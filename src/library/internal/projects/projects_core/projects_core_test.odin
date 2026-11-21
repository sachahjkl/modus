#+build !freestanding
package projects_core

import "core:testing"
import "modus:contract/blake3"
import pr "modus:contract/plans_recipes"

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
