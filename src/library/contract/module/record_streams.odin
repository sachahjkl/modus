package module

// The record outputs and the record inputs of a module
// (src/md/features/module_outputs.md, "The declaration in the module").
//
// A record output is a stream of records of one record type that the
// module writes while it works; a record input is a stream that it reads.
// The source declares each one as a package variable of
// `system.Record_Output(T)`, `system.Record_Input(T)` or
// `system.Record_Input_With_Terms(T, Terms)`, and the build
// writes one row for each in the tables Record_Outputs and Record_Inputs.
// The record of a row is a record description of the table Records, the one
// form that the exports and the log facts use. A file is hostile input:
// each reader below checks what it reads.

// The largest index of a row of the table Record_Outputs or of the table
// Record_Inputs: a wiring names a row in 16 bits. It is the bound of the
// field, not a bound of cost: a declaration costs nothing until a wiring.
RECORD_STREAM_INDEX_MOST :: 65_535

// Whether a generic record output has one ring for each wiring of the
// generic record input of its module, of the type of that wiring. A
// record output that is not generic is always Unpaired.
Record_Output_Pairing :: enum u8 {
	Unpaired = 0, // One type for the record output: its own record, or the one type of the generic record input.
	Paired   = 1, // One ring for each wiring of the generic record input, of the type of that wiring: the record output `forward` of the collector.
}

// How many wirings a record input takes, and of which types.
Wiring_Count :: enum u8 {
	One        = 0, // One wiring at a time.
	Many       = 1, // Several wirings of one type. For a generic record input, the first wiring fixes it.
	Many_Types = 2, // Several wirings, each of its own type: a generic record input only.
}

// One row of the table Record_Outputs: one record output that the module
// declares. The rows are sorted by name, and no two rows have one name.
//
// Example: `requests: system.Record_Output(Access_Record)` is the row with
// the name "requests", the line of help of its comment, and the index of
// the record "Access_Record" in the table Records.
Record_Output :: struct {
	name_offset:  u32, // The name of the package variable, in the string table.
	name_count:   u32, // Its bytes: at least 1.
	about_offset: u32, // One line of help, in the string table.
	about_count:  u32, // Its bytes.
	text_offset:  u32, // The documentation text: the comment of the declaration, in its Markdown.
	text_count:   u32, // Its bytes.
	record:       u32, // The index of the description of its record in the table Records; 0: a generic record output.
	pairing:      u8, // The byte of a Record_Output_Pairing (record_output_pairing_of_word).
	reserved:     [3]u8, // 0.
	place:        u64, // The memory offset of its package variable, where each loader writes the index of the row (record_stream_indexes_write); 0: the link kept no variable, as no code uses it.
}
#assert(size_of(Record_Output) == 40)

// One row of the table Record_Inputs: one record input that the module
// declares. The rows are sorted by name, no two rows have one name, and no
// row has the name of a record output.
//
// Example: `sources: system.Record_Input_With_Terms(system.Any_Record,
// Space_Terms, .Many_Types)` is the row with the name "sources", the record
// 0, the terms the index of "Space_Terms", and the count Many_Types.
Record_Input :: struct {
	name_offset:  u32, // The name of the package variable, in the string table.
	name_count:   u32, // Its bytes: at least 1.
	about_offset: u32, // One line of help, in the string table.
	about_count:  u32, // Its bytes.
	text_offset:  u32, // The documentation text: the comment of the declaration, in its Markdown.
	text_count:   u32, // Its bytes.
	record:       u32, // The index of the description of its record in the table Records; 0: a generic record input.
	terms:        u32, // The index of the description of its wiring terms in the table Records; 0: it takes no terms.
	wirings:      u8, // The byte of a Wiring_Count (wiring_count_of_word).
	reserved:     [7]u8, // 0.
	place:        u64, // The memory offset of its package variable, as for a record output; 0: none.
}
#assert(size_of(Record_Input) == 48)

// The bytes that a loader writes at the place of a declaration: the index
// of its row, a u32 little-endian, the first field of the variable
// (system.Record_Output, system.Record_Input). The library reads the index
// there: the variable has its address, and no name, at run time.
RECORD_STREAM_PLACE_SIZE :: 4

// record_stream_place_of_row gives the place of a row of the table
// Record_Outputs or Record_Inputs, read with no other check: validate and
// the loader read the places of rows that the other readers may refuse.
@(private = "file")
record_stream_place_of_row :: proc "contextless" (file: []u8, kind: Table_Kind, index: u32) -> (place: u64, ok: bool) {
	#partial switch kind {
	case .Record_Outputs:
		row := record(file, kind, index, Record_Output) or_return
		return row.place, true
	case .Record_Inputs:
		row := record(file, kind, index, Record_Input) or_return
		return row.place, true
	}
	return 0, false
}

// record_stream_place_valid says if a place is one that a loader writes:
// 0, or RECORD_STREAM_PLACE_SIZE bytes on a multiple of that size inside
// one segment that the loader can write and that stays writable after the
// load, and outside the own-hash place. A place in code would let a file
// make the loader write into its code; the library writes the state of the
// variable after the load, so a segment that loses Write would fault it;
// and an index over the hash would change the hash that the module reads.
@(private = "file")
record_stream_place_valid :: proc "contextless" (file: []u8, place: u64) -> bool {
	if place == 0 {
		return true
	}
	if place % RECORD_STREAM_PLACE_SIZE != 0 || !writable_range(file, place, RECORD_STREAM_PLACE_SIZE) {
		return false
	}
	for index in 1 ..< count(file, .Segments) {
		segment, _ := record(file, .Segments, index, Segment)
		if range_holds(segment.memory_offset, segment.memory_size, place, RECORD_STREAM_PLACE_SIZE) && .Read_Only_After_Load in segment.flags {
			return false
		}
	}
	if hash_place, present := own_hash_place(file); present && ranges_meet(hash_place, HASH_SIZE, place, RECORD_STREAM_PLACE_SIZE) {
		return false
	}
	return true
}

// ranges_meet says if two runs of bytes share a byte, with no sum that can
// wrap: each value comes from a file that the loader does not trust.
@(private = "file")
ranges_meet :: proc "contextless" (first, first_size, second, second_size: u64) -> bool {
	if first <= second {
		return second - first < first_size
	}
	return first - second < second_size
}

// record_stream_places_valid checks the place of each row of the two
// tables: validate calls it, so a loader of a valid file writes each index
// in writable data, and no other write of a loader, a rebase or an import
// slot, falls on an index. The rows past RECORD_STREAM_INDEX_MOST are not
// read: a wiring names none, and record_streams_check refuses such a
// table.
record_stream_places_valid :: proc "contextless" (file: []u8) -> bool {
	lowest, highest := max(u64), u64(0)
	for kind in ([2]Table_Kind{.Record_Outputs, .Record_Inputs}) {
		rows := min(max(count(file, kind), 1) - 1, RECORD_STREAM_INDEX_MOST)
		for index in 1 ..= rows {
			place, ok := record_stream_place_of_row(file, kind, index)
			if !ok || !record_stream_place_valid(file, place) {
				return false
			}
			if place != 0 {
				lowest, highest = min(lowest, place), max(highest, place)
			}
		}
	}
	if highest == 0 {
		return true
	}
	for index in 1 ..< count(file, .Slots) {
		slot, _ := record(file, .Slots, index, Slot)
		if location_meets_a_place(file, slot.memory_offset, lowest, highest) {
			return false
		}
	}
	// The walk of rebase_range, with no write.
	cursor: u64
	for index in 0 ..< count(file, .Rebases) {
		word, _ := record(file, .Rebases, index, u64)
		if word & 1 == 0 {
			if location_meets_a_place(file, word, lowest, highest) {
				return false
			}
			cursor = word + REBASE_WORD_SIZE
			continue
		}
		for bit in u64(1) ..= REBASE_BITMAP_LOCATIONS {
			if word >> bit & 1 != 0 && location_meets_a_place(file, cursor + REBASE_WORD_SIZE * (bit - 1), lowest, highest) {
				return false
			}
		}
		cursor += REBASE_WORD_SIZE * REBASE_BITMAP_LOCATIONS
	}
	return true
}

// location_meets_a_place says if the 8 bytes of a location that a loader
// writes share a byte with the place of a row. Most locations lie outside
// the span from the lowest place to the highest one: they cost one
// comparison, and only a location inside it reads the rows.
@(private = "file")
location_meets_a_place :: proc "contextless" (file: []u8, location: u64, lowest, highest: u64) -> bool {
	// validate took each place inside a segment, so highest + its size
	// does not wrap.
	if !ranges_meet(location, REBASE_WORD_SIZE, lowest, highest - lowest + RECORD_STREAM_PLACE_SIZE) {
		return false
	}
	for kind in ([2]Table_Kind{.Record_Outputs, .Record_Inputs}) {
		rows := min(max(count(file, kind), 1) - 1, RECORD_STREAM_INDEX_MOST)
		for index in 1 ..= rows {
			place, _ := record_stream_place_of_row(file, kind, index)
			if place != 0 && ranges_meet(location, REBASE_WORD_SIZE, place, RECORD_STREAM_PLACE_SIZE) {
				return true
			}
		}
	}
	return false
}

// record_stream_indexes_write writes the index of each row at its place,
// in the memory of a module that a loader prepares, when the place is
// between the offsets first and end: a loader that writes one segment at a
// time calls it for each one, as for own_hash_write. A row with the place
// 0 writes nothing. false: a place is not one that validate takes, or is
// outside memory; the module must not run. Call validate first.
record_stream_indexes_write :: proc "contextless" (file: []u8, memory: []u8, first: u64 = 0, end: u64 = max(u64)) -> bool {
	for kind in ([2]Table_Kind{.Record_Outputs, .Record_Inputs}) {
		rows := min(max(count(file, kind), 1) - 1, RECORD_STREAM_INDEX_MOST)
		for index in 1 ..= rows {
			place, ok := record_stream_place_of_row(file, kind, index)
			if !ok || !record_stream_place_valid(file, place) {
				return false
			}
			if place == 0 || place < first || place >= end {
				continue
			}
			if !range_holds(0, u64(len(memory)), place, RECORD_STREAM_PLACE_SIZE) {
				return false
			}
			for byte_index in 0 ..< RECORD_STREAM_PLACE_SIZE {
				memory[place + u64(byte_index)] = u8(index >> (8 * uint(byte_index)))
			}
		}
	}
	return true
}

// record_output_pairing_of_word and wiring_count_of_word are the borders of
// the bytes of a row: the member, or false for a byte that names none.
record_output_pairing_of_word :: proc "contextless" (word: u8) -> (pairing: Record_Output_Pairing, ok: bool) {
	for member in Record_Output_Pairing {
		if u8(member) == word {
			return member, true
		}
	}
	return {}, false
}

wiring_count_of_word :: proc "contextless" (word: u8) -> (wirings: Wiring_Count, ok: bool) {
	for member in Wiring_Count {
		if u8(member) == word {
			return member, true
		}
	}
	return {}, false
}

// record_stream_type gives the description of the record of a record
// output, a record input or wiring terms, after it checked it: record_type
// takes it, it has no Handle field, and each of its bytes is a byte of one
// field. The record goes into memory that another process reads: a byte
// that no field names carries memory of the writer, and a handle number
// names nothing in another process.
record_stream_type :: proc "contextless" (file: []u8, index: u32) -> (value: Record, ok: bool) {
	value = record_type(file, index) or_return
	if record_has_handle(file, value) || !record_covers_each_byte(file, value) {
		return {}, false
	}
	return value, true
}

// record_covers_each_byte says if the fields of a record follow each other
// from its first byte to its last one, with no byte between them.
record_covers_each_byte :: proc "contextless" (file: []u8, of: Record) -> bool {
	end: u32 = 0
	for number in 0 ..< of.field_count {
		item := field(file, of, number) or_return
		if item.offset != end {
			return false
		}
		end += field_size(item)
	}
	return end == of.size
}

// record_output gives row index of the table Record_Outputs, its pairing,
// and the description of its record (zero for a generic record output),
// after it checked them: the index is from 1 to RECORD_STREAM_INDEX_MOST,
// the reserved bytes are 0, the name is a name of the source inside the
// string table, the help and the text are inside the string table, the
// record is 0 or a record that record_stream_type takes, the pairing names a
// member, and Paired is on a generic record output only.
record_output :: proc "contextless" (file: []u8, index: u32) -> (value: Record_Output, pairing: Record_Output_Pairing, description: Record, ok: bool) {
	if index == 0 || index > RECORD_STREAM_INDEX_MOST {
		return {}, {}, {}, false
	}
	value = record(file, .Record_Outputs, index, Record_Output) or_return
	if (value.reserved != [3]u8{}) || !record_stream_texts_valid(file, value.name_offset, value.name_count, value.about_offset, value.about_count, value.text_offset, value.text_count) {
		return {}, {}, {}, false
	}
	pairing = record_output_pairing_of_word(value.pairing) or_return
	if value.record != 0 {
		description = record_stream_type(file, value.record) or_return
	}
	if pairing == .Paired && value.record != 0 {
		return {}, {}, {}, false
	}
	return value, pairing, description, true
}

// record_input gives row index of the table Record_Inputs, its count of
// wirings, the description of its record (zero for a generic record input)
// and of its terms (zero for none), after it checked them as record_output
// does: the count names a member, Many_Types is on a generic record input
// only, and the terms are 0 or a record that record_stream_type takes.
record_input :: proc "contextless" (file: []u8, index: u32) -> (value: Record_Input, wirings: Wiring_Count, description: Record, terms: Record, ok: bool) {
	if index == 0 || index > RECORD_STREAM_INDEX_MOST {
		return {}, {}, {}, {}, false
	}
	value = record(file, .Record_Inputs, index, Record_Input) or_return
	if (value.reserved != [7]u8{}) || !record_stream_texts_valid(file, value.name_offset, value.name_count, value.about_offset, value.about_count, value.text_offset, value.text_count) {
		return {}, {}, {}, {}, false
	}
	wirings = wiring_count_of_word(value.wirings) or_return
	if value.record != 0 {
		description = record_stream_type(file, value.record) or_return
	}
	if value.terms != 0 {
		terms = record_stream_type(file, value.terms) or_return
	}
	if wirings == .Many_Types && value.record != 0 {
		return {}, {}, {}, {}, false
	}
	return value, wirings, description, terms, true
}

// record_stream_texts_valid checks the three texts of a row: a name of the
// source of at least one byte, then a line of help and a documentation
// text, all inside the string table.
@(private = "file")
record_stream_texts_valid :: proc "contextless" (file: []u8, name_offset, name_count, about_offset, about_count, text_offset, text_count: u32) -> bool {
	strings_count := table(file, .Strings).count
	inside :: proc "contextless" (strings_count, offset, count: u32) -> bool {
		return offset <= strings_count && count <= strings_count - offset
	}
	if name_count == 0 || !inside(strings_count, name_offset, name_count) || !inside(strings_count, about_offset, about_count) || !inside(strings_count, text_offset, text_count) {
		return false
	}
	return source_name_valid(string_at(file, name_offset, name_count))
}

// Why the tables Record_Outputs and Record_Inputs of a file break a rule
// (record_streams_check).
Record_Stream_Fault :: enum u8 {
	None                  = 0, // The tables keep each rule.
	Too_Many_Outputs      = 1, // The table Record_Outputs has more than RECORD_STREAM_INDEX_MOST rows.
	Too_Many_Inputs       = 2, // The table Record_Inputs has more than RECORD_STREAM_INDEX_MOST rows.
	Bad_Output            = 3, // record_output refuses a row.
	Bad_Input             = 4, // record_input refuses a row.
	Outputs_Out_Of_Order  = 5, // A name of a record output is not after the name of the row before: the rows are not sorted, or two have one name.
	Inputs_Out_Of_Order   = 6, // The same for a record input.
	Name_Of_Both          = 7, // A record output and a record input have one name: `server.name` would name two streams.
	Generic_Output_Alone  = 8, // A generic record output in a module with no generic record input, or with two: it takes its type from the one generic record input.
}

// record_streams_check checks the tables Record_Outputs and Record_Inputs
// of a whole file: each row, the order of the names, and the rule of a
// generic record output. place is the index of the row of the fault, or 0.
// The work is in proportion to the rows: the order of the names makes one
// walk of each table, and one walk of the two together, enough.
//
// Example: a module whose only declaration is `forward:
// system.Record_Output(system.Any_Record, .Paired)` gives
// Generic_Output_Alone at 1.
record_streams_check :: proc "contextless" (file: []u8) -> (fault: Record_Stream_Fault, place: u32) {
	outputs := max(count(file, .Record_Outputs), 1) - 1
	inputs := max(count(file, .Record_Inputs), 1) - 1
	if outputs > RECORD_STREAM_INDEX_MOST {
		return .Too_Many_Outputs, RECORD_STREAM_INDEX_MOST + 1
	}
	if inputs > RECORD_STREAM_INDEX_MOST {
		return .Too_Many_Inputs, RECORD_STREAM_INDEX_MOST + 1
	}
	generic_inputs := 0
	before := ""
	for index in 1 ..= inputs {
		value, _, _, _, ok := record_input(file, index)
		if !ok {
			return .Bad_Input, index
		}
		name := string_at(file, value.name_offset, value.name_count)
		if index > 1 && name <= before {
			return .Inputs_Out_Of_Order, index
		}
		before = name
		if value.record == 0 {
			generic_inputs += 1
		}
	}
	before = ""
	for index in 1 ..= outputs {
		value, _, _, ok := record_output(file, index)
		if !ok {
			return .Bad_Output, index
		}
		name := string_at(file, value.name_offset, value.name_count)
		if index > 1 && name <= before {
			return .Outputs_Out_Of_Order, index
		}
		before = name
		if value.record == 0 && generic_inputs != 1 {
			return .Generic_Output_Alone, index
		}
	}
	// Both tables are sorted: one walk of the two finds a name of both.
	output_index, input_index := u32(1), u32(1)
	for output_index <= outputs && input_index <= inputs {
		output_row, _ := record(file, .Record_Outputs, output_index, Record_Output)
		input_row, _ := record(file, .Record_Inputs, input_index, Record_Input)
		output_name := string_at(file, output_row.name_offset, output_row.name_count)
		input_name := string_at(file, input_row.name_offset, input_row.name_count)
		switch {
		case output_name < input_name:
			output_index += 1
		case output_name > input_name:
			input_index += 1
		case:
			return .Name_Of_Both, output_index
		}
	}
	return .None, 0
}
