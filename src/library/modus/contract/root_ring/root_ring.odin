// The root ring: the commands that a process sends to the root service, the
// words of their records, and the rule of who can send each one.
//
// A process that the root service starts with one of the start grants
// `ROOT_RING_GRANTS` receives a root ring at the handle
// `system.GRANT_ROOT`. It writes `Root_Command` records on it; the root
// service reads each word of a record at one border of this package, which
// refuses a word that names no member, then checks the start grant set of the sender
// with `sender_allowed`, then runs the command and sends a completion.
//
// The start grant set of the sender is the set of start grants that the root service
// gave the process at its start. The name of the process is not read: a
// disk process has a nickname that it chose, and the nickname gives it no
// command (docs/MODULE_CONTRACT.md, "A module from a disk").
//
// The design: (src/md/api/root_ring.md).
package root_ring

import "base:intrinsics"
import "modus:contract/call_outcome"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/memory_screen"
import "modus:contract/replacement_list"
import "modus:contract/start_grant"

// The ring to the root service. The name of the process is in values[0..4],
// but for `Start_From_Disk`, whose hash takes those values.
// The completion record has the tag of the command, and the word of its
// call outcome as kind (call_outcome.completion_outcome is its border).
// With any other outcome than Succeeded, its values are an error record
// (errors.completion_record): the argument 1 is the name. The procedure
// that refuses names the outcome and the kind together (refuse).
//
// A process with a root ring (`system.GRANT_ROOT`) writes these commands;
// the root service checks the start grant set of the process for each one
// (ROOT_COMMAND_SENDERS).
//
// ```odin
// name := system.name_pack("clock")
// system.send(&root.commands, {kind = u32(root_ring.Root_Command.Start), tag = 1, values = {name[0], name[1], name[2], name[3], 0, 0, 0}})
// ```
Root_Command :: enum u32 {
	None       = 0, // Refused with `Unsupported`, as a word that names no command (command_of_word).
	// Start the module of the boot image with this name. A module of the
	// system (root, input, compositor, terminal, block, frame) is refused
	// with `Reserved`; a name with no module with `Absent`.
	//
	// From the start policy (the start grant Start_Policy): a part of the
	// system that the root service starts in its own way (input,
	// compositor) is allowed, a name that runs already is refused
	// with `Exists` (unit `Processes`), and values[0] of the completion is a
	// handle of the process with the right Read, whose stop ends a wait of
	// the start policy.
	//
	// values[4]: a Start_Wiring_List. With In_The_List_Page, the wiring list
	// is in the list page of the sender, which Wire with List_Page gave it
	// (modus:contract/output, Wiring_List_Head): the root service applies it
	// before the first instruction of the process, whole or not at all
	// (src/md/features/module_outputs.md, "The wiring list of a start").
	// values[5]: a Start_Answer. With Process_Handle, values[0] of
	// the completion is a handle of the process with the right Read, which
	// a Wire names; values[1..6] are the rings of the rows whose reader is
	// the sender, in the order of the rows. values[6] is 0, or, from a start
	// policy for the holder of Display on a machine with no screen, the size
	// of a screen of memory (screen_of_memory_word).
	Start      = 1,
	// Stop the process with this name. The compositor and the terminal are
	// refused with `Reserved`; a name that runs no process with `Absent`.
	// From the start policy: only a process that it asked for, else
	// `Absent`.
	Stop       = 2,
	// Connect makes a connection to a service that runs. The completion has
	// three handles of the caller: values[0] the process (right Read: its
	// state), values[1] the call ring, values[2] the call region. values[3..7]
	// is the hash of the module file of the process: its exports are described there.
	//
	// values[4] not 0: the connection is for the row values[4] - 1 of the
	// client table, whose serial is values[5] (modus:contract/remote,
	// Client_Table). Only a process with the start grant Remote_Clients
	// sends it. The connection acts for the principal of that row, and ends
	// when the grant of the row ends. A row with another serial is refused
	// with `Absent` (unit `Grants`); a row whose principal has its session
	// locked with `Absent` (unit `Principals`).
	Connect    = 3,
	Disconnect = 4, // End the connection to the service with this name; with values[4] not 0, the connection for that row of the client table, as Connect names it.
	// Grants reads the grants of the process with this name. The completion
	// has two sets of Root_Grant (bit n: grant n): values[0] the grants that
	// the process has, values[1] the grants that were revoked. values[2] is
	// the number of the principal whose session the process belongs to (0:
	// the machine), and values[3..6] the name of that principal, 31 bytes at
	// most, zero bytes after it (docs/PRINCIPALS.md).
	Grants     = 5,
	// Revoke ends one grant of the process with this name: values[4] is the
	// Root_Grant. The kernel ends each handle and each mapping that came
	// from the grant, in that process and in the processes that it gave them
	// to. values[0] of the completion is their count.
	Revoke     = 6,
	// Replace sets the replacement of the module with this name, in the
	// replacement table of the machine: values[4] is the number, from 1, of
	// the entry of the boot image of the module that replaces it. 0 removes
	// the replacement. The root service refuses it to a process that does
	// not have the grant Replace, and refuses a chain: a module that replaces is not
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
	// of Connect. The root service refuses it to a process that does not
	// have the grant History_Store, and after a revocation of the grant History.
	Connect_History = 8,
	// The commands of the principals (docs/PRINCIPALS.md). The root service
	// takes Principal_Create, Principal_Lock, Principals and
	// Machine_Passphrase from a process with the grant Root_Ring, and
	// Principal_Record, Principal_Unlock, Machine_Key and
	// Principal_Change_End from the process `unlock` only.
	//
	// Principal_Create records a new named principal: the name is in
	// values[0..4]. The root service starts `unlock`, which asks for the
	// passphrase in its window, makes the keys and keeps them sealed in its
	// store. The completion comes at once: the creation ends in `unlock`.
	Principal_Create = 9,
	// Principal_Lock ends the session of the named principal that is
	// unlocked: each process of the session stops, and `unlock` starts
	// again. values[0] of the completion is the count of the processes
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
	// principal (modus:disk_process, table_key_of_principal_key),
	// and values[5] its origin: Principal_Key_Origin.Opened from the open of an
	// existing file, Principal_Key_Origin.New from the creation of the principal.
	// At the first unlock of a run the root service takes the key and reads
	// the table; a later unlock must give the same key, else it is refused
	// with Bad_State, and starts the read again when the first one failed.
	// Principal_Key_Origin.New for a principal whose record no creation made since
	// the machine started is refused with Bad_State. A key of 32 zero bytes,
	// or another origin, is refused with Bad_Operation.
	Principal_Unlock = 13,
	// Debug gives the debugger service the handle of the process with this
	// name, with the right Debug only, on behalf of one of its callers:
	// values[4] is the call ring of the connection of that caller, as the
	// service names it. The service becomes the debugger of the process
	// with `debug_attach` (docs/TOOLS.md, "The debugger"). The root service
	// gives the handle only when the caller acts for the principal whose
	// session runs that process, and when each grant of the process is a
	// grant that the caller holds itself: a debugger acts with each handle
	// of the process that it debugs. A grant refuses for each caller when
	// what it reaches belongs to that one process: a service, a private
	// store, a terminal, an endpoint of the network. After a revocation of
	// a grant of the caller, the root service ends each debugging that the
	// rule no longer gives.
	// The completion: values[0] the handle, values[1..4] the hash of the
	// module file of the process, values[5] its principal. A refusal has the kind
	// `No_Grant` with the unit `Debug_Access`, and `found` is 1 + the start
	// grant that refuses (start_grant.Grant), which the sentence of the
	// record names. The grant is `debug` in `Grants`, a grant of the
	// caller; `Revoke` ends each handle that came from it, and the
	// debugging with them. With values[5] not 0, the service says that it
	// ended the debugging of the process for that caller: the root service
	// forgets the debug access. Only the process with the grant Debugger
	// sends this command.
	Debug = 14,
	// Palette_Provide makes the caller the palette provider of the desktop
	// (docs/CONSOLE.md, "8. The palette provider"). The root service makes the
	// entry table (modus:contract/palette_table) and one ring, and gives both to
	// the caller and to the compositor: the caller writes the table, the
	// compositor maps it read-only. The name of the command is not read.
	// The completion: values[0] the handle of the table, values[1] the
	// handle of the ring. The root service refuses it to a process that
	// does not have the grant Palette, after a revocation of that grant,
	// and when a provider exists already (Bad_State).
	Palette_Provide = 15,
	// Start_From_Disk starts a disk process: a process whose module file is
	// an object of the store `module_files` of the storage service, and not a
	// file of the boot image
	// (docs/MODULE_CONTRACT.md, "A module from a disk").
	// This command does not carry its name as the others do:
	// values[0..3] is the hash of the module file (BLAKE3, 32 bytes), and
	// values[4..6] the name of the module and of its entry in the store, 1
	// to 23 bytes, zero bytes after it (modus:disk_process).
	//
	// The root service reads the object from the storage service and starts
	// its bytes only when their hash is the hash of the command: the
	// storage service does not choose what runs. The process receives the
	// log and a window, no grant, and the budget of a process that the
	// tables of the root service do not name; its name gives it nothing.
	// The process belongs to the session of the caller, and the store is
	// the store `module_files` of the principal of that session.
	//
	// The completion comes when the process started or the load ended, and
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
	// 8 bytes of the hash of the row. A disk process whose row has the grant
	// store gets the store of its nickname.
	Start_From_Disk = 16,
	// Disk_Grant changes the disk grant table of the principal of the
	// caller (docs/MODULE_CONTRACT.md, "The grants of a disk process"):
	// values[0..2] the nickname, 1 to 23 bytes with zero bytes after it
	// (modus:disk_process, name_pack); values[4] a
	// Disk_Grant_Action, another word refused with `Bad_Value`; values[5] the start grant (modus:contract/start_grant). The
	// row names the hash that the nickname names now: its row, or the disk
	// process of the nickname that runs. The grant takes effect at the next
	// start. The caller must act for its principal (`No_Grant`, unit
	// `Acts_For_Principal`). A grant that no command gives is refused with
	// `Reserved` (unit `Grants`), one that no command gives yet with
	// `Unsupported`; a nickname with no row and no process with `Absent`
	// (unit `Processes`); a full table with `Full` (unit `Grants`).
	Disk_Grant = 17,
	// Nickname_Move points a nickname of the disk grant table of the
	// principal of the caller to another file: values[0..3] the hash,
	// values[4..6] the nickname, as Start_From_Disk carries them. Its grants
	// and its store follow. A nickname with no row is refused with `Absent`
	// (unit `Grants`); the same file with `Bad_Value`; the row of the
	// chosen start policy with `Reserved` (unit `Grants`).
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
	// (modus:disk_process, table_key_of_machine_key), from the open
	// of the record or from a new machine passphrase. The root service
	// reads the table, then writes it after each change. A table that does
	// not verify under an opened key is refused and kept; under a new key
	// it is written over, as no record signed it. A second key is refused
	// with Bad_State.
	Machine_Key = 20,
	// Disk_Grant_Persistence sets how long a row of the disk grant table of
	// the principal of the caller lasts across a restart: values[0..2] the
	// nickname, as Disk_Grant carries it, or no byte for the global
	// setting; values[4] a disk_process.Persistence (0 the global setting,
	// 1 persist, 2 forget; the global setting takes 1 or 2). The caller
	// must act for its principal. A nickname with no row is refused with
	// `Absent` (unit `Grants`); the row of the chosen start policy, which
	// always persists, with `Reserved` (unit `Grants`).
	Disk_Grant_Persistence = 21,
	// Debug_Store gives the debugger service a connection to the storage
	// service that reads only, to the store `module_files` of the principal of
	// the disk process with this name: the service reads there the debug
	// object of the module of the process
	// (docs/MODULE_CONTRACT.md, "The debug object of a disk process").
	// values[4] is the call ring of the caller, as for Debug. The root
	// service gives it only for a process that it gave this service the
	// debug access to, for that caller, and only for a disk process
	// (`Absent`, unit `Debug_Objects`). The completion: values[0] the
	// storage service (right Read: its state), values[1] the call ring,
	// values[2] the call region. With values[5] not 0, the service says
	// that it read the object: the root service ends the connection. The
	// connection ends in any case when the debug access ends. Only the
	// process with the grant Debugger sends this command.
	//
	// With values[6] not 0, the connection is for the stop report that the
	// root service kept of the disk process with this nickname, which
	// stopped on a fault: the caller must act for its principal, and the
	// grant `debug` of the caller must not be revoked; no debug access is
	// needed (`Absent`, unit `Stop_Reports`: no such report). The
	// completion adds values[3], one page with a disk_process.Kept_Stop_Report
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
	// principal of the caller, with the uses of the word in values[5]
	// (remote.Client_Uses: Calls, View, Input; a word that
	// remote.client_uses_of_word refuses is refused with `Bad_Value`,
	// argument 3). With Calls, each call of that client acts for the
	// principal; with View, `remote_display` shows it the screen; with
	// Input, the keys and the pointer of the client go to the desktop. An
	// allow of a key of a row of the same principal adds the uses to the
	// row and keeps its serial.
	// Remote_Client_Action.Revoke frees the row of the key, whatever its
	// uses: the root service ends
	// each connection to a service that was made for the row, and the remote
	// services end the open connection of the client. The allow of Calls and
	// the revocation also change the disk grant table of the principal,
	// which keeps the key of Calls across a restart; View and Input last
	// until the machine stops. The completion of a revocation has
	// the count of the connections that ended in values[0], and
	// REMOTE_CLIENT_KEY_CAN_COME_BACK in values[1] when the disk grant table
	// did not take the revocation. Remote_Client_Action.Read reads the place
	// values[5], below remote.CLIENT_READ_PLACES: a row of the client table,
	// then a contested key of the disk grant table of the caller, whose row
	// is a row of another principal. The completion has the key in
	// values[0..3], the principal in values[4], the word of its uses in
	// values[5] for a key of the principal of the caller (0: no key at the
	// place), and its state in values[6]
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
	// with each of the uses changes nothing.
	Remote_Client = 26,
	// Machine_Usable comes from the start policy that runs only: the
	// machine is usable, as its own policy says (src/md/features/start_policy.md).
	// The root service then no longer starts the rescue start policy for a
	// stop or for the hang bound. Its name is not read. A second one, or
	// one from a start policy that the root service no longer waits for,
	// is refused with `Exists` (unit `Processes`).
	Machine_Usable = 27,
	// Start_Policy_Choice sets the start policy that the next start of the
	// machine runs (src/md/features/start_policy.md, "A start policy from
	// the disk"): values[0..3] the hash of its module file, values[4..6]
	// the nickname, as Start_From_Disk carries them. The hash 0 takes the
	// hash of the row of the nickname. A nickname of no byte ends the
	// choice: the next start runs the default start policy; with a hash that
	// is not 0 it is refused with `Bad_Value` (argument 2). The caller must
	// act for principal 0 (`No_Grant`, unit `Acts_For_Principal`; a caller
	// of a named principal gets `Absent`, unit `Principals`). The choice
	// is refused with `Refused` (unit `Principals`) when the machine key
	// does not open with no passphrase, as the root service reads the
	// choice before a passphrase can be typed; with `Absent` (unit `Grants`)
	// for a nickname with no row and no hash; with `Exists` (unit `Grants`)
	// for a row with another hash, the value the first 8 bytes of the hash
	// of the row; with `Reserved` (unit `Grants`) for a row that holds the
	// grant store; with `Full` (unit `Grants`) for a full table; and with
	// `Refused` while the table takes no change.
	Start_Policy_Choice = 28,
	// Wire joins one record output of one process to one record input of
	// another, or to the sender (src/md/features/module_outputs.md, "The
	// wiring and its rights"). values[0] is a Wire_Step; values[1..6] are
	// 0. Its name is not read.
	//
	// List_Page gives the list page of the sender: a memory object of
	// output.WIRING_LIST_PAGES_MOST pages that the root service makes once
	// from the budget of the sender and keeps. The completion: values[0] a
	// handle of it with Read and Write, given through the root ring. The
	// sender writes a wiring list there (modus:contract/output,
	// Wiring_List_Head); the root service copies the page from its own
	// handle, which a revocation by the sender does not reach.
	//
	// Apply applies the wiring list of one row in the list page. An end
	// Started names a process whose start the sender asked for, an end
	// Connected a service to which it holds a connection and for which it
	// acts for the principal; each by a process handle lent through the
	// root ring, whose number the list holds. The completion: values[0]
	// the output ring for a reader Asker, else 0; values[1] the number of
	// the wiring; values[2] the index of the record description in the
	// module file of the writer; values[3..6] the hash of that file. The
	// refusals and their error records: src/md/features/module_outputs.md,
	// "Errors".
	Wire = 29,
	// Start_Edit starts `edit` connected to a store of the principal of
	// the caller, to edit the named object path (src/md/features/editor.md).
	// values[0..3]: the name of the store, 1 to 31 bytes with zero bytes
	// after it (system.name_pack).
	// values[4]: the handle of a read-only memory object given through the
	// root ring holding the UTF-8 bytes of the object path.
	// values[5]: the byte length of the object path, 1 to
	// EDIT_TARGET_PATH_LIMIT.
	// values[6]: 0.
	// The caller must have the start grant Root_Ring and act for its
	// principal (Acts_For_Principal); the store must belong to the
	// principal of the caller.
	Start_Edit = 30,
	// Debug_Start starts a process of the boot image held before its first
	// instruction for the debugger service, on behalf of one of its callers,
	// so that the kernel records or replays it from that instruction
	// (src/md/features/record_and_replay.md, "The frequent tasks").
	// values[0..3]: the name of the module. values[4]: the call ring of the
	// connection of the caller, as for Debug. values[5]: the step
	// (Debug_Start_Step). values[6]: 0 (debug_start_border).
	//
	// Start_Held starts the module as Start does for the caller, in the
	// session of the principal that the caller acts for, and gives the
	// debugger service the handle of the process with the right Debug
	// only, under the rule of Debug: the completion is the completion of
	// Debug. Start_Replay does the same with no start grant: the process
	// receives no handle but its budget and its log, and its context is the
	// one that the history writes back (Replay_Start). Release lets the held
	// process of the caller run, and Abandon stops it: values[0] of the
	// completion is 0. A caller holds one held process at a time; the end
	// of its debug access lets a process held with Start_Held run, and
	// stops one held with Start_Replay. Only the process with the grant
	// Debugger sends this command.
	Debug_Start = 31,
	// Plan_Roles gives the core the roles of the plan of principal 0
	// (src/md/features/declarations.md, "Apply, the difference and the
	// rollback"). values[0] is a root_delegation.Plan_Roles_Step;
	// values[1..6] are 0, but values[1] of Loaded. Its name is not read.
	//
	// Page gives the roles page: one page that the core makes once and
	// keeps. The completion: values[0] a handle of it with Read and Write,
	// given through the root ring, values[1] the serial of the set of
	// overrides in force, values[2] its generation. The sender writes a
	// root_delegation.Plan_Roles_Set there.
	//
	// Apply and Rollback copy the set once out of the page, check it whole
	// (root_delegation.plan_roles_set_check, then the module of each hash in
	// the boot image and its contract), and replace the overrides of the
	// roles with it in one step: a refused set changes nothing. The
	// completion: values[0] the new serial, values[1] the generation. A
	// refusal has the kind Refused (unit Records), the index of the
	// override as the argument and the Plan_Roles_Refusal as the value
	// found; Bad_State with no page.
	//
	// Loaded says that the sender read the current plan of principal 0 at
	// its start: values[1] is a root_delegation.Plan_Roles_Load_Outcome. At
	// the start of the machine the core waits for it, within the hang
	// bound, before it starts the start policy. The completion: values[0]
	// the serial in force, values[1] its generation. Only the process with
	// the start grant Plans sends this command.
	Plan_Roles = 32,
	// Screen_Budget grows the budgets of the compositor and of the service of
	// the remote display for a size of a screen of memory past the size that
	// their start paid, or ends a growth (src/md/features/screen_of_memory.md,
	// "The growth of the budgets"). values[0] is a Screen_Budget_Step. Its
	// name is not read. Only the process with the start grant Screen_Capture
	// sends it.
	//
	// Grow: values[1] the width, values[2] the height, values[3..6] 0. The
	// root service makes one extra budget for each process, both or neither
	// (memory_screen.screen_budget_grow_decide), gives the compositor its
	// handle with Screen_Budget_Give on the control ring, then answers:
	// values[0] the handle of the extra budget of the sender, with Read and
	// Spend, values[1] its pages, values[2] the number of the growth, never
	// 0. A growth while the sender holds an extra budget is a replacement:
	// the share pays both. A refusal has the status No_Budget, the kind
	// Refused (unit Pages), the width as the value and the
	// memory_screen.Grow_Refusal as the value found; nothing is made, and the
	// extra budgets in force stay.
	//
	// Release: values[1] the number of a growth, values[2..6] 0. The sender
	// closed its extra budget of that growth: the root service takes back
	// each handle of it in other processes, and closes its own when all its
	// pages are back; until then they count against the share. Refused with
	// Bad_State and the kind Absent when the sender holds none of that
	// growth.
	Screen_Budget = 33,
	// Wide_Grant_Ask opens the path of a wide grant
	// (src/md/features/wide_grants.md, "The path of a grant, end to end"):
	// values[0..3] the client key of the agent, values[4] the word of the
	// scopes that it proposes (wide_grants.Wide_Authorities), values[5] the
	// duration in milliseconds, values[6] 0. The sender acts for the
	// principal of the row of the key in the client table. The completion
	// comes at once, with the serial of the flow in values[0]: the grant
	// comes after the screen and the proof.
	Wide_Grant_Ask = 34,
	// Wide_Grant_Proof is the end of the proof of `unlock` in the mode
	// Prove_Wide_Grant: values[4] the principal, values[5] a
	// Wide_Grant_Proof_Outcome. Only the holder of Principals sends it.
	Wide_Grant_Proof = 35,
	// Wide_Grant_End ends the wide grant of a client key: values[0..3] the
	// key. The sender acts for the principal of the grant.
	Wide_Grant_End = 36,
	// Wide_Grant_Agent_Ask is the ask of an agent through `remote`
	// (src/md/features/wide_grants.md, "The ask of an agent"): values[0..3]
	// the key that the client proved in its handshake, values[4] the word of
	// the scopes, values[5] the duration in milliseconds, values[6] 0. The
	// principal is the principal of the row of the key. Only the holder of
	// Remote_Clients sends it. The completion: the serial of the flow in
	// values[0], as for Wide_Grant_Ask.
	Wide_Grant_Agent_Ask = 37,
	// Wide_Grant_Second_Connection says that a second connection of a key
	// came while the row of the key held a wide grant: values[0..3] the key,
	// the other values 0. The root service ends the grant with the reason
	// Duplicate_Connection. Only the holder of Remote_Clients sends it.
	Wide_Grant_Second_Connection = 38,
}

// The step of a Screen_Budget, in values[0].
Screen_Budget_Step :: enum u64 {
	Grow    = 1,
	Release = 2,
}

// screen_budget_step_of_word is the border of values[0] of a Screen_Budget.
screen_budget_step_of_word :: proc "contextless" (word: u64) -> (step: Screen_Budget_Step, ok: bool) {
	return enum_word.member_of_word(Screen_Budget_Step, word)
}

// The words of a Screen_Budget that passed its border.
Screen_Budget_Words :: struct {
	step:          Screen_Budget_Step,
	width, height: u64, // Grow: the size, which the decision checks against its bounds.
	growth:        u64, // Release: the number of a growth, never 0.
}

// screen_budget_words_of_values is the border of the values of a
// Screen_Budget: a step that names no member, a number of growth of 0 in a
// Release, or a word that must be 0 and is not, is refused, with the place
// of the word (1 to 7) for its error record.
screen_budget_words_of_values :: proc "contextless" (values: [7]u64) -> (words: Screen_Budget_Words, refused_place: int, ok: bool) {
	step, step_ok := screen_budget_step_of_word(values[0])
	if !step_ok {
		return {}, 1, false
	}
	first_free: int
	switch step {
	case .Grow:
		words = {step = step, width = values[1], height = values[2]}
		first_free = 3
	case .Release:
		if values[1] == 0 {
			return {}, 2, false
		}
		words = {step = step, growth = values[1]}
		first_free = 2
	}
	for place in first_free ..< len(values) {
		if values[place] != 0 {
			return {}, place + 1, false
		}
	}
	return words, 0, true
}

// values[5] of a Wide_Grant_Proof: how the proof of the principal ended.
// The values cross the root ring.
Wide_Grant_Proof_Outcome :: enum u64 {
	None      = 0, // Refused at the border.
	Proved    = 1, // The passphrase opened the keys of the principal.
	Cancelled = 2, // The principal ended the window with no passphrase.
	Refused   = 3, // The principal has no passphrase that proves it here.
}

// wide_grant_proof_outcome_of_word is the border of values[5] of a
// Wide_Grant_Proof: a word that names no member, and None, are refused.
wide_grant_proof_outcome_of_word :: proc "contextless" (word: u64) -> (outcome: Wide_Grant_Proof_Outcome, ok: bool) {
	member := enum_word.member_of_word(Wide_Grant_Proof_Outcome, word) or_return
	return member, member != .None
}

// values[5] of a Debug_Start: what it does.
Debug_Start_Step :: enum u64 {
	None         = 0, // Refused.
	Start_Held   = 1, // Start the module with its start grants, held before its first instruction.
	Start_Replay = 2, // Start the module with no start grant, held, for a replay.
	Release      = 3, // Let the held process of the caller run.
	Abandon      = 4, // Stop the held process of the caller: no export waits for it any more.
}

// debug_start_step_of_word is the border of values[5] of a Debug_Start:
// None and a word that names no member are refused.
debug_start_step_of_word :: proc "contextless" (word: u64) -> (step: Debug_Start_Step, ok: bool) {
	member, known := enum_word.member_of_word(Debug_Start_Step, word)
	if !known || member == .None {
		return .None, false
	}
	return member, true
}

// debug_start_border is the border of the values of a Debug_Start that are
// not the name and the call ring: the step of values[5], and values[6],
// which must be 0. A refusal gives Argument_Refused and the error record
// Bad_Value of the argument (3 for the step, 4 for values[6]), and the root
// service runs nothing.
debug_start_border :: proc "contextless" (values: [7]u64) -> (step: Debug_Start_Step, outcome: call_outcome.Call_Outcome, refusal: [7]u64) {
	read, ok := debug_start_step_of_word(values[5])
	if !ok {
		return .None, .Argument_Refused, word_refusal(.Debug_Start, 3, values[5], u64(max(Debug_Start_Step)))
	}
	if values[6] != 0 {
		return .None, .Argument_Refused, word_refusal(.Debug_Start, 4, values[6], 0)
	}
	return read, .Succeeded, {}
}

// values[0] of a Wire: what it does.
Wire_Step :: enum u64 {
	None      = 0, // Refused.
	List_Page = 1, // Give the list page of the sender.
	Apply     = 2, // Apply the list of one row in the list page.
}

// wire_step_of_word is the border of values[0] of a Wire: None and a word
// that names no member are refused.
wire_step_of_word :: proc "contextless" (word: u64) -> (step: Wire_Step, ok: bool) {
	member, known := enum_word.member_of_word(Wire_Step, word)
	if !known || member == .None {
		return .None, false
	}
	return member, true
}

// values[4] of a Start: where its wiring list is.
Start_Wiring_List :: enum u64 {
	None             = 0, // The start wires nothing.
	In_The_List_Page = 1, // The list page of the sender holds the wiring list of the child.
}

// start_wiring_list_of_word is the border of values[4] of a Start.
start_wiring_list_of_word :: proc "contextless" (word: u64) -> (place: Start_Wiring_List, ok: bool) {
	return enum_word.member_of_word(Start_Wiring_List, word)
}

// values[5] of a Start: what its completion gives.
Start_Answer :: enum u64 {
	Nothing        = 0, // No handle. values[0] of the completion is 0.
	Process_Handle = 1, // values[0] of the completion: the process, with the right Read.
}

// start_answer_of_word is the border of values[5] of a Start.
start_answer_of_word :: proc "contextless" (word: u64) -> (answer: Start_Answer, ok: bool) {
	return enum_word.member_of_word(Start_Answer, word)
}

// screen_of_memory_word gives values[6] of the Start of the holder of
// Display on a machine with no screen: the width in the low 32 bits and the
// height in the high 32 bits (src/md/features/screen_of_memory.md). 0: no
// screen of memory.
screen_of_memory_word :: proc "contextless" (width, height: u32) -> u64 {
	return u64(width) | u64(height) << 32
}

// screen_of_memory_of_word is the border of values[6] of a Start: 0 is no
// screen of memory, and any other word is a size inside the bounds of the
// contract memory_screen, or refused.
screen_of_memory_of_word :: proc "contextless" (word: u64) -> (width, height: u32, ok: bool) {
	if word == 0 {
		return 0, 0, true
	}
	width, height = u32(word), u32(word >> 32)
	if !memory_screen.size_in_bounds(u64(width), u64(height)) {
		return 0, 0, false
	}
	return width, height, true
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
// sender. The rule reads the start grant set of the sender only, never its name.
Root_Command_Sender :: enum u8 {
	Nobody, // No process: None, which command_of_word refuses first.
	Root_Ring, // A process with the start grant Root_Ring, as the console.
	// A process with the start grant Root_Ring, or with Connect to a
	// service of its list: the root service checks the list, which is a
	// part of the start grant set of the process.
	Root_Ring_Or_Connect,
	Each_Ring, // Each process that has a root ring: the end of a connection that it holds.
	// The process with the start grant Principals only: a process with
	// Root_Ring does not send these, as they carry the keys and the records
	// of the principals.
	Principals,
	// The process with the start grant Debugger only: it names a caller of
	// its own connections, and the root service applies the rule of the
	// debug access to that caller.
	Debugger,
	// A process with the start grant Root_Ring, or the start policy with
	// Start_Policy: the root service restricts what the start policy names.
	Root_Ring_Or_Start_Policy,
	// The process with the start grant Start_Policy only.
	Start_Policy,
	// The process with the start grant Plans only: the holder of the role
	// Plans names the holders of the roles of the machine.
	Plans,
	// The process with the start grant Screen_Capture only: the service of
	// the remote display, for the budgets of a screen of memory.
	Screen_Capture,
	// The process with the start grant Remote_Clients and a root ring: it
	// names a client key that proved itself in its handshake.
	Remote_Clients,
}

// The sender of each command. The table is whole: a new command does not
// compile until its row says who sends it.
@(rodata)
ROOT_COMMAND_SENDERS := [Root_Command]Root_Command_Sender {
	.None                   = .Nobody,
	.Start                  = .Root_Ring_Or_Start_Policy,
	.Stop                   = .Root_Ring_Or_Start_Policy,
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
	.Machine_Usable         = .Start_Policy,
	.Start_Policy_Choice    = .Root_Ring,
	.Wire                   = .Root_Ring_Or_Start_Policy,
	.Start_Edit             = .Root_Ring,
	.Debug_Start            = .Debugger,
	.Plan_Roles             = .Plans,
	.Screen_Budget          = .Screen_Capture,
	.Wide_Grant_Ask         = .Root_Ring,
	.Wide_Grant_Proof       = .Principals,
	.Wide_Grant_End         = .Root_Ring,
	.Wide_Grant_Agent_Ask   = .Remote_Clients,
	.Wide_Grant_Second_Connection = .Remote_Clients,
}

// The start grants that give a process a root ring. A process with none of
// them has no root ring, so it sends no command: a disk process, whose
// grants a command gives, and which no command gives one of these.
ROOT_RING_GRANTS :: bit_set[start_grant.Grant]{.Root_Ring, .Connect, .Principals, .Debugger, .Start_Policy, .Plans, .Screen_Capture}

// root_ring_given says if a process with these start grants receives a
// root ring at its start.
root_ring_given :: proc "contextless" (start_grant_set: bit_set[start_grant.Grant]) -> bool {
	return start_grant_set & ROOT_RING_GRANTS != {}
}

// The handles that the root service gives a process that it starts from
// the boot image, at its start, by its start grants. Each one has one context slot
// (system.START_GRANT_SET_HANDLE_SLOTS); several start grants can give one handle (the
// machine, the root ring). A start writes a handle only when start_grant_set_handles
// gives it, so this mapping is the one that the start follows.
Start_Grant_Set_Handle :: enum u8 {
	Display, // A process with no grant Terminal: the ring to the compositor.
	Root_Ring, // A start grant of ROOT_RING_GRANTS.
	Machine, // Inspect, Stop, Schedule, Events or Counters: one handle with those rights.
	Image,
	Log_Records,
	Service_Ring, // Serve.
	Terminal_Ring, // Terminal.
	Terminal_Text, // Terminal.
	Device_Ring, // Data_Disk, Scratch_Disk, Network_Device or Sound_Device: one device service.
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
	Device_Service, // Data_Disk, Scratch_Disk, Network_Device or Sound_Device: the device service, with Read, so that its stop ends a wait for its answer.
	Log, // Each process: the log.
}

// start_grant_set_handles gives the handles that a start gives a start grant set.
start_grant_set_handles :: proc "contextless" (start_grant_set: bit_set[start_grant.Grant]) -> (handles: bit_set[Start_Grant_Set_Handle]) {
	handles += {.Log}
	// The start policy has no window: it starts before the compositor, and
	// it shows nothing.
	if .Terminal in start_grant_set {
		handles += {.Terminal_Ring, .Terminal_Text}
	} else if .Start_Policy not_in start_grant_set {
		handles += {.Display}
	}
	if root_ring_given(start_grant_set) {
		handles += {.Root_Ring}
	}
	if start_grant_set & {.Inspect, .Stop, .Schedule, .Events, .Counters} != {} {
		handles += {.Machine}
	}
	if .Image in start_grant_set {
		handles += {.Image}
	}
	if .Log_Records in start_grant_set {
		handles += {.Log_Records}
	}
	if .Serve in start_grant_set {
		handles += {.Service_Ring}
	}
	if start_grant_set & {.Data_Disk, .Scratch_Disk, .Network_Device, .Sound_Device} != {} {
		handles += {.Device_Ring, .Device_Service}
	}
	if .Network_Device in start_grant_set {
		handles += {.Network_Control}
	}
	if .Clock in start_grant_set {
		handles += {.Date_Page, .Date_Ports}
	}
	if .Store in start_grant_set && .Acts_For_Principal not_in start_grant_set {
		handles += {.Storage_Ring, .Storage_Region, .Storage_Service}
	}
	if .Replacements in start_grant_set {
		handles += {.Replacements}
	}
	if .Network in start_grant_set {
		handles += {.Datagram_Ring, .Datagram_Region}
	}
	if .Settings in start_grant_set {
		handles += {.Settings_Page}
	}
	if .Tpm in start_grant_set {
		handles += {.Tpm_Ring, .Tpm_Service, .Tpm_Region}
	}
	if .Remote_Clients in start_grant_set {
		handles += {.Client_Table}
	}
	return handles
}

// sender_allowed says if a process with these start grants can send a
// command. A refused command gets `No_Grant` (sender_refusal) and runs
// nothing. For Connect with the grant Connect and not Root_Ring, the root
// service then checks the list of the services of the process.
sender_allowed :: proc "contextless" (command: Root_Command, start_grant_set: bit_set[start_grant.Grant]) -> bool {
	if !root_ring_given(start_grant_set) {
		return false
	}
	switch ROOT_COMMAND_SENDERS[command] {
	case .Nobody:
		return false
	case .Root_Ring:
		return .Root_Ring in start_grant_set
	case .Root_Ring_Or_Connect:
		return .Root_Ring in start_grant_set || .Connect in start_grant_set
	case .Each_Ring:
		return true
	case .Principals:
		return .Principals in start_grant_set
	case .Debugger:
		return .Debugger in start_grant_set
	case .Root_Ring_Or_Start_Policy:
		return .Root_Ring in start_grant_set || .Start_Policy in start_grant_set
	case .Start_Policy:
		return .Start_Policy in start_grant_set
	case .Plans:
		return .Plans in start_grant_set
	case .Screen_Capture:
		return .Screen_Capture in start_grant_set
	case .Remote_Clients:
		return .Remote_Clients in start_grant_set
	}
	return false
}

// The step at which the dispatch of one record ends, in the order of the
// steps: the border, the sender, the command.
Dispatch_Step :: enum u8 {
	Border  = 0, // The kind names no command, or None: Operation_Unsupported, and nothing runs.
	Sender  = 1, // The sender cannot send the command: Grant_Or_Right_Missing, and nothing runs.
	Command = 2, // The command runs.
}

// What the dispatch decides for one record before any command runs. A
// refusal holds its call outcome and its error record; a command that runs
// holds Succeeded and no record.
Dispatch_Decision :: struct {
	step:    Dispatch_Step,
	command: Root_Command, // None at the border.
	outcome: call_outcome.Call_Outcome,
	refusal: [7]u64,
}

// dispatch_decide is the decision of the dispatch of the root service for
// one record: the border of its kind, then the table of the senders with
// the start grants of the sender. service_listed says that the list of
// the start grant set of the sender names the service of values[0..4]: a Connect with
// the grant Connect and not Root_Ring needs it. The decision reads the
// start grant set and never the name, and reads and changes no state: the root
// service runs the command only when the step is Command.
dispatch_decide :: proc "contextless" (kind: u32, start_grant_set: bit_set[start_grant.Grant], service_listed: bool) -> Dispatch_Decision {
	command, known := command_of_word(kind)
	if !known {
		return {step = .Border, command = .None, outcome = .Operation_Unsupported, refusal = command_refusal(kind)}
	}
	allowed := sender_allowed(command, start_grant_set)
	if command == .Connect && .Root_Ring not_in start_grant_set && !service_listed {
		allowed = false
	}
	if !allowed {
		return {step = .Sender, command = command, outcome = .Grant_Or_Right_Missing, refusal = sender_refusal(command)}
	}
	return {step = .Command, command = command, outcome = .Succeeded}
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

// Why the root service refused a Replace: the contract of its refusal
// record. The root service writes it with replace_refusal_record
// (internal:root/replacement_rules decides the reason), and a reader reads
// it back with replace_refusal_of_record, never by the place of a field.
Replace_Refusal :: enum u8 {
	No_Grant             = 0, // The sender lacks the start grant Replace: the record of the sender.
	Entry_Past_The_Image = 1, // by past the entries: Bad_Value of argument 2, value by (at most 2^62), limit the count of the entries, unit None.
	Replaces_Itself      = 2, // The entry by is the module of the name: Bad_Value of argument 2, value by, unit Modules.
	No_Module            = 3, // No module of the boot image has the name: Absent of argument 1, unit Modules.
	No_Signed_Row        = 4, // No signed row names the pair, or the image has no list: Absent of argument 2, unit Records, value by.
	Chain                = 5, // A record of the table would chain to this one: State of argument 2, unit Records, value by.
	Row_Not_Authentic    = 6, // The row of the pair does not verify: Damaged of argument 2, unit Records, value by, found 0.
	List_Not_Valid       = 7, // The list breaks its format: Damaged of argument 2, unit Records, value by, found the List_Problem (1 or more).
	Table_Full           = 8, // The replacement table has no room: Full, unit Records, limit its capacity.
}

// The outcome of each refusal of a Replace.
@(rodata)
REPLACE_REFUSAL_OUTCOMES := [Replace_Refusal]call_outcome.Call_Outcome {
	.No_Grant             = .Grant_Or_Right_Missing,
	.Entry_Past_The_Image = .Argument_Refused,
	.Replaces_Itself      = .Argument_Refused,
	.No_Module            = .Nothing_Has_That_Name,
	.No_Signed_Row        = .Nothing_Has_That_Name,
	.Chain                = .Wrong_State,
	.Row_Not_Authentic    = .Data_Damaged,
	.List_Not_Valid       = .Data_Damaged,
	.Table_Full           = .Budget_Or_Capacity_Exhausted,
}

// replace_refusal_record writes the outcome and the record of one refusal
// of a Replace, with the fields that Replace_Refusal names. problem is read
// for List_Not_Valid only, and capacity for Table_Full only.
replace_refusal_record :: proc "contextless" (refusal: Replace_Refusal, by: u64, entry_count: u64, problem: replacement_list.List_Problem, capacity: i64) -> (outcome: call_outcome.Call_Outcome, values: [7]u64) {
	kind := u32(Root_Command.Replace)
	outcome = REPLACE_REFUSAL_OUTCOMES[refusal]
	by_value := i64(min(by, 1 << 62))
	switch refusal {
	case .No_Grant:
		values = sender_refusal(.Replace)
	case .Entry_Past_The_Image:
		values = errors.ring_fail(kind, .Bad_Value, .None, 2, by_value, i64(min(entry_count, 1 << 62)))
	case .Replaces_Itself:
		values = errors.ring_fail(kind, .Bad_Value, .Modules, 2, by_value)
	case .No_Module:
		values = errors.ring_fail(kind, .Absent, .Modules, 1)
	case .No_Signed_Row:
		values = errors.ring_fail(kind, .Absent, .Records, 2, by_value)
	case .Chain:
		values = errors.ring_fail(kind, .State, .Records, 2, by_value)
	case .Row_Not_Authentic:
		values = errors.ring_fail(kind, .Damaged, .Records, 2, by_value)
	case .List_Not_Valid:
		values = errors.ring_fail(kind, .Damaged, .Records, 2, by_value, 0, i64(problem))
	case .Table_Full:
		values = errors.ring_fail(kind, .Full, .Records, 0, 0, capacity)
	}
	return outcome, values
}

// replace_refusal_of_record reads the reason of a refused Replace from its
// outcome and its record, by the fields that Replace_Refusal names, and the
// problem of a list that breaks its format. A pair that no reason writes
// gives ok false: the reader says the record as it is.
replace_refusal_of_record :: proc "contextless" (outcome: call_outcome.Call_Outcome, record: errors.Error_Record) -> (refusal: Replace_Refusal, problem: replacement_list.List_Problem, ok: bool) {
	if record.operation != i64(Root_Command.Replace) && outcome != .Grant_Or_Right_Missing {
		return {}, {}, false
	}
	kind, kind_ok := errors.kind_of_word(record.kind)
	unit, unit_ok := errors.unit_of_word(record.unit)
	if !kind_ok || !unit_ok {
		return {}, {}, false
	}
	switch {
	case outcome == .Grant_Or_Right_Missing && kind == .No_Grant && unit == .Root_Commands:
		refusal = .No_Grant
	case outcome == .Argument_Refused && kind == .Bad_Value && unit == .None && record.argument == 2:
		refusal = .Entry_Past_The_Image
	case outcome == .Argument_Refused && kind == .Bad_Value && unit == .Modules && record.argument == 2:
		refusal = .Replaces_Itself
	case outcome == .Nothing_Has_That_Name && kind == .Absent && unit == .Modules:
		refusal = .No_Module
	case outcome == .Nothing_Has_That_Name && kind == .Absent && unit == .Records:
		refusal = .No_Signed_Row
	case outcome == .Wrong_State && kind == .State && unit == .Records:
		refusal = .Chain
	case outcome == .Data_Damaged && kind == .Damaged && unit == .Records && record.found == 0:
		refusal = .Row_Not_Authentic
	case outcome == .Data_Damaged && kind == .Damaged && unit == .Records:
		read, read_ok := enum_word.member_of_word(replacement_list.List_Problem, u64(record.found))
		if !read_ok || read == .None {
			return {}, {}, false
		}
		refusal, problem = .List_Not_Valid, read
	case outcome == .Budget_Or_Capacity_Exhausted && kind == .Full && unit == .Records:
		refusal = .Table_Full
	case:
		return {}, {}, false
	}
	return refusal, problem, true
}

// member_of_word is the border of a word of a root command: the member, or
// the refusal that the root service answers. A word that names no member
// gives Argument_Refused and the error record Bad_Value of `argument`, with
// the word (at most 2^62) and the largest member. It reads and changes no
// state, so a refused word changes nothing.
member_of_word :: proc "contextless" ($Enum: typeid, word: u64, command: Root_Command, argument: i64) -> (member: Enum, outcome: call_outcome.Call_Outcome, refusal: [7]u64) where intrinsics.type_is_enum(Enum) {
	read, ok := enum_word.member_of_word(Enum, word)
	if ok {
		return read, .Succeeded, {}
	}
	return {}, .Argument_Refused, word_refusal(command, argument, word, u64(max(Enum)))
}

// refuse writes the error record of a refused root command in values, and
// gives the call outcome of the refusal. The procedure that refuses names
// the outcome and the kind together, at the place where it refuses
// (src/md/api/call_outcome.md, "The borders of the rings"): the root
// service maps no status to an outcome.
refuse :: proc "contextless" (values: ^[7]u64, outcome: call_outcome.Call_Outcome, command: u32, kind: errors.Kind, unit: errors.Unit = .None, argument: i64 = 0, value: i64 = 0, limit: i64 = 0, found: i64 = 0) -> call_outcome.Call_Outcome {
	values^ = errors.ring_fail(command, kind, unit, argument, value, limit, found)
	return outcome
}

// word_refusal is the error record of a word that names no member. It is
// not polymorphic, so a process that never reads such a word still uses
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
// gives Argument_Refused: the root service then changes no table.
machine_key_report_of_values :: proc "contextless" (values: [7]u64) -> (report: Machine_Key_Report, outcome: call_outcome.Call_Outcome) {
	state, state_ok := enum_word.member_of_word(Machine_Key_State, values[4])
	if !state_ok {
		return {}, .Argument_Refused
	}
	report.state = state
	switch state {
	case .Awaited:
		form, form_ok := enum_word.member_of_word(Machine_Key_Form, values[5])
		if !form_ok {
			return {}, .Argument_Refused
		}
		report.form = form
	case .Opened, .New, .Unreadable:
	}
	return report, .Succeeded
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
	.Machine_Usable         = "Machine_Usable",
	.Start_Policy_Choice    = "Start_Policy_Choice",
	.Wire                   = "Wire",
	.Start_Edit             = "Start_Edit",
	.Debug_Start            = "Debug_Start",
	.Plan_Roles             = "Plan_Roles",
	.Screen_Budget          = "Screen_Budget",
	.Wide_Grant_Ask         = "Wide_Grant_Ask",
	.Wide_Grant_Proof       = "Wide_Grant_Proof",
	.Wide_Grant_End         = "Wide_Grant_End",
	.Wide_Grant_Agent_Ask   = "Wide_Grant_Agent_Ask",
	.Wide_Grant_Second_Connection = "Wide_Grant_Second_Connection",
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
	.Machine_Usable         = "name",
	.Start_Policy_Choice    = "nickname",
	.Wire                   = "step",
	.Start_Edit             = "store",
	.Debug_Start            = "name",
	.Plan_Roles             = "override",
	.Screen_Budget          = "step",
	.Wide_Grant_Ask         = "key",
	.Wide_Grant_Proof       = "name",
	.Wide_Grant_End         = "key",
	.Wide_Grant_Agent_Ask   = "key",
	.Wide_Grant_Second_Connection = "key",
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
	.Machine_Usable         = "",
	.Start_Policy_Choice    = "hash",
	.Wire                   = "",
	.Start_Edit             = "name",
	.Debug_Start            = "",
	.Plan_Roles             = "",
	.Screen_Budget          = "",
	.Wide_Grant_Ask         = "scopes",
	.Wide_Grant_Proof       = "principal",
	.Wide_Grant_End         = "",
	.Wide_Grant_Agent_Ask   = "scopes",
	.Wide_Grant_Second_Connection = "",
}

// command_of_record reads the command that an error record names: the
// number comes from another process. A number that names no member gives
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
