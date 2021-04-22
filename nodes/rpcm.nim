import json, tables, strutils, strformat, sequtils, sugar, macros, options, sets, ./supportm
import ./node_namem, ./net_asyncm

export json, node_namem

# fn_signature -------------------------------------------------------------------------------------
type FnSignature = (NimNode, seq[(NimNode, NimNode, NimNode)], NimNode)
# `NimNodes` have are of `nnk_sym` except of `arg_default` which is `nnk_empty` or custom literal type.

type FnSignatureS = (string, seq[(string, string, Option[string])], string)
proc to_s(fsign: FnSignature): FnSignatureS =
  let args = fsign[1].map((arg) => (
    arg[0].str_val, arg[1].str_val, if arg[2].kind == nnk_empty: string.none else: arg[2].str_val.some)
  )
  (fsign[0].str_val, args, fsign[2].str_val)

proc fn_signature(fn_raw: NimNode): FnSignature =
  let invalid_usage = "invalid usage, if you think it's a valid case please update the code to suppor it"
  let fn_impl = case fn_raw.kind
  of nnk_sym:      fn_raw.get_impl
  of nnk_proc_def: fn_raw
  else:            throw fmt"{invalid_usage}, {fn_raw.kind}"
  # echo fn_impl.tree_repr()

  let fname = fn_impl.name
  assert fname.kind == nnk_sym, invalid_usage

  let rtype = fn_impl.params()[0] # return type is the first one
  assert rtype.kind == nnk_sym, invalid_usage

  var args: seq[(NimNode, NimNode, NimNode)]
  for i in 1 ..< fn_impl.params.len:  # first is return type
    let idents = fn_impl.params[i]
    let (arg_type, arg_default) = (idents[^2], idents[^1])
    assert arg_type.kind == nnk_sym, invalid_usage
    for j in 0 ..< idents.len-2:  # last are arg type and default value
      let arg_name = idents[j]
      assert arg_name.kind == nnk_sym, invalid_usage
      args.add((arg_name, arg_type, arg_default))
  (fname, args, rtype)

test "fn_signature":
  macro get_fn_signature(fn: typed): string =
    let signature = fn.fn_signature.repr
    quote do:
      `signature`

  proc fn_0_args: float = 0.0
  assert get_fn_signature(fn_0_args) == "(fn_0_args, [], float)"

  proc fn_1_args(c: string): float = 0.0
  assert get_fn_signature(fn_1_args) == "(fn_1_args, [(c, string, )], float)"

  proc fn_1_args_with_default(c: string = "some"): float = 0.0
  assert get_fn_signature(fn_1_args_with_default) == """(fn_1_args_with_default, [(c, string, "some")], float)"""

  type Cache = (int, int)
  proc fn_custom_arg_type(c: Cache): float = 0.0
  assert get_fn_signature(fn_custom_arg_type) == "(fn_custom_arg_type, [(c, Cache, )], float)"

  proc fn_2_args(c: string, d: int): float = 0.0
  assert get_fn_signature(fn_2_args) == "(fn_2_args, [(c, string, ), (d, int, )], float)"

  proc fn_2_comma_args(c, d: string): float = 0.0
  assert get_fn_signature(fn_2_comma_args) == "(fn_2_comma_args, [(c, string, ), (d, string, )], float)"


# nexport ------------------------------------------------------------------------------------------
macro nexport*(node: NodeName, fn: typed) =
  # Export function as node function, so it would be possible to call it remotely from other nodes

  let fsign      = fn_signature(fn)
  let fsymb      = fsign[0]
  let fsigns     = fsign.to_s

  for arg in fsign[1]:
    if arg[2].kind != nnk_empty:
      throw "defaults not supported yet, please consider updating the code to support it"

  case fn.kind
  of nnk_proc_def: # Used as pragma `{.sfun.}`
    quote do:
      nexport_function(`node`, `fsigns`, `fsymb`)
      `fn`
  of nnk_sym: # Used as macro `sfun fn`
    quote do:
      nexport_function(`node`, `fsigns`, `fsymb`)
  else:
    throw fmt"invalid usage, if you think it's a valid case please update the code to suppor it, {fn.kind}"


# export_node_function -----------------------------------------------------------------------------
type NFHandler = proc (args: JsonNode): JsonNode # can throw errors

type NexportedFunction = ref object
  node:    NodeName
  fsign:   FnSignatureS
  handler: NFHandler
var nexported_functions: Table[string, NexportedFunction]

proc full_name(s: FnSignatureS): string =
  # Full name with argument types and return values, needed to support multiple dispatch
  template normalize (s: string): string = s.replace("_", "").replace(" ", "").to_lower
  let args_s = s[1].map((arg) => fmt"{arg[0].normalize}: {arg[1].normalize}").join(", ")
  fmt"{s[0].normalize}({args_s}): {s[2].normalize}"

proc nexport_function*[R](node: NodeName, fsign: FnSignatureS, fn: proc: R): void =
  proc nfhandler(args: JsonNode): JsonNode =
    assert args.kind == JArray and args.len == 0
    %fn()
  nexported_functions[fsign.full_name] = NexportedFunction(node: node, fsign: fsign, handler: nfhandler)

proc nexport_function*[A, R](node: NodeName, fsign: FnSignatureS, fn: proc(a: A): R): void =
  proc nfhandler(args: JsonNode): JsonNode =
    assert args.kind == JArray and args.len == 1
    %fn(args[0].to(A))
  nexported_functions[fsign.full_name] = NexportedFunction(node: node, fsign: fsign, handler: nfhandler)

proc nexport_function*[A, B, R](node: NodeName, fsign: FnSignatureS, fn: proc(a: A, b: B): R): void =
  proc nfhandler(args: JsonNode): JsonNode =
    assert args.kind == JArray and args.len == 2
    %fn(args[0].to(A), args[1].to(B))
  nexported_functions[fsign.full_name] = NexportedFunction(node: node, fsign: fsign, handler: nfhandler)

proc nexport_function*[A, B, C, R](node: NodeName, fsign: FnSignatureS, fn: proc(a: A, b: B, c: C): R): void =
  proc nfhandler(args: JsonNode): JsonNode =
    assert args.kind == JArray and args.len == 3
    %fn(args[0].to(A), args[1].to(B), args[2].to(C))
  nexported_functions[fsign.full_name] = NexportedFunction(node: node, fsign: fsign, handler: nfhandler)


# nexport_handler ----------------------------------------------------------------------------------
proc nexport_handler*(req: string): Future[Option[string]] {.async.} =
  # Use it to start as RPC server
  try:
    let data = req.parse_json
    let (fname, args) = (data["fname"].get_str, data["args"])
    if fname notin nexported_functions: throw fmt"no server function '{fname}'"
    let nfn = nexported_functions[fname]
    let res = nfn.handler(args)
    discard %((a: 1))
    return (is_error: false, result: res).`%`.`$`.some
  except Exception as e:
    return (is_error: true, message: e.msg).`%`.`$`.some


# nimport ------------------------------------------------------------------------------------------
macro nimport*(node: NodeName, fn: typed) =
  # Import remote function from remote node to be able to call it

  let fsign      = fn_signature(fn)
  let fsigns     = fsign.to_s
  let full_name  = fsigns.full_name
  let args       = fsign[1]
  let rtype      = fsign[2]

  # Generating code
  case args.len:
  of 0:
    quote do:
      return call_nimported_function(`node`, `full_name`, typeof `rtype`)
  of 1:
    let a = args[0]
    quote do:
      return call_nimported_function(`node`, `full_name`, `a`, typeof `rtype`)
  of 2:
    let (a, b) = (args[0], args[1])
    quote do:
      return call_nimported_function(`node`, `full_name`, `a`, `b`, typeof `rtype`)
  of 3:
    let (a, b, c) = (args[0], args[1], args[2])
    quote do:
      return call_nimported_function(`node`, `full_name`, `a`, `b`, `c`, typeof `rtype`)
  else:
    quote do:
      raise new_exception(Exception, "not supported, please update the code to suppor it")


# call_nimported_function -----------------------------------------------------------------------------
proc call_nimported_function(node: NodeName, fname: string, args: JsonNode): JsonNode =
  assert args.kind == JArray
  let res = wait_for node.call((fname: fname, args: args).`%`.`$`)
  let data = res.parse_json
  if data["is_error"].get_bool: throw data["message"].get_str
  data["result"]

proc call_nimported_function*[R](node: NodeName, fname: string, rtype: type[R]): R =
  let args = newJArray()
  call_nimported_function(node, fname, args).to(R)

proc call_nimported_function*[A, R](node: NodeName, fname: string, a: A, tr: type[R]): R =
  let args = newJArray(); args.add %a
  call_nimported_function(node, fname, args).to(R)

proc call_nimported_function*[A, B, R](node: NodeName, fname: string, a: A, b: B, tr: type[R]): R =
  let args = newJArray(); args.add %a; args.add %b;
  call_nimported_function(node, fname, args).to(R)

proc call_nimported_function*[A, B, C, R](node: NodeName, fname: string, a: A, b: B, c: C, tr: type[R]): R =
  let args = newJArray(); args.add %a; args.add %b; args.add %c
  call_nimported_function(node, fname, args).to(R)


# generate_nimport ---------------------------------------------------------------------------------
const default_prepend = """
import nodes/rpcm

export rpcm"""

proc generate_nimport*(fname: string, prepend = default_prepend): void =
  var statements: seq[string]
  statements.add $prepend

  var declared_nodes: HashSet[NodeName]
  for nfn in nexported_functions.values:
    let (node, fsign) = (nfn.node, nfn.fsign)

    # Declaring node
    if node notin declared_nodes:
      statements.add fmt"""let {node}* = NodeName("{node}")"""
      declared_nodes.incl node

    # Declaring function
    let args_s = fsign[1].map((arg) => fmt"{arg[0]}: {arg[1]}").join(", ")
    statements.add fmt"""proc {fsign[0]}*({args_s}): {fsign[2]} = nimport({node}, {fsign[0]})"""

  # Avoiding writing file if it's the same
  let code = statements.join("\n\n")
  let existing_code =
    try: read_file(fname)
    except: ""

  if existing_code != code:
    write_file(fname, code)