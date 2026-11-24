#+build !freestanding
package agent_bridge

import "core:testing"
import assistant_contract "modus:contract/assistant"
import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/remote"
import "modus:contract/wide_grants"

@(private = "file")
approved_test_policy :: proc(client_key: [32]u8, now_ms: u64) -> Bridge_Client_Policy {
	client_key := client_key
	terms := wide_grants.Wide_Grant_Terms {
		principal_id          = 1,
		grantee_identity_hash = blake3.hash(client_key[:]),
		authorities_word      = wide_grants.wide_authorities_to_word({.View_Screen, .Send_Input}),
		target_window_count   = 1,
		target_window_ids     = {0 = 42},
		duration_ms           = wide_grants.DEFAULT_WIDE_GRANT_DURATION_MS,
		survives_restart      = false,
	}
	terms.terms_hash, _ = wide_grants.wide_grant_terms_compute_hash(&terms)
	return {
		client_key_public     = client_key,
		principal_id          = 1,
		permissions_word      = bridge_permissions_to_word({.Eval_Lex, .Eval_Step, .Read_Screen, .Send_Input, .Read_Log_Facts}),
		remote_uses_word      = remote.client_uses_word({.Calls, .View, .Input}),
		has_wide_grant        = true,
		wide_grant_serial     = 7,
		wide_grant_state_word = u64(wide_grants.Wide_Grant_State.Active),
		wide_grant_terms      = terms,
		wide_grant_created_ms = now_ms - 1000,
		wide_grant_expires_ms = now_ms + 60_000,
		collector_available   = true,
	}
}

// Every sensitive action gated by wide_grants.act_requires_principal_proof must
// be refused hard by bridge_authorize_approved_act even with an active wide
// grant AND Allowed_By_Principal on the trusted display.
@(test)
test_approved_act_never_bypasses_principal_proof :: proc(t: ^testing.T) {
	key := [32]u8{0 = 0x11, 31 = 0x22}
	now_ms: u64 = 10_000
	policy := approved_test_policy(key, now_ms)

	sensitive_lines := [?]struct {
		line:    string,
		service: string,
		export:  string,
	}{
		{`plans.apply("home")`, "plans", "apply"},
		{`plans.apply_poll(1)`, "plans", "apply_poll"},
		{`plans.rollback()`, "plans", "rollback"},
		{`unlock.passphrase("x")`, "unlock", "passphrase"},
		{`compositor.act_ask("plans.apply")`, "compositor", "act_ask"},
		{`compositor.powerbox_ask("notes")`, "compositor", "powerbox_ask"},
		{`compositor.plan_diff_ask("diff")`, "compositor", "plan_diff_ask"},
		{`compositor.revoke_grant(1)`, "compositor", "revoke_grant"},
		{`compositor.wide_grant_mark(1)`, "compositor", "wide_grant_mark"},
		{`collector.create_grant(1)`, "collector", "create_grant"},
		{`collector.revoke_grant(1)`, "collector", "revoke_grant"},
		{`assistant.act_result(1, 5, "allowed")`, "assistant", "act_result"},
		{`principals.add("bob")`, "principals", "add"},
		{`remote.allow("key")`, "remote", "allow"},
		{`disk_grants.set(1)`, "disk_grants", "set"},
		{`storage.grant_set("notes")`, "storage", "grant_set"},
		{`root.disk_grant_set(1)`, "root", "disk_grant_set"},
		{`root.replace("console")`, "root", "replace"},
		{`debugger.attach(1)`, "debugger", "attach"},
	}

	for item in sensitive_lines {
		action := classify_lex_sensitive_action(transmute([]u8)item.service, transmute([]u8)item.export)
		testing.expectf(t, wide_grants.act_requires_principal_proof(action), "%s.%s must require principal proof", item.service, item.export)
		binding := Approved_Act_Binding {
			act_number      = 1,
			principal_state = .Allowed_By_Principal,
			service         = transmute([]u8)item.service,
			export          = transmute([]u8)item.export,
			line_hash       = blake3.hash(transmute([]u8)item.line),
			already_used    = false,
		}
		decision := bridge_authorize_approved_act(&policy, &binding, transmute([]u8)item.line, now_ms)
		testing.expectf(t, decision.state == .Ended && decision.refusal == .Principal_Approval_Required, "%q was not refused: %v", item.line, decision)
		testing.expect_value(t, decision.outcome, call_outcome.Call_Outcome.Grant_Or_Right_Missing)
	}
}

// Non-sensitive approved acts run only when every binding, wide-grant,
// single-use, and collector check passes; tampering, replay, missing grant,
// expired grant, or non-Allowed_By_Principal state are all refused.
@(test)
test_approved_act_binding_and_single_use_refusals :: proc(t: ^testing.T) {
	key := [32]u8{0 = 0x33, 31 = 0x44}
	now_ms: u64 = 10_000
	policy := approved_test_policy(key, now_ms)
	line := `settings.set(.french)`
	service := "settings"
	export := "set"
	good_binding := Approved_Act_Binding {
		act_number      = 5,
		principal_state = .Allowed_By_Principal,
		service         = transmute([]u8)service,
		export          = transmute([]u8)export,
		line_hash       = blake3.hash(transmute([]u8)line),
		already_used    = false,
	}

	// Valid approved non-sensitive act succeeds.
	ok_decision := bridge_authorize_approved_act(&policy, &good_binding, transmute([]u8)line, now_ms)
	testing.expect_value(t, ok_decision.state, Bridge_Request_State.Ended)
	testing.expect_value(t, ok_decision.outcome, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, ok_decision.refusal, Bridge_Refusal.None)
	testing.expect_value(t, ok_decision.required_act_kind, wide_grants.Act_Kind.Call_Made)

	// Replay (already_used = true) refused.
	replayed := good_binding
	replayed.already_used = true
	testing.expect_value(t, bridge_authorize_approved_act(&policy, &replayed, transmute([]u8)line, now_ms).refusal, Bridge_Refusal.Approval_Already_Used)

	// Mutated argument after approval -> hash mismatch refused.
	mutated_line := `settings.set(.english)`
	testing.expect_value(t, bridge_authorize_approved_act(&policy, &good_binding, transmute([]u8)mutated_line, now_ms).refusal, Bridge_Refusal.Approval_Mismatch)

	// Wrong principal state (Proposed, Awaiting_Principal, Refused_By_Principal, Done, Not_Shown).
	for bad_state in ([]assistant_contract.Act_State{.Proposed, .Awaiting_Principal, .Refused_By_Principal, .Done, .Refused, .Not_Shown}) {
		bad_binding := good_binding
		bad_binding.principal_state = bad_state
		testing.expect_value(t, bridge_authorize_approved_act(&policy, &bad_binding, transmute([]u8)line, now_ms).refusal, Bridge_Refusal.Principal_Approval_Required)
	}

	// No wide grant -> Wide_Grant_Required.
	no_grant := policy
	no_grant.has_wide_grant = false
	testing.expect_value(t, bridge_authorize_approved_act(&no_grant, &good_binding, transmute([]u8)line, now_ms).refusal, Bridge_Refusal.Wide_Grant_Required)

	// Expired wide grant -> Wide_Grant_Expired.
	testing.expect_value(t, bridge_authorize_approved_act(&policy, &good_binding, transmute([]u8)line, policy.wide_grant_expires_ms).refusal, Bridge_Refusal.Wide_Grant_Expired)

	// Collector unavailable -> Act_Log_Required.
	no_log := policy
	no_log.collector_available = false
	testing.expect_value(t, bridge_authorize_approved_act(&no_log, &good_binding, transmute([]u8)line, now_ms).refusal, Bridge_Refusal.Act_Log_Required)

	// Multi-call or pipe line -> Invalid_Text.
	pipe_line := `settings.set(.french) |> count()`
	pipe_binding := good_binding
	pipe_binding.line_hash = blake3.hash(transmute([]u8)pipe_line)
	testing.expect_value(t, bridge_authorize_approved_act(&policy, &pipe_binding, transmute([]u8)pipe_line, now_ms).refusal, Bridge_Refusal.Invalid_Text)
}

@(test)
test_eval_step_authorization_requires_permission_calls_and_collector :: proc(t: ^testing.T) {
	key := [32]u8{0 = 0x55, 31 = 0x66}
	now_ms: u64 = 10_000
	policy := approved_test_policy(key, now_ms)
	req := Bridge_Authorization_Request{command = .Eval_Step, now_ms = now_ms}

	ok_dec := bridge_authorize_command(&policy, &req)
	testing.expect_value(t, ok_dec.state, Bridge_Request_State.Ended)
	testing.expect_value(t, ok_dec.outcome, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, ok_dec.required_act_kind, wide_grants.Act_Kind.Call_Made)

	// Missing Eval_Step permission -> Permission_Denied.
	no_perm := policy
	no_perm.permissions_word = bridge_permissions_to_word({.Eval_Lex})
	testing.expect_value(t, bridge_authorize_command(&no_perm, &req).refusal, Bridge_Refusal.Permission_Denied)

	// Missing collector -> Act_Log_Required.
	no_log := policy
	no_log.collector_available = false
	testing.expect_value(t, bridge_authorize_command(&no_log, &req).refusal, Bridge_Refusal.Act_Log_Required)
}
