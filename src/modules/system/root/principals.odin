package root

import "modus:contract/errors"
import "modus:contract/ring"
import "modus:contract/system_description"
import "modus:support/principals"
import "modus:contract/root_ring"
import "modus:support/system"

// The principals in the root service (docs/PRINCIPALS.md).
//
// The kernel knows no principal: a program acts with the handles that it
// holds. This service holds one record for each principal, and records for
// each program that it starts the principal whose session the program
// belongs to. It names that principal in each connection (the grant of the
// Connect command), in the name of the store of the program, and in the
// grants of the program.
//
// Principal 0 is the machine: its record exists at each boot, from the
// trust record of the boot program, and its session needs no unlock. With
// no named principal the system runs as principal 0 only.
//
// One named principal: the program `unlock` keeps its record in its own
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
	state:       root_ring.Principal_State,
	name:        [principals.NAME_LIMIT]u8,
	name_length: int,
	public_key:  [32]u8, // Ed25519: the key that signs the grants of the principal. Principal 0: none in this system yet.
	measured:    bool, // Principal 0: the boot program measured the system into PCR 11.
	measure:     [32]u8, // Principal 0: the value of PCR 11.
}

principal_records: [principals.PRINCIPAL_CAPACITY]Principal_Record

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
	failed_stops: int, // Below UNLOCK_RESTART_LIMIT: see above.
}

unlock_run: Unlock_Run

// The change in progress: the caller of Principal_Change waits for its
// completion until `unlock` gives the end, or stops (principal_change_end,
// principal_change_forget). One change at a time, as one `unlock` runs.
principal_change_waiting: bool
principal_change_asker: ^Started // nil when the caller stopped: nobody receives the end.
principal_change_tag: u32

principal_name :: proc "contextless" (number: u64) -> string {
	if number >= principals.PRINCIPAL_CAPACITY {
		return ""
	}
	record := &principal_records[number]
	return string(record.name[:record.name_length])
}

// desktop_principal gives the principal of a program that the desktop
// starts (the menu, the palette): the named principal whose session runs,
// else the machine.
desktop_principal :: proc "contextless" () -> u64 {
	for &record, number in principal_records {
		if number != principals.MACHINE && record.state == .Unlocked {
			return u64(number)
		}
	}
	return principals.MACHINE
}

// principals_start makes the record of principal 0 from the trust record
// that the boot program wrote (trust.odin read it).
principals_start :: proc "contextless" () {
	persisted_tables_start()
	machine_record := &principal_records[principals.MACHINE]
	machine_record^ = {state = .Machine, name_length = len(principals.MACHINE_NAME)}
	copy(machine_record.name[:], principals.MACHINE_NAME)
	trust := &trust_boot_report.trust
	if trust.measure == .Measured {
		machine_record.measured = true
		machine_record.measure = trust.measure_value
		digits := system_description.hexadecimal(trust.measure_value)
		system.log("root: principal 0 is the machine: the system is measured, PCR ", trust.measure_register, " = ", string(digits[:]), "; its key, the attestation key of the TPM, is not built")
	} else {
		system.log("root: principal 0 is the machine: the system is not measured; its key, the attestation key of the TPM, is not built")
	}
}

// unlock_start starts `unlock`: at boot to read its files (with none it
// stops at once, and the machine runs as principal 0 only), after a lock,
// to create a principal, or to set the machine passphrase.
unlock_start :: proc "contextless" (mode: principals.Unlock_Mode, name: string) -> system.Status {
	status := system.Status.Bad_State
	// An `unlock` that runs keeps its stage: it is reaped first.
	if unlock_run.stage == .Stopped {
		unlock_run.stage = .Starting
		unlock_run.mode = mode
		unlock_run.name_length = copy(unlock_run.name[:], name)
		status = start("unlock")
		unlock_run.name = {}
		unlock_run.name_length = 0
		unlock_run.stage = status == .Ok ? .Running : .Stopped
	}
	if status != .Ok {
		system.log_in("programs", .Warning, "root: unlock did not start (status ", status, "): no named principal can be created or unlocked")
	}
	return status
}

// unlock_values_write writes the values of the context of the `unlock`
// that starts: its mode and the name of the principal to create. After a
// lock this service holds the key of the table of principal 0: unlock
// does not ask for the machine passphrase again.
unlock_values_write :: proc "contextless" (values: ^system.Context_Values) {
	start_mode := unlock_run.mode
	if start_mode == .Unlock && machine_key_held() {
		start_mode = .Unlock_Machine_Key_Held
	}
	system.value_put(values, system.GRANT_VALUE_UNLOCK_MODE, u64(start_mode))
	packed := principals.name_pack(string(unlock_run.name[:unlock_run.name_length]))
	system.values_put(values, system.GRANT_VALUE_UNLOCK_NAME, packed[:])
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
principal_create :: proc "contextless" (name: string) -> system.Status {
	if principals.name_problem(name) != .None {
		return .Bad_Operation
	}
	if principal_records[1].state != .Absent || find("unlock") != nil {
		return .Bad_State
	}
	system.log_in("programs", .Info, "root: the principal \"", name, "\" is created in the window of unlock")
	return unlock_start(.Create_Principal, name)
}

// principal_record takes the public part of the record of a named
// principal from `unlock`: values[0..3] its public key, values[4..6] its
// name. The values are a copy in this service: `unlock` cannot change them.
principal_record :: proc "contextless" (values: [7]u64, completion: ^[7]u64) -> system.Status {
	public_key := transmute([32]u8)([4]u64{values[0], values[1], values[2], values[3]})
	name, name_length := principals.name_unpack({values[4], values[5], values[6]})
	if principals.name_problem(string(name[:name_length])) != .None {
		return .Bad_Operation
	}
	record := &principal_records[1]
	if record.state != .Absent {
		// The same record again (a second start of `unlock`) has the same
		// number; another one has no place.
		if record.public_key != public_key || string(record.name[:record.name_length]) != string(name[:name_length]) {
			return .No_Slot
		}
		completion^[0] = 1
		return .Ok
	}
	record^ = {state = .Locked, name = name, name_length = name_length, public_key = public_key}
	// Only a record that `unlock` made in this run lets its first key write
	// over a table that does not verify (principal_key_take).
	principal_created_in_this_run[1] = unlock_creating()
	completion^[0] = 1
	digits := system_description.hexadecimal(public_key)
	system.log_in("programs", .Info, "root: principal 1 \"", principal_name(1), "\" is recorded, its public key ", string(digits[:16]), "...; its session is locked")
	return .Ok
}

// principal_unlock starts the session of a named principal: from now on the
// desktop starts each program in it. values[4] is its number; values[0..3]
// and values[5] are the key of the tag of its disk grant table and its
// origin, which this service takes before the session starts
// (principal_key_take). A refusal writes its own error record in
// completion: the values of the command hold a key where a name would be,
// so the record of `refusal` is never built from them.
principal_unlock :: proc "contextless" (values: [7]u64, completion: ^[7]u64) -> system.Status {
	kind := u32(root_ring.Root_Command.Principal_Unlock)
	number := values[4]
	if number == principals.MACHINE || number >= principals.PRINCIPAL_CAPACITY || principal_records[number].state == .Absent {
		completion^ = errors.ring_fail(kind, .Absent, .Principals, 2, i64(min(number, 1 << 62)))
		return .Bad_Handle
	}
	if principal_records[number].state != .Locked {
		completion^ = errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(system.Status.Bad_State))
		return .Bad_State
	}
	if status := principal_key_take(number, values); status != .Ok {
		completion^ = errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(status))
		return status
	}
	principal_records[number].state = .Unlocked
	// The client keys that the principal allowed take calls again.
	remote_clients_session_changed(number, false)
	unlock_run.failed_stops = 0
	system.log_in("programs", .Info, "root: the session of principal ", number, " \"", principal_name(number), "\" starts: the desktop starts each program in it")
	return .Ok
}

// principal_lock ends the session that runs: each program of the session
// stops (a frozen program needs a kernel operation that does not exist),
// and `unlock` starts again. completion[0] is the count of the programs
// stopped.
principal_lock :: proc "contextless" (completion: ^[7]u64) -> system.Status {
	number := desktop_principal()
	if number == principals.MACHINE {
		return .Bad_State
	}
	count: u64
	for &item in started {
		if item.program != 0 && item.principal == number {
			system.call(.Program_Stop, u64(item.program), 0)
			if !item.is_terminal {
				count += 1
			}
		}
	}
	principal_records[number].state = .Locked
	// A call from another machine acts for no principal whose session is
	// locked: the connections of its client keys end.
	remote_clients_session_changed(number, true)
	completion^[0] = count
	system.log_in("programs", .Info, "root: the session of principal ", number, " \"", principal_name(number), "\" ends: ", count, " programs stopped")
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
		system.call(.Program_Stop, u64(running.program), 0)
		system.log_in("programs", .Info, "root: the lock stops the window of unlock, which ran for ", principals.mode_words(unlock_run.mode), "; unlock asks for the passphrase when it stopped")
		return .Ok
	}
	unlock_start(.Unlock, "")
	return .Ok
}

// unlock_stopped counts a stop of `unlock` that reap found: each stop
// while a principal is locked, whatever its code, unless the root service
// asked it. An `unlock` that stops at once with the code 0 (a store that
// lost the file of a principal whose record is locked) must be bounded as
// a fault is.
unlock_stopped :: proc "contextless" () {
	// A creation that stopped before it gave its record created nothing:
	// the stage Stopped says that no `unlock` creates.
	asked := unlock_run.stage == .Stop_Asked
	unlock_run.stage = .Stopped
	if asked || !principal_locked() {
		return
	}
	unlock_run.failed_stops += 1
	if unlock_run.failed_stops == UNLOCK_RESTART_LIMIT {
		system.log_in("programs", .Warning, "root: unlock stopped ", u64(UNLOCK_RESTART_LIMIT), " times while a principal is locked, with no stop that the root service asked: it starts no more until the machine starts again")
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
	// A full table is not counted: a slot comes free only with a stop, and
	// a stop is an event, so the next pass tries again with no hot loop.
	if status := unlock_start(.Unlock, ""); status != .Ok && status != .No_Slot {
		unlock_run.failed_stops += 1
	}
}

// principal_change_end runs the command Principal_Change_End, which only
// `unlock` sends: the change ended. The end goes to the caller of
// Principal_Change.
principal_change_end :: proc "contextless" (values: [7]u64, completion: ^[7]u64) -> system.Status {
	kind := u32(root_ring.Root_Command.Principal_Change_End)
	if !principal_change_waiting {
		completion^ = errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(system.Status.Bad_State))
		return .Bad_State
	}
	end, end_status, end_refusal := root_ring.member_of_word(principals.Change_End, values[4], .Principal_Change_End, 2)
	if end_status != .Ok {
		completion^ = end_refusal
		return end_status
	}
	problem, problem_status, problem_refusal := root_ring.member_of_word(principals.Change_Problem, values[5], .Principal_Change_End, 3)
	if problem_status != .Ok {
		completion^ = problem_refusal
		return problem_status
	}
	principal_change_finish(end, problem)
	return .Ok
}

// principal_change_finish gives the end of the change to its caller, when
// it still runs, and ends the change.
principal_change_finish :: proc "contextless" (end: principals.Change_End, problem: principals.Change_Problem) {
	principal_change_waiting = false
	system.log_in("programs", .Info, "root: the change in the window of unlock ends: ", principals.change_end_sentences[end])
	asker := principal_change_asker
	principal_change_asker = nil
	if asker != nil && asker.program != 0 && asker.requests.head != nil {
		if !system.send(&asker.requests.completions, ring.Record{kind = u32(system.Status.Ok), tag = principal_change_tag, values = {0 = u64(end), 1 = u64(problem)}}) {
			system.log_in("programs", .Warning, "root: the completion ring of ", system.Module_Name{system.name_of(asker.name[:])}, " is full: the end of the change does not reach it, and its line waits until Escape")
		}
	}
}

// principal_change_forget takes a program that stops out of the change:
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
// change the passphrase of the principal of the session of the caller, or
// to make it a new recovery key. The caller acts for that principal, and
// its session runs: the console of principal 0 cannot ask for a named
// principal. The window asks for the current passphrase before any change
// (src/md/features/tpm_sealed_principal_keys.md). values is the
// completion: an error record for a refusal. A change that starts holds
// the completion until it ends (principal_change_finish).
principal_change :: proc "contextless" (caller: ^Started, tag: u32, change: u64, values: ^[7]u64) -> (status: system.Status, held: bool) {
	status, held = principal_change_begin(caller, change, values)
	if held {
		principal_change_waiting = true
		principal_change_asker = caller
		principal_change_tag = tag
	}
	return
}

principal_change_begin :: proc "contextless" (caller: ^Started, change: u64, values: ^[7]u64) -> (status: system.Status, held: bool) {
	kind := u32(root_ring.Root_Command.Principal_Change)
	if .Acts_For_Principal not_in grants_held(caller) {
		values^ = errors.ring_fail(kind, .No_Grant, .Acts_For_Principal, 1)
		return .No_Right, false
	}
	asked, asked_status, asked_refusal := root_ring.member_of_word(root_ring.Principal_Change, change, .Principal_Change, 2)
	if asked_status != .Ok {
		values^ = asked_refusal
		return asked_status, false
	}
	mode: principals.Unlock_Mode
	switch asked {
	case .Passphrase:
		mode = .Change_Passphrase
	case .Recovery_Key:
		mode = .New_Recovery_Key
	}
	number := caller.principal
	if number == principals.MACHINE || number >= principals.PRINCIPAL_CAPACITY || principal_records[number].state != .Unlocked {
		system.log_in("programs", .Warning, "root: refused a change of the passphrase: the caller runs in no session of a named principal")
		values^ = errors.ring_fail(kind, .Absent, .Principals)
		return .Bad_State, false
	}
	// A change that waits for its end is a change whose `unlock` runs, or
	// is not reaped yet: one at a time.
	if find("unlock") != nil || principal_change_waiting {
		system.log_in("programs", .Warning, "root: refused a change of the passphrase: unlock runs; it is made when unlock stopped")
		values^ = errors.ring_fail(kind, .Busy, .Requests, 0, 1, 1)
		return .No_Slot, false
	}
	if mode == .Change_Passphrase {
		system.log_in("programs", .Info, "root: the passphrase of principal ", number, " \"", principal_name(number), "\" changes in the window of unlock")
	} else {
		system.log_in("programs", .Info, "root: a new recovery key of principal ", number, " \"", principal_name(number), "\" is made in the window of unlock")
	}
	started_status := unlock_start(mode, "")
	if started_status != .Ok {
		values^ = errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(started_status))
		return started_status, false
	}
	return .Ok, true
}

// principal_read gives a record: values[0] its state, values[1..4] its
// name, values[5] the first 8 bytes of its public key, values[6] for
// principal 0 the first 8 bytes of the measure of the system (0: not
// measured).
principal_read :: proc "contextless" (number: u64, completion: ^[7]u64) -> system.Status {
	if number >= principals.PRINCIPAL_CAPACITY {
		return .Bad_Handle
	}
	record := &principal_records[number]
	state := record.state
	if state == .Absent && number != principals.MACHINE && find("unlock") != nil && unlock_creating() {
		state = .Creating
	}
	if state == .Absent {
		return .Bad_Handle
	}
	packed := system.name_pack(string(record.name[:record.name_length]))
	key := transmute([4]u64)record.public_key
	measure := transmute([4]u64)record.measure
	completion^ = {u64(state), packed[0], packed[1], packed[2], packed[3], key[0], record.measured ? measure[0] : 0}
	return .Ok
}

// For each principal: its record was made by a creation in this run of the
// machine, not read from a file that existed. Only such a principal can
// give a key of the origin Principal_Key_Origin.New.
principal_created_in_this_run: [principals.PRINCIPAL_CAPACITY]bool
