#+build !freestanding
package plans_recipes

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/object_cache"
import "modus:contract/powerbox"
import "modus:contract/start_grant"
import "modus:contract/tree_hash"

@(private = "file")
make_hash :: proc(tag: u8) -> blake3.Hash {
	data := [4]u8{'t', 'e', 's', tag}
	return blake3.hash(data[:])
}

@(private = "file")
make_key :: proc(tag: u8) -> [object_cache.PUBLIC_KEY_SIZE]u8 {
	key: [object_cache.PUBLIC_KEY_SIZE]u8
	for index in 0 ..< len(key) {
		key[index] = tag ~ u8(index + 1)
	}
	return key
}

@(private = "file")
mock_sign :: proc(public_key: [object_cache.PUBLIC_KEY_SIZE]u8, message: []u8) -> [object_cache.SIGNATURE_SIZE]u8 {
	sig: [object_cache.SIGNATURE_SIZE]u8
	first := blake3.derive_key("test-sig-1", message)
	key_copy := public_key
	second := blake3.derive_key("test-sig-2", key_copy[:])
	for index in 0 ..< 32 {
		sig[index] = first[index] ~ second[index]
		sig[32 + index] = first[31 - index] ~ second[index]
	}
	return sig
}

@(private = "file")
mock_verify :: proc "contextless" (
	public_key: [object_cache.PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [object_cache.SIGNATURE_SIZE]u8,
	user_data: rawptr,
) -> bool {
	_ = user_data
	first := blake3.derive_key("test-sig-1", message)
	key_copy := public_key
	second := blake3.derive_key("test-sig-2", key_copy[:])
	for index in 0 ..< 32 {
		if signature[index] != (first[index] ~ second[index]) {
			return false
		}
		if signature[32 + index] != (first[31 - index] ~ second[index]) {
			return false
		}
	}
	return true
}

@(test)
test_plan_validation_refusals_and_cycles :: proc(t: ^testing.T) {
	// Nil and empty plans are refused.
	refusal, _ := plan_validate(nil)
	testing.expect_value(t, refusal, Plan_Refusal.Empty_Plan)

	empty := test_plan(0, 0)
	refusal, _ = plan_validate(&empty)
	testing.expect_value(t, refusal, Plan_Refusal.Empty_Plan)

	// A count past the memory of the plan, by one and by the most of the
	// field, and an order shorter than the count.
	too_many := test_plan(0, 1, 1)
	too_many.entries[0], _ = plan_entry_make_module(.Disk_Module, "app", make_hash(1))
	for count in ([2]u32{2, max(u32)}) {
		too_many.entry_count = count
		refusal, _ = plan_validate(&too_many)
		testing.expect_value(t, refusal, Plan_Refusal.Too_Many_Entries)
	}
	too_many.entry_count = 1
	short_order := too_many
	short_order.order = nil
	refusal, _ = plan_validate(&short_order)
	testing.expect_value(t, refusal, Plan_Refusal.Buffer_Too_Small)
	refusal, _ = plan_validate(&too_many)
	testing.expect_value(t, refusal, Plan_Refusal.None)

	// Bad entry kind word (0 and unknown).
	bad_kind := test_plan(0, 1)
	bad_kind.entries[0].kind_word = 0
	refusal, _ = plan_validate(&bad_kind)
	testing.expect_value(t, refusal, Plan_Refusal.Bad_Entry_Kind)

	bad_kind.entries[0].kind_word = 99
	refusal, _ = plan_validate(&bad_kind)
	testing.expect_value(t, refusal, Plan_Refusal.Bad_Entry_Kind)

	// Invalid names (empty, path traversal, non-zero tail padding).
	bad_name := test_plan(0, 1)
	e, _ := plan_entry_make_module(.Disk_Module, "app", make_hash(1))
	bad_name.entries[0] = e
	bad_name.entries[0].name_length = 0
	refusal, _ = plan_validate(&bad_name)
	testing.expect_value(t, refusal, Plan_Refusal.Invalid_Name)

	bad_name.entries[0] = e
	bad_name.entries[0].name_bytes[0] = '.'
	bad_name.entries[0].name_bytes[1] = '.'
	bad_name.entries[0].name_length = 2
	refusal, _ = plan_validate(&bad_name)
	testing.expect_value(t, refusal, Plan_Refusal.Invalid_Name)

	bad_name.entries[0] = e
	bad_name.entries[0].name_bytes[10] = 'x' // non-zero tail byte
	refusal, _ = plan_validate(&bad_name)
	testing.expect_value(t, refusal, Plan_Refusal.Invalid_Name)

	// Zero module hash refused.
	zero_mod := test_plan(0, 1)
	zero_mod.entries[0], _ = plan_entry_make_module(.Disk_Module, "app", {})
	refusal, _ = plan_validate(&zero_mod)
	testing.expect_value(t, refusal, Plan_Refusal.Zero_Module_Hash)

	// System_Part grant bit and unknown grant bits are refused.
	sys_grant := test_plan(0, 1)
	sys_grant.entries[0], _ = plan_entry_make_module(.Start_Module, "svc", make_hash(2), u64(1) << u64(start_grant.Grant.System_Part))
	refusal, _ = plan_validate(&sys_grant)
	testing.expect_value(t, refusal, Plan_Refusal.Bad_Start_Grant)

	sys_grant.entries[0], _ = plan_entry_make_module(.Start_Module, "svc", make_hash(2), u64(1) << 63)
	refusal, _ = plan_validate(&sys_grant)
	testing.expect_value(t, refusal, Plan_Refusal.Bad_Start_Grant)

	// Non-principal-0 cannot replace a trusted-path role (Display).
	non_zero_tp := test_plan(1, 1)
	non_zero_tp.entries[0], _ = plan_entry_make_role("display", .Display, make_hash(3))
	refusal, _ = plan_validate(&non_zero_tp)
	testing.expect_value(t, refusal, Plan_Refusal.Trusted_Path_Forbidden)

	// Principal 0 CAN assign Display.
	non_zero_tp.principal = 0
	refusal, _ = plan_validate(&non_zero_tp)
	testing.expect_value(t, refusal, Plan_Refusal.None)

	// Duplicate single-holder role refused.
	dup_role := test_plan(0, 2)
	dup_role.entries[0], _ = plan_entry_make_role("net_a", .Network, make_hash(4))
	dup_role.entries[1], _ = plan_entry_make_role("net_b", .Network, make_hash(5))
	refusal, _ = plan_validate(&dup_role)
	testing.expect_value(t, refusal, Plan_Refusal.Duplicate_Entry)

	// Self-cyclic role interposition refused.
	self_cycle := test_plan(0, 1)
	self_cycle.entries[0], _ = plan_entry_make_role("net_a", .Network, make_hash(4), make_hash(4))
	refusal, _ = plan_validate(&self_cycle)
	testing.expect_value(t, refusal, Plan_Refusal.Cyclic_Role_Chain)

	// 2-node cyclic Assistive interposition chain refused.
	two_cycle := test_plan(0, 2)
	two_cycle.entries[0], _ = plan_entry_make_role("a1", .Assistive, make_hash(10), make_hash(11))
	two_cycle.entries[1], _ = plan_entry_make_role("a2", .Assistive, make_hash(11), make_hash(10))
	refusal, _ = plan_validate(&two_cycle)
	testing.expect_value(t, refusal, Plan_Refusal.Cyclic_Role_Chain)

	// Acyclic Assistive interposition chain is accepted.
	acyclic := test_plan(0, 2)
	acyclic.entries[0], _ = plan_entry_make_role("a1", .Assistive, make_hash(10), make_hash(11))
	acyclic.entries[1], _ = plan_entry_make_role("a2", .Assistive, make_hash(11), {})
	refusal, _ = plan_validate(&acyclic)
	testing.expect_value(t, refusal, Plan_Refusal.None)
}

@(test)
test_plan_hash_order_independent_and_diff_grants :: proc(t: ^testing.T) {
	store_grant_bit := u64(1) << u64(start_grant.Grant.Store)
	net_grant_bit := u64(1) << u64(start_grant.Grant.Network)

	plan_a := test_plan(0, 3)
	plan_a.entries[0], _ = plan_entry_make_module(.Disk_Module, "editor", make_hash(1), store_grant_bit)
	plan_a.entries[1], _ = plan_entry_make_store("docs", .Read_Only)
	plan_a.entries[2], _ = plan_entry_make_role("storage", .Storage, make_hash(2))

	// Same entries in reversed order must produce the exact same plan_hash.
	plan_a_rev := test_plan(0, 3)
	plan_a_rev.entries[0] = plan_a.entries[2]
	plan_a_rev.entries[1] = plan_a.entries[1]
	plan_a_rev.entries[2] = plan_a.entries[0]

	hash_a, ref_a := plan_hash(&plan_a)
	hash_rev, ref_rev := plan_hash(&plan_a_rev)
	testing.expect_value(t, ref_a, Plan_Refusal.None)
	testing.expect_value(t, ref_rev, Plan_Refusal.None)
	testing.expect_value(t, hash_a, hash_rev)

	// Nil output buffer is refused cleanly.
	testing.expect_value(t, plan_diff_compute(&plan_a, &plan_a_rev, nil), Plan_Refusal.Buffer_Too_Small)

	// Diff against identical plan has no changes and no added grants.
	diff_same := test_difference()
	ref_same := plan_diff_compute(&plan_a, &plan_a_rev, &diff_same)
	testing.expect_value(t, ref_same, Plan_Refusal.None)
	testing.expect(t, !diff_same.has_changes, "identical plans have no diff")
	testing.expect(t, !diff_same.any_grant_added, "identical plans add no grant")

	// Narrowing rights (removing Store grant from editor) adds no grant.
	plan_narrow := test_plan_copy(&plan_a)
	plan_narrow.entries[0].start_grants_mask = 0
	diff_narrow := test_difference()
	ref_narrow := plan_diff_compute(&plan_a, &plan_narrow, &diff_narrow)
	testing.expect_value(t, ref_narrow, Plan_Refusal.None)
	testing.expect(t, diff_narrow.has_changes, "removing grant is a change")
	testing.expect(t, !diff_narrow.any_grant_added, "removing grant adds no grant")
	testing.expect_value(t, diff_narrow.removed_grants_count, u32(1))

	// Adding Network grant to editor sets any_grant_added.
	plan_wide := test_plan_copy(&plan_a)
	plan_wide.entries[0].start_grants_mask = store_grant_bit | net_grant_bit
	diff_wide := test_difference()
	ref_wide := plan_diff_compute(&plan_a, &plan_wide, &diff_wide)
	testing.expect_value(t, ref_wide, Plan_Refusal.None)
	testing.expect(t, diff_wide.any_grant_added, "adding Network grant must set any_grant_added")
	testing.expect_value(t, diff_wide.added_grants_count, u32(1))

	// Widening store rights Read_Only -> Read_Write sets any_grant_added.
	plan_rw := test_plan_copy(&plan_a)
	plan_rw.entries[1].store_rights_word = u64(Plan_Store_Rights.Read_Write)
	diff_rw := test_difference()
	ref_rw := plan_diff_compute(&plan_a, &plan_rw, &diff_rw)
	testing.expect_value(t, ref_rw, Plan_Refusal.None)
	testing.expect(t, diff_rw.any_grant_added, "widening store rights must set any_grant_added")
	testing.expect_value(t, diff_rw.changed_stores, u32(1))

	// Narrowing store rights Read_Write -> Read_Only does NOT set any_grant_added.
	diff_ro := test_difference()
	ref_ro := plan_diff_compute(&plan_rw, &plan_a, &diff_ro)
	testing.expect_value(t, ref_ro, Plan_Refusal.None)
	testing.expect(t, diff_ro.has_changes, "narrowing store rights is a change")
	testing.expect(t, !diff_ro.any_grant_added, "narrowing store rights adds no grant")

	// Feed Plan_Difference directly into powerbox Request_Batch.
	batch, pb_ref := plan_difference_to_powerbox_batch(&diff_wide, 42, 7, 0, make_hash(99))
	testing.expect_value(t, pb_ref, Plan_Refusal.None)
	pb_check, _ := powerbox.request_batch_validate(&batch)
	testing.expect_value(t, pb_check, powerbox.Powerbox_Refusal.None)
	testing.expect_value(t, batch.items[0].plan_hash, diff_wide.proposed_plan_hash)
}

@(test)
test_applied_plan_wire_and_rollback :: proc(t: ^testing.T) {
	// Rollback from empty history refused.
	_, empty_ref := plan_rollback_check(nil, 0)
	testing.expect_value(t, empty_ref, Plan_Refusal.Empty_History)

	rec1 := Applied_Plan_Record {
		plan_hash          = make_hash(1),
		previous_plan_hash = {},
		generation         = 1,
		timestamp_ms       = 1000,
		principal          = 0,
	}
	rec2 := Applied_Plan_Record {
		plan_hash          = make_hash(2),
		previous_plan_hash = rec1.plan_hash,
		generation         = 2,
		timestamp_ms       = 2000,
		principal          = 0,
	}
	rec3 := Applied_Plan_Record {
		plan_hash          = make_hash(3),
		previous_plan_hash = rec2.plan_hash,
		generation         = 3,
		timestamp_ms       = 3000,
		principal          = 0,
	}

	// Rollback from generation 1 with no target refused (no earlier generation).
	one := [1]Applied_Plan_Record{rec1}
	_, ref_one := plan_rollback_check(one[:], 1)
	testing.expect_value(t, ref_one, Plan_Refusal.Empty_History)

	// Rollback from generation 3 selects generation 2.
	history := [3]Applied_Plan_Record{rec1, rec2, rec3}
	sel, ref_sel := plan_rollback_check(history[:], 3)
	testing.expect_value(t, ref_sel, Plan_Refusal.None)
	testing.expect_value(t, sel.generation, u64(2))

	// Explicit target rollback to generation 1 succeeds; to 3 refused as already current; to 99 refused.
	sel1, ref_sel1 := plan_rollback_check(history[:], 3, 1, true)
	testing.expect_value(t, ref_sel1, Plan_Refusal.None)
	testing.expect_value(t, sel1.generation, u64(1))

	_, ref_same := plan_rollback_check(history[:], 3, 3, true)
	testing.expect_value(t, ref_same, Plan_Refusal.Already_At_Generation)

	_, ref_unk := plan_rollback_check(history[:], 3, 99, true)
	testing.expect_value(t, ref_unk, Plan_Refusal.Unknown_Generation)

	// Wire encode/decode round-trip and adversarial corruption checks.
	wire: [APPLIED_PLAN_WIRE_SIZE]u8
	small: [APPLIED_PLAN_WIRE_SIZE - 1]u8
	small[0] = 0xAA
	_, small_ref := encode_applied_plan_record(&rec2, small[:])
	testing.expect_value(t, small_ref, Plan_Refusal.Buffer_Too_Small)
	testing.expect_value(t, small[0], u8(0xAA))

	written, enc_ref := encode_applied_plan_record(&rec2, wire[:])
	testing.expect_value(t, enc_ref, Plan_Refusal.None)
	testing.expect_value(t, written, APPLIED_PLAN_WIRE_SIZE)

	decoded, dec_ref := decode_applied_plan_record(wire[:])
	testing.expect_value(t, dec_ref, Plan_Refusal.None)
	testing.expect_value(t, decoded, rec2)

	// Truncated, trailing, bad magic, non-zero reserved refused.
	_, trunc_ref := decode_applied_plan_record(wire[:APPLIED_PLAN_WIRE_SIZE - 1])
	testing.expect_value(t, trunc_ref, Plan_Refusal.Truncated)

	extra: [APPLIED_PLAN_WIRE_SIZE + 1]u8
	copy(extra[:], wire[:])
	_, trail_ref := decode_applied_plan_record(extra[:])
	testing.expect_value(t, trail_ref, Plan_Refusal.Trailing_Bytes)

	bad_magic := wire
	bad_magic[0] = 'X'
	_, magic_ref := decode_applied_plan_record(bad_magic[:])
	testing.expect_value(t, magic_ref, Plan_Refusal.Bad_Header)

	bad_res := wire
	bad_res[12] = 1
	_, res_ref := decode_applied_plan_record(bad_res[:])
	testing.expect_value(t, res_ref, Plan_Refusal.Bad_Header)
}

@(test)
test_recipe_hash_stability_and_tampered_cache_refusal :: proc(t: ^testing.T) {
	in_a, ref_a := recipe_input_make("alpha", .Tree, make_hash(11))
	in_b, ref_b := recipe_input_make("beta", .Blob, make_hash(12))
	in_c, ref_c := recipe_input_make("gamma", .Tree, make_hash(13))
	testing.expect_value(t, ref_a, Recipe_Refusal.None)
	testing.expect_value(t, ref_b, Recipe_Refusal.None)
	testing.expect_value(t, ref_c, Recipe_Refusal.None)

	spec1 := Recipe_Spec {
		builder_hash       = make_hash(1),
		output_kind        = .Tree,
		source_date_unix   = 1700000000,
		output_block_limit = 512,
		input_count        = 3,
		arguments_length   = 5,
	}
	spec1.inputs[0] = in_a
	spec1.inputs[1] = in_b
	spec1.inputs[2] = in_c
	copy(spec1.arguments[:5], "opt=1")

	// Permuted input order must yield identical recipe_hash.
	spec2 := spec1
	spec2.inputs[0] = in_c
	spec2.inputs[1] = in_a
	spec2.inputs[2] = in_b

	h1, r1 := recipe_hash(&spec1)
	h2, r2 := recipe_hash(&spec2)
	testing.expect_value(t, r1, Recipe_Refusal.None)
	testing.expect_value(t, r2, Recipe_Refusal.None)
	testing.expect_value(t, h1, h2)

	// Changing one argument byte changes recipe_hash.
	spec3 := spec1
	spec3.arguments[4] = '2'
	h3, r3 := recipe_hash(&spec3)
	testing.expect_value(t, r3, Recipe_Refusal.None)
	testing.expect(t, h1 != h3, "argument change must alter recipe hash")

	// Duplicate inputs refused.
	dup_spec := spec1
	dup_spec.inputs[2] = in_a
	_, dup_ref := recipe_hash(&dup_spec)
	testing.expect_value(t, dup_ref, Recipe_Refusal.Duplicate_Input)

	// Sandbox preparation enforces zero network, read-only inputs, empty out, seed == recipe_hash.
	sandbox: Builder_Sandbox_Spec
	sb_ref := builder_sandbox_prepare(&spec1, &sandbox)
	testing.expect_value(t, sb_ref, Recipe_Refusal.None)
	testing.expect_value(t, builder_sandbox_validate(&sandbox), Recipe_Refusal.None)
	testing.expect_value(t, sandbox.random_seed, h1)
	testing.expect(t, !sandbox.allow_network && !sandbox.allow_root_ring, "sandbox must forbid network and root ring")

	tampered_sb := sandbox
	tampered_sb.allow_network = true
	testing.expect_value(t, builder_sandbox_validate(&tampered_sb), Recipe_Refusal.Sandbox_Violation)

	// Build a valid canonical tree payload and signed realisation.
	tree_entry, te_ref := tree_hash.tree_entry_make(.Object, "kernel.module", make_hash(50))
	testing.expect_value(t, te_ref, tree_hash.Tree_Refusal.None)
	tree_entries := [1]tree_hash.Tree_Entry{tree_entry}
	tree_buf: [tree_hash.HEADER_SIZE + tree_hash.ENTRY_SIZE_MOST]u8
	tree_written, enc_ref := tree_hash.tree_encode(tree_entries[:], tree_buf[:])
	testing.expect_value(t, enc_ref, tree_hash.Tree_Refusal.None)
	out_hash, out_ref := recipe_hash_output(.Tree, tree_buf[:tree_written])
	testing.expect_value(t, out_ref, Recipe_Refusal.None)

	trusted_key := make_key(7)
	untrusted_key := make_key(8)
	trusted_list := [1][object_cache.PUBLIC_KEY_SIZE]u8{trusted_key}
	policy := object_cache.Substitution_Policy{mode = .Prefer_Cache, trusted_signers = trusted_list[:]}

	realisation := object_cache.Realisation_Record {
		recipe_hash       = h1,
		output_hash       = out_hash,
		output_kind       = .Tree,
		signer_public_key = trusted_key,
	}
	sign_bytes, sign_ok := object_cache.realisation_signing_bytes(&realisation)
	testing.expect(t, sign_ok, "signing bytes valid")
	realisation.signature = mock_sign(trusted_key, sign_bytes[:])

	// Valid realisation + valid tree payload accepted.
	verified_hash, v_ref := recipe_verify_cache_realisation(&spec1, policy, &realisation, tree_buf[:tree_written], mock_verify)
	testing.expect_value(t, v_ref, Recipe_Refusal.None)
	testing.expect_value(t, verified_hash, out_hash)

	// Tampered payload byte refused.
	tampered_payload := tree_buf
	tampered_payload[tree_written - 1] ~= 0x01
	_, tam_ref := recipe_verify_cache_realisation(&spec1, policy, &realisation, tampered_payload[:tree_written], mock_verify)
	testing.expect_value(t, tam_ref, Recipe_Refusal.Hash_Mismatch)

	// Tampered signature refused.
	bad_sig := realisation
	bad_sig.signature[0] ~= 0xFF
	_, sig_ref := recipe_verify_cache_realisation(&spec1, policy, &bad_sig, tree_buf[:tree_written], mock_verify)
	testing.expect_value(t, sig_ref, Recipe_Refusal.Bad_Signature)

	// Untrusted signer refused.
	untrusted_real := realisation
	untrusted_real.signer_public_key = untrusted_key
	usign_bytes, _ := object_cache.realisation_signing_bytes(&untrusted_real)
	untrusted_real.signature = mock_sign(untrusted_key, usign_bytes[:])
	_, untrusted_ref := recipe_verify_cache_realisation(&spec1, policy, &untrusted_real, tree_buf[:tree_written], mock_verify)
	testing.expect_value(t, untrusted_ref, Recipe_Refusal.Untrusted_Realisation)

	// Build_Only policy refuses any cache realisation.
	build_only_policy := object_cache.Substitution_Policy{mode = .Build_Only, trusted_signers = trusted_list[:]}
	_, bo_ref := recipe_verify_cache_realisation(&spec1, build_only_policy, &realisation, tree_buf[:tree_written], mock_verify)
	testing.expect_value(t, bo_ref, Recipe_Refusal.Untrusted_Realisation)
}

@(test)
test_pins_lex_roundtrip_and_adversarial_refusals :: proc(t: ^testing.T) {
	// Empty pin set round-trips byte-for-byte.
	buf1: [MAX_PINS_LEX_BYTES]u8
	buf2: [MAX_PINS_LEX_BYTES]u8
	parsed: [MAX_PROJECT_PINS]Pin_Entry

	empty_written, empty_ref := pins_lex_format(nil, buf1[:])
	testing.expect_value(t, empty_ref, Project_Refusal.None)
	testing.expect_value(t, string(buf1[:empty_written]), "{\n}\n")

	empty_count, parse_empty_ref := pins_lex_parse(buf1[:empty_written], parsed[:])
	testing.expect_value(t, parse_empty_ref, Project_Refusal.None)
	testing.expect_value(t, empty_count, 0)

	// Unsorted input pins format canonically sorted by name and round-trip byte-for-byte.
	pin_z, r_z := pin_entry_make("zeta", make_hash(20), make_hash(21), "main")
	pin_a, r_a := pin_entry_make("alpha", make_hash(22), make_hash(23))
	testing.expect_value(t, r_z, Project_Refusal.None)
	testing.expect_value(t, r_a, Project_Refusal.None)

	unsorted := [2]Pin_Entry{pin_z, pin_a}
	n1, f_ref1 := pins_lex_format(unsorted[:], buf1[:])
	testing.expect_value(t, f_ref1, Project_Refusal.None)

	p_count, p_ref := pins_lex_parse(buf1[:n1], parsed[:])
	testing.expect_value(t, p_ref, Project_Refusal.None)
	testing.expect_value(t, p_count, 2)
	testing.expect_value(t, string(parsed[0].name_bytes[:parsed[0].name_length]), "alpha")
	testing.expect_value(t, string(parsed[1].name_bytes[:parsed[1].name_length]), "zeta")
	testing.expect_value(t, string(parsed[1].upstream_ref_bytes[:parsed[1].upstream_ref_length]), "main")

	n2, f_ref2 := pins_lex_format(parsed[:p_count], buf2[:])
	testing.expect_value(t, f_ref2, Project_Refusal.None)
	testing.expect_value(t, string(buf1[:n1]), string(buf2[:n2]))

	// Adversarial pins.lex parser refusals.
	GOOD_H1 :: "blake3:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	GOOD_H2 :: "blake3:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
	UPPER_H :: "blake3:0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef"
	ZERO_H  :: "blake3:0000000000000000000000000000000000000000000000000000000000000000"

	// Duplicate pin name.
	dup_text := "{\n  a = { tree = " + GOOD_H1 + ", source = " + GOOD_H2 + " },\n  a = { tree = " + GOOD_H2 + ", source = " + GOOD_H1 + " },\n}\n"
	_, ref := pins_lex_parse(transmute([]u8)dup_text, parsed[:])
	testing.expect_value(t, ref, Project_Refusal.Duplicate_Pin)

	// Path traversal pin name.
	trav_text := "{\n  ../evil = { tree = " + GOOD_H1 + ", source = " + GOOD_H2 + " },\n}\n"
	_, ref = pins_lex_parse(transmute([]u8)trav_text, parsed[:])
	testing.expect_value(t, ref, Project_Refusal.Invalid_Pin_Name)

	// Reserved Lex keyword pin name.
	kw_text := "{\n  let = { tree = " + GOOD_H1 + ", source = " + GOOD_H2 + " },\n}\n"
	_, ref = pins_lex_parse(transmute([]u8)kw_text, parsed[:])
	testing.expect_value(t, ref, Project_Refusal.Invalid_Pin_Name)

	// Uppercase hex hash literal refused.
	upper_text := "{\n  a = { tree = " + UPPER_H + ", source = " + GOOD_H2 + " },\n}\n"
	_, ref = pins_lex_parse(transmute([]u8)upper_text, parsed[:])
	testing.expect_value(t, ref, Project_Refusal.Invalid_Hash_Literal)

	// Zero hash literal refused.
	zero_text := "{\n  a = { tree = " + ZERO_H + ", source = " + GOOD_H2 + " },\n}\n"
	_, ref = pins_lex_parse(transmute([]u8)zero_text, parsed[:])
	testing.expect_value(t, ref, Project_Refusal.Zero_Hash)

	// Missing source field refused.
	missing_text := "{\n  a = { tree = " + GOOD_H1 + " },\n}\n"
	_, ref = pins_lex_parse(transmute([]u8)missing_text, parsed[:])
	testing.expect_value(t, ref, Project_Refusal.Missing_Field)

	// Unknown field refused.
	unk_text := "{\n  a = { tree = " + GOOD_H1 + ", source = " + GOOD_H2 + ", extra = \"x\" },\n}\n"
	_, ref = pins_lex_parse(transmute([]u8)unk_text, parsed[:])
	testing.expect_value(t, ref, Project_Refusal.Unknown_Field)

	// Trailing garbage refused.
	trail_text := "{\n}\nextra"
	_, ref = pins_lex_parse(transmute([]u8)trail_text, parsed[:])
	testing.expect_value(t, ref, Project_Refusal.Trailing_Tokens)
}

@(test)
test_source_resolver_and_project_console_contracts :: proc(t: ^testing.T) {
	// Source resolver request/response validation.
	req := Source_Resolver_Request {
		action_word        = u64(Source_Resolver_Action.Fetch),
		source_module_hash = make_hash(30),
		expected_tree_hash = make_hash(31),
	}
	copy(req.input_name_bytes[:], "gui_toolkit")
	req.input_name_length = u8(len("gui_toolkit"))
	copy(req.address_bytes[:], "https://code.example.org/gui_toolkit")
	req.address_length = u16(len("https://code.example.org/gui_toolkit"))
	copy(req.allowed_host_bytes[:], "code.example.org")
	req.allowed_host_length = u16(len("code.example.org"))

	testing.expect_value(t, source_resolver_request_validate(&req), Project_Refusal.None)

	// Host mismatch (SSRF attempt) refused.
	bad_host_req := req
	copy(bad_host_req.allowed_host_bytes[:], "other.example.org")
	bad_host_req.allowed_host_length = u16(len("other.example.org"))
	testing.expect_value(t, source_resolver_request_validate(&bad_host_req), Project_Refusal.Host_Mismatch)

	// Fetch without expected_tree_hash refused.
	no_hash_fetch := req
	no_hash_fetch.expected_tree_hash = {}
	testing.expect_value(t, source_resolver_request_validate(&no_hash_fetch), Project_Refusal.Zero_Hash)

	// Fetch response with wrong tree hash refused.
	resp := Source_Resolver_Response {
		status_word        = u64(Source_Resolver_Status.Ok),
		source_module_hash = req.source_module_hash,
		resolved_tree_hash = make_hash(32), // mismatches 31
	}
	testing.expect_value(t, source_resolver_response_validate(&req, &resp), Project_Refusal.Hash_Mismatch)

	resp.resolved_tree_hash = req.expected_tree_hash
	testing.expect_value(t, source_resolver_response_validate(&req, &resp), Project_Refusal.None)

	// Project console spec validation: undeclared store and rights escalation refused.
	caller_store_ro, _ := project_console_store_make("kernel_src", .Read_Only)
	caller_store_rw, _ := project_console_store_make("scratch", .Read_Write)
	caller_stores := [2]Project_Console_Store{caller_store_ro, caller_store_rw}

	spec := Project_Console_Spec {
		project_tree_hash = make_hash(40),
		principal         = 0,
		module_count      = 1,
		store_count       = 1,
	}
	spec.modules[0], _ = project_console_module_make("odin", make_hash(41))
	spec.stores[0], _ = project_console_store_make("kernel_src", .Read_Only)

	ref, _ := project_console_spec_validate(&spec, caller_stores[:])
	testing.expect_value(t, ref, Project_Refusal.None)

	// Narrowing Read_Write -> Read_Only is allowed.
	spec.stores[0], _ = project_console_store_make("scratch", .Read_Only)
	ref, _ = project_console_spec_validate(&spec, caller_stores[:])
	testing.expect_value(t, ref, Project_Refusal.None)

	// Escalating Read_Only -> Read_Write is refused.
	spec.stores[0], _ = project_console_store_make("kernel_src", .Read_Write)
	ref, _ = project_console_spec_validate(&spec, caller_stores[:])
	testing.expect_value(t, ref, Project_Refusal.Store_Rights_Exceeded)

	// Undeclared store is refused.
	spec.stores[0], _ = project_console_store_make("secret_keys", .Read_Only)
	ref, _ = project_console_spec_validate(&spec, caller_stores[:])
	testing.expect_value(t, ref, Project_Refusal.Undeclared_Store)
}

@(test)
test_project_console_spec_edges_hash_and_grant_diff :: proc(t: ^testing.T) {
	// Nil and zero project tree hash refused.
	ref, _ := project_console_spec_validate_structure(nil)
	testing.expect_value(t, ref, Project_Refusal.Zero_Hash)

	empty_console := Project_Console_Spec{project_tree_hash = make_hash(60), principal = 1}
	ref, _ = project_console_spec_validate_structure(&empty_console)
	testing.expect_value(t, ref, Project_Refusal.Empty_Console)

	// Bounds: module_count and store_count past max refused.
	too_many_mods := empty_console
	too_many_mods.module_count = MAX_CONSOLE_MODULES + 1
	ref, _ = project_console_spec_validate_structure(&too_many_mods)
	testing.expect_value(t, ref, Project_Refusal.Too_Many_Modules)

	too_many_stores := empty_console
	too_many_stores.store_count = MAX_CONSOLE_STORES + 1
	ref, _ = project_console_spec_validate_structure(&too_many_stores)
	testing.expect_value(t, ref, Project_Refusal.Too_Many_Stores)

	// Duplicate module names refused.
	dup_mods := Project_Console_Spec{project_tree_hash = make_hash(61), principal = 1, module_count = 2}
	dup_mods.modules[0], _ = project_console_module_make("odin", make_hash(62))
	dup_mods.modules[1], _ = project_console_module_make("odin", make_hash(63))
	bad_idx: u32
	ref, bad_idx = project_console_spec_validate_structure(&dup_mods)
	testing.expect_value(t, ref, Project_Refusal.Duplicate_Module)
	testing.expect_value(t, bad_idx, u32(1))

	// Duplicate store names refused.
	dup_stores := Project_Console_Spec{project_tree_hash = make_hash(61), principal = 1, store_count = 2}
	dup_stores.stores[0], _ = project_console_store_make("kernel", .Read_Only)
	dup_stores.stores[1], _ = project_console_store_make("kernel", .Read_Write)
	ref, bad_idx = project_console_spec_validate_structure(&dup_stores)
	testing.expect_value(t, ref, Project_Refusal.Duplicate_Store)
	testing.expect_value(t, bad_idx, u32(1))

	// Unknown store rights words (0, 3, max(u64)) refused.
	for bad_word in ([?]u64{0, 3, max(u64)}) {
		bad_rights := Project_Console_Spec{project_tree_hash = make_hash(61), principal = 1, store_count = 1}
		bad_rights.stores[0], _ = project_console_store_make("kernel", .Read_Only)
		bad_rights.stores[0].rights_word = bad_word
		ref, _ = project_console_spec_validate_structure(&bad_rights)
		testing.expect_value(t, ref, Project_Refusal.Bad_Store_Rights)
	}

	// Canonical hash is order-independent over modules and stores.
	spec_a := Project_Console_Spec{project_tree_hash = make_hash(64), principal = 2, module_count = 2, store_count = 2}
	spec_a.modules[0], _ = project_console_module_make("odin", make_hash(65))
	spec_a.modules[1], _ = project_console_module_make("nasm", make_hash(66))
	spec_a.stores[0], _ = project_console_store_make("kernel", .Read_Write)
	spec_a.stores[1], _ = project_console_store_make("docs", .Read_Only)

	spec_b := Project_Console_Spec{project_tree_hash = make_hash(64), principal = 2, module_count = 2, store_count = 2}
	spec_b.modules[0] = spec_a.modules[1]
	spec_b.modules[1] = spec_a.modules[0]
	spec_b.stores[0] = spec_a.stores[1]
	spec_b.stores[1] = spec_a.stores[0]

	hash_a, href_a := project_console_spec_hash(&spec_a)
	hash_b, href_b := project_console_spec_hash(&spec_b)
	testing.expect_value(t, href_a, Project_Refusal.None)
	testing.expect_value(t, href_b, Project_Refusal.None)
	testing.expect_value(t, hash_a, hash_b)

	// Grant diff: covered session needs no consent; missing module or widened store requires consent.
	session_mods := [2]Project_Console_Module{spec_a.modules[0], spec_a.modules[1]}
	session_stores := [2]Project_Console_Store{spec_a.stores[0], spec_a.stores[1]}
	diff_cov, dref := project_console_grant_diff(&spec_a, session_stores[:], session_mods[:])
	testing.expect_value(t, dref, Project_Refusal.None)
	testing.expect(t, !diff_cov.needs_consent, "already covered grants need no consent")
	testing.expect_value(t, diff_cov.added_module_count, u32(0))
	testing.expect_value(t, diff_cov.added_store_count, u32(0))

	// Missing second module and read-only store instead of read-write triggers consent.
	partial_mods := [1]Project_Console_Module{spec_a.modules[0]}
	partial_store, _ := project_console_store_make("kernel", .Read_Only)
	partial_stores := [1]Project_Console_Store{partial_store}
	diff_add, dref_add := project_console_grant_diff(&spec_a, partial_stores[:], partial_mods[:])
	testing.expect_value(t, dref_add, Project_Refusal.None)
	testing.expect(t, diff_add.needs_consent, "extra module and widened/missing stores must require consent")
	testing.expect_value(t, diff_add.added_module_count, u32(1))
	testing.expect_value(t, diff_add.added_store_count, u32(2))

	// Declaration derivation: nil/zero refused as Unknown_Project; explicit empty console refused as Empty_Console.
	_, decl_ref := project_console_spec_from_declaration(nil, 0)
	testing.expect_value(t, decl_ref, Project_Refusal.Unknown_Project)

	empty_decl := Project_Declaration{project_tree_hash = make_hash(67), has_console_field = true}
	_, decl_ref = project_console_spec_from_declaration(&empty_decl, 0)
	testing.expect_value(t, decl_ref, Project_Refusal.Empty_Console)

	// Omitting console field falls back to output builders + source store (Read_Write).
	fallback_decl := Project_Declaration{project_tree_hash = make_hash(68), has_console_field = false, builder_module_count = 1, has_source_store = true}
	fallback_decl.builder_modules[0], _ = project_console_module_make("odin", make_hash(69))
	copy(fallback_decl.source_store_bytes[:], "kernel")
	fallback_decl.source_store_length = u8(len("kernel"))
	fb_spec, fb_ref := project_console_spec_from_declaration(&fallback_decl, 3)
	testing.expect_value(t, fb_ref, Project_Refusal.None)
	testing.expect_value(t, fb_spec.module_count, u32(1))
	testing.expect_value(t, fb_spec.store_count, u32(1))
	testing.expect_value(t, fb_spec.stores[0].rights_word, u64(Plan_Store_Rights.Read_Write))
}

// A plan of 1000 entries, past the 32 of a plan of a fixed size: 1000
// holders of Assistive (a role of several holders) in one chain of
// interposition of 999 links is no cycle; a link from the last back to the
// first is a cycle, refused at the first holder whose chain comes back; a
// name that repeats a name 400 entries before is refused at the later
// entry; and the hash of the plan does not depend on the order of its
// entries.
@(test)
plan_validate_of_a_plan_of_a_thousand_entries :: proc(t: ^testing.T) {
	COUNT :: 1000
	holder_hash :: proc(index: int) -> (hash: blake3.Hash) {
		hash[0], hash[1], hash[2] = u8(index), u8(index >> 8), 0x5a
		return
	}
	chain := test_plan(0, COUNT, COUNT)
	for index in 0 ..< COUNT {
		name := [3]u8{'h', 'a' + u8(index % 26), 'a' + u8(index / 26 % 26)}
		full := [4]u8{name[0], name[1], name[2], 'a' + u8(index / 676)}
		over: blake3.Hash
		if index > 0 {
			over = holder_hash(index - 1)
		}
		chain.entries[index], _ = plan_entry_make_role(string(full[:]), .Assistive, holder_hash(index), over)
	}
	refusal, bad_index := plan_validate(&chain)
	testing.expect_value(t, refusal, Plan_Refusal.None)
	forward, _ := plan_hash(&chain)

	// The same entries in the reverse order give the same hash.
	reversed := test_plan(0, COUNT, COUNT)
	for index in 0 ..< COUNT {
		reversed.entries[index] = chain.entries[COUNT - 1 - index]
	}
	backward, _ := plan_hash(&reversed)
	testing.expect_value(t, backward, forward)

	// The first holder interposes over the last: each holder is on a cycle,
	// and the first by index is refused.
	cycle := test_plan_copy(&chain)
	cycle.entries[0].interposed_over_hash = holder_hash(COUNT - 1)
	refusal, bad_index = plan_validate(&cycle)
	testing.expect_value(t, refusal, Plan_Refusal.Cyclic_Role_Chain)
	testing.expect_value(t, bad_index, u32(0))

	// A chain that ends in a cycle of two holders that it does not hold:
	// the first entry whose chain reaches it is refused.
	tail := test_plan_copy(&chain)
	tail.entries[500].interposed_over_hash = holder_hash(501)
	refusal, bad_index = plan_validate(&tail)
	testing.expect_value(t, refusal, Plan_Refusal.Cyclic_Role_Chain)
	testing.expect_value(t, bad_index, u32(500))

	// A name 400 entries after its first use, and a module that an earlier
	// holder of the role has: each refused at its later entry.
	repeat := test_plan_copy(&chain)
	repeat.entries[900].name_bytes = repeat.entries[500].name_bytes
	refusal, bad_index = plan_validate(&repeat)
	testing.expect_value(t, refusal, Plan_Refusal.Duplicate_Entry)
	testing.expect_value(t, bad_index, u32(900))
	same_module := test_plan_copy(&chain)
	same_module.entries[999].module_hash = holder_hash(3)
	same_module.entries[999].interposed_over_hash = {}
	refusal, bad_index = plan_validate(&same_module)
	testing.expect_value(t, refusal, Plan_Refusal.Duplicate_Entry)
	testing.expect_value(t, bad_index, u32(999))

	// An entry that fails its own check before a repeat: the check wins at
	// the lower index.
	both := test_plan_copy(&repeat)
	both.entries[700].kind_word = 0
	refusal, bad_index = plan_validate(&both)
	testing.expect_value(t, refusal, Plan_Refusal.Bad_Entry_Kind)
	testing.expect_value(t, bad_index, u32(700))

	// A difference of 1000 entries against a plan of one: 999 removed, in
	// memory for both plans, and refused with one item of memory too few.
	one := test_plan(0, 1, 1)
	one.entries[0] = chain.entries[0]
	difference := Plan_Difference{changes = make([]Plan_Diff_Item, COUNT + 1, context.temp_allocator)}
	testing.expect_value(t, plan_diff_compute(&chain, &one, &difference), Plan_Refusal.None)
	testing.expect_value(t, difference.removed_roles, u32(COUNT - 1))
	short := Plan_Difference{changes = make([]Plan_Diff_Item, COUNT, context.temp_allocator)}
	testing.expect_value(t, plan_diff_compute(&chain, &one, &short), Plan_Refusal.Buffer_Too_Small)
	testing.expect_value(t, short.change_count, u32(0))
}

// The entry Script_Fonts names the script font set of the machine: the
// plan of principal 0 takes one; the plan of another principal, a second
// entry, another name, a zero hash, a role, an interposed hash, a start
// grant and store rights are each refused at the border. A change of the
// set is an item of the difference that grants nothing.
@(test)
the_script_font_set_of_a_plan :: proc(t: ^testing.T) {
	_, made := plan_entry_make_script_fonts({})
	testing.expect(t, !made, "a zero hash makes no entry")
	entry, ok := plan_entry_make_script_fonts(make_hash(1))
	testing.expect(t, ok)
	plan := Plan_Spec{principal = 0, entry_count = 1}
	plan.entries[0] = entry
	refusal, _ := plan_validate(&plan)
	testing.expect_value(t, refusal, Plan_Refusal.None)
	named, found := plan_script_fonts(&plan)
	testing.expect(t, found && named == make_hash(1))
	Broken :: struct {
		change:  proc(plan: ^Plan_Spec),
		refusal: Plan_Refusal,
	}
	cases := [?]Broken {
		{proc(plan: ^Plan_Spec) {plan.principal = 1}, .Machine_Only},
		{proc(plan: ^Plan_Spec) {plan.entries[1] = plan.entries[0]; plan.entries[1].module_hash = make_hash(2); plan.entry_count = 2}, .Duplicate_Entry},
		{proc(plan: ^Plan_Spec) {plan.entries[0].name_length = u8(copy(plan.entries[0].name_bytes[:], "fonts"))}, .Invalid_Name},
		{proc(plan: ^Plan_Spec) {plan.entries[0].module_hash = {}}, .Zero_Module_Hash},
		{proc(plan: ^Plan_Spec) {plan.entries[0].role_word = 1}, .Bad_Role},
		{proc(plan: ^Plan_Spec) {plan.entries[0].interposed_over_hash = make_hash(3)}, .Bad_Entry_Kind},
		{proc(plan: ^Plan_Spec) {plan.entries[0].start_grants_mask = 1}, .Bad_Start_Grant},
		{proc(plan: ^Plan_Spec) {plan.entries[0].store_rights_word = 1}, .Bad_Store_Rights},
		{proc(plan: ^Plan_Spec) {plan.entries[0].kind_word = u64(max(Plan_Entry_Kind)) + 1}, .Bad_Entry_Kind},
	}
	for broken, index in cases {
		changed := plan
		broken.change(&changed)
		found_refusal, _ := plan_validate(&changed)
		testing.expectf(t, found_refusal == broken.refusal, "case %d: %v, expected %v", index, found_refusal, broken.refusal)
	}
	other := plan
	other.entries[0].module_hash = make_hash(2)
	difference: Plan_Difference
	testing.expect_value(t, plan_diff_compute(&plan, &other, &difference), Plan_Refusal.None)
	testing.expect(t, difference.has_changes && difference.change_count == 1 && !difference.any_grant_added)
	item := difference.changes[0]
	testing.expect(t, item.change == .Changed && item.entry_kind == .Script_Fonts && item.old_module_hash == make_hash(1) && item.new_module_hash == make_hash(2))
	testing.expect_value(t, difference.added_grants_count + difference.removed_grants_count, u32(0))
}
