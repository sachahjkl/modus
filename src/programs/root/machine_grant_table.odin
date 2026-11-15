package root

// The disk grant table of principal 0 on the disk, under the machine
// passphrase (docs/PRINCIPALS.md, "Principal 0 and its machine passphrase";
// docs/MODULE_CONTRACT.md, "The grants of a disk program").
//
// With no machine passphrase, the table of principal 0 lasts until the
// machine stops. With one, `unlock` gives this service the key of the tag
// of the table (Machine_Key) after the passphrase is typed: this service
// reads the object `grant_table` of the store `programs`, then writes it
// after each change. The key is the only key that this service receives:
// it opens no seal, and it signs nothing but a table.
//
// A table that does not verify under a key that opened an existing record
// is refused and kept: it can be a good table of an older machine key, or
// a table that a byte changed, and a write over it would lose its grants
// with no sign. Only the key of a new machine passphrase, set when no
// record existed, writes over such a table: no key of a record signed it.
//
// The read and the write are calls of the storage service, which this
// service started and does not wait for: each one is a state of the loop
// (machine_table_step), with the deadline of a load, as the load of a
// module file is (disk_programs.odin). A write that fails is tried again
// at once, up to WRITE_TRY_LIMIT tries, so a `disallow` reaches the disk
// with no later change.

import "base:intrinsics"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/ring"
import "modus:support/disk_program"
import "modus:support/principals"
import "modus:support/storage"
import "modus:support/system"

// The tries of one write. Each try has the deadline of a load; the bound
// ends the tries when the storage service fails for good.
WRITE_TRY_LIMIT :: 3

// The states of the table of principal 0 on the disk.
Machine_Table_State :: enum u8 {
	No_Passphrase, // The machine has no passphrase: the table lasts until the machine stops.
	Awaited, // A machine passphrase is set and not typed: no row, and no change is taken.
	Record_Unreadable, // The store holds a record of the machine passphrase that unlock cannot read: no key, no change, and no new passphrase.
	Reading, // The key came, and the read of the table runs: no change is taken, as the read replaces the table.
	Kept, // The read ended: the table is written after each change.
	Unread, // The read failed: this service does not know what the disk holds, so no change is taken.
	Refused, // The table on the disk does not verify under the key of the record: it is kept, and no change is written over it.
	Unwritten, // A write failed WRITE_TRY_LIMIT times: the disk holds an older table, so no change is taken.
}

// The call of the storage service that runs for the table.
Machine_Table_Call :: enum u8 {
	None,
	Read,
	Write,
}

Machine_Table :: struct {
	state:          Machine_Table_State,
	key:            [disk_program.KEY_SIZE]u8, // The key of the tag. Zero bytes until it comes.
	key_new:        bool, // The key is the key of a new machine passphrase: no record signed the table on the disk.
	call:           Machine_Table_Call,
	write_again:    bool, // A change came while a write ran: one more write after it.
	write_failures: int, // The failed tries of the write that runs.
	connection:     ^Connection, // The connection to the storage service for the call. nil: none, or it ended.
	client:         storage.Client, // The call ring and the call region of that connection, mapped here.
	sent:           storage.Sent_Call,
	arguments:      [3]isolated.Argument,
	argument_count: int,
	bytes:          [disk_program.TABLE_SIZE]u8, // The table that a write sends.
	deadline:       u64, // The time at which the call ends with no answer.
}

machine_table: Machine_Table

// The caller record of the connection of this service for the table: its
// name is the name of the store `programs`, so the table is an object of
// the store of the module files of principal 0. grant_for gives it the
// limit of that store and no grant to act for a principal.
machine_table_keeper: Started

// machine_key_held says if this service holds the key of the tag: `unlock`
// then does not ask for the machine passphrase (after a lock).
machine_key_held :: proc "contextless" () -> bool {
	#partial switch machine_table.state {
	case .Reading, .Kept, .Unread, .Refused, .Unwritten:
		return true
	}
	return false
}

// machine_passphrase_ask runs the command Machine_Passphrase: it starts
// `unlock` to set the machine passphrase. A machine with a passphrase
// refuses a second one: a change is not built. A record that cannot be
// read refuses one too: it can hold a good key.
machine_passphrase_ask :: proc "contextless" () -> system.Status {
	if machine_table.state == .Record_Unreadable {
		system.log_in("programs", .Warning, "root: refused a machine passphrase: the record of the machine passphrase cannot be read, and a new one would replace a key that can be good")
		return .Bad_State
	}
	if machine_table.state != .No_Passphrase {
		system.log_in("programs", .Warning, "root: refused a machine passphrase: the machine has one, and a change is not built")
		return .Bad_State
	}
	if find("unlock") != nil {
		system.log_in("programs", .Warning, "root: refused a machine passphrase: unlock runs; it is set when unlock stopped")
		return .No_Slot
	}
	system.log_in("programs", .Info, "root: the machine passphrase is set in the window of unlock")
	return unlock_start(principals.MODE_SET_MACHINE_PASSPHRASE, "")
}

// machine_key_take runs the command Machine_Key, which only `unlock`
// sends: the machine has a passphrase that is not typed yet, its record
// cannot be read, or the key of the tag came. The key is a copy in this
// service; the local copy is erased here, and the main loop erases the
// slot of the ring (machine_key_ring_erase).
machine_key_take :: proc "contextless" (values: [7]u64) -> system.Status {
	state := machine_table.state
	waiting := state == .No_Passphrase || state == .Awaited || state == .Record_Unreadable
	switch values[4] {
	case system.MACHINE_KEY_AWAITED:
		if !waiting {
			return .Bad_State
		}
		machine_table.state = .Awaited
		system.log_in("programs", .Info, "root: the machine has a passphrase: the disk grants of principal 0 wait for it, and the machine runs")
		return .Ok
	case system.MACHINE_KEY_UNREADABLE:
		if !waiting {
			return .Bad_State
		}
		machine_table.state = .Record_Unreadable
		system.log_in("programs", .Warning, "root: the record of the machine passphrase cannot be read: the disk grants of principal 0 stay absent, and no change and no new passphrase is taken")
		return .Ok
	case system.MACHINE_KEY_OPENED, system.MACHINE_KEY_NEW:
		key_new := values[4] == system.MACHINE_KEY_NEW
		// A new passphrase is set only on a machine with no record; an
		// opened key comes after the report that a record exists.
		if key_new && state != .No_Passphrase || !key_new && state != .Awaited {
			return .Bad_State
		}
		key := transmute([disk_program.KEY_SIZE]u8)[4]u64{values[0], values[1], values[2], values[3]}
		defer machine_key_erase(key[:])
		if key == {} {
			return .Bad_Operation
		}
		machine_table.key = key
		machine_table.key_new = key_new
		machine_table.state = .Reading
		machine_table_read_begin()
		return .Ok
	}
	return .Bad_Operation
}

// machine_key_erase writes 0 over a copy of a key with volatile stores,
// which the compiler cannot remove.
machine_key_erase :: proc "contextless" (bytes: []u8) {
	for &item in bytes {
		intrinsics.volatile_store(&item, 0)
	}
}

// machine_key_ring_erase writes 0 over the values of the record of the
// command ring that the loop read last: the record Machine_Key, whose key
// would else stay in the ring until its slot is used again. `unlock` sends
// nothing more before the completion, so no record is written there now.
// The mask is the private mask of this service, so a false counter of the
// other side names a slot of the ring and nothing else.
machine_key_ring_erase :: proc "contextless" (queue: ^ring.Queue) {
	read := intrinsics.atomic_load_explicit(&queue.counters.read, .Relaxed)
	slot := &queue.records[(read - 1) & queue.mask]
	for &value in slot.values {
		intrinsics.volatile_store(&value, 0)
	}
}

// machine_table_refusal says if a change of the disk grant table of a
// principal is refused now, with its line on the log. Only the table of
// principal 0 has a state on the disk.
machine_table_refusal :: proc "contextless" (principal: u64) -> bool {
	if principal != principals.MACHINE {
		return false
	}
	switch machine_table.state {
	case .No_Passphrase, .Kept:
		return false
	case .Awaited:
		system.log_in("programs", .Warning, "root: refused a change of the disk grant table of principal 0: the machine passphrase is not typed; type it in the window of unlock")
	case .Record_Unreadable:
		system.log_in("programs", .Warning, "root: refused a change of the disk grant table of principal 0: the record of the machine passphrase cannot be read, so nothing is written over the table on the disk")
	case .Reading:
		system.log_in("programs", .Warning, "root: refused a change of the disk grant table of principal 0: its read from the store programs runs")
	case .Unread:
		system.log_in("programs", .Warning, "root: refused a change of the disk grant table of principal 0: the store programs did not give it, so a write could lose it")
	case .Refused:
		system.log_in("programs", .Warning, "root: refused a change of the disk grant table of principal 0: the table on the disk does not verify under the machine key, and it is kept; restore a version of it that verifies, then start the machine again")
	case .Unwritten:
		system.log_in("programs", .Warning, "root: refused a change of the disk grant table of principal 0: its last change is not on the disk; start the machine again")
	}
	return true
}

// machine_table_changed writes the table of principal 0 after a change,
// when it is kept on the disk.
machine_table_changed :: proc "contextless" (principal: u64) {
	if principal == principals.MACHINE && machine_table.state == .Kept {
		// A change during the tries of a write joins those tries, with no
		// more tries than the bound.
		if machine_table.call == .None {
			machine_table.write_failures = 0
		}
		machine_table_write_begin()
	}
}

// machine_table_open opens the connection of this service to the store
// `programs` of principal 0. It gives the reason when the storage service
// gives none.
machine_table_open :: proc "contextless" () -> (reason: string, opened: bool) {
	table := &machine_table
	machine_table_keeper = {}
	copy(machine_table_keeper.name[:len(machine_table_keeper.name) - 1], disk_program.STORE_NAME)
	machine_table_keeper.principal = principals.MACHINE
	connection, service, ring_memory, region_memory, status := connection_open(&machine_table_keeper, "storage")
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

// machine_table_send sends the call of the table, with its arguments: the
// root of the store, the name of the object, and for a write its bytes.
machine_table_send :: proc "contextless" (call: Machine_Table_Call) -> bool {
	table := &machine_table
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

// machine_table_read_begin starts the read of the table, after the key
// came. A read that cannot start leaves the table unread.
machine_table_read_begin :: proc "contextless" () {
	reason, opened := machine_table_open()
	if !opened {
		machine_table_read_failed(reason)
		return
	}
	if !machine_table_send(.Read) {
		machine_table_end()
		machine_table_read_failed("the storage service took no call")
	}
}

// machine_table_write_begin starts a write of the table of principal 0, or
// marks one more write after the write that runs.
machine_table_write_begin :: proc "contextless" () {
	table := &machine_table
	if table.call != .None {
		table.write_again = true
		return
	}
	disk_program.table_encode(&disk_grant_tables[principals.MACHINE], &table.key, &table.bytes)
	reason, opened := machine_table_open()
	if !opened {
		machine_table_write_failed(reason)
		return
	}
	if !machine_table_send(.Write) {
		machine_table_end()
		machine_table_write_failed("the storage service took no call")
	}
}

// machine_table_end gives back what the call held: the mappings, the
// handles and the connection.
machine_table_end :: proc "contextless" () {
	table := &machine_table
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

// machine_table_read_failed ends a read that got no answer that this
// service can use: the table stays unread.
machine_table_read_failed :: proc "contextless" (reason: string) {
	machine_table.state = .Unread
	system.log_in("programs", .Warning, "root: the disk grant table of principal 0 is not read: ", reason, "; the disk grants of principal 0 stay absent until the machine starts again")
}

// machine_table_write_failed counts a failed try of a write, and tries
// again at once up to WRITE_TRY_LIMIT tries. Then the disk holds an older
// table, which can hold a grant that was taken since: no change is taken,
// and the log says it.
machine_table_write_failed :: proc "contextless" (reason: string) {
	table := &machine_table
	table.write_failures += 1
	if table.write_failures < WRITE_TRY_LIMIT {
		system.log_in("programs", .Warning, "root: the disk grant table of principal 0 is not written: ", reason, "; try ", u64(table.write_failures + 1), " of ", u64(WRITE_TRY_LIMIT))
		machine_table_write_begin()
		return
	}
	table.state = .Unwritten
	table.write_again = false
	system.log_in("programs", .Warning, "root: the disk grant table of principal 0 is not written after ", u64(WRITE_TRY_LIMIT), " tries: ", reason, "; the disk keeps an older table, so a grant taken since can come back at the next start, and no change is taken")
}

// machine_table_failed ends a call that got no answer that this service
// can use.
machine_table_failed :: proc "contextless" (reason: string) {
	call := machine_table.call
	machine_table_end()
	if call == .Read {
		machine_table_read_failed(reason)
	} else {
		machine_table_write_failed(reason)
	}
}

// machine_table_step reads the answer of the call of the table, if it
// came, and does the next step. It never waits: with no answer, it adds the
// completions of the connection to the wait of the loop.
machine_table_step :: proc "contextless" (wait: ^system.Wait) {
	table := &machine_table
	if table.call == .None {
		return
	}
	if table.connection == nil {
		machine_table_failed("the storage service stopped")
		return
	}
	error: errors.Error_Record
	value, text, status, answered := storage.call_answer(&table.client, &table.sent, table.arguments[:table.argument_count], &error)
	if !answered {
		if !storage.connected(&table.client) {
			machine_table_failed("the storage service stopped")
			return
		}
		if system.time() >= table.deadline {
			machine_table_failed("the storage service gave no answer in time")
			return
		}
		system.wait_records(wait, &table.client.calls.completions)
		return
	}
	switch table.call {
	case .None:
	case .Read:
		absent := status == .Failed && value == storage.ERROR_ABSENT
		if !absent && status != .Ok {
			sentence: [240]u8
			writer := system.Writer{buffer = sentence[:]}
			storage.error_text(&writer, &table.client, &error)
			machine_table_failed(system.written(&writer))
			return
		}
		// The bytes are copied once, by table_decode, before any field is
		// read: the storage service is a transport.
		from_disk: disk_program.Grant_Table
		problem := disk_program.Table_File_Problem.None
		if !absent {
			from_disk, problem = disk_program.table_decode(text, &table.key)
		}
		machine_table_end()
		switch disk_program.table_read_decision(absent, problem, table.key_new) {
		case .Write_Over:
			table.state = .Kept
			if absent {
				system.log_in("programs", .Info, "root: the store programs holds no disk grant table of principal 0: the table of this machine is written there")
			} else {
				system.log_in("programs", .Warning, "root: refused the disk grant table of principal 0 from the store programs: ", disk_program.table_problem_sentences[problem], "; it gives no grant, and the table of the new machine passphrase is written over it")
			}
			machine_table_write_begin()
			return
		case .Keep:
			table.state = .Refused
			system.log_in("programs", .Warning, "root: refused the disk grant table of principal 0 from the store programs: ", disk_program.table_problem_sentences[problem], "; it gives no grant, and it is kept: no change is written over it")
			return
		case .Take:
		}
		table.state = .Kept
		replaced := disk_grant_tables[principals.MACHINE].count
		disk_grant_tables[principals.MACHINE] = from_disk
		if replaced > 0 {
			system.log_in("programs", .Info, "root: read the disk grant table of principal 0 from the store programs: ", u64(from_disk.count), " rows, with the tag of the machine key; it replaces ", u64(replaced), " rows made before the machine passphrase was typed")
		} else {
			system.log_in("programs", .Info, "root: read the disk grant table of principal 0 from the store programs: ", u64(from_disk.count), " rows, with the tag of the machine key")
		}
	case .Write:
		if status != .Ok {
			sentence: [240]u8
			writer := system.Writer{buffer = sentence[:]}
			storage.error_text(&writer, &table.client, &error)
			machine_table_failed(system.written(&writer))
			return
		}
		machine_table_end()
		table.write_failures = 0
		// The rows of the bytes that went to the disk: a row that lasts
		// until the machine stops is not among them.
		system.log_in("programs", .Info, "root: the disk grant table of principal 0 is written in the store programs: ", u64(table.bytes[disk_program.TABLE_OFFSET_COUNT]), " rows, with the tag of the machine key")
		if table.write_again {
			table.write_again = false
			machine_table_write_begin()
		}
	}
}

// machine_table_deadline gives the time at which the loop of this service
// must run again for the call of the table, or no time when none runs.
machine_table_deadline :: proc "contextless" () -> u64 {
	return machine_table.call == .None ? system.WAIT_FOREVER : machine_table.deadline
}
