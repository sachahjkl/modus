package resources

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "modus:contract/font_characters"
import "modustool:foundation"

// The bitmap font of the system is Spleen, a font that is drawn for each
// of its sizes. The command "font" converts four of its BDF files to Odin
// data: 8x16, the font of the cells of the graphics library, and 12x24,
// 16x32 and 32x64, the cells of the boot display at 12, 16 and 32 eighths
// (src/md/features/boot_display_scale.md, "The text"). The results are in
// the repository, so that a build does not need the BDF files. Each holds
// the characters with a character index, in the order of that index
// (font_characters.character_index): ASCII 32 to 126, then the Latin-1
// Supplement, then the added characters. A character that a BDF file lacks
// stops the command.

// The folder of the BDF files of Spleen: the development shell sets it.
FONT_SOURCE_VARIABLE :: "FONT_SOURCE"
FONT_WIDTH :: 8
FONT_HEIGHT :: 16
// The sizes of the boot display, past 8x16.
BOOT_DISPLAY_FONT_SIZES :: [3][2]int{{12, 24}, {16, 32}, {32, 64}}
// The widest row of a size that a table keeps: 32 bits.
FONT_ROW_BITS_MOST :: 32

// bdf_glyphs_read reads the glyphs of the characters with a character index from
// a BDF file of one size: rows gets height rows for each character index,
// each row as the BDF file writes it (the left pixel in the high bit of its
// bytes). Every glyph must have the box of the size, at the offsets of the
// first glyph. It gives false, after one line on the standard error, for a
// file that does not read, a glyph of another box, or a missing character.
bdf_glyphs_read :: proc(path: string, width, height: int, rows: []u32) -> bool {
	source, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("modustool: cannot read %s: %v", path, err)
		return false
	}
	found := 0
	index := -1 // The character index of the glyph that is read; -1 for a character that the font of the system does not hold.
	row := -1 // The next line of the bitmap; -1 outside a bitmap.
	first_box := ""
	text := string(source)
	for line in strings.split_lines_iterator(&text) {
		switch {
		case strings.has_prefix(line, "ENCODING "):
			encoding, _ := strconv.parse_int(line[len("ENCODING "):])
			index = -1
			if character_index, in_font := font_characters.character_index(rune(encoding)); in_font && encoding >= 0 {
				index = character_index
			}
		case strings.has_prefix(line, "BBX "):
			fields := strings.fields(line, context.temp_allocator)
			box_width, box_height := -1, -1
			if len(fields) == 5 {
				box_width, _ = strconv.parse_int(fields[1])
				box_height, _ = strconv.parse_int(fields[2])
			}
			if first_box == "" {
				first_box = strings.clone(line, context.temp_allocator)
			}
			if box_width != width || box_height != height || line != first_box {
				fmt.eprintfln("modustool: %s: a glyph is not %dx%d at the offsets of the first glyph: %s", path, width, height, line)
				return false
			}
		case line == "BITMAP":
			row = 0
		case line == "ENDCHAR":
			if index >= 0 && row == height {
				found += 1
			}
			row = -1
		case row >= 0 && row < height:
			if index >= 0 {
				bits, _ := strconv.parse_uint(line, 16)
				rows[index * height + row] = u32(bits)
			}
			row += 1
		}
	}
	if found != font_characters.CHARACTER_COUNT {
		fmt.eprintfln("modustool: %s has %d of the %d characters", path, found, font_characters.CHARACTER_COUNT)
		return false
	}
	return true
}

// bdf_path gives the BDF file of a size in the folder of the font.
bdf_path :: proc(folder: string, width, height: int) -> string {
	return fmt.tprintf("%s/spleen-%dx%d.bdf", folder, width, height)
}

run_font :: proc(args: []string) -> int {
	folder := os.get_env(FONT_SOURCE_VARIABLE, context.temp_allocator)
	if folder == "" {
		fmt.eprintln("modustool: " + FONT_SOURCE_VARIABLE + " is not set. Use the development shell: nix develop")
		return foundation.EXIT_FAILURE
	}

	// 8x16, the font of the cells: one byte for each row.
	glyphs := make([]u32, font_characters.CHARACTER_COUNT * FONT_HEIGHT, context.temp_allocator)
	if !bdf_glyphs_read(bdf_path(folder, FONT_WIDTH, FONT_HEIGHT), FONT_WIDTH, FONT_HEIGHT, glyphs) {
		return foundation.EXIT_FAILURE
	}
	out := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&out, "// This file is the output of \"modustool font\". Do not change it by hand.")
	fmt.sbprintln(&out, "//")
	fmt.sbprintln(&out, "// The font is Spleen 8x16 2.1.0, Copyright (c) 2018-2024, Frederic Cambus.")
	fmt.sbprintln(&out, "// Its license is BSD 2-Clause: see " + SPLEEN_LICENSE_FILE + ".")
	fmt.sbprintln(&out, "package graphics")
	fmt.sbprintln(&out)
	fmt.sbprintln(&out, "import \"modus:contract/font_characters\"")
	fmt.sbprintln(&out)
	fmt.sbprintln(&out, "// One glyph is one byte per line, from the top. Bit 7 is the left pixel.")
	fmt.sbprintln(&out, "// The glyphs are in the order of font_characters.character_index: the comment")
	fmt.sbprintln(&out, "// of each glyph is its code point.")
	fmt.sbprintfln(&out, "CELL_WIDTH :: %d", FONT_WIDTH)
	fmt.sbprintfln(&out, "CELL_HEIGHT :: %d", FONT_HEIGHT)
	fmt.sbprintln(&out)
	fmt.sbprintln(&out, "@(rodata)")
	fmt.sbprintln(&out, "font := [font_characters.CHARACTER_COUNT][CELL_HEIGHT]u8 {")
	glyph_rows_write(&out, glyphs, FONT_HEIGHT, 2)
	fmt.sbprintln(&out, "}")
	if write_err := os.write_entire_file(foundation.FONT_OUTPUT, strings.to_string(out)); write_err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", foundation.FONT_OUTPUT, write_err)
		return foundation.EXIT_FAILURE
	}
	fmt.printfln("modustool: wrote %s: %d characters of %dx%d pixels", foundation.FONT_OUTPUT, font_characters.CHARACTER_COUNT, FONT_WIDTH, FONT_HEIGHT)

	// 12x24 and 16x32, the cells of the boot display: 16 bits for each row,
	// the left pixel in bit 15. A row of the BDF file of a width of 9 to 16
	// pixels has two bytes, so its bits are already in that place.
	sizes := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&sizes, "// This file is the output of \"modustool font\". Do not change it by hand.")
	fmt.sbprintln(&sizes, "//")
	fmt.sbprintln(&sizes, "// The font is Spleen 12x24, 16x32 and 32x64 2.1.0, Copyright (c) 2018-2024, Frederic Cambus.")
	fmt.sbprintln(&sizes, "// Its license is BSD 2-Clause: see " + SPLEEN_LICENSE_FILE + ".")
	fmt.sbprintln(&sizes, "package bootscreen")
	fmt.sbprintln(&sizes)
	fmt.sbprintln(&sizes, "import \"modus:contract/font_characters\"")
	fmt.sbprintln(&sizes)
	fmt.sbprintln(&sizes, "// One glyph is one row per line, from the top: 16 bits for a width up to")
	fmt.sbprintln(&sizes, "// 16, with the left pixel in bit 15, and 32 bits for 32x64, with the left")
	fmt.sbprintln(&sizes, "// pixel in bit 31. The glyphs are in the order of")
	fmt.sbprintln(&sizes, "// font_characters.character_index: the comment of each glyph is its code point.")
	boot_display_sizes := BOOT_DISPLAY_FONT_SIZES
	for size in boot_display_sizes {
		width, height := size[0], size[1]
		// A row of the BDF file has the bytes of its width: 2 bytes for 9 to
		// 16 pixels, 4 bytes for 25 to 32, so its left pixel is the high bit.
		row_bits := width <= 16 ? 16 : 32
		if width <= row_bits / 2 || width > FONT_ROW_BITS_MOST || (row_bits == 32 && width <= 24) {
			fmt.eprintfln("modustool: a size of %dx%d does not take rows of 16 or 32 bits", width, height)
			return foundation.EXIT_FAILURE
		}
		rows := make([]u32, font_characters.CHARACTER_COUNT * height, context.temp_allocator)
		if !bdf_glyphs_read(bdf_path(folder, width, height), width, height, rows) {
			return foundation.EXIT_FAILURE
		}
		fmt.sbprintln(&sizes)
		fmt.sbprintfln(&sizes, "SPLEEN_%dX%d_WIDTH :: %d", width, height, width)
		fmt.sbprintfln(&sizes, "SPLEEN_%dX%d_HEIGHT :: %d", width, height, height)
		fmt.sbprintln(&sizes)
		fmt.sbprintln(&sizes, "@(rodata)")
		// The brace is written apart: a format holds none.
		fmt.sbprint(&sizes, fmt.tprintf("spleen_%dx%d := [font_characters.CHARACTER_COUNT][SPLEEN_%dX%d_HEIGHT]u%d ", width, height, width, height, row_bits))
		fmt.sbprintln(&sizes, "{")
		glyph_rows_write(&sizes, rows, height, row_bits / 4)
		fmt.sbprintln(&sizes, "}")
	}
	if write_err := os.write_entire_file(foundation.BOOT_DISPLAY_FONT_OUTPUT, strings.to_string(sizes)); write_err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", foundation.BOOT_DISPLAY_FONT_OUTPUT, write_err)
		return foundation.EXIT_FAILURE
	}
	fmt.printfln("modustool: wrote %s: %d characters of 12x24, 16x32 and 32x64 pixels", foundation.BOOT_DISPLAY_FONT_OUTPUT, font_characters.CHARACTER_COUNT)
	return 0
}

// glyph_rows_write writes one line for each glyph: its rows in hexadecimal
// with two, four or eight digits, then its code point as a comment.
glyph_rows_write :: proc(out: ^strings.Builder, rows: []u32, height, digits: int) {
	for glyph_index in 0 ..< font_characters.CHARACTER_COUNT {
		fmt.sbprint(out, "\t{")
		for line in 0 ..< height {
			bits := rows[glyph_index * height + line]
			separator := line == 0 ? "" : ", "
			switch digits {
			case 2:
				fmt.sbprintf(out, "%s0x%02X", separator, bits)
			case 4:
				fmt.sbprintf(out, "%s0x%04X", separator, bits)
			case:
				fmt.sbprintf(out, "%s0x%08X", separator, bits)
			}
		}
		character, _ := font_characters.character_of_index(glyph_index)
		fmt.sbprintfln(out, "}, // %d", int(character))
	}
}

// The license of Spleen, beside the data that this command writes; the
// reuse list and the site read it.
SPLEEN_LICENSE_FILE :: foundation.SOURCE_FOLDER_SUPPORT + "/graphics/FONT_LICENSE"
