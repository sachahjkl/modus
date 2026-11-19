package system

// The library of the record outputs and the record inputs
// (src/md/features/module_outputs.md, "Fan-out and flow control" and "The
// end of a stream"): the ends that a process takes from its wiring ring,
// and the calls output_write, output_end, input_read and asker_read.
//
// The ends of a process are in one table of this package, of the size of
// the ends that the root service gives one process at most: an end past it
// is refused in the completion. A variable of a declaration finds its ends
// by the index that the loader wrote in it. The table and the wiring ring
// are state of the whole process, so the calls of this file run in one
// thread at a time: a process that calls them from several threads holds
// its own lock around each call. Each queue then has one writer and one
// reader.

import "base:intrinsics"
import "modus:contract/errors"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/output"
import "modus:contract/ring"

// The ends of one process at one time: the root service gives no more
// (ENDS_OF_A_PROCESS_MOST in the root service).
STREAM_END_CAPACITY :: 16

// One end that the process holds. Free when command is None.
@(private = "file")
Stream_End :: struct {
	command:            output.Wiring_Command,
	tag:                u32, // The number of the wiring.
	index:              u32, // The record output or the record input; 0 for the asker.
	pace:               output.Wiring_Pace,
	ring_memory:        Handle,
	ring_address:       rawptr,
	ring_pages:         u64,
	queue:              ring.Compartment_Ring, // Opened at the first use, when the size of the record is known.
	opened:             bool,
	end_memory:         Handle,
	end_words:          ^output.End_Words, // Mapped with Read only.
	description_memory: Handle,
	description_file:   []u8, // Mapped with Read only: the reader checks each record against it.
	description:        module.Record,
	terms_memory:       Handle,
	read_state:         output.Read_State, // A reader: what its border knows of the ring.
	joined:             bool, // A writer: it wrote the joined record.
	gap_count:          u32, // A writer: the records that this ring refused since its last gap record.
	gap_first:          u32, // A writer: the serial of the first of them.
}

@(private = "file")
stream_ends: [STREAM_END_CAPACITY]Stream_End

// The wiring ring of the process: the handle 16 of its context, or the ring
// that the root service gave an asker with its list page.
@(private = "file")
wiring_ring: ring.Ring
@(private = "file")
wiring_ring_memory: Handle

// The compartments in the private memory of the process: the writer builds
// each one in its buffer before its push, and the reader copies each one
// into its own before its border, which then reads only that copy.
@(private = "file")
written_compartment: [output.COMPARTMENT_SIZE_MOST]u8
@(private = "file")
read_compartment: [output.COMPARTMENT_SIZE_MOST]u8

// wiring_ring_take gives the library the wiring ring that the root
// service gave an asker with its list page (Wire with List_Page), for a
// process whose context has none. A process with a wiring ring keeps it.
wiring_ring_take :: proc "contextless" (memory: Handle) -> Status {
	if wiring_ring.head != nil {
		return .Bad_State
	}
	wiring_ring = ring_open(memory) or_return
	wiring_ring_memory = memory
	return .Ok
}

// wiring_ring_ready opens the wiring ring of the context at the first call.
@(private = "file")
wiring_ring_ready :: proc "contextless" () -> bool {
	if wiring_ring.head != nil {
		return true
	}
	memory := context_record().handles[op.CONTEXT_WIRING_RING]
	if memory == 0 {
		return false
	}
	opened, status := ring_open(memory)
	if status != .Ok {
		return false
	}
	wiring_ring, wiring_ring_memory = opened, memory
	return true
}

// wiring_wait waits until the wiring ring brings an end, or an end word of
// a writer end of the record output index changes (0: of each writer
// end), or until deadline. A caller then reads its state again: a wait
// ends early as each wait does.
wiring_wait :: proc "contextless" (deadline: u64, index: u32 = 0) {
	waiting := wait_begin()
	if wiring_ring_ready() {
		wait_records(&waiting, &wiring_ring.commands)
	}
	for &end in stream_ends {
		if end.command == .Writer_End && (index == 0 || end.index == index) && end.end_words != nil {
			wait_word(&waiting, &end.end_words.end, u32(output.End_Word.None))
		}
	}
	wait_end(&waiting, deadline)
}

// input_has_writer says if a record input has an end now, after the ends
// that wait in the wiring ring are taken.
input_has_writer :: proc "contextless" (stream: ^Record_Input($Record_Type, $wirings)) -> bool {
	stream_ends_take()
	for &end in stream_ends {
		if end.command == .Reader_End && end.index == stream.index && stream.index != 0 {
			return true
		}
	}
	return false
}

// handle_through says if a handle came through the wiring ring, with the
// kind of a memory object and the rights asked for at least.
@(private = "file")
handle_through :: proc "contextless" (handle: op.Handle, needed: Rights) -> bool {
	if handle == 0 {
		return false
	}
	kind, rights, through := handle_state(Handle(handle), wiring_ring_memory)
	return kind == .Memory && through && needed <= rights
}

// stream_end_close unmaps and closes what an end holds, and frees it.
@(private = "file")
stream_end_close :: proc "contextless" (end: ^Stream_End) {
	if end.ring_address != nil {
		memory_unmap(end.ring_address)
	}
	if end.end_words != nil {
		memory_unmap(end.end_words)
	}
	if raw_data(end.description_file) != nil {
		memory_unmap(raw_data(end.description_file))
	}
	handles := [4]Handle{end.ring_memory, end.end_memory, end.description_memory, end.terms_memory}
	for handle in handles {
		if handle != 0 {
			close(handle)
		}
	}
	end^ = {}
}

// given_handles_close closes the handles that a refused command named and
// that came through the wiring ring: the process keeps none of them.
@(private = "file")
given_handles_close :: proc "contextless" (record: ring.Record) {
	places := [4]int{output.WIRING_VALUE_RING, output.WIRING_VALUE_TERMS, output.WIRING_VALUE_DESCRIPTION, output.WIRING_VALUE_END_WORDS}
	for place in places {
		word := record.values[place]
		if word != 0 && word <= u64(max(u32)) && handle_through(op.Handle(word), {}) {
			close(Handle(word))
		}
	}
}

// stream_end_take takes one end that the border took: it proves each
// handle, maps the end page and the description file with Read only and
// the ring, and keeps the end. It gives the completion.
@(private = "file")
stream_end_take :: proc "contextless" (given: output.Given_End, record: ring.Record) -> ring.Record {
	refuse :: proc "contextless" (record: ring.Record, status: Status, refusal: errors.Error_Record) -> ring.Record {
		given_handles_close(record)
		return output.wiring_completion(record.tag, status, refusal)
	}
	reader := given.command == .Reader_End || given.command == .Asker_End
	if !handle_through(given.ring, {.Read, .Write}) {
		return refuse(record, .Bad_Handle, errors.error_make(.Handle_Absent, .Lent_Handles, output.WIRING_VALUE_RING + 1, i64(given.ring)))
	}
	if !handle_through(given.end_words, {.Read}) {
		return refuse(record, .Bad_Handle, errors.error_make(.Handle_Absent, .Lent_Handles, output.WIRING_VALUE_END_WORDS + 1, i64(given.end_words)))
	}
	if reader && !handle_through(given.description, {.Read}) {
		return refuse(record, .Bad_Handle, errors.error_make(.Handle_Absent, .Lent_Handles, output.WIRING_VALUE_DESCRIPTION + 1, i64(given.description)))
	}
	if given.terms != 0 && !handle_through(given.terms, {.Read}) {
		return refuse(record, .Bad_Handle, errors.error_make(.Handle_Absent, .Lent_Handles, output.WIRING_VALUE_TERMS + 1, i64(given.terms)))
	}
	place: ^Stream_End
	for &end in stream_ends {
		if end.command == .None {
			place = &end
			break
		}
	}
	if place == nil {
		return refuse(record, .No_Slot, errors.error_make(.Full, .Wirings, 0, STREAM_END_CAPACITY + 1, STREAM_END_CAPACITY))
	}
	end := Stream_End {
		command            = given.command,
		tag                = given.tag,
		index              = given.index,
		pace               = given.pace,
		ring_memory        = Handle(given.ring),
		end_memory         = Handle(given.end_words),
		description_memory = Handle(given.description),
		terms_memory       = Handle(given.terms),
	}
	status: Status
	end.ring_pages, status = memory_size(end.ring_memory)
	if status == .Ok {
		end.ring_address, status = memory_map(end.ring_memory)
	}
	if status == .Ok {
		words: rawptr
		words, status = memory_map(end.end_memory, {})
		end.end_words = (^output.End_Words)(words)
	}
	if status == .Ok && reader {
		pages: u64
		pages, status = memory_size(end.description_memory)
		address: rawptr
		if status == .Ok {
			address, status = memory_map(end.description_memory, {})
		}
		if status == .Ok {
			end.description_file = ([^]u8)(address)[:pages * PAGE_SIZE]
			described, ok := module.record_stream_type(end.description_file, output.DESCRIPTION_RECORD_INDEX)
			if !ok {
				status = .Bad_Operation
			}
			end.description = described
		}
	}
	if status != .Ok {
		stream_end_close(&end)
		return output.wiring_completion(record.tag, status, errors.error_make(.Refused, .Wirings, 0, 0, 0, i64(status)))
	}
	place^ = end
	return output.wiring_completion(record.tag, .Ok)
}

// stream_ends_take takes each end that waits in the wiring ring, while the
// completion queue has room for its answer. The writer calls it at each
// write: a reader that a Wire added gets the next record after its joined
// record.
@(private = "file")
stream_ends_take :: proc "contextless" () {
	if !wiring_ring_ready() {
		return
	}
	for !ring.full(&wiring_ring.completions) {
		record, ok := receive(&wiring_ring.commands)
		if !ok {
			break
		}
		given, refusal, taken := output.given_end_of_record(record)
		completion: ring.Record
		if taken {
			completion = stream_end_take(given, record)
		} else {
			given_handles_close(record)
			completion = output.wiring_completion(record.tag, .Bad_Operation, refusal)
		}
		send(&wiring_ring.completions, completion)
	}
}

// counters_wake_reader and counters_wake_writer wake the other side of a
// queue of compartments if it waits, as wake_reader and wake_writer do for
// a queue of records.
@(private = "file")
counters_wake_reader :: proc "contextless" (counters: ^ring.Counters) {
	ring.complete(&counters.write)
	if intrinsics.atomic_load(&counters.reader_waits) != 0 && intrinsics.atomic_exchange(&counters.reader_waits, 0) != 0 {
		word_wake(&counters.write, WAKE_ALL)
	}
}

@(private = "file")
counters_wake_writer :: proc "contextless" (counters: ^ring.Counters) {
	ring.complete(&counters.read)
	if intrinsics.atomic_load(&counters.writer_waits) != 0 && intrinsics.atomic_exchange(&counters.writer_waits, 0) != 0 {
		word_wake(&counters.read, WAKE_ALL)
	}
}

// stream_end_open opens the ring of an end at its first use, for
// compartments of a record of record_size bytes. false: the memory is no
// ring of that size, and the end is closed.
@(private = "file")
stream_end_open :: proc "contextless" (end: ^Stream_End, record_size: u32) -> bool {
	if end.opened {
		return true
	}
	size := output.compartment_size(record_size)
	opened, ok := ring.compartment_open(end.ring_address, end.ring_pages, size)
	// A memory that is no ring of this size comes from no root service that
	// compared the record: the end is closed, and the other side reads the
	// close.
	if size == 0 || !ok {
		stream_end_close(end)
		return false
	}
	end.queue, end.opened = opened, true
	return true
}

// stream_end_ended gives the end word of an end, through its border. A
// word that the border refuses ends the end as Revoked: the root service
// alone writes the page, and a page that names nothing is no stream.
@(private = "file")
stream_end_ended :: proc "contextless" (end: ^Stream_End) -> (word: output.End_Word, stop_cause: u32, stop_outcome: u32) {
	read, cause, outcome, ok := output.end_of_words(output.end_words_read(end.end_words))
	if !ok {
		return .Revoked, 0, 0
	}
	return read, cause, outcome
}

// What a write does to one ring, decided before the write: a write is
// whole or refused over the rings that hold the writer.
@(private = "file")
Ring_Room :: enum u8 {
	Room       = 0, // The ring takes the record, after its gap record when it has one.
	Holds      = 1, // The ring is full and holds the writer.
	Refuses    = 2, // The ring is full and refuses this record for its reader alone: the pace Never_Holds_Writer.
}

@(private = "file")
ring_room :: proc "contextless" (end: ^Stream_End) -> Ring_Room {
	queue := &end.queue.commands
	needed := u32(1)
	if !end.joined {
		needed += 1
	}
	if end.gap_count != 0 {
		needed += 1
	}
	room := ring.compartment_capacity(queue) - ring.compartment_count(queue)
	if room >= needed {
		return .Room
	}
	switch end.pace {
	case .Writer_Chooses:
		return .Holds
	case .Always_Holds_Writer:
		return .Holds
	case .Never_Holds_Writer:
		return .Refuses
	}
	return .Holds
}

// output_ends_of gives the live ends of a record output, after it took the
// ends of the wiring ring, removed each end that ended, and read the
// completions of each ring.
@(private = "file")
output_ends_of :: proc "contextless" (state: ^Output_State, record_size: u32) -> (live: int) {
	stream_ends_take()
	for &end in stream_ends {
		if end.command != .Writer_End || end.index != state.index || state.index == 0 {
			continue
		}
		if !stream_end_open(&end, record_size) {
			continue
		}
		if word, _, _ := stream_end_ended(&end); word != .None {
			state.last_end = word
			state.rings_ended += 1
			stream_end_close(&end)
			continue
		}
		for _ in 0 ..< ring.count(&end.queue.completions) {
			completion, ok := ring.pop(&end.queue.completions)
			if !ok {
				break
			}
			kind, _, _, known := output.completion_of_record(completion)
			if known && kind == .Bad_Record {
				state.refused_by_readers += 1
			}
		}
		live += 1
	}
	return live
}

// compartment_push_to builds one compartment in the private copy and
// pushes it.
@(private = "file")
compartment_push_to :: proc "contextless" (end: ^Stream_End, kind: output.Compartment_Kind, serial: u32, record: []u8 = nil, gap: u32 = 0, error: errors.Error_Record = {}) -> bool {
	size := int(end.queue.commands.compartment_size)
	buffer := written_compartment[:size]
	built := false
	switch kind {
	case .Joined:
		built = output.joined_compartment(buffer, serial)
	case .Gap:
		built = output.gap_compartment(buffer, serial, gap)
	case .End:
		built = output.end_compartment(buffer, serial, error)
	case .Record:
		built = output.record_compartment(buffer, serial, record)
	}
	return built && ring.compartment_push(&end.queue.commands, buffer)
}

// output_write writes one record of a record output into the ring of each
// reader (src/md/features/module_outputs.md, "Fan-out and flow control").
// The write is whole or refused over the rings that hold the writer: with
// wait, it waits for room in each of them until deadline; with no wait, a
// full ring of the pace Writer_Chooses refuses the record with Full. A
// full ring of the pace Never_Holds_Writer refuses the record for its
// reader alone, which gets a gap record before the next record that it
// takes. A ring of the pace Always_Holds_Writer holds the writer whatever
// wait says. With no reader, the record is discarded and counted:
// No_Reader. It gives Ended after output_end.
output_write :: proc "contextless" (stream: ^Record_Output($Record_Type, $pairing), record: Record_Type, wait := true, deadline: u64 = WAIT_FOREVER) -> output.Stream_Status {
	state := &stream.state
	if state.ended {
		return .Ended
	}
	copy_of_record := record
	bytes := ([^]u8)(&copy_of_record)[:size_of(Record_Type)]
	return output_write_bytes(state, bytes, wait, deadline)
}

@(private = "file")
output_write_bytes :: proc "contextless" (state: ^Output_State, bytes: []u8, wait: bool, deadline: u64) -> output.Stream_Status {
	if output.compartment_size(u32(len(bytes))) == 0 {
		return .Bad_Record
	}
	for {
		if output_ends_of(state, u32(len(bytes))) == 0 {
			state.discarded += 1
			state.next_serial += 1
			return .No_Reader
		}
		holds := false
		holds_by_choice := false
		for &end in stream_ends {
			if end.command != .Writer_End || end.index != state.index || !end.opened {
				continue
			}
			if ring_room(&end) == .Holds {
				holds = true
				holds_by_choice = holds_by_choice || end.pace == .Writer_Chooses
			}
		}
		if !holds {
			break
		}
		// With no wait, a full ring of the pace Writer_Chooses refuses the
		// record; only rings of the pace Always_Holds_Writer hold it then.
		if !wait && holds_by_choice {
			state.refused += 1
			return .Full
		}
		// Wait for room in each ring that holds the writer, or for an end
		// word, until the deadline.
		waiting := wait_begin()
		for &end in stream_ends {
			if end.command != .Writer_End || end.index != state.index || !end.opened {
				continue
			}
			if ring_room(&end) == .Holds {
				counters := end.queue.commands.counters
				wait_word(&waiting, &counters.read, intrinsics.atomic_load_explicit(&counters.read, .Relaxed), &counters.writer_waits, &counters.reader_waits, &counters.write)
				wait_word(&waiting, &end.end_words.end, u32(output.End_Word.None))
			}
		}
		if wait_end(&waiting, deadline) >= deadline {
			state.refused += 1
			return .Full
		}
	}
	serial := state.next_serial
	for &end in stream_ends {
		if end.command != .Writer_End || end.index != state.index || !end.opened {
			continue
		}
		if !end.joined {
			// The first compartment of each ring: the serial of the next
			// record, the count of the records before this reader joined.
			end.joined = compartment_push_to(&end, .Joined, serial)
		}
		if ring_room(&end) == .Refuses {
			if end.gap_count == 0 {
				end.gap_first = serial
			}
			end.gap_count += 1
			continue
		}
		if end.gap_count != 0 && compartment_push_to(&end, .Gap, end.gap_first, gap = end.gap_count) {
			end.gap_count = 0
		}
		compartment_push_to(&end, .Record, serial, bytes)
		counters_wake_reader(end.queue.commands.counters)
	}
	state.next_serial += 1
	state.written += 1
	return .Ok
}

// output_end ends a record output: an end record in each ring, with an
// error record that is zero for a clean end, then the close of each end.
// Each ring takes it when it has room, until deadline; a ring that has no
// room by then ends with its end word when the process stops. A later
// output_write gives Ended.
output_end :: proc "contextless" (stream: ^Record_Output($Record_Type, $pairing), error: errors.Error_Record = {}, deadline: u64 = WAIT_FOREVER) -> output.Stream_Status {
	state := &stream.state
	if state.ended {
		return .Ended
	}
	output_ends_of(state, u32(size_of(Record_Type)))
	status := output.Stream_Status.Ok
	for &end in stream_ends {
		if end.command != .Writer_End || end.index != state.index || !end.opened {
			continue
		}
		for {
			if !end.joined {
				end.joined = compartment_push_to(&end, .Joined, state.next_serial)
			}
			if end.joined && compartment_push_to(&end, .End, state.next_serial, error = error) {
				counters_wake_reader(end.queue.commands.counters)
				break
			}
			waiting := wait_begin()
			counters := end.queue.commands.counters
			wait_word(&waiting, &counters.read, intrinsics.atomic_load_explicit(&counters.read, .Relaxed), &counters.writer_waits, &counters.reader_waits, &counters.write)
			wait_word(&waiting, &end.end_words.end, u32(output.End_Word.None))
			if wait_end(&waiting, deadline) >= deadline {
				status = .Full
				break
			}
			if word, _, _ := stream_end_ended(&end); word != .None {
				state.last_end = word
				break
			}
		}
		stream_end_close(&end)
	}
	state.ended = true
	return status
}

// output_read_by says if a record output has a reader now: a writer that
// builds a costly record asks it first.
output_read_by :: proc "contextless" (stream: ^Record_Output($Record_Type, $pairing)) -> bool {
	return output_ends_of(&stream.state, u32(size_of(Record_Type))) > 0
}

// output_reader_count gives the readers of a record output now.
output_reader_count :: proc "contextless" (stream: ^Record_Output($Record_Type, $pairing)) -> int {
	return output_ends_of(&stream.state, u32(size_of(Record_Type)))
}

// What a read gives besides the record: the kind of the compartment and
// what its kind says, or the end word.
Input_Item :: struct {
	kind:         output.Compartment_Kind, // Record, Joined, Gap or End.
	serial:       u32, // A record: its serial. Joined: the serial of the next record. Gap: the first missing serial. End: the count of the records.
	gap_count:    u32, // Gap: the records that the reader misses.
	error:        errors.Error_Record, // End: zero for a clean end.
	end_word:     output.End_Word, // Ended by an end word: why; None for an end record.
	stop_cause:   u32, // Writer_Stopped: the words of the stop of the writer.
	stop_outcome: u32,
	refusal:      errors.Error_Record, // Bad_Record: the error record that names the field.
}

// input_read reads the next compartment of a record input: a record, which
// it copies into into, or a joined record, a gap record, or the end. It
// waits for one until deadline: No_Record past it. No_Writer: the record
// input has no ring. A compartment that the border refuses gives
// Bad_Record, with its error record in the item, and a completion that
// tells the writer.
input_read :: proc "contextless" (stream: ^Record_Input($Record_Type, $wirings), into: ^Record_Type, deadline: u64 = WAIT_FOREVER) -> (item: Input_Item, status: output.Stream_Status) {
	state := &stream.state
	if state.index == 0 {
		return {}, .No_Writer
	}
	item, status = stream_read(.Reader_End, state.index, 0, ([^]u8)(into)[:size_of(Record_Type)], deadline)
	if status == .Ok && item.kind == .Record {
		state.read += 1
	}
	return item, status
}

// asker_read reads the next compartment of a wiring whose reader is this
// process as its asker: number is the number of the wiring that the
// completion of Wire or Start gave.
asker_read :: proc "contextless" (number: u32, into: ^$Record_Type, deadline: u64 = WAIT_FOREVER) -> (item: Input_Item, status: output.Stream_Status) {
	return stream_read(.Asker_End, 0, number, ([^]u8)(into)[:size_of(Record_Type)], deadline)
}

// stream_read is the reader of input_read and asker_read: the ends of one
// record input, or the one end of an asker, read in the order of the
// table.
@(private = "file")
stream_read :: proc "contextless" (command: output.Wiring_Command, index: u32, tag: u32, into: []u8, deadline: u64) -> (item: Input_Item, status: output.Stream_Status) {
	for {
		stream_ends_take()
		found := false
		for &end in stream_ends {
			if end.command != command || (command == .Reader_End && end.index != index) || (command == .Asker_End && end.tag != tag) {
				continue
			}
			// The record of the variable has the size of the description
			// that the root service compared: an end of another size is no
			// end of this variable.
			if end.description.size != u32(len(into)) || !stream_end_open(&end, end.description.size) {
				if end.command != .None {
					stream_end_close(&end)
				}
				continue
			}
			found = true
			read, read_status, done := stream_end_read(&end, into)
			if done {
				return read, read_status
			}
		}
		if !found {
			return {}, .No_Writer
		}
		waiting := wait_begin()
		for &end in stream_ends {
			if end.command != command || !end.opened || (command == .Reader_End && end.index != index) || (command == .Asker_End && end.tag != tag) {
				continue
			}
			counters := end.queue.commands.counters
			wait_word(&waiting, &counters.write, intrinsics.atomic_load_explicit(&counters.read, .Relaxed), &counters.reader_waits, &counters.writer_waits, &counters.read)
			wait_word(&waiting, &end.end_words.end, u32(output.End_Word.None))
		}
		if wiring_ring.head != nil {
			wait_records(&waiting, &wiring_ring.commands)
		}
		if wait_end(&waiting, deadline) >= deadline {
			return {}, .No_Record
		}
	}
}

// stream_end_read reads one compartment of one end. done is false when the
// ring has nothing now. The reader takes a compartment only while the
// completion queue has room for its answer.
@(private = "file")
stream_end_read :: proc "contextless" (end: ^Stream_End, into: []u8) -> (item: Input_Item, status: output.Stream_Status, done: bool) {
	if ring.full(&end.queue.completions) {
		return {}, .Ok, false
	}
	size := int(end.queue.commands.compartment_size)
	buffer := read_compartment[:size]
	if !ring.compartment_pop(&end.queue.commands, buffer) {
		// The end word only when the queue is empty: each record that the
		// writer published before its stop comes first.
		word, cause, outcome := stream_end_ended(end)
		if word == .None {
			return {}, .Ok, false
		}
		stream_end_close(end)
		return {kind = .End, end_word = word, stop_cause = cause, stop_outcome = outcome}, .Ended, true
	}
	counters_wake_writer(end.queue.commands.counters)
	taken, fault, refusal := output.record_of_compartment(&end.read_state, buffer, end.description_file, end.description)
	if fault != .None {
		// The writer reads the refusal in its completions. The reader
		// closes the end: after a compartment that it refused, it can trust
		// no serial of that ring, and only that stream ends.
		ring.push(&end.queue.completions, output.refusal_completion(end.read_state.next_serial, refusal))
		counters_wake_reader(end.queue.completions.counters)
		stream_end_close(end)
		return {kind = .Record, refusal = refusal}, .Bad_Record, true
	}
	item = {kind = taken.kind, serial = taken.serial, gap_count = taken.gap_count, error = taken.error}
	switch taken.kind {
	case .Record:
		copy(into, taken.record)
		return item, .Ok, true
	case .Joined, .Gap:
		return item, .Ok, true
	case .End:
		ring.push(&end.queue.completions, output.end_completion(taken.serial))
		counters_wake_reader(end.queue.completions.counters)
		stream_end_close(end)
		return item, .Ended, true
	}
	return item, .Ok, true
}
