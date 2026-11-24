package session_budgets

// Per-session reserved budget calculation and storage block accounting
// (src/md/features/several_principals.md, "The rest").
//
// Each unlocked named principal session receives a reserved child budget from
// the root service covering pages, process slots, thread slots, processor
// time, log records, and storage blocks. A fixed machine reserve is always
// held back so a named session reaches its own limit and never exhausts the
// machine budget.

// Amounts reserved for a named principal session across all bounded resources.
Session_Budget_Amounts :: struct {
	pages:          u64,
	processes:      u64,
	threads:        u64,
	processor:      u64,
	log_records:    u64,
	storage_blocks: u64,
}

// Default storage block pool for dividing named session quotas when disk
// capacity is not queried directly (1 GiB of 4 KiB blocks).
DEFAULT_MACHINE_STORAGE_BLOCKS :: u64(262_144)

// Machine reserve floors held back for principal 0 and joint processes so no
// named session can starve the root service, display holder, or unlock.
// Computed from observed machine baseline: root + compositor + storage + log +
// unlock + drivers fit within these reserves; machine_reserve_for scales a
// reserve downward to at most one quarter of available capacity on small
// machines (for example 1-CPU to 4-CPU hosts) while always keeping at least
// one unit reserved for the machine.
DEFAULT_MACHINE_RESERVE :: Session_Budget_Amounts {
	pages          = 8192,
	processes      = 24,
	threads        = 48,
	processor      = 4_000_000,
	log_records    = 200,
	storage_blocks = 4096,
}

// machine_reserve_for adapts DEFAULT_MACHINE_RESERVE to `machine_available`:
// each component stays at DEFAULT_MACHINE_RESERVE when the machine holds at
// least four times that reserve, and otherwise reserves one quarter (at least
// 1) so 1-CPU and small-memory hosts still open a bounded session budget.
// When `machine_available` holds 0 or 1 on any resource, the unscaled floor is
// kept so compute_session_budget refuses to starve the machine.
machine_reserve_for :: proc "contextless" (machine_available: Session_Budget_Amounts) -> Session_Budget_Amounts {
	cap_part :: proc "contextless" (avail, floor: u64) -> u64 {
		if avail <= 1 {
			return floor
		}
		return min(floor, max(u64(1), avail / 4))
	}
	return {
		pages          = cap_part(machine_available.pages, DEFAULT_MACHINE_RESERVE.pages),
		processes      = cap_part(machine_available.processes, DEFAULT_MACHINE_RESERVE.processes),
		threads        = cap_part(machine_available.threads, DEFAULT_MACHINE_RESERVE.threads),
		processor      = cap_part(machine_available.processor, DEFAULT_MACHINE_RESERVE.processor),
		log_records    = cap_part(machine_available.log_records, DEFAULT_MACHINE_RESERVE.log_records),
		storage_blocks = cap_part(machine_available.storage_blocks, DEFAULT_MACHINE_RESERVE.storage_blocks),
	}
}

// compute_session_budget divides the resources above `reserve` evenly across
// `session_slots` named principal slots. Refuses zero slots or any resource
// where `machine_available <= reserve`, guaranteeing that:
//   per_session.X * session_slots + reserve.X <= machine_available.X
// for every resource X.
compute_session_budget :: proc "contextless" (
	machine_available: Session_Budget_Amounts,
	reserve: Session_Budget_Amounts,
	session_slots: u64,
) -> (per_session: Session_Budget_Amounts, ok: bool) {
	if session_slots == 0 {
		return {}, false
	}
	share :: proc "contextless" (avail, res, slots: u64) -> (part: u64, fit: bool) {
		if avail <= res {
			return 0, false
		}
		part = (avail - res) / slots
		return part, part > 0
	}
	pages, pages_ok := share(machine_available.pages, reserve.pages, session_slots)
	processes, proc_ok := share(machine_available.processes, reserve.processes, session_slots)
	threads, thr_ok := share(machine_available.threads, reserve.threads, session_slots)
	processor, cpu_ok := share(machine_available.processor, reserve.processor, session_slots)
	log_records, log_ok := share(machine_available.log_records, reserve.log_records, session_slots)
	storage_blocks, blk_ok := share(machine_available.storage_blocks, reserve.storage_blocks, session_slots)
	if !pages_ok || !proc_ok || !thr_ok || !cpu_ok || !log_ok || !blk_ok {
		return {}, false
	}
	return {
		pages          = pages,
		processes      = processes,
		threads        = threads,
		processor      = processor,
		log_records    = log_records,
		storage_blocks = storage_blocks,
	}, true
}

// Per-session storage block ledger enforcing that a session's stores never
// exceed its reserved block budget and total reserved blocks never exceed the
// disk capacity.
Session_Block_Ledger :: struct {
	limit: u64,
	used:  u64,
}

// ledger_init sets the block ceiling of one session. Refuses 0.
ledger_init :: proc "contextless" (ledger: ^Session_Block_Ledger, limit: u64) -> bool {
	if ledger == nil || limit == 0 {
		return false
	}
	ledger^ = {limit = limit, used = 0}
	return true
}

// ledger_reserve charges `blocks` to the session ledger. Refuses 0, overflow,
// or any amount past `ledger.limit` without mutating `ledger.used`.
ledger_reserve :: proc "contextless" (ledger: ^Session_Block_Ledger, blocks: u64) -> bool {
	if ledger == nil || blocks == 0 || blocks > ledger.limit || ledger.used > ledger.limit - blocks {
		return false
	}
	ledger.used += blocks
	return true
}

// ledger_release returns `blocks` to the session ledger. Refuses 0 or more
// than currently used without mutating `ledger.used`.
ledger_release :: proc "contextless" (ledger: ^Session_Block_Ledger, blocks: u64) -> bool {
	if ledger == nil || blocks == 0 || blocks > ledger.used {
		return false
	}
	ledger.used -= blocks
	return true
}

// ledger_remaining returns unused blocks remaining in the session's quota.
ledger_remaining :: proc "contextless" (ledger: ^Session_Block_Ledger) -> u64 {
	if ledger == nil || ledger.used > ledger.limit {
		return 0
	}
	return ledger.limit - ledger.used
}
