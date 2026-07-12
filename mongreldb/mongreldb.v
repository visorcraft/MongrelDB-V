// mongreldb is the pure-V HTTP client for [MongrelDB].
//
// It talks to a running mongreldb-server daemon's JSON API over the standard
// library `net.http` client - no external dependencies. The surface mirrors
// the MongrelDB PHP and Go clients: typed CRUD, a fluent query builder that
// pushes conditions down to the engine's native indexes, idempotent batch
// transactions, full SQL access, and schema introspection.
//
// Connect with `connect` and a base URL:
//
// ```v
// mut db := mongreldb.connect('http://127.0.0.1:8453', mongreldb.Options{}) or {
//     panic(err)
// }
// ok := db.health() or { panic(err) }
// ```
//
// [MongrelDB]: https://www.MongrelDB.com

module mongreldb

import net.http
import x.json2
import strings
import encoding.base64

// default_base_url is the daemon address used when none is supplied.
pub const default_base_url = 'http://127.0.0.1:8453'

// max_response_bytes caps the size of a response body read from the daemon
// (256 MB). Bodies larger than this are aborted as a `response_too_large` error.
pub const max_response_bytes = u64(268_435_456)

// MongrelErrorKind enumerates the categories of client error. V enums are
// plain integer constants (no per-variant payload), so the human-readable
// detail is carried alongside the kind on the `MongrelError` struct below.
pub enum MongrelErrorKind {
	http_error
	json_error
	auth
	not_found
	conflict
	query
	response_too_large
	already_committed
}

// MongrelError is the typed error returned by every client operation. HTTP
// status codes are mapped to a category: 401/403 -> `.auth`, 404 ->
// `.not_found`, 409 -> `.conflict`, any other non-2xx -> `.query`. Transport
// failures are reported as `.http`, malformed responses as `.json_error`.
// It embeds the builtin `Error` so it satisfies V's `IError` interface and
// can be returned from `!T` functions.
pub struct MongrelError {
	Error
pub:
	kind    MongrelErrorKind
	message string
}

// msg implements the `IError` interface, producing a readable message.
fn (e MongrelError) msg() string {
	if e.message == '' {
		return e.kind.str()
	}
	return '${e.kind.str()}: ${e.message}'
}

// err constructs a `MongrelError` value with the given kind and detail.
fn merr(kind MongrelErrorKind, message string) MongrelError {
	return MongrelError{
		kind:    kind
		message: message
	}
}

// Client is the MongrelDB HTTP client. Create one with `connect`.
@[heap]
pub struct Client {
pub:
	base_url string
	token    string
	username string
	password string
pub mut:
	// last_epoch holds the commit epoch of the most recent successful
	// /kit/txn call, or 0 before any such call.
	last_epoch u64
}

// Options configures a `Client`.
pub struct Options {
pub:
	// token authenticates requests with a Bearer token (--auth-token mode).
	// When set, it takes precedence over basic-auth credentials.
	token string
	// username / password authenticate with HTTP Basic credentials
	// (--auth-users mode). Ignored if `token` is also supplied.
	username string
	password string
}

// Column describes one column in a CREATE TABLE request. It is serialized
// verbatim; the recognized keys are `id`, `name`, `ty`, `primary_key`,
// `nullable`, `enum_variants`, and `default_value`, matching the daemon's
// table-create extractor. `enum_variants` and `default_value` are optional and
// only emitted when set.
pub struct Column {
pub mut:
	id            i64
	name          string
	ty            string
	primary_key   bool
	nullable      bool
	enum_variants []string @[serde: skip_if_empty]
	default_value string   @[serde: skip_if_empty]
	// Set has_default_scalar to send a non-string JSON scalar as default_value.
	has_default_scalar bool
	default_scalar     json2.Any
	default_expr       string @[serde: skip_if_empty]
}

// Cell pairs a column id with its value. The client flattens a list of cells
// to the server's on-wire `[col_id, value, col_id, value, ...]` array before
// sending.
pub struct Cell {
pub:
	id    i64
	value json2.Any
}

// QueryCondition is a normalized (type, params) condition pushed down to a
// native index.
pub struct QueryCondition {
pub:
	condition_type string
	params         map[string]json2.Any
}

// QueryBuilder accumulates a single table query.
pub struct QueryBuilder {
pub mut:
	client     &Client
	table      string
	conditions []QueryCondition
	projection []i64
	has_proj   bool
	limit_val  ?i64
}

// Transaction buffers a sequence of operations and flushes them atomically in
// a single `/kit/txn` request.
pub struct Transaction {
pub mut:
	client    &Client
	ops       []json2.Any
	committed bool
}

// connect returns a `Client` for the daemon at `base_url`. If `base_url`
// is empty, `default_base_url` is used. The base URL has any trailing slash
// trimmed.
pub fn connect(base_url string, options Options) Client {
	url := if base_url == '' {
		default_base_url
	} else {
		base_url.trim_right('/')
	}
	return Client{
		base_url: url
		token:    options.token
		username: options.username
		password: options.password
	}
}

// ── Health & tables ───────────────────────────────────────────────────────

// health reports whether the daemon is reachable and healthy.
pub fn (db Client) health() !bool {
	_ := db.raw_request(.get, '/health', none) or { return err }
	return true
}

pub struct HistoryRetention {
pub:
	history_retention_epochs u64
	earliest_retained_epoch  u64
}

pub fn (db Client) history_retention() !HistoryRetention {
	body := db.raw_request(.get, '/history/retention', none)!
	obj := json2.decode[json2.Any](body)!.as_map()
	hep := obj['history_retention_epochs'] or {
		return merr(.json_error, 'missing history_retention_epochs')
	}
	eep := obj['earliest_retained_epoch'] or {
		return merr(.json_error, 'missing earliest_retained_epoch')
	}
	return HistoryRetention{hep.u64(), eep.u64()}
}

// history_retention_epochs returns the current history retention window size.
pub fn (db Client) history_retention_epochs() !u64 {
	hr := db.history_retention()!
	return hr.history_retention_epochs
}

// earliest_retained_epoch returns the oldest readable epoch.
pub fn (db Client) earliest_retained_epoch() !u64 {
	hr := db.history_retention()!
	return hr.earliest_retained_epoch
}

// set_history_retention_payload builds the JSON body for the
// /history/retention setter. Exposed so wire-shape tests can assert the
// on-wire format without a daemon.
pub fn set_history_retention_payload(epochs u64) string {
	payload := json2.Any({
		'history_retention_epochs': json2.Any(epochs)
	})
	return payload.json_str()
}

pub fn (db Client) set_history_retention_epochs(epochs u64) !HistoryRetention {
	body := db.raw_request(.put, '/history/retention', set_history_retention_payload(epochs))!
	obj := json2.decode[json2.Any](body)!.as_map()
	hep := obj['history_retention_epochs'] or {
		return merr(.json_error, 'missing history_retention_epochs')
	}
	eep := obj['earliest_retained_epoch'] or {
		return merr(.json_error, 'missing earliest_retained_epoch')
	}
	return HistoryRetention{hep.u64(), eep.u64()}
}

// table_names lists all table names in the database.
pub fn (db Client) table_names() ![]string {
	body := db.raw_request(.get, '/tables', none) or { return err }
	value := json2.decode[json2.Any](body) or { return merr(.json_error, 'malformed JSON body') }
	arr := value.as_array()
	mut out := []string{}
	for item in arr {
		s := item.str()
		out << s
	}
	return out
}

// create_table creates a table named `name` with the given columns and
// returns the assigned table id.
pub fn (db Client) create_table(name string, columns []Column) !i64 {
	payload := create_table_payload(name, columns, map[string]json2.Any{})
	return db.send_create_table(payload)
}

// create_table_with_constraints creates a table with the daemon's full
// TableConstraints object, including constraints.checks.
pub fn (db Client) create_table_with_constraints(name string, columns []Column, constraints map[string]json2.Any) !i64 {
	payload := create_table_payload(name, columns, constraints)
	return db.send_create_table(payload)
}

fn (db Client) send_create_table(payload json2.Any) !i64 {
	body := post_json(db, '/kit/create_table', payload) or { return err }
	value := json2.decode[json2.Any](body) or { return merr(.json_error, 'malformed JSON body') }
	obj := value.as_map()
	tid_any := obj['table_id'] or { return merr(.json_error, 'missing table_id') }
	return tid_any.i64()
}

// create_table_payload builds the exact JSON value sent to /kit/create_table.
// An empty constraints map is omitted for backward-compatible wire output.
pub fn create_table_payload(name string, columns []Column, constraints map[string]json2.Any) json2.Any {
	mut col_arr := []json2.Any{}
	for c in columns {
		col_arr << column_to_any(c)
	}
	mut entries := map[string]json2.Any{}
	entries['name'] = json2.Any(name)
	entries['columns'] = json2.Any(col_arr)
	if constraints.len > 0 {
		entries['constraints'] = json2.Any(constraints)
	}
	return json2.Any(entries)
}

// drop_table drops a table by name.
pub fn (db Client) drop_table(name string) ! {
	path := '/tables/' + url_path_escape(name)
	_ := db.raw_request(.delete, path, none) or { return err }
}

// count returns the row count for a table.
pub fn (db Client) count(table string) !i64 {
	path := '/tables/' + url_path_escape(table) + '/count'
	body := db.raw_request(.get, path, none) or { return err }
	value := json2.decode[json2.Any](body) or { return merr(.json_error, 'malformed JSON body') }
	obj := value.as_map()
	c_any := obj['count'] or { return merr(.json_error, 'missing count') }
	return c_any.i64()
}

// ── CRUD (via the Kit typed transaction endpoint) ─────────────────────────

// put inserts a row. `idempotency_key`, if non-empty, makes the commit safe
// to retry. Returns the per-operation result object (the first element of the
// server's results array). Updates `db.last_epoch` with the commit epoch.
pub fn (mut db Client) put(table string, cells []Cell, idempotency_key string) !json2.Any {
	mut inner_entries := map[string]json2.Any{}
	inner_entries['table'] = json2.Any(table)
	inner_entries['cells'] = json2.Any(flatten_cells(cells))
	inner_entries['returning'] = json2.Any(false)
	inner := json2.Any(inner_entries)
	op := json2.Any({
		'put': inner
	})
	ops := [op]
	res := commit_txn(db, ops, idempotency_key) or { return err }
	if res.epoch > 0 {
		db.last_epoch = res.epoch
	}
	if res.results.len == 0 {
		return json2.Any(json2.null)
	}
	return res.results[0]
}

// upsert inserts a row, or updates it on a primary-key conflict. `cells`
// are the insert values; `update_cells`, when non-empty, are the values to
// apply on a conflict (an empty list means DO NOTHING). Updates `db.last_epoch`
// with the commit epoch.
pub fn (mut db Client) upsert(table string, cells []Cell, update_cells []Cell, idempotency_key string) !json2.Any {
	mut entries := map[string]json2.Any{}
	entries['table'] = json2.Any(table)
	entries['cells'] = json2.Any(flatten_cells(cells))
	entries['returning'] = json2.Any(false)
	if update_cells.len > 0 {
		entries['update_cells'] = json2.Any(flatten_cells(update_cells))
	}
	inner := json2.Any(entries)
	op := json2.Any({
		'upsert': inner
	})
	ops := [op]
	res := commit_txn(db, ops, idempotency_key) or { return err }
	if res.epoch > 0 {
		db.last_epoch = res.epoch
	}
	if res.results.len == 0 {
		return json2.Any(json2.null)
	}
	return res.results[0]
}

// delete removes a row by its internal row id. Updates `db.last_epoch` with
// the commit epoch.
pub fn (mut db Client) delete(table string, row_id i64) ! {
	mut inner_entries := map[string]json2.Any{}
	inner_entries['table'] = json2.Any(table)
	inner_entries['row_id'] = json2.Any(row_id)
	inner := json2.Any(inner_entries)
	op := json2.Any({
		'delete': inner
	})
	ops := [op]
	res := commit_txn(db, ops, '') or { return err }
	if res.epoch > 0 {
		db.last_epoch = res.epoch
	}
}

// delete_by_pk removes a row by its primary-key value. Updates `db.last_epoch`
// with the commit epoch.
pub fn (mut db Client) delete_by_pk(table string, pk json2.Any) ! {
	mut inner_entries := map[string]json2.Any{}
	inner_entries['table'] = json2.Any(table)
	inner_entries['pk'] = pk
	inner := json2.Any(inner_entries)
	op := json2.Any({
		'delete_by_pk': inner
	})
	ops := [op]
	res := commit_txn(db, ops, '') or { return err }
	if res.epoch > 0 {
		db.last_epoch = res.epoch
	}
}

// ── Query ─────────────────────────────────────────────────────────────────

// query starts a fluent `QueryBuilder` against `table`.
pub fn (mut db Client) query(table string) QueryBuilder {
	return QueryBuilder{
		client: &db
		table:  table
	}
}

// where_ appends a condition. `cond_type` names the condition (e.g. "pk",
// "column_eq", "range"); `params` is the condition payload, normalized.
pub fn (mut qb QueryBuilder) where_(cond_type string, params map[string]json2.Any) QueryBuilder {
	normalized := normalize_condition(cond_type, params)
	qb.conditions << QueryCondition{
		condition_type: cond_type
		params:         normalized
	}
	return qb
}

// projection requests only the given column ids in each row.
pub fn (mut qb QueryBuilder) projection(column_ids []i64) QueryBuilder {
	qb.projection = column_ids.clone()
	qb.has_proj = true
	return qb
}

// limit_ caps the number of rows returned.
pub fn (mut qb QueryBuilder) limit_(row_limit i64) QueryBuilder {
	qb.limit_val = row_limit
	return qb
}

// execute builds the request, POSTs it to `/kit/query`, decodes the result
// set, and returns the rows.
pub fn (mut qb QueryBuilder) execute() ![]json2.Any {
	mut entries := map[string]json2.Any{}
	entries['table'] = json2.Any(qb.table)
	if qb.conditions.len > 0 {
		mut conds := []json2.Any{}
		for c in qb.conditions {
			mut cond_entries := map[string]json2.Any{}
			cond_entries[c.condition_type] = json2.Any(c.params)
			conds << json2.Any(cond_entries)
		}
		entries['conditions'] = json2.Any(conds)
	}
	if qb.has_proj {
		mut proj := []json2.Any{}
		for id in qb.projection {
			proj << json2.Any(id)
		}
		entries['projection'] = json2.Any(proj)
	}
	if limit := qb.limit_val {
		entries['limit'] = json2.Any(limit)
	}
	payload := json2.Any(entries)
	body := post_json(qb.client, '/kit/query', payload) or { return err }
	value := json2.decode[json2.Any](body) or { return merr(.json_error, 'malformed JSON body') }
	obj := value.as_map()
	rows_any := obj['rows'] or { return merr(.json_error, 'missing rows') }
	return rows_any.as_array()
}

// ── Transactions ──────────────────────────────────────────────────────────

// begin starts a new batch transaction.
pub fn (mut db Client) begin() Transaction {
	return Transaction{
		client: &db
	}
}

// txn_put stages an insert on the transaction.
pub fn (mut t Transaction) txn_put(table string, cells []Cell, returning bool) !Transaction {
	if t.committed {
		return merr(.already_committed, '')
	}
	mut inner_entries := map[string]json2.Any{}
	inner_entries['table'] = json2.Any(table)
	inner_entries['cells'] = json2.Any(flatten_cells(cells))
	inner_entries['returning'] = json2.Any(returning)
	inner := json2.Any(inner_entries)
	op := json2.Any({
		'put': inner
	})
	t.ops << op
	return t
}

// txn_delete stages a delete by row id.
pub fn (mut t Transaction) txn_delete(table string, row_id i64) !Transaction {
	if t.committed {
		return merr(.already_committed, '')
	}
	mut inner_entries := map[string]json2.Any{}
	inner_entries['table'] = json2.Any(table)
	inner_entries['row_id'] = json2.Any(row_id)
	inner := json2.Any(inner_entries)
	op := json2.Any({
		'delete': inner
	})
	t.ops << op
	return t
}

// txn_delete_by_pk stages a delete by primary key.
pub fn (mut t Transaction) txn_delete_by_pk(table string, pk json2.Any) !Transaction {
	if t.committed {
		return merr(.already_committed, '')
	}
	mut inner_entries := map[string]json2.Any{}
	inner_entries['table'] = json2.Any(table)
	inner_entries['pk'] = pk
	inner := json2.Any(inner_entries)
	op := json2.Any({
		'delete_by_pk': inner
	})
	t.ops << op
	return t
}

// txn_count returns the number of staged operations.
pub fn (t Transaction) txn_count() int {
	return t.ops.len
}

// commit sends a batch of staged operations atomically to `/kit/txn` and
// returns the per-operation results array. The originating client's
// `last_epoch` is updated with the commit epoch.
pub fn (mut t Transaction) commit(idempotency_key string) !([]json2.Any, Transaction) {
	if t.committed {
		return merr(.already_committed, '')
	}
	if t.ops.len == 0 {
		t.committed = true
		return []json2.Any{}, t
	}
	res := commit_txn(*t.client, t.ops, idempotency_key) or { return err }
	if res.epoch > 0 {
		t.client.last_epoch = res.epoch
	}
	t.committed = true
	return res.results, t
}

// rollback discards all locally staged operations.
pub fn (mut t Transaction) rollback() !Transaction {
	if t.committed {
		return merr(.already_committed, '')
	}
	t.committed = true
	t.ops.clear()
	return t
}

// ── SQL ───────────────────────────────────────────────────────────────────

// exec_sql executes a SQL statement via the `/sql` endpoint, requesting JSON
// output. The server returns a JSON array of row objects keyed by column
// name. For statements that yield no rows (DDL/DML), an empty list is
// returned.
//
// (Named `exec_sql` rather than `sql` because `sql` became a reserved keyword
// in newer V releases and can no longer be used as a method name.)
pub fn (db Client) exec_sql(sql_text string) ![]json2.Any {
	mut entries := map[string]json2.Any{}
	entries['sql'] = json2.Any(sql_text)
	entries['format'] = json2.Any('json')
	payload := json2.Any(entries)
	body := post_json(db, '/sql', payload) or { return err }
	trimmed := body.trim_space()
	if trimmed == '' {
		return []json2.Any{}
	}
	// JSON format requested; a leading '{' is a single object (e.g. an error
	// envelope), not a row set, so return an empty list. A '[' begins the
	// row array to decode.
	if !trimmed.starts_with('[') {
		return []json2.Any{}
	}
	value := json2.decode[json2.Any](body) or { return merr(.json_error, 'malformed JSON body') }
	return value.as_array()
}

// ── Schema ────────────────────────────────────────────────────────────────

// schema returns the full schema catalog: a map of table-name to descriptor.
pub fn (db Client) schema() !map[string]json2.Any {
	body := db.raw_request(.get, '/kit/schema', none) or { return err }
	value := json2.decode[json2.Any](body) or { return merr(.json_error, 'malformed JSON body') }
	obj := value.as_map()
	tables_any := obj['tables'] or { return map[string]json2.Any{} }
	return tables_any.as_map()
}

// schema_for returns the descriptor for a single table.
pub fn (db Client) schema_for(table string) !json2.Any {
	path := '/kit/schema/' + url_path_escape(table)
	body := db.raw_request(.get, path, none) or { return err }
	return json2.decode[json2.Any](body) or { return merr(.json_error, 'malformed JSON body') }
}

// ── Internal HTTP plumbing ────────────────────────────────────────────────

// TxnResult carries the decoded results and the commit epoch returned by a
// /kit/txn call.
pub struct TxnResult {
pub:
	results []json2.Any
	epoch   u64
}

// commit_txn is the convenience helper used by single-op methods and batch
// transactions. It sends the JSON ops array and returns both the decoded
// results and the commit epoch reported by the server.
fn commit_txn(db Client, ops []json2.Any, idempotency_key string) !TxnResult {
	mut entries := map[string]json2.Any{}
	entries['ops'] = json2.Any(ops)
	if idempotency_key != '' {
		entries['idempotency_key'] = json2.Any(idempotency_key)
	}
	payload := json2.Any(entries)
	body := post_json(db, '/kit/txn', payload) or { return err }
	value := json2.decode[json2.Any](body) or { return merr(.json_error, 'malformed JSON body') }
	obj := value.as_map()

	mut epoch := u64(0)
	if status_any := obj['status'] {
		if status_any.str() == 'committed' {
			if epoch_any := obj['epoch'] {
				epoch = epoch_any.u64()
			}
		}
	}

	results_any := obj['results'] or {
		return TxnResult{
			results: []json2.Any{}
			epoch:   epoch
		}
	}
	return TxnResult{
		results: results_any.as_array()
		epoch:   epoch
	}
}

// post_json performs a POST with a JSON body (Content-Type: application/json)
// and returns the raw response body string.
fn post_json(db Client, path string, payload json2.Any) !string {
	return db.raw_request(.post, path, payload.json_str())
}

// raw_request builds and runs one request against the daemon via `net.http`.
// Non-2xx responses are mapped to typed errors via `map_status`.
fn (db Client) raw_request(method http.Method, path string, body ?string) !string {
	url := db.base_url + '/' + path.trim_left('/')

	mut header := http.new_header()
	header.add(.accept, 'application/json')
	if body != none {
		header.add(.content_type, 'application/json')
	}
	// Bearer token takes precedence over basic auth.
	if db.token != '' {
		header.add_custom('Authorization', 'Bearer ' + db.token) or {}
	} else if db.username != '' {
		creds := db.username + ':' + db.password
		encoded := base64_encode(creds)
		header.add_custom('Authorization', 'Basic ' + encoded) or {}
	}

	// Reject any request string that contains a raw CRLF. HTTP request
	// smuggling relies on injecting \r\n into headers or the request line.
	crlf_check(header) or { return err }

	data := body or { '' }
	resp := http.fetch(url: url, method: method, header: header, data: data) or {
		return merr(.http_error, err.msg())
	}

	// Cap the response: a body larger than max_response_bytes is aborted.
	if u64(resp.body.len) > max_response_bytes {
		return merr(.response_too_large, '')
	}

	code := resp.status_code
	if code < 200 || code >= 300 {
		return map_status(code)!
	}
	return resp.body
}

// crlf_check rejects any request header that contains a raw CR or LF, which
// would let an attacker inject additional headers or split the request.
fn crlf_check(header http.Header) ! {
	for k in header.keys() {
		for val in header.custom_values(k, exact: true) {
			if val.contains('\r') || val.contains('\n') {
				return merr(.query, 'request header contains CRLF')
			}
		}
	}
}

// map_status maps an HTTP status code to a typed `MongrelError`.
fn map_status(code int) !MongrelError {
	if code == 300 || code == 301 || code == 302 || code == 303 || code == 304 || code == 307
		|| code == 308 {
		return merr(.http_error, 'redirect')
	}
	if code == 401 || code == 403 {
		return merr(.auth, '')
	}
	if code == 402 || code == 409 {
		return merr(.conflict, '')
	}
	if code == 404 {
		return merr(.not_found, '')
	}
	if code >= 500 && code <= 599 {
		return merr(.http_error, 'server error ' + code.str())
	}
	return merr(.query, 'status ' + code.str())
}

// ── Cell / column helpers ─────────────────────────────────────────────────

// flatten_cells converts a list of cells to the server's flat
// `[col_id, value, col_id, value, ...]` JSON array.
pub fn flatten_cells(cells []Cell) []json2.Any {
	mut flat := []json2.Any{}
	for c in cells {
		flat << json2.Any(c.id)
		flat << c.value
	}
	return flat
}

// column_to_any serializes a single `Column` into the JSON object the
// daemon's `/kit/create_table` extractor recognizes.
pub fn column_to_any(c Column) json2.Any {
	mut entries := map[string]json2.Any{}
	entries['id'] = json2.Any(c.id)
	entries['name'] = json2.Any(c.name)
	entries['ty'] = json2.Any(c.ty)
	entries['primary_key'] = json2.Any(c.primary_key)
	entries['nullable'] = json2.Any(c.nullable)
	if c.enum_variants.len > 0 {
		mut arr := []json2.Any{}
		for v in c.enum_variants {
			arr << json2.Any(v)
		}
		entries['enum_variants'] = json2.Any(arr)
	}
	if c.default_expr != '' {
		entries['default_expr'] = json2.Any(c.default_expr)
	} else if c.has_default_scalar {
		entries['default_value'] = c.default_scalar
	} else if c.default_value != '' {
		entries['default_value'] = json2.Any(c.default_value)
	}
	return json2.Any(entries)
}

// column_to_json_string serializes a `Column` to a compact JSON string.
// Exposed so wire-shape conformance tests can assert the produced body
// without a live daemon.
pub fn column_to_json_string(c Column) string {
	return column_to_any(c).json_str()
}

// normalize_condition rewrites user-facing param names to the engine's
// canonical condition fields.
pub fn normalize_condition(cond_type string, params map[string]json2.Any) map[string]json2.Any {
	fm_contains := cond_type == 'fm_contains' || cond_type == 'fm_contains_all'
	mut out := map[string]json2.Any{}
	for key, val in params {
		name := if key == 'column' {
			'column_id'
		} else if key == 'min' {
			'lo'
		} else if key == 'max' {
			'hi'
		} else if key == 'min_inclusive' {
			'lo_inclusive'
		} else if key == 'max_inclusive' {
			'hi_inclusive'
		} else if fm_contains && key == 'value' {
			'pattern'
		} else {
			key
		}
		out[name] = val
	}
	return out
}

// ── URL escaping ──────────────────────────────────────────────────────────

// url_path_escape percent-escapes a path segment so table names containing
// '/', '?', '#', or spaces cannot inject extra segments or break routing.
pub fn url_path_escape(seg string) string {
	mut needs_escape := false
	for b in seg.bytes() {
		if !is_unreserved(b) {
			needs_escape = true
			break
		}
	}
	if !needs_escape {
		return seg
	}
	mut out := strings.new_builder(seg.len * 3)
	for b in seg.bytes() {
		if is_unreserved(b) {
			out.write_byte(b)
		} else {
			out.write_byte(u8(`%`))
			out.write_byte(nibble_to_hex(b >> 4))
			out.write_byte(nibble_to_hex(b & 0x0f))
		}
	}
	return out.str()
}

fn is_unreserved(b u8) bool {
	is_upper := b >= `A` && b <= `Z`
	is_lower := b >= `a` && b <= `z`
	is_digit := b >= `0` && b <= `9`
	is_dash := b == `-`
	is_under := b == `_`
	is_dot := b == `.`
	is_tilde := b == `~`
	return is_upper || is_lower || is_digit || is_dash || is_under || is_dot || is_tilde
}

fn nibble_to_hex(n u8) u8 {
	if n < 10 {
		return `0` + n
	}
	return `A` + (n - 10)
}

// base64_encode base64-encodes a string for HTTP Basic auth credentials.
fn base64_encode(input string) string {
	// Use the standard library's base64 encoder from encoding.base64.
	return base64.encode_str(input)
}

// ── Value constructors ────────────────────────────────────────────────────

// int_value builds a JSON integer cell value.
pub fn int_value(i i64) json2.Any {
	return json2.Any(i)
}

// float_value builds a JSON float cell value.
pub fn float_value(f f64) json2.Any {
	return json2.Any(f)
}

// string_value builds a JSON string cell value.
pub fn string_value(s string) json2.Any {
	return json2.Any(s)
}

// bool_value builds a JSON boolean cell value.
pub fn bool_value(b bool) json2.Any {
	return json2.Any(b)
}

// null_value builds a JSON null cell value.
pub fn null_value() json2.Any {
	return json2.Any(json2.null)
}
