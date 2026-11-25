#+build !freestanding
package principals_rules

import "core:testing"
import "modus:contract/blake3"

@(private = "file")
test_hash :: proc(seed: u8) -> blake3.Hash {
	input := [4]u8{seed, seed ~ 0x55, seed + 13, 0x7E}
	return blake3.hash(input[:])
}

@(test)
disk_rows_set_refuses_all_bad_edges :: proc(t: ^testing.T) {
	base := Disk_Rows_Set {
		principal         = 0,
		generation        = 1,
		start_policy_kind = .Boot_Image_Default,
	}

	// Bad principal (at bound and max u64).
	bad_p := base
	bad_p.principal = PRINCIPAL_CAPACITY
	testing.expect_value(t, disk_rows_set_validate(&bad_p), Principals_Rules_Refusal.Bad_Principal)
	bad_p.principal = max(u64)
	testing.expect_value(t, disk_rows_set_validate(&bad_p), Principals_Rules_Refusal.Bad_Principal)

	// Unknown start policy kind (None and out of range).
	bad_sp := base
	bad_sp.start_policy_kind = .None
	testing.expect_value(t, disk_rows_set_validate(&bad_sp), Principals_Rules_Refusal.Unknown_Start_Policy_Kind)

	// Non-zero start policy hash for Boot_Image_Default or Rescue is refused.
	default_with_hash := base
	default_with_hash.start_policy_hash = test_hash(1)
	testing.expect_value(t, disk_rows_set_validate(&default_with_hash), Principals_Rules_Refusal.Nonzero_Start_Policy_Hash_For_Default)

	rescue_with_hash := base
	rescue_with_hash.start_policy_kind = .Rescue
	rescue_with_hash.start_policy_hash = test_hash(2)
	testing.expect_value(t, disk_rows_set_validate(&rescue_with_hash), Principals_Rules_Refusal.Nonzero_Start_Policy_Hash_For_Default)

	// Chosen_Disk_Module requires principal 0 and non-zero hash.
	chosen_zero_hash := base
	chosen_zero_hash.start_policy_kind = .Chosen_Disk_Module
	testing.expect_value(t, disk_rows_set_validate(&chosen_zero_hash), Principals_Rules_Refusal.Zero_Start_Policy_Hash)

	chosen_p1 := base
	chosen_p1.principal = 1
	chosen_p1.start_policy_kind = .Chosen_Disk_Module
	chosen_p1.start_policy_hash = test_hash(3)
	testing.expect_value(t, disk_rows_set_validate(&chosen_p1), Principals_Rules_Refusal.Start_Policy_Not_Principal_Zero)

	// Capacity + 1 for disk grants and remote clients.
	too_many_grants := base
	too_many_grants.disk_grant_count = DISK_GRANT_ROW_CAPACITY + 1
	testing.expect_value(t, disk_rows_set_validate(&too_many_grants), Principals_Rules_Refusal.Too_Many_Disk_Grants)

	too_many_clients := base
	too_many_clients.remote_client_count = REMOTE_CLIENT_ROW_CAPACITY + 1
	testing.expect_value(t, disk_rows_set_validate(&too_many_clients), Principals_Rules_Refusal.Too_Many_Remote_Clients)

	// Nickname edges: empty, over limit, uppercase / slash / space.
	_, ref_empty := disk_grant_row_make("", test_hash(4), {.Store}, 100)
	testing.expect_value(t, ref_empty, Principals_Rules_Refusal.Empty_Nickname)
	long_nick: [DISK_NICKNAME_LIMIT + 1]u8
	for &b in long_nick {
		b = 'a'
	}
	_, ref_long := disk_grant_row_make(string(long_nick[:]), test_hash(4), {.Store}, 100)
	testing.expect_value(t, ref_long, Principals_Rules_Refusal.Nickname_Too_Long)
	for bad in ([?]string{"Upper", "has space", "bad/slash", "dot.name"}) {
		_, ref_bad := disk_grant_row_make(bad, test_hash(4), {.Store}, 100)
		testing.expect_value(t, ref_bad, Principals_Rules_Refusal.Bad_Nickname_Byte)
	}

	// Zero module hash and unknown disk grant bits.
	_, ref_zero_hash := disk_grant_row_make("app_one", {}, {.Store}, 100)
	testing.expect_value(t, ref_zero_hash, Principals_Rules_Refusal.Zero_Module_Hash)
	unknown_grant_word := u64(1) << 5
	_, grant_word_ok := disk_grant_flags_from_word(unknown_grant_word)
	testing.expect(t, !grant_word_ok)
	_, ref_bad_bits := disk_grant_row_make("app_one", test_hash(5), transmute(Disk_Grant_Flags)unknown_grant_word, 100)
	testing.expect_value(t, ref_bad_bits, Principals_Rules_Refusal.Unknown_Disk_Grant_Bits)

	// Duplicate disk grant nickname (non-adjacent).
	row_a, ref_a := disk_grant_row_make("alpha", test_hash(10), {.Store}, 64)
	row_b, ref_b := disk_grant_row_make("beta", test_hash(11), {.Store}, 64)
	row_a2, ref_a2 := disk_grant_row_make("alpha", test_hash(12), {.Store}, 128)
	testing.expect(t, ref_a == .None && ref_b == .None && ref_a2 == .None)
	dup_grants := base
	dup_grants.disk_grants[0] = row_a
	dup_grants.disk_grants[1] = row_b
	dup_grants.disk_grants[2] = row_a2
	dup_grants.disk_grant_count = 3
	testing.expect_value(t, disk_rows_set_validate(&dup_grants), Principals_Rules_Refusal.Duplicate_Disk_Grant_Nickname)

	// Zero client key, empty client uses, unknown client use bits, and duplicate client key.
	zero_client := base
	zero_client.remote_clients[0] = {public_key = {}, uses = {.Calls}, serial = 1}
	zero_client.remote_client_count = 1
	testing.expect_value(t, disk_rows_set_validate(&zero_client), Principals_Rules_Refusal.Zero_Client_Key)

	empty_uses := base
	empty_uses.remote_clients[0] = {public_key = test_hash(20), uses = {}, serial = 1}
	empty_uses.remote_client_count = 1
	testing.expect_value(t, disk_rows_set_validate(&empty_uses), Principals_Rules_Refusal.Empty_Client_Uses)

	unknown_use_word := u64(1) << 3
	_, use_word_ok := client_use_flags_from_word(unknown_use_word)
	testing.expect(t, !use_word_ok)
	bad_uses := base
	bad_uses.remote_clients[0] = {public_key = test_hash(20), uses = transmute(Client_Use_Flags)unknown_use_word, serial = 1}
	bad_uses.remote_client_count = 1
	testing.expect_value(t, disk_rows_set_validate(&bad_uses), Principals_Rules_Refusal.Unknown_Client_Use_Bits)

	dup_clients := base
	dup_clients.remote_clients[0] = {public_key = test_hash(21), uses = {.Calls}, serial = 1}
	dup_clients.remote_clients[1] = {public_key = test_hash(22), uses = {.View}, serial = 2}
	dup_clients.remote_clients[2] = {public_key = test_hash(21), uses = {.Calls, .View}, serial = 3}
	dup_clients.remote_client_count = 3
	testing.expect_value(t, disk_rows_set_validate(&dup_clients), Principals_Rules_Refusal.Duplicate_Remote_Client_Key)

	// Border word checks.
	_, sp0_ok := start_policy_kind_from_word(0)
	testing.expect(t, !sp0_ok)
	_, sp_past_ok := start_policy_kind_from_word(u64(max(Start_Policy_Kind)) + 1)
	testing.expect(t, !sp_past_ok)
	_, r_max_ok := principals_rules_refusal_from_word(u64(max(Principals_Rules_Refusal)))
	testing.expect(t, r_max_ok)
	_, r_past_ok := principals_rules_refusal_from_word(u64(max(Principals_Rules_Refusal)) + 1)
	testing.expect(t, !r_past_ok)
}

@(test)
disk_rows_set_canonical_sort_and_digest_are_order_invariant :: proc(t: ^testing.T) {
	g_alpha, r1 := disk_grant_row_make("alpha", test_hash(1), {.Store}, 256)
	g_middle, r2 := disk_grant_row_make("middle-app", test_hash(2), {.Store}, 512)
	g_zeta, r3 := disk_grant_row_make("zeta_tool", test_hash(3), {}, 0)
	testing.expect(t, r1 == .None && r2 == .None && r3 == .None)

	c1 := Remote_Client_Row{public_key = test_hash(40), uses = {.Calls}, serial = 10, session_locked = false}
	c2 := Remote_Client_Row{public_key = test_hash(41), uses = {.View, .Input}, serial = 11, session_locked = true}
	c3 := Remote_Client_Row{public_key = test_hash(42), uses = {.Calls, .View}, serial = 12, session_locked = false}

	set_a := Disk_Rows_Set {
		principal           = 0,
		generation          = 4,
		start_policy_kind   = .Chosen_Disk_Module,
		start_policy_hash   = test_hash(99),
		disk_grant_count    = 3,
		remote_client_count = 3,
	}
	set_a.disk_grants[0] = g_zeta
	set_a.disk_grants[1] = g_alpha
	set_a.disk_grants[2] = g_middle
	set_a.remote_clients[0] = c3
	set_a.remote_clients[1] = c1
	set_a.remote_clients[2] = c2

	set_b := set_a
	set_b.disk_grants[0] = g_middle
	set_b.disk_grants[1] = g_zeta
	set_b.disk_grants[2] = g_alpha
	set_b.remote_clients[0] = c2
	set_b.remote_clients[1] = c3
	set_b.remote_clients[2] = c1

	canon_a, ref_a := disk_rows_set_canonicalize(&set_a)
	canon_b, ref_b := disk_rows_set_canonicalize(&set_b)
	testing.expect_value(t, ref_a, Principals_Rules_Refusal.None)
	testing.expect_value(t, ref_b, Principals_Rules_Refusal.None)
	testing.expect_value(t, disk_grant_row_nickname(&canon_a.disk_grants[0]), "alpha")
	testing.expect_value(t, disk_grant_row_nickname(&canon_a.disk_grants[1]), "middle-app")
	testing.expect_value(t, disk_grant_row_nickname(&canon_a.disk_grants[2]), "zeta_tool")
	testing.expect_value(t, canon_a, canon_b)

	digest_a, dig_ref_a := disk_rows_set_digest(&set_a)
	digest_b, dig_ref_b := disk_rows_set_digest(&set_b)
	testing.expect_value(t, dig_ref_a, Principals_Rules_Refusal.None)
	testing.expect_value(t, dig_ref_b, Principals_Rules_Refusal.None)
	testing.expect_value(t, digest_a, digest_b)

	// Changing one bit of any field changes the canonical digest.
	set_c := set_a
	set_c.remote_clients[0].session_locked = true
	digest_c, dig_ref_c := disk_rows_set_digest(&set_c)
	testing.expect_value(t, dig_ref_c, Principals_Rules_Refusal.None)
	testing.expect(t, digest_c != digest_a)
}
