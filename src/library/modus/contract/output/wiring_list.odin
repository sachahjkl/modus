package output

import "base:intrinsics"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/module"
import "modus:contract/ring"

// The wiring list: the rows that an asker lends the root service with
// `Wire` (one row) or with `Start` (the wiring of the child before its
// first instruction), in one memory object that it gives through its root
// ring (src/md/features/module_outputs.md, "The wiring list of a start").
//
// The memory of a list:
//   offset 0      the head (Wiring_List_Head), 64 bytes
//   offset 64     the rows (Wiring), 64 bytes each
//   after them    the lent handles, 32 bits each: the numbers of the
//                 handles that the asker gave the root service through its
//                 root ring, which a row names by their place from 1
//   after them    the wiring terms, which a row names by an offset and a
//                 count
//
// The root service copies the memory once into its private memory, then
// takes it through wiring_list_check: the asker can change the lent bytes
// at any time, so no byte is read twice.

// The most pages of the memory of a list: the root service copies it whole.
WIRING_LIST_PAGES_MOST :: 4
WIRING_LIST_BYTES_MOST :: WIRING_LIST_PAGES_MOST * ring.PAGE_SIZE
// The most rows and lent handles of one list: one command, not a bound of
// the wirings of the machine. A Wire after a start adds more.
WIRING_LIST_ROW_LIMIT :: 32
// The wirings that one asker holds at one time: the root service refuses
// one more. Each wiring costs the root service one handle.
WIRINGS_OF_AN_ASKER_MOST :: 8
// A list names at most the two ends of each wiring that its asker can
// hold: each lent handle is a handle in the table of the root service
// until the command ends.
WIRING_LIST_HANDLE_LIMIT :: 2 * WIRINGS_OF_AN_ASKER_MOST
#assert(size_of(Wiring_List_Head) + WIRING_LIST_ROW_LIMIT * size_of(Wiring) + WIRING_LIST_HANDLE_LIMIT * size_of(u32) <= WIRING_LIST_BYTES_MOST)

// The compartments of an output ring that a row names with the capacity 0,
// and the least and the most that a row names.
WIRING_CAPACITY_DEFAULT :: 256
WIRING_CAPACITY_LEAST :: 32
WIRING_CAPACITY_MOST :: 4096

// The rows of a Start that name the asker as their reader, at most: the
// completion of the Start gives the ring of each one in values[1..6].
WIRING_ASKER_ROWS_OF_A_START :: 6

// One end of a wiring. The values cross the border of the root ring.
Wiring_End :: enum u32 {
	None      = 0, // Refused.
	Child     = 1, // The process that the Start of the list starts. Only a Start names it.
	Started   = 2, // A process whose start the asker asked for: a lent process handle.
	// A service to which the asker holds a connection: the number of the process handle of the service that
	// the completion of Connect gave the asker. That handle has no Give, so the asker names it and never lends it.
	Connected = 3,
	Asker     = 4, // The asker itself, as the reader. Never a writer.
}

// What the writer of a row writes. The values cross the border of the
// root ring.
Writer_Stream :: enum u32 {
	None          = 0, // Refused.
	Record_Output = 1, // A record output that the module of the writer declares.
	Log           = 2, // The record output `log` of the child.
}

// The head of a list. The values cross the border of the root ring.
Wiring_List_Head :: struct {
	row_count:    u32, // The rows that follow the head: 1 to WIRING_LIST_ROW_LIMIT; 1 for a Wire.
	handle_count: u32, // The lent handles that follow the rows: 0 to WIRING_LIST_HANDLE_LIMIT.
	reserved:     [14]u32, // 0.
}
#assert(size_of(Wiring_List_Head) == 64)

// One row of a list: one wiring, from its writer to its reader. Each word
// is the word of its member or a number; all-zero bytes are refused.
Wiring :: struct {
	writer_end:    u32, // A Wiring_End: Child, Started or Connected.
	writer_handle: u32, // Started: the place from 1 in the lent handles. Connected: the number that Connect gave. Child: 0.
	writer_stream: u32, // A Writer_Stream.
	writer_index:  u32, // Record_Output: the index of the record output, from 1. Log: 0.
	reader_end:    u32, // A Wiring_End: Child, Started, Connected or Asker.
	reader_handle: u32, // Started: the place from 1 in the lent handles. Connected: the number that Connect gave. Child or Asker: 0.
	reader_index:  u32, // The index of the record input, from 1. Asker: 0.
	pace:          u32, // A Wiring_Pace.
	capacity:      u32, // The compartments of the ring: 0 for WIRING_CAPACITY_DEFAULT, or a power of two from WIRING_CAPACITY_LEAST to WIRING_CAPACITY_MOST.
	terms_offset:  u32, // The wiring terms, in bytes from the start of the memory of the list, after the lent handles; 0 with no terms.
	terms_count:   u32, // The bytes of the terms; 0 with no terms.
	condition_offset: u32, // The condition of the wiring, a Condition_Terms, in bytes from the start of the memory of the list, after the lent handles; 0 with no condition.
	condition_count:  u32, // size_of(Condition_Terms), or 0 with no condition.
	paired_row:    u32, // A writer that is a record output Paired: the number from 1 of an earlier row of the same list that wires the source of its pair into the generic record input of the same process. Else 0.
	reserved:      [2]u32, // 0.
}
#assert(size_of(Wiring) == 64)

// The number of each field of a Wiring, from 1, as the error record of a
// refused row names it in its argument.
Wiring_Field :: enum i64 {
	Whole         = 0,
	Writer_End    = 1,
	Writer_Handle = 2,
	Writer_Stream = 3,
	Writer_Index  = 4,
	Reader_End    = 5,
	Reader_Handle = 6,
	Reader_Index  = 7,
	Pace          = 8,
	Capacity      = 9,
	Terms_Offset  = 10,
	Terms_Count   = 11,
	Condition_Offset = 12,
	Condition_Count  = 13,
	Paired_Row    = 14,
	Reserved      = 15,
}

// One row after its border: each word is its member or a checked number.
Checked_Wiring :: struct {
	writer_end:    Wiring_End,
	writer_handle: u32, // The place from 1 for Started, the number of the connection for Connected, or 0.
	writer_stream: Writer_Stream,
	writer_index:  u32,
	reader_end:    Wiring_End,
	reader_handle: u32,
	reader_index:  u32,
	pace:          Wiring_Pace,
	capacity:      u32, // The default is applied: a power of two.
	terms_offset:  u32,
	terms_count:   u32,
	condition_offset: u32, // The condition terms, or 0: their count is size_of(Condition_Terms).
	paired_row:    u32, // The earlier row of the source of the pair, from 1, or 0.
}

// Which command lends the list.
Wiring_List_Form :: enum u8 {
	Wire  = 0, // One row, no end Child.
	Start = 1, // Any count of rows; Child is the process that starts.
}

// The rows and the lent handles of a list, after its border.
Checked_Wiring_List :: struct {
	row_count:    u32,
	handle_count: u32,
	rows:         [WIRING_LIST_ROW_LIMIT]Checked_Wiring,
	handles:      [WIRING_LIST_HANDLE_LIMIT]u32, // The numbers of the lent handles, in the table of the root service; each one is still to prove.
}

// wiring_end_of_word is the border of the word of an end: the member, or
// false for a word that names none and for None.
wiring_end_of_word :: proc "contextless" (word: u32) -> (end: Wiring_End, ok: bool) {
	member, known := enum_word.member_of_word(Wiring_End, u64(word))
	if !known || member == .None {
		return .None, false
	}
	return member, true
}

// writer_stream_of_word is the border of the word of a writer stream: the
// member, or false for a word that names none and for None.
writer_stream_of_word :: proc "contextless" (word: u32) -> (stream: Writer_Stream, ok: bool) {
	member, known := enum_word.member_of_word(Writer_Stream, u64(word))
	if !known || member == .None {
		return .None, false
	}
	return member, true
}

// wiring_pace_of_word is the border of the word of a pace.
wiring_pace_of_word :: proc "contextless" (word: u32) -> (pace: Wiring_Pace, ok: bool) {
	return enum_word.member_of_word(Wiring_Pace, u64(word))
}

// row_refusal is the error record of a refused row: Bad_Value of the unit
// Wiring_Rows, the field as the argument, the word, the largest word that
// the border takes there, and the row from 1.
@(private = "file")
row_refusal :: proc "contextless" (row: u32, field: Wiring_Field, word: u64, largest: u64) -> errors.Error_Record {
	return errors.error_make(.Bad_Value, .Wiring_Rows, i64(field), i64(min(word, 1 << 62)), i64(min(largest, 1 << 62)), i64(row))
}

// end_handle_check checks the handle word of one end: a place from 1 to
// handle_count for Started, a number that is not 0 for Connected (the root
// service proves it against its own record of the connection), 0 for Child
// and Asker.
@(private = "file")
end_handle_check :: proc "contextless" (end: Wiring_End, place: u32, handle_count: u32) -> (largest: u64, ok: bool) {
	switch end {
	case .Started:
		return u64(handle_count), place != 0 && place <= handle_count
	case .Connected:
		return u64(max(u32)), place != 0
	case .Child, .Asker, .None:
		return 0, place == 0
	}
	return 0, false
}

// wiring_row_check is the border of one row. row is its number from 1,
// handle_count the lent handles of the list, and terms_start the first
// byte after the lent handles, list_size the bytes of the copy of the
// list. It refuses, in the order of the fields:
//
// - an end word that names no member, None, an Asker writer, a Child in a
//   Wire;
// - a handle place of 0 or past handle_count for Started, a number of 0
//   for Connected, and a word that is not 0 for Child and Asker;
// - a writer stream that names no member, and Log for a writer that is
//   not the Child;
// - an index of 0 or past module.RECORD_STREAM_INDEX_MOST where an index is
//   needed, and one that is not 0 for Log and for an Asker reader;
// - the two ends the Child, and the two ends one lent handle or one
//   connection;
// - a pace that names no member;
// - a capacity that is not 0 and not a power of two from
//   WIRING_CAPACITY_LEAST to WIRING_CAPACITY_MOST;
// - terms with a count and no offset, an offset and no count, a count past
//   module.RECORD_SIZE_LIMIT, terms before terms_start or past the list,
//   and terms for an Asker reader;
// - a condition with a count and no offset or an offset and no count, a
//   count that is not size_of(Condition_Terms), and a condition before
//   terms_start or past the list;
// - a paired row that is not an earlier row of the list, or beside the
//   record output `log`;
// - a reserved word that is not 0.
//
// It reads no state, and a refusal gives no row.
wiring_row_check :: proc "contextless" (row: Wiring, number: u32, form: Wiring_List_Form, handle_count: u32, terms_start: u32, list_size: u32) -> (checked: Checked_Wiring, refusal: errors.Error_Record, ok: bool) {
	writer_end, writer_known := wiring_end_of_word(row.writer_end)
	if !writer_known || writer_end == .Asker || (form == .Wire && writer_end == .Child) {
		return {}, row_refusal(number, .Writer_End, u64(row.writer_end), u64(Wiring_End.Connected)), false
	}
	if largest, place_ok := end_handle_check(writer_end, row.writer_handle, handle_count); !place_ok {
		return {}, row_refusal(number, .Writer_Handle, u64(row.writer_handle), largest), false
	}
	writer_stream, stream_known := writer_stream_of_word(row.writer_stream)
	if !stream_known || (writer_stream == .Log && writer_end != .Child) {
		return {}, row_refusal(number, .Writer_Stream, u64(row.writer_stream), u64(max(Writer_Stream))), false
	}
	switch writer_stream {
	case .Record_Output:
		if row.writer_index == 0 || row.writer_index > module.RECORD_STREAM_INDEX_MOST {
			return {}, row_refusal(number, .Writer_Index, u64(row.writer_index), module.RECORD_STREAM_INDEX_MOST), false
		}
	case .Log, .None:
		if row.writer_index != 0 {
			return {}, row_refusal(number, .Writer_Index, u64(row.writer_index), 0), false
		}
	}
	reader_end, reader_known := wiring_end_of_word(row.reader_end)
	if !reader_known || (form == .Wire && reader_end == .Child) || (reader_end == .Child && writer_end == .Child) {
		return {}, row_refusal(number, .Reader_End, u64(row.reader_end), u64(max(Wiring_End))), false
	}
	if largest, place_ok := end_handle_check(reader_end, row.reader_handle, handle_count); !place_ok {
		return {}, row_refusal(number, .Reader_Handle, u64(row.reader_handle), largest), false
	}
	// One lent handle, or one connection, at both ends is one process at
	// both ends. A place and a number of a connection name different
	// things: the root service compares their processes.
	if reader_end == writer_end && row.reader_handle != 0 && row.reader_handle == row.writer_handle {
		return {}, row_refusal(number, .Reader_Handle, u64(row.reader_handle), u64(handle_count)), false
	}
	if reader_end == .Asker {
		if row.reader_index != 0 {
			return {}, row_refusal(number, .Reader_Index, u64(row.reader_index), 0), false
		}
	} else if row.reader_index == 0 || row.reader_index > module.RECORD_STREAM_INDEX_MOST {
		return {}, row_refusal(number, .Reader_Index, u64(row.reader_index), module.RECORD_STREAM_INDEX_MOST), false
	}
	pace, pace_known := wiring_pace_of_word(row.pace)
	if !pace_known {
		return {}, row_refusal(number, .Pace, u64(row.pace), u64(max(Wiring_Pace))), false
	}
	capacity := row.capacity
	if capacity == 0 {
		capacity = WIRING_CAPACITY_DEFAULT
	} else if capacity < WIRING_CAPACITY_LEAST || capacity > WIRING_CAPACITY_MOST || capacity & (capacity - 1) != 0 {
		return {}, row_refusal(number, .Capacity, u64(row.capacity), WIRING_CAPACITY_MOST), false
	}
	if (row.terms_offset == 0) != (row.terms_count == 0) {
		field := row.terms_offset == 0 ? Wiring_Field.Terms_Offset : Wiring_Field.Terms_Count
		word := row.terms_offset == 0 ? row.terms_offset : row.terms_count
		return {}, row_refusal(number, field, u64(word), 0), false
	}
	if row.terms_count != 0 {
		if reader_end == .Asker || row.terms_count > module.RECORD_SIZE_LIMIT {
			return {}, row_refusal(number, .Terms_Count, u64(row.terms_count), reader_end == .Asker ? 0 : module.RECORD_SIZE_LIMIT), false
		}
		// The sum is in 64 bits: two words near the top of 32 bits do not
		// wrap to a small end.
		if row.terms_offset < terms_start || u64(row.terms_offset) + u64(row.terms_count) > u64(list_size) {
			return {}, row_refusal(number, .Terms_Offset, u64(row.terms_offset), u64(list_size)), false
		}
	}
	// The condition: both words or neither, the size of its terms, and
	// after the lent handles inside the list. The root service reads its
	// fields against the record of the writer.
	if (row.condition_offset == 0) != (row.condition_count == 0) {
		field := row.condition_offset == 0 ? Wiring_Field.Condition_Offset : Wiring_Field.Condition_Count
		return {}, row_refusal(number, field, 0, 0), false
	}
	if row.condition_count != 0 {
		if row.condition_count != size_of(Condition_Terms) {
			return {}, row_refusal(number, .Condition_Count, u64(row.condition_count), size_of(Condition_Terms)), false
		}
		if row.condition_offset < terms_start || u64(row.condition_offset) + u64(row.condition_count) > u64(list_size) {
			return {}, row_refusal(number, .Condition_Offset, u64(row.condition_offset), u64(list_size)), false
		}
	}
	// The source of a pair comes earlier in the list, so its reader end
	// reaches the process before the end of the pair. A Wire has one row,
	// so it names no pair. The root service checks the rest of the pair
	// against the module files.
	if row.paired_row != 0 && (row.paired_row >= number || writer_stream != .Record_Output) {
		return {}, row_refusal(number, .Paired_Row, u64(row.paired_row), u64(max(number, 1) - 1)), false
	}
	for word in row.reserved {
		if word != 0 {
			return {}, row_refusal(number, .Reserved, u64(word), 0), false
		}
	}
	checked = {
		writer_end    = writer_end,
		writer_handle = row.writer_handle,
		writer_stream = writer_stream,
		writer_index  = row.writer_index,
		reader_end    = reader_end,
		reader_handle = row.reader_handle,
		reader_index  = row.reader_index,
		pace          = pace,
		capacity      = capacity,
		terms_offset  = row.terms_offset,
		terms_count   = row.terms_count,
		condition_offset = row.condition_offset,
		paired_row    = row.paired_row,
	}
	return checked, {}, true
}

// wiring_list_check is the border of a whole list, in the private copy of
// the memory that the asker lent. It refuses:
//
// - a copy of no byte, past WIRING_LIST_BYTES_MOST, or smaller than its
//   head;
// - a reserved word of the head that is not 0;
// - a count of rows of 0, past WIRING_LIST_ROW_LIMIT, or not 1 for a Wire;
// - a count of lent handles past WIRING_LIST_HANDLE_LIMIT;
// - rows and handles past the copy;
// - each row that wiring_row_check refuses, with its number;
// - two rows that wire the record output `log` of the child;
// - one handle number in two places of the lent handles: the error record
//   has the unit Lent_Handles, the second place as its value and the first
//   as its limit.
//
// The error record has the unit Wiring_Rows; found is 0 for the list as a
// whole, else the row from 1. On a refusal, list holds no row.
wiring_list_check :: proc "contextless" (copy_of_list: []u8, form: Wiring_List_Form, list: ^Checked_Wiring_List) -> (refusal: errors.Error_Record, ok: bool) {
	list^ = {}
	size := len(copy_of_list)
	if size < size_of(Wiring_List_Head) || size > WIRING_LIST_BYTES_MOST {
		return errors.error_make(.Bad_Value, .Wiring_Rows, 0, i64(size), WIRING_LIST_BYTES_MOST), false
	}
	head: Wiring_List_Head
	intrinsics.mem_copy_non_overlapping(&head, raw_data(copy_of_list), size_of(head))
	for word in head.reserved {
		if word != 0 {
			return errors.error_make(.Bad_Value, .Wiring_Rows, 0, i64(word), 0), false
		}
	}
	rows_most: u32 = form == .Wire ? 1 : WIRING_LIST_ROW_LIMIT
	if head.row_count == 0 || head.row_count > rows_most {
		return errors.error_make(.Bad_Value, .Wiring_Rows, 0, i64(head.row_count), i64(rows_most)), false
	}
	if head.handle_count > WIRING_LIST_HANDLE_LIMIT {
		return errors.error_make(.Bad_Value, .Lent_Handles, 0, i64(head.handle_count), WIRING_LIST_HANDLE_LIMIT), false
	}
	// The counts are bounded above, so the sizes do not wrap.
	rows_end := size_of(Wiring_List_Head) + int(head.row_count) * size_of(Wiring)
	terms_start := rows_end + int(head.handle_count) * size_of(u32)
	if terms_start > size {
		return errors.error_make(.Out_Of_Range, .Bytes, 0, i64(terms_start), i64(size)), false
	}
	log_rows: u32
	for index in 0 ..< head.row_count {
		row: Wiring
		intrinsics.mem_copy_non_overlapping(&row, &copy_of_list[size_of(Wiring_List_Head) + int(index) * size_of(Wiring)], size_of(Wiring))
		checked, row_refused, row_ok := wiring_row_check(row, index + 1, form, head.handle_count, u32(terms_start), u32(size))
		if !row_ok {
			list^ = {}
			return row_refused, false
		}
		if checked.writer_stream == .Log {
			log_rows += 1
			if log_rows > 1 {
				list^ = {}
				return errors.error_make(.Bad_Value, .Wiring_Rows, i64(Wiring_Field.Writer_Stream), i64(row.writer_stream), 0, i64(index + 1)), false
			}
		}
		list.rows[index] = checked
	}
	for index in 0 ..< head.handle_count {
		word: u32
		intrinsics.mem_copy_non_overlapping(&word, &copy_of_list[rows_end + int(index) * size_of(u32)], size_of(u32))
		// One handle in two places would be proved once and closed twice;
		// a list names each lent handle once.
		for before in 0 ..< index {
			if list.handles[before] == word {
				list^ = {}
				return errors.error_make(.Bad_Value, .Lent_Handles, 0, i64(index) + 1, i64(before) + 1), false
			}
		}
		list.handles[index] = word
	}
	list.row_count = head.row_count
	list.handle_count = head.handle_count
	return {}, true
}

// wiring_list_write writes a list in memory of an asker: the head, the
// rows, the handles. The terms are the bytes that the caller writes at the
// offsets of its rows. false: the list does not fit the bytes.
wiring_list_write :: proc "contextless" (bytes: []u8, rows: []Wiring, handles: []u32) -> bool {
	end := size_of(Wiring_List_Head) + len(rows) * size_of(Wiring) + len(handles) * size_of(u32)
	if len(rows) > WIRING_LIST_ROW_LIMIT || len(handles) > WIRING_LIST_HANDLE_LIMIT || end > len(bytes) {
		return false
	}
	head := Wiring_List_Head{row_count = u32(len(rows)), handle_count = u32(len(handles))}
	intrinsics.mem_copy_non_overlapping(raw_data(bytes), &head, size_of(head))
	if len(rows) > 0 {
		intrinsics.mem_copy_non_overlapping(&bytes[size_of(Wiring_List_Head)], raw_data(rows), len(rows) * size_of(Wiring))
	}
	if len(handles) > 0 {
		intrinsics.mem_copy_non_overlapping(&bytes[size_of(Wiring_List_Head) + len(rows) * size_of(Wiring)], raw_data(handles), len(handles) * size_of(u32))
	}
	return true
}

// wiring_terms_start gives the first byte after the lent handles of a list
// of row_count rows and handle_count handles: where its terms can start.
wiring_terms_start :: proc "contextless" (row_count: int, handle_count: int) -> int {
	return size_of(Wiring_List_Head) + row_count * size_of(Wiring) + handle_count * size_of(u32)
}
