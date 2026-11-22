package root

import "modus:disk_process"
import terminal "modus:terminal"

// The start grant set of a process of the boot image: what this service gives it at
// its start, by its name. start_grant_set_of reads it one time, at the start; the
// process keeps it in Started.start_grant_set, and each rule after the start reads it
// there and never by the name of the process. A disk process has a
// nickname that it chose: its start grant set comes from the disk grant table of its
// principal, never from this table (disk_processes.odin).
//
// The start grant set of each process is one row of the table `start_grant_sets`: its
// start grants and the other terms of its start grant set. The site reads the table
// for its table "The grants of each process", and the tool stops each build
// when a module of the boot image has no row (start_grant_sets_check.odin).
Start_Grant_Set :: struct {
	grants:      bit_set[Grant],
	using terms: Start_Grant_Set_Terms,
}

// The services that a process with the grant Connect and not Root_Ring can
// connect to: the list of its row, an empty text after the last one.
CALLABLE_LIMIT :: 9

// The parts of a start grant set that are not start grants. Zero is the start grant set of a
// process that needs none of them.
Start_Grant_Set_Terms :: struct {
	callable:         [CALLABLE_LIMIT]string, // With the grant Connect: the services that it can connect to.
	store_blocks:     u64, // With the grant Store: the blocks of its private store. 0: STORE_BLOCKS_DEFAULT.
	log_gives:        bool, // The log with the right Give: it gives the log to the processes that it starts.
	terminal_columns: u64, // With the grant Terminal: the columns of its terminal. 0: TERMINAL_COLUMNS_DEFAULT.
	terminal_rows:    u64, // 0: TERMINAL_ROWS_DEFAULT.
	terminal_measure: bool, // Its terminal shows the rates of the process.
	on_demand:        bool, // A service that starts at the first connection to it.
}

STORE_BLOCKS_DEFAULT :: 64
TERMINAL_COLUMNS_DEFAULT :: 96
TERMINAL_ROWS_DEFAULT :: 26

// A row of the table: the whole start grant set of one process, by its name.
Start_Grant_Set_Row :: struct {
	name:   string,
	grants: bit_set[Grant],
	terms:  Start_Grant_Set_Terms,
}

// The start grant set of each module of the boot image, with the reason of each
// grant and each term. The table is whole: the tool refuses a build where a
// module of the boot image has no row, or a row names no module of it, so
// a new module never starts with a start grant set that nobody wrote. The form of a
// row is the form that the site reads: a record literal with no type, its
// name a string, its grants a set of members, its terms a record, and the
// reason in the comment lines above it.
//
// The rows come in three groups: the processes with grants; the parts of
// the system that this service starts itself (the grant System_Part, and
// the names of system_part_names), each with handles that no other grant
// names, which a command Start does not start; and the processes whose start grant set
// holds no grant: the log and a window, or the handles of the process that
// starts them.
@(rodata)
start_grant_sets := [?]Start_Grant_Set_Row {
	// The console is the shell of the machine, and its commands need
	// each grant:
	// - **Root_Ring**: `start`, `stop`, `grants`, `revoke`, `connect`
	//   and the commands of the principals ask this service.
	// - **Inspect**: `memory`, `locks` and `process_modules` read the
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
	// It gives the log to the processes that it starts, which write on it.
	{name = "console", grants = {.Root_Ring, .Inspect, .Stop, .Image, .Terminal, .Store, .Acts_For_Principal, .Replacements, .Replace, .History_Store, .Debug_Image, .Palette}, terms = {store_blocks = 3, log_gives = true}},
	// It writes its lines to a terminal and reads the key Space from it:
	// it has no surface and needs nothing else. It shows the rates of the
	// process in a terminal as large as a terminal can be.
	{name = "flood", grants = {.Terminal}, terms = {terminal_columns = terminal.COLUMNS_LIMIT, terminal_rows = terminal.ROWS_LIMIT, terminal_measure = true}},
	// The test of the records of a terminal ring whose kind names no
	// record: it writes them to its terminal, as flood writes lines.
	{name = "hostile_terminal", grants = {.Terminal}},
	// A developer tool: it reads the reports of the machine and the names
	// of the modules, and serves the same facts (docs/TOOLS.md).
	{name = "inspect", grants = {.Inspect, .Image, .Serve, .Debug_Image}},
	// It serves processes() and counts() to a caller that acts for the
	// principal. It starts at its first connection, so the table of the
	// processes needs no start of its own, in each start policy, the rescue
	// included.
	{name = "monitor", grants = {.Inspect, .Serve}, terms = {on_demand = true}},
	// The debugger service (docs/TOOLS.md, "The debugger"):
	// - **Serve**: its exports are the commands of the debugger.
	// - **Debugger**: it asks this service for the handle of a process
	//   with the right Debug, on behalf of one of its callers, and, for
	//   a disk process that it debugs, for a connection that reads only
	//   to the store of its debug object (Debug_Store).
	// - **Inspect**: the threads and the module records of the process
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
	// It reads the kernel entries of the process for its measures.
	{name = "flow", grants = {.Inspect}},
	// It reads the kernel entries of the process for its measures.
	{name = "crowd", grants = {.Inspect}},
	// It reads the kernel entries of the process for its measures.
	{name = "clock", grants = {.Inspect}},
	// It shows what the kernel refuses.
	{name = "rights", grants = {.Inspect, .Image}},
	// It reads the pointer themes in the resource table of the boot image.
	{name = "pointers", grants = {.Image}},
	// It serves records(): the whole log to a caller that acts for the
	// principal, its own records to each other caller. The boot image is
	// the catalog in which its window finds the module file of a log fact,
	// to write the sentence of the fact (src/md/features/log_facts.md, "The
	// reader path").
	{name = "log", grants = {.Log_Records, .Serve, .Image}},
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
	// four processes of its case of the shares from the boot image, and
	// serves strategy_set(), share() and policy() to the console.
	{name = "scheduler", grants = {.Inspect, .Schedule, .Image, .Serve}},
	// A service: the console calls its exports through a connection.
	{name = "paint", grants = {.Serve}},
	// A service: the console calls its exports through a connection.
	{name = "life", grants = {.Serve}},
	// A service: the console calls its exports through a connection.
	{name = "tally", grants = {.Serve}},
	// The module of the tables, started as a process when a caller
	// connects.
	{name = "sample", grants = {.Serve}, terms = {on_demand = true}},
	// A service: the console calls its exports through a connection.
	{name = "heron", grants = {.Serve}},
	// It writes the settings, keeps them in its private store, and serves
	// set() and get().
	{name = "settings", grants = {.Settings, .Serve, .Store}},
	// It reads the real-time clock, writes the date page, and serves now().
	{name = "date", grants = {.Clock, .Serve}},
	// The start policy: its root ring starts and stops the processes of
	// its list and says when the machine is usable, and it reads the
	// machine parts page. It holds nothing else, so a fault in it reaches
	// only the processes that it asked for (src/md/features/start_policy.md).
	// This service starts it, and refuses a Start of its name.
	{name = "start_policy", grants = {.Start_Policy}},
	// It reads the documentation of each module of the boot image, and the
	// module records of each process.
	{name = "manual", grants = {.Serve, .Image, .Replacements, .Inspect}},
	// It measures the block service on the disk of the measures, which
	// holds no data of a process: its writes destroy nothing.
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
	// The text that it edits and the versions of the text live in its
	// private store: a commit of a text of 32 KiB holds 8 blocks of data
	// and their nodes, and the store keeps each version for 10 minutes
	// before the thinning.
	{name = "edit", grants = {.Store}, terms = {store_blocks = 4500}},
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
	// service refuses (its start grant set names no service). One object is over the
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
	// The module file service: its private store is the store `module_files`
	// of its principal, as a private store has the name of its process,
	// with the limit with which this service reads it and the tool writes
	// it, so no grant differs from the limit on the disk; a client grant
	// of TCP to one web server, 10.0.2.100 port 80; and its exports for the
	// console. It starts nothing: this service checks the hash of each file
	// that a principal starts (docs/MODULE_CONTRACT.md, "A module from a
	// disk"). It starts when a principal connects to it.
	{name = "module_files", grants = {.Store, .Network, .Serve}, terms = {store_blocks = disk_process.STORE_BLOCKS_LIMIT, on_demand = true}},
	// A listen grant of UDP: QUIC in the process, the module cryptography
	// through its imports.
	{name = "quic_echo", grants = {.Network}},
	// It plays a tone through the sound service of the sound device, its
	// one client while it runs (src/md/features/timed_stream.md).
	{name = "tone", grants = {.Sound_Device}},
	// It is the one client of the frame service of the network device, and
	// it receives from this service the endpoint of each process with the
	// grant Network.
	{name = "network", grants = {.Network_Device}},
	// The calls of another machine: a listen grant of UDP that admits the
	// address of the host only (QUIC in the process, the module
	// cryptography through its imports), the client table, which names the
	// key of each client that a principal allowed, connections to the
	// services of its list, each for one row of that table, and the grant
	// to act for the principal of that row (docs/MODULE_CONTRACT.md, "A
	// call from the host"; docs/PRINCIPALS.md, "The client keys of
	// remote").
	{name = "remote", grants = {.Connect, .Network, .Acts_For_Principal, .Remote_Clients}, terms = {callable = {"compositor", "date", "debugger", "inspect", "log", "manual", "monitor", "settings", "storage"}}},
	// The remote display: a listen grant of UDP that admits the address of
	// the host only, the client table, which names the uses of the key of
	// each viewer that a principal allowed, and the capture face and the
	// input face of the compositor on the ring of its window
	// (src/md/features/remote_display.md). It calls no service.
	{name = "remote_display", grants = {.Network, .Remote_Clients, .Screen_Capture}},
	// It reads the size of the code of interface_module.
	{name = "interface_through_module", grants = {.Image}},
	// The window of the debugger: a connection to the service debugger and
	// to no other service, the boot image for the description of the
	// exports of that service, and the grant to act for the principal,
	// which the service asks of each caller. It holds no right over a
	// process (docs/TOOLS.md, "The window of the debugger").
	{name = "debugger_window", grants = {.Connect, .Image, .Acts_For_Principal}, terms = {callable = {0 = "debugger"}}},
	// It loads sample, starts a call host of it from the boot image, and
	// connects to the service sample (docs/MODULE_CONTRACT.md, "Tables and
	// bytes as parameters").
	{name = "tables", grants = {.Image, .Connect}, terms = {callable = {0 = "sample"}}},
	// The screen, the input ring and the control ring of this service
	// (display_holder_start); its exports serve the processes.
	{name = "compositor", grants = {.Serve, .System_Part}},
	// The ports and the two interrupts of the PS/2 controller (input_start).
	{name = "input", grants = {.System_Part}},
	// The text of the process that writes in it (terminal_start).
	{name = "terminal", grants = {.System_Part}},
	// One block device and the ring of its one client (driver_start).
	{name = "block", grants = {.System_Part}},
	// The network device and the ring of its one client (driver_start).
	{name = "frame", grants = {.System_Part}},
	// The disk of the measures for its one client `iommu` (driver_start).
	{name = "iommu_device", grants = {.System_Part}},
	// The entropy device, whose one client is this service (driver_start).
	{name = "entropy", grants = {.System_Part}},
	// The sound device and the ring of its one client (driver_start).
	{name = "sound", grants = {.System_Part}},
	// The VirtIO-GPU device and the ring of its one client (driver_start).
	{name = "gpu_device", grants = {.System_Part}},
	// The registers of the TPM, and the ring and the region that `unlock`
	// receives (tpm_service_start).
	{name = "tpm", grants = {.System_Part}},
	// The delegated wiring service: its core ring, stops ring, read-only
	// boot image view, and transfer region (wiring_service_start). It holds
	// no root authority, no machine handle, and no Control on any process.
	{name = "wiring", grants = {.System_Part}},
	// The delegated powerbox service: its service ring, trusted display
	// ring and transfer region. It holds no root ring and no ambient authority.
	{name = "powerbox", grants = {.System_Part, .Serve}},
	// The delegated collector service: its service ring and transfer region
	// for hash-chained act records and wide-grant enforcement.
	{name = "collector", grants = {.System_Part, .Serve}},
	// The delegated plans service: its service ring and transfer region for
	// plan diffs, trusted display consent checks, atomic apply, and rollback.
	{name = "plans", grants = {.System_Part, .Serve}},
	// The delegated recipes service: its service ring and transfer region for
	// cache verification, sandboxed builds, and provenance queries.
	{name = "recipes", grants = {.System_Part, .Serve}},
	// The delegated projects service: its service ring and transfer region for
	// pins.lex inspection, source updates, and ephemeral project consoles.
	{name = "projects", grants = {.System_Part, .Serve}},
	// The delegated disk_processes service: it reads the module file of a
	// disk process and its imports through a connection that reads only,
	// into memory that the core lends, and asks for Start_From_Bytes
	// (disk_processes_delegation.odin). Holds no root ring and no machine
	// authority.
	{name = "disk_processes", grants = {.System_Part, .Serve}},
	// The delegated devices service: PCI identity table matching and
	// attenuated per-device grant minting. Holds no root ring.
	{name = "devices", grants = {.System_Part, .Serve}},
	// The delegated principals service: named principals, session lifecycle,
	// disk grant tables, remote client keys, and principal 0 start policy
	// choice. Holds no root ring and no machine authority.
	{name = "principals", grants = {.System_Part, .Serve}},
	// Only the image of the test of a shortage of frames holds it: its
	// start list asks for it, and shortage_start gives it the machine with Inspect and
	// Stop; a command Start of another sender gives it no grant.
	{name = "shortage"},
	// On the machine of the operation sequences, its start list asks for
	// it, and operation_fuzzing_start gives it the machine with the right
	// Physical only, for the physical address of its mailbox, the boot
	// image for the module of its runner, and the log, which it gives to
	// each runner; a command Start of another sender gives it no grant.
	// Only the boot image of the operation sequences holds it, and a
	// release refuses an image that holds it.
	{name = "operation_fuzzing", terms = {log_gives = true}},
	// A runner of operation_fuzzing: its starter gives it its handles.
	{name = "operation_sequence_runner"},
	// A load that never ends and never waits for an input.
	{name = "plasma"},
	// It writes to an address that it does not have.
	{name = "fault"},
	// The cards of the people whose work inspired the system.
	{name = "hall_of_fame"},
	// A light browser: the pages that it shows are built into it, so its
	// window is its one handle.
	{name = "browser"},
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
	// The process that the test of the debugger debugs.
	{name = "debug_target"},
	// The test of the record and the replay of a process with a shared
	// writer: it starts its readers from the boot image.
	{name = "replay_probe", grants = {.Image}},
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
	// The asker of the test of the record outputs: Start, Wire, Connect and
	// Revoke are commands of the root ring, which only the grant Root_Ring
	// sends (src/md/features/module_outputs.md, "How a test waits on a
	// record output"). It starts and wires only its own children, and
	// revokes only its own grant wirings.
	{name = "output_wiring", grants = {.Root_Ring}},
	// The writer and the reader of that test: their ends come from the root
	// service in their wiring rings, and they need no grant.
	{name = "output_writer"},
	{name = "output_reader"},
	// The utility modules of the record streams: their ends come in their
	// wiring rings, and they need no grant.
	{name = "merge"},
	{name = "filter"},
	// The demonstration pair of the start list: the start policy wires
	// them, and they need no grant.
	{name = "wired_reader"},
	{name = "wired_writer"},
	// The asker of the test of the generic record inputs: Start, Wire and
	// Stop are commands of the root ring. Its writer needs no grant.
	{name = "generic_wiring", grants = {.Root_Ring}},
	{name = "generic_source"},
	// The writer of the test of the record output log: its end comes in
	// its context before its first instruction, and it needs no grant. Its
	// log budget holds 0 records (budgets.odin).
	{name = "log_flood"},
	// The follower of the test of log.follow: Connect and Wire are commands
	// of the root ring, and the end Connected of log.follow is given only
	// to a caller that acts for the principal: log.follow carries the
	// records of the whole log.
	{name = "log_follower", grants = {.Root_Ring, .Acts_For_Principal}},
	// A side that writes its own words in its wiring ring, past the
	// library: it needs no grant either.
	{name = "output_side"},
	// The writer of the streams of the console: its end comes in its
	// wiring ring when the console reads `output_counter.counts`, and it
	// needs no grant.
	{name = "output_counter"},
	// Its reader in the wiring list that the console gives its start: its
	// end comes in its wiring ring before its first instruction.
	{name = "output_count_reader"},
	// A writer that writes its ring past the library and ignores the
	// condition of its wiring: the console must refuse its record.
	{name = "output_liar"},
	// The asker of the test of fan-out and the pace: it starts its slow
	// reader and `server` with a wiring list, and reads `server.requests`
	// itself. Start and Wire are commands of the root ring.
	{name = "requests_pace", grants = {.Root_Ring}},
	// Its slow reader: its two ends come in its wiring ring before the
	// first instruction of `server`, and it needs no grant.
	{name = "requests_reader"},
	// The asker of the measures of the record outputs: it starts its
	// readers and its writer with a wiring list, and reads its own grants
	// between two runs. Start, Wire and Grants are commands of the root ring.
	{name = "output_measure", grants = {.Root_Ring}},
	// Its writer and its readers: their ends come in their wiring rings
	// before their first instruction, and they need no grant.
	{name = "output_measure_writer"},
	{name = "output_measure_reader"},
	// The two rows of the test of the restarts of a start policy, which only
	// the image of the test of the rescue holds: each stops itself at once,
	// and needs no grant.
	{name = "stops_refused"},
	{name = "stops_failed"},
}

// The processes that this service starts itself, each in its own way and
// with its own handles: a command Start does not start them, and a disk
// process does not take one of their names. Each one but root has a row of
// start_grant_sets whose grants are System_Part, and Serve beside it for the
// compositor, whose exports serve the processes: the tool refuses another
// set, and the grant System_Part on another row
// (tools/modustool/build/start_grant_sets_check.odin), because the debug access to
// a process reads that grant. The names are strings that the tool reads.
@(rodata)
system_part_names := [?]string{"root", "input", "compositor", "terminal", "block", "frame", "iommu_device", "tpm", "entropy", "sound", "gpu_device", "wiring", "powerbox", "collector", "plans", "recipes", "projects", "disk_processes", "devices", "principals"}

// name_is_a_system_part says if a name is one of system_part_names.
name_is_a_system_part :: proc "contextless" (name: string) -> bool {
	for part in system_part_names {
		if name == part {
			return true
		}
	}
	return false
}

// start_grant_set_of gives the start grant set of a process of the boot image by its name: the
// grants and the terms of its row. A name with no row has the zero start grant set:
// it names no module of the boot image, as the tool checks. Only a start
// reads it.
start_grant_set_of :: proc "contextless" (name: string) -> (start_grant_set: Start_Grant_Set) {
	for &row in start_grant_sets {
		if row.name == name {
			start_grant_set.grants = row.grants
			start_grant_set.terms = row.terms
			break
		}
	}
	return start_grant_set
}

// start_grant_set_names_the_process says if the table of this service gives the name
// a grant or a term: a disk process does not take such a nickname, as the
// name would carry an authority that the principal did not give. A row
// with no grant and no term carries none, so it reserves no nickname: a
// nickname of a module of the boot image is refused for that module
// (disk_processes.odin), and a nickname of a module that this image does
// not hold is free.
start_grant_set_names_the_process :: proc "contextless" (name: string) -> bool {
	for &row in start_grant_sets {
		if row.name == name {
			return row.grants != {} || row.terms != (Start_Grant_Set_Terms{})
		}
	}
	return false
}

// start_grant_set_store_blocks gives the blocks of the private store of a start grant set.
start_grant_set_store_blocks :: proc "contextless" (start_grant_set: ^Start_Grant_Set) -> u64 {
	return start_grant_set.store_blocks == 0 ? STORE_BLOCKS_DEFAULT : start_grant_set.store_blocks
}

// start_grant_set_may_connect says if a process with a start grant set can ask this service for a
// connection to the service with a name. A process with the grant
// Root_Ring connects to each service.
start_grant_set_may_connect :: proc "contextless" (start_grant_set: ^Start_Grant_Set, service: string) -> bool {
	if .Root_Ring in start_grant_set.grants {
		return true
	}
	if .Connect not_in start_grant_set.grants {
		return false
	}
	for name in start_grant_set.callable {
		if name == "" {
			return false
		}
		if name == service {
			return true
		}
	}
	return false
}

// start_grant_set_terminal gives the size of the terminal of a start grant set, and what it
// shows.
start_grant_set_terminal :: proc "contextless" (start_grant_set: ^Start_Grant_Set) -> (columns, rows: u64, measure: bool) {
	columns = start_grant_set.terminal_columns == 0 ? TERMINAL_COLUMNS_DEFAULT : start_grant_set.terminal_columns
	rows = start_grant_set.terminal_rows == 0 ? TERMINAL_ROWS_DEFAULT : start_grant_set.terminal_rows
	return columns, rows, start_grant_set.terminal_measure
}

// on_demand says if the service with a name starts when a process asks for
// a connection to it.
on_demand :: proc "contextless" (name: string) -> bool {
	if name == "plans" || name == "recipes" || name == "projects" || name == "collector" || name == "powerbox" {
		return true
	}
	return start_grant_set_of(name).on_demand
}
