#+build !freestanding
#+build !modus
package tpm2

import "core:testing"
import "modus:contract/byte_order"
import "modus:contract/tpm_attestation"

@(test)
evict_control_and_owner_auth_refuse_invalid_edges :: proc(t: ^testing.T) {
	buf: [256]u8
	// Handle 0 and persistent handles outside 0x81000000..0x817FFFFF are refused.
	testing.expect_value(t, evict_control_command(buf[:], nil, 0, PERSISTENT_STORAGE_KEY_HANDLE), 0)
	testing.expect_value(t, evict_control_command(buf[:], nil, 0x8000_0000, 0x80FF_FFFF), 0)
	testing.expect_value(t, evict_control_command(buf[:], nil, 0x8000_0000, 0x8180_0000), 0)
	testing.expect_value(t, evict_control_command(buf[:], nil, 0x8000_0000, max(u32)), 0)
	// Oversized owner auth and too-small buffer are refused.
	oversized_auth: [AUTHORIZATION_VALUE_SIZE + 1]u8
	oversized_auth[0] = 1
	testing.expect_value(t, evict_control_command(buf[:], oversized_auth[:], 0x8000_0000, PERSISTENT_STORAGE_KEY_HANDLE), 0)
	testing.expect_value(t, evict_control_command(buf[:8], nil, 0x8000_0000, PERSISTENT_STORAGE_KEY_HANDLE), 0)

	// Valid evict control encodes exact command code and handles.
	written := evict_control_command(buf[:], nil, 0x8000_0001, PERSISTENT_STORAGE_KEY_HANDLE)
	testing.expect(t, written > 10)
	testing.expect_value(t, byte_order.read_u16_big_endian(buf[:], 0), TAG_SESSIONS)
	testing.expect_value(t, byte_order.read_u32_big_endian(buf[:], 2), u32(written))
	testing.expect_value(t, byte_order.read_u32_big_endian(buf[:], 6), COMMAND_EVICT_CONTROL)
	testing.expect_value(t, byte_order.read_u32_big_endian(buf[:], 10), HANDLE_OWNER)
	testing.expect_value(t, byte_order.read_u32_big_endian(buf[:], 14), u32(0x8000_0001))

	// Owner auth change refuses empty, all-zero, and oversized new auth.
	zero_auth: [AUTHORIZATION_VALUE_SIZE]u8
	testing.expect_value(t, owner_authorization_change_command(buf[:], nil, nil), 0)
	testing.expect_value(t, owner_authorization_change_command(buf[:], nil, zero_auth[:]), 0)
	testing.expect_value(t, owner_authorization_change_command(buf[:], nil, oversized_auth[:]), 0)
	good_auth: [AUTHORIZATION_VALUE_SIZE]u8 = {0 = 0x5A, 31 = 0xA5}
	owner_written := owner_authorization_change_command(buf[:], nil, good_auth[:])
	testing.expect(t, owner_written > 10)
	testing.expect_value(t, byte_order.read_u32_big_endian(buf[:], 6), COMMAND_HIERARCHY_CHANGE_AUTH)
	testing.expect_value(t, byte_order.read_u32_big_endian(buf[:], 10), HANDLE_OWNER)

	// owner_authorization_set checks bit 0 only.
	testing.expect(t, !owner_authorization_set(0))
	testing.expect(t, !owner_authorization_set(PERMANENT_LOCKOUT_AUTHORIZATION_SET))
	testing.expect(t, owner_authorization_set(PERMANENT_OWNER_AUTHORIZATION_SET))
}

@(test)
external_key_verify_signature_and_policy_authorize_edges :: proc(t: ^testing.T) {
	buf: [512]u8
	zero_coord: [ECDSA_P256_COORD_SIZE]u8
	pub_x: [ECDSA_P256_COORD_SIZE]u8 = {0 = 0x11, 31 = 0x22}
	pub_y: [ECDSA_P256_COORD_SIZE]u8 = {0 = 0x33, 31 = 0x44}
	sig_r: [ECDSA_P256_COORD_SIZE]u8 = {0 = 0x55, 31 = 0x66}
	sig_s: [ECDSA_P256_COORD_SIZE]u8 = {0 = 0x77, 31 = 0x88}
	digest: [DIGEST_SIZE]u8 = {0 = 0x99, 31 = 0xAA}

	// Zero coordinates refused for key name and LoadExternal.
	_, ok := ecdsa_p256_key_name(&zero_coord, &pub_y)
	testing.expect(t, !ok)
	_, ok = ecdsa_p256_key_name(&pub_x, &zero_coord)
	testing.expect(t, !ok)
	testing.expect_value(t, load_external_ecdsa_p256_command(buf[:], &zero_coord, &pub_y), 0)
	testing.expect_value(t, load_external_ecdsa_p256_command(buf[:], &pub_x, &zero_coord), 0)

	key_name, name_ok := ecdsa_p256_key_name(&pub_x, &pub_y)
	testing.expect(t, name_ok)
	testing.expect_value(t, byte_order.read_u16_big_endian(key_name[:], 0), ALGORITHM_SHA256)

	// LoadExternal encodes public-only key in HANDLE_OWNER.
	load_len := load_external_ecdsa_p256_command(buf[:], &pub_x, &pub_y)
	testing.expect(t, load_len > 10)
	testing.expect_value(t, byte_order.read_u32_big_endian(buf[:], 6), COMMAND_LOAD_EXTERNAL)
	testing.expect_value(t, byte_order.read_u32_big_endian(buf[:], load_len - 4), HANDLE_OWNER)

	// VerifySignature refuses handle 0 or zero digest/r/s.
	testing.expect_value(t, verify_signature_command(buf[:], 0, &digest, &sig_r, &sig_s), 0)
	testing.expect_value(t, verify_signature_command(buf[:], 0x8000_0002, &zero_coord, &sig_r, &sig_s), 0)
	testing.expect_value(t, verify_signature_command(buf[:], 0x8000_0002, &digest, &zero_coord, &sig_s), 0)
	testing.expect_value(t, verify_signature_command(buf[:], 0x8000_0002, &digest, &sig_r, &zero_coord), 0)
	vs_len := verify_signature_command(buf[:], 0x8000_0002, &digest, &sig_r, &sig_s)
	testing.expect(t, vs_len > 10)
	testing.expect_value(t, byte_order.read_u32_big_endian(buf[:], 6), COMMAND_VERIFY_SIGNATURE)

	// verify_signature_answer refuses NULL hierarchy, wrong ticket tag, wrong
	// response tag (TAG_SESSIONS), zero/empty/oversized digest, and trailing bytes,
	// while accepting both 32-byte SHA-256 and 64-byte SHA-512 swtpm tickets.
	make_ticket_answer_var :: proc(resp_tag: u16, tag: u16, hierarchy: u32, td: []u8, extra: int) -> (raw: [128]u8, size: int) {
		size = 10 + 2 + 4 + 2 + len(td) + extra
		byte_order.write_u16_big_endian(raw[:], 0, resp_tag)
		byte_order.write_u32_big_endian(raw[:], 2, u32(size))
		byte_order.write_u32_big_endian(raw[:], 6, RESPONSE_SUCCESS)
		byte_order.write_u16_big_endian(raw[:], 10, tag)
		byte_order.write_u32_big_endian(raw[:], 12, hierarchy)
		byte_order.write_u16_big_endian(raw[:], 16, u16(len(td)))
		copy(raw[18:][:len(td)], td)
		return raw, size
	}
	td: [DIGEST_SIZE]u8 = {0 = 0xDE, 31 = 0xAD}
	raw_null, sz_null := make_ticket_answer_var(TAG_NO_SESSIONS, TAG_VERIFIED, HANDLE_NULL, td[:], 0)
	_, _, p := verify_signature_answer(raw_null[:sz_null])
	testing.expect_value(t, p, Answer_Problem.Malformed)

	raw_sessions, sz_sessions := make_ticket_answer_var(TAG_SESSIONS, TAG_VERIFIED, HANDLE_OWNER, td[:], 0)
	_, _, p = verify_signature_answer(raw_sessions[:sz_sessions])
	testing.expect_value(t, p, Answer_Problem.Malformed)

	raw_tag, sz_tag := make_ticket_answer_var(TAG_NO_SESSIONS, TAG_CREATION, HANDLE_OWNER, td[:], 0)
	_, _, p = verify_signature_answer(raw_tag[:sz_tag])
	testing.expect_value(t, p, Answer_Problem.Malformed)

	raw_zero, sz_zero := make_ticket_answer_var(TAG_NO_SESSIONS, TAG_VERIFIED, HANDLE_OWNER, zero_coord[:], 0)
	_, _, p = verify_signature_answer(raw_zero[:sz_zero])
	testing.expect_value(t, p, Answer_Problem.Malformed)

	raw_empty, sz_empty := make_ticket_answer_var(TAG_NO_SESSIONS, TAG_VERIFIED, HANDLE_OWNER, nil, 0)
	_, _, p = verify_signature_answer(raw_empty[:sz_empty])
	testing.expect_value(t, p, Answer_Problem.Malformed)

	oversized_td: [TICKET_DIGEST_LIMIT + 1]u8
	oversized_td[0] = 0x42
	raw_over, sz_over := make_ticket_answer_var(TAG_NO_SESSIONS, TAG_VERIFIED, HANDLE_OWNER, oversized_td[:], 0)
	_, _, p = verify_signature_answer(raw_over[:sz_over])
	testing.expect_value(t, p, Answer_Problem.Malformed)

	raw_extra, sz_extra := make_ticket_answer_var(TAG_NO_SESSIONS, TAG_VERIFIED, HANDLE_OWNER, td[:], 1)
	_, _, p = verify_signature_answer(raw_extra[:sz_extra])
	testing.expect_value(t, p, Answer_Problem.Malformed)

	raw_ok, sz_ok := make_ticket_answer_var(TAG_NO_SESSIONS, TAG_VERIFIED, HANDLE_OWNER, td[:], 0)
	ticket, code, ok_p := verify_signature_answer(raw_ok[:sz_ok])
	testing.expect_value(t, ok_p, Answer_Problem.None)
	testing.expect_value(t, code, RESPONSE_SUCCESS)
	testing.expect_value(t, ticket.hierarchy, tpm_attestation.Ticket_Hierarchy.Owner)
	testing.expect_value(t, ticket.digest_len, u16(DIGEST_SIZE))
	testing.expect(t, string(ticket.digest[:ticket.digest_len]) == string(td[:]))

	// 64-byte SHA-512 swtpm verified ticket decodes and encodes into PolicyAuthorize.
	td_512: [TICKET_DIGEST_LIMIT]u8
	td_512[0] = 0xBE
	td_512[63] = 0xEF
	raw_512, sz_512 := make_ticket_answer_var(TAG_NO_SESSIONS, TAG_VERIFIED, HANDLE_OWNER, td_512[:], 0)
	ticket_512, code_512, p_512 := verify_signature_answer(raw_512[:sz_512])
	testing.expect_value(t, p_512, Answer_Problem.None)
	testing.expect_value(t, code_512, RESPONSE_SUCCESS)
	testing.expect_value(t, ticket_512.digest_len, u16(TICKET_DIGEST_LIMIT))
	testing.expect(t, string(ticket_512.digest[:ticket_512.digest_len]) == string(td_512[:]))

	// PolicyNV refuses non-policy session, non-NV index, and zero floor bits.
	testing.expect_value(t, policy_nv_floor_command(buf[:], 0x0200_0001, 0x0180_6D01, 1), 0)
	testing.expect_value(t, policy_nv_floor_command(buf[:], 0x0300_0001, 0x8100_0001, 1), 0)
	testing.expect_value(t, policy_nv_floor_command(buf[:], 0x0300_0001, 0x0180_6D01, 0), 0)
	pnv_len := policy_nv_floor_command(buf[:], 0x0300_0001, 0x0180_6D01, 0x3)
	testing.expect(t, pnv_len > 10)
	testing.expect_value(t, byte_order.read_u32_big_endian(buf[:], 6), COMMAND_POLICY_NV)

	// Authorized policy digest separates unauthorized vs password-authorized policies
	// and rejects malformed key names.
	policy_ref: [DIGEST_SIZE]u8 = {0 = 0x42}
	_, bad_name_ok := authorized_sealed_object_policy(key_name[:10], policy_ref[:], false)
	testing.expect(t, !bad_name_ok)
	pol_no_pw, ok1 := authorized_sealed_object_policy(key_name[:], policy_ref[:], false)
	pol_pw, ok2 := authorized_sealed_object_policy(key_name[:], policy_ref[:], true)
	testing.expect(t, ok1 && ok2)
	testing.expect(t, pol_no_pw != pol_pw)
	testing.expect_value(t, pol_pw, policy_with_password_digest(&pol_no_pw))

	// Approved update branch changes when floor bits change.
	pcr_dig: [DIGEST_SIZE]u8 = {0 = 0xAB}
	nv_name := [34]u8{0 = 0x00, 1 = 0x0B, 2 = 0x77}
	branch_v1 := approved_update_branch_policy(&pcr_dig, nv_name[:], 1 << 0)
	branch_v2 := approved_update_branch_policy(&pcr_dig, nv_name[:], (1 << 0) | (1 << 1))
	testing.expect(t, branch_v1 != branch_v2)

	// PolicyAuthorize wire command encodes cleanly with both 32-byte and 64-byte tickets.
	pa_len := policy_authorize_command(buf[:], 0x0300_0001, branch_v2, policy_ref[:], key_name[:], ticket)
	testing.expect(t, pa_len > 10)
	testing.expect_value(t, byte_order.read_u32_big_endian(buf[:], 6), COMMAND_POLICY_AUTHORIZE)
	pa_512_len := policy_authorize_command(buf[:], 0x0300_0001, branch_v2, policy_ref[:], key_name[:], ticket_512)
	testing.expect_value(t, pa_512_len, pa_len + 32)
	testing.expect_value(t, byte_order.read_u32_big_endian(buf[:], 6), COMMAND_POLICY_AUTHORIZE)
}
