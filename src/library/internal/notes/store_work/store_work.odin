// The work of the store of the process notes, as records that the window
// thread and the store thread pass to each other (src/md/features/notes.md,
// "The store thread"). The window thread makes no call of the system for
// the store: it puts a request in a queue, and reads the result later. The
// queues are pure here, with host tests; the module holds their lock and
// their events.
package store_work

import "base:intrinsics"
import "modus:contract/store"

// The bytes of a note go between the two threads in memory that each
// thread owns in turn, never in the records of the queues, so a note has
// the size that the budget pays (src/md/features/notes.md, "The store
// thread"):
//
// - the write memory: the window thread writes the text of a Write in it,
//   and puts the request; it writes nothing more in it until the result of
//   that Write came back (Write_Gate). One Write is in flight at a time.
// - the read memory: the store thread writes the bytes of a Load or a
//   Version, or the rows of Versions, in it, and holds it (Read_Hold) until
//   the window thread took the result that names them and released it.

NAME_BYTES :: store.ENTRY_NAME_CAPACITY
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
	byte_count: int, // Write: the bytes of the text in the write memory. Version: the bytes of the version, from its row.
}

Result :: struct {
	kind:       Request_Kind,
	serial:     u64,
	status:     Result_Status,
	name:       [NAME_BYTES]u8,
	name_count: int,
	generation: i64, // Write, Restore, Remove: the commit; Version: the version read.
	byte_count: int, // Load, Version: the bytes in the read memory; Versions: the bytes of the rows there. Too_Long: the bytes of the note.
	holds_read: bool, // The read memory holds the bytes of this result: the window releases it after it took them.
}

// Write_Gate: the one Write in flight. The window thread alone uses it.
Write_Gate :: struct {
	in_flight: bool,
}

// write_gate_take says if the window can write the write memory and put a
// Write: no Write is in flight. It then marks one in flight.
write_gate_take :: proc "contextless" (gate: ^Write_Gate) -> bool {
	if gate.in_flight {
		return false
	}
	gate.in_flight = true
	return true
}

// write_gate_done ends the Write in flight: its result came back.
write_gate_done :: proc "contextless" (gate: ^Write_Gate) {
	gate.in_flight = false
}

// Read_Hold: who owns the read memory. 0: the store thread may write it;
// 1: a result that names it waits for the window thread. The two threads
// read and write the word; the module wakes the store thread with an
// event after a release.
Read_Hold :: struct {
	held: u32,
}

// read_hold_free says if the store thread may write the read memory now.
read_hold_free :: proc "contextless" (hold: ^Read_Hold) -> bool {
	return intrinsics.atomic_load_explicit(&hold.held, .Acquire) == 0
}

// read_hold_set marks the read memory held by the result that the store
// thread puts next.
read_hold_set :: proc "contextless" (hold: ^Read_Hold) {
	intrinsics.atomic_store_explicit(&hold.held, 1, .Release)
}

// read_hold_release gives the read memory back to the store thread: the
// window thread took the bytes of the result that held it.
read_hold_release :: proc "contextless" (hold: ^Read_Hold) {
	intrinsics.atomic_store_explicit(&hold.held, 0, .Release)
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


