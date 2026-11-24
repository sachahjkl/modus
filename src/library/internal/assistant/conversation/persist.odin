// Canonical binary persistence of an assistant Conversation for the private
// store of the assistant window (src/md/features/assistant.md, "The
// conversation kept in the private store").
//
// Format layout (little-endian, zero implicit padding):
//   Header (PERSIST_HEADER_BYTES = 80):
//     [0..8]   magic:         "MODASCV1"
//     [8..40]  digest:        BLAKE3 derive_key over bytes [40 .. 80 + payload_bytes]
//     [40..44] version:       u32 (1)
//     [44..48] entry_count:   u32 (0 .. CONVERSATION_ENTRY_CAPACITY)
//     [48..56] last_serial:   u64
//     [56..64] last_act:      u64
//     [64..72] last_entry:    u64
//     [72..76] payload_bytes: u32
//     [76..80] reserved:      u32 (must be 0)
//   Payload (payload_bytes): entry_count variable-length entry records.
//
// Two-pass decode: every field, enum word, counter relation, UTF-8/control
// rule, integrity digest, and exact byte length is verified before the
// destination Conversation is touched. Any refusal leaves destination
// unchanged.
package conversation

import "base:intrinsics"
import assistant_contract "modus:contract/assistant"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/errors"

// Format property: canonical 8-byte magic identifying stored assistant
// conversations.
PERSIST_MAGIC :: [8]u8{'M', 'O', 'D', 'A', 'S', 'C', 'V', '1'}

// Format property: current canonical encoding version.
PERSIST_VERSION :: u32(1)

// Format property: BLAKE3 derive_key domain separation context.
PERSIST_HASH_DOMAIN :: "modus assistant conversation v1"

// Format property: fixed header size (8 magic + 32 digest + 40 metadata).
PERSIST_HEADER_BYTES :: 80
PERSIST_HASH_OFFSET :: 8
PERSIST_SIGNED_OFFSET :: 40

// Format property: fixed per-entry header size before variable-length text,
// line, service, and export byte slices.
PERSIST_ENTRY_HEADER_BYTES :: 96

// Format property: known boolean flag bits inside an encoded entry header.
PERSIST_FLAG_TAKEN :: u8(1 << 0)
PERSIST_FLAG_STOP_REQUESTED :: u8(1 << 1)
PERSIST_FLAG_EXPANDED :: u8(1 << 2)
PERSIST_FLAG_FOLD_TOGGLED :: u8(1 << 3)
PERSIST_FLAGS_KNOWN_MASK :: PERSIST_FLAG_TAKEN | PERSIST_FLAG_STOP_REQUESTED | PERSIST_FLAG_EXPANDED | PERSIST_FLAG_FOLD_TOGGLED

// Computed upper bound on one encoded entry and one full conversation.
PERSIST_ENTRY_MAX_BYTES :: PERSIST_ENTRY_HEADER_BYTES + assistant_contract.REPLY_TEXT_BYTES + assistant_contract.ACT_LINE_BYTES + 2 * assistant_contract.ACT_NAME_BYTES
PERSIST_MAX_BYTES :: PERSIST_HEADER_BYTES + assistant_contract.CONVERSATION_ENTRY_CAPACITY * PERSIST_ENTRY_MAX_BYTES

// Closed set of refusals returned by persist_encode and persist_decode.
Persist_Refusal :: enum u8 {
	None                = 0,
	Buffer_Too_Small    = 1,
	Truncated           = 2,
	Bad_Magic           = 3,
	Unsupported_Version = 4,
	Bad_Length          = 5,
	Hash_Mismatch       = 6,
	Trailing_Bytes      = 7,
	Bad_Count           = 8,
	Bad_Enum            = 9,
	Bad_Flags           = 10,
	Bad_Text            = 11,
	Bad_Counters        = 12,
}

// persist_encoded_size gives the exact byte count needed to encode conversation.
persist_encoded_size :: proc "contextless" (conversation: ^Conversation) -> int {
	if conversation == nil {
		return 0
	}
	count := clamp(conversation.entry_count, 0, len(conversation.entries))
	total := PERSIST_HEADER_BYTES
	for index in 0 ..< count {
		entry := entry_at(conversation, index)
		text_len := clamp(entry.text_count, 0, len(entry.text))
		line_len := clamp(entry.line_count, 0, len(entry.line))
		service_len := clamp(entry.service_count, 0, len(entry.service))
		export_len := clamp(entry.export_count, 0, len(entry.export))
		total += PERSIST_ENTRY_HEADER_BYTES + text_len + line_len + service_len + export_len
	}
	return total
}

// persist_encode serializes conversation into destination and writes its
// domain-separated BLAKE3 digest.
persist_encode :: proc "contextless" (conversation: ^Conversation, destination: []u8) -> (written: int, refusal: Persist_Refusal) {
	if conversation == nil {
		return 0, .Bad_Count
	}
	if conversation.entry_count < 0 || conversation.entry_count > len(conversation.entries) {
		return 0, .Bad_Count
	}
	needed := persist_encoded_size(conversation)
	if len(destination) < needed {
		return 0, .Buffer_Too_Small
	}
	magic := PERSIST_MAGIC
	copy(destination[0:8], magic[:])
	payload_bytes := needed - PERSIST_HEADER_BYTES
	byte_order.write_u32_little_endian(destination, 40, PERSIST_VERSION)
	byte_order.write_u32_little_endian(destination, 44, u32(conversation.entry_count))
	byte_order.write_u64_little_endian(destination, 48, conversation.last_serial)
	byte_order.write_u64_little_endian(destination, 56, conversation.last_act)
	byte_order.write_u64_little_endian(destination, 64, conversation.last_entry)
	byte_order.write_u32_little_endian(destination, 72, u32(payload_bytes))
	byte_order.write_u32_little_endian(destination, 76, 0)

	cursor := PERSIST_HEADER_BYTES
	for index in 0 ..< conversation.entry_count {
		entry := entry_at(conversation, index)
		hdr := destination[cursor:cursor + PERSIST_ENTRY_HEADER_BYTES]
		hdr[0] = u8(entry.kind)
		hdr[1] = u8(entry.act_kind)
		hdr[2] = u8(entry.state)
		hdr[3] = u8(entry.turn)
		hdr[4] = entry.step
		hdr[5] = entry.step_count
		hdr[6] = entry.last_act_step
		hdr[7] = entry.step_acts
		hdr[8] = u8(entry.end_cause)
		flags: u8 = 0
		if entry.taken {
			flags |= PERSIST_FLAG_TAKEN
		}
		if entry.stop_requested {
			flags |= PERSIST_FLAG_STOP_REQUESTED
		}
		if entry.expanded {
			flags |= PERSIST_FLAG_EXPANDED
		}
		if entry.fold_toggled {
			flags |= PERSIST_FLAG_FOLD_TOGGLED
		}
		hdr[9] = flags
		byte_order.write_u16_little_endian(hdr, 10, 0)
		byte_order.write_u16_little_endian(hdr, 12, u16(clamp(entry.acts_counted, 0, assistant_contract.MODEL_ACT_CAPACITY)))
		byte_order.write_u16_little_endian(hdr, 14, u16(clamp(entry.acts_given, 0, assistant_contract.MODEL_ACT_CAPACITY)))
		byte_order.write_u64_little_endian(hdr, 16, entry.number)
		byte_order.write_u64_little_endian(hdr, 24, entry.serial)
		byte_order.write_u64_little_endian(hdr, 32, entry.act)
		text_len := clamp(entry.text_count, 0, len(entry.text))
		line_len := clamp(entry.line_count, 0, len(entry.line))
		service_len := clamp(entry.service_count, 0, len(entry.service))
		export_len := clamp(entry.export_count, 0, len(entry.export))
		byte_order.write_u16_little_endian(hdr, 40, u16(text_len))
		byte_order.write_u16_little_endian(hdr, 42, u16(line_len))
		hdr[44] = u8(service_len)
		hdr[45] = u8(export_len)
		byte_order.write_u16_little_endian(hdr, 46, 0)
		byte_order.write_u64_little_endian(hdr, 48, u64(entry.error.kind))
		byte_order.write_u64_little_endian(hdr, 56, u64(entry.error.unit))
		byte_order.write_u64_little_endian(hdr, 64, u64(entry.error.argument))
		byte_order.write_u64_little_endian(hdr, 72, u64(entry.error.value))
		byte_order.write_u64_little_endian(hdr, 80, u64(entry.error.limit))
		byte_order.write_u64_little_endian(hdr, 88, u64(entry.error.found))
		cursor += PERSIST_ENTRY_HEADER_BYTES
		if text_len > 0 {
			copy(destination[cursor:cursor + text_len], entry.text[:text_len])
			cursor += text_len
		}
		if line_len > 0 {
			copy(destination[cursor:cursor + line_len], entry.line[:line_len])
			cursor += line_len
		}
		if service_len > 0 {
			copy(destination[cursor:cursor + service_len], entry.service[:service_len])
			cursor += service_len
		}
		if export_len > 0 {
			copy(destination[cursor:cursor + export_len], entry.export[:export_len])
			cursor += export_len
		}
	}

	digest := blake3.derive_key(PERSIST_HASH_DOMAIN, destination[PERSIST_SIGNED_OFFSET:needed])
	copy(destination[PERSIST_HASH_OFFSET:PERSIST_HASH_OFFSET + blake3.HASH_SIZE], digest[:])
	return needed, .None
}

// persist_decode verifies data completely before populating destination.
// On any refusal, destination is untouched.
persist_decode :: proc "contextless" (destination: ^Conversation, data: []u8) -> Persist_Refusal {
	if destination == nil {
		return .Bad_Count
	}
	if len(data) < PERSIST_HEADER_BYTES {
		return .Truncated
	}
	magic := PERSIST_MAGIC
	for i in 0 ..< 8 {
		if data[i] != magic[i] {
			return .Bad_Magic
		}
	}
	version := byte_order.read_u32_little_endian(data, 40)
	if version != PERSIST_VERSION {
		return .Unsupported_Version
	}
	entry_count := int(byte_order.read_u32_little_endian(data, 44))
	if entry_count < 0 || entry_count > assistant_contract.CONVERSATION_ENTRY_CAPACITY {
		return .Bad_Count
	}
	last_serial := byte_order.read_u64_little_endian(data, 48)
	last_act := byte_order.read_u64_little_endian(data, 56)
	last_entry := byte_order.read_u64_little_endian(data, 64)
	payload_bytes := int(byte_order.read_u32_little_endian(data, 72))
	reserved := byte_order.read_u32_little_endian(data, 76)
	if reserved != 0 {
		return .Bad_Flags
	}
	if payload_bytes < 0 || payload_bytes > PERSIST_MAX_BYTES - PERSIST_HEADER_BYTES {
		return .Bad_Length
	}
	expected_total := PERSIST_HEADER_BYTES + payload_bytes
	if len(data) < expected_total {
		return .Truncated
	}
	if len(data) > expected_total {
		return .Trailing_Bytes
	}

	// Verify BLAKE3 integrity digest over metadata + payload (constant-time compare).
	expected_digest := blake3.derive_key(PERSIST_HASH_DOMAIN, data[PERSIST_SIGNED_OFFSET:expected_total])
	diff: u8 = 0
	for i in 0 ..< blake3.HASH_SIZE {
		diff |= data[PERSIST_HASH_OFFSET + i] ~ expected_digest[i]
	}
	if diff != 0 {
		return .Hash_Mismatch
	}

	// Pass 1: validate every entry strictly without mutating destination.
	cursor := PERSIST_HEADER_BYTES
	prev_number: u64 = 0
	for _ in 0 ..< entry_count {
		next_cursor, refusal := persist_validate_entry(data, cursor, last_serial, last_act, last_entry, &prev_number)
		if refusal != .None {
			return refusal
		}
		cursor = next_cursor
	}
	if cursor != expected_total {
		return .Trailing_Bytes
	}

	// Pass 2: all bytes are verified; rebuild destination cleanly in place.
	intrinsics.mem_zero(destination, size_of(Conversation))
	destination.last_serial = last_serial
	destination.last_act = last_act
	destination.last_entry = last_entry
	destination.entry_first = 0
	destination.entry_count = entry_count

	cursor = PERSIST_HEADER_BYTES
	for index in 0 ..< entry_count {
		entry := &destination.entries[index]
		cursor = persist_read_entry(data, cursor, entry)
		if entry.kind == .Request && entry.serial == last_serial {
			destination.newest_last_act_step = entry.last_act_step
		}
	}
	destination.changed = true
	destination.layout_serial = 1
	return .None
}

@(private = "file")
persist_validate_entry :: proc "contextless" (data: []u8, cursor: int, last_serial, last_act, last_entry: u64, prev_number: ^u64) -> (next_cursor: int, refusal: Persist_Refusal) {
	if cursor + PERSIST_ENTRY_HEADER_BYTES > len(data) {
		return cursor, .Truncated
	}
	hdr := data[cursor:cursor + PERSIST_ENTRY_HEADER_BYTES]
	kind, kind_ok := enum_word.member_of_word(Entry_Kind, u64(hdr[0]))
	if !kind_ok {
		return cursor, .Bad_Enum
	}
	act_kind_word := hdr[1]
	state_word := hdr[2]
	turn, turn_ok := enum_word.member_of_word(Turn_State, u64(hdr[3]))
	if !turn_ok {
		return cursor, .Bad_Enum
	}
	step := hdr[4]
	step_count := hdr[5]
	last_act_step := hdr[6]
	step_acts := hdr[7]
	end_cause_word := hdr[8]
	flags := hdr[9]
	reserved_1 := byte_order.read_u16_little_endian(hdr, 10)
	acts_counted := int(byte_order.read_u16_little_endian(hdr, 12))
	acts_given := int(byte_order.read_u16_little_endian(hdr, 14))
	number := byte_order.read_u64_little_endian(hdr, 16)
	serial := byte_order.read_u64_little_endian(hdr, 24)
	act := byte_order.read_u64_little_endian(hdr, 32)
	text_len := int(byte_order.read_u16_little_endian(hdr, 40))
	line_len := int(byte_order.read_u16_little_endian(hdr, 42))
	service_len := int(hdr[44])
	export_len := int(hdr[45])
	reserved_2 := byte_order.read_u16_little_endian(hdr, 46)
	err_kind_word := i64(byte_order.read_u64_little_endian(hdr, 48))
	err_unit_word := i64(byte_order.read_u64_little_endian(hdr, 56))

	if reserved_1 != 0 || reserved_2 != 0 || (flags & ~PERSIST_FLAGS_KNOWN_MASK) != 0 {
		return cursor, .Bad_Flags
	}
	if number == 0 || number <= prev_number^ || number > last_entry {
		return cursor, .Bad_Counters
	}
	if serial == 0 || serial > last_serial {
		return cursor, .Bad_Counters
	}
	if step > assistant_contract.AGENT_LOOP_STEP_CAPACITY || step_count > assistant_contract.AGENT_LOOP_STEP_CAPACITY || last_act_step > assistant_contract.AGENT_LOOP_STEP_CAPACITY {
		return cursor, .Bad_Counters
	}
	if int(step_acts) > assistant_contract.MODEL_ACT_CAPACITY || acts_counted > assistant_contract.MODEL_ACT_CAPACITY || acts_given > acts_counted {
		return cursor, .Bad_Counters
	}
	if text_len > assistant_contract.REPLY_TEXT_BYTES || line_len > assistant_contract.ACT_LINE_BYTES || service_len > assistant_contract.ACT_NAME_BYTES || export_len > assistant_contract.ACT_NAME_BYTES {
		return cursor, .Bad_Length
	}
	body_start := cursor + PERSIST_ENTRY_HEADER_BYTES
	body_end := body_start + text_len + line_len + service_len + export_len
	if body_end > len(data) {
		return cursor, .Truncated
	}
	text := string(data[body_start:body_start + text_len])
	line_start := body_start + text_len
	line := string(data[line_start:line_start + line_len])
	service_start := line_start + line_len
	service := string(data[service_start:service_start + service_len])
	export_start := service_start + service_len
	export := string(data[export_start:export_start + export_len])

	switch kind {
	case .Request:
		if act != 0 || act_kind_word != 0 || state_word != 0 || line_len != 0 || service_len != 0 || export_len != 0 {
			return cursor, .Bad_Counters
		}
		if turn == .Ended {
			if _, ok := assistant_contract.agent_loop_end_of_word(i64(end_cause_word)); !ok {
				return cursor, .Bad_Enum
			}
		} else if end_cause_word != 0 {
			return cursor, .Bad_Enum
		}
		if assistant_contract.text_check(text, assistant_contract.REQUEST_TEXT_BYTES) != .None {
			return cursor, .Bad_Text
		}
	case .Reply:
		if act != 0 || act_kind_word != 0 || state_word != 0 || end_cause_word != 0 || line_len != 0 || service_len != 0 || export_len != 0 {
			return cursor, .Bad_Counters
		}
		if step == 0 {
			return cursor, .Bad_Counters
		}
		if assistant_contract.text_check(text, assistant_contract.REPLY_TEXT_BYTES) != .None {
			return cursor, .Bad_Text
		}
	case .Reply_Refused:
		if act != 0 || act_kind_word != 0 || state_word != 0 || end_cause_word != 0 || text_len != 0 || line_len != 0 || service_len != 0 || export_len != 0 {
			return cursor, .Bad_Counters
		}
		err_kind, err_kind_ok := errors.kind_of_word(err_kind_word)
		if !err_kind_ok || err_kind == .None {
			return cursor, .Bad_Enum
		}
		if _, err_unit_ok := errors.unit_of_word(err_unit_word); !err_unit_ok {
			return cursor, .Bad_Enum
		}
	case .Act:
		if act == 0 || act > last_act || end_cause_word != 0 {
			return cursor, .Bad_Counters
		}
		if _, ok := assistant_contract.act_kind_of_word(i64(act_kind_word)); !ok {
			return cursor, .Bad_Enum
		}
		if _, ok := assistant_contract.act_state_of_word(i64(state_word)); !ok {
			return cursor, .Bad_Enum
		}
		if assistant_contract.text_check(line, assistant_contract.ACT_LINE_BYTES) != .None {
			return cursor, .Bad_Text
		}
		if text_len > 0 && assistant_contract.text_check(text, assistant_contract.REPLY_TEXT_BYTES) != .None {
			return cursor, .Bad_Text
		}
		named := service_len > 0 || export_len > 0
		if named && (!assistant_contract.act_name_valid(service) || !assistant_contract.act_name_valid(export)) {
			return cursor, .Bad_Text
		}
	case .Loop_End:
		if act != 0 || act_kind_word != 0 || state_word != 0 || text_len != 0 || line_len != 0 || service_len != 0 || export_len != 0 {
			return cursor, .Bad_Counters
		}
		if _, ok := assistant_contract.agent_loop_end_of_word(i64(end_cause_word)); !ok {
			return cursor, .Bad_Enum
		}
	}

	prev_number^ = number
	return body_end, .None
}

@(private = "file")
persist_read_entry :: proc "contextless" (data: []u8, cursor: int, entry: ^Entry) -> int {
	hdr := data[cursor:cursor + PERSIST_ENTRY_HEADER_BYTES]
	entry.kind, _ = enum_word.member_of_word(Entry_Kind, u64(hdr[0]))
	if entry.kind == .Act {
		entry.act_kind, _ = assistant_contract.act_kind_of_word(i64(hdr[1]))
		entry.state, _ = assistant_contract.act_state_of_word(i64(hdr[2]))
	}
	entry.turn, _ = enum_word.member_of_word(Turn_State, u64(hdr[3]))
	entry.step = hdr[4]
	entry.step_count = hdr[5]
	entry.last_act_step = hdr[6]
	entry.step_acts = hdr[7]
	if hdr[8] != 0 {
		entry.end_cause, _ = assistant_contract.agent_loop_end_of_word(i64(hdr[8]))
	}
	flags := hdr[9]
	entry.taken = (flags & PERSIST_FLAG_TAKEN) != 0
	entry.stop_requested = (flags & PERSIST_FLAG_STOP_REQUESTED) != 0
	entry.expanded = (flags & PERSIST_FLAG_EXPANDED) != 0
	entry.fold_toggled = (flags & PERSIST_FLAG_FOLD_TOGGLED) != 0
	entry.acts_counted = int(byte_order.read_u16_little_endian(hdr, 12))
	entry.acts_given = int(byte_order.read_u16_little_endian(hdr, 14))
	entry.number = byte_order.read_u64_little_endian(hdr, 16)
	entry.serial = byte_order.read_u64_little_endian(hdr, 24)
	entry.act = byte_order.read_u64_little_endian(hdr, 32)
	// Stale trusted-display dialog serials never survive a restart.
	entry.dialog = 0
	entry.revision = 1
	text_len := int(byte_order.read_u16_little_endian(hdr, 40))
	line_len := int(byte_order.read_u16_little_endian(hdr, 42))
	service_len := int(hdr[44])
	export_len := int(hdr[45])
	if entry.kind == .Reply_Refused {
		err_kind, _ := errors.kind_of_word(i64(byte_order.read_u64_little_endian(hdr, 48)))
		err_unit, _ := errors.unit_of_word(i64(byte_order.read_u64_little_endian(hdr, 56)))
		entry.error = errors.error_make(
			err_kind,
			err_unit,
			i64(byte_order.read_u64_little_endian(hdr, 64)),
			i64(byte_order.read_u64_little_endian(hdr, 72)),
			i64(byte_order.read_u64_little_endian(hdr, 80)),
			i64(byte_order.read_u64_little_endian(hdr, 88)),
		)
	}
	pos := cursor + PERSIST_ENTRY_HEADER_BYTES
	if text_len > 0 {
		entry.text_count = copy(entry.text[:], data[pos:pos + text_len])
		pos += text_len
	}
	if line_len > 0 {
		entry.line_count = copy(entry.line[:], data[pos:pos + line_len])
		pos += line_len
	}
	if service_len > 0 {
		entry.service_count = copy(entry.service[:], data[pos:pos + service_len])
		pos += service_len
	}
	if export_len > 0 {
		entry.export_count = copy(entry.export[:], data[pos:pos + export_len])
		pos += export_len
	}
	// Wide grants and single-use consumed-act records never survive a restart,
	// so downgrade any persisted Allowed_By_Principal act to Refused on reload
	// to prevent cross-restart approval replay.
	if entry.kind == .Act && entry.state == .Allowed_By_Principal {
		entry.state = .Refused
		if entry.text_count == 0 {
			entry.text_count = copy(entry.text[:], "approval expired across restart")
		}
	}
	return pos
}
