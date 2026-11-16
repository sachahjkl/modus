package system

import "base:intrinsics"
import module "modus:contract/module"

// The roles of the context of a program that the root service starts.
// A handle that the program was not granted is 0.

// The handle 0: the display ring to the compositor, a memory object with
// **Read** and **Write**. A program with a window sends its commands there,
// and receives its input as completion records (`src/library/support/display`).
GRANT_DISPLAY :: 0 // Memory: the ring to the compositor.
// The handle 1: the root ring, a memory object with **Read** and **Write**,
// for a program with the grant Root_Ring, as the console.
// It sends `Root_Command` records on it: start, stop, connect, grants,
// revoke, replace, and the commands of the principals. The root service
// checks each command against the grants of the sender.
GRANT_ROOT :: 1 // Memory: the ring to the root service, to start and stop programs.
// The handle 2: the machine, with only the rights of the grants of the
// program: **Inspect** to read the reports of the programs and of the
// kernel, **Stop** to stop the machine, **Schedule** to change the
// scheduling strategy.
GRANT_MACHINE :: 2 // The machine, with the rights of the role: Inspect, or Inspect and Stop.
// The handle 3: the memory of the boot image, with **Read**, for a program
// with the grant Image: it lists the modules, loads them, and reads the
// descriptions of their exports. Its size is the value 0.
GRANT_IMAGE :: 3 // Memory: the boot image, to list the modules.
// The handle 4: the memory of the records of the log of the kernel, with
// **Read** only, for a program with the grant Log_Records: it reads the
// lines of every program, and writes none.
GRANT_LOG_RECORDS :: 4 // Memory, with Read: the records of the log.
// The handle 5: the service ring of a service, a memory object with
// **Read** and **Write**. The root service names each new connection of a
// caller on it, with the call ring and the call region of that caller
// (`src/library/support/system/service.odin`). The file of the service is at the
// value 1.
GRANT_SERVICE :: 5 // Memory: the service ring. The root service names each connection of a caller on it.
// The handle 10: the replacement table of the machine, with **Read**
// only, for a program that loads modules by itself: its loader reads the
// table before each load, so a replacement reaches the loads that follow.
GRANT_REPLACEMENTS :: 10 // Memory, with Read: the replacement table of the machine (Replacement_Table). 6 to 9 are the terminal and the store (packages terminal, storage).
// The value 0: the size in bytes of the boot image of the handle 3.
GRANT_VALUE_IMAGE_SIZE :: 0
// The value 1, for a service: the address where the root service mapped
// the file of the program, read-only. The service reads the descriptions
// of its exports there, to check each call; the value 2 is its size.
GRANT_VALUE_FILE_ADDRESS :: 1 // A service: where the file of the program is, read-only (the descriptions of its exports).
// The value 2, for a service: the size in bytes of its file at the address
// of the value 1.
GRANT_VALUE_FILE_SIZE :: 2

// The ring to the root service. The name of the program is in values[0..4],
// but for `Start_From_Disk`, whose hash takes those values.
// The completion record has the tag of the command, and a Status as kind.
// When the status is not Ok, its values are an error record
// (errors.completion_record): the argument 1 is the name.
//
// A program with the grant of the root ring (`GRANT_ROOT`) writes these
// commands; the root service checks the role of the program for each one.
//
// ```odin
// name := system.name_pack("clock")
// system.send(&root.commands, {kind = u32(system.Root_Command.Start), tag = 1, values = {name[0], name[1], name[2], name[3], 0, 0, 0}})
// ```
Root_Command :: enum u32 {
	None       = 0, // Refused.
	Start      = 1, // Start the program of the boot image with this name. A program of the system (root, input, compositor, terminal, block, frame) is refused with `Reserved`; a name with no module with `Absent`.
	Stop       = 2, // Stop the program with this name. The compositor and the terminal are refused with `Reserved`; a name that runs no program with `Absent`.
	// Connect makes a connection to a service that runs. The completion has
	// three handles of the caller: values[0] the program (right Read: its
	// state), values[1] the call ring, values[2] the call region. values[3..7]
	// is the hash of the file of the program: its exports are described there.
	//
	// values[4] not 0: the connection is for the row values[4] - 1 of the
	// client table, whose serial is values[5] (modus:contract/remote,
	// Client_Table). Only a program with the start grant Remote_Clients
	// sends it. The connection acts for the principal of that row, and ends
	// when the grant of the row ends. A row with another serial is refused
	// with `Absent` (unit `Grants`); a row whose principal has its session
	// locked with `Absent` (unit `Principals`).
	Connect    = 3,
	Disconnect = 4, // End the connection to the service with this name; with values[4] not 0, the connection for that row of the client table, as Connect names it.
	// Grants reads the grants of the program with this name. The completion
	// has two sets of Root_Grant (bit n: grant n): values[0] the grants that
	// the program has, values[1] the grants that were revoked. values[2] is
	// the number of the principal whose session the program belongs to (0:
	// the machine), and values[3..6] the name of that principal, 31 bytes at
	// most, zero bytes after it (docs/PRINCIPALS.md).
	Grants     = 5,
	// Revoke ends one grant of the program with this name: values[4] is the
	// Root_Grant. The kernel ends each handle and each mapping that came
	// from the grant, in that program and in the programs that it gave them
	// to. values[0] of the completion is their count.
	Revoke     = 6,
	// Replace sets the replacement of the module with this name, in the
	// replacement table of the machine: values[4] is the number, from 1, of
	// the entry of the boot image of the module that replaces it. 0 removes
	// the replacement. The root service refuses it to a program that does
	// not have the role, and refuses a chain: a module that replaces is not
	// replaced. The completion has Bad_State for a chain, No_Slot for a
	// full table.
	Replace    = 7,
	// Connect_History makes the connection of the caller to the store of
	// its line history in the storage service (docs/CONSOLE.md, section 6).
	// The name of the command is "storage". It is a second connection to
	// the storage service, apart from the private store of the caller: a
	// store of its own, named after the caller with ".history", with a
	// small limit of blocks and no grant to act for the principal, so it
	// reaches that store and no other one. The completion is the completion
	// of Connect. The root service refuses it to a program that does not
	// have the role, and after a revocation of the grant History.
	Connect_History = 8,
	// The commands of the principals (docs/PRINCIPALS.md). The root service
	// takes Principal_Create, Principal_Lock, Principals and
	// Machine_Passphrase from a program with the grant Root_Ring, and
	// Principal_Record, Principal_Unlock, Machine_Key and
	// Principal_Change_End from the program `unlock` only.
	//
	// Principal_Create records a new named principal: the name is in
	// values[0..4]. The root service starts `unlock`, which asks for the
	// passphrase in its window, makes the keys and keeps them sealed in its
	// store. The completion comes at once: the creation ends in `unlock`.
	Principal_Create = 9,
	// Principal_Lock ends the session of the named principal that is
	// unlocked: each program of the session stops, and `unlock` starts
	// again. values[0] of the completion is the count of the programs
	// stopped.
	Principal_Lock = 10,
	// Principals reads the record of the principal with the number
	// values[4]: values[0] the state (Principal_State), values[1..4] its
	// name, zero bytes after it, values[5] the first 8 bytes of its public
	// key (0: none), values[6] for principal 0 the first 8 bytes of the
	// measure of the system in PCR 11 (0: not measured). A number with no
	// record is refused with Bad_Handle.
	Principals = 11,
	// Principal_Record gives the record of a named principal that `unlock`
	// keeps in its store: values[0..3] its public key (Ed25519, 32 bytes),
	// values[4..6] its name (1 to 23 bytes, zero bytes after it). The
	// completion has its number in values[0]: the same record gives the
	// same number, and a second record is refused with No_Slot.
	Principal_Record = 12,
	// Principal_Unlock starts the session of the principal with the number
	// values[4]: `unlock` opened its sealed keys with the passphrase.
	// values[0..3] is the key of the tag of the disk grant table of that
	// principal (modus:support/disk_program, table_key_of_principal_key),
	// and values[5] its origin: Principal_Key_Origin.Opened from the open of an
	// existing file, Principal_Key_Origin.New from the creation of the principal.
	// At the first unlock of a run the root service takes the key and reads
	// the table; a later unlock must give the same key, else it is refused
	// with Bad_State, and starts the read again when the first one failed.
	// Principal_Key_Origin.New for a principal whose record no creation made since
	// the machine started is refused with Bad_State. A key of 32 zero bytes,
	// or another origin, is refused with Bad_Operation.
	Principal_Unlock = 13,
	// Debug gives the debugger service the handle of the program with this
	// name, with the right Debug only, on behalf of one of its callers:
	// values[4] is the call ring of the connection of that caller, as the
	// service names it. The service becomes the debugger of the program
	// with `debug_attach` (docs/TOOLS.md, "The debugger"). The root service
	// gives the handle only when the caller acts for the principal whose
	// session runs that program, and when each grant of the program is a
	// grant that the caller holds itself: a debugger acts with each handle
	// of the program that it debugs. A grant refuses for each caller when
	// what it reaches belongs to that one program: a service, a private
	// store, a terminal, an endpoint of the network. After a revocation of
	// a grant of the caller, the root service ends each debugging that the
	// rule no longer gives.
	// The completion: values[0] the handle, values[1..4] the hash of the
	// file of the program, values[5] its principal. A refusal has the kind
	// `No_Grant` with the unit `Debug_Access`, and `found` is 1 + the start
	// grant that refuses (start_grant.Grant), which the sentence of the
	// record names. The grant is `debug` in `Grants`, a grant of the
	// caller; `Revoke` ends each handle that came from it, and the
	// debugging with them. With values[5] not 0, the service says that it
	// ended the debugging of the program for that caller: the root service
	// forgets the debug access. Only the program with the grant Debugger
	// sends this command.
	Debug = 14,
	// Palette_Provide makes the caller the palette provider of the desktop
	// (docs/CONSOLE.md, "8. The palette provider"). The root service makes the
	// entry table (modus:contract/palette_table) and one ring, and gives both to
	// the caller and to the compositor: the caller writes the table, the
	// compositor maps it read-only. The name of the command is not read.
	// The completion: values[0] the handle of the table, values[1] the
	// handle of the ring. The root service refuses it to a program that
	// does not have the grant Palette, after a revocation of that grant,
	// and when a provider exists already (Bad_State).
	Palette_Provide = 15,
	// Start_From_Disk starts a disk program: a program whose module file is
	// an object of the store `programs` of the storage service, and not a
	// file of the boot image
	// (docs/MODULE_CONTRACT.md, "A program from a disk").
	// This command does not carry its name as the others do:
	// values[0..3] is the hash of the module file (BLAKE3, 32 bytes), and
	// values[4..6] the name of the program and of its entry in the store, 1
	// to 23 bytes, zero bytes after it (modus:support/disk_program).
	//
	// The root service reads the object from the storage service and starts
	// its bytes only when their hash is the hash of the command: the
	// storage service does not choose what runs. The program receives the
	// log and a window, no grant, and the budget of a program that the
	// tables of the root service do not name; its name gives it nothing.
	// The program belongs to the session of the caller, and the store is
	// the store `programs` of the principal of that session.
	//
	// The completion comes when the program started or the load ended, and
	// not before: the root service serves each other ring meanwhile. A
	// refusal has an error record whose argument 1 is the name and whose
	// argument 2 is the hash: `Not_Authentic` for bytes with another hash,
	// `Absent` (unit `Objects`) for a name with no entry, `Exists` (unit
	// `Modules`) for the name of a module of the boot image, `Reserved` for
	// a name that the tables of the root service give a grant, `Busy` while
	// another load runs, `Too_Long` for a file over the limit, `No_Answer`
	// when the storage service gave no answer before the deadline, and
	// `Malformed` for bytes that are no module or whose import is not in
	// the boot image.
	//
	// values[0..3] all zero takes the hash from the row of the nickname in
	// the disk grant table of the principal: `Absent` (unit `Grants`) when
	// the nickname has no row. A row with another hash refuses the start
	// before any read: `Exists` (unit `Grants`), and the value is the first
	// 8 bytes of the hash of the row. A disk program whose row has the grant
	// store gets the store of its nickname.
	Start_From_Disk = 16,
	// Disk_Grant changes the disk grant table of the principal of the
	// caller (docs/MODULE_CONTRACT.md, "The grants of a disk program"):
	// values[0..2] the nickname, 1 to 23 bytes with zero bytes after it
	// (modus:support/disk_program, name_pack); values[4] a
	// Disk_Grant_Action, another word refused with `Bad_Value`; values[5] the start grant (modus:contract/start_grant). The
	// row names the hash that the nickname names now: its row, or the disk
	// program of the nickname that runs. The grant takes effect at the next
	// start. The caller must act for its principal (`No_Grant`, unit
	// `Acts_For_Principal`). A grant that no command gives is refused with
	// `Reserved` (unit `Grants`), one that no command gives yet with
	// `Unsupported`; a nickname with no row and no program with `Absent`
	// (unit `Programs`); a full table with `Full` (unit `Grants`).
	Disk_Grant = 17,
	// Nickname_Move points a nickname of the disk grant table of the
	// principal of the caller to another file: values[0..3] the hash,
	// values[4..6] the nickname, as Start_From_Disk carries them. Its grants
	// and its store follow. A nickname with no row is refused with `Absent`
	// (unit `Grants`); the same file with `Bad_Value`.
	Nickname_Move = 18,
	// Machine_Passphrase starts `unlock` to set the machine passphrase
	// (docs/PRINCIPALS.md, "Principal 0 and its machine passphrase"): its
	// window asks for it two times. The completion comes at once. A machine
	// that has a machine passphrase refuses a second one with `Exists`
	// (unit `Principals`); while `unlock` runs, `Busy`.
	Machine_Passphrase = 19,
	// Machine_Key comes from `unlock` only; values[4] says what it reports.
	// Machine_Key_State.Awaited: the machine has a machine passphrase that is not
	// typed yet, or a machine key sealed by the TPM that is not unsealed yet
	// (values[5] Machine_Key_Form.Sealed_By_The_Tpm), so a change of the disk
	// grant table of principal 0 is refused until the key comes. Machine_Key_State.Unreadable: the store holds a
	// record of the machine passphrase that `unlock` cannot read; a change
	// and a new machine passphrase are refused. Machine_Key_State.Opened and
	// Machine_Key_State.New: values[0..3] is the key of the tag of that table
	// (modus:support/disk_program, table_key_of_machine_key), from the open
	// of the record or from a new machine passphrase. The root service
	// reads the table, then writes it after each change. A table that does
	// not verify under an opened key is refused and kept; under a new key
	// it is written over, as no record signed it. A second key is refused
	// with Bad_State.
	Machine_Key = 20,
	// Disk_Grant_Persistence sets how long a row of the disk grant table of
	// the principal of the caller lasts across a restart: values[0..2] the
	// nickname, as Disk_Grant carries it, or no byte for the global
	// setting; values[4] a disk_program.Persistence (0 the global setting,
	// 1 persist, 2 forget; the global setting takes 1 or 2). The caller
	// must act for its principal. A nickname with no row is refused with
	// `Absent` (unit `Grants`).
	Disk_Grant_Persistence = 21,
	// Debug_Store gives the debugger service a connection to the storage
	// service that reads only, to the store `programs` of the principal of
	// the disk program with this name: the service reads there the debug
	// object of the module of the program
	// (docs/MODULE_CONTRACT.md, "The debug object of a disk program").
	// values[4] is the call ring of the caller, as for Debug. The root
	// service gives it only for a program that it gave this service the
	// debug access to, for that caller, and only for a disk program
	// (`Absent`, unit `Debug_Objects`). The completion: values[0] the
	// storage service (right Read: its state), values[1] the call ring,
	// values[2] the call region. With values[5] not 0, the service says
	// that it read the object: the root service ends the connection. The
	// connection ends in any case when the debug access ends. Only the
	// program with the grant Debugger sends this command.
	//
	// With values[6] not 0, the connection is for the stop report that the
	// root service kept of the disk program with this nickname, which
	// stopped on a fault: the caller must act for its principal, and the
	// grant `debug` of the caller must not be revoked; no debug access is
	// needed (`Absent`, unit `Stop_Reports`: no such report). The
	// completion adds values[3], one page with a disk_program.Kept_Stop_Report
	// (right Read), and values[4], the principal. The connection ends at the
	// end that the service sends with values[6], and when the caller or the
	// service stops.
	Debug_Store = 22,
	// Machine_Seal starts `unlock` to make a machine key that the TPM
	// service seals to the measure of the system, with a recovery key that
	// the window of `unlock` shows one time
	// (docs/PRINCIPALS.md, "The machine key sealed by the TPM").
	// The completion comes at once. A
	// machine with a record of its machine key refuses it with `Exists`
	// (unit `Principals`); a machine with no TPM service with `Unsupported`
	// (unit `Principals`); while `unlock` runs, `Busy`.
	Machine_Seal = 23,
	// Principal_Change starts `unlock` to change the passphrase of the
	// named principal of the session of the caller (values[4]
	// Principal_Change.Passphrase), or to make it a new recovery key
	// (Principal_Change.Recovery_Key): the window asks for the current
	// passphrase first (docs/PRINCIPALS.md, "A change of the passphrase").
	// The completion comes when the change ends, which takes the time of
	// the typing: values[0] the end (principals.Change_End), values[1] for
	// the end Refused the cause (principals.Change_Problem). A stop of
	// `unlock` before the end gives the end None. The caller must act for
	// its principal (`No_Grant`, unit `Acts_For_Principal`); a caller of
	// principal 0, or of a principal whose session is locked, is refused at
	// once with `Absent` (unit `Principals`); another value with
	// `Bad_Value`; while `unlock` runs, `Busy`.
	Principal_Change = 24,
	// Principal_Change_End comes from `unlock` only: the change that a
	// Principal_Change started ended. values[4] the end
	// (principals.Change_End), values[5] the cause (principals.Change_Problem).
	// The root service gives both to the caller of Principal_Change. With
	// no change in progress, `Bad_State`; a value out of its enum,
	// `Bad_Operation`.
	Principal_Change_End = 25,
	// Remote_Client changes the client table of the remote service
	// (modus:contract/remote, Client_Table; docs/PRINCIPALS.md, "The client
	// keys of remote"): values[0..3] is the Ed25519 public key of a client,
	// values[4] the action. Remote_Client_Action.Allow gives the key a row for the
	// principal of the caller: each call of that client then acts for it.
	// Remote_Client_Action.Revoke frees the row of the key: the root service ends
	// each connection to a service that was made for the row, and the remote
	// service ends the open connection of the client. The allow and the
	// revocation also change the disk grant table of the principal, which
	// keeps the key across a restart. The completion of a revocation has
	// the count of the connections that ended in values[0], and
	// REMOTE_CLIENT_KEY_CAN_COME_BACK in values[1] when the disk grant table
	// did not take the revocation. Remote_Client_Action.Read reads the place
	// values[5], below remote.CLIENT_READ_PLACES: a row of the client table,
	// then a contested key of the disk grant table of the caller, whose row
	// is a row of another principal. The completion has the key in
	// values[0..3], the principal in values[4], 1 in values[5] for a key of
	// the principal of the caller, and its state in values[6]
	// (Remote_Client_State.Holds, Remote_Client_State.Locked, Remote_Client_State.Contested).
	// The caller must act for its principal (`No_Grant`, unit
	// `Acts_For_Principal`). A key of zeros is refused with `Bad_Value`; a
	// key that another principal allowed with `Exists` (unit `Grants`); a
	// full table, or a principal with remote.CLIENT_ROWS_OF_ONE_PRINCIPAL
	// keys, with `Full` (unit `Grants`); an allow while the disk grant table
	// of the principal takes no change with `Refused`; a revocation of a key
	// that the principal of the caller did not allow with `Absent` (unit
	// `Grants`). A revocation is never refused for the state of the disk
	// grant table. The allow of a key that the principal allowed already
	// changes nothing.
	Remote_Client = 26,
}

// The enumerations below are words of the root ring: each value is the
// word of the record, so it is explicit and does not move. A word becomes
// its member at one place, member_of_word, which refuses a word that names
// no member.

// The action of a Remote_Client command, in values[4].
Remote_Client_Action :: enum u64 {
	Allow  = 1,
	Revoke = 2,
	Read   = 3,
}

// The state of a client key in values[6] of the completion of a
// Remote_Client_Action.Read.
Remote_Client_State :: enum u64 {
	Holds     = 0, // Each call of its client acts for the principal.
	Locked    = 1, // The session of the principal is locked: the key opens no connection until the unlock.
	Contested = 2, // Two principals allowed the key, one in this run and one in its disk grant table: it acts for neither until one of them revokes it.
}

// The flag of values[1] of the completion of a Remote_Client_Action.Revoke:
// the disk grant table of the principal did not take the revocation, so
// the key can come back at the next start of the machine. A flag, not a
// choice: 0 says the opposite.
REMOTE_CLIENT_KEY_CAN_COME_BACK :: 1

// The change of a Principal_Change command, in values[4].
Principal_Change :: enum u64 {
	Passphrase   = 1,
	Recovery_Key = 2,
}

// The action of a Disk_Grant command, in values[4].
Disk_Grant_Action :: enum u64 {
	Allow    = 1,
	Disallow = 2,
}

// The state that a Machine_Key command gives, in values[4].
Machine_Key_State :: enum u64 {
	Awaited    = 1,
	Opened     = 2,
	New        = 3,
	Unreadable = 4,
}

// values[5] of a Machine_Key command Machine_Key_State.Awaited: how the
// record of the machine key is sealed. Only the line of the log differs.
Machine_Key_Form :: enum u64 {
	Passphrase        = 0, // By a machine passphrase.
	Sealed_By_The_Tpm = 1, // By the TPM, and not by a machine passphrase.
}

// The origin of the key of a Principal_Unlock command, in values[5].
Principal_Key_Origin :: enum u64 {
	Opened = 1,
	New    = 2,
}

// member_of_word reads a word of a record as a member of the enumeration
// `Enum`. A word that names no member is refused: the caller answers it
// with an error record, and never takes it for a member.
member_of_word :: proc "contextless" ($Enum: typeid, word: u64) -> (member: Enum, ok: bool) where intrinsics.type_is_enum(Enum) {
	for candidate in Enum {
		if u64(candidate) == word {
			return candidate, true
		}
	}
	return {}, false
}

// The state of a principal in the root service.
Principal_State :: enum u64 {
	Absent   = 0, // No record has this number.
	Machine  = 1, // Principal 0: always there; its session has no unlock.
	Locked   = 2, // A named principal with no session.
	Unlocked = 3, // A named principal whose session runs.
	Creating = 4, // `unlock` asks for the passphrase of a new principal; no record yet.
}

// The replacement table of the machine. The root service writes it, and
// gives it with the right Read. It gives the records to each program that
// it starts (system.program_start); a program that loads modules reads the
// table before each load. version is odd while the root service writes.
//
// A reader copies the table with `replacements_read`, which reads again
// while the version changes; `replacements_write` is for the root service.
// See [replacement table](term:replacement-table).
REPLACEMENT_CAPACITY :: 32 // The replacements of one machine. `Replace` gives No_Slot for one more.
Replacement_Table :: struct {
	version: u32, // Odd while the root service writes; one more at each start and each end of a write.
	count:   u32, // The records in use.
	records: [REPLACEMENT_CAPACITY]module.Replacement,
}
#assert(size_of(Replacement_Table) <= PAGE_SIZE)

// replacements_read copies the records of a replacement table that another
// program writes. It reads again while the table changes.
replacements_read :: proc "contextless" (table: ^Replacement_Table, records: ^[REPLACEMENT_CAPACITY]module.Replacement) -> []module.Replacement {
	if table == nil {
		return nil
	}
	for {
		version := intrinsics.atomic_load_explicit(&table.version, .Acquire)
		if version & 1 != 0 {
			continue
		}
		count := min(intrinsics.volatile_load(&table.count), REPLACEMENT_CAPACITY)
		intrinsics.mem_copy_non_overlapping(records, &table.records, size_of(table.records))
		intrinsics.atomic_thread_fence(.Acquire)
		if intrinsics.atomic_load_explicit(&table.version, .Relaxed) == version {
			return records[:count]
		}
	}
}

// replacements_write changes a replacement table: it sets the record of
// `from`, or removes it when `to` is zero. The one writer is the root
// service.
replacements_write :: proc "contextless" (table: ^Replacement_Table, from, to: [32]u8) -> Status {
	place := -1
	for index in 0 ..< int(table.count) {
		if table.records[index].from == from {
			place = index
		}
	}
	if to == {} && place < 0 {
		return .Bad_Handle
	}
	if to != {} && place < 0 && table.count == REPLACEMENT_CAPACITY {
		return .No_Slot
	}
	intrinsics.atomic_store_explicit(&table.version, table.version + 1, .Release)
	intrinsics.atomic_thread_fence(.Release)
	switch {
	case to == {}:
		table.records[place] = table.records[table.count - 1]
		table.records[table.count - 1] = {}
		table.count -= 1
	case place < 0:
		table.records[table.count] = {from = from, to = to}
		table.count += 1
	case:
		table.records[place].to = to
	}
	intrinsics.atomic_store_explicit(&table.version, table.version + 1, .Release)
	return .Ok
}

// The names of the commands of the root ring and of their values, for the
// sentence of the error record of a completion that failed: the value 1 is
// the name (values[0..4]), the value 2 is values[4].
@(rodata)
root_command_names := [Root_Command]string {
	.None       = "None",
	.Start      = "Start",
	.Stop       = "Stop",
	.Connect    = "Connect",
	.Disconnect = "Disconnect",
	.Grants     = "Grants",
	.Revoke     = "Revoke",
	.Replace    = "Replace",
	.Connect_History = "Connect_History",
	.Principal_Create = "Principal_Create",
	.Principal_Lock = "Principal_Lock",
	.Principals = "Principals",
	.Principal_Record = "Principal_Record",
	.Principal_Unlock = "Principal_Unlock",
	.Debug      = "Debug",
	.Palette_Provide = "Palette_Provide",
	.Start_From_Disk = "Start_From_Disk",
	.Disk_Grant = "Disk_Grant",
	.Nickname_Move = "Nickname_Move",
	.Machine_Passphrase = "Machine_Passphrase",
	.Machine_Key = "Machine_Key",
	.Disk_Grant_Persistence = "Disk_Grant_Persistence",
	.Debug_Store = "Debug_Store",
	.Machine_Seal = "Machine_Seal",
	.Principal_Change = "Principal_Change",
	.Principal_Change_End = "Principal_Change_End",
	.Remote_Client = "Remote_Client",
}

// root_command_name gives the name of a command of the root ring, or "an
// unknown command" for a number out of `Root_Command`: the number comes from
// an error record.
root_command_name :: proc "contextless" (command: i64) -> string {
	return command >= 0 && command <= i64(max(Root_Command)) ? root_command_names[Root_Command(command)] : "an unknown command"
}

// root_argument_name gives the name of an argument of a command of the root
// ring, as an error record numbers it: 1 is the name, 2 is values[4]. An
// empty text: the command has no such argument.
root_argument_name :: proc "contextless" (command: i64, argument: i64) -> string {
	switch argument {
	case 1:
		if Root_Command(command) == .Remote_Client {
			return "key"
		}
		return "name"
	case 2:
		#partial switch Root_Command(command) {
		case .Remote_Client:
			return "action"
		case .Revoke:
			return "grant"
		case .Replace:
			return "by"
		case .Principals, .Principal_Unlock:
			return "number"
		case .Start_From_Disk, .Nickname_Move:
			return "hash"
		case .Disk_Grant:
			return "grant"
		case .Disk_Grant_Persistence:
			return "setting"
		case .Principal_Change:
			return "change"
		}
	}
	return ""
}

// The grants that the root service records for each program, and that it
// can revoke while the program runs (the command `Revoke`). Each grant is a
// handle of the context, or a connection that the root service made; a
// revocation ends each handle and each mapping that came from it.
//
// A recorded grant is not a start grant (modus:contract/start_grant). A start
// grant says what the role of a program gives, and its name has capital
// letters (`Inspect`). A recorded grant says which handle the root service
// gave, and its name is in lower case (`machine`): the console types it.
// Several start grants are one recorded grant: `Inspect`, `Stop`,
// `Schedule` and `Events` are rights of the one handle `machine`.
Root_Grant :: enum u32 {
	Log         = 0, // Write on the log.
	Machine     = 1, // The machine, with the rights of the role.
	Image       = 2, // Read the boot image.
	Log_Records = 3, // Read the records of the log.
	Store       = 4, // A private store in the storage service.
	Network     = 5, // An endpoint of datagrams in the network service, with one remote.
	Acts_For_Principal = 6, // To act for the principal of its session in each service that the program is connected to (isolated.CALLER_ACTS_FOR_PRINCIPAL).
	History     = 7, // The store of the line history of the console in the storage service (Root_Command.Connect_History).
	Debug       = 8, // The handle of another program with the right Debug, for each program that the command Debug named (Root_Command.Debug).
	Palette     = 9, // The entry table and the ring of the palette provider (Root_Command.Palette_Provide): the commands of the program show in the palette of the desktop.
}
// A set of grants: bit n is the grant n. The completion of `Grants` holds
// two of them.
Root_Grants :: bit_set[Root_Grant;u64]

// The name of each grant, as the console and the log write it.
root_grant_names := [Root_Grant]string {
	.Log         = "log",
	.Machine     = "machine",
	.Image       = "image",
	.Log_Records = "log_records",
	.Store       = "store",
	.Network     = "network",
	.Acts_For_Principal = "acts_for_principal",
	.History     = "history",
	.Debug       = "debug",
	.Palette     = "palette",
}

// A name of a program in a command of the root ring: 31 bytes at most, zero
// bytes after it.
Name :: [32]u8

// name_pack gives the four values of a name, as a command of the root ring
// carries it. A name longer than 31 bytes is cut.
name_pack :: proc "contextless" (name: string) -> (values: [4]u64) {
	bytes: Name
	copy(bytes[:len(bytes) - 1], name)
	return transmute([4]u64)bytes
}

// name_unpack gives the name of four values. Its last byte is always zero,
// whatever the values hold: a reader takes the bytes before the first zero.
name_unpack :: proc "contextless" (values: [4]u64) -> Name {
	bytes := transmute(Name)values
	bytes[len(bytes) - 1] = 0
	return bytes
}
