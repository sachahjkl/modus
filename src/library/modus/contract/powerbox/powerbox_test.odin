#+build !freestanding
package powerbox

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/remote"
import "modus:contract/remote_display"

@(private = "file")
make_hash :: proc(tag: u8) -> blake3.Hash {
	h: blake3.Hash
	h[0] = tag
	h[15] = tag ~ 0x3C
	h[31] = tag ~ 0xA5
	return h
}

@(private = "file")
set_label :: proc(dest: ^[MAX_NAME_BYTES]u8, length: ^u8, text: string) {
	dest^ = {}
	copy(dest^[:], text)
	length^ = u8(len(text))
}

@(private = "file")
set_host :: proc(item: ^Request_Item, host: string) {
	item.host_bytes = {}
	copy(item.host_bytes[:], host)
	item.host_length = u16(len(host))
}

@(private = "file")
set_service :: proc(item: ^Request_Item, name: string) {
	item.service_name_bytes = {}
	copy(item.service_name_bytes[:], name)
	item.service_name_length = u8(len(name))
}

@(private = "file")
make_network_item :: proc(ipv4: u32, port: u16, duration: Grant_Duration = .This_Run, host: string = "") -> Request_Item {
	item := Request_Item {
		kind_word           = u64(Request_Item_Kind.Network_Endpoint),
		duration_word       = u64(duration),
		reason_word         = u64(Grant_Reason.Fetch),
		ipv4_address        = ipv4,
		port                = port,
		transport_word      = u64(Network_Transport.Tcp),
		network_rights_word = u64(1) << u64(Network_Endpoint_Right.Connect),
	}
	if len(host) > 0 {
		set_host(&item, host)
	}
	return item
}

@(private = "file")
make_store_item :: proc(mode: Store_Access_Mode = .Read_Only, duration: Grant_Duration = .This_Run, reason: Grant_Reason = .Open) -> Request_Item {
	return Request_Item {
		kind_word         = u64(Request_Item_Kind.Store_Share),
		duration_word     = u64(duration),
		reason_word       = u64(reason),
		store_access_word = u64(mode),
	}
}

@(private = "file")
make_service_item :: proc(name: string, duration: Grant_Duration = .This_Run) -> Request_Item {
	item := Request_Item {
		kind_word     = u64(Request_Item_Kind.Service_Connection),
		duration_word = u64(duration),
		reason_word   = u64(Grant_Reason.Use),
	}
	set_service(&item, name)
	return item
}

@(private = "file")
make_plan_item :: proc(tag: u8) -> Request_Item {
	return Request_Item {
		kind_word     = u64(Request_Item_Kind.Plan_Difference),
		duration_word = u64(Grant_Duration.None),
		reason_word   = u64(Grant_Reason.None),
		plan_hash     = make_hash(tag),
	}
}

@(private = "file")
make_valid_batch :: proc(origin: Module_Origin = .Disk_Module) -> Request_Batch {
	batch := Request_Batch {
		request_serial      = 100,
		asker_process_slot  = 7,
		asker_principal     = 1,
		asker_has_window    = true,
		asker_module_origin = u64(origin),
		asker_module_hash   = make_hash(0x42),
		item_count          = 1,
	}
	set_label(&batch.asker_label_bytes, &batch.asker_label_length, "notes_app")
	batch.items[0] = make_network_item(0x0A00_0264, 443, .This_Run)
	return batch
}

@(private = "file")
make_valid_dialog :: proc(origin: Module_Origin = .Disk_Module) -> Dialog_Record {
	dialog := Dialog_Record {
		action_word           = u64(Dialog_Action.Show_Grant_Dialog),
		dialog_serial         = 50,
		request_serial        = 100,
		session_principal     = 1,
		asker_process_slot    = 7,
		asker_module_origin   = u64(origin),
		asker_module_hash     = make_hash(0x42),
		allow_per_item_ticks  = true,
		allow_duration_choice = true,
		allow_always_duration = origin == .Disk_Module,
		item_count            = 3,
		picker_change_count   = 9,
		picker_candidate_count = 2,
	}
	set_label(&dialog.asker_label_bytes, &dialog.asker_label_length, "notes_app")
	dialog.items[0] = make_network_item(0x0A00_0264, 443, .This_Run, "api.example.com")
	dialog.items[1] = make_store_item(.Read_Write, .This_Run, .Save)
	dialog.items[2] = make_service_item("settings", .Once)

	c0, ok0 := picker_candidate_make("documents", 101)
	c1, ok1 := picker_candidate_make("photos", 202)
	assert(ok0 && ok1)
	dialog.picker_candidates[0] = c0
	dialog.picker_candidates[1] = c1
	refusal := dialog_record_seal(&dialog)
	assert(refusal == .None)
	return dialog
}

@(test)
border_enum_parsers_refuse_zero_out_of_range_and_max_words :: proc(t: ^testing.T) {
	for bad in ([?]u64{0, u64(Request_Item_Kind.Plan_Difference) + 1, 255, max(u64)}) {
		kind, ok := request_item_kind_from_word(bad)
		testing.expectf(t, !ok && kind == .None, "kind word %d must be refused", bad)
	}
	for member in Request_Item_Kind {
		if member == .None {
			continue
		}
		parsed, ok := request_item_kind_from_word(u64(member))
		testing.expect(t, ok && parsed == member)
	}

	for bad in ([?]u64{0, u64(Grant_Duration.Always) + 1, 255, max(u64)}) {
		dur, ok := grant_duration_from_word(bad)
		testing.expectf(t, !ok && dur == .None, "duration word %d must be refused", bad)
	}
	for member in Grant_Duration {
		if member == .None {
			continue
		}
		parsed, ok := grant_duration_from_word(u64(member))
		testing.expect(t, ok && parsed == member)
	}

	for bad in ([?]u64{0, u64(Item_Decision.Invalid) + 1, 255, max(u64)}) {
		dec, ok := item_decision_from_word(bad)
		testing.expectf(t, !ok && dec == .None, "decision word %d must be refused", bad)
	}
	for member in Item_Decision {
		if member == .None {
			continue
		}
		parsed, ok := item_decision_from_word(u64(member))
		testing.expect(t, ok && parsed == member)
	}

	for bad in ([?]u64{0, u64(Store_Access_Mode.Read_Write) + 1, 255, max(u64)}) {
		mode, ok := store_access_mode_from_word(bad)
		testing.expectf(t, !ok && mode == .None, "store mode word %d must be refused", bad)
	}

	for bad in ([?]u64{0, u64(Dialog_Action.Dismiss_Dialog) + 1, 255, max(u64)}) {
		act, ok := dialog_action_from_word(bad)
		testing.expectf(t, !ok && act == .None, "dialog action word %d must be refused", bad)
	}

	// Powerbox_Refusal accepts every member including None, refuses past last and max(u64).
	for member in Powerbox_Refusal {
		parsed, ok := powerbox_refusal_from_word(u64(member))
		testing.expect(t, ok && parsed == member)
	}
	for bad in ([?]u64{u64(Powerbox_Refusal.Picker_Selection_Invalid) + 1, 255, max(u64)}) {
		_, ok := powerbox_refusal_from_word(bad)
		testing.expectf(t, !ok, "refusal word %d must be refused", bad)
	}

	// Input origin, module origin, transport, reason, network rights, service command edges.
	for bad in ([?]u64{0, u64(Input_Origin.Remote_Display) + 1, max(u64)}) {
		_, ok := input_origin_from_word(bad)
		testing.expect(t, !ok)
	}
	for bad in ([?]u64{0, u64(Module_Origin.Disk_Module) + 1, max(u64)}) {
		_, ok := module_origin_from_word(bad)
		testing.expect(t, !ok)
	}
	for bad in ([?]u64{0, u64(Network_Transport.Tcp) + 1, max(u64)}) {
		_, ok := network_transport_from_word(bad)
		testing.expect(t, !ok)
	}
	for bad in ([?]u64{u64(Grant_Reason.Use) + 1, max(u64)}) {
		_, ok := grant_reason_from_word(bad)
		testing.expect(t, !ok)
	}
	for bad in ([?]u64{0, u64(1) << 2, u64(1) << 63, max(u64)}) {
		_, ok := network_endpoint_rights_from_word(bad)
		testing.expect(t, !ok)
	}
	for bad in ([?]u32{0, u32(Service_Ring_Command.Query_Counts) + 1, max(u32)}) {
		_, ok := service_ring_command_from_word(bad)
		testing.expect(t, !ok)
	}
}

@(test)
request_batch_validate_edges_counts_and_refusals :: proc(t: ^testing.T) {
	// No_Window refusal.
	no_win := make_valid_batch()
	no_win.asker_has_window = false
	refusal, _ := request_batch_validate(&no_win)
	testing.expect_value(t, refusal, Powerbox_Refusal.No_Window)

	// 0 items -> Empty_Batch.
	empty := make_valid_batch()
	empty.item_count = 0
	refusal, _ = request_batch_validate(&empty)
	testing.expect_value(t, refusal, Powerbox_Refusal.Empty_Batch)

	// 1 item -> valid.
	one := make_valid_batch()
	refusal, _ = request_batch_validate(&one)
	testing.expect_value(t, refusal, Powerbox_Refusal.None)

	// 16 items (exact bound) -> valid.
	full := make_valid_batch()
	full.item_count = MAX_REQUEST_ITEMS
	for i in u32(0) ..< MAX_REQUEST_ITEMS {
		full.items[i] = make_network_item(0x0A00_0201 + i, u16(8000 + i), .This_Run)
	}
	refusal, _ = request_batch_validate(&full)
	testing.expect_value(t, refusal, Powerbox_Refusal.None)

	// 17 items (one past bound) and max(u32) -> Too_Many_Items.
	over := full
	over.item_count = MAX_REQUEST_ITEMS + 1
	refusal, _ = request_batch_validate(&over)
	testing.expect_value(t, refusal, Powerbox_Refusal.Too_Many_Items)

	huge := full
	huge.item_count = max(u32)
	refusal, _ = request_batch_validate(&huge)
	testing.expect_value(t, refusal, Powerbox_Refusal.Too_Many_Items)

	// Duplicate items: same IPv4/port, case-insensitive hostname, same service, same store request.
	dup_ip := make_valid_batch()
	dup_ip.item_count = 2
	dup_ip.items[0] = make_network_item(0x0A00_0264, 443)
	dup_ip.items[1] = make_network_item(0x0A00_0264, 443)
	dup_refusal, bad_idx := request_batch_validate(&dup_ip)
	testing.expect_value(t, dup_refusal, Powerbox_Refusal.Duplicate_Item)
	testing.expect_value(t, bad_idx, u32(1))

	dup_host := make_valid_batch()
	dup_host.item_count = 2
	dup_host.items[0] = make_network_item(0, 443, .This_Run, "Example.COM")
	dup_host.items[1] = make_network_item(0, 443, .This_Run, "example.com")
	refusal, _ = request_batch_validate(&dup_host)
	testing.expect_value(t, refusal, Powerbox_Refusal.Duplicate_Item)

	dup_svc := make_valid_batch()
	dup_svc.item_count = 2
	dup_svc.items[0] = make_service_item("settings")
	dup_svc.items[1] = make_service_item("settings")
	refusal, _ = request_batch_validate(&dup_svc)
	testing.expect_value(t, refusal, Powerbox_Refusal.Duplicate_Item)

	dup_store := make_valid_batch()
	dup_store.item_count = 2
	dup_store.items[0] = make_store_item(.Read_Only, .This_Run, .Open)
	dup_store.items[1] = make_store_item(.Read_Only, .This_Run, .Open)
	refusal, _ = request_batch_validate(&dup_store)
	testing.expect_value(t, refusal, Powerbox_Refusal.Duplicate_Item)

	// Distinct store items (Read_Only Open vs Read_Write Save) are NOT duplicates.
	distinct_stores := make_valid_batch()
	distinct_stores.item_count = 2
	distinct_stores.items[0] = make_store_item(.Read_Only, .This_Run, .Open)
	distinct_stores.items[1] = make_store_item(.Read_Write, .This_Run, .Save)
	refusal, _ = request_batch_validate(&distinct_stores)
	testing.expect_value(t, refusal, Powerbox_Refusal.None)
}

@(test)
request_batch_validate_refuses_bad_words_hosts_reasons_and_boot_always :: proc(t: ^testing.T) {
	// Unknown kind words: 0 and max(u64).
	for bad_kind in ([?]u64{0, 99, max(u64)}) {
		batch := make_valid_batch()
		batch.items[0].kind_word = bad_kind
		refusal, _ := request_batch_validate(&batch)
		testing.expect_value(t, refusal, Powerbox_Refusal.Invalid_Kind)
	}

	// Unknown duration words: 0 and max(u64).
	for bad_dur in ([?]u64{0, 99, max(u64)}) {
		batch := make_valid_batch()
		batch.items[0].duration_word = bad_dur
		refusal, _ := request_batch_validate(&batch)
		testing.expect_value(t, refusal, Powerbox_Refusal.Invalid_Duration)
	}

	// Reason incompatible with kind (Serve on Store_Share).
	bad_reason := make_valid_batch()
	bad_reason.items[0] = make_store_item(.Read_Only, .This_Run, .Serve)
	refusal, _ := request_batch_validate(&bad_reason)
	testing.expect_value(t, refusal, Powerbox_Refusal.Invalid_Kind)

	// Always refused for Boot_Image module on every ordinary item kind.
	for item in ([?]Request_Item{
		make_network_item(0x0A00_0264, 443, .Always),
		make_store_item(.Read_Only, .Always, .Open),
		make_service_item("date", .Always),
	}) {
		boot_batch := make_valid_batch(.Boot_Image)
		boot_batch.items[0] = item
		r, _ := request_batch_validate(&boot_batch)
		testing.expect_value(t, r, Powerbox_Refusal.Always_Forbidden_For_Boot_Module)
	}

	// Always accepted for Disk_Module.
	disk_always := make_valid_batch(.Disk_Module)
	disk_always.items[0] = make_network_item(0x0A00_0264, 443, .Always)
	refusal, _ = request_batch_validate(&disk_always)
	testing.expect_value(t, refusal, Powerbox_Refusal.None)

	// Invalid hosts, ports, IPv4 addresses, UTF-8, and non-requestable services.
	bad_port_0 := make_valid_batch()
	bad_port_0.items[0].port = 0
	refusal, _ = request_batch_validate(&bad_port_0)
	testing.expect_value(t, refusal, Powerbox_Refusal.Invalid_Host)

	for reserved_port in ([?]u16{remote.LISTEN_PORT, remote_display.LISTEN_PORT}) {
		res_batch := make_valid_batch()
		res_batch.items[0].port = reserved_port
		r, _ := request_batch_validate(&res_batch)
		testing.expect_value(t, r, Powerbox_Refusal.Invalid_Host)
	}

	for bad_ip in ([?]u32{0, 0x7F00_0001, 0xA9FE_0102, 0xFFFF_FFFF}) {
		ip_batch := make_valid_batch()
		ip_batch.items[0].ipv4_address = bad_ip
		r, _ := request_batch_validate(&ip_batch)
		testing.expect_value(t, r, Powerbox_Refusal.Invalid_Host)
	}

	for bad_host in ([?]string{"-bad.com", "bad-.com", ".leading.dot", "trailing.dot.", "double..dot", "has space.com", "bad\nline.com", "semi;colon.com"}) {
		h_batch := make_valid_batch()
		set_host(&h_batch.items[0], bad_host)
		r, _ := request_batch_validate(&h_batch)
		testing.expectf(t, r == .Invalid_Host, "host %q must be refused", bad_host)
	}

	// Invalid UTF-8 bytes in host and in asker label.
	bad_utf8_host := make_valid_batch()
	bad_utf8_host.items[0].host_bytes[0] = 0xFF
	bad_utf8_host.items[0].host_bytes[1] = 0xFE
	bad_utf8_host.items[0].host_length = 2
	refusal, _ = request_batch_validate(&bad_utf8_host)
	testing.expect_value(t, refusal, Powerbox_Refusal.Invalid_Host)

	bad_utf8_label := make_valid_batch()
	bad_utf8_label.asker_label_bytes[0] = 0xC0
	bad_utf8_label.asker_label_bytes[1] = 0xAF
	bad_utf8_label.asker_label_length = 2
	refusal, _ = request_batch_validate(&bad_utf8_label)
	testing.expect_value(t, refusal, Powerbox_Refusal.Invalid_Host)

	// Non-requestable privileged services refused.
	for bad_svc in ([?]string{"", "root", "storage", "remote", "remote_display", "compositor", "tpm", "debugger"}) {
		s_batch := make_valid_batch()
		s_batch.items[0] = make_service_item(bad_svc)
		r, _ := request_batch_validate(&s_batch)
		testing.expectf(t, r == .Invalid_Host, "service %q must be refused", bad_svc)
	}

	// Plan_Difference rejects non-zero duration and mixing with ordinary items.
	plan_with_dur := make_valid_batch()
	plan_with_dur.items[0] = make_plan_item(0x77)
	plan_with_dur.items[0].duration_word = u64(Grant_Duration.This_Run)
	refusal, _ = request_batch_validate(&plan_with_dur)
	testing.expect_value(t, refusal, Powerbox_Refusal.Invalid_Duration)

	mixed_plan := make_valid_batch()
	mixed_plan.item_count = 2
	mixed_plan.items[0] = make_plan_item(0x77)
	mixed_plan.items[1] = make_service_item("date")
	refusal, _ = request_batch_validate(&mixed_plan)
	testing.expect_value(t, refusal, Powerbox_Refusal.Invalid_Kind)
}

@(test)
answer_record_validate_picker_bounds_remote_display_and_round_trip :: proc(t: ^testing.T) {
	TRUSTED_DISPLAY_SLOT :: u32(3)
	dialog := make_valid_dialog(.Disk_Module)
	refusal, _ := dialog_record_validate(&dialog)
	testing.expect_value(t, refusal, Powerbox_Refusal.None)

	// Build a completely valid trusted answer choosing picker candidate 1 (exact upper bound: count - 1).
	good_answer := Grant_Answer {
		dialog_serial            = dialog.dialog_serial,
		request_serial           = dialog.request_serial,
		dialog_record_hash       = dialog.record_hash,
		display_holder_slot      = TRUSTED_DISPLAY_SLOT,
		input_origin_word        = u64(Input_Origin.Local_Machine),
		shown_timestamp_ms       = 1000,
		input_press_timestamp_ms = 1300,
		answer_timestamp_ms      = 1320,
		item_count               = 3,
	}
	good_answer.items[0] = {
		decision_word = u64(Item_Decision.Granted),
		duration_word = u64(Grant_Duration.Always),
	}
	good_answer.items[1] = {
		decision_word       = u64(Item_Decision.Granted),
		duration_word       = u64(Grant_Duration.This_Run),
		picker_selected     = true,
		picker_index        = 1, // Upper valid bound (count == 2 -> indices 0, 1).
		picker_change_count = dialog.picker_change_count,
		picker_name_hash    = dialog.picker_candidates[1].name_hash,
	}
	good_answer.items[2] = {
		decision_word = u64(Item_Decision.Refused),
		duration_word = u64(Grant_Duration.None),
	}

	// Valid round-trip passes.
	refusal, _ = answer_record_validate(&dialog, &good_answer, TRUSTED_DISPLAY_SLOT)
	testing.expect_value(t, refusal, Powerbox_Refusal.None)

	// Remote_Display input MUST be refused as Untrusted_Answer.
	remote_ans := good_answer
	remote_ans.input_origin_word = u64(Input_Origin.Remote_Display)
	refusal, _ = answer_record_validate(&dialog, &remote_ans, TRUSTED_DISPLAY_SLOT)
	testing.expect_value(t, refusal, Powerbox_Refusal.Untrusted_Answer)

	// Unknown / zero input origin refused.
	for bad_origin in ([?]u64{0, 99, max(u64)}) {
		bad_o := good_answer
		bad_o.input_origin_word = bad_origin
		r, _ := answer_record_validate(&dialog, &bad_o, TRUSTED_DISPLAY_SLOT)
		testing.expect_value(t, r, Powerbox_Refusal.Untrusted_Answer)
	}

	// Wrong display holder slot or zero trusted slot refused.
	wrong_slot := good_answer
	wrong_slot.display_holder_slot = TRUSTED_DISPLAY_SLOT + 1
	refusal, _ = answer_record_validate(&dialog, &wrong_slot, TRUSTED_DISPLAY_SLOT)
	testing.expect_value(t, refusal, Powerbox_Refusal.Untrusted_Answer)
	refusal, _ = answer_record_validate(&dialog, &good_answer, 0)
	testing.expect_value(t, refusal, Powerbox_Refusal.Untrusted_Answer)

	// Request serial, dialog serial, and dialog record hash mismatches refused.
	bad_req_serial := good_answer
	bad_req_serial.request_serial += 1
	refusal, _ = answer_record_validate(&dialog, &bad_req_serial, TRUSTED_DISPLAY_SLOT)
	testing.expect_value(t, refusal, Powerbox_Refusal.Untrusted_Answer)

	bad_dlg_serial := good_answer
	bad_dlg_serial.dialog_serial += 1
	refusal, _ = answer_record_validate(&dialog, &bad_dlg_serial, TRUSTED_DISPLAY_SLOT)
	testing.expect_value(t, refusal, Powerbox_Refusal.Untrusted_Answer)

	bad_hash := good_answer
	bad_hash.dialog_record_hash[0] ~= 0x01
	refusal, _ = answer_record_validate(&dialog, &bad_hash, TRUSTED_DISPLAY_SLOT)
	testing.expect_value(t, refusal, Powerbox_Refusal.Untrusted_Answer)

	// Forged Held decision from Display refused.
	forged_held := good_answer
	forged_held.items[0].decision_word = u64(Item_Decision.Held)
	refusal, _ = answer_record_validate(&dialog, &forged_held, TRUSTED_DISPLAY_SLOT)
	testing.expect_value(t, refusal, Powerbox_Refusal.Untrusted_Answer)

	// Picker index one past bound (2) and max(u32) refused as Picker_Selection_Invalid.
	for bad_idx in ([?]u32{dialog.picker_candidate_count, dialog.picker_candidate_count + 5, max(u32)}) {
		bad_pick := good_answer
		bad_pick.items[1].picker_index = bad_idx
		r, item_idx := answer_record_validate(&dialog, &bad_pick, TRUSTED_DISPLAY_SLOT)
		testing.expect_value(t, r, Powerbox_Refusal.Picker_Selection_Invalid)
		testing.expect_value(t, item_idx, u32(1))
	}

	// Picker change count mismatch and tampered name hash refused.
	bad_change := good_answer
	bad_change.items[1].picker_change_count += 1
	refusal, _ = answer_record_validate(&dialog, &bad_change, TRUSTED_DISPLAY_SLOT)
	testing.expect_value(t, refusal, Powerbox_Refusal.Picker_Selection_Invalid)

	bad_name_hash := good_answer
	bad_name_hash.items[1].picker_name_hash[3] ~= 0xFF
	refusal, _ = answer_record_validate(&dialog, &bad_name_hash, TRUSTED_DISPLAY_SLOT)
	testing.expect_value(t, refusal, Powerbox_Refusal.Picker_Selection_Invalid)

	// Picker unselected on granted Store_Share refused.
	unselected := good_answer
	unselected.items[1].picker_selected = false
	refusal, _ = answer_record_validate(&dialog, &unselected, TRUSTED_DISPLAY_SLOT)
	testing.expect_value(t, refusal, Powerbox_Refusal.Picker_Selection_Invalid)

	// Picker selected on non-Store_Share refused.
	extra_pick := good_answer
	extra_pick.items[0].picker_selected = true
	refusal, _ = answer_record_validate(&dialog, &extra_pick, TRUSTED_DISPLAY_SLOT)
	testing.expect_value(t, refusal, Powerbox_Refusal.Picker_Selection_Invalid)

	// Boot module dialog refuses Always even in Display answer.
	boot_dialog := make_valid_dialog(.Boot_Image)
	boot_answer := good_answer
	boot_answer.dialog_record_hash = boot_dialog.record_hash
	boot_answer.items[0].duration_word = u64(Grant_Duration.Always)
	boot_refusal, bad_item := answer_record_validate(&boot_dialog, &boot_answer, TRUSTED_DISPLAY_SLOT)
	testing.expect_value(t, boot_refusal, Powerbox_Refusal.Always_Forbidden_For_Boot_Module)
	testing.expect_value(t, bad_item, u32(0))
}

@(test)
plan_difference_dialog_enforces_whole_accept_or_refuse :: proc(t: ^testing.T) {
	TRUSTED_DISPLAY_SLOT :: u32(3)
	dialog := Dialog_Record {
		action_word           = u64(Dialog_Action.Show_Plan_Difference),
		dialog_serial         = 88,
		request_serial        = 199,
		session_principal     = 1,
		asker_process_slot    = 4,
		asker_module_origin   = u64(Module_Origin.Boot_Image),
		asker_module_hash     = make_hash(0x99),
		allow_per_item_ticks  = false,
		allow_duration_choice = false,
		allow_always_duration = false,
		item_count            = 1,
	}
	set_label(&dialog.asker_label_bytes, &dialog.asker_label_length, "plans")
	dialog.items[0] = make_plan_item(0xAB)
	testing.expect_value(t, dialog_record_seal(&dialog), Powerbox_Refusal.None)

	// Enabling per-item ticks or duration choice on Show_Plan_Difference is refused.
	bad_ticks := dialog
	bad_ticks.allow_per_item_ticks = true
	testing.expect_value(t, dialog_record_seal(&bad_ticks), Powerbox_Refusal.Invalid_Duration)

	bad_dur_flag := dialog
	bad_dur_flag.allow_duration_choice = true
	testing.expect_value(t, dialog_record_seal(&bad_dur_flag), Powerbox_Refusal.Invalid_Duration)

	// Whole accept passes.
	accept := Grant_Answer {
		dialog_serial            = dialog.dialog_serial,
		request_serial           = dialog.request_serial,
		dialog_record_hash       = dialog.record_hash,
		display_holder_slot      = TRUSTED_DISPLAY_SLOT,
		input_origin_word        = u64(Input_Origin.Local_Machine),
		shown_timestamp_ms       = 2000,
		input_press_timestamp_ms = 2500,
		answer_timestamp_ms      = 2510,
		whole_plan_accepted      = true,
		item_count               = 1,
	}
	accept.items[0] = {decision_word = u64(Item_Decision.Granted), duration_word = u64(Grant_Duration.None)}
	refusal, _ := answer_record_validate(&dialog, &accept, TRUSTED_DISPLAY_SLOT)
	testing.expect_value(t, refusal, Powerbox_Refusal.None)

	// Whole refuse passes.
	refuse := accept
	refuse.whole_plan_accepted = false
	refuse.items[0].decision_word = u64(Item_Decision.Refused)
	refusal, _ = answer_record_validate(&dialog, &refuse, TRUSTED_DISPLAY_SLOT)
	testing.expect_value(t, refusal, Powerbox_Refusal.None)

	// Mismatched partial decision (whole_plan_accepted=true, item Refused) is refused.
	partial := accept
	partial.items[0].decision_word = u64(Item_Decision.Refused)
	refusal, _ = answer_record_validate(&dialog, &partial, TRUSTED_DISPLAY_SLOT)
	testing.expect_value(t, refusal, Powerbox_Refusal.Untrusted_Answer)

	// Non-zero duration on Show_Plan_Difference answer is refused.
	with_dur := accept
	with_dur.items[0].duration_word = u64(Grant_Duration.This_Run)
	refusal, _ = answer_record_validate(&dialog, &with_dur, TRUSTED_DISPLAY_SLOT)
	testing.expect_value(t, refusal, Powerbox_Refusal.Invalid_Duration)
}

// The arm time of a door: the contract time under it and at 0, the time of
// the principal between, the most past it and at the largest word; an act
// at the show, one millisecond early, at the arm time, before the show,
// and with a show near the largest time.
@(test)
the_arm_time_of_a_door_is_the_principal_s_never_under_the_contract :: proc(t: ^testing.T) {
	testing.expect_value(t, consent_arm_milliseconds(0), CONSENT_ARM_MILLISECONDS)
	testing.expect_value(t, consent_arm_milliseconds(CONSENT_ARM_MILLISECONDS - 1), CONSENT_ARM_MILLISECONDS)
	testing.expect_value(t, consent_arm_milliseconds(2000), u64(2000))
	testing.expect_value(t, consent_arm_milliseconds(CONSENT_ARM_MILLISECONDS_MOST), CONSENT_ARM_MILLISECONDS_MOST)
	testing.expect_value(t, consent_arm_milliseconds(CONSENT_ARM_MILLISECONDS_MOST + 1), CONSENT_ARM_MILLISECONDS_MOST)
	testing.expect_value(t, consent_arm_milliseconds(max(u64)), CONSENT_ARM_MILLISECONDS_MOST)
	testing.expect(t, !consent_armed(1000, 1000, 2000))
	testing.expect(t, !consent_armed(1000, 2999, 2000))
	testing.expect(t, consent_armed(1000, 3000, 2000))
	testing.expect(t, !consent_armed(1000, 999, 0))
	testing.expect(t, consent_armed(1000, 1000 + CONSENT_ARM_MILLISECONDS, 0))
	testing.expect(t, !consent_armed(max(u64) - 10, max(u64), 0))
	testing.expect(t, consent_armed(0, max(u64), 0))
}

// An answer that a display makes carries the arm time that it applied:
// the contract time for 0 and under it, the time of the principal, the most
// for a word past it; the rest of the answer names the dialog.
@(test)
an_answer_carries_the_arm_time_of_the_principal :: proc(t: ^testing.T) {
	dialog := Dialog_Record{dialog_serial = 7, request_serial = 9, item_count = 2}
	for item in ([?][2]u64{{0, CONSENT_ARM_MILLISECONDS}, {CONSENT_ARM_MILLISECONDS - 1, CONSENT_ARM_MILLISECONDS}, {2000, 2000}, {CONSENT_ARM_MILLISECONDS_MOST + 1, CONSENT_ARM_MILLISECONDS_MOST}, {max(u64), CONSENT_ARM_MILLISECONDS_MOST}}) {
		answer := grant_answer_make(&dialog, 3, .Local_Machine, 100, 700, 800, item[0])
		testing.expectf(t, answer.arm_milliseconds == item[1], "%d gives %d", item[0], answer.arm_milliseconds)
		testing.expect(t, answer.dialog_serial == 7 && answer.request_serial == 9 && answer.item_count == 2 && answer.display_holder_slot == 3 && answer.shown_timestamp_ms == 100 && answer.input_press_timestamp_ms == 700 && answer.answer_timestamp_ms == 800)
	}
}
