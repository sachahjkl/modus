package root

// The bridge of the core to the delegated principals service
// (src/md/api/root_service_split.md, "State").
//
// The principals service holds the key of the tag of each disk grant table,
// and reads and writes each table in the store module_files of its
// principal (persisted_grant_table.odin): the core holds no key and calls no
// storage service. The core keeps the tables in memory, and each rule of a
// grant runs here. The service also holds a mirror of the state of the
// core, which the core keeps whole with the commands of its ring: the
// record of each named principal (Register_Principal), the state of its
// session (Session_Transition), the whole set of rows of each table
// (Replace_Disk_Rows), each allow and revocation of a client key
// (Client_Key_Command), and the choice of a start policy and the machine
// passphrase (Start_Policy_Command).
//
// The core never waits for the service. A change marks what differs, and
// one pass of the loop sends the commands, each from a place of the
// transfer region that its answer frees; the loop reads the answers. The
// bridge compares the state of the core with what it told the service,
// not a list of events, so a command that found no free place is sent at a
// later pass, and a service that starts again gets the whole state. A
// refusal of the service is one line: the core and its mirror disagree,
// and the core keeps its rule. A service that does not start in three
// starts leaves the core with no mirror, with one line.

import "base:intrinsics"
import "modus:contract/remote"
import "modus:contract/ring"
import rd "modus:contract/root_delegation"
import op "modus:contract/operation"
import "modus:disk_process"
import "modus:principals"
import "modus:random"
import "modus:system"

// The bound of the starts of the principals service, as for each delegated
// service of the start.
PRINCIPALS_RESTART_LIMIT :: 3

// The most answers that one pass of the loop reads: each place has one
// command in flight, so a service that writes more floods the core.
PRINCIPALS_ANSWERS_PER_PASS :: 2 * rd.PRINCIPALS_TRANSFER_PLACE_COUNT

#assert(rd.PRINCIPAL_NAME_CAPACITY == principals.NAME_LIMIT)
#assert(len(disk_process.Client_Key_Row{}.key) == len(rd.Client_Key_Input{}.client_key))

// What the core told the principals service: the bridge sends what differs
// from the state of the core.
Principals_Mirror :: struct {
	registered:          [principals.PRINCIPAL_CAPACITY]bool,
	unlocked:            [principals.PRINCIPAL_CAPACITY]bool,
	rows_changed:        [principals.PRINCIPAL_CAPACITY]bool,
	passphrase_required: bool,
}

principals_process: ^Started
principals_ring_memory: system.Handle
principals_ring: ring.Ring
principals_region_memory: system.Handle
principals_region: []u8
principals_starts: int
// The core started the service once: a stop then starts it again, within
// its bound.
principals_service_wanted: bool
principals_absent_told: bool
// The core stopped the service and waits for its reap: no command goes to
// it meanwhile.
principals_stopping: bool
principals_next_tag: u32 = 1
principals_mirror: Principals_Mirror
// The generation of the rows of each principal: each set of rows has a new
// one, which the service requires to grow.
principals_rows_generation: [principals.PRINCIPAL_CAPACITY]u64

// The tag of the command in flight from each place of the transfer region,
// 0 for a free place, its command for the line of a refusal, and the
// principal of a Table_Key.
principals_place_tags: [rd.PRINCIPALS_TRANSFER_PLACE_COUNT]u32
principals_place_commands: [rd.PRINCIPALS_TRANSFER_PLACE_COUNT]rd.Principals_Ring_Command
principals_place_principals: [rd.PRINCIPALS_TRANSFER_PLACE_COUNT]u64

// The set of rows that the bridge builds: too large for the stack of the
// loop.
principals_rows_request: rd.Disk_Rows_Set_Request

// principals_service_boot starts the principals service at the start of the
// machine. A start that fails is tried again by the loop, within the bound.
principals_service_boot :: proc "contextless" () {
	principals_service_wanted = true
	_ = principals_service_start()
}

// principals_service_start starts the principals service with its ring, its
// transfer region and its log, and nothing else. It gives false past
// PRINCIPALS_RESTART_LIMIT starts or on a failure. A service that starts
// has an empty state: the mirror is reset, so the next pass sends the
// whole state of the core.
principals_service_start :: proc "contextless" () -> bool {
	if principals_process != nil {
		return true
	}
	if principals_starts >= PRINCIPALS_RESTART_LIMIT {
		return false
	}
	principals_starts += 1
	slot := part_place_take()
	file := image_file_checked("principals")
	if slot == nil {
		system.log_fact(.Warning, Principals_Service_Start_Failed{status = .No_Slot})
		return false
	}
	if len(file) == 0 {
		system.log_fact(.Warning, Principals_Service_Start_Failed{status = .Bad_Handle})
		return false
	}
	ring_memory, ring_opened, status := system.ring_create()
	region_memory: system.Handle
	region_address: rawptr
	if status == .Ok {
		region_memory, status = system.memory_create(rd.PRINCIPALS_REGION_PAGES)
	}
	if status == .Ok {
		region_address, status = system.memory_map(region_memory, {.Write})
	}
	process: system.Handle
	principals_budget: Start_Budget
	if status == .Ok {
		grants: system.Context_Grants
		values: system.Context_Values
		system.grant_put(&grants, rd.PRINCIPALS_RING_SLOT, {ring_memory, {.Read, .Write}})
		system.grant_put(&grants, rd.PRINCIPALS_REGION_SLOT, {region_memory, {.Read, .Write}})
		// The boot image, read-only: the file of the storage service, whose
		// exports a call of a table names.
		system.grant_put(&grants, rd.PRINCIPALS_IMAGE_SLOT, {image_memory, {.Read}})
		system.grant_put(&grants, op.CONTEXT_LOG, log_grant(start_grant_set_of("principals")))
		system.value_put(&values, rd.PRINCIPALS_VALUE_IMAGE_SIZE, u64(len(image)))
		budget_ok: bool
		if context_refused("principals", &grants, &values) {
			status = .Bad_State
		} else if principals_budget, budget_ok = budget_of(file, "principals"); !budget_ok {
			status = .No_Budget
		} else {
			process, status = system.process_start(file, "principals", grants.grants, random.values_with_seed(&process_generator, values.values), principals_budget.amounts, nil, &prepared, load_source(), ready = &slot.ready)
		}
	}
	if status != .Ok {
		if region_address != nil {
			system.memory_unmap(region_address)
		}
		if ring_opened.head != nil {
			system.ring_close(&ring_opened)
		}
		for handle in ([2]system.Handle{ring_memory, region_memory}) {
			if handle != 0 {
				system.close(handle)
			}
		}
		system.log_fact(.Warning, Principals_Service_Start_Failed{status = status})
		return false
	}
	part_place_fill(slot, "principals", process)
	start_budget_note(slot, principals_budget)
	principals_process = slot
	principals_ring_memory, principals_ring = ring_memory, ring_opened
	principals_region_memory = region_memory
	principals_region = ([^]u8)(region_address)[:rd.PRINCIPALS_REGION_PAGES * system.PAGE_SIZE]
	principals_place_tags = {}
	principals_mirror = {}
	for &changed in principals_mirror.rows_changed {
		changed = true
	}
	system.log_fact(.Info, Principals_Service_Started{starts = u64(principals_starts), start_limit = u64(PRINCIPALS_RESTART_LIMIT)})
	return true
}

// principals_service_end forgets the principals service when it stopped:
// the next pass of the loop starts it again, within its bound. The answers
// of the commands in flight are lost with its ring.
principals_service_end :: proc "contextless" (item: ^Started) {
	if item != principals_process {
		return
	}
	if raw_data(principals_region) != nil {
		system.memory_unmap(raw_data(principals_region))
		principals_region = nil
	}
	if principals_ring.head != nil {
		// A Table_Key that the service did not read keeps its key in a slot
		// of the command ring: each slot is erased before the ring closes.
		commands := &principals_ring.commands
		for index in u64(0) ..= u64(commands.mask) {
			intrinsics.mem_zero_volatile(&commands.records[index].values, size_of(commands.records[index].values))
		}
		system.ring_close(&principals_ring)
	}
	for handle in ([2]system.Handle{principals_ring_memory, principals_region_memory}) {
		if handle != 0 {
			system.close(handle)
		}
	}
	principals_ring_memory, principals_region_memory = 0, 0
	principals_place_tags = {}
	principals_process = nil
	principals_stopping = false
	system.log_fact(.Warning, Principals_Service_Stopped{})
	persisted_tables_service_ended()
}

// principals_service_silent_stop stops a principals service that gave no
// answer to the call of a table in time: the place of the call would stay
// taken for ever. The reap frees each place, and the next pass starts the
// service again within its bound. The stopped service holds no key.
principals_service_silent_stop :: proc "contextless" () {
	if principals_process == nil || principals_stopping {
		return
	}
	principals_stopping = true
	system.log_fact(.Warning, Principals_Service_Silent{})
	for &table in persisted_tables {
		table.key_held = false
	}
	started_process_stop(principals_process)
}

// principals_rows_changed says that the disk grant table of a principal
// changed in the core: the next pass sends its whole set of rows.
principals_rows_changed :: proc "contextless" (principal: u64) {
	if principal < principals.PRINCIPAL_CAPACITY {
		principals_mirror.rows_changed[principal] = true
	}
}

// principals_client_key_tell tells the service of an allow or a revocation
// of a client key of a principal whose session it holds as running. With
// no free place, or for a principal that the service does not hold as
// running, nothing is sent: the set of rows that the change marks carries
// the same key.
principals_client_key_tell :: proc "contextless" (principal: u64, action: rd.Client_Key_Action, key: [32]u8, uses: remote.Client_Uses) {
	principals_rows_changed(principal)
	if !principals_running_in_mirror(principal) {
		return
	}
	input := rd.Client_Key_Input {
		principal_id     = principal,
		action_word      = u32(action),
		client_key       = key,
		client_uses_word = action == .Allow ? remote.client_uses_word(uses) : 0,
	}
	_ = principals_command_send(.Client_Key_Command, &input, size_of(input))
}

// principals_start_policy_tell tells the service of a choice of a start
// policy of principal 0, or of its end with an empty nickname. As for a
// client key, the set of rows that the change marks carries the same
// choice when nothing is sent.
principals_start_policy_tell :: proc "contextless" (nickname: string, hash: [disk_process.HASH_SIZE]u8) {
	principals_rows_changed(principals.MACHINE)
	if principals_process == nil || len(nickname) > rd.NICKNAME_CAPACITY {
		return
	}
	input := rd.Start_Policy_Input {
		principal_id = principals.MACHINE,
		action_word  = u32(rd.Start_Policy_Action.Clear_Choice),
	}
	if nickname != "" {
		input.action_word = u32(rd.Start_Policy_Action.Set_Choice)
		copy(input.nickname[:], nickname)
		input.nickname_length = u8(len(nickname))
		input.module_hash = hash
	}
	_ = principals_command_send(.Start_Policy_Command, &input, size_of(input))
}

// principals_running_in_mirror says if the service holds the session of a
// principal as running: principal 0 always, a named principal after its
// Unlock.
@(private = "file")
principals_running_in_mirror :: proc "contextless" (principal: u64) -> bool {
	if principals_process == nil || principal >= principals.PRINCIPAL_CAPACITY {
		return false
	}
	return principal == principals.MACHINE || principals_mirror.registered[principal] && principals_mirror.unlocked[principal]
}

@(private = "file")
principals_tag_next :: proc "contextless" () -> u32 {
	tag := principals_next_tag
	principals_next_tag = principals_next_tag == max(u32) ? 1 : principals_next_tag + 1
	return tag
}

@(private = "file")
principals_free_places :: proc "contextless" () -> (count: int) {
	for tag in principals_place_tags {
		if tag == 0 {
			count += 1
		}
	}
	return count
}

// principals_place_send copies an input record to a free place of the
// transfer region and sends its command, with no wait: the offset of the
// place goes in values[offset_index], and a negative index sends none. The
// values are the caller's: a caller that sends a key erases them after. The
// place stays taken until the answer. ok is false when the service does not
// run, no place is free, or the ring took no record.
principals_place_send :: proc "contextless" (command: rd.Principals_Ring_Command, input: rawptr, size: int, values: ^[7]u64, offset_index: int, principal: u64 = 0) -> (tag: u32, ok: bool) {
	if principals_process == nil || principals_stopping || principals_ring.head == nil || raw_data(principals_region) == nil {
		return 0, false
	}
	for &place_tag, place in principals_place_tags {
		if place_tag != 0 {
			continue
		}
		offset, place_ok := rd.principals_transfer_place_offset(place)
		if !place_ok || size > rd.PRINCIPALS_TRANSFER_PLACE_BYTES {
			return 0, false
		}
		if input != nil && size > 0 {
			intrinsics.mem_copy_non_overlapping(&principals_region[offset], input, size)
		}
		if offset_index >= 0 && offset_index < len(values) {
			values[offset_index] = offset
		}
		tag = principals_tag_next()
		record := ring.Record{kind = u32(command), tag = tag, values = values^}
		sent := system.send(&principals_ring.commands, record)
		// A Table_Key carries a key: the copy of this frame is erased.
		intrinsics.mem_zero_volatile(&record, size_of(record))
		if !sent {
			return 0, false
		}
		place_tag = tag
		principals_place_commands[place] = command
		principals_place_principals[place] = principal
		return tag, true
	}
	return 0, false
}

// principals_command_send sends a command of the mirror, whose input record
// is at the offset of values[0].
@(private = "file")
principals_command_send :: proc "contextless" (command: rd.Principals_Ring_Command, input: rawptr, size: int) -> bool {
	values: [7]u64
	_, sent := principals_place_send(command, input, size, &values, 0)
	return sent
}

// principals_table_key_send gives the principals service the key of the tag
// of the table of a principal, in the values of the record: the key is in
// no place of the region, and the service erases the slot of its ring after
// it reads it. This service keeps no copy. false: the service does not run
// or took no record.
principals_table_key_send :: proc "contextless" (principal: u64, key: ^[32]u8) -> bool {
	values: [7]u64
	defer key_erase((cast(^[size_of(values)]u8)&values)[:])
	words := cast(^[4]u64)key
	values = {0 = words[0], 1 = words[1], 2 = words[2], 3 = words[3], 4 = principal}
	_, sent := principals_place_send(.Table_Key, nil, 0, &values, -1, principal)
	return sent
}

// principals_session_send sends one transition of the session of a
// principal.
@(private = "file")
principals_session_send :: proc "contextless" (principal: u64, action: rd.Session_Action) -> bool {
	input := rd.Session_Transition_Input{principal_id = principal, action_word = u32(action)}
	return principals_command_send(.Session_Transition, &input, size_of(input))
}

// principals_passphrase_required says if the machine has a passphrase that
// forbids the choice of a start policy, by the rule of the core
// (start_policy_choice.odin): a record of the machine key that does not
// open with no passphrase.
@(private = "file")
principals_passphrase_required :: proc "contextless" () -> bool {
	return persisted_tables[principals.MACHINE].state != .No_Passphrase && !machine_key_without_passphrase
}

// principals_sync sends, in order, what the service does not hold yet: the
// record of each named principal, the state of its session, the machine
// passphrase, then the set of rows of each changed table. It stops at the
// first command that finds no place: the answers free places, and their
// arrival runs the next pass.
@(private = "file")
principals_sync :: proc "contextless" () {
	if principals_process == nil {
		if !principals_service_wanted {
			return
		}
		if principals_starts >= PRINCIPALS_RESTART_LIMIT {
			if !principals_absent_told {
				principals_absent_told = true
				system.log_fact(.Error, Principals_Service_Absent{start_limit = PRINCIPALS_RESTART_LIMIT})
			}
			return
		}
		if !principals_service_start() {
			return
		}
	}
	for number in u64(1) ..< principals.PRINCIPAL_CAPACITY {
		record := &principal_records[number]
		if !principals_mirror.registered[number] && (record.state == .Locked || record.state == .In_Front) {
			input := rd.Register_Principal_Input{principal_id = number, public_key = record.public_key}
			input.name_length = u8(copy(input.name[:], record.name[:clamp(record.name_length, 0, principals.NAME_LIMIT)]))
			if !principals_command_send(.Register_Principal, &input, size_of(input)) {
				return
			}
			principals_mirror.registered[number] = true
		}
		if !principals_mirror.registered[number] {
			continue
		}
		unlocked := record.state == .In_Front
		if unlocked == principals_mirror.unlocked[number] {
			continue
		}
		if unlocked {
			// The session in front of the core is the session that runs
			// (desktop_principal): the unlock and the front go together.
			if principals_free_places() < 2 || !principals_session_send(number, .Unlock) || !principals_session_send(number, .Bring_To_Front) {
				return
			}
			// A table of a locked session is refused by the service: the
			// unlock sends it.
			principals_mirror.rows_changed[number] = true
		} else if !principals_session_send(number, .Lock) {
			return
		}
		principals_mirror.unlocked[number] = unlocked
	}
	if required := principals_passphrase_required(); required != principals_mirror.passphrase_required {
		input := rd.Start_Policy_Input {
			principal_id        = principals.MACHINE,
			action_word         = u32(rd.Start_Policy_Action.Set_Passphrase_Required),
			passphrase_required = required,
		}
		if !principals_command_send(.Start_Policy_Command, &input, size_of(input)) {
			return
		}
		principals_mirror.passphrase_required = required
	}
	for number in u64(0) ..< principals.PRINCIPAL_CAPACITY {
		if !principals_mirror.rows_changed[number] || !principals_running_in_mirror(number) {
			continue
		}
		generation := principals_rows_generation[number] + 1
		if !disk_process.disk_rows_set_request_of_table(&disk_grant_tables[number], number, generation, &principals_rows_request) {
			principals_mirror.rows_changed[number] = false
			system.log_fact(.Warning, Principals_Rows_Unsent{principal = number})
			continue
		}
		if !principals_command_send(.Replace_Disk_Rows, &principals_rows_request, size_of(principals_rows_request)) {
			return
		}
		principals_rows_generation[number] = generation
		principals_mirror.rows_changed[number] = false
	}
}

// principals_answers reads the answers of the principals service, frees
// their places, sends what the service does not hold yet, and adds the
// completions of the service to the wait of the loop. A refusal is one
// line and changes nothing in the core.
principals_answers :: proc "contextless" (wait: ^system.Wait) {
	if principals_ring.head != nil {
		read := 0
		for record in root_receive(&principals_ring.completions, "the principals service") {
			read += 1
			place := -1
			if record.tag != 0 {
				for tag, index in principals_place_tags {
					if tag == record.tag {
						place = index
					}
				}
			}
			// An answer frees its place whatever its status: the service
			// read the place, and a place held for ever would stop the bridge.
			if place >= 0 {
				principals_place_tags[place] = 0
			}
			status, known := rd.principals_ring_status_from_word(record.kind)
			if place < 0 || !known {
				system.log_fact(.Warning, Principals_Answer_Refused{status_word = u64(record.kind), tag = u64(record.tag)})
			} else {
				offset, _ := rd.principals_transfer_place_offset(place)
				command := principals_place_commands[place]
				switch command {
				case .Table_Read, .Table_Write:
					persisted_table_answer(record, status, offset)
				case .None, .Register_Principal, .Session_Transition, .Replace_Disk_Rows, .Client_Key_Command, .Start_Policy_Command, .Table_Key:
					switch status {
					case .Ok:
					case .Refused, .Bad_Command, .Storage_Refused:
						system.log_fact(.Warning, Principals_Command_Refused{command_word = u64(command), status_word = u64(record.kind), first_value = record.values[0], second_value = record.values[1]})
						// A key that the service refused is not held: the
						// next unlock gives it again.
						if command == .Table_Key && principals_place_principals[place] < principals.PRINCIPAL_CAPACITY {
							persisted_tables[principals_place_principals[place]].key_held = false
						}
					}
				}
			}
			if read >= PRINCIPALS_ANSWERS_PER_PASS {
				break
			}
		}
	}
	principals_sync()
	if principals_ring.head != nil {
		system.wait_records(wait, &principals_ring.completions)
	}
}
