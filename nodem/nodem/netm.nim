import strutils, strformat, options, uri, tables, hashes, times
from net import OptReuseAddr
from asyncnet import AsyncSocket
from os import param_str
import ./net_nodem, ./supportm, ./asyncm

export net_nodem, asyncm


# autoconnect --------------------------------------------------------------------------------------
proc connect_without_concurrent_usage(url: string, timeout_ms: int): Future[AsyncSocket] {.async.} =
  let (scheme, host, port, path) = url.parse_url
  if scheme != "tcp": throw "only TCP supported"
  if path != "": throw "wrong path"

  # Waiting for timeout
  let tic = timer_ms()
  while true:
    var socket = asyncnet.new_async_socket()
    try:
      let left_ms = timeout_ms - tic()
      if left_ms > 0:
        await asyncnet.connect(socket, host, Port(port)).with_timeout(left_ms)
      else:
        await asyncnet.connect(socket, host, Port(port))
      return socket
    except Exception as e:
      try:    asyncnet.close(socket)
      except: discard

    let delay_time_ms = 20
    let left_ms = timeout_ms - tic()
    if left_ms <= delay_time_ms:
      throw "Timed out, connection closed"
    else:
      await sleep_async delay_time_ms

var sockets: Table[string, AsyncSocket]
var connect_in_progress: Table[string, Future[AsyncSocket]]
# Preventing multiple concurrent attempts to open same socket

proc connect(node: Node, timeout_ms: int): Future[AsyncSocket] {.async.} =
  # Auto-connect for sockets, if not available wait's till connection would be available with timeout,
  # maybe also add auto-disconnect if it's not used for a while
  let (url, _) = node.get
  if timeout_ms <= 0: throw "tiemout should be greather than zero"

  if url in sockets: return sockets[url]

  # Preventing simultaneous connection to the same socket
  if url in connect_in_progress: return await connect_in_progress[url]
  try:
    let r = connect_without_concurrent_usage(url, timeout_ms)
    connect_in_progress[url] = r
    sockets[url] = await r
  finally:
    connect_in_progress.del url
  return sockets[url]


# disconnect ---------------------------------------------------------------------------------------
proc disconnect*(node: Node): Future[void] {.async.} =
  let (url, _) = node.get
  if url in sockets:
    let socket = sockets[url]
    try:     asyncnet.close(socket)
    except:  discard
    finally: sockets.del url


# send_message, receive_message --------------------------------------------------------------------
var id_counter: int64 = 0
proc next_id: int64 = id_counter += 1

proc send_message_async(socket: AsyncSocket, message: string, message_id = next_id()): Future[void] {.async.} =
  await asyncnet.send(socket, ($(message.len.int8)).align_left(8))
  await asyncnet.send(socket, ($message_id).align_left(64))
  await asyncnet.send(socket, message)

proc receive_message_async(
  socket: AsyncSocket
): Future[tuple[is_closed: bool, message_id: int, message: string]] {.async.} =
  let message_length_s = await asyncnet.recv(socket, 8)
  if message_length_s == "": return (true, -1, "") # Socket disconnected
  if message_length_s.len != 8: throw "socket error, wrong size for message length"
  let message_length = message_length_s.replace(" ", "").parse_int

  let message_id_s = await asyncnet.recv(socket, 64)
  if message_id_s.len != 64: throw "socket error, wrong size for message_id"
  let message_id = message_id_s.replace(" ", "").parse_int

  let message = await asyncnet.recv(socket, message_length)
  if message.len != message_length: throw "socket error, wrong size for message"
  return (false, message_id, message)


# send_async ---------------------------------------------------------------------------------------
proc send_async*(node: Node, message: string, timeout_ms: int): Future[void] {.async.} =
  # Send message
  if timeout_ms <= 0: throw "tiemout should be greather than zero"
  let tic = timer_ms()
  let socket = await connect(node, timeout_ms)
  var success = false
  try:
    let left_ms = timeout_ms - tic() # some time could be used by `connect`
    if left_ms <= 0: throw "send timed out"
    await socket.send_message_async(message).with_timeout(left_ms)
    success = true
  finally:
    # Closing socket on any error, it will be auto-reconnected
    if not success: await disconnect(node)

proc send_async*(node: Node, message: string): Future[void] =
  let (_, timeout_ms) = node.get
  send_async(node, message, timeout_ms)


# send ---------------------------------------------------------------------------------------------
proc send*(node: Node, message: string, timeout_ms: int): void =
  # Send message
  try:
    wait_for node.send_async(message, timeout_ms)
  except Exception as e:
    # Cleaning messy async error
    throw fmt"can't send to '{node}', {e.msg.clean_async_error}"

proc send*(node: Node, message: string): void =
  let (_, timeout_ms) = node.get
  send(node, message, timeout_ms)


# call_async ---------------------------------------------------------------------------------------
proc call_async*(node: Node, message: string, timeout_ms: int): Future[string] {.async.} =
  # Send message and waits for reply
  if timeout_ms <= 0: throw "tiemout should be greather than zero"

  let tic = timer_ms()
  let socket = await connect(node, timeout_ms)

  var success = false
  try:
    let id = next_id()

    # Sending
    var left_ms = timeout_ms - tic() # some time could be used by `connect`
    if left_ms <= 0: throw "send timed out"
    await socket.send_message_async(message, id).with_timeout(left_ms)

    # Receiving
    left_ms = timeout_ms - tic()
    if left_ms <= 0: throw "receive timed out"
    let (is_closed, reply_id, reply) = await socket.receive_message_async.with_timeout(left_ms)

    if is_closed: throw "socket closed"
    if reply_id != id: throw "wrong reply id for call"
    success = true
    return reply
  finally:
    # Closing socket on any error, it will be auto-reconnected
    if not success: await disconnect(node)

proc call_async*(node: Node, message: string): Future[string] =
  let (_, timeout_ms) = node.get
  call_async(node, message, timeout_ms)


# call ---------------------------------------------------------------------------------------------
proc call*(node: Node, message: string, timeout_ms: int): string =
  # Send message and waits for reply
  try:
    wait_for node.call_async(message, timeout_ms)
  except Exception as e:
    # Cleaning messy async error
    throw fmt"can't call '{node}', {e.msg.clean_async_error}"

proc call*(node: Node, message: string): string =
  let (_, timeout_ms) = node.get
  call(node, message, timeout_ms)


# receive_async ------------------------------------------------------------------------------------
type OnMessageAsync* = proc (message: string): Future[Option[string]]
type OnNetError*     = proc (e: ref Exception): void # mostly for logging

proc process_client_async(
  client:           AsyncSocket,
  on_message_async: OnMessageAsync,
  on_net_error:     OnNetError,
  timeout_ms:       int,
) {.async.} =
  # Messages received and send async with both sync/async handlers, so there's no waiting for networking.
  try:
    while not asyncnet.is_closed(client):
      let (is_closed, message_id, message) = await client.receive_message_async
      if is_closed: break

      let reply = try:
        await on_message_async(message)
      except Exception as e:
        # If exception happens in the handler itself quitting, it should be handled
        # in `on_message` with try/except
        stderr.write_line "unhandled exception in recieve_async, quitting"
        stderr.write_line e.msg
        stderr.write_line e.get_stack_trace
        quit 1

      if reply.is_some:
        await send_message_async(client, reply.get, message_id).with_timeout(timeout_ms)
  except Exception as e:
    on_net_error(e)
  finally:
    # Ensuring socket is closed
    try:    asyncnet.close(client)
    except: discard

proc on_net_error_default(e: ref Exception): void = echo e.msg

proc receive_async*(
  node:      Node,
  on_message:   OnMessageAsync,
  on_net_error: OnNetError = on_net_error_default
): Future[void] {.async.} =
  let (url, timeout_ms) = node.get
  if timeout_ms <= 0: throw "tiemout should be greather than zero"

  let (scheme, host, port, path) = parse_url url
  if scheme != "tcp": throw "only TCP supported"
  if path != "": throw "wrong path"
  var server = asyncnet.new_async_socket()
  asyncnet.set_sock_opt(server, OptReuseAddr, true)
  asyncnet.bind_addr(server, Port(port), host)
  asyncnet.listen(server)

  while true:
    let client = await asyncnet.accept(server)
    spawn_async process_client_async(client, on_message, on_net_error, timeout_ms)


# receive ------------------------------------------------------------------------------------------
type OnMessage* = proc (message: string): Option[string]

proc receive*(
  node:      Node,
  on_message:   OnMessage,
  on_net_error: OnNetError = on_net_error_default
): void =
  # While the handler itsel is sync, the messages received and send async, so there's no
  # waiting for networking.

  proc on_message_with_error_handling(message: string): Option[string] =
    try:
      on_message message
    except Exception as e:
      # If exception happens in the handler itself quitting, it should be handled
      # in `on_message` with try/except
      stderr.write_line "unhandled exception in recieve, quitting"
      stderr.write_line e.msg
      stderr.write_line e.get_stack_trace
      quit 1

  proc on_message_async(message: string): Future[Option[string]] {.async.} =
    # The `on_message_with_error_handling` have to be separate proc to avoid messy async stack trace
    return on_message_with_error_handling(message)

  wait_for receive_async(node, on_message_async, on_net_error)


# Test ---------------------------------------------------------------------------------------------
if is_main_module:
  # Two nodes working simultaneously and exchanging messages, there's no client or server
  let (a, b) = (Node("a"), Node("b"))

  proc start(self: Node, other: Node) =
    proc log(msg: string) = echo fmt"node {self} {msg}"

    proc main: Future[void] {.async.} =
      for _ in 1..3:
        log "heartbeat"
        let dstate = await other.call_async("state")
        log fmt"state of other: {dstate}"
        await sleep_async 1000
      await other.send_async("quit")

    proc on_message(message: string): Future[Option[string]] {.async.} =
      case message
      of "state": # Handles `call`, with reply
        return fmt"{self} ok".some
      of "quit":    # Hanldes `send`, without reply
        log "quitting"
        quit()
      else:
        throw fmt"unknown message {message}"

    proc on_error(e: ref Exception): void = echo e.msg

    log "started"
    spawn_async main()
    spawn_async self.receive_async(on_message, on_error)

  start(a, b)
  start(b, a)
  run_forever()


# receive ------------------------------------------------------------------------------------------
# const delay_ms = 100
# proc receive*(node: Node): Future[string] {.async.} =
#   # Auto-reconnects and waits untill it gets the message
#   var success = false
#   try:
#     # Handling connection errors and auto-reconnecting
#     while true:
#       let socket = block:
#         let (is_error, error, socket) = await connect node
#         if is_error:
#           await sleep_async delay_ms
#           continue
#         socket
#       let (is_error, is_closed, error, _, message) = await socket.receive_message
#       if is_error or is_closed:
#         await sleep_async delay_ms
#         continue
#       success = true
#       return message
#   finally:
#     # Closing socket on any error, it will be auto-reconnected
#     if not success: await disconnect(node)


# if is_main_module:
#   # Clean error on server
#   let server = Node("server")
#   proc run_server =
#     proc on_message(message: string): Option[string] =
#       throw "some error"
#     server.receive(on_message)

#   proc run_client =
#     server.send "some message"

#   case param_str(1)
#   of "server": run_server()
#   of "client": run_client()
#   else:        throw "unknown command"