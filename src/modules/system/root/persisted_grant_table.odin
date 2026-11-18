package root

// The disk grant table of each principal on the disk, under a key that only
// `unlock` gives (docs/PRINCIPALS.md, "Principal 0 and its machine passphrase";
// docs/PRINCIPALS.md, "The disk grant table of a named principal";
// docs/MODULE_CONTRACT.md, "The grants of a disk program").
//
// Principal 0: with no machine passphrase, its table lasts until the
// machine stops. With one, `unlock` gives this service the key of the tag
// of the table (Machine_Key) after the passphrase is typed.
//
// A named principal: `unlock` gives the key of the tag of its table with
// the start of its session (Principal_Unlock), from the secret unlock key
// that the passphrase opens. This service keeps it until the machine stops:
// a lock does not erase it, as a write that runs at the lock still needs it.
//
// With the key, this service reads the object `grant_table` of the store
// `module_files` of the principal, then writes it after each change. The key is
// the only key that this service receives: it opens no seal, and it signs
// nothing but a table.
//
// A table that does not verify under a key that opened an existing record
// is refused and kept: it can be a good table of another key, or a table
// that a byte changed, and a write over it would lose its grants with no
// sign. Only the key of a record that is new (a new machine passphrase set
// when no record existed, or a new principal) writes over such a table: no
// key of a record signed it.
//
// The read and the write are calls of the storage service, which this
// service started and does not wait for: each one is a state of the loop
// (persisted_tables_step), with the deadline of a load, as the load of a
// module file is (disk_programs.odin). Each principal has its own
// connection, so the calls of two tables do not wait for each other. A
// write that fails is tried again at once, up to WRITE_TRY_LIMIT tries, so
// a `disallow` reaches the disk with no later change.

import "base:intrinsics"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/ring"
import "modus:support/disk_program"
import "modus:support/principals"
import "modus:support/storage"
import "modus:contract/root_ring"
import "modus:support/system"

// The tries of one write. Each try has the deadline of a load; the bound
// ends the tries when the storage service fails for good.
WRITE_TRY_LIMIT :: 3

// The states of the table of a principal on the disk.
Persisted_Table_State :: enum u8 {
	No_Passphrase, // Principal 0 only: the machine has no passphrase, and the table lasts until the machine stops.
	Awaited, // A key is awaited: the machine passphrase is not typed, or the named principal was not unlocked in this run. No row, and no change is taken.
	Record_Unreadable, // Principal 0 only: the store holds a record of the machine passphrase that unlock cannot read: no key, no change, and no new passphrase.
	Reading, // The key came, and the read of the table runs: no change is taken, as the read replaces the table.
	Kept, // The read ended: the table is written after each change.
	Unread, // The read failed: this service does not know what the disk holds, so no change is taken.
	Refused, // The table on the disk does not verify under the key of the record: it is kept, and no change is written over it.
	Unwritten, // A write failed WRITE_TRY_LIMIT times: the disk holds an older table, so no change is taken.
}

// The call of the storage service that runs for a table.
Persisted_Table_Call :: enum u8 {
	None,
	Read,
	Write,
}

Persisted_Table :: struct {
	state:          Persisted_Table_State,
	key:            [disk_program.KEY_SIZE]u8, // The key of the tag. Zero bytes until it comes.
	key_new:        bool, // The key is the key of a new record: no record signed the table on the disk.
	call:           Persisted_Table_Call,
	write_again:    bool, // A change came while a write ran: one more write after it.
	write_failures: int, // The failed tries of the write that runs.
	// The caller record of the connection of this service for the table:
	// its name is the name of the store `module_files`, and its principal the
	// principal of the table, so the table is an object of the store of the
	// module files of that principal. grant_for gives it the limit of that
	// store and no grant to act for a principal.
	keeper:         Started,
	connection:     ^Connection, // The connection to the storage service for the call. nil: none, or it ended.
	client:         storage.Client, // The call ring and the call region of that connection, mapped here.
	sent:           storage.Sent_Call,
	arguments:      [3]isolated.Argument,
	argument_count: int,
	bytes:          [disk_program.TABLE_SIZE]u8, // The table that a write sends.
	deadline:       u64, // The time at which the call ends with no answer.
	// Why the table on the disk was refused, in the state Refused: the
	// sentence of a refused change depends on it.
	refused_problem: disk_program.Table_File_Problem,
	// The client keys of remote revoked before a read of the table in this
	// run: the read takes them out of the table that it gives, so a key
	// that the disk still holds does not come back.
	revoked_keys:      [disk_program.CLIENT_KEY_CAPACITY][disk_program.CLIENT_KEY_SIZE]u8,
	revoked_key_count: int,
}

persisted_tables: [principals.PRINCIPAL_CAPACITY]Persisted_Table

// persisted_tables_start gives each named principal the state Awaited: its
// key comes at its first unlock. Principal 0 starts with no passphrase,
// until `unlock` reports a record of the machine passphrase.
persisted_tables_start :: proc "contextless" () {
	for &table, number in persisted_tables {
		table = {}
		if number != principals.MACHINE {
			table.state = .Awaited
		}
	}
}

// persisted_table_keeper_is says if a caller record is the caller of the
// connection of this service for a persisted table.
persisted_table_keeper_is :: proc "contextless" (caller: ^Started) -> bool {
	for &table in persisted_tables {
		if caller == &table.keeper {
			return true
		}
	}
	return false
}

// persisted_table_connection_ended tells a table that its connection ended.
persisted_table_connection_ended :: proc "contextless" (connection: ^Connection) {
	for &table in persisted_tables {
		if table.connection == connection {
			table.connection = nil
		}
	}
}

// The words that name the key of a principal in the log.
key_words :: proc "contextless" (principal: u64) -> string {
	return principal == principals.MACHINE ? "the machine key" : "the key of the principal"
}

// machine_key_held says if this service holds the key of the tag of the
// table of principal 0: `unlock` then does not ask for the machine
// passphrase (after a lock).
machine_key_held :: proc "contextless" () -> bool {
	switch persisted_tables[principals.MACHINE].state {
	case .Reading, .Kept, .Unread, .Refused, .Unwritten:
		return true
	case .No_Passphrase, .Awaited, .Record_Unreadable:
		return false
	}
	return false
}

// machine_passphrase_ask runs the command Machine_Passphrase: it starts
// `unlock` to set the machine passphrase. A machine with a passphrase
// refuses a second one: a change is not built. A record that cannot be
// read refuses one too: it can hold a good key.
machine_passphrase_ask :: proc "contextless" () -> system.Status {
	state := persisted_tables[principals.MACHINE].state
	if state == .Record_Unreadable {
		system.log_in("programs", .Warning, "root: refused a machine passphrase: the record of the machine passphrase cannot be read, and a new one would replace a key that can be good")
		return .Bad_State
	}
	if state != .No_Passphrase {
		system.log_in("programs", .Warning, "root: refused a machine passphrase: the machine has one, and a change is not built")
		return .Bad_State
	}
	if find("unlock") != nil {
		system.log_in("programs", .Warning, "root: refused a machine passphrase: unlock runs; it is set when unlock stopped")
		return .No_Slot
	}
	system.log_in("programs", .Info, "root: the machine passphrase is set in the window of unlock")
	return unlock_start(.Set_Machine_Passphrase, "")
}

// machine_seal_ask runs the command Machine_Seal: it starts `unlock` to
// make a machine key that the TPM service seals to the measure of the
// system (src/md/features/tpm_sealed_machine_key.md). It is refused on a
// machine with no TPM service, and on a machine with a record of its
// machine key, readable or not: a new key would replace a key that can be
// good, and the table that it signed.
machine_seal_ask :: proc "contextless" () -> system.Status {
	if tpm_ring == 0 {
		system.log_in("programs", .Warning, "root: refused a machine key sealed by the TPM: no TPM service runs, as the system is not measured into a TPM")
		return .Bad_Handle
	}
	if !tpm_seal_allowed() {
		system.log_in("programs", .Warning, "root: refused a machine key sealed by the TPM: the firmware did not verify the boot program (Secure Boot is off), so a seal would trust a boot program that nothing verified")
		return .No_Right
	}
	state := persisted_tables[principals.MACHINE].state
	if state != .No_Passphrase {
		system.log_in("programs", .Warning, "root: refused a machine key sealed by the TPM: the machine has a record of its machine key, and a change is not built")
		return .Bad_State
	}
	if find("unlock") != nil {
		system.log_in("programs", .Warning, "root: refused a machine key sealed by the TPM: unlock runs; it is made when unlock stopped")
		return .No_Slot
	}
	system.log_in("programs", .Info, "root: the machine key is sealed by the TPM in the window of unlock")
	return unlock_start(.Seal_Machine_Key, "")
}

// machine_key_take runs the command Machine_Key, which only `unlock`
// sends: the machine has a passphrase that is not typed yet, its record
// cannot be read, or the key of the tag came. The key is a copy in this
// service; the local copy is erased here, and the main loop erases the
// slot of the ring (key_ring_erase).
machine_key_take :: proc "contextless" (values: [7]u64) -> system.Status {
	table := &persisted_tables[principals.MACHINE]
	state := table.state
	waiting := state == .No_Passphrase || state == .Awaited || state == .Record_Unreadable
	// A word that names no state or no form is refused, and changes nothing.
	report, report_status := root_ring.machine_key_report_of_values(values)
	if report_status != .Ok {
		return report_status
	}
	reported := report.state
	switch reported {
	case .Awaited:
		if !waiting {
			return .Bad_State
		}
		table.state = .Awaited
		switch report.form {
		case .Sealed_By_The_Tpm:
			system.log_in("programs", .Info, "root: the machine key is sealed by the TPM: the disk grants of principal 0 wait for the unseal, and the machine runs")
		case .Passphrase:
			system.log_in("programs", .Info, "root: the machine has a passphrase: the disk grants of principal 0 wait for it, and the machine runs")
		}
		return .Ok
	case .Unreadable:
		if !waiting {
			return .Bad_State
		}
		table.state = .Record_Unreadable
		system.log_in("programs", .Warning, "root: the record of the machine passphrase cannot be read: the disk grants of principal 0 stay absent, and no change and no new passphrase is taken")
		return .Ok
	case .Opened, .New:
		key_new := reported == .New
		// A new passphrase is set only on a machine with no record; an
		// opened key comes after the report that a record exists.
		if key_new && state != .No_Passphrase || !key_new && state != .Awaited {
			return .Bad_State
		}
		key := transmute([disk_program.KEY_SIZE]u8)[4]u64{values[0], values[1], values[2], values[3]}
		defer key_erase(key[:])
		if key == {} {
			return .Bad_Operation
		}
		table.key = key
		table.key_new = key_new
		table.state = .Reading
		persisted_table_read_begin(principals.MACHINE)
		return .Ok
	}
	return .Bad_Operation
}

// principal_key_take takes the key of the tag of the table of a named
// principal, which `unlock` gives with Principal_Unlock: values[0..3] the
// key, values[5] its origin. At the first unlock of the run the read of the
// table starts. A later unlock, after a lock, gives the key of the same
// file: a key that differs is refused, as this service keeps one key for
// each table. A read that failed starts again at such an unlock. The origin
// Principal_Key_Origin.New, which lets the read write over a table that does not
// verify, is taken only for a principal that this service saw created in
// this run: the rule then holds in this service, not in the code of
// `unlock` alone. The local copy is erased here, and the main loop erases
// the slot of the ring (key_ring_erase).
principal_key_take :: proc "contextless" (number: u64, values: [7]u64) -> system.Status {
	if number == principals.MACHINE || number >= principals.PRINCIPAL_CAPACITY {
		return .Bad_Handle
	}
	table := &persisted_tables[number]
	key := transmute([disk_program.KEY_SIZE]u8)[4]u64{values[0], values[1], values[2], values[3]}
	defer key_erase(key[:])
	origin, origin_status, _ := root_ring.member_of_word(root_ring.Principal_Key_Origin, values[5], .Principal_Unlock, 0)
	if key == {} || origin_status != .Ok {
		return .Bad_Operation
	}
	if origin == .New && !principal_created_in_this_run[number] {
		system.log_in("programs", .Warning, "root: refused the unlock of principal ", number, ": its key comes as the key of a new principal, and its record was not created since the machine started")
		return .Bad_State
	}
	if table.state != .Awaited {
		if !keys_equal(&table.key, &key) {
			system.log_in("programs", .Warning, "root: refused the unlock of principal ", number, ": the key of its disk grant table differs from the key of its first unlock since the machine started")
			return .Bad_State
		}
		// The read at an earlier unlock failed: this unlock tries it again.
		// No write ran since, so the origin of the first key still holds.
		if table.state == .Unread {
			table.state = .Reading
			persisted_table_read_begin(number)
		}
		return .Ok
	}
	table.key = key
	table.key_new = origin == .New
	table.state = .Reading
	persisted_table_read_begin(number)
	return .Ok
}

// keys_equal compares two keys in a time that does not depend on the first
// byte that differs.
keys_equal :: proc "contextless" (first, second: ^[disk_program.KEY_SIZE]u8) -> bool {
	difference: u8
	for index in 0 ..< disk_program.KEY_SIZE {
		difference |= first[index] ~ second[index]
	}
	return difference == 0
}

// key_erase writes 0 over a copy of a key with volatile stores, which the
// compiler cannot remove.
key_erase :: proc "contextless" (bytes: []u8) {
	for &item in bytes {
		intrinsics.volatile_store(&item, 0)
	}
}

// key_ring_erase writes 0 over the values of the record of the command ring
// that the loop read last: the record Machine_Key or Principal_Unlock,
// whose key would else stay in the ring until its slot is used again.
// `unlock` sends nothing more before the completion, so no record is
// written there now. The mask is the private mask of this service, so a
// false counter of the other side names a slot of the ring and nothing
// else.
key_ring_erase :: proc "contextless" (queue: ^ring.Queue) {
	read := intrinsics.atomic_load_explicit(&queue.counters.read, .Relaxed)
	slot := &queue.records[(read - 1) & queue.mask]
	for &value in slot.values {
		intrinsics.volatile_store(&value, 0)
	}
}

// persisted_table_refusal says if a change of the disk grant table of a
// principal is refused now, with its line on the log.
persisted_table_refusal :: proc "contextless" (principal: u64) -> bool {
	if principal >= principals.PRINCIPAL_CAPACITY {
		return true
	}
	// A record of a program of a session that the lock stopped can still be
	// in its ring: no change comes from a session that is not unlocked.
	if principal != principals.MACHINE && principal_records[principal].state != .Unlocked {
		system.log_in("programs", .Warning, "root: refused a change of the disk grant table of principal ", principal, ": its session is locked")
		return true
	}
	switch persisted_tables[principal].state {
	case .No_Passphrase, .Kept:
		return false
	case .Awaited:
		if principal == principals.MACHINE {
			system.log_in("programs", .Warning, "root: refused a change of the disk grant table of principal 0: the machine passphrase is not typed; type it in the window of unlock")
		} else {
			system.log_in("programs", .Warning, "root: refused a change of the disk grant table of principal ", principal, ": unlock gave no key for it")
		}
	case .Record_Unreadable:
		system.log_in("programs", .Warning, "root: refused a change of the disk grant table of principal 0: the record of the machine passphrase cannot be read, so nothing is written over the table on the disk")
	case .Reading:
		system.log_in("programs", .Warning, "root: refused a change of the disk grant table of principal ", principal, ": its read from the store module_files runs")
	case .Unread:
		system.log_in("programs", .Warning, "root: refused a change of the disk grant table of principal ", principal, ": the store module_files did not give it, so a write could lose it")
	case .Refused:
		if disk_program.table_problem_is_format(persisted_tables[principal].refused_problem) {
			system.log_in("programs", .Warning, "root: refused a change of the disk grant table of principal ", principal, ": the table on the disk has a format that this system does not read, and it is kept; do not restore a version of it, as no version has a format that this system reads")
		} else {
			system.log_in("programs", .Warning, "root: refused a change of the disk grant table of principal ", principal, ": the table on the disk does not verify under ", key_words(principal), ", and it is kept; restore a version of it that verifies, then start the machine again")
		}
	case .Unwritten:
		system.log_in("programs", .Warning, "root: refused a change of the disk grant table of principal ", principal, ": its last change is not on the disk; start the machine again")
	}
	return true
}

// persisted_table_changed writes the table of a principal after a change,
// when it is kept on the disk.
persisted_table_changed :: proc "contextless" (principal: u64) {
	if principal >= principals.PRINCIPAL_CAPACITY {
		return
	}
	table := &persisted_tables[principal]
	if table.state == .Kept {
		// A change during the tries of a write joins those tries, with no
		// more tries than the bound.
		if table.call == .None {
			table.write_failures = 0
		}
		persisted_table_write_begin(principal)
	}
}

// persisted_table_revocation writes the disk grant table of a principal
// after the revocation of one of its client keys of remote, and says if the
// key can still come back from the disk. A revocation is never refused: it
// ends a grant at once, so it does what each state of the table allows.
// - Kept: the table is written.
// - Unwritten: the revocation starts the writes again, as the table in
//   memory holds each change since the last good write.
// - Reading, Awaited, Unread: the key is kept as revoked, and the next read
//   of this run takes it out of the table that it gives. The machine can
//   stop before that read, but in Reading, which ends at once.
// - Refused, Record_Unreadable: nothing is written over the table on the
//   disk, which can hold the key.
persisted_table_revocation :: proc "contextless" (principal: u64, key: [disk_program.CLIENT_KEY_SIZE]u8) -> (can_come_back: bool) {
	table := &persisted_tables[principal]
	switch table.state {
	case .No_Passphrase:
		return false
	case .Kept:
		persisted_table_changed(principal)
		return false
	case .Unwritten:
		table.state = .Kept
		table.write_failures = 0
		table.write_again = false
		system.log_in("programs", .Warning, "root: a revocation of a client key of remote starts the writes of the disk grant table of principal ", principal, " again")
		persisted_table_write_begin(principal)
		return false
	case .Reading, .Awaited, .Unread:
		already := false
		for place in 0 ..< table.revoked_key_count {
			if table.revoked_keys[place] == key {
				already = true
			}
		}
		if !already && table.revoked_key_count < disk_program.CLIENT_KEY_CAPACITY {
			table.revoked_keys[table.revoked_key_count] = key
			table.revoked_key_count += 1
		}
		can_come_back = table.state != .Reading
	case .Refused, .Record_Unreadable:
		can_come_back = true
	}
	if can_come_back {
		head: [16]u8
		system.log_in("calls", .Warning, "root: the revocation of the client key ", key_head_text(&head, key), " of remote is not written in the disk grant table of principal ", principal, ", which takes no change now: the key can come back at the next start of the machine")
	}
	return can_come_back
}

// persisted_table_revoked_keys_take takes the keys revoked before the read
// out of the table that the read gives, and gives their count.
persisted_table_revoked_keys_take :: proc "contextless" (table: ^Persisted_Table, from_disk: ^disk_program.Grant_Table) -> (count: int) {
	for place in 0 ..< clamp(table.revoked_key_count, 0, disk_program.CLIENT_KEY_CAPACITY) {
		if disk_program.table_client_key_remove(from_disk, table.revoked_keys[place]) == .None {
			count += 1
		}
	}
	table.revoked_keys = {}
	table.revoked_key_count = 0
	return count
}

// persisted_table_open opens the connection of this service to the store
// `module_files` of a principal. It gives the reason when the storage service
// gives none.
persisted_table_open :: proc "contextless" (principal: u64) -> (reason: string, opened: bool) {
	table := &persisted_tables[principal]
	table.keeper = {}
	copy(table.keeper.name[:len(table.keeper.name) - 1], disk_program.STORE_NAME)
	table.keeper.principal = principal
	connection, service, ring_memory, region_memory, status := connection_open(&table.keeper, "storage")
	if status != .Ok {
		return "no connection to the storage service", false
	}
	client, mapped := storage.open_handles(ring_memory, region_memory, service.program, system.image_find(image, "storage"))
	if !mapped {
		system.close(ring_memory)
		system.close(region_memory)
		disconnect(connection)
		return "the call ring and the call region of the storage service do not map", false
	}
	table.connection = connection
	table.client = client
	table.deadline = system.time() + disk_program.LOAD_DEADLINE_MILLISECONDS
	return "", true
}

// persisted_table_send sends the call of a table, with its arguments: the
// root of the store, the name of the object, and for a write its bytes.
persisted_table_send :: proc "contextless" (principal: u64, call: Persisted_Table_Call) -> bool {
	table := &persisted_tables[principal]
	table.arguments = {}
	table.arguments[0].integer = u64(storage.ROOT)
	// The name is a constant: its bytes stay after this procedure returns.
	object_name := disk_program.TABLE_OBJECT_NAME
	table.arguments[1].text = transmute([]u8)object_name
	table.argument_count = 2
	export := "read"
	if call == .Write {
		table.arguments[2].text = table.bytes[:]
		table.argument_count = 3
		export = "write"
	}
	status: storage.Status
	table.sent, status = storage.call_send(&table.client, export, table.arguments[:table.argument_count])
	if status != .Ok {
		return false
	}
	table.call = call
	return true
}

// persisted_table_read_begin starts the read of a table, after its key
// came. A read that cannot start leaves the table unread.
persisted_table_read_begin :: proc "contextless" (principal: u64) {
	reason, opened := persisted_table_open(principal)
	if !opened {
		persisted_table_read_failed(principal, reason)
		return
	}
	if !persisted_table_send(principal, .Read) {
		persisted_table_end(principal)
		persisted_table_read_failed(principal, "the storage service took no call")
	}
}

// persisted_table_write_begin starts a write of the table of a principal,
// or marks one more write after the write that runs.
persisted_table_write_begin :: proc "contextless" (principal: u64) {
	table := &persisted_tables[principal]
	if table.call != .None {
		table.write_again = true
		return
	}
	disk_program.table_encode(&disk_grant_tables[principal], &table.key, &table.bytes)
	reason, opened := persisted_table_open(principal)
	if !opened {
		persisted_table_write_failed(principal, reason)
		return
	}
	if !persisted_table_send(principal, .Write) {
		persisted_table_end(principal)
		persisted_table_write_failed(principal, "the storage service took no call")
	}
}

// persisted_table_end gives back what the call of a table held: the
// mappings, the handles and the connection.
persisted_table_end :: proc "contextless" (principal: u64) {
	table := &persisted_tables[principal]
	if table.client.calls.head != nil {
		system.ring_close(&table.client.calls)
	}
	if table.client.region != nil {
		system.memory_unmap(raw_data(table.client.region))
	}
	// The handle of the storage service is the handle of its row in the
	// table of the started programs: it stays.
	for handle in ([2]system.Handle{table.client.ring_memory, table.client.region_memory}) {
		if handle != 0 {
			system.close(handle)
		}
	}
	if table.connection != nil {
		disconnect(table.connection)
	}
	table.connection = nil
	table.client = {}
	table.sent = {}
	table.arguments = {}
	table.argument_count = 0
	table.call = .None
}

// persisted_table_read_failed ends a read that got no answer that this
// service can use: the table stays unread.
persisted_table_read_failed :: proc "contextless" (principal: u64, reason: string) {
	persisted_tables[principal].state = .Unread
	system.log_in("programs", .Warning, "root: the disk grant table of principal ", principal, " is not read: ", reason, "; the disk grants of principal ", principal, " stay absent until the machine starts again")
}

// persisted_table_write_failed counts a failed try of a write, and tries
// again at once up to WRITE_TRY_LIMIT tries. Then the disk holds an older
// table, which can hold a grant that was taken since: no change is taken,
// and the log says it.
persisted_table_write_failed :: proc "contextless" (principal: u64, reason: string) {
	table := &persisted_tables[principal]
	table.write_failures += 1
	if table.write_failures < WRITE_TRY_LIMIT {
		system.log_in("programs", .Warning, "root: the disk grant table of principal ", principal, " is not written: ", reason, "; try ", u64(table.write_failures + 1), " of ", u64(WRITE_TRY_LIMIT))
		persisted_table_write_begin(principal)
		return
	}
	table.state = .Unwritten
	table.write_again = false
	system.log_in("programs", .Warning, "root: the disk grant table of principal ", principal, " is not written after ", u64(WRITE_TRY_LIMIT), " tries: ", reason, "; the disk keeps an older table, so a grant taken since can come back at the next start, and no change is taken")
}

// persisted_table_failed ends a call that got no answer that this service
// can use.
persisted_table_failed :: proc "contextless" (principal: u64, reason: string) {
	call := persisted_tables[principal].call
	persisted_table_end(principal)
	if call == .Read {
		persisted_table_read_failed(principal, reason)
	} else {
		persisted_table_write_failed(principal, reason)
	}
}

// persisted_tables_step does the next step of the call of each table.
persisted_tables_step :: proc "contextless" (wait: ^system.Wait) {
	for number in 0 ..< u64(principals.PRINCIPAL_CAPACITY) {
		persisted_table_step(number, wait)
	}
}

// persisted_table_step reads the answer of the call of a table, if it
// came, and does the next step. It never waits: with no answer, it adds the
// completions of the connection to the wait of the loop.
persisted_table_step :: proc "contextless" (principal: u64, wait: ^system.Wait) {
	table := &persisted_tables[principal]
	if table.call == .None {
		return
	}
	if table.connection == nil {
		persisted_table_failed(principal, "the storage service stopped")
		return
	}
	error: errors.Error_Record
	value, text, status, answered := storage.call_answer(&table.client, &table.sent, table.arguments[:table.argument_count], &error)
	if !answered {
		if !storage.connected(&table.client) {
			persisted_table_failed(principal, "the storage service stopped")
			return
		}
		if system.time() >= table.deadline {
			persisted_table_failed(principal, "the storage service gave no answer in time")
			return
		}
		system.wait_records(wait, &table.client.calls.completions)
		return
	}
	switch table.call {
	case .None:
	case .Read:
		absent := storage.export_failed_with(status, value, .Absent)
		if !absent && status != .Ok {
			sentence: [240]u8
			writer := system.Writer{buffer = sentence[:]}
			storage.error_text(&writer, &table.client, &error)
			persisted_table_failed(principal, system.written(&writer))
			return
		}
		// The bytes are copied once, by table_decode, before any field is
		// read: the storage service is a transport.
		from_disk: disk_program.Grant_Table
		problem := disk_program.Table_File_Problem.None
		if !absent {
			from_disk, problem = disk_program.table_decode(text, &table.key)
		}
		persisted_table_end(principal)
		decision := disk_program.table_read_decision(absent, problem, table.key_new)
		if decision != .Take {
			// The table in memory is written, or nothing is: a key revoked
			// before is in neither.
			table.revoked_keys = {}
			table.revoked_key_count = 0
		}
		switch decision {
		case .Write_Over:
			table.state = .Kept
			if absent {
				system.log_in("programs", .Info, "root: the store module_files holds no disk grant table of principal ", principal, ": the table of this machine is written there")
			} else {
				new_record := principal == principals.MACHINE ? "the new machine passphrase" : "the new principal"
				system.log_in("programs", .Warning, "root: refused the disk grant table of principal ", principal, " from the store module_files: ", disk_program.table_problem_sentences[problem], "; it gives no grant, and the table of ", new_record, " is written over it")
			}
			persisted_table_write_begin(principal)
			return
		case .Keep:
			table.state = .Refused
			table.refused_problem = problem
			system.log_in("programs", .Warning, "root: refused the disk grant table of principal ", principal, " from the store module_files: ", disk_program.table_problem_sentences[problem], "; it gives no grant, and it is kept: no change is written over it")
			return
		case .Take:
		}
		table.state = .Kept
		replaced := disk_grant_tables[principal].count
		if replaced > 0 {
			system.log_in("programs", .Info, "root: read the disk grant table of principal ", principal, " from the store module_files: ", u64(from_disk.count), " rows, with the tag of ", key_words(principal), "; ", u64(from_disk.client_key_count), " client keys of remote; it replaces ", u64(replaced), " rows made before the key came")
		} else {
			system.log_in("programs", .Info, "root: read the disk grant table of principal ", principal, " from the store module_files: ", u64(from_disk.count), " rows, with the tag of ", key_words(principal), "; ", u64(from_disk.client_key_count), " client keys of remote")
		}
		// A key revoked before the read stays revoked: the disk still held
		// it, and it is written there no more.
		revoked := persisted_table_revoked_keys_take(table, &from_disk)
		disk_grant_tables[principal] = from_disk
		if revoked > 0 {
			system.log_in("calls", .Info, "root: the disk grant table of principal ", principal, " held ", u64(revoked), " client keys of remote revoked before its read: they stay revoked, and the table is written again")
			table.write_failures = 0
			persisted_table_write_begin(principal)
		}
		// The client keys of the table hold again, and a key allowed before
		// the read that the table does not hold ends, as a row does.
		client_keys_after_read(principal)
	case .Write:
		if status != .Ok {
			sentence: [240]u8
			writer := system.Writer{buffer = sentence[:]}
			storage.error_text(&writer, &table.client, &error)
			persisted_table_failed(principal, system.written(&writer))
			return
		}
		persisted_table_end(principal)
		table.write_failures = 0
		// The rows of the bytes that went to the disk: a row that lasts
		// until the machine stops is not among them.
		system.log_in("programs", .Info, "root: the disk grant table of principal ", principal, " is written in the store module_files: ", u64(table.bytes[disk_program.TABLE_OFFSET_COUNT]), " rows, with the tag of ", key_words(principal), "; ", u64(table.bytes[disk_program.TABLE_OFFSET_CLIENT_KEY_COUNT]), " client keys of remote")
		if table.write_again {
			table.write_again = false
			persisted_table_write_begin(principal)
		}
	}
}

// persisted_tables_deadline gives the time at which the loop of this
// service must run again for the call of a table, or no time when none
// runs.
persisted_tables_deadline :: proc "contextless" () -> u64 {
	deadline: u64 = system.WAIT_FOREVER
	for &table in persisted_tables {
		if table.call != .None {
			deadline = min(deadline, table.deadline)
		}
	}
	return deadline
}
