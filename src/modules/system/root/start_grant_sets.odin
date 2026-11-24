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
// Whether a process runs once for the machine or once per unlocked principal
// session (src/md/features/several_principals.md, "The services that keep
// data"). Session is the zero value so no process silently shares state across
// principals.
Service_Scope :: enum u8 {
	Session = 0,
	Machine = 1,
}

Start_Grant_Set :: struct {
	scope:       Service_Scope,
	grants:      bit_set[Grant],
	using terms: Start_Grant_Set_Terms,
}

// The services that a process with the grant Connect and not Root_Ring can
// connect to: the list of its row, an empty text after the last one. The
// longest list is the one of remote, whose clients call the services of
// the principal: ten. A full list needs no empty text, as the reader stops
// at the end of the array too, so the limit is that length, with no spare
// place that no row uses.
CALLABLE_LIMIT :: 10

// The parts of a start grant set that are not start grants. Zero is the start grant set of a
// process that needs none of them.
Start_Grant_Set_Terms :: struct {
	callable:         [CALLABLE_LIMIT]string, // With the grant Connect: the services that it can connect to.
	store_blocks:     u64, // With the grant Store: the blocks of its private store. 0: STORE_BLOCKS_DEFAULT.
	log_gives:        bool, // The log with the right Give: it gives the log to the processes that it starts.
	store_gives:      bool, // With the grant Store: the storage service with the right Give: it gives it to the processes that it starts with a share of its store.
	terminal_columns: u64, // With the grant Terminal: the columns of its terminal. 0: TERMINAL_COLUMNS_DEFAULT.
	terminal_rows:    u64, // 0: TERMINAL_ROWS_DEFAULT.
	terminal_measure: bool, // Its terminal shows the rates of the process.
	on_demand:        bool, // A service that starts at the first connection to it.
	asks_acts:        bool, // With the grant Connect to the holder of Display: it may ask the principal to decide one act of an agent (plans_recipes.DISPLAY_AMOUNT_ACT_ASKER), and nothing else that serves the principal.
}

STORE_BLOCKS_DEFAULT :: 64
TERMINAL_COLUMNS_DEFAULT :: 96
TERMINAL_ROWS_DEFAULT :: 26
// The terminal of flood: the size of its measures since they started.
FLOOD_TERMINAL_COLUMNS :: 104
FLOOD_TERMINAL_ROWS :: 32
#assert(FLOOD_TERMINAL_COLUMNS <= terminal.COLUMNS_LIMIT && FLOOD_TERMINAL_ROWS <= terminal.ROWS_LIMIT)

// A row of the table: the whole start grant set of one process, by its name.
Start_Grant_Set_Row :: struct {
	name:   string,
	scope:  Service_Scope,
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
	{name = "console", scope = .Session, grants = {.Root_Ring, .Inspect, .Stop, .Image, .Terminal, .Store, .Acts_For_Principal, .Replacements, .Replace, .History_Store, .Debug_Image, .Palette, .Recount}, terms = {store_blocks = 3, log_gives = true}},
	// It writes its lines to a terminal and reads the key Space from it:
	// it has no surface and needs nothing else. It shows the rates of the
	// process in a terminal of a fixed size, so that its measures compare
	// from one run to the next.
	{name = "flood", scope = .Session, grants = {.Terminal}, terms = {terminal_columns = FLOOD_TERMINAL_COLUMNS, terminal_rows = FLOOD_TERMINAL_ROWS, terminal_measure = true}},
	// The test of the records of a terminal ring whose kind names no
	// record: it writes them to its terminal, as flood writes lines.
	{name = "hostile_terminal", scope = .Session, grants = {.Terminal}},
	// A shell of Linux in a guest (src/md/features/linux_shell.md):
	// - **Terminal**: the serial console of the guest, both ways.
	// - **Store**: its private store holds the guest image: a kernel of
	//   13 MB and an initial archive. The blocks hold both, with room for a
	//   newer kernel beside them.
	{name = "linux", scope = .Session, grants = {.Terminal, .Store}, terms = {store_blocks = 8192}},
	// A developer tool: it reads the reports of the machine and the names
	// of the modules, and serves the same facts (docs/TOOLS.md).
	{name = "inspect", scope = .Session, grants = {.Inspect, .Image, .Serve, .Debug_Image}},
	// It serves processes() and counts() to a caller that acts for the
	// principal. It starts at its first connection, so the table of the
	// processes needs no start of its own, in each start policy, the rescue
	// included.
	// Its private store (Store) keeps the settings that the principal
	// chose.
	{name = "monitor", scope = .Session, grants = {.Inspect, .Serve, .Store}, terms = {on_demand = true}},
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
	{name = "debugger", scope = .Session, grants = {.Serve, .Debugger, .Inspect, .Debug_Image, .Image}, terms = {on_demand = true}},
	// It shows what each processor runs.
	{name = "processors", scope = .Session, grants = {.Inspect}},
	// It shows the page tables.
	{name = "pages", scope = .Session, grants = {.Inspect}},
	// It reads the kernel entries of the process for its measures.
	{name = "flow", scope = .Session, grants = {.Inspect}},
	// It reads the kernel entries of the process for its measures.
	{name = "crowd", scope = .Session, grants = {.Inspect}},
	// It reads the kernel entries of the process for its measures.
	{name = "time_page", scope = .Session, grants = {.Inspect}},
	// The clock of the desktop: a connection to the compositor only, for
	// the notification at the end of its timer, and the boot image for the
	// description of the exports of the compositor
	// (src/md/features/clock_application.md, "The grants").
	{name = "clock", scope = .Session, grants = {.Connect, .Image}, terms = {callable = {0 = "compositor"}}},
	// It shows what the kernel refuses.
	{name = "rights", scope = .Session, grants = {.Inspect, .Image}},
	// It reads the pointer themes in the resource table of the boot image.
	{name = "pointers", scope = .Session, grants = {.Image}},
	// It serves records(): the whole log to a caller that acts for the
	// principal, its own records to each other caller. The boot image is
	// the catalog in which its window finds the module file of a log fact,
	// to write the sentence of the fact (src/md/features/log_facts.md, "The
	// reader path").
	{name = "log", scope = .Machine, grants = {.Log_Records, .Serve, .Image}},
	// The test of the own records and of the records of its children: a
	// connection to the log service and to no other service, with no
	// grant to act for the principal, and the boot image for the
	// description of the exports of that service and for the module of
	// its children (src/md/features/log_reader_scope.md). It starts them on
	// its own budget, and the handle of each child is its grant to read the
	// records of that child; each child writes the records that its
	// starter reads back, one of them more than the whole log keeps
	// (src/md/features/own_log_ring.md).
	{name = "log_reader", scope = .Session, grants = {.Connect, .Image}, terms = {callable = {0 = "log"}, log_gives = true}},
	// It shows the modules of the boot image.
	{name = "boot", scope = .Session, grants = {.Inspect, .Image}},
	// It starts its nodes from the boot image, and its nodes write on the
	// log.
	{name = "rings", scope = .Session, grants = {.Image}, terms = {log_gives = true}},
	// It reads its own page table, and starts its twins from the boot
	// image.
	{name = "frames", scope = .Session, grants = {.Inspect, .Image}},
	// It reads the counts of the locks, and starts its lockers from the
	// boot image.
	{name = "locks", scope = .Session, grants = {.Inspect, .Image}},
	// It reads its own mappings, and starts its child from the boot image.
	{name = "address_space", scope = .Session, grants = {.Inspect, .Image}},
	// It starts its children from the boot image.
	{name = "return_fault", scope = .Session, grants = {.Image}},
	// It starts its children from the boot image; the child that repairs
	// logs its own cases.
	{name = "fault_ring", scope = .Session, grants = {.Image}, terms = {log_gives = true}},
	// It starts its children from the boot image, and is the debugger of
	// each one: no grant of this service gives it that. A child writes one
	// line from a buffer that its debugger watches.
	{name = "debugged", scope = .Session, grants = {.Image}, terms = {log_gives = true}},
	// It gives the event table of the machine, and starts its children
	// from the boot image.
	{name = "kernel_events", scope = .Session, grants = {.Events, .Image}},
	// It counts the events of the processor for its own loop
	// (docs/ARCHITECTURE.md, "The counters of a thread").
	{name = "counters", scope = .Session, grants = {.Counters}},
	// It reads the counts of the scheduler, changes the strategy and
	// writes the weight of each thread (the share policy). It starts the
	// four processes of its case of the shares from the boot image, and
	// serves strategy_set(), share() and policy() to the console.
	{name = "scheduler", scope = .Machine, grants = {.Inspect, .Schedule, .Image, .Serve}},
	// A service: the console calls its exports through a connection. Its
	// private store keeps the pictures that the principal saves
	// (src/md/features/paint_application.md).
	{name = "paint", scope = .Session, grants = {.Serve, .Store}, terms = {store_blocks = 12000}},
	// A window and a service: the agent runner on the host calls its
	// exports through remote, it asks the trusted display for the act
	// dialog with the term asks_acts, and it keeps its conversation in its
	// private store across restarts. It acts for nobody: the grant to act
	// for the principal would open each export of the display that serves
	// the principal (src/md/features/assistant.md, "The right to ask an
	// act"). The boot image checks that the holder of Display has the act
	// dialog.
	{name = "assistant", scope = .Session, grants = {.Serve, .Image, .Connect, .Store}, terms = {callable = {0 = "display"}, asks_acts = true, store_blocks = 12000}},
	// A service: the console calls its exports through a connection.
	{name = "life", scope = .Session, grants = {.Serve}},
	// A service: the console calls its exports through a connection.
	{name = "tally", scope = .Session, grants = {.Serve}},
	// The module of the tables, started as a process when a caller
	// connects.
	{name = "sample", scope = .Session, grants = {.Serve}, terms = {on_demand = true}},
	// A service: the console calls its exports through a connection.
	{name = "heron", scope = .Session, grants = {.Serve}},
	// It writes the settings, keeps them in its private store, serves set()
	// and get(), reads module descriptions from the boot image to discover
	// module settings dynamically, and connects to the role and module
	// setters on behalf of the principal.
	{name = "settings", scope = .Session, grants = {.Settings, .Serve, .Store, .Image, .Connect, .Acts_For_Principal}, terms = {callable = {0 = "compositor", 1 = "monitor", 2 = "browser"}}},
	// It reads the real-time clock, writes the date page, and serves now().
	{name = "date", scope = .Machine, grants = {.Clock, .Serve}},
	// The start policy: its root ring starts and stops the processes of
	// its list and says when the machine is usable, and it reads the
	// machine parts page. It holds nothing else, so a fault in it reaches
	// only the processes that it asked for (src/md/features/start_policy.md).
	// This service starts it, and refuses a Start of its name.
	{name = "start_policy", scope = .Machine, grants = {.Start_Policy}},
	// It reads the documentation of each module of the boot image, and the
	// module records of each process.
	{name = "manual", scope = .Session, grants = {.Serve, .Image, .Replacements, .Inspect}},
	// It measures the block service on the disk of the measures, which
	// holds no data of a process: its writes destroy nothing.
	{name = "disk", scope = .Session, grants = {.Scratch_Disk}},
	// The client of the test of the IOMMU: its device service on the disk
	// of the measures is the test device service iommu_device.
	{name = "iommu", scope = .Session, grants = {.Scratch_Disk}},
	// It is the one client of the block service of the data disk, and it
	// serves a private store to each caller with the grant Store. It starts
	// at the first connection to it.
	{name = "storage", scope = .Machine, grants = {.Serve, .Data_Disk}, terms = {on_demand = true}},
	// The holder of the role Plans: the generations of the plan of each
	// principal in its private store, the boot image and a connection to the
	// trusted display for the difference that the principal sees, and the
	// roles page of this service, which takes the roles of an accepted plan
	// of principal 0 whole or refuses them whole (Root_Command.Plan_Roles;
	// src/md/features/declarations.md, "Apply, the difference and the
	// rollback"). Its callers act for their principal; it acts for nobody.
	{name = "plans", scope = .Session, grants = {.Serve, .Store, .Image, .Connect, .Plans}, terms = {callable = {0 = "display"}, on_demand = true}},
	// The holder of the role Recipes: the cache of the realisations and the
	// recipes in its private store (src/md/features/recipes.md). It starts
	// each builder as a call host (including c_compiler and assemble for the
	// native C builder, src/md/features/program_loop.md): the boot image gives
	// the module of the call host and the compilers, log_gives gives a child
	// its own log handle, and store_gives lets recipes give storage shares to
	// a builder (src/md/features/recipes.md, "The builder"). Its store holds
	// the objects of its guest builds by their hashes: a kernel of 13 MB, an
	// initial archive and the files of the inputs and the outputs
	// (src/md/features/recipes.md, "The guest builder in the service"). A
	// guest build needs no grant: the guest is a process that its own budget
	// pays. Network gives one scoped UDP client endpoint to the object cache
	// (port 5010), used only by recipes itself and never passed to a builder
	// or a guest.
	{name = "recipes", scope = .Session, grants = {.Serve, .Store, .Image, .Network}, terms = {store_blocks = 16384, on_demand = true, log_gives = true, store_gives = true}},
	// The holder of the role Projects: the pins of each project in its
	// private store (src/md/features/declarations.md).
	{name = "projects", scope = .Session, grants = {.Serve, .Store}, terms = {on_demand = true}},
	// The collector of principal 0: the audit spaces of the record outputs
	// that a wiring gives it, as segments chained by their hash in its
	// private store, and the act records of the wide grants
	// (src/md/features/module_outputs.md, "The collector"). Its callers
	// act for its principal; it acts for nobody. A source reaches it only
	// through a wiring, never through a grant.
	{name = "collector", scope = .Session, grants = {.Serve, .Store}, terms = {on_demand = true}},
	// The notes and their versions live in its private store: a version
	// of a note of 32 KiB holds 8 blocks of data and their nodes, and the
	// store keeps each version for 10 minutes before the thinning.
	{name = "notes", scope = .Session, grants = {.Store}, terms = {store_blocks = 4500}},
	// The test of persistence: its note, its count and their versions live
	// in its private store: the versions of a run of 1000 commits of the
	// count (4 blocks each), then thinning at the limit.
	{name = "persistence_check", scope = .Session, grants = {.Store}, terms = {store_blocks = 4500}},
	// The text that it edits and the versions of the text live in its
	// private store: a commit of a text of 32 KiB holds 8 blocks of data
	// and their nodes, and the store keeps each version for 10 minutes
	// before the thinning.
	{name = "edit", scope = .Session, grants = {.Store}, terms = {store_blocks = 4500}},
	// The records of the named principals in its private store, the
	// passphrase in its window, the commands of the principals, and the
	// ring of the TPM service, which seals the machine key to the measure
	// of the system (docs/PRINCIPALS.md). It erases the versions of the
	// file of a principal after a change of a secret, so an old secret
	// opens no version (docs/STORAGE.md, "4.8 The erase of versions").
	{name = "unlock", scope = .Machine, grants = {.Store, .Principals, .Tpm, .Versions_Erase}},
	// The test of the trees of a store: 100000 empty objects in 1110 trees,
	// about 9500 nodes, and room for the copies of a commit.
	{name = "hierarchy", scope = .Session, grants = {.Store}, terms = {store_blocks = 12000}},
	// The test of the large objects of a store, written by ranges: a commit
	// of 1000 blocks spread over an object of 8 GiB holds about 2000
	// blocks, with its version; the loop of range commits about 4000.
	{name = "ranges", scope = .Session, grants = {.Store}, terms = {store_blocks = 12000}},
	// It makes errors in its store, loads modules and starts fault from
	// the boot image, counts the locks, and asks for connections that this
	// service refuses (its start grant set names no service). One object is over the
	// limit of its store. It gives the log to its child, which measures a
	// refused Log.
	{name = "errors", scope = .Session, grants = {.Store, .Image, .Inspect, .Connect, .Debug_Image}, terms = {store_blocks = 2, log_gives = true}},
	// It loads modules of the boot image, and measures with the cycle
	// counter.
	{name = "imports", scope = .Session, grants = {.Inspect, .Image}},
	// It reads the hash of the module cryptography in the boot image.
	{name = "cryptography_vectors", scope = .Session, grants = {.Image}},
	// It measures with the cycle counter.
	{name = "net", scope = .Session, grants = {.Inspect, .Network}},
	// A listen grant, its exports for the console, and its pages in its
	// private store.
	{name = "server", scope = .Session, grants = {.Network, .Serve, .Store}},
	// A client grant of TCP to one web server, 10.0.2.100 port 80.
	{name = "fetch", scope = .Session, grants = {.Network}},
	// The module file service: its private store is the store `module_files`
	// of its principal, as a private store has the name of its process,
	// with the limit with which this service reads it and the tool writes
	// it, so no grant differs from the limit on the disk; a client grant
	// of TCP to one web server, 10.0.2.100 port 80; and its exports for the
	// console. It starts nothing: this service checks the hash of each file
	// that a principal starts (docs/MODULE_CONTRACT.md, "A module from a
	// disk"). It starts when a principal connects to it.
	{name = "module_files", scope = .Session, grants = {.Store, .Network, .Serve}, terms = {store_blocks = disk_process.STORE_BLOCKS_LIMIT, on_demand = true}},
	// A listen grant of UDP: QUIC in the process, the module cryptography
	// through its imports.
	{name = "quic_echo", scope = .Session, grants = {.Network}},
	// It plays a tone through the sound service of the sound device, its
	// one client while it runs (src/md/features/timed_stream.md).
	{name = "tone", scope = .Session, grants = {.Sound_Device}},
	// It is the one client of the frame service of the network device, and
	// it receives from this service the endpoint of each process with the
	// grant Network.
	{name = "network", scope = .Machine, grants = {.Network_Device}},
	// The calls of another machine: a listen grant of UDP that admits the
	// address of the host only (QUIC in the process, the module
	// cryptography through its imports), the client table, which names the
	// key of each client that a principal allowed, connections to the
	// services of its list, each for one row of that table, and the grant
	// to act for the principal of that row (docs/MODULE_CONTRACT.md, "A
	// call from the host"; docs/PRINCIPALS.md, "The client keys of
	// remote").
	{name = "remote", scope = .Machine, grants = {.Connect, .Network, .Acts_For_Principal, .Remote_Clients}, terms = {callable = {0 = "assistant", 1 = "compositor", 2 = "date", 3 = "debugger", 4 = "inspect", 5 = "log", 6 = "manual", 7 = "monitor", 8 = "settings", 9 = "storage"}}},
	// The remote display: a listen grant of UDP that admits the address of
	// the host only, the client table, which names the uses of the key of
	// each viewer that a principal allowed, and the capture face and the
	// input face of the compositor on the ring of its window
	// (src/md/features/remote_display.md). It calls no service.
	{name = "remote_display", scope = .Machine, grants = {.Network, .Remote_Clients, .Screen_Capture}},
	// It reads the size of the code of interface_module.
	{name = "interface_through_module", scope = .Session, grants = {.Image}},
	// The window of the debugger: a connection to the service debugger and
	// to no other service, the boot image for the description of the
	// exports of that service, and the grant to act for the principal,
	// which the service asks of each caller. It holds no right over a
	// process (docs/TOOLS.md, "The window of the debugger").
	{name = "debugger_window", scope = .Session, grants = {.Connect, .Image, .Acts_For_Principal}, terms = {callable = {0 = "debugger"}}},
	// It loads sample, starts a call host of it from the boot image, and
	// connects to the service sample (docs/MODULE_CONTRACT.md, "Tables and
	// bytes as parameters").
	{name = "tables", scope = .Session, grants = {.Image, .Connect}, terms = {callable = {0 = "sample"}}},
	// The screen, the input ring and the control ring of this service
	// (display_holder_start); its exports serve the processes.
	{name = "compositor", scope = .Machine, grants = {.Serve, .System_Part}},
	// The ports and the two interrupts of the PS/2 controller (input_start).
	{name = "input", scope = .Machine, grants = {.System_Part}},
	// The text of the process that writes in it (terminal_start).
	{name = "terminal", scope = .Machine, grants = {.System_Part}},
	// The terminal of a console image with no compositor: the ports of the
	// second serial port, COM2, where it writes ANSI text and reads keys
	// (renderer_terminal_start).
	// COM1 stays the log of the kernel.
	{name = "serial_terminal", scope = .Machine, grants = {.System_Part}},
	// The terminal of a console image with no compositor on a machine with
	// a screen: the framebuffer, where it draws a grid of characters, and
	// the input ring, whose keys it sends to its process
	// (renderer_terminal_start).
	{name = "grid_terminal", scope = .Machine, grants = {.System_Part}},
	// The terminal of a console image for a page that draws it with the
	// document of a browser: the ports of COM2, where it writes one JSON
	// line for each step and reads keys (renderer_terminal_start).
	{name = "dom_terminal", scope = .Machine, grants = {.System_Part}},
	// One block device and the ring of its one client (driver_start).
	{name = "block", scope = .Machine, grants = {.System_Part}},
	// The network device and the ring of its one client (driver_start).
	{name = "frame", scope = .Machine, grants = {.System_Part}},
	// The disk of the measures for its one client `iommu` (driver_start).
	{name = "iommu_device", scope = .Machine, grants = {.System_Part}},
	// The entropy device, whose one client is this service (driver_start).
	{name = "entropy", scope = .Machine, grants = {.System_Part}},
	// The sound device and the ring of its one client (driver_start).
	{name = "sound", scope = .Machine, grants = {.System_Part}},
	// The VirtIO-GPU device and the ring of its one client (driver_start).
	{name = "gpu_device", scope = .Machine, grants = {.System_Part}},
	// The registers of the TPM, and the ring and the region that `unlock`
	// receives (tpm_service_start).
	{name = "tpm", scope = .Machine, grants = {.System_Part}},
	// The delegated wiring service: its core ring, stops ring, read-only
	// boot image view, and transfer region (wiring_service_start). It holds
	// no root authority, no machine handle, and no Control on any process.
	{name = "wiring", scope = .Machine, grants = {.System_Part}},
	// The delegated powerbox service: its service ring, trusted display
	// ring and transfer region. It holds no root ring and no ambient authority.
	{name = "powerbox", scope = .Machine, grants = {.System_Part, .Serve}},
	// The delegated disk_processes service: it reads the module file of a
	// disk process and its imports through a connection that reads only,
	// into memory that the core lends, and asks for Start_From_Bytes
	// (disk_processes_delegation.odin). Holds no root ring and no machine
	// authority.
	{name = "disk_processes", scope = .Machine, grants = {.System_Part, .Serve}},
	// The delegated devices service: PCI identity table matching and
	// attenuated per-device grant minting. Holds no root ring.
	{name = "devices", scope = .Machine, grants = {.System_Part, .Serve}},
	// The delegated principals service: named principals, session lifecycle,
	// disk grant tables, remote client keys, and principal 0 start policy
	// choice. Holds no root ring and no machine authority.
	{name = "principals", scope = .Machine, grants = {.System_Part, .Serve}},
	// Only the image of the test of a shortage of frames holds it: its
	// start list asks for it, and shortage_start gives it the machine with Inspect and
	// Stop; a command Start of another sender gives it no grant.
	{name = "shortage", scope = .Machine},
	// On the machine of the operation sequences, its start list asks for
	// it, and operation_fuzzing_start gives it the machine with the right
	// Physical only, for the physical address of its mailbox, the boot
	// image for the module of its runner, and the log, which it gives to
	// each runner; a command Start of another sender gives it no grant.
	// Only the boot image of the operation sequences holds it, and a
	// release refuses an image that holds it.
	{name = "operation_fuzzing", scope = .Machine, terms = {log_gives = true}},
	// A runner of operation_fuzzing: its starter gives it its handles.
	{name = "operation_sequence_runner", scope = .Machine},
	// A load that never ends and never waits for an input.
	{name = "plasma", scope = .Session},
	// It writes to an address that it does not have.
	{name = "fault", scope = .Session},
	// The cards of the people whose work inspired the system.
	{name = "hall_of_fame", scope = .Session},
	// A light browser: the pages that it shows are built into it.
	// - **Serve**: its settings (set, home, reset, settings_state).
	// - **Store**: its private store keeps the settings that the principal
	//   chose.
	{name = "browser", scope = .Session, grants = {.Serve, .Store}},
	// A node of `rings`: its starter gives it four memory objects.
	{name = "node", scope = .Session},
	// Five threads in one address space.
	{name = "threads", scope = .Session},
	// Five threads and one queue of work.
	{name = "workers", scope = .Session},
	// Everything that it uses, it makes.
	{name = "origin", scope = .Session},
	// The limits of its own budget.
	{name = "limits", scope = .Session},
	// The budget of its own children.
	{name = "budget", scope = .Session},
	// This service writes the facts of the seed of the system in its
	// values: facts, not the seed (start_values_of_the_name).
	{name = "randomness", scope = .Session},
	// The extended state of its own threads.
	{name = "extended_state", scope = .Session},
	// The process that the test of the debugger debugs.
	{name = "debug_target", scope = .Session},
	// The test of the record and the replay of a process with a shared
	// writer: it starts its readers from the boot image.
	{name = "replay_probe", scope = .Session, grants = {.Image}},
	// A guest in its own memory.
	{name = "guest_demo", scope = .Session},
	// A child of `frames`: its starter gives it its handles.
	{name = "twin", scope = .Session},
	// A child of `locks`: its starter gives it its handles.
	{name = "locker", scope = .Session},
	// The call host: its starter gives it the call ring and the call
	// region.
	{name = "host", scope = .Session},
	// The elements of the interface package, in its window.
	{name = "interface_elements", scope = .Session},
	// A frame at 1920 x 1080 drawn into memory of its own budget.
	{name = "processor_frame", scope = .Session},
	// The candidate fonts, in its window.
	{name = "vector_glyphs", scope = .Session},
	// The interface font, in its window.
	{name = "interface_font", scope = .Session},
	// An arena that grows until its own budget refuses a commit.
	{name = "arena", scope = .Session},
	// The asker of the test of the record outputs: Start, Wire, Connect and
	// Revoke are commands of the root ring, which only the grant Root_Ring
	// sends (src/md/features/module_outputs.md, "How a test waits on a
	// record output"). It starts and wires only its own children, and
	// revokes only its own grant wirings.
	{name = "output_wiring", scope = .Session, grants = {.Root_Ring}},
	// The writer and the reader of that test: their ends come from the root
	// service in their wiring rings, and they need no grant.
	{name = "output_writer", scope = .Session},
	{name = "output_reader", scope = .Session},
	// The utility modules of the record streams: their ends come in their
	// wiring rings, and they need no grant.
	{name = "merge", scope = .Session},
	{name = "filter", scope = .Session},
	// The demonstration pair of the start list: the start policy wires
	// them, and they need no grant.
	{name = "wired_reader", scope = .Session},
	{name = "wired_writer", scope = .Session},
	// The asker of the test of the generic record inputs: Start, Wire and
	// Stop are commands of the root ring. Its writer needs no grant.
	{name = "generic_wiring", scope = .Session, grants = {.Root_Ring}},
	{name = "generic_source", scope = .Session},
	// The asker of the test of the audit of the collector: Start, Wire and
	// Connect are commands of the root ring. It starts the collector and
	// wires the pair of an audit to itself, and asks the holder of Display
	// for the dialog of a plan, which it must refuse: the boot image gives
	// the description of its exports.
	{name = "audit_asker", scope = .Session, grants = {.Root_Ring, .Image}, terms = {callable = {0 = "display"}}},
	// The applier of the test of the plan of principal 0: a connection to
	// the holder of Plans and to no other service, the boot image for the
	// description of its exports and for the hash of the holder that the
	// plan names, and the grant to act for the principal, which plans.apply
	// asks.
	{name = "plan_applier", scope = .Session, grants = {.Connect, .Image, .Acts_For_Principal}, terms = {callable = {0 = "plans"}}},
	// The asker of the test of the store picker: a connection to the
	// holder of Display and to no other service, the boot image for the
	// description of its exports, and the grant to act for the principal,
	// which powerbox_pick_store asks.
	{name = "store_asker", scope = .Session, grants = {.Connect, .Image, .Acts_For_Principal}, terms = {callable = {0 = "display"}}},
	// The stranger of the same test: the same connection with no grant to
	// act for the principal, so the display refuses it each grant and each
	// list.
	{name = "store_stranger", scope = .Session, grants = {.Connect, .Image}, terms = {callable = {0 = "display"}}},
	// The hostile caller of the trusted display of a plan difference: the
	// grant to act for the principal, so the display reads the objects that
	// it gives, and a connection to the holder of Display only.
	{name = "difference_hostile", scope = .Session, grants = {.Connect, .Image, .Acts_For_Principal}, terms = {callable = {0 = "display"}}},
	// The machine case of the border of Memory_Read: the boot image, which
	// the kernel names as device memory, for the refusal of device memory.
	{name = "memory_read_border", scope = .Session, grants = {.Image}},
	// The machine case of the budget of a surface: the ring of its window
	// only, which each start gives.
	{name = "surface_budget_edges", scope = .Session, grants = {}},
	// The driver of the machine test of the builders: it registers and
	// builds recipes with the service recipes, which takes a caller that
	// acts for its principal; the boot image gives the hash of the test
	// builder and the descriptions of the exports of recipes.
	{name = "build_check", scope = .Session, grants = {.Connect, .Image, .Acts_For_Principal}, terms = {callable = {0 = "recipes"}}},
	// The planners of the tests of the script font set: the grants of
	// plan_applier, for a plan of one entry Script_Fonts. They get the
	// font outlines, as each process that draws text, and hash them.
	{name = "script_fonts_planner", scope = .Session, grants = {.Connect, .Image, .Acts_For_Principal}, terms = {callable = {0 = "plans"}}},
	{name = "script_fonts_cut_planner", scope = .Session, grants = {.Connect, .Image, .Acts_For_Principal}, terms = {callable = {0 = "plans"}}},
	// The writer of the test of the mapping of the script font set: it
	// needs no grant; it gets the set where the font outlines go.
	{name = "script_fonts_writer", scope = .Session},
	// The holder of Settings that the plan of that test names: it writes
	// its line and stops, and needs no grant.
	{name = "settings_stand_in", scope = .Session},
	// The writer of the test of the record output log: its end comes in
	// its context before its first instruction, and it needs no grant. Its
	// log budget holds 0 records (budgets.odin).
	{name = "log_flood", scope = .Session},
	// The follower of the test of log.follow: Connect and Wire are commands
	// of the root ring, and the end Connected of log.follow is given only
	// to a caller that acts for the principal: log.follow carries the
	// records of the whole log.
	{name = "log_follower", scope = .Session, grants = {.Root_Ring, .Acts_For_Principal}},
	// The test of the border of compositor.notify: a connection to the
	// compositor that does not act for the principal, and the boot image
	// for the description of its exports (src/md/features/tray_widgets.md,
	// "The export notify").
	{name = "notify_border_of_the_compositor", scope = .Session, grants = {.Connect, .Image}, terms = {callable = {0 = "compositor"}}},
	// A side that writes its own words in its wiring ring, past the
	// library: it needs no grant either.
	{name = "output_side", scope = .Session},
	// The writer of the streams of the console: its end comes in its
	// wiring ring when the console reads `output_counter.counts`, and it
	// needs no grant.
	{name = "output_counter", scope = .Session},
	// Its reader in the wiring list that the console gives its start: its
	// end comes in its wiring ring before its first instruction.
	{name = "output_count_reader", scope = .Session},
	// A writer that writes its ring past the library and ignores the
	// condition of its wiring: the console must refuse its record.
	{name = "output_liar", scope = .Session},
	// The asker of the test of fan-out and the pace: it starts its slow
	// reader and `server` with a wiring list, and reads `server.requests`
	// itself. Start and Wire are commands of the root ring.
	{name = "requests_pace", scope = .Session, grants = {.Root_Ring}},
	// Its slow reader: its two ends come in its wiring ring before the
	// first instruction of `server`, and it needs no grant.
	{name = "requests_reader", scope = .Session},
	// The asker of the measures of the record outputs: it starts its
	// readers and its writer with a wiring list, and reads its own grants
	// between two runs. Start, Wire and Grants are commands of the root ring.
	{name = "output_measure", scope = .Session, grants = {.Root_Ring}},
	// Its writer and its readers: their ends come in their wiring rings
	// before their first instruction, and they need no grant.
	{name = "output_measure_writer", scope = .Session},
	{name = "output_measure_reader", scope = .Session},
	// The two rows of the test of the restarts of a start policy, which only
	// the image of the test of the rescue holds: each stops itself at once,
	// and needs no grant.
	{name = "stops_refused", scope = .Session},
	{name = "stops_failed", scope = .Session},
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
system_part_names := [?]string{"root", "input", "compositor", "terminal", "serial_terminal", "grid_terminal", "dom_terminal", "block", "frame", "iommu_device", "tpm", "entropy", "sound", "gpu_device", "wiring", "powerbox", "disk_processes", "devices", "principals"}

// name_is_a_system_part says if a name is one of system_part_names.
name_is_a_system_part :: proc "contextless" (name: string) -> bool {
	for part in system_part_names {
		if name == part {
			return true
		}
	}
	return false
}

// Closed list of machine-scope processes allowed to serve connections of a
// named principal (src/md/features/several_principals.md, "The services that
// keep data"). Every other service is session-scoped.
@(rodata)
joint_process_names := [?]string{
	"storage",
	"log",
	"scheduler",
	"principals",
	"powerbox",
	"disk_processes",
	"compositor",
	"input",
	"sound",
	"network",
	"unlock",
	"tpm",
	"remote",
	"remote_display",
	"date",
}

// name_is_a_joint_process reports whether `name` is in the closed list of
// machine-scope processes permitted to serve named principals.
name_is_a_joint_process :: proc "contextless" (name: string) -> bool {
	for joint in joint_process_names {
		if name == joint {
			return true
		}
	}
	return false
}

// service_scope_of returns the declared scope of a module in start_grant_sets,
// defaulting to .Session for any unlisted module.
service_scope_of :: proc "contextless" (name: string) -> Service_Scope {
	for &row in start_grant_sets {
		if row.name == name {
			return row.scope
		}
	}
	return .Session
}

// start_grant_set_of gives the start grant set of a process of the boot image by its name: the
// grants and the terms of its row. A name with no row has the zero start grant set:
// it names no module of the boot image, as the tool checks. Only a start
// reads it.
start_grant_set_of :: proc "contextless" (name: string) -> (start_grant_set: Start_Grant_Set) {
	for &row in start_grant_sets {
		if row.name == name {
			start_grant_set.scope = row.scope
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
		// A callable name can be a role name: it allows the holder of the
		// role in force, whichever module a plan gave it to, and nothing
		// when the role has no holder.
		if resolved, has_holder := role_target_resolve_strict(name); has_holder && resolved == service {
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
	if name == "powerbox" {
		return true
	}
	return start_grant_set_of(name).on_demand
}
