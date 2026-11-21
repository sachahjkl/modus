#+build !freestanding
package disk_processes_core

import "core:testing"
import "modus:contract/blake3"
import rd "modus:contract/root_delegation"
import "modus:contract/start_grant"

@(private = "file")
make_entry :: proc(name: string, hash: blake3.Hash, size: u64, imports: []blake3.Hash = nil) -> Catalog_Entry {
	entry: Catalog_Entry
	entry.name_length = u8(copy(entry.name[:], name))
	entry.module_hash = hash
	entry.byte_size = size
	entry.direct_import_count = u32(len(imports))
	for h, i in imports {
		entry.direct_imports[i] = h
	}
	return entry
}

@(private = "file")
tag_hash :: proc(tag: u8) -> blake3.Hash {
	h: blake3.Hash
	h[0] = tag
	h[1] = tag ~ 0x5A
	return h
}

@(test)
catalog_and_dfs_refuse_cycles_missing_imports_and_excess_depth :: proc(t: ^testing.T) {
	state: Disk_Processes_State
	state_init(&state)

	// Invalid catalog registrations are refused.
	testing.expect_value(t, catalog_register(&state, {}), Catalog_Refusal.Invalid_Name)
	bad_self := make_entry("self.mod", tag_hash(1), 64, {tag_hash(1)})
	testing.expect_value(t, catalog_register(&state, bad_self), Catalog_Refusal.Self_Import)
	bad_size := make_entry("huge.mod", tag_hash(2), rd.MODULE_BYTES_LIMIT + 1)
	testing.expect_value(t, catalog_register(&state, bad_size), Catalog_Refusal.Module_Too_Large)

	// Missing import refusal.
	missing_dep := tag_hash(99)
	app := make_entry("app.mod", tag_hash(10), 128, {missing_dep})
	testing.expect_value(t, catalog_register(&state, app), Catalog_Refusal.None)
	missing_res := validate_imports(&state, tag_hash(10))
	testing.expect_value(t, missing_res.refusal, Import_Validation_Refusal.Missing_Import)
	testing.expect_value(t, missing_res.offending_hash, missing_dep)

	// 3-node cycle refusal: A -> B -> C -> A.
	state_init(&state)
	ha, hb, hc := tag_hash(1), tag_hash(2), tag_hash(3)
	testing.expect_value(t, catalog_register(&state, make_entry("a", ha, 64, {hb})), Catalog_Refusal.None)
	testing.expect_value(t, catalog_register(&state, make_entry("b", hb, 64, {hc})), Catalog_Refusal.None)
	testing.expect_value(t, catalog_register(&state, make_entry("c", hc, 64, {ha})), Catalog_Refusal.None)
	cycle_res := validate_imports(&state, ha)
	testing.expect_value(t, cycle_res.refusal, Import_Validation_Refusal.Import_Cycle)
	testing.expect_value(t, cycle_res.offending_hash, ha)

	// Diamond DAG succeeds and deduplicates the shared leaf: root -> {left, right} -> leaf.
	state_init(&state)
	hroot, hleft, hright, hleaf := tag_hash(10), tag_hash(11), tag_hash(12), tag_hash(13)
	testing.expect_value(t, catalog_register(&state, make_entry("leaf", hleaf, 64)), Catalog_Refusal.None)
	testing.expect_value(t, catalog_register(&state, make_entry("left", hleft, 64, {hleaf})), Catalog_Refusal.None)
	testing.expect_value(t, catalog_register(&state, make_entry("right", hright, 64, {hleaf})), Catalog_Refusal.None)
	testing.expect_value(t, catalog_register(&state, make_entry("root", hroot, 64, {hleft, hright})), Catalog_Refusal.None)
	dag_res := validate_imports(&state, hroot)
	testing.expect_value(t, dag_res.refusal, Import_Validation_Refusal.None)
	testing.expect_value(t, dag_res.resolved_count, u32(3))
	testing.expect_value(t, dag_res.max_depth_seen, u32(2))

	// Depth exactly at MAX_IMPORT_DEPTH succeeds; MAX_IMPORT_DEPTH + 1 is refused.
	state_init(&state)
	// Chain of MAX_IMPORT_DEPTH + 1 nodes: node 0 (depth 0) -> ... -> node MAX_IMPORT_DEPTH (depth MAX_IMPORT_DEPTH).
	for i := MAX_IMPORT_DEPTH; i >= 0; i -= 1 {
		h := tag_hash(u8(50 + i))
		if i == MAX_IMPORT_DEPTH {
			testing.expect_value(t, catalog_register(&state, make_entry("leaf", h, 64)), Catalog_Refusal.None)
		} else {
			child := tag_hash(u8(50 + i + 1))
			testing.expect_value(t, catalog_register(&state, make_entry("node", h, 64, {child})), Catalog_Refusal.None)
		}
	}
	at_bound := validate_imports(&state, tag_hash(50))
	testing.expect_value(t, at_bound.refusal, Import_Validation_Refusal.None)
	testing.expect_value(t, at_bound.max_depth_seen, u32(MAX_IMPORT_DEPTH))

	// Add one more parent above node 0 -> depth MAX_IMPORT_DEPTH + 1.
	extra := tag_hash(49)
	testing.expect_value(t, catalog_register(&state, make_entry("extra", extra, 64, {tag_hash(50)})), Catalog_Refusal.None)
	past_bound := validate_imports(&state, extra)
	testing.expect_value(t, past_bound.refusal, Import_Validation_Refusal.Import_Depth_Exceeded)
}

@(test)
debug_lookup_and_prepare_start_enforce_hashes_and_grant_borders :: proc(t: ^testing.T) {
	state: Disk_Processes_State
	state_init(&state)

	lib_bytes := [?]u8{1, 2, 3, 4}
	app_bytes := [?]u8{'A', 'P', 'P', 9, 8, 7, 6}
	lib_hash := blake3.hash(lib_bytes[:])
	app_hash := blake3.hash(app_bytes[:])

	lib_entry := make_entry("lib", lib_hash, u64(len(lib_bytes)))
	app_entry := make_entry("app", app_hash, u64(len(app_bytes)), {lib_hash})
	app_entry.has_debug_object = true
	app_entry.debug_object_hash = tag_hash(0xEE)
	app_entry.debug_object_size = 4096

	testing.expect_value(t, catalog_register(&state, lib_entry), Catalog_Refusal.None)
	testing.expect_value(t, catalog_register(&state, app_entry), Catalog_Refusal.None)

	// Debug object lookup: found for app, absent for lib and unknown hash.
	dbg, dbg_ok := lookup_debug_object(&state, app_hash)
	testing.expect(t, dbg_ok)
	testing.expect_value(t, dbg.debug_object_hash, tag_hash(0xEE))
	testing.expect_value(t, dbg.debug_object_size, u64(4096))

	_, no_dbg := lookup_debug_object(&state, lib_hash)
	testing.expect(t, !no_dbg)
	_, unknown_dbg := lookup_debug_object(&state, {})
	testing.expect(t, !unknown_dbg)

	// Prepare start refuses tampered bytes.
	input := Prepare_Start_Input {
		principal   = 2,
		module_hash = app_hash,
		budget_pages = 128,
	}
	input.nickname_length = u8(copy(input.nickname[:], "my-app"))
	tampered := app_bytes
	tampered[0] ~= 0xFF
	_, tam_ref, _, _ := prepare_start_from_bytes(&state, &input, tampered[:])
	testing.expect_value(t, tam_ref, Prepare_Start_Refusal.Hash_Mismatch)

	// Prepare start refuses System_Part grant.
	bad_grant_input := input
	bad_grant_input.requested_grant_count = 1
	bad_grant_input.requested_grant_words[0] = u64(start_grant.Grant.System_Part)
	_, bg_ref, _, border_ref := prepare_start_from_bytes(&state, &bad_grant_input, app_bytes[:])
	testing.expect_value(t, bg_ref, Prepare_Start_Refusal.Border_Validation)
	testing.expect_value(t, border_ref, rd.Start_From_Bytes_Refusal.Forbidden_System_Part_Grant)

	// Clean prepare start with Store grant succeeds and carries resolved imports.
	good_input := input
	good_input.requested_grant_count = 1
	good_input.requested_grant_words[0] = u64(start_grant.Grant.Store)
	req, prep_ref, imp_ref, b_ref := prepare_start_from_bytes(&state, &good_input, app_bytes[:])
	testing.expect_value(t, prep_ref, Prepare_Start_Refusal.None)
	testing.expect_value(t, imp_ref, Import_Validation_Refusal.None)
	testing.expect_value(t, b_ref, rd.Start_From_Bytes_Refusal.None)
	testing.expect_value(t, req.expected_module_hash, app_hash)
	testing.expect_value(t, req.import_count, u32(1))
	testing.expect_value(t, req.import_hashes[0], lib_hash)
}
