// Pure freestanding hardware fault containment (#MC / NMI single-process stop),
// PMU branch-count deterministic interrupt placement, counted-kernel counter-set
// ring, per-procedure fuzzing coverage bitset, and 2-CPU SMP fuzzing trace.
package kernel_fault_isolation

import "modus:contract/enum_word"

// IA32_MCi_STATUS bits (Intel SDM Vol 3B).
MC_STATUS_VAL   :: u64(1) << 63 // Valid bank
MC_STATUS_UC    :: u64(1) << 61 // Uncorrected error
MC_STATUS_PCC   :: u64(1) << 57 // Processor Context Corrupt (fatal)
MC_STATUS_S     :: u64(1) << 56 // Signaling (AR/AO)
MC_STATUS_AR    :: u64(1) << 55 // Action Required (recoverable if user ring)

Fault_Action :: enum u8 {
	Ignore_Corrected   = 1,
	Kill_User_Process  = 2,
	Halt_Machine       = 3,
}

fault_action_of_word :: proc "contextless" (word: u64) -> (a: Fault_Action, ok: bool) {
	return enum_word.member_of_word(Fault_Action, word)
}

// classify_machine_check determines whether an #MC or NMI bank status can be
// safely contained by terminating only the interrupted user-ring process
// (CPL == 3, PCC == 0, RIPV/EIPV valid) or must halt the whole machine.
classify_machine_check :: proc "contextless" (
	mci_status: u64,
	in_user_ring: bool,
	rip_valid: bool,
	addr_valid: bool,
) -> Fault_Action {
	if (mci_status & MC_STATUS_VAL) == 0 {
		return .Ignore_Corrected
	}
	if (mci_status & MC_STATUS_UC) == 0 {
		return .Ignore_Corrected
	}
	if (mci_status & MC_STATUS_PCC) != 0 {
		return .Halt_Machine
	}
	if in_user_ring && rip_valid && addr_valid && (mci_status & MC_STATUS_S) != 0 {
		return .Kill_User_Process
	}
	return .Halt_Machine
}

// ============================================================================
// Branch-count deterministic interrupt placement for record & replay
// ============================================================================

Branch_Interrupt_Point :: struct {
	retired_branches: u64,
	instruction_ptr:  u64,
	vector:           u8,
}

branch_interrupt_matches :: proc "contextless" (target: Branch_Interrupt_Point, current_branches, current_rip: u64) -> bool {
	return current_branches == target.retired_branches && current_rip == target.instruction_ptr
}

// ============================================================================
// Counted-kernel counter-set ring & per-procedure fuzzing coverage + 2-CPU SMP
// ============================================================================

COUNTER_RING_SLOTS :: 16
MAX_TRACKED_PROCS :: 512

Counter_Set_Summary :: struct {
	sequence:       u64,
	edges_hit:      u32,
	new_edges:      u32,
	smp_interleave: u16, // Bitmask of CPU0/CPU1 turn transitions
}

Counter_Ring :: struct {
	slots:     [COUNTER_RING_SLOTS]Counter_Set_Summary,
	write_idx: u64,
	dropped:   u64,
	proc_hits: [MAX_TRACKED_PROCS / 64]u64,
}

counter_ring_init :: proc "contextless" (r: ^Counter_Ring) {
	if r == nil {
		return
	}
	r^ = {}
}

counter_ring_push :: proc "contextless" (r: ^Counter_Ring, summary: Counter_Set_Summary) -> bool {
	if r == nil {
		return false
	}
	idx := r.write_idx % COUNTER_RING_SLOTS
	r.slots[idx] = summary
	r.write_idx += 1
	return true
}

procedure_coverage_mark :: proc "contextless" (r: ^Counter_Ring, proc_id: u32) -> (is_new: bool) {
	if r == nil || proc_id >= MAX_TRACKED_PROCS {
		return false
	}
	word := proc_id / 64
	bit := u64(1) << (proc_id % 64)
	was := (r.proc_hits[word] & bit) != 0
	r.proc_hits[word] |= bit
	return !was
}

procedure_coverage_count :: proc "contextless" (r: ^Counter_Ring) -> int {
	if r == nil {
		return 0
	}
	total := 0
	for w in r.proc_hits {
		x := w
		for x != 0 {
			x &= x - 1
			total += 1
		}
	}
	return total
}
