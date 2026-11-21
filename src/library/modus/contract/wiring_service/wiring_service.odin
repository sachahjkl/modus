// The contract of the delegated wiring service: what the root service core
// and the `wiring` service agree on (src/md/api/root_service_split.md).
//
// The root service core starts `wiring` with four attenuated handles in its
// context:
//
// - `SERVICE_RING`: the command and response ring between the core and
//   `wiring`. Only the core writes commands there.
// - `SERVICE_STOPS_RING`: the `stops` record output ring from the core to
//   `wiring`. The core writes one `Process_Stop_Notice` for each stopped
//   process so `wiring` ends its wirings and frees its slots without
//   polling or broadcast.
// - `SERVICE_IMAGE`: the boot image, with the right Read only, for reading
//   the record-stream descriptions of module files during type matching.
// - `SERVICE_REGION`: the shared transfer region for the copied wiring
//   list, the core's resolved process identities, and the child ends of a
//   prepared Start.
//
// Per-asker and per-process authority crosses `SERVICE_RING` in attenuated
// form only: a child wiring budget with Spend only, a process handle with
// Give only, and the wiring ring memory of each stream process.
//
// This package calls no kernel operation and imports no support package.
package wiring_service

import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/output"
import "modus:contract/ring"

// The context slots of the `wiring` delegated service.
SERVICE_RING :: 0 // Memory (Read, Write): command and response ring from the core.
SERVICE_STOPS_RING :: 1 // Memory (Read, Write): stops record output ring from the core.
SERVICE_IMAGE :: 2 // Memory (Read): boot image module files for type matching.
SERVICE_REGION :: 3 // Memory (Read, Write): shared transfer region.

// The context value holding the byte size of SERVICE_IMAGE.
VALUE_IMAGE_SIZE :: 0

// The layout of SERVICE_REGION: six pages (24 KiB).
//   pages 0..3: copy of the asker's wiring list (WIRING_LIST_BYTES_MOST)
//   page  4:    Resolved_Wiring_Request written by the core
//   page  5:    Prepared_Start_Ends written by wiring for Prepare_Start_Wiring
REGION_LIST_OFFSET :: 0
REGION_LIST_SIZE :: output.WIRING_LIST_BYTES_MOST
REGION_REQUEST_OFFSET :: REGION_LIST_OFFSET + REGION_LIST_SIZE
REGION_REQUEST_SIZE :: ring.PAGE_SIZE
REGION_RESPONSE_OFFSET :: REGION_REQUEST_OFFSET + REGION_REQUEST_SIZE
REGION_RESPONSE_SIZE :: ring.PAGE_SIZE
SERVICE_REGION_PAGES :: (REGION_RESPONSE_OFFSET + REGION_RESPONSE_SIZE) / ring.PAGE_SIZE
SERVICE_REGION_SIZE :: SERVICE_REGION_PAGES * ring.PAGE_SIZE

#assert(REGION_LIST_OFFSET == 0)
#assert(REGION_LIST_SIZE == 4 * ring.PAGE_SIZE)
#assert(REGION_REQUEST_OFFSET == 4 * ring.PAGE_SIZE)
#assert(REGION_RESPONSE_OFFSET == 5 * ring.PAGE_SIZE)
#assert(SERVICE_REGION_PAGES == 6)

// The largest count of distinct connected-service resolutions carried in
// one Resolved_Wiring_Request: up to two ends per row.
RESOLVED_CONNECTED_LIMIT :: 2 * output.WIRING_LIST_ROW_LIMIT

// Attenuated grant classes supplied by the root core to `wiring`.
// Each member names one narrow class of authority; attenuated_rights_of
// returns the exact maximal kernel rights for that class.
Attenuated_Grant_Kind :: enum u32 {
	None                 = 0, // Refused.
	Asker_Wiring_Budget  = 1, // Child wiring budget of an asker: Spend only.
	Stream_Process_Token = 2, // Process handle for a stream process: Give only.
	Process_Wiring_Ring  = 3, // Wiring ring memory of a process: Read and Write.
	Read_Only_Image      = 4, // Boot image view for type matching: Read only.
}

// attenuated_rights_of gives the exact maximal rights that `wiring` holds
// for each attenuated grant class. None and any unknown member are refused.
attenuated_rights_of :: proc "contextless" (kind: Attenuated_Grant_Kind) -> (rights: op.Rights, ok: bool) {
	switch kind {
	case .None:
		return {}, false
	case .Asker_Wiring_Budget:
		return {.Spend}, true
	case .Stream_Process_Token:
		return {.Give}, true
	case .Process_Wiring_Ring:
		return {.Read, .Write}, true
	case .Read_Only_Image:
		return {.Read}, true
	}
	return {}, false
}

// attenuated_rights_allowed checks that a handle's kernel rights stay
// strictly within the attenuated ceiling of its grant class and are non-empty.
attenuated_rights_allowed :: proc "contextless" (kind: Attenuated_Grant_Kind, held: op.Rights) -> bool {
	allowed, ok := attenuated_rights_of(kind)
	if !ok || held == {} {
		return false
	}
	return (held &~ allowed) == {}
}

// Canonical identity of a process: its kernel process slot and serial.
// Both must be non-zero, and slot must be below op.PROCESS_SLOTS_OF_THE_MACHINE.
Process_Identity :: struct {
	slot:   u64,
	serial: u64,
}

// process_identity_valid checks whether a process slot and serial can name
// a running process of the machine.
process_identity_valid :: proc "contextless" (identity: Process_Identity) -> bool {
	return identity.slot >= 1 && identity.slot < op.PROCESS_SLOTS_OF_THE_MACHINE && identity.serial != 0
}

// Flags describing a process registered with `wiring`. The values cross
// SERVICE_RING, so every bit position is explicit and unknown bits are
// refused at the border.
Process_Flag :: enum u32 {
	Is_Service         = 0, // Process serves isolated calls.
	Is_Start_Policy    = 1, // Process holds Start_Policy.
	Acts_For_Principal = 2, // Process acts for its principal.
	Can_Wire           = 3, // Process can ask for wirings.
	Has_Wiring_Ring    = 4, // Process has a wiring ring handle attached.
}

Process_Flags :: bit_set[Process_Flag; u32]

PROCESS_FLAGS_KNOWN_MASK :: u64(
	(u32(1) << u32(Process_Flag.Is_Service)) |
	(u32(1) << u32(Process_Flag.Is_Start_Policy)) |
	(u32(1) << u32(Process_Flag.Acts_For_Principal)) |
	(u32(1) << u32(Process_Flag.Can_Wire)) |
	(u32(1) << u32(Process_Flag.Has_Wiring_Ring)),
)

// process_flags_from_word is the border for Process_Flags: any bit outside
// the declared flags is refused.
process_flags_from_word :: proc "contextless" (word: u64) -> (flags: Process_Flags, ok: bool) {
	if word &~ PROCESS_FLAGS_KNOWN_MASK != 0 {
		return {}, false
	}
	return transmute(Process_Flags)u32(word), true
}

// Commands sent by the root core to `wiring` over SERVICE_RING.
// The values cross the ring border, so every value is explicit.
Command_Kind :: enum u32 {
	None                 = 0, // Refused.
	Register_Process     = 1, // Register a process with its attenuated token, wiring ring, module slice, and flags.
	Grant_Asker_Budget   = 2, // Supply an asker's Spend-only child wiring budget handle.
	List_Page            = 3, // Create or return the asker's list page (and wiring ring if absent).
	Wire                 = 4, // Apply a 1-row Wire list staged in SERVICE_REGION.
	Prepare_Start_Wiring = 5, // Validate and allocate a Start wiring list staged in SERVICE_REGION.
	Commit_Start_Wiring  = 6, // Deliver peer ends of a prepared Start batch after Process_Start succeeded.
	Abort_Start_Wiring   = 7, // Destroy a prepared Start batch after Process_Start failed.
	Unwire               = 8, // End one wiring owned by an asker with a chosen End_Word.
	Revoke_Asker         = 9, // End every wiring asked by an asker with End_Word.Revoked.
	Query                = 10, // Read active counts for the machine, an asker, or a process.
}

// Query kind for Command_Kind.Query.
Query_Kind :: enum u32 {
	None           = 0, // Refused.
	Machine_Totals = 1, // values[0]: active wirings, values[1]: registered processes, values[2]: list page holders.
	Asker_Count    = 2, // values[0]: active wirings asked by (target_slot, target_serial).
	Process_Ends   = 3, // values[0]: ends_given, values[1]: log_ends_given for (target_slot, target_serial).
}

// Response status in completion record kind on SERVICE_RING.
Response_Status :: enum u32 {
	Ok          = 0, // Command succeeded.
	Bad_Command = 1, // Invalid command word, value, or malformed region payload.
	Bad_Handle  = 2, // Missing or unproved handle, or unknown process identity.
	No_Right    = 3, // Caller/asker lacks permission for the requested end or action.
	Bad_State   = 4, // Invalid state (self-wire, input already taken, no list page, unknown batch).
	No_Slot     = 5, // Capacity limit reached (asker, machine, process ends, list askers, full ring).
	No_Budget   = 6, // Child wiring budget exhausted or absent.
	No_Memory           = 7, // Kernel refused memory allocation.
	Refused             = 8, // Delivery or other operation failed.
	Asker_Wirings_Empty = 9, // Unsolicited tag-0 notice: an asker's active wirings dropped to 0.
}

// response_status_to_op_status maps a service Response_Status to the
// corresponding kernel/root-ring op.Status.
response_status_to_op_status :: proc "contextless" (status: Response_Status) -> op.Status {
	switch status {
	case .Ok:
		return .Ok
	case .Bad_Command:
		return .Bad_Operation
	case .Bad_Handle:
		return .Bad_Handle
	case .No_Right:
		return .No_Right
	case .Bad_State:
		return .Bad_State
	case .No_Slot:
		return .No_Slot
	case .No_Budget:
		return .No_Budget
	case .No_Memory:
		return .No_Memory
	case .Refused, .Asker_Wirings_Empty:
		return .Bad_State
	}
	return .Bad_State
}

// response_status_from_op_status maps a kernel op.Status into Response_Status.
response_status_from_op_status :: proc "contextless" (status: op.Status) -> Response_Status {
	switch status {
	case .Ok:
		return .Ok
	case .Bad_Operation:
		return .Bad_Command
	case .Bad_Handle:
		return .Bad_Handle
	case .No_Right:
		return .No_Right
	case .Bad_State:
		return .Bad_State
	case .No_Slot:
		return .No_Slot
	case .No_Budget:
		return .No_Budget
	case .No_Memory:
		return .No_Memory
	case .Bad_Address:
		return .Refused
	}
	return .Refused
}

// Decoded command record from SERVICE_RING.
Command :: struct {
	kind:               Command_Kind,
	tag:                u32,
	process:            Process_Identity, // Target process or asker identity.
	flags:              Process_Flags,
	module_offset:      u64, // Offset of module bytes in SERVICE_IMAGE.
	module_size:        u64, // Byte size of module bytes in SERVICE_IMAGE.
	process_handle:     op.Handle, // Register_Process: Give-only process handle.
	wiring_ring_handle: op.Handle, // Register_Process: wiring ring memory handle (0 if none).
	budget_handle:      op.Handle, // Grant_Asker_Budget: Spend-only child wiring budget handle.
	batch_id:           u32, // Commit_Start_Wiring / Abort_Start_Wiring.
	wiring_number:      u32, // Unwire: target wiring number.
	end_word:           output.End_Word, // Unwire: end word to write (non-None).
	query_kind:         Query_Kind, // Query: which counters to return.
}

// command_to_record encodes a typed Command into a 64-byte ring.Record.
command_to_record :: proc "contextless" (cmd: Command) -> ring.Record {
	record := ring.Record{kind = u32(cmd.kind), tag = cmd.tag}
	switch cmd.kind {
	case .None:
	case .Register_Process:
		record.values[0] = cmd.process.slot
		record.values[1] = cmd.process.serial
		record.values[2] = cmd.module_offset
		record.values[3] = cmd.module_size
		record.values[4] = u64(cmd.process_handle)
		record.values[5] = u64(cmd.wiring_ring_handle)
		record.values[6] = u64(transmute(u32)cmd.flags)
	case .Grant_Asker_Budget:
		record.values[0] = cmd.process.slot
		record.values[1] = cmd.process.serial
		record.values[2] = u64(cmd.budget_handle)
	case .List_Page:
		record.values[0] = cmd.process.slot
		record.values[1] = cmd.process.serial
	case .Wire:
		record.values[0] = cmd.process.slot
		record.values[1] = cmd.process.serial
		record.values[2] = u64(transmute(u32)cmd.flags)
	case .Prepare_Start_Wiring:
		record.values[0] = cmd.process.slot
		record.values[1] = cmd.process.serial
		record.values[2] = u64(transmute(u32)cmd.flags)
		record.values[3] = cmd.module_offset
		record.values[4] = cmd.module_size
	case .Commit_Start_Wiring:
		record.values[0] = u64(cmd.batch_id)
		record.values[1] = cmd.process.slot
		record.values[2] = cmd.process.serial
	case .Abort_Start_Wiring:
		record.values[0] = u64(cmd.batch_id)
	case .Unwire:
		record.values[0] = cmd.process.slot
		record.values[1] = cmd.process.serial
		record.values[2] = u64(cmd.wiring_number)
		record.values[3] = u64(cmd.end_word)
	case .Revoke_Asker:
		record.values[0] = cmd.process.slot
		record.values[1] = cmd.process.serial
	case .Query:
		record.values[0] = u64(cmd.query_kind)
		record.values[1] = cmd.process.slot
		record.values[2] = cmd.process.serial
	}
	return record
}

@(private = "file")
trailing_zeros :: proc "contextless" (values: [7]u64, from: int) -> bool {
	for index in from ..< len(values) {
		if values[index] != 0 {
			return false
		}
	}
	return true
}

// command_from_record is the one strict border for commands arriving on
// SERVICE_RING. It refuses Command_Kind.None, any unknown command word,
// out-of-range process slots, zero serials, unknown flags, handles past
// u32, invalid query/end words, and non-zero reserved words.
command_from_record :: proc "contextless" (record: ring.Record) -> (cmd: Command, ok: bool) {
	kind, kind_known := enum_word.member_of_word(Command_Kind, u64(record.kind))
	if !kind_known || kind == .None {
		return {}, false
	}
	v := record.values
	cmd.kind = kind
	cmd.tag = record.tag
	switch kind {
	case .None:
		return {}, false
	case .Register_Process:
		id := Process_Identity{slot = v[0], serial = v[1]}
		if !process_identity_valid(id) {
			return {}, false
		}
		if (v[2] == 0) != (v[3] == 0) {
			return {}, false
		}
		if v[4] == 0 || v[4] > u64(max(u32)) {
			return {}, false
		}
		if v[5] > u64(max(u32)) {
			return {}, false
		}
		flags, flags_ok := process_flags_from_word(v[6])
		if !flags_ok {
			return {}, false
		}
		if (.Has_Wiring_Ring in flags) != (v[5] != 0) {
			return {}, false
		}
		cmd.process = id
		cmd.module_offset = v[2]
		cmd.module_size = v[3]
		cmd.process_handle = op.Handle(v[4])
		cmd.wiring_ring_handle = op.Handle(v[5])
		cmd.flags = flags
	case .Grant_Asker_Budget:
		id := Process_Identity{slot = v[0], serial = v[1]}
		if !process_identity_valid(id) || v[2] == 0 || v[2] > u64(max(u32)) || !trailing_zeros(v, 3) {
			return {}, false
		}
		cmd.process = id
		cmd.budget_handle = op.Handle(v[2])
	case .List_Page:
		id := Process_Identity{slot = v[0], serial = v[1]}
		if !process_identity_valid(id) || !trailing_zeros(v, 2) {
			return {}, false
		}
		cmd.process = id
	case .Wire:
		id := Process_Identity{slot = v[0], serial = v[1]}
		flags, flags_ok := process_flags_from_word(v[2])
		if !process_identity_valid(id) || !flags_ok || !trailing_zeros(v, 3) {
			return {}, false
		}
		cmd.process = id
		cmd.flags = flags
	case .Prepare_Start_Wiring:
		id := Process_Identity{slot = v[0], serial = v[1]}
		flags, flags_ok := process_flags_from_word(v[2])
		if !process_identity_valid(id) || !flags_ok || v[3] == 0 || v[4] == 0 || !trailing_zeros(v, 5) {
			return {}, false
		}
		cmd.process = id
		cmd.flags = flags
		cmd.module_offset = v[3]
		cmd.module_size = v[4]
	case .Commit_Start_Wiring:
		id := Process_Identity{slot = v[1], serial = v[2]}
		if v[0] == 0 || v[0] > u64(max(u32)) || !process_identity_valid(id) || !trailing_zeros(v, 3) {
			return {}, false
		}
		cmd.batch_id = u32(v[0])
		cmd.process = id
	case .Abort_Start_Wiring:
		if v[0] == 0 || v[0] > u64(max(u32)) || !trailing_zeros(v, 1) {
			return {}, false
		}
		cmd.batch_id = u32(v[0])
	case .Unwire:
		id := Process_Identity{slot = v[0], serial = v[1]}
		end_word, end_ok := enum_word.member_of_word(output.End_Word, v[3])
		if !process_identity_valid(id) || v[2] == 0 || v[2] > u64(max(u32)) || !end_ok || end_word == .None || !trailing_zeros(v, 4) {
			return {}, false
		}
		cmd.process = id
		cmd.wiring_number = u32(v[2])
		cmd.end_word = end_word
	case .Revoke_Asker:
		id := Process_Identity{slot = v[0], serial = v[1]}
		if !process_identity_valid(id) || !trailing_zeros(v, 2) {
			return {}, false
		}
		cmd.process = id
	case .Query:
		qkind, qok := enum_word.member_of_word(Query_Kind, v[0])
		if !qok || qkind == .None || !trailing_zeros(v, 3) {
			return {}, false
		}
		cmd.query_kind = qkind
		switch qkind {
		case .None:
			return {}, false
		case .Machine_Totals:
			if v[1] != 0 || v[2] != 0 {
				return {}, false
			}
		case .Asker_Count, .Process_Ends:
			id := Process_Identity{slot = v[1], serial = v[2]}
			if !process_identity_valid(id) {
				return {}, false
			}
			cmd.process = id
		}
	}
	return cmd, true
}

// Decoded response record from SERVICE_RING.
Response :: struct {
	status:        Response_Status,
	tag:           u32,
	error_record:  errors.Error_Record, // Valid when status != .Ok.
	// Valid when status == .Ok, depending on the answered command:
	list_page:     op.Handle, // List_Page: handle of list page given through SERVICE_RING.
	wiring_ring:   op.Handle, // List_Page: handle of new wiring ring (0 if asker already had one).
	wiring_number: u32, // Wire: wiring number allocated.
	batch_id:      u32, // Prepare_Start_Wiring: prepared batch identifier.
	ended_count:   u64, // Revoke_Asker / Unwire: count of wirings ended.
	asker_active:  u64, // Wire / Commit_Start_Wiring: active wirings held by asker after command.
	query_values:  [3]u64, // Query: returned counters.
}

// response_to_record encodes a typed Response into a 64-byte ring.Record.
response_to_record :: proc "contextless" (resp: Response, command: Command_Kind) -> ring.Record {
	if resp.status != .Ok {
		return ring.Record{
			kind   = u32(resp.status),
			tag    = resp.tag,
			values = errors.completion_values(resp.error_record),
		}
	}
	record := ring.Record{kind = u32(Response_Status.Ok), tag = resp.tag}
	switch command {
	case .None, .Register_Process, .Grant_Asker_Budget, .Abort_Start_Wiring:
	case .List_Page:
		record.values[0] = u64(resp.list_page)
		record.values[1] = u64(resp.wiring_ring)
	case .Wire:
		record.values[0] = u64(resp.wiring_number)
		record.values[1] = resp.asker_active
	case .Prepare_Start_Wiring:
		record.values[0] = u64(resp.batch_id)
	case .Commit_Start_Wiring:
		record.values[0] = resp.asker_active
	case .Unwire, .Revoke_Asker:
		record.values[0] = resp.ended_count
	case .Query:
		record.values[0] = resp.query_values[0]
		record.values[1] = resp.query_values[1]
		record.values[2] = resp.query_values[2]
	}
	return record
}

// response_from_record is the one strict border for responses arriving on
// SERVICE_RING. It refuses unknown status words, Command_Kind.None, handles
// past u32, zero identifiers where non-zero is required, and non-zero unused
// fields.
response_from_record :: proc "contextless" (record: ring.Record, command: Command_Kind) -> (resp: Response, ok: bool) {
	if command == .None {
		return {}, false
	}
	status, status_known := enum_word.member_of_word(Response_Status, u64(record.kind))
	if !status_known {
		return {}, false
	}
	if status == .Asker_Wirings_Empty {
		return {}, false
	}
	resp.status = status
	resp.tag = record.tag
	if status != .Ok {
		resp.error_record = errors.completion_record(record.values)
		return resp, true
	}
	v := record.values
	switch command {
	case .None:
		return {}, false
	case .Register_Process, .Grant_Asker_Budget, .Abort_Start_Wiring:
		if !trailing_zeros(v, 0) {
			return {}, false
		}
	case .List_Page:
		if v[0] == 0 || v[0] > u64(max(u32)) || v[1] > u64(max(u32)) || !trailing_zeros(v, 2) {
			return {}, false
		}
		resp.list_page = op.Handle(v[0])
		resp.wiring_ring = op.Handle(v[1])
	case .Wire:
		if v[0] == 0 || v[0] > u64(max(u32)) || !trailing_zeros(v, 2) {
			return {}, false
		}
		resp.wiring_number = u32(v[0])
		resp.asker_active = v[1]
	case .Prepare_Start_Wiring:
		if v[0] == 0 || v[0] > u64(max(u32)) || !trailing_zeros(v, 1) {
			return {}, false
		}
		resp.batch_id = u32(v[0])
	case .Commit_Start_Wiring:
		if !trailing_zeros(v, 1) {
			return {}, false
		}
		resp.asker_active = v[0]
	case .Unwire, .Revoke_Asker:
		if !trailing_zeros(v, 1) {
			return {}, false
		}
		resp.ended_count = v[0]
	case .Query:
		if !trailing_zeros(v, 3) {
			return {}, false
		}
		resp.query_values = {v[0], v[1], v[2]}
	}
	return resp, true
}

// asker_wirings_empty_to_record encodes an unsolicited tag-0 completion on
// SERVICE_RING telling the root core that asker `id` now holds zero active
// wirings and should have the recorded grant `.Wirings` cleared.
asker_wirings_empty_to_record :: proc "contextless" (id: Process_Identity) -> ring.Record {
	return {
		kind   = u32(Response_Status.Asker_Wirings_Empty),
		tag    = 0,
		values = {id.slot, id.serial, 0, 0, 0, 0, 0},
	}
}

// asker_wirings_empty_from_record is the strict border for tag-0
// Asker_Wirings_Empty notices on SERVICE_RING.
asker_wirings_empty_from_record :: proc "contextless" (record: ring.Record) -> (id: Process_Identity, ok: bool) {
	if record.tag != 0 || record.kind != u32(Response_Status.Asker_Wirings_Empty) {
		return {}, false
	}
	if !trailing_zeros(record.values, 2) {
		return {}, false
	}
	id = {slot = record.values[0], serial = record.values[1]}
	if !process_identity_valid(id) {
		return {}, false
	}
	return id, true
}

// Kind of a notice emitted on the core's `stops` record output.
Stop_Notice_Kind :: enum u32 {
	None              = 0, // Refused.
	Process_Stopped   = 1, // Kernel recorded the process stop with a valid cause and outcome.
	Process_Abandoned = 2, // Core released the process with no recorded kernel stop; outputs end as Revoked.
}

// Process_Stop_Notice is the record emitted by the root core's `stops`
// record output at reap/release so delegated services reclaim state without
// polling or broadcast. Zero unnamed padding bytes so it also serves as a
// described record stream type.
Process_Stop_Notice :: struct {
	process_slot:   u64,
	process_serial: u64,
	kind:           Stop_Notice_Kind,
	cause:          op.Stop_Cause,
	outcome:        op.Stop_Outcome,
	reserved:       u32,
}
#assert(size_of(Process_Stop_Notice) == 32)

// stop_notice_to_record encodes a Process_Stop_Notice into a 64-byte ring.Record.
stop_notice_to_record :: proc "contextless" (notice: Process_Stop_Notice) -> ring.Record {
	return ring.Record {
		kind = u32(notice.kind),
		tag = 0,
		values = {
			0 = notice.process_slot,
			1 = notice.process_serial,
			2 = u64(notice.cause),
			3 = u64(notice.outcome),
		},
	}
}

// stop_notice_from_record is the one strict border for records arriving on
// SERVICE_STOPS_RING. It refuses Stop_Notice_Kind.None, unknown kinds,
// invalid process slots or zero serials, non-zero tags or trailing values,
// invalid (cause, outcome) pairs for Process_Stopped (via op.stop_of_words),
// and any non-zero cause/outcome on Process_Abandoned.
stop_notice_from_record :: proc "contextless" (record: ring.Record) -> (notice: Process_Stop_Notice, ok: bool) {
	if record.tag != 0 || !trailing_zeros(record.values, 4) {
		return {}, false
	}
	kind, kind_known := enum_word.member_of_word(Stop_Notice_Kind, u64(record.kind))
	if !kind_known || kind == .None {
		return {}, false
	}
	id := Process_Identity{slot = record.values[0], serial = record.values[1]}
	if !process_identity_valid(id) {
		return {}, false
	}
	switch kind {
	case .None:
		return {}, false
	case .Process_Stopped:
		_, cause, outcome, stop_ok := op.stop_of_words(u64(op.Process_State.Stopped), record.values[2], record.values[3])
		if !stop_ok {
			return {}, false
		}
		return {
			process_slot   = id.slot,
			process_serial = id.serial,
			kind           = .Process_Stopped,
			cause          = cause,
			outcome        = outcome,
		}, true
	case .Process_Abandoned:
		if record.values[2] != 0 || record.values[3] != 0 {
			return {}, false
		}
		return {
			process_slot   = id.slot,
			process_serial = id.serial,
			kind           = .Process_Abandoned,
			cause          = .None,
			outcome        = .None,
		}, true
	}
	return {}, false
}

// Resolved lent handle entry written by the core in SERVICE_REGION.
// The core proved each lent handle came through the asker's root ring,
// recorded its process identity and ownership facts, and closed the lent
// handle before sending the command to `wiring`.
Resolved_Lent_End :: struct {
	process_slot:            u64,
	process_serial:          u64,
	started_by_asker:        u8,
	started_by_start_policy: u8,
	present:                 u8,
	reserved:                [5]u8,
}
#assert(size_of(Resolved_Lent_End) == 24)

// Resolved connected-service entry written by the core in SERVICE_REGION.
// Because a connected service's process handle carries no Give, the core
// resolves the caller's connection number against its connection table.
Resolved_Connected_End :: struct {
	process_slot:             u64,
	process_serial:           u64,
	handle_number:            u32,
	asker_acts_for_principal: u8,
	process_is_a_service:     u8,
	asker_holds_a_connection: u8,
	present:                  u8,
}
#assert(size_of(Resolved_Connected_End) == 24)

// Structured request staged by the core at REGION_REQUEST_OFFSET for Wire
// and Prepare_Start_Wiring.
Resolved_Wiring_Request :: struct {
	form:                  u32, // output.Wiring_List_Form.
	list_bytes:            u32, // Valid byte count at REGION_LIST_OFFSET.
	asker_is_start_policy: u8,
	reserved_0:            [3]u8,
	lent_count:            u32,
	connected_count:       u32,
	reserved_1:            u32,
	child_module_offset:   u64, // Prepare_Start_Wiring: offset in SERVICE_IMAGE.
	child_module_size:     u64, // Prepare_Start_Wiring: size in SERVICE_IMAGE.
	lent:                  [output.WIRING_LIST_HANDLE_LIMIT]Resolved_Lent_End,
	connected:             [RESOLVED_CONNECTED_LIMIT]Resolved_Connected_End,
}
#assert(size_of(Resolved_Wiring_Request) <= REGION_REQUEST_SIZE)

// resolved_request_check validates a copied Resolved_Wiring_Request at
// `wiring`'s border. Refuses invalid form words, out-of-range counts,
// non-boolean flag bytes, non-zero reserved bytes, or invalid identities on
// present entries.
resolved_request_check :: proc "contextless" (req: ^Resolved_Wiring_Request) -> (form: output.Wiring_List_Form, ok: bool) {
	form_val, form_ok := enum_word.member_of_word(output.Wiring_List_Form, u64(req.form))
	if !form_ok {
		return {}, false
	}
	if req.list_bytes < size_of(output.Wiring_List_Head) || req.list_bytes > REGION_LIST_SIZE {
		return {}, false
	}
	if req.asker_is_start_policy > 1 || req.reserved_0 != ([3]u8{}) || req.reserved_1 != 0 {
		return {}, false
	}
	if req.lent_count > output.WIRING_LIST_HANDLE_LIMIT || req.connected_count > RESOLVED_CONNECTED_LIMIT {
		return {}, false
	}
	switch form_val {
	case .Wire:
		if req.child_module_offset != 0 || req.child_module_size != 0 {
			return {}, false
		}
	case .Start:
		if req.child_module_offset == 0 || req.child_module_size == 0 {
			return {}, false
		}
	}
	for index in 0 ..< req.lent_count {
		entry := &req.lent[index]
		if entry.present > 1 || entry.started_by_asker > 1 || entry.started_by_start_policy > 1 || entry.reserved != ([5]u8{}) {
			return {}, false
		}
		if entry.present == 1 && !process_identity_valid({entry.process_slot, entry.process_serial}) {
			return {}, false
		}
	}
	for index in 0 ..< req.connected_count {
		entry := &req.connected[index]
		if entry.handle_number == 0 || entry.present > 1 || entry.asker_acts_for_principal > 1 || entry.process_is_a_service > 1 || entry.asker_holds_a_connection > 1 {
			return {}, false
		}
		if entry.present == 1 && !process_identity_valid({entry.process_slot, entry.process_serial}) {
			return {}, false
		}
	}
	return form_val, true
}

// Flat wire representation of one child end returned by `wiring` in
// Prepared_Start_Ends at REGION_RESPONSE_OFFSET. All handles were given by
// `wiring` to the core through SERVICE_RING.
Prepared_Start_End :: struct {
	command:     u32, // output.Wiring_Command (Writer_End or Reader_End).
	tag:         u32, // Wiring number.
	ring:        u32, // Handle of output ring.
	index:       u32, // Record output or input index (1 ..= module.RECORD_STREAM_INDEX_MOST).
	pace:        u32, // output.Wiring_Pace.
	terms:       u32, // Reader_End: terms handle or 0.
	description: u32, // Reader_End: description file handle.
	end_words:   u32, // End page handle.
	condition:   u32, // Writer_End: condition page handle or 0.
	filter:      u32, // output.Reader_Filter.
}
#assert(size_of(Prepared_Start_End) == 40)

// Response payload written by `wiring` at REGION_RESPONSE_OFFSET for
// Prepare_Start_Wiring and Commit_Start_Wiring.
Prepared_Start_Ends :: struct {
	batch_id:           u32,
	child_end_count:    u32,
	asker_wiring_count: u32,
	log_ring:           u32, // Log output ring handle (0 if log not wired).
	log_end_words:      u32, // Log end page handle (0 if log not wired).
	reserved:           u32,
	asker_numbers:      [output.WIRING_ASKER_ROWS_OF_A_START]u32,
	child_ends:         [output.WIRING_LIST_ROW_LIMIT]Prepared_Start_End,
}
#assert(size_of(Prepared_Start_Ends) <= REGION_RESPONSE_SIZE)

// given_end_to_prepared converts a typed output.Given_End into its wire form.
given_end_to_prepared :: proc "contextless" (end: output.Given_End) -> Prepared_Start_End {
	return {
		command     = u32(end.command),
		tag         = end.tag,
		ring        = u32(end.ring),
		index       = end.index,
		pace        = u32(end.pace),
		terms       = u32(end.terms),
		description = u32(end.description),
		end_words   = u32(end.end_words),
		condition   = u32(end.condition),
		filter      = u32(end.filter),
	}
}

// prepared_end_to_given is the core's border for each child end returned by
// `wiring`: refuses invalid commands (including None and Asker_End), invalid
// pace or filter words, zero handles where required, and out-of-range stream
// indices.
prepared_end_to_given :: proc "contextless" (wire: Prepared_Start_End) -> (end: output.Given_End, ok: bool) {
	cmd, cmd_ok := enum_word.member_of_word(output.Wiring_Command, u64(wire.command))
	if !cmd_ok || (cmd != .Writer_End && cmd != .Reader_End) {
		return {}, false
	}
	if wire.tag == 0 || wire.ring == 0 || wire.end_words == 0 {
		return {}, false
	}
	if wire.index == 0 || wire.index > module.RECORD_STREAM_INDEX_MOST {
		return {}, false
	}
	pace, pace_ok := enum_word.member_of_word(output.Wiring_Pace, u64(wire.pace))
	if !pace_ok {
		return {}, false
	}
	filter, filter_ok := enum_word.member_of_word(output.Reader_Filter, u64(wire.filter))
	if !filter_ok {
		return {}, false
	}
	switch cmd {
	case .Writer_End:
		if wire.terms != 0 || wire.description != 0 || filter != .None {
			return {}, false
		}
	case .Reader_End:
		if pace != .Writer_Chooses || wire.description == 0 || wire.condition != 0 {
			return {}, false
		}
	case .None, .Asker_End:
		return {}, false
	}
	return {
		command     = cmd,
		tag         = wire.tag,
		ring        = op.Handle(wire.ring),
		index       = wire.index,
		pace        = pace,
		terms       = op.Handle(wire.terms),
		description = op.Handle(wire.description),
		end_words   = op.Handle(wire.end_words),
		condition   = op.Handle(wire.condition),
		filter      = filter,
	}, true
}

// prepared_start_ends_check validates the whole Prepared_Start_Ends payload
// copied by the core from REGION_RESPONSE_OFFSET.
prepared_start_ends_check :: proc "contextless" (payload: ^Prepared_Start_Ends, expected_batch: u32, out_ends: []output.Given_End) -> (count: int, ok: bool) {
	if payload.batch_id == 0 || payload.batch_id != expected_batch || payload.reserved != 0 {
		return 0, false
	}
	if payload.child_end_count > output.WIRING_LIST_ROW_LIMIT || int(payload.child_end_count) > len(out_ends) {
		return 0, false
	}
	if payload.asker_wiring_count > output.WIRING_ASKER_ROWS_OF_A_START {
		return 0, false
	}
	if (payload.log_ring == 0) != (payload.log_end_words == 0) {
		return 0, false
	}
	for index in 0 ..< payload.child_end_count {
		given, end_ok := prepared_end_to_given(payload.child_ends[index])
		if !end_ok {
			return 0, false
		}
		out_ends[index] = given
	}
	return int(payload.child_end_count), true
}
