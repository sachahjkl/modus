#+build !freestanding
package declaration_eval

import "core:fmt"
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

// bundle_validate refuses every damaged or hostile bundle before any lookup:
// overflow entry_count, unsorted entries, duplicates, unknown kind, bad flags,
// bad paths, and out-of-bounds offsets.
@(test)
bundle_refusals_at_the_border :: proc(t: ^testing.T) {
	// Empty and one byte below header size.
	testing.expect_value(t, bundle_validate(nil), Bundle_Refusal.Too_Small)
	small: [BUNDLE_HEADER_BYTES - 1]u8
	testing.expect_value(t, bundle_validate(small[:]), Bundle_Refusal.Too_Small)

	// Build a valid bundle (intentionally given unsorted input to verify bundle_write sorts).
	here := blake3.hash(transmute([]u8)string("tree"))
	decl_hash := blake3.hash(transmute([]u8)string("decl"))
	seed := u64(0xdeadbeefcafebabe)
	entries := [3]Bundle_Input_Entry {
		{kind = .Declaration_Hash, hash = decl_hash, content = "{ b = 2 }"},
		{kind = .File_Path, path = "z.lex", content = "{ z = 9 }"},
		{kind = .File_Path, path = "pins.lex", content = "{ a = 1 }"},
	}
	buf: [1024]u8
	written, write_err := bundle_write(buf[:], entries[:], true, here, seed)
	testing.expect_value(t, write_err, Bundle_Refusal.None)
	testing.expect_value(t, bundle_validate(buf[:written]), Bundle_Refusal.None)
	testing.expect_value(t, bundle_hash_seed(buf[:written]), seed)

	// Bad magic.
	bad := make([]u8, written, context.temp_allocator)
	copy(bad, buf[:written])
	bad[0] ~= 0xff
	testing.expect_value(t, bundle_validate(bad), Bundle_Refusal.Bad_Magic)

	// Bad version (v1 and v3 both refused).
	copy(bad, buf[:written])
	byte_order.write_u32_little_endian(bad, 4, BUNDLE_VERSION - 1)
	testing.expect_value(t, bundle_validate(bad), Bundle_Refusal.Bad_Version)
	copy(bad, buf[:written])
	byte_order.write_u32_little_endian(bad, 4, BUNDLE_VERSION + 1)
	testing.expect_value(t, bundle_validate(bad), Bundle_Refusal.Bad_Version)

	// Unknown flag bit.
	copy(bad, buf[:written])
	byte_order.write_u32_little_endian(bad, 12, 2)
	testing.expect_value(t, bundle_validate(bad), Bundle_Refusal.Bad_Flags)

	// Overflowing entry_count (max u32 and table larger than buffer).
	copy(bad, buf[:written])
	byte_order.write_u32_little_endian(bad, 8, max(u32))
	testing.expect_value(t, bundle_validate(bad), Bundle_Refusal.Entry_Out_Of_Bounds)
	copy(bad, buf[:written])
	byte_order.write_u32_little_endian(bad, 8, 100)
	testing.expect_value(t, bundle_validate(bad), Bundle_Refusal.Entry_Out_Of_Bounds)

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

	// Unsorted entries on wire refused cleanly (swap slot 0 and slot 1).
	copy(bad, buf[:written])
	tmp: [BUNDLE_ENTRY_BYTES]u8
	copy(tmp[:], bad[BUNDLE_HEADER_BYTES:BUNDLE_HEADER_BYTES + BUNDLE_ENTRY_BYTES])
	copy(bad[BUNDLE_HEADER_BYTES:BUNDLE_HEADER_BYTES + BUNDLE_ENTRY_BYTES], bad[BUNDLE_HEADER_BYTES + BUNDLE_ENTRY_BYTES:BUNDLE_HEADER_BYTES + 2 * BUNDLE_ENTRY_BYTES])
	copy(bad[BUNDLE_HEADER_BYTES + BUNDLE_ENTRY_BYTES:BUNDLE_HEADER_BYTES + 2 * BUNDLE_ENTRY_BYTES], tmp[:])
	testing.expect_value(t, bundle_validate(bad), Bundle_Refusal.Unsorted_Entries)

	// Duplicate entries on wire refused cleanly (overwrite slot 1 with slot 0).
	copy(bad, buf[:written])
	copy(bad[BUNDLE_HEADER_BYTES + BUNDLE_ENTRY_BYTES:BUNDLE_HEADER_BYTES + 2 * BUNDLE_ENTRY_BYTES], bad[BUNDLE_HEADER_BYTES:BUNDLE_HEADER_BYTES + BUNDLE_ENTRY_BYTES])
	testing.expect_value(t, bundle_validate(bad), Bundle_Refusal.Duplicate_Entry)

	// Duplicate entries passed to bundle_write refused cleanly.
	dup_buf: [512]u8
	dup_entries := [2]Bundle_Input_Entry {
		{kind = .File_Path, path = "a.lex", content = "1"},
		{kind = .File_Path, path = "a.lex", content = "2"},
	}
	_, dup_err := bundle_write(dup_buf[:], dup_entries[:])
	testing.expect_value(t, dup_err, Bundle_Refusal.Duplicate_Entry)

	// Buffer too small and bad path refused by bundle_write.
	_, short_err := bundle_write(dup_buf[:written - 1], entries[:], true, here, seed)
	testing.expect_value(t, short_err, Bundle_Refusal.Buffer_Too_Small)
	bad_path_entries := [1]Bundle_Input_Entry{{kind = .File_Path, path = "../escape.lex", content = "1"}}
	_, path_err := bundle_write(dup_buf[:], bad_path_entries[:])
	testing.expect_value(t, path_err, Bundle_Refusal.Bad_Path)

	// Valid O(log N) lookup round-trip.
	got_here, has_here := bundle_here_hash(buf[:written])
	testing.expect(t, has_here && got_here == here)
	pins_src, pins_ok := bundle_lookup_path(buf[:written], "pins.lex")
	testing.expect(t, pins_ok && pins_src == "{ a = 1 }")
	z_src, z_ok := bundle_lookup_path(buf[:written], "z.lex")
	testing.expect(t, z_ok && z_src == "{ z = 9 }")
	decl_src, decl_ok := bundle_lookup_hash(buf[:written], decl_hash)
	testing.expect(t, decl_ok && decl_src == "{ b = 2 }")
	_, missing_ok := bundle_lookup_path(buf[:written], "nope.lex")
	testing.expect(t, !missing_ok)
}

// Bundles beyond the former 64-entry cap (e.g. 512 entries: 256 paths + 256
// hashes) write, validate, and look up cleanly in O(log N).
@(test)
bundle_scales_past_former_64_entry_cap :: proc(t: ^testing.T) {
	N :: 256
	entries := make([]Bundle_Input_Entry, 2 * N, context.temp_allocator)
	for i in 0 ..< N {
		// Reverse order so heapsort exercises every comparison path.
		idx := N - 1 - i
		entries[i] = {
			kind    = .File_Path,
			path    = fmt.aprintf("pkg/mod_%04d.lex", idx, allocator = context.temp_allocator),
			content = fmt.aprintf("{{ id = %d }}", idx, allocator = context.temp_allocator),
		}
		tag := fmt.aprintf("hash_%04d", idx, allocator = context.temp_allocator)
		entries[N + i] = {
			kind    = .Declaration_Hash,
			hash    = blake3.hash(transmute([]u8)tag),
			content = fmt.aprintf("{{ h = %d }}", idx, allocator = context.temp_allocator),
		}
	}
	buf := make([]u8, 256 * 1024, context.temp_allocator)
	written, err := bundle_write(buf, entries, hash_seed = 42)
	testing.expect_value(t, err, Bundle_Refusal.None)
	testing.expect_value(t, bundle_validate(buf[:written]), Bundle_Refusal.None)
	for i in 0 ..< N {
		path := fmt.aprintf("pkg/mod_%04d.lex", i, allocator = context.temp_allocator)
		want := fmt.aprintf("{{ id = %d }}", i, allocator = context.temp_allocator)
		got, ok := bundle_lookup_path(buf[:written], path)
		testing.expectf(t, ok && got == want, "path %s: got %q (%v), want %q", path, got, ok, want)

		tag := fmt.aprintf("hash_%04d", i, allocator = context.temp_allocator)
		h := blake3.hash(transmute([]u8)tag)
		want_h := fmt.aprintf("{{ h = %d }}", i, allocator = context.temp_allocator)
		got_h, ok_h := bundle_lookup_hash(buf[:written], h)
		testing.expectf(t, ok_h && got_h == want_h, "hash %d: got %q (%v), want %q", i, got_h, ok_h, want_h)
	}
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

	// Integer_Unit round-trip and Bad_Integer_Unit refusal on wire.
	ubuf: [128]u8
	uw := output_writer_start(ubuf[:], {status = .Ok, failure_kind = .None, steps_taken = 1})
	output_write_integer_unit(&uw, 64, {kind = .Size, unit = 2}) // 64 MiB
	testing.expect(t, !uw.overflow)
	_, uerr := output_validate(ubuf[:uw.written])
	testing.expect_value(t, uerr, Output_Refusal.None)
	_, ur, hr := output_read_header(ubuf[:uw.written])
	testing.expect_value(t, hr, Output_Refusal.None)
	utag, tr := output_read_tag(&ur)
	testing.expect_value(t, tr, Output_Refusal.None)
	testing.expect_value(t, utag, Value_Tag.Integer_Unit)
	uv, uu, uref := output_read_integer_unit(&ur)
	testing.expect(t, uref == .None && uv == 64 && uu.kind == .Size && uu.unit == 2 && ur.offset == uw.written)

	// Corrupt unit byte past valid Size_Unit range -> Bad_Integer_Unit.
	ubuf[OUTPUT_HEADER_BYTES + 2] = 99
	_, bad_uerr := output_validate(ubuf[:uw.written])
	testing.expect_value(t, bad_uerr, Output_Refusal.Bad_Integer_Unit)

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
