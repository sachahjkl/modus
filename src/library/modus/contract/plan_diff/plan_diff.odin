// Shared contract for multi-line declaration plan grant sets and
// trusted-display grant diffs (src/md/features/declarations.md and
// src/md/features/powerbox.md).
//
// Pure freestanding contract package: no kernel calls, no host imports, and
// no dynamic allocation. Computes exact canonical diffs between current and
// target grant sets so the trusted display always gates grant additions and
// widenings behind explicit principal consent.
package plan_diff

import "modus:contract/blake3"
import "modus:contract/enum_word"

// Format property: catalog or module holder identifier max UTF-8 length.
PLAN_HOLDER_NAME_BYTES :: 64

// Format property: role, store, service, or endpoint target max UTF-8 length.
PLAN_TARGET_NAME_BYTES :: 64

// Plan value: default fixed capacity of grant entries per plan set, supporting
// multi-line declaration plans well past the 200-byte console line.
PLAN_GRANT_CAPACITY :: 256

// Closed set of outcomes returned by plan grant set construction and diffing.
// Values cross process borders explicitly.
Plan_Diff_Refusal :: enum u8 {
	None             = 0,
	Duplicate_Entry  = 1,
	Capacity_Full    = 2,
	Output_Too_Small = 3,
	Empty_Holder     = 4,
	Empty_Target     = 5,
	Name_Too_Long    = 6,
	Bad_Grant_Kind   = 7,
	Empty_Rights     = 8,
	Bad_Rights_Mask  = 9,
	Null_Set         = 10,
	Bad_Control_Byte = 11,
}

// Closed set of per-grant transition kinds reported by plan_diff_compute.
Grant_Change_Kind :: enum u8 {
	Unchanged = 0,
	Added     = 1,
	Removed   = 2,
	Widened   = 3,
	Narrowed  = 4,
}

// Closed set of plan grant categories subject to diffing and trusted consent.
Plan_Grant_Kind :: enum u8 {
	Role_Holder      = 1,
	Store_Share      = 2,
	Network_Endpoint = 3,
	Service_Connect  = 4,
	Start_Grant      = 5,
	Plan_Value       = 6,
	Wide_Authority   = 7,
}

// Closed set of rights bits carried on a plan grant entry.
Grant_Right :: enum u8 {
	Read     = 0,
	Write    = 1,
	Execute  = 2,
	Connect  = 3,
	Listen   = 4,
	Admin    = 5,
	Delegate = 6,
}

// Bitset of Grant_Right bits.
Grant_Right_Set :: bit_set[Grant_Right; u16]

// Mask of all valid Grant_Right bits (bits 0..6).
@(private = "file")
VALID_RIGHTS_MASK :: u16((1 << 7) - 1)

// One grant entry inside a multi-line declaration plan.
Plan_Grant_Entry :: struct {
	kind:        Plan_Grant_Kind,
	holder:      [PLAN_HOLDER_NAME_BYTES]u8,
	holder_len:  u16,
	target:      [PLAN_TARGET_NAME_BYTES]u8,
	target_len:  u16,
	rights:      Grant_Right_Set,
	module_hash: blake3.Hash,
}

// Complete set of grant entries carried by one current or target plan.
Plan_Grant_Set :: struct {
	entries: [PLAN_GRANT_CAPACITY]Plan_Grant_Entry,
	count:   u16,
}

// One deterministic grant difference row for the trusted display.
Plan_Grant_Change :: struct {
	change:        Grant_Change_Kind,
	kind:          Plan_Grant_Kind,
	holder:        [PLAN_HOLDER_NAME_BYTES]u8,
	holder_len:    u16,
	target:        [PLAN_TARGET_NAME_BYTES]u8,
	target_len:    u16,
	before_rights: Grant_Right_Set,
	after_rights:  Grant_Right_Set,
	before_hash:   blake3.Hash,
	after_hash:    blake3.Hash,
}

// plan_grant_kind_of_word converts a transport word into a Plan_Grant_Kind at
// a border, refusing any word that names no member.
plan_grant_kind_of_word :: proc "contextless" (word: u64) -> (kind: Plan_Grant_Kind, ok: bool) {
	return enum_word.member_of_word(Plan_Grant_Kind, word)
}

// grant_change_kind_of_word converts a transport word into a Grant_Change_Kind
// at a border, refusing any word that names no member.
grant_change_kind_of_word :: proc "contextless" (word: u64) -> (kind: Grant_Change_Kind, ok: bool) {
	return enum_word.member_of_word(Grant_Change_Kind, word)
}

// grant_right_set_of_word converts a raw rights bitmask at a border, refusing
// any unknown bit past the closed Grant_Right set.
grant_right_set_of_word :: proc "contextless" (word: u64) -> (rights: Grant_Right_Set, ok: bool) {
	if (word & ~u64(VALID_RIGHTS_MASK)) != 0 {
		return {}, false
	}
	return transmute(Grant_Right_Set)u16(word), true
}

// plan_grant_entry_holder returns the holder name slice of `entry`.
plan_grant_entry_holder :: proc "contextless" (entry: ^Plan_Grant_Entry) -> string {
	if entry == nil || int(entry.holder_len) > PLAN_HOLDER_NAME_BYTES {
		return ""
	}
	return string(entry.holder[:entry.holder_len])
}

// plan_grant_entry_target returns the target name slice of `entry`.
plan_grant_entry_target :: proc "contextless" (entry: ^Plan_Grant_Entry) -> string {
	if entry == nil || int(entry.target_len) > PLAN_TARGET_NAME_BYTES {
		return ""
	}
	return string(entry.target[:entry.target_len])
}

// plan_grant_change_holder returns the holder name slice of `change`.
plan_grant_change_holder :: proc "contextless" (change: ^Plan_Grant_Change) -> string {
	if change == nil || int(change.holder_len) > PLAN_HOLDER_NAME_BYTES {
		return ""
	}
	return string(change.holder[:change.holder_len])
}

// plan_grant_change_target returns the target name slice of `change`.
plan_grant_change_target :: proc "contextless" (change: ^Plan_Grant_Change) -> string {
	if change == nil || int(change.target_len) > PLAN_TARGET_NAME_BYTES {
		return ""
	}
	return string(change.target[:change.target_len])
}

// plan_grant_entry_make constructs and validates one Plan_Grant_Entry.
plan_grant_entry_make :: proc "contextless" (
	kind: Plan_Grant_Kind,
	holder: string,
	target: string,
	rights: Grant_Right_Set,
	module_hash: blake3.Hash = {},
) -> (entry: Plan_Grant_Entry, refusal: Plan_Diff_Refusal) {
	if _, ok := enum_word.member_of_argument(kind); !ok {
		return {}, .Bad_Grant_Kind
	}
	if len(holder) == 0 {
		return {}, .Empty_Holder
	}
	if len(holder) > PLAN_HOLDER_NAME_BYTES {
		return {}, .Name_Too_Long
	}
	if len(target) == 0 {
		return {}, .Empty_Target
	}
	if len(target) > PLAN_TARGET_NAME_BYTES {
		return {}, .Name_Too_Long
	}
	if !name_bytes_clean(holder) || !name_bytes_clean(target) {
		return {}, .Bad_Control_Byte
	}
	raw_rights := transmute(u16)rights
	if (raw_rights & ~VALID_RIGHTS_MASK) != 0 {
		return {}, .Bad_Rights_Mask
	}
	if rights == {} {
		return {}, .Empty_Rights
	}

	out := Plan_Grant_Entry{
		kind        = kind,
		holder_len  = u16(len(holder)),
		target_len  = u16(len(target)),
		rights      = rights,
		module_hash = module_hash,
	}
	copy(out.holder[:len(holder)], holder)
	copy(out.target[:len(target)], target)
	return out, .None
}

// plan_grant_entry_validate checks every field of an existing Plan_Grant_Entry.
plan_grant_entry_validate :: proc "contextless" (entry: ^Plan_Grant_Entry) -> Plan_Diff_Refusal {
	if entry == nil {
		return .Null_Set
	}
	if _, ok := enum_word.member_of_argument(entry.kind); !ok {
		return .Bad_Grant_Kind
	}
	if entry.holder_len == 0 {
		return .Empty_Holder
	}
	if int(entry.holder_len) > PLAN_HOLDER_NAME_BYTES {
		return .Name_Too_Long
	}
	if entry.target_len == 0 {
		return .Empty_Target
	}
	if int(entry.target_len) > PLAN_TARGET_NAME_BYTES {
		return .Name_Too_Long
	}
	if !name_bytes_clean(string(entry.holder[:entry.holder_len])) ||
	   !name_bytes_clean(string(entry.target[:entry.target_len])) {
		return .Bad_Control_Byte
	}
	raw_rights := transmute(u16)entry.rights
	if (raw_rights & ~VALID_RIGHTS_MASK) != 0 {
		return .Bad_Rights_Mask
	}
	if entry.rights == {} {
		return .Empty_Rights
	}
	return .None
}

// plan_grant_set_add validates `entry` and appends it to `set`, refusing
// duplicates and capacity overflow without mutating `set`.
plan_grant_set_add :: proc "contextless" (set: ^Plan_Grant_Set, entry: Plan_Grant_Entry) -> Plan_Diff_Refusal {
	if set == nil {
		return .Null_Set
	}
	local_entry := entry
	if err := plan_grant_entry_validate(&local_entry); err != .None {
		return err
	}
	if int(set.count) > PLAN_GRANT_CAPACITY {
		return .Capacity_Full
	}
	for i in 0 ..< int(set.count) {
		if entry_key_compare(&set.entries[i], &local_entry) == 0 {
			return .Duplicate_Entry
		}
	}
	if int(set.count) >= PLAN_GRANT_CAPACITY {
		return .Capacity_Full
	}
	set.entries[set.count] = local_entry
	set.count += 1
	return .None
}

// plan_grant_set_validate checks every entry and key uniqueness in `set`.
plan_grant_set_validate :: proc "contextless" (set: ^Plan_Grant_Set) -> Plan_Diff_Refusal {
	if set == nil {
		return .Null_Set
	}
	if int(set.count) > PLAN_GRANT_CAPACITY {
		return .Capacity_Full
	}
	n := int(set.count)
	for i in 0 ..< n {
		if err := plan_grant_entry_validate(&set.entries[i]); err != .None {
			return err
		}
	}
	for i in 0 ..< n {
		for j in i + 1 ..< n {
			if entry_key_compare(&set.entries[i], &set.entries[j]) == 0 {
				return .Duplicate_Entry
			}
		}
	}
	return .None
}

// plan_diff_compute computes the exact deterministic grant diff from `current`
// to `target` in canonical (kind, holder, target) order. On any refusal
// (including Output_Too_Small), `out_changes` is not modified.
plan_diff_compute :: proc "contextless" (
	current: ^Plan_Grant_Set,
	target: ^Plan_Grant_Set,
	out_changes: []Plan_Grant_Change,
) -> (count: int, refusal: Plan_Diff_Refusal) {
	if err := plan_grant_set_validate(current); err != .None {
		return 0, err
	}
	if err := plan_grant_set_validate(target); err != .None {
		return 0, err
	}

	cur_order: [PLAN_GRANT_CAPACITY]u16
	tgt_order: [PLAN_GRANT_CAPACITY]u16
	cur_n := int(current.count)
	tgt_n := int(target.count)
	sort_entry_indices(current, cur_order[:cur_n])
	sort_entry_indices(target, tgt_order[:tgt_n])

	// Pass 1: count changes before writing so Output_Too_Small never mutates out_changes.
	needed := 0
	ci := 0
	ti := 0
	for ci < cur_n && ti < tgt_n {
		ce := &current.entries[cur_order[ci]]
		te := &target.entries[tgt_order[ti]]
		cmp := entry_key_compare(ce, te)
		if cmp < 0 {
			needed += 1
			ci += 1
		} else if cmp > 0 {
			needed += 1
			ti += 1
		} else {
			if classify_entry_transition(ce, te) != .Unchanged {
				needed += 1
			}
			ci += 1
			ti += 1
		}
	}
	needed += (cur_n - ci) + (tgt_n - ti)

	if needed > len(out_changes) {
		return 0, .Output_Too_Small
	}

	// Pass 2: emit deterministic change records in canonical key order.
	written := 0
	ci = 0
	ti = 0
	for ci < cur_n && ti < tgt_n {
		ce := &current.entries[cur_order[ci]]
		te := &target.entries[tgt_order[ti]]
		cmp := entry_key_compare(ce, te)
		if cmp < 0 {
			out_changes[written] = make_removed_change(ce)
			written += 1
			ci += 1
		} else if cmp > 0 {
			out_changes[written] = make_added_change(te)
			written += 1
			ti += 1
		} else {
			kind := classify_entry_transition(ce, te)
			if kind != .Unchanged {
				out_changes[written] = make_modified_change(kind, ce, te)
				written += 1
			}
			ci += 1
			ti += 1
		}
	}
	for ci < cur_n {
		out_changes[written] = make_removed_change(&current.entries[cur_order[ci]])
		written += 1
		ci += 1
	}
	for ti < tgt_n {
		out_changes[written] = make_added_change(&target.entries[tgt_order[ti]])
		written += 1
		ti += 1
	}
	return written, .None
}

// plan_diff_requires_trusted_consent reports whether any change adds or widens
// a grant (or swaps a module hash on an existing grant/role), requiring
// explicit trusted-display approval that an agent console cannot bypass.
plan_diff_requires_trusted_consent :: proc "contextless" (changes: []Plan_Grant_Change) -> bool {
	for ch in changes {
		switch ch.change {
		case .Added, .Widened:
			return true
		case .Removed, .Narrowed, .Unchanged:
		}
	}
	return false
}

// ---- Private helpers.

@(private = "file")
name_bytes_clean :: proc "contextless" (s: string) -> bool {
	for i in 0 ..< len(s) {
		b := s[i]
		if b < 0x20 || b == 0x7F {
			return false
		}
	}
	return true
}

@(private = "file")
bytes_compare :: proc "contextless" (a, b: []u8) -> int {
	limit := min(len(a), len(b))
	for i in 0 ..< limit {
		if a[i] < b[i] {
			return -1
		}
		if a[i] > b[i] {
			return 1
		}
	}
	if len(a) < len(b) {
		return -1
	}
	if len(a) > len(b) {
		return 1
	}
	return 0
}

@(private = "file")
entry_key_compare :: proc "contextless" (a, b: ^Plan_Grant_Entry) -> int {
	if u8(a.kind) < u8(b.kind) {
		return -1
	}
	if u8(a.kind) > u8(b.kind) {
		return 1
	}
	hc := bytes_compare(a.holder[:a.holder_len], b.holder[:b.holder_len])
	if hc != 0 {
		return hc
	}
	return bytes_compare(a.target[:a.target_len], b.target[:b.target_len])
}

@(private = "file")
sort_entry_indices :: proc "contextless" (set: ^Plan_Grant_Set, order: []u16) {
	for i in 0 ..< len(order) {
		order[i] = u16(i)
	}
	for i := 1; i < len(order); i += 1 {
		key_idx := order[i]
		j := i - 1
		for j >= 0 && entry_key_compare(&set.entries[order[j]], &set.entries[key_idx]) > 0 {
			order[j + 1] = order[j]
			j -= 1
		}
		order[j + 1] = key_idx
	}
}

@(private = "file")
classify_entry_transition :: proc "contextless" (before, after: ^Plan_Grant_Entry) -> Grant_Change_Kind {
	added_rights := after.rights - before.rights
	removed_rights := before.rights - after.rights
	hash_changed := before.module_hash != after.module_hash
	// Any new right or changed module hash widens authority and must ask consent.
	if added_rights != {} || hash_changed {
		return .Widened
	}
	if removed_rights != {} {
		return .Narrowed
	}
	return .Unchanged
}

@(private = "file")
make_added_change :: proc "contextless" (entry: ^Plan_Grant_Entry) -> Plan_Grant_Change {
	return {
		change       = .Added,
		kind         = entry.kind,
		holder       = entry.holder,
		holder_len   = entry.holder_len,
		target       = entry.target,
		target_len   = entry.target_len,
		after_rights = entry.rights,
		after_hash   = entry.module_hash,
	}
}

@(private = "file")
make_removed_change :: proc "contextless" (entry: ^Plan_Grant_Entry) -> Plan_Grant_Change {
	return {
		change        = .Removed,
		kind          = entry.kind,
		holder        = entry.holder,
		holder_len    = entry.holder_len,
		target        = entry.target,
		target_len    = entry.target_len,
		before_rights = entry.rights,
		before_hash   = entry.module_hash,
	}
}

@(private = "file")
make_modified_change :: proc "contextless" (kind: Grant_Change_Kind, before, after: ^Plan_Grant_Entry) -> Plan_Grant_Change {
	return {
		change        = kind,
		kind          = after.kind,
		holder        = after.holder,
		holder_len    = after.holder_len,
		target        = after.target,
		target_len    = after.target_len,
		before_rights = before.rights,
		after_rights  = after.rights,
		before_hash   = before.module_hash,
		after_hash    = after.module_hash,
	}
}
