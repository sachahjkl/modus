// The text rendering of the system (src/md/features/text_rendering.md):
// the faces and their fallback chains, the text size, the measure of a
// text (shaping.odin), the breaks of its lines (line_break.odin), the
// rasterizer at any size (raster.odin) and the private glyph cache
// (private_cache.odin).
//
// A process opens it once with the font outlines that its starter mapped
// (open). The shaper asks for an advance (advance), the
// draw for a glyph (glyph), and each frame starts with frame_begin. The
// state is one for each copy of this package: a process has its own, and
// the drawing module that it imports has its own. Both read the same
// outlines with the same code, so the measure in the process and the draw
// in the module give the same advances.
//
// The advance comes from the font file at each measure, never from a
// cache: the measure and the draw of a frame agree whatever the cache
// holds. The draw changes the private glyph cache: one thread of a process
// draws at a time, as for the blend tables of the graphics package.
//
// No table of this package holds an address: the drawing module compiles
// it, and a library module holds no data that the loader would write
// (docs/MODULE_CONTRACT.md, "A library as a module"). So the chains are
// fixed arrays and the names come from procedures.
//
// See [text size](term:text-size), [face](term:face),
// [fallback chain](term:fallback-chain) and
// [private glyph cache](term:private-glyph-cache).
package text_rendering

import "modus:contract/font_outlines"
import "modus:contract/text_encoding"
import "modus:vector_font"

// ---- The text size.

// The text size is the height of the line of a face, in 1/64 of a pixel:
// a line of 16 pixels is the size 1 024. The places and the advances of a
// text are in the same unit.
SUBPIXEL :: 64
// The size of a line of 16 pixels: the line of the grid of cells at scale 1.
TEXT_SIZE_OF_SCALE_ONE :: 16 * SUBPIXEL
// The smallest size: a line of 4 pixels. Below it a glyph has no form that
// a reader can read.
TEXT_SIZE_MINIMUM :: 4 * SUBPIXEL
// The largest size: a line of 256 pixels. It is a bound of cost: the work
// of one glyph grows with the square of the size. A larger text is a path.
TEXT_SIZE_LIMIT :: 256 * SUBPIXEL
// The size is 16 bits in the key of the private glyph cache.
#assert(TEXT_SIZE_LIMIT < 1 << 16)

// Why a text size is refused. None: the size is valid.
Size_Problem :: enum u8 {
	None, // A size from TEXT_SIZE_MINIMUM to TEXT_SIZE_LIMIT.
	Zero, // The size 0: a caller that gives no size names the size it wants.
	Too_Small, // Above 0 and below TEXT_SIZE_MINIMUM.
	Too_Large, // Above TEXT_SIZE_LIMIT.
}

// size_check checks a text size. A size out of its range is refused, never
// clamped: a clamp turns a value that the contract refuses into one that
// it accepts.
size_check :: proc "contextless" (size: int) -> Size_Problem {
	switch {
	case size == 0:
		return .Zero
	case size < TEXT_SIZE_MINIMUM:
		return .Too_Small
	case size > TEXT_SIZE_LIMIT:
		return .Too_Large
	}
	return .None
}

// size_of_scale gives the text size of a scale of the grid of cells: 1 024,
// 2 048 and 3 072 for the scales 1, 2 and 3.
size_of_scale :: #force_inline proc "contextless" (scale: int) -> int {
	return scale * TEXT_SIZE_OF_SCALE_ONE
}

// line_rows gives the rows of pixels of a line of a size: the size rounded
// up to a whole pixel, so that the line holds the ink of the size.
line_rows :: #force_inline proc "contextless" (size: int) -> int {
	return (size + SUBPIXEL - 1) / SUBPIXEL
}

// cell_columns gives the width of a cell of a face of cells at a size, in
// whole pixels: half the line, a half up. At the sizes of the scales 1, 2
// and 3 it is the cell of the grid: 8, 16 and 24 pixels.
cell_columns :: #force_inline proc "contextless" (size: int) -> int {
	return (size + SUBPIXEL) / (2 * SUBPIXEL)
}

// ---- The fonts, the faces and the chains.

// The fonts that a chain names: one member for each font file that the
// resource of the outlines holds, found there by its name
// (outline_font_name). None ends a chain.
Outline_Font :: enum u8 {
	None,
	B612, // B612 Regular: the interface font.
	B612_Bold, // B612 Bold: the bold weight of the interface font.
	Paper_Mono, // Paper Mono: the font of the cells.
	Paper_Mono_Semibold, // Paper Mono SemiBold: the bold weight of the cells.
}
Outline_Fonts :: bit_set[Outline_Font]
// The font is 4 bits in the key of the private glyph cache.
#assert(int(max(Outline_Font)) < 1 << 4)

// outline_font_name gives the name of the record of a font in the resource
// of the outlines: the name of its file in resources/fonts.
outline_font_name :: proc "contextless" (font: Outline_Font) -> string {
	switch font {
	case .None:
		return ""
	case .B612:
		return "b612"
	case .B612_Bold:
		return "b612_bold"
	case .Paper_Mono:
		return "paper_mono"
	case .Paper_Mono_Semibold:
		return "paper_mono_semibold"
	}
	return ""
}

// The chains of the faces: the faces of cells with and without the grid
// fit share one.
Chain_Kind :: enum u8 {
	Interface,
	Interface_Bold,
	Cells,
	Cells_Bold,
}

// A face: a first font, its frame, its weight and the grid fit. A glyph of
// another font of its chain is drawn in the frame of the first font. None:
// no face, as in a process with no outlines; each of its characters draws
// the replacement glyph.
Face :: enum u8 {
	None                   = 0,
	Interface              = 1, // B612 Regular: proportional.
	Interface_Bold         = 2, // B612 Bold: proportional.
	Cells                  = 3, // Paper Mono with the grid fit.
	Cells_Without_Grid_Fit = 4, // Paper Mono with no grid fit.
	Cells_Bold             = 5, // Paper Mono SemiBold.
}
// The face is 4 bits in the key of the private glyph cache.
#assert(int(max(Face)) < 1 << 4)

// face_of_word is the border of the face, where a word of an export
// becomes a face: a word that names no member, and the member None, which
// measures nothing, are refused.
face_of_word :: proc "contextless" (word: i64) -> (face: Face, ok: bool) {
	for member in Face {
		if member != .None && i64(member) == word {
			return member, true
		}
	}
	return .None, false
}

// The positions of a glyph across a pixel: the step of the color stripes.
// A proportional glyph is at the nearest third of a pixel at each size; a
// glyph of cells is at a whole pixel.
POSITION_LIMIT :: 3
#assert(POSITION_LIMIT == vector_font.PLACED_POSITION_LIMIT)

// position_of gives the whole pixel and the position of a place of text in
// 1/64 of a pixel, with position_count positions in a pixel: the nearest
// position, so the error is at most half of a step. A position_count under
// 1 is taken as 1.
position_of :: proc "contextless" (place: i64, position_count: int) -> (pixel: i64, position: int) {
	count := i64(max(position_count, 1))
	steps := place * count + SUBPIXEL / 2
	nearest := steps >= 0 ? steps / SUBPIXEL : -((-steps + SUBPIXEL - 1) / SUBPIXEL)
	pixel = nearest >= 0 ? nearest / count : -((-nearest + count - 1) / count)
	return pixel, int(nearest - pixel * count)
}

// The form of a face: its first font, its chain, its frame and the grid
// fit.
Face_Form :: struct {
	primary:      Outline_Font, // The first font of each of its chains.
	chain:        Chain_Kind,
	proportional: bool, // Each character has its own advance, and its frame is the cap height; else its frame is the advance, half the line.
	grid_fit:     bool, // The baseline, the x-height and the cap height on whole pixels.
}

@(rodata)
face_forms := [Face]Face_Form {
	.None = {},
	.Interface = {primary = .B612, chain = .Interface, proportional = true, grid_fit = true},
	.Interface_Bold = {primary = .B612_Bold, chain = .Interface_Bold, proportional = true, grid_fit = true},
	.Cells = {primary = .Paper_Mono, chain = .Cells, grid_fit = true},
	.Cells_Without_Grid_Fit = {primary = .Paper_Mono, chain = .Cells, grid_fit = false},
	.Cells_Bold = {primary = .Paper_Mono_Semibold, chain = .Cells_Bold, grid_fit = true},
}

// positions_of gives the positions across a pixel of a face at any size:
// three for a proportional face, one for a face of cells.
positions_of :: #force_inline proc "contextless" (face: Face) -> int {
	return face_forms[face].proportional ? POSITION_LIMIT : 1
}

// The scripts that have chains of their own. A character of no script
// takes the default chain of its face.
Script :: enum u8 {
	Greek, // The Greek letters: U+0391 to U+03A9, U+03B1 to U+03C9, with no U+03A2.
	Cyrillic, // The basic Cyrillic letters: U+0400 to U+045F.
	Box_Drawing, // The box-drawing characters and the block elements: U+2500 to U+259F.
}

// script_name gives the name of a script for the log.
script_name :: proc "contextless" (script: Script) -> string {
	switch script {
	case .Greek:
		return "greek"
	case .Cyrillic:
		return "cyrillic"
	case .Box_Drawing:
		return "box drawing"
	}
	return ""
}

CHAIN_LIMIT :: 4 // The fonts of one chain.
RANGE_LIMIT :: 4 // The runs of one script.

// A chain: its fonts in order, None after the last.
Chain :: [CHAIN_LIMIT]Outline_Font

Character_Range :: struct {
	first, last: rune,
}

// A script: its characters as runs with no gap, and the chain of each face.
Script_Row :: struct {
	ranges:      [RANGE_LIMIT]Character_Range,
	range_count: int,
	chains:      [Chain_Kind]Chain,
}

// The fallback chains by script: the data of the choice of a font. A new
// font is one member of Outline_Font, one record of the resource and its
// place in these rows.
@(rodata)
scripts := [Script]Script_Row {
	.Greek = {ranges = {{0x0391, 0x03A1}, {0x03A3, 0x03A9}, {0x03B1, 0x03C9}, {}}, range_count = 3, chains = {.Interface = {.B612, .Paper_Mono, .None, .None}, .Interface_Bold = {.B612_Bold, .B612, .Paper_Mono_Semibold, .None}, .Cells = {.Paper_Mono, .B612, .None, .None}, .Cells_Bold = {.Paper_Mono_Semibold, .B612_Bold, .B612, .None}}},
	.Cyrillic = {ranges = {{0x0400, 0x045F}, {}, {}, {}}, range_count = 1, chains = {.Interface = {.B612, .Paper_Mono, .None, .None}, .Interface_Bold = {.B612_Bold, .B612, .Paper_Mono_Semibold, .None}, .Cells = {.Paper_Mono, .B612, .None, .None}, .Cells_Bold = {.Paper_Mono_Semibold, .B612_Bold, .B612, .None}}},
	.Box_Drawing = {ranges = {{0x2500, 0x259F}, {}, {}, {}}, range_count = 1, chains = {.Interface = {.Paper_Mono, .None, .None, .None}, .Interface_Bold = {.Paper_Mono_Semibold, .None, .None, .None}, .Cells = {.Paper_Mono, .None, .None, .None}, .Cells_Bold = {.Paper_Mono_Semibold, .None, .None, .None}}},
}

// The chain of each face for a character of no script.
@(rodata)
default_chains := [Chain_Kind]Chain {
	.Interface      = {.B612, .Paper_Mono, .None, .None},
	.Interface_Bold = {.B612_Bold, .Paper_Mono_Semibold, .None, .None},
	.Cells          = {.Paper_Mono, .B612, .None, .None},
	.Cells_Bold     = {.Paper_Mono_Semibold, .B612, .None, .None},
}

// Where a glyph comes from.
Glyph_Source :: enum u8 {
	Missing, // No font of the chain has the character, the character is no character of a text, the size or the position is refused, or the renderer refused its outline: the replacement glyph.
	Private_Cache, // The words of the private glyph cache of this process.
	Not_Kept, // Drawn into the render memory of this copy and not kept: the glyphs of the frame in progress fill the cache. The words are valid until the next draw.
	Banded, // Not kept, no entry and no words: the caller draws it band by band (glyph_bands). A glyph larger than the largest block of the cache, and each glyph before the copy has its glyph memory (memory_give).
}

// One font file of the outlines, opened.
Font :: struct {
	opened: bool,
	file:   vector_font.Font_File,
	hash:   [32]u8, // The hash that its record names.
	own:    vector_font.Font_Measures, // From its outlines: the frame of a font of cells.
	stated: vector_font.Font_Measures, // With the heights that its table OS/2 states and the units of one cell from its cap height: the frame of a proportional font.
	// The pair adjustments of its table kern. Empty for a font with no such
	// table, and for a table that the reader refuses: the font still draws
	// and measures, with no pair.
	pairs:  vector_font.Pair_Table,
}

// Font_Set: the fonts of one resource of outlines, opened. A process has
// one in its state (open); a call of the library module text_rendering
// opens one from the bytes of its caller, for that call only.
Font_Set :: struct {
	opened: bool,
	fonts:  [Outline_Font]Font,
}

// State: the state of this copy of the package. All zero: nothing is
// opened, and no face draws: each caller draws in Spleen.
State :: struct {
	using font_set: Font_Set,
	frame:          u64, // The number of the frame: frame_begin adds one.
}

state: State

// open opens the fonts of the outlines into the state of this copy
// (fonts_open). A second open does nothing: the outlines never change.
open :: proc "contextless" (outlines: ^font_outlines.Outlines) -> (missing: Outline_Fonts) {
	outline := outline_of(&outline_memory)
	return fonts_open(&state.font_set, outlines, &outline)
}

// fonts_open opens the fonts of the outlines into a set, with the memory of
// one outline for the measures of each font. It gives the fonts that the
// outlines do not hold or that the parser refuses: a chain skips them. A
// set that is open stays as it is. wanted names the fonts to open: a call
// of the library module opens the fonts of the chains of one face only
// (fonts_of_face), as each open reads the outlines of 94 characters for
// the measures of its font; a font that is not wanted stays closed, and is
// not missing.
fonts_open :: proc "contextless" (set: ^Font_Set, outlines: ^font_outlines.Outlines, outline: ^vector_font.Outline, wanted: Outline_Fonts = ~Outline_Fonts{}) -> (missing: Outline_Fonts) {
	if set.opened {
		return {}
	}
	for font in Outline_Font {
		if font == .None || font not_in wanted {
			continue
		}
		missing += {font}
		name := outline_font_name(font)
		for index in 0 ..< min(outlines.count, font_outlines.FONT_LIMIT) {
			record := &outlines.records[index]
			if font_outlines.name_of(record) != name {
				continue
			}
			if font_file_open(set, font, font_outlines.font_bytes(outlines, index), outline) == .None {
				set.fonts[font].hash = record.hash
				missing -= {font}
			}
		}
	}
	set.opened = true
	return missing
}

// font_file_open opens one font file as a font of a set, with the memory
// of one outline for its measures, and marks the set open. A font that the
// parser refuses stays closed, and the problem says why. A candidate font
// that is not in the font outlines draws through the faces with it: the
// demonstration vector_glyphs and the picture of the tool open each
// candidate as the font Paper_Mono of a set of their own, so the faces of
// the cells of that set draw the candidate (glyph_bands_in).
font_file_open :: proc "contextless" (set: ^Font_Set, font: Outline_Font, bytes: []u8, outline: ^vector_font.Outline) -> (problem: vector_font.Font_Problem) {
	set.opened = true
	if font == .None {
		return .Unknown_Format
	}
	opened := &set.fonts[font]
	opened^ = {}
	file: vector_font.Font_File
	file, problem = vector_font.font_open(bytes)
	if problem != .None {
		return problem
	}
	own, stated: vector_font.Font_Measures
	own, problem = vector_font.font_measures_of_outline(&file, outline)
	if problem != .None {
		return problem
	}
	stated, problem = vector_font.proportional_measures(&file, own)
	if problem != .None {
		return problem
	}
	pairs, pair_problem := vector_font.pair_table_open(&file)
	if pair_problem != .None {
		pairs = {}
	}
	opened^ = {opened = true, file = file, own = own, stated = stated, pairs = pairs}
	return .None
}

// face_opened says if this copy can draw a face: the outlines are open and
// hold the first font of the face, whose frame places each glyph of the
// face. false for the face None. A face that is not opened draws nothing,
// so its caller draws in Spleen or in the font of the cells.
face_opened :: proc "contextless" (face: Face) -> bool {
	return face != .None && state.opened && state.fonts[face_forms[face].primary].opened
}

// frame_begin starts a frame of the process: the order of use of the
// private glyph cache counts in frames, and a glyph of the frame in
// progress is never evicted.
frame_begin :: proc "contextless" () {
	state.frame += 1
	cache_state.frame_full = false
}

// character_valid says if a character can have a glyph: a character of a
// text (no control character, no surrogate, at most the last code point).
@(private)
character_valid :: #force_inline proc "contextless" (character: rune) -> bool {
	return character > 0 && text_encoding.character_in_text(character)
}

// script_of gives the script of a character; found is false for a
// character of no script.
script_of :: proc "contextless" (character: rune) -> (script: Script, found: bool) {
	for each in Script {
		row := scripts[each]
		for index in 0 ..< min(row.range_count, RANGE_LIMIT) {
			if character >= row.ranges[index].first && character <= row.ranges[index].last {
				return each, true
			}
		}
	}
	return {}, false
}

// chain_of gives the chain of a face for a character.
chain_of :: proc "contextless" (face: Face, character: rune) -> Chain {
	kind := face_forms[face].chain
	if script, found := script_of(character); found {
		return scripts[script].chains[kind]
	}
	return default_chains[kind]
}

// chain_fonts gives the fonts that the chains of a face can name, for each
// script and for the default chain, that the outlines hold: each font from
// which the face can draw a glyph. None for the face None and before open.
chain_fonts :: proc "contextless" (face: Face) -> (fonts: Outline_Fonts) {
	if face == .None || !state.opened {
		return {}
	}
	for font in fonts_of_face(face) {
		if state.fonts[font].opened {
			fonts += {font}
		}
	}
	return fonts
}

// fonts_of_face gives the fonts that the chains of a face name, for each
// script and for the default chain, whether a set holds them or not: the
// fonts that a measure of the face can read. None for the face None.
fonts_of_face :: proc "contextless" (face: Face) -> (fonts: Outline_Fonts) {
	if face == .None {
		return {}
	}
	chain_add :: proc "contextless" (fonts: ^Outline_Fonts, chain: Chain) {
		for font in chain {
			if font != .None {
				fonts^ += {font}
			}
		}
	}
	kind := face_forms[face].chain
	for script in Script {
		chain_add(&fonts, scripts[script].chains[kind])
	}
	chain_add(&fonts, default_chains[kind])
	return fonts
}

// font_glyph_of gives the first font of the chain of a face that has a
// glyph for a character, and the index of that glyph in that font: None
// for no font, for the face None, for a character that is no character of
// a text, before open, and for a face whose first font the outlines lack:
// its frame places each glyph of the face.
font_glyph_of :: proc "contextless" (face: Face, character: rune) -> (font: Outline_Font, glyph_index: int) {
	return font_glyph_in(&state.font_set, face, character)
}

// font_glyph_in is font_glyph_of over a set of fonts.
font_glyph_in :: proc "contextless" (set: ^Font_Set, face: Face, character: rune) -> (font: Outline_Font, glyph_index: int) {
	if face == .None || !set.opened || !character_valid(character) || !set.fonts[face_forms[face].primary].opened {
		return .None, 0
	}
	chain := chain_of(face, character)
	for each in chain {
		if each == .None {
			break
		}
		opened := &set.fonts[each]
		if !opened.opened {
			continue
		}
		if index, problem := vector_font.glyph_of(&opened.file, character); problem == .None {
			return each, index
		}
	}
	return .None, 0
}

// font_of gives the first font of the chain of a face that has a glyph for
// a character (font_glyph_of).
font_of :: proc "contextless" (face: Face, character: rune) -> Outline_Font {
	font, _ := font_glyph_of(face, character)
	return font
}

// has says if a face has a glyph for a character.
has :: proc "contextless" (face: Face, character: rune) -> bool {
	return font_of(face, character) != .None
}

// measures_in_frame gives the measures with which a font draws in a face:
// the frame of the first font; for another font, its stated heights and
// the units of one cell that put its cap height on the cap height of the
// first font.
@(private)
measures_in_frame :: proc "contextless" (face: Face, font: Outline_Font) -> vector_font.Font_Measures {
	return measures_in_frame_of(&state.font_set, face, font)
}

// measures_in_frame_of is measures_in_frame over a set of fonts.
@(private)
measures_in_frame_of :: proc "contextless" (set: ^Font_Set, face: Face, font: Outline_Font) -> vector_font.Font_Measures {
	form := face_forms[face]
	first := &set.fonts[form.primary]
	primary := form.proportional ? first.stated : first.own
	if font == form.primary {
		return primary
	}
	measures := set.fonts[font].stated
	// The open accepted each font only with a cap height above 0, so the
	// divisor is not 0; the units of a cell stay above 0, as they divide an
	// advance.
	measures.advance = max(int(vector_font.divide_rounded(i64(measures.cap_height) * i64(primary.advance), i64(max(primary.cap_height, 1)))), 1)
	return measures
}

// units_at_size gives a length in units of a font in 1/64 of a pixel at a
// text size, in a frame of units_per_cell units for the width of a cell:
// units * (size / 2) / units_per_cell, rounded to the nearest integer, a
// half up (vector_font.divide_rounded). A cell is half the line, so at the
// size of a scale s it is units * 8 * s * 64 / units_per_cell: the advance
// of the scales of the grid.
units_at_size :: #force_inline proc "contextless" (units, size, units_per_cell: int) -> i64 {
	return vector_font.divide_rounded(i64(units) * i64(size), 2 * i64(max(units_per_cell, 1)))
}

// advance_limit_of_size gives the bound of an advance at a size: one line.
// The widest advance of the fonts of the system is under it (B612: 2 000
// units, a line is 2 400). A font that states more is hostile; its advance
// is kept in that bound, so no sum along a text wraps (shaping.odin).
advance_limit_of_size :: #force_inline proc "contextless" (size: int) -> i64 {
	return i64(size)
}

// pair_limit_of_size gives the bound of a pair adjustment at a size, on
// each side of 0: half a line. The largest pair of the fonts of the system
// is 200 units, a twelfth of a line of B612.
pair_limit_of_size :: #force_inline proc "contextless" (size: int) -> i64 {
	return i64(size) / 2
}

// advance gives the advance of a character of a face at a text size, in
// 1/64 of a pixel, from the font file of its chain: the same at each
// measure, whatever the private glyph cache holds. A face of cells has the
// advance of a cell, half the line. found is false for a character that no
// font of the chain has, and for a size that size_check refuses.
advance :: proc "contextless" (face: Face, character: rune, size: int) -> (value: i32, found: bool) {
	font, glyph_index := font_glyph_of(face, character)
	return glyph_advance_in(&state.font_set, face, font, glyph_index, size)
}

// glyph_advance_in gives the advance of a glyph of a font of the chain of
// a face, in a set of fonts, at a text size, in 1/64 of a pixel: the
// advance of its table hmtx, scaled to the frame of the face, rounded once,
// and kept from 0 to one line. found is false for the font None and for a
// size that size_check refuses.
glyph_advance_in :: proc "contextless" (set: ^Font_Set, face: Face, font: Outline_Font, glyph_index, size: int) -> (value: i32, found: bool) {
	if size_check(size) != .None || font == .None || face == .None {
		return 0, false
	}
	if !face_forms[face].proportional {
		return i32(vector_font.divide_rounded(i64(size), 2)), true
	}
	units := vector_font.glyph_advance(&set.fonts[font].file, glyph_index)
	return i32(clamp(units_at_size(units, size, measures_in_frame_of(set, face, font).advance), 0, advance_limit_of_size(size))), true
}

// glyph_pair_in gives the pair adjustment of two glyphs of one font of the
// chain of a proportional face, in a set of fonts, at a text size, in 1/64
// of a pixel: the pair of its table kern, scaled and rounded as an advance,
// and kept within half a line on each side. 0 for two fonts, for a face of
// cells (each character is one cell), and for a pair that the table lacks.
glyph_pair_in :: proc "contextless" (set: ^Font_Set, face: Face, font: Outline_Font, left_index, right_index, size: int) -> i32 {
	if font == .None || face == .None || !face_forms[face].proportional || size_check(size) != .None {
		return 0
	}
	units := vector_font.pair_adjustment(&set.fonts[font].pairs, left_index, right_index)
	if units == 0 {
		return 0
	}
	limit := pair_limit_of_size(size)
	return i32(clamp(units_at_size(units, size, measures_in_frame_of(set, face, font).advance), -limit, limit))
}

// coverage counts the characters of a script that the chain of a face
// draws.
coverage :: proc "contextless" (face: Face, script: Script) -> (drawn, total: int) {
	row := scripts[script]
	for index in 0 ..< min(row.range_count, RANGE_LIMIT) {
		range := row.ranges[index]
		for character in range.first ..= range.last {
			total += 1
			if has(face, character) {
				drawn += 1
			}
		}
	}
	return drawn, total
}

// glyph gives the glyph of a character of a face at a text size and a
// position across a pixel, and its first word, from the private glyph
// cache, where it is drawn at its first use. The words of a row are
// entry.width words from words + row * entry.width. source is Missing for
// a face, a size, a position or a character that has no glyph, and for an
// outline that the renderer refuses.
glyph :: proc "contextless" (face: Face, character: rune, size, position: int) -> (entry: Glyph_Entry, words: [^]u32, source: Glyph_Source) {
	if face == .None || size_check(size) != .None || position < 0 || position >= positions_of(face) {
		return {}, nil, .Missing
	}
	font, glyph_index := font_glyph_of(face, character)
	if font == .None {
		return {}, nil, .Missing
	}
	return private_glyph(face, font, glyph_index, size, position)
}
