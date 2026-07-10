# Queries

The fluent `QueryBuilder` pushes conditions down to MongrelDB's native indexes
for sub-millisecond lookups - bitmap, learned-range, FM-index full text, HNSW
vector similarity, and more. Each condition type maps to one specialized
index; conditions are AND-ed together.

```v
mut q := db.query('orders')
q = q.where_('range', {
	'column': mongreldb.int_value(3)
	'min': mongreldb.float_value(100.0)
	'max': mongreldb.float_value(500.0)
})
q = q.projection([1, 2])
q = q.limit_(100)
rows := q.execute() or { panic(err) }
```

This guide covers every condition type, projection, limits, combining
conditions, and the friendly aliases the builder translates for you.

---

## The basics

Every query starts with `db.query(table)` and ends with `execute`:

| Method | Purpose |
|--------|---------|
| `where_(type, params)` | Add a native condition. Multiple `where_` calls are AND-ed. |
| `projection(column_ids)` | Return only these column ids (omit for all columns). |
| `limit_(n)` | Cap the number of rows. |
| `execute()` | Send and decode. |

The request body produced by the builder matches the daemon's `/kit/query`
shape:

```json
{
  "table": "orders",
  "conditions": [{"range": {"column_id": 3, "lo": 100.0, "hi": 500.0}}],
  "projection": [1, 2],
  "limit": 100
}
```

## Condition types

`params` is a `map[string]json2.Any`. Column references use the numeric
**column id**, never the column name.

### `pk` - exact primary-key match

```v
mut q := db.query('orders')
q = q.where_('pk', {'value': mongreldb.int_value(42)})
_ = q.execute() or { panic(err) }
```

### `range` - integer range (learned-range index)

Inclusive bounds. Omit `lo` (min) or `hi` (max) for an open range.

```v
mut q := db.query('orders')
q = q.where_('range', {
	'column': mongreldb.int_value(3)
	'min': mongreldb.int_value(100)
	'max': mongreldb.int_value(500)
})
_ = q.execute() or { panic(err) }
```

### `range_f64` - float range with inclusive/exclusive control

```v
mut q := db.query('orders')
q = q.where_('range_f64', {
	'column': mongreldb.int_value(3)
	'min': mongreldb.float_value(100.0)
	'max': mongreldb.float_value(500.0)
	'min_inclusive': mongreldb.bool_value(true)
	'max_inclusive': mongreldb.bool_value(false) // (100.0, 500.0]
})
_ = q.execute() or { panic(err) }
```

### `bitmap_eq` - equality on a bitmap-indexed column

```v
mut q := db.query('orders')
q = q.where_('bitmap_eq', {
	'column': mongreldb.int_value(2)
	'value': mongreldb.string_value('Alice')
})
_ = q.execute() or { panic(err) }
```

### `is_null` / `is_not_null` - null checks

```v
mut q := db.query('orders')
q = q.where_('is_null', {'column': mongreldb.int_value(3)})
_ = q.execute() or { panic(err) }
```

### `fm_contains` - full-text substring search (FM-index)

Use `pattern` (the server key) or the friendly `value` alias - both translate
to `pattern` on the wire for FTS conditions.

```v
mut q := db.query('documents')
q = q.where_('fm_contains', {
	'column': mongreldb.int_value(2)
	'pattern': mongreldb.string_value('database performance')
})
q = q.limit_(10)
_ = q.execute() or { panic(err) }
```

### `ann` - dense vector similarity (HNSW)

Approximate nearest-neighbors over a vector column. `k` is the result count.

```v
mut q := db.query('embeddings')
q = q.where_('ann', {
	'column': mongreldb.int_value(2)
	'query': /* your vector value */
	'k': mongreldb.int_value(10)
})
_ = q.execute() or { panic(err) }
```

## Projection (column selection)

`projection([1, 2])` restricts the columns in each returned row. Omit the call
for all columns.

```v
mut q := db.query('orders')
q = q.where_('range', {'column': mongreldb.int_value(3), 'min': mongreldb.int_value(100)})
q = q.projection([1, 2])
_ = q.execute() or { panic(err) }
```

## Limit

`limit_(n)` caps the result.

```v
mut q := db.query('orders')
q = q.where_('range', {'column': mongreldb.int_value(3), 'min': mongreldb.int_value(100)})
q = q.limit_(100)
rows := q.execute() or { panic(err) }
```

## Multiple AND conditions

Chain `where_` calls. Every condition must match; the server intersects the
index results.

```v
mut q := db.query('orders')
q = q.where_('bitmap_eq', {
	'column': mongreldb.int_value(2)
	'value': mongreldb.string_value('Alice')
})
q = q.where_('range', {
	'column': mongreldb.int_value(3)
	'min': mongreldb.int_value(100)
	'max': mongreldb.int_value(500)
})
q = q.projection([1, 3])
q = q.limit_(50)
_ = q.execute() or { panic(err) }
```

## Friendly alias translation

| You write | Sent as | Applies to |
|-----------|---------|------------|
| `column` | `column_id` | all condition types |
| `min` | `lo` | `range`, `range_f64` |
| `max` | `hi` | `range`, `range_f64` |
| `min_inclusive` | `lo_inclusive` | `range_f64` |
| `max_inclusive` | `hi_inclusive` | `range_f64` |
| `value` | `pattern` | `fm_contains`, `fm_contains_all` only |

For arbitrary predicates, joins, and aggregations that the native indexes do
not cover, use SQL instead - see [sql.md](sql.md).
