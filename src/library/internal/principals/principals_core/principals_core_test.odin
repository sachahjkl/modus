#+build !freestanding
package principals_core

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/remote"
import "modus:contract/role_contract"
import rd "modus:contract/root_delegation"

@(private = "file")
make_hash :: proc(seed: u8) -> (h: blake3.Hash) {
	for i in 0 ..< len(h) {
		h[i] = seed + u8(i)
	}
	if h == (blake3.Hash{}) {
		h[0] = 1
	}
	return h
}

@(private = "file")
make_key :: proc(seed: u8) -> (k: [32]u8) {
	for i in 0 ..< len(k) {
		k[i] = seed ~ u8(i + 1)
	}
	if k == ([32]u8{}) {
		k[0] = 1
	}
	return k
}

@(private = "file")
fill_name :: proc(text: string) -> (buf: [PRINCIPAL_NAME_CAPACITY]u8, length: u8) {
	copy(buf[:], text)
	return buf, u8(len(text))
}

@(private = "file")
fill_nickname :: proc(text: string) -> (buf: [rd.NICKNAME_CAPACITY]u8, length: u8) {
	copy(buf[:], text)
	return buf, u8(len(text))
}

@(private = "file")
snapshot_domain_equal :: proc(a, b: ^Principals_State) -> bool {
	if a.initialized != b.initialized ||
		a.front_principal != b.front_principal ||
		a.start_policy != b.start_policy ||
		a.machine_passphrase_required != b.machine_passphrase_required ||
		a.client_table != b.client_table ||
		a.next_client_serial != b.next_client_serial ||
		a.principals != b.principals {
		return false
	}
	return a.counters.principal_count == b.counters.principal_count &&
		a.counters.active_sessions == b.counters.active_sessions &&
		a.counters.disk_rows_applied == b.counters.disk_rows_applied &&
		a.counters.active_client_keys == b.counters.active_client_keys &&
		a.counters.start_policy_updates == b.counters.start_policy_updates
}

@(test)
action_enum_borders_refuse_zero_and_unknown_words :: proc(t: ^testing.T) {
	for bad in ([?]u32{0, u32(max(Session_Action)) + 1, max(u32)}) {
		_, ok := session_action_from_word(bad)
		testing.expect(t, !ok)
	}
	for a in Session_Action {
		if a == .None {
			continue
		}
		got, ok := session_action_from_word(u32(a))
		testing.expect(t, ok && got == a)
	}

	for bad in ([?]u32{0, u32(max(Client_Key_Action)) + 1, max(u32)}) {
		_, ok := client_key_action_from_word(bad)
		testing.expect(t, !ok)
	}
	for a in Client_Key_Action {
		if a == .None {
			continue
		}
		got, ok := client_key_action_from_word(u32(a))
		testing.expect(t, ok && got == a)
	}

	for bad in ([?]u32{0, u32(max(Start_Policy_Action)) + 1, max(u32)}) {
		_, ok := start_policy_action_from_word(bad)
		testing.expect(t, !ok)
	}
	for a in Start_Policy_Action {
		if a == .None {
			continue
		}
		got, ok := start_policy_action_from_word(u32(a))
		testing.expect(t, ok && got == a)
	}
}

@(test)
uninitialized_state_refuses_every_operation :: proc(t: ^testing.T) {
	state: Principals_State
	reg := Register_Principal_Input{principal_id = 1, public_key = make_key(1)}
	reg.name, reg.name_length = fill_name("alice")
	testing.expect_value(t, register_principal(&state, &reg), Principals_Refusal.Uninitialized)

	sess := Session_Transition_Input{principal_id = 1, action_word = u32(Session_Action.Unlock)}
	testing.expect_value(t, session_transition(&state, &sess), Principals_Refusal.Uninitialized)

	req := rd.Disk_Rows_Set_Request{principal = 0, generation = 1}
	ref, _ := apply_disk_rows_set(&state, &req)
	testing.expect_value(t, ref, Principals_Refusal.Uninitialized)

	ck := Client_Key_Input{principal_id = 0, action_word = u32(Client_Key_Action.Allow), client_key = make_key(2), client_uses_word = remote.client_uses_word({.Calls})}
	_, ck_ref := client_key_command(&state, &ck)
	testing.expect_value(t, ck_ref, Principals_Refusal.Uninitialized)

	sp := Start_Policy_Input{principal_id = 0, action_word = u32(Start_Policy_Action.Clear_Choice)}
	testing.expect_value(t, start_policy_command(&state, &sp), Principals_Refusal.Uninitialized)

	_, build_ref := build_disk_rows_set_request(&state, 0)
	testing.expect_value(t, build_ref, Principals_Refusal.Uninitialized)
}

@(test)
principal_registration_refusals_and_capacity_overflow_keep_state_intact :: proc(t: ^testing.T) {
	state: Principals_State
	state_init(&state)
	testing.expect_value(t, state.counters.principal_count, u64(1))
	testing.expect_value(t, state.counters.active_sessions, u64(1))

	// Refused: principal 0 cannot be registered again.
	before := state
	bad0 := Register_Principal_Input{principal_id = 0, public_key = make_key(1)}
	bad0.name, bad0.name_length = fill_name("alice")
	testing.expect_value(t, register_principal(&state, &bad0), Principals_Refusal.Invalid_Principal_Id)
	testing.expect(t, snapshot_domain_equal(&state, &before))

	// Refused: empty, too long, uppercase, leading digit, space, trailing junk, reserved "machine".
	for bad_name in ([?]string{"", "Alice", "1alice", "alice bob", "alice/bob"}) {
		before = state
		inp := Register_Principal_Input{principal_id = 1, public_key = make_key(1)}
		inp.name, inp.name_length = fill_name(bad_name)
		testing.expect_value(t, register_principal(&state, &inp), Principals_Refusal.Invalid_Principal_Name)
		testing.expect(t, snapshot_domain_equal(&state, &before))
	}
	before = state
	too_long := Register_Principal_Input{principal_id = 1, name_length = PRINCIPAL_NAME_CAPACITY + 1, public_key = make_key(1)}
	testing.expect_value(t, register_principal(&state, &too_long), Principals_Refusal.Invalid_Principal_Name)
	testing.expect(t, snapshot_domain_equal(&state, &before))

	before = state
	trailing := Register_Principal_Input{principal_id = 1, public_key = make_key(1)}
	trailing.name, trailing.name_length = fill_name("alice")
	trailing.name[PRINCIPAL_NAME_CAPACITY - 1] = 'x'
	testing.expect_value(t, register_principal(&state, &trailing), Principals_Refusal.Trailing_Name_Bytes)
	testing.expect(t, snapshot_domain_equal(&state, &before))

	before = state
	reserved := Register_Principal_Input{principal_id = 1, public_key = make_key(1)}
	reserved.name, reserved.name_length = fill_name("machine")
	testing.expect_value(t, register_principal(&state, &reserved), Principals_Refusal.Duplicate_Principal_Name)
	testing.expect(t, snapshot_domain_equal(&state, &before))

	// Refused: zero public key.
	before = state
	zero_key := Register_Principal_Input{principal_id = 1}
	zero_key.name, zero_key.name_length = fill_name("alice")
	testing.expect_value(t, register_principal(&state, &zero_key), Principals_Refusal.Zero_Public_Key)
	testing.expect(t, snapshot_domain_equal(&state, &before))

	// Register first valid named principal.
	alice := Register_Principal_Input{principal_id = 1, public_key = make_key(10)}
	alice.name, alice.name_length = fill_name("alice")
	testing.expect_value(t, register_principal(&state, &alice), Principals_Refusal.None)
	testing.expect_value(t, state.counters.principal_count, u64(2))
	testing.expect_value(t, state.counters.active_sessions, u64(1)) // Starts Locked.

	// Refused: duplicate id, duplicate name, duplicate public key.
	before = state
	dup_id := Register_Principal_Input{principal_id = 1, public_key = make_key(11)}
	dup_id.name, dup_id.name_length = fill_name("bob")
	testing.expect_value(t, register_principal(&state, &dup_id), Principals_Refusal.Duplicate_Principal)
	testing.expect(t, snapshot_domain_equal(&state, &before))

	before = state
	dup_name := Register_Principal_Input{principal_id = 2, public_key = make_key(11)}
	dup_name.name, dup_name.name_length = fill_name("alice")
	testing.expect_value(t, register_principal(&state, &dup_name), Principals_Refusal.Duplicate_Principal_Name)
	testing.expect(t, snapshot_domain_equal(&state, &before))

	before = state
	dup_key := Register_Principal_Input{principal_id = 2, public_key = make_key(10)}
	dup_key.name, dup_key.name_length = fill_name("bob")
	testing.expect_value(t, register_principal(&state, &dup_key), Principals_Refusal.Duplicate_Public_Key)
	testing.expect(t, snapshot_domain_equal(&state, &before))

	// Fill remaining slots up to MAX_PRINCIPALS, then verify overflow refuses with zero mutation.
	for i in u64(2) ..< u64(MAX_PRINCIPALS) {
		inp := Register_Principal_Input{principal_id = i, public_key = make_key(u8(20 + i))}
		inp.name[0] = 'p'
		inp.name[1] = u8('0' + i)
		inp.name_length = 2
		testing.expect_value(t, register_principal(&state, &inp), Principals_Refusal.None)
	}
	testing.expect_value(t, state.counters.principal_count, u64(MAX_PRINCIPALS))

	before = state
	overflow := Register_Principal_Input{principal_id = 99, public_key = make_key(99)}
	overflow.name, overflow.name_length = fill_name("overflow")
	testing.expect_value(t, register_principal(&state, &overflow), Principals_Refusal.Principals_Full)
	testing.expect(t, snapshot_domain_equal(&state, &before))
}

@(test)
session_lifecycle_protects_machine_and_updates_client_keys :: proc(t: ^testing.T) {
	state: Principals_State
	state_init(&state)

	alice := Register_Principal_Input{principal_id = 1, public_key = make_key(1)}
	alice.name, alice.name_length = fill_name("alice")
	testing.expect_value(t, register_principal(&state, &alice), Principals_Refusal.None)

	// Invalid action words and unknown principal refused.
	before := state
	testing.expect_value(t, session_transition(&state, &Session_Transition_Input{principal_id = 1, action_word = 0}), Principals_Refusal.Invalid_Session_Action)
	testing.expect_value(t, session_transition(&state, &Session_Transition_Input{principal_id = 1, action_word = 99}), Principals_Refusal.Invalid_Session_Action)
	testing.expect_value(t, session_transition(&state, &Session_Transition_Input{principal_id = 77, action_word = u32(Session_Action.Unlock)}), Principals_Refusal.Unknown_Principal)
	testing.expect(t, snapshot_domain_equal(&state, &before))

	// Principal 0 cannot be locked, unlocked, or stopped.
	for protected_act in ([?]Session_Action{.Unlock, .Lock, .Stop_Session}) {
		before = state
		testing.expect_value(t, session_transition(&state, &Session_Transition_Input{principal_id = 0, action_word = u32(protected_act)}), Principals_Refusal.Machine_Principal_Protected)
		testing.expect(t, snapshot_domain_equal(&state, &before))
	}

	// Locked principal cannot be locked, stopped, or brought to front.
	for conflict_act in ([?]Session_Action{.Lock, .Stop_Session, .Bring_To_Front}) {
		before = state
		testing.expect_value(t, session_transition(&state, &Session_Transition_Input{principal_id = 1, action_word = u32(conflict_act)}), Principals_Refusal.Session_State_Conflict)
		testing.expect(t, snapshot_domain_equal(&state, &before))
	}

	// Allow a client key for principal 0 while principal 0 is in front.
	k0 := make_key(40)
	s0, ref0 := client_key_command(&state, &Client_Key_Input{principal_id = 0, action_word = u32(Client_Key_Action.Allow), client_key = k0, client_uses_word = remote.client_uses_word({.Calls, .View})})
	testing.expect_value(t, ref0, Principals_Refusal.None)
	testing.expect(t, s0 > 0)

	// Unlock alice, allow a client key for alice (not in front yet).
	testing.expect_value(t, session_transition(&state, &Session_Transition_Input{principal_id = 1, action_word = u32(Session_Action.Unlock)}), Principals_Refusal.None)
	testing.expect_value(t, state.counters.active_sessions, u64(2))
	// Unlocking an already-active principal is refused.
	testing.expect_value(t, session_transition(&state, &Session_Transition_Input{principal_id = 1, action_word = u32(Session_Action.Unlock)}), Principals_Refusal.Session_State_Conflict)

	k1 := make_key(41)
	s1, ref1 := client_key_command(&state, &Client_Key_Input{principal_id = 1, action_word = u32(Client_Key_Action.Allow), client_key = k1, client_uses_word = remote.client_uses_word({.Calls, .View, .Input})})
	testing.expect_value(t, ref1, Principals_Refusal.None)
	row1, found1 := client_key_lookup(&state, k1)
	testing.expect(t, found1 && row1.not_in_front == 1 && row1.session_locked == 0)

	// Bring alice to front -> k1 unpaused, k0 paused.
	testing.expect_value(t, session_transition(&state, &Session_Transition_Input{principal_id = 1, action_word = u32(Session_Action.Bring_To_Front)}), Principals_Refusal.None)
	row0_after, _ := client_key_lookup(&state, k0)
	row1_after, _ := client_key_lookup(&state, k1)
	testing.expect(t, row0_after.not_in_front == 1 && row1_after.not_in_front == 0)

	// Lock alice -> k1 gets session_locked = 1 and a fresh serial; front returns to principal 0 so k0 unpauses.
	testing.expect_value(t, session_transition(&state, &Session_Transition_Input{principal_id = 1, action_word = u32(Session_Action.Lock)}), Principals_Refusal.None)
	testing.expect_value(t, state.front_principal, role_contract.MACHINE_PRINCIPAL)
	row0_locked, _ := client_key_lookup(&state, k0)
	row1_locked, _ := client_key_lookup(&state, k1)
	testing.expect(t, row0_locked.not_in_front == 0)
	testing.expect(t, row1_locked.session_locked == 1 && row1_locked.serial > s1)

	// Re-unlock alice -> k1 gets session_locked = 0 and a newer serial.
	testing.expect_value(t, session_transition(&state, &Session_Transition_Input{principal_id = 1, action_word = u32(Session_Action.Unlock)}), Principals_Refusal.None)
	row1_reunlocked, _ := client_key_lookup(&state, k1)
	testing.expect(t, row1_reunlocked.session_locked == 0 && row1_reunlocked.serial > row1_locked.serial)
}

@(test)
disk_rows_set_enforces_border_atomicity_and_start_policy_rules :: proc(t: ^testing.T) {
	state: Principals_State
	state_init(&state)

	alice := Register_Principal_Input{principal_id = 1, public_key = make_key(5)}
	alice.name, alice.name_length = fill_name("alice")
	testing.expect_value(t, register_principal(&state, &alice), Principals_Refusal.None)

	// Locked principal cannot apply disk rows.
	locked_req := rd.Disk_Rows_Set_Request{principal = 1, generation = 1}
	before := state
	ref_locked, _ := apply_disk_rows_set(&state, &locked_req)
	testing.expect_value(t, ref_locked, Principals_Refusal.Session_State_Conflict)
	testing.expect(t, snapshot_domain_equal(&state, &before))

	testing.expect_value(t, session_transition(&state, &Session_Transition_Input{principal_id = 1, action_word = u32(Session_Action.Unlock)}), Principals_Refusal.None)

	// Non-principal-0 attempting Start_Policy is refused at the border with zero state mutation.
	bad_sp_req := rd.Disk_Rows_Set_Request{principal = 1, generation = 1, row_count = 1}
	bad_sp_req.rows[0].class_word = u32(rd.Disk_Row_Class.Start_Policy)
	bad_sp_req.rows[0].nickname, bad_sp_req.rows[0].nickname_length = fill_nickname("custom_policy")
	bad_sp_req.rows[0].module_hash = make_hash(7)
	before = state
	ref_sp, border_sp := apply_disk_rows_set(&state, &bad_sp_req)
	testing.expect_value(t, ref_sp, Principals_Refusal.Border_Validation)
	testing.expect_value(t, border_sp, rd.Disk_Rows_Set_Refusal.Start_Policy_Requires_Principal_Zero)
	testing.expect(t, snapshot_domain_equal(&state, &before))

	// Valid Disk_Rows_Set for principal 0 with Store + Start_Policy + Client_Key.
	req0 := rd.Disk_Rows_Set_Request{principal = 0, generation = 1, row_count = 3}
	req0.rows[0].class_word = u32(rd.Disk_Row_Class.Store)
	req0.rows[0].nickname, req0.rows[0].nickname_length = fill_nickname("notes_app")
	req0.rows[0].module_hash = make_hash(1)
	req0.rows[0].store_blocks = 256
	req0.rows[1].class_word = u32(rd.Disk_Row_Class.Start_Policy)
	req0.rows[1].nickname, req0.rows[1].nickname_length = fill_nickname("boot_policy")
	req0.rows[1].module_hash = make_hash(2)
	req0.rows[2].class_word = u32(rd.Disk_Row_Class.Client_Key)
	req0.rows[2].client_key = make_key(60)
	req0.rows[2].client_uses_word = remote.client_uses_word({.Calls, .View})

	ref_ok, border_ok := apply_disk_rows_set(&state, &req0)
	testing.expect_value(t, ref_ok, Principals_Refusal.None)
	testing.expect_value(t, border_ok, rd.Disk_Rows_Set_Refusal.None)
	testing.expect(t, state.start_policy.active)
	testing.expect_value(t, state.principals[0].store_row_count, u32(1))
	testing.expect_value(t, state.counters.active_client_keys, u64(1))

	// Stale generation (same or lower) refused with zero state mutation.
	before = state
	stale_ref, _ := apply_disk_rows_set(&state, &req0)
	testing.expect_value(t, stale_ref, Principals_Refusal.Stale_Generation)
	testing.expect(t, snapshot_domain_equal(&state, &before))

	// Principal 1 attempting to claim principal 0's client key is refused atomically.
	dup_ck_req := rd.Disk_Rows_Set_Request{principal = 1, generation = 1, row_count = 2}
	dup_ck_req.rows[0].class_word = u32(rd.Disk_Row_Class.Store)
	dup_ck_req.rows[0].nickname, dup_ck_req.rows[0].nickname_length = fill_nickname("alice_tool")
	dup_ck_req.rows[0].module_hash = make_hash(9)
	dup_ck_req.rows[0].store_blocks = 64
	dup_ck_req.rows[1].class_word = u32(rd.Disk_Row_Class.Client_Key)
	dup_ck_req.rows[1].client_key = make_key(60) // Owned by principal 0.
	dup_ck_req.rows[1].client_uses_word = remote.client_uses_word({.Calls})
	before = state
	dup_ref, _ := apply_disk_rows_set(&state, &dup_ck_req)
	testing.expect_value(t, dup_ref, Principals_Refusal.Duplicate_Client_Key)
	testing.expect(t, snapshot_domain_equal(&state, &before))

	// Build canonical Disk_Rows_Set_Request from state and verify it passes border validation.
	built, build_ref := build_disk_rows_set_request(&state, 0)
	testing.expect_value(t, build_ref, Principals_Refusal.None)
	testing.expect_value(t, built.generation, u64(2))
	testing.expect_value(t, built.row_count, u32(3))
	testing.expect_value(t, rd.validate_disk_rows_set_request(&built).refusal, rd.Disk_Rows_Set_Refusal.None)
}

@(test)
client_keys_and_start_policy_refuse_every_invalid_edge :: proc(t: ^testing.T) {
	state: Principals_State
	state_init(&state)

	// Register and unlock two named principals so we can test global CLIENT_CAPACITY (8)
	// as well as per-principal CLIENT_ROWS_OF_ONE_PRINCIPAL (4).
	for id in u64(1) ..= u64(2) {
		inp := Register_Principal_Input{principal_id = id, public_key = make_key(u8(id))}
		inp.name[0] = 'u'
		inp.name[1] = u8('0' + id)
		inp.name_length = 2
		testing.expect_value(t, register_principal(&state, &inp), Principals_Refusal.None)
		testing.expect_value(t, session_transition(&state, &Session_Transition_Input{principal_id = id, action_word = u32(Session_Action.Unlock)}), Principals_Refusal.None)
	}

	// Refused: zero key, bad uses (0, Input without View, unknown bit).
	before := state
	_, r_zero := client_key_command(&state, &Client_Key_Input{principal_id = 0, action_word = u32(Client_Key_Action.Allow), client_uses_word = remote.client_uses_word({.Calls})})
	testing.expect_value(t, r_zero, Principals_Refusal.Zero_Client_Key)
	for bad_uses in ([?]u64{0, remote.client_uses_word({.Input}), remote.client_uses_word({.Calls, .Input}), u64(1) << 3, max(u64)}) {
		_, r_uses := client_key_command(&state, &Client_Key_Input{principal_id = 0, action_word = u32(Client_Key_Action.Allow), client_key = make_key(70), client_uses_word = bad_uses})
		testing.expect_value(t, r_uses, Principals_Refusal.Bad_Client_Uses)
	}
	testing.expect(t, snapshot_domain_equal(&state, &before))

	// Fill principal 0's 4 client key slots; 5th is refused with Principal_Client_Limit.
	for i in u8(0) ..< u8(remote.CLIENT_ROWS_OF_ONE_PRINCIPAL) {
		_, r := client_key_command(&state, &Client_Key_Input{principal_id = 0, action_word = u32(Client_Key_Action.Allow), client_key = make_key(100 + i), client_uses_word = remote.client_uses_word({.Calls})})
		testing.expect_value(t, r, Principals_Refusal.None)
	}
	before = state
	_, r_p_limit := client_key_command(&state, &Client_Key_Input{principal_id = 0, action_word = u32(Client_Key_Action.Allow), client_key = make_key(199), client_uses_word = remote.client_uses_word({.Calls})})
	testing.expect_value(t, r_p_limit, Principals_Refusal.Principal_Client_Limit)
	testing.expect(t, snapshot_domain_equal(&state, &before))

	// Duplicate client key across principals refused.
	before = state
	_, r_dup := client_key_command(&state, &Client_Key_Input{principal_id = 1, action_word = u32(Client_Key_Action.Allow), client_key = make_key(100), client_uses_word = remote.client_uses_word({.Calls})})
	testing.expect_value(t, r_dup, Principals_Refusal.Duplicate_Client_Key)
	testing.expect(t, snapshot_domain_equal(&state, &before))

	// Cross-principal revoke refused (no confused deputy).
	before = state
	_, r_wrong := client_key_command(&state, &Client_Key_Input{principal_id = 1, action_word = u32(Client_Key_Action.Revoke), client_key = make_key(100)})
	testing.expect_value(t, r_wrong, Principals_Refusal.Wrong_Principal)
	testing.expect(t, snapshot_domain_equal(&state, &before))

	// Fill principal 1's 4 slots -> global table now has 8 / 8 keys; principal 2's 1st key is refused with Client_Table_Full.
	for i in u8(0) ..< u8(remote.CLIENT_ROWS_OF_ONE_PRINCIPAL) {
		_, r := client_key_command(&state, &Client_Key_Input{principal_id = 1, action_word = u32(Client_Key_Action.Allow), client_key = make_key(150 + i), client_uses_word = remote.client_uses_word({.Calls})})
		testing.expect_value(t, r, Principals_Refusal.None)
	}
	before = state
	_, r_full := client_key_command(&state, &Client_Key_Input{principal_id = 2, action_word = u32(Client_Key_Action.Allow), client_key = make_key(200), client_uses_word = remote.client_uses_word({.Calls})})
	testing.expect_value(t, r_full, Principals_Refusal.Client_Table_Full)
	testing.expect(t, snapshot_domain_equal(&state, &before))

	// Principal 2 trying to add a key via Disk_Rows_Set also refuses with Client_Table_Full and zero mutation.
	req_full := rd.Disk_Rows_Set_Request{principal = 2, generation = 1, row_count = 1}
	req_full.rows[0].class_word = u32(rd.Disk_Row_Class.Client_Key)
	req_full.rows[0].client_key = make_key(201)
	req_full.rows[0].client_uses_word = remote.client_uses_word({.Calls})
	before = state
	r_req_full, _ := apply_disk_rows_set(&state, &req_full)
	testing.expect_value(t, r_req_full, Principals_Refusal.Client_Table_Full)
	testing.expect(t, snapshot_domain_equal(&state, &before))

	// Revoke one key of principal 0, verify absent revoke refuses, and principal 2 can now allow one key.
	_, r_rev := client_key_command(&state, &Client_Key_Input{principal_id = 0, action_word = u32(Client_Key_Action.Revoke), client_key = make_key(100)})
	testing.expect_value(t, r_rev, Principals_Refusal.None)
	_, r_rev_again := client_key_command(&state, &Client_Key_Input{principal_id = 0, action_word = u32(Client_Key_Action.Revoke), client_key = make_key(100)})
	testing.expect_value(t, r_rev_again, Principals_Refusal.Client_Key_Not_Found)
	_, r_p2_ok := client_key_command(&state, &Client_Key_Input{principal_id = 2, action_word = u32(Client_Key_Action.Allow), client_key = make_key(200), client_uses_word = remote.client_uses_word({.Calls})})
	testing.expect_value(t, r_p2_ok, Principals_Refusal.None)

	// Start policy commands: non-principal-0 refused, bad nickname/hash refused, machine passphrase blocks choice.
	sp_bad_p := Start_Policy_Input{principal_id = 1, action_word = u32(Start_Policy_Action.Set_Choice), module_hash = make_hash(5)}
	sp_bad_p.nickname, sp_bad_p.nickname_length = fill_nickname("custom_policy")
	before = state
	testing.expect_value(t, start_policy_command(&state, &sp_bad_p), Principals_Refusal.Start_Policy_Requires_Principal_Zero)
	testing.expect(t, snapshot_domain_equal(&state, &before))

	sp_zero_hash := Start_Policy_Input{principal_id = 0, action_word = u32(Start_Policy_Action.Set_Choice)}
	sp_zero_hash.nickname, sp_zero_hash.nickname_length = fill_nickname("custom_policy")
	testing.expect_value(t, start_policy_command(&state, &sp_zero_hash), Principals_Refusal.Zero_Module_Hash)

	sp_reserved := Start_Policy_Input{principal_id = 0, action_word = u32(Start_Policy_Action.Set_Choice), module_hash = make_hash(5)}
	sp_reserved.nickname, sp_reserved.nickname_length = fill_nickname("root")
	testing.expect_value(t, start_policy_command(&state, &sp_reserved), Principals_Refusal.Invalid_Nickname)

	sp_ok := Start_Policy_Input{principal_id = 0, action_word = u32(Start_Policy_Action.Set_Choice), module_hash = make_hash(5)}
	sp_ok.nickname, sp_ok.nickname_length = fill_nickname("custom_policy")
	testing.expect_value(t, start_policy_command(&state, &sp_ok), Principals_Refusal.None)
	testing.expect(t, state.start_policy.active)

	// Enabling machine passphrase clears active start policy and refuses new choices.
	testing.expect_value(t, start_policy_command(&state, &Start_Policy_Input{principal_id = 0, action_word = u32(Start_Policy_Action.Set_Passphrase_Required), passphrase_required = true}), Principals_Refusal.None)
	testing.expect(t, !state.start_policy.active)
	before = state
	testing.expect_value(t, start_policy_command(&state, &sp_ok), Principals_Refusal.Start_Policy_Forbidden_With_Passphrase)
	testing.expect(t, snapshot_domain_equal(&state, &before))
}
