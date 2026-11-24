#+build !freestanding
package session_budgets

import "core:testing"
import op "modus:contract/operation"

@(test)
compute_session_budget_refuses_starvation_and_keeps_machine_reserve :: proc(t: ^testing.T) {
	machine := Session_Budget_Amounts {
		pages          = 131_072,
		processes      = 120,
		threads        = 256,
		processor      = 16_000_000,
		log_records    = 256 * op.LOG_RECORDS_OF_A_PROCESS,
		storage_blocks = 65536,
	}
	reserve := DEFAULT_MACHINE_RESERVE

	// Zero session slots refused.
	_, ok := compute_session_budget(machine, reserve, 0)
	testing.expect(t, !ok, "zero session slots must be refused")

	// Machine available <= reserve on any single resource is refused.
	too_small_pages := machine
	too_small_pages.pages = reserve.pages
	_, ok = compute_session_budget(too_small_pages, reserve, 1)
	testing.expect(t, !ok, "pages == reserve must be refused")

	too_small_procs := machine
	too_small_procs.processes = reserve.processes - 1
	_, ok = compute_session_budget(too_small_procs, reserve, 1)
	testing.expect(t, !ok, "processes < reserve must be refused")

	too_small_blocks := machine
	too_small_blocks.storage_blocks = reserve.storage_blocks
	_, ok = compute_session_budget(too_small_blocks, reserve, 1)
	testing.expect(t, !ok, "storage_blocks == reserve must be refused")

	// Too many slots leaving 0 per session on any resource is refused.
	_, ok = compute_session_budget(machine, reserve, 1000)
	testing.expect(t, !ok, "slots exceeding spare processes must be refused")

	// Valid allocations keep strict machine reserve for 1 and 4 named sessions.
	for slots in ([?]u64{1, 2, 4}) {
		per, fit := compute_session_budget(machine, reserve, slots)
		testing.expect(t, fit)
		testing.expect(t, per.pages * slots + reserve.pages <= machine.pages)
		testing.expect(t, per.processes * slots + reserve.processes <= machine.processes)
		testing.expect(t, per.threads * slots + reserve.threads <= machine.threads)
		testing.expect(t, per.processor * slots + reserve.processor <= machine.processor)
		testing.expect(t, per.log_records * slots + reserve.log_records <= machine.log_records)
		testing.expect(t, per.storage_blocks * slots + reserve.storage_blocks <= machine.storage_blocks)
		// A session never gets 100% of machine resources.
		testing.expect(t, per.pages < machine.pages)
		testing.expect(t, per.processes < machine.processes)
		testing.expect(t, per.storage_blocks < machine.storage_blocks)
	}

	// Small-host scaling: 1-CPU, 2-CPU, and 4-CPU machines all reserve a strict
	// machine floor and open a positive session budget.
	for cpus in ([?]u64{1, 2, 4}) {
		small := machine
		small.processor = cpus * 1_000_000
		scaled_reserve := machine_reserve_for(small)
		per, fit := compute_session_budget(small, scaled_reserve, 1)
		testing.expect(t, fit, "1..4 CPU machine must open a bounded session budget")
		testing.expect(t, scaled_reserve.processor > 0 && per.processor > 0)
		testing.expect(t, per.processor + scaled_reserve.processor <= small.processor)
		testing.expect(t, per.processor < small.processor)
	}

	// Machine reserve keeps enough log records for root plus every reserved
	// machine process slot, and enough pages for the shared disk-process
	// budget plus on-demand machine services.
	real_reserve := machine_reserve_for(machine)
	testing.expect(t, real_reserve.log_records >= (DEFAULT_MACHINE_RESERVE_PROCESSES + 1) * op.LOG_RECORDS_OF_A_PROCESS)
	testing.expect(t, real_reserve.pages >= 65_536)

	// Starvation guard: 0 or 1 unit on any resource is still refused even with scaling.
	starved := machine
	starved.processor = 1
	_, ok = compute_session_budget(starved, machine_reserve_for(starved), 1)
	testing.expect(t, !ok, "1 unit available must still be refused")
}

@(test)
session_block_ledger_hits_session_limit_before_machine_limit :: proc(t: ^testing.T) {
	ledger: Session_Block_Ledger
	testing.expect(t, !ledger_init(nil, 100))
	testing.expect(t, !ledger_init(&ledger, 0))
	testing.expect(t, ledger_init(&ledger, 1024))
	testing.expect_value(t, ledger_remaining(&ledger), u64(1024))

	// Refusals: zero, past limit, max(u64).
	testing.expect(t, !ledger_reserve(&ledger, 0))
	testing.expect(t, !ledger_reserve(&ledger, 1025))
	testing.expect(t, !ledger_reserve(&ledger, max(u64)))
	testing.expect_value(t, ledger.used, u64(0))

	// Reserve up to exact session limit, then 1 more block is refused.
	testing.expect(t, ledger_reserve(&ledger, 600))
	testing.expect(t, ledger_reserve(&ledger, 424))
	testing.expect_value(t, ledger_remaining(&ledger), u64(0))
	testing.expect(t, !ledger_reserve(&ledger, 1), "1 block past session limit must be refused")
	testing.expect(t, !ledger_reserve(&ledger, max(u64)), "overflow past session limit must be refused")
	testing.expect_value(t, ledger.used, u64(1024))

	// Release refusals (0, > used), then valid release and re-reserve.
	testing.expect(t, !ledger_release(&ledger, 0))
	testing.expect(t, !ledger_release(&ledger, 1025))
	testing.expect(t, ledger_release(&ledger, 424))
	testing.expect_value(t, ledger_remaining(&ledger), u64(424))
	testing.expect(t, ledger_reserve(&ledger, 424))
	testing.expect_value(t, ledger_remaining(&ledger), u64(0))
}
