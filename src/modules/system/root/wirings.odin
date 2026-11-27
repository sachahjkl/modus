package root

// Delegated wiring core bridge (src/md/api/root_service_split.md).
//
// All wiring validation, record-type matching, generic stream resolution,
// condition checking, ring/end allocation, completion tracking, and stop
// cleanup live in the separate `wiring` service process
// (`src/modules/system/wiring`). This file keeps only what the root core
// must own:
//
// - starting `wiring` on demand with its four attenuated context handles
//   (core ring, stops ring, read-only boot image, shared transfer region);
// - emitting `Process_Stop_Notice` records on the core's `stops` output
//   ring at reap and release;
// - supplying per-asker Spend-only child wiring budgets and per-process
//   Give-only process tokens + wiring rings;
// - proving and closing lent handles on each asker's root ring and
//   resolving connection numbers against the core's connection table;
// - driving in-flight requests to `wiring` asynchronously from
//   `root_loop_pass` so the core never blocks on the delegated service.

import "base:intrinsics"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/output"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:contract/wide_grants"
import ws "modus:contract/wiring_service"
import "internal:root/start_policy_rules"
import "modus:random"
import "modus:system"

// Bound on restarts of the delegated wiring service after a crash.
WIRING_RESTART_LIMIT :: 3

// Hang bound for one request to the delegated wiring service.
WIRING_REQUEST_BOUND_MILLISECONDS :: system.ANSWER_BOUND_MILLISECONDS

// Child wiring budget reserve carved from an asker's budget (pages only:
// zero processes, zero threads, zero processor time, zero log records).
WIRING_ASKER_BUDGET_PAGES_MIN :: output.WIRING_LIST_PAGES_MOST + 1

// Pre-allocated child ends prepared by `wiring` for a Start with wiring list.
Premade_Start_Wiring :: struct {
	ends:          []output.Given_End,
	log_ring:      system.Handle,
	log_end_words: system.Handle,
}

// Stage of the one in-flight request from the core to `wiring`.
Wiring_Request_Stage :: enum u8 {
	Idle,
	List_Page,
	Wire,
	Start_Prepare,
	Start_Commit,
	Revoke_Asker,
}

// One in-flight request to the delegated wiring service.
Wiring_Request :: struct {
	stage:            Wiring_Request_Stage,
	command:          ws.Command_Kind,
	root_command:     root_ring.Root_Command,
	tag:              u32, // Tag of the asker's root ring command.
	service_tag:      u32, // Tag sent on wiring_ring.
	asker:            ^Started, // Process awaiting completion on its root ring.
	target:           ^Started, // Revoke_Asker: process whose wirings are revoked.
	child:            ^Started, // Start_Commit: newly started child.
	batch_id:         u32, // Prepare/Commit batch identifier.
	start_name:             system.Name,
	start_principal:        u64,
	start_answer:           root_ring.Start_Answer,
	start_budget_unbounded: bool,
	for_start_policy:       bool,
	counted_restart:    ^start_policy_rules.Name_Count,
	start_reply_handle: u64,
	deadline:           u64,
	// A request of the audit of a wide grant: the root service asked it
	// for itself, and its answer goes to the path of the grant with the
	// flow that asked it, not to a ring (wide_grant_authority.odin).
	audit:             Audit_Request,
	audit_flow_serial: u64,
}

// What the root service asked the wiring service for the audit of a wide
// grant.
Audit_Request :: enum u8 {
	None   = 0,
	Wire   = 1, // The Wire of one writer of act records to the collector.
	Unwire = 2, // The end of the wirings whose asker is the collector.
}

// State of the delegated `wiring` service process.
wiring_process: ^Started
wiring_ring_memory: system.Handle
wiring_ring: ring.Ring
wiring_stops_memory: system.Handle
wiring_stops_ring: ring.Ring
wiring_region_memory: system.Handle
wiring_region: []u8
wiring_starts: int
wiring_next_tag: u32 = 1
wiring_request: Wiring_Request

// Private copy of an asker's list page and staging buffers for core->wiring.
core_list_copy: [output.WIRING_LIST_BYTES_MOST]u8
core_resolved_req: ws.Resolved_Wiring_Request
core_prepared_resp: ws.Prepared_Start_Ends
core_child_ends: [output.WIRING_LIST_ROW_LIMIT]output.Given_End

// wiring_service_start launches `wiring` with only its four attenuated
// context handles and logs its start. Returns false past WIRING_RESTART_LIMIT
// or on failure.
wiring_service_start :: proc "contextless" () -> bool {
	if wiring_process != nil {
		return true
	}
	if wiring_starts >= WIRING_RESTART_LIMIT {
		return false
	}
	slot := part_place_take()
	if slot == nil {
		return false
	}
	file := image_file_checked("wiring")
	if len(file) == 0 {
		return false
	}
	ring_mem, ring_opened, status := system.ring_create(receive_handles = true)
	stops_mem: system.Handle
	stops_opened: ring.Ring
	reg_mem: system.Handle
	reg_addr: rawptr
	if status == .Succeeded {
		stops_mem, stops_opened, status = system.ring_create()
	}
	if status == .Succeeded {
		reg_mem, status = system.memory_create(ws.SERVICE_REGION_PAGES)
	}
	if status == .Succeeded {
		reg_addr, status = system.memory_map(reg_mem, {.Write})
	}
	process: system.Handle
	wiring_budget: Start_Budget
	if status == .Succeeded {
		grants: system.Context_Grants
		values: system.Context_Values
		system.grant_put(&grants, ws.SERVICE_RING, {ring_mem, {.Read, .Write}})
		system.grant_put(&grants, ws.SERVICE_STOPS_RING, {stops_mem, {.Read, .Write}})
		system.grant_put(&grants, ws.SERVICE_IMAGE, {image_memory, {.Read}})
		system.grant_put(&grants, ws.SERVICE_REGION, {reg_mem, {.Read, .Write}})
		system.grant_put(&grants, op.CONTEXT_LOG, log_grant(start_grant_set_of("wiring")))
		system.value_put(&values, ws.VALUE_IMAGE_SIZE, u64(len(image)))
		budget_ok: bool
		if context_refused("wiring", &grants, &values) {
			status = .Wrong_State
		} else if wiring_budget, budget_ok = budget_of(file, "wiring"); !budget_ok {
			status = .Budget_Or_Capacity_Exhausted
		} else {
			process, status = system.process_start(file, "wiring", grants.grants, random.values_with_seed(&process_generator, values.values), wiring_budget.amounts, nil, &prepared, load_source(), ready = &slot.ready)
		}
	}
	if status != .Succeeded {
		if reg_addr != nil {
			system.memory_unmap(reg_addr)
		}
		if stops_opened.head != nil {
			system.ring_close(&stops_opened)
		}
		if ring_opened.head != nil {
			system.ring_close(&ring_opened)
		}
		for h in ([3]system.Handle{ring_mem, stops_mem, reg_mem}) {
			if h != 0 {
				system.close(h)
			}
		}
		system.log_fact(.Warning, Wiring_Service_Start_Failed{status_number = u64(status)})
		return false
	}
	part_place_fill(slot, "wiring", process)
	start_budget_note(slot, wiring_budget)
	slot.process_slot, slot.process_serial, _ = system.process_place(process)
	wiring_process = slot
	wiring_ring_memory, wiring_ring = ring_mem, ring_opened
	wiring_stops_memory, wiring_stops_ring = stops_mem, stops_opened
	wiring_region_memory = reg_mem
	wiring_region = ([^]u8)(reg_addr)[:ws.SERVICE_REGION_SIZE]
	wiring_starts += 1
	system.log_fact(.Info, Wiring_Service_Started{starts = u64(wiring_starts), start_limit = u64(WIRING_RESTART_LIMIT)})

	// Register every already-running process that participates in wirings.
	for &item in started {
		if item.process != 0 && &item != wiring_process && !item.is_terminal {
			item.wiring_registered = false
			wiring_register_process(&item)
		}
	}
	return true
}

// wiring_service_end cleans up if `wiring` stops, and fails any in-flight
// request so its caller never hangs.
wiring_service_end :: proc "contextless" (item: ^Started) {
	if item != wiring_process {
		return
	}
	if wiring_request.stage != .Idle {
		// The wiring service stopped during the request.
		wiring_request_fail(.Callee_Stopped_During_The_Call, errors.ring_fail(u32(wiring_request.root_command), .Callee_Stopped, .Services))
	}
	if raw_data(wiring_region) != nil {
		system.memory_unmap(raw_data(wiring_region))
		wiring_region = nil
	}
	if wiring_stops_ring.head != nil {
		system.ring_close(&wiring_stops_ring)
	}
	if wiring_ring.head != nil {
		system.ring_close(&wiring_ring)
	}
	for h in ([3]system.Handle{wiring_ring_memory, wiring_stops_memory, wiring_region_memory}) {
		if h != 0 {
			system.close(h)
		}
	}
	wiring_ring_memory, wiring_stops_memory, wiring_region_memory = 0, 0, 0
	wiring_process = nil
	for &other in started {
		other.wiring_registered = false
	}
	system.log_fact(.Warning, Wiring_Service_Stopped{})
}

// process_flags_of builds the attenuated Process_Flags describing a Started
// process for `wiring`.
@(private = "file")
process_flags_of :: proc "contextless" (item: ^Started) -> (flags: ws.Process_Flags) {
	if item.service.head != nil {
		flags += {.Is_Service}
	}
	if .Start_Policy in item.start_grant_set.grants {
		flags += {.Is_Start_Policy}
	}
	if .Acts_For_Principal in grants_held(item) {
		flags += {.Acts_For_Principal}
	}
	if root_ring.sender_allowed(.Wire, item.start_grant_set.grants) {
		flags += {.Can_Wire}
	}
	if item.wiring_memory != 0 {
		flags += {.Has_Wiring_Ring}
	}
	return flags
}

// wiring_register_process supplies `wiring` with a Give-only process token,
// the process's wiring ring (if any), and its read-only module slice in the
// boot image.
wiring_register_process :: proc "contextless" (item: ^Started) {
	if wiring_process == nil || item == nil || item == wiring_process || item.held_for_replay || item.process == 0 || item.process_slot == 0 || item.process_serial == 0 {
		return
	}
	token, status := give_through_service_ring(wiring_process.process, wiring_ring_memory, item.process, {.Give}, &wiring_process.service_ring_ready)
	if status != .Succeeded {
		return
	}
	ring_given: system.Handle
	if item.wiring_memory != 0 {
		ring_given, status = give_through_service_ring(wiring_process.process, wiring_ring_memory, item.wiring_memory, {.Read, .Write}, &wiring_process.service_ring_ready)
		if status != .Succeeded {
			return
		}
	}
	flags := process_flags_of(item)
	if ring_given == 0 {
		flags -= {.Has_Wiring_Ring}
	}
	cmd := ws.Command{
		kind               = .Register_Process,
		tag                = 0,
		process            = {item.process_slot, item.process_serial},
		module_offset      = item.module_offset,
		module_size        = item.module_size,
		process_handle     = op.Handle(token),
		wiring_ring_handle = op.Handle(ring_given),
		flags              = flags,
		principal          = item.principal,
	}
	if system.send(&wiring_ring.commands, ws.command_to_record(cmd)) {
		item.wiring_registered = true
	}
}

// wiring_pages_stated gives the wiring pages of an asker's module floor:
// the wiring pages that its module file states, or half of its floor pages
// when it states none.
@(private = "file")
wiring_pages_stated :: proc "contextless" (asker: ^Started) -> u64 {
	file := image_file_checked(system.name_of(asker.name[:]))
	request: module.Floor
	if module.validate(file) == .None {
		request, _ = module.floor_read(file)
	}
	return system.wiring_pages_of_floor(request)
}

// wiring_asker_budget_ensure carves a pages-only child wiring budget from
// asker.budget and gives `wiring` a Spend-only handle to it.
@(private = "file")
wiring_asker_budget_ensure :: proc "contextless" (asker: ^Started, command: root_ring.Root_Command, values: ^[7]u64) -> call_outcome.Call_Outcome {
	if asker.wiring_budget != 0 {
		return .Succeeded
	}
	if asker.budget == 0 {
		return root_ring.refuse(values, .Budget_Or_Capacity_Exhausted, u32(command), .Budget_Hidden, .Pages)
	}
	avail, read_status := system.budget_read(asker.budget)
	if read_status != .Succeeded {
		return root_ring.refuse(values, .Budget_Or_Capacity_Exhausted, u32(command), .Budget_Hidden, .Pages)
	}
	list_cost := op.memory_cost(output.WIRING_LIST_PAGES_MOST)
	if avail.pages < list_cost {
		return root_ring.refuse(values, .Budget_Or_Capacity_Exhausted, u32(command), .Budget, .Pages, 1, 0, i64(list_cost), i64(avail.pages))
	}
	// A stated amount, whatever the asker spent before its first wiring
	// (src/md/features/module_outputs.md, "The bounds of the wirings"): for
	// the start policy, what the header of its list says that its rows
	// cost, which its budget was widened by; for each other asker, the
	// wiring pages of its module file, or half of the pages that it asks
	// when it states none.
	stated := wiring_pages_stated(asker)
	if asker == start_policy_process && start_list_wiring_pages > 0 {
		stated = start_list_wiring_pages
	}
	pages := min(avail.pages, stated)
	if pages < list_cost {
		return root_ring.refuse(values, .Budget_Or_Capacity_Exhausted, u32(command), .Budget, .Pages, 1, 0, i64(list_cost), i64(pages))
	}
	err: errors.Error_Record
	child, status := system.budget_create({pages = pages}, asker.budget, error = &err)
	if status != .Succeeded {
		// The budget of the asker cannot give the budget of its wirings:
		// the record of the kernel, under the outcome of its status.
		err.operation = i64(command)
		outcome := system.own_operation_outcome(status)
		values^ = errors.completion_values(call_outcome.record_explained(outcome, err))
		return outcome
	}
	given, give_status := give_through_service_ring(wiring_process.process, wiring_ring_memory, child, {.Spend}, &wiring_process.service_ring_ready)
	if give_status != .Succeeded {
		system.close(child)
		return root_ring.refuse(values, system.own_operation_outcome(give_status), u32(command), .Refused, .Wirings, 0, 0, 0, i64(give_status))
	}
	cmd := ws.Command{
		kind          = .Grant_Asker_Budget,
		tag           = 0,
		process       = {asker.process_slot, asker.process_serial},
		budget_handle = op.Handle(given),
	}
	if !system.send(&wiring_ring.commands, ws.command_to_record(cmd)) {
		system.close(child)
		return root_ring.refuse(values, .Callee_Busy, u32(command), .Busy, .Requests, 0, 1, 1)
	}
	asker.wiring_budget = child
	return .Succeeded
}

// wiring_emit_stop_notice emits one Process_Stop_Notice onto the core's
// `stops` output ring for `wiring` and releases the core's wiring handles
// for `item`.
wiring_emit_stop_notice :: proc "contextless" (item: ^Started, stop: Process_Stop) {
	if wiring_request.stage != .Idle {
		if wiring_request.asker == item {
			if wiring_request.stage == .Start_Prepare && wiring_request.batch_id != 0 && wiring_ring.head != nil {
				abort_cmd := ws.Command{kind = .Abort_Start_Wiring, batch_id = wiring_request.batch_id}
				_ = system.send(&wiring_ring.commands, ws.command_to_record(abort_cmd))
			}
			wiring_request = {}
		} else {
			// A child that already started and exited quickly before Start_Commit
			// returns must NOT drop the asker's Start reply; clear only the pointer.
			if wiring_request.child == item {
				wiring_request.child = nil
			}
			if wiring_request.target == item {
				wiring_request.target = nil
			}
		}
	}
	if wiring_stops_ring.head != nil && item != wiring_process && item.process_slot != 0 && item.process_serial != 0 {
		notice: ws.Process_Stop_Notice
		if stop.state == .Stopped && stop.cause != .None {
			notice = {
				process_slot   = item.process_slot,
				process_serial = item.process_serial,
				kind           = .Process_Stopped,
				cause          = stop.cause,
				outcome        = stop.outcome,
			}
		} else {
			notice = {
				process_slot   = item.process_slot,
				process_serial = item.process_serial,
				kind           = .Process_Abandoned,
			}
		}
		_ = system.send(&wiring_stops_ring.commands, ws.stop_notice_to_record(notice))
	}
	for h in ([4]^system.Handle{&item.wiring_memory, &item.list_memory, &item.wiring_budget, &item.budget}) {
		if h^ != 0 {
			system.close(h^)
			h^ = 0
		}
	}
	item.wiring_registered = false
}

// lent_handle_of proves whether a lent handle number came through the
// asker's root ring.
@(private = "file")
lent_handle_of :: proc "contextless" (asker: ^Started, handle: u32) -> (kind: op.Object_Kind, through: bool) {
	if handle == 0 {
		return {}, false
	}
	kind, _, through = system.handle_state(system.Handle(handle), asker.requests_memory)
	return kind, through
}

// process_of_lent_handle resolves a proved process handle to its Started slot.
@(private = "file")
process_of_lent_handle :: proc "contextless" (handle: system.Handle) -> ^Started {
	lent_slot, lent_serial, lent_status := system.process_place(handle)
	if lent_status != .Succeeded {
		return nil
	}
	for &item in started {
		if item.process != 0 && item.process_slot == lent_slot && item.process_serial == lent_serial {
			return &item
		}
	}
	return nil
}

// connected_service resolves a caller's Connect handle number to the service
// process in the core's connection table.
@(private = "file")
connected_service :: proc "contextless" (asker: ^Started, number: system.Handle) -> (service: ^Started, plain_connection: bool) {
	found: ^Started
	for &connection in connections {
		if connection.caller != asker || connection.history || connection.caller_service_handle != number {
			continue
		}
		if found != nil {
			return nil, false
		}
		found = connection.service
		plain_connection = connection.client.place == 0
	}
	return found, plain_connection
}

// list_page_copy copies the asker's list page once into core_list_copy.
@(private = "file")
list_page_copy :: proc "contextless" (asker: ^Started) -> bool {
	if asker.list_memory == 0 {
		return false
	}
	address, status := system.memory_map(asker.list_memory, {})
	if status != .Succeeded {
		return false
	}
	intrinsics.mem_copy_non_overlapping(&core_list_copy[0], address, output.WIRING_LIST_BYTES_MOST)
	system.memory_unmap(address)
	return true
}

// lent_handles_close closes every handle listed in the asker's list page
// that came through the asker's root ring.
lent_handles_close :: proc "contextless" (asker: ^Started, copied := false) {
	if !copied && !list_page_copy(asker) {
		return
	}
	head: output.Wiring_List_Head
	intrinsics.mem_copy_non_overlapping(&head, &core_list_copy[0], size_of(head))
	if head.row_count > output.WIRING_LIST_ROW_LIMIT || head.handle_count > output.WIRING_LIST_HANDLE_LIMIT {
		return
	}
	first := size_of(output.Wiring_List_Head) + int(head.row_count) * size_of(output.Wiring)
	for place in 0 ..< int(head.handle_count) {
		word: u32
		intrinsics.mem_copy_non_overlapping(&word, &core_list_copy[first + place * size_of(u32)], size_of(u32))
		if _, through := lent_handle_of(asker, word); through {
			system.close(system.Handle(word))
		}
	}
}

// list_stage_for_wiring copies the asker's list page, proves and closes all
// lent handles on asker.requests_memory, resolves Connected numbers against
// `connections`, and writes both into wiring_region.
@(private = "file")
list_stage_for_wiring :: proc "contextless" (asker: ^Started, form: output.Wiring_List_Form, command: root_ring.Root_Command, child_offset, child_size: u64, values: ^[7]u64) -> call_outcome.Call_Outcome {
	if !list_page_copy(asker) {
		return root_ring.refuse(values, .Nothing_Has_That_Name, u32(command), .Absent, .Wirings)
	}
	checked: output.Checked_Wiring_List
	refusal, ok := output.wiring_list_check(core_list_copy[:], form, &checked)
	if !ok {
		// The check of the form of the list: each of its refusals breaks a
		// rule of the argument.
		lent_handles_close(asker, copied = true)
		refusal.operation = i64(command)
		values^ = errors.completion_values(refusal)
		return .Argument_Refused
	}
	core_resolved_req = {
		form                  = u32(form),
		list_bytes            = output.WIRING_LIST_BYTES_MOST,
		asker_is_start_policy = .Start_Policy in asker.start_grant_set.grants ? 1 : 0,
		lent_count            = checked.handle_count,
		child_module_offset   = child_offset,
		child_module_size     = child_size,
	}
	outcome := call_outcome.Call_Outcome.Succeeded
	for place in 0 ..< checked.handle_count {
		number := checked.handles[place]
		handle := system.Handle(number)
		kind, through := lent_handle_of(asker, number)
		target: ^Started
		if through {
			if kind == .Process {
				target = process_of_lent_handle(handle)
			}
			system.close(handle)
		}
		if outcome != .Succeeded {
			continue
		}
		switch {
		case !through:
			outcome = root_ring.refuse(values, .Argument_Refused, u32(command), .Handle_Absent, .Lent_Handles, 0, i64(place) + 1)
		case kind != .Process:
			outcome = root_ring.refuse(values, .Argument_Refused, u32(command), .Handle_Kind, .Lent_Handles, 0, i64(place) + 1, i64(op.Object_Kind.Process), i64(kind))
		case target == nil:
			outcome = root_ring.refuse(values, .Argument_Refused, u32(command), .Handle_Absent, .Lent_Handles, 0, i64(place) + 1)
		case:
			if !target.wiring_registered {
				wiring_register_process(target)
			}
			core_resolved_req.lent[place] = {
				process_slot            = target.process_slot,
				process_serial          = target.process_serial,
				started_by_asker        = target.asker == asker ? 1 : 0,
				started_by_start_policy = target.asked_by_start_policy ? 1 : 0,
				present                 = 1,
			}
		}
	}
	if outcome != .Succeeded {
		return outcome
	}
	acts := .Acts_For_Principal in grants_held(asker)
	for row_idx in 0 ..< checked.row_count {
		row := checked.rows[row_idx]
		conn_handles := [2]u32{row.writer_end == .Connected ? row.writer_handle : 0, row.reader_end == .Connected ? row.reader_handle : 0}
		for ch in conn_handles {
			if ch == 0 {
				continue
			}
			duplicate := false
			for seen in 0 ..< core_resolved_req.connected_count {
				if core_resolved_req.connected[seen].handle_number == ch {
					duplicate = true
					break
				}
			}
			if duplicate || core_resolved_req.connected_count >= ws.RESOLVED_CONNECTED_LIMIT {
				continue
			}
			svc, plain := connected_service(asker, system.Handle(ch))
			entry := ws.Resolved_Connected_End{handle_number = ch}
			if svc != nil {
				if !svc.wiring_registered {
					wiring_register_process(svc)
				}
				entry.process_slot = svc.process_slot
				entry.process_serial = svc.process_serial
				entry.asker_acts_for_principal = acts ? 1 : 0
				entry.process_is_a_service = svc.service.head != nil ? 1 : 0
				entry.asker_holds_a_connection = plain ? 1 : 0
				entry.present = 1
			}
			core_resolved_req.connected[core_resolved_req.connected_count] = entry
			core_resolved_req.connected_count += 1
		}
	}
	intrinsics.mem_copy_non_overlapping(&wiring_region[ws.REGION_LIST_OFFSET], &core_list_copy[0], output.WIRING_LIST_BYTES_MOST)
	intrinsics.mem_copy_non_overlapping(&wiring_region[ws.REGION_REQUEST_OFFSET], &core_resolved_req, size_of(ws.Resolved_Wiring_Request))
	return .Succeeded
}

@(private = "file")
next_service_tag :: proc "contextless" () -> u32 {
	tag := wiring_next_tag
	wiring_next_tag = wiring_next_tag == max(u32) ? 1 : wiring_next_tag + 1
	return tag
}

// wire_begin starts an asynchronous Wire (List_Page or Apply) delegated to `wiring`.
wire_begin :: proc "contextless" (asker: ^Started, record: ring.Record, values: ^[7]u64) -> (outcome: call_outcome.Call_Outcome, held: bool) {
	command := root_ring.Root_Command.Wire
	step, step_ok := root_ring.wire_step_of_word(record.values[0])
	if !step_ok {
		lent_handles_close(asker)
		values^ = root_ring.word_refusal(command, 1, record.values[0], u64(max(root_ring.Wire_Step)))
		return .Argument_Refused, false
	}
	for index in 1 ..< len(record.values) {
		if record.values[index] != 0 {
			lent_handles_close(asker)
			values^ = root_ring.word_refusal(command, i64(index) + 1, record.values[index], 0)
			return .Argument_Refused, false
		}
	}
	if wiring_request.stage != .Idle {
		if step == .Apply {
			lent_handles_close(asker)
		}
		return root_ring.refuse(values, .Callee_Busy, u32(command), .Busy, .Requests, 0, 1, 1), false
	}
	if !wiring_service_start() {
		if step == .Apply {
			lent_handles_close(asker)
		}
		return root_ring.refuse(values, .Callee_Unavailable, u32(command), .Refused, .Services), false
	}
	if !asker.wiring_registered {
		wiring_register_process(asker)
	}
	switch step {
	case .None:
		// The border refused None above; the case keeps the switch whole.
		return root_ring.refuse(values, .Argument_Refused, u32(command), .Bad_Value, .None, 1), false
	case .List_Page:
		if budget_st := wiring_asker_budget_ensure(asker, command, values); budget_st != .Succeeded {
			return budget_st, false
		}
		stag := next_service_tag()
		cmd := ws.Command{kind = .List_Page, tag = stag, process = {asker.process_slot, asker.process_serial}}
		if !system.send(&wiring_ring.commands, ws.command_to_record(cmd)) {
			return root_ring.refuse(values, .Callee_Busy, u32(command), .Busy, .Requests, 0, 1, 1), false
		}
		wiring_request = {
			stage        = .List_Page,
			command      = .List_Page,
			root_command = command,
			tag          = record.tag,
			service_tag  = stag,
			asker        = asker,
			deadline     = system.time() + WIRING_REQUEST_BOUND_MILLISECONDS,
		}
		return .Succeeded, true
	case .Apply:
		if stage_st := list_stage_for_wiring(asker, .Wire, command, 0, 0, values); stage_st != .Succeeded {
			return stage_st, false
		}
		if budget_st := wiring_asker_budget_ensure(asker, command, values); budget_st != .Succeeded {
			return budget_st, false
		}
		stag := next_service_tag()
		cmd := ws.Command{kind = .Wire, tag = stag, process = {asker.process_slot, asker.process_serial}, flags = process_flags_of(asker)}
		if !system.send(&wiring_ring.commands, ws.command_to_record(cmd)) {
			return root_ring.refuse(values, .Callee_Busy, u32(command), .Busy, .Requests, 0, 1, 1), false
		}
		wiring_request = {
			stage        = .Wire,
			command      = .Wire,
			root_command = command,
			tag          = record.tag,
			service_tag  = stag,
			asker        = asker,
			deadline     = system.time() + WIRING_REQUEST_BOUND_MILLISECONDS,
		}
		return .Succeeded, true
	}
	return root_ring.refuse(values, .Argument_Refused, u32(command), .Bad_Value, .None, 1), false
}

// start_with_wiring_begin starts an asynchronous Prepare_Start_Wiring for
// a Start with Start_Wiring_List.In_The_List_Page.
start_with_wiring_begin :: proc "contextless" (asker: ^Started, tag: u32, name: string, principal: u64, start_answer: root_ring.Start_Answer, for_start_policy: bool, counted: ^start_policy_rules.Name_Count, values: ^[7]u64, budget_unbounded := false) -> (outcome: call_outcome.Call_Outcome, held: bool) {
	command := root_ring.Root_Command.Start
	if wiring_request.stage != .Idle {
		lent_handles_close(asker)
		return root_ring.refuse(values, .Callee_Busy, u32(command), .Busy, .Requests, 0, 1, 1), false
	}
	if name_is_a_system_part(name) {
		lent_handles_close(asker)
		return root_ring.refuse(values, .Grant_Or_Right_Missing, u32(command), .Reserved, .None, 1), false
	}
	child_offset, child_size: u64
	for &entry in system.image_entries(image) {
		if system.name_of(entry.name[:]) == name && entry.offset <= u64(len(image)) && entry.size <= u64(len(image)) - entry.offset {
			// The wiring service reads the module at this offset: its bytes
			// have the hash of their entry first.
			if image_entry_give(&entry) {
				child_offset, child_size = entry.offset, entry.size
			}
			break
		}
	}
	if child_size == 0 {
		lent_handles_close(asker)
		return root_ring.refuse(values, .Nothing_Has_That_Name, u32(command), .Absent, .Modules, 1), false
	}
	if !wiring_service_start() {
		lent_handles_close(asker)
		return root_ring.refuse(values, .Callee_Unavailable, u32(command), .Refused, .Services), false
	}
	if !asker.wiring_registered {
		wiring_register_process(asker)
	}
	if stage_st := list_stage_for_wiring(asker, .Start, command, child_offset, child_size, values); stage_st != .Succeeded {
		return stage_st, false
	}
	if budget_st := wiring_asker_budget_ensure(asker, command, values); budget_st != .Succeeded {
		return budget_st, false
	}
	stag := next_service_tag()
	cmd := ws.Command{
		kind          = .Prepare_Start_Wiring,
		tag           = stag,
		process       = {asker.process_slot, asker.process_serial},
		flags         = process_flags_of(asker),
		module_offset = child_offset,
		module_size   = child_size,
	}
	if !system.send(&wiring_ring.commands, ws.command_to_record(cmd)) {
		return root_ring.refuse(values, .Callee_Busy, u32(command), .Busy, .Requests, 0, 1, 1), false
	}
	packed_name: system.Name
	copy(packed_name[:len(packed_name) - 1], name)
	wiring_request = {
		stage                  = .Start_Prepare,
		command                = .Prepare_Start_Wiring,
		root_command           = command,
		tag                    = tag,
		service_tag            = stag,
		asker                  = asker,
		start_name             = packed_name,
		start_principal        = principal,
		start_answer           = start_answer,
		start_budget_unbounded = budget_unbounded,
		for_start_policy       = for_start_policy,
		counted_restart        = counted,
		deadline               = system.time() + WIRING_REQUEST_BOUND_MILLISECONDS,
	}
	return .Succeeded, true
}

// audit_wire_begin asks the wiring service for one wiring of the audit of a
// wide grant (src/md/features/wide_grants.md, "The path of a grant, end to
// end"): the record output acts of writer to collector.sources, with the
// terms of an audit space. The collector is the asker and the reader, and
// pays the ring from its budget; the core writes the request whole, with
// the fact audit_wired_by_root on both ends, so no list of an asker ever
// carries it. The answer reaches wide_grant_wire_answered.
audit_wire_begin :: proc "contextless" (collector: ^Started, writer: ^Started, producer: wide_grants.Act_Producer, writer_output_index: u32, collector_input_index: u32, flow_serial: u64) -> call_outcome.Call_Outcome {
	if wiring_request.stage != .Idle {
		return .Callee_Busy
	}
	if !wiring_service_start() {
		return .Wrong_State
	}
	for item in ([2]^Started{collector, writer}) {
		if !item.wiring_registered {
			wiring_register_process(item)
		}
		if !item.wiring_registered {
			return .Wrong_State
		}
	}
	values: [7]u64
	if budget_status := wiring_asker_budget_ensure(collector, .Wire, &values); budget_status != .Succeeded {
		return budget_status
	}
	endpoints := [1]wide_grants.Act_Producer_Endpoint{{producer = producer, end = .Started, handle = 1, output_index = writer_output_index}}
	rows: [1]output.Wiring
	terms: wide_grants.Space_Terms
	terms_start := u32(output.wiring_terms_start(1, 2))
	if _, refusal := wide_grants.act_wiring_rows_build(.Started, 2, collector_input_index, endpoints[:], terms_start, wide_grants.ACT_SPACE_BOUND_RECORDS, rows[:], &terms); refusal != .None {
		return .Argument_Refused
	}
	core_list_copy = {}
	handles := [2]u32{1, 2}
	if !output.wiring_list_write(core_list_copy[:], rows[:], handles[:]) {
		return .Argument_Refused
	}
	intrinsics.mem_copy_non_overlapping(&core_list_copy[terms_start], &terms, size_of(terms))
	core_resolved_req = {
		form        = u32(output.Wiring_List_Form.Wire),
		list_bytes  = output.WIRING_LIST_BYTES_MOST,
		lent_count  = 2,
	}
	core_resolved_req.lent[0] = {process_slot = writer.process_slot, process_serial = writer.process_serial, audit_wired_by_root = 1, present = 1}
	core_resolved_req.lent[1] = {process_slot = collector.process_slot, process_serial = collector.process_serial, audit_wired_by_root = 1, present = 1}
	intrinsics.mem_copy_non_overlapping(&wiring_region[ws.REGION_LIST_OFFSET], &core_list_copy[0], output.WIRING_LIST_BYTES_MOST)
	intrinsics.mem_copy_non_overlapping(&wiring_region[ws.REGION_REQUEST_OFFSET], &core_resolved_req, size_of(ws.Resolved_Wiring_Request))
	stag := next_service_tag()
	cmd := ws.Command{kind = .Wire, tag = stag, process = {collector.process_slot, collector.process_serial}, flags = process_flags_of(collector)}
	if !system.send(&wiring_ring.commands, ws.command_to_record(cmd)) {
		return .Callee_Busy
	}
	wiring_request = {
		stage               = .Wire,
		command             = .Wire,
		root_command        = .Wire,
		service_tag         = stag,
		asker               = collector,
		deadline            = system.time() + WIRING_REQUEST_BOUND_MILLISECONDS,
		audit               = .Wire,
		audit_flow_serial   = flow_serial,
	}
	return .Succeeded
}

// audit_unwire_begin asks the end of every wiring whose asker is the
// collector: the wirings of the audit of a wide grant, which only the core
// asks for in its name. Its answer reaches wide_grant_wire_answered. With no
// wiring service, or no collector, no wiring is left: done says that the
// end is done at once, and the caller marks the request sent before it
// gives the answer, so the flow reads the answer of a request that it
// sent. .Budget_Or_Capacity_Exhausted: the wiring service serves another request; the caller
// tries again at the next pass.
audit_unwire_begin :: proc "contextless" (collector: ^Started, flow_serial: u64) -> (outcome: call_outcome.Call_Outcome, done: bool) {
	if wiring_process == nil || collector == nil || collector.process == 0 {
		return .Succeeded, true
	}
	values: [7]u64
	held: bool
	outcome, held = wirings_revoke_begin(nil, collector, 0, &values)
	if outcome == .Succeeded && held {
		wiring_request.audit = .Unwire
		wiring_request.audit_flow_serial = flow_serial
	}
	return outcome, outcome == .Succeeded && !held
}

// wirings_revoke_begin delegates revocation of the recorded grant `.Wirings`
// of `target` to `wiring`.
wirings_revoke_begin :: proc "contextless" (caller: ^Started, target: ^Started, tag: u32, values: ^[7]u64) -> (outcome: call_outcome.Call_Outcome, held: bool) {
	if wiring_process == nil {
		target.granted -= {.Wirings}
		values[0] = 0
		return .Succeeded, false
	}
	if wiring_request.stage != .Idle {
		return root_ring.refuse(values, .Callee_Busy, u32(root_ring.Root_Command.Revoke), .Busy, .Requests, 0, 1, 1), false
	}
	stag := next_service_tag()
	cmd := ws.Command{kind = .Revoke_Asker, tag = stag, process = {target.process_slot, target.process_serial}}
	if !system.send(&wiring_ring.commands, ws.command_to_record(cmd)) {
		return root_ring.refuse(values, .Callee_Busy, u32(root_ring.Root_Command.Revoke), .Busy, .Requests, 0, 1, 1), false
	}
	wiring_request = {
		stage        = .Revoke_Asker,
		command      = .Revoke_Asker,
		root_command = .Revoke,
		tag          = tag,
		service_tag  = stag,
		asker        = caller,
		target       = target,
		deadline     = system.time() + WIRING_REQUEST_BOUND_MILLISECONDS,
	}
	return .Succeeded, true
}

// wiring_request_deadline returns the deadline of any in-flight request to
// `wiring` for root_loop_pass's single wait.
wiring_request_deadline :: proc "contextless" () -> u64 {
	return wiring_request.stage == .Idle ? system.WAIT_FOREVER : wiring_request.deadline
}

@(private = "file")
wiring_request_reply :: proc "contextless" (outcome: call_outcome.Call_Outcome, values: [7]u64) {
	asker := wiring_request.asker
	tag := wiring_request.tag
	audit := wiring_request.audit
	audit_flow_serial := wiring_request.audit_flow_serial
	wiring_request = {}
	if audit != .None {
		wide_grant_wire_answered(audit, audit_flow_serial, outcome)
		return
	}
	if asker != nil && asker.process != 0 && asker.requests.head != nil {
		_ = system.send(&asker.requests.completions, ring.Record{kind = u32(outcome), tag = tag, values = values})
	}
}

// wiring_request_fail answers the asker with a refusal. Once the process of
// a start runs, in the commit of its wiring, the asker can see it and holds
// its handle: a refusal then is a partial change, and a call in doubt stays
// in doubt.
@(private = "file")
wiring_request_fail :: proc "contextless" (outcome: call_outcome.Call_Outcome, values: [7]u64) {
	if wiring_request.stage == .Start_Commit {
		wiring_request_fail_after_start(outcome, values)
		return
	}
	wiring_request_reply(outcome, values)
}

// wiring_request_fail_after_start answers a refusal that came after the
// process of the start began to run.
@(private = "file")
wiring_request_fail_after_start :: proc "contextless" (outcome: call_outcome.Call_Outcome, values: [7]u64) {
	refusal := values
	passed := changed_then_refused(&refusal, outcome)
	wiring_request_reply(passed, refusal)
}

@(private = "file")
prove_wiring_memory_handle :: proc "contextless" (handle: op.Handle, needed: system.Rights) -> bool {
	if handle == 0 {
		return false
	}
	kind, rights, through := system.handle_state(system.Handle(handle), wiring_ring_memory)
	return through && kind == .Memory && needed <= rights
}

@(private = "file")
close_prepared_child_handles :: proc "contextless" (ends: []output.Given_End, log_ring, log_end_words: system.Handle) {
	if log_ring != 0 {
		system.close(log_ring)
	}
	if log_end_words != 0 {
		system.close(log_end_words)
	}
	for end in ends {
		for h in ([5]op.Handle{end.ring, end.end_words, end.terms, end.description, end.condition}) {
			if h != 0 {
				system.close(system.Handle(h))
			}
		}
	}
}

// wiring_request_step advances any in-flight request to `wiring` and adds
// wiring_ring.completions to root_loop_pass's single wait.
wiring_request_step :: proc "contextless" (wait: ^system.Wait) {
	if wiring_ring.head == nil {
		return
	}
	for record in root_receive(&wiring_ring.completions, "the wiring service") {
		if record.tag == 0 {
			if emptied_id, is_empty := ws.asker_wirings_empty_from_record(record); is_empty {
				for &item in started {
					if item.process != 0 && item.process_slot == emptied_id.slot && item.process_serial == emptied_id.serial {
						item.granted -= {.Wirings}
						break
					}
				}
			}
			continue
		}
		if wiring_request.stage == .Idle || record.tag != wiring_request.service_tag {
			// Asynchronous Register_Process / Grant_Asker_Budget / Abort completion.
			continue
		}
		resp, resp_ok := ws.response_from_record(record, wiring_request.command)
		if !resp_ok {
			// The wiring service answered what its contract does not hold.
			wiring_request_fail(.Answer_Unreadable, errors.ring_fail(u32(wiring_request.root_command), .Malformed, .Wirings))
			continue
		}
		// The wiring service named the outcome and the record of its
		// refusal: they reach the asker as they are.
		if resp.outcome != .Succeeded {
			wiring_request_fail(resp.outcome, errors.completion_values(resp.error_record))
			continue
		}
		switch wiring_request.stage {
		case .Idle:
		case .List_Page:
			asker := wiring_request.asker
			if !prove_wiring_memory_handle(resp.list_page, {.Read, .Write, .Give}) || (resp.wiring_ring != 0 && !prove_wiring_memory_handle(resp.wiring_ring, {.Read, .Write, .Give})) {
				wiring_request_fail(.Answer_Unreadable, errors.ring_fail(u32(root_ring.Root_Command.Wire), .Malformed, .Wirings))
				continue
			}
			if asker.list_memory != 0 {
				system.close(asker.list_memory)
			}
			asker.list_memory = system.Handle(resp.list_page)
			ring_for_asker: system.Handle
			status := call_outcome.Call_Outcome.Succeeded
			if resp.wiring_ring != 0 {
				if asker.wiring_memory != 0 {
					system.close(asker.wiring_memory)
				}
				asker.wiring_memory = system.Handle(resp.wiring_ring)
				ring_for_asker, status = system.give(asker.requests_memory, asker.wiring_memory, {.Read, .Write})
			}
			page_for_asker: system.Handle
			if status == .Succeeded {
				page_for_asker, status = system.give(asker.requests_memory, asker.list_memory, {.Read, .Write})
			}
			if status != .Succeeded {
				wiring_request_fail(system.own_operation_outcome(status), errors.ring_fail(u32(root_ring.Root_Command.Wire), .Refused, .Wirings, 0, 0, 0, i64(status)))
				continue
			}
			wiring_request_reply(.Succeeded, {u64(page_for_asker), u64(ring_for_asker), 0, 0, 0, 0, 0})
		case .Wire:
			if resp.asker_active > 0 {
				wiring_request.asker.granted += {.Wirings}
			}
			wiring_request_reply(.Succeeded, {u64(resp.wiring_number), 0, 0, 0, 0, 0, 0})
		case .Start_Prepare:
			intrinsics.mem_copy_non_overlapping(&core_prepared_resp, &wiring_region[ws.REGION_RESPONSE_OFFSET], size_of(ws.Prepared_Start_Ends))
			end_count, payload_ok := ws.prepared_start_ends_check(&core_prepared_resp, resp.batch_id, core_child_ends[:])
			handles_ok := payload_ok
			if handles_ok && core_prepared_resp.log_ring != 0 {
				handles_ok = prove_wiring_memory_handle(op.Handle(core_prepared_resp.log_ring), {.Read, .Write, .Give}) && prove_wiring_memory_handle(op.Handle(core_prepared_resp.log_end_words), {.Read, .Give})
			}
			for idx := 0; handles_ok && idx < end_count; idx += 1 {
				e := core_child_ends[idx]
				handles_ok = prove_wiring_memory_handle(e.ring, {.Read, .Write, .Give}) && prove_wiring_memory_handle(e.end_words, {.Read, .Give})
				if handles_ok && e.terms != 0 {
					handles_ok = prove_wiring_memory_handle(e.terms, {.Read, .Give})
				}
				if handles_ok && e.description != 0 {
					handles_ok = prove_wiring_memory_handle(e.description, {.Read, .Give})
				}
				if handles_ok && e.condition != 0 {
					handles_ok = prove_wiring_memory_handle(e.condition, {.Read, .Give})
				}
			}
			if !handles_ok {
				abort_cmd := ws.Command{kind = .Abort_Start_Wiring, batch_id = resp.batch_id}
				_ = system.send(&wiring_ring.commands, ws.command_to_record(abort_cmd))
				wiring_request_fail(.Answer_Unreadable, errors.ring_fail(u32(root_ring.Root_Command.Start), .Malformed, .Wirings))
				continue
			}
			premade := Premade_Start_Wiring{
				ends          = core_child_ends[:end_count],
				log_ring      = system.Handle(core_prepared_resp.log_ring),
				log_end_words = system.Handle(core_prepared_resp.log_end_words),
			}
			started_place: ^Started
			start_refusal: [7]u64
			name := system.name_of(wiring_request.start_name[:])
			started := start(name, wiring_request.start_principal, wiring_request.asker, &premade, &started_place, &start_refusal, budget_unbounded = wiring_request.start_budget_unbounded)
			close_prepared_child_handles(core_child_ends[:end_count], premade.log_ring, premade.log_end_words)
			if started != .Succeeded || started_place == nil {
				abort_cmd := ws.Command{kind = .Abort_Start_Wiring, batch_id = resp.batch_id}
				_ = system.send(&wiring_ring.commands, ws.command_to_record(abort_cmd))
				if started == .Succeeded {
					// The process stopped before this answer.
					started = root_ring.refuse(&start_refusal, .Callee_Stopped_During_The_Call, u32(root_ring.Root_Command.Start), .Callee_Stopped, .Processes, 1)
				}
				wiring_request_fail(started, start_refusal)
				continue
			}
			if !started_place.wiring_registered {
				wiring_register_process(started_place)
			}
			// Give the asker its child process handle immediately before the child
			// can finish and be reaped while Commit_Start_Wiring is in flight.
			reply_handle: u64
			if wiring_request.for_start_policy {
				if wiring_request.counted_restart != nil {
					wiring_request.counted_restart.starts += 1
				}
				started_place.asked_by_start_policy = true
				reply_handle, _ = start_process_handle_give(wiring_request.asker, started_place)
			} else if wiring_request.start_answer == .Process_Handle {
				reply_handle, _ = start_process_handle_give(wiring_request.asker, started_place)
			}
			stag := next_service_tag()
			commit_cmd := ws.Command{
				kind     = .Commit_Start_Wiring,
				tag      = stag,
				batch_id = resp.batch_id,
				process  = {started_place.process_slot, started_place.process_serial},
			}
			if !system.send(&wiring_ring.commands, ws.command_to_record(commit_cmd)) {
				// The process runs and the asker can hold its handle.
				wiring_request_fail_after_start(.Callee_Busy, errors.ring_fail(u32(root_ring.Root_Command.Start), .Busy, .Requests, 0, 1, 1))
				continue
			}
			wiring_request.stage = .Start_Commit
			wiring_request.command = .Commit_Start_Wiring
			wiring_request.service_tag = stag
			wiring_request.batch_id = resp.batch_id
			wiring_request.child = started_place
			wiring_request.start_reply_handle = reply_handle
			wiring_request.deadline = system.time() + WIRING_REQUEST_BOUND_MILLISECONDS
		case .Start_Commit:
			intrinsics.mem_copy_non_overlapping(&core_prepared_resp, &wiring_region[ws.REGION_RESPONSE_OFFSET], size_of(ws.Prepared_Start_Ends))
			if resp.asker_active > 0 {
				wiring_request.asker.granted += {.Wirings}
			}
			reply_values: [7]u64
			reply_values[0] = wiring_request.start_reply_handle
			if !wiring_request.for_start_policy {
				asker_count := min(core_prepared_resp.asker_wiring_count, output.WIRING_ASKER_ROWS_OF_A_START)
				for idx in 0 ..< asker_count {
					reply_values[1 + idx] = u64(core_prepared_resp.asker_numbers[idx])
				}
			}
			wiring_request_reply(.Succeeded, reply_values)
		case .Revoke_Asker:
			target := wiring_request.target
			if target != nil && target.process != 0 {
				target.granted -= {.Wirings}
				system.log_fact(.Info, Wirings_Revoked{ended = resp.ended_count, target = module_name_field(system.name_of(target.name[:]))})
			}
			wiring_request_reply(.Succeeded, {resp.ended_count, 0, 0, 0, 0, 0, 0})
		}
	}
	if wiring_request.stage != .Idle && system.time() >= wiring_request.deadline {
		wiring_request_fail(.Deadline_Passed_During_The_Call, errors.ring_fail(u32(wiring_request.root_command), .No_Answer, .Milliseconds, 0, 0, WIRING_REQUEST_BOUND_MILLISECONDS))
	}
	system.wait_records(wait, &wiring_ring.completions)
}
