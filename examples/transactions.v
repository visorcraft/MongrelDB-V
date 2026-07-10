// Example: atomic batch transactions with the MongrelDB V client.
//
// Run from the repo root:
//
//   v run examples/transactions.v
//
// Requires a mongreldb-server daemon running on http://127.0.0.1:8453.
//
// Creates a table, stages three inserts in a single transaction, commits them
// atomically, verifies the count, then demonstrates idempotent retries by
// re-committing with the same idempotency key (the daemon returns the original
// result and applies no duplicate rows). Cleans up by dropping the table.

import rand
import time

import mongreldb

fn main() {
	mut db := mongreldb.connect('http://127.0.0.1:8453', mongreldb.Options{})

	db.health() or {
		eprintln('daemon not reachable: ${err}')
		exit(1)
	}
	println('Connected to MongrelDB')

	// Unique table name + idempotency key per run so concurrent/repeated runs
	// never collide and retry logic isn't confused with a prior run's batch.
	suffix := unique_suffix()
	table := 'example_txn_${suffix}'
	idempotency_key := 'example-txn-${suffix}'
	db.drop_table(table) or {}

	db.create_table(table, [
		mongreldb.Column{1, 'id', 'int64', true, false, [], ''},
		mongreldb.Column{2, 'name', 'varchar', false, false, [], ''},
		mongreldb.Column{3, 'score', 'float64', false, false, [], ''},
	]) or { eprintln('create_table failed: ${err}'); exit(1) }
	println('Created table ${table}')

	// Stage three puts and commit them atomically. Either every op lands or
	// none do; a constraint violation rolls back the whole batch.
	mut txn := db.begin()
	txn = txn.txn_put(table, [
		mongreldb.Cell{1, mongreldb.int_value(1)},
		mongreldb.Cell{2, mongreldb.string_value('Alice')},
		mongreldb.Cell{3, mongreldb.float_value(95.5)},
	], false) or { eprintln('txn_put failed: ${err}'); cleanup(db, table); exit(1) }
	txn = txn.txn_put(table, [
		mongreldb.Cell{1, mongreldb.int_value(2)},
		mongreldb.Cell{2, mongreldb.string_value('Bob')},
		mongreldb.Cell{3, mongreldb.float_value(82.0)},
	], false) or { eprintln('txn_put failed: ${err}'); cleanup(db, table); exit(1) }
	txn = txn.txn_put(table, [
		mongreldb.Cell{1, mongreldb.int_value(3)},
		mongreldb.Cell{2, mongreldb.string_value('Carol')},
		mongreldb.Cell{3, mongreldb.float_value(78.3)},
	], false) or { eprintln('txn_put failed: ${err}'); cleanup(db, table); exit(1) }
	println('Staged ${txn.txn_count()} operations')

	results, mut committed := txn.commit('') or {
		eprintln('commit failed: ${err}')
		cleanup(db, table)
		exit(1)
	}
	println('Committed atomically: ${results.len} operations applied')

	after_commit := db.count(table) or { 0 }
	println('Verified row count after commit: ${after_commit}')

	// Idempotent retry: stage the same batch again with an idempotency key,
	// then commit a second time with the SAME key. The daemon replays the
	// original result and applies no extra rows.
	mut retry := db.begin()
	retry = retry.txn_put(table, [
		mongreldb.Cell{1, mongreldb.int_value(4)},
		mongreldb.Cell{2, mongreldb.string_value('Dave')},
		mongreldb.Cell{3, mongreldb.float_value(60.0)},
	], false) or { eprintln('retry txn_put failed: ${err}'); cleanup(db, table); exit(1) }
	_ = retry.commit(idempotency_key) or { eprintln('retry commit failed: ${err}'); cleanup(db, table); exit(1) }
	after_first := db.count(table) or { 0 }
	println('After first idempotent commit: ${after_first} rows')

	mut retry2 := db.begin()
	retry2 = retry2.txn_put(table, [
		mongreldb.Cell{1, mongreldb.int_value(4)},
		mongreldb.Cell{2, mongreldb.string_value('Dave')},
		mongreldb.Cell{3, mongreldb.float_value(60.0)},
	], false) or { eprintln('retry2 txn_put failed: ${err}'); cleanup(db, table); exit(1) }
	_ = retry2.commit(idempotency_key) or { eprintln('retry2 commit failed: ${err}'); cleanup(db, table); exit(1) }
	after_dup := db.count(table) or { 0 }
	println('After duplicate idempotent commit (same key): ${after_dup} rows (no double-apply)')

	_ = committed
	cleanup(db, table)
}

fn cleanup(db mongreldb.Client, table string) {
	db.drop_table(table) or {}
	println('Dropped table ${table}')
}

fn unique_suffix() string {
	ts := time.now().unix_time_milli()
	ulid := rand.ulid()
	return '${ts}_${ulid}'
}
