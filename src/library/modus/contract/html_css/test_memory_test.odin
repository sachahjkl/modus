#+build !freestanding
#+build !modus
package html_css

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
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

// order_cut_grow refuses the work of the order past a few entries: the
// order of a large page cuts its nodes after they are written.
@(private = "file")
order_cut_grow :: proc "contextless" (tree: ^Dom_Tree, part: Dom_Part, wanted: int) -> bool {
	if part == .Order && wanted > 64 {
		return false
	}
	return test_dom_grow(tree, part, wanted)
}

// A large page whose order is cut, then a small page: no byte of the large
// page stays in the memory of the tree, past what the small page wrote and
// in it.
@(test)
a_small_page_after_a_cut_large_page_holds_no_byte_of_it :: proc(t: ^testing.T) {
	tree := new(Dom_Tree)
	tree.grow = order_cut_grow
	SECRET :: "zq-secret-of-the-large-page"
	large: strings.Builder
	strings.builder_init(&large, context.temp_allocator)
	for i in 0 ..< 400 {
		fmt.sbprintf(&large, "<p class=%s id=n%d>%s %d</p>", SECRET, i, SECRET, i)
	}
	origin := Document_Origin{principal_id = 1, scheme = .Https, port = 443}
	parse_html(tree, origin, transmute([]u8)strings.to_string(large))
	testing.expect(t, tree.truncated && tree.node_count == 1, "the order was cut")
	testing.expect(t, tree.nodes_written > 400, "the nodes were written before the cut")
	parse_html(tree, origin, transmute([]u8)string("<p>x</p>"))
	testing.expect(t, !tree.truncated && tree.node_count > 1)
	none_past :: proc(bytes: []u8, from: int) -> bool {
		for b in bytes[min(from, len(bytes)):] {
			if b != 0 {
				return false
			}
		}
		return true
	}
	count := int(tree.node_count)
	testing.expect(t, none_past(slice.to_bytes(tree.nodes), count * size_of(Dom_Node)), "no node of the large page")
	testing.expect(t, none_past(slice.to_bytes(tree.attrs), int(tree.attr_count) * size_of(Dom_Attr)), "no attribute of the large page")
	testing.expect(t, none_past(tree.text_pool, int(tree.text_len)), "no text of the large page")
	testing.expect(t, none_past(slice.to_bytes(tree.order), (2 * count + (count + 31) / 32) * size_of(u32)), "no order of the large page")
	testing.expect(t, !strings.contains(string(tree.text_pool), SECRET))
}


// A page that makes the most boxes: tables with head, body and foot groups,
// rows and cells, cells outside a row, nested tables, inline elements, and
// text that wraps in a narrow view. A node gives one box at most, so the
// boxes never pass the nodes: the bound that the origin worker checks.
@(test)
a_node_gives_one_box_at_most :: proc(t: ^testing.T) {
	tree := test_tree_make()
	sheet := test_sheet_make()
	layout := test_layout_make()
	page: strings.Builder
	strings.builder_init(&page, context.temp_allocator)
	strings.write_string(&page, "<style>td { padding: 1px } span { color: red } .f { display: flex }</style>")
	for i in 0 ..< 20 {
		fmt.sbprintf(&page, "<table><thead><tr><th>h%d</th><th>h</th></tr></thead><tbody>", i)
		fmt.sbprintf(&page, "<tr><td>a long text that wraps in a narrow view %d</td><td><table><tr><td>inner</td></tr></table></td></tr>", i)
		strings.write_string(&page, "<td>a cell outside a row</td><caption>c</caption></tbody><tfoot><tr><td><span>s</span><b>b</b> t</td></tr></tfoot></table>")
		strings.write_string(&page, "<div class=f><span>one</span><span>two</span> text <em>em</em></div><ul><li>a<li>b</ul>")
	}
	parse_html(tree, {principal_id = 1, scheme = .Https, port = 443}, transmute([]u8)strings.to_string(page))
	parse_document_styles(tree, sheet)
	for width in ([?]i32{40, 320, 1920}) {
		compute_layout(tree, sheet, width, 600, layout)
		testing.expect(t, !layout.truncated && layout.box_count > 0)
		testing.expectf(t, layout.box_count <= tree.node_count, "%d boxes for %d nodes", layout.box_count, tree.node_count)
		seen := make([]bool, tree.node_count, context.temp_allocator)
		for box in layout.boxes[:layout.box_count] {
			testing.expectf(t, !seen[box.node_index], "the node %d has two boxes", box.node_index)
			seen[box.node_index] = true
		}
	}
}

