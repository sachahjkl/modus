#+build !freestanding
package isolated

import "modus:contract/call_outcome"
import "modus:contract/errors"
import module "modus:contract/module"
import "core:math/rand"
import "core:testing"

@(private = "file")
description :: proc(types: ..module.Type) -> (function: module.Function) {
	function.parameter_count = u8(len(types))
	for type, index in types {
		function.parameters[index] = u8(type)
	}
	return function
}

// What encode writes, decode reads: the same integers, and for each Text
// the same bytes, at an address in the call region.
@(test)
arguments_round_trip :: proc(t: ^testing.T) {
	region: [256]u8
	function := description(.Integer, .Text, .Integer, .Text, .Text, .Integer)
	first, second := "the first text", "second"
	arguments := [?]Argument{{integer = 7}, {text = transmute([]u8)first}, {integer = max(u64)}, {text = transmute([]u8)second}, {}, {integer = 1 << 40}}
	offset, size, _, encoded := encode(nil, function, arguments[:], region[:])
	testing.expect(t, encoded)
	testing.expect_value(t, size, 3 * 8 + 3 * 16)

	call: Call
	testing.expect(t, decode(nil, function, offset, size, region[:], &call))
	testing.expect_value(t, call.arguments[0], 7)
	testing.expect_value(t, call.arguments[2], max(u64))
	testing.expect_value(t, call.arguments[5], 1 << 40)
	// A Text register has the address of a slice record with the layout of a string.
	testing.expect_value(t, (^string)(uintptr(call.arguments[1]))^, first)
	testing.expect_value(t, (^string)(uintptr(call.arguments[3]))^, second)
	testing.expect_value(t, (^string)(uintptr(call.arguments[4]))^, "")
	low, high := uintptr(&region[0]), uintptr(&region[0]) + len(region)
	for index in ([]int{1, 3, 4}) {
		testing.expect(t, uintptr(call.slices[index].start) >= low && uintptr(call.slices[index].start + call.slices[index].count) <= high)
	}
}

@(test)
encode_refuses :: proc(t: ^testing.T) {
	region: [64]u8
	long: [64]u8
	_, _, _, ok := encode(nil, description(.Integer), {}, region[:])
	testing.expect(t, !ok, "the argument count differs from the description")
	_, _, _, ok = encode(nil, description(.Text), {{text = long[:]}}, region[:])
	testing.expect(t, !ok, "the text does not fit in the call region")
	_, _, _, ok = encode(nil, description(.Text), {{text = long[:48]}}, region[:])
	testing.expect(t, ok, "the text fills the call region exactly")
	// A byte of no type: one past the last type, 200 and the largest byte.
	refused_types := [?]u8{u8(max(module.Type)) + 1, 200, max(u8)}
	for word in refused_types {
		with_word := description(.Integer)
		with_word.parameters[0] = word
		_, _, _, ok = encode(nil, with_word, {{}}, region[:])
		testing.expectf(t, !ok, "the description has the unknown type %d", word)
		with_word = description(.Integer)
		with_word.result = word
		_, _, _, ok = encode(nil, with_word, {{}}, region[:])
		testing.expectf(t, !ok, "the description has the unknown result type %d", word)
		_, described := record_size(with_word)
		testing.expectf(t, !described, "the record size of the unknown result type %d", word)
	}
	unknown := description(.Integer)
	unknown.parameter_count = module.PARAMETER_CAPACITY + 1
	_, _, _, ok = encode(nil, unknown, {{}}, region[:])
	testing.expect(t, !ok, "the description has too many parameters")
}

// decode refuses each argument record that names memory out of the call region.
@(test)
decode_refuses :: proc(t: ^testing.T) {
	region: [128]u8
	call: Call
	function := description(.Integer, .Text)
	SIZE :: 8 + 16

	Case :: struct {
		offset, size: u64,
		slice:        Slice,
		ok:           bool,
		about:        string,
	}
	cases := [?]Case {
		{offset = 0, size = SIZE, slice = {start = 24, count = 104}, ok = true, about = "a slice to the last byte"},
		{offset = 104, size = SIZE, slice = {start = 0, count = 0}, ok = true, about = "a record at the end"},
		{offset = 0, size = SIZE, slice = {start = 128, count = 0}, ok = true, about = "an empty slice at the end"},
		{offset = 0, size = SIZE, slice = {start = 24, count = 105}, about = "a slice one byte too long"},
		{offset = 0, size = SIZE, slice = {start = 129, count = 0}, about = "a slice that starts after the end"},
		{offset = 0, size = SIZE, slice = {start = 8, count = max(u64)}, about = "a count that wraps"},
		{offset = 0, size = SIZE, slice = {start = max(u64), count = 2}, about = "a start that wraps"},
		{offset = 105, size = SIZE, about = "a record that crosses the end"},
		{offset = max(u64), size = SIZE, about = "a record offset that wraps"},
		{offset = 0, size = SIZE - 8, about = "a record that is too small"},
		{offset = 0, size = SIZE + 8, about = "a record that is too large"},
		{offset = 0, size = max(u64), about = "a size that wraps"},
	}
	for item in cases {
		region = {}
		if item.offset <= len(region) - SIZE {
			store(region[:], item.offset + 8, item.slice)
		}
		testing.expectf(t, decode(nil, function, item.offset, item.size, region[:], &call) == item.ok, "%s", item.about)
	}
}

// With random bytes in the call region and random numbers in the command
// record, decode gives only addresses in the call region.
@(test)
decode_random :: proc(t: ^testing.T) {
	region: [512]u8
	low, high := u64(uintptr(&region[0])), u64(uintptr(&region[0])) + len(region)
	accepted := 0
	for _ in 0 ..< 200_000 {
		function: module.Function
		function.parameter_count = u8(rand.int_max(module.PARAMETER_CAPACITY + 2))
		function.result = u8(rand.int_max(4))
		for &word in function.parameters {
			word = u8(rand.int_max(4))
		}
		for &b in region[:64] {
			b = u8(rand.uint32())
		}
		// Small numbers most of the time, so that many records pass the checks.
		if rand.int_max(4) != 0 {
			for i := 0; i < 64; i += 8 {
				store(region[:], u64(i), u64(rand.int_max(600)))
			}
		}
		size, _ := record_size(function)
		offset := u64(rand.int_max(8)) * 8
		if rand.int_max(8) == 0 {
			size, offset = rand.uint64(), rand.uint64()
		}
		call: Call
		refusal: errors.Error_Record
		if !decode(nil, function, offset, size, region[:], &call, &refusal) {
			if !receiver_refusal_named(t, refusal) {
				return
			}
			continue
		}
		accepted += 1
		types := function.parameters
		count := int(function.parameter_count)
		if function.result == u8(module.Type.Text) {
			// The buffer of the result is one more slice.
			testing.expect(t, count < module.PARAMETER_CAPACITY)
			types[count] = u8(module.Type.Text)
			count += 1
		}
		for word, index in types[:count] {
			if word != u8(module.Type.Text) {
				continue
			}
			slice := call.slices[index]
			testing.expect(t, call.arguments[index] == u64(uintptr(&call.slices[index])))
			if slice.start < low || slice.start > high || slice.count > high - slice.start {
				testing.expectf(t, false, "a slice is out of the call region: start %x count %x", slice.start, slice.count)
				return
			}
		}
	}
	testing.expect(t, accepted > 1000, "the test must accept many records")
}

// A Text result: the buffer is the rest of the call region. The callee
// writes there; the caller reads the count that the callee gave, and never
// more than the buffer.
@(test)
text_result :: proc(t: ^testing.T) {
	region: [128]u8
	function := description(.Text, .Integer)
	function.result = u8(module.Type.Text)
	argument := "abc"
	offset, size, result, encoded := encode(nil, function, {{text = transmute([]u8)argument}, {integer = 5}}, region[:])
	testing.expect(t, encoded)
	testing.expect_value(t, size, 16 + 8 + 16)
	testing.expect_value(t, result, Slice{start = 43, count = 85})

	call: Call
	testing.expect(t, decode(nil, function, offset, size, region[:], &call))
	buffer := (^[]u8)(uintptr(call.arguments[2]))^
	testing.expect_value(t, len(buffer), 85)
	testing.expect(t, raw_data(buffer) == &region[43])
	copy(buffer, "result")

	text, complete := result_text(region[:], result, 6)
	testing.expect_value(t, string(text), "result")
	testing.expect(t, complete)
	text, complete = result_text(region[:], result, 86)
	testing.expect_value(t, len(text), 85)
	testing.expect(t, !complete, "the callee gave a count larger than the buffer")
	text, complete = result_text(region[:], result, max(u64))
	testing.expect(t, len(text) == 85 && !complete)
	_, complete = result_text(region[:], Slice{start = 100, count = 29}, 1)
	testing.expect(t, !complete, "a buffer that is not in the call region")

	full := integer_description(module.PARAMETER_CAPACITY)
	full.result = u8(module.Type.Text)
	none: [module.PARAMETER_CAPACITY]Argument
	_, _, _, ok := encode(nil, full, none[:], region[:])
	testing.expect(t, !ok, "as many parameters as an export has leave no argument for the buffer")
}

// integer_description gives the description of an export with `count`
// Integer parameters.
@(private = "file")
integer_description :: proc(count: int) -> (function: module.Function) {
	function.parameter_count = u8(count)
	for index in 0 ..< count {
		function.parameters[index] = u8(module.Type.Integer)
	}
	return function
}

// An export with nine parameters, past the six registers: each argument
// comes back in its place, a Text and a Record after the sixth too, and the
// error record is the argument after the buffer of the result. A tenth
// argument and more are refused when the bound has no room for them.
@(test)
nine_parameters_round_trip :: proc(t: ^testing.T) {
	storage: [512]u8
	file := record_file(&storage)
	region: [512]u8
	function := description(.Integer, .Text, .Integer, .Integer, .Integer, .Integer, .Integer, .Text, .Record)
	function.parameter_details[8] = 1
	function.result = u8(module.Type.Text)
	function.error_record = 1
	testing.expect_value(t, module.call_argument_count(int(function.parameter_count), function.result, true), 11)
	seventh, eighth := "the second text", "past the registers"
	record := [2]u64{0, 77}
	arguments := [9]Argument{{integer = 1}, {text = transmute([]u8)seventh}, {integer = 3}, {integer = 4}, {integer = 5}, {integer = 6}, {integer = 7}, {text = transmute([]u8)eighth}, {record = ([^]u8)(&record)[:16]}}
	offset, size, result, encoded := encode(file, function, arguments[:], region[:])
	testing.expect(t, encoded, "nine parameters, a Text result and an error record fit the bound")
	testing.expect_value(t, size, u64(6 * 8 + 2 * 16 + 8 + 16))
	call: Call
	testing.expect(t, decode(file, function, offset, size, region[:], &call))
	for value, index in ([7]u64{0 = 1, 2 = 3, 3 = 4, 4 = 5, 5 = 6, 6 = 7}) {
		if index != 1 {
			testing.expect_value(t, call.arguments[index], value)
		}
	}
	testing.expect_value(t, (^string)(uintptr(call.arguments[1]))^, seventh)
	testing.expect_value(t, (^string)(uintptr(call.arguments[7]))^, eighth)
	testing.expect_value(t, (^[2]u64)(uintptr(call.arguments[8]))^, record)
	// The buffer of the Text result is argument 10, the error record 11.
	buffer := (^[]u8)(uintptr(call.arguments[9]))^
	testing.expect(t, raw_data(buffer) == &region[result.start] && u64(len(buffer)) == result.count)
	testing.expect_value(t, call.arguments[10], u64(uintptr(&call.error_record)))

	// The bound: twelve arguments fit, thirteen do not.
	_, described := record_size(function)
	testing.expect(t, described)
	function.parameters[9], function.parameters[10] = u8(module.Type.Integer), u8(module.Type.Integer)
	function.parameter_count = 11
	_, described = record_size(function)
	testing.expect(t, !described, "eleven parameters, a Text result and an error record are thirteen arguments")
	function.error_record = 0
	_, described = record_size(function)
	testing.expect(t, described, "eleven parameters and a Text result are twelve arguments")
}

// A module file with one record: {handle at 0, integer at 8}, 16 bytes.
@(private = "file")
record_file :: proc(file: ^[512]u8) -> []u8 {
	Directory :: [module.TABLE_COUNT]module.Table_Entry
	directory: Directory
	offset := u64(size_of(module.Header) + size_of(Directory))
	records := [2]module.Record{1 = {size = 16, first_field = 1, field_count = 2}}
	fields := [3]module.Field{1 = {offset = 0, type = u8(module.Type.Handle), detail = 6}, 2 = {offset = 8, type = u8(module.Type.Integer)}}
	directory[module.Table_Kind.Records] = {offset = offset, count = 2, record_size = size_of(module.Record)}
	(^[2]module.Record)(&file[offset])^ = records
	offset += size_of(records)
	directory[module.Table_Kind.Fields] = {offset = offset, count = 3, record_size = size_of(module.Field)}
	(^[3]module.Field)(&file[offset])^ = fields
	offset += size_of(fields)
	(^module.Header)(&file[0])^ = {magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = module.TABLE_COUNT}
	(^Directory)(&file[size_of(module.Header)])^ = directory
	return file[:offset]
}

// A module file with one record of 24 bytes: {name: Text(16) at 0, integer at 16}.
@(private = "file")
table_file :: proc(file: ^[512]u8) -> []u8 {
	Directory :: [module.TABLE_COUNT]module.Table_Entry
	directory: Directory
	offset := u64(size_of(module.Header) + size_of(Directory))
	records := [2]module.Record{1 = {size = 24, first_field = 1, field_count = 2}}
	fields := [3]module.Field{1 = {offset = 0, type = u8(module.Type.Text), detail = 16}, 2 = {offset = 16, type = u8(module.Type.Integer)}}
	directory[module.Table_Kind.Records] = {offset = offset, count = 2, record_size = size_of(module.Record)}
	(^[2]module.Record)(&file[offset])^ = records
	offset += size_of(records)
	directory[module.Table_Kind.Fields] = {offset = offset, count = 3, record_size = size_of(module.Field)}
	(^[3]module.Field)(&file[offset])^ = fields
	offset += size_of(fields)
	(^module.Header)(&file[0])^ = {magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = module.TABLE_COUNT}
	(^Directory)(&file[size_of(module.Header)])^ = directory
	return file[:offset]
}

// A Table result: the buffer is the rest of the call region, from a
// multiple of 8, with a capacity in records. The caller reads the count of
// records that the callee gave, and never more than the buffer.
@(test)
table_result :: proc(t: ^testing.T) {
	storage: [512]u8
	file := table_file(&storage)
	described, valid := module.record_type(file, 1)
	testing.expect(t, valid, "a record with a Text field of 16 bytes is valid")
	testing.expect_value(t, described.size, 24)
	region: [128]u8
	function := description(.Text)
	function.result, function.result_detail = u8(module.Type.Table), 1
	argument := "abc"
	offset, size, result, encoded := encode(file, function, {{text = transmute([]u8)argument}}, region[:])
	testing.expect(t, encoded)
	testing.expect_value(t, size, 16 + 16)
	// The text ends at 35; the records start at 40: 88 bytes, 3 records.
	testing.expect_value(t, result, Slice{start = 40, count = 3})

	Row :: struct {
		name:  [16]u8,
		value: i64,
	}
	call: Call
	testing.expect(t, decode(file, function, offset, size, region[:], &call))
	rows := (^[]Row)(uintptr(call.arguments[1]))^
	testing.expect_value(t, len(rows), 3)
	testing.expect(t, rawptr(raw_data(rows)) == rawptr(&region[40]))
	rows[0].value, rows[1].value = 1, 2
	copy(rows[0].name[:], "one")
	copy(rows[1].name[:], "xxxxxxxxxxxxxxxx")

	bytes, complete := result_table(region[:], result, 2, 24)
	testing.expect(t, complete && len(bytes) == 48)
	item, _ := module.field(file, described, 0)
	testing.expect_value(t, module.field_text(bytes[:24], item), "one")
	testing.expect_value(t, module.field_text(bytes[24:48], item), "xxxxxxxxxxxxxxxx")
	bytes, complete = result_table(region[:], result, 5, 24)
	testing.expect(t, !complete && len(bytes) == 72, "the callee gave a count larger than the buffer")
	_, complete = result_table(region[:], Slice{start = 100, count = 2}, 1, 24)
	testing.expect(t, !complete, "a buffer that is not in the call region")
	// An argument record that names a buffer out of the call region: refused.
	(^Slice)(&region[16])^ = Slice{start = 40, count = 4}
	testing.expect(t, !decode(file, function, offset, size, region[:], &call))
	// A Text field of 0 bytes has no description: its detail is its size.
	storage[size_of(module.Header) + module.TABLE_COUNT * size_of(module.Table_Entry) + 2 * size_of(module.Record) + size_of(module.Field) + 16] = 0
	_, valid = module.record_type(file, 1)
	testing.expect(t, !valid, "a Text field of 0 bytes")
}

// A Record goes as its bytes, a Handle as its number. decode gives a
// private copy of the record, and the list of the handles to prove: the
// Handle parameters and the Handle fields.
@(test)
records_and_handles_round_trip :: proc(t: ^testing.T) {
	storage: [512]u8
	file := record_file(&storage)
	region: [256]u8
	function := description(.Record, .Handle, .Integer)
	function.parameter_details = {0 = 1, 1 = 3}
	function.result, function.result_detail = u8(module.Type.Record), 1
	sent := [2]u64{0x1_0007, 99}
	arguments := [?]Argument{{record = ([^]u8)(&sent)[:16]}, {integer = 0x2_0009}, {integer = 5}}
	offset, size, place, encoded := encode(file, function, arguments[:], region[:])
	testing.expect(t, encoded)
	testing.expect_value(t, size, 4 * 8)
	testing.expect_value(t, place.count, 16)

	call: Call
	testing.expect(t, decode(file, function, offset, size, region[:], &call))
	received := (^[2]u64)(uintptr(call.arguments[0]))
	testing.expect_value(t, received^, sent)
	testing.expect_value(t, call.arguments[1], 0x2_0009)
	testing.expect_value(t, call.arguments[2], 5)
	testing.expect_value(t, call.lent_count, 2)
	testing.expect_value(t, call.lent[0], Lent{0x1_0007, 6})
	testing.expect_value(t, call.lent[1], Lent{0x2_0009, 3})
	// The copy is private: the other process changes the call region, and
	// the export still reads what decode read.
	for &b in region[int(size):] {
		b = 0xEE
	}
	testing.expect_value(t, received^, sent)
	// The result: the export writes in private memory, result_store copies
	// it to the place that the caller named, and the caller copies it out.
	(^[2]u64)(uintptr(call.arguments[3]))^ = {11, 22}
	result_store(function, &call, region[:])
	result: [2]u64
	testing.expect(t, result_record(region[:], place, ([^]u8)(&result)[:16]))
	testing.expect_value(t, result, [2]u64{11, 22})

	// A record of another size, a handle of more than 32 bits, and a
	// record that is not in the call region: refused.
	_, _, _, encoded = encode(file, function, {{record = ([^]u8)(&sent)[:8]}, {}, {}}, region[:])
	testing.expect(t, !encoded)
	_, _, _, encoded = encode(file, function, {{record = ([^]u8)(&sent)[:16]}, {integer = 1 << 32}, {}}, region[:])
	testing.expect(t, !encoded)
	offset, size, _, encoded = encode(file, function, arguments[:], region[:])
	(^u64)(&region[offset])^ = u64(len(region)) - 8
	testing.expect(t, encoded && !decode(file, function, offset, size, region[:], &call))
	// A description that names no record of the module: refused.
	function.parameter_details[0] = 2
	testing.expect(t, !decode(file, function, offset, size, region[:], &call))
}

// An export with an error record: the record is private to the receiver,
// so the argument record has no field for it, and the argument after the
// buffer of a Text result is the address of the record of the receiver.
@(test)
error_record_of_the_receiver :: proc(t: ^testing.T) {
	region: [256]u8
	for &b in region {
		b = 0xEE
	}
	function := description(.Text)
	function.result = u8(module.Type.Text)
	function.error_record = 1
	argument := "name"
	offset, size, result, encoded := encode(nil, function, {{text = transmute([]u8)argument}}, region[:])
	testing.expect(t, encoded)
	// The Text and the buffer of the result: no field for the record.
	testing.expect_value(t, size, 16 + 16)
	// The text ends at 36; the buffer starts after it.
	testing.expect_value(t, result.start, 36)
	call: Call
	call.error_record = {kind = 99}
	testing.expect(t, decode(nil, function, offset, size, region[:], &call))
	testing.expect_value(t, call.arguments[2], u64(uintptr(&call.error_record)))
	// decode gives each call a zero record: no record of an earlier call
	// reaches the caller.
	testing.expect_value(t, call.error_record, errors.Error_Record{})
	// An export with an error record and as many parameters as an export
	// has: no argument is free for the record.
	full := integer_description(module.PARAMETER_CAPACITY)
	full.error_record = 1
	none: [module.PARAMETER_CAPACITY]Argument
	_, _, _, encoded = encode(nil, full, none[:], region[:])
	testing.expect(t, !encoded)
}

// A Record result with an error record: the place of the result is the
// argument after the parameters, and the record of the receiver the one
// after it. On success, result_store copies the record into the call
// region; on a failure the receiver skips result_store, so the place stays
// zero, and the error record goes in the completion.
@(test)
fallible_record_result :: proc(t: ^testing.T) {
	storage: [512]u8
	file := record_file(&storage)
	function := description(.Integer)
	function.result, function.result_detail = u8(module.Type.Record), 1
	function.error_record = 1

	// Success: the outcome word 0 copies the record out.
	region: [256]u8
	for &b in region {
		b = 0xEE
	}
	offset, size, place, encoded := encode(file, function, {{integer = 42}}, region[:])
	testing.expect(t, encoded)
	testing.expect_value(t, size, u64(8 + 8))
	testing.expect_value(t, place, Slice{start = 16, count = 16})
	call: Call
	testing.expect(t, decode(file, function, offset, size, region[:], &call))
	testing.expect_value(t, call.arguments[0], u64(42))
	testing.expect_value(t, call.arguments[1], u64(uintptr(&call.records[1])))
	testing.expect_value(t, call.arguments[2], u64(uintptr(&call.error_record)))
	testing.expect_value(t, call.result, place)
	(^[2]u64)(uintptr(call.arguments[1]))^ = {11, 22}
	value, outcome_word := export_answer(function, {0, 999})
	testing.expect_value(t, outcome_word, u64(0))
	testing.expect_value(t, value, u64(0))
	if outcome_word == 0 {
		result_store(function, &call, region[:])
	}
	result: [2]u64
	testing.expect(t, result_record(region[:], place, ([^]u8)(&result)[:16]))
	testing.expect_value(t, result, [2]u64{11, 22})

	// A failure: result_store is skipped, so the place keeps its zero
	// bytes, and the record of the export goes in the completion.
	for &b in region {
		b = 0xEE
	}
	offset, size, place, encoded = encode(file, function, {{integer = 7}}, region[:])
	testing.expect(t, encoded)
	call = {}
	testing.expect(t, decode(file, function, offset, size, region[:], &call))
	(^[2]u64)(uintptr(call.arguments[1]))^ = {77, 88}
	(^errors.Error_Record)(uintptr(call.arguments[2]))^ = errors.error_make(.Bad_Value, .None, 1, 7)
	value, outcome_word = export_answer(function, {u64(call_outcome.Call_Outcome.Argument_Refused), 555})
	testing.expect_value(t, outcome_word, u64(call_outcome.Call_Outcome.Argument_Refused))
	testing.expect_value(t, value, u64(0))
	if outcome_word == 0 {
		result_store(function, &call, region[:])
	}
	result = {0xFF, 0xFF}
	testing.expect(t, result_record(region[:], place, ([^]u8)(&result)[:16]))
	testing.expect_value(t, result, [2]u64{0, 0})
	completion := answer_completion(5, 3, value, outcome_word, call.error_record)
	read_value, read_outcome, read_record := answer_of_completion(completion)
	testing.expect_value(t, read_value, 0)
	testing.expect_value(t, read_outcome, call_outcome.Call_Outcome.Argument_Refused)
	testing.expect_value(t, read_record.kind, i64(errors.Kind.Bad_Value))
	testing.expect_value(t, read_record.operation, 3)

	// A parameter count that leaves no argument for both the place and the
	// record.
	nearly_full := integer_description(module.PARAMETER_CAPACITY - 1)
	nearly_full.result, nearly_full.result_detail = u8(module.Type.Record), 1
	nearly_full.error_record = 1
	args: [module.PARAMETER_CAPACITY - 1]Argument
	_, _, _, encoded = encode(file, nearly_full, args[:], region[:])
	testing.expect(t, !encoded)
}

// The completion of a call crosses from the receiver to the caller with no
// loss: the value of a success, the outcome and the record of a failure.
// The border refuses each word that names no outcome, and a failure whose
// record names no kind, as Answer_Unreadable with the value 0. The edges
// come first.
@(test)
the_completion_carries_the_outcome_and_the_record :: proc(t: ^testing.T) {
	// A kind that names no outcome: the first word past the last member and
	// the largest word, with a value that the reader must not take.
	for word in ([]u32{u32(max(call_outcome.Call_Outcome)) + 1, max(u32)}) {
		value, outcome, record := answer_of_completion({kind = word, tag = 1, values = {0 = 77}})
		testing.expectf(t, value == 0 && outcome == .Answer_Unreadable && record.kind == i64(errors.Kind.Bad_Value), "the word %d gives %v %v", word, outcome, record)
	}
	// A failure whose record names no kind, or a kind that is not a member.
	for kind in ([]i64{0, -1, 9999}) {
		values := errors.completion_values({kind = kind})
		_, outcome, _ := answer_of_completion({kind = u32(call_outcome.Call_Outcome.Callee_Busy), values = values})
		testing.expectf(t, outcome == .Answer_Unreadable, "a record of kind %d gives %v", kind, outcome)
	}
	// An export that failed with no record: the receiver writes Refused, so
	// the failure still reads.
	silent := answer_completion(2, 4, 0, u64(call_outcome.Call_Outcome.Wrong_State), {})
	_, outcome, record := answer_of_completion(silent)
	testing.expect_value(t, outcome, call_outcome.Call_Outcome.Wrong_State)
	testing.expect_value(t, record.kind, i64(errors.Kind.Refused))
	testing.expect_value(t, record.operation, 4)
	// A word of the export past 32 bits names no outcome: it stays
	// unreadable, and never becomes a member by a cut.
	cut := answer_completion(2, 4, 0, u64(1) << 32 | u64(call_outcome.Call_Outcome.Argument_Refused), errors.error_make(.Bad_Value))
	_, outcome, _ = answer_of_completion(cut)
	testing.expect_value(t, outcome, call_outcome.Call_Outcome.Answer_Unreadable)
	// Each failure of the receiver, and each member that an export gives.
	refused := refusal_completion(9, .Operation_Unsupported, errors.error_make(.Unsupported, .None, 0, 12))
	testing.expect_value(t, refused.tag, 9)
	_, outcome, record = answer_of_completion(refused)
	testing.expect_value(t, outcome, call_outcome.Call_Outcome.Operation_Unsupported)
	testing.expect_value(t, record.value, 12)
	for member in call_outcome.Call_Outcome {
		if member == .Succeeded {
			continue
		}
		completion := answer_completion(1, 6, 123, u64(member), errors.error_make(.Refused))
		value, read, _ := answer_of_completion(completion)
		testing.expectf(t, value == 0 && read == member, "the outcome %v reads as %v with the value %d", member, read, value)
	}
	// The success last: the value comes back whole.
	success := answer_completion(3, 1, max(u64), 0, {})
	value, read, read_record := answer_of_completion(success)
	testing.expect_value(t, value, -1)
	testing.expect_value(t, read, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, read_record, errors.Error_Record{})
}

// The completion of a call carries the result register of an Integer, an
// Enum, a Text and a Table result, and 0 for each other result and for a
// byte that names no type. An Enum result once gave 0: a getter that gave
// .spleen read as .vector at the caller.
@(test)
the_completion_carries_an_enum_result :: proc(t: ^testing.T) {
	register := u64(0xFFFF_FFFF_0000_0001)
	for word in ([]u8{0, u8(module.Type.Record), u8(module.Type.Handle), u8(module.Type.Bytes), 200, 255}) {
		testing.expectf(t, completion_value(module.Function{result = word}, register) == 0, "the result byte %d gives 0", word)
	}
	for type in ([]module.Type{.Integer, .Enum, .Text, .Table}) {
		testing.expectf(t, completion_value(module.Function{result = u8(type)}, register) == register, "the result %v keeps the register", type)
	}
	testing.expect_value(t, completion_value(module.Function{result = u8(module.Type.Enum)}, 1), 1)
}

// The grant of a connection: the amount, the principal and the flag each
// keep their own bits, and a number out of the field cannot reach the flag.
@(test)
the_grant_of_a_connection_names_the_principal :: proc(t: ^testing.T) {
	grant := caller_grant_make(4500, 1, false)
	testing.expect_value(t, grant & CALLER_AMOUNT_MASK, 4500)
	testing.expect_value(t, caller_principal(grant), 1)
	testing.expect(t, grant & CALLER_ACTS_FOR_PRINCIPAL == 0)
	acting := caller_grant_make(0, 0, true)
	testing.expect_value(t, caller_principal(acting), 0)
	testing.expect(t, acting & CALLER_ACTS_FOR_PRINCIPAL != 0)
	testing.expect_value(t, acting & CALLER_AMOUNT_MASK, 0)
	largest := caller_grant_make(CALLER_AMOUNT_MASK + 1, CALLER_PRINCIPAL_LIMIT, false)
	testing.expect_value(t, largest, 0)
	// An amount out of its field cannot set the flag of a connection that
	// reads only, and the flag keeps the amount and the principal.
	testing.expect(t, caller_grant_make(CALLER_READS_ONLY, 0, false) & CALLER_READS_ONLY == 0)
	reading := caller_grant_make(4096, 2, false) | CALLER_READS_ONLY
	testing.expect_value(t, reading & CALLER_AMOUNT_MASK, 4096)
	testing.expect_value(t, caller_principal(reading), 2)
	testing.expect(t, reading & CALLER_ACTS_FOR_PRINCIPAL == 0)
	testing.expect_value(t, caller_principal(caller_grant_make(0, CALLER_PRINCIPAL_LIMIT - 1, true)), CALLER_PRINCIPAL_LIMIT - 1)
	// The same for the flag of the erase of versions: an amount cannot set
	// it, and it keeps the amount.
	testing.expect(t, caller_grant_make(CALLER_ERASES_VERSIONS, 0, false) & CALLER_ERASES_VERSIONS == 0)
	erasing := caller_grant_make(64, 0, false) | CALLER_ERASES_VERSIONS
	testing.expect_value(t, erasing & CALLER_AMOUNT_MASK, 64)
	testing.expect(t, erasing & CALLER_READS_ONLY == 0)
}
