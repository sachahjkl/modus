#+build !freestanding
package powerbox_core

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/powerbox"

TRUSTED_DISPLAY_SLOT :: u32(5)

@(private = "file")
make_hash :: proc(tag: u8) -> blake3.Hash {
	h: blake3.Hash
	h[0] = tag
	h[16] = tag ~ 0x55
	h[31] = tag ~ 0xAA
	return h
}

@(private = "file")
set_label :: proc(batch: ^powerbox.Request_Batch, text: string) {
	batch.asker_label_bytes = {}
	copy(batch.asker_label_bytes[:], text)
	batch.asker_label_length = u8(len(text))
}

@(private = "file")
make_network_item :: proc(ipv4: u32, port: u16, duration: powerbox.Grant_Duration = .This_Run, host: string = "") -> powerbox.Request_Item {
	item := powerbox.Request_Item {
		kind_word           = u64(powerbox.Request_Item_Kind.Network_Endpoint),
		duration_word       = u64(duration),
		reason_word         = u64(powerbox.Grant_Reason.Fetch),
		ipv4_address        = ipv4,
		port                = port,
		transport_word      = u64(powerbox.Network_Transport.Tcp),
		network_rights_word = u64(1) << u64(powerbox.Network_Endpoint_Right.Connect),
	}
	if len(host) > 0 {
		copy(item.host_bytes[:], host)
		item.host_length = u16(len(host))
	}
	return item
}

@(private = "file")
make_store_item :: proc(mode: powerbox.Store_Access_Mode = .Read_Only, duration: powerbox.Grant_Duration = .This_Run) -> powerbox.Request_Item {
	return powerbox.Request_Item {
		kind_word         = u64(powerbox.Request_Item_Kind.Store_Share),
		duration_word     = u64(duration),
		reason_word       = u64(powerbox.Grant_Reason.Open),
		store_access_word = u64(mode),
	}
}

@(private = "file")
make_service_item :: proc(name: string, duration: powerbox.Grant_Duration = .This_Run) -> powerbox.Request_Item {
	item := powerbox.Request_Item {
		kind_word     = u64(powerbox.Request_Item_Kind.Service_Connection),
		duration_word = u64(duration),
		reason_word   = u64(powerbox.Grant_Reason.Use),
	}
	copy(item.service_name_bytes[:], name)
	item.service_name_length = u8(len(name))
	return item
}

@(private = "file")
make_plan_item :: proc(tag: u8) -> powerbox.Request_Item {
	return powerbox.Request_Item {
		kind_word     = u64(powerbox.Request_Item_Kind.Plan_Difference),
		duration_word = u64(powerbox.Grant_Duration.None),
		reason_word   = u64(powerbox.Grant_Reason.None),
		plan_hash     = make_hash(tag),
	}
}

@(private = "file")
make_batch :: proc(
	serial: u64,
	slot: u32,
	principal: u64,
	origin: powerbox.Module_Origin,
	hash_tag: u8,
	label: string,
	item: powerbox.Request_Item,
) -> powerbox.Request_Batch {
	batch := powerbox.Request_Batch {
		request_serial      = serial,
		asker_process_slot  = slot,
		asker_principal     = principal,
		asker_has_window    = true,
		asker_module_origin = u64(origin),
		asker_module_hash   = make_hash(hash_tag),
		item_count          = 1,
	}
	set_label(&batch, label)
	batch.items[0] = item
	return batch
}

@(private = "file")
make_grant_answer :: proc(
	dialog: ^powerbox.Dialog_Record,
	shown_ms: u64,
	press_ms: u64,
	answer_ms: u64,
	decision: powerbox.Item_Decision = .Granted,
	duration: powerbox.Grant_Duration = .This_Run,
) -> powerbox.Grant_Answer {
	ans := powerbox.Grant_Answer {
		dialog_serial            = dialog.dialog_serial,
		request_serial           = dialog.request_serial,
		dialog_record_hash       = dialog.record_hash,
		display_holder_slot      = TRUSTED_DISPLAY_SLOT,
		input_origin_word        = u64(powerbox.Input_Origin.Local_Machine),
		shown_timestamp_ms       = shown_ms,
		input_press_timestamp_ms = press_ms,
		answer_timestamp_ms      = answer_ms,
		item_count               = dialog.item_count,
	}
	for i in u32(0) ..< dialog.item_count {
		ans.items[i] = {
			decision_word = u64(decision),
			duration_word = decision == .Granted ? u64(duration) : u64(powerbox.Grant_Duration.None),
		}
	}
	return ans
}

@(private = "file")
make_test_state :: proc() -> ^Powerbox_State {
	state := new(Powerbox_State, context.temp_allocator)
	tables := Powerbox_Tables {
		stores      = make([]Session_Store, 512, context.temp_allocator),
		held_grants = make([]Held_Grant, 512, context.temp_allocator),
	}
	state_init(state, TRUSTED_DISPLAY_SLOT, tables)
	return state
}

@(test)
anti_clickjacking_enforces_250ms_arm_time_and_monotonic_clocks :: proc(t: ^testing.T) {
	state := make_test_state()

	batch := make_batch(1, 10, 1, .Disk_Module, 0x11, "reader", make_network_item(0x0A00_0264, 443))
	sub, dialog, has_dialog := submit_batch(state, &batch, 1000)
	testing.expect_value(t, sub.refusal, powerbox.Powerbox_Refusal.None)
	testing.expect(t, has_dialog && sub.dialog_queued)

	// Answer before Display marks the dialog Shown MUST be refused.
	early_before_shown := make_grant_answer(&dialog, 1000, 1300, 1300)
	res := resolve_answer(state, &early_before_shown, 1300)
	testing.expect_value(t, res.refusal, powerbox.Powerbox_Refusal.Untrusted_Answer)
	testing.expect_value(t, active_grant_count(state), u32(0))

	// Untrusted slot cannot mark Shown.
	testing.expect_value(t, mark_dialog_shown(state, dialog.dialog_serial, TRUSTED_DISPLAY_SLOT + 1, 1100), powerbox.Powerbox_Refusal.Untrusted_Answer)

	// Trusted Display marks dialog Shown at t = 1100 ms.
	testing.expect_value(t, mark_dialog_shown(state, dialog.dialog_serial, TRUSTED_DISPLAY_SLOT, 1100), powerbox.Powerbox_Refusal.None)

	// Answer at 0 ms after Shown -> refused, 0 grants.
	at_0 := make_grant_answer(&dialog, 1100, 1100, 1100)
	res = resolve_answer(state, &at_0, 1100)
	testing.expect_value(t, res.refusal, powerbox.Powerbox_Refusal.Untrusted_Answer)
	testing.expect_value(t, active_grant_count(state), u32(0))

	// Answer at 249 ms after Shown -> refused, 0 grants.
	at_249 := make_grant_answer(&dialog, 1100, 1349, 1349)
	res = resolve_answer(state, &at_249, 1349)
	testing.expect_value(t, res.refusal, powerbox.Powerbox_Refusal.Untrusted_Answer)
	testing.expect_value(t, active_grant_count(state), u32(0))

	// Key/press started at 249 ms (before arm time) even though released at 300 ms -> refused, 0 grants.
	pre_arm_press := make_grant_answer(&dialog, 1100, 1349, 1400)
	res = resolve_answer(state, &pre_arm_press, 1400)
	testing.expect_value(t, res.refusal, powerbox.Powerbox_Refusal.Untrusted_Answer)
	testing.expect_value(t, active_grant_count(state), u32(0))

	// Clock rollback (now_ms < shown_ms) -> refused safely without u64 underflow.
	rollback := make_grant_answer(&dialog, 1100, 1100, 1100)
	res = resolve_answer(state, &rollback, 900)
	testing.expect_value(t, res.refusal, powerbox.Powerbox_Refusal.Untrusted_Answer)
	testing.expect_value(t, active_grant_count(state), u32(0))

	// Forged earlier shown_timestamp_ms in answer -> refused.
	forged_shown := make_grant_answer(&dialog, 800, 1349, 1349)
	res = resolve_answer(state, &forged_shown, 1349)
	testing.expect_value(t, res.refusal, powerbox.Powerbox_Refusal.Untrusted_Answer)
	testing.expect_value(t, active_grant_count(state), u32(0))

	// Remote_Display input after 250 ms -> still refused.
	remote_ans := make_grant_answer(&dialog, 1100, 1350, 1350)
	remote_ans.input_origin_word = u64(powerbox.Input_Origin.Remote_Display)
	res = resolve_answer(state, &remote_ans, 1350)
	testing.expect_value(t, res.refusal, powerbox.Powerbox_Refusal.Untrusted_Answer)
	testing.expect_value(t, active_grant_count(state), u32(0))

	// Answer at exact 250 ms (1100 + 250 = 1350) -> accepted!
	at_250 := make_grant_answer(&dialog, 1100, 1350, 1350)
	res = resolve_answer(state, &at_250, 1350)
	testing.expect_value(t, res.refusal, powerbox.Powerbox_Refusal.None)
	testing.expect_value(t, res.items[0].decision, powerbox.Item_Decision.Granted)
	testing.expect(t, res.items[0].granted_handle_id != 0)
	testing.expect_value(t, active_grant_count(state), u32(1))

	// Replaying the same answer after resolution is refused.
	replay := resolve_answer(state, &at_250, 1400)
	testing.expect_value(t, replay.refusal, powerbox.Powerbox_Refusal.Untrusted_Answer)
	testing.expect_value(t, active_grant_count(state), u32(1))
}

@(test)
dialog_expires_at_60s_with_zero_grants_issued :: proc(t: ^testing.T) {
	state := make_test_state()

	batch := make_batch(10, 11, 1, .Disk_Module, 0x22, "fetcher", make_network_item(0x0A00_0264, 80))
	_, dialog, has_dialog := submit_batch(state, &batch, 5000)
	testing.expect(t, has_dialog)
	testing.expect_value(t, mark_dialog_shown(state, dialog.dialog_serial, TRUSTED_DISPLAY_SLOT, 5100), powerbox.Powerbox_Refusal.None)

	// At 59_999 ms elapsed (64_999 ms), dialog is NOT expired yet.
	testing.expect_value(t, expire_dialogs(state, 5000 + DIALOG_EXPIRY_MILLISECONDS - 1), u32(0))
	testing.expect_value(t, pending_count_for_session(state, 1), u32(1))

	// At exact 60_000 ms elapsed (65_000 ms), resolve_answer marks dialog Expired with zero grants.
	late := make_grant_answer(&dialog, 5100, 65_000, 65_000)
	res := resolve_answer(state, &late, 5000 + DIALOG_EXPIRY_MILLISECONDS)
	testing.expect_value(t, res.refusal, powerbox.Powerbox_Refusal.None)
	testing.expect_value(t, res.items[0].decision, powerbox.Item_Decision.Expired)
	testing.expect_value(t, res.items[0].granted_handle_id, u64(0))
	testing.expect_value(t, active_grant_count(state), u32(0))
	testing.expect_value(t, pending_count_for_session(state, 1), u32(0))
	testing.expect_value(t, state.counters.total_expired_dialogs, u64(1))
}

@(test)
session_queue_bound_refuses_fourth_concurrent_dialog :: proc(t: ^testing.T) {
	state := make_test_state()

	// Queue 3 concurrent dialogs in session 1 (from 3 processes).
	for i in u32(0) ..< MAX_PENDING_DIALOGS {
		b := make_batch(u64(i + 1), 20 + i, 1, .Disk_Module, u8(0x30 + i), "worker", make_network_item(0x0A00_0201 + i, u16(8000 + i)))
		sub, _, has_dialog := submit_batch(state, &b, 1000 + u64(i))
		testing.expect_value(t, sub.refusal, powerbox.Powerbox_Refusal.None)
		testing.expect(t, has_dialog)
	}
	testing.expect_value(t, pending_count_for_session(state, 1), u32(MAX_PENDING_DIALOGS))

	// 4th concurrent dialog in session 1 MUST be refused with Dialog_Queue_Full.
	fourth := make_batch(4, 24, 1, .Disk_Module, 0x34, "fourth_app", make_network_item(0x0A00_0205, 8004))
	sub4, _, has_dialog4 := submit_batch(state, &fourth, 1010)
	testing.expect_value(t, sub4.refusal, powerbox.Powerbox_Refusal.Dialog_Queue_Full)
	testing.expect(t, !has_dialog4)
	testing.expect_value(t, pending_count_for_session(state, 1), u32(MAX_PENDING_DIALOGS))

	// Another session (principal 2) is unaffected by session 1's queue.
	other_session := make_batch(5, 30, 2, .Disk_Module, 0x35, "other_app", make_service_item("date"))
	sub_other, _, has_other := submit_batch(state, &other_session, 1010)
	testing.expect_value(t, sub_other.refusal, powerbox.Powerbox_Refusal.None)
	testing.expect(t, has_other)
	testing.expect_value(t, pending_count_for_session(state, 2), u32(1))

	// After session 1 dialogs expire at +60s, a new dialog in session 1 is accepted.
	sub4_retry, _, has_retry := submit_batch(state, &fourth, 1000 + DIALOG_EXPIRY_MILLISECONDS + 10)
	testing.expect_value(t, sub4_retry.refusal, powerbox.Powerbox_Refusal.None)
	testing.expect(t, has_retry)
	testing.expect_value(t, pending_count_for_session(state, 1), u32(1))
}

@(test)
rate_limit_quiet_time_refusal_cap_and_no_window_order :: proc(t: ^testing.T) {
	state := make_test_state()

	// No_Window is refused at border and MUST NOT consume the 500 ms rate limit.
	no_win := make_batch(1, 40, 1, .Disk_Module, 0x40, "bg_proc", make_service_item("settings"))
	no_win.asker_has_window = false
	r0, _, has0 := submit_batch(state, &no_win, 1000)
	testing.expect_value(t, r0.refusal, powerbox.Powerbox_Refusal.No_Window)
	testing.expect(t, !has0)

	// Immediately at t=1000 with a window, request succeeds.
	ok_batch := make_batch(2, 40, 1, .Disk_Module, 0x40, "bg_proc", make_service_item("settings"))
	r1, d1, has1 := submit_batch(state, &ok_batch, 1000)
	testing.expect_value(t, r1.refusal, powerbox.Powerbox_Refusal.None)
	testing.expect(t, has1)

	// Second request at t=1499 ms (499 ms elapsed) -> Rate_Limited.
	b2 := make_batch(3, 40, 1, .Disk_Module, 0x40, "bg_proc", make_service_item("date"))
	r_fast, _, _ := submit_batch(state, &b2, 1499)
	testing.expect_value(t, r_fast.refusal, powerbox.Powerbox_Refusal.Rate_Limited)

	// At exact 500 ms (t=1500 ms), second request is allowed.
	r_ok, _, has_ok := submit_batch(state, &b2, 1500)
	testing.expect_value(t, r_ok.refusal, powerbox.Powerbox_Refusal.None)
	testing.expect(t, has_ok)

	// Refuse 3 dialogs whole -> after 3rd whole refusal, process is blocked for rest of run.
	testing.expect_value(t, mark_dialog_shown(state, d1.dialog_serial, TRUSTED_DISPLAY_SLOT, 1600), powerbox.Powerbox_Refusal.None)
	refuse1 := make_grant_answer(&d1, 1600, 1900, 1900, .Refused)
	res_ref1 := resolve_answer(state, &refuse1, 1900)
	testing.expect_value(t, res_ref1.refusal, powerbox.Powerbox_Refusal.None)
	testing.expect_value(t, res_ref1.items[0].decision, powerbox.Item_Decision.Refused)

	// During 60 s quiet time (1900 + 59_999), new request is Rate_Limited.
	b3 := make_batch(4, 40, 1, .Disk_Module, 0x40, "bg_proc", make_service_item("manual"))
	r_quiet, _, _ := submit_batch(state, &b3, 1900 + QUIET_TIME_AFTER_REFUSAL_MILLISECONDS - 1)
	testing.expect_value(t, r_quiet.refusal, powerbox.Powerbox_Refusal.Rate_Limited)

	// Complete 2 more whole refusals after quiet time to hit MAX_WHOLE_REFUSALS_PER_RUN (3).
	t_now := 1900 + QUIET_TIME_AFTER_REFUSAL_MILLISECONDS
	for round in u64(0) ..< 2 {
		b := make_batch(10 + round, 40, 1, .Disk_Module, 0x40, "bg_proc", make_service_item("manual"))
		sub_r, dlg, has_d := submit_batch(state, &b, t_now)
		testing.expect_value(t, sub_r.refusal, powerbox.Powerbox_Refusal.None)
		testing.expect(t, has_d)
		testing.expect_value(t, mark_dialog_shown(state, dlg.dialog_serial, TRUSTED_DISPLAY_SLOT, t_now + 10), powerbox.Powerbox_Refusal.None)
		ans := make_grant_answer(&dlg, t_now + 10, t_now + 300, t_now + 300, .Refused)
		_ = resolve_answer(state, &ans, t_now + 300)
		t_now += 300 + QUIET_TIME_AFTER_REFUSAL_MILLISECONDS
	}

	// After 3 whole refusals, even much later in the same run, requests stay Rate_Limited.
	b_after := make_batch(99, 40, 1, .Disk_Module, 0x40, "bg_proc", make_service_item("sound"))
	r_capped, _, has_capped := submit_batch(state, &b_after, t_now + 1_000_000)
	testing.expect_value(t, r_capped.refusal, powerbox.Powerbox_Refusal.Rate_Limited)
	testing.expect(t, !has_capped)
}

@(test)
always_grant_bound_to_hash_not_nickname_and_boot_module_refused :: proc(t: ^testing.T) {
	state := make_test_state()

	// 1. Boot module requesting Always is strictly refused.
	boot_always := make_batch(1, 50, 1, .Boot_Image, 0x50, "console", make_network_item(0x0A00_0264, 443, .Always))
	r_boot, _, has_boot := submit_batch(state, &boot_always, 1000)
	testing.expect_value(t, r_boot.refusal, powerbox.Powerbox_Refusal.Always_Forbidden_For_Boot_Module)
	testing.expect(t, !has_boot)

	// 2. Boot module requesting This_Run, buggy Display answering Always -> refused, 0 grants.
	boot_run := make_batch(2, 50, 1, .Boot_Image, 0x50, "console", make_network_item(0x0A00_0264, 443, .This_Run))
	_, boot_dlg, has_bd := submit_batch(state, &boot_run, 1000)
	testing.expect(t, has_bd)
	testing.expect(t, !boot_dlg.allow_always_duration)
	testing.expect_value(t, mark_dialog_shown(state, boot_dlg.dialog_serial, TRUSTED_DISPLAY_SLOT, 1050), powerbox.Powerbox_Refusal.None)
	bad_boot_ans := make_grant_answer(&boot_dlg, 1050, 1400, 1400, .Granted, .Always)
	res_boot_ans := resolve_answer(state, &bad_boot_ans, 1400)
	testing.expect_value(t, res_boot_ans.refusal, powerbox.Powerbox_Refusal.Always_Forbidden_For_Boot_Module)
	testing.expect_value(t, active_grant_count(state), u32(0))

	// 3. Disk module A (nickname "writer", hash 0x61) receives an Always grant.
	ep_item := make_network_item(0x0A00_0264, 443, .Always, "sync.example.com")
	disk_a := make_batch(3, 61, 1, .Disk_Module, 0x61, "writer", ep_item)
	_, dlg_a, has_da := submit_batch(state, &disk_a, 2000)
	testing.expect(t, has_da && dlg_a.allow_always_duration)
	testing.expect_value(t, mark_dialog_shown(state, dlg_a.dialog_serial, TRUSTED_DISPLAY_SLOT, 2050), powerbox.Powerbox_Refusal.None)
	ans_a := make_grant_answer(&dlg_a, 2050, 2400, 2400, .Granted, .Always)
	res_a := resolve_answer(state, &ans_a, 2400)
	testing.expect_value(t, res_a.refusal, powerbox.Powerbox_Refusal.None)
	testing.expect_value(t, res_a.items[0].decision, powerbox.Item_Decision.Granted)
	testing.expect_value(t, res_a.items[0].duration, powerbox.Grant_Duration.Always)

	// Simulate session lock / restart: active session grants end, Always rows stay.
	_, revoked := lock_session(state, 1)
	testing.expect(t, revoked >= 1)
	testing.expect_value(t, active_grant_count(state), u32(0))

	// Disk module A restarts with the SAME hash (0x61) -> Held shortcut without dialog!
	disk_a_restart := make_batch(4, 62, 1, .Disk_Module, 0x61, "writer", ep_item)
	res_held, _, has_held_dlg := submit_batch(state, &disk_a_restart, 3000)
	testing.expect_value(t, res_held.refusal, powerbox.Powerbox_Refusal.None)
	testing.expect(t, res_held.all_held && !has_held_dlg)
	testing.expect_value(t, res_held.items[0].decision, powerbox.Item_Decision.Held)
	testing.expect(t, res_held.items[0].granted_handle_id != 0)

	// Hostile disk module B with the EXACT SAME nickname "writer" but DIFFERENT hash (0x62)
	// MUST NOT receive Held from module A's Always row!
	disk_b_impostor := make_batch(5, 63, 1, .Disk_Module, 0x62, "writer", ep_item)
	res_imp, _, has_imp_dlg := submit_batch(state, &disk_b_impostor, 3100)
	testing.expect_value(t, res_imp.refusal, powerbox.Powerbox_Refusal.None)
	testing.expect(t, !res_imp.all_held && has_imp_dlg)
}

@(test)
held_shortcut_and_partial_held_batch :: proc(t: ^testing.T) {
	state := make_test_state()

	svc_date := make_service_item("date")
	svc_settings := make_service_item("settings")
	start_handle, reg_ok := register_start_grant(state, 70, 1, make_hash(0x70), &svc_date)
	testing.expect(t, reg_ok && start_handle != 0)

	// Batch containing ONLY the start-granted item resolves Held immediately with no dialog.
	b_only := make_batch(1, 70, 1, .Boot_Image, 0x70, "clock_app", svc_date)
	res_only, _, has_only := submit_batch(state, &b_only, 1000)
	testing.expect_value(t, res_only.refusal, powerbox.Powerbox_Refusal.None)
	testing.expect(t, res_only.all_held && !has_only)
	testing.expect_value(t, res_only.items[0].decision, powerbox.Item_Decision.Held)
	testing.expect_value(t, res_only.items[0].granted_handle_id, start_handle)

	// Mixed batch: item 0 is already Held, item 1 is new -> dialog carries ONLY item 1.
	b_mix := b_only
	b_mix.request_serial = 2
	b_mix.item_count = 2
	b_mix.items[0] = svc_date
	b_mix.items[1] = svc_settings
	res_mix, dlg_mix, has_mix := submit_batch(state, &b_mix, 1600)
	testing.expect_value(t, res_mix.refusal, powerbox.Powerbox_Refusal.None)
	testing.expect(t, has_mix && !res_mix.all_held)
	testing.expect_value(t, dlg_mix.item_count, u32(1))

	testing.expect_value(t, mark_dialog_shown(state, dlg_mix.dialog_serial, TRUSTED_DISPLAY_SLOT, 1650), powerbox.Powerbox_Refusal.None)
	ans_mix := make_grant_answer(&dlg_mix, 1650, 2000, 2000, .Granted, .This_Run)
	final_mix := resolve_answer(state, &ans_mix, 2000)
	testing.expect_value(t, final_mix.refusal, powerbox.Powerbox_Refusal.None)
	testing.expect_value(t, final_mix.item_count, u32(2))
	testing.expect_value(t, final_mix.items[0].decision, powerbox.Item_Decision.Held)
	testing.expect_value(t, final_mix.items[0].granted_handle_id, start_handle)
	testing.expect_value(t, final_mix.items[1].decision, powerbox.Item_Decision.Granted)
	testing.expect(t, final_mix.items[1].granted_handle_id != 0 && final_mix.items[1].granted_handle_id != start_handle)
}

@(test)
plan_difference_rejects_partial_ticks_and_applies_or_refuses_whole :: proc(t: ^testing.T) {
	state := make_test_state()

	b := make_batch(1, 80, 1, .Boot_Image, 0x80, "plans", make_plan_item(0xCC))
	sub, dlg, has_dlg := submit_batch(state, &b, 1000)
	testing.expect_value(t, sub.refusal, powerbox.Powerbox_Refusal.None)
	testing.expect(t, has_dlg)
	testing.expect_value(t, dlg.action_word, u64(powerbox.Dialog_Action.Show_Plan_Difference))
	testing.expect(t, !dlg.allow_per_item_ticks && !dlg.allow_duration_choice && !dlg.allow_always_duration)

	testing.expect_value(t, mark_dialog_shown(state, dlg.dialog_serial, TRUSTED_DISPLAY_SLOT, 1100), powerbox.Powerbox_Refusal.None)

	// Partial / contradictory answer (whole_plan_accepted=true with item Refused) -> refused, 0 grants.
	bad_partial := powerbox.Grant_Answer {
		dialog_serial            = dlg.dialog_serial,
		request_serial           = dlg.request_serial,
		dialog_record_hash       = dlg.record_hash,
		display_holder_slot      = TRUSTED_DISPLAY_SLOT,
		input_origin_word        = u64(powerbox.Input_Origin.Local_Machine),
		shown_timestamp_ms       = 1100,
		input_press_timestamp_ms = 1400,
		answer_timestamp_ms      = 1400,
		whole_plan_accepted      = true,
		item_count               = 1,
	}
	bad_partial.items[0] = {decision_word = u64(powerbox.Item_Decision.Refused), duration_word = u64(powerbox.Grant_Duration.None)}
	res_bad := resolve_answer(state, &bad_partial, 1400)
	testing.expect_value(t, res_bad.refusal, powerbox.Powerbox_Refusal.Untrusted_Answer)
	testing.expect_value(t, active_grant_count(state), u32(0))

	// Providing a duration on Show_Plan_Difference -> refused, 0 grants.
	bad_dur := bad_partial
	bad_dur.items[0] = {decision_word = u64(powerbox.Item_Decision.Granted), duration_word = u64(powerbox.Grant_Duration.This_Run)}
	res_dur := resolve_answer(state, &bad_dur, 1400)
	testing.expect_value(t, res_dur.refusal, powerbox.Powerbox_Refusal.Invalid_Duration)
	testing.expect_value(t, active_grant_count(state), u32(0))

	// Whole accept with zero duration succeeds.
	good_accept := bad_partial
	good_accept.items[0] = {decision_word = u64(powerbox.Item_Decision.Granted), duration_word = u64(powerbox.Grant_Duration.None)}
	res_ok := resolve_answer(state, &good_accept, 1400)
	testing.expect_value(t, res_ok.refusal, powerbox.Powerbox_Refusal.None)
	testing.expect_value(t, res_ok.items[0].decision, powerbox.Item_Decision.Granted)
	testing.expect(t, res_ok.items[0].granted_handle_id != 0)
}

@(test)
picker_isolation_and_out_of_bounds_index_issues_zero_grants :: proc(t: ^testing.T) {
	state := make_test_state()

	// Register stores for principal 1 and an unrelated store for principal 2.
	testing.expect(t, register_session_store(state, 1, "documents", 101))
	testing.expect(t, register_session_store(state, 1, "photos", 202))
	testing.expect(t, register_session_store(state, 2, "principal2_secret", 999))

	// Principal 1 asks for [Network_Endpoint, Store_Share(Read_Only)] in one grouped batch.
	batch := make_batch(1, 90, 1, .Disk_Module, 0x90, "gallery", make_network_item(0x0A00_0264, 443))
	batch.item_count = 2
	batch.items[1] = make_store_item(.Read_Only, .This_Run)

	sub, dlg, has_dlg := submit_batch(state, &batch, 1000)
	testing.expect_value(t, sub.refusal, powerbox.Powerbox_Refusal.None)
	testing.expect(t, has_dlg)

	// Dialog_Record carries ONLY principal 1's 2 stores — principal 2's store is isolated!
	testing.expect_value(t, dlg.picker_candidate_count, u32(2))
	testing.expect_value(t, dlg.picker_candidates[0].store_id, u64(101))
	testing.expect_value(t, dlg.picker_candidates[1].store_id, u64(202))

	testing.expect_value(t, mark_dialog_shown(state, dlg.dialog_serial, TRUSTED_DISPLAY_SLOT, 1100), powerbox.Powerbox_Refusal.None)

	// Out-of-bounds picker index (2 == count) on item 1 MUST fail whole answer with ZERO grants issued
	// (item 0 Network_Endpoint must NOT leak!).
	bad_pick := make_grant_answer(&dlg, 1100, 1400, 1400, .Granted, .This_Run)
	bad_pick.items[1].picker_selected = true
	bad_pick.items[1].picker_index = 2 // One past upper bound (0, 1).
	bad_pick.items[1].picker_change_count = dlg.picker_change_count
	bad_pick.items[1].picker_name_hash = dlg.picker_candidates[0].name_hash
	res_bad := resolve_answer(state, &bad_pick, 1400)
	testing.expect_value(t, res_bad.refusal, powerbox.Powerbox_Refusal.Picker_Selection_Invalid)
	testing.expect_value(t, active_grant_count(state), u32(0))

	// Valid pick of candidate 1 ("photos", store_id 202) succeeds and mints ONE attenuated
	// single-store handle strictly bound to store 202 and Read_Only.
	good_pick := make_grant_answer(&dlg, 1100, 1400, 1400, .Granted, .This_Run)
	good_pick.items[1].picker_selected = true
	good_pick.items[1].picker_index = 1
	good_pick.items[1].picker_change_count = dlg.picker_change_count
	good_pick.items[1].picker_name_hash = dlg.picker_candidates[1].name_hash
	res_good := resolve_answer(state, &good_pick, 1400)
	testing.expect_value(t, res_good.refusal, powerbox.Powerbox_Refusal.None)
	testing.expect_value(t, res_good.items[0].decision, powerbox.Item_Decision.Granted)
	testing.expect_value(t, res_good.items[1].decision, powerbox.Item_Decision.Granted)
	testing.expect_value(t, res_good.items[1].store_access, powerbox.Store_Access_Mode.Read_Only)
	testing.expect_value(t, active_grant_count(state), u32(2))

	store_grant, found := lookup_issued_grant(state, res_good.items[1].granted_handle_id)
	testing.expect(t, found)
	testing.expect_value(t, store_grant.kind, powerbox.Request_Item_Kind.Store_Share)
	testing.expect_value(t, store_grant.store_id, u64(202))
	testing.expect_value(t, store_grant.store_access, powerbox.Store_Access_Mode.Read_Only)

	// Revoking the handle ends it immediately.
	testing.expect(t, revoke_grant(state, res_good.items[1].granted_handle_id))
	_, still_found := lookup_issued_grant(state, res_good.items[1].granted_handle_id)
	testing.expect(t, !still_found)
}

@(test)
never_ask_again_and_process_stop_withdrawal :: proc(t: ^testing.T) {
	state := make_test_state()

	// Process 95 asks for Network_Endpoint and principal refuses with never_ask_again = true.
	b_net := make_batch(1, 95, 1, .Disk_Module, 0x95, "chat", make_network_item(0x0A00_0264, 443))
	_, dlg, has_dlg := submit_batch(state, &b_net, 1000)
	testing.expect(t, has_dlg)
	testing.expect_value(t, mark_dialog_shown(state, dlg.dialog_serial, TRUSTED_DISPLAY_SLOT, 1050), powerbox.Powerbox_Refusal.None)
	refuse_forever := make_grant_answer(&dlg, 1050, 1400, 1400, .Refused)
	refuse_forever.never_ask_again = true
	res := resolve_answer(state, &refuse_forever, 1400)
	testing.expect_value(t, res.refusal, powerbox.Powerbox_Refusal.None)

	// Even past quiet time, Network_Endpoint from process 95 is refused Rate_Limited.
	b_net2 := make_batch(2, 95, 1, .Disk_Module, 0x95, "chat", make_network_item(0x0A00_0265, 8080))
	res_blocked, _, has_blocked := submit_batch(state, &b_net2, 100_000)
	testing.expect_value(t, res_blocked.refusal, powerbox.Powerbox_Refusal.Rate_Limited)
	testing.expect(t, !has_blocked)

	// Another item kind (Service_Connection) from process 95 is still allowed past quiet time.
	b_svc := make_batch(3, 95, 1, .Disk_Module, 0x95, "chat", make_service_item("date"))
	res_svc, dlg_svc, has_svc := submit_batch(state, &b_svc, 100_000)
	testing.expect_value(t, res_svc.refusal, powerbox.Powerbox_Refusal.None)
	testing.expect(t, has_svc)

	// Stopping process 95 withdraws its pending dialog; any late answer is refused.
	withdrawn, _ := withdraw_for_process(state, 95)
	testing.expect_value(t, withdrawn, u32(1))
	testing.expect_value(t, pending_count_for_session(state, 1), u32(0))
	late_ans := make_grant_answer(&dlg_svc, 100_050, 100_400, 100_400, .Granted, .This_Run)
	res_late := resolve_answer(state, &late_ans, 100_400)
	testing.expect_value(t, res_late.refusal, powerbox.Powerbox_Refusal.Untrusted_Answer)
	testing.expect_value(t, active_grant_count(state), u32(0))
}

// A principal with 300 stores: the dialog carries the first page and the
// count of the whole list, the trusted display pages and searches the rest,
// and a pick of the 251st store gives a share of that store only. A pick
// after the list changed, a page asked by another process, and a full
// table are refused.
@(test)
picker_pages_reach_each_store_of_a_long_list :: proc(t: ^testing.T) {
	state := make_test_state()
	COUNT :: 300
	name_buffer: [16]u8
	for index in 0 ..< COUNT {
		name := store_name(name_buffer[:], index)
		testing.expect(t, register_session_store(state, 1, name, u64(1000 + index)))
	}
	testing.expect(t, register_session_store(state, 2, "other principal", 9))

	batch := make_batch(1, 91, 1, .Disk_Module, 0x91, "gallery", make_store_item(.Read_Only, .This_Run))
	sub, dlg, has_dlg := submit_batch(state, &batch, 1000)
	testing.expect_value(t, sub.refusal, powerbox.Powerbox_Refusal.None)
	testing.expect(t, has_dlg)
	testing.expect_value(t, dlg.picker_candidate_total, u32(COUNT))
	testing.expect_value(t, dlg.picker_candidate_count, u32(powerbox.PICKER_PAGE_CANDIDATES))

	// Each page from the first to the last: each store once, in order.
	request := powerbox.Picker_Page_Request{dialog_serial = dlg.dialog_serial}
	page: powerbox.Picker_Page
	seen := 0
	for {
		testing.expect_value(t, picker_page_take(state, TRUSTED_DISPLAY_SLOT, &request, &page), powerbox.Powerbox_Refusal.None)
		page_refusal, _ := powerbox.picker_page_validate(&page)
		testing.expect_value(t, page_refusal, powerbox.Powerbox_Refusal.None)
		for candidate in page.candidates[:page.candidate_count] {
			testing.expect_value(t, candidate.list_index, u32(seen))
			testing.expect_value(t, candidate.store_id, u64(1000 + seen))
			seen += 1
		}
		if !page.more {
			break
		}
		request.first = page.next
	}
	testing.expect_value(t, seen, COUNT)

	// The search finds the 251st store, past the 32 of one page.
	request = {dialog_serial = dlg.dialog_serial}
	wanted := store_name(name_buffer[:], 250)
	request.query_length = u8(copy(request.query_bytes[:], wanted))
	testing.expect_value(t, picker_page_take(state, TRUSTED_DISPLAY_SLOT, &request, &page), powerbox.Powerbox_Refusal.None)
	testing.expect_value(t, page.candidate_count, u32(1))
	chosen := page.candidates[0]
	testing.expect_value(t, chosen.list_index, u32(250))

	// A page for another holder is refused, and a page of a serial that is
	// not pending.
	testing.expect_value(t, picker_page_take(state, TRUSTED_DISPLAY_SLOT + 1, &request, &page), powerbox.Powerbox_Refusal.Untrusted_Answer)
	unknown := request
	unknown.dialog_serial += 100
	testing.expect_value(t, picker_page_take(state, TRUSTED_DISPLAY_SLOT, &unknown, &page), powerbox.Powerbox_Refusal.Untrusted_Answer)

	testing.expect_value(t, mark_dialog_shown(state, dlg.dialog_serial, TRUSTED_DISPLAY_SLOT, 1100), powerbox.Powerbox_Refusal.None)
	answer := make_grant_answer(&dlg, 1100, 1400, 1400, .Granted, .This_Run)
	answer.items[0].picker_selected = true
	answer.items[0].picker_index = chosen.list_index
	answer.items[0].picker_change_count = dlg.picker_change_count
	// A pick with the hash of another name is refused, with no grant.
	answer.items[0].picker_name_hash = dlg.picker_candidates[0].name_hash
	bad := resolve_answer(state, &answer, 1400)
	testing.expect_value(t, bad.refusal, powerbox.Powerbox_Refusal.Picker_Selection_Invalid)
	testing.expect_value(t, active_grant_count(state), u32(0))

	answer.items[0].picker_name_hash = chosen.name_hash
	good := resolve_answer(state, &answer, 1400)
	testing.expect_value(t, good.refusal, powerbox.Powerbox_Refusal.None)
	grant, found := lookup_issued_grant(state, good.items[0].granted_handle_id)
	testing.expect(t, found)
	testing.expect_value(t, grant.store_id, u64(1250))
}

@(private = "file")
store_name :: proc(buffer: []u8, index: int) -> string {
	text := "store 000"
	length := copy(buffer, text)
	buffer[6] = u8('0' + index / 100)
	buffer[7] = u8('0' + index / 10 % 10)
	buffer[8] = u8('0' + index % 10)
	return string(buffer[:length])
}

// The list changes between the dialog and the answer: the places of the
// dialog name other stores, so the pick is refused.
@(test)
picker_pick_after_the_list_changed_is_refused :: proc(t: ^testing.T) {
	state := make_test_state()
	testing.expect(t, register_session_store(state, 1, "documents", 101))
	batch := make_batch(1, 92, 1, .Disk_Module, 0x92, "gallery", make_store_item(.Read_Only, .This_Run))
	_, dlg, has_dlg := submit_batch(state, &batch, 1000)
	testing.expect(t, has_dlg)
	testing.expect(t, register_session_store(state, 1, "photos", 202))
	request := powerbox.Picker_Page_Request{dialog_serial = dlg.dialog_serial}
	page: powerbox.Picker_Page
	testing.expect_value(t, picker_page_take(state, TRUSTED_DISPLAY_SLOT, &request, &page), powerbox.Powerbox_Refusal.Picker_Selection_Invalid)
	testing.expect_value(t, mark_dialog_shown(state, dlg.dialog_serial, TRUSTED_DISPLAY_SLOT, 1100), powerbox.Powerbox_Refusal.None)
	answer := make_grant_answer(&dlg, 1100, 1400, 1400, .Granted, .This_Run)
	answer.items[0].picker_selected = true
	answer.items[0].picker_change_count = dlg.picker_change_count
	answer.items[0].picker_name_hash = dlg.picker_candidates[0].name_hash
	result := resolve_answer(state, &answer, 1400)
	testing.expect_value(t, result.refusal, powerbox.Powerbox_Refusal.Picker_Selection_Invalid)
	testing.expect_value(t, active_grant_count(state), u32(0))
}

// The tables have the size that the caller gave: none refuses each store,
// one row takes one store.
@(test)
powerbox_tables_refuse_at_their_own_size :: proc(t: ^testing.T) {
	state := new(Powerbox_State, context.temp_allocator)
	state_init(state, TRUSTED_DISPLAY_SLOT, {})
	testing.expect(t, !register_session_store(state, 1, "documents", 101))
	one: [1]Session_Store
	state_init(state, TRUSTED_DISPLAY_SLOT, {stores = one[:]})
	testing.expect(t, register_session_store(state, 1, "documents", 101))
	testing.expect(t, !register_session_store(state, 1, "photos", 202))
}
