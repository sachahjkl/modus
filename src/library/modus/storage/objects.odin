// Client helpers for read-only object mapping (map_object) and durable pin
// management (pin_object, unpin_object, list_pins) on the storage service
// (src/md/features/objects_by_hash.md).
package storage

import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/storage_object"
import "modus:contract/storage_status"
import store_contract "modus:contract/store"
import "modus:system"

// Format property: exact maximum byte length of a Map_Object_Request buffer
// (60-byte header + OBJECT_PATH_LIMIT bytes).
MAP_REQUEST_MAX_BYTES :: storage_object.MAP_OBJECT_REQUEST_HEADER_SIZE + store_contract.OBJECT_PATH_LIMIT

// Format property: maximum wire bytes for List_Pins_Answer
// (24-byte header + LIST_PINS_LIMIT * 48-byte pin records).
LIST_PINS_MAX_BYTES :: storage_object.LIST_PINS_HEADER_SIZE + storage_object.LIST_PINS_LIMIT * storage_object.PIN_RECORD_SIZE

// One read-only object mapped into this process's address space by map_object.
// Close with mapped_object_close when done.
Mapped_Object :: struct {
	handle: system.Handle,
	bytes:  []u8,
	hash:   blake3.Hash,
	size:   u64,
}

// mapped_object_close unmaps mapped.bytes and closes mapped.handle.
mapped_object_close :: proc "contextless" (mapped: ^Mapped_Object) {
	if mapped == nil {
		return
	}
	if raw_data(mapped.bytes) != nil {
		system.memory_unmap(raw_data(mapped.bytes))
	}
	if mapped.handle != 0 {
		system.close(mapped.handle)
	}
	mapped^ = {}
}

// map_object maps the read-only object at exact '/' path across the caller's
// granted read-only trees in storage.
map_object :: proc "contextless" (
	client: ^Client,
	path: string,
	error: ^errors.Error_Record = nil,
) -> (
	mapped: Mapped_Object,
	answer: storage_object.Map_Object_Answer,
	status: storage_status.Status,
	outcome: call_outcome.Call_Outcome,
) {
	mapped, answer, _, status, outcome = map_object_with_matches(client, path, false, {}, nil, nil, error)
	return
}

// map_object_pinned maps the read-only object at exact '/' path only when its
// intact content hash equals expected_hash. On mismatch, returns Failed with
// outcome Another_Change_Came_First and answer.result == .Hash_Mismatch.
map_object_pinned :: proc "contextless" (
	client: ^Client,
	path: string,
	expected_hash: blake3.Hash,
	error: ^errors.Error_Record = nil,
) -> (
	mapped: Mapped_Object,
	answer: storage_object.Map_Object_Answer,
	status: storage_status.Status,
	outcome: call_outcome.Call_Outcome,
) {
	mapped, answer, _, status, outcome = map_object_with_matches(client, path, true, expected_hash, nil, nil, error)
	return
}

// map_object_handle_of_word validates the integer handle returned by
// map_object at the transport border before converting it to system.Handle.
map_object_handle_of_word :: proc "contextless" (word: i64) -> (handle: system.Handle, ok: bool) {
	if word <= 0 || word > i64(max(u32)) {
		return 0, false
	}
	return system.Handle(word), true
}

// map_object_with_matches maps the read-only object at path and, on ambiguity,
// decodes matching tree records from ambiguity_buf into matches_out (whose
// strings borrow from ambiguity_buf).
map_object_with_matches :: proc "contextless" (
	client: ^Client,
	path: string,
	has_expected_hash: bool,
	expected_hash: blake3.Hash,
	ambiguity_buf: []u8,
	matches_out: []storage_object.Ambiguity_Entry,
	error: ^errors.Error_Record = nil,
) -> (
	mapped: Mapped_Object,
	answer: storage_object.Map_Object_Answer,
	matches_written: int,
	status: storage_status.Status,
	outcome: call_outcome.Call_Outcome,
) {
	req_buf: [MAP_REQUEST_MAX_BYTES]u8
	amb_cap := u32(min(len(matches_out), storage_object.AMBIGUITY_RECORD_LIMIT))
	req := storage_object.Map_Object_Request {
		path               = path,
		has_expected_hash  = has_expected_hash,
		expected_hash      = has_expected_hash ? expected_hash : {},
		ambiguity_capacity = len(ambiguity_buf) >= storage_object.AMBIGUITY_TABLE_HEADER_SIZE ? amb_cap : 0,
	}
	req_len, enc_problem := storage_object.map_object_request_encode(req, req_buf[:])
	if enc_problem != .None {
		return {}, {result = .Path_Refused}, 0, .Refused, .Argument_Refused
	}

	ans_buf: [storage_object.MAP_OBJECT_ANSWER_SIZE]u8
	arguments := [3]isolated.Argument {
		{table = {records = req_buf[:req_len], count = u64(req_len)}},
		{table = {records = ans_buf[:], count = 0}},
		{table = {records = ambiguity_buf, count = 0}},
	}

	handle_word: i64
	handle_word, _, status, outcome = call(client, "map_object", arguments[:], error)

	answer_decoded := false
	ans_count := min(int(arguments[1].table.count), len(ans_buf))
	if ans_count > 0 {
		decoded_ans, dec_prob := storage_object.map_object_answer_decode(ans_buf[:ans_count])
		if dec_prob == .None {
			answer = decoded_ans
			answer_decoded = true
		}
	}

	if answer_decoded && answer.result == .Ambiguous && len(ambiguity_buf) > 0 && arguments[2].table.count > 0 {
		amb_count := min(int(arguments[2].table.count), len(ambiguity_buf))
		_, _, written, amb_prob := storage_object.ambiguity_table_decode(ambiguity_buf[:amb_count], matches_out)
		if amb_prob == .None {
			matches_written = written
		}
	}

	handle, handle_ok := map_object_handle_of_word(handle_word)
	if status != .Ok {
		// If storage succeeded and granted a handle before client-side table
		// return failed, close that handle so it does not leak.
		if outcome == .Succeeded && handle_ok {
			system.close(handle)
		}
		if !answer_decoded {
			answer.result = .Unavailable
		}
		return {}, answer, matches_written, status, outcome
	}
	if !handle_ok || !answer_decoded || answer.result != .Mapped {
		if handle_ok {
			system.close(handle)
		}
		if !answer_decoded {
			answer.result = .Unavailable
		}
		return {}, answer, 0, .Refused, .Answer_Unreadable
	}
	pages, size_status := system.memory_size(handle)
	if size_status != .Succeeded || answer.size > pages * system.PAGE_SIZE {
		system.close(handle)
		return {}, answer, 0, .Refused, .Answer_Unreadable
	}
	addr, map_status := system.memory_map(handle, {})
	if map_status != .Succeeded || addr == nil {
		system.close(handle)
		return {}, answer, 0, .Refused, map_status
	}
	return Mapped_Object {
		handle = handle,
		bytes  = ([^]u8)(addr)[:answer.size],
		hash   = answer.hash,
		size   = answer.size,
	}, answer, 0, .Ok, .Succeeded
}

// pin_object adds one durable pin on (store_index, hash) for the caller's
// principal so collect_garbage and erase_versions cannot reclaim it.
pin_object :: proc "contextless" (
	client: ^Client,
	store_index: u32,
	hash: blake3.Hash,
	error: ^errors.Error_Record = nil,
) -> (
	pin_count: u32,
	status: storage_status.Status,
	outcome: call_outcome.Call_Outcome,
) {
	req_buf: [storage_object.PIN_REQUEST_SIZE]u8
	req_len, enc_problem := storage_object.pin_request_encode({store_index = store_index, hash = hash}, req_buf[:])
	if enc_problem != .None {
		return 0, .Refused, .Argument_Refused
	}
	arguments := [1]isolated.Argument{{table = {records = req_buf[:req_len], count = u64(req_len)}}}
	value: i64
	value, _, status, outcome = call(client, "pin_object", arguments[:], error)
	if status != .Ok {
		return 0, status, outcome
	}
	return u32(value), .Ok, .Succeeded
}

// unpin_object decrements one durable pin on (store_index, hash) for the
// caller's principal.
unpin_object :: proc "contextless" (
	client: ^Client,
	store_index: u32,
	hash: blake3.Hash,
	error: ^errors.Error_Record = nil,
) -> (
	remaining: u32,
	status: storage_status.Status,
	outcome: call_outcome.Call_Outcome,
) {
	req_buf: [storage_object.UNPIN_REQUEST_SIZE]u8
	req_len, enc_problem := storage_object.unpin_request_encode({store_index = store_index, hash = hash}, req_buf[:])
	if enc_problem != .None {
		return 0, .Refused, .Argument_Refused
	}
	arguments := [1]isolated.Argument{{table = {records = req_buf[:req_len], count = u64(req_len)}}}
	value: i64
	value, _, status, outcome = call(client, "unpin_object", arguments[:], error)
	if status != .Ok {
		return 0, status, outcome
	}
	return u32(value), .Ok, .Succeeded
}

// list_pins lists active durable pins visible to the caller using scratch as
// the call-region decode buffer (pass a buffer of at least
// storage_object.list_pins_answer_encoded_size(len(out)) bytes).
list_pins :: proc "contextless" (
	client: ^Client,
	scratch: []u8,
	out: []storage_object.Pin_Record,
	error: ^errors.Error_Record = nil,
) -> (
	total_pins: u32,
	written: int,
	status: storage_status.Status,
	outcome: call_outcome.Call_Outcome,
) {
	arguments := [1]isolated.Argument{{table = {records = scratch, count = 0}}}
	_, _, status, outcome = call(client, "list_pins", arguments[:], error)
	if status != .Ok {
		return 0, 0, status, outcome
	}
	count := min(int(arguments[0].table.count), len(scratch))
	total, _, decoded, dec_problem := storage_object.list_pins_answer_decode(scratch[:count], out)
	if dec_problem != .None {
		return 0, 0, .Refused, .Answer_Unreadable
	}
	return total, decoded, .Ok, .Succeeded
}
