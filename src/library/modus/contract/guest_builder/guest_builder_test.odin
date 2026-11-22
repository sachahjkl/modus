#+build !freestanding
package guest_builder

import "core:slice"
import "core:strings"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import op "modus:contract/operation"
import "modus:contract/tree_hash"

@(private = "file")
non_zero_hash :: proc(seed: u8) -> (result: blake3.Hash) {
	for &value, index in result {
		value = seed ~ u8(index + 1)
	}
	return result
}

// valid_spec_with_archive_size gives a valid spec whose initial archive has
// a nonzero hash and the size size.
@(private = "file")
valid_spec_with_archive_size :: proc(size: u64) -> (spec: Guest_Build_Spec) {
	spec = valid_spec()
	spec.initial_archive_hash = non_zero_hash(0x55)
	spec.initial_archive_size = size
	return spec
}

@(private = "file")
valid_spec :: proc() -> (spec: Guest_Build_Spec) {
	spec.kernel_hash = non_zero_hash(0x11)
	spec.root_image_hash = non_zero_hash(0x22)
	spec.frozen_epoch_seconds = 0
	spec.memory_pages = MIN_GUEST_MEMORY_PAGES
	spec.output_size_bound = 8192
	spec.max_guest_exits = 1024
	spec.allow_network = false
	spec.allow_real_clock = false
	spec.allow_writable_inputs = false
	_ = build_spec_set_command(&spec, "cargo build --release --offline")
	_ = build_spec_add_input(&spec, "src", non_zero_hash(0x33))
	return spec
}

// Border enum conversions must refuse every value that names no member,
// starting at the edges: 0, 1, the bound, one past the bound, and max(u64).
@(test)
enum_word_borders_refuse_unknown_values :: proc(t: ^testing.T) {
	// Guest_Build_State: 1..6 valid.
	for bad in ([]u64{0, 7, 255, max(u64)}) {
		_, ok := guest_build_state_of_word(bad)
		testing.expectf(t, !ok, "Guest_Build_State must refuse %d", bad)
	}
	for member in Guest_Build_State {
		got, ok := guest_build_state_of_word(u64(member))
		testing.expect(t, ok && got == member)
	}

	// Guest_Disk_Role: 1..3 valid.
	for bad in ([]u64{0, 4, 255, max(u64)}) {
		_, ok := guest_disk_role_of_word(bad)
		testing.expectf(t, !ok, "Guest_Disk_Role must refuse %d", bad)
	}
	for member in Guest_Disk_Role {
		got, ok := guest_disk_role_of_word(u64(member))
		testing.expect(t, ok && got == member)
	}

	// Guest_Builder_Refusal: 0..20 valid.
	for bad in ([]u64{21, 22, 255, max(u64)}) {
		_, ok := guest_builder_refusal_of_word(bad)
		testing.expectf(t, !ok, "Guest_Builder_Refusal must refuse %d", bad)
	}
	for member in Guest_Builder_Refusal {
		got, ok := guest_builder_refusal_of_word(u64(member))
		testing.expect(t, ok && got == member)
	}

	// Guest_Block_Operation: 1..3 valid.
	for bad in ([]u64{0, 4, 255, max(u64)}) {
		_, ok := guest_block_operation_of_word(bad)
		testing.expectf(t, !ok, "Guest_Block_Operation must refuse %d", bad)
	}
	for member in Guest_Block_Operation {
		got, ok := guest_block_operation_of_word(u64(member))
		testing.expect(t, ok && got == member)
	}

	// Guest_Io_Port and Guest_Rtc_Register borders.
	for bad in ([]u64{0, 1, 0x80, 0xFFFF, max(u64)}) {
		_, ok := guest_io_port_of_word(bad)
		testing.expectf(t, !ok, "Guest_Io_Port must refuse 0x%x", bad)
	}
	for member in Guest_Io_Port {
		got, ok := guest_io_port_of_word(u64(member))
		testing.expect(t, ok && got == member)
	}
	for bad in ([]u64{1, 3, 5, 0x33, 0xFF, max(u64)}) {
		_, ok := guest_rtc_register_of_word(bad)
		testing.expectf(t, !ok, "Guest_Rtc_Register must refuse 0x%x", bad)
	}
	for member in Guest_Rtc_Register {
		got, ok := guest_rtc_register_of_word(u64(member))
		testing.expect(t, ok && got == member)
	}
}

// Adversarial relative path validation: empty, traversal, absolute, trailing
// slash, double slash, backslash, control bytes, invalid UTF-8, over-length,
// segment past 64 bytes, and depth past MAX_PATH_DEPTH must all be refused.
@(test)
relative_path_validation_refuses_traversal_and_malformed_paths :: proc(t: ^testing.T) {
	bad_paths := [?]string{
		"",
		".",
		"..",
		"../escape",
		"a/../b",
		"a/..",
		"a/./b",
		"/leading/slash",
		"trailing/slash/",
		"double//slash",
		"windows\\path",
		"control\nnewline",
		"control\x00nul",
		"control\x1besc",
		strings.repeat("a", MAX_MOUNT_PATH_BYTES + 1, context.temp_allocator),
		strings.repeat("s", tree_hash.ENTRY_NAME_CAPACITY + 1, context.temp_allocator),
		"d1/d2/d3/d4/d5/d6/d7/d8/d9", // Depth 9 > MAX_PATH_DEPTH (8).
	}
	for candidate in bad_paths {
		testing.expectf(t, !validate_relative_path(transmute([]u8)candidate), "must refuse path %q", candidate)
	}
	bad_utf8_bytes := [4]u8{'b', 'a', 'd', 0xFF}
	testing.expect(t, !validate_relative_path(bad_utf8_bytes[:]))

	good_paths := [?]string{
		"a",
		"bin/tool",
		"d1/d2/d3/d4/d5/d6/d7/d8", // Exact depth bound 8.
		strings.repeat("x", tree_hash.ENTRY_NAME_CAPACITY, context.temp_allocator),
	}
	for candidate in good_paths {
		testing.expectf(t, validate_relative_path(transmute([]u8)candidate), "must accept valid path %q", candidate)
	}
}

// Every single member of Guest_Builder_Refusal is triggered and verified.
@(test)
every_refusal_member_is_triggered :: proc(t: ^testing.T) {
	seen: bit_set[Guest_Builder_Refusal]
	record :: proc(t: ^testing.T, seen: ^bit_set[Guest_Builder_Refusal], got, expected: Guest_Builder_Refusal) {
		testing.expect_value(t, got, expected)
		seen^ += {got}
	}

	// 0: None
	base := valid_spec()
	record(t, &seen, validate_build_spec(&base), .None)

	// 1: Zero_Kernel_Hash
	s := valid_spec()
	s.kernel_hash = {}
	record(t, &seen, validate_build_spec(&s), .Zero_Kernel_Hash)

	// 2: Zero_Root_Image_Hash
	s = valid_spec()
	s.root_image_hash = {}
	record(t, &seen, validate_build_spec(&s), .Zero_Root_Image_Hash)

	// 3: Empty_Command
	s = valid_spec()
	s.command_length = 0
	s.command = {}
	record(t, &seen, validate_build_spec(&s), .Empty_Command)
	testing.expect_value(t, build_spec_set_command(&s, ""), Guest_Builder_Refusal.Empty_Command)

	// 4: Command_Too_Long
	s = valid_spec()
	s.command_length = MAX_COMMAND_BYTES + 1
	record(t, &seen, validate_build_spec(&s), .Command_Too_Long)
	too_long_cmd := strings.repeat("c", MAX_COMMAND_BYTES + 1, context.temp_allocator)
	testing.expect_value(t, build_spec_set_command(&s, too_long_cmd), Guest_Builder_Refusal.Command_Too_Long)

	// 5: Invalid_Command_Text (control byte, invalid UTF-8, and non-zero padding)
	s = valid_spec()
	testing.expect_value(t, build_spec_set_command(&s, "echo\nhi"), Guest_Builder_Refusal.Invalid_Command_Text)
	s.command[0] = 0xFF
	record(t, &seen, validate_build_spec(&s), .Invalid_Command_Text)
	s = valid_spec()
	s.command[s.command_length] = 'x' // Non-zero padding past command_length.
	testing.expect_value(t, validate_build_spec(&s), Guest_Builder_Refusal.Invalid_Command_Text)

	// 6: Too_Many_Inputs
	s = valid_spec()
	s.input_count = MAX_INPUT_MOUNTS + 1
	record(t, &seen, validate_build_spec(&s), .Too_Many_Inputs)

	// 7: Duplicate_Input_Mount (exact duplicate and file/dir prefix conflict)
	s = valid_spec()
	record(t, &seen, build_spec_add_input(&s, "src", non_zero_hash(0x44)), .Duplicate_Input_Mount)
	testing.expect_value(t, build_spec_add_input(&s, "src/sub", non_zero_hash(0x45)), Guest_Builder_Refusal.Duplicate_Input_Mount)

	// 8: Invalid_Mount_Path (traversal "../escape")
	s = valid_spec()
	record(t, &seen, build_spec_add_input(&s, "../escape", non_zero_hash(0x44)), .Invalid_Mount_Path)

	// 9: Network_Forbidden
	s = valid_spec()
	s.allow_network = true
	record(t, &seen, validate_build_spec(&s), .Network_Forbidden)

	// 10: Real_Clock_Forbidden
	s = valid_spec()
	s.allow_real_clock = true
	record(t, &seen, validate_build_spec(&s), .Real_Clock_Forbidden)

	// 11: Writable_Input_Forbidden
	s = valid_spec()
	s.allow_writable_inputs = true
	record(t, &seen, validate_build_spec(&s), .Writable_Input_Forbidden)

	// 12: Memory_Too_Small (edges 0, 1, MIN-1)
	for pages in ([]u64{0, 1, MIN_GUEST_MEMORY_PAGES - 1}) {
		s = valid_spec()
		s.memory_pages = pages
		record(t, &seen, validate_build_spec(&s), .Memory_Too_Small)
	}

	// 13: Memory_Past_Bound (edges MAX+1, max(u64))
	for pages in ([]u64{MAX_GUEST_MEMORY_PAGES + 1, max(u64)}) {
		s = valid_spec()
		s.memory_pages = pages
		record(t, &seen, validate_build_spec(&s), .Memory_Past_Bound)
	}

	// 14: Output_Too_Large (0, MAX+1, max(u64))
	for bound in ([]u64{0, MAX_OUTPUT_DISK_BYTES + 1, max(u64)}) {
		s = valid_spec()
		s.output_size_bound = bound
		record(t, &seen, validate_build_spec(&s), .Output_Too_Large)
	}

	// 15: Malformed_Disk_Image
	corrupt_disk := [64]u8{0 = 'B', 1 = 'A', 2 = 'D', 3 = 'M', 4 = 'A', 5 = 'G', 6 = 'I', 7 = 'C'}
	workspace := new(Disk_Unpack_Workspace, context.temp_allocator)
	tree_out: [4096]u8
	_, bad_hash, bad_refusal := unpack_output_disk(corrupt_disk[:], 4096, workspace, tree_out[:])
	record(t, &seen, bad_refusal, .Malformed_Disk_Image)
	testing.expect(t, hash_is_zero(bad_hash))

	// 16: Nonzero_Guest_Exit
	runner := new(Guest_Sandbox_Runner, context.temp_allocator)
	out_disk: [8192]u8
	s = valid_spec()
	testing.expect_value(t, runner_prepare(runner, &s, nil, nil, out_disk[:]), Guest_Builder_Refusal.None)
	testing.expect_value(t, runner_start(runner), Guest_Builder_Refusal.None)
	regs := op.Guest_Registers{rip = 0x1000}
	keep := runner_handle_exit(runner, &regs, .Port_Write, u64(Guest_Io_Port.Build_Exit_Status), 4, 2, 0x1004)
	testing.expect(t, !keep)
	exit_hash, exit_written, exit_refusal := runner_finish(runner, workspace, tree_out[:])
	record(t, &seen, exit_refusal, .Nonzero_Guest_Exit)
	testing.expect_value(t, exit_written, 0)
	testing.expect(t, hash_is_zero(exit_hash))
	testing.expect_value(t, runner.state, Guest_Build_State.Failed)

	// 17: Output_Extraction_Failed (valid output disk, caller tree buffer too small)
	valid_out: [4096]u8
	files := [?]Disk_File_Input{
		{path = "result.bin", content = transmute([]u8)string("hello")},
	}
	_, pack_ref := pack_disk_image(.Output_Writable, files[:], 0, valid_out[:])
	testing.expect_value(t, pack_ref, Guest_Builder_Refusal.None)
	tiny_tree_out: [8]u8 = {0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA}
	tiny_written, tiny_hash, tiny_ref := unpack_output_disk(valid_out[:], 4096, workspace, tiny_tree_out[:])
	record(t, &seen, tiny_ref, .Output_Extraction_Failed)
	testing.expect_value(t, tiny_written, 0)
	testing.expect(t, hash_is_zero(tiny_hash))
	// Refusal must leave output buffer untouched.
	for b in tiny_tree_out {
		testing.expect_value(t, b, u8(0xAA))
	}

	// 18: Initial_Archive_Too_Large (past the bound, at the memory of the
	// guest, and max(u64))
	archive := []u8{'0', '7', '0', '7', '0', '1'}
	for size in ([]u64{MAX_INITIAL_ARCHIVE_BYTES + 1, MIN_GUEST_MEMORY_PAGES * GUEST_PAGE_BYTES, max(u64)}) {
		s = valid_spec()
		_ = build_spec_set_initial_archive(&s, archive)
		s.initial_archive_size = size
		record(t, &seen, validate_build_spec(&s), .Initial_Archive_Too_Large)
	}
	s = valid_spec()
	s.memory_pages = MAX_GUEST_MEMORY_PAGES
	_ = build_spec_set_initial_archive(&s, archive)
	s.initial_archive_size = MAX_INITIAL_ARCHIVE_BYTES
	testing.expect_value(t, validate_build_spec(&s), Guest_Builder_Refusal.None)
	s = valid_spec_with_archive_size(MIN_GUEST_MEMORY_PAGES * GUEST_PAGE_BYTES - 1)
	testing.expect_value(t, validate_build_spec(&s), Guest_Builder_Refusal.None)

	// 19: Initial_Archive_Size_Invalid (a size with no hash, a hash with no
	// size, an empty archive, bytes whose count is not the size, bytes that
	// the spec does not name)
	s = valid_spec()
	s.initial_archive_size = 1
	record(t, &seen, validate_build_spec(&s), .Initial_Archive_Size_Invalid)
	s = valid_spec()
	_ = build_spec_set_initial_archive(&s, archive)
	s.initial_archive_size = 0
	testing.expect_value(t, validate_build_spec(&s), Guest_Builder_Refusal.Initial_Archive_Size_Invalid)
	s = valid_spec()
	testing.expect_value(t, build_spec_set_initial_archive(&s, nil), Guest_Builder_Refusal.Initial_Archive_Size_Invalid)
	testing.expect(t, hash_is_zero(s.initial_archive_hash) && s.initial_archive_size == 0)
	testing.expect_value(t, initial_archive_check(&s, archive), Guest_Builder_Refusal.Initial_Archive_Size_Invalid)
	testing.expect_value(t, initial_archive_check(&s, nil), Guest_Builder_Refusal.None)
	_ = build_spec_set_initial_archive(&s, archive)
	testing.expect_value(t, initial_archive_check(&s, archive[:len(archive) - 1]), Guest_Builder_Refusal.Initial_Archive_Size_Invalid)
	testing.expect_value(t, initial_archive_check(&s, nil), Guest_Builder_Refusal.Initial_Archive_Size_Invalid)
	testing.expect_value(t, initial_archive_check(&s, archive), Guest_Builder_Refusal.None)

	// 20: Initial_Archive_Mismatch (one changed byte of the same size)
	tampered := [6]u8{'0', '7', '0', '7', '0', '2'}
	record(t, &seen, initial_archive_check(&s, tampered[:]), .Initial_Archive_Mismatch)

	// Confirm every single enum member of Guest_Builder_Refusal was exercised.
	for member in Guest_Builder_Refusal {
		testing.expectf(t, member in seen, "refusal member %v was not exercised", member)
	}
}

// MODGBD1 pack/unpack adversarial tests: corrupt magic, bad version, bad role,
// read-only role passed as output, unknown flags, non-zero reserved bytes,
// extent past bound, integer overflow extent, overlapping extents, flipped
// payload hash, unsorted/duplicate/traversal paths, and file/dir prefix
// conflict hidden behind '-' ('a', 'a-b', 'a/file').
@(test)
disk_image_refuses_corruption_traversal_and_prefix_conflicts :: proc(t: ^testing.T) {
	workspace := new(Disk_Unpack_Workspace, context.temp_allocator)
	tree_out: [4096]u8

	// Pack refuses unsorted paths, duplicate paths, traversal, and hidden
	// file/directory prefix conflicts ("a", "a-b", "a/file") without touching
	// the destination buffer.
	sentinel: [2048]u8
	for &b in sentinel {
		b = 0xCC
	}

	bad_file_lists := [?][]Disk_File_Input{
		// Unsorted
		{{path = "b.txt", content = nil}, {path = "a.txt", content = nil}},
		// Duplicate
		{{path = "a.txt", content = nil}, {path = "a.txt", content = nil}},
		// Traversal
		{{path = "../escape", content = nil}},
		// Direct file/dir conflict
		{{path = "dir", content = nil}, {path = "dir/file", content = nil}},
		// Hidden file/dir conflict separated by '-' (ASCII '-' < '/')
		{{path = "a", content = nil}, {path = "a-b", content = nil}, {path = "a/file", content = nil}},
	}
	for list in bad_file_lists {
		buf := sentinel
		written, ref := pack_input_disk(list, 0, buf[:])
		testing.expect(t, ref != .None && written == 0)
		testing.expect(t, slice.equal(buf[:], sentinel[:]))
	}

	// Build a valid output disk image to mutate byte-by-byte in adversarial checks.
	good_files := [?]Disk_File_Input{
		{path = "alpha.bin", content = transmute([]u8)string("first payload")},
		{path = "beta.bin", content = transmute([]u8)string("second payload")},
	}
	good_disk: [4096]u8
	good_len, good_ref := pack_disk_image(.Output_Writable, good_files[:], 12345, good_disk[:])
	testing.expect_value(t, good_ref, Guest_Builder_Refusal.None)
	testing.expect(t, good_len > DISK_HEADER_SIZE)

	expect_corrupt :: proc(t: ^testing.T, img: []u8, bound: u64, expected: Guest_Builder_Refusal, ws: ^Disk_Unpack_Workspace, out: []u8, label: string) {
		for &b in out {
			b = 0x55
		}
		written, hash, ref := unpack_output_disk(img, bound, ws, out)
		testing.expectf(t, ref == expected, "%s: expected %v, got %v", label, expected, ref)
		testing.expectf(t, written == 0 && hash_is_zero(hash), "%s: must return zero hash and 0 bytes", label)
		for b in out {
			testing.expectf(t, b == 0x55, "%s: output buffer modified on refusal", label)
		}
	}

	// 1. Corrupt magic.
	mut := good_disk
	mut[0] = 'X'
	expect_corrupt(t, mut[:], 4096, .Malformed_Disk_Image, workspace, tree_out[:], "corrupt magic")

	// 2. Bad version.
	mut = good_disk
	mut[7] = 2
	expect_corrupt(t, mut[:], 4096, .Malformed_Disk_Image, workspace, tree_out[:], "bad version")

	// 3. Invalid role word (99) and wrong role (Inputs_Read_Only).
	mut = good_disk
	byte_order.write_u32_little_endian(mut[:], 8, 99)
	expect_corrupt(t, mut[:], 4096, .Malformed_Disk_Image, workspace, tree_out[:], "unknown role")

	ro_disk: [4096]u8
	_, ro_ref := pack_input_disk(good_files[:], 12345, ro_disk[:])
	testing.expect_value(t, ro_ref, Guest_Builder_Refusal.None)
	expect_corrupt(t, ro_disk[:], 4096, .Malformed_Disk_Image, workspace, tree_out[:], "read-only disk as output")

	// 4. Unknown flag bit and read-only flag set on Output_Writable.
	mut = good_disk
	byte_order.write_u32_little_endian(mut[:], 12, 2)
	expect_corrupt(t, mut[:], 4096, .Malformed_Disk_Image, workspace, tree_out[:], "unknown flag bit")
	mut = good_disk
	byte_order.write_u32_little_endian(mut[:], 12, DISK_FLAG_READ_ONLY)
	expect_corrupt(t, mut[:], 4096, .Malformed_Disk_Image, workspace, tree_out[:], "ro flag on output")

	// 5. Non-zero reserved header byte.
	mut = good_disk
	mut[45] = 1
	expect_corrupt(t, mut[:], 4096, .Malformed_Disk_Image, workspace, tree_out[:], "reserved header pad")

	// 6. Declared total_image_bytes past output_size_bound -> Output_Too_Large.
	expect_corrupt(t, good_disk[:], u64(good_len - 1), .Output_Too_Large, workspace, tree_out[:], "past output bound")

	// 7. Trailing non-zero byte past total_image_bytes.
	mut = good_disk
	mut[good_len] = 0x01
	expect_corrupt(t, mut[:], 4096, .Malformed_Disk_Image, workspace, tree_out[:], "trailing garbage")

	// 8. Truncated image.
	expect_corrupt(t, good_disk[:good_len - 1], 4096, .Malformed_Disk_Image, workspace, tree_out[:], "truncated image")

	// 9. Out-of-bounds / integer-overflow extent.
	mut = good_disk
	byte_order.write_u64_little_endian(mut[:], DISK_HEADER_SIZE + 128, max(u64) - 4)
	byte_order.write_u64_little_endian(mut[:], DISK_HEADER_SIZE + 136, 16)
	expect_corrupt(t, mut[:], 4096, .Malformed_Disk_Image, workspace, tree_out[:], "overflow extent")

	// 10. Overlapping extents (second entry points into first entry's data).
	mut = good_disk
	first_offset := byte_order.read_u64_little_endian(mut[:], DISK_HEADER_SIZE + 128)
	byte_order.write_u64_little_endian(mut[:], DISK_HEADER_SIZE + DISK_ENTRY_SIZE + 128, first_offset)
	expect_corrupt(t, mut[:], 4096, .Malformed_Disk_Image, workspace, tree_out[:], "overlapping extent")

	// 11. Single bit flipped in payload -> content BLAKE3 mismatch.
	mut = good_disk
	mut[first_offset] ~= 0x01
	expect_corrupt(t, mut[:], 4096, .Malformed_Disk_Image, workspace, tree_out[:], "payload bit flip")

	// 12. Embedded traversal path "../escape" forged directly in raw directory bytes.
	mut = good_disk
	forged := "../escape"
	byte_order.write_u16_little_endian(mut[:], DISK_HEADER_SIZE, u16(len(forged)))
	copy(mut[DISK_HEADER_SIZE + 4:][:MAX_MOUNT_PATH_BYTES], make([]u8, MAX_MOUNT_PATH_BYTES, context.temp_allocator))
	copy(mut[DISK_HEADER_SIZE + 4:][:len(forged)], transmute([]u8)forged)
	expect_corrupt(t, mut[:], 4096, .Malformed_Disk_Image, workspace, tree_out[:], "forged traversal path")
}

// Nested directory unpack must produce the exact domain-separated Merkle
// tree_hash matching hand-constructed tree_hash.tree_encode + tree_hash.tree_hash,
// including directories whose names sort before hyphenated siblings ("a" < "a-b").
@(test)
nested_output_disk_matches_canonical_tree_hash :: proc(t: ^testing.T) {
	workspace := new(Disk_Unpack_Workspace, context.temp_allocator)
	out_disk: [8192]u8
	// Note full-path sort order: "a-b" ('-') < "a.txt" ('.') < "a/x" ('/') < "a/y" ('/') < "a0" ('0').
	// In canonical MODTREE1 root order: "a" (Tree) < "a-b" < "a.txt" < "a0".
	p_ab := transmute([]u8)string("hyphenated")
	p_atxt := transmute([]u8)string("dotted")
	p_ax := transmute([]u8)string("child-x")
	p_ay := transmute([]u8)string("child-y")
	p_a0 := transmute([]u8)string("zero-suffix")
	files := [?]Disk_File_Input{
		{path = "a-b", content = p_ab},
		{path = "a.txt", content = p_atxt},
		{path = "a/x", content = p_ax},
		{path = "a/y", content = p_ay},
		{path = "a0", content = p_a0},
	}
	_, pack_ref := pack_disk_image(.Output_Writable, files[:], 0, out_disk[:])
	testing.expect_value(t, pack_ref, Guest_Builder_Refusal.None)

	tree_out: [4096]u8
	written, got_hash, unpack_ref := unpack_output_disk(out_disk[:], 8192, workspace, tree_out[:])
	testing.expect_value(t, unpack_ref, Guest_Builder_Refusal.None)
	testing.expect(t, written > tree_hash.HEADER_SIZE)

	// Independently build the expected canonical child tree "a" and root tree.
	ex_x, _ := tree_hash.tree_entry_make(.Object, "x", blake3.hash(p_ax))
	ex_y, _ := tree_hash.tree_entry_make(.Object, "y", blake3.hash(p_ay))
	child_buf: [512]u8
	child_len, child_enc_ref := tree_hash.tree_encode([]tree_hash.Tree_Entry{ex_x, ex_y}, child_buf[:])
	testing.expect_value(t, child_enc_ref, tree_hash.Tree_Refusal.None)
	child_hash, child_h_ref := tree_hash.tree_hash(child_buf[:child_len])
	testing.expect_value(t, child_h_ref, tree_hash.Tree_Refusal.None)

	er_a, _ := tree_hash.tree_entry_make(.Tree, "a", child_hash)
	er_ab, _ := tree_hash.tree_entry_make(.Object, "a-b", blake3.hash(p_ab))
	er_atxt, _ := tree_hash.tree_entry_make(.Object, "a.txt", blake3.hash(p_atxt))
	er_a0, _ := tree_hash.tree_entry_make(.Object, "a0", blake3.hash(p_a0))
	expected_root_buf: [1024]u8
	expected_root_len, root_enc_ref := tree_hash.tree_encode([]tree_hash.Tree_Entry{er_a, er_ab, er_atxt, er_a0}, expected_root_buf[:])
	testing.expect_value(t, root_enc_ref, tree_hash.Tree_Refusal.None)
	expected_root_hash, root_h_ref := tree_hash.tree_hash(expected_root_buf[:expected_root_len])
	testing.expect_value(t, root_h_ref, tree_hash.Tree_Refusal.None)

	testing.expect_value(t, written, expected_root_len)
	testing.expect(t, slice.equal(tree_out[:written], expected_root_buf[:expected_root_len]))
	testing.expect_value(t, got_hash, expected_root_hash)
}

// Read-only disk protection: writes to Inputs_Read_Only and Root_Image return
// Io_Error, leave disk bytes untouched, record a sandbox violation, and cause
// runner_finish to refuse output with a zero output_tree_hash.
@(test)
read_only_disk_writes_are_refused_and_recorded :: proc(t: ^testing.T) {
	spec := valid_spec()
	root_disk := [512]u8{}
	for &b, i in root_disk {
		b = u8(i)
	}
	root_snapshot := root_disk

	input_files := [?]Disk_File_Input{
		{path = "src/main.rs", content = transmute([]u8)string("fn main() {}")},
	}
	input_disk: [2048]u8
	_, pack_ref := pack_input_disk(input_files[:], 0, input_disk[:])
	testing.expect_value(t, pack_ref, Guest_Builder_Refusal.None)
	input_snapshot := input_disk

	output_disk: [8192]u8
	runner := new(Guest_Sandbox_Runner, context.temp_allocator)
	testing.expect_value(t, runner_prepare(runner, &spec, root_disk[:], input_disk[:], output_disk[:]), Guest_Builder_Refusal.None)
	testing.expect_value(t, runner_start(runner), Guest_Builder_Refusal.None)

	// Reading Inputs_Read_Only succeeds.
	read_buf: [7]u8
	testing.expect_value(t, runner_handle_block_request(runner, .Inputs_Read_Only, .Read, 0, read_buf[:]), Guest_Block_Status.Ok)
	testing.expect_value(t, string(read_buf[:]), "MODGBD1")

	// Writing Inputs_Read_Only is refused with Io_Error and leaves input_disk unchanged.
	hostile := [4]u8{0xDE, 0xAD, 0xBE, 0xEF}
	testing.expect_value(t, runner_handle_block_request(runner, .Inputs_Read_Only, .Write, 0, hostile[:]), Guest_Block_Status.Io_Error)
	testing.expect(t, slice.equal(input_disk[:], input_snapshot[:]))
	testing.expect_value(t, runner.sandbox_violations, u64(1))
	testing.expect_value(t, runner.last_violation, Sandbox_Violation_Kind.Read_Only_Disk_Write)

	// Writing Root_Image is also refused with Io_Error and leaves root_disk unchanged.
	testing.expect_value(t, runner_handle_block_request(runner, .Root_Image, .Write, 16, hostile[:]), Guest_Block_Status.Io_Error)
	testing.expect(t, slice.equal(root_disk[:], root_snapshot[:]))
	testing.expect_value(t, runner.sandbox_violations, u64(2))

	// Even if the guest writes a valid output disk and exits 0, the recorded
	// sandbox violation causes runner_finish to refuse output with zero hash.
	out_files := [?]Disk_File_Input{{path = "out.bin", content = transmute([]u8)string("ok")}}
	packed_out: [1024]u8
	packed_len, _ := pack_disk_image(.Output_Writable, out_files[:], 0, packed_out[:])
	testing.expect_value(t, runner_handle_block_request(runner, .Output_Writable, .Write, 0, packed_out[:packed_len]), Guest_Block_Status.Ok)

	regs := op.Guest_Registers{rip = 0x1000}
	_ = runner_handle_exit(runner, &regs, .Port_Write, u64(Guest_Io_Port.Build_Exit_Status), 4, 0, 0x1004)
	workspace := new(Disk_Unpack_Workspace, context.temp_allocator)
	tree_out: [4096]u8
	hash, written, finish_ref := runner_finish(runner, workspace, tree_out[:])
	testing.expect_value(t, finish_ref, Guest_Builder_Refusal.Writable_Input_Forbidden)
	testing.expect_value(t, runner.state, Guest_Build_State.Refused)
	testing.expect_value(t, written, 0)
	testing.expect(t, hash_is_zero(hash))
}

// Network access is refused both via direct device request and via guest I/O
// port trap, leaving state Refused and output_tree_hash zero.
@(test)
network_device_requests_and_port_traps_are_refused :: proc(t: ^testing.T) {
	spec := valid_spec()
	output_disk: [8192]u8
	runner := new(Guest_Sandbox_Runner, context.temp_allocator)
	testing.expect_value(t, runner_prepare(runner, &spec, nil, nil, output_disk[:]), Guest_Builder_Refusal.None)
	testing.expect_value(t, runner_start(runner), Guest_Builder_Refusal.None)

	// Direct device request refusal.
	testing.expect_value(t, runner_request_network_device(runner), Guest_Builder_Refusal.Network_Forbidden)
	testing.expect_value(t, runner.sandbox_violations, u64(1))
	testing.expect_value(t, runner.last_violation, Sandbox_Violation_Kind.Network_Access_Attempt)

	// Port trap refusal stops the guest immediately.
	runner2 := new(Guest_Sandbox_Runner, context.temp_allocator)
	testing.expect_value(t, runner_prepare(runner2, &spec, nil, nil, output_disk[:]), Guest_Builder_Refusal.None)
	testing.expect_value(t, runner_start(runner2), Guest_Builder_Refusal.None)
	regs := op.Guest_Registers{rip = 0x1000}
	keep := runner_handle_exit(runner2, &regs, .Port_Read, u64(Guest_Io_Port.Network_Device_Trap), 4, 0, 0x1002)
	testing.expect(t, !keep)
	testing.expect_value(t, runner2.state, Guest_Build_State.Refused)
	testing.expect_value(t, runner2.refusal, Guest_Builder_Refusal.Network_Forbidden)

	workspace := new(Disk_Unpack_Workspace, context.temp_allocator)
	tree_out: [4096]u8
	hash, written, ref := runner_finish(runner2, workspace, tree_out[:])
	testing.expect_value(t, ref, Guest_Builder_Refusal.Network_Forbidden)
	testing.expect_value(t, written, 0)
	testing.expect(t, hash_is_zero(hash))
}

// Frozen clock and CMOS/RTC reads always reflect spec.frozen_epoch_seconds
// (default 0 -> 1970-01-01T00:00:00Z, custom epoch -> exact UTC date) and
// ignore guest writes attempting to alter RTC registers.
@(test)
frozen_clock_and_rtc_reads_are_deterministic :: proc(t: ^testing.T) {
	// Epoch 0: 1970-01-01 00:00:00 UTC (Thursday = weekday 5).
	d0 := frozen_utc_date_from_epoch(0)
	testing.expect_value(t, d0.year, u16(1970))
	testing.expect_value(t, d0.month, u8(1))
	testing.expect_value(t, d0.day, u8(1))
	testing.expect_value(t, d0.hour, u8(0))
	testing.expect_value(t, d0.minute, u8(0))
	testing.expect_value(t, d0.second, u8(0))

	// Custom frozen timestamp: 1_700_000_000 = 2023-11-14 22:13:20 UTC.
	spec := valid_spec()
	spec.frozen_epoch_seconds = 0x0000_0001_6553_F100 // Tests both low and high 32-bit halves.
	spec_custom := valid_spec()
	spec_custom.frozen_epoch_seconds = 1_700_000_000
	d1 := frozen_utc_date_from_epoch(spec_custom.frozen_epoch_seconds)
	testing.expect_value(t, d1.year, u16(2023))
	testing.expect_value(t, d1.month, u8(11))
	testing.expect_value(t, d1.day, u8(14))
	testing.expect_value(t, d1.hour, u8(22))
	testing.expect_value(t, d1.minute, u8(13))
	testing.expect_value(t, d1.second, u8(20))

	out_disk: [8192]u8
	runner := new(Guest_Sandbox_Runner, context.temp_allocator)
	testing.expect_value(t, runner_prepare(runner, &spec, nil, nil, out_disk[:]), Guest_Builder_Refusal.None)
	testing.expect_value(t, runner_start(runner), Guest_Builder_Refusal.None)
	testing.expect_value(t, runner_read_frozen_clock(runner), spec.frozen_epoch_seconds)

	// Read 64-bit frozen clock via I/O ports.
	regs := op.Guest_Registers{rip = 0x1000}
	testing.expect(t, runner_handle_exit(runner, &regs, .Port_Read, u64(Guest_Io_Port.Frozen_Clock_Low), 4, 0, 0x1002))
	low := u32(regs.rax)
	testing.expect(t, runner_handle_exit(runner, &regs, .Port_Read, u64(Guest_Io_Port.Frozen_Clock_High), 4, 0, 0x1004))
	high := u32(regs.rax)
	testing.expect_value(t, (u64(high) << 32) | u64(low), spec.frozen_epoch_seconds)

	// Read CMOS/RTC year and century on custom epoch, and verify guest writes
	// to Rtc_Data cannot mutate frozen time.
	runner_rtc := new(Guest_Sandbox_Runner, context.temp_allocator)
	testing.expect_value(t, runner_prepare(runner_rtc, &spec_custom, nil, nil, out_disk[:]), Guest_Builder_Refusal.None)
	testing.expect_value(t, runner_start(runner_rtc), Guest_Builder_Refusal.None)
	testing.expect(t, runner_handle_exit(runner_rtc, &regs, .Port_Write, u64(Guest_Io_Port.Rtc_Index), 1, u64(Guest_Rtc_Register.Year), 0x1006))
	testing.expect(t, runner_handle_exit(runner_rtc, &regs, .Port_Write, u64(Guest_Io_Port.Rtc_Data), 1, 0x99, 0x1008))
	testing.expect(t, runner_handle_exit(runner_rtc, &regs, .Port_Read, u64(Guest_Io_Port.Rtc_Data), 1, 0, 0x100A))
	testing.expect_value(t, u8(regs.rax), u8(0x23)) // BCD 23 for 2023.
	testing.expect(t, runner_handle_exit(runner_rtc, &regs, .Port_Write, u64(Guest_Io_Port.Rtc_Index), 1, u64(Guest_Rtc_Register.Century), 0x100C))
	testing.expect(t, runner_handle_exit(runner_rtc, &regs, .Port_Read, u64(Guest_Io_Port.Rtc_Data), 1, 0, 0x100E))
	testing.expect_value(t, u8(regs.rax), u8(0x20)) // BCD 20 for 2023.
}

// Guest timeout when max_guest_exits is reached transitions to Timed_Out and
// extracts nothing with a zero output_tree_hash.
@(test)
guest_exit_bound_transitions_to_timed_out :: proc(t: ^testing.T) {
	spec := valid_spec()
	spec.max_guest_exits = 3
	out_disk: [8192]u8
	runner := new(Guest_Sandbox_Runner, context.temp_allocator)
	testing.expect_value(t, runner_prepare(runner, &spec, nil, nil, out_disk[:]), Guest_Builder_Refusal.None)
	testing.expect_value(t, runner_start(runner), Guest_Builder_Refusal.None)

	regs := op.Guest_Registers{rip = 0x1000}
	testing.expect(t, runner_handle_exit(runner, &regs, .Cpuid, 0, 0, 0, 0x1002))
	// Exits Interrupted come from the host timer: past the bound, uncounted.
	for _ in 0 ..< 1001 {
		testing.expect(t, runner_handle_exit(runner, &regs, .Interrupted, 0, 0, 0, 0x1002))
	}
	testing.expect_value(t, runner.guest_exits_handled, u64(1))
	testing.expect(t, runner_handle_exit(runner, &regs, .Cpuid, 0, 0, 0, 0x1004))
	testing.expect(t, runner_handle_exit(runner, &regs, .Cpuid, 0, 0, 0, 0x1006))
	// Fourth exit of the guest hits the bound of 3 and stops with Timed_Out.
	testing.expect(t, !runner_handle_exit(runner, &regs, .Cpuid, 0, 0, 0, 0x1008))
	testing.expect_value(t, runner.state, Guest_Build_State.Timed_Out)
	testing.expect_value(t, runner.guest_exits_handled, u64(3))

	workspace := new(Disk_Unpack_Workspace, context.temp_allocator)
	tree_out: [4096]u8
	hash, written, ref := runner_finish(runner, workspace, tree_out[:])
	testing.expect(t, ref != .None)
	testing.expect_value(t, written, 0)
	testing.expect(t, hash_is_zero(hash))
}

// Two completely independent runs with identical spec, inputs, and guest
// execution produce bit-for-bit identical canonical MODTREE1 bytes and
// identical domain-separated output tree_hash.
@(test)
two_independent_runs_produce_identical_output_tree_hash :: proc(t: ^testing.T) {
	run_once :: proc(t: ^testing.T, stale_pattern: u8) -> (tree_hash_out: blake3.Hash, tree_bytes: []u8) {
		spec := valid_spec()
		spec.frozen_epoch_seconds = 1_700_000_000

		// Pack read-only input disk from immutable source files.
		input_files := [?]Disk_File_Input{
			{path = "src/lib.odin", content = transmute([]u8)string("package demo")},
			{path = "src/main.odin", content = transmute([]u8)string("main :: proc() {}")},
		}
		input_disk: [4096]u8
		_, in_ref := pack_input_disk(input_files[:], spec.frozen_epoch_seconds, input_disk[:])
		testing.expect_value(t, in_ref, Guest_Builder_Refusal.None)

		// Fill output disk with distinct stale bytes to prove runner_prepare zeroes it.
		output_disk: [8192]u8
		for &b in output_disk {
			b = stale_pattern
		}

		runner := new(Guest_Sandbox_Runner, context.temp_allocator)
		testing.expect_value(t, runner_prepare(runner, &spec, nil, input_disk[:], output_disk[:]), Guest_Builder_Refusal.None)
		testing.expect_value(t, runner_start(runner), Guest_Builder_Refusal.None)

		// Simulate deterministic guest execution: read CPUID, read frozen clock,
		// read input disk header, write deterministic output MODGBD1 image, exit 0.
		regs := op.Guest_Registers{rax = 0, rip = 0x1000}
		testing.expect(t, runner_handle_exit(runner, &regs, .Cpuid, 0, 0, 0, 0x1002))
		testing.expect(t, runner_handle_exit(runner, &regs, .Port_Read, u64(Guest_Io_Port.Frozen_Clock_Low), 4, 0, 0x1004))
		clock_low := u32(regs.rax)

		in_header: [DISK_HEADER_SIZE]u8
		testing.expect_value(t, runner_handle_block_request(runner, .Inputs_Read_Only, .Read, 0, in_header[:]), Guest_Block_Status.Ok)

		artifact_bytes: [40]u8
		h := blake3.hash(in_header[:])
		copy(artifact_bytes[0:32], h[:])
		byte_order.write_u32_little_endian(artifact_bytes[:], 32, clock_low)
		byte_order.write_u32_little_endian(artifact_bytes[:], 36, u32(regs.rbx))

		out_files := [?]Disk_File_Input{
			{path = "bin/output.module", content = artifact_bytes[:]},
			{path = "manifest.txt", content = transmute([]u8)string("deterministic")},
		}
		guest_image: [4096]u8
		guest_len, out_pack_ref := pack_disk_image(.Output_Writable, out_files[:], spec.frozen_epoch_seconds, guest_image[:])
		testing.expect_value(t, out_pack_ref, Guest_Builder_Refusal.None)
		testing.expect_value(t, runner_handle_block_request(runner, .Output_Writable, .Write, 0, guest_image[:guest_len]), Guest_Block_Status.Ok)

		// Clean exit code 0.
		testing.expect(t, !runner_handle_exit(runner, &regs, .Port_Write, u64(Guest_Io_Port.Build_Exit_Status), 4, 0, 0x1008))

		workspace := new(Disk_Unpack_Workspace, context.temp_allocator)
		tree_buf := make([]u8, 4096, context.temp_allocator)
		hash, written, finish_ref := runner_finish(runner, workspace, tree_buf)
		testing.expect_value(t, finish_ref, Guest_Builder_Refusal.None)
		testing.expect_value(t, runner.state, Guest_Build_State.Succeeded)
		testing.expect(t, !hash_is_zero(hash))
		return hash, tree_buf[:written]
	}

	hash_a, tree_a := run_once(t, 0x11)
	hash_b, tree_b := run_once(t, 0xEE)
	testing.expect_value(t, hash_a, hash_b)
	testing.expect(t, slice.equal(tree_a, tree_b))
}

// Guest_Build_Spec wire encode/decode round-trip, deterministic spec hash,
// and refusal of mutated wire bytes.
@(test)
build_spec_wire_round_trip_and_refusals :: proc(t: ^testing.T) {
	spec := valid_spec()
	wire: [SPEC_WIRE_SIZE]u8
	written, enc_ref := encode_build_spec(&spec, wire[:])
	testing.expect_value(t, enc_ref, Guest_Builder_Refusal.None)
	testing.expect_value(t, written, SPEC_WIRE_SIZE)

	decoded, dec_ref := decode_build_spec(wire[:])
	testing.expect_value(t, dec_ref, Guest_Builder_Refusal.None)
	testing.expect_value(t, decoded, spec)

	hash1, h1_ref := build_spec_hash(&spec)
	hash2, h2_ref := build_spec_hash(&decoded)
	testing.expect_value(t, h1_ref, Guest_Builder_Refusal.None)
	testing.expect_value(t, h2_ref, Guest_Builder_Refusal.None)
	testing.expect_value(t, hash1, hash2)
	testing.expect(t, !hash_is_zero(hash1))

	// Flip allow_network byte on wire -> Network_Forbidden.
	bad_wire := wire
	bad_wire[112] = 1
	_, net_ref := decode_build_spec(bad_wire[:])
	testing.expect_value(t, net_ref, Guest_Builder_Refusal.Network_Forbidden)

	// Flip allow_real_clock byte on wire -> Real_Clock_Forbidden.
	bad_wire = wire
	bad_wire[113] = 1
	_, clock_ref := decode_build_spec(bad_wire[:])
	testing.expect_value(t, clock_ref, Guest_Builder_Refusal.Real_Clock_Forbidden)

	// Flip allow_writable_inputs byte on wire -> Writable_Input_Forbidden.
	bad_wire = wire
	bad_wire[114] = 1
	_, ro_ref := decode_build_spec(bad_wire[:])
	testing.expect_value(t, ro_ref, Guest_Builder_Refusal.Writable_Input_Forbidden)

	// Truncated wire -> Malformed_Disk_Image.
	_, trunc_ref := decode_build_spec(wire[:SPEC_WIRE_SIZE - 1])
	testing.expect_value(t, trunc_ref, Guest_Builder_Refusal.Malformed_Disk_Image)

	// The wire of version 1 is refused.
	bad_wire = wire
	byte_order.write_u32_little_endian(bad_wire[:], 8, 1)
	_, version_ref := decode_build_spec(bad_wire[:])
	testing.expect_value(t, version_ref, Guest_Builder_Refusal.Malformed_Disk_Image)

	// A spec with no initial archive has zero bytes at its place.
	for value in wire[SPEC_WIRE_INITIAL_ARCHIVE_OFFSET:] {
		testing.expect_value(t, value, u8(0))
	}

	// The initial archive crosses the wire, and changes the hash of the spec.
	with_archive := spec
	testing.expect_value(t, build_spec_set_initial_archive(&with_archive, transmute([]u8)string("070701")), Guest_Builder_Refusal.None)
	archive_wire: [SPEC_WIRE_SIZE]u8
	_, archive_ref := encode_build_spec(&with_archive, archive_wire[:])
	testing.expect_value(t, archive_ref, Guest_Builder_Refusal.None)
	testing.expect_value(t, byte_order.read_u64_little_endian(archive_wire[:], SPEC_WIRE_INITIAL_ARCHIVE_OFFSET + 32), u64(6))
	archive_decoded, archive_dec_ref := decode_build_spec(archive_wire[:])
	testing.expect_value(t, archive_dec_ref, Guest_Builder_Refusal.None)
	testing.expect_value(t, archive_decoded, with_archive)
	archive_hash, _ := build_spec_hash(&with_archive)
	testing.expect(t, archive_hash != hash1)

	// A size on the wire with no hash, and a hash with the size 0.
	bad_wire = wire
	byte_order.write_u64_little_endian(bad_wire[:], SPEC_WIRE_INITIAL_ARCHIVE_OFFSET + 32, 6)
	_, size_ref := decode_build_spec(bad_wire[:])
	testing.expect_value(t, size_ref, Guest_Builder_Refusal.Initial_Archive_Size_Invalid)
	bad_wire = archive_wire
	byte_order.write_u64_little_endian(bad_wire[:], SPEC_WIRE_INITIAL_ARCHIVE_OFFSET + 32, 0)
	_, hash_ref := decode_build_spec(bad_wire[:])
	testing.expect_value(t, hash_ref, Guest_Builder_Refusal.Initial_Archive_Size_Invalid)
	// A size past the bound on the wire.
	bad_wire = archive_wire
	byte_order.write_u64_little_endian(bad_wire[:], SPEC_WIRE_INITIAL_ARCHIVE_OFFSET + 32, max(u64))
	_, large_ref := decode_build_spec(bad_wire[:])
	testing.expect_value(t, large_ref, Guest_Builder_Refusal.Initial_Archive_Too_Large)
}
