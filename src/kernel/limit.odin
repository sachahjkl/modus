package kernel

import "base:intrinsics"

// The limits of a budget: processor time and log records. A program cannot
// take all the processor time or fill the log: each resource has a limit.
//
// Pages, programs and threads are things that a budget holds: they move
// from a budget to a new budget, and they return. The log records of each
// second move in the same way: a new budget takes its records of each
// second from the budget that it came from, and gives them back at its end,
// so no budget learns from a refusal what another one wrote (budget_log).
//   log_records: records that the budget can write on the log in each second.
// Processor time is a limit for each second:
//   processor:   microseconds of processor time in each second, on all the
//                processors together. 1 000 000 is one full processor.
// It is for a budget and for each budget that came from it: the kernel
// counts what a thread uses in the budget of the thread and in each budget
// above it. A new budget cannot have a limit above the limit of the budget
// that it came from. A budget with the limit 0 has no time: its threads do
// not run.
//
// The kernel counts processor time with the cycle counter, from the moment
// when a processor takes a thread to the moment when it leaves it: the time
// of the kernel entries of the thread is time of the thread. The limit
// holds in each period of 100 ms. What a budget used above its part of a
// period, it has less in the next period: over many periods the limit is
// exact.
//
// A period starts at the first tick that is 100 ms or more after the start
// of the period before, and a tick can come late: a machine that runs
// under another system loses time. The kernel measures the true length of
// each period with the cycle counter. A budget has its part of the true
// length: a late tick takes time from no budget.
//
// No lock protects these counts: each one is an atomic word (docs/
// ARCHITECTURE.md, "Locks of the kernel", "Budgets and the tick"). The tick
// reads the chain of budgets with no lock: `parent` changes only when a
// budget ends, and the slot of a budget that ended is used again only after
// processor_sync to all processors (budget_create).
LIMIT_PERIOD :: 100 // Milliseconds.
LOG_PERIOD :: 1000 // Milliseconds.

// budget_charge counts the time of the thread of a processor, up to now,
// and gives it: the strategy charges the same time (strategy.odin).
budget_charge :: proc "contextless" (cpu: ^Processor) -> (spent: u64) {
	now := cycles_now()
	spent = now - cpu.charged_from
	cpu.charged_from = now
	if cpu.current == 0 {
		return 0
	}
	for index := intrinsics.atomic_load(&threads[cpu.current].budget); index != 0; index = intrinsics.atomic_load(&budgets[index].parent) {
		intrinsics.atomic_add(&budgets[index].spent, spent)
		intrinsics.atomic_add(&budgets[index].spent_total, spent)
	}
	return spent
}

period_start: u64 // The cycle counter at the start of this period.
period_time: u64 // The milliseconds at the start of this period. Only the first processor reads and writes it.

// The cycles of this period that a budget can use: its part of the length
// of a period, or of the true length when the period is longer.
@(private = "file")
allowance :: proc "contextless" (budget: ^Budget) -> u64 {
	now := cycles_now()
	start := intrinsics.atomic_load(&period_start)
	length := max(cycle_frequency * LIMIT_PERIOD / 1000, now > start ? now - start : 0)
	// A whole day in one period does not overflow, with 64 processors.
	return budget.amounts.processor * (length / 1000) / 1000
}

// budget_spent says if a budget, or a budget above it, has no processor
// time left in this period.
budget_spent :: proc "contextless" (index: u32) -> bool {
	for at := index; at != 0; at = intrinsics.atomic_load(&budgets[at].parent) {
		if intrinsics.atomic_load(&budgets[at].spent) >= allowance(&budgets[at]) {
			return true
		}
	}
	return false
}

// budget_period starts a new period, at a tick of the first processor.
// Only this processor subtracts from `spent`; the others only add. So
// `spent` is at least the value read when the subtraction happens.
budget_period :: proc "contextless" (now: u64) {
	if now - period_time >= LIMIT_PERIOD {
		period_time = now
		refreshed := false
		for &budget in budgets[1:] {
			part := allowance(&budget)
			spent := intrinsics.atomic_load(&budget.spent)
			if spent >= part {
				refreshed = true
			}
			intrinsics.atomic_sub(&budget.spent, min(spent, part))
		}
		intrinsics.atomic_store(&period_start, cycles_now())
		if refreshed {
			// Threads of these budgets can run again: the idle processors look.
			kick_all()
		}
	}
}

// budget_log_count_to_child moves into a new budget the part of the count
// of this second of its parent that the parent's new amount no longer
// holds, at most the amount of the child. Without it, a child would start
// at 0, and a loop of starts and stops of a child would write past the
// amount of its starter in one second. The caller holds the frame lock and
// subtracted the amount of the child from the parent before.
budget_log_count_to_child :: proc "contextless" (parent: u32, child: u32) {
	second := intrinsics.atomic_load(&time_milliseconds) / LOG_PERIOD
	from := &budgets[parent]
	left := intrinsics.atomic_load(&from.amounts.log_records)
	child_amount := budgets[child].amounts.log_records
	for {
		word := intrinsics.atomic_load(&from.logged)
		count := word >> 32 == second ? word & 0xFFFF_FFFF : 0
		part := min(child_amount, count > left ? count - left : 0)
		if part == 0 {
			return
		}
		if _, swapped := intrinsics.atomic_compare_exchange_strong(&from.logged, word, second << 32 | (count - part)); swapped {
			intrinsics.atomic_store(&budgets[child].logged, second << 32 | part)
			return
		}
	}
}

// budget_log_count_to_parent adds the count of this second of a budget that
// ends to its parent, as its amount returns: the records that it wrote in
// this second stay spent. The caller holds the frame lock.
budget_log_count_to_parent :: proc "contextless" (index: u32, parent: u32) {
	second := intrinsics.atomic_load(&time_milliseconds) / LOG_PERIOD
	word := intrinsics.atomic_load(&budgets[index].logged)
	if word >> 32 != second || word & 0xFFFF_FFFF == 0 {
		return
	}
	part := word & 0xFFFF_FFFF
	to := &budgets[parent]
	for {
		parent_word := intrinsics.atomic_load(&to.logged)
		count := parent_word >> 32 == second ? parent_word & 0xFFFF_FFFF : 0
		if _, swapped := intrinsics.atomic_compare_exchange_strong(&to.logged, parent_word, second << 32 | (count + part)); swapped {
			return
		}
	}
}

// budget_log counts the log records of one Log of a program in the budget
// that pays for it: all of them, or none. false: the budget has not that
// many records left in this second. The word
// `logged` holds the second in its high 32 bits and the count of that
// second in its low 32 bits: a new second starts at 0 with no reset by
// another processor.
//
// The log records of each second are an amount that a budget holds, as its
// pages: Budget_Create moves them to the new budget, and the end of the
// budget gives them back. So a budget counts only its own records, and the
// records of a tree of budgets are still at most the amount of its top. A
// count in each budget above would tell a program, by a refusal, that the
// others wrote much (src/md/features/log_side_channels.md).
budget_log :: proc "contextless" (index: u32, records: u64) -> bool {
	// Budget 0 is no budget: it holds what returned to no budget, and a
	// program whose budgets all ended counts nowhere, as a processor time
	// that no budget charges.
	if index == 0 {
		return true
	}
	second := intrinsics.atomic_load(&time_milliseconds) / LOG_PERIOD
	budget := &budgets[index]
	// One read: Budget_Create and the end of a child change the amount
	// under the frame lock, and a record checked against a value that held
	// is right.
	limit := intrinsics.atomic_load(&budget.amounts.log_records)
	for {
		word := intrinsics.atomic_load(&budget.logged)
		count := word >> 32 == second ? word & 0xFFFF_FFFF : 0
		if count + records > limit {
			intrinsics.atomic_add(&budget.refused, records)
			return false
		}
		if _, swapped := intrinsics.atomic_compare_exchange_strong(&budget.logged, word, second << 32 | (count + records)); swapped {
			return true
		}
	}
}
