package store_explorer

import "modus:contract/errors"

// Structured log facts of store_explorer (src/md/features/log_facts.md).

@(log_fact = "store_explorer: first picture presented")
First_Picture_Presented :: struct {}

@(log_fact = "store_explorer: opened store with {entries} entries and {stores} accessible stores")
Store_Opened :: struct {
	entries: u64,
	stores:  u64,
}

@(log_fact = "store_explorer: no store granted")
No_Store :: struct {}

@(log_fact = "store_explorer: store connection ended, switching to read only")
Store_Revoked :: struct {}

@(log_fact = "store_explorer: created entry at generation {generation}")
Entry_Created :: struct {
	generation: i64,
}

@(log_fact = "store_explorer: removed entry at generation {generation}")
Entry_Removed :: struct {
	generation: i64,
}

@(log_fact = "store_explorer: restored version {from_generation} as generation {to_generation}")
Version_Restored :: struct {
	from_generation: i64,
	to_generation:   i64,
}

@(log_fact = "store_explorer: store call refused: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Store_Call_Refused :: distinct errors.Error_Record_Fact_Fields
