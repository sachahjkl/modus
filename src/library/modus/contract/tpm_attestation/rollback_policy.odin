// Anti-rollback NV counter state and TPM2_PolicyAuthorize floor policy
// verification (src/md/features/rollback_floors.md).
//
// Two mechanisms prevent state and image rollback:
// 1. A strictly monotonic disk-grant-table counter (next > last_seen),
//    refusing replays (==) and rollbacks (<).
// 2. TPM2_PolicyAuthorize verification under a pinned publisher key digest,
//    computing the authorized policy digest independently of PCR 7 while
//    refusing any key number or policy version below the current floor.
package tpm_attestation

// Bounds for publisher key numbers and policy security versions (64-bit NV
// bit-field floor indices in the TPM).
FLOOR_MIN_VERSION :: u32(1)
FLOOR_MAX_VERSION :: u32(64)

// TPM 2.0 command code for TPM2_PolicyAuthorize (TPM 2.0 Part 2).
COMMAND_POLICY_AUTHORIZE :: u32(0x0000_016A)

// Domain prefix separating publisher policy approvals from other signatures.
POLICY_APPROVAL_DOMAIN :: "MODUS_POLICY_AUTHORIZE_V1"

// Closed set of refusals for anti-rollback counters and policy authorization.
Rollback_Refusal :: enum u8 {
	None                       = 0,
	Not_Initialized            = 1,
	Zero_Publisher_Key         = 2,
	Counter_Zero               = 3,
	Counter_Replay             = 4,
	Counter_Rollback           = 5,
	Key_Number_Out_Of_Range    = 6,
	Key_Number_Below_Floor     = 7,
	Policy_Version_Out_Of_Range = 8,
	Policy_Version_Below_Floor = 9,
	Zero_Policy_Digest         = 10,
	Missing_Verifier           = 11,
	Signature_Invalid          = 12,
}

// Signed publisher statement authorizing an approved policy digest for a
// specific key number and policy security version.
Approved_Policy_Statement :: struct {
	key_number:      u32,
	policy_version:  u32,
	approved_policy: Digest,
	policy_ref:      Digest,
}

// Caller-provided signature verifier for publisher policy authorizations.
Policy_Signature_Verify_Proc :: #type proc "contextless" (
	publisher_key_digest: Digest,
	approval_digest: Digest,
	signature: []u8,
	user_data: rawptr,
) -> bool

// Monotonic anti-rollback floor and TPM2_PolicyAuthorize state.
Rollback_Floor_State :: struct {
	initialized:              bool,
	last_grant_table_counter: u64,
	key_floor:                u32,
	version_floor:            u32,
	publisher_key_digest:     Digest,
	active_policy_digest:     Digest,
}

// rollback_floor_init initializes the anti-rollback floor state.
// Refuses an all-zero publisher key digest or out-of-range floors without
// modifying state.
rollback_floor_init :: proc "contextless" (
	state: ^Rollback_Floor_State,
	publisher_key_digest: Digest,
	initial_counter: u64,
	initial_key_floor: u32,
	initial_version_floor: u32,
) -> Rollback_Refusal {
	key := publisher_key_digest
	if is_all_zero(key[:]) {
		return .Zero_Publisher_Key
	}
	if initial_key_floor > FLOOR_MAX_VERSION {
		return .Key_Number_Out_Of_Range
	}
	if initial_version_floor > FLOOR_MAX_VERSION {
		return .Policy_Version_Out_Of_Range
	}
	state^ = Rollback_Floor_State {
		initialized              = true,
		last_grant_table_counter = initial_counter,
		key_floor                = initial_key_floor,
		version_floor            = initial_version_floor,
		publisher_key_digest     = key,
		active_policy_digest     = {},
	}
	return .None
}

// rollback_floor_advance_counter validates and advances the monotonic
// disk-grant-table counter. Strictly requires next_counter > last_seen;
// refuses zero, replay (==), and rollback (<) without mutating state.
rollback_floor_advance_counter :: proc "contextless" (
	state: ^Rollback_Floor_State,
	next_counter: u64,
) -> Rollback_Refusal {
	if !state.initialized {
		return .Not_Initialized
	}
	if next_counter == 0 {
		return .Counter_Zero
	}
	if next_counter == state.last_grant_table_counter {
		return .Counter_Replay
	}
	if next_counter < state.last_grant_table_counter {
		return .Counter_Rollback
	}
	state.last_grant_table_counter = next_counter
	return .None
}

// compute_policy_authorize_digest computes the TPM2_PolicyAuthorize root
// policy digest bound to publisher_key_digest and policy_ref, completely
// independent of PCR 7 values (TPM 2.0 Part 3, TPM2_PolicyAuthorize):
//   step1 = SHA-256(zero32 || be32(TPM_CC_PolicyAuthorize) || publisher_key_digest)
//   out   = SHA-256(step1 || policy_ref)
compute_policy_authorize_digest :: proc "contextless" (
	publisher_key_digest: Digest,
	policy_ref: Digest,
) -> Digest {
	zeros: Digest
	key := publisher_key_digest
	ref := policy_ref

	ctx1: Sha256_State
	sha256_init(&ctx1)
	sha256_update(&ctx1, zeros[:])
	sha256_update_u32_be(&ctx1, COMMAND_POLICY_AUTHORIZE)
	sha256_update(&ctx1, key[:])
	intermediate := sha256_final(&ctx1)

	ctx2: Sha256_State
	sha256_init(&ctx2)
	sha256_update(&ctx2, intermediate[:])
	sha256_update(&ctx2, ref[:])
	return sha256_final(&ctx2)
}

// compute_policy_approval_hash computes the domain-separated digest signed by
// the publisher key to approve a policy statement at (key_number, policy_version).
compute_policy_approval_hash :: proc "contextless" (statement: Approved_Policy_Statement) -> Digest {
	approved := statement.approved_policy
	ref := statement.policy_ref
	domain := POLICY_APPROVAL_DOMAIN
	ctx: Sha256_State
	sha256_init(&ctx)
	sha256_update(&ctx, transmute([]u8)domain)
	sha256_update_u32_be(&ctx, statement.key_number)
	sha256_update_u32_be(&ctx, statement.policy_version)
	sha256_update(&ctx, approved[:])
	sha256_update(&ctx, ref[:])
	return sha256_final(&ctx)
}

// rollback_floor_verify_policy_authorize verifies a publisher-signed
// TPM2_PolicyAuthorize statement against the pinned publisher key and floor
// bounds. Refuses out-of-range versions, revoked key numbers, policy versions
// below the current floor, zero approved policies, or invalid signatures
// without mutating state. On success, raises key/version floors monotonically
// and returns the PCR-7-independent authorized policy digest.
rollback_floor_verify_policy_authorize :: proc "contextless" (
	state: ^Rollback_Floor_State,
	statement: Approved_Policy_Statement,
	signature: []u8,
	verify_signature: Policy_Signature_Verify_Proc,
	user_data: rawptr = nil,
) -> (authorized_digest: Digest, refusal: Rollback_Refusal) {
	if !state.initialized {
		return {}, .Not_Initialized
	}
	if verify_signature == nil {
		return {}, .Missing_Verifier
	}
	if len(signature) == 0 {
		return {}, .Signature_Invalid
	}
	if statement.key_number < FLOOR_MIN_VERSION || statement.key_number > FLOOR_MAX_VERSION {
		return {}, .Key_Number_Out_Of_Range
	}
	if statement.policy_version < FLOOR_MIN_VERSION || statement.policy_version > FLOOR_MAX_VERSION {
		return {}, .Policy_Version_Out_Of_Range
	}
	approved := statement.approved_policy
	if is_all_zero(approved[:]) {
		return {}, .Zero_Policy_Digest
	}

	// Verify the publisher signature before trusting any key or version claim.
	approval_hash := compute_policy_approval_hash(statement)
	if !verify_signature(state.publisher_key_digest, approval_hash, signature, user_data) {
		return {}, .Signature_Invalid
	}

	// Key floor comes first: a revoked key proves nothing, version included.
	if statement.key_number < state.key_floor {
		return {}, .Key_Number_Below_Floor
	}
	if statement.key_number == state.key_floor && statement.policy_version < state.version_floor {
		return {}, .Policy_Version_Below_Floor
	}

	digest := compute_policy_authorize_digest(state.publisher_key_digest, statement.policy_ref)
	if statement.key_number > state.key_floor {
		// Each new key starts its own version floor.
		state.key_floor = statement.key_number
		state.version_floor = statement.policy_version
	} else if statement.policy_version > state.version_floor {
		state.version_floor = statement.policy_version
	}
	state.active_policy_digest = digest
	return digest, .None
}
