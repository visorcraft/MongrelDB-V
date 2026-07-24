# Quickstart

Zero to a running MongrelDB V program in fifteen minutes. This guide assumes a
fresh machine and walks through installing the prerequisites, starting the
daemon, and writing, running, and understanding a complete program.

---

## 1. Prerequisites

You need two things installed: the V toolchain and a `mongreldb-server` daemon.

### Install V

Verify it:

```sh
v version
# V 0.x ...
```

If you do not have it, install from <https://github.com/vlang/v/releases> or
build from source per <https://vlang.io/>.

### Install mongreldb-server

Fetch a prebuilt server binary from the
[MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases):

```sh
mkdir -p bin
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.64.6/mongreldb-server-linux-x64
chmod +x bin/mongreldb-server
```

Verify it runs:

```sh
./bin/mongreldb-server --version
```

## 2. Start the daemon

By default `mongreldb-server` listens on `http://127.0.0.1:8453` and stores
data in the current working directory.

```sh
mkdir -p /tmp/mdb-data && cd /tmp/mdb-data
/path/to/mongreldb-server
```

In another terminal, sanity-check it:

```sh
curl http://127.0.0.1:8453/health
# ok
```

Leave the daemon running for the rest of this guide.

## 3. Create a project and pull in the client

Copy `mongreldb/mongreldb.v` into your project's module path (e.g.
`myproject/mongreldb/mongreldb.v`) or add this repo as a git submodule.

## 4. Write your first program

Create `main.v`:

```v
import mongreldb

fn main() {
	// 1. Connect to the daemon. Empty URL falls back to http://127.0.0.1:8453.
	mut db := mongreldb.connect('http://127.0.0.1:8453', mongreldb.Options{})

	// 2. Health check before doing anything else.
	db.health() or { panic('daemon unreachable: ${err}') }

	// 3. Create a table. Each column has a stable numeric id, a name, a type,
	//    and optional constraint-style fields (`enum_variants`, `default_value`).
	//    The primary_key column is the row identity.
	tid := db.create_table('orders', [
		mongreldb.Column{id: 1, name: 'id', ty: 'int64', primary_key: true},
		mongreldb.Column{id: 2, name: 'customer', ty: 'varchar'},
		mongreldb.Column{id: 3, name: 'amount', ty: 'float64'},
		// Enum column: only the four listed values are accepted.
		mongreldb.Column{id: 4, name: 'status', ty: 'varchar', enum_variants: ['pending', 'shipped', 'delivered', 'cancelled']},
		// Enum column with a default applied when the cell is omitted.
		mongreldb.Column{id: 5, name: 'currency', ty: 'varchar', enum_variants: ['USD', 'EUR', 'GBP'], default_value: 'USD'},
	]) or { panic(err) }
	println('created table id: ${tid}')

	// 4. Insert rows. Cells pair column id -> value.
	db.put('orders', [
		mongreldb.Cell{1, mongreldb.int_value(1)},
		mongreldb.Cell{2, mongreldb.string_value('Alice')},
		mongreldb.Cell{3, mongreldb.float_value(99.5)},
		mongreldb.Cell{4, mongreldb.string_value('pending')},
		mongreldb.Cell{5, mongreldb.string_value('USD')},
	], '') or { panic(err) }
	db.put('orders', [
		mongreldb.Cell{1, mongreldb.int_value(2)},
		mongreldb.Cell{2, mongreldb.string_value('Bob')},
		mongreldb.Cell{3, mongreldb.float_value(200.0)},
		mongreldb.Cell{4, mongreldb.string_value('shipped')},
		mongreldb.Cell{5, mongreldb.string_value('EUR')},
	], '') or { panic(err) }

	// 5. Query with a native index condition. The range index serves this in
	//    sub-millisecond.
	mut q := db.query('orders')
	q = q.where_('range', {
		'column': mongreldb.int_value(3)
		'min':    mongreldb.float_value(50.0)
		'max':    mongreldb.float_value(150.0)
	})
	q = q.projection([1, 2])
	q = q.limit_(100)
	rows := q.execute() or { panic(err) }
	println('rows: ${rows.len}')

	// 6. Count the rows.
	n := db.count('orders') or { panic(err) }
	println('total rows: ${n}')
}
```

Build and run it:

```sh
v run main.v
```

You should see:

```
created table id: 1
rows: 1
total rows: 2
```

## 5. What each part does

| Code | What it does |
|------|--------------|
| `mongreldb.connect(url, options)` | Builds an HTTP client targeting one daemon. Backed by `net.http`. |
| `db.health()` | GET `/health`; succeeds when the daemon answers. |
| `db.create_table(name, columns)` | POST `/kit/create_table`. Column `id`s are the on-wire identifiers; use them everywhere else. `enum_variants` and `default_value` are optional and emitted only when set. |
| `db.put(table, cells, key)` | Single-op transaction: POST `/kit/txn` with one `put` op. `cells` is flattened to `[col_id, val, ...]`. |
| `db.query(table) \|> .where_(...)` | Builds a `/kit/query` body. `where_` pushes a condition down to a native index. |
| `.projection([1, 2])` | Server returns only those column ids, saving bandwidth. |
| `.limit_(100)` | Caps the result. |
| `.execute()` | Sends the query and decodes the `rows` array. |
| `db.count(table)` | GET `/tables/{name}/count`. |

## 6. Constrained columns

`Column` accepts two optional constraint-style fields that are forwarded to the
daemon verbatim. They are omitted from the JSON body when empty, so existing
schemas that don't set them produce an identical payload.

| Field | Type | Effect |
|-------|------|--------|
| `enum_variants` | `[]string` | Restrict the column to one of the listed string values. The engine rejects writes outside the set with `MongrelError.conflict`. |
| `default_value` | `string` | String default applied when the cell is omitted on a `put`. Literal values `"now"` and `"uuid"` are sent as static strings; use `default_expr` for dynamic `now`/`uuid` defaults. |
| `has_default_scalar` + `default_scalar` | `bool` + `json2.Any` | Non-string JSON scalar default. Caller must supply the scalar type expected by the column. Sent as `default_value`. |
| `default_expr` | `string` | Dynamic `now` or `uuid`. Takes precedence over scalar and string defaults. |

Both fields compose. A column can be a plain string, an enum-only string, a
string with a default, or an enum with a default:

```v
// Plain string - no constraints, no extra keys on the wire.
mongreldb.Column{id: 2, name: 'customer', ty: 'varchar'},

// Enum only - writes outside the set are rejected at commit time.
mongreldb.Column{id: 4, name: 'status', ty: 'varchar', enum_variants: ['pending', 'shipped', 'delivered', 'cancelled']},

// Enum with a default - the engine fills in "USD" when the cell is omitted.
mongreldb.Column{id: 5, name: 'currency', ty: 'varchar', enum_variants: ['USD', 'EUR', 'GBP'], default_value: 'USD'},

// Integer default - sent as a JSON number, not a string.
mongreldb.Column{
	id:                 6
	name:               'retries'
	ty:                 'int64'
	has_default_scalar: true
	default_scalar:     json2.Any(i64(3))
},

// Dynamic default_expr takes precedence over default_value.
mongreldb.Column{
	id:           7
	name:         'created_at'
	ty:           'timestamp'
	default_expr: 'now'
},
```

An empty `enum_variants` slice is also omitted, so `[]string{}` and omitting the
field produce identical wire shapes.

## 7. History retention and time travel

MongrelDB keeps a durable MVCC history window. The size of the window is measured
in epochs and controls how far back `AS OF EPOCH` queries can read. The client
exposes three pieces of the API:

- `db.history_retention() !HistoryRetention` returns the current window and the
  earliest epoch that is still readable.
- `db.set_history_retention_epochs(epochs) !HistoryRetention` changes the
  durable window. Increasing retention cannot bring back epochs that have
  already been garbage-collected.
- `db.last_epoch` is updated after every successful Kit transaction (`put`,
  `upsert`, `delete`, `delete_by_pk`, and `Transaction.commit`). It holds the
  commit epoch of the most recent write, which is a convenient pinning point
  for time-travel reads.

```v
// Widen the history window.
updated := db.set_history_retention_epochs(u64(10000)) or { panic(err) }
println(updated.history_retention_epochs)
println(updated.earliest_retained_epoch)

// Pin a read to the epoch of the last committed write.
db.put('orders', [mongreldb.Cell{1, mongreldb.int_value(1)}], '') or { panic(err) }
rows := db.exec_sql('SELECT id FROM orders AS OF EPOCH ${db.last_epoch}') or { panic(err) }
```

## 8. Common pitfalls

**Using the column name instead of the column id.** Every on-wire API uses the
numeric `id` from `create_table`, never the `name`. The query builder's `column`
alias maps to the server's `column_id` - pass the integer id, not the string
name.

**Treating a single `put` as non-transactional.** `put` is a one-op
transaction. A unique constraint violation surfaces as
`MongrelError.conflict` (HTTP 409), not as a silent no-op.

**Calling `commit` twice on the same `Transaction`.** The second call returns
`MongrelError.already_committed`. Start a fresh `db.begin()` for each logical
unit of work.

**Pointing at a daemon that requires auth.** If the daemon was started with
`--auth-token` or `--auth-users`, every call returns `MongrelError.auth` unless
you set `token` or `username`/`password` in `Options`. See [auth.md](auth.md).

## Next steps

- [transactions.md](transactions.md) - atomic batches, idempotency, retries
- [queries.md](queries.md) - every native index condition
- [sql.md](sql.md) - recursive CTEs, window functions, `CREATE TABLE AS SELECT`
- [auth.md](auth.md) - bearer tokens, basic auth, user/role management
- [errors.md](errors.md) - the full typed error set and recovery patterns
