package display

import "modus:contract/demand_cache"
import "modus:contract/fixed_addresses"
import "modus:contract/font_outlines"
import "modus:support/fallback_glyphs"
import "modus:support/graphics"
import "modus:support/system"

// The glyphs past the glyph caches (src/md/features/glyphs_on_demand.md):
// the side of a program. The starter maps the font outlines and the demand
// cache read-only beside the glyph caches; text_settings_load opens them,
// and then each spacing and each draw of the program finds the fallback
// face of its glyph cache with no other call. A frame starts with
// text_frame_begin: interface.window_frame_begin and the drawing module
// call it, and a program that draws text by hand calls it at its frame.

// fallback_load opens the font outlines and the demand cache that the
// starter mapped. The problem is Not_Mapped when the starter gave no
// outlines: each character past the glyph caches then draws the
// replacement glyph. missing names the fonts of the chains that the
// outlines lack or that the renderer refuses.
@(private)
fallback_load :: proc "contextless" (ctx: ^system.Context) -> (problem: font_outlines.Problem, missing: fallback_glyphs.Outline_Fonts) {
	outlines: font_outlines.Outlines
	outlines, problem = font_outlines.open(&ctx.values)
	if problem.kind != .None {
		return problem, {}
	}
	demand_base: uintptr
	if .Demand_Cache in fixed_addresses.ranges_mapped(&ctx.values) {
		demand_base = uintptr(demand_cache.ADDRESS)
	}
	return {}, fallback_glyphs.open(&outlines, demand_base)
}

// text_frame_begin starts a frame of the text of the program: the order of
// use of its private glyph cache counts in frames, and the demand cache
// gives one generation to the draws of the frame.
text_frame_begin :: proc "contextless" () {
	fallback_glyphs.frame_begin()
}

// Cell_Fallback: what the program draws for a character in a cell past the
// glyph cache of cells, at scale 1.
Cell_Fallback :: struct {
	font:   fallback_glyphs.Outline_Font, // The font of the chain of the cells that has it; None: the replacement glyph.
	source: fallback_glyphs.Glyph_Source, // Where its words are.
	rows:   int, // Its rows of ink.
	inside: bool, // Its glyph starts at the left of its cell and is at most as wide as the cell.
}

// cell_fallback_of draws a character as a cell of the program draws it,
// in the private glyph cache of the program, and says where it comes from:
// the terminal says it once on its log.
cell_fallback_of :: proc "contextless" (character: rune) -> Cell_Fallback {
	face := graphics.cell_face()
	entry, _, source := fallback_glyphs.glyph(face, character, 1, 0)
	return {font = fallback_glyphs.font_of(face, character), source = source, rows = int(entry.row_count), inside = entry.left == 0 && int(entry.width) <= graphics.CELL_WIDTH}
}
