#+build !freestanding
package module

import "core:testing"
import op "modus:contract/operation"

// The parts of a module file of these tests: a code segment of one page,
// then a data segment of one page, one record, its fields, the strings,
// the facts and the own-hash place. Each table holds its record 0.
@(private = "file")
Facts_File :: struct {
	records: [dynamic]Record,
	fields:  [dynamic]Field,
	strings: [dynamic]u8,
	facts:   [dynamic]Fact,
	places:  [dynamic]Own_Hash_Place, // Empty: no table Own_Hash.
}

// The two keys of the facts of the file, in their order.
@(private = "file")
FIRST_KEY :: u64(0x1000)
@(private = "file")
SECOND_KEY :: u64(0x2000)
// The place of the hash in the data segment.
@(private = "file")
PLACE :: u64(PAGE_SIZE + 64)

@(private = "file")
string_add :: proc(table: ^[dynamic]u8, text: string) -> (offset, count: u32) {
	offset = u32(len(table))
	append(table, text)
	return offset, u32(len(text))
}

// facts_file_parts gives the parts of a valid file: the record "Probe" of
// two unsigned Integer fields of 8 bytes, "value" and "mark", and two
// facts of it, the first with a valid template, the second with a template
// that names a field that the record does not have.
@(private = "file")
facts_file_parts :: proc() -> (parts: Facts_File) {
	parts.records = make([dynamic]Record, context.temp_allocator)
	parts.fields = make([dynamic]Field, context.temp_allocator)
	parts.strings = make([dynamic]u8, context.temp_allocator)
	parts.facts = make([dynamic]Fact, context.temp_allocator)
	parts.places = make([dynamic]Own_Hash_Place, context.temp_allocator)
	append(&parts.strings, 0)
	name_offset, name_count := string_add(&parts.strings, "Probe")
	append(&parts.records, Record{}, Record{name_offset = name_offset, name_count = name_count, size = 16, first_field = 1, field_count = 2})
	value_offset, value_count := string_add(&parts.strings, "value")
	mark_offset, mark_count := string_add(&parts.strings, "mark")
	append(&parts.fields, Field{}, Field{name_offset = value_offset, name_count = value_count, offset = 0, type = u8(Type.Integer), unsigned = true}, Field{name_offset = mark_offset, name_count = mark_count, offset = 8, type = u8(Type.Integer), unsigned = true})
	package_offset, package_count := string_add(&parts.strings, "probe")
	good_offset, good_count := string_add(&parts.strings, "the value {value} and the mark {mark}")
	bad_offset, bad_count := string_add(&parts.strings, "the value {value} and the {other}")
	append(&parts.facts, Fact{})
	append(&parts.facts, Fact{key = FIRST_KEY, record = 1, template_offset = good_offset, template_count = good_count, package_offset = package_offset, package_count = package_count})
	append(&parts.facts, Fact{key = SECOND_KEY, record = 1, template_offset = bad_offset, template_count = bad_count, package_offset = package_offset, package_count = package_count})
	append(&parts.places, Own_Hash_Place{}, Own_Hash_Place{memory_offset = PLACE})
	return parts
}

@(private = "file")
bytes_of :: proc(items: []$T) -> []u8 {
	return ([^]u8)(raw_data(items))[:len(items) * size_of(T)]
}

// facts_file writes a module file of the parts: the header, the directory,
// the two segments, and each table.
@(private = "file")
facts_file :: proc(parts: Facts_File) -> []u8 {
	file := make([dynamic]u8, size_of(Header) + TABLE_COUNT * size_of(Table_Entry), context.temp_allocator)
	directory: [TABLE_COUNT]Table_Entry
	add :: proc(file: ^[dynamic]u8, directory: ^[TABLE_COUNT]Table_Entry, kind: Table_Kind, bytes: []u8, count, record_size: u32) {
		for len(file) % 8 != 0 {
			append(file, 0)
		}
		directory[kind] = {offset = u64(len(file)), count = count, record_size = record_size}
		append(file, ..bytes)
	}
	segments := [3]Segment{{}, {memory_offset = 0, memory_size = PAGE_SIZE, flags = {.Read, .Execute}}, {memory_offset = PAGE_SIZE, memory_size = PAGE_SIZE, flags = {.Read, .Write}}}
	add(&file, &directory, .Segments, bytes_of(segments[:]), len(segments), size_of(Segment))
	add(&file, &directory, .Records, bytes_of(parts.records[:]), u32(len(parts.records)), size_of(Record))
	add(&file, &directory, .Fields, bytes_of(parts.fields[:]), u32(len(parts.fields)), size_of(Field))
	add(&file, &directory, .Strings, parts.strings[:], u32(len(parts.strings)), 1)
	add(&file, &directory, .Facts, bytes_of(parts.facts[:]), u32(len(parts.facts)), size_of(Fact))
	if len(parts.places) > 0 {
		add(&file, &directory, .Own_Hash, bytes_of(parts.places[:]), u32(len(parts.places)), size_of(Own_Hash_Place))
	}
	(^Header)(&file[0])^ = {magic = MAGIC, version = VERSION, header_size = size_of(Header), machine = .X86_64, table_count = TABLE_COUNT, memory_size = 2 * PAGE_SIZE}
	(^[TABLE_COUNT]Table_Entry)(&file[size_of(Header)])^ = directory
	return file[:]
}

// An own-hash place that is not HASH_SIZE bytes inside one segment that
// the loader can write is refused by validate: in the code, across the end
// of the data segment, at the end of the memory, and at the largest
// offset. The last place that fits is taken. own_hash_write then writes
// the hash there, and only inside the range that a loader gives it.
@(test)
the_own_hash_place_is_in_writable_data :: proc(t: ^testing.T) {
	refused := [?]u64{0, 64, PAGE_SIZE - HASH_SIZE, 2 * PAGE_SIZE - HASH_SIZE + 1, 2 * PAGE_SIZE - 1, 2 * PAGE_SIZE, max(u64) - HASH_SIZE + 1, max(u64)}
	for place in refused {
		parts := facts_file_parts()
		parts.places[1].memory_offset = place
		testing.expectf(t, validate(facts_file(parts)) == .Bad_Own_Hash_Place, "the place %x is taken", place)
	}
	hash: [HASH_SIZE]u8
	for &value, index in hash {
		value = u8(index + 1)
	}
	// A place in the code makes own_hash_write refuse too, and write nothing.
	code_place := facts_file_parts()
	code_place.places[1].memory_offset = 64
	memory := make([]u8, 2 * PAGE_SIZE, context.temp_allocator)
	testing.expect(t, !own_hash_write(facts_file(code_place), memory, hash))
	for value in memory {
		testing.expect_value(t, value, 0)
	}

	// The last place that fits, then the usual place.
	last := facts_file_parts()
	last.places[1].memory_offset = 2 * PAGE_SIZE - HASH_SIZE
	testing.expect_value(t, validate(facts_file(last)), Error.None)
	file := facts_file(facts_file_parts())
	testing.expect_value(t, validate(file), Error.None)
	place, present := own_hash_place(file)
	testing.expect(t, present && place == PLACE)

	// A range of the loader without the place writes nothing; memory that
	// ends before the end of the place is refused, with nothing written.
	testing.expect(t, own_hash_write(file, memory, hash, 0, PAGE_SIZE))
	testing.expect(t, own_hash_write(file, memory, hash, PLACE + 1, 2 * PAGE_SIZE))
	testing.expect(t, !own_hash_write(file, memory[:PLACE + HASH_SIZE - 1], hash))
	for value in memory {
		testing.expect_value(t, value, 0)
	}
	// The range of the data segment holds the place: the hash is there.
	testing.expect(t, own_hash_write(file, memory, hash, PAGE_SIZE, 2 * PAGE_SIZE))
	testing.expect(t, string(memory[PLACE:][:HASH_SIZE]) == string(hash[:]))
	testing.expect_value(t, memory[PLACE - 1], 0)
	testing.expect_value(t, memory[PLACE + HASH_SIZE], 0)

	// A file with no table Own_Hash has no place, and writes nothing.
	without := facts_file_parts()
	clear(&without.places)
	none := facts_file(without)
	_, none_present := own_hash_place(none)
	clean := make([]u8, 2 * PAGE_SIZE, context.temp_allocator)
	testing.expect(t, !none_present && validate(none) == .None && own_hash_write(none, clean, hash))
	for value in clean {
		testing.expect_value(t, value, 0)
	}
}

// A row of the table Facts that breaks a rule is refused by `fact`: the
// index 0 and an index past the table, the key 0, a reserved word, a record
// index 0 or past the records, a record whose values pass one log record,
// a template of 0 bytes, one byte past its bound or outside the strings, a
// package name of 0 bytes or outside the strings. A record of exactly
// LOG_FACT_VALUE_CAPACITY bytes is taken, and the valid row last.
@(test)
a_fact_row_that_breaks_a_rule_is_refused :: proc(t: ^testing.T) {
	Change :: struct {
		name:   string,
		change: proc(parts: ^Facts_File),
	}
	changes := [?]Change {
		{"the key 0", proc(parts: ^Facts_File) {parts.facts[1].key = 0}},
		{"a reserved word", proc(parts: ^Facts_File) {parts.facts[1].reserved = 1}},
		{"the record 0", proc(parts: ^Facts_File) {parts.facts[1].record = 0}},
		{"a record past the records", proc(parts: ^Facts_File) {parts.facts[1].record = 2}},
		{"the largest record index", proc(parts: ^Facts_File) {parts.facts[1].record = max(u32)}},
		{"a template of 0 bytes", proc(parts: ^Facts_File) {parts.facts[1].template_count = 0}},
		{"a template one byte past its bound", proc(parts: ^Facts_File) {parts.facts[1].template_offset, parts.facts[1].template_count = 0, FACT_TEMPLATE_BYTES_MOST + 1}},
		{"a template past the strings", proc(parts: ^Facts_File) {parts.facts[1].template_offset = u32(len(parts.strings))}},
		{"the largest template offset", proc(parts: ^Facts_File) {parts.facts[1].template_offset = max(u32)}},
		{"a package name of 0 bytes", proc(parts: ^Facts_File) {parts.facts[1].package_count = 0}},
		{"a package name past the strings", proc(parts: ^Facts_File) {parts.facts[1].package_offset = u32(len(parts.strings))}},
		{"values one byte past one log record", proc(parts: ^Facts_File) {
				parts.records[1].size = op.LOG_FACT_VALUE_CAPACITY + 1
				parts.records[1].field_count = 1
				parts.fields[1] = {name_offset = parts.fields[1].name_offset, name_count = parts.fields[1].name_count, type = u8(Type.Text), detail = op.LOG_FACT_VALUE_CAPACITY + 1}
			}},
	}
	for item in changes {
		parts := facts_file_parts()
		item.change(&parts)
		file := facts_file(parts)
		_, _, ok := fact(file, 1)
		testing.expectf(t, !ok, "a fact with %s is taken", item.name)
	}
	file := facts_file(facts_file_parts())
	for index in ([3]u32{0, 3, max(u32)}) {
		_, _, ok := fact(file, index)
		testing.expectf(t, !ok, "the row %d is taken", index)
	}
	// The values of one log record, exactly: taken.
	whole := facts_file_parts()
	whole.records[1].size = op.LOG_FACT_VALUE_CAPACITY
	whole.records[1].field_count = 1
	whole.fields[1] = {name_offset = whole.fields[1].name_offset, name_count = whole.fields[1].name_count, type = u8(Type.Text), detail = op.LOG_FACT_VALUE_CAPACITY}
	_, whole_record, whole_ok := fact(facts_file(whole), 1)
	testing.expect(t, whole_ok && whole_record.size == op.LOG_FACT_VALUE_CAPACITY)
	value, description, ok := fact(file, 1)
	testing.expect(t, ok && value.key == FIRST_KEY && description.size == 16 && description.field_count == 2)
}

// fact_find gives the row of a key by its search in the sorted table, and
// no row for the key 0, a key below, between and above the keys, the
// largest key, and a key whose row `fact` refuses.
// A record is a fact type when a row of the table Facts names it. The
// edges first: the record 0, one past the last record, the largest index,
// and a file with no fact; then a record that no fact names; last, the
// record of the facts.
@(test)
a_record_is_a_fact_type_only_when_a_fact_names_it :: proc(t: ^testing.T) {
	parts := facts_file_parts()
	// A second record of the same fields, which no fact names.
	plain_offset, plain_count := string_add(&parts.strings, "Plain")
	append(&parts.records, Record{name_offset = plain_offset, name_count = plain_count, size = 16, first_field = 1, field_count = 2})
	file := facts_file(parts)
	testing.expect(t, !record_is_fact(file, 0), "the record 0 is a fact type")
	testing.expect(t, !record_is_fact(file, 3), "a record past the table is a fact type")
	testing.expect(t, !record_is_fact(file, max(u32)), "the largest index is a fact type")
	testing.expect(t, !record_is_fact(file, 2), "a record that no fact names is a fact type")
	without := facts_file_parts()
	resize(&without.facts, 1)
	testing.expect(t, !record_is_fact(facts_file(without), 1), "a record of a file with no fact is a fact type")
	testing.expect(t, record_is_fact(file, 1), "the record of the facts is no fact type")
}

@(test)
fact_find_gives_the_row_of_a_key :: proc(t: ^testing.T) {
	file := facts_file(facts_file_parts())
	for key in ([?]u64{0, 1, FIRST_KEY - 1, FIRST_KEY + 1, SECOND_KEY - 1, SECOND_KEY + 1, max(u64)}) {
		_, _, _, found := fact_find(file, key)
		testing.expectf(t, !found, "the key %x is found", key)
	}
	broken := facts_file_parts()
	broken.facts[2].reserved = 1
	_, _, _, broken_found := fact_find(facts_file(broken), SECOND_KEY)
	testing.expect(t, !broken_found)
	first, first_value, _, first_found := fact_find(file, FIRST_KEY)
	second, second_value, _, second_found := fact_find(file, SECOND_KEY)
	testing.expect(t, first_found && first == 1 && first_value.key == FIRST_KEY)
	testing.expect(t, second_found && second == 2 && second_value.key == SECOND_KEY)
}

// A fact template that breaks a rule of its language is refused with its
// fault and its place: each rule, with the edges of its length (0 bytes,
// the bound, one past the bound) and of the count of the fields. A
// template that keeps every rule is the last case.
@(test)
a_template_that_breaks_a_rule_is_refused :: proc(t: ^testing.T) {
	names := []string{"block", "check"}
	Case :: struct {
		template: string,
		fault:    Fact_Template_Fault,
		place:    int,
	}
	cases := [?]Case {
		{"", .Field_Not_Named, 0},
		{"the block {block}", .Field_Not_Named, 1},
		{"the block {block", .Unclosed_Brace, 10},
		{"{", .Unclosed_Brace, 0},
		{"} {block} {check}", .Lone_Closing_Brace, 0},
		{"{block} {check} }", .Lone_Closing_Brace, 16},
		{"{block:08} {check}", .Not_A_Field_Name, 1},
		{"{} {block} {check}", .Not_A_Field_Name, 1},
		{"{1block} {check}", .Not_A_Field_Name, 1},
		{"{block check}", .Not_A_Field_Name, 1},
		{"{blocks} {check}", .Unknown_Field, 1},
		{"{Block} {check}", .Unknown_Field, 1},
		{"{block} {block} {check}", .Field_Twice, 9},
		{"a\nb {block} {check}", .Not_Text, 1},
		{"\xff {block} {check}", .Not_Text, 0},
	}
	for item in cases {
		fault, place := fact_template_check(item.template, names)
		testing.expectf(t, fault == item.fault && place == item.place, "the template %q gave %v at %d, not %v at %d", item.template, fault, place, item.fault, item.place)
	}
	// The length: one byte below the bound and the bound are taken, one
	// byte more is refused. The bound holds the longest line of a module,
	// about 380 bytes, with room.
	#assert(FACT_TEMPLATE_BYTES_MOST == 512)
	filled: [FACT_TEMPLATE_BYTES_MOST + 1]u8
	for &value in filled {
		value = 'x'
	}
	copy(filled[:], "{block} {check} ")
	below_fault, _ := fact_template_check(string(filled[:FACT_TEMPLATE_BYTES_MOST - 1]), names)
	bound_fault, _ := fact_template_check(string(filled[:FACT_TEMPLATE_BYTES_MOST]), names)
	past_fault, past_place := fact_template_check(string(filled[:]), names)
	testing.expect_value(t, below_fault, Fact_Template_Fault.None)
	testing.expect_value(t, bound_fault, Fact_Template_Fault.None)
	testing.expect(t, past_fault == .Too_Long && past_place == FACT_TEMPLATE_BYTES_MOST)
	// A template of the bound with a field of each byte past the bound: the
	// length is checked before the names, so a name at byte 513 is never read.
	past_with_name: [FACT_TEMPLATE_BYTES_MOST + 8]u8
	copy(past_with_name[:], filled[:])
	copy(past_with_name[FACT_TEMPLATE_BYTES_MOST:], "{other}")
	far_fault, _ := fact_template_check(string(past_with_name[:FACT_TEMPLATE_BYTES_MOST + 7]), names)
	testing.expect_value(t, far_fault, Fact_Template_Fault.Too_Long)
	// The count of the fields: one past the capacity is refused.
	many: [FACT_FIELD_CAPACITY + 1]string
	for &name in many {
		name = "a"
	}
	many_fault, _ := fact_template_check("{a}", many[:])
	testing.expect_value(t, many_fault, Fact_Template_Fault.Too_Many_Fields)
	// No field and no brace; braces written as two; then the usual form.
	none_fault, _ := fact_template_check("a sentence", nil)
	braces_fault, _ := fact_template_check("{{block}} }} {block} {check}", names)
	usual_fault, _ := fact_template_check("storage: the block {block} has a wrong check {check}", names)
	testing.expect(t, none_fault == .None && braces_fault == .None && usual_fault == .None)

	// The template of a row of a file: the second row names a field that
	// its record does not have.
	file := facts_file(facts_file_parts())
	first, first_record, _ := fact(file, 1)
	second, second_record, _ := fact(file, 2)
	testing.expect_value(t, fact_template_valid(file, second, second_record), Fact_Template_Fault.Unknown_Field)
	testing.expect_value(t, fact_template_valid(file, first, first_record), Fact_Template_Fault.None)
}
