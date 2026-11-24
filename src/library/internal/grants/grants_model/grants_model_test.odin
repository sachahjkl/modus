#+build !freestanding
package grants_model

import "core:testing"
import "modus:contract/root_ring"
import "modus:contract/wide_grants"
import "modus:disk_process"
import "modus:system"

@(test)
border_refuses_unknown_bits_and_handles_empty_rows :: proc(t: ^testing.T) {
	snap: Snapshot

	// Empty process name is skipped without failing total.
	total, added := snapshot_add_process_completion(&snap, {6 = 3})
	testing.expect_value(t, total, u64(3))
	testing.expect(t, !added)
	testing.expect_value(t, snap.process_count, 0)

	// Unknown Root_Grant bit in granted or revoked is refused.
	packed := system.name_pack("notes")
	bad_bit := u64(1) << len(system.Root_Grant)
	_, added_bad_grant := snapshot_add_process_completion(&snap, {packed[0], packed[1], packed[2], packed[3], bad_bit, 0, 1})
	testing.expect(t, !added_bad_grant)
	_, added_bad_revoked := snapshot_add_process_completion(&snap, {packed[0], packed[1], packed[2], packed[3], 0, bad_bit, 1})
	testing.expect(t, !added_bad_revoked)
	testing.expect_value(t, snap.process_count, 0)

	// Valid process row succeeds.
	granted := transmute(u64)(system.Root_Grants{.Store, .Log})
	revoked := transmute(u64)(system.Root_Grants{.Network})
	total, added = snapshot_add_process_completion(&snap, {packed[0], packed[1], packed[2], packed[3], granted, revoked, 1})
	testing.expect(t, added && total == 1)
	testing.expect_value(t, snap.process_count, 1)
	testing.expect_value(t, process_row_name(&snap.processes[0]), "notes")
	testing.expect(t, .Store in snap.processes[0].granted && .Network in snap.processes[0].revoked)

	// Wide grant border: serial 0 clears cleanly; unknown scope or zero key refused fail-closed.
	testing.expect(t, snapshot_set_wide_grant_completion(&snap, {}))
	testing.expect(t, !snap.wide_grant.active)
	testing.expect(t, !snapshot_set_wide_grant_completion(&snap, {0 = 1, 4 = 0, 5 = 9000, 6 = 7}))
	testing.expect(t, !snap.wide_grant.active)
	testing.expect(t, !snapshot_set_wide_grant_completion(&snap, {0 = 1, 4 = 1 << 20, 5 = 9000, 6 = 7}))
	testing.expect(t, !snap.wide_grant.active)
	testing.expect(t, !snapshot_set_wide_grant_completion(&snap, {4 = wide_grants.wide_authorities_to_word({.View_Screen}), 5 = 9000, 6 = 7}))
	testing.expect(t, !snap.wide_grant.active)
	testing.expect(t, snapshot_set_wide_grant_completion(&snap, {0 = 0xAABB, 4 = wide_grants.wide_authorities_to_word({.View_Screen, .Send_Input}), 5 = 125_000, 6 = 9}))
	testing.expect(t, snap.wide_grant.active && snap.wide_grant.grant_serial == 9)
	testing.expect(t, .View_Screen in snap.wide_grant.scopes && .Send_Input in snap.wide_grant.scopes)

	// Disk grant border: empty nickname, unknown grant bit, bad meta refused.
	_, disk_added := snapshot_add_disk_completion(&snap, {6 = 2})
	testing.expect(t, !disk_added)
	nick := disk_process.name_pack("visitor")
	_, disk_bad_grant := snapshot_add_disk_completion(&snap, {nick[0], nick[1], nick[2], 0x1122, 1 << 4, 0, 1})
	testing.expect(t, !disk_bad_grant)
	_, disk_bad_meta := snapshot_add_disk_completion(&snap, {nick[0], nick[1], nick[2], 0x1122, u64(transmute(u8)(disk_process.Disk_Grants{.Store})), 99, 1})
	testing.expect(t, !disk_bad_meta)
	meta := root_ring.disk_grant_meta_pack(.Persist, false, .Kept_By_Passphrase)
	_, disk_ok := snapshot_add_disk_completion(&snap, {nick[0], nick[1], nick[2], 0x1122, u64(transmute(u8)(disk_process.Disk_Grants{.Store})), meta, 1})
	testing.expect(t, disk_ok && snap.disk_count == 1)
	testing.expect_value(t, disk_row_nickname(&snap.disks[0]), "visitor")
	testing.expect_value(t, disk_persistence_label(&snap.disks[0]), "kept on disk")
}

@(test)
overflow_tracks_truncated_counts_without_crashing :: proc(t: ^testing.T) {
	snap: Snapshot
	packed := system.name_pack("proc")
	granted := transmute(u64)(system.Root_Grants{.Store})
	for i in 0 ..< PROCESS_ROW_CAPACITY + 5 {
		_, added := snapshot_add_process_completion(&snap, {packed[0], packed[1], packed[2], packed[3], granted, 0, u64(PROCESS_ROW_CAPACITY + 5)})
		if i < PROCESS_ROW_CAPACITY {
			testing.expect(t, added)
		} else {
			testing.expect(t, !added)
		}
	}
	testing.expect_value(t, snap.process_count, PROCESS_ROW_CAPACITY)
	testing.expect_value(t, snap.processes_truncated, u64(5))

	nick := disk_process.name_pack("diskapp")
	meta := root_ring.disk_grant_meta_pack(.Global, true, .Kept_By_Machine_Passphrase)
	store_bits := u64(transmute(u8)(disk_process.Disk_Grants{.Store}))
	for i in 0 ..< DISK_ROW_CAPACITY + 3 {
		_, added := snapshot_add_disk_completion(&snap, {nick[0], nick[1], nick[2], u64(i + 1), store_bits, meta, u64(DISK_ROW_CAPACITY + 3)})
		if i < DISK_ROW_CAPACITY {
			testing.expect(t, added)
		} else {
			testing.expect(t, !added)
		}
	}
	testing.expect_value(t, snap.disk_count, DISK_ROW_CAPACITY)
	testing.expect_value(t, snap.disks_truncated, u64(3))

	list: Display_List
	display_list_build(&list, &snap)
	testing.expect(t, list.count > 0 && list.count <= DISPLAY_ROW_CAPACITY)
	trunc_count := 0
	for row in list.rows[:list.count] {
		if row.kind == .Truncation_Notice {
			trunc_count += 1
		}
	}
	testing.expect_value(t, trunc_count, 2)
}

@(test)
confirm_state_refuses_unrevocable_targets_and_reconciles :: proc(t: ^testing.T) {
	snap: Snapshot
	packed := system.name_pack("console")
	_, _ = snapshot_add_process_completion(&snap, {
		packed[0], packed[1], packed[2], packed[3],
		transmute(u64)(system.Root_Grants{.Store}),
		transmute(u64)(system.Root_Grants{.Palette}),
		1,
	})
	nick_store := disk_process.name_pack("app_a")
	nick_policy := disk_process.name_pack("policy_a")
	meta := root_ring.disk_grant_meta_pack(.Global, false, .Until_Stop)
	_, _ = snapshot_add_disk_completion(&snap, {nick_store[0], nick_store[1], nick_store[2], 1, u64(transmute(u8)(disk_process.Disk_Grants{.Store})), meta, 2})
	_, _ = snapshot_add_disk_completion(&snap, {nick_policy[0], nick_policy[1], nick_policy[2], 2, u64(transmute(u8)(disk_process.Disk_Grants{.Start_Policy})), meta, 2})

	confirm: Confirm_State
	// Refusal cases: inactive wide grant, revoked process grant, out-of-range index, Start_Policy disk row.
	testing.expect(t, !confirm_arm(&confirm, &snap, {kind = .Wide_Grant}))
	testing.expect(t, !confirm_arm(&confirm, &snap, {kind = .Process_Grant, process_index = 0, root_grant = .Palette}))
	testing.expect(t, !confirm_arm(&confirm, &snap, {kind = .Process_Grant, process_index = -1, root_grant = .Store}))
	testing.expect(t, !confirm_arm(&confirm, &snap, {kind = .Process_Grant, process_index = 1, root_grant = .Store}))
	testing.expect(t, !confirm_arm(&confirm, &snap, {kind = .Disk_Grant, disk_index = 1, disk_grant = .Start_Policy}))
	testing.expect(t, !confirm.armed)

	// Valid arm for held process grant and reconcile when grant disappears.
	target := Action_Target{kind = .Process_Grant, process_index = 0, root_grant = .Store}
	testing.expect(t, confirm_arm(&confirm, &snap, target))
	testing.expect(t, confirm_matches(&confirm, target))
	snap.processes[0].granted = {}
	confirm_reconcile(&confirm, &snap)
	testing.expect(t, !confirm.armed)

	// Valid arm for disk .Store grant and explicit cancel.
	disk_target := Action_Target{kind = .Disk_Grant, disk_index = 0, disk_grant = .Store}
	testing.expect(t, confirm_arm(&confirm, &snap, disk_target))
	testing.expect(t, confirm_matches(&confirm, disk_target))
	confirm_cancel(&confirm)
	testing.expect(t, !confirm.armed)
}

@(test)
display_list_empty_and_formatting_helpers :: proc(t: ^testing.T) {
	empty_snap: Snapshot
	list: Display_List
	display_list_build(&list, &empty_snap)
	// 3 section headings + 3 empty notices = 6 rows.
	testing.expect_value(t, list.count, 6)

	hex_buf: [16]u8
	testing.expect_value(t, format_hex_prefix(&hex_buf, 0x0807060504030201), "0102030405060708")

	scope_buf: [32]u8
	testing.expect_value(t, format_wide_scopes(&scope_buf, {.View_Screen}), "view screen")
	testing.expect_value(t, format_wide_scopes(&scope_buf, {.View_Screen, .Send_Input}), "view screen, send input")

	time_buf: [24]u8
	testing.expect_value(t, format_remaining_time(&time_buf, 1000, 1000), "ending")
	testing.expect_value(t, format_remaining_time(&time_buf, 5000, 1000), "ending")
	testing.expect_value(t, format_remaining_time(&time_buf, 1000, 42_500), "42 s left")
	testing.expect_value(t, format_remaining_time(&time_buf, 1000, 121_000), "2 min left")
}

@(test)
zero_grant_disk_row_renders_no_grant_and_is_not_removable :: proc(t: ^testing.T) {
	snap: Snapshot
	nick := disk_process.name_pack("visitor")
	meta := root_ring.disk_grant_meta_pack(.Persist, false, .Kept_By_Passphrase)
	_, added := snapshot_add_disk_completion(&snap, {nick[0], nick[1], nick[2], 0xAABB, 0, meta, 1})
	testing.expect(t, added && snap.disk_count == 1)
	testing.expect_value(t, snap.disks[0].grants, disk_process.Disk_Grants{})

	list: Display_List
	display_list_build(&list, &snap)
	found := false
	for row in list.rows[:list.count] {
		if row.kind == .Disk_Grant_Item {
			found = true
			testing.expect(t, !row.has_grant)
			testing.expect(t, !row.removable)
			testing.expect_value(t, disk_row_grant_label(row), "no grant")
		}
	}
	testing.expect(t, found)

	confirm: Confirm_State
	testing.expect(t, !confirm_arm(&confirm, &snap, {kind = .Disk_Grant, disk_index = 0, disk_grant = .Store}))
	testing.expect(t, !confirm.armed)
}
