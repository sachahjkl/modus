package root

// The disk grant table of each principal on the disk, under a key that only
// `unlock` gives (docs/PRINCIPALS.md, "Principal 0 and its machine passphrase";
// docs/PRINCIPALS.md, "The disk grant table of a named principal";
// docs/MODULE_CONTRACT.md, "The grants of a disk process").
//
// Principal 0: with no machine passphrase, its table lasts until the
// machine stops. With one, `unlock` gives the key of the tag of the table
// (Machine_Key) after the passphrase is typed.
//
// A named principal: `unlock` gives the key of the tag of its table with
// the start of its session (Principal_Unlock), from the secret unlock key
// that the passphrase opens.
//
// This service holds no key and is the client of no storage service
// (src/md/api/root_service_split.md, "State"). It passes
// each key on to the principals service, which keeps it until the machine
// stops, and keeps only the BLAKE3 hash of the key, to compare the key of a
// later unlock. For each read and each write, this service makes the
// connection of the principals service to the store `module_files` of the
// principal, gives its handles through the ring of the service, and sends
// Table_Read or Table_Write: the service calls the storage service, adds or
// checks the tag, and answers. This service decides each grant from its own
// table: it writes the table that the service writes
// (disk_process.table_body_encode), and checks the table that the service
// read with the decoder of the disk (disk_process.table_body_decode).
//
// A table that does not verify under a key that opened an existing record
// is refused and kept: it can be a good table of another key, or a table
// that a byte changed, and a write over it would lose its grants with no
// sign. Only the key of a record that is new (a new machine passphrase set
// when no record existed, or a new principal) writes over such a table: no
// key of a record signed it.
//
// This service never waits for the principals service: each call is a
// state of the loop, with a deadline past the deadline of the service for
// the storage service. A write that fails is tried again at once, up to
// WRITE_TRY_LIMIT tries, so a `disallow` reaches the disk with no later
// change. A principals service that starts again holds no key: a write then
// fails until the next unlock gives the key again.

import "base:intrinsics"
import "modus:contract/blake3"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/ring"
import rd "modus:contract/root_delegation"
import "modus:contract/root_ring"
import "modus:disk_process"
import "modus:principals"
import "modus:system"

#assert(rd.TABLE_BYTES == disk_process.TABLE_SIZE)

// The tries of one write. Each try has the deadline of a call; the bound
// ends the tries when the storage service fails for good.
WRITE_TRY_LIMIT :: 3

// The deadline of a call of a table in this service: past the deadline of
// the principals service for the storage service, so the cause that the
// service gives comes first.
TABLE_CALL_DEADLINE_MILLISECONDS :: 2 * disk_process.LOAD_DEADLINE_MILLISECONDS

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

// The call of a table that runs in the principals service.
Persisted_Table_Call :: enum u8 {
	None,
	Read,
	Write,
}

Persisted_Table :: struct {
	state:           Persisted_Table_State,
	// The BLAKE3 hash of the key of the tag: a later unlock gives the same
	// key. Zero bytes until the key comes. This service keeps no key.
	key_hash:        blake3.Hash,
	// The principals service that runs holds the key: a service that
	// started again since does not.
	key_held:        bool,
	key_new:         bool, // The key is the key of a new record: no record signed the table on the disk.
	call:            Persisted_Table_Call,
	write_again:     bool, // A change came while a write ran: one more write after it.
	write_failures:  int, // The failed tries of the write that runs.
	// The caller record of the connection of the principals service for the
	// table: its name is the name of the store `module_files`, and its
	// principal the principal of the table, so the table is an object of
	// the store of the module files of that principal. grant_for gives it
	// the limit of that store and no grant to act for a principal.
	keeper:          Started,
	connection:      ^Connection, // The connection for the call. nil: none, or it ended.
	// The handles of the connection that the principals service holds
	// copies of: this service revokes the copies at the end of the call.
	storage_handles: [3]system.Handle,
	tag:             u32, // The tag of the command of the call that runs.
	bytes:           [disk_process.TABLE_SIZE]u8, // The table that a write sends, with no tag.
	deadline:        u64, // The time at which the call ends with no answer.
	// Why the table on the disk was refused, in the state Refused: the
	// sentence of a refused change depends on it.
	refused_problem: disk_process.Table_File_Problem,
	// The client keys of remote revoked before a read of the table in this
	// run: the read takes them out of the table that it gives, so a key
	// that the disk still holds does not come back.
	revoked_keys:      [disk_process.CLIENT_KEY_CAPACITY][disk_process.CLIENT_KEY_SIZE]u8,
	revoked_key_count: int,
}

persisted_tables: [principals.PRINCIPAL_CAPACITY]Persisted_Table

// The table that the principals service read, copied out of its place:
// too large for the stack of the loop.
persisted_table_read_copy: [disk_process.TABLE_SIZE]u8

// The input of a table call that this service writes in a place.
persisted_table_input: rd.Table_Call_Input

// The record of the machine key opens with no passphrase: unlock reported a
// record sealed by the TPM alone, or made one in this run. Only then is a
// choice of a start policy read before the start policy runs
// (start_policy_choice.odin).
machine_key_without_passphrase: bool

// The causes of a call of a table that did not end, as the log writes them.
TABLE_CAUSE_NO_CONNECTION :: "no connection to the storage service"
TABLE_CAUSE_NO_SERVICE :: "the principals service does not run"
TABLE_CAUSE_SERVICE_STOPPED :: "the principals service stopped"
TABLE_CAUSE_SERVICE_SILENT :: "the principals service gave no answer in time"
TABLE_CAUSE_HANDLES_NOT_GIVEN :: "the principals service took no handle"
TABLE_CAUSE_UNDECODED :: "the principals service gave a table that does not decode"
TABLE_CAUSE_BAD_ANSWER :: "the principals service gave an answer that names no cause"
TABLE_CAUSE_OUTSIDE_CLASS :: "the principals service gave a row outside the disk grant classes"
TABLE_CAUSE_BAD_ERROR_RECORD :: "the principals service gave an error record that names no kind"

// The rows of a table that the principals service read, as the border of
// Disk_Rows_Set takes them. A file variable: the set is too large for the
// stack of this service.
persisted_table_read_rows: rd.Disk_Rows_Set_Request

// The cause of each failure that the principals service names.
@(rodata)
table_call_failure_causes := [rd.Table_Call_Failure]string {
	.None            = TABLE_CAUSE_BAD_ANSWER,
	.Not_Mapped      = "the call ring and the call region of the storage service do not map",
	.Call_Not_Taken  = "the storage service took no call",
	.Storage_Stopped = "the storage service stopped",
	.No_Answer       = "the storage service gave no answer in time",
	.No_Key          = "the principals service holds no key of the table",
	.Bad_Input       = "the principals service refused the call",
}

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
// connection of the principals service for a persisted table.
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

// machine_key_held says if the principals service holds the key of the tag
// of the table of principal 0: `unlock` then does not ask for the machine
// passphrase (after a lock).
machine_key_held :: proc "contextless" () -> bool {
	table := &persisted_tables[principals.MACHINE]
	switch table.state {
	case .Reading, .Kept, .Unread, .Refused, .Unwritten:
		return table.key_held
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
		system.log_fact(.Warning, Machine_Passphrase_Refused_Unreadable{})
		return .Bad_State
	}
	if state != .No_Passphrase {
		system.log_fact(.Warning, Machine_Passphrase_Refused_Exists{})
		return .Bad_State
	}
	if find("unlock") != nil {
		system.log_fact(.Warning, Machine_Passphrase_Refused_Unlock_Runs{})
		return .No_Slot
	}
	system.log_fact(.Info, Machine_Passphrase_Setting_Started{})
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
		system.log_fact(.Warning, Machine_Key_Seal_Refused_No_Tpm{})
		return .Bad_Handle
	}
	if !tpm_seal_allowed() {
		system.log_fact(.Warning, Machine_Key_Seal_Refused_Not_Verified{})
		return .No_Right
	}
	state := persisted_tables[principals.MACHINE].state
	if state != .No_Passphrase {
		system.log_fact(.Warning, Machine_Key_Seal_Refused_Exists{})
		return .Bad_State
	}
	if find("unlock") != nil {
		system.log_fact(.Warning, Machine_Key_Seal_Refused_Unlock_Runs{})
		return .No_Slot
	}
	system.log_fact(.Info, Machine_Key_Seal_Started{})
	return unlock_start(.Seal_Machine_Key, "")
}

// machine_key_take runs the command Machine_Key, which only `unlock`
// sends: the machine has a passphrase that is not typed yet, its record
// cannot be read, or the key of the tag came. The key goes on to the
// principals service, and this service keeps its hash only; the local copy
// is erased here, and the main loop erases the slot of the ring
// (key_ring_erase).
machine_key_take :: proc "contextless" (values: ^[7]u64) -> system.Status {
	table := &persisted_tables[principals.MACHINE]
	state := table.state
	waiting := state == .No_Passphrase || state == .Awaited || state == .Record_Unreadable
	// A word that names no state or no form is refused, and changes nothing.
	// The report reads values[4] and values[5]: the key does not go with them.
	report, report_status := root_ring.machine_key_report_of_values({4 = values[4], 5 = values[5]})
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
			machine_key_without_passphrase = true
			system.log_fact(.Info, Machine_Key_Sealed_Grants_Wait{})
		case .Passphrase:
			machine_key_without_passphrase = false
			system.log_fact(.Info, Machine_Passphrase_Grants_Wait{})
		}
		return .Ok
	case .Unreadable:
		if !waiting {
			return .Bad_State
		}
		table.state = .Record_Unreadable
		system.log_fact(.Warning, Machine_Passphrase_Record_Unreadable{})
		return .Ok
	case .Opened, .New:
		key_new := reported == .New
		key := transmute([disk_process.KEY_SIZE]u8)[4]u64{values[0], values[1], values[2], values[3]}
		defer key_erase(key[:])
		if key == {} {
			return .Bad_Operation
		}
		// The principals service started again since the key came, and
		// unlock asked for the passphrase again: the same key goes to the
		// new service, and the writes start again.
		if !key_new && !waiting && !table.key_held {
			return persisted_table_key_again(principals.MACHINE, &key)
		}
		// A new passphrase is set only on a machine with no record; an
		// opened key comes after the report that a record exists.
		if key_new && state != .No_Passphrase || !key_new && state != .Awaited {
			return .Bad_State
		}
		table.key_hash = blake3.hash(key[:])
		table.key_new = key_new
		// A new record comes from the one run of unlock that this service
		// started for it: a seal by the TPM has no passphrase.
		if key_new {
			machine_key_without_passphrase = unlock_run.mode == .Seal_Machine_Key
		}
		table.key_held = principals_table_key_send(principals.MACHINE, &key)
		table.state = .Reading
		persisted_table_read_begin(principals.MACHINE)
		return .Ok
	}
	return .Bad_Operation
}

// principal_key_take takes the key of the tag of the table of a named
// principal, which `unlock` gives with Principal_Unlock: values[0..3] the
// key, values[5] its origin. At the first unlock of the run the key goes on
// to the principals service, and the read of the table starts. A later
// unlock, after a lock, gives the key of the same file: a key whose hash
// differs is refused, as each table has one key. A read that failed starts
// again at such an unlock, and a principals service that started again
// gets the key again. The origin Principal_Key_Origin.New, which lets the
// read write over a table that does not verify, is taken only for a
// principal that this service saw created in this run: the rule then holds
// in this service, not in the code of `unlock` alone. The local copy is
// erased here, and the main loop erases the slot of the ring
// (key_ring_erase).
principal_key_take :: proc "contextless" (number: u64, values: ^[7]u64) -> system.Status {
	if number == principals.MACHINE || number >= principals.PRINCIPAL_CAPACITY {
		return .Bad_Handle
	}
	table := &persisted_tables[number]
	key := transmute([disk_process.KEY_SIZE]u8)[4]u64{values[0], values[1], values[2], values[3]}
	defer key_erase(key[:])
	origin, origin_status, _ := root_ring.member_of_word(root_ring.Principal_Key_Origin, values[5], .Principal_Unlock, 0)
	if key == {} || origin_status != .Ok {
		return .Bad_Operation
	}
	if origin == .New && !principal_created_in_this_run[number] {
		system.log_fact(.Warning, Unlock_Refused_New_Key{principal = number})
		return .Bad_State
	}
	if table.state != .Awaited {
		if !hashes_equal(table.key_hash, blake3.hash(key[:])) {
			system.log_fact(.Warning, Unlock_Refused_Other_Key{principal = number})
			return .Bad_State
		}
		if !table.key_held {
			return persisted_table_key_again(number, &key)
		}
		// The read at an earlier unlock failed: this unlock tries it again.
		// No write ran since, so the origin of the first key still holds.
		if table.state == .Unread {
			table.state = .Reading
			persisted_table_read_begin(number)
		}
		return .Ok
	}
	table.key_hash = blake3.hash(key[:])
	table.key_new = origin == .New
	table.key_held = principals_table_key_send(number, &key)
	table.state = .Reading
	persisted_table_read_begin(number)
	return .Ok
}

// persisted_table_key_again gives a principals service that started again
// the key of a table whose hash this service kept. A table whose writes
// stopped for want of the key writes again; a table whose read failed is
// read again.
@(private = "file")
persisted_table_key_again :: proc "contextless" (principal: u64, key: ^[disk_process.KEY_SIZE]u8) -> system.Status {
	table := &persisted_tables[principal]
	if !hashes_equal(table.key_hash, blake3.hash(key[:])) {
		system.log_fact(.Warning, Unlock_Refused_Other_Key{principal = principal})
		return .Bad_State
	}
	table.key_held = principals_table_key_send(principal, key)
	if !table.key_held {
		return .Ok
	}
	switch table.state {
	case .Unread:
		table.state = .Reading
		persisted_table_read_begin(principal)
	case .Unwritten:
		table.state = .Kept
		table.write_failures = 0
		table.write_again = false
		persisted_table_write_begin(principal)
	case .No_Passphrase, .Awaited, .Record_Unreadable, .Reading, .Kept, .Refused:
		// A read that runs, a kept table and a refused table go on with the
		// key: the next change writes it.
	}
	return .Ok
}

// hashes_equal compares two hashes in a time that does not depend on the
// first byte that differs.
hashes_equal :: proc "contextless" (first, second: blake3.Hash) -> bool {
	difference: u8
	for index in 0 ..< len(first) {
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
	// A record of a process of a session that the lock stopped can still be
	// in its ring: no change comes from a session that is not unlocked.
	if principal != principals.MACHINE && principal_records[principal].state != .Unlocked {
		system.log_fact(.Warning, Table_Change_Refused_Session_Locked{principal = principal})
		return true
	}
	switch persisted_tables[principal].state {
	case .No_Passphrase, .Kept:
		return false
	case .Awaited:
		if principal == principals.MACHINE {
			system.log_fact(.Warning, Machine_Table_Change_Refused_Not_Typed{})
		} else {
			system.log_fact(.Warning, Table_Change_Refused_No_Key{principal = principal})
		}
	case .Record_Unreadable:
		system.log_fact(.Warning, Machine_Table_Change_Refused_Record_Unreadable{})
	case .Reading:
		system.log_fact(.Warning, Table_Change_Refused_Reading{principal = principal})
	case .Unread:
		system.log_fact(.Warning, Table_Change_Refused_Unread{principal = principal})
	case .Refused:
		if disk_process.table_problem_is_format(persisted_tables[principal].refused_problem) {
			system.log_fact(.Warning, Table_Change_Refused_Format{principal = principal})
		} else {
			system.log_fact(.Warning, Table_Change_Refused_Not_Verified{principal = principal, table_key = text_field(key_words(principal), 32)})
		}
	case .Unwritten:
		system.log_fact(.Warning, Table_Change_Refused_Unwritten{principal = principal})
	}
	return true
}

// persisted_table_changed writes the table of a principal after a change,
// when it is kept on the disk.
persisted_table_changed :: proc "contextless" (principal: u64) {
	if principal >= principals.PRINCIPAL_CAPACITY {
		return
	}
	principals_rows_changed(principal)
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
persisted_table_revocation :: proc "contextless" (principal: u64, key: [disk_process.CLIENT_KEY_SIZE]u8) -> (can_come_back: bool) {
	principals_rows_changed(principal)
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
		system.log_fact(.Warning, Table_Writes_Restarted_By_Revocation{principal = principal})
		persisted_table_write_begin(principal)
		return false
	case .Reading, .Awaited, .Unread:
		already := false
		for place in 0 ..< table.revoked_key_count {
			if table.revoked_keys[place] == key {
				already = true
			}
		}
		if !already && table.revoked_key_count < disk_process.CLIENT_KEY_CAPACITY {
			table.revoked_keys[table.revoked_key_count] = key
			table.revoked_key_count += 1
		}
		can_come_back = table.state != .Reading
	case .Refused, .Record_Unreadable:
		can_come_back = true
	}
	if can_come_back {
		head: [16]u8
		system.log_fact(.Warning, Client_Key_Revocation_Not_Written{principal = principal, client_key = text_field(key_head_text(&head, key), 24)})
	}
	return can_come_back
}

// persisted_table_revoked_keys_take takes the keys revoked before the read
// out of the table that the read gives, and gives their count.
persisted_table_revoked_keys_take :: proc "contextless" (table: ^Persisted_Table, from_disk: ^disk_process.Grant_Table) -> (count: int) {
	for place in 0 ..< clamp(table.revoked_key_count, 0, disk_process.CLIENT_KEY_CAPACITY) {
		if disk_process.table_client_key_remove(from_disk, table.revoked_keys[place]) == .None {
			count += 1
		}
	}
	table.revoked_keys = {}
	table.revoked_key_count = 0
	return count
}

// persisted_table_open makes the connection of the principals service to
// the store `module_files` of a principal, and gives the service copies of
// its three handles through its ring. It gives the cause when it fails.
persisted_table_open :: proc "contextless" (principal: u64) -> (cause: string, given: [3]system.Handle, opened: bool) {
	table := &persisted_tables[principal]
	if principals_process == nil || principals_stopping || principals_ring.head == nil {
		return TABLE_CAUSE_NO_SERVICE, {}, false
	}
	table.keeper = {}
	copy(table.keeper.name[:len(table.keeper.name) - 1], disk_process.STORE_NAME)
	table.keeper.principal = principal
	storage_name := role_holder_name(.Storage)
	connection, service, ring_memory, region_memory, status := connection_open(&table.keeper, storage_name)
	if status != .Ok {
		return TABLE_CAUSE_NO_CONNECTION, {}, false
	}
	// The handle of the storage service is a copy of its own, so its
	// revocation does not reach the handle of its row. The copy has Give so
	// that this service can give it through the ring; the service receives
	// it with Read only.
	storage_copy: system.Handle
	storage_copy, status = system.give(0, service.process, {.Read, .Give})
	sources := [3]system.Handle{storage_copy, ring_memory, region_memory}
	rights := [3]system.Rights{{.Read}, {.Read, .Write}, {.Read, .Write}}
	given_count := 0
	for source, index in sources {
		if status != .Ok {
			break
		}
		given[index], status = give_through_service_ring(principals_process.process, principals_ring_memory, source, rights[index], &principals_process.service_ring_ready)
		if status == .Ok {
			given_count += 1
		}
	}
	table.connection = connection
	table.storage_handles = sources
	if status != .Ok {
		persisted_table_end(principal)
		return TABLE_CAUSE_HANDLES_NOT_GIVEN, {}, false
	}
	return "", given, true
}

// persisted_table_send sends the call of a table to the principals service:
// its handles and, in a place of the transfer region, the name of the
// storage service and, for a write, the table with no tag.
persisted_table_send :: proc "contextless" (principal: u64, call: Persisted_Table_Call) -> (cause: string, sent: bool) {
	table := &persisted_tables[principal]
	given: [3]system.Handle
	opened: bool
	if cause, given, opened = persisted_table_open(principal); !opened {
		return cause, false
	}
	persisted_table_input = {principal = principal}
	storage_name := role_holder_name(.Storage)
	persisted_table_input.storage_module_length = u64(copy(persisted_table_input.storage_module[:], storage_name))
	command := rd.Principals_Ring_Command.Table_Read
	if call == .Write {
		persisted_table_input.table = table.bytes
		command = .Table_Write
	}
	values := [7]u64{0 = u64(given[0]), 1 = u64(given[1]), 2 = u64(given[2])}
	tag, place_sent := principals_place_send(command, &persisted_table_input, size_of(persisted_table_input), &values, 3)
	if !place_sent {
		persisted_table_end(principal)
		return TABLE_CAUSE_NO_SERVICE, false
	}
	table.tag = tag
	table.call = call
	table.deadline = system.time() + TABLE_CALL_DEADLINE_MILLISECONDS
	return "", true
}

// persisted_table_read_begin starts the read of a table, after its key
// came. A read that cannot start leaves the table unread.
persisted_table_read_begin :: proc "contextless" (principal: u64) {
	if !persisted_tables[principal].key_held {
		persisted_table_read_failed(principal, TABLE_CAUSE_NO_SERVICE)
		return
	}
	if cause, sent := persisted_table_send(principal, .Read); !sent {
		persisted_table_read_failed(principal, cause)
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
	if !table.key_held {
		persisted_table_write_failed(principal, table_call_failure_causes[.No_Key])
		return
	}
	disk_process.table_body_encode(&disk_grant_tables[principal], &table.bytes)
	if cause, sent := persisted_table_send(principal, .Write); !sent {
		persisted_table_write_failed(principal, cause)
	}
}

// persisted_table_end gives back what the call of a table held: the copies
// of the handles in the principals service, the handles of this service and
// the connection.
persisted_table_end :: proc "contextless" (principal: u64) {
	table := &persisted_tables[principal]
	for &handle in table.storage_handles {
		if handle == 0 {
			continue
		}
		if principals_process != nil {
			system.handle_revoke(handle, principals_process.process)
		}
		system.close(handle)
		handle = 0
	}
	if table.connection != nil {
		disconnect(table.connection)
	}
	table.connection = nil
	table.tag = 0
	table.call = .None
}

// persisted_table_read_failed ends a read that got no answer that this
// service can use: the table stays unread.
persisted_table_read_failed :: proc "contextless" (principal: u64, cause: string) {
	persisted_tables[principal].state = .Unread
	system.log_fact(.Warning, Table_Not_Read{principal = principal, absent_grants_principal = principal, call_failure = text_field(cause, 72)})
}

// persisted_table_write_failed counts a failed try of a write, and tries
// again at once up to WRITE_TRY_LIMIT tries. Then the disk holds an older
// table, which can hold a grant that was taken since: no change is taken,
// and the log says it.
persisted_table_write_failed :: proc "contextless" (principal: u64, cause: string) {
	table := &persisted_tables[principal]
	table.write_failures += 1
	if table.write_failures < WRITE_TRY_LIMIT {
		system.log_fact(.Warning, Table_Write_Tried_Again{principal = principal, try_number = u64(table.write_failures + 1), try_limit = u64(WRITE_TRY_LIMIT), call_failure = text_field(cause, 72)})
		persisted_table_write_begin(principal)
		return
	}
	table.state = .Unwritten
	table.write_again = false
	system.log_fact(.Warning, Table_Write_Given_Up{principal = principal, try_limit = u64(WRITE_TRY_LIMIT), call_failure = text_field(cause, 72)})
}

// persisted_table_failed ends a call that got no answer that this service
// can use.
persisted_table_failed :: proc "contextless" (principal: u64, cause: string) {
	call := persisted_tables[principal].call
	persisted_table_end(principal)
	if call == .Read {
		persisted_table_read_failed(principal, cause)
	} else {
		persisted_table_write_failed(principal, cause)
	}
}

// persisted_tables_step ends each call whose principals service did not
// answer in time, and stops that service: its place in the transfer region
// would stay taken for ever. The answers come in principals_answers.
persisted_tables_step :: proc "contextless" () {
	now := system.time()
	for number in 0 ..< u64(principals.PRINCIPAL_CAPACITY) {
		table := &persisted_tables[number]
		if table.call != .None && now >= table.deadline {
			// The stop comes first: the tries of a write that the failure
			// starts then find no service and no key, and do not take a
			// place of the service that is stopping.
			principals_service_silent_stop()
			persisted_table_failed(number, TABLE_CAUSE_SERVICE_SILENT)
		}
	}
}

// persisted_tables_service_ended ends each call that the principals service
// held when it stopped. The new service holds no key.
persisted_tables_service_ended :: proc "contextless" () {
	for number in 0 ..< u64(principals.PRINCIPAL_CAPACITY) {
		table := &persisted_tables[number]
		table.key_held = false
		if table.call != .None {
			persisted_table_failed(number, TABLE_CAUSE_SERVICE_STOPPED)
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

// persisted_table_answer takes the answer of the principals service to the
// call of a table, which a place of its transfer region holds. An answer
// whose tag names no call that runs is one line, and changes nothing: the
// call ended at its deadline.
persisted_table_answer :: proc "contextless" (record: ring.Record, status: rd.Principals_Ring_Status, place_offset: u64) {
	principal := u64(principals.PRINCIPAL_CAPACITY)
	for &table, number in persisted_tables {
		if table.call != .None && table.tag == record.tag {
			principal = u64(number)
		}
	}
	if principal >= principals.PRINCIPAL_CAPACITY {
		system.log_fact(.Warning, Principals_Answer_Refused{status_word = u64(record.kind), tag = u64(record.tag)})
		return
	}
	table := &persisted_tables[principal]
	switch status {
	case .Storage_Refused:
		// The error record is a claim of the principals service: its kind
		// and its unit must name members, and a refusal names a kind.
		error_record, error_record_known := errors.refusal_record_of_values(record.values)
		if !error_record_known {
			persisted_table_failed(principal, TABLE_CAUSE_BAD_ERROR_RECORD)
			return
		}
		// The error record is a fact of its own fields; the line of the
		// table names the refusal.
		system.log_fact(.Warning, Table_Call_Refused(errors.error_record_fact_fields(error_record)))
		persisted_table_failed(principal, TABLE_CALL_REFUSED)
		return
	case .Refused, .Bad_Command:
		failure, known := rd.table_call_failure_of_word(record.values[0])
		persisted_table_failed(principal, known ? table_call_failure_causes[failure] : TABLE_CAUSE_BAD_ANSWER)
		return
	case .Ok:
	}
	call := table.call
	switch call {
	case .None:
	case .Write:
		persisted_table_end(principal)
		table.write_failures = 0
		// The rows of the bytes that went to the disk: a row that lasts
		// until the machine stops is not among them.
		system.log_fact(.Info, Table_Written{principal = principal, rows = u64(table.bytes[disk_process.TABLE_OFFSET_COUNT]), client_keys = u64(table.bytes[disk_process.TABLE_OFFSET_CLIENT_KEY_COUNT]), table_key = text_field(key_words(principal), 32)})
		if table.write_again {
			table.write_again = false
			persisted_table_write_begin(principal)
		}
	case .Read:
		// The table is copied once out of the place, then checked with the
		// decoder of the disk: the principals service is a transport.
		intrinsics.mem_copy_non_overlapping(&persisted_table_read_copy, &principals_region[place_offset + u64(offset_of(rd.Table_Call_Input, table))], disk_process.TABLE_SIZE)
		persisted_table_end(principal)
		persisted_table_read_take(principal, record.values)
	}
}

// persisted_table_read_take takes what the principals service read: no
// table, a table that does not verify under the key, or a table that
// verified, which this service decodes again.
@(private = "file")
persisted_table_read_take :: proc "contextless" (principal: u64, values: [7]u64) {
	table := &persisted_tables[principal]
	outcome, outcome_known := rd.table_read_outcome_of_word(values[0])
	problem, problem_known := enum_word.member_of_word(disk_process.Table_File_Problem, values[1])
	if !outcome_known || !problem_known || outcome == .Absent && problem != .None {
		persisted_table_read_failed(principal, TABLE_CAUSE_BAD_ANSWER)
		return
	}
	absent := outcome == .Absent
	from_disk: disk_process.Grant_Table
	if outcome == .Decoded && problem == .None {
		decoded, decode_problem := disk_process.table_body_decode(&persisted_table_read_copy)
		if decode_problem != .None {
			persisted_table_read_failed(principal, TABLE_CAUSE_UNDECODED)
			return
		}
		from_disk = decoded
		// Only principal 0 chooses the start policy of the machine.
		problem = disk_process.table_principal_problem(&from_disk, principal == principals.MACHINE)
		// The table is a claim of the principals service: its rows pass
		// the border of Disk_Rows_Set, so no row gives a grant outside the
		// disk grant classes, whatever the service verified.
		if problem == .None && !disk_process.disk_rows_set_request_of_table(&from_disk, principal, 1, &persisted_table_read_rows) {
			persisted_table_read_failed(principal, TABLE_CAUSE_OUTSIDE_CLASS)
			return
		}
	}
	decision := disk_process.table_read_decision(absent, problem, table.key_new)
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
			system.log_fact(.Info, Table_Absent_Written{principal = principal})
		} else {
			new_record := principal == principals.MACHINE ? "the new machine passphrase" : "the new principal"
			table_refused_written_over_log(principal, problem, new_record)
		}
		table.write_failures = 0
		persisted_table_write_begin(principal)
		return
	case .Keep:
		table.state = .Refused
		table.refused_problem = problem
		table_refused_kept_log(principal, problem)
		return
	case .Take:
	}
	table.state = .Kept
	replaced := disk_grant_tables[principal].count
	if replaced > 0 {
		system.log_fact(.Info, Table_Read_Replacing{principal = principal, rows = u64(from_disk.count), client_keys = u64(from_disk.client_key_count), replaced_rows = u64(replaced), table_key = text_field(key_words(principal), 32)})
	} else {
		system.log_fact(.Info, Table_Read{principal = principal, rows = u64(from_disk.count), client_keys = u64(from_disk.client_key_count), table_key = text_field(key_words(principal), 32)})
	}
	// A key revoked before the read stays revoked: the disk still held it,
	// and it is written there no more.
	revoked := persisted_table_revoked_keys_take(table, &from_disk)
	disk_grant_tables[principal] = from_disk
	principals_rows_changed(principal)
	if revoked > 0 {
		system.log_fact(.Info, Table_Revoked_Keys_Kept{principal = principal, revoked_keys = u64(revoked)})
		table.write_failures = 0
		persisted_table_write_begin(principal)
	}
	// The client keys of the table hold again, and a key allowed before
	// the read that the table does not hold ends, as a row does.
	client_keys_after_read(principal)
}

// The cause of a call of a table that the storage service refused: the
// fact Table_Call_Refused before it holds the fields of the error record.
TABLE_CALL_REFUSED :: "the storage service refused the call"

// table_refused_written_over_log writes the line of a table on the disk
// that this service refuses and writes over. The sentence of a problem
// that fits the field is a Text field; the three longer ones have a fact
// type each, with their sentence in the template.
table_refused_written_over_log :: proc "contextless" (principal: u64, problem: disk_process.Table_File_Problem, new_record: string) {
	switch problem {
	case .Older_Format:
		system.log_fact(.Warning, Table_Refused_Older_Format_Written_Over{principal = principal, new_record = text_field(new_record, 32)})
	case .Bad_Row:
		system.log_fact(.Warning, Table_Refused_Bad_Row_Written_Over{principal = principal, new_record = text_field(new_record, 32)})
	case .Bad_Client_Keys:
		system.log_fact(.Warning, Table_Refused_Bad_Client_Keys_Written_Over{principal = principal, new_record = text_field(new_record, 32)})
	case .None, .Wrong_Size, .Not_Authentic, .Wrong_Magic, .Wrong_Format, .Too_Many_Rows, .Bad_Setting, .Two_Rows, .Two_Start_Policies, .Start_Policy_Of_A_Named_Principal, .Bytes_After_Rows:
		system.log_fact(.Warning, Table_Refused_Written_Over{principal = principal, new_record = text_field(new_record, 32), table_problem = text_field(disk_process.table_problem_sentences[problem], 104)})
	}
}

// table_refused_kept_log writes the line of a table on the disk that this
// service refuses and keeps, as table_refused_written_over_log does.
table_refused_kept_log :: proc "contextless" (principal: u64, problem: disk_process.Table_File_Problem) {
	switch problem {
	case .Older_Format:
		system.log_fact(.Warning, Table_Refused_Older_Format_Kept{principal = principal})
	case .Bad_Row:
		system.log_fact(.Warning, Table_Refused_Bad_Row_Kept{principal = principal})
	case .Bad_Client_Keys:
		system.log_fact(.Warning, Table_Refused_Bad_Client_Keys_Kept{principal = principal})
	case .None, .Wrong_Size, .Not_Authentic, .Wrong_Magic, .Wrong_Format, .Too_Many_Rows, .Bad_Setting, .Two_Rows, .Two_Start_Policies, .Start_Policy_Of_A_Named_Principal, .Bytes_After_Rows:
		system.log_fact(.Warning, Table_Refused_Kept{principal = principal, table_problem = text_field(disk_process.table_problem_sentences[problem], 104)})
	}
}