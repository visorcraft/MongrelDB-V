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

fn test_url_path_escape_passes_unreserved() {
	// Unreserved characters pass through unchanged.
	assert mongreldb.url_path_escape('orders_2026.1') == 'orders_2026.1'
}

fn test_url_path_escape_encodes_reserved() {
	// Reserved characters are percent-encoded so they cannot inject segments.
	assert mongreldb.url_path_escape('a/b') == 'a%2Fb'
	assert mongreldb.url_path_escape('a b') == 'a%20b'
}
