// Wire-shape conformance tests for the mongreldb V client.
//
// These are pure (no daemon required): they serialize a `Column` via
// `column_to_json_string`, and assert the exact keys + values appear in the
// outgoing JSON body. They guard the ergonomic extension that adds
// `enum_variants` and `default_value` keys to the per-column payload that
// `/kit/create_table` accepts. A future regression that drops either key would
// silently break user schemas, so the wire shape is asserted here.

module mongreldb_wire_test

import mongreldb
import net.http
import x.json2

fn test_column_to_json_emits_enum_and_default() {
	col := mongreldb.Column{
		id:            1
		name:          'color'
		ty:            'string'
		primary_key:   false
		nullable:      false
		enum_variants: ['a', 'b']
		default_value: 'a'
	}
	s := mongreldb.column_to_json_string(col)
	assert s.contains('"enum_variants":["a","b"]')
	assert s.contains('"default_value":"a"')
}

fn test_create_table_payload_emits_checks() {
	constraints_value := json2.decode[json2.Any]('{"checks":[{"id":1,"name":"ck_color","expr":{"IsNotNull":1}}]}') or {
		assert false
		return
	}
	payload := mongreldb.create_table_payload('colors', [
		mongreldb.Column{
			id:            1
			name:          'color'
			ty:            'enum'
			enum_variants: ['red', 'blue']
			default_value: 'red'
		},
	], constraints_value.as_map()).json_str()
	assert payload.contains('"enum_variants":["red","blue"]')
	assert payload.contains('"default_value":"red"')
	assert payload.contains('"constraints"')
	assert payload.contains('"checks"')
	assert payload.contains('"IsNotNull":1')
}

fn test_column_to_json_omits_absent_enum_and_default() {
	col := mongreldb.Column{
		id:          2
		name:        'amount'
		ty:          'int64'
		primary_key: true
		nullable:    false
	}
	s := mongreldb.column_to_json_string(col)
	// Both keys must be absent so the wire shape matches the baseline.
	assert !s.contains('enum_variants')
	assert !s.contains('default_value')
	assert s.contains('"primary_key":true')
	assert s.contains('"nullable":false')
}

fn test_column_to_json_omits_empty_enum() {
	col := mongreldb.Column{
		id:            3
		name:          'label'
		ty:            'string'
		primary_key:   false
		nullable:      false
		default_value: 'x'
	}
	s := mongreldb.column_to_json_string(col)
	// An explicit empty slice should not be emitted.
	assert !s.contains('enum_variants')
	assert s.contains('"default_value":"x"')
}

fn test_column_to_json_emits_boolean_default() {
	col := mongreldb.Column{
		id:                 4
		name:               'enabled'
		ty:                 'bool'
		has_default_scalar: true
		default_scalar:     json2.Any(true)
	}
	s := mongreldb.column_to_json_string(col)
	assert s.contains('"default_value":true')
}

fn test_column_to_json_emits_number_and_null_defaults() {
	number := mongreldb.column_to_json_string(mongreldb.Column{
		id:                 5
		name:               'retries'
		ty:                 'int64'
		has_default_scalar: true
		default_scalar:     json2.Any(i64(3))
	})
	null_value := mongreldb.column_to_json_string(mongreldb.Column{
		id:                 6
		name:               'optional'
		ty:                 'varchar'
		has_default_scalar: true
		default_scalar:     json2.Any(json2.null)
	})
	assert number.contains('"default_value":3')
	assert null_value.contains('"default_value":null')
}

fn test_column_to_json_emits_dynamic_default_expr() {
	col := mongreldb.Column{
		id:                 5
		name:               'created_at'
		ty:                 'timestamp'
		default_value:      'legacy'
		has_default_scalar: true
		default_scalar:     json2.Any(false)
		default_expr:       'now'
	}
	s := mongreldb.column_to_json_string(col)
	assert s.contains('"default_expr":"now"')
	assert !s.contains('default_value')
}

fn test_column_to_json_emits_literal_now_and_uuid_defaults() {
	now_col := mongreldb.Column{
		id:            7
		name:          'now_literal'
		ty:            'varchar'
		default_value: 'now'
	}
	uuid_col := mongreldb.Column{
		id:            8
		name:          'uuid_literal'
		ty:            'varchar'
		default_value: 'uuid'
	}
	assert mongreldb.column_to_json_string(now_col).contains('"default_value":"now"')
	assert mongreldb.column_to_json_string(uuid_col).contains('"default_value":"uuid"')
}

fn test_set_history_retention_payload_shape() {
	body := mongreldb.set_history_retention_payload(u64(2048))
	assert body.contains('"history_retention_epochs":2048')
}

fn test_url_path_escape_passes_unreserved() {
	// Unreserved characters pass through unchanged.
	assert mongreldb.url_path_escape('orders_2026.1') == 'orders_2026.1'
}

fn test_url_path_escape_encodes_reserved() {
	// Reserved characters are percent-encoded so they cannot inject segments.
	assert mongreldb.url_path_escape('a/b') == 'a%2Fb'
	assert mongreldb.url_path_escape('a b') == 'a%20b'
}

// ── Transport-level retention tests ───────────────────────────────────────
//
// The payload-shape test above only checks the JSON builder. These tests
// drive the client's real `history_retention` and `set_history_retention_epochs`
// methods through the HTTP transport (`Client.raw_request` -> `http.fetch`)
// against an in-process `net.http.Server` mock, so we can assert the actual
// on-wire method, the `/history/retention` path, the PUT body key, the GET
// response keys, and the propagation of a non-2xx response to a typed
// MongrelError. Uses only the standard library - no new dependency.

// shared mock_state carries the last recorded request and the canned response
// between the handler (running on the server thread) and the test thread.
shared mock_state := MockState{}

struct MockState {
mut:
	method    string
	url       string
	body      string
	status    int    = 200
	resp_body string = '{}'
}

// MockHandler is an `net.http.Handler` that records each incoming request
// into `shared mock_state` and returns the canned status+body. V satisfies
// interfaces structurally, so defining `handle` with a matching signature is
// enough; no explicit `impl` clause is needed.
struct MockHandler {}

fn (mut h MockHandler) handle(req http.Request) http.Response {
	// Record the request method/path/body for the test to assert against.
	lock mock_state {
		mock_state.method = req.method.str()
		mock_state.url = req.url
		mock_state.body = req.data
	}
	// Snapshot the canned response under the read lock.
	status, resp_body := rlock mock_state {
		mock_state.status
		mock_state.resp_body
	}
	return http.Response{
		status_code: status
		body:        resp_body
	}
}

// reset_mock installs a fresh canned 200 response and clears the recorded
// request fields, so each test starts from a known state.
fn reset_mock(status int, resp_body string) {
	lock mock_state {
		mock_state.method = ''
		mock_state.url = ''
		mock_state.body = ''
		mock_state.status = status
		mock_state.resp_body = resp_body
	}
}

// last_method/last_url/last_body read the recorded request fields. They use
// the shared-variable read lock so the server thread cannot tear the read.
fn last_method() string {
	return rlock mock_state {
		mock_state.method
	}
}

fn last_url() string {
	return rlock mock_state {
		mock_state.url
	}
}

fn last_body() string {
	return rlock mock_state {
		mock_state.body
	}
}

// start_mock_server binds a `net.http.Server` to a kernel-assigned port on
// 127.0.0.1 and starts `listen_and_serve` in a background thread. The server
// is heap-allocated and returned by reference so it outlives this helper's
// stack frame; the caller must `close()` it when done.
fn start_mock_server() !(&http.Server, string) {
	mut server := &http.Server{
		addr:                 ':0'
		handler:              MockHandler{}
		show_startup_message: false
	}
	// Spawn listen_and_serve on a background thread. The server is
	// heap-allocated so the pointer the caller receives and the pointer the
	// server thread operates on reference the same Server instance.
	spawn server.listen_and_serve()
	// `wait_till_running` blocks until the listener is bound and returns the
	// assigned port number.
	port := server.wait_till_running() or { return error('mock server did not start') }
	return server, 'http://127.0.0.1:${port}'
}

fn test_history_retention_transport_get_method_and_path() {
	reset_mock(200, '{"history_retention_epochs":250,"earliest_retained_epoch":5}')
	server, url := start_mock_server() or {
		assert false
		return
	}
	defer {
		server.close()
	}
	mut db := mongreldb.connect(url, mongreldb.Options{})
	hr := db.history_retention() or {
		assert false
		return
	}
	assert hr.history_retention_epochs == u64(250)
	assert hr.earliest_retained_epoch == u64(5)
	assert last_method() == 'GET'
	assert last_url().contains('/history/retention')
}

fn test_history_retention_transport_put_method_path_and_body_key() {
	reset_mock(200, '{"history_retention_epochs":2048,"earliest_retained_epoch":7}')
	server, url := start_mock_server() or {
		assert false
		return
	}
	defer {
		server.close()
	}
	mut db := mongreldb.connect(url, mongreldb.Options{})
	hr := db.set_history_retention_epochs(u64(2048)) or {
		assert false
		return
	}
	assert hr.history_retention_epochs == u64(2048)
	assert hr.earliest_retained_epoch == u64(7)
	assert last_method() == 'PUT'
	assert last_url().contains('/history/retention')
	// The PUT body must carry the single key the server reads.
	assert last_body().contains('"history_retention_epochs":2048')
}

fn test_history_retention_transport_non_2xx_propagates_as_typed_error() {
	// 500 maps to MongrelErrorKind.http_error in map_status.
	reset_mock(500, '{"error":{"message":"boom"}}')
	server, url := start_mock_server() or {
		assert false
		return
	}
	defer {
		server.close()
	}
	mut db := mongreldb.connect(url, mongreldb.Options{})
	hr := db.history_retention() or {
		// Verify the error category so we know it was mapped, not just any panic.
		assert err.kind == .http_error
		return
	}
	// If we somehow got a value back, the mock did not emit 500 as intended.
	assert hr.history_retention_epochs == u64(0)
	assert false
}

fn test_history_retention_transport_404_propagates_as_not_found() {
	// 404 maps to MongrelErrorKind.not_found.
	reset_mock(404, '{"error":{"message":"no such setting"}}')
	server, url := start_mock_server() or {
		assert false
		return
	}
	defer {
		server.close()
	}
	mut db := mongreldb.connect(url, mongreldb.Options{})
	_ = db.set_history_retention_epochs(u64(1)) or {
		assert err.kind == .not_found
		return
	}
	assert false
}
