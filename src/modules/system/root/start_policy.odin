package root

// The start of the start policy, and its rescue (src/md/features/start_policy.md).
//
// This service keeps the mechanism of the start: the machine parts page,
// the start of one start policy with the start grant Start_Policy, the
// parts of the system that only it can start, and the rescue start policy
// when the chosen one fails. It holds no order of the start: the list of
// the start policy holds it. The policy says itself when the machine is
// usable (Machine_Usable); this service does not judge what it started.

import info "modus:contract/boot_info"
import op "modus:contract/operation"
import "modus:contract/start_list"
import "modus:contract/system_description"
import "modus:private/root/start_policy_rules"
import "modus:support/disk_process"
import "modus:support/pci"
import "modus:support/principals"
import "modus:support/system"

// What this service waits for of the start policy. The decisions on the
// commands of a start policy are in the private part start_policy_rules,
// which the host tests.
Start_Policy_Stage :: start_policy_rules.Stage

// The start policy that runs: the module of the boot image with one of its
// two lists, or the module of the store that principal 0 chose, with no
// list (start_policy_choice.odin).
Start_Policy_List :: enum u8 {
	Default, // start_list.START_LIST_RESOURCE.
	Rescue,  // start_list.RESCUE_LIST_RESOURCE.
	Chosen,  // No list: the module from the disk holds its own order.
}

// The resource of the list of each start policy of the boot image.
@(rodata)
START_POLICY_LIST_NAMES := [Start_Policy_List]string {
	.Default = start_list.START_LIST_RESOURCE,
	.Rescue  = start_list.RESCUE_LIST_RESOURCE,
	.Chosen  = "",
}

// The words of each start policy in a line of the log.
@(rodata)
START_POLICY_LIST_WORDS := [Start_Policy_List]string {
	.Default = "of the list " + start_list.START_LIST_RESOURCE,
	.Rescue  = "of the list " + start_list.RESCUE_LIST_RESOURCE,
	.Chosen  = "chosen by principal 0, from the disk",
}

START_POLICY_NAME :: "start_policy"

// The time that a start policy has to say that the machine is usable: the
// hang bound of the system, so that only a start policy that hangs meets
// it, never a slow machine.
START_POLICY_HANG_BOUND_MILLISECONDS :: system.TEST_HANG_BOUND_MILLISECONDS

start_policy_stage: Start_Policy_Stage
start_policy_list: Start_Policy_List
start_policy_process: ^Started // The place of the start policy that runs. nil: none.
start_policy_hash: [32]u8 // The hash of the module of the last start policy that started, for the lines.
start_policy_deadline: u64 = system.WAIT_FOREVER // Running: the time of the hang bound.
// The start of the start policy: only it may take the name, as only
// unlock_start takes the name of unlock.
start_policy_starting: bool

// The machine parts page: written once, before the start policy starts.
machine_parts_memory: system.Handle
machine_parts: start_list.Machine_Parts

// machine_parts_page_create checks each part of the machine that a start
// row can need, and writes the page. A part that this service cannot check
// is absent: the page never says that a part is present by default. The
// screen is the one test of the boot display (modus:support/screen_presence),
// so the page and the line of a machine with no screen agree. The PS/2
// controller is no part of the page: the input service reads its absence.
machine_parts_page_create :: proc "contextless" () {
	parts: start_list.Machine_Parts
	width, height: u32
	if !no_screen_at_the_start {
		parts += {.Screen}
		width, height = u32(screen.width), u32(screen.height)
	}
	if configuration_open() == .Ok {
		virtio_at := proc "contextless" (place: pci.Place, device: u32) -> bool {
			identity := pci.read_32(place, 0)
			return identity & 0xFFFF == pci.VENDOR_VIRTIO && identity >> 16 == device
		}
		if virtio_at({device = pci.DATA_DISK_DEVICE}, pci.DEVICE_VIRTIO_BLOCK) {
			parts += {.Data_Disk}
		}
		if virtio_at(scratch_disk_place(), pci.DEVICE_VIRTIO_BLOCK) {
			parts += {.Scratch_Disk}
		}
		if virtio_at({device = pci.NETWORK_DEVICE}, pci.DEVICE_VIRTIO_NETWORK) {
			parts += {.Network_Device}
		}
		if virtio_at({device = pci.SOUND_DEVICE}, pci.DEVICE_VIRTIO_SOUND) {
			parts += {.Sound_Device}
		}
		if virtio_at({device = pci.ENTROPY_DEVICE}, pci.DEVICE_VIRTIO_ENTROPY) {
			parts += {.Entropy_Device}
		}
	}
	if trust_boot_report.trust.measure == .Measured {
		parts += {.Tpm}
	}
	machine_parts = parts
	status: system.Status
	address: rawptr
	machine_parts_memory, status = system.memory_create(1)
	if status == .Ok {
		address, status = system.memory_map(machine_parts_memory)
	}
	if status != .Ok {
		// With no page, no start policy can read the parts: it starts
		// nothing, and the rescue does the same, with their lines.
		system.log(.Error, "root: cannot create the machine parts page: status ", status)
		machine_parts_memory = 0
		return
	}
	start_list.parts_page_write((^start_list.Machine_Parts_Page)(address), parts, width, height)
	buffer: [256]u8
	present := system.Writer{buffer = buffer[:]}
	for part in start_list.Machine_Part {
		if part in parts {
			if present.count > 0 {
				system.write_bytes(&present, transmute([]u8)string(", "))
			}
			system.write_bytes(&present, transmute([]u8)start_list.PART_NAMES[part])
		}
	}
	system.log(.Info, "root: the machine parts page: ", present.count > 0 ? system.written(&present) : "no part", "; the start policy reads it")
}

// start_policy_pages_give maps the machine parts page and the list of the
// start policy that starts, read-only, and states the size of the list.
// With no list, it maps neither: the start policy then stops with its
// line, before Machine_Usable.
start_policy_pages_give :: proc "contextless" (work: ^Start_Work) {
	if machine_parts_memory == 0 {
		return
	}
	list_mapping, list_size, given := resource_mapping(START_POLICY_LIST_NAMES[start_policy_list], start_list.START_LIST_ADDRESS, work.name)
	if !given {
		return
	}
	start_mapping_add(work, "the machine parts page", {memory = machine_parts_memory, address = start_list.MACHINE_PARTS_PAGE_ADDRESS, first = 0, page_count = 1})
	start_mapping_add(work, "the start list", list_mapping)
	system.value_put(&work.values, start_list.VALUE_LIST_SIZE, list_size)
	system.range_mapped_put(&work.values, .Start_Policy_Pages)
}

// What the boot record asks of this start, through its border: the start
// policy that principal 0 chose, or the rescue for one of three causes.
Start_Policy_Request :: enum u8 {
	Chosen, // The chosen start policy, or the default one with no choice.
	Rescue_By_Key, // The key R was held.
	Rescue_By_Boot_Entry, // The boot entry "modus (rescue)" started the machine.
	Rescue_By_Refused_Record, // The border refused the words of the boot record.
}

start_policy_request: Start_Policy_Request

// start_policy_begin reads the start request of the boot record, through
// its border, then the choice of principal 0 (start_policy_choice.odin),
// which starts the start policy that the request asks for. A rescue still
// reads the choice: the table holds the client keys of remote.
start_policy_begin :: proc "contextless" () {
	show("the root service starts the start policy", .Running, .Root)
	report := &trust_boot_report
	request, source, known := info.start_request_of_words(report.start_request, report.start_request_source)
	start_policy_request = .Chosen
	if !known {
		system.log(.Warning, "root: the boot record names the start request ", report.start_request, " with the source ", report.start_request_source, ", which the border refuses: the rescue start policy starts")
		start_policy_request = .Rescue_By_Refused_Record
	} else {
		switch request {
		case .Chosen:
		case .Rescue:
			switch source {
			case .Key:
				start_policy_request = .Rescue_By_Key
			case .Boot_Entry:
				start_policy_request = .Rescue_By_Boot_Entry
			case .None:
				// The border refuses Rescue with no source.
				start_policy_request = .Rescue_By_Refused_Record
			}
		}
	}
	start_policy_choice_read_begin()
}

// start_policy_after_the_choice starts the start policy of this start, once
// the choice of principal 0 is read or known to be absent. replaced is the
// hash text of the start policy that a rescue replaces: the chosen one, or
// the default one.
start_policy_after_the_choice :: proc "contextless" (chosen: ^disk_process.Grant_Row) {
	replaced := chosen != nil ? start_policy_hash_text(chosen.hash) : start_policy_hash_text_of_image()
	switch start_policy_request {
	case .Chosen:
		if chosen != nil {
			start_policy_chosen_load_begin(chosen)
			return
		}
		start_policy_launch(.Default)
	case .Rescue_By_Key:
		system.log(.Info, "root: the key R was held at the start: the rescue start policy starts in place of the start policy ", replaced)
		start_policy_launch(.Rescue)
	case .Rescue_By_Boot_Entry:
		system.log(.Info, "root: the boot entry modus (rescue) started the machine: the rescue start policy starts in place of the start policy ", replaced)
		start_policy_launch(.Rescue)
	case .Rescue_By_Refused_Record:
		system.log(.Warning, "root: the rescue start policy starts in place of the start policy ", replaced, ": the boot record asks for it with words that the border refuses")
		start_policy_launch(.Rescue)
	}
}

// start_policy_hash_text gives the first 8 digits of the hash of the
// module of a start policy, for a line.
start_policy_hash_text :: proc "contextless" (hash: [32]u8) -> string {
	@(static) text: [8 + len("…")]u8
	digits := system_description.hexadecimal(hash)
	copy(text[:8], digits[:8])
	copy(text[8:], "…")
	return string(text[:])
}

// start_policy_hash_text_of_image gives the hash text of the module of the
// start policy of the boot image: the policy that a request of the rescue
// replaces before it starts.
start_policy_hash_text_of_image :: proc "contextless" () -> string {
	for &item in system.image_entries(image) {
		if system.name_of(item.name[:]) == START_POLICY_NAME {
			return start_policy_hash_text(item.hash)
		}
	}
	return "of no module"
}

// start_policy_launch starts the start policy with one list. A start that
// fails starts the rescue; a rescue that fails leaves the machine with no
// start policy.
start_policy_launch :: proc "contextless" (list: Start_Policy_List) {
	start_policy_list = list
	start_policy_process = nil
	if len(system.image_find(image, START_POLICY_NAME)) == 0 {
		if list == .Default {
			system.log(.Warning, "root: the start policy is absent from the boot image: the rescue start policy starts")
			start_policy_launch(.Rescue)
		} else {
			start_policy_none("the rescue start policy is absent from the boot image")
		}
		return
	}
	// The measure before Process_Start: an attestation sees each start
	// policy that ran, the rescue too.
	module_hash, list_hash: [32]u8
	for &item in system.image_entries(image) {
		if system.name_of(item.name[:]) == START_POLICY_NAME {
			module_hash = item.hash
		}
	}
	if list_entry := system.image_resource_find(image, START_POLICY_LIST_NAMES[list]); list_entry != nil {
		list_hash = list_entry.hash
	}
	// A start policy of the boot image starts unmeasured, with the line of
	// the cause: it is signed and measured with the system in PCR 11.
	_ = start_policy_measure(module_hash, list_hash, START_POLICY_LIST_WORDS[list])
	start_policy_from_disk = false
	start_policy_starting = true
	status := start(START_POLICY_NAME, principals.MACHINE)
	start_policy_starting = false
	if status == .Ok {
		start_policy_process = start_policy_running()
	}
	if start_policy_process == nil {
		if list == .Default {
			system.log(.Warning, "root: the start policy ", start_policy_hash_text_of_image(), " did not start, with the status ", status, ": the rescue start policy starts")
			start_policy_launch(.Rescue)
		} else {
			start_policy_none("the rescue start policy did not start")
		}
		return
	}
	start_policy_hash = start_policy_process.hash
	start_policy_stage = .Running
	start_policy_deadline = system.time() + START_POLICY_HANG_BOUND_MILLISECONDS
}

// start_policy_running gives the place of the start policy that runs.
start_policy_running :: proc "contextless" () -> ^Started {
	for &item in started {
		// A failed start policy whose stop this service asked can still run
		// past the bound of the stage Stopping: it is not the one that runs.
		if item.process != 0 && .Start_Policy in item.role.grants && !item.stop_asked_by_root_service {
			if state, _, _ := system.process_state(item.process); state != .Stopped {
				return &item
			}
		}
	}
	return nil
}

// start_policy_none ends the start with no start policy: the boot display
// shows the cause, and this service serves the root ring of each process
// that still runs, and starts nothing more by itself.
start_policy_none :: proc "contextless" (cause: string) {
	start_policy_stage = .No_Policy
	start_policy_process = nil
	start_policy_deadline = system.WAIT_FOREVER
	system.log(.Error, "root: no start policy at all: ", cause, "; this service serves the root ring of each process that runs, and starts nothing more")
	failure_show(cause, .Bad_State)
}

// start_policy_stopped is told of each process that stopped, before its
// place is freed. Any stop cause of the start policy before the machine is
// usable starts the rescue; the line gives the cause.
start_policy_stopped :: proc "contextless" (item: ^Started, cause: op.Stop_Cause, code: u32) {
	if item != start_policy_process {
		return
	}
	start_policy_process = nil
	hash := start_policy_hash_text(start_policy_hash)
	buffer: [64]u8
	stop_text := system.Writer{buffer = buffer[:]}
	system.stop_write(&stop_text, cause, code)
	switch start_policy_stage {
	case .None, .Stopping, .No_Policy:
		// The stop was asked by this service, or the policy was no longer
		// the one that it waits for.
	case .Running:
		if start_policy_list == .Rescue {
			system.log(.Error, "root: the rescue start policy ", hash, " stopped before the machine was usable: ", system.written(&stop_text))
			start_policy_none("the rescue start policy stopped before the machine was usable")
			return
		}
		system.log(.Warning, "root: the start policy ", hash, " stopped before the machine was usable: ", system.written(&stop_text), "; the rescue start policy starts")
		start_policy_rescue_begin()
	case .Usable:
		system.log(.Warning, "root: the start policy ", hash, " stopped: ", system.written(&stop_text), ", after the machine was usable: the processes that it asked for keep running")
	}
}

// start_policy_rescue_begin stops each process that the failed start
// policy asked for, so the rescue starts on a known state. The rescue
// starts at a pass of the loop where none of them is left.
start_policy_rescue_begin :: proc "contextless" () {
	start_policy_stage = .Stopping
	// A process that does not end its stop must not hold the machine with
	// no start policy: past the bound the rescue starts anyway, with a line.
	start_policy_deadline = system.time() + START_POLICY_HANG_BOUND_MILLISECONDS
	for &item in started {
		if item.process != 0 && (item.asked_by_start_policy || item.is_terminal && item.writer != nil && item.writer.asked_by_start_policy) {
			root_stop_ask(&item)
		}
	}
	if start_policy_process != nil {
		root_stop_ask(start_policy_process)
		start_policy_process = nil
	}
}

// root_stop_ask stops a process that this service chooses to stop, and
// marks it so: the reap then reads no fault and no absence in its stop.
// The stop of `unlock` is asked through its stage, so it does not count
// toward the bound of its restarts.
root_stop_ask :: proc "contextless" (item: ^Started) {
	item.stop_asked_by_root_service = true
	if !item.is_terminal && system.name_of(item.name[:]) == "unlock" {
		unlock_stop_ask()
	}
	system.call(.Process_Stop, u64(item.process), 0)
}

// start_policy_step runs after each reap: it starts the rescue when the
// processes of a failed start policy are gone, and at the hang bound of a
// start policy that never said that the machine is usable.
start_policy_step :: proc "contextless" () {
	// Before any start policy: the read of the choice of principal 0.
	start_policy_choice_step()
	switch start_policy_stage {
	case .None, .Usable, .No_Policy:
	case .Stopping:
		left := 0
		for &item in started {
			if item.process != 0 && (item.asked_by_start_policy || .Start_Policy in item.role.grants) {
				left += 1
			}
		}
		if left > 0 && system.time() < start_policy_deadline {
			return
		}
		if left > 0 {
			system.log(.Warning, "root: ", u64(left), " processes of the failed start policy did not stop within the hang bound of ", u64(START_POLICY_HANG_BOUND_MILLISECONDS), " ms: the rescue start policy starts beside them")
		}
		start_policy_launch(.Rescue)
	case .Running:
		if system.time() < start_policy_deadline {
			return
		}
		hash := start_policy_hash_text(start_policy_hash)
		if start_policy_list == .Rescue {
			system.log(.Error, "root: the rescue start policy ", hash, " sent no Machine_Usable within the hang bound of ", u64(START_POLICY_HANG_BOUND_MILLISECONDS), " ms")
			if start_policy_process != nil {
				root_stop_ask(start_policy_process)
			}
			start_policy_none("the rescue start policy sent no Machine_Usable within the hang bound")
			return
		}
		system.log(.Warning, "root: the start policy ", hash, " sent no Machine_Usable within the hang bound of ", u64(START_POLICY_HANG_BOUND_MILLISECONDS), " ms: the rescue start policy starts")
		start_policy_rescue_begin()
	}
}

// start_policy_wake gives the time at which the loop must run
// start_policy_step even with no event.
start_policy_wake :: proc "contextless" () -> u64 {
	wake := start_policy_stage == .Running || start_policy_stage == .Stopping ? start_policy_deadline : system.WAIT_FOREVER
	return min(wake, start_policy_choice_wake())
}

// start_policy_usable runs Machine_Usable: only from the start policy that
// runs, and once.
start_policy_usable :: proc "contextless" (sender: ^Started, values: ^[7]u64) -> system.Status {
	if status, refusal := start_policy_rules.usable_decision(sender == start_policy_process, start_policy_stage); status != .Ok {
		values^ = refusal
		return status
	}
	start_policy_stage = .Usable
	start_policy_deadline = system.WAIT_FOREVER
	// A measure, not a check: the pages that this service can still give,
	// now and at the lowest count that it read since its start.
	budget_pages_note()
	system.log(.Info, "root: the machine is usable, by the start policy ", start_policy_hash_text(start_policy_hash), " ", START_POLICY_LIST_WORDS[start_policy_list], ": the budget of this service holds ", budget_pages_now, " free pages, ", budget_pages_lowest, " at the lowest")
	return .Ok
}

// start_policy_start runs a Start from the start policy that runs. A part
// of the system starts by its own procedure, which only this service holds
// the handles of; each other name starts with the grants of its role. The
// completion has a handle of the process with the right Read, so its stop
// ends a wait of the start policy.
// written: the procedure wrote the error record of its refusal, and the
// dispatch must not write over it.
start_policy_start :: proc "contextless" (sender: ^Started, name: string, values: ^[7]u64, written: ^bool) -> system.Status {
	// The two processes of a test machine take the budget or the memory of
	// the machine, and the stop of shortage stops the machine: they start
	// only from the image of their test (start_policy_rules.start_refusal).
	// The error record of a refusal is start_policy_rules.start_record,
	// which root_command_answer writes.
	facts := start_policy_facts(sender, name)
	if refusal := start_policy_rules.start_refusal(facts); refusal != .Ok {
		values^ = start_policy_rules.start_record(refusal, facts)
		written^ = true
		return refusal
	}
	// A start policy from the disk has the bound of a start row on the
	// restarts of each name that it asks for: no loop of starts.
	restart_status, restart_record, counted := start_policy_rules.restart_check(&start_policy_name_counts, start_policy_from_disk, name)
	if restart_status != .Ok {
		values^ = restart_record
		written^ = true
		system.log(.Warning, "root: refused a start of ", system.Module_Name{name}, " by the start policy from the disk: past its ", u64(start_list.RESTART_LIMIT), " restarts, or past the ", u64(start_policy_rules.RESTARTED_NAME_CAPACITY), " names whose starts the root service counts, it stays stopped")
		return restart_status
	}
	status: system.Status
	switch name {
	case "input":
		status = input_start()
	case "compositor":
		status = compositor_start()
	case "shortage":
		status = shortage_start()
	case OPERATION_FUZZING_NAME:
		status = operation_fuzzing_start()
	case "settings":
		status = settings_boot_pass_start()
	case "unlock":
		status = unlock_start(.Unlock, "")
	case:
		// start refuses a part of the system with Bad_Operation.
		status = start(name, principals.MACHINE)
	}
	if status != .Ok {
		return status
	}
	if counted != nil {
		counted.starts += 1
	}
	slot := find_running(name)
	if slot == nil {
		slot = find(name)
	}
	if slot == nil {
		// The process ended before this answer, and its place is gone.
		return .Ok
	}
	slot.asked_by_start_policy = true
	given, give_status := system.give(sender.requests_memory, slot.process, {.Read})
	if give_status == .Ok {
		values[0] = u64(given)
	}
	return .Ok
}

// start_policy_facts reads the facts of a Start of a start policy from the
// state of this service, for start_policy_rules.
start_policy_facts :: proc "contextless" (sender: ^Started, name: string) -> start_policy_rules.Start_Facts {
	return {
		sender_runs               = sender == start_policy_process,
		name_runs                 = find_running(name) != nil,
		name_is_a_start_policy    = .Start_Policy in role_of(name).grants,
		name_is_of_a_test_machine = name == "shortage" || name == OPERATION_FUZZING_NAME,
		name_in_image             = len(system.image_find(image, name)) != 0,
	}
}

// find_running gives the process with a name that runs: a process that
// stopped keeps its place until the reap, and a start of its name again
// takes another place.
find_running :: proc "contextless" (name: string) -> ^Started {
	for &item in started {
		if item.process != 0 && !item.is_terminal && system.name_of(item.name[:]) == name {
			if state, _, _ := system.process_state(item.process); state != .Stopped {
				return &item
			}
		}
	}
	return nil
}
