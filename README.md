<p align="center">
  <img src="assets/mongrel.png" alt="MongrelDB logo" width="250" />
</p>

<h1 align="center">MongrelDB V Client</h1>

<p align="center">
  <b>Pure V client for MongrelDB - embedded+server database with SQL, vector search, full-text search, and AI-native retrieval.</b>
  <br />
  No external dependencies - built on the standard library <code>net.http</code>. The API mirrors the MongrelDB PHP and Go clients.
</p>

<p align="center">
  <a href="#license"><img src="https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg" alt="License" /></a>
  <a href="https://github.com/visorcraft/MongrelDB-V/actions/workflows/ci.yml"><img src="https://github.com/visorcraft/MongrelDB-V/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="https://vlang.io/"><img src="https://img.shields.io/badge/V-0.x-5d87bf.svg" alt="V" /></a>
</p>

## Package

| Surface | Module | Install |
|---|---|---|
| V client | `mongreldb` | drop `mongreldb/mongreldb.v` into your module path |

## Requirements

- **V (weekly release)** - this client uses `x.json2` for typed JSON
- A running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB) daemon

## What It Provides

- **Typed CRUD** over the Kit transaction endpoint: `put` (with optional idempotency keys for safe retries) and `delete_by_pk`, plus batched `put`/`delete`/`delete_by_pk` and `upsert`-style insert-or-update.
- **Fluent query builder** that pushes conditions down to the engine's specialized indexes for sub-millisecond lookups: bitmap equality/IN, learned-range, null checks, FM-index full-text search, HNSW vector similarity (`ann`), and sparse vector match. Friendly aliases (`column` -> `column_id`, `min`/`max` -> `lo`/`hi`) are translated to the server's on-wire keys.
- **Idempotent batch transactions** - operations staged locally and committed atomically, with the engine enforcing unique, foreign-key, and check constraints at commit time. Idempotency keys return the original response on duplicate commits, even after a crash.
- **Full SQL access** through the DataFusion-backed `/sql` endpoint (JSON format requested): recursive CTEs, window functions, `CREATE TABLE AS SELECT`, materialized views, and multi-statement execution.
- **Schema management**: typed table creation, full schema catalog, and per-table descriptors.
- **Typed errors**: `auth` (401/403), `not_found` (404), `conflict` (409), `query` (everything else non-2xx), `http_error` (transport), and `json_error` (malformed response) - a single `MongrelError` enum you match on.

## Examples

Task-focused, commented guides live in [`docs/`](docs):

- [Quickstart](docs/quickstart.md) - install, start the daemon, write and run a complete program.
- [Transactions](docs/transactions.md) - batch commits, idempotency keys, constraint handling.
- [Queries](docs/queries.md) - every native condition type and the index it pushes down to.
- [SQL](docs/sql.md) - recursive CTEs, window functions, advanced SQL.
- [Authentication](docs/auth.md) - Bearer token, HTTP Basic, and open modes.
- [Errors](docs/errors.md) - the typed error set and recovery patterns.

## Quick Example

```v
import mongreldb
import x.json2

fn main() {
	mut db := mongreldb.connect('http://127.0.0.1:8453', mongreldb.Options{})

	// Create a table. Column ids are stable on-wire identifiers.
	constraints := json2.decode[json2.Any]('{"checks":[{"id":1,"name":"ck_customer","expr":{"IsNotNull":2}}]}')!
	tid := db.create_table_with_constraints('orders', [
		mongreldb.Column{id: 1, name: 'id', ty: 'int64', primary_key: true},
		mongreldb.Column{id: 2, name: 'customer', ty: 'varchar'},
		mongreldb.Column{id: 3, name: 'amount', ty: 'float64'},
	], constraints.as_map()) or { panic(err) }

	// Insert rows (cells pair column id -> value).
	db.put('orders', [
		mongreldb.Cell{1, mongreldb.int_value(1)},
		mongreldb.Cell{2, mongreldb.string_value('Alice')},
		mongreldb.Cell{3, mongreldb.float_value(99.5)},
	], '') or { panic(err) }

	// Query with a native index condition (learned-range index).
	mut q := db.query('orders')
	q = q.where_('range', {
		'column': mongreldb.int_value(3)
		'min': mongreldb.float_value(100.0)
	})
	q = q.limit_(100)
	rows := q.execute() or { panic(err) }
	println('rows: ${rows.len}')

	n := db.count('orders') or { panic(err) }
	println('count: ${n}') // 1
}
```

## Authentication

```v
// Bearer token (--auth-token mode)
db := mongreldb.connect('http://127.0.0.1:8453', mongreldb.Options{
	token: 'my-secret-token'
})

// HTTP Basic (--auth-users mode)
db := mongreldb.connect('http://127.0.0.1:8453', mongreldb.Options{
	username: 'admin'
	password: 's3cret'
})
```

A Bearer token takes precedence over Basic credentials when both are supplied.

## Batch transactions

Operations are staged locally and committed atomically. The engine enforces
unique, foreign-key, and check constraints at commit time.

```v
mut txn := db.begin()
txn = txn.txn_put('orders', [mongreldb.Cell{1, mongreldb.int_value(10)}], false) or { panic(err) }

// atomic - all or nothing
results, mut committed := txn.commit('') or {
	// A constraint violation surfaces as a MongrelError.conflict.
	panic(err)
}
```

## Native query builder

Conditions push down to the engine's specialized indexes. The builder accepts
friendly aliases that are translated to the server's on-wire keys: `column`
(-> `column_id`), `min`/`max` (-> `lo`/`hi`).

```v
// Bitmap equality (low-cardinality columns).
mut q1 := db.query('orders')
q1 = q1.where_('bitmap_eq', {
	'column': mongreldb.int_value(2)
	'value': mongreldb.string_value('Alice')
})
_ = q1.execute() or { panic(err) }

// Range query (learned-range index).
mut q2 := db.query('orders')
q2 = q2.where_('range', {
	'column': mongreldb.int_value(3)
	'min': mongreldb.float_value(50.0)
	'max': mongreldb.float_value(150.0)
})
q2 = q2.limit_(100)
_ = q2.execute() or { panic(err) }
```

## SQL

```v
db.exec_sql("INSERT INTO orders (id, customer, amount) VALUES (99, 'Zoe', 999.0)") or { panic(err) }
db.exec_sql('CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500') or { panic(err) }

// Recursive CTEs and window functions
cte := 'WITH RECURSIVE r(n) AS (
  SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<10
) SELECT n FROM r'
db.exec_sql(cte) or { panic(err) }
```

The `/sql` endpoint is requested in JSON format. For statements that yield no
rows (DDL/DML) `sql` returns an empty array with no error.

## Error handling

Every non-2xx response is mapped to a typed error. Match on the variant.

```v
res := db.schema_for('missing_table') or {
	if err is mongreldb.MongrelError {
		e := err as mongreldb.MongrelError
		match e.kind {
			.not_found { println('not found') }
			.conflict { println('constraint violation') }
			.auth { println('not authorized') }
			else { println('query/server error') }
		}
	}
	return
}
```

| HTTP status | Error |
|-------------|-------|
| 401, 403 | `.auth` |
| 404 | `.not_found` |
| 409 | `.conflict` |
| other non-2xx | `.query` |
| transport failure | `.http_error` |
| malformed JSON | `.json_error` |

## API reference

Methods marked `mut` require the client variable to be declared `mut db := ...`;
they may update `db.last_epoch` from the server's commit epoch.

### `mongreldb`

| Method | Description |
|--------|-------------|
| `connect(url, options) Client` | Construct a client (url defaults to `http://127.0.0.1:8453`) |
| `health() !bool` | Check daemon health |
| `table_names() ![]string` | List table names |
| `create_table(name, columns) !i64` | Create a table; returns the table id |
| `create_table_with_constraints(name, columns, constraints) !i64` | Create a table with checks/unique/FK constraints |
| `drop_table(name) !` | Drop a table |
| `count(table) !i64` | Row count |
| `mut put(table, cells, key) !json2.Any` | Insert a row |
| `mut upsert(table, cells, update_cells, key) !json2.Any` | Insert or update on PK conflict |
| `mut delete(table, row_id) !` | Delete by row id |
| `mut delete_by_pk(table, pk) !` | Delete by primary key |
| `mut query(table) QueryBuilder` | Start a native query |
| `mut begin() Transaction` | Start a batch |
| `exec_sql(sql) ![]json2.Any` | Execute SQL |
| `schema() !map[string]json2.Any` | Full schema catalog |
| `schema_for(table) !json2.Any` | Single-table descriptor |
| `history_retention() !HistoryRetention` | Current retention window and earliest retained epoch |
| `set_history_retention_epochs(epochs) !HistoryRetention` | Set the durable MVCC window |
| `last_epoch` (field) | Commit epoch of the most recent `/kit/txn` |

### `QueryBuilder`

| Method | Description |
|--------|-------------|
| `where_(type, params) QueryBuilder` | Add a native condition (AND-ed) |
| `projection(column_ids) QueryBuilder` | Set column projection |
| `limit_(n) QueryBuilder` | Set row limit |
| `offset(n) QueryBuilder` | Skip matching rows before the limit |
| `execute() ![]json2.Any` | Run the query; returns the rows |

### `Transaction`

| Method | Description |
|--------|-------------|
| `txn_put(table, cells, returning) !Transaction` | Stage an insert |
| `txn_delete(table, row_id) !Transaction` | Stage a delete by row id |
| `txn_delete_by_pk(table, pk) !Transaction` | Stage a delete by primary key |
| `txn_count() int` | Number of staged operations |
| `commit(key) !([]json2.Any, Transaction)` | Commit atomically |
| `rollback() !Transaction` | Discard all operations |

## Building and testing

The test suite is a live integration suite: it boots a real `mongreldb-server`
daemon and exercises the full client surface against it. It skips cleanly when
no daemon is available.

```sh
# Run the offline unit tests (wire-shape conformance) + live suite (self-skips
# without a daemon).
v test .

# Run the examples.
v run examples/basic_crud.v
v run examples/query_builder.v
v run examples/transactions.v
```

Fetch a prebuilt server binary from the [MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases):

```sh
mkdir -p bin
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.60.2/mongreldb-server-linux-x64
chmod +x bin/mongreldb-server
```

### Using the client in your project

Copy `mongreldb/mongreldb.v` (and its module) into your project's module path, or add
this repo as a git submodule and import it.

## History retention

Use `history_retention`, `set_history_retention_epochs`, and `last_epoch` with
MongrelDB 0.48.0+. The retention window controls how far back `AS OF EPOCH`
time-travel queries can read; increasing it cannot bring back history that has
already been pruned.

```v
// Inspect the current durable MVCC window.
ret := db.history_retention() or { panic(err) }
println(ret.history_retention_epochs)  // e.g. 1024
println(ret.earliest_retained_epoch)   // e.g. 3

// Widen the window. The response contains the updated values.
updated := db.set_history_retention_epochs(u64(1000)) or { panic(err) }
println(updated.history_retention_epochs)  // 1000

// After a Kit transaction write, last_epoch holds the commit epoch.
db.put('orders', [mongreldb.Cell{1, mongreldb.int_value(1)}], '') or { panic(err) }
rows := db.exec_sql('SELECT id FROM orders AS OF EPOCH ${db.last_epoch}') or { panic(err) }
```

## Contributing

Contributions are welcome. Please:

1. Open an issue first for non-trivial changes.
2. Add focused tests near your change - the suite must stay green.
3. Keep the client a thin wrapper over `mongreldb-server`.

## License

Dual-licensed under the **MIT License** or the **Apache License, Version 2.0**,
at your option. See [MIT](LICENSE-MIT) OR [Apache-2.0](LICENSE-APACHE) for the full text.

`SPDX-License-Identifier: MIT OR Apache-2.0`
