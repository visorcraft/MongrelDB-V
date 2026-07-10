# Error Handling

The V client surfaces failures as values of a single, small `MongrelError` enum
rather than as exceptions. Each variant maps to a category of HTTP or transport
failure, so you discriminate with a `match` and recover precisely.

```v
import mongreldb
```

## The error type

Every public function on the client returns `!T` (a V option-result), where
the error is a `MongrelError`:

| Variant             | Meaning                                                          |
|---------------------|------------------------------------------------------------------|
| `http_error(string)` | A transport error or a server status we do not map more narrowly (3xx and most 5xx). |
| `json_error(string)` | The server returned a malformed or unexpected JSON body.         |
| `auth`              | Authentication or authorization failed (HTTP 401 or 403).       |
| `not_found`         | The table or row does not exist (HTTP 404).                      |
| `conflict`          | A constraint violation rolled back a transaction, or a payment-required response (HTTP 402 or 409). |
| `query(string)`     | The request was malformed: a bad condition, projection, or SQL statement (HTTP 400 and other 4xx). |
| `response_too_large`| The response body exceeded `max_response_bytes`.                 |
| `already_committed` | A `Transaction` method was called after `commit` or `rollback`.  |

## How HTTP status maps to an error

| HTTP status            | Error              |
|------------------------|--------------------|
| 200 / 2xx              | (success, no error)|
| 401, 403               | `auth`             |
| 404                    | `not_found`        |
| 402, 409               | `conflict`         |
| 400 and other 4xx      | `query`            |
| 3xx, 5xx, and transport failures | `http_error` |
| Body that is not valid JSON | `json_error`   |

## Matching errors

Use a `match` to handle each case:

```v
db.schema_for('users') or {
	match err {
		mongreldb.MongrelError{...auth} { println('invalid credentials') }
		mongreldb.MongrelError{...not_found} { println('table missing') }
		mongreldb.MongrelError{...query} { println('malformed query') }
		else { println('other error') }
	}
	return
}
```

For the common "log and propagate" shape, a plain `or { panic(err) }` is
enough:

```v
rows := db.query('users').execute() or { panic(err) }
```

## Transaction conflicts

A `commit` runs all staged ops in a single atomic batch. If any op violates a
unique, foreign-key, check, or trigger constraint, the daemon rolls back the
entire batch and returns HTTP 409, which the client surfaces as
`MongrelError.conflict`.

```v
mut txn := db.begin()
txn = txn.txn_put('orders', [mongreldb.Cell{1, mongreldb.int_value(10)}], false) or { panic(err) }

_ = txn.commit('order-batch-001') or {
	match err {
		mongreldb.MongrelError{...conflict} { println('batch rolled back - fix the data and retry') }
		else { panic(err) }
	}
}
```

The idempotency key makes a safe retry possible: re-stage the same ops on a
fresh transaction and commit with the same key. The daemon returns the
original response on duplicate commits.

## Single-use transactions

`commit` and `rollback` both flip an internal flag. Calling any method on the
transaction afterward returns `MongrelError.already_committed`. Start a new
transaction for each batch.

## Retries and idempotency

Network glitches and daemon restarts happen. Pair an idempotency key with a
retry loop for commit. Only retry on `MongrelError.http_error(...)` (transport)
with the same idempotency key. `conflict` and `query` indicate a problem with
the request itself and must be fixed before retrying.

## Common pitfalls

**Swallowing errors with a catch-all.** A bare `or {}` discards the category
and hides bugs. Match with `match` so each branch is explicit.

**Retrying `conflict`.** A conflict means the batch violated a constraint;
replaying the same ops will fail the same way. Fix the offending op, then
retry.

**Forgetting `already_committed`.** A transaction is single-use. If you share
one across function boundaries, make it obvious who calls `commit` or
`rollback`.

## Next steps

- [transactions.md](transactions.md) - atomic batches and idempotency
- [auth.md](auth.md) - where `MongrelError.auth` comes from
