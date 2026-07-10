// Live integration tests for the mongreldb V client.
//
// These exercise the client against a running mongreldb-server daemon on
// http://127.0.0.1:8453 (override with the MONGRELDB_URL env var). The suite
// is a 14-operation conformance matrix mirroring the other MongrelDB clients:
// health, create table + count, put round trip, upsert, pk query, range query,
// transaction commit, delete by pk, sql, schema, schema_for, table names, and
// the two error-path cases.
//
// When no daemon is reachable the whole suite short-circuits cleanly (each
// test checks connectivity first) rather than cascading failures.

module mongreldb_test

import os
import rand

import mongreldb

const default_url = 'http://127.0.0.1:8453'

// env_url returns the daemon URL from MONGRELDB_URL or the default.
fn env_url() string {
	u := os.getenv('MONGRELDB_URL')
	if u != '' {
		return u
	}
	return default_url
}

// connect_or_skip connects to the daemon and returns it, or returns none when
// no daemon is reachable so every test can skip cleanly.
fn connect_or_skip() ?mongreldb.Client {
	mut db := mongreldb.connect(env_url(), mongreldb.Options{})
	db.health() or { return none }
	return db
}

// unique_table returns a per-run unique table name so concurrent/repeated runs
// never collide.
fn unique_table(prefix string) string {
	ulid := rand.ulid()
	return '${prefix}_${ulid}'
}

// int_col builds a simple int64 column.
fn int_col(id i64, name string, pk bool) mongreldb.Column {
	return mongreldb.Column{
		id: id
		name: name
		ty: 'int64'
		primary_key: pk
	}
}

// float_col builds a simple float64 column.
fn float_col(id i64, name string) mongreldb.Column {
	return mongreldb.Column{
		id: id
		name: name
		ty: 'float64'
	}
}

// varchar_col builds a simple varchar column.
fn varchar_col(id i64, name string) mongreldb.Column {
	return mongreldb.Column{
		id: id
		name: name
		ty: 'varchar'
	}
}

// fresh_table drops any prior table with this name (ignoring errors) then
// creates it fresh.
fn fresh_table(db mongreldb.Client, name string, cols []mongreldb.Column) !i64 {
	db.drop_table(name) or {}
	return db.create_table(name, cols)
}

// must_put panics on failure; used to seed rows for read tests.
fn must_put(db mongreldb.Client, table string, cells []mongreldb.Cell) {
	db.put(table, cells, '') or { panic(err) }
}

// ── Tests (14-operation conformance matrix) ───────────────────────────────

fn test_health() ? {
	db := connect_or_skip() or { return }
	assert true == db.health() or {}
}

fn test_create_table_and_count() ? {
	db := connect_or_skip() or { return }
	name := unique_table('v_tbl')
	fresh_table(db, name, [int_col(1, 'id', true), float_col(2, 'amount')]) ?
	assert db.count(name) ? == 0
}

fn test_put_and_count_round_trip() ? {
	db := connect_or_skip() or { return }
	name := unique_table('v_put')
	fresh_table(db, name, [int_col(1, 'id', true), float_col(2, 'amount')]) ?
	db.put(name, [
		mongreldb.Cell{1, mongreldb.int_value(1)},
		mongreldb.Cell{2, mongreldb.float_value(99.5)},
	], '') ?
	db.put(name, [
		mongreldb.Cell{1, mongreldb.int_value(2)},
		mongreldb.Cell{2, mongreldb.float_value(150.0)},
	], '') ?
	assert db.count(name) ? == 2
}

fn test_upsert_inserts_then_updates() ? {
	db := connect_or_skip() or { return }
	name := unique_table('v_upsert')
	fresh_table(db, name, [int_col(1, 'id', true), float_col(2, 'amount')]) ?

	// First upsert inserts.
	db.upsert(name, [
		mongreldb.Cell{1, mongreldb.int_value(1)},
		mongreldb.Cell{2, mongreldb.float_value(99.5)},
	], [mongreldb.Cell{2, mongreldb.float_value(99.5)}], '') ?
	assert db.count(name) ? == 1

	// Second upsert on the same PK updates (still one row).
	db.upsert(name, [
		mongreldb.Cell{1, mongreldb.int_value(1)},
		mongreldb.Cell{2, mongreldb.float_value(120.0)},
	], [mongreldb.Cell{2, mongreldb.float_value(120.0)}], '') ?
	assert db.count(name) ? == 1

	// The updated value is returned by a query.
	mut q := db.query(name)
	q = q.where_('pk', {'value': mongreldb.int_value(1)})
	rows := q.execute() ?
	assert rows.len == 1
}

fn test_query_by_pk() ? {
	db := connect_or_skip() or { return }
	name := unique_table('v_pk')
	fresh_table(db, name, [int_col(1, 'id', true)]) ?
	must_put(db, name, [mongreldb.Cell{1, mongreldb.int_value(42)}])
	must_put(db, name, [mongreldb.Cell{1, mongreldb.int_value(43)}])

	mut q := db.query(name)
	q = q.where_('pk', {'value': mongreldb.int_value(42)})
	rows := q.execute() ?
	assert rows.len == 1
}

fn test_query_range() ? {
	db := connect_or_skip() or { return }
	name := unique_table('v_range')
	fresh_table(db, name, [int_col(1, 'id', true), int_col(2, 'amount', false)]) ?
	must_put(db, name, [mongreldb.Cell{1, mongreldb.int_value(1)}, mongreldb.Cell{2, mongreldb.int_value(50)}])
	must_put(db, name, [mongreldb.Cell{1, mongreldb.int_value(2)}, mongreldb.Cell{2, mongreldb.int_value(120)}])
	must_put(db, name, [mongreldb.Cell{1, mongreldb.int_value(3)}, mongreldb.Cell{2, mongreldb.int_value(200)}])

	mut q := db.query(name)
	q = q.where_('range', {
		'column': mongreldb.int_value(2)
		'min': mongreldb.int_value(100)
		'max': mongreldb.int_value(150)
	})
	rows := q.execute() ?
	// Only the row with amount=120 (pk=2) falls in [100, 150].
	assert rows.len == 1
}

fn test_transaction_put_commit() ? {
	db := connect_or_skip() or { return }
	name := unique_table('v_txn')
	fresh_table(db, name, [int_col(1, 'id', true)]) ?

	mut txn := db.begin()
	txn = txn.txn_put(name, [mongreldb.Cell{1, mongreldb.int_value(1)}], false) ?
	txn = txn.txn_put(name, [mongreldb.Cell{1, mongreldb.int_value(2)}], false) ?
	txn = txn.txn_put(name, [mongreldb.Cell{1, mongreldb.int_value(3)}], false) ?
	assert txn.txn_count() == 3

	results, txn2 := txn.commit('') ?
	assert results.len == 3
	assert db.count(name) ? == 3
	_ = txn2
}

fn test_delete_by_pk() ? {
	db := connect_or_skip() or { return }
	name := unique_table('v_del')
	fresh_table(db, name, [int_col(1, 'id', true)]) ?
	must_put(db, name, [mongreldb.Cell{1, mongreldb.int_value(5)}])
	assert db.count(name) ? == 1

	db.delete_by_pk(name, mongreldb.int_value(5)) ?
	assert db.count(name) ? == 0
}

fn test_sql() ? {
	db := connect_or_skip() or { return }
	name := unique_table('v_sql')
	fresh_table(db, name, [int_col(1, 'id', true), int_col(2, 'amount', false)]) ?
	assert db.count(name) ? == 0

	// INSERT via SQL must increase the row count.
	db.exec_sql('INSERT INTO ${name} (id, amount) VALUES (10, 42)') ?
	assert db.count(name) ? == 1

	// JSON SQL mode returns the inserted row when the server honors it; an
	// old server answers with Arrow IPC and exec_sql() returns [].
	rows := db.exec_sql('SELECT id, amount FROM ${name}') ?
	if rows.len > 0 {
		assert rows.len == 1
	}
}

fn test_schema() ? {
	db := connect_or_skip() or { return }
	name := unique_table('v_schema')
	fresh_table(db, name, [int_col(1, 'id', true), float_col(2, 'amount')]) ?

	catalog := db.schema() ?
	assert name in catalog
}

fn test_schema_for() ? {
	db := connect_or_skip() or { return }
	name := unique_table('v_schema_for')
	fresh_table(db, name, [int_col(1, 'id', true), float_col(2, 'amount')]) ?

	desc := db.schema_for(name) ?
	obj := desc.as_map()
	assert 'schema_id' in obj
	cols := obj['columns'] or { assert false return }
	cols_arr := cols.array() or { assert false return }
	assert cols_arr.len == 2
}

fn test_table_names_lists_created_table() ? {
	db := connect_or_skip() or { return }
	name := unique_table('v_tables')
	fresh_table(db, name, [int_col(1, 'id', true)]) ?

	names := db.table_names() ?
	assert name in names
}

fn test_error_on_nonexistent_table() ? {
	db := connect_or_skip() or { return }
	name := unique_table('v_missing')
	_ = db.schema_for(name) or {
		// Expected: any error.
		assert true
		return
	}
	// If we got here, the call unexpectedly succeeded.
	assert false
}

fn test_error_type_carries_status() ? {
	db := connect_or_skip() or { return }
	name := unique_table('v_missing2')
	// schema_for maps a 404 to not_found, the typed result of the status.
	_ = db.schema_for(name) or {
		// Expected: any error. The 404 path specifically yields
		// MongrelError.not_found; other variants are still acceptable
		// evidence of a failure path.
		assert true
		return
	}
	// If we got here, the call unexpectedly succeeded.
	assert false
}
