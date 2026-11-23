#+build !freestanding
package tls_tcp_module

import "core:slice"
import "core:testing"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:quic"
import "modus:system"
import "modus:tls_tcp"

// A byte that no export writes on its own: a buffer filled with it shows
// each byte that a refused call wrote.
@(private = "file")
UNTOUCHED :: u8(0xA5)

// A header record that no parse gives: its legacy version is not 0x0303.
@(private = "file")
UNTOUCHED_HEADER :: tls_tcp.Record_Header{content_type = .Alert, legacy_version = 0xBEEF, length = 0xBEEF}

@(private = "file")
UNTOUCHED_INTEGER :: Variable_Length_Integer{value = -7, size = -7}

@(private = "file")
UNTOUCHED_PROBE :: Quic_Header_Probe{form = .Long, version = 0xDEAD_BEEF}

@(private = "file")
bytes_to_read :: proc(bytes: []u8) -> system.Bytes_To_Read {
	return {bytes = raw_data(bytes), count = u64(len(bytes)), capacity = u64(len(bytes))}
}

@(private = "file")
bytes_to_change :: proc(bytes: []u8) -> system.Bytes_To_Change {
	return {bytes = raw_data(bytes), count = u64(len(bytes)), capacity = u64(len(bytes))}
}

@(private = "file")
all_untouched :: proc(bytes: []u8) -> bool {
	for byte in bytes {
		if byte != UNTOUCHED {
			return false
		}
	}
	return true
}

// The pair of an export, as one value that a test compares.
@(private = "file")
Answer :: struct {
	outcome: call_outcome.Call_Outcome,
	value:   i64,
}

@(private = "file")
answer_of :: proc(outcome: call_outcome.Call_Outcome, value: i64) -> Answer {
	return {outcome, value}
}

// expect_refusal checks the outcome Argument_Refused with the value 0, and
// each field of the error record.
@(private = "file")
expect_refusal :: proc(t: ^testing.T, result: Answer, error: errors.Error_Record, expected: errors.Error_Record, loc := #caller_location) {
	testing.expect_value(t, result, Answer{.Argument_Refused, 0}, loc = loc)
	testing.expect_value(t, error, expected, loc = loc)
}

// parse_into gives the result of tls_record_header_parse over bytes, its
// error record, and the header record that started as UNTOUCHED_HEADER.
@(private = "file")
parse_into :: proc(bytes: []u8) -> (result: Answer, error: errors.Error_Record, header: tls_tcp.Record_Header) {
	input := bytes_to_read(bytes)
	header = UNTOUCHED_HEADER
	table := system.Table_To_Change(tls_tcp.Record_Header){records = &header, count = 1, capacity = 1}
	result = answer_of(tls_record_header_parse(&input, &table, &error))
	return
}

@(test)
record_header_parse_refuses_each_bad_place :: proc(t: ^testing.T) {
	error: errors.Error_Record
	header := UNTOUCHED_HEADER
	table := system.Table_To_Change(tls_tcp.Record_Header){records = &header, count = 1, capacity = 1}
	valid := [5]u8{22, 0x03, 0x03, 0x00, 0x10}
	input := bytes_to_read(valid[:])

	expect_refusal(t, answer_of(tls_record_header_parse(nil, &table, &error)), error, errors.error_make(.Bad_Address, .Bytes, 1))
	expect_refusal(t, answer_of(tls_record_header_parse(&input, nil, &error)), error, errors.error_make(.Bad_Address, .Records, 2, 0, 0, 1))
	empty := system.Bytes_To_Read{}
	expect_refusal(t, answer_of(tls_record_header_parse(&empty, &table, &error)), error, errors.error_make(.Too_Small, .Bytes, 1, 0, 5))
	nil_bytes := system.Bytes_To_Read{bytes = nil, count = 5, capacity = 5}
	expect_refusal(t, answer_of(tls_record_header_parse(&nil_bytes, &table, &error)), error, errors.error_make(.Bad_Address, .Bytes, 1, 0, 5))
	no_record := system.Table_To_Change(tls_tcp.Record_Header){records = &header, count = 0, capacity = 1}
	expect_refusal(t, answer_of(tls_record_header_parse(&input, &no_record, &error)), error, errors.error_make(.Too_Small, .Records, 2, 0, 1))
	nil_records := system.Table_To_Change(tls_tcp.Record_Header){records = nil, count = 1, capacity = 1}
	expect_refusal(t, answer_of(tls_record_header_parse(&input, &nil_records, &error)), error, errors.error_make(.Bad_Address, .Records, 2, 0, 1, 1))
	testing.expect_value(t, header, UNTOUCHED_HEADER)
	// A nil error record is allowed: the caller asked for no record.
	testing.expect_value(t, answer_of(tls_record_header_parse(&empty, &table, nil)), Answer{.Argument_Refused, 0})
}

@(test)
record_header_parse_refuses_each_short_input :: proc(t: ^testing.T) {
	valid := [5]u8{22, 0x03, 0x03, 0x00, 0x10}
	for count in 0 ..< 5 {
		result, error, header := parse_into(valid[:count])
		expect_refusal(t, result, error, errors.error_make(.Too_Small, .Bytes, 1, i64(count), 5))
		testing.expect_value(t, header, UNTOUCHED_HEADER)
	}
}

@(test)
record_header_parse_refuses_unknown_content_types :: proc(t: ^testing.T) {
	for content_type in ([]u8{0, 1, 19, 24, 25, 0x80, 0xFF}) {
		bytes := [5]u8{content_type, 0x03, 0x03, 0x00, 0x01}
		result, error, header := parse_into(bytes[:])
		expect_refusal(t, result, error, errors.error_make(.Bad_Value, .None, 1, i64(content_type), 23, 1))
		testing.expect_value(t, header, UNTOUCHED_HEADER)
	}
}

@(test)
record_header_parse_refuses_other_legacy_versions :: proc(t: ^testing.T) {
	// 0x0301 is the version of a first ClientHello: the strict border of
	// the module refuses it too.
	for version in ([]u16{0x0000, 0x0300, 0x0301, 0x0302, 0x0304, 0x0403, 0xFFFF}) {
		bytes := [5]u8{23, u8(version >> 8), u8(version), 0x00, 0x01}
		result, error, header := parse_into(bytes[:])
		expect_refusal(t, result, error, errors.error_make(.Bad_Value, .None, 1, i64(version), 0x0303, 2))
		testing.expect_value(t, header, UNTOUCHED_HEADER)
	}
}

@(test)
record_header_parse_refuses_lengths_past_the_limit :: proc(t: ^testing.T) {
	Case :: struct {
		content_type: tls_tcp.Tls_Content_Type,
		limit:        int,
	}
	cases := [?]Case{{.Application_Data, tls_tcp.MAX_CIPHERTEXT_SIZE}, {.Handshake, tls_tcp.MAX_PLAINTEXT_SIZE}, {.Alert, tls_tcp.MAX_PLAINTEXT_SIZE}, {.Change_Cipher_Spec, tls_tcp.MAX_PLAINTEXT_SIZE}}
	for each in cases {
		for length in ([]int{each.limit + 1, each.limit + 256, int(max(u16))}) {
			bytes := [5]u8{u8(each.content_type), 0x03, 0x03, u8(length >> 8), u8(length)}
			result, error, header := parse_into(bytes[:])
			expect_refusal(t, result, error, errors.error_make(.Too_Long, .Bytes, 1, i64(length), i64(each.limit)))
			testing.expect_value(t, header, UNTOUCHED_HEADER)
		}
		// The limit itself is a valid length.
		bytes := [5]u8{u8(each.content_type), 0x03, 0x03, u8(each.limit >> 8), u8(each.limit)}
		result, error, header := parse_into(bytes[:])
		testing.expect_value(t, result, Answer{.Succeeded, 5})
		testing.expect_value(t, error, errors.Error_Record{})
		testing.expect_value(t, header, tls_tcp.Record_Header{content_type = each.content_type, legacy_version = 0x0303, length = u16(each.limit)})
	}
}

// The export gives the header that the package gives, and reads only the
// 5 bytes of the header out of a longer input.
@(test)
record_header_parse_is_the_parse_of_the_package :: proc(t: ^testing.T) {
	for content_type in tls_tcp.Tls_Content_Type {
		for length in ([]u16{0, 1, 255, 256, 0x1234, u16(tls_tcp.MAX_PLAINTEXT_SIZE)}) {
			bytes := [9]u8{u8(content_type), 0x03, 0x03, u8(length >> 8), u8(length), 0xFF, 0xFF, 0xFF, 0xFF}
			expected, refusal := tls_tcp.record_parse_header(bytes[:], false)
			testing.expect_value(t, refusal, tls_tcp.Tls_Refusal.None)
			result, error, header := parse_into(bytes[:])
			testing.expect_value(t, result, Answer{.Succeeded, 5})
			testing.expect_value(t, error, errors.Error_Record{})
			testing.expect_value(t, header, expected)
		}
	}
}

@(test)
record_header_write_refuses_each_bad_argument_and_writes_nothing :: proc(t: ^testing.T) {
	error: errors.Error_Record
	buffer: [8]u8
	for &byte in buffer {
		byte = UNTOUCHED
	}
	output := bytes_to_change(buffer[:])
	for word in ([]i64{min(i64), -1, 0, 19, 24, 255, 256, max(i64)}) {
		expect_refusal(t, answer_of(tls_record_header_write(word, 1, &output, &error)), error, errors.error_make(.Bad_Value, .None, 1, word, 23))
	}
	for length in ([]i64{min(i64), -1}) {
		expect_refusal(t, answer_of(tls_record_header_write(22, length, &output, &error)), error, errors.error_make(.Bad_Value, .Bytes, 2, length, tls_tcp.MAX_PLAINTEXT_SIZE))
	}
	for length in ([]i64{tls_tcp.MAX_PLAINTEXT_SIZE + 1, tls_tcp.MAX_CIPHERTEXT_SIZE, max(i64)}) {
		expect_refusal(t, answer_of(tls_record_header_write(22, length, &output, &error)), error, errors.error_make(.Too_Long, .Bytes, 2, length, tls_tcp.MAX_PLAINTEXT_SIZE))
	}
	for length in ([]i64{tls_tcp.MAX_CIPHERTEXT_SIZE + 1, i64(max(u16)) + 1, max(i64)}) {
		expect_refusal(t, answer_of(tls_record_header_write(23, length, &output, &error)), error, errors.error_make(.Too_Long, .Bytes, 2, length, tls_tcp.MAX_CIPHERTEXT_SIZE))
	}
	expect_refusal(t, answer_of(tls_record_header_write(22, 1, nil, &error)), error, errors.error_make(.Bad_Address, .Bytes, 3, 0, 0, 1))
	for count in 0 ..< 5 {
		short := bytes_to_change(buffer[:count])
		expect_refusal(t, answer_of(tls_record_header_write(22, 1, &short, &error)), error, errors.error_make(.Too_Small, .Bytes, 3, i64(count), 5))
	}
	nil_bytes := system.Bytes_To_Change{bytes = nil, count = 5, capacity = 5}
	expect_refusal(t, answer_of(tls_record_header_write(22, 1, &nil_bytes, &error)), error, errors.error_make(.Bad_Address, .Bytes, 3, 0, 5, 1))
	testing.expect(t, all_untouched(buffer[:]), "a refused write writes no byte")
}

// The header that the export writes is the header that the package writes
// for a plaintext record, and the parse of the export reads it back. The
// byte after the header stays as it was.
@(test)
record_header_write_is_the_write_of_the_package_and_parses_back :: proc(t: ^testing.T) {
	payload: [tls_tcp.MAX_PLAINTEXT_SIZE]u8
	package_record: [tls_tcp.RECORD_HEADER_SIZE + tls_tcp.MAX_PLAINTEXT_SIZE]u8
	for content_type in tls_tcp.Tls_Content_Type {
		for length in ([]int{0, 1, 255, 256, tls_tcp.MAX_PLAINTEXT_SIZE}) {
			written, refusal := tls_tcp.record_write_plaintext(content_type, payload[:length], package_record[:])
			testing.expect_value(t, refusal, tls_tcp.Tls_Refusal.None)
			testing.expect_value(t, written, 5 + length)
			buffer := [6]u8{UNTOUCHED, UNTOUCHED, UNTOUCHED, UNTOUCHED, UNTOUCHED, UNTOUCHED}
			output := bytes_to_change(buffer[:])
			error: errors.Error_Record
			testing.expect_value(t, answer_of(tls_record_header_write(i64(content_type), i64(length), &output, &error)), Answer{.Succeeded, 5})
			testing.expect_value(t, error, errors.Error_Record{})
			testing.expect(t, slice.equal(buffer[:5], package_record[:5]), "the header of the package")
			testing.expect_value(t, buffer[5], UNTOUCHED)
			result, parse_error, header := parse_into(buffer[:5])
			testing.expect_value(t, result, Answer{.Succeeded, 5})
			testing.expect_value(t, parse_error, errors.Error_Record{})
			testing.expect_value(t, header, tls_tcp.Record_Header{content_type = content_type, legacy_version = 0x0303, length = u16(length)})
		}
	}
	// An encrypted record is 256 bytes longer at most.
	buffer: [5]u8
	output := bytes_to_change(buffer[:])
	error: errors.Error_Record
	testing.expect_value(t, answer_of(tls_record_header_write(23, tls_tcp.MAX_CIPHERTEXT_SIZE, &output, &error)), Answer{.Succeeded, 5})
	testing.expect_value(t, buffer, [5]u8{23, 0x03, 0x03, 0x41, 0x00})
	expected, refusal := tls_tcp.record_parse_header(buffer[:], false)
	testing.expect_value(t, refusal, tls_tcp.Tls_Refusal.None)
	testing.expect_value(t, expected.length, u16(tls_tcp.MAX_CIPHERTEXT_SIZE))
}

@(test)
cipher_suite_supported_refuses_words_out_of_sixteen_bits :: proc(t: ^testing.T) {
	error: errors.Error_Record
	for word in ([]i64{min(i64), -1, i64(max(u16)) + 1, max(i64)}) {
		expect_refusal(t, answer_of(cipher_suite_supported(word, &error)), error, errors.error_make(.Bad_Value, .None, 1, 0, i64(max(u16)), word))
	}
	error = {}
	testing.expect_value(t, answer_of(cipher_suite_supported(0x1302, &error)), Answer{.Succeeded, 0})
	testing.expect_value(t, answer_of(cipher_suite_supported(0, &error)), Answer{.Succeeded, 0})
	testing.expect_value(t, answer_of(cipher_suite_supported(0x1301, &error)), Answer{.Succeeded, 1})
	testing.expect_value(t, answer_of(cipher_suite_supported(0x1303, &error)), Answer{.Succeeded, 1})
	testing.expect_value(t, error, errors.Error_Record{})
	testing.expect_value(t, record_max_plaintext_bytes(), 16384)
	testing.expect_value(t, record_max_ciphertext_bytes(), 16640)
}

// integer_read_into gives the result of quic_variable_length_integer_read
// over bytes, its error record, and the record that started untouched.
@(private = "file")
integer_read_into :: proc(bytes: []u8) -> (result: Answer, error: errors.Error_Record, integer: Variable_Length_Integer) {
	input := bytes_to_read(bytes)
	integer = UNTOUCHED_INTEGER
	table := system.Table_To_Change(Variable_Length_Integer){records = &integer, count = 1, capacity = 1}
	result = answer_of(quic_variable_length_integer_read(&input, &table, &error))
	return
}

@(test)
variable_length_integer_read_refuses_each_bad_place :: proc(t: ^testing.T) {
	error: errors.Error_Record
	integer := UNTOUCHED_INTEGER
	table := system.Table_To_Change(Variable_Length_Integer){records = &integer, count = 1, capacity = 1}
	one := [1]u8{0x25}
	input := bytes_to_read(one[:])
	expect_refusal(t, answer_of(quic_variable_length_integer_read(nil, &table, &error)), error, errors.error_make(.Bad_Address, .Bytes, 1))
	expect_refusal(t, answer_of(quic_variable_length_integer_read(&input, nil, &error)), error, errors.error_make(.Bad_Address, .Records, 2, 0, 0, 1))
	empty := system.Bytes_To_Read{}
	expect_refusal(t, answer_of(quic_variable_length_integer_read(&empty, &table, &error)), error, errors.error_make(.Too_Small, .Bytes, 1, 0, 1))
	nil_bytes := system.Bytes_To_Read{bytes = nil, count = 1, capacity = 1}
	expect_refusal(t, answer_of(quic_variable_length_integer_read(&nil_bytes, &table, &error)), error, errors.error_make(.Bad_Address, .Bytes, 1, 0, 1))
	no_record := system.Table_To_Change(Variable_Length_Integer){records = &integer, count = 0, capacity = 1}
	expect_refusal(t, answer_of(quic_variable_length_integer_read(&input, &no_record, &error)), error, errors.error_make(.Too_Small, .Records, 2, 0, 1))
	nil_records := system.Table_To_Change(Variable_Length_Integer){records = nil, count = 1, capacity = 1}
	expect_refusal(t, answer_of(quic_variable_length_integer_read(&input, &nil_records, &error)), error, errors.error_make(.Bad_Address, .Records, 2, 0, 1, 1))
	testing.expect_value(t, integer, UNTOUCHED_INTEGER)
}

// Each length that the first byte names, with one byte less than it needs
// and with each count before it, is refused, and the package refuses it
// too.
@(test)
variable_length_integer_read_refuses_each_truncated_encoding :: proc(t: ^testing.T) {
	full := [8]u8{0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}
	for prefix in 1 ..< 4 {
		size := 1 << uint(prefix)
		full[0] = u8(prefix << 6) | 0x3F
		for count in 1 ..< size {
			result, error, integer := integer_read_into(full[:count])
			expect_refusal(t, result, error, errors.error_make(.Too_Small, .Bytes, 1, i64(count), i64(size)))
			testing.expect_value(t, integer, UNTOUCHED_INTEGER)
			_, _, ok := quic.variable_length_integer_read(full[:count], 0)
			testing.expect(t, !ok, "the package refuses it too")
		}
	}
}

@(private = "file")
BOUNDARY_VALUES := [?]i64{0, 1, 63, 64, 16383, 16384, 1073741823, 1073741824, (i64(1) << 62) - 1}

@(private = "file")
BOUNDARY_SIZES := [?]i64{1, 1, 1, 2, 2, 4, 4, 8, 8}

@(test)
variable_length_integer_write_refuses_each_bad_argument_and_writes_nothing :: proc(t: ^testing.T) {
	error: errors.Error_Record
	buffer: [9]u8
	for &byte in buffer {
		byte = UNTOUCHED
	}
	output := bytes_to_change(buffer[:])
	for value in ([]i64{min(i64), -(i64(1) << 62), -1, i64(1) << 62, (i64(1) << 62) + 1, max(i64)}) {
		expect_refusal(t, answer_of(quic_variable_length_integer_write(value, &output, &error)), error, errors.error_make(.Bad_Value, .None, 1, value, QUIC_VARIABLE_LENGTH_INTEGER_LARGEST))
	}
	expect_refusal(t, answer_of(quic_variable_length_integer_write(0, nil, &error)), error, errors.error_make(.Bad_Address, .Bytes, 2, 0, 0, 1))
	for value, index in BOUNDARY_VALUES {
		size := BOUNDARY_SIZES[index]
		for count in 0 ..< size {
			short := bytes_to_change(buffer[:count])
			expect_refusal(t, answer_of(quic_variable_length_integer_write(value, &short, &error)), error, errors.error_make(.Too_Small, .Bytes, 2, count, size))
		}
	}
	nil_bytes := system.Bytes_To_Change{bytes = nil, count = 8, capacity = 8}
	expect_refusal(t, answer_of(quic_variable_length_integer_write(1, &nil_bytes, &error)), error, errors.error_make(.Bad_Address, .Bytes, 2, 0, 8, 1))
	testing.expect(t, all_untouched(buffer[:]), "a refused write writes no byte")
}

// At each edge of each size, the export writes the bytes of the package
// in the shortest size, writes no byte after them, and its read gives the
// value and the size back, as the read of the package does.
@(test)
variable_length_integer_round_trip_is_the_package_at_each_edge :: proc(t: ^testing.T) {
	for value, index in BOUNDARY_VALUES {
		size := BOUNDARY_SIZES[index]
		testing.expect_value(t, i64(quic.variable_length_integer_size(u64(value))), size)
		package_bytes: [8]u8
		testing.expect_value(t, i64(quic.variable_length_integer_write(package_bytes[:], 0, u64(value), int(size))), size)
		buffer := [9]u8{UNTOUCHED, UNTOUCHED, UNTOUCHED, UNTOUCHED, UNTOUCHED, UNTOUCHED, UNTOUCHED, UNTOUCHED, UNTOUCHED}
		output := bytes_to_change(buffer[:])
		error: errors.Error_Record
		testing.expect_value(t, answer_of(quic_variable_length_integer_write(value, &output, &error)), Answer{.Succeeded, size})
		testing.expect_value(t, error, errors.Error_Record{})
		testing.expect(t, slice.equal(buffer[:size], package_bytes[:size]), "the bytes of the package")
		testing.expect(t, all_untouched(buffer[size:]), "no byte after the encoding")
		result, read_error, integer := integer_read_into(buffer[:])
		testing.expect_value(t, result, Answer{.Succeeded, size})
		testing.expect_value(t, read_error, errors.Error_Record{})
		testing.expect_value(t, integer, Variable_Length_Integer{value = value, size = size})
		package_value, package_size, ok := quic.variable_length_integer_read(buffer[:], 0)
		testing.expect(t, ok)
		testing.expect_value(t, i64(package_value), value)
		testing.expect_value(t, i64(package_size), size)
	}
}

// The examples of RFC 9000, appendix A.1, and longer encodings of small
// values, which RFC 9000 allows outside a frame type.
@(test)
variable_length_integer_read_gives_the_examples_of_the_rfc :: proc(t: ^testing.T) {
	Case :: struct {
		bytes: []u8,
		value: i64,
	}
	cases := [?]Case {
		{{0xC2, 0x19, 0x7C, 0x5E, 0xFF, 0x14, 0xE8, 0x8C}, 151288809941952652},
		{{0x9D, 0x7F, 0x3E, 0x7D}, 494878333},
		{{0x7B, 0xBD}, 15293},
		{{0x25}, 37},
		{{0x40, 0x25}, 37},
		{{0xC0, 0, 0, 0, 0, 0, 0, 0}, 0},
		{{0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}, (i64(1) << 62) - 1},
	}
	for each in cases {
		result, error, integer := integer_read_into(each.bytes)
		testing.expect_value(t, result, Answer{.Succeeded, i64(len(each.bytes))})
		testing.expect_value(t, error, errors.Error_Record{})
		testing.expect_value(t, integer, Variable_Length_Integer{value = each.value, size = i64(len(each.bytes))})
	}
}

// probe_into gives the result of quic_header_probe over bytes, its error
// record, and the record that started untouched.
@(private = "file")
probe_into :: proc(bytes: []u8) -> (result: Answer, error: errors.Error_Record, probe: Quic_Header_Probe) {
	input := bytes_to_read(bytes)
	probe = UNTOUCHED_PROBE
	table := system.Table_To_Change(Quic_Header_Probe){records = &probe, count = 1, capacity = 1}
	result = answer_of(quic_header_probe(&input, &table, &error))
	return
}

@(test)
header_probe_refuses_each_bad_place :: proc(t: ^testing.T) {
	error: errors.Error_Record
	probe := UNTOUCHED_PROBE
	table := system.Table_To_Change(Quic_Header_Probe){records = &probe, count = 1, capacity = 1}
	short_header := [1]u8{0x40}
	input := bytes_to_read(short_header[:])
	expect_refusal(t, answer_of(quic_header_probe(nil, &table, &error)), error, errors.error_make(.Bad_Address, .Bytes, 1))
	expect_refusal(t, answer_of(quic_header_probe(&input, nil, &error)), error, errors.error_make(.Bad_Address, .Records, 2, 0, 0, 1))
	empty := system.Bytes_To_Read{}
	expect_refusal(t, answer_of(quic_header_probe(&empty, &table, &error)), error, errors.error_make(.Too_Small, .Bytes, 1, 0, 1))
	nil_bytes := system.Bytes_To_Read{bytes = nil, count = 1, capacity = 1}
	expect_refusal(t, answer_of(quic_header_probe(&nil_bytes, &table, &error)), error, errors.error_make(.Bad_Address, .Bytes, 1, 0, 1))
	no_record := system.Table_To_Change(Quic_Header_Probe){records = &probe, count = 0, capacity = 1}
	expect_refusal(t, answer_of(quic_header_probe(&input, &no_record, &error)), error, errors.error_make(.Too_Small, .Records, 2, 0, 1))
	nil_records := system.Table_To_Change(Quic_Header_Probe){records = nil, count = 1, capacity = 1}
	expect_refusal(t, answer_of(quic_header_probe(&input, &nil_records, &error)), error, errors.error_make(.Bad_Address, .Records, 2, 0, 1, 1))
	testing.expect_value(t, probe, UNTOUCHED_PROBE)
}

@(test)
header_probe_refuses_truncated_long_headers_and_a_clear_fixed_bit :: proc(t: ^testing.T) {
	long_header := [5]u8{0xC0, 0, 0, 0, 1}
	for count in 1 ..< 5 {
		result, error, probe := probe_into(long_header[:count])
		expect_refusal(t, result, error, errors.error_make(.Too_Small, .Bytes, 1, i64(count), 5))
		testing.expect_value(t, probe, UNTOUCHED_PROBE)
	}
	// The Fixed Bit clear: a short header, and a long header of version 1.
	// The reader of the package refuses the same packets.
	for first in ([]u8{0x00, 0x01, 0x3F}) {
		packet := [32]u8{0 = first}
		result, error, probe := probe_into(packet[:])
		expect_refusal(t, result, error, errors.error_make(.Bad_Value, .None, 1, i64(first), 0x40, 1))
		testing.expect_value(t, probe, UNTOUCHED_PROBE)
		header: quic.Packet_Header
		package_error: errors.Error_Record
		testing.expect(t, !quic.header_read(packet[:], 0, 0, &header, &package_error))
		testing.expect_value(t, errors.Kind(package_error.kind), errors.Kind.Bad_Value)
	}
	for first in ([]u8{0x80, 0x90, 0xA0, 0xB0, 0xBF}) {
		packet := [32]u8{0 = first, 4 = 1}
		result, error, probe := probe_into(packet[:])
		expect_refusal(t, result, error, errors.error_make(.Bad_Value, .None, 1, i64(first), 0x40, 1))
		testing.expect_value(t, probe, UNTOUCHED_PROBE)
		header: quic.Packet_Header
		package_error: errors.Error_Record
		testing.expect(t, !quic.header_read(packet[:], 0, 0, &header, &package_error))
		testing.expect_value(t, errors.Kind(package_error.kind), errors.Kind.Bad_Value)
	}
}

// For each packet that the reader of the package takes, the probe gives
// the same form and the same version, from the first 5 bytes only.
@(test)
header_probe_agrees_with_the_reader_of_the_package :: proc(t: ^testing.T) {
	short_header: [21]u8
	short_header[0] = 0x40
	// A Handshake packet of version 1: no connection identifier, a Length
	// of 20, and 20 bytes for the packet number and the sample.
	handshake: [28]u8
	handshake[0] = 0xE0
	handshake[4] = 1
	handshake[7] = 20
	version_negotiation := []u8{0x80, 0, 0, 0, 0, 1, 0xAA, 1, 0xBB, 0, 0, 0, 1}
	unknown_version := []u8{0x00 | 0x80, 0xFF, 0x00, 0x00, 0x1D, 2, 0xAA, 0xAA, 0, 0x99}
	Case :: struct {
		packet: []u8,
		probe:  Quic_Header_Probe,
		read:   i64,
		type:   quic.Packet_Type,
	}
	cases := [?]Case {
		{short_header[:], {form = .Short, version = 0}, 1, .One_Rtt},
		{handshake[:], {form = .Long, version = quic.QUIC_VERSION_1}, 5, .Handshake},
		{version_negotiation, {form = .Long, version = 0}, 5, .Version_Negotiation},
		{unknown_version, {form = .Long, version = 0xFF00001D}, 5, .Unknown_Version},
	}
	for each in cases {
		header: quic.Packet_Header
		package_error: errors.Error_Record
		testing.expect(t, quic.header_read(each.packet, 0, 0, &header, &package_error))
		testing.expect_value(t, header.type, each.type)
		testing.expect_value(t, header.version, each.probe.version)
		result, error, probe := probe_into(each.packet)
		testing.expect_value(t, result, Answer{.Succeeded, each.read})
		testing.expect_value(t, error, errors.Error_Record{})
		testing.expect_value(t, probe, each.probe)
		// The probe reads no byte past what it gives: the first bytes alone
		// give the same answer.
		head_result, head_error, head_probe := probe_into(each.packet[:each.read])
		testing.expect_value(t, head_result, Answer{.Succeeded, each.read})
		testing.expect_value(t, head_error, errors.Error_Record{})
		testing.expect_value(t, head_probe, each.probe)
	}
}
