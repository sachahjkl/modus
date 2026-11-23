// Work accounting probe: per-connection work threads strictly funded by each
// client's offered child budget (src/md/features/work_accounting.md).
//
// Each client connection provides a child budget handle carrying the right
// Spend. The service allocates the connection's work thread stack, uncommitted
// scratch memory, and work thread itself on that client budget — never on the
// service's own budget. Exhaustion or revocation of one client affects only
// that client's work thread and never starves sibling clients.
package work_accounting_probe

import "base:intrinsics"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/work_budget"
import "modus:system"

// Default budget requirements for the probe service: one work thread stack,
// 8 pages of per-connection scratch space, and a 50 ms/s minimum time limit.
PROBE_REQUIREMENTS :: work_budget.Work_Budget_Requirements{
	stack_pages                    = work_budget.WORK_THREAD_DEFAULT_STACK_PAGES,
	scratch_pages                  = 8,
	ring_pages                     = work_budget.DEFAULT_RING_AND_REGION_PAGES,
	minimum_processor_microseconds = 50_000,
	maximum_pages                  = 512,
}

// Kernel operation callbacks used by Accounted_Service. On modus,
// modus_runtime_ops binds every callback directly to modus:system.
// Host tests supply a deterministic fake runtime to verify isolation invariants.
Worker_Runtime_Ops :: struct {
	state:                   rawptr,
	handle_state:            proc "contextless" (state: rawptr, handle: op.Handle) -> (kind: op.Object_Kind, rights: op.Rights),
	budget_read:             proc "contextless" (state: rawptr, budget: op.Handle) -> (amounts: op.Budget_Amounts, status: op.Status),
	memory_create_on_budget: proc "contextless" (state: rawptr, page_count: u64, budget: op.Handle, flags: op.Memory_Flags, error: ^errors.Error_Record) -> (memory: op.Handle, status: op.Status),
	memory_map:              proc "contextless" (state: rawptr, memory: op.Handle, error: ^errors.Error_Record) -> (address: rawptr, status: op.Status),
	memory_unmap:            proc "contextless" (state: rawptr, address: rawptr) -> op.Status,
	memory_commit_on_budget: proc "contextless" (state: rawptr, memory: op.Handle, budget: op.Handle, first_page: u64, page_count: u64, error: ^errors.Error_Record) -> (changed: u64, status: op.Status),
	thread_create_on_budget: proc "contextless" (state: rawptr, budget: op.Handle, entry: proc "c" (parameter: rawptr) -> !, stack_top: u64, parameter: rawptr, error: ^errors.Error_Record) -> (thread: op.Handle, status: op.Status),
	thread_stop:             proc "contextless" (state: rawptr, thread: op.Handle) -> op.Status,
	handle_close:            proc "contextless" (state: rawptr, handle: op.Handle),
	word_wait:               proc "contextless" (state: rawptr, word: ^u32, value: u32),
	word_wake:               proc "contextless" (state: rawptr, word: ^u32),
	nanoseconds:             proc "contextless" (state: rawptr) -> u64,
}

// Live per-connection worker resources owned on one client's work budget.
Connection_Worker :: struct {
	occupied:                bool,
	connection_identifier:   u64,
	client_budget:           op.Handle,
	stack_memory:            op.Handle,
	stack_base:              rawptr,
	stack_pages:             u64,
	scratch_memory:          op.Handle,
	scratch_base:            rawptr,
	scratch_reserved_pages:  u64,
	scratch_committed_pages: u64,
	work_thread:             op.Handle,
	request_sequence:        u32,
	response_sequence:       u32,
	stop_requested:          u32,
	requested_scratch_pages: u64,
	work_iterations:         u64,
	work_accumulator:        u64,
	last_refusal:            work_budget.Work_Budget_Refusal,
	last_error:              errors.Error_Record,
	last_cpu_nanoseconds:    u64,
	service:                 ^Accounted_Service,
}

// Service instance managing one work thread and one work budget per client
// connection without ever charging client work to service_own_budget.
Accounted_Service :: struct {
	table:   work_budget.Connection_Worker_Table,
	ops:     Worker_Runtime_Ops,
	workers: [work_budget.MAX_ACCOUNTED_CONNECTIONS]Connection_Worker,
}

// work_budget_contract_version exports the work accounting contract version.
@(export, link_name = "work_budget_contract_version")
work_budget_contract_version :: proc "c" () -> i64 {
	return i64(work_budget.ACCOUNTING_SNAPSHOT_VERSION)
}

@(private = "file")
modus_handle_state :: proc "contextless" (_: rawptr, handle: op.Handle) -> (kind: op.Object_Kind, rights: op.Rights) {
	object_kind, held_rights, _ := system.handle_state(handle)
	return object_kind, held_rights
}

@(private = "file")
modus_budget_read :: proc "contextless" (_: rawptr, budget: op.Handle) -> (amounts: op.Budget_Amounts, status: op.Status) {
	return system.budget_read(budget)
}

@(private = "file")
modus_memory_create_on_budget :: proc "contextless" (_: rawptr, page_count: u64, budget: op.Handle, flags: op.Memory_Flags, error: ^errors.Error_Record) -> (memory: op.Handle, status: op.Status) {
	// Refuse zero or the service's own budget so client memory can never fall
	// back to the service's budget.
	if budget == 0 || budget == system.own_budget() {
		errors.fail(error, 0, .Handle_Rights, .Budgets, 1, i64(budget), i64(transmute(u32)work_budget.WORK_BUDGET_REQUIRED_RIGHTS), 0)
		return 0, .No_Right
	}
	return system.memory_create(page_count, budget, flags, error)
}

@(private = "file")
modus_memory_map :: proc "contextless" (_: rawptr, memory: op.Handle, error: ^errors.Error_Record) -> (address: rawptr, status: op.Status) {
	return system.memory_map(memory, {.Write}, error = error)
}

@(private = "file")
modus_memory_unmap :: proc "contextless" (_: rawptr, address: rawptr) -> op.Status {
	return system.memory_unmap(address)
}

@(private = "file")
modus_memory_commit_on_budget :: proc "contextless" (_: rawptr, memory: op.Handle, budget: op.Handle, first_page: u64, page_count: u64, error: ^errors.Error_Record) -> (changed: u64, status: op.Status) {
	// Refuse zero or the service's own budget so scratch growth is strictly
	// charged to the client's work budget.
	if budget == 0 || budget == system.own_budget() {
		errors.fail(error, 0, .Handle_Rights, .Budgets, 1, i64(budget), i64(transmute(u32)work_budget.WORK_BUDGET_REQUIRED_RIGHTS), 0)
		return 0, .No_Right
	}
	ranges := [1]op.Page_Range{{first = first_page, page_count = page_count}}
	return system.memory_commit(memory, ranges[:], budget, error)
}

@(private = "file")
modus_thread_create_on_budget :: proc "contextless" (_: rawptr, budget: op.Handle, entry: proc "c" (parameter: rawptr) -> !, stack_top: u64, parameter: rawptr, error: ^errors.Error_Record) -> (thread: op.Handle, status: op.Status) {
	// Create the work thread directly on the client's work budget so both its
	// thread area and its processor time count strictly in the client's budget.
	if budget == 0 || budget == system.own_budget() {
		errors.fail(error, 0, .Handle_Rights, .Budgets, 1, i64(budget), i64(transmute(u32)work_budget.WORK_BUDGET_REQUIRED_RIGHTS), 0)
		return 0, .No_Right
	}
	results, call_status := system.call_with_error(error, .Thread_Create, u64(budget), u64(uintptr(rawptr(entry))), stack_top, u64(uintptr(parameter)), 0, 0)
	if call_status != .Ok {
		return 0, call_status
	}
	return op.Handle(results[0]), .Ok
}

@(private = "file")
modus_thread_stop :: proc "contextless" (_: rawptr, thread: op.Handle) -> op.Status {
	_, status := system.call(.Thread_Stop, u64(thread))
	return status
}

@(private = "file")
modus_handle_close :: proc "contextless" (_: rawptr, handle: op.Handle) {
	system.close(handle)
}

@(private = "file")
modus_word_wait :: proc "contextless" (_: rawptr, word: ^u32, value: u32) {
	system.word_wait(word, value)
}

@(private = "file")
modus_word_wake :: proc "contextless" (_: rawptr, word: ^u32) {
	system.word_wake(word, 1)
}

@(private = "file")
modus_nanoseconds :: proc "contextless" (_: rawptr) -> u64 {
	return system.nanoseconds()
}

// modus_runtime_ops returns the real kernel-backed runtime callbacks for modus.
modus_runtime_ops :: proc "contextless" () -> Worker_Runtime_Ops {
	return {
		handle_state            = modus_handle_state,
		budget_read             = modus_budget_read,
		memory_create_on_budget = modus_memory_create_on_budget,
		memory_map              = modus_memory_map,
		memory_unmap            = modus_memory_unmap,
		memory_commit_on_budget = modus_memory_commit_on_budget,
		thread_create_on_budget = modus_thread_create_on_budget,
		thread_stop             = modus_thread_stop,
		handle_close            = modus_handle_close,
		word_wait               = modus_word_wait,
		word_wake               = modus_word_wake,
		nanoseconds             = modus_nanoseconds,
	}
}

// service_init initializes an Accounted_Service with its budget requirements,
// its own budget handle (which is refused for any client connection), and its
// runtime callbacks.
service_init :: proc "contextless" (service: ^Accounted_Service, requirements: work_budget.Work_Budget_Requirements, service_own_budget: op.Handle, ops: Worker_Runtime_Ops) -> work_budget.Work_Budget_Refusal {
	if service == nil {
		return .Invalid_State
	}
	table, refusal := work_budget.table_init(requirements, service_own_budget)
	if refusal != .None {
		return refusal
	}
	service^ = {
		table = table,
		ops   = ops,
	}
	return .None
}

@(private = "file")
service_find_worker :: proc "contextless" (service: ^Accounted_Service, connection_identifier: u64) -> ^Connection_Worker {
	if service == nil || connection_identifier == 0 {
		return nil
	}
	for &worker in service.workers {
		if worker.occupied && worker.connection_identifier == connection_identifier {
			return &worker
		}
	}
	return nil
}

@(private = "file")
worker_teardown_resources :: proc "contextless" (service: ^Accounted_Service, worker: ^Connection_Worker, close_budget_handle: bool) {
	if worker.work_thread != 0 {
		service.ops.thread_stop(service.ops.state, worker.work_thread)
		service.ops.handle_close(service.ops.state, worker.work_thread)
		worker.work_thread = 0
	}
	if worker.scratch_base != nil {
		service.ops.memory_unmap(service.ops.state, worker.scratch_base)
		worker.scratch_base = nil
	}
	if worker.scratch_memory != 0 {
		service.ops.handle_close(service.ops.state, worker.scratch_memory)
		worker.scratch_memory = 0
	}
	if worker.stack_base != nil {
		service.ops.memory_unmap(service.ops.state, worker.stack_base)
		worker.stack_base = nil
	}
	if worker.stack_memory != 0 {
		service.ops.handle_close(service.ops.state, worker.stack_memory)
		worker.stack_memory = 0
	}
	if close_budget_handle && worker.client_budget != 0 {
		service.ops.handle_close(service.ops.state, worker.client_budget)
		worker.client_budget = 0
	}
}

// connection_worker_thread_entry is the entry point of each per-connection work
// thread. It executes strictly on its client's work budget, waiting on its own
// request word so exhausting this client's budget never holds any shared lock.
connection_worker_thread_entry :: proc "c" (parameter: rawptr) -> ! {
	worker := (^Connection_Worker)(parameter)
	service := worker.service
	seen := u32(0)
	for {
		if intrinsics.atomic_load(&worker.stop_requested) != 0 {
			system.thread_stop()
		}
		current := intrinsics.atomic_load(&worker.request_sequence)
		if current == seen {
			service.ops.word_wait(service.ops.state, &worker.request_sequence, seen)
			continue
		}
		seen = current
		requested_pages := intrinsics.atomic_load(&worker.requested_scratch_pages)
		iterations := intrinsics.atomic_load(&worker.work_iterations)
		refusal := connection_worker_execute_request(service, worker.connection_identifier, requested_pages, iterations, &worker.last_error)
		worker.last_refusal = refusal
		intrinsics.atomic_store(&worker.response_sequence, seen)
		service.ops.word_wake(service.ops.state, &worker.response_sequence)
	}
}

// service_connect_client validates the client's offered work budget handle,
// allocates stack and uncommitted scratch memory on that budget, and spawns one
// work thread on that budget. On any refusal or kernel failure, every partial
// allocation is torn down cleanly and the service's own budget stays untouched.
service_connect_client :: proc "contextless" (
	service: ^Accounted_Service,
	connection_identifier: u64,
	client_budget: op.Handle,
	offered_pages: u64,
	offered_time: u64,
	offered_threads: u64,
	error: ^errors.Error_Record = nil,
) -> work_budget.Work_Budget_Refusal {
	if service == nil || !service.table.initialized || connection_identifier == 0 {
		if error != nil {
			error^ = work_budget.work_budget_refusal_to_error_record(.Invalid_State, 1, i64(connection_identifier))
		}
		return .Invalid_State
	}
	if client_budget == 0 {
		if error != nil {
			error^ = work_budget.work_budget_refusal_to_error_record(.Missing_Spend_Right, 2, 0)
		}
		return .Missing_Spend_Right
	}
	if service.table.service_own_budget != 0 && client_budget == service.table.service_own_budget {
		if error != nil {
			error^ = work_budget.work_budget_refusal_to_error_record(.Invalid_State, 2, i64(client_budget))
		}
		return .Invalid_State
	}

	kind, rights := service.ops.handle_state(service.ops.state, client_budget)
	if kind != .Budget || !(work_budget.WORK_BUDGET_REQUIRED_RIGHTS <= rights) {
		if error != nil {
			error^ = work_budget.work_budget_refusal_to_error_record(.Missing_Spend_Right, 2, i64(client_budget), i64(transmute(u32)work_budget.WORK_BUDGET_REQUIRED_RIGHTS), i64(transmute(u32)rights))
		}
		return .Missing_Spend_Right
	}

	// When the handle also carries Read, read the authoritative kernel amounts
	// so a caller cannot overstate a readable budget. A Spend-only handle skips
	// Budget_Read and relies on the kernel enforcing exact limits at allocation.
	effective_pages := offered_pages
	effective_time := offered_time
	effective_threads := offered_threads
	if .Read in rights && service.ops.budget_read != nil {
		amounts, read_status := service.ops.budget_read(service.ops.state, client_budget)
		if read_status == .Ok {
			effective_pages = amounts.pages
			effective_time = amounts.processor
			effective_threads = amounts.threads
		}
	}

	open_refusal := work_budget.connection_open(&service.table, connection_identifier, client_budget, effective_pages, effective_time, effective_threads, true)
	if open_refusal != .None {
		if error != nil {
			error^ = work_budget.work_budget_refusal_to_error_record(open_refusal, 2, i64(client_budget))
		}
		return open_refusal
	}

	free_index := -1
	for &worker, index in service.workers {
		if !worker.occupied {
			free_index = index
			break
		}
	}
	if free_index < 0 {
		_, _ = work_budget.connection_close(&service.table, connection_identifier)
		if error != nil {
			error^ = work_budget.work_budget_refusal_to_error_record(.Too_Many_Connections, 1, i64(connection_identifier))
		}
		return .Too_Many_Connections
	}

	req := service.table.requirements
	worker := &service.workers[free_index]
	worker^ = {
		occupied              = true,
		connection_identifier = connection_identifier,
		client_budget         = client_budget,
		stack_pages           = req.stack_pages,
		service               = service,
	}

	// Allocate the work thread stack strictly on client_budget.
	stack_memory, stack_status := service.ops.memory_create_on_budget(service.ops.state, req.stack_pages, client_budget, {}, error)
	if stack_status != .Ok {
		worker^ = {}
		_, _ = work_budget.connection_close(&service.table, connection_identifier)
		return status_to_connect_refusal(stack_status, .Too_Few_Pages)
	}
	worker.stack_memory = stack_memory

	stack_base, map_status := service.ops.memory_map(service.ops.state, stack_memory, error)
	if map_status != .Ok {
		worker_teardown_resources(service, worker, false)
		worker^ = {}
		_, _ = work_budget.connection_close(&service.table, connection_identifier)
		return status_to_connect_refusal(map_status, .Too_Few_Pages)
	}
	worker.stack_base = stack_base

	// Reserve uncommitted scratch memory on client_budget so dynamic client
	// work commits pages directly from client_budget and returns No_Budget when
	// exhausted.
	base_pages, _ := work_budget.work_budget_base_pages(req)
	reserve_pages := req.scratch_pages
	if effective_pages > base_pages && effective_pages - base_pages > reserve_pages {
		reserve_pages = effective_pages - base_pages
	}
	if reserve_pages > 0 {
		scratch_memory, scratch_status := service.ops.memory_create_on_budget(service.ops.state, reserve_pages, client_budget, {.Uncommitted}, error)
		if scratch_status != .Ok {
			worker_teardown_resources(service, worker, false)
			worker^ = {}
			_, _ = work_budget.connection_close(&service.table, connection_identifier)
			return status_to_connect_refusal(scratch_status, .Too_Few_Pages)
		}
		worker.scratch_memory = scratch_memory
		worker.scratch_reserved_pages = reserve_pages

		scratch_base, scratch_map_status := service.ops.memory_map(service.ops.state, scratch_memory, error)
		if scratch_map_status != .Ok {
			worker_teardown_resources(service, worker, false)
			worker^ = {}
			_, _ = work_budget.connection_close(&service.table, connection_identifier)
			return status_to_connect_refusal(scratch_map_status, .Too_Few_Pages)
		}
		worker.scratch_base = scratch_base
	}

	// Create the per-connection work thread strictly on client_budget.
	stack_top := u64(uintptr(worker.stack_base)) + worker.stack_pages * op.PAGE_SIZE
	thread_handle, thread_status := service.ops.thread_create_on_budget(service.ops.state, client_budget, connection_worker_thread_entry, stack_top, worker, error)
	if thread_status != .Ok {
		worker_teardown_resources(service, worker, false)
		worker^ = {}
		_, _ = work_budget.connection_close(&service.table, connection_identifier)
		return status_to_connect_refusal(thread_status, .Missing_Thread_Slot)
	}
	worker.work_thread = thread_handle

	activate_refusal := work_budget.connection_activate(&service.table, connection_identifier, thread_handle)
	if activate_refusal != .None {
		worker_teardown_resources(service, worker, false)
		worker^ = {}
		_, _ = work_budget.connection_close(&service.table, connection_identifier)
		if error != nil {
			error^ = work_budget.work_budget_refusal_to_error_record(activate_refusal, 1, i64(connection_identifier))
		}
		return activate_refusal
	}
	return .None
}

@(private = "file")
status_to_connect_refusal :: proc "contextless" (status: op.Status, on_no_budget: work_budget.Work_Budget_Refusal) -> work_budget.Work_Budget_Refusal {
	switch status {
	case .No_Budget:
		return on_no_budget
	case .No_Right:
		return .Missing_Spend_Right
	case .Bad_Handle:
		return .Budget_Revoked
	case .Ok, .Bad_Operation, .Bad_Address, .Bad_State, .No_Slot, .No_Memory:
		return .Invalid_State
	}
	return .Invalid_State
}

// connection_worker_execute_request executes one request for a connection,
// committing requested scratch pages strictly on the client's budget and
// recording elapsed processor nanoseconds. Exhausting this client's budget
// marks ONLY this connection Exhausted and never touches sibling connections.
connection_worker_execute_request :: proc "contextless" (
	service: ^Accounted_Service,
	connection_identifier: u64,
	requested_scratch_pages: u64,
	work_iterations: u64,
	error: ^errors.Error_Record = nil,
) -> work_budget.Work_Budget_Refusal {
	if service == nil || !service.table.initialized {
		return .Invalid_State
	}
	if begin_refusal := work_budget.connection_begin_request(&service.table, connection_identifier); begin_refusal != .None {
		if error != nil {
			error^ = work_budget.work_budget_refusal_to_error_record(begin_refusal, 1, i64(connection_identifier))
		}
		return begin_refusal
	}
	worker := service_find_worker(service, connection_identifier)
	if worker == nil {
		return .Invalid_State
	}

	start_ns := service.ops.nanoseconds(service.ops.state)

	if requested_scratch_pages > 0 {
		account, has_account := work_budget.connection_account(&service.table, connection_identifier)
		remaining_account_pages := has_account ? account.pages_limit - account.pages_charged : u64(0)
		if worker.scratch_memory == 0 || requested_scratch_pages > worker.scratch_reserved_pages - worker.scratch_committed_pages || requested_scratch_pages > remaining_account_pages {
			_ = work_budget.connection_mark_exhausted(&service.table, connection_identifier)
			if error != nil {
				error^ = work_budget.work_budget_refusal_to_error_record(.Budget_Exhausted, 2, i64(requested_scratch_pages), i64(remaining_account_pages))
			}
			return .Budget_Exhausted
		}
		_, commit_status := service.ops.memory_commit_on_budget(service.ops.state, worker.scratch_memory, worker.client_budget, worker.scratch_committed_pages, requested_scratch_pages, error)
		if commit_status != .Ok {
			if commit_status == .Bad_Handle || commit_status == .No_Right {
				_, _ = service_revoke_client(service, connection_identifier)
				return .Budget_Revoked
			}
			_ = work_budget.connection_mark_exhausted(&service.table, connection_identifier)
			if error != nil && error.kind == i64(errors.Kind.None) {
				error^ = work_budget.work_budget_refusal_to_error_record(.Budget_Exhausted, 2, i64(requested_scratch_pages))
			}
			return .Budget_Exhausted
		}
		if charge_refusal := work_budget.connection_charge_pages(&service.table, connection_identifier, requested_scratch_pages); charge_refusal != .None {
			if error != nil {
				error^ = work_budget.work_budget_refusal_to_error_record(charge_refusal, 2, i64(requested_scratch_pages))
			}
			return charge_refusal
		}
		worker.scratch_committed_pages += requested_scratch_pages
	}

	// Run bounded private work on the connection's work thread.
	accumulator := worker.work_accumulator
	for step in u64(0) ..< work_iterations {
		accumulator = accumulator * 6364136223846793005 + step + 1
	}
	worker.work_accumulator = accumulator

	end_ns := service.ops.nanoseconds(service.ops.state)
	elapsed_ns := end_ns >= start_ns ? end_ns - start_ns : 0
	worker.last_cpu_nanoseconds = elapsed_ns

	complete_refusal := work_budget.connection_complete_request(&service.table, connection_identifier, elapsed_ns)
	if complete_refusal != .None && error != nil {
		error^ = work_budget.work_budget_refusal_to_error_record(complete_refusal, 1, i64(connection_identifier))
	}
	return complete_refusal
}

// service_submit_to_worker dispatches one request to a live modus work thread
// and waits for that worker's completion word.
service_submit_to_worker :: proc "contextless" (service: ^Accounted_Service, connection_identifier: u64, requested_scratch_pages: u64, work_iterations: u64, error: ^errors.Error_Record = nil) -> work_budget.Work_Budget_Refusal {
	worker := service_find_worker(service, connection_identifier)
	if worker == nil {
		_, refusal := work_budget.connection_snapshot(&service.table, connection_identifier)
		return refusal == .None ? .Invalid_State : refusal
	}
	next_seq := intrinsics.atomic_load(&worker.request_sequence) + 1
	intrinsics.atomic_store(&worker.requested_scratch_pages, requested_scratch_pages)
	intrinsics.atomic_store(&worker.work_iterations, work_iterations)
	worker.last_error = {}
	intrinsics.atomic_store(&worker.request_sequence, next_seq)
	service.ops.word_wake(service.ops.state, &worker.request_sequence)
	for {
		done := intrinsics.atomic_load(&worker.response_sequence)
		if done == next_seq {
			break
		}
		service.ops.word_wait(service.ops.state, &worker.response_sequence, done)
	}
	if error != nil && worker.last_refusal != .None {
		error^ = worker.last_error
	}
	return worker.last_refusal
}

// service_revoke_client halts a client's work thread, releases its stack,
// scratch memory, and budget handle, transitions the account to Revoked, and
// reclaims the slot. Sibling connections continue undisturbed.
service_revoke_client :: proc "contextless" (service: ^Accounted_Service, connection_identifier: u64) -> (snapshot: work_budget.Accounting_Snapshot, refusal: work_budget.Work_Budget_Refusal) {
	if service == nil || !service.table.initialized {
		return {}, .Invalid_State
	}
	worker := service_find_worker(service, connection_identifier)
	if worker != nil {
		intrinsics.atomic_store(&worker.stop_requested, 1)
		service.ops.word_wake(service.ops.state, &worker.request_sequence)
		worker_teardown_resources(service, worker, true)
		worker^ = {}
	}
	return work_budget.connection_revoke(&service.table, connection_identifier)
}

// service_disconnect_client cleanly stops a client's work thread, releases all
// resources paid by that client's budget, transitions the account to Closed,
// and reclaims the slot.
service_disconnect_client :: proc "contextless" (service: ^Accounted_Service, connection_identifier: u64) -> (snapshot: work_budget.Accounting_Snapshot, refusal: work_budget.Work_Budget_Refusal) {
	if service == nil || !service.table.initialized {
		return {}, .Invalid_State
	}
	worker := service_find_worker(service, connection_identifier)
	if worker != nil {
		intrinsics.atomic_store(&worker.stop_requested, 1)
		service.ops.word_wake(service.ops.state, &worker.request_sequence)
		worker_teardown_resources(service, worker, true)
		worker^ = {}
	}
	return work_budget.connection_close(&service.table, connection_identifier)
}

// Global probe service instance used by the exported self-test so no stack
// frame overflows when running on modus.
probe_service: Accounted_Service

// run_two_client_isolation_probe creates two child budgets attenuated to Spend
// only, spawns one work thread per client on its own child budget, exhausts
// client 1's scratch pages while proving client 2 keeps running and the
// service's own remaining pages never drop for client work, then revokes and
// closes both cleanly. Gives Succeeded, or a failure with an error record.
@(export, link_name = "run_two_client_isolation_probe")
run_two_client_isolation_probe :: proc "c" (error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	own_budget := system.own_budget()
	if init_refusal := service_init(&probe_service, PROBE_REQUIREMENTS, own_budget, modus_runtime_ops()); init_refusal != .None {
		if error != nil {
			error^ = work_budget.work_budget_refusal_to_error_record(init_refusal)
		}
		return .Wrong_State, 0
	}

	amounts_a, ok_a := work_budget.work_budget_child_amounts(PROBE_REQUIREMENTS, 0)
	amounts_b, ok_b := work_budget.work_budget_child_amounts(PROBE_REQUIREMENTS, 32)
	if !ok_a || !ok_b {
		return call_outcome.fail(error, .Wrong_State, .State, .Pages)
	}

	parent_a, status_a := system.budget_create(amounts_a, own_budget, error)
	if status_a != .Ok {
		return system.outcome_of_own_status(status_a), 0
	}
	defer system.close(parent_a)

	parent_b, status_b := system.budget_create(amounts_b, own_budget, error)
	if status_b != .Ok {
		return system.outcome_of_own_status(status_b), 0
	}
	defer system.close(parent_b)

	// Attenuate both handles to Spend only before passing them to the service.
	spend_a, give_a := system.give(0, parent_a, {.Spend}, error)
	if give_a != .Ok {
		return system.outcome_of_own_status(give_a), 0
	}
	spend_b, give_b := system.give(0, parent_b, {.Spend}, error)
	if give_b != .Ok {
		system.close(spend_a)
		return system.outcome_of_own_status(give_b), 0
	}

	// Snapshot the service's own budget after both child budgets have been split
	// off. Client connections and work must not spend any further own pages.
	own_before, read_status := system.budget_read(own_budget, error)
	if read_status != .Ok {
		system.close(spend_a)
		system.close(spend_b)
		return system.outcome_of_own_status(read_status), 0
	}

	if connect_a := service_connect_client(&probe_service, 1, spend_a, amounts_a.pages, amounts_a.processor, amounts_a.threads, error); connect_a != .None {
		system.close(spend_a)
		system.close(spend_b)
		return .Wrong_State, 0
	}
	if connect_b := service_connect_client(&probe_service, 2, spend_b, amounts_b.pages, amounts_b.processor, amounts_b.threads, error); connect_b != .None {
		_, _ = service_disconnect_client(&probe_service, 1)
		system.close(spend_b)
		return .Wrong_State, 0
	}

	// Ask client 1 for more scratch pages than its tight child budget holds ->
	// must exhaust ONLY client 1.
	exhaust_refusal := service_submit_to_worker(&probe_service, 1, PROBE_REQUIREMENTS.scratch_pages + 16, 64)
	if exhaust_refusal != .Budget_Exhausted {
		_, _ = service_disconnect_client(&probe_service, 1)
		_, _ = service_disconnect_client(&probe_service, 2)
		return call_outcome.fail(error, .Wrong_State, .State, .Budgets, 1, i64(exhaust_refusal), i64(work_budget.Work_Budget_Refusal.Budget_Exhausted))
	}

	// Client 2 must keep serving work cleanly on its own work thread.
	b_refusal := service_submit_to_worker(&probe_service, 2, 4, 256, error)
	if b_refusal != .None {
		_, _ = service_disconnect_client(&probe_service, 1)
		_, _ = service_disconnect_client(&probe_service, 2)
		return .Wrong_State, 0
	}

	own_after_work, _ := system.budget_read(own_budget)

	_, _ = service_revoke_client(&probe_service, 1)
	_, _ = service_disconnect_client(&probe_service, 2)

	// Confirm the service's own budget did not lose pages to client work.
	if own_after_work.pages < own_before.pages {
		return call_outcome.fail(error, .Budget_Or_Capacity_Exhausted, .Budget, .Pages, 0, i64(own_after_work.pages), i64(own_before.pages))
	}
	return .Succeeded, 0
}
