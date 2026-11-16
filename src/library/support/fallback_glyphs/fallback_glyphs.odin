// The glyphs past the glyph cache (src/md/features/glyphs_on_demand.md):
// for a character that no glyph cache holds, the font of its fallback
// chain, its advance from that font file, and its glyph: from the demand
// cache when the font service drew it there, else drawn by this program
// into its private glyph cache.
//
// A program opens it once with the font outlines and the demand cache that
// its starter mapped (open). The shaper asks for an advance (advance), the
// draw for a glyph (glyph), and each frame starts with frame_begin. The
// state is one for each copy of this package: a program has its own, and
// the drawing module that it imports has its own. Both read the same
// outlines, so the measure in the program and the draw in the module give
// the same advances.
//
// The advance comes from the font file at each measure, never from a
// cache: the measure and the draw of a frame agree whatever the cache
// holds. The draw changes the private glyph cache: one thread of a program
// draws at a time, as for the blend tables of the graphics package.
//
// No table of this package holds an address: the drawing module compiles
// it, and a library module holds no data that the loader would write
// (docs/MODULE_CONTRACT.md, "A library as a module"). So the chains are
// fixed arrays and the names come from procedures.
//
// See [fallback chain](term:fallback-chain), [fallback face](term:fallback-face)
// and [private glyph cache](term:private-glyph-cache).
package fallback_glyphs

import "modus:contract/demand_cache"
import "modus:contract/font_outlines"
import "modus:contract/glyph_cache"
import "modus:contract/text_encoding"
import "modus:support/vector_font"

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

// A fallback face: the glyph cache that a glyph past it stands beside. A
// glyph of a face has the form, the baseline and the scale of the glyphs
// of that cache. None: a glyph cache that is not of a font of the outlines,
// or a program with no outlines; its characters past the cache draw the
// replacement glyph.
Face :: enum u8 {
	None,
	Interface, // The glyph cache of B612 Regular: proportional.
	Interface_Bold, // The glyph cache of B612 Bold: proportional, scale 1.
	Cells, // The glyph cache of Paper Mono with the grid fit.
	Cells_Without_Grid_Fit, // The glyph cache of Paper Mono with no grid fit.
	Cells_Bold, // The glyph cache of Paper Mono SemiBold: scale 1.
}

// The form of a face: the form of its glyph cache, its first font, its
// chain, and its face of the demand cache.
Face_Form :: struct {
	primary:      Outline_Font, // The font of its glyph cache: the first font of each of its chains.
	chain:        Chain_Kind,
	proportional: bool, // Each character has its own advance; a glyph is the box of its ink.
	grid_fit:     bool, // The flag FLAG_GRID_FIT of the glyph cache.
	scale_count:  int, // The scales 1 ..= scale_count.
	positions:    [glyph_cache.SIZE_LIMIT]int, // The positions of each scale; 0 past scale_count.
	has_demand:   bool, // The demand cache has a face for it.
	demand:       demand_cache.Face, // That face.
}

@(rodata)
face_forms := [Face]Face_Form {
	.None = {},
	.Interface = {primary = .B612, chain = .Interface, proportional = true, grid_fit = true, scale_count = 3, positions = {3, 1, 1}, has_demand = true, demand = .Interface},
	.Interface_Bold = {primary = .B612_Bold, chain = .Interface_Bold, proportional = true, grid_fit = true, scale_count = 1, positions = {3, 0, 0}},
	.Cells = {primary = .Paper_Mono, chain = .Cells, grid_fit = true, scale_count = 3, positions = {1, 1, 1}, has_demand = true, demand = .Cells},
	.Cells_Without_Grid_Fit = {primary = .Paper_Mono, chain = .Cells, grid_fit = false, scale_count = 3, positions = {1, 1, 1}, has_demand = true, demand = .Cells_Without_Grid_Fit},
	.Cells_Bold = {primary = .Paper_Mono_Semibold, chain = .Cells_Bold, grid_fit = true, scale_count = 1, positions = {1, 0, 0}, has_demand = true, demand = .Cells_Bold},
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
	Missing, // No font of the chain has the character, the character is no character of a text, or the renderer refused its outline: the replacement glyph.
	Demand_Cache, // The words of the demand cache: the first font of the face, drawn by the font service.
	Private_Cache, // The words of the private glyph cache of this program.
}

// One font file of the outlines, opened.
Font :: struct {
	opened: bool,
	file:   vector_font.Font_File,
	hash:   [32]u8, // The hash that its record names.
	own:    vector_font.Font_Measures, // From its outlines: the measures of a font of cells.
	stated: vector_font.Font_Measures, // With the heights that its table OS/2 states and the units of one cell from its cap height: the measures of a proportional font.
}

// State: the state of this copy of the package. All zero: nothing is
// opened, and each character past the glyph cache draws the replacement
// glyph.
State :: struct {
	opened:         bool,
	fonts:          [Outline_Font]Font,
	demand_readers: [Face]demand_cache.Reader,
	demand_open:    [Face]bool,
	frame:          u64, // The number of the frame: frame_begin adds one.
}

state: State
// The private glyph cache and the work memory of the renderer, apart from
// the state: a copy that only measures (the module text_shaping) never
// names them, so its file does not carry them.
private_cache: Private_Cache
render_memory: vector_font.Render_Memory

// open opens the fonts of the outlines and the faces of the demand cache
// mapped at demand_base (0: none). It gives the fonts that the outlines do
// not hold or that the parser refuses: a chain skips them. A second open
// does nothing: the outlines never change.
open :: proc "contextless" (outlines: ^font_outlines.Outlines, demand_base: uintptr) -> (missing: Outline_Fonts) {
	if state.opened {
		return {}
	}
	for font in Outline_Font {
		if font == .None {
			continue
		}
		missing += {font}
		name := outline_font_name(font)
		for &record, index in outlines.records {
			if font_outlines.name_of(&record) != name {
				continue
			}
			opened := &state.fonts[font]
			problem: vector_font.Font_Problem
			opened.file, problem = vector_font.font_open(font_outlines.font_bytes(outlines, index))
			if problem == .None {
				opened.own, problem = vector_font.font_measures(&opened.file, &render_memory)
			}
			if problem == .None {
				opened.stated, problem = vector_font.proportional_measures(&opened.file, opened.own)
			}
			if problem == .None {
				opened.hash = record.hash
				opened.opened = true
				missing -= {font}
			}
		}
	}
	for form, face in face_forms {
		if face == .None || !form.has_demand || !state.fonts[form.primary].opened || demand_base == 0 {
			continue
		}
		state.demand_readers[face], state.demand_open[face] = demand_cache.reader_of(demand_base, form.demand, state.fonts[form.primary].hash, demand_flags_of(face))
	}
	state.opened = true
	return missing
}

// demand_flags_of gives the flags of the glyph cache of a face, as the
// font service states them in the header of the demand cache
// (vector_font.demand_font_open).
@(private)
demand_flags_of :: proc "contextless" (face: Face) -> u32 {
	form := face_forms[face]
	return (form.grid_fit ? glyph_cache.FLAG_GRID_FIT : 0) | (form.proportional ? glyph_cache.FLAG_PROPORTIONAL : 0) | u32(vector_font.Stripe_Filter.Five_Taps) << glyph_cache.FILTER_SHIFT
}

// face_of_cache gives the fallback face of a glyph cache: the face whose
// first font has the hash of the font file of the cache, whose form the
// cache has at each scale. None when no face matches.
face_of_cache :: proc "contextless" (cache: ^glyph_cache.Cache) -> Face {
	if !state.opened || cache == nil || cache.header == nil {
		return .None
	}
	proportional := cache.header.flags & glyph_cache.FLAG_PROPORTIONAL != 0
	grid_fit := cache.header.flags & glyph_cache.FLAG_GRID_FIT != 0
	search: for form, face in face_forms {
		font := &state.fonts[form.primary]
		if face == .None || !font.opened || font.hash != cache.header.font_hash || form.proportional != proportional || form.grid_fit != grid_fit || len(cache.sizes) != form.scale_count {
			continue
		}
		for size, index in cache.sizes {
			if int(size.position_count) != form.positions[index] {
				continue search
			}
		}
		return face
	}
	return .None
}

// frame_begin starts a frame of the program: the order of use of the
// private glyph cache counts in frames, and the demand cache gives one
// generation to each draw of the frame.
frame_begin :: proc "contextless" () {
	state.frame += 1
	for &reader, face in state.demand_readers {
		if state.demand_open[face] {
			demand_cache.reader_frame_begin(&reader)
		}
	}
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

// font_of gives the first font of the chain of a face that has a glyph for
// a character: None for no font, for the face None, for a character that
// is no character of a text, before open, and for a face whose first font
// the outlines lack: its measures place each glyph of the face.
font_of :: proc "contextless" (face: Face, character: rune) -> Outline_Font {
	if face == .None || !state.opened || !character_valid(character) || !state.fonts[face_forms[face].primary].opened {
		return .None
	}
	chain := chain_of(face, character)
	for font in chain {
		if font == .None {
			break
		}
		opened := &state.fonts[font]
		if !opened.opened {
			continue
		}
		if _, problem := vector_font.glyph_of(&opened.file, character); problem == .None {
			return font
		}
	}
	return .None
}

// measures_in_frame gives the measures with which a font draws in a face:
// the measures of its glyph cache for the first font; for another font,
// its stated heights and the units of one cell that put its cap height on
// the cap height of the first font.
@(private)
measures_in_frame :: proc "contextless" (face: Face, font: Outline_Font) -> vector_font.Font_Measures {
	form := face_forms[face]
	first := &state.fonts[form.primary]
	primary := form.proportional ? first.stated : first.own
	if font == form.primary {
		return primary
	}
	measures := state.fonts[font].stated
	// The open accepted each font only with a cap height above 0, so the
	// divisor is not 0; the units of a cell stay above 0, as they divide an
	// advance.
	measures.advance = max(int(vector_font.divide_rounded(i64(measures.cap_height) * i64(primary.advance), i64(max(primary.cap_height, 1)))), 1)
	return measures
}

// style_of gives the style of a face at a scale: the cell, the baseline and
// the grid fit of its first font, for each font of its chain.
@(private)
style_of :: proc "contextless" (face: Face, scale: int) -> vector_font.Glyph_Style {
	form := face_forms[face]
	first := &state.fonts[form.primary]
	primary := form.proportional ? first.stated : first.own
	return vector_font.glyph_style_of(primary, 8 * scale, 16 * scale, form.grid_fit)
}

// has says if a face has a glyph for a character past its glyph cache.
has :: proc "contextless" (face: Face, character: rune) -> bool {
	return font_of(face, character) != .None
}

// advance gives the advance of a character of a face at a scale, in 1/64
// of a pixel, from the font file of its chain: the same at each measure,
// whatever the private glyph cache holds. found is false for a character
// that no font of the chain has, and for a scale that the face does not
// have.
advance :: proc "contextless" (face: Face, character: rune, scale: int) -> (value: i32, found: bool) {
	form := face_forms[face]
	if scale < 1 || scale > form.scale_count {
		return 0, false
	}
	font := font_of(face, character)
	if font == .None {
		return 0, false
	}
	if !form.proportional {
		return i32(8 * scale * glyph_cache.SUBPIXEL), true
	}
	units := vector_font.character_advance(&state.fonts[font].file, character)
	return clamp(vector_font.units_to_subpixels(units, scale, measures_in_frame(face, font).advance), 0, glyph_cache.ADVANCE_LIMIT), true
}

// glyph gives the glyph of a character of a face at a scale and a position
// of a pixel, and its first word: from the demand cache when the font is
// the first font of the face and the demand cache holds it, else from the
// private glyph cache, where it is drawn at its first use. The words of a
// row are entry.width words from words + row * entry.width. source is
// Missing for a face, a scale, a position or a character that has no
// glyph, and for an outline that the renderer refuses.
glyph :: proc "contextless" (face: Face, character: rune, scale, position: int) -> (entry: glyph_cache.Glyph_Entry, words: [^]u32, source: Glyph_Source) {
	form := face_forms[face]
	if scale < 1 || scale > form.scale_count || position < 0 || position >= form.positions[scale - 1] {
		return {}, nil, .Missing
	}
	font := font_of(face, character)
	if font == .None {
		return {}, nil, .Missing
	}
	if font == form.primary && state.demand_open[face] {
		reader := &state.demand_readers[face]
		found, found_state := demand_cache.find(reader, character)
		if found_state == .Drawn {
			if demand_glyph, has_glyph := demand_cache.glyph_of_entry(reader.face, &found, scale, position); has_glyph {
				return demand_glyph, ([^]u32)(&reader.words[int(demand_glyph.word_offset)]), .Demand_Cache
			}
		}
	}
	return private_glyph(face, font, character, scale, position)
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
