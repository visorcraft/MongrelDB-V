# Authentication & Authorization

A `mongreldb-server` daemon runs in one of three modes:

1. **Open** (default) - no auth required.
2. **Bearer token** (`--auth-token <TOKEN>`) - every request must carry an
   `Authorization: Bearer <TOKEN>` header.
3. **HTTP Basic** (`--auth-users`) - every request must carry an
   `Authorization: Basic <base64(user:pass)>` header.

The V client supports all three through the `Options` struct passed to
`mongreldb.connect`. This guide shows each mode and how to manage users and
roles via SQL when the server is in Basic mode.

---

## Bearer token mode

Start the daemon with a token:

```sh
mongreldb-server --auth-token s3cret-token
```

Connect with `token`. The token is sent as `Authorization: Bearer ...` on every
request.

```v
mut db := mongreldb.connect('http://127.0.0.1:8453', mongreldb.Options{
	token: 's3cret-token'
})

db.health() or { panic(err) }
println('healthy')
```

A missing or wrong token surfaces as `MongrelError.auth` (HTTP 401/403).

## Basic auth mode

Start the daemon with a users file or inline users:

```sh
mongreldb-server --auth-users
```

Connect with `username` / `password`:

```v
mut db := mongreldb.connect('http://127.0.0.1:8453', mongreldb.Options{
	username: 'admin'
	password: 's3cret'
})
```

The client base64-encodes `username:password` and sets `Authorization: Basic ...`
on every request.

## Token takes precedence

If you supply both, `token` wins and Basic credentials are ignored.

```v
mut db := mongreldb.connect('http://127.0.0.1:8453', mongreldb.Options{
	username: 'fallback'
	password: 'user'
	token: 'overrides-everything'
})
```

## User and role management via SQL

When the daemon is in Basic auth mode, users and roles live in the catalog and
are managed with SQL. Run these statements through `db.sql`.

### Create a user

```v
db.exec_sql("CREATE USER alice WITH PASSWORD 'hunter2'") or { panic(err) }
```

### Alter a user

```v
db.exec_sql("ALTER USER alice WITH PASSWORD 'new-password'") or { panic(err) }
db.exec_sql('ALTER USER alice ADMIN') or { panic(err) }
```

### Drop a user

```v
db.exec_sql('DROP USER alice') or { panic(err) }
```

### Roles and grants

```v
db.exec_sql('CREATE ROLE analyst') or { panic(err) }
db.exec_sql('GRANT SELECT ON orders TO analyst') or { panic(err) }
db.exec_sql('GRANT analyst TO alice') or { panic(err) }
db.exec_sql('REVOKE SELECT ON orders FROM analyst') or { panic(err) }
db.exec_sql('DROP ROLE analyst') or { panic(err) }
```

## Common pitfalls

**Auth errors look like other errors without a typed match.** A 401/403 maps
to `MongrelError.auth`; a 404 maps to `.not_found`. Always discriminate with a
`match` rather than string-matching messages.

**Forgetting to set auth in production.** A client built with default
`Options` sends no credentials. Against an auth-enabled daemon, every call
returns `MongrelError.auth`. Centralize client construction so the auth option
is never accidentally dropped.

**Token in version control.** Put secrets in the environment, a secret
manager, or a file outside the repo. Never commit a real token.

## Next steps

- [errors.md](errors.md) - `MongrelError.auth` and the rest of the typed error set
- [quickstart.md](quickstart.md) - the full end-to-end walkthrough
