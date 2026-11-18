package root

import "modus:support/disk_program"
import terminal "modus:support/terminal"

// The role of a program of the boot image: what this service gives it at
// its start, by its name. role_of reads it one time, at the start; the
// program keeps it in Started.role, and each rule after the start reads it
// there and never by the name of the program. A disk program has a
// nickname that it chose: its role comes from the disk grant table of its
// principal, never from this table (disk_programs.odin).
//
// The role of each program is one row of the table `program_roles`: its
// start grants and the other terms of its role. The site reads the table
// for its table "The grants of each program", and the tool stops each build
// when a program of the boot image has no row (program_roles_check.odin).
Program_Role :: struct {
	grants:      bit_set[Grant],
	using terms: Program_Role_Terms,
}

// The services that a program with the grant Connect and not Root_Ring can
// connect to: the list of its row, an empty text after the last one.
CALLABLE_LIMIT :: 9

// The parts of a role that are not start grants. Zero is the role of a
// program that needs none of them.
Program_Role_Terms :: struct {
	callable:         [CALLABLE_LIMIT]string, // With the grant Connect: the services that it can connect to.
	store_blocks:     u64, // With the grant Store: the blocks of its private store. 0: STORE_BLOCKS_DEFAULT.
	log_gives:        bool, // The log with the right Give: it gives the log to the programs that it starts.
	terminal_columns: u64, // With the grant Terminal: the columns of its terminal. 0: TERMINAL_COLUMNS_DEFAULT.
	terminal_rows:    u64, // 0: TERMINAL_ROWS_DEFAULT.
	terminal_measure: bool, // Its terminal shows the rates of the program.
	on_demand:        bool, // A service that starts at the first connection to it.
}

STORE_BLOCKS_DEFAULT :: 64
TERMINAL_COLUMNS_DEFAULT :: 96
TERMINAL_ROWS_DEFAULT :: 26

// A row of the table: the whole role of one program, by its name.
Program_Role_Row :: struct {
	name:   string,
	grants: bit_set[Grant],
	terms:  Program_Role_Terms,
}

// The role of each program of the boot image, with the reason of each
// grant and each term. The table is whole: the tool refuses a build where a
// program of the boot image has no row, or a row names no module of it, so
// a new program never starts with a role that nobody wrote. The form of a
// row is the form that the site reads: a record literal with no type, its
// name a string, its grants a set of members, its terms a record, and the
// reason in the comment lines above it.
//
// The rows come in three groups: the programs with grants; the parts of
// the system that this service starts itself (the grant System_Part, and
// the names of system_part_names), each with handles that no other grant
// names, which a command Start does not start; and the programs whose role
// holds no grant: the log and a window, or the handles of the program that
// starts them.
@(rodata)
program_roles := [?]Program_Role_Row {
	// The console is the shell of the machine, and its commands need
	// each grant:
	// - **Root_Ring**: `start`, `stop`, `grants`, `revoke`, `connect`
	//   and the commands of the principals ask this service.
	// - **Inspect**: `memory`, `locks` and `program_modules` read the
	//   reports of the machine.
	// - **Stop**: `shutdown` stops the machine.
	// - **Image**: `load` and `isolate` map the modules of the boot image.
	// - **Debug_Image**: a stop report names the procedures and the
	//   source lines.
	// - **Replacements** and **Replace**: `replacements` reads the
	//   replacement table, `replace` changes it.
	// - **Terminal**: the console has no surface of its own.
	// - **Store**: `connect storage` opens its private store, with a
	//   small limit of blocks that a test reaches.
	// - **History_Store**: the line history, apart from that store.
	// - **Acts_For_Principal**: a service that it connects to shows what
	//   it holds for all callers.
	// - **Palette**: its commands show in the palette of the desktop,
	//   and the palette names the one that the input chose.
	// It gives the log to the programs that it starts, which write on it.
	{name = "console", grants = {.Root_Ring, .Inspect, .Stop, .Image, .Terminal, .Store, .Acts_For_Principal, .Replacements, .Replace, .History_Store, .Debug_Image, .Palette}, terms = {store_blocks = 3, log_gives = true}},
	// It writes its lines to a terminal and reads the key Space from it:
	// it has no surface and needs nothing else. It shows the rates of the
	// program in a terminal as large as a terminal can be.
	{name = "flood", grants = {.Terminal}, terms = {terminal_columns = terminal.COLUMNS_LIMIT, terminal_rows = terminal.ROWS_LIMIT, terminal_measure = true}},
	// The test of the records of a terminal ring whose kind names no
	// record: it writes them to its terminal, as flood writes lines.
	{name = "hostile_terminal", grants = {.Terminal}},
	// A developer tool: it reads the reports of the machine and the names
	// of the modules, and serves the same facts (docs/TOOLS.md).
	{name = "inspect", grants = {.Inspect, .Image, .Serve, .Debug_Image}},
	// It serves programs() and counts() to a caller that acts for the
	// principal.
	{name = "monitor", grants = {.Inspect, .Serve}},
	// The debugger service (docs/TOOLS.md, "The debugger"):
	// - **Serve**: its exports are the commands of the debugger.
	// - **Debugger**: it asks this service for the handle of a program
	//   with the right Debug, on behalf of one of its callers, and, for
	//   a disk program that it debugs, for a connection that reads only
	//   to the store of its debug object (Debug_Store).
	// - **Inspect**: the threads and the module records of the program
	//   that it debugs.
	// - **Debug_Image**: the debug objects, which name the procedures,
	//   the lines, the types and the variables.
	// - **Image**: the name of each module, from its hash.
	// It starts at the first connection to it.
	{name = "debugger", grants = {.Serve, .Debugger, .Inspect, .Debug_Image, .Image}, terms = {on_demand = true}},
	// It shows what each processor runs.
	{name = "processors", grants = {.Inspect}},
	// It shows the page tables.
	{name = "pages", grants = {.Inspect}},
	// It reads the kernel entries of the program for its measures.
	{name = "flow", grants = {.Inspect}},
	// It reads the kernel entries of the program for its measures.
	{name = "crowd", grants = {.Inspect}},
	// It reads the kernel entries of the program for its measures.
	{name = "clock", grants = {.Inspect}},
	// It shows what the kernel refuses.
	{name = "rights", grants = {.Inspect, .Image}},
	// It reads the pointer themes in the resource table of the boot image.
	{name = "pointers", grants = {.Image}},
	// It serves records(): the whole log to a caller that acts for the
	// principal, its own records to each other caller.
	{name = "log", grants = {.Log_Records, .Serve}},
	// The test of the own records and of the records of its children: a
	// connection to the log service and to no other service, with no
	// grant to act for the principal, and the boot image for the
	// description of the exports of that service and for the module of
	// its children (src/md/features/log_reader_scope.md). It starts them on
	// its own budget, and the handle of each child is its grant to read the
	// records of that child; each child writes the records that its
	// starter reads back, one of them more than the whole log keeps
	// (src/md/features/own_log_ring.md).
	{name = "log_reader", grants = {.Connect, .Image}, terms = {callable = {0 = "log"}, log_gives = true}},
	// It shows the modules of the boot image.
	{name = "boot", grants = {.Inspect, .Image}},
	// It starts its nodes from the boot image, and its nodes write on the
	// log.
	{name = "rings", grants = {.Image}, terms = {log_gives = true}},
	// It reads its own page table, and starts its twins from the boot
	// image.
	{name = "frames", grants = {.Inspect, .Image}},
	// It reads the counts of the locks, and starts its lockers from the
	// boot image.
	{name = "locks", grants = {.Inspect, .Image}},
	// It reads its own mappings, and starts its child from the boot image.
	{name = "address_space", grants = {.Inspect, .Image}},
	// It starts its children from the boot image.
	{name = "return_fault", grants = {.Image}},
	// It starts its children from the boot image; the child that repairs
	// logs its own cases.
	{name = "fault_ring", grants = {.Image}, terms = {log_gives = true}},
	// It starts its children from the boot image, and is the debugger of
	// each one: no grant of this service gives it that. A child writes one
	// line from a buffer that its debugger watches.
	{name = "debugged", grants = {.Image}, terms = {log_gives = true}},
	// It gives the event table of the machine, and starts its children
	// from the boot image.
	{name = "kernel_events", grants = {.Events, .Image}},
	// It counts the events of the processor for its own loop
	// (docs/ARCHITECTURE.md, "The counters of a thread").
	{name = "counters", grants = {.Counters}},
	// It reads the counts of the scheduler, changes the strategy and
	// writes the weight of each thread (the share policy). It starts the
	// four programs of its case of the shares from the boot image, and
	// serves strategy_set(), share() and policy() to the console.
	{name = "scheduler", grants = {.Inspect, .Schedule, .Image, .Serve}},
	// A service: the console calls its exports through a connection.
	{name = "paint", grants = {.Serve}},
	// A service: the console calls its exports through a connection.
	{name = "life", grants = {.Serve}},
	// A service: the console calls its exports through a connection.
	{name = "tally", grants = {.Serve}},
	// The module of the tables, started as a program when a caller
	// connects.
	{name = "sample", grants = {.Serve}, terms = {on_demand = true}},
	// A service: the console calls its exports through a connection.
	{name = "heron", grants = {.Serve}},
	// It writes the settings, keeps them in its private store, and serves
	// set() and get().
	{name = "settings", grants = {.Settings, .Serve, .Store}},
	// It reads the real-time clock, writes the date page, and serves now().
	{name = "date", grants = {.Clock, .Serve}},
	// It reads the documentation of each module of the boot image, and the
	// module records of each program.
	{name = "manual", grants = {.Serve, .Image, .Replacements, .Inspect}},
	// It measures the block service on the disk of the measures, which
	// holds no data of a program: its writes destroy nothing.
	{name = "disk", grants = {.Scratch_Disk}},
	// The client of the test of the IOMMU: its device service on the disk
	// of the measures is the test device service iommu_device.
	{name = "iommu", grants = {.Scratch_Disk}},
	// It is the one client of the block service of the data disk, and it
	// serves a private store to each caller with the grant Store. It starts
	// at the first connection to it.
	{name = "storage", grants = {.Serve, .Data_Disk}, terms = {on_demand = true}},
	// Its note, its count and their versions live in its private store:
	// the versions of a run of 1000 commits of the count (4 blocks each),
	// then thinning at the limit.
	{name = "notes", grants = {.Store}, terms = {store_blocks = 4500}},
	// The records of the named principals in its private store, the
	// passphrase in its window, the commands of the principals, and the
	// ring of the TPM service, which seals the machine key to the measure
	// of the system (docs/PRINCIPALS.md). It erases the versions of the
	// file of a principal after a change of a secret, so an old secret
	// opens no version (docs/STORAGE.md, "4.8 The erase of versions").
	{name = "unlock", grants = {.Store, .Principals, .Tpm, .Versions_Erase}},
	// The test of the trees of a store: 100000 empty objects in 1110 trees,
	// about 9500 nodes, and room for the copies of a commit.
	{name = "hierarchy", grants = {.Store}, terms = {store_blocks = 12000}},
	// The test of the large objects of a store, written by ranges: a commit
	// of 1000 blocks spread over an object of 8 GiB holds about 2000
	// blocks, with its version; the loop of range commits about 4000.
	{name = "ranges", grants = {.Store}, terms = {store_blocks = 12000}},
	// It makes errors in its store, loads modules and starts fault from
	// the boot image, counts the locks, and asks for connections that this
	// service refuses (its role names no service). One object is over the
	// limit of its store. It gives the log to its child, which measures a
	// refused Log.
	{name = "errors", grants = {.Store, .Image, .Inspect, .Connect, .Debug_Image}, terms = {store_blocks = 2, log_gives = true}},
	// It loads modules of the boot image, and measures with the cycle
	// counter.
	{name = "imports", grants = {.Inspect, .Image}},
	// It reads the hash of the module cryptography in the boot image.
	{name = "cryptography_vectors", grants = {.Image}},
	// It measures with the cycle counter.
	{name = "net", grants = {.Inspect, .Network}},
	// A listen grant, its exports for the console, and its pages in its
	// private store.
	{name = "server", grants = {.Network, .Serve, .Store}},
	// A client grant of TCP to one web server, 10.0.2.100 port 80.
	{name = "fetch", grants = {.Network}},
	// The module file service: its private store is the store `programs`
	// of its principal, as a private store has the name of its program,
	// with the limit with which this service reads it and the tool writes
	// it, so no grant differs from the limit on the disk; a client grant
	// of TCP to one web server, 10.0.2.100 port 80; and its exports for the
	// console. It starts nothing: this service checks the hash of each file
	// that a principal starts (docs/MODULE_CONTRACT.md, "A program from a
	// disk"). It starts when a principal connects to it.
	{name = "programs", grants = {.Store, .Network, .Serve}, terms = {store_blocks = disk_program.STORE_BLOCKS_LIMIT, on_demand = true}},
	// A listen grant of UDP: QUIC in the program, the module cryptography
	// through its imports.
	{name = "quic_echo", grants = {.Network}},
	// It is the one client of the frame service of the network device, and
	// it receives from this service the endpoint of each program with the
	// grant Network.
	{name = "network", grants = {.Network_Device}},
	// The calls of another machine: a listen grant of UDP that admits the
	// address of the host only (QUIC in the program, the module
	// cryptography through its imports), the client table, which names the
	// key of each client that a principal allowed, connections to the
	// services of its list, each for one row of that table, and the grant
	// to act for the principal of that row (docs/MODULE_CONTRACT.md, "A
	// call from the host"; docs/PRINCIPALS.md, "The client keys of
	// remote").
	{name = "remote", grants = {.Connect, .Network, .Acts_For_Principal, .Remote_Clients}, terms = {callable = {"compositor", "date", "debugger", "inspect", "log", "manual", "monitor", "settings", "storage"}}},
	// It reads the size of the code of interface_module.
	{name = "interface_through_module", grants = {.Image}},
	// The window of the debugger: a connection to the service debugger and
	// to no other service, the boot image for the description of the
	// exports of that service, and the grant to act for the principal,
	// which the service asks of each caller. It holds no right over a
	// program (docs/TOOLS.md, "The window of the debugger").
	{name = "debugger_window", grants = {.Connect, .Image, .Acts_For_Principal}, terms = {callable = {0 = "debugger"}}},
	// It loads sample, starts a call host of it from the boot image, and
	// connects to the service sample (docs/MODULE_CONTRACT.md, "Tables and
	// bytes as parameters").
	{name = "tables", grants = {.Image, .Connect}, terms = {callable = {0 = "sample"}}},
	// The screen, the input ring and the control ring of this service
	// (compositor_start); its exports serve the programs.
	{name = "compositor", grants = {.Serve, .System_Part}},
	// The ports and the two interrupts of the PS/2 controller (input_start).
	{name = "input", grants = {.System_Part}},
	// The text of the program that writes in it (terminal_start).
	{name = "terminal", grants = {.System_Part}},
	// One block device and the ring of its one client (driver_start).
	{name = "block", grants = {.System_Part}},
	// The network device and the ring of its one client (driver_start).
	{name = "frame", grants = {.System_Part}},
	// The disk of the measures for its one client `iommu` (driver_start).
	{name = "iommu_device", grants = {.System_Part}},
	// The entropy device, whose one client is this service (driver_start).
	{name = "entropy", grants = {.System_Part}},
	// The registers of the TPM, and the ring and the region that `unlock`
	// receives (tpm_service_start).
	{name = "tpm", grants = {.System_Part}},
	// The demand cache with Write and the font outlines
	// (font_service_start).
	{name = "glyphs", grants = {.System_Part}},
	// On the machine of the test of a shortage of frames, shortage_start
	// gives it the machine with Inspect and Stop; a command Start gives it
	// no grant.
	{name = "shortage"},
	// On the machine of the operation sequences, operation_fuzzing_start
	// gives it the machine with the right Physical only, for the physical
	// address of its mailbox, the boot image for the module of its runner,
	// and the log, which it gives to each runner; a command Start gives it
	// no grant. Only the boot image of the operation sequences holds it,
	// and a release refuses an image that holds it.
	{name = "operation_fuzzing", terms = {log_gives = true}},
	// A runner of operation_fuzzing: its starter gives it its handles.
	{name = "operation_sequence_runner"},
	// A load that never ends and never waits for an input.
	{name = "plasma"},
	// It writes to an address that it does not have.
	{name = "fault"},
	// The cards of the people whose work inspired the system.
	{name = "hall_of_fame"},
	// A node of `rings`: its starter gives it four memory objects.
	{name = "node"},
	// Five threads in one address space.
	{name = "threads"},
	// Five threads and one queue of work.
	{name = "workers"},
	// Everything that it uses, it makes.
	{name = "origin"},
	// The limits of its own budget.
	{name = "limits"},
	// The budget of its own children.
	{name = "budget"},
	// This service writes the facts of the seed of the system in its
	// values: facts, not the seed (start_values_of_the_name).
	{name = "randomness"},
	// The extended state of its own threads.
	{name = "extended_state"},
	// The program that the test of the debugger debugs.
	{name = "debug_target"},
	// A guest in its own memory.
	{name = "guest_demo"},
	// A child of `frames`: its starter gives it its handles.
	{name = "twin"},
	// A child of `locks`: its starter gives it its handles.
	{name = "locker"},
	// The call host: its starter gives it the call ring and the call
	// region.
	{name = "host"},
	// The elements of the interface package, in its window.
	{name = "interface_elements"},
	// A frame at 1920 x 1080 drawn into memory of its own budget.
	{name = "processor_frame"},
	// The candidate fonts, in its window.
	{name = "vector_glyphs"},
	// The interface font, in its window.
	{name = "interface_font"},
	// An arena that grows until its own budget refuses a commit.
	{name = "arena"},
}

// The programs that this service starts itself, each in its own way and
// with its own handles: a command Start does not start them, and a disk
// program does not take one of their names. Each one but root has a row of
// program_roles whose grants are System_Part, and Serve beside it for the
// compositor, whose exports serve the programs: the tool refuses another
// set, and the grant System_Part on another row
// (tools/modustool/program_roles_check.odin), because the debug access to
// a program reads that grant. The names are strings that the tool reads.
@(rodata)
system_part_names := [?]string{"root", "input", "compositor", "terminal", "block", "frame", "iommu_device", "tpm", "entropy", "glyphs"}
#assert(FONT_SERVICE_NAME == "glyphs")

// name_is_a_system_part says if a name is one of system_part_names.
name_is_a_system_part :: proc "contextless" (name: string) -> bool {
	for part in system_part_names {
		if name == part {
			return true
		}
	}
	return false
}

// role_of gives the role of a program of the boot image by its name: the
// grants and the terms of its row. A name with no row has the zero role:
// it names no program of the boot image, as the tool checks. Only a start
// reads it.
role_of :: proc "contextless" (name: string) -> (role: Program_Role) {
	for &row in program_roles {
		if row.name == name {
			role.grants = row.grants
			role.terms = row.terms
			break
		}
	}
	return role
}

// role_names_the_program says if the table of this service gives the name
// a grant or a term: a disk program does not take such a nickname, as the
// name would carry an authority that the principal did not give. A row
// with no grant and no term carries none, so it reserves no nickname: a
// nickname of a module of the boot image is refused for that module
// (disk_programs.odin), and a nickname of a program that this image does
// not hold is free.
role_names_the_program :: proc "contextless" (name: string) -> bool {
	for &row in program_roles {
		if row.name == name {
			return row.grants != {} || row.terms != (Program_Role_Terms{})
		}
	}
	return false
}

// role_store_blocks gives the blocks of the private store of a role.
role_store_blocks :: proc "contextless" (role: ^Program_Role) -> u64 {
	return role.store_blocks == 0 ? STORE_BLOCKS_DEFAULT : role.store_blocks
}

// role_may_connect says if a program with a role can ask this service for a
// connection to the service with a name. A program with the grant
// Root_Ring connects to each service.
role_may_connect :: proc "contextless" (role: ^Program_Role, service: string) -> bool {
	if .Root_Ring in role.grants {
		return true
	}
	if .Connect not_in role.grants {
		return false
	}
	for name in role.callable {
		if name == "" {
			return false
		}
		if name == service {
			return true
		}
	}
	return false
}

// role_terminal gives the size of the terminal of a role, and what it
// shows.
role_terminal :: proc "contextless" (role: ^Program_Role) -> (columns, rows: u64, measure: bool) {
	columns = role.terminal_columns == 0 ? TERMINAL_COLUMNS_DEFAULT : role.terminal_columns
	rows = role.terminal_rows == 0 ? TERMINAL_ROWS_DEFAULT : role.terminal_rows
	return columns, rows, role.terminal_measure
}

// on_demand says if the service with a name starts when a program asks for
// a connection to it.
on_demand :: proc "contextless" (name: string) -> bool {
	return role_of(name).on_demand
}
