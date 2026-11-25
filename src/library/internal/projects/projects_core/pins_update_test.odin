#+build !freestanding
package projects_core

import "core:slice"
import "core:strings"
import "core:testing"
import "modus:contract/blake3"
import pr "modus:contract/plans_recipes"

@(private = "file")
pu_hash :: proc(tag: string) -> blake3.Hash {
	return blake3.hash(transmute([]u8)tag)
}

@(private = "file")
pu_make_raw_store :: proc(name: string, rights_word: u64) -> pr.Project_Console_Store {
	st: pr.Project_Console_Store
	raw := transmute([]u8)name
	copy(st.name_bytes[:len(raw)], raw)
	st.name_length = u8(len(raw))
	st.rights_word = rights_word
	return st
}

@(private = "file")
pu_make_raw_module :: proc(name: string, hash: blake3.Hash) -> pr.Project_Console_Module {
	mod: pr.Project_Console_Module
	raw := transmute([]u8)name
	copy(mod.name_bytes[:len(raw)], raw)
	mod.name_length = u8(len(raw))
	mod.module_hash = hash
	return mod
}

@(test)
enter_scope_refusal_border_refuses_unknown_words :: proc(t: ^testing.T) {
	for member in Enter_Scope_Refusal {
		got, ok := enter_scope_refusal_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, got, member)
	}
	_, bad_1 := enter_scope_refusal_of_word(15)
	_, bad_2 := enter_scope_refusal_of_word(max(u64))
	testing.expect(t, !bad_1)
	testing.expect(t, !bad_2)
}

@(test)
pins_lex_update_entry_single_line_diff_and_refusals :: proc(t: ^testing.T) {
	src_git := pu_hash("catalog.git")
	src_follow := pu_hash("catalog.follow")

	pin_alpha, r0 := pr.pin_entry_make("alpha", src_git, pu_hash("alpha-v1"), "commit-a1")
	pin_gt, r1 := pr.pin_entry_make("gt", src_follow, pu_hash("gt-v1"), "rel-41")
	pin_zebra, r2 := pr.pin_entry_make("zebra", src_git, pu_hash("zebra-v1"), "commit-z1")
	testing.expect_value(t, r0, pr.Project_Refusal.None)
	testing.expect_value(t, r1, pr.Project_Refusal.None)
	testing.expect_value(t, r2, pr.Project_Refusal.None)

	initial_pins := [3]pr.Pin_Entry{pin_alpha, pin_gt, pin_zebra}
	initial_buf: [pr.MAX_PINS_LEX_BYTES]u8
	initial_len, fmt_ref := pr.pins_lex_format(initial_pins[:], initial_buf[:])
	testing.expect_value(t, fmt_ref, pr.Project_Refusal.None)
	initial_bytes := initial_buf[:initial_len]

	// Update ONLY "gt" -> review diff must change exactly 1 line (line 3).
	updated_buf: [pr.MAX_PINS_LEX_BYTES]u8
	upd := pins_lex_update_entry(initial_bytes, "gt", src_follow, pu_hash("gt-v2"), "rel-42", false, updated_buf[:])
	testing.expect_value(t, upd.refusal, pr.Project_Refusal.None)
	testing.expect(t, upd.changed)
	testing.expect(t, !upd.inserted)
	testing.expect_value(t, upd.changed_line_number, u32(3))
	testing.expect_value(t, upd.old_tree_hash, pu_hash("gt-v1"))
	testing.expect_value(t, upd.new_tree_hash, pu_hash("gt-v2"))

	old_lines := strings.split_lines(string(initial_bytes), context.temp_allocator)
	new_lines := strings.split_lines(string(updated_buf[:upd.written]), context.temp_allocator)
	testing.expect_value(t, len(new_lines), len(old_lines))
	diff_count := 0
	diff_line_1based := u32(0)
	for idx in 0 ..< len(old_lines) {
		if old_lines[idx] != new_lines[idx] {
			diff_count += 1
			diff_line_1based = u32(idx + 1)
		}
	}
	testing.expect_value(t, diff_count, 1)
	testing.expect_value(t, diff_line_1based, upd.changed_line_number)

	// Re-applying identical values reports changed == false and identical bytes.
	noop_buf: [pr.MAX_PINS_LEX_BYTES]u8
	noop := pins_lex_update_entry(updated_buf[:upd.written], "gt", src_follow, pu_hash("gt-v2"), "rel-42", false, noop_buf[:])
	testing.expect_value(t, noop.refusal, pr.Project_Refusal.None)
	testing.expect(t, !noop.changed)
	testing.expect(t, slice.equal(noop_buf[:noop.written], updated_buf[:upd.written]))

	// Missing pin refused when allow_insert is false, leaving output untouched.
	sentinel: [pr.MAX_PINS_LEX_BYTES]u8
	sentinel[0] = 0xCC
	miss := pins_lex_update_entry(initial_bytes, "beta", src_git, pu_hash("beta-v1"), "main", false, sentinel[:])
	testing.expect_value(t, miss.refusal, pr.Project_Refusal.Pin_Not_Found)
	testing.expect_value(t, sentinel[0], u8(0xCC))

	// Inserting "beta" with allow_insert == true places it at sorted line 3.
	ins_buf: [pr.MAX_PINS_LEX_BYTES]u8
	ins := pins_lex_update_entry(initial_bytes, "beta", src_git, pu_hash("beta-v1"), "main", true, ins_buf[:])
	testing.expect_value(t, ins.refusal, pr.Project_Refusal.None)
	testing.expect(t, ins.inserted)
	testing.expect(t, ins.changed)
	testing.expect_value(t, ins.changed_line_number, u32(3))

	// Adversarial refusals leave output completely untouched.
	testing.expect_value(t, pins_lex_update_entry(initial_bytes, "", src_git, pu_hash("x"), "", false, sentinel[:]).refusal, pr.Project_Refusal.Invalid_Pin_Name)
	testing.expect_value(t, pins_lex_update_entry(initial_bytes, "let", src_git, pu_hash("x"), "", false, sentinel[:]).refusal, pr.Project_Refusal.Invalid_Pin_Name)
	testing.expect_value(t, pins_lex_update_entry(initial_bytes, "../gt", src_git, pu_hash("x"), "", false, sentinel[:]).refusal, pr.Project_Refusal.Invalid_Pin_Name)
	testing.expect_value(t, pins_lex_update_entry(initial_bytes, "gt", {}, pu_hash("x"), "", false, sentinel[:]).refusal, pr.Project_Refusal.Zero_Hash)
	testing.expect_value(t, pins_lex_update_entry(initial_bytes, "gt", src_git, {}, "", false, sentinel[:]).refusal, pr.Project_Refusal.Zero_Hash)
	testing.expect_value(t, pins_lex_update_entry(initial_bytes, "gt", src_git, pu_hash("x"), "bad\"ref", false, sentinel[:]).refusal, pr.Project_Refusal.Invalid_Upstream_Ref)
	testing.expect_value(t, pins_lex_update_entry(transmute([]u8)string("not lex"), "gt", src_git, pu_hash("x"), "", false, sentinel[:]).refusal, pr.Project_Refusal.Malformed_Syntax)
	testing.expect_value(t, pins_lex_update_entry(initial_bytes, "gt", src_follow, pu_hash("gt-v2"), "rel-42", false, sentinel[:upd.written - 1]).refusal, pr.Project_Refusal.Buffer_Too_Small)
	testing.expect_value(t, sentinel[0], u8(0xCC))
}

@(test)
project_enter_scope_refuses_ambient_paths_duplicates_and_escalation :: proc(t: ^testing.T) {
	proj_hash := pu_hash("project-root")
	mod_odin, mr0 := pr.project_console_module_make("odin", pu_hash("mod-odin"))
	mod_nasm, mr1 := pr.project_console_module_make("nasm", pu_hash("mod-nasm"))
	testing.expect_value(t, mr0, pr.Project_Refusal.None)
	testing.expect_value(t, mr1, pr.Project_Refusal.None)

	held_kernel, sr0 := pr.project_console_store_make("kernel", .Read_Write)
	held_docs, sr1 := pr.project_console_store_make("docs", .Read_Only)
	testing.expect_value(t, sr0, pr.Project_Refusal.None)
	testing.expect_value(t, sr1, pr.Project_Refusal.None)
	caller_stores := [2]pr.Project_Console_Store{held_kernel, held_docs}

	// Nil, zero project hash, empty scope, and count overflows.
	r_nil, _ := project_enter_scope_validate(nil, caller_stores[:])
	testing.expect_value(t, r_nil, Enter_Scope_Refusal.Bad_Scope)

	scope := Project_Enter_Scope{principal = 1}
	r_zero, _ := project_enter_scope_validate(&scope, caller_stores[:])
	testing.expect_value(t, r_zero, Enter_Scope_Refusal.Zero_Project_Hash)

	scope.project_tree_hash = proj_hash
	r_empty, _ := project_enter_scope_validate(&scope, caller_stores[:])
	testing.expect_value(t, r_empty, Enter_Scope_Refusal.Empty_Scope)

	too_many_mods := scope
	too_many_mods.module_count = pr.MAX_CONSOLE_MODULES + 1
	r_tmm, _ := project_enter_scope_validate(&too_many_mods, caller_stores[:])
	testing.expect_value(t, r_tmm, Enter_Scope_Refusal.Too_Many_Modules)

	too_many_stores := scope
	too_many_stores.store_count = pr.MAX_CONSOLE_STORES + 1
	r_tms, _ := project_enter_scope_validate(&too_many_stores, caller_stores[:])
	testing.expect_value(t, r_tms, Enter_Scope_Refusal.Too_Many_Stores)

	// Ambient host paths in store names are explicitly refused.
	ambient_paths := [?]string{"/etc/passwd", "../secret", "~/keys", "dir/sub", "C:\\data", ".hidden"}
	for path in ambient_paths {
		amb := scope
		amb.store_count = 1
		amb.stores[0] = pu_make_raw_store(path, u64(pr.Plan_Store_Rights.Read_Only))
		ref, idx := project_enter_scope_validate(&amb, caller_stores[:])
		testing.expect_value(t, ref, Enter_Scope_Refusal.Ambient_Path_Refused)
		testing.expect_value(t, idx, u32(0))
	}

	// Ambient host path in module name is explicitly refused.
	amb_mod := scope
	amb_mod.module_count = 1
	amb_mod.modules[0] = pu_make_raw_module("/usr/bin/odin", pu_hash("mod-odin"))
	r_amb_mod, _ := project_enter_scope_validate(&amb_mod, caller_stores[:])
	testing.expect_value(t, r_amb_mod, Enter_Scope_Refusal.Ambient_Path_Refused)

	// Zero module hash and duplicate module name refused.
	zero_mod := scope
	zero_mod.module_count = 1
	zero_mod.modules[0] = pu_make_raw_module("odin", {})
	r_zm, _ := project_enter_scope_validate(&zero_mod, caller_stores[:])
	testing.expect_value(t, r_zm, Enter_Scope_Refusal.Zero_Module_Hash)

	dup_mod := scope
	dup_mod.module_count = 2
	dup_mod.modules[0] = mod_odin
	dup_mod.modules[1] = mod_odin
	r_dm, dm_idx := project_enter_scope_validate(&dup_mod, caller_stores[:])
	testing.expect_value(t, r_dm, Enter_Scope_Refusal.Duplicate_Module)
	testing.expect_value(t, dm_idx, u32(1))

	// Unknown store rights words (0, 3, max(u64)) refused.
	for bad_rights in ([?]u64{0, 3, max(u64)}) {
		bad_r := scope
		bad_r.store_count = 1
		bad_r.stores[0] = pu_make_raw_store("kernel", bad_rights)
		ref, _ := project_enter_scope_validate(&bad_r, caller_stores[:])
		testing.expect_value(t, ref, Enter_Scope_Refusal.Unknown_Store_Rights)
	}

	// Duplicate store name refused.
	dup_st := scope
	dup_st.store_count = 2
	dup_st.stores[0] = held_kernel
	dup_st.stores[1] = held_kernel
	r_ds, ds_idx := project_enter_scope_validate(&dup_st, caller_stores[:])
	testing.expect_value(t, r_ds, Enter_Scope_Refusal.Duplicate_Store)
	testing.expect_value(t, ds_idx, u32(1))

	// Undeclared store and rights escalation refused.
	undec := scope
	undec.store_count = 1
	undec.stores[0] = pu_make_raw_store("private_keys", u64(pr.Plan_Store_Rights.Read_Only))
	r_undec, _ := project_enter_scope_validate(&undec, caller_stores[:])
	testing.expect_value(t, r_undec, Enter_Scope_Refusal.Undeclared_Store)

	escalate := scope
	escalate.store_count = 1
	escalate.stores[0] = pu_make_raw_store("docs", u64(pr.Plan_Store_Rights.Read_Write))
	r_esc, _ := project_enter_scope_validate(&escalate, caller_stores[:])
	testing.expect_value(t, r_esc, Enter_Scope_Refusal.Store_Rights_Exceeded)

	// Valid attenuated scope converts cleanly and enters a child console.
	valid := scope
	valid.module_count = 2
	valid.modules[0] = mod_odin
	valid.modules[1] = mod_nasm
	valid.store_count = 2
	valid.stores[0] = pu_make_raw_store("kernel", u64(pr.Plan_Store_Rights.Read_Only))
	valid.stores[1] = held_docs

	spec, conv_ref := project_enter_scope_to_console_spec(&valid, caller_stores[:])
	testing.expect_value(t, conv_ref, Enter_Scope_Refusal.None)

	state: Projects_State
	state_init(&state)
	ctx, enter_ref := enter_project(&state, &spec, caller_stores[:])
	testing.expect_value(t, enter_ref, pr.Project_Refusal.None)
	testing.expect_value(t, ctx.module_count, u32(2))
	testing.expect_value(t, ctx.store_count, u32(2))
}
