// The delegated service disk_processes: the holder of the role
// Disk_Processes (src/md/api/root_service_split.md, "The disk processes").
//
// It reads the module file of a disk process, and the files of its import
// scan, from the store module_files of the principal of each load,
// through a connection that reads only, which the core gives with the
// command Load. The bytes go into memory that the core lends; the core
// checks each hash on its own mapping after the end of each loan, then
// starts the module from the request Start_From_Bytes. The core never
// reads a module file from the disk, and never waits for the storage
// service during a load.
//
// The rules of the load are in the machine of
// internal:disk_processes/disk_processes_core; this file carries its
// actions to the storage service and to the core.
package disk_processes_service

import "base:intrinsics"
import dpc "internal:disk_processes/disk_processes_core"
import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import op "modus:contract/operation"
import module "modus:contract/module"
import "modus:contract/ring"
import rd "modus:contract/root_delegation"
import "modus:contract/storage_status"
import "modus:contract/value_kinds"
import "modus:storage"
import "modus:system"

// The page tables of its mappings: the boot image, one lent file of up to
// 64 MiB (a module file, or the script font set: 32 page tables and their
// directory), and the call ring and the call region of the storage
// connection.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 128, processes = 1, threads = 1}

// Status record returned by the status() export.
Disk_Processes_Status :: struct {
	loads:            i64,
	starts_requested: i64,
	refusals:         i64,
	commands_refused: i64,
}

machine: dpc.Machine
core_ring: ring.Ring
core_ring_memory: system.Handle
region: []u8
image: []u8

// The load that runs: the tag of the core, the storage connection, the
// call in flight, and the lent memory of the file that is read.
load_tag: u32
client: storage.Client
client_open: bool
sent: storage.Sent_Call
arguments: [4]isolated.Argument
argument_count: int
call_waiting: bool
lent_memory: system.Handle
lent_address: rawptr

// The private copies of what crosses a border: the request of the core,
// and the rows of a list that the storage service writes.
copied_request: rd.Load_Request
list_rows: [dpc.LIST_PAGE_ROWS]storage.Listed
list_names: [dpc.LIST_NAME_BYTES]u8
machine_rows: [dpc.LIST_PAGE_ROWS]dpc.List_Row

@(private = "file")
fail :: proc "contextless" (text: string) -> ! {
	system.log_fact(.Error, Service_Failed{failure = value_kinds.text_field(text, FAILURE_FIELD_BYTES)})
	system.stop(.Failed)
}

// status writes the counts of the loads into result.
@(export)
status :: proc "c" (result: ^Disk_Processes_Status, error: ^errors.Error_Record) -> call_outcome.Call_Outcome {
	if result == nil {
		outcome, _ := call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 1)
		return outcome
	}
	result^ = {
		loads            = i64(machine.counters.loads),
		starts_requested = i64(machine.counters.starts_requested),
		refusals         = i64(machine.counters.refusals),
		commands_refused = i64(machine.counters.commands_refused),
	}
	return .Succeeded
}

@(private = "file")
image_holds :: proc "contextless" (hash: blake3.Hash) -> bool {
	return system.image_entry_of(image, hash) != nil
}

@(private = "file")
imports_walk :: proc "contextless" (file: []u8, walked: ^dpc.Machine) {
	if module.validate(file) != .None {
		return
	}
	for number in 1 ..< module.count(file, .Imports) {
		record, _ := module.record(file, .Imports, number, module.Import)
		dpc.want_import(walked, record.hash)
	}
}

// lent_release gives back the lent memory: the core revokes the loan when
// it takes the next event.
@(private = "file")
lent_release :: proc "contextless" () {
	if lent_address != nil {
		system.memory_unmap(lent_address)
		lent_address = nil
	}
	if lent_memory != 0 {
		system.close(lent_memory)
		lent_memory = 0
	}
}

// load_release gives back what the load holds: the lent memory and the
// storage connection.
@(private = "file")
load_release :: proc "contextless" () {
	lent_release()
	if client_open {
		if client.calls.head != nil {
			system.ring_close(&client.calls)
		}
		if client.region != nil {
			system.memory_unmap(raw_data(client.region))
		}
		for handle in ([3]system.Handle{client.ring_memory, client.region_memory, client.service}) {
			if handle != 0 {
				system.close(handle)
			}
		}
	}
	client = {}
	client_open = false
	call_waiting = false
}

@(private = "file")
event_send :: proc "contextless" (event: rd.Disk_Load_Event, tag: u32) {
	report := machine.report
	intrinsics.mem_copy_non_overlapping(&region[rd.EVENT_REPORT_OFFSET], &report, size_of(rd.Event_Report))
	if !system.send(&core_ring.completions, ring.Record{kind = u32(event), tag = tag}) {
		// The core reads one event for each command: a full ring is a
		// fault of the core, and the load ends with no event.
		dpc.cancel(&machine)
		load_release()
	}
}

// perform carries the actions of the machine until it waits: for an
// answer of the storage service, or for a command of the core.
@(private = "file")
perform :: proc "contextless" (first: dpc.Action) {
	action := first
	for {
		switch action.kind {
		case .Wait_Command:
			return
		case .Ask_Size, .Ask_Read, .Ask_List:
			arguments = {}
			arguments[0].integer = u64(storage.ROOT)
			arguments[1].text = transmute([]u8)action.name
			argument_count = 2
			export := "size"
			switch action.kind {
			case .Wait_Command, .Send_Event, .Ask_Size:
			case .Ask_Read:
				export = "read_range"
				arguments[2].integer = action.offset
				argument_count = 3
			case .Ask_List:
				export = "list"
				// The name after which the page starts, in the memory of the
				// machine: an empty name of the first page is still a range.
				arguments[1].text = machine.after[:machine.after_length]
				arguments[2].table = {records = ([^]u8)(&list_rows)[:size_of(list_rows)], count = 0}
				arguments[3].table = {records = list_names[:], count = 0}
				argument_count = 4
			}
			call_status: storage_status.Status
			sent, call_status = storage.call_send(&client, export, arguments[:argument_count])
			if call_status != .Ok {
				action = dpc.call_failed(&machine, .Call_Not_Taken)
				continue
			}
			call_waiting = true
			return
		case .Send_Event:
			if action.release_lent {
				lent_release()
			}
			event_send(action.event, load_tag)
			switch action.event {
			case .Ready, .Refused, .Command_Refused:
				load_release()
			case .None, .Memory_Wanted, .Module_Filled, .Scan_Started, .Import_Found, .Candidate_Dropped, .Cancelled:
			// The load goes on: the core answers this event with a command.
			}
			return
		}
	}
}

// answer_poll reads the answer of the storage service to the call in
// flight, if it came, and gives it to the machine.
@(private = "file")
answer_poll :: proc "contextless" () {
	if !call_waiting {
		return
	}
	error: errors.Error_Record
	value, text, status, outcome, answered := storage.call_answer(&client, &sent, arguments[:argument_count], &error)
	answer: dpc.Storage_Answer
	switch {
	case !answered && storage.connected(&client):
		return
	case !answered:
		answer.kind = .Gone
	case status == .Failed && outcome == .Nothing_Has_That_Name:
		answer.kind = .Absent
	case status == .Failed:
		answer = {kind = .Failed, value = value, error = error, damaged = outcome == .Data_Damaged}
	case status != .Ok || value < 0:
		answer.kind = .Not_Allowed
	case:
		answer = {kind = .Value, value = value, text = text}
		if machine.stage == .List {
			count := int(min(value, dpc.LIST_PAGE_ROWS))
			for &item, index in list_rows[:count] {
				class := dpc.Entry_Class.Unknown
				if kind, known := storage.entry_kind_of_word(item.kind); known {
					class = kind == .Object ? .Object : .Other
				}
				machine_rows[index] = {name_offset = item.name_offset, name_count = item.name_count, class = class, size = item.size}
			}
			answer.rows = machine_rows[:count]
			answer.names = list_names[:]
		}
	}
	call_waiting = false
	perform(dpc.storage_answered(&machine, &answer))
}

// handle_proof says if a handle came from the core through the ring, as a
// memory or a process with at least the rights asked.
@(private = "file")
handle_proof :: proc "contextless" (handle: u64, kind: op.Object_Kind, needed: system.Rights) -> bool {
	found_kind, rights, through := system.handle_state(system.Handle(handle), core_ring_memory)
	return through && found_kind == kind && needed <= rights
}

@(private = "file")
handle_command :: proc "contextless" (command: ring.Record) {
	parsed, known := rd.disk_load_command_of_word(command.kind)
	if !known || parsed != .Load && command.tag != load_tag {
		system.log_fact(.Warning, Command_Refused{command_kind = u64(command.kind)})
		machine.report = {}
		event_send(.Command_Refused, command.tag)
		return
	}
	switch parsed {
	case .None:
	case .Load:
		load_release()
		dpc.cancel(&machine)
		load_tag = command.tag
		intrinsics.mem_copy_non_overlapping(&copied_request, &region[rd.LOAD_REQUEST_OFFSET], size_of(rd.Load_Request))
		action := dpc.load_begin(&machine, &copied_request)
		valid := handle_proof(command.values[0], .Process, {.Read}) && handle_proof(command.values[1], .Memory, {.Read, .Write}) && handle_proof(command.values[2], .Memory, {.Read, .Write})
		if action.kind == .Ask_Size && valid {
			storage_module := string(copied_request.storage_module[:copied_request.storage_module_length])
			file := system.image_find(image, storage_module)
			if module.validate(file) == .None {
				client, client_open = storage.open_handles(system.Handle(command.values[1]), system.Handle(command.values[2]), system.Handle(command.values[0]), file)
			}
			if !client_open {
				action = dpc.call_failed(&machine, .Not_Mapped)
			}
		} else if action.kind == .Ask_Size {
			action = dpc.call_failed(&machine, .Not_Mapped)
		}
		if !client_open {
			// The handles that came through the ring and that no connection
			// holds are closed here: a refusal keeps none of them.
			for index in 0 ..< 3 {
				word := command.values[index]
				kind := index == 0 ? op.Object_Kind.Process : op.Object_Kind.Memory
				if handle_proof(word, kind, {}) {
					system.close(system.Handle(word))
				}
			}
		}
		perform(action)
	case .Memory_Lent:
		if !handle_proof(command.values[0], .Memory, {.Read, .Write}) {
			perform(dpc.command_refused(&machine))
			return
		}
		lent_release()
		lent_memory = system.Handle(command.values[0])
		pages, size_status := system.memory_size(lent_memory)
		address: rawptr
		map_status := size_status
		if size_status == .Ok {
			address, map_status = system.memory_map(lent_memory, {.Write})
		}
		if map_status != .Ok {
			perform(dpc.command_refused(&machine))
			return
		}
		lent_address = address
		perform(dpc.memory_lent(&machine, ([^]u8)(address)[:pages * system.PAGE_SIZE]))
	case .Continue:
		perform(dpc.continue_given(&machine))
	case .Cancel:
		// The lent memory and the storage connection are given back first:
		// the core ends their loans only after Cancelled, so no write of
		// this service meets a revoked page.
		dpc.cancel(&machine)
		load_release()
		machine.report = {}
		event_send(.Cancelled, command.tag)
	}
}

// entry opens the ring of the core, the transfer region and the boot
// image, then serves the loads.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	core_ring_memory = ctx.handles[rd.DISK_PROCESSES_RING_SLOT]
	open_status: system.Status
	if core_ring, open_status = system.ring_open(core_ring_memory, receive_handles = true); open_status != .Ok {
		fail("no ring of the core")
	}
	region_memory := ctx.handles[rd.DISK_PROCESSES_REGION_SLOT]
	pages, size_status := system.memory_size(region_memory)
	if size_status != .Ok || pages < rd.DISK_PROCESSES_REGION_PAGES {
		fail("the transfer region is smaller than its two pages")
	}
	region_address, region_status := system.memory_map(region_memory, {.Write})
	if region_status != .Ok {
		fail("the transfer region does not map")
	}
	region = ([^]u8)(region_address)[:rd.DISK_PROCESSES_REGION_PAGES * system.PAGE_SIZE]
	image_memory := ctx.handles[rd.DISK_PROCESSES_IMAGE_SLOT]
	image_size := ctx.values[rd.DISK_PROCESSES_VALUE_IMAGE_SIZE]
	image_kind, image_rights, _ := system.handle_state(image_memory)
	if image_kind != .Memory || .Write in image_rights || image_size == 0 {
		fail("no boot image that reads only")
	}
	image_address, image_status := system.memory_map(image_memory, {})
	if image_status != .Ok {
		fail("the boot image does not map")
	}
	image = ([^]u8)(image_address)[:image_size]

	dpc.machine_init(&machine, {image_holds = image_holds, imports_walk = imports_walk})
	system.log_fact(.Info, Service_Ready{})

	for {
		wait := system.wait_begin()
		answered := false
		for command in system.receive(&core_ring.commands) {
			handle_command(command)
			answered = true
		}
		answer_poll()
		if answered || ring.count(&core_ring.completions) > 0 {
			system.wake_reader(&core_ring.completions)
		}
		system.wait_records(&wait, &core_ring.commands)
		if call_waiting && client.calls.head != nil {
			system.wait_records(&wait, &client.calls.completions)
		}
		system.wait_end(&wait)
	}
}
