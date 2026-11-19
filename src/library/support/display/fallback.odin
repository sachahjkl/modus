package display

import "modus:contract/font_outlines"
import op "modus:contract/operation"
import "modus:support/graphics"
import "modus:support/system"
import "modus:support/text_rendering"

// The glyphs past the glyph caches (src/md/features/glyphs_on_demand.md):
// the side of a process. The starter maps the font outlines read-only
// beside the glyph caches; text_settings_load opens them, and then each
// spacing and each draw of the process finds the fallback face of its
// glyph cache with no other call. The process draws each such glyph
// itself, into its private glyph cache. A frame starts with
// text_frame_begin: interface.window_frame_begin and the drawing module
// call it, and a process that draws text by hand calls it at its frame.

// fallback_load opens the font outlines that the starter mapped. The
// problem is Not_Mapped when the starter gave no outlines: each character
// past the glyph caches then draws the replacement glyph. missing names
// the fonts of the chains that the outlines lack or that the renderer
// refuses.
@(private)
fallback_load :: proc "contextless" (ctx: ^system.Context) -> (problem: font_outlines.Problem, missing: text_rendering.Outline_Fonts) {
	outlines: font_outlines.Outlines
	outlines, problem = font_outlines.open(&ctx.values)
	if problem.kind != .None {
		return problem, {}
	}
	return {}, text_rendering.open(&outlines)
}

// script_coverage_tell writes, for each script of the fallback chains, how
// many of its characters the chain of the interface and the chain of the
// cells draw, and says when no font of the system has the others. One
// process writes it once, after text_settings_open: the compositor, which
// starts once at each boot. The lines start with the name of the caller.
script_coverage_tell :: proc "contextless" (caller: string) {
	for script in text_rendering.Script {
		interface_drawn, total := text_rendering.coverage(.Interface, script)
		cells_drawn, _ := text_rendering.coverage(.Cells, script)
		if interface_drawn == total && cells_drawn == total {
			system.log_in("processes", .Info, caller, ": the script ", text_rendering.script_name(script), ": the chain of the interface draws ", u64(interface_drawn), " of its ", u64(total), " characters, the chain of the cells ", u64(cells_drawn))
		} else {
			system.log_in("processes", .Info, caller, ": the script ", text_rendering.script_name(script), ": the chain of the interface draws ", u64(interface_drawn), " of its ", u64(total), " characters, the chain of the cells ", u64(cells_drawn), "; no font of the system has the others")
		}
	}
}

// text_frame_begin starts a frame of the text of the process: the order of
// use of its private glyph cache counts in frames. It writes no line: the
// drawing module calls it, and a library module holds no table of the
// addresses of texts, which the parts of a line of the log are
// (src/md/api/library_modules.md).
//
// After a frame whose glyph needed the glyph memory, it reserves that
// memory (text_memory_reserve): a copy that never draws a glyph past its
// glyph caches pays nothing for it.
text_frame_begin :: proc "contextless" () {
	if text_rendering.memory_wanted() {
		_ = text_memory_reserve()
	}
	text_rendering.frame_begin()
}

// The pages of the glyph memory of one copy of text_rendering.
TEXT_MEMORY_PAGES :: (size_of(text_rendering.Glyph_Memory) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
// The budgets of the terminal, the compositor and interface_font state two
// glyph memories as integer literals, which the tool reads: a change of
// the glyph memory fails here, so that their sums change with it.
GLYPH_MEMORY_PAGES_IN_THE_BUDGETS :: 354
#assert(TEXT_MEMORY_PAGES == GLYPH_MEMORY_PAGES_IN_THE_BUDGETS)

// The reservation of the glyph memory of this copy: one try only, so a
// budget that cannot pay costs one kernel call, not one at each frame.
text_memory_tried: bool
text_memory_given: bool // The copy has its glyph memory.
text_memory_status: system.Status // The status of a refused reservation; Ok before the try and after a reservation.
text_memory_told: bool // The line of a refused reservation is on the log.

// text_memory_reserve gives this copy of text_rendering its glyph memory:
// a new memory object of TEXT_MEMORY_PAGES pages, which the budget of the
// process pays, mapped with Write. Its pages start at zero, as the
// package needs. It gives true when the copy has its memory. After a
// refusal the copy draws each glyph past its glyph caches band by band,
// with the right pixels, and never tries again.
text_memory_reserve :: proc "contextless" () -> bool {
	if text_memory_given {
		return true
	}
	if text_memory_tried {
		return false
	}
	text_memory_tried = true
	memory, status := system.memory_create(TEXT_MEMORY_PAGES)
	if status != .Ok {
		text_memory_status = status
		return false
	}
	address, mapped := system.memory_map(memory)
	if mapped != .Ok {
		system.close(memory)
		text_memory_status = mapped
		return false
	}
	text_rendering.memory_give((^text_rendering.Glyph_Memory)(address))
	text_memory_given = true
	return true
}

// text_not_kept_tell writes one line on the log of the process, once,
// after the first frame whose glyphs filled its private glyph cache: its
// pixels were right, and it cost more time; and one line, once, when the
// budget refused the glyph memory. A process calls it after
// text_frame_begin; the drawing module does not.
text_not_kept_tell :: proc "contextless" () {
	if count, report := text_rendering.not_kept_report(); report {
		system.log("text_rendering: the glyphs of one frame fill the private glyph cache: ", count, " glyphs drawn and not kept")
	}
	if text_memory_status != .Ok && !text_memory_told {
		text_memory_told = true
		system.log("text_rendering: the glyph memory of ", u64(TEXT_MEMORY_PAGES), " pages is refused: ", op.STATUS_NAMES[text_memory_status], "; each glyph past the glyph caches is drawn band by band")
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
	// The first glyph of the process that needs the glyph memory: the
	// memory now, and the glyph again from the private glyph cache.
	if source == .Banded && text_rendering.memory_wanted() && text_memory_reserve() {
		entry, _, source = text_rendering.glyph(face, character, text_rendering.size_of_scale(1), 0)
	}
	return {font = text_rendering.font_of(face, character), source = source, rows = int(entry.row_count), inside = entry.left == 0 && int(entry.width) <= graphics.CELL_WIDTH}
}
