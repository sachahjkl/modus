package modustool

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "modus:contract/glyph_cache"
import "modustool:foundation"

// The font of the graphics library is Spleen 8x16, a bitmap font that is
// drawn for this size. The command "font" converts its BDF file to Odin data.
// The result is in the repository, so that a build does not need the BDF file.
// It holds the characters of a glyph cache, in the order of their character
// index (glyph_cache.character_index): ASCII 32 to 126, then the Latin-1
// Supplement, then the added characters. Spleen 8x16 2.1.0 draws the euro
// sign; a character that the BDF file lacks stops the command.

FONT_SOURCE_VARIABLE :: "FONT_SOURCE"
FONT_WIDTH :: 8
FONT_HEIGHT :: 16

run_font :: proc(args: []string) -> int {
	path := os.get_env(FONT_SOURCE_VARIABLE, context.temp_allocator)
	if path == "" {
		fmt.eprintln("modustool: " + FONT_SOURCE_VARIABLE + " is not set. Use the development shell: nix develop")
		return foundation.EXIT_FAILURE
	}
	source, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("modustool: cannot read %s: %v", path, err)
		return foundation.EXIT_FAILURE
	}
	glyphs: [glyph_cache.CHARACTER_COUNT][FONT_HEIGHT]u8
	found := 0
	index := -1 // The character index of the glyph that is read; -1 for a character that the font of the system does not hold.
	encoding := -1
	row := -1 // The next line of the bitmap; -1 outside a bitmap.
	text := string(source)
	for line in strings.split_lines_iterator(&text) {
		switch {
		case strings.has_prefix(line, "ENCODING "):
			encoding, _ = strconv.parse_int(line[len("ENCODING "):])
			index = -1
			if character_index, in_font := glyph_cache.character_index(rune(encoding)); in_font && encoding >= 0 {
				index = character_index
			}
		case strings.has_prefix(line, "BBX ") && line != "BBX 8 16 0 -4":
			fmt.eprintfln("modustool: %s: a glyph is not %dx%d: %s", path, FONT_WIDTH, FONT_HEIGHT, line)
			return foundation.EXIT_FAILURE
		case line == "BITMAP":
			row = 0
		case line == "ENDCHAR":
			if index >= 0 && row == FONT_HEIGHT {
				found += 1
			}
			row = -1
		case row >= 0 && row < FONT_HEIGHT:
			if index >= 0 {
				bits, _ := strconv.parse_uint(line, 16)
				glyphs[index][row] = u8(bits)
			}
			row += 1
		}
	}
	if found != len(glyphs) {
		fmt.eprintfln("modustool: %s has %d of the %d characters", path, found, len(glyphs))
		return foundation.EXIT_FAILURE
	}

	out := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&out, "// This file is the output of \"modustool font\". Do not change it by hand.")
	fmt.sbprintln(&out, "//")
	fmt.sbprintln(&out, "// The font is Spleen 8x16 2.1.0, Copyright (c) 2018-2024, Frederic Cambus.")
	fmt.sbprintln(&out, "// Its license is BSD 2-Clause: see " + SITE_SPLEEN_LICENSE_FILE + ".")
	fmt.sbprintln(&out, "package graphics")
	fmt.sbprintln(&out)
	fmt.sbprintln(&out, "import \"modus:contract/glyph_cache\"")
	fmt.sbprintln(&out)
	fmt.sbprintln(&out, "// One glyph is one byte per line, from the top. Bit 7 is the left pixel.")
	fmt.sbprintln(&out, "// The glyphs are in the order of glyph_cache.character_index: the comment")
	fmt.sbprintln(&out, "// of each glyph is its code point.")
	fmt.sbprintfln(&out, "CELL_WIDTH :: %d", FONT_WIDTH)
	fmt.sbprintfln(&out, "CELL_HEIGHT :: %d", FONT_HEIGHT)
	fmt.sbprintln(&out)
	fmt.sbprintln(&out, "@(rodata)")
	fmt.sbprintln(&out, "font := [glyph_cache.CHARACTER_COUNT][CELL_HEIGHT]u8 {")
	for glyph, glyph_index in glyphs {
		fmt.sbprint(&out, "\t{")
		for bits, line in glyph {
			fmt.sbprintf(&out, "%s0x%02X", line == 0 ? "" : ", ", bits)
		}
		character, _ := glyph_cache.character_of_index(glyph_index)
		fmt.sbprintfln(&out, "}, // %d", int(character))
	}
	fmt.sbprintln(&out, "}")
	if write_err := os.write_entire_file(foundation.FONT_OUTPUT, strings.to_string(out)); write_err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", foundation.FONT_OUTPUT, write_err)
		return foundation.EXIT_FAILURE
	}
	fmt.printfln("modustool: wrote %s: %d characters of %dx%d pixels", foundation.FONT_OUTPUT, found, FONT_WIDTH, FONT_HEIGHT)
	return 0
}
