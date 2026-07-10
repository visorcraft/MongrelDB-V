# Security

This document describes the security properties of the MongrelDB V client and
how to report vulnerabilities.

## Overview

The MongrelDB V client is a pure-V library (no external dependencies) that
talks to `mongreldb-server` over HTTP using the standard library `net.http`
client. The client itself holds no encryption keys and stores no data at rest;
it is a thin request/response layer over the daemon.

## Client security properties

- The client communicates with `mongreldb-server` over plain HTTP. The daemon
  binds to `127.0.0.1` by default — traffic stays on the loopback interface.
  For remote or multi-tenant deployments, terminate TLS in a reverse proxy
  (nginx, Caddy) in front of the daemon.
- The client supports Bearer token and HTTP Basic auth, matching the daemon's
  `--auth-token` and `--auth-users` modes. Credentials are sent only in the
  `Authorization` header and are never logged by the client.
- The native Condition API and query builder accept typed parameters (column
  IDs, typed values) — no string interpolation, no SQL injection surface.
  User-supplied values are serialized as typed JSON, not concatenated into
  queries.
- **CRLF validation:** the client rejects any request whose headers contain a
  raw CR or LF, which prevents HTTP request smuggling via caller-supplied table
  names, SQL, or values.
- **Response limit:** the client caps response bodies at 256 MB
  (`max_response_bytes`); larger bodies are aborted as `response_too_large`
  rather than buffering unbounded data.
- **URL-encoding:** table names are percent-encoded in path segments, so names
  containing `/`, `?`, `#`, or spaces cannot inject extra segments or break
  routing.
- **WARNING — raw SQL:** The `sql()` method sends a raw SQL string to the
  server. It does NOT parameterize or sanitize input, and the client never
  interprets SQL locally. Never interpolate untrusted user input into SQL
  statements — use parameterized queries where the server supports them, or
  validate/escape input yourself. (The native condition API and query builder
  remain type-safe and are not affected.)
- Idempotency keys are caller-supplied opaque strings; the client does not
  derive or store them.

## Daemon security (mongreldb-server)

The client is a consumer of `mongreldb-server`. The daemon's security posture:

- Binds to `127.0.0.1` only — not accessible from other machines.
- **No authentication by default** — any local process can query, write, or
  delete data. Enable `--auth-token` or `--auth-users` for any shared host.
- No TLS — traffic is plaintext on the loopback interface.
- No rate limiting or request size caps.

For remote access or multi-tenant environments, place a reverse proxy (nginx,
Caddy) in front with TLS termination and authentication. Do not expose the
daemon directly to a network.

## Input validation

- The query builder produces typed JSON requests. Invalid column IDs, value
  encodings, and numeric ranges are rejected before any request is sent.
- Server and network errors are mapped to the `MongrelError` enum
  (`auth`, `not_found`, `conflict`, `query`, `http_error`, `json_error`) you
  match with a `match`, not leaked as panics. Library code never throws —
  errors are propagated as `!` results.

## Dependency security

The MongrelDB V client has no runtime dependencies beyond the V standard
library. Report dependency vulnerabilities through GitHub's Dependabot alerts
or the private vulnerability reporting flow below.

## Reporting a vulnerability

**Do not file a public GitHub issue, discussion, or pull request for security
problems.** Report privately through **GitHub's private vulnerability
reporting**:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**.
3. Fill in the advisory form with the details below.

This keeps the report confidential between you and the maintainers until a fix
is ready. Please include as much as you can:

- a description of the issue and its impact,
- step-by-step reproduction steps,
- the MongrelDB V client version, V version, and OS,
- the `mongreldb-server` version if relevant,
- the relevant configuration, error output, or a proof-of-concept,
- a suggested fix or mitigation, if you have one.

### What to expect

- **Acknowledgement** of your report within a few days.
- An initial assessment and, where confirmed, a remediation plan.
- Progress updates through the private advisory thread until the issue is
  resolved.
- Credit for your responsible disclosure in the advisory, unless you prefer to
  remain anonymous.

We ask that you give us a reasonable opportunity to ship a fix before any
public disclosure.
