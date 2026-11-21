#+build !freestanding
package root_ring

import "core:testing"
import "modus:contract/store"

@(test)
edit_store_validate_refuses_invalid_names_and_accepts_bounds :: proc(t: ^testing.T) {
	refusal, _ := edit_store_validate("")
	testing.expect_value(t, refusal, Edit_Store_Refusal.Empty)

	// One past EDIT_TARGET_STORE_LIMIT.
	too_long: [EDIT_TARGET_STORE_LIMIT + 1]u8
	for &value in too_long {
		value = 'a'
	}
	refusal, _ = edit_store_validate(string(too_long[:]))
	testing.expect_value(t, refusal, Edit_Store_Refusal.Too_Long)

	// Bad bytes: NUL, '/', control, invalid UTF-8.
	bad := [?]string{"a/b", "a\x00b", "a\nb", "\x1b", "\xff"}
	for name in bad {
		refusal, _ = edit_store_validate(name)
		testing.expectf(t, refusal == .Bad_Byte, "store %q gave %v", name, refusal)
	}

	// Exact bounds: 1 byte and EDIT_TARGET_STORE_LIMIT bytes.
	refusal, _ = edit_store_validate("a")
	testing.expect_value(t, refusal, Edit_Store_Refusal.None)
	refusal, _ = edit_store_validate(string(too_long[:EDIT_TARGET_STORE_LIMIT]))
	testing.expect_value(t, refusal, Edit_Store_Refusal.None)
	refusal, _ = edit_store_validate("notes.principal.1")
	testing.expect_value(t, refusal, Edit_Store_Refusal.None)
}

@(test)
edit_path_validate_refuses_bad_paths_and_splits_valid_ones :: proc(t: ^testing.T) {
	refusal, _ := edit_path_validate("")
	testing.expect_value(t, refusal, Edit_Path_Refusal.Empty)

	// One past EDIT_TARGET_PATH_LIMIT.
	long_path: [EDIT_TARGET_PATH_LIMIT + 1]u8
	for &value, idx in long_path {
		value = (idx % 10 == 9) ? '/' : 'a'
	}
	long_path[EDIT_TARGET_PATH_LIMIT] = 'z'
	refusal, _ = edit_path_validate(string(long_path[:]))
	testing.expect_value(t, refusal, Edit_Path_Refusal.Too_Long)

	// Too deep: store.NESTING_LIMIT + 2 segments ("a/a/.../a").
	deep: [(store.NESTING_LIMIT + 2) * 2 - 1]u8
	for i in 0 ..< len(deep) {
		deep[i] = i % 2 == 0 ? 'a' : '/'
	}
	refusal, _ = edit_path_validate(string(deep[:]))
	testing.expect_value(t, refusal, Edit_Path_Refusal.Too_Deep)

	// Segment over ENTRY_NAME_CAPACITY (65 bytes).
	long_seg: [store.ENTRY_NAME_CAPACITY + 1]u8
	for &value in long_seg {
		value = 'x'
	}
	refusal, _ = edit_path_validate(string(long_seg[:]))
	testing.expect_value(t, refusal, Edit_Path_Refusal.Bad_Segment)

	// Bad segments: leading '/', trailing '/', '//', '.', '..', control, invalid UTF-8.
	bad_paths := [?]string{
		"/",
		"/a",
		"a/",
		"a//b",
		".",
		"..",
		"a/./b",
		"a/../b",
		"a/b\x00c",
		"a/b\nc",
		"a/\xff",
	}
	for path in bad_paths {
		refusal, _ = edit_path_validate(path)
		testing.expectf(t, refusal == .Bad_Segment, "path %q gave %v", path, refusal)
	}

	// Valid single-segment, multi-segment, UTF-8, and max-depth paths.
	refusal, _ = edit_path_validate("today.txt")
	testing.expect_value(t, refusal, Edit_Path_Refusal.None)
	refusal, _ = edit_path_validate("src/kernel/enter.odin")
	testing.expect_value(t, refusal, Edit_Path_Refusal.None)
	refusal, _ = edit_path_validate("notes/été.txt")
	testing.expect_value(t, refusal, Edit_Path_Refusal.None)
	// Exact nesting bound: store.NESTING_LIMIT + 1 segments.
	refusal, _ = edit_path_validate(string(deep[:(store.NESTING_LIMIT + 1) * 2 - 1]))
	testing.expect_value(t, refusal, Edit_Path_Refusal.None)

	// Segment iteration on "src/kernel/enter.odin".
	seg1, next1, last1 := edit_path_next_segment("src/kernel/enter.odin", 0)
	testing.expect(t, seg1 == "src" && !last1)
	seg2, next2, last2 := edit_path_next_segment("src/kernel/enter.odin", next1)
	testing.expect(t, seg2 == "kernel" && !last2)
	seg3, _, last3 := edit_path_next_segment("src/kernel/enter.odin", next2)
	testing.expect(t, seg3 == "enter.odin" && last3)
}

@(test)
edit_target_read_refuses_corrupt_pages_and_accepts_valid_one :: proc(t: ^testing.T) {
	_, _, ok := edit_target_read(nil)
	testing.expect(t, !ok)

	bad_cases := [?]Edit_Target{
		{},
		{store_length = EDIT_TARGET_STORE_LIMIT + 1, path_length = 1},
		{store_length = 1, path_length = EDIT_TARGET_PATH_LIMIT + 1},
		{store_length = 1, path_length = 2, store = {0 = 'a'}, path = {0 = '.', 1 = '.'}},
		{store_length = 3, path_length = 1, store = {0 = 'a', 1 = '/', 2 = 'b'}, path = {0 = 'x'}},
	}
	for &item, idx in bad_cases {
		_, _, valid := edit_target_read(&item)
		testing.expectf(t, !valid, "bad target %d was accepted", idx)
	}

	good: Edit_Target
	copy(good.store[:], "notes")
	good.store_length = 5
	copy(good.path[:], "src/main.odin")
	good.path_length = 13
	s, p, valid := edit_target_read(&good)
	testing.expect(t, valid)
	testing.expect_value(t, s, "notes")
	testing.expect_value(t, p, "src/main.odin")
}
