package files

import "modus:contract/errors"

// Structured log facts of files (src/md/features/log_facts.md).

@(log_fact = "files: first picture presented")
First_Picture_Presented :: struct {}

@(log_fact = "files: opened store with {entries} entries and {stores} accessible stores")
Store_Opened :: struct {
	entries: u64,
	stores:  u64,
}

@(log_fact = "files: no store granted")
No_Store :: struct {}

@(log_fact = "files: store connection ended, switching to read only")
Store_Revoked :: struct {}

@(log_fact = "files: created entry at generation {generation}")
Entry_Created :: struct {
	generation: i64,
}

@(log_fact = "files: removed entry at generation {generation}")
Entry_Removed :: struct {
	generation: i64,
}

@(log_fact = "files: restored version {from_generation} as generation {to_generation}")
Version_Restored :: struct {
	from_generation: i64,
	to_generation:   i64,
}

@(log_fact = "files: opened object in edit")
Editor_Opened :: struct {}

@(log_fact = "files: editor launch refused")
Edit_Open_Refused :: struct {}

@(log_fact = "files: store call refused: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Store_Call_Refused :: distinct errors.Error_Record_Fact_Fields
