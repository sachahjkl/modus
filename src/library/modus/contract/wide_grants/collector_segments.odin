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
package wide_grants

import "modus:contract/blake3"
import "modus:contract/byte_order"
import pr "modus:contract/plans_recipes"

// The records of one segment. A space holds at most SPACE_RECORDS_MOST
// records, so it has at most SPACE_SEGMENTS_MOST segments.
SPACE_SEGMENT_RECORDS :: 16
SPACE_SEGMENTS_MOST :: SPACE_RECORDS_MOST / SPACE_SEGMENT_RECORDS

#assert(SPACE_RECORDS_MOST % SPACE_SEGMENT_RECORDS == 0)

// The first bytes of a segment and of the index, and the version of each.
SEGMENT_MAGIC :: "mcolsegm"
SPACE_INDEX_MAGIC :: "mcolspcs"
SEGMENT_VERSION :: 1
SPACE_INDEX_VERSION :: 1

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
SPACE_INDEX_ROW_BYTES :: SPACE_INDEX_ROW_OUTPUT_AT + SPACE_NAME_BYTES
SPACE_INDEX_BYTES_MOST :: SPACE_INDEX_HEAD_BYTES + SPACE_CAPACITY * SPACE_INDEX_ROW_BYTES + blake3.HASH_SIZE

#assert(SPACE_INDEX_ROW_BYTES == 84)

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
space_segment_count :: proc "contextless" (space: ^Collector_Space) -> u32 {
	return (space.count + SPACE_SEGMENT_RECORDS - 1) / SPACE_SEGMENT_RECORDS
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

// segment_object_name gives the name of the segment segment of the space
// space_number in into.
segment_object_name :: proc "contextless" (into: ^[SEGMENT_OBJECT_NAME_BYTES]u8, space_number: u32, segment: u32) -> string {
	at := text_write(into[:], 0, "collector_space_")
	at = decimal_write(into[:], at, space_number)
	at = text_write(into[:], at, "_segment_")
	at = decimal_write(into[:], at, segment)
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
	segment: u32,
	record_count: u32,
	previous: blake3.Hash,
) {
	first_serial := u64(segment) * SPACE_SEGMENT_RECORDS
	copy(into[SEGMENT_MAGIC_AT:][:8], SEGMENT_MAGIC)
	byte_order.write_u32_little_endian(into, SEGMENT_VERSION_AT, SEGMENT_VERSION)
	byte_order.write_u32_little_endian(into, SEGMENT_KIND_AT, u32(space.kind))
	byte_order.write_u32_little_endian(into, SEGMENT_FORWARDING_AT, u32(space.forwarding))
	byte_order.write_u32_little_endian(into, SEGMENT_SPACE_AT, space_number)
	byte_order.write_u32_little_endian(into, SEGMENT_BOUND_AT, space.bound)
	byte_order.write_u32_little_endian(into, SEGMENT_RECORD_SIZE_AT, space.record_size)
	byte_order.write_u64_little_endian(into, SEGMENT_PRINCIPAL_AT, principal)
	byte_order.write_u64_little_endian(into, SEGMENT_INDEX_AT, u64(segment))
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

@(private = "file")
segment_previous_hash :: proc "contextless" (space: ^Collector_Space, segment: u32) -> blake3.Hash {
	if segment == 0 {
		return {}
	}
	return space.segment_hashes[segment - 1]
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
	segment := u32(serial / SPACE_SEGMENT_RECORDS)
	if segment >= SPACE_SEGMENTS_MOST || u64(space.count) != serial || len(record) != int(space.record_size) {
		// An audit space removes no record: its serials are its places.
		return {}, .Store_Damaged
	}
	first_index := segment * SPACE_SEGMENT_RECORDS
	record_count := space.count - first_index + 1
	length := segment_length(space.record_size, record_count)
	bytes := store.segment_bytes[:length]
	segment_head_write(bytes, store.principal, space_number, space, segment, record_count, segment_previous_hash(space, segment))
	at := SEGMENT_HEAD_BYTES
	for index in first_index ..< space.count {
		place := (space.first + index) % space.bound
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
// hash, its head against the terms of the space, the segment before it and
// the count that it holds, the serial of each record, the link of its last
// record. link is the link of the record before the segment, and becomes the
// link of its last record. With Load, the records go into the space; with
// Compare, each must equal the one that the space holds.
@(private = "file")
segment_check :: proc "contextless" (
	store: ^Space_Store,
	space_number: u32,
	space: ^Collector_Space,
	segment: u32,
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
	segment_head_write(expected_head[:], store.principal, space_number, space, segment, record_count, segment_previous_hash(space, segment))
	if string(expected_head[:]) != string(bytes[:SEGMENT_HEAD_BYTES]) {
		return {}, 0, false
	}
	first_index := segment * SPACE_SEGMENT_RECORDS
	switch use {
	case .Load:
		if space.count != first_index || first_index + record_count > space.bound {
			return {}, 0, false
		}
	case .Compare:
		if first_index + record_count > space.count {
			return {}, 0, false
		}
	}
	at := SEGMENT_HEAD_BYTES
	for index in first_index ..< first_index + record_count {
		serial := byte_order.read_u64_little_endian(bytes, at)
		time_ms := byte_order.read_u64_little_endian(bytes, at + 8)
		record := bytes[at + SEGMENT_RECORD_HEAD_BYTES:][:space.record_size]
		if serial != u64(index) {
			return {}, 0, false
		}
		link^ = space_record_hash(link^, serial, time_ms, record)
		place := (space.first + index) % space.bound
		offset := int(place) * SPACE_RECORD_BYTES_MOST
		switch use {
		case .Load:
			space.serials[place] = serial
			space.times[place] = time_ms
			space.hashes[place] = link^
			copy(space.bytes[offset:][:space.record_size], record)
		case .Compare:
			if space.serials[place] != serial || space.times[place] != time_ms || space.hashes[place] != link^ {
				return {}, 0, false
			}
			if string(space.bytes[offset:][:space.record_size]) != string(record) {
				return {}, 0, false
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
		space.count += record_count
		space.next_serial = u64(space.count)
		space.last_hash = link^
		space.segment_hashes[segment] = segment_hash
	}
	return segment_hash, record_count, true
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
		if bound < 1 || bound > SPACE_RECORDS_MOST || record_size < 1 || record_size > SPACE_RECORD_BYTES_MOST {
			return .Store_Damaged
		}
		source := row[SPACE_INDEX_ROW_SOURCE_AT:][:SPACE_NAME_BYTES]
		output := row[SPACE_INDEX_ROW_OUTPUT_AT:][:SPACE_NAME_BYTES]
		if !name_field_valid(source) || !name_field_valid(output) {
			return .Store_Damaged
		}
		room += bound
		if room > SPACE_ROOM_RECORDS {
			return .Store_Damaged
		}
		space := &store.spaces[space_number - 1]
		space^ = {}
		space.active = true
		space.kind = kind
		space.forwarding = forwarding
		space.bound = bound
		space.record_size = record_size
		copy(space.source[:], source)
		copy(space.output[:], output)
	}
	return .None
}

// space_segments_load reads each segment of one space in order, and checks
// that no segment follows a missing one or one that is not full. A space
// with no index row must have no segment.
@(private = "file")
space_segments_load :: proc "contextless" (store: ^Space_Store, space_number: u32) -> Space_Refusal {
	space := &store.spaces[space_number - 1]
	link: blake3.Hash
	ended := false
	// One past the last segment of the largest space too: an object there is
	// a segment that no audit space can hold.
	for segment in u32(0) ..= SPACE_SEGMENTS_MOST {
		name_place: [SEGMENT_OBJECT_NAME_BYTES]u8
		name := segment_object_name(&name_place, space_number, segment)
		bytes, status := pr.private_store_read(&store.store_port, name, store.segment_bytes[:])
		switch status {
		case .Ok:
		case .Absent:
			ended = true
			continue
		case .Too_Large:
			return .Store_Damaged
		case .Failed:
			return .Store_Failed
		}
		if ended || !space.active || segment >= SPACE_SEGMENTS_MOST {
			return .Store_Damaged
		}
		_, record_count, ok := segment_check(store, space_number, space, segment, bytes, &link, .Load)
		if !ok {
			return .Store_Damaged
		}
		if record_count < SPACE_SEGMENT_RECORDS {
			ended = true
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

// space_segments_verify reads each segment of an audit space from the
// private store and compares it with the space in memory: its hash, its
// link to the segment before it, and each of its records. It gives the
// first serial of the first segment that does not match. A segment that is
// missing, or one past the last, breaks the chain too.
space_segments_verify :: proc "contextless" (store: ^Space_Store, space_number: u32, space: ^Collector_Space) -> (refusal: Space_Refusal, failing_serial: u64) {
	link: blake3.Hash
	segment_count := space_segment_count(space)
	for segment in u32(0) ..= segment_count {
		failing_serial = u64(segment) * SPACE_SEGMENT_RECORDS
		name_place: [SEGMENT_OBJECT_NAME_BYTES]u8
		name := segment_object_name(&name_place, space_number, segment)
		bytes, status := pr.private_store_read(&store.store_port, name, store.segment_bytes[:])
		switch status {
		case .Ok:
		case .Absent:
			if segment == segment_count {
				return .None, 0
			}
			return .Chain_Broken, failing_serial
		case .Too_Large:
			return .Chain_Broken, failing_serial
		case .Failed:
			return .Store_Failed, 0
		}
		if segment == segment_count {
			return .Chain_Broken, failing_serial
		}
		segment_hash, record_count, ok := segment_check(store, space_number, space, segment, bytes, &link, .Compare)
		expected_count := min(space.count - segment * SPACE_SEGMENT_RECORDS, SPACE_SEGMENT_RECORDS)
		if !ok || segment_hash != space.segment_hashes[segment] || record_count != expected_count {
			return .Chain_Broken, failing_serial
		}
	}
	return .None, 0
}
