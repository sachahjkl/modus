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
import "modus:contract/call_outcome"
import op "modus:contract/operation"
import rd "modus:contract/root_delegation"
import "modus:contract/root_ring"
import "modus:contract/start_list"
import "modus:contract/value_kinds"
import "internal:root/start_policy_rules"
import "modus:disk_process"
import "modus:pci"
import "modus:principals"
import "modus:system"

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
// answer bound of the services, so that only a start policy that hangs
// meets it, never a slow machine.
START_POLICY_HANG_BOUND_MILLISECONDS :: system.ANSWER_BOUND_MILLISECONDS

start_policy_stage: Start_Policy_Stage
start_policy_list: Start_Policy_List
start_policy_process: ^Started // The place of the start policy that runs. nil: none.
start_policy_hash: [32]u8 // The hash of the module of the last start policy that started, for the lines.
start_policy_deadline: u64 = system.WAIT_FOREVER // Running: the time of the hang bound.
// The start of the start policy: only it may take the name, as only
// unlock_start takes the name of unlock.
start_policy_starting: bool

// The wiring rows with audit terms of the list of the start policy that
// started: the collector of principal 0 keeps them, and this service, its
// starter, widens its budget for each (src/md/features/wide_grants.md, "The
// starter pays for the audits").
start_list_audits: u64

// The pages that the wiring rows of that list cost the start policy, as
// its header gives them: this service, its starter, adds them to its
// budget and carves its wiring budget from them (src/md/features/module_outputs.md,
// "The bounds of the wirings").
start_list_wiring_pages: u64

// start_list_facts_of reads the audits and the wiring pages of a list of the
// boot image. A list that is not whole has none: the start policy refuses it.
start_list_facts_of :: proc "contextless" (entry: ^info.Image_Entry) -> (audits: u64, wiring_pages: u64) {
	if !image_entry_give(entry) {
		return 0, 0
	}
	count, pages, ok := start_list.list_starter_facts(image[entry.offset:][:entry.size])
	if !ok {
		return 0, 0
	}
	return u64(count), pages
}

// The machine parts page: written once, before the start policy starts.
machine_parts_memory: system.Handle
machine_parts: start_list.Machine_Parts

// machine_parts_page_create checks each part of the machine that a start
// row can need, and writes the page. A part that this service cannot check
// is absent: the page never says that a part is present by default. The
// screen is the one test of the boot display (modus:screen_presence),
// so the page and the line of a machine with no screen agree. The PS/2
// controller is no part of the page: the input service reads its absence.
machine_parts_page_create :: proc "contextless" () {
	parts: start_list.Machine_Parts
	width, height: u32
	if !no_screen_at_the_start {
		parts += {.Screen}
		width, height = u32(screen.width), u32(screen.height)
	}
	// A device is a part when the devices service classified it with the
	// class of its place: a machine whose devices service did not classify
	// the bus has none of these parts (devices_delegation.odin).
	if bus_classified {
		classified_at := proc "contextless" (place: pci.Place, role: rd.Device_Class_Role) -> bool {
			device, found := classified_device_at(place)
			return found && device.role == role
		}
		if classified_at({device = pci.DATA_DISK_DEVICE}, .Block_Device) {
			parts += {.Data_Disk}
		}
		if classified_at(scratch_disk_place(), .Block_Device) {
			parts += {.Scratch_Disk}
		}
		if classified_at({device = pci.NETWORK_DEVICE}, .Network_Device) {
			parts += {.Network_Device}
		}
		if classified_at({device = pci.SOUND_DEVICE}, .Sound_Device) {
			parts += {.Sound_Device}
		}
		if classified_at({device = pci.ENTROPY_DEVICE}, .Entropy_Device) {
			parts += {.Entropy_Device}
		}
	}
	if trust_boot_report.trust.measure == u64(info.Measure_State.Measured) {
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
		system.log_fact(.Error, Machine_Parts_Page_Failed{status = status})
		machine_parts_memory = 0
		return
	}
	start_list.parts_page_write((^start_list.Machine_Parts_Page)(address), parts, width, height)
	// One fact for each part, so that a reader filters the parts by field.
	for part in start_list.Machine_Part {
		if part in parts {
			system.log_fact(.Info, Machine_Part_Present{machine_part = text_field(start_list.PART_NAMES[part], 24)})
		}
	}
	if parts == {} {
		system.log_fact(.Info, Machine_Parts_None{})
	}
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
		system.log_fact(.Warning, Start_Request_Refused{start_request = report.start_request, start_request_source = report.start_request_source})
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
// hash of the start policy that a rescue replaces: the chosen one, or the
// default one, which the boot image can lack.
start_policy_after_the_choice :: proc "contextless" (chosen: ^disk_process.Grant_Row) {
	replaced, replaced_found := start_policy_image_hash()
	if chosen != nil {
		replaced, replaced_found = chosen.hash, true
	}
	switch start_policy_request {
	case .Chosen:
		if chosen != nil {
			start_policy_chosen_load_begin(chosen)
			return
		}
		start_policy_launch(.Default)
	case .Rescue_By_Key:
		if replaced_found {
			system.log_fact(.Info, Rescue_By_Key{replaced_hash = value_kinds.Hash_Head_Field(replaced)})
		} else {
			system.log_fact(.Info, Rescue_By_Key_Of_No_Module{})
		}
		start_policy_launch(.Rescue)
	case .Rescue_By_Boot_Entry:
		if replaced_found {
			system.log_fact(.Info, Rescue_By_Boot_Entry{replaced_hash = value_kinds.Hash_Head_Field(replaced)})
		} else {
			system.log_fact(.Info, Rescue_By_Boot_Entry_Of_No_Module{})
		}
		start_policy_launch(.Rescue)
	case .Rescue_By_Refused_Record:
		if replaced_found {
			system.log_fact(.Warning, Rescue_By_Refused_Record{replaced_hash = value_kinds.Hash_Head_Field(replaced)})
		} else {
			system.log_fact(.Warning, Rescue_By_Refused_Record_Of_No_Module{})
		}
		start_policy_launch(.Rescue)
	}
}

// start_policy_image_hash gives the hash of the module of the start policy
// of the boot image: the policy that a request of the rescue replaces
// before it starts. found is false when the boot image has no such module.
start_policy_image_hash :: proc "contextless" () -> (hash: [32]u8, found: bool) {
	for &item in system.image_entries(image) {
		if is_role_holder(system.name_of(item.name[:]), .Start_Policy) {
			return item.hash, true
		}
	}
	return {}, false
}

// start_policy_launch starts the start policy with one list. A start that
// fails starts the rescue; a rescue that fails leaves the machine with no
// start policy.
start_policy_launch :: proc "contextless" (list: Start_Policy_List) {
	start_policy_list = list
	start_policy_process = nil
	policy_name := role_holder_name(.Start_Policy)
	if len(system.image_find(image, policy_name)) == 0 {
		if list == .Default {
			system.log_fact(.Warning, Start_Policy_Absent{})
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
		if is_role_holder(system.name_of(item.name[:]), .Start_Policy) {
			module_hash = item.hash
		}
	}
	if list_entry := system.image_resource_find(image, START_POLICY_LIST_NAMES[list]); list_entry != nil {
		list_hash = list_entry.hash
		start_list_audits, start_list_wiring_pages = start_list_facts_of(list_entry)
	}
	// A start policy of the boot image starts unmeasured, with the line of
	// the cause: it is signed and measured with the system in PCR 11.
	_ = start_policy_measure(module_hash, list_hash, START_POLICY_LIST_WORDS[list])
	start_policy_from_disk = false
	start_policy_starting = true
	outcome := start(role_holder_name(.Start_Policy), principals.MACHINE)
	start_policy_starting = false
	if outcome == .Succeeded {
		start_policy_process = start_policy_running()
	}
	if start_policy_process == nil {
		if list == .Default {
			if image_hash, image_found := start_policy_image_hash(); image_found {
				system.log_fact(.Warning, Start_Policy_Not_Started{start_policy_hash = value_kinds.Hash_Head_Field(image_hash), outcome = call_outcome.Call_Outcome_Word(outcome)})
			} else {
				system.log_fact(.Warning, Start_Policy_Not_Started_Of_No_Module{outcome = outcome})
			}
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
		if item.process != 0 && .Start_Policy in item.start_grant_set.grants && !item.stop_asked_by_root_service {
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
	system.log_fact(.Error, No_Start_Policy{failure_cause = text_field(cause, 72)})
	failure_show(cause, .Bad_State)
}

// start_policy_stopped is told of each process that stopped, before its
// place is freed. Any stop cause of the start policy starts the rescue,
// whatever its stop outcome: before the machine is usable, a policy that
// stopped did not make it usable; after, the rows that it asked for have
// no starter left. A stop of the rescue leaves no start policy. The line
// gives the cause and the outcome.
start_policy_stopped :: proc "contextless" (item: ^Started, cause: op.Stop_Cause, outcome: op.Stop_Outcome) {
	if item != start_policy_process {
		return
	}
	start_policy_process = nil
	hash := value_kinds.Hash_Head_Field(start_policy_hash)
	// A stop of itself has its outcome; another cause has none, as the line
	// of the stop of each process says.
	itself := cause == .Itself
	usable := start_policy_stage == .Usable
	switch start_policy_rules.stop_action(start_policy_stage, start_policy_list == .Rescue) {
	case .Nothing:
		// The stop was asked by this service, or the policy was no longer
		// the one that it waits for.
	case .No_Policy:
		switch {
		case usable && itself:
			system.log_fact(.Error, Rescue_Stopped_After_Usable{start_policy_hash = hash, cause = cause, outcome = outcome})
		case usable:
			system.log_fact(.Error, Rescue_Stopped_After_Usable_Without_Outcome{start_policy_hash = hash, cause = cause})
		case itself:
			system.log_fact(.Error, Rescue_Stopped_Before_Usable{start_policy_hash = hash, cause = cause, outcome = outcome})
		case:
			system.log_fact(.Error, Rescue_Stopped_Before_Usable_Without_Outcome{start_policy_hash = hash, cause = cause})
		}
		start_policy_none(usable ? "the rescue start policy stopped after the machine was usable" : "the rescue start policy stopped before the machine was usable")
	case .Rescue:
		// After Machine_Usable too: a needed row past its restart bound
		// stops the default start policy, and its rows must not run on
		// with no starter (src/md/features/supervision.md, "A holder that
		// stops in a loop, and the escalation").
		switch {
		case usable && itself:
			system.log_fact(.Warning, Start_Policy_Stopped_After_Usable{start_policy_hash = hash, cause = cause, outcome = outcome})
		case usable:
			system.log_fact(.Warning, Start_Policy_Stopped_After_Usable_Without_Outcome{start_policy_hash = hash, cause = cause})
		case itself:
			system.log_fact(.Warning, Start_Policy_Stopped_Before_Usable{start_policy_hash = hash, cause = cause, outcome = outcome})
		case:
			system.log_fact(.Warning, Start_Policy_Stopped_Before_Usable_Without_Outcome{start_policy_hash = hash, cause = cause})
		}
		start_policy_rescue_begin()
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
	started_process_stop(item)
}

// start_policy_step runs after each reap: it starts the rescue when the
// processes of a failed start policy are gone, and at the hang bound of a
// start policy that never said that the machine is usable.
start_policy_step :: proc "contextless" () {
	// Before any start policy: the read of the choice of principal 0, then
	// the read of its plan.
	start_policy_choice_step()
	plan_at_start_step()
	switch start_policy_stage {
	case .None, .Usable, .No_Policy:
	case .Stopping:
		left := 0
		for &item in started {
			if item.process != 0 && (item.asked_by_start_policy || .Start_Policy in item.start_grant_set.grants) {
				left += 1
			}
		}
		if left > 0 && system.time() < start_policy_deadline {
			return
		}
		if left > 0 {
			system.log_fact(.Warning, Start_Policy_Processes_Late{left_processes = u64(left), bound = START_POLICY_HANG_BOUND_MILLISECONDS})
		}
		start_policy_launch(.Rescue)
	case .Running:
		if system.time() < start_policy_deadline {
			return
		}
		hash := value_kinds.Hash_Head_Field(start_policy_hash)
		if start_policy_list == .Rescue {
			system.log_fact(.Error, Rescue_Not_Usable_In_Time{bound = START_POLICY_HANG_BOUND_MILLISECONDS, start_policy_hash = hash})
			if start_policy_process != nil {
				root_stop_ask(start_policy_process)
			}
			start_policy_none("the rescue start policy sent no Machine_Usable within the hang bound")
			return
		}
		system.log_fact(.Warning, Start_Policy_Not_Usable_In_Time{bound = START_POLICY_HANG_BOUND_MILLISECONDS, start_policy_hash = hash})
		start_policy_rescue_begin()
	}
}

// start_policy_wake gives the time at which the loop must run
// start_policy_step even with no event.
start_policy_wake :: proc "contextless" () -> u64 {
	wake := start_policy_stage == .Running || start_policy_stage == .Stopping ? start_policy_deadline : system.WAIT_FOREVER
	return min(wake, start_policy_choice_wake(), plan_at_start_wake())
}

// start_policy_usable runs Machine_Usable: only from the start policy that
// runs, and once.
start_policy_usable :: proc "contextless" (sender: ^Started, values: ^[7]u64) -> call_outcome.Call_Outcome {
	if outcome, refusal := start_policy_rules.usable_decision(sender == start_policy_process, start_policy_stage); outcome != .Succeeded {
		values^ = refusal
		return outcome
	}
	start_policy_stage = .Usable
	start_policy_deadline = system.WAIT_FOREVER
	// A measure, not a check: the pages that this service can still give,
	// now and at the lowest count that it read since its start.
	budget_pages_note()
	system.log_fact(.Info, Machine_Usable{free_pages = budget_pages_now, lowest_free_pages = budget_pages_lowest, start_policy_hash = value_kinds.Hash_Head_Field(start_policy_hash), start_policy_words = text_field(START_POLICY_LIST_WORDS[start_policy_list], 40)})
	return .Succeeded
}

// start_policy_start runs a Start from the start policy that runs. A part
// of the system starts by its own procedure, which only this service holds
// the handles of; each other name starts with the grants of its start grant set, and
// with the wiring list of the wiring rows of its start list
// (src/md/features/module_outputs.md, "The wiring rows of a start list").
// The completion has a handle of the process with the rights Read and
// Give: its stop ends a wait of the start policy, and the start policy
// lends it as the reader of a later wiring row. Each refusal writes its
// outcome and its error record in values.
start_policy_start :: proc "contextless" (sender: ^Started, tag: u32, name: string, list: root_ring.Start_Wiring_List, values: ^[7]u64, held: ^bool, screen_of_memory: [2]u32 = {}) -> call_outcome.Call_Outcome {
	kind := u32(root_ring.Root_Command.Start)
	// The checks before any start (start_policy_rules.start_step, with its
	// host tests): a list for a part of the system, whose procedure takes
	// none; a start policy, a name that runs, and a process of a test
	// machine that its image does not hold, which takes the machine; and
	// the bound of a start row on the restarts of a start policy from the
	// disk. Each refusal of a Start with a list closes its lent numbers.
	listed := list == .In_The_List_Page
	// A row that names a role starts the module that holds it: the start
	// list says "display", never the module of one holder.
	module_name, has_holder := role_target_resolve_strict(name)
	if !has_holder {
		if listed {
			lent_handles_close(sender)
		}
		return root_ring.refuse(values, .Nothing_Has_That_Name, kind, .Absent, .None, 1)
	}
	facts := start_policy_facts(sender, module_name)
	step := start_policy_rules.start_step(listed, facts, &start_policy_name_counts, start_policy_from_disk, name)
	if step.outcome != .Succeeded {
		if step.lent_close {
			lent_handles_close(sender)
		}
		values^ = step.refusal
		if step.outcome == .Budget_Or_Capacity_Exhausted {
			system.log_fact(.Warning, Start_Policy_Restart_Refused{restart_limit = u64(start_list.RESTART_LIMIT), counted_names = u64(start_policy_rules.RESTARTED_NAME_CAPACITY), refused_process = module_name_field(name)})
		}
		return step.outcome
	}
	// The procedures of the parts of the system start each one through the
	// kernel: their status is the status of a kernel operation.
	status: system.Status
	started_place: ^Started
	switch start_list.root_procedure_of(name) {
	case .Input:
		status = input_start()
	case .Display:
		status = display_holder_start(screen_of_memory)
	case .Shortage:
		status = shortage_start()
	case .Operation_Fuzzing:
		status = operation_fuzzing_start()
	case .Settings:
		if outcome := settings_boot_pass_start(values); outcome != .Succeeded {
			return outcome
		}
	case .Unlock:
		if outcome := unlock_start(.Unlock, "", refusal = values); outcome != .Succeeded {
			return outcome
		}
	case .None:
		if listed {
			outcome, is_held := start_with_wiring_begin(sender, tag, module_name, principals.MACHINE, .Process_Handle, true, step.counted, values)
			held^ = is_held
			return outcome
		}
		// start refuses a part of the system with Reserved.
		if outcome := start(module_name, principals.MACHINE, sender, nil, &started_place, values); outcome != .Succeeded {
			return outcome
		}
	}
	if status != .Ok {
		return kernel_refused(values, kind, status)
	}
	if step.counted != nil {
		step.counted.starts += 1
	}
	slot := started_place
	if slot == nil {
		slot = find_running(module_name)
	}
	if slot == nil {
		slot = find(module_name)
	}
	if slot == nil {
		// The process ended before this answer, and its place is gone.
		return .Succeeded
	}
	slot.asked_by_start_policy = true
	given, give_status := start_process_handle_give(sender, slot)
	if give_status == .Ok {
		values[0] = given
	}
	return .Succeeded
}

// start_policy_facts reads the facts of a Start of a start policy from the
// state of this service, for start_policy_rules.
start_policy_facts :: proc "contextless" (sender: ^Started, name: string) -> start_policy_rules.Start_Facts {
	return {
		sender_runs               = sender == start_policy_process,
		name_runs                 = find_running(name) != nil,
		name_is_a_start_policy    = .Start_Policy in start_grant_set_of(name).grants,
		name_is_of_a_test_machine = start_list.root_procedure_of(name) == .Shortage || start_list.root_procedure_of(name) == .Operation_Fuzzing,
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
