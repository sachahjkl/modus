package system

// The library of the record outputs and the record inputs
// (src/md/features/module_outputs.md, "Fan-out and flow control";
// src/md/features/module_outputs.md, "The end of a stream"): the ends that a process takes from its wiring ring,
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
import "modus:contract/call_outcome"
import "modus:contract/errors"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/output"
import "modus:contract/ring"

// The ends of a process have no count: the table grows in an arena that
// its budget pays, one place for each end that the wiring service gives
// (stream_ends_grow; src/md/features/module_outputs.md, "The bounds of the
// wirings").

// The places of the wait of a read: they grow with the table of the ends,
// so a read waits on each of its rings (output.reader_wait_words). One set
// serves each thread that reads: the calls of this file run in one thread
// at a time, and wait_begin asks the kernel for the room of the thread
// that waits.
@(private = "file")
reader_wait: Growing_Wait_Set

// One end that the process holds. Free when command is None.
@(private = "package")
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
	// The counter of the other side, as this side loaded it for its last
	// decision: the writer waits on read with read_seen, the reader on
	// write with write_seen. A change after the load ends the wait at once.
	read_seen:          u32,
	write_seen:         u32,
	// A writer end with a condition: the bytes of the page that the root
	// service gave, copied once at the take, then taken through the border
	// of the writer when the size of the record is known.
	condition_given:    bool,
	condition_bytes:    [size_of(output.Writer_Condition)]u8,
	condition:          output.Checked_Condition,
	// A writer end: the record of this write fails the condition of the
	// ring, which takes nothing of this write.
	skips:              bool,
	// A writer end: this ring held the writer at the last look of the
	// write; and the last write gave Full with this ring among the rings
	// that held it. A writer that keeps its record on Full waits for the
	// room of these rings only (wait_output_room): a ring that a write
	// filled exactly holds no record that waits.
	holds_at_look:      bool,
	refused_full:       bool,
	// A writer end of a record output Paired: the number of the wiring of
	// the source of its pair, a reader end of this process. 0 for each
	// other end.
	pair:               u32,
	// A writer end of a record output By_Principal: the principal of its
	// reader, plus 1, which the wiring service wrote. 0 for each other end.
	reader_principal:   u64,
}

// writer_end_in says if an end is a writer end of the record output index
// and of the pair: 0 for a record output that is not Paired, whose ends
// name no pair, so a write of one never reaches a ring of a pair.
@(private = "file")
writer_end_in :: proc "contextless" (end: ^Stream_End, index: u32, selector: End_Selector) -> bool {
	if end.command != .Writer_End || end.index != index || end.pair != selector.pair {
		return false
	}
	return selector.any_principal || end.reader_principal == selector.reader_principal
}

// Which writer ends of a record output a write or a count takes: the ends
// of one pair (0: no pair), and of one reader principal (plus 1; 0: the
// ends that name none). any_principal takes the ends of each principal: a
// count of the live rings, never a write.
End_Selector :: struct {
	pair:             u32,
	reader_principal: u64,
	any_principal:    bool,
}

// refused_full_mark records the end of one write on each ring of a record
// output: Full marks the rings that held the writer at its last look, and
// a write that went through clears each mark.
@(private = "file")
refused_full_mark :: proc "contextless" (index: u32, full: bool, selector: End_Selector = {}) {
	for &end in stream_ends {
		if writer_end_in(&end, index, selector) && end.opened {
			end.refused_full = full && end.holds_at_look
		}
	}
}

@(private = "package")
stream_ends: []Stream_End

// The tags of the ends that this process closed and whose word Closed did
// not fit the completion queue of the wiring ring yet. Each end gives one
// word, and the table holds one for each end of the table; a word that
// finds no room past it is dropped, and the root service then frees the
// count of that end at the stop of a side or at a revocation.
@(private = "package")
closed_tags: []u32
@(private = "package")
closed_tag_count: int

// The arenas of the table of the ends and of the closed tags: made at the
// first end that the process takes, from what its budget holds then.
@(private = "package")
Stream_End_Table :: struct {
	ends:  Arena,
	tags:  Arena,
	made:  bool,
	count: int,
}
@(private = "package")
stream_end_table: Stream_End_Table

when ODIN_OS != .Freestanding {
	// A host test gives the memory of the table and the places that its
	// budget pays: the seam then grows the table in it with no kernel.
	@(private = "package")
	stream_ends_host_backing: []Stream_End
	@(private = "package")
	closed_tags_host_backing: []u32
	@(private = "package")
	stream_ends_host_paid: int
}

// stream_ends_grow adds one place to the table of the ends and one to the
// closed tags, as the budget of the process pays them; the table never
// moves. false: the budget pays no more, and nothing changed.
@(private = "package")
stream_ends_grow :: proc "contextless" () -> bool {
	table := &stream_end_table
	when ODIN_OS != .Freestanding {
		if stream_ends_host_seam_active {
			if table.count >= stream_ends_host_paid || table.count >= len(stream_ends_host_backing) || table.count >= len(closed_tags_host_backing) {
				return false
			}
			stream_ends_host_backing[table.count] = {}
			closed_tags_host_backing[table.count] = 0
			table.count += 1
			stream_ends = stream_ends_host_backing[:table.count]
			closed_tags = closed_tags_host_backing[:table.count]
			return true
		}
	}
	if !table.made {
		amounts, read := budget_read()
		if read != .Succeeded || amounts.pages == 0 {
			return false
		}
		pages := arena_reservation_pages(amounts.pages)
		ends, ends_status := arena_create(pages)
		if ends_status != .Succeeded {
			return false
		}
		tags, tags_status := arena_create(pages)
		if tags_status != .Succeeded {
			_ = arena_end(&ends)
			return false
		}
		// Exact commits keep both small tables to the pages their ends need
		// instead of committing ARENA_GROWTH_STEP_FIRST_PAGES each.
		ends.exact_commits = true
		tags.exact_commits = true
		table.ends, table.tags, table.made = ends, tags, true
	}
	end_place, end_status := arena_push(&table.ends, size_of(Stream_End), align_of(Stream_End))
	if end_status != .Succeeded {
		return false
	}
	tag_place, tag_status := arena_push(&table.tags, size_of(u32), align_of(u32))
	if tag_status != .Succeeded {
		// The place of the end stays in the arena, free: the next growth
		// counts it once its tag is paid.
		_ = arena_pop(&table.ends, size_of(Stream_End))
		return false
	}
	intrinsics.mem_zero(end_place, size_of(Stream_End))
	(^u32)(tag_place)^ = 0
	table.count += 1
	stream_ends = ([^]Stream_End)(table.ends.base)[:table.count]
	closed_tags = ([^]u32)(table.tags.base)[:table.count]
	// A set that the budget does not pay keeps its places: the rings past
	// them are not waited on, and wait_set_room has written why.
	_ = wait_set_grow(&reader_wait, output.reader_wait_words(table.count))
	return true
}

// stream_end_places takes pending ends from the wiring ring and gives the
// places of the table of the ends of this process: the most rings that
// input_tags or output_pairs can list, so a caller sizes its list of tags
// from it.
stream_end_places :: proc "contextless" () -> int {
	stream_ends_take()
	return len(stream_ends)
}

// stream_end_free_place gives a free place of the table of the ends, and
// grows the table by one when none is free. nil: the budget pays no more.
@(private = "package")
stream_end_free_place :: proc "contextless" () -> ^Stream_End {
	for &end in stream_ends {
		if end.command == .None {
			return &end
		}
	}
	if !stream_ends_grow() {
		return nil
	}
	return &stream_ends[len(stream_ends) - 1]
}

// The wiring ring of the process: the handle 16 of its context, or the ring
// that the root service gave an asker with its list page.
@(private = "package")
wiring_ring: ring.Ring
@(private = "file")
wiring_ring_memory: Handle

when ODIN_OS != .Freestanding {
	// Host tests enable this seam to drive the output_write loop against
	// host-allocated rings without calling kernel map/unmap/close or reading
	// the thread record.
	@(private = "package")
	stream_ends_host_seam_active: bool
}

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
wiring_ring_take :: proc "contextless" (memory: Handle) -> call_outcome.Call_Outcome {
	if wiring_ring.head != nil {
		return .Wrong_State
	}
	wiring_ring = ring_open(memory, receive_handles = true) or_return
	wiring_ring_memory = memory
	return .Succeeded
}

// wiring_ring_open maps the wiring ring of the context with Receive_Handles
// so the wiring service can deliver stream ends before the first write or read.
wiring_ring_open :: proc "contextless" () -> bool {
	return wiring_ring_ready()
}

// wiring_ring_ready opens the wiring ring of the context at the first call.
@(private = "file")
wiring_ring_ready :: proc "contextless" () -> bool {
	if wiring_ring.head != nil {
		return true
	}
	when ODIN_OS != .Freestanding {
		if stream_ends_host_seam_active {
			return false
		}
	}
	memory := context_record().handles[op.CONTEXT_WIRING_RING]
	if memory == 0 {
		return false
	}
	opened, status := ring_open(memory, receive_handles = true)
	if status != .Succeeded {
		return false
	}
	wiring_ring, wiring_ring_memory = opened, memory
	return true
}

// wait_wiring adds the commands of the wiring ring to a wait that the
// caller builds with its own words: a loop that waits on other things too
// (a window, the log) wakes when an end comes, and takes it at its next
// pass. A process with no wiring ring adds nothing.
wait_wiring :: proc "contextless" (waiting: ^Wait) {
	if wiring_ring_ready() {
		wait_records(waiting, &wiring_ring.commands)
	}
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

// stream_index_read reads the index that the loader wrote in the variable
// of a record stream (module.record_stream_indexes_write), with a volatile
// load. No code of the module stores the index: with plain loads, the
// optimizer can take the variable for its zeros, as it would take the
// own hash (text.odin), or split it into one variable for each field, whose
// symbol the tool then does not find, so the loader writes nothing. The
// index then reads 0, and the record stream never finds its ends. A
// volatile load is an access that the optimizer cannot see through, so it
// keeps the variable whole, at its symbol.
@(private = "file")
stream_index_read :: proc "contextless" (index: ^u32) -> u32 {
	return intrinsics.volatile_load(index)
}

// input_has_writer says if a record input has an end now, after the ends
// that wait in the wiring ring are taken.
input_has_writer :: proc {
	input_has_writer_plain,
	input_has_writer_with_terms,
}

input_has_writer_plain :: proc "contextless" (stream: ^Record_Input($Record_Type, $wirings)) -> bool {
	_, found := input_end_of(&stream.state, 0)
	return found
}

input_has_writer_with_terms :: proc "contextless" (stream: ^Record_Input_With_Terms($Record_Type, $Terms_Type, $wirings)) -> bool {
	_, found := input_end_of(&stream.state, 0)
	return found
}

// Why a reader that waits for its full ring to hold its writer stops.
Full_Wait_End :: enum u8 {
	Held    = 0, // The ring is full and its writer waits for room in it.
	No_End  = 1, // The record input has no end, or its ring is no ring of the size of its record.
	Ended   = 2, // The end ended by its end word: the reader reads it.
	Broken  = 3, // The counters are no counters of an honest writer: the end is closed, as a read closes it.
	Past_Deadline = 4, // The deadline passed first.
}

// input_full_and_writer_waits waits, with no read, until the ring of a
// record input of the count One is full and its writer waits for room in
// it, or until deadline. A slow reader then knows by a state, not by a
// time, that its ring holds the writer, which only the pace
// Always_Holds_Writer, or a writer that chose to wait, does. A record input
// of the counts Many and Many_Types has several rings, which no single
// state names: the procedure takes only the count One. It gives why it
// ended, and the compartments that the ring holds with its capacity.
input_full_and_writer_waits :: proc "contextless" (stream: ^Record_Input($Record_Type, $wirings), deadline: u64) -> (ended: Full_Wait_End, held, capacity: u32) where wirings == module.Wiring_Count.One {
	return full_and_writer_waits(.Reader_End, stream_index_read(&stream.index), u32(size_of(Record_Type)), deadline)
}

// asker_full_and_writer_waits is input_full_and_writer_waits for a wiring
// whose reader is this process as its asker, by the number that the
// completion of Wire or Start gave: an asker knows by a state, not by a
// time, that its ring holds the writer.
asker_full_and_writer_waits :: proc "contextless" (number: u32, $Record_Type: typeid, deadline: u64) -> (ended: Full_Wait_End, held, capacity: u32) {
	return full_and_writer_waits(.Asker_End, number, u32(size_of(Record_Type)), deadline)
}

// full_and_writer_waits is the one body of the two: the end of a record
// input by its index, or the end of an asker by its number.
@(private = "file")
full_and_writer_waits :: proc "contextless" (command: output.Wiring_Command, key: u32, record_size: u32, deadline: u64) -> (ended: Full_Wait_End, held, capacity: u32) {
	for {
		stream_ends_take()
		end: ^Stream_End
		for &item in stream_ends {
			if item.command != command || key == 0 {
				continue
			}
			if (command == .Asker_End && item.tag == key) || (command != .Asker_End && item.index == key) {
				end = &item
				break
			}
		}
		// With no end that opens, no counter can be read: the rule gives
		// No_End whatever they hold (output.full_wait_step_of).
		if end == nil {
			return .No_End, 0, 0
		}
		// As stream_read does: the record of the variable has the size of
		// the description that the root service compared, so an end of
		// another size is no end of this variable, and it is closed. A
		// memory that is no ring of that size closes in stream_end_open.
		if end.description.size != record_size {
			stream_end_finish(end)
			return .No_End, 0, 0
		}
		if !stream_end_open(end, end.description.size) {
			return .No_End, 0, 0
		}
		word, _, _ := stream_end_ended(end)
		commands := end.queue.commands.counters
		completions := end.queue.completions.counters
		write := intrinsics.atomic_load_explicit(&commands.write, .Acquire)
		read := intrinsics.atomic_load_explicit(&commands.read, .Relaxed)
		completions_write := intrinsics.atomic_load_explicit(&completions.write, .Relaxed)
		completions_read := intrinsics.atomic_load_explicit(&completions.read, .Acquire)
		writer_waits := intrinsics.atomic_load_explicit(&commands.writer_waits, .Acquire) != 0
		capacity = ring.compartment_capacity(&end.queue.commands)
		step, _ := output.full_wait_step_of(true, word, write, read, capacity, completions_write, completions_read, ring.capacity(&end.queue.completions), writer_waits, time(), deadline)
		switch step {
		case .No_End:
			return .No_End, 0, 0
		case .Ended:
			return .Ended, 0, 0
		case .Held:
			return .Held, write - read, capacity
		case .Broken:
			// As a read does: a ring that no honest writer writes is never
			// read again, and never waited on.
			stream_end_finish(end)
			return .Broken, 0, capacity
		case .Past_Deadline:
			return .Past_Deadline, write - read, capacity
		case .Wait:
		}
		// Two words, so no wake is lost between the load and the wait: a
		// write changes write, and a writer that starts to wait changes
		// writer_waits when the ring is full. The writer, in wait_end,
		// stores writer_waits, then takes reader_waits and wakes write:
		// the flag reader_waits brings that wake here. No other flag is
		// set: this reader asks the writer for nothing, and a flag of the
		// writer set here would wake it for no room, which would wake this
		// reader again, with no end. writer_waits is waited on at the value
		// that this look loaded, not at 0: a writer that waits on a ring
		// that is not full yet holds it at 1, and a wait while it is 0
		// would end at once, a spin.
		waiting := wait_begin()
		wait_word(&waiting, &end.end_words.end, u32(output.End_Word.None))
		wait_word(&waiting, &commands.write, write, &commands.reader_waits)
		wait_word(&waiting, &commands.writer_waits, u32(writer_waits ? 1 : 0))
		wait_end(&waiting, deadline)
	}
}

// input_writer_counts gives the counts that the writer of a record input
// of the count One published in the head page of its ring: its claim as of
// the last compartment that this process took. ok is false while the
// record input has no open end.
input_writer_counts :: proc "contextless" (stream: ^Record_Input($Record_Type, $wirings)) -> (counts: output.Writer_Counts, ok: bool) where wirings == module.Wiring_Count.One {
	index := stream_index_read(&stream.index)
	for &end in stream_ends {
		if end.command == .Reader_End && end.index == index && index != 0 && end.opened {
			return output.writer_counts_read(end.ring_address), true
		}
	}
	return {}, false
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
	when ODIN_OS != .Freestanding {
		if stream_ends_host_seam_active {
			end^ = {}
			return
		}
	}
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

// stream_end_finish closes an end that this process took and ends of its
// own: after the end of its stream, after a fault of the other side, or an
// end that is no end of its variable. The root service reads the word
// Closed and frees the count of this side. An end that ended by its end
// word is closed with stream_end_close: the root service ended the wiring
// before, and a word Closed would name nothing.
@(private = "file")
stream_end_finish :: proc "contextless" (end: ^Stream_End) {
	tag := end.tag
	stream_end_close(end)
	if closed_tag_count < len(closed_tags) {
		closed_tags[closed_tag_count] = tag
		closed_tag_count += 1
	}
	closed_words_send()
}

// stream_end_close_by_word closes an end that ended by its end word. For
// Side_Closed, the other side closed and the wiring still runs: this side
// says Closed too, and the root service then ends the wiring. For each
// other word, the root service ended the wiring before.
@(private = "file")
stream_end_close_by_word :: proc "contextless" (end: ^Stream_End, word: output.End_Word) {
	if word == .Side_Closed {
		stream_end_finish(end)
	} else {
		stream_end_close(end)
	}
}

// closed_words_wait adds the room of the completion queue of the wiring
// ring to a wait while words Closed wait for it: the next call sends them
// as soon as the root service reads its completions.
@(private = "file")
closed_words_wait :: proc "contextless" (waiting: ^Wait) {
	if closed_tag_count > 0 && wiring_ring.head != nil {
		wait_room(waiting, &wiring_ring.completions)
	}
}

// closed_words_send writes the words Closed that wait, while the
// completion queue of the wiring ring has room.
@(private = "file")
closed_words_send :: proc "contextless" () {
	if wiring_ring.head == nil {
		return
	}
	sent := 0
	for sent < closed_tag_count && send(&wiring_ring.completions, output.wiring_closed_completion(closed_tags[sent])) {
		sent += 1
	}
	if sent == 0 {
		return
	}
	copy(closed_tags[:], closed_tags[sent:closed_tag_count])
	closed_tag_count -= sent
}

// given_handles_close closes the handles that a refused command named and
// that came through the wiring ring: the process keeps none of them.
@(private = "file")
given_handles_close :: proc "contextless" (record: ring.Record) {
	places := [4]int{output.WIRING_VALUE_RING, output.WIRING_VALUE_TERMS, output.WIRING_VALUE_DESCRIPTION, output.WIRING_VALUE_END_WORDS}
	for place in places {
		// The word of the description of a writer end is the principal of
		// its reader: a number, never a handle.
		if place == output.WIRING_VALUE_READER_PRINCIPAL && record.kind == u32(output.Wiring_Command.Writer_End) {
			continue
		}
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
	refuse :: proc "contextless" (record: ring.Record, outcome: call_outcome.Call_Outcome, refusal: errors.Error_Record) -> ring.Record {
		given_handles_close(record)
		return output.wiring_completion(record.tag, outcome, refusal)
	}
	reader := given.command == .Reader_End || given.command == .Asker_End
	if !handle_through(given.ring, {.Read, .Write}) {
		return refuse(record, .Argument_Refused, errors.error_make(.Handle_Absent, .Lent_Handles, output.WIRING_VALUE_RING + 1, i64(given.ring)))
	}
	if !handle_through(given.end_words, {.Read}) {
		return refuse(record, .Argument_Refused, errors.error_make(.Handle_Absent, .Lent_Handles, output.WIRING_VALUE_END_WORDS + 1, i64(given.end_words)))
	}
	if reader && !handle_through(given.description, {.Read}) {
		return refuse(record, .Argument_Refused, errors.error_make(.Handle_Absent, .Lent_Handles, output.WIRING_VALUE_DESCRIPTION + 1, i64(given.description)))
	}
	if given.terms != 0 && !handle_through(given.terms, {.Read}) {
		return refuse(record, .Argument_Refused, errors.error_make(.Handle_Absent, .Lent_Handles, output.WIRING_VALUE_TERMS + 1, i64(given.terms)))
	}
	if given.condition != 0 && !handle_through(given.condition, {.Read}) {
		return refuse(record, .Argument_Refused, errors.error_make(.Handle_Absent, .Lent_Handles, output.WIRING_VALUE_TERMS + 1, i64(given.condition)))
	}
	// A place that the budget does not pay refuses the end: the wiring
	// service ends it at the word Refused.
	place := stream_end_free_place()
	if place == nil {
		return refuse(record, .Budget_Or_Capacity_Exhausted, errors.error_make(.Budget, .Pages, 0, i64(len(stream_ends) + 1), i64(len(stream_ends))))
	}
	// A ring of a pair carries the records of one source that this process
	// reads: the root service gives the end of the source first, so a pair
	// that names no reader end of this process comes from no root service.
	if given.command == .Writer_End && given.pair != 0 {
		source_held := false
		for &held in stream_ends {
			source_held ||= held.command == .Reader_End && held.tag == given.pair
		}
		if !source_held {
			return refuse(record, .Nothing_Has_That_Name, errors.error_make(.Absent, .Wirings, output.WIRING_VALUE_PAIR + 1, i64(given.pair)))
		}
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
		pair               = given.pair,
		reader_principal   = given.reader_principal,
	}
	// A ring with a condition: the writer leaves out records, so its
	// serials move forward by any count.
	end.read_state.filtered = given.filter == .By_Writer
	status: call_outcome.Call_Outcome
	// The condition of a writer end: one copy of the page, which the
	// handle then leaves. The border of the writer reads the copy when the
	// size of the record is known (stream_end_open).
	if given.condition != 0 {
		address, map_status := memory_map(Handle(given.condition), {})
		status = map_status
		if status == .Succeeded {
			intrinsics.mem_copy_non_overlapping(&end.condition_bytes[0], address, size_of(output.Writer_Condition))
			memory_unmap(address)
			end.condition_given = true
		}
		close(Handle(given.condition))
		if status != .Succeeded {
			given_handles_close(record)
			return output.wiring_completion(record.tag, status, errors.error_make(.Refused, .Wirings, 0, 0, 0, i64(status)))
		}
	}
	end.ring_pages, status = memory_size(end.ring_memory)
	if status == .Succeeded {
		end.ring_address, status = memory_map(end.ring_memory)
	}
	if status == .Succeeded {
		words: rawptr
		words, status = memory_map(end.end_memory, {})
		end.end_words = (^output.End_Words)(words)
	}
	if status == .Succeeded && reader {
		pages: u64
		pages, status = memory_size(end.description_memory)
		address: rawptr
		if status == .Succeeded {
			address, status = memory_map(end.description_memory, {})
		}
		if status == .Succeeded {
			end.description_file = ([^]u8)(address)[:pages * PAGE_SIZE]
			described, ok := module.record_stream_type(end.description_file, output.DESCRIPTION_RECORD_INDEX)
			if !ok {
				status = .Argument_Refused
			}
			end.description = described
		}
	}
	if status != .Succeeded {
		stream_end_close(&end)
		return output.wiring_completion(record.tag, status, errors.error_make(.Refused, .Wirings, 0, 0, 0, i64(status)))
	}
	place^ = end
	return output.wiring_completion(record.tag, .Succeeded)
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
	// The words Closed that waited for room go first: an answer to a new
	// command then never takes their place.
	closed_words_send()
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
			completion = output.wiring_completion(record.tag, .Argument_Refused, refusal)
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
	// compared the record: the end is closed.
	if size == 0 || !ok {
		stream_end_finish(end)
		return false
	}
	// A condition that the record of this writer cannot hold comes from no
	// root service that read the description: the end is closed.
	if end.condition_given {
		checked, checked_ok := output.writer_condition_check(end.condition_bytes[:], record_size)
		if !checked_ok {
			stream_end_finish(end)
			return false
		}
		end.condition = checked
	}
	end.queue, end.opened = opened, true
	return true
}

// stream_end_ended gives the end word of an end, through its border. A
// word that the border refuses ends the end as Revoked: the root service
// alone writes the page, and a page that names nothing is no stream.
@(private = "file")
stream_end_ended :: proc "contextless" (end: ^Stream_End) -> (word: output.End_Word, stop_cause: op.Stop_Cause, stop_outcome: op.Stop_Outcome) {
	read, cause, outcome, ok := output.end_of_words(output.end_words_read(end.end_words))
	if !ok {
		return .Revoked, .None, .None
	}
	return read, cause, outcome
}

// ring_room gives what one ring does with the next write, decided before
// the write, from the counter read that it loads once into read_seen: a
// wait on that same value then misses no read of the reader. A write is
// whole or refused over the rings that hold the writer.
@(private = "file")
ring_room :: proc "contextless" (end: ^Stream_End) -> output.Ring_Room {
	queue := &end.queue.commands
	needed := u32(1)
	if !end.joined {
		needed += 1
	}
	if end.gap_count != 0 {
		needed += 1
	}
	write := intrinsics.atomic_load_explicit(&queue.counters.write, .Relaxed)
	end.read_seen = intrinsics.atomic_load_explicit(&queue.counters.read, .Acquire)
	return output.ring_room_of(write, end.read_seen, ring.compartment_capacity(queue), needed, end.pace)
}

// output_ends_of gives the live ends of a record output, after it took the
// ends of the wiring ring, removed each end that ended, and read the
// completions of each ring. A reader that refused a compartment closed its
// end, and a completion that the border refuses comes from no reader: the
// writer closes that end too, so it never feeds a ring that no one reads.
@(private = "file")
output_ends_of :: proc "contextless" (state: ^Output_State, record_size: u32, selector: End_Selector = {}) -> (live: int) {
	stream_ends_take()
	index := stream_index_read(&state.index)
	for &end in stream_ends {
		if !writer_end_in(&end, index, selector) || index == 0 {
			continue
		}
		if !stream_end_open(&end, record_size) {
			continue
		}
		if word, _, _ := stream_end_ended(&end); word != .None {
			state.last_end = word
			state.rings_ended += 1
			stream_end_close_by_word(&end, word)
			continue
		}
		refused := false
		for _ in 0 ..< ring.count(&end.queue.completions) {
			completion, ok := ring.pop(&end.queue.completions)
			if !ok {
				break
			}
			kind, _, _, known := output.completion_of_record(completion)
			if !known {
				state.rings_broken += 1
				refused = true
				break
			}
			if kind == .Bad_Record {
				state.refused_by_readers += 1
				refused = true
				break
			}
		}
		if refused {
			stream_end_finish(&end)
			continue
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
output_write :: proc "contextless" (stream: ^Record_Output($Record_Type, $pairing), record: Record_Type, wait := true, deadline: u64 = WAIT_FOREVER) -> output.Stream_Status where Record_Type != Any_Record {
	state := &stream.state
	if state.ended {
		return .Ended
	}
	copy_of_record := record
	bytes := ([^]u8)(&copy_of_record)[:size_of(Record_Type)]
	return output_write_bytes(state, bytes, wait, deadline)
}

// output_size_set gives a generic record output the size of its record:
// the size of the type that the wiring of its generic record input fixed,
// which the writer reads in the item of a read or in the description of
// its record input. Each ring of it has that record, so the library opens
// no ring before it knows the size: a generic writer calls it before its
// first write, its first gap and its end. false: a size of 0, past a
// record of a record description, or another size than the one set.
output_size_set :: proc "contextless" (stream: ^Record_Output(Any_Record, $pairing), size: u32) -> bool {
	if size == 0 || size > module.RECORD_SIZE_LIMIT {
		return false
	}
	if stream.state.record_size != 0 {
		return stream.state.record_size == size
	}
	stream.state.record_size = size
	return true
}

// output_write_any writes one record of a generic record output: bytes of
// the size that output_size_set gave, as a generic reader read them. A
// first write with no size set gives the size. Bad_Record: another size.
output_write_any :: proc "contextless" (stream: ^Record_Output(Any_Record, $pairing), bytes: []u8, wait := true, deadline: u64 = WAIT_FOREVER) -> output.Stream_Status {
	state := &stream.state
	if state.ended {
		return .Ended
	}
	if !output_size_set(stream, u32(len(bytes))) {
		return .Bad_Record
	}
	return output_write_bytes(state, bytes, wait, deadline)
}

// output_size_known says if the library knows the record size of a record
// output: always for a record type, after output_size_set for a generic
// one.
@(private = "file")
output_size_known :: proc "contextless" (stream: ^Record_Output($Record_Type, $pairing)) -> bool {
	when Record_Type == Any_Record {
		return stream.state.record_size != 0
	} else {
		return true
	}
}

// output_ends_live gives the live ends of a record output with the size of
// its record: the size of its type, or for a generic record output the size
// that output_size_set gave. A generic record output with no size yet opens
// no end: an end opened with another size would be closed.
@(private = "file")
output_ends_live :: proc "contextless" (stream: ^Record_Output($Record_Type, $pairing)) -> int {
	when Record_Type == Any_Record {
		if stream.state.record_size == 0 {
			return 0
		}
		return output_ends_of(&stream.state, stream.state.record_size, {any_principal = true})
	} else {
		return output_ends_of(&stream.state, u32(size_of(Record_Type)), {any_principal = true})
	}
}

@(private = "file")
output_write_bytes :: proc "contextless" (state: ^Output_State, bytes: []u8, wait: bool, deadline: u64, selector: End_Selector = {}) -> output.Stream_Status {
	if output.compartment_size(u32(len(bytes))) == 0 {
		return .Bad_Record
	}
	// The serial and the counts of the rings that this write reaches.
	cs := counts_of(state, selector)
	if cs == nil {
		return .Bad_Record
	}
	index := stream_index_read(&state.index)
	// An earlier look of this write waited: a wake before the room counts
	// no second hold.
	waited := false
	room_loop: for {
		if output_ends_of(state, u32(len(bytes)), selector) == 0 {
			cs.discarded += 1
			cs.next_serial += 1
			return .No_Reader
		}
		// A ring whose condition the record fails takes nothing of this
		// write, and holds the writer for nothing.
		for &end in stream_ends {
			if writer_end_in(&end, index, selector) && end.opened {
				end.skips = end.condition_given && !output.writer_condition_holds(end.condition, bytes)
			}
		}
		// One pass decides and builds the wait: each ring that holds the
		// writer is waited on with the read that its decision loaded, so a
		// reader that reads, or reads all and waits, between the decision
		// and the wait ends the wait at once.
		waiting: Wait
		when ODIN_OS != .Freestanding {
			if !stream_ends_host_seam_active {
				waiting = wait_begin()
			}
		} else {
			waiting = wait_begin()
		}
		held_by_choice, held_always, broken := false, false, false
		for &end in stream_ends {
			if !writer_end_in(&end, index, selector) || !end.opened {
				continue
			}
			// A ring that skips the record is not read: it holds nothing.
			room := end.skips ? output.Ring_Room.Room : ring_room(&end)
			end.holds_at_look = false
			switch output.ring_part_of(end.skips, room, end.pace) {
			case .Broken:
				// A count of the reader past the write of the writer: no
				// honest reader writes one, and no wait on it ever ends.
				state.rings_broken += 1
				stream_end_finish(&end)
				broken = true
			case .Holds_By_Choice, .Holds_Always:
				end.holds_at_look = true
				if end.pace == .Always_Holds_Writer {
					held_always = true
				} else {
					held_by_choice = true
				}
				counters := end.queue.commands.counters
				wait_word(&waiting, &counters.read, end.read_seen, &counters.writer_waits, &counters.reader_waits, &counters.write)
				wait_word(&waiting, &end.end_words.end, u32(output.End_Word.None))
			case .Skipped, .Takes, .Refuses:
			}
		}
		// A ring that closed changes the set of the rings: decide again.
		if broken {
			continue room_loop
		}
		closed_words_wait(&waiting)
		// The counts of this look come from one pure rule
		// (output.write_counts_after): a write counts once in held, and a
		// write that waited and reached its deadline counts in held and in
		// refused.
		step := output.write_step_of(held_by_choice, held_always, wait)
		looked := output.write_counts_after({refused = cs.refused, held = cs.held}, step, waited, false)
		cs.refused, cs.held = looked.refused, looked.held
		switch step {
		case .Write:
			refused_full_mark(index, false, selector)
			break room_loop
		case .Full:
			refused_full_mark(index, true, selector)
			return .Full
		case .Wait:
			waited = true
			if wait_end(&waiting, deadline) >= deadline {
				timed_out := output.write_counts_after({refused = cs.refused, held = cs.held}, .Wait, true, true)
				cs.refused, cs.held = timed_out.refused, timed_out.held
				refused_full_mark(index, true, selector)
				return .Full
			}
		}
	}
	serial := cs.next_serial
	// The counts before this record. Each write publishes them again, so a
	// reader reads the counts of the last write before its read, at least
	// as new as the compartment that it took
	// (src/md/features/module_outputs.md, "The counts of a record output").
	// A ring of one principal reads the counts of that principal only.
	counts := output.Writer_Counts{written = cs.written, discarded = cs.discarded, refused = cs.refused, held = cs.held, rings_past_gap = cs.rings_past_gap}
	taken := false
	for &end in stream_ends {
		if !writer_end_in(&end, index, selector) || !end.opened {
			continue
		}
		output.writer_counts_write(end.ring_address, counts)
		if end.skips {
			// The joined record comes with the first write after the take,
			// also when the ring skips the record: "joined after N" keeps
			// its count, and a reader of a condition that never passes
			// still learns that it joined. A new ring has room for it.
			if !end.joined && ring_room(&end) == .Room {
				end.joined = compartment_push_to(&end, .Joined, serial)
				if end.joined {
					counters_wake_reader(end.queue.commands.counters)
				}
			}
			continue
		}
		if !end.joined {
			// The first compartment of each ring: the serial of the next
			// record, the count of the records before this reader joined.
			end.joined = compartment_push_to(&end, .Joined, serial)
		}
		room := ring_room(&end)
		// The record is taken only by a ring with room for it: a ring that
		// refuses it, or a ring that broke, takes nothing
		// (output.ring_takes_record).
		if output.ring_takes_record(false, room) {
			taken = true
		}
		if room == .Broken {
			state.rings_broken += 1
			stream_end_finish(&end)
			continue
		}
		if room == .Refuses {
			gap, step := output.gap_after_refused_record({count = end.gap_count, first = end.gap_first}, serial, end.condition_given)
			switch step {
			case .Counted:
				end.gap_count, end.gap_first = gap.count, gap.first
			case .Past_The_Count, .Not_Contiguous:
				// One more would give a gap that its reader refuses: the
				// stream of this reader ends, and it reads Side_Closed
				// after the records that its ring holds. The other rings
				// of this write go on. A refused record never gives
				// Not_Contiguous: it is the same end.
				cs.rings_past_gap += 1
				stream_end_finish(&end)
			}
			continue
		}
		if end.gap_count != 0 && compartment_push_to(&end, .Gap, end.gap_first, gap = end.gap_count) {
			end.gap_count = 0
		}
		compartment_push_to(&end, .Record, serial, bytes)
		counters_wake_reader(end.queue.commands.counters)
	}
	cs.next_serial += 1
	// A record that the condition of each ring left out, or that each ring
	// refused for its reader, is taken by no ring: it counts as discarded,
	// as a record with no reader. Each ring that refused it counts it in
	// its gap.
	after := output.counts_after_write(counts, taken)
	cs.written, cs.discarded = after.written, after.discarded
	return .Ok
}

// counts_of gives the serial and the counts of the rings that a selector
// reaches: those of one reader principal, or of the whole record output.
// nil: a principal past SCOPED_PRINCIPALS_MOST, whose rings take nothing.
@(private = "file")
counts_of :: proc "contextless" (state: ^Output_State, selector: End_Selector) -> ^Serial_Counts {
	if selector.reader_principal == 0 {
		return &state.counts
	}
	if selector.reader_principal > SCOPED_PRINCIPALS_MOST {
		return nil
	}
	return &state.scoped[selector.reader_principal - 1]
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
	// A generic record output with no size opens no ring: its end would
	// reach no reader, so it is refused, not given as done.
	if !output_size_known(stream) {
		return .Bad_Record
	}
	output_ends_live(stream)
	status := output.Stream_Status.Ok
	index := stream_index_read(&state.index)
	for &end in stream_ends {
		if end.command != .Writer_End || end.index != index || !end.opened {
			continue
		}
		if writer_end_close_with_record(state, &end, error, deadline) == .Full {
			status = .Full
		}
	}
	state.ended = true
	return status
}

// writer_end_close_with_record writes the end record into one ring when
// it has room, until deadline, then closes the end. Full: the ring had no
// room by then; it ends with its end word when the process stops.
@(private = "file")
writer_end_close_with_record :: proc "contextless" (state: ^Output_State, end: ^Stream_End, error: errors.Error_Record, deadline: u64) -> output.Stream_Status {
	status := output.Stream_Status.Ok
	ended_by := output.End_Word.None
	for {
		// The read is loaded before the push: a reader that reads after
		// a refused push changes it, and the wait ends at once.
		waiting: Wait
		when ODIN_OS != .Freestanding {
			if !stream_ends_host_seam_active {
				waiting = wait_begin()
			}
		} else {
			waiting = wait_begin()
		}
		if ring_room(end) == .Broken {
			state.rings_broken += 1
			break
		}
		cs := counts_of(state, {reader_principal = end.reader_principal})
		serial := cs != nil ? cs.next_serial : state.next_serial
		if !end.joined {
			end.joined = compartment_push_to(end, .Joined, serial)
		}
		if end.joined && compartment_push_to(end, .End, serial, error = error) {
			counters_wake_reader(end.queue.commands.counters)
			break
		}
		counters := end.queue.commands.counters
		wait_word(&waiting, &counters.read, end.read_seen, &counters.writer_waits, &counters.reader_waits, &counters.write)
		wait_word(&waiting, &end.end_words.end, u32(output.End_Word.None))
		closed_words_wait(&waiting)
		if wait_end(&waiting, deadline) >= deadline {
			status = .Full
			break
		}
		closed_words_send()
		if word, _, _ := stream_end_ended(end); word != .None {
			state.last_end = word
			ended_by = word
			break
		}
	}
	if ended_by != .None {
		stream_end_close_by_word(end, ended_by)
	} else {
		stream_end_finish(end)
	}
	return status
}

// output_write_pair writes one record of a record output Paired into the
// rings of one pair: pair is the number of the wiring of the source, the
// tag of the item of its read. The record has the size of the record of
// that source, which the rings of the pair took from the root service. A
// write is whole or refused over those rings, as output_write; the other
// pairs see nothing of it, and the serial of the record output moves for
// each, so the reader of a pair reads serials that move forward by any
// count (output.Reader_Filter.By_Writer). No_Reader: the pair has no ring
// now. Bad_Record: pair 0, or a size that no record takes.
output_write_pair :: proc "contextless" (stream: ^Record_Output(Any_Record, module.Record_Output_Pairing.Paired), pair: u32, bytes: []u8, wait := true, deadline: u64 = WAIT_FOREVER) -> output.Stream_Status {
	state := &stream.state
	if state.ended {
		return .Ended
	}
	if pair == 0 || output.compartment_size(u32(len(bytes))) == 0 {
		return .Bad_Record
	}
	return output_write_bytes(state, bytes, wait, deadline, {pair = pair})
}

// output_pair_rings gives the live rings of one pair of a record output
// Paired, whose record has record_size bytes, after it took the ends of the
// wiring ring and closed each ring that ended.
output_pair_rings :: proc "contextless" (stream: ^Record_Output(Any_Record, module.Record_Output_Pairing.Paired), pair: u32, record_size: u32) -> int {
	if pair == 0 || output.compartment_size(record_size) == 0 {
		return 0
	}
	return output_ends_of(&stream.state, record_size, {pair = pair})
}

// output_pairs writes the pairs of the writer ends that a record output
// Paired holds now, after it took the ends of the wiring ring, each pair
// once, and gives their count: at most len(into).
output_pairs :: proc "contextless" (stream: ^Record_Output(Any_Record, module.Record_Output_Pairing.Paired), into: []u32) -> (count: int) {
	stream_ends_take()
	index := stream_index_read(&stream.state.index)
	if index == 0 {
		return 0
	}
	ends: for &end in stream_ends {
		if end.command != .Writer_End || end.index != index || end.pair == 0 {
			continue
		}
		for listed in into[:count] {
			if listed == end.pair {
				continue ends
			}
		}
		if count < len(into) {
			into[count] = end.pair
			count += 1
		}
	}
	return count
}

// output_pair_close closes each writer end of one pair of a record output
// Paired, with no end record, and says Closed to the root service: its
// reader reads Side_Closed after the records that its ring holds. It
// needs no size of a record, so it closes an end that no write opened: the
// end of a pair whose source the process does not keep. It gives the
// count of the ends that it closed.
output_pair_close :: proc "contextless" (stream: ^Record_Output(Any_Record, module.Record_Output_Pairing.Paired), pair: u32) -> (closed: int) {
	index := stream_index_read(&stream.state.index)
	if index == 0 || pair == 0 {
		return 0
	}
	for &end in stream_ends {
		if writer_end_in(&end, index, {pair = pair}) {
			stream_end_finish(&end)
			closed += 1
		}
	}
	return closed
}

// output_end_pair ends the rings of one pair of a record output Paired: an
// end record with error, zero for a clean end, then the close of each of
// its rings, as output_end does for each ring. The other pairs go on.
// No_Reader: the pair has no ring. Full: a ring had no room by deadline.
output_end_pair :: proc "contextless" (stream: ^Record_Output(Any_Record, module.Record_Output_Pairing.Paired), pair: u32, record_size: u32, error: errors.Error_Record = {}, deadline: u64 = WAIT_FOREVER) -> output.Stream_Status {
	state := &stream.state
	if state.ended {
		return .Ended
	}
	if output_pair_rings(stream, pair, record_size) == 0 {
		return .No_Reader
	}
	status := output.Stream_Status.Ok
	index := stream_index_read(&state.index)
	for &end in stream_ends {
		if !writer_end_in(&end, index, {pair = pair}) || !end.opened {
			continue
		}
		if writer_end_close_with_record(state, &end, error, deadline) == .Full {
			status = .Full
		}
	}
	return status
}

// output_write_principal writes one record of a record output
// By_Principal into the rings whose reader is of one principal, which the
// wiring service named on each writer end: the other rings see nothing of
// it, and the serial of the record output moves for each, so a reader reads
// serials that move forward by any count (output.Reader_Filter.By_Writer).
// A ring whose reader principal is not known takes no record of this call.
// No_Reader: no ring of that principal now. Bad_Record: a principal past
// the field of a grant.
output_write_principal :: proc "contextless" (stream: ^Record_Output($Record_Type, module.Record_Output_Pairing.By_Principal), principal: u64, record: Record_Type, wait := true, deadline: u64 = WAIT_FOREVER) -> output.Stream_Status where Record_Type != Any_Record {
	state := &stream.state
	if state.ended {
		return .Ended
	}
	// A principal past the counted ones has no ring and no serial.
	if principal >= SCOPED_PRINCIPALS_MOST {
		return .Bad_Record
	}
	local := record
	bytes := ([^]u8)(&local)[:size_of(Record_Type)]
	return output_write_bytes(state, bytes, wait, deadline, {reader_principal = principal + 1})
}

// output_principal_rings gives the live rings of the readers of one
// principal of a record output By_Principal.
output_principal_rings :: proc "contextless" (stream: ^Record_Output($Record_Type, module.Record_Output_Pairing.By_Principal), principal: u64) -> int {
	if principal >= SCOPED_PRINCIPALS_MOST {
		return 0
	}
	return output_ends_of(&stream.state, u32(size_of(Record_Type)), {reader_principal = principal + 1})
}

// output_gap says to each reader of a record output that the writer lost
// count records before it wrote them: the records of the log of the kernel
// that it wrote over before log.follow read them. The serials of those
// records are the next count serials, which no ring receives; each ring
// receives one gap record of them in their place, before the next record,
// as for the records that its own ring refused. A ring with room takes the
// gap record now; another one keeps it with its own gap, and the next write
// gives it. A count of 0 loses nothing and writes nothing. It never waits.
// With no reader, the serials still move: a reader that joins later learns
// them in its joined record.
output_gap :: proc "contextless" (stream: ^Record_Output($Record_Type, $pairing), count: u32) -> output.Stream_Status {
	state := &stream.state
	if state.ended {
		return .Ended
	}
	if count == 0 {
		return .Ok
	}
	// A generic record output with no size cannot say the loss to a ring.
	if !output_size_known(stream) {
		return .Bad_Record
	}
	when pairing == .By_Principal {
		// A record output of principals says a loss to the rings of one
		// principal only: output_gap_principal.
		return .Bad_Record
	}
	record_size := u32(size_of(Record_Type))
	when Record_Type == Any_Record {
		record_size = state.record_size
	}
	return output_gap_bytes(state, record_size, count, {})
}

// output_gap_principal says a loss of count records to the rings of the
// readers of one principal of a record output By_Principal, with the serial
// and the counts of that principal: the rings of another principal learn
// nothing of it.
output_gap_principal :: proc "contextless" (stream: ^Record_Output($Record_Type, module.Record_Output_Pairing.By_Principal), principal: u64, count: u32) -> output.Stream_Status where Record_Type != Any_Record {
	state := &stream.state
	if state.ended {
		return .Ended
	}
	if principal >= SCOPED_PRINCIPALS_MOST {
		return .Bad_Record
	}
	if count == 0 {
		return .Ok
	}
	return output_gap_bytes(state, u32(size_of(Record_Type)), count, {reader_principal = principal + 1})
}

@(private = "file")
output_gap_bytes :: proc "contextless" (state: ^Output_State, record_size: u32, count: u32, selector: End_Selector) -> output.Stream_Status {
	cs := counts_of(state, selector)
	if cs == nil {
		return .Bad_Record
	}
	if output_ends_of(state, record_size, selector) == 0 {
		cs.next_serial += count
		return .No_Reader
	}
	index := stream_index_read(&state.index)
	first := cs.next_serial
	// The counts as of this call, in each ring, as each write publishes
	// them: a reader that reads the gap reads counts at least as new.
	counts := output.Writer_Counts{written = cs.written, discarded = cs.discarded, refused = cs.refused, held = cs.held, rings_past_gap = cs.rings_past_gap}
	for &end in stream_ends {
		if !writer_end_in(&end, index, selector) || !end.opened {
			continue
		}
		output.writer_counts_write(end.ring_address, counts)
		gap, step := output.gap_after_lost_records({count = end.gap_count, first = end.gap_first}, first, count, end.condition_given)
		switch step {
		case .Counted:
			end.gap_count, end.gap_first = gap.count, gap.first
		case .Past_The_Count, .Not_Contiguous:
			// A gap past its largest count, or one that cannot say both
			// losses, would give a reader a serial that it cannot place:
			// the stream of this reader ends.
			cs.rings_past_gap += 1
			stream_end_finish(&end)
			continue
		}
		room := ring_room(&end)
		if room == .Broken {
			state.rings_broken += 1
			stream_end_finish(&end)
			continue
		}
		if room != .Room {
			continue
		}
		pushed := false
		if !end.joined {
			end.joined = compartment_push_to(&end, .Joined, first)
			pushed = end.joined
		}
		if end.joined && compartment_push_to(&end, .Gap, end.gap_first, gap = end.gap_count) {
			end.gap_count = 0
			pushed = true
		}
		if pushed {
			counters_wake_reader(end.queue.commands.counters)
		}
	}
	cs.next_serial += count
	return .Ok
}

// wait_output_room adds to a wait that the caller builds the room of each
// ring of a record output that refused the last write with Full, and has
// no room yet at the read of that write (output.room_wait_of): a writer
// that keeps its place on Full, and waits on other things too, wakes when
// the reader of such a ring reads, as output_write wakes when it holds, or
// when the ring ends. It decides with the read that the last write loaded
// (read_seen), and waits on that same value: it never loads the read
// again, so a reader that drained the ring between the Full of the write
// and this wait ends the wait at once. A ring of the pace
// Never_Holds_Writer, which refuses its record for its own reader, and a
// ring with room at that read add nothing.
//
// Each ring takes OUTPUT_ROOM_WAIT_WORDS words of the list, which holds
// the places of its wait (wait_room_left); a word that does not fit is
// refused, and the wait then ends only at its deadline. So the caller
// gives the most rings that its list has room for, and asserts its sum at
// compile time. A full ring past that count is not waited on: its reader gets the
// row that waits at the next wake of the writer for another cause. It
// gives the count of those rings, for a count of the caller.
OUTPUT_ROOM_WAIT_WORDS :: 3 // The read and its flag, and the end word.
wait_output_room :: proc "contextless" (waiting: ^Wait, stream: ^Record_Output($Record_Type, $pairing), most: int) -> (not_waited: int) {
	state := &stream.state
	if state.ended {
		return 0
	}
	index := stream_index_read(&state.index)
	waited := 0
	for &end in stream_ends {
		if end.command != .Writer_End || end.index != index || !end.opened {
			continue
		}
		if !output.room_wait_of(end.refused_full, ring_room_seen(&end)) {
			continue
		}
		if waited >= most {
			not_waited += 1
			continue
		}
		waited += 1
		counters := end.queue.commands.counters
		wait_word(waiting, &counters.read, end.read_seen, &counters.writer_waits, &counters.reader_waits, &counters.write)
		wait_word(waiting, &end.end_words.end, u32(output.End_Word.None))
	}
	return not_waited
}

// ring_room_seen gives what one ring does with the next write, from the
// read that the last decision loaded (read_seen), with no new load: the
// value that a wait then waits on.
@(private = "file")
ring_room_seen :: proc "contextless" (end: ^Stream_End) -> output.Ring_Room {
	queue := &end.queue.commands
	needed := u32(1)
	if !end.joined {
		needed += 1
	}
	if end.gap_count != 0 {
		needed += 1
	}
	write := intrinsics.atomic_load_explicit(&queue.counters.write, .Relaxed)
	return output.ring_room_of(write, end.read_seen, ring.compartment_capacity(queue), needed, end.pace)
}

// output_read_by says if a record output has a reader now: a writer that
// builds a costly record asks it first.
output_read_by :: proc "contextless" (stream: ^Record_Output($Record_Type, $pairing)) -> bool {
	return output_ends_live(stream) > 0
}

// output_reader_count gives the readers of a record output now.
output_reader_count :: proc "contextless" (stream: ^Record_Output($Record_Type, $pairing)) -> int {
	return output_ends_live(stream)
}

// What a read gives besides the record: the kind of the compartment and
// what its kind says, or the end word.
Input_Item :: struct {
	kind:         output.Compartment_Kind, // Record, Joined, Gap or End.
	serial:       u32, // A record: its serial. Joined: the serial of the next record. Gap: the first missing serial. End: the count of the records.
	gap_count:    u32, // Gap: the records that the reader misses.
	error:        errors.Error_Record, // End: zero for a clean end.
	end_word:     output.End_Word, // Ended by an end word: why; None for an end record.
	stop_cause:   op.Stop_Cause, // Writer_Stopped: the stop of the writer, through the border of the end words.
	stop_outcome: op.Stop_Outcome,
	refusal:      errors.Error_Record, // Bad_Record: the error record that names the field.
	// The ring of the item: the number of its wiring. A record input of the
	// counts Many and Many_Types reads several rings, and its reader tells
	// them apart by it: their serials, joined records and ends are each of
	// one ring. 0 when no ring gave the item.
	tag:          u32,
	// The size of the record of that ring, from its description file: a
	// generic reader copies that many bytes, and writes them on.
	record_size:  u32,
}

// input_read reads the next compartment of a record input: a record, which
// it copies into into, or a joined record, a gap record, or the end. It
// waits for one until deadline: No_Record past it. No_Writer: the record
// input has no ring. A compartment that the border refuses gives
// Bad_Record, with its error record in the item, and a completion that
// tells the writer.
input_read :: proc "contextless" (stream: ^Record_Input($Record_Type, $wirings), into: ^Record_Type, deadline: u64 = WAIT_FOREVER) -> (item: Input_Item, status: output.Stream_Status) {
	return input_state_read(&stream.state, ([^]u8)(into)[:size_of(Record_Type)], false, deadline)
}

// input_read_any reads the next compartment of a generic record input
// (src/md/features/module_outputs.md, "Generic record inputs and the
// utility modules"): into holds the largest record that a ring of it can
// carry, module.RECORD_SIZE_LIMIT bytes, and the record takes its first
// item.record_size bytes. Each ring of the record input has the record of
// its wiring: one type for the counts One and Many, a type for each ring
// for Many_Types. The rings are read in turn, each in its order; no order
// across rings is given.
input_read_any :: proc {
	input_read_any_plain,
	input_read_any_with_terms,
}

input_read_any_plain :: proc "contextless" (stream: ^Record_Input(Any_Record, $wirings), into: []u8, deadline: u64 = WAIT_FOREVER) -> (item: Input_Item, status: output.Stream_Status) {
	return input_state_read(&stream.state, into, true, deadline)
}

input_read_any_with_terms :: proc "contextless" (stream: ^Record_Input_With_Terms(Any_Record, $Terms_Type, $wirings), into: []u8, deadline: u64 = WAIT_FOREVER) -> (item: Input_Item, status: output.Stream_Status) {
	return input_state_read(&stream.state, into, true, deadline)
}

// input_state_read is the one read of a record input, of a record or
// generic.
@(private = "file")
input_state_read :: proc "contextless" (state: ^Input_State, into: []u8, generic: bool, deadline: u64, tag: u32 = 0) -> (item: Input_Item, status: output.Stream_Status) {
	index := stream_index_read(&state.index)
	if index == 0 {
		return {}, .No_Writer
	}
	item, status = stream_read(.Reader_End, index, tag, into, deadline, generic = generic, turn = &state.turn)
	if status == .Ok && item.kind == .Record {
		state.read += 1
	}
	return item, status
}

// input_read_from reads the next compartment of one ring of a generic
// record input with terms: the ring of the wiring tag. A reader that keeps
// a record before it reads the next one reads each source by itself, so a
// source that it cannot keep yet stays in its ring and holds its writer,
// and the other sources go on. No_Writer: the record input holds no ring
// of that wiring, or tag 0, which names none.
input_read_from :: proc "contextless" (stream: ^Record_Input_With_Terms(Any_Record, $Terms_Type, $wirings), tag: u32, into: []u8, deadline: u64 = WAIT_FOREVER) -> (item: Input_Item, status: output.Stream_Status) {
	if tag == 0 {
		return {}, .No_Writer
	}
	return input_state_read(&stream.state, into, true, deadline, tag)
}

// input_tags writes the tags of the rings that a record input holds now,
// after it took the ends that wait in the wiring ring, and gives their
// count: at most len(into).
input_tags :: proc "contextless" (stream: ^Record_Input_With_Terms($Record_Type, $Terms_Type, $wirings), into: []u32) -> (count: int) {
	stream_ends_take()
	index := stream_index_read(&stream.state.index)
	if index == 0 {
		return 0
	}
	for &end in stream_ends {
		if end.command == .Reader_End && end.index == index && count < len(into) {
			into[count] = end.tag
			count += 1
		}
	}
	return count
}

// input_source_names gives the names of the source of one ring of a
// record input with terms: the module name of the writer process and the
// name of its record output, which the root service wrote after the terms
// (output.Source_Names). It copies them once, then checks the copy. false:
// no such ring, no terms, or names that the border refuses.
input_source_names :: proc "contextless" (stream: ^Record_Input_With_Terms($Record_Type, $Terms_Type, $wirings), tag: u32) -> (names: output.Source_Names, source_length: int, output_length: int, ok: bool) {
	end := input_end_of(&stream.state, tag) or_return
	if end.terms_memory == 0 {
		return {}, 0, 0, false
	}
	pages, size_status := memory_size(end.terms_memory)
	if size_status != .Succeeded || pages * PAGE_SIZE < output.SOURCE_NAMES_PAGE_BYTES {
		return {}, 0, 0, false
	}
	address, status := memory_map(end.terms_memory, {})
	if status != .Succeeded {
		return {}, 0, 0, false
	}
	defer memory_unmap(address)
	return output.source_names_of_page(([^]u8)(address)[:output.SOURCE_NAMES_PAGE_BYTES])
}

// input_close closes the ring of the wiring tag of a record input, and
// says Closed to the root service: its writer reads Side_Closed after the
// records that the ring holds. A reader that cannot keep a source closes
// it, so its writer never waits for a reader that does not read. false: no
// such ring.
input_close :: proc "contextless" (stream: ^Record_Input_With_Terms($Record_Type, $Terms_Type, $wirings), tag: u32) -> bool {
	if tag == 0 {
		return false
	}
	end := input_end_of(&stream.state, tag) or_return
	stream_end_finish(end)
	return true
}

// wait_input_records adds to a wait that the caller builds each ring of a
// record input with terms that the last read found empty: a write of its
// writer, or its end word, ends the wait. It waits on the write that the
// read loaded (write_seen), so a record that the writer pushed after that
// read ends the wait at once. Each ring takes INPUT_RECORDS_WAIT_WORDS
// words; the caller gives the most rings that its list holds, and gets the
// count of the rings past it.
INPUT_RECORDS_WAIT_WORDS :: 3 // The write and its flag, and the end word.
wait_input_records :: proc "contextless" (waiting: ^Wait, stream: ^Record_Input_With_Terms($Record_Type, $Terms_Type, $wirings), most: int) -> (not_waited: int) {
	index := stream_index_read(&stream.state.index)
	waited := 0
	for &end in stream_ends {
		if end.command != .Reader_End || end.index != index || index == 0 || !end.opened {
			continue
		}
		if waited >= most {
			not_waited += 1
			continue
		}
		waited += 1
		counters := end.queue.commands.counters
		wait_word(waiting, &counters.write, end.write_seen, &counters.reader_waits, &counters.writer_waits, &counters.read)
		wait_word(waiting, &end.end_words.end, u32(output.End_Word.None))
	}
	return not_waited
}

// input_terms copies the wiring terms of one ring of a record input into
// into: the ring of the wiring tag, or with tag 0 the first ring that the
// record input holds, its one ring for the count One. The root service
// checked their size against the description of the terms; the reader
// checks their fields, as each record. false: no such ring, or no terms.
input_terms :: proc "contextless" (stream: ^Record_Input_With_Terms($Record_Type, $Terms_Type, $wirings), into: ^Terms_Type, tag: u32 = 0) -> bool {
	end := input_end_of(&stream.state, tag) or_return
	if end.terms_memory == 0 {
		return false
	}
	address, status := memory_map(end.terms_memory, {})
	if status != .Succeeded {
		return false
	}
	defer memory_unmap(address)
	intrinsics.mem_copy_non_overlapping(into, address, size_of(Terms_Type))
	return true
}

// input_description gives the description file and the record description
// of one ring of a record input, as input_terms names it: what a generic
// reader checks each record against, and what it reads its fields from.
input_description :: proc {
	input_description_plain,
	input_description_with_terms,
}

input_description_plain :: proc "contextless" (stream: ^Record_Input($Record_Type, $wirings), tag: u32 = 0) -> (file: []u8, description: module.Record, ok: bool) {
	end := input_end_of(&stream.state, tag) or_return
	return end.description_file, end.description, true
}

input_description_with_terms :: proc "contextless" (stream: ^Record_Input_With_Terms($Record_Type, $Terms_Type, $wirings), tag: u32 = 0) -> (file: []u8, description: module.Record, ok: bool) {
	end := input_end_of(&stream.state, tag) or_return
	return end.description_file, end.description, true
}

// input_end_of gives the end of a record input of the wiring tag, or with
// tag 0 the first one, after it took the ends that the wiring ring holds.
@(private = "file")
input_end_of :: proc "contextless" (state: ^Input_State, tag: u32) -> (end: ^Stream_End, ok: bool) {
	stream_ends_take()
	index := stream_index_read(&state.index)
	if index == 0 {
		return nil, false
	}
	for &item in stream_ends {
		if item.command == .Reader_End && item.index == index && (tag == 0 || item.tag == tag) {
			return &item, true
		}
	}
	return nil, false
}

// asker_read reads the next compartment of a wiring whose reader is this
// process as its asker: number is the number of the wiring that the
// completion of Wire or Start gave.
asker_read :: proc "contextless" (number: u32, into: ^$Record_Type, deadline: u64 = WAIT_FOREVER) -> (item: Input_Item, status: output.Stream_Status) {
	return stream_read(.Asker_End, 0, number, ([^]u8)(into)[:size_of(Record_Type)], deadline)
}

// asker_read_bytes is asker_read for a reader that knows the size of the
// record only when it runs, as the console does: into has the size of the
// record description of the wiring, and an end of another size is closed.
// wake_word, when it is not nil, ends the wait as soon as it holds another
// value than wake_value: the read then gives No_Record, before its
// deadline. The console passes the word that Escape changes, so a read
// that waits ends at once, with no poll.
asker_read_bytes :: proc "contextless" (number: u32, into: []u8, deadline: u64 = WAIT_FOREVER, wake_word: ^u32 = nil, wake_value: u32 = 0) -> (item: Input_Item, status: output.Stream_Status) {
	return stream_read(.Asker_End, 0, number, into, deadline, wake_word, wake_value)
}

// asker_writer_counts gives the counts that the writer of a wiring whose
// reader is this process as its asker published in the head page of its
// ring: its claim as of the last compartment that this process took. ok is
// false while this process holds no open end of the wiring.
asker_writer_counts :: proc "contextless" (number: u32) -> (counts: output.Writer_Counts, ok: bool) {
	for &end in stream_ends {
		if end.command == .Asker_End && end.tag == number && end.opened && end.ring_address != nil {
			return output.writer_counts_read(end.ring_address), true
		}
	}
	return {}, false
}

// asker_close closes the end of a wiring whose reader is this process as
// its asker, before the end of its stream: the root service reads the word
// Closed, and the writer reads the end word Side_Closed. false: this
// process holds no such end, as after the end of its stream.
asker_close :: proc "contextless" (number: u32) -> bool {
	stream_ends_take()
	for &end in stream_ends {
		if end.command == .Asker_End && end.tag == number {
			stream_end_finish(&end)
			return true
		}
	}
	return false
}


// stream_read is the reader of input_read and asker_read: the ends of one
// record input, or the one end of an asker. A record input reads its ends
// in turn from turn, the place after the end that gave the last item
// (output.ring_turn_next), so a fast ring keeps no slow one out; no order
// across rings is given. A generic reader takes an end of any record that
// into holds, and copies its record into the first bytes of into; any
// other reader takes only an end of the size of into, its record.
@(private = "file")
stream_read :: proc "contextless" (command: output.Wiring_Command, index: u32, tag: u32, into: []u8, deadline: u64, wake_word: ^u32 = nil, wake_value: u32 = 0, generic := false, turn: ^u32 = nil) -> (item: Input_Item, status: output.Stream_Status) {
	for {
		if wake_word != nil && intrinsics.atomic_load(wake_word) != wake_value {
			return {}, .No_Record
		}
		stream_ends_take()
		found := false
		start := turn != nil ? int(turn^) % len(stream_ends) : 0
		for offset in 0 ..< len(stream_ends) {
			place := (start + offset) % len(stream_ends)
			end := &stream_ends[place]
			if end.command != command || (command == .Reader_End && (end.index != index || (tag != 0 && end.tag != tag))) || (command == .Asker_End && end.tag != tag) {
				continue
			}
			// The record of the variable has the size of the description
			// that the root service compared: an end of another size is no
			// end of this variable. A generic variable takes the record of
			// each wiring, up to the size of its buffer.
			fits := generic ? end.description.size <= u32(len(into)) : end.description.size == u32(len(into))
			if !fits || !stream_end_open(end, end.description.size) {
				if end.command != .None {
					stream_end_finish(end)
				}
				continue
			}
			found = true
			ring_tag, record_size := end.tag, end.description.size
			read, read_status, done := stream_end_read(end, into[:record_size])
			if done {
				read.tag, read.record_size = ring_tag, record_size
				if turn != nil {
					turn^ = u32(output.ring_turn_next(place, len(stream_ends)))
				}
				return read, read_status
			}
		}
		if !found {
			return {}, .No_Writer
		}
		// Add the fixed words first so they always fit; each ring then needs
		// only READER_WAIT_WORDS_OF_A_RING (events was added by wait_begin,
		// so READER_WAIT_WORDS_BESIDE_RINGS is never double-counted).
		waiting := wait_begin(&reader_wait.set)
		if wiring_ring.head != nil {
			wait_records(&waiting, &wiring_ring.commands)
		}
		if wake_word != nil {
			wait_word(&waiting, wake_word, wake_value)
		}
		closed_words_wait(&waiting)
		for &end in stream_ends {
			if end.command != command || !end.opened || (command == .Reader_End && (end.index != index || (tag != 0 && end.tag != tag))) || (command == .Asker_End && end.tag != tag) {
				continue
			}
			if wait_room_left(&waiting) < output.READER_WAIT_WORDS_OF_A_RING {
				break
			}
			// The write that stream_end_read loaded when it found the ring
			// empty: a record that the writer pushed after that load ends
			// the wait at once.
			counters := end.queue.commands.counters
			wait_word(&waiting, &counters.write, end.write_seen, &counters.reader_waits, &counters.writer_waits, &counters.read)
			wait_word(&waiting, &end.end_words.end, u32(output.End_Word.None))
		}
		if wait_end(&waiting, deadline) >= deadline {
			return {}, .No_Record
		}
	}
}

// stream_end_read reads one compartment of one end. done is false when the
// ring has nothing now: write_seen then holds the write that it loaded,
// for the wait. It loads each counter of the writer once, and refuses a
// ring whose counters no honest writer writes (output.
// reader_ring_fault_of): a count past the capacity, or a completion queue
// that the writer never empties. Such a ring is closed with Bad_Record,
// never read again, and never waited on.
@(private = "file")
stream_end_read :: proc "contextless" (end: ^Stream_End, into: []u8) -> (item: Input_Item, status: output.Stream_Status, done: bool) {
	commands := end.queue.commands.counters
	completions := end.queue.completions.counters
	write := intrinsics.atomic_load_explicit(&commands.write, .Acquire)
	read := intrinsics.atomic_load_explicit(&commands.read, .Relaxed)
	completions_write := intrinsics.atomic_load_explicit(&completions.write, .Relaxed)
	completions_read := intrinsics.atomic_load_explicit(&completions.read, .Acquire)
	ring_fault, ring_refusal := output.reader_ring_fault_of(write, read, ring.compartment_capacity(&end.queue.commands), completions_write, completions_read, ring.capacity(&end.queue.completions))
	if ring_fault != .None {
		stream_end_finish(end)
		return {kind = .Record, refusal = ring_refusal}, .Bad_Record, true
	}
	end.write_seen = write
	size := int(end.queue.commands.compartment_size)
	buffer := read_compartment[:size]
	if write == read || !ring.compartment_pop(&end.queue.commands, buffer) {
		// The end word only when the queue is empty: each record that the
		// writer published before its stop comes first. A record pushed
		// after the load of write and before the end word is read first:
		// the wait on write_seen ends at once.
		word, cause, outcome := stream_end_ended(end)
		if word == .None || intrinsics.atomic_load_explicit(&commands.write, .Acquire) != write {
			return {}, .Ok, false
		}
		stream_end_close_by_word(end, word)
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
		stream_end_finish(end)
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
		stream_end_finish(end)
		return item, .Ended, true
	}
	return item, .Ok, true
}
