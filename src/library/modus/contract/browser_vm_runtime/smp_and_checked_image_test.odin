#+build !freestanding
package browser_vm_runtime

import "core:testing"
import "modus:contract/blake3"

@(test)
browser_smp_enum_borders_and_init_refusals :: proc(t: ^testing.T) {
	_, ok_st := browser_cpu_state_of_word(99)
	testing.expect(t, !ok_st)
	st, ok_st2 := browser_cpu_state_of_word(u64(Browser_Cpu_State.Idle_Waiting))
	testing.expect(t, ok_st2 && st == .Idle_Waiting)

	_, ok_ipi := browser_ipi_kind_of_word(4)
	testing.expect(t, !ok_ipi)
	kind, ok_ipi2 := browser_ipi_kind_of_word(u64(Browser_Ipi_Kind.Tlb_Shootdown))
	testing.expect(t, ok_ipi2 && kind == .Tlb_Shootdown)

	_, ok_mask_bad := browser_ipi_mask_of_word(0x10)
	testing.expect(t, !ok_mask_bad)
	mask, ok_mask := browser_ipi_mask_of_word(0x03)
	testing.expect(t, ok_mask && mask == {.Reschedule, .Tlb_Shootdown})

	_, ok_ref := browser_smp_refusal_of_word(77)
	testing.expect(t, !ok_ref)

	// Nil and out-of-range CPU counts refused without mutation.
	testing.expect(t, browser_smp_init(nil, 2) == .Nil_Table)
	tbl: Browser_Smp_Table
	tbl.cpu_count = 3
	testing.expect(t, browser_smp_init(&tbl, 0) == .Invalid_Cpu_Count)
	testing.expect(t, browser_smp_init(&tbl, MAX_BROWSER_CPUS + 1) == .Invalid_Cpu_Count)
	testing.expect(t, tbl.cpu_count == 3)
}

@(test)
browser_smp_transitions_ipis_and_tlb_shootdown :: proc(t: ^testing.T) {
	tbl: Browser_Smp_Table
	testing.expect(t, browser_smp_init(&tbl, 4) == .None)
	testing.expect(t, tbl.slots[0].state == .Online)
	testing.expect(t, tbl.slots[1].state == .Offline)

	// One-time shared data-segment initialization claim.
	first, claim_ref1 := browser_smp_claim_data_segment_init(&tbl)
	second, claim_ref2 := browser_smp_claim_data_segment_init(&tbl)
	testing.expect(t, claim_ref1 == .None && first)
	testing.expect(t, claim_ref2 == .None && !second)

	// Out-of-range CPU and illegal state edges refused without mutation.
	testing.expect(t, browser_smp_transition_cpu(&tbl, 4, .Starting) == .Cpu_Out_Of_Range)
	testing.expect(t, browser_smp_transition_cpu(&tbl, 1, .Online) == .Invalid_Cpu_Transition)
	testing.expect(t, browser_smp_transition_cpu(&tbl, 1, .Idle_Waiting) == .Invalid_Cpu_Transition)
	testing.expect(t, browser_smp_transition_cpu(&tbl, 1, Browser_Cpu_State(99)) == .Invalid_Cpu_Transition)
	testing.expect(t, tbl.slots[1].state == .Offline)

	// Single-online-CPU shootdown completes immediately without deadlock.
	gen1, sd_ref1 := browser_smp_begin_tlb_shootdown(&tbl, 0, 0x1000, 0x4000)
	testing.expect(t, sd_ref1 == .None && gen1 == 1)
	testing.expect(t, browser_smp_shootdown_complete(&tbl))
	testing.expect(t, tbl.slots[0].last_tlb_generation == 1)

	// Bring CPUs 1 and 2 online; put CPU 2 into Idle_Waiting; halt CPU 3.
	testing.expect(t, browser_smp_transition_cpu(&tbl, 1, .Starting) == .None)
	testing.expect(t, browser_smp_transition_cpu(&tbl, 1, .Online) == .None)
	testing.expect(t, browser_smp_transition_cpu(&tbl, 2, .Starting) == .None)
	testing.expect(t, browser_smp_transition_cpu(&tbl, 2, .Online) == .None)
	testing.expect(t, browser_smp_transition_cpu(&tbl, 2, .Idle_Waiting) == .None)
	testing.expect(t, browser_smp_transition_cpu(&tbl, 3, .Starting) == .None)
	testing.expect(t, browser_smp_transition_cpu(&tbl, 3, .Halted) == .None)
	// Halted is terminal.
	testing.expect(t, browser_smp_transition_cpu(&tbl, 3, .Online) == .Invalid_Cpu_Transition)

	// IPI refusals: empty mask, unknown bit, halted target, idle sender, out-of-range.
	testing.expect(t, browser_smp_send_ipi(&tbl, 0, 1, {}) == .Empty_Ipi_Mask)
	bad_mask := transmute(Browser_Ipi_Mask)u32(0x80)
	testing.expect(t, browser_smp_send_ipi(&tbl, 0, 1, bad_mask) == .Unknown_Ipi_Bit)
	testing.expect(t, browser_smp_send_ipi(&tbl, 0, 3, {.Reschedule}) == .Cpu_Not_Ready)
	testing.expect(t, browser_smp_send_ipi(&tbl, 2, 1, {.Reschedule}) == .Cpu_Not_Ready)
	testing.expect(t, browser_smp_send_ipi(&tbl, 0, 4, {.Reschedule}) == .Cpu_Out_Of_Range)
	testing.expect(t, tbl.slots[1].wake_word == 0)

	// Valid IPI to idle CPU 2 bumps wake_word; taking IPIs wakes CPU 2 to Online.
	testing.expect(t, browser_smp_send_ipi(&tbl, 0, 2, {.Reschedule}) == .None)
	testing.expect(t, tbl.slots[2].wake_word == 1 && tbl.slots[2].ipi_pending == {.Reschedule})
	got_ipis, take_ref := browser_smp_take_ipis(&tbl, 2)
	testing.expect(t, take_ref == .None && got_ipis == {.Reschedule})
	testing.expect(t, tbl.slots[2].state == .Online && tbl.slots[2].ipi_pending == {})

	// Cross-CPU TLB shootdown from CPU 0 targets CPUs 1 and 2 (not halted CPU 3).
	gen2, sd_ref2 := browser_smp_begin_tlb_shootdown(&tbl, 0, 0x2000, 0x8000)
	testing.expect(t, sd_ref2 == .None && gen2 == 2)
	testing.expect(t, !browser_smp_shootdown_complete(&tbl))
	testing.expect(t, tbl.shootdown.target_mask == ((u32(1) << 1) | (u32(1) << 2)))

	// Overlapping shootdown refused while active.
	gen_overlap, ref_overlap := browser_smp_begin_tlb_shootdown(&tbl, 1, 0x2000, 0)
	testing.expect(t, gen_overlap == 0 && ref_overlap == .Shootdown_Already_Active)

	// Bad acks refused without mutating ack_mask.
	_, ref_bad_gen := browser_smp_ack_tlb_shootdown(&tbl, 1, 1)
	testing.expect(t, ref_bad_gen == .Generation_Mismatch)
	_, ref_self := browser_smp_ack_tlb_shootdown(&tbl, 0, 2)
	testing.expect(t, ref_self == .Already_Acknowledged)
	_, ref_halted := browser_smp_ack_tlb_shootdown(&tbl, 3, 2)
	testing.expect(t, ref_halted == .Cpu_Not_Ready)
	testing.expect(t, tbl.shootdown.ack_mask == 0)

	// CPU 1 acks -> still pending CPU 2; double ack from CPU 1 refused.
	done1, ack_ref1 := browser_smp_ack_tlb_shootdown(&tbl, 1, 2)
	testing.expect(t, ack_ref1 == .None && !done1)
	_, ack_dup := browser_smp_ack_tlb_shootdown(&tbl, 1, 2)
	testing.expect(t, ack_dup == .Already_Acknowledged)

	// CPU 2 acks -> shootdown completes; late ack refused.
	done2, ack_ref2 := browser_smp_ack_tlb_shootdown(&tbl, 2, 2)
	testing.expect(t, ack_ref2 == .None && done2 && browser_smp_shootdown_complete(&tbl))
	testing.expect(t, tbl.slots[1].last_tlb_generation == 2 && tbl.slots[2].last_tlb_generation == 2)
	_, ack_late := browser_smp_ack_tlb_shootdown(&tbl, 2, 2)
	testing.expect(t, ack_late == .No_Active_Shootdown)

	// Regression: halting a targeted CPU during an active shootdown satisfies
	// its target bit and completes the shootdown once all targets have acked or halted.
	gen3, sd_ref3 := browser_smp_begin_tlb_shootdown(&tbl, 0, 0x3000, 0xC000)
	testing.expect(t, sd_ref3 == .None && gen3 == 3 && !browser_smp_shootdown_complete(&tbl))
	// Halt CPU 1 while shootdown targets CPUs 1 and 2 -> CPU 1 auto-acked, still waiting on CPU 2.
	testing.expect(t, browser_smp_transition_cpu(&tbl, 1, .Halted) == .None)
	testing.expect(t, (tbl.shootdown.ack_mask & (u32(1) << 1)) != 0)
	testing.expect(t, tbl.slots[1].ipi_pending == {})
	testing.expect(t, !browser_smp_shootdown_complete(&tbl))
	// Halt CPU 2 (last remaining target) -> shootdown completes cleanly with no deadlock.
	testing.expect(t, browser_smp_transition_cpu(&tbl, 2, .Halted) == .None)
	testing.expect(t, browser_smp_shootdown_complete(&tbl))
	testing.expect(t, tbl.slots[2].ipi_pending == {})
	testing.expect(t, tbl.slots[2].last_tlb_generation == 3)
}

@(test)
checked_image_gate_init_and_wait_flow_verify_and_fail_closed :: proc(t: ^testing.T) {
	_, ok_st := image_file_verify_state_of_word(9)
	testing.expect(t, !ok_st)
	_, ok_dec := image_read_decision_of_word(0)
	testing.expect(t, !ok_dec)
	_, ok_ref := image_gate_refusal_of_word(42)
	testing.expect(t, !ok_ref)

	console_bytes := transmute([]u8)string("console-table-v1")
	log_bytes := transmute([]u8)string("log-schema-table-v1")
	manual_bytes := transmute([]u8)string("manual-index-v1")
	hashes := [3]blake3.Hash{
		blake3.hash(console_bytes),
		blake3.hash(log_bytes),
		blake3.hash(manual_bytes),
	}
	sizes := [3]u64{
		u64(len(console_bytes)),
		u64(len(log_bytes)),
		u64(len(manual_bytes)),
	}

	// Refusal checks on init: nil, empty, mismatched length, zero hash, zero size.
	testing.expect(t, checked_image_gate_init(nil, hashes[:], sizes[:]) == .Nil_Gate)
	gate: Checked_Image_File_Gate
	testing.expect(t, checked_image_gate_init(&gate, nil, nil) == .File_Count_Out_Of_Range)
	testing.expect(t, checked_image_gate_init(&gate, hashes[:], sizes[:2]) == .File_Count_Out_Of_Range)
	bad_hashes := hashes
	bad_hashes[1] = {}
	testing.expect(t, checked_image_gate_init(&gate, bad_hashes[:], sizes[:]) == .Zero_Expected_Hash)
	bad_sizes := sizes
	bad_sizes[2] = 0
	testing.expect(t, checked_image_gate_init(&gate, hashes[:], bad_sizes[:]) == .Invalid_Expected_Size)
	testing.expect(t, gate.file_count == 0)

	// Valid init sets all entries Unchecked.
	testing.expect(t, checked_image_gate_init(&gate, hashes[:], sizes[:]) == .None)
	testing.expect(t, !checked_image_gate_all_verified(&gate))

	// Holder IDs representing Image-grant holders: console=10, log=20, manual=30.
	CONSOLE_HOLDER :: u64(10)
	LOG_HOLDER :: u64(20)
	MANUAL_HOLDER :: u64(30)

	// Invalid holder ID 0 and out-of-range file index refused.
	_, _, bad_holder := checked_image_gate_request_read(&gate, 0, 0)
	testing.expect(t, bad_holder == .Invalid_Holder_Id)
	_, _, bad_idx := checked_image_gate_request_read(&gate, 3, CONSOLE_HOLDER)
	testing.expect(t, bad_idx == .File_Index_Out_Of_Range)

	// File 0 (console): first reader waits and triggers hashing.
	dec0, need_start0, req_ref0 := checked_image_gate_request_read(&gate, 0, CONSOLE_HOLDER)
	testing.expect(t, req_ref0 == .None && dec0 == .Wait && need_start0)

	// Finish before begin_hashing is refused.
	woken: [CHECKED_IMAGE_MAX_WAITERS_PER_FILE]u64
	_, _, early_fin := checked_image_gate_finish_hashing(&gate, 0, console_bytes, woken[:])
	testing.expect(t, early_fin == .Invalid_State_Transition)

	// Start hashing; second begin_hashing is refused.
	testing.expect(t, checked_image_gate_begin_hashing(&gate, 0) == .None)
	testing.expect(t, checked_image_gate_begin_hashing(&gate, 0) == .Invalid_State_Transition)

	// Concurrent readers (log, manual) wait without requesting a second hash;
	// duplicate request from console does not occupy a second waiter slot.
	dec1, need_start1, req_ref1 := checked_image_gate_request_read(&gate, 0, LOG_HOLDER)
	dec2, need_start2, req_ref2 := checked_image_gate_request_read(&gate, 0, MANUAL_HOLDER)
	dec_dup, need_dup, req_dup := checked_image_gate_request_read(&gate, 0, CONSOLE_HOLDER)
	testing.expect(t, req_ref1 == .None && dec1 == .Wait && !need_start1)
	testing.expect(t, req_ref2 == .None && dec2 == .Wait && !need_start2)
	testing.expect(t, req_dup == .None && dec_dup == .Wait && !need_dup)
	testing.expect(t, gate.entries[0].waiter_count == 3)

	// Undersized woken buffer refuses without mutating gate state or waiters.
	w_short, v_short, ref_short := checked_image_gate_finish_hashing(&gate, 0, console_bytes, woken[:2])
	testing.expect(t, w_short == 0 && !v_short && ref_short == .Output_Too_Small)
	testing.expect(t, gate.entries[0].state == .Hashing && gate.entries[0].waiter_count == 3)

	// Valid hash verification wakes all 3 holders and allows reads immediately.
	w_count, verified, fin_ref := checked_image_gate_finish_hashing(&gate, 0, console_bytes, woken[:])
	testing.expect(t, fin_ref == .None && verified && w_count == 3)
	testing.expect(t, woken[0] == CONSOLE_HOLDER && woken[1] == LOG_HOLDER && woken[2] == MANUAL_HOLDER)
	dec_allow, need_allow, req_allow := checked_image_gate_request_read(&gate, 0, CONSOLE_HOLDER)
	testing.expect(t, req_allow == .None && dec_allow == .Allow && !need_allow)

	// File 1 (log): tampered 1 byte must fail closed permanently.
	dec_l, need_l, ref_l := checked_image_gate_request_read(&gate, 1, LOG_HOLDER)
	testing.expect(t, ref_l == .None && dec_l == .Wait && need_l)
	testing.expect(t, checked_image_gate_begin_hashing(&gate, 1) == .None)
	tampered: [19]u8
	copy(tampered[:], log_bytes)
	tampered[5] ~= 0x01
	w_bad, v_bad, ref_bad := checked_image_gate_finish_hashing(&gate, 1, tampered[:], woken[:])
	testing.expect(t, ref_bad == .Hash_Mismatch && !v_bad && w_bad == 1 && woken[0] == LOG_HOLDER)
	st1, ok1 := checked_image_gate_state(&gate, 1)
	testing.expect(t, ok1 && st1 == .Refused)

	// Subsequent reads on failed file 1 deny closed; cannot restart hashing.
	dec_deny, need_deny, ref_deny := checked_image_gate_request_read(&gate, 1, MANUAL_HOLDER)
	testing.expect(t, ref_deny == .None && dec_deny == .Deny_Failed && !need_deny)
	testing.expect(t, gate.entries[1].denied_reads == 1)
	testing.expect(t, checked_image_gate_begin_hashing(&gate, 1) == .Invalid_State_Transition)

	// File 2 (manual): waiter queue capacity bound (8) refuses 9th distinct holder.
	for h in u64(100) ..< u64(100 + CHECKED_IMAGE_MAX_WAITERS_PER_FILE) {
		d, _, r := checked_image_gate_request_read(&gate, 2, h)
		testing.expect(t, r == .None && d == .Wait)
	}
	_, _, full_ref := checked_image_gate_request_read(&gate, 2, 999)
	testing.expect(t, full_ref == .Waiter_Queue_Full)

	// Explicit refusal of unchecked file wakes all 8 waiters and seals it Refused.
	w_refused, r_refused := checked_image_gate_refuse_file(&gate, 2, woken[:])
	testing.expect(t, r_refused == .None && w_refused == CHECKED_IMAGE_MAX_WAITERS_PER_FILE)
	st2, ok2 := checked_image_gate_state(&gate, 2)
	testing.expect(t, ok2 && st2 == .Refused)
	// Cannot refuse an already Verified or already Refused file.
	_, ref_verified := checked_image_gate_refuse_file(&gate, 0, woken[:])
	testing.expect(t, ref_verified == .Invalid_State_Transition)
	_, ref_again := checked_image_gate_refuse_file(&gate, 2, woken[:])
	testing.expect(t, ref_again == .Invalid_State_Transition)

	// Separate 2-file gate verifies all entries cleanly and reports all_verified.
	clean_gate: Checked_Image_File_Gate
	testing.expect(t, checked_image_gate_init(&clean_gate, hashes[:2], sizes[:2]) == .None)
	testing.expect(t, checked_image_gate_begin_hashing(&clean_gate, 0) == .None)
	_, ok_c0, r_c0 := checked_image_gate_finish_hashing(&clean_gate, 0, console_bytes, woken[:])
	testing.expect(t, r_c0 == .None && ok_c0 && !checked_image_gate_all_verified(&clean_gate))
	testing.expect(t, checked_image_gate_begin_hashing(&clean_gate, 1) == .None)
	_, ok_c1, r_c1 := checked_image_gate_finish_hashing(&clean_gate, 1, log_bytes, woken[:])
	testing.expect(t, r_c1 == .None && ok_c1 && checked_image_gate_all_verified(&clean_gate))
}
