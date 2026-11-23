#+build !freestanding
package browser

import "base:runtime"
import "core:mem"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:system"
import "modus:web"

// The memory of the document for the host tests: arenas over reservations
// of the heap, whose commits a fake accepts, as an arena of a process grows
// from its budget.

@(private = "file")
TEST_RESERVE_PAGES :: 2048 // 8 MiB for each part: the pages built into the browser and the tests.

@(private = "file")
test_page_change :: proc "contextless" (arena: ^system.Arena, range: op.Page_Range, flags: op.Commit_Flags, error: ^errors.Error_Record) -> system.Status {
	return .Ok
}

@(private = "file")
test_arena :: proc() -> system.Arena {
	// The arenas are globals of the process that outlive each test: their
	// memory is of the heap, not of the allocator of one test.
	bytes, _ := mem.alloc_bytes(TEST_RESERVE_PAGES * system.PAGE_SIZE, system.PAGE_SIZE, runtime.heap_allocator())
	return system.arena_of_reservation(raw_data(bytes), TEST_RESERVE_PAGES, test_page_change)
}

// browser_test_memory_make gives the document and the tables of the window
// their arenas, once.
browser_test_memory_make :: proc() {
	if document_tree.grow != nil {
		return
	}
	for &arena in document_arenas {
		arena = test_arena()
	}
	for &arena in table_arenas {
		arena = test_arena()
	}
	web.document_memory_bind(&document_arenas, &document_tree, &sheet, &document_layout)
}
