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

// The bytes of the name of an entry.
MAX_ENTRY_NAME_BYTES :: 64

// The largest count of entries of a plan. A plan holds its entries in the
// memory of its owner, so no count of the contract bounds it; this is the
// bound of the representation: an index of the order of a plan keeps its
// top bit for plan_validate.
PLAN_ENTRY_COUNT_LIMIT :: u32(1) << 31 - 1
@(private = "file")
PLAN_ORDER_MARK :: u32(1) << 31

#assert(APPLIED_PLAN_WIRE_SIZE == 104)

// Closed set of entry kinds carried inside a Plan_Spec.
// Zero means unset and is refused at the border.
Plan_Entry_Kind :: enum u8 {
	None         = 0,
	Role_Holder  = 1,
	Start_Module = 2,
	Disk_Module  = 3,
	Store_Grant  = 4,
	// The script font set of the machine (src/md/features/script_fonts.md):
	// module_hash is the hash of the data object, and the name is
	// SCRIPT_FONTS_ENTRY_NAME. Only the plan of principal 0 names one, at
	// most one; the root service reads it at the next start of the machine.
	Script_Fonts = 5,
}

// The name of the one entry Script_Fonts of a plan.
SCRIPT_FONTS_ENTRY_NAME :: "script_fonts"

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
	No_Change              = 25, // The plan is the current plan: the trusted display has nothing to show.
	Apply_Pending          = 26, // An apply or a rollback of the principal waits for the decision of the trusted display.
	No_Pending_Apply       = 27, // No apply, or no rollback, of the principal waits under this ticket.
	Refused_By_Principal   = 28, // The principal refused the difference on the trusted display.
	Display_Refused        = 29, // The trusted display did not show the difference whole, so nobody accepted it.
	Store_Failed           = 30, // The private store did not take a write: nothing was committed.
	Store_Damaged          = 31, // A record of the private store does not decode or does not match its hash.
	Roles_Refused          = 32, // The root service refused the roles of the plan of principal 0: nothing was committed.
	No_Memory              = 33, // The budget of the service pays no more memory for the plan, its difference or its lists: nothing changed.
	Machine_Only           = 34, // The entry names a part of the machine, which only the plan of principal 0 names.
}

// Closed set of completion statuses returned on the recipes and projects
// service rings.
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
// the plans service and root service. Its tables are memory of its owner,
// and their lengths are its capacity: entries holds the entries, and order
// one index for each entry, which plan_validate writes. After a
// plan_validate with no refusal, order[:entry_count] names the entries in
// their canonical order, which plan_hash and plan_diff_compute read.
Plan_Spec :: struct {
	principal:   u64,
	entry_count: u32,
	entries:     []Plan_Entry,
	order:       []u32,
}

// plan_bytes_for gives the bytes of the memory of a plan of count entries:
// the entries, then the order. ok is false past PLAN_ENTRY_COUNT_LIMIT.
plan_bytes_for :: proc "contextless" (count: int) -> (bytes: int, ok: bool) {
	if count < 0 || count > int(PLAN_ENTRY_COUNT_LIMIT) {
		return 0, false
	}
	return count * (size_of(Plan_Entry) + size_of(u32)), true
}

// plan_of_memory gives an empty plan of principal whose tables are memory:
// as many entries as it holds. memory starts at a multiple of 8.
plan_of_memory :: proc "contextless" (principal: u64, memory: []u8) -> (plan: Plan_Spec) {
	capacity := min(len(memory) / (size_of(Plan_Entry) + size_of(u32)), int(PLAN_ENTRY_COUNT_LIMIT))
	plan.principal = principal
	if capacity == 0 {
		return
	}
	plan.entries = ([^]Plan_Entry)(raw_data(memory))[:capacity]
	plan.order = ([^]u32)(raw_data(memory[capacity * size_of(Plan_Entry):]))[:capacity]
	return
}

// plan_clear makes a plan empty and keeps its memory.
plan_clear :: proc "contextless" (plan: ^Plan_Spec) {
	plan^ = {entries = plan.entries, order = plan.order}
}

// plan_copy makes destination hold the plan source, in the memory of
// destination: false when it has no room, and destination does not change.
plan_copy :: proc "contextless" (destination, source: ^Plan_Spec) -> bool {
	count := int(source.entry_count)
	if count > len(source.entries) || count > len(source.order) || count > len(destination.entries) || count > len(destination.order) {
		return false
	}
	copy(destination.entries[:count], source.entries[:count])
	copy(destination.order[:count], source.order[:count])
	destination.principal = source.principal
	destination.entry_count = source.entry_count
	return true
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
	// Memory of the caller: plan_diff_compute needs one item for each entry
	// of the two plans (plan_difference_changes_most).
	changes:              []Plan_Diff_Item,
	// The block that changes lies in when the plans core took it from its
	// memory, which gives it back; nil when the caller gave the changes.
	changes_memory:       []u8,
}

// plan_difference_changes_most gives the most items of a difference of
// current (nil: no plan) and proposed: each entry of current removed and
// each entry of proposed added.
plan_difference_changes_most :: proc "contextless" (current, proposed: ^Plan_Spec) -> int {
	most := 0
	if current != nil {
		most += int(current.entry_count)
	}
	if proposed != nil {
		most += int(proposed.entry_count)
	}
	return most
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

// plan_entry_make_script_fonts constructs the Script_Fonts entry that names
// the script font set by its hash.
plan_entry_make_script_fonts :: proc "contextless" (set_hash: blake3.Hash) -> (entry: Plan_Entry, ok: bool) {
	if hash_is_zero(set_hash) {
		return {}, false
	}
	entry.name_length = u8(copy(entry.name_bytes[:], SCRIPT_FONTS_ENTRY_NAME))
	entry.kind_word = u64(Plan_Entry_Kind.Script_Fonts)
	entry.module_hash = set_hash
	return entry, true
}

// plan_script_fonts gives the hash of the script font set that a plan
// names, or found false: the plan names none.
plan_script_fonts :: proc "contextless" (plan: ^Plan_Spec) -> (set_hash: blake3.Hash, found: bool) {
	for entry in plan.entries[:min(int(plan.entry_count), len(plan.entries))] {
		if entry.kind_word == u64(Plan_Entry_Kind.Script_Fonts) {
			return entry.module_hash, true
		}
	}
	return {}, false
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

// plan_validate strictly checks every entry of plan at the border, and
// writes in its order the canonical order of its entries.
// Refuses empty plans, a count past its memory, unknown enum words, zero module
// hashes, invalid names or non-zero padding, unknown or System_Part start grant
// bits, non-principal-0 trusted-path role holders, duplicate entries, and
// cyclic role interposition chains. bad_index is the first entry that a
// check refuses, in the order of the entries: an entry that repeats an
// earlier one is refused at the later index. The checks sort the order
// and search it, so a plan of any count costs n log n.
plan_validate :: proc "contextless" (plan: ^Plan_Spec) -> (refusal: Plan_Refusal, bad_index: u32) {
	if plan == nil || plan.entry_count == 0 {
		return .Empty_Plan, 0
	}
	if plan.entry_count > PLAN_ENTRY_COUNT_LIMIT || int(plan.entry_count) > len(plan.entries) {
		return .Too_Many_Entries, 0
	}
	if int(plan.entry_count) > len(plan.order) {
		return .Buffer_Too_Small, 0
	}
	count := plan.entry_count
	first_invalid := count
	invalid_refusal := Plan_Refusal.None
	for index in u32(0) ..< count {
		if entry_refusal := plan_entry_check(plan, &plan.entries[index]); entry_refusal != .None {
			first_invalid = index
			invalid_refusal = entry_refusal
			break
		}
	}
	// The repeats among the entries before the first invalid one: an entry
	// is checked whole before it is compared with the entries before it.
	first_repeat := plan_first_repeat(plan, first_invalid)
	if first_invalid < count && first_invalid <= first_repeat {
		return invalid_refusal, first_invalid
	}
	if first_repeat < count {
		return .Duplicate_Entry, first_repeat
	}
	if chain_refusal, chain_index := plan_chains_check(plan); chain_refusal != .None {
		return chain_refusal, chain_index
	}
	plan_order_fill(plan, count)
	plan_order_sort(plan, plan.order[:count], .Identity)
	return .None, 0
}

// The check of one entry alone.
@(private = "file")
plan_entry_check :: proc "contextless" (plan: ^Plan_Spec, entry: ^Plan_Entry) -> Plan_Refusal {
	kind, kind_ok := plan_entry_kind_of_word(entry.kind_word)
	if !kind_ok {
		return .Bad_Entry_Kind
	}
	if !entry_name_valid(entry.name_bytes[:], entry.name_length) {
		return .Invalid_Name
	}
	if !start_grants_mask_valid(entry.start_grants_mask) {
		return .Bad_Start_Grant
	}
	switch kind {
	case .None:
		return .Bad_Entry_Kind
	case .Role_Holder:
		role, role_ok := role_contract.role_from_word(entry.role_word)
		if !role_ok {
			return .Bad_Role
		}
		if !role_contract.disk_holder_allowed_for_principal(role, plan.principal) {
			return .Trusted_Path_Forbidden
		}
		if hash_is_zero(entry.module_hash) {
			return .Zero_Module_Hash
		}
		if entry.store_rights_word != 0 {
			return .Bad_Store_Rights
		}
		if !hash_is_zero(entry.interposed_over_hash) && entry.interposed_over_hash == entry.module_hash {
			return .Cyclic_Role_Chain
		}
	case .Start_Module, .Disk_Module:
		if entry.role_word != 0 {
			return .Bad_Role
		}
		if hash_is_zero(entry.module_hash) {
			return .Zero_Module_Hash
		}
		if !hash_is_zero(entry.interposed_over_hash) {
			return .Bad_Role
		}
		if entry.store_rights_word != 0 {
			return .Bad_Store_Rights
		}
	case .Store_Grant:
		if entry.role_word != 0 {
			return .Bad_Role
		}
		if !hash_is_zero(entry.module_hash) || !hash_is_zero(entry.interposed_over_hash) {
			return .Bad_Entry_Kind
		}
		if entry.start_grants_mask != 0 {
			return .Bad_Start_Grant
		}
		if _, rights_ok := plan_store_rights_of_word(entry.store_rights_word); !rights_ok {
			return .Bad_Store_Rights
		}
	case .Script_Fonts:
		if plan.principal != 0 {
			return .Machine_Only
		}
		if string(entry.name_bytes[:entry.name_length]) != SCRIPT_FONTS_ENTRY_NAME {
			return .Invalid_Name
		}
		if entry.role_word != 0 {
			return .Bad_Role
		}
		if hash_is_zero(entry.module_hash) {
			return .Zero_Module_Hash
		}
		if !hash_is_zero(entry.interposed_over_hash) {
			return .Bad_Entry_Kind
		}
		if entry.start_grants_mask != 0 {
			return .Bad_Start_Grant
		}
		if entry.store_rights_word != 0 {
			return .Bad_Store_Rights
		}
	}
	return .None
}

// The two orders of the entries that the checks sort: by identity (the
// kind, the role, the name), which is the canonical order once no two
// entries share an identity, and by module (the kind, the role, the module
// hash), where the holders of one role are together and found by their
// module. The index of the entry ends each tie, so a group of equal keys
// is in the order of the entries.
@(private = "file")
Plan_Order_Key :: enum u8 {
	Identity,
	Module,
}

@(private = "file")
plan_order_fill :: proc "contextless" (plan: ^Plan_Spec, count: u32) {
	for index in u32(0) ..< count {
		plan.order[index] = index
	}
}

@(private = "file")
plan_key_compare :: proc "contextless" (plan: ^Plan_Spec, key: Plan_Order_Key, left, right: u32) -> int {
	first := &plan.entries[left & ~PLAN_ORDER_MARK]
	second := &plan.entries[right & ~PLAN_ORDER_MARK]
	if first.kind_word != second.kind_word {
		return first.kind_word < second.kind_word ? -1 : 1
	}
	if first.role_word != second.role_word {
		return first.role_word < second.role_word ? -1 : 1
	}
	switch key {
	case .Identity:
		if order := compare_bytes(first.name_bytes[:first.name_length], second.name_bytes[:second.name_length]); order != 0 {
			return order
		}
	case .Module:
		if order := compare_bytes(first.module_hash[:], second.module_hash[:]); order != 0 {
			return order
		}
	}
	left_index, right_index := left & ~PLAN_ORDER_MARK, right & ~PLAN_ORDER_MARK
	if left_index != right_index {
		return left_index < right_index ? -1 : 1
	}
	return 0
}

// plan_order_sort sorts order by key, in place, with a heap sort: no
// memory but order, and n log n in the worst case.
@(private = "file")
plan_order_sort :: proc "contextless" (plan: ^Plan_Spec, order: []u32, key: Plan_Order_Key) {
	sift_down :: proc "contextless" (plan: ^Plan_Spec, order: []u32, key: Plan_Order_Key, start, end: int) {
		root := start
		for {
			child := 2 * root + 1
			if child >= end {
				return
			}
			if child + 1 < end && plan_key_compare(plan, key, order[child], order[child + 1]) < 0 {
				child += 1
			}
			if plan_key_compare(plan, key, order[root], order[child]) >= 0 {
				return
			}
			order[root], order[child] = order[child], order[root]
			root = child
		}
	}
	count := len(order)
	for start := count / 2 - 1; start >= 0; start -= 1 {
		sift_down(plan, order, key, start, count)
	}
	for end := count - 1; end > 0; end -= 1 {
		order[0], order[end] = order[end], order[0]
		sift_down(plan, order, key, 0, end)
	}
}

// plan_first_repeat gives the first index, among the first count entries,
// of an entry that repeats an earlier one, or plan.entry_count: an identity
// that an earlier entry has, a second holder of a role that allows one
// holder, or a second holder of a role with the module of an earlier
// holder.
@(private = "file")
plan_first_repeat :: proc "contextless" (plan: ^Plan_Spec, count: u32) -> (first: u32) {
	first = plan.entry_count
	order := plan.order[:count]
	plan_order_fill(plan, count)
	plan_order_sort(plan, order, .Identity)
	for position in 1 ..< max(len(order), 1) {
		earlier, later := order[position - 1], order[position]
		if plan_entries_same_identity(&plan.entries[earlier], &plan.entries[later]) {
			first = min(first, later)
		}
	}
	plan_order_fill(plan, count)
	plan_order_sort(plan, order, .Module)
	holder := u64(Plan_Entry_Kind.Role_Holder)
	group_start := 0
	for group_start < len(order) {
		group_entry := &plan.entries[order[group_start]]
		group_end := group_start + 1
		for group_end < len(order) && plan.entries[order[group_end]].kind_word == group_entry.kind_word && plan.entries[order[group_end]].role_word == group_entry.role_word {
			group_end += 1
		}
		if group_entry.kind_word == holder && group_end - group_start > 1 {
			role, _ := role_contract.role_from_word(group_entry.role_word)
			if !role_contract.role_allows_multiple_holders(role) {
				// Each holder after the first by index repeats it.
				lowest, second := plan.entry_count, plan.entry_count
				for index in order[group_start:group_end] {
					if index < lowest {
						lowest, second = index, lowest
					} else if index < second {
						second = index
					}
				}
				first = min(first, second)
			} else {
				for position in group_start + 1 ..< group_end {
					if plan.entries[order[position - 1]].module_hash == plan.entries[order[position]].module_hash {
						first = min(first, order[position])
					}
				}
			}
		}
		group_start = group_end
	}
	return first
}

// plan_holder_find gives the place in order, sorted by module, of the
// holder of role whose module is module_hash.
@(private = "file")
plan_holder_find :: proc "contextless" (plan: ^Plan_Spec, order: []u32, role_word: u64, module_hash: blake3.Hash) -> (position: int, found: bool) {
	holder := u64(Plan_Entry_Kind.Role_Holder)
	before :: proc "contextless" (entry: ^Plan_Entry, kind, role_word: u64, module_hash: blake3.Hash) -> bool {
		if entry.kind_word != kind {
			return entry.kind_word < kind
		}
		if entry.role_word != role_word {
			return entry.role_word < role_word
		}
		module := module_hash
		return compare_bytes(entry.module_hash[:], module[:]) < 0
	}
	low, high := 0, len(order)
	for low < high {
		middle := low + (high - low) / 2
		if before(&plan.entries[order[middle] & ~PLAN_ORDER_MARK], holder, role_word, module_hash) {
			low = middle + 1
		} else {
			high = middle
		}
	}
	if low == len(order) {
		return 0, false
	}
	entry := &plan.entries[order[low] & ~PLAN_ORDER_MARK]
	return low, entry.kind_word == holder && entry.role_word == role_word && entry.module_hash == module_hash
}

// plan_chains_check refuses a holder whose chain of interposition comes
// back to it, or runs longer than the plan: a cycle. Each chain is walked
// once: a holder whose chain ends gets the mark in the order, and a walk
// that reaches a marked holder ends there.
@(private = "file")
plan_chains_check :: proc "contextless" (plan: ^Plan_Spec) -> (refusal: Plan_Refusal, bad_index: u32) {
	count := plan.entry_count
	order := plan.order[:count]
	plan_order_fill(plan, count)
	plan_order_sort(plan, order, .Module)
	holder := u64(Plan_Entry_Kind.Role_Holder)
	for index in u32(0) ..< count {
		entry := &plan.entries[index]
		if entry.kind_word != holder || hash_is_zero(entry.interposed_over_hash) {
			continue
		}
		cursor := entry.interposed_over_hash
		for hop in u32(0) ..< count {
			if cursor == entry.module_hash {
				return .Cyclic_Role_Chain, index
			}
			position, found := plan_holder_find(plan, order, entry.role_word, cursor)
			if !found || order[position] & PLAN_ORDER_MARK != 0 {
				break
			}
			next := &plan.entries[order[position]]
			if hash_is_zero(next.interposed_over_hash) {
				break
			}
			cursor = next.interposed_over_hash
			if hop == count - 1 {
				return .Cyclic_Role_Chain, index
			}
		}
		// The chain ends: each holder on it ends too.
		mark := entry.module_hash
		for {
			position, found := plan_holder_find(plan, order, entry.role_word, mark)
			if !found || order[position] & PLAN_ORDER_MARK != 0 {
				break
			}
			order[position] |= PLAN_ORDER_MARK
			next := &plan.entries[order[position] & ~PLAN_ORDER_MARK]
			if hash_is_zero(next.interposed_over_hash) {
				break
			}
			mark = next.interposed_over_hash
		}
	}
	return .None, 0
}

// plan_identity_find gives the entry of plan with the identity of entry,
// or nil: a search of its canonical order, which plan_validate wrote.
@(private = "file")
plan_identity_find :: proc "contextless" (plan: ^Plan_Spec, entry: ^Plan_Entry) -> ^Plan_Entry {
	before :: proc "contextless" (candidate, entry: ^Plan_Entry) -> bool {
		if candidate.kind_word != entry.kind_word {
			return candidate.kind_word < entry.kind_word
		}
		if candidate.role_word != entry.role_word {
			return candidate.role_word < entry.role_word
		}
		return compare_bytes(candidate.name_bytes[:candidate.name_length], entry.name_bytes[:entry.name_length]) < 0
	}
	order := plan.order[:plan.entry_count]
	low, high := 0, len(order)
	for low < high {
		middle := low + (high - low) / 2
		if before(&plan.entries[order[middle]], entry) {
			low = middle + 1
		} else {
			high = middle
		}
	}
	if low < len(order) && plan_entries_same_identity(&plan.entries[order[low]], entry) {
		return &plan.entries[order[low]]
	}
	return nil
}

// The bytes of one entry in the canonical form that plan_hash hashes, with
// room for its longest name.
@(private = "file")
PLAN_ENTRY_CANONICAL_MOST :: 8 + 4 + MAX_ENTRY_NAME_BYTES + 8 + 3 * blake3.HASH_SIZE + 8 + 8

// plan_hash validates plan and computes its canonical order-independent
// domain-separated BLAKE3 digest: a chain over the entries in their
// canonical order, each link the hash of the link before and of one entry,
// so a plan of any count hashes in memory of one entry.
plan_hash :: proc "contextless" (plan: ^Plan_Spec) -> (digest: blake3.Hash, refusal: Plan_Refusal) {
	validation_refusal, _ := plan_validate(plan)
	if validation_refusal != .None {
		return {}, validation_refusal
	}
	head: [12]u8
	byte_order.write_u64_little_endian(head[:], 0, plan.principal)
	byte_order.write_u32_little_endian(head[:], 8, plan.entry_count)
	digest = blake3.derive_key(PLAN_HASH_DOMAIN, head[:])
	link: [blake3.HASH_SIZE + PLAN_ENTRY_CANONICAL_MOST]u8
	for position in u32(0) ..< plan.entry_count {
		entry := &plan.entries[plan.order[position]]
		copy(link[:blake3.HASH_SIZE], digest[:])
		encoder := Canonical_Encoder{buffer = link[blake3.HASH_SIZE:]}
		encoder_u64(&encoder, entry.kind_word)
		encoder_bytes(&encoder, entry.name_bytes[:entry.name_length])
		encoder_u64(&encoder, entry.role_word)
		encoder_raw_bytes(&encoder, entry.module_hash[:])
		encoder_raw_bytes(&encoder, entry.interposed_over_hash[:])
		encoder_raw_bytes(&encoder, entry.recipe_hash[:])
		encoder_u64(&encoder, entry.start_grants_mask)
		encoder_u64(&encoder, entry.store_rights_word)
		if encoder.overflow {
			return {}, .Buffer_Too_Small
		}
		digest = blake3.derive_key(PLAN_HASH_DOMAIN, link[:blake3.HASH_SIZE + encoder.position])
	}
	return digest, .None
}

@(private = "file")
reserve_diff_item :: proc "contextless" (diff: ^Plan_Difference) -> ^Plan_Diff_Item {
	diff.has_changes = true
	if int(diff.change_count) >= len(diff.changes) {
		return nil
	}
	slot := &diff.changes[diff.change_count]
	diff.change_count += 1
	slot^ = {}
	return slot
}

// plan_diff_compute computes the complete grant, role, module, and store
// difference between current (nil when no plan is applied yet) and proposed,
// writing the result in place into caller-supplied out_diff so the large
// Plan_Difference record is never copied by value. Sets any_grant_added
// whenever any start grant, store right, or role authority is newly granted
// or widened.
plan_diff_compute :: proc "contextless" (current: ^Plan_Spec, proposed: ^Plan_Spec, out_diff: ^Plan_Difference) -> Plan_Refusal {
	if out_diff == nil {
		return .Buffer_Too_Small
	}
	changes, changes_memory := out_diff.changes, out_diff.changes_memory
	out_diff^ = {changes = changes, changes_memory = changes_memory}
	if current != nil {
		current_hash, current_refusal := plan_hash(current)
		if current_refusal != .None {
			return current_refusal
		}
		out_diff.current_plan_hash = current_hash
	}
	proposed_hash, proposed_refusal := plan_hash(proposed)
	if proposed_refusal != .None {
		out_diff^ = {changes = changes, changes_memory = changes_memory}
		return proposed_refusal
	}
	if current != nil && current.principal != proposed.principal {
		out_diff^ = {changes = changes, changes_memory = changes_memory}
		return .Principal_Mismatch
	}
	// Room for each item that the two plans can give, before any item: a
	// difference is whole or refused.
	if len(changes) < plan_difference_changes_most(current, proposed) {
		out_diff^ = {changes = changes, changes_memory = changes_memory}
		return .Buffer_Too_Small
	}
	out_diff.proposed_plan_hash = proposed_hash

	// Pass 1: find removed and changed entries from current.
	if current != nil {
		for cur_index in u32(0) ..< current.entry_count {
			cur_entry := &current.entries[cur_index]
			cur_kind, _ := plan_entry_kind_of_word(cur_entry.kind_word)
			cur_role, _ := role_contract.role_from_word(cur_entry.role_word)
			cur_rights, _ := plan_store_rights_of_word(cur_entry.store_rights_word)

			matched := plan_identity_find(proposed, cur_entry)

			if matched == nil {
				removed_bits := cur_entry.start_grants_mask
				out_diff.removed_grants_count += popcount_u64(removed_bits)
				switch cur_kind {
				case .None:
				case .Role_Holder:
					out_diff.removed_roles += 1
					out_diff.removed_grants_count += 1
				case .Start_Module, .Disk_Module:
					out_diff.removed_modules += 1
				case .Store_Grant:
					out_diff.removed_stores += 1
					out_diff.removed_grants_count += 1
				case .Script_Fonts:
				// A change of the script font set grants nothing: its item
				// says it, and no count holds it.
				}
				if item := reserve_diff_item(out_diff); item != nil {
					item.change = .Removed
					item.entry_kind = cur_kind
					item.role = cur_role
					item.name_bytes = cur_entry.name_bytes
					item.name_length = cur_entry.name_length
					item.old_module_hash = cur_entry.module_hash
					item.removed_grants_mask = removed_bits
					item.old_store_rights = cur_rights
				}
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
			out_diff.added_grants_count += popcount_u64(added_bits)
			out_diff.removed_grants_count += popcount_u64(removed_bits)
			if added_bits != 0 {
				out_diff.any_grant_added = true
			}

			switch cur_kind {
			case .None:
			case .Role_Holder:
				out_diff.changed_roles += 1
				if module_changed {
					out_diff.added_grants_count += 1
					out_diff.any_grant_added = true
				}
			case .Start_Module, .Disk_Module:
				out_diff.changed_modules += 1
				// Granting existing start grants to a different module binary
				// introduces authority for the new module.
				if module_changed && matched.start_grants_mask != 0 {
					out_diff.any_grant_added = true
				}
			case .Store_Grant:
				out_diff.changed_stores += 1
				if cur_rights == .Read_Only && prop_rights == .Read_Write {
					out_diff.added_grants_count += 1
					out_diff.any_grant_added = true
				} else if cur_rights == .Read_Write && prop_rights == .Read_Only {
					out_diff.removed_grants_count += 1
				}
			case .Script_Fonts:
			}

			if item := reserve_diff_item(out_diff); item != nil {
				item.change = .Changed
				item.entry_kind = cur_kind
				item.role = cur_role
				item.name_bytes = cur_entry.name_bytes
				item.name_length = cur_entry.name_length
				item.old_module_hash = cur_entry.module_hash
				item.new_module_hash = matched.module_hash
				item.added_grants_mask = added_bits
				item.removed_grants_mask = removed_bits
				item.old_store_rights = cur_rights
				item.new_store_rights = prop_rights
			}
		}
	}

	// Pass 2: find newly added entries in proposed.
	for prop_index in u32(0) ..< proposed.entry_count {
		prop_entry := &proposed.entries[prop_index]
		if current != nil && plan_identity_find(current, prop_entry) != nil {
			continue
		}

		prop_kind, _ := plan_entry_kind_of_word(prop_entry.kind_word)
		prop_role, _ := role_contract.role_from_word(prop_entry.role_word)
		prop_rights, _ := plan_store_rights_of_word(prop_entry.store_rights_word)
		added_bits := prop_entry.start_grants_mask
		out_diff.added_grants_count += popcount_u64(added_bits)
		if added_bits != 0 {
			out_diff.any_grant_added = true
		}

		switch prop_kind {
		case .None:
		case .Role_Holder:
			out_diff.added_roles += 1
			out_diff.added_grants_count += 1
			out_diff.any_grant_added = true
		case .Start_Module, .Disk_Module:
			out_diff.added_modules += 1
		case .Store_Grant:
			out_diff.added_stores += 1
			out_diff.added_grants_count += 1
			out_diff.any_grant_added = true
		case .Script_Fonts:
		}

		if item := reserve_diff_item(out_diff); item != nil {
			item.change = .Added
			item.entry_kind = prop_kind
			item.role = prop_role
			item.name_bytes = prop_entry.name_bytes
			item.name_length = prop_entry.name_length
			item.new_module_hash = prop_entry.module_hash
			item.added_grants_mask = added_bits
			item.new_store_rights = prop_rights
		}
	}

	return .None
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
