#+build !freestanding
package declaration_eval

import "core:strings"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/byte_order"

// declaration_path_valid refuses every hostile or non-.lex path and accepts
// valid relative paths inside a tree.
@(test)
declaration_paths_at_the_border :: proc(t: ^testing.T) {
	refused := [?]string {
		"",
		".lex",
		"/pins.lex",
		"pins.lex/",
		"a//b.lex",
		"./pins.lex",
		"../pins.lex",
		"a/../b.lex",
		"a/./b.lex",
		"a/..",
		"a\\b.lex",
		"pins.txt",
		"pins.lexx",
		"pins\x00.lex",
		"pins\n.lex",
		strings.concatenate({strings.repeat("a", DECLARATION_PATH_LIMIT - 3, context.temp_allocator), ".lex"}, context.temp_allocator),
	}
	for path in refused {
		testing.expectf(t, !declaration_path_valid(path), "%q must be refused", path)
	}
	exact_limit := strings.concatenate({strings.repeat("a", DECLARATION_PATH_LIMIT - 4, context.temp_allocator), ".lex"}, context.temp_allocator)
	testing.expect_value(t, len(exact_limit), DECLARATION_PATH_LIMIT)
	accepted := [?]string {
		"pins.lex",
		"project.lex",
		"src/plan.lex",
		"a/b/c/mod.lex",
		"a..b.lex",
		exact_limit,
	}
	for path in accepted {
		testing.expectf(t, declaration_path_valid(path), "%q must be accepted", path)
	}
}

// bundle_validate refuses every damaged or hostile bundle before any lookup.
@(test)
bundle_refusals_at_the_border :: proc(t: ^testing.T) {
	// Empty and one byte below header size.
	testing.expect_value(t, bundle_validate(nil), Bundle_Refusal.Too_Small)
	small: [BUNDLE_HEADER_BYTES - 1]u8
	testing.expect_value(t, bundle_validate(small[:]), Bundle_Refusal.Too_Small)

	// Build a valid bundle, then mutate each field one by one.
	here := blake3.hash(transmute([]u8)string("tree"))
	decl_hash := blake3.hash(transmute([]u8)string("decl"))
	entries := [2]Bundle_Input_Entry {
		{kind = .File_Path, path = "pins.lex", content = "{ a = 1 }"},
		{kind = .Declaration_Hash, hash = decl_hash, content = "{ b = 2 }"},
	}
	buf: [512]u8
	written, write_err := bundle_write(buf[:], entries[:], true, here)
	testing.expect_value(t, write_err, Bundle_Refusal.None)
	testing.expect_value(t, bundle_validate(buf[:written]), Bundle_Refusal.None)

	// Bad magic.
	bad := make([]u8, written, context.temp_allocator)
	copy(bad, buf[:written])
	bad[0] ~= 0xff
	testing.expect_value(t, bundle_validate(bad), Bundle_Refusal.Bad_Magic)

	// Bad version.
	copy(bad, buf[:written])
	byte_order.write_u32_little_endian(bad, 4, BUNDLE_VERSION + 1)
	testing.expect_value(t, bundle_validate(bad), Bundle_Refusal.Bad_Version)

	// Unknown flag bit.
	copy(bad, buf[:written])
	byte_order.write_u32_little_endian(bad, 12, 2)
	testing.expect_value(t, bundle_validate(bad), Bundle_Refusal.Bad_Flags)

	// Too many entries (one past BUNDLE_ENTRY_LIMIT).
	copy(bad, buf[:written])
	byte_order.write_u32_little_endian(bad, 8, BUNDLE_ENTRY_LIMIT + 1)
	testing.expect_value(t, bundle_validate(bad), Bundle_Refusal.Too_Many_Entries)

	// Unknown entry kind enum word (0 and 99).
	for bad_kind in ([2]u8{0, 99}) {
		copy(bad, buf[:written])
		bad[BUNDLE_HEADER_BYTES] = bad_kind
		testing.expect_value(t, bundle_validate(bad), Bundle_Refusal.Unknown_Entry_Kind)
	}

	// Non-zero reserved byte.
	copy(bad, buf[:written])
	bad[BUNDLE_HEADER_BYTES + 1] = 1
	testing.expect_value(t, bundle_validate(bad), Bundle_Refusal.Bad_Reserved)

	// Out-of-bounds offset and overflowing length.
	copy(bad, buf[:written])
	byte_order.write_u32_little_endian(bad, BUNDLE_HEADER_BYTES + 12, u32(written) + 1)
	testing.expect_value(t, bundle_validate(bad), Bundle_Refusal.Entry_Out_Of_Bounds)

	copy(bad, buf[:written])
	byte_order.write_u32_little_endian(bad, BUNDLE_HEADER_BYTES + 16, max(u32))
	testing.expect_value(t, bundle_validate(bad), Bundle_Refusal.Entry_Out_Of_Bounds)

	// Buffer too small and invalid path refused by bundle_write.
	_, short_err := bundle_write(buf[:written - 1], entries[:], true, here)
	testing.expect_value(t, short_err, Bundle_Refusal.Buffer_Too_Small)
	bad_path_entries := [1]Bundle_Input_Entry{{kind = .File_Path, path = "../escape.lex", content = "1"}}
	_, path_err := bundle_write(buf[:], bad_path_entries[:])
	testing.expect_value(t, path_err, Bundle_Refusal.Invalid_Path)

	// Valid lookup round-trip.
	got_here, has_here := bundle_here_hash(buf[:written])
	testing.expect(t, has_here && got_here == here)
	pins_src, pins_ok := bundle_lookup_path(buf[:written], "pins.lex")
	testing.expect(t, pins_ok && pins_src == "{ a = 1 }")
	decl_src, decl_ok := bundle_lookup_hash(buf[:written], decl_hash)
	testing.expect(t, decl_ok && decl_src == "{ b = 2 }")
	_, missing_ok := bundle_lookup_path(buf[:written], "nope.lex")
	testing.expect(t, !missing_ok)
}

// output_validate refuses every damaged output buffer and accepts valid
// canonical values and refusal records.
@(test)
output_validation_and_round_trip :: proc(t: ^testing.T) {
	buf: [512]u8
	writer := output_writer_start(buf[:], {status = .Ok, failure_kind = .None, steps_taken = 7})
	output_write_u8(&writer, u8(Value_Tag.Record))
	output_write_u32(&writer, 2)
	output_write_string(&writer, "a")
	output_write_integer(&writer, 42)
	output_write_string(&writer, "b")
	output_write_boolean(&writer, true)
	testing.expect(t, !writer.overflow)

	valid := buf[:writer.written]
	header, err := output_validate(valid)
	testing.expect_value(t, err, Output_Refusal.None)
	testing.expect_value(t, header.status, Output_Status.Ok)
	testing.expect_value(t, header.steps_taken, u32(7))

	// Truncated at every prefix.
	for cut in 0 ..< len(valid) {
		_, cut_err := output_validate(valid[:cut])
		testing.expectf(t, cut_err != .None, "prefix of %d bytes must be refused", cut)
	}

	// Trailing byte refused.
	buf[writer.written] = 0
	_, trailing_err := output_validate(buf[:writer.written + 1])
	testing.expect_value(t, trailing_err, Output_Refusal.Trailing_Bytes)

	// Unknown status, unknown failure kind, bad boolean, unknown value tag.
	bad := make([]u8, len(valid), context.temp_allocator)
	copy(bad, valid)
	bad[8] = 99
	_, err = output_validate(bad)
	testing.expect_value(t, err, Output_Refusal.Unknown_Status)

	copy(bad, valid)
	bad[9] = 99
	_, err = output_validate(bad)
	testing.expect_value(t, err, Output_Refusal.Unknown_Failure_Kind)

	copy(bad, valid)
	bad[OUTPUT_HEADER_BYTES] = 99
	_, err = output_validate(bad)
	testing.expect_value(t, err, Output_Refusal.Unknown_Value_Tag)

	copy(bad, valid)
	bad[len(bad) - 1] = 2 // boolean must be 0 or 1
	_, err = output_validate(bad)
	testing.expect_value(t, err, Output_Refusal.Bad_Boolean)

	// Unsorted record fields refused.
	unsorted_writer := output_writer_start(buf[:], {status = .Ok})
	output_write_u8(&unsorted_writer, u8(Value_Tag.Record))
	output_write_u32(&unsorted_writer, 2)
	output_write_string(&unsorted_writer, "z")
	output_write_integer(&unsorted_writer, 1)
	output_write_string(&unsorted_writer, "a")
	output_write_integer(&unsorted_writer, 2)
	_, err = output_validate(buf[:unsorted_writer.written])
	testing.expect_value(t, err, Output_Refusal.Unsorted_Record)

	// Refusal output round-trip.
	ref_len, ref_ok := output_write_refusal(buf[:], .Cycle_Detected, 12, 3, 9, "a")
	testing.expect(t, ref_ok)
	ref_header, ref_err := output_validate(buf[:ref_len])
	testing.expect_value(t, ref_err, Output_Refusal.None)
	testing.expect_value(t, ref_header.status, Output_Status.Refused)
	testing.expect_value(t, ref_header.failure_kind, Failure_Kind.Cycle_Detected)
	testing.expect_value(t, ref_header.line, u32(3))
	testing.expect_value(t, ref_header.column, u32(9))
}
