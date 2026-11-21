// The delegated wiring service: creates and manages record-stream wirings
// between processes without holding root authority
// (src/md/api/root_service_split.md).
//
// **What it holds.** Only its attenuated grants from the root service core:
//
// - `SERVICE_RING`: typed command and response ring with the core.
// - `SERVICE_STOPS_RING`: the core's `stops` record output ring carrying
//   `Process_Stop_Notice` records so stopped processes are cleaned up
//   without polling or broadcast.
// - `SERVICE_IMAGE`: read-only view of the boot image for checking record
//   descriptions during type matching.
// - `SERVICE_REGION`: shared transfer region for copied wiring lists,
//   resolved process identities, and prepared Start child ends.
// - Per-asker child wiring budgets with **Spend** only, per-process tokens
//   with **Give** only, and wiring rings of processes that declare record
//   streams.
//
// It holds no machine handle, no root ring, no Control or Debug right on
// any process, and no Spend right on the root service budget. A fault in a
// wiring list stops this service alone, never the root service.
package wiring

import "base:intrinsics"
import "modus:contract/errors"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/output"
import "modus:contract/ring"
import "modus:contract/root_ring"
import ws "modus:contract/wiring_service"
import "internal:wiring/wiring_core"
import "modus:system"

// One thread serves SERVICE_RING, SERVICE_STOPS_RING, and mapped process
// wiring rings. All stream rings, end pages, terms pages, description files,
// and list pages are paid from each asker's child wiring budget.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 32, processes = 1, threads = 1}

// Stall bound in wiring_core must stay identical to the system hang bound.
#assert(wiring_core.STALL_HANG_BOUND_MS == system.TEST_HANG_BOUND_MILLISECONDS)

// Poll cadence (milliseconds) while at least one Always_Holds_Writer wiring
// is active, so full rings are observed without waking when none exist.
STALL_POLL_INTERVAL_MS :: u64(1_000)

// Fixed words in one wait of the main loop: the event word, SERVICE_RING,
// and SERVICE_STOPS_RING.
WIRING_WAIT_FIXED_WORDS :: 1 + 2 + 2
WIRING_WAITED_RINGS_MOST :: (op.WORD_WAIT_CAPACITY - WIRING_WAIT_FIXED_WORDS) / 2
#assert(WIRING_WAIT_FIXED_WORDS + 2 * WIRING_WAITED_RINGS_MOST <= op.WORD_WAIT_CAPACITY)

// Kernel handles associated with one registered Process_Entry in `state`.
Process_Handles :: struct {
	process_token:        system.Handle, // Give-only process handle token.
	wiring_memory:        system.Handle, // Process wiring ring memory (Read, Write).
	wiring_ring:          ring.Ring, // Mapped only while the process holds ends.
	wiring_ring_ready:    bool, // True once Handle_Give succeeded on wiring_memory.
	asker_budget:         system.Handle, // Child wiring budget (Spend only).
	list_memory:          system.Handle, // Asker's list page, paid from asker_budget.
	unknown_wiring_words: u64,
}

// Transient memory handles made for one row before delivery completes.
Row_Objects :: struct {
	ring_memory:        system.Handle,
	end_memory:         system.Handle,
	terms_memory:       system.Handle,
	description_memory: system.Handle,
	condition_memory:   system.Handle,
}

// One prepared Start wiring batch awaiting Commit_Start_Wiring or Abort_Start_Wiring.
Prepared_Batch :: struct {
	active:  bool,
	id:      u32,
	work:    wiring_core.Plan_Work,
	objects: [output.WIRING_LIST_ROW_LIMIT]Row_Objects,
}

core_ring_memory: system.Handle
core_ring: ring.Ring
stops_ring_memory: system.Handle
stops_ring: ring.Ring
image: []u8
region: []u8

state: wiring_core.State
process_handles: [wiring_core.PROCESS_CAPACITY]Process_Handles
wiring_end_memory: [wiring_core.WIRINGS_OF_THE_MACHINE_MOST]system.Handle
wiring_ring_memory: [wiring_core.WIRINGS_OF_THE_MACHINE_MOST]system.Handle
wiring_ring_capacity: [wiring_core.WIRINGS_OF_THE_MACHINE_MOST]u32

// Private copies of shared region payloads so no byte is read twice from
// shared memory, plus scratch buffers for description files and plans.
list_copy: [output.WIRING_LIST_BYTES_MOST]u8
request_copy: ws.Resolved_Wiring_Request
response_staging: ws.Prepared_Start_Ends
description_copy: [output.DESCRIPTION_FILE_BYTES_MOST]u8
wire_work: wiring_core.Plan_Work
prepared_batch: Prepared_Batch
next_batch_id: u32 = 1

@(private = "file")
fail :: proc "contextless" (reason: string) -> ! {
	system.log(.Error, "wiring: ", reason)
	system.stop(.Failed)
}

@(private = "file")
prove_core_handle :: proc "contextless" (handle: op.Handle, expected_kind: op.Object_Kind, grant_kind: ws.Attenuated_Grant_Kind) -> (ok: bool) {
	if handle == 0 {
		return false
	}
	kind, rights, through := system.handle_state(system.Handle(handle), core_ring_memory)
	if !through || kind != expected_kind {
		return false
	}
	return ws.attenuated_rights_allowed(grant_kind, rights)
}

@(private = "file")
close_handle :: proc "contextless" (handle: ^system.Handle) {
	if handle^ != 0 {
		system.close(handle^)
		handle^ = 0
	}
}

@(private = "file")
close_row_objects :: proc "contextless" (obj: ^Row_Objects, keep_end := false, keep_ring := false) {
	if !keep_ring {
		close_handle(&obj.ring_memory)
	}
	close_handle(&obj.terms_memory)
	close_handle(&obj.description_memory)
	close_handle(&obj.condition_memory)
	if !keep_end {
		close_handle(&obj.end_memory)
	}
}

@(private = "file")
wiring_slot_handles_close :: proc "contextless" (slot: int) {
	if slot < 0 || slot >= wiring_core.WIRINGS_OF_THE_MACHINE_MOST {
		return
	}
	close_handle(&wiring_end_memory[slot])
	close_handle(&wiring_ring_memory[slot])
	wiring_ring_capacity[slot] = 0
}

@(private = "file")
end_words_write_and_wake :: proc "contextless" (wiring_slot: int, end_word: output.End_Word, cause: op.Stop_Cause = .None, outcome: op.Stop_Outcome = .None) {
	if end_word == .None || wiring_slot < 0 || wiring_slot >= wiring_core.WIRINGS_OF_THE_MACHINE_MOST {
		return
	}
	end_mem := wiring_end_memory[wiring_slot]
	if end_mem == 0 {
		return
	}
	address, status := system.memory_map(end_mem)
	if status != .Ok {
		system.log(.Warning, "wiring: cannot map end page of slot ", u64(wiring_slot), ": status ", status)
		return
	}
	words := (^output.End_Words)(address)
	output.end_words_write(words, end_word, cause, outcome)
	system.word_wake(&words.end, system.WAKE_ALL)
	system.memory_unmap(address)
}

@(private = "file")
wiring_ring_hold :: proc "contextless" (proc_idx: int, drop_stale: bool = true) -> system.Status {
	if proc_idx < 0 || proc_idx >= wiring_core.PROCESS_CAPACITY {
		return .Bad_Handle
	}
	ph := &process_handles[proc_idx]
	if ph.wiring_ring.head != nil {
		return .Ok
	}
	if ph.wiring_memory == 0 {
		return .Bad_State
	}
	opened, status := system.ring_open(ph.wiring_memory)
	if status != .Ok {
		return status
	}
	ph.wiring_ring = opened
	if drop_stale {
		for _ in 0 ..< ring.capacity(&ph.wiring_ring.completions) {
			if _, received := system.receive(&ph.wiring_ring.completions); !received {
				break
			}
		}
	}
	return .Ok
}

@(private = "file")
wiring_rings_let_go :: proc "contextless" () {
	for idx in 0 ..< wiring_core.PROCESS_CAPACITY {
		ph := &process_handles[idx]
		entry := &state.processes[idx]
		if ph.wiring_ring.head != nil && (!entry.active || entry.ends_given - entry.log_ends_given <= 0) {
			system.ring_close(&ph.wiring_ring)
		}
	}
}

@(private = "file")
ring_room_callback :: proc "contextless" (data: rawptr, proc_idx: int) -> (available: u32, capacity: u32, has_ring: bool) {
	_ = data
	if proc_idx < 0 || proc_idx >= wiring_core.PROCESS_CAPACITY {
		return 0, 0, false
	}
	ph := &process_handles[proc_idx]
	if ph.wiring_memory == 0 {
		return 0, 0, false
	}
	if wiring_ring_hold(proc_idx) != .Ok {
		return 0, 0, false
	}
	commands := &ph.wiring_ring.commands
	cap := ring.capacity(commands)
	return cap - ring.count(commands), cap, true
}

@(private = "file")
page_write :: proc "contextless" (budget: system.Handle, bytes: []u8, error: ^errors.Error_Record) -> (memory: system.Handle, status: system.Status) {
	pages := u64(max(len(bytes), 1) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	memory = system.memory_create(pages, budget, error = error) or_return
	address, map_status := system.memory_map(memory, {.Write}, error = error)
	if map_status != .Ok {
		system.close(memory)
		return 0, map_status
	}
	if len(bytes) > 0 {
		intrinsics.mem_copy_non_overlapping(address, raw_data(bytes), len(bytes))
	}
	system.memory_unmap(address)
	return memory, .Ok
}

@(private = "file")
plan_writer_file :: proc "contextless" (plan: ^wiring_core.Row_Plan) -> []u8 {
	if plan.writer_is_log_file {
		return wiring_core.log_output_file(&state)
	}
	return wiring_core.image_slice_of(image, plan.writer_file_offset, plan.writer_file_size)
}

@(private = "file")
make_row_objects :: proc "contextless" (asker_budget: system.Handle, plan: ^wiring_core.Row_Plan, obj: ^Row_Objects, error: ^errors.Error_Record) -> system.Status {
	writer_file := plan_writer_file(plan)
	description, desc_ok := module.record_stream_type(writer_file, plan.description)
	if !desc_ok {
		error^ = errors.error_make(.Bad_Value, .Record_Types)
		return .Bad_Operation
	}
	compartment := output.compartment_size(description.size)
	obj.ring_memory = system.memory_create(ring.compartment_pages(plan.row.capacity, compartment), asker_budget, error = error) or_return
	obj.end_memory = system.memory_create(output.END_WORDS_PAGES, asker_budget, error = error) or_return
	if plan.row.terms_count != 0 {
		obj.terms_memory = page_write(asker_budget, list_copy[plan.row.terms_offset:][:plan.row.terms_count], error) or_return
	}
	if plan.has_condition {
		condition_bytes := transmute([size_of(output.Writer_Condition)]u8)plan.condition
		obj.condition_memory = page_write(asker_budget, condition_bytes[:], error) or_return
	}
	size, described := output.description_file_write(description_copy[:], writer_file, plan.description)
	if !described {
		error^ = errors.error_make(.Too_Long, .Bytes, 0, 0, output.DESCRIPTION_FILE_BYTES_MOST)
		return .Bad_Operation
	}
	obj.description_memory = page_write(asker_budget, description_copy[:size], error) or_return
	return .Ok
}

@(private = "file")
given_end_of_row :: proc "contextless" (plan: ^wiring_core.Row_Plan, obj: ^Row_Objects, writer: bool) -> output.Given_End {
	if writer {
		return {
			command   = .Writer_End,
			tag       = plan.allocated_number,
			ring      = op.Handle(obj.ring_memory),
			index     = plan.row.writer_index,
			pace      = plan.row.pace,
			end_words = op.Handle(obj.end_memory),
			condition = op.Handle(obj.condition_memory),
		}
	}
	cmd := plan.row.reader_end == .Asker ? output.Wiring_Command.Asker_End : output.Wiring_Command.Reader_End
	filter := plan.has_condition ? output.Reader_Filter.By_Writer : output.Reader_Filter.None
	return {
		command     = cmd,
		tag         = plan.allocated_number,
		ring        = op.Handle(obj.ring_memory),
		index       = plan.row.reader_index,
		terms       = op.Handle(obj.terms_memory),
		description = op.Handle(obj.description_memory),
		end_words   = op.Handle(obj.end_memory),
		filter      = filter,
	}
}

// Startup grace bound (milliseconds) for a newly started process to map its
// wiring ring with Receive_Handles before its first end arrives (TCG safe).
DELIVER_STARTUP_GRACE_MS :: 500

// process_stop_pending peeks unread stop notices on stops_ring without
// mutating state, so wiring_end_give fails fast if the target stopped.
@(private = "file")
process_stop_pending :: proc "contextless" (id: ws.Process_Identity) -> bool {
	q := &stops_ring.commands
	if q.counters == nil || q.records == nil {
		return false
	}
	r := intrinsics.atomic_load_explicit(&q.counters.read, .Acquire)
	w := intrinsics.atomic_load_explicit(&q.counters.write, .Acquire)
	count := w - r
	if count > ring.capacity(q) {
		return false
	}
	for offset in u32(0) ..< count {
		rec := q.records[(r + offset) & q.mask]
		if notice, ok := ws.stop_notice_from_record(rec); ok && notice.process_slot == id.slot && notice.process_serial == id.serial {
			return true
		}
	}
	return false
}

// wiring_end_give gives one end to a running process through its wiring
// ring. Because `wiring` holds no Control right on any process, on partial
// failure it calls handle_revoke(source, 0) on objects it created to clean
// up any half-delivered handles.
@(private = "file")
wiring_end_give :: proc "contextless" (proc_idx: int, end: output.Given_End) -> system.Status {
	if proc_idx < 0 || proc_idx >= wiring_core.PROCESS_CAPACITY || !state.processes[proc_idx].active {
		return .Bad_Handle
	}
	ph := &process_handles[proc_idx]
	if ph.wiring_memory == 0 {
		return .Bad_State
	}
	wiring_ring_hold(proc_idx) or_return
	given := end
	sources := [5]system.Handle{
		system.Handle(end.ring),
		system.Handle(end.end_words),
		system.Handle(end.terms),
		system.Handle(end.description),
		system.Handle(end.condition),
	}
	rights := [5]system.Rights{{.Read, .Write}, {.Read}, {.Read}, {.Read}, {.Read}}
	results := [5]^op.Handle{&given.ring, &given.end_words, &given.terms, &given.description, &given.condition}
	status := system.Status.Ok
	gifts := 0
	target_id := state.processes[proc_idx].id
	for source, idx in sources {
		if source == 0 {
			continue
		}
		h, g_status := system.give(ph.wiring_memory, source, rights[idx])
		// A freshly started process may not have mapped its wiring ring with
		// Receive_Handles yet (Bad_Handle): retry with bounded exponential
		// backoff up to DELIVER_STARTUP_GRACE_MS, stopping immediately if a
		// stop notice is pending, and never retrying No_Right or once ready.
		if g_status == .Bad_Handle && !ph.wiring_ring_ready {
			deadline := system.time() + DELIVER_STARTUP_GRACE_MS
			backoff: u64 = 1
			for g_status == .Bad_Handle {
				if process_stop_pending(target_id) {
					g_status = .Bad_State
					break
				}
				now := system.time()
				if now >= deadline {
					break
				}
				wake_at := min(now + backoff, deadline)
				system.sleep(wake_at)
				backoff = min(backoff * 2, 10)
				h, g_status = system.give(ph.wiring_memory, source, rights[idx])
			}
		}
		if g_status != .Ok {
			status = g_status
			break
		}
		ph.wiring_ring_ready = true
		results[idx]^ = op.Handle(h)
		gifts = idx + 1
	}
	if status == .Ok && !system.send(&ph.wiring_ring.commands, output.given_end_record(given)) {
		status = .No_Slot
	}
	if status != .Ok {
		for idx in 0 ..< gifts {
			if sources[idx] != 0 {
				_, _ = system.handle_revoke(sources[idx], 0)
			}
		}
	}
	return status
}

@(private = "file")
revoke_row_objects :: proc "contextless" (obj: ^Row_Objects) {
	for h in ([5]system.Handle{obj.ring_memory, obj.end_memory, obj.terms_memory, obj.description_memory, obj.condition_memory}) {
		if h != 0 {
			_, _ = system.handle_revoke(h, 0)
		}
	}
}

@(private = "file")
abort_prepared_batch :: proc "contextless" () {
	if !prepared_batch.active {
		return
	}
	for number in 1 ..= prepared_batch.work.list.row_count {
		plan := &prepared_batch.work.plans[number - 1]
		obj := &prepared_batch.objects[number - 1]
		if plan.allocated_slot >= 0 {
			_, _ = wiring_core.wiring_end_slot(&state, plan.allocated_slot, .None)
			wiring_end_memory[plan.allocated_slot] = 0
			wiring_ring_memory[plan.allocated_slot] = 0
			wiring_ring_capacity[plan.allocated_slot] = 0
			plan.allocated_slot = -1
		}
		revoke_row_objects(obj)
		close_row_objects(obj, keep_end = false, keep_ring = false)
	}
	prepared_batch = {}
}

@(private = "file")
region_read_request :: proc "contextless" () {
	intrinsics.mem_copy_non_overlapping(&list_copy[0], &region[ws.REGION_LIST_OFFSET], ws.REGION_LIST_SIZE)
	intrinsics.mem_copy_non_overlapping(&request_copy, &region[ws.REGION_REQUEST_OFFSET], size_of(ws.Resolved_Wiring_Request))
}

@(private = "file")
region_write_response :: proc "contextless" () {
	intrinsics.mem_copy_non_overlapping(&region[ws.REGION_RESPONSE_OFFSET], &response_staging, size_of(ws.Prepared_Start_Ends))
}

@(private = "file")
handle_register_process :: proc "contextless" (cmd: ws.Command) -> ws.Response {
	if !prove_core_handle(cmd.process_handle, .Process, .Stream_Process_Token) {
		return {status = .Bad_Handle, tag = cmd.tag, error_record = errors.error_make(.Handle_Rights, .Lent_Handles)}
	}
	if cmd.wiring_ring_handle != 0 && !prove_core_handle(cmd.wiring_ring_handle, .Memory, .Process_Wiring_Ring) {
		system.close(system.Handle(cmd.process_handle))
		return {status = .Bad_Handle, tag = cmd.tag, error_record = errors.error_make(.Handle_Rights, .Lent_Handles)}
	}
	idx, st := wiring_core.process_register(&state, cmd.process, cmd.module_offset, cmd.module_size, cmd.flags)
	if st != .Ok {
		system.close(system.Handle(cmd.process_handle))
		if cmd.wiring_ring_handle != 0 {
			system.close(system.Handle(cmd.wiring_ring_handle))
		}
		return {status = st, tag = cmd.tag, error_record = errors.error_make(.Full, .Processes)}
	}
	ph := &process_handles[idx]
	if ph.process_token != 0 {
		system.close(ph.process_token)
	}
	ph.process_token = system.Handle(cmd.process_handle)
	if cmd.wiring_ring_handle != 0 {
		if ph.wiring_ring.head != nil {
			system.ring_close(&ph.wiring_ring)
		}
		close_handle(&ph.wiring_memory)
		ph.wiring_memory = system.Handle(cmd.wiring_ring_handle)
		ph.wiring_ring_ready = false
	}
	return {status = .Ok, tag = cmd.tag}
}

@(private = "file")
handle_grant_asker_budget :: proc "contextless" (cmd: ws.Command) -> ws.Response {
	if !prove_core_handle(cmd.budget_handle, .Budget, .Asker_Wiring_Budget) {
		return {status = .Bad_Handle, tag = cmd.tag, error_record = errors.error_make(.Handle_Rights, .Lent_Handles)}
	}
	idx, found := wiring_core.process_find(&state, cmd.process)
	if !found {
		system.close(system.Handle(cmd.budget_handle))
		return {status = .Bad_Handle, tag = cmd.tag, error_record = errors.error_make(.Absent, .Processes)}
	}
	ph := &process_handles[idx]
	close_handle(&ph.asker_budget)
	ph.asker_budget = system.Handle(cmd.budget_handle)
	return {status = .Ok, tag = cmd.tag}
}

@(private = "file")
handle_list_page :: proc "contextless" (cmd: ws.Command) -> ws.Response {
	op_code := u32(root_ring.Root_Command.Wire)
	already, asker_idx, res_st, refusal := wiring_core.list_page_reserve(&state, cmd.process, op_code)
	if res_st != .Ok {
		return {status = res_st, tag = cmd.tag, error_record = refusal}
	}
	ph := &process_handles[asker_idx]
	if ph.asker_budget == 0 {
		if !already {
			wiring_core.list_page_unreserve(&state, asker_idx)
		}
		err := errors.error_make(.Budget_Hidden, .Pages)
		err.operation = i64(op_code)
		return {status = .No_Budget, tag = cmd.tag, error_record = err}
	}
	err: errors.Error_Record
	made_page, made_ring: bool
	if ph.list_memory == 0 {
		mem, status := system.memory_create(output.WIRING_LIST_PAGES_MOST, ph.asker_budget, error = &err)
		if status != .Ok {
			if !already {
				wiring_core.list_page_unreserve(&state, asker_idx)
			}
			err.operation = i64(op_code)
			return {status = ws.response_status_from_op_status(status), tag = cmd.tag, error_record = err}
		}
		ph.list_memory = mem
		made_page = true
	}
	ring_given: system.Handle
	if ph.wiring_memory == 0 {
		mem, status := system.memory_create(ring.pages(output.WIRING_RING_CAPACITY), ph.asker_budget, error = &err)
		if status == .Ok {
			ph.wiring_memory = mem
			made_ring = true
			ring_given, status = system.give(core_ring_memory, mem, {.Read, .Write, .Give})
		}
		if status != .Ok {
			if made_ring {
				close_handle(&ph.wiring_memory)
			}
			if made_page {
				close_handle(&ph.list_memory)
				wiring_core.list_page_unreserve(&state, asker_idx)
			}
			err.operation = i64(op_code)
			return {status = ws.response_status_from_op_status(status), tag = cmd.tag, error_record = err}
		}
	}
	page_given, give_status := system.give(core_ring_memory, ph.list_memory, {.Read, .Write, .Give})
	if give_status != .Ok {
		if made_ring {
			_, _ = system.handle_revoke(ph.wiring_memory, 0)
			close_handle(&ph.wiring_memory)
		}
		if made_page {
			close_handle(&ph.list_memory)
			wiring_core.list_page_unreserve(&state, asker_idx)
		}
		rec := errors.error_make(.Refused, .Wirings, 0, 0, 0, i64(give_status))
		rec.operation = i64(op_code)
		return {status = ws.response_status_from_op_status(give_status), tag = cmd.tag, error_record = rec}
	}
	return {
		status      = .Ok,
		tag         = cmd.tag,
		list_page   = op.Handle(page_given),
		wiring_ring = op.Handle(ring_given),
	}
}

@(private = "file")
process_module_name :: proc "contextless" (idx: int) -> string {
	if idx < 0 || idx >= len(state.processes) || !state.processes[idx].active {
		return ""
	}
	pe := &state.processes[idx]
	for &entry in system.image_entries(image) {
		if entry.offset == pe.module_offset && entry.size == pe.module_size {
			return system.name_of(entry.name[:])
		}
	}
	return ""
}

@(private = "file")
log_wiring_created :: proc "contextless" (plan: ^wiring_core.Row_Plan, number: u32) {
	writer_name := process_module_name(plan.writer_index)
	reader_name := process_module_name(plan.reader_index)
	if plan.row.writer_stream == .Log {
		system.log(.Info, "wiring: wired the record output log of ", system.Module_Name{writer_name}, " to ", plan.row.reader_end == .Asker ? "its asker " : "", system.Module_Name{reader_name}, ", wiring ", u64(number))
		return
	}
	system.log(.Info, "wiring: wired the record output ", u64(plan.row.writer_index), " of ", system.Module_Name{writer_name}, " to ", plan.row.reader_end == .Asker ? "its asker " : "", system.Module_Name{reader_name}, ", wiring ", u64(number))
}

@(private = "file")
handle_wire :: proc "contextless" (cmd: ws.Command) -> ws.Response {
	op_code := u32(root_ring.Root_Command.Wire)
	region_read_request()
	st, refusal := wiring_core.plan_resolve(&state, image, list_copy[:], &request_copy, cmd.process, op_code, &wire_work, ring_room_callback, nil)
	if st != .Ok {
		return {status = st, tag = cmd.tag, error_record = refusal}
	}
	asker_idx := wire_work.asker_index
	asker_budget := process_handles[asker_idx].asker_budget
	if asker_budget == 0 {
		err := errors.error_make(.Budget_Hidden, .Pages)
		err.operation = i64(op_code)
		return {status = .No_Budget, tag = cmd.tag, error_record = err}
	}
	plan := &wire_work.plans[0]
	obj: Row_Objects
	err: errors.Error_Record
	make_status := make_row_objects(asker_budget, plan, &obj, &err)
	if make_status != .Ok {
		close_row_objects(&obj, keep_end = false)
		err.operation = i64(op_code)
		err.found = 1
		return {status = ws.response_status_from_op_status(make_status), tag = cmd.tag, error_record = err}
	}
	slot, number, alloc_ok := wiring_core.wiring_slot_allocate(&state, asker_idx, plan)
	if !alloc_ok {
		close_row_objects(&obj, keep_end = false)
		rec := errors.error_make(.Full, .Wirings, 0, i64(state.wirings_running + 1), wiring_core.WIRINGS_OF_THE_MACHINE_MOST)
		rec.operation = i64(op_code)
		return {status = .No_Slot, tag = cmd.tag, error_record = rec}
	}
	wiring_end_memory[slot] = obj.end_memory
	keep_ring := plan.row.pace == .Always_Holds_Writer
	if keep_ring {
		wiring_ring_memory[slot] = obj.ring_memory
		wiring_ring_capacity[slot] = plan.row.capacity
	}
	deliv_status := wiring_end_give(plan.writer_index, given_end_of_row(plan, &obj, true))
	if deliv_status == .Ok {
		deliv_status = wiring_end_give(plan.reader_index, given_end_of_row(plan, &obj, false))
	}
	close_row_objects(&obj, keep_end = true, keep_ring = keep_ring)
	if deliv_status != .Ok {
		end_word, _ := wiring_core.wiring_end_slot(&state, slot, .Refused)
		end_words_write_and_wake(slot, end_word)
		wiring_slot_handles_close(slot)
		rec := errors.error_make(.Refused, .Wirings, 0, 0, 0, i64(deliv_status))
		rec.operation = i64(op_code)
		return {status = .Refused, tag = cmd.tag, error_record = rec}
	}
	wiring_core.wiring_mark_delivered(&state, slot, plan)
	log_wiring_created(plan, number)
	return {
		status        = .Ok,
		tag           = cmd.tag,
		wiring_number = number,
		asker_active  = u64(state.processes[asker_idx].wirings_asked),
	}
}

@(private = "file")
handle_prepare_start_wiring :: proc "contextless" (cmd: ws.Command) -> ws.Response {
	op_code := u32(root_ring.Root_Command.Start)
	if prepared_batch.active {
		rec := errors.error_make(.Busy, .Wirings, 0, 1, 1)
		rec.operation = i64(op_code)
		return {status = .No_Slot, tag = cmd.tag, error_record = rec}
	}
	region_read_request()
	request_copy.child_module_offset = cmd.module_offset
	request_copy.child_module_size = cmd.module_size
	st, refusal := wiring_core.plan_resolve(&state, image, list_copy[:], &request_copy, cmd.process, op_code, &prepared_batch.work, ring_room_callback, nil)
	if st != .Ok {
		return {status = st, tag = cmd.tag, error_record = refusal}
	}
	asker_idx := prepared_batch.work.asker_index
	asker_budget := process_handles[asker_idx].asker_budget
	if asker_budget == 0 {
		err := errors.error_make(.Budget_Hidden, .Pages)
		err.operation = i64(op_code)
		return {status = .No_Budget, tag = cmd.tag, error_record = err}
	}
	batch_id := next_batch_id
	next_batch_id = next_batch_id == max(u32) ? 1 : next_batch_id + 1
	prepared_batch.active = true
	prepared_batch.id = batch_id
	response_staging = {batch_id = batch_id}

	// Phase 1: allocate every row's memory objects and wiring slot before
	// giving any handle to the core, so a budget or slot refusal on a later
	// row never leaves unclaimed handles in the core's handle table.
	for number in 1 ..= prepared_batch.work.list.row_count {
		plan := &prepared_batch.work.plans[number - 1]
		obj := &prepared_batch.objects[number - 1]
		err: errors.Error_Record
		make_status := make_row_objects(asker_budget, plan, obj, &err)
		if make_status != .Ok {
			close_row_objects(obj, keep_end = false)
			abort_prepared_batch()
			err.operation = i64(op_code)
			err.found = i64(number)
			return {status = ws.response_status_from_op_status(make_status), tag = cmd.tag, error_record = err}
		}
		slot, _, alloc_ok := wiring_core.wiring_slot_allocate(&state, asker_idx, plan)
		if !alloc_ok {
			close_row_objects(obj, keep_end = false)
			abort_prepared_batch()
			rec := errors.error_make(.Full, .Wirings, 0, i64(state.wirings_running + 1), wiring_core.WIRINGS_OF_THE_MACHINE_MOST)
			rec.operation = i64(op_code)
			return {status = .No_Slot, tag = cmd.tag, error_record = rec}
		}
		wiring_end_memory[slot] = obj.end_memory
		if plan.row.reader_end == .Asker && response_staging.asker_wiring_count < output.WIRING_ASKER_ROWS_OF_A_START {
			response_staging.asker_numbers[response_staging.asker_wiring_count] = plan.allocated_number
			response_staging.asker_wiring_count += 1
		}
	}
	// Phase 2: all rows fit; now give child handles to the core through
	// SERVICE_RING so core passes them into system.process_start.
	for number in 1 ..= prepared_batch.work.list.row_count {
		plan := &prepared_batch.work.plans[number - 1]
		obj := &prepared_batch.objects[number - 1]
		if plan.writer_index == wiring_core.CHILD_PROCESS_INDEX && plan.row.writer_stream == .Log {
			g_ring, g_st := system.give(core_ring_memory, obj.ring_memory, {.Read, .Write, .Give})
			g_end: system.Handle
			if g_st == .Ok {
				g_end, g_st = system.give(core_ring_memory, obj.end_memory, {.Read, .Give})
			}
			if g_st != .Ok {
				abort_prepared_batch()
				rec := errors.error_make(.Refused, .Wirings, 0, 0, 0, i64(g_st))
				rec.operation = i64(op_code)
				return {status = ws.response_status_from_op_status(g_st), tag = cmd.tag, error_record = rec}
			}
			response_staging.log_ring = u32(g_ring)
			response_staging.log_end_words = u32(g_end)
		} else if plan.writer_index == wiring_core.CHILD_PROCESS_INDEX {
			given, g_st := give_child_end_to_core(given_end_of_row(plan, obj, true))
			if g_st != .Ok {
				abort_prepared_batch()
				rec := errors.error_make(.Refused, .Wirings, 0, 0, 0, i64(g_st))
				rec.operation = i64(op_code)
				return {status = ws.response_status_from_op_status(g_st), tag = cmd.tag, error_record = rec}
			}
			response_staging.child_ends[response_staging.child_end_count] = ws.given_end_to_prepared(given)
			response_staging.child_end_count += 1
		}
		if plan.reader_index == wiring_core.CHILD_PROCESS_INDEX {
			given, g_st := give_child_end_to_core(given_end_of_row(plan, obj, false))
			if g_st != .Ok {
				abort_prepared_batch()
				rec := errors.error_make(.Refused, .Wirings, 0, 0, 0, i64(g_st))
				rec.operation = i64(op_code)
				return {status = ws.response_status_from_op_status(g_st), tag = cmd.tag, error_record = rec}
			}
			response_staging.child_ends[response_staging.child_end_count] = ws.given_end_to_prepared(given)
			response_staging.child_end_count += 1
		}
	}
	region_write_response()
	return {status = .Ok, tag = cmd.tag, batch_id = batch_id}
}

@(private = "file")
give_child_end_to_core :: proc "contextless" (end: output.Given_End) -> (given: output.Given_End, status: system.Status) {
	given = end
	sources := [5]system.Handle{
		system.Handle(end.ring),
		system.Handle(end.end_words),
		system.Handle(end.terms),
		system.Handle(end.description),
		system.Handle(end.condition),
	}
	rights := [5]system.Rights{
		{.Read, .Write, .Give},
		{.Read, .Give},
		{.Read, .Give},
		{.Read, .Give},
		{.Read, .Give},
	}
	results := [5]^op.Handle{&given.ring, &given.end_words, &given.terms, &given.description, &given.condition}
	for source, idx in sources {
		if source == 0 {
			continue
		}
		h, st := system.give(core_ring_memory, source, rights[idx])
		if st != .Ok {
			return {}, st
		}
		results[idx]^ = op.Handle(h)
	}
	return given, .Ok
}

@(private = "file")
handle_commit_start_wiring :: proc "contextless" (cmd: ws.Command) -> ws.Response {
	if !prepared_batch.active || prepared_batch.id != cmd.batch_id {
		return {status = .Bad_State, tag = cmd.tag, error_record = errors.error_make(.State, .Wirings)}
	}
	child_idx, child_found := wiring_core.process_find(&state, cmd.process)
	if !child_found {
		abort_prepared_batch()
		return {status = .Bad_Handle, tag = cmd.tag, error_record = errors.error_make(.Absent, .Processes)}
	}
	asker_idx := prepared_batch.work.asker_index
	response_staging = {batch_id = prepared_batch.id}
	for number in 1 ..= prepared_batch.work.list.row_count {
		plan := &prepared_batch.work.plans[number - 1]
		obj := &prepared_batch.objects[number - 1]
		slot := plan.allocated_slot
		wiring_core.wiring_bind_child(&state, slot, child_idx)
		if plan.writer_index == wiring_core.CHILD_PROCESS_INDEX {
			plan.writer_index = child_idx
		}
		if plan.reader_index == wiring_core.CHILD_PROCESS_INDEX {
			plan.reader_index = child_idx
		}
		deliv_status := system.Status.Ok
		if plan.writer_index != child_idx {
			deliv_status = wiring_end_give(plan.writer_index, given_end_of_row(plan, obj, true))
		}
		if deliv_status == .Ok && plan.reader_index != child_idx {
			deliv_status = wiring_end_give(plan.reader_index, given_end_of_row(plan, obj, false))
		}
		keep_ring := plan.row.pace == .Always_Holds_Writer
		if keep_ring {
			wiring_ring_memory[slot] = obj.ring_memory
			wiring_ring_capacity[slot] = plan.row.capacity
		}
		close_row_objects(obj, keep_end = true, keep_ring = keep_ring)
		if deliv_status != .Ok {
			end_word, _ := wiring_core.wiring_end_slot(&state, slot, .Refused)
			end_words_write_and_wake(slot, end_word)
			wiring_slot_handles_close(slot)
			if plan.row.reader_end == .Asker && response_staging.asker_wiring_count < output.WIRING_ASKER_ROWS_OF_A_START {
				response_staging.asker_numbers[response_staging.asker_wiring_count] = 0
				response_staging.asker_wiring_count += 1
			}
			continue
		}
		wiring_core.wiring_mark_delivered(&state, slot, plan)
		log_wiring_created(plan, plan.allocated_number)
		if plan.row.reader_end == .Asker && response_staging.asker_wiring_count < output.WIRING_ASKER_ROWS_OF_A_START {
			response_staging.asker_numbers[response_staging.asker_wiring_count] = plan.allocated_number
			response_staging.asker_wiring_count += 1
		}
	}
	if state.processes[child_idx].ends_given - state.processes[child_idx].log_ends_given > 0 {
		// Keep completions the child may already have written for its start ends.
		_ = wiring_ring_hold(child_idx, drop_stale = false)
	}
	region_write_response()
	asker_active := u64(state.processes[asker_idx].wirings_asked)
	prepared_batch = {}
	return {status = .Ok, tag = cmd.tag, asker_active = asker_active}
}

@(private = "file")
handle_abort_start_wiring :: proc "contextless" (cmd: ws.Command) -> ws.Response {
	if !prepared_batch.active || prepared_batch.id != cmd.batch_id {
		return {status = .Bad_State, tag = cmd.tag, error_record = errors.error_make(.State, .Wirings)}
	}
	abort_prepared_batch()
	return {status = .Ok, tag = cmd.tag}
}

@(private = "file")
handle_unwire :: proc "contextless" (cmd: ws.Command) -> ws.Response {
	slot, end_word, _, st, ref := wiring_core.unwire_apply(&state, cmd.process, cmd.wiring_number, cmd.end_word, u32(cmd.kind))
	if st != .Ok {
		return {status = st, tag = cmd.tag, error_record = ref}
	}
	end_words_write_and_wake(slot, end_word)
	wiring_slot_handles_close(slot)
	return {status = .Ok, tag = cmd.tag, ended_count = 1}
}

@(private = "file")
handle_revoke_asker :: proc "contextless" (cmd: ws.Command) -> ws.Response {
	actions: [wiring_core.WIRINGS_OF_THE_MACHINE_MOST]wiring_core.Stop_Action
	count, found := wiring_core.revoke_asker_apply(&state, cmd.process, actions[:])
	if !found {
		return {status = .Ok, tag = cmd.tag, ended_count = 0}
	}
	for idx in 0 ..< count {
		act := actions[idx]
		end_words_write_and_wake(act.wiring_slot, act.end_word)
		wiring_slot_handles_close(act.wiring_slot)
	}
	return {status = .Ok, tag = cmd.tag, ended_count = u64(count)}
}

@(private = "file")
handle_query :: proc "contextless" (cmd: ws.Command) -> ws.Response {
	switch cmd.query_kind {
	case .None:
		return {status = .Bad_Command, tag = cmd.tag}
	case .Machine_Totals:
		return {
			status       = .Ok,
			tag          = cmd.tag,
			query_values = {u64(state.wirings_running), wiring_core.registered_process_count(&state), u64(state.list_page_holders)},
		}
	case .Asker_Count:
		idx, found := wiring_core.process_find(&state, cmd.process)
		if !found {
			return {status = .Bad_Handle, tag = cmd.tag, error_record = errors.error_make(.Absent, .Processes)}
		}
		return {status = .Ok, tag = cmd.tag, query_values = {u64(state.processes[idx].wirings_asked), 0, 0}}
	case .Process_Ends:
		idx, found := wiring_core.process_find(&state, cmd.process)
		if !found {
			return {status = .Bad_Handle, tag = cmd.tag, error_record = errors.error_make(.Absent, .Processes)}
		}
		return {status = .Ok, tag = cmd.tag, query_values = {u64(state.processes[idx].ends_given), u64(state.processes[idx].log_ends_given), 0}}
	}
	return {status = .Bad_Command, tag = cmd.tag}
}

@(private = "file")
stops_drain :: proc "contextless" () {
	actions: [wiring_core.WIRINGS_OF_THE_MACHINE_MOST]wiring_core.Stop_Action
	for record in system.receive(&stops_ring.commands) {
		notice, ok := ws.stop_notice_from_record(record)
		if !ok {
			system.log(.Warning, "wiring: refused malformed stop notice on stops ring, kind ", u64(record.kind))
			continue
		}
		count, proc_idx, matched := wiring_core.process_stop_apply(&state, notice, actions[:])
		if !matched {
			continue
		}
		for i in 0 ..< count {
			act := actions[i]
			switch act.kind {
			case .Detach:
			case .End_Wiring:
				end_words_write_and_wake(act.wiring_slot, act.end_word, act.stop_cause, act.stop_outcome)
				wiring_slot_handles_close(act.wiring_slot)
			}
		}
		ph := &process_handles[proc_idx]
		if ph.wiring_ring.head != nil {
			system.ring_close(&ph.wiring_ring)
		}
		close_handle(&ph.wiring_memory)
		ph.wiring_ring_ready = false
		close_handle(&ph.list_memory)
		close_handle(&ph.asker_budget)
		close_handle(&ph.process_token)
		ph.unknown_wiring_words = 0
	}
}

@(private = "file")
asker_wirings_snapshot :: proc "contextless" (had: ^[wiring_core.PROCESS_CAPACITY]bool) {
	for i in 0 ..< wiring_core.PROCESS_CAPACITY {
		had[i] = state.processes[i].active && state.processes[i].wirings_asked > 0
	}
}

@(private = "file")
asker_wirings_notify_emptied :: proc "contextless" (had: ^[wiring_core.PROCESS_CAPACITY]bool) {
	for i in 0 ..< wiring_core.PROCESS_CAPACITY {
		if had[i] && state.processes[i].active && state.processes[i].wirings_asked == 0 {
			_ = system.send(&core_ring.completions, ws.asker_wirings_empty_to_record(state.processes[i].id))
		}
	}
}

@(private = "file")
process_completions_drain :: proc "contextless" () {
	for proc_idx in 0 ..< wiring_core.PROCESS_CAPACITY {
		ph := &process_handles[proc_idx]
		if !state.processes[proc_idx].active || ph.wiring_ring.head == nil {
			continue
		}
		for _ in 0 ..< system.records_of_turn(&ph.wiring_ring.completions) {
			rec := system.receive(&ph.wiring_ring.completions) or_break
			act := wiring_core.wiring_completion_apply(&state, proc_idx, rec)
			switch act.effect {
			case .None:
			case .Write_End_Word:
				end_words_write_and_wake(act.wiring_slot, act.end_word)
			case .End_Wiring:
				if act.end_word == .Refused {
					system.log(.Info, "wiring: ", system.Module_Name{process_module_name(proc_idx)}, " refused its end of the wiring ", u64(act.wiring_number))
				}
				end_words_write_and_wake(act.wiring_slot, act.end_word)
				wiring_slot_handles_close(act.wiring_slot)
			case .Unknown_Word:
				ph.unknown_wiring_words += 1
				if ph.unknown_wiring_words == 1 {
					system.log(.Info, "wiring: ", system.Module_Name{process_module_name(proc_idx)}, " wrote a word of its wiring ring that names no wiring of it: it is dropped, and each later one is counted until its stop")
				}
			case .Dropped_Word:
				if act.first_drop {
					system.log(.Info, "wiring: ", system.Module_Name{process_module_name(proc_idx)}, " wrote a word of its wiring ring for the wiring ", u64(act.wiring_number), " after its answer: dropped")
				}
			}
		}
	}
}

@(private = "file")
core_commands_serve :: proc "contextless" () {
	for record in system.receive(&core_ring.commands) {
		cmd, ok := ws.command_from_record(record)
		if !ok {
			resp := ws.Response{
				status       = .Bad_Command,
				tag          = record.tag,
				error_record = errors.error_make(.Unsupported, .None, 0, i64(record.kind)),
			}
			_ = system.send(&core_ring.completions, ws.response_to_record(resp, .Wire))
			continue
		}
		resp: ws.Response
		switch cmd.kind {
		case .None:
			resp = {status = .Bad_Command, tag = cmd.tag}
		case .Register_Process:
			resp = handle_register_process(cmd)
		case .Grant_Asker_Budget:
			resp = handle_grant_asker_budget(cmd)
		case .List_Page:
			resp = handle_list_page(cmd)
		case .Wire:
			resp = handle_wire(cmd)
		case .Prepare_Start_Wiring:
			resp = handle_prepare_start_wiring(cmd)
		case .Commit_Start_Wiring:
			resp = handle_commit_start_wiring(cmd)
		case .Abort_Start_Wiring:
			resp = handle_abort_start_wiring(cmd)
		case .Unwire:
			resp = handle_unwire(cmd)
		case .Revoke_Asker:
			resp = handle_revoke_asker(cmd)
		case .Query:
			resp = handle_query(cmd)
		}
		_ = system.send(&core_ring.completions, ws.response_to_record(resp, cmd.kind))
	}
}

// Entry of the delegated wiring service: verifies its four attenuated
// context handles, then serves stops notices, process wiring completions,
// and core commands forever.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	core_ring_memory = ctx.handles[ws.SERVICE_RING]
	stops_ring_memory = ctx.handles[ws.SERVICE_STOPS_RING]
	image_memory := ctx.handles[ws.SERVICE_IMAGE]
	region_memory := ctx.handles[ws.SERVICE_REGION]
	image_size := ctx.values[ws.VALUE_IMAGE_SIZE]

	status: system.Status
	core_ring, status = system.ring_open(core_ring_memory, receive_handles = true)
	if status != .Ok {
		fail("no service ring")
	}
	stops_ring, status = system.ring_open(stops_ring_memory)
	if status != .Ok {
		fail("no stops ring")
	}
	img_kind, img_rights, _ := system.handle_state(image_memory)
	if img_kind != .Memory || !ws.attenuated_rights_allowed(.Read_Only_Image, img_rights) || image_size == 0 {
		fail("no read-only boot image")
	}
	img_addr, img_status := system.memory_map(image_memory, {})
	if img_status != .Ok {
		fail("cannot map boot image")
	}
	image = ([^]u8)(img_addr)[:image_size]

	reg_pages, reg_size_status := system.memory_size(region_memory)
	if reg_size_status != .Ok || reg_pages < ws.SERVICE_REGION_PAGES {
		fail("transfer region too small")
	}
	reg_addr, reg_map_status := system.memory_map(region_memory, {.Write})
	if reg_map_status != .Ok {
		fail("cannot map transfer region")
	}
	region = ([^]u8)(reg_addr)[:ws.SERVICE_REGION_SIZE]

	wiring_core.state_init(&state)
	system.log(.Info, "wiring: ready, read-only boot image ", image_size, " bytes")

	for {
		wait := system.wait_begin()
		// Serve core commands (Register_Process, Commit_Start_Wiring) before
		// stops_drain so a short-lived child that exits immediately after start
		// commits its wiring batch before its stop notice unregisters it.
		core_commands_serve()
		had_wirings: [wiring_core.PROCESS_CAPACITY]bool
		asker_wirings_snapshot(&had_wirings)
		stops_drain()
		process_completions_drain()
		wiring_rings_let_go()
		stall_rings_check()
		asker_wirings_notify_emptied(&had_wirings)

		system.wait_records(&wait, &stops_ring.commands)
		system.wait_records(&wait, &core_ring.commands)
		waited_rings := 0
		for proc_idx in 0 ..< wiring_core.PROCESS_CAPACITY {
			if waited_rings >= WIRING_WAITED_RINGS_MOST {
				break
			}
			ph := &process_handles[proc_idx]
			if state.processes[proc_idx].active && ph.wiring_ring.head != nil {
				system.wait_records(&wait, &ph.wiring_ring.completions)
				waited_rings += 1
			}
		}
		deadline := system.WAIT_FOREVER
		if next_deadline, watched := wiring_core.wiring_stall_next_deadline(&state, system.time(), STALL_POLL_INTERVAL_MS); watched {
			deadline = next_deadline
		}
		system.wait_end(&wait, deadline)
	}
}

// stall_rings_check observes every delivered Always_Holds_Writer wiring's
// ring head read-only and revokes any wiring whose ring stayed full without
// reader progress for at least STALL_HANG_BOUND_MS, unblocking its writer
// immediately while leaving healthy sibling wirings intact.
@(private = "file")
stall_rings_check :: proc "contextless" () {
	now_ms := system.time()
	for slot in 0 ..< wiring_core.WIRINGS_OF_THE_MACHINE_MOST {
		kept := &state.wirings[slot]
		if !kept.active || !kept.asked_counted || kept.pace != .Always_Holds_Writer {
			continue
		}
		ring_mem := wiring_ring_memory[slot]
		capacity := wiring_ring_capacity[slot]
		if ring_mem == 0 || capacity == 0 {
			continue
		}
		address, status := system.memory_map(ring_mem, {})
		if status != .Ok {
			continue
		}
		head := (^ring.Head)(address)
		write := intrinsics.atomic_load_explicit(&head.commands.write, .Acquire)
		read := intrinsics.atomic_load_explicit(&head.commands.read, .Acquire)
		system.memory_unmap(address)
		ring_full := (write - read) >= capacity
		wiring_core.wiring_stall_observe(&state, slot, ring_full, read, now_ms)
	}
	actions: [wiring_core.WIRINGS_OF_THE_MACHINE_MOST]wiring_core.Stop_Action
	revoked := wiring_core.wiring_stall_expire(&state, now_ms, actions[:])
	for i in 0 ..< revoked {
		act := actions[i]
		end_words_write_and_wake(act.wiring_slot, act.end_word)
		wiring_slot_handles_close(act.wiring_slot)
		system.log(.Warning, "wiring: revoked stalled Always_Holds_Writer wiring ", u64(act.wiring_number))
	}
}
