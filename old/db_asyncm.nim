import base/[basem, asyncm, logm]
import ./sqlm
from osproc import exec_cmd_ex
from uri import nil

from asyncpg as pga import nil

# DbAsync ------------------------------------------------------------------------------------------
type DbAsync* = object
  id*: string

proc `$`*(db: DbAsync): string = db.id
proc hash*(db: DbAsync): Hash = db.id.hash
proc `==`*(a, b: DbAsync): bool = a.id == b.id

proc log(db: DbAsync): Log = Log.init("db_async", db.id)


# DbAsyncImpl --------------------------------------------------------------------------------------
type DbAsyncImpl* = ref object
  url*:                    string
  encoding*:               string
  create_db_if_not_exist*: bool

  host*:                   string
  port*:                   int
  name*:                   string
  user*:                   string
  password*:               string


# Impls --------------------------------------------------------------------------------------------
var impls: Table[DbAsync, DbAsyncImpl]
# Deferring the database configuration, like IoC

proc impl*(
  db:                      DbAsync,
  name_or_url:             string,
  encoding               = "utf8",
  create_db_if_not_exist = true # Create db if not exist
): void =
  let url = if ":" in name_or_url: name_or_url
  else:                            fmt"postgresql://postgres@localhost:5432/{name_or_url}"

  var parsed = uri.init_uri(); uri.parse_uri(url, parsed)
  impls[db] = DbAsyncImpl(
    url: url, encoding: encoding, create_db_if_not_exist: create_db_if_not_exist,
    host: parsed.hostname, port: parsed.port.parse_int, name: parsed.path[1..^1],
    user: parsed.username, password: parsed.password
  )

proc impl*(db: DbAsync): DbAsyncImpl =
  if db notin impls: throw fmt"db '{db.id}' not defined"
  impls[db]


# Connections --------------------------------------------------------------------------------------
# Using separate storage for connections, because they need to be mutable. The DbAsync can't be mutable
# because it's needed to be passed around callbacks and sometimes Nim won't allow to pass mutable data
# in callbacks.
var connections:      Table[DbAsync, pga.apgConnection]
var before_callbacks: Table[DbAsync, seq[proc: Future[void]]]


# DbAsync.init ------------------------------------------------------------------------------------------
proc init*(_: type[DbAsync], id = "default"): DbAsync =
  # The db parameters and connection will be establisehd later, lazily on demand, and reconnected after failure
  DbAsync(id: id)


# db.create ----------------------------------------------------------------------------------------
proc create*(db: DbAsync): Future[void] {.async.} =
  # Using bash, don't know how to create db otherwise
  db.log.info "create"
  let impl = db.impl
  let (output, code) = exec_cmd_ex fmt"createdb -U {impl.user} {impl.name}"
  if code != 0 and fmt"""database "{impl.name}" already exists""" in output:
    throw "can't create database {impl.user} {impl.name}"


# db.drop ------------------------------------------------------------------------------------------
proc drop*(db: DbAsync, user = "postgres"): Future[void] {.async.} =
  # Using bash, don't know how to db db otherwise
  db.log.info "drop"
  let impl = db.impl
  let (output, code) = exec_cmd_ex fmt"dropdb -U {impl.user} {impl.name}"
  if code != 0 and fmt"""database "{impl.name}" does not exist""" notin output:
    throw fmt"can't drop database {impl.user} {impl.name}"


# db.close -----------------------------------------------------------------------------------------
# proc close*(db: DbAsync): Future[void] {.async.} =
#   if db notin connections: return
#   let conn = connections[db]
#   connections.del db
#   db.log.info "close"
#   db_postgres.close(conn)


# db.with_connection -------------------------------------------------------------------------------
#
# - Connect lazily on demand
# - Reconnect after error
# - Automatically create database if not exist

proc connect(db: DbAsync): Future[pga.apgConnection]

var in_progress: Table[DbAsync, Future[pga.apgConnection]]
proc with_connection*[R](db: DbAsync, op: (pga.apgConnection) -> Future[R]): Future[R] {.async.} =
  # if db in in_progress:
  #   await in_progress[db]
  # in_progress[db] = result

  if db notin connections:
    connections[db] = await db.connect()

    if db in before_callbacks:
      db.log.info "applying before callbacks"
      for cb in before_callbacks[db]: await cb()

  var success = false
  try:
    let r = await op(connections[db])
    result.complete r
    success = true
  finally:
    if not success:
      # Reconnecting if connection is broken. There's no way to determine if error was caused by
      # broken connection or something else. So assuming that connection is broken and terminating it,
      # it will be reconnected next time automatically.
      try:                   db.close
      except Exception as e: db.log.warn("can't close connection", e)

# proc with_connection*(db: DbAsync, op: (DbAsyncConn) -> void): void =
#   discard db.with_connection(proc (conn: auto): auto =
#     op(conn)
#     true
#   )

proc connect(db: DbAsync): Future[pga.apgConnection] {.async.} =
  db.log.info "connect"
  let impl = db.impl

  proc connect(): Future[pga.apgConnection] =
    var params = @[("host", impl.host), ("port", impl.port.to_s), ("dbname", impl.name), ("user", impl.user)]
    if impl.password != "": params.add(("password", impl.password))
    pga.connect(params.map((param) => fmt"{param[0]}={param[1]}").join(" "))

  let connection = try:
    await connect()
  except Exception as e:
    # Creating databse if doesn't exist and trying to reconnect
    if fmt"""database "{impl.name}" does not exist""" in e.message and impl.create_db_if_not_exist:
      await db.create
      await connect()
    else:
      throw e

  # Setting encoding
  # try:
  echo "set encoding"
  # await pga.set_encoding(connection, impl.encoding)
  # except Exception as e:
  #   throw "can't set encoding"

  # Disabling logging https://forum.nim-lang.org/t/7801
  # let stub: postgres.PQnoticeReceiver = proc (arg: pointer, res: postgres.PPGresult){.cdecl.} = discard
  # discard postgres.pqsetNoticeReceiver(connection, stub, nil)
  return connection


# to_nim_postgres_sql ------------------------------------------------------------------------------
type NimPostgresSQL* = tuple[query: string, values: seq[string]] # Parameterised SQL

proc to_nim_postgres_sql*(sql: SQL): NimPostgresSQL =
  # Nim driver for PostgreSQL requires special format because:
  # - it doesn't support null in SQL params
  # - it doesn't support typed params, all params should be strings
  var i = 0
  var values: seq[string]
  let query: string = sql.query.replace(re"\?", proc (v: string): string =
    let v = sql.values[i]
    i += 1
    case v.kind:
    of JNull:
      "null"
    of JString:
      values.add v.get_str
      "?"
    else:
      values.add $v
      "?"
  )
  if i != sql.values.len: throw fmt"number parameters in SQL doesn't match, {sql}"
  (query: query, values: values)


# db.exec ------------------------------------------------------------------------------------------
proc exec_batch(connection: DbAsyncConn, query: string) =
  # https://forum.nim-lang.org/t/7804
  var res = postgres.pqexec(connection, query)
  if postgres.pqResultStatus(res) != postgres.PGRES_COMMAND_OK: db_postgres.dbError(connection)
  postgres.pqclear(res)

proc exec*(db: DbAsync, query: SQL, log = true): void =
  if log: db.log.debug "exec"
  if ";" in query.query:
    if not query.values.is_empty: throw "multiple statements can't be used with parameters"
    db.with_connection do (conn: auto) -> void:
      conn.exec_batch(query.query)
  else:
    let pg_query = query.to_nim_postgres_sql
    db.with_connection do (conn: auto) -> void:
      db_postgres.exec(conn, db_postgres.sql(pg_query.query), pg_query.values)


# db.before ----------------------------------------------------------------------------------------
# Callbacks to be executed before any query
proc before*(db: DbAsync, cb: proc: void, prepend = false): void =
  var list = before_callbacks[db, @[]]
  before_callbacks[db] = if prepend: cb & list else: list & cb

proc before*(db: DbAsync, sql: SQL, prepend = false): void =
  db.before(() => db.exec(sql), prepend = prepend)


# db.get ------------------------------------------------------------------------------------------
proc get_raw*(db: DbAsync, query: SQL, log = true): seq[JsonNode] =
  if log: db.log.debug "get"
  let pg_query = query.to_nim_postgres_sql
  db.with_connection do (conn: auto) -> auto:
    var rows: seq[JsonNode]
    var columns: db_postgres.DbAsyncColumns
    for row in db_postgres.instant_rows(conn, columns, db_postgres.sql(pg_query.query), pg_query.values):
      var jrow = newJObject()
      for i in 0..<columns.len:
        let name   = columns[i].name
        let kind   = columns[i].typ.kind
        let svalue = db_postgres.`[]`(row, i)
        jrow.add(name, from_postgres_to_json(kind, svalue))
      rows.add jrow
    rows

proc get*[T](db: DbAsync, query: SQL, _: type[T], log = true): seq[T] =
  db.get_raw(query, log = log).map((v) => v.postgres_to(T))


# db.get_one --------------------------------------------------------------------------------------
proc get_one_optional*[T](db: DbAsync, query: SQL, _: type[T], log = true): Option[T] =
  if log: db.log.debug "get_one"

  # Getting row
  let rows = db.get_raw(query, log = false)
  if rows.len > 1: throw fmt"expected single result but got {rows.len} rows"
  if rows.len < 1: return T.none
  let row = rows[0]

  # Getting value
  when T is object | tuple:
    row.postgres_to(T).some
  else:
    if row.len > 1: throw fmt"expected single column row, but got {row.len} columns"
    for _, v in row.fields:
      return v.json_to(T).some
    throw fmt"expected single column row, but got row without columns"

proc get_one*[T](db: DbAsync, query: SQL, TT: type[T], log = true): T =
  db.get_one_optional(query, TT, log = log).get

proc get_one*[T](db: DbAsync, query: SQL, TT: type[T], default: T, log = true): T =
  db.get_one_optional(query, TT, log = log).get(default)


# table_columns ------------------------------------------------------------------------------------
# var table_columns_cache: Table[string, seq[string]] # table_name -> columns
# proc table_columns*(db: DbAsync, table: string): seq[string] =
#   # table columns, fetched from database
#   if table notin table_columns_cache:
#     db.log.debug "get columns"
#     db.with_connection do (conn: auto) -> void:
#       var rows: seq[JsonNode]
#       var columns: db_postgres.DbAsyncColumns
#       for _ in db_postgres.instant_rows(conn, columns, db_postgres.sql(fmt"select * from {table} limit 1"), @[]):
#         discard
#       var names: seq[string]
#       for i in 0..<columns.len: names.add columns[i].name
#       table_columns_cache[table] = names
#   table_columns_cache[table]


# --------------------------------------------------------------------------------------------------
# Test ---------------------------------------------------------------------------------------------
# --------------------------------------------------------------------------------------------------
if is_main_module:
  # No need to manage connections, it will be connected lazily and
  # reconnected in case of connection error
  let db = DbAsync.init
  db.impl("nim_test")
  # db.drop

  # Executing schema befor any other DB query, will be executed lazily before the first use
  db.before sql"""
    drop table if exists dbm_test_users;

    create table dbm_test_users(
      name varchar(100) not null,
      age  integer      not null
    );
  """

  # SQL with `:named` parameters
  db.exec(sql(
    "insert into dbm_test_users (name, age) values (:name, :age)",
    (name: "Jim", age: 30)
  ))

  # Casting to Nim
  assert db.get(
    sql"select name, age from dbm_test_users order by name", tuple[name: string, age: int]
  ) == @[
    (name: "Jim", age: 30)
  ]

  # SQL with `{}` parameters
  assert db.get(
    sql"""select name, age from dbm_test_users where name = {"Jim"}""", tuple[name: string, age: int]
  ) == @[
    (name: "Jim", age: 30)
  ]

  # Count
  assert db.get_one(
    sql"select count(*) from dbm_test_users where age = {30}", int
  ) == 1

  # # Metadata
  # assert db.table_columns("dbm_test_users") == @["name", "age"]

  # Cleaning
  db.exec sql"drop table if exists dbm_test_users"

  # block: # Auto reconnect, kill db and then restart it
  #   while true:
  #     try:
  #       echo db
  #         .get_raw("select name, age from dbm_test_users order by name")
  #         .to((string, int))
  #     except Exception as e:
  #       echo "error"
  #     sleep 1000