// The work of the store of the process notes, as records that the window
// thread and the store thread pass to each other (src/md/features/notes.md,
// "The store thread"). The window thread makes no call of the system for
// the store: it puts a request in a queue, and reads the result later. The
// queues are pure here, with host tests; the module holds their lock and
// their events.
package store_work

import "modus:contract/store"
import "modus:text_model"

NAME_BYTES :: store.ENTRY_NAME_CAPACITY
// The bytes of a result: a text, and one byte more, so that an object
// longer than a text shows as one.
RESULT_BYTES :: text_model.TEXT_CAPACITY + 1
// The requests that wait at most. A full queue refuses a push: the window
// keeps its change waiting and tries again at its next turn.
QUEUE_CAPACITY :: 4

// What the store thread does.
Request_Kind :: enum u8 {
	List     = 0, // Open the store, list the notes and read the first bytes of each.
	Load     = 1, // Read a note.
	Write    = 2, // Write a note in one commit.
	Versions = 3, // List the versions of a note.
	Version  = 4, // Read a version of a note.
	Restore  = 5, // Make a version the current note, in one commit.
	Remove   = 6, // Remove a note and its versions.
}

// What came of a request.
Result_Status :: enum u8 {
	Done       = 0,
	Absent     = 1, // The store has no such note.
	Damaged    = 2, // The store has the note and cannot give its bytes.
	Too_Long   = 3, // The note is longer than a text.
	Refused    = 4, // The storage service refused: the fact of its error record is on the log.
	Unanswered = 5, // The storage service gave no answer: the notes are not kept from now on.
	No_Store   = 6, // The process has no store.
}

Request :: struct {
	kind:       Request_Kind,
	serial:     u64, // Given by the window: a result names its request.
	name:       [NAME_BYTES]u8,
	name_count: int,
	generation: i64, // Version, Restore: the version.
	bytes:      [text_model.TEXT_CAPACITY]u8, // Write: the text.
	byte_count: int,
}

Result :: struct {
	kind:       Request_Kind,
	serial:     u64,
	status:     Result_Status,
	name:       [NAME_BYTES]u8,
	name_count: int,
	generation: i64, // Write, Restore, Remove: the commit; Version: the version read.
	bytes:      [RESULT_BYTES]u8, // Load, Version: the bytes; Versions: the rows of the versions.
	byte_count: int,
}

// A queue of records, the oldest first. The zero value is empty.
Queue :: struct($T: typeid) {
	items: [QUEUE_CAPACITY]T,
	first: int,
	count: int,
}

// queue_push copies a record to the end of a queue. false: the queue is
// full, and nothing changed.
queue_push :: proc "contextless" (queue: ^Queue($T), item: ^T) -> bool {
	if queue.count < 0 || queue.count >= QUEUE_CAPACITY || queue.first < 0 || queue.first >= QUEUE_CAPACITY {
		return false
	}
	queue.items[(queue.first + queue.count) % QUEUE_CAPACITY] = item^
	queue.count += 1
	return true
}

// queue_pop copies the oldest record of a queue into item, and removes it.
// false: the queue is empty, and item did not change.
queue_pop :: proc "contextless" (queue: ^Queue($T), item: ^T) -> bool {
	if queue.count <= 0 || queue.count > QUEUE_CAPACITY || queue.first < 0 || queue.first >= QUEUE_CAPACITY {
		return false
	}
	item^ = queue.items[queue.first]
	queue.first = (queue.first + 1) % QUEUE_CAPACITY
	queue.count -= 1
	return true
}

// queue_full says if a push would be refused.
queue_full :: proc "contextless" (queue: ^Queue($T)) -> bool {
	return queue.count >= QUEUE_CAPACITY
}

// name_set writes a name of an object into a record. false: the name is
// empty or longer than NAME_BYTES, and nothing changed.
name_set :: proc "contextless" (name: string, into: ^[NAME_BYTES]u8, count: ^int) -> bool {
	if len(name) == 0 || len(name) > NAME_BYTES {
		return false
	}
	count^ = copy(into[:], name)
	return true
}

// bytes_set writes the bytes of a text into a request. false: they are
// longer than a text, and nothing changed.
bytes_set :: proc "contextless" (request: ^Request, bytes: []u8) -> bool {
	if len(bytes) > len(request.bytes) {
		return false
	}
	request.byte_count = copy(request.bytes[:], bytes)
	return true
}
