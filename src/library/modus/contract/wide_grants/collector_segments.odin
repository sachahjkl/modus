// The audit spaces of the collector in its private store: one index object
// that names each audit space and its terms, and the records of each space
// as segments of a fixed count of records, each segment chained to the one
// before it by its BLAKE3 hash (src/md/features/module_outputs.md, "The
// chain of the segments").
//
// Each write of the port is one commit of a whole object, so a reader finds
// an object whole or absent. The collector writes a record into the open
// segment of its space before the space keeps it in memory and before the
// forward queue takes it: a stop of the collector after the write keeps the
// record, a refused write keeps and forwards nothing. A segment that holds
// SPACE_SEGMENT_RECORDS records is closed: no write names it again. The open
// segment is written again only with one more record after the ones that it
// held.
//
// A space Keep stays in memory: its oldest records leave by design, and an
// append-only segment never removes one.
//
// A space Audit keeps up to its bound in its segments, and the newest
// SPACE_RECORDS_MOST of them in memory too. Its segments take the
// SPACE_SEGMENT_SLOTS slots of the space in a ring: the object of a segment
// is named by its slot, and a later segment writes over a slot only when
// the records of the segment there rotated out (space_rotate_before), whole
// segments at a time, oldest first. The index keeps where the kept records
// start, with the hash of the segment and the link of the record before
// them: the chain of what stays is whole, and starts at those anchors.
package wide_grants

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import pr "modus:contract/plans_recipes"
import "modus:contract/value_kinds"

// The records of one segment.
SPACE_SEGMENT_RECORDS :: 16
// The slots of the segments of one space Audit in the private store, and so
// the largest bound of such a space.
SPACE_SEGMENT_SLOTS :: 256
SPACE_AUDIT_BOUND_MOST :: SPACE_SEGMENT_SLOTS * SPACE_SEGMENT_RECORDS

// The ring in memory holds each record of the open segment, which the
// segment writes again whole at each record.
#assert(SPACE_RECORDS_MOST % SPACE_SEGMENT_RECORDS == 0)
#assert(SPACE_RECORDS_MOST >= SPACE_SEGMENT_RECORDS)

// The first bytes of a segment and of the index, and the version of each.
SEGMENT_MAGIC :: "mcolsegm"
SPACE_INDEX_MAGIC :: "mcolspcs"
SEGMENT_VERSION :: 1
SPACE_INDEX_VERSION :: 3

// The context strings of the hash of a segment and of the index.
SEGMENT_HASH_DOMAIN :: "modus collector segment v1"
SPACE_INDEX_HASH_DOMAIN :: "modus collector spaces v1"

// The name of the index object in the private store.
SPACE_INDEX_OBJECT_NAME :: "collector_spaces"

// The places of the head of a segment, in bytes, all little-endian.
SEGMENT_MAGIC_AT :: 0
SEGMENT_VERSION_AT :: 8
SEGMENT_KIND_AT :: 12
SEGMENT_FORWARDING_AT :: 16
SEGMENT_SPACE_AT :: 20
SEGMENT_BOUND_AT :: 24
SEGMENT_RECORD_SIZE_AT :: 28
SEGMENT_PRINCIPAL_AT :: 32
SEGMENT_INDEX_AT :: 40
SEGMENT_FIRST_SERIAL_AT :: 48
SEGMENT_LAST_SERIAL_AT :: 56
SEGMENT_RECORD_COUNT_AT :: 64
SEGMENT_SOURCE_AT :: 72
SEGMENT_OUTPUT_AT :: SEGMENT_SOURCE_AT + SPACE_NAME_BYTES
SEGMENT_PREVIOUS_HASH_AT :: SEGMENT_OUTPUT_AT + SPACE_NAME_BYTES
SEGMENT_HEAD_BYTES :: SEGMENT_PREVIOUS_HASH_AT + blake3.HASH_SIZE

// Each record of a segment: its serial and its time, then its bytes.
SEGMENT_RECORD_HEAD_BYTES :: 16

// After the records: the link of the last record, then the hash of the
// segment over each byte before it.
SEGMENT_TAIL_BYTES :: 2 * blake3.HASH_SIZE

SEGMENT_BYTES_MOST :: SEGMENT_HEAD_BYTES + SPACE_SEGMENT_RECORDS * (SEGMENT_RECORD_HEAD_BYTES + SPACE_RECORD_BYTES_MOST) + SEGMENT_TAIL_BYTES

#assert(SEGMENT_HEAD_BYTES == 168)
#assert(SEGMENT_BYTES_MOST == 4584)

// The places of the head of the index, and of each row after it.
SPACE_INDEX_MAGIC_AT :: 0
SPACE_INDEX_VERSION_AT :: 8
SPACE_INDEX_COUNT_AT :: 12
SPACE_INDEX_PRINCIPAL_AT :: 16
SPACE_INDEX_HEAD_BYTES :: 24
SPACE_INDEX_ROW_SPACE_AT :: 0
SPACE_INDEX_ROW_KIND_AT :: 4
SPACE_INDEX_ROW_FORWARDING_AT :: 8
SPACE_INDEX_ROW_BOUND_AT :: 12
SPACE_INDEX_ROW_RECORD_SIZE_AT :: 16
SPACE_INDEX_ROW_SOURCE_AT :: 20
SPACE_INDEX_ROW_OUTPUT_AT :: SPACE_INDEX_ROW_SOURCE_AT + SPACE_NAME_BYTES
SPACE_INDEX_ROW_KEPT_FIRST_AT :: SPACE_INDEX_ROW_OUTPUT_AT + SPACE_NAME_BYTES
SPACE_INDEX_ROW_ANCHOR_SEGMENT_AT :: SPACE_INDEX_ROW_KEPT_FIRST_AT + 8
SPACE_INDEX_ROW_ANCHOR_LINK_AT :: SPACE_INDEX_ROW_ANCHOR_SEGMENT_AT + blake3.HASH_SIZE
// The state of the space, then for a closed space its next serial and its
// last link: a closed space has no window, and reads its records whole
// from the store up to that link.
SPACE_INDEX_ROW_STATE_AT :: SPACE_INDEX_ROW_ANCHOR_LINK_AT + blake3.HASH_SIZE
SPACE_INDEX_ROW_NEXT_SERIAL_AT :: SPACE_INDEX_ROW_STATE_AT + 8
SPACE_INDEX_ROW_LAST_LINK_AT :: SPACE_INDEX_ROW_NEXT_SERIAL_AT + 8
// The date of the close, in milliseconds since 1970; 0 until a pass of
// the collector knows a date.
SPACE_INDEX_ROW_CLOSED_AT_AT :: SPACE_INDEX_ROW_LAST_LINK_AT + blake3.HASH_SIZE
SPACE_INDEX_ROW_BYTES :: SPACE_INDEX_ROW_CLOSED_AT_AT + 8

// The state of a space in a row of the index.
// Removing: the retention of a closed space ended, and its objects are
// being removed. Removed: they are, the place is free, and the row says
// so to a reader until a new space takes the place; it holds no field.
Space_Index_State :: enum u32 {
	Open     = 1,
	Closed   = 2,
	Removing = 3,
	Removed  = 4,
}

#assert(SPACE_INDEX_ROW_BYTES == 212)

// The bytes of the name of a segment object: "collector_space_<n>_segment_<k>".
SEGMENT_OBJECT_NAME_BYTES :: 48

// The slot map of a space Audit, "collector_space_<n>_slots": the first
// bytes, the version, the context string of its hash, and its size. It
// names the segment of each slot, so a start reads the map and the last
// segments only, never each slot.
SLOT_MAP_MAGIC :: "mcolslot"
SLOT_MAP_VERSION :: 1
SLOT_MAP_HASH_DOMAIN :: "modus collector slot map v1"
SLOT_MAP_HEAD_BYTES :: 16
SLOT_MAP_BYTES :: SLOT_MAP_HEAD_BYTES + SPACE_SEGMENT_SLOTS * 8 + blake3.HASH_SIZE

// The segments that a start reads into the ring: those that hold the
// newest SPACE_RECORDS_MOST records, at most one of them not full.
LOAD_SEGMENTS_MOST :: SPACE_RECORDS_MOST / SPACE_SEGMENT_RECORDS + 1

// Whether the spaces of a store were read back from its private store. The
// store reads them at its first step: a read that fails leaves Not_Loaded,
// and the next step reads again; a damaged object leaves Damaged until the
// collector starts again, and each step is refused.
Space_Load_State :: enum u8 {
	Not_Loaded = 0,
	Loaded     = 1,
	Damaged    = 2,
}

// What segment_check does with the records of a segment that is whole.
@(private = "file")
Segment_Use :: enum u8 {
	Load    = 0, // Write them into the space, which holds the records before them.
	Compare = 1, // Compare them with the ones that the space holds.
}

// space_segment_count gives the segments that hold the records of a space.
space_segment_count :: proc "contextless" (space: ^Collector_Space) -> u64 {
	return (space.next_serial - space.kept_first_serial + SPACE_SEGMENT_RECORDS - 1) / SPACE_SEGMENT_RECORDS
}

@(private = "file")
decimal_write :: proc "contextless" (into: []u8, start: int, value: u32) -> int {
	digits: [10]u8
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
	at := start
	for index := count - 1; index >= 0; index -= 1 {
		into[at] = digits[index]
		at += 1
	}
	return at
}

@(private = "file")
text_write :: proc "contextless" (into: []u8, at: int, text: string) -> int {
	copy(into[at:], text)
	return at + len(text)
}

// segment_object_name gives the name of the object of the segment segment
// of the space space_number in into: the name of its slot.
segment_object_name :: proc "contextless" (into: ^[SEGMENT_OBJECT_NAME_BYTES]u8, space_number: u32, segment: u64) -> string {
	at := text_write(into[:], 0, "collector_space_")
	at = decimal_write(into[:], at, space_number)
	at = text_write(into[:], at, "_segment_")
	at = decimal_write(into[:], at, u32(segment % SPACE_SEGMENT_SLOTS))
	return string(into[:at])
}

// slot_map_object_name gives the name of the slot map of the space
// space_number in into.
slot_map_object_name :: proc "contextless" (into: ^[SEGMENT_OBJECT_NAME_BYTES]u8, space_number: u32) -> string {
	at := text_write(into[:], 0, "collector_space_")
	at = decimal_write(into[:], at, space_number)
	at = text_write(into[:], at, "_slots")
	return string(into[:at])
}

// slot_map_persist writes the slot map of a space whole, as the store
// holds it.
slot_map_persist :: proc "contextless" (store: ^Space_Store, space_number: u32) -> Space_Refusal {
	bytes: [SLOT_MAP_BYTES]u8
	copy(bytes[:8], SLOT_MAP_MAGIC)
	byte_order.write_u32_little_endian(bytes[:], 8, SLOT_MAP_VERSION)
	byte_order.write_u32_little_endian(bytes[:], 12, space_number)
	ring := store.spaces[space_number - 1].ring
	if ring == nil {
		return .Store_Damaged
	}
	for entry, slot in ring.slot_map {
		byte_order.write_u64_little_endian(bytes[:], SLOT_MAP_HEAD_BYTES + slot * 8, entry)
	}
	at := SLOT_MAP_HEAD_BYTES + SPACE_SEGMENT_SLOTS * 8
	map_hash := blake3.derive_key(SLOT_MAP_HASH_DOMAIN, bytes[:at])
	copy(bytes[at:][:blake3.HASH_SIZE], map_hash[:])
	name_place: [SEGMENT_OBJECT_NAME_BYTES]u8
	if pr.private_store_write(&store.store_port, slot_map_object_name(&name_place, space_number), bytes[:]) != .Ok {
		return .Store_Failed
	}
	return .None
}

// slot_map_load reads the slot map of a space into the store. No object is
// a map of no slot; a map of another space, another size or a broken hash
// is damage.
@(private = "file")
slot_map_load :: proc "contextless" (store: ^Space_Store, space_number: u32, ring: ^Space_Window) -> (present: bool, refusal: Space_Refusal) {
	if ring != nil {
		ring.slot_map = {}
	}
	buffer: [SLOT_MAP_BYTES]u8
	name_place: [SEGMENT_OBJECT_NAME_BYTES]u8
	bytes, status := pr.private_store_read(&store.store_port, slot_map_object_name(&name_place, space_number), buffer[:])
	store.load_reads += 1
	switch status {
	case .Ok:
	case .Absent:
		return false, .None
	case .Too_Large:
		return false, .Store_Damaged
	case .Failed:
		return false, .Store_Failed
	}
	if len(bytes) != SLOT_MAP_BYTES || string(bytes[:8]) != SLOT_MAP_MAGIC || byte_order.read_u32_little_endian(bytes, 8) != SLOT_MAP_VERSION || byte_order.read_u32_little_endian(bytes, 12) != space_number {
		return false, .Store_Damaged
	}
	at := SLOT_MAP_HEAD_BYTES + SPACE_SEGMENT_SLOTS * 8
	map_hash := blake3.derive_key(SLOT_MAP_HASH_DOMAIN, bytes[:at])
	if string(map_hash[:]) != string(bytes[at:]) {
		return false, .Store_Damaged
	}
	for slot in 0 ..< SPACE_SEGMENT_SLOTS {
		if ring != nil {
			ring.slot_map[slot] = byte_order.read_u64_little_endian(bytes, SLOT_MAP_HEAD_BYTES + slot * 8)
		}
	}
	return true, .None
}

// name_field_valid says if a name field of a stored object holds a name that
// space_open takes, and only zeros after it.
@(private = "file")
name_field_valid :: proc "contextless" (field: []u8) -> bool {
	length := 0
	for length < len(field) && field[length] != 0 {
		length += 1
	}
	if length == 0 || length >= SPACE_NAME_BYTES {
		return false
	}
	for value in field[:length] {
		if value < 0x21 || value > 0x7E {
			return false
		}
	}
	for value in field[length:] {
		if value != 0 {
			return false
		}
	}
	return true
}

// segment_head_write writes the head of a segment of space.
@(private = "file")
segment_head_write :: proc "contextless" (
	into: []u8,
	principal: u64,
	space_number: u32,
	space: ^Collector_Space,
	segment: u64,
	record_count: u32,
	previous: blake3.Hash,
) {
	first_serial := segment * SPACE_SEGMENT_RECORDS
	copy(into[SEGMENT_MAGIC_AT:][:8], SEGMENT_MAGIC)
	byte_order.write_u32_little_endian(into, SEGMENT_VERSION_AT, SEGMENT_VERSION)
	byte_order.write_u32_little_endian(into, SEGMENT_KIND_AT, u32(space.kind))
	byte_order.write_u32_little_endian(into, SEGMENT_FORWARDING_AT, u32(space.forwarding))
	byte_order.write_u32_little_endian(into, SEGMENT_SPACE_AT, space_number)
	byte_order.write_u32_little_endian(into, SEGMENT_BOUND_AT, space.bound)
	byte_order.write_u32_little_endian(into, SEGMENT_RECORD_SIZE_AT, space.record_size)
	byte_order.write_u64_little_endian(into, SEGMENT_PRINCIPAL_AT, principal)
	byte_order.write_u64_little_endian(into, SEGMENT_INDEX_AT, segment)
	byte_order.write_u64_little_endian(into, SEGMENT_FIRST_SERIAL_AT, first_serial)
	byte_order.write_u64_little_endian(into, SEGMENT_LAST_SERIAL_AT, first_serial + u64(record_count) - 1)
	byte_order.write_u64_little_endian(into, SEGMENT_RECORD_COUNT_AT, u64(record_count))
	copy(into[SEGMENT_SOURCE_AT:][:SPACE_NAME_BYTES], space.source[:])
	copy(into[SEGMENT_OUTPUT_AT:][:SPACE_NAME_BYTES], space.output[:])
	previous_hash := previous
	copy(into[SEGMENT_PREVIOUS_HASH_AT:][:blake3.HASH_SIZE], previous_hash[:])
}

@(private = "file")
segment_length :: proc "contextless" (record_size: u32, record_count: u32) -> int {
	return SEGMENT_HEAD_BYTES + int(record_count) * (SEGMENT_RECORD_HEAD_BYTES + int(record_size)) + SEGMENT_TAIL_BYTES
}

// segment_previous_hash gives the previous hash of the open segment of a
// space: the anchor for the first kept segment, else the last full one.
@(private = "file")
segment_previous_hash :: proc "contextless" (space: ^Collector_Space, segment: u64) -> blake3.Hash {
	if segment == space.kept_first_serial / SPACE_SEGMENT_RECORDS {
		return space.anchor_segment_hash
	}
	return space.closed_segment_hash
}

// segment_persist writes the open segment of an audit space with the record
// that comes next, whose link is link, and gives the hash of that segment.
// It changes nothing of the space: the caller keeps the record only once the
// write succeeded.
segment_persist :: proc "contextless" (
	store: ^Space_Store,
	space_number: u32,
	space: ^Collector_Space,
	record: []u8,
	time_ms: u64,
	link: blake3.Hash,
) -> (segment_hash: blake3.Hash, refusal: Space_Refusal) {
	serial := space.next_serial
	segment := serial / SPACE_SEGMENT_RECORDS
	first_index := segment * SPACE_SEGMENT_RECORDS
	// The ring holds each record of the open segment, and the slot of the
	// segment holds no kept segment: the bound of the space sees to both.
	ring_holds := first_index >= space.first_serial || space.count == 0 && first_index == serial
	if !ring_holds || segment - space.kept_first_serial / SPACE_SEGMENT_RECORDS >= SPACE_SEGMENT_SLOTS || first_index < space.kept_first_serial || len(record) != int(space.record_size) {
		return {}, .Store_Damaged
	}
	record_count := u32(serial - first_index + 1)
	// A new segment takes its slot in the map first: a stop between the two
	// writes leaves a map that names a segment that its slot does not hold
	// yet, which a start reads as the end of the records.
	slot := segment % SPACE_SEGMENT_SLOTS
	map_entry := &space.ring.slot_map[slot]
	if map_entry^ != segment + 1 {
		before := map_entry^
		map_entry^ = segment + 1
		if refusal = slot_map_persist(store, space_number); refusal != .None {
			map_entry^ = before
			return {}, refusal
		}
	}
	length := segment_length(space.record_size, record_count)
	bytes := store.segment_bytes[:length]
	segment_head_write(bytes, store.principal, space_number, space, segment, record_count, segment_previous_hash(space, segment))
	at := SEGMENT_HEAD_BYTES
	for index in first_index ..< serial {
		place := space_place_of(space, index)
		byte_order.write_u64_little_endian(bytes, at, space.ring.serials[place])
		byte_order.write_u64_little_endian(bytes, at + 8, space.ring.times[place])
		offset := int(place) * SPACE_RECORD_BYTES_MOST
		copy(bytes[at + SEGMENT_RECORD_HEAD_BYTES:][:space.record_size], space.ring.bytes[offset:][:space.record_size])
		at += SEGMENT_RECORD_HEAD_BYTES + int(space.record_size)
	}
	byte_order.write_u64_little_endian(bytes, at, serial)
	byte_order.write_u64_little_endian(bytes, at + 8, time_ms)
	copy(bytes[at + SEGMENT_RECORD_HEAD_BYTES:][:len(record)], record)
	at += SEGMENT_RECORD_HEAD_BYTES + len(record)
	last_link := link
	copy(bytes[at:][:blake3.HASH_SIZE], last_link[:])
	at += blake3.HASH_SIZE
	segment_hash = blake3.derive_key(SEGMENT_HASH_DOMAIN, bytes[:at])
	copy(bytes[at:][:blake3.HASH_SIZE], segment_hash[:])
	name_place: [SEGMENT_OBJECT_NAME_BYTES]u8
	name := segment_object_name(&name_place, space_number, segment)
	if pr.private_store_write(&store.store_port, name, bytes) != .Ok {
		return {}, .Store_Failed
	}
	return segment_hash, .None
}

// segment_check checks one stored segment of space whole: its length, its
// hash, its head against the terms of the space, previous (the hash of the
// segment before it) and the count that it holds, the serial of each
// record, the link of its last record. link is the link of the record
// before the segment, and becomes the link of its last record. With Load,
// the records go into the ring of the space, after the records before them;
// with Compare, each record that the ring holds must equal the stored one.
@(private = "file")
segment_check :: proc "contextless" (
	store: ^Space_Store,
	space_number: u32,
	space: ^Collector_Space,
	segment: u64,
	previous: blake3.Hash,
	bytes: []u8,
	link: ^blake3.Hash,
	use: Segment_Use,
) -> (segment_hash: blake3.Hash, record_count: u32, ok: bool) {
	if len(bytes) < SEGMENT_HEAD_BYTES + SEGMENT_TAIL_BYTES {
		return {}, 0, false
	}
	count_word := byte_order.read_u64_little_endian(bytes, SEGMENT_RECORD_COUNT_AT)
	if count_word < 1 || count_word > SPACE_SEGMENT_RECORDS {
		return {}, 0, false
	}
	record_count = u32(count_word)
	if len(bytes) != segment_length(space.record_size, record_count) {
		return {}, 0, false
	}
	hash_at := len(bytes) - blake3.HASH_SIZE
	segment_hash = blake3.derive_key(SEGMENT_HASH_DOMAIN, bytes[:hash_at])
	stored_hash: blake3.Hash
	copy(stored_hash[:], bytes[hash_at:])
	if segment_hash != stored_hash {
		return {}, 0, false
	}
	expected_head: [SEGMENT_HEAD_BYTES]u8
	segment_head_write(expected_head[:], store.principal, space_number, space, segment, record_count, previous)
	if string(expected_head[:]) != string(bytes[:SEGMENT_HEAD_BYTES]) {
		return {}, 0, false
	}
	first_index := segment * SPACE_SEGMENT_RECORDS
	switch use {
	case .Load:
		if space.next_serial != first_index || first_index + u64(record_count) - space.kept_first_serial > u64(space.bound) {
			return {}, 0, false
		}
	case .Compare:
		if first_index + u64(record_count) > space.next_serial {
			return {}, 0, false
		}
	}
	at := SEGMENT_HEAD_BYTES
	for index in first_index ..< first_index + u64(record_count) {
		serial := byte_order.read_u64_little_endian(bytes, at)
		time_ms := byte_order.read_u64_little_endian(bytes, at + 8)
		record := bytes[at + SEGMENT_RECORD_HEAD_BYTES:][:space.record_size]
		if serial != index {
			return {}, 0, false
		}
		link^ = space_record_hash(link^, serial, time_ms, record)
		switch use {
		case .Load:
			if space.count >= space.window {
				space_window_drop_oldest(space)
			}
			place := (space.first + space.count) % space.window
			if space.count == 0 {
				space.first_serial = serial
			}
			space.ring.serials[place] = serial
			space.ring.times[place] = time_ms
			space.ring.hashes[place] = link^
			copy(space.ring.bytes[int(place) * SPACE_RECORD_BYTES_MOST:][:space.record_size], record)
			space.count += 1
			space.next_serial = serial + 1
		case .Compare:
			if space.count > 0 && serial >= space.first_serial {
				place := space_place_of(space, serial)
				offset := int(place) * SPACE_RECORD_BYTES_MOST
				if space.ring.serials[place] != serial || space.ring.times[place] != time_ms || space.ring.hashes[place] != link^ {
					return {}, 0, false
				}
				if string(space.ring.bytes[offset:][:space.record_size]) != string(record) {
					return {}, 0, false
				}
			}
		}
		at += SEGMENT_RECORD_HEAD_BYTES + int(space.record_size)
	}
	stored_link: blake3.Hash
	copy(stored_link[:], bytes[at:][:blake3.HASH_SIZE])
	if stored_link != link^ {
		return {}, 0, false
	}
	if use == .Load {
		space.last_hash = link^
		if record_count == SPACE_SEGMENT_RECORDS {
			space.closed_segment_hash = segment_hash
		}
	}
	return segment_hash, record_count, true
}

// segment_tail_read reads the hash and the link of the last record of a
// stored segment that segment_check took before: the anchors of the
// segment after it.
@(private = "file")
segment_tail_read :: proc "contextless" (bytes: []u8) -> (segment_hash: blake3.Hash, last_link: blake3.Hash) {
	copy(segment_hash[:], bytes[len(bytes) - blake3.HASH_SIZE:])
	copy(last_link[:], bytes[len(bytes) - 2 * blake3.HASH_SIZE:][:blake3.HASH_SIZE])
	return segment_hash, last_link
}

// segment_index_of reads the number of the segment that a stored object of
// a slot holds, or false for an object too short to have a head.
@(private = "file")
segment_index_of :: proc "contextless" (bytes: []u8) -> (segment: u64, ok: bool) {
	if len(bytes) < SEGMENT_HEAD_BYTES {
		return 0, false
	}
	return byte_order.read_u64_little_endian(bytes, SEGMENT_INDEX_AT), true
}

// space_index_persist writes the index of the audit spaces of store, as the
// memory holds them now, with a row Removed for each place whose space was
// removed and that no space took again.
space_index_persist :: proc "contextless" (store: ^Space_Store) -> Space_Refusal {
	if !space_index_buffer_ensure(store, space_index_bytes_of(len(store.spaces))) {
		return .Memory_Refused
	}
	bytes := store.index_bytes
	copy(bytes[SPACE_INDEX_MAGIC_AT:][:8], SPACE_INDEX_MAGIC)
	byte_order.write_u32_little_endian(bytes, SPACE_INDEX_VERSION_AT, SPACE_INDEX_VERSION)
	byte_order.write_u64_little_endian(bytes, SPACE_INDEX_PRINCIPAL_AT, store.principal)
	count: u32 = 0
	at := SPACE_INDEX_HEAD_BYTES
	for &space, index in store.spaces {
		listed := space.active && space.kind == .Audit || !space.active && space.place_removed
		if !listed {
			continue
		}
		row := bytes[at:][:SPACE_INDEX_ROW_BYTES]
		for &value in row {
			value = 0
		}
		byte_order.write_u32_little_endian(row, SPACE_INDEX_ROW_SPACE_AT, u32(index + 1))
		count += 1
		at += SPACE_INDEX_ROW_BYTES
		if !space.active {
			byte_order.write_u64_little_endian(row, SPACE_INDEX_ROW_STATE_AT, u64(Space_Index_State.Removed))
			continue
		}
		byte_order.write_u32_little_endian(row, SPACE_INDEX_ROW_KIND_AT, u32(space.kind))
		byte_order.write_u32_little_endian(row, SPACE_INDEX_ROW_FORWARDING_AT, u32(space.forwarding))
		byte_order.write_u32_little_endian(row, SPACE_INDEX_ROW_BOUND_AT, space.bound)
		byte_order.write_u32_little_endian(row, SPACE_INDEX_ROW_RECORD_SIZE_AT, space.record_size)
		copy(row[SPACE_INDEX_ROW_SOURCE_AT:][:SPACE_NAME_BYTES], space.source[:])
		copy(row[SPACE_INDEX_ROW_OUTPUT_AT:][:SPACE_NAME_BYTES], space.output[:])
		byte_order.write_u64_little_endian(row, SPACE_INDEX_ROW_KEPT_FIRST_AT, space.kept_first_serial)
		copy(row[SPACE_INDEX_ROW_ANCHOR_SEGMENT_AT:][:blake3.HASH_SIZE], space.anchor_segment_hash[:])
		copy(row[SPACE_INDEX_ROW_ANCHOR_LINK_AT:][:blake3.HASH_SIZE], space.anchor_link[:])
		state := Space_Index_State.Open
		if space.closed {
			state = space.removing ? .Removing : .Closed
			byte_order.write_u64_little_endian(row, SPACE_INDEX_ROW_NEXT_SERIAL_AT, space.next_serial)
			last_link := space.last_hash
			copy(row[SPACE_INDEX_ROW_LAST_LINK_AT:][:blake3.HASH_SIZE], last_link[:])
			byte_order.write_u64_little_endian(row, SPACE_INDEX_ROW_CLOSED_AT_AT, u64(max(space.closed_at_ms, 0)))
		}
		byte_order.write_u64_little_endian(row, SPACE_INDEX_ROW_STATE_AT, u64(state))
	}
	byte_order.write_u32_little_endian(bytes, SPACE_INDEX_COUNT_AT, count)
	index_hash := blake3.derive_key(SPACE_INDEX_HASH_DOMAIN, bytes[:at])
	copy(bytes[at:][:blake3.HASH_SIZE], index_hash[:])
	at += blake3.HASH_SIZE
	if pr.private_store_write(&store.store_port, SPACE_INDEX_OBJECT_NAME, bytes[:at]) != .Ok {
		return .Store_Failed
	}
	return .None
}

// space_index_read reads the index object whole: the buffer grows while
// the object is larger, as the budget pays.
@(private = "file")
space_index_read :: proc "contextless" (store: ^Space_Store) -> (bytes: []u8, refusal: Space_Refusal) {
	if !space_index_buffer_ensure(store, space_index_bytes_of(max(len(store.spaces), 1))) {
		return nil, .Memory_Refused
	}
	for {
		status: pr.Private_Store_Status
		bytes, status = pr.private_store_read(&store.store_port, SPACE_INDEX_OBJECT_NAME, store.index_bytes)
		switch status {
		case .Ok:
			return bytes, .None
		case .Absent:
			return nil, .None
		case .Too_Large:
			if !space_index_buffer_ensure(store, 2 * len(store.index_bytes)) {
				return nil, .Memory_Refused
			}
		case .Failed:
			return nil, .Store_Failed
		}
	}
}

// space_index_load reads the index and makes each audit space that it names
// active, with its terms and no record. A missing index names no space.
@(private = "file")
space_index_load :: proc "contextless" (store: ^Space_Store) -> Space_Refusal {
	bytes, read_refusal := space_index_read(store)
	if read_refusal != .None || bytes == nil {
		return read_refusal
	}
	if len(bytes) < SPACE_INDEX_HEAD_BYTES + blake3.HASH_SIZE {
		return .Store_Damaged
	}
	count := byte_order.read_u32_little_endian(bytes, SPACE_INDEX_COUNT_AT)
	if (len(bytes) - SPACE_INDEX_HEAD_BYTES - blake3.HASH_SIZE) / SPACE_INDEX_ROW_BYTES < int(count) || len(bytes) != space_index_bytes_of(int(count)) {
		return .Store_Damaged
	}
	hash_at := len(bytes) - blake3.HASH_SIZE
	index_hash := blake3.derive_key(SPACE_INDEX_HASH_DOMAIN, bytes[:hash_at])
	if string(index_hash[:]) != string(bytes[hash_at:]) {
		return .Store_Damaged
	}
	if string(bytes[SPACE_INDEX_MAGIC_AT:][:8]) != SPACE_INDEX_MAGIC || byte_order.read_u32_little_endian(bytes, SPACE_INDEX_VERSION_AT) != SPACE_INDEX_VERSION {
		return .Store_Damaged
	}
	if byte_order.read_u64_little_endian(bytes, SPACE_INDEX_PRINCIPAL_AT) != store.principal {
		return .Store_Damaged
	}
	// The last row names the most places: the table grows to them first.
	// The buffer of the index does not move with it.
	if count > 0 {
		last_number := byte_order.read_u32_little_endian(bytes[SPACE_INDEX_HEAD_BYTES + (int(count) - 1) * SPACE_INDEX_ROW_BYTES:], SPACE_INDEX_ROW_SPACE_AT)
		if last_number < count {
			return .Store_Damaged
		}
		if !space_places_ensure(store, int(last_number)) {
			return .Memory_Refused
		}
	}
	previous_number: u32 = 0
	for row_index in 0 ..< int(count) {
		row := bytes[SPACE_INDEX_HEAD_BYTES + row_index * SPACE_INDEX_ROW_BYTES:][:SPACE_INDEX_ROW_BYTES]
		space_number := byte_order.read_u32_little_endian(row, SPACE_INDEX_ROW_SPACE_AT)
		// The rows go up by their number, so no number comes twice.
		if space_number <= previous_number || int(space_number) > len(store.spaces) {
			return .Store_Damaged
		}
		previous_number = space_number
		state, state_ok := enum_word.member_of_word(Space_Index_State, byte_order.read_u64_little_endian(row, SPACE_INDEX_ROW_STATE_AT))
		if !state_ok {
			return .Store_Damaged
		}
		space := &store.spaces[space_number - 1]
		space^ = {}
		if state == .Removed {
			// A removed place holds its number and its state, nothing else.
			for value, at in row {
				in_number := at < SPACE_INDEX_ROW_SPACE_AT + 4
				in_state := at >= SPACE_INDEX_ROW_STATE_AT && at < SPACE_INDEX_ROW_STATE_AT + 8
				if !in_number && !in_state && value != 0 {
					return .Store_Damaged
				}
			}
			space.place_removed = true
			continue
		}
		kind, kind_ok := collector_space_kind_from_word(u64(byte_order.read_u32_little_endian(row, SPACE_INDEX_ROW_KIND_AT)))
		if !kind_ok || kind != .Audit {
			return .Store_Damaged
		}
		forwarding, forwarding_ok := space_forwarding_of_word(u64(byte_order.read_u32_little_endian(row, SPACE_INDEX_ROW_FORWARDING_AT)))
		if !forwarding_ok {
			return .Store_Damaged
		}
		bound := byte_order.read_u32_little_endian(row, SPACE_INDEX_ROW_BOUND_AT)
		record_size := byte_order.read_u32_little_endian(row, SPACE_INDEX_ROW_RECORD_SIZE_AT)
		if bound < 1 || bound > SPACE_AUDIT_BOUND_MOST || record_size < 1 || record_size > SPACE_RECORD_BYTES_MOST {
			return .Store_Damaged
		}
		// The kept records start at a segment: a rotation removes whole
		// segments only.
		kept_first := byte_order.read_u64_little_endian(row, SPACE_INDEX_ROW_KEPT_FIRST_AT)
		if kept_first % SPACE_SEGMENT_RECORDS != 0 {
			return .Store_Damaged
		}
		window := min(bound, SPACE_RECORDS_MOST)
		source := row[SPACE_INDEX_ROW_SOURCE_AT:][:SPACE_NAME_BYTES]
		output := row[SPACE_INDEX_ROW_OUTPUT_AT:][:SPACE_NAME_BYTES]
		if !name_field_valid(source) || !name_field_valid(output) {
			return .Store_Damaged
		}
		space.active = true
		space.kind = kind
		space.forwarding = forwarding
		space.bound = bound
		space.window = window
		space.record_size = record_size
		copy(space.source[:], source)
		copy(space.output[:], output)
		space.kept_first_serial = kept_first
		space.next_serial = kept_first
		space.first_serial = kept_first
		copy(space.anchor_segment_hash[:], row[SPACE_INDEX_ROW_ANCHOR_SEGMENT_AT:][:blake3.HASH_SIZE])
		copy(space.anchor_link[:], row[SPACE_INDEX_ROW_ANCHOR_LINK_AT:][:blake3.HASH_SIZE])
		space.window_link = space.anchor_link
		space.last_hash = space.anchor_link
		closed_next_serial := byte_order.read_u64_little_endian(row, SPACE_INDEX_ROW_NEXT_SERIAL_AT)
		closed_last_link: blake3.Hash
		copy(closed_last_link[:], row[SPACE_INDEX_ROW_LAST_LINK_AT:][:blake3.HASH_SIZE])
		closed_at := byte_order.read_u64_little_endian(row, SPACE_INDEX_ROW_CLOSED_AT_AT)
		switch state {
		case .Open:
			// An open space finds its next serial and its last link in its
			// segments: the row holds none.
			if closed_next_serial != 0 || closed_last_link != {} || closed_at != 0 {
				return .Store_Damaged
			}
		case .Closed, .Removing:
			if closed_next_serial < kept_first || closed_next_serial - kept_first > u64(bound) || closed_at > u64(max(i64)) {
				return .Store_Damaged
			}
			space.closed = true
			space.removing = state == .Removing
			space.closed_at_ms = i64(closed_at)
			space.next_serial = closed_next_serial
			space.first_serial = closed_next_serial
			space.last_hash = closed_last_link
			space.window_link = closed_last_link
		case .Removed:
		}
	}
	return .None
}

// slot_holds_segment says if the slot of segment holds that segment, whole.
// An absent object or an older segment of the slot is no such segment.
@(private = "file")
slot_holds_segment :: proc "contextless" (store: ^Space_Store, space_number: u32, segment: u64) -> (held: bool, refusal: Space_Refusal) {
	name_place: [SEGMENT_OBJECT_NAME_BYTES]u8
	bytes, status := pr.private_store_read(&store.store_port, segment_object_name(&name_place, space_number, segment), store.segment_bytes[:])
	store.load_reads += 1
	switch status {
	case .Ok:
	case .Absent:
		return false, .None
	case .Too_Large:
		return false, .Store_Damaged
	case .Failed:
		return false, .Store_Failed
	}
	stored_segment, head_ok := segment_index_of(bytes)
	return head_ok && stored_segment == segment && segment_whole(bytes), .None
}

// space_segments_load reads one space at a start: its slot map, then the
// segments that hold its newest records into its ring, each chained to the
// one before it, from the hash and the last link of the segment before the
// first one that it reads (or the anchors). The map names one run of
// segments from the first kept one; a map that names a later segment past
// a gap, a segment in another slot, or a space that no index row names is
// damage. A map that names a last segment that its slot does not hold yet
// is a stop between the two writes of a new segment: the records end
// before it. The other segments are read by space_verify, not at a start:
// a start reads a few objects for each space, whatever its count.
@(private = "file")
space_segments_load :: proc "contextless" (store: ^Space_Store, space_number: u32) -> Space_Refusal {
	space := &store.spaces[space_number - 1]
	if space.active && space.closed {
		// A closed space has no window: its row holds its last link, and a
		// reader or space_verify reads its segments.
		return .None
	}
	if space.active && !space_window_take(store, space_number) {
		return .Memory_Refused
	}
	present, map_refusal := slot_map_load(store, space_number, space.ring)
	if map_refusal != .None {
		return map_refusal
	}
	if !space.active {
		return present ? .Store_Damaged : .None
	}
	slots := &space.ring.slot_map
	first_segment := space.kept_first_serial / SPACE_SEGMENT_RECORDS
	last: u64
	named := false
	for segment in first_segment ..< first_segment + SPACE_SEGMENT_SLOTS {
		if slots[segment % SPACE_SEGMENT_SLOTS] != segment + 1 {
			break
		}
		last, named = segment, true
	}
	for entry, slot in slots {
		if entry == 0 {
			continue
		}
		segment := entry - 1
		if segment % SPACE_SEGMENT_SLOTS != u64(slot) || (segment >= first_segment && (!named || segment > last)) {
			return .Store_Damaged
		}
	}
	// A map that names no segment, or no segment after last, is a map lost
	// or an older map, if the slot of the next segment holds that segment
	// whole: the map takes the slot before the segment is written, so a
	// segment that no map names was written after a newer map.
	next := named ? last + 1 : first_segment
	if held, refusal := slot_holds_segment(store, space_number, next); refusal != .None {
		return refusal
	} else if held {
		return .Store_Damaged
	}
	if !named {
		return .None
	}
	start := first_segment
	if last - first_segment >= LOAD_SEGMENTS_MOST {
		start = last - (LOAD_SEGMENTS_MOST - 1)
	}
	link := space.anchor_link
	previous := space.anchor_segment_hash
	name_place: [SEGMENT_OBJECT_NAME_BYTES]u8
	if start > first_segment {
		// The segment before the first one read gives the link and the hash
		// that chain it.
		bytes, status := pr.private_store_read(&store.store_port, segment_object_name(&name_place, space_number, start - 1), store.segment_bytes[:])
		store.load_reads += 1
		switch status {
		case .Ok:
		case .Absent, .Too_Large:
			return .Store_Damaged
		case .Failed:
			return .Store_Failed
		}
		stored_segment, head_ok := segment_index_of(bytes)
		if !head_ok || stored_segment != start - 1 || len(bytes) != segment_length(space.record_size, SPACE_SEGMENT_RECORDS) || !segment_whole(bytes) {
			return .Store_Damaged
		}
		previous, link = segment_tail_read(bytes)
		space.closed_segment_hash = previous
	}
	space.next_serial = start * SPACE_SEGMENT_RECORDS
	space.first_serial = space.next_serial
	space.window_link = link
	space.last_hash = link
	for segment in start ..= last {
		bytes, status := pr.private_store_read(&store.store_port, segment_object_name(&name_place, space_number, segment), store.segment_bytes[:])
		store.load_reads += 1
		older := false
		switch status {
		case .Ok:
			stored_segment, head_ok := segment_index_of(bytes)
			older = head_ok && stored_segment < segment && stored_segment % SPACE_SEGMENT_SLOTS == segment % SPACE_SEGMENT_SLOTS
		case .Absent:
			older = true
		case .Too_Large:
			return .Store_Damaged
		case .Failed:
			return .Store_Failed
		}
		if older {
			// Only the last segment may be missing: its map came first.
			return segment == last ? .None : .Store_Damaged
		}
		segment_hash, record_count, ok := segment_check(store, space_number, space, segment, previous, bytes, &link, .Load)
		if !ok || (record_count < SPACE_SEGMENT_RECORDS && segment != last) {
			return .Store_Damaged
		}
		previous = segment_hash
	}
	return .None
}

// Where records_read writes the records that it reads.
Records_Out :: struct {
	heads:         []Kept_Record_Head,
	bytes:         []u8,
	count:         int,
	written_bytes: int,
	limit:         int,
}

// records_out_put gives one record to the reader: its head and its bytes
// when both fit, and the count either way.
records_out_put :: proc "contextless" (out: ^Records_Out, serial, time_ms: u64, link: blake3.Hash, record: []u8) {
	size := len(record)
	if out.count < len(out.heads) && out.written_bytes + size <= len(out.bytes) {
		out.heads[out.count] = {
			serial     = i64(min(serial, u64(max(i64)))),
			time_ms    = i64(min(time_ms, u64(max(i64)))),
			size       = i64(size),
			chain_hash = value_kinds.Hash_Field(link),
		}
		copy(out.bytes[out.written_bytes:][:size], record)
		out.written_bytes += size
	}
	out.count += 1
}

// space_ring_first gives the serial of the first record of the ring in
// memory, or the next serial when the ring is empty.
space_ring_first :: proc "contextless" (space: ^Collector_Space) -> u64 {
	return space.count > 0 ? space.first_serial : space.next_serial
}

// space_segments_read reads the kept records from serial start up to
// before end from the segments of a space, for a reader of the whole
// audit: the records before the ring. It reads the segment before the
// first one for the link that chains it (or takes the anchor), checks each
// segment whole, its number, the serial of each record and its last link,
// and gives each record its link. It stops at the limit of out.
space_segments_read :: proc "contextless" (store: ^Space_Store, space_number: u32, space: ^Collector_Space, start: u64, end: u64, out: ^Records_Out) -> Space_Refusal {
	if start >= end || out.count >= out.limit {
		return .None
	}
	first_segment := space.kept_first_serial / SPACE_SEGMENT_RECORDS
	segment := start / SPACE_SEGMENT_RECORDS
	link := space.anchor_link
	name_place: [SEGMENT_OBJECT_NAME_BYTES]u8
	if segment > first_segment {
		bytes, status := pr.private_store_read(&store.store_port, segment_object_name(&name_place, space_number, segment - 1), store.segment_bytes[:])
		switch status {
		case .Ok:
		case .Absent, .Too_Large:
			return .Chain_Broken
		case .Failed:
			return .Store_Failed
		}
		stored_segment, head_ok := segment_index_of(bytes)
		if !head_ok || stored_segment != segment - 1 || !segment_whole(bytes) {
			return .Chain_Broken
		}
		_, link = segment_tail_read(bytes)
	}
	for ; segment * SPACE_SEGMENT_RECORDS < end && out.count < out.limit; segment += 1 {
		bytes, status := pr.private_store_read(&store.store_port, segment_object_name(&name_place, space_number, segment), store.segment_bytes[:])
		switch status {
		case .Ok:
		case .Absent, .Too_Large:
			return .Chain_Broken
		case .Failed:
			return .Store_Failed
		}
		stored_segment, head_ok := segment_index_of(bytes)
		if !head_ok || stored_segment != segment || !segment_whole(bytes) {
			return .Chain_Broken
		}
		record_count := byte_order.read_u64_little_endian(bytes, SEGMENT_RECORD_COUNT_AT)
		if record_count < 1 || record_count > SPACE_SEGMENT_RECORDS || len(bytes) != segment_length(space.record_size, u32(record_count)) {
			return .Chain_Broken
		}
		at := SEGMENT_HEAD_BYTES
		for index in segment * SPACE_SEGMENT_RECORDS ..< segment * SPACE_SEGMENT_RECORDS + record_count {
			serial := byte_order.read_u64_little_endian(bytes, at)
			time_ms := byte_order.read_u64_little_endian(bytes, at + 8)
			record := bytes[at + SEGMENT_RECORD_HEAD_BYTES:][:space.record_size]
			if serial != index {
				return .Chain_Broken
			}
			link = space_record_hash(link, serial, time_ms, record)
			// The join: the link of the last record before the ring is the
			// link where the chain of the ring starts. Segments rewritten
			// whole, each with its own hash and last link, hold together
			// alone, and only this compare ties them to the ring.
			if serial + 1 == end && end == space_ring_first(space) && link != space.window_link {
				return .Chain_Broken
			}
			if serial >= start && serial < end && out.count < out.limit {
				records_out_put(out, serial, time_ms, link, record)
			}
			at += SEGMENT_RECORD_HEAD_BYTES + int(space.record_size)
		}
		_, stored_link := segment_tail_read(bytes)
		if stored_link != link {
			return .Chain_Broken
		}
	}
	return .None
}

// segment_whole says if stored bytes hold a segment whose hash matches its
// bytes.
@(private = "file")
segment_whole :: proc "contextless" (bytes: []u8) -> bool {
	if len(bytes) < SEGMENT_HEAD_BYTES + SEGMENT_TAIL_BYTES {
		return false
	}
	segment_hash, _ := segment_tail_read(bytes)
	return blake3.derive_key(SEGMENT_HASH_DOMAIN, bytes[:len(bytes) - blake3.HASH_SIZE]) == segment_hash
}

// space_slots_free_check reads each slot of a space that holds no kept
// segment: the slots of the segments end ..< first_segment +
// SPACE_SEGMENT_SLOTS. Each holds no object, or a whole segment of that
// slot from before first_segment: one that rotated out. Anything else is
// damage: a segment after one that is missing, past the bound, a copy in
// another slot, a segment of a space that no index names. It reads each
// slot once, at the start of the collector and at each verify.
@(private = "file")
space_slots_free_check :: proc "contextless" (store: ^Space_Store, space_number: u32, active: bool, first_segment: u64, end: u64) -> Space_Refusal {
	for segment in end ..< first_segment + SPACE_SEGMENT_SLOTS {
		name_place: [SEGMENT_OBJECT_NAME_BYTES]u8
		name := segment_object_name(&name_place, space_number, segment)
		bytes, status := pr.private_store_read(&store.store_port, name, store.segment_bytes[:])
		switch status {
		case .Ok:
		case .Absent:
			continue
		case .Too_Large:
			return .Store_Damaged
		case .Failed:
			return .Store_Failed
		}
		stored_segment, head_ok := segment_index_of(bytes)
		if !active || !head_ok || stored_segment % SPACE_SEGMENT_SLOTS != segment % SPACE_SEGMENT_SLOTS || stored_segment >= first_segment || !segment_whole(bytes) {
			return .Store_Damaged
		}
	}
	return .None
}

// space_store_ready reads the audit spaces back from the private store at
// the first step of a store, and gives the state of that read to each step
// after it. A failed read leaves no space, and the next step reads again.
// A damaged object leaves no space, and refuses each step until the
// collector starts again: a part of an audit is never served as the whole.
space_store_ready :: proc "contextless" (store: ^Space_Store) -> Space_Refusal {
	switch store.load_state {
	case .Loaded:
		return .None
	case .Damaged:
		return .Store_Damaged
	case .Not_Loaded:
	}
	store.damaged_space = 0
	store.load_reads = 1
	refusal := space_index_load(store)
	// The place after the last one that the index names holds no slot map:
	// a new space takes the first free place, so an index that was lost,
	// or an older one, leaves a map there.
	if refusal == .None {
		name_place: [SEGMENT_OBJECT_NAME_BYTES]u8
		probe: [1]u8
		_, status := pr.private_store_read(&store.store_port, slot_map_object_name(&name_place, u32(len(store.spaces) + 1)), probe[:])
		store.load_reads += 1
		switch status {
		case .Absent:
		case .Ok, .Too_Large:
			store.damaged_space = u32(len(store.spaces) + 1)
			refusal = .Store_Damaged
		case .Failed:
			refusal = .Store_Failed
		}
	}
	for space_number in u32(1) ..= u32(len(store.spaces)) {
		if refusal != .None {
			break
		}
		refusal = space_segments_load(store, space_number)
		if refusal == .Store_Damaged {
			store.damaged_space = space_number
		}
	}
	if refusal == .None {
		store.load_state = .Loaded
		return .None
	}
	// A read that stopped in the middle leaves no part of a space, and no
	// window.
	for space_number in u32(1) ..= u32(len(store.spaces)) {
		space_window_give(store, space_number)
	}
	// The places stay in the memory of the port, empty.
	for &space in store.spaces {
		space = {}
	}
	switch refusal {
	case .Store_Damaged:
		store.load_state = .Damaged
		return .Store_Damaged
	case .Memory_Refused:
		// The budget pays fewer windows than the open spaces of the index:
		// the next step reads again.
		return .Memory_Refused
	case .None, .Bad_Kind, .Bad_Forwarding, .Bad_Bound, .Space_Limit_Reached, .Bad_Name, .Bad_Record_Size, .Unknown_Space, .Space_Full, .Forward_Full, .Wrong_Size, .Not_Principal, .Own_Space, .Chain_Broken, .Forward_Empty, .Bad_Limit, .Store_Failed, .Space_Held, .Space_Closed, .Space_Removed, .Act_Space:
	}
	return .Store_Failed
}

// space_closed_pass dates each closed space that has no date yet, and
// removes each closed space whose retention ended at date_ms
// (src/md/features/wide_grants.md, "The end of a closed audit space"). The
// row says Removing in the index before the first object goes, so a stop in
// the middle goes on at the next pass; then the segments of its kept
// records and its slot map go, and the row says Removed. A date that is
// not known dates nothing and removes nothing; a date before the close
// removes nothing. A refused write or remove stops the pass, and the next
// pass goes on. It gives the spaces removed in this pass.
space_closed_pass :: proc "contextless" (store: ^Space_Store, date_ms: i64, date_known: bool, retention_ms: i64) -> (removed: int, refusal: Space_Refusal) {
	if ready := space_store_ready(store); ready != .None {
		return 0, ready
	}
	if store.index_dirty {
		if refusal = space_index_persist(store); refusal != .None {
			return 0, refusal
		}
		store.index_dirty = false
	}
	dated := false
	for &space, index in store.spaces {
		if !space.active || !space.closed {
			continue
		}
		if space.closed_at_ms == 0 {
			if date_known && date_ms > 0 {
				space.closed_at_ms = date_ms
				dated = true
			}
			continue
		}
		if !space.removing {
			if !date_known || date_ms < space.closed_at_ms || date_ms - space.closed_at_ms < max(retention_ms, 0) {
				continue
			}
			space.removing = true
			if refusal = space_index_persist(store); refusal != .None {
				space.removing = false
				return removed, refusal
			}
			dated = false
		}
		if refusal = space_objects_remove(store, u32(index + 1)); refusal != .None {
			return removed, refusal
		}
		space = {place_removed = true}
		removed += 1
		store.index_dirty = true
	}
	if dated || store.index_dirty {
		if refusal = space_index_persist(store); refusal != .None {
			store.index_dirty = true
			return removed, refusal
		}
		store.index_dirty = false
	}
	return removed, .None
}

// space_objects_remove removes each slot of the place of a space and its
// slot map: the slots of the kept records, and those of segments that
// rotated out, which a rotation leaves in their slot until a later segment
// takes it. A new space in the place then finds no slot taken. An object
// that is absent was removed before.
@(private = "file")
space_objects_remove :: proc "contextless" (store: ^Space_Store, space_number: u32) -> Space_Refusal {
	name_place: [SEGMENT_OBJECT_NAME_BYTES]u8
	for slot in u64(0) ..< SPACE_SEGMENT_SLOTS {
		switch pr.private_store_remove(&store.store_port, segment_object_name(&name_place, space_number, slot)) {
		case .Ok, .Absent:
		case .Too_Large, .Failed:
			return .Store_Failed
		}
	}
	switch pr.private_store_remove(&store.store_port, slot_map_object_name(&name_place, space_number)) {
	case .Ok, .Absent:
	case .Too_Large, .Failed:
		return .Store_Failed
	}
	return .None
}

// space_closed_next_due gives when space_closed_pass has work next: the
// earliest end of a retention, at once for a removal that stopped or a
// write that waits, and soon for a closed space with no date yet.
space_closed_next_due :: proc "contextless" (store: ^Space_Store, retention_ms: i64) -> (due_date_ms: i64, dated_due: bool, at_once: bool, undated: bool) {
	at_once = store.index_dirty
	for &space in store.spaces {
		if !space.active || !space.closed {
			continue
		}
		switch {
		case space.removing:
			at_once = true
		case space.closed_at_ms == 0:
			undated = true
		case:
			end := space.closed_at_ms + max(retention_ms, 0)
			if end < space.closed_at_ms {
				end = max(i64)
			}
			if !dated_due || end < due_date_ms {
				due_date_ms, dated_due = end, true
			}
		}
	}
	return due_date_ms, dated_due, at_once, undated
}

// space_segments_verify reads each kept segment of an audit space from the
// private store, from its anchors, and compares it with the space: its
// hash, its link to the segment before it, its count, and each record that
// the ring holds. It gives the first serial of the first segment that does
// not match. A segment that is missing, or a newer one after the last,
// breaks the chain too.
space_segments_verify :: proc "contextless" (store: ^Space_Store, space_number: u32, space: ^Collector_Space) -> (refusal: Space_Refusal, failing_serial: u64) {
	link := space.anchor_link
	previous := space.anchor_segment_hash
	first_segment := space.kept_first_serial / SPACE_SEGMENT_RECORDS
	segment_count := space_segment_count(space)
	for segment in first_segment ..< first_segment + segment_count {
		failing_serial = segment * SPACE_SEGMENT_RECORDS
		name_place: [SEGMENT_OBJECT_NAME_BYTES]u8
		name := segment_object_name(&name_place, space_number, segment)
		bytes, status := pr.private_store_read(&store.store_port, name, store.segment_bytes[:])
		switch status {
		case .Ok:
		case .Absent, .Too_Large:
			return .Chain_Broken, failing_serial
		case .Failed:
			return .Store_Failed, 0
		}
		segment_hash, record_count, ok := segment_check(store, space_number, space, segment, previous, bytes, &link, .Compare)
		expected_count := min(space.next_serial - failing_serial, SPACE_SEGMENT_RECORDS)
		if !ok || u64(record_count) != expected_count {
			return .Chain_Broken, failing_serial
		}
		previous = segment_hash
	}
	if link != space.last_hash {
		return .Chain_Broken, space.next_serial
	}
	after := first_segment + segment_count
	switch space_slots_free_check(store, space_number, true, first_segment, after) {
	case .None:
	case .Store_Failed:
		return .Store_Failed, 0
	case .Store_Damaged, .Bad_Kind, .Bad_Forwarding, .Bad_Bound, .Space_Limit_Reached, .Bad_Name, .Bad_Record_Size, .Unknown_Space, .Wrong_Size, .Not_Principal, .Own_Space, .Chain_Broken, .Forward_Empty, .Forward_Full, .Space_Full, .Bad_Limit, .Space_Held, .Memory_Refused, .Space_Closed, .Space_Removed, .Act_Space:
		return .Chain_Broken, after * SPACE_SEGMENT_RECORDS
	}
	return .None, 0
}

// space_rotate_before takes out of an audit space the records before
// serial, whole segments at a time: the segment that holds serial stays,
// and so do the records after it. The index keeps the new first kept
// record with its anchors, read from the last segment that leaves; the
// slots of the segments that left take later segments. The records that
// left leave the ring too, and count as removed. A refusal changes nothing.
space_rotate_before :: proc "contextless" (store: ^Space_Store, space_number: u32, serial: u64) -> Space_Refusal {
	if ready := space_store_ready(store); ready != .None {
		return ready
	}
	space := space_of(store, space_number)
	if space == nil {
		return .Unknown_Space
	}
	if space.kind != .Audit {
		return .Bad_Kind
	}
	new_first := min(serial, space.next_serial) / SPACE_SEGMENT_RECORDS * SPACE_SEGMENT_RECORDS
	if new_first <= space.kept_first_serial {
		return .None
	}
	// The anchors are the hash and the last link of the segment before the
	// new first one, which is whole and full.
	last_left := new_first / SPACE_SEGMENT_RECORDS - 1
	name_place: [SEGMENT_OBJECT_NAME_BYTES]u8
	name := segment_object_name(&name_place, space_number, last_left)
	bytes, status := pr.private_store_read(&store.store_port, name, store.segment_bytes[:])
	switch status {
	case .Ok:
	case .Absent, .Too_Large:
		return .Store_Damaged
	case .Failed:
		return .Store_Failed
	}
	stored_segment, head_ok := segment_index_of(bytes)
	if !head_ok || stored_segment != last_left || len(bytes) != segment_length(space.record_size, SPACE_SEGMENT_RECORDS) {
		return .Store_Damaged
	}
	segment_hash, last_link := segment_tail_read(bytes)
	if blake3.derive_key(SEGMENT_HASH_DOMAIN, bytes[:len(bytes) - blake3.HASH_SIZE]) != segment_hash {
		return .Store_Damaged
	}
	before := space^
	space.removed += new_first - space.kept_first_serial
	space.kept_first_serial = new_first
	space.anchor_segment_hash = segment_hash
	space.anchor_link = last_link
	for space.count > 0 && space.first_serial < new_first {
		space_window_drop_oldest(space)
	}
	if space.count == 0 {
		space.first_serial = space.next_serial
	}
	if persisted := space_index_persist(store); persisted != .None {
		space^ = before
		return persisted
	}
	return .None
}

