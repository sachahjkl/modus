package root

import "modus:contract/errors"
import "modus:contract/ring"
import "modus:contract/system_description"
import "modus:support/principals"
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
	state:       system.Principal_State,
	name:        [principals.NAME_LIMIT]u8,
	name_length: int,
	public_key:  [32]u8, // Ed25519: the key that signs the grants of the principal. Principal 0: none in this system yet.
	measured:    bool, // Principal 0: the boot program measured the system into PCR 11.
	measure:     [32]u8, // Principal 0: the value of PCR 11.
}

principal_records: [principals.PRINCIPAL_CAPACITY]Principal_Record

// What start() gives to the next start of `unlock` (principals.VALUE_MODE):
// to unlock, to create the principal with this name, or to set the machine
// passphrase.
unlock_mode: u64
unlock_name: [principals.NAME_LIMIT]u8
unlock_name_length: int
// True only while unlock_start starts `unlock`: a start by name from a
// ring or from the desktop is refused (start).
unlock_start_asked: bool
// The mode of the last `unlock` that started: a lock stops the `unlock` of
// a change, which the session asked for (principal_lock).
unlock_running_mode: u64
// The stops of `unlock` with a code other than 0, and its starts that
// failed, since the last lock or the last start of a session. Past the
// bound, the root service starts it no more while a principal is locked,
// until the machine starts again: a file that stops it at once must not
// start it in a loop. A close of its window counts too, so the bound
// leaves room for a close by mistake.
UNLOCK_RESTART_LIMIT :: 3
unlock_failed_stops: int

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
// to create a principal, or to set the machine passphrase. mode is a
// principals.MODE_ value.
unlock_start :: proc "contextless" (mode: u64, name: string) -> system.Status {
	unlock_mode = mode
	unlock_name_length = copy(unlock_name[:], name)
	unlock_start_asked = true
	status := start("unlock")
	unlock_start_asked = false
	if status == .Ok {
		unlock_running_mode = mode
	}
	unlock_mode = principals.MODE_UNLOCK
	unlock_name_length = 0
	unlock_name = {}
	if status != .Ok {
		system.log_in("programs", .Warning, "root: unlock did not start (status ", status, "): no named principal can be created or unlocked")
	}
	return status
}

// principal_create starts `unlock` to create a named principal.
principal_create :: proc "contextless" (name: string) -> system.Status {
	if principals.name_problem(name) != .None {
		return .Bad_Operation
	}
	if principal_records[1].state != .Absent || find("unlock") != nil {
		return .Bad_State
	}
	system.log_in("programs", .Info, "root: the principal \"", name, "\" is created in the window of unlock")
	status := unlock_start(principals.MODE_CREATE_PRINCIPAL, name)
	unlock_creating = status == .Ok
	return status
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
	principal_created_in_this_run[1] = unlock_creating
	unlock_creating = false
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
	kind := u32(system.Root_Command.Principal_Unlock)
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
	unlock_failed_stops = 0
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
	completion^[0] = count
	system.log_in("programs", .Info, "root: the session of principal ", number, " \"", principal_name(number), "\" ends: ", count, " programs stopped")
	unlock_failed_stops = 0
	// One `unlock` runs at a time. The `unlock` of a change was asked from
	// the session, so it stops with the session; another one (a machine
	// passphrase that is set) runs to its end. In each case the `unlock`
	// of the lock starts after each reap where none runs
	// (unlock_for_a_locked_principal).
	if running := find("unlock"); running != nil {
		if unlock_running_mode == principals.MODE_CHANGE_PASSPHRASE || unlock_running_mode == principals.MODE_NEW_RECOVERY_KEY {
			system.call(.Program_Stop, u64(running.program), 0)
			system.log_in("programs", .Info, "root: the lock stops the change in the window of unlock; unlock asks for the passphrase when it stopped")
		} else {
			system.log_in("programs", .Info, "root: unlock runs at the lock; it asks for the passphrase when it stopped")
		}
		return .Ok
	}
	unlock_start(principals.MODE_UNLOCK, "")
	return .Ok
}

// unlock_stopped counts a stop of `unlock` that reap found: a stop with a
// code other than 0 counts toward UNLOCK_RESTART_LIMIT.
unlock_stopped :: proc "contextless" (failed: bool) {
	if !failed {
		return
	}
	unlock_failed_stops += 1
	if unlock_failed_stops == UNLOCK_RESTART_LIMIT && principal_locked() {
		system.log_in("programs", .Warning, "root: unlock stopped ", u64(UNLOCK_RESTART_LIMIT), " times with an error while a principal is locked: it starts no more until the machine starts again")
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
	if !principal_locked() || find("unlock") != nil || unlock_failed_stops >= UNLOCK_RESTART_LIMIT {
		return
	}
	if unlock_start(principals.MODE_UNLOCK, "") != .Ok {
		unlock_failed_stops += 1
	}
}

// principal_change_end runs the command Principal_Change_End, which only
// `unlock` sends: the change ended. The end goes to the caller of
// Principal_Change.
principal_change_end :: proc "contextless" (values: [7]u64, completion: ^[7]u64) -> system.Status {
	kind := u32(system.Root_Command.Principal_Change_End)
	end, problem := values[4], values[5]
	if !principal_change_waiting {
		completion^ = errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(system.Status.Bad_State))
		return .Bad_State
	}
	if end > u64(max(principals.Change_End)) || problem > u64(max(principals.Change_Problem)) {
		completion^ = errors.ring_fail(kind, .Bad_Value, .None, 2, i64(min(end, 1 << 62)), i64(max(principals.Change_End)))
		return .Bad_Operation
	}
	principal_change_finish(principals.Change_End(end), principals.Change_Problem(problem))
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
		system.send(&asker.requests.completions, ring.Record{kind = u32(system.Status.Ok), tag = principal_change_tag, values = {0 = u64(end), 1 = u64(problem)}})
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
	kind := u32(system.Root_Command.Principal_Change)
	if .Acts_For_Principal not_in grants_held(caller) {
		values^ = errors.ring_fail(kind, .No_Grant, .Acts_For_Principal, 1)
		return .No_Right, false
	}
	mode: u64
	switch change {
	case system.PRINCIPAL_CHANGE_PASSPHRASE:
		mode = principals.MODE_CHANGE_PASSPHRASE
	case system.PRINCIPAL_CHANGE_RECOVERY_KEY:
		mode = principals.MODE_NEW_RECOVERY_KEY
	case:
		values^ = errors.ring_fail(kind, .Bad_Value, .None, 2, i64(min(change, 1 << 62)), system.PRINCIPAL_CHANGE_RECOVERY_KEY)
		return .Bad_Operation, false
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
	if mode == principals.MODE_CHANGE_PASSPHRASE {
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
	if state == .Absent && number != principals.MACHINE && find("unlock") != nil && unlock_creating {
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

// Set while `unlock` runs to create a principal: a reader of the records
// sees the state Creating.
unlock_creating: bool

// For each principal: its record was made by a creation in this run of the
// machine, not read from a file that existed. Only such a principal can
// give a key of the origin PRINCIPAL_KEY_NEW.
principal_created_in_this_run: [principals.PRINCIPAL_CAPACITY]bool
