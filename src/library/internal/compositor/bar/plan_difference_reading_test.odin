#+build !freestanding
package bar

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import op "modus:contract/operation"

@(private = "file")
heap_take :: proc "contextless" (user: rawptr, bytes, alignment: int) -> rawptr {
	context = runtime.default_context()
	left := (^int)(user)
	if bytes > left^ {
		return nil
	}
	left^ -= bytes
	// The heap: the temporary memory of a thread ends with the thread.
	memory, _ := runtime.mem_alloc(bytes, max(alignment, 1), runtime.heap_allocator())
	return raw_data(memory)
}

// A source over bytes of this process: the copy of a test.
@(private = "file")
slice_source :: proc(bytes: ^[]u8) -> Plan_Difference_Source {
	return {user = bytes, bytes = len(bytes^), copy = proc "contextless" (user: rawptr, into: []u8) -> bool {
		copy(into, (^[]u8)(user)^)
		return true
	}}
}

// A source whose object gives no bytes: a page with no frame, a revoked
// handle.
@(private = "file")
refusing_source :: proc(bytes: int) -> Plan_Difference_Source {
	return {bytes = bytes, copy = proc "contextless" (_: rawptr, _: []u8) -> bool {
		return false
	}}
}

@(private = "file")
sides_of :: proc(added_count, removed_count: int) -> (source: []u8, added, removed: int) {
	a := items_text(added_count)
	r := items_text(removed_count)
	return transmute([]u8)strings.concatenate({a, r}, context.temp_allocator), len(a), len(r)
}

// A difference of 20 000 items on each side, read on a thread while the
// dialog shows its reading state: no act accepts, the view does not move;
// the lines come in at the adoption, and the accept counts after the last
// line, as for each difference.
@(test)
plan_difference_read_on_a_worker :: proc(t: ^testing.T) {
	SIDE :: 20_000
	source, added, removed := sides_of(SIDE, SIDE)
	dialog: Plan_Difference_Dialog
	serial, refusal, _ := plan_difference_reading_open(&dialog, "home", 0)
	testing.expect(t, refusal == .None && serial == 1 && dialog.open && dialog.reading)
	// While it reads: Accept is no act, scrolls do not show an end.
	plan_difference_key(&dialog, .Next, 0)
	testing.expect(t, !plan_difference_scroll(&dialog, 1000))
	testing.expect_value(t, plan_difference_key(&dialog, .Act, 10_000), Plan_Difference_Decision.Pending)
	decision, known := plan_difference_decision_of_serial(&dialog, serial)
	testing.expect(t, known && decision == .Pending)

	Job :: struct {
		source:          []u8,
		added, removed:  int,
		left:            int,
		read:            Plan_Difference_Read,
		done:            sync.Sema,
	}
	job := Job{source = source, added = added, removed = removed, left = max(int)}
	worker := thread.create_and_start_with_data(&job, proc(data: rawptr) {
		job := (^Job)(data)
		job.read = plan_difference_read(slice_source(&job.source), job.added, job.removed, {user = &job.left, take = heap_take})
		sync.sema_post(&job.done)
	})
	sync.sema_wait(&job.done)
	thread.join(worker)
	thread.destroy(worker)
	testing.expect(t, job.read.refusal == .None && job.read.added_count == SIDE && job.read.removed_count == SIDE)
	testing.expect(t, plan_difference_adopt(&dialog, serial, &job.read, 20_000))
	testing.expect(t, !dialog.reading && dialog.added_count == SIDE && dialog.removed_count == SIDE)
	testing.expect_value(t, plan_difference_item_text(&dialog.removed[SIDE - 1]), "item 19999")
	// The arm time starts at the adoption; the last line is not seen yet.
	testing.expect_value(t, plan_difference_key(&dialog, .Act, 20_000 + 500), Plan_Difference_Decision.Pending)
	for plan_difference_scroll(&dialog, PLAN_DIFFERENCE_VISIBLE_LINES) {}
	testing.expect_value(t, plan_difference_key(&dialog, .Act, 20_000 + 500), Plan_Difference_Decision.Accepted)
}

// The principal ends the dialog while the worker reads: the reading that
// comes after is dropped, and so is a reading of an older serial; a
// refused reading ends the dialog with no decision that a poll knows.
@(test)
plan_difference_ended_before_its_reading :: proc(t: ^testing.T) {
	source, added, removed := sides_of(50, 0)
	left := max(int)
	dialog: Plan_Difference_Dialog
	serial, _, _ := plan_difference_reading_open(&dialog, "home", 0)
	testing.expect_value(t, plan_difference_key(&dialog, .Escape, 0), Plan_Difference_Decision.Refused)
	read := plan_difference_read(slice_source(&source), added, removed, {user = &left, take = heap_take})
	testing.expect(t, !plan_difference_adopt(&dialog, serial, &read, 1))
	testing.expect(t, !dialog.open && dialog.added_count == 0)
	decision, known := plan_difference_decision_of_serial(&dialog, serial)
	testing.expect(t, known && decision == .Refused)

	// A reading of the dialog before is no reading of this one.
	second, _, _ := plan_difference_reading_open(&dialog, "home", 0)
	testing.expect(t, !plan_difference_adopt(&dialog, serial, &read, 1))
	testing.expect(t, dialog.open && dialog.reading)
	// A second dialog while one reads is Busy.
	_, busy, _ := plan_difference_reading_open(&dialog, "other", 0)
	testing.expect_value(t, busy, Plan_Difference_Refusal.Busy)

	// A refused reading: an empty item. The dialog ends unread.
	bad := transmute([]u8)string("a,,b")
	refused := plan_difference_read(slice_source(&bad), len(bad), 0, {user = &left, take = heap_take})
	testing.expect_value(t, refused.refusal, Plan_Difference_Refusal.Empty_Item)
	testing.expect(t, plan_difference_adopt(&dialog, second, &refused, 1))
	testing.expect(t, !dialog.open)
	_, known = plan_difference_decision_of_serial(&dialog, second)
	testing.expect(t, !known)
	// A budget that pays no copy, and one that pays the copy and no item.
	none := 0
	testing.expect_value(t, plan_difference_read(slice_source(&source), added, removed, {user = &none, take = heap_take}).refusal, Plan_Difference_Refusal.Too_Many_Items)
	copy_only := added
	testing.expect_value(t, plan_difference_read(slice_source(&source), added, removed, {user = &copy_only, take = heap_take}).refusal, Plan_Difference_Refusal.Too_Many_Items)
	// Lengths that pass the source, or are negative.
	testing.expect_value(t, plan_difference_read(slice_source(&source), added + 1, removed, {user = &left, take = heap_take}).refusal, Plan_Difference_Refusal.Not_A_Difference)
	testing.expect_value(t, plan_difference_read(slice_source(&source), -1, removed, {user = &left, take = heap_take}).refusal, Plan_Difference_Refusal.Not_A_Difference)
	// An object that gives no bytes, whose sides fit: the reading is
	// refused, and does not take the copy for a known one.
	testing.expect_value(t, plan_difference_read(refusing_source(len(source)), added, removed, {user = &left, take = heap_take}).refusal, Plan_Difference_Refusal.Not_A_Difference)
	// A source with no copy at all.
	testing.expect_value(t, plan_difference_read({bytes = len(source)}, added, removed, {user = &left, take = heap_take}).refusal, Plan_Difference_Refusal.Not_A_Difference)
}

// The border of the object: each claim that is not true is refused.
@(test)
plan_difference_object_that_is_not_what_it_claims :: proc(t: ^testing.T) {
	PAGE :: i64(op.PAGE_SIZE)
	testing.expect_value(t, plan_difference_object_check(.Memory, {.Read}, true, 1, {}, 10, 20), Plan_Difference_Refusal.None)
	testing.expect_value(t, plan_difference_object_check(.Memory, {.Read}, true, 2, {.Contiguous}, PAGE, 1), Plan_Difference_Refusal.None)
	testing.expect_value(t, plan_difference_object_check(.Memory, {.Read}, true, 1, {}, PAGE, 0), Plan_Difference_Refusal.None)
	cases := [?]struct {
		kind:           op.Object_Kind,
		rights:         op.Rights,
		through:        bool,
		pages:          u64,
		flags:          op.Memory_Flags,
		added, removed: i64,
	} {
		{.Memory, {.Read}, false, 1, {}, 10, 0}, // Not through the call ring of the caller.
		{.Process, {.Read}, true, 1, {}, 10, 0}, // No memory object.
		{.Memory, {.Read, .Write}, true, 1, {}, 10, 0}, // A right past Read.
		{.Memory, {.Read, .Give}, true, 1, {}, 10, 0},
		{.Memory, {}, true, 1, {}, 10, 0}, // No Read.
		{.Memory, {.Read}, true, 1, {.Uncommitted}, 10, 0}, // Pages that can have no frame.
		{.Memory, {.Read}, true, 1, {.Uncommitted, .Contiguous}, 10, 0},
		{.Memory, {.Read}, true, 2, {}, 10, 0}, // More pages than the sides.
		{.Memory, {.Read}, true, 1, {}, PAGE, 1}, // Fewer pages than the sides.
		{.Memory, {.Read}, true, 1, {}, -1, 2},
		{.Memory, {.Read}, true, 1, {}, max(i64), 1},
	}
	for item in cases {
		testing.expectf(t, plan_difference_object_check(item.kind, item.rights, item.through, item.pages, item.flags, item.added, item.removed) == .Not_A_Difference, "%v", item)
	}
	testing.expect_value(t, plan_difference_object_check(.Memory, {.Read}, true, 0, {}, 0, 0), Plan_Difference_Refusal.No_Change)
}
