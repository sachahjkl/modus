package root

import "base:intrinsics"
import "internal:root/principal_unlock_flow"
import info "modus:contract/boot_info"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/ring"
import "modus:contract/system_description"
import "modus:principals"
import "modus:contract/root_ring"
import "modus:contract/value_kinds"
import "modus:system"

// The principals in the root service (docs/PRINCIPALS.md).
//
// The kernel knows no principal: a process acts with the handles that it
// holds. This service holds one record for each principal, and records for
// each process that it starts the principal whose session the process
// belongs to. It names that principal in each connection (the grant of the
// Connect command), in the name of the store of the process, and in the
// grants of the process.
//
// Principal 0 is the machine: its record exists at each boot, from the
// trust record of the boot program, and its session needs no unlock. With
// no named principal the system runs as principal 0 only.
//
// One named principal: the process `unlock` keeps its record in its own
// store, with its secret keys sealed under a key that Argon2id derives from
// its passphrase. `unlock` gives this service the public part of the record
// (Principal_Record), and tells it when the passphrase opened the seal
// (Principal_Unlock). This service trusts `unlock` for both, as the one
// holder of the grant Principals, as it trusts `settings` as the one writer
// of the settings page. The seal by the TPM is not built.
//
// `unlock` also keeps the record of the machine passphrase, and gives this
// service the key of the tag of the disk grant table of principal 0
// (Machine_Key), and with Principal_Unlock the key of the tag of the table
// of the named principal (persisted_grant_table.odin).

Principal_Record :: struct {
	// The state of its session: session_change writes it. Principal 0 has
	// no session state, and keeps Absent: principal_read says Machine.
	state:       principals.Session_State,
	name:        [principals.NAME_LIMIT]u8,
	name_length: int,
	public_key:  [32]u8, // Ed25519: the key that signs the grants of the principal. Principal 0: none in this system yet.
	// The principal identifier from its file (Principal_Identifier): the name
	// of the principal on the disk. All zero until `unlock` gives it; a
	// session never starts without it.
	identifier:  principals.Principal_Identifier,
	measured:    bool, // Principal 0: the boot program measured the system into PCR 11.
	measure:     [32]u8, // Principal 0: the value of PCR 11.
}

principal_records: [principals.PRINCIPAL_CAPACITY]Principal_Record

// Named principal slots retired by removal during this boot run: refused
// for new creation until reboot so no stale handle aliases a new principal.
retired_slots: principals.Retired_Slots

// The seat: what the screen shows, and the session in front. It is a fact
// of its own, not the set of the unlocked records
// (src/md/features/several_principals.md, "The states"). seat_change
// writes it.
seat: principals.Seat

// session_change changes the state of the session of a named principal:
// the one place that writes it. A refused event changes nothing, and says
// so: each caller checked the state before, so a refusal is a fault of
// this service.
session_change :: proc "contextless" (number: u64, event: principals.Session_Event) -> bool {
	if number == principals.MACHINE || number >= principals.PRINCIPAL_CAPACITY {
		system.log_fact(.Warning, Session_Event_Refused{principal = number, event_code = u64(event), state_code = 0})
		return false
	}
	record := &principal_records[number]
	next, ok := principals.session_next(record.state, event)
	if !ok {
		system.log_fact(.Warning, Session_Event_Refused{principal = number, event_code = u64(event), state_code = u64(record.state)})
		return false
	}
	record.state = next
	return true
}

// seat_change changes the seat: the one place that writes it.
seat_change :: proc "contextless" (event: principals.Seat_Event, principal: u64 = principals.MACHINE) -> bool {
	next, ok := principals.seat_next(seat, event, principal)
	if !ok {
		system.log_fact(.Warning, Seat_Event_Refused{principal = principal, event_code = u64(event), state_code = u64(seat.state)})
		return false
	}
	seat = next
	return true
}

// seat_unlock_window_settle puts the seat on the window of unlock when the
// chooser holds it and an unlock or a creation runs: a window that a
// session asked for (a change, a proof) leaves the seat to that session.
seat_unlock_window_settle :: proc "contextless" () {
	if seat.state != .Chooser || (unlock_run.stage != .Running && unlock_run.stage != .Stop_Asked) {
		return
	}
	switch unlock_run.mode {
	case .Unlock, .Unlock_Machine_Key_Held, .Create_Principal:
		seat_change(.Unlock_Window_Opened)
	case .Set_Machine_Passphrase, .Seal_Machine_Key, .Change_Passphrase, .New_Recovery_Key, .Machine_Key_Without_Window, .Prove_Wide_Grant, .Remove_Principal:
	}
}

// What the one `unlock` of this service does now. One `unlock` runs at a
// time: two runs would share the ring of the principals and the ring and
// the region of the TPM service.
Unlock_Stage :: enum u8 {
	Stopped, // No `unlock` runs.
	// unlock_start runs start("unlock"): the one moment at which start
	// takes the name. A start by name from a ring or from the desktop is
	// refused.
	Starting,
	Running, // It runs for its mode.
	// It runs, and this service asked its stop (a close of its window, a
	// lock): its stop does not count toward the bound of its restarts.
	Stop_Asked,
}

// The stops of `unlock` that the root service did not ask, while a
// principal is locked, whatever their code, and its starts that failed for
// another cause than a full table, since the last lock or the last start
// of a session. Past the bound, the root service starts it no more while a
// principal is locked, until the machine starts again: a file that stops
// it at once, with any code, must not start it in a loop. A close of its
// window and a stop at a lock are asked by the root service, so they never
// count: closes by mistake never reach the bound.
UNLOCK_RESTART_LIMIT :: 3

// The one `unlock` of this service: its stage, and what each stage reads.
Unlock_Run :: struct {
	stage:        Unlock_Stage,
	// Starting: what start() gives to `unlock` (VALUE_MODE): to unlock, to
	// create the principal with the name below, to set the machine
	// passphrase. Running and Stop_Asked: what it runs for, which the line
	// of a lock that stops it names (principal_lock).
	mode:         principals.Unlock_Mode,
	name:         [principals.NAME_LIMIT]u8, // Starting: the name of the principal to create.
	name_length:  int,
	principal:    u64, // Starting: the number of the principal that asked for a change.
	failed_stops: int, // Below UNLOCK_RESTART_LIMIT: see above.
}

unlock_run: Unlock_Run

// The change in progress: the caller of Principal_Change waits for its
// completion until `unlock` gives the end, or stops (principal_change_end,
// principal_change_forget). One change at a time, as one `unlock` runs.
principal_change_waiting: bool
principal_change_asker: ^Started // nil when the caller stopped: nobody receives the end.
principal_change_tag: u32
principal_change_principal: u64

principal_name :: proc "contextless" (number: u64) -> string {
	if number >= principals.PRINCIPAL_CAPACITY {
		return ""
	}
	record := &principal_records[number]
	return string(record.name[:record.name_length])
}

// desktop_principal gives the principal of a process that the desktop
// starts (the menu, the palette): the principal of the session in front,
// else the machine.
desktop_principal :: proc "contextless" () -> u64 {
	return principals.principal_in_front(seat)
}

// principals_start makes the record of principal 0 from the trust record
// that the boot program wrote (trust.odin read it).
principals_start :: proc "contextless" () {
	persisted_tables_start()
	machine_record := &principal_records[principals.MACHINE]
	machine_record^ = {name_length = len(principals.MACHINE_NAME)}
	seat_change(.Machine_Alone)
	copy(machine_record.name[:], principals.MACHINE_NAME)
	trust := &trust_boot_report.trust
	if trust.measure == u64(info.Measure_State.Measured) {
		machine_record.measured = true
		machine_record.measure = trust.measure_value
		system.log_fact(.Info, Machine_Principal_Measured{measure_register = trust.measure_register, measure_value = value_kinds.Hash_Field(trust.measure_value)})
	} else {
		system.log_fact(.Info, Machine_Principal_Unmeasured{})
	}
}

// unlock_start starts `unlock`: at boot to read its files (with none it
// stops at once, and the machine runs as principal 0 only), after a lock,
// to create a principal, or to set the machine passphrase. A refusal
// writes its record in refusal, when the caller gives one.
unlock_start :: proc "contextless" (mode: principals.Unlock_Mode, name: string, principal: u64 = principals.MACHINE, refusal: ^[7]u64 = nil) -> call_outcome.Call_Outcome {
	own_refusal: [7]u64
	record := refusal != nil ? refusal : &own_refusal
	// An `unlock` that runs keeps its stage: it is reaped first.
	outcome := root_ring.refuse(record, .Callee_Busy, u32(root_ring.Root_Command.Start), .Busy, .Processes, 1, 1, 1)
	if unlock_run.stage == .Stopped {
		record^ = {}
		unlock_run.stage = .Starting
		unlock_run.mode = mode
		unlock_run.name_length = copy(unlock_run.name[:], name)
		unlock_run.principal = principal
		outcome = start("unlock", refusal = record)
		unlock_run.name = {}
		unlock_run.name_length = 0
		unlock_run.principal = principals.MACHINE
		unlock_run.stage = outcome == .Succeeded ? .Running : .Stopped
		if outcome == .Succeeded && mode == .Create_Principal {
			session_change(1, .Creation_Begun)
		}
		seat_unlock_window_settle()
	}
	if outcome != .Succeeded {
		system.log_fact(.Warning, Unlock_Start_Failed{outcome = outcome})
	}
	return outcome
}

// unlock_values_write writes the values of the context of the `unlock`
// that starts: its mode, the name of the principal to create, and the number
// of the principal that asked for a change. After a lock this service holds
// the key of the table of principal 0: unlock does not ask for the machine
// passphrase again.
unlock_values_write :: proc "contextless" (values: ^system.Context_Values) {
	start_mode := unlock_run.mode
	if start_mode == .Unlock && machine_key_held() {
		start_mode = .Unlock_Machine_Key_Held
	}
	system.value_put(values, system.GRANT_VALUE_UNLOCK_MODE, u64(start_mode))
	packed := principals.name_pack(string(unlock_run.name[:unlock_run.name_length]))
	system.values_put(values, system.GRANT_VALUE_UNLOCK_NAME, packed[:])
	system.value_put(values, system.GRANT_VALUE_UNLOCK_PRINCIPAL, unlock_run.principal)
}

// unlock_without_window says if a start of a name is the start of `unlock`
// that reads the machine key before the start policy: it gets no window.
unlock_without_window :: proc "contextless" (name: string) -> bool {
	return name == "unlock" && unlock_run.stage == .Starting && unlock_run.mode == .Machine_Key_Without_Window
}

// unlock_without_window_running says if a place of the table holds the run
// of `unlock` that reads the machine key before the start policy. It is
// read before unlock_stopped changes the stage.
unlock_without_window_running :: proc "contextless" (item: ^Started) -> bool {
	running := unlock_run.stage == .Running || unlock_run.stage == .Stop_Asked
	return running && unlock_run.mode == .Machine_Key_Without_Window && !item.is_terminal && system.name_of(item.name[:]) == "unlock"
}

// unlock_stop_ask says that this service asks the stop of the `unlock`
// that runs: its stop does not count.
unlock_stop_ask :: proc "contextless" () {
	if unlock_run.stage == .Running {
		unlock_run.stage = .Stop_Asked
	}
}

// unlock_creating says if the `unlock` that runs creates a named
// principal: a reader of the records sees the state Creating, and the first
// record that it gives is a record of this run.
unlock_creating :: proc "contextless" () -> bool {
	return (unlock_run.stage == .Running || unlock_run.stage == .Stop_Asked) && unlock_run.mode == .Create_Principal
}

// A creation never runs during a session while the system holds one named
// principal: it needs the record of principal 1 absent, so no session runs,
// and the lock never stops a creation. With more places, a lock of another
// session stops it; nothing is written before Enter, but a stop between the
// file and its record must then be designed
// (src/md/features/tpm_sealed_principal_keys.md).
#assert(principals.PRINCIPAL_CAPACITY == 2)

// principal_create starts `unlock` to create a named principal.
principal_create :: proc "contextless" (name: string, values: ^[7]u64) -> call_outcome.Call_Outcome {
	kind := u32(root_ring.Root_Command.Principal_Create)
	if principals.name_problem(name) != .None {
		return root_ring.refuse(values, .Argument_Refused, kind, .Bad_Value, .None, 1)
	}
	if principal_records[1].state == .Creating {
		return root_ring.refuse(values, .Callee_Busy, kind, .Busy, .Requests, 0, 1, 1)
	}
	// A slot freed by removal stays retired for the rest of this boot run so
	// no stale handle can alias a newly created principal.
	if !principals.slot_creation_allowed(&retired_slots, 1) {
		return root_ring.refuse(values, .Wrong_State, kind, .State, .Principals, 0, 1)
	}
	// One named principal: several are not built.
	if principal_records[1].state != .Absent {
		return root_ring.refuse(values, .Budget_Or_Capacity_Exhausted, kind, .Full, .Principals, 0, 0, principals.PRINCIPAL_CAPACITY - 1)
	}
	if find("unlock") != nil {
		return root_ring.refuse(values, .Callee_Busy, kind, .Busy, .Requests, 0, 1, 1)
	}
	system.log_fact(.Info, Principal_Creation_Started{principal_name = text_field(name, 24)})
	return unlock_start(.Create_Principal, name, refusal = values)
}

// principal_record takes the public part of the record of a named
// principal from `unlock`: values[0..3] its public key, values[4..6] its
// name. The values are a copy in this service: `unlock` cannot change them.
principal_record :: proc "contextless" (values: [7]u64, completion: ^[7]u64) -> call_outcome.Call_Outcome {
	kind := u32(root_ring.Root_Command.Principal_Record)
	public_key := transmute([32]u8)([4]u64{values[0], values[1], values[2], values[3]})
	name, name_length := principals.name_unpack({values[4], values[5], values[6]})
	if principals.name_problem(string(name[:name_length])) != .None {
		return root_ring.refuse(completion, .Argument_Refused, kind, .Bad_Value, .None, 5)
	}
	record := &principal_records[1]
	if record.state != .Absent && record.state != .Creating {
		// The same record again (a second start of `unlock`) has the same
		// number; another one has no place.
		if record.public_key != public_key || string(record.name[:record.name_length]) != string(name[:name_length]) {
			return root_ring.refuse(completion, .Budget_Or_Capacity_Exhausted, kind, .Full, .Principals, 0, 0, principals.PRINCIPAL_CAPACITY - 1)
		}
		completion^[0] = 1
		return .Succeeded
	}
	if !session_change(1, .Record_Given) {
		return root_ring.refuse(completion, .Wrong_State, kind, .State, .Principals, 0, 1)
	}
	record^ = {state = record.state, name = name, name_length = name_length, public_key = public_key}
	seat_change(.Named_Principal_Recorded)
	seat_unlock_window_settle()
	// Only a record that `unlock` made in this run lets its first key write
	// over a table that does not verify (principal_key_take).
	principal_created_in_this_run[1] = unlock_creating()
	completion^[0] = 1
	digits := system_description.hexadecimal(public_key)
	system.log_fact(.Info, Principal_Recorded{principal_name = text_field(principal_name(1), 24), public_key_head = text_field(string(digits[:16]), 24)})
	return .Succeeded
}

// principal_identifier takes the principal identifier of a record from
// `unlock`: values[0..3] the identifier, values[4] the number. The values
// are a copy in this service. A record keeps its first identifier: a second
// one is refused, as a file of another principal would be.
principal_identifier :: proc "contextless" (values: [7]u64, completion: ^[7]u64) -> call_outcome.Call_Outcome {
	kind := u32(root_ring.Root_Command.Principal_Identifier)
	number := values[4]
	for index in 5 ..< len(values) {
		if values[index] != 0 {
			completion^ = root_ring.word_refusal(.Principal_Identifier, i64(index) + 1, values[index], 0)
			return .Argument_Refused
		}
	}
	if number == principals.MACHINE || number >= principals.PRINCIPAL_CAPACITY || principal_records[number].state == .Absent || principal_records[number].state == .Creating {
		return root_ring.refuse(completion, .Nothing_Has_That_Name, kind, .Absent, .Principals, 5, i64(min(number, 1 << 62)))
	}
	identifier := transmute(principals.Principal_Identifier)([4]u64{values[0], values[1], values[2], values[3]})
	if principals.identifier_is_zero(identifier[:]) {
		return root_ring.refuse(completion, .Argument_Refused, kind, .Bad_Value, .None, 1)
	}
	record := &principal_records[number]
	if !principals.identifier_is_zero(record.identifier[:]) {
		if record.identifier != identifier {
			return root_ring.refuse(completion, .Wrong_State, kind, .State, .Principals, 5, i64(number))
		}
		return .Succeeded
	}
	record.identifier = identifier
	return .Succeeded
}

// storage_holder gives the process that holds the role Storage, or nil.
storage_holder :: proc "contextless" () -> ^Started {
	for &item in started {
		if item.process != 0 && item.service.head != nil && is_role_holder(system.name_of(item.name[:]), .Storage) {
			return &item
		}
	}
	return nil
}

// principal_storage_key passes the storage key of a named principal from
// `unlock` to the holder of Storage, with its identifier, and keeps no copy
// (src/md/features/store_encryption.md, "The keys"). values[0..3] the key,
// values[4] the number; this service erases them.
principal_storage_key :: proc "contextless" (values: ^[7]u64, completion: ^[7]u64) -> call_outcome.Call_Outcome {
	kind := u32(root_ring.Root_Command.Principal_Storage_Key)
	defer intrinsics.mem_zero_volatile(values, size_of(values^))
	number := values[4]
	record_state := principals.Session_State.Absent
	identifier_zero := true
	if number < principals.PRINCIPAL_CAPACITY {
		record_state = principal_records[number].state
		identifier_zero = principals.identifier_is_zero(principal_records[number].identifier[:])
	}
	holder := storage_holder()
	ring_free: u32
	if holder != nil {
		ring_free = ring.capacity(&holder.service.commands) - ring.count(&holder.service.commands)
	}
	decision := principal_unlock_flow.storage_key_check(&storage_key_flow, values^, record_state, identifier_zero, holder != nil, ring_free)
	if !decision.send {
		completion^ = decision.refusal
		return decision.outcome
	}
	// The identity first: a key with no identity before it is refused by
	// the storage service, and an identity with no key opens nothing. The
	// storage service erases the slot of each record that it takes; the copy
	// here is erased at once.
	identifier := transmute([4]u64)principal_records[number].identifier
	key_record := ring.Record{kind = u32(isolated.Service_Command.Principal_Storage_Key), values = {values[0], values[1], values[2], values[3], number, 0, 0}}
	defer intrinsics.mem_zero_volatile(&key_record, size_of(key_record))
	identity_sent := system.send(&holder.service.commands, ring.Record{kind = u32(isolated.Service_Command.Principal_Identity), values = {identifier[0], identifier[1], identifier[2], identifier[3], number, 0, 0}})
	key_sent := identity_sent && system.send(&holder.service.commands, key_record)
	succeeded, owe_erase := principal_unlock_flow.storage_key_sent(&storage_key_flow, number, identity_sent, key_sent)
	if !succeeded {
		if owe_erase {
			storage_erase_owe(number)
		}
		return root_ring.refuse(completion, .Callee_Busy, kind, .Busy, .Requests, 0, 1, 1)
	}
	return .Succeeded
}

// The tracking of awaiting storage keys and owed erases for each principal
// slot: a lock or a failed or abandoned unlock owes the erase, which the
// main loop sends again until the storage ring takes it.
storage_key_flow: principal_unlock_flow.Flow

// storage_erase_owe owes the erase of the keys of a slot, and sends it now
// if the ring has room.
storage_erase_owe :: proc "contextless" (number: u64) {
	principal_unlock_flow.erase_owe(&storage_key_flow, number)
	if !storage_erase_send(number) {
		system.log_fact(.Warning, Storage_Lock_Not_Sent{principal = number})
	}
}

// storage_erase_send sends an owed erase. A storage service that stopped
// took its keys with its memory: nothing is owed to it.
@(private = "file")
storage_erase_send :: proc "contextless" (number: u64) -> bool {
	holder := storage_holder()
	sent := holder != nil && system.send(&holder.service.commands, ring.Record{kind = u32(isolated.Service_Command.Principal_Locked), values = {4 = number}})
	return principal_unlock_flow.erase_attempt(&storage_key_flow, number, holder != nil, sent)
}

// storage_erase_step sends each owed erase again, and waits for room in the
// ring of the storage service while one is still owed. The main loop calls
// it at each pass.
storage_erase_step :: proc "contextless" (wait: ^system.Wait) {
	still_owed := false
	for owed, number in storage_key_flow.erase_owed {
		if owed && !storage_erase_send(u64(number)) {
			still_owed = true
		}
	}
	if still_owed {
		if holder := storage_holder(); holder != nil {
			system.wait_room(wait, &holder.service.commands)
		}
	}
}

// storage_principal_locked tells the holder of Storage that the session of
// a principal ended: it erases its keys. A full ring owes the erase, which
// the main loop sends again until the ring takes it.
storage_principal_locked :: proc "contextless" (number: u64) {
	storage_erase_owe(number)
}

// In-flight orphaned store reclamation request forwarded from `unlock` to
// Storage. One request runs at a time (as one `unlock` runs).
reclaim_waiting: bool
reclaim_asker: ^Started
reclaim_asker_tag: u32
reclaim_service_tag: u32

// principal_stores_reclaim forwards Root_Command.Principal_Stores_Reclaim from
// `unlock` to the Storage holder: validates the slot and identifier, sends
// Principal_Locked(slot) followed by Principal_Reclaim(id, slot), and holds
// the caller's completion until Storage replies on its service completions ring.
principal_stores_reclaim :: proc "contextless" (asker: ^Started, tag: u32, values: [7]u64, completion: ^[7]u64) -> (outcome: call_outcome.Call_Outcome, held: bool) {
	kind := u32(root_ring.Root_Command.Principal_Stores_Reclaim)
	for index in 5 ..< len(values) {
		if values[index] != 0 {
			completion^ = root_ring.word_refusal(.Principal_Stores_Reclaim, i64(index) + 1, values[index], 0)
			return .Argument_Refused, false
		}
	}
	number := values[4]
	if number == principals.MACHINE || number >= principals.PRINCIPAL_CAPACITY {
		return root_ring.refuse(completion, .Argument_Refused, kind, .Bad_Value, .Principals, 2, i64(min(number, 1 << 62)), principals.PRINCIPAL_CAPACITY - 1), false
	}
	identifier := transmute(principals.Principal_Identifier)([4]u64{values[0], values[1], values[2], values[3]})
	if principals.identifier_is_zero(identifier[:]) {
		return root_ring.refuse(completion, .Argument_Refused, kind, .Bad_Value, .None, 1), false
	}
	// If the slot holds a live principal record with another identifier,
	// refuse rather than locking or touching another principal's stores.
	record := &principal_records[number]
	if record.state != .Absent && !principals.identifier_is_zero(record.identifier[:]) && record.identifier != identifier {
		return root_ring.refuse(completion, .Wrong_State, kind, .State, .Principals, 2, i64(number)), false
	}
	if reclaim_waiting {
		return root_ring.refuse(completion, .Callee_Busy, kind, .Busy, .Requests, 0, 1, 1), false
	}
	holder := storage_holder()
	if holder == nil {
		return root_ring.refuse(completion, .Callee_Unavailable, kind, .Absent, .Services), false
	}
	if ring.capacity(&holder.service.commands) - ring.count(&holder.service.commands) < 2 {
		return root_ring.refuse(completion, .Callee_Busy, kind, .Busy, .Requests, 0, 1, 1), false
	}
	reclaim_service_tag += 1
	if reclaim_service_tag == 0 {
		reclaim_service_tag = 1
	}
	// Lock the slot first on the FIFO service ring so Storage erases the slot's
	// keys before validating and marking the removed principal's stores.
	locked_sent := system.send(&holder.service.commands, ring.Record{kind = u32(isolated.Service_Command.Principal_Locked), values = {4 = number}})
	reclaim_sent := locked_sent && system.send(&holder.service.commands, ring.Record{kind = u32(isolated.Service_Command.Principal_Reclaim), tag = reclaim_service_tag, values = values})
	if !reclaim_sent {
		if locked_sent {
			storage_erase_owe(number)
		}
		return root_ring.refuse(completion, .Callee_Busy, kind, .Busy, .Requests, 0, 1, 1), false
	}
	reclaim_waiting = true
	reclaim_asker = asker
	reclaim_asker_tag = tag
	return .Succeeded, true
}

// storage_reclaim_step drains completions from Storage's service ring and
// forwards the matching Principal_Reclaim result to the waiting caller.
storage_reclaim_step :: proc "contextless" (wait: ^system.Wait) {
	if !reclaim_waiting {
		return
	}
	holder := storage_holder()
	if holder == nil {
		storage_reclaim_complete(.Callee_Unavailable, {})
		return
	}
	for {
		record, ok := root_receive(&holder.service.completions, system.name_of(holder.name[:]))
		if !ok {
			break
		}
		if record.tag != reclaim_service_tag {
			continue
		}
		outcome, unreadable := call_outcome.outcome_of_word(u64(record.kind))
		values := outcome == .Answer_Unreadable ? errors.completion_values(unreadable) : record.values
		storage_reclaim_complete(outcome, values)
		return
	}
	if reclaim_waiting {
		system.wait_records(wait, &holder.service.completions)
	}
}

@(private = "file")
storage_reclaim_complete :: proc "contextless" (outcome: call_outcome.Call_Outcome, values: [7]u64) {
	asker := reclaim_asker
	tag := reclaim_asker_tag
	reclaim_waiting = false
	reclaim_asker = nil
	reclaim_asker_tag = 0
	if asker != nil && asker.process != 0 && asker.requests.head != nil {
		_ = system.send(&asker.requests.completions, ring.Record{kind = u32(outcome), tag = tag, values = values})
	}
}

// storage_reclaim_forget clears the caller if it stops, or fails the request
// back to the caller if the Storage holder stops while a reclaim is in flight.
storage_reclaim_forget :: proc "contextless" (item: ^Started) {
	if !reclaim_waiting {
		return
	}
	if reclaim_asker == item {
		reclaim_asker = nil
	}
	if is_role_holder(system.name_of(item.name[:]), .Storage) {
		storage_reclaim_complete(.Callee_Unavailable, {})
	}
}

// principal_unlock starts the session of a named principal: from now on the
// desktop starts each process in it. values[4] is its number; values[0..3]
// and values[5] are the key of the tag of its disk grant table and its
// origin, which this service takes before the session starts
// (principal_key_take). A refusal writes its own error record in
// completion: the values of the command hold a key where a name would be,
// so the record of `refusal` is never built from them.
principal_unlock :: proc "contextless" (values: ^[7]u64, completion: ^[7]u64) -> call_outcome.Call_Outcome {
	number := values[4]
	outcome := principal_unlock_checked(values, completion)
	// The storage key of this unlock was sent: a session that did not start
	// leaves no key in the storage service.
	if principal_unlock_flow.unlock_finished(&storage_key_flow, number, outcome == .Succeeded) {
		storage_erase_owe(number)
	}
	return outcome
}

@(private = "file")
principal_unlock_checked :: proc "contextless" (values: ^[7]u64, completion: ^[7]u64) -> call_outcome.Call_Outcome {
	kind := u32(root_ring.Root_Command.Principal_Unlock)
	number := values[4]
	record_state := principals.Session_State.Absent
	identifier_zero := true
	if number < principals.PRINCIPAL_CAPACITY {
		record_state = principal_records[number].state
		identifier_zero = principals.identifier_is_zero(principal_records[number].identifier[:])
	}
	// The seat before the key: a seat that refuses the session takes no key
	// of it.
	precheck := principal_unlock_flow.unlock_precheck(number, record_state, identifier_zero, seat)
	if !precheck.ok {
		completion^ = precheck.refusal
		return precheck.outcome
	}
	if outcome := principal_key_take(number, values, completion); outcome != .Succeeded {
		return outcome
	}
	// The seat first: a refusal there leaves the session locked. The state
	// was checked Locked above, so the session then changes.
	if !seat_change(.Session_Unlocked, number) || !session_change(number, .Unlocked) {
		return root_ring.refuse(completion, .Wrong_State, kind, .State, .Principals, 2, i64(number))
	}
	// Reserve the session's child kernel budget and storage block quota so
	// session processes hit the session limit before any machine limit.
	session_budget_open(number)
	// The client keys that the principal allowed take calls again.
	remote_clients_session_changed(number, false)
	// The proofs of wide grants not given count from 0 again.
	wide_grant_principal_unlocked(number) // wide_grant_authority.odin
	unlock_run.failed_stops = 0
	system.log_fact(.Info, Session_Started{principal = number, principal_name = text_field(principal_name(number), 24)})
	return .Succeeded
}

// principal_lock ends the session that runs: each process of the session
// stops (a frozen process needs a kernel operation that does not exist),
// and `unlock` starts again. completion[0] is the count of the processes
// stopped.
principal_lock :: proc "contextless" (completion: ^[7]u64) -> call_outcome.Call_Outcome {
	number := desktop_principal()
	// No session of a named principal runs: nothing to lock.
	if number == principals.MACHINE {
		return root_ring.refuse(completion, .Nothing_Has_That_Name, u32(root_ring.Root_Command.Principal_Lock), .Absent, .Principals)
	}
	// A wide grant of the principal ends at the lock, with its reason. Its
	// collector stops when the end settled, after its record of the end.
	wide_grant_principal_locked(number) // wide_grant_authority.odin
	count: u64
	for &item in started {
		if item.process != 0 && item.principal == number {
			if wide_grant_collector_held_at_lock(&item) {
				count += 1
				continue
			}
			started_process_stop(&item)
			if !item.is_terminal {
				count += 1
			}
		}
	}
	session_change(number, .Locked)
	seat_change(.Session_Locked, number)
	session_budget_close(number)
	storage_principal_locked(number)
	// A call from another machine acts for no principal whose session is
	// locked: the connections of its client keys end.
	remote_clients_session_changed(number, true)
	completion^[0] = count
	system.log_fact(.Info, Session_Ended{principal = number, stopped_processes = count, principal_name = text_field(principal_name(number), 24)})
	unlock_run.failed_stops = 0
	// One `unlock` runs at a time. During a session only the session can
	// have asked for it (a change, a machine passphrase, a seal of the
	// machine key), so it stops with the session, whatever its mode: else
	// anyone at the keyboard of the locked machine would read its recovery
	// key or set the machine passphrase. Each window that shows a recovery
	// key writes nothing before Enter, so the stop loses no key that
	// nobody wrote down (src/md/features/tpm_sealed_principal_keys.md).
	// The `unlock` of the lock starts after the reap
	// (unlock_for_a_locked_principal).
	if running := find("unlock"); running != nil {
		unlock_stop_ask()
		started_process_stop(running)
		system.log_fact(.Info, Unlock_Stopped_By_Lock{unlock_mode = text_field(principals.mode_words(unlock_run.mode), 40)})
	}
	// Tear down the display holder of the locked session and start a fresh one
	// after reap so no clipboard, palette ranking, glyph cache, or notification
	// state crosses the session boundary; unlock_for_a_locked_principal then
	// opens unlock on the fresh display holder.
	if display_holder_restart_request() {
		return .Succeeded
	}
	if find("unlock") != nil {
		return .Succeeded
	}
	unlock_start(.Unlock, "")
	return .Succeeded
}

// unlock_stopped counts a stop of `unlock` that reap found: each stop
// while a principal is locked, whatever its code, unless the root service
// asked it. An `unlock` that stops at once with `Done` (a store that
// lost the file of a principal whose record is locked) must be bounded as
// a fault is.
unlock_stopped :: proc "contextless" () {
	// A creation that stopped before it gave its record created nothing:
	// the stage Stopped says that no `unlock` creates.
	asked := unlock_run.stage == .Stop_Asked
	unlock_run.stage = .Stopped
	// An unlock that stopped between its key and its session owes its erase.
	for owed, number in principal_unlock_flow.unlock_stopped_collect(&storage_key_flow) {
		if owed {
			storage_erase_owe(u64(number))
		}
	}
	if principal_records[1].state == .Creating {
		session_change(1, .Creation_Abandoned)
	}
	if seat.state == .Unlock_Window {
		seat_change(.Unlock_Window_Closed)
	}
	// The run that proves a wide grant ends by itself, and unlocks nothing:
	// its stop is no failed unlock.
	if asked || !principal_locked() || unlock_run.mode == .Prove_Wide_Grant {
		return
	}
	unlock_run.failed_stops += 1
	if unlock_run.failed_stops == UNLOCK_RESTART_LIMIT {
		system.log_fact(.Warning, Unlock_Restarts_Given_Up{restart_limit = u64(UNLOCK_RESTART_LIMIT)})
	}
}

// principal_locked says if a named principal has a record and no session.
principal_locked :: proc "contextless" () -> bool {
	for &record, number in principal_records {
		if number != principals.MACHINE && record.state == .Locked {
			return true
		}
	}
	return false
}

// unlock_for_a_locked_principal keeps one rule after each reap: a named
// principal that is locked has a window of `unlock`. A lock, a close of
// that window, a stop of `unlock` during a change and a start that failed
// all reach the same rule, so no path leaves the principal locked with no
// way in. The main loop calls it after each reap.
unlock_for_a_locked_principal :: proc "contextless" () {
	if !principal_locked() || find("unlock") != nil || unlock_run.failed_stops >= UNLOCK_RESTART_LIMIT {
		return
	}
	// With no screen nobody can type the passphrase: the `unlock` of the
	// boot said so in its line, and a new one would say it again.
	if desktop_absent() {
		return
	}
	// A full table is not counted: a slot comes free only with a stop, and
	// a stop is an event, so the next pass tries again with no hot loop.
	if outcome := unlock_start(.Unlock, ""); outcome != .Succeeded && outcome != .Callee_Busy {
		unlock_run.failed_stops += 1
	}
}

// principal_change_end runs the command Principal_Change_End, which only
// `unlock` sends: the change ended. The end goes to the caller of
// Principal_Change.
principal_change_end :: proc "contextless" (values: [7]u64, completion: ^[7]u64) -> call_outcome.Call_Outcome {
	kind := u32(root_ring.Root_Command.Principal_Change_End)
	// No change waits for its end.
	if !principal_change_waiting {
		return root_ring.refuse(completion, .Wrong_State, kind, .State, .Requests)
	}
	end, end_outcome, end_refusal := root_ring.member_of_word(principals.Change_End, values[4], .Principal_Change_End, 2)
	if end_outcome != .Succeeded {
		completion^ = end_refusal
		return end_outcome
	}
	problem, problem_outcome, problem_refusal := root_ring.member_of_word(principals.Change_Problem, values[5], .Principal_Change_End, 3)
	if problem_outcome != .Succeeded {
		completion^ = problem_refusal
		return problem_outcome
	}
	principal_change_finish(end, problem)
	return .Succeeded
}

// principal_change_finish gives the end of the change to its caller, when
// it still runs, and ends the change. When `end` is `.Principal_Removed`,
// the root service tears down the session, revokes its keys, retires the slot
// for this run, and restarts the display holder.
principal_change_finish :: proc "contextless" (end: principals.Change_End, problem: principals.Change_Problem) {
	principal_change_waiting = false
	changed_principal := principal_change_principal
	principal_change_principal = principals.MACHINE
	system.log_fact(.Info, Principal_Change_Ended{change_end = text_field(principals.change_end_sentences[end], 64)})
	asker := principal_change_asker
	principal_change_asker = nil
	if asker != nil && asker.process != 0 && asker.requests.head != nil {
		if !system.send(&asker.requests.completions, ring.Record{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = principal_change_tag, values = {0 = u64(end), 1 = u64(problem)}}) {
			system.log_fact(.Warning, Change_End_Not_Delivered{caller = module_name_field(system.name_of(asker.name[:]))})
		}
	}
	if end == .Principal_Removed && changed_principal != principals.MACHINE && changed_principal < principals.PRINCIPAL_CAPACITY {
		principal_remove_finish(changed_principal)
	}
}

// principal_remove_finish tears down a removed named principal: transitions
// to Removing, stops all session processes, closes its session budget, clears
// its storage and client keys, retires the slot for this run, updates the
// seat, and requests a fresh display holder.
@(private = "file")
principal_remove_finish :: proc "contextless" (number: u64) {
	session_change(number, .Removal_Begun)
	wide_grant_principal_locked(number)
	count: u64
	for &item in started {
		if item.process != 0 && item.principal == number {
			if wide_grant_collector_held_at_lock(&item) {
				count += 1
				continue
			}
			started_process_stop(&item)
			if !item.is_terminal {
				count += 1
			}
		}
	}
	session_budget_close(number)
	storage_principal_locked(number)
	remote_clients_principal_removed(number)
	persisted_tables[number] = {state = .Awaited}
	principal_created_in_this_run[number] = false
	principals.slot_retire(&retired_slots, number)
	record_state := principal_records[number].state
	principal_records[number] = {state = record_state}
	session_change(number, .Removal_Finished)
	seat_change(.Session_Removed, number)
	any_named := false
	for idx in u64(1) ..< principals.PRINCIPAL_CAPACITY {
		if principal_records[idx].state != .Absent {
			any_named = true
			break
		}
	}
	if !any_named {
		seat_change(.Last_Named_Principal_Removed, principals.MACHINE)
	}
	remote_clients_front_follow()
	system.log_fact(.Info, Principal_Removed{principal = number, stopped_processes = count})
	_ = display_holder_restart_request()
}

// principal_change_forget takes a process that stops out of the change:
// a caller that stops receives nothing, and an `unlock` that stops before
// it gave the end gives the end None to the caller.
principal_change_forget :: proc "contextless" (item: ^Started) {
	if !principal_change_waiting {
		return
	}
	if principal_change_asker == item {
		principal_change_asker = nil
	}
	if system.name_of(item.name[:]) == "unlock" {
		principal_change_finish(.None, .None)
	}
}

// principal_change runs the command Principal_Change: it starts `unlock` to
// change the passphrase of the principal of the session of the caller, to
// make it a new recovery key, or to remove the principal. The caller acts for
// that principal, and its session runs: the console of principal 0 cannot ask
// for a named principal. The window asks for the current passphrase before any
// change (src/md/features/tpm_sealed_principal_keys.md). values is the
// completion: an error record for a refusal. A change that starts holds
// the completion until it ends (principal_change_finish).
principal_change :: proc "contextless" (caller: ^Started, tag: u32, change: u64, values: ^[7]u64) -> (outcome: call_outcome.Call_Outcome, held: bool) {
	outcome, held = principal_change_begin(caller, change, values)
	if held {
		principal_change_waiting = true
		principal_change_asker = caller
		principal_change_tag = tag
		principal_change_principal = caller.principal
	}
	return
}

principal_change_begin :: proc "contextless" (caller: ^Started, change: u64, values: ^[7]u64) -> (outcome: call_outcome.Call_Outcome, held: bool) {
	kind := u32(root_ring.Root_Command.Principal_Change)
	if .Acts_For_Principal not_in grants_held(caller) {
		return root_ring.refuse(values, .Grant_Or_Right_Missing, kind, .No_Grant, .Acts_For_Principal, 1), false
	}
	asked, asked_outcome, asked_refusal := root_ring.member_of_word(root_ring.Principal_Change, change, .Principal_Change, 2)
	if asked_outcome != .Succeeded {
		values^ = asked_refusal
		return asked_outcome, false
	}
	mode: principals.Unlock_Mode
	switch asked {
	case .Passphrase:
		mode = .Change_Passphrase
	case .Recovery_Key:
		mode = .New_Recovery_Key
	case .Remove:
		mode = .Remove_Principal
	}
	number := caller.principal
	if number == principals.MACHINE || number >= principals.PRINCIPAL_CAPACITY || principal_records[number].state != .In_Front {
		system.log_fact(.Warning, Passphrase_Change_Refused_No_Session{})
		return root_ring.refuse(values, .Nothing_Has_That_Name, kind, .Absent, .Principals), false
	}
	// A change that waits for its end is a change whose `unlock` runs, or
	// is not reaped yet: one at a time.
	if find("unlock") != nil || principal_change_waiting {
		system.log_fact(.Warning, Passphrase_Change_Refused_Unlock_Runs{})
		return root_ring.refuse(values, .Callee_Busy, kind, .Busy, .Requests, 0, 1, 1), false
	}
	switch asked {
	case .Passphrase:
		system.log_fact(.Info, Passphrase_Change_Started{principal = number, principal_name = text_field(principal_name(number), 24)})
	case .Recovery_Key:
		system.log_fact(.Info, Recovery_Key_Change_Started{principal = number, principal_name = text_field(principal_name(number), 24)})
	case .Remove:
		system.log_fact(.Info, Principal_Removal_Started{principal = number, principal_name = text_field(principal_name(number), 24)})
	}
	if started := unlock_start(mode, "", number, values); started != .Succeeded {
		return started, false
	}
	return .Succeeded, true
}

// principal_read gives a record: values[0] its state, values[1..4] its
// name, values[5] the first 8 bytes of its public key, values[6] for
// principal 0 the first 8 bytes of the measure of the system (0: not
// measured).
principal_read :: proc "contextless" (number: u64, completion: ^[7]u64) -> call_outcome.Call_Outcome {
	kind := u32(root_ring.Root_Command.Principals)
	if number >= principals.PRINCIPAL_CAPACITY {
		return root_ring.refuse(completion, .Nothing_Has_That_Name, kind, .Absent, .Principals, 2, i64(min(number, 1 << 62)))
	}
	record := &principal_records[number]
	state := principals.principal_state_word(number, record.state)
	if state == .Absent {
		return root_ring.refuse(completion, .Nothing_Has_That_Name, kind, .Absent, .Principals, 2, i64(number))
	}
	packed := system.name_pack(string(record.name[:record.name_length]))
	key := transmute([4]u64)record.public_key
	measure := transmute([4]u64)record.measure
	completion^ = {u64(state), packed[0], packed[1], packed[2], packed[3], key[0], record.measured ? measure[0] : 0}
	return .Succeeded
}

// For each principal: its record was made by a creation in this run of the
// machine, not read from a file that existed. Only such a principal can
// give a key of the origin Principal_Key_Origin.New.
principal_created_in_this_run: [principals.PRINCIPAL_CAPACITY]bool
