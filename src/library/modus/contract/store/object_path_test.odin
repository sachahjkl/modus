#+build !freestanding
package store

import "core:strings"
import "core:testing"

// Border check: unknown words for Object_Path_Problem are refused, and every
// member round-trips cleanly.
@(test)
object_path_problem_border_refuses_unknown_words :: proc(t: ^testing.T) {
	for word in ([?]u64{u64(max(Object_Path_Problem)) + 1, 0x100, max(u64)}) {
		_, ok := object_path_problem_of_word(word)
		testing.expectf(t, !ok, "word %d must not map to an Object_Path_Problem", word)
	}
	for member in Object_Path_Problem {
		got, ok := object_path_problem_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, got, member)
	}
}

// Refusal cases come first: empty path, leading slash, trailing slash, double
// slashes, dot segments, NUL, control bytes, invalid UTF-8, segment length
// past 255, depth past 32, and total length past 4096.
@(test)
object_path_refusals_and_exact_edges :: proc(t: ^testing.T) {
	// 0 bytes -> Empty.
	count, problem, offset, bad := object_path_validate("")
	testing.expect_value(t, count, 0)
	testing.expect_value(t, problem, Object_Path_Problem.Empty)
	testing.expect_value(t, offset, 0)
	testing.expect_value(t, bad, u8(0))

	// Leading slash cases.
	for leading in ([?]string{"/", "/a", "/pointer_themes/posy", "//"}) {
		c, p, off, b := object_path_validate(leading)
		testing.expect_value(t, c, 0)
		testing.expect_value(t, p, Object_Path_Problem.Leading_Slash)
		testing.expect_value(t, off, 0)
		testing.expect_value(t, b, u8('/'))
	}

	// Trailing slash cases.
	for trailing in ([?]string{"a/", "pointer_themes/posy/", "a/b//"}) {
		c, p, off, b := object_path_validate(trailing)
		testing.expect_value(t, c, 0)
		testing.expect_value(t, p, Object_Path_Problem.Trailing_Slash)
		testing.expect_value(t, off, len(trailing) - 1)
		testing.expect_value(t, b, u8('/'))
	}

	// Empty interior segments ("//").
	for empty_seg in ([?]struct {
		path: string,
		off:  int,
	}{{"a//b", 2}, {"a/b///c", 4}, {"x//y/z", 2}}) {
		c, p, off, b := object_path_validate(empty_seg.path)
		testing.expect_value(t, c, 0)
		testing.expect_value(t, p, Object_Path_Problem.Empty_Segment)
		testing.expect_value(t, off, empty_seg.off)
		testing.expect_value(t, b, u8('/'))
	}

	// Dot segments ("." and "..") at start, middle, and end.
	for dot_case in ([?]struct {
		path: string,
		off:  int,
	}{
		{".", 0},
		{"..", 0},
		{"./a", 0},
		{"../a", 0},
		{"a/./b", 2},
		{"a/../b", 2},
		{"a/.", 2},
		{"a/..", 2},
	}) {
		c, p, off, b := object_path_validate(dot_case.path)
		testing.expect_value(t, c, 0)
		testing.expect_value(t, p, Object_Path_Problem.Dot_Segment)
		testing.expect_value(t, off, dot_case.off)
		testing.expect_value(t, b, u8('.'))
	}

	// NUL, C0 controls, DEL, C1 controls, and invalid UTF-8 sequences.
	bad_byte_cases := [?]struct {
		bytes: []u8,
		off:   int,
		byte:  u8,
	}{
		{{0x00}, 0, 0x00},
		{{'a', '/', 'b', 0x00, 'c'}, 3, 0x00},
		{{'a', '\n', 'b'}, 1, '\n'},
		{{'a', '\t', 'b'}, 1, '\t'},
		{{'a', '/', 0x1F}, 2, 0x1F},
		{{'a', '/', 0x7F}, 2, 0x7F},
		{{'a', '/', 0xC2, 0x80}, 2, 0xC2},             // U+0080 C1 control
		{{'a', '/', 0xC2, 0x9F}, 2, 0xC2},             // U+009F C1 control
		{{'a', '/', 0xFF}, 2, 0xFF},                   // Invalid UTF-8 lead
		{{'a', '/', 0xC0, 0xAF}, 2, 0xC0},             // Overlong '/'
		{{'a', '/', 0xED, 0xA0, 0x80}, 2, 0xED},       // UTF-16 surrogate U+D800
		{{'a', '/', 0xF4, 0x90, 0x80, 0x80}, 2, 0xF4}, // Above U+10FFFF
		{{'a', '/', 0xE2, 0x82}, 2, 0xE2},             // Truncated 3-byte UTF-8
	}
	for item in bad_byte_cases {
		c, p, off, b := object_path_validate(string(item.bytes))
		testing.expect_value(t, c, 0)
		testing.expect_value(t, p, Object_Path_Problem.Bad_Byte)
		testing.expect_value(t, off, item.off)
		testing.expect_value(t, b, item.byte)
	}

	// Segment length bound: 255 valid, 256 refused.
	seg_255 := strings.repeat("a", ENTRY_NAME_CAPACITY, context.temp_allocator)
	seg_256 := strings.repeat("a", ENTRY_NAME_CAPACITY + 1, context.temp_allocator)
	c255, p255, _, _ := object_path_validate(seg_255)
	testing.expect_value(t, p255, Object_Path_Problem.None)
	testing.expect_value(t, c255, 1)

	c256, p256, off256, _ := object_path_validate(seg_256)
	testing.expect_value(t, c256, 0)
	testing.expect_value(t, p256, Object_Path_Problem.Segment_Too_Long)
	testing.expect_value(t, off256, 0)

	nested_256 := strings.concatenate({"ok/", seg_256}, context.temp_allocator)
	cn256, pn256, offn256, _ := object_path_validate(nested_256)
	testing.expect_value(t, cn256, 0)
	testing.expect_value(t, pn256, Object_Path_Problem.Segment_Too_Long)
	testing.expect_value(t, offn256, 3)

	// Depth bound: 32 segments valid, 33 segments refused.
	depth_32_parts := make([]string, OBJECT_PATH_DEPTH_LIMIT, context.temp_allocator)
	for &part in depth_32_parts {
		part = "d"
	}
	depth_32 := strings.join(depth_32_parts, "/", context.temp_allocator)
	c32, p32, _, _ := object_path_validate(depth_32)
	testing.expect_value(t, p32, Object_Path_Problem.None)
	testing.expect_value(t, c32, OBJECT_PATH_DEPTH_LIMIT)

	depth_33 := strings.concatenate({depth_32, "/x"}, context.temp_allocator)
	c33, p33, off33, _ := object_path_validate(depth_33)
	testing.expect_value(t, c33, 0)
	testing.expect_value(t, p33, Object_Path_Problem.Too_Deep)
	testing.expect_value(t, off33, len(depth_32) + 1)

	// Total byte length bound: 4096 bytes valid, 4097 bytes refused.
	// 16 segments of 255 bytes + 15 slashes = 4095 bytes; build exact 4096:
	// 16 segments of 255 bytes = 4080, plus 16 slashes + 1-byte segment = 17 segments, 4097 bytes.
	// For exact 4096 bytes: 15 * (255 + 1) = 3840, plus 254 + 1 + 1 = 256 -> 3840 + 256 = 4096 (17 segments).
	exact_parts := make([dynamic]string, context.temp_allocator)
	for _ in 0 ..< 15 {
		append(&exact_parts, seg_255)
	}
	append(&exact_parts, strings.repeat("b", 254, context.temp_allocator))
	append(&exact_parts, "z")
	path_4096 := strings.join(exact_parts[:], "/", context.temp_allocator)
	testing.expect_value(t, len(path_4096), OBJECT_PATH_LIMIT)
	c4096, p4096, _, _ := object_path_validate(path_4096)
	testing.expect_value(t, p4096, Object_Path_Problem.None)
	testing.expect_value(t, c4096, 17)

	path_4097 := strings.concatenate({path_4096, "q"}, context.temp_allocator)
	testing.expect_value(t, len(path_4097), OBJECT_PATH_LIMIT + 1)
	c4097, p4097, off4097, _ := object_path_validate(path_4097)
	testing.expect_value(t, c4097, 0)
	testing.expect_value(t, p4097, Object_Path_Problem.Too_Long)
	testing.expect_value(t, off4097, OBJECT_PATH_LIMIT)

	// Refused split leaves caller's output buffer untouched.
	out: [OBJECT_PATH_DEPTH_LIMIT]string
	out[0] = "sentinel"
	split_count, split_problem, _, _ := object_path_split("bad/../path", &out)
	testing.expect_value(t, split_count, 0)
	testing.expect_value(t, split_problem, Object_Path_Problem.Dot_Segment)
	testing.expect_value(t, out[0], "sentinel")
}

// Valid cases: 1-byte name, dot-prefixed normal names ("...", ".config"),
// UTF-8 names, and real system object paths with iterator and split checks.
@(test)
object_path_valid_paths_iterate_and_split :: proc(t: ^testing.T) {
	Case :: struct {
		path:     string,
		segments: []string,
	}
	cases := [?]Case {
		{"a", {"a"}},
		{"...", {"..."}},
		{".hidden/file..name", {".hidden", "file..name"}},
		{"pointer_themes/posy", {"pointer_themes", "posy"}},
		{"fonts/noto_sans_hebrew", {"fonts", "noto_sans_hebrew"}},
		{"manual/pages/français/réseau", {"manual", "pages", "français", "réseau"}},
	}
	for item in cases {
		count, problem, _, _ := object_path_validate(item.path)
		testing.expect_value(t, problem, Object_Path_Problem.None)
		testing.expect_value(t, count, len(item.segments))

		// Iterator extracts exact slices with zero allocation.
		it := object_path_iterator_make(item.path)
		index := 0
		for seg in object_path_next(&it) {
			testing.expect(t, index < len(item.segments))
			testing.expect_value(t, seg, item.segments[index])
			index += 1
		}
		testing.expect_value(t, index, len(item.segments))
		_, extra := object_path_next(&it)
		testing.expect(t, !extra)

		// Split fills caller buffer identically.
		out: [OBJECT_PATH_DEPTH_LIMIT]string
		split_count, split_problem, _, _ := object_path_split(item.path, &out)
		testing.expect_value(t, split_problem, Object_Path_Problem.None)
		testing.expect_value(t, split_count, len(item.segments))
		for expected, i in item.segments {
			testing.expect_value(t, out[i], expected)
		}
	}
}
