// Bounded UI <-> worker ring queues and pluggable storage inspection routines
// for store_explorer (src/md/features/store_explorer.md).
package store_explorer_core

import "modus:contract/blake3"

// Plan value: 16 queued interactive requests between UI and worker; full queues
// refuse new requests explicitly (.Queue_Full) without blocking the UI thread.
QUEUE_CAPACITY :: 16

Request_Kind :: enum u8 {
	None            = 0,
	Open_Initial    = 1,
	Select_Store    = 2,
	Enter_Tree      = 3,
	Navigate_Up     = 4,
	Navigate_Depth  = 5,
	Select_Entry    = 6,
	Apply_Filter    = 7,
	Refresh         = 8,
	Create_Object   = 9,
	Create_Tree     = 10,
	Remove_Entry    = 11,
	List_Versions   = 12,
	Preview_Version = 13,
	Restore_Version = 14,
}

Result_Kind :: enum u8 {
	None             = 0,
	Opened           = 1,
	Tree_Loaded      = 2,
	Object_Inspected = 3,
	Filtered         = 4,
	Entry_Changed    = 5,
	Versions_Listed  = 6,
	Version_Previewed = 7,
	Version_Restored = 8,
	Failed           = 9,
}

Worker_Request :: struct {
	kind:       Request_Kind,
	serial:     u64,
	index:      int,
	generation: i64,
	text:       [ENTRY_NAME_MAX_BYTES]u8,
	text_len:   int,
}

Worker_Result :: struct {
	kind:            Result_Kind,
	serial:          u64,
	has_snapshot:    bool, // True only when worker wrote snapshots[snapshot_index] and awaits UI ack.
	snapshot_index:  int,
	problem:         Problem_Kind,
	store_connected: bool,
	read_only:       bool,
}

Ring_Queue :: struct($T: typeid) {
	items: [QUEUE_CAPACITY]T,
	head:  int,
	tail:  int,
	count: int,
}

queue_push :: proc "contextless" (q: ^Ring_Queue($T), item: ^T) -> bool {
	if q.count >= QUEUE_CAPACITY {
		return false
	}
	q.items[q.tail] = item^
	q.tail = (q.tail + 1) % QUEUE_CAPACITY
	q.count += 1
	return true
}

queue_pop :: proc "contextless" (q: ^Ring_Queue($T), out: ^T) -> bool {
	if q.count <= 0 {
		return false
	}
	out^ = q.items[q.head]
	q.head = (q.head + 1) % QUEUE_CAPACITY
	q.count -= 1
	return true
}

// Pluggable object read callback so streaming BLAKE3 hashing and preview
// extraction are 100% host-tested without a kernel.
Read_Range_Proc :: #type proc "contextless" (user_data: rawptr, offset: u64, dst: []u8) -> (read_bytes: []u8, problem: Problem_Kind)

// inspect_object_stream reads an object in chunks, copies up to PREVIEW_MAX_BYTES
// into snap.preview_bytes, streams the entire object through BLAKE3 (with strict
// upper-bound chunk checks), classifies UTF-8 vs binary, and indexes text lines.
inspect_object_stream :: proc "contextless" (
	snap: ^Explorer_Snapshot,
	name: string,
	size: i64,
	generation: i64,
	read_fn: Read_Range_Proc,
	user_data: rawptr,
	chunk_buf: []u8,
) -> Problem_Kind {
	snap.has_object = true
	name_n := min(len(name), ENTRY_NAME_MAX_BYTES)
	copy(snap.object_name[:name_n], name[:name_n])
	snap.object_name_len = u16(name_n)
	snap.object_size = max(size, 0)
	snap.object_generation = generation
	snap.preview_len = 0
	snap.preview_truncated = false
	snap.has_hash = false
	snap.preview_line_count = 0

	if size < 0 || read_fn == nil || len(chunk_buf) == 0 {
		return .Object_Unreadable
	}

	hasher := blake3.hasher_make()

	total := u64(size)
	filled := u64(0)
	for filled < total {
		want := min(u64(len(chunk_buf)), total - filled)
		part, prob := read_fn(user_data, filled, chunk_buf[:want])
		if prob != .None {
			return prob
		}
		if len(part) == 0 || u64(len(part)) > total - filled {
			return .Object_Damaged
		}
		blake3.hasher_update(&hasher, part)
		if snap.preview_len < PREVIEW_MAX_BYTES {
			take := min(len(part), PREVIEW_MAX_BYTES - snap.preview_len)
			copy(snap.preview_bytes[snap.preview_len:][:take], part[:take])
			snap.preview_len += take
		}
		filled += u64(len(part))
	}

	snap.object_hash = blake3.hasher_finish(&hasher)
	snap.has_hash = true
	snap.preview_truncated = u64(snap.preview_len) < total
	// If truncation sliced a multi-byte UTF-8 sequence at PREVIEW_MAX_BYTES,
	// trim the incomplete trailing sequence (at most 3 bytes) for text check.
	check_len := snap.preview_len
	if snap.preview_truncated && check_len > 0 {
		trimmed := 0
		for trimmed < 3 && check_len > 0 && (snap.preview_bytes[check_len - 1] & 0xC0) == 0x80 {
			check_len -= 1
			trimmed += 1
		}
		if check_len > 0 && snap.preview_bytes[check_len - 1] >= 0xC0 {
			check_len -= 1
		}
	}
	snap.preview_is_utf8 = is_preview_text_utf8(snap.preview_bytes[:check_len])
	if snap.preview_is_utf8 {
		snap.preview_len = check_len
		index_preview_lines(snap)
	}
	return .None
}
