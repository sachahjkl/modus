package display

import "modus:contract/demand_cache"
import "modus:contract/fixed_addresses"
import "modus:contract/font_outlines"
import "modus:support/graphics"
import "modus:support/system"
import "modus:support/text_rendering"

// The glyphs past the glyph caches (src/md/features/glyphs_on_demand.md):
// the side of a process. The starter maps the font outlines and the demand
// cache read-only beside the glyph caches; text_settings_load opens them,
// and then each spacing and each draw of the process finds the fallback
// face of its glyph cache with no other call. A frame starts with
// text_frame_begin: interface.window_frame_begin and the drawing module
// call it, and a process that draws text by hand calls it at its frame.

// fallback_load opens the font outlines and the demand cache that the
// starter mapped. The problem is Not_Mapped when the starter gave no
// outlines: each character past the glyph caches then draws the
// replacement glyph. missing names the fonts of the chains that the
// outlines lack or that the renderer refuses.
@(private)
fallback_load :: proc "contextless" (ctx: ^system.Context) -> (problem: font_outlines.Problem, missing: text_rendering.Outline_Fonts) {
	outlines: font_outlines.Outlines
	outlines, problem = font_outlines.open(&ctx.values)
	if problem.kind != .None {
		return problem, {}
	}
	demand_base: uintptr
	if .Demand_Cache in fixed_addresses.ranges_mapped(&ctx.values) {
		demand_base = uintptr(demand_cache.ADDRESS)
	}
	return {}, text_rendering.open(&outlines, demand_base)
}

// text_frame_begin starts a frame of the text of the process: the order of
// use of its private glyph cache counts in frames, and the demand cache
// gives one generation to the draws of the frame. It writes no line: the
// drawing module calls it, and a library module holds no table of the
// addresses of texts, which the parts of a line of the log are
// (src/md/api/library_modules.md).
text_frame_begin :: proc "contextless" () {
	text_rendering.frame_begin()
}

// text_not_kept_tell writes one line on the log of the process, once,
// after the first frame whose glyphs filled its private glyph cache: its
// pixels were right, and it cost more time. A process calls it after
// text_frame_begin; the drawing module does not.
text_not_kept_tell :: proc "contextless" () {
	if count, report := text_rendering.not_kept_report(); report {
		system.log("text_rendering: the glyphs of one frame fill the private glyph cache: ", count, " glyphs drawn and not kept")
	}
}

// Cell_Fallback: what the process draws for a character in a cell past the
// glyph cache of cells, at scale 1.
Cell_Fallback :: struct {
	font:   text_rendering.Outline_Font, // The font of the chain of the cells that has it; None: the replacement glyph.
	source: text_rendering.Glyph_Source, // Where its words are.
	rows:   int, // Its rows of ink.
	inside: bool, // Its glyph starts at the left of its cell and is at most as wide as the cell.
}

// cell_fallback_of draws a character as a cell of the process draws it,
// in the private glyph cache of the process, and says where it comes from:
// the terminal says it once on its log.
cell_fallback_of :: proc "contextless" (character: rune) -> Cell_Fallback {
	face := graphics.cell_face()
	entry, _, source := text_rendering.glyph(face, character, text_rendering.size_of_scale(1), 0)
	return {font = text_rendering.font_of(face, character), source = source, rows = int(entry.row_count), inside = entry.left == 0 && int(entry.width) <= graphics.CELL_WIDTH}
}
