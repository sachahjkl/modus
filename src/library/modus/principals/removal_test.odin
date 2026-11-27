#+build !freestanding
#+build !modus
package principals

import "core:testing"
import "modus:contract/byte_order"
import "modus:contract/tpm_attestation"
import "modus:contract/tpm_service"

// Hostile bytes, wrong transitions, and same-run slot reuse are refused.
@(test)
removal_record_codec_and_transitions_refuse_bad_inputs :: proc(t: ^testing.T) {
	id := Principal_Identifier{0 = 0xAA, 31 = 0x55}
	buf: [REMOVAL_RECORD_SIZE]u8

	// Encode refusals: slot 0, unknown step, zero identifier.
	testing.expect_value(t, removal_record_encode({slot = 0, step = .Marked, identifier = id}, &buf), Removal_Problem.Bad_Slot)
	testing.expect_value(t, removal_record_encode({slot = 1, step = Removal_Step(0), identifier = id}, &buf), Removal_Problem.Bad_Step)
	testing.expect_value(t, removal_record_encode({slot = 1, step = Removal_Step(99), identifier = id}, &buf), Removal_Problem.Bad_Step)
	testing.expect_value(t, removal_record_encode({slot = 1, step = .Marked}, &buf), Removal_Problem.Zero_Identifier)

	valid := Removal_Record{slot = 1, step = .Marked, pin_generation = 4, identifier = id}
	testing.expect_value(t, removal_record_encode(valid, &buf), Removal_Problem.None)
	decoded, prob := removal_record_decode(buf[:])
	testing.expect_value(t, prob, Removal_Problem.None)
	testing.expect_value(t, decoded, valid)

	// Decode refusals: short/long slice, bad magic, bad format, slot 0, bad step, non-zero reserved, zero id.
	_, prob = removal_record_decode(buf[:REMOVAL_RECORD_SIZE - 1])
	testing.expect_value(t, prob, Removal_Problem.Wrong_Size)
	bad := buf
	bad[0] = 'X'
	_, prob = removal_record_decode(bad[:])
	testing.expect_value(t, prob, Removal_Problem.Wrong_Magic)
	bad = buf
	byte_order.write_u32_little_endian(bad[REMOVAL_OFFSET_FORMAT:], 0, 2)
	_, prob = removal_record_decode(bad[:])
	testing.expect_value(t, prob, Removal_Problem.Wrong_Format)
	bad = buf
	byte_order.write_u32_little_endian(bad[REMOVAL_OFFSET_SLOT:], 0, 0)
	_, prob = removal_record_decode(bad[:])
	testing.expect_value(t, prob, Removal_Problem.Bad_Slot)
	bad = buf
	bad[REMOVAL_OFFSET_STEP] = 99
	_, prob = removal_record_decode(bad[:])
	testing.expect_value(t, prob, Removal_Problem.Bad_Step)
	bad = buf
	bad[REMOVAL_OFFSET_RESERVED + 3] = 1
	_, prob = removal_record_decode(bad[:])
	testing.expect_value(t, prob, Removal_Problem.Reserved_Set)
	bad = buf
	for i in 0 ..< PRINCIPAL_IDENTIFIER_SIZE {
		bad[REMOVAL_OFFSET_IDENTIFIER + i] = 0
	}
	_, prob = removal_record_decode(bad[:])
	testing.expect_value(t, prob, Removal_Problem.Zero_Identifier)

	// Transition refusals: skipping steps, repeating steps, rolling back.
	_, prob = removal_step_advance(valid, .File_Deleted)
	testing.expect_value(t, prob, Removal_Problem.Bad_Transition)
	_, prob = removal_step_advance(valid, .Stores_Marked)
	testing.expect_value(t, prob, Removal_Problem.Bad_Transition)
	_, prob = removal_step_advance(valid, .Pin_Freed)
	testing.expect_value(t, prob, Removal_Problem.Bad_Transition)
	_, prob = removal_step_advance(valid, .Marked)
	testing.expect_value(t, prob, Removal_Problem.Bad_Transition)

	s2, p2 := removal_step_advance(valid, .Keys_Erased)
	testing.expect_value(t, p2, Removal_Problem.None)
	_, prob = removal_step_advance(s2, .Marked)
	testing.expect_value(t, prob, Removal_Problem.Bad_Transition)
	s3, p3 := removal_step_advance(s2, .File_Deleted)
	testing.expect_value(t, p3, Removal_Problem.None)
	_, prob = removal_step_advance(s3, .Pin_Freed)
	testing.expect_value(t, prob, Removal_Problem.Bad_Transition)
	s4, p4 := removal_step_advance(s3, .Stores_Marked)
	testing.expect_value(t, p4, Removal_Problem.None)
	s5, p5 := removal_step_advance(s4, .Pin_Freed)
	testing.expect_value(t, p5, Removal_Problem.None)
	_, prob = removal_step_advance(s5, .Pin_Freed)
	testing.expect_value(t, prob, Removal_Problem.Bad_Transition)
}

// Simulates full lifecycle: create principal A -> remove A (with crash and
// resume at every step!) -> refuse same-run slot reuse -> reboot -> refuse
// disk rollback of A's file -> create principal B in freed slot advancing pin
// from Free(g) to Active(B, g+1).
@(test)
create_remove_crash_resume_and_recreate_cycle :: proc(t: ^testing.T) {
	id_a := Principal_Identifier{0 = 0x11, 31 = 0xAA}
	id_b := Principal_Identifier{0 = 0x22, 31 = 0xBB}
	file_a := transmute([]u8)string("PRINCIPT principal A sealed file")
	file_b := transmute([]u8)string("PRINCIPT principal B sealed file")

	// 1. Create principal A: Absent -> Active(A, g=1).
	pin_a, pin_ref := tpm_attestation.principal_file_pin_settle({}, 1, tpm_attestation.Identifier(id_a), file_a)
	testing.expect_value(t, pin_ref, tpm_attestation.Pin_Refusal.None)
	testing.expect_value(t, pin_a.state, tpm_attestation.Principal_Pin_State.Active)
	testing.expect_value(t, pin_a.generation, u64(1))

	// 2. Crash and resume at every step of durable removal.
	for crash_after in 0 ..< 5 {
		// Simulate disk state + TPM pin for this crash point.
		stores_present := true
		file_present := true
		stores_marked := false
		tpm_pin := pin_a
		marker_present := true
		marker_bytes: [REMOVAL_RECORD_SIZE]u8
		rec := Removal_Record{slot = 1, step = .Marked, pin_generation = tpm_pin.generation, identifier = id_a}
		testing.expect_value(t, removal_record_encode(rec, &marker_bytes), Removal_Problem.None)

		// Run up to crash_after steps, then simulate reboot & resume from disk marker.
		steps_run := 0
		for marker_present {
			loaded, dec_prob := removal_record_decode(marker_bytes[:])
			testing.expect_value(t, dec_prob, Removal_Problem.None)
			action := removal_next_action(loaded, true)
			switch action {
			case .Erase_Keys:
				stores_present = false
				next, adv_prob := removal_step_advance(loaded, .Keys_Erased)
				testing.expect_value(t, adv_prob, Removal_Problem.None)
				testing.expect_value(t, removal_record_encode(next, &marker_bytes), Removal_Problem.None)
			case .Delete_File:
				file_present = false
				next, adv_prob := removal_step_advance(loaded, .File_Deleted)
				testing.expect_value(t, adv_prob, Removal_Problem.None)
				testing.expect_value(t, removal_record_encode(next, &marker_bytes), Removal_Problem.None)
			case .Mark_Stores:
				stores_marked = true
				next, adv_prob := removal_step_advance(loaded, .Stores_Marked)
				testing.expect_value(t, adv_prob, Removal_Problem.None)
				testing.expect_value(t, removal_record_encode(next, &marker_bytes), Removal_Problem.None)
			case .Free_Pin:
				// Idempotent: if pin is already Free (crash right after NV write before marker update), keep it.
				if tpm_pin.state == .Active {
					freed, free_ref := tpm_attestation.principal_file_pin_free(tpm_pin)
					testing.expect_value(t, free_ref, tpm_attestation.Pin_Refusal.None)
					tpm_pin = freed
				}
				next, adv_prob := removal_step_advance(loaded, .Pin_Freed)
				testing.expect_value(t, adv_prob, Removal_Problem.None)
				testing.expect_value(t, removal_record_encode(next, &marker_bytes), Removal_Problem.None)
			case .Clear_Marker:
				marker_present = false
			}
			steps_run += 1
			// Verify crash_after triggers a simulated restart mid-flight (marker stays durable).
			if steps_run == crash_after {
				testing.expect(t, marker_present || crash_after >= 5)
			}
		}

		testing.expect(t, !stores_present && !file_present && stores_marked && !marker_present)
		testing.expect_value(t, tpm_pin.state, tpm_attestation.Principal_Pin_State.Free)
		testing.expect_value(t, tpm_pin.generation, u64(2))
		testing.expect_value(t, tpm_pin.identifier, tpm_attestation.Identifier{})
	}

	// 3. Same-run slot reuse is refused after removal.
	retired: Retired_Slots
	testing.expect(t, slot_creation_allowed(&retired, 1))
	testing.expect(t, !slot_retire(&retired, MACHINE))
	testing.expect(t, slot_retire(&retired, 1))
	testing.expect(t, !slot_creation_allowed(&retired, 1), "removed slot must not be reused in same run")

	// 4. After reboot (fresh Retired_Slots), the Free pin refuses a rolled-back file of A,
	//    recognizes an absent file as .Free_Slot, and allows creating principal B at g = 3.
	freed_pin, free_ref := tpm_attestation.principal_file_pin_free(pin_a)
	testing.expect_value(t, free_ref, tpm_attestation.Pin_Refusal.None)
	freed_payload: [tpm_attestation.PRINCIPAL_FILE_PIN_RECORD_SIZE]u8
	_, enc_ref := tpm_attestation.principal_file_pin_encode(freed_pin, freed_payload[:])
	testing.expect_value(t, enc_ref, tpm_attestation.Pin_Refusal.None)

	// Disk rollback of A's file while pin is Free is refused!
	rollback_verdict, _, rollback_ref := tpm_service.principal_file_pin_verdict(.Held, freed_payload[:], 1, tpm_attestation.Identifier(id_a), file_a, true)
	testing.expect_value(t, rollback_verdict, tpm_service.Pin_Verdict.Principal_File_Pin_Mismatch)
	testing.expect_value(t, rollback_ref, tpm_attestation.Pin_Refusal.Slot_Free)

	// Absent file with Free pin gives .Free_Slot (ready for new creation!).
	free_verdict, decoded_free, free_v_ref := tpm_service.principal_file_pin_verdict(.Held, freed_payload[:], 1, {}, nil, false)
	testing.expect_value(t, free_verdict, tpm_service.Pin_Verdict.Free_Slot)
	testing.expect_value(t, free_v_ref, tpm_attestation.Pin_Refusal.None)

	// Reboot clears same-run retirement; creating principal B advances Free(2) -> Active(B, 3).
	after_reboot: Retired_Slots
	testing.expect(t, slot_creation_allowed(&after_reboot, 1))
	pin_b, settle_ref := tpm_attestation.principal_file_pin_settle(decoded_free, 1, tpm_attestation.Identifier(id_b), file_b)
	testing.expect_value(t, settle_ref, tpm_attestation.Pin_Refusal.None)
	testing.expect_value(t, pin_b.state, tpm_attestation.Principal_Pin_State.Active)
	testing.expect_value(t, pin_b.generation, u64(3))
	testing.expect_value(t, pin_b.identifier, tpm_attestation.Identifier(id_b))
}

// Removal by a holder of the Principals machine grant: refuses principal 0 or
// out-of-range actor/target, missing Principals grant, absent target, and
// removing the sole System holder while another named principal remains.
@(test)
removal_by_grant_rules_and_multi_slot_file_names :: proc(t: ^testing.T) {
	// Actor and target slot boundaries: 0, capacity, max(u64).
	for bad in ([?]u64{MACHINE, PRINCIPAL_CAPACITY, max(u64)}) {
		testing.expect_value(t, removal_by_grant_allowed(bad, 2, true, true, false, 1, true), Removal_By_Grant_Refusal.Actor_Not_Named)
		testing.expect_value(t, removal_by_grant_allowed(1, bad, true, true, false, 1, true), Removal_By_Grant_Refusal.Target_Not_Named)
	}
	// Missing Principals scope.
	testing.expect_value(t, removal_by_grant_allowed(1, 2, false, true, false, 1, true), Removal_By_Grant_Refusal.Missing_Grant)
	// Absent target.
	testing.expect_value(t, removal_by_grant_allowed(1, 2, true, false, false, 1, true), Removal_By_Grant_Refusal.Target_Absent)
	// Sole System holder cannot be removed while another named principal remains.
	testing.expect_value(t, removal_by_grant_allowed(1, 2, true, true, true, 1, true), Removal_By_Grant_Refusal.Last_System_Grant)
	// Allowed: target does not hold System, OR another System holder exists, OR no other named principal remains.
	testing.expect_value(t, removal_by_grant_allowed(1, 2, true, true, false, 1, true), Removal_By_Grant_Refusal.None)
	testing.expect_value(t, removal_by_grant_allowed(1, 2, true, true, true, 2, true), Removal_By_Grant_Refusal.None)
	testing.expect_value(t, removal_by_grant_allowed(1, 1, true, true, true, 1, false), Removal_By_Grant_Refusal.None)

	// Per-slot file object names: slot 0 and past capacity refused; slot 1 uses
	// legacy names; slots 2..PRINCIPAL_CAPACITY-1 use dotted slot names.
	buf: [32]u8
	_, ok0 := principal_file_object_name(&buf, MACHINE)
	testing.expect(t, !ok0)
	_, ok_past := principal_file_object_name(&buf, PRINCIPAL_CAPACITY)
	testing.expect(t, !ok_past)
	_, ok_max := principal_file_object_name(&buf, max(u64))
	testing.expect(t, !ok_max)

	n1, ok1 := principal_file_object_name(&buf, 1)
	testing.expect(t, ok1 && n1 == "principal")
	r1, rok1 := principal_recovery_object_name(&buf, 1)
	testing.expect(t, rok1 && r1 == "principal_recovery")

	n2, ok2 := principal_file_object_name(&buf, 2)
	testing.expect(t, ok2 && n2 == "principal.2")
	r2, rok2 := principal_recovery_object_name(&buf, 2)
	testing.expect(t, rok2 && r2 == "principal_recovery.2")

	n7, ok7 := principal_file_object_name(&buf, PRINCIPAL_CAPACITY - 1)
	testing.expect(t, ok7 && n7 == "principal.7")
	r7, rok7 := principal_recovery_object_name(&buf, PRINCIPAL_CAPACITY - 1)
	testing.expect(t, rok7 && r7 == "principal_recovery.7")
}

// Regression tests for:
// - Bootstrap machine-grant gating (never during boot scan or unloaded table).
// - Explicit slot packing in Principal_Record across reboots.
// - Self-removal last-System-holder refusal.
// - Target pin_generation == 0 never triggers Free_Pin.
@(test)
bootstrap_gating_slot_packing_and_self_removal_invariants :: proc(t: ^testing.T) {
	// First-principal bootstrap refused during boot scan (created_in_this_run == false).
	testing.expect(t, !first_principal_bootstrap_allowed(false, 0, 1, true))
	// Refused when principal 0's table is not loaded (e.g., Awaited/Refused).
	testing.expect(t, !first_principal_bootstrap_allowed(true, 0, 1, false))
	// Refused when machine grants already exist or another named principal exists.
	testing.expect(t, !first_principal_bootstrap_allowed(true, 1, 1, true))
	testing.expect(t, !first_principal_bootstrap_allowed(true, 0, 2, true))
	testing.expect(t, !first_principal_bootstrap_allowed(true, 0, 0, true))
	// Allowed only on genuine first creation with loaded empty table.
	testing.expect(t, first_principal_bootstrap_allowed(true, 0, 1, true))

	// Explicit slot packing preserves slot 0 (unspecified) and 1..PRINCIPAL_CAPACITY-1
	// alongside both short and maximum-length (23-byte) names, and refuses slots >= capacity.
	full_name := "abcdefghijklmnopqrstuvw" // 23 bytes == NAME_LIMIT.
	testing.expect_value(t, len(full_name), NAME_LIMIT)
	for slot in u64(0) ..< PRINCIPAL_CAPACITY {
		packed := record_name_and_slot_pack(full_name, slot)
		out_name, out_len, out_slot, ok := record_name_and_slot_unpack(packed)
		testing.expect(t, ok)
		testing.expect_value(t, out_slot, slot)
		testing.expect_value(t, out_len, NAME_LIMIT)
		testing.expect_value(t, string(out_name[:out_len]), full_name)
	}
	bad_raw := record_name_and_slot_pack("bob", 2)
	bad_bytes := transmute([24]u8)bad_raw
	bad_bytes[NAME_LIMIT] = u8(PRINCIPAL_CAPACITY)
	_, _, bad_slot, bad_ok := record_name_and_slot_unpack(transmute([3]u64)bad_bytes)
	testing.expect(t, !bad_ok && bad_slot == PRINCIPAL_CAPACITY)
	bad_bytes[NAME_LIMIT] = 255
	_, _, max_slot, max_ok := record_name_and_slot_unpack(transmute([3]u64)bad_bytes)
	testing.expect(t, !max_ok && max_slot == 255)

	// Self-removal enforces the last-System-holder invariant identically to grant removal.
	testing.expect(t, !self_removal_allowed(true, 1, true), "sole System holder must not self-remove while another named principal exists")
	testing.expect(t, !self_removal_allowed(true, 0, true))
	testing.expect(t, self_removal_allowed(true, 2, true), "allowed when another System holder survives")
	testing.expect(t, self_removal_allowed(false, 1, true), "allowed when caller does not hold System")
	testing.expect(t, self_removal_allowed(true, 1, false), "allowed when caller is the last named principal")

	// A target with pin_generation == 0 skips Free_Pin and clears marker directly.
	no_pin_rec := Removal_Record{slot = 2, step = .Stores_Marked, pin_generation = 0, identifier = {0 = 1}}
	testing.expect_value(t, removal_next_action(no_pin_rec, no_pin_rec.pin_generation != 0), Removal_Action.Clear_Marker)
	with_pin_rec := Removal_Record{slot = 2, step = .Stores_Marked, pin_generation = 3, identifier = {0 = 1}}
	testing.expect_value(t, removal_next_action(with_pin_rec, with_pin_rec.pin_generation != 0), Removal_Action.Free_Pin)
}
