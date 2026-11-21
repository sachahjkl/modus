#+build !freestanding
package projects_core

import "core:testing"
import "modus:contract/blake3"
import pr "modus:contract/plans_recipes"
import "modus:contract/powerbox"

@(private = "file")
make_hash :: proc(tag: u8) -> blake3.Hash {
	data := [4]u8{'p', 'r', 'j', tag}
	return blake3.hash(data[:])
}

@(private = "file")
Mock_Resolver_Data :: struct {
	gt_tree:   blake3.Hash,
	tool_tree: blake3.Hash,
	fail_next: bool,
}

@(private = "file")
mock_resolver :: proc "contextless" (request: ^pr.Source_Resolver_Request, user_data: rawptr) -> (pr.Source_Resolver_Response, bool) {
	data := (^Mock_Resolver_Data)(user_data)
	if data.fail_next {
		return {}, false
	}
	name := string(request.input_name_bytes[:request.input_name_length])
	resp := pr.Source_Resolver_Response {
		status_word        = u64(pr.Source_Resolver_Status.Ok),
		source_module_hash = request.source_module_hash,
	}
	if name == "gt" {
		resp.resolved_tree_hash = data.gt_tree
		copy(resp.resolved_ref_bytes[:], "v42")
		resp.resolved_ref_length = 3
	} else {
		resp.resolved_tree_hash = data.tool_tree
		copy(resp.resolved_ref_bytes[:], "deadbeef")
		resp.resolved_ref_length = 8
	}
	return resp, true
}

@(private = "file")
make_resolve_request :: proc(name: string, src_hash: blake3.Hash, addr: string, host: string) -> pr.Source_Resolver_Request {
	req := pr.Source_Resolver_Request {
		action_word        = u64(pr.Source_Resolver_Action.Resolve),
		source_module_hash = src_hash,
	}
	copy(req.input_name_bytes[:], name)
	req.input_name_length = u8(len(name))
	copy(req.address_bytes[:], addr)
	req.address_length = u16(len(addr))
	copy(req.allowed_host_bytes[:], host)
	req.allowed_host_length = u16(len(host))
	return req
}

@(test)
test_projects_update_writes_only_canonical_pins_and_reports_diff :: proc(t: ^testing.T) {
	state := new(Projects_State)
	defer free(state)
	state_init(state)

	git_source := make_hash(1)
	jj_source := make_hash(2)
	requests := [2]pr.Source_Resolver_Request {
		make_resolve_request("tool", git_source, "https://git.example.org/tool", "git.example.org"),
		make_resolve_request("gt", jj_source, "https://jj.example.org/gt", "jj.example.org"),
	}

	data := Mock_Resolver_Data{gt_tree = make_hash(10), tool_tree = make_hash(20)}

	// Initial update from empty pins.lex adds both pins in canonical sorted order.
	res1 := update_pins(state, nil, requests[:], mock_resolver, &data)
	testing.expect_value(t, res1.refusal, pr.Project_Refusal.None)
	testing.expect_value(t, res1.added_count, u32(2))
	testing.expect_value(t, res1.moved_count, u32(0))
	testing.expect(t, res1.pins_lex_length > 0, "pins.lex bytes generated")

	// list_inputs reads back exact sorted pins.
	listed: [pr.MAX_PROJECT_PINS]pr.Pin_Entry
	list_count, list_ref := list_inputs(state, res1.pins_lex_bytes[:res1.pins_lex_length], listed[:])
	testing.expect_value(t, list_ref, pr.Project_Refusal.None)
	testing.expect_value(t, list_count, 2)
	testing.expect_value(t, string(listed[0].name_bytes[:listed[0].name_length]), "gt")
	testing.expect_value(t, listed[0].tree_hash, make_hash(10))
	testing.expect_value(t, string(listed[1].name_bytes[:listed[1].name_length]), "tool")
	testing.expect_value(t, listed[1].tree_hash, make_hash(20))

	// Update ONLY "gt" when upstream moves; "tool" stays pinned to make_hash(20).
	data.gt_tree = make_hash(11)
	data.tool_tree = make_hash(99) // must NOT be touched because filter is "gt"
	res2 := update_pins(state, res1.pins_lex_bytes[:res1.pins_lex_length], requests[:], mock_resolver, &data, "gt")
	testing.expect_value(t, res2.refusal, pr.Project_Refusal.None)
	testing.expect_value(t, res2.moved_count, u32(1))
	testing.expect_value(t, res2.added_count, u32(0))
	testing.expect_value(t, res2.changes[0].old_tree_hash, make_hash(10))
	testing.expect_value(t, res2.changes[0].new_tree_hash, make_hash(11))

	list_count, list_ref = list_inputs(state, res2.pins_lex_bytes[:res2.pins_lex_length], listed[:])
	testing.expect_value(t, list_ref, pr.Project_Refusal.None)
	testing.expect_value(t, list_count, 2)
	testing.expect_value(t, listed[0].tree_hash, make_hash(11))
	testing.expect_value(t, listed[1].tree_hash, make_hash(20))

	// Unknown filter input refused with zero output bytes.
	res_unk := update_pins(state, res2.pins_lex_bytes[:res2.pins_lex_length], requests[:], mock_resolver, &data, "nonexistent")
	testing.expect_value(t, res_unk.refusal, pr.Project_Refusal.Pin_Not_Found)
	testing.expect_value(t, res_unk.pins_lex_length, 0)
}

@(test)
test_projects_enter_and_exit_leave_nothing_installed :: proc(t: ^testing.T) {
	state := new(Projects_State)
	defer free(state)
	state_init(state)

	caller_src, _ := pr.project_console_store_make("kernel", .Read_Write)
	caller_ro, _ := pr.project_console_store_make("docs", .Read_Only)
	caller_stores := [2]pr.Project_Console_Store{caller_src, caller_ro}

	// Undeclared store refused with zero active consoles.
	bad_spec := pr.Project_Console_Spec {
		project_tree_hash = make_hash(70),
		principal         = 1,
		module_count      = 1,
		store_count       = 1,
	}
	bad_spec.modules[0], _ = pr.project_console_module_make("odin", make_hash(71))
	bad_spec.stores[0], _ = pr.project_console_store_make("other_store", .Read_Only)

	_, bad_ref := enter_project(state, &bad_spec, caller_stores[:])
	testing.expect_value(t, bad_ref, pr.Project_Refusal.Undeclared_Store)
	testing.expect_value(t, state.counters.active_consoles, u64(0))

	// Valid enter opens ephemeral console with connected modules and declared stores.
	good_spec := bad_spec
	good_spec.stores[0], _ = pr.project_console_store_make("kernel", .Read_Write)

	ctx, enter_ref := enter_project(state, &good_spec, caller_stores[:])
	testing.expect_value(t, enter_ref, pr.Project_Refusal.None)
	testing.expect(t, ctx.console_id != 0, "console id assigned")
	testing.expect_value(t, state.counters.active_consoles, u64(1))

	found_ctx, found := lookup_console(state, ctx.console_id)
	testing.expect(t, found, "active console must be findable")
	testing.expect_value(t, found_ctx.project_tree_hash, make_hash(70))

	// Another principal cannot close this console.
	testing.expect_value(t, exit_project(state, ctx.console_id, 2), pr.Project_Refusal.Unknown_Console)
	testing.expect_value(t, state.counters.active_consoles, u64(1))

	// Owner principal exits cleanly: zero active consoles, lookup gone, nothing installed.
	testing.expect_value(t, exit_project(state, ctx.console_id, 1), pr.Project_Refusal.None)
	testing.expect_value(t, state.counters.active_consoles, u64(0))
	_, still_there := lookup_console(state, ctx.console_id)
	testing.expect(t, !still_there, "exit must wipe child console context completely")

	// Double exit refused.
	testing.expect_value(t, exit_project(state, ctx.console_id, 1), pr.Project_Refusal.Unknown_Console)
}

@(private = "file")
make_trusted_console_consent :: proc(
	principal: u64,
	spec_hash: blake3.Hash,
	display_slot: u32,
	accepted: bool = true,
	input_origin: powerbox.Input_Origin = .Local_Machine,
) -> (dialog: powerbox.Dialog_Record, answer: powerbox.Grant_Answer) {
	dialog = {
		action_word          = u64(powerbox.Dialog_Action.Show_Plan_Difference),
		dialog_serial        = 11,
		request_serial       = 22,
		session_principal    = principal,
		asker_process_slot   = 7,
		asker_module_origin  = u64(powerbox.Module_Origin.Boot_Image),
		asker_module_hash    = make_hash(90),
		asker_label_length   = u8(len("projects")),
		item_count           = 1,
	}
	copy(dialog.asker_label_bytes[:], "projects")
	dialog.items[0] = {
		kind_word     = u64(powerbox.Request_Item_Kind.Plan_Difference),
		duration_word = u64(powerbox.Grant_Duration.None),
		plan_hash     = spec_hash,
	}
	record_hash, _ := powerbox.dialog_record_hash(&dialog)
	dialog.record_hash = record_hash

	answer = {
		dialog_serial            = dialog.dialog_serial,
		request_serial           = dialog.request_serial,
		dialog_record_hash       = record_hash,
		display_holder_slot      = display_slot,
		input_origin_word        = u64(input_origin),
		shown_timestamp_ms       = 1000,
		input_press_timestamp_ms = 1100,
		answer_timestamp_ms      = 1200,
		whole_plan_accepted      = accepted,
		item_count               = 1,
	}
	answer.items[0] = {
		decision_word = u64(accepted ? powerbox.Item_Decision.Granted : powerbox.Item_Decision.Refused),
		duration_word = u64(powerbox.Grant_Duration.None),
	}
	return dialog, answer
}

@(private = "file")
make_project_decl :: proc(name: string, tree_tag: u8, has_console: bool) -> pr.Project_Declaration {
	decl := pr.Project_Declaration {
		project_tree_hash = make_hash(tree_tag),
		has_console_field = has_console,
	}
	copy(decl.name_bytes[:], name)
	decl.name_length = u8(len(name))
	return decl
}

@(test)
test_project_console_adversarial_refusals_and_nesting_depth :: proc(t: ^testing.T) {
	TRUSTED_DISPLAY :: u32(42)
	state := new(Projects_State)
	defer free(state)
	state_init(state, TRUSTED_DISPLAY)

	base_store_rw, _ := pr.project_console_store_make("kernel", .Read_Write)
	base_store_ro, _ := pr.project_console_store_make("docs", .Read_Only)
	base_stores := [2]pr.Project_Console_Store{base_store_rw, base_store_ro}
	mod_odin, _ := pr.project_console_module_make("odin", make_hash(101))
	mod_nasm, _ := pr.project_console_module_make("nasm", make_hash(102))
	base_modules := [2]pr.Project_Console_Module{mod_odin, mod_nasm}
	applied_plan_before := make_hash(200)

	// 1. Exit with no active project console is refused cleanly.
	_, no_active_ref := exit_current_project(state, 1)
	testing.expect_value(t, no_active_ref, pr.Project_Refusal.No_Active_Console)
	testing.expect_value(t, state.counters.active_consoles, u64(0))
	testing.expect_value(t, state.counters.total_exits, u64(0))

	// 2. Unknown project refused cleanly with zero state mutation.
	_, _, unk_ref := enter_named_project(state, 1, "does_not_exist", 0, base_stores[:], base_modules[:], nil, nil, applied_plan_before)
	testing.expect_value(t, unk_ref, pr.Project_Refusal.Unknown_Project)
	testing.expect_value(t, state.counters.active_consoles, u64(0))

	// 3. Registered project with empty console field refused cleanly.
	empty_decl := make_project_decl("empty_proj", 110, true)
	testing.expect_value(t, register_project(state, &empty_decl), pr.Project_Refusal.None)
	_, _, empty_ref := enter_named_project(state, 1, "empty_proj", 0, base_stores[:], base_modules[:], nil, nil, applied_plan_before)
	testing.expect_value(t, empty_ref, pr.Project_Refusal.Empty_Console)
	testing.expect_value(t, state.counters.active_consoles, u64(0))

	// 4. Duplicate module names in console field refused cleanly.
	dup_decl := make_project_decl("dup_proj", 111, true)
	dup_decl.console_module_count = 2
	dup_decl.console_modules[0] = mod_odin
	dup_decl.console_modules[1], _ = pr.project_console_module_make("odin", make_hash(109))
	dup_decl.console_store_count = 1
	dup_decl.console_stores[0] = base_store_rw
	testing.expect_value(t, register_project(state, &dup_decl), pr.Project_Refusal.None)
	_, _, dup_ref := enter_named_project(state, 1, "dup_proj", 0, base_stores[:], base_modules[:], nil, nil, applied_plan_before)
	testing.expect_value(t, dup_ref, pr.Project_Refusal.Duplicate_Module)
	testing.expect_value(t, state.counters.active_consoles, u64(0))

	// 5. Register valid project covered by current session grants and nest up to MAX_PROJECT_CONSOLE_DEPTH.
	valid_decl := make_project_decl("kernel_proj", 112, true)
	valid_decl.console_module_count = 2
	valid_decl.console_modules[0] = mod_odin
	valid_decl.console_modules[1] = mod_nasm
	valid_decl.console_store_count = 1
	valid_decl.console_stores[0] = base_store_rw
	testing.expect_value(t, register_project(state, &valid_decl), pr.Project_Refusal.None)

	ids: [pr.MAX_PROJECT_CONSOLE_DEPTH]u64
	parent_id := u64(0)
	for level in u32(1) ..= pr.MAX_PROJECT_CONSOLE_DEPTH {
		ctx, diff, enter_ref := enter_named_project(state, 1, "kernel_proj", parent_id, base_stores[:], base_modules[:], nil, nil, applied_plan_before)
		testing.expect_value(t, enter_ref, pr.Project_Refusal.None)
		testing.expect(t, !diff.needs_consent, "covered session grants need no consent")
		testing.expect_value(t, ctx.depth, level)
		testing.expect_value(t, ctx.parent_console_id, parent_id)
		testing.expect_value(t, ctx.applied_plan_hash_snapshot, applied_plan_before)
		ids[level - 1] = ctx.console_id
		parent_id = ctx.console_id
	}
	testing.expect_value(t, active_console_count_for_principal(state, 1), u32(pr.MAX_PROJECT_CONSOLE_DEPTH))
	testing.expect_value(t, state.counters.max_depth_reached, u64(pr.MAX_PROJECT_CONSOLE_DEPTH))

	// One past MAX_PROJECT_CONSOLE_DEPTH is refused cleanly without mutating active depth.
	_, _, overflow_ref := enter_named_project(state, 1, "kernel_proj", parent_id, base_stores[:], base_modules[:], nil, nil, applied_plan_before)
	testing.expect_value(t, overflow_ref, pr.Project_Refusal.Nesting_Depth_Exceeded)
	testing.expect_value(t, active_console_count_for_principal(state, 1), u32(pr.MAX_PROJECT_CONSOLE_DEPTH))

	// Attempting to exit a parent console while a nested child is still active is refused.
	testing.expect_value(t, exit_project(state, ids[0], 1), pr.Project_Refusal.Child_Console_Active)
	testing.expect_value(t, active_console_count_for_principal(state, 1), u32(pr.MAX_PROJECT_CONSOLE_DEPTH))

	// Principal 2 cannot nest under Principal 1's console or exit it.
	_, _, foreign_parent := enter_named_project(state, 2, "kernel_proj", ids[0], base_stores[:], base_modules[:])
	testing.expect_value(t, foreign_parent, pr.Project_Refusal.Unknown_Console)
	_, foreign_exit := exit_current_project(state, 2)
	testing.expect_value(t, foreign_exit, pr.Project_Refusal.No_Active_Console)

	// Unwind via exit_current_project() from depth 4 down to 0, verifying parent restoration and zero leaked state.
	for expected_depth := u32(pr.MAX_PROJECT_CONSOLE_DEPTH); expected_depth >= 1; expected_depth -= 1 {
		report, exit_ref := exit_current_project(state, 1)
		testing.expect_value(t, exit_ref, pr.Project_Refusal.None)
		testing.expect_value(t, report.exited_console_id, ids[expected_depth - 1])
		testing.expect_value(t, report.restored_depth, expected_depth - 1)
		testing.expect_value(t, report.revoked_module_count, u32(2))
		testing.expect_value(t, report.revoked_store_count, u32(1))
		testing.expect_value(t, report.applied_plan_hash_snapshot, applied_plan_before)

		// Exited console is completely wiped and unreachable.
		_, still_active := lookup_console(state, ids[expected_depth - 1])
		testing.expect(t, !still_active, "exited console slot must be wiped")

		if expected_depth > 1 {
			// Parent console state stays completely intact.
			parent_ctx, parent_found := active_console_for_principal(state, 1)
			testing.expect(t, parent_found, "parent console must be restored")
			testing.expect_value(t, parent_ctx.console_id, ids[expected_depth - 2])
			testing.expect_value(t, parent_ctx.depth, expected_depth - 1)
			testing.expect_value(t, parent_ctx.module_count, u32(2))
			testing.expect_value(t, parent_ctx.store_count, u32(1))
		}
	}

	// At base console: zero active consoles, applied plan untouched, further exit refused.
	testing.expect_value(t, state.counters.active_consoles, u64(0))
	testing.expect_value(t, active_console_count_for_principal(state, 1), u32(0))
	_, any_left := active_console_for_principal(state, 1)
	testing.expect(t, !any_left, "no active child console should remain")
	_, extra_exit_ref := exit_current_project(state, 1)
	testing.expect_value(t, extra_exit_ref, pr.Project_Refusal.No_Active_Console)
}

@(test)
test_project_console_consent_required_for_extra_grants :: proc(t: ^testing.T) {
	TRUSTED_DISPLAY :: u32(77)
	state := new(Projects_State)
	defer free(state)
	state_init(state, TRUSTED_DISPLAY)

	// Base session holds only docs (Read_Only) and odin.
	base_docs, _ := pr.project_console_store_make("docs", .Read_Only)
	base_stores := [1]pr.Project_Console_Store{base_docs}
	mod_odin, _ := pr.project_console_module_make("odin", make_hash(120))
	base_modules := [1]pr.Project_Console_Module{mod_odin}

	// Project requests an additional module (qemu) and an additional store (kernel, Read_Write).
	spec := pr.Project_Console_Spec {
		project_tree_hash = make_hash(121),
		principal         = 1,
		module_count      = 2,
		store_count       = 2,
	}
	spec.modules[0] = mod_odin
	spec.modules[1], _ = pr.project_console_module_make("qemu", make_hash(122))
	spec.stores[0] = base_docs
	spec.stores[1], _ = pr.project_console_store_make("kernel", .Read_Write)

	spec_hash, href := pr.project_console_spec_hash(&spec)
	testing.expect_value(t, href, pr.Project_Refusal.None)

	// Without consent: refused with Consent_Required, zero state mutation.
	_, diff, ref := enter_project_session(state, &spec, base_stores[:], base_modules[:])
	testing.expect_value(t, ref, pr.Project_Refusal.Consent_Required)
	testing.expect(t, diff.needs_consent, "extra module and store must require consent")
	testing.expect_value(t, diff.added_module_count, u32(1))
	testing.expect_value(t, diff.added_store_count, u32(1))
	testing.expect_value(t, state.counters.active_consoles, u64(0))

	// Forged display slot refused as Untrusted_Consent.
	dlg_bad_slot, ans_bad_slot := make_trusted_console_consent(1, spec_hash, TRUSTED_DISPLAY + 1)
	_, _, ref = enter_project_session(state, &spec, base_stores[:], base_modules[:], &dlg_bad_slot, &ans_bad_slot)
	testing.expect_value(t, ref, pr.Project_Refusal.Untrusted_Consent)

	// Remote display input refused as Untrusted_Consent.
	dlg_remote, ans_remote := make_trusted_console_consent(1, spec_hash, TRUSTED_DISPLAY, true, .Remote_Display)
	_, _, ref = enter_project_session(state, &spec, base_stores[:], base_modules[:], &dlg_remote, &ans_remote)
	testing.expect_value(t, ref, pr.Project_Refusal.Untrusted_Consent)

	// Wrong spec hash refused as Untrusted_Consent.
	dlg_wrong_hash, ans_wrong_hash := make_trusted_console_consent(1, make_hash(250), TRUSTED_DISPLAY)
	_, _, ref = enter_project_session(state, &spec, base_stores[:], base_modules[:], &dlg_wrong_hash, &ans_wrong_hash)
	testing.expect_value(t, ref, pr.Project_Refusal.Untrusted_Consent)

	// Refused decision (whole_plan_accepted = false) refused as Untrusted_Consent.
	dlg_denied, ans_denied := make_trusted_console_consent(1, spec_hash, TRUSTED_DISPLAY, false)
	_, _, ref = enter_project_session(state, &spec, base_stores[:], base_modules[:], &dlg_denied, &ans_denied)
	testing.expect_value(t, ref, pr.Project_Refusal.Untrusted_Consent)
	testing.expect_value(t, state.counters.active_consoles, u64(0))

	// Verified trusted Display consent succeeds cleanly.
	dlg_ok, ans_ok := make_trusted_console_consent(1, spec_hash, TRUSTED_DISPLAY)
	applied_hash := make_hash(240)
	ctx, _, ref_ok := enter_project_session(state, &spec, base_stores[:], base_modules[:], &dlg_ok, &ans_ok, applied_hash)
	testing.expect_value(t, ref_ok, pr.Project_Refusal.None)
	testing.expect(t, ctx.consent_verified, "consent_verified must be recorded")
	testing.expect_value(t, ctx.depth, u32(1))
	testing.expect_value(t, state.counters.active_consoles, u64(1))

	// Nested child trying to add a store outside its parent console ALSO requires consent.
	nested_spec := pr.Project_Console_Spec {
		project_tree_hash = make_hash(123),
		principal         = 1,
		parent_console_id = ctx.console_id,
		module_count      = 1,
		store_count       = 1,
	}
	nested_spec.modules[0] = mod_odin
	nested_spec.stores[0], _ = pr.project_console_store_make("secrets", .Read_Only)
	_, nested_diff, nested_ref := enter_project_session(state, &nested_spec, base_stores[:], base_modules[:])
	testing.expect_value(t, nested_ref, pr.Project_Refusal.Consent_Required)
	testing.expect_value(t, nested_diff.added_store_count, u32(1))

	// Exit revokes both temporary modules and both temporary stores, restoring root console.
	report, exit_ref := exit_current_project(state, 1)
	testing.expect_value(t, exit_ref, pr.Project_Refusal.None)
	testing.expect_value(t, report.revoked_module_count, u32(2))
	testing.expect_value(t, report.revoked_store_count, u32(2))
	testing.expect_value(t, report.restored_parent_id, u64(0))
	testing.expect_value(t, report.restored_depth, u32(0))
	testing.expect_value(t, report.applied_plan_hash_snapshot, applied_hash)
	testing.expect_value(t, state.counters.active_consoles, u64(0))
}
