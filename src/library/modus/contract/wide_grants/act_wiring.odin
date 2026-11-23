// Wide-grant act record output wiring and routing contract
// (src/md/features/wide_grants.md, "The record of each act";
// src/md/features/module_outputs.md, "The collector").
//
// Defines the closed set of the four act record producers (root, agent
// console, remote, trusted display), the fixed-layout Act_Stream_Record
// carried on each producer's `acts` record output, the builder of wiring rows
// into collector.sources, and the pure fail-closed Grant_Act_Router that
// attaches all four audit spaces at grant creation, gates every incoming act
// record, and writes the end record and closes all wirings on revocation or
// expiry.
//
// Contract package: imports base and contract packages only, calls no kernel
// operation, and allocates no memory.
package wide_grants

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/output"
import pr "modus:contract/plans_recipes"

// Name of the record output declared by each wide-grant act producer.
ACT_OUTPUT_NAME :: "acts"

// The bound of the audit space of each writer of act records: the largest
// space Audit. It holds the records of the grants that the collector keeps
// (Act_Space_Plan), in its private store; memory holds the newest
// SPACE_RECORDS_MOST of them.
ACT_SPACE_BOUND_RECORDS :: i64(SPACE_AUDIT_BOUND_MOST)

// The capacity of the ring of each wiring of act records. Each record in
// that ring is an act that ran: the space keeps room for a whole ring while
// a grant holds, and reads the ring to its end after the grant ends.
ACT_RING_CAPACITY :: u32(output.WIRING_CAPACITY_LEAST)

// The records of the root service in each grant: its start and its end.
ACT_ROOT_RECORDS_PER_GRANT :: 2

// The most grants whose act records a collector keeps.
ACT_RETAINED_GRANTS_MOST :: 16

// How the act spaces of a collector are sized
// (src/md/features/wide_grants.md, "The size of the act records"): each
// space holds bound_records; the collector keeps the records of
// retained_grants grants at most, the newest ones; a new grant needs room
// for records_per_minute records of each writer for each minute of its
// duration, at least grant_records_least, and at most the share of one
// grant of the space. The oldest closed grants rotate out to make that
// room, whole segments at a time; the grant that holds never does.
Act_Space_Plan :: struct {
	bound_records:       i64,
	retained_grants:     int,
	records_per_minute:  u64,
	grant_records_least: u64,
}

ACT_SPACE_PLAN :: Act_Space_Plan {
	bound_records       = ACT_SPACE_BOUND_RECORDS,
	retained_grants     = 8,
	records_per_minute  = 16,
	grant_records_least = 64,
}

// act_space_plan_valid says if a plan holds: a bound of an audit space, a
// count of grants in the ring, a rate, and a least share that fits the
// share of one grant.
act_space_plan_valid :: proc "contextless" (plan: Act_Space_Plan) -> bool {
	if plan.bound_records < i64(ACT_RING_CAPACITY) + 1 || plan.bound_records > SPACE_AUDIT_BOUND_MOST {
		return false
	}
	if plan.retained_grants < 1 || plan.retained_grants > ACT_RETAINED_GRANTS_MOST || plan.records_per_minute < 1 || plan.grant_records_least < 1 {
		return false
	}
	return plan.grant_records_least <= act_grant_records_most(plan)
}

// act_grant_records_most gives the share of one grant of the space of a
// writer: the bound less the ring of the reserve, between the grants of the
// ring.
act_grant_records_most :: proc "contextless" (plan: Act_Space_Plan) -> u64 {
	return (u64(plan.bound_records) - u64(ACT_RING_CAPACITY)) / u64(plan.retained_grants)
}

// act_grant_allowance gives the records of each writer that a grant of
// duration_ms needs room for when it starts.
act_grant_allowance :: proc "contextless" (plan: Act_Space_Plan, duration_ms: u64) -> u64 {
	minutes := (duration_ms + 59_999) / 60_000
	wanted := minutes * plan.records_per_minute
	if minutes != 0 && wanted / minutes != plan.records_per_minute {
		wanted = max(u64)
	}
	return clamp(wanted, plan.grant_records_least, act_grant_records_most(plan))
}

// Number of act producers wired for a wide grant.
ACT_PRODUCER_COUNT :: 4

// Closed set of the four act record producers of a wide grant.
// Zero means unset and is refused at the border.
Act_Producer :: enum u64 {
	None            = 0,
	Root_Service    = 1,
	Agent_Console   = 2,
	Remote_Service  = 3,
	Trusted_Display = 4,
}

// Bit set of wired act producers.
Act_Producers :: bit_set[Act_Producer;u64]

// Complete set of the four producers required for a wide grant audit.
ALL_ACT_PRODUCERS :: Act_Producers{.Root_Service, .Agent_Console, .Remote_Service, .Trusted_Display}

// The writers whose spaces a grant of this layer opens and wires: the
// agent console writes no act record until the layer of Console_Lines
// (src/md/features/wide_grants.md, "The order of the work"), and an empty
// space would take a window of memory from the audits of the servers.
ACT_PRODUCERS_WIRED :: Act_Producers{.Root_Service, .Remote_Service, .Trusted_Display}

// Canonical module/source name for each act producer, used as the source name
// of its audit space in the collector.
@(rodata)
ACT_PRODUCER_NAMES := [Act_Producer]string {
	.None            = "",
	.Root_Service    = "root",
	.Agent_Console   = "console",
	.Remote_Service  = "remote",
	.Trusted_Display = "compositor",
}

// Closed lifecycle state of a wide grant's act output wirings.
Act_Wiring_State :: enum u8 {
	Unwired = 0, // No active wide grant: act outputs are not wired; acts refused.
	Wired   = 1, // Active wide grant: all four act outputs wired to audit spaces.
	Ended   = 2, // Grant revoked or expired: end record written, wirings closed.
}

// Closed set of refusal reasons returned by act stream validation, wiring
// row building, and Grant_Act_Router transitions.
Act_Wiring_Refusal :: enum u64 {
	None                  = 0,
	No_Active_Grant       = 1,
	Grant_Revoked         = 2,
	Grant_Serial_Mismatch = 3,
	Principal_Mismatch    = 4,
	Bad_Producer          = 5,
	Bad_Act_Kind          = 6,
	Missing_Target_Window = 7,
	Producer_Not_Wired    = 8,
	Audit_Space_Full      = 9,
	Store_Refused         = 10,
	Already_Wired         = 11,
	Clock_Went_Back       = 12,
	Bad_Revocation_Reason = 13,
	Bad_Bound             = 14,
	Bad_Wiring_End        = 15,
	Duplicate_Handle      = 16,
	Buffer_Too_Small      = 17,
}

// Fixed-layout act record carried on each producer's `acts` record output
// and stored in the collector's per-producer audit space. Every byte is named
// by a field with no padding and no handle, so the build tool describes it
// directly in Record_Outputs.
Act_Stream_Record :: struct {
	grant_serial:     u64,
	principal_id:     u64,
	timestamp_ms:     u64,
	producer_word:    u64, // Act_Producer (1..4); 0 refused at border.
	act_kind_word:    u64, // Act_Kind (1..9); 0 refused at border.
	target_window_id: u64,
	detail_word_0:    u64,
	detail_word_1:    u64,
}
#assert(size_of(Act_Stream_Record) == 64)
#assert(size_of(Act_Stream_Record) <= SPACE_RECORD_BYTES_MOST)

// One running producer end to wire into collector.sources at grant activation.
Act_Producer_Endpoint :: struct {
	producer:     Act_Producer,
	end:          output.Wiring_End, // Started or Connected; Child and Asker refused.
	handle:       u32, // Lent handle place (Started) or connection handle (Connected).
	output_index: u32, // 1-based Record_Outputs index of `acts` in the producer module.
}

// State tracking the wired act audit spaces for the active wide grant of one
// principal.
Grant_Act_Router :: struct {
	state:               Act_Wiring_State,
	grant_serial:        u64,
	principal_id:        u64,
	wired_producers:     Act_Producers,
	ended_producers:     Act_Producers, // The writers of the grant that ended: their records of before the end are still read.
	space_numbers:       [Act_Producer]u32,
	emitted_counts:      [Act_Producer]u64,
	// The time of the last record of each writer: one ring is in the order
	// of its times, two rings are not in each other's order.
	writer_last_ms:      [Act_Producer]u64,
	last_timestamp_ms:   u64, // The clock of the collector at the start and the end of the grant.
	revocation_reason:   Revocation_Reason,
	ended_ms:            u64,
	revocation_recorded: bool,
	plan:                Act_Space_Plan,
	retained:            Retained_Grants, // Kept through each grant: the ring of the grants that the spaces keep.
}

// One grant of the ring that the act spaces keep: where its records start
// in the space of each writer.
Retained_Grant :: struct {
	grant_serial:  u64,
	first_serials: [Act_Producer]u64,
}

// The ring of the grants whose records the act spaces keep, oldest first.
// It lives in its own object of the private store, so a collector that
// starts again rotates the same grants out.
Retained_Grants :: struct {
	loaded: bool,
	count:  int,
	rows:   [ACT_RETAINED_GRANTS_MOST]Retained_Grant,
}

// The object of the ring of the grants, its first bytes, its version and
// the context string of its hash.
RETAINED_GRANTS_OBJECT_NAME :: "collector_act_grants"
RETAINED_GRANTS_MAGIC :: "mcolactg"
RETAINED_GRANTS_VERSION :: 1
RETAINED_GRANTS_HASH_DOMAIN :: "modus collector act grants v1"
RETAINED_GRANTS_HEAD_BYTES :: 16
RETAINED_GRANTS_ROW_BYTES :: 8 + 8 * ACT_PRODUCER_COUNT
RETAINED_GRANTS_BYTES_MOST :: RETAINED_GRANTS_HEAD_BYTES + ACT_RETAINED_GRANTS_MOST * RETAINED_GRANTS_ROW_BYTES + blake3.HASH_SIZE

// Border parser converting a raw transport word into Act_Producer, refusing 0
// and any unknown value.
act_producer_from_word :: proc "contextless" (word: u64) -> (producer: Act_Producer, ok: bool) {
	member := enum_word.member_of_word(Act_Producer, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// act_producer_from_source_name maps a collector source name back to its
// closed Act_Producer, refusing unknown or empty names.
act_producer_from_source_name :: proc "contextless" (name: []u8) -> (producer: Act_Producer, ok: bool) {
	for candidate in Act_Producer {
		if candidate == .None {
			continue
		}
		expected := ACT_PRODUCER_NAMES[candidate]
		if len(name) == len(expected) && string(name) == expected {
			return candidate, true
		}
	}
	return .None, false
}

// act_kind_is_lifecycle reports whether kind is a grant lifecycle transition
// emitted exclusively by Root_Service.
act_kind_is_lifecycle :: proc "contextless" (kind: Act_Kind) -> bool {
	switch kind {
	case .Grant_Started, .Grant_Revoked, .Grant_Expired:
		return true
	case .None, .Frame_Read, .Key_Injected, .Pointer_Moved, .Pointer_Clicked, .Action_Invoked, .Forbidden_Act_Blocked, .Call_Made, .Target_Window_Changed, .Input_Counted:
		return false
	}
	return false
}

// act_audit_space_terms returns the canonical append-only Audit Space_Terms
// for one wide-grant act record output space.
act_audit_space_terms :: proc "contextless" (bound_records: i64 = ACT_SPACE_BOUND_RECORDS) -> Space_Terms {
	return Space_Terms {
		kind_word       = i64(Collector_Space_Kind.Audit),
		bound_records   = bound_records,
		forwarding_word = i64(Space_Forwarding.Keeps),
		record_size     = size_of(Act_Stream_Record),
	}
}

// act_stream_record_encode writes record in canonical little-endian byte order.
act_stream_record_encode :: proc "contextless" (record: ^Act_Stream_Record) -> (bytes: [size_of(Act_Stream_Record)]u8) {
	byte_order.write_u64_little_endian(bytes[:], 0, record.grant_serial)
	byte_order.write_u64_little_endian(bytes[:], 8, record.principal_id)
	byte_order.write_u64_little_endian(bytes[:], 16, record.timestamp_ms)
	byte_order.write_u64_little_endian(bytes[:], 24, record.producer_word)
	byte_order.write_u64_little_endian(bytes[:], 32, record.act_kind_word)
	byte_order.write_u64_little_endian(bytes[:], 40, record.target_window_id)
	byte_order.write_u64_little_endian(bytes[:], 48, record.detail_word_0)
	byte_order.write_u64_little_endian(bytes[:], 56, record.detail_word_1)
	return bytes
}

// act_stream_record_decode reads an Act_Stream_Record from exact-length
// canonical little-endian bytes.
act_stream_record_decode :: proc "contextless" (bytes: []u8) -> (record: Act_Stream_Record, ok: bool) {
	if len(bytes) != size_of(Act_Stream_Record) {
		return {}, false
	}
	record = Act_Stream_Record {
		grant_serial     = byte_order.read_u64_little_endian(bytes, 0),
		principal_id     = byte_order.read_u64_little_endian(bytes, 8),
		timestamp_ms     = byte_order.read_u64_little_endian(bytes, 16),
		producer_word    = byte_order.read_u64_little_endian(bytes, 24),
		act_kind_word    = byte_order.read_u64_little_endian(bytes, 32),
		target_window_id = byte_order.read_u64_little_endian(bytes, 40),
		detail_word_0    = byte_order.read_u64_little_endian(bytes, 48),
		detail_word_1    = byte_order.read_u64_little_endian(bytes, 56),
	}
	return record, true
}

// act_stream_record_validate strictly checks one Act_Stream_Record at the
// border, converting producer_word and act_kind_word to their closed enums.
act_stream_record_validate :: proc "contextless" (record: ^Act_Stream_Record) -> (producer: Act_Producer, kind: Act_Kind, refusal: Act_Wiring_Refusal) {
	if record.grant_serial == 0 {
		return .None, .None, .No_Active_Grant
	}
	parsed_producer, producer_ok := act_producer_from_word(record.producer_word)
	if !producer_ok {
		return .None, .None, .Bad_Producer
	}
	parsed_kind, kind_ok := act_kind_from_word(record.act_kind_word)
	if !kind_ok {
		return .None, .None, .Bad_Act_Kind
	}
	if act_kind_requires_target_window(parsed_kind) && record.target_window_id == 0 {
		return .None, .None, .Missing_Target_Window
	}
	return parsed_producer, parsed_kind, .None
}

// act_wiring_rows_build builds the output.Wiring rows that connect each
// running act producer endpoint to collector.sources with Always_Holds_Writer
// and Audit Space_Terms. Refuses missing endpoints, invalid ends, zero or
// colliding handles, invalid bounds, or insufficient output buffer room.
act_wiring_rows_build :: proc "contextless" (
	collector_end: output.Wiring_End,
	collector_handle: u32,
	collector_input_index: u32,
	endpoints: []Act_Producer_Endpoint,
	terms_offset: u32,
	bound_records: i64,
	out_rows: []output.Wiring,
	out_terms: ^Space_Terms,
) -> (written: int, refusal: Act_Wiring_Refusal) {
	if len(endpoints) == 0 {
		return 0, .Bad_Wiring_End
	}
	if len(out_rows) < len(endpoints) || out_terms == nil {
		return 0, .Buffer_Too_Small
	}
	if (collector_end != .Started && collector_end != .Connected) || collector_handle == 0 || collector_input_index == 0 {
		return 0, .Bad_Wiring_End
	}
	if bound_records < 1 || bound_records > SPACE_AUDIT_BOUND_MOST {
		return 0, .Bad_Bound
	}
	seen_producers: Act_Producers
	for ep, index in endpoints {
		if ep.producer == .None || ep.producer in seen_producers {
			return 0, .Bad_Producer
		}
		if (ep.end != .Started && ep.end != .Connected) || ep.handle == 0 || ep.output_index == 0 {
			return 0, .Bad_Wiring_End
		}
		if ep.end == collector_end && ep.handle == collector_handle {
			return 0, .Duplicate_Handle
		}
		for earlier in endpoints[:index] {
			if earlier.end == ep.end && earlier.handle == ep.handle {
				return 0, .Duplicate_Handle
			}
		}
		seen_producers += {ep.producer}
	}
	terms := act_audit_space_terms(bound_records)
	for ep, index in endpoints {
		out_rows[index] = output.Wiring {
			writer_end    = u32(ep.end),
			writer_handle = ep.handle,
			writer_stream = u32(output.Writer_Stream.Record_Output),
			writer_index  = ep.output_index,
			reader_end    = u32(collector_end),
			reader_handle = collector_handle,
			reader_index  = collector_input_index,
			pace          = u32(output.Wiring_Pace.Always_Holds_Writer),
			capacity      = ACT_RING_CAPACITY,
			terms_offset  = terms_offset,
			terms_count   = size_of(Space_Terms),
		}
	}
	out_terms^ = terms
	return len(endpoints), .None
}

// act_space_refusal_map translates a collector Space_Refusal into the
// corresponding Act_Wiring_Refusal.
@(private = "file")
act_space_refusal_map :: proc "contextless" (refusal: Space_Refusal) -> Act_Wiring_Refusal {
	switch refusal {
	case .None:
		return .None
	case .Space_Full, .Forward_Full:
		return .Audit_Space_Full
	case .Store_Failed, .Store_Damaged:
		return .Store_Refused
	case .Bad_Bound, .Space_Limit_Reached:
		return .Bad_Bound
	case .Bad_Kind, .Bad_Forwarding, .Bad_Name, .Bad_Record_Size, .Unknown_Space, .Wrong_Size, .Not_Principal, .Own_Space, .Chain_Broken, .Forward_Empty, .Bad_Limit, .Space_Held:
		return .Store_Refused
	}
	return .Store_Refused
}

// retained_grants_load reads the ring of the grants from the private store
// once. No object is an empty ring; a damaged one refuses the grant: the
// spaces would else grow with no grant to rotate out.
@(private = "file")
retained_grants_load :: proc "contextless" (store: ^Space_Store, retained: ^Retained_Grants) -> Act_Wiring_Refusal {
	if retained.loaded {
		return .None
	}
	buffer: [RETAINED_GRANTS_BYTES_MOST]u8
	bytes, status := pr.private_store_read(&store.store_port, RETAINED_GRANTS_OBJECT_NAME, buffer[:])
	switch status {
	case .Ok:
	case .Absent:
		retained^ = {loaded = true}
		return .None
	case .Too_Large, .Failed:
		return .Store_Refused
	}
	if len(bytes) < RETAINED_GRANTS_HEAD_BYTES + blake3.HASH_SIZE || string(bytes[:8]) != RETAINED_GRANTS_MAGIC || byte_order.read_u32_little_endian(bytes, 8) != RETAINED_GRANTS_VERSION {
		return .Store_Refused
	}
	count := int(byte_order.read_u32_little_endian(bytes, 12))
	if count > ACT_RETAINED_GRANTS_MOST || len(bytes) != RETAINED_GRANTS_HEAD_BYTES + count * RETAINED_GRANTS_ROW_BYTES + blake3.HASH_SIZE {
		return .Store_Refused
	}
	hash_at := len(bytes) - blake3.HASH_SIZE
	grants_hash := blake3.derive_key(RETAINED_GRANTS_HASH_DOMAIN, bytes[:hash_at])
	if string(grants_hash[:]) != string(bytes[hash_at:]) {
		return .Store_Refused
	}
	read: Retained_Grants = {loaded = true, count = count}
	for index in 0 ..< count {
		row := bytes[RETAINED_GRANTS_HEAD_BYTES + index * RETAINED_GRANTS_ROW_BYTES:][:RETAINED_GRANTS_ROW_BYTES]
		read.rows[index].grant_serial = byte_order.read_u64_little_endian(row, 0)
		at := 8
		for producer in Act_Producer {
			if producer == .None {
				continue
			}
			read.rows[index].first_serials[producer] = byte_order.read_u64_little_endian(row, at)
			at += 8
		}
	}
	retained^ = read
	return .None
}

// retained_grants_persist writes the ring of the grants whole.
@(private = "file")
retained_grants_persist :: proc "contextless" (store: ^Space_Store, retained: ^Retained_Grants) -> Act_Wiring_Refusal {
	bytes: [RETAINED_GRANTS_BYTES_MOST]u8
	copy(bytes[:8], RETAINED_GRANTS_MAGIC)
	byte_order.write_u32_little_endian(bytes[:], 8, RETAINED_GRANTS_VERSION)
	byte_order.write_u32_little_endian(bytes[:], 12, u32(retained.count))
	at := RETAINED_GRANTS_HEAD_BYTES
	for index in 0 ..< retained.count {
		byte_order.write_u64_little_endian(bytes[:], at, retained.rows[index].grant_serial)
		at += 8
		for producer in Act_Producer {
			if producer == .None {
				continue
			}
			byte_order.write_u64_little_endian(bytes[:], at, retained.rows[index].first_serials[producer])
			at += 8
		}
	}
	grants_hash := blake3.derive_key(RETAINED_GRANTS_HASH_DOMAIN, bytes[:at])
	copy(bytes[at:][:blake3.HASH_SIZE], grants_hash[:])
	at += blake3.HASH_SIZE
	if pr.private_store_write(&store.store_port, RETAINED_GRANTS_OBJECT_NAME, bytes[:at]) != .Ok {
		return .Store_Refused
	}
	return .None
}

// act_room_short says if the space of a writer has less room than a grant
// needs: its allowance, and the ring of the reserve.
@(private = "file")
act_room_short :: proc "contextless" (store: ^Space_Store, space_number: u32, needed: u64) -> bool {
	space := space_of(store, space_number)
	if space == nil {
		return true
	}
	return space_kept_count(space) + needed > u64(space.bound)
}

// act_wiring_attach wires all four act record outputs (root, console, remote,
// compositor) to append-only Audit spaces in the principal's collector store
// and writes the opening Grant_Started record from Root_Service. It makes
// room first: while the ring of the kept grants is full, or a space has
// less room than the grant needs, the oldest grant of the ring rotates out
// of each space. The grant that ended before is closed: no open grant ever
// rotates. Fails closed with the router unchanged if any space cannot open,
// the room cannot be made, or the opening record cannot be persisted.
act_wiring_attach :: proc "contextless" (
	router: ^Grant_Act_Router,
	store: ^Space_Store,
	grant_serial: u64,
	principal_id: u64,
	authorities: Wide_Authorities,
	duration_ms: u64,
	now_ms: u64,
	plan: Act_Space_Plan = ACT_SPACE_PLAN,
) -> Act_Wiring_Refusal {
	if grant_serial == 0 {
		return .No_Active_Grant
	}
	if store == nil || principal_id != store.principal {
		return .Principal_Mismatch
	}
	if !act_space_plan_valid(plan) {
		return .Bad_Bound
	}
	if router.state == .Wired && router.grant_serial == grant_serial {
		return .Already_Wired
	}
	if router.state == .Wired {
		// The grant before must end first, with its record.
		return .Already_Wired
	}
	if router.last_timestamp_ms > 0 && now_ms < router.last_timestamp_ms {
		return .Clock_Went_Back
	}

	terms := act_audit_space_terms(plan.bound_records)
	opened: [Act_Producer]u32
	for producer in ACT_PRODUCERS_WIRED {
		source_name := transmute([]u8)ACT_PRODUCER_NAMES[producer]
		output_name := transmute([]u8)string(ACT_OUTPUT_NAME)
		space_number, open_refusal := space_open(store, source_name, output_name, terms)
		if open_refusal != .None {
			return act_space_refusal_map(open_refusal)
		}
		opened[producer] = space_number
	}

	retained := router.retained
	if load_refusal := retained_grants_load(store, &retained); load_refusal != .None {
		return load_refusal
	}
	allowance := act_grant_allowance(plan, duration_ms)
	needed :: proc "contextless" (producer: Act_Producer, allowance: u64) -> u64 {
		return (producer == .Root_Service ? ACT_ROOT_RECORDS_PER_GRANT : allowance) + u64(ACT_RING_CAPACITY)
	}
	for {
		short := retained.count >= plan.retained_grants
		for producer in ACT_PRODUCERS_WIRED {
			if act_room_short(store, opened[producer], needed(producer, allowance)) {
				short = true
			}
		}
		if !short {
			break
		}
		if retained.count == 0 {
			// Each grant rotated out and the room is still short: records that
			// no grant of the ring names fill the space. They rotate out too.
			for producer in ACT_PRODUCERS_WIRED {
				space := space_of(store, opened[producer])
				if space_rotate_before(store, opened[producer], space.next_serial) != .None {
					return .Store_Refused
				}
				if act_room_short(store, opened[producer], needed(producer, allowance)) {
					return .Audit_Space_Full
				}
			}
			break
		}
		// The oldest grant of the ring rotates out: each space keeps from the
		// first record of the grant after it.
		for producer in ACT_PRODUCERS_WIRED {
			boundary := retained.count > 1 ? retained.rows[1].first_serials[producer] : space_of(store, opened[producer]).next_serial
			if space_rotate_before(store, opened[producer], boundary) != .None {
				return .Store_Refused
			}
		}
		copy(retained.rows[:retained.count - 1], retained.rows[1:retained.count])
		retained.rows[retained.count - 1] = {}
		retained.count -= 1
	}
	row := Retained_Grant{grant_serial = grant_serial}
	for producer in ACT_PRODUCERS_WIRED {
		row.first_serials[producer] = space_of(store, opened[producer]).next_serial
	}
	retained.rows[retained.count] = row
	retained.count += 1
	if persist_refusal := retained_grants_persist(store, &retained); persist_refusal != .None {
		return persist_refusal
	}

	start_record := Act_Stream_Record {
		grant_serial  = grant_serial,
		principal_id  = principal_id,
		timestamp_ms  = now_ms,
		producer_word = u64(Act_Producer.Root_Service),
		act_kind_word = u64(Act_Kind.Grant_Started),
		detail_word_0 = wide_authorities_to_word(authorities),
		detail_word_1 = duration_ms,
	}
	encoded := act_stream_record_encode(&start_record)
	_, append_refusal := record_append(store, opened[.Root_Service], encoded[:], now_ms)
	if append_refusal != .None {
		// The ring names a grant with no start: it rotates out with the
		// others, and holds no record.
		router.retained = retained
		return act_space_refusal_map(append_refusal)
	}

	router^ = Grant_Act_Router {
		state             = .Wired,
		grant_serial      = grant_serial,
		principal_id      = principal_id,
		wired_producers   = ACT_PRODUCERS_WIRED,
		space_numbers     = opened,
		last_timestamp_ms = now_ms,
		plan              = plan,

		retained          = retained,
	}
	router.emitted_counts[.Root_Service] = 1
	// A record of a time before the start of the grant is of no act of it.
	for &last in router.writer_last_ms {
		last = now_ms
	}
	return .None
}

// act_link_may_read says if the collector may read the next record of the
// ring of a writer. While the grant holds, the space keeps room for a whole
// ring: below that room it reads no more, the ring fills, and the writer
// refuses its next act. After the end it reads the ring to its end into
// that room: each record there is an act that ran before the end.
act_link_may_read :: proc "contextless" (router: ^Grant_Act_Router, store: ^Space_Store, link: ^Source_Link) -> bool {
	if router.state != .Wired {
		return true
	}
	space := space_of(store, link.space)
	if space == nil {
		return true
	}
	return space_kept_count(space) + u64(ACT_RING_CAPACITY) < u64(space.bound)
}

// act_wiring_accepts_stream_record checks whether an incoming Act_Stream_Record
// arriving on a wired producer ring is permitted for the currently wired grant.
// Refuses records with no active grant, records after revocation/expiry,
// spoofed producer identities, mismatched grant serials or principals, and
// lifecycle records emitted by non-root producers.
act_wiring_accepts_stream_record :: proc "contextless" (
	router: ^Grant_Act_Router,
	record: ^Act_Stream_Record,
	expected_producer: Act_Producer,
) -> Act_Wiring_Refusal {
	if expected_producer == .None {
		return .Bad_Producer
	}
	producer, kind, valid_refusal := act_stream_record_validate(record)
	if valid_refusal != .None {
		return valid_refusal
	}
	if producer != expected_producer {
		return .Bad_Producer
	}
	writers := router.wired_producers
	switch router.state {
	case .Unwired:
		return .No_Active_Grant
	case .Ended:
		// A record of the grant that ended, from a writer of it, with a time
		// at or before the end, is an act that ran while the grant held, and
		// waited in its ring: it is kept. Each other one is refused.
		if record.grant_serial != router.grant_serial || record.timestamp_ms > router.ended_ms {
			return .Grant_Revoked
		}
		writers = router.ended_producers
	case .Wired:
	}
	if record.grant_serial != router.grant_serial {
		return .Grant_Serial_Mismatch
	}
	if record.principal_id != router.principal_id {
		return .Principal_Mismatch
	}
	if producer not_in writers {
		return .Producer_Not_Wired
	}
	if act_kind_is_lifecycle(kind) && producer != .Root_Service {
		return .Bad_Act_Kind
	}
	if record.timestamp_ms < router.writer_last_ms[producer] {
		return .Clock_Went_Back
	}
	return .None
}

// act_wiring_emit validates and appends one Act_Stream_Record into its
// producer's audit space in store. Fails closed if no grant is active, if the
// grant was revoked or expired, or if the audit space is full.
act_wiring_emit :: proc "contextless" (
	router: ^Grant_Act_Router,
	store: ^Space_Store,
	record: Act_Stream_Record,
) -> (serial: u64, refusal: Act_Wiring_Refusal) {
	local := record
	producer, _, valid_refusal := act_stream_record_validate(&local)
	if valid_refusal != .None {
		return 0, valid_refusal
	}
	if gate := act_wiring_accepts_stream_record(router, &local, producer); gate != .None {
		return 0, gate
	}
	if store == nil || store.principal != router.principal_id {
		return 0, .Principal_Mismatch
	}
	space_number := router.space_numbers[producer]
	if space_number == 0 {
		return 0, .Producer_Not_Wired
	}
	encoded := act_stream_record_encode(&local)
	appended_serial, append_refusal := record_append(store, space_number, encoded[:], local.timestamp_ms)
	if append_refusal != .None {
		return 0, act_space_refusal_map(append_refusal)
	}
	router.emitted_counts[producer] += 1
	router.writer_last_ms[producer] = local.timestamp_ms
	return appended_serial, .None
}

// act_wiring_revoke records Grant_Revoked from Root_Service and closes all
// four act output wirings immediately so subsequent acts are refused with
// Grant_Revoked. Revocation always closes the wirings even if the audit space
// is full so an agent cannot block revocation by filling its audit log.
act_wiring_revoke :: proc "contextless" (
	router: ^Grant_Act_Router,
	store: ^Space_Store,
	grant_serial: u64,
	reason: Revocation_Reason,
	now_ms: u64,
) -> Act_Wiring_Refusal {
	parsed_reason, reason_ok := revocation_reason_from_word(u64(reason))
	if !reason_ok {
		return .Bad_Revocation_Reason
	}
	switch router.state {
	case .Unwired:
		return .No_Active_Grant
	case .Ended:
		return .Grant_Revoked
	case .Wired:
	}
	if grant_serial != router.grant_serial {
		return .Grant_Serial_Mismatch
	}
	if now_ms < router.last_timestamp_ms {
		return .Clock_Went_Back
	}

	recorded := false
	if store != nil && store.principal == router.principal_id && router.space_numbers[.Root_Service] != 0 {
		end_record := Act_Stream_Record {
			grant_serial  = grant_serial,
			principal_id  = router.principal_id,
			timestamp_ms  = now_ms,
			producer_word = u64(Act_Producer.Root_Service),
			act_kind_word = u64(Act_Kind.Grant_Revoked),
			detail_word_0 = u64(parsed_reason),
		}
		encoded := act_stream_record_encode(&end_record)
		_, append_refusal := record_append(store, router.space_numbers[.Root_Service], encoded[:], now_ms)
		if append_refusal == .None {
			router.emitted_counts[.Root_Service] += 1
			recorded = true
		}
	}

	router.state = .Ended
	router.ended_producers = router.wired_producers
	router.wired_producers = {}
	router.revocation_reason = parsed_reason
	router.ended_ms = now_ms
	router.last_timestamp_ms = now_ms
	router.revocation_recorded = recorded
	return .None
}

// act_link_keep is the step of one record that a ring of an act record
// output brings to the collector. A record that does not decode, of another
// producer, of no grant, of an ended grant or of another grant is refused
// before its space sees it: the link closes with no pending record, and the
// space keeps nothing. A record that passes goes to link_keep, whose Held
// keeps it pending while the space is full.
act_link_keep :: proc "contextless" (
	router: ^Grant_Act_Router,
	store: ^Space_Store,
	link: ^Source_Link,
	record: []u8,
	expected_producer: Act_Producer,
	time_ms: u64,
) -> (step: Link_Step, act_refusal: Act_Wiring_Refusal, space_refusal: Space_Refusal) {
	stream_record, decoded := act_stream_record_decode(record)
	act_refusal = .Bad_Producer
	if decoded {
		act_refusal = act_wiring_accepts_stream_record(router, &stream_record, expected_producer)
	}
	if act_refusal != .None {
		link_close(link, errors.error_make(.Refused, .Records, 0, i64(act_refusal), i64(link.record_size), i64(link.tag)))
		return .Refused, act_refusal, .None
	}
	step, space_refusal = link_keep(store, link, record, time_ms)
	switch step {
	case .Kept, .Held:
		// A record that the space holds pending counts too: its time is
		// past, and a later record of an earlier time is a clock that went
		// back.
		router.writer_last_ms[expected_producer] = max(router.writer_last_ms[expected_producer], stream_record.timestamp_ms)
		if step == .Kept {
			router.emitted_counts[expected_producer] += 1
		}
	case .Refused:
		link_close(link, errors.error_make(.Bad_Value, .Records, 0, i64(space_refusal), i64(link.record_size), i64(link.tag)))
	}
	return step, .None, space_refusal
}

// act_links_close_ended closes each link that feeds an act space of a
// router whose grant ended and holds a pending record: a record that its
// full space held, which no room will keep after the end. A link with no
// pending record stays open: its ring is read to its end, and its records
// of before the end are kept. It writes the tags of the rings that the
// caller closes, and gives their count. A router that holds a grant closes
// nothing, so an agent that fills its space cannot end the links of
// another grant.
act_links_close_ended :: proc "contextless" (router: ^Grant_Act_Router, links: ^Source_Links, closed_tags: []u32) -> (count: int) {
	if router.state != .Ended {
		return 0
	}
	for &link in links.links {
		if !link.active || link.state != .Open || !link.pending || count >= len(closed_tags) {
			continue
		}
		for producer in Act_Producer {
			if producer == .None || router.space_numbers[producer] != link.space {
				continue
			}
			link_close(&link, errors.error_make(.Refused, .Records, 0, i64(Act_Wiring_Refusal.Grant_Revoked), i64(link.record_size), i64(link.tag)))
			closed_tags[count] = link.tag
			count += 1
			break
		}
	}
	return count
}

// act_links_close_replaced closes each open link that feeds an act space of
// a router whose grant ended because a newer grant replaces it, pending
// record or not: once the newer grant holds, a record of the old grant on
// such a ring would close a ring of the newer one. A record that the ring
// still held is lost, and the record of the end says that the grant was
// replaced. It writes the tags of the rings that the caller closes, and
// gives their count. A router that holds a grant closes nothing.
act_links_close_replaced :: proc "contextless" (router: ^Grant_Act_Router, links: ^Source_Links, closed_tags: []u32) -> (count: int) {
	if router.state != .Ended {
		return 0
	}
	for &link in links.links {
		if !link.active || link.state != .Open || count >= len(closed_tags) {
			continue
		}
		for producer in Act_Producer {
			if producer == .None || router.space_numbers[producer] != link.space {
				continue
			}
			link_close(&link, errors.error_make(.Refused, .Records, 0, i64(Act_Wiring_Refusal.Grant_Revoked), i64(link.record_size), i64(link.tag)))
			closed_tags[count] = link.tag
			count += 1
			break
		}
	}
	return count
}

// act_wiring_expire records Grant_Expired from Root_Service and closes all
// four act output wirings immediately.
act_wiring_expire :: proc "contextless" (
	router: ^Grant_Act_Router,
	store: ^Space_Store,
	grant_serial: u64,
	expires_ms: u64,
	now_ms: u64,
) -> Act_Wiring_Refusal {
	switch router.state {
	case .Unwired:
		return .No_Active_Grant
	case .Ended:
		return .Grant_Revoked
	case .Wired:
	}
	if grant_serial != router.grant_serial {
		return .Grant_Serial_Mismatch
	}
	if now_ms < router.last_timestamp_ms {
		return .Clock_Went_Back
	}

	recorded := false
	if store != nil && store.principal == router.principal_id && router.space_numbers[.Root_Service] != 0 {
		end_record := Act_Stream_Record {
			grant_serial  = grant_serial,
			principal_id  = router.principal_id,
			timestamp_ms  = now_ms,
			producer_word = u64(Act_Producer.Root_Service),
			act_kind_word = u64(Act_Kind.Grant_Expired),
			detail_word_0 = expires_ms,
		}
		encoded := act_stream_record_encode(&end_record)
		_, append_refusal := record_append(store, router.space_numbers[.Root_Service], encoded[:], now_ms)
		if append_refusal == .None {
			router.emitted_counts[.Root_Service] += 1
			recorded = true
		}
	}

	router.state = .Ended
	router.ended_producers = router.wired_producers
	router.wired_producers = {}
	router.ended_ms = now_ms
	router.last_timestamp_ms = now_ms
	router.revocation_recorded = recorded
	return .None
}
