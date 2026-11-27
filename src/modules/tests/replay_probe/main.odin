// The record and the replay of a process with a shared writer
// (src/md/features/record_and_replay.md).
//
// The test process starts a reader: a child of this module that maps a page
// with Write, which the test process maps with Write too. The kernel records
// the reader from its first instruction, so the test process is a shared
// writer that the gate holds. In each round the test process writes bytes
// that come from its own clock into the page, and the reader sums them with
// its trapped reads of the cycle counter and of cpuid. Then:
//
// - The record holds one shared mapping, a delta of the shared page for each
//   round, the cycle counter and cpuid, and ends with the stop of the reader.
// - A replay of the history, in a new child that maps no shared page and
//   has no writer, reaches the end of the history with no divergence: the
//   kernel maps a private page where the record had the shared one, and
//   writes each delta at its input point.
// - A replay of a copy of the history with one byte of a delta changed stops
//   at the first entry after it that carries the sum: its input point, the
//   value of the history and the value of the replay.
//
// **What it is for.** It is the machine test of the record of a shared
// writer, and of the replay with no peer.
//
// **Start**: `start("replay_probe")` in the console. It starts each child
// from the boot image.
//
// **Grants**, as the root service gives them: **Image**, the boot image, to
// start the children from it.
//
// **What a reader sees**: one line for each case, which ends with "as it
// must", then "replay_probe: ok, 3 cases: ...", or "replay_probe: failed:
// N cases of 3". The process has no window.
package replay_probe

import "modus:contract/call_outcome"
import "base:intrinsics"
import "modus:contract/enum_word"
import "modus:contract/input_history"
import "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:display"
import "modus:random"
import "modus:system"
import terminal "modus:terminal"

// The test process, a child at a time, and the threads of both. The
// working memory pays each child (including a recorded console child and its
// 1024-page terminal text region or stand-in mapping on replay), its
// histories, and the point copies and shared-page baselines that the kernel
// takes from the budget of a history.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 6400, processes = 2, threads = 2}

// The value of the context that gives the role. Not the value 0: the root
// service writes there the size of the boot image of the grant Image.
VALUE_ROLE :: 7

// What a process of this module does.
Role :: enum u64 {
	Test   = 0, // The test process: it writes the shared page and checks the record and the replays.
	Reader = 1, // The recorded child: it reads the shared page each round.
}

CASE_COUNT :: 4
// The rounds of the reader: one write of the test process each.
ROUNDS :: 4
// The pages of each reader history: the head, about ten records each round, and
// the start of the reader. A full history ends the record with Buffer_Full.
HISTORY_PAGES :: 16
// The pages of the console history: 512 KiB holds console startup, terminal
// mappings, typed key deltas, Lex evaluation, and output records.
CONSOLE_HISTORY_PAGES :: 128
// Where the reader maps the shared page: far from each place that a
// starter or the kernel chooses.
SHARED_ADDRESS :: u64(0x0000_0100_0000_0000)

// The page that the test process and the reader share.
Shared_Page :: struct {
	round:        u32, // The round whose bytes the test process wrote.
	acknowledged: u32, // The round that the reader read.
	data:         [64]u8, // The bytes of the round. The last one is never the one of the round before.
}
#assert(size_of(Shared_Page) <= system.PAGE_SIZE)

// The word whose wake carries the sum of the reader. No thread waits on it:
// the wake only puts the sum into an argument of a kernel entry, which a
// replay compares with the history.
checksum_word: u32

image: []u8
process_generator: random.Generator
log_handle: system.Handle
right_count: int

// mix_deterministic runs a pure integer mixing loop whose result depends only
// on its inputs.
mix_deterministic :: proc "contextless" (seed: u64, rounds: u64) -> u64 {
	state := seed ~ 0x9E37_79B9_7F4A_7C15
	for step in u64(0) ..< rounds {
		state = (state * 0xBF58_476D_1CE4_E5B9) + (step * 2 + 1)
		state ~= state >> 27
	}
	return state
}

// hang_bound gives a deadline that only ends a hang.
hang_bound :: proc "contextless" () -> u64 {
	return system.time() + system.TEST_HANG_BOUND_MILLISECONDS
}

// verdict counts a case and gives the verdict field of its fact.
verdict :: proc "contextless" (right: bool) -> [16]u8 {
	if right {
		right_count += 1
		return value_kinds.text_field("as it must", 16)
	}
	return value_kinds.text_field("WRONG", 16)
}

// reader_run is the recorded child. Each value that it reads from outside
// is an input of the history: the shared page, the cycle counter, cpuid.
reader_run :: proc "contextless" () -> ! {
	shared := (^Shared_Page)(uintptr(SHARED_ADDRESS))
	_, _, leaf1_ecx, _ := intrinsics.x86_cpuid(1, 0)
	checksum := mix_deterministic(system.nanoseconds() ~ u64(leaf1_ecx), 64)
	for round in u32(1) ..= ROUNDS {
		for {
			seen := intrinsics.atomic_load(&shared.round)
			if seen == round {
				break
			}
			system.word_wait(&shared.round, seen)
		}
		for value, index in shared.data {
			checksum = mix_deterministic(checksum ~ (u64(value) << (u64(index % 8) * 8)), 1)
		}
		checksum = mix_deterministic(checksum ~ system.nanoseconds(), 4)
		system.word_wake(&checksum_word, checksum)
		intrinsics.atomic_store(&shared.acknowledged, round)
		system.word_wake(&shared.acknowledged)
	}
	system.stop(.Done)
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	role, role_known := enum_word.member_of_word(Role, ctx.values[VALUE_ROLE])
	if !role_known {
		system.log_fact(.Error, Probe_Bad_Role{word = ctx.values[VALUE_ROLE]})
		system.stop(.Refused)
	}
	switch role {
	case .Reader:
		reader_run()
	case .Test:
	}
	if !random.generator_from_context(&process_generator, ctx) {
		system.log_fact(.Info, Probe_No_Random_Seed{})
		system.stop(.Refused)
	}
	address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {})
	if status != .Succeeded {
		system.log_fact(.Info, Probe_No_Boot_Image{})
		system.stop(.Failed)
	}
	log_handle = ctx.handles[op.CONTEXT_LOG]
	image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	test_run()
	if right_count == CASE_COUNT {
		system.log_fact(.Info, Probe_Held{cases = CASE_COUNT})
		system.stop(.Done)
	}
	system.log_fact(.Info, Probe_Failed{wrong_cases = u64(CASE_COUNT - right_count), cases = CASE_COUNT})
	system.stop(.Failed)
}

// A memory object of this process and its mapping.
Mapped :: struct {
	memory: system.Handle,
	bytes:  []u8,
}

// mapped_create makes a memory object, contiguous for a history, and maps it
// with Write when writable is true, or read-only when writable is false.
mapped_create :: proc "contextless" (page_count: u64, contiguous: bool, writable := true) -> (mapped: Mapped, ok: bool) {
	flags: op.Memory_Flags
	if contiguous {
		flags = {.Contiguous}
	}
	memory, made := system.memory_create(page_count, flags = flags)
	if made != .Succeeded {
		system.log_fact(.Info, Probe_Step_Failed{status_word = call_outcome.Call_Outcome_Word(made), step = value_kinds.text_field("Memory_Create", 32)})
		return {}, false
	}
	map_flags: op.Map_Flags
	if writable {
		map_flags = {.Write}
	}
	address, mapped_status := system.memory_map(memory, map_flags)
	if mapped_status != .Succeeded {
		system.close(memory)
		system.log_fact(.Info, Probe_Step_Failed{status_word = call_outcome.Call_Outcome_Word(mapped_status), step = value_kinds.text_field("Memory_Map", 32)})
		return {}, false
	}
	return {memory = memory, bytes = ([^]u8)(address)[:page_count * system.PAGE_SIZE]}, true
}

mapped_release :: proc "contextless" (mapped: Mapped) {
	if mapped.bytes != nil {
		system.memory_unmap(raw_data(mapped.bytes))
	}
	if mapped.memory != 0 {
		system.close(mapped.memory)
	}
}

// reader_start starts a reader held before its first instruction. A record
// maps the shared page into it; a replay maps nothing there.
reader_start :: proc "contextless" (shared: system.Handle) -> (process: system.Handle, entry: u64, ok: bool) {
	grants: [op.CONTEXT_HANDLES]system.Grant
	values: [op.CONTEXT_VALUES]u64
	values[VALUE_ROLE] = u64(Role.Reader)
	mappings: [1]system.Mapping
	mapping_count := 0
	if shared != 0 {
		mappings[0] = {memory = shared, address = SHARED_ADDRESS, page_count = 1, flags = {.Write}}
		mapping_count = 1
	}
	error: module.Load_Error
	status: call_outcome.Call_Outcome
	process, status = system.process_start(system.image_find(image, "replay_probe"), "replay_probe reader", grants, random.values_with_seed(&process_generator, values), {pages = 256, processes = 1, threads = 1, processor = 200_000, log_records = 10}, mappings[:mapping_count], nil, {image = image}, &error, held_entry = &entry)
	if status != .Succeeded {
		system.log_fact(.Info, Probe_Step_Failed{status_word = call_outcome.Call_Outcome_Word(status), step = value_kinds.text_field("process_start", 32)})
		return 0, 0, false
	}
	return process, entry, true
}

// reader_wait_stopped waits until a reader stopped. The bound only ends a
// hang.
reader_wait_stopped :: proc "contextless" (process: system.Handle) -> (cause: op.Stop_Cause, outcome: op.Stop_Outcome, stopped: bool) {
	for deadline := hang_bound(); system.time() < deadline; {
		state: op.Process_State
		state, cause, outcome = system.process_state(process)
		if state == .Stopped {
			return cause, outcome, true
		}
		system.sleep(system.time() + 1)
	}
	system.log_fact(.Info, Probe_Reader_Hung{})
	return .None, .None, false
}

// Counts of the records of a history.
History_Counts :: struct {
	points:             u64,
	shared_mappings:    u64, // The Shared_Mapping records of the shared page: one page, Read_Write.
	other_mappings:     u64,
	shared_deltas:      u64,
	all_deltas:         u64,
	cycle_reads:        u64,
	cpuid_reads:        u64,
	carriers:           u64, // The wakes of checksum_word.
	end:                input_history.History_End_Reason,
}

// history_counts reads a history through the border of the contract.
history_counts :: proc "contextless" (bytes: []u8, scratch: []u8) -> (counts: History_Counts, ok: bool) {
	reader := input_history.history_reader_open(bytes) or_return
	counts.points = reader.header.point_count
	for {
		_, kind, payload, has_more, read_ok := input_history.history_reader_next_into(&reader, scratch)
		if !read_ok {
			return {}, false
		}
		if !has_more {
			return counts, true
		}
		switch kind {
		case .None:
			return {}, false
		case .Shared_Mapping:
			entry, access, _ := input_history.shared_mapping_validate(payload)
			if entry.virtual_address == SHARED_ADDRESS && entry.page_count == 1 && access == .Read_Write {
				counts.shared_mappings += 1
			} else {
				counts.other_mappings += 1
			}
		case .Page_Delta:
			counts.all_deltas += 1
			if header, _ := input_history.page_delta_validate(payload); header.virtual_address == SHARED_ADDRESS {
				counts.shared_deltas += 1
			}
		case .Cycle_Counter:
			counts.cycle_reads += 1
		case .Processor_Identification:
			counts.cpuid_reads += 1
		case .Kernel_Completion:
			if entry, _, _ := input_history.kernel_completion_from_payload(payload); carries_checksum(entry) {
				counts.carriers += 1
			}
		case .History_End:
			_, counts.end, _, _ = input_history.history_end_from_payload(payload)
		}
	}
}

// carries_checksum says whether a kernel entry is the wake of the reader
// that carries its sum: the same module at the same base, so the word has
// the same address in the reader as in this process.
carries_checksum :: proc "contextless" (entry: input_history.Kernel_Completion_Payload) -> bool {
	return entry.command_kind &~ op.COMMAND_NAMES_ERROR_DETAILS == u32(op.Operation.Word_Wake) && entry.command_values[0] == u64(uintptr(&checksum_word))
}

// One record of a history, private to this process.
record_scratch: [input_history.MAX_RECORD_PAYLOAD_BYTES]u8

// test_run runs the four cases: reader record/replay/divergence, then live
// record and replay of the real console module.
test_run :: proc "contextless" () {
	{
		shared, shared_ok := mapped_create(1, false)
		if !shared_ok {
			return
		}
		defer mapped_release(shared)
		history, history_ok := mapped_create(HISTORY_PAGES, true)
		if !history_ok {
			return
		}
		defer mapped_release(history)
		if case_of_the_record(shared, history) {
			case_of_the_replay(history)
			case_of_the_divergence(history)
		}
	}
	case_of_the_console()
}

// case_of_the_record records the reader while this process writes the
// shared page, and checks what the history holds.
case_of_the_record :: proc "contextless" (shared: Mapped, history: Mapped) -> bool {
	reader, entry, started := reader_start(shared.memory)
	if !started {
		return false
	}
	defer system.close(reader)
	if status := system.process_record_start(reader, history.memory); status != .Succeeded {
		system.log_fact(.Info, Probe_Step_Failed{status_word = call_outcome.Call_Outcome_Word(status), step = value_kinds.text_field("Record_Start", 32)})
		system.process_stop(reader)
		return false
	}
	if status := system.process_release(reader, entry); status != .Succeeded {
		system.log_fact(.Info, Probe_Step_Failed{status_word = call_outcome.Call_Outcome_Word(status), step = value_kinds.text_field("process_release", 32)})
		system.process_stop(reader)
		return false
	}
	page := (^Shared_Page)(raw_data(shared.bytes))
	for round in u32(1) ..= ROUNDS {
		// Bytes that only this run gives: a replay that reads them comes
		// from the history, never from a second run of the writer.
		clock := system.nanoseconds()
		for &value, index in page.data {
			value = u8(clock >> (u64(index % 8) * 8)) ~ u8(index)
		}
		page.data[len(page.data) - 1] = 0x80 | u8(round)
		intrinsics.atomic_store(&page.round, round)
		system.word_wake(&page.round)
		for deadline := hang_bound(); intrinsics.atomic_load(&page.acknowledged) != round; {
			seen := intrinsics.atomic_load(&page.acknowledged)
			if seen == round || system.time() >= deadline {
				break
			}
			system.word_wait(&page.acknowledged, seen, system.time() + 10)
		}
	}
	cause, outcome, stopped := reader_wait_stopped(reader)
	counts, counted := history_counts(history.bytes, record_scratch[:])
	system.log_fact(.Info, Probe_Recorded{points = counts.points, shared_deltas = counts.shared_deltas, cycle_reads = counts.cycle_reads, cpuid_reads = counts.cpuid_reads})
	right := stopped && cause == .Itself && outcome == .Done && counted && counts.end == .Normal_Stop
	right = right && counts.shared_mappings == 1 && counts.other_mappings == 0 && counts.shared_deltas >= ROUNDS
	right = right && counts.cycle_reads >= ROUNDS && counts.cpuid_reads >= 1 && counts.carriers == ROUNDS
	system.log_fact(.Info, Record_Checked{verdict = verdict(right)})
	return right
}

// replay_of runs a replay of history in a new reader with no shared page,
// and gives the header of the history after it.
replay_of :: proc "contextless" (history: Mapped) -> (header: input_history.History_Header, cause: op.Stop_Cause, outcome: op.Stop_Outcome, ok: bool) {
	reader, entry, started := reader_start(0)
	if !started {
		return {}, .None, .None, false
	}
	defer system.close(reader)
	if status := system.process_replay_start(reader, history.memory); status != .Succeeded {
		system.log_fact(.Info, Probe_Step_Failed{status_word = call_outcome.Call_Outcome_Word(status), step = value_kinds.text_field("Replay_Start", 32)})
		system.process_stop(reader)
		return {}, .None, .None, false
	}
	if status := system.process_release(reader, entry); status != .Succeeded {
		system.log_fact(.Info, Probe_Step_Failed{status_word = call_outcome.Call_Outcome_Word(status), step = value_kinds.text_field("process_release", 32)})
		system.process_stop(reader)
		return {}, .None, .None, false
	}
	stopped: bool
	cause, outcome, stopped = reader_wait_stopped(reader)
	if !stopped {
		system.process_stop(reader)
		return {}, .None, .None, false
	}
	opened: input_history.History_Reader
	opened, ok = input_history.history_reader_open(history.bytes)
	return opened.header, cause, outcome, ok
}

// history_copy makes a contiguous copy of a history for one replay: each
// replay writes its end into the header of its own copy.
history_copy :: proc "contextless" (history: Mapped) -> (copied: Mapped, ok: bool) {
	copied = mapped_create(HISTORY_PAGES, true) or_return
	copy(copied.bytes, history.bytes)
	return copied, true
}

// case_of_the_replay replays the history with no writer: the same inputs
// at the same points, and the end of the history.
case_of_the_replay :: proc "contextless" (history: Mapped) {
	copied, copied_ok := history_copy(history)
	if !copied_ok {
		system.log_fact(.Info, Replay_Checked{verdict = verdict(false)})
		return
	}
	defer mapped_release(copied)
	header, cause, outcome, replayed := replay_of(copied)
	end, _ := input_history.history_end_reason_of_word(u64(header.end_reason))
	divergences := u64(end == .Divergence ? 1 : 0)
	system.log_fact(.Info, Probe_Replayed{divergences = divergences, divergence_point = header.divergence_point})
	system.log_fact(.Info, Replay_Checked{verdict = verdict(replayed && end == .Normal_Stop && cause == .Itself && outcome == .Done)})
}

// case_of_the_divergence changes the last byte of a delta of the shared
// page in a copy of the history: the replay must stop at the first wake
// after it that carries the sum, with the sum of the history.
case_of_the_divergence :: proc "contextless" (history: Mapped) {
	copied, copied_ok := history_copy(history)
	if !copied_ok {
		system.log_fact(.Info, Divergence_Checked{verdict = verdict(false)})
		return
	}
	defer mapped_release(copied)
	// The second delta of the shared page, the bytes of round 2; its last
	// byte is the last byte of data, which differs each round.
	reader, opened := input_history.history_reader_open(copied.bytes)
	changed_offset := -1
	deltas := 0
	expected_point, expected_sum: u64
	for opened {
		offset := reader.read_offset
		record_header, kind, payload, has_more, read_ok := input_history.history_reader_next_into(&reader, record_scratch[:])
		if !read_ok || !has_more {
			break
		}
		if kind == .Page_Delta {
			if header, _ := input_history.page_delta_validate(payload); header.virtual_address == SHARED_ADDRESS {
				deltas += 1
				if deltas == 2 {
					changed_offset = size_of(input_history.History_Header) + int(offset) + size_of(input_history.History_Record_Header) + len(payload) - 1
				}
			}
		} else if kind == .Kernel_Completion {
			if entry, _, _ := input_history.kernel_completion_from_payload(payload); changed_offset >= 0 && expected_point == 0 && carries_checksum(entry) {
				expected_point = record_header.point_number
				expected_sum = entry.command_values[1]
			}
		}
	}
	if changed_offset < 0 || expected_point == 0 {
		system.log_fact(.Info, Divergence_Checked{verdict = verdict(false)})
		return
	}
	copied.bytes[changed_offset] ~= 0x01
	header, cause, _, replayed := replay_of(copied)
	end, _ := input_history.history_end_reason_of_word(u64(header.end_reason))
	kind, _ := input_history.divergence_kind_of_word(u64(header.divergence_kind))
	report, found, reported := input_history.divergence_report_of_history(copied.bytes, record_scratch[:])
	system.log_fact(.Info, Probe_Divergence{kind = u64(kind), point = header.divergence_point, expected_point = expected_point, recorded_sum = header.divergence_expected, replayed_sum = header.divergence_actual, recorded_instruction = report.recorded_instruction_address})
	right := replayed && end == .Divergence && kind == .Unexpected_Arguments && cause == .Holder
	right = right && header.divergence_point == expected_point && header.divergence_expected == expected_sum && header.divergence_actual != expected_sum
	right = right && reported && found && report.recorded_kind == .Kernel_Completion && report.point == expected_point
	system.log_fact(.Info, Divergence_Checked{verdict = verdict(right)})
}

// console_start starts the real console module held before its first
// instruction. Recording passes a 2-page terminal ring and a 1024-page text
// region; replay passes no terminal handles so the kernel supplies stand-in
// mappings from the history.
console_start :: proc "contextless" (term_ring, term_text: system.Handle) -> (process: system.Handle, entry: u64, ok: bool) {
	grants: [op.CONTEXT_HANDLES]system.Grant
	values: [op.CONTEXT_VALUES]u64
	if log_handle != 0 {
		grants[op.CONTEXT_LOG] = {log_handle, {.Write}}
	}
	if term_ring != 0 {
		grants[system.GRANT_TERMINAL_RING] = {term_ring, {.Read, .Write}}
	}
	if term_text != 0 {
		grants[system.GRANT_TERMINAL_TEXT] = {term_text, {.Read, .Write}}
	}
	error: module.Load_Error
	status: call_outcome.Call_Outcome
	process, status = system.process_start(system.image_find(image, "console"), "console", grants, random.values_with_seed(&process_generator, values), {pages = 4096, processes = 1, threads = 1, processor = 200_000, log_records = 10}, nil, nil, {image = image}, &error, held_entry = &entry)
	if status != .Succeeded {
		system.log_fact(.Info, Probe_Step_Failed{status_word = call_outcome.Call_Outcome_Word(status), step = value_kinds.text_field("console process_start", 32)})
		return 0, 0, false
	}
	return process, entry, true
}

// console_text_read copies count bytes from the circular terminal text region
// starting at cursor and advances cursor.
console_text_read :: proc "contextless" (text_bytes: []u8, cursor: ^u64, count: u32, dest: []u8) -> []u8 {
	total := int(min(u64(count), u64(len(dest))))
	place := int(cursor^ % terminal.TEXT_SIZE)
	first := min(total, len(text_bytes) - place)
	copy(dest[:first], text_bytes[place:place + first])
	if total > first {
		copy(dest[first:total], text_bytes[:total - first])
	}
	cursor^ += u64(count)
	return dest[:total]
}

// bytes_contain reports whether haystack holds needle.
bytes_contain :: proc "contextless" (haystack: []u8, needle: string) -> bool {
	if len(needle) == 0 {
		return true
	}
	if len(haystack) < len(needle) {
		return false
	}
	needle_bytes := transmute([]u8)needle
	for start in 0 ..= len(haystack) - len(needle_bytes) {
		matched := true
		for offset in 0 ..< len(needle_bytes) {
			if haystack[start + offset] != needle_bytes[offset] {
				matched = false
				break
			}
		}
		if matched {
			return true
		}
	}
	return false
}

// console_key_send pushes one key record into the terminal completion queue
// and wakes the console reader.
console_key_send :: proc "contextless" (term: ^ring.Ring, code: u32, ch: rune, serial: u64) -> bool {
	record := ring.Record {
		kind   = u32(terminal.Input.Key),
		tag    = code,
		values = {0 = u64(ch), 1 = 0, 2 = serial},
	}
	for deadline := hang_bound(); system.time() < deadline; {
		if ring.push(&term.completions, record) {
			system.wake_reader(&term.completions)
			return true
		}
		system.sleep(system.time() + 1)
	}
	return false
}

// case_of_the_console records the real console module while this process acts
// as its shared terminal writer, types "6 * 7" and Enter, verifies "42" in
// the terminal text output, ends recording, and replays the console alone
// with no terminal handles to clean completion.
case_of_the_console :: proc "contextless" () {
	history, history_ok := mapped_create(CONSOLE_HISTORY_PAGES, true)
	if !history_ok {
		system.log_fact(.Info, Console_Checked{verdict = verdict(false)})
		return
	}
	defer mapped_release(history)

	saw_prompt := false
	saw_42 := false
	saw_prompt_after_42 := false
	{
		term_ring, ring_ok := mapped_create(ring.PAGE_COUNT, false, writable = true)
		if !ring_ok {
			system.log_fact(.Info, Console_Checked{verdict = verdict(false)})
			return
		}
		defer mapped_release(term_ring)
		// Map the 1024-page text region read-only here so the console is its
		// sole writer: the kernel emits a Shared_Mapping with zero shared-page
		// baselines and zero initial deltas for untouched pages.
		term_text, text_ok := mapped_create(terminal.TEXT_PAGES, false, writable = false)
		if !text_ok {
			system.log_fact(.Info, Console_Checked{verdict = verdict(false)})
			return
		}
		defer mapped_release(term_text)
		term, term_opened := ring.open(raw_data(term_ring.bytes), ring.PAGE_COUNT)
		if !term_opened {
			system.log_fact(.Info, Console_Checked{verdict = verdict(false)})
			return
		}
		console_proc, console_entry, started := console_start(term_ring.memory, term_text.memory)
		if !started {
			system.log_fact(.Info, Console_Checked{verdict = verdict(false)})
			return
		}
		defer system.close(console_proc)
		if status := system.process_record_start(console_proc, history.memory); status != .Succeeded {
			system.log_fact(.Info, Probe_Step_Failed{status_word = call_outcome.Call_Outcome_Word(status), step = value_kinds.text_field("console Record_Start", 32)})
			system.process_stop(console_proc)
			system.log_fact(.Info, Console_Checked{verdict = verdict(false)})
			return
		}
		if status := system.process_release(console_proc, console_entry); status != .Succeeded {
			system.log_fact(.Info, Probe_Step_Failed{status_word = call_outcome.Call_Outcome_Word(status), step = value_kinds.text_field("console process_release", 32)})
			system.process_stop(console_proc)
			system.log_fact(.Info, Console_Checked{verdict = verdict(false)})
			return
		}

		text_cursor: u64
		run_buf: [terminal.RUN_LIMIT]u8
		for deadline := hang_bound(); !saw_prompt && system.time() < deadline; {
			if rec, popped := ring.pop(&term.commands); popped {
				kind, kind_ok := terminal.kind_of_ring_word(rec.kind)
				if kind_ok && rec.tag > 0 {
					_ = console_text_read(term_text.bytes, &text_cursor, rec.tag, run_buf[:])
				}
				if kind_ok && kind == .Edit {
					saw_prompt = true
				}
			} else {
				wait := system.wait_begin()
				system.wait_records(&wait, &term.commands)
				system.wait_end(&wait, system.time() + 10)
			}
		}

		keys_sent := saw_prompt
		line_chars := "6 * 7"
		serial := u64(1)
		for ch in line_chars {
			if !keys_sent {
				break
			}
			keys_sent = console_key_send(&term, 1, ch, serial)
			serial += 1
		}
		// Wait until the console echoes the typed edit line before sending Enter
		// so edit_show() updates shown from "> 6 * 7" back to "> " after evaluation.
		saw_line_echo := false
		for deadline := hang_bound(); keys_sent && !saw_line_echo && system.time() < deadline; {
			if rec, popped := ring.pop(&term.commands); popped {
				kind, kind_ok := terminal.kind_of_ring_word(rec.kind)
				run_slice: []u8
				if kind_ok && rec.tag > 0 {
					run_slice = console_text_read(term_text.bytes, &text_cursor, rec.tag, run_buf[:])
				}
				if kind_ok && kind == .Edit && bytes_contain(run_slice, "6 * 7") {
					saw_line_echo = true
				}
			} else {
				wait := system.wait_begin()
				system.wait_records(&wait, &term.commands)
				system.wait_end(&wait, system.time() + 10)
			}
		}
		if keys_sent && saw_line_echo {
			keys_sent = console_key_send(&term, display.KEY_ENTER, '\n', serial)
		} else {
			keys_sent = false
		}

		for deadline := hang_bound(); keys_sent && !(saw_42 && saw_prompt_after_42) && system.time() < deadline; {
			if rec, popped := ring.pop(&term.commands); popped {
				kind, kind_ok := terminal.kind_of_ring_word(rec.kind)
				run_slice: []u8
				if kind_ok && rec.tag > 0 {
					run_slice = console_text_read(term_text.bytes, &text_cursor, rec.tag, run_buf[:])
				}
				if kind_ok && kind == .Text && bytes_contain(run_slice, "42") {
					saw_42 = true
				} else if kind_ok && kind == .Edit && saw_42 {
					saw_prompt_after_42 = true
				}
			} else {
				wait := system.wait_begin()
				system.wait_records(&wait, &term.commands)
				system.wait_end(&wait, system.time() + 10)
			}
		}

		_ = system.process_record_end(console_proc)
		system.process_stop(console_proc)
		_, _, _ = reader_wait_stopped(console_proc)
	}

	counts, counted := history_counts(history.bytes, record_scratch[:])
	total_mappings := counts.shared_mappings + counts.other_mappings
	system.log_fact(.Info, Console_Recorded{points = counts.points, shared_mappings = total_mappings, shared_deltas = counts.all_deltas, end_reason = u64(counts.end)})
	record_ok := saw_prompt && saw_42 && saw_prompt_after_42 && counted && counts.end == .Recorder_Stopped && counts.points > 0 && total_mappings >= 2 && counts.all_deltas >= 1
	if !record_ok {
		system.log_fact(.Info, Console_Checked{verdict = verdict(false)})
		return
	}

	replay_history, copy_ok := mapped_create(CONSOLE_HISTORY_PAGES, true)
	if !copy_ok {
		system.log_fact(.Info, Console_Checked{verdict = verdict(false)})
		return
	}
	defer mapped_release(replay_history)
	copy(replay_history.bytes, history.bytes)

	replay_proc, replay_entry, replay_started := console_start(0, 0)
	if !replay_started {
		system.log_fact(.Info, Console_Checked{verdict = verdict(false)})
		return
	}
	defer system.close(replay_proc)
	if status := system.process_replay_start(replay_proc, replay_history.memory); status != .Succeeded {
		system.log_fact(.Info, Probe_Step_Failed{status_word = call_outcome.Call_Outcome_Word(status), step = value_kinds.text_field("console Replay_Start", 32)})
		system.process_stop(replay_proc)
		system.log_fact(.Info, Console_Checked{verdict = verdict(false)})
		return
	}
	if status := system.process_release(replay_proc, replay_entry); status != .Succeeded {
		system.log_fact(.Info, Probe_Step_Failed{status_word = call_outcome.Call_Outcome_Word(status), step = value_kinds.text_field("console replay release", 32)})
		system.process_stop(replay_proc)
		system.log_fact(.Info, Console_Checked{verdict = verdict(false)})
		return
	}
	_, _, stopped := reader_wait_stopped(replay_proc)
	if !stopped {
		system.process_stop(replay_proc)
	}
	opened, opened_ok := input_history.history_reader_open(replay_history.bytes)
	end, _ := input_history.history_end_reason_of_word(u64(opened.header.end_reason))
	system.log_fact(.Info, Console_Replayed{end_reason = u64(end), divergence_kind = u64(opened.header.divergence_kind), divergence_point = opened.header.divergence_point})
	right := stopped && opened_ok && end == .Recorder_Stopped && opened.header.divergence_kind == 0 && opened.header.divergence_point == 0
	system.log_fact(.Info, Console_Checked{verdict = verdict(right)})
}
