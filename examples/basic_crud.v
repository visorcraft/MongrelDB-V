// Example: basic CRUD operations with the MongrelDB V client.
//
// Run from the repo root:
//
//   v run examples/basic_crud.v
//
// Requires a mongreldb-server daemon running on http://127.0.0.1:8453.
//
// Creates a table, inserts three rows, counts them, queries all rows, "updates"
// one row by overwriting it at its primary key, deletes one row, then drops
// the table. Progress is printed at every step.
import rand
import time
import mongreldb

fn main() {
	mut db := mongreldb.connect('http://127.0.0.1:8453', mongreldb.Options{})

	// Health check; bail out if the daemon is unreachable.
	db.health() or {
		eprintln('daemon not reachable: ${err}')
		exit(1)
	}
	println('Connected to MongrelDB')

	// Unique table name per run so concurrent/repeated runs never collide.
	table := unique_name('example_crud')
	db.drop_table(table) or {}

	// Create the table. Schema: id (int64 PK), name (varchar), score (float64).
	tid := db.create_table(table, [
		mongreldb.Column{1, 'id', 'int64', true, false, [], ''},
		mongreldb.Column{2, 'name', 'varchar', false, false, [], ''},
		mongreldb.Column{3, 'score', 'float64', false, false, [], ''},
	]) or {
		eprintln('create_table failed: ${err}')
		exit(1)
	}
	println('Created table ${table} (id ${tid})')

	// Insert three rows. Cells pair column id -> value.
	db.put(table, [
		mongreldb.Cell{1, mongreldb.int_value(1)},
		mongreldb.Cell{2, mongreldb.string_value('Alice')},
		mongreldb.Cell{3, mongreldb.float_value(95.5)},
	], '') or {
		eprintln('put failed: ${err}')
		cleanup(db, table)
		exit(1)
	}
	db.put(table, [
		mongreldb.Cell{1, mongreldb.int_value(2)},
		mongreldb.Cell{2, mongreldb.string_value('Bob')},
		mongreldb.Cell{3, mongreldb.float_value(82.0)},
	], '') or {
		eprintln('put failed: ${err}')
		cleanup(db, table)
		exit(1)
	}
	db.put(table, [
		mongreldb.Cell{1, mongreldb.int_value(3)},
		mongreldb.Cell{2, mongreldb.string_value('Carol')},
		mongreldb.Cell{3, mongreldb.float_value(78.3)},
	], '') or {
		eprintln('put failed: ${err}')
		cleanup(db, table)
		exit(1)
	}
	println('Inserted 3 rows')

	total := db.count(table) or {
		eprintln('count failed: ${err}')
		cleanup(db, table)
		exit(1)
	}
	println('Total rows: ${total}')

	// Query all rows (no conditions).
	mut q := db.query(table)
	rows := q.execute() or {
		eprintln('query failed: ${err}')
		cleanup(db, table)
		exit(1)
	}
	println('Query returned ${rows.len} rows')

	// Update Alice's score by re-putting the same primary key with new values.
	db.put(table, [
		mongreldb.Cell{1, mongreldb.int_value(1)},
		mongreldb.Cell{2, mongreldb.string_value('Alice')},
		mongreldb.Cell{3, mongreldb.float_value(100.0)},
	], '') or {
		eprintln('update put failed: ${err}')
		cleanup(db, table)
		exit(1)
	}
	println("Updated Alice's score to 100.0")

	// Delete Carol (primary key 3).
	db.delete_by_pk(table, mongreldb.int_value(3)) or {
		eprintln('delete failed: ${err}')
		cleanup(db, table)
		exit(1)
	}
	after_delete := db.count(table) or { 0 }
	println('Deleted Carol; remaining rows: ${after_delete}')

	cleanup(db, table)
}

fn cleanup(db mongreldb.Client, table string) {
	db.drop_table(table) or {}
	println('Dropped table ${table}')
}

fn unique_name(prefix string) string {
	// Use a millisecond timestamp + a random suffix for uniqueness.
	ts := time.now().unix_milli()
	ulid := rand.ulid()
	return '${prefix}_${ts}_${ulid}'
}
