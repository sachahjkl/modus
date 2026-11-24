package root

// The start of a process of the boot image by its name: the start grant set that the
// tables of this service give the name, the services that the start grant set needs,
// and one context whose handles each take their own slot.

import "base:intrinsics"
import "internal:root/role_policy"
import info "modus:contract/boot_info"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/fixed_addresses"
import "modus:contract/isolated"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:contract/settings"
import "modus:disk_process"
import "modus:display"
import "modus:pci"
import "modus:principals"
import "modus:random"
import "modus:storage"
import "modus:system"
import terminal "modus:terminal"

// The mappings of a start: the storage file, the date page, the fresh
// bytes page, the settings page, the file of a service, the debug image,
// the disk process page and the font outlines: 8 places for the union, and
// the largest start grant set uses 7.
START_MAPPING_LIMIT :: 8

// How a start lets the process run (debug_start.odin).
Start_Hold :: enum u8 {
	None                 = 0, // The process runs at once.
	At_First_Instruction = 1, // The process is held before its first instruction, with its start grants.
	For_Replay           = 2, // The process is held, with no start grant and no window: a replay sends nothing to any process.
}

// The work of one start: what the steps of start() build, and the handles
// of this service that the start closes at its end, whatever its result.
// The process and the services hold their own copies of those handles.
Start_Work :: struct {
	name:           string,
	principal:      u64,
	asker:          ^Started,
	start_grant_set:           Start_Grant_Set,
	file:           []u8,
	entry:          ^info.Image_Entry,
	slot:           ^Started, // The place of the process in the table. nil until start_place_take.
	driver:         ^Started, // The device service that this start started for the process. nil: none.
	view:           ^Started, // The place of the terminal of a process with the grant Terminal. nil: none.
	// The handles and the values of the context. A write that one of them
	// refused stops the start before the process runs (start_process_load).
	grants:         system.Context_Grants,
	values:         system.Context_Values,
	mappings:       [START_MAPPING_LIMIT]system.Mapping,
	mapping_count:  int,
	mappings_full:  bool, // A mapping that the process cannot start without did not fit (mapping_needed_log).
	machine_rights: system.Rights,
	device_ring:    system.Handle,
	store_ring:     system.Handle,
	store_region:   system.Handle,
	endpoint_ring:  system.Handle,
	endpoint_region: system.Handle,
	clock_ports:    system.Handle,
	shared:         [2]system.Handle, // The ring to the compositor; or the terminal ring and the text region.
	// The wiring of the child before its first instruction, and what the
	// start gives back: its wiring ring and a handle of its budget.
	wiring:         system.Start_Wiring,
	// Pre-allocated child ends from the delegated wiring service, or nil.
	premade_wiring: ^Premade_Start_Wiring,
	// Optional override for edit(store, name): connects `edit` to the
	// named store of its principal and maps the read-only Edit_Target page.
	store_override:       string,
	store_limit_override: u64,
	edit_target_page:     system.Handle,
	// Where a refusal writes its error record: the completion of the
	// command that asked for the start, or a record of the start alone. A
	// start that this one starts first writes there too.
	refusal:        ^[7]u64,
	hold:           Start_Hold,
}

// start starts a process of the boot image that shows a surface or has a
// terminal, in the session of a principal (principals.odin). asker is the
// process that asked for the start with Start, or nil; premade_wiring
// holds child ends prepared by the delegated wiring service; place, when
// not nil, receives the place of the process; refusal, when not nil,
// receives the error record of a refusal, which the step that refuses
// writes with the outcome; hold keeps the process before its first
// instruction for a debugger.
start :: proc "contextless" (name: string, principal: u64 = principals.MACHINE, asker: ^Started = nil, premade_wiring: ^Premade_Start_Wiring = nil, place: ^^Started = nil, refusal: ^[7]u64 = nil, store_override: string = "", store_limit_override: u64 = 0, edit_target_page: system.Handle = 0, hold: Start_Hold = .None) -> call_outcome.Call_Outcome {
	own_refusal: [7]u64
	work := Start_Work {
		name                 = name,
		principal            = principal,
		asker                = asker,
		premade_wiring       = premade_wiring,
		store_override       = store_override,
		store_limit_override = store_limit_override,
		edit_target_page     = edit_target_page,
		refusal              = refusal != nil ? refusal : &own_refusal,
		hold                 = hold,
	}
	defer start_handles_close(&work)
	// The holder of Settings is the one writer of the settings page: each
	// start of it, by any caller, is decided here (text_settings.odin).
	if is_role_holder(name, .Settings) && settings_start_decide(principal, .Other) != .Start {
		return start_refuse(&work, .Wrong_State, .State, .Processes, 1)
	}
	// The handles of the start are free before any is made: the table of
	// prepared modules gives back its parts used least recently
	// (own_tables.odin).
	handles_room_make(start_handles_needed())
	if outcome := start_prepare(&work); outcome != .Succeeded {
		// A device service that start_prepare started before its refusal
		// stops: else its device stays held until the machine restarts.
		start_abandon(&work)
		return outcome
	}
	if outcome := start_place_take(&work); outcome != .Succeeded {
		start_abandon(&work)
		return outcome
	}
	work.slot.asker = asker
	outcome := start_context_build(&work)
	if outcome == .Succeeded && premade_wiring != nil {
		work.wiring.ends = premade_wiring.ends
		work.wiring.log_ring = premade_wiring.log_ring
		work.wiring.log_end_words = premade_wiring.log_end_words
	}
	if outcome == .Succeeded {
		outcome = start_process_load(&work)
	}
	if outcome != .Succeeded {
		start_abandon(&work)
		return outcome
	}
	start_wiring_keep(&work)
	if name == "collector" {
		wide_grant_collector_started(&work) // wide_grant_authority.odin
	}
	wide_grant_process_started(work.slot)
	if place != nil {
		place^ = work.slot
	}
	return start_finish(&work)
}

// start_wiring_keep keeps what the start of a process gave the core: its
// canonical (slot, serial), its module slice in the boot image, its budget
// handle if it can ask for wirings, and its wiring ring handle for the
// delegated wiring service.
start_wiring_keep :: proc "contextless" (work: ^Start_Work) {
	slot := work.slot
	slot.process_slot, slot.process_serial, _ = system.process_place(slot.process)
	session_table_record(slot.process_slot, slot.process_serial, work.principal)
	slot.module_offset = work.entry.offset
	slot.module_size = work.entry.size
	slot.budget = work.wiring.budget
	slot.wiring_memory = work.wiring.wiring_memory
	if wiring_process != nil {
		wiring_register_process(slot)
	}
}

// start_prepare finds the file of the process, refuses a name that start()
// does not start, reads the start grant set, and starts the services that the start grant set
// needs first: the network service, the storage service, and the device
// service of a client of a disk or of the network device.
start_prepare :: proc "contextless" (work: ^Start_Work) -> call_outcome.Call_Outcome {
	name := work.name
	for &item in system.image_entries(image) {
		if system.name_of(item.name[:]) == name && item.offset <= u64(len(image)) && item.size <= u64(len(image)) - item.offset {
			// The bytes have the hash of their entry before any read of
			// them (trust.odin, image_checks).
			if !image_entry_give(&item) {
				return start_refuse(work, .Data_Damaged, .Damaged, .Modules, 1)
			}
			work.file = image[item.offset:][:item.size]
			work.entry = &item
			break
		}
	}
	if len(work.file) == 0 {
		return start_refuse(work, .Nothing_Has_That_Name, .Absent, .Modules, 1)
	}
	// A part of the system starts by this service alone, as a service on
	// demand or at the boot.
	if name_is_a_system_part(name) && !(work.asker == nil && on_demand(name)) {
		return start_refuse(work, .Grant_Or_Right_Missing, .Reserved, .None, 1)
	}
	// One `unlock` at a time, and only from unlock_start: two runs would
	// share the ring of the principals and the ring and the region of the
	// TPM service, and one would read the answers of the other.
	if name == "unlock" && unlock_run.stage != .Starting {
		return start_refuse(work, .Grant_Or_Right_Missing, .Reserved, .None, 1)
	}
	if name == "unlock" && find("unlock") != nil {
		return start_refuse(work, .Callee_Busy, .Busy, .Processes, 1, 1, 1)
	}
	// The grants of a role follow its holder: a holder that the plan names
	// gets the row of the role (role_policy.grant_row_name_of_module).
	work.start_grant_set = start_grant_set_of(role_policy.grant_row_name_of_module(&role_holder_names, name))
	// A replay holds no connection, no ring to another process and no
	// right of the machine (src/md/features/record_and_replay.md, "The
	// replay"): its start grant set is empty.
	switch work.hold {
	case .For_Replay:
		work.start_grant_set = {}
	case .None, .At_First_Instruction:
	}
	grants := work.start_grant_set.grants
	// The start policy starts from start_policy_launch only: a second
	// holder of its root ring would start and stop the processes of the
	// machine.
	if .Start_Policy in grants && !start_policy_starting {
		return start_refuse(work, .Grant_Or_Right_Missing, .Reserved, .None, 1)
	}
	// A start grant set whose handles meet in one context slot does not start, before
	// any service starts for it: the table of the boot image is damaged.
	if slot, twice := system.start_grant_set_slot_taken_twice(grants); twice {
		grant_slot_refused(name, slot)
		return start_refuse(work, .Data_Damaged, .Damaged, .Records, 0, i64(slot))
	}
	// A process with an endpoint: the network service starts first. A
	// service that starts here and a refusal of this start after it change
	// no state of the sender (needed_service_failed).
	if .Network in grants {
		if _, outcome := network_service(work.refusal); outcome != .Succeeded {
			return needed_service_failed(work.refusal)
		}
	}
	// A process with a store (and no Root_Ring to connect itself): the
	// storage service starts first.
	if .Store in grants && .Root_Ring not_in grants {
		running := false
		for &item in started {
			if item.process != 0 && item.service.head != nil && is_role_holder(system.name_of(item.name[:]), .Storage) {
				running = true
			}
		}
		if !running {
			// The record of that start is the record of this one.
			if outcome := start(role_holder_name(.Storage), refusal = work.refusal); outcome != .Succeeded {
				return needed_service_failed(work.refusal)
			}
		}
	}
	// A client of a block service: the service of its disk starts first.
	status: call_outcome.Call_Outcome
	if .Data_Disk in grants || .Scratch_Disk in grants {
		place := .Data_Disk in grants ? pci.Place{device = pci.DATA_DISK_DEVICE} : scratch_disk_place()
		work.driver, work.device_ring, status = driver_start(place, name == "iommu" ? DRIVER_IOMMU_DEVICE : DRIVER_BLOCK)
	} else if .Network_Device in grants {
		work.driver, work.device_ring, status = driver_start(pci.Place{device = pci.NETWORK_DEVICE}, DRIVER_FRAME)
	} else if .Sound_Device in grants {
		// One process plays at a time: a second one finds the sound service
		// of the device started, and does not start (src/md/features/timed_stream.md,
		// "One process at a time").
		place := pci.Place{device = pci.SOUND_DEVICE}
		for &item in started {
			if item.process != 0 && item.is_driver && item.device == place {
				system.log_fact(.Warning, Start_Refused_Sound_Device_Busy{refused_process = module_name_field(name)})
				return start_refuse(work, .Callee_Busy, .Busy, .Processes, 1, 1, 1)
			}
		}
		work.driver, work.device_ring, status = driver_start(place, DRIVER_SOUND)
	}
	switch status {
	case .Succeeded:
		return .Succeeded
	case .Nothing_Has_That_Name:
		// No device of the class at its place: the machine lacks it.
		return start_refuse(work, .Callee_Unavailable, .Device)
	case .Argument_Refused, .Grant_Or_Right_Missing, .Name_Already_Taken, .Wrong_State, .Another_Change_Came_First, .Operation_Unsupported, .Budget_Or_Capacity_Exhausted, .Callee_Busy, .Callee_Unavailable, .Data_Damaged, .Stopped_After_A_Partial_Change, .Callee_Stopped_During_The_Call, .Connection_Ended_During_The_Call, .Deadline_Passed_During_The_Call, .Answer_Unreadable:
	}
	return start_kernel_refused(work, status)
}

// start_refuse writes the error record of a refused start where the asker
// reads it, and gives the outcome that names the refusal.
start_refuse :: proc "contextless" (work: ^Start_Work, outcome: call_outcome.Call_Outcome, kind: errors.Kind, unit: errors.Unit = .None, argument: i64 = 0, value: i64 = 0, limit: i64 = 0, found: i64 = 0) -> call_outcome.Call_Outcome {
	start_refusal_keep(work, errors.ring_fail(u32(root_ring.Root_Command.Start), kind, unit, argument, value, limit, found))
	return outcome
}

// start_kernel_refused writes the record Refused of a kernel operation of
// the start that the kernel refused, with the status in found, and gives
// the outcome of a refusal on the objects of this service: the border of
// the kernel until the kernel gives the call outcome itself.
start_kernel_refused :: proc "contextless" (work: ^Start_Work, status: call_outcome.Call_Outcome) -> call_outcome.Call_Outcome {
	return start_refuse(work, system.own_operation_outcome(status), .Refused, .None, 0, 0, 0, i64(status))
}

// start_refusal_keep writes the error record of a refusal that names its
// cause where the asker of the start reads it: the completion of its
// command.
start_refusal_keep :: proc "contextless" (work: ^Start_Work, record: [7]u64) {
	if work.refusal != nil {
		work.refusal^ = record
	}
}

// start_place_take takes a free place of the table of the processes, and
// writes there what the steps that follow read: the name, which the
// connection to the storage service names, the principal, which the name of
// its store carries, and the start grant set, which the grant of each connection
// reads.
start_place_take :: proc "contextless" (work: ^Start_Work) -> call_outcome.Call_Outcome {
	for &item in started {
		if place_is_free(&item) {
			work.slot = &item
			break
		}
	}
	if work.slot == nil {
		// The table of the processes frees a place when a process stops.
		return start_refuse(work, .Callee_Busy, .Full, .Processes, 0, 0, i64(len(started)))
	}
	slot := work.slot
	slot^ = {}
	// The steps that follow can start another process (a service on demand
	// at the connection to the private store): that start takes another
	// place.
	slot.reserved = true
	copy(slot.name[:len(slot.name) - 1], work.name)
	slot.principal = work.principal
	slot.start_grant_set = work.start_grant_set
	return .Succeeded
}

// start_abandon undoes a start that failed after start_prepare: the place
// of the process is freed with what this service made for it, and the
// device service that the start started stops.
start_abandon :: proc "contextless" (work: ^Start_Work) {
	if work.name == "collector" {
		wide_grant_collector_abandon(work)
	}
	if work.slot != nil {
		release(work.slot)
	}
	// The place of the terminal holds nothing yet: only its mark.
	if work.view != nil && work.view.process == 0 {
		work.view^ = {}
	}
	if work.driver != nil {
		started_process_stop(work.driver)
	}
}

// start_handles_close closes the handles of this service that the start
// made for the process and does not keep.
start_handles_close :: proc "contextless" (work: ^Start_Work) {
	handles := [?]system.Handle{work.device_ring, work.store_ring, work.store_region, work.endpoint_ring, work.endpoint_region, work.clock_ports, work.shared[0], work.shared[1]}
	for handle in handles {
		if handle != 0 {
			system.close(handle)
		}
	}
}

// start_grant_put writes one handle of the start grant set into the context of the
// process, at the context slot of system.START_GRANT_SET_HANDLE_SLOTS. A handle that
// root_ring.start_grant_set_handles does not give the start grant set is refused as a taken
// slot, so the start follows the one mapping that the tests read. The
// first refused slot is kept: the start then fails before the process
// runs (start_process_load).
start_grant_put :: proc "contextless" (work: ^Start_Work, handle: root_ring.Start_Grant_Set_Handle, grant: system.Grant) {
	slot := system.START_GRANT_SET_HANDLE_SLOTS[handle]
	if handle not_in root_ring.start_grant_set_handles(work.start_grant_set.grants) {
		system.context_refusal_note(&work.grants.refusal, slot)
		return
	}
	system.grant_put(&work.grants, slot, grant)
}

// start_mapping_add adds one mapping of the process, or says that it does
// not fit.
start_mapping_add :: proc "contextless" (work: ^Start_Work, what: string, mapping: system.Mapping) {
	if work.mapping_count >= len(work.mappings) {
		mapping_needed_log(what, work.name, len(work.mappings))
		work.mappings_full = true
		return
	}
	work.mappings[work.mapping_count] = mapping
	work.mapping_count += 1
}

// start_context_build builds the context of the process from its start grant set:
// each step writes the handles, the values and the mappings of one part.
start_context_build :: proc "contextless" (work: ^Start_Work) -> call_outcome.Call_Outcome {
	if work.device_ring != 0 {
		start_grant_put(work, .Device_Ring, {work.device_ring, {.Read, .Write}})
	}
	// The device service with Read: its stop is an event of the client, so
	// a client that waits for its answer learns of the stop at once
	// (src/md/features/missing_hardware.md).
	if work.driver != nil && work.driver.process != 0 {
		start_grant_put(work, .Device_Service, {work.driver.process, {.Read}})
	}
	start_values_of_the_name(work)
	if .Tpm in work.start_grant_set.grants {
		tpm_grants_give(work)
		system.value_put(&work.values, system.GRANT_VALUE_SEAL_ALLOWED, u64(tpm_seal_allowed()))
	}
	start_grant_put(work, .Log, log_grant(work.start_grant_set))
	if outcome := start_store_give(work); outcome != .Succeeded {
		return outcome
	}
	if outcome := start_view_give(work); outcome != .Succeeded {
		return outcome
	}
	if outcome := start_rings_give(work); outcome != .Succeeded {
		return outcome
	}
	start_handles_of_the_start_grant_set_give(work)
	start_pages_give(work)
	if outcome := start_service_give(work); outcome != .Succeeded {
		return outcome
	}
	if work.mappings_full {
		return start_refuse(work, .Budget_Or_Capacity_Exhausted, .Full, .Records, 0, 0, START_MAPPING_LIMIT)
	}
	return .Succeeded
}

// start_values_of_the_name writes the values that a process receives by its
// name, as only that process reads them.
start_values_of_the_name :: proc "contextless" (work: ^Start_Work) {
	if is_role_holder(work.name, .Powerbox) {
		powerbox_context_give(work) // powerbox_picker.odin
	}
	switch work.name {
	case "unlock":
		unlock_values_write(&work.values)
	case "collector":
		// The collector receives its principal, the authority key of the
		// wide grants and the ring of the grants (wide_grant_authority.odin).
		wide_grant_collector_context(work)
	case "module_files":
		// The module file service serves the callers of the principal of
		// its store only, and learns that principal here.
		system.value_put(&work.values, system.GRANT_VALUE_SERVICE_PRINCIPAL, work.principal)
	case "randomness":
		// The facts of the seed of the system, that only this service has:
		// the process shows them (docs/RANDOMNESS.md). Facts, not the seed.
		facts: [op.CONTEXT_VALUES]u64
		random.report_values_write(&entropy_report, &facts)
		system.values_put(&work.values, system.GRANT_VALUE_SEED_FACTS, facts[system.GRANT_VALUE_SEED_FACTS:][:system.SEED_FACTS_VALUE_COUNT])
	}
}

// start_store_give connects the process to its private store, in its
// context: the call ring, the call region, the storage service with the
// right Read, and its file. A process with Root_Ring connects to the
// storage service itself.
start_store_give :: proc "contextless" (work: ^Start_Work) -> call_outcome.Call_Outcome {
	grants := work.start_grant_set.grants
	if .Store not_in grants || .Root_Ring in grants {
		return .Succeeded
	}
	storage_service: ^Started
	outcome: call_outcome.Call_Outcome
	_, storage_service, work.store_ring, work.store_region, outcome = connection_open(work.slot, role_holder_name(.Storage), work.refusal, u32(root_ring.Root_Command.Start), store_override = work.store_override, store_limit_override = work.store_limit_override)
	if outcome != .Succeeded {
		return outcome
	}
	start_grant_put(work, .Storage_Ring, {work.store_ring, {.Read, .Write}})
	start_grant_put(work, .Storage_Region, {work.store_region, {.Read, .Write}})
	service_rights := system.Rights{.Read}
	if work.start_grant_set.store_gives {
		service_rights += {.Give}
	}
	start_grant_put(work, .Storage_Service, {storage_service.process, service_rights})
	for &item in system.image_entries(image) {
		if is_role_holder(system.name_of(item.name[:]), .Storage) && item.offset % system.PAGE_SIZE == 0 && item.offset <= u64(len(image)) && item.size <= u64(len(image)) - item.offset {
			mapping, given := image_entry_mapping(&item, storage.FILE_ADDRESS)
			if !given {
				return start_refuse(work, .Data_Damaged, .Damaged, .Modules)
			}
			system.value_put(&work.values, system.GRANT_VALUE_STORAGE_FILE_SIZE, item.size)
			start_mapping_add(work, "the file of the storage service", mapping)
		}
	}
	return .Succeeded
}

// start_view_give gives a process with the grant Terminal the terminal ring
// and the text region, and a free place for its terminal; else a window: a
// ring to the compositor. This service does not keep the memory objects
// that it makes here.
//
// With no screen, a process with the grant Terminal does not start: its
// terminal would show nothing, and its writes would fill a ring that no
// process reads. Another process starts with no window: `display.open`
// refuses it with the record No_Grant of a surface, and a process that runs
// with no window (a service, `remote`) runs. The line of the absence of the
// screen says this once; each refusal here adds no line.
//
// serial_terminal and dom_terminal need no screen: with them, a process
// with the grant Terminal starts on a machine with no screen too. A console image has no
// window server: there, a process with no terminal starts with no window.
start_view_give :: proc "contextless" (work: ^Start_Work) -> call_outcome.Call_Outcome {
	terminal_wanted := .Terminal in work.start_grant_set.grants
	if desktop_absent() && !(terminal_wanted && !role_policy.console_renderer_needs_screen(console_renderer)) {
		if terminal_wanted {
			return start_refuse(work, .Operation_Unsupported, .Unsupported, .Terminal)
		}
		return .Succeeded
	}
	status: call_outcome.Call_Outcome
	if terminal_wanted {
		for &item in started {
			if place_is_free(&item) && &item != work.slot {
				work.view = &item
				break
			}
		}
		if work.view == nil {
			return start_refuse(work, .Callee_Busy, .Full, .Processes, 0, 0, i64(len(started)))
		}
		work.view.reserved = true
		if work.shared[0], status = system.memory_create(ring.pages(terminal.RING_CAPACITY)); status != .Succeeded {
			return start_kernel_refused(work, status)
		}
		if work.shared[1], status = system.memory_create(terminal.TEXT_PAGES); status != .Succeeded {
			return start_kernel_refused(work, status)
		}
		start_grant_put(work, .Terminal_Ring, {work.shared[0], {.Read, .Write}})
		start_grant_put(work, .Terminal_Text, {work.shared[1], {.Read, .Write}})
		return .Succeeded
	}
	// The start policy has no window (root_ring.start_grant_set_handles), and neither
	// have the run of `unlock` and the holder of Plans before it, as no
	// compositor runs yet. A
	// replay has none: the compositor would write into its ring.
	if .Start_Policy in work.start_grant_set.grants || unlock_without_window(work.name) || plan_at_start_without_window() || work.hold == .For_Replay {
		return .Succeeded
	}
	if console_renderer != .Desktop_Terminal {
		return .Succeeded
	}
	if work.shared[0], status = system.memory_create(ring.PAGE_COUNT); status != .Succeeded {
		return start_kernel_refused(work, status)
	}
	if work.slot.client, status = system.give(display_holder, work.shared[0], {.Read, .Write}); status != .Succeeded {
		return start_kernel_refused(work, status)
	}
	// The capture face and the input face ride this ring: the compositor
	// takes them only from the client whose record says so.
	capture: u64 = .Screen_Capture in work.start_grant_set.grants ? display.CLIENT_CAPTURE : 0
	// The window of unlock that proves a principal for a wide grant takes
	// the keys of the input service only: an agent with input never types
	// the proof of its own grant.
	local_input_only: u64 = work.name == "unlock" && unlock_run.mode == .Prove_Wide_Grant ? display.CLIENT_LOCAL_INPUT_ONLY : 0
	// Values 1 to 3: the name of the module, the one name of the window
	// that the process does not choose; value 4 is 0 for a process of the
	// boot image.
	name := disk_process.name_pack(work.name)
	system.send(&control.commands, ring.Record{kind = u32(display.Control.Client_Add), values = {0 = u64(work.slot.client), 1 = name[0], 2 = name[1], 3 = name[2], display.CLIENT_ADD_CAPTURE = capture, display.CLIENT_ADD_LOCAL_INPUT_ONLY = local_input_only}})
	start_grant_put(work, .Display, {work.shared[0], {.Read, .Write}})
	return .Succeeded
}

// start_rings_give makes the rings of the start grant set: the root ring of a sender
// of root commands, the control ring of the network service, and the
// endpoint of a process with the grant Network.
start_rings_give :: proc "contextless" (work: ^Start_Work) -> call_outcome.Call_Outcome {
	slot := work.slot
	grants := work.start_grant_set.grants
	status: call_outcome.Call_Outcome
	if root_ring.root_ring_given(grants) {
		accepts_handles := root_ring.sender_allowed(.Wire, grants) || root_ring.sender_allowed(.Start_Edit, grants)
		if slot.requests_memory, slot.requests, status = system.ring_create(receive_handles = accepts_handles); status != .Succeeded {
			return start_kernel_refused(work, status)
		}
		start_grant_put(work, .Root_Ring, {slot.requests_memory, {.Read, .Write}})
	}
	if .Network_Device in grants {
		if slot.network_memory, slot.network, status = system.ring_create(); status != .Succeeded {
			return start_kernel_refused(work, status)
		}
		start_grant_put(work, .Network_Control, {slot.network_memory, {.Read, .Write}})
	}
	if .Network in grants {
		outcome: call_outcome.Call_Outcome
		if work.endpoint_ring, work.endpoint_region, outcome = endpoint_open(slot, work.name, work.refusal); outcome != .Succeeded {
			return outcome
		}
		start_grant_put(work, .Datagram_Ring, {work.endpoint_ring, {.Read, .Write}})
		start_grant_put(work, .Datagram_Region, {work.endpoint_region, {.Read, .Write}})
	}
	return .Succeeded
}

// start_handles_of_the_start_grant_set_give gives the handles that a start grant names:
// the one machine handle with a part of its rights, the records of the
// log, the boot image, the replacement table, the client table, the
// settings page, and the date page with the ports of the clock.
start_handles_of_the_start_grant_set_give :: proc "contextless" (work: ^Start_Work) {
	grants := work.start_grant_set.grants
	if .Inspect in grants {
		work.machine_rights += {.Inspect}
	}
	if .Stop in grants {
		work.machine_rights += {.Stop}
	}
	if .Schedule in grants {
		work.machine_rights += {.Schedule}
	}
	if .Events in grants {
		work.machine_rights += {.Events}
	}
	if .Counters in grants {
		work.machine_rights += {.Counters}
	}
	if work.machine_rights != {} {
		start_grant_put(work, .Machine, {machine, work.machine_rights})
	}
	if .Log_Records in grants {
		start_grant_put(work, .Log_Records, {system.context_record().handles[op.ROOT_LOG_RECORDS], {.Read}})
		start_grant_put(work, .Session_Table, {session_table_memory, {.Read}})
		// The window of the log shows the records of this principal only.
		system.value_put(&work.values, system.GRANT_VALUE_SERVICE_PRINCIPAL, work.principal)
	}
	if .Image in grants {
		start_grant_put(work, .Image, {image_memory, {.Read}})
		system.value_put(&work.values, system.GRANT_VALUE_IMAGE_SIZE, u64(len(image)))
	}
	if .Replacements in grants {
		start_grant_put(work, .Replacements, {replacement_memory, {.Read}})
	}
	if .Remote_Clients in grants {
		start_grant_put(work, .Client_Table, {client_table_memory, {.Read}})
	}
	if .Settings in grants {
		start_grant_put(work, .Settings_Page, {settings_memory, {.Read, .Write}})
	}
	// The pass goes to the holder of Settings in force: a holder that a
	// plan gave has no grant Settings and no page, and still learns which
	// pass started it. A service that the start of the holder starts first
	// (the storage service) gets no value.
	if is_role_holder(work.name, .Settings) {
		system.value_put(&work.values, settings.VALUE_PASS, u64(settings_pass))
	}
	if .Clock in grants {
		start_grant_put(work, .Date_Page, {date_memory, {.Read, .Write}})
		results, ports_status := system.call(.Device_Create, u64(machine), u64(op.Device_Kind.Ports), 0x70, 2)
		if ports_status == .Succeeded {
			work.clock_ports = system.Handle(results[0])
			start_grant_put(work, .Date_Ports, {work.clock_ports, {}})
		}
	}
}

// start_pages_give maps the pages that each process reads, and those of its
// start grant set: the date page and its fresh bytes page, the debug image, the disk
// process page, and for a process with a surface the settings page and the
// font outlines, read-only.
start_pages_give :: proc "contextless" (work: ^Start_Work) {
	grants := work.start_grant_set.grants
	date_page_give(work.mappings[:], &work.mapping_count, &work.values)
	fresh_bytes_page_give(work.slot, work.mappings[:], &work.mapping_count, &work.values)
	// Each process: whether the machine runs for a measure. The boot image
	// says it, so the modules of a measure run are the modules of a test.
	if system.image_resource_find(image, system.MEASURE_RUN_RESOURCE) != nil {
		system.value_put(&work.values, op.CONTEXT_VALUE_MEASURE_RUN, 1)
	}
	if .Debug_Image in grants {
		debug_image_give(work.mappings[:], &work.mapping_count, &work.values)
	}
	// A process that sees each process: which of them run from a disk, by
	// their nicknames and the hashes that this service checked.
	if .Inspect in grants {
		disk_process_page_give(work.mappings[:], &work.mapping_count, &work.values)
	}
	// The start policy draws no text: it reads the machine parts page and
	// its list.
	if .Start_Policy in grants {
		start_policy_pages_give(work)
	} else if .Terminal not_in grants {
		// The writer of the settings and the date service read the settings
		// of the machine; each other process draws with its presentation
		// record (src/md/features/module_settings.md).
		page := .Settings in grants || .Clock in grants ? Text_Settings_Page.Machine : Text_Settings_Page.Presentation
		text_settings_give(work.mappings[:], &work.mapping_count, &work.values, page, work.slot)
	}
	// The plan values of the owner of the module: its defaults and its
	// locks, read-only, written at this start (plan_values.odin).
	plan_values_page_give(work.slot, work.name, work.mappings[:], &work.mapping_count, &work.values)
	if work.edit_target_page != 0 {
		start_mapping_add(work, "the target of edit", {memory = work.edit_target_page, address = fixed_addresses.EDIT_TARGET_PAGE_ADDRESS, first = 0, page_count = 1})
		system.range_mapped_put(&work.values, .Edit_Target_Page)
	}
}

// start_service_give gives a service its service ring, and its own file,
// to read the descriptions of its exports.
start_service_give :: proc "contextless" (work: ^Start_Work) -> call_outcome.Call_Outcome {
	entry := work.entry
	if .Serve not_in work.start_grant_set.grants || entry.offset % system.PAGE_SIZE != 0 || work.mappings_full {
		return .Succeeded
	}
	if work.mapping_count >= len(work.mappings) {
		mapping_needed_log("the file of the service", work.name, len(work.mappings))
		work.mappings_full = true
		return .Succeeded
	}
	file_mapping, given := image_entry_mapping(entry, isolated.FILE_ADDRESS)
	if !given {
		return start_refuse(work, .Data_Damaged, .Damaged, .Modules, 1)
	}
	slot := work.slot
	status: call_outcome.Call_Outcome
	if slot.service_memory, slot.service, status = system.ring_create(); status != .Succeeded {
		return start_kernel_refused(work, status)
	}
	start_grant_put(work, .Service_Ring, {slot.service_memory, {.Read, .Write}})
	system.value_put(&work.values, system.GRANT_VALUE_FILE_ADDRESS, isolated.FILE_ADDRESS)
	system.value_put(&work.values, system.GRANT_VALUE_FILE_SIZE, entry.size)
	start_mapping_add(work, "the file of the service", file_mapping)
	return .Succeeded
}

// start_process_load starts the process with its context, its budget and
// its mappings. A slot that two grants took, or a value that two parts of
// the start wrote, refuses the start first, with its line: no process
// starts with a handle or a value lost.
start_process_load :: proc "contextless" (work: ^Start_Work) -> call_outcome.Call_Outcome {
	name := work.name
	// Two grants in one slot, or one value written twice: the table of the
	// boot image is damaged.
	if context_refused(name, &work.grants, &work.values) {
		return start_refuse(work, .Data_Damaged, .Damaged, .Records)
	}
	load_error: module.Load_Error
	// The floor of the start holds the audits of the collector and the
	// wirings of the start policy (start_floor_of). A floor that this
	// service cannot pay refuses the start, with its line, before any page
	// moves.
	start_budget, budget_ok := budget_of(work.file, name, work.principal)
	if !budget_ok {
		return start_refuse(work, .Budget_Or_Capacity_Exhausted, .Budget, .Pages)
	}
	process_budget := start_budget.amounts
	status: call_outcome.Call_Outcome
	// The start of the measure of the start of a window: the load of the
	// module, its hash and Process_Start are in it
	// (src/md/features/desktop_to_browser.md, "The three measures on the path of the system").
	started_at := system.nanoseconds()
	// Only a process that can send Wire asks for a wiring, which its budget
	// pays: this service keeps a handle of that budget for it alone. Each
	// other process with a root ring (Connect, Principals, Debugger) holds
	// no handle of this service for its budget: the handle table of this
	// service holds one handle for each process that it keeps one for.
	work.wiring.keep_budget = root_ring.sender_allowed(.Wire, work.start_grant_set.grants)
	// The collector pays the rings of the audit of a wide grant, which the
	// root service asks in its name (src/md/features/wide_grants.md, "The
	// path of a grant, end to end").
	work.wiring.keep_budget ||= work.name == "collector"
	held_entry: ^u64
	switch work.hold {
	case .None:
	case .At_First_Instruction:
		held_entry = &work.slot.held_entry
	case .For_Replay:
		held_entry = &work.slot.held_entry
		work.slot.held_for_replay = true
	}
	seeded_values := random.values_with_seed(&process_generator, work.values.values)
	defer {
		intrinsics.mem_zero_volatile(&seeded_values, size_of(seeded_values))
		intrinsics.mem_zero_volatile(&work.values.values, size_of(work.values.values))
	}
	work.slot.process, status = system.process_start(work.file, name, work.grants.grants, seeded_values, process_budget, work.mappings[:work.mapping_count], &prepared, load_source(), &load_error, wiring = &work.wiring, held_entry = held_entry, ready = &work.slot.ready)
	if status == .Succeeded {
		start_budget_note(work.slot, start_budget)
		// A process with a window of its own: the compositor ties the time
		// to the ring of the window that Client_Add gave.
		if .Terminal not_in work.start_grant_set.grants && work.slot.client != 0 {
			if !system.send(&control.commands, ring.Record{kind = u32(display.Control.Client_Started), values = {0 = u64(work.slot.client), 1 = started_at}}) {
				// A measure, not a part of the start: the window runs, and
				// has no line of its start.
				system.log_fact(.Warning, Window_Start_Not_Measured{window_process = module_name_field(name)})
			}
		}
		return .Succeeded
	}
	// A budget of no page: the start failed before process_start.
	if status == .Budget_Or_Capacity_Exhausted && process_budget.pages != 0 {
		budget_refusal_log(name, process_budget, 0, "this service")
	} else if load_error.stage != u32(module.Load_Stage.None) {
		system.log_fact(.Warning, Start_Refused_By_Loader{refused_process = module_name_field(name)})
		load_error_log(.Warning, &load_error)
	} else {
		system.log_fact(.Warning, Start_Failed{status = status, refused_process = module_name_field(name)})
	}
	// Capacity exhaustion or busy tables: of the child or of this service,
	// which prepares the module; the line of the tables of this service tells
	// which.
	if status == .Budget_Or_Capacity_Exhausted || status == .Callee_Busy {
		own_tables_log(name)
	}
	return start_kernel_refused(work, status)
}

// start_finish records what the process received, and starts its terminal.
start_finish :: proc "contextless" (work: ^Start_Work) -> call_outcome.Call_Outcome {
	slot := work.slot
	grants := work.start_grant_set.grants
	slot.driver = work.driver
	slot.hash = work.entry.hash
	slot.granted += {.Log}
	if work.machine_rights != {} {
		slot.granted += {.Machine}
	}
	if .Image in grants {
		slot.granted += {.Image}
	}
	if .Log_Records in grants {
		slot.granted += {.Log_Records}
	}
	if .Network in grants {
		slot.granted += {.Network}
	}
	if .Acts_For_Principal in grants {
		slot.granted += {.Acts_For_Principal}
	}
	if work.view != nil {
		if status := terminal_start(work.view, slot, work.shared[0], work.shared[1]); status != .Succeeded {
			started_process_stop(slot)
			return start_kernel_refused(work, status)
		}
		started_log(work.name, work.principal, true)
		return .Succeeded
	}
	started_log(work.name, work.principal, false)
	return .Succeeded
}
