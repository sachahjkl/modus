#+build !freestanding
package work_accounting_probe

import "core:testing"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/work_budget"

Fake_Budget :: struct {
	alive:             bool,
	handle:            op.Handle,
	rights:            op.Rights,
	pages_initial:     u64,
	pages_remaining:   u64,
	threads_initial:   u64,
	threads_remaining: u64,
	processor:         u64,
	revoked:           bool,
}

Fake_Memory :: struct {
	alive:           bool,
	handle:          op.Handle,
	payer:           op.Handle,
	reserved_pages:  u64,
	committed_pages: u64,
	uncommitted:     bool,
	list_pages:      u64,
	mapped:          bool,
	mapped_address:  rawptr,
}

Fake_Thread :: struct {
	alive:   bool,
	handle:  op.Handle,
	payer:   op.Handle,
	stopped: bool,
}

Fake_Kernel_Runtime :: struct {
	service_own_budget:        op.Handle,
	service_budget_touched:    bool,
	next_handle:               u32,
	next_address:              uintptr,
	clock_ns:                  u64,
	budgets:                   [work_budget.MAX_ACCOUNTED_CONNECTIONS + 8]Fake_Budget,
	memories:                  [work_budget.MAX_ACCOUNTED_CONNECTIONS * 4 + 16]Fake_Memory,
	threads:                   [work_budget.MAX_ACCOUNTED_CONNECTIONS + 8]Fake_Thread,
	non_budget_handle:         op.Handle,
	force_thread_create_fail:  op.Status,
}

@(private = "file")
fake_init :: proc(rt: ^Fake_Kernel_Runtime) {
	rt^ = {
		next_handle  = 10,
		next_address = 0x1000_0000,
		clock_ns     = 1_000_000,
	}
	rt.service_own_budget = fake_add_budget(rt, {.Give, .Read, .Spend, .Commit}, 4096, 8, 1_000_000)
	rt.non_budget_handle = op.Handle(rt.next_handle)
	rt.next_handle += 1
}

@(private = "file")
fake_add_budget :: proc(rt: ^Fake_Kernel_Runtime, rights: op.Rights, pages, threads, processor: u64) -> op.Handle {
	for &b in rt.budgets {
		if !b.alive {
			h := op.Handle(rt.next_handle)
			rt.next_handle += 1
			b = {
				alive             = true,
				handle            = h,
				rights            = rights,
				pages_initial     = pages,
				pages_remaining   = pages,
				threads_initial   = threads,
				threads_remaining = threads,
				processor         = processor,
			}
			return h
		}
	}
	return 0
}

@(private = "file")
fake_find_budget :: proc "contextless" (rt: ^Fake_Kernel_Runtime, h: op.Handle) -> ^Fake_Budget {
	for &b in rt.budgets {
		if b.alive && b.handle == h {
			return &b
		}
	}
	return nil
}

@(private = "file")
fake_find_memory :: proc "contextless" (rt: ^Fake_Kernel_Runtime, h: op.Handle) -> ^Fake_Memory {
	for &m in rt.memories {
		if m.alive && m.handle == h {
			return &m
		}
	}
	return nil
}

@(private = "file")
fake_find_thread :: proc "contextless" (rt: ^Fake_Kernel_Runtime, h: op.Handle) -> ^Fake_Thread {
	for &th in rt.threads {
		if th.alive && th.handle == h {
			return &th
		}
	}
	return nil
}

@(private = "file")
fake_handle_state :: proc "contextless" (state: rawptr, handle: op.Handle) -> (kind: op.Object_Kind, rights: op.Rights) {
	rt := (^Fake_Kernel_Runtime)(state)
	if handle == rt.non_budget_handle {
		return .Memory, {.Read, .Write}
	}
	if b := fake_find_budget(rt, handle); b != nil && !b.revoked {
		return .Budget, b.rights
	}
	if m := fake_find_memory(rt, handle); m != nil {
		return .Memory, {.Read, .Write}
	}
	if th := fake_find_thread(rt, handle); th != nil {
		return .Thread, {.Read, .Control}
	}
	return .None, {}
}

@(private = "file")
fake_budget_read :: proc "contextless" (state: rawptr, budget: op.Handle) -> (amounts: op.Budget_Amounts, status: op.Status) {
	rt := (^Fake_Kernel_Runtime)(state)
	b := fake_find_budget(rt, budget)
	if b == nil || b.revoked {
		return {}, .Bad_Handle
	}
	if .Read not_in b.rights {
		return {}, .No_Right
	}
	return {
		pages     = b.pages_remaining,
		threads   = b.threads_remaining,
		processor = b.processor,
	}, .Ok
}

@(private = "file")
fake_memory_create :: proc "contextless" (state: rawptr, page_count: u64, budget: op.Handle, flags: op.Memory_Flags, error: ^errors.Error_Record) -> (memory: op.Handle, status: op.Status) {
	rt := (^Fake_Kernel_Runtime)(state)
	if budget == 0 || budget == rt.service_own_budget {
		rt.service_budget_touched = true
		return 0, .No_Right
	}
	b := fake_find_budget(rt, budget)
	if b == nil || b.revoked {
		return 0, .Bad_Handle
	}
	if .Spend not_in b.rights {
		return 0, .No_Right
	}
	is_uncommitted := .Uncommitted in flags
	full_cost := op.memory_cost(page_count)
	list_cost := full_cost > page_count ? full_cost - page_count : 0
	upfront := is_uncommitted ? max(list_cost, u64(1)) : full_cost
	if b.pages_remaining < upfront {
		if error != nil {
			error^ = errors.error_make(.Budget, .Pages, 1, i64(budget), i64(upfront), i64(b.pages_remaining))
		}
		return 0, .No_Budget
	}
	for &m in rt.memories {
		if !m.alive {
			h := op.Handle(rt.next_handle)
			rt.next_handle += 1
			b.pages_remaining -= upfront
			m = {
				alive           = true,
				handle          = h,
				payer           = budget,
				reserved_pages  = page_count,
				committed_pages = is_uncommitted ? 0 : page_count,
				uncommitted     = is_uncommitted,
				list_pages      = is_uncommitted ? upfront : list_cost,
			}
			return h, .Ok
		}
	}
	return 0, .No_Slot
}

@(private = "file")
fake_memory_map :: proc "contextless" (state: rawptr, memory: op.Handle, _: ^errors.Error_Record) -> (address: rawptr, status: op.Status) {
	rt := (^Fake_Kernel_Runtime)(state)
	m := fake_find_memory(rt, memory)
	if m == nil {
		return nil, .Bad_Handle
	}
	addr := rawptr(rt.next_address)
	rt.next_address += uintptr((m.reserved_pages + 2) * op.PAGE_SIZE)
	m.mapped = true
	m.mapped_address = addr
	return addr, .Ok
}

@(private = "file")
fake_memory_unmap :: proc "contextless" (state: rawptr, address: rawptr) -> op.Status {
	rt := (^Fake_Kernel_Runtime)(state)
	for &m in rt.memories {
		if m.alive && m.mapped && m.mapped_address == address {
			m.mapped = false
			m.mapped_address = nil
			return .Ok
		}
	}
	return .Bad_Address
}

@(private = "file")
fake_memory_commit :: proc "contextless" (state: rawptr, memory: op.Handle, budget: op.Handle, first_page: u64, page_count: u64, error: ^errors.Error_Record) -> (changed: u64, status: op.Status) {
	rt := (^Fake_Kernel_Runtime)(state)
	if budget == 0 || budget == rt.service_own_budget {
		rt.service_budget_touched = true
		return 0, .No_Right
	}
	b := fake_find_budget(rt, budget)
	if b == nil || b.revoked {
		return 0, .Bad_Handle
	}
	if .Spend not_in b.rights {
		return 0, .No_Right
	}
	m := fake_find_memory(rt, memory)
	if m == nil || m.payer != budget || !m.uncommitted {
		return 0, .Bad_Handle
	}
	if first_page + page_count > m.reserved_pages {
		return 0, .Bad_Address
	}
	if b.pages_remaining < page_count {
		if error != nil {
			error^ = errors.error_make(.Budget, .Pages, 1, i64(budget), i64(page_count), i64(b.pages_remaining))
		}
		return 0, .No_Budget
	}
	b.pages_remaining -= page_count
	m.committed_pages += page_count
	return page_count, .Ok
}

@(private = "file")
fake_thread_create :: proc "contextless" (state: rawptr, budget: op.Handle, _: proc "c" (parameter: rawptr) -> !, _: u64, _: rawptr, error: ^errors.Error_Record) -> (thread: op.Handle, status: op.Status) {
	rt := (^Fake_Kernel_Runtime)(state)
	if budget == 0 || budget == rt.service_own_budget {
		rt.service_budget_touched = true
		return 0, .No_Right
	}
	if rt.force_thread_create_fail != .Ok {
		fail := rt.force_thread_create_fail
		rt.force_thread_create_fail = .Ok
		return 0, fail
	}
	b := fake_find_budget(rt, budget)
	if b == nil || b.revoked {
		return 0, .Bad_Handle
	}
	if .Spend not_in b.rights {
		return 0, .No_Right
	}
	if b.threads_remaining < 1 {
		if error != nil {
			error^ = errors.error_make(.Budget, .Threads, 1, i64(budget), 1, 0)
		}
		return 0, .No_Budget
	}
	if b.pages_remaining < work_budget.WORK_THREAD_AREA_PAGES {
		if error != nil {
			error^ = errors.error_make(.Budget, .Pages, 1, i64(budget), i64(work_budget.WORK_THREAD_AREA_PAGES), i64(b.pages_remaining))
		}
		return 0, .No_Budget
	}
	for &th in rt.threads {
		if !th.alive {
			h := op.Handle(rt.next_handle)
			rt.next_handle += 1
			b.threads_remaining -= 1
			b.pages_remaining -= work_budget.WORK_THREAD_AREA_PAGES
			th = {alive = true, handle = h, payer = budget}
			return h, .Ok
		}
	}
	return 0, .No_Slot
}

@(private = "file")
fake_thread_stop :: proc "contextless" (state: rawptr, thread: op.Handle) -> op.Status {
	rt := (^Fake_Kernel_Runtime)(state)
	th := fake_find_thread(rt, thread)
	if th == nil {
		return .Bad_Handle
	}
	if !th.stopped {
		th.stopped = true
		if b := fake_find_budget(rt, th.payer); b != nil {
			b.threads_remaining += 1
			b.pages_remaining += work_budget.WORK_THREAD_AREA_PAGES
		}
	}
	return .Ok
}

@(private = "file")
fake_handle_close :: proc "contextless" (state: rawptr, handle: op.Handle) {
	rt := (^Fake_Kernel_Runtime)(state)
	if m := fake_find_memory(rt, handle); m != nil {
		if b := fake_find_budget(rt, m.payer); b != nil {
			b.pages_remaining += m.committed_pages + m.list_pages
		}
		m^ = {}
		return
	}
	if th := fake_find_thread(rt, handle); th != nil {
		if !th.stopped {
			if b := fake_find_budget(rt, th.payer); b != nil {
				b.threads_remaining += 1
				b.pages_remaining += work_budget.WORK_THREAD_AREA_PAGES
			}
		}
		th^ = {}
		return
	}
}

@(private = "file")
fake_word_wait :: proc "contextless" (_: rawptr, _: ^u32, _: u32) {}

@(private = "file")
fake_word_wake :: proc "contextless" (_: rawptr, _: ^u32) {}

@(private = "file")
fake_nanoseconds :: proc "contextless" (state: rawptr) -> u64 {
	rt := (^Fake_Kernel_Runtime)(state)
	rt.clock_ns += 25_000
	return rt.clock_ns
}

@(private = "file")
fake_ops :: proc(rt: ^Fake_Kernel_Runtime) -> Worker_Runtime_Ops {
	return {
		state                   = rt,
		handle_state            = fake_handle_state,
		budget_read             = fake_budget_read,
		memory_create_on_budget = fake_memory_create,
		memory_map              = fake_memory_map,
		memory_unmap            = fake_memory_unmap,
		memory_commit_on_budget = fake_memory_commit,
		thread_create_on_budget = fake_thread_create,
		thread_stop             = fake_thread_stop,
		handle_close            = fake_handle_close,
		word_wait               = fake_word_wait,
		word_wake               = fake_word_wake,
		nanoseconds             = fake_nanoseconds,
	}
}

@(private = "file")
fake_live_counts :: proc(rt: ^Fake_Kernel_Runtime) -> (memories: int, mappings: int, threads: int) {
	for &m in rt.memories {
		if m.alive {
			memories += 1
		}
		if m.mapped {
			mappings += 1
		}
	}
	for &th in rt.threads {
		if th.alive {
			threads += 1
		}
	}
	return
}

@(test)
service_refuses_service_own_budget_and_missing_spend_right :: proc(t: ^testing.T) {
	rt: Fake_Kernel_Runtime
	fake_init(&rt)

	service: Accounted_Service
	testing.expect_value(t, service_init(&service, PROBE_REQUIREMENTS, rt.service_own_budget, fake_ops(&rt)), work_budget.Work_Budget_Refusal.None)

	min_pages, _ := work_budget.work_budget_minimum_pages(PROBE_REQUIREMENTS)
	min_time := PROBE_REQUIREMENTS.minimum_processor_microseconds
	err: errors.Error_Record

	// Service own budget handle refused before any kernel allocation.
	testing.expect_value(t, service_connect_client(&service, 1, rt.service_own_budget, min_pages, min_time, 1, &err), work_budget.Work_Budget_Refusal.Invalid_State)
	// Handle 0 refused.
	testing.expect_value(t, service_connect_client(&service, 1, 0, min_pages, min_time, 1, &err), work_budget.Work_Budget_Refusal.Missing_Spend_Right)
	// Non-budget handle refused.
	testing.expect_value(t, service_connect_client(&service, 1, rt.non_budget_handle, min_pages, min_time, 1, &err), work_budget.Work_Budget_Refusal.Missing_Spend_Right)
	// Budget without Spend right (Read + Commit only) refused.
	no_spend := fake_add_budget(&rt, {.Read, .Commit}, min_pages, 1, min_time)
	testing.expect_value(t, service_connect_client(&service, 1, no_spend, min_pages, min_time, 1, &err), work_budget.Work_Budget_Refusal.Missing_Spend_Right)

	// Zero objects leaked and service own budget never touched.
	mems, maps, ths := fake_live_counts(&rt)
	testing.expect_value(t, mems, 0)
	testing.expect_value(t, maps, 0)
	testing.expect_value(t, ths, 0)
	testing.expect(t, !rt.service_budget_touched, "service own budget must never be charged")
}

@(test)
spend_only_child_budgets_isolate_exhaustion_and_never_charge_service :: proc(t: ^testing.T) {
	rt: Fake_Kernel_Runtime
	fake_init(&rt)

	service: Accounted_Service
	testing.expect_value(t, service_init(&service, PROBE_REQUIREMENTS, rt.service_own_budget, fake_ops(&rt)), work_budget.Work_Budget_Refusal.None)

	amounts_a, ok_a := work_budget.work_budget_child_amounts(PROBE_REQUIREMENTS, 0)
	amounts_b, ok_b := work_budget.work_budget_child_amounts(PROBE_REQUIREMENTS, 32)
	testing.expect(t, ok_a && ok_b, "child amounts must compute cleanly")

	// Both clients pass Spend-only handles (no Read, no Give).
	budget_a := fake_add_budget(&rt, {.Spend}, amounts_a.pages, amounts_a.threads, amounts_a.processor)
	budget_b := fake_add_budget(&rt, {.Spend}, amounts_b.pages, amounts_b.threads, amounts_b.processor)

	testing.expect_value(t, service_connect_client(&service, 1, budget_a, amounts_a.pages, amounts_a.processor, amounts_a.threads), work_budget.Work_Budget_Refusal.None)
	testing.expect_value(t, service_connect_client(&service, 2, budget_b, amounts_b.pages, amounts_b.processor, amounts_b.threads), work_budget.Work_Budget_Refusal.None)

	// Client 1 requests 16 scratch pages, exceeding its tight work budget -> Exhausted!
	err_a: errors.Error_Record
	testing.expect_value(t, connection_worker_execute_request(&service, 1, 16, 32, &err_a), work_budget.Work_Budget_Refusal.Budget_Exhausted)
	testing.expect_value(t, err_a.kind, i64(errors.Kind.Budget))

	snap_a, _ := work_budget.connection_snapshot(&service.table, 1)
	testing.expect_value(t, snap_a.state, work_budget.Work_Account_State.Exhausted)
	testing.expect_value(t, snap_a.exhaustion_count, u64(1))

	// Client 2 keeps executing requests and committing pages cleanly on its own budget.
	for _ in 0 ..< 4 {
		testing.expect_value(t, connection_worker_execute_request(&service, 2, 4, 64), work_budget.Work_Budget_Refusal.None)
	}
	snap_b, _ := work_budget.connection_snapshot(&service.table, 2)
	testing.expect_value(t, snap_b.state, work_budget.Work_Account_State.Active)
	testing.expect_value(t, snap_b.requests_served, u64(4))
	testing.expect(t, snap_b.processor_nanoseconds > 0, "client 2 must record non-zero processor nanoseconds")

	// Revoking client 1 and closing client 2 returns every page and thread slot cleanly.
	revoked_a, rev_refusal := service_revoke_client(&service, 1)
	testing.expect_value(t, rev_refusal, work_budget.Work_Budget_Refusal.None)
	testing.expect_value(t, revoked_a.state, work_budget.Work_Account_State.Revoked)

	closed_b, close_refusal := service_disconnect_client(&service, 2)
	testing.expect_value(t, close_refusal, work_budget.Work_Budget_Refusal.None)
	testing.expect_value(t, closed_b.state, work_budget.Work_Account_State.Closed)

	mems, maps, ths := fake_live_counts(&rt)
	testing.expect_value(t, mems, 0)
	testing.expect_value(t, maps, 0)
	testing.expect_value(t, ths, 0)
	testing.expect(t, !rt.service_budget_touched, "service own budget must never be charged")

	// Verify both child budgets regained all pages and thread slots after teardown.
	fb_a := fake_find_budget(&rt, budget_a)
	fb_b := fake_find_budget(&rt, budget_b)
	testing.expect_value(t, fb_a.pages_remaining, fb_a.pages_initial)
	testing.expect_value(t, fb_a.threads_remaining, fb_a.threads_initial)
	testing.expect_value(t, fb_b.pages_remaining, fb_b.pages_initial)
	testing.expect_value(t, fb_b.threads_remaining, fb_b.threads_initial)
}

@(test)
partial_connect_failure_rolls_back_and_mid_call_revocation_reclaims :: proc(t: ^testing.T) {
	rt: Fake_Kernel_Runtime
	fake_init(&rt)

	service: Accounted_Service
	testing.expect_value(t, service_init(&service, PROBE_REQUIREMENTS, rt.service_own_budget, fake_ops(&rt)), work_budget.Work_Budget_Refusal.None)

	amounts, _ := work_budget.work_budget_child_amounts(PROBE_REQUIREMENTS, 16)
	budget_1 := fake_add_budget(&rt, {.Spend}, amounts.pages, amounts.threads, amounts.processor)

	// Inject Thread_Create No_Budget failure after stack and scratch succeed:
	// verify stack and scratch are rolled back with zero leaks.
	rt.force_thread_create_fail = .No_Budget
	testing.expect_value(t, service_connect_client(&service, 1, budget_1, amounts.pages, amounts.processor, amounts.threads), work_budget.Work_Budget_Refusal.Missing_Thread_Slot)

	mems, maps, ths := fake_live_counts(&rt)
	testing.expect_value(t, mems, 0)
	testing.expect_value(t, maps, 0)
	testing.expect_value(t, ths, 0)
	testing.expect_value(t, work_budget.table_occupied_count(&service.table), 0)
	fb1 := fake_find_budget(&rt, budget_1)
	testing.expect_value(t, fb1.pages_remaining, fb1.pages_initial)

	// Reconnect cleanly, then revoke the kernel budget handle before a scratch commit.
	testing.expect_value(t, service_connect_client(&service, 1, budget_1, amounts.pages, amounts.processor, amounts.threads), work_budget.Work_Budget_Refusal.None)
	fb1.revoked = true
	testing.expect_value(t, connection_worker_execute_request(&service, 1, 2, 16), work_budget.Work_Budget_Refusal.Budget_Revoked)
	testing.expect_value(t, work_budget.table_occupied_count(&service.table), 0)

	mems, maps, ths = fake_live_counts(&rt)
	testing.expect_value(t, mems, 0)
	testing.expect_value(t, maps, 0)
	testing.expect_value(t, ths, 0)
	testing.expect(t, !rt.service_budget_touched, "service own budget must never be charged")
	testing.expect_value(t, work_budget_contract_version(), i64(work_budget.ACCOUNTING_SNAPSHOT_VERSION))
}

@(test)
overstated_client_budget_and_service_capacity_bound :: proc(t: ^testing.T) {
	rt: Fake_Kernel_Runtime
	fake_init(&rt)

	service: Accounted_Service
	testing.expect_value(t, service_init(&service, PROBE_REQUIREMENTS, rt.service_own_budget, fake_ops(&rt)), work_budget.Work_Budget_Refusal.None)

	min_pages, _ := work_budget.work_budget_minimum_pages(PROBE_REQUIREMENTS)
	min_time := PROBE_REQUIREMENTS.minimum_processor_microseconds

	// Readable budget whose true pages are below minimum: client lies and claims
	// min_pages, service reads authoritative kernel amounts and refuses.
	short_readable := fake_add_budget(&rt, {.Spend, .Read}, min_pages - 1, 1, min_time)
	testing.expect_value(t, service_connect_client(&service, 1, short_readable, min_pages, min_time, 1), work_budget.Work_Budget_Refusal.Too_Few_Pages)

	// Spend-only budget that holds just enough for stack + thread area + list
	// page (21 pages) while client overstates offered_pages = min_pages:
	// first scratch commit hits kernel No_Budget and exhausts ONLY this client.
	tight_spend_only := fake_add_budget(&rt, {.Spend}, 22, 1, min_time)
	testing.expect_value(t, service_connect_client(&service, 2, tight_spend_only, min_pages, min_time, 1), work_budget.Work_Budget_Refusal.None)
	testing.expect_value(t, connection_worker_execute_request(&service, 2, 4, 8), work_budget.Work_Budget_Refusal.Budget_Exhausted)
	snap2, _ := work_budget.connection_snapshot(&service.table, 2)
	testing.expect_value(t, snap2.state, work_budget.Work_Account_State.Exhausted)
	_, _ = service_disconnect_client(&service, 2)

	// Capacity bound: MAX_ACCOUNTED_CONNECTIONS succeed, +1 refused, then
	// revoking one allows the +1 client to connect cleanly.
	amounts, _ := work_budget.work_budget_child_amounts(PROBE_REQUIREMENTS, 0)
	for i in 1 ..= work_budget.MAX_ACCOUNTED_CONNECTIONS {
		b := fake_add_budget(&rt, {.Spend}, amounts.pages, amounts.threads, amounts.processor)
		testing.expect_value(t, service_connect_client(&service, u64(10 + i), b, amounts.pages, amounts.processor, amounts.threads), work_budget.Work_Budget_Refusal.None)
	}
	overflow_budget := fake_add_budget(&rt, {.Spend}, amounts.pages, amounts.threads, amounts.processor)
	testing.expect_value(t, service_connect_client(&service, 99, overflow_budget, amounts.pages, amounts.processor, amounts.threads), work_budget.Work_Budget_Refusal.Too_Many_Connections)
	testing.expect_value(t, work_budget.table_occupied_count(&service.table), work_budget.MAX_ACCOUNTED_CONNECTIONS)

	_, rev_refusal := service_revoke_client(&service, 11)
	testing.expect_value(t, rev_refusal, work_budget.Work_Budget_Refusal.None)
	testing.expect_value(t, service_connect_client(&service, 99, overflow_budget, amounts.pages, amounts.processor, amounts.threads), work_budget.Work_Budget_Refusal.None)

	// Clean up all remaining connections and verify zero leaks.
	for i in 2 ..= work_budget.MAX_ACCOUNTED_CONNECTIONS {
		_, _ = service_disconnect_client(&service, u64(10 + i))
	}
	_, _ = service_disconnect_client(&service, 99)

	mems, maps, ths := fake_live_counts(&rt)
	testing.expect_value(t, mems, 0)
	testing.expect_value(t, maps, 0)
	testing.expect_value(t, ths, 0)
	testing.expect(t, !rt.service_budget_touched, "service own budget must never be charged")
}
