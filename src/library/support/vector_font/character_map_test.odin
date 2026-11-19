#+build !freestanding
package vector_font

import "core:testing"

@(private = "file")
b612_file := #load("../../../../resources/fonts/b612.ttf")

// One segment of a cmap of format 4 that a test writes: its first and last
// code, and a delta that maps each code of it to the glyph 1.
@(private = "file")
Test_Segment :: struct {
	start, end: int,
}

@(private = "file")
put_u16 :: proc(bytes: ^[dynamic]u8, value: int) {
	append(bytes, u8(value >> 8 & 0xFF), u8(value & 0xFF))
}

@(private = "file")
put_u32 :: proc(bytes: ^[dynamic]u8, value: int) {
	put_u16(bytes, value >> 16 & 0xFFFF)
	put_u16(bytes, value & 0xFFFF)
}

// character_map_of writes a table cmap with one subtable of format 4
// (platform 3, encoding 1): the segments as given, each code mapped to the
// glyph 1, with no range offset. doubled is the count of segments times 2
// that the subtable states, and length the length that it states: a test
// gives a wrong one.
@(private = "file")
character_map_of :: proc(segments: []Test_Segment, doubled, length: int) -> []u8 {
	bytes := make([dynamic]u8)
	put_u16(&bytes, 0) // The version.
	put_u16(&bytes, 1) // One subtable.
	put_u16(&bytes, 3)
	put_u16(&bytes, 1)
	put_u32(&bytes, 12)
	put_u16(&bytes, 4) // The format.
	put_u16(&bytes, length)
	put_u16(&bytes, 0) // The language.
	put_u16(&bytes, doubled)
	put_u16(&bytes, 0)
	put_u16(&bytes, 0)
	put_u16(&bytes, 0)
	for segment in segments {
		put_u16(&bytes, segment.end)
	}
	put_u16(&bytes, 0) // The reserved word.
	for segment in segments {
		put_u16(&bytes, segment.start)
	}
	for segment in segments {
		put_u16(&bytes, (1 - segment.start) & 0xFFFF)
	}
	for _ in segments {
		put_u16(&bytes, 0)
	}
	return bytes[:]
}

// font_with_character_map gives a copy of B612 whose directory names a new
// table cmap, appended at its end on 4 bytes.
@(private = "file")
font_with_character_map :: proc(character_map: []u8) -> []u8 {
	bytes := make([dynamic]u8)
	append(&bytes, ..b612_file)
	for len(bytes) % 4 != 0 {
		append(&bytes, 0)
	}
	place := len(bytes)
	append(&bytes, ..character_map)
	count := read_u16(bytes[:], 4) or_else 0
	for index in 0 ..< count {
		record := 12 + 16 * index
		if string(bytes[record:record + 4]) != "cmap" {
			continue
		}
		for shift, at in ([4]uint{24, 16, 8, 0}) {
			bytes[record + 8 + at] = u8(place >> shift & 0xFF)
			bytes[record + 12 + at] = u8(len(character_map) >> shift & 0xFF)
		}
	}
	return bytes[:]
}

// The segments of a cmap are checked once, at the open: two segments out
// of order, two segments with one end, and an odd count are refused as an
// unknown format; a count whose arrays pass the subtable is refused as too
// short, with the largest count, 32 767 segments, in a subtable of the
// largest length. One segment, and the largest count that a subtable holds,
// 8 189 segments, open, and each code finds its segment by halves: the
// first, the middle, the last, and none past the last; last.
@(test)
the_segments_of_a_character_map :: proc(t: ^testing.T) {
	Refusal :: struct {
		name:     string,
		segments: []Test_Segment,
		doubled:  int, // 0: the count of the segments.
		problem:  Font_Problem,
	}
	unsorted := [3]Test_Segment{{10, 20}, {5, 8}, {0xFFFF, 0xFFFF}}
	twice := [3]Test_Segment{{5, 8}, {8, 8}, {0xFFFF, 0xFFFF}}
	one := [1]Test_Segment{{'A', 'Z'}}
	refusals := [?]Refusal {
		{"two segments out of order", unsorted[:], 0, .Unknown_Format},
		{"two segments with one end", twice[:], 0, .Unknown_Format},
		{"an odd count", one[:], 3, .Unknown_Format},
		{"one segment past the subtable", one[:], 4, .Too_Short},
		{"the largest count in the largest length", one[:], 0xFFFE, .Too_Short},
	}
	for refusal in refusals {
		doubled := refusal.doubled != 0 ? refusal.doubled : 2 * len(refusal.segments)
		character_map := character_map_of(refusal.segments, doubled, 16 + 8 * len(refusal.segments))
		if refusal.doubled == 0xFFFE {
			// The length field holds at most 0xFFFF: pad the subtable to it.
			padded := make([]u8, 12 + 0xFFFF)
			copy(padded, character_map)
			padded[12 + 2], padded[12 + 3] = 0xFF, 0xFF
			character_map = padded
		}
		_, problem := font_open(font_with_character_map(character_map))
		testing.expectf(t, problem == refusal.problem, "%s: %v, expected %v", refusal.name, problem, refusal.problem)
	}
	// One segment: its codes, and a code on each side of it.
	font, problem := font_open(font_with_character_map(character_map_of(one[:], 2, 16 + 8)))
	testing.expect_value(t, problem, Font_Problem.None)
	testing.expect_value(t, font.map_segments, 1)
	for character in ([?]rune{'A', 'M', 'Z'}) {
		glyph, found := glyph_of(&font, character)
		testing.expectf(t, found == .None && glyph == 1, "%c in one segment: %v %v", character, glyph, found)
	}
	for character in ([?]rune{'@', '[', 0, 0xFFFF}) {
		_, found := glyph_of(&font, character)
		testing.expectf(t, found == .No_Glyph, "%x outside one segment: %v", character, found)
	}
	// The largest count that a subtable of the largest length holds.
	LARGEST :: (0xFFFF - 16) / 8
	many := make([]Test_Segment, LARGEST)
	for &segment, index in many {
		segment = {2 * index + 1, 2 * index + 1}
	}
	font, problem = font_open(font_with_character_map(character_map_of(many, 2 * LARGEST, 16 + 8 * LARGEST)))
	testing.expect_value(t, problem, Font_Problem.None)
	testing.expect_value(t, font.map_segments, LARGEST)
	for index in ([?]int{0, LARGEST / 2, LARGEST - 1}) {
		glyph, found := glyph_of(&font, rune(2 * index + 1))
		testing.expectf(t, found == .None && glyph == 1, "the segment %v: %v %v", index, glyph, found)
		_, between := glyph_of(&font, rune(2 * index + 2))
		testing.expectf(t, between == .No_Glyph, "the code after the segment %v: %v", index, between)
	}
	_, past := glyph_of(&font, rune(2 * LARGEST + 1))
	testing.expect_value(t, past, Font_Problem.No_Glyph)
}
