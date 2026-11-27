// Local cross-principal signed grants on one machine
// (src/md/features/several_principals.md, "The rest").
//
// Two principals on the same machine share a store object, tree, or role
// contract through the exact Signed_Grant and Revocation_List contract used
// across machines (signed_grant.odin), with serving_machine_id set to the
// local machine's identifier. There is no second sharing mechanism.
//
// Contract package: imports base and contract packages only, calls no kernel
// operation, and allocates no memory.
package machine_mesh

import "modus:contract/principals_rules"

// Local directory record of one named principal on this machine.
Local_Principal_Entry :: struct {
	slot:               u64,
	root_public_key:    Principal_Root_Public_Key,
	signing_public_key: [PUBLIC_KEY_SIZE]u8,
}

// Closed refusal reasons specific to local cross-principal grant binding
// before delegating to signed_grant_check.
Local_Grant_Refusal :: enum u8 {
	None               = 0,
	Bad_Principal_Slot = 1, // Nil entry, principal 0, or zero public key.
	Self_Grant_Refused = 2, // Grantor and grantee name the same principal.
	Zero_Machine_Id    = 3, // Local machine identifier is all zero.
	Grant_Check_Failed = 4, // Delegated signed_grant_check refused the grant.
}

// local_signed_grant_check verifies a Signed_Grant shared between two distinct
// named principals on the same machine by constructing a single-entry active
// local Signed_Machine_List for `grantor` on `local_machine_id` and delegating
// directly to `signed_grant_check`.
local_signed_grant_check :: proc "contextless" (
	grant: ^Signed_Grant,
	grantor: ^Local_Principal_Entry,
	grantee: ^Local_Principal_Entry,
	local_machine_id: [PUBLIC_KEY_SIZE]u8,
	now_ms: u64,
	revocation_list: ^Revocation_List,
	verify_signature: Signature_Verify_Proc,
	user_data: rawptr = nil,
	revocation_scratch: []u8 = nil,
) -> (refusal: Local_Grant_Refusal, check_status: Grant_Check_Status) {
	if grant == nil || grantor == nil || grantee == nil {
		return .Bad_Principal_Slot, .Refused_Nil_Input
	}
	if grantor.slot == 0 || grantor.slot >= principals_rules.PRINCIPAL_CAPACITY {
		return .Bad_Principal_Slot, .Refused_Wrong_Grantor
	}
	if grantee.slot == 0 || grantee.slot >= principals_rules.PRINCIPAL_CAPACITY {
		return .Bad_Principal_Slot, .Refused_Wrong_Grantee
	}
	if key_is_zero(grantor.root_public_key) || key_is_zero(grantor.signing_public_key) || key_is_zero(grantee.root_public_key) {
		return .Bad_Principal_Slot, .Refused_Zero_Key
	}
	if grantor.slot == grantee.slot || keys_equal_constant_time(grantor.root_public_key, grantee.root_public_key) {
		return .Self_Grant_Refused, .Refused_Wrong_Grantee
	}
	if key_is_zero(local_machine_id) {
		return .Zero_Machine_Id, .Refused_Zero_Key
	}

	local_list: Signed_Machine_List
	local_list.principal_root_public_key = grantor.root_public_key
	local_list.sequence_number = 1
	local_list.entry_count = 1
	local_list.entries[0] = {
		machine_id         = local_machine_id,
		signing_public_key = grantor.signing_public_key,
		state              = .Active,
	}

	check_status = signed_grant_check(
		grant,
		&local_list,
		local_machine_id,
		grantee.root_public_key,
		now_ms,
		revocation_list,
		verify_signature,
		user_data,
		revocation_scratch,
	)
	if check_status != .Accepted {
		return .Grant_Check_Failed, check_status
	}
	return .None, .Accepted
}
