package storage

import "modus:contract/errors"
import "modus:contract/storage_status"

// A whole object of any size, in pieces of a call region. A call region
// holds 64 KiB with the name and the record of the call, so a text larger
// than one call goes as ranges: read_range after its size, and write_range
// in pieces with one commit, so the whole object is still one version
// (docs/STORAGE.md, "Ranges"). edit and notes keep their texts so.

// The bytes of one call of read_range or write_range, and the most bytes
// that write_whole sends in one write.
WHOLE_PIECE_BYTES :: 32 * 1024

// The memory that read_whole fills: it gives at least `minimum` bytes, or
// false when the budget of the caller cannot pay them.
Whole_Room :: #type proc "contextless" (data: rawptr, minimum: int) -> (room: []u8, ok: bool)

// Why read_whole gave no bytes.
Whole_Read :: enum u8 {
	Read     = 0, // The bytes came: the whole object.
	Absent   = 1, // The place has no such object.
	Too_Long = 2, // The room of the caller cannot hold the object.
	Refused  = 3, // A call refused: the status says how.
}

// read_whole reads the whole object `name` under a place into the room
// that `room` gives, by its size, then by read_range in pieces. A refused
// read leaves the room with no meaning.
read_whole :: proc "contextless" (client: ^Client, place: Place, name: string, room: Whole_Room, room_data: rawptr, error: ^errors.Error_Record = nil) -> (bytes: []u8, outcome: Whole_Read, status: storage_status.Status) {
	object_size, size_status := size(client, place, name, error)
	if size_status == .Absent {
		return nil, .Absent, .Ok
	}
	if size_status != .Ok {
		return nil, .Refused, size_status
	}
	if object_size < 0 {
		return nil, .Refused, .Refused
	}
	whole, room_ok := room(room_data, int(object_size))
	if !room_ok || len(whole) < int(object_size) {
		return nil, .Too_Long, .Ok
	}
	whole = whole[:object_size]
	offset := 0
	for offset < len(whole) {
		part, part_status := read_range(client, place, name, u64(offset), whole[offset:][:min(WHOLE_PIECE_BYTES, len(whole) - offset)], error)
		if part_status != .Ok {
			return nil, .Refused, part_status
		}
		// No byte before the end: the object changed under the read.
		if len(part) == 0 {
			return nil, .Refused, .Damaged
		}
		offset += len(part)
	}
	return whole, .Read, .Ok
}

// write_whole makes the object `name` under a place the bytes given, in
// one commit: one write when they fit one call, else ranges of this
// connection and their commit. The storage service holds the pending
// changes of the commit for this connection, sized to it.
write_whole :: proc "contextless" (client: ^Client, place: Place, name: string, bytes: []u8, error: ^errors.Error_Record = nil) -> (generation: i64, status: storage_status.Status) {
	if len(bytes) <= WHOLE_PIECE_BYTES {
		return write(client, place, name, bytes, error)
	}
	if status = set_size(client, place, name, u64(len(bytes)), error); status != .Ok {
		return -1, status
	}
	for offset := 0; offset < len(bytes); offset += WHOLE_PIECE_BYTES {
		written, range_status := write_range(client, place, name, u64(offset), bytes[offset:min(offset + WHOLE_PIECE_BYTES, len(bytes))], error)
		if range_status != .Ok || written < 0 {
			return -1, range_status
		}
	}
	measure: Commit_Measure
	measure, status = commit(client, place, name, error)
	return measure.generation, status
}
