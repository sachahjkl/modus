// Pure freestanding cross-thread hardware counter profiler and user-space
// external pager state machines
// (src/md/features/processor_counters.md).
//
// Zero dynamic allocations, zero kernel operations, strict bounds & W^X checks.
package processor_profiler

import "modus:contract/enum_word"
import op "modus:contract/operation"

MAX_PROFILED_THREADS :: 32

Counter_Sample :: struct {
	thread_id:    u64,
	cycles:       u64,
	instructions: u64,
	cache_misses: u64,
	branch_misses: u64,
}

Counter_Delta :: struct {
	cycles:                u64,
	instructions:          u64,
	cache_misses:          u64,
	branch_misses:         u64,
	ipc_milli:             u64, // instructions * 1000 / cycles
	cache_miss_per_k_inst: u64, // cache_misses * 1000 / instructions
}

Profiler_Refusal :: enum u8 {
	None              = 0,
	Nil_State         = 1,
	Invalid_Thread    = 2,
	Counter_Backwards = 3,
	Table_Full        = 4,
}

Profiler_Slot :: struct {
	active: bool,
	last:   Counter_Sample,
	total:  Counter_Delta,
	samples: u64,
}

Profiler_Session :: struct {
	slots: [MAX_PROFILED_THREADS]Profiler_Slot,
}

profiler_init :: proc "contextless" (p: ^Profiler_Session) {
	if p == nil {
		return
	}
	p^ = {}
}

// profiler_record_sample ingests a new monotonic hardware counter snapshot for
// sample.thread_id and returns the exact interval delta and fixed-point IPC.
profiler_record_sample :: proc "contextless" (p: ^Profiler_Session, sample: Counter_Sample) -> (delta: Counter_Delta, refusal: Profiler_Refusal) {
	if p == nil {
		return {}, .Nil_State
	}
	if sample.thread_id == 0 {
		return {}, .Invalid_Thread
	}
	free_idx := -1
	for &s, i in p.slots {
		if !s.active {
			if free_idx < 0 {
				free_idx = i
			}
			continue
		}
		if s.last.thread_id == sample.thread_id {
			if sample.cycles < s.last.cycles || sample.instructions < s.last.instructions || sample.cache_misses < s.last.cache_misses || sample.branch_misses < s.last.branch_misses {
				return {}, .Counter_Backwards
			}
			d := Counter_Delta{
				cycles        = sample.cycles - s.last.cycles,
				instructions  = sample.instructions - s.last.instructions,
				cache_misses  = sample.cache_misses - s.last.cache_misses,
				branch_misses = sample.branch_misses - s.last.branch_misses,
			}
			if d.cycles > 0 && d.instructions <= max(u64) / 1000 {
				d.ipc_milli = (d.instructions * 1000) / d.cycles
			}
			if d.instructions > 0 && d.cache_misses <= max(u64) / 1000 {
				d.cache_miss_per_k_inst = (d.cache_misses * 1000) / d.instructions
			}
			s.last = sample
			s.total.cycles += d.cycles
			s.total.instructions += d.instructions
			s.total.cache_misses += d.cache_misses
			s.total.branch_misses += d.branch_misses
			s.samples += 1
			return d, .None
		}
	}
	if free_idx < 0 {
		return {}, .Table_Full
	}
	p.slots[free_idx] = {active = true, last = sample, samples = 1}
	return {}, .None
}

// ============================================================================
// External User-Space Pager (answers target page faults with W^X enforcement)
// ============================================================================

MAX_PAGER_REGIONS :: 16
MAX_RESIDENT_PAGES :: 128

Pager_Action :: enum u8 {
	Refuse_Stop    = 0,
	Map_Zero_Page  = 1,
	Map_Back_Page  = 2,
}

pager_action_of_word :: proc "contextless" (word: u64) -> (a: Pager_Action, ok: bool) {
	return enum_word.member_of_word(Pager_Action, word)
}

Pager_Region :: struct {
	active:       bool,
	base_address: u64,
	page_count:   u64,
	writable:     bool,
	executable:   bool,
	backed:       bool,
}

External_Pager :: struct {
	regions:            [MAX_PAGER_REGIONS]Pager_Region,
	resident_addresses: [MAX_RESIDENT_PAGES]u64,
	resident_count:     int,
	faults_answered:    u64,
	faults_refused:     u64,
}

pager_init :: proc "contextless" (pg: ^External_Pager) {
	if pg == nil {
		return
	}
	pg^ = {}
}

// pager_add_region registers a managed virtual address range, enforcing W^X
// and strict user-half page-aligned bounds.
pager_add_region :: proc "contextless" (pg: ^External_Pager, base_addr, page_count: u64, writable, executable, backed: bool) -> bool {
	if pg == nil || page_count == 0 || (base_addr & (op.PAGE_SIZE - 1)) != 0 {
		return false
	}
	if writable && executable {
		return false // Strict W^X.
	}
	if page_count > op.USER_END / op.PAGE_SIZE || base_addr >= op.USER_END || page_count * op.PAGE_SIZE > op.USER_END - base_addr {
		return false
	}
	for &r in pg.regions {
		if !r.active {
			r = {active = true, base_address = base_addr, page_count = page_count, writable = writable, executable = executable, backed = backed}
			return true
		}
	}
	return false
}

// pager_handle_fault resolves a page fault address and access rights, refusing
// kernel addresses, unmapped regions, permission violations, or exhausted pool.
pager_handle_fault :: proc "contextless" (pg: ^External_Pager, fault_addr: u64, is_write, is_exec: bool) -> (action: Pager_Action, page_addr: u64) {
	if pg == nil || fault_addr >= op.USER_END {
		if pg != nil {
			pg.faults_refused += 1
		}
		return .Refuse_Stop, 0
	}
	aligned := fault_addr & ~u64(op.PAGE_SIZE - 1)
	for &r in pg.regions {
		if !r.active {
			continue
		}
		if aligned >= r.base_address && aligned - r.base_address < r.page_count * op.PAGE_SIZE {
			if (is_write && !r.writable) || (is_exec && !r.executable) {
				pg.faults_refused += 1
				return .Refuse_Stop, 0
			}
			// Record resident page if not already tracked.
			already := false
			for i in 0 ..< pg.resident_count {
				if pg.resident_addresses[i] == aligned {
					already = true
					break
				}
			}
			if !already {
				if pg.resident_count >= MAX_RESIDENT_PAGES {
					pg.faults_refused += 1
					return .Refuse_Stop, 0
				}
				pg.resident_addresses[pg.resident_count] = aligned
				pg.resident_count += 1
			}
			pg.faults_answered += 1
			return r.backed ? .Map_Back_Page : .Map_Zero_Page, aligned
		}
	}
	pg.faults_refused += 1
	return .Refuse_Stop, 0
}
