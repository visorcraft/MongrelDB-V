# Transactions

MongrelDB commits every write through a single atomic transaction endpoint
(`POST /kit/txn`). This guide covers the two ways to use it - a one-shot
single op, and a staged batch - plus idempotency keys for safe retries, typed
constraint-violation handling, and rollback.

The engine enforces `UNIQUE`, foreign-key, check, and trigger constraints at
**commit time**. A violation aborts the entire batch: no op in the batch
becomes visible.

---

## Single puts vs. batch transactions

### Single op: `db.put`

`db.put` is a convenience wrapper that sends a one-op transaction. Use it when
a write is independent and you do not need atomicity across multiple rows.

```v
// One row, one atomic op. The empty string means "no idempotency key".
db.put('orders', [
	mongreldb.Cell{1, mongreldb.int_value(1)},
	mongreldb.Cell{2, mongreldb.string_value('Alice')},
	mongreldb.Cell{3, mongreldb.float_value(99.5)},
], '') or { panic(err) }
```

`db.delete_by_pk` is the same shape: a single-op transaction. (`delete` by
row id is available only on a staged `Transaction`.)

### Batch: `db.begin` + `Transaction`

When several writes must succeed or fail together, stage them on a
`Transaction` and commit once. All ops go to the server in a single HTTP
request and commit atomically.

```v
mut txn := db.begin()
txn = txn.txn_put('orders', [
	mongreldb.Cell{1, mongreldb.int_value(10)},
	mongreldb.Cell{2, mongreldb.string_value('Dave')},
], false) or { panic(err) }
txn = txn.txn_put('orders', [
	mongreldb.Cell{1, mongreldb.int_value(11)},
	mongreldb.Cell{2, mongreldb.string_value('Eve')},
], false) or { panic(err) }
txn = txn.txn_delete_by_pk('orders', mongreldb.int_value(2)) or { panic(err) }

results, mut committed := txn.commit('') or { panic(err) }
println('committed ${results.len} ops')
```

The last argument to `txn_put` is `returning`. Set it to `true` to have the
daemon echo the written row back in the result.

`txn_delete(table, row_id)` stages a delete by the internal row id;
`txn_delete_by_pk(table, pk)` stages a delete by primary-key value.

## Idempotency keys for safe retries

Networks drop requests and daemons crash after committing but before replying.
An idempotency key makes a commit safe to retry: the daemon remembers the key
and replays the **original** result on a duplicate commit, even across
restarts.

Pass the key as the argument to `commit` (or to `db.put`):

```v
fn charge(db mongreldb.Client, order_id i64) {
	mut txn := db.begin()
	txn = txn.txn_put('charges', [
		mongreldb.Cell{1, mongreldb.int_value(order_id)},
		mongreldb.Cell{2, mongreldb.float_value(199.0)},
	], false) or { panic(err) }

	// Use a stable, business-meaningful key derived from the request.
	key := 'charge:${order_id}'
	_ = txn.commit(key) or { panic(err) }
}
```

Rules for keys:

- Any non-empty string works. Prefer content-derived, globally-unique values.
- The empty string disables idempotency - a retry will commit again.
- The key scopes the **entire batch**, not individual ops. Reuse the exact
  same ops and key together when retrying.

## Handling constraint violations

Constraint violations arrive as HTTP 409, mapped to `MongrelError.conflict`.

```v
mut txn := db.begin()
txn = txn.txn_put('orders', [mongreldb.Cell{1, mongreldb.int_value(1)}], false) or { panic(err) } // duplicate PK

_ = txn.commit('') or {
	match err {
		mongreldb.MongrelError{...conflict} { println('constraint violation (batch rolled back)') }
		else { panic(err) }
	}
}
```

The engine already discarded the entire batch - there is nothing to undo
server-side.

## Rollback after failure

There are two notions of "rollback":

1. **Server-side.** When `commit` returns `MongrelError.conflict`, the engine
   has already discarded the entire batch. Nothing was written; there is no
   server rollback to perform.
2. **Client-side.** `txn.rollback()` clears the locally staged ops. Call it to
   release the `Transaction` when you decide not to commit (for example, after
   a validation error in your own code, before ever sending).

```v
mut txn := db.begin()
txn = txn.txn_put('orders', [mongreldb.Cell{1, mongreldb.int_value(1)}], false) or { panic(err) }

if !business_rule_ok() {
	// Throw the staged ops away locally. Nothing has been sent to the daemon.
	txn = txn.rollback() or { panic(err) }
	return
}

_ = txn.commit('') or {
	match err {
		mongreldb.MongrelError{...conflict} {} // server already rolled back
		else { panic(err) }
	}
}
```

`rollback` and `commit` both return `MongrelError.already_committed` if the
transaction was already committed. Treat that as a programming error to fix
upstream, not a runtime condition to silence.

## Summary

| Goal | Use |
|------|-----|
| One independent write | `db.put` / `delete_by_pk` |
| Several writes that must commit together | `db.begin` + `commit` |
| Retry safely after a network blip | `commit(key)` with a stable key |
| Detect a constraint violation | match `MongrelError.conflict` from `commit` |
| Abort before sending | `txn.rollback()` |

See [errors.md](errors.md) for the full error set and [queries.md](queries.md)
for read patterns.
