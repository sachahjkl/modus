#+build !freestanding
package web

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/html_css"
import op "modus:contract/operation"
import "modus:system"

// The memory of a document over reservations of the heap, whose commits
// and decommits a fake accepts, as an arena of a process does with its
// budget.

@(private = "file")
TEST_RESERVE_PAGES :: 4096

@(private = "file")
test_page_change :: proc "contextless" (arena: ^system.Arena, range: op.Page_Range, flags: op.Commit_Flags, error: ^errors.Error_Record) -> call_outcome.Call_Outcome {
	return .Succeeded
}

@(private = "file")
committed_pages :: proc(arenas: ^Document_Arenas) -> (pages: u64) {
	for &arena in arenas {
		pages += arena.committed_pages
	}
	return
}

@(private = "file")
page_of :: proc(paragraphs: int) -> string {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "<style>p { margin: 2px } .x { color: red }</style>")
	for index in 0 ..< paragraphs {
		fmt.sbprintf(&builder, "<p class=x id=p%d>a paragraph of text %d</p>", index, index)
	}
	return strings.to_string(builder)
}

@(private = "file")
lay_out :: proc(tree: ^html_css.Dom_Tree, sheet: ^html_css.Css_Stylesheet, layout: ^html_css.Layout_Tree, page: string) {
	html_css.parse_html(tree, {principal_id = 1, scheme = .Https, port = 443}, transmute([]u8)page)
	html_css.stylesheet_clear(sheet)
	html_css.parse_document_styles(tree, sheet)
	html_css.compute_layout(tree, sheet, 800, 600, layout)
}

// A large page grows the arenas; the trim after a small page gives their
// pages back, down to what the small page needs, and the large page grows
// them again, with the same layout.
@(test)
a_trim_gives_back_the_pages_of_a_large_page :: proc(t: ^testing.T) {
	arenas := new(Document_Arenas)
	defer free(arenas)
	for &arena in arenas {
		bytes, _ := mem.alloc_bytes(TEST_RESERVE_PAGES * system.PAGE_SIZE, system.PAGE_SIZE, runtime.heap_allocator())
		arena = system.arena_of_reservation(raw_data(bytes), TEST_RESERVE_PAGES, test_page_change)
	}
	defer for &arena in arenas {
		mem.free(arena.base, runtime.heap_allocator())
	}
	tree := new(html_css.Dom_Tree)
	sheet := new(html_css.Css_Stylesheet)
	layout := new(html_css.Layout_Tree)
	defer free(tree)
	defer free(sheet)
	defer free(layout)
	document_memory_bind(arenas, tree, sheet, layout)

	large := page_of(3000)
	lay_out(tree, sheet, layout, large)
	large_boxes := layout.box_count
	testing.expect(t, !tree.truncated && large_boxes > 3000)
	document_memory_trim(arenas, tree, sheet, layout)
	after_large := committed_pages(arenas)

	lay_out(tree, sheet, layout, page_of(3))
	testing.expect_value(t, tree.truncated, false)
	document_memory_trim(arenas, tree, sheet, layout)
	after_small := committed_pages(arenas)
	testing.expect(t, after_small * 8 < after_large, "the pages of the large page went back")
	for &arena, part in arenas {
		testing.expectf(t, arena.committed_pages <= 16, "the part %v keeps %d pages for a small page", part, arena.committed_pages)
	}
	// The slices hold what the arenas hold, and the small page reads whole.
	testing.expect(t, len(tree.nodes) >= int(tree.node_count) && len(layout.boxes) >= int(layout.box_count))
	box, found := html_css.layout_find_box_by_id(tree, layout, "p2")
	testing.expect(t, found && box < layout.box_count)

	lay_out(tree, sheet, layout, large)
	testing.expect_value(t, layout.box_count, large_boxes)
	document_memory_trim(arenas, tree, sheet, layout)
	// A trim after the same page keeps what it needs: the next one commits
	// nothing more.
	kept := committed_pages(arenas)
	lay_out(tree, sheet, layout, large)
	testing.expect_value(t, committed_pages(arenas), kept)
}
