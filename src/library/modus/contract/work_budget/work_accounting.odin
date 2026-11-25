// Sibling-isolated processor-time budgets, per-client service work accounting,
// bounded lowest-step-debt scheduling, and process work report rows
// (src/md/features/work_accounting.md, src/md/features/log_side_channels.md).
//
// Extends `modus:contract/work_budget` without duplicating the package:
// freestanding, zero kernel calls, zero host imports, and zero heap allocation.
package work_budget

import "modus:contract/enum_word"
import "modus:contract/isolated"

// Plan value: matches the maximum concurrent connections held by one shared
// service so every connected client owns one accounting slot.
SERVICE_WORK_CAPACITY :: isolated.SERVICE_CONNECTION_CAPACITY

// Plan value: matches SERVICE_WORK_CAPACITY so every connected client can
// queue a pending shared step in the step-debt scheduler.
STEP_DEBT_CAPACITY :: isolated.SERVICE_CONNECTION_CAPACITY

// Format property: 32-byte module/service name buffer matching system reports.
SERVICE_NAME_CAPACITY :: 32

// Plan value: 100 ms budget period in microseconds matching kernel accounting.
PROCESSOR_PERIOD_MICROSECONDS :: u64(100_000)

// Closed set of refusals for processor-time division, client work charging,
// step-debt scheduling, and report row construction. Explicit values cross
// transport borders.
Work_Accounting_Refusal :: enum u8 {
	None                 = 0,
	Bad_Value            = 1,
	Insufficient_Budget  = 2,
	Period_Exhausted     = 3,
	Pages_Exceeded       = 4,
	Capacity_Full        = 5,
	Duplicate_Connection = 6,
	Not_Found            = 7,
	Queue_Empty          = 8,
	Overflow             = 9,
}

// Exclusive processor-time budget for one process or child hierarchy.
// Dividing to a child moves both allowance_us and any overflowing part of
// used_us for the current period so siblings never share a limit and one
// sibling exhausting its share cannot reduce or signal into another sibling.
Processor_Time_Budget :: struct {
	allowance_us: u64,
	used_us:      u64,
	total_us:     u64,
	period_index: u64,
}

// Per-connection memory, processor time, and shared-step debt tracked by a
// shared service for one client.
Client_Work_Snapshot :: struct {
	connection_id:            u64,
	pages_used:               u64,
	pages_limit:              u64,
	pages_peak:               u64,
	processor_last_period_us: u64,
	processor_total_us:       u64,
	step_debt_ns:             u64,
	period_index:             u64,
	active:                   bool,
}

// Fixed-capacity table holding Client_Work_Snapshot entries for one service.
Service_Work_Table :: struct {
	slots: [SERVICE_WORK_CAPACITY]Client_Work_Snapshot,
	count: int,
}

// One client entry tracked by Step_Debt_Scheduler.
Step_Debt_Entry :: struct {
	connection_id: u64,
	step_debt_ns:  u64,
	enqueue_order: u64,
	waiting:       bool,
	occupied:      bool,
}

// Bounded fair scheduler for shared steps of a service: always selects the
// waiting client with the lowest step_debt_ns, breaking exact ties by earliest
// enqueue_order and then lowest connection_id.
Step_Debt_Scheduler :: struct {
	entries:       [STEP_DEBT_CAPACITY]Step_Debt_Entry,
	count:         int,
	next_sequence: u64,
}

// One row of `work(process)` showing what a shared service spent for a client
// connection.
Process_Work_Report_Row :: struct {
	service_name:             [SERVICE_NAME_CAPACITY]u8,
	service_name_length:      u8,
	connection_id:            u64,
	pages_used:               u64,
	pages_limit:              u64,
	processor_last_period_us: u64,
	processor_total_us:       u64,
	step_debt_ns:             u64,
}

// work_accounting_refusal_of_word converts a raw word into
// Work_Accounting_Refusal at a border, refusing any unknown value.
work_accounting_refusal_of_word :: proc "contextless" (word: u64) -> (refusal: Work_Accounting_Refusal, ok: bool) {
	return enum_word.member_of_word(Work_Accounting_Refusal, word)
}

// processor_budget_init creates an exclusive processor-time budget with
// allowance_us microseconds per period starting at period_index.
processor_budget_init :: proc "contextless" (allowance_us: u64, period_index: u64 = 0) -> Processor_Time_Budget {
	return Processor_Time_Budget {
		allowance_us = allowance_us,
		used_us      = 0,
		total_us     = 0,
		period_index = period_index,
	}
}

// processor_budget_remaining returns the unused microseconds remaining in the
// current period of b.
processor_budget_remaining :: proc "contextless" (b: Processor_Time_Budget) -> u64 {
	if b.used_us >= b.allowance_us {
		return 0
	}
	return b.allowance_us - b.used_us
}

// processor_budget_advance_period advances b to new_period, resetting used_us
// when new_period > b.period_index. Refuses nil or backward period jumps.
processor_budget_advance_period :: proc "contextless" (b: ^Processor_Time_Budget, new_period: u64) -> Work_Accounting_Refusal {
	if b == nil || new_period < b.period_index {
		return .Bad_Value
	}
	if new_period > b.period_index {
		b.used_us = 0
		b.period_index = new_period
	}
	return .None
}

// divide_to_child carves an exclusive share_us allowance out of parent into a
// new child budget. Any portion of parent.used_us that exceeds parent's
// reduced allowance moves to child.used_us so creating and stopping children in
// a loop cannot mint extra processor time within one period. Once divided,
// child consumption never affects parent or any sibling budget.
divide_to_child :: proc "contextless" (parent: ^Processor_Time_Budget, share_us: u64) -> (child: Processor_Time_Budget, refusal: Work_Accounting_Refusal) {
	if parent == nil || share_us == 0 {
		return {}, .Bad_Value
	}
	if parent.used_us > parent.allowance_us {
		return {}, .Bad_Value
	}
	if share_us > parent.allowance_us {
		return {}, .Insufficient_Budget
	}
	new_parent_allowance := parent.allowance_us - share_us
	moved_used: u64 = 0
	if parent.used_us > new_parent_allowance {
		moved_used = parent.used_us - new_parent_allowance
	}
	parent.allowance_us = new_parent_allowance
	parent.used_us -= moved_used
	return Processor_Time_Budget {
		allowance_us = share_us,
		used_us      = moved_used,
		total_us     = 0,
		period_index = parent.period_index,
	}, .None
}

// reclaim_from_child returns child's allowance_us (and current-period used_us
// when in the same period) back to parent when the child budget closes.
// Refuses nil, self-reclaim, or overflow without mutating either budget.
reclaim_from_child :: proc "contextless" (parent: ^Processor_Time_Budget, child: ^Processor_Time_Budget) -> Work_Accounting_Refusal {
	if parent == nil || child == nil || parent == child {
		return .Bad_Value
	}
	if parent.allowance_us > max(u64) - child.allowance_us {
		return .Overflow
	}
	returned_used := child.period_index == parent.period_index ? child.used_us : u64(0)
	if parent.used_us > max(u64) - returned_used {
		return .Overflow
	}
	parent.allowance_us += child.allowance_us
	parent.used_us += returned_used
	child.allowance_us = 0
	child.used_us = 0
	return .None
}

// charge_period charges elapsed_us against b in current_period, rolling over
// used_us when current_period advances. Refuses nil, backward period jumps,
// period exhaustion, or total_us overflow without mutating b.
charge_period :: proc "contextless" (b: ^Processor_Time_Budget, elapsed_us: u64, current_period: u64) -> Work_Accounting_Refusal {
	if b == nil || current_period < b.period_index {
		return .Bad_Value
	}
	base_used := current_period > b.period_index ? u64(0) : b.used_us
	if base_used > b.allowance_us || elapsed_us > b.allowance_us - base_used {
		return .Period_Exhausted
	}
	if b.total_us > max(u64) - elapsed_us {
		return .Overflow
	}
	b.period_index = current_period
	b.used_us = base_used + elapsed_us
	b.total_us += elapsed_us
	return .None
}

// service_work_register opens one accounting slot for connection_id with a
// non-zero pages_limit. Refuses invalid inputs, duplicates, or a full table
// without mutating table.
service_work_register :: proc "contextless" (
	table: ^Service_Work_Table,
	connection_id: u64,
	pages_limit: u64,
	initial_step_debt_ns: u64 = 0,
	period_index: u64 = 0,
) -> Work_Accounting_Refusal {
	if table == nil || connection_id == 0 || pages_limit == 0 {
		return .Bad_Value
	}
	free_slot := -1
	for &slot, i in table.slots {
		if slot.active {
			if slot.connection_id == connection_id {
				return .Duplicate_Connection
			}
		} else if free_slot < 0 {
			free_slot = i
		}
	}
	if free_slot < 0 {
		return .Capacity_Full
	}
	table.slots[free_slot] = Client_Work_Snapshot {
		connection_id = connection_id,
		pages_limit   = pages_limit,
		step_debt_ns  = initial_step_debt_ns,
		period_index  = period_index,
		active        = true,
	}
	table.count += 1
	return .None
}

// service_work_remove closes the accounting slot of connection_id.
service_work_remove :: proc "contextless" (table: ^Service_Work_Table, connection_id: u64) -> Work_Accounting_Refusal {
	if table == nil || connection_id == 0 {
		return .Bad_Value
	}
	for &slot in table.slots {
		if slot.active && slot.connection_id == connection_id {
			slot = {}
			if table.count > 0 {
				table.count -= 1
			}
			return .None
		}
	}
	return .Not_Found
}

// charge_client_pages_and_time atomically applies a signed page_delta and
// elapsed_us processor time to connection_id in current_period. On any refusal
// (pages over limit, negative underflow, backward period, or u64 overflow),
// neither pages nor time is modified.
charge_client_pages_and_time :: proc "contextless" (
	table: ^Service_Work_Table,
	connection_id: u64,
	page_delta: i64,
	elapsed_us: u64,
	current_period: u64,
) -> Work_Accounting_Refusal {
	if table == nil || connection_id == 0 {
		return .Bad_Value
	}
	target: ^Client_Work_Snapshot
	for &slot in table.slots {
		if slot.active && slot.connection_id == connection_id {
			target = &slot
			break
		}
	}
	if target == nil {
		return .Not_Found
	}
	if current_period < target.period_index {
		return .Bad_Value
	}
	new_pages: u64
	if page_delta >= 0 {
		add := u64(page_delta)
		if target.pages_used > target.pages_limit || add > target.pages_limit - target.pages_used {
			return .Pages_Exceeded
		}
		new_pages = target.pages_used + add
	} else {
		if page_delta == min(i64) {
			return .Bad_Value
		}
		sub := u64(-page_delta)
		if sub > target.pages_used {
			return .Bad_Value
		}
		new_pages = target.pages_used - sub
	}
	base_period_us := current_period > target.period_index ? u64(0) : target.processor_last_period_us
	if base_period_us > max(u64) - elapsed_us || target.processor_total_us > max(u64) - elapsed_us {
		return .Overflow
	}
	target.pages_used = new_pages
	if new_pages > target.pages_peak {
		target.pages_peak = new_pages
	}
	target.period_index = current_period
	target.processor_last_period_us = base_period_us + elapsed_us
	target.processor_total_us += elapsed_us
	return .None
}

// service_work_set_step_debt updates the cached step_debt_ns reported in
// Client_Work_Snapshot for connection_id.
service_work_set_step_debt :: proc "contextless" (table: ^Service_Work_Table, connection_id: u64, step_debt_ns: u64) -> Work_Accounting_Refusal {
	if table == nil || connection_id == 0 {
		return .Bad_Value
	}
	for &slot in table.slots {
		if slot.active && slot.connection_id == connection_id {
			slot.step_debt_ns = step_debt_ns
			return .None
		}
	}
	return .Not_Found
}

// service_work_snapshot returns a copy of the accounting snapshot for
// connection_id.
service_work_snapshot :: proc "contextless" (table: ^Service_Work_Table, connection_id: u64) -> (snap: Client_Work_Snapshot, refusal: Work_Accounting_Refusal) {
	if table == nil || connection_id == 0 {
		return {}, .Bad_Value
	}
	for slot in table.slots {
		if slot.active && slot.connection_id == connection_id {
			return slot, .None
		}
	}
	return {}, .Not_Found
}

// step_debt_min_waiting returns the lowest step_debt_ns among all currently
// waiting connections, or (0, false) when no connection waits.
step_debt_min_waiting :: proc "contextless" (sched: ^Step_Debt_Scheduler) -> (min_debt: u64, has_waiting: bool) {
	if sched == nil {
		return 0, false
	}
	for entry in sched.entries {
		if !entry.occupied || !entry.waiting {
			continue
		}
		if !has_waiting || entry.step_debt_ns < min_debt {
			min_debt = entry.step_debt_ns
			has_waiting = true
		}
	}
	return min_debt, has_waiting
}

// step_debt_register adds connection_id to sched, initializing its step debt
// to the current floor of waiting connections so newly joined clients neither
// starve active clients nor lag behind them.
step_debt_register :: proc "contextless" (sched: ^Step_Debt_Scheduler, connection_id: u64) -> Work_Accounting_Refusal {
	if sched == nil || connection_id == 0 {
		return .Bad_Value
	}
	free_slot := -1
	for &entry, i in sched.entries {
		if entry.occupied {
			if entry.connection_id == connection_id {
				return .Duplicate_Connection
			}
		} else if free_slot < 0 {
			free_slot = i
		}
	}
	if free_slot < 0 {
		return .Capacity_Full
	}
	floor, _ := step_debt_min_waiting(sched)
	sched.entries[free_slot] = Step_Debt_Entry {
		connection_id = connection_id,
		step_debt_ns  = floor,
		enqueue_order = 0,
		waiting       = false,
		occupied      = true,
	}
	sched.count += 1
	return .None
}

// step_debt_remove deletes connection_id from sched.
step_debt_remove :: proc "contextless" (sched: ^Step_Debt_Scheduler, connection_id: u64) -> Work_Accounting_Refusal {
	if sched == nil || connection_id == 0 {
		return .Bad_Value
	}
	for &entry in sched.entries {
		if entry.occupied && entry.connection_id == connection_id {
			entry = {}
			if sched.count > 0 {
				sched.count -= 1
			}
			return .None
		}
	}
	return .Not_Found
}

// step_debt_mark_waiting marks connection_id as having a shared step ready.
// Lifts an idle client's step_debt_ns up to the current waiting floor so long
// idle time cannot accumulate credit to starve active clients.
step_debt_mark_waiting :: proc "contextless" (sched: ^Step_Debt_Scheduler, connection_id: u64) -> Work_Accounting_Refusal {
	if sched == nil || connection_id == 0 {
		return .Bad_Value
	}
	floor, has_waiting := step_debt_min_waiting(sched)
	for &entry in sched.entries {
		if entry.occupied && entry.connection_id == connection_id {
			if !entry.waiting {
				if has_waiting && entry.step_debt_ns < floor {
					entry.step_debt_ns = floor
				}
				sched.next_sequence += 1
				entry.enqueue_order = sched.next_sequence
				entry.waiting = true
			}
			return .None
		}
	}
	return .Not_Found
}

// next_client_by_lowest_step_debt pops and returns the waiting connection with
// the lowest step_debt_ns. Ties break deterministically by lowest
// enqueue_order, then lowest connection_id.
next_client_by_lowest_step_debt :: proc "contextless" (sched: ^Step_Debt_Scheduler) -> (connection_id: u64, refusal: Work_Accounting_Refusal) {
	if sched == nil {
		return 0, .Bad_Value
	}
	best_index := -1
	for entry, i in sched.entries {
		if !entry.occupied || !entry.waiting {
			continue
		}
		if best_index < 0 {
			best_index = i
			continue
		}
		best := sched.entries[best_index]
		if entry.step_debt_ns < best.step_debt_ns ||
		   (entry.step_debt_ns == best.step_debt_ns && entry.enqueue_order < best.enqueue_order) ||
		   (entry.step_debt_ns == best.step_debt_ns && entry.enqueue_order == best.enqueue_order && entry.connection_id < best.connection_id) {
			best_index = i
		}
	}
	if best_index < 0 {
		return 0, .Queue_Empty
	}
	sched.entries[best_index].waiting = false
	return sched.entries[best_index].connection_id, .None
}

// step_debt_record_duration adds a measured shared-step duration in
// nanoseconds to connection_id. Refuses overflow without mutating the entry.
step_debt_record_duration :: proc "contextless" (sched: ^Step_Debt_Scheduler, connection_id: u64, step_duration_ns: u64) -> Work_Accounting_Refusal {
	if sched == nil || connection_id == 0 {
		return .Bad_Value
	}
	for &entry in sched.entries {
		if entry.occupied && entry.connection_id == connection_id {
			if entry.step_debt_ns > max(u64) - step_duration_ns {
				return .Overflow
			}
			entry.step_debt_ns += step_duration_ns
			return .None
		}
	}
	return .Not_Found
}

// process_work_report_row_of builds a typed `work(process)` report row from a
// service name and an active Client_Work_Snapshot. Refuses empty or oversized
// service names, inactive snapshots, or zero connection IDs.
process_work_report_row_of :: proc "contextless" (service_name: string, snap: Client_Work_Snapshot) -> (row: Process_Work_Report_Row, refusal: Work_Accounting_Refusal) {
	if len(service_name) == 0 || len(service_name) > SERVICE_NAME_CAPACITY {
		return {}, .Bad_Value
	}
	if !snap.active || snap.connection_id == 0 {
		return {}, .Bad_Value
	}
	copy(row.service_name[:], service_name)
	row.service_name_length = u8(len(service_name))
	row.connection_id = snap.connection_id
	row.pages_used = snap.pages_used
	row.pages_limit = snap.pages_limit
	row.processor_last_period_us = snap.processor_last_period_us
	row.processor_total_us = snap.processor_total_us
	row.step_debt_ns = snap.step_debt_ns
	return row, .None
}

// process_work_report_service_name returns the validated service name slice of
// row, clamped to SERVICE_NAME_CAPACITY.
process_work_report_service_name :: proc "contextless" (row: ^Process_Work_Report_Row) -> string {
	if row == nil {
		return ""
	}
	n := min(int(row.service_name_length), SERVICE_NAME_CAPACITY)
	return string(row.service_name[:n])
}
