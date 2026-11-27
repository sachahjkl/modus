// Update-surviving TPM seals and owner hierarchy protection in the TPM service
// (src/md/features/tpm_sealed_machine_key.md, "The seal across an update").
//
// Provides Seal_Authorized, Unseal_Authorized, and Owner_Protect using
// PERSISTENT_STORAGE_KEY_HANDLE (TPM2_EvictControl), TPM2_LoadExternal +
// TPM2_VerifySignature for the publisher ECDSA P-256 key, TPM2_PolicyNV on the
// TPM version floor, and TPM2_PolicyAuthorize so sealed machine and principal
// secrets survive signed OS updates while refusing systems below the floor.
package tpm_device_service

import "base:intrinsics"
import "modus:contract/errors"
import "modus:contract/tpm_attestation"
import "modus:contract/tpm_service"
import "modus:contract/value_kinds"
import "modus:random"
import "modus:system"
import "modus:tpm2"

// update_policy_bundle_copy copies Update_Policy_Bundle once out of the shared
// TPM region and validates it at the border before any TPM command runs.
@(private = "file")
update_policy_bundle_copy :: proc "contextless" (
	require_approval: bool,
) -> (bundle: tpm_service.Update_Policy_Bundle, failed: Outcome, ok: bool) {
	intrinsics.mem_copy_non_overlapping(&bundle, &region[tpm_service.REGION_UPDATE_POLICY], size_of(tpm_service.Update_Policy_Bundle))
	if refusal := tpm_service.update_policy_bundle_check(&bundle, require_approval); refusal != .None {
		return {}, {outcome = .Argument_Refused, values = errors.completion_values(errors.error_make(.Bad_Value, .None, 0, i64(refusal)))}, false
	}
	return bundle, {}, true
}

// persistent_or_primary_storage_key probes PERSISTENT_STORAGE_KEY_HANDLE with
// TPM2_ReadPublic first so unsealing and sealing continue to work after the
// owner hierarchy authorization value is set. When the persistent handle is
// absent, falls back to creating the transient owner primary storage key.
persistent_or_primary_storage_key :: proc "contextless" () -> (handle: u32, must_flush: bool, failed: Outcome, ok: bool) {
	count := tpm2.read_public_command(command_bytes[:], tpm2.PERSISTENT_STORAGE_KEY_HANDLE)
	answer, step := transact(count)
	if step != .None {
		return 0, false, request_failed(.Callee_Unavailable, .Device, 0, i64(step)), false
	}
	code, problem := tpm2.status_answer(answer)
	if problem == .None {
		return tpm2.PERSISTENT_STORAGE_KEY_HANDLE, false, {}, true
	}
	if problem == .Refused && tpm2.handle_absent(code) {
		primary, primary_failed, primary_ok := storage_key()
		return primary, true, primary_failed, primary_ok
	}
	return 0, false, outcome_of_problem(problem, code, tpm2.COMMAND_READ_PUBLIC), false
}

// seal_authorized seals 32 secret bytes at REGION_SECRET to the
// TPM2_PolicyAuthorize root policy computed from Update_Policy_Bundle (plus
// TPM2_PolicyPassword when authorization_kind is .Value) so signed updates above
// the TPM version floor continue to unseal the object.
seal_authorized :: proc "contextless" (authorization_kind: tpm_service.Authorization) -> Outcome {
	secret: [tpm2.SECRET_SIZE]u8
	authorization: [tpm2.AUTHORIZATION_VALUE_SIZE]u8
	defer erase(secret[:])
	defer erase(authorization[:])
	copy(secret[:], region[tpm_service.REGION_SECRET:][:tpm2.SECRET_SIZE])
	erase(region[tpm_service.REGION_SECRET:][:tpm2.SECRET_SIZE])
	authorized := authorization_take(authorization_kind, &authorization)
	authorization_bytes: []u8
	if authorized {
		authorization_bytes = authorization[:]
	}
	defer erase(command_bytes[:])

	bundle, bundle_failed, bundle_ok := update_policy_bundle_copy(require_approval = false)
	if !bundle_ok {
		return bundle_failed
	}
	key_name, name_ok := tpm2.ecdsa_p256_key_name(&bundle.publisher_x, &bundle.publisher_y)
	if !name_ok {
		return request_failed(.Argument_Refused, .Bad_Value)
	}
	policy, policy_ok := tpm2.authorized_sealed_object_policy(key_name[:], bundle.policy_ref[:], authorized)
	if !policy_ok {
		return request_failed(.Argument_Refused, .Bad_Value)
	}
	parent, must_flush, parent_failed, parent_ok := persistent_or_primary_storage_key()
	if !parent_ok {
		return parent_failed
	}
	defer if must_flush {
		flush(parent)
	}
	count := tpm2.create_sealed_command(command_bytes[:], parent, &secret, &policy, authorization_bytes)
	answer, step := transact(count)
	if step != .None {
		return request_failed(.Callee_Unavailable, .Device, 0, i64(step))
	}
	created, code, problem := tpm2.create_answer(answer)
	if problem != .None {
		return outcome_of_problem(problem, code, tpm2.COMMAND_CREATE)
	}
	copy(region[tpm_service.REGION_PUBLIC_AREA:][:len(created.public_area)], created.public_area)
	copy(region[tpm_service.REGION_PRIVATE_AREA:][:len(created.private_area)], created.private_area)
	copy(region[tpm_service.REGION_CREATION_DATA:][:len(created.creation_data)], created.creation_data)
	copy(region[tpm_service.REGION_CREATION_TICKET:][:len(created.creation_ticket)], created.creation_ticket)
	system.log_fact(.Info, Sealed_Authorized{public_area = bytes_field(len(created.public_area)), private_area = bytes_field(len(created.private_area))})
	return {outcome = .Succeeded, values = {0 = u64(len(created.public_area)), 1 = u64(len(created.private_area)), 2 = u64(tpm2.PCR_SET), 3 = u64(len(created.creation_data)), 4 = u64(len(created.creation_ticket))}}
}

// unseal_authorized unseals an update-surviving object by verifying the
// publisher ECDSA P-256 signature on approved_policy inside the TPM
// (TPM2_LoadExternal + TPM2_VerifySignature), satisfying PCR 7/11, the NV
// version floor (TPM2_PolicyNV), TPM2_PolicyAuthorize with the verified ticket,
// and TPM2_PolicyPassword when authorization_kind is .Value.
unseal_authorized :: proc "contextless" (
	public_count, private_count, creation_count, ticket_count: u64,
	authorization_kind: tpm_service.Authorization,
) -> Outcome {
	authorization: [tpm2.AUTHORIZATION_VALUE_SIZE]u8
	defer erase(authorization[:])
	defer erase(command_bytes[:])
	defer erase(answer_bytes[:])
	authorized := authorization_take(authorization_kind, &authorization)
	if public_count > tpm2.PUBLIC_AREA_LIMIT || private_count > tpm2.PRIVATE_AREA_LIMIT || creation_count > tpm2.CREATION_DATA_LIMIT || ticket_count > tpm2.CREATION_TICKET_LIMIT {
		return request_failed(.Argument_Refused, .Too_Long)
	}
	authorization_bytes: []u8
	if authorized {
		authorization_bytes = authorization[:]
	}
	bundle, bundle_failed, bundle_ok := update_policy_bundle_copy(require_approval = true)
	if !bundle_ok {
		return bundle_failed
	}
	key_name, name_ok := tpm2.ecdsa_p256_key_name(&bundle.publisher_x, &bundle.publisher_y)
	if !name_ok {
		return request_failed(.Argument_Refused, .Bad_Value)
	}

	public_bytes, private_bytes, creation_bytes, ticket_bytes := int(public_count), int(private_count), int(creation_count), int(ticket_count)
	public_area: [tpm2.PUBLIC_AREA_LIMIT]u8
	private_area: [tpm2.PRIVATE_AREA_LIMIT]u8
	creation_data: [tpm2.CREATION_DATA_LIMIT]u8
	creation_ticket: [tpm2.CREATION_TICKET_LIMIT]u8
	copy(public_area[:public_bytes], region[tpm_service.REGION_PUBLIC_AREA:][:public_bytes])
	copy(private_area[:private_bytes], region[tpm_service.REGION_PRIVATE_AREA:][:private_bytes])
	copy(creation_data[:creation_bytes], region[tpm_service.REGION_CREATION_DATA:][:creation_bytes])
	copy(creation_ticket[:ticket_bytes], region[tpm_service.REGION_CREATION_TICKET:][:ticket_bytes])
	if !tpm2.area_fits(public_area[:public_bytes], tpm2.PUBLIC_AREA_LIMIT) || !tpm2.area_fits(private_area[:private_bytes], tpm2.PRIVATE_AREA_LIMIT) || !tpm2.ticket_fits(creation_ticket[:ticket_bytes]) {
		return request_failed(.Argument_Refused, .Malformed)
	}
	if !tpm2.update_seal_public_check(public_area[:public_bytes], key_name[:], bundle.policy_ref[:], authorized) {
		system.log_fact(.Info, Unseal_Policy_Refused{})
		return object_not_authentic(tpm_service.UNSEAL_PUBLIC_AREA_ARGUMENT, 0)
	}

	parent, must_flush, parent_failed, parent_ok := persistent_or_primary_storage_key()
	if !parent_ok {
		return parent_failed
	}
	defer if must_flush {
		flush(parent)
	}
	count := tpm2.load_command(command_bytes[:], parent, public_area[:public_bytes], private_area[:private_bytes])
	answer, step := transact(count)
	if step != .None {
		return request_failed(.Callee_Unavailable, .Device, 0, i64(step))
	}
	item, code, problem := tpm2.handle_answer(answer)
	if problem != .None {
		return outcome_of_problem(problem, code, tpm2.COMMAND_LOAD)
	}
	defer flush(item)

	// Confirm the TPM created this sealed object before authorizing unseal.
	if _, creation_ok := tpm2.creation_data_pcr_digest(creation_data[:creation_bytes]); !creation_ok {
		system.log_fact(.Info, Unseal_Creation_Data_Refused{})
		return object_not_authentic(tpm_service.UNSEAL_CREATION_DATA_ARGUMENT, 0)
	}
	creation_digest := tpm2.creation_hash(creation_data[:creation_bytes])
	count = tpm2.certify_creation_command(command_bytes[:], item, &creation_digest, creation_ticket[:ticket_bytes])
	answer, step = transact(count)
	if step != .None {
		return request_failed(.Callee_Unavailable, .Device, 0, i64(step))
	}
	code, problem = tpm2.status_answer(answer)
	if problem == .Refused && tpm2.ticket_fails(code) {
		system.log_fact(.Info, Unseal_Ticket_Refused{response_code = value_kinds.Hexadecimal_Sixteen_Digits(code)})
		return object_not_authentic(tpm_service.UNSEAL_CREATION_TICKET_ARGUMENT, code)
	}
	if problem != .None {
		return outcome_of_problem(problem, code, tpm2.COMMAND_CERTIFY_CREATION)
	}

	// Load the publisher ECDSA P-256 verification key and obtain a TPM-verified
	// ticket over SHA-256(approved_policy || policy_ref).
	count = tpm2.load_external_ecdsa_p256_command(command_bytes[:], &bundle.publisher_x, &bundle.publisher_y)
	answer, step = transact(count)
	if step != .None {
		return request_failed(.Callee_Unavailable, .Device, 0, i64(step))
	}
	pub_handle: u32
	pub_handle, code, problem = tpm2.handle_answer(answer)
	if problem != .None {
		return outcome_of_problem(problem, code, tpm2.COMMAND_LOAD_EXTERNAL)
	}
	defer flush(pub_handle)

	approval_digest := tpm2.policy_authorize_approval_digest(&bundle.approved_policy, bundle.policy_ref[:])
	count = tpm2.verify_signature_command(command_bytes[:], pub_handle, &approval_digest, &bundle.signature_r, &bundle.signature_s)
	answer, step = transact(count)
	if step != .None {
		return request_failed(.Callee_Unavailable, .Device, 0, i64(step))
	}
	verified_ticket: tpm_attestation.Verified_Ticket
	verified_ticket, code, problem = tpm2.verify_signature_answer(answer)
	if problem != .None {
		return outcome_of_problem(problem, code, tpm2.COMMAND_VERIFY_SIGNATURE)
	}

	// Satisfy the authorized policy chain in a live policy session:
	// PolicyPCR(7, 11) -> PolicyNV(version_floor_index, BITSET) ->
	// PolicyAuthorize(approved_policy, policy_ref, key_name, ticket) ->
	// optional PolicyPassword.
	count = tpm2.start_session_command(command_bytes[:], .Policy)
	answer, step = transact(count)
	if step != .None {
		return request_failed(.Callee_Unavailable, .Device, 0, i64(step))
	}
	session: u32
	session, code, problem = tpm2.handle_answer(answer)
	if problem != .None {
		return outcome_of_problem(problem, code, tpm2.COMMAND_START_AUTH_SESSION)
	}
	defer flush(session)

	count = tpm2.policy_pcr_command(command_bytes[:], session)
	answer, step = transact(count)
	if step != .None {
		return request_failed(.Callee_Unavailable, .Device, 0, i64(step))
	}
	code, problem = tpm2.status_answer(answer)
	if problem != .None {
		return outcome_of_problem(problem, code, tpm2.COMMAND_POLICY_PCR)
	}

	count = tpm2.policy_nv_floor_command(command_bytes[:], session, bundle.version_floor_index, bundle.version_floor_bits)
	answer, step = transact(count)
	if step != .None {
		return request_failed(.Callee_Unavailable, .Device, 0, i64(step))
	}
	code, problem = tpm2.status_answer(answer)
	if problem != .None {
		return outcome_of_problem(problem, code, tpm2.COMMAND_POLICY_NV)
	}

	count = tpm2.policy_authorize_command(command_bytes[:], session, bundle.approved_policy, bundle.policy_ref[:], key_name[:], verified_ticket)
	answer, step = transact(count)
	if step != .None {
		return request_failed(.Callee_Unavailable, .Device, 0, i64(step))
	}
	code, problem = tpm2.status_answer(answer)
	if problem != .None {
		return outcome_of_problem(problem, code, tpm2.COMMAND_POLICY_AUTHORIZE)
	}

	if authorized {
		count = tpm2.policy_password_command(command_bytes[:], session)
		answer, step = transact(count)
		if step != .None {
			return request_failed(.Callee_Unavailable, .Device, 0, i64(step))
		}
		code, problem = tpm2.status_answer(answer)
		if problem != .None {
			return outcome_of_problem(problem, code, tpm2.COMMAND_POLICY_PASSWORD)
		}
	}

	secret: []u8
	for attempt in 1 ..= UNSEAL_TRIES {
		count = tpm2.unseal_command(command_bytes[:], item, session, authorization_bytes)
		authorization_used = authorization_used || authorized
		answer, step = transact(count)
		if step != .None {
			return request_failed(.Callee_Unavailable, .Device, 0, i64(step))
		}
		secret, code, problem = tpm2.unseal_answer(answer)
		if problem != .Refused || !tpm2.retry_asked(code) || attempt == UNSEAL_TRIES {
			break
		}
	}
	if problem != .None {
		if problem == .Refused && tpm2.authorization_fails(code) {
			authorization_used = false
			system.log_fact(.Info, Unseal_Authorization_Wrong{response_code = value_kinds.Hexadecimal_Sixteen_Digits(code)})
			return {outcome = .Argument_Refused, values = errors.completion_values(errors.error_make(.Not_Authentic, .None, tpm_service.UNSEAL_AUTHORIZATION_ARGUMENT, i64(tpm2.COMMAND_UNSEAL), 0, i64(code)))}
		}
		if problem == .Refused && tpm2.locked_out(code) {
			system.log_fact(.Info, Unseal_Locked_Out{response_code = value_kinds.Hexadecimal_Sixteen_Digits(code)})
		}
		return outcome_of_problem(problem, code, tpm2.COMMAND_UNSEAL)
	}
	copy(region[tpm_service.REGION_SECRET:][:tpm2.SECRET_SIZE], secret)
	system.log_fact(.Info, Unsealed_Authorized{})
	return {outcome = .Succeeded, values = {0 = tpm2.SECRET_SIZE}}
}

// owner_protect persists the primary storage key at PERSISTENT_STORAGE_KEY_HANDLE,
// generates a random 32-byte owner hierarchy authorization value, sets it via
// TPM2_HierarchyChangeAuth(Owner), and seals that value under the persistent
// storage key to the Update_Policy_Bundle so only update-authorized boots can
// unseal it and another OS on the machine cannot undefine TPM floors or pins.
owner_protect :: proc "contextless" (seeded: bool) -> Outcome {
	defer erase(command_bytes[:])
	bundle, bundle_failed, bundle_ok := update_policy_bundle_copy(require_approval = false)
	if !bundle_ok {
		return bundle_failed
	}
	if !seeded {
		return request_failed(.Wrong_State, .State)
	}
	owner_auth: [tpm2.AUTHORIZATION_VALUE_SIZE]u8
	defer erase(owner_auth[:])
	key_error: errors.Error_Record
	if !random.fill_for_a_key(&generator, owner_auth[:], .Processor, &key_error) {
		return request_failed(.Wrong_State, .State)
	}
	key_name, name_ok := tpm2.ecdsa_p256_key_name(&bundle.publisher_x, &bundle.publisher_y)
	if !name_ok {
		return request_failed(.Argument_Refused, .Bad_Value)
	}
	policy, policy_ok := tpm2.authorized_sealed_object_policy(key_name[:], bundle.policy_ref[:], false)
	if !policy_ok {
		return request_failed(.Argument_Refused, .Bad_Value)
	}

	// Refuse if the owner hierarchy already has a non-empty authorization value.
	permanent: [1]u32
	if !properties_read(tpm2.PROPERTY_PERMANENT, permanent[:], "the state of the hierarchies") {
		return request_failed(.Callee_Unavailable, .Device)
	}
	if tpm2.owner_authorization_set(permanent[0]) {
		return request_failed(.Wrong_State, .State)
	}

	// Check whether PERSISTENT_STORAGE_KEY_HANDLE is already persisted (for
	// example after an interrupted earlier run) so retries do not fail with
	// TPM_RC_NV_DEFINED. When absent, create and persist the primary storage key
	// before setting owner auth so later boots can load sealed objects without
	// knowing owner auth.
	changed_before := false
	count := tpm2.read_public_command(command_bytes[:], tpm2.PERSISTENT_STORAGE_KEY_HANDLE)
	answer, step := transact(count)
	if step != .None {
		return changing_interface_failed(step, changed_before = false)
	}
	code, problem := tpm2.status_answer(answer)
	if problem == .Refused && tpm2.handle_absent(code) {
		primary, primary_failed, primary_ok := storage_key()
		if !primary_ok {
			return primary_failed
		}
		defer flush(primary)

		count = tpm2.evict_control_command(command_bytes[:], nil, primary, tpm2.PERSISTENT_STORAGE_KEY_HANDLE)
		answer, step = transact(count)
		if step != .None {
			return changing_interface_failed(step, changed_before = false)
		}
		code, problem = tpm2.status_answer(answer)
		if problem != .None {
			return changing_answer_failed(problem, code, tpm2.COMMAND_EVICT_CONTROL, changed_before = false)
		}
		changed_before = true
	} else if problem != .None {
		return changing_answer_failed(problem, code, tpm2.COMMAND_READ_PUBLIC, changed_before = false)
	}

	// Seal the new owner authorization value under the persistent storage key
	// BEFORE changing the hierarchy auth so a failed seal leaves owner auth empty.
	count = tpm2.create_sealed_command(command_bytes[:], tpm2.PERSISTENT_STORAGE_KEY_HANDLE, &owner_auth, &policy, nil)
	answer, step = transact(count)
	if step != .None {
		return changing_interface_failed(step, changed_before = changed_before)
	}
	created: tpm2.Created_Object
	created, code, problem = tpm2.create_answer(answer)
	if problem != .None {
		return changing_answer_failed(problem, code, tpm2.COMMAND_CREATE, changed_before = changed_before)
	}
	if len(created.creation_data) > tpm2.CREATION_DATA_LIMIT {
		return changing_answer_failed(.Malformed, code, tpm2.COMMAND_CREATE, changed_before = changed_before)
	}

	// Copy the created object areas out of global answer_bytes before the next
	// transact overwrites answer_bytes with the TPM2_HierarchyChangeAuth reply.
	public_copy: [tpm2.PUBLIC_AREA_LIMIT]u8
	private_copy: [tpm2.PRIVATE_AREA_LIMIT]u8
	creation_copy: [tpm2.CREATION_DATA_LIMIT]u8
	ticket_copy: [tpm2.CREATION_TICKET_LIMIT]u8
	defer erase(private_copy[:])
	public_len := copy(public_copy[:], created.public_area)
	private_len := copy(private_copy[:], created.private_area)
	creation_len := copy(creation_copy[:], created.creation_data)
	ticket_len := copy(ticket_copy[:], created.creation_ticket)

	count = tpm2.owner_authorization_change_command(command_bytes[:], nil, owner_auth[:])
	answer, step = transact(count)
	if step != .None {
		return changing_interface_failed(step, changed_before = true)
	}
	code, problem = tpm2.status_answer(answer)
	if problem != .None {
		return changing_answer_failed(problem, code, tpm2.COMMAND_HIERARCHY_CHANGE_AUTH, changed_before = true)
	}

	copy(region[tpm_service.REGION_PUBLIC_AREA:][:public_len], public_copy[:public_len])
	copy(region[tpm_service.REGION_PRIVATE_AREA:][:private_len], private_copy[:private_len])
	copy(region[tpm_service.REGION_CREATION_DATA:][:creation_len], creation_copy[:creation_len])
	copy(region[tpm_service.REGION_CREATION_TICKET:][:ticket_len], ticket_copy[:ticket_len])
	system.log_fact(.Info, Owner_Hierarchy_Protected{persistent_handle = value_kinds.Hexadecimal_Sixteen_Digits(tpm2.PERSISTENT_STORAGE_KEY_HANDLE)})
	return {outcome = .Succeeded, values = {0 = u64(public_len), 1 = u64(private_len), 2 = u64(tpm2.PERSISTENT_STORAGE_KEY_HANDLE), 3 = u64(creation_len), 4 = u64(ticket_len)}}
}
