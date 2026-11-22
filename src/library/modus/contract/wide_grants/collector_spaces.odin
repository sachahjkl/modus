// The spaces of the collector: one bounded space of kept records for each
// pair of a source process and a record output, and the queue of the
// records that the collector forwards after it kept them
// (src/md/features/module_outputs.md).
//
// A space Keep removes its oldest record when it is full and counts it. A
// space Audit never removes a record: a full audit space refuses the next
// one, so its writer waits and no record is lost. A record of a space that
// forwards enters the forward queue only after the space kept it, and a full
// forward queue refuses the record before the space keeps it: the collector
// never forwards a record that it did not keep, and never drops one in
// silence.
//
// The store is pure: its caller gives each time and each identity, and the
// store calls no kernel operation and allocates no memory.
package wide_grants

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/value_kinds"

// The spaces that one collector holds at once.
SPACE_CAPACITY :: 8

// The records that one space holds at most: the largest bound of a space.
SPACE_RECORDS_MOST :: 64

// The records that the bounds of all the spaces hold together: a space whose
// bound does not fit what the others left is refused.
SPACE_ROOM_RECORDS :: 256

// The bytes of a record of a space at most: the largest record that a record
// description allows.
SPACE_RECORD_BYTES_MOST :: 256

// The records that wait to be forwarded at most, across the spaces.
FORWARD_QUEUE_CAPACITY :: 16

// The bytes of the name of a source process and of a record output.
SPACE_NAME_BYTES :: 32

// The context string of the chain of the records of an audit space.
SPACE_RECORD_HASH_DOMAIN :: "modus collector record v1"

// Whether a space forwards each record that it keeps.
Space_Forwarding :: enum u64 {
	None    = 0,
	Keeps   = 1,
	Forward = 2,
}

// Why the store refuses a step. A refused step changes nothing.
Space_Refusal :: enum u8 {
	None                = 0,
	Bad_Kind            = 1,
	Bad_Forwarding      = 2,
	Bad_Bound           = 3,
	Bound_Past_Room     = 4,
	Space_Limit_Reached = 5,
	Bad_Name            = 6,
	Bad_Record_Size     = 7,
	Unknown_Space       = 8,
	Space_Full          = 9,
	Forward_Full        = 10,
	Wrong_Size          = 11,
	Not_Principal       = 12,
	Own_Space           = 13,
	Chain_Broken        = 14,
	Forward_Empty       = 15,
	Bad_Limit           = 16,
}

// The terms of a space, as space_open takes them: the kind (Keep or Audit),
// the bound in records, whether it forwards, and the size of its record.
Space_Terms :: struct {
	kind_word:       i64,
	bound_records:   i64,
	forwarding_word: i64,
	record_size:     i64,
}

#assert(size_of(Space_Terms) == 32)

// The head of one kept record, as records_read gives it beside its bytes.
Kept_Record_Head :: struct {
	serial:     i64,
	time_ms:    i64,
	size:       i64,
	chain_hash: value_kinds.Hash_Field,
}

#assert(size_of(Kept_Record_Head) == 56)

// The state of one space, as spaces gives it.
Space_Row :: struct {
	space:           i64,
	kind_word:       i64,
	forwarding_word: i64,
	bound_records:   i64,
	record_size:     i64,
	kept:            i64,
	removed:         i64,
	refused_full:    i64,
	forwarded:       i64,
	next_serial:     i64,
	source:          [32]u8,
	output:          [32]u8,
	last_hash:       value_kinds.Hash_Field,
}

#assert(size_of(Space_Row) == 176)

// Who asks for the records of a space. The service fills it from the grant
// that the root service wrote for the connection: a caller cannot choose it.
Space_Reader :: struct {
	principal:          u64,
	acts_for_principal: bool,
	name:               [SPACE_NAME_BYTES]u8,
}

// One space.
Collector_Space :: struct {
	active:       bool,
	kind:         Collector_Space_Kind,
	forwarding:   Space_Forwarding,
	bound:        u32,
	record_size:  u32,
	source:       [SPACE_NAME_BYTES]u8,
	output:       [SPACE_NAME_BYTES]u8,
	first:        u32, // The place of the oldest record in the ring of the space.
	count:        u32,
	next_serial:  u64,
	removed:      u64,
	refused_full: u64,
	forwarded:    u64,
	last_hash:    blake3.Hash,
	serials:      [SPACE_RECORDS_MOST]u64,
	times:        [SPACE_RECORDS_MOST]u64,
	hashes:       [SPACE_RECORDS_MOST]blake3.Hash,
	bytes:        [SPACE_RECORDS_MOST * SPACE_RECORD_BYTES_MOST]u8,
}

// One record that waits to be forwarded: a copy, so a space Keep that
// removes its oldest record never removes a record before it is forwarded.
Forward_Item :: struct {
	space:  u32,
	serial: u64,
	size:   u32,
	bytes:  [SPACE_RECORD_BYTES_MOST]u8,
}

// The spaces of one collector, for its principal.
Space_Store :: struct {
	principal:     u64,
	spaces:        [SPACE_CAPACITY]Collector_Space,
	forward_first: u32,
	forward_count: u32,
	forward:       [FORWARD_QUEUE_CAPACITY]Forward_Item,
}

// space_forwarding_of_word is the border of the forwarding word of terms.
space_forwarding_of_word :: proc "contextless" (word: u64) -> (forwarding: Space_Forwarding, ok: bool) {
	member := enum_word.member_of_word(Space_Forwarding, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// space_store_init empties store for principal.
space_store_init :: proc "contextless" (store: ^Space_Store, principal: u64) {
	store^ = {}
	store.principal = principal
}

@(private = "file")
name_valid :: proc "contextless" (name: []u8) -> bool {
	if len(name) == 0 || len(name) >= SPACE_NAME_BYTES {
		return false
	}
	for value in name {
		if value < 0x21 || value > 0x7E {
			return false
		}
	}
	return true
}

@(private = "file")
name_field_equal :: proc "contextless" (field: ^[SPACE_NAME_BYTES]u8, name: []u8) -> bool {
	if len(name) >= SPACE_NAME_BYTES {
		return false
	}
	for index in 0 ..< SPACE_NAME_BYTES {
		expected := index < len(name) ? name[index] : 0
		if field[index] != expected {
			return false
		}
	}
	return true
}

// space_room_left gives the records that a new space can still bound.
space_room_left :: proc "contextless" (store: ^Space_Store) -> u32 {
	used: u32 = 0
	for &space in store.spaces {
		if space.active {
			used += space.bound
		}
	}
	return used >= SPACE_ROOM_RECORDS ? 0 : SPACE_ROOM_RECORDS - used
}

// space_open gives the number (from 1) of the space of the source and the
// record output, with terms. A pair that already has an active space with
// the same record size and the same terms gives that space; a pair whose
// record size changed gets a new space, and the old one stays.
space_open :: proc "contextless" (store: ^Space_Store, source, output: []u8, terms: Space_Terms) -> (space_number: u32, refusal: Space_Refusal) {
	if !name_valid(source) || !name_valid(output) {
		return 0, .Bad_Name
	}
	if terms.kind_word < 0 {
		return 0, .Bad_Kind
	}
	kind, kind_ok := collector_space_kind_from_word(u64(terms.kind_word))
	if !kind_ok {
		return 0, .Bad_Kind
	}
	if terms.forwarding_word < 0 {
		return 0, .Bad_Forwarding
	}
	forwarding, forwarding_ok := space_forwarding_of_word(u64(terms.forwarding_word))
	if !forwarding_ok {
		return 0, .Bad_Forwarding
	}
	if terms.bound_records < 1 || terms.bound_records > SPACE_RECORDS_MOST {
		return 0, .Bad_Bound
	}
	if terms.record_size < 1 || terms.record_size > SPACE_RECORD_BYTES_MOST {
		return 0, .Bad_Record_Size
	}
	bound := u32(terms.bound_records)
	record_size := u32(terms.record_size)
	free := -1
	for &space, index in store.spaces {
		if space.active && name_field_equal(&space.source, source) && name_field_equal(&space.output, output) && space.record_size == record_size {
			if space.kind != kind || space.forwarding != forwarding || space.bound != bound {
				// One pair and one record keep one space: terms that change
				// it would turn an audit into a space that removes records.
				return 0, .Bad_Kind
			}
			return u32(index + 1), .None
		}
		if !space.active && free < 0 {
			free = index
		}
	}
	if free < 0 {
		return 0, .Space_Limit_Reached
	}
	if bound > space_room_left(store) {
		return 0, .Bound_Past_Room
	}
	space := &store.spaces[free]
	space^ = {}
	space.active = true
	space.kind = kind
	space.forwarding = forwarding
	space.bound = bound
	space.record_size = record_size
	copy(space.source[:], source)
	copy(space.output[:], output)
	return u32(free + 1), .None
}

// space_of gives the active space of space_number, or nil.
space_of :: proc "contextless" (store: ^Space_Store, space_number: u32) -> ^Collector_Space {
	if space_number == 0 || space_number > SPACE_CAPACITY {
		return nil
	}
	space := &store.spaces[space_number - 1]
	if !space.active {
		return nil
	}
	return space
}

// space_record_hash gives the link of a record in the chain of its space:
// the hash of the link before it, its serial, its time and its bytes.
space_record_hash :: proc "contextless" (previous: blake3.Hash, serial, time_ms: u64, record: []u8) -> blake3.Hash {
	material: [blake3.HASH_SIZE + 8 + 8 + SPACE_RECORD_BYTES_MOST]u8
	previous_link := previous
	copy(material[:blake3.HASH_SIZE], previous_link[:])
	byte_order.write_u64_little_endian(material[:], blake3.HASH_SIZE, serial)
	byte_order.write_u64_little_endian(material[:], blake3.HASH_SIZE + 8, time_ms)
	length := min(len(record), SPACE_RECORD_BYTES_MOST)
	copy(material[blake3.HASH_SIZE + 16:][:length], record[:length])
	return blake3.derive_key(SPACE_RECORD_HASH_DOMAIN, material[:blake3.HASH_SIZE + 16 + length])
}

// record_append keeps record in its space at time_ms, then queues it for the
// forward when the space forwards. It gives the serial of the record. Each
// check comes before the first change: a refused record leaves the space and
// the queue as they were, and its writer sends it again.
record_append :: proc "contextless" (store: ^Space_Store, space_number: u32, record: []u8, time_ms: u64) -> (serial: u64, refusal: Space_Refusal) {
	space := space_of(store, space_number)
	if space == nil {
		return 0, .Unknown_Space
	}
	if u32(len(record)) != space.record_size || len(record) > SPACE_RECORD_BYTES_MOST {
		return 0, .Wrong_Size
	}
	if space.count >= space.bound {
		switch space.kind {
		case .Audit:
			space.refused_full += 1
			return 0, .Space_Full
		case .Keep:
		case .None:
			return 0, .Bad_Kind
		}
	}
	forwards := space.forwarding == .Forward
	if forwards && store.forward_count >= FORWARD_QUEUE_CAPACITY {
		space.refused_full += 1
		return 0, .Forward_Full
	}
	if space.count >= space.bound {
		// A space Keep thins its oldest record, and counts it.
		space.first = (space.first + 1) % space.bound
		space.count -= 1
		space.removed += 1
	}
	serial = space.next_serial
	place := (space.first + space.count) % space.bound
	space.serials[place] = serial
	space.times[place] = time_ms
	offset := int(place) * SPACE_RECORD_BYTES_MOST
	copy(space.bytes[offset:][:len(record)], record)
	if space.kind == .Audit {
		space.last_hash = space_record_hash(space.last_hash, serial, time_ms, record)
		space.hashes[place] = space.last_hash
	}
	space.count += 1
	space.next_serial += 1
	if forwards {
		item := &store.forward[(store.forward_first + store.forward_count) % FORWARD_QUEUE_CAPACITY]
		item^ = {space = space_number, serial = serial, size = u32(len(record))}
		copy(item.bytes[:len(record)], record)
		store.forward_count += 1
	}
	return serial, .None
}

// forward_peek gives the oldest record that waits to be forwarded, and
// leaves it in the queue: the caller takes it with forward_done only once
// its record output took it, so a full output never loses it.
forward_peek :: proc "contextless" (store: ^Space_Store) -> (item: ^Forward_Item, refusal: Space_Refusal) {
	if store.forward_count == 0 {
		return nil, .Forward_Empty
	}
	return &store.forward[store.forward_first], .None
}

// forward_done removes the oldest record of the queue, which its record
// output took, and counts it as forwarded in its space.
forward_done :: proc "contextless" (store: ^Space_Store) -> Space_Refusal {
	if store.forward_count == 0 {
		return .Forward_Empty
	}
	item := &store.forward[store.forward_first]
	if space := space_of(store, item.space); space != nil {
		space.forwarded += 1
	}
	item^ = {}
	store.forward_first = (store.forward_first + 1) % FORWARD_QUEUE_CAPACITY
	store.forward_count -= 1
	return .None
}

// space_read_allowed decides whether reader reads the records of space: a
// reader that acts for the principal of the collector, and that is not the
// source of the space, since a server never reads its own audit.
space_read_allowed :: proc "contextless" (store: ^Space_Store, space: ^Collector_Space, reader: ^Space_Reader) -> Space_Refusal {
	if reader == nil || !reader.acts_for_principal || reader.principal != store.principal {
		return .Not_Principal
	}
	if reader.name == space.source {
		return .Own_Space
	}
	return .None
}

// records_read writes the heads and the bytes of the kept records of a space
// whose serial is after after (from -1 for all), oldest first, at most limit
// of them, into heads and bytes, and gives the count of such records, which
// can pass what the two places hold. A record goes in only when its head and
// its bytes both fit. A reader that wants more asks again, after the serial
// of the last record that it received.
records_read :: proc "contextless" (
	store: ^Space_Store,
	space_number: u32,
	after: i64,
	limit: int,
	reader: ^Space_Reader,
	heads: []Kept_Record_Head,
	bytes: []u8,
) -> (count: int, refusal: Space_Refusal) {
	space := space_of(store, space_number)
	if space == nil {
		return 0, .Unknown_Space
	}
	if allowed := space_read_allowed(store, space, reader); allowed != .None {
		return 0, allowed
	}
	if limit < 1 || limit > SPACE_RECORDS_MOST {
		return 0, .Bad_Limit
	}
	written_bytes := 0
	for index in 0 ..< space.count {
		if count >= limit {
			break
		}
		place := (space.first + index) % space.bound
		serial := space.serials[place]
		if after >= 0 && serial <= u64(after) {
			continue
		}
		size := int(space.record_size)
		if count < len(heads) && written_bytes + size <= len(bytes) {
			heads[count] = {
				serial     = i64(min(serial, u64(max(i64)))),
				time_ms    = i64(min(space.times[place], u64(max(i64)))),
				size       = i64(size),
				chain_hash = value_kinds.Hash_Field(space.hashes[place]),
			}
			offset := int(place) * SPACE_RECORD_BYTES_MOST
			copy(bytes[written_bytes:][:size], space.bytes[offset:][:size])
			written_bytes += size
		}
		count += 1
	}
	return count, .None
}

// space_verify walks the chain of an audit space from its first record and
// compares each link and the last hash. It gives the serial of the first
// record whose link breaks.
space_verify :: proc "contextless" (store: ^Space_Store, space_number: u32) -> (refusal: Space_Refusal, failing_serial: u64) {
	space := space_of(store, space_number)
	if space == nil {
		return .Unknown_Space, 0
	}
	if space.kind != .Audit {
		return .Bad_Kind, 0
	}
	link: blake3.Hash
	for index in 0 ..< space.count {
		place := (space.first + index) % space.bound
		offset := int(place) * SPACE_RECORD_BYTES_MOST
		link = space_record_hash(link, space.serials[place], space.times[place], space.bytes[offset:][:space.record_size])
		if link != space.hashes[place] {
			return .Chain_Broken, space.serials[place]
		}
	}
	if link != space.last_hash {
		return .Chain_Broken, space.next_serial
	}
	return .None, 0
}

// space_rows writes the row of each space that reader may read into rows,
// and gives the count of such spaces, which can pass what rows holds. The
// space of a source is not in the rows of that source: a source does not
// learn the counts or the last link of its own audit.
space_rows :: proc "contextless" (store: ^Space_Store, reader: ^Space_Reader, rows: []Space_Row) -> (count: int, refusal: Space_Refusal) {
	if reader == nil || !reader.acts_for_principal || reader.principal != store.principal {
		return 0, .Not_Principal
	}
	for &space, index in store.spaces {
		if !space.active || space_read_allowed(store, &space, reader) != .None {
			continue
		}
		if count < len(rows) {
			rows[count] = space_row_of(&space, u32(index + 1))
		}
		count += 1
	}
	return count, .None
}

// space_stats gives the row of one space, under the rule of records_read.
space_stats :: proc "contextless" (store: ^Space_Store, space_number: u32, reader: ^Space_Reader) -> (row: Space_Row, refusal: Space_Refusal) {
	space := space_of(store, space_number)
	if space == nil {
		return {}, .Unknown_Space
	}
	if allowed := space_read_allowed(store, space, reader); allowed != .None {
		return {}, allowed
	}
	return space_row_of(space, space_number), .None
}

// space_open_allowed decides whether reader sets the terms of a space of
// source: a reader that acts for the principal and is not that source, since
// the terms of an audit are the choice of the starter, not of its subject.
space_open_allowed :: proc "contextless" (store: ^Space_Store, source: []u8, reader: ^Space_Reader) -> Space_Refusal {
	if reader == nil || !reader.acts_for_principal || reader.principal != store.principal {
		return .Not_Principal
	}
	if name_field_equal(&reader.name, source) {
		return .Own_Space
	}
	return .None
}

// space_row_of gives the row of one space.
space_row_of :: proc "contextless" (space: ^Collector_Space, space_number: u32) -> Space_Row {
	return {
		space           = i64(space_number),
		kind_word       = i64(space.kind),
		forwarding_word = i64(space.forwarding),
		bound_records   = i64(space.bound),
		record_size     = i64(space.record_size),
		kept            = i64(space.count),
		removed         = i64(min(space.removed, u64(max(i64)))),
		refused_full    = i64(min(space.refused_full, u64(max(i64)))),
		forwarded       = i64(min(space.forwarded, u64(max(i64)))),
		next_serial     = i64(min(space.next_serial, u64(max(i64)))),
		source          = space.source,
		output          = space.output,
		last_hash       = value_kinds.Hash_Field(space.last_hash),
	}
}

// space_count gives the active spaces.
space_count :: proc "contextless" (store: ^Space_Store) -> int {
	count := 0
	for &space in store.spaces {
		if space.active {
			count += 1
		}
	}
	return count
}

// source_count gives the sources that have an active space, each once.
source_count :: proc "contextless" (store: ^Space_Store) -> int {
	count := 0
	for &space, index in store.spaces {
		if !space.active {
			continue
		}
		seen := false
		for &earlier in store.spaces[:index] {
			if earlier.active && earlier.source == space.source {
				seen = true
				break
			}
		}
		if !seen {
			count += 1
		}
	}
	return count
}

// kept_record_count gives the records that the active spaces keep now.
kept_record_count :: proc "contextless" (store: ^Space_Store) -> u64 {
	total: u64 = 0
	for &space in store.spaces {
		if space.active {
			total += u64(space.count)
		}
	}
	return total
}
