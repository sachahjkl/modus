package fuzz

import "core:fmt"
import "core:slice"
import "modus:contract/blake3"
import "modus:contract/font_outlines"
import "modus:contract/font_characters"
import "modus:vector_font"

// The fuzz targets of the fonts (src/md/infrastructure/fuzzing.md, "The
// targets, in order of value"): each process with text reads the font
// files of the outlines with the vector font reader, and validates the
// font outlines once, then trusts each entry. A signed image writes them
// today; a fault there still stops a service.

// fuzz_aligned_input gives an input on a multiple of 8: the readers of the
// outlines and of a theme refuse other memory, as the
// starter maps them on a page. An input that is aligned already is given
// as it is, so the page with no access beside it still catches a read past
// its ends; only another input is copied, and loses that guard.
fuzz_aligned_input :: proc(input: []u8) -> []u8 {
	if uintptr(raw_data(input)) % 8 == 0 {
		return input
	}
	words := make([]u64, (len(input) + 7) / 8, context.temp_allocator)
	bytes := slice.to_bytes(words)[:len(input)]
	copy(bytes, input)
	return bytes
}

// ---------------------------------------------------------------------
// The vector font reader.

// The font of a seed: the smallest font file of resources/fonts.
@(private = "file")
fuzz_font_seed := #load("../../../resources/fonts/commit_mono.ttf")

// The memory of the renderer: one for the process, as a service keeps it.
@(private = "file")
fuzz_font_memory: ^vector_font.Render_Memory

fuzz_vector_font_start :: proc() -> bool {
	fuzz_font_memory = new(vector_font.Render_Memory)
	return fuzz_font_memory != nil
}

// The characters that the target asks of a font: the edges of the code
// points, the characters that font_measures reads, and some past ASCII.
@(rodata, private = "file")
fuzz_font_characters := [?]rune{0, ' ', 'A', 'V', 'g', 'x', 'H', 0xE9, font_characters.EURO_SIGN, 0xFFFD, 0xFFFF, 0x10000, 0x10FFFF}

// fuzz_vector_font_execute: a font that font_open accepts gives each glyph,
// outline, advance, pair and substitution with no fault, and an outline in
// the memory of the caller; a font whose measures it reads draws a glyph.
fuzz_vector_font_execute :: proc(input: []u8) -> Fuzz_Verdict {
	font, problem := vector_font.font_open(input)
	if problem > max(vector_font.Font_Problem) {
		return fuzz_broken(.Contract, "font_open gives a problem out of its enumeration: %d", u8(problem))
	}
	if problem != .None {
		return FUZZ_PASSED
	}
	memory := fuzz_font_memory
	outline := vector_font.Outline{points = memory.points[:], contour_ends = memory.contours[:]}
	glyphs := make([dynamic]int, context.temp_allocator)
	append(&glyphs, 0, 1, font.glyph_count - 1, font.glyph_count, int(max(u16)))
	for character in fuzz_font_characters {
		glyph, glyph_problem := vector_font.glyph_of(&font, character)
		if glyph_problem == .None {
			if glyph < 0 || glyph >= font.glyph_count {
				return fuzz_broken(.Contract, "glyph_of gives the glyph %d of %d", glyph, font.glyph_count)
			}
			append(&glyphs, glyph)
		}
		_ = vector_font.character_advance(&font, character)
	}
	for glyph in glyphs {
		// A glyph number of the file is a word of 16 bits: never negative.
		if glyph < 0 {
			continue
		}
		_ = vector_font.glyph_advance(&font, glyph)
		_, _ = vector_font.glyph_data(&font, glyph)
		if vector_font.glyph_outline(&font, glyph, &outline) == .None {
			if outline.point_count < 0 || outline.point_count > len(outline.points) || outline.contour_count < 0 || outline.contour_count > len(outline.contour_ends) {
				return fuzz_broken(.Contract, "the outline of the glyph %d has %d points and %d contours", glyph, outline.point_count, outline.contour_count)
			}
		}
		for tag in ([?]vector_font.Feature_Tag{{'s', 's', '0', '1'}, {'z', 'e', 'r', 'o'}}) {
			if substitute, substitution_problem := vector_font.single_substitution(&font, tag, glyph); substitution_problem == .None && (substitute < 0 || substitute >= font.glyph_count) {
				return fuzz_broken(.Contract, "single_substitution gives the glyph %d of %d", substitute, font.glyph_count)
			}
		}
	}
	if pairs, pairs_problem := vector_font.pair_table_open(&font); pairs_problem == .None {
		_ = vector_font.character_pair_adjustment(&font, &pairs, 'A', 'V')
		_ = vector_font.pair_adjustment(&pairs, 0, max(int))
	}
	measures, measures_problem := vector_font.font_measures(&font, memory)
	if measures_problem != .None {
		return FUZZ_PASSED
	}
	style := vector_font.glyph_style_of(measures, 8, 16, false)
	pixels: [8 * 16]u32
	_ = vector_font.glyph_render(&font, measures, style, 'A', memory, pixels[:])
	return FUZZ_PASSED
}

fuzz_vector_font_seeds :: proc(seeds: ^[dynamic][]u8) {
	append(seeds, slice.clone(fuzz_font_seed), slice.clone(fuzz_font_seed[:12]), make([]u8, 0))
}

// ---------------------------------------------------------------------
// The font outlines.

// fuzz_font_outlines_execute: a resource that validate accepts gives each
// font file inside it, and its fonts written again by resource_write give
// a resource that validate accepts with the same names and the same bytes.
fuzz_font_outlines_execute :: proc(input: []u8) -> Fuzz_Verdict {
	bytes := fuzz_aligned_input(input)
	outlines, problem := font_outlines.validate(bytes)
	if problem.kind > max(font_outlines.Problem_Kind) {
		return fuzz_broken(.Contract, "validate gives a problem out of its enumeration: %d", u8(problem.kind))
	}
	if problem.kind != .None {
		if outlines.header != {} || outlines.count != 0 {
			return fuzz_broken(.Contract, "validate refuses with %v and gives records", problem.kind)
		}
		return FUZZ_PASSED
	}
	fonts := make([]font_outlines.Font_Input, outlines.count, context.temp_allocator)
	for &record, index in outlines.records[:outlines.count] {
		fonts[index] = {name = font_outlines.name_of(&record), bytes = font_outlines.font_bytes(&outlines, index)}
	}
	out := fuzz_aligned_input(make([]u8, font_outlines.resource_size(fonts), context.temp_allocator))
	if _, written := font_outlines.resource_write(fonts, out); !written {
		return fuzz_broken(.Round_Trip, "resource_write refuses the fonts of a resource that validate accepted")
	}
	again, again_problem := font_outlines.validate(out)
	if again_problem.kind != .None || again.count != len(fonts) {
		return fuzz_broken(.Round_Trip, "validate refuses what resource_write wrote: %v", again_problem.kind)
	}
	for &record, index in again.records[:again.count] {
		font := font_outlines.font_bytes(&again, index)
		if font_outlines.name_of(&record) != fonts[index].name || !slice.equal(font, fonts[index].bytes) || record.hash != blake3.hash(font) {
			return fuzz_broken(.Round_Trip, "the font %d written again differs", index)
		}
	}
	return FUZZ_PASSED
}

fuzz_font_outlines_seeds :: proc(seeds: ^[dynamic][]u8) {
	for count in ([?]int{1, 3, font_outlines.FONT_LIMIT}) {
		fonts := make([]font_outlines.Font_Input, count, context.temp_allocator)
		for &font, index in fonts {
			font = {name = fmt.tprintf("font_%d", index), bytes = fuzz_font_seed[index * 16:][:16 + index]}
		}
		out := fuzz_aligned_input(make([]u8, font_outlines.resource_size(fonts), context.temp_allocator))
		_, _ = font_outlines.resource_write(fonts, out)
		append(seeds, slice.clone(out))
	}
	append(seeds, make([]u8, font_outlines.HEADER_SIZE - 1))
}

fuzz_font_outlines_regions :: proc(input: []u8, regions: ^[dynamic]Fuzz_Region) {
	if len(input) < font_outlines.HEADER_SIZE {
		return
	}
	append(regions, Fuzz_Region{offset = 0, type = font_outlines.Header, count = 1})
	records := min(font_outlines.FONT_LIMIT, (len(input) - font_outlines.HEADER_SIZE) / font_outlines.RECORD_SIZE)
	if records > 0 {
		append(regions, Fuzz_Region{offset = font_outlines.RECORDS_OFFSET, type = font_outlines.Font_Record, count = records})
	}
}
