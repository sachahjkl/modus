// Pure wiring state machine for the delegated `wiring` service
// (src/md/api/root_service_split.md).
//
// This package holds all state transitions and validation logic for record
// stream wirings: process registration by canonical (slot, serial), list
// page reservation, full wiring-list resolution (record-type equality,
// generic stream type fixing, condition checking, duplicate and cycle
// detection, per-asker / per-process / machine capacity limits), wiring
// ring completion handling, unwire/revocation, and stop-notice cleanup.
//
// It makes no kernel calls and imports no support package, so adversarial
// host tests exercise every branch directly.
package wiring_core

import "modus:contract/errors"
import "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/output"
import "modus:contract/ring"
import ws "modus:contract/wiring_service"

// The processes that `wiring` tracks at one time.
PROCESS_CAPACITY :: 32

// The ends that one process holds at one time (system.STREAM_END_CAPACITY).
ENDS_OF_A_PROCESS_MOST :: 16

// The ends of one service that one asker holds through its connections.
CONNECTED_ENDS_OF_AN_ASKER_MOST :: 4

// The wirings of the whole machine at one time.
WIRINGS_OF_THE_MACHINE_MOST :: 24

// The askers that hold a list page at one time.
LIST_PAGE_ASKERS_MOST :: 4
#assert(LIST_PAGE_ASKERS_MOST * CONNECTED_ENDS_OF_AN_ASKER_MOST <= ENDS_OF_A_PROCESS_MOST)

// The generic record inputs of one process whose fixed type is kept until
// its stop.
GENERIC_TYPES_OF_A_PROCESS_MOST :: 4

// Monotonic stall bound (milliseconds) before an Always_Holds_Writer wiring
// whose ring stays full without reader progress is revoked (matches
// system.TEST_HANG_BOUND_MILLISECONDS; verified by #assert in wiring/main.odin).
STALL_HANG_BOUND_MS :: u64(60_000)

// Sentinel process index representing the child of a Start wiring list
// before Process_Start assigns its process slot and serial.
CHILD_PROCESS_INDEX :: -2

// Sentinel process index for a side that closed its end and then stopped.
DETACHED_PROCESS_INDEX :: -1

// One type fixed for a generic record input of count One or Many.
Generic_Type_Kept :: struct {
	index:       u32, // Record input index, from 1.
	description: u32, // Record index in the file slice.
	is_log_file: bool, // True when the description comes from the built-in log description file.
	file_offset: u64, // Offset in the read-only boot image (when !is_log_file).
	file_size:   u64, // Byte size in the read-only boot image (when !is_log_file).
}

// Tracked state of one registered process.
Process_Entry :: struct {
	active:             bool,
	id:                 ws.Process_Identity,
	flags:              ws.Process_Flags,
	module_offset:      u64,
	module_size:        u64,
	has_list_page:      bool,
	wirings_asked:      int,
	ends_given:         int,
	log_ends_given:     int,
	generic_types:      [GENERIC_TYPES_OF_A_PROCESS_MOST]Generic_Type_Kept,
	generic_type_count: int,
}

// Tracked state of one active wiring.
Wiring_Entry :: struct {
	active:              bool,
	number:              u32, // Unique non-zero wiring number (tag of its ends).
	asker_index:         int, // Process index of asker, or DETACHED_PROCESS_INDEX.
	writer_index:        int, // Process index of writer, or DETACHED_PROCESS_INDEX.
	reader_index:        int, // Process index of reader (asker for Asker), or DETACHED_PROCESS_INDEX.
	writer_stream_index: u32, // Record output index (0 for log).
	reader_stream_index: u32, // Record input index (0 for asker).
	pace:                output.Wiring_Pace,
	writer_is_log:       bool,
	reader_is_asker:     bool,
	writer_counted:      bool,
	reader_counted:      bool,
	writer_answered:     bool,
	reader_answered:     bool,
	writer_closed:       bool,
	reader_closed:       bool,
	asked_counted:       bool,
	end_written:         bool,
	dropped_told:        bool,
	// Stall-deadline tracking for Always_Holds_Writer wirings whose ring
	// stays full with no reader progress.
	stall_active:        bool,
	stalled_since_ms:    u64,
	stalled_read_cursor: u32,
}

// Whole pure state of the delegated wiring service.
State :: struct {
	processes:           [PROCESS_CAPACITY]Process_Entry,
	wirings:             [WIRINGS_OF_THE_MACHINE_MOST]Wiring_Entry,
	wiring_number_next:  u32,
	wirings_running:     int,
	list_page_holders:   int,
	log_output_bytes:    [output.DESCRIPTION_FILE_BYTES_MOST]u8,
	log_output_size:     int,
}

// One resolved row of a wiring list plan.
Row_Plan :: struct {
	row:                   output.Checked_Wiring,
	writer_index:          int, // Process index, or CHILD_PROCESS_INDEX.
	reader_index:          int, // Process index, or CHILD_PROCESS_INDEX.
	writer_is_log_file:    bool,
	writer_file_offset:    u64,
	writer_file_size:      u64,
	description:           u32,
	terms_size:            u32,
	condition:             output.Writer_Condition,
	has_condition:         bool,
	deferred:              bool,
	resolved:              bool,
	fixes:                 bool,
	keeps_type:            bool,
	paired:                bool, // The writer is a record output Paired: its ring pairs with the source of row.paired_row.
	allocated_slot:        int, // Wiring slot index allocated in State.wirings, or -1.
	allocated_number:      u32,
}

// Scratch workspace for resolving one wiring list without heap allocation.
Plan_Work :: struct {
	asker_index: int,
	command_op:  u32,
	form:        output.Wiring_List_Form,
	list:        output.Checked_Wiring_List,
	child_offset: u64,
	child_size:   u64,
	plans:       [output.WIRING_LIST_ROW_LIMIT]Row_Plan,
}

// Callback queried by plan_resolve to inspect a running process's wiring
// ring available command room without coupling wiring_core to kernel calls.
Ring_Room_Proc :: proc "contextless" (data: rawptr, proc_index: int) -> (available: u32, capacity: u32, has_ring: bool)

// Action returned when applying a completion record from a process's wiring ring.
Completion_Effect :: enum u8 {
	None, // Answer Taken accepted; no side effect needed.
	End_Wiring, // End the wiring and write end_word (Refused or None when both closed).
	Write_End_Word, // Write end_word (Side_Closed) while wiring remains open for peer.
	Unknown_Word, // Completion tag named no wiring of this process; dropped.
	Dropped_Word, // Duplicate or unexpected word for an existing wiring; dropped.
}

Completion_Action :: struct {
	effect:       Completion_Effect,
	wiring_slot:  int, // Index into State.wirings, or -1.
	wiring_number: u32,
	end_word:     output.End_Word,
	first_drop:   bool, // True on the first Dropped_Word for this wiring.
	side_status:  op.Status,
	border_ok:    bool,
}

// Action returned for each wiring affected by a process stop or revocation.
Stop_Action_Kind :: enum u8 {
	End_Wiring, // Write end_word (if != .None), wake peer, close end page handle.
	Detach, // Side had already closed; peer keeps reading Side_Closed.
}

Stop_Action :: struct {
	kind:          Stop_Action_Kind,
	wiring_slot:   int,
	wiring_number: u32,
	end_word:      output.End_Word,
	stop_cause:    op.Stop_Cause,
	stop_outcome:  op.Stop_Outcome,
	asker_index:   int,
	asker_empty:   bool, // True if asker's wirings_asked just reached 0.
}

// state_init prepares a zeroed State with wiring_number_next = 1 and the
// built-in description file for output.Log_Output_Record.
state_init :: proc "contextless" (s: ^State) {
	s^ = {}
	s.wiring_number_next = 1
	if size, ok := output.log_output_file_write(s.log_output_bytes[:]); ok {
		s.log_output_size = size
	}
}

// log_output_file returns the built-in description file slice for log output.
log_output_file :: proc "contextless" (s: ^State) -> []u8 {
	if s.log_output_size <= 0 {
		return nil
	}
	return s.log_output_bytes[:s.log_output_size]
}

// image_slice_of returns a validated read-only slice of image, or nil if
// offset/size are zero or out of bounds.
image_slice_of :: proc "contextless" (image: []u8, offset, size: u64) -> []u8 {
	if size == 0 || offset > u64(len(image)) || size > u64(len(image)) - offset {
		return nil
	}
	return image[offset:][:size]
}

// process_find locates an active process matching BOTH slot and serial.
// A stale serial for a reused slot never matches.
process_find :: proc "contextless" (s: ^State, id: ws.Process_Identity) -> (index: int, found: bool) {
	if !ws.process_identity_valid(id) {
		return -1, false
	}
	for &entry, idx in s.processes {
		if entry.active && entry.id == id {
			return idx, true
		}
	}
	return -1, false
}

// process_register registers a new process or refreshes an existing active
// entry with the exact same (slot, serial). Refuses invalid identities,
// conflicting serials on an already-active slot, or a full table.
process_register :: proc "contextless" (s: ^State, id: ws.Process_Identity, module_offset, module_size: u64, flags: ws.Process_Flags) -> (index: int, status: ws.Response_Status) {
	if !ws.process_identity_valid(id) {
		return -1, .Bad_Command
	}
	if (module_offset == 0) != (module_size == 0) {
		return -1, .Bad_Command
	}
	free_index := -1
	for &entry, idx in s.processes {
		if !entry.active {
			if free_index < 0 {
				free_index = idx
			}
			continue
		}
		if entry.id.slot == id.slot {
			if entry.id.serial != id.serial {
				return -1, .Bad_State
			}
			entry.flags = flags
			entry.module_offset = module_offset
			entry.module_size = module_size
			return idx, .Ok
		}
	}
	if free_index < 0 {
		return -1, .No_Slot
	}
	s.processes[free_index] = {
		active        = true,
		id            = id,
		flags         = flags,
		module_offset = module_offset,
		module_size   = module_size,
	}
	return free_index, .Ok
}

// list_page_reserve checks whether asker may hold a list page and reserves
// a slot under LIST_PAGE_ASKERS_MOST.
list_page_reserve :: proc "contextless" (s: ^State, asker_id: ws.Process_Identity, command_op: u32) -> (already_held: bool, asker_index: int, status: ws.Response_Status, refusal: errors.Error_Record) {
	idx, found := process_find(s, asker_id)
	if !found {
		return false, -1, .Bad_Handle, make_error(command_op, .Absent, .Processes)
	}
	if s.processes[idx].has_list_page {
		return true, idx, .Ok, {}
	}
	if s.list_page_holders >= LIST_PAGE_ASKERS_MOST {
		return false, -1, .No_Slot, make_error(command_op, .Full, .Wirings, 0, i64(s.list_page_holders + 1), LIST_PAGE_ASKERS_MOST)
	}
	s.processes[idx].has_list_page = true
	s.list_page_holders += 1
	return false, idx, .Ok, {}
}

// list_page_unreserve rolls back a fresh reservation after an allocation error.
list_page_unreserve :: proc "contextless" (s: ^State, asker_index: int) {
	if asker_index < 0 || asker_index >= PROCESS_CAPACITY || !s.processes[asker_index].active {
		return
	}
	if s.processes[asker_index].has_list_page {
		s.processes[asker_index].has_list_page = false
		if s.list_page_holders > 0 {
			s.list_page_holders -= 1
		}
	}
}

@(private = "file")
make_error :: proc "contextless" (operation: u32, kind: errors.Kind, unit: errors.Unit, argument: i64 = 0, value: i64 = 0, limit: i64 = 0, found: i64 = 0) -> errors.Error_Record {
	rec := errors.error_make(kind, unit, argument, value, limit, found)
	rec.operation = i64(operation)
	return rec
}

@(private = "file")
generic_input_of :: proc "contextless" (file: []u8) -> (index: u32, wirings: module.Wiring_Count, ok: bool) {
	for row in 1 ..= module.count(file, .Record_Inputs) {
		value, row_wirings, _, _, row_ok := module.record_input(file, row)
		if row_ok && value.record == 0 {
			return row, row_wirings, true
		}
	}
	return 0, {}, false
}

@(private = "file")
plan_file_slice :: proc "contextless" (s: ^State, image: []u8, is_log: bool, offset, size: u64) -> []u8 {
	if is_log {
		return log_output_file(s)
	}
	return image_slice_of(image, offset, size)
}

@(private = "file")
process_file_slice :: proc "contextless" (s: ^State, work: ^Plan_Work, image: []u8, proc_index: int) -> (slice: []u8, offset, size: u64) {
	if proc_index == CHILD_PROCESS_INDEX {
		return image_slice_of(image, work.child_offset, work.child_size), work.child_offset, work.child_size
	}
	if proc_index < 0 || proc_index >= PROCESS_CAPACITY || !s.processes[proc_index].active {
		return nil, 0, 0
	}
	entry := &s.processes[proc_index]
	return image_slice_of(image, entry.module_offset, entry.module_size), entry.module_offset, entry.module_size
}

@(private = "file")
generic_type_fixed :: proc "contextless" (s: ^State, work: ^Plan_Work, image: []u8, number: u32, proc_index: int, input_index: u32) -> (file: []u8, is_log: bool, offset, size: u64, desc: u32, fixed: bool) {
	if input_index == 0 || proc_index == DETACHED_PROCESS_INDEX {
		return nil, false, 0, 0, 0, false
	}
	for other in 1 ..= work.list.row_count {
		plan := &work.plans[other - 1]
		if other != number && plan.fixes && plan.reader_index == proc_index && plan.row.reader_index == input_index {
			return plan_file_slice(s, image, plan.writer_is_log_file, plan.writer_file_offset, plan.writer_file_size), plan.writer_is_log_file, plan.writer_file_offset, plan.writer_file_size, plan.description, true
		}
	}
	if proc_index >= 0 && proc_index < PROCESS_CAPACITY && s.processes[proc_index].active {
		entry := &s.processes[proc_index]
		for kept in entry.generic_types[:entry.generic_type_count] {
			if kept.index == input_index {
				return plan_file_slice(s, image, kept.is_log_file, kept.file_offset, kept.file_size), kept.is_log_file, kept.file_offset, kept.file_size, kept.description, true
			}
		}
	}
	return nil, false, 0, 0, 0, false
}

@(private = "file")
generic_types_listed :: proc "contextless" (work: ^Plan_Work, number: u32, proc_index: int) -> (listed: int) {
	for other in 1 ..= work.list.row_count {
		plan := &work.plans[other - 1]
		if other != number && plan.fixes && plan.reader_index == proc_index {
			listed += 1
		}
	}
	return listed
}

@(private = "file")
deferred_type_fixed :: proc "contextless" (s: ^State, work: ^Plan_Work, image: []u8, number: u32) -> bool {
	plan := &work.plans[number - 1]
	writer_file := plan_file_slice(s, image, plan.writer_is_log_file, plan.writer_file_offset, plan.writer_file_size)
	if len(writer_file) == 0 {
		return false
	}
	// A ring of a pair takes the type of its source: it is fixed once the
	// row of the source has its type. The border keeps paired_row before
	// the row, inside the list.
	if _, pairing, _, output_ok := module.record_output(writer_file, plan.row.writer_index); output_ok && pairing == .Paired {
		pair := plan.row.paired_row
		if pair == 0 || pair >= number {
			return true
		}
		source := &work.plans[pair - 1]
		return !source.deferred || source.resolved
	}
	index, _, has_input := generic_input_of(writer_file)
	if !has_input {
		return false
	}
	_, _, _, _, _, fixed := generic_type_fixed(s, work, image, number, plan.writer_index, index)
	return fixed
}

// record_input_taken checks whether a Wiring_Count.One input already has a
// wiring in an earlier row of this list or among active wirings.
@(private = "file")
record_input_taken :: proc "contextless" (s: ^State, work: ^Plan_Work, number: u32, reader_idx: int, reader_stream: u32) -> bool {
	for before in 1 ..< number {
		plan := &work.plans[before - 1]
		if plan.reader_index == reader_idx && plan.row.reader_end != .Asker && plan.row.reader_index == reader_stream {
			return true
		}
	}
	if reader_idx < 0 {
		return false
	}
	for &kept in s.wirings {
		if kept.active && kept.reader_index == reader_idx && !kept.reader_is_asker && kept.reader_stream_index == reader_stream {
			return true
		}
	}
	return false
}

// graph_reaches performs a bounded breadth-first search from `from_proc`
// along active wirings and resolved rows of `work` (up to `row_limit`) to
// detect whether adding `writer -> reader` would close a directed cycle.
@(private = "file")
graph_reaches :: proc "contextless" (s: ^State, work: ^Plan_Work, row_limit: u32, from_proc, target_proc: int) -> bool {
	if from_proc == target_proc {
		return true
	}
	// Map CHILD_PROCESS_INDEX to slot PROCESS_CAPACITY in the visited/queue arrays.
	node_id :: proc "contextless" (idx: int) -> int {
		if idx == CHILD_PROCESS_INDEX {
			return PROCESS_CAPACITY
		}
		if idx >= 0 && idx < PROCESS_CAPACITY {
			return idx
		}
		return -1
	}
	start_node := node_id(from_proc)
	goal_node := node_id(target_proc)
	if start_node < 0 || goal_node < 0 {
		return false
	}
	visited: [PROCESS_CAPACITY + 1]bool
	queue: [PROCESS_CAPACITY + 1]int
	head, tail := 0, 0
	visited[start_node] = true
	queue[tail] = from_proc
	tail += 1
	for head < tail {
		current := queue[head]
		head += 1
		// Traverse active wirings.
		if current >= 0 {
			for &kept in s.wirings {
				if !kept.active || kept.writer_index != current || kept.reader_index < 0 {
					continue
				}
				next := kept.reader_index
				next_id := node_id(next)
				if next_id == goal_node {
					return true
				}
				if next_id >= 0 && !visited[next_id] {
					visited[next_id] = true
					queue[tail] = next
					tail += 1
				}
			}
		}
		// Traverse earlier rows of the same list.
		for row_num in 1 ..< row_limit {
			plan := &work.plans[row_num - 1]
			if plan.writer_index != current {
				continue
			}
			next := plan.reader_index
			next_id := node_id(next)
			if next_id == goal_node {
				return true
			}
			if next_id >= 0 && !visited[next_id] {
				visited[next_id] = true
				queue[tail] = next
				tail += 1
			}
		}
	}
	return false
}

@(private = "file")
resolve_end_from_request :: proc "contextless" (s: ^State, work: ^Plan_Work, req: ^ws.Resolved_Wiring_Request, end: output.Wiring_End, place: u32) -> (proc_index: int, facts: output.End_Facts, found: bool) {
	facts.asker_is_start_policy = req.asker_is_start_policy != 0
	switch end {
	case .Child:
		return CHILD_PROCESS_INDEX, facts, true
	case .Asker:
		return work.asker_index, facts, true
	case .Started:
		if place == 0 || place > req.lent_count {
			return -1, facts, false
		}
		lent := &req.lent[place - 1]
		if lent.present == 0 {
			return -1, facts, false
		}
		idx, ok := process_find(s, {lent.process_slot, lent.process_serial})
		if !ok {
			return -1, facts, false
		}
		facts.started_by_asker = lent.started_by_asker != 0
		facts.started_by_start_policy = lent.started_by_start_policy != 0
		return idx, facts, true
	case .Connected:
		for i in 0 ..< req.connected_count {
			conn := &req.connected[i]
			if conn.handle_number == place {
				if conn.present == 0 {
					return -1, facts, false
				}
				idx, ok := process_find(s, {conn.process_slot, conn.process_serial})
				if !ok {
					return -1, facts, false
				}
				facts.asker_acts_for_principal = conn.asker_acts_for_principal != 0
				facts.process_is_a_service = conn.process_is_a_service != 0
				facts.asker_holds_a_connection = conn.asker_holds_a_connection != 0
				return idx, facts, true
			}
		}
		return -1, facts, false
	case .None:
	}
	return -1, facts, false
}

// paired_source_of gives the row of the source of the pair of the row
// number, whose writer writer_idx is a record output Paired whose module
// has the generic record input input_index. The rule
// (src/md/features/module_outputs.md, "The collector"):
//
// - the writer of a pair is a process that runs, never the child of a
//   start: it keeps the source before it forwards, so its reader end of
//   the source reaches it before the end of the pair;
// - its pace is Always_Holds_Writer, which the stall bound watches;
// - the row names its source: an earlier row of the list, whose reader is
//   the generic record input of the same process, and whose writer is
//   another process;
// - one source has one pair: a second row of the list that names the same
//   source is refused with Exists.
//
// Each refusal names the field and the row, and changes no state.
@(private = "file")
paired_source_of :: proc "contextless" (work: ^Plan_Work, number: u32, writer_idx: int, input_index: u32, has_input: bool) -> (source: ^Row_Plan, status: ws.Response_Status, refusal: errors.Error_Record) {
	plan := &work.plans[number - 1]
	row := plan.row
	found := i64(number)
	op_code := work.command_op
	if row.writer_end == .Child {
		return nil, .Bad_Command, make_error(op_code, .Unsupported, .Wiring_Rows, i64(output.Wiring_Field.Writer_End), i64(row.writer_end), 0, found)
	}
	// A pair has the pace of an audit: the stall bound of the wiring
	// service ends a ring that holds its writer past the hang bound, so a
	// consumer that never reads cannot hold the forward of the collector
	// for ever.
	if row.pace != .Always_Holds_Writer {
		return nil, .Bad_Command, make_error(op_code, .Unsupported, .Wiring_Rows, i64(output.Wiring_Field.Pace), i64(row.pace), i64(output.Wiring_Pace.Always_Holds_Writer), found)
	}
	pair := row.paired_row
	if pair == 0 || pair >= number {
		return nil, .Bad_Command, make_error(op_code, .Bad_Value, .Wiring_Rows, i64(output.Wiring_Field.Paired_Row), i64(pair), i64(number - 1), found)
	}
	source = &work.plans[pair - 1]
	if !has_input || source.row.reader_end == .Asker || source.reader_index != writer_idx || source.row.reader_index != input_index || source.writer_index == writer_idx {
		return nil, .Bad_Command, make_error(op_code, .Bad_Value, .Wiring_Rows, i64(output.Wiring_Field.Paired_Row), i64(pair), 0, found)
	}
	for other in 1 ..= work.list.row_count {
		if other != number && work.plans[other - 1].paired && work.plans[other - 1].row.paired_row == pair {
			return nil, .Bad_State, make_error(op_code, .Exists, .Wirings, i64(output.Wiring_Field.Paired_Row), i64(pair), 0, found)
		}
	}
	return source, .Ok, {}
}

@(private = "file")
resolve_row :: proc "contextless" (s: ^State, image: []u8, list_copy: []u8, req: ^ws.Resolved_Wiring_Request, work: ^Plan_Work, number: u32, first_pass: bool) -> (status: ws.Response_Status, refusal: errors.Error_Record) {
	plan := &work.plans[number - 1]
	row := plan.row
	found := i64(number)
	op_code := work.command_op

	if req.asker_is_start_policy != 0 {
		if field, allowed := output.start_policy_row_allowed(work.form, row.writer_end, row.reader_end); !allowed {
			return .No_Right, make_error(op_code, .No_Grant, .Wirings, i64(field), 0, 0, found)
		}
	}

	writer_idx, writer_facts, writer_found := resolve_end_from_request(s, work, req, row.writer_end, row.writer_handle)
	reader_idx, reader_facts, reader_found := resolve_end_from_request(s, work, req, row.reader_end, row.reader_handle)
	plan.writer_index = writer_idx
	plan.reader_index = reader_idx

	if !writer_found && row.writer_end == .Connected {
		return .Bad_Handle, make_error(op_code, .Absent, .Connections, i64(output.Wiring_Field.Writer_Handle), i64(row.writer_handle), 0, found)
	}
	if !reader_found && row.reader_end == .Connected {
		return .Bad_Handle, make_error(op_code, .Absent, .Connections, i64(output.Wiring_Field.Reader_Handle), i64(row.reader_handle), 0, found)
	}
	if !writer_found || !reader_found {
		return .Bad_Handle, make_error(op_code, .Handle_Absent, .Lent_Handles, 0, 0, 0, found)
	}
	if !output.wiring_end_allowed(row.writer_end, writer_facts) || !output.wiring_end_allowed(row.reader_end, reader_facts) {
		return .No_Right, make_error(op_code, .No_Grant, .Wirings, 0, 0, 0, found)
	}
	// Self-wire or directed cycle refused.
	if writer_idx == reader_idx || graph_reaches(s, work, number, reader_idx, writer_idx) {
		return .Bad_State, make_error(op_code, .Bad_Value, .Wirings, i64(output.Wiring_Field.Reader_End), 0, 0, found)
	}

	writer_file: []u8
	if row.writer_stream == .Log {
		if row.condition_offset != 0 {
			return .Bad_Command, make_error(op_code, .Unsupported, .Wiring_Rows, i64(output.Wiring_Field.Condition_Offset), i64(row.condition_offset), 0, found)
		}
		if row.pace == .Never_Holds_Writer {
			return .Bad_Command, make_error(op_code, .Unsupported, .Wiring_Rows, i64(output.Wiring_Field.Pace), i64(row.pace), 0, found)
		}
		writer_file = log_output_file(s)
		if len(writer_file) == 0 {
			return .Bad_State, make_error(op_code, .Absent, .Modules, 0, 0, 0, found)
		}
		plan.writer_is_log_file = true
		plan.writer_file_offset = 0
		plan.writer_file_size = 0
		plan.description = output.DESCRIPTION_RECORD_INDEX
	} else {
		wf, woff, wsize := process_file_slice(s, work, image, writer_idx)
		if len(wf) == 0 {
			return .Bad_State, make_error(op_code, .Absent, .Modules, 0, 0, 0, found)
		}
		writer_file = wf
		plan.writer_is_log_file = false
		plan.writer_file_offset = woff
		plan.writer_file_size = wsize
		output_row, pairing, _, output_ok := module.record_output(writer_file, row.writer_index)
		if !output_ok {
			outputs := max(module.count(writer_file, .Record_Outputs), 1) - 1
			return .Bad_Command, make_error(op_code, .Bad_Value, .Wiring_Rows, i64(output.Wiring_Field.Writer_Index), i64(row.writer_index), i64(outputs), found)
		}
		plan.description = output_row.record
		// A record output Paired takes the type of each source: a record of
		// its own would bypass the rule of the pairs. The border of the
		// module file refuses it too; this check does not lean on that.
		if pairing == .Paired && output_row.record != 0 {
			return .Bad_Command, make_error(op_code, .Unsupported, .Wiring_Rows, i64(output.Wiring_Field.Writer_Index), i64(row.writer_index), 0, found)
		}
		// A pair names its source only beside a record output Paired.
		if pairing == .Unpaired && row.paired_row != 0 {
			return .Bad_Command, make_error(op_code, .Bad_Value, .Wiring_Rows, i64(output.Wiring_Field.Paired_Row), i64(row.paired_row), 0, found)
		}
		if output_row.record == 0 && first_pass {
			plan.deferred = true
			return .Ok, {}
		}
		if output_row.record == 0 {
			input_index, input_wirings, has_input := generic_input_of(writer_file)
			fixed_file, fixed_is_log, fixed_off, fixed_size, fixed_desc, fixed := generic_type_fixed(s, work, image, number, writer_idx, input_index)
			switch output.generic_writer_step_of(0, pairing, input_wirings, fixed && has_input) {
			case .Declared:
			case .Fixed_Type:
				writer_file = fixed_file
				plan.writer_is_log_file = fixed_is_log
				plan.writer_file_offset = fixed_off
				plan.writer_file_size = fixed_size
				plan.description = fixed_desc
			case .Not_Fixed:
				return .Bad_Command, make_error(op_code, .Bad_Value, .Record_Types, 0, i64(output.Description_Difference.Not_Fixed), 0, found)
			case .Paired_Source:
				source, pair_status, pair_refusal := paired_source_of(work, number, writer_idx, input_index, has_input)
				if pair_status != .Ok {
					return pair_status, pair_refusal
				}
				writer_file = plan_file_slice(s, image, source.writer_is_log_file, source.writer_file_offset, source.writer_file_size)
				plan.writer_is_log_file = source.writer_is_log_file
				plan.writer_file_offset = source.writer_file_offset
				plan.writer_file_size = source.writer_file_size
				plan.description = source.description
				plan.paired = true
			}
		}
	}

	reader_file := writer_file
	reader_description := plan.description
	if row.reader_end != .Asker {
		rf, _, _ := process_file_slice(s, work, image, reader_idx)
		if len(rf) == 0 {
			return .Bad_State, make_error(op_code, .Absent, .Modules, 0, 0, 0, found)
		}
		reader_file = rf
		input_row, wirings, _, terms, input_ok := module.record_input(reader_file, row.reader_index)
		if !input_ok {
			inputs := max(module.count(reader_file, .Record_Inputs), 1) - 1
			return .Bad_Command, make_error(op_code, .Bad_Value, .Wiring_Rows, i64(output.Wiring_Field.Reader_Index), i64(row.reader_index), i64(inputs), found)
		}
		reader_description = input_row.record
		if input_row.terms != 0 {
			plan.terms_size = terms.size
		}
		if wirings == .One && record_input_taken(s, work, number, reader_idx, row.reader_index) {
			return .Bad_State, make_error(op_code, .Exists, .Wirings, i64(output.Wiring_Field.Reader_Index), i64(row.reader_index), 0, found)
		}
		fixed_file, _, _, _, fixed_desc, fixed := generic_type_fixed(s, work, image, number, reader_idx, row.reader_index)
		step := output.generic_reader_step_of(input_row.record, wirings, fixed)
		plan.keeps_type = output.generic_reader_keeps(step)
		switch step {
		case .Compare_Declared:
		case .Compare_Fixed:
			reader_file, reader_description = fixed_file, fixed_desc
		case .Take_Each:
			reader_file, reader_description = writer_file, plan.description
		case .Fix:
			kept_count := 0
			if reader_idx >= 0 {
				kept_count = s.processes[reader_idx].generic_type_count
			}
			listed := generic_types_listed(work, number, reader_idx)
			if !output.generic_type_room_of(kept_count, listed, GENERIC_TYPES_OF_A_PROCESS_MOST) {
				return .No_Slot, make_error(op_code, .Full, .Wirings, 0, i64(kept_count + listed + 1), GENERIC_TYPES_OF_A_PROCESS_MOST, found)
			}
			reader_file, reader_description = writer_file, plan.description
			plan.fixes = true
		}
	}

	difference, part := output.record_descriptions_compare(writer_file, plan.description, reader_file, reader_description)
	if difference != .Equal {
		return .Bad_Command, make_error(op_code, .Bad_Value, .Record_Types, 0, i64(difference), i64(part), found)
	}
	if row.terms_count != plan.terms_size {
		return .Bad_Command, make_error(op_code, .Bad_Value, .Wiring_Terms, i64(output.Wiring_Field.Terms_Count), i64(row.terms_count), i64(plan.terms_size), found)
	}
	plan.has_condition = false
	if row.condition_offset != 0 {
		description, _ := module.record_stream_type(writer_file, plan.description)
		terms_slice := list_copy[row.condition_offset:][:size_of(output.Condition_Terms)]
		condition, cond_refusal, condition_ok := output.writer_condition_of_terms(terms_slice, writer_file, description)
		if !condition_ok {
			cond_refusal.operation = i64(op_code)
			cond_refusal.found = found
			return .Bad_Command, cond_refusal
		}
		plan.condition = condition
		plan.has_condition = true
	}
	return .Ok, {}
}

@(private = "file")
ends_needed :: proc "contextless" (work: ^Plan_Work, proc_idx: int) -> (needed: u32) {
	for number in 1 ..= work.list.row_count {
		plan := &work.plans[number - 1]
		if plan.writer_index == proc_idx {
			needed += 1
		}
		if plan.reader_index == proc_idx {
			needed += 1
		}
	}
	return needed
}

@(private = "file")
connected_ends_needed :: proc "contextless" (work: ^Plan_Work, proc_idx: int) -> (needed: u32) {
	for number in 1 ..= work.list.row_count {
		plan := &work.plans[number - 1]
		if plan.writer_index == proc_idx && plan.row.writer_end == .Connected {
			needed += 1
		}
		if plan.reader_index == proc_idx && plan.row.reader_end == .Connected {
			needed += 1
		}
	}
	return needed
}

@(private = "file")
asker_ends_in :: proc "contextless" (s: ^State, asker_idx: int, proc_idx: int) -> (held: int) {
	for &kept in s.wirings {
		if !kept.active || kept.asker_index != asker_idx {
			continue
		}
		if kept.writer_index == proc_idx && kept.writer_counted {
			held += 1
		}
		if kept.reader_index == proc_idx && kept.reader_counted {
			held += 1
		}
	}
	return held
}

@(private = "file")
check_limits :: proc "contextless" (s: ^State, work: ^Plan_Work, ring_room: Ring_Room_Proc, ring_room_data: rawptr) -> (status: ws.Response_Status, refusal: errors.Error_Record) {
	op_code := work.command_op
	rows := int(work.list.row_count)
	asker := &s.processes[work.asker_index]
	if asker.wirings_asked + rows > output.WIRINGS_OF_AN_ASKER_MOST {
		return .No_Slot, make_error(op_code, .Full, .Wirings, 0, i64(asker.wirings_asked + rows), output.WIRINGS_OF_AN_ASKER_MOST)
	}
	if s.wirings_running + rows > WIRINGS_OF_THE_MACHINE_MOST {
		return .No_Slot, make_error(op_code, .Full, .Wirings, 0, i64(s.wirings_running + rows), WIRINGS_OF_THE_MACHINE_MOST)
	}
	for number in 1 ..= work.list.row_count {
		plan := &work.plans[number - 1]
		ends := [2]int{plan.writer_index, plan.reader_index}
		connected := [2]bool{plan.row.writer_end == .Connected, plan.row.reader_end == .Connected}
		for proc_idx, side in ends {
			needed := ends_needed(work, proc_idx)
			given := proc_idx >= 0 ? s.processes[proc_idx].ends_given : 0
			if given + int(needed) > ENDS_OF_A_PROCESS_MOST {
				return .No_Slot, make_error(op_code, .Full, .Wirings, 0, i64(given + int(needed)), ENDS_OF_A_PROCESS_MOST, i64(number))
			}
			if connected[side] && proc_idx >= 0 {
				held := asker_ends_in(s, work.asker_index, proc_idx)
				through_connection := connected_ends_needed(work, proc_idx)
				if held + int(through_connection) > CONNECTED_ENDS_OF_AN_ASKER_MOST {
					return .No_Slot, make_error(op_code, .Full, .Wirings, 0, i64(held + int(through_connection)), CONNECTED_ENDS_OF_AN_ASKER_MOST, i64(number))
				}
			}
			if proc_idx == CHILD_PROCESS_INDEX {
				continue
			}
			if ring_room != nil {
				available, capacity, has_ring := ring_room(ring_room_data, proc_idx)
				if !has_ring {
					return .Bad_State, make_error(op_code, .Absent, .Wirings, 0, 0, 0, i64(number))
				}
				if available < needed {
					return .No_Slot, make_error(op_code, .Busy, .Wirings, 0, i64(needed), i64(capacity), i64(number))
				}
			}
		}
	}
	return .Ok, {}
}

// plan_resolve validates a copied wiring list and resolved core request
// completely without mutating State. On refusal, State is untouched.
plan_resolve :: proc "contextless" (s: ^State, image: []u8, list_copy: []u8, req: ^ws.Resolved_Wiring_Request, asker_id: ws.Process_Identity, command_op: u32, work: ^Plan_Work, ring_room: Ring_Room_Proc = nil, ring_room_data: rawptr = nil) -> (status: ws.Response_Status, refusal: errors.Error_Record) {
	work^ = {}
	asker_idx, asker_found := process_find(s, asker_id)
	if !asker_found {
		return .Bad_Handle, make_error(command_op, .Absent, .Processes)
	}
	form, req_ok := ws.resolved_request_check(req)
	if !req_ok || int(req.list_bytes) > len(list_copy) {
		return .Bad_Command, make_error(command_op, .Bad_Value, .Wiring_Rows)
	}
	list_refusal, list_ok := output.wiring_list_check(list_copy[:req.list_bytes], form, &work.list)
	if !list_ok {
		list_refusal.operation = i64(command_op)
		return .Bad_Command, list_refusal
	}
	work.asker_index = asker_idx
	work.command_op = command_op
	work.form = form
	work.child_offset = req.child_module_offset
	work.child_size = req.child_module_size

	asker_rows := 0
	for number in 1 ..= work.list.row_count {
		work.plans[number - 1] = {
			row            = work.list.rows[number - 1],
			allocated_slot = -1,
		}
		row_status, row_refusal := resolve_row(s, image, list_copy, req, work, number, true)
		if row_status != .Ok {
			return row_status, row_refusal
		}
		if work.plans[number - 1].row.reader_end == .Asker {
			asker_rows += 1
		}
	}
	// Resolve deferred generic record outputs in topological sweeps.
	for _ in 1 ..= work.list.row_count {
		progress := false
		for number in 1 ..= work.list.row_count {
			plan := &work.plans[number - 1]
			if plan.deferred && !plan.resolved && deferred_type_fixed(s, work, image, number) {
				row_status, row_refusal := resolve_row(s, image, list_copy, req, work, number, false)
				if row_status != .Ok {
					return row_status, row_refusal
				}
				plan.resolved = true
				progress = true
			}
		}
		if !progress {
			break
		}
	}
	for number in 1 ..= work.list.row_count {
		plan := &work.plans[number - 1]
		if plan.deferred && !plan.resolved {
			row_status, row_refusal := resolve_row(s, image, list_copy, req, work, number, false)
			if row_status != .Ok {
				return row_status, row_refusal
			}
			plan.resolved = true
		}
	}
	if form == .Start && asker_rows > output.WIRING_ASKER_ROWS_OF_A_START {
		return .Bad_Command, make_error(command_op, .Bad_Value, .Wiring_Rows, i64(output.Wiring_Field.Reader_End), i64(asker_rows), output.WIRING_ASKER_ROWS_OF_A_START)
	}
	return check_limits(s, work, ring_room, ring_room_data)
}

// wiring_number_take allocates the next unused non-zero wiring number.
wiring_number_take :: proc "contextless" (s: ^State) -> u32 {
	if s.wiring_number_next == 0 {
		s.wiring_number_next = 1
	}
	for {
		number := s.wiring_number_next
		s.wiring_number_next = number == max(u32) ? 1 : number + 1
		in_use := false
		for &kept in s.wirings {
			if kept.active && kept.number == number {
				in_use = true
				break
			}
		}
		if number != 0 && !in_use {
			return number
		}
	}
}

// wiring_slot_allocate claims a free slot in State.wirings for one resolved row.
wiring_slot_allocate :: proc "contextless" (s: ^State, asker_index: int, plan: ^Row_Plan) -> (slot: int, number: u32, ok: bool) {
	free_slot := -1
	for &kept, idx in s.wirings {
		if !kept.active {
			free_slot = idx
			break
		}
	}
	if free_slot < 0 {
		return -1, 0, false
	}
	number = wiring_number_take(s)
	s.wirings[free_slot] = {
		active              = true,
		number              = number,
		asker_index         = asker_index,
		writer_index        = plan.writer_index,
		reader_index        = plan.reader_index,
		writer_stream_index = plan.row.writer_index,
		reader_stream_index = plan.row.reader_index,
		pace                = plan.row.pace,
		writer_is_log       = plan.row.writer_stream == .Log,
		reader_is_asker     = plan.row.reader_end == .Asker,
	}
	s.wirings_running += 1
	plan.allocated_slot = free_slot
	plan.allocated_number = number
	return free_slot, number, true
}

// wiring_bind_child replaces CHILD_PROCESS_INDEX with the child's actual
// registered process index upon Commit_Start_Wiring.
wiring_bind_child :: proc "contextless" (s: ^State, wiring_slot: int, child_proc_index: int) {
	if wiring_slot < 0 || wiring_slot >= WIRINGS_OF_THE_MACHINE_MOST || !s.wirings[wiring_slot].active {
		return
	}
	kept := &s.wirings[wiring_slot]
	if kept.writer_index == CHILD_PROCESS_INDEX {
		kept.writer_index = child_proc_index
	}
	if kept.reader_index == CHILD_PROCESS_INDEX {
		kept.reader_index = child_proc_index
	}
}

// wiring_mark_delivered updates writer, reader, asker counts and fixes any
// generic reader type once both sides of a wiring have been delivered.
wiring_mark_delivered :: proc "contextless" (s: ^State, wiring_slot: int, plan: ^Row_Plan) {
	if wiring_slot < 0 || wiring_slot >= WIRINGS_OF_THE_MACHINE_MOST || !s.wirings[wiring_slot].active {
		return
	}
	kept := &s.wirings[wiring_slot]
	if !kept.writer_counted && kept.writer_index >= 0 {
		kept.writer_counted = true
		s.processes[kept.writer_index].ends_given += 1
		if kept.writer_is_log {
			s.processes[kept.writer_index].log_ends_given += 1
		}
	}
	if !kept.reader_counted && kept.reader_index >= 0 {
		kept.reader_counted = true
		s.processes[kept.reader_index].ends_given += 1
	}
	if plan != nil && plan.keeps_type && kept.reader_index >= 0 {
		generic_type_keep(&s.processes[kept.reader_index], plan)
	}
	if !kept.asked_counted && kept.asker_index >= 0 {
		kept.asked_counted = true
		s.processes[kept.asker_index].wirings_asked += 1
	}
}

@(private = "file")
generic_type_keep :: proc "contextless" (entry: ^Process_Entry, plan: ^Row_Plan) {
	for kept in entry.generic_types[:entry.generic_type_count] {
		if kept.index == plan.row.reader_index {
			return
		}
	}
	if entry.generic_type_count < len(entry.generic_types) {
		entry.generic_types[entry.generic_type_count] = {
			index       = plan.row.reader_index,
			description = plan.description,
			is_log_file = plan.writer_is_log_file,
			file_offset = plan.writer_file_offset,
			file_size   = plan.writer_file_size,
		}
		entry.generic_type_count += 1
	}
}

// wiring_end_slot releases an active wiring slot and updates all counters.
// Returns the effective End_Word to write (None if end_written already or
// asked == .None) and whether asker's wirings_asked just hit 0.
wiring_end_slot :: proc "contextless" (s: ^State, wiring_slot: int, asked: output.End_Word) -> (end_to_write: output.End_Word, asker_empty: bool) {
	if wiring_slot < 0 || wiring_slot >= WIRINGS_OF_THE_MACHINE_MOST || !s.wirings[wiring_slot].active {
		return .None, false
	}
	kept := &s.wirings[wiring_slot]
	end_to_write = output.end_word_to_write(kept.end_written, asked)
	if end_to_write != .None {
		kept.end_written = true
	}
	if kept.writer_counted && kept.writer_index >= 0 {
		s.processes[kept.writer_index].ends_given -= 1
		if kept.writer_is_log {
			s.processes[kept.writer_index].log_ends_given -= 1
		}
	}
	if kept.reader_counted && kept.reader_index >= 0 {
		s.processes[kept.reader_index].ends_given -= 1
	}
	if kept.asked_counted && kept.asker_index >= 0 {
		s.processes[kept.asker_index].wirings_asked -= 1
		if s.processes[kept.asker_index].wirings_asked == 0 {
			asker_empty = true
		}
	}
	kept^ = {}
	if s.wirings_running > 0 {
		s.wirings_running -= 1
	}
	return end_to_write, asker_empty
}

// wiring_completion_apply processes one completion record from a process's
// wiring ring (Taken, Closed, or refusal) and returns the required effect.
wiring_completion_apply :: proc "contextless" (s: ^State, proc_index: int, record: ring.Record) -> Completion_Action {
	status, tag, answer, _, ok := output.wiring_completion_of_record(record)
	wiring_slot := -1
	for &kept, idx in s.wirings {
		if kept.active && kept.number == record.tag && (kept.writer_index == proc_index || kept.reader_index == proc_index) {
			wiring_slot = idx
			break
		}
	}
	if wiring_slot >= 0 {
		kept := &s.wirings[wiring_slot]
		// The end of log came in the writer's context, never through its wiring ring.
		if kept.writer_index == proc_index && kept.writer_is_log {
			wiring_slot = -1
		}
	}
	if wiring_slot < 0 {
		return {effect = .Unknown_Word, wiring_slot = -1, wiring_number = record.tag}
	}
	kept := &s.wirings[wiring_slot]
	is_writer := kept.writer_index == proc_index
	answered := is_writer ? &kept.writer_answered : &kept.reader_answered
	closed := is_writer ? &kept.writer_closed : &kept.reader_closed
	counted := is_writer ? &kept.writer_counted : &kept.reader_counted

	if counted^ && !answered^ {
		answered^ = true
		if ok && status == .Ok && answer == .Taken {
			return {effect = .None, wiring_slot = wiring_slot, wiring_number = kept.number}
		}
		end_word, _ := wiring_end_slot(s, wiring_slot, .Refused)
		return {
			effect        = .End_Wiring,
			wiring_slot   = wiring_slot,
			wiring_number = tag,
			end_word      = end_word,
			side_status   = status,
			border_ok     = ok,
		}
	}
	if counted^ && !closed^ && ok && status == .Ok && answer == .Closed {
		closed^ = true
		counted^ = false
		s.processes[proc_index].ends_given -= 1
		if kept.writer_closed && kept.reader_closed {
			number := kept.number
			_, _ = wiring_end_slot(s, wiring_slot, .None)
			return {effect = .End_Wiring, wiring_slot = wiring_slot, wiring_number = number, end_word = .None}
		}
		end_word := output.end_word_to_write(kept.end_written, .Side_Closed)
		if end_word != .None {
			kept.end_written = true
		}
		return {effect = .Write_End_Word, wiring_slot = wiring_slot, wiring_number = kept.number, end_word = end_word}
	}
	first_drop := !kept.dropped_told
	kept.dropped_told = true
	return {effect = .Dropped_Word, wiring_slot = wiring_slot, wiring_number = kept.number, first_drop = first_drop}
}

// unwire_apply ends a single wiring owned by asker_id with end_word.
// Refuses unknown askers, unknown wiring numbers, or wirings owned by another asker.
unwire_apply :: proc "contextless" (s: ^State, asker_id: ws.Process_Identity, wiring_number: u32, end_word: output.End_Word, command_op: u32) -> (wiring_slot: int, end_to_write: output.End_Word, asker_empty: bool, status: ws.Response_Status, refusal: errors.Error_Record) {
	if end_word == .None || wiring_number == 0 {
		return -1, .None, false, .Bad_Command, make_error(command_op, .Bad_Value, .Wirings)
	}
	asker_idx, asker_found := process_find(s, asker_id)
	if !asker_found {
		return -1, .None, false, .Bad_Handle, make_error(command_op, .Absent, .Processes)
	}
	for &kept, idx in s.wirings {
		if kept.active && kept.number == wiring_number {
			if kept.asker_index != asker_idx {
				return -1, .None, false, .No_Right, make_error(command_op, .No_Grant, .Wirings)
			}
			written, empty := wiring_end_slot(s, idx, end_word)
			return idx, written, empty, .Ok, {}
		}
	}
	return -1, .None, false, .Bad_Handle, make_error(command_op, .Absent, .Wirings)
}

// revoke_asker_apply ends every wiring asked by asker_id with End_Word.Revoked
// and writes each action into `actions`.
revoke_asker_apply :: proc "contextless" (s: ^State, asker_id: ws.Process_Identity, actions: []Stop_Action) -> (count: int, found: bool) {
	asker_idx, ok := process_find(s, asker_id)
	if !ok {
		return 0, false
	}
	for idx in 0 ..< WIRINGS_OF_THE_MACHINE_MOST {
		kept := &s.wirings[idx]
		if !kept.active || kept.asker_index != asker_idx {
			continue
		}
		number := kept.number
		end_word, asker_empty := wiring_end_slot(s, idx, .Revoked)
		if count < len(actions) {
			actions[count] = {
				kind          = .End_Wiring,
				wiring_slot   = idx,
				wiring_number = number,
				end_word      = end_word,
				asker_index   = asker_idx,
				asker_empty   = asker_empty,
			}
		}
		count += 1
	}
	return count, true
}

// process_stop_apply handles one Process_Stop_Notice from the core's `stops`
// output. A stale serial (not matching any active Process_Entry) is ignored
// with matched = false and zero state mutation. Otherwise every wiring
// naming the process is detached (if its side already closed while the peer
// stays open) or ended with the proper End_Word, and the process slot is freed.
process_stop_apply :: proc "contextless" (s: ^State, notice: ws.Process_Stop_Notice, actions: []Stop_Action) -> (action_count: int, proc_index: int, matched: bool) {
	idx, found := process_find(s, {notice.process_slot, notice.process_serial})
	if !found {
		return 0, -1, false
	}
	stopped_by_kernel := notice.kind == .Process_Stopped && notice.cause != .None
	for w_idx in 0 ..< WIRINGS_OF_THE_MACHINE_MOST {
		kept := &s.wirings[w_idx]
		if !kept.active {
			continue
		}
		end := output.End_Word.None
		switch {
		case kept.writer_index == idx:
			end = .Writer_Stopped
		case kept.reader_index == idx && !kept.reader_is_asker:
			end = .Reader_Stopped
		case kept.asker_index == idx:
			end = .Asker_Stopped
		}
		if end == .None {
			continue
		}
		number := kept.number
		asker_idx := kept.asker_index
		if end == .Writer_Stopped && output.stop_step_of(kept.writer_closed, kept.reader_closed) == .Detach {
			kept.writer_index = DETACHED_PROCESS_INDEX
			if action_count < len(actions) {
				actions[action_count] = {kind = .Detach, wiring_slot = w_idx, wiring_number = number, asker_index = asker_idx}
			}
			action_count += 1
			continue
		}
		if end == .Reader_Stopped && output.stop_step_of(kept.reader_closed, kept.writer_closed) == .Detach {
			kept.reader_index = DETACHED_PROCESS_INDEX
			if action_count < len(actions) {
				actions[action_count] = {kind = .Detach, wiring_slot = w_idx, wiring_number = number, asker_index = asker_idx}
			}
			action_count += 1
			continue
		}
		// If the process was both writer and asker, or stopped without kernel
		// record, compute the final end word and stop fields.
		cause := op.Stop_Cause.None
		outcome := op.Stop_Outcome.None
		asked := end
		if end == .Writer_Stopped {
			if stopped_by_kernel {
				cause = notice.cause
				outcome = notice.outcome
			} else {
				asked = .Revoked
			}
		}
		end_word, asker_empty := wiring_end_slot(s, w_idx, asked)
		if action_count < len(actions) {
			actions[action_count] = {
				kind          = .End_Wiring,
				wiring_slot   = w_idx,
				wiring_number = number,
				end_word      = end_word,
				stop_cause    = cause,
				stop_outcome  = outcome,
				asker_index   = asker_idx,
				asker_empty   = asker_empty,
			}
		}
		action_count += 1
	}
	if s.processes[idx].has_list_page && s.list_page_holders > 0 {
		s.list_page_holders -= 1
	}
	s.processes[idx] = {}
	return action_count, idx, true
}

// wiring_stall_observe updates the monotonic stall tracker for one wiring.
// Only active Always_Holds_Writer wirings participate; Never_Holds_Writer
// and Writer_Chooses wirings are never tracked or revoked here.
//
// When the ring is observed full, stalled_since_ms is latched at now_ms with
// the observed read cursor. The instant read_cursor advances or the ring is
// no longer full, stall tracking resets to 0.
wiring_stall_observe :: proc "contextless" (s: ^State, wiring_slot: int, ring_full: bool, read_cursor: u32, now_ms: u64) {
	if wiring_slot < 0 || wiring_slot >= WIRINGS_OF_THE_MACHINE_MOST {
		return
	}
	kept := &s.wirings[wiring_slot]
	if !kept.active || kept.pace != .Always_Holds_Writer {
		kept.stall_active = false
		kept.stalled_since_ms = 0
		kept.stalled_read_cursor = 0
		return
	}
	if !ring_full {
		kept.stall_active = false
		kept.stalled_since_ms = 0
		kept.stalled_read_cursor = read_cursor
		return
	}
	if !kept.stall_active {
		kept.stall_active = true
		kept.stalled_since_ms = now_ms
		kept.stalled_read_cursor = read_cursor
		return
	}
	if read_cursor != kept.stalled_read_cursor {
		// Reader made progress: clear the stall deadline immediately.
		kept.stall_active = false
		kept.stalled_since_ms = 0
		kept.stalled_read_cursor = read_cursor
	}
}

// wiring_stall_expire revokes every active Always_Holds_Writer wiring whose
// ring stayed full without reader progress for at least STALL_HANG_BOUND_MS,
// recording each revocation into actions. Healthy sibling wirings and
// non-Always_Holds_Writer wirings remain untouched. Never mutates a wiring
// unless its Stop_Action fits in actions.
wiring_stall_expire :: proc "contextless" (s: ^State, now_ms: u64, actions: []Stop_Action) -> (count: int) {
	if len(actions) == 0 {
		return 0
	}
	for idx in 0 ..< WIRINGS_OF_THE_MACHINE_MOST {
		if count >= len(actions) {
			break
		}
		kept := &s.wirings[idx]
		if !kept.active || kept.pace != .Always_Holds_Writer || !kept.stall_active {
			continue
		}
		if now_ms < kept.stalled_since_ms || now_ms - kept.stalled_since_ms < STALL_HANG_BOUND_MS {
			continue
		}
		number := kept.number
		asker_idx := kept.asker_index
		end_word, asker_empty := wiring_end_slot(s, idx, .Revoked)
		actions[count] = {
			kind          = .End_Wiring,
			wiring_slot   = idx,
			wiring_number = number,
			end_word      = end_word,
			asker_index   = asker_idx,
			asker_empty   = asker_empty,
		}
		count += 1
	}
	return count
}

// wiring_stall_next_deadline computes the next wake deadline (milliseconds)
// for the wiring service loop when any active Always_Holds_Writer wiring is
// watched. Returns has_watched = false when no Always_Holds_Writer wiring is
// active so the loop can sleep indefinitely.
wiring_stall_next_deadline :: proc "contextless" (s: ^State, now_ms: u64, poll_interval_ms: u64) -> (deadline_ms: u64, has_watched: bool) {
	best := max(u64)
	for &kept in s.wirings {
		if !kept.active || kept.pace != .Always_Holds_Writer {
			continue
		}
		has_watched = true
		poll_at := now_ms > max(u64) - poll_interval_ms ? max(u64) : now_ms + poll_interval_ms
		candidate := poll_at
		if kept.stall_active {
			expire_at := kept.stalled_since_ms > max(u64) - STALL_HANG_BOUND_MS ? max(u64) : kept.stalled_since_ms + STALL_HANG_BOUND_MS
			candidate = min(candidate, expire_at)
		}
		best = min(best, candidate)
	}
	if !has_watched {
		return 0, false
	}
	return best, true
}

// registered_process_count returns the count of active processes in State.
registered_process_count :: proc "contextless" (s: ^State) -> (count: u64) {
	for &entry in s.processes {
		if entry.active {
			count += 1
		}
	}
	return count
}
