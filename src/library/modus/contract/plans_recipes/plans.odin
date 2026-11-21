// Plans contract: declarative system and session plan records, canonical
// hashing, grant difference computation, trusted display integration,
// rollback validation, and the applied_plans store wire format
// (src/md/features/declarations.md).
//
// This is a contract package: it imports base and contract packages only,
// calls no kernel operation, and allocates no memory.
package plans_recipes

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/powerbox"
import "modus:contract/role_contract"
import "modus:contract/start_grant"
import "modus:contract/text_encoding"

// Domain separation context string for canonical plan digests.
PLAN_HASH_DOMAIN :: "modus plan v1"

// Header magic identifying version 1 of an Applied_Plan_Record in applied_plans.
APPLIED_PLAN_MAGIC :: [8]u8{'M', 'O', 'D', 'P', 'L', 'A', 'N', '1'}

// Current binary wire format version for Applied_Plan_Record.
APPLIED_PLAN_WIRE_VERSION :: u32(1)

// Exact binary wire size of one Applied_Plan_Record:
//   magic(8) + version(4) + reserved(4) + plan_hash(32) + previous_plan_hash(32) +
//   generation(8) + timestamp_ms(8) + principal(8) = 104 bytes.
APPLIED_PLAN_WIRE_SIZE :: 8 + 4 + 4 + blake3.HASH_SIZE + blake3.HASH_SIZE + 8 + 8 + 8

// Structural bounds on plans and plan differences.
MAX_PLAN_ENTRIES :: 32
MAX_PLAN_DIFF_CHANGES :: 64
MAX_ENTRY_NAME_BYTES :: 64
MAX_PLAN_CANONICAL_BYTES :: 16384

// Context slots for the delegated plans service.
PLANS_SERVICE_RING_SLOT :: 10
PLANS_SERVICE_REGION_SLOT :: 11
PLANS_POWERBOX_RING_SLOT :: 12
PLANS_CONTEXT_VALUE_DISPLAY_SLOT :: 0

#assert(APPLIED_PLAN_WIRE_SIZE == 104)

// Closed set of entry kinds carried inside a Plan_Spec.
// Zero means unset and is refused at the border.
Plan_Entry_Kind :: enum u8 {
	None         = 0,
	Role_Holder  = 1,
	Start_Module = 2,
	Disk_Module  = 3,
	Store_Grant  = 4,
}

// Closed set of store access rights declared in a plan or project console.
// Zero means unset and is refused at the border.
Plan_Store_Rights :: enum u8 {
	None       = 0,
	Read_Only  = 1,
	Read_Write = 2,
}

// Closed set of change kinds reported in a Plan_Difference.
Plan_Change_Kind :: enum u8 {
	None    = 0,
	Added   = 1,
	Removed = 2,
	Changed = 3,
}

// Closed set of refusal reasons for plan validation, diffing, apply, and rollback.
Plan_Refusal :: enum u8 {
	None                   = 0,
	Empty_Plan             = 1,
	Too_Many_Entries       = 2,
	Bad_Entry_Kind         = 3,
	Bad_Role               = 4,
	Zero_Module_Hash       = 5,
	Bad_Start_Grant        = 6,
	Bad_Store_Rights       = 7,
	Invalid_Name           = 8,
	Duplicate_Entry        = 9,
	Cyclic_Role_Chain      = 10,
	Buffer_Too_Small       = 11,
	Truncated              = 12,
	Trailing_Bytes         = 13,
	Bad_Header             = 14,
	Zero_Plan_Hash         = 15,
	Empty_History          = 16,
	Unknown_Generation     = 17,
	Already_At_Generation  = 18,
	Stale_Current_Plan     = 19,
	Consent_Required       = 20,
	Untrusted_Consent      = 21,
	Principal_Mismatch     = 22,
	Trusted_Path_Forbidden = 23,
	History_Full           = 24,
}

// Closed set of commands accepted on the plans service ring.
Plans_Ring_Command :: enum u32 {
	None            = 0,
	Compute_Diff    = 1,
	Apply_Plan      = 2,
	Rollback_Plan   = 3,
	Query_History   = 4,
}

// Closed set of completion statuses returned on the plans, recipes, and
// projects service rings.
Service_Ring_Status :: enum u32 {
	Ok          = 0,
	Refused     = 1,
	Bad_Command = 2,
	Busy        = 3,
}

// One typed declaration entry inside a Plan_Spec.
Plan_Entry :: struct {
	kind_word:            u64,
	name_bytes:           [MAX_ENTRY_NAME_BYTES]u8,
	name_length:          u8,
	role_word:            u64,
	module_hash:          blake3.Hash,
	interposed_over_hash: blake3.Hash,
	recipe_hash:          blake3.Hash,
	start_grants_mask:    u64,
	store_rights_word:    u64,
}

// Complete typed plan value produced by declaration evaluation and checked by
// the plans service and root service.
Plan_Spec :: struct {
	principal:   u64,
	entry_count: u32,
	entries:     [MAX_PLAN_ENTRIES]Plan_Entry,
}

// One difference row between a current applied plan and a proposed plan.
Plan_Diff_Item :: struct {
	change:              Plan_Change_Kind,
	entry_kind:          Plan_Entry_Kind,
	role:                role_contract.Role,
	name_bytes:          [MAX_ENTRY_NAME_BYTES]u8,
	name_length:         u8,
	old_module_hash:     blake3.Hash,
	new_module_hash:     blake3.Hash,
	added_grants_mask:   u64,
	removed_grants_mask: u64,
	old_store_rights:    Plan_Store_Rights,
	new_store_rights:    Plan_Store_Rights,
}

// Summary and itemized difference between two plans. Feeds directly into the
// powerbox Show_Plan_Difference trusted display dialog.
Plan_Difference :: struct {
	current_plan_hash:    blake3.Hash,
	proposed_plan_hash:   blake3.Hash,
	added_roles:          u32,
	removed_roles:        u32,
	changed_roles:        u32,
	added_modules:        u32,
	removed_modules:      u32,
	changed_modules:      u32,
	added_stores:         u32,
	removed_stores:       u32,
	changed_stores:       u32,
	added_grants_count:   u32,
	removed_grants_count: u32,
	any_grant_added:      bool,
	has_changes:          bool,
	change_count:         u32,
	changes:              [MAX_PLAN_DIFF_CHANGES]Plan_Diff_Item,
}

// One persisted generation record stored in a principal's applied_plans store.
Applied_Plan_Record :: struct {
	plan_hash:          blake3.Hash,
	previous_plan_hash: blake3.Hash,
	generation:         u64,
	timestamp_ms:       u64,
	principal:          u64,
}

// Single borders converting transport words into closed enum members.

plan_entry_kind_of_word :: proc "contextless" (word: u64) -> (kind: Plan_Entry_Kind, ok: bool) {
	member := enum_word.member_of_word(Plan_Entry_Kind, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

plan_store_rights_of_word :: proc "contextless" (word: u64) -> (rights: Plan_Store_Rights, ok: bool) {
	member := enum_word.member_of_word(Plan_Store_Rights, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

plans_ring_command_of_word :: proc "contextless" (word: u32) -> (command: Plans_Ring_Command, ok: bool) {
	member := enum_word.member_of_word(Plans_Ring_Command, u64(word)) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// Canonical byte encoder for hashing without dynamic allocation.
@(private)
Canonical_Encoder :: struct {
	buffer:   []u8,
	position: int,
	overflow: bool,
}

@(private)
encoder_byte :: proc "contextless" (encoder: ^Canonical_Encoder, value: u8) {
	if encoder.overflow || encoder.position >= len(encoder.buffer) {
		encoder.overflow = true
		return
	}
	encoder.buffer[encoder.position] = value
	encoder.position += 1
}

@(private)
encoder_u32 :: proc "contextless" (encoder: ^Canonical_Encoder, value: u32) {
	if encoder.overflow || len(encoder.buffer) - encoder.position < 4 {
		encoder.overflow = true
		return
	}
	byte_order.write_u32_little_endian(encoder.buffer, encoder.position, value)
	encoder.position += 4
}

@(private)
encoder_u64 :: proc "contextless" (encoder: ^Canonical_Encoder, value: u64) {
	if encoder.overflow || len(encoder.buffer) - encoder.position < 8 {
		encoder.overflow = true
		return
	}
	byte_order.write_u64_little_endian(encoder.buffer, encoder.position, value)
	encoder.position += 8
}

@(private)
encoder_bytes :: proc "contextless" (encoder: ^Canonical_Encoder, data: []u8) {
	encoder_u32(encoder, u32(len(data)))
	if encoder.overflow || len(encoder.buffer) - encoder.position < len(data) {
		encoder.overflow = true
		return
	}
	for index in 0 ..< len(data) {
		encoder.buffer[encoder.position + index] = data[index]
	}
	encoder.position += len(data)
}

@(private)
encoder_raw_bytes :: proc "contextless" (encoder: ^Canonical_Encoder, data: []u8) {
	if encoder.overflow || len(encoder.buffer) - encoder.position < len(data) {
		encoder.overflow = true
		return
	}
	for index in 0 ..< len(data) {
		encoder.buffer[encoder.position + index] = data[index]
	}
	encoder.position += len(data)
}

@(private)
hash_is_zero :: proc "contextless" (value: blake3.Hash) -> bool {
	accumulated: u8 = 0
	for item in value {
		accumulated |= item
	}
	return accumulated == 0
}

@(private)
bytes_equal :: proc "contextless" (first, second: []u8) -> bool {
	if len(first) != len(second) {
		return false
	}
	for index in 0 ..< len(first) {
		if first[index] != second[index] {
			return false
		}
	}
	return true
}

@(private)
compare_bytes :: proc "contextless" (first, second: []u8) -> int {
	limit := min(len(first), len(second))
	for index in 0 ..< limit {
		if first[index] != second[index] {
			return first[index] < second[index] ? -1 : 1
		}
	}
	if len(first) < len(second) {
		return -1
	}
	if len(first) > len(second) {
		return 1
	}
	return 0
}

@(private)
popcount_u64 :: proc "contextless" (value: u64) -> u32 {
	remaining := value
	count: u32 = 0
	for remaining != 0 {
		remaining &= remaining - 1
		count += 1
	}
	return count
}

@(private)
entry_name_valid :: proc "contextless" (bytes: []u8, length: u8) -> bool {
	size := int(length)
	if size == 0 || size > len(bytes) {
		return false
	}
	active := bytes[:size]
	if (size == 1 && active[0] == '.') || (size == 2 && active[0] == '.' && active[1] == '.') {
		return false
	}
	for item in active {
		if item == '/' || item == '\\' {
			return false
		}
	}
	if !text_encoding.identifier_valid(active) {
		return false
	}
	for pad in bytes[size:] {
		if pad != 0 {
			return false
		}
	}
	return true
}

// start_grants_mask_valid reports whether every set bit in mask names a valid
// start_grant.Grant member other than System_Part, which no plan may grant.
start_grants_mask_valid :: proc "contextless" (mask: u64) -> bool {
	allowed: u64 = 0
	for member in start_grant.Grant {
		if member == .System_Part {
			continue
		}
		bit := u64(member)
		if bit < 64 {
			allowed |= u64(1) << bit
		}
	}
	return (mask & ~allowed) == 0
}

// plan_entry_make_role constructs a Role_Holder entry with zero-padded name bytes.
plan_entry_make_role :: proc "contextless" (
	name: string,
	role: role_contract.Role,
	module_hash: blake3.Hash,
	interposed_over_hash: blake3.Hash = {},
	start_grants_mask: u64 = 0,
) -> (entry: Plan_Entry, ok: bool) {
	raw := transmute([]u8)name
	if len(raw) == 0 || len(raw) > MAX_ENTRY_NAME_BYTES {
		return {}, false
	}
	copy(entry.name_bytes[:len(raw)], raw)
	entry.name_length = u8(len(raw))
	entry.kind_word = u64(Plan_Entry_Kind.Role_Holder)
	entry.role_word = u64(role)
	entry.module_hash = module_hash
	entry.interposed_over_hash = interposed_over_hash
	entry.start_grants_mask = start_grants_mask
	return entry, true
}

// plan_entry_make_module constructs a Start_Module or Disk_Module entry.
plan_entry_make_module :: proc "contextless" (
	kind: Plan_Entry_Kind,
	name: string,
	module_hash: blake3.Hash,
	start_grants_mask: u64 = 0,
	recipe_hash: blake3.Hash = {},
) -> (entry: Plan_Entry, ok: bool) {
	if kind != .Start_Module && kind != .Disk_Module {
		return {}, false
	}
	raw := transmute([]u8)name
	if len(raw) == 0 || len(raw) > MAX_ENTRY_NAME_BYTES {
		return {}, false
	}
	copy(entry.name_bytes[:len(raw)], raw)
	entry.name_length = u8(len(raw))
	entry.kind_word = u64(kind)
	entry.module_hash = module_hash
	entry.recipe_hash = recipe_hash
	entry.start_grants_mask = start_grants_mask
	return entry, true
}

// plan_entry_make_store constructs a Store_Grant entry with validated rights.
plan_entry_make_store :: proc "contextless" (name: string, rights: Plan_Store_Rights) -> (entry: Plan_Entry, ok: bool) {
	if rights == .None {
		return {}, false
	}
	raw := transmute([]u8)name
	if len(raw) == 0 || len(raw) > MAX_ENTRY_NAME_BYTES {
		return {}, false
	}
	copy(entry.name_bytes[:len(raw)], raw)
	entry.name_length = u8(len(raw))
	entry.kind_word = u64(Plan_Entry_Kind.Store_Grant)
	entry.store_rights_word = u64(rights)
	return entry, true
}

@(private = "file")
plan_entries_same_identity :: proc "contextless" (first, second: ^Plan_Entry) -> bool {
	if first.kind_word != second.kind_word {
		return false
	}
	kind, ok := plan_entry_kind_of_word(first.kind_word)
	if !ok {
		return false
	}
	if kind == .Role_Holder && first.role_word != second.role_word {
		return false
	}
	if first.name_length != second.name_length || int(first.name_length) > MAX_ENTRY_NAME_BYTES {
		return false
	}
	return bytes_equal(first.name_bytes[:first.name_length], second.name_bytes[:second.name_length])
}

// plan_validate strictly checks every entry of plan at the border.
// Refuses empty plans, oversized entry counts, unknown enum words, zero module
// hashes, invalid names or non-zero padding, unknown or System_Part start grant
// bits, non-principal-0 trusted-path role holders, duplicate entries, and
// cyclic role interposition chains.
plan_validate :: proc "contextless" (plan: ^Plan_Spec) -> (refusal: Plan_Refusal, bad_index: u32) {
	if plan == nil || plan.entry_count == 0 {
		return .Empty_Plan, 0
	}
	if plan.entry_count > MAX_PLAN_ENTRIES {
		return .Too_Many_Entries, 0
	}

	for index in u32(0) ..< plan.entry_count {
		entry := &plan.entries[index]
		kind, kind_ok := plan_entry_kind_of_word(entry.kind_word)
		if !kind_ok {
			return .Bad_Entry_Kind, index
		}
		if !entry_name_valid(entry.name_bytes[:], entry.name_length) {
			return .Invalid_Name, index
		}
		if !start_grants_mask_valid(entry.start_grants_mask) {
			return .Bad_Start_Grant, index
		}

		switch kind {
		case .None:
			return .Bad_Entry_Kind, index
		case .Role_Holder:
			role, role_ok := role_contract.role_from_word(entry.role_word)
			if !role_ok {
				return .Bad_Role, index
			}
			if !role_contract.disk_holder_allowed_for_principal(role, plan.principal) {
				return .Trusted_Path_Forbidden, index
			}
			if hash_is_zero(entry.module_hash) {
				return .Zero_Module_Hash, index
			}
			if entry.store_rights_word != 0 {
				return .Bad_Store_Rights, index
			}
			if !hash_is_zero(entry.interposed_over_hash) && entry.interposed_over_hash == entry.module_hash {
				return .Cyclic_Role_Chain, index
			}
		case .Start_Module, .Disk_Module:
			if entry.role_word != 0 {
				return .Bad_Role, index
			}
			if hash_is_zero(entry.module_hash) {
				return .Zero_Module_Hash, index
			}
			if !hash_is_zero(entry.interposed_over_hash) {
				return .Bad_Role, index
			}
			if entry.store_rights_word != 0 {
				return .Bad_Store_Rights, index
			}
		case .Store_Grant:
			if entry.role_word != 0 {
				return .Bad_Role, index
			}
			if !hash_is_zero(entry.module_hash) || !hash_is_zero(entry.interposed_over_hash) {
				return .Bad_Entry_Kind, index
			}
			if entry.start_grants_mask != 0 {
				return .Bad_Start_Grant, index
			}
			if _, rights_ok := plan_store_rights_of_word(entry.store_rights_word); !rights_ok {
				return .Bad_Store_Rights, index
			}
		}

		// Duplicate checks against all earlier entries.
		for earlier in u32(0) ..< index {
			prev := &plan.entries[earlier]
			if plan_entries_same_identity(prev, entry) {
				return .Duplicate_Entry, index
			}
			if kind == .Role_Holder && prev.kind_word == u64(Plan_Entry_Kind.Role_Holder) && prev.role_word == entry.role_word {
				role, _ := role_contract.role_from_word(entry.role_word)
				if !role_contract.role_allows_multiple_holders(role) {
					return .Duplicate_Entry, index
				}
				if prev.module_hash == entry.module_hash {
					return .Duplicate_Entry, index
				}
			}
		}
	}

	// Cycle detection across role interposition chains for each Role_Holder.
	for index in u32(0) ..< plan.entry_count {
		entry := &plan.entries[index]
		if entry.kind_word != u64(Plan_Entry_Kind.Role_Holder) || hash_is_zero(entry.interposed_over_hash) {
			continue
		}
		cursor := entry.interposed_over_hash
		for hop in u32(0) ..< plan.entry_count {
			_ = hop
			if cursor == entry.module_hash {
				return .Cyclic_Role_Chain, index
			}
			found_next := false
			for candidate_index in u32(0) ..< plan.entry_count {
				candidate := &plan.entries[candidate_index]
				if candidate.kind_word != u64(Plan_Entry_Kind.Role_Holder) || candidate.role_word != entry.role_word {
					continue
				}
				if candidate.module_hash == cursor {
					if hash_is_zero(candidate.interposed_over_hash) {
						found_next = false
						break
					}
					cursor = candidate.interposed_over_hash
					found_next = true
					break
				}
			}
			if !found_next {
				break
			}
			if hop == plan.entry_count - 1 {
				return .Cyclic_Role_Chain, index
			}
		}
	}

	return .None, 0
}

@(private = "file")
compare_plan_entries :: proc "contextless" (first, second: ^Plan_Entry) -> int {
	if first.kind_word != second.kind_word {
		return first.kind_word < second.kind_word ? -1 : 1
	}
	if first.role_word != second.role_word {
		return first.role_word < second.role_word ? -1 : 1
	}
	name_order := compare_bytes(first.name_bytes[:first.name_length], second.name_bytes[:second.name_length])
	if name_order != 0 {
		return name_order
	}
	return compare_bytes(first.module_hash[:], second.module_hash[:])
}

// plan_hash validates plan and computes its canonical order-independent
// domain-separated BLAKE3 digest.
plan_hash :: proc "contextless" (plan: ^Plan_Spec) -> (digest: blake3.Hash, refusal: Plan_Refusal) {
	validation_refusal, _ := plan_validate(plan)
	if validation_refusal != .None {
		return {}, validation_refusal
	}

	// Sort indices into canonical order without mutating the caller's plan.
	order: [MAX_PLAN_ENTRIES]u32
	for index in u32(0) ..< plan.entry_count {
		order[index] = index
	}
	for i in u32(1) ..< plan.entry_count {
		key_index := order[i]
		j := int(i) - 1
		for j >= 0 && compare_plan_entries(&plan.entries[order[j]], &plan.entries[key_index]) > 0 {
			order[j + 1] = order[j]
			j -= 1
		}
		order[j + 1] = key_index
	}

	canonical_buffer: [MAX_PLAN_CANONICAL_BYTES]u8
	encoder := Canonical_Encoder{buffer = canonical_buffer[:]}
	encoder_u64(&encoder, plan.principal)
	encoder_u32(&encoder, plan.entry_count)
	for pos in u32(0) ..< plan.entry_count {
		entry := &plan.entries[order[pos]]
		encoder_u64(&encoder, entry.kind_word)
		encoder_bytes(&encoder, entry.name_bytes[:entry.name_length])
		encoder_u64(&encoder, entry.role_word)
		encoder_raw_bytes(&encoder, entry.module_hash[:])
		encoder_raw_bytes(&encoder, entry.interposed_over_hash[:])
		encoder_raw_bytes(&encoder, entry.recipe_hash[:])
		encoder_u64(&encoder, entry.start_grants_mask)
		encoder_u64(&encoder, entry.store_rights_word)
	}
	if encoder.overflow {
		return {}, .Buffer_Too_Small
	}
	return blake3.derive_key(PLAN_HASH_DOMAIN, canonical_buffer[:encoder.position]), .None
}

@(private = "file")
append_diff_item :: proc "contextless" (diff: ^Plan_Difference, item: Plan_Diff_Item) {
	if diff.change_count < MAX_PLAN_DIFF_CHANGES {
		diff.changes[diff.change_count] = item
		diff.change_count += 1
	}
	diff.has_changes = true
}

// plan_diff_compute computes the complete grant, role, module, and store
// difference between current (nil when no plan is applied yet) and proposed.
// Sets any_grant_added whenever any start grant, store right, or role
// authority is newly granted or widened.
plan_diff_compute :: proc "contextless" (current: ^Plan_Spec, proposed: ^Plan_Spec) -> (diff: Plan_Difference, refusal: Plan_Refusal) {
	if current != nil {
		current_hash, current_refusal := plan_hash(current)
		if current_refusal != .None {
			return {}, current_refusal
		}
		diff.current_plan_hash = current_hash
	}
	proposed_hash, proposed_refusal := plan_hash(proposed)
	if proposed_refusal != .None {
		return {}, proposed_refusal
	}
	if current != nil && current.principal != proposed.principal {
		return {}, .Principal_Mismatch
	}
	diff.proposed_plan_hash = proposed_hash

	// Pass 1: find removed and changed entries from current.
	if current != nil {
		for cur_index in u32(0) ..< current.entry_count {
			cur_entry := &current.entries[cur_index]
			cur_kind, _ := plan_entry_kind_of_word(cur_entry.kind_word)
			cur_role, _ := role_contract.role_from_word(cur_entry.role_word)
			cur_rights, _ := plan_store_rights_of_word(cur_entry.store_rights_word)

			matched: ^Plan_Entry = nil
			for prop_index in u32(0) ..< proposed.entry_count {
				candidate := &proposed.entries[prop_index]
				if plan_entries_same_identity(cur_entry, candidate) {
					matched = candidate
					break
				}
			}

			if matched == nil {
				removed_bits := cur_entry.start_grants_mask
				diff.removed_grants_count += popcount_u64(removed_bits)
				switch cur_kind {
				case .None:
				case .Role_Holder:
					diff.removed_roles += 1
					diff.removed_grants_count += 1
				case .Start_Module, .Disk_Module:
					diff.removed_modules += 1
				case .Store_Grant:
					diff.removed_stores += 1
					diff.removed_grants_count += 1
				}
				append_diff_item(
					&diff,
					{
						change              = .Removed,
						entry_kind          = cur_kind,
						role                = cur_role,
						name_bytes          = cur_entry.name_bytes,
						name_length         = cur_entry.name_length,
						old_module_hash     = cur_entry.module_hash,
						removed_grants_mask = removed_bits,
						old_store_rights    = cur_rights,
					},
				)
				continue
			}

			prop_rights, _ := plan_store_rights_of_word(matched.store_rights_word)
			module_changed := cur_entry.module_hash != matched.module_hash || cur_entry.interposed_over_hash != matched.interposed_over_hash
			grants_changed := cur_entry.start_grants_mask != matched.start_grants_mask
			rights_changed := cur_rights != prop_rights
			if !module_changed && !grants_changed && !rights_changed {
				continue
			}

			added_bits := matched.start_grants_mask & ~cur_entry.start_grants_mask
			removed_bits := cur_entry.start_grants_mask & ~matched.start_grants_mask
			diff.added_grants_count += popcount_u64(added_bits)
			diff.removed_grants_count += popcount_u64(removed_bits)
			if added_bits != 0 {
				diff.any_grant_added = true
			}

			switch cur_kind {
			case .None:
			case .Role_Holder:
				diff.changed_roles += 1
				if module_changed {
					diff.added_grants_count += 1
					diff.any_grant_added = true
				}
			case .Start_Module, .Disk_Module:
				diff.changed_modules += 1
				// Granting existing start grants to a different module binary
				// introduces authority for the new module.
				if module_changed && matched.start_grants_mask != 0 {
					diff.any_grant_added = true
				}
			case .Store_Grant:
				diff.changed_stores += 1
				if cur_rights == .Read_Only && prop_rights == .Read_Write {
					diff.added_grants_count += 1
					diff.any_grant_added = true
				} else if cur_rights == .Read_Write && prop_rights == .Read_Only {
					diff.removed_grants_count += 1
				}
			}

			append_diff_item(
				&diff,
				{
					change              = .Changed,
					entry_kind          = cur_kind,
					role                = cur_role,
					name_bytes          = cur_entry.name_bytes,
					name_length         = cur_entry.name_length,
					old_module_hash     = cur_entry.module_hash,
					new_module_hash     = matched.module_hash,
					added_grants_mask   = added_bits,
					removed_grants_mask = removed_bits,
					old_store_rights    = cur_rights,
					new_store_rights    = prop_rights,
				},
			)
		}
	}

	// Pass 2: find newly added entries in proposed.
	for prop_index in u32(0) ..< proposed.entry_count {
		prop_entry := &proposed.entries[prop_index]
		found_in_current := false
		if current != nil {
			for cur_index in u32(0) ..< current.entry_count {
				if plan_entries_same_identity(&current.entries[cur_index], prop_entry) {
					found_in_current = true
					break
				}
			}
		}
		if found_in_current {
			continue
		}

		prop_kind, _ := plan_entry_kind_of_word(prop_entry.kind_word)
		prop_role, _ := role_contract.role_from_word(prop_entry.role_word)
		prop_rights, _ := plan_store_rights_of_word(prop_entry.store_rights_word)
		added_bits := prop_entry.start_grants_mask
		diff.added_grants_count += popcount_u64(added_bits)
		if added_bits != 0 {
			diff.any_grant_added = true
		}

		switch prop_kind {
		case .None:
		case .Role_Holder:
			diff.added_roles += 1
			diff.added_grants_count += 1
			diff.any_grant_added = true
		case .Start_Module, .Disk_Module:
			diff.added_modules += 1
		case .Store_Grant:
			diff.added_stores += 1
			diff.added_grants_count += 1
			diff.any_grant_added = true
		}

		append_diff_item(
			&diff,
			{
				change            = .Added,
				entry_kind        = prop_kind,
				role              = prop_role,
				name_bytes        = prop_entry.name_bytes,
				name_length       = prop_entry.name_length,
				new_module_hash   = prop_entry.module_hash,
				added_grants_mask = added_bits,
				new_store_rights  = prop_rights,
			},
		)
	}

	return diff, .None
}

// plan_difference_to_powerbox_batch constructs a validated powerbox
// Request_Batch carrying a single Plan_Difference item so the trusted Display
// holder can show Show_Plan_Difference and collect whole-plan consent.
plan_difference_to_powerbox_batch :: proc "contextless" (
	diff: ^Plan_Difference,
	request_serial: u64,
	asker_process_slot: u32,
	principal: u64,
	plans_module_hash: blake3.Hash,
	asker_label: string = "plans",
) -> (batch: powerbox.Request_Batch, refusal: Plan_Refusal) {
	if diff == nil || hash_is_zero(diff.proposed_plan_hash) {
		return {}, .Zero_Plan_Hash
	}
	if request_serial == 0 || asker_process_slot == 0 || hash_is_zero(plans_module_hash) {
		return {}, .Zero_Module_Hash
	}
	label_bytes := transmute([]u8)asker_label
	if len(label_bytes) == 0 || len(label_bytes) > powerbox.MAX_NAME_BYTES {
		return {}, .Invalid_Name
	}

	batch = {
		request_serial      = request_serial,
		asker_process_slot  = asker_process_slot,
		asker_principal     = principal,
		asker_has_window    = true,
		asker_module_origin = u64(powerbox.Module_Origin.Boot_Image),
		asker_module_hash   = plans_module_hash,
		asker_label_length  = u8(len(label_bytes)),
		item_count          = 1,
	}
	copy(batch.asker_label_bytes[:len(label_bytes)], label_bytes)
	batch.items[0] = {
		kind_word     = u64(powerbox.Request_Item_Kind.Plan_Difference),
		duration_word = u64(powerbox.Grant_Duration.None),
		reason_word   = u64(powerbox.Grant_Reason.None),
		plan_hash     = diff.proposed_plan_hash,
	}
	if pb_refusal, _ := powerbox.request_batch_validate(&batch); pb_refusal != .None {
		return {}, .Untrusted_Consent
	}
	return batch, .None
}

// plan_rollback_check validates rollback history and chooses the target
// Applied_Plan_Record. Refuses empty history, rollback from the first
// generation when no explicit target is given, unknown generations, and
// rolling back to the already-current generation.
plan_rollback_check :: proc "contextless" (
	history: []Applied_Plan_Record,
	current_generation: u64,
	target_generation: u64 = 0,
	has_target: bool = false,
) -> (selected: Applied_Plan_Record, refusal: Plan_Refusal) {
	if len(history) == 0 || current_generation == 0 {
		return {}, .Empty_History
	}

	// Validate history integrity: strictly positive, strictly increasing
	// generations, non-zero plan hashes, and consistent principal.
	principal := history[0].principal
	current_index := -1
	for record, index in history {
		if record.generation == 0 || hash_is_zero(record.plan_hash) {
			return {}, .Zero_Plan_Hash
		}
		if record.principal != principal {
			return {}, .Principal_Mismatch
		}
		if index > 0 && record.generation <= history[index - 1].generation {
			return {}, .Bad_Header
		}
		if record.generation == current_generation {
			current_index = index
		}
	}
	if current_index < 0 {
		return {}, .Unknown_Generation
	}

	if !has_target {
		if current_index == 0 {
			return {}, .Empty_History
		}
		return history[current_index - 1], .None
	}

	if target_generation == 0 {
		return {}, .Unknown_Generation
	}
	if target_generation == current_generation {
		return {}, .Already_At_Generation
	}
	for record in history {
		if record.generation == target_generation {
			return record, .None
		}
	}
	return {}, .Unknown_Generation
}

// encode_applied_plan_record writes one Applied_Plan_Record into output in the
// canonical 104-byte applied_plans store format. Refused calls leave output
// untouched.
encode_applied_plan_record :: proc "contextless" (record: ^Applied_Plan_Record, output: []u8) -> (written: int, refusal: Plan_Refusal) {
	if record == nil || hash_is_zero(record.plan_hash) {
		return 0, .Zero_Plan_Hash
	}
	if record.generation == 0 {
		return 0, .Unknown_Generation
	}
	if len(output) < APPLIED_PLAN_WIRE_SIZE {
		return 0, .Buffer_Too_Small
	}
	magic := APPLIED_PLAN_MAGIC
	copy(output[0:8], magic[:])
	byte_order.write_u32_little_endian(output, 8, APPLIED_PLAN_WIRE_VERSION)
	byte_order.write_u32_little_endian(output, 12, 0)
	copy(output[16:48], record.plan_hash[:])
	copy(output[48:80], record.previous_plan_hash[:])
	byte_order.write_u64_little_endian(output, 80, record.generation)
	byte_order.write_u64_little_endian(output, 88, record.timestamp_ms)
	byte_order.write_u64_little_endian(output, 96, record.principal)
	return APPLIED_PLAN_WIRE_SIZE, .None
}

// decode_applied_plan_record strictly validates and decodes an exact 104-byte
// applied_plans store record.
decode_applied_plan_record :: proc "contextless" (input: []u8) -> (record: Applied_Plan_Record, refusal: Plan_Refusal) {
	if len(input) < APPLIED_PLAN_WIRE_SIZE {
		return {}, .Truncated
	}
	if len(input) > APPLIED_PLAN_WIRE_SIZE {
		return {}, .Trailing_Bytes
	}
	magic := APPLIED_PLAN_MAGIC
	for index in 0 ..< len(magic) {
		if input[index] != magic[index] {
			return {}, .Bad_Header
		}
	}
	if byte_order.read_u32_little_endian(input, 8) != APPLIED_PLAN_WIRE_VERSION {
		return {}, .Bad_Header
	}
	if byte_order.read_u32_little_endian(input, 12) != 0 {
		return {}, .Bad_Header
	}
	copy(record.plan_hash[:], input[16:48])
	copy(record.previous_plan_hash[:], input[48:80])
	if hash_is_zero(record.plan_hash) {
		return {}, .Zero_Plan_Hash
	}
	record.generation = byte_order.read_u64_little_endian(input, 80)
	if record.generation == 0 {
		return {}, .Unknown_Generation
	}
	record.timestamp_ms = byte_order.read_u64_little_endian(input, 88)
	record.principal = byte_order.read_u64_little_endian(input, 96)
	return record, .None
}
