package root

// The start of a process of the boot image by its name: the role that the
// tables of this service give the name, the services that the role needs,
// and one context whose handles each take their own slot.

import info "modus:contract/boot_info"
import "modus:contract/isolated"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:contract/settings"
import "modus:support/display"
import "modus:support/pci"
import "modus:support/principals"
import "modus:support/random"
import "modus:support/storage"
import "modus:support/system"
import terminal "modus:support/terminal"

// The mappings of a start: the storage file, the date page, the fresh
// bytes page, the settings page, the file of a service, the debug image,
// the disk process page and the font outlines: 8 places for the union, and
// the largest role uses 7.
START_MAPPING_LIMIT :: 8

// The work of one start: what the steps of start() build, and the handles
// of this service that the start closes at its end, whatever its result.
// The process and the services hold their own copies of those handles.
Start_Work :: struct {
	name:           string,
	principal:      u64,
	role:           Process_Role,
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
}

// start starts a process of the boot image that shows a surface or has a
// terminal, in the session of a principal (principals.odin).
start :: proc "contextless" (name: string, principal: u64 = principals.MACHINE) -> system.Status {
	work := Start_Work {
		name      = name,
		principal = principal,
	}
	defer start_handles_close(&work)
	if status := start_prepare(&work); status != .Ok {
		return status
	}
	if status := start_place_take(&work); status != .Ok {
		start_abandon(&work)
		return status
	}
	status := start_context_build(&work)
	if status == .Ok {
		status = start_process_load(&work)
	}
	if status != .Ok {
		start_abandon(&work)
		return status
	}
	return start_finish(&work)
}

// start_prepare finds the file of the process, refuses a name that start()
// does not start, reads the role, and starts the services that the role
// needs first: the network service, the storage service, and the device
// service of a client of a disk or of the network device.
start_prepare :: proc "contextless" (work: ^Start_Work) -> system.Status {
	name := work.name
	for &item in system.image_entries(image) {
		if system.name_of(item.name[:]) == name && item.offset <= u64(len(image)) && item.size <= u64(len(image)) - item.offset {
			work.file = image[item.offset:][:item.size]
			work.entry = &item
			break
		}
	}
	if len(work.file) == 0 || name_is_a_system_part(name) {
		return .Bad_Operation
	}
	// One `unlock` at a time, and only from unlock_start: two runs would
	// share the ring of the principals and the ring and the region of the
	// TPM service, and one would read the answers of the other.
	if name == "unlock" && (unlock_run.stage != .Starting || find("unlock") != nil) {
		return .Bad_State
	}
	work.role = role_of(name)
	grants := work.role.grants
	// The start policy starts from start_policy_launch only: a second
	// holder of its root ring would start and stop the processes of the
	// machine.
	if .Start_Policy in grants && !start_policy_starting {
		return .Bad_Operation
	}
	// A role whose handles meet in one context slot does not start, before
	// any service starts for it.
	if slot, twice := system.role_slot_taken_twice(grants); twice {
		grant_slot_refused(name, slot)
		return .Bad_State
	}
	// A process with an endpoint: the network service starts first.
	if .Network in grants {
		network_service() or_return
	}
	// A process with a store: the storage service starts first.
	if .Store in grants && .Acts_For_Principal not_in grants {
		running := false
		for &item in started {
			if item.process != 0 && item.service.head != nil && system.name_of(item.name[:]) == "storage" {
				running = true
			}
		}
		if !running {
			start("storage") or_return
		}
	}
	// A client of a block service: the service of its disk starts first.
	status: system.Status
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
				return .Bad_State
			}
		}
		work.driver, work.device_ring, status = driver_start(place, DRIVER_SOUND)
	}
	return status
}

// start_place_take takes a free place of the table of the processes, and
// writes there what the steps that follow read: the name, which the
// connection to the storage service names, the principal, which the name of
// its store carries, and the role, which the grant of each connection
// reads.
start_place_take :: proc "contextless" (work: ^Start_Work) -> system.Status {
	for &item in started {
		if place_is_free(&item) {
			work.slot = &item
			break
		}
	}
	if work.slot == nil {
		return .No_Slot
	}
	slot := work.slot
	slot^ = {}
	// The steps that follow can start another process (a service on demand
	// at the connection to the private store): that start takes another
	// place.
	slot.reserved = true
	copy(slot.name[:len(slot.name) - 1], work.name)
	slot.principal = work.principal
	slot.role = work.role
	return .Ok
}

// start_abandon undoes a start that failed after start_prepare: the place
// of the process is freed with what this service made for it, and the
// device service that the start started stops.
start_abandon :: proc "contextless" (work: ^Start_Work) {
	if work.slot != nil {
		release(work.slot)
	}
	// The place of the terminal holds nothing yet: only its mark.
	if work.view != nil && work.view.process == 0 {
		work.view^ = {}
	}
	if work.driver != nil {
		system.process_stop(work.driver.process)
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

// start_grant_put writes one handle of the role into the context of the
// process, at the context slot of system.ROLE_HANDLE_SLOTS. A handle that
// root_ring.role_handles does not give the role is refused as a taken
// slot, so the start follows the one mapping that the tests read. The
// first refused slot is kept: the start then fails before the process
// runs (start_process_load).
start_grant_put :: proc "contextless" (work: ^Start_Work, handle: root_ring.Role_Handle, grant: system.Grant) {
	slot := system.ROLE_HANDLE_SLOTS[handle]
	if handle not_in root_ring.role_handles(work.role.grants) {
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

// start_context_build builds the context of the process from its role:
// each step writes the handles, the values and the mappings of one part.
start_context_build :: proc "contextless" (work: ^Start_Work) -> system.Status {
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
	if .Tpm in work.role.grants {
		tpm_grants_give(work)
		system.value_put(&work.values, system.GRANT_VALUE_SEAL_ALLOWED, u64(tpm_seal_allowed()))
	}
	start_grant_put(work, .Log, log_grant(work.role))
	start_store_give(work) or_return
	start_view_give(work) or_return
	start_rings_give(work) or_return
	start_handles_of_the_role_give(work)
	start_pages_give(work)
	start_service_give(work) or_return
	return work.mappings_full ? .No_Slot : .Ok
}

// start_values_of_the_name writes the values that a process receives by its
// name, as only that process reads them.
start_values_of_the_name :: proc "contextless" (work: ^Start_Work) {
	switch work.name {
	case "unlock":
		unlock_values_write(&work.values)
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
// right Read, and its file. A process that acts for its principal connects
// to the storage service itself.
start_store_give :: proc "contextless" (work: ^Start_Work) -> system.Status {
	grants := work.role.grants
	if .Store not_in grants || .Acts_For_Principal in grants {
		return .Ok
	}
	storage_service: ^Started
	status: system.Status
	_, storage_service, work.store_ring, work.store_region, status = connection_open(work.slot, "storage")
	if status != .Ok {
		return status
	}
	start_grant_put(work, .Storage_Ring, {work.store_ring, {.Read, .Write}})
	start_grant_put(work, .Storage_Region, {work.store_region, {.Read, .Write}})
	start_grant_put(work, .Storage_Service, {storage_service.process, {.Read}})
	for &item in system.image_entries(image) {
		if system.name_of(item.name[:]) == "storage" && item.offset % system.PAGE_SIZE == 0 && item.offset <= u64(len(image)) && item.size <= u64(len(image)) - item.offset {
			system.value_put(&work.values, system.GRANT_VALUE_STORAGE_FILE_SIZE, item.size)
			start_mapping_add(work, "the file of the storage service", {memory = image_memory, address = storage.FILE_ADDRESS, first = item.offset / system.PAGE_SIZE, page_count = (item.size + system.PAGE_SIZE - 1) / system.PAGE_SIZE})
		}
	}
	return .Ok
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
start_view_give :: proc "contextless" (work: ^Start_Work) -> (status: system.Status) {
	if screen_absent {
		return .Terminal in work.role.grants ? .Bad_State : .Ok
	}
	if .Terminal in work.role.grants {
		for &item in started {
			if place_is_free(&item) && &item != work.slot {
				work.view = &item
				break
			}
		}
		if work.view == nil {
			return .No_Slot
		}
		work.view.reserved = true
		work.shared[0] = system.memory_create(ring.pages(terminal.RING_CAPACITY)) or_return
		work.shared[1] = system.memory_create(terminal.TEXT_PAGES) or_return
		start_grant_put(work, .Terminal_Ring, {work.shared[0], {.Read, .Write}})
		start_grant_put(work, .Terminal_Text, {work.shared[1], {.Read, .Write}})
		return .Ok
	}
	// The start policy has no window (root_ring.role_handles), and neither
	// has the run of `unlock` before it, as no compositor runs yet.
	if .Start_Policy in work.role.grants || unlock_without_window(work.name) {
		return .Ok
	}
	work.shared[0] = system.memory_create(ring.PAGE_COUNT) or_return
	work.slot.client = system.give(compositor, work.shared[0], {.Read, .Write}) or_return
	// The capture face and the input face ride this ring: the compositor
	// takes them only from the client whose record says so.
	capture: u64 = .Screen_Capture in work.role.grants ? display.CLIENT_CAPTURE : 0
	system.send(&control.commands, ring.Record{kind = u32(display.Control.Client_Add), values = {0 = u64(work.slot.client), display.CLIENT_ADD_CAPTURE = capture}})
	start_grant_put(work, .Display, {work.shared[0], {.Read, .Write}})
	return .Ok
}

// start_rings_give makes the rings of the role: the root ring of a sender
// of root commands, the control ring of the network service, and the
// endpoint of a process with the grant Network.
start_rings_give :: proc "contextless" (work: ^Start_Work) -> (status: system.Status) {
	slot := work.slot
	grants := work.role.grants
	if root_ring.root_ring_given(grants) {
		slot.requests_memory, slot.requests = system.ring_create() or_return
		start_grant_put(work, .Root_Ring, {slot.requests_memory, {.Read, .Write}})
	}
	if .Network_Device in grants {
		slot.network_memory, slot.network = system.ring_create() or_return
		start_grant_put(work, .Network_Control, {slot.network_memory, {.Read, .Write}})
	}
	if .Network in grants {
		work.endpoint_ring, work.endpoint_region = endpoint_open(slot, work.name) or_return
		start_grant_put(work, .Datagram_Ring, {work.endpoint_ring, {.Read, .Write}})
		start_grant_put(work, .Datagram_Region, {work.endpoint_region, {.Read, .Write}})
	}
	return .Ok
}

// start_handles_of_the_role_give gives the handles that a start grant names:
// the one machine handle with a part of its rights, the records of the
// log, the boot image, the replacement table, the client table, the
// settings page, and the date page with the ports of the clock.
start_handles_of_the_role_give :: proc "contextless" (work: ^Start_Work) {
	grants := work.role.grants
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
		system.value_put(&work.values, settings.VALUE_BOOT_PASS, u64(settings_boot_pass))
	}
	if .Clock in grants {
		start_grant_put(work, .Date_Page, {date_memory, {.Read, .Write}})
		results, ports_status := system.call(.Device_Create, u64(machine), u64(op.Device_Kind.Ports), 0x70, 2)
		if ports_status == .Ok {
			work.clock_ports = system.Handle(results[0])
			start_grant_put(work, .Date_Ports, {work.clock_ports, {}})
		}
	}
}

// start_pages_give maps the pages that each process reads, and those of its
// role: the date page and its fresh bytes page, the debug image, the disk
// process page, and for a process with a surface the settings page and the
// font outlines, read-only.
start_pages_give :: proc "contextless" (work: ^Start_Work) {
	grants := work.role.grants
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
		text_settings_give(work.mappings[:], &work.mapping_count, &work.values)
	}
}

// start_service_give gives a service its service ring, and its own file,
// to read the descriptions of its exports.
start_service_give :: proc "contextless" (work: ^Start_Work) -> (status: system.Status) {
	entry := work.entry
	if .Serve not_in work.role.grants || entry.offset % system.PAGE_SIZE != 0 || work.mappings_full {
		return .Ok
	}
	if work.mapping_count >= len(work.mappings) {
		mapping_needed_log("the file of the service", work.name, len(work.mappings))
		work.mappings_full = true
		return .Ok
	}
	slot := work.slot
	slot.service_memory, slot.service = system.ring_create() or_return
	start_grant_put(work, .Service_Ring, {slot.service_memory, {.Read, .Write}})
	system.value_put(&work.values, system.GRANT_VALUE_FILE_ADDRESS, isolated.FILE_ADDRESS)
	system.value_put(&work.values, system.GRANT_VALUE_FILE_SIZE, entry.size)
	start_mapping_add(work, "the file of the service", {memory = image_memory, address = isolated.FILE_ADDRESS, first = entry.offset / system.PAGE_SIZE, page_count = (entry.size + system.PAGE_SIZE - 1) / system.PAGE_SIZE})
	return .Ok
}

// start_process_load starts the process with its context, its budget and
// its mappings. A slot that two grants took, or a value that two parts of
// the start wrote, refuses the start first, with its line: no process
// starts with a handle or a value lost.
start_process_load :: proc "contextless" (work: ^Start_Work) -> system.Status {
	name := work.name
	if context_refused(name, &work.grants, &work.values) {
		return .Bad_State
	}
	load_error: module.Load_Error
	process_budget := budget_of(work.file, name)
	status: system.Status
	// The start of the measure of the start of a window: the load of the
	// module, its hash and Process_Start are in it
	// (src/md/features/desktop_to_browser.md, "The three measures on the path of the system").
	started_at := system.nanoseconds()
	work.slot.process, status = system.process_start(work.file, name, work.grants.grants, random.values_with_seed(&process_generator, work.values.values), process_budget, work.mappings[:work.mapping_count], &prepared, load_source(), &load_error)
	if status == .Ok {
		// A process with a window of its own: the compositor ties the time
		// to the ring of the window that Client_Add gave.
		if .Terminal not_in work.role.grants && work.slot.client != 0 {
			if !system.send(&control.commands, ring.Record{kind = u32(display.Control.Client_Started), values = {0 = u64(work.slot.client), 1 = started_at}}) {
				// A measure, not a part of the start: the window runs, and
				// has no line of its start.
				system.log_fact(.Warning, Window_Start_Not_Measured{window_process = module_name_field(name)})
			}
		}
		return .Ok
	}
	// A budget of no page: the start failed before process_start.
	if status == .No_Budget && process_budget.pages != 0 {
		budget_refusal_log(name, process_budget, 0, "this service")
	} else if load_error.stage != .None {
		buffer: [512]u8
		writer := system.Writer{buffer = buffer[:]}
		system.load_error_text(&writer, &load_error)
		system.log(.Warning, "root: cannot start ", system.Module_Name{name}, ": ", system.written(&writer))
	} else {
		system.log_fact(.Warning, Start_Failed{status = status, refused_process = module_name_field(name)})
	}
	return status
}

// start_finish records what the process received, and starts its terminal.
start_finish :: proc "contextless" (work: ^Start_Work) -> system.Status {
	slot := work.slot
	grants := work.role.grants
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
		if status := terminal_start(work.view, slot, work.shared[0], work.shared[1]); status != .Ok {
			system.process_stop(slot.process)
			return status
		}
		started_log(work.name, work.principal, true)
		return .Ok
	}
	started_log(work.name, work.principal, false)
	return .Ok
}
