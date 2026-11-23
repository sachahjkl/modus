package web

// The memory of a document of the web: the tree, the style sheet and the
// layout tree of html_css in arenas of the budget of the process, one for
// each part, which grow as a page needs them
// (src/md/features/desktop_to_browser.md, "The memory of a document").
// A page has no fixed count of nodes, rules or bytes: the budget bounds it,
// and a part that the budget does not pay cuts the document there, which
// it says (truncated).

import "modus:contract/html_css"
import "modus:system"

// The arenas of the memory of a document, one for each part that grows.
Document_Arena :: enum u8 {
	Nodes      = 0,
	Attributes = 1,
	Text       = 2,
	Order      = 3,
	Rules      = 4,
	Names      = 5,
	Styles     = 6,
	Boxes      = 7,
	Matched    = 8,
}

Document_Arenas :: [Document_Arena]system.Arena

// document_arenas_create reserves the arenas of a document, each of
// reserve_pages pages: the pages that the budget of the process holds
// (system.arena_reservation_pages), so that no part is bounded by less than
// the budget. The budget pays the frame list of each reservation now, and
// each page at its first use. A refused arena ends the ones before it.
document_arenas_create :: proc "contextless" (arenas: ^Document_Arenas, reserve_pages: u64) -> system.Status {
	for &arena, part in arenas {
		status: system.Status
		if arena, status = system.arena_create(reserve_pages); status != .Ok {
			for &made, before in arenas {
				if before < part {
					system.arena_end(&made)
				}
			}
			return status
		}
	}
	return .Ok
}

// document_memory_bind gives a tree, a style sheet and a layout tree the
// grow procedures of the arenas.
document_memory_bind :: proc "contextless" (arenas: ^Document_Arenas, tree: ^html_css.Dom_Tree, sheet: ^html_css.Css_Stylesheet, layout: ^html_css.Layout_Tree) {
	tree.grow, tree.grow_data = document_tree_grow, arenas
	sheet.grow, sheet.grow_data = document_sheet_grow, arenas
	layout.grow, layout.grow_data = document_layout_grow, arenas
}

// arena_entries makes an arena hold at least wanted entries of a size from
// its base, and gives the entries that it holds: twice the wanted ones when
// the reservation holds them, so that a parse grows a few times only, else
// the wanted ones. The arena grows at its end, so each entry keeps its
// place, as html_css asks (html_css.Dom_Grow). false: the budget or the
// reservation does not hold them; the arena holds what it held.
arena_entries :: proc "contextless" (arena: ^system.Arena, entry_size, wanted: int) -> (entries: int, ok: bool) {
	held := int(arena.used_bytes) / entry_size
	if wanted <= held {
		return held, true
	}
	reserved := int(arena.reserved_pages * system.PAGE_SIZE) / entry_size
	if wanted > reserved {
		return held, false
	}
	for target in ([2]int{min(2 * wanted, reserved), wanted}) {
		if _, status := system.arena_push(arena, u64((target - held) * entry_size), 1); status == .Ok {
			return target, true
		}
	}
	return held, false
}

// arena_slice gives the entries that an arena holds, of a type.
arena_slice :: proc "contextless" (arena: ^system.Arena, $T: typeid, entries: int) -> []T {
	if entries == 0 {
		return nil
	}
	return ([^]T)(arena.base)[:entries]
}

@(private = "file")
document_tree_grow :: proc "contextless" (tree: ^html_css.Dom_Tree, part: html_css.Dom_Part, wanted: int) -> bool {
	arenas := (^Document_Arenas)(tree.grow_data)
	switch part {
	case .Nodes:
		entries, ok := arena_entries(&arenas[.Nodes], size_of(html_css.Dom_Node), wanted)
		tree.nodes = arena_slice(&arenas[.Nodes], html_css.Dom_Node, entries)
		return ok
	case .Attributes:
		entries, ok := arena_entries(&arenas[.Attributes], size_of(html_css.Dom_Attr), wanted)
		tree.attrs = arena_slice(&arenas[.Attributes], html_css.Dom_Attr, entries)
		return ok
	case .Text:
		entries, ok := arena_entries(&arenas[.Text], 1, wanted)
		tree.text_pool = arena_slice(&arenas[.Text], u8, entries)
		return ok
	case .Order:
		entries, ok := arena_entries(&arenas[.Order], size_of(u32), wanted)
		tree.order = arena_slice(&arenas[.Order], u32, entries)
		return ok
	}
	return false
}

@(private = "file")
document_sheet_grow :: proc "contextless" (sheet: ^html_css.Css_Stylesheet, part: html_css.Css_Part, wanted: int) -> bool {
	arenas := (^Document_Arenas)(sheet.grow_data)
	switch part {
	case .Rules:
		entries, ok := arena_entries(&arenas[.Rules], size_of(html_css.Css_Rule), wanted)
		sheet.rules = arena_slice(&arenas[.Rules], html_css.Css_Rule, entries)
		return ok
	case .Names:
		entries, ok := arena_entries(&arenas[.Names], 1, wanted)
		sheet.names = arena_slice(&arenas[.Names], u8, entries)
		return ok
	}
	return false
}

@(private = "file")
document_layout_grow :: proc "contextless" (layout: ^html_css.Layout_Tree, part: html_css.Layout_Part, wanted: int) -> bool {
	arenas := (^Document_Arenas)(layout.grow_data)
	switch part {
	case .Styles:
		entries, ok := arena_entries(&arenas[.Styles], size_of(html_css.Computed_Style), wanted)
		layout.node_styles = arena_slice(&arenas[.Styles], html_css.Computed_Style, entries)
		return ok
	case .Boxes:
		entries, ok := arena_entries(&arenas[.Boxes], size_of(html_css.Layout_Box), wanted)
		layout.boxes = arena_slice(&arenas[.Boxes], html_css.Layout_Box, entries)
		return ok
	case .Matched:
		entries, ok := arena_entries(&arenas[.Matched], size_of(html_css.Matched_Rule), wanted)
		layout.matched = arena_slice(&arenas[.Matched], html_css.Matched_Rule, entries)
		return ok
	}
	return false
}

// document_memory_trim gives back the pages of each arena past twice what
// the document holds now, and cuts each slice to what its arena holds
// after: a page that needed much memory leaves only what a page of its
// size needs, so another part can grow for a later page of another shape.
// Twice is the margin of a growth (arena_entries): a next page of the same
// size commits nothing. A part keeps the bytes of the document in place.
document_memory_trim :: proc "contextless" (arenas: ^Document_Arenas, tree: ^html_css.Dom_Tree, sheet: ^html_css.Css_Stylesheet, layout: ^html_css.Layout_Tree) {
	nodes := int(max(tree.node_count, tree.nodes_written))
	tree.nodes = arena_slice(&arenas[.Nodes], html_css.Dom_Node, arena_trim_to(&arenas[.Nodes], size_of(html_css.Dom_Node), nodes))
	tree.attrs = arena_slice(&arenas[.Attributes], html_css.Dom_Attr, arena_trim_to(&arenas[.Attributes], size_of(html_css.Dom_Attr), int(tree.attr_count)))
	tree.text_pool = arena_slice(&arenas[.Text], u8, arena_trim_to(&arenas[.Text], 1, int(tree.text_len)))
	tree.order = arena_slice(&arenas[.Order], u32, arena_trim_to(&arenas[.Order], size_of(u32), int(tree.order_written)))
	sheet.rules = arena_slice(&arenas[.Rules], html_css.Css_Rule, arena_trim_to(&arenas[.Rules], size_of(html_css.Css_Rule), int(sheet.rule_count)))
	sheet.names = arena_slice(&arenas[.Names], u8, arena_trim_to(&arenas[.Names], 1, int(sheet.name_count)))
	layout.node_styles = arena_slice(&arenas[.Styles], html_css.Computed_Style, arena_trim_to(&arenas[.Styles], size_of(html_css.Computed_Style), int(layout.styled_count)))
	layout.boxes = arena_slice(&arenas[.Boxes], html_css.Layout_Box, arena_trim_to(&arenas[.Boxes], size_of(html_css.Layout_Box), int(layout.box_count)))
	layout.matched = arena_slice(&arenas[.Matched], html_css.Matched_Rule, arena_trim_to(&arenas[.Matched], size_of(html_css.Matched_Rule), int(layout.matched_count)))
}

// arena_trim_to gives back the pages of an arena past twice the entries in
// use, and gives the entries that it holds after.
arena_trim_to :: proc "contextless" (arena: ^system.Arena, entry_size, used: int) -> (entries: int) {
	system.arena_trim(arena, u64(2 * used * entry_size))
	return int(arena.used_bytes) / entry_size
}

