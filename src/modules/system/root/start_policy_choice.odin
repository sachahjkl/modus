package root

// The choice of a start policy from the disk by principal 0
// (src/md/features/start_policy.md, "A start policy from the disk").
//
// The choice is one row of the disk grant table of principal 0, with the
// disk grant Start_Policy (modus:support/disk_process). Principal 0 makes it
// with the command Start_Policy_Choice; it takes effect at the next start.
// At that start this service reads it before any start policy runs: it
// starts `unlock` with no window, which has the TPM release the machine
// key, then reads the table (the read of the choice before the start
// policy). It then loads the
// module file of the row from the store module_files, checks its hash,
// measures it into PCR 12, and starts it with the grant Start_Policy only.
// Each refusal on that way starts the rescue start policy, with its line.

import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:contract/errors"
import "modus:contract/start_list"
import "modus:private/root/start_policy_rules"
import "modus:support/disk_process"
import "modus:support/principals"
import "modus:support/random"
import "modus:support/storage"
import "modus:support/system"

// What the read of the choice waits for, before any start policy runs.
Start_Policy_Choice_Stage :: enum u8 {
	Done, // No read runs: a start policy started, or will start now.
	Machine_Key, // The run of `unlock` with no window, until its stop.
	// That run passed the hang bound and its stop is asked: the read waits
	// for its reap, within a second hang bound.
	Machine_Key_Stopping,
	Table, // The read of the disk grant table of principal 0.
	Load, // The load of the chosen module file from the store (disk_processes.odin).
}

start_policy_choice_stage: Start_Policy_Choice_Stage
start_policy_choice_deadline: u64 = system.WAIT_FOREVER

// The start policy that runs came from the disk: the root service bounds
// the restarts of the names that it asks for.
start_policy_from_disk: bool

// The nickname of the chosen start policy, for the lines after its load.
start_policy_chosen_nickname: [disk_process.NAME_LIMIT]u8
start_policy_chosen_nickname_length: int

// The starts of each name that a start policy from the disk asked for
// (start_policy_rules.restart_check).
start_policy_name_counts: start_policy_rules.Name_Counts

// start_policy_choice_read_begin starts the read of the choice of principal
// 0. A machine with no TPM service or no data disk has no machine key that
// opens with no passphrase: no choice can be kept there, and the start
// policy of the boot image starts at once.
start_policy_choice_read_begin :: proc "contextless" () {
	if tpm_ring == 0 || tpm_process == nil {
		system.log(.Info, "root: no choice of a start policy is read: no TPM service runs, so no machine key opens with no passphrase")
		start_policy_choice_end()
		return
	}
	if .Data_Disk not_in machine_parts {
		system.log(.Info, "root: no choice of a start policy is read: the machine has no data disk")
		start_policy_choice_end()
		return
	}
	show("the root service reads the choice of principal 0", .Running, .Root)
	if status := unlock_start(.Machine_Key_Without_Window, ""); status != .Ok {
		system.log(.Warning, "root: no choice of a start policy is read: unlock did not start, with the status ", status)
		start_policy_choice_end()
		return
	}
	system.log(.Info, "root: unlock reads the machine key with no window, before the start policy: the choice of principal 0 is in its disk grant table")
	start_policy_choice_stage = .Machine_Key
	start_policy_choice_deadline = system.time() + START_POLICY_HANG_BOUND_MILLISECONDS
}

// start_policy_choice_step runs after each reap: the stop of `unlock`, then
// the end of the read of the table, each within the hang bound.
start_policy_choice_step :: proc "contextless" () {
	switch start_policy_choice_stage {
	case .Done, .Load:
		// The load ends in disk_load_end, which calls
		// start_policy_chosen_load_ended.
	case .Machine_Key:
		if unlock_run.stage == .Stopped {
			start_policy_choice_stage = .Table
			start_policy_choice_deadline = system.time() + START_POLICY_HANG_BOUND_MILLISECONDS
			start_policy_choice_table_check()
			return
		}
		if system.time() >= start_policy_choice_deadline {
			system.log(.Warning, "root: unlock gave no machine key within the hang bound of ", u64(START_POLICY_HANG_BOUND_MILLISECONDS), " ms: the choice of principal 0 is not read, and unlock is stopped")
			if running := find("unlock"); running != nil {
				root_stop_ask(running)
			}
			// The run of the start list starts only once this one is
			// reaped: one `unlock` at a time.
			start_policy_choice_stage = .Machine_Key_Stopping
			start_policy_choice_deadline = system.time() + START_POLICY_HANG_BOUND_MILLISECONDS
		}
	case .Machine_Key_Stopping:
		if unlock_run.stage == .Stopped {
			start_policy_choice_end()
			return
		}
		if system.time() >= start_policy_choice_deadline {
			system.log(.Warning, "root: unlock did not stop within the hang bound of ", u64(START_POLICY_HANG_BOUND_MILLISECONDS), " ms after its stop was asked: the start policy starts, and its row unlock does not start while it runs")
			start_policy_choice_end()
		}
	case .Table:
		start_policy_choice_table_check()
	}
}

// start_policy_choice_table_check ends the read when the table of principal
// 0 is no longer being read.
start_policy_choice_table_check :: proc "contextless" () {
	if persisted_tables[principals.MACHINE].state != .Reading {
		start_policy_choice_end()
		return
	}
	if system.time() >= start_policy_choice_deadline {
		system.log(.Warning, "root: the read of the disk grant table of principal 0 did not end within the hang bound of ", u64(START_POLICY_HANG_BOUND_MILLISECONDS), " ms: the choice of principal 0 is not read")
		start_policy_choice_end()
	}
}

// start_policy_choice_wake gives the time at which the loop must run the
// step of the read even with no event.
start_policy_choice_wake :: proc "contextless" () -> u64 {
	switch start_policy_choice_stage {
	case .Machine_Key, .Machine_Key_Stopping, .Table:
		return start_policy_choice_deadline
	case .Done, .Load:
	}
	return system.WAIT_FOREVER
}

// start_policy_choice_end ends the read, and starts the start policy that
// the boot record and the choice ask for. A choice counts only in a table
// that this service read under a machine key that opens with no
// passphrase.
start_policy_choice_end :: proc "contextless" () {
	start_policy_choice_stage = .Done
	start_policy_choice_deadline = system.WAIT_FOREVER
	chosen: ^disk_process.Grant_Row
	switch persisted_tables[principals.MACHINE].state {
	case .Kept:
		if machine_key_without_passphrase {
			chosen = disk_process.table_start_policy_row(&disk_grant_tables[principals.MACHINE])
		}
	case .No_Passphrase:
		// No record of a machine key: no choice was kept.
	case .Awaited, .Record_Unreadable, .Reading, .Unread, .Refused, .Unwritten:
		system.log(.Info, "root: the disk grant table of principal 0 is not read before the start policy: no choice of principal 0 is known")
	}
	start_policy_after_the_choice(chosen)
}

// nickname_reserved_for_a_start_policy says if a nickname cannot name a
// start policy: it runs under its nickname in the table of the processes,
// so a name that a table of this service gives a grant, or that a module of
// the boot image has, would take them.
nickname_reserved_for_a_start_policy :: proc "contextless" (nickname: string) -> bool {
	return name_is_a_system_part(nickname) || role_names_the_process(nickname) || len(system.image_find(image, nickname)) != 0
}

// start_policy_chosen_nickname_text gives the nickname of the chosen start
// policy.
start_policy_chosen_nickname_text :: proc "contextless" () -> string {
	return string(start_policy_chosen_nickname[:start_policy_chosen_nickname_length])
}

// start_policy_chosen_load_begin reads the module file of the chosen row
// from the store module_files of principal 0, with the load of a disk
// process: its bounds, the check of the hash and the import scan. Its end
// starts the policy, or the rescue.
start_policy_chosen_load_begin :: proc "contextless" (row: ^disk_process.Grant_Row) {
	nickname := disk_process.row_nickname(row)
	start_policy_chosen_nickname = {}
	start_policy_chosen_nickname_length = copy(start_policy_chosen_nickname[:], nickname)
	// The rules of the choice again: a table restored from an older version,
	// or a boot image that holds a new module of this name, can name what
	// the choice refused.
	if nickname_reserved_for_a_start_policy(nickname) {
		system.log(.Warning, "root: the chosen start policy \"", nickname, "\" is not read: the root service gives this name a grant, or a module of the boot image has it: the rescue start policy starts")
		start_policy_launch(.Rescue)
		return
	}
	if disk_load.stage != .Idle {
		system.log(.Warning, "root: the chosen start policy \"", nickname, "\" is not read: another load from the disk runs: the rescue start policy starts")
		start_policy_launch(.Rescue)
		return
	}
	disk_reader = {}
	copy(disk_reader.name[:len(disk_reader.name) - 1], disk_process.STORE_NAME)
	disk_reader.principal = principals.MACHINE
	connection, service, ring_memory, region_memory, open_status := connection_open(&disk_reader, "storage")
	if open_status != .Ok {
		system.log(.Warning, "root: the chosen start policy \"", nickname, "\" is not read: no connection to the storage service, status ", open_status, ": the rescue start policy starts")
		start_policy_launch(.Rescue)
		return
	}
	client, opened := storage.open_handles(ring_memory, region_memory, service.process, system.image_find(image, "storage"))
	if !opened {
		system.close(ring_memory)
		system.close(region_memory)
		disconnect(connection)
		system.log(.Warning, "root: the chosen start policy \"", nickname, "\" is not read: the call ring and the call region of the storage service do not map: the rescue start policy starts")
		start_policy_launch(.Rescue)
		return
	}
	name_bytes: [disk_process.NAME_LIMIT]u8
	name_length := copy(name_bytes[:], nickname)
	disk_load = {
		stage            = .Size,
		name             = name_bytes,
		name_length      = name_length,
		hash             = row.hash,
		principal        = principals.MACHINE,
		connection       = connection,
		client           = client,
		deadline         = system.time() + disk_process.LOAD_DEADLINE_MILLISECONDS,
		for_start_policy = true,
	}
	start_policy_choice_stage = .Load
	system.log(.Info, "root: reads the chosen start policy \"", nickname, "\", the file ", system.Hash{row.hash[:]}, ", from the store ", disk_process.STORE_NAME, " of principal 0")
	if !disk_load_ask("size", 0, false) {
		disk_load_end(.Bad_State, disk_refused(nickname, {}, "the storage service took no call"))
	}
}

// start_policy_chosen_load_ended is told of the end of the load of the
// chosen start policy: a load that failed, with the line of its cause
// before, starts the rescue.
start_policy_chosen_load_ended :: proc "contextless" (status: system.Status) {
	start_policy_choice_stage = .Done
	if status == .Ok {
		return
	}
	system.log(.Warning, "root: the chosen start policy \"", start_policy_chosen_nickname_text(), "\" is not started, with the status ", status, ": the rescue start policy starts")
	start_policy_launch(.Rescue)
}

// start_policy_chosen_run starts the chosen start policy from the bytes of
// its file, which this service checked. It receives what the start policy
// of the boot image receives, with no list: its root ring, the log, the
// date page, its fresh bytes page and the machine parts page. Its role is
// the grant Start_Policy and nothing else, whatever its row: no store, no
// window, no right of the machine. Its budget comes from the one budget of
// the disk processes, as each module of a disk. It is measured into PCR 12
// before Process_Start.
start_policy_chosen_run :: proc "contextless" (name: string, file: []u8, hash: [disk_process.HASH_SIZE]u8, store_files: []system.Source_File, load_error: ^module.Load_Error) -> system.Status {
	slot: ^Started
	for &item in started {
		if place_is_free(&item) {
			slot = &item
			break
		}
	}
	if slot == nil {
		return .No_Slot
	}
	slot^ = {}
	copy(slot.name[:len(slot.name) - 1], name)
	slot.principal = principals.MACHINE
	slot.from_disk = true
	slot.role = {grants = {.Start_Policy}}
	slot.reserved = true
	context_grants: system.Context_Grants
	values: system.Context_Values
	system.grant_put(&context_grants, op.CONTEXT_LOG, {system.context_record().handles[op.CONTEXT_LOG], {.Write}})
	status: system.Status
	slot.requests_memory, slot.requests, status = system.ring_create()
	if status != .Ok {
		slot^ = {}
		return status
	}
	system.grant_put(&context_grants, system.GRANT_ROOT, {slot.requests_memory, {.Read, .Write}})
	mappings: [8]system.Mapping
	mapping_count := 0
	date_page_give(mappings[:], &mapping_count, &values)
	fresh_bytes_page_give(slot, mappings[:], &mapping_count, &values)
	// The machine parts page and no list: the size of the list is 0.
	if machine_parts_memory != 0 {
		mappings[mapping_count] = {memory = machine_parts_memory, address = start_list.MACHINE_PARTS_PAGE_ADDRESS, first = 0, page_count = 1}
		mapping_count += 1
		system.range_mapped_put(&values, .Start_Policy_Pages)
	}
	disk_processes: system.Handle
	disk_processes, status = disk_processes_budget_get()
	if status == .Ok && context_refused(name, &context_grants, &values) {
		status = .Bad_State
	}
	process: system.Handle
	if status == .Ok {
		words: [64]u8
		// A chosen start policy never runs unmeasured: else PCR 12 would
		// show the rescue alone after a module of the disk ran and failed,
		// and an attestation would not see it. The rescue starts in its
		// place, and is measured, or says why not.
		if !start_policy_measure(hash, {}, system.format(words[:], "(nickname \"", name, "\")")) {
			system.log(.Warning, "root: the chosen start policy \"", name, "\" does not run unmeasured: it is not started")
			status = .Bad_State
		}
	}
	if status == .Ok {
		process_budget := disk_budget_of(file, name, disk_processes)
		source := load_source()
		source.files = store_files
		process, status = system.process_start(file, name, context_grants.grants, random.values_with_seed(&process_generator, values.values), process_budget, mappings[:mapping_count], nil, source, load_error, disk_processes)
		if status == .No_Budget {
			budget_refusal_log(name, process_budget, disk_processes, "the disk processes")
		}
	}
	if status != .Ok {
		release(slot)
		return status
	}
	slot.reserved = false
	slot.process = process
	slot.hash = hash
	slot.granted += {.Log}
	disk_process_page_add(slot)
	start_policy_list = .Chosen
	start_policy_from_disk = true
	start_policy_name_counts = {}
	start_policy_process = slot
	start_policy_hash = hash
	start_policy_stage = .Running
	start_policy_deadline = system.time() + START_POLICY_HANG_BOUND_MILLISECONDS
	system.log(.Info, "root: started the chosen start policy \"", name, "\" from the disk, hash ", system.Hash{start_policy_hash[:]}, ", with the grant Start_Policy only")
	return .Ok
}

// start_policy_choice_command runs the command Start_Policy_Choice of the
// console of principal 0: the start policy of the next start, or with no
// nickname the end of the choice. values is the completion: an error
// record for a refusal. A refusal changes nothing.
start_policy_choice_command :: proc "contextless" (caller: ^Started, record: ring.Record, values: ^[7]u64) -> system.Status {
	kind := u32(root_ring.Root_Command.Start_Policy_Choice)
	hash := transmute([disk_process.HASH_SIZE]u8)[4]u64{record.values[0], record.values[1], record.values[2], record.values[3]}
	nickname_bytes, nickname_length := disk_process.name_unpack({record.values[4], record.values[5], record.values[6]})
	nickname := string(nickname_bytes[:nickname_length])
	if .Acts_For_Principal not_in grants_held(caller) {
		values^ = errors.ring_fail(kind, .No_Grant, .Acts_For_Principal, 1)
		return .No_Right
	}
	if form_status, form_refusal := start_policy_rules.choice_form_refusal(nickname == "", hash == {}); form_status != .Ok {
		values^ = form_refusal
		system.log(.Warning, "root: refused a choice of a start policy: a nickname of no byte ends the choice, and the command names a hash")
		return form_status
	}
	facts := start_policy_rules.Choice_Facts {
		caller_is_principal_0          = caller.principal == principals.MACHINE,
		machine_key_record             = persisted_tables[principals.MACHINE].state != .No_Passphrase,
		machine_key_without_passphrase = machine_key_without_passphrase,
	}
	refusal := start_policy_rules.choice_refusal(facts)
	switch refusal {
	case .None:
	case .Named_Principal:
		system.log(.Warning, "root: refused a choice of a start policy: the caller acts for principal ", caller.principal, ", and only principal 0 chooses the start policy of the machine")
	case .No_Machine_Key:
		system.log(.Warning, "root: refused a choice of a start policy: the machine has no machine key, so the disk grant table of principal 0 lasts until the machine stops, and no choice reaches the next start; machine_seal() makes a machine key")
	case .Passphrase:
		system.log(.Warning, "root: refused a choice of a start policy: the machine key opens with the machine passphrase, and the root service reads the choice before a passphrase can be typed")
	}
	if refusal != .None {
		values^ = start_policy_rules.choice_record(refusal)
		return .Bad_State
	}
	if persisted_table_refusal(principals.MACHINE) {
		values^ = errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(system.Status.Bad_State))
		return .Bad_State
	}
	table := &disk_grant_tables[principals.MACHINE]
	if nickname == "" {
		if disk_process.table_start_policy_end(table) != .None {
			system.log(.Info, "root: principal 0 has chosen no start policy: the default start policy runs at the next start")
			return .Ok
		}
		system.log(.Info, "root: principal 0 ended its choice of a start policy: the default start policy runs at the next start of the machine")
		persisted_table_changed(principals.MACHINE)
		return .Ok
	}
	problem_of_the_name, offset := disk_process.nickname_grant_problem(nickname)
	switch problem_of_the_name {
	case .None:
	case .Empty:
		values^ = errors.ring_fail(kind, .Empty, .Bytes, 1, 0, disk_process.NAME_LIMIT)
		return .Bad_Operation
	case .Too_Long:
		values^ = errors.ring_fail(kind, .Too_Long, .Bytes, 1, i64(nickname_length), disk_process.NAME_LIMIT)
		return .Bad_Operation
	case .Bad_Byte:
		values^ = errors.ring_fail(kind, .Bad_Byte, .None, 1, i64(offset), 0, i64(offset < len(nickname) ? nickname[offset] : 0))
		return .Bad_Operation
	case .Store_Name, .Table_Name:
		values^ = errors.ring_fail(kind, .Reserved, .None, 1)
		return .Bad_Operation
	}
	// The start policy runs under its nickname, in the table of the
	// processes: a name that a table of this service gives a grant, or
	// that a module of the boot image has, would take them.
	if nickname_reserved_for_a_start_policy(nickname) {
		values^ = errors.ring_fail(kind, .Reserved, .None, 1)
		system.log(.Warning, "root: refused the start policy ", system.Module_Name{nickname}, ": the root service gives this name a grant, or a module of the boot image has it, and the start policy runs under its nickname")
		return .Bad_Operation
	}
	switch disk_process.table_start_policy_choose(table, nickname, hash) {
	case .None:
	case .No_File:
		values^ = errors.ring_fail(kind, .Absent, .Grants, 1)
		system.log(.Warning, "root: refused the start policy ", system.Module_Name{nickname}, ": the nickname names no module, as it has no row in the disk grant table of principal 0; name the hash of its file")
		return .Bad_Handle
	case .Other_File:
		named := disk_process.table_find(table, nickname)
		head := transmute([4]u64)named.hash
		values^ = errors.ring_fail(kind, .Exists, .Grants, 2, i64(head[0]))
		system.log(.Warning, "root: refused the start policy ", system.Module_Name{nickname}, ": the nickname names the file ", system.Hash{named.hash[:]}, ", and the command names the file ", system.Hash{hash[:]})
		return .Bad_Operation
	case .Holds_Store:
		values^ = errors.ring_fail(kind, .Reserved, .Grants, 1)
		system.log(.Warning, "root: refused the start policy ", system.Module_Name{nickname}, ": its row holds the grant store, and a start policy holds the grant Start_Policy and nothing else")
		return .Bad_Operation
	case .Full:
		values^ = errors.ring_fail(kind, .Full, .Grants, 0, 0, disk_process.ROW_CAPACITY)
		return .No_Slot
	case .Absent, .Not_Held, .Same_File, .Zero_Hash, .Zero_Key, .Start_Policy_Row:
		values^ = errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(system.Status.Bad_State))
		return .Bad_State
	}
	row := disk_process.table_start_policy_row(table)
	if row == nil {
		values^ = errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(system.Status.Bad_State))
		return .Bad_State
	}
	system.log(.Info, "root: principal 0 chose the start policy ", system.Module_Name{nickname}, ", the file ", system.Hash{row.hash[:]}, ": it runs at the next start of the machine, with the grant Start_Policy only; the machine key keeps the choice on the disk")
	persisted_table_changed(principals.MACHINE)
	return .Ok
}
