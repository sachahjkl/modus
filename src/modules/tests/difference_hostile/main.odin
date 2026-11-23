// The hostile caller of the trusted display of a plan difference
// (src/md/features/declarations.md, "The apply as built").
// It acts for its principal, as the plans service does, so the display
// reads what it gives, and it gives two objects that would stop a display
// that maps them:
//
//   1. An Uncommitted object, whose page has no frame: the display refuses
//      it at its border with Bad_Value, keeps no copy of it, and still
//      serves.
//   2. A good object that this process revokes as soon as the call
//      returned, while the worker of the display reads it: the display
//      reads by the kernel (Memory_Read), so the revocation is a status
//      there and not a fault. The dialog ends unread, or shows the lines
//      read before the revocation until the principal refuses it; either
//      way the display still serves.
//
// **Start**: `start("difference_hostile")` in the console of principal 0.
// **What a reader sees**: no window of its own; the dialog of the
// difference "difference_hostile", which the scenario refuses with
// Escape; one line "difference_hostile: ..." for each case, or a line
// "difference_hostile: WRONG: ...".
package difference_hostile

import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/module"
import "modus:system"

// The items of the difference that the second case revokes: enough pages
// that the worker of the display reads them in several copies.
REVOKED_ITEMS :: 4000
ITEM_BYTES :: 9 // "item0000," with its comma.

// A connection, two objects of at most 10 pages, the text of the items.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 128}

// The decisions that plan_diff_poll gives (plans_recipes.Plan_Display_Decision).
DECISION_PENDING :: 0
DECISION_ACCEPTED :: 1

Display :: struct {
	connection: system.Call_Connection,
	file:       []u8,
	ask, poll:  u32,
}

items_text: [REVOKED_ITEMS * ITEM_BYTES]u8

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	display := display_connect(ctx)
	uncommitted_case(&display)
	revoked_case(&display)
	system.stop(.Done)
}

// uncommitted_case gives an object whose one page is not committed.
@(private = "file")
uncommitted_case :: proc "contextless" (display: ^Display) {
	memory, status := system.memory_create(1, 0, {.Uncommitted})
	if status != .Ok {
		wrong("an Uncommitted object of one page was not made; the status word", u64(status))
	}
	defer system.close(memory)
	given := give(display, memory)
	result, call, error := ask(display, given, 10, 0)
	if call != .Argument_Refused || result != 0 || error.kind != i64(errors.Kind.Bad_Value) {
		system.log_fact(.Error, Wrong_Answer{status = u64(call), result = result, error_kind = error.kind})
		system.stop(.Failed)
	}
	// The display closed its copy at the refusal: no holding is left to end.
	if ended, revoke_status := system.handle_revoke(memory); revoke_status != .Ok || ended != 0 {
		wrong("the display kept the refused object; the holdings that the revocation ended", ended)
	}
	serving_check(display)
	system.log_fact(.Info, Uncommitted_Refused{})
}

// revoked_case gives a good object and revokes it after the call.
@(private = "file")
revoked_case :: proc "contextless" (display: ^Display) {
	// The items that commas separate: "item0000,item0001,...,item3999".
	added_bytes := 0
	for index in 0 ..< REVOKED_ITEMS {
		if index > 0 {
			items_text[added_bytes] = ','
			added_bytes += 1
		}
		added_bytes += copy(items_text[added_bytes:], "item")
		number := index
		for place := added_bytes + 3; place >= added_bytes; place -= 1 {
			items_text[place] = u8('0' + number % 10)
			number /= 10
		}
		added_bytes += 4
	}
	added := items_text[:added_bytes]
	pages := (u64(added_bytes) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	memory, status := system.memory_create(pages)
	if status != .Ok {
		wrong("the object of the difference was not made; the status word", u64(status))
	}
	defer system.close(memory)
	address, map_status := system.memory_map(memory, {.Write})
	if map_status != .Ok {
		wrong("the object of the difference does not map; the status word", u64(map_status))
	}
	copy(([^]u8)(address)[:added_bytes], added[:added_bytes])
	system.memory_unmap(address)
	given := give(display, memory)
	result, call, error := ask(display, given, added_bytes, 0)
	if call != .Succeeded || result <= 0 {
		system.log_fact(.Error, Wrong_Answer{status = u64(call), result = result, error_kind = error.kind})
		system.stop(.Failed)
	}
	// The worker of the display reads now: its copy of the object ends.
	_, _ = system.handle_revoke(memory)
	system.log_fact(.Info, Revoked_After_The_Call{serial = u64(result)})
	// The dialog ends unread (unknown), or the principal refuses the lines
	// that the worker read first: the scenario presses Escape.
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for {
		decision := poll(display, result)
		if decision == DECISION_ACCEPTED {
			wrong("the principal accepted the revoked difference; the serial", u64(result))
		}
		if decision != DECISION_PENDING {
			serving_check(display)
			system.log_fact(.Info, Revoked_Display_Serves{decision = u64(decision)})
			return
		}
		if system.time() >= deadline {
			wrong("the dialog of the revoked difference did not end within the hang bound; the milliseconds", system.TEST_HANG_BOUND_MILLISECONDS)
		}
		wait := system.wait_begin()
		system.wait_end(&wait, system.time() + 10)
	}
}

// give gives a copy of memory with Read only through the call ring of the
// connection: the number of that copy is what the display names.
@(private = "file")
give :: proc "contextless" (display: ^Display, memory: system.Handle) -> system.Handle {
	given, status := system.give(display.connection.ring_memory, memory, {.Read})
	if status != .Ok {
		wrong("the object did not go through the call ring; the status word", u64(status))
	}
	return given
}

@(private = "file")
ask :: proc "contextless" (display: ^Display, given: system.Handle, added_bytes, removed_bytes: int) -> (result: i64, status: call_outcome.Call_Outcome, error: errors.Error_Record) {
	name := "difference_hostile"
	arguments := [4]isolated.Argument{{text = transmute([]u8)name}, {integer = u64(given)}, {integer = u64(added_bytes)}, {integer = u64(removed_bytes)}}
	result, status = system.call_isolated(&display.connection, display.file, display.ask, arguments[:], &error)
	return
}

@(private = "file")
poll :: proc "contextless" (display: ^Display, serial: i64) -> i64 {
	arguments := [1]isolated.Argument{{integer = u64(serial)}}
	error: errors.Error_Record
	result, status := system.call_isolated(&display.connection, display.file, display.poll, arguments[:], &error)
	if status != .Succeeded || result < 0 {
		system.log_fact(.Error, Wrong_Answer{status = u64(status), result = result, error_kind = error.kind})
		system.stop(.Failed)
	}
	return result
}

// serving_check proves that the display still serves a call: a poll of a
// serial that names no dialog gives unknown.
@(private = "file")
serving_check :: proc "contextless" (display: ^Display) {
	_ = poll(display, max(i64))
}

@(private = "file")
display_connect :: proc "contextless" (ctx: ^system.Context) -> (display: Display) {
	requests_memory := ctx.handles[system.GRANT_ROOT]
	requests, ring_status := system.ring_open(requests_memory, receive_handles = true)
	if ring_status != .Ok {
		wrong("no root ring; the status", u64(ring_status))
	}
	image_handle := ctx.handles[system.GRANT_IMAGE]
	address, map_status := system.memory_map(image_handle, {})
	if image_handle == 0 || map_status != .Ok {
		wrong("the boot image does not map; the status word", u64(map_status))
	}
	image := ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	connected: call_outcome.Call_Outcome
	display.connection, connected = system.service_connection(&requests, 1, "display")
	if connected != .Succeeded {
		wrong("the root service gave no connection to the holder of Display; the call outcome", u64(connected))
	}
	entry := system.image_entry_of(image, display.connection.module_hash)
	if entry == nil {
		wrong("the holder of Display is no module of the boot image", 0)
	}
	display.file = image[entry.offset:][:entry.size]
	if blake3.hash(display.file) != display.connection.module_hash {
		wrong("the file of the holder of Display has not its hash", 0)
	}
	display.ask = module.export_find(display.file, "plan_diff_ask")
	display.poll = module.export_find(display.file, "plan_diff_poll")
	if display.ask == 0 || display.poll == 0 {
		wrong("the holder of Display has no export plan_diff_ask or plan_diff_poll", 0)
	}
	return
}

@(private = "file")
wrong :: proc "contextless" (text: string, value: u64) -> ! {
	system.log_fact(.Error, Wrong{value = value}, text)
	system.stop(.Failed)
}
