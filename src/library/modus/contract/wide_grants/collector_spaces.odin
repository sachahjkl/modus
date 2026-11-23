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
// The store calls no kernel operation and allocates no memory: its caller
// gives each time and each identity, and the port of its private store, the
// one way to the store of the collector (collector_segments.odin).
package wide_grants

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import pr "modus:contract/plans_recipes"
import "modus:contract/value_kinds"

// The name of the module of the collector, as a start list and the root
// service name it.
COLLECTOR_MODULE_NAME :: "collector"

// The pages that one audit of a start list adds to the budget of the
// collector: its window, and its place and its row of the index, which a
// page holds with room (src/md/features/wide_grants.md, "The starter pays
// for the audits"). The root service widens the budget by it.
SPACE_AUDIT_PAGES :: SPACE_WINDOW_PAGES + 1

// How long a closed audit space is kept before its removal, until a plan
// states it: a principal reads or copies the audit of a module in the
// quarter after its update, and the storage service keeps the versions of
// the removed objects by its own retention after that.
CLOSED_AUDIT_RETENTION_DEFAULT_MILLISECONDS :: i64(90 * 24 * 3600 * 1000)

// How often the collector tries again to date a closed space while no date
// is known.
CLOSED_AUDIT_DATE_RETRY_MILLISECONDS :: u64(60_000)

// The records that one space holds in memory at most: the largest bound of
// a space Keep, and the window of the newest records of a space Audit,
// whose records stay in the private store up to its bound.
SPACE_RECORDS_MOST :: 64

// The bytes of a record of a space at most: the largest record that a record
// description allows.
SPACE_RECORD_BYTES_MOST :: 256

// The records of one space that wait to be forwarded at most. A space
// whose pair does not take its records fills its own part of the queue
// only, so it never holds the forward of another space.
FORWARD_QUEUE_PER_SPACE_LIMIT :: 4

// The records that wait to be forwarded at most, across the spaces: the
// part of each source that the collector reads at once.
FORWARD_QUEUE_CAPACITY :: 64
// Only a space that a source feeds forwards: the part of each fits for the
// sources that forward at once; past them the queue holds a record, which
// waits and is not lost.
#assert(FORWARD_QUEUE_PER_SPACE_LIMIT * FORWARD_SOURCES_SHARED <= FORWARD_QUEUE_CAPACITY)

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
	Store_Failed        = 17, // The private store refused a read or a write: nothing changed.
	Store_Damaged       = 18, // An object of the private store does not decode, or breaks its chain.
	Space_Held          = 19, // Another wiring of the same source feeds the space now.
	Memory_Refused      = 20, // The budget of the collector did not pay the window of the space: nothing changed.
	Space_Closed        = 21, // The space closed when its record size changed: it keeps its records and takes no more.
	Space_Removed       = 22, // The space closed, and its retention ended: its records are removed, or being removed.
	Act_Space           = 23, // The pair names an act space of a wide grant, which only the grant opens (act_wiring_attach).
	Older_Format        = 24, // The private store holds the spaces of an older release, which names its principal by its slot: none is read.
}

// The window of an open space: the ring of its newest records in memory,
// and the slot map of a space Audit. The collector commits it from its
// budget when the space opens and decommits it when the space closes.
Space_Window :: struct {
	serials:  [SPACE_RECORDS_MOST]u64,
	times:    [SPACE_RECORDS_MOST]u64,
	hashes:   [SPACE_RECORDS_MOST]blake3.Hash,
	bytes:    [SPACE_RECORDS_MOST * SPACE_RECORD_BYTES_MOST]u8,
	// For each slot, the number of the segment that it holds, plus 1; 0:
	// none, as the slot map object holds it.
	slot_map: [SPACE_SEGMENT_SLOTS]u64,
}

// The pages of the window of one space.
SPACE_WINDOW_PAGES :: (size_of(Space_Window) + 4095) / 4096

// Where the memory of the spaces comes from: the budget of the collector on
// a machine, the heap in a host test. No count of the store is fixed.
//
// - window_take gives a zeroed window, or nil when it is not paid;
//   window_give returns it; windows_left says how many windows the budget
//   still pays.
// - places_grow gives the table of the places with count places at least,
//   at the same address, the places before kept; nil when it is not paid.
// - index_grow gives a buffer of bytes for the index, or nil; the bytes
//   of the buffer before are not kept, as a write or a read of the index
//   fills it whole.
Space_Memory_Port :: struct {
	user:         rawptr,
	window_take:  proc "contextless" (user: rawptr) -> ^Space_Window,
	window_give:  proc "contextless" (user: rawptr, window: ^Space_Window),
	windows_left: proc "contextless" (user: rawptr) -> u32,
	places_grow:  proc "contextless" (user: rawptr, count: u32) -> []Collector_Space,
	index_grow:   proc "contextless" (user: rawptr, bytes: int) -> []u8,
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

// One space. The ring in memory holds the newest records, window of them
// at most; a space Audit keeps each record in the private store too, from
// kept_first_serial, and refuses a record past its bound.
Collector_Space :: struct {
	active:         bool,
	kind:           Collector_Space_Kind,
	forwarding:     Space_Forwarding,
	bound:          u32,
	window:         u32, // The places of the ring in memory: min(bound, SPACE_RECORDS_MOST).
	record_size:    u32,
	source:         [SPACE_NAME_BYTES]u8,
	output:         [SPACE_NAME_BYTES]u8,
	first:          u32, // The place of the oldest record in the ring of the space.
	count:          u32, // The records in the ring.
	first_serial:   u64, // The serial of the record at first.
	next_serial:    u64,
	removed:        u64,
	refused_full:   u64,
	forwarded:      u64,
	unforwarded:    u64, // The kept records whose pair ended before they left: the space keeps them, and no reader got them.
	last_hash:      blake3.Hash,
	window_link:    blake3.Hash, // The link of the record before first_serial: where the chain of the ring starts.
	// A space Audit: the first record that the private store keeps. The
	// records before it rotated out (space_rotate_before), whole segments
	// at a time; the anchors close the chain at that place.
	kept_first_serial:   u64,
	anchor_segment_hash: blake3.Hash, // The hash of the segment before the first kept one.
	anchor_link:         blake3.Hash, // The link of the record before kept_first_serial.
	closed_segment_hash: blake3.Hash, // The hash of the last full segment: the previous one of the open segment.
	// A space Audit whose record size changed: no window, no new record; its
	// records stay in the store, after window_link, which is its last link.
	closed:         bool,
	closed_at_ms:   i64, // The date of the close, in milliseconds since 1970; 0 until a pass of the collector knows a date.
	// The retention of a closed space ended: its objects are being removed
	// (active), or are removed and its place is free (not active).
	removing:       bool,
	place_removed:  bool,
	ring:           ^Space_Window, // nil for a closed space.
}

// One record that waits to be forwarded: a copy, so a space Keep that
// removes its oldest record never removes a record before it is forwarded.
Forward_Item :: struct {
	space:  u32,
	serial: u64,
	size:   u32,
	bytes:  [SPACE_RECORD_BYTES_MOST]u8,
}

// The spaces of one collector, for its principal, and the port of the
// private store that keeps its audit spaces.
Space_Store :: struct {
	principal:     u64, // The slot of the principal in this run: the checks of the callers.
	identifier:    [COLLECTOR_IDENTIFIER_SIZE]u8, // The principal identifier: the name of the principal in each object of the store.
	store_port:    pr.Private_Store_Port,
	load_state:    Space_Load_State,
	damaged_space: u32, // The space whose objects were damaged at the read, from 1; 0 for the index.
	spaces:        []Collector_Space, // The places, in the memory of the port: they grow and never move.
	forward_first: u32,
	forward_count: u32,
	forward:       [FORWARD_QUEUE_CAPACITY]Forward_Item,
	memory:        Space_Memory_Port,
	index_dirty:   bool, // The memory holds a change that no write of the index took yet: the next pass writes it.
	load_reads:    int, // The objects that the last load of the spaces read: a measure.
	segment_bytes: [SEGMENT_BYTES_MOST]u8,
	index_bytes:   []u8, // The buffer of the index, in the memory of the port.
}

// space_forwarding_of_word is the border of the forwarding word of terms.
space_forwarding_of_word :: proc "contextless" (word: u64) -> (forwarding: Space_Forwarding, ok: bool) {
	member := enum_word.member_of_word(Space_Forwarding, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// space_store_init empties store for principal, over the private store of
// store_port and the memory of memory. The audit spaces come back from that
// store at the first step.
//
// A named principal with an identifier of zero bytes, the name of principal
// 0, gets no store: its port keeps no procedure, so each step is refused
// and no object names it as principal 0. identified is then false.
space_store_init :: proc "contextless" (store: ^Space_Store, principal: u64, identifier: [COLLECTOR_IDENTIFIER_SIZE]u8, store_port: pr.Private_Store_Port, memory: Space_Memory_Port) -> (identified: bool) {
	store^ = {}
	store.principal = principal
	store.identifier = identifier
	store.memory = memory
	if principal != 0 && identifier == {} {
		return false
	}
	store.store_port = store_port
	return true
}

// space_index_bytes_of gives the bytes of an index of count places.
space_index_bytes_of :: proc "contextless" (count: int) -> int {
	return SPACE_INDEX_HEAD_BYTES + count * SPACE_INDEX_ROW_BYTES + blake3.HASH_SIZE
}

// space_places_ensure makes the table hold count places at least. false:
// the budget does not pay them, and nothing changed. The buffer of the index
// grows only at a write of the index (space_index_persist), so a load that
// grows the table keeps the bytes that it read.
space_places_ensure :: proc "contextless" (store: ^Space_Store, count: int) -> bool {
	if len(store.spaces) < count {
		if store.memory.places_grow == nil {
			return false
		}
		grown := store.memory.places_grow(store.memory.user, u32(count))
		if len(grown) < count || (len(store.spaces) > 0 && raw_data(grown) != raw_data(store.spaces)) {
			return false
		}
		store.spaces = grown
	}
	return true
}

// space_index_buffer_ensure makes the buffer of the index hold bytes.
space_index_buffer_ensure :: proc "contextless" (store: ^Space_Store, bytes: int) -> bool {
	if len(store.index_bytes) >= bytes {
		return true
	}
	if store.memory.index_grow == nil {
		return false
	}
	grown := store.memory.index_grow(store.memory.user, bytes)
	if len(grown) < bytes {
		return false
	}
	store.index_bytes = grown
	return true
}

// space_windows_left gives the windows that the budget still pays.
space_windows_left :: proc "contextless" (store: ^Space_Store) -> u32 {
	if store.memory.windows_left == nil {
		return 0
	}
	return store.memory.windows_left(store.memory.user)
}

// space_window_take gives a window to the space of space_number, or false
// when the budget does not pay it.
space_window_take :: proc "contextless" (store: ^Space_Store, space_number: u32) -> bool {
	if store.memory.window_take == nil {
		return false
	}
	window := store.memory.window_take(store.memory.user)
	if window == nil {
		return false
	}
	store.spaces[space_number - 1].ring = window
	return true
}

// space_window_give returns the window of a space, if it holds one.
space_window_give :: proc "contextless" (store: ^Space_Store, space_number: u32) {
	space := &store.spaces[space_number - 1]
	if space.ring != nil && store.memory.window_give != nil {
		store.memory.window_give(store.memory.user, space.ring)
	}
	space.ring = nil
}

// space_windows_open gives the spaces that hold a window, and the act
// spaces among them.
space_windows_open :: proc "contextless" (store: ^Space_Store) -> (open: u32, acts: u32) {
	for &space in store.spaces {
		if space.ring != nil {
			open += 1
			if space_is_act(&space) {
				acts += 1
			}
		}
	}
	return open, acts
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

// server_audit_terms_valid says if the terms of a row of a start list name
// what such a row may ask: a space Audit that keeps the records that leave
// a server, never one that forwards them (a pair needs a writer that the
// start list does not hold), with a bound and a record size in range. The
// record size is checked against the record of the writer when the
// collector opens the link.
server_audit_terms_valid :: proc "contextless" (terms: Space_Terms) -> bool {
	kind_ok := terms.kind_word == i64(Collector_Space_Kind.Audit) && terms.forwarding_word == i64(Space_Forwarding.Keeps)
	bound_ok := terms.bound_records >= 1 && terms.bound_records <= SPACE_AUDIT_BOUND_MOST
	size_ok := terms.record_size >= 1 && terms.record_size <= SPACE_RECORD_BYTES_MOST
	return kind_ok && bound_ok && size_ok
}

// space_open gives the number (from 1) of the space of the source and the
// record output, with terms. A pair that already has an open space with
// the same record size and the same terms gives that space. A pair whose
// record size changed gets a new space, and the old one closes in memory:
// a space Audit keeps its place and its records in the store, a space Keep
// frees its place (src/md/features/wide_grants.md, "The memory of the
// spaces"). A new space takes a window from the budget, and leaves the
// windows of the act spaces that are not open.
space_open :: proc "contextless" (store: ^Space_Store, source, output: []u8, terms: Space_Terms) -> (space_number: u32, refusal: Space_Refusal) {
	if ready := space_store_ready(store); ready != .None {
		return 0, ready
	}
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
	if terms.bound_records < 1 || terms.bound_records > i64(space_bound_most(kind)) {
		return 0, .Bad_Bound
	}
	if terms.record_size < 1 || terms.record_size > SPACE_RECORD_BYTES_MOST {
		return 0, .Bad_Record_Size
	}
	bound := u32(terms.bound_records)
	window := min(bound, SPACE_RECORDS_MOST)
	record_size := u32(terms.record_size)
	free := -1
	changed := -1 // The open space of the pair with another record size.
	for &space, index in store.spaces {
		if space.active && !space.closed && name_field_equal(&space.source, source) && name_field_equal(&space.output, output) {
			if space.record_size != record_size {
				changed = index
				continue
			}
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
		// No free place: the table grows, as the budget pays.
		free = len(store.spaces)
		if !space_places_ensure(store, free + 1) {
			return 0, .Memory_Refused
		}
	}
	// The room of the window. A space that is not an act space leaves the
	// windows of the act spaces that are not open. A change of size holds
	// the old window and the new one for a moment, then gives the old one
	// back: it needs one window, and leaves the room of the act spaces as
	// it was.
	act := space_names_act(source, output)
	_, acts := space_windows_open(store)
	kept := act ? 0 : ACT_SPACES_RESERVED - min(acts, ACT_SPACES_RESERVED)
	needed := changed >= 0 ? 1 : 1 + kept
	if space_windows_left(store) < needed {
		return 0, .Memory_Refused
	}
	space := &store.spaces[free]
	space^ = {}
	if !space_window_take(store, u32(free + 1)) {
		return 0, .Memory_Refused
	}
	space.active = true
	space.kind = kind
	space.forwarding = forwarding
	space.bound = bound
	space.window = window
	space.record_size = record_size
	copy(space.source[:], source)
	copy(space.output[:], output)
	// The old space is closed in the index first, with its ring still in
	// memory: a refused write leaves it as it was.
	old: ^Collector_Space
	old_before: Collector_Space
	if changed >= 0 {
		old = &store.spaces[changed]
		old_before = old^
		if old.kind == .Audit {
			old.closed = true
		}
	}
	if kind == .Audit || (old != nil && old.kind == .Audit) {
		// The index names the space before its first record, so a stop after
		// a record never leaves a segment that no index names; it names the
		// closed space with its last link.
		if persisted := space_index_persist(store); persisted != .None {
			if old != nil {
				old^ = old_before
			}
			space_window_give(store, u32(free + 1))
			space^ = {}
			return 0, persisted
		}
	}
	if old != nil {
		space_close(store, u32(changed + 1))
	}
	return u32(free + 1), .None
}

// The act spaces of a wide grant, one for each wired writer: their windows
// stay free for them.
ACT_SPACES_RESERVED :: u32(3)

// space_names_act says if a source and an output name an act space: the
// output acts of a wired writer.
space_names_act :: proc "contextless" (source, output: []u8) -> bool {
	if string(output) != ACT_OUTPUT_NAME {
		return false
	}
	for producer in ACT_PRODUCERS_WIRED {
		if string(source) == ACT_PRODUCER_NAMES[producer] {
			return true
		}
	}
	return false
}

// space_is_act says if a space is an act space of a wide grant.
space_is_act :: proc "contextless" (space: ^Collector_Space) -> bool {
	return space_names_act(name_field_text(&space.source), name_field_text(&space.output))
}

// name_field_text gives the bytes of a name field before its first zero.
@(private = "file")
name_field_text :: proc "contextless" (field: ^[SPACE_NAME_BYTES]u8) -> []u8 {
	length := 0
	for length < SPACE_NAME_BYTES && field[length] != 0 {
		length += 1
	}
	return field[:length]
}

// space_ring_empty empties the ring of a space whose records stay in the
// store: the ring starts after its last record.
@(private = "file")
space_ring_empty :: proc "contextless" (space: ^Collector_Space) {
	space.first = 0
	space.count = 0
	space.first_serial = space.next_serial
	space.window_link = space.last_hash
}

// space_close closes the space of space_number in memory: a space Audit
// gives back its window and keeps its place, its records in the store and
// its last link; a space Keep, whose records are in memory only, frees its
// place.
space_close :: proc "contextless" (store: ^Space_Store, space_number: u32) {
	space := &store.spaces[space_number - 1]
	space_window_give(store, space_number)
	switch space.kind {
	case .Audit:
		space.closed = true
		space.closed_at_ms = 0
		space_ring_empty(space)
	case .Keep, .None:
		space^ = {}
	}
}

// space_bound_most gives the largest bound of a space of kind: a space Keep
// holds its records in memory only, a space Audit in the private store.
space_bound_most :: proc "contextless" (kind: Collector_Space_Kind) -> u32 {
	switch kind {
	case .Audit:
		return SPACE_AUDIT_BOUND_MOST
	case .Keep:
		return SPACE_RECORDS_MOST
	case .None:
		return 0
	}
	return 0
}

// space_place_of gives the place in the ring of a record whose serial the
// ring holds.
space_place_of :: proc "contextless" (space: ^Collector_Space, serial: u64) -> u32 {
	return u32((u64(space.first) + (serial - space.first_serial)) % u64(space.window))
}

// space_window_drop_oldest takes the oldest record out of the ring: a
// space Keep thins it; a space Audit keeps it in the private store.
space_window_drop_oldest :: proc "contextless" (space: ^Collector_Space) {
	if space.count == 0 {
		return
	}
	space.window_link = space.ring.hashes[space.first]
	space.first = (space.first + 1) % space.window
	space.count -= 1
	space.first_serial += 1
}

// space_kept_count gives the records that a space keeps: in the private
// store for a space Audit, in memory for a space Keep.
space_kept_count :: proc "contextless" (space: ^Collector_Space) -> u64 {
	if space.kind == .Audit {
		return space.next_serial - space.kept_first_serial
	}
	return u64(space.count)
}

// space_of gives the active space of space_number, or nil.
space_of :: proc "contextless" (store: ^Space_Store, space_number: u32) -> ^Collector_Space {
	if space_number == 0 || int(space_number) > len(store.spaces) {
		return nil
	}
	space := &store.spaces[space_number - 1]
	if !space.active || space.removing {
		return nil
	}
	return space
}

// space_missing gives why space_of gave no space: Space_Removed for a space
// whose retention ended, Unknown_Space for a number that names none.
space_missing :: proc "contextless" (store: ^Space_Store, space_number: u32) -> Space_Refusal {
	if space_number == 0 || int(space_number) > len(store.spaces) {
		return .Unknown_Space
	}
	space := &store.spaces[space_number - 1]
	if space.removing || space.place_removed {
		return .Space_Removed
	}
	return .Unknown_Space
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
// the queue as they were, and its writer sends it again. An audit space
// writes the record into its segment in the private store first: a refused
// write keeps nothing and forwards nothing.
record_append :: proc "contextless" (store: ^Space_Store, space_number: u32, record: []u8, time_ms: u64) -> (serial: u64, refusal: Space_Refusal) {
	if ready := space_store_ready(store); ready != .None {
		return 0, ready
	}
	space := space_of(store, space_number)
	if space == nil {
		return 0, space_missing(store, space_number)
	}
	if space.closed || space.ring == nil {
		return 0, .Space_Closed
	}
	if u32(len(record)) != space.record_size || len(record) > SPACE_RECORD_BYTES_MOST {
		return 0, .Wrong_Size
	}
	switch space.kind {
	case .Audit:
		if space.next_serial - space.kept_first_serial >= u64(space.bound) {
			space.refused_full += 1
			return 0, .Space_Full
		}
	case .Keep:
	case .None:
		return 0, .Bad_Kind
	}
	forwards := space.forwarding == .Forward
	if forwards && (store.forward_count >= FORWARD_QUEUE_CAPACITY || forward_count_of(store, space_number) >= FORWARD_QUEUE_PER_SPACE_LIMIT) {
		space.refused_full += 1
		return 0, .Forward_Full
	}
	segment_hash: blake3.Hash
	if space.kind == .Audit {
		link := space_record_hash(space.last_hash, space.next_serial, time_ms, record)
		persisted: Space_Refusal
		segment_hash, persisted = segment_persist(store, space_number, space, record, time_ms, link)
		if persisted != .None {
			return 0, persisted
		}
	}
	if space.count >= space.window {
		// A space Keep thins its oldest record, and counts it; a space Audit
		// keeps it in the private store, out of the ring.
		space_window_drop_oldest(space)
		if space.kind == .Keep {
			space.removed += 1
		}
	}
	serial = space.next_serial
	place := (space.first + space.count) % space.window
	space.ring.serials[place] = serial
	space.ring.times[place] = time_ms
	offset := int(place) * SPACE_RECORD_BYTES_MOST
	copy(space.ring.bytes[offset:][:len(record)], record)
	if space.count == 0 {
		space.first_serial = serial
	}
	if space.kind == .Audit {
		space.last_hash = space_record_hash(space.last_hash, serial, time_ms, record)
		space.ring.hashes[place] = space.last_hash
		if serial % SPACE_SEGMENT_RECORDS == SPACE_SEGMENT_RECORDS - 1 {
			space.closed_segment_hash = segment_hash
		}
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

// forward_drop removes the oldest record of the queue, whose pair has no
// ring any more, and counts it as unforwarded in its space: the space keeps
// it, and no later reader of a new pair takes a record of another wiring.
forward_drop :: proc "contextless" (store: ^Space_Store) -> Space_Refusal {
	return forward_remove_at(store, 0, .Dropped)
}

// How a record leaves the forward queue.
Forward_Removal :: enum u8 {
	Forwarded = 0, // The ring of its pair took it: its space counts it as forwarded.
	Dropped   = 1, // Its pair has no ring any more: its space keeps it, and counts it as unforwarded.
}

// forward_item_at gives the record at offset from the oldest one of the
// queue, or nil past the queue.
forward_item_at :: proc "contextless" (store: ^Space_Store, offset: u32) -> ^Forward_Item {
	if offset >= store.forward_count {
		return nil
	}
	return &store.forward[(store.forward_first + offset) % FORWARD_QUEUE_CAPACITY]
}

// forward_remove_at removes the record at offset from the oldest one, and
// counts it in its space. The records after it move one place toward the
// oldest one, so the order of the others stays: the forward keeps the
// order of each space, and a space whose pair waits does not hold another.
forward_remove_at :: proc "contextless" (store: ^Space_Store, offset: u32, removal: Forward_Removal) -> Space_Refusal {
	item := forward_item_at(store, offset)
	if item == nil {
		return .Forward_Empty
	}
	if space := space_of(store, item.space); space != nil {
		switch removal {
		case .Forwarded:
			space.forwarded += 1
		case .Dropped:
			space.unforwarded += 1
		}
	}
	for place in offset ..< store.forward_count - 1 {
		store.forward[(store.forward_first + place) % FORWARD_QUEUE_CAPACITY] = store.forward[(store.forward_first + place + 1) % FORWARD_QUEUE_CAPACITY]
	}
	store.forward[(store.forward_first + store.forward_count - 1) % FORWARD_QUEUE_CAPACITY] = {}
	store.forward_count -= 1
	return .None
}

// forward_count_of gives the records of a space that the forward queue
// holds.
forward_count_of :: proc "contextless" (store: ^Space_Store, space_number: u32) -> (count: u32) {
	for offset in 0 ..< store.forward_count {
		if store.forward[(store.forward_first + offset) % FORWARD_QUEUE_CAPACITY].space == space_number {
			count += 1
		}
	}
	return count
}

// forward_waits_for says if the forward queue holds a record of a space.
forward_waits_for :: proc "contextless" (store: ^Space_Store, space_number: u32) -> bool {
	for offset in 0 ..< store.forward_count {
		if store.forward[(store.forward_first + offset) % FORWARD_QUEUE_CAPACITY].space == space_number {
			return true
		}
	}
	return false
}

// forward_done removes the oldest record of the queue, which its record
// output took, and counts it as forwarded in its space.
forward_done :: proc "contextless" (store: ^Space_Store) -> Space_Refusal {
	return forward_remove_at(store, 0, .Forwarded)
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
	if ready := space_store_ready(store); ready != .None {
		return 0, ready
	}
	space := space_of(store, space_number)
	if space == nil {
		return 0, space_missing(store, space_number)
	}
	if allowed := space_read_allowed(store, space, reader); allowed != .None {
		return 0, allowed
	}
	if limit < 1 || limit > SPACE_RECORDS_MOST {
		return 0, .Bad_Limit
	}
	out := Records_Out{heads = heads, bytes = bytes, limit = limit}
	// A space Audit keeps its records in the private store: a reader that
	// starts before the ring reads them there, oldest first, then the ring.
	start := space.kind == .Audit ? space.kept_first_serial : 0
	if after >= 0 && u64(after) + 1 > start {
		start = u64(after) + 1
	}
	ring_first := space_ring_first(space)
	if space.kind == .Audit && start < ring_first {
		if refusal = space_segments_read(store, space_number, space, start, ring_first, &out); refusal != .None {
			return 0, refusal
		}
	}
	for index in 0 ..< space.count {
		if out.count >= limit {
			break
		}
		place := (space.first + index) % space.window
		serial := space.ring.serials[place]
		if serial < start {
			continue
		}
		offset := int(place) * SPACE_RECORD_BYTES_MOST
		records_out_put(&out, serial, space.ring.times[place], space.ring.hashes[place], space.ring.bytes[offset:][:space.record_size])
	}
	return out.count, .None
}

// space_verify walks the chain of an audit space from its first record and
// compares each link and the last hash, then reads each segment of the space
// back from the private store and compares it. It gives the serial of the
// first record whose link breaks, or the first serial of the first segment
// that does not match.
space_verify :: proc "contextless" (store: ^Space_Store, space_number: u32) -> (refusal: Space_Refusal, failing_serial: u64) {
	if ready := space_store_ready(store); ready != .None {
		return ready, 0
	}
	space := space_of(store, space_number)
	if space == nil {
		return space_missing(store, space_number), 0
	}
	if space.kind != .Audit {
		return .Bad_Kind, 0
	}
	// The ring starts at the link of the record before it: the records
	// before are in the private store, which space_segments_verify reads.
	link := space.window_link
	for index in 0 ..< space.count {
		place := (space.first + index) % space.window
		offset := int(place) * SPACE_RECORD_BYTES_MOST
		link = space_record_hash(link, space.ring.serials[place], space.ring.times[place], space.ring.bytes[offset:][:space.record_size])
		if link != space.ring.hashes[place] {
			return .Chain_Broken, space.ring.serials[place]
		}
	}
	if link != space.last_hash {
		return .Chain_Broken, space.next_serial
	}
	return space_segments_verify(store, space_number, space)
}

// space_rows writes the row of each space that reader may read into rows,
// and gives the count of such spaces, which can pass what rows holds. The
// space of a source is not in the rows of that source: a source does not
// learn the counts or the last link of its own audit.
space_rows :: proc "contextless" (store: ^Space_Store, reader: ^Space_Reader, rows: []Space_Row) -> (count: int, refusal: Space_Refusal) {
	if reader == nil || !reader.acts_for_principal || reader.principal != store.principal {
		return 0, .Not_Principal
	}
	if ready := space_store_ready(store); ready != .None {
		return 0, ready
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
	if ready := space_store_ready(store); ready != .None {
		return {}, ready
	}
	space := space_of(store, space_number)
	if space == nil {
		return {}, space_missing(store, space_number)
	}
	if allowed := space_read_allowed(store, space, reader); allowed != .None {
		return {}, allowed
	}
	return space_row_of(space, space_number), .None
}

// space_open_allowed decides whether reader sets the terms of a space of
// source and output: a reader that acts for the principal and is not that
// source, since the terms of an audit are the choice of the starter, not of
// its subject, and a pair that is no act space of a wide grant, which only
// act_wiring_attach opens.
space_open_allowed :: proc "contextless" (store: ^Space_Store, source: []u8, output: []u8, reader: ^Space_Reader) -> Space_Refusal {
	if reader == nil || !reader.acts_for_principal || reader.principal != store.principal {
		return .Not_Principal
	}
	if name_field_equal(&reader.name, source) {
		return .Own_Space
	}
	// The act spaces of a wide grant open only with the grant: a caller
	// that opened one with another record size would close the audit of
	// the grant.
	if space_names_act(source, output) {
		return .Act_Space
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
		kept            = i64(min(space_kept_count(space), u64(max(i64)))),
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
			total += space_kept_count(&space)
		}
	}
	return total
}
