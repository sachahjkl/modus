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

import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/output"

// Name of the record output declared by each wide-grant act producer.
ACT_OUTPUT_NAME :: "acts"

// Default per-producer audit space bound in records for a wide grant: four
// producers * 32 records = 128 records, leaving half of SPACE_ROOM_RECORDS
// free for server audit spaces in the same collector.
ACT_SPACE_BOUND_RECORDS :: i64(32)
#assert(ACT_SPACE_BOUND_RECORDS * 4 <= SPACE_ROOM_RECORDS)

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
	space_numbers:       [Act_Producer]u32,
	emitted_counts:      [Act_Producer]u64,
	last_timestamp_ms:   u64,
	revocation_reason:   Revocation_Reason,
	ended_ms:            u64,
	revocation_recorded: bool,
}

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
	case .None, .Frame_Read, .Key_Injected, .Pointer_Moved, .Pointer_Clicked, .Action_Invoked, .Forbidden_Act_Blocked:
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
	if bound_records < 1 || bound_records > SPACE_RECORDS_MOST {
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
			capacity      = 0,
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
	case .Bad_Bound, .Bound_Past_Room, .Space_Limit_Reached:
		return .Bad_Bound
	case .Bad_Kind, .Bad_Forwarding, .Bad_Name, .Bad_Record_Size, .Unknown_Space, .Wrong_Size, .Not_Principal, .Own_Space, .Chain_Broken, .Forward_Empty, .Bad_Limit, .Space_Held:
		return .Store_Refused
	}
	return .Store_Refused
}

// act_wiring_attach wires all four act record outputs (root, console, remote,
// compositor) to append-only Audit spaces in the principal's collector store
// and writes the opening Grant_Started record from Root_Service. Fails closed
// with router state unchanged if any space cannot open or the opening record
// cannot be persisted.
act_wiring_attach :: proc "contextless" (
	router: ^Grant_Act_Router,
	store: ^Space_Store,
	grant_serial: u64,
	principal_id: u64,
	authorities: Wide_Authorities,
	duration_ms: u64,
	now_ms: u64,
	bound_records: i64 = ACT_SPACE_BOUND_RECORDS,
) -> Act_Wiring_Refusal {
	if grant_serial == 0 {
		return .No_Active_Grant
	}
	if store == nil || principal_id != store.principal {
		return .Principal_Mismatch
	}
	if bound_records < 1 || bound_records > SPACE_RECORDS_MOST {
		return .Bad_Bound
	}
	if router.state == .Wired && router.grant_serial == grant_serial {
		return .Already_Wired
	}
	if router.last_timestamp_ms > 0 && now_ms < router.last_timestamp_ms {
		return .Clock_Went_Back
	}

	terms := act_audit_space_terms(bound_records)
	opened: [Act_Producer]u32
	for producer in Act_Producer {
		if producer == .None {
			continue
		}
		source_name := transmute([]u8)ACT_PRODUCER_NAMES[producer]
		output_name := transmute([]u8)string(ACT_OUTPUT_NAME)
		space_number, open_refusal := space_open(store, source_name, output_name, terms)
		if open_refusal != .None {
			return act_space_refusal_map(open_refusal)
		}
		opened[producer] = space_number
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
		return act_space_refusal_map(append_refusal)
	}

	router^ = Grant_Act_Router {
		state             = .Wired,
		grant_serial      = grant_serial,
		principal_id      = principal_id,
		wired_producers   = ALL_ACT_PRODUCERS,
		space_numbers     = opened,
		last_timestamp_ms = now_ms,
	}
	router.emitted_counts[.Root_Service] = 1
	return .None
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
	switch router.state {
	case .Unwired:
		return .No_Active_Grant
	case .Ended:
		return .Grant_Revoked
	case .Wired:
	}
	if record.grant_serial != router.grant_serial {
		return .Grant_Serial_Mismatch
	}
	if record.principal_id != router.principal_id {
		return .Principal_Mismatch
	}
	if producer not_in router.wired_producers {
		return .Producer_Not_Wired
	}
	if act_kind_is_lifecycle(kind) && producer != .Root_Service {
		return .Bad_Act_Kind
	}
	if record.timestamp_ms < router.last_timestamp_ms {
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
	router.last_timestamp_ms = local.timestamp_ms
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
	router.wired_producers = {}
	router.revocation_reason = parsed_reason
	router.ended_ms = now_ms
	router.last_timestamp_ms = now_ms
	router.revocation_recorded = recorded
	return .None
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
	router.wired_producers = {}
	router.ended_ms = now_ms
	router.last_timestamp_ms = now_ms
	router.revocation_recorded = recorded
	return .None
}
