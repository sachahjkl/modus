#+build !freestanding
package document_picker

import "core:fmt"
import "core:testing"

@(private = "file")
Test_Tables :: struct {
	documents: [512]Document_Record,
	grants:    [512]Document_Grant,
}

@(private = "file")
service_make :: proc(tables: ^Test_Tables) -> (svc: Document_Service) {
	document_service_init(&svc, tables.documents[:], tables.grants[:])
	return svc
}

@(test)
document_picker_grants_and_drop_only_drag_and_drop :: proc(t: ^testing.T) {
	_, bad := drag_state_of_word(99)
	testing.expect(t, !bad)

	tables := new(Test_Tables)
	defer free(tables)
	svc := service_make(tables)
	doc_id, r := document_register(&svc, 1, "notes.txt")
	testing.expect_value(t, r, Picker_Refusal.None)
	_, r_dup := document_register(&svc, 1, "notes.txt")
	testing.expect_value(t, r_dup, Picker_Refusal.Duplicate_Doc)

	// Start drag from window 10, hover over window 20 (process slot 5):
	// process 5 MUST NOT hold any grant during hover!
	drag: Drag_Session
	testing.expect_value(t, drag_begin(&drag, 10, doc_id, {.Read}), Picker_Refusal.None)
	testing.expect_value(t, drag_hover(&drag, 20), Picker_Refusal.None)
	testing.expect(t, !document_process_has_grant(&svc, doc_id, 5, {.Read}))

	// Explicit drop onto window 20 mints Read-only grant to process 5 and resets drag.
	gid, r_drop := drag_drop(&drag, &svc, 20, 5)
	testing.expect_value(t, r_drop, Picker_Refusal.None)
	testing.expect(t, document_process_has_grant(&svc, doc_id, 5, {.Read}))
	testing.expect(t, !document_process_has_grant(&svc, doc_id, 5, {.Write}))
	testing.expect_value(t, drag.state, Drag_State.Idle)

	// Second drop refused because drag ended.
	_, r_again := drag_drop(&drag, &svc, 20, 5)
	testing.expect_value(t, r_again, Picker_Refusal.Drop_Not_Active)

	// Principal revokes grant cleanly.
	testing.expect_value(t, document_grant_revoke(&svc, gid), Picker_Refusal.None)
	testing.expect(t, !document_process_has_grant(&svc, doc_id, 5, {.Read}))
}

// A service with no table refuses each document, and a table of one row
// takes one document, then refuses the second: the capacity is the memory
// of the caller.
@(test)
document_tables_refuse_at_their_own_size :: proc(t: ^testing.T) {
	empty: Document_Service
	document_service_init(&empty, nil, nil)
	_, refusal := document_register(&empty, 1, "a")
	testing.expect_value(t, refusal, Picker_Refusal.Table_Full)

	one_document: [1]Document_Record
	one_grant: [1]Document_Grant
	small: Document_Service
	document_service_init(&small, one_document[:], one_grant[:])
	first, first_refusal := document_register(&small, 1, "a")
	testing.expect_value(t, first_refusal, Picker_Refusal.None)
	_, second_refusal := document_register(&small, 1, "b")
	testing.expect_value(t, second_refusal, Picker_Refusal.Table_Full)
	_, grant_refusal := document_grant_on_pick(&small, first, 3, {.Read})
	testing.expect_value(t, grant_refusal, Picker_Refusal.None)
	_, grant_full := document_grant_on_pick(&small, first, 4, {.Read})
	testing.expect_value(t, grant_full, Picker_Refusal.Table_Full)
}

// The bad inputs of a page are refused, then pages of 0, 1, a page bound
// and past 64 documents: 300 documents of one principal page whole, each
// once, in the order of their identifiers, and the search finds one past
// the 64th.
@(test)
document_pages_reach_each_document :: proc(t: ^testing.T) {
	tables := new(Test_Tables)
	defer free(tables)
	svc := service_make(tables)
	page_rows: [32]Document_Record

	_, refusal := document_page(nil, 1, 0, "", page_rows[:])
	testing.expect_value(t, refusal, Picker_Refusal.Nil_State)
	_, refusal = document_page(&svc, 1, 0, "", nil)
	testing.expect_value(t, refusal, Picker_Refusal.Empty_Page)
	long_query: [MAX_DOC_NAME_BYTES + 1]u8
	_, refusal = document_page(&svc, 1, 0, string(long_query[:]), page_rows[:])
	testing.expect_value(t, refusal, Picker_Refusal.Invalid_Query)

	// No document: an empty page with nothing more.
	page, page_refusal := document_page(&svc, 1, 0, "", page_rows[:])
	testing.expect_value(t, page_refusal, Picker_Refusal.None)
	testing.expect_value(t, page.count, 0)
	testing.expect(t, !page.more)

	// One document of another principal is never on a page.
	_, other := document_register(&svc, 2, "secret of another principal")
	testing.expect_value(t, other, Picker_Refusal.None)

	COUNT :: 300
	ids: [COUNT]u64
	for index in 0 ..< COUNT {
		name := fmt.tprintf("note %03d", index)
		id, register_refusal := document_register(&svc, 1, name)
		testing.expect_value(t, register_refusal, Picker_Refusal.None)
		ids[index] = id
	}

	// A page of one row.
	page, _ = document_page(&svc, 1, 0, "", page_rows[:1])
	testing.expect_value(t, page.count, 1)
	testing.expect(t, page.more)
	testing.expect_value(t, page_rows[0].doc_id, ids[0])

	// Pages of 32 rows, from the first to the last: 10 pages, the last of 12.
	seen := 0
	cursor: u64 = 0
	pages := 0
	for {
		page, page_refusal = document_page(&svc, 1, cursor, "", page_rows[:])
		testing.expect_value(t, page_refusal, Picker_Refusal.None)
		for row in page_rows[:page.count] {
			testing.expect_value(t, row.doc_id, ids[seen])
			testing.expect_value(t, row.principal_id, u64(1))
			seen += 1
		}
		pages += 1
		cursor = page.next_cursor
		if !page.more {
			break
		}
	}
	testing.expect_value(t, seen, COUNT)
	testing.expect_value(t, pages, 10)

	// A page that ends exactly at the last document says nothing more.
	page, _ = document_page(&svc, 1, ids[COUNT - 33], "", page_rows[:])
	testing.expect_value(t, page.count, 32)
	testing.expect(t, !page.more)

	// The search finds the 200th note past the old cap of 64, in any case.
	page, _ = document_page(&svc, 1, 0, "NOTE 200", page_rows[:])
	testing.expect_value(t, page.count, 1)
	testing.expect_value(t, page_rows[0].doc_id, ids[200])

	// A grant on the 299th document.
	grant, grant_refusal := document_grant_on_pick(&svc, ids[299], 7, {.Read, .Write})
	testing.expect_value(t, grant_refusal, Picker_Refusal.None)
	testing.expect(t, grant != 0)
	testing.expect(t, document_process_has_grant(&svc, ids[299], 7, {.Write}))

	// A removal between two pages moves no other document out of reach.
	page, _ = document_page(&svc, 1, 0, "", page_rows[:])
	testing.expect_value(t, document_remove(&svc, ids[10]), Picker_Refusal.None)
	testing.expect(t, !document_process_has_grant(&svc, ids[10], 7, {.Read}))
	next, _ := document_page(&svc, 1, page.next_cursor, "", page_rows[:1])
	testing.expect_value(t, page_rows[0].doc_id, ids[32])
	testing.expect(t, next.more)
	testing.expect_value(t, document_remove(&svc, ids[10]), Picker_Refusal.Not_Found)
	testing.expect_value(t, document_remove(&svc, 0), Picker_Refusal.Invalid_Id)
}
