// The private store of the services of the declarations, and the records
// that they keep in it (src/md/features/declarations.md, "Storage").
//
// A service reaches its private store through Private_Store_Port: one read
// and one write of a whole object by its name. The service binds the port to
// its storage client; a host test binds it to Memory_Private_Store. Each
// write of a whole object is one commit of the storage service, so a record
// that a reader finds is whole or absent.
//
// The plans service keeps, for each principal:
//
// - one generation object for each applied plan, "plan_<principal>_<n>":
//   the applied plan record and the rows of its plan;
// - one current object, "plan_<principal>_current": the current and the
//   highest generation. Its write is the commit of an apply and of a
//   rollback: a stop before it leaves a generation object that no current
//   object names, which the next apply writes again.
//
// The recipes service keeps one realisation object for each recipe that it
// realised, "realisation_<recipe hash>": the realisation record, its origin
// and the bytes of its output, so a build of the same recipe after a start
// takes it from the store and builds nothing.
//
// The projects service keeps one project object for each project of a
// principal, "project_<principal>_<hash of the name>": the name, the
// evaluation of its project.lex and the text of its pins.lex, in one write,
// so a pin and the project that it belongs to never disagree.
package plans_recipes

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/isolated"
import "modus:contract/object_cache"

// The outcome of one access of the private store.
Private_Store_Status :: enum u8 {
	Ok        = 0,
	Absent    = 1, // No object has this name.
	Too_Large = 2, // The object has more bytes than the place that the reader gave.
	Failed    = 3, // The storage service refused the access, or the port has no store.
}

// The port of a private store: a read and a write of a whole object.
Private_Store_Port :: struct {
	user:  rawptr,
	read:  proc "contextless" (user: rawptr, name: string, into: []u8) -> (count: int, status: Private_Store_Status),
	write: proc "contextless" (user: rawptr, name: string, data: []u8) -> Private_Store_Status,
}

// private_store_read reads the object name whole into into. A port with no
// procedure fails: a service with no store keeps nothing.
private_store_read :: proc "contextless" (port: ^Private_Store_Port, name: string, into: []u8) -> (bytes: []u8, status: Private_Store_Status) {
	if port == nil || port.read == nil {
		return nil, .Failed
	}
	count: int
	count, status = port.read(port.user, name, into)
	if status != .Ok {
		return nil, status
	}
	if count < 0 || count > len(into) {
		return nil, .Too_Large
	}
	return into[:count], .Ok
}

// private_store_write makes the object name the bytes of data, in one commit.
private_store_write :: proc "contextless" (port: ^Private_Store_Port, name: string, data: []u8) -> Private_Store_Status {
	if port == nil || port.write == nil {
		return .Failed
	}
	return port.write(port.user, name, data)
}

// The objects and the bytes of each object of a memory store.
MEMORY_PRIVATE_STORE_OBJECTS :: 64
MEMORY_PRIVATE_STORE_OBJECT_BYTES :: 8192
MEMORY_PRIVATE_STORE_NAME_BYTES :: 64

// One object of a memory store.
Memory_Private_Object :: struct {
	used:        bool,
	name:        [MEMORY_PRIVATE_STORE_NAME_BYTES]u8,
	name_length: int,
	length:      int,
	bytes:       [MEMORY_PRIVATE_STORE_OBJECT_BYTES]u8,
}

// A private store in memory, for a host test: it has the semantics of the
// port, and it can refuse each write after a count, as a store that a stop
// ends between two commits.
Memory_Private_Store :: struct {
	objects:        [MEMORY_PRIVATE_STORE_OBJECTS]Memory_Private_Object,
	writes:         int,
	reads:          int,
	writes_allowed: int, // The writes that succeed before each write fails; -1: no bound.
}

// memory_private_store_port gives the port of a memory store, with no bound
// of the writes.
memory_private_store_port :: proc "contextless" (store: ^Memory_Private_Store) -> Private_Store_Port {
	store.writes_allowed = -1
	return {user = store, read = memory_private_store_read, write = memory_private_store_write}
}

// memory_private_store_find gives the object name of a memory store, or nil.
memory_private_store_find :: proc "contextless" (store: ^Memory_Private_Store, name: string) -> ^Memory_Private_Object {
	for &object in store.objects {
		if object.used && string(object.name[:object.name_length]) == name {
			return &object
		}
	}
	return nil
}

@(private = "file")
memory_private_store_read :: proc "contextless" (user: rawptr, name: string, into: []u8) -> (count: int, status: Private_Store_Status) {
	store := (^Memory_Private_Store)(user)
	store.reads += 1
	object := memory_private_store_find(store, name)
	if object == nil {
		return 0, .Absent
	}
	if object.length > len(into) {
		return 0, .Too_Large
	}
	copy(into, object.bytes[:object.length])
	return object.length, .Ok
}

@(private = "file")
memory_private_store_write :: proc "contextless" (user: rawptr, name: string, data: []u8) -> Private_Store_Status {
	store := (^Memory_Private_Store)(user)
	if store.writes_allowed >= 0 && store.writes >= store.writes_allowed {
		return .Failed
	}
	if len(name) == 0 || len(name) > MEMORY_PRIVATE_STORE_NAME_BYTES || len(data) > MEMORY_PRIVATE_STORE_OBJECT_BYTES {
		return .Failed
	}
	object := memory_private_store_find(store, name)
	if object == nil {
		for &candidate in store.objects {
			if !candidate.used {
				object = &candidate
				break
			}
		}
	}
	if object == nil {
		return .Failed
	}
	object.used = true
	copy(object.name[:], name)
	object.name_length = len(name)
	copy(object.bytes[:], data)
	object.length = len(data)
	store.writes += 1
	return .Ok
}

// The bounds of the dialog of a difference on the trusted display: a plan
// name, an item of a side, and the items of one side. The compositor checks
// its own bounds against these.
PLAN_DISPLAY_NAME_BYTES :: 48
PLAN_DISPLAY_ITEM_BYTES :: 48
PLAN_DISPLAY_ITEM_CAPACITY :: 8

// The arm time of the dialog of a difference: the trusted display takes a
// decision only this long after it showed the difference, so a key or a
// press meant for a window does not accept the plan. A caller of apply
// knows from it when a key of the principal counts.
PLAN_DISPLAY_ARM_MILLISECONDS :: 500

// The amount (isolated.CALLER_AMOUNT_MASK) of the grant of a connection to
// the holder of Display whose caller holds the role Plans now. Each service
// gives the amount its own meaning; the root service writes this one, and
// writes the grant of each such connection again when the roles change, so
// a module that lost the role Plans loses it. The holder of Plans acts for
// nobody: this amount, not the grant to act for the principal, lets the
// display show it a difference.
DISPLAY_AMOUNT_PLANS_HOLDER :: u64(1)

// plan_display_caller_allowed says if the trusted display serves
// plan_diff_ask and plan_diff_poll to a connection with this grant: the
// holder of Plans, or a caller that acts for its principal.
//
// Example: `plan_display_caller_allowed(DISPLAY_AMOUNT_PLANS_HOLDER)` is
// true; `plan_display_caller_allowed(0)` is false.
plan_display_caller_allowed :: proc "contextless" (grant: u64) -> bool {
	return grant & isolated.CALLER_ACTS_FOR_PRINCIPAL != 0 || grant & isolated.CALLER_AMOUNT_MASK == DISPLAY_AMOUNT_PLANS_HOLDER
}

// The amount of the grant of a connection to the holder of Display whose
// caller may ask the principal to decide one act of an agent: a process
// whose start grant set has the term asks_acts, as the assistant
// (src/md/features/assistant.md, "The right to ask an act"). It is not the
// grant to act for the principal, which would open each export of the
// display that serves the principal.
DISPLAY_AMOUNT_ACT_ASKER :: u64(2)

// act_display_caller_allowed says if the trusted display serves act_ask,
// act_poll and act_cancel to a connection with this grant: an asker of
// acts, or a caller that acts for its principal.
//
// Example: `act_display_caller_allowed(DISPLAY_AMOUNT_ACT_ASKER)` is true;
// `act_display_caller_allowed(DISPLAY_AMOUNT_PLANS_HOLDER)` is false.
act_display_caller_allowed :: proc "contextless" (grant: u64) -> bool {
	return grant & isolated.CALLER_ACTS_FOR_PRINCIPAL != 0 || grant & isolated.CALLER_AMOUNT_MASK == DISPLAY_AMOUNT_ACT_ASKER
}

// The decision of the trusted display on the difference of a plan, as the
// export plan_diff_poll of the Display role gives it. The values cross the
// border of the export: the compositor writes i64(member).
Plan_Display_Decision :: enum u64 {
	Pending  = 0, // The dialog of the difference still shows.
	Accepted = 1,
	Refused  = 2,
	Unknown  = 3, // The display holds no decision of this serial: a later dialog replaced it, or it never showed.
}

// plan_display_decision_of_word is the border of a decision word: a word
// that names no member is refused.
plan_display_decision_of_word :: proc "contextless" (word: i64) -> (decision: Plan_Display_Decision, ok: bool) {
	switch word {
	case i64(Plan_Display_Decision.Pending):
		return .Pending, true
	case i64(Plan_Display_Decision.Accepted):
		return .Accepted, true
	case i64(Plan_Display_Decision.Refused):
		return .Refused, true
	case i64(Plan_Display_Decision.Unknown):
		return .Unknown, true
	}
	return .Unknown, false
}

// The magic of a generation object and of a current object.
PLAN_GENERATION_MAGIC :: [8]u8{'M', 'O', 'D', 'P', 'G', 'E', 'N', '1'}
PLAN_CURRENT_MAGIC :: [8]u8{'M', 'O', 'D', 'P', 'C', 'U', 'R', '1'}

// The bytes of one entry row in a generation object: four words, three
// hashes and the name.
PLAN_ENTRY_ROW_WIRE_SIZE :: 4 * 8 + 3 * blake3.HASH_SIZE + MAX_ENTRY_NAME_BYTES

// The head of a generation object: its magic, the applied plan record and
// the count of its rows (4 bytes, then 4 zero bytes).
PLAN_GENERATION_HEAD_SIZE :: 8 + APPLIED_PLAN_WIRE_SIZE + 8

// The most bytes of a generation object.
PLAN_GENERATION_WIRE_MOST :: PLAN_GENERATION_HEAD_SIZE + MAX_PLAN_ENTRIES * PLAN_ENTRY_ROW_WIRE_SIZE

// The bytes of a current object: its magic, the principal, the current and
// the highest generation, and the hash of the current plan.
PLAN_CURRENT_WIRE_SIZE :: 8 + 3 * 8 + blake3.HASH_SIZE

#assert(PLAN_ENTRY_ROW_WIRE_SIZE == size_of(Plan_Entry_Row))
#assert(PLAN_GENERATION_WIRE_MOST <= MEMORY_PRIVATE_STORE_OBJECT_BYTES)

// The pointer of the generations of a principal that its current object holds.
Plan_Current_Record :: struct {
	principal:          u64,
	current_generation: u64,
	highest_generation: u64,
	current_plan_hash:  blake3.Hash,
}

// The name of an object of a service of the declarations.
Private_Object_Name :: struct {
	bytes:  [64]u8,
	length: int,
}

// plan_object_name gives "plan_<principal>_<generation>", or
// "plan_<principal>_current" when current is true.
plan_object_name :: proc "contextless" (principal: u64, generation: u64, current: bool) -> (name: Private_Object_Name) {
	private_object_name_append(&name, "plan_")
	private_object_name_append_decimal(&name, principal)
	private_object_name_append(&name, "_")
	if current {
		private_object_name_append(&name, "current")
	} else {
		private_object_name_append_decimal(&name, generation)
	}
	return name
}

// private_object_name_text gives the text of a name.
private_object_name_text :: proc "contextless" (name: ^Private_Object_Name) -> string {
	return string(name.bytes[:name.length])
}

// private_object_name_append adds text at the end of a name, as far as it fits.
private_object_name_append :: proc "contextless" (name: ^Private_Object_Name, text: string) {
	for index in 0 ..< len(text) {
		if name.length < len(name.bytes) {
			name.bytes[name.length] = text[index]
			name.length += 1
		}
	}
}

// private_object_name_append_decimal adds the decimal digits of value.
private_object_name_append_decimal :: proc "contextless" (name: ^Private_Object_Name, value: u64) {
	digits: [20]u8
	count := 0
	rest := value
	for {
		digits[count] = u8('0' + rest % 10)
		count += 1
		rest /= 10
		if rest == 0 {
			break
		}
	}
	for index := count - 1; index >= 0; index -= 1 {
		if name.length < len(name.bytes) {
			name.bytes[name.length] = digits[index]
			name.length += 1
		}
	}
}

// private_object_name_append_hash adds the first digits of a hash, in
// lowercase hexadecimal, as far as they fit.
private_object_name_append_hash :: proc "contextless" (name: ^Private_Object_Name, digest: blake3.Hash, digits: int) {
	hex_digits := "0123456789abcdef"
	for index in 0 ..< min(digits, 2 * len(digest)) {
		if name.length >= len(name.bytes) {
			return
		}
		value := digest[index / 2]
		name.bytes[name.length] = hex_digits[index % 2 == 0 ? value >> 4 : value & 0x0f]
		name.length += 1
	}
}

// encode_plan_generation writes the generation object of record and its
// plan into output. The plan must be the plan of the record: its hash and
// its principal are checked, so a generation object never names another plan.
encode_plan_generation :: proc "contextless" (record: ^Applied_Plan_Record, plan: ^Plan_Spec, output: []u8) -> (written: int, refusal: Plan_Refusal) {
	if record == nil || plan == nil {
		return 0, .Buffer_Too_Small
	}
	if plan.entry_count == 0 || plan.entry_count > MAX_PLAN_ENTRIES {
		return 0, .Too_Many_Entries
	}
	digest, hash_refusal := plan_hash(plan)
	if hash_refusal != .None {
		return 0, hash_refusal
	}
	if digest != record.plan_hash {
		return 0, .Store_Damaged
	}
	if plan.principal != record.principal {
		return 0, .Principal_Mismatch
	}
	size := PLAN_GENERATION_HEAD_SIZE + int(plan.entry_count) * PLAN_ENTRY_ROW_WIRE_SIZE
	if len(output) < size {
		return 0, .Buffer_Too_Small
	}
	magic := PLAN_GENERATION_MAGIC
	copy(output[0:8], magic[:])
	if _, record_refusal := encode_applied_plan_record(record, output[8:8 + APPLIED_PLAN_WIRE_SIZE]); record_refusal != .None {
		return 0, record_refusal
	}
	head_rest := 8 + APPLIED_PLAN_WIRE_SIZE
	byte_order.write_u32_little_endian(output, head_rest, plan.entry_count)
	byte_order.write_u32_little_endian(output, head_rest + 4, 0)
	for index in 0 ..< int(plan.entry_count) {
		row := plan_entry_row_of_entry(&plan.entries[index])
		place := PLAN_GENERATION_HEAD_SIZE + index * PLAN_ENTRY_ROW_WIRE_SIZE
		byte_order.write_u64_little_endian(output, place, u64(row.kind_word))
		byte_order.write_u64_little_endian(output, place + 8, u64(row.role_word))
		byte_order.write_u64_little_endian(output, place + 16, u64(row.start_grants_mask))
		byte_order.write_u64_little_endian(output, place + 24, u64(row.store_rights_word))
		copy(output[place + 32:place + 64], row.module_hash[:])
		copy(output[place + 64:place + 96], row.interposed_over_hash[:])
		copy(output[place + 96:place + 128], row.recipe_hash[:])
		copy(output[place + 128:place + 192], row.name[:])
	}
	return size, .None
}

// decode_plan_generation reads a generation object of principal and
// generation, and checks it whole: its head, each row at the border of a
// plan, the hash of the plan against its record, and the principal and the
// generation that its name gives. On a refusal, out and record are zero.
decode_plan_generation :: proc "contextless" (input: []u8, principal: u64, generation: u64, out: ^Plan_Spec) -> (record: Applied_Plan_Record, refusal: Plan_Refusal) {
	if out == nil {
		return {}, .Buffer_Too_Small
	}
	out^ = {}
	if len(input) < PLAN_GENERATION_HEAD_SIZE {
		return {}, .Truncated
	}
	magic := PLAN_GENERATION_MAGIC
	for index in 0 ..< len(magic) {
		if input[index] != magic[index] {
			return {}, .Bad_Header
		}
	}
	record, refusal = decode_applied_plan_record(input[8:8 + APPLIED_PLAN_WIRE_SIZE])
	if refusal != .None {
		return {}, refusal
	}
	head_rest := 8 + APPLIED_PLAN_WIRE_SIZE
	count := byte_order.read_u32_little_endian(input, head_rest)
	if byte_order.read_u32_little_endian(input, head_rest + 4) != 0 {
		return {}, .Bad_Header
	}
	if count == 0 || count > MAX_PLAN_ENTRIES {
		return {}, .Store_Damaged
	}
	size := PLAN_GENERATION_HEAD_SIZE + int(count) * PLAN_ENTRY_ROW_WIRE_SIZE
	if len(input) < size {
		return {}, .Truncated
	}
	if len(input) > size {
		return {}, .Trailing_Bytes
	}
	if record.principal != principal || record.generation != generation {
		return {}, .Store_Damaged
	}
	rows: [MAX_PLAN_ENTRIES]Plan_Entry_Row
	for index in 0 ..< int(count) {
		place := PLAN_GENERATION_HEAD_SIZE + index * PLAN_ENTRY_ROW_WIRE_SIZE
		row := &rows[index]
		row.kind_word = i64(byte_order.read_u64_little_endian(input, place))
		row.role_word = i64(byte_order.read_u64_little_endian(input, place + 8))
		row.start_grants_mask = i64(byte_order.read_u64_little_endian(input, place + 16))
		row.store_rights_word = i64(byte_order.read_u64_little_endian(input, place + 24))
		copy(row.module_hash[:], input[place + 32:place + 64])
		copy(row.interposed_over_hash[:], input[place + 64:place + 96])
		copy(row.recipe_hash[:], input[place + 96:place + 128])
		copy(row.name[:], input[place + 128:place + 192])
	}
	if row_refusal, _ := plan_of_rows(principal, rows[:count], out); row_refusal != .None {
		return {}, .Store_Damaged
	}
	digest, hash_refusal := plan_hash(out)
	if hash_refusal != .None || digest != record.plan_hash {
		out^ = {}
		return {}, .Store_Damaged
	}
	return record, .None
}

// encode_plan_current writes the current object of a principal.
encode_plan_current :: proc "contextless" (current: ^Plan_Current_Record, output: []u8) -> (written: int, refusal: Plan_Refusal) {
	if current == nil || len(output) < PLAN_CURRENT_WIRE_SIZE {
		return 0, .Buffer_Too_Small
	}
	if current.current_generation == 0 || current.current_generation > current.highest_generation || hash_is_zero(current.current_plan_hash) {
		return 0, .Unknown_Generation
	}
	magic := PLAN_CURRENT_MAGIC
	copy(output[0:8], magic[:])
	byte_order.write_u64_little_endian(output, 8, current.principal)
	byte_order.write_u64_little_endian(output, 16, current.current_generation)
	byte_order.write_u64_little_endian(output, 24, current.highest_generation)
	copy(output[32:64], current.current_plan_hash[:])
	return PLAN_CURRENT_WIRE_SIZE, .None
}

// decode_plan_current reads the current object of principal and checks it:
// its principal, a current generation from 1 to the highest one, and a plan
// hash.
decode_plan_current :: proc "contextless" (input: []u8, principal: u64) -> (current: Plan_Current_Record, refusal: Plan_Refusal) {
	if len(input) < PLAN_CURRENT_WIRE_SIZE {
		return {}, .Truncated
	}
	if len(input) > PLAN_CURRENT_WIRE_SIZE {
		return {}, .Trailing_Bytes
	}
	magic := PLAN_CURRENT_MAGIC
	for index in 0 ..< len(magic) {
		if input[index] != magic[index] {
			return {}, .Bad_Header
		}
	}
	current.principal = byte_order.read_u64_little_endian(input, 8)
	current.current_generation = byte_order.read_u64_little_endian(input, 16)
	current.highest_generation = byte_order.read_u64_little_endian(input, 24)
	copy(current.current_plan_hash[:], input[32:64])
	if current.principal != principal || current.current_generation == 0 || current.current_generation > current.highest_generation || hash_is_zero(current.current_plan_hash) {
		return {}, .Store_Damaged
	}
	return current, .None
}


// The magic of a realisation object and of a project object.
REALISATION_OBJECT_MAGIC :: [8]u8{'M', 'O', 'D', 'R', 'E', 'A', 'L', '1'}
PROJECT_OBJECT_MAGIC :: [8]u8{'M', 'O', 'D', 'P', 'R', 'J', 'T', '1'}

// The head of a realisation object: its magic, the recipe hash, the output
// hash, the output kind, the origin, the signer key, the signature and the
// count of the bytes of the output.
REALISATION_OBJECT_HEAD_SIZE :: 8 + 2 * blake3.HASH_SIZE + 8 + 8 + object_cache.PUBLIC_KEY_SIZE + object_cache.SIGNATURE_SIZE + 8

// The hexadecimal digits of the recipe hash in the name of a realisation
// object: the name of an entry of a store has at most 64 bytes, and the
// object holds the whole hash, which the reader checks.
REALISATION_NAME_HASH_DIGITS :: 52

// The hexadecimal digits of the hash of a project name in the name of a
// project object.
PROJECT_NAME_HASH_DIGITS :: 24

// realisation_object_name gives "realisation_" and the first digits of the
// recipe hash.
realisation_object_name :: proc "contextless" (recipe_hash: blake3.Hash) -> (name: Private_Object_Name) {
	private_object_name_append(&name, "realisation_")
	private_object_name_append_hash(&name, recipe_hash, REALISATION_NAME_HASH_DIGITS)
	return name
}

// project_object_name gives "project_<principal>_" and the first digits of
// the hash of the project name.
project_object_name :: proc "contextless" (principal: u64, project_name: []u8) -> (name: Private_Object_Name) {
	private_object_name_append(&name, "project_")
	private_object_name_append_decimal(&name, principal)
	private_object_name_append(&name, "_")
	private_object_name_append_hash(&name, blake3.hash(project_name), PROJECT_NAME_HASH_DIGITS)
	return name
}

// encode_realisation_object writes the realisation object of record, with
// its origin word and the bytes of its output.
encode_realisation_object :: proc "contextless" (record: ^object_cache.Realisation_Record, origin_word: u64, payload: []u8, output: []u8) -> (written: int, refusal: Recipe_Refusal) {
	if record == nil {
		return 0, .Buffer_Too_Small
	}
	size := REALISATION_OBJECT_HEAD_SIZE + len(payload)
	if len(output) < size {
		return 0, .Buffer_Too_Small
	}
	magic := REALISATION_OBJECT_MAGIC
	copy(output[0:8], magic[:])
	place := 8
	copy(output[place:place + blake3.HASH_SIZE], record.recipe_hash[:])
	place += blake3.HASH_SIZE
	copy(output[place:place + blake3.HASH_SIZE], record.output_hash[:])
	place += blake3.HASH_SIZE
	byte_order.write_u64_little_endian(output, place, u64(record.output_kind))
	byte_order.write_u64_little_endian(output, place + 8, origin_word)
	place += 16
	copy(output[place:place + object_cache.PUBLIC_KEY_SIZE], record.signer_public_key[:])
	place += object_cache.PUBLIC_KEY_SIZE
	copy(output[place:place + object_cache.SIGNATURE_SIZE], record.signature[:])
	place += object_cache.SIGNATURE_SIZE
	byte_order.write_u64_little_endian(output, place, u64(len(payload)))
	place += 8
	copy(output[place:], payload)
	return size, .None
}

// decode_realisation_object reads a realisation object of recipe_hash and
// checks it whole: its head, its recipe hash, its output kind against
// expected_kind, and the hash of its output bytes against its output hash.
// Any fault is Store_Damaged: the reader never takes an output that its hash
// does not name.
decode_realisation_object :: proc "contextless" (input: []u8, recipe_hash: blake3.Hash, expected_kind: object_cache.Cache_Object_Kind) -> (record: object_cache.Realisation_Record, origin_word: u64, payload: []u8, refusal: Recipe_Refusal) {
	if len(input) < REALISATION_OBJECT_HEAD_SIZE {
		return {}, 0, nil, .Store_Damaged
	}
	magic := REALISATION_OBJECT_MAGIC
	for index in 0 ..< len(magic) {
		if input[index] != magic[index] {
			return {}, 0, nil, .Store_Damaged
		}
	}
	place := 8
	copy(record.recipe_hash[:], input[place:place + blake3.HASH_SIZE])
	place += blake3.HASH_SIZE
	copy(record.output_hash[:], input[place:place + blake3.HASH_SIZE])
	place += blake3.HASH_SIZE
	kind_word := byte_order.read_u64_little_endian(input, place)
	origin_word = byte_order.read_u64_little_endian(input, place + 8)
	place += 16
	copy(record.signer_public_key[:], input[place:place + object_cache.PUBLIC_KEY_SIZE])
	place += object_cache.PUBLIC_KEY_SIZE
	copy(record.signature[:], input[place:place + object_cache.SIGNATURE_SIZE])
	place += object_cache.SIGNATURE_SIZE
	length := byte_order.read_u64_little_endian(input, place)
	place += 8
	if length != u64(len(input) - REALISATION_OBJECT_HEAD_SIZE) {
		return {}, 0, nil, .Store_Damaged
	}
	kind, kind_ok := object_cache.cache_object_kind_of_word(kind_word)
	if !kind_ok || kind != expected_kind || record.recipe_hash != recipe_hash {
		return {}, 0, nil, .Store_Damaged
	}
	record.output_kind = kind
	payload = input[place:]
	recomputed, output_refusal := recipe_hash_output(kind, payload)
	if output_refusal != .None || recomputed != record.output_hash {
		return {}, 0, nil, .Store_Damaged
	}
	return record, origin_word, payload, .None
}

// encode_project_object writes the project object of a project: its name,
// the evaluation of its project.lex and the text of its pins.lex.
encode_project_object :: proc "contextless" (project_name: []u8, evaluation: []u8, pins_lex: []u8, output: []u8) -> (written: int, ok: bool) {
	if len(project_name) == 0 || len(project_name) > MAX_ENTRY_NAME_BYTES {
		return 0, false
	}
	size := 8 + 12 + MAX_ENTRY_NAME_BYTES + len(evaluation) + len(pins_lex)
	if len(output) < size {
		return 0, false
	}
	magic := PROJECT_OBJECT_MAGIC
	copy(output[0:8], magic[:])
	byte_order.write_u32_little_endian(output, 8, u32(len(project_name)))
	byte_order.write_u32_little_endian(output, 12, u32(len(evaluation)))
	byte_order.write_u32_little_endian(output, 16, u32(len(pins_lex)))
	for index in 0 ..< MAX_ENTRY_NAME_BYTES {
		output[20 + index] = index < len(project_name) ? project_name[index] : 0
	}
	place := 20 + MAX_ENTRY_NAME_BYTES
	copy(output[place:], evaluation)
	copy(output[place + len(evaluation):], pins_lex)
	return size, true
}

// decode_project_object reads a project object and checks that it is whole
// and that it names project_name. It gives the evaluation and the pins.lex
// text as parts of input.
decode_project_object :: proc "contextless" (input: []u8, project_name: []u8) -> (evaluation: []u8, pins_lex: []u8, ok: bool) {
	head := 20 + MAX_ENTRY_NAME_BYTES
	if len(input) < head {
		return nil, nil, false
	}
	magic := PROJECT_OBJECT_MAGIC
	for index in 0 ..< len(magic) {
		if input[index] != magic[index] {
			return nil, nil, false
		}
	}
	name_length := int(byte_order.read_u32_little_endian(input, 8))
	evaluation_length := int(byte_order.read_u32_little_endian(input, 12))
	pins_length := int(byte_order.read_u32_little_endian(input, 16))
	if name_length != len(project_name) || name_length == 0 || name_length > MAX_ENTRY_NAME_BYTES {
		return nil, nil, false
	}
	if evaluation_length > len(input) - head || pins_length != len(input) - head - evaluation_length {
		return nil, nil, false
	}
	for index in 0 ..< MAX_ENTRY_NAME_BYTES {
		expected := index < name_length ? project_name[index] : 0
		if input[20 + index] != expected {
			return nil, nil, false
		}
	}
	return input[head:head + evaluation_length], input[head + evaluation_length:], true
}
