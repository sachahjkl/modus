// Contract for update-surviving TPM seals and owner hierarchy protection
// (src/md/features/tpm_sealed_machine_key.md, "The seal across an update").
//
// Defines the region layout and border validation of Update_Policy_Bundle for
// Seal_Authorized, Unseal_Authorized, and Owner_Protect. Allocates no memory
// and calls no kernel operation.
package tpm_service

import "modus:contract/enum_word"
import "modus:contract/tpm_attestation"
import "modus:contract/tpm_policy"

// Format property: offset in the 4 KiB TPM region holding Update_Policy_Bundle,
// placed after REGION_PIN (2560 + 160 = 2720), aligned to 32 bytes.
REGION_UPDATE_POLICY :: 2752

// Format property: P-256 coordinate and ECDSA component byte width.
UPDATE_POLICY_P256_BYTES :: 32

// Format property: TPM NV index range allocated for modus rollback floors.
FLOOR_NV_INDEX_MIN :: u32(0x0180_6D00)
FLOOR_NV_INDEX_MAX :: u32(0x0180_6D40)

// Closed set of seal policy modes supported by the TPM service.
Seal_Policy :: enum u64 {
	Exact_Pcrs        = 0,
	Authorized_Update = 1,
}

// Closed set of refusal reasons when checking Update_Policy_Bundle at the border.
Update_Policy_Refusal :: enum u8 {
	None                       = 0,
	Zero_Publisher_Key         = 1,
	Zero_Policy_Ref            = 2,
	Zero_Approved_Policy       = 3,
	Zero_Signature             = 4,
	Bad_Floor_Index            = 5,
	Zero_Floor_Bits            = 6,
	Key_Number_Out_Of_Range    = 7,
	Version_Floor_Out_Of_Range = 8,
}

// Fixed-layout publisher update-policy bundle transferred in the TPM region at
// REGION_UPDATE_POLICY for Seal_Authorized, Unseal_Authorized, and Owner_Protect.
Update_Policy_Bundle :: struct {
	publisher_x:         [UPDATE_POLICY_P256_BYTES]u8,
	publisher_y:         [UPDATE_POLICY_P256_BYTES]u8,
	policy_ref:          [tpm_attestation.SHA256_SIZE]u8,
	approved_policy:     [tpm_attestation.SHA256_SIZE]u8,
	signature_r:         [UPDATE_POLICY_P256_BYTES]u8,
	signature_s:         [UPDATE_POLICY_P256_BYTES]u8,
	version_floor_bits:  u64,
	version_floor_index: u32,
	key_number:          u32,
	version_floor:       u32,
	reserved:            u32,
}

#assert(size_of(Update_Policy_Bundle) == 216)
#assert(REGION_UPDATE_POLICY >= REGION_PIN + PIN_LIMIT)
#assert(REGION_UPDATE_POLICY + size_of(Update_Policy_Bundle) <= REGION_SIZE)

// seal_policy_of_word converts a transport word into a Seal_Policy at the border.
seal_policy_of_word :: proc "contextless" (word: u64) -> (policy: Seal_Policy, ok: bool) {
	return enum_word.member_of_word(Seal_Policy, word)
}

// update_policy_refusal_of_word converts a transport word into Update_Policy_Refusal.
update_policy_refusal_of_word :: proc "contextless" (word: u64) -> (refusal: Update_Policy_Refusal, ok: bool) {
	return enum_word.member_of_word(Update_Policy_Refusal, word)
}

@(private = "file")
slice_is_zero :: proc "contextless" (bytes: []u8) -> bool {
	acc: u8
	for b in bytes {
		acc |= b
	}
	return acc == 0
}

// update_policy_bundle_check validates every field of bundle at the TPM service
// border. require_approval is true for Unseal_Authorized (which checks the
// publisher signature and NV floor) and false for Seal_Authorized/Owner_Protect
// (which need only the publisher key and policy_ref to compute the authorized
// policy digest).
update_policy_bundle_check :: proc "contextless" (
	bundle: ^Update_Policy_Bundle,
	require_approval: bool,
) -> Update_Policy_Refusal {
	if bundle == nil || bundle.reserved != 0 {
		return .Zero_Publisher_Key
	}
	if slice_is_zero(bundle.publisher_x[:]) || slice_is_zero(bundle.publisher_y[:]) {
		return .Zero_Publisher_Key
	}
	if slice_is_zero(bundle.policy_ref[:]) {
		return .Zero_Policy_Ref
	}
	if bundle.key_number < tpm_policy.KEY_NUMBER_MIN || bundle.key_number > tpm_policy.KEY_NUMBER_MAX {
		return .Key_Number_Out_Of_Range
	}
	if bundle.version_floor < tpm_policy.NV_VERSION_FLOOR_MIN || bundle.version_floor > tpm_policy.NV_VERSION_FLOOR_MAX {
		return .Version_Floor_Out_Of_Range
	}
	if !require_approval {
		return .None
	}
	if slice_is_zero(bundle.approved_policy[:]) {
		return .Zero_Approved_Policy
	}
	if slice_is_zero(bundle.signature_r[:]) || slice_is_zero(bundle.signature_s[:]) {
		return .Zero_Signature
	}
	if bundle.version_floor_index < FLOOR_NV_INDEX_MIN || bundle.version_floor_index > FLOOR_NV_INDEX_MAX {
		return .Bad_Floor_Index
	}
	if bundle.version_floor_bits == 0 {
		return .Zero_Floor_Bits
	}
	return .None
}
