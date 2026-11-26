#+build !freestanding
#+build !modus
package powerbox

import "core:testing"
import "modus:contract/blake3"

@(private = "file")
test_text_bytes :: proc(label: string) -> []u8 {
	return transmute([]u8)label
}

@(private = "file")
test_blake3 :: proc(label: string) -> blake3.Hash {
	raw := transmute([]u8)label
	return blake3.hash(raw)
}

@(test)
test_persistence_and_refusal_border_parsers :: proc(t: ^testing.T) {
	// Powerbox_Choice_Persistence refuses 0, one past max, max(u64).
	if _, ok := powerbox_choice_persistence_from_word(0); ok {
		testing.fail_now(t, "powerbox_choice_persistence_from_word accepted 0")
	}
	if _, ok := powerbox_choice_persistence_from_word(u64(max(Powerbox_Choice_Persistence)) + 1); ok {
		testing.fail_now(t, "powerbox_choice_persistence_from_word accepted one past max")
	}
	if _, ok := powerbox_choice_persistence_from_word(max(u64)); ok {
		testing.fail_now(t, "powerbox_choice_persistence_from_word accepted max(u64)")
	}
	for expected in Powerbox_Choice_Persistence {
		if expected == .None {
			continue
		}
		parsed, ok := powerbox_choice_persistence_from_word(u64(expected))
		testing.expect(t, ok && parsed == expected)
	}

	// Powerbox_Persistent_Refusal refuses one past max and max(u64).
	if _, ok := powerbox_persistent_refusal_from_word(u64(max(Powerbox_Persistent_Refusal)) + 1); ok {
		testing.fail_now(t, "powerbox_persistent_refusal_from_word accepted one past max")
	}
	if _, ok := powerbox_persistent_refusal_from_word(max(u64)); ok {
		testing.fail_now(t, "powerbox_persistent_refusal_from_word accepted max(u64)")
	}
	for expected in Powerbox_Persistent_Refusal {
		parsed, ok := powerbox_persistent_refusal_from_word(u64(expected))
		testing.expect(t, ok && parsed == expected)
	}
}

@(test)
test_persistent_module_grant_refuses_boot_modules_zero_hashes_and_bad_edges :: proc(t: ^testing.T) {
	table: Persistent_Grant_Table
	mod_hash := test_blake3("disk-module-v1")
	target_hash := test_blake3("store:notes")
	store_rw := u64(Store_Access_Mode.Read_Write)
	disk_origin := u64(Module_Origin.Disk_Module)
	boot_origin := u64(Module_Origin.Boot_Image)

	// Nil table refused.
	testing.expect_value(
		t,
		persistent_grant_record(nil, disk_origin, mod_hash, u64(Request_Item_Kind.Store_Share), target_hash, store_rw, u64(Powerbox_Choice_Persistence.Always_For_Module)),
		Powerbox_Persistent_Refusal.Nil_Input,
	)

	// Boot-image modules and zero/unknown origins refused.
	testing.expect_value(
		t,
		persistent_grant_record(&table, boot_origin, mod_hash, u64(Request_Item_Kind.Store_Share), target_hash, store_rw, u64(Powerbox_Choice_Persistence.Always_For_Module)),
		Powerbox_Persistent_Refusal.Boot_Module_Forbidden,
	)
	testing.expect_value(
		t,
		persistent_grant_record(&table, boot_origin, mod_hash, u64(Request_Item_Kind.Store_Share), target_hash, 0, u64(Powerbox_Choice_Persistence.Never_Ask_Again)),
		Powerbox_Persistent_Refusal.Boot_Module_Forbidden,
	)
	testing.expect_value(
		t,
		persistent_grant_record(&table, 0, mod_hash, u64(Request_Item_Kind.Store_Share), target_hash, store_rw, u64(Powerbox_Choice_Persistence.Always_For_Module)),
		Powerbox_Persistent_Refusal.Boot_Module_Forbidden,
	)

	// Zero module hash and zero target hash refused.
	testing.expect_value(
		t,
		persistent_grant_record(&table, disk_origin, {}, u64(Request_Item_Kind.Store_Share), target_hash, store_rw, u64(Powerbox_Choice_Persistence.Always_For_Module)),
		Powerbox_Persistent_Refusal.Zero_Module_Hash,
	)
	testing.expect_value(
		t,
		persistent_grant_record(&table, disk_origin, mod_hash, u64(Request_Item_Kind.Store_Share), {}, store_rw, u64(Powerbox_Choice_Persistence.Always_For_Module)),
		Powerbox_Persistent_Refusal.Zero_Target_Hash,
	)

	// Non-persistent choices (Once, This_Run, None, unknown) refused.
	for bad_p in ([?]u64{0, u64(Powerbox_Choice_Persistence.Once), u64(Powerbox_Choice_Persistence.This_Run), 99}) {
		testing.expect_value(
			t,
			persistent_grant_record(&table, disk_origin, mod_hash, u64(Request_Item_Kind.Store_Share), target_hash, store_rw, bad_p),
			Powerbox_Persistent_Refusal.Bad_Persistence,
		)
	}

	// Plan_Difference and zero item kind refused.
	testing.expect_value(
		t,
		persistent_grant_record(&table, disk_origin, mod_hash, u64(Request_Item_Kind.Plan_Difference), target_hash, 1, u64(Powerbox_Choice_Persistence.Always_For_Module)),
		Powerbox_Persistent_Refusal.Bad_Item_Kind,
	)
	testing.expect_value(
		t,
		persistent_grant_record(&table, disk_origin, mod_hash, 0, target_hash, store_rw, u64(Powerbox_Choice_Persistence.Always_For_Module)),
		Powerbox_Persistent_Refusal.Bad_Item_Kind,
	)

	// Bad rights: 0 for Always_For_Module, non-zero for Never_Ask_Again.
	testing.expect_value(
		t,
		persistent_grant_record(&table, disk_origin, mod_hash, u64(Request_Item_Kind.Store_Share), target_hash, 0, u64(Powerbox_Choice_Persistence.Always_For_Module)),
		Powerbox_Persistent_Refusal.Bad_Rights,
	)
	testing.expect_value(
		t,
		persistent_grant_record(&table, disk_origin, mod_hash, u64(Request_Item_Kind.Store_Share), target_hash, store_rw, u64(Powerbox_Choice_Persistence.Never_Ask_Again)),
		Powerbox_Persistent_Refusal.Bad_Rights,
	)
	testing.expect_value(t, table.count, u32(0))

	// Accepted record, duplicate refusal, lookup, and boot-origin lookup refusal.
	testing.expect_value(
		t,
		persistent_grant_record(&table, disk_origin, mod_hash, u64(Request_Item_Kind.Store_Share), target_hash, store_rw, u64(Powerbox_Choice_Persistence.Always_For_Module)),
		Powerbox_Persistent_Refusal.None,
	)
	testing.expect_value(t, table.count, u32(1))

	testing.expect_value(
		t,
		persistent_grant_record(&table, disk_origin, mod_hash, u64(Request_Item_Kind.Store_Share), target_hash, store_rw, u64(Powerbox_Choice_Persistence.Always_For_Module)),
		Powerbox_Persistent_Refusal.Duplicate_Entry,
	)

	_, boot_found := persistent_grant_lookup(&table, boot_origin, mod_hash, u64(Request_Item_Kind.Store_Share), target_hash)
	testing.expect(t, !boot_found)

	found_entry, found := persistent_grant_lookup(&table, disk_origin, mod_hash, u64(Request_Item_Kind.Store_Share), target_hash)
	testing.expect(t, found)
	testing.expect_value(t, found_entry.persistence, Powerbox_Choice_Persistence.Always_For_Module)
	testing.expect_value(t, found_entry.rights_word, store_rw)

	// Permanent refusal entry for a second target of the same module.
	net_target := test_blake3("endpoint:example.org:443")
	testing.expect_value(
		t,
		persistent_grant_record(&table, disk_origin, mod_hash, u64(Request_Item_Kind.Network_Endpoint), net_target, 0, u64(Powerbox_Choice_Persistence.Never_Ask_Again)),
		Powerbox_Persistent_Refusal.None,
	)
	testing.expect_value(t, table.count, u32(2))

	// Single revocation and whole-module revocation.
	testing.expect_value(
		t,
		persistent_grant_revoke(&table, mod_hash, u64(Request_Item_Kind.Store_Share), target_hash),
		Powerbox_Persistent_Refusal.None,
	)
	testing.expect_value(t, table.count, u32(1))
	testing.expect_value(
		t,
		persistent_grant_revoke(&table, mod_hash, u64(Request_Item_Kind.Store_Share), target_hash),
		Powerbox_Persistent_Refusal.Not_Found,
	)

	removed, rev_refusal := persistent_grant_revoke_module(&table, mod_hash)
	testing.expect_value(t, rev_refusal, Powerbox_Persistent_Refusal.None)
	testing.expect_value(t, removed, u32(1))
	testing.expect_value(t, table.count, u32(0))
}

@(test)
test_persistent_grant_table_capacity_bound :: proc(t: ^testing.T) {
	table: Persistent_Grant_Table
	mod_hash := test_blake3("disk-module-cap")
	disk_origin := u64(Module_Origin.Disk_Module)
	for index in 0 ..< PERSISTENT_GRANT_TABLE_CAPACITY {
		target := test_blake3("target")
		target[0] = u8(index)
		target[1] = u8(index >> 8)
		refusal := persistent_grant_record(&table, disk_origin, mod_hash, u64(Request_Item_Kind.Service_Connection), target, 1, u64(Powerbox_Choice_Persistence.Always_For_Module))
		testing.expect_value(t, refusal, Powerbox_Persistent_Refusal.None)
	}
	overflow_target := test_blake3("overflow")
	testing.expect_value(
		t,
		persistent_grant_record(&table, disk_origin, mod_hash, u64(Request_Item_Kind.Service_Connection), overflow_target, 1, u64(Powerbox_Choice_Persistence.Always_For_Module)),
		Powerbox_Persistent_Refusal.Table_Full,
	)
}

@(test)
test_requestable_service_validation_and_lookup :: proc(t: ^testing.T) {
	// Empty and non-identifier service names refused.
	_, empty_refusal := requestable_service_build("", true)
	testing.expect_value(t, empty_refusal, Powerbox_Persistent_Refusal.Bad_Service_Name)

	_, bad_chars := requestable_service_build("bad service!", true)
	testing.expect_value(t, bad_chars, Powerbox_Persistent_Refusal.Bad_Service_Name)

	// Wide service and acts-for-principal service refused.
	wide_entry, ok_refusal := requestable_service_build("display", true)
	testing.expect_value(t, ok_refusal, Powerbox_Persistent_Refusal.None)
	wide_entry.is_wide_service = true
	testing.expect_value(t, requestable_service_validate(&wide_entry), Powerbox_Persistent_Refusal.Wide_Service_Forbidden)

	principal_entry, p_refusal := requestable_service_build("storage", true)
	testing.expect_value(t, p_refusal, Powerbox_Persistent_Refusal.None)
	principal_entry.acts_for_principal = true
	testing.expect_value(t, requestable_service_validate(&principal_entry), Powerbox_Persistent_Refusal.Acts_For_Principal_Forbidden)

	// Duplicate service in table refused.
	sound_entry, _ := requestable_service_build("sound", true)
	date_entry, _ := requestable_service_build("date", false)
	dup_table := [?]Requestable_Service_Entry{sound_entry, date_entry, sound_entry}
	dup_refusal, dup_idx := requestable_service_table_validate(dup_table[:])
	testing.expect_value(t, dup_refusal, Powerbox_Persistent_Refusal.Duplicate_Service)
	testing.expect_value(t, dup_idx, u32(2))

	// Valid allowlist lookup succeeds and skips tampered wide entry.
	valid_table := [?]Requestable_Service_Entry{sound_entry, date_entry, wide_entry}
	found_entry, found := requestable_service_table_find(valid_table[:], test_text_bytes("sound"))
	testing.expect(t, found && found_entry.requires_consent)
	_, wide_found := requestable_service_table_find(valid_table[:], test_text_bytes("display"))
	testing.expect(t, !wide_found)
}

@(test)
test_console_missing_handle_request_enforces_single_call_edges :: proc(t: ^testing.T) {
	service := test_text_bytes("storage")
	export_name := test_text_bytes("read_object")
	store_ro := u64(Store_Access_Mode.Read_Only)
	once_word := u64(Powerbox_Choice_Persistence.Once)

	// Zero request serial refused.
	_, r := console_missing_handle_request(0, 3, 1, service, export_name, 1, u64(Request_Item_Kind.Store_Share), store_ro, once_word)
	testing.expect_value(t, r, Powerbox_Persistent_Refusal.Zero_Request_Serial)

	// Zero console process slot refused.
	_, r = console_missing_handle_request(1, 0, 1, service, export_name, 1, u64(Request_Item_Kind.Store_Share), store_ro, once_word)
	testing.expect_value(t, r, Powerbox_Persistent_Refusal.Zero_Asker_Slot)

	// Bad service name and bad export name refused.
	_, r = console_missing_handle_request(1, 3, 1, nil, export_name, 1, u64(Request_Item_Kind.Store_Share), store_ro, once_word)
	testing.expect_value(t, r, Powerbox_Persistent_Refusal.Bad_Service_Name)

	_, r = console_missing_handle_request(1, 3, 1, service, test_text_bytes("bad export"), 1, u64(Request_Item_Kind.Store_Share), store_ro, once_word)
	testing.expect_value(t, r, Powerbox_Persistent_Refusal.Bad_Export_Name)

	// Zero parameter index refused.
	_, r = console_missing_handle_request(1, 3, 1, service, export_name, 0, u64(Request_Item_Kind.Store_Share), store_ro, once_word)
	testing.expect_value(t, r, Powerbox_Persistent_Refusal.Zero_Parameter_Index)

	// Plan_Difference and bad rights refused.
	_, r = console_missing_handle_request(1, 3, 1, service, export_name, 1, u64(Request_Item_Kind.Plan_Difference), 1, once_word)
	testing.expect_value(t, r, Powerbox_Persistent_Refusal.Bad_Item_Kind)

	_, r = console_missing_handle_request(1, 3, 1, service, export_name, 1, u64(Request_Item_Kind.Store_Share), 0, once_word)
	testing.expect_value(t, r, Powerbox_Persistent_Refusal.Bad_Rights)

	// Any persistence wider than Once refused.
	for wider in ([?]Powerbox_Choice_Persistence{.This_Run, .Always_For_Module, .Never_Ask_Again}) {
		_, r = console_missing_handle_request(1, 3, 1, service, export_name, 1, u64(Request_Item_Kind.Store_Share), store_ro, u64(wider))
		testing.expect_value(t, r, Powerbox_Persistent_Refusal.Non_Once_Console_Ask)
	}

	// Accepted single-call console handle request.
	ask, ok_r := console_missing_handle_request(42, 3, 1, service, export_name, 2, u64(Request_Item_Kind.Store_Share), store_ro, once_word)
	testing.expect_value(t, ok_r, Powerbox_Persistent_Refusal.None)
	testing.expect_value(t, ask.request_serial, u64(42))
	testing.expect_value(t, ask.console_process_slot, u32(3))
	testing.expect_value(t, ask.parameter_index, u32(2))
	testing.expect_value(t, ask.item_kind, Request_Item_Kind.Store_Share)
	testing.expect_value(t, ask.persistence, Powerbox_Choice_Persistence.Once)
	testing.expect(t, string(ask.service_name_bytes[:ask.service_name_length]) == "storage")
	testing.expect(t, string(ask.export_name_bytes[:ask.export_name_length]) == "read_object")
}
