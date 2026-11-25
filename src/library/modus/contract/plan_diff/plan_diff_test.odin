#+build !freestanding
package plan_diff

import "core:fmt"
import "core:testing"
import "modus:contract/blake3"

@(private = "file")
make_hash :: proc(tag: u8) -> blake3.Hash {
	h: blake3.Hash
	h[0] = tag
	h[31] = tag ~ 0xA5
	return h
}

@(test)
plan_diff_border_word_refusals :: proc(t: ^testing.T) {
	// Unknown words are refused at every enum and bitset border.
	_, ok := plan_grant_kind_of_word(0)
	testing.expect_value(t, ok, false)
	_, ok = plan_grant_kind_of_word(99)
	testing.expect_value(t, ok, false)
	kind, kind_ok := plan_grant_kind_of_word(u64(Plan_Grant_Kind.Store_Share))
	testing.expect_value(t, kind_ok, true)
	testing.expect_value(t, kind, Plan_Grant_Kind.Store_Share)

	_, ok = grant_change_kind_of_word(5)
	testing.expect_value(t, ok, false)
	ch, ch_ok := grant_change_kind_of_word(u64(Grant_Change_Kind.Widened))
	testing.expect_value(t, ch_ok, true)
	testing.expect_value(t, ch, Grant_Change_Kind.Widened)

	_, ok = grant_right_set_of_word(1 << 7)
	testing.expect_value(t, ok, false)
	_, ok = grant_right_set_of_word(~u64(0))
	testing.expect_value(t, ok, false)
	rights, r_ok := grant_right_set_of_word(u64(transmute(u16)(Grant_Right_Set{.Read, .Write})))
	testing.expect_value(t, r_ok, true)
	testing.expect_value(t, rights, Grant_Right_Set{.Read, .Write})
}

@(test)
plan_diff_entry_and_set_refusals :: proc(t: ^testing.T) {
	// Entry refusals: empty holder/target, oversized name, control byte, empty rights, bad kind.
	_, ref := plan_grant_entry_make(.Store_Share, "", "notes", {.Read})
	testing.expect_value(t, ref, Plan_Diff_Refusal.Empty_Holder)

	_, ref = plan_grant_entry_make(.Store_Share, "editor", "", {.Read})
	testing.expect_value(t, ref, Plan_Diff_Refusal.Empty_Target)

	long_name := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" // 65 bytes
	_, ref = plan_grant_entry_make(.Store_Share, long_name, "notes", {.Read})
	testing.expect_value(t, ref, Plan_Diff_Refusal.Name_Too_Long)

	_, ref = plan_grant_entry_make(.Store_Share, "bad\nname", "notes", {.Read})
	testing.expect_value(t, ref, Plan_Diff_Refusal.Bad_Control_Byte)

	_, ref = plan_grant_entry_make(.Store_Share, "editor", "notes", {})
	testing.expect_value(t, ref, Plan_Diff_Refusal.Empty_Rights)

	_, ref = plan_grant_entry_make(Plan_Grant_Kind(0), "editor", "notes", {.Read})
	testing.expect_value(t, ref, Plan_Diff_Refusal.Bad_Grant_Kind)

	// Null set refusal.
	entry, ok_ref := plan_grant_entry_make(.Store_Share, "editor", "notes", {.Read})
	testing.expect_value(t, ok_ref, Plan_Diff_Refusal.None)
	testing.expect_value(t, plan_grant_set_add(nil, entry), Plan_Diff_Refusal.Null_Set)

	// Duplicate entry refused with zero mutation.
	set: Plan_Grant_Set
	testing.expect_value(t, plan_grant_set_add(&set, entry), Plan_Diff_Refusal.None)
	testing.expect_value(t, set.count, u16(1))
	testing.expect_value(t, plan_grant_set_add(&set, entry), Plan_Diff_Refusal.Duplicate_Entry)
	testing.expect_value(t, set.count, u16(1))
}

@(test)
plan_diff_capacity_overflow_no_mutation :: proc(t: ^testing.T) {
	full: Plan_Grant_Set
	for i in 0 ..< PLAN_GRANT_CAPACITY {
		name := fmt.tprintf("app_%03d", i)
		e, ref := plan_grant_entry_make(.Store_Share, name, "data", {.Read})
		testing.expect_value(t, ref, Plan_Diff_Refusal.None)
		testing.expect_value(t, plan_grant_set_add(&full, e), Plan_Diff_Refusal.None)
	}
	testing.expect_value(t, full.count, u16(PLAN_GRANT_CAPACITY))

	// Entry 257 is refused without mutating `full`.
	extra, ref := plan_grant_entry_make(.Store_Share, "app_overflow", "data", {.Read})
	testing.expect_value(t, ref, Plan_Diff_Refusal.None)
	testing.expect_value(t, plan_grant_set_add(&full, extra), Plan_Diff_Refusal.Capacity_Full)
	testing.expect_value(t, full.count, u16(PLAN_GRANT_CAPACITY))

	// Output_Too_Small must not mutate caller's out_changes buffer.
	empty: Plan_Grant_Set
	sentinel_buf: [2]Plan_Grant_Change
	sentinel_buf[0].change = .Removed
	sentinel_buf[1].change = .Narrowed
	count, diff_ref := plan_diff_compute(&empty, &full, sentinel_buf[:])
	testing.expect_value(t, diff_ref, Plan_Diff_Refusal.Output_Too_Small)
	testing.expect_value(t, count, 0)
	testing.expect_value(t, sentinel_buf[0].change, Grant_Change_Kind.Removed)
	testing.expect_value(t, sentinel_buf[1].change, Grant_Change_Kind.Narrowed)
}

@(test)
plan_diff_identical_add_remove_widen_narrow_and_consent :: proc(t: ^testing.T) {
	current: Plan_Grant_Set
	target: Plan_Grant_Set

	// Entries inserted in opposite order to verify canonical deterministic sorting.
	e_stay, _ := plan_grant_entry_make(.Service_Connect, "console", "monitor", {.Connect}, make_hash(1))
	e_remove, _ := plan_grant_entry_make(.Network_Endpoint, "old_tool", "10.0.2.10:80", {.Connect})
	e_widen_before, _ := plan_grant_entry_make(.Store_Share, "notes", "journal", {.Read})
	e_widen_after, _ := plan_grant_entry_make(.Store_Share, "notes", "journal", {.Read, .Write})
	e_narrow_before, _ := plan_grant_entry_make(.Store_Share, "viewer", "archive", {.Read, .Write})
	e_narrow_after, _ := plan_grant_entry_make(.Store_Share, "viewer", "archive", {.Read})
	e_role_before, _ := plan_grant_entry_make(.Role_Holder, "display", "compositor", {.Execute}, make_hash(2))
	e_role_after, _ := plan_grant_entry_make(.Role_Holder, "display", "compositor", {.Execute}, make_hash(3))
	e_add, _ := plan_grant_entry_make(.Wide_Authority, "agent", "screen", {.Read})

	testing.expect_value(t, plan_grant_set_add(&current, e_narrow_before), Plan_Diff_Refusal.None)
	testing.expect_value(t, plan_grant_set_add(&current, e_widen_before), Plan_Diff_Refusal.None)
	testing.expect_value(t, plan_grant_set_add(&current, e_remove), Plan_Diff_Refusal.None)
	testing.expect_value(t, plan_grant_set_add(&current, e_stay), Plan_Diff_Refusal.None)
	testing.expect_value(t, plan_grant_set_add(&current, e_role_before), Plan_Diff_Refusal.None)

	// Identical plan yields 0 changes and requires no consent.
	changes: [16]Plan_Grant_Change
	same_count, same_ref := plan_diff_compute(&current, &current, changes[:])
	testing.expect_value(t, same_ref, Plan_Diff_Refusal.None)
	testing.expect_value(t, same_count, 0)
	testing.expect_value(t, plan_diff_requires_trusted_consent(changes[:same_count]), false)

	// Build target plan.
	testing.expect_value(t, plan_grant_set_add(&target, e_add), Plan_Diff_Refusal.None)
	testing.expect_value(t, plan_grant_set_add(&target, e_stay), Plan_Diff_Refusal.None)
	testing.expect_value(t, plan_grant_set_add(&target, e_role_after), Plan_Diff_Refusal.None)
	testing.expect_value(t, plan_grant_set_add(&target, e_widen_after), Plan_Diff_Refusal.None)
	testing.expect_value(t, plan_grant_set_add(&target, e_narrow_after), Plan_Diff_Refusal.None)

	count, ref := plan_diff_compute(&current, &target, changes[:])
	testing.expect_value(t, ref, Plan_Diff_Refusal.None)
	testing.expect_value(t, count, 5)

	// Canonical order is sorted by Plan_Grant_Kind ascending:
	// 0: Role_Holder (hash swap -> Widened)
	// 1: Store_Share notes/journal (Read -> Read+Write -> Widened)
	// 2: Store_Share viewer/archive (Read+Write -> Read -> Narrowed)
	// 3: Network_Endpoint old_tool (Removed)
	// 4: Wide_Authority agent (Added)
	testing.expect_value(t, changes[0].kind, Plan_Grant_Kind.Role_Holder)
	testing.expect_value(t, changes[0].change, Grant_Change_Kind.Widened)
	testing.expect_value(t, changes[1].kind, Plan_Grant_Kind.Store_Share)
	testing.expect_value(t, plan_grant_change_holder(&changes[1]), "notes")
	testing.expect_value(t, changes[1].change, Grant_Change_Kind.Widened)
	testing.expect_value(t, changes[2].kind, Plan_Grant_Kind.Store_Share)
	testing.expect_value(t, plan_grant_change_holder(&changes[2]), "viewer")
	testing.expect_value(t, changes[2].change, Grant_Change_Kind.Narrowed)
	testing.expect_value(t, changes[3].kind, Plan_Grant_Kind.Network_Endpoint)
	testing.expect_value(t, changes[3].change, Grant_Change_Kind.Removed)
	testing.expect_value(t, changes[4].kind, Plan_Grant_Kind.Wide_Authority)
	testing.expect_value(t, changes[4].change, Grant_Change_Kind.Added)

	testing.expect_value(t, plan_diff_requires_trusted_consent(changes[:count]), true)

	// Pure narrowing + removal requires no widening consent flag.
	narrow_only := [2]Plan_Grant_Change{changes[2], changes[3]}
	testing.expect_value(t, plan_diff_requires_trusted_consent(narrow_only[:]), false)
}
