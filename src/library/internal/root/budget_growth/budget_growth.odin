// Budget_Grow in the root service: a second budget handle that a process
// with a growth row in the plan asks for, up to its ceiling, rate-limited
// per process, optionally served from a per-process growth reserve before
// the shared free pool, drained on release and closed at stop
// (src/md/features/module_budget_request.md, "The growth is a second budget").
//
// A pure part, which host tests run with no kernel or root service: handles
// and process keys are u64 words.
package budget_growth

// Maximum concurrent extra budgets held by one process (active or draining).
// Bounded because the root service keeps one handle per open extra budget
// out of its handle table, and a process needs only a few concurrent purpose
// budgets at once.
EXTRAS_PER_PROCESS :: 8

// Maximum total extra budgets tracked across all running processes.
// Sized to fit within the handle budget of the root service alongside
// process, ring, and screen-budget handles.
TABLE_CAPACITY :: 64

// Maximum distinct processes whose rate-limit timestamp is tracked.
// Sized to the process slot capacity of the root service.
PROCESS_LIMIT_CAPACITY :: 64

// Refused log lines per second: a sender that loops cannot fill the log.
REFUSED_LINES_PER_SECOND :: 4

// Why Budget_Grow refused a growth request. Carried in the refusal record as
// a closed enum value; never carries a free-page count.
Grow_Refusal :: enum u8 {
	None         = 0,
	No_Row       = 1, // Process has no growth ceiling in the plan: refused before reading pool.
	Bad_Pages    = 2, // Requested pages is 0 or exceeds ceiling alone.
	Too_Soon     = 3, // Process already received a decision within the rate-limit period.
	Over_Ceiling = 4, // Start budget + held extras + asked exceeds ceiling.
	Full         = 5, // Process or table holds its maximum extra budgets.
	No_Pages     = 6, // Free pages past start-list reserves and growth reserves do not hold asked.
}

// Human-readable cause sentence for each refusal, following docs/WRITING.md.
// None mentions any free-page count of the starter.
@(rodata)
GROW_REFUSAL_SENTENCES := [Grow_Refusal]string {
	.None         = "",
	.No_Row       = "the plan gives the process no growth ceiling",
	.Bad_Pages    = "the requested pages are zero or above the ceiling",
	.Too_Soon     = "another growth decision ran inside the rate-limit period",
	.Over_Ceiling = "the requested pages pass the growth ceiling of the process",
	.Full         = "the process or the root service holds the maximum extra budgets",
	.No_Pages     = "the starter cannot supply the requested pages now",
}

// Inputs to one Budget_Grow decision.
Grow_Facts :: struct {
	ceiling_pages:        u64,  // 0: no growth row in the plan.
	growth_reserve_pages: u64,  // Optional reserved pages for this process alone (<= ceiling_pages).
	asked_pages:          u64,  // Requested pages of the new extra budget.
	paid_pages:           u64,  // Initial budget pages + held (active and draining) extra pages.
	reserve_used_pages:   u64,  // Reserve pages currently held by this process's extra budgets.
	extras_held:          int,  // Count of extra budgets held by this process (active and draining).
	table_used:           int,  // Total extra budgets held across all processes.
	now:                  u64,  // Current monotonic time in milliseconds.
	last_decision_at:     u64,  // Time of the previous decision for this process.
	has_last_decision:    bool, // True once this process has had a prior decision.
	period_ms:            u64,  // Rate-limit period in milliseconds (>= 1).
	shared_pool_pages:    u64,  // Free pages of the starter past start-list and growth reserves.
}

// One extra budget handle tracked by the root service.
Extra :: struct {
	owner:        u64,  // Non-zero process identity (process handle or slot serial).
	handle:       u64,  // Root service handle of the extra budget; 0 means free slot.
	pages:        u64,  // Total pages in this extra budget.
	from_reserve: u64,  // Portion of pages taken from the owner's growth reserve.
	growth:       u64,  // Unique non-zero serial returned to the process for Release.
	draining:     bool, // Released: child handle revoked, waiting until all pages return.
}

// Per-process rate-limit record.
Rate_Entry :: struct {
	owner:            u64, // 0 means free slot.
	last_decision_at: u64,
}

// All extra budgets and per-process rate limits held by the root service.
Table :: struct {
	extras:      [TABLE_CAPACITY]Extra,
	rates:       [PROCESS_LIMIT_CAPACITY]Rate_Entry,
	last_growth: u64, // Monotonic serial for each accepted growth; 0 is none.
}

// decide evaluates one Budget_Grow request in strict order:
// 1. No growth row -> No_Row (before reading pool or rate limit).
// 2. Bad page count (0 or > ceiling) -> Bad_Pages.
// 3. Rate limit (within period_ms of last decision) -> Too_Soon.
// 4. Ceiling check (paid + asked > ceiling, overflow-safe) -> Over_Ceiling.
// 5. Capacity check (per-process and global table) -> Full.
// 6. Reserve then shared pool -> No_Pages when shared pool is short.
//
// counts_as_decision is true whenever the check reached step 4 or later (so
// both accepted growths and ceiling/pool refusals consume the process's
// rate-limit slot for the current period, bounding probing to one decision
// per period).
decide :: proc "contextless" (facts: Grow_Facts) -> (refusal: Grow_Refusal, from_reserve: u64, from_pool: u64, counts_as_decision: bool) {
	if facts.ceiling_pages == 0 {
		return .No_Row, 0, 0, false
	}
	if facts.asked_pages == 0 || facts.asked_pages > facts.ceiling_pages {
		return .Bad_Pages, 0, 0, false
	}
	period := max(facts.period_ms, u64(1))
	if facts.has_last_decision {
		if facts.now < facts.last_decision_at || facts.now - facts.last_decision_at < period {
			return .Too_Soon, 0, 0, false
		}
	}
	if facts.paid_pages > facts.ceiling_pages || facts.asked_pages > facts.ceiling_pages - facts.paid_pages {
		return .Over_Ceiling, 0, 0, true
	}
	if facts.extras_held >= EXTRAS_PER_PROCESS || facts.table_used >= TABLE_CAPACITY {
		return .Full, 0, 0, true
	}
	reserve_left := facts.growth_reserve_pages > facts.reserve_used_pages ? facts.growth_reserve_pages - facts.reserve_used_pages : 0
	from_reserve = min(facts.asked_pages, reserve_left)
	from_pool = facts.asked_pages - from_reserve
	if from_pool > facts.shared_pool_pages {
		return .No_Pages, 0, 0, true
	}
	return .None, from_reserve, from_pool, true
}

// held_by returns the count of extra budgets (active and draining), total
// pages, and reserve pages held by owner.
held_by :: proc "contextless" (table: ^Table, owner: u64) -> (count: int, pages: u64, reserve_used: u64) {
	if owner == 0 {
		return 0, 0, 0
	}
	for extra in table.extras {
		if extra.handle != 0 && extra.owner == owner {
			count += 1
			pages = pages > max(u64) - extra.pages ? max(u64) : pages + extra.pages
			reserve_used = reserve_used > max(u64) - extra.from_reserve ? max(u64) : reserve_used + extra.from_reserve
		}
	}
	return
}

// table_used returns the total count of active and draining extra budgets.
table_used :: proc "contextless" (table: ^Table) -> (count: int) {
	for extra in table.extras {
		if extra.handle != 0 {
			count += 1
		}
	}
	return
}

// last_decision returns the previous decision timestamp of owner, if any.
last_decision :: proc "contextless" (table: ^Table, owner: u64) -> (at: u64, found: bool) {
	if owner == 0 {
		return 0, false
	}
	for entry in table.rates {
		if entry.owner == owner {
			return entry.last_decision_at, true
		}
	}
	return 0, false
}

// note_decision records the timestamp of a decision for owner so the next
// request within period_ms is refused with Too_Soon.
note_decision :: proc "contextless" (table: ^Table, owner: u64, now: u64) {
	if owner == 0 {
		return
	}
	free_index := -1
	for &entry, index in table.rates {
		if entry.owner == owner {
			entry.last_decision_at = now
			return
		}
		if entry.owner == 0 && free_index < 0 {
			free_index = index
		}
	}
	if free_index >= 0 {
		table.rates[free_index] = {owner = owner, last_decision_at = now}
	}
}

// grow_take inserts a newly created extra budget for owner and returns its
// unique growth serial. Returns 0 without changing table when owner or
// handle is 0, handle is duplicated, or table/per-process capacity is full.
grow_take :: proc "contextless" (table: ^Table, owner, handle, pages, from_reserve, now: u64) -> (growth: u64) {
	if owner == 0 || handle == 0 || pages == 0 || from_reserve > pages || table.last_growth == max(u64) {
		return 0
	}
	owner_count := 0
	free_index := -1
	for extra, index in table.extras {
		if extra.handle != 0 {
			if extra.handle == handle {
				return 0
			}
			if extra.owner == owner {
				owner_count += 1
			}
		} else if free_index < 0 {
			free_index = index
		}
	}
	if free_index < 0 || owner_count >= EXTRAS_PER_PROCESS {
		return 0
	}
	table.last_growth += 1
	growth = table.last_growth
	table.extras[free_index] = {
		owner        = owner,
		handle       = handle,
		pages        = pages,
		from_reserve = from_reserve,
		growth       = growth,
		draining     = false,
	}
	note_decision(table, owner, now)
	return growth
}

// grow_undo removes a growth that failed delivery to the caller.
grow_undo :: proc "contextless" (table: ^Table, growth: u64) -> bool {
	if growth == 0 {
		return false
	}
	for &extra in table.extras {
		if extra.handle != 0 && extra.growth == growth && !extra.draining {
			extra = {}
			return true
		}
	}
	return false
}

// release marks the extra budget (owner, growth) as draining and returns its
// root handle so the root service can revoke the child handle. Returns false
// when owner does not hold that growth or already released it.
release :: proc "contextless" (table: ^Table, owner, growth: u64) -> (handle: u64, ok: bool) {
	if owner == 0 || growth == 0 {
		return 0, false
	}
	for &extra in table.extras {
		if extra.handle != 0 && extra.owner == owner && extra.growth == growth && !extra.draining {
			extra.draining = true
			return extra.handle, true
		}
	}
	return 0, false
}

// draining says whether any extra budget waits for its objects to close.
draining :: proc "contextless" (table: ^Table) -> bool {
	for extra in table.extras {
		if extra.handle != 0 && extra.draining {
			return true
		}
	}
	return false
}

// drained removes a draining extra budget once all its pages are back.
drained :: proc "contextless" (table: ^Table, handle, pages_left: u64) -> bool {
	if handle == 0 {
		return false
	}
	for &extra in table.extras {
		if extra.handle == handle && extra.draining {
			if pages_left < extra.pages {
				return false
			}
			extra = {}
			return true
		}
	}
	return false
}

// stop clears all extra budgets (active and draining) and the rate-limit
// entry of a stopped process, returning the handles the root service must
// close.
stop :: proc "contextless" (table: ^Table, owner: u64) -> (handles: [EXTRAS_PER_PROCESS]u64, count: int) {
	if owner == 0 {
		return {}, 0
	}
	for &extra in table.extras {
		if extra.handle != 0 && extra.owner == owner {
			if count < EXTRAS_PER_PROCESS {
				handles[count] = extra.handle
				count += 1
			}
			extra = {}
		}
	}
	for &entry in table.rates {
		if entry.owner == owner {
			entry = {}
		}
	}
	return handles, count
}

// Rate limit for refusal log lines.
Line_Bound :: struct {
	second: u64,
	count:  u64,
}

// line_allowed says if a refusal at now (milliseconds) writes its line.
line_allowed :: proc "contextless" (bound: ^Line_Bound, now: u64) -> bool {
	second := now / 1000
	if second != bound.second {
		bound.second = second
		bound.count = 0
	}
	if bound.count >= REFUSED_LINES_PER_SECOND {
		return false
	}
	bound.count += 1
	return true
}
