// The root ring: the commands that a program sends to the root service, the
// words of their records, and the rule of who can send each one.
//
// A program that the root service starts with one of the start grants
// `ROOT_RING_GRANTS` receives a root ring at the handle
// `system.GRANT_ROOT`. It writes `Root_Command` records on it; the root
// service reads each word of a record at one border of this package, which
// refuses a word that names no member, then checks the role of the sender
// with `sender_allowed`, then runs the command and sends a completion.
//
// The role of the sender is the set of start grants that the root service
// gave the program at its start. The name of the program is not read: a
// disk program has a nickname that it chose, and the nickname gives it no
// command (docs/MODULE_CONTRACT.md, "A program from a disk").
//
// The design: (src/md/api/root_ring.md).
package root_ring

import "base:intrinsics"
import "modus:contract/enum_word"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/start_grant"

// The ring to the root service. The name of the program is in values[0..4],
// but for `Start_From_Disk`, whose hash takes those values.
// The completion record has the tag of the command, and a Status as kind.
// When the status is not Ok, its values are an error record
// (errors.completion_record): the argument 1 is the name.
//
// A program with a root ring (`system.GRANT_ROOT`) writes these commands;
// the root service checks the role of the program for each one
// (ROOT_COMMAND_SENDERS).
//
// ```odin
// name := system.name_pack("clock")
// system.send(&root.commands, {kind = u32(root_ring.Root_Command.Start), tag = 1, values = {name[0], name[1], name[2], name[3], 0, 0, 0}})
// ```
Root_Command :: enum u32 {
	None       = 0, // Refused with `Unsupported`, as a word that names no command (command_of_word).
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

// command_of_word is the border of the kind of a record of the root ring:
// the one place where the word becomes a Root_Command. A word that names no
// member is refused, and so is None, which no sender sends: the root
// service answers both with `Unsupported` (command_refusal), and runs
// nothing.
command_of_word :: proc "contextless" (word: u32) -> (command: Root_Command, ok: bool) {
	read, known := enum_word.member_of_word(Root_Command, u64(word))
	if !known || read == .None {
		return .None, false
	}
	return read, true
}

// command_refusal is the error record of a kind that command_of_word
// refused: `Unsupported`, with the word as the value.
command_refusal :: proc "contextless" (word: u32) -> [7]u64 {
	return errors.ring_fail(word, .Unsupported, .None, 0, i64(word))
}

// Who can send a command of the root ring, by the start grants of the
// sender. The rule reads the role of the sender only, never its name.
Root_Command_Sender :: enum u8 {
	Nobody, // No program: None, which command_of_word refuses first.
	Root_Ring, // A program with the start grant Root_Ring, as the console.
	// A program with the start grant Root_Ring, or with Connect to a
	// service of its list: the root service checks the list, which is a
	// part of the role of the program.
	Root_Ring_Or_Connect,
	Each_Ring, // Each program that has a root ring: the end of a connection that it holds.
	// The program with the start grant Principals only: a program with
	// Root_Ring does not send these, as they carry the keys and the records
	// of the principals.
	Principals,
	// The program with the start grant Debugger only: it names a caller of
	// its own connections, and the root service applies the rule of the
	// debug access to that caller.
	Debugger,
}

// The sender of each command. The table is whole: a new command does not
// compile until its row says who sends it.
@(rodata)
ROOT_COMMAND_SENDERS := [Root_Command]Root_Command_Sender {
	.None                   = .Nobody,
	.Start                  = .Root_Ring,
	.Stop                   = .Root_Ring,
	.Connect                = .Root_Ring_Or_Connect,
	.Disconnect             = .Each_Ring,
	.Grants                 = .Root_Ring,
	.Revoke                 = .Root_Ring,
	.Replace                = .Root_Ring,
	.Connect_History        = .Root_Ring,
	.Principal_Create       = .Root_Ring,
	.Principal_Lock         = .Root_Ring,
	.Principals             = .Root_Ring,
	.Principal_Record       = .Principals,
	.Principal_Unlock       = .Principals,
	.Debug                  = .Debugger,
	.Palette_Provide        = .Root_Ring,
	.Start_From_Disk        = .Root_Ring,
	.Disk_Grant             = .Root_Ring,
	.Nickname_Move          = .Root_Ring,
	.Machine_Passphrase     = .Root_Ring,
	.Machine_Key            = .Principals,
	.Disk_Grant_Persistence = .Root_Ring,
	.Debug_Store            = .Debugger,
	.Machine_Seal           = .Root_Ring,
	.Principal_Change       = .Root_Ring,
	.Principal_Change_End   = .Principals,
	.Remote_Client          = .Root_Ring,
}

// The start grants that give a program a root ring. A program with none of
// them has no root ring, so it sends no command: a disk program, whose
// grants a command gives, and which no command gives one of these.
ROOT_RING_GRANTS :: bit_set[start_grant.Grant]{.Root_Ring, .Connect, .Principals, .Debugger}

// root_ring_given says if a program with these start grants receives a
// root ring at its start.
root_ring_given :: proc "contextless" (role: bit_set[start_grant.Grant]) -> bool {
	return role & ROOT_RING_GRANTS != {}
}

// The handles that the root service gives a program of the boot image at
// its start, by its start grants. Each one has one context slot
// (system.ROLE_HANDLE_SLOTS); several start grants can give one handle (the
// machine, the root ring). A start writes a handle only when role_handles
// gives it, so this mapping is the one that the start follows.
Role_Handle :: enum u8 {
	Display, // A program with no grant Terminal: the ring to the compositor.
	Root_Ring, // A start grant of ROOT_RING_GRANTS.
	Machine, // Inspect, Stop, Schedule, Events or Counters: one handle with those rights.
	Image,
	Log_Records,
	Service_Ring, // Serve.
	Terminal_Ring, // Terminal.
	Terminal_Text, // Terminal.
	Device_Ring, // Data_Disk, Scratch_Disk or Network_Device: one device service.
	Date_Page, // Clock.
	Date_Ports, // Clock.
	Storage_Ring, // Store, without Acts_For_Principal: its private store at its start.
	Storage_Region,
	Storage_Service,
	Replacements,
	Datagram_Ring, // Network.
	Datagram_Region, // Network.
	Network_Control, // Network_Device.
	Settings_Page, // Settings.
	Tpm_Ring, // Tpm.
	Tpm_Service, // Tpm.
	Tpm_Region, // Tpm.
	Client_Table, // Remote_Clients.
	Log, // Each program: the log.
}

// role_handles gives the handles that a start gives a role.
role_handles :: proc "contextless" (role: bit_set[start_grant.Grant]) -> (handles: bit_set[Role_Handle]) {
	handles += {.Log}
	if .Terminal in role {
		handles += {.Terminal_Ring, .Terminal_Text}
	} else {
		handles += {.Display}
	}
	if root_ring_given(role) {
		handles += {.Root_Ring}
	}
	if role & {.Inspect, .Stop, .Schedule, .Events, .Counters} != {} {
		handles += {.Machine}
	}
	if .Image in role {
		handles += {.Image}
	}
	if .Log_Records in role {
		handles += {.Log_Records}
	}
	if .Serve in role {
		handles += {.Service_Ring}
	}
	if role & {.Data_Disk, .Scratch_Disk, .Network_Device} != {} {
		handles += {.Device_Ring}
	}
	if .Network_Device in role {
		handles += {.Network_Control}
	}
	if .Clock in role {
		handles += {.Date_Page, .Date_Ports}
	}
	if .Store in role && .Acts_For_Principal not_in role {
		handles += {.Storage_Ring, .Storage_Region, .Storage_Service}
	}
	if .Replacements in role {
		handles += {.Replacements}
	}
	if .Network in role {
		handles += {.Datagram_Ring, .Datagram_Region}
	}
	if .Settings in role {
		handles += {.Settings_Page}
	}
	if .Tpm in role {
		handles += {.Tpm_Ring, .Tpm_Service, .Tpm_Region}
	}
	if .Remote_Clients in role {
		handles += {.Client_Table}
	}
	return handles
}

// sender_allowed says if a program with these start grants can send a
// command. A refused command gets `No_Grant` (sender_refusal) and runs
// nothing. For Connect with the grant Connect and not Root_Ring, the root
// service then checks the list of the services of the program.
sender_allowed :: proc "contextless" (command: Root_Command, role: bit_set[start_grant.Grant]) -> bool {
	if !root_ring_given(role) {
		return false
	}
	switch ROOT_COMMAND_SENDERS[command] {
	case .Nobody:
		return false
	case .Root_Ring:
		return .Root_Ring in role
	case .Root_Ring_Or_Connect:
		return .Root_Ring in role || .Connect in role
	case .Each_Ring:
		return true
	case .Principals:
		return .Principals in role
	case .Debugger:
		return .Debugger in role
	}
	return false
}

// sender_refusal is the error record of a command that its sender cannot
// send: `No_Grant`, with the unit Connection for a Connect to a service
// that the list of the sender does not name, else Root_Commands.
sender_refusal :: proc "contextless" (command: Root_Command) -> [7]u64 {
	if command == .Connect {
		return errors.ring_fail(u32(command), .No_Grant, .Connection, 1)
	}
	return errors.ring_fail(u32(command), .No_Grant, .Root_Commands)
}

// replace_refusal gives the error record of a refused Replace whose cause
// the state shows, from the status of the change of the table: `by` past
// the entries of the boot image, a name that names no module, a module
// that replaces itself, a full table. entry_count is the count of the
// entries of the boot image, name_in_image says if a module has the name,
// and capacity is the count of the records of the table. named false: no
// such cause, and the caller writes the record Refused with the status.
// A refusal of the signature of a row is a cause that only the root
// service knows, and it writes that record itself.
replace_refusal :: proc "contextless" (status: op.Status, by: u64, entry_count: u64, name_in_image: bool, capacity: i64) -> (record: [7]u64, named: bool) {
	kind := u32(Root_Command.Replace)
	switch {
	case status == .No_Right:
		// The sender lacks the start grant Replace.
		return sender_refusal(.Replace), true
	case status == .Bad_Handle && by > entry_count:
		return errors.ring_fail(kind, .Bad_Value, .None, 2, i64(min(by, 1 << 62)), i64(min(entry_count, 1 << 62))), true
	case status == .Bad_Handle && !name_in_image:
		return errors.ring_fail(kind, .Absent, .Modules, 1), true
	case status == .Bad_Operation:
		// A module does not replace itself.
		return errors.ring_fail(kind, .Bad_Value, .None, 2, i64(min(by, 1 << 62))), true
	case status == .No_Slot:
		return errors.ring_fail(kind, .Full, .Records, 0, 0, capacity), true
	}
	return {}, false
}

// member_of_word is the border of a word of a root command: the member, or
// the refusal that the root service answers. A word that names no member
// gives Bad_Operation and the error record Bad_Value of `argument`, with
// the word (at most 2^62) and the largest member. It reads and changes no
// state, so a refused word changes nothing.
member_of_word :: proc "contextless" ($Enum: typeid, word: u64, command: Root_Command, argument: i64) -> (member: Enum, status: op.Status, refusal: [7]u64) where intrinsics.type_is_enum(Enum) {
	read, ok := enum_word.member_of_word(Enum, word)
	if ok {
		return read, .Ok, {}
	}
	return {}, .Bad_Operation, word_refusal(command, argument, word, u64(max(Enum)))
}

// word_refusal is the error record of a word that names no member. It is
// not polymorphic, so a program that never reads such a word still uses
// the import of its record.
word_refusal :: proc "contextless" (command: Root_Command, argument: i64, word: u64, largest: u64) -> [7]u64 {
	return errors.ring_fail(u32(command), .Bad_Value, .None, argument, i64(min(word, 1 << 62)), i64(largest))
}


// The report of a Machine_Key command, read from its record: the state in
// values[4], and for .Awaited the form in values[5]. form is read only
// with .Awaited.
Machine_Key_Report :: struct {
	state: Machine_Key_State,
	form:  Machine_Key_Form,
}

// machine_key_report_of_values is the border of a Machine_Key command. A
// state that names no member, or for .Awaited a form that names no member,
// gives Bad_Operation: the root service then changes no table.
machine_key_report_of_values :: proc "contextless" (values: [7]u64) -> (report: Machine_Key_Report, status: op.Status) {
	state, state_ok := enum_word.member_of_word(Machine_Key_State, values[4])
	if !state_ok {
		return {}, .Bad_Operation
	}
	report.state = state
	switch state {
	case .Awaited:
		form, form_ok := enum_word.member_of_word(Machine_Key_Form, values[5])
		if !form_ok {
			return {}, .Bad_Operation
		}
		report.form = form
	case .Opened, .New, .Unreadable:
	}
	return report, .Ok
}

// The state of a principal in the root service.
Principal_State :: enum u64 {
	Absent   = 0, // No record has this number.
	Machine  = 1, // Principal 0: always there; its session has no unlock.
	Locked   = 2, // A named principal with no session.
	Unlocked = 3, // A named principal whose session runs.
	Creating = 4, // `unlock` asks for the passphrase of a new principal; no record yet.
}

// The names of the commands of the root ring, for the sentence of the
// error record of a completion that failed.
@(rodata)
root_command_names := [Root_Command]string {
	.None                   = "None",
	.Start                  = "Start",
	.Stop                   = "Stop",
	.Connect                = "Connect",
	.Disconnect             = "Disconnect",
	.Grants                 = "Grants",
	.Revoke                 = "Revoke",
	.Replace                = "Replace",
	.Connect_History        = "Connect_History",
	.Principal_Create       = "Principal_Create",
	.Principal_Lock         = "Principal_Lock",
	.Principals             = "Principals",
	.Principal_Record       = "Principal_Record",
	.Principal_Unlock       = "Principal_Unlock",
	.Debug                  = "Debug",
	.Palette_Provide        = "Palette_Provide",
	.Start_From_Disk        = "Start_From_Disk",
	.Disk_Grant             = "Disk_Grant",
	.Nickname_Move          = "Nickname_Move",
	.Machine_Passphrase     = "Machine_Passphrase",
	.Machine_Key            = "Machine_Key",
	.Disk_Grant_Persistence = "Disk_Grant_Persistence",
	.Debug_Store            = "Debug_Store",
	.Machine_Seal           = "Machine_Seal",
	.Principal_Change       = "Principal_Change",
	.Principal_Change_End   = "Principal_Change_End",
	.Remote_Client          = "Remote_Client",
}

// The name of the argument 1 of an error record of each command: the name
// of values[0..4], or what the command carries in its place.
@(rodata)
root_first_argument_names := [Root_Command]string {
	.None                   = "",
	.Start                  = "name",
	.Stop                   = "name",
	.Connect                = "name",
	.Disconnect             = "name",
	.Grants                 = "name",
	.Revoke                 = "name",
	.Replace                = "name",
	.Connect_History        = "name",
	.Principal_Create       = "name",
	.Principal_Lock         = "name",
	.Principals             = "name",
	.Principal_Record       = "name",
	.Principal_Unlock       = "name",
	.Debug                  = "name",
	.Palette_Provide        = "name",
	.Start_From_Disk        = "name",
	.Disk_Grant             = "name",
	.Nickname_Move          = "name",
	.Machine_Passphrase     = "name",
	.Machine_Key            = "name",
	.Disk_Grant_Persistence = "name",
	.Debug_Store            = "name",
	.Machine_Seal           = "name",
	.Principal_Change       = "name",
	.Principal_Change_End   = "name",
	.Remote_Client          = "key",
}

// The name of the argument 2 of an error record of each command: values[4],
// or the hash of a command that carries one. An empty text: the command
// has no such argument.
@(rodata)
root_second_argument_names := [Root_Command]string {
	.None                   = "",
	.Start                  = "",
	.Stop                   = "",
	.Connect                = "",
	.Disconnect             = "",
	.Grants                 = "",
	.Revoke                 = "grant",
	.Replace                = "by",
	.Connect_History        = "",
	.Principal_Create       = "",
	.Principal_Lock         = "",
	.Principals             = "number",
	.Principal_Record       = "",
	.Principal_Unlock       = "number",
	.Debug                  = "",
	.Palette_Provide        = "",
	.Start_From_Disk        = "hash",
	.Disk_Grant             = "grant",
	.Nickname_Move          = "hash",
	.Machine_Passphrase     = "",
	.Machine_Key            = "",
	.Disk_Grant_Persistence = "setting",
	.Debug_Store            = "",
	.Machine_Seal           = "",
	.Principal_Change       = "change",
	.Principal_Change_End   = "",
	.Remote_Client          = "action",
}

// command_of_record reads the command that an error record names: the
// number comes from another program. A number that names no member gives
// false, and so does None.
command_of_record :: proc "contextless" (command: i64) -> (read: Root_Command, ok: bool) {
	if command < 0 || command > i64(max(u32)) {
		return .None, false
	}
	return command_of_word(u32(command))
}

// root_command_name gives the name of a command of the root ring, or "an
// unknown command" for a number that names no command: the number comes
// from an error record.
root_command_name :: proc "contextless" (command: i64) -> string {
	read, ok := command_of_record(command)
	return ok ? root_command_names[read] : "an unknown command"
}

// root_argument_name gives the name of an argument of a command of the root
// ring, as an error record numbers it: 1 is the name, 2 is values[4]. An
// empty text: the command has no such argument, or the number names no
// command.
root_argument_name :: proc "contextless" (command: i64, argument: i64) -> string {
	read, ok := command_of_record(command)
	if !ok {
		return ""
	}
	switch argument {
	case 1:
		return root_first_argument_names[read]
	case 2:
		return root_second_argument_names[read]
	}
	return ""
}
