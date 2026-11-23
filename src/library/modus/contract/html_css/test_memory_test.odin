#+build !freestanding
package html_css

import "base:runtime"
import "core:slice"
import "core:testing"

// The memory of the host tests: a tree, a style sheet and a layout tree
// whose parts grow from the heap, as the arenas of a process grow from its
// budget. A test that checks a part that cannot grow gives a tree with no
// grow procedure and fixed slices.

test_tree_make :: proc() -> ^Dom_Tree {
	tree := new(Dom_Tree)
	tree.grow = test_dom_grow
	return tree
}

test_sheet_make :: proc() -> ^Css_Stylesheet {
	sheet := new(Css_Stylesheet)
	sheet.grow = test_css_grow
	return sheet
}

test_layout_make :: proc() -> ^Layout_Tree {
	layout := new(Layout_Tree)
	layout.grow = test_layout_grow
	return layout
}

// The entries that a part of the memory of a test can reach: a reserve of
// addresses, as an arena reserves them, whose pages the system gives at
// their first touch.
@(private = "file")
TEST_RESERVE_BYTES :: 32 << 20

// test_grown gives a slice of at least wanted entries with the same first
// entry as a slice: the first growth reserves TEST_RESERVE_BYTES, and
// each one after it takes more of that reserve, so each entry keeps its
// place, as Dom_Grow asks. Past the reserve, it refuses.
@(private = "file")
test_grown :: proc(old: []$T, wanted: int) -> (grown: []T, ok: bool) {
	reserve := TEST_RESERVE_BYTES / size_of(T)
	if wanted > reserve {
		return old, false
	}
	base := raw_data(old)
	if base == nil {
		base = raw_data(make([]T, reserve))
		if base == nil {
			return old, false
		}
	}
	return ([^]T)(base)[:min(max(wanted, 64) * 2, reserve)], true
}

test_dom_grow :: proc "contextless" (tree: ^Dom_Tree, part: Dom_Part, wanted: int) -> bool {
	context = runtime.default_context()
	ok: bool
	switch part {
	case .Nodes:
		tree.nodes, ok = test_grown(tree.nodes, wanted)
	case .Attributes:
		tree.attrs, ok = test_grown(tree.attrs, wanted)
	case .Text:
		tree.text_pool, ok = test_grown(tree.text_pool, wanted)
	case .Order:
		tree.order, ok = test_grown(tree.order, wanted)
	}
	return ok
}

test_css_grow :: proc "contextless" (sheet: ^Css_Stylesheet, part: Css_Part, wanted: int) -> bool {
	context = runtime.default_context()
	ok: bool
	switch part {
	case .Rules:
		sheet.rules, ok = test_grown(sheet.rules, wanted)
	case .Names:
		sheet.names, ok = test_grown(sheet.names, wanted)
	}
	return ok
}

test_layout_grow :: proc "contextless" (layout: ^Layout_Tree, part: Layout_Part, wanted: int) -> bool {
	context = runtime.default_context()
	ok: bool
	switch part {
	case .Styles:
		layout.node_styles, ok = test_grown(layout.node_styles, wanted)
	case .Boxes:
		layout.boxes, ok = test_grown(layout.boxes, wanted)
	case .Matched:
		layout.matched, ok = test_grown(layout.matched, wanted)
	}
	return ok
}

// The memory of a tree, a sheet and a layout outlives a document: each
// clear wipes what the last document wrote, so the next one, of any origin,
// reads no byte of it.
@(test)
a_clear_wipes_the_last_document :: proc(t: ^testing.T) {
	tree := test_tree_make()
	sheet := test_sheet_make()
	layout := test_layout_make()
	SECRET :: "zq-secret-of-a"
	html := "<style>." + SECRET + " { color: red }</style><p class=" + SECRET + " title=" + SECRET + ">" + SECRET + "</p>"
	parse_html(tree, {principal_id = 1, scheme = .Https, port = 443}, transmute([]u8)string(html))
	parse_document_styles(tree, sheet)
	compute_layout(tree, sheet, 640, 480, layout)
	testing.expect(t, tree.node_count > 0 && sheet.rule_count == 1 && layout.box_count > 0)
	dom_tree_clear(tree)
	stylesheet_clear(sheet)
	layout_tree_clear(layout)
	zero :: proc(bytes: []u8) -> bool {
		for b in bytes {
			if b != 0 {
				return false
			}
		}
		return true
	}
	testing.expect(t, zero(tree.text_pool), "the text of the tree is wiped")
	testing.expect(t, zero(sheet.names), "the names of the sheet are wiped")
	testing.expect(t, zero(slice.to_bytes(tree.nodes)) && zero(slice.to_bytes(tree.attrs)), "the nodes and the attributes are wiped")
	testing.expect(t, zero(slice.to_bytes(sheet.rules)), "the rules are wiped")
	testing.expect(t, zero(slice.to_bytes(layout.boxes)) && zero(slice.to_bytes(layout.node_styles)), "the boxes and the styles are wiped")
	testing.expect(t, tree.grow != nil && sheet.grow != nil && layout.grow != nil, "a clear keeps the grow procedures")
}
