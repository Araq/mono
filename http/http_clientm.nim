import sugar, httpclient, strformat
import supportm, jsonm, urlm, seqm, falliblem, tablem, logm
from uri import nil

let default_timeout_sec = 5
let http_pool_size_warn = 100

# with_client --------------------------------------------------------------------------------------
var clients_pool: Table[string, HttpClient]
template with_client(url: string, use_pool: bool, code) =
  if use_pool:
    if clients_pool.len > http_pool_size_warn:
      Log.init("http").with((size: clients_pool.len)).warn("clients pool is too large {size}")

    let domain = Url.parse(url).domain
    if domain notin clients_pool: clients_pool[domain] = new_http_client()
    let client {.inject.} = clients_pool[domain]
    return code
  else:
    let client {.inject.} = new_http_client()
    defer: client.close
    return code


# http_get, http_post ------------------------------------------------------------------------------
proc http_get*(
  url: string, timeout_sec = default_timeout_sec, use_pool = false,
  headers: openarray[(string, string)] = @[]
): string =
  with_client(url, use_pool):
    client.timeout = timeout_sec * 1000
    client.headers = new_http_headers(headers)
    client.get_content(url)

proc http_post*(
  url: string, content: string, timeout_sec = default_timeout_sec, use_pool = false,
  headers: openarray[(string, string)] = @[]
): string =
  with_client(url, use_pool):
    client.timeout = timeout_sec * 1000
    client.headers = new_http_headers(headers)
    client.post_content(url, content)


# get_data, post_data ------------------------------------------------------------------------------
proc get_data*[Res](url: string, timeout_sec = default_timeout_sec, use_pool = false): Res =
  let resp = http_get(url, timeout_sec, use_pool, { "Content-Type": "application/json" })
  Fallible[Res].from_json(resp.parse_json).get

proc post_data*[Req, Res](url: string, req: Req, timeout_sec = default_timeout_sec, use_pool = false): Res =
  let resp = http_post(url, req.to_json, timeout_sec, use_pool, { "Content-Type": "application/json" })
  Fallible[Res].from_json(resp.parse_json).get


# post_batch ---------------------------------------------------------------------------------------
proc post_batch*[B, R](
  url: string, requests: seq[B], timeout_sec = default_timeout_sec, use_pool = false
): seq[Fallible[R]] =
  let data = http_post(url, requests.to_json, timeout_sec, use_pool, { "Content-Type": "application/json" })
  let json = data.parse_json
  if json.kind == JObject and "is_error" in json:
    for _ in requests:
      result.add Fallible[R].from_json(json)
  else:
    for item in json:
      result.add Fallible[R].from_json(item)


# build_url ----------------------------------------------------------------------------------------
proc build_url*(url: string, query: varargs[(string, string)]): string =
  if query.len > 0: url & "?" & uri.encode_query(query)
  else:            url

proc build_url*(url: string, query: tuple): string =
  var squery: seq[(string, string)] = @[]
  for k, v in query.field_pairs: squery.add((k, $v))
  build_url(url, squery)

test "build_url":
  assert build_url("http://some.com") == "http://some.com"
  assert build_url("http://some.com", { "a": "1", "b": "two" }) == "http://some.com?a=1&b=two"

  assert build_url("http://some.com", (a: 1, b: "two")) == "http://some.com?a=1&b=two"