// Pure freestanding hardware fault containment (#MC / NMI single-process stop
// per Intel SDM Vol. 3B Machine-Check Software Error Recovery), PMU branch-count
// deterministic interrupt placement, and atomic counter-set ring.
package kernel_fault_isolation

import "base:intrinsics"
import "modus:contract/enum_word"

// IA32_MCi_STATUS bits (Intel SDM Vol 3B).
MC_STATUS_VAL  :: u64(1) << 63 // Valid bank
MC_STATUS_OVER :: u64(1) << 62 // Overflow (multiple errors; unrecoverable if UC)
MC_STATUS_UC   :: u64(1) << 61 // Uncorrected error
MC_STATUS_EN   :: u64(1) << 60 // Error reporting enabled
MC_STATUS_PCC  :: u64(1) << 57 // Processor Context Corrupt (fatal)
MC_STATUS_S    :: u64(1) << 56 // Signaling (AR/AO)
MC_STATUS_AR   :: u64(1) << 55 // Action Required

Fault_Action :: enum u8 {
	Ignore_Corrected  = 1,
	Kill_User_Process = 2,
	Halt_Machine      = 3,
}

fault_action_of_word :: proc "contextless" (word: u64) -> (a: Fault_Action, ok: bool) {
	return enum_word.member_of_word(Fault_Action, word)
}

// classify_machine_check classifies an IA32_MCi_STATUS bank strictly per Intel
// SDM Vol. 3B: requires software_error_recovery_supported (IA32_MCG_CAP.MCG_SER_P),
// OVER == 0, EN == 1, PCC == 0, S == 1, AR == 1, CPL == 3, and valid RIP/ADDR
// before isolating the fault to the interrupted user process.
classify_machine_check :: proc "contextless" (
	mci_status: u64,
	software_error_recovery_supported: bool,
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
	if !software_error_recovery_supported {
		return .Halt_Machine
	}
	if (mci_status & MC_STATUS_PCC) != 0 || (mci_status & MC_STATUS_OVER) != 0 || (mci_status & MC_STATUS_EN) == 0 {
		return .Halt_Machine
	}
	if (mci_status & MC_STATUS_S) != 0 && (mci_status & MC_STATUS_AR) == 0 {
		// Action Optional (S=1, AR=0): hardware recovered, no process kill needed.
		return .Ignore_Corrected
	}
	if in_user_ring && rip_valid && addr_valid && (mci_status & MC_STATUS_S) != 0 && (mci_status & MC_STATUS_AR) != 0 {
		return .Kill_User_Process
	}
	return .Halt_Machine
}

Branch_Interrupt_Point :: struct {
	retired_branches: u64,
	instruction_ptr:  u64,
	vector:           u8,
}

branch_interrupt_matches :: proc "contextless" (target: Branch_Interrupt_Point, current_branches, current_rip: u64) -> bool {
	return current_branches == target.retired_branches && current_rip == target.instruction_ptr
}

COUNTER_RING_SLOTS :: 16
MAX_TRACKED_PROCS :: 512

Counter_Set_Summary :: struct {
	sequence:       u64,
	edges_hit:      u32,
	new_edges:      u32,
	smp_interleave: u16,
}

Counter_Ring :: struct {
	slots:     [COUNTER_RING_SLOTS]Counter_Set_Summary,
	write_idx: u64,
	read_idx:  u64,
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
	w := intrinsics.atomic_load_explicit(&r.write_idx, .Relaxed)
	rd := intrinsics.atomic_load_explicit(&r.read_idx, .Acquire)
	if w - rd >= COUNTER_RING_SLOTS {
		intrinsics.atomic_add_explicit(&r.dropped, 1, .Relaxed)
		return false
	}
	r.slots[w % COUNTER_RING_SLOTS] = summary
	intrinsics.atomic_store_explicit(&r.write_idx, w + 1, .Release)
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
