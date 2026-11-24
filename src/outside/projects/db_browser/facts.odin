package db_browser

import "modus:contract/errors"

// Structured log facts of db_browser (src/md/features/log_facts.md).

@(log_fact = "db_browser: first picture presented")
First_Picture_Presented :: struct {}

@(log_fact = "db_browser: opened database of {bytes} bytes, {tables} tables, generation {generation}")
Database_Opened :: struct {
	bytes:      u64,
	tables:     u64,
	generation: i64,
}

@(log_fact = "db_browser: no store granted, running in memory")
No_Store :: struct {}

@(log_fact = "db_browser: query returned {rows} rows, {columns} columns, {changes} changes")
Query_Executed :: struct {
	rows:    u64,
	columns: u64,
	changes: i64,
}

@(log_fact = "db_browser: sorted column {column}, direction {direction}")
Query_Sorted :: struct {
	column:    u64,
	direction: u64,
}

@(log_fact = "db_browser: committed {bytes} bytes at generation {generation}")
Database_Committed :: struct {
	bytes:      u64,
	generation: i64,
}

@(log_fact = "db_browser: previewing version generation {generation}")
Version_Previewed :: struct {
	generation: i64,
}

@(log_fact = "db_browser: restored version generation {from_generation} as generation {to_generation}")
Version_Restored :: struct {
	from_generation: i64,
	to_generation:   i64,
}

@(log_fact = "db_browser: store connection ended, switching to read only")
Store_Revoked :: struct {}

@(log_fact = "db_browser: store call refused: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Store_Call_Refused :: distinct errors.Error_Record_Fact_Fields

@(log_fact = "db_browser: sqlite host unavailable")
Engine_Unavailable :: struct {}
