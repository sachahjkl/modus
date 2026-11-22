// The root service: the first process, and the centre of the grants.
//
// The kernel gives it every handle that exists at boot: the machine, the
// boot image, the framebuffer, the devices. It starts the other processes,
// and it gives each one only the handles of its start grant set. It is the **only
// process that creates access from nothing**: each other handle of the
// system came from it, directly or through a chain of processes.
//
// **What it is for.** A process never takes access for itself. It receives
// it at its start, or it asks this service on its *root ring*, and this
// service answers by the tables of this file:
//
// - `start_grant_sets` (start_grant_sets.odin): the start grant set of each module of the boot
//   image, by its name, in one row: its start grants and the other terms
//   of its start grant set (the services that a process with the grant `Connect` can
//   reach, the blocks of a private store, the log with Give, the size of a
//   terminal), with the reason of each. The site shows them in the table
//   "The grants of each process", and the build stops when a process of
//   the boot image has no row.
// - `budget_of` (budgets.odin): the budget that the module of a process
//   asks for, accepted up to the largest budget of a process, and the table
//   of the exceptions, each with its reason.
//
// A start reads the start grant set of a process one time (`start_grant_set_of`), and the
// process keeps it in `Started.start_grant_set`: each rule after the start reads it
// there, never by the name. A process whose row has no grant receives the
// log and a window. A disk process is never a row of these tables: this
// service refuses a file of a disk whose name one of them names, or whose
// name a module of the boot image has (disk_processes.odin).
//
// **The commands of the root ring** (`Root_Command` in the package
// root_ring, root_ring.odin). The table `root_ring.ROOT_COMMAND_SENDERS`
// says who sends each one: a process with the grant **Root_Ring** (the
// console) sends most of them; a process with **Connect** sends `Connect`
// to the services of its start grant set, and `Disconnect`; the process with
// **Principals** sends `Principal_Record`, `Principal_Unlock`,
// `Machine_Key` and `Principal_Change_End`, and no other process can; the
// process with **Debugger** sends `Debug`, `Debug_Store` and `Debug_Start`.
//
// - `Start`, `Stop`: a process by name, in the session of the caller. The
//   start policy (the grant **Start_Policy**) sends them too, with
//   `Machine_Usable` (start_policy.odin).
// - `Start_From_Disk`: a disk process, by its name and the hash of its
//   module file, which this service reads from the store `module_files` of the
//   storage service. Its completion comes when the load ends
//   (disk_processes.odin; docs/MODULE_CONTRACT.md, "A module from a disk").
// - `Disk_Grant`, `Nickname_Move`, `Disk_Grant_Persistence`: the disk
//   grant table of the principal of the caller: a grant to the file that a
//   nickname names, the move of a nickname to another file, and how long a
//   row lasts (disk_processes.odin; docs/MODULE_CONTRACT.md, "The grants of
//   a disk process").
// - `Connect`, `Disconnect`, `Connect_History`: a connection to a service.
// - `Palette_Provide`: the entry table and the ring of the palette
//   provider, for the process with the grant **Palette**.
// - `Grants`, `Revoke`: read the grants of a process, end one of them.
//   The kernel ends each handle that came from the grant, also in the
//   processes that received it from that process.
// - `Replace`: change the replacement table of the machine.
// - `Principal_Create`, `Principal_Lock`, `Principals`, `Principal_Change`:
//   the named principals (docs/PRINCIPALS.md, "7. The commands").
// - `Machine_Passphrase`: the machine passphrase, which guards the key of
//   the disk grant table of principal 0 (persisted_grant_table.odin).
// - `Machine_Seal`: a machine key that the TPM service seals to the
//   measure of the system, with a recovery key (tpm.odin).
// - `Start_Policy_Choice`: the start policy from the disk that the next
//   start runs, a row of the disk grant table of principal 0
//   (start_policy_choice.odin).
// - `Debug`: the handle of a process with the right Debug, for the
//   debugger service, on behalf of a caller of that service that acts for
//   the principal whose session runs that process (`debug`).
// - `Debug_Store`: for that debugger service, a connection that reads only
//   to the store `module_files` of a disk process that it debugs, where the
//   debug object of the process is (debug_store.odin); or that connection
//   and the stop report that this service kept of a disk process that
//   stopped on a fault.
// - `Debug_Start`: for that debugger service, a module started for one of
//   its callers held before its first instruction, with the handle of
//   `Debug`; then its release or its stop (debug_start.odin).
//
// A refused command has an error record in its completion: the console
// prints it, for example after `revoke("notes", "store")` on a process
// that does not run. The border and the check of the sender write the
// record of their refusal; after them, the procedure of the command writes
// it (root_ring.odin).
//
// **What a reader sees.** At boot the screen shows the boot display, with
// each step, until the compositor takes the screen. The log has
// "root: ok, N modules in the boot image", the strength of the random seed,
// the machine parts page, then one line "root: started NAME" for each
// process, and, when the start policy says that the machine is usable, one
// measure: "root: the machine is usable, by the start policy H… of the list
// start_list: the budget of this service holds N free pages, M at the
// lowest" (start_policy.odin).
//
// **What it does not do.** It does not run the code of a process, and it
// does not check what a process does with a grant. It checks only the
// identity of the boot image against the system description
// (docs/TRUSTED_BOOT.md), and the budget of each process.
//
// The design: (docs/ARCHITECTURE.md, "U2. Root service").
package root

import "modus:bochs_display"
import "modus:bootscreen"
import "modus:bootscreen/collect"
import "modus:display"
import "modus:graphics"
import info "modus:contract/boot_info"
import "modus:contract/isolated"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:random"
import "modus:screen_presence"
import "modus:system"
import terminal "modus:terminal"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/fixed_addresses"
import "modus:contract/log_scope"
import "modus:contract/root_ring"
import "modus:pci"
import "modus:principals"
import "modus:disk_process"
import "modus:contract/settings"
import "modus:contract/palette_table"
import "modus:contract/start_grant"
import "modus:contract/start_list"
import "modus:contract/value_kinds"

// What a process receives, by name: a start grant. The list and the name of
// each one are a contract, because the reader of an error record names the
// start grant that refused a debug access (src/library/modus/contract/start_grant).
Grant :: start_grant.Grant

// The context of the input service: the slots that src/modules/system/input
// names GRANT_RING, GRANT_PORTS, GRANT_KEYBOARD_INTERRUPT and
// GRANT_MOUSE_INTERRUPT. The input service is no package that this service
// imports, so the numbers are written on both sides.
INPUT_GRANT_RING :: 0 // The input ring, which the compositor reads.
INPUT_GRANT_PORTS :: 1 // The ports of the PS/2 controller.
INPUT_GRANT_KEYBOARD_INTERRUPT :: 2
INPUT_GRANT_MOUSE_INTERRUPT :: 3
// The context of the compositor, as src/modules/system/compositor names it. The
// handle 0: the framebuffer of the firmware, or the memory of two screen
// pages.
COMPOSITOR_GRANT_FRAMEBUFFER :: 0
COMPOSITOR_GRANT_INPUT :: 1 // The input ring of the input service.
COMPOSITOR_GRANT_CONTROL :: 2 // The control ring from this service.
// The handle 3 of the context of the compositor: the memory of the
// registers of the standard VGA, when its handle 0 is the memory of two
// screen pages (devices.odin, display_open). 0: no page flip.
COMPOSITOR_GRANT_DISPLAY_REGISTERS :: 3
COMPOSITOR_GRANT_GPU_RING :: 4 // Optional VirtIO-GPU client ring when gpu_device started.
// The values 0 to 3 of the context of the compositor: the screen.
COMPOSITOR_VALUE_WIDTH :: 0
COMPOSITOR_VALUE_HEIGHT :: 1
COMPOSITOR_VALUE_PIXELS_PER_LINE :: 2
COMPOSITOR_VALUE_FORMAT :: 3
// The values of the context of the compositor that name its own file.
COMPOSITOR_VALUE_FILE_ADDRESS :: 4
COMPOSITOR_VALUE_FILE_SIZE :: 5
// The pointer theme file of the compositor (docs/POINTERS.md): a resource
// of the boot image, mapped read-only (resources.odin).
COMPOSITOR_VALUE_POINTER_THEME_ADDRESS :: 6
COMPOSITOR_VALUE_POINTER_THEME_SIZE :: 7
POINTER_THEME_ADDRESS :: fixed_addresses.POINTER_THEMES_ADDRESS
// The values of the context of the compositor for each pointer theme: the
// second at the values that modus:contract/operation names for it.
COMPOSITOR_POINTER_THEME_VALUES := [2][2]int{{COMPOSITOR_VALUE_POINTER_THEME_ADDRESS, COMPOSITOR_VALUE_POINTER_THEME_SIZE}, {op.CONTEXT_VALUE_SECOND_POINTER_THEME_ADDRESS, op.CONTEXT_VALUE_SECOND_POINTER_THEME_SIZE}}
POINTER_THEME_SPACING :: fixed_addresses.RANGE_SPAN / 2 // The second theme is this far after the first.

// grant_for gives what a caller receives in a service (isolated.Service_Command).
// The storage service: the private store of the caller, with the limit of
// blocks of its start grant set. Each service: the principal of the session of the
// caller, and the flag that the caller acts for that principal (the manual
// gives what runs only to such a caller).
grant_for :: proc "contextless" (caller: ^Started, service: ^Started) -> u64 {
	// The connection of the service disk_processes, for the read of the
	// module file of a disk process and of its imports: the store of the
	// module files, with its limit, the flag that it reads only, and no
	// grant to act for a principal (disk_processes_delegation.odin).
	if caller == &disk_reader {
		return isolated.caller_grant_make(disk_process.STORE_BLOCKS_LIMIT, caller.principal, false) | isolated.CALLER_READS_ONLY
	}
	// The connection of this service for the disk grant table of a
	// principal, an object of the store of the module files of that
	// principal (persisted_grant_table.odin).
	if persisted_table_keeper_is(caller) {
		return isolated.caller_grant_make(disk_process.STORE_BLOCKS_LIMIT, caller.principal, false)
	}
	// The connection of the debugger service to the same store, for the
	// debug object of a disk process: it reads only (debug_store.odin).
	if caller == &debug_store_reader {
		return isolated.caller_grant_make(disk_process.STORE_BLOCKS_LIMIT, caller.principal, false) | isolated.CALLER_READS_ONLY
	}
	// The log service: the own records of the caller, named by its process
	// slot and its process serial; with the grant to act for the principal,
	// the whole log (src/md/features/log_reader_scope.md). A disk process
	// never acts for a principal.
	if system.name_of(service.name[:]) == "log" {
		whole_log := !caller.from_disk && .Acts_For_Principal in caller.start_grant_set.grants && .Acts_For_Principal not_in caller.revoked
		return isolated.caller_grant_make(own_records_amount_of(caller), caller.principal, whole_log)
	}
	// A disk process: the grants of its start, never the grants of a name,
	// and never the grant to act for a principal.
	if caller.from_disk {
		return isolated.caller_grant_make(disk_store_limit(caller, service), caller.principal, false)
	}
	start_grant_set := &caller.start_grant_set
	amount: u64
	if .Store in start_grant_set.grants && .Store not_in caller.revoked && is_role_holder(system.name_of(service.name[:]), .Storage) {
		amount = start_grant_set_store_blocks(start_grant_set)
	}
	acts := .Acts_For_Principal in start_grant_set.grants && .Acts_For_Principal not_in caller.revoked
	grant := isolated.caller_grant_make(amount, caller.principal, acts)
	// The grant to erase versions is a right over the private store: it goes
	// with the store, to the storage service only.
	if amount != 0 && .Versions_Erase in start_grant_set.grants {
		grant |= isolated.CALLER_ERASES_VERSIONS
	}
	return grant
}

// own_records_amount_of gives the amount of the grant of a connection to
// the log service: the process slot and the process serial of the caller,
// which the kernel gives for its process handle. A slot that the kernel does
// not give, or that does not fit, gives 0: the caller then reads no record,
// never the records of another process.
own_records_amount_of :: proc "contextless" (caller: ^Started) -> u64 {
	slot, serial, status := system.process_place(caller.process)
	if status != .Ok {
		return 0
	}
	amount, ok := log_scope.own_records_amount(slot, serial)
	if !ok {
		system.log_fact(.Warning, Log_Scope_Refused{slot = u64(slot), serial = u64(serial), caller = module_name_field(system.name_of(caller.name[:]))})
		return 0
	}
	return amount
}

// log_grant gives the grant of the log: each process that this service
// starts can write on the log. A process whose start grant set says so can also give
// the log to the processes that it starts.
log_grant :: proc "contextless" (start_grant_set: Start_Grant_Set) -> system.Grant {
	rights := system.Rights{.Write}
	if start_grant_set.log_gives {
		rights += {.Give}
	}
	return {system.context_record().handles[op.CONTEXT_LOG], rights}
}

// A process that this service started.
Started :: struct {
	process:         system.Handle, // 0: the slot is free.
	client:          system.Handle, // The ring of the process, as the compositor names it.
	requests:        ring.Ring, // The ring from the process to this service, if it has one.
	requests_memory: system.Handle,
	service:            ring.Ring, // The service ring of the process, if it is a service.
	service_memory:     system.Handle,
	service_ring_ready: bool, // True once Handle_Give succeeded on service_memory (no startup retry after).
	hash:            [32]u8, // The hash of the file of the process.
	name:            system.Name,
	// The start grant set that this service gave the process when it started it: each
	// rule after the start reads it here, in the state of the process that
	// runs, and never in a table by the name of the process (the sender of
	// a command, the debug access, the grant of a connection).
	start_grant_set:            Start_Grant_Set,
	granted:         system.Root_Grants, // What the process has from this service, of the grants that this service can revoke.
	revoked:         system.Root_Grants,
	writer:          ^Started, // A terminal: the process that writes in it. nil after that process stopped.
	is_terminal:     bool,
	driver:            ^Started, // The device service that serves this process. nil: none, or it stopped.
	is_driver:         bool, // A device service: it has the device at `device`.
	bus_master_active: bool, // True while PCI Bus Master is on for this device service.
	device:            pci.Place,
	bridge_group:    Bridge_Group, // A device behind a conventional bridge: the buses behind it, whose devices this service holds too (devices.odin). Zero: none.
	queues:          system.Handle, // A block service: the memory of the queue of its device.
	network:            ring.Ring, // The network service: the control ring from this service.
	network_memory:     system.Handle,
	network_ring_ready: bool, // True once Handle_Give succeeded on network_memory.
	endpoint:        system.Handle, // A process with an endpoint: its datagram ring, as the network service names it.
	network_service: ^Started,
	// The principal whose session the process belongs to (docs/PRINCIPALS.md):
	// 0, the machine, for the processes of the system and each process that a
	// process of the machine starts; the named principal whose session runs
	// for a process that the desktop starts.
	principal:       u64,
	// The process that received the handle of this process with the right
	// Debug (Root_Command.Debug): the debugger service. nil: none, or it
	// stopped, or the grant was revoked.
	debugger:        ^Started,
	// A disk process: its name is a nickname, which no table by name of
	// this service reads. Its grants are `start_grant_set`, from the disk grant table
	// of its principal at its start, and its store is the store of the
	// nickname (disk_processes.odin).
	from_disk:       bool,
	// The caller of the debugger service for which this service gave that
	// handle: the grant `debug` is a grant of this caller. nil with no
	// debugger.
	debug_for:       ^Started,
	// The row of the client table of the connection of debug_for that
	// asked (Client_Grant.place): the clients of two principals are the
	// one caller `remote`, and the debugging of one must not be ended or
	// taken through the connection of the other. 0: a caller with no row.
	debug_for_row:   int,
	// A start holds this place while it builds the process, before the
	// process runs: a start that the start runs (a service on demand) takes
	// another place. release clears it with the place.
	reserved:        bool,
	// The start policy asked for this process: a failed start policy has
	// it stopped before the rescue starts, and a start policy stops only
	// such a process (start_policy.odin).
	asked_by_start_policy: bool,
	// This service asked the stop of the process, for the rescue: its stop
	// is no fault of the process, and the stop of the compositor so is no
	// absence of the screen, whatever the order of the reap.
	stop_asked_by_root_service: bool,
	// The process that asked for the start of this one with Start: the
	// rule of an end Started of a wiring (wirings.odin). nil: this service
	// started it by itself, or the asker stopped.
	asker:           ^Started,
	// Canonical kernel identity cached at start for Process_Stop_Notice
	// and delegated services (src/md/api/root_service_split.md).
	process_slot:    u64,
	process_serial:  u64,
	// Slice of the module file of the process in the boot image, for the
	// delegated wiring service's read-only boot image view.
	module_offset:   u64,
	module_size:     u64,
	// A handle of the budget of the process with Read and Spend, for a
	// process that can send Wire, so the core can carve its Spend-only
	// child wiring budget (`wiring_budget`). Closed at stop.
	budget:          system.Handle,
	wiring_budget:   system.Handle,
	// The wiring ring of a process that declares record streams or asked
	// for a list page: handed to the delegated `wiring` service, never
	// mapped in the root core.
	wiring_memory:   system.Handle,
	// Read-only handle to an asker's list page so the core can prove and
	// close lent handles on the asker's root ring.
	list_memory:     system.Handle,
	// Whether the delegated wiring service currently holds this process.
	wiring_registered: bool,
	// The entry address of a process that Debug_Start holds before its
	// first instruction (debug_start.odin). 0: the process runs.
	held_entry:      u64,
	// The process is the start of a replay (Start_Replay). Held, it stops
	// at the end of its debugging in place of a run: with no Replay_Start
	// its context is not the one of a history. Released, it keeps the mark
	// while it runs.
	held_for_replay: bool,
}

// place_is_free says if a place of the table of the processes holds no
// process and no start that builds one.
place_is_free :: proc "contextless" (item: ^Started) -> bool {
	return item.process == 0 && !item.reserved
}

// A connection: one caller can call the exports of one service.
Connection :: struct {
	caller:  ^Started, // nil: the place is free.
	service: ^Started,
	ring:    system.Handle, // The call ring, as the service names it.
	region:  system.Handle, // The call region, as the service names it.
	// The process handle of the service as the caller names it: the number
	// that the completion of Connect gave. A Connected end of a wiring
	// names the connection by it, since that handle has no Give.
	caller_service_handle: system.Handle,
	// The connection to the store of the line history of the caller
	// (Root_Command.Connect_History): its grant is the limit of that store,
	// never the private store and never the grant to act for the principal.
	history: bool,
	// A connection of `remote` for one row of the client table: it acts
	// for the principal of the row, and ends when the grant of the row
	// ends (remote_clients.odin). place 0: none.
	client:          Client_Grant,
	role_generation: u64, // Supervision generation of service role at Connect time.
}

// The blocks of the store of a line history. One object of one block
// takes 3 blocks of a store (the table of the store, the list of the
// object, its data), and a change of it needs one block more for the new
// data, in the commit that thins the version before: 4 is the least limit
// with which the history can change.
HISTORY_STORE_LIMIT :: 4

// connection_grant gives what the caller of a connection receives in its
// service now: for the history store, its limit only.
connection_grant :: proc "contextless" (connection: ^Connection) -> u64 {
	if connection.history {
		return isolated.caller_grant_make(.History in connection.caller.revoked ? 0 : HISTORY_STORE_LIMIT, connection.caller.principal, false)
	}
	if connection.client.place != 0 {
		return client_connection_grant(connection.caller, connection.client)
	}
	return grant_for(connection.caller, connection.service)
}

CONNECTION_CAPACITY :: 32

connections: [CONNECTION_CAPACITY]Connection

STARTED_CAPACITY :: 32

machine: system.Handle
image: []u8
image_memory: system.Handle
started: [STARTED_CAPACITY]Started
// The shared code of the modules of the processes that this service starts.
prepared: system.Prepared_Modules
display_holder: system.Handle
control: ring.Ring
control_memory: system.Handle
// The machine has no screen: no framebuffer at the start, or a compositor
// that stopped. With no screen this service starts no input service, no
// compositor and no console, gives no process a window, and refuses a start
// that needs a terminal: the other services start
// (src/md/features/missing_hardware.md).
screen_absent: bool
// The machine had no screen before the first start of a process, and not a
// compositor that stopped later: it chooses the line of the absence.
no_screen_at_the_start: bool

// The replacement table of the machine: this service writes it. Each
// process that this service starts receives its records (a process cannot
// ask for a replacement and cannot refuse one: a replacement is not an
// access that a process takes for itself).
replacement_memory: system.Handle
replacement_table: ^system.Replacement_Table
replacement_records: [system.REPLACEMENT_CAPACITY]module.Replacement

// load_source gives what the loader of a process that this service starts can
// read: the boot image, and the replacements of this time.
load_source :: proc "contextless" () -> system.Load_Source {
	return {image = image, replacements = system.replacements_read(replacement_table, &replacement_records)}
}

// The boot display (package bootscreen), on the screen of the machine.
// This service draws it until the compositor has the screen.
screen: graphics.Canvas
screen_data: bootscreen.Data
message: bootscreen.Text

show :: proc "contextless" (text: string, state: bootscreen.State, step: bootscreen.Step) {
	if screen.pixels == nil {
		return
	}
	screen_data.message = text
	screen_data.state = state
	screen_data.step = step
	collect.data(&screen_data, machine)
	bootscreen.draw_screen(screen, &screen_data)
}

// shortage_start gives the process shortage nearly all the pages of this
// service, and the machine; the process stops the machine at its end. This
// service keeps SHORTAGE_KEEP pages: the module of the process is copied in
// memory that it pays.
SHORTAGE_KEEP :: 24

// The start list of the machine of the shortage asks for it: this service
// then starts nothing else, as its budget is gone.
shortage_start :: proc "contextless" () -> system.Status {
	slot := part_place_take()
	if slot == nil {
		return .No_Slot
	}
	own, _ := system.budget_read()
	context_grants: system.Context_Grants
	values: system.Context_Values
	system.grant_put(&context_grants, system.GRANT_MACHINE, {machine, {.Inspect, .Stop}})
	system.grant_put(&context_grants, op.CONTEXT_LOG, log_grant(start_grant_set_of("shortage")))
	if context_refused("shortage", &context_grants, &values) {
		shortage_failed()
	}
	amounts := system.Budget_Amounts {
		pages       = own.pages - SHORTAGE_KEEP,
		processes    = 1,
		threads     = 8,
		processor   = own.processor,
		log_records = LOG_RECORDS_OF_A_PROCESS,
	}
	process, status := system.process_start(system.image_find(image, "shortage"), "shortage", context_grants.grants, random.values_with_seed(&process_generator, values.values), amounts, nil, &prepared)
	if status != .Ok {
		system.log_fact(.Info, Shortage_Start_Failed{status = status})
		shortage_failed()
	}
	part_place_fill(slot, "shortage", process)
	system.log_fact(.Info, Process_Started_With_Budget{started_process = module_name_field("shortage"), pages = value_kinds.Size_In_Pages(amounts.pages)})
	return .Ok
}

// part_place_take takes a free place of the table of the processes for a
// process that this service starts by its own procedure, so that a start
// policy that asked for it gets its handle and can name it. nil: the table
// is full.
part_place_take :: proc "contextless" () -> ^Started {
	for &item in started {
		if place_is_free(&item) {
			item = {}
			return &item
		}
	}
	return nil
}

// part_place_fill records such a process in its place: its start grant set, its name
// and the hash of its file.
part_place_fill :: proc "contextless" (slot: ^Started, name: string, process: system.Handle) {
	slot.process = process
	slot.process_slot, slot.process_serial, _ = system.process_place(process)
	slot.start_grant_set = start_grant_set_of(name)
	slot.granted = {.Log}
	copy(slot.name[:len(slot.name) - 1], name)
	for &item in system.image_entries(image) {
		if system.name_of(item.name[:]) == name {
			slot.hash = item.hash
			slot.module_offset = item.offset
			slot.module_size = item.size
		}
	}
}

// The process that runs the operation sequences (src/md/infrastructure/kernel_fuzzing.md).
OPERATION_FUZZING_NAME :: start_list.OPERATION_FUZZING_NAME
// Its budget: its mailbox, the shared code of its runners, and the budget
// of each sequence, which it creates and ends for each one.
OPERATION_FUZZING_PAGES :: 8192

// operation_fuzzing_start starts operation_fuzzing with the machine with
// the right Physical only: it reads the physical address of its mailbox,
// which the tool reaches through the memory file of the machine. It gives
// no other right of the machine. The start list of the machine of the
// operation sequences asks for it, and for nothing else.
operation_fuzzing_start :: proc "contextless" () -> system.Status {
	slot := part_place_take()
	if slot == nil {
		return .No_Slot
	}
	own, _ := system.budget_read()
	context_grants: system.Context_Grants
	values: system.Context_Values
	start_grant_set := start_grant_set_of(OPERATION_FUZZING_NAME)
	system.grant_put(&context_grants, system.GRANT_MACHINE, {machine, {.Physical}})
	system.grant_put(&context_grants, system.GRANT_IMAGE, {image_memory, {.Read}})
	system.grant_put(&context_grants, op.CONTEXT_LOG, log_grant(start_grant_set))
	system.value_put(&values, system.GRANT_VALUE_IMAGE_SIZE, u64(len(image)))
	if context_refused(OPERATION_FUZZING_NAME, &context_grants, &values) {
		return .Bad_State
	}
	amounts := system.Budget_Amounts {
		pages       = OPERATION_FUZZING_PAGES,
		processes    = 16,
		threads     = 32,
		processor   = own.processor,
		log_records = LOG_RECORDS_OF_A_PROCESS,
	}
	process, status := system.process_start(system.image_find(image, OPERATION_FUZZING_NAME), OPERATION_FUZZING_NAME, context_grants.grants, random.values_with_seed(&process_generator, values.values), amounts, nil, &prepared)
	if status != .Ok {
		system.log_fact(.Error, Operation_Fuzzing_Start_Failed{status = status})
		return status
	}
	part_place_fill(slot, OPERATION_FUZZING_NAME, process)
	system.log_fact(.Info, Process_Started_With_Budget{started_process = module_name_field(OPERATION_FUZZING_NAME), pages = value_kinds.Size_In_Pages(amounts.pages)})
	return .Ok
}

// shortage_failed ends the machine of the test of a shortage whose process
// did not start. The machine has nothing else to run: this service waits
// whatever Machine_Stop gives, so the test ends on the stop code or on its
// hang bound, and never on a start that went on after a refusal.
shortage_failed :: proc "contextless" () -> ! {
	system.call(.Machine_Stop, u64(machine), 1)
	for {
		system.sleep(max(u64))
	}
}

// fail ends the start of the machine, before the start policy: the trust,
// the seed and the pages that every process reads. The machine does not
// stop: the boot display stays, with the failure, until the machine is
// stopped from outside.
fail :: proc "contextless" (text: string, status: system.Status) -> ! {
	system.log_fact(.Error, Root_Failed{status = status, failure = text_field(text, 140)})
	failure_show(text, status)
	for {
		system.sleep(max(u64))
	}
}

// failure_show takes the screen back from the compositor and shows a
// failure on the boot display.
failure_show :: proc "contextless" (text: string, status: system.Status) {
	if display_holder != 0 {
		// This service asks the stop: the screen returns to it, and the
		// stop is no absence of the screen.
		for &item in started {
			if item.process == display_holder {
				item.stop_asked_by_root_service = true
			}
		}
		system.process_stop(display_holder) // The screen returns to this service.
		// The compositor could leave the page 1 on the screen; the boot
		// display is on the page 0, the framebuffer of the firmware.
		if display_registers_address != nil {
			bochs_display.page_show(display_registers_address, 0, display_screen_height)
		}
	}
	message.count = 0
	bootscreen.put(&message, "the start failed: ")
	bootscreen.put(&message, text)
	bootscreen.put(&message, ": status ")
	bootscreen.put_number(&message, u64(status))
	show(string(message.bytes[:message.count]), .Failed, screen_data.step)
	system.log_fact(.Info, Failure_Shown{})
}

// The random generator of the root service: its seed comes from the
// sources of the processor (src/library/modus/random/entropy.odin), not from a
// starter. It gives the seed of each process that root starts.
process_generator: random.Generator
entropy_report: random.Entropy_Report

// The entry of the root service: it brings up the system, then answers the
// root rings of the processes for the life of the machine.
//
// The kernel starts it with the context of the root service: the machine,
// the boot image, the framebuffer and their values. The entry, in order:
//
// 1. maps the boot image and the debug image; writes "root: ok, N modules
//    in the boot image";
// 2. takes the screen for the boot display;
// 3. checks the boot image against the system description (trust.odin);
//    a failure stays on the screen and no process starts;
// 4. reads the principals, and seeds the random generator of the system
//    from the sources of the processor; a seed of 32 zero bytes ends the
//    boot;
// 5. creates the pages that it writes for every process: the settings
//    page, the date page, the disk process page, the fresh bytes pages, the
//    replacement table and the client table;
// 6. starts the entropy service when the machine has an entropy device,
//    with no wait for its bytes, and the TPM service when the system is
//    measured into a TPM;
// 7. writes the machine parts page, and, with a TPM service and a data
//    disk, reads the choice of principal 0: `unlock` with no window
//    unseals the machine key, and the disk grant table of principal 0 is
//    read (start_policy_choice.odin);
// 8. with a data disk and no rescue, starts the holder of Plans, which
//    reads the current plan of principal 0 from its own store and gives
//    its roles, and waits for its Loaded within the hang bound
//    (plan_at_start.odin);
// 9. starts one start policy, measured into PCR 12 first: the start policy
//    from the disk that principal 0 chose, the default start policy with
//    the list start_list, or, when the boot record asks for it, the rescue
//    start policy with the list rescue_list (start_policy.odin). The start
//    policy asks for each other start: the parts of the system (`input`,
//    the compositor) start by their procedures here,
//    each other process with the grants of its start grant set.
//
// With no screen before the first start (modus:screen_presence),
// this service writes the line "root: no screen: no console, no window;
// the other services start" once, and the machine parts page has no
// screen: the processes that start with no screen are a decision of the
// start list (src/md/features/start_policy.md), and this service starts
// none in place of the console, and refuses a compositor. `unlock` starts,
// as a machine key that the TPM releases needs no typing, and when it must
// have a key typed it writes its line and stops, and it is not started
// again. A compositor that stops by itself later gives one line and
// refuses the later windows and terminals; it starts nothing.
//
// A failure in steps 1 to 5, or a refusal of the rights of a part of the
// system, calls `fail`: the boot display shows the cause, and the machine
// waits until it is stopped from outside. A start policy that fails starts
// the rescue start policy; with no start policy at all, the boot display
// shows the cause, and the loop runs.
//
// Then one loop runs for ever. It waits on the control ring of the
// compositor (a start or a stop from the desktop), on the root ring of each
// process, and on the answers of the network service and of the entropy
// service, whose bytes it mixes into its generator; every 30 seconds it
// asks the entropy service for the fresh bytes of the running processes
// (entropy.odin). It checks each command
// against the grants of the caller, runs it, and sends a completion. After
// each pass, `reap` frees what this service held for the processes that
// stopped. The root service never returns.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	machine = ctx.handles[op.ROOT_MACHINE]
	boot_image_take(ctx)
	// The kernel refuses a stop code that the host cannot receive whole,
	// with its error record, and changes nothing: the line after the two
	// calls says that the machine runs on.
	refused_codes := [2]u64{op.MACHINE_STOP_CODE_MOST + 1, max(u64)}
	for code in refused_codes {
		refusal: errors.Error_Record
		_, refused := system.call_with_error(&refusal, .Machine_Stop, u64(machine), code)
		if refused != .Bad_Operation || refusal.kind != i64(errors.Kind.Bad_Value) || refusal.argument != 2 || refusal.value != i64(code) || refusal.limit != op.MACHINE_STOP_CODE_MOST {
			fail("Machine_Stop did not refuse a code past one byte with its error record", refused)
		}
	}
	system.log_fact(.Info, Machine_Stop_Codes_Refused{first_code = refused_codes[0], second_code = refused_codes[1], code_limit = u64(op.MACHINE_STOP_CODE_MOST)})
	// The screen first: a failure of the check below stays on it.
	screen_at_the_start := boot_display_take(ctx)
	// The boot image against the system description, before any process
	// starts (trust.odin).
	trust_check()
	principals_start()
	// The random seed of the system: before the first process starts.
	random_seed_make()
	// The settings page and the font outlines, before the first window.
	text_settings_create()
	date_page_create()
	disk_process_page_create()
	fresh_bytes_create() // fresh_bytes.odin
	replacement_table_create()
	remote_clients_create()
	// The control ring exists with no compositor too: the loop waits on it,
	// and a record for a compositor that is absent stays there.
	screen_rings_create(ctx)
	// With no screen before the first start, the one line, and a machine
	// parts page with no screen: the start list then starts no input
	// service, no compositor and no console.
	if !screen_at_the_start {
		no_screen_at_the_start = true
		screen_absence_note()
	}
	// The devices service classifies the bus before any device service
	// starts (devices_delegation.odin).
	bus_classify()
	// The seed and the keys of the machine need these two before any start
	// policy: they are no row of a start list. The loop mixes the bytes of
	// the entropy device when they come (entropy.odin).
	entropy_service_start()
	tpm_service_start()
	// The principals service holds the mirror of the principals and of
	// their tables before the start policy gives them a change
	// (principals_delegation.odin).
	principals_service_boot()
	machine_parts_page_create()
	start_policy_begin()
	for {
		root_loop_pass()
	}
}

// What the start of the input service and of the compositor needs from
// the context of this service, kept for a start that a start policy asks
// for at any time.
root_screen_values: [4]u64 // The width, the height, the pixels of a line and the format of the framebuffer.
root_framebuffer: system.Handle
// The input ring: the input service writes it and the compositor reads
// it. One ring for the whole run: a compositor that a rescue starts again
// reads the ring of the input service that the rescue starts again.
input_memory: system.Handle

// screen_rings_create keeps the screen of the context, and makes the input
// ring and the control ring of the compositor. A send on the control ring
// before a compositor runs fills a ring that no compositor reads.
screen_rings_create :: proc "contextless" (ctx: ^system.Context) {
	root_screen_values = {ctx.values[op.ROOT_VALUE_WIDTH], ctx.values[op.ROOT_VALUE_HEIGHT], ctx.values[op.ROOT_VALUE_PIXELS_PER_LINE], ctx.values[op.ROOT_VALUE_FORMAT]}
	root_framebuffer = ctx.handles[op.ROOT_FRAMEBUFFER]
	status: system.Status
	input_memory, _, status = system.ring_create()
	if status == .Ok {
		control_memory, control, status = system.ring_create()
	}
	if status != .Ok {
		fail("cannot create a ring", status)
	}
}

// boot_image_take maps the boot image and the debug image, and writes the
// first line of this service.
boot_image_take :: proc "contextless" (ctx: ^system.Context) {
	image_memory = ctx.handles[op.ROOT_BOOT_IMAGE]
	address, status := system.memory_map(image_memory, {})
	if status != .Ok {
		fail("cannot map the boot image", status)
	}
	image = ([^]u8)(address)[:ctx.values[op.ROOT_VALUE_BOOT_IMAGE_SIZE]]
	system.log_fact(.Info, Root_Ready{image_modules = u64(len(system.image_entries(image)))})
	debug_image_take(ctx)
}

// boot_display_take maps the framebuffer for the boot display, and says if
// the machine has a screen, by the test that the compositor makes too
// (modus:screen_presence). With no screen, the boot display shows
// nothing and the start goes on.
boot_display_take :: proc "contextless" (ctx: ^system.Context) -> (present: bool) {
	pixels, map_status := system.memory_map(ctx.handles[op.ROOT_FRAMEBUFFER], {.Write})
	if !screen_presence.screen_present(map_status, ctx.values[op.ROOT_VALUE_WIDTH], ctx.values[op.ROOT_VALUE_HEIGHT]) {
		return false
	}
	screen = {
		pixels = ([^]graphics.Color)(pixels),
		width  = int(ctx.values[op.ROOT_VALUE_WIDTH]),
		height = int(ctx.values[op.ROOT_VALUE_HEIGHT]),
		stride = int(ctx.values[op.ROOT_VALUE_PIXELS_PER_LINE]),
	}
	screen_data.image = image
	screen_data.red_first = ctx.values[op.ROOT_VALUE_FORMAT] == u64(info.Pixel_Format.Red_Green_Blue_X)
	return true
}

// random_seed_make seeds the random generator of the system from the
// sources of the processor, and writes the facts of the seed.
random_seed_make :: proc "contextless" () {
	seed := random.entropy_gather(random.sources_of_the_processor(), &entropy_report)
	if !random.generator_seed(&process_generator, &seed, entropy_report.strength) {
		// BLAKE3 does not give 32 zero bytes in practice; if it does, root
		// says why it cannot start a process, instead of a stop at its
		// first draw.
		fail("the random seed of the system is 32 zero bytes: no process can get a seed", .Bad_Operation)
	}
	report := &entropy_report
	system.log_fact(.Info, Random_Seed_Made{rdseed_good = u64(report.rdseed_good), rdseed_refused = u64(report.rdseed_refused), rdrand_good = u64(report.rdrand_good), rdrand_refused = u64(report.rdrand_refused), jitter_samples = u64(report.jitter_samples), jitter_distinct = u64(report.jitter_distinct), strength = text_field(op.seed_strength_names[report.strength], 32), rdseed_presence = text_field(report.rdseed_present ? "present" : "absent", 8), rdrand_presence = text_field(report.rdrand_present ? "present" : "absent", 8)})
}

// replacement_table_create makes the replacement table of the machine,
// which this service writes and each process reads.
replacement_table_create :: proc "contextless" () {
	table: rawptr
	status: system.Status
	replacement_memory, status = system.memory_create(1)
	if status == .Ok {
		table, status = system.memory_map(replacement_memory)
	}
	if status != .Ok {
		fail("cannot create the replacement table", status)
	}
	replacement_table = (^system.Replacement_Table)(table)
}

// input_start starts the input service with the ports and the interrupts
// of the PS/2 controller, and the input ring, which the compositor reads.
// A start policy asks for it: a failure of the start is its status, with
// one line. The kernel makes a device handle from its arguments and the
// rights of this service only, so a refusal of a device handle is a fault
// of this service, never an absent controller, and it stays `fail`: the
// input service finds that absence itself, at its first read of the status
// port, and stops with its line.
input_start :: proc "contextless" () -> system.Status {
	show("the root service starts input", .Running, .Input)
	slot := part_place_take()
	if slot == nil {
		return .No_Slot
	}
	// The devices: this service closes its handles after the start.
	devices: [3]system.Handle
	defer {
		for handle in devices {
			if handle != 0 {
				system.close(handle)
			}
		}
	}
	device_requests := [3][3]u64{{u64(op.Device_Kind.Ports), 0x60, 5}, {u64(op.Device_Kind.Interrupt), 1, 0}, {u64(op.Device_Kind.Interrupt), 12, 0}}
	for request, index in device_requests {
		results, device_status := system.call(.Device_Create, u64(machine), request[0], request[1], request[2])
		if device_status != .Ok {
			fail("cannot create a device handle", device_status)
		}
		devices[index] = system.Handle(results[0])
	}
	context_grants: system.Context_Grants
	system.grant_put(&context_grants, INPUT_GRANT_RING, {input_memory, {.Read, .Write}})
	system.grant_put(&context_grants, INPUT_GRANT_PORTS, {devices[0], {}})
	system.grant_put(&context_grants, INPUT_GRANT_KEYBOARD_INTERRUPT, {devices[1], {.Read}})
	system.grant_put(&context_grants, INPUT_GRANT_MOUSE_INTERRUPT, {devices[2], {.Read}})
	input_name := role_holder_name(.Input)
	system.grant_put(&context_grants, op.CONTEXT_LOG, log_grant(start_grant_set_of(input_name)))
	// The settings page, read-only: the input service reads the layout of
	// the keyboard there at each key.
	// With no settings page, no mapping and no bit of its range: the input
	// service reads nothing at the range.
	input_values: system.Context_Values
	input_mappings: [2]system.Mapping
	input_mapping_count := 0
	if settings_memory != 0 {
		input_mappings[input_mapping_count] = {memory = settings_memory, address = settings.PAGE_ADDRESS, first = 0, page_count = 1}
		input_mapping_count += 1
		system.range_mapped_put(&input_values, .Settings_Page)
	}
	fresh_bytes_page_give(slot, input_mappings[:], &input_mapping_count, &input_values)
	if context_refused(input_name, &context_grants, &input_values) {
		fresh_bytes_forget(slot)
		return .Bad_State
	}
	process, status := system.process_start(system.image_find(image, input_name), input_name, context_grants.grants, random.values_with_seed(&process_generator, input_values.values), budget_of(system.image_find(image, input_name), input_name), input_mappings[:input_mapping_count], &prepared)
	if status != .Ok {
		fresh_bytes_forget(slot)
		system.log_fact(.Warning, Input_Start_Failed{status = status})
		return status
	}
	part_place_fill(slot, input_name, process)
	started_log(input_name, principals.MACHINE, false)
	return .Ok
}

// screen_absence_note records that the machine has no screen, and writes
// one line, once: at the start with no framebuffer, or when the compositor
// stopped by itself. This service starts no process in place of the
// console: which processes start with no screen is a decision of the start
// list (src/md/features/start_policy.md).
screen_absence_note :: proc "contextless" () {
	if screen_absent {
		return
	}
	screen_absent = true
	if no_screen_at_the_start {
		system.log_fact(.Warning, No_Screen{})
	} else {
		system.log_fact(.Warning, Compositor_Stopped{})
	}
}

// display_holder_start starts the holder of the role Display, the module
// that role_holder_name(.Display) names, with the framebuffer, the input
// ring and a new control ring from this service: the ring of an earlier
// holder can hold records that name handles of that holder only. Nothing
// here depends on the module of today: any module that fills the display
// contract gets the same context. A start policy asks for it by the role
// name "display": a failure is its status, with one line. With no screen it
// is refused: a start list that asks for it on such a machine gets
// Bad_State.
display_holder_start :: proc "contextless" () -> system.Status {
	if screen_absent {
		return .Bad_State
	}
	_ = gpu_driver_start()
	show("the root service starts the compositor", .Running, .Compositor)
	served := part_place_take()
	if served == nil {
		return .No_Slot
	}
	new_control_memory, new_control, status := system.ring_create()
	if status != .Ok {
		system.log_fact(.Warning, Compositor_Control_Ring_Failed{status = status})
		return status
	}
	if control_memory != 0 {
		system.ring_close(&control)
		system.close(control_memory)
	}
	control_memory, control = new_control_memory, new_control
	context_grants: system.Context_Grants
	// The two screen pages of the standard VGA and its registers, in place
	// of the framebuffer of the firmware: the compositor then puts each
	// frame on the screen by a page flip. The address of the framebuffer is
	// in the boot record. With no boot record, the address is 0: no page
	// flip.
	framebuffer_address: u64
	if _, inspect_status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Boot), 0, u64(uintptr(&screen_data.boot)), size_of(screen_data.boot)); inspect_status == .Ok {
		framebuffer_address = screen_data.boot.framebuffer_address
	}
	pages_memory, display_registers := display_open(framebuffer_address, root_screen_values[0], root_screen_values[1], root_screen_values[2])
	defer if pages_memory != 0 {
		system.close(pages_memory) // The compositor holds its own handle.
	}
	if pages_memory != 0 {
		system.grant_put(&context_grants, COMPOSITOR_GRANT_FRAMEBUFFER, {pages_memory, {.Read, .Write}})
		system.grant_put(&context_grants, COMPOSITOR_GRANT_DISPLAY_REGISTERS, {display_registers, {.Read, .Write}})
	} else {
		system.grant_put(&context_grants, COMPOSITOR_GRANT_FRAMEBUFFER, {root_framebuffer, {.Read, .Write}})
	}
	system.grant_put(&context_grants, COMPOSITOR_GRANT_INPUT, {input_memory, {.Read, .Write}})
	system.grant_put(&context_grants, COMPOSITOR_GRANT_CONTROL, {control_memory, {.Read, .Write}})
	if gpu_client_ring_memory != 0 {
		system.grant_put(&context_grants, COMPOSITOR_GRANT_GPU_RING, {gpu_client_ring_memory, {.Read, .Write}})
	}
	display_name := role_holder_name(.Display)
	start_grant_set := start_grant_set_of(display_name)
	system.grant_put(&context_grants, op.CONTEXT_LOG, log_grant(start_grant_set))
	values: system.Context_Values
	system.value_put(&values, COMPOSITOR_VALUE_WIDTH, root_screen_values[0])
	system.value_put(&values, COMPOSITOR_VALUE_HEIGHT, root_screen_values[1])
	system.value_put(&values, COMPOSITOR_VALUE_PIXELS_PER_LINE, root_screen_values[2])
	system.value_put(&values, COMPOSITOR_VALUE_FORMAT, root_screen_values[3])
	// The compositor is also a service (src/modules/system/compositor/exports.odin):
	// a service ring and its own file, as start() gives to a service. Its
	// values 0 to 3 are the screen, so the file is at values 4 and 5.
	// The file, two pointer themes, the settings page, the font outlines,
	// the date page, the fresh bytes page, and one place more.
	mappings: [8]system.Mapping
	mapping_count := 0
	for &item in system.image_entries(image) {
		if system.name_of(item.name[:]) == display_name && item.offset % system.PAGE_SIZE == 0 && item.offset <= u64(len(image)) && item.size <= u64(len(image)) - item.offset {
			served.service_memory, served.service, status = system.ring_create()
			if status != .Ok {
				system.log_fact(.Warning, Compositor_Service_Ring_Failed{status = status})
				served^ = {}
				return status
			}
			system.grant_put(&context_grants, system.GRANT_SERVICE, {served.service_memory, {.Read, .Write}})
			system.value_put(&values, COMPOSITOR_VALUE_FILE_ADDRESS, isolated.FILE_ADDRESS)
			system.value_put(&values, COMPOSITOR_VALUE_FILE_SIZE, item.size)
			mappings[0] = {memory = image_memory, address = isolated.FILE_ADDRESS, first = item.offset / system.PAGE_SIZE, page_count = (item.size + system.PAGE_SIZE - 1) / system.PAGE_SIZE}
			mapping_count = 1
			served.hash = item.hash
		}
	}
	// The pointer themes: resources of the boot image, read-only, each at
	// its place in the list of pointer_theme_choice (the values 6 and 7,
	// then the two values of modus:contract/operation). The setting
	// "pointer_theme" chooses one in the compositor.
	for name, index in pointer_theme_choice() {
		address := POINTER_THEME_ADDRESS + u64(index) * POINTER_THEME_SPACING
		if mapping, size, given := resource_mapping(name, address, display_name); given {
			places := COMPOSITOR_POINTER_THEME_VALUES[index]
			system.value_put(&values, places[0], address)
			system.value_put(&values, places[1], size)
			mappings[mapping_count] = mapping
			mapping_count += 1
		}
	}
	text_settings_give(mappings[:], &mapping_count, &values)
	date_page_give(mappings[:], &mapping_count, &values)
	fresh_bytes_page_give(served, mappings[:], &mapping_count, &values)
	if context_refused(display_name, &context_grants, &values) {
		display_holder_place_free(served)
		return .Bad_State
	}
	// The compositor imports the drawing module: its load needs the boot
	// image as the source of its imports.
	display_holder_load_error: module.Load_Error
	display_holder, status = system.process_start(system.image_find(image, display_name), display_name, context_grants.grants, random.values_with_seed(&process_generator, values.values), budget_of(system.image_find(image, display_name), display_name), mappings[:mapping_count], &prepared, load_source(), &display_holder_load_error)
	if status != .Ok {
		if display_holder_load_error.stage != u32(module.Load_Stage.None) {
			system.log_fact(.Error, Compositor_Load_Refused{})
			load_error_log(.Error, &display_holder_load_error)
		}
		system.log_fact(.Warning, Compositor_Start_Failed{status = status})
		display_holder = 0
		display_holder_place_free(served)
		return status
	}
	served.process = display_holder
	served.process_slot, served.process_serial, _ = system.process_place(display_holder)
	served.start_grant_set = start_grant_set
	copy(served.name[:len(served.name) - 1], display_name)
	for &item in system.image_entries(image) {
		if system.name_of(item.name[:]) == display_name {
			served.module_offset = item.offset
			served.module_size = item.size
		}
	}
	started_log(display_name, principals.MACHINE, false)
	return .Ok
}

// display_holder_place_free frees the place of a display holder that did not
// start, with its service ring.
display_holder_place_free :: proc "contextless" (served: ^Started) {
	if served.service.head != nil {
		system.ring_close(&served.service)
		system.close(served.service_memory)
	}
	served^ = {}
}

// display_holder_end forgets the display holder that stopped: no process gets a
// window until a start policy starts another one, and the boot display,
// on the page 0 of the framebuffer of the firmware, is on the screen again.
display_holder_end :: proc "contextless" () {
	display_holder = 0
	// Each window ring was a handle in the table of that compositor, and
	// died with it: a later Client_Remove for one would name a handle of
	// the next compositor. This clears the window of each disk process too,
	// as it is a place of the same table.
	for &item in started {
		item.client = 0
	}
	if display_registers_address != nil {
		bochs_display.page_show(display_registers_address, 0, display_screen_height)
	}
}

// root_loop_pass is one pass of the loop of this service: the control ring
// of the compositor, the root ring of each process, the answers of the
// services that it waits for, the reap of the processes that stopped, then
// one wait for the next event or deadline.
root_loop_pass :: proc "contextless" () {
	// The stop of a process is an event.
	wait := system.wait_begin()
	control_ring_serve()
	for &item in started {
		if item.process != 0 && item.requests.head != nil {
			root_ring_serve(&item)
		}
	}
	// Before reap: an entropy service that answered and stopped still has
	// its answers in the ring.
	entropy_answers(&wait)
	reap()
	// After reap: the processes of a failed start policy are gone, and the
	// rescue can start (start_policy.odin).
	start_policy_step()
	// After reap: a principal that is locked has a window of unlock.
	unlock_for_a_locked_principal()
	// After reap: a storage service that stopped ended its connections.
	disk_load_step(&wait)
	persisted_tables_step()
	network_answers(&wait)
	wiring_request_step(&wait)
	devices_answers(&wait)
	principals_answers(&wait)
	system.wait_records(&wait, &control.completions)
	for &item in started {
		if item.process != 0 && item.requests.head != nil {
			system.wait_records(&wait, &item.requests.commands)
		}
	}
	// The count of wait_words.odin keeps each list in the wait.
	root_wait_full_tell(&wait)
	// A load from the disk and a call for the disk grant table have a
	// deadline: the wait ends there, with or without an answer of the
	// storage service. The next read of the fresh bytes has one too, a
	// read of the entropy device in flight (entropy.odin), the hang
	// bound of a start policy that runs, and any in-flight request to
	// the delegated wiring service.
	system.wait_end(&wait, min(disk_load_deadline(), persisted_tables_deadline(), fresh_bytes_deadline, entropy_read_deadline_time(), start_policy_wake(), wiring_request_deadline()))
}

// control_ring_serve answers the control ring of the compositor: a start
// or a stop from the desktop.
control_ring_serve :: proc "contextless" () {
	for record in system.receive(&control.completions) {
		control_word, known := enum_word.member_of_word(display.Control, u64(record.kind))
		if !known {
			system.log_fact(.Warning, Compositor_Record_Unknown{record_kind = u64(record.kind)})
			continue
		}
		switch control_word {
		case .None, .Client_Add, .Client_Remove, .Palette_Provider_Add, .Palette_Provider_Remove, .Client_Started:
			// This service sends these to the compositor, and takes none
			// from it.
			system.log_fact(.Warning, Compositor_Record_Not_Taken{record_kind = u64(record.kind)})
		case .Start:
			// The desktop starts a process in the session that runs.
			name := system.name_unpack({record.values[0], record.values[1], record.values[2], record.values[3]})
			start(system.name_of(name[:]), desktop_principal())
		case .Stop:
			for &item in started {
				if item.process != 0 && item.client == system.Handle(record.values[0]) {
					// A close of the window of unlock is a stop that this
					// service asked: it does not count toward the bound of
					// its restarts.
					if !item.is_terminal && system.name_of(item.name[:]) == "unlock" {
						unlock_stop_ask()
					}
					started_process_stop(&item)
				}
			}
		}
	}
}

// The pages that the budget of this service can still pay: at the last
// read, and the lowest count of each read. A read comes after each start
// of a process, when the budget of the process left this budget.
budget_pages_now: u64
budget_pages_lowest: u64 = max(u64)

budget_pages_note :: proc "contextless" () {
	if own, status := system.budget_read(); status == .Ok {
		budget_pages_now = own.pages
		budget_pages_lowest = min(budget_pages_lowest, own.pages)
	}
}

// started_log writes the fact of a start, with a terminal or not, and with
// the session of a named principal: "root: started notes, in the session
// of principal 1 \"alice\"".
started_log :: proc "contextless" (name: string, principal: u64, with_terminal: bool) {
	budget_pages_note()
	started_process := module_name_field(name)
	machine_principal := principal == principals.MACHINE
	switch {
	case machine_principal && !with_terminal:
		system.log_fact(.Info, Process_Started{started_process = started_process})
	case machine_principal && with_terminal:
		system.log_fact(.Info, Process_Started_With_Terminal{started_process = started_process})
	case !with_terminal:
		system.log_fact(.Info, Process_Started_In_Session{started_process = started_process, principal = principal, principal_name = text_field(principal_name(principal), 24)})
	case:
		system.log_fact(.Info, Process_Started_With_Terminal_In_Session{started_process = started_process, principal = principal, principal_name = text_field(principal_name(principal), 24)})
	}
}

// find gives the process with a name that this service started. A terminal
// has the name of no process.
find :: proc "contextless" (name: string) -> ^Started {
	for &item in started {
		if item.process != 0 && !item.is_terminal && system.name_of(item.name[:]) == name {
			return &item
		}
	}
	return nil
}

// grants_held gives the grants of the start of a process that it still
// holds: a grant that was revoked from it is not a grant that it holds.
// The revocation names a grant of system.Root_Grant; the machine is one
// handle, so its revocation ends each right of the machine.
grants_held :: proc "contextless" (item: ^Started) -> bit_set[Grant] {
	held := item.start_grant_set.grants
	if .Machine in item.revoked {
		held -= {.Inspect, .Stop, .Schedule, .Events, .Counters}
	}
	if .Image in item.revoked {
		held -= {.Image}
	}
	if .Log_Records in item.revoked {
		held -= {.Log_Records}
	}
	if .Store in item.revoked {
		held -= {.Store}
	}
	if .Network in item.revoked {
		held -= {.Network}
	}
	if .Acts_For_Principal in item.revoked {
		held -= {.Acts_For_Principal}
	}
	if .History in item.revoked {
		held -= {.History_Store}
	}
	if .Palette in item.revoked {
		held -= {.Palette}
	}
	return held
}

// debug_refusing_grant says if a grant of a process refuses the debug
// access to it for a caller, and which one. A debugger acts with each
// handle of the process that it debugs, and reads each byte of it: the
// right Debug on a process is each grant of that process. So the rule is
// one comparison of two sets of grants, with no name of a process in it:
//
// - each grant that this service gave the process at its start
//   (Started.start_grant_set) is a grant that the caller holds itself and that was not
//   revoked from it (grants_held): the caller then gains nothing that this
//   service did not give it;
// - a grant refuses the debug access for each caller when what it reaches
//   belongs to that one process (GRANTS_OF_ONE_PROCESS): the same grant of
//   the caller reaches another thing, so two holders of the grant do not
//   hold the same thing.
//
// What follows, with no list: a process with no grant can be debugged, and
// a process whose grants reach only what the caller reaches by the same
// grants (the machine, the boot image); a service, a device service, the
// compositor, a terminal, and a process with a private store, an endpoint
// of the network, a terminal or a device cannot.
// The rule reads the state of the process that runs, so it holds for a
// process that came from a disk as for one of the boot image.
//
// A window is not a grant: each process with no terminal has one. The
// debugger of a process draws in its window and reads the input that the
// compositor sends to it.
debug_refusing_grant :: proc "contextless" (caller: ^Started, target: ^Started) -> (grant: Grant, refuses: bool) {
	held := grants_held(caller)
	for candidate in Grant {
		if candidate in target.start_grant_set.grants && (candidate in GRANTS_OF_ONE_PROCESS || candidate not_in held) {
			return candidate, true
		}
	}
	return .Root_Ring, false
}

// The grants that refuse the debug access for each caller: what the grant
// reaches belongs to the one process that holds it, so two holders of the
// grant do not hold the same thing.
// - Serve: a service holds what its callers lent it and what it keeps for
//   them;
// - Terminal: a terminal of its own, with the keys typed in it;
// - Store, History_Store: a store of its own. A caller that acts for the
//   principal reads each store of that principal, and writes only its own:
//   through the registers of the process, a debugger would write the store
//   of the process;
// - Data_Disk, Scratch_Disk, Network_Device, Sound_Device: a device service
//   that this service started for the process alone, and its ring;
// - Network: an endpoint names its own remote and its own ports;
// - Connect: the services that a process can connect to are its own list;
// - Principals: a ring of its own, and the records of the principals;
// - Tpm: the ring and the region of the TPM service, which hold the
//   machine key during a request;
// - Debugger: a ring of its own, and the debuggings of its callers;
// - System_Part: handles that no other grant names;
// - Versions_Erase: the versions of the objects of its own store;
// - Remote_Clients: a connection for a row of the client table acts for the
//   principal of that row, which is not the principal of the caller;
// - Start_Policy: a root ring that starts and stops the processes of the
//   machine, which no caller holds;
// - Screen_Capture: the copy of the screen and the input of the desktop,
//   which show and drive each window of the principal in front;
// - Plans: the roles page, which names the holders of the roles of the
//   machine.
// Each other grant reaches one thing that each of its holders reaches: the
// machine by its rights, the boot image, the debug image, the replacement
// table, the settings page, the date page, the records of the log, the
// commands of the root ring.
GRANTS_OF_ONE_PROCESS :: bit_set[Grant]{.Serve, .Terminal, .Store, .History_Store, .Data_Disk, .Scratch_Disk, .Network_Device, .Sound_Device, .Network, .Connect, .Principals, .Tpm, .Debugger, .System_Part, .Versions_Erase, .Remote_Clients, .Start_Policy, .Screen_Capture, .Plans}

// debug gives the debugger service the handle of the process with a name,
// with the right Debug and no other, on behalf of one of its callers:
// debug access is a handle to one process, and the principal grants it.
// `holder` is the debugger service, which sent the command;
// `connection_ring` is the call ring of one of its connections, as the
// service names it: this service made that connection, so it knows the
// caller, and the service cannot name a process that is not one of its
// callers. values is the completion of Root_Command.Debug: the handle,
// then the hash of the file of the process, then its principal. A refusal
// writes its error record there.
//
// The rule is applied to the caller, not to the service:
//
// - the caller acts for the principal whose session runs the process: the
//   grant Acts_For_Principal, not revoked, and the same principal. So a
//   process of the machine does not debug a process of a named principal,
//   and a process of one principal does not debug a process of another;
// - no grant of the process refuses (debug_refusing_grant).
//
// This service records the grant of the caller (`debug` in Grants) and can
// revoke it: the kernel then ends the handle, and the debugging with it.
// The handle also ends when the connection of the caller to the service
// ends, and when the caller stops.
//
// With `end`, the service says that it ended the debugging of the process
// for that caller: this service forgets the debug access (debug_end).
//
// Bad_Handle: the ring names no connection of the service, or no process
// has the name. Bad_State: a grant of the process refuses, the process is
// the caller or the service, or another caller debugs it. Bad_Operation:
// the caller does not act for the principal of the process. No_Right: the
// grant `debug` was revoked from the caller.
debug :: proc "contextless" (holder: ^Started, name: string, connection_ring: u64, end: bool, values: ^[7]u64) -> system.Status {
	kind := u32(root_ring.Root_Command.Debug)
	caller, caller_principal, caller_row := debug_caller_of(holder, connection_ring)
	if caller == nil {
		values^ = errors.ring_fail(kind, .Absent, .Connections, 2)
		return .Bad_Handle
	}
	// The service ended the debugging of the process for this caller: this
	// service forgets the debug access, and another caller can ask for it.
	// Each process with the name that the service debugs for this caller
	// ends, not the first with the name: a replay (Debug_Start) has the
	// name of the process that was recorded.
	if end {
		ended: u64
		found := false
		for &item in started {
			if item.process != 0 && !item.is_terminal && system.name_of(item.name[:]) == name && item.debugger == holder && item.debug_for == caller && item.debug_for_row == caller_row {
				ended += debug_end(&item)
				found = true
			}
		}
		if !found {
			values^ = errors.ring_fail(kind, .Absent, .Debugged_Processes, 1)
			return .Bad_State
		}
		values[0] = ended
		system.log_fact(.Info, Debugging_Ended{debugger = module_name_field(system.name_of(holder.name[:])), target = module_name_field(name), caller = module_name_field(system.name_of(caller.name[:]))})
		return .Ok
	}
	target := find(name)
	if target == nil {
		values^ = errors.ring_fail(kind, .Absent, .Processes, 1)
		return .Bad_Handle
	}
	if target == caller || target == holder {
		values^ = errors.ring_fail(kind, .No_Grant, .Debug_Access, 1)
		return .Bad_State
	}
	if .Debug in caller.revoked {
		values^ = errors.ring_fail(kind, .No_Grant, .Debug_Access, 1)
		return .No_Right
	}
	if .Acts_For_Principal not_in grants_held(caller) || target.principal != caller_principal {
		values^ = errors.ring_fail(kind, .No_Grant, .Acts_For_Principal, 1)
		return .Bad_Operation
	}
	if grant, refuses := debug_refusing_grant(caller, target); refuses {
		values^ = errors.ring_fail(kind, .No_Grant, .Debug_Access, 1, 0, 0, 1 + i64(grant))
		system.log_fact(.Info, Debug_Access_Refused{caller = module_name_field(system.name_of(caller.name[:])), target = module_name_field(name), grant = text_field(start_grant.GRANT_NAMES[grant], 24)})
		return .Bad_State
	}
	// One debugger for one process: the kernel has the same rule.
	if target.debugger != nil && (target.debugger != holder || target.debug_for != caller || target.debug_for_row != caller_row) {
		values^ = errors.ring_fail(kind, .Full, .Debugged_Processes, 1, 0, 1)
		return .Bad_State
	}
	return debug_give(holder, caller, caller_principal, caller_row, target, name, kind, values)
}

// debug_caller_of gives the caller of the debugger service whose connection
// has this call ring, the principal that it acts for through that
// connection, and the row of the client table of that connection. A
// connection of `remote` for a row of the client table acts for the
// principal of the row, not for the session of `remote`. nil: the ring
// names no connection of the service.
debug_caller_of :: proc "contextless" (holder: ^Started, connection_ring: u64) -> (caller: ^Started, caller_principal: u64, caller_row: int) {
	for &connection in connections {
		if connection.caller != nil && connection.service == holder && !connection.history && u64(connection.ring) == connection_ring {
			caller = connection.caller
			caller_principal = connection_principal(&connection)
			caller_row = connection.client.place
		}
	}
	return caller, caller_principal, caller_row
}

// debug_give gives the debugger service the handle of a process with the
// right Debug and no other, for a caller, and records the debug access.
// values is the completion: the handle, the hash of the file of the
// process, its principal. kind names the command of a refusal.
debug_give :: proc "contextless" (holder: ^Started, caller: ^Started, caller_principal: u64, caller_row: int, target: ^Started, name: string, kind: u32, values: ^[7]u64) -> system.Status {
	given, status := system.give(holder.requests_memory, target.process, {.Debug})
	if status != .Ok {
		values^ = errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(status))
		return status
	}
	target.debugger = holder
	target.debug_for = caller
	target.debug_for_row = caller_row
	caller.granted += {.Debug}
	hash := transmute([4]u64)target.hash
	values^ = {u64(given), hash[0], hash[1], hash[2], hash[3], target.principal, 0}
	system.log_fact(.Info, Debug_Right_Given{debugger = module_name_field(system.name_of(holder.name[:])), target = module_name_field(name), caller = module_name_field(system.name_of(caller.name[:])), principal = caller_principal})
	return .Ok
}

// debug_end ends the debug access to one process: the handle that the
// debugger service received ends there, and the kernel ends the debugging
// of the process with its last handle. The caller keeps the grant `debug`
// only while the service debugs another process for it. It gives the count
// of the holdings that ended.
debug_end :: proc "contextless" (target: ^Started) -> (count: u64) {
	// A process held before its first instruction runs at the end of its
	// debugging, as each thread that a debugger held does. A held replay
	// stops: it has no context of its own to run with.
	if target.held_entry != 0 {
		if target.held_for_replay {
			target.held_entry = 0
			started_process_stop(target)
		} else {
			_ = held_process_release(target)
		}
	}
	holder, caller := target.debugger, target.debug_for
	target.debugger, target.debug_for, target.debug_for_row = nil, nil, 0
	// The connection to the store of the debug object is a part of the
	// debug access, and ends with it.
	debug_store_end(target)
	if holder != nil && holder.process != 0 && target.process != 0 {
		count, _ = system.handle_revoke(target.process, holder.process)
	}
	if caller == nil {
		return count
	}
	for &other in started {
		if other.process != 0 && other.debug_for == caller {
			return count
		}
	}
	caller.granted -= {.Debug}
	return count
}

// revoke ends one grant of a process that runs: access is never given for
// ever, and each grant can be revoked. Each grant
// here is a handle that this service keeps: the handle of the process came
// from it, and the kernel ends what came from it in that process
// (Handle_Revoke). What the process gave to other processes ends too.
// values is the completion of Root_Command.Revoke.
revoke :: proc "contextless" (caller: ^Started, tag: u32, name: string, grant: u64, values: ^[7]u64) -> (status: system.Status, held: bool) {
	status, held = revoke_grant(caller, tag, name, grant, values)
	if status == .Ok && !held {
		if item := find(name); item != nil {
			debug_check_again(item)
		}
	}
	return status, held
}

// debug_check_again ends each debugging that runs for a caller and that
// the rule no longer gives it, after a grant of the caller was revoked: a
// grant that the caller lost must not stay in its hands through the
// registers of a process that holds it. The process is given back as on a
// detach: the kernel resumes each thread that the debugger held. The end
// needs nothing of the caller, so a caller that lost the grant to act for
// the principal leaves no thread stopped.
debug_check_again :: proc "contextless" (caller: ^Started) {
	for &other in started {
		if other.process == 0 || other.debug_for != caller {
			continue
		}
		_, refuses := debug_refusing_grant(caller, &other)
		if refuses || .Acts_For_Principal not_in grants_held(caller) {
			debug_end(&other)
			system.log_fact(.Info, Debugging_Ended_After_Revocation{target = module_name_field(system.name_of(other.name[:])), caller = module_name_field(system.name_of(caller.name[:]))})
		}
	}
}

// revoke_grant is revoke, before the check of the debuggings of the
// process.
revoke_grant :: proc "contextless" (caller: ^Started, tag: u32, name: string, grant: u64, values: ^[7]u64) -> (status: system.Status, held: bool) {
	item := find(name)
	if item == nil {
		return .Bad_Handle, false
	}
	which, known := enum_word.member_of_word(system.Root_Grant, grant)
	if !known {
		return .Bad_Operation, false
	}
	if which not_in item.granted {
		return .Bad_State, false
	}
	handle: system.Handle
	switch which {
	case .Store:
		// The store is data of the storage service: the root service tells it
		// on its service ring that the grant of each connection changed.
		count: u64
		for &connection in connections {
			if connection.caller != item || connection.history || !is_role_holder(system.name_of(connection.service.name[:]), .Storage) {
				continue
			}
			// The amount ends, and the grant to erase versions with it, as it
			// is a right over the store; the principal and the flag to act for
			// it stay.
			kept := grant_for(item, connection.service) &~ (isolated.CALLER_AMOUNT_MASK | isolated.CALLER_ERASES_VERSIONS)
			if !system.send(&connection.service.service.commands, ring.Record{kind = u32(isolated.Service_Command.Grant), values = {0 = u64(connection.ring), 6 = kept}}) {
				return .No_Slot, false
			}
			count += 1
		}
		item.granted -= {which}
		item.revoked += {which}
		values[0] = count
		system.log_fact(.Info, Grant_Revoked_Connections{holder = module_name_field(name), grant = text_field(system.root_grant_names[which], 24), connections = count})
		return .Ok, false
	case .Acts_For_Principal:
		// The grant is data of each service that the process is connected
		// to: the root service tells each one that the grant of the
		// connection changed. A new connection has no grant to act for the
		// principal either (grant_for).
		// A connection whose new grant does not reach its service would keep
		// the grant to act for the principal, and with it the whole log,
		// while the record of this service says that the grant is revoked.
		// So each service ring must hold each Grant record before anything
		// changes; else the revocation is refused and nothing changes. This
		// service is the one writer of a service ring, so the room cannot
		// shrink between the check and the sends.
		if service := grant_room_short(item); service != nil {
			system.log_fact(.Warning, Acts_For_Principal_Revocation_Refused{holder = module_name_field(name), service = module_name_field(system.name_of(service.name[:]))})
			return .No_Slot, false
		}
		item.granted -= {which}
		item.revoked += {which}
		count: u64
		for &connection in connections {
			if connection.caller != item {
				continue
			}
			if system.send(&connection.service.service.commands, ring.Record{kind = u32(isolated.Service_Command.Grant), values = {0 = u64(connection.ring), 6 = connection_grant(&connection)}}) {
				count += 1
			}
		}
		values[0] = count
		system.log_fact(.Info, Grant_Revoked_Connections{holder = module_name_field(name), grant = text_field(system.root_grant_names[which], 24), connections = count})
		return .Ok, false
	case .History:
		// The store of the history is data of the storage service, as the
		// private store: the storage service ends the grant of the
		// connection, and the process keeps its history in its memory only.
		item.granted -= {which}
		item.revoked += {which}
		count: u64
		for &connection in connections {
			if connection.caller != item || !connection.history {
				continue
			}
			if !system.send(&connection.service.service.commands, ring.Record{kind = u32(isolated.Service_Command.Grant), values = {0 = u64(connection.ring), 6 = isolated.caller_grant_make(0, item.principal, false)}}) {
				return .No_Slot, false
			}
			count += 1
		}
		values[0] = count
		system.log_fact(.Info, Grant_Revoked_Connections{holder = module_name_field(name), grant = text_field(system.root_grant_names[which], 24), connections = count})
		return .Ok, false
	case .Network:
		// The endpoint is data of the network service, as a store is data of
		// the storage service: the network service ends the grant.
		count := endpoint_revoke(item)
		item.granted -= {which}
		item.revoked += {which}
		values[0] = count
		system.log_fact(.Info, Grant_Revoked_Endpoints{holder = module_name_field(name), endpoints = count})
		return .Ok, false
	case .Debug:
		// One handle for each process that the command Debug named for
		// this caller: each one ends in the debugger service, and the
		// kernel ends the debugging of that process with its last handle.
		count: u64
		for &other in started {
			if other.process == 0 || other.debug_for != item {
				continue
			}
			count += debug_end(&other)
		}
		item.granted -= {which}
		item.revoked += {which}
		values[0] = count
		system.log_fact(.Info, Grant_Revoked_Holdings{holder = module_name_field(name), grant = text_field(system.root_grant_names[which], 24), holdings = count})
		return .Ok, false
	case .Palette:
		// The table and the ring end in the process, and the compositor
		// unmaps its side: the palette keeps the modules and the windows.
		count := palette_provider_end(item, true)
		item.granted -= {which}
		item.revoked += {which}
		values[0] = count
		system.log_fact(.Info, Grant_Revoked_Holdings{holder = module_name_field(name), grant = text_field(system.root_grant_names[which], 24), holdings = count})
		return .Ok, false
	case .Wirings:
		// Each wiring that the process asked for ends with the end word
		// Revoked in the delegated wiring service; the process can ask for
		// new ones, as a revocation ends what was given and not the right
		// to ask.
		return wirings_revoke_begin(caller, item, tag, values)
	case .Log:
		handle = system.context_record().handles[op.CONTEXT_LOG]
	case .Machine:
		handle = machine
	case .Image:
		handle = image_memory
	case .Log_Records:
		handle = system.context_record().handles[op.ROOT_LOG_RECORDS]
	}
	count, revoke_status := system.handle_revoke(handle, item.process)
	if revoke_status != .Ok {
		return revoke_status, false
	}
	item.granted -= {which}
	item.revoked += {which}
	values[0] = count
	system.log_fact(.Info, Grant_Revoked_Holdings{holder = module_name_field(name), grant = text_field(system.root_grant_names[which], 24), holdings = count})
	return .Ok, false
}

// Tight startup grace bound (milliseconds) for a freshly started service to
// complete its first ring_open(..., receive_handles = true). Once ready^ is
// true, no retry runs so a live service that unmaps its ring cannot stall root.
SERVICE_RING_STARTUP_GRACE_MS :: 200

// give_through_service_ring gives a handle to a service through a ring that
// the service opens with Receive_Handles at its start. Retries Bad_Handle
// only while !ready^ (freshly started) within SERVICE_RING_STARTUP_GRACE_MS,
// failing immediately if the service stops or refuses consent (No_Right).
give_through_service_ring :: proc "contextless" (target_process, ring_memory, handle: system.Handle, rights: system.Rights, ready: ^bool) -> (given: system.Handle, status: system.Status) {
	given, status = system.give(ring_memory, handle, rights)
	if status == .Ok {
		ready^ = true
		return given, .Ok
	}
	if status != .Bad_Handle || ready^ {
		return 0, status
	}
	deadline := system.time() + SERVICE_RING_STARTUP_GRACE_MS
	for system.time() < deadline {
		if target_process != 0 {
			if state, _, _ := system.process_state(target_process); state == .Stopped || state == .None {
				return 0, .Bad_State
			}
		}
		system.sleep(system.time() + 1)
		given, status = system.give(ring_memory, handle, rights)
		if status == .Ok {
			ready^ = true
			return given, .Ok
		}
		if status != .Bad_Handle {
			return 0, status
		}
	}
	return 0, status
}

// The palette provider (docs/CONSOLE.md, "8. The palette provider"): the one
// process that gives the palette of the desktop entries of its own. This
// service keeps a handle of the entry table and of the ring, so that a
// revocation ends what the provider holds of them.
palette_provider: ^Started // nil: no provider.
palette_table_memory, palette_ring_memory: system.Handle
palette_table_in_display_holder, palette_ring_in_display_holder: system.Handle

// palette_provide makes a process with the grant Palette the palette
// provider: a new entry table and a new ring, which the process and the
// compositor receive. The process gets the table with Write; the
// compositor gets it with Read only, and learns of both on its control
// ring. values is the completion of Root_Command.Palette_Provide.
palette_provide :: proc "contextless" (caller: ^Started, values: ^[7]u64) -> system.Status {
	if .Palette not_in caller.start_grant_set.grants || .Palette in caller.revoked {
		return .No_Right
	}
	if palette_provider != nil {
		return .Bad_State
	}
	status: system.Status
	initial_pages, pages_ok := palette_table.table_pages_for(palette_table.INITIAL_ENTRY_CAPACITY)
	if !pages_ok {
		return .Bad_Operation
	}
	palette_table_memory, status = system.memory_create(initial_pages)
	if status != .Ok {
		return status
	}
	palette_ring_memory, status = system.memory_create(ring.PAGE_COUNT)
	given_table, given_ring: system.Handle
	if status == .Ok {
		palette_table_in_display_holder, status = system.give(display_holder, palette_table_memory, {.Read})
	}
	if status == .Ok {
		palette_ring_in_display_holder, status = system.give(display_holder, palette_ring_memory, {.Read, .Write})
	}
	if status == .Ok {
		given_table, status = system.give(caller.requests_memory, palette_table_memory, {.Read, .Write})
	}
	if status == .Ok {
		given_ring, status = system.give(caller.requests_memory, palette_ring_memory, {.Read, .Write})
	}
	if status != .Ok {
		system.close(palette_table_memory)
		if palette_ring_memory != 0 {
			system.close(palette_ring_memory)
		}
		palette_table_memory, palette_ring_memory = 0, 0
		return status
	}
	palette_provider = caller
	caller.granted += {.Palette}
	values^ = {0 = u64(given_table), 1 = u64(given_ring)}
	system.send(&control.commands, ring.Record{kind = u32(display.Control.Palette_Provider_Add), values = {0 = u64(palette_ring_in_display_holder), 1 = u64(palette_table_in_display_holder)}})
	system.log_fact(.Info, Palette_Provider_Set{provider = module_name_field(system.name_of(caller.name[:]))})
	return .Ok
}

// palette_provider_end ends the palette provider: the compositor unmaps
// the table and the ring. With revoke, each handle and each mapping of
// the two objects ends in the process, which runs on; without, the process
// stopped. It gives the count of the holdings that ended.
palette_provider_end :: proc "contextless" (item: ^Started, revoke: bool) -> (count: u64) {
	if palette_provider != item {
		return 0
	}
	if revoke {
		for handle in ([2]system.Handle{palette_table_memory, palette_ring_memory}) {
			ended, _ := system.handle_revoke(handle, item.process)
			count += ended
		}
	}
	system.send(&control.commands, ring.Record{kind = u32(display.Control.Palette_Provider_Remove), values = {0 = u64(palette_ring_in_display_holder), 1 = u64(palette_table_in_display_holder)}})
	system.close(palette_table_memory)
	system.close(palette_ring_memory)
	palette_provider = nil
	palette_table_memory, palette_ring_memory = 0, 0
	system.log_fact(.Info, Palette_Provider_Absent{})
	return count
}

// terminal_start starts the terminal of a process that runs. The terminal
// receives a surface, the terminal ring, the text region with the right
// Read, and a handle that reads the state of the process. It receives
// nothing of the start grant set of the process.
terminal_start :: proc "contextless" (view: ^Started, writer: ^Started, ring_memory, text_memory: system.Handle) -> system.Status {
	view^ = {}
	display_memory := system.memory_create(ring.PAGE_COUNT) or_return
	defer system.close(display_memory)
	client := system.give(display_holder, display_memory, {.Read, .Write}) or_return
	system.send(&control.commands, ring.Record{kind = u32(display.Control.Client_Add), values = {0 = u64(client)}})

	// The slots of a terminal are its own: the terminal has no other role.
	terminal_name := role_holder_name(.Terminal)
	start_grant_set := start_grant_set_of(terminal_name)
	context_grants: system.Context_Grants
	values: system.Context_Values
	columns, rows, measure := start_grant_set_terminal(&writer.start_grant_set)
	handles := terminal.Terminal_Handles{display = display_memory, ring = ring_memory, text = text_memory, writer = writer.process, log = log_grant(start_grant_set)}
	terminal.context_of(&context_grants, &values, handles, system.name_pack(system.name_of(writer.name[:])), columns, rows, measure)
	// The settings page, font outlines, and fresh bytes page.
	mappings: [3]system.Mapping
	mapping_count := 0
	text_settings_give(mappings[:], &mapping_count, &values)
	fresh_bytes_page_give(view, mappings[:], &mapping_count, &values)
	if context_refused(terminal_name, &context_grants, &values) {
		fresh_bytes_forget(view)
		system.send(&control.commands, ring.Record{kind = u32(display.Control.Client_Remove), values = {0 = u64(client)}})
		return .Bad_State
	}
	// The terminal imports the drawing module: its load needs the boot
	// image as the source of its imports.
	load_error: module.Load_Error
	process, status := system.process_start(system.image_find(image, terminal_name), terminal_name, context_grants.grants, random.values_with_seed(&process_generator, values.values), budget_of(system.image_find(image, terminal_name), terminal_name), mappings[:mapping_count], &prepared, load_source(), &load_error)
	if status != .Ok {
		fresh_bytes_forget(view)
		if load_error.stage != u32(module.Load_Stage.None) {
			system.log_fact(.Warning, Terminal_Load_Refused{})
			load_error_log(.Warning, &load_error)
		}
		system.send(&control.commands, ring.Record{kind = u32(display.Control.Client_Remove), values = {0 = u64(client)}})
		return status
	}
	view.process, view.client, view.writer, view.is_terminal = process, client, writer, true
	view.start_grant_set = start_grant_set
	view.principal = writer.principal // The lock stops the terminal of a process of the session with it.
	copy(view.name[:len(view.name) - 1], terminal_name)
	return .Ok
}

// connect makes a connection from a caller to the service with a name: a
// new call ring and a new call region, that the two processes receive. This
// service pays for the two memory objects and does not keep them. values is
// the completion of Root_Command.Connect. client: the row of the client
// table that the connection is for, or none.
connect :: proc "contextless" (caller: ^Started, name: string, values: ^[7]u64, history := false, client: Client_Grant = {}) -> system.Status {
	free, service, ring_memory, region_memory := connection_open(caller, name, history, client) or_return
	defer system.close(ring_memory)
	defer system.close(region_memory)
	// The caller receives its handles through its ring to this service.
	status: system.Status
	given: [3]system.Handle
	// The process handle of the service, with Read only and never Give: a
	// handle with Read and Give lends to log.process_records, and would give
	// each client the log records of the service
	// (src/md/features/log_reader_scope.md).
	given[0], status = system.give(caller.requests_memory, service.process, {.Read})
	if status == .Ok {
		given[1], status = system.give(caller.requests_memory, ring_memory, {.Read, .Write})
	}
	if status == .Ok {
		given[2], status = system.give(caller.requests_memory, region_memory, {.Read, .Write})
	}
	if status != .Ok {
		disconnect(free)
		return status
	}
	free.caller_service_handle = given[0]
	hash := transmute([4]u64)service.hash
	values^ = {u64(given[0]), u64(given[1]), u64(given[2]), hash[0], hash[1], hash[2], hash[3]}
	// The principal of the connection, and whether the caller acts for it.
	acts := connection_grant(free) & isolated.CALLER_ACTS_FOR_PRINCIPAL != 0
	switch {
	case history:
		system.log_fact(.Info, Connected_History{caller = module_name_field(system.name_of(caller.name[:])), service = module_name_field(name), limit = HISTORY_STORE_LIMIT, principal = caller.principal})
	case client.place != 0 && acts:
		head: [16]u8
		system.log_fact(.Info, Connected_Acting_With_Client_Key{caller = module_name_field(system.name_of(caller.name[:])), service = module_name_field(name), principal = client.principal, client_key = text_field(key_head_text(&head, client.key), 24)})
	case client.place != 0:
		head: [16]u8
		system.log_fact(.Info, Connected_With_Client_Key{caller = module_name_field(system.name_of(caller.name[:])), service = module_name_field(name), principal = client.principal, client_key = text_field(key_head_text(&head, client.key), 24)})
	case acts:
		system.log_fact(.Info, Connected_Acting{caller = module_name_field(system.name_of(caller.name[:])), service = module_name_field(name), principal = caller.principal})
	case:
		system.log_fact(.Info, Connected{caller = module_name_field(system.name_of(caller.name[:])), service = module_name_field(name), principal = caller.principal})
	}
	return .Ok
}

// connection_open makes the service side of a connection from a caller to
// the service with a name, and starts the service if it starts on demand.
// It gives the call ring and the call region: give them to the caller,
// then close them.
connection_open :: proc "contextless" (caller: ^Started, name: string, history := false, client: Client_Grant = {}, store_override: string = "", store_limit_override: u64 = 0) -> (free: ^Connection, service: ^Started, ring_memory, region_memory: system.Handle, status: system.Status) {
	for pass in 0 ..< 2 {
		for &item in started {
			if item.process != 0 && item.service.head != nil && system.name_of(item.name[:]) == name {
				service = &item
			}
		}
		if service != nil || pass == 1 || !on_demand(name) {
			break
		}
		if status = start(name); status != .Ok {
			return nil, nil, 0, 0, status
		}
	}
	if service == nil || service == caller {
		return nil, nil, 0, 0, .Bad_Handle
	}
	count := 0
	for &connection in connections {
		if connection.caller == nil {
			free = &connection
		} else if connection.service == service {
			count += 1
			if connection.caller == caller && connection.history == history && connection.client.place == client.place {
				return nil, nil, 0, 0, .Bad_State
			}
		}
	}
	if free == nil || count == isolated.SERVICE_CONNECTION_CAPACITY {
		return nil, nil, 0, 0, .No_Slot
	}
	// The service ring keeps room for one Disconnect for each connection:
	// this service never waits for a service that does not read its ring.
	names := &service.service.commands
	if ring.capacity(names) - ring.count(names) < u32(count) + 2 {
		return nil, nil, 0, 0, .No_Slot
	}
	// The storage service names the store of a connection by the name that
	// it receives: the store of the history has the name of the caller and
	// ".history", which no module of the boot image has, and the store of a
	// named principal has its number after it (src/library/modus/principals). Each
	// other service receives the name of the process. A name that does not
	// fit is refused before anything is made: a cut name can be the name of
	// another store.
	store_name: system.Name
	if is_role_holder(system.name_of(service.name[:]), .Storage) {
		if store_override != "" {
			if len(store_override) >= len(store_name) {
				return nil, nil, 0, 0, .Bad_Operation
			}
			copy(store_name[:len(store_name) - 1], store_override)
		} else {
			// The store of a disk process is the store of its nickname, with a
			// prefix that no module name has (disk_processes.odin).
			process_of_the_store := system.name_of(caller.name[:])
			disk_store_name: [32]u8
			if caller.from_disk {
				process_of_the_store = disk_process.store_process_name(&disk_store_name, process_of_the_store)
			}
			// A connection for a row of the client table belongs to the
			// principal of the row.
			principal_of_the_store := client.place != 0 ? client.principal : caller.principal
			if !principals.store_name_write(&store_name, process_of_the_store, principal_of_the_store, history) {
				system.log_fact(.Warning, Store_Name_Too_Long{principal = caller.principal, caller = module_name_field(system.name_of(caller.name[:]))})
				return nil, nil, 0, 0, .Bad_Operation
			}
		}
	} else {
		copy(store_name[:len(store_name) - 1], system.name_of(caller.name[:]))
	}
	ring_memory = system.memory_create(ring.PAGE_COUNT) or_return
	region_memory, status = system.memory_create(isolated.REGION_PAGES)
	in_service_ring, in_service_region: system.Handle
	if status == .Ok {
		in_service_ring, status = give_through_service_ring(service.process, service.service_memory, ring_memory, {.Read, .Write}, &service.service_ring_ready)
	}
	if status == .Ok {
		in_service_region, status = give_through_service_ring(service.process, service.service_memory, region_memory, {.Read, .Write}, &service.service_ring_ready)
	}
	if status != .Ok {
		system.close(ring_memory)
		if region_memory != 0 {
			system.close(region_memory)
		}
		return nil, nil, 0, 0, status
	}
	caller_name := transmute([4]u64)store_name
	grant: u64
	switch {
	case store_override != "":
		grant = isolated.caller_grant_make(store_limit_override, caller.principal, false)
	case history:
		grant = isolated.caller_grant_make(HISTORY_STORE_LIMIT, caller.principal, false)
	case client.place != 0:
		grant = client_connection_grant(caller, client)
	case:
		grant = grant_for(caller, service)
	}
	if !system.send(&service.service.commands, ring.Record{kind = u32(isolated.Service_Command.Connect), values = {0 = u64(in_service_ring), 1 = u64(in_service_region), 2 = caller_name[0], 3 = caller_name[1], 4 = caller_name[2], 5 = caller_name[3], 6 = grant}}) {
		system.close(ring_memory)
		system.close(region_memory)
		return nil, nil, 0, 0, .No_Slot
	}
	// An amount is a store for the storage service only: for the log
	// service, it names the process of the caller.
	if grant & isolated.CALLER_AMOUNT_MASK != 0 && is_role_holder(system.name_of(service.name[:]), .Storage) {
		caller.granted += {history ? system.Root_Grant.History : system.Root_Grant.Store}
	}
	free^ = {
		caller  = caller,
		service = service,
		ring    = in_service_ring,
		region  = in_service_region,
		history = history,
		client  = client,
	}
	return free, service, ring_memory, region_memory, .Ok
}

// grant_room_short gives the first service whose service ring cannot hold
// one Grant record for each connection of a process to it, with the room
// for one Disconnect of each connection of that service still kept
// (connection_open keeps it, so that an end of a connection always reaches
// the service). nil: each ring holds them.
grant_room_short :: proc "contextless" (item: ^Started) -> ^Started {
	for &asked in connections {
		if asked.caller != item {
			continue
		}
		grants: u32
		connected: u32
		for &other in connections {
			if other.caller == nil || other.service != asked.service {
				continue
			}
			connected += 1
			if other.caller == item {
				grants += 1
			}
		}
		names := &asked.service.service.commands
		if ring.capacity(names) - ring.count(names) < grants + connected {
			return asked.service
		}
	}
	return nil
}

// disconnect ends a connection: the service unmaps the call ring and the
// call region. The service ring has room for the record (see connect); a
// service that gives a false count of records read keeps its own mappings.
disconnect :: proc "contextless" (connection: ^Connection) {
	// The debug access that the service has for this caller ends with the
	// connection: the service debugs a process only for a caller that can
	// still call it.
	if !connection.history {
		for &other in started {
			if other.process != 0 && other.debugger == connection.service && other.debug_for == connection.caller && other.debug_for_row == connection.client.place {
				debug_end(&other)
			}
		}
	}
	if connection.service.process != 0 {
		system.send(&connection.service.service.commands, ring.Record{kind = u32(isolated.Service_Command.Disconnect), values = {0 = u64(connection.ring), 1 = u64(connection.region)}})
	}
	system.log_fact(.Info, Disconnected{caller = module_name_field(system.name_of(connection.caller.name[:])), service = module_name_field(system.name_of(connection.service.name[:]))})
	// The connection of the service disk_processes for a load from the
	// disk: the load learns here that it ended.
	if disk_load.connection == connection {
		disk_load.connection = nil
	}
	persisted_table_connection_ended(connection)
	if debug_store.connection == connection {
		debug_store = {}
	}
	connection^ = {}
}

// The stop of a process as the reap read it from the kernel: one read of
// Process_State for the fact of the stop and for the end words.
Process_Stop :: struct {
	state:   op.Process_State,
	cause:   op.Stop_Cause,
	outcome: op.Stop_Outcome,
}

// release frees what this service holds for a process, and tells the
// compositor. stop is the stop that the reap read; a start that this
// service abandons, or a process that it lets go with no reap, gives none.
release :: proc "contextless" (item: ^Started, stop: Process_Stop = {}) {
	// The row goes before the handle closes: the kernel can then give the
	// slot to another process, which the row must not name.
	disk_process_page_remove(item)
	// The connections of the process end: those that it made, and those
	// that it served.
	served := item.service.head != nil
	// A terminal that stops: its process stops. A process that stops: its
	// terminal stays, and shows what the process wrote.
	if item.writer != nil && item.writer.process != 0 {
		started_process_stop(item.writer)
	}
	// A debugged process that stops, a debugger service that stops, and a
	// caller of the debugger service that stops: the debug access ends.
	if item.debugger != nil {
		debug_end(item)
	}
	// Emit Process_Stop_Notice on the core's `stops` output so the
	// delegated wiring service ends each wiring of this process and frees
	// its slots, then release core wiring handles.
	wiring_service_end(item)
	disk_processes_service_end(item)
	devices_service_end(item)
	principals_service_end(item)
	wiring_emit_stop_notice(item, stop)
	for &other in started {
		if other.process != 0 && (other.debugger == item || other.debug_for == item) {
			debug_end(&other)
		}
		if other.writer == item {
			other.writer = nil
		}
		if other.asker == item {
			other.asker = nil
		}
		if other.driver == item {
			other.driver = nil
		}
	}
	// The connection for a kept stop report ends with its caller and with
	// the debugger service.
	debug_store_release(item)
	// A client that stops: its device service stops (bus master off first).
	// A device service that stops: the device stops using memory.
	if item.driver != nil && item.driver.process != 0 {
		started_process_stop(item.driver)
	}
	if item.is_driver {
		driver_end(item)
	}
	tpm_service_end(item)
	entropy_service_end(item)
	fresh_bytes_forget(item)
	endpoint_close(item)
	disk_load_forget(item)
	principal_change_forget(item)
	if palette_provider == item {
		palette_provider_end(item, false)
	}
	if item.network.head != nil {
		network_end(item)
	}
	if item.process != 0 && item.process == display_holder {
		display_holder_end()
	}
	if item.process != 0 {
		system.close(item.process)
		item.process = 0
	}
	for &connection in connections {
		if connection.caller == item || connection.service == item {
			disconnect(&connection)
		}
	}
	if served {
		system.ring_close(&item.service)
		system.close(item.service_memory)
	}
	if item.client != 0 {
		system.send(&control.commands, ring.Record{kind = u32(display.Control.Client_Remove), values = {0 = u64(item.client)}})
	}
	if item.requests.head != nil {
		system.ring_close(&item.requests)
		system.close(item.requests_memory)
	}
	if item.process != 0 {
		system.close(item.process)
	}
	item^ = {}
}

// reap finds the processes that stopped.
reap :: proc "contextless" () {
	for &item in started {
		if item.process == 0 {
			continue
		}
		state, cause, outcome := system.process_state(item.process)
		if state == .Stopped {
			// A finished work, a clean stop that a call or an event asked,
			// and a stop by a holder are the expected ends; each other stop
			// is a warning.
			level := op.Log_Level.Warning
			switch cause {
			case .Itself:
				switch outcome {
				case .Done, .Stopped_On_Request:
					level = .Info
				case .None, .Failed, .Refused:
				}
			case .Holder:
				level = .Info
			case .None, .Last_Thread_Ended, .Handles_Closed, .Fault, .Not_Committed, .Cannot_Return, .Fault_Unanswered:
			}
			// The run of `unlock` before the start policy has a line of its
			// own: a wait for the stop of the run of the start list never
			// takes it. A template has no condition: a stop of itself has
			// its outcome, each other stop has none, so each sentence is a
			// fact type.
			stopped_process := module_name_field(system.name_of(item.name[:]))
			without_window := unlock_without_window_running(&item)
			switch {
			case without_window && cause == .Itself:
				system.log_fact(level, Unlock_Without_Window_Stopped{stopped_process = stopped_process, cause = cause, outcome = outcome})
			case without_window:
				system.log_fact(level, Unlock_Without_Window_Stopped_Without_Outcome{stopped_process = stopped_process, cause = cause})
			case cause == .Itself:
				system.log_fact(level, Process_Stopped{stopped_process = stopped_process, cause = cause, outcome = outcome})
			case:
				system.log_fact(level, Process_Stopped_Without_Outcome{stopped_process = stopped_process, cause = cause})
			}
			// The kernel forgets the stop report with the last handle,
			// which release closes: a disk process keeps it here.
			if stopped_role := role_of_module_name(system.name_of(item.name[:])); stopped_role != .None {
				_ = role_supervision_advance(stopped_role, nil)
				_, _ = delegated_service_on_stop(system.name_of(item.name[:]), system.time(), true)
			}
			stop_report_keep(&item)
			if !item.is_terminal && system.name_of(item.name[:]) == "unlock" {
				unlock_stopped()
			}
			start_policy_stopped(&item, cause, outcome)
			// release closes the handle of the process, which is the handle
			// of the compositor: no later start may give to it.
			display_holder_reaped := item.process == display_holder
			// A compositor that this service stopped for the rescue is
			// started again by the rescue: it is no absence of the screen.
			stopped_for_the_rescue := item.stop_asked_by_root_service
			// The stop of an asker of wirings: the tables of this service,
			// after the wirings of the asker ended, as a measure of its
			// margin (own_tables.odin).
			asker_name: system.Name
			asker_measured := root_ring.sender_allowed(.Wire, item.start_grant_set.grants)
			if asker_measured {
				asker_name = item.name
			}
			// The one read of the stop serves the fact above and the end
			// words of the wirings of the process.
			release(&item, {state = state, cause = cause, outcome = outcome})
			if asker_measured {
				own_tables_measure(system.name_of(asker_name[:]))
			}
			// A later start gets no window and a start with a terminal is
			// refused (start_view_give), and nothing starts here.
			if display_holder_reaped {
				display_holder = 0
				if !stopped_for_the_rescue {
					screen_absence_note()
				}
			}
		}
	}
}
