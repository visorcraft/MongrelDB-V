// Example: query builder conditions with the MongrelDB V client.
//
// Run from the repo root:
//
//   v run examples/query_builder.v
//
// Requires a mongreldb-server daemon running on http://127.0.0.1:8453.
//
// Creates a table, inserts five rows with varying scores, then uses the native
// query builder to fetch rows by a range condition and by an exact primary-key
// match. Cleans up by dropping the table.
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

	// Unique table name per run so concurrent/repeated runs never collide.
	table := unique_name('example_query')
	db.drop_table(table) or {}

	db.create_table(table, [
		mongreldb.Column{1, 'id', 'int64', true, false, [], ''},
		mongreldb.Column{2, 'name', 'varchar', false, false, [], ''},
		mongreldb.Column{3, 'score', 'float64', false, false, [], ''},
	]) or {
		eprintln('create_table failed: ${err}')
		exit(1)
	}
	println('Created table ${table}')

	// Five rows with varying scores.
	db.put(table, [
		mongreldb.Cell{1, mongreldb.int_value(1)},
		mongreldb.Cell{2, mongreldb.string_value('Alice')},
		mongreldb.Cell{3, mongreldb.float_value(40.0)},
	], '') or {
		eprintln('put failed: ${err}')
		cleanup(db, table)
		exit(1)
	}
	db.put(table, [
		mongreldb.Cell{1, mongreldb.int_value(2)},
		mongreldb.Cell{2, mongreldb.string_value('Bob')},
		mongreldb.Cell{3, mongreldb.float_value(65.0)},
	], '') or {
		eprintln('put failed: ${err}')
		cleanup(db, table)
		exit(1)
	}
	db.put(table, [
		mongreldb.Cell{1, mongreldb.int_value(3)},
		mongreldb.Cell{2, mongreldb.string_value('Carol')},
		mongreldb.Cell{3, mongreldb.float_value(82.0)},
	], '') or {
		eprintln('put failed: ${err}')
		cleanup(db, table)
		exit(1)
	}
	db.put(table, [
		mongreldb.Cell{1, mongreldb.int_value(4)},
		mongreldb.Cell{2, mongreldb.string_value('Dave')},
		mongreldb.Cell{3, mongreldb.float_value(91.0)},
	], '') or {
		eprintln('put failed: ${err}')
		cleanup(db, table)
		exit(1)
	}
	db.put(table, [
		mongreldb.Cell{1, mongreldb.int_value(5)},
		mongreldb.Cell{2, mongreldb.string_value('Eve')},
		mongreldb.Cell{3, mongreldb.float_value(12.5)},
	], '') or {
		eprintln('put failed: ${err}')
		cleanup(db, table)
		exit(1)
	}
	println('Inserted 5 rows')

	// Range condition: scores in [60.0, 90.0]. The "column" alias maps to the
	// server's column_id; pass the numeric column id (3), not the name.
	mut range_q := db.query(table)
	range_q = range_q.where_('range_f64', {
		'column':        mongreldb.int_value(3)
		'min':           mongreldb.float_value(60.0)
		'max':           mongreldb.float_value(90.0)
		'min_inclusive': mongreldb.bool_value(true)
		'max_inclusive': mongreldb.bool_value(true)
	})
	range_rows := range_q.execute() or {
		eprintln('range query failed: ${err}')
		cleanup(db, table)
		exit(1)
	}
	println('Range query (score in [60,90]) returned ${range_rows.len} rows')

	// Primary-key condition: fetch the single row with id == 4.
	mut pk_q := db.query(table)
	pk_q = pk_q.where_('pk', {
		'value': mongreldb.int_value(4)
	})
	pk_rows := pk_q.execute() or {
		eprintln('pk query failed: ${err}')
		cleanup(db, table)
		exit(1)
	}
	println('PK query (id == 4) returned ${pk_rows.len} rows')

	cleanup(db, table)
}

fn cleanup(db mongreldb.Client, table string) {
	db.drop_table(table) or {}
	println('Dropped table ${table}')
}

fn unique_name(prefix string) string {
	ts := time.now().unix_milli()
	ulid := rand.ulid()
	return '${prefix}_${ts}_${ulid}'
}
