// Work accounting contract: client-funded work budgets, per-connection work
// thread accounting, and border validation (src/md/features/work_accounting.md).
//
// A shared service never pays for client work from its own budget. Each client
// connection carries a child work budget with the right Spend, sized from the
// service's declared Work_Budget_Requirements. The service creates one work
// thread and all per-connection working state on that budget so memory pages
// and processor time count strictly against the client.
//
// This is a contract package: it imports base packages and contract packages
// only, calls no kernel operation, and allocates no memory.
package work_budget

import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/isolated"
import op "modus:contract/operation"
import "modus:contract/ring"

// Maximum simultaneous accounted client connections held by one service.
// Matches the service connection table capacity.
MAX_ACCOUNTED_CONNECTIONS :: isolated.SERVICE_CONNECTION_CAPACITY

// Pages paid from a work budget for one thread area: one page for the thread
// record and two pages for the kernel ring. The fourth page is an unbacked
// guard page.
WORK_THREAD_AREA_PAGES :: u64(op.THREAD_AREA_PAGES - 1)

// Default stack size for a connection work thread, in 4096-byte pages.
WORK_THREAD_DEFAULT_STACK_PAGES :: u64(op.THREAD_STACK_PAGES)

// Pages for one connection page shared with the starter and client.
CONNECTION_PAGE_PAGES :: u64(1)

// Default pages for one connection's call ring, call region, and connection page.
DEFAULT_RING_AND_REGION_PAGES :: u64(ring.PAGE_COUNT + isolated.REGION_PAGES + CONNECTION_PAGE_PAGES)

// The one kernel right a service requires on a client's work budget handle.
// The service cannot transfer the budget (no Give) and cannot inspect the
// client's parent budget.
WORK_BUDGET_REQUIRED_RIGHTS :: op.Rights{.Spend}

// Largest page count accepted by a work budget contract record, bounded by the
// kernel memory object page limit so page arithmetic never overflows.
MAX_WORK_BUDGET_PAGES :: op.MEMORY_PAGE_LIMIT

// Largest processor time limit accepted in a work budget requirement or
// snapshot: microseconds of processor time per second across up to 64 cores.
MAX_PROCESSOR_MICROSECONDS_PER_SECOND :: u64(64_000_000)

// Format version of Accounting_Snapshot_Record.
ACCOUNTING_SNAPSHOT_VERSION :: u32(1)

// Closed lifecycle state of one client's work account inside a service.
// Explicit values cross transport borders; zero names no state and is refused.
Work_Account_State :: enum u64 {
	Inactive  = 1, // Slot opened and budget checked; work thread not yet active.
	Active    = 2, // Work thread runs on the client's work budget.
	Exhausted = 3, // Client budget ran out of pages or processor time; sibling clients continue.
	Revoked   = 4, // Client budget or connection was revoked; work thread stopped and slot reclaimed.
	Closed    = 5, // Connection closed cleanly; all client resources returned.
}

// Closed set of reasons why a work budget check or state transition refused an
// operation. Explicit values cross transport borders.
Work_Budget_Refusal :: enum u64 {
	None                 = 0,
	Missing_Spend_Right  = 1,
	Too_Few_Pages        = 2,
	Too_Little_Time      = 3,
	Missing_Thread_Slot  = 4,
	Budget_Revoked       = 5,
	Budget_Exhausted     = 6,
	Too_Many_Connections = 7,
	Duplicate_Connection = 8,
	Invalid_State        = 9,
}

// Budget requirements declared by a service contract so a client or starter can
// create an exact child work budget with Spend right only.
Work_Budget_Requirements :: struct {
	stack_pages:                    u64, // Stack pages for the connection work thread (at least 1).
	scratch_pages:                  u64, // Minimum working-state pages for the connection (tables, arenas, scratch).
	ring_pages:                     u64, // Pages for the call ring, call region, and connection page.
	minimum_processor_microseconds: u64, // Minimum processor time limit in microseconds per second (at least 1).
	maximum_pages:                  u64, // Optional upper page limit accepted per connection (0: MAX_WORK_BUDGET_PAGES).
}

// Live accounting state held by a service for one client connection.
Client_Work_Account :: struct {
	connection_identifier:        u64,
	client_budget_handle:         op.Handle,
	work_thread_handle:           op.Handle,
	state:                        Work_Account_State,
	pages_limit:                  u64,
	pages_charged:                u64,
	pages_peak:                   u64,
	processor_limit_microseconds: u64,
	processor_nanoseconds:        u64,
	step_debt_nanoseconds:        u64,
	requests_served:              u64,
	exhaustion_count:             u64,
	in_flight_request:            bool,
}

// Validated snapshot of one client connection's work accounting.
Accounting_Snapshot :: struct {
	connection_identifier:        u64,
	state:                        Work_Account_State,
	pages_limit:                  u64,
	pages_charged:                u64,
	pages_peak:                   u64,
	processor_limit_microseconds: u64,
	processor_nanoseconds:        u64,
	step_debt_nanoseconds:        u64,
	requests_served:              u64,
	exhaustion_count:             u64,
}

// Fixed-layout transport form of Accounting_Snapshot. Untrusted readers decode
// state_word through accounting_snapshot_decode so unknown state words never
// enter typed code.
Accounting_Snapshot_Record :: struct {
	version:                      u64,
	connection_identifier:        u64,
	state_word:                   u64,
	pages_limit:                  u64,
	pages_charged:                u64,
	pages_peak:                   u64,
	processor_limit_microseconds: u64,
	processor_nanoseconds:        u64,
	step_debt_nanoseconds:        u64,
	requests_served:              u64,
	exhaustion_count:             u64,
}
#assert(size_of(Accounting_Snapshot_Record) == 88)

// One slot in Connection_Worker_Table.
Connection_Worker_Slot :: struct {
	occupied: bool,
	account:  Client_Work_Account,
}

// Fixed-capacity pure state machine tracking one work thread and one work
// budget per client connection.
Connection_Worker_Table :: struct {
	initialized:           bool,
	requirements:          Work_Budget_Requirements,
	service_own_budget:    op.Handle, // Never accepted as a client work budget.
	slots:                 [MAX_ACCOUNTED_CONNECTIONS]Connection_Worker_Slot,
	occupied_count:        int,
	revoked_ring:          [MAX_ACCOUNTED_CONNECTIONS]u64,
	revoked_ring_cursor:   int,
	revoked_total:         u64,
	closed_total:          u64,
}

// work_account_state_from_word converts a transport word into a
// Work_Account_State, refusing zero and every value outside the closed enum.
work_account_state_from_word :: proc "contextless" (word: u64) -> (state: Work_Account_State, ok: bool) {
	return enum_word.member_of_word(Work_Account_State, word)
}

// work_budget_refusal_from_word converts a transport word into a
// Work_Budget_Refusal, refusing every value outside the closed enum.
work_budget_refusal_from_word :: proc "contextless" (word: u64) -> (refusal: Work_Budget_Refusal, ok: bool) {
	return enum_word.member_of_word(Work_Budget_Refusal, word)
}

// work_budget_refusal_to_error_record maps a closed Work_Budget_Refusal to a
// standard kernel/service error record for reporting across isolated calls.
work_budget_refusal_to_error_record :: proc "contextless" (refusal: Work_Budget_Refusal, argument: i64 = 0, value: i64 = 0, limit: i64 = 0, found: i64 = 0) -> errors.Error_Record {
	switch refusal {
	case .None:
		return {}
	case .Missing_Spend_Right:
		return errors.error_make(.Handle_Rights, .Budgets, argument, value, i64(transmute(u32)WORK_BUDGET_REQUIRED_RIGHTS), found)
	case .Too_Few_Pages:
		return errors.error_make(.Budget, .Pages, argument, value, limit, found)
	case .Too_Little_Time:
		return errors.error_make(.Budget, .Processor, argument, value, limit, found)
	case .Missing_Thread_Slot:
		return errors.error_make(.Budget, .Threads, argument, value, limit, found)
	case .Budget_Revoked:
		return errors.error_make(.Handle_Ended, .Budgets, argument, value, limit, i64(errors.End.Revoked))
	case .Budget_Exhausted:
		return errors.error_make(.Budget, .Pages, argument, value, limit, found)
	case .Too_Many_Connections:
		return errors.error_make(.Full, .Connections, argument, value, i64(MAX_ACCOUNTED_CONNECTIONS), found)
	case .Duplicate_Connection:
		return errors.error_make(.Exists, .Connections, argument, value, limit, found)
	case .Invalid_State:
		return errors.error_make(.State, .Connections, argument, value, limit, found)
	}
	return errors.error_make(.State, .Connections, argument, value, limit, found)
}

// checked_add_u64 adds two unsigned 64-bit values without wrapping.
@(private = "file")
checked_add_u64 :: proc "contextless" (left, right: u64) -> (sum: u64, ok: bool) {
	if right > max(u64) - left {
		return 0, false
	}
	return left + right, true
}

// work_budget_base_pages returns the exact pages paid at connection setup for
// the work thread stack (including its frame list), the thread area, and the
// connection's ring and region pages.
work_budget_base_pages :: proc "contextless" (requirements: Work_Budget_Requirements) -> (pages: u64, ok: bool) {
	if requirements.stack_pages == 0 || requirements.stack_pages > MAX_WORK_BUDGET_PAGES {
		return 0, false
	}
	if requirements.ring_pages > MAX_WORK_BUDGET_PAGES {
		return 0, false
	}
	stack_cost := op.memory_cost(requirements.stack_pages)
	if stack_cost == max(u64) || stack_cost > MAX_WORK_BUDGET_PAGES {
		return 0, false
	}
	total := checked_add_u64(stack_cost, WORK_THREAD_AREA_PAGES) or_return
	total = checked_add_u64(total, requirements.ring_pages) or_return
	if total > MAX_WORK_BUDGET_PAGES {
		return 0, false
	}
	return total, true
}

// work_budget_minimum_pages returns the minimum total pages a client work
// budget must hold: base thread and ring pages plus the minimum scratch pages
// and their frame list cost.
work_budget_minimum_pages :: proc "contextless" (requirements: Work_Budget_Requirements) -> (pages: u64, ok: bool) {
	if requirements.scratch_pages > MAX_WORK_BUDGET_PAGES {
		return 0, false
	}
	if requirements.minimum_processor_microseconds == 0 || requirements.minimum_processor_microseconds > MAX_PROCESSOR_MICROSECONDS_PER_SECOND {
		return 0, false
	}
	base := work_budget_base_pages(requirements) or_return
	scratch_cost := requirements.scratch_pages == 0 ? u64(0) : op.memory_cost(requirements.scratch_pages)
	if scratch_cost == max(u64) || scratch_cost > MAX_WORK_BUDGET_PAGES {
		return 0, false
	}
	total := checked_add_u64(base, scratch_cost) or_return
	if total > MAX_WORK_BUDGET_PAGES {
		return 0, false
	}
	if requirements.maximum_pages != 0 {
		if requirements.maximum_pages > MAX_WORK_BUDGET_PAGES || requirements.maximum_pages < total {
			return 0, false
		}
	}
	return total, true
}

// work_budget_requirements_valid reports whether requirements is self-consistent
// and within kernel limits.
work_budget_requirements_valid :: proc "contextless" (requirements: Work_Budget_Requirements) -> bool {
	_, ok := work_budget_minimum_pages(requirements)
	return ok
}

// work_budget_child_amounts computes the exact op.Budget_Amounts a client passes
// to Budget_Create so the resulting child budget holds one thread slot, zero
// process slots, zero log records, the required pages plus optional extra
// scratch pages, and the required processor time limit.
work_budget_child_amounts :: proc "contextless" (requirements: Work_Budget_Requirements, extra_scratch_pages: u64 = 0) -> (amounts: op.Budget_Amounts, ok: bool) {
	minimum_pages := work_budget_minimum_pages(requirements) or_return
	if extra_scratch_pages > MAX_WORK_BUDGET_PAGES {
		return {}, false
	}
	total_pages := checked_add_u64(minimum_pages, extra_scratch_pages) or_return
	upper := requirements.maximum_pages == 0 ? MAX_WORK_BUDGET_PAGES : requirements.maximum_pages
	if total_pages > upper {
		return {}, false
	}
	return {
		pages       = total_pages,
		processes   = 0,
		threads     = 1,
		processor   = requirements.minimum_processor_microseconds,
		log_records = 0,
	}, true
}

// work_budget_check checks whether a client's offered work budget satisfies a
// service contract's requirements before any thread or memory is created.
work_budget_check :: proc "contextless" (requirements: Work_Budget_Requirements, offered_pages: u64, offered_time: u64, offered_threads: u64, has_spend_right: bool) -> Work_Budget_Refusal {
	minimum_pages, valid := work_budget_minimum_pages(requirements)
	if !valid {
		return .Invalid_State
	}
	if !has_spend_right {
		return .Missing_Spend_Right
	}
	if offered_threads < 1 {
		return .Missing_Thread_Slot
	}
	if offered_time == 0 || offered_time < requirements.minimum_processor_microseconds {
		return .Too_Little_Time
	}
	if offered_pages < minimum_pages {
		return .Too_Few_Pages
	}
	if requirements.maximum_pages != 0 && offered_pages > requirements.maximum_pages {
		return .Invalid_State
	}
	if offered_pages > MAX_WORK_BUDGET_PAGES || offered_time > MAX_PROCESSOR_MICROSECONDS_PER_SECOND {
		return .Invalid_State
	}
	return .None
}

// work_budget_check_rights checks a kernel Budget_Amounts record together with
// the Rights returned by Handle_State.
work_budget_check_rights :: proc "contextless" (requirements: Work_Budget_Requirements, amounts: op.Budget_Amounts, rights: op.Rights) -> Work_Budget_Refusal {
	return work_budget_check(requirements, amounts.pages, amounts.processor, amounts.threads, WORK_BUDGET_REQUIRED_RIGHTS <= rights)
}

// account_snapshot builds an Accounting_Snapshot from a live Client_Work_Account.
account_snapshot :: proc "contextless" (account: Client_Work_Account) -> Accounting_Snapshot {
	return {
		connection_identifier        = account.connection_identifier,
		state                        = account.state,
		pages_limit                  = account.pages_limit,
		pages_charged                = account.pages_charged,
		pages_peak                   = account.pages_peak,
		processor_limit_microseconds = account.processor_limit_microseconds,
		processor_nanoseconds        = account.processor_nanoseconds,
		step_debt_nanoseconds        = account.step_debt_nanoseconds,
		requests_served              = account.requests_served,
		exhaustion_count             = account.exhaustion_count,
	}
}

// accounting_snapshot_validate checks every invariant of an Accounting_Snapshot.
accounting_snapshot_validate :: proc "contextless" (snapshot: Accounting_Snapshot) -> Work_Budget_Refusal {
	state, state_ok := work_account_state_from_word(u64(snapshot.state))
	if !state_ok {
		return .Invalid_State
	}
	if snapshot.connection_identifier == 0 {
		return .Invalid_State
	}
	if snapshot.pages_limit > MAX_WORK_BUDGET_PAGES {
		return .Invalid_State
	}
	if snapshot.pages_charged > snapshot.pages_limit {
		return .Invalid_State
	}
	if snapshot.pages_peak < snapshot.pages_charged || snapshot.pages_peak > snapshot.pages_limit {
		return .Invalid_State
	}
	if snapshot.processor_limit_microseconds > MAX_PROCESSOR_MICROSECONDS_PER_SECOND {
		return .Invalid_State
	}
	switch state {
	case .Inactive:
		if snapshot.pages_limit == 0 || snapshot.processor_limit_microseconds == 0 {
			return .Invalid_State
		}
	case .Active:
		if snapshot.pages_limit == 0 || snapshot.processor_limit_microseconds == 0 {
			return .Invalid_State
		}
	case .Exhausted:
		if snapshot.exhaustion_count == 0 {
			return .Invalid_State
		}
	case .Revoked, .Closed:
		if snapshot.pages_charged != 0 {
			return .Invalid_State
		}
	}
	return .None
}

// accounting_snapshot_encode packs a validated Accounting_Snapshot into its
// border-crossing record form.
accounting_snapshot_encode :: proc "contextless" (snapshot: Accounting_Snapshot) -> Accounting_Snapshot_Record {
	return {
		version                      = u64(ACCOUNTING_SNAPSHOT_VERSION),
		connection_identifier        = snapshot.connection_identifier,
		state_word                   = u64(snapshot.state),
		pages_limit                  = snapshot.pages_limit,
		pages_charged                = snapshot.pages_charged,
		pages_peak                   = snapshot.pages_peak,
		processor_limit_microseconds = snapshot.processor_limit_microseconds,
		processor_nanoseconds        = snapshot.processor_nanoseconds,
		step_debt_nanoseconds        = snapshot.step_debt_nanoseconds,
		requests_served              = snapshot.requests_served,
		exhaustion_count             = snapshot.exhaustion_count,
	}
}

// accounting_snapshot_decode validates a raw Accounting_Snapshot_Record at the
// border, refusing unknown version numbers, unknown state words (including 0
// and max(u64)), and inconsistent counts.
accounting_snapshot_decode :: proc "contextless" (record: Accounting_Snapshot_Record) -> (snapshot: Accounting_Snapshot, refusal: Work_Budget_Refusal) {
	if record.version != u64(ACCOUNTING_SNAPSHOT_VERSION) {
		return {}, .Invalid_State
	}
	state, state_ok := work_account_state_from_word(record.state_word)
	if !state_ok {
		return {}, .Invalid_State
	}
	candidate := Accounting_Snapshot {
		connection_identifier        = record.connection_identifier,
		state                        = state,
		pages_limit                  = record.pages_limit,
		pages_charged                = record.pages_charged,
		pages_peak                   = record.pages_peak,
		processor_limit_microseconds = record.processor_limit_microseconds,
		processor_nanoseconds        = record.processor_nanoseconds,
		step_debt_nanoseconds        = record.step_debt_nanoseconds,
		requests_served              = record.requests_served,
		exhaustion_count             = record.exhaustion_count,
	}
	if check := accounting_snapshot_validate(candidate); check != .None {
		return {}, check
	}
	return candidate, .None
}

// One row of the work that a service did for one connection of a process:
// what the console command work(process) shows. A connection whose service
// charges no work budget yet is unaccounted: its numbers are zero because
// the service paid the work itself, not because the work was free.
Work_Row :: struct {
	accounted:              bool, // false: no accounting snapshot exists for the connection.
	state:                  Work_Account_State, // Read only when accounted.
	pages_charged:          u64, // Pages of the work budget in use.
	pages_limit:            u64, // Pages of the work budget in total.
	processor_microseconds: u64, // Processor time of the work thread since the connection.
	step_debt_microseconds: u64, // Time of the shared steps of the connection.
}

// microseconds_of_nanoseconds gives a count of nanoseconds in whole
// microseconds, rounded down: a row never shows time that was not spent.
microseconds_of_nanoseconds :: proc "contextless" (nanoseconds: u64) -> u64 {
	return nanoseconds / 1000
}

// work_row_unaccounted gives the row of a connection whose service charges
// no work budget.
work_row_unaccounted :: proc "contextless" () -> Work_Row {
	return {}
}

// work_row_of_snapshot_record is the border of the snapshot that a service
// writes for one connection: it decodes the record and gives the row, or
// the refusal of accounting_snapshot_decode and no row.
work_row_of_snapshot_record :: proc "contextless" (record: Accounting_Snapshot_Record) -> (row: Work_Row, refusal: Work_Budget_Refusal) {
	snapshot, decoded := accounting_snapshot_decode(record)
	if decoded != .None {
		return {}, decoded
	}
	return {
		accounted              = true,
		state                  = snapshot.state,
		pages_charged          = snapshot.pages_charged,
		pages_limit            = snapshot.pages_limit,
		processor_microseconds = microseconds_of_nanoseconds(snapshot.processor_nanoseconds),
		step_debt_microseconds = microseconds_of_nanoseconds(snapshot.step_debt_nanoseconds),
	}, .None
}

// work_account_state_text gives the word of a state in a row.
work_account_state_text :: proc "contextless" (state: Work_Account_State) -> string {
	switch state {
	case .Inactive:
		return "inactive"
	case .Active:
		return "active"
	case .Exhausted:
		return "exhausted"
	case .Revoked:
		return "revoked"
	case .Closed:
		return "closed"
	}
	return ""
}

// work_row_state_text gives the word of the state column of a row:
// "unaccounted" for a connection with no snapshot, else the word of its
// state.
work_row_state_text :: proc "contextless" (row: Work_Row) -> string {
	if !row.accounted {
		return "unaccounted"
	}
	return work_account_state_text(row.state)
}

// table_init creates a new Connection_Worker_Table bound to a service's budget
// requirements and its own budget handle (which is refused as any client's
// work budget).
table_init :: proc "contextless" (requirements: Work_Budget_Requirements, service_own_budget: op.Handle) -> (table: Connection_Worker_Table, refusal: Work_Budget_Refusal) {
	if !work_budget_requirements_valid(requirements) {
		return {}, .Invalid_State
	}
	return {
		initialized        = true,
		requirements       = requirements,
		service_own_budget = service_own_budget,
	}, .None
}

@(private = "file")
table_find_slot :: proc "contextless" (table: ^Connection_Worker_Table, connection_identifier: u64) -> ^Connection_Worker_Slot {
	if table == nil || !table.initialized || connection_identifier == 0 {
		return nil
	}
	for &slot in table.slots {
		if slot.occupied && slot.account.connection_identifier == connection_identifier {
			return &slot
		}
	}
	return nil
}

@(private = "file")
table_is_recently_revoked :: proc "contextless" (table: ^Connection_Worker_Table, connection_identifier: u64) -> bool {
	if table == nil || connection_identifier == 0 {
		return false
	}
	for identifier in table.revoked_ring {
		if identifier == connection_identifier {
			return true
		}
	}
	return false
}

@(private = "file")
table_record_revoked :: proc "contextless" (table: ^Connection_Worker_Table, connection_identifier: u64) {
	table.revoked_ring[table.revoked_ring_cursor] = connection_identifier
	table.revoked_ring_cursor = (table.revoked_ring_cursor + 1) % MAX_ACCOUNTED_CONNECTIONS
}

@(private = "file")
table_clear_revoked :: proc "contextless" (table: ^Connection_Worker_Table, connection_identifier: u64) {
	for &identifier in table.revoked_ring {
		if identifier == connection_identifier {
			identifier = 0
		}
	}
}

@(private = "file")
table_least_active_step_debt :: proc "contextless" (table: ^Connection_Worker_Table) -> u64 {
	found := false
	least: u64 = 0
	for &slot in table.slots {
		if !slot.occupied || slot.account.state != .Active {
			continue
		}
		if !found || slot.account.step_debt_nanoseconds < least {
			least = slot.account.step_debt_nanoseconds
			found = true
		}
	}
	return least
}

@(private = "file")
account_budget_is_client_owned :: proc "contextless" (table: ^Connection_Worker_Table, budget_handle: op.Handle) -> bool {
	if budget_handle == 0 {
		return false
	}
	if table.service_own_budget != 0 && budget_handle == table.service_own_budget {
		return false
	}
	return true
}

// connection_open validates a client's offered work budget and allocates one
// slot in the table. It refuses a missing Spend right, a zero budget handle,
// the service's own budget handle, insufficient pages/time/threads, a duplicate
// connection identifier, or a full table, leaving all existing slots untouched.
// When work_thread_handle is non-zero, the connection enters Active at once;
// otherwise it enters Inactive until connection_activate binds the thread.
connection_open :: proc "contextless" (
	table: ^Connection_Worker_Table,
	connection_identifier: u64,
	client_budget_handle: op.Handle,
	offered_pages: u64,
	offered_time: u64,
	offered_threads: u64,
	has_spend_right: bool,
	work_thread_handle: op.Handle = 0,
) -> Work_Budget_Refusal {
	if table == nil || !table.initialized || connection_identifier == 0 {
		return .Invalid_State
	}
	if table_find_slot(table, connection_identifier) != nil {
		return .Duplicate_Connection
	}
	if client_budget_handle == 0 {
		return .Missing_Spend_Right
	}
	if table.service_own_budget != 0 && client_budget_handle == table.service_own_budget {
		return .Invalid_State
	}
	if check := work_budget_check(table.requirements, offered_pages, offered_time, offered_threads, has_spend_right); check != .None {
		return check
	}
	base_pages, base_ok := work_budget_base_pages(table.requirements)
	if !base_ok || base_pages > offered_pages {
		return .Too_Few_Pages
	}
	free_index := -1
	for &slot, index in table.slots {
		if !slot.occupied {
			free_index = index
			break
		}
	}
	if free_index < 0 {
		return .Too_Many_Connections
	}
	initial_debt := table_least_active_step_debt(table)
	initial_state := work_thread_handle == 0 ? Work_Account_State.Inactive : Work_Account_State.Active
	table_clear_revoked(table, connection_identifier)
	table.slots[free_index] = {
		occupied = true,
		account = {
			connection_identifier        = connection_identifier,
			client_budget_handle         = client_budget_handle,
			work_thread_handle           = work_thread_handle,
			state                        = initial_state,
			pages_limit                  = offered_pages,
			pages_charged                = base_pages,
			pages_peak                   = base_pages,
			processor_limit_microseconds = offered_time,
			step_debt_nanoseconds        = initial_debt,
		},
	}
	table.occupied_count += 1
	return .None
}

// connection_activate binds a live work thread handle created on the client's
// work budget to an Inactive connection, transitioning it to Active.
connection_activate :: proc "contextless" (table: ^Connection_Worker_Table, connection_identifier: u64, work_thread_handle: op.Handle) -> Work_Budget_Refusal {
	if table == nil || !table.initialized || work_thread_handle == 0 {
		return .Invalid_State
	}
	slot := table_find_slot(table, connection_identifier)
	if slot == nil {
		return table_is_recently_revoked(table, connection_identifier) ? .Budget_Revoked : .Invalid_State
	}
	if !account_budget_is_client_owned(table, slot.account.client_budget_handle) {
		return .Invalid_State
	}
	switch slot.account.state {
	case .Inactive:
		slot.account.work_thread_handle = work_thread_handle
		slot.account.state = .Active
		slot.account.step_debt_nanoseconds = table_least_active_step_debt(table)
		return .None
	case .Exhausted:
		return .Budget_Exhausted
	case .Revoked:
		return .Budget_Revoked
	case .Active, .Closed:
		return .Invalid_State
	}
	return .Invalid_State
}

// connection_begin_request marks a request in flight on an Active connection's
// work thread. Refuses Inactive, Exhausted, Revoked, or concurrent re-entry on
// the same connection without affecting sibling connections.
connection_begin_request :: proc "contextless" (table: ^Connection_Worker_Table, connection_identifier: u64) -> Work_Budget_Refusal {
	if table == nil || !table.initialized {
		return .Invalid_State
	}
	slot := table_find_slot(table, connection_identifier)
	if slot == nil {
		return table_is_recently_revoked(table, connection_identifier) ? .Budget_Revoked : .Invalid_State
	}
	if !account_budget_is_client_owned(table, slot.account.client_budget_handle) {
		return .Invalid_State
	}
	switch slot.account.state {
	case .Active:
		if slot.account.in_flight_request || slot.account.work_thread_handle == 0 {
			return .Invalid_State
		}
		slot.account.in_flight_request = true
		return .None
	case .Exhausted:
		return .Budget_Exhausted
	case .Revoked:
		return .Budget_Revoked
	case .Inactive, .Closed:
		return .Invalid_State
	}
	return .Invalid_State
}

// connection_charge_pages charges delta_pages to the client's work budget.
// When the charge would exceed pages_limit, ONLY this connection transitions to
// Exhausted (with its pages_charged unchanged and any in-flight request aborted),
// leaving every sibling connection untouched.
connection_charge_pages :: proc "contextless" (table: ^Connection_Worker_Table, connection_identifier: u64, delta_pages: u64) -> Work_Budget_Refusal {
	if table == nil || !table.initialized {
		return .Invalid_State
	}
	slot := table_find_slot(table, connection_identifier)
	if slot == nil {
		return table_is_recently_revoked(table, connection_identifier) ? .Budget_Revoked : .Invalid_State
	}
	if !account_budget_is_client_owned(table, slot.account.client_budget_handle) {
		return .Invalid_State
	}
	switch slot.account.state {
	case .Active:
		remaining := slot.account.pages_limit - slot.account.pages_charged
		if delta_pages > remaining {
			slot.account.state = .Exhausted
			slot.account.exhaustion_count += 1
			slot.account.in_flight_request = false
			return .Budget_Exhausted
		}
		slot.account.pages_charged += delta_pages
		if slot.account.pages_charged > slot.account.pages_peak {
			slot.account.pages_peak = slot.account.pages_charged
		}
		return .None
	case .Exhausted:
		return .Budget_Exhausted
	case .Revoked:
		return .Budget_Revoked
	case .Inactive, .Closed:
		return .Invalid_State
	}
	return .Invalid_State
}

// connection_release_pages returns scratch pages previously charged to a
// connection when its arena or working table decommits. Base thread and ring
// pages stay charged until close or revocation.
connection_release_pages :: proc "contextless" (table: ^Connection_Worker_Table, connection_identifier: u64, released_pages: u64) -> Work_Budget_Refusal {
	if table == nil || !table.initialized {
		return .Invalid_State
	}
	slot := table_find_slot(table, connection_identifier)
	if slot == nil {
		return table_is_recently_revoked(table, connection_identifier) ? .Budget_Revoked : .Invalid_State
	}
	base_pages, base_ok := work_budget_base_pages(table.requirements)
	if !base_ok {
		return .Invalid_State
	}
	switch slot.account.state {
	case .Active, .Exhausted:
		if released_pages > slot.account.pages_charged || slot.account.pages_charged - released_pages < base_pages {
			return .Invalid_State
		}
		slot.account.pages_charged -= released_pages
		return .None
	case .Revoked:
		return .Budget_Revoked
	case .Inactive, .Closed:
		return .Invalid_State
	}
	return .Invalid_State
}

// connection_charge_processor_time records processor nanoseconds used by a
// connection's work thread and optional shared-step time added to its step debt.
connection_charge_processor_time :: proc "contextless" (table: ^Connection_Worker_Table, connection_identifier: u64, delta_nanoseconds: u64, shared_step_nanoseconds: u64 = 0) -> Work_Budget_Refusal {
	if table == nil || !table.initialized {
		return .Invalid_State
	}
	slot := table_find_slot(table, connection_identifier)
	if slot == nil {
		return table_is_recently_revoked(table, connection_identifier) ? .Budget_Revoked : .Invalid_State
	}
	if !account_budget_is_client_owned(table, slot.account.client_budget_handle) {
		return .Invalid_State
	}
	switch slot.account.state {
	case .Active:
		next_cpu, cpu_ok := checked_add_u64(slot.account.processor_nanoseconds, delta_nanoseconds)
		next_debt, debt_ok := checked_add_u64(slot.account.step_debt_nanoseconds, shared_step_nanoseconds)
		if !cpu_ok || !debt_ok {
			return .Invalid_State
		}
		slot.account.processor_nanoseconds = next_cpu
		slot.account.step_debt_nanoseconds = next_debt
		return .None
	case .Exhausted:
		return .Budget_Exhausted
	case .Revoked:
		return .Budget_Revoked
	case .Inactive, .Closed:
		return .Invalid_State
	}
	return .Invalid_State
}

// connection_complete_request finishes an in-flight request, charging its work
// thread processor time and optional shared-step debt and incrementing
// requests_served. A connection revoked mid-call fails with Budget_Revoked.
connection_complete_request :: proc "contextless" (table: ^Connection_Worker_Table, connection_identifier: u64, delta_nanoseconds: u64, shared_step_nanoseconds: u64 = 0) -> Work_Budget_Refusal {
	if table == nil || !table.initialized {
		return .Invalid_State
	}
	slot := table_find_slot(table, connection_identifier)
	if slot == nil {
		return table_is_recently_revoked(table, connection_identifier) ? .Budget_Revoked : .Invalid_State
	}
	if !account_budget_is_client_owned(table, slot.account.client_budget_handle) {
		return .Invalid_State
	}
	switch slot.account.state {
	case .Active:
		if !slot.account.in_flight_request {
			return .Invalid_State
		}
		next_cpu, cpu_ok := checked_add_u64(slot.account.processor_nanoseconds, delta_nanoseconds)
		next_debt, debt_ok := checked_add_u64(slot.account.step_debt_nanoseconds, shared_step_nanoseconds)
		if !cpu_ok || !debt_ok {
			return .Invalid_State
		}
		slot.account.processor_nanoseconds = next_cpu
		slot.account.step_debt_nanoseconds = next_debt
		slot.account.requests_served += 1
		slot.account.in_flight_request = false
		return .None
	case .Exhausted:
		return .Budget_Exhausted
	case .Revoked:
		return .Budget_Revoked
	case .Inactive, .Closed:
		return .Invalid_State
	}
	return .Invalid_State
}

// connection_mark_exhausted transitions an Active connection to Exhausted when
// the kernel reports No_Budget or processor-period exhaustion for that client.
// Sibling connections stay Active.
connection_mark_exhausted :: proc "contextless" (table: ^Connection_Worker_Table, connection_identifier: u64) -> Work_Budget_Refusal {
	if table == nil || !table.initialized {
		return .Invalid_State
	}
	slot := table_find_slot(table, connection_identifier)
	if slot == nil {
		return table_is_recently_revoked(table, connection_identifier) ? .Budget_Revoked : .Invalid_State
	}
	switch slot.account.state {
	case .Active:
		slot.account.state = .Exhausted
		slot.account.exhaustion_count += 1
		slot.account.in_flight_request = false
		return .None
	case .Exhausted:
		return .Budget_Exhausted
	case .Revoked:
		return .Budget_Revoked
	case .Inactive, .Closed:
		return .Invalid_State
	}
	return .Invalid_State
}

// connection_replenish resumes an Exhausted connection after pages or processor
// limit have been restored to its work budget. Revoked and Closed connections
// cannot be resumed.
connection_replenish :: proc "contextless" (table: ^Connection_Worker_Table, connection_identifier: u64, added_pages: u64, new_processor_limit_microseconds: u64) -> Work_Budget_Refusal {
	if table == nil || !table.initialized {
		return .Invalid_State
	}
	slot := table_find_slot(table, connection_identifier)
	if slot == nil {
		return table_is_recently_revoked(table, connection_identifier) ? .Budget_Revoked : .Invalid_State
	}
	switch slot.account.state {
	case .Exhausted:
		new_limit, add_ok := checked_add_u64(slot.account.pages_limit, added_pages)
		if !add_ok {
			return .Invalid_State
		}
		if check := work_budget_check(table.requirements, new_limit, new_processor_limit_microseconds, 1, true); check != .None {
			return check
		}
		if slot.account.pages_charged > new_limit {
			return .Too_Few_Pages
		}
		slot.account.pages_limit = new_limit
		slot.account.processor_limit_microseconds = new_processor_limit_microseconds
		slot.account.state = .Active
		return .None
	case .Revoked:
		return .Budget_Revoked
	case .Inactive, .Active, .Closed:
		return .Invalid_State
	}
	return .Invalid_State
}

// connection_revoke cleanly transitions a connection to Revoked (including when
// a request is in flight), captures its final Revoked snapshot, and reclaims
// its slot immediately so new clients are never blocked by revoked connections.
connection_revoke :: proc "contextless" (table: ^Connection_Worker_Table, connection_identifier: u64) -> (final_snapshot: Accounting_Snapshot, refusal: Work_Budget_Refusal) {
	if table == nil || !table.initialized || connection_identifier == 0 {
		return {}, .Invalid_State
	}
	slot := table_find_slot(table, connection_identifier)
	if slot == nil {
		return {}, table_is_recently_revoked(table, connection_identifier) ? .Budget_Revoked : .Invalid_State
	}
	slot.account.state = .Revoked
	slot.account.in_flight_request = false
	slot.account.work_thread_handle = 0
	slot.account.pages_charged = 0
	final_snapshot = account_snapshot(slot.account)
	slot^ = {}
	table.occupied_count -= 1
	table.revoked_total += 1
	table_record_revoked(table, connection_identifier)
	return final_snapshot, .None
}

// connection_close cleanly transitions a connection to Closed, captures its
// final Closed snapshot, and reclaims its slot. A stale close on an already
// closed or unknown connection returns Invalid_State and changes nothing.
connection_close :: proc "contextless" (table: ^Connection_Worker_Table, connection_identifier: u64) -> (final_snapshot: Accounting_Snapshot, refusal: Work_Budget_Refusal) {
	if table == nil || !table.initialized || connection_identifier == 0 {
		return {}, .Invalid_State
	}
	slot := table_find_slot(table, connection_identifier)
	if slot == nil {
		return {}, table_is_recently_revoked(table, connection_identifier) ? .Budget_Revoked : .Invalid_State
	}
	slot.account.state = .Closed
	slot.account.in_flight_request = false
	slot.account.work_thread_handle = 0
	slot.account.pages_charged = 0
	final_snapshot = account_snapshot(slot.account)
	slot^ = {}
	table.occupied_count -= 1
	table.closed_total += 1
	return final_snapshot, .None
}

// connection_snapshot returns a validated Accounting_Snapshot for an occupied
// connection.
connection_snapshot :: proc "contextless" (table: ^Connection_Worker_Table, connection_identifier: u64) -> (snapshot: Accounting_Snapshot, refusal: Work_Budget_Refusal) {
	if table == nil || !table.initialized {
		return {}, .Invalid_State
	}
	slot := table_find_slot(table, connection_identifier)
	if slot == nil {
		return {}, table_is_recently_revoked(table, connection_identifier) ? .Budget_Revoked : .Invalid_State
	}
	return account_snapshot(slot.account), .None
}

// connection_account returns a copy of the live Client_Work_Account for an
// occupied connection.
connection_account :: proc "contextless" (table: ^Connection_Worker_Table, connection_identifier: u64) -> (account: Client_Work_Account, ok: bool) {
	slot := table_find_slot(table, connection_identifier)
	if slot == nil {
		return {}, false
	}
	return slot.account, true
}

// connection_next_shared_step picks the Active waiting connection with the
// least step_debt_nanoseconds, breaking ties by the smallest connection
// identifier. Exhausted, Inactive, Revoked, and unknown connections are skipped.
connection_next_shared_step :: proc "contextless" (table: ^Connection_Worker_Table, waiting_connections: []u64) -> (connection_identifier: u64, ok: bool) {
	if table == nil || !table.initialized {
		return 0, false
	}
	best_debt: u64 = 0
	for candidate in waiting_connections {
		slot := table_find_slot(table, candidate)
		if slot == nil || slot.account.state != .Active {
			continue
		}
		if !ok || slot.account.step_debt_nanoseconds < best_debt || (slot.account.step_debt_nanoseconds == best_debt && candidate < connection_identifier) {
			connection_identifier = candidate
			best_debt = slot.account.step_debt_nanoseconds
			ok = true
		}
	}
	return connection_identifier, ok
}

// table_active_count returns the number of connections currently in Active state.
table_active_count :: proc "contextless" (table: ^Connection_Worker_Table) -> int {
	if table == nil || !table.initialized {
		return 0
	}
	count := 0
	for &slot in table.slots {
		if slot.occupied && slot.account.state == .Active {
			count += 1
		}
	}
	return count
}

// table_occupied_count returns the number of slots currently occupied.
table_occupied_count :: proc "contextless" (table: ^Connection_Worker_Table) -> int {
	if table == nil || !table.initialized {
		return 0
	}
	return table.occupied_count
}

// table_total_pages_charged returns the sum of pages charged across all live
// client connections.
table_total_pages_charged :: proc "contextless" (table: ^Connection_Worker_Table) -> u64 {
	if table == nil || !table.initialized {
		return 0
	}
	total: u64 = 0
	for &slot in table.slots {
		if slot.occupied {
			total += slot.account.pages_charged
		}
	}
	return total
}
