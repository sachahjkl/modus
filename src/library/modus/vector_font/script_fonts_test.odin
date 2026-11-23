#+build !freestanding
package vector_font

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// The script fonts of the system (src/md/features/script_fonts.md), read
// from SCRIPT_FONT_SOURCES: the development shell and the check of the
// flake set it. A test fails when the variable or a file is missing.
SCRIPT_FONT_SOURCES_VARIABLE :: "SCRIPT_FONT_SOURCES"

script_font_bytes :: proc(t: ^testing.T, name: string) -> []u8 {
	sources := os.get_env(SCRIPT_FONT_SOURCES_VARIABLE, context.temp_allocator)
	testing.expectf(t, sources != "", "%s is set: run the tests in the development shell or in the check of the flake", SCRIPT_FONT_SOURCES_VARIABLE)
	rest := sources
	prefix := strings.concatenate({name, "="}, context.temp_allocator)
	for item in strings.split_iterator(&rest, ";") {
		if strings.has_prefix(item, prefix) {
			bytes, error := os.read_entire_file(item[len(prefix):], context.allocator)
			testing.expectf(t, error == nil, "%s can be read", item[len(prefix):])
			return bytes
		}
	}
	testing.expectf(t, false, "%s names %s", SCRIPT_FONT_SOURCES_VARIABLE, name)
	return nil
}

// script_font_open opens a script font file, the first face of a
// collection.
script_font_open :: proc(t: ^testing.T, bytes: []u8) -> (font: Font_File, ok: bool) {
	face, face_problem := collection_face_offset(bytes, 0)
	problem: Font_Problem
	font, problem = font_open(bytes, face)
	return font, testing.expectf(t, face_problem == .None && problem == .None, "the font opens: %v %v", face_problem, problem)
}

@(private = "file")
outline_box :: proc(outline: ^Outline) -> (low_x, low_y, high_x, high_y: i32) {
	low_x, low_y, high_x, high_y = max(i32), max(i32), min(i32), min(i32)
	for point in outline.points[:outline.point_count] {
		low_x, low_y = min(low_x, point.x), min(low_y, point.y)
		high_x, high_y = max(high_x, point.x), max(high_y, point.y)
	}
	return
}

// A font of CFF outlines (Noto Sans Symbols 2) and one of CFF2 outlines in
// a collection (Noto Sans CJK): the black square and the ideograph one have
// closed contours inside the em of their font, as a glyph of glyf has; each
// glyph of Noto Sans Symbols 2 and the first 4 096 glyphs of Noto Sans CJK
// read with no problem. Each cut of the table of Noto Sans Symbols 2 at a
// place gives a problem or an outline, never a read past the table.
@(test)
the_outlines_of_cff_and_cff2 :: proc(t: ^testing.T) {
	memory := new(Render_Memory)
	defer free(memory)
	outline := Outline{points = memory.points[:], contour_ends = memory.contours[:]}
	Case :: struct {
		name:          string,
		character:     rune,
		version:       int,
		glyphs_to_read: int,
	}
	cases := [?]Case{{"noto_sans_symbols_2", 0x25A0, 1, max(int)}, {"noto_sans_cjk", 0x4E00, 2, 4096}}
	for each in cases {
		bytes := script_font_bytes(t, each.name)
		defer delete(bytes)
		font, ok := script_font_open(t, bytes)
		if !ok {
			continue
		}
		testing.expect_value(t, font.cff.version, each.version)
		glyph, problem := glyph_of(&font, each.character)
		testing.expectf(t, problem == .None && glyph > 0, "%s: U+%04X has a glyph", each.name, int(each.character))
		problem = glyph_outline(&font, glyph, &outline)
		testing.expect_value(t, problem, Font_Problem.None)
		testing.expectf(t, outline.contour_count >= 1 && outline.point_count >= 4, "%s: %v contours, %v points", each.name, outline.contour_count, outline.point_count)
		low_x, low_y, high_x, high_y := outline_box(&outline)
		units := i32(font.units_per_em)
		testing.expectf(t, low_x >= -units / 4 && high_x <= units + units / 4 && low_y >= -units / 2 && high_y <= units + units / 4 && high_x > low_x && high_y > low_y, "%s: the box %v %v %v %v in an em of %v", each.name, low_x, low_y, high_x, high_y, units)
		testing.expectf(t, outline.advance > 0, "%s: the advance %v", each.name, outline.advance)
		failed := 0
		for index in 0 ..< min(font.glyph_count, each.glyphs_to_read) {
			glyph_problem := glyph_outline(&font, index, &outline)
			if glyph_problem != .None {
				if failed < 4 {
					fmt.printfln("vector_font: %s: the glyph %v: %v", each.name, index, glyph_problem)
				}
				failed += 1
			}
		}
		testing.expectf(t, failed == 0, "%s: %v glyphs do not read", each.name, failed)
	}
	// The cuts of a CFF font: a font cut inside its tables does not open,
	// or opens and reads each glyph with a problem or an outline.
	bytes := script_font_bytes(t, "noto_sans_symbols_2")
	defer delete(bytes)
	font, ok := script_font_open(t, bytes)
	if !ok {
		return
	}
	cut := make([]u8, len(bytes))
	defer delete(cut)
	for length := font.cff.table.offset; length < len(bytes); length += 4099 {
		copy(cut, bytes)
		damaged := cut[:length]
		opened, problem := font_open(damaged)
		if problem != .None {
			continue
		}
		for index in 0 ..< min(opened.glyph_count, 64) {
			_ = glyph_outline(&opened, index, &outline)
		}
	}
	// One changed byte at each of 64 places of the charstrings.
	for place in 0 ..< 64 {
		copy(cut, bytes)
		at := font.cff.table.offset + (place * 7919) % font.cff.table.length
		cut[at] ~= 0x5A
		opened, problem := font_open(cut)
		if problem != .None {
			continue
		}
		for index in 0 ..< min(opened.glyph_count, 256) {
			_ = glyph_outline(&opened, index, &outline)
		}
	}
}

// The character map of format 12: an emoji past U+FFFF has its glyph in
// Noto Emoji, and a character past each group has none; the groups of a
// built subtable that do not grow refuse the font.
@(test)
the_character_map_of_format_12 :: proc(t: ^testing.T) {
	bytes := script_font_bytes(t, "noto_emoji")
	defer delete(bytes)
	font, ok := script_font_open(t, bytes)
	if !ok {
		return
	}
	testing.expect(t, font.long_map.length > 0 && font.map_groups > 0)
	for character in ([?]rune{0x1F600, 0x1F44D, 0x2764}) {
		glyph, problem := glyph_of(&font, character)
		testing.expectf(t, problem == .None && glyph > 0, "U+%X has a glyph", int(character))
	}
	for character in ([?]rune{0x10FFFF, -1, 0x110000}) {
		_, problem := glyph_of(&font, character)
		testing.expectf(t, problem == .No_Glyph, "U+%X has no glyph", int(character))
	}
	// A subtable of two groups out of order, and one whose last passes
	// U+10FFFF: each is refused.
	table := [?]u8{0, 12, 0, 0, 0, 0, 0, 40, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0x50, 0, 0, 0, 0x60, 0, 0, 0, 1, 0, 0, 0, 0x40, 0, 0, 0, 0x45, 0, 0, 0, 2}
	_, problem := long_map_groups_check(table[:])
	testing.expect_value(t, problem, Font_Problem.Unknown_Format)
	past := [?]u8{0, 12, 0, 0, 0, 0, 0, 28, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0x50, 0, 0x11, 0, 0, 0, 0, 0, 1}
	_, problem = long_map_groups_check(past[:])
	testing.expect_value(t, problem, Font_Problem.Unknown_Format)
	short := [?]u8{0, 12, 0, 0, 0, 0, 0, 28, 0, 0, 0, 0, 0, 0, 0, 9}
	_, problem = long_map_groups_check(short[:])
	testing.expect_value(t, problem, Font_Problem.Too_Short)
}
