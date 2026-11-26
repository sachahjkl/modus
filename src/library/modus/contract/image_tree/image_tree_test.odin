#+build !freestanding
#+build !modus
package image_tree

import "core:testing"
import "modus:contract/blake3"
import info "modus:contract/boot_info"
import "modus:contract/store"

@(private = "file")
sample_hash :: proc(seed: u8) -> blake3.Hash {
	data := [4]u8{seed, seed ~ 0x5A, seed + 13, 0xC3}
	return blake3.hash(data[:])
}

@(private = "file")
make_image_entry :: proc(name: string, size: u64, hash: blake3.Hash) -> (entry: info.Image_Entry) {
	copy(entry.name[:], name)
	entry.size = size
	entry.hash = hash
	return entry
}

// Enum borders refuse unknown transport words and round-trip every member.
@(test)
enum_borders_refuse_unknown_words :: proc(t: ^testing.T) {
	for word in ([?]u64{0, 3, 255, max(u64)}) {
		_, ok := entry_kind_of_word(word)
		testing.expect(t, !ok)
	}
	for member in Entry_Kind {
		got, ok := entry_kind_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, got, member)
	}
	for word in ([?]u64{u64(max(Problem)) + 1, 255, max(u64)}) {
		_, ok := problem_of_word(word)
		testing.expect(t, !ok)
	}
	for member in Problem {
		got, ok := problem_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, got, member)
	}
	for word in ([?]u64{u64(max(Lookup_Problem)) + 1, 255, max(u64)}) {
		_, ok := lookup_problem_of_word(word)
		testing.expect(t, !ok)
	}
	for member in Lookup_Problem {
		got, ok := lookup_problem_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, got, member)
	}
}

// Corrupt magic, wrong version, truncated buffers, trailing bytes, and bad
// header counts are refused before any entry is trusted.
@(test)
corrupt_headers_truncation_and_trailing_bytes_refused :: proc(t: ^testing.T) {
	nodes_scratch: [4]Draft_Node
	entries_scratch: [4]Draft_Entry
	buf: [512]u8
	specs := [?]Object_Spec{{path = "a", image_entry_index = 0, size = 10, hash = sample_hash(1)}}
	written, enc_prob := encode_from_objects(specs[:], nodes_scratch[:], entries_scratch[:], buf[:])
	testing.expect_value(t, enc_prob, Problem.None)

	// Truncated inputs: 0, 1, HEADER_SIZE - 1, HEADER_SIZE, written - 1.
	for length in ([?]int{0, 1, HEADER_SIZE - 1, HEADER_SIZE, written - 1}) {
		_, prob := validate(buf[:length])
		testing.expect_value(t, prob, Problem.Truncated)
	}

	// Trailing bytes: 1 byte and 4 bytes past valid manifest.
	_, trail1 := validate(buf[:written + 1])
	testing.expect_value(t, trail1, Problem.Trailing_Bytes)
	_, trail4 := validate(buf[:written + 4])
	testing.expect_value(t, trail4, Problem.Trailing_Bytes)

	// Corrupt magic.
	bad_magic := buf
	bad_magic[7] = '2'
	_, magic_prob := validate(bad_magic[:written])
	testing.expect_value(t, magic_prob, Problem.Bad_Magic)

	// Corrupt version: 0, 2, max(u32).
	for bad_ver in ([?]u32{0, VERSION + 1, max(u32)}) {
		bad_buf := buf
		(^Header)(raw_data(bad_buf[:])).version = bad_ver
		_, ver_prob := validate(bad_buf[:written])
		testing.expect_value(t, ver_prob, Problem.Bad_Version)
	}

	// Bad header counts: node_count 0, NODE_CAPACITY + 1, ENTRY_CAPACITY + 1, NAMES_BYTES_LIMIT + 1.
	bad_zero_nodes := buf
	(^Header)(raw_data(bad_zero_nodes[:])).node_count = 0
	_, zn_prob := validate(bad_zero_nodes[:written])
	testing.expect_value(t, zn_prob, Problem.Bad_Counts)

	bad_many_nodes := buf
	(^Header)(raw_data(bad_many_nodes[:])).node_count = NODE_CAPACITY + 1
	_, mn_prob := validate(bad_many_nodes[:written])
	testing.expect_value(t, mn_prob, Problem.Bad_Counts)

	bad_many_entries := buf
	(^Header)(raw_data(bad_many_entries[:])).entry_count = ENTRY_CAPACITY + 1
	_, me_prob := validate(bad_many_entries[:written])
	testing.expect_value(t, me_prob, Problem.Bad_Counts)

	bad_many_names := buf
	(^Header)(raw_data(bad_many_names[:])).names_bytes = NAMES_BYTES_LIMIT + 1
	_, mnm_prob := validate(bad_many_names[:written])
	testing.expect_value(t, mnm_prob, Problem.Bad_Counts)

	// Output buffer too small leaves caller buffer completely untouched.
	small: [HEADER_SIZE]u8
	for &b in small {
		b = 0xAA
	}
	w_small, p_small := encode_from_objects(specs[:], nodes_scratch[:], entries_scratch[:], small[:])
	testing.expect_value(t, w_small, 0)
	testing.expect_value(t, p_small, Problem.Truncated)
	testing.expect_value(t, small[0], u8(0xAA))
}

// Unsorted entries, duplicate names, unknown entry kinds, cycles, orphan nodes,
// shared DAG nodes, non-zero reserved fields, and out-of-range name offsets are
// refused at both encode and validate borders.
@(test)
structural_corruption_cycles_and_ordering_refused :: proc(t: ^testing.T) {
	out: [1024]u8

	// Unsorted entries in encode_nodes.
	nodes_one := [1]Build_Node{{first_entry = 0, entry_count = 2, parent_node = ROOT_PARENT}}
	unsorted := [2]Build_Entry {
		{kind = .Object, name = "beta", target_index = 0, size = 1, hash = sample_hash(1)},
		{kind = .Object, name = "alpha", target_index = 1, size = 1, hash = sample_hash(2)},
	}
	w_uns, p_uns := encode_nodes(nodes_one[:], unsorted[:], out[:])
	testing.expect_value(t, w_uns, 0)
	testing.expect_value(t, p_uns, Problem.Not_Sorted)

	// Duplicate names in encode_nodes.
	dup := [2]Build_Entry {
		{kind = .Object, name = "same", target_index = 0, size = 1, hash = sample_hash(1)},
		{kind = .Object, name = "same", target_index = 1, size = 2, hash = sample_hash(2)},
	}
	w_dup, p_dup := encode_nodes(nodes_one[:], dup[:], out[:])
	testing.expect_value(t, w_dup, 0)
	testing.expect_value(t, p_dup, Problem.Duplicate_Name)

	// Self-cycle (root Tree entry pointing to node 0).
	self_cycle_entries := [1]Build_Entry{{kind = .Tree, name = "loop", target_index = 0}}
	nodes_self := [1]Build_Node{{first_entry = 0, entry_count = 1, parent_node = ROOT_PARENT}}
	_, p_self := encode_nodes(nodes_self[:], self_cycle_entries[:], out[:])
	testing.expect_value(t, p_self, Problem.Cycle_Or_Order)

	// 2-node cycle (node 0 -> node 1 -> node 0).
	cycle_nodes := [2]Build_Node {
		{first_entry = 0, entry_count = 1, parent_node = ROOT_PARENT},
		{first_entry = 1, entry_count = 1, parent_node = 0},
	}
	cycle_entries := [2]Build_Entry {
		{kind = .Tree, name = "sub", target_index = 1},
		{kind = .Tree, name = "back", target_index = 0},
	}
	_, p_cycle := encode_nodes(cycle_nodes[:], cycle_entries[:], out[:])
	testing.expect_value(t, p_cycle, Problem.Cycle_Or_Order)

	// Shared DAG node (two entries pointing to child node 1).
	dag_nodes := [2]Build_Node {
		{first_entry = 0, entry_count = 2, parent_node = ROOT_PARENT},
		{first_entry = 2, entry_count = 0, parent_node = 0},
	}
	dag_entries := [2]Build_Entry {
		{kind = .Tree, name = "a", target_index = 1},
		{kind = .Tree, name = "b", target_index = 1},
	}
	_, p_dag := encode_nodes(dag_nodes[:], dag_entries[:], out[:])
	testing.expect_value(t, p_dag, Problem.Shared_Node)

	// Orphan node (node 1 not referenced by node 0).
	orphan_nodes := [2]Build_Node {
		{first_entry = 0, entry_count = 0, parent_node = ROOT_PARENT},
		{first_entry = 0, entry_count = 0, parent_node = 0},
	}
	_, p_orphan := encode_nodes(orphan_nodes[:], nil, out[:])
	testing.expect_value(t, p_orphan, Problem.Orphan_Node)

	// Tree entry with non-zero size or non-zero hash is refused.
	bad_tree_entries := [1]Build_Entry{{kind = .Tree, name = "dir", target_index = 1, size = 4}}
	valid_two_nodes := [2]Build_Node {
		{first_entry = 0, entry_count = 1, parent_node = ROOT_PARENT},
		{first_entry = 1, entry_count = 0, parent_node = 0},
	}
	_, p_bad_tree := encode_nodes(valid_two_nodes[:], bad_tree_entries[:], out[:])
	testing.expect_value(t, p_bad_tree, Problem.Bad_Entry)

	// Build a valid 2-entry tree, then mutate wire bytes to test validate directly.
	sorted_entries := [2]Build_Entry {
		{kind = .Object, name = "alpha", target_index = 0, size = 1, hash = sample_hash(1)},
		{kind = .Object, name = "beta", target_index = 1, size = 2, hash = sample_hash(2)},
	}
	valid_len, valid_prob := encode_nodes(nodes_one[:], sorted_entries[:], out[:])
	testing.expect_value(t, valid_prob, Problem.None)

	// Wire unknown entry kind (0 and 3).
	for bad_kind in ([?]u8{0, 3, 255}) {
		mut := out
		mut[HEADER_SIZE + NODE_RECORD_SIZE] = bad_kind
		_, kp := validate(mut[:valid_len])
		testing.expect_value(t, kp, Problem.Bad_Entry_Kind)
	}

	// Wire non-zero reserved field on Node_Record.
	mut_node_res := out
	(^Node_Record)(raw_data(mut_node_res[HEADER_SIZE:])).reserved = 1
	_, nrp := validate(mut_node_res[:valid_len])
	testing.expect_value(t, nrp, Problem.Bad_Node)

	// Wire non-zero reserved field on Entry_Record.
	mut_entry_res := out
	(^Entry_Record)(raw_data(mut_entry_res[HEADER_SIZE + NODE_RECORD_SIZE:])).reserved_u32 = 1
	_, erp := validate(mut_entry_res[:valid_len])
	testing.expect_value(t, erp, Problem.Bad_Entry)

	// Wire out-of-range name_offset.
	mut_off := out
	(^Entry_Record)(raw_data(mut_off[HEADER_SIZE + NODE_RECORD_SIZE:])).name_offset = 1
	_, ofp := validate(mut_off[:valid_len])
	testing.expect_value(t, ofp, Problem.Bad_Name_Offset)

	// Wire unsorted mutation: change 'a' of "alpha" to 'z'.
	mut_unsort := out
	pool_start := HEADER_SIZE + NODE_RECORD_SIZE + 2 * ENTRY_RECORD_SIZE
	mut_unsort[pool_start] = 'z'
	_, usp := validate(mut_unsort[:valid_len])
	testing.expect_value(t, usp, Problem.Not_Sorted)

	// Wire duplicate mutation: swap "alpha" to "beta" length=4? Use two same-length names:
	same_len := [2]Build_Entry {
		{kind = .Object, name = "aa", target_index = 0, size = 1, hash = sample_hash(1)},
		{kind = .Object, name = "ab", target_index = 1, size = 2, hash = sample_hash(2)},
	}
	sl_len, sl_prob := encode_nodes(nodes_one[:], same_len[:], out[:])
	testing.expect_value(t, sl_prob, Problem.None)
	mut_dup := out
	mut_dup[HEADER_SIZE + NODE_RECORD_SIZE + 2 * ENTRY_RECORD_SIZE + 3] = 'a'
	_, dup_wp := validate(mut_dup[:sl_len])
	testing.expect_value(t, dup_wp, Problem.Duplicate_Name)
}

// Reserved root-only boot/trust records are refused both by name in the tree
// and by target resource index in validate_against_resources (anti-aliasing!).
@(test)
reserved_boot_records_refused_by_name_and_by_resource_index :: proc(t: ^testing.T) {
	nodes_scratch: [8]Draft_Node
	entries_scratch: [8]Draft_Entry
	out: [1024]u8

	for reserved in RESERVED_BOOT_RECORDS {
		specs := [1]Object_Spec{{path = reserved, image_entry_index = 0, size = 4, hash = sample_hash(1)}}
		w, prob := encode_from_objects(specs[:], nodes_scratch[:], entries_scratch[:], out[:])
		testing.expect_value(t, w, 0)
		testing.expectf(t, prob == .Reserved_Name, "reserved name %q must be refused", reserved)
	}

	// Aliasing attack: benign path "fonts/harmless" pointing to a boot-image
	// resource whose actual Image_Entry name is "system_description".
	h_desc := sample_hash(77)
	alias_specs := [1]Object_Spec{{path = "fonts/harmless", image_entry_index = 0, size = 64, hash = h_desc}}
	written, enc_prob := encode_from_objects(alias_specs[:], nodes_scratch[:], entries_scratch[:], out[:])
	testing.expect_value(t, enc_prob, Problem.None)

	resources := [1]info.Image_Entry{make_image_entry("system_description", 64, h_desc)}
	_, res_prob := validate_against_resources(out[:written], resources[:])
	testing.expect_value(t, res_prob, Problem.Reserved_Name)

	// Out-of-range resource index.
	_, oor_prob := validate_against_resources(out[:written], nil)
	testing.expect_value(t, oor_prob, Problem.Resource_Out_Of_Range)

	// Mismatched resource size or hash.
	wrong_size := [1]info.Image_Entry{make_image_entry("harmless", 65, h_desc)}
	_, ws_prob := validate_against_resources(out[:written], wrong_size[:])
	testing.expect_value(t, ws_prob, Problem.Resource_Mismatch)

	wrong_hash := [1]info.Image_Entry{make_image_entry("harmless", 64, sample_hash(78))}
	_, wh_prob := validate_against_resources(out[:written], wrong_hash[:])
	testing.expect_value(t, wh_prob, Problem.Resource_Mismatch)

	// Matching non-reserved resource succeeds.
	good_res := [1]info.Image_Entry{make_image_entry("harmless", 64, h_desc)}
	_, good_prob := validate_against_resources(out[:written], good_res[:])
	testing.expect_value(t, good_prob, Problem.None)
}

// Empty tree, 0-byte objects, invalid paths, path conflicts, canonical
// order-independence, subtree grants, ambiguity across 2 and 3 trees, and
// hash-pin match vs mismatch.
@(test)
empty_tree_zero_byte_objects_subtrees_ambiguity_and_hash_pins :: proc(t: ^testing.T) {
	nodes_scratch: [32]Draft_Node
	entries_scratch: [64]Draft_Entry
	out_a: [4096]u8
	out_b: [4096]u8

	// 1. Empty tree (0 entries).
	empty_len, empty_prob := encode_from_objects(nil, nodes_scratch[:], entries_scratch[:], out_a[:])
	testing.expect_value(t, empty_prob, Problem.None)
	testing.expect_value(t, empty_len, HEADER_SIZE + NODE_RECORD_SIZE)
	empty_header, empty_val := validate(out_a[:empty_len])
	testing.expect_value(t, empty_val, Problem.None)
	testing.expect_value(t, empty_header.node_count, u32(1))
	testing.expect_value(t, empty_header.entry_count, u32(0))

	root_only := [1]Subtree_Grant{{tree_name = "image", root_node = ROOT_NODE}}
	_, m0, lp0, _ := lookup_in_grants(out_a[:empty_len], root_only[:], "anything", false, {}, nil)
	testing.expect_value(t, lp0, Lookup_Problem.Not_Found)
	testing.expect_value(t, m0, 0)

	// 2. Invalid paths and path conflicts refused by encode_from_objects.
	for bad_path in ([?]string{"", "/a", "a/", "a//b", "a/../b", "a/./b"}) {
		bad_specs := [1]Object_Spec{{path = bad_path, image_entry_index = 0, size = 1, hash = sample_hash(1)}}
		_, bp := encode_from_objects(bad_specs[:], nodes_scratch[:], entries_scratch[:], out_a[:])
		testing.expect_value(t, bp, Problem.Invalid_Path)
	}
	conflict_a := [2]Object_Spec {
		{path = "fonts", image_entry_index = 0, size = 1, hash = sample_hash(1)},
		{path = "fonts/b612", image_entry_index = 1, size = 2, hash = sample_hash(2)},
	}
	_, ca_prob := encode_from_objects(conflict_a[:], nodes_scratch[:], entries_scratch[:], out_a[:])
	testing.expect_value(t, ca_prob, Problem.Path_Conflict)

	conflict_b := [2]Object_Spec {
		{path = "fonts/b612", image_entry_index = 1, size = 2, hash = sample_hash(2)},
		{path = "fonts", image_entry_index = 0, size = 1, hash = sample_hash(1)},
	}
	_, cb_prob := encode_from_objects(conflict_b[:], nodes_scratch[:], entries_scratch[:], out_a[:])
	testing.expect_value(t, cb_prob, Problem.Path_Conflict)

	// 3. Canonical encoding: two different input orders yield byte-for-byte identical output.
	h_zero := blake3.hash(nil)
	h_posy := sample_hash(10)
	h_sys := sample_hash(11)
	h_hebrew := sample_hash(12)
	h_shared_a := sample_hash(20)
	h_shared_b := sample_hash(21)
	h_shared_c := sample_hash(22)

	specs_order_1 := [?]Object_Spec {
		{path = "pointer_themes/posy", image_entry_index = 0, size = 4096, hash = h_posy},
		{path = "pointer_themes/system", image_entry_index = 1, size = 2048, hash = h_sys},
		{path = "fonts/noto_sans_hebrew", image_entry_index = 2, size = 35508, hash = h_hebrew},
		{path = "empty_marker", image_entry_index = 3, size = 0, hash = h_zero},
		{path = "tree_a/common", image_entry_index = 4, size = 16, hash = h_shared_a},
		{path = "tree_b/common", image_entry_index = 5, size = 32, hash = h_shared_b},
		{path = "tree_c/common", image_entry_index = 6, size = 64, hash = h_shared_c},
	}
	specs_order_2 := [?]Object_Spec {
		specs_order_1[6],
		specs_order_1[3],
		specs_order_1[1],
		specs_order_1[5],
		specs_order_1[0],
		specs_order_1[4],
		specs_order_1[2],
	}

	len_a, pa := encode_from_objects(specs_order_1[:], nodes_scratch[:], entries_scratch[:], out_a[:])
	len_b, pb := encode_from_objects(specs_order_2[:], nodes_scratch[:], entries_scratch[:], out_b[:])
	testing.expect_value(t, pa, Problem.None)
	testing.expect_value(t, pb, Problem.None)
	testing.expect_value(t, len_a, len_b)
	for i in 0 ..< len_a {
		testing.expect_value(t, out_a[i], out_b[i])
	}
	manifest := out_a[:len_a]

	// 4. 0-byte object resolves cleanly from root.
	zero_res, zero_matches, zero_lp, _ := lookup_in_grants(manifest, root_only[:], "empty_marker", true, h_zero, nil)
	testing.expect_value(t, zero_lp, Lookup_Problem.None)
	testing.expect_value(t, zero_matches, 1)
	testing.expect_value(t, zero_res.size, u64(0))
	testing.expect_value(t, zero_res.image_entry_index, u32(3))
	testing.expect_value(t, zero_res.hash, h_zero)

	// 5. Subtree grant isolation: granting only "pointer_themes" resolves both
	//    relative "posy" and qualified "pointer_themes/posy", returns Is_Subtree
	//    for "pointer_themes", and refuses "fonts/noto_sans_hebrew" and "empty_marker".
	pt_node, pt_lp, _ := subtree_resolve(manifest, "pointer_themes")
	testing.expect_value(t, pt_lp, Lookup_Problem.None)
	pt_grants := [1]Subtree_Grant{{tree_name = "pointer_themes", root_node = pt_node}}

	posy_res, posy_m, posy_lp, _ := lookup_in_grants(manifest, pt_grants[:], "posy", true, h_posy, nil)
	testing.expect_value(t, posy_lp, Lookup_Problem.None)
	testing.expect_value(t, posy_m, 1)
	testing.expect_value(t, posy_res.image_entry_index, u32(0))
	testing.expect_value(t, posy_res.size, u64(4096))

	qual_res, qual_m, qual_lp, _ := lookup_in_grants(manifest, pt_grants[:], "pointer_themes/posy", true, h_posy, nil)
	testing.expect_value(t, qual_lp, Lookup_Problem.None)
	testing.expect_value(t, qual_m, 1)
	testing.expect_value(t, qual_res.image_entry_index, u32(0))
	testing.expect_value(t, qual_res.size, u64(4096))

	_, _, pt_self_lp, _ := lookup_in_grants(manifest, pt_grants[:], "pointer_themes", false, {}, nil)
	testing.expect_value(t, pt_self_lp, Lookup_Problem.Is_Subtree)

	_, _, escaped_lp, _ := lookup_in_grants(manifest, pt_grants[:], "fonts/noto_sans_hebrew", false, {}, nil)
	testing.expect_value(t, escaped_lp, Lookup_Problem.Not_Found)

	// Asking for a subtree name as an object returns Is_Subtree.
	_, _, subtree_lp, _ := lookup_in_grants(manifest, root_only[:], "pointer_themes", false, {}, nil)
	testing.expect_value(t, subtree_lp, Lookup_Problem.Is_Subtree)

	// Invalid path in lookup returns Bad_Path with exact Object_Path_Problem.
	_, _, bad_lp, bad_pp := lookup_in_grants(manifest, pt_grants[:], "../empty_marker", false, {}, nil)
	testing.expect_value(t, bad_lp, Lookup_Problem.Bad_Path)
	testing.expect_value(t, bad_pp, store.Object_Path_Problem.Dot_Segment)

	// Out-of-range grant root_node returns Bad_Grant.
	bad_grants := [1]Subtree_Grant{{tree_name = "bad", root_node = 999}}
	_, _, bg_lp, _ := lookup_in_grants(manifest, bad_grants[:], "posy", false, {}, nil)
	testing.expect_value(t, bg_lp, Lookup_Problem.Bad_Grant)

	// 6. Hash pin mismatch returns Hash_Mismatch (NOT Data_Damaged).
	mismatch_res, mismatch_m, mismatch_lp, _ := lookup_in_grants(manifest, pt_grants[:], "posy", true, h_sys, nil)
	testing.expect_value(t, mismatch_lp, Lookup_Problem.Hash_Mismatch)
	testing.expect_value(t, mismatch_m, 1)
	testing.expect_value(t, mismatch_res.hash, h_posy)

	// 7. Ambiguity across 2 trees and across 3 trees, including bounded buffer
	//    smaller than total match_count.
	node_a, _, _ := subtree_resolve(manifest, "tree_a")
	node_b, _, _ := subtree_resolve(manifest, "tree_b")
	node_c, _, _ := subtree_resolve(manifest, "tree_c")

	two_grants := [2]Subtree_Grant {
		{tree_name = "tree_a", root_node = node_a},
		{tree_name = "tree_b", root_node = node_b},
	}
	amb_buf_4: [4]Ambiguity_Match
	_, m2, lp2, _ := lookup_in_grants(manifest, two_grants[:], "common", false, {}, amb_buf_4[:])
	testing.expect_value(t, lp2, Lookup_Problem.Ambiguous)
	testing.expect_value(t, m2, 2)
	testing.expect_value(t, amb_buf_4[0].tree_name, "tree_a")
	testing.expect_value(t, amb_buf_4[0].hash, h_shared_a)
	testing.expect_value(t, amb_buf_4[1].tree_name, "tree_b")
	testing.expect_value(t, amb_buf_4[1].hash, h_shared_b)

	// Even when an expected hash matches only one tree, ambiguity is still refused!
	_, m2_pin, lp2_pin, _ := lookup_in_grants(manifest, two_grants[:], "common", true, h_shared_a, amb_buf_4[:])
	testing.expect_value(t, lp2_pin, Lookup_Problem.Ambiguous)
	testing.expect_value(t, m2_pin, 2)

	// Disambiguating with the grant's tree_name prefix selects that single tree.
	disamb_res, disamb_m, disamb_lp, _ := lookup_in_grants(manifest, two_grants[:], "tree_b/common", true, h_shared_b, amb_buf_4[:])
	testing.expect_value(t, disamb_lp, Lookup_Problem.None)
	testing.expect_value(t, disamb_m, 1)
	testing.expect_value(t, disamb_res.image_entry_index, u32(5))
	testing.expect_value(t, disamb_res.size, u64(32))

	// 3 ambiguous trees into a 2-slot buffer: writes first 2 and reports total 3.
	three_grants := [3]Subtree_Grant {
		{tree_name = "tree_a", root_node = node_a},
		{tree_name = "tree_b", root_node = node_b},
		{tree_name = "tree_c", root_node = node_c},
	}
	amb_buf_2: [2]Ambiguity_Match
	_, m3, lp3, _ := lookup_in_grants(manifest, three_grants[:], "common", false, {}, amb_buf_2[:])
	testing.expect_value(t, lp3, Lookup_Problem.Ambiguous)
	testing.expect_value(t, m3, 3)
	testing.expect_value(t, amb_buf_2[0].tree_name, "tree_a")
	testing.expect_value(t, amb_buf_2[1].tree_name, "tree_b")

	// 8. Node listing returns sorted entries cleanly.
	pt_count, pt_ok := node_entry_count(manifest, pt_node)
	testing.expect(t, pt_ok)
	testing.expect_value(t, pt_count, 2)
	e0, e0_ok := node_entry_at(manifest, pt_node, 0)
	e1, e1_ok := node_entry_at(manifest, pt_node, 1)
	testing.expect(t, e0_ok && e1_ok)
	testing.expect_value(t, e0.name, "posy")
	testing.expect_value(t, e1.name, "system")
	_, past_ok := node_entry_at(manifest, pt_node, 2)
	testing.expect(t, !past_ok)
}
