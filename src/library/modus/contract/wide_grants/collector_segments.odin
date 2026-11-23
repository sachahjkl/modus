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
import pr "modus:contract/plans_recipes"

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
SPACE_INDEX_VERSION :: 2

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
SPACE_INDEX_ROW_BYTES :: SPACE_INDEX_ROW_ANCHOR_LINK_AT + blake3.HASH_SIZE
SPACE_INDEX_BYTES_MOST :: SPACE_INDEX_HEAD_BYTES + SPACE_CAPACITY * SPACE_INDEX_ROW_BYTES + blake3.HASH_SIZE

#assert(SPACE_INDEX_ROW_BYTES == 156)

// The bytes of the name of a segment object: "collector_space_<n>_segment_<k>".
SEGMENT_OBJECT_NAME_BYTES :: 48

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
	length := segment_length(space.record_size, record_count)
	bytes := store.segment_bytes[:length]
	segment_head_write(bytes, store.principal, space_number, space, segment, record_count, segment_previous_hash(space, segment))
	at := SEGMENT_HEAD_BYTES
	for index in first_index ..< serial {
		place := space_place_of(space, index)
		byte_order.write_u64_little_endian(bytes, at, space.serials[place])
		byte_order.write_u64_little_endian(bytes, at + 8, space.times[place])
		offset := int(place) * SPACE_RECORD_BYTES_MOST
		copy(bytes[at + SEGMENT_RECORD_HEAD_BYTES:][:space.record_size], space.bytes[offset:][:space.record_size])
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
			space.serials[place] = serial
			space.times[place] = time_ms
			space.hashes[place] = link^
			copy(space.bytes[int(place) * SPACE_RECORD_BYTES_MOST:][:space.record_size], record)
			space.count += 1
			space.next_serial = serial + 1
		case .Compare:
			if space.count > 0 && serial >= space.first_serial {
				place := space_place_of(space, serial)
				offset := int(place) * SPACE_RECORD_BYTES_MOST
				if space.serials[place] != serial || space.times[place] != time_ms || space.hashes[place] != link^ {
					return {}, 0, false
				}
				if string(space.bytes[offset:][:space.record_size]) != string(record) {
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
// memory holds them now.
space_index_persist :: proc "contextless" (store: ^Space_Store) -> Space_Refusal {
	bytes := store.index_bytes[:]
	copy(bytes[SPACE_INDEX_MAGIC_AT:][:8], SPACE_INDEX_MAGIC)
	byte_order.write_u32_little_endian(bytes, SPACE_INDEX_VERSION_AT, SPACE_INDEX_VERSION)
	byte_order.write_u64_little_endian(bytes, SPACE_INDEX_PRINCIPAL_AT, store.principal)
	count: u32 = 0
	at := SPACE_INDEX_HEAD_BYTES
	for &space, index in store.spaces {
		if !space.active || space.kind != .Audit {
			continue
		}
		row := bytes[at:][:SPACE_INDEX_ROW_BYTES]
		byte_order.write_u32_little_endian(row, SPACE_INDEX_ROW_SPACE_AT, u32(index + 1))
		byte_order.write_u32_little_endian(row, SPACE_INDEX_ROW_KIND_AT, u32(space.kind))
		byte_order.write_u32_little_endian(row, SPACE_INDEX_ROW_FORWARDING_AT, u32(space.forwarding))
		byte_order.write_u32_little_endian(row, SPACE_INDEX_ROW_BOUND_AT, space.bound)
		byte_order.write_u32_little_endian(row, SPACE_INDEX_ROW_RECORD_SIZE_AT, space.record_size)
		copy(row[SPACE_INDEX_ROW_SOURCE_AT:][:SPACE_NAME_BYTES], space.source[:])
		copy(row[SPACE_INDEX_ROW_OUTPUT_AT:][:SPACE_NAME_BYTES], space.output[:])
		byte_order.write_u64_little_endian(row, SPACE_INDEX_ROW_KEPT_FIRST_AT, space.kept_first_serial)
		copy(row[SPACE_INDEX_ROW_ANCHOR_SEGMENT_AT:][:blake3.HASH_SIZE], space.anchor_segment_hash[:])
		copy(row[SPACE_INDEX_ROW_ANCHOR_LINK_AT:][:blake3.HASH_SIZE], space.anchor_link[:])
		count += 1
		at += SPACE_INDEX_ROW_BYTES
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

// space_index_load reads the index and makes each audit space that it names
// active, with its terms and no record. A missing index names no space.
@(private = "file")
space_index_load :: proc "contextless" (store: ^Space_Store) -> Space_Refusal {
	bytes, status := pr.private_store_read(&store.store_port, SPACE_INDEX_OBJECT_NAME, store.index_bytes[:])
	switch status {
	case .Ok:
	case .Absent:
		return .None
	case .Too_Large:
		return .Store_Damaged
	case .Failed:
		return .Store_Failed
	}
	if len(bytes) < SPACE_INDEX_HEAD_BYTES + blake3.HASH_SIZE {
		return .Store_Damaged
	}
	count := byte_order.read_u32_little_endian(bytes, SPACE_INDEX_COUNT_AT)
	if count > SPACE_CAPACITY || len(bytes) != SPACE_INDEX_HEAD_BYTES + int(count) * SPACE_INDEX_ROW_BYTES + blake3.HASH_SIZE {
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
	previous_number: u32 = 0
	room: u32 = 0
	for row_index in 0 ..< int(count) {
		row := bytes[SPACE_INDEX_HEAD_BYTES + row_index * SPACE_INDEX_ROW_BYTES:][:SPACE_INDEX_ROW_BYTES]
		space_number := byte_order.read_u32_little_endian(row, SPACE_INDEX_ROW_SPACE_AT)
		// The rows go up by their number, so no number comes twice.
		if space_number <= previous_number || space_number > SPACE_CAPACITY {
			return .Store_Damaged
		}
		previous_number = space_number
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
		room += window
		if room > SPACE_ROOM_RECORDS {
			return .Store_Damaged
		}
		space := &store.spaces[space_number - 1]
		space^ = {}
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
	}
	return .None
}

// space_segments_load reads the kept segments of one space in order, from
// the first kept one, into its ring, each chained to the one before it. The
// first slot with no kept segment ends them; space_slots_free_check then
// reads each other slot. A space that no index row names has no segment.
@(private = "file")
space_segments_load :: proc "contextless" (store: ^Space_Store, space_number: u32) -> Space_Refusal {
	space := &store.spaces[space_number - 1]
	if !space.active {
		return space_slots_free_check(store, space_number, false, 0, 0)
	}
	link := space.anchor_link
	previous := space.anchor_segment_hash
	first_segment := space.kept_first_serial / SPACE_SEGMENT_RECORDS
	for segment in first_segment ..< first_segment + SPACE_SEGMENT_SLOTS {
		name_place: [SEGMENT_OBJECT_NAME_BYTES]u8
		name := segment_object_name(&name_place, space_number, segment)
		bytes, status := pr.private_store_read(&store.store_port, name, store.segment_bytes[:])
		switch status {
		case .Ok:
		case .Absent:
			return space_slots_free_check(store, space_number, true, first_segment, segment)
		case .Too_Large:
			return .Store_Damaged
		case .Failed:
			return .Store_Failed
		}
		stored_segment, head_ok := segment_index_of(bytes)
		if head_ok && stored_segment < first_segment {
			// A segment that rotated out holds the slot: the kept ones ended.
			return space_slots_free_check(store, space_number, true, first_segment, segment)
		}
		segment_hash, record_count, ok := segment_check(store, space_number, space, segment, previous, bytes, &link, .Load)
		if !ok {
			return .Store_Damaged
		}
		previous = segment_hash
		if record_count < SPACE_SEGMENT_RECORDS {
			return space_slots_free_check(store, space_number, true, first_segment, segment + 1)
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
	refusal := space_index_load(store)
	for space_number in u32(1) ..= SPACE_CAPACITY {
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
	// A read that stopped in the middle leaves no part of a space.
	store.spaces = {}
	if refusal == .Store_Damaged {
		store.load_state = .Damaged
		return .Store_Damaged
	}
	return .Store_Failed
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
	case .Store_Damaged, .Bad_Kind, .Bad_Forwarding, .Bad_Bound, .Bound_Past_Room, .Space_Limit_Reached, .Bad_Name, .Bad_Record_Size, .Unknown_Space, .Wrong_Size, .Not_Principal, .Own_Space, .Chain_Broken, .Forward_Empty, .Forward_Full, .Space_Full, .Bad_Limit, .Space_Held:
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

