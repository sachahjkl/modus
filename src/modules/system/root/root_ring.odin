package root

// The root ring in this service: the dispatch of each command that a
// process writes on its root ring (modus:contract/root_ring;
// src/md/api/root_ring.md).
//
// Each record goes through three steps, in this order, and a step that
// refuses ends it with its own error record. The first two are the pure
// decision root_ring.dispatch_decide, which a host test and a fuzz target
// of the tool call:
//
// 1. The border: command_of_word reads the kind. A word that names no
//    command, and None, get Operation_Unsupported with the record
//    `Unsupported`, and nothing runs.
// 2. The sender: the table root_ring.ROOT_COMMAND_SENDERS, with the start
//    grants that the process received at its start (Started.start_grant_set), and for
//    a Connect the services of its start grant set. A refusal gets
//    Grant_Or_Right_Missing with `No_Grant`, before any other check, so a
//    process learns nothing of a command that it cannot send.
// 3. The command: one case of a whole switch. The procedure that refuses
//    names the outcome and writes the error record at the place where it
//    refuses (root_ring.refuse): the completion holds them as they are, and
//    no status is mapped to an outcome.

import "base:intrinsics"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "internal:root/start_policy_rules"
import "modus:principals"
import "modus:system"

// The answer of a command of the root ring: the completion that the sender
// receives, or none yet.
Command_Answer :: struct {
	outcome: call_outcome.Call_Outcome,
	values:  [7]u64, // The values of the completion; for a refusal, its error record.
	// The completion comes when the work ends (a load from the disk, a
	// change of a passphrase): the loop goes on meanwhile, and the work
	// sends it.
	held:    bool,
}

// root_ring_serve answers each command that a process wrote on its root
// ring since the last pass.
root_ring_serve :: proc "contextless" (item: ^Started) {
	for {
		record := system.receive(&item.requests.commands) or_break
		answer := root_command_answer(item, &record)
		tag := record.tag
		// Machine_Key and Principal_Unlock carry a key in their values: no
		// copy of a record stays in this frame.
		intrinsics.mem_zero_volatile(&record, size_of(record))
		if answer.held {
			continue
		}
		system.send(&item.requests.completions, ring.Record{kind = u32(answer.outcome), tag = tag, values = answer.values})
	}
}

// kernel_refused writes the record Refused of a kernel operation that this
// service ran for a command and that the kernel refused, with the status
// in found, and gives the outcome of a refusal on the objects of this
// service (system.outcome_of_own_status): the border of the kernel until
// the kernel gives the call outcome itself.
kernel_refused :: proc "contextless" (values: ^[7]u64, command: u32, status: system.Status) -> call_outcome.Call_Outcome {
	return root_ring.refuse(values, system.outcome_of_own_status(status), command, .Refused, .None, 0, 0, 0, i64(status))
}

// needed_service_failed gives the end of a command whose service, which the
// command starts on demand, did not start: the party that the command needs
// failed, and the record of that start stays in values, explained under
// Callee_Unavailable. A shared service that starts for the command, and a
// refusal after it, change no state of the sender (src/md/api/call_outcome.md,
// "A service on demand").
needed_service_failed :: proc "contextless" (values: ^[7]u64) -> call_outcome.Call_Outcome {
	values^ = errors.completion_values(call_outcome.record_explained(.Callee_Unavailable, errors.completion_record(values^)))
	return .Callee_Unavailable
}

// changed_then_refused gives the end of a command that changed what its
// sender can see, then refused with the record in values: the rule of
// weakening (call_outcome.outcome_passed_on), with the record explained
// under the outcome. A refusal becomes Stopped_After_A_Partial_Change, and
// a call in doubt stays in doubt.
changed_then_refused :: proc "contextless" (values: ^[7]u64, refused: call_outcome.Call_Outcome) -> call_outcome.Call_Outcome {
	outcome := call_outcome.outcome_passed_on(refused, changed_before = true)
	values^ = errors.completion_values(call_outcome.record_explained(outcome, errors.completion_record(values^)))
	return outcome
}

// root_command_answer runs the three steps of one record: the border and
// the sender, which root_ring.dispatch_decide decides from the start grant set that
// the process received at its start and never from its name (a disk
// process has the nickname that it chose), then the command.
root_command_answer :: proc "contextless" (item: ^Started, record: ^ring.Record) -> (answer: Command_Answer) {
	// The values of a key are no name: they are not unpacked, so no copy of
	// the key stays in the name bytes of this frame.
	name_bytes: system.Name
	if record.kind != u32(root_ring.Root_Command.Machine_Key) && record.kind != u32(root_ring.Root_Command.Principal_Unlock) {
		name_bytes = system.name_unpack({record.values[0], record.values[1], record.values[2], record.values[3]})
	}
	raw_name := system.name_of(name_bytes[:])
	name := raw_name
	resolved_ok := true
	if record.kind == u32(root_ring.Root_Command.Connect) || record.kind == u32(root_ring.Root_Command.Disconnect) {
		name, resolved_ok = role_target_resolve_strict(raw_name)
	}
	// The sender first: a name that names no service is said only to a
	// sender that may send the command, so a process learns nothing of a
	// command that it cannot send. A name that resolves to nothing is on no
	// list of a start grant set.
	listed := resolved_ok && start_grant_set_may_connect(&item.start_grant_set, name)
	decision := root_ring.dispatch_decide(record.kind, item.start_grant_set.grants, listed)
	switch decision.step {
	case .Border, .Sender:
		return {outcome = decision.outcome, values = decision.refusal}
	case .Command:
	}
	if !resolved_ok {
		answer.outcome = root_ring.refuse(&answer.values, .Nothing_Has_That_Name, record.kind, .Absent, .Services, 1)
		return answer
	}
	return root_command_run(item, decision.command, record, name)
}

// root_command_run runs one command that its sender can send. name is the
// name of values[0..4], for the commands that carry one.
root_command_run :: proc "contextless" (item: ^Started, command: root_ring.Root_Command, record_place: ^ring.Record, name: string) -> (answer: Command_Answer) {
	// A copy for the commands that read the record by value. A key command
	// reads the record of the caller through the pointer, never this copy.
	record: ring.Record
	if command != .Machine_Key && command != .Principal_Unlock {
		record = record_place^
	}
	defer intrinsics.mem_zero_volatile(&record, size_of(record))
	kind := u32(command)
	answer.outcome = .Operation_Unsupported
	switch command {
	case .None:
		// The border refuses it; the case keeps the switch whole.
	case .Start:
		// The start policy starts the parts of the system too, and gets a
		// handle of each process (start_policy.odin). A process that a
		// process starts belongs to the session of the process that asks.
		answer.outcome = start_command(item, record, name, &answer.values, &answer.held)
	case .Stop:
		answer.outcome = stop_command(item, name, &answer.values)
	case .Connect:
		answer.outcome = root_connect(item, record, name, &answer.values)
	case .Disconnect:
		// The connection of the history is not ended by the name of its
		// service: the process keeps its history when it ends its calls to
		// the storage service.
		answer.outcome = root_ring.refuse(&answer.values, .Nothing_Has_That_Name, kind, .Absent, .Connections, 1)
		for &connection in connections {
			// values[4]: the row of the client table that the connection is
			// for, as Connect named it; 0 for none.
			if connection.caller == item && !connection.history && connection.client.place == int(min(record.values[4], u64(max(int)))) && system.name_of(connection.service.name[:]) == name {
				disconnect(&connection)
				answer.outcome, answer.values = .Succeeded, {}
			}
		}
	case .Grants:
		answer.outcome = root_ring.refuse(&answer.values, .Nothing_Has_That_Name, kind, .Absent, .Processes, 1)
		if other := find(name); other != nil {
			packed := system.name_pack(principal_name(other.principal))
			answer.values = {transmute(u64)other.granted, transmute(u64)other.revoked, other.principal, packed[0], packed[1], packed[2], packed[3]}
			answer.outcome = .Succeeded
		}
	case .Revoke:
		answer.outcome, answer.held = revoke(item, record.tag, name, record.values[4], &answer.values)
	case .Replace:
		answer.outcome = replace(item, name, record.values[4], &answer.values)
	case .Connect_History:
		answer.outcome = .Grant_Or_Right_Missing
		answer.values = root_ring.sender_refusal(.Connect_History)
		if .History_Store in item.start_grant_set.grants && .History not_in item.revoked && is_role_holder(name, .Storage) {
			answer.values = {}
			answer.outcome = connect(item, role_holder_name(.Storage), &answer.values, history = true)
		}
	case .Principal_Create:
		answer.outcome = principal_create(name, &answer.values)
	case .Principal_Lock:
		answer.outcome = principal_lock(&answer.values)
	case .Principals:
		answer.outcome = principal_read(record.values[4], &answer.values)
	case .Principal_Record:
		answer.outcome = principal_record(record.values, &answer.values)
	case .Principal_Identifier:
		answer.outcome = principal_identifier(record.values, &answer.values)
	case .Principal_Storage_Key:
		answer.outcome = principal_storage_key(&record_place.values, &answer.values)
		key_ring_erase(&item.requests.commands)
	case .Principal_Unlock:
		answer.outcome = principal_unlock(&record_place.values, &answer.values)
		key_ring_erase(&item.requests.commands)
	case .Debug:
		answer.outcome = debug(item, name, record.values[4], record.values[5] != 0, &answer.values)
	case .Palette_Provide:
		answer.outcome = palette_provide(item, &answer.values)
	case .Start_From_Disk:
		// The completion of a load from the disk comes when the load ends.
		answer.outcome, answer.held = disk_start_begin(item, record, &answer.values)
	case .Disk_Grant:
		answer.outcome = disk_grant_change(item, record, &answer.values)
	case .Nickname_Move:
		answer.outcome = nickname_move(item, record, &answer.values)
	case .Machine_Passphrase:
		answer.outcome = machine_passphrase_ask(&answer.values)
	case .Machine_Key:
		// Its values hold a key where a name would be: the record of a
		// refusal names its cause only.
		answer.outcome = machine_key_take(&record_place.values, &answer.values)
		key_ring_erase(&item.requests.commands)
	case .Disk_Grant_Persistence:
		answer.outcome = disk_grant_persistence(item, record, &answer.values)
	case .Debug_Store:
		answer.outcome = debug_store_open(item, name, record.values[4], record.values[5] != 0, record.values[6] != 0, &answer.values)
	case .Machine_Seal:
		answer.outcome = machine_seal_ask(&answer.values)
	case .Principal_Change:
		// The completion comes when the change ends.
		answer.outcome, answer.held = principal_change(item, record.tag, record.values[4], &answer.values)
	case .Principal_Change_End:
		answer.outcome = principal_change_end(record.values, &answer.values)
	case .Remote_Client:
		answer.outcome = remote_client_command(item, record, &answer.values)
	case .Machine_Usable:
		answer.outcome = start_policy_usable(item, &answer.values)
	case .Start_Policy_Choice:
		answer.outcome = start_policy_choice_command(item, record, &answer.values)
	case .Wire:
		answer.outcome, answer.held = wire_begin(item, record, &answer.values)
	case .Start_Edit:
		answer.outcome = start_edit_command(item, record, name, &answer.values)
	case .Debug_Start:
		answer.outcome = debug_start(item, name, record.values, &answer.values)
	case .Plan_Roles:
		answer.outcome = plan_roles_command(item, record.values, &answer.values)
	case .Screen_Budget:
		answer.outcome = screen_budget_command(item, record, &answer.values) // screen_budgets.odin
	case .Wide_Grant_Ask:
		answer.outcome = wide_grant_ask(item, record, &answer.values)
	case .Wide_Grant_Proof:
		answer.outcome = wide_grant_proof(item, record, &answer.values)
	case .Wide_Grant_End:
		answer.outcome = wide_grant_end_command(item, record, &answer.values)
	case .Wide_Grant_Agent_Ask:
		answer.outcome = wide_grant_agent_ask(item, record, &answer.values)
	case .Wide_Grant_Second_Connection:
		answer.outcome = wide_grant_second_connection(item, record, &answer.values)
	}
	return answer
}

// start_command runs Start: the border of values[4..6], the start with its
// wiring list, and the answer that values[5] asks for. The start policy
// starts the parts of the system too, and gets a handle of each process
// (start_policy.odin), with the wiring list of the wiring rows of its
// start list.
start_command :: proc "contextless" (item: ^Started, record: ring.Record, name: string, values: ^[7]u64, held: ^bool) -> call_outcome.Call_Outcome {
	command := root_ring.Root_Command.Start
	list, list_ok := root_ring.start_wiring_list_of_word(record.values[4])
	answer, answer_ok := root_ring.start_answer_of_word(record.values[5])
	// The size of a screen of memory: only from a start policy, only for
	// the holder of Display, and only on a machine with no screen
	// (src/md/features/screen_of_memory.md).
	memory_width, memory_height, memory_ok := start_policy_rules.screen_of_memory_of_start(record.values[6], .Start_Policy in item.start_grant_set.grants, name, !no_screen_at_the_start)
	refusal: [7]u64
	switch {
	case !list_ok:
		refusal = root_ring.word_refusal(command, 2, record.values[4], u64(max(root_ring.Start_Wiring_List)))
	case !answer_ok:
		refusal = root_ring.word_refusal(command, 3, record.values[5], u64(max(root_ring.Start_Answer)))
	case !memory_ok:
		refusal = root_ring.word_refusal(command, 4, record.values[6], 0)
	}
	if refusal != ([7]u64{}) {
		// A refused Start keeps none of the handles that its list lent.
		lent_handles_close(item)
		values^ = refusal
		return .Argument_Refused
	}
	if .Start_Policy in item.start_grant_set.grants {
		return start_policy_start(item, record.tag, name, list, values, held, {memory_width, memory_height})
	}
	// A process that a process starts belongs to the session of the
	// process that asks, and the asker of its start is that process.
	started_place: ^Started
	switch list {
	case .None:
		// The refusal of this start, or of a start that it made first,
		// writes its outcome and its record.
		outcome := start(name, item.principal, item, nil, &started_place, values)
		if outcome == .Succeeded && answer == .Process_Handle && started_place != nil {
			values[0], _ = start_process_handle_give(item, started_place)
		}
		return outcome
	case .In_The_List_Page:
	}
	outcome, is_held := start_with_wiring_begin(item, record.tag, name, item.principal, answer, false, nil, values)
	held^ = is_held
	return outcome
}

// stop_command runs Stop. The compositor and a terminal are not processes
// that the console stops, and the start policy stops only a process that it
// asked for: a start policy learns nothing of a process that it did not
// ask for, so each of its refusals is the one record Absent.
stop_command :: proc "contextless" (item: ^Started, name: string, values: ^[7]u64) -> call_outcome.Call_Outcome {
	kind := u32(root_ring.Root_Command.Stop)
	for &other in started {
		if .Start_Policy in item.start_grant_set.grants && !other.asked_by_start_policy {
			continue
		}
		if other.process != 0 && other.process != display_holder && !other.is_terminal && system.name_of(other.name[:]) == name {
			started_process_stop(&other)
			return .Succeeded
		}
	}
	if .Start_Policy in item.start_grant_set.grants {
		values^ = start_policy_rules.stop_record()
		return .Nothing_Has_That_Name
	}
	if find(name) == nil {
		return root_ring.refuse(values, .Nothing_Has_That_Name, kind, .Absent, .Processes, 1)
	}
	// The holder of Display, or a terminal, has the name.
	return root_ring.refuse(values, .Grant_Or_Right_Missing, kind, .Reserved, .None, 1)
}

// start_process_handle_give gives the asker of a start the handle of the
// process with the rights Read and Give, through its root ring: the handle
// that a Wire names, whose stop ends a wait of the asker, and that a start
// policy lends to a list as the reader of a wiring row.
start_process_handle_give :: proc "contextless" (asker: ^Started, process: ^Started) -> (u64, system.Status) {
	// Give, so that the asker can lend the handle back through its root
	// ring, where Wire names the process as a Started end. A copy carries
	// Read and Give at most, so it stops and maps nothing, and the
	// revocation of this service reaches each copy.
	given, status := system.give(asker.requests_memory, process.process, {.Read, .Give})
	if status != .Ok {
		return 0, status
	}
	return u64(given), .Ok
}

// root_connect runs Connect. The process of the client table connects for
// one of its rows, and for no other principal; its check writes the record
// of its refusal, and connect writes the record of each refusal after it.
root_connect :: proc "contextless" (item: ^Started, record: ring.Record, name: string, values: ^[7]u64) -> call_outcome.Call_Outcome {
	if .Remote_Clients in item.start_grant_set.grants || record.values[4] != 0 {
		client, outcome := client_grant_of(item, record.values[4], record.values[5], values)
		if outcome != .Succeeded {
			return outcome
		}
		return connect(item, name, values, client = client)
	}
	return connect(item, name, values)
}

// edit_store_limit gives the block limit to use when opening a store for
// `edit(store, name)`: the limit of the matching start grant set when the
// store belongs to a known module, HISTORY_STORE_LIMIT for a history
// store, or edit's own store block limit for any other store name.
edit_store_limit :: proc "contextless" (store_name: string) -> u64 {
	// Strip optional ".principal.<number>" suffix to match the module row.
	base := store_name
	marker := ".principal."
	for index := 0; index + len(marker) < len(store_name); index += 1 {
		if store_name[index:index + len(marker)] == marker {
			base = store_name[:index]
			break
		}
	}
	suffix := ".history"
	if len(base) > len(suffix) && base[len(base) - len(suffix):] == suffix {
		return HISTORY_STORE_LIMIT
	}
	row := start_grant_set_of(base)
	if .Store in row.grants {
		return start_grant_set_store_blocks(&row)
	}
	edit_row := start_grant_set_of("edit")
	return start_grant_set_store_blocks(&edit_row)
}

// start_edit_command runs Start_Edit: starts `edit` connected to a store
// of the principal of the caller, editing the named object path.
start_edit_command :: proc "contextless" (item: ^Started, record: ring.Record, store_name: string, values: ^[7]u64) -> call_outcome.Call_Outcome {
	command := u32(root_ring.Root_Command.Start_Edit)
	path_handle := system.Handle(record.values[4])
	path_count := record.values[5]
	kind, rights, through := system.handle_state(path_handle, item.requests_memory)
	defer if through {
		system.close(path_handle)
	}
	// The caller must act for its principal to reach another store.
	if .Acts_For_Principal not_in item.start_grant_set.grants || .Acts_For_Principal in item.revoked {
		return root_ring.refuse(values, .Grant_Or_Right_Missing, command, .No_Grant, .Acts_For_Principal, 1)
	}
	if record.values[6] != 0 {
		values^ = root_ring.word_refusal(.Start_Edit, 3, record.values[6], 0)
		return .Argument_Refused
	}
	store_refusal, store_offset := root_ring.edit_store_validate(store_name)
	switch store_refusal {
	case .None:
	case .Empty:
		return root_ring.refuse(values, .Argument_Refused, command, .Empty, .Bytes, 1, 0, root_ring.EDIT_TARGET_STORE_LIMIT)
	case .Too_Long:
		return root_ring.refuse(values, .Argument_Refused, command, .Too_Long, .Bytes, 1, i64(len(store_name)), root_ring.EDIT_TARGET_STORE_LIMIT)
	case .Bad_Byte:
		return root_ring.refuse(values, .Argument_Refused, command, .Bad_Byte, .Bytes, 1, i64(store_offset), 0, i64(store_name[store_offset]))
	}
	// Principal isolation: a caller for principal N opens stores of principal N only.
	if principals.store_name_principal(store_name) != item.principal {
		return root_ring.refuse(values, .Grant_Or_Right_Missing, command, .No_Grant, .Acts_For_Principal, 1)
	}
	if !through || kind != .Memory || .Read not_in rights {
		return root_ring.refuse(values, .Argument_Refused, command, .Bad_Value, .Objects, 2)
	}
	if path_count == 0 {
		return root_ring.refuse(values, .Argument_Refused, command, .Empty, .Bytes, 2, 0, root_ring.EDIT_TARGET_PATH_LIMIT)
	}
	if path_count > root_ring.EDIT_TARGET_PATH_LIMIT {
		return root_ring.refuse(values, .Argument_Refused, command, .Too_Long, .Bytes, 2, i64(min(path_count, u64(max(i64)))), root_ring.EDIT_TARGET_PATH_LIMIT)
	}
	pages, size_status := system.memory_size(path_handle)
	if size_status != .Ok || pages * system.PAGE_SIZE < path_count {
		return root_ring.refuse(values, .Argument_Refused, command, .Too_Long, .Bytes, 2, i64(path_count))
	}
	mapped, map_status := system.memory_map(path_handle, {})
	if map_status != .Ok {
		return kernel_refused(values, command, map_status)
	}
	path_bytes: [root_ring.EDIT_TARGET_PATH_LIMIT]u8
	intrinsics.mem_copy_non_overlapping(&path_bytes[0], mapped, int(path_count))
	system.memory_unmap(mapped)
	path := string(path_bytes[:int(path_count)])
	path_refusal, path_offset := root_ring.edit_path_validate(path)
	switch path_refusal {
	case .None:
	case .Empty:
		return root_ring.refuse(values, .Argument_Refused, command, .Empty, .Bytes, 2, 0, root_ring.EDIT_TARGET_PATH_LIMIT)
	case .Too_Long:
		return root_ring.refuse(values, .Argument_Refused, command, .Too_Long, .Bytes, 2, i64(len(path)), root_ring.EDIT_TARGET_PATH_LIMIT)
	case .Too_Deep:
		return root_ring.refuse(values, .Argument_Refused, command, .Too_Long, .Objects, 2, i64(path_offset))
	case .Bad_Segment:
		found := path_offset < len(path) ? i64(path[path_offset]) : 0
		return root_ring.refuse(values, .Argument_Refused, command, .Bad_Byte, .Bytes, 2, i64(path_offset), 0, found)
	}
	target_page, page_status := system.memory_create(1)
	if page_status != .Ok {
		return kernel_refused(values, command, page_status)
	}
	defer system.close(target_page)
	target_address, target_map_status := system.memory_map(target_page)
	if target_map_status != .Ok {
		return kernel_refused(values, command, target_map_status)
	}
	target := (^root_ring.Edit_Target)(target_address)
	target^ = {}
	target.store_length = u32(len(store_name))
	target.path_length = u32(len(path))
	copy(target.store[:], store_name)
	copy(target.path[:], path)
	system.memory_unmap(target_address)
	return start("edit", item.principal, item, nil, nil, values, store_override = store_name, store_limit_override = edit_store_limit(store_name), edit_target_page = target_page)
}
