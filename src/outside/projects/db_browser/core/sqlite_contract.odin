// Odin mirror of sqlite.manifest records and closed Value_Kind enum
// (src/md/features/db_browser.md). Every struct size and field offset matches
// src/outside/c_programs/sqlite/modus_sqlite_contract.h byte for byte.
package db_browser_core

import "modus:contract/call_outcome"
import "modus:contract/errors"

SQLITE_COLUMN_NAME_BYTES :: 64
SQLITE_PAGE_SIZE :: 4096

Value_Kind :: enum u8 {
	None      = 0,
	Null      = 1,
	Integer   = 2,
	Real_Bits = 3,
	Text      = 4,
	Blob      = 5,
}

// Border parser: refuses any byte that does not name a Value_Kind member.
value_kind_of_word :: proc "contextless" (word: u8) -> (kind: Value_Kind, ok: bool) {
	switch word {
	case u8(Value_Kind.None):
		return .None, true
	case u8(Value_Kind.Null):
		return .Null, true
	case u8(Value_Kind.Integer):
		return .Integer, true
	case u8(Value_Kind.Real_Bits):
		return .Real_Bits, true
	case u8(Value_Kind.Text):
		return .Text, true
	case u8(Value_Kind.Blob):
		return .Blob, true
	}
	return .None, false
}

Open_Options :: struct {
	fresh:          u8,
	read_only:      u8,
	reserved:       [2]u8,
	page_size:      u32,
	random_seed:    u64,
	database_bytes: u64,
	heap_bytes:     u32,
	reserved_2:     u32,
}
#assert(size_of(Open_Options) == 32)
#assert(offset_of(Open_Options, fresh) == 0)
#assert(offset_of(Open_Options, read_only) == 1)
#assert(offset_of(Open_Options, page_size) == 4)
#assert(offset_of(Open_Options, random_seed) == 8)
#assert(offset_of(Open_Options, database_bytes) == 16)
#assert(offset_of(Open_Options, heap_bytes) == 24)

Session_Info :: struct {
	version_number: i64,
	database_bytes: u64,
	dirty_pages:    u64,
	page_size:      u32,
	open:           u8,
	read_only:      u8,
	reserved:       [2]u8,
}
#assert(size_of(Session_Info) == 32)
#assert(offset_of(Session_Info, version_number) == 0)
#assert(offset_of(Session_Info, database_bytes) == 8)
#assert(offset_of(Session_Info, dirty_pages) == 16)
#assert(offset_of(Session_Info, page_size) == 24)
#assert(offset_of(Session_Info, open) == 28)
#assert(offset_of(Session_Info, read_only) == 29)

Column_Row :: struct {
	column_index:   u32,
	declared_kind:  u8,
	name_length:    u8,
	name_truncated: u8,
	reserved:       u8,
	name:           [SQLITE_COLUMN_NAME_BYTES]u8,
}
#assert(size_of(Column_Row) == 72)
#assert(offset_of(Column_Row, column_index) == 0)
#assert(offset_of(Column_Row, declared_kind) == 4)
#assert(offset_of(Column_Row, name_length) == 5)
#assert(offset_of(Column_Row, name_truncated) == 6)
#assert(offset_of(Column_Row, name) == 8)

Cell_Row :: struct {
	row_index:       u32,
	column_index:    u32,
	value_kind:      u8,
	truncated:       u8,
	reserved:        [6]u8,
	integer_or_bits: i64,
	payload_offset:  u32,
	payload_length:  u32,
}
#assert(size_of(Cell_Row) == 32)
#assert(offset_of(Cell_Row, row_index) == 0)
#assert(offset_of(Cell_Row, column_index) == 4)
#assert(offset_of(Cell_Row, value_kind) == 8)
#assert(offset_of(Cell_Row, truncated) == 9)
#assert(offset_of(Cell_Row, integer_or_bits) == 16)
#assert(offset_of(Cell_Row, payload_offset) == 24)
#assert(offset_of(Cell_Row, payload_length) == 28)

Query_Summary :: struct {
	column_count:   u32,
	row_count:      u32,
	changes:        i64,
	dirty_pages:    u64,
	database_bytes: u64,
	truncated_rows: u8,
	has_rows:       u8,
	reserved:       [6]u8,
}
#assert(size_of(Query_Summary) == 40)
#assert(offset_of(Query_Summary, column_count) == 0)
#assert(offset_of(Query_Summary, row_count) == 4)
#assert(offset_of(Query_Summary, changes) == 8)
#assert(offset_of(Query_Summary, dirty_pages) == 16)
#assert(offset_of(Query_Summary, database_bytes) == 24)
#assert(offset_of(Query_Summary, truncated_rows) == 32)
#assert(offset_of(Query_Summary, has_rows) == 33)

Dirty_Range_Row :: struct {
	byte_offset: u64,
	byte_length: u64,
}
#assert(size_of(Dirty_Range_Row) == 16)
#assert(offset_of(Dirty_Range_Row, byte_offset) == 0)
#assert(offset_of(Dirty_Range_Row, byte_length) == 8)

// Pluggable bridge to sqlite.module: implemented over a zero-grant child call
// host on modus (worker.odin) and over direct sqlite.module or mocks in host tests.
Sqlite_Bridge :: struct {
	user_data: rawptr,
	open: proc "contextless" (
		user_data: rawptr,
		options: ^Open_Options,
		database: []u8,
		info: ^Session_Info,
		err: ^errors.Error_Record,
	) -> call_outcome.Call_Outcome,
	execute: proc "contextless" (
		user_data: rawptr,
		sql: string,
		database: []u8,
		columns: []Column_Row,
		cells: []Cell_Row,
		payload: []u8,
		diagnostic: []u8,
		summary: ^Query_Summary,
		column_count: ^int,
		cell_count: ^int,
		payload_count: ^int,
		diagnostic_count: ^int,
		err: ^errors.Error_Record,
	) -> call_outcome.Call_Outcome,
	dirty_ranges: proc "contextless" (
		user_data: rawptr,
		ranges: []Dirty_Range_Row,
		total_count: ^int,
		err: ^errors.Error_Record,
	) -> call_outcome.Call_Outcome,
	mark_synced: proc "contextless" (
		user_data: rawptr,
		err: ^errors.Error_Record,
	) -> call_outcome.Call_Outcome,
	info: proc "contextless" (
		user_data: rawptr,
		out_info: ^Session_Info,
		err: ^errors.Error_Record,
	) -> call_outcome.Call_Outcome,
	last_diagnostic: proc "contextless" (
		user_data: rawptr,
		out_diag: []u8,
		out_count: ^int,
		err: ^errors.Error_Record,
	) -> call_outcome.Call_Outcome,
	close: proc "contextless" (
		user_data: rawptr,
		database: []u8,
		err: ^errors.Error_Record,
	) -> call_outcome.Call_Outcome,
}
