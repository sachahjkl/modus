// The root service: the first program, and the centre of the grants.
//
// The kernel gives it every handle that exists at boot: the machine, the
// boot image, the framebuffer, the devices. It starts the other programs,
// and it gives each one only the handles of its role. It is the **only
// program that creates access from nothing**: each other handle of the
// system came from it, directly or through a chain of programs.
//
// **What it is for.** A program never takes access for itself. It receives
// it at its start, or it asks this service on its *root ring*, and this
// service answers by the tables of this file:
//
// - `program_roles` (roles.odin): the role of each program of the boot
//   image, by its name, in one row: its start grants and the other terms
//   of its role (the services that a program with the grant `Connect` can
//   reach, the blocks of a private store, the log with Give, the size of a
//   terminal), with the reason of each. The site shows them in the table
//   "The grants of each program", and the build stops when a program of
//   the boot image has no row.
// - `budget_of` (budgets.odin): the budget that the module of a program
//   asks for, accepted up to the largest budget of a program, and the table
//   of the exceptions, each with its reason.
//
// A start reads the role of a program one time (`role_of`), and the
// program keeps it in `Started.role`: each rule after the start reads it
// there, never by the name. A program whose row has no grant receives the
// log and a window. A disk program is never a row of these tables: this
// service refuses a file of a disk whose name one of them names, or whose
// name a module of the boot image has (disk_programs.odin).
//
// **The commands of the root ring** (`Root_Command` in the package
// root_ring, root_ring.odin). The table `root_ring.ROOT_COMMAND_SENDERS`
// says who sends each one: a program with the grant **Root_Ring** (the
// console) sends most of them; a program with **Connect** sends `Connect`
// to the services of its role, and `Disconnect`; the program with
// **Principals** sends `Principal_Record`, `Principal_Unlock`,
// `Machine_Key` and `Principal_Change_End`, and no other program can; the
// program with **Debugger** sends `Debug` and `Debug_Store`.
//
// - `Start`, `Stop`: a program by name, in the session of the caller.
// - `Start_From_Disk`: a disk program, by its name and the hash of its
//   module file, which this service reads from the store `programs` of the
//   storage service. Its completion comes when the load ends
//   (disk_programs.odin; docs/MODULE_CONTRACT.md, "A program from a disk").
// - `Disk_Grant`, `Nickname_Move`, `Disk_Grant_Persistence`: the disk
//   grant table of the principal of the caller: a grant to the file that a
//   nickname names, the move of a nickname to another file, and how long a
//   row lasts (disk_programs.odin; docs/MODULE_CONTRACT.md, "The grants of
//   a disk program").
// - `Connect`, `Disconnect`, `Connect_History`: a connection to a service.
// - `Palette_Provide`: the entry table and the ring of the palette
//   provider, for the program with the grant **Palette**.
// - `Grants`, `Revoke`: read the grants of a program, end one of them.
//   The kernel ends each handle that came from the grant, also in the
//   programs that received it from that program.
// - `Replace`: change the replacement table of the machine.
// - `Principal_Create`, `Principal_Lock`, `Principals`, `Principal_Change`:
//   the named principals (docs/PRINCIPALS.md, "7. The commands").
// - `Machine_Passphrase`: the machine passphrase, which guards the key of
//   the disk grant table of principal 0 (persisted_grant_table.odin).
// - `Machine_Seal`: a machine key that the TPM service seals to the
//   measure of the system, with a recovery key (tpm.odin).
// - `Debug`: the handle of a program with the right Debug, for the
//   debugger service, on behalf of a caller of that service that acts for
//   the principal whose session runs that program (`debug`).
// - `Debug_Store`: for that debugger service, a connection that reads only
//   to the store `programs` of a disk program that it debugs, where the
//   debug object of the program is (debug_store.odin); or that connection
//   and the stop report that this service kept of a disk program that
//   stopped on a fault.
//
// A refused command has an error record in its completion: the console
// prints it, for example after `revoke("notes", "store")` on a program
// that does not run. The border and the check of the sender write the
// record of their refusal; after them, the procedure of the command writes
// it (root_ring.odin).
//
// **What a reader sees.** At boot the screen shows the boot display, with
// each step, until the compositor takes the screen. The log has
// "root: ok, N modules in the boot image", the strength of the random seed,
// then one line "root: started NAME" for each program, and, when the
// console is started, one measure: "root: the start is done: the budget of
// this service holds N free pages, M at the lowest".
//
// **What it does not do.** It does not run the code of a program, and it
// does not check what a program does with a grant. It checks only the
// identity of the boot image against the system description
// (docs/TRUSTED_BOOT.md), and the budget of each program.
//
// The design: (docs/ARCHITECTURE.md, "U2. Root service").
package root

import "modus:support/bochs_display"
import "modus:support/bootscreen"
import "modus:support/bootscreen/collect"
import "modus:support/display"
import "modus:support/graphics"
import info "modus:contract/boot_info"
import "modus:contract/isolated"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:support/random"
import "modus:support/system"
import terminal "modus:support/terminal"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/fixed_addresses"
import "modus:contract/log_scope"
import "modus:contract/root_ring"
import "modus:support/pci"
import "modus:support/principals"
import "modus:support/disk_program"
import "modus:contract/settings"
import "modus:contract/palette_table"
import "modus:contract/start_grant"

ROOT_MARK :: "root: ok"

// What a program receives, by name: a start grant. The list and the name of
// each one are a contract, because the reader of an error record names the
// start grant that refused a debug access (src/library/contract/start_grant).
Grant :: start_grant.Grant

// The context of the input service: the slots that src/modules/system/input
// names GRANT_RING, GRANT_PORTS, GRANT_KEYBOARD_INTERRUPT and
// GRANT_MOUSE_INTERRUPT. A program is no package that this service
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
// blocks of its role. Each service: the principal of the session of the
// caller, and the flag that the caller acts for that principal (the manual
// gives what runs only to such a caller).
grant_for :: proc "contextless" (caller: ^Started, service: ^Started) -> u64 {
	// The connection of this service itself, for the read of the module
	// file of a disk program: the store of the module files, with its
	// limit, and no grant to act for a principal.
	if caller == &disk_reader {
		return isolated.caller_grant_make(disk_program.STORE_BLOCKS_LIMIT, caller.principal, false)
	}
	// The connection of this service for the disk grant table of a
	// principal, an object of the store of the module files of that
	// principal (persisted_grant_table.odin).
	if persisted_table_keeper_is(caller) {
		return isolated.caller_grant_make(disk_program.STORE_BLOCKS_LIMIT, caller.principal, false)
	}
	// The connection of the debugger service to the same store, for the
	// debug object of a disk program: it reads only (debug_store.odin).
	if caller == &debug_store_reader {
		return isolated.caller_grant_make(disk_program.STORE_BLOCKS_LIMIT, caller.principal, false) | isolated.CALLER_READS_ONLY
	}
	// The log service: the own records of the caller, named by its program
	// slot and its program serial; with the grant to act for the principal,
	// the whole log (src/md/features/log_reader_scope.md). A disk program
	// never acts for a principal.
	if system.name_of(service.name[:]) == "log" {
		whole_log := !caller.from_disk && .Acts_For_Principal in caller.role.grants && .Acts_For_Principal not_in caller.revoked
		return isolated.caller_grant_make(own_records_amount_of(caller), caller.principal, whole_log)
	}
	// A disk program: the grants of its start, never the grants of a name,
	// and never the grant to act for a principal.
	if caller.from_disk {
		return isolated.caller_grant_make(disk_store_limit(caller, service), caller.principal, false)
	}
	role := &caller.role
	amount: u64
	if .Store in role.grants && .Store not_in caller.revoked && system.name_of(service.name[:]) == "storage" {
		amount = role_store_blocks(role)
	}
	acts := .Acts_For_Principal in role.grants && .Acts_For_Principal not_in caller.revoked
	grant := isolated.caller_grant_make(amount, caller.principal, acts)
	// The grant to erase versions is a right over the private store: it goes
	// with the store, to the storage service only.
	if amount != 0 && .Versions_Erase in role.grants {
		grant |= isolated.CALLER_ERASES_VERSIONS
	}
	return grant
}

// own_records_amount_of gives the amount of the grant of a connection to
// the log service: the program slot and the program serial of the caller,
// which the kernel gives for its program handle. A slot that the kernel does
// not give, or that does not fit, gives 0: the caller then reads no record,
// never the records of another program.
own_records_amount_of :: proc "contextless" (caller: ^Started) -> u64 {
	results, status := system.call(.Program_State, u64(caller.program))
	if status != .Ok {
		return 0
	}
	amount, ok := log_scope.own_records_amount(results[3], results[4])
	if !ok {
		system.log_in("calls", .Warning, "root: the program slot ", results[3], " or the program serial ", results[4], " of ", system.Module_Name{system.name_of(caller.name[:])}, " does not fit the grant of the log service: it reads no record")
		return 0
	}
	return amount
}

// log_grant gives the grant of the log: each program that this service
// starts can write on the log. A program whose role says so can also give
// the log to the programs that it starts.
log_grant :: proc "contextless" (role: Program_Role) -> system.Grant {
	rights := system.Rights{.Write}
	if role.log_gives {
		rights += {.Give}
	}
	return {system.context_record().handles[op.CONTEXT_LOG], rights}
}

// A program that this service started.
Started :: struct {
	program:         system.Handle, // 0: the slot is free.
	client:          system.Handle, // The ring of the program, as the compositor names it.
	requests:        ring.Ring, // The ring from the program to this service, if it has one.
	requests_memory: system.Handle,
	service:         ring.Ring, // The service ring of the program, if it is a service.
	service_memory:  system.Handle,
	hash:            [32]u8, // The hash of the file of the program.
	name:            system.Name,
	// The role that this service gave the program when it started it: each
	// rule after the start reads it here, in the state of the program that
	// runs, and never in a table by the name of the program (the sender of
	// a command, the debug access, the grant of a connection).
	role:            Program_Role,
	granted:         system.Root_Grants, // What the program has from this service, of the grants that this service can revoke.
	revoked:         system.Root_Grants,
	writer:          ^Started, // A terminal: the program that writes in it. nil after that program stopped.
	is_terminal:     bool,
	driver:          ^Started, // The block service that serves this program. nil: none, or it stopped.
	is_driver:       bool, // A block service: it has the device at `device`.
	device:          pci.Place,
	bridge_group:    Bridge_Group, // A device behind a conventional bridge: the buses behind it, whose devices this service holds too (devices.odin). Zero: none.
	queues:          system.Handle, // A block service: the memory of the queue of its device.
	network:         ring.Ring, // The network service: the control ring from this service.
	network_memory:  system.Handle,
	endpoint:        system.Handle, // A program with an endpoint: its datagram ring, as the network service names it.
	network_service: ^Started,
	// The principal whose session the program belongs to (docs/PRINCIPALS.md):
	// 0, the machine, for the programs of the system and each program that a
	// program of the machine starts; the named principal whose session runs
	// for a program that the desktop starts.
	principal:       u64,
	// The program that received the handle of this program with the right
	// Debug (Root_Command.Debug): the debugger service. nil: none, or it
	// stopped, or the grant was revoked.
	debugger:        ^Started,
	// A disk program: its name is a nickname, which no table by name of
	// this service reads. Its grants are `role`, from the disk grant table
	// of its principal at its start, and its store is the store of the
	// nickname (disk_programs.odin).
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
	// A start holds this place while it builds the program, before the
	// program runs: a start that the start runs (a service on demand) takes
	// another place. release clears it with the place.
	reserved:        bool,
}

// place_is_free says if a place of the table of the programs holds no
// program and no start that builds one.
place_is_free :: proc "contextless" (item: ^Started) -> bool {
	return item.program == 0 && !item.reserved
}

// A connection: one caller can call the exports of one service.
Connection :: struct {
	caller:  ^Started, // nil: the place is free.
	service: ^Started,
	ring:    system.Handle, // The call ring, as the service names it.
	region:  system.Handle, // The call region, as the service names it.
	// The connection to the store of the line history of the caller
	// (Root_Command.Connect_History): its grant is the limit of that store,
	// never the private store and never the grant to act for the principal.
	history: bool,
	// A connection of `remote` for one row of the client table: it acts
	// for the principal of the row, and ends when the grant of the row
	// ends (remote_clients.odin). place 0: none.
	client:  Client_Grant,
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
// The shared code of the modules of the programs that this service starts.
prepared: system.Prepared_Modules
compositor: system.Handle
control: ring.Ring
control_memory: system.Handle

// The replacement table of the machine: this service writes it. Each
// program that this service starts receives its records (a program cannot
// ask for a replacement and cannot refuse one: a replacement is not an
// access that a program takes for itself).
replacement_memory: system.Handle
replacement_table: ^system.Replacement_Table
replacement_records: [system.REPLACEMENT_CAPACITY]module.Replacement

// load_source gives what the loader of a program that this service starts can
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

// shortage_start gives the program shortage nearly all the pages of this
// service, and the machine; the program stops the machine at its end. This
// service keeps SHORTAGE_KEEP pages: the module of the program is copied in
// memory that it pays.
SHORTAGE_KEEP :: 24

shortage_start :: proc "contextless" (ctx: ^system.Context) -> ! {
	own, _ := system.budget_read()
	context_grants: system.Context_Grants
	values: system.Context_Values
	system.grant_put(&context_grants, system.GRANT_MACHINE, {machine, {.Inspect, .Stop}})
	system.grant_put(&context_grants, op.CONTEXT_LOG, log_grant(role_of("shortage")))
	if context_refused("shortage", &context_grants, &values) {
		shortage_failed()
	}
	amounts := system.Budget_Amounts {
		pages       = own.pages - SHORTAGE_KEEP,
		programs    = 1,
		threads     = 8,
		processor   = own.processor,
		log_records = LOG_RECORDS_OF_A_PROGRAM,
	}
	if _, status := system.program_start(system.image_find(image, "shortage"), "shortage", context_grants.grants, random.values_with_seed(&program_generator, values.values), amounts, nil, &prepared); status != .Ok {
		system.log("root: cannot start shortage: status ", status)
		shortage_failed()
	}
	system.log("root: started shortage with ", system.Size{amounts.pages, .Pages})
	for {
		system.sleep(max(u64))
	}
}

// The program that runs the operation sequences (src/md/infrastructure/kernel_fuzzing.md).
OPERATION_FUZZING_NAME :: "operation_fuzzing"
// Its budget: its mailbox, the shared code of its runners, and the budget
// of each sequence, which it creates and ends for each one.
OPERATION_FUZZING_PAGES :: 8192

// operation_fuzzing_start starts operation_fuzzing with the machine with
// the right Physical only: it reads the physical address of its mailbox,
// which the tool reaches through the memory file of the machine. It gives
// no other right of the machine, and this service starts nothing else.
operation_fuzzing_start :: proc "contextless" () -> ! {
	own, _ := system.budget_read()
	context_grants: system.Context_Grants
	values: system.Context_Values
	role := role_of(OPERATION_FUZZING_NAME)
	system.grant_put(&context_grants, system.GRANT_MACHINE, {machine, {.Physical}})
	system.grant_put(&context_grants, system.GRANT_IMAGE, {image_memory, {.Read}})
	system.grant_put(&context_grants, op.CONTEXT_LOG, log_grant(role))
	system.value_put(&values, system.GRANT_VALUE_IMAGE_SIZE, u64(len(image)))
	if context_refused(OPERATION_FUZZING_NAME, &context_grants, &values) {
		fail("the context of operation_fuzzing was refused", .Bad_Operation)
	}
	amounts := system.Budget_Amounts {
		pages       = OPERATION_FUZZING_PAGES,
		programs    = 16,
		threads     = 32,
		processor   = own.processor,
		log_records = LOG_RECORDS_OF_A_PROGRAM,
	}
	if _, status := system.program_start(system.image_find(image, OPERATION_FUZZING_NAME), OPERATION_FUZZING_NAME, context_grants.grants, random.values_with_seed(&program_generator, values.values), amounts, nil, &prepared); status != .Ok {
		fail("cannot start operation_fuzzing", status)
	}
	system.log("root: started operation_fuzzing with ", system.Size{amounts.pages, .Pages})
	for {
		system.sleep(max(u64))
	}
}

// shortage_failed ends the machine of the test of a shortage whose program
// did not start. The machine has nothing else to run: this service waits
// whatever Machine_Stop gives, so the test ends on the stop code or on its
// hang bound, and never on a start that went on after a refusal.
shortage_failed :: proc "contextless" () -> ! {
	system.call(.Machine_Stop, u64(machine), 1)
	for {
		system.sleep(max(u64))
	}
}

// fail ends the start of the machine. The machine does not stop: the boot
// display stays, with the failure, until the machine is stopped from outside.
fail :: proc "contextless" (text: string, status: system.Status) -> ! {
	system.log_in("programs", .Error, "root: ", text, ": status ", status)
	if compositor != 0 {
		system.call(.Program_Stop, u64(compositor), 0) // The screen returns to this service.
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
	system.log("root: the boot display shows the failure")
	for {
		system.sleep(max(u64))
	}
}

// The random generator of the root service: its seed comes from the
// sources of the processor (src/library/support/random/entropy.odin), not from a
// starter. It gives the seed of each program that root starts.
program_generator: random.Generator
entropy_report: random.Entropy_Report

// The entry of the root service: it brings up the system, then answers the
// root rings of the programs for the life of the machine.
//
// The kernel starts it with the context of the root service: the machine,
// the boot image, the framebuffer and their values. The entry, in order:
//
// 1. maps the boot image and the debug image; writes "root: ok, N modules
//    in the boot image";
// 2. takes the screen for the boot display;
// 3. checks the boot image against the system description (trust.odin);
//    a failure stays on the screen and no program starts;
// 4. reads the principals, and seeds the random generator of the system
//    from the sources of the processor; a seed of 32 zero bytes ends the
//    boot;
// 5. on the machine of the test of a shortage of frames, starts the program
//    `shortage` and nothing else;
// 6. creates the settings page, the date page and the replacement table;
// 7. starts `input` with the ports and the interrupts of the PS/2
//    controller, then the compositor with the framebuffer, then the entropy
//    service when the machine has an entropy device, with no wait for its
//    bytes, then the font service, which draws the demand cache and ends
//    (font_service.odin);
// 8. starts `date`, then the console, then the settings that were kept,
//    then the TPM service when the system is measured into a TPM, then
//    `unlock`.
//
// A failure in steps 1 to 8 calls `fail`: the boot display shows the cause,
// and the machine waits until it is stopped from outside.
//
// Then one loop runs for ever. It waits on the control ring of the
// compositor (a start or a stop from the desktop), on the root ring of each
// program, and on the answers of the network service and of the entropy
// service, whose bytes it mixes into its generator; every 30 seconds it
// asks the entropy service for the fresh bytes of the running programs
// (entropy.odin). It checks each command
// against the grants of the caller, runs it, and sends a completion. After
// each pass, `reap` frees what this service held for the programs that
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
	system.log("root: Machine_Stop refused the codes ", refused_codes[0], " and ", refused_codes[1], " with Bad_Operation and the record Bad_Value of the code, limit ", u64(op.MACHINE_STOP_CODE_MOST), ", and the machine runs on: as it must")
	// The screen first: a failure of the check below stays on it.
	boot_display_take(ctx)
	// The boot image against the system description, before any program
	// starts (trust.odin).
	trust_check()
	principals_start()
	// The random seed of the system: before the first program starts.
	random_seed_make()
	// The machine of the operation sequences: only its boot image holds the
	// program operation_fuzzing, and it starts nothing else.
	if len(system.image_find(image, OPERATION_FUZZING_NAME)) != 0 {
		operation_fuzzing_start()
	}
	// The machine of the test of the shortage of frames: its boot image has
	// the program shortage and no input service, so no desktop.
	if len(system.image_find(image, "input")) == 0 && len(system.image_find(image, "shortage")) != 0 {
		shortage_start(ctx)
	}
	// The settings page and the glyph cache, before the first boot display.
	text_settings_create()
	date_page_create()
	appearance_open() // appearance_edge.odin
	disk_program_page_create()
	fresh_bytes_create() // fresh_bytes.odin
	show("the root service starts input", .Running, .Input)
	replacement_table_create()
	remote_clients_create()
	input_memory := input_start()
	show("the root service starts the compositor", .Running, .Compositor)
	compositor_start(ctx, input_memory)
	programs_of_the_boot_start()
	for {
		root_loop_pass()
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
	system.log(ROOT_MARK, ", ", u64(len(system.image_entries(image))), " modules in the boot image")
	debug_image_take(ctx)
}

// boot_display_take maps the framebuffer for the boot display. With no
// framebuffer, the boot display shows nothing and the start goes on.
boot_display_take :: proc "contextless" (ctx: ^system.Context) {
	pixels, map_status := system.memory_map(ctx.handles[op.ROOT_FRAMEBUFFER], {.Write})
	if map_status != .Ok {
		return
	}
	screen = {
		pixels = ([^]graphics.Color)(pixels),
		width  = int(ctx.values[op.ROOT_VALUE_WIDTH]),
		height = int(ctx.values[op.ROOT_VALUE_HEIGHT]),
		stride = int(ctx.values[op.ROOT_VALUE_PIXELS_PER_LINE]),
	}
	screen_data.image = image
	screen_data.red_first = ctx.values[op.ROOT_VALUE_FORMAT] == u64(info.Pixel_Format.Red_Green_Blue_X)
}

// random_seed_make seeds the random generator of the system from the
// sources of the processor, and writes the facts of the seed.
random_seed_make :: proc "contextless" () {
	seed := random.entropy_gather(random.sources_of_the_processor(), &entropy_report)
	if !random.generator_seed(&program_generator, &seed, entropy_report.strength) {
		// BLAKE3 does not give 32 zero bytes in practice; if it does, root
		// says why it cannot start a program, instead of a stop at its
		// first draw.
		fail("the random seed of the system is 32 zero bytes: no program can get a seed", .Bad_Operation)
	}
	report := &entropy_report
	system.log("root: the random seed of the system, strength ", op.seed_strength_names[report.strength], ": rdseed ", report.rdseed_present ? "present" : "absent", ", ", u64(report.rdseed_good), " good values, ", u64(report.rdseed_refused), " refused; rdrand ", report.rdrand_present ? "present" : "absent", ", ", u64(report.rdrand_good), " good, ", u64(report.rdrand_refused), " refused; the cycle counter, ", u64(report.jitter_samples), " samples, ", u64(report.jitter_distinct), " distinct low bytes")
}

// replacement_table_create makes the replacement table of the machine,
// which this service writes and each program reads.
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
// of the PS/2 controller. It gives the input ring, which the compositor
// receives too.
input_start :: proc "contextless" () -> (input_memory: system.Handle) {
	status: system.Status
	input_memory, _, status = system.ring_create()
	if status != .Ok {
		fail("cannot create a ring", status)
	}
	device :: proc "contextless" (kind: op.Device_Kind, a, b: u64) -> system.Handle {
		results, status := system.call(.Device_Create, u64(machine), u64(kind), a, b)
		if status != .Ok {
			fail("cannot create a device handle", status)
		}
		return system.Handle(results[0])
	}
	// The devices: this service closes its handles after the start.
	devices := [3]system.Handle{device(.Ports, 0x60, 5), device(.Interrupt, 1, 0), device(.Interrupt, 12, 0)}
	context_grants: system.Context_Grants
	system.grant_put(&context_grants, INPUT_GRANT_RING, {input_memory, {.Read, .Write}})
	system.grant_put(&context_grants, INPUT_GRANT_PORTS, {devices[0], {}})
	system.grant_put(&context_grants, INPUT_GRANT_KEYBOARD_INTERRUPT, {devices[1], {.Read}})
	system.grant_put(&context_grants, INPUT_GRANT_MOUSE_INTERRUPT, {devices[2], {.Read}})
	system.grant_put(&context_grants, op.CONTEXT_LOG, log_grant(role_of("input")))
	// The settings page, read-only: the input service reads the layout of
	// the keyboard there at each key.
	// With no settings page, no mapping and no bit of its range: the input
	// service reads nothing at the range.
	input_values: system.Context_Values
	settings_mapping := [1]system.Mapping{{memory = settings_memory, address = settings.PAGE_ADDRESS, first = 0, page_count = 1}}
	input_mappings: []system.Mapping
	if settings_page != nil {
		input_mappings = settings_mapping[:]
		system.range_mapped_put(&input_values, .Settings_Page)
	}
	if context_refused("input", &context_grants, &input_values) {
		fail("cannot start input", .Bad_State)
	}
	_, status = system.program_start(system.image_find(image, "input"), "input", context_grants.grants, random.values_with_seed(&program_generator, input_values.values), budget_of(system.image_find(image, "input"), "input"), input_mappings, &prepared)
	if status != .Ok {
		fail("cannot start input", status)
	}
	for handle in devices {
		system.close(handle)
	}
	return input_memory
}

// compositor_start starts the compositor with the framebuffer, the input
// ring and its control ring from this service. It takes the first place of
// the table of the programs: a connection to it finds it there by its name.
compositor_start :: proc "contextless" (ctx: ^system.Context, input_memory: system.Handle) {
	status: system.Status
	control_memory, control, status = system.ring_create()
	if status != .Ok {
		fail("cannot create a ring", status)
	}
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
	pages_memory, display_registers := display_open(framebuffer_address, ctx.values[op.ROOT_VALUE_WIDTH], ctx.values[op.ROOT_VALUE_HEIGHT], ctx.values[op.ROOT_VALUE_PIXELS_PER_LINE])
	defer if pages_memory != 0 {
		system.close(pages_memory) // The compositor holds its own handle.
	}
	if pages_memory != 0 {
		system.grant_put(&context_grants, COMPOSITOR_GRANT_FRAMEBUFFER, {pages_memory, {.Read, .Write}})
		system.grant_put(&context_grants, COMPOSITOR_GRANT_DISPLAY_REGISTERS, {display_registers, {.Read, .Write}})
	} else {
		system.grant_put(&context_grants, COMPOSITOR_GRANT_FRAMEBUFFER, {ctx.handles[op.ROOT_FRAMEBUFFER], {.Read, .Write}})
	}
	system.grant_put(&context_grants, COMPOSITOR_GRANT_INPUT, {input_memory, {.Read, .Write}})
	system.grant_put(&context_grants, COMPOSITOR_GRANT_CONTROL, {control_memory, {.Read, .Write}})
	role := role_of("compositor")
	system.grant_put(&context_grants, op.CONTEXT_LOG, log_grant(role))
	values: system.Context_Values
	system.value_put(&values, COMPOSITOR_VALUE_WIDTH, ctx.values[op.ROOT_VALUE_WIDTH])
	system.value_put(&values, COMPOSITOR_VALUE_HEIGHT, ctx.values[op.ROOT_VALUE_HEIGHT])
	system.value_put(&values, COMPOSITOR_VALUE_PIXELS_PER_LINE, ctx.values[op.ROOT_VALUE_PIXELS_PER_LINE])
	system.value_put(&values, COMPOSITOR_VALUE_FORMAT, ctx.values[op.ROOT_VALUE_FORMAT])
	// The compositor is also a service (src/modules/system/compositor/exports.odin):
	// a service ring and its own file, as start() gives to a service. Its
	// values 0 to 3 are the screen, so the file is at values 4 and 5.
	// The file, two pointer themes, the settings page, five glyph caches,
	// the font outlines, the demand cache, the date page, the fresh bytes
	// page.
	mappings: [14]system.Mapping
	mapping_count := 0
	served := &started[0]
	served^ = {}
	for &item in system.image_entries(image) {
		if system.name_of(item.name[:]) == "compositor" && item.offset % system.PAGE_SIZE == 0 && item.offset <= u64(len(image)) && item.size <= u64(len(image)) - item.offset {
			served.service_memory, served.service, status = system.ring_create()
			if status != .Ok {
				fail("cannot create a ring", status)
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
		if mapping, size, given := resource_mapping(name, address, "compositor"); given {
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
	if context_refused("compositor", &context_grants, &values) {
		fail("cannot start the compositor", .Bad_State)
	}
	// The compositor imports the drawing module: its load needs the boot
	// image as the source of its imports.
	compositor_load_error: module.Load_Error
	compositor, status = system.program_start(system.image_find(image, "compositor"), "compositor", context_grants.grants, random.values_with_seed(&program_generator, values.values), budget_of(system.image_find(image, "compositor"), "compositor"), mappings[:mapping_count], &prepared, load_source(), &compositor_load_error)
	if status != .Ok {
		if compositor_load_error.stage != .None {
			buffer: [512]u8
			writer := system.Writer{buffer = buffer[:]}
			system.load_error_text(&writer, &compositor_load_error)
			system.log_in("programs", .Error, "root: cannot load the compositor: ", system.written(&writer))
		}
		fail("cannot start the compositor", status)
	}
	served.program = compositor
	served.role = role
	copy(served.name[:len(served.name) - 1], "compositor")
}

// programs_of_the_boot_start starts the programs of the boot, in their
// order, then writes the measure of the free pages.
programs_of_the_boot_start :: proc "contextless" () {
	// The entropy device, after the compositor: the compositor takes the
	// first place of the table of the programs. The loop mixes its bytes
	// when they come (entropy.odin).
	entropy_service_start()
	// The font service draws the fixed subsets into the demand cache, which
	// each program with a surface maps; a program that draws before it ends
	// draws the same glyphs itself (font_service.odin).
	font_service_start()
	// The date: the program `date` reads the real-time clock. The programs
	// that start before it writes the page read no date until then.
	if status := start("date"); status != .Ok {
		system.log_in("programs", .Warning, "root: cannot start date: the system has no date")
	}
	if status := start("console"); status != .Ok {
		fail("cannot start the console", status)
	}
	// The settings that were kept (text_settings.odin).
	settings_boot_pass_start()
	// The TPM service, when the system is measured into a TPM: `unlock`
	// unseals the machine key with it (tpm.odin).
	tpm_service_start()
	// The named principal, if one was created: `unlock` reads its file and
	// asks for the passphrase; with no file it stops (principals.odin).
	unlock_start(.Unlock, "")
	// A measure, not a check: the pages that this service can still give,
	// now and at the lowest count that it read since its start. This
	// service holds the budget of the free memory of the machine, and each
	// program that it starts takes its budget from it.
	budget_pages_note()
	system.log("root: the start is done: the budget of this service holds ", budget_pages_now, " free pages, ", budget_pages_lowest, " at the lowest")
}

// root_loop_pass is one pass of the loop of this service: the control ring
// of the compositor, the root ring of each program, the answers of the
// services that it waits for, the reap of the programs that stopped, then
// one wait for the next event or deadline.
root_loop_pass :: proc "contextless" () {
	// The stop of a program is an event.
	wait := system.wait_begin()
	control_ring_serve()
	for &item in started {
		if item.program != 0 && item.requests.head != nil {
			root_ring_serve(&item)
		}
	}
	// Before reap: an entropy service that answered and stopped still has
	// its answers in the ring.
	entropy_answers(&wait)
	reap()
	// After reap: a principal that is locked has a window of unlock.
	unlock_for_a_locked_principal()
	// After reap: a storage service that stopped ended its connections.
	disk_load_step(&wait)
	persisted_tables_step(&wait)
	network_answers(&wait)
	system.wait_records(&wait, &control.completions)
	for &item in started {
		if item.program != 0 && item.requests.head != nil {
			system.wait_records(&wait, &item.requests.commands)
		}
	}
	// The appearance in force at an edge of the rule of the day
	// (appearance_edge.odin): one more deadline, and the change count of
	// the date page.
	appearance_step(&wait)
	// A load from the disk and a call for the disk grant table have a
	// deadline: the wait ends there, with or without an answer of the
	// storage service. The next read of the fresh bytes has one too
	// (entropy.odin).
	system.wait_end(&wait, min(disk_load_deadline(), persisted_tables_deadline(), appearance_deadline, fresh_bytes_deadline))
}

// control_ring_serve answers the control ring of the compositor: a start
// or a stop from the desktop.
control_ring_serve :: proc "contextless" () {
	for record in system.receive(&control.completions) {
		control_word, known := enum_word.member_of_word(display.Control, u64(record.kind))
		if !known {
			system.log_in("programs", .Warning, "root: refused a record of the compositor of the kind ", u64(record.kind), ", which names no control")
			continue
		}
		switch control_word {
		case .None, .Client_Add, .Client_Remove, .Palette_Provider_Add, .Palette_Provider_Remove:
			// This service sends these to the compositor, and takes none
			// from it.
			system.log_in("programs", .Warning, "root: refused a record of the compositor of the kind ", u64(record.kind), ", which this service sends and does not take")
		case .Start:
			// The desktop starts a program in the session that runs.
			name := system.name_unpack({record.values[0], record.values[1], record.values[2], record.values[3]})
			start(system.name_of(name[:]), desktop_principal())
		case .Stop:
			for &item in started {
				if item.program != 0 && item.client == system.Handle(record.values[0]) {
					// A close of the window of unlock is a stop that this
					// service asked: it does not count toward the bound of
					// its restarts.
					if !item.is_terminal && system.name_of(item.name[:]) == "unlock" {
						unlock_stop_ask()
					}
					system.call(.Program_Stop, u64(item.program), 0)
				}
			}
		}
	}
}

// The pages that the budget of this service can still pay: at the last
// read, and the lowest count of each read. A read comes after each start
// of a program, when the budget of the program left this budget.
budget_pages_now: u64
budget_pages_lowest: u64 = max(u64)

budget_pages_note :: proc "contextless" () {
	if own, status := system.budget_read(); status == .Ok {
		budget_pages_now = own.pages
		budget_pages_lowest = min(budget_pages_lowest, own.pages)
	}
}

// started_log writes the line of a start, with the session of a named
// principal: "root: started notes, in the session of principal 1 \"alice\"".
started_log :: proc "contextless" (name: string, principal: u64, terminal: string) {
	budget_pages_note()
	if principal == principals.MACHINE {
		system.log_in("programs", .Info, "root: started ", system.Module_Name{name}, terminal)
	} else {
		system.log_in("programs", .Info, "root: started ", system.Module_Name{name}, terminal, ", in the session of principal ", principal, " \"", principal_name(principal), "\"")
	}
}

// find gives the program with a name that this service started. A terminal
// has the name of no program.
find :: proc "contextless" (name: string) -> ^Started {
	for &item in started {
		if item.program != 0 && !item.is_terminal && system.name_of(item.name[:]) == name {
			return &item
		}
	}
	return nil
}

// grants_held gives the grants of the start of a program that it still
// holds: a grant that was revoked from it is not a grant that it holds.
// The revocation names a grant of system.Root_Grant; the machine is one
// handle, so its revocation ends each right of the machine.
grants_held :: proc "contextless" (item: ^Started) -> bit_set[Grant] {
	held := item.role.grants
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

// debug_refusing_grant says if a grant of a program refuses the debug
// access to it for a caller, and which one. A debugger acts with each
// handle of the program that it debugs, and reads each byte of it: the
// right Debug on a program is each grant of that program. So the rule is
// one comparison of two sets of grants, with no name of a program in it:
//
// - each grant that this service gave the program at its start
//   (Started.role) is a grant that the caller holds itself and that was not
//   revoked from it (grants_held): the caller then gains nothing that this
//   service did not give it;
// - a grant refuses the debug access for each caller when what it reaches
//   belongs to that one program (GRANTS_OF_ONE_PROGRAM): the same grant of
//   the caller reaches another thing, so two holders of the grant do not
//   hold the same thing.
//
// What follows, with no list: a program with no grant can be debugged, and
// a program whose grants reach only what the caller reaches by the same
// grants (the machine, the boot image); a service, a device service, the
// compositor, a terminal, and a program with a private store, an endpoint
// of the network, a terminal or a device cannot.
// The rule reads the state of the program that runs, so it holds for a
// program that came from a disk as for one of the boot image.
//
// A window is not a grant: each program with no terminal has one. The
// debugger of a program draws in its window and reads the input that the
// compositor sends to it.
debug_refusing_grant :: proc "contextless" (caller: ^Started, target: ^Started) -> (grant: Grant, refuses: bool) {
	held := grants_held(caller)
	for candidate in Grant {
		if candidate in target.role.grants && (candidate in GRANTS_OF_ONE_PROGRAM || candidate not_in held) {
			return candidate, true
		}
	}
	return .Root_Ring, false
}

// The grants that refuse the debug access for each caller: what the grant
// reaches belongs to the one program that holds it, so two holders of the
// grant do not hold the same thing.
// - Serve: a service holds what its callers lent it and what it keeps for
//   them;
// - Terminal: a terminal of its own, with the keys typed in it;
// - Store, History_Store: a store of its own. A caller that acts for the
//   principal reads each store of that principal, and writes only its own:
//   through the registers of the program, a debugger would write the store
//   of the program;
// - Data_Disk, Scratch_Disk, Network_Device: a device service that this
//   service started for the program alone, and its ring;
// - Network: an endpoint names its own remote and its own ports;
// - Connect: the services that a program can connect to are its own list;
// - Principals: a ring of its own, and the records of the principals;
// - Tpm: the ring and the region of the TPM service, which hold the
//   machine key during a request;
// - Debugger: a ring of its own, and the debuggings of its callers;
// - System_Part: handles that no other grant names;
// - Versions_Erase: the versions of the objects of its own store;
// - Remote_Clients: a connection for a row of the client table acts for the
//   principal of that row, which is not the principal of the caller.
// Each other grant reaches one thing that each of its holders reaches: the
// machine by its rights, the boot image, the debug image, the replacement
// table, the settings page, the date page, the records of the log, the
// commands of the root ring.
GRANTS_OF_ONE_PROGRAM :: bit_set[Grant]{.Serve, .Terminal, .Store, .History_Store, .Data_Disk, .Scratch_Disk, .Network_Device, .Network, .Connect, .Principals, .Tpm, .Debugger, .System_Part, .Versions_Erase, .Remote_Clients}

// debug gives the debugger service the handle of the program with a name,
// with the right Debug and no other, on behalf of one of its callers:
// debug access is a handle to one program, and the principal grants it.
// `holder` is the debugger service, which sent the command;
// `connection_ring` is the call ring of one of its connections, as the
// service names it: this service made that connection, so it knows the
// caller, and the service cannot name a program that is not one of its
// callers. values is the completion of Root_Command.Debug: the handle,
// then the hash of the file of the program, then its principal. A refusal
// writes its error record there.
//
// The rule is applied to the caller, not to the service:
//
// - the caller acts for the principal whose session runs the program: the
//   grant Acts_For_Principal, not revoked, and the same principal. So a
//   program of the machine does not debug a program of a named principal,
//   and a program of one principal does not debug a program of another;
// - no grant of the program refuses (debug_refusing_grant).
//
// This service records the grant of the caller (`debug` in Grants) and can
// revoke it: the kernel then ends the handle, and the debugging with it.
// The handle also ends when the connection of the caller to the service
// ends, and when the caller stops.
//
// With `end`, the service says that it ended the debugging of the program
// for that caller: this service forgets the debug access (debug_end).
//
// Bad_Handle: the ring names no connection of the service, or no program
// has the name. Bad_State: a grant of the program refuses, the program is
// the caller or the service, or another caller debugs it. Bad_Operation:
// the caller does not act for the principal of the program. No_Right: the
// grant `debug` was revoked from the caller.
debug :: proc "contextless" (holder: ^Started, name: string, connection_ring: u64, end: bool, values: ^[7]u64) -> system.Status {
	kind := u32(root_ring.Root_Command.Debug)
	caller: ^Started
	// The principal that the caller acts for through this connection: a
	// connection of `remote` for a row of the client table acts for the
	// principal of the row, not for the session of `remote`.
	caller_principal: u64
	caller_row: int
	for &connection in connections {
		if connection.caller != nil && connection.service == holder && !connection.history && u64(connection.ring) == connection_ring {
			caller = connection.caller
			caller_principal = connection_principal(&connection)
			caller_row = connection.client.place
		}
	}
	if caller == nil {
		values^ = errors.ring_fail(kind, .Absent, .Connections, 2)
		return .Bad_Handle
	}
	target := find(name)
	if target == nil {
		values^ = errors.ring_fail(kind, .Absent, .Programs, 1)
		return .Bad_Handle
	}
	// The service ended the debugging of the program for this caller: this
	// service forgets the debug access, and another caller can ask for it.
	if end {
		if target.debugger != holder || target.debug_for != caller || target.debug_for_row != caller_row {
			values^ = errors.ring_fail(kind, .Absent, .Debugged_Programs, 1)
			return .Bad_State
		}
		values[0] = debug_end(target)
		system.log_in("programs", .Info, "root: ", system.Module_Name{system.name_of(holder.name[:])}, " ended the debugging of ", system.Module_Name{name}, " for ", system.Module_Name{system.name_of(caller.name[:])})
		return .Ok
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
		system.log_in("programs", .Info, "root: refused ", system.Module_Name{system.name_of(caller.name[:])}, " the debug access to ", system.Module_Name{name}, ": the grant ", start_grant.GRANT_NAMES[grant], " of the program refuses it")
		return .Bad_State
	}
	// One debugger for one program: the kernel has the same rule.
	if target.debugger != nil && (target.debugger != holder || target.debug_for != caller || target.debug_for_row != caller_row) {
		values^ = errors.ring_fail(kind, .Full, .Debugged_Programs, 1, 0, 1)
		return .Bad_State
	}
	given, status := system.give(holder.requests_memory, target.program, {.Debug})
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
	system.log_in("programs", .Info, "root: gave ", system.Module_Name{system.name_of(holder.name[:])}, " the right to debug ", system.Module_Name{name}, " for ", system.Module_Name{system.name_of(caller.name[:])}, ", for principal ", caller_principal)
	return .Ok
}

// debug_end ends the debug access to one program: the handle that the
// debugger service received ends there, and the kernel ends the debugging
// of the program with its last handle. The caller keeps the grant `debug`
// only while the service debugs another program for it. It gives the count
// of the holdings that ended.
debug_end :: proc "contextless" (target: ^Started) -> (count: u64) {
	holder, caller := target.debugger, target.debug_for
	target.debugger, target.debug_for, target.debug_for_row = nil, nil, 0
	// The connection to the store of the debug object is a part of the
	// debug access, and ends with it.
	debug_store_end(target)
	if holder != nil && holder.program != 0 && target.program != 0 {
		count, _ = system.handle_revoke(target.program, holder.program)
	}
	if caller == nil {
		return count
	}
	for &other in started {
		if other.program != 0 && other.debug_for == caller {
			return count
		}
	}
	caller.granted -= {.Debug}
	return count
}

// revoke ends one grant of a program that runs: access is never given for
// ever, and each grant can be revoked. Each grant
// here is a handle that this service keeps: the handle of the program came
// from it, and the kernel ends what came from it in that program
// (Handle_Revoke). What the program gave to other programs ends too.
// values is the completion of Root_Command.Revoke.
revoke :: proc "contextless" (name: string, grant: u64, values: ^[7]u64) -> system.Status {
	status := revoke_grant(name, grant, values)
	if status == .Ok {
		if item := find(name); item != nil {
			debug_check_again(item)
		}
	}
	return status
}

// debug_check_again ends each debugging that runs for a caller and that
// the rule no longer gives it, after a grant of the caller was revoked: a
// grant that the caller lost must not stay in its hands through the
// registers of a program that holds it. The program is given back as on a
// detach: the kernel resumes each thread that the debugger held. The end
// needs nothing of the caller, so a caller that lost the grant to act for
// the principal leaves no thread stopped.
debug_check_again :: proc "contextless" (caller: ^Started) {
	for &other in started {
		if other.program == 0 || other.debug_for != caller {
			continue
		}
		_, refuses := debug_refusing_grant(caller, &other)
		if refuses || .Acts_For_Principal not_in grants_held(caller) {
			debug_end(&other)
			system.log_in("programs", .Info, "root: ended the debugging of ", system.Module_Name{system.name_of(other.name[:])}, " for ", system.Module_Name{system.name_of(caller.name[:])}, ": the rule no longer gives the debug access, after a revocation")
		}
	}
}

// revoke_grant is revoke, before the check of the debuggings of the
// program.
revoke_grant :: proc "contextless" (name: string, grant: u64, values: ^[7]u64) -> system.Status {
	item := find(name)
	if item == nil {
		return .Bad_Handle
	}
	which, known := enum_word.member_of_word(system.Root_Grant, grant)
	if !known {
		return .Bad_Operation
	}
	if which not_in item.granted {
		return .Bad_State
	}
	handle: system.Handle
	switch which {
	case .Store:
		// The store is data of the storage service: the root service tells it
		// on its service ring that the grant of each connection changed.
		count: u64
		for &connection in connections {
			if connection.caller != item || connection.history || system.name_of(connection.service.name[:]) != "storage" {
				continue
			}
			// The amount ends, and the grant to erase versions with it, as it
			// is a right over the store; the principal and the flag to act for
			// it stay.
			kept := grant_for(item, connection.service) &~ (isolated.CALLER_AMOUNT_MASK | isolated.CALLER_ERASES_VERSIONS)
			if !system.send(&connection.service.service.commands, ring.Record{kind = u32(isolated.Service_Command.Grant), values = {0 = u64(connection.ring), 6 = kept}}) {
				return .No_Slot
			}
			count += 1
		}
		item.granted -= {which}
		item.revoked += {which}
		values[0] = count
		system.log_in("programs", .Info, "root: revoked the grant store of ", system.Module_Name{name}, ", connections changed: ", count)
		return .Ok
	case .Acts_For_Principal:
		// The grant is data of each service that the program is connected
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
			system.log_in("programs", .Warning, "root: refused the revocation of acts_for_principal of ", system.Module_Name{name}, ": the service ", system.Module_Name{system.name_of(service.name[:])}, " has no room for the new grants; nothing changed")
			return .No_Slot
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
		system.log_in("programs", .Info, "root: revoked the grant acts_for_principal of ", system.Module_Name{name}, ", connections changed: ", count)
		return .Ok
	case .History:
		// The store of the history is data of the storage service, as the
		// private store: the storage service ends the grant of the
		// connection, and the program keeps its history in its memory only.
		item.granted -= {which}
		item.revoked += {which}
		count: u64
		for &connection in connections {
			if connection.caller != item || !connection.history {
				continue
			}
			if !system.send(&connection.service.service.commands, ring.Record{kind = u32(isolated.Service_Command.Grant), values = {0 = u64(connection.ring), 6 = isolated.caller_grant_make(0, item.principal, false)}}) {
				return .No_Slot
			}
			count += 1
		}
		values[0] = count
		system.log_in("programs", .Info, "root: revoked the grant history of ", system.Module_Name{name}, ", connections changed: ", count)
		return .Ok
	case .Network:
		// The endpoint is data of the network service, as a store is data of
		// the storage service: the network service ends the grant.
		count := endpoint_revoke(item)
		item.granted -= {which}
		item.revoked += {which}
		values[0] = count
		system.log_in("programs", .Info, "root: revoked the grant network of ", system.Module_Name{name}, ", endpoints changed: ", count)
		return .Ok
	case .Debug:
		// One handle for each program that the command Debug named for
		// this caller: each one ends in the debugger service, and the
		// kernel ends the debugging of that program with its last handle.
		count: u64
		for &other in started {
			if other.program == 0 || other.debug_for != item {
				continue
			}
			count += debug_end(&other)
		}
		item.granted -= {which}
		item.revoked += {which}
		values[0] = count
		system.log_in("programs", .Info, "root: revoked the grant debug of ", system.Module_Name{name}, ", holdings ended: ", count)
		return .Ok
	case .Palette:
		// The table and the ring end in the program, and the compositor
		// unmaps its side: the palette keeps the programs and the windows.
		count := palette_provider_end(item, true)
		item.granted -= {which}
		item.revoked += {which}
		values[0] = count
		system.log_in("programs", .Info, "root: revoked the grant palette of ", system.Module_Name{name}, ", holdings ended: ", count)
		return .Ok
	case .Log:
		handle = system.context_record().handles[op.CONTEXT_LOG]
	case .Machine:
		handle = machine
	case .Image:
		handle = image_memory
	case .Log_Records:
		handle = system.context_record().handles[op.ROOT_LOG_RECORDS]
	}
	count := system.handle_revoke(handle, item.program) or_return
	item.granted -= {which}
	item.revoked += {which}
	values[0] = count
	system.log_in("programs", .Info, "root: revoked the grant ", system.root_grant_names[which], " of ", system.Module_Name{name}, ", holdings ended: ", count)
	return .Ok
}

// The palette provider (docs/CONSOLE.md, "8. The palette provider"): the one
// program that gives the palette of the desktop entries of its own. This
// service keeps a handle of the entry table and of the ring, so that a
// revocation ends what the provider holds of them.
palette_provider: ^Started // nil: no provider.
palette_table_memory, palette_ring_memory: system.Handle
palette_table_in_compositor, palette_ring_in_compositor: system.Handle

// palette_provide makes a program with the grant Palette the palette
// provider: a new entry table and a new ring, which the program and the
// compositor receive. The program gets the table with Write; the
// compositor gets it with Read only, and learns of both on its control
// ring. values is the completion of Root_Command.Palette_Provide.
palette_provide :: proc "contextless" (caller: ^Started, values: ^[7]u64) -> system.Status {
	if .Palette not_in caller.role.grants || .Palette in caller.revoked {
		return .No_Right
	}
	if palette_provider != nil {
		return .Bad_State
	}
	status: system.Status
	palette_table_memory, status = system.memory_create(palette_table.TABLE_PAGES)
	if status != .Ok {
		return status
	}
	palette_ring_memory, status = system.memory_create(ring.PAGE_COUNT)
	given_table, given_ring: system.Handle
	if status == .Ok {
		palette_table_in_compositor, status = system.give(compositor, palette_table_memory, {.Read})
	}
	if status == .Ok {
		palette_ring_in_compositor, status = system.give(compositor, palette_ring_memory, {.Read, .Write})
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
	system.send(&control.commands, ring.Record{kind = u32(display.Control.Palette_Provider_Add), values = {0 = u64(palette_ring_in_compositor), 1 = u64(palette_table_in_compositor)}})
	system.log_in("programs", .Info, "root: ", system.Module_Name{system.name_of(caller.name[:])}, " is the palette provider")
	return .Ok
}

// palette_provider_end ends the palette provider: the compositor unmaps
// the table and the ring. With revoke, each handle and each mapping of
// the two objects ends in the program, which runs on; without, the program
// stopped. It gives the count of the holdings that ended.
palette_provider_end :: proc "contextless" (item: ^Started, revoke: bool) -> (count: u64) {
	if palette_provider != item {
		return 0
	}
	if revoke {
		for handle in ([2]system.Handle{palette_table_memory, palette_ring_memory}) {
			ended, _ := system.handle_revoke(handle, item.program)
			count += ended
		}
	}
	system.send(&control.commands, ring.Record{kind = u32(display.Control.Palette_Provider_Remove), values = {0 = u64(palette_ring_in_compositor), 1 = u64(palette_table_in_compositor)}})
	system.close(palette_table_memory)
	system.close(palette_ring_memory)
	palette_provider = nil
	palette_table_memory, palette_ring_memory = 0, 0
	system.log_in("programs", .Info, "root: no palette provider")
	return count
}

// terminal_start starts the terminal of a program that runs. The terminal
// receives a surface, the terminal ring, the text region with the right
// Read, and a handle that reads the state of the program. It receives
// nothing of the role of the program.
terminal_start :: proc "contextless" (view: ^Started, writer: ^Started, ring_memory, text_memory: system.Handle) -> system.Status {
	view^ = {}
	display_memory := system.memory_create(ring.PAGE_COUNT) or_return
	defer system.close(display_memory)
	client := system.give(compositor, display_memory, {.Read, .Write}) or_return
	system.send(&control.commands, ring.Record{kind = u32(display.Control.Client_Add), values = {0 = u64(client)}})

	// The slots of a terminal are its own: the terminal has no other role.
	role := role_of("terminal")
	context_grants: system.Context_Grants
	values: system.Context_Values
	columns, rows, measure := role_terminal(&writer.role)
	handles := terminal.Terminal_Handles{display = display_memory, ring = ring_memory, text = text_memory, writer = writer.program, log = log_grant(role)}
	terminal.context_of(&context_grants, &values, handles, system.name_pack(system.name_of(writer.name[:])), columns, rows, measure)
	// The settings page, five glyph caches, the font outlines and the
	// demand cache.
	mappings: [8]system.Mapping
	mapping_count := 0
	text_settings_give(mappings[:], &mapping_count, &values)
	if context_refused("terminal", &context_grants, &values) {
		system.send(&control.commands, ring.Record{kind = u32(display.Control.Client_Remove), values = {0 = u64(client)}})
		return .Bad_State
	}
	// The terminal imports the drawing module: its load needs the boot
	// image as the source of its imports.
	load_error: module.Load_Error
	program, status := system.program_start(system.image_find(image, "terminal"), "terminal", context_grants.grants, random.values_with_seed(&program_generator, values.values), budget_of(system.image_find(image, "terminal"), "terminal"), mappings[:mapping_count], &prepared, load_source(), &load_error)
	if status != .Ok {
		if load_error.stage != .None {
			buffer: [512]u8
			writer := system.Writer{buffer = buffer[:]}
			system.load_error_text(&writer, &load_error)
			system.log_in("programs", .Warning, "root: cannot load the terminal: ", system.written(&writer))
		}
		system.send(&control.commands, ring.Record{kind = u32(display.Control.Client_Remove), values = {0 = u64(client)}})
		return status
	}
	view.program, view.client, view.writer, view.is_terminal = program, client, writer, true
	view.role = role
	view.principal = writer.principal // The lock stops the terminal of a program of the session with it.
	copy(view.name[:len(view.name) - 1], "terminal")
	return .Ok
}

// connect makes a connection from a caller to the service with a name: a
// new call ring and a new call region, that the two programs receive. This
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
	// The program handle of the service, with Read only and never Give: a
	// handle with Read and Give lends to log.program_records, and would give
	// each client the log records of the service
	// (src/md/features/log_reader_scope.md).
	given[0], status = system.give(caller.requests_memory, service.program, {.Read})
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
	hash := transmute([4]u64)service.hash
	values^ = {u64(given[0]), u64(given[1]), u64(given[2]), hash[0], hash[1], hash[2], hash[3]}
	// The principal of the connection, and whether the caller acts for it.
	acts := connection_grant(free) & isolated.CALLER_ACTS_FOR_PRINCIPAL != 0
	if history {
		system.log_in("calls", .Info, "root: connected ", system.Module_Name{system.name_of(caller.name[:])}, " to the store of its line history in the service ", system.Module_Name{name}, ", ", system.Size{HISTORY_STORE_LIMIT, .Blocks}, ", for principal ", caller.principal)
	} else if client.place != 0 {
		head: [16]u8
		system.log_in("calls", .Info, "root: connected ", system.Module_Name{system.name_of(caller.name[:])}, " to the service ", system.Module_Name{name}, acts ? ", acting for principal " : ", for principal ", client.principal, ", for the client key ", key_head_text(&head, client.key))
	} else {
		system.log_in("calls", .Info, "root: connected ", system.Module_Name{system.name_of(caller.name[:])}, " to the service ", system.Module_Name{name}, acts ? ", acting for principal " : ", for principal ", caller.principal)
	}
	return .Ok
}

// connection_open makes the service side of a connection from a caller to
// the service with a name, and starts the service if it starts on demand.
// It gives the call ring and the call region: give them to the caller,
// then close them.
connection_open :: proc "contextless" (caller: ^Started, name: string, history := false, client: Client_Grant = {}) -> (free: ^Connection, service: ^Started, ring_memory, region_memory: system.Handle, status: system.Status) {
	for pass in 0 ..< 2 {
		for &item in started {
			if item.program != 0 && item.service.head != nil && system.name_of(item.name[:]) == name {
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
	// named principal has its number after it (src/library/support/principals). Each
	// other service receives the name of the program. A name that does not
	// fit is refused before anything is made: a cut name can be the name of
	// another store.
	store_name: system.Name
	if system.name_of(service.name[:]) == "storage" {
		// The store of a disk program is the store of its nickname, with a
		// prefix that no module name has (disk_programs.odin).
		program_of_the_store := system.name_of(caller.name[:])
		disk_store_name: [32]u8
		if caller.from_disk {
			program_of_the_store = disk_program.store_program_name(&disk_store_name, program_of_the_store)
		}
		// A connection for a row of the client table belongs to the
		// principal of the row.
		principal_of_the_store := client.place != 0 ? client.principal : caller.principal
		if !principals.store_name_write(&store_name, program_of_the_store, principal_of_the_store, history) {
			system.log_in("calls", .Warning, "root: the name of the store of ", system.Module_Name{system.name_of(caller.name[:])}, " for principal ", caller.principal, " has more than 31 bytes: no connection")
			return nil, nil, 0, 0, .Bad_Operation
		}
	} else {
		copy(store_name[:len(store_name) - 1], system.name_of(caller.name[:]))
	}
	ring_memory = system.memory_create(ring.PAGE_COUNT) or_return
	region_memory, status = system.memory_create(isolated.REGION_PAGES)
	in_service_ring, in_service_region: system.Handle
	if status == .Ok {
		in_service_ring, status = system.give(service.service_memory, ring_memory, {.Read, .Write})
	}
	if status == .Ok {
		in_service_region, status = system.give(service.service_memory, region_memory, {.Read, .Write})
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
	// service, it names the program of the caller.
	if grant & isolated.CALLER_AMOUNT_MASK != 0 && system.name_of(service.name[:]) == "storage" {
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
// one Grant record for each connection of a program to it, with the room
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
	// connection: the service debugs a program only for a caller that can
	// still call it.
	if !connection.history {
		for &other in started {
			if other.program != 0 && other.debugger == connection.service && other.debug_for == connection.caller && other.debug_for_row == connection.client.place {
				debug_end(&other)
			}
		}
	}
	if connection.service.program != 0 {
		system.send(&connection.service.service.commands, ring.Record{kind = u32(isolated.Service_Command.Disconnect), values = {0 = u64(connection.ring), 1 = u64(connection.region)}})
	}
	system.log_in("calls", .Info, "root: disconnected ", system.Module_Name{system.name_of(connection.caller.name[:])}, " from the service ", system.Module_Name{system.name_of(connection.service.name[:])})
	// The connection of this service for a load from the disk: the load
	// learns here that it ended.
	if disk_load.connection == connection {
		disk_load.connection = nil
	}
	persisted_table_connection_ended(connection)
	if debug_store.connection == connection {
		debug_store = {}
	}
	connection^ = {}
}

// release frees what this service holds for a program, and tells the compositor.
release :: proc "contextless" (item: ^Started) {
	// The row goes before the handle closes: the kernel can then give the
	// slot to another program, which the row must not name.
	disk_program_page_remove(item)
	// The connections of the program end: those that it made, and those
	// that it served.
	served := item.service.head != nil
	// A terminal that stops: its program stops. A program that stops: its
	// terminal stays, and shows what the program wrote.
	if item.writer != nil && item.writer.program != 0 {
		system.call(.Program_Stop, u64(item.writer.program), 0)
	}
	// A debugged program that stops, a debugger service that stops, and a
	// caller of the debugger service that stops: the debug access ends.
	if item.debugger != nil {
		debug_end(item)
	}
	for &other in started {
		if other.program != 0 && (other.debugger == item || other.debug_for == item) {
			debug_end(&other)
		}
		if other.writer == item {
			other.writer = nil
		}
		if other.driver == item {
			other.driver = nil
		}
	}
	// The connection for a kept stop report ends with its caller and with
	// the debugger service.
	debug_store_release(item)
	// A client that stops: its block service stops. A block service that
	// stops: the device stops using memory.
	if item.driver != nil && item.driver.program != 0 {
		system.call(.Program_Stop, u64(item.driver.program), 0)
	}
	if item.is_driver {
		driver_end(item)
	}
	tpm_service_end(item)
	entropy_service_end(item)
	fresh_bytes_forget(item)
	font_service_end(item)
	endpoint_close(item)
	disk_load_forget(item)
	principal_change_forget(item)
	if palette_provider == item {
		palette_provider_end(item, false)
	}
	if item.network.head != nil {
		network_end(item)
	}
	if item.program != 0 {
		system.close(item.program)
		item.program = 0
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
	if item.program != 0 {
		system.close(item.program)
	}
	item^ = {}
}

// reap finds the programs that stopped.
reap :: proc "contextless" () {
	for &item in started {
		if item.program == 0 {
			continue
		}
		state, code := system.program_state(item.program)
		if state == .Stopped {
			system.log_in("programs", code == 0 ? .Info : .Warning, "root: ", system.Module_Name{system.name_of(item.name[:])}, " stopped with code ", u64(code))
			// The kernel forgets the stop report with the last handle,
			// which release closes: a disk program keeps it here.
			stop_report_keep(&item)
			if !item.is_terminal && system.name_of(item.name[:]) == "unlock" {
				unlock_stopped()
			}
			release(&item)
		}
	}
}
