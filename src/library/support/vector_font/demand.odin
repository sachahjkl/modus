package vector_font

import "modus:contract/demand_cache"
import "modus:contract/glyph_cache"

// The glyphs of a character past the glyph cache, drawn at the request of
// a program into the demand cache (src/md/features/glyphs_on_demand.md). The
// font service draws them with the renderer and the style of the build:
// the same font file gives the same words as the glyph cache of the face.

// Demand_Font: the font file of one face, placed on the grid as its glyph
// cache places it: glyph_cache_build_proportional for the face Interface,
// glyph_cache_build for a face of cells.
Demand_Font :: struct {
	font:     Font_File,
	face:     demand_cache.Face,
	measures: Font_Measures, // For a proportional face, proportional_measures: the advance is the units of one cell.
	styles:   [demand_cache.SIZE_COUNT]Glyph_Style, // The style of each scale of the face.
	flags:    u32, // The flags of its glyph cache: the demand cache states them.
}

// demand_font_open reads the font file of a face and computes its place on
// the grid, with or without the grid fit of the face, as the build does.
demand_font_open :: proc "contextless" (bytes: []u8, face: demand_cache.Face, memory: ^Render_Memory) -> (demand: Demand_Font, problem: Font_Problem) {
	form := demand_cache.face_forms[face]
	demand.face = face
	demand.font, problem = font_open(bytes)
	if problem != .None {
		return {}, problem
	}
	demand.measures, problem = font_measures(&demand.font, memory)
	if problem != .None {
		return {}, problem
	}
	if form.proportional {
		demand.measures, problem = proportional_measures(&demand.font, demand.measures)
		if problem != .None {
			return {}, problem
		}
	}
	for scale in 1 ..= form.scale_count {
		demand.styles[scale - 1] = glyph_style_of(demand.measures, 8 * scale, 16 * scale, form.grid_fit)
	}
	demand.flags = (form.grid_fit ? glyph_cache.FLAG_GRID_FIT : 0) | (form.proportional ? glyph_cache.FLAG_PROPORTIONAL : 0) | u32(Stripe_Filter.Five_Taps) << glyph_cache.FILTER_SHIFT
	return demand, .None
}

// Demand_Result: what demand_glyph_draw did with a character.
Demand_Result :: enum u8 {
	Drawn, // Its glyphs and its advances are in the entry, its words in the cache.
	Absent, // The font has no glyph for it, or its glyph does not fit the limits of a glyph: an entry Absent.
	Refused, // Its words do not fit the cache: no word is kept.
}

// demand_glyph_draw draws the glyphs of one character at each scale and
// each position of the face of the font, writes their words in the cache,
// and gives the entry to publish. A refusal gives back the words that it
// took.
demand_glyph_draw :: proc "contextless" (demand: ^Demand_Font, writer: ^demand_cache.Writer, character: rune, memory: ^Render_Memory) -> (entry: demand_cache.Entry, result: Demand_Result) {
	if _, problem := glyph_of(&demand.font, character); problem != .None {
		return {state = .Absent}, .Absent
	}
	words_before := writer.words_used
	entry.state = .Drawn
	if demand_cache.face_forms[demand.face].proportional {
		result = proportional_glyphs_draw(demand, writer, character, memory, &entry)
	} else {
		result = cell_glyphs_draw(demand, writer, character, memory, &entry)
	}
	switch result {
	case .Drawn:
		return entry, .Drawn
	case .Absent:
		writer.words_used = words_before
		return {state = .Absent}, .Absent
	case .Refused:
	}
	writer.words_used = words_before
	return {}, .Refused
}

// proportional_glyphs_draw draws a character of a proportional face at
// each scale and each position: each glyph the box of its ink, as
// glyph_cache_build_proportional keeps it.
@(private = "file")
proportional_glyphs_draw :: proc "contextless" (demand: ^Demand_Font, writer: ^demand_cache.Writer, character: rune, memory: ^Render_Memory, entry: ^demand_cache.Entry) -> Demand_Result {
	form := demand_cache.face_forms[demand.face]
	for scale in 1 ..= form.scale_count {
		style := demand.styles[scale - 1]
		entry.advances[scale - 1] = units_to_subpixels(character_advance(&demand.font, character), scale, demand.measures.advance)
		position_count := demand_cache.position_count_of(demand.face, scale)
		for position in 0 ..< position_count {
			place, _ := demand_cache.glyph_place_of(scale, position)
			box, problem := glyph_render_placed(&demand.font, demand.measures, style, character, position, position_count, memory)
			if problem != .None {
				return .Absent
			}
			if box.row_count == 0 {
				continue // No ink: a space. Its glyph entry stays all zero.
			}
			count := box.row_count * box.width
			offset, taken := demand_cache.words_take(writer, count)
			if !taken {
				return .Refused
			}
			entry.glyphs[place] = {first_row = u16(box.first_row), row_count = u16(box.row_count), word_offset = u32(offset), left = i16(box.left), width = u16(box.width)}
			for row in 0 ..< box.row_count {
				start := offset + row * box.width
				source := (box.first_row + row) * PLACED_WIDTH_LIMIT + box.first_column
				copy(writer.words[start:start + box.width], memory.placed[source:source + box.width])
			}
		}
	}
	return .Drawn
}

// cell_glyphs_draw draws a character of a face of cells at each scale of
// the face, as glyph_cache_build draws a character of a cache of cells:
// the ink cut to the cell, only the rows with ink, each row the width of
// the cell from its left, the advance the width of the cell. The work
// memory of a proportional glyph holds the cell: it is not used here
// otherwise.
@(private = "file")
cell_glyphs_draw :: proc "contextless" (demand: ^Demand_Font, writer: ^demand_cache.Writer, character: rune, memory: ^Render_Memory, entry: ^demand_cache.Entry) -> Demand_Result {
	#assert(PLACED_WIDTH_LIMIT >= CELL_WIDTH_LIMIT)
	form := demand_cache.face_forms[demand.face]
	for scale in 1 ..= form.scale_count {
		style := demand.styles[scale - 1]
		width := style.cell_width
		entry.advances[scale - 1] = i32(width * glyph_cache.SUBPIXEL)
		place, _ := demand_cache.glyph_place_of(scale, 0)
		pixels := memory.placed[:width * style.cell_height]
		if glyph_render(&demand.font, demand.measures, style, character, memory, pixels) != .None {
			return .Absent
		}
		first, last := style.cell_height, -1
		for row in 0 ..< style.cell_height {
			for word in pixels[row * width:][:width] {
				if word != 0 {
					first = min(first, row)
					last = max(last, row)
				}
			}
		}
		if last < first {
			continue // No ink: a space. Its glyph entry stays all zero.
		}
		count := (last - first + 1) * width
		offset, taken := demand_cache.words_take(writer, count)
		if !taken {
			return .Refused
		}
		entry.glyphs[place] = {first_row = u16(first), row_count = u16(last - first + 1), word_offset = u32(offset), left = 0, width = u16(width)}
		copy(writer.words[offset:offset + count], pixels[first * width:][:count])
	}
	return .Drawn
}
