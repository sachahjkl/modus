// Counted module memory floor calculation including per-copy text glyph cache
// memory (src/md/features/module_budget_request.md and
// src/md/features/text_rendering.md).
//
// Replaces hand-written working_memory_pages estimates with an overflow-safe
// sum of counted parts: module load pages, declared start objects, private
// glyph cache pages for each copy of text_rendering that draws (the module's
// own copy and/or the imported drawing module copy), and child module floors.
//
// Pure freestanding contract extending `modus:contract/work_budget`.
package work_budget

import "modus:contract/enum_word"

// Computed bound: matches MAX_WORK_BUDGET_PAGES (kernel memory object limit)
// so a counted floor never exceeds addressable memory limits.
MODULE_FLOOR_MAX_PAGES :: MAX_WORK_BUDGET_PAGES

// Plan value: default 64 pages (256 KiB) per drawing copy of text_rendering's
// private glyph cache, counted separately for a module's own drawing copy and
// for the imported drawing module copy when both draw text.
GLYPH_CACHE_PRIVATE_DEFAULT_PAGES :: u64(64)

// Closed set of refusals returned when validating or summing module floor
// components. Explicit values cross build/runtime borders.
Module_Floor_Refusal :: enum u8 {
	None            = 0,
	Zero_Load_Pages = 1,
	Overflow        = 2,
	Exceeds_Limit   = 3,
	Bad_Value       = 4,
}

// Counted page components of one module's memory floor at its first state of
// work. Every component comes from a build-time or contract count rather than
// a hand-guessed working-memory constant.
Module_Floor_Components :: struct {
	load_pages:               u64, // Module image, imports, threads, frame lists, and page tables (>= 1).
	start_object_pages:       u64, // Declared MODULE_START_OBJECTS / PACKAGE_START_OBJECTS priced via op.memory_cost.
	own_text_glyph_pages:     u64, // Private glyph cache pages when this module compiles text_rendering to draw.
	drawing_text_glyph_pages: u64, // Private glyph cache pages of the imported drawing module copy.
	child_floor_pages:        u64, // Sum of floors of child modules started before ready() (and MODULE_START_BUDGETS).
}

// module_floor_refusal_of_word converts a raw word into Module_Floor_Refusal
// at a border, refusing any word that does not name a member.
module_floor_refusal_of_word :: proc "contextless" (word: u64) -> (refusal: Module_Floor_Refusal, ok: bool) {
	return enum_word.member_of_word(Module_Floor_Refusal, word)
}

// module_floor_glyph_pages computes the counted glyph cache pages for a module
// based on whether its own copy of text_rendering draws and whether it imports
// the drawing module (which holds its own separate private glyph cache).
// Refuses per_copy_pages == 0 whenever at least one copy draws.
module_floor_glyph_pages :: proc "contextless" (
	draws_own_text: bool,
	imports_drawing_module: bool,
	per_copy_pages: u64 = GLYPH_CACHE_PRIVATE_DEFAULT_PAGES,
) -> (own_pages: u64, drawing_pages: u64, refusal: Module_Floor_Refusal) {
	if (draws_own_text || imports_drawing_module) && per_copy_pages == 0 {
		return 0, 0, .Bad_Value
	}
	if draws_own_text {
		own_pages = per_copy_pages
	}
	if imports_drawing_module {
		drawing_pages = per_copy_pages
	}
	return own_pages, drawing_pages, .None
}

@(private = "file")
floor_checked_add_u64 :: proc "contextless" (left, right: u64) -> (sum: u64, ok: bool) {
	if left > max(u64) - right {
		return 0, false
	}
	return left + right, true
}

// module_floor_total_pages computes the overflow-safe total floor in 4 KiB
// pages from all counted components. Refuses zero load_pages, u64 overflow,
// or a sum above MODULE_FLOOR_MAX_PAGES.
module_floor_total_pages :: proc "contextless" (parts: Module_Floor_Components) -> (total_pages: u64, refusal: Module_Floor_Refusal) {
	if parts.load_pages == 0 {
		return 0, .Zero_Load_Pages
	}
	sum := parts.load_pages
	ok: bool
	sum, ok = floor_checked_add_u64(sum, parts.start_object_pages)
	if !ok {
		return 0, .Overflow
	}
	sum, ok = floor_checked_add_u64(sum, parts.own_text_glyph_pages)
	if !ok {
		return 0, .Overflow
	}
	sum, ok = floor_checked_add_u64(sum, parts.drawing_text_glyph_pages)
	if !ok {
		return 0, .Overflow
	}
	sum, ok = floor_checked_add_u64(sum, parts.child_floor_pages)
	if !ok {
		return 0, .Overflow
	}
	if sum > MODULE_FLOOR_MAX_PAGES {
		return 0, .Exceeds_Limit
	}
	return sum, .None
}
