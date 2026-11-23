// Delegated powerbox service implementing Role.Powerbox
// (src/md/features/powerbox.md).
//
// Mediates grouped consent requests from windowed processes, forwards sealed
// Dialog_Record payloads (with principal-scoped Store_Share picker candidates)
// to the trusted Display role holder, verifies trusted local answers with
// anti-clickjacking arm delay and expiry bounds, and tracks issued grants.
package powerbox_service

import "base:intrinsics"
import "modus:contract/errors"
import "modus:contract/powerbox"
import "modus:contract/ring"
import "modus:contract/role_contract"
import "modus:contract/value_kinds"
import "internal:powerbox/powerbox_core"
import "modus:system"

// The pages of the arena that holds the grants that processes hold.
TABLE_PAGES :: 512

// Working memory budget for the freestanding powerbox service process: the
// grants (TABLE_PAGES), the stores of the picker and their index, which
// grow from the rest (512 pages: about 10 000 stores), and its data.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = TABLE_PAGES + 512 + 256, processes = 1, threads = 1}

// Status record returned by the status() export required by Role.Powerbox.
Powerbox_Status :: struct {
	pending_dialogs:        i64,
	total_requests:         i64,
	total_dialogs_shown:    i64,
	total_items_granted:    i64,
	total_items_refused:    i64,
	total_refused_requests: i64,
	total_expired_dialogs:  i64,
}

// Package-level BSS state so the service never places large tables on the stack.
service_state: powerbox_core.Powerbox_State
service_ring: ring.Ring
display_ring: ring.Ring
service_region_base: [^]u8
service_region_bytes: u64
service_ring_memory: system.Handle

// Buffers in BSS for copy-then-check reading of shared-memory records.
copied_batch: powerbox.Request_Batch
copied_answer: powerbox.Grant_Answer
outbound_dialog: powerbox.Dialog_Record
copied_page_request: powerbox.Picker_Page_Request
outbound_page: powerbox.Picker_Page
table_arena: system.Arena

// The stores of the principals for the picker grow in an arena of their
// own, in place, as large as the budget; their index is written again
// in a second arena at each growth. Both commit the exact pages of each
// growth, and keep STORE_KEPT_PAGES of the budget for the rest of the
// service.
store_arena: system.Arena
store_index_arena: system.Arena
STORE_KEPT_PAGES :: 64

@(private = "file")
store_push_allowed :: proc "contextless" (arena: ^system.Arena, bytes, alignment: u64) -> bool {
	pages, fits := system.arena_push_commit_pages(arena, bytes, alignment)
	amounts, status := system.budget_read()
	return fits && status == .Ok && amounts.pages >= STORE_KEPT_PAGES && pages <= amounts.pages - STORE_KEPT_PAGES
}

// stores_grow gives the core rows_least rows in place, and a new index of
// four slots for each row, a power of two.
@(private = "file")
stores_grow :: proc "contextless" (_: rawptr, state: ^powerbox_core.Powerbox_State, rows_least: int) -> bool {
	rows := len(state.stores)
	if rows_least > rows {
		bytes := u64(rows_least - rows) * size_of(powerbox_core.Session_Store)
		if !store_push_allowed(&store_arena, bytes, align_of(powerbox_core.Session_Store)) {
			return false
		}
		if _, status := system.arena_push(&store_arena, bytes, align_of(powerbox_core.Session_Store)); status != .Ok {
			return false
		}
		state.stores = ([^]powerbox_core.Session_Store)(store_arena.base)[:rows_least]
	}
	slots := 1
	for slots < 4 * len(state.stores) {
		slots *= 2
	}
	// The index of before is no longer read: its pages hold the new one.
	system.arena_reset(&store_index_arena)
	bytes := u64(slots) * size_of(u32)
	if !store_push_allowed(&store_index_arena, bytes, align_of(u32)) {
		state.store_index = nil
		return false
	}
	address, status := system.arena_push(&store_index_arena, bytes, align_of(u32))
	if status != .Ok {
		state.store_index = nil
		return false
	}
	state.store_index = ([^]u32)(address)[:slots]
	return true
}

// tables_make takes the held grants from the table arena, and starts the
// stores empty, in their arena of the size of the budget.
@(private = "file")
tables_make :: proc "contextless" () -> (tables: powerbox_core.Powerbox_Tables, ok: bool) {
	status: system.Status
	table_arena, status = system.arena_create(TABLE_PAGES)
	if status != .Ok {
		return {}, false
	}
	amounts, budget_status := system.budget_read()
	if budget_status != .Ok {
		return {}, false
	}
	reserve := system.arena_reservation_pages(amounts.pages)
	if store_arena, status = system.arena_create(reserve); status != .Ok {
		return {}, false
	}
	if store_index_arena, status = system.arena_create(reserve); status != .Ok {
		return {}, false
	}
	store_arena.exact_commits = true
	store_index_arena.exact_commits = true
	grant_rows := u64(TABLE_PAGES) * system.PAGE_SIZE / size_of(powerbox_core.Held_Grant)
	grants, grant_status := system.arena_push(&table_arena, grant_rows * size_of(powerbox_core.Held_Grant), align_of(powerbox_core.Held_Grant))
	if grant_status != .Ok {
		return {}, false
	}
	tables.held_grants = ([^]powerbox_core.Held_Grant)(grants)[:grant_rows]
	tables.stores_grow = stores_grow
	return tables, true
}

fail :: proc "contextless" (text: string) -> ! {
	system.log_fact(.Error, Service_Failed{failure = value_kinds.text_field(text, FAILURE_FIELD_BYTES)})
	system.stop(.Failed)
}

// declared_contract_hash returns the BLAKE3 hash of Role.Powerbox filled by
// this service.
declared_contract_hash :: proc "contextless" () -> role_contract.Contract_Hash {
	return role_contract.powerbox_contract_hash()
}

// pending_count returns the number of active pending consent dialogs across
// all sessions.
@(export)
pending_count :: proc "c" (error: ^errors.Error_Record) -> i64 {
	if service_state.next_dialog_serial == 0 {
		return errors.fail(error, -1, .State, .Requests)
	}
	return i64(service_state.counters.pending_dialogs)
}

// status writes the aggregate powerbox counters into out.
@(export)
status :: proc "c" (out: ^Powerbox_Status, error: ^errors.Error_Record) -> i64 {
	if out == nil {
		return errors.fail(error, -1, .Bad_Address, .None, 1)
	}
	if service_state.next_dialog_serial == 0 {
		return errors.fail(error, -2, .State, .Requests)
	}
	out^ = {
		pending_dialogs        = i64(service_state.counters.pending_dialogs),
		total_requests         = i64(service_state.counters.total_requests),
		total_dialogs_shown    = i64(service_state.counters.total_dialogs_shown),
		total_items_granted    = i64(service_state.counters.total_items_granted),
		total_items_refused    = i64(service_state.counters.total_items_refused),
		total_refused_requests = i64(service_state.counters.total_refused_requests),
		total_expired_dialogs  = i64(service_state.counters.total_expired_dialogs),
	}
	return 0
}

// region_range_valid checks that [offset, offset + length) lies wholly within
// the mapped shared region without u64 addition overflow.
@(private = "file")
region_range_valid :: proc "contextless" (offset: u64, length: u64) -> bool {
	if service_region_base == nil || length == 0 || length > service_region_bytes {
		return false
	}
	return offset <= service_region_bytes - length
}

// handle_command validates and executes one command record from service_ring.
@(private = "file")
handle_command :: proc "contextless" (command: ring.Record, now_ms: u64) -> (display_notified: bool) {
	parsed, ok := powerbox.service_ring_command_from_word(command.kind)
	if !ok {
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(powerbox.Service_Ring_Status.Bad_Command),
				tag    = command.tag,
				values = errors.ring_fail(command.kind, .Unsupported, .None, 0, i64(command.kind)),
			},
		)
		return false
	}

	switch parsed {
	case .None:
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(powerbox.Service_Ring_Status.Bad_Command),
				tag    = command.tag,
				values = errors.ring_fail(command.kind, .Unsupported, .None, 0, i64(command.kind)),
			},
		)
		return false
	case .Submit_Batch:
		batch_offset := command.values[0]
		dialog_offset := command.values[1]
		if !region_range_valid(batch_offset, size_of(powerbox.Request_Batch)) {
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(powerbox.Service_Ring_Status.Bad_Command),
					tag    = command.tag,
					values = errors.ring_fail(command.kind, .Out_Of_Range, .Bytes, 1, i64(batch_offset), i64(service_region_bytes)),
				},
			)
			return false
		}
		// Copy once out of shared memory before validating so the caller cannot
		// mutate fields after the border check.
		intrinsics.mem_copy_non_overlapping(&copied_batch, rawptr(&service_region_base[batch_offset]), size_of(powerbox.Request_Batch))
		resolution, dialog_record, has_dialog := powerbox_core.submit_batch(&service_state, &copied_batch, now_ms)
		if resolution.refusal != .None {
			system.log_fact(.Warning, Request_Refused{request_serial = resolution.request_serial, refusal_code = u64(resolution.refusal)})
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(powerbox.Service_Ring_Status.Refused),
					tag    = command.tag,
					values = {u64(resolution.refusal), resolution.request_serial, 0, 0, 0, 0, 0},
				},
			)
			return false
		}
		if has_dialog {
			outbound_dialog = dialog_record
			if region_range_valid(dialog_offset, size_of(powerbox.Dialog_Record)) {
				intrinsics.mem_copy_non_overlapping(rawptr(&service_region_base[dialog_offset]), &outbound_dialog, size_of(powerbox.Dialog_Record))
			}
			// The dialog of an asker waits in the region of the root service,
			// which gives it to the trusted display: the picker ring is the
			// ring of the commands of the display, which this service only
			// answers.
		}
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(powerbox.Service_Ring_Status.Ok),
				tag    = command.tag,
				values = {
					u64(resolution.refusal),
					resolution.dialog_serial,
					resolution.dialog_queued ? 1 : 0,
					resolution.all_held ? 1 : 0,
					u64(resolution.item_count),
					0,
					0,
				},
			},
		)
		return display_notified
	case .Display_Shown:
		dialog_serial := command.values[0]
		display_slot := u32(command.values[1])
		refusal := powerbox_core.mark_dialog_shown(&service_state, dialog_serial, display_slot, now_ms)
		status_word := refusal == .None ? u32(powerbox.Service_Ring_Status.Ok) : u32(powerbox.Service_Ring_Status.Refused)
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = status_word,
				tag    = command.tag,
				values = {u64(refusal), dialog_serial, now_ms, 0, 0, 0, 0},
			},
		)
		return false
	case .Display_Answer:
		answer_offset := command.values[0]
		if !region_range_valid(answer_offset, size_of(powerbox.Grant_Answer)) {
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(powerbox.Service_Ring_Status.Bad_Command),
					tag    = command.tag,
					values = errors.ring_fail(command.kind, .Out_Of_Range, .Bytes, 1, i64(answer_offset), i64(service_region_bytes)),
				},
			)
			return false
		}
		intrinsics.mem_copy_non_overlapping(&copied_answer, rawptr(&service_region_base[answer_offset]), size_of(powerbox.Grant_Answer))
		resolution := powerbox_core.resolve_answer(&service_state, &copied_answer, now_ms)
		status_word := resolution.refusal == .None ? u32(powerbox.Service_Ring_Status.Ok) : u32(powerbox.Service_Ring_Status.Refused)
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = status_word,
				tag    = command.tag,
				values = {u64(resolution.refusal), resolution.dialog_serial, resolution.request_serial, u64(resolution.item_count), 0, 0, 0},
			},
		)
		return false
	case .Withdraw_Dialog:
		process_slot := u32(command.values[0])
		withdrawn, revoked := powerbox_core.withdraw_for_process(&service_state, process_slot)
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(powerbox.Service_Ring_Status.Ok),
				tag    = command.tag,
				values = {u64(withdrawn), u64(revoked), 0, 0, 0, 0, 0},
			},
		)
		return false
	case .Picker_Page:
		// values[0]: the offset of the request in the region, values[1]: the
		// offset of the page, values[2]: the slot of the trusted display.
		request_offset := command.values[0]
		page_offset := command.values[1]
		if !region_range_valid(request_offset, size_of(powerbox.Picker_Page_Request)) || !region_range_valid(page_offset, size_of(powerbox.Picker_Page)) {
			ring.push(
				&service_ring.completions,
				ring.Record{
					kind   = u32(powerbox.Service_Ring_Status.Bad_Command),
					tag    = command.tag,
					values = errors.ring_fail(command.kind, .Out_Of_Range, .Bytes, 1, i64(request_offset), i64(service_region_bytes)),
				},
			)
			return false
		}
		// Copy once out of shared memory before the check.
		intrinsics.mem_copy_non_overlapping(&copied_page_request, rawptr(&service_region_base[request_offset]), size_of(powerbox.Picker_Page_Request))
		refusal := powerbox_core.picker_page_take(&service_state, u32(command.values[2]), &copied_page_request, &outbound_page)
		if refusal == .None {
			intrinsics.mem_copy_non_overlapping(rawptr(&service_region_base[page_offset]), &outbound_page, size_of(powerbox.Picker_Page))
		}
		status_word := refusal == .None ? u32(powerbox.Service_Ring_Status.Ok) : u32(powerbox.Service_Ring_Status.Refused)
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = status_word,
				tag    = command.tag,
				values = {u64(refusal), copied_page_request.dialog_serial, u64(outbound_page.candidate_count), u64(outbound_page.next), u64(outbound_page.total), outbound_page.more ? 1 : 0, 0},
			},
		)
		return false
	case .Stores_Connection:
		stores_connection_take(command)
		return false
	case .Stores_Refused:
		if stores_refused_take(command) {
			system.wake_reader(&display_ring.completions)
		}
		return false
	case .Query_Counts:
		counters := service_state.counters
		ring.push(
			&service_ring.completions,
			ring.Record{
				kind   = u32(powerbox.Service_Ring_Status.Ok),
				tag    = command.tag,
				values = {
					counters.pending_dialogs,
					counters.total_requests,
					counters.total_dialogs_shown,
					counters.total_items_granted,
					counters.total_items_refused,
					counters.total_refused_requests,
					counters.total_expired_dialogs,
				},
			},
		)
		return false
	}
	return false
}

// entry initializes the delegated powerbox service rings and loops over
// consent commands and expiry ticks until stopped.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	export_service, export_ok := system.service_open(ctx)
	has_delegated := false
	if ctx.handles[powerbox.SERVICE_RING_SLOT] != 0 && ctx.handles[powerbox.TRUSTED_DISPLAY_RING_SLOT] != 0 {
		status_open: system.Status
		// The root service gives the handles of a connection to the
		// storage service through this ring (Stores_Connection).
		service_ring_memory = ctx.handles[powerbox.SERVICE_RING_SLOT]
		if service_ring, status_open = system.ring_open(service_ring_memory, receive_handles = true); status_open == .Ok {
			if display_ring, status_open = system.ring_open(ctx.handles[powerbox.TRUSTED_DISPLAY_RING_SLOT]); status_open == .Ok {
				has_delegated = true
			}
		}
	}
	picker_region_open(ctx)
	if !export_ok && !has_delegated {
		fail("no powerbox service ring")
	}

	region_handle := ctx.handles[powerbox.SERVICE_REGION_SLOT]
	if region_handle != 0 {
		pages, size_status := system.memory_size(region_handle)
		if size_status != .Ok || pages == 0 {
			fail("the powerbox data region has no pages")
		}
		address, map_status := system.memory_map(region_handle, {.Write})
		if map_status != .Ok {
			fail("cannot map the powerbox data region")
		}
		service_region_base = ([^]u8)(address)
		service_region_bytes = pages * system.PAGE_SIZE
	}

	display_slot := u32(ctx.values[powerbox.CONTEXT_VALUE_DISPLAY_SLOT])
	tables, tables_ok := tables_make()
	if !tables_ok {
		fail("no memory for the tables of the powerbox")
	}
	powerbox_core.state_init(&service_state, display_slot, tables)

	contract_digest := declared_contract_hash()
	_ = contract_digest
	system.log_fact(.Info, Service_Ready{display_slot = u64(display_slot), contract_version = u64(role_contract.POWERBOX_CONTRACT_VERSION)})

	for {
		wait := system.wait_begin()
		now_ms := system.time()
		if expired := powerbox_core.expire_dialogs(&service_state, now_ms); expired > 0 {
			system.log_fact(.Info, Dialogs_Expired{expired_dialogs = u64(expired)})
		}

		if export_ok {
			system.service_run(&export_service)
			system.service_wait(&wait, &export_service)
		}
		if has_delegated {
			answered := false
			display_notified := false
			drained := 0
			for drained < powerbox.REQUESTS_PER_PASS && ring.count(&service_ring.completions) < ring.capacity(&service_ring.completions) {
				command := system.receive(&service_ring.commands) or_break
				if handle_command(command, now_ms) {
					display_notified = true
				}
				answered = true
				drained += 1
			}

			if picker_ring_serve(now_ms) {
				system.wake_reader(&display_ring.completions)
			}
			if stores_call_step(now_ms) {
				answered = true
				system.wake_reader(&display_ring.completions)
			}
			if answered || stores_wanted_sent {
				stores_wanted_sent = false
				system.wake_reader(&service_ring.completions)
			}
			_ = display_notified
			if drained == powerbox.REQUESTS_PER_PASS && ring.count(&service_ring.commands) > 0 {
				continue
			}
			system.wait_records(&wait, &service_ring.commands)
			system.wait_records(&wait, &display_ring.commands)
			if stores_call.active {
				system.wait_records(&wait, &stores_call.client.calls.completions)
			}
		}
		if picker_open_wait.active || stores_call.active {
			// An Open that waits ends at its bound: the loop runs then.
			system.wait_end(&wait, picker_wait_deadline())
		} else if service_state.counters.pending_dialogs > 0 {
			system.wait_end(&wait, now_ms + 1000)
		} else {
			system.wait_end(&wait)
		}
	}
}
