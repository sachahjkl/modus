package vector_font

import "modus:contract/demand_cache"
import "modus:contract/glyph_cache"

// The glyphs of a character past the glyph cache, drawn at the request of
// a program into the demand cache (src/md/features/glyphs_on_demand.md). The
// font service draws them with the renderer and the style of the build:
// the same font file gives the same words as its proportional glyph cache.

// Demand_Font: a proportional font, placed on the grid as its glyph cache
// places it (glyph_cache_build_proportional).
Demand_Font :: struct {
	font:     Font_File,
	measures: Font_Measures, // proportional_measures: the advance is the units of one cell.
	styles:   [demand_cache.SIZE_COUNT]Glyph_Style, // The style of each scale.
	flags:    u32, // The flags of its glyph cache: the demand cache states them.
}

// demand_font_open reads a proportional font file and computes its place
// on the grid, with or without the grid fit, as the build does.
demand_font_open :: proc "contextless" (bytes: []u8, grid_fit: bool, memory: ^Render_Memory) -> (demand: Demand_Font, problem: Font_Problem) {
	demand.font, problem = font_open(bytes)
	if problem != .None {
		return {}, problem
	}
	measures: Font_Measures
	measures, problem = font_measures(&demand.font, memory)
	if problem != .None {
		return {}, problem
	}
	demand.measures, problem = proportional_measures(&demand.font, measures)
	if problem != .None {
		return {}, problem
	}
	for &style, index in demand.styles {
		scale := index + 1
		style = glyph_style_of(demand.measures, 8 * scale, 16 * scale, grid_fit)
	}
	demand.flags = (grid_fit ? glyph_cache.FLAG_GRID_FIT : 0) | glyph_cache.FLAG_PROPORTIONAL | u32(Stripe_Filter.Five_Taps) << glyph_cache.FILTER_SHIFT
	return demand, .None
}

// Demand_Result: what demand_glyph_draw did with a character.
Demand_Result :: enum u8 {
	Drawn, // Its glyphs and its advances are in the entry, its words in the cache.
	Absent, // The font has no glyph for it, or its glyph does not fit the limits of a glyph: an entry Absent.
	Refused, // Its words do not fit the cache: no word is kept.
}

// demand_glyph_draw draws the glyphs of one character at each scale and
// each position of the demand cache, writes their words in the cache, and
// gives the entry to publish. A refusal gives back the words that it took.
demand_glyph_draw :: proc "contextless" (demand: ^Demand_Font, writer: ^demand_cache.Writer, character: rune, memory: ^Render_Memory) -> (entry: demand_cache.Entry, result: Demand_Result) {
	if _, problem := glyph_of(&demand.font, character); problem != .None {
		return {state = .Absent}, .Absent
	}
	words_before := writer.words_used
	entry.state = .Drawn
	for scale in 1 ..= demand_cache.SIZE_COUNT {
		style := demand.styles[scale - 1]
		entry.advances[scale - 1] = units_to_subpixels(character_advance(&demand.font, character), scale, demand.measures.advance)
		position_count := demand_cache.position_count_of(scale)
		for position in 0 ..< position_count {
			place, _ := demand_cache.glyph_place_of(scale, position)
			box, problem := glyph_render_placed(&demand.font, demand.measures, style, character, position, position_count, memory)
			if problem != .None {
				writer.words_used = words_before
				return {state = .Absent}, .Absent
			}
			if box.row_count == 0 {
				continue // No ink: a space. Its glyph entry stays all zero.
			}
			count := box.row_count * box.width
			offset, taken := demand_cache.words_take(writer, count)
			if !taken {
				writer.words_used = words_before
				return {}, .Refused
			}
			entry.glyphs[place] = {first_row = u16(box.first_row), row_count = u16(box.row_count), word_offset = u32(offset), left = i16(box.left), width = u16(box.width)}
			for row in 0 ..< box.row_count {
				start := offset + row * box.width
				source := (box.first_row + row) * PLACED_WIDTH_LIMIT + box.first_column
				copy(writer.words[start:start + box.width], memory.placed[source:source + box.width])
			}
		}
	}
	return entry, .Drawn
}
