package console_results

import "modus:contract/errors"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/text_encoding"
import "modus:contract/value_kinds"
import "modus:support/sentence"

// What a part of a drawn result is. The caller of a drawer chooses the
// color of each part: a value has the color of its value kind
// (`part_value_kind`), as in the log and on the site of the system.
Part :: enum u8 {
	Plain     = 0, // A text value, and the spaces between two parts.
	Label     = 1, // The name of a field, the head of a column, the place of a row of bytes.
	Note      = 2, // What the drawer says about the result: the count of rows, the rows that are not shown.
	Failure   = 3, // The sentence of an error.
	Number    = 4, // An Integer that is a plain number.
	Handle    = 5, // A handle.
	Type      = 6, // The name of a record, or the kind of an object.
	Status    = 7, // An error kind.
	Operation = 8, // The operation or the export of an error.
	Size      = 9, // An Integer field that counts a size, and its unit.
	Time      = 10, // An Integer field that counts a time, and its unit.
	Module    = 11, // A Text field that holds the name of a module.
	Version   = 12, // A field that holds a hash, in hexadecimal.
}

// part_value_kind gives the value kind of a part. None: the part is not a
// value, and the caller draws it plain, dim or as a failure.
part_value_kind :: proc "contextless" (part: Part) -> value_kinds.Value_Kind {
	switch part {
	case .Number:
		return .Number
	case .Size:
		return .Size
	case .Time:
		return .Time
	case .Handle:
		return .Handle
	case .Type:
		return .Type
	case .Status:
		return .Status
	case .Operation:
		return .Operation
	case .Module:
		return .Module
	case .Version:
		return .Version
	case .Plain, .Label, .Note, .Failure:
	}
	return .None
}

// value_kind_part gives the part of a value of a value kind that the
// contract wrote (module.field_kind_text): the kinds of a field only.
@(private = "file")
value_kind_part :: proc "contextless" (kind: value_kinds.Value_Kind) -> Part {
	switch kind {
	case .Time:
		return .Time
	case .Version:
		return .Version
	case .Status:
		return .Status
	case .None, .Number, .Size, .Handle, .Value, .Grant, .Type, .Operation, .Command, .Module, .File, .Guide, .Term, .Yes, .No, .Procedure, .Constant, .Variable:
		// field_kind_text gives a number for each other kind of a field.
	}
	return .Number
}

// Where a drawer writes. The caller gives the two procedures. A drawer
// calls `write` for each part of a line, then `end_line`. Before the parts
// of a line it sets `continuation`: the column where the rest of the line
// starts when the window of the caller is narrower than the line, so that a
// long value goes on under its own start and is never cut.
Sink :: struct {
	data:         rawptr, // The state of the caller.
	write:        proc "contextless" (sink: ^Sink, text: string, part: Part), // One part of the line.
	end_line:     proc "contextless" (sink: ^Sink), // The line ends.
	continuation: int, // The column where a line that is too long goes on.
}

COLUMN_LIMIT :: 40 // The most columns of a drawn table: the fields of a record that join makes.
CONTINUATION_MOST :: 48 // A line goes on under its last column only when that column starts at or before this one.
COLUMN_GAP :: 2 // The spaces between two columns.
BYTES_IN_A_ROW :: 16 // The bytes of one row of a view of bytes.
// The bytes of the text of one cell: the values of a log fact in
// hexadecimal, two digits for each byte, are the longest; a hash takes 64,
// a number at most 20.
CELL_TEXT_CAPACITY :: 2 * value_kinds.FACT_VALUES_FIELD_BYTES

BLANKS :: "                                                                "

// blanks writes a count of spaces.
blanks :: proc "contextless" (sink: ^Sink, count: int) {
	blank := BLANKS
	rest := count
	for rest > 0 {
		taken := min(rest, len(blank))
		sink.write(sink, blank[:taken], .Plain)
		rest -= taken
	}
}

// One value of a field, as text.
Cell :: struct {
	text:   string, // The text of the value.
	number: bool, // The value is a number: it is aligned at the right.
	part:   Part, // What the value is.
	unit:   string, // The unit of a Size or a Time, with the space before it: " pages". "" for another value.
}

// integer_part gives the part of an Integer field from the value kind that
// its description states, and the text of its unit. A unit that is not one
// of the contract is a plain number: a description of another party can
// hold anything, and a guess would show a wrong unit.
integer_part :: proc "contextless" (item: module.Field) -> (part: Part, unit: string) {
	if item.type != u8(module.Type.Integer) || !value_kinds.integer_unit_valid(item.integer_unit) {
		return .Number, ""
	}
	switch item.integer_unit.kind {
	case .Size:
		return .Size, value_kinds.integer_unit_text(item.integer_unit)
	case .Time:
		return .Time, value_kinds.integer_unit_text(item.integer_unit)
	case .None, .Number, .Handle, .Value, .Grant, .Status, .Type, .Operation, .Command, .Module, .File, .Guide, .Term, .Version, .Yes, .No, .Procedure, .Constant, .Variable:
		// integer_unit_valid takes no other kind: a plain number.
	}
	return .Number, ""
}

// field_at_the_right says if the values of a field are at the right of
// their column: the digits of an Integer, of a hexadecimal Integer and of
// a handle. A status is a name, and a module name and a hash are at the
// left as a text is.
field_at_the_right :: proc "contextless" (item: module.Field) -> bool {
	type, type_ok := module.field_type(item)
	kind, kind_ok := module.field_kind(item)
	if !type_ok || !kind_ok {
		return false
	}
	switch type {
	case .Integer:
		return kind == .Plain || kind == .Hexadecimal || kind == .Hexadecimal_Sixteen_Digits || kind == .Hundredths || kind == .Nanoseconds_As_Microseconds || kind == .Tenths || kind == .Hexadecimal_No_Leading_Zero || kind == .Time_Of_Day
	case .Handle:
		return true
	case .None, .Text, .Record, .Table, .Bytes:
	}
	return false
}

// hexadecimal_text writes "0x" and two hexadecimal digits for each byte of
// a field of size bytes, in buffer: the width of the text says the size.
hexadecimal_text :: proc "contextless" (buffer: []u8, value: u64, size: u32) -> string {
	writer := sentence.Writer {
		buffer = buffer,
	}
	sentence.write_part(&writer, "0x")
	sentence.write_hex(&writer, value, 2 * int(size))
	return sentence.written(&writer)
}

// hash_text writes two hexadecimal digits for each byte of a hash, the
// first byte first, in buffer. A hash that the buffer cannot hold whole
// gives "": a hash is never cut.
hash_text :: proc "contextless" (buffer: []u8, bytes: []u8) -> string {
	if 2 * len(bytes) > len(buffer) {
		return ""
	}
	digits := sentence.HEX_DIGITS
	for value, index in bytes {
		buffer[2 * index] = digits[value >> 4]
		buffer[2 * index + 1] = digits[value & 0xF]
	}
	return string(buffer[:2 * len(bytes)])
}

// cell_of gives the text of one field of a record, by its type and its
// field kind. The text of a number, of a status of a word that names no
// member and of a hash is in buffer, of CELL_TEXT_CAPACITY bytes; the text
// of a Text field is in the record, and the name of a status in the
// contract.
cell_of :: proc "contextless" (row: []u8, item: module.Field, buffer: []u8) -> Cell {
	// A byte that names no type or no kind: the check of the description
	// refused it, and the cell is empty.
	type, type_ok := module.field_type(item)
	kind, kind_ok := module.field_kind(item)
	if !type_ok || !kind_ok {
		return {}
	}
	// The kinds whose form the kind alone decides: the text that the
	// sentence of a fact writes, from the one writer of the contract.
	if text, value_kind, by_kind := module.field_kind_text(buffer, row, item); by_kind {
		return {text = text, number = type == .Integer, part = value_kind_part(value_kind)}
	}
	switch type {
	case .None, .Record, .Table:
		// A record holds no such field (module.field_size): an empty cell.
	case .Bytes:
		// A Bytes field is a hash or the values of a log fact
		// (module.field_kind_valid).
		bytes := module.field_bytes(row, item)
		if bytes == nil {
			return {}
		}
		switch kind {
		case .Hash:
			return {text = hash_text(buffer, bytes), part = .Version}
		case .Fact_Values, .Log_Body:
			// The raw form of the values or of the body of a log record:
			// the zeros after the last byte that is not zero say nothing,
			// as on the serial line.
			last := len(bytes)
			for last > 0 && bytes[last - 1] == 0 {
				last -= 1
			}
			return {text = hash_text(buffer, bytes[:last]), part = .Number}
		case .Text_View:
			// A text of more than 12 bytes whose out-of-line bytes the row
			// does not carry: its first bytes, then its length, and never
			// a text that looks whole.
			if len(bytes) != value_kinds.TEXT_VIEW_BYTES {
				return {}
			}
			length := u64(bytes[0]) | u64(bytes[1]) << 8 | u64(bytes[2]) << 16 | u64(bytes[3]) << 24
			// Bytes of the writer that nobody checked: the rule of the
			// filter of the kernel, in a copy.
			prefix: [value_kinds.TEXT_VIEW_PREFIX_BYTES]u8
			copy(prefix[:], bytes[4:])
			text_encoding.invalid_sequences_replace(prefix[:])
			return {text = sentence.format(buffer, string(prefix[:]), "… (", length, " bytes)"), part = .Plain}
		case .Plain, .Hexadecimal, .Status, .Module_Name, .Hexadecimal_Sixteen_Digits, .Hundredths, .Nanoseconds_As_Microseconds, .Tenths, .Hexadecimal_No_Leading_Zero, .Time_Of_Day:
			// module.field_kind_valid refuses these kinds on Bytes.
		case .Hash_Head:
			// module.field_kind_text wrote it above.
		}
		return {}
	case .Integer:
		value := module.field_integer(row, item)
		switch kind {
		case .Hexadecimal:
			return {text = hexadecimal_text(buffer, u64(value), module.field_size(item)), number = true, part = .Number}
		case .Status:
			which, which_ok := module.field_contract_enum(item)
			if name, named := module.contract_enum_member_name(which, u64(value)); which_ok && named {
				return {text = name, part = .Status}
			}
			// A word that names no member: its number, never the name of
			// another member.
			return {text = sentence.format(buffer, u64(value)), part = .Number}
		case .Plain, .Module_Name, .Hash, .Fact_Values, .Hash_Head, .Text_View, .Log_Body:
			// module.field_kind_valid refuses each of them but Plain on an
			// Integer.
		case .Hexadecimal_Sixteen_Digits, .Hundredths, .Nanoseconds_As_Microseconds, .Tenths, .Hexadecimal_No_Leading_Zero, .Time_Of_Day:
			// module.field_kind_text wrote them above.
		}
		part, unit := integer_part(item)
		if item.unsigned && module.field_size(item) == 8 {
			return {text = sentence.format(buffer, u64(value)), number = true, part = part, unit = unit}
		}
		return {text = sentence.format(buffer, value), number = true, part = part, unit = unit}
	case .Handle:
		handle: u64
		if u64(item.offset) <= u64(len(row)) && u64(len(row)) - u64(item.offset) >= 4 {
			for index in 0 ..< u32(4) {
				handle |= u64(row[item.offset + index]) << (8 * index)
			}
		}
		return {text = sentence.format(buffer, handle), number = true, part = .Handle}
	case .Text:
		return {text = module.field_text(row, item), part = kind == .Module_Name ? Part.Module : Part.Plain}
	}
	return {}
}

// cell_write writes one cell in a column of a width: a number at the right
// of its column, a text at the left. The last column has no spaces after
// its text.
cell_write :: proc "contextless" (sink: ^Sink, text: string, width: int, number: bool, last: bool, part: Part) {
	if number {
		blanks(sink, width - len(text))
	}
	sink.write(sink, text, part)
	if last {
		return
	}
	if !number {
		blanks(sink, width - len(text))
	}
	blanks(sink, COLUMN_GAP)
}

// head_length gives the columns of the head of a column: the name, and the
// unit in parentheses after it when the field states one. unit is the text
// of the unit with the space before it (" pages"), or "".
head_length :: proc "contextless" (name_length: int, unit: string) -> int {
	if len(unit) < 2 {
		return name_length
	}
	return name_length + len(" (") + len(unit) - 1 + len(")")
}

// head_write writes the head of one column, dim, aligned as its values are:
// the name, then the unit of a Size or a Time in parentheses: "time (ms)".
// The unit is in the head and not in each cell, because it is the same in
// each row.
head_write :: proc "contextless" (sink: ^Sink, name: string, unit: string, width: int, number: bool, last: bool) {
	length := head_length(len(name), unit)
	if number {
		blanks(sink, width - length)
	}
	sink.write(sink, name, .Label)
	if len(unit) >= 2 {
		sink.write(sink, " (", .Label)
		sink.write(sink, unit[1:], .Label)
		sink.write(sink, ")", .Label)
	}
	if last {
		return
	}
	if !number {
		blanks(sink, width - length)
	}
	blanks(sink, COLUMN_GAP)
}

// draw_integer draws an Integer: its decimal text, in one line.
draw_integer :: proc "contextless" (sink: ^Sink, value: i64) {
	buffer: [24]u8
	sink.continuation = 0
	sink.write(sink, sentence.format(buffer[:], value), .Number)
	sink.end_line(sink)
}

// draw_text draws a Text: its bytes, one line for each line of the text.
// An empty text is one empty line.
draw_text :: proc "contextless" (sink: ^Sink, text: string) {
	sink.continuation = 0
	rest := text
	for {
		end := 0
		for end < len(rest) && rest[end] != '\n' {
			end += 1
		}
		sink.write(sink, rest[:end], .Plain)
		sink.end_line(sink)
		if end >= len(rest) {
			break
		}
		rest = rest[end + 1:]
		// A text that ends with the end of a line has no empty line after it.
		if len(rest) == 0 {
			break
		}
	}
}

// draw_record draws a Record: the name of its record, then one line for
// each field, with the name of the field and its value. A field that
// counts a size or a time has its unit after its value: "time  120 ms".
// file and detail
// name the description of the record; bytes are its bytes.
draw_record :: proc "contextless" (sink: ^Sink, file: []u8, detail: u32, bytes: []u8) {
	sink.continuation = 0
	described, ok := module.record_type(file, detail)
	if !ok || int(described.size) > len(bytes) {
		sink.write(sink, "a record with no valid description", .Note)
		sink.end_line(sink)
		return
	}
	sink.write(sink, module.string_at(file, described.name_offset, described.name_count), .Type)
	sink.end_line(sink)
	width := 0
	for number in 0 ..< described.field_count {
		if item, found := module.field(file, described, number); found {
			width = max(width, int(item.name_count))
		}
	}
	sink.continuation = min(COLUMN_GAP + width + COLUMN_GAP, CONTINUATION_MOST)
	for number in 0 ..< described.field_count {
		item, found := module.field(file, described, number)
		if !found {
			continue
		}
		name := module.string_at(file, item.name_offset, item.name_count)
		buffer: [CELL_TEXT_CAPACITY]u8
		cell := cell_of(bytes, item, buffer[:])
		blanks(sink, COLUMN_GAP)
		sink.write(sink, name, .Label)
		blanks(sink, width - len(name) + COLUMN_GAP)
		sink.write(sink, cell.text, cell.part)
		// The unit is in the color of the value, as a value run of the log
		// covers the number and its unit.
		if cell.unit != "" {
			sink.write(sink, cell.unit, cell.part)
		}
		sink.end_line(sink)
	}
	sink.continuation = 0
}

// draw_table draws a Table: a line with the names of the fields, a line for
// each row, and the count of rows with the name of the record. Each column
// has the least width that holds its head and its values; a number is at
// the right of its column. The head of a field that counts a size or a time
// has its unit: "time (ms)". No value is cut: a line wider than the window
// goes on under its last column.
//
// row_limit: the most rows that are drawn. When the table has more, one
// line says how many are not shown, with rest_hint after it: how the
// reader gets them.
draw_table :: proc "contextless" (sink: ^Sink, file: []u8, detail: u32, bytes: []u8, row_limit: int, rest_hint: string = "") {
	sink.continuation = 0
	described, ok := module.record_type(file, detail)
	if !ok || described.size == 0 {
		sink.write(sink, "a table with no valid description", .Note)
		sink.end_line(sink)
		return
	}
	size := int(described.size)
	rows := len(bytes) / size
	shown := clamp(row_limit, 0, rows)
	field_count := min(int(described.field_count), COLUMN_LIMIT)
	items: [COLUMN_LIMIT]module.Field
	units: [COLUMN_LIMIT]string
	widths: [COLUMN_LIMIT]int
	for number in 0 ..< field_count {
		items[number], _ = module.field(file, described, u32(number))
		_, units[number] = integer_part(items[number])
		widths[number] = head_length(int(items[number].name_count), units[number])
	}
	for index in 0 ..< shown {
		row := bytes[index * size:][:size]
		for number in 0 ..< field_count {
			buffer: [CELL_TEXT_CAPACITY]u8
			widths[number] = max(widths[number], len(cell_of(row, items[number], buffer[:]).text))
		}
	}
	last_start := 0
	for number in 0 ..< field_count - 1 {
		last_start += widths[number] + COLUMN_GAP
	}
	sink.continuation = last_start <= CONTINUATION_MOST ? last_start : COLUMN_GAP
	for number in 0 ..< field_count {
		name := module.string_at(file, items[number].name_offset, items[number].name_count)
		head_write(sink, name, units[number], widths[number], field_at_the_right(items[number]), number == field_count - 1)
	}
	sink.end_line(sink)
	for index in 0 ..< shown {
		row := bytes[index * size:][:size]
		for number in 0 ..< field_count {
			buffer: [CELL_TEXT_CAPACITY]u8
			cell := cell_of(row, items[number], buffer[:])
			cell_write(sink, cell.text, widths[number], cell.number, number == field_count - 1, cell.part)
		}
		sink.end_line(sink)
	}
	sink.continuation = 0
	count_text: [24]u8
	if rows > shown {
		sink.write(sink, sentence.format(count_text[:], u64(rows - shown)), .Number)
		sink.write(sink, rows - shown == 1 ? " row more is not shown" : " rows more are not shown", .Note)
		sink.write(sink, rest_hint, .Note)
		sink.end_line(sink)
	}
	sink.write(sink, sentence.format(count_text[:], u64(rows)), .Number)
	sink.write(sink, rows == 1 ? " row of " : " rows of ", .Note)
	sink.write(sink, module.string_at(file, described.name_offset, described.name_count), .Type)
	sink.end_line(sink)
}

// ---- A Stream: a table drawn one row at a time.
//
// A Stream has no rows to measure before its draw: each record comes
// while the line runs. So the width of each column is the widest text that
// its field can hold, from the record description, and a row never moves
// the rows above it (src/md/features/module_outputs.md, "The console
// form").

// The columns of a Stream, from its record description.
Stream_Columns :: struct {
	items:  [COLUMN_LIMIT]module.Field,
	units:  [COLUMN_LIMIT]string,
	widths: [COLUMN_LIMIT]int,
	count:  int,
	size:   int, // The bytes of one record.
}

// integer_digits gives the most characters of the decimal text of an
// Integer field of a size: the digits of its largest value, and the sign
// of its least one.
integer_digits :: proc "contextless" (size: u32, unsigned: bool) -> int {
	switch size {
	case 1:
		return unsigned ? 3 : 4
	case 2:
		return unsigned ? 5 : 6
	case 4:
		return unsigned ? 10 : 11
	}
	// 8 bytes: "18446744073709551615" and "-9223372036854775808" both have 20.
	return 20
}

// field_width gives the widest text that cell_of writes for a field: the
// digits of an Integer, "0x" and two digits for each byte of a hexadecimal
// Integer, the longest text of the kinds that write a number in another
// form, the longest member of a status or its number, the 10 digits of
// a handle, the bytes of a Text, two digits for each byte of a Bytes field.
// A field whose type or kind names nothing gives 0: its cell is empty.
field_width :: proc "contextless" (item: module.Field) -> int {
	type, type_ok := module.field_type(item)
	kind, kind_ok := module.field_kind(item)
	if !type_ok || !kind_ok {
		return 0
	}
	size := module.field_size(item)
	switch type {
	case .None, .Record, .Table:
		return 0
	case .Bytes:
		return 2 * int(size)
	case .Handle:
		return 10
	case .Text:
		return int(size)
	case .Integer:
		switch kind {
		case .Hexadecimal, .Hexadecimal_No_Leading_Zero:
			return 2 + 2 * int(size)
		case .Hexadecimal_Sixteen_Digits:
			return 16
		case .Hundredths, .Tenths:
			// The digits and the point: a value under one unit gains a 0
			// before the point, and keeps no more width than its sign
			// and its digits took.
			return integer_digits(size, item.unsigned) + 1
		case .Nanoseconds_As_Microseconds:
			// Three digits fewer, the point, a decimal and " us"; a value
			// under one microsecond is "0.0 us".
			return max(6, integer_digits(size, true) + 2)
		case .Time_Of_Day:
			// The hours of the largest count of seconds, ":" and two
			// digits of minutes; two digits of hours at least.
			return max(5, integer_digits(size, true))
		case .Status:
			// A word that names no member is drawn as its number.
			width := integer_digits(size, true)
			if which, which_ok := module.field_contract_enum(item); which_ok {
				for word in 0 ..< module.contract_enum_member_count(which) {
					if name, named := module.contract_enum_member_name(which, word); named {
						width = max(width, len(name))
					}
				}
			}
			return width
		case .Plain, .Module_Name, .Hash, .Fact_Values, .Hash_Head, .Text_View, .Log_Body:
		}
		return integer_digits(size, item.unsigned)
	}
	return 0
}

// stream_columns_of gives the columns of a Stream of a record description.
// ok is false for a description that the contract does not read, or of a
// record of 0 bytes.
stream_columns_of :: proc "contextless" (file: []u8, detail: u32) -> (columns: Stream_Columns, ok: bool) {
	described := module.record_type(file, detail) or_return
	if described.size == 0 {
		return {}, false
	}
	columns.size = int(described.size)
	columns.count = min(int(described.field_count), COLUMN_LIMIT)
	for number in 0 ..< columns.count {
		columns.items[number] = module.field(file, described, u32(number)) or_return
		_, columns.units[number] = integer_part(columns.items[number])
		columns.widths[number] = max(head_length(int(columns.items[number].name_count), columns.units[number]), field_width(columns.items[number]))
	}
	return columns, true
}

// stream_continuation gives the column where a row of a Stream goes on
// when it is wider than the window: under its last column, as draw_table
// does.
stream_continuation :: proc "contextless" (columns: ^Stream_Columns) -> int {
	last_start := 0
	for number in 0 ..< columns.count - 1 {
		last_start += columns.widths[number] + COLUMN_GAP
	}
	return last_start <= CONTINUATION_MOST ? last_start : COLUMN_GAP
}

// draw_stream_head draws the line of the names of the fields of a Stream.
draw_stream_head :: proc "contextless" (sink: ^Sink, columns: ^Stream_Columns, file: []u8) {
	sink.continuation = stream_continuation(columns)
	for number in 0 ..< columns.count {
		item := columns.items[number]
		head_write(sink, module.string_at(file, item.name_offset, item.name_count), columns.units[number], columns.widths[number], field_at_the_right(item), number == columns.count - 1)
	}
	sink.end_line(sink)
	sink.continuation = 0
}

// draw_stream_row draws one record of a Stream, in the columns of its head.
// A row of another size than the record draws nothing: the reader gives
// each record whole.
draw_stream_row :: proc "contextless" (sink: ^Sink, columns: ^Stream_Columns, row: []u8) {
	if len(row) != columns.size {
		return
	}
	sink.continuation = stream_continuation(columns)
	for number in 0 ..< columns.count {
		buffer: [CELL_TEXT_CAPACITY]u8
		cell := cell_of(row, columns.items[number], buffer[:])
		cell_write(sink, cell.text, columns.widths[number], cell.number, number == columns.count - 1, cell.part)
	}
	sink.end_line(sink)
	sink.continuation = 0
}

// draw_note draws one line that says something of a result and is no
// value of it: the joined record of a Stream, a gap, its end.
draw_note :: proc "contextless" (sink: ^Sink, text: string) {
	sink.continuation = 0
	sink.write(sink, text, .Note)
	sink.end_line(sink)
}

// draw_handle draws a Handle: its number, the kind of its object and its
// rights, as the kernel gives them to the caller: "Handle 65541: Memory
// (Give, Read, Write)". A handle that names no object has no rights.
draw_handle :: proc "contextless" (sink: ^Sink, handle: u64, kind: op.Object_Kind, rights: op.Rights) {
	sink.continuation = 0
	buffer: [24]u8
	sink.write(sink, "Handle ", .Plain)
	sink.write(sink, sentence.format(buffer[:], handle), .Handle)
	sink.write(sink, ": ", .Plain)
	sink.write(sink, sentence.object_names[kind], .Type)
	if kind != .None {
		rights_text: [160]u8
		writer := sentence.Writer {
			buffer = rights_text[:],
		}
		sentence.write_rights(&writer, rights, ", ")
		sink.write(sink, " (", .Plain)
		sink.write(sink, sentence.written(&writer), .Plain)
		sink.write(sink, ")", .Plain)
	}
	sink.end_line(sink)
}

// draw_bytes draws Bytes: rows of 16 bytes, each with the place of its
// first byte, the bytes in hexadecimal, and their characters. byte_limit:
// the most bytes that are drawn; one line says how many are not shown. The
// last line is the count of bytes. first_place: the place of the first
// byte in what the bytes come from.
draw_bytes :: proc "contextless" (sink: ^Sink, bytes: []u8, byte_limit: int, first_place: u64 = 0) {
	sink.continuation = 0
	shown := clamp(byte_limit, 0, len(bytes))
	for start := 0; start < shown; start += BYTES_IN_A_ROW {
		row := bytes[start:min(start + BYTES_IN_A_ROW, shown)]
		place_text: [16]u8
		place := sentence.Writer {
			buffer = place_text[:],
		}
		sentence.write_hex(&place, first_place + u64(start), 8)
		sink.write(sink, sentence.written(&place), .Label)
		blanks(sink, COLUMN_GAP)
		digits := sentence.HEX_DIGITS
		for value in row {
			pair := [2]u8{digits[value >> 4], digits[value & 0xF]}
			sink.write(sink, string(pair[:]), .Number)
			blanks(sink, 1)
		}
		blanks(sink, 3 * (BYTES_IN_A_ROW - len(row)) + 1)
		characters: [BYTES_IN_A_ROW]u8
		for value, index in row {
			characters[index] = value >= 32 && value <= 126 ? value : '.'
		}
		sink.write(sink, string(characters[:len(row)]), .Plain)
		sink.end_line(sink)
	}
	count_text: [24]u8
	if len(bytes) > shown {
		sink.write(sink, sentence.format(count_text[:], u64(len(bytes) - shown)), .Number)
		sink.write(sink, len(bytes) - shown == 1 ? " byte more is not shown" : " bytes more are not shown", .Note)
		sink.end_line(sink)
	}
	sink.write(sink, sentence.format(count_text[:], u64(len(bytes))), .Number)
	sink.write(sink, len(bytes) == 1 ? " byte" : " bytes", .Note)
	sink.end_line(sink)
}

// What a line that failed gives: the sentence of the failure, and the error
// record when a call gave one.
Failure :: struct {
	sentence:       string, // One sentence: what failed, and why.
	record:         ^errors.Error_Record, // nil: the console itself refused the line, and no call gave a record.
	operation:      string, // The name of the operation or of the export of the record.
	argument_names: []string, // The names of its parameters, from 1: the record names an argument by its number.
	details:        []errors.Error_Record, // The error details that the call wrote in the table of the caller.
	detail_count:   u64, // The count of error details of the full answer.
}

FAILURE_START :: "error: " // The start of each line of a failure.
FAILURE_LABEL_WIDTH :: 9 // The longest label of a line of an error record: "operation".

// failure_label writes the label of one line of an error record.
failure_label :: proc "contextless" (sink: ^Sink, label: string) {
	blanks(sink, COLUMN_GAP)
	sink.write(sink, label, .Label)
	blanks(sink, FAILURE_LABEL_WIDTH - len(label) + COLUMN_GAP)
}

// failure_argument_name gives the name of the argument that a record names
// by its number, or "".
failure_argument_name :: proc "contextless" (failure: Failure, record: ^errors.Error_Record) -> string {
	if record.argument >= 1 && record.argument <= i64(len(failure.argument_names)) {
		return failure.argument_names[record.argument - 1]
	}
	return ""
}

// draw_failure draws the error of a line. The first line is "error: " and
// the sentence. With an error record, the lines after it give the record as
// values: its kind, the operation, the argument, and the three values with
// their unit. With more than one error detail, one line for each detail
// follows, then the count of the details that the table did not hold.
draw_failure :: proc "contextless" (sink: ^Sink, failure: Failure) {
	sink.continuation = len(FAILURE_START)
	sink.write(sink, FAILURE_START, .Failure)
	sink.write(sink, failure.sentence, .Failure)
	sink.end_line(sink)
	record := failure.record
	if record == nil || record.kind == 0 {
		sink.continuation = 0
		return
	}
	number: [24]u8
	sink.continuation = COLUMN_GAP + FAILURE_LABEL_WIDTH + COLUMN_GAP
	failure_label(sink, "kind")
	if kind, kind_ok := errors.kind_of_word(record.kind); kind_ok {
		sink.write(sink, errors.KIND_NAMES[kind], .Status)
	} else {
		sink.write(sink, "an unknown kind, ", .Note)
		sink.write(sink, sentence.format(number[:], record.kind), .Number)
	}
	sink.end_line(sink)
	if failure.operation != "" {
		failure_label(sink, "operation")
		sink.write(sink, failure.operation, .Operation)
		sink.end_line(sink)
	}
	if record.argument != 0 {
		failure_label(sink, "argument")
		sink.write(sink, sentence.format(number[:], record.argument), .Number)
		if name := failure_argument_name(failure, record); name != "" {
			blanks(sink, 1)
			sink.write(sink, name, .Plain)
		}
		sink.end_line(sink)
	}
	failure_label(sink, "values")
	sink.write(sink, "value ", .Label)
	sink.write(sink, sentence.format(number[:], record.value), .Number)
	sink.write(sink, ", limit ", .Label)
	sink.write(sink, sentence.format(number[:], record.limit), .Number)
	sink.write(sink, ", found ", .Label)
	sink.write(sink, sentence.format(number[:], record.found), .Number)
	if record.unit != 0 {
		sink.write(sink, ", unit ", .Label)
		if unit, unit_ok := errors.unit_of_word(record.unit); unit_ok {
			sink.write(sink, errors.UNIT_NAMES[unit], .Plain)
		} else {
			sink.write(sink, sentence.format(number[:], record.unit), .Number)
		}
	}
	sink.end_line(sink)
	// The error record is the first detail: with one detail, the lines
	// above say all of it.
	sink.continuation = len(FAILURE_START)
	if failure.detail_count >= 2 {
		shown := min(u64(len(failure.details)), failure.detail_count)
		for &detail, index in failure.details[:shown] {
			buffer: [240]u8
			writer := sentence.Writer {
				buffer = buffer[:],
			}
			sentence.error_detail_number_text(&writer, u64(index + 1), failure.detail_count)
			sentence.error_text(&writer, &detail, failure.operation, failure_argument_name(failure, &detail))
			sink.write(sink, FAILURE_START, .Failure)
			sink.write(sink, sentence.written(&writer), .Failure)
			sink.end_line(sink)
		}
		if failure.detail_count > shown {
			buffer: [128]u8
			writer := sentence.Writer {
				buffer = buffer[:],
			}
			sentence.error_details_rest_text(&writer, shown, failure.detail_count)
			sink.write(sink, FAILURE_START, .Failure)
			sink.write(sink, sentence.written(&writer), .Failure)
			sink.end_line(sink)
		}
	}
	sink.continuation = 0
}
