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

// Machine reserve floors held back for principal 0 and joint processes so no
// named session can starve the root service, display holder, or unlock.
// Computed from observed machine baseline: root + compositor + storage + log +
// unlock + drivers fit comfortably within these reserves.
DEFAULT_MACHINE_RESERVE :: Session_Budget_Amounts {
	pages          = 8192,
	processes      = 24,
	threads        = 48,
	processor      = 4_000_000,
	log_records    = 200,
	storage_blocks = 4096,
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
