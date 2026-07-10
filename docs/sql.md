# SQL

MongrelDB ships a DataFusion-backed SQL engine at `POST /sql`. From V, run SQL
with `db.sql`:

```v
rows := db.exec_sql('SELECT 1') or { panic(err) }
```

This guide covers the SQL surface - DDL, DML, `CREATE TABLE AS SELECT`,
recursive CTEs, and window functions - and when to reach for SQL versus the
native query builder.

---

## How `sql` behaves

`db.exec_sql(sql)` sends `{"sql": "...", "format": "json"}` to `/sql`. It returns
the decoded rows when the daemon replies with a JSON result set, and an empty
array with no error otherwise.

In practice:

- **DDL and DML** (`CREATE TABLE`, `INSERT`, `UPDATE`, `DELETE`) reply with a
  non-JSON status body. `sql` returns an empty array - success is the signal.
- **`SELECT`** returns a JSON array of row objects keyed by column name when the
  server honors the requested JSON format; otherwise an empty array.

Errors are mapped to the same typed error set as everything else: an HTTP 400
or 5xx maps to `MongrelError.query(...)`/`.http_error(...)`; 409 maps to
`.conflict`; and so on. See [errors.md](errors.md).

```v
db.exec_sql("INSERT INTO orders (id, customer, amount) VALUES (99, 'Zoe', 999.0)") or {
	match err {
		mongreldb.MongrelError{...conflict} { println('duplicate row') }
		else { panic(err) }
	}
}
```

## CREATE TABLE

```v
db.exec_sql('CREATE TABLE products (
  id          INT64 PRIMARY KEY,
  name        VARCHAR,
  price       FLOAT64,
  category    VARCHAR,
  in_stock    BOOLEAN
)') or { panic(err) }
```

## INSERT

```v
db.exec_sql("INSERT INTO products (id, name, price, category, in_stock) VALUES (1, 'Widget', 9.99, 'tools', true)") or { panic(err) }
db.exec_sql('INSERT INTO products VALUES (2, "Gadget", 19.99, "tools", true)') or { panic(err) }
```

For bulk inserts, the native batch transaction (`db.begin`) is usually faster
because it stages ops in one round trip without re-parsing SQL.

## UPDATE

```v
db.exec_sql('UPDATE products SET price = 14.99 WHERE id = 1') or { panic(err) }
db.exec_sql("UPDATE orders SET amount = 200.0 WHERE customer = 'Bob'") or { panic(err) }
```

## DELETE

```v
db.exec_sql('DELETE FROM products WHERE in_stock = false') or { panic(err) }
db.exec_sql('DELETE FROM products WHERE id = 2') or { panic(err) }
```

## SELECT

```v
db.exec_sql("SELECT id, name FROM products WHERE category = 'tools' ORDER BY price") or { panic(err) }
db.exec_sql('SELECT category, COUNT(*) AS n FROM products GROUP BY category') or { panic(err) }
```

## CREATE TABLE AS SELECT

Materialize a query result into a new table. Great for snapshots, rollups,
and denormalized aggregates.

```v
db.exec_sql('CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500') or { panic(err) }

db.exec_sql('CREATE TABLE sales_by_customer AS
   SELECT customer, SUM(amount) AS total
   FROM orders
   GROUP BY customer') or { panic(err) }
```

## Recursive CTEs

```v
db.exec_sql('WITH RECURSIVE r(n) AS (
   SELECT 1
   UNION ALL
   SELECT n + 1 FROM r WHERE n < 10
 )
 SELECT n FROM r') or { panic(err) }
```

## Window functions

```v
// Row number within each customer, ordered by amount descending.
db.exec_sql('SELECT id, customer, amount,
       ROW_NUMBER() OVER (PARTITION BY customer ORDER BY amount DESC) AS rn
 FROM orders') or { panic(err) }

// Running total per customer.
db.exec_sql('SELECT id, customer, amount,
       SUM(amount) OVER (PARTITION BY customer ORDER BY id) AS running_total
 FROM orders') or { panic(err) }
```

## When to use SQL vs. the query builder

| Reach for | When |
|-----------|------|
| **`QueryBuilder`** | Point lookups, range scans, bitmap filters, full-text, and vector similarity that map to a native index. Sub-millisecond, no parser overhead. |
| **SQL** | DDL, multi-statement setup, joins, recursive CTEs, window functions, and arbitrary aggregates. |

Mix freely: create tables with SQL, write rows with `db.put`, read them back
with `QueryBuilder`, and run analytics with SQL.

## Next steps

- [queries.md](queries.md) - every native index condition in detail
- [transactions.md](transactions.md) - bulk inserts via batch transactions
- [errors.md](errors.md) - handling SQL execution errors
