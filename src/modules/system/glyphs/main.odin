// The font service (src/md/features/glyphs_on_demand.md, "Layer 1: the
// fixed subsets, shared and read-only"): it draws the fixed subsets past
// the glyph caches into the demand cache, which each process that gets the
// glyph caches maps read-only, then ends.
//
// **What it is for.** Each process draws a character past the glyph
// caches itself, from the font outlines, into its private glyph cache.
// The characters that many processes draw at their start, the
// box-drawing characters of the terminal and the Greek letters of the
// interface font, are drawn here once for all: a process finds them in the
// demand cache with the same bytes. The demand cache holds the same
// entries whatever the processes draw, so it tells no process what another
// draws.
//
// **Its grants**: the demand cache with Read and Write, and the font
// outlines read-only at their fixed range. It has no surface and no ring.
// The root service starts it after the compositor, as a part of the
// system: `start("glyphs")` is refused.
//
// **What a reader sees.** The log has one line for each face:
// `glyphs: the face cells of the demand cache holds each of the 165
// characters of its subset of paper_mono`, or, when a character is
// refused or the font cannot draw it, `glyphs: the face cells of the
// demand cache lacks characters of its subset of paper_mono: <n> drawn,
// <r> refused, <a> that the font cannot draw`. Then one line of the
// totals: `glyphs: the font service drew each face of its subset into the
// demand cache: 542 characters, <w> words of 1048576`. Then one line for
// each script of the fallback chains: `glyphs: the script greek: the chain
// of the interface draws 47 of its 49 characters, the chain of the cells
// 47; no font of the system has the others`. Then it ends with the code 0.
package glyphs

import "modus:contract/blake3"
import "modus:contract/demand_cache"
import "modus:contract/font_outlines"
import "modus:support/text_rendering"
import "modus:support/system"
import "modus:support/vector_font"

// The render memory; the demand cache and the outlines are memory of the
// root service and of the boot image.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 192, processes = 1, threads = 1}

// The font of the outlines of each face: the file of its glyph cache. The
// demand cache names each one by its hash, and a process uses a face only
// beside the glyph cache of that hash.
font_of_face :: proc "contextless" (face: demand_cache.Face) -> text_rendering.Outline_Font {
	switch face {
	case .Interface:
		return .B612
	case .Cells, .Cells_Without_Grid_Fit:
		return .Paper_Mono
	case .Cells_Bold:
		return .Paper_Mono_Semibold
	}
	return .None
}

// The name of a face for the log.
face_name_of :: proc "contextless" (face: demand_cache.Face) -> string {
	switch face {
	case .Interface:
		return "interface"
	case .Cells:
		return "cells"
	case .Cells_Without_Grid_Fit:
		return "cells without the grid fit"
	case .Cells_Bold:
		return "bold cells"
	}
	return ""
}

render_memory: vector_font.Render_Memory
demand_fonts: [demand_cache.Face]vector_font.Demand_Font
writer: demand_cache.Writer

// Character_Added: what character_add did with a character.
Character_Added :: enum u8 {
	Drawn, // It is drawn and published now, or it was published before.
	Absent, // It is outside the subset, or the font cannot draw it: no entry.
	Refused, // It does not fit the cache: no entry.
}

// character_add draws one character of the subset of a face into the
// demand cache, if the cache does not hold it.
character_add :: proc "contextless" (face: demand_cache.Face, character: rune) -> Character_Added {
	if !demand_cache.in_subset(face, character) {
		return .Absent
	}
	place, search := demand_cache.place_find(&writer, face, character)
	switch search {
	case .Published:
		return .Drawn
	case .Full:
		demand_cache.refusal_count(&writer)
		return .Refused
	case .Free:
	}
	entry, result := vector_font.demand_glyph_draw(&demand_fonts[face], &writer, character, &render_memory)
	switch result {
	case .Drawn:
		demand_cache.publish(&writer, place, face, character, entry)
		return .Drawn
	case .Absent:
		return .Absent
	case .Refused:
		demand_cache.refusal_count(&writer)
		return .Refused
	}
	return .Absent
}

// font_bytes_of gives the font file of a font of the outlines, or nil.
font_bytes_of :: proc "contextless" (outlines: ^font_outlines.Outlines, font: text_rendering.Outline_Font) -> (bytes: []u8, hash: [32]u8) {
	for &record, index in outlines.records {
		if font_outlines.name_of(&record) == text_rendering.outline_font_name(font) {
			return font_outlines.font_bytes(outlines, index), record.hash
		}
	}
	return nil, {}
}

// coverage_log writes, for each script of the fallback chains, how many of
// its characters the chain of the interface and the chain of the cells
// draw, and names the ones that no font of the system has.
coverage_log :: proc "contextless" () {
	for script in text_rendering.Script {
		interface_drawn, total := text_rendering.coverage(.Interface, script)
		cells_drawn, _ := text_rendering.coverage(.Cells, script)
		if interface_drawn == total && cells_drawn == total {
			system.log_in("processes", .Info, "glyphs: the script ", text_rendering.script_name(script), ": the chain of the interface draws ", u64(interface_drawn), " of its ", u64(total), " characters, the chain of the cells ", u64(cells_drawn))
		} else {
			system.log_in("processes", .Info, "glyphs: the script ", text_rendering.script_name(script), ": the chain of the interface draws ", u64(interface_drawn), " of its ", u64(total), " characters, the chain of the cells ", u64(cells_drawn), "; no font of the system has the others")
		}
	}
}

// The entry of the font service: it maps the demand cache, writes its
// header, draws the whole subset of each face, writes the coverage of the
// fallback chains, and ends with the code 0. With no demand cache, no
// outlines, or a font that the renderer refuses, it stops with the code 1:
// each process then draws each of its glyphs past the glyph caches itself.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	address, status := system.memory_map(ctx.handles[demand_cache.SERVICE_GRANT_CACHE])
	if status != .Ok {
		system.log_in("processes", .Error, "glyphs: the demand cache does not map: status ", status)
		system.stop(1)
	}
	outlines, problem := font_outlines.open(&ctx.values)
	if problem.kind != .None {
		system.log_in("processes", .Error, "glyphs: the font outlines are refused: ", font_outlines.problem_sentences[problem.kind])
		system.stop(1)
	}
	faces: [demand_cache.Face]demand_cache.Face_Header
	for face in demand_cache.Face {
		font := font_of_face(face)
		bytes, hash := font_bytes_of(&outlines, font)
		font_problem := vector_font.Font_Problem.Missing_Table
		if bytes != nil {
			demand_fonts[face], font_problem = vector_font.demand_font_open(bytes, face, &render_memory)
		}
		if font_problem != .None {
			system.log_in("processes", .Error, "glyphs: the font ", text_rendering.outline_font_name(font), " of the face ", face_name_of(face), " is refused: ", vector_font.font_problem_names[font_problem])
			system.stop(1)
		}
		// The hash of the record: the root service checked the hash of the
		// whole resource, and the tool wrote each record from its file.
		faces[face] = {font_hash = hash, flags = demand_fonts[face].flags}
		if hash != blake3.hash(bytes) {
			system.log_in("processes", .Error, "glyphs: the font ", text_rendering.outline_font_name(font), " does not have the hash of its record")
			system.stop(1)
		}
	}
	writer = demand_cache.writer_open(uintptr(address), vector_font.RENDERER_VERSION, faces)
	// The whole subset of each face, face after face, in the order of the
	// code points: the entries of the cache do not depend on what a process
	// draws.
	total: u64
	for face in demand_cache.Face {
		drawn, refused, absent: u64
		for range in demand_cache.subset_of(face) {
			for character in range.first ..= range.last {
				switch character_add(face, character) {
				case .Drawn:
					drawn += 1
				case .Refused:
					refused += 1
				case .Absent:
					absent += 1
				}
			}
		}
		total += drawn
		font_name := text_rendering.outline_font_name(font_of_face(face))
		if refused == 0 && absent == 0 {
			system.log_in("processes", .Info, "glyphs: the face ", face_name_of(face), " of the demand cache holds each of the ", u64(demand_cache.subset_count(face)), " characters of its subset of ", font_name)
		} else {
			system.log_in("processes", .Warning, "glyphs: the face ", face_name_of(face), " of the demand cache lacks characters of its subset of ", font_name, ": ", drawn, " drawn, ", refused, " refused, ", absent, " that the font cannot draw")
		}
	}
	system.log_in("processes", .Info, "glyphs: the font service drew each face of its subset into the demand cache: ", total, " characters, ", u64(writer.words_used), " words of ", u64(demand_cache.WORD_CAPACITY))
	// What the fallback chains draw past the glyph caches, script by
	// script: the log names what no font of the system has.
	_ = text_rendering.open(&outlines, 0)
	coverage_log()
	system.stop(0)
}
