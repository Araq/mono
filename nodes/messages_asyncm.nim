import asyncdispatch, strutils, strformat, options, uri, tables, hashes, ./nodem, ./supportm
from asyncnet import AsyncSocket
from os import param_str

export nodem, asyncdispatch

{.experimental: "code_reordering".}

# send_message, receive_message --------------------------------------------------------------------
var id_counter: int64 = 0
proc next_id: int64 = id_counter += 1

proc send_message(socket: AsyncSocket, message: string, message_id = next_id()): Future[void] {.async.} =
  await asyncnet.send(socket, ($(message.len.int8)).align_left(8))
  await asyncnet.send(socket, ($message_id).align_left(64))
  await asyncnet.send(socket, message)

proc receive_message(
  socket: AsyncSocket
): Future[tuple[is_error: bool, is_closed: bool, error: string, message_id: int, message: string]] {.async.} =
  template return_error(error: string) = return (true, true, error, -1, "")

  let message_length_s = await asyncnet.recv(socket, 8)
  if message_length_s == "": return (false, true, "", -1, "") # Socket disconnected
  if message_length_s.len != 8: return_error("socket error, wrong size for message length")
  let message_length = message_length_s.replace(" ", "").parse_int

  let message_id_s = await asyncnet.recv(socket, 64)
  if message_id_s.len != 64: return_error("socket error, wrong size for message_id")
  let message_id = message_id_s.replace(" ", "").parse_int

  let message = await asyncnet.recv(socket, message_length)
  if message.len != message_length: return_error("socket error, wrong size for message")
  return (false, false, "", message_id, message)


# receive ------------------------------------------------------------------------------------------
const delay_ms = 100
proc receive*(node: Node): Future[string] {.async.} =
  # Auto-reconnects and waits untill it gets the message
  var success = false
  try:
    # Handling connection errors and auto-reconnecting
    while true:
      let socket = block:
        let (is_error, error, socket) = await connect node
        if is_error:
          await sleep_async delay_ms
          continue
        socket
      let (is_error, is_closed, error, _, message) = await socket.receive_message
      if is_error or is_closed:
        await sleep_async delay_ms
        continue
      success = true
      return message
  finally:
    # Closing socket on any error, it will be auto-reconnected
    if not success: await disconnect(node)


# send ---------------------------------------------------------------------------------------------
proc send*(node: Node, message: string): Future[void] {.async.} =
  # Send message, if acknowledge without reply
  let (is_error, error, socket) = await connect(node)
  if is_error: throw error
  var success = false
  try:
    await socket.send_message(message)
    success = true
  finally:
    # Closing socket on any error, it will be auto-reconnected
    if not success: await disconnect(node)


# emit ---------------------------------------------------------------------------------------------
proc emit*(node: Node, message: string): Future[void] {.async.} =
  # Emit message without reply and don't check if it's delivered or not, never fails
  let (is_error, _, socket) = await connect(node)
  if not is_error:
    try:
      await socket.send_message(message)
    except:
      # Closing socket on any error, it will be auto-reconnected
      await disconnect(node)


# call ---------------------------------------------------------------------------------------------
proc call*(node: Node, message: string): Future[string] {.async.} =
  # Send message and waits for reply
  let socket = block:
    let (is_error, error, socket) = await connect(node)
    if is_error: throw error
    socket
  var success = false
  try:
    let id = next_id()
    await socket.send_message(message, id)
    let (is_error, is_closed, error, reply_id, reply) = await socket.receive_message
    if is_error: throw error
    if is_closed: throw "socket closed"
    if reply_id != id: throw "wrong reply id for call"
    success = true
    return reply
  finally:
    # Closing socket on any error, it will be auto-reconnected
    if not success: await disconnect(node)


# on_receive ---------------------------------------------------------------------------------------
type MessageHandler* = proc (message: string): Future[Option[string]]
type SelfHandler* = proc: Future[void]

let default_self = proc: Future[void] {.async.} = discard

proc run*(node: Node, handler: MessageHandler, self: SelfHandler = default_self): Future[void] {.async.} =
  let (scheme, host, port) = parse_url node.to_url
  if scheme != "tcp": throw "only TCP supported"
  var server = asyncnet.new_async_socket()
  asyncnet.bind_addr(server, Port(port), host)
  asyncnet.listen(server)

  async_check self()
  while true:
    let client = await asyncnet.accept(server)
    async_check process_client(client, handler)

proc process_client(client: AsyncSocket, handler: MessageHandler) {.async.} =
  try:
    while not asyncnet.is_closed(client):
      let (is_error, is_closed, error, message_id, message) = await client.receive_message
      if is_error: throw error
      if is_closed: break
      let reply = await handler(message)
      if reply.is_some:
        await send_message(client, reply.get, message_id)
  finally:
    # Ensuring socket is closed
    try:    asyncnet.close(client)
    except: discard


# autoconnect --------------------------------------------------------------------------------------
# Auto-connect for sockets, maybe also add auto-disconnect if it's not used for a while
var sockets: Table[string, AsyncSocket]
proc connect(node: Node): Future[tuple[is_error: bool, error: string, socket: AsyncSocket]] {.async.} =
  let url = node.to_url
  if url notin sockets:
    let (scheme, host, port) = url.parse_url
    if scheme != "tcp": throw "only TCP supported"
    var socket = asyncnet.new_async_socket()
    try:
      await asyncnet.connect(socket, host, Port(port))
    except Exception as e:
      return (true, e.msg, socket)
    sockets[url] = socket
  return (false, "", sockets[url])


# disconnect ---------------------------------------------------------------------------------------
proc disconnect*(node: Node): Future[void] {.async.} =
  let url = node.to_url
  if url in sockets:
    let socket = sockets[url]
    try:     asyncnet.close(socket)
    except:  discard
    finally: sockets.del url


# Test ---------------------------------------------------------------------------------------------
if is_main_module:
  # Two nodes working simultaneously and exchanging messages, there's no client or server
  let (a, b) = (Node("a"), Node("b"))

  proc start(node: Node, dependent: Node): Future[void] {.async.} =
    proc log(msg: string) = echo fmt"node {node} {msg}"

    proc self: Future[void] {.async.} =
      for _ in 1..3:
        log "heartbeat"
        try:
          let dstate = await dependent.call("state")
          log fmt"state of dependent: {dstate}"
        except:
          log "failed" # a going to fail first time, because b is not started yet
        await sleep_async 1000

    proc on_receive(message: string): Future[Option[string]] {.async.} =
      case message
      of "state": # Handles `call`, with reply
        return fmt"{node} ok".some
      of "quit":    # Hanldes `send`, without reply
        log "quitting"
        quit()
      else:
        throw fmt"unknown message {message}"

    log "started"
    await node.run(on_receive, self)

  async_check start(a, b)
  async_check start(b, a)
  run_forever()