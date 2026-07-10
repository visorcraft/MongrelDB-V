# MongrelDB V Client - Guides

Task-focused guides for the pure-V MongrelDB HTTP client. For the full API
surface in one place, see the root [README](../README.md).

| Guide | What it covers |
|-------|----------------|
| [quickstart.md](quickstart.md) | Install, start the daemon, write and run your first program, common pitfalls |
| [transactions.md](transactions.md) | Single puts vs. batch transactions, idempotency keys, constraint handling, rollback |
| [queries.md](queries.md) | Every native index condition: PK, range, bitmap, full-text, vector similarity |
| [sql.md](sql.md) | CREATE TABLE, INSERT/UPDATE/DELETE/SELECT, CREATE TABLE AS SELECT, recursive CTEs, window functions |
| [auth.md](auth.md) | Bearer token and Basic auth modes, user/role management via SQL |
| [errors.md](errors.md) | The typed error set, HTTP-status mapping, recovery patterns |

## Where to start

- **New to the client?** Start with [quickstart.md](quickstart.md).
- **Writing data?** Read [transactions.md](transactions.md).
- **Reading data?** Read [queries.md](queries.md) for indexed lookups, or
  [sql.md](sql.md) for joins, CTEs, and analytics.
- **Securing a deployment?** Read [auth.md](auth.md).
- **Debugging a failure?** Read [errors.md](errors.md).
