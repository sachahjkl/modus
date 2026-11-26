#+build !freestanding
package storage_object

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/call_outcome"
import "modus:contract/errors"

@(private = "file")
sample_hash :: proc(seed: u8) -> blake3.Hash {
	data := [4]u8{seed, seed ~ 0x5A, seed + 1, seed + 7}
	return blake3.hash(data[:])
}

// Single-border enum decoders refuse every out-of-range word and accept every
// defined member.
@(test)
enum_borders_refuse_unknown_words :: proc(t: ^testing.T) {
	for member in Wire_Kind {
		got, ok := wire_kind_of_word(u64(member))
		testing.expect(t, ok && got == member)
	}
	for bad in ([?]u64{0, 7, 255, max(u64)}) {
		_, ok := wire_kind_of_word(bad)
		testing.expect(t, !ok)
	}

	for member in Map_Object_Result {
		got, ok := map_object_result_of_word(u64(member))
		testing.expect(t, ok && got == member)
		outcome, kind := map_object_result_outcome(member)
		testing.expect(t, kind in call_outcome.KINDS_OF[outcome])
	}
	for bad in ([?]u64{8, 99, max(u64)}) {
		_, ok := map_object_result_of_word(bad)
		testing.expect(t, !ok)
	}

	// Hash_Mismatch maps to Another_Change_Came_First, never Data_Damaged.
	hm_outcome, _ := map_object_result_outcome(.Hash_Mismatch)
	testing.expect_value(t, hm_outcome, call_outcome.Call_Outcome.Another_Change_Came_First)
	dmg_outcome, dmg_kind := map_object_result_outcome(.Damaged)
	testing.expect_value(t, dmg_outcome, call_outcome.Call_Outcome.Data_Damaged)
	testing.expect_value(t, dmg_kind, errors.Kind.Damaged)

	for member in Wire_Problem {
		got, ok := wire_problem_of_word(u64(member))
		testing.expect(t, ok && got == member)
	}
	_, bad_wp := wire_problem_of_word(99)
	testing.expect(t, !bad_wp)
}

// Map_Object_Request round-trips cleanly and refuses every adversarial mutation:
// bad magic, bad version, wrong kind, non-zero reserved bytes, unknown flags,
// non-zero hash without Has_Expected_Hash, invalid paths, truncation, trailing bytes.
@(test)
map_object_request_roundtrip_and_refusals :: proc(t: ^testing.T) {
	req := Map_Object_Request {
		path               = "pointer_themes/posy",
		has_expected_hash  = true,
		expected_hash      = sample_hash(1),
		ambiguity_capacity = 8,
	}
	buf: [256]u8
	n, prob := map_object_request_encode(req, buf[:])
	testing.expect_value(t, prob, Wire_Problem.None)
	testing.expect_value(t, n, map_object_request_encoded_size(req.path))

	decoded, dprob := map_object_request_decode(buf[:n])
	testing.expect_value(t, dprob, Wire_Problem.None)
	testing.expect_value(t, decoded.path, req.path)
	testing.expect_value(t, decoded.has_expected_hash, true)
	testing.expect_value(t, decoded.expected_hash, req.expected_hash)
	testing.expect_value(t, decoded.ambiguity_capacity, u32(8))

	// Truncation at every prefix length from 0 ..< n is refused.
	for cut in 0 ..< n {
		_, cprob := map_object_request_decode(buf[:cut])
		testing.expect_value(t, cprob, Wire_Problem.Truncated)
	}

	// Trailing garbage byte is refused.
	buf[n] = 0
	_, tprob := map_object_request_decode(buf[:n + 1])
	testing.expect_value(t, tprob, Wire_Problem.Trailing_Bytes)

	// Bad magic, bad version, bad kind, non-zero envelope reserved, non-zero header reserved.
	mut: [256]u8
	copy(mut[:n], buf[:n])
	mut[0] = 'X'
	_, p := map_object_request_decode(mut[:n])
	testing.expect_value(t, p, Wire_Problem.Bad_Magic)

	copy(mut[:n], buf[:n])
	byte_order.write_u16_little_endian(mut[:], 6, 2)
	_, p = map_object_request_decode(mut[:n])
	testing.expect_value(t, p, Wire_Problem.Bad_Version)

	copy(mut[:n], buf[:n])
	mut[8] = u8(Wire_Kind.Pin_Request)
	_, p = map_object_request_decode(mut[:n])
	testing.expect_value(t, p, Wire_Problem.Bad_Kind)

	copy(mut[:n], buf[:n])
	mut[9] = 1
	_, p = map_object_request_decode(mut[:n])
	testing.expect_value(t, p, Wire_Problem.Non_Zero_Reserved)

	copy(mut[:n], buf[:n])
	byte_order.write_u16_little_endian(mut[:], 10, 1)
	_, p = map_object_request_decode(mut[:n])
	testing.expect_value(t, p, Wire_Problem.Non_Zero_Reserved)

	copy(mut[:n], buf[:n])
	byte_order.write_u32_little_endian(mut[:], 24, 1)
	_, p = map_object_request_decode(mut[:n])
	testing.expect_value(t, p, Wire_Problem.Non_Zero_Reserved)

	// Unknown flag bit refused.
	copy(mut[:n], buf[:n])
	byte_order.write_u32_little_endian(mut[:], 12, 0x02)
	_, p = map_object_request_decode(mut[:n])
	testing.expect_value(t, p, Wire_Problem.Bad_Flags)

	// Unset Has_Expected_Hash with non-zero hash bytes refused (both encode & decode).
	copy(mut[:n], buf[:n])
	byte_order.write_u32_little_endian(mut[:], 12, 0)
	_, p = map_object_request_decode(mut[:n])
	testing.expect_value(t, p, Wire_Problem.Invalid_State)

	bad_req := req
	bad_req.has_expected_hash = false
	_, ep := map_object_request_encode(bad_req, buf[:])
	testing.expect_value(t, ep, Wire_Problem.Invalid_State)

	// Invalid paths and ambiguity_capacity past bound refused on encode.
	for bad_path in ([?]string{"", "/a", "a/", "a//b", "../etc", "a/./b"}) {
		_, bp := map_object_request_encode({path = bad_path}, buf[:])
		testing.expect_value(t, bp, Wire_Problem.Invalid_Path)
	}
	_, cap_p := map_object_request_encode({path = "fonts/a", ambiguity_capacity = AMBIGUITY_RECORD_LIMIT + 1}, buf[:])
	testing.expect_value(t, cap_p, Wire_Problem.Count_Exceeds_Limit)

	// Buffer too small leaves output untouched.
	small := [16]u8{0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA}
	_, sp := map_object_request_encode({path = "fonts/a"}, small[:])
	testing.expect_value(t, sp, Wire_Problem.Buffer_Too_Small)
	testing.expect_value(t, small[0], u8(0xAA))
}

// Map_Object_Answer enforces strict state invariants per Map_Object_Result.
@(test)
map_object_answer_roundtrip_and_refusals :: proc(t: ^testing.T) {
	buf: [128]u8

	// Mapped answer.
	mapped := Map_Object_Answer {
		result = .Mapped,
		size   = 123456,
		hash   = sample_hash(3),
	}
	n, p := map_object_answer_encode(mapped, buf[:])
	testing.expect(t, p == .None && n == MAP_OBJECT_ANSWER_SIZE)
	dec, dp := map_object_answer_decode(buf[:n])
	testing.expect_value(t, dp, Wire_Problem.None)
	testing.expect_value(t, dec, mapped)

	// Ambiguous answer requires ambiguity_total >= 2 and zero size/hash.
	amb := Map_Object_Answer{result = .Ambiguous, ambiguity_total = 3}
	n, p = map_object_answer_encode(amb, buf[:])
	testing.expect_value(t, p, Wire_Problem.None)
	dec, dp = map_object_answer_decode(buf[:n])
	testing.expect(t, dp == .None && dec == amb)

	_, bad_amb := map_object_answer_encode({result = .Ambiguous, ambiguity_total = 1}, buf[:])
	testing.expect_value(t, bad_amb, Wire_Problem.Invalid_State)

	// Path_Refused requires non-None path_problem.
	pr := Map_Object_Answer{result = .Path_Refused, path_problem = .Dot_Segment}
	n, p = map_object_answer_encode(pr, buf[:])
	testing.expect_value(t, p, Wire_Problem.None)
	dec, dp = map_object_answer_decode(buf[:n])
	testing.expect(t, dp == .None && dec == pr)

	_, bad_pr := map_object_answer_encode({result = .Path_Refused, path_problem = .None}, buf[:])
	testing.expect_value(t, bad_pr, Wire_Problem.Invalid_State)

	// Unknown result byte, unknown path_problem byte, non-zero reserved, trailing byte.
	mut: [128]u8
	copy(mut[:MAP_OBJECT_ANSWER_SIZE], buf[:MAP_OBJECT_ANSWER_SIZE])
	mut[12] = 99
	_, dp = map_object_answer_decode(mut[:MAP_OBJECT_ANSWER_SIZE])
	testing.expect_value(t, dp, Wire_Problem.Bad_Enum)

	copy(mut[:MAP_OBJECT_ANSWER_SIZE], buf[:MAP_OBJECT_ANSWER_SIZE])
	mut[13] = 99
	_, dp = map_object_answer_decode(mut[:MAP_OBJECT_ANSWER_SIZE])
	testing.expect_value(t, dp, Wire_Problem.Bad_Enum)

	copy(mut[:MAP_OBJECT_ANSWER_SIZE], buf[:MAP_OBJECT_ANSWER_SIZE])
	byte_order.write_u16_little_endian(mut[:], 14, 1)
	_, dp = map_object_answer_decode(mut[:MAP_OBJECT_ANSWER_SIZE])
	testing.expect_value(t, dp, Wire_Problem.Non_Zero_Reserved)

	copy(mut[:MAP_OBJECT_ANSWER_SIZE], buf[:MAP_OBJECT_ANSWER_SIZE])
	byte_order.write_u32_little_endian(mut[:], 20, 1)
	_, dp = map_object_answer_decode(mut[:MAP_OBJECT_ANSWER_SIZE])
	testing.expect_value(t, dp, Wire_Problem.Non_Zero_Reserved)

	_, dp = map_object_answer_decode(buf[:MAP_OBJECT_ANSWER_SIZE - 1])
	testing.expect_value(t, dp, Wire_Problem.Truncated)
	_, dp = map_object_answer_decode(buf[:MAP_OBJECT_ANSWER_SIZE + 1])
	testing.expect_value(t, dp, Wire_Problem.Trailing_Bytes)
}

// Ambiguity table encodes/decodes variable-length tree names and paths cleanly
// within the call region, supports caller-bounded decoding, and refuses corrupt
// records without mutating out.
@(test)
ambiguity_table_roundtrip_and_refusals :: proc(t: ^testing.T) {
	entries := [?]Ambiguity_Entry {
		{grant_index = 0, tree_name = "system_themes", path = "default", size = 4096, hash = sample_hash(10)},
		{grant_index = 2, tree_name = "principal_themes", path = "default", size = 8192, hash = sample_hash(11)},
	}
	buf: [512]u8
	n, p := ambiguity_table_encode(3, entries[:], buf[:])
	testing.expect_value(t, p, Wire_Problem.None)
	testing.expect_value(t, n, ambiguity_table_encoded_size(entries[:]))

	out: [4]Ambiguity_Entry
	total, count, written, dp := ambiguity_table_decode(buf[:n], out[:])
	testing.expect_value(t, dp, Wire_Problem.None)
	testing.expect_value(t, total, u32(3))
	testing.expect_value(t, count, 2)
	testing.expect_value(t, written, 2)
	testing.expect_value(t, out[0].tree_name, "system_themes")
	testing.expect_value(t, out[0].path, "default")
	testing.expect_value(t, out[0].hash, entries[0].hash)
	testing.expect_value(t, out[1].grant_index, u32(2))
	testing.expect_value(t, out[1].tree_name, "principal_themes")
	testing.expect_value(t, out[1].size, u64(8192))

	// Smaller output slice still validates entire wire buffer and reports true counts.
	small_out: [1]Ambiguity_Entry
	total, count, written, dp = ambiguity_table_decode(buf[:n], small_out[:])
	testing.expect(t, dp == .None && total == 3 && count == 2 && written == 1)

	// Truncation at every byte refuses and leaves sentinel out untouched.
	sentinel := [1]Ambiguity_Entry{{grant_index = 777}}
	for cut in 0 ..< n {
		_, _, _, cp := ambiguity_table_decode(buf[:cut], sentinel[:])
		testing.expect_value(t, cp, Wire_Problem.Truncated)
		testing.expect_value(t, sentinel[0].grant_index, u32(777))
	}

	// Trailing byte refused.
	_, _, _, tp := ambiguity_table_decode(buf[:n + 1], sentinel[:])
	testing.expect_value(t, tp, Wire_Problem.Trailing_Bytes)

	// Invalid tree_name (contains '/') or invalid path ('..') refused.
	bad_tree := [1]Ambiguity_Entry{{grant_index = 0, tree_name = "bad/name", path = "a", size = 1, hash = sample_hash(1)}}
	_, ep := ambiguity_table_encode(2, bad_tree[:], buf[:])
	testing.expect_value(t, ep, Wire_Problem.Invalid_Text)

	bad_path := [1]Ambiguity_Entry{{grant_index = 0, tree_name = "ok", path = "../a", size = 1, hash = sample_hash(1)}}
	_, ep = ambiguity_table_encode(2, bad_path[:], buf[:])
	testing.expect_value(t, ep, Wire_Problem.Invalid_Path)

	// total_matches < 2 with non-empty entries refused.
	_, ep = ambiguity_table_encode(1, entries[:1], buf[:])
	testing.expect_value(t, ep, Wire_Problem.Invalid_State)
}

// Pin_Request, Unpin_Request, and List_Pins_Answer round-trip and refuse
// cross-kind confusion, non-zero reserved/flags, zero pin_count, truncation,
// and trailing bytes.
@(test)
pin_and_list_pins_roundtrip_and_refusals :: proc(t: ^testing.T) {
	req := Pin_Request{store_index = 19, hash = sample_hash(22)}
	pbuf: [64]u8
	ubuf: [64]u8

	pn, pp := pin_request_encode(req, pbuf[:])
	testing.expect(t, pp == .None && pn == PIN_REQUEST_SIZE)
	un, up := unpin_request_encode(req, ubuf[:])
	testing.expect(t, up == .None && un == UNPIN_REQUEST_SIZE)

	pdec, pdp := pin_request_decode(pbuf[:pn])
	testing.expect(t, pdp == .None && pdec == req)
	udec, udp := unpin_request_decode(ubuf[:un])
	testing.expect(t, udp == .None && udec == req)

	// Cross-kind decode refused.
	_, cross1 := pin_request_decode(ubuf[:un])
	testing.expect_value(t, cross1, Wire_Problem.Bad_Kind)
	_, cross2 := unpin_request_decode(pbuf[:pn])
	testing.expect_value(t, cross2, Wire_Problem.Bad_Kind)

	// Non-zero flags, non-zero reserved, truncated, trailing.
	mut := pbuf
	byte_order.write_u32_little_endian(mut[:], 12, 1)
	_, mp := pin_request_decode(mut[:pn])
	testing.expect_value(t, mp, Wire_Problem.Bad_Flags)

	mut = pbuf
	byte_order.write_u32_little_endian(mut[:], 20, 1)
	_, mp = pin_request_decode(mut[:pn])
	testing.expect_value(t, mp, Wire_Problem.Non_Zero_Reserved)

	_, mp = pin_request_decode(pbuf[:pn - 1])
	testing.expect_value(t, mp, Wire_Problem.Truncated)
	_, mp = pin_request_decode(pbuf[:pn + 1])
	testing.expect_value(t, mp, Wire_Problem.Trailing_Bytes)

	// List_Pins_Answer round-trip and refusals.
	records := [?]Pin_Record {
		{principal_id = 1, store_index = 4, pin_count = 3, hash = sample_hash(30)},
		{principal_id = 2, store_index = 9, pin_count = 1, hash = sample_hash(31)},
	}
	lbuf: [256]u8
	ln, lp := list_pins_answer_encode(5, records[:], lbuf[:])
	testing.expect_value(t, lp, Wire_Problem.None)
	testing.expect_value(t, ln, list_pins_answer_encoded_size(len(records)))

	out: [4]Pin_Record
	total, count, written, ldp := list_pins_answer_decode(lbuf[:ln], out[:])
	testing.expect_value(t, ldp, Wire_Problem.None)
	testing.expect_value(t, total, u32(5))
	testing.expect_value(t, count, 2)
	testing.expect_value(t, written, 2)
	testing.expect_value(t, out[0], records[0])
	testing.expect_value(t, out[1], records[1])

	// Zero pin_count refused on encode AND decode.
	bad_rec := [1]Pin_Record{{principal_id = 1, store_index = 4, pin_count = 0, hash = sample_hash(32)}}
	_, bp := list_pins_answer_encode(1, bad_rec[:], lbuf[:])
	testing.expect_value(t, bp, Wire_Problem.Invalid_State)

	corrupt := lbuf
	byte_order.write_u32_little_endian(corrupt[:], LIST_PINS_HEADER_SIZE + PIN_RECORD_SIZE + 12, 0)
	sentinel := [1]Pin_Record{{principal_id = 999}}
	_, _, _, cp := list_pins_answer_decode(corrupt[:ln], sentinel[:])
	testing.expect_value(t, cp, Wire_Problem.Invalid_State)
	testing.expect_value(t, sentinel[0].principal_id, u64(999)) // untouched on refusal

	// total_pins < record_count refused.
	corrupt = lbuf
	byte_order.write_u32_little_endian(corrupt[:], 12, 1)
	_, _, _, cp = list_pins_answer_decode(corrupt[:ln], sentinel[:])
	testing.expect_value(t, cp, Wire_Problem.Invalid_State)

	// Count past LIST_PINS_LIMIT refused.
	corrupt = lbuf
	byte_order.write_u32_little_endian(corrupt[:], 12, LIST_PINS_LIMIT + 1)
	byte_order.write_u32_little_endian(corrupt[:], 16, LIST_PINS_LIMIT + 1)
	_, _, _, cp = list_pins_answer_decode(corrupt[:ln], sentinel[:])
	testing.expect_value(t, cp, Wire_Problem.Count_Exceeds_Limit)

	// Truncated and trailing refused.
	_, _, _, cp = list_pins_answer_decode(lbuf[:ln - 1], sentinel[:])
	testing.expect_value(t, cp, Wire_Problem.Truncated)
	_, _, _, cp = list_pins_answer_decode(lbuf[:ln + 1], sentinel[:])
	testing.expect_value(t, cp, Wire_Problem.Trailing_Bytes)
}
