#+build !freestanding
#+build !modus
package tpm_service

import "core:testing"
import "modus:contract/call_outcome"

@(test)
update_policy_bundle_and_ring_border_refusals :: proc(t: ^testing.T) {
	// Unknown enum words are refused at the border.
	_, ok := seal_policy_of_word(u64(max(Seal_Policy)) + 1)
	testing.expect(t, !ok)
	_, ok = seal_policy_of_word(max(u64))
	testing.expect(t, !ok)
	for m in Seal_Policy {
		got, m_ok := seal_policy_of_word(u64(m))
		testing.expect(t, m_ok && got == m)
	}

	// Ring source separation: Measure_Ring cannot call Seal_Authorized,
	// Unseal_Authorized, or Owner_Protect.
	for cmd in ([3]Command{.Seal_Authorized, .Unseal_Authorized, .Owner_Protect}) {
		_, outcome, _ := request_of_record(u32(cmd), {}, .Measure_Ring)
		testing.expect_value(t, outcome, call_outcome.Call_Outcome.Grant_Or_Right_Missing)
	}
	// Owner_Protect refuses any non-zero value word.
	for place in 0 ..< 7 {
		vals: [7]u64
		vals[place] = 1
		_, outcome, _ := request_of_record(u32(Command.Owner_Protect), vals, .Client_Ring)
		testing.expect_value(t, outcome, call_outcome.Call_Outcome.Argument_Refused)
	}
	req, out, _ := request_of_record(u32(Command.Owner_Protect), {}, .Client_Ring)
	testing.expect_value(t, out, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, req.command, Command.Owner_Protect)

	// Bad authorization words refused on Seal_Authorized and Unseal_Authorized.
	_, out, _ = request_of_record(u32(Command.Seal_Authorized), {0 = u64(max(Authorization)) + 1}, .Client_Ring)
	testing.expect_value(t, out, call_outcome.Call_Outcome.Argument_Refused)
	_, out, _ = request_of_record(u32(Command.Unseal_Authorized), {4 = max(u64)}, .Client_Ring)
	testing.expect_value(t, out, call_outcome.Call_Outcome.Argument_Refused)

	// Update_Policy_Bundle adversarial refusal checks.
	good := Update_Policy_Bundle {
		publisher_x         = {0 = 1},
		publisher_y         = {0 = 2},
		policy_ref          = {0 = 3},
		approved_policy     = {0 = 4},
		signature_r         = {0 = 5},
		signature_s         = {0 = 6},
		version_floor_bits  = 1,
		version_floor_index = FLOOR_NV_INDEX_MIN,
		key_number          = 1,
		version_floor       = 1,
	}
	testing.expect_value(t, update_policy_bundle_check(nil, false), Update_Policy_Refusal.Zero_Publisher_Key)

	bad := good; bad.publisher_x = {}
	testing.expect_value(t, update_policy_bundle_check(&bad, false), Update_Policy_Refusal.Zero_Publisher_Key)
	bad = good; bad.publisher_y = {}
	testing.expect_value(t, update_policy_bundle_check(&bad, false), Update_Policy_Refusal.Zero_Publisher_Key)
	bad = good; bad.reserved = 1
	testing.expect_value(t, update_policy_bundle_check(&bad, false), Update_Policy_Refusal.Zero_Publisher_Key)
	bad = good; bad.policy_ref = {}
	testing.expect_value(t, update_policy_bundle_check(&bad, false), Update_Policy_Refusal.Zero_Policy_Ref)
	bad = good; bad.key_number = 0
	testing.expect_value(t, update_policy_bundle_check(&bad, false), Update_Policy_Refusal.Key_Number_Out_Of_Range)
	bad = good; bad.key_number = 65
	testing.expect_value(t, update_policy_bundle_check(&bad, false), Update_Policy_Refusal.Key_Number_Out_Of_Range)
	bad = good; bad.version_floor = 0
	testing.expect_value(t, update_policy_bundle_check(&bad, false), Update_Policy_Refusal.Version_Floor_Out_Of_Range)
	bad = good; bad.version_floor = 65
	testing.expect_value(t, update_policy_bundle_check(&bad, false), Update_Policy_Refusal.Version_Floor_Out_Of_Range)

	// Approval fields are enforced when require_approval is true.
	bad = good; bad.approved_policy = {}
	testing.expect_value(t, update_policy_bundle_check(&bad, false), Update_Policy_Refusal.None)
	testing.expect_value(t, update_policy_bundle_check(&bad, true), Update_Policy_Refusal.Zero_Approved_Policy)
	bad = good; bad.signature_r = {}
	testing.expect_value(t, update_policy_bundle_check(&bad, true), Update_Policy_Refusal.Zero_Signature)
	bad = good; bad.signature_s = {}
	testing.expect_value(t, update_policy_bundle_check(&bad, true), Update_Policy_Refusal.Zero_Signature)
	bad = good; bad.version_floor_index = FLOOR_NV_INDEX_MIN - 1
	testing.expect_value(t, update_policy_bundle_check(&bad, true), Update_Policy_Refusal.Bad_Floor_Index)
	bad = good; bad.version_floor_index = FLOOR_NV_INDEX_MAX + 1
	testing.expect_value(t, update_policy_bundle_check(&bad, true), Update_Policy_Refusal.Bad_Floor_Index)
	bad = good; bad.version_floor_bits = 0
	testing.expect_value(t, update_policy_bundle_check(&bad, true), Update_Policy_Refusal.Zero_Floor_Bits)

	// Valid bundle passes both seal and unseal checks.
	testing.expect_value(t, update_policy_bundle_check(&good, false), Update_Policy_Refusal.None)
	testing.expect_value(t, update_policy_bundle_check(&good, true), Update_Policy_Refusal.None)
}
