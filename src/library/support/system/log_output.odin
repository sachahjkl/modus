package system

import "base:intrinsics"
import op "modus:contract/operation"
import "modus:contract/output"
import "modus:contract/ring"
import "modus:contract/text_encoding"
import "modus:contract/value_kinds"

// The record output `log` of this process (src/md/features/log_facts.md,
// "The record output `log`"). When the wiring list of its start wires
// `log`, the root service puts the output ring at the handle
// op.CONTEXT_LOG_OUTPUT of the context and the end page at
// op.CONTEXT_LOG_OUTPUT_END, before the first instruction. Each log record
// that system.log, system.log_fact and system.log_text give the kernel,
// and that the kernel took or refused for its budget alone, then goes to
// that ring, whole, and waits while the ring is full: the reader of the
// audit loses none, and holds the writer.
//
// The end is not in the table of the stream ends: every thread of a process
// writes its log, and that table serves one thread at a time. This end has
// its own lock, which a thread holds for the records of one call, so the
// records of a text of several records and of a fact of several parts stay
// in a row. A process with no wiring of `log` reads one word of its context
// for each call, and takes no lock.

// What the writer of `log` knows of its end.
@(private = "file")
Log_Output_State :: enum u8 {
	Unopened = 0, // No call wrote yet: the handles of the context are not read.
	Open     = 1, // The ring is mapped, and each record goes to it.
	Ended    = 2, // The reader stopped or closed, the end words say an end, or the ring was refused: the log of the kernel only.
}

@(private = "file")
log_output_lock: Lock
@(private = "file")
log_output_state: Log_Output_State

// log_output_state_set stores the state under the lock, atomically: a call
// reads it before the lock to skip the lock once the output ended.
@(private = "file")
log_output_state_set :: proc "contextless" (state: Log_Output_State) {
	intrinsics.atomic_store((^u8)(&log_output_state), u8(state))
}
@(private = "file")
log_output_ring_address: rawptr
@(private = "file")
log_output_queue: ring.Compartment_Ring
@(private = "file")
log_output_end_words: ^output.End_Words
@(private = "file")
log_output_joined: bool
@(private = "file")
log_output_serial: u32
// The compartment that the writer builds before its push, and the copy of
// the text that it filters: private memory of the process, under the lock.
@(private = "file")
log_output_compartment: [output.COMPARTMENT_SIZE_MOST]u8
@(private = "file")
log_output_text: [op.LOG_TEXT_BYTES_MOST]u8

// log_output_wired says if the context gives a ring for `log`: one load of
// one word, the cost of a process with no wiring.
@(private)
log_output_wired :: #force_inline proc "contextless" () -> bool {
	return context_record().handles[op.CONTEXT_LOG_OUTPUT] != 0
}

// log_output_open maps the ring and the end page that the context gives.
// The caller holds the lock. A handle that is not a memory object with the
// rights that the root service gives, or a memory that is no ring of the
// size of the record, ends the output: the process goes on with the log of
// the kernel only.
@(private = "file")
log_output_open :: proc "contextless" () {
	log_output_state_set(.Ended)
	ring_memory := Handle(context_record().handles[op.CONTEXT_LOG_OUTPUT])
	end_memory := Handle(context_record().handles[op.CONTEXT_LOG_OUTPUT_END])
	ring_kind, ring_rights, _ := handle_state(ring_memory)
	end_kind, end_rights, _ := handle_state(end_memory)
	if ring_kind != .Memory || !({.Read, .Write} <= ring_rights) || end_kind != .Memory || .Read not_in end_rights {
		return
	}
	pages, size_status := memory_size(ring_memory)
	if size_status != .Ok {
		return
	}
	address, map_status := memory_map(ring_memory)
	if map_status != .Ok {
		return
	}
	queue, opened := ring.compartment_open(address, pages, output.compartment_size(size_of(output.Log_Output_Record)))
	if !opened {
		memory_unmap(address)
		return
	}
	words, words_status := memory_map(end_memory, {})
	if words_status != .Ok {
		memory_unmap(address)
		return
	}
	log_output_ring_address, log_output_queue = address, queue
	log_output_end_words = (^output.End_Words)(words)
	log_output_state_set(.Open)
}

// log_output_close unmaps the ring and the end page: the reader ended, or
// broke the ring. The process keeps its handles: the root service ends the
// wiring at its stop.
@(private = "file")
log_output_close :: proc "contextless" () {
	if log_output_ring_address != nil {
		memory_unmap(log_output_ring_address)
	}
	if log_output_end_words != nil {
		memory_unmap(log_output_end_words)
	}
	log_output_ring_address, log_output_end_words = nil, nil
	log_output_state_set(.Ended)
}

// log_output_push writes one compartment of a record of the ring, waiting
// while the ring is full: the pace of `log` holds its writer, so no record
// is lost. The caller holds the lock. It ends the output when the end words
// say an end, or when the reader wrote a count that no honest reader
// writes.
@(private = "file")
log_output_push :: proc "contextless" (record: ^output.Log_Output_Record) {
	commands := &log_output_queue.commands
	counters := commands.counters
	size := int(commands.compartment_size)
	for log_output_state == .Open {
		if end, _, _, ok := output.end_of_words(output.end_words_read(log_output_end_words)); !ok || end != .None {
			log_output_close()
			return
		}
		// The completions of the reader: a reader that refused a
		// compartment closed its side, and a word that names no completion
		// comes from no reader. Both end the output, as for a record
		// output; and a queue that nobody pops would fill.
		for _ in 0 ..< ring.count(&log_output_queue.completions) {
			completion, popped := ring.pop(&log_output_queue.completions)
			if !popped {
				break
			}
			kind, _, _, known := output.completion_of_record(completion)
			if !known || kind == .Bad_Record {
				log_output_close()
				return
			}
		}
		needed := u32(1)
		if !log_output_joined {
			needed += 1
		}
		write := intrinsics.atomic_load_explicit(&counters.write, .Relaxed)
		read := intrinsics.atomic_load_explicit(&counters.read, .Acquire)
		switch output.ring_room_of(write, read, ring.compartment_capacity(commands), needed, .Always_Holds_Writer) {
		case .Room:
			if !log_output_joined {
				// The first compartment: the joined record of the serial of
				// the first record, 0 for a wiring of the start.
				if !output.joined_compartment(log_output_compartment[:size], log_output_serial) || !ring.compartment_push(commands, log_output_compartment[:size]) {
					log_output_close()
					return
				}
				log_output_joined = true
			}
			bytes := ([^]u8)(record)[:size_of(output.Log_Output_Record)]
			if !output.record_compartment(log_output_compartment[:size], log_output_serial, bytes) || !ring.compartment_push(commands, log_output_compartment[:size]) {
				log_output_close()
				return
			}
			log_output_serial += 1
			ring.complete(&counters.write)
			if intrinsics.atomic_load(&counters.reader_waits) != 0 && intrinsics.atomic_exchange(&counters.reader_waits, 0) != 0 {
				word_wake(&counters.write, WAKE_ALL)
			}
			return
		case .Broken:
			log_output_close()
			return
		case .Holds, .Refuses:
			// The pace of log holds the writer: it waits on the read that it
			// loaded, so a read between the decision and the wait ends the
			// wait at once, and on the end word, so an end of the reader
			// ends it too.
			waiting := wait_begin()
			wait_word(&waiting, &counters.read, read, &counters.writer_waits, &counters.reader_waits, &counters.write)
			wait_word(&waiting, &log_output_end_words.end, u32(output.End_Word.None))
			wait_end(&waiting, WAIT_FOREVER)
		}
	}
}

// log_output_copy writes into the record output `log` the records that one
// call of Log gives the kernel: the parts of a text, cut as the kernel cuts
// it after the same filter, or the parts of a fact. bytes is what the call
// gives Log: a text with its value runs right after it, or a fact. It never
// fails the call: an output that ended leaves the log of the kernel.
@(private)
log_output_copy :: proc "contextless" (bytes: ^u8, count: int, level: op.Log_Level, run_count: int, form: op.Log_Record_Form) {
	if !log_output_wired() {
		return
	}
	// An output that ended stays ended: one atomic load, and no lock, for
	// each later call of each thread.
	if Log_Output_State(intrinsics.atomic_load((^u8)(&log_output_state))) == .Ended {
		return
	}
	lock(&log_output_lock)
	defer unlock(&log_output_lock)
	if log_output_state == .Unopened {
		log_output_open()
	}
	if log_output_state != .Open {
		return
	}
	time := nanoseconds() / 1000
	switch form {
	case .Text:
		text_count := min(count, len(log_output_text))
		copy(log_output_text[:], ([^]u8)(bytes)[:text_count])
		text := log_output_text[:text_count]
		text_encoding.invalid_sequences_replace(text)
		runs := ([^]value_kinds.Value_Run_In_Call)(rawptr(uintptr(bytes) + uintptr(count)))[:run_count]
		start := 0
		for {
			record, next := output.log_output_text_part(text, runs, start, level, time)
			log_output_push(&record)
			start = next
			if start >= len(text) || log_output_state != .Open {
				break
			}
		}
	case .Fact:
		body := ([^]u8)(bytes)[:count]
		for part in 0 ..< op.log_fact_part_count(count - op.LOG_FACT_HEAD_BYTES) {
			record, ok := output.log_output_fact_part(body, part, level, time)
			if !ok || log_output_state != .Open {
				break
			}
			log_output_push(&record)
		}
	}
}
