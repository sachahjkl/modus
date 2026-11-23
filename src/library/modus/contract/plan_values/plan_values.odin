// The plan values of principal 0 (src/md/features/module_settings.md,
// "Plan records"): the defaults and the locks that
// the plan gives each owner of settings, and the values that only the plan
// holds (a plan-only value).
//
// The holder of Plans writes the set of one generation on the page that the
// core lends (the command Plan_Values); the core checks it whole with
// set_check and keeps it. At the start of an owner the core gives it the
// values of that owner on its own page, and writes the page again at each
// change of the set (owner_page_publish); the owner copies the page whole
// (owner_page_copy) and reads the copy with owner_page_read. Each list of values is a record of
// modus:contract/chosen_values: one form of entry, one reader, one border.
//
// This package allocates no memory and calls no kernel operation.
package plan_values

import "base:intrinsics"
import "modus:contract/chosen_values"
import "modus:contract/fixed_addresses"

// Where an owner maps the page of its plan values.
OWNER_PAGE_ADDRESS :: fixed_addresses.PLAN_VALUES_PAGE_ADDRESS

// The bytes "PLANVAL1": a set of plan values.
SET_MAGIC :: u64(0x314C_4156_4E41_4C50)
// The bytes "OWNVAL02": the page of the values of one owner, with its
// sequence word.
OWNER_MAGIC :: u64(0x3230_4C41_564E_574F)
// The pages of a set: the room for each owner of the plan with a few dozen
// values each.
SET_PAGES :: 4
SET_SIZE :: SET_PAGES * 4096
// The size of the page of one owner.
OWNER_PAGE_SIZE :: 4096
// The owners of one set at most.
OWNER_CAPACITY :: 32
// The header of a set: the magic, the principal, the generation, the count
// of the owners and four zero bytes.
SET_HEADER_SIZE :: 32
// The head of the block of one owner: its name, then the bytes of its
// defaults and of its locks, each a record of chosen values.
OWNER_HEAD_SIZE :: chosen_values.NAME_SIZE + 8
// The header of the page of one owner: the magic, the bytes of its
// defaults and of its locks, then the sequence word and four zero bytes.
// The core writes the page again when the plan values change: the sequence
// is odd while it writes, and even after; an owner copies the page and
// keeps the copy only when the sequence was even and the same before and
// after (owner_page_copy), and waits on the word for the next change.
OWNER_PAGE_HEADER_SIZE :: 24
OWNER_PAGE_SEQUENCE_OFFSET :: 16

// Why a set is refused. A refusal changes no value of the core.
Set_Problem :: enum u8 {
	None              = 0,
	Too_Short         = 1, // Fewer bytes than a header, or a block past the bytes.
	Bad_Magic         = 2,
	Not_Machine       = 3, // The set is not of principal 0: the values of the machine come from its plan only.
	Zero_Generation   = 4,
	Too_Many_Owners   = 5, // The count of the owners is past OWNER_CAPACITY.
	Bad_Owner         = 6, // An owner name that is not a name (chosen_values.name_valid), or bytes after its first zero.
	Owner_Twice       = 7,
	Bad_Record        = 8, // The defaults or the locks of an owner are no record of chosen values.
	Default_And_Lock  = 9, // One name is a default and a lock of one owner: the lock and the default would say two things.
	Reserved_Not_Zero = 10, // The reserved bytes of the header, or bytes after the last block that are not zero.
	Owner_Too_Large   = 11, // The two records of an owner do not fit its page (OWNER_PAGE_SIZE): the core could not give them.
}

// The name of each problem, for a line of the log.
@(rodata)
SET_PROBLEM_NAMES := [Set_Problem]string {
	.None              = "none",
	.Too_Short         = "too short",
	.Bad_Magic         = "another format",
	.Not_Machine       = "not of principal 0",
	.Zero_Generation   = "no generation",
	.Too_Many_Owners   = "too many owners",
	.Bad_Owner         = "an owner not valid",
	.Owner_Twice       = "an owner twice",
	.Bad_Record        = "a record not valid",
	.Default_And_Lock  = "a default and a lock",
	.Reserved_Not_Zero = "reserved bytes",
	.Owner_Too_Large   = "an owner past its page",
}

// The values of one owner in a checked set or page: two records of chosen
// values, in the bytes of the caller.
Owner_Values :: struct {
	defaults: chosen_values.Record,
	locks:    chosen_values.Record,
}

// The parts of a set that set_check read.
Set_Head :: struct {
	principal:   u64,
	generation:  u64,
	owner_count: int,
}

@(private)
word_at :: proc "contextless" (bytes: []u8, at: int) -> u64 {
	value: u64
	for index in 0 ..< 8 {
		value |= u64(bytes[at + index]) << u64(index * 8)
	}
	return value
}

@(private)
word_put :: proc "contextless" (bytes: []u8, at: int, value: u64) {
	for index in 0 ..< 8 {
		bytes[at + index] = u8(value >> u64(index * 8))
	}
}

// name_of_field gives the name in a field of NAME_SIZE bytes: its bytes
// before the first zero, and false when a byte after that zero is not zero.
@(private)
name_of_field :: proc "contextless" (field: []u8) -> (name: string, ok: bool) {
	length := 0
	for length < len(field) && field[length] != 0 {
		length += 1
	}
	for byte in field[length:] {
		if byte != 0 {
			return "", false
		}
	}
	return string(field[:length]), true
}

// align8 gives the offset after a count of bytes, at a multiple of 8.
@(private)
align8 :: proc "contextless" (offset: int) -> int {
	return (offset + 7) &~ 7
}

// records_read reads the defaults and the locks of one owner, and refuses a
// name that is a default and a lock.
@(private)
records_read :: proc "contextless" (defaults_bytes, locks_bytes: []u8) -> (values: Owner_Values, problem: Set_Problem) {
	record_problem: chosen_values.Record_Problem
	if values.defaults, record_problem = chosen_values.read_record(defaults_bytes); record_problem != .None {
		return {}, .Bad_Record
	}
	if values.locks, record_problem = chosen_values.read_record(locks_bytes); record_problem != .None {
		return {}, .Bad_Record
	}
	for index in 0 ..< values.locks.count {
		if chosen_values.contains(values.defaults, chosen_values.entry_name(values.locks, index)) {
			return {}, .Default_And_Lock
		}
	}
	return values, .None
}

// set_walk checks a set and, when owner is not "", finds the values of that
// owner. Each refusal reads nothing more.
@(private)
set_walk :: proc "contextless" (bytes: []u8, owner: string) -> (head: Set_Head, values: Owner_Values, found: bool, problem: Set_Problem) {
	if len(bytes) < SET_HEADER_SIZE {
		return {}, {}, false, .Too_Short
	}
	if word_at(bytes, 0) != SET_MAGIC {
		return {}, {}, false, .Bad_Magic
	}
	head = {principal = word_at(bytes, 8), generation = word_at(bytes, 16)}
	count_word := word_at(bytes, 24)
	if count_word >> 32 != 0 {
		return {}, {}, false, .Reserved_Not_Zero
	}
	switch {
	case head.principal != 0:
		return {}, {}, false, .Not_Machine
	case head.generation == 0:
		return {}, {}, false, .Zero_Generation
	case count_word > OWNER_CAPACITY:
		return {}, {}, false, .Too_Many_Owners
	}
	head.owner_count = int(count_word)
	names: [OWNER_CAPACITY]string
	at := SET_HEADER_SIZE
	for index in 0 ..< head.owner_count {
		if len(bytes) - at < OWNER_HEAD_SIZE {
			return {}, {}, false, .Too_Short
		}
		name, name_ok := name_of_field(bytes[at:][:chosen_values.NAME_SIZE])
		if !name_ok || !chosen_values.name_valid(name) {
			return {}, {}, false, .Bad_Owner
		}
		for other in names[:index] {
			if other == name {
				return {}, {}, false, .Owner_Twice
			}
		}
		names[index] = name
		lengths := word_at(bytes, at + chosen_values.NAME_SIZE)
		defaults_length, locks_length := int(lengths & 0xFFFF_FFFF), int(lengths >> 32)
		start := at + OWNER_HEAD_SIZE
		if defaults_length > len(bytes) - start || locks_length > len(bytes) - start - defaults_length {
			return {}, {}, false, .Too_Short
		}
		owner_values, records_problem := records_read(bytes[start:][:defaults_length], bytes[start + defaults_length:][:locks_length])
		if records_problem != .None {
			return {}, {}, false, records_problem
		}
		if !owner_fits_page(owner_values) {
			return {}, {}, false, .Owner_Too_Large
		}
		if name == owner {
			values, found = owner_values, true
		}
		at = align8(start + defaults_length + locks_length)
		if at > len(bytes) {
			at = len(bytes)
		}
	}
	for byte in bytes[at:] {
		if byte != 0 {
			return {}, {}, false, .Reserved_Not_Zero
		}
	}
	return head, values, found, .None
}

// owner_fits_page says if the values of an owner fit the page that the
// core gives it: the header of the page and its two records.
owner_fits_page :: proc "contextless" (values: Owner_Values) -> bool {
	return OWNER_PAGE_HEADER_SIZE + max(chosen_values.record_size(values.defaults), chosen_values.HEADER_SIZE) + max(chosen_values.record_size(values.locks), chosen_values.HEADER_SIZE) <= OWNER_PAGE_SIZE
}

// Format property: the bytes of the entries and the texts that the values
// of one owner may hold inside one OWNER_PAGE_SIZE (4096-byte) page, after
// the page header and the two chosen_values headers. The border of a plan
// refuses an owner past it.
OWNER_BYTES_MOST :: OWNER_PAGE_SIZE - OWNER_PAGE_HEADER_SIZE - 2 * chosen_values.HEADER_SIZE

// set_check checks a whole set, as the core reads its copy of the page of
// the holder of Plans.
set_check :: proc "contextless" (bytes: []u8) -> (head: Set_Head, problem: Set_Problem) {
	head, _, _, problem = set_walk(bytes, "")
	return head, problem
}

// owner_values_of gives the values of one owner in a set that set_check
// took: found is false for an owner that the set does not name, which then
// has no value of the plan.
owner_values_of :: proc "contextless" (bytes: []u8, owner: string) -> (values: Owner_Values, found: bool) {
	_, values, found, _ = set_walk(bytes, owner)
	return values, found
}

// Owner_Block: the values of one owner for set_write, as two records of
// chosen values.
Owner_Block :: struct {
	owner:    string,
	defaults: []u8,
	locks:    []u8,
}

// set_write writes a set: the header, then each block. It gives the bytes
// written, or 0 when the blocks do not fit. It checks nothing: set_check is
// the border of the reader.
set_write :: proc "contextless" (out: []u8, principal, generation: u64, blocks: []Owner_Block) -> (written: int) {
	for &byte in out {
		byte = 0
	}
	if len(out) < SET_HEADER_SIZE {
		return 0
	}
	word_put(out, 0, SET_MAGIC)
	word_put(out, 8, principal)
	word_put(out, 16, generation)
	word_put(out, 24, u64(len(blocks)))
	at := SET_HEADER_SIZE
	for block in blocks {
		need := OWNER_HEAD_SIZE + len(block.defaults) + len(block.locks)
		if len(block.owner) > chosen_values.NAME_SIZE || need > len(out) - at {
			return 0
		}
		copy(out[at:][:chosen_values.NAME_SIZE], block.owner)
		word_put(out, at + chosen_values.NAME_SIZE, u64(len(block.defaults)) | u64(len(block.locks)) << 32)
		copy(out[at + OWNER_HEAD_SIZE:], block.defaults)
		copy(out[at + OWNER_HEAD_SIZE + len(block.defaults):], block.locks)
		at = min(align8(at + need), len(out))
	}
	return at
}

// owner_page_write writes the values of one owner on its page, as the core
// maps it at its start. Values of no owner give a page with two empty
// records. ok is false when the values do not fit the page.
owner_page_write :: proc "contextless" (page: []u8, values: Owner_Values) -> (ok: bool) {
	// The sequence word is the one byte range that the write keeps: an owner
	// reads it during the write (owner_page_publish).
	for &byte, index in page {
		if index < OWNER_PAGE_SEQUENCE_OFFSET || index >= OWNER_PAGE_SEQUENCE_OFFSET + 8 {
			byte = 0
		}
	}
	// An empty record is written as a header: the page always holds two
	// records.
	defaults_length := max(chosen_values.record_size(values.defaults), chosen_values.HEADER_SIZE)
	locks_length := max(chosen_values.record_size(values.locks), chosen_values.HEADER_SIZE)
	if len(page) < OWNER_PAGE_HEADER_SIZE || defaults_length + locks_length > len(page) - OWNER_PAGE_HEADER_SIZE {
		return false
	}
	word_put(page, 0, OWNER_MAGIC)
	word_put(page, 8, u64(defaults_length) | u64(locks_length) << 32)
	defaults_written, defaults_problem := chosen_values.write_record(values.defaults, nil, page[OWNER_PAGE_HEADER_SIZE:][:defaults_length])
	locks_written, locks_problem := chosen_values.write_record(values.locks, nil, page[OWNER_PAGE_HEADER_SIZE + defaults_length:][:locks_length])
	return defaults_problem == .None && locks_problem == .None && defaults_written == defaults_length && locks_written == locks_length
}

// owner_page_read is the border of the page of plan values of an owner: the
// defaults and the locks, or false and no value for a page that is no page
// of plan values. An owner with no page has no value of the plan.
owner_page_read :: proc "contextless" (page: []u8) -> (values: Owner_Values, ok: bool) {
	if len(page) < OWNER_PAGE_HEADER_SIZE || word_at(page, 0) != OWNER_MAGIC {
		return {}, false
	}
	lengths := word_at(page, 8)
	defaults_length, locks_length := int(lengths & 0xFFFF_FFFF), int(lengths >> 32)
	if defaults_length > len(page) - OWNER_PAGE_HEADER_SIZE || locks_length > len(page) - OWNER_PAGE_HEADER_SIZE - defaults_length {
		return {}, false
	}
	problem: Set_Problem
	values, problem = records_read(page[OWNER_PAGE_HEADER_SIZE:][:defaults_length], page[OWNER_PAGE_HEADER_SIZE + defaults_length:][:locks_length])
	return values, problem == .None
}

// value_in_force gives the value of a field in force, and the layer that
// gives it (src/md/features/module_settings.md, "The precedence"): a lock
// of the plan, then a choice of the principal, then a default of the plan.
// A word that the border of the field refuses holds as no value of its
// layer, and the next layer holds. found is false when no layer gives a
// word: the default of the contract holds.
value_in_force :: proc "contextless" (name: string, chosen: chosen_values.Record, plan: Owner_Values, border: proc "contextless" (word: u64) -> bool) -> (word: u64, layer: chosen_values.Layer, found: bool) {
	Source :: struct {
		record: chosen_values.Record,
		layer:  chosen_values.Layer,
	}
	for source in ([3]Source{{plan.locks, .Locked}, {chosen, .Chosen}, {plan.defaults, .Plan_Default}}) {
		if value, value_found := chosen_values.find(source.record, name); value_found && border(value) {
			return value, source.layer, true
		}
	}
	return 0, .Contract_Default, false
}

// text_in_force gives the text of a field in force and its layer, in the
// order of value_in_force: a text that the border of the field refuses
// holds as no value of its layer. The text is in the bytes of its record.
text_in_force :: proc "contextless" (name: string, chosen: chosen_values.Record, plan: Owner_Values, border: proc "contextless" (text: string) -> bool) -> (text: string, layer: chosen_values.Layer, found: bool) {
	Source :: struct {
		record: chosen_values.Record,
		layer:  chosen_values.Layer,
	}
	for source in ([3]Source{{plan.locks, .Locked}, {chosen, .Chosen}, {plan.defaults, .Plan_Default}}) {
		if value, value_found := chosen_values.find_text(source.record, name); value_found && border(value) {
			return value, source.layer, true
		}
	}
	return "", .Contract_Default, false
}

// locked says if the plan locks a word field: the setter of the owner
// refuses a change of it with No_Grant, and keeps the chosen value under
// the lock. A lock whose word the border refuses holds as no value, as in
// value_in_force: it locks nothing.
locked :: proc "contextless" (plan: Owner_Values, name: string, border: proc "contextless" (word: u64) -> bool) -> bool {
	word, found := chosen_values.find(plan.locks, name)
	return found && border(word)
}

// text_locked says if the plan locks a text field, as locked does for a
// word.
text_locked :: proc "contextless" (plan: Owner_Values, name: string, border: proc "contextless" (text: string) -> bool) -> bool {
	text, found := chosen_values.find_text(plan.locks, name)
	return found && border(text)
}

// owner_page_sequence gives the sequence word of a page.
owner_page_sequence :: proc "contextless" (page: []u8) -> ^u32 {
	return (^u32)(&page[OWNER_PAGE_SEQUENCE_OFFSET])
}

// owner_page_sequence_load reads the sequence word of a page that the core
// may write meanwhile.
owner_page_sequence_load :: proc "contextless" (page: []u8) -> u32 {
	return intrinsics.atomic_load_explicit(owner_page_sequence(page), .Acquire)
}

// owner_page_publish writes the values of an owner on a page that the owner
// may read meanwhile: the sequence is odd during the write, and even after.
// The caller wakes the sequence word after it. ok is false when the values
// do not fit the page: the page then holds no value, with an even sequence.
owner_page_publish :: proc "contextless" (page: []u8, values: Owner_Values) -> (ok: bool) {
	sequence := owner_page_sequence(page)
	before := intrinsics.atomic_load_explicit(sequence, .Relaxed)
	intrinsics.atomic_store_explicit(sequence, before | 1, .Relaxed)
	intrinsics.atomic_thread_fence(.Release)
	ok = owner_page_write(page, values)
	if !ok {
		_ = owner_page_write(page, {})
	}
	intrinsics.atomic_store_explicit(sequence, (before | 1) + 1, .Release)
	return ok
}

// owner_page_copy makes one copy of a page that the core may write
// meanwhile into out, the memory of the owner. sequence is the even
// sequence of a whole copy. A copy that met a write gives ok false and met,
// the word that it read: an odd met is a write in progress, which the
// caller waits out on the word (system.plan_values_of_process); an even one
// is a write that ended during the copy, and the caller copies again. Both
// pages must hold OWNER_PAGE_SIZE bytes (owner_page_sizes_valid).
owner_page_copy :: proc "contextless" (page: []u8, out: []u8) -> (sequence: u32, ok: bool, met: u32) {
	if !owner_page_sizes_valid(page, out) {
		return 0, false, 0
	}
	word := owner_page_sequence(page)
	first := intrinsics.atomic_load_explicit(word, .Acquire)
	if first & 1 != 0 {
		return 0, false, first
	}
	intrinsics.mem_copy_non_overlapping(raw_data(out), raw_data(page), OWNER_PAGE_SIZE)
	intrinsics.atomic_thread_fence(.Acquire)
	if after := intrinsics.atomic_load_explicit(word, .Relaxed); after != first {
		return 0, false, after
	}
	return first, true, first
}

// owner_page_sizes_valid says if a page and a copy each hold a whole page.
owner_page_sizes_valid :: proc "contextless" (page: []u8, out: []u8) -> bool {
	return len(page) >= OWNER_PAGE_SIZE && len(out) >= OWNER_PAGE_SIZE
}
