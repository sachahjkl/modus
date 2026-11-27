#+build !freestanding
#+build !modus
package wide_grants

import "core:testing"
import "modus:contract/blake3"
import pr "modus:contract/plans_recipes"

@(private = "file")
audit_id_of :: proc(seed: u8) -> (id: [MACHINE_AUDIT_IDENTIFIER_SIZE]u8) {
	for &b, index in id {
		b = seed + u8(index + 1)
	}
	return id
}

@(private = "file")
make_machine_terms :: proc(authorities: Wide_Authorities) -> Wide_Grant_Terms {
	terms := Wide_Grant_Terms {
		principal_id          = 0,
		grantee_identity_hash = blake3.hash(transmute([]u8)string("principal-alice")),
		authorities_word      = wide_authorities_to_word(authorities),
		target_window_count   = 0,
		duration_ms           = DEFAULT_WIDE_GRANT_DURATION_MS,
		survives_restart      = false,
	}
	_ = wide_grant_terms_seal(&terms)
	return terms
}

// Machine wide grants use principal 0, zero target windows, and a non-empty
// subset of MACHINE_AUTHORITIES; mixing agent and machine authorities, setting
// a non-zero principal, or supplying windows is refused.
@(test)
machine_wide_grant_terms_refuse_every_mixed_or_wrong_principal_edge :: proc(t: ^testing.T) {
	// Valid machine wide grants: Principals, System, and both.
	for auths in ([?]Wide_Authorities{{.Machine_Principals}, {.Machine_System}, {.Machine_Principals, .Machine_System}}) {
		terms := make_machine_terms(auths)
		testing.expect_value(t, wide_grant_terms_validate(&terms), Wide_Grant_Refusal.None)
	}

	// Refused: non-zero principal with machine authorities.
	{
		terms := make_machine_terms({.Machine_Principals})
		terms.principal_id = 1
		testing.expect_value(t, wide_grant_terms_seal(&terms), Wide_Grant_Refusal.Invalid_Authority)
	}

	// Refused: mixing machine and agent authorities.
	{
		terms := make_machine_terms({.Machine_Principals, .View_Screen})
		terms.target_window_count = 1
		terms.target_window_ids[0] = 10
		testing.expect_value(t, wide_grant_terms_seal(&terms), Wide_Grant_Refusal.Invalid_Authority)
	}

	// Refused: machine wide grant with non-zero target windows or dirty tail.
	{
		terms := make_machine_terms({.Machine_System})
		terms.target_window_count = 1
		terms.target_window_ids[0] = 10
		testing.expect_value(t, wide_grant_terms_seal(&terms), Wide_Grant_Refusal.Too_Many_Windows)

		terms = make_machine_terms({.Machine_System})
		terms.target_window_ids[0] = 10
		testing.expect_value(t, wide_grant_terms_seal(&terms), Wide_Grant_Refusal.Too_Many_Windows)
	}

	// Border parsers for machine audit act kinds and authorities.
	for bad in ([?]u64{0, u64(max(Machine_Audit_Act_Kind)) + 1, max(u64)}) {
		_, ok := machine_audit_act_kind_from_word(bad)
		testing.expect(t, !ok)
	}
	for kind in Machine_Audit_Act_Kind {
		if kind == .None {
			continue
		}
		got, ok := machine_audit_act_kind_from_word(u64(kind))
		testing.expect(t, ok && got == kind)
	}
	for bad_mask in ([?]u64{0, wide_authorities_to_word({.View_Screen}), wide_authorities_to_word({.Machine_Principals, .View_Screen}), max(u64)}) {
		_, ok := machine_grant_authorities_of_word(bad_mask)
		testing.expect(t, !ok)
	}
}

// Machine audit record encode/decode refuses invalid act kinds, agent
// authorities, non-zero reserved words, and short buffers.
@(test)
machine_audit_record_encode_decode_refusals :: proc(t: ^testing.T) {
	rec := Machine_Audit_Record {
		grant_serial      = 42,
		timestamp_ms      = 1000,
		act_kind_word     = u64(Machine_Audit_Act_Kind.Principal_Removed),
		scopes_word       = wide_authorities_to_word({.Machine_Principals}),
		actor_identifier  = audit_id_of(1),
		target_identifier = audit_id_of(2),
		detail_word_0     = 7,
		detail_word_1     = 9,
	}
	buf: [MACHINE_AUDIT_RECORD_SIZE]u8
	testing.expect(t, !machine_audit_record_encode(&rec, buf[:MACHINE_AUDIT_RECORD_SIZE - 1]))
	testing.expect(t, !machine_audit_record_encode(nil, buf[:]))

	bad := rec
	bad.act_kind_word = 0
	testing.expect(t, !machine_audit_record_encode(&bad, buf[:]))

	bad = rec
	bad.scopes_word = wide_authorities_to_word({.View_Screen})
	testing.expect(t, !machine_audit_record_encode(&bad, buf[:]))

	bad = rec
	bad.reserved_0 = 1
	testing.expect(t, !machine_audit_record_encode(&bad, buf[:]))

	testing.expect(t, machine_audit_record_encode(&rec, buf[:]))
	decoded, ok := machine_audit_record_decode(buf[:])
	testing.expect(t, ok && decoded == rec)

	_, short_ok := machine_audit_record_decode(buf[:MACHINE_AUDIT_RECORD_SIZE - 1])
	testing.expect(t, !short_ok)

	tampered := buf
	tampered[112] = 1
	_, tampered_ok := machine_audit_record_decode(tampered[:])
	testing.expect(t, !tampered_ok)
}

// On principal 0's collector:
// - The machine audit space cannot be opened via space_open_allowed.
// - Every admitted named principal can list, stat, and read the machine audit
//   space, while every other space of principal 0 is hidden and refused.
// - A caller that does not act for its principal is refused even on the
//   machine audit space.
// - When the machine audit space reaches its bound, ordinary acts fail with
//   Space_Full, while the Machine_Wide_Grant_Ended act is exempt, passes
//   space_verify, and reloads cleanly after a collector restart.
@(test)
machine_audit_space_shared_read_and_end_act_exemption :: proc(t: ^testing.T) {
	mem := new(pr.Memory_Private_Store)
	defer free(mem)
	mem.writes_allowed = -1
	port := pr.memory_private_store_port(mem)
	machine_id := audit_id_of(99)

	store := new(Space_Store)
	defer free(store)
	space_store_init(store, 0, machine_id, port, space_window_heap_port())

	// space_open_allowed refuses opening the machine audit space externally.
	p0_console := Space_Reader{principal = 0, acts_for_principal = true}
	copy(p0_console.name[:], "console")
	testing.expect_value(t, space_open_allowed(store, transmute([]u8)string(MACHINE_AUDIT_SOURCE), transmute([]u8)string(MACHINE_AUDIT_OUTPUT), &p0_console), Space_Refusal.Act_Space)

	// Open the machine audit space directly (as root/collector wiring does)
	// with bound 3, plus a private space of principal 0.
	audit_terms := Space_Terms {
		kind_word       = i64(Collector_Space_Kind.Audit),
		bound_records   = 3,
		forwarding_word = i64(Space_Forwarding.Keeps),
		record_size     = MACHINE_AUDIT_RECORD_SIZE,
	}
	audit_space, open_refusal := space_open(store, transmute([]u8)string(MACHINE_AUDIT_SOURCE), transmute([]u8)string(MACHINE_AUDIT_OUTPUT), audit_terms)
	testing.expect_value(t, open_refusal, Space_Refusal.None)
	testing.expect(t, audit_space >= 1)

	private_terms := Space_Terms {
		kind_word       = i64(Collector_Space_Kind.Audit),
		bound_records   = 4,
		forwarding_word = i64(Space_Forwarding.Keeps),
		record_size     = 8,
	}
	private_space, priv_refusal := space_open(store, transmute([]u8)string("storage"), transmute([]u8)string("events"), private_terms)
	testing.expect_value(t, priv_refusal, Space_Refusal.None)
	priv_data := [8]u8{1, 2, 3, 4, 5, 6, 7, 8}
	_, priv_app := record_append(store, private_space, priv_data[:], 100)
	testing.expect_value(t, priv_app, Space_Refusal.None)

	// Fill the machine audit space to its exact bound (3 records).
	for i in u64(0) ..< 3 {
		rec := Machine_Audit_Record {
			grant_serial      = 10,
			timestamp_ms      = 200 + i * 10,
			act_kind_word     = u64(i == 0 ? Machine_Audit_Act_Kind.Machine_Wide_Grant_Started : Machine_Audit_Act_Kind.System_Action),
			scopes_word       = wide_authorities_to_word({.Machine_System}),
			actor_identifier  = audit_id_of(1),
			target_identifier = audit_id_of(2),
			detail_word_0     = i,
		}
		serial, app_refusal := machine_audit_append(store, audit_space, &rec)
		testing.expect_value(t, app_refusal, Space_Refusal.None)
		testing.expect_value(t, serial, i)
	}

	// Fourth ordinary act is refused with Space_Full.
	extra := Machine_Audit_Record {
		grant_serial     = 10,
		timestamp_ms     = 250,
		act_kind_word    = u64(Machine_Audit_Act_Kind.System_Action),
		scopes_word      = wide_authorities_to_word({.Machine_System}),
		actor_identifier = audit_id_of(1),
	}
	_, full_refusal := machine_audit_append(store, audit_space, &extra)
	testing.expect_value(t, full_refusal, Space_Refusal.Space_Full)

	// The end act is exempt from Space_Full and appends cleanly as serial 3.
	end_rec := Machine_Audit_Record {
		grant_serial     = 10,
		timestamp_ms     = 260,
		act_kind_word    = u64(Machine_Audit_Act_Kind.Machine_Wide_Grant_Ended),
		scopes_word      = wide_authorities_to_word({.Machine_System}),
		actor_identifier = audit_id_of(1),
	}
	end_serial, end_refusal := machine_audit_append(store, audit_space, &end_rec)
	testing.expect_value(t, end_refusal, Space_Refusal.None)
	testing.expect_value(t, end_serial, u64(3))

	// A second end act past bound+1 is refused so unbounded growth is impossible.
	_, second_end := machine_audit_append(store, audit_space, &end_rec)
	testing.expect_value(t, second_end, Space_Refusal.Space_Full)

	// Verify the hash chain in memory and on store.
	verify_refusal, _ := space_verify(store, audit_space)
	testing.expect_value(t, verify_refusal, Space_Refusal.None)

	// Admitted named principal (principal 2) sees ONLY the machine audit space.
	alice := Space_Reader{principal = 2, acts_for_principal = true}
	copy(alice.name[:], "console")
	rows: [8]Space_Row
	row_count, rows_refusal := space_rows(store, &alice, rows[:])
	testing.expect_value(t, rows_refusal, Space_Refusal.None)
	testing.expect_value(t, row_count, 1)
	testing.expect_value(t, rows[0].space, i64(audit_space))

	// Alice reads all 4 records (including the exempt end act) cleanly.
	heads: [8]Kept_Record_Head
	bytes: [8 * MACHINE_AUDIT_RECORD_SIZE]u8
	read_count, read_refusal := records_read(store, audit_space, -1, 8, &alice, heads[:], bytes[:])
	testing.expect_value(t, read_refusal, Space_Refusal.None)
	testing.expect_value(t, read_count, 4)
	last_rec, last_ok := machine_audit_record_decode(bytes[3 * MACHINE_AUDIT_RECORD_SIZE:4 * MACHINE_AUDIT_RECORD_SIZE])
	testing.expect(t, last_ok && last_rec.act_kind_word == u64(Machine_Audit_Act_Kind.Machine_Wide_Grant_Ended))

	// Alice is refused uniformly with Not_Principal on active private space,
	// removed private space, and absent space (no existence oracle).
	removed_space, rem_open := space_open(store, transmute([]u8)string("temp"), transmute([]u8)string("log"), private_terms)
	testing.expect_value(t, rem_open, Space_Refusal.None)
	space_close(store, removed_space)
	_, rem_date_ref := space_closed_pass(store, 280, true, 0)
	testing.expect_value(t, rem_date_ref, Space_Refusal.None)
	rem_count, rem_pass_ref := space_closed_pass(store, 280, true, 0)
	testing.expect_value(t, rem_pass_ref, Space_Refusal.None)
	testing.expect_value(t, rem_count, 1)
	// Confirm principal 0 sees Space_Removed for removed_space vs Unknown_Space for absent,
	// while Alice sees uniform Not_Principal for all three.
	_, p0_rem_ref := space_stats(store, removed_space, &p0_console)
	testing.expect_value(t, p0_rem_ref, Space_Refusal.Space_Removed)
	absent_space := u32(10)
	_, p0_abs_ref := space_stats(store, absent_space, &p0_console)
	testing.expect_value(t, p0_abs_ref, Space_Refusal.Unknown_Space)
	for probe in ([?]u32{private_space, removed_space, absent_space}) {
		_, r_ref := records_read(store, probe, -1, 8, &alice, heads[:], bytes[:])
		testing.expect_value(t, r_ref, Space_Refusal.Not_Principal)
		_, s_ref := space_stats(store, probe, &alice)
		testing.expect_value(t, s_ref, Space_Refusal.Not_Principal)
	}

	// Non-machine-audit space refuses machine_audit_append and refuses the
	// bound+1 end exemption even if called with exempt_full_end = true.
	_, wrong_space_ref := machine_audit_append(store, private_space, &end_rec)
	testing.expect_value(t, wrong_space_ref, Space_Refusal.Bad_Kind)
	for i in u64(1) ..< 4 {
		_, p_app := record_append(store, private_space, priv_data[:], 100 + i)
		testing.expect_value(t, p_app, Space_Refusal.None)
	}
	_, bypass_ref := record_append_with_end_exemption(store, private_space, priv_data[:], 110, true)
	testing.expect_value(t, bypass_ref, Space_Refusal.Space_Full)
	testing.expect_value(t, space_of(store, private_space).next_serial, u64(4))

	// Non-acting caller is refused even on the machine audit space.
	unprivileged := Space_Reader{principal = 2, acts_for_principal = false}
	copy(unprivileged.name[:], "app")
	_, unpriv_ref := records_read(store, audit_space, -1, 8, &unprivileged, heads[:], bytes[:])
	testing.expect_value(t, unpriv_ref, Space_Refusal.Not_Principal)

	// Reload the store from disk: all 4 records (bound + 1 exempt end act)
	// reload and verify cleanly!
	reloaded := new(Space_Store)
	defer free(reloaded)
	space_store_init(reloaded, 0, machine_id, port, space_window_heap_port())
	testing.expect_value(t, space_store_ready(reloaded), Space_Refusal.None)
	re_verify, _ := space_verify(reloaded, audit_space)
	testing.expect_value(t, re_verify, Space_Refusal.None)
	re_count, re_read := records_read(reloaded, audit_space, -1, 8, &alice, heads[:], bytes[:])
	testing.expect_value(t, re_read, Space_Refusal.None)
	testing.expect_value(t, re_count, 4)
}

// A refused Forward_Full append on a machine audit space at SPACE_AUDIT_BOUND_MOST
// must not rotate or mutate kept_first_serial before returning Forward_Full.
@(test)
machine_audit_forward_full_refuses_without_rotating :: proc(t: ^testing.T) {
	mem := new(pr.Memory_Private_Store)
	defer free(mem)
	mem.writes_allowed = -1
	port := pr.memory_private_store_port(mem)
	store := new(Space_Store)
	defer free(store)
	space_store_init(store, 0, audit_id_of(77), port, space_window_heap_port())

	terms := Space_Terms {
		kind_word       = i64(Collector_Space_Kind.Audit),
		bound_records   = SPACE_AUDIT_BOUND_MOST,
		forwarding_word = i64(Space_Forwarding.Forward),
		record_size     = MACHINE_AUDIT_RECORD_SIZE,
	}
	audit_space, open_ref := space_open(store, transmute([]u8)string(MACHINE_AUDIT_SOURCE), transmute([]u8)string(MACHINE_AUDIT_OUTPUT), terms)
	testing.expect_value(t, open_ref, Space_Refusal.None)

	// Fill the forward queue to FORWARD_QUEUE_PER_SPACE_LIMIT and simulate
	// kept == SPACE_AUDIT_BOUND_MOST so the end-exemption path would rotate if
	// Forward_Full were not checked first.
	rec := Machine_Audit_Record {
		grant_serial  = 5,
		timestamp_ms  = 100,
		act_kind_word = u64(Machine_Audit_Act_Kind.System_Action),
		scopes_word   = wide_authorities_to_word({.Machine_System}),
	}
	for i in 0 ..< FORWARD_QUEUE_PER_SPACE_LIMIT {
		rec.timestamp_ms = u64(100 + i)
		_, app_ref := machine_audit_append(store, audit_space, &rec)
		testing.expect_value(t, app_ref, Space_Refusal.None)
	}
	held := space_of(store, audit_space)
	saved_kept_first := held.kept_first_serial
	saved_next := held.next_serial
	held.next_serial = saved_kept_first + SPACE_AUDIT_BOUND_MOST

	end_rec := rec
	end_rec.act_kind_word = u64(Machine_Audit_Act_Kind.Machine_Wide_Grant_Ended)
	_, ref := machine_audit_append(store, audit_space, &end_rec)
	testing.expect_value(t, ref, Space_Refusal.Forward_Full)
	testing.expect_value(t, held.kept_first_serial, saved_kept_first)
	held.next_serial = saved_next
}
