package console

import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import info "modus:contract/boot_info"
import "modus:contract/isolated"
import op "modus:contract/operation"
import module "modus:contract/module"
import "modus:contract/remote"
import "modus:contract/ring"
import "modus:contract/start_grant"
import "modus:contract/text_encoding"
import "modus:contract/value_kinds"
import "modus:disk_process"
import "modus:principals"
import "modus:random"
import "modus:contract/root_ring"
import "modus:contract/enum_word"
import "modus:lex_parser"
import "modus:system"
import "base:intrinsics"

// A command: a function with typed parameters and a typed result.
//
// The console is a process that reads one line at a time and runs it as an
// expression of a small language: `name = expression`, or an expression
// alone. A call is `name(argument, ...)`. Each argument is a number, a text
// in quotes, a variable, or the result of another call. The console checks
// the kind of each argument against the parameter before the call. A
// command gives a result and never prints: the console draws the result of
// the line by its kind. No process parses text: the text of the line stops
// at the console.
//
// A command comes from one of three places:
//
// - **The console itself**: the built-in commands that this page lists.
//   They exist before any module is loaded.
// - **A module of the boot image** that `load("sample")` or
//   `isolate("sample")` adds: each export of the module becomes a command
//   with the name of the export, and each record of its description becomes
//   a command that makes a record from its fields.
// - **A service that runs**, which `connect("monitor")` reaches: each export
//   becomes a command named `service.export`, as `monitor.processes()`.
//
// The name, the kinds and the help of a command of a module come from the
// description of its export: the console types nothing for it. When two
// commands have one name, the command added last is the one that runs: the
// module `probe` exports `count`, so the console names its own count of rows
// `rows`.
//
// **The kinds of a value.** A result is an `Integer`, a `Text`, a `Record`,
// a `Handle`, a `Table` or `Bytes`. A command whose result is `None` does
// something and gives nothing. A command that lists things gives a `Table`,
// so `where`, `sort` and `columns` take it as they take the table of an
// export: `where(grants("notes"), state = "held")`. A parameter of the
// kind `Value` takes any kind, and the command checks it.
//
// **Tables compose.** A `Table` is the records of one description, one
// after the other. The console holds a table as one value and passes it to
// the next call with no parsing: `where`, `sort`, `join`, `columns`,
// `first`, `rows` and `row` read only the description of the records, so
// they work on each table of each service. Example:
//
// ```
// > columns(where(manual.running(), module = "calendar_fixed"), process, slot, module, replaces)
// ```
//
// **A variable keeps a value** for the lines after it: `t = readings(4)`,
// then `sum_values(where(t, sensor = 2))`. The console keeps 16 variables.
// `variables()` lists them.
//
// **Errors.** A command that fails gives no value, and the line has an
// error: the rest of the line does not run. The console draws the error as
// one line that starts with `error: `, then the values of its error record
// when a call gave one. A wrong argument is refused before the call, with
// the argument and the two kinds:
// "error: sum_values: argument 1 is Table(Reading, Read), not
// Table(Reading)".
//
// The keys of the line, the completion list and the line history: (docs/CONSOLE.md, "1. The keys").
Command :: struct {
	name:            string,
	parameters:      [ARGUMENT_CAPACITY]Kind,
	parameter_names: [ARGUMENT_CAPACITY]string, // From the description of an export. "": no name.
	parameter_units: [ARGUMENT_CAPACITY]value_kinds.Integer_Unit, // What the Integer of each parameter counts, as a built-in command or the description of an export states it. {}: a plain number.
	parameter_count: int,
	parameter_forms: [ARGUMENT_CAPACITY]Parameter_Form, // What the parser reads for each parameter: an expression, but for a few built-in commands.
	result:          Kind,
	about:           string,
	run:             proc "contextless" (arguments: []Value) -> Value, // A command of the console itself.
	address:         uintptr, // Not 0: an export of a module in this process. The call is direct.
	sandbox:         int, // Not 0: an export of sandboxes[sandbox - 1]. The call is isolated.
	export:          u32, // The index of the export in its module.
	function:        module.Function, // The description of the export: the details of its types.
	file:            []u8, // The module of the description.
	record:          u32, // Not 0: the command makes a record with this description of file, from its fields.
	// Not 0: the number, from 1, of the parameter of the export that is its
	// table of error details. The console gives the table; the input does
	// not write it, so parameter_count does not count it.
	details_parameter: int,
	// A command of the console whose first parameter, a Table, takes a
	// Stream too: it reads each row as it comes (where, first, table).
	takes_stream: bool,
	// A command whose last parameter a call may leave out: start(name) and
	// start(name, list).
	optional_last: bool,
}

// The places of the table of error details that the console gives to an
// export (docs/MODULE_CONTRACT.md, section 8, "The table of error details").
ERROR_DETAILS_CAPACITY :: 16

// A process that executes the isolated calls of the console. It is a call
// host with a module (a sandboxed process that the console starts), or a
// service that runs and serves its own exports (the console has a
// connection to it).
Sandbox :: struct {
	name:          string,
	service:       bool, // A service that runs: the console does not start it and does not stop it.
	quiet:         bool, // A service that the console connected to for itself, to read the log records of a line: its exports are no commands yet.
	hash:          [32]u8, // A service: the hash of the file of the process.
	// A call host: the files that it loads, in the boot image: the module,
	// its imports, and the modules of the replacements. files_memory has the
	// list of the files and the replacements (isolated.VALUE_FILE_ADDRESS).
	files:              [FILE_CAPACITY]^info.Image_Entry,
	file_count:         int,
	file_offsets:       [FILE_CAPACITY]u64, // Where each file is, from isolated.FILE_ADDRESS.
	files_memory:       system.Handle,
	files_size:         u64,
	replacement_offset: u64,
	replacement_count:  u64,
	// A module from memory (isolate_memory): the copy of its file in a
	// memory object of the console, mapped at module_address, and its entry
	// in the list of the files. 0: the module is a file of the boot image.
	module_memory:      system.Handle,
	module_address:     rawptr,
	module_entry:       info.Image_Entry,
	process:       system.Handle, // 0: no call host runs, or no connection exists. The next call makes one.
	ring_memory:   system.Handle,
	ring:          ring.Ring,
	region_memory: system.Handle,
	region:        []u8,
	calls:         u32, // The tag of the last call.
}

SANDBOX_CAPACITY :: 12
// The log records of each second of the call host of a sandbox. The
// console gives them from its own 1000 (op.LOG_RECORDS_OF_A_PROCESS): the
// twelve call hosts take 600, and the console keeps 400 for its own lines.
SANDBOX_LOG_RECORDS :: 50
FILE_CAPACITY :: system.MODULE_SPACE_CAPACITY + system.IMPORT_CAPACITY

// A sandbox with no name is free.
sandboxes: [SANDBOX_CAPACITY]Sandbox
prepared: system.Prepared_Modules // The shared code of the call hosts.

// sandbox_free gives a free sandbox, and its number. 0: all have a user.
sandbox_free :: proc "contextless" () -> (sandbox: ^Sandbox, number: int) {
	for &item, index in sandboxes {
		if item.name == "" {
			return &item, index + 1
		}
	}
	return nil, 0
}
image_memory: system.Handle

COMMAND_CAPACITY :: 512
LOADED_CAPACITY :: 8

// A module that the console loaded.
Loaded :: struct {
	hash:    [32]u8,
	name:    string, // In the boot image; for a module from memory, in its sandbox, which unload sets to zero.
	file:    []u8, // In the boot image.
	place:   int, // A direct load: the place of the module in `space`.
	sandbox: int, // Not 0: the module is in sandboxes[sandbox - 1].
}

loaded: [LOADED_CAPACITY]Loaded
loaded_count: int

// The modules that load put in the console, with their imports. The load
// source is the boot image: what the root service granted.
space: system.Module_Space

// The replacement table of the machine: the root service writes it, the
// console reads it before each load.
replacement_table: ^system.Replacement_Table
replacement_records: [system.REPLACEMENT_CAPACITY]module.Replacement

// source_now gives the source of a load: the boot image, and the replacements
// of the machine at this time.
source_now :: proc "contextless" () -> system.Load_Source {
	return {image = image, replacements = system.replacements_read(replacement_table, &replacement_records)}
}

commands: [COMMAND_CAPACITY]Command
command_count: int

machine: system.Handle
image: []u8
debug_names: system.Debug_Names // The debug image and the verdicts of its objects: the names of a stop report. Used by the thread that runs the lines only.
requests: ring.Ring
requests_memory: system.Handle
request_count: u32 // The tag of the last command to the root service.
abandoned_connects: system.Abandoned_Connects

// The names of the commands of services: "process.export".
names: [16384]u8
names_count: int

// units: what the Integer of each parameter counts, in the order of the
// parameters; a command whose numbers are plain counts gives none. forms:
// what the parser reads for each parameter; none is an expression each.
// optional_last: a call may leave out the last parameter. The site reads
// these arguments from the line of each command
// (tools/modustool/foundation/site_source_readers.odin), so a command is
// one line, with its named arguments on it.
command :: proc "contextless" (name: string, parameters: []Kind, result: Kind, about: string, run: proc "contextless" (arguments: []Value) -> Value, units: []value_kinds.Integer_Unit = nil, forms: []Parameter_Form = nil, optional_last := false) {
	item := &commands[command_count]
	item^ = {name = name, parameter_count = len(parameters), result = result, about = about, run = run, optional_last = optional_last}
	copy(item.parameters[:], parameters)
	copy(item.parameter_units[:], units)
	copy(item.parameter_forms[:], forms)
	command_count += 1
}

// commands_start maps what the root service granted, and lists the commands.
commands_start :: proc "contextless" () {
	machine = ctx.handles[system.GRANT_MACHINE]
	image_memory = ctx.handles[system.GRANT_IMAGE]
	if address, status := system.memory_map(image_memory, {}); status == .Ok {
		image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	}
	debug_names = system.debug_names_of(ctx)
	requests_memory = ctx.handles[system.GRANT_ROOT]
	requests, _ = system.ring_open(requests_memory, receive_handles = true)
	if address, status := system.memory_map(ctx.handles[system.GRANT_REPLACEMENTS], {}); status == .Ok {
		replacement_table = (^system.Replacement_Table)(address)
	}
	space.next = op.MODULE_BASE

	// The comment above each command is its documentation on the site: the
	// help after the name is the text that help() gives in its row.

	// Gives one row for each command that the console can call now: its
	// name, its signature, and its help.
	//
	// The table grows with each `load`, `isolate` and `connect`, and
	// shrinks with each `unload`: it is the command table of this moment,
	// not a fixed list. In a signature, a parameter shows its name when the
	// description of the export gives one, and `Value` when it takes any
	// kind; the result follows `->`, and a command with no `->` gives
	// nothing. A help longer than its field ends with the cut mark:
	// `describe(name)` gives it whole.
	//
	// `help` takes no argument: `describe(name)` gives the help on one
	// name, and `help("let")` says so.
	//
	// ```
	// > where(help(), name = "repeat")
	// name    signature                      about
	// repeat  repeat(Text, Integer) -> Text  a text, several times
	// 1 row of Command
	// ```
	command("help", {}, .Table, "the commands, one row each", help)
	// Gives the help on one name, as a `Text`: a command gives its
	// signature and its whole help; a word of Lex (`let`, `in`, `with`,
	// `|>`, `_`, `=>`, `function`, `[`, `list`, `if`) or a name of the
	// evaluation (`map`, `filter`) gives a short guide with an example;
	// `where` and `connect` give both.
	//
	// - `name`: the name of a command, as `help()` gives it, or a word
	//   of Lex.
	//
	// ```
	// > describe("let")
	// > describe("where")
	// ```
	//
	// Error: "no command and no word of Lex has the name ...", with the
	// names near it.
	command("describe", {.Text}, .Text, "the help on one name: a command or a word of Lex", describe)
	// Gives one row for each process that runs: the export `processes` of
	// the service `monitor`, under a short name.
	//
	// The list of the processes is a fact of a service, not of the console:
	// the command connects to `monitor` when the console has no connection
	// to it yet, and calls `monitor.processes()`. The rows are those of that
	// export: the slot, the name, the state, the resident and the mapped
	// pages, the handles, the
	// threads, the processor time and the kernel entries of each process,
	// and the hash of the file of a disk process, whose name is its
	// nickname.
	//
	// ```
	// > columns(where(processes(), state = "waiting"), slot, name, threads)
	// > columns(where(processes(), name = "visitor"), name, hash)
	// ```
	//
	// Errors: those of `connect("monitor")` when the service does not run,
	// and those of the export.
	command("processes", {}, .Table, "the processes that run: monitor.processes()", processes_of_monitor)
	// Gives one row for each module of each process that runs: the slot and
	// the name of the process, the module, the module that it replaces, the
	// head of its hash, and the writer of the record.
	//
	// The rows are the module records of the kernel: what the loader of
	// each process recorded. `replaces` is empty when the module is in no
	// place but its own. `writer` is `starter` when the starter of the
	// process wrote the record, which the process cannot change, and
	// `process` when the process wrote it for itself.
	//
	// It needs the grant **machine**: the console asks the kernel with
	// `Inspect` on the machine handle. Without it: "error: the console has
	// no grant to inspect the machine".
	command("process_modules", {}, .Table, "the modules of each process that runs", process_modules)
	// Gives the memory of the machine and the counters of the kernel, as
	// one `Record`.
	//
	// The fields: the memory and the free memory in MiB, the used pages,
	// the pages that a budget paid for and that have no page frame yet, the
	// pages of the budgets, the free pages that no budget holds (0 when
	// each page is free or paid), the count of memory objects, of kernel
	// entries, of interrupts and of processors.
	//
	// It needs the grant **machine**, as `process_modules()`.
	command("memory", {}, .Record, "memory and kernel counters", show_memory)
	// Gives one row for each kind of lock of the kernel: its name, the
	// count of its waits and the count of its takes.
	//
	// It needs the grant **machine**, as `memory()`.
	command("locks", {}, .Table, "the waits and the takes of each kind of kernel lock", list_locks)
	// Gives one row for each module of the boot image: its name, its bytes
	// and the head of its BLAKE3 hash, the first 8 bytes.
	//
	// These are the names that `load`, `isolate`, `start` and `replace`
	// take. The boot image is the one source of code of the console: it is
	// what the root service granted, with the grant **image**.
	command("modules", {}, .Table, "the modules of the boot image", list_modules)
	// Loads a module of the boot image into the memory of the console, and
	// makes each of its exports a command: a call is a direct call, with no
	// other process.
	//
	// - `name`: the name of a module of the boot image, as `modules()`
	//   gives it.
	//
	// The loader checks the hash of the file against the boot image, loads
	// its imports, and applies the replacement table of this time. The
	// result is a `Record`: the module, the count of its commands, how a
	// call runs (`direct`), and the head of its hash. `loaded()` then lists
	// its imports, with the module that the loader gave in the place of
	// each one. The module runs with the memory and every handle of the
	// console: load only a module that the console trusts, and `isolate`
	// the others.
	//
	// ```
	// > load("sample")
	// Loaded
	//   module     sample
	//   commands   12
	//   call       direct
	//   hash_head  <the first 8 bytes of its hash>
	// ```
	//
	// Errors: no module has the name; the module is loaded already; it
	// exports no command (`start` runs a process); no room for its commands
	// (512 commands, 8 modules); the hash differs from the boot image; the
	// loader refuses the file, with the stage and the reason.
	command("load", {.Text}, .Record, "load a module here: direct calls", load_module)
	// Loads a module of the boot image into a new sandboxed process, a call
	// host, and makes each of its exports a command: a call is an isolated
	// call through a call ring.
	//
	// - `name`: the name of a module of the boot image.
	//
	// The call host receives its call ring, its call region, the log, and
	// the files of the module and of its imports, read-only: no other
	// handle. A fault of the module stops the call host, not the console:
	// the error of the line has the stop report, with the instruction and
	// the frames. Escape during a call stops the call host. The arguments
	// and the results go through the call region, so a table result is
	// limited by its size. The result is the `Record` of `load`, with the
	// call `isolated`.
	//
	// Errors: as `load`; also "no room for a sandboxed process" when 8
	// sandboxes run, and "cannot start a sandboxed process" when the budget
	// of the console cannot pay for it.
	command("isolate", {.Text}, .Record, "load a module in a sandboxed process", isolate_module)
	// Loads a module file that a memory object holds into a new call host,
	// and makes each of its exports a command, as `isolate` does for a
	// module of the boot image. The module that `assemble` wrote is such a
	// file.
	//
	// - `name`: the name of the module in the console: 1 to 31 ASCII
	//   letters, digits and `_`, with no digit first.
	// - `memory`: the memory object that holds the file from its first byte.
	// - `size`: the bytes of the file, 1 to 4 MiB.
	//
	// The console copies the bytes into a memory object of its own, checks
	// the copy with `module.validate`, and computes its hash; the log has
	// the hash. A later write into `memory` changes nothing. The call host
	// receives the copy as its one file: a module from memory takes no
	// import. The result is the `Record` of `load`, with the call
	// `isolated`.
	//
	// ```
	// > f = buffer(4)
	// > n = assemble("export add(a: Integer, b: Integer) -> Integer; add: mov %rdi, %rax; add %rsi, %rax; ret", f)
	// > isolate_memory("adder", f, n)
	// ```
	//
	// Errors: the name is no name; a size of 0 or past the object or past
	// 4 MiB; the handle names no memory object; the bytes are no module
	// file; the module imports a module; a module with the name or the same
	// bytes is loaded; it exports no command; no room for a sandbox or for
	// its commands.
	command("isolate_memory", {.Text, .Handle, .Integer}, .Record, "isolate the module file of a memory object", isolate_from_memory)
	// Removes a module that `load` or `isolate` added: its commands leave
	// the command table.
	//
	// - `name`: the name of the module, as `load` or `isolate` took it.
	//
	// After `isolate`, the call host stops: the console closes its handles,
	// and the kernel stops a process that no handle names. After `load`, the
	// module leaves the memory of the console, unless another loaded module
	// imports it: one copy serves both. The result is a `Record`: the
	// module, the count of the commands removed, and what became of its
	// memory.
	//
	// ```
	// > unload("sample")
	// Unloaded
	//   module    sample
	//   commands  12
	//   memory    left the console
	// ```
	//
	// Error: "load and isolate added no module with the name ...".
	command("unload", {.Text}, .Record, "remove a module that load or isolate added", unload_module)
	// Gives one row for each module and each service whose exports are
	// commands of the console, and one row for each import of such a
	// module.
	//
	// The fields: the module; how a call runs (`direct`, `isolated`,
	// `service`); for an import, the module that imports it and, when the
	// loader gave another module in its place, the module that the import
	// names; the head of its hash.
	//
	// ```
	// > where(loaded(), in_place_of = "calendar")
	// ```
	command("loaded", {}, .Table, "the modules and the services whose exports are commands", list_loaded)
	// Asks the root service for a connection to a service that runs, and
	// makes each export of the service a command named `service.export`.
	//
	// - `name`: the name of the service, as `processes()` gives it.
	//
	// The root service decides: it refuses a service that the console may
	// not call, with its reason. It gives a call ring, a call region and the
	// hash of the file of the process; the console reads the descriptions of
	// the exports from that file in the boot image. A call then runs in the
	// service, with the rights of the service, and the service checks its
	// caller. When the service stops, the console ends the connection. The
	// result is the `Record` of `load`, with the call `service`; a service
	// that is connected already gives it again.
	//
	// ```
	// > connect("settings")
	// Loaded
	//   module     settings
	//   commands   3
	//   call       service
	//   hash_head  <the first 8 bytes of its hash>
	// ```
	//
	// Errors: the root service refused, with its error record; the service
	// exports no command; no room for its commands.
	command("connect", {.Text}, .Record, "call the exports of a service that runs", connect_service)
	// Asks the root service to start a process from a module of the boot
	// image. It gives nothing.
	//
	// - `name`: the name of the module, which becomes the name of the
	//   process.
	//
	// The root service gives the process the grants of its name, and only
	// those (the reference page of the grants lists them). `processes()`
	// then has its row.
	//
	// - `list`: a wiring list, which the call may leave out: a `Table` of
	//   `Wiring`, as `wire(from, to)` gives it and `+` joins it. Each row
	//   names the module at one end; the root service makes each wiring
	//   before the first instruction of the process, so its first record
	//   reaches each reader.
	//
	// When the module declares a record output, the console keeps the
	// handle of the process while it runs, and a line reads each record
	// output by its typed name: `output_counter.counts` (docs/CONSOLE.md,
	// "Streams").
	//
	// ```
	// > start("output_count_reader", wire(where(output_counter.counts, status = 404), output_count_reader.counts))
	// ```
	//
	// Errors: the error record of the root service when it refuses (no
	// module has the name, the process runs already, no slot is free, a
	// row of the list, a record input of the count One wired twice), and
	// "the root service did not answer" after 3 seconds; a list that is no
	// Table of Wiring, a row that names no end of the module or names it
	// twice, an end that does not run, a list past its 32 rows or its 16
	// lent handles; the console keeps the handles of 8 started processes
	// with a record output at most.
	command("start", {.Text, .Table}, .None, "start a process, by module name, with a wiring list or none", start_process, optional_last = true)
	// Starts the editor `edit` on a text object of a store of the principal
	// of this console. It gives nothing.
	//
	// - `store`: the name of a store of this principal, as `storage.stores()`
	//   lists it, 1 to 31 bytes.
	// - `name`: the name or `/`-separated path of the text object in that
	//   store, 1 to 256 bytes.
	//
	// ```
	// > edit("notes", "today.txt")
	// ```
	//
	// Errors: invalid store name or object path; the store belongs to another
	// principal or the console lacks `acts_for_principal`; the root service
	// refused the start or did not answer.
	command("edit", {.Text, .Text}, .None, "edit a text object of a store in the editor", edit_object)
	// Asks the root service to start a disk process: a process whose module
	// file is an object of the store `module_files` of the storage service, and
	// not a file of the boot image. It gives nothing.
	//
	// - `name`: the nickname of the process: the name of its entry in the
	//   store, 1 to 23 bytes.
	// - `hash`: the BLAKE3 hash of the module file, 64 hexadecimal digits.
	//   The tool that wrote the file prints it. An empty text takes the hash
	//   that the nickname names in the disk grant table.
	//
	// The root service reads the object and starts its bytes only when
	// their hash is `hash`: the storage service does not choose what runs.
	// The process receives the log and a window, and the grants of its
	// nickname in the disk grant table only, whatever its name
	// (docs/MODULE_CONTRACT.md, "A module from a disk").
	//
	// ```
	// > start_from_disk("visitor", "5f0c...")
	// > start_from_disk("visitor", "")
	// ```
	//
	// Errors: the name or the hash has a wrong form; the store has no
	// object with the name; the bytes have another hash; the nickname
	// names another file, or no file for an empty hash; a module of the
	// boot image has the name, or the root service gives the name a grant;
	// another load runs; the loader refuses the file; the storage service
	// stopped or gave no answer.
	command("start_from_disk", {.Text, .Text}, .None, "start a module of the store module_files, by nickname and hash", start_from_disk)
	// Gives a grant to the file that a nickname names, from its next start
	// (docs/MODULE_CONTRACT.md, "The grants of a disk process"). It gives
	// nothing.
	//
	// - `nickname`: the nickname of a disk process: letters, digits, `-`
	//   and `_`, 1 to 23 bytes. Its row in the disk grant table, or the
	//   disk process of that nickname that runs, gives the file.
	// - `grant`: the name of a start grant. A command gives `store` only:
	//   the store of the nickname, which follows the nickname to its next
	//   file.
	//
	// ```
	// > allow("visitor", "store")
	// ```
	//
	// Errors: the nickname has a wrong form, no row and no process that
	// runs; the grant is one that no command gives to a disk process (the
	// ring of the root service, the machine, a device, the principal), or
	// one that is not built; the table is full.
	command("allow", {.Text, .Text}, .None, "give a disk process a grant, by nickname", allow)
	// Takes a grant from the file that a nickname names, from its next
	// start. The store stays on the disk; `revoke` ends the grant of a
	// process that runs. It gives nothing.
	//
	// - `nickname`: the nickname of a disk process with a row.
	// - `grant`: the name of the grant: `store`.
	command("disallow", {.Text, .Text}, .None, "take a grant from a disk process, by nickname", disallow)
	// Allows the key of a client of the process `remote` for the principal
	// of this console: each call of that client, from another machine,
	// acts for this principal (docs/PRINCIPALS.md, "The client keys of
	// remote"). It gives nothing.
	//
	// - `key`: the Ed25519 public key of the client, 64 hexadecimal
	//   digits. `modustool run` prints the key of its peer.
	//
	// ```
	// > remote_allow("6a1f...")
	// ```
	//
	// The grant lasts until `remote_disallow`, and holds no call while the
	// session of the principal is locked. It is a key of the disk grant
	// table of the principal, so it lasts across a restart of the machine
	// when that table does: principal 0 needs a machine passphrase or a
	// machine key sealed by the TPM, and `disk_persistence("", "forget")`
	// keeps it until the machine stops.
	//
	// Errors: this console does not act for its principal; the key has a
	// wrong form; another principal allowed the key; the principal has 4
	// keys, or the table is full; the disk grant table of the principal
	// takes no change now (the log says why).
	command("remote_allow", {.Text}, .None, "let a client of remote call for the principal of this console, by its key", remote_allow)
	// Allows the key of a viewer of the process `remote_display` for the
	// principal of this console: the viewer sees the screen, and with the
	// input its keys and its pointer go to the desktop as the keys of this
	// principal (src/md/features/remote_display.md). While a viewer is
	// connected, the bar shows the mark `viewer`. It gives nothing.
	//
	// - `key`: the Ed25519 public key of the viewer, 64 hexadecimal digits.
	// - `use`: `view`, or `view_and_input`.
	//
	// ```
	// > remote_display_allow("6a1f...", "view")
	// ```
	//
	// An allow of a key that the principal allowed already adds the use to
	// it. The grant lasts until `remote_disallow`, which ends every use of
	// the key, and holds nothing while the session of the principal is
	// locked. The view and the input last until the machine stops: no disk
	// grant table keeps them.
	//
	// Errors: the use is not `view` or `view_and_input`; this console does
	// not act for its principal; the key has a wrong form; another
	// principal allowed the key; the principal has 4 keys, or the table is
	// full.
	command("remote_display_allow", {.Text, .Text}, .None, "let a viewer of remote_display see the screen, or see it and type, for the principal of this console", remote_display_allow)
	// Revokes the key of a client of `remote` that the principal of this
	// console allowed. `remote` ends the open connection of the client, and
	// refuses the key in its next handshake. It gives a sentence with the
	// count of the connections to services that ended, and says when the
	// disk grant table did not take the revocation: the key can then come
	// back at the next start of the machine.
	//
	// - `key`: the key, as `remote_allow` took it.
	//
	// ```
	// > remote_disallow("6a1f...")
	// 4 connections to services ended
	// ```
	//
	// Errors: the principal of this console did not allow the key.
	command("remote_disallow", {.Text}, .Text, "end the grant of a client key of remote", remote_disallow)
	// Gives one row for each key of a client of `remote` that the principal
	// of this console allowed, with its state: `holds` (each call of the
	// client acts for the principal), `locked` (the session of the
	// principal is locked), or `contested` (another principal allowed the
	// key too, one in this run and one in its disk grant table: it acts for
	// neither until one of them revokes it), and its uses: `calls` (of
	// `remote`), `view` and `view and input` (of `remote_display`), or both.
	//
	// ```
	// > remote_clients()
	// key                                                               principal  state      uses
	// 6a1f...                                                                   0  holds      calls
	// 1 row of Remote_Client
	// ```
	command("remote_clients", {}, .Table, "the client keys of remote that the principal of this console allowed", remote_clients)
	// Points a nickname to another file: its grants and its store follow.
	// The log says "root: the file HASH will get the data of NICKNAME"
	// before the change. It gives nothing.
	//
	// - `nickname`: a nickname with a row in the disk grant table.
	// - `hash`: the BLAKE3 hash of the new file, 64 hexadecimal digits.
	//
	// Errors: the nickname has no row; the hash has a wrong form, or is the
	// hash of its file already.
	command("nickname_move", {.Text, .Text}, .None, "point a nickname to another file, with its grants and its store", nickname_move)
	// Sets how long a row of the disk grant table lasts across a restart.
	// A row persists only when its principal has a key for the table: for
	// principal 0, the machine passphrase. It gives nothing.
	//
	// - `nickname`: a nickname with a row, or no byte for the global
	//   setting of the table.
	// - `setting`: `persist`, `forget` (the row lasts until the machine
	//   stops), or `global` (the row follows the global setting). The
	//   global setting takes `persist` or `forget`; the default is
	//   `persist`.
	//
	// ```
	// > disk_persistence("visitor", "forget")
	// ```
	//
	// Errors: the nickname has no row; the setting is not one of these;
	// the machine passphrase is not typed yet.
	command("disk_persistence", {.Text, .Text}, .None, "how long a grant of a disk process lasts across a restart", disk_persistence)
	// Asks the root service to stop a process that runs. It gives nothing.
	//
	// - `name`: the name of the process, as `processes()` gives it.
	//
	// `stop("console")` stops this console: it saves its line history
	// first, because the save after the line never comes.
	//
	// Errors: the error record of the root service when it refuses, and
	// "the root service did not answer".
	command("stop", {.Text}, .None, "stop a process, by name", stop_process)
	// Gives one row for each grant that a process has or lost, of the
	// grants that the root service records and can revoke.
	//
	// - `name`: the name of a process that runs.
	//
	// The fields: the process; the grant (log, machine, image, log_records,
	// store, network, acts_for_principal, history); its state, `held` or
	// `lost`; the number and the name of the principal that the process
	// runs for.
	//
	// ```
	// > grants("notes")
	// process  grant  state  principal  principal_name
	// notes    log    held           0  machine
	// notes    store  held           0  machine
	// 2 rows of Grant
	// ```
	//
	// Error: the error record of the root service when no process has the
	// name.
	command("grants", {.Text}, .Table, "what a process has from the root service", grants)
	// Asks the root service to end one grant of a process that runs, and
	// gives the count of the holdings that ended.
	//
	// - `name`: the name of the process.
	// - `grant`: the name of the grant, as `grants()` gives it.
	//
	// The root service closes each handle that came from the grant and
	// records the loss: `grants()` then gives it with the state `lost`. The
	// process continues, and an operation on a closed handle fails with an
	// error record that says "was revoked".
	//
	// Errors: "no grant has the name ...", with the list of the names; the
	// error record of the root service when it refuses.
	command("revoke", {.Text, .Text}, .Integer, "end a grant of a process that runs", revoke)
	// Asks the root service to create a named principal: a principal whose
	// session opens with a passphrase. It gives nothing.
	//
	// - `name`: the name of the principal.
	//
	// The passphrase is never a text of the console, because the console
	// keeps each line in its history: the window of unlock opens and asks
	// for it. `principals()` then has the row of the principal.
	command("principal_create", {.Text}, .None, "create a named principal: its passphrase is typed in the window of unlock", principal_create)
	// Asks the root service to set the machine passphrase: an optional
	// passphrase of principal 0, the machine, that keeps the disk grant
	// table of principal 0 across a restart. It gives nothing.
	//
	// The passphrase is never a text of the console: the window of unlock
	// opens and asks for it two times. At each start of the machine, the
	// window then asks for it; until it is typed, the disk processes of
	// principal 0 start with no grant.
	//
	// Errors: the machine has a passphrase already; unlock runs.
	command("machine_passphrase", {}, .None, "set the machine passphrase: it is typed in the window of unlock", machine_passphrase)
	// Asks the root service to seal a new machine key to the measure of the
	// system with the TPM: the window of unlock shows the recovery key one
	// time. It needs Secure Boot that verified the boot program.
	//
	// Errors: the machine has a record of its key already; no TPM service
	// runs; Secure Boot did not verify the boot program; unlock runs.
	command("machine_seal", {}, .None, "seal a machine key to the measure of the system with the TPM: the window of unlock shows its recovery key one time", machine_seal)
	// Asks the root service to run a start policy of the store
	// module_files at the next start of the machine, with the grant
	// Start_Policy only. It gives nothing. The choice is a row of the disk
	// grant table of principal 0, and the TPM measures the start policy
	// into PCR 12 before it runs (`PRINCIPALS.md`, "The start policy of
	// principal 0").
	//
	// - `nickname`: the nickname of the module file, as for
	//   `start_from_disk`.
	// - `hash`: the BLAKE3 hash of the file, 64 hexadecimal digits, or
	//   empty for the hash of the row of the nickname.
	//
	// ```
	// > start_policy_choose("tiny", "5f0c...")
	// ```
	//
	// Errors: the console acts for a named principal; the machine has no
	// machine key, or its machine key needs a passphrase; the nickname has
	// no row and no hash is given; the row names another file, or holds
	// the grant store.
	command("start_policy_choose", {.Text, .Text}, .None, "run a start policy of the store module_files at the next start of the machine", start_policy_choose)
	// Ends the choice of a start policy: the next start runs the default
	// start policy of the boot image. The row of the nickname stays.
	command("start_policy_default", {}, .None, "run the default start policy at the next start of the machine", start_policy_default)
	// Asks the root service to change the passphrase of the named principal
	// of the session of this console, and gives what changed when the
	// window of unlock ends the change.
	//
	// The window of unlock asks for the current passphrase, which the TPM
	// counts when it seals the keys, then for the new one two times. The
	// line waits for the end of the change; Escape ends the wait, and the
	// window goes on. Only a console that the desktop starts during the
	// session acts for the principal: the console of the machine cannot
	// ask.
	//
	// Errors: this console acts for no named principal; its session is
	// locked; unlock runs; the file cannot take the change (the cause
	// follows); the change was cancelled, or failed, and nothing changed.
	command("passphrase_change", {}, .Text, "change the passphrase of the principal of this session: it is typed in the window of unlock", passphrase_change)
	// Asks the root service for a new recovery key of the named principal
	// of the session of this console, and gives what changed when the
	// window of unlock ends the change.
	//
	// The window of unlock asks for the current passphrase, then shows the
	// new recovery key one time; the file is written after Enter. The old
	// recovery key opens no file written after it, and still opens the
	// version from before that the store keeps on the disk. Only the keys
	// sealed by the TPM have a recovery key.
	//
	// Errors: as `passphrase_change()`; the keys under the passphrase alone
	// have no recovery key.
	command("recovery_key_change", {}, .Text, "make a new recovery key for the principal of this session: the window of unlock shows it one time", recovery_key_change)
	// Asks the root service to lock the session of the named principal that
	// is unlocked, and gives the count of the processes of the session that
	// stopped.
	//
	// The window of unlock then asks for the passphrase again.
	command("lock", {}, .Integer, "end the session of the named principal: its processes stop", lock_session)
	// Gives one row for each principal of the machine: its number, its
	// name, its state, the head of its public key, and for principal 0 the
	// head of the measure of the system.
	//
	// Principal 0 is the machine: it has no unlock, and its state is
	// `machine`. The other states: `locked`, `unlocked` (its session runs),
	// and `creating` (created in the window of unlock). An empty measure:
	// the system was not measured.
	//
	// ```
	// > principals()
	// number  name     state    public_key_head  measure_head
	//      0  machine  machine
	// 1 row of Principal
	// ```
	command("principals", {}, .Table, "the principals of the machine", list_principals)
	// Asks the root service to give one module where a module imports
	// another, in each load that follows. It gives nothing.
	//
	// - `name`: the module that an import names.
	// - `by`: the module to give in its place; the text `""` removes the
	//   replacement of `name`.
	//
	// The replacement table belongs to the machine: the root service writes
	// it, and each loader reads it at each load. A process that runs keeps
	// the modules that it loaded. `replacements()` gives the table. The
	// root service adds a replacement only for a pair that a replacement
	// row of the boot image names, signed by the signing key of the system
	// (docs/MODULE_CONTRACT.md, "Who may replace a module"); a removal
	// needs no row.
	//
	// Errors: no module has the name; the console has no grant to change
	// the table; a chain of replacements is refused; no signed row names
	// the pair; the signature of its row does not verify; the table is
	// full; a module does not replace itself.
	command("replace", {.Text, .Text}, .None, "give the second module where a module imports the first", replace)
	// Gives the replacement table of the machine: one row for each module
	// that a load replaces, with the module that it gets in its place and
	// the heads of the two hashes. No replacement: no row.
	command("replacements", {}, .Table, "the replacement table of the machine", list_replacements)
	// Gives the milliseconds since the machine started, as an `Integer`.
	command("time", {}, .Integer, "milliseconds since boot", time)
	// Gives the BLAKE3 hash of the bytes of a text, as 64 hexadecimal
	// digits.
	//
	// The same hash names a module in the boot image and an object in a
	// store: `hash("")` gives `af1349b9...`.
	command("hash", {.Text}, .Text, "the BLAKE3 hash of a text", hash)
	// Gives the count of bytes of a text, as an `Integer`.
	//
	// `length("kept across a stop")` gives 18.
	command("length", {.Text}, .Integer, "the number of bytes of a text", length)
	// Gives the decimal text of an integer: `text(42) + " pages"` gives
	// `42 pages`.
	command("text", {.Integer}, .Text, "the decimal text of an integer", text)
	// Gives the text of one character of Unicode, from its code point:
	// `character(233)` gives the small letter e with an acute accent, two
	// bytes of UTF-8, so `length(character(233))` gives 2.
	//
	// A line of the console holds ASCII, as the keys give it: this command
	// writes each other character. The terminal shows a character that its
	// font lacks as the replacement glyph, a box.
	//
	// Error: "N is no character of a text", for a control character, a
	// surrogate (55296 to 57343) and a number past 1114111.
	command("character", {.Integer}, .Text, "the text of one character, from its code point", character_text)
	// Gives a text repeated a count of times: `repeat("ab", 3)` gives
	// `ababab`.
	//
	// The texts of one line share 4096 bytes: past them, "error: the text
	// is too long".
	command("repeat", {.Text, .Integer}, .Text, "a text, several times", repeat)
	// Makes a new memory object of a count of pages, paid by the budget of
	// the console, and gives its handle.
	//
	// The console holds the handle until `release`. The console draws a
	// handle with its kind and its rights: "Handle 65541: Memory (Give,
	// Read, Write)". `byte` and `bytes` read it.
	//
	// Error: "the budget of the console cannot pay for N pages".
	command("buffer", {.Integer}, .Handle, "a new memory object, in pages", buffer_create, {value_kinds.size_in(.Pages)})
	// Gives one byte of a memory object, from 0: the console maps the object
	// for the time of the command.
	//
	// A new object holds zero bytes: `byte(buffer(1), 0)` gives 0. Errors: the
	// handle names no memory object, or the object has no byte at that
	// place.
	command("byte", {.Handle, .Integer}, .Integer, "one byte of a memory object", buffer_byte)
	// Gives a count of bytes of a memory object, from a first byte, as
	// `Bytes`: the console maps the object for the time of the command and
	// copies them.
	//
	// - `memory`: a handle of a memory object.
	// - `first`: the place of the first byte, from 0.
	// - `count`: the count of bytes, at most 4096.
	//
	// The console draws `Bytes` as rows of 16 bytes in hexadecimal, with
	// the place of each row and the characters; it draws the first 256
	// bytes and says how many it does not show.
	//
	// Errors: the handle names no memory object; the object does not have
	// these bytes; the count is not 0 to 4096.
	command("bytes", {.Handle, .Integer, .Integer}, .Bytes, "bytes of a memory object", buffer_bytes, {{}, {}, value_kinds.size_in(.Bytes)})
	// Closes a memory object that `buffer` made: the console gives its
	// handle back, and the kernel frees the pages when no handle names the
	// object. It gives nothing.
	//
	// Error: "release closes a memory object that buffer made", for each
	// other handle.
	command("release", {.Handle}, .None, "close a handle", release)
	// Gives one row for each variable: its name, its type and its value as
	// a text.
	//
	// A line `name = expression` makes or changes a variable. The console
	// keeps 16 variables; a table keeps at most 32 KiB of rows. The value
	// of a table is the count of its rows; the value of a record is its
	// fields in one line.
	command("variables", {}, .Table, "the variables", list_variables)
	// Clears the text of the terminal: the edit line becomes the first row
	// of the view. The line history stays. It gives nothing.
	command("clear", {}, .None, "clear the console", clear)
	// Stops the machine: the console saves its line history, then asks the
	// kernel to stop the machine. It gives nothing.
	//
	// It needs the grant **machine**. Without it: "error: the console has
	// no grant to stop the machine".
	command("shutdown", {}, .None, "stop the machine", shutdown)
	// Leaves the child console of a project opened by `projects.enter`,
	// revoking its temporary module connections and store shares and
	// returning control to the parent console. It gives nothing.
	//
	// Error: "exit: no project console is active" when called outside a
	// child project console.
	command("exit", {}, .None, "leave the console of a project", exit_project_console)
	// Forgets the line history, in the memory of the console and in its
	// store, and gives the count of the lines that it forgot.
	//
	// Its object leaves the store with each of its versions. The line
	// `history_clear()` goes too.
	//
	// If the store refuses the removal, the history is still cleared in
	// memory, and the error gives the reason of the store. The design of the
	// history: (docs/CONSOLE.md, "6. The line history across a stop").
	command("history_clear", {}, .Integer, "forget the line history, in memory and in its store", history_clear)
	// Measures the work of one key with the completion list open, for the
	// query `mcnt`, and gives the measure as two rows.
	//
	// It times four parts: the collect of the names, their rank, the text
	// of the rows, and the colors of the code. Each number is the least of
	// 20 batches of 10 keys, in nanoseconds. The first row is for the names
	// of this console; the second for the worst case, 512 names of 128
	// bytes. It also writes each row as a line of the log, in microseconds.
	// It runs in the second thread, so the list on the screen stays. The
	// bounds that it measures: (docs/CONSOLE.md, "4. The bounds, and the cost of one key").
	command("measure_completion", {}, .Table, "measure one key of the completion list", measure_completion)
	// Sets or reads the active CLDR interface locale of the console.
	//
	// - `tag`: `"en"`, `"fr"`, or `""` to read the active locale tag.
	command("locale", {.Text}, .Text, "set or read the active CLDR locale (en or fr)", locale_command)
	// Reads a language tag of BCP 47 into its record, a `Locale`: the
	// language, the script, the region, two variants, the keywords of the
	// extension `u` (`ca`, `nu`, `fw`, `hc`, `ms`, `co`, `rg`), in
	// the canonical form of UTS #35 (`iw` gives `he`).
	//
	// - `tag`: the text of the tag, in any case; the call may leave it
	//   out. With no tag, or `""`, it gives the first language of the
	//   language list of the settings page, and English when the list is
	//   empty.
	//
	// The console reads the text once: an export takes the record, never
	// the text, so no process parses the tag again. `settings.set_languages`
	// takes a table of these records, and `settings.languages()` gives each
	// one with its canonical tag.
	//
	// ```
	// > language("fr-CA")
	// > language("ar-EG-u-nu-latn")
	// > settings.set_languages([language("fr-CA"), language("en")])
	// > language()
	// ```
	//
	// Error: the tag is refused, with the byte of the subtag at fault and
	// the reason: a private use (`-x-`), an extension other than `u`, a
	// key of `u` other than the seven, a value that names no member of
	// its key, a third variant, an extended language, a tag past 128 bytes.
	command("language", {.Text}, .Record, "the record of a language tag, or the first language of the principal", language_command, optional_last = true)
	// Gives one row for each connection of a process to a service: the
	// service, the state of its work account, the pages of its work budget
	// in use and in total, the processor time of its work thread since the
	// connection, and its step debt.
	//
	// - `process`: the name of a process that runs, as `processes()`
	//   gives it.
	//
	// The console knows the connections of its own process only. No
	// service charges a work budget yet: each row has the state
	// `unaccounted` and no numbers, because the service paid the work
	// itself.
	//
	// ```
	// > work("console")
	// ```
	//
	// It needs the grant **machine**, as `memory()`. Errors: the name is
	// empty or past 31 bytes; no process that runs has the name; the
	// process is not this console.
	command("work", {.Text}, .Table, "the work that services did for each connection of a process", work_command)
	// Lists the closed system roles defined by the role contract.
	command("roles", {}, .Table, "the closed system roles", roles_command)
	// Lists the delegated system services (plans, recipes, projects, powerbox, disk_processes, principals, devices, settings).
	command("delegated_services", {}, .Table, "the delegated system services", delegated_services_command)
	// Computes the canonical BLAKE3 tree hash of a one-entry immutable tree.
	//
	// - `name`: entry name inside the tree.
	// - `content`: text bytes hashed as the file leaf.
	command("tree_hash", {.Text, .Text}, .Text, "canonical BLAKE3 hash of an immutable tree entry", tree_hash_command)
	// Compiles C source text in one step via c_compiler and assemble, then isolates the resulting module under name.
	//
	// - `name`: name of the new isolated module in the console.
	// - `source`: C source code whose exported functions become callable commands.
	command("compile_c", {.Text, .Text}, .Record, "compile C source into an isolated module and load its exports", compile_c_command)
	// Builds the C source `file` of the store of a project with the native C
	// builder (recipes.build_c), and puts the module in the store
	// module_files under the name of the project. An unchanged source is
	// substituted: no compile runs. A C error builds nothing, and the log
	// names the byte of the source (src/md/features/program_loop.md).
	//
	// ```
	// > build("hello", "hello.c")
	// hello: module 3f1c…
	// ```
	command("build", {.Text, .Text}, .Text, "build a C source of a project into its module", build_program)
	// Runs the module of a project: it reads the module from the store
	// module_files, isolates it in a call host with no grant, and calls its
	// export main. A grant that the project does not declare is refused.
	//
	// ```
	// > run("hello")
	// 42
	// ```
	command("run", {.Text, .Text}, .Integer, "run the module of a project: its export main", run_program, optional_last = true)
	debugger_commands_start()
	tables_start()
	facts_start() // facts.odin
}

help :: proc "contextless" (arguments: []Value) -> Value {
	columns := [3]Column{text_column("name", 48), text_column("signature", 104), text_column("about", 104)}
	table, made := made_table("Command", columns[:])
	if !made {
		return fail("help: the line has no room for the description")
	}
	for &item in commands[:command_count] {
		row := made_row(&table)
		buffer: [240]u8
		writer := system.Writer {
			buffer = buffer[:],
		}
		_, _ = signature_write(&writer, &item, -1, true)
		made_text(&table, row, 0, item.name)
		made_text(&table, row, 1, system.written(&writer))
		made_text(&table, row, 2, item.about)
	}
	return made_value(&table, "help")
}

// describe gives the signature and the whole help of one command. When two
// commands have the name, it is the one that a call runs: the last one.
describe :: proc "contextless" (arguments: []Value) -> Value {
	return help_topic(arguments[0].text)
}

// command_of_service gives the command of an export of a service that the
// console is connected to, or nil.
command_of_service :: proc "contextless" (service: string, export: string) -> ^Command {
	for &item in commands[:command_count] {
		if item.sandbox == 0 || item.record != 0 || len(item.name) != len(service) + 1 + len(export) {
			continue
		}
		sandbox := &sandboxes[item.sandbox - 1]
		if sandbox.service && sandbox.name == service && item.name[:len(service)] == service && item.name[len(service) + 1:] == export {
			return &item
		}
	}
	return nil
}

// bound_call calls an export of a service under a short name of the
// console: the fact is a fact of the service, and the console calls its
// export as it calls any export. It connects to the service first when the
// console has no connection to it.
bound_call :: proc "contextless" (service: string, export: string, arguments: []Value) -> Value {
	found := command_of_service(service, export)
	if found == nil {
		connect_arguments := [1]Value{{kind = .Text, text = service}}
		connect_service(connect_arguments[:])
		if failed {
			return {}
		}
		found = command_of_service(service, export)
	}
	if found == nil {
		return fail("the service ", service, " has no export ", export, " that the console can call")
	}
	return call_isolated(found, arguments)
}

processes_of_monitor :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("monitor", "processes", arguments)
}

system_report :: proc "contextless" () -> (report: op.System_Report, ok: bool) {
	_, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report))
	if status != .Ok {
		fail("the console has no grant to inspect the machine")
	}
	return report, status == .Ok
}

module_report: op.Module_Report

// process_modules gives the identity of each process: each module that a
// loader put in it, and the module that it replaces (the module records of
// the kernel).
process_modules :: proc "contextless" (arguments: []Value) -> Value {
	report, ok := system_report()
	if !ok {
		return {}
	}
	columns := [6]Column{integer_column("slot"), text_column("process", 32), text_column("module", 32), text_column("replaces", 32), text_column("hash_head", 16), text_column("writer", 8)}
	table, made := made_table("Process_Module", columns[:])
	if !made {
		return fail("process_modules: the line has no room for the description")
	}
	for slot in 1 ..< report.process_slots {
		process: op.Process_Report
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process), slot, u64(uintptr(&process)), size_of(process))
		if process.state == .None {
			continue
		}
		modules := &module_report
		modules^ = {}
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Modules), slot, u64(uintptr(modules)), size_of(modules^))
		for item in modules.modules[:min(int(modules.count), len(modules.modules))] {
			row := made_row(&table)
			head: [16]u8
			made_integer(&table, row, 0, i64(slot))
			made_text(&table, row, 1, system.name_of(process.name[:]))
			made_text(&table, row, 2, module_name_of(item.hash))
			if item.replaces != {} {
				made_text(&table, row, 3, module_name_of(item.replaces))
			}
			made_text(&table, row, 4, hash_head_text(&head, item.hash))
			// A word that names no writer leaves the cell empty, with a line:
			// the table never says who made a claim that no kernel marked.
			if writer, writer_ok := op.module_writer_of_word(item.writer); writer_ok {
				made_text(&table, row, 5, op.module_writer_name(writer))
			} else {
				system.log_fact(.Info, Module_Writer_Refused{base = item.base, slot = u64(slot), writer_word = item.writer})
			}
		}
	}
	return made_value(&table, "process_modules")
}

show_memory :: proc "contextless" (arguments: []Value) -> Value {
	report, ok := system_report()
	if !ok {
		return {}
	}
	columns := [10]Column {
		size_column("memory", .Mebibytes),
		size_column("free", .Mebibytes),
		size_column("used", .Pages),
		size_column("reserved", .Pages),
		size_column("budgets", .Pages),
		// Each page is free or paid: the budgets and the reserved pages
		// hold all the free pages, and this count is 0.
		size_column("free_no_budget_holds", .Pages),
		integer_column("memory_objects"),
		integer_column("kernel_entries"),
		integer_column("interrupts"),
		integer_column("processors"),
	}
	table, made := made_table("Memory", columns[:])
	if !made {
		return fail("memory: the line has no room for the description")
	}
	values := [10]i64 {
		i64(report.page_count * system.PAGE_SIZE >> 20),
		i64(report.free_pages * system.PAGE_SIZE >> 20),
		i64(report.page_count - report.free_pages),
		i64(report.reserved_pages),
		i64(report.budget_pages),
		i64(report.free_pages) - i64(report.reserved_pages) - i64(report.budget_pages),
		i64(report.region_count),
		i64(report.entries),
		i64(report.interrupts),
		i64(report.processors),
	}
	row := made_row(&table)
	for value, index in values {
		made_integer(&table, row, index, value)
	}
	return made_record(&table, "memory")
}

list_locks :: proc "contextless" (arguments: []Value) -> Value {
	report, ok := system_report()
	if !ok {
		return {}
	}
	columns := [3]Column{text_column("lock", 16), integer_column("waits"), integer_column("takes")}
	table, made := made_table("Lock", columns[:])
	if !made {
		return fail("locks: the line has no room for the description")
	}
	for kind in op.Lock_Kind {
		row := made_row(&table)
		made_text(&table, row, 0, op.LOCK_KIND_NAMES[kind])
		made_integer(&table, row, 1, i64(report.locks[kind].waits))
		made_integer(&table, row, 2, i64(report.locks[kind].takes))
	}
	return made_value(&table, "locks")
}

hex_text :: proc "contextless" (bytes: []u8) -> string {
	start := scratch_count
	alphabet := system.HEX_DIGITS
	for b in bytes {
		scratch_text(string([]u8{alphabet[b >> 4], alphabet[b & 0xF]}))
	}
	return string(scratch[start:scratch_count])
}

// module_text gives the name of a module in the boot image, and the start
// of its hash, for a sentence.
module_text :: proc "contextless" (value: [32]u8) -> string {
	hash := value
	start := scratch_count
	if entry := system.image_entry_of(image, hash); entry != nil {
		scratch_text(system.name_of(entry.name[:]), " ")
	}
	hex_text(hash[:8]) // It writes in the scratch memory, after the name.
	scratch_text("...")
	return string(scratch[start:scratch_count])
}

list_modules :: proc "contextless" (arguments: []Value) -> Value {
	columns := [3]Column{text_column("name", 32), size_column("size", .Bytes), text_column("hash_head", 16)}
	table, made := made_table("Module", columns[:])
	if !made {
		return fail("modules: the line has no room for the description")
	}
	for &entry in system.image_entries(image) {
		row := made_row(&table)
		head: [16]u8
		made_text(&table, row, 0, system.name_of(entry.name[:]))
		made_integer(&table, row, 1, i64(entry.size))
		made_text(&table, row, 2, hash_head_text(&head, entry.hash))
	}
	return made_value(&table, "modules")
}

// loaded_record gives the result of load, isolate and connect: the module,
// the count of its commands, how a call runs, and the head of its hash.
loaded_record :: proc "contextless" (name: string, callable: int, how: string, hash: [32]u8) -> Value {
	columns := [4]Column{text_column("module", 32), integer_column("commands"), text_column("call", 8), text_column("hash_head", 16)}
	table, made := made_table("Loaded", columns[:])
	if !made {
		return fail(name, ": the line has no room for the description of its result")
	}
	row := made_row(&table)
	head: [16]u8
	made_text(&table, row, 0, name)
	made_integer(&table, row, 1, i64(callable))
	made_text(&table, row, 2, how)
	made_text(&table, row, 3, hash_head_text(&head, hash))
	return made_record(&table, name)
}

// list_loaded gives the modules and the services whose exports are
// commands, and the imports of the modules: the module that each import
// names, and the module that the loader gave in its place.
list_loaded :: proc "contextless" (arguments: []Value) -> Value {
	columns := [5]Column{text_column("module", 32), text_column("call", 8), text_column("imported_by", 32), text_column("in_place_of", 32), text_column("hash_head", 16)}
	table, made := made_table("Loaded_Module", columns[:])
	if !made {
		return fail("loaded: the line has no room for the description")
	}
	loaded_row :: proc "contextless" (table: ^Made_Table, name: string, how: string, imported_by: string, in_place_of: string, hash: [32]u8) {
		row := made_row(table)
		head: [16]u8
		made_text(table, row, 0, name)
		made_text(table, row, 1, how)
		made_text(table, row, 2, imported_by)
		made_text(table, row, 3, in_place_of)
		made_text(table, row, 4, hash_head_text(&head, hash))
	}
	for &item in loaded[:loaded_count] {
		if item.sandbox != 0 {
			loaded_row(&table, item.name, "isolated", "", "", item.hash)
			sandbox := &sandboxes[item.sandbox - 1]
			for file in sandbox.files[1:max(sandbox.file_count, 1)] {
				loaded_row(&table, system.name_of(file.name[:]), "isolated", item.name, "", file.hash)
			}
			continue
		}
		loaded_row(&table, item.name, "direct", "", "", item.hash)
		placed := &space.modules[item.place]
		for number in 0 ..< int(placed.import_count) {
			record, _ := module.record(placed.file, .Imports, u32(number + 1), module.Import)
			used := &space.modules[placed.import_places[number]]
			loaded_row(&table, module_name_of(used.hash), "direct", item.name, used.hash != record.hash ? module_name_of(record.hash) : "", used.hash)
		}
	}
	for &sandbox in sandboxes {
		if sandbox.service && !sandbox.quiet {
			loaded_row(&table, sandbox.name, "service", "", "", sandbox.hash)
		}
	}
	return made_value(&table, "loaded")
}

// load_module loads a module in the console: a call of its exports is a
// direct call. The module has the memory and the handles of the console.
load_module :: proc "contextless" (arguments: []Value) -> Value {
	return add_module(arguments[0].text, false)
}

// isolate_module loads a module in a call host: a call of its exports is an
// isolated call. The module has no handle and no memory of the console.
isolate_module :: proc "contextless" (arguments: []Value) -> Value {
	return add_module(arguments[0].text, true)
}

// add_module makes each export of a module of the boot image a command: the
// description of the export in the module gives its name, its types and its
// help. The description is the same for a direct call and an isolated call.
add_module :: proc "contextless" (name: string, isolate: bool) -> Value {
	for &entry in system.image_entries(image) {
		if system.name_of(entry.name[:]) != name || entry.offset > u64(len(image)) || entry.size > u64(len(image)) - entry.offset {
			continue
		}
		file := image[entry.offset:][:entry.size]
		if blake3.hash(file) != entry.hash || module.validate(file) != .None {
			return fail("the module ", name, " does not have the hash that the boot image names")
		}
		for &item in loaded[:loaded_count] {
			if item.hash == entry.hash {
				return fail("the module ", name, " is loaded; unload(\"", name, "\") removes it")
			}
		}
		callable := callable_count(file)
		if callable == 0 {
			return fail("the module ", name, " exports no command; start(\"", name, "\") starts a process")
		}
		if loaded_count == LOADED_CAPACITY || command_count + callable + record_command_count(file) > COMMAND_CAPACITY {
			return fail("no room for the commands of ", name)
		}
		base: u64
		number := 0
		place := -1
		if isolate {
			sandbox: ^Sandbox
			sandbox, number = sandbox_free()
			if sandbox == nil {
				return fail("no room for a sandboxed process")
			}
			sandbox^ = {
				name = system.name_of(entry.name[:]),
			}
			if !sandbox_create(sandbox, file) {
				sandbox^ = {}
				if load_error.stage != u32(module.Load_Stage.None) {
					load_details.count = 0 // A call host gives no details of its load.
					return fail_load("cannot isolate ", name)
				}
				return fail("cannot start a sandboxed process for ", name)
			}
		} else {
			// The loader reads the replacement table of this time: the
			// console cannot choose it.
			space.source = source_now()
			ok: bool
			load_details = {records = &load_detail_records[0], count = 0, capacity = ERROR_DETAILS_CAPACITY}
			if place, ok = system.module_space_load(&space, file, &load_error, &load_details); !ok {
				return fail_load("cannot load ", name)
			}
			base = space.modules[place].base
		}
		loaded[loaded_count] = {hash = entry.hash, name = system.name_of(entry.name[:]), file = file, place = place, sandbox = number}
		loaded_count += 1
		commands_add(file, "", number, base)
		return loaded_record(system.name_of(entry.name[:]), callable, isolate ? "isolated" : "direct", entry.hash)
	}
	return fail("no module has the name ", name)
}

// The bytes of a module file that isolate_memory takes: the bound of a
// module file of the store module_files, which a call host maps whole.
MEMORY_MODULE_BYTES_MOST :: 4 * 1024 * 1024

// isolate_from_memory makes each export of a module file that a memory
// object holds a command, as isolate does for a module of the boot image
// (src/md/features/assembler.md, "The machine step: a module from the memory of the console").
// The console copies the bytes into an object of its own first: the caller
// keeps its object and can write it again, and the descriptions that the
// commands read must not change under them.
isolate_from_memory :: proc "contextless" (arguments: []Value) -> Value {
	name := arguments[0].text
	memory := system.Handle(arguments[1].integer)
	size := arguments[2].integer
	name_valid := len(name) >= 1 && len(name) < info.IMAGE_NAME_SIZE
	for index in 0 ..< len(name) {
		character := name[index]
		letter := character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' || character == '_'
		digit := character >= '0' && character <= '9'
		if !letter && !(digit && index > 0) {
			name_valid = false
		}
	}
	if !name_valid {
		return fail("isolate_memory: \"", name, "\" is no name of a module: 1 to ", i64(info.IMAGE_NAME_SIZE - 1), " ASCII letters, digits and _, with no digit first")
	}
	if size < 1 || size > MEMORY_MODULE_BYTES_MOST {
		return fail("isolate_memory: the size is ", size, " bytes; a module file has 1 to ", i64(MEMORY_MODULE_BYTES_MOST))
	}
	kind, _, _ := system.handle_state(memory)
	if kind != .Memory {
		return fail("isolate_memory: the handle names no memory object")
	}
	// A refused handle has no pages, so it has no byte.
	pages, _ := system.memory_size(memory)
	if u64(size) > pages * system.PAGE_SIZE {
		return fail("isolate_memory: the memory object has ", pages * system.PAGE_SIZE, " bytes; it does not hold ", size)
	}
	for &item in loaded[:loaded_count] {
		if item.name == name {
			return fail("the module ", name, " is loaded; unload(\"", name, "\") removes it")
		}
	}
	if loaded_count == LOADED_CAPACITY {
		return fail("no room for the commands of ", name)
	}
	sandbox, number := sandbox_free()
	if sandbox == nil {
		return fail("no room for a sandboxed process")
	}

	copy_pages := (u64(size) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	copy_memory, create_status := system.memory_create(copy_pages)
	if create_status != .Ok {
		return fail("isolate_memory: the budget of the console cannot pay for ", copy_pages, " pages")
	}
	copy_address, copy_status := system.memory_map(copy_memory)
	if copy_status != .Ok {
		system.close(copy_memory)
		return fail("isolate_memory: the console cannot map its copy")
	}
	source_address, source_status := system.memory_map(memory, {})
	if source_status != .Ok {
		system.memory_unmap(copy_address)
		system.close(copy_memory)
		return fail("the console cannot map the memory object")
	}
	intrinsics.mem_copy_non_overlapping(copy_address, source_address, int(size))
	system.memory_unmap(source_address)
	file := ([^]u8)(copy_address)[:size]
	copy_end :: proc "contextless" (address: rawptr, memory: system.Handle) {
		system.memory_unmap(address)
		system.close(memory)
	}

	if error := module.validate(file); error != .None {
		copy_end(copy_address, copy_memory)
		return fail("isolate_memory: the bytes are no module file: module.validate refuses them with the error ", u64(error))
	}
	if module.count(file, .Imports) > 1 {
		copy_end(copy_address, copy_memory)
		return fail("isolate_memory: the module imports another module; a module from memory takes no import")
	}
	hash := blake3.hash(file)
	for &item in loaded[:loaded_count] {
		if item.hash == hash {
			copy_end(copy_address, copy_memory)
			return fail("the module ", item.name, " has the same bytes and is loaded; unload(\"", item.name, "\") removes it")
		}
	}
	callable := callable_count(file)
	if callable == 0 {
		copy_end(copy_address, copy_memory)
		return fail("isolate_memory: the module ", name, " exports no command")
	}
	if command_count + callable + int(module.count(file, .Records)) > COMMAND_CAPACITY {
		copy_end(copy_address, copy_memory)
		return fail("no room for the commands of ", name)
	}

	sandbox^ = {module_memory = copy_memory, module_address = copy_address}
	copy(sandbox.module_entry.name[:], name)
	sandbox.module_entry.hash = hash
	sandbox.module_entry.size = u64(size)
	sandbox.name = system.name_of(sandbox.module_entry.name[:])
	if !sandbox_create(sandbox, file) {
		sandbox^ = {}
		copy_end(copy_address, copy_memory)
		if load_error.stage != u32(module.Load_Stage.None) {
			load_details.count = 0 // A call host gives no details of its load.
			return fail_load("cannot isolate ", name)
		}
		return fail("cannot start a sandboxed process for ", name)
	}
	loaded[loaded_count] = {hash = hash, name = sandbox.name, file = file, place = -1, sandbox = number}
	loaded_count += 1
	commands_add(file, "", number, 0)
	system.log_fact(.Info, Module_From_Memory{size = value_kinds.Size_In_Bytes(size), module_hash = value_kinds.Hash_Field(hash), module_name = value_kinds.module_name_field(sandbox.name)})
	return loaded_record(sandbox.name, callable, "isolated", hash)
}

// unload_module removes a module that load or isolate added: its commands
// leave the console. A direct load leaves the memory of the console. A call
// host stops: the kernel stops a process that no handle names.
unload_module :: proc "contextless" (arguments: []Value) -> Value {
	name := arguments[0].text
	for &item, index in loaded[:loaded_count] {
		if item.name != name {
			continue
		}
		kept, removed := 0, 0
		for &entry in commands[:command_count] {
			module_command := entry.run == nil && raw_data(entry.file) == raw_data(item.file) && entry.sandbox == item.sandbox
			if !module_command {
				commands[kept] = entry
				kept += 1
			} else if entry.record != 0 {
				removed -= 1 // The count that the console prints is the count of exports.
			}
		}
		removed += command_count - kept
		command_count = kept
		memory := "left the console"
		if item.sandbox != 0 {
			sandbox := &sandboxes[item.sandbox - 1]
			sandbox_end(sandbox)
			system.ring_close(&sandbox.ring)
			system.memory_unmap(raw_data(sandbox.region))
			system.close(sandbox.ring_memory)
			system.close(sandbox.region_memory)
			system.close(sandbox.files_memory)
			if sandbox.module_memory != 0 {
				system.memory_unmap(sandbox.module_address)
				system.close(sandbox.module_memory)
			}
			sandbox^ = {}
			memory = "its sandboxed process stopped"
		} else {
			// A module that another module imports stays: one copy for all.
			// An import that no other module uses leaves with the module.
			if !system.module_space_release(&space, item.place, &load_error) {
				return fail_load("cannot remove ", item.name)
			}
			if space.modules[item.place].users != 0 {
				memory = "stays: another module imports it"
			}
		}
		columns := [3]Column{text_column("module", 32), integer_column("commands"), text_column("memory", 40)}
		table, made := made_table("Unloaded", columns[:])
		row := made_row(&table)
		// The argument, not item.name: the name of a module from memory is
		// a view of its sandbox, which is all zero bytes now.
		made_text(&table, row, 0, name)
		made_integer(&table, row, 1, i64(removed))
		made_text(&table, row, 2, memory)
		loaded[index] = loaded[loaded_count - 1]
		loaded_count -= 1
		if !made {
			return fail(name, ": the line has no room for the description of its result")
		}
		return made_record(&table, "unload")
	}
	return fail("load and isolate added no module with the name ", name)
}

// callable_count gives the count of exports of a module that the console
// can call.
callable_count :: proc "contextless" (file: []u8) -> (callable: int) {
	head, _ := module.header(file)
	for index in 1 ..< module.count(file, .Exports) {
		if function, ok := module.function(file, index); ok && index != head.entry_export && callable_by_console(file, function) {
			callable += 1
		}
	}
	return callable
}

// record_command_count gives the count of the records of a module that
// can become commands: each one that is not a fact type. It is the room
// that commands_add can take, at most.
record_command_count :: proc "contextless" (file: []u8) -> int {
	count := 0
	for index in 1 ..< module.count(file, .Records) {
		if !module.record_is_fact(file, index) {
			count += 1
		}
	}
	return count
}

// commands_add makes each callable export of a module a command. The
// description of the export gives its name, its types and its help.
// Each record of the module is a command too, with the name of the record:
// it makes a Record value from one argument for each field.
//   prefix:  "", or the name of a service: the command is "service.export".
//   sandbox: 0 for a direct call at base, or the number of the sandbox.
commands_add :: proc "contextless" (file: []u8, prefix: string, sandbox: int, base: u64) {
	head, _ := module.header(file)
	for index in 1 ..< module.count(file, .Records) {
		described, ok := module.record_type(file, index)
		// A fact type is read through facts(), never made by hand: it is
		// no command, and takes no room of the commands.
		if !ok || described.field_count > ARGUMENT_CAPACITY || module.record_is_fact(file, index) {
			continue
		}
		item := &commands[command_count]
		item^ = {
			name            = module.string_at(file, described.name_offset, described.name_count),
			about           = "make a record from its fields",
			parameter_count = int(described.field_count),
			result          = .Record,
			file            = file,
			record          = index,
			sandbox         = sandbox, // The owner of the command. A record has no call.
		}
		item.function.result_detail = index
		// record_type refused a field of no type; the border reads each
		// byte again, and a record with such a field is no command.
		fields_known := true
		for number in 0 ..< described.field_count {
			field, _ := module.field(file, described, number)
			kind, kind_ok := kind_of_type_word(field.type)
			// A hash is a Bytes field: the console has no value of a hash
			// to type, so a record with one is no command.
			if !kind_ok || kind == .Bytes {
				fields_known = false
				break
			}
			item.parameters[number] = kind
			item.parameter_names[number] = module.string_at(file, field.name_offset, field.name_count)
			item.function.parameter_details[number] = field.detail
		}
		if !fields_known {
			continue
		}
		command_count += 1
	}
	for index in 1 ..< module.count(file, .Exports) {
		address, has_address := module.export_address(file, uintptr(base), index)
		if !has_address || index == head.entry_export {
			continue
		}
		item := &commands[command_count]
		if !export_command_make(item, file, index) {
			continue
		}
		if prefix != "" {
			item.name = system.format(names[names_count:], prefix, ".", item.name)
			names_count += len(item.name)
		}
		if sandbox != 0 {
			item.sandbox = sandbox
		} else {
			item.address = address
		}
		command_count += 1
	}
}

// export_command_make writes the command of the export index of a module
// file, with the name of the export and no way to call it yet: the caller
// gives its sandbox or its address. false: the console cannot call the
// export (callable_by_console), or a byte of its description names no type.
export_command_make :: proc "contextless" (item: ^Command, file: []u8, index: u32) -> bool {
	function, ok := module.function(file, index)
	if !ok || !callable_by_console(file, function) {
		return false
	}
	// callable_by_console refused each byte of no type; the border reads
	// them again, and an export with such a byte is no command.
	result_kind, result_ok := kind_of_type_word(function.result)
	if !result_ok {
		return false
	}
	item^ = {
		name            = module.string_at(file, function.name_offset, function.name_count),
		about           = module.string_at(file, function.about_offset, function.about_count),
		parameter_count = int(function.parameter_count),
		result          = result_kind,
		export          = index,
		function        = function,
		file            = file,
	}
	for word, parameter in function.parameters[:function.parameter_count] {
		kind, kind_ok := kind_of_type_word(word)
		if !kind_ok {
			return false
		}
		item.parameters[parameter] = kind
		item.parameter_names[parameter] = module.string_at(file, function.parameter_names[parameter], u32(function.parameter_name_counts[parameter]))
		// The description of the export states what its number counts,
		// as a built-in command states it in `command`. A detail out of
		// the contract comes from another party: the field is then a
		// plain number.
		if kind == .Integer {
			item.parameter_units[parameter], _ = value_kinds.integer_unit_of_detail(function.parameter_details[parameter])
		}
	}
	// The table of error details is the last parameter: the console
	// gives it, and the command shows the parameters before it.
	if details_index, has_details := module.error_details_parameter(file, function); has_details {
		item.details_parameter = details_index + 1
		item.parameter_count = details_index
	}
	return true
}

// connect_service makes a connection to a service that runs, and makes each
// export of the service a command: "service.export". The root service
// decides if the console can call the service. It names the file of the
// process by its hash: the console reads the descriptions there.
connect_service :: proc "contextless" (arguments: []Value) -> Value {
	name := arguments[0].text
	line_records_try_again()
	sandbox: ^Sandbox
	number := 0
	for &item, index in sandboxes {
		if !item.service || item.name != name {
			continue
		}
		// The commands of the service exist already: the answer is the
		// record of the connection, again.
		if !item.quiet {
			if entry := system.image_entry_of(image, item.hash); entry != nil {
				return loaded_record(item.name, callable_count(image[entry.offset:][:entry.size]), "service", item.hash)
			}
			return fail("the boot image has no file with the hash of the process ", name)
		}
		// The console connected for itself: the commands come now.
		sandbox, number = &item, index + 1
	}
	fresh := sandbox == nil
	if fresh {
		sandbox, number = sandbox_free()
		if sandbox == nil {
			return fail("no room for the service ", name)
		}
		sandbox^ = {
			name    = name,
			service = true,
		}
	}
	if fresh || sandbox.process == 0 {
		refused: ring.Record
		not_ready: bool
		if outcome := service_connect(sandbox, &refused, &not_ready); outcome != .Succeeded {
			sandbox^ = {}
			if not_ready {
				return fail("cannot connect to ", name, ": the service stopped, or did not open the connection before the hang bound of ", i64(system.ANSWER_BOUND_MILLISECONDS / 1000), " s")
			}
			if refused.kind == 0 {
				return fail("cannot connect to ", name, ": ", outcome == .Deadline_Passed_During_The_Call ? "the root service did not answer" : "the call ring or the call region does not map")
			}
			return fail_root(scratch_text("cannot connect to ", name, ": "), refused)
		}
	}
	for &entry in system.image_entries(image) {
		if entry.hash != sandbox.hash || entry.offset > u64(len(image)) || entry.size > u64(len(image)) - entry.offset {
			continue
		}
		file := image[entry.offset:][:entry.size]
		if blake3.hash(file) != entry.hash || module.validate(file) != .None {
			break
		}
		callable := callable_count(file)
		if callable == 0 || command_count + callable + record_command_count(file) > COMMAND_CAPACITY || len(names) - names_count < callable * 64 {
			service_disconnect(sandbox)
			sandbox^ = {}
			return fail("the service ", name, callable == 0 ? " exports no command" : ": no room for its commands")
		}
		sandbox.name = system.name_of(entry.name[:]) // The text of the line does not stay.
		sandbox.quiet = false
		commands_add(file, sandbox.name, number, 0)
		return loaded_record(sandbox.name, callable, "service", entry.hash)
	}
	service_disconnect(sandbox)
	sandbox^ = {}
	return fail("the boot image has no file with the hash of the process ", name)
}

// root_refusal_text gives the sentence of the error record of a completion
// of the root ring that failed.
root_refusal_text :: proc "contextless" (buffer: []u8, completion: ring.Record) -> string {
	error := errors.completion_record(completion.values)
	writer := system.Writer{buffer = buffer}
	system.ring_error_text(&writer, &error, "root", root_ring.root_command_name(error.operation), root_ring.root_argument_name(error.operation, error.argument))
	return system.written(&writer)
}

// service_connect asks the root service for a connection to the service of
// a sandbox, maps the call ring and the call region that it gives, and
// waits for the ready completion of the service. refused: the completion of
// a refusal of the root service, if the caller asks for it. not_ready: set
// when the service stopped or sent no ready completion within the bound.
// The outcome is that of the answer of the root service, or of the step
// of this process that failed after it.
service_connect :: proc "contextless" (sandbox: ^Sandbox, refused: ^ring.Record = nil, not_ready: ^bool = nil) -> call_outcome.Call_Outcome {
	// The root service can start the service first: only the hang bound
	// of an answer ends this wait, never a time of a start.
	completion, answered := request_record(.Connect, sandbox.name, 0, system.ANSWER_BOUND_MILLISECONDS, stoppable = true)
	if !answered {
		// Do not block on the root service after Escape or the hang bound:
		// send Disconnect and record connect_tag so the next drain of the
		// root ring closes any late Connect handles without holding the
		// console.
		if requests.head != nil {
			connect_tag := request_count
			request_count += 1
			system.connect_abandon(&requests, &abandoned_connects, connect_tag, request_count, system.name_pack(sandbox.name))
		}
		return .Deadline_Passed_During_The_Call
	}
	if outcome, refusal := call_outcome.completion_outcome(completion.kind, completion.values); outcome != .Succeeded {
		if refused != nil {
			// The record of the root service, or for an answer that this
			// process cannot read, the record of the border.
			refused^ = {kind = u32(outcome), tag = completion.tag, values = errors.completion_values(refusal)}
		}
		return outcome
	}
	sandbox.process = system.Handle(completion.values[0])
	sandbox.ring_memory = system.Handle(completion.values[1])
	sandbox.region_memory = system.Handle(completion.values[2])
	hash := transmute([32]u8)[4]u64{completion.values[3], completion.values[4], completion.values[5], completion.values[6]}
	calls, ring_status := system.ring_open(sandbox.ring_memory, receive_handles = true)
	bytes, region_status := system.memory_map(sandbox.region_memory)
	sandbox.ring = calls
	// A refused handle has no pages: the region is empty.
	region_pages, _ := system.memory_size(sandbox.region_memory)
	sandbox.region = ([^]u8)(bytes)[:region_status == .Ok ? region_pages * system.PAGE_SIZE : 0]
	// After the first connection, the commands are those of one file.
	if ring_status != .Ok || region_status != .Ok {
		service_disconnect(sandbox)
		return system.outcome_of_own_status(ring_status != .Ok ? ring_status : region_status)
	}
	// After the first connection, the module is the module of the commands.
	if sandbox.hash != {} && sandbox.hash != hash {
		service_disconnect(sandbox)
		return .Wrong_State
	}
	// The service maps the call ring when it reads the Connect of the root
	// service, which can be after its start on demand: a lend before the
	// ready completion has no receiver (src/md/api/call_ring_ready.md).
	call_stoppable_enter()
	ready := system.connection_ready_wait(&sandbox.ring, sandbox.process, &work.cancel)
	call_stoppable_leave()
	if ready != .Ready {
		service_disconnect(sandbox)
		if not_ready != nil {
			not_ready^ = true
		}
		return .Callee_Unavailable
	}
	sandbox.hash = hash
	return .Succeeded
}

// service_disconnect ends the connection of a sandbox. The service
// continues.
service_disconnect :: proc "contextless" (sandbox: ^Sandbox) {
	request_record(.Disconnect, sandbox.name, 0, system.ANSWER_BOUND_MILLISECONDS)
	if sandbox.ring.head != nil {
		system.ring_close(&sandbox.ring)
	}
	if len(sandbox.region) != 0 {
		system.memory_unmap(raw_data(sandbox.region))
	}
	system.close(sandbox.ring_memory)
	system.close(sandbox.region_memory)
	system.close(sandbox.process)
	sandbox.process, sandbox.ring_memory, sandbox.region_memory, sandbox.ring, sandbox.region = 0, 0, 0, {}, nil
}

// services_check ends the connection to each service that stopped: the
// handle of the console does not keep a stopped process.
services_check :: proc "contextless" () {
	for &sandbox in sandboxes {
		if sandbox.service && sandbox.process != 0 {
			if state, _, _ := system.process_state(sandbox.process); state == .Stopped {
				service_disconnect(&sandbox)
			}
		}
	}
	stream_owners_check()
}

// callable_by_console says if the console has a value for each parameter and
// for the result of an export.
callable_by_console :: proc "contextless" (file: []u8, function: module.Function) -> bool {
	function := function
	// The result is a byte of a module file: a byte that names no type, a
	// Handle and Bytes have no value of the console as a result.
	result_type, result_ok := module.function_result_type(function)
	if function.name_count == 0 || function.parameter_count > ARGUMENT_CAPACITY || module.call_argument_count(int(function.parameter_count), function.result, function.error_record != 0) > system.CALL_INTEGERS || !result_ok || result_type == .Bytes || result_type == .Handle {
		return false
	}
	if result_type == .Record || result_type == .Table {
		if _, ok := module.record_type(file, function.result_detail); !ok {
			return false
		}
	}
	details_index, has_details := module.error_details_parameter(file, function)
	for word, index in function.parameters[:function.parameter_count] {
		direction, direction_ok := module.direction_of_word(function.parameter_directions[index])
		if !direction_ok {
			return false
		}
		// The type is a byte of a module file: a byte that names no type
		// makes the export not callable.
		type, type_ok := module.type_of_word(word)
		if !type_ok {
			return false
		}
		switch type {
		case .None:
			return false
		case .Integer, .Text, .Handle:
		case .Enum:
			// function_enums_check below reads the enum and its getter.
		case .Record:
			if _, ok := module.record_type(file, function.parameter_details[index]); !ok {
				return false
			}
		case .Table:
			// A Read or Change table is a Table value. An Append table is a
			// second result, which the language does not have; the table of
			// error details is the one Append table: the console gives it.
			if _, _, ok := isolated.table_record(file, word, function.parameter_details[index]); !ok || (direction == .Append && !(has_details && index == details_index)) {
				return false
			}
		case .Bytes:
			// A Text value: read only.
			if direction != .Read {
				return false
			}
		}
	}
	// The console names the members of each enum and the palette calls
	// each getter: an enum or a getter that breaks a rule of the format
	// makes the export not callable.
	if _, problem := module.function_enums_check(file, function); problem != .None {
		return false
	}
	// The palette runs a line made of the name of the export and of its
	// parameters, `h.f(a = .x)`: a name that is no name of Lex could put a
	// call of its own in that line, as the console.
	if !lex_parser.name_valid(module.string_at(file, function.name_offset, function.name_count)) {
		return false
	}
	for index in 0 ..< int(function.parameter_count) {
		if !lex_parser.name_valid(module.string_at(file, function.parameter_names[index], u32(function.parameter_name_counts[index]))) {
			return false
		}
	}
	return isolated.directions_valid(function)
}

// type_text_of_field gives the type of a field: "Unsigned(1)", "Integer(4)".
type_text_of_field :: proc "contextless" (file: []u8, field: module.Field) -> string {
	writer := system.Writer {
		buffer = scratch[scratch_count:],
	}
	system.write_field_type(&writer, file, field)
	scratch_count += writer.count
	return system.written(&writer)
}

// record_build makes a Record value: one argument for each field, in the
// order of the description.
record_build :: proc "contextless" (item: ^Command, arguments: []Value) -> Value {
	described, _ := module.record_type(item.file, item.record)
	bytes := scratch_bytes(int(described.size))
	if bytes == nil {
		return fail("the line has too many records")
	}
	for argument, number in arguments {
		field, _ := module.field(item.file, described, u32(number))
		if field.type == u8(module.Type.Text) {
			copy(bytes[field.offset:][:field.detail], argument.text)
		} else if field.type == u8(module.Type.Handle) {
			(^u32)(&bytes[field.offset])^ = u32(argument.integer)
		} else {
			if !module.field_integer_fits(field, argument.integer) {
				return fail(item.name, ": the field ", module.string_at(item.file, field.name_offset, field.name_count), " is ", type_text_of_field(item.file, field), ", it does not hold ", argument.integer)
			}
			module.field_integer_set(bytes, field, argument.integer)
		}
	}
	return {kind = .Record, record = bytes, file = item.file, detail = item.record}
}

// call_export calls an export of a loaded module with the call form: each
// argument in one integer word, in order: 6 in registers, the others on the
// stack. An Integer is the value; a Text
// is the address of its slice record; a Record is the address of its bytes;
// a Handle is the handle. The module is in this process: it has each handle
// of the console, and the rights of a description limit nothing here.
call_export :: proc "contextless" (item: ^Command, arguments: []Value) -> Value {
	// The module runs in this process: its log records are records of the
	// console.
	line_records_call_begins("console")
	integers: [system.CALL_INTEGERS]u64
	// A Table or Bytes parameter: the address of a table place over the
	// memory of the value. A Change table changes it in place: a variable
	// holds the changed rows after the call.
	places: [ARGUMENT_CAPACITY]module.Table_Place
	for &argument, index in arguments {
		if index < int(item.parameter_count) && (item.parameters[index] == .Table || item.parameters[index] == .Bytes) {
			bytes := argument.kind == .Text ? transmute([]u8)argument.text : argument.record
			size, _, _ := isolated.table_record(item.file, u8(type_of_kind(item.parameters[index])), item.function.parameter_details[index])
			count := u64(len(bytes)) / max(size, 1)
			places[index] = {address = u64(uintptr(raw_data(bytes))), count = count, capacity = count}
			integers[index] = u64(uintptr(&places[index]))
			continue
		}
		switch argument.kind {
		case .Text:
			integers[index] = u64(uintptr(&argument.text))
		case .Record:
			integers[index] = u64(uintptr(raw_data(argument.record)))
		case .None, .Integer, .Handle, .Table, .Bytes, .Stream, .Record_Input, .Record_Literal, .Enum, .Member, .Function, .List, .Hash, .Boolean, .Record_With, .Module_Ref, .Tree_Ref, .Recipe_Ref, .Follow_Ref, .Store_Ref, .Plan_Value, .Project_Value:
			// The check of the line gave each other kind its integer: a
			// handle is its number, a member its value or the absent word,
			// and a Table or Bytes parameter took its place above. An export
			// takes no Stream: argument_accepted refused it.
			integers[index] = u64(argument.integer)
		}
	}
	// The table of error details: the last parameter, after those of the
	// input. The export appends to it only when it fails.
	parameter_total := len(arguments)
	details: [ERROR_DETAILS_CAPACITY]errors.Error_Record
	details_place: module.Table_Place
	if item.details_parameter != 0 {
		details_place = {address = u64(uintptr(&details[0])), count = 0, capacity = ERROR_DETAILS_CAPACITY}
		integers[parameter_total] = u64(uintptr(&details_place))
		parameter_total += 1
	}
	// A Record result: the export writes it in the memory of the line.
	record: []u8
	if item.result == .Record {
		described, _ := module.record_type(item.file, item.function.result_detail)
		record = scratch_bytes(int(described.size))
		if record == nil {
			return fail("the line has too many records")
		}
		integers[parameter_total] = u64(uintptr(raw_data(record)))
	}
	// A Text result: the buffer is the free part of the memory of the line.
	buffer := scratch[scratch_count:]
	if item.result == .Text {
		integers[parameter_total] = u64(uintptr(&buffer))
	}
	// A Table result: the buffer is the free part of the memory of the
	// tables of the line, with a capacity in records.
	table: Table_Buffer
	if item.result == .Table {
		table = table_buffer(item.file, item.function.result_detail)
		integers[parameter_total] = u64(uintptr(&table.slice))
	}
	// An error record: one more argument, after the buffer of a result. The
	// export writes it when it fails.
	error: errors.Error_Record
	if item.function.error_record != 0 {
		integers[parameter_total + int(item.result == .Text || item.result == .Table || item.result == .Record)] = u64(uintptr(&error))
	}
	floats: [system.CALL_FLOATS]u64
	results: [system.CALL_RESULTS]u64
	system.export_call(item.address, &integers, &floats, &results)
	// An export that can fail gives its call outcome first, then its value.
	// The module is one that the line loaded, not one that the console was
	// built with: the word goes through the border.
	if item.function.error_record != 0 {
		outcome, unreadable := call_outcome.outcome_of_word(results[0])
		if outcome != .Succeeded {
			if unreadable.kind != 0 {
				error = unreadable
			}
			error.operation = i64(item.export)
			result := export_failure(item, &error, outcome)
			failure_details_set(details[:], details_place.count)
			return result
		}
		results[0] = results[1]
	}
	switch item.result {
	case .Integer:
		return {kind = .Integer, integer = i64(results[0])}
	case .Enum:
		return enum_result(item, i64(results[0]))
	case .Text:
		if results[0] > u64(len(buffer)) {
			return fail("the result of ", item.name, " has ", results[0], " bytes: it does not fit")
		}
		scratch_count += int(results[0])
		return {kind = .Text, text = string(buffer[:results[0]])}
	case .Record:
		return {kind = .Record, record = record, file = item.file, detail = item.function.result_detail}
	case .Table:
		return table_take(item, &table, results[0])
	case .None, .Handle, .Bytes, .Stream, .Record_Input, .Record_Literal, .Member, .Function, .List, .Hash, .Boolean, .Record_With, .Module_Ref, .Tree_Ref, .Recipe_Ref, .Follow_Ref, .Store_Ref, .Plan_Value, .Project_Value:
		// None gives no value; callable_by_console refuses an export with
		// a Handle or a Bytes result, and no export gives a Stream.
	}
	return {}
}

// enum_result gives the Enum value of the integer result of an export: the
// low bytes of the size of its enum (module.enum_value_of_register). A
// value that names no member is refused: the export broke its contract,
// and the line never holds a member that the enum does not have.
enum_result :: proc "contextless" (item: ^Command, register: i64) -> Value {
	described, problem := module.enum_type(item.file, item.function.result_detail)
	if problem != .None {
		return fail("the result of ", item.name, " names an enum that its module file does not describe")
	}
	value := module.enum_value_of_register(described, register)
	if _, named := module.enum_name_of_value(item.file, described, value); !named {
		return fail(item.name, " gave ", value, ", which names no member of ", module.enum_name(item.file, described))
	}
	return {kind = .Enum, integer = value, file = item.file, detail = item.function.result_detail}
}

// sandbox_create makes the call ring and the call region of a sandbox, and
// the list of the files that its call host loads, then starts the call host.
sandbox_create :: proc "contextless" (sandbox: ^Sandbox, file: []u8) -> bool {
	if !sandbox_files(sandbox, file) {
		return false
	}
	status: system.Status
	sandbox.ring_memory, sandbox.ring, status = system.ring_create()
	if status != .Ok {
		system.close(sandbox.files_memory)
		return false
	}
	address: rawptr
	if sandbox.region_memory, status = system.memory_create(isolated.REGION_PAGES); status == .Ok {
		address, status = system.memory_map(sandbox.region_memory)
	}
	if status != .Ok {
		system.ring_close(&sandbox.ring)
		system.close(sandbox.ring_memory)
		system.close(sandbox.region_memory)
		system.close(sandbox.files_memory)
		return false
	}
	sandbox.region = ([^]u8)(address)[:isolated.REGION_PAGES * system.PAGE_SIZE]
	if sandbox_start(sandbox) != .Ok {
		system.ring_close(&sandbox.ring)
		system.memory_unmap(address)
		system.close(sandbox.ring_memory)
		system.close(sandbox.region_memory)
		system.close(sandbox.files_memory)
		return false
	}
	return true
}

// sandbox_files chooses the files of a call host: the module, and what its
// load reads with the replacement table of this time (system.source_closure).
// It writes their list, in the form of the boot image, and the replacements
// in one page: the call host receives that page and these files, and no
// other file.
sandbox_files :: proc "contextless" (sandbox: ^Sandbox, file: []u8) -> bool {
	source := source_now()
	if sandbox.module_memory != 0 {
		// A module from memory is the one file: isolate_memory refused a
		// module with an import.
		sandbox.files[0] = &sandbox.module_entry
		sandbox.file_count = 1
	} else {
		sandbox.file_count = system.source_closure(source, file, &sandbox.files)
	}
	list_size := size_of(info.Image_Header) + sandbox.file_count * size_of(info.Image_Entry)
	if sandbox.file_count == 0 || list_size + len(source.replacements) * size_of(module.Replacement) > system.PAGE_SIZE {
		return false
	}
	status: system.Status
	if sandbox.files_memory, status = system.memory_create(1); status != .Ok {
		return false
	}
	address, map_status := system.memory_map(sandbox.files_memory)
	if map_status != .Ok {
		system.close(sandbox.files_memory)
		return false
	}
	defer system.memory_unmap(address)
	page := ([^]u8)(address)[:system.PAGE_SIZE]
	(^info.Image_Header)(address)^ = {magic = info.IMAGE_MAGIC, count = u32(sandbox.file_count)}
	entries := ([^]info.Image_Entry)(raw_data(page[size_of(info.Image_Header):]))[:sandbox.file_count]
	offset := u64(system.PAGE_SIZE)
	for item, index in sandbox.files[:sandbox.file_count] {
		if item.offset % system.PAGE_SIZE != 0 {
			system.close(sandbox.files_memory)
			return false
		}
		entries[index] = item^
		entries[index].offset = offset
		sandbox.file_offsets[index] = offset
		offset += (item.size + system.PAGE_SIZE - 1) / system.PAGE_SIZE * system.PAGE_SIZE
	}
	sandbox.files_size = offset
	sandbox.replacement_offset = u64(list_size + 7) &~ 7
	sandbox.replacement_count = u64(len(source.replacements))
	copy(([^]module.Replacement)(raw_data(page[sandbox.replacement_offset:]))[:len(source.replacements)], source.replacements)
	return true
}

// sandbox_start starts the call host of a sandbox. The process receives the
// call ring and the call region, and no other handle. The console maps the
// file of the module in it, read-only: the process has no handle to the
// boot image.
sandbox_start :: proc "contextless" (sandbox: ^Sandbox) -> system.Status {
	if sandbox.service {
		// The connection says its own outcome; this procedure gives the
		// status of the start of a call host.
		if service_connect(sandbox) != .Succeeded {
			return .Bad_State
		}
		return .Ok
	}
	sandbox.ring.head^ = {}
	grants: [op.CONTEXT_HANDLES]system.Grant
	values: [op.CONTEXT_VALUES]u64
	grants[isolated.GRANT_RING] = {sandbox.ring_memory, {.Read, .Write}}
	grants[isolated.GRANT_REGION] = {sandbox.region_memory, {.Read, .Write}}
	grants[op.CONTEXT_LOG] = {system.context_record().handles[op.CONTEXT_LOG], {.Write}}
	values[isolated.VALUE_FILE_ADDRESS] = isolated.FILE_ADDRESS
	values[isolated.VALUE_FILE_SIZE] = sandbox.files_size
	values[isolated.VALUE_REPLACEMENT_OFFSET] = sandbox.replacement_offset
	values[isolated.VALUE_REPLACEMENT_COUNT] = sandbox.replacement_count
	mappings: [FILE_CAPACITY + 1]system.Mapping
	mappings[0] = {memory = sandbox.files_memory, address = isolated.FILE_ADDRESS}
	for item, index in sandbox.files[:sandbox.file_count] {
		source_memory := image_memory
		if sandbox.module_memory != 0 {
			source_memory = sandbox.module_memory
		}
		mappings[index + 1] = {memory = source_memory, address = isolated.FILE_ADDRESS + sandbox.file_offsets[index], first = item.offset / system.PAGE_SIZE, page_count = (item.size + system.PAGE_SIZE - 1) / system.PAGE_SIZE}
	}
	status: system.Status
	load_error = {}
	sandbox.process, status = system.process_start(system.image_find(image, "host"), sandbox.name, grants, random.values_with_seed(&process_generator, values), {pages = 512, processes = 1, threads = 1, processor = 500_000, log_records = SANDBOX_LOG_RECORDS}, mappings[:sandbox.file_count + 1], &prepared)
	if status != .Ok {
		return status
	}
	// The first completion of the call host says if it loaded the module.
	// With Load_Failed, the record of the failure is in the call region:
	// the console copies it, and reads it as values.
	call_stoppable_enter()
	ready := system.connection_ready_wait(&sandbox.ring, sandbox.process, &work.cancel)
	call_stoppable_leave()
	switch ready {
	case .Ready:
		return .Ok
	case .Load_Failed:
		intrinsics.mem_copy_non_overlapping(&load_error, raw_data(sandbox.region), size_of(load_error))
	case .Refused:
	}
	sandbox_end(sandbox)
	return .Bad_State
}

// load_error is the record of the last load that failed. The console owns
// it; the loader, or a call host through the call region, fills it.
load_error: module.Load_Error

// The error details of the last load in this process that failed: one load
// error for each import that is missing or has the wrong hash. A call host
// gives none: the count is 0.
load_detail_records: [ERROR_DETAILS_CAPACITY]module.Load_Error
load_details: system.Table_To_Append(module.Load_Error)

// fail_load makes the line fail with a load error: the sentence says what
// failed, and the lines of the record follow it in the error of the line.
// Each line is drawn after "error: ". When the load
// gave more than one error detail, the lines of each one follow, after its
// number: the record is the first detail.
fail_load :: proc "contextless" (what: string, name: string) -> Value {
	result := fail(what, name)
	load_error_lines :: proc "contextless" (record: ^module.Load_Error, number: u64, count: u64) {
		buffer: [768]u8
		writer := system.Writer {
			buffer = buffer[:],
		}
		if number != 0 {
			system.error_detail_number_text(&writer, number, count)
		}
		system.load_error_text(&writer, record)
		text := system.written(&writer)
		for len(text) > 0 {
			end := 0
			for end < len(text) && text[end] != '\n' {
				end += 1
			}
			fail_note(text[:end])
			text = text[min(end + 1, len(text)):]
		}
	}
	load_error_lines(&load_error, 0, 0)
	if load_details.count >= 2 {
		shown := min(load_details.count, load_details.capacity)
		for &detail, index in load_detail_records[:shown] {
			load_error_lines(&detail, u64(index + 1), load_details.count)
		}
		buffer: [128]u8
		writer := system.Writer{buffer = buffer[:]}
		system.error_details_rest_text(&writer, shown, load_details.count)
		if rest := system.written(&writer); rest != "" {
			fail_note(rest)
		}
	}
	load_details.count = 0
	return result
}

// fault_print adds to the error of the line where a process stopped on a fault: the module that
// ran, as the loader of the process recorded it, and the module that it
// replaced. With the debug image, the instruction and each frame have the
// name of their procedure and their source line.
fault_print :: proc "contextless" (report: ^op.Stop_Report) {
	if report.module.size != 0 {
		buffer: [256]u8
		writer := system.Writer{buffer = buffer[:]}
		named := false
		if entry := system.image_entry_of(image, report.module.hash); entry != nil && debug_names.image != nil {
			named = system.place_write(&writer, system.debug_object_of(&debug_names, report.module.hash), report.instruction - report.module.base, system.name_of(entry.name[:]), false)
		}
		if named {
			fail_note("the instruction is at ", system.written(&writer))
		} else {
			fail_note("the instruction is at offset ", system.Hex(report.instruction - report.module.base), " of ", module_text(report.module.hash))
		}
		if report.module.replaces != {} {
			fail_note(module_text(report.module.hash), " runs in place of ", module_text(report.module.replaces))
		}
	}
	// The stack trace: the instruction, then the return address of each call.
	for &frame, number in report.frames[:min(report.frame_count, op.STOP_FRAME_CAPACITY)] {
		buffer: [256]u8
		writer := system.Writer{buffer = buffer[:]}
		system.frame_text(&writer, image, &debug_names, &frame, number)
		fail_note("frame ", u64(number), ": ", system.written(&writer), number == 0 ? ", the instruction" : "")
	}
}

// sandbox_end closes the handle of the call host. The kernel stops a process
// that no handle names.
sandbox_end :: proc "contextless" (sandbox: ^Sandbox) {
	if sandbox.service {
		service_disconnect(sandbox)
		return
	}
	system.close(sandbox.process)
	sandbox.process = 0
}

// export_failure makes the line fail with the error record of an export
// that failed: the sentence of the record, and the record itself with the
// names of the export and of its parameters, from the description.
export_failure :: proc "contextless" (item: ^Command, error: ^errors.Error_Record, outcome: call_outcome.Call_Outcome) -> Value {
	already := failed
	argument := ""
	if error.argument >= 1 && error.argument <= i64(item.parameter_count) {
		argument = item.parameter_names[error.argument - 1]
	}
	buffer: [240]u8
	writer := system.Writer{buffer = buffer[:]}
	system.call_failure_text(&writer, outcome, error, item.name, argument)
	result := fail(system.written(&writer))
	if !already {
		failure_record_set(error^, item.name, item.parameter_names[:item.parameter_count], outcome)
	}
	return result
}

// stop_reason_write writes why a process stopped: the stop outcome for a
// stop of itself ("failed", "refused"), else the text of its stop cause,
// with the name of the vector for a fault. A whole switch: a new cause is a
// compile error here.
stop_reason_write :: proc "contextless" (writer: ^system.Writer, cause: op.Stop_Cause, outcome: op.Stop_Outcome, vector: u32) {
	switch cause {
	case .Itself:
		system.write_part(writer, op.STOP_OUTCOME_TEXTS[outcome])
	case .Fault:
		system.write_part(writer, op.STOP_CAUSE_TEXTS[cause])
		system.write_part(writer, ", ")
		if kind, known := op.fault_kind_of_word(u64(vector)); known {
			system.write_part(writer, fault_kind_text(kind))
		} else {
			// The number of the vector is on the stop report lines.
			system.write_part(writer, "a fault of a kind that the console does not know")
		}
	case .None, .Holder, .Last_Thread_Ended, .Handles_Closed, .Not_Committed, .Cannot_Return, .Fault_Unanswered:
		system.write_part(writer, op.STOP_CAUSE_TEXTS[cause])
	}
}

// fault_kind_text gives the words of a fault kind, as a line of the console
// names it.
fault_kind_text :: proc "contextless" (kind: op.Fault_Kind) -> string {
	switch kind {
	case .Divide_Error:
		return "division by zero"
	case .Debug:
		return "debug trap"
	case .Breakpoint:
		return "breakpoint"
	case .Invalid_Opcode:
		return "invalid instruction"
	case .Segment_Not_Present:
		return "segment not present"
	case .Stack_Fault:
		return "stack fault"
	case .General_Protection:
		return "protection fault"
	case .Page_Fault:
		return "page fault"
	case .X87_Floating_Point:
		return "x87 floating-point error"
	case .Alignment_Check:
		return "alignment check"
	case .Simd_Floating_Point:
		return "SIMD floating-point error"
	}
	return ""
}

// call_isolated calls an export of a module in its call host. The arguments
// go in the call region as one argument record; one command record of the
// call ring names it; the completion record has the result.
// A module that faults stops alone: the console reports an error and
// continues. A call has no time limit: the input stops it with Escape,
// and the console then stops the call host. The next call starts a new
// call host.
call_isolated :: proc "contextless" (item: ^Command, arguments: []Value) -> Value {
	// From here to the return, Escape stops this call: outside a call,
	// Escape is a key of the next line.
	call_stoppable_enter()
	defer call_stoppable_leave()
	sandbox := &sandboxes[item.sandbox - 1]
	if sandbox.process != 0 {
		if state, _, _ := system.process_state(sandbox.process); state == .Stopped {
			sandbox_end(sandbox)
		}
	}
	if sandbox.process == 0 && sandbox_start(sandbox) != .Ok {
		if !sandbox.service && load_error.stage != u32(module.Load_Stage.None) {
			load_details.count = 0 // A call host gives no details of its load.
			return fail_load("cannot start a sandboxed process for ", sandbox.name)
		}
		return fail(sandbox.service ? "no service runs with the name " : "cannot start a sandboxed process for ", sandbox.name)
	}
	line_records_call_begins(sandbox.name)
	encoded: [ARGUMENT_CAPACITY]isolated.Argument
	for argument, index in arguments {
		encoded[index] = {integer = u64(argument.integer), text = transmute([]u8)argument.text, record = argument.record}
		// A Table or Bytes parameter: the records go into the call region,
		// and those of a Change table come back.
		if item.parameters[index] == .Table || item.parameters[index] == .Bytes {
			bytes := argument.kind == .Text ? transmute([]u8)argument.text : argument.record
			size, _, _ := isolated.table_record(item.file, u8(type_of_kind(item.parameters[index])), item.function.parameter_details[index])
			encoded[index].table = {records = bytes, count = u64(len(bytes)) / max(size, 1)}
		}
	}
	// The table of error details: the last parameter, after those of the
	// input. Its places are reserved in the call region; the details come
	// back when the export fails.
	parameter_total := len(arguments)
	details: [ERROR_DETAILS_CAPACITY]errors.Error_Record
	if item.details_parameter != 0 {
		encoded[parameter_total] = {table = {records = ([^]u8)(&details[0])[:size_of(details)], count = 0}}
		parameter_total += 1
	}
	// The handles: the other process receives a copy of each one, with the
	// rights of the description, through the call ring.
	// At the end of the call the console revokes the copies: the kernel ends what the other process kept.
	lending: system.Lending
	defer system.lend_end(&lending)
	switch lend_status := system.lend(item.file, item.function, encoded[:parameter_total], sandbox.ring_memory, &lending); lend_status {
	case .Ok:
	case .Bad_Handle:
		return fail(item.name, ": an argument names no handle of the console")
	case .No_Right:
		return fail(item.name, ": a handle of the console lacks a right that the description asks, or the Give right")
	case .No_Slot:
		return fail(item.name, ": the process ", sandbox.name, " has no room for one more handle")
	case .Bad_Operation, .Bad_Address, .No_Memory, .Bad_State, .No_Budget:
		return fail(item.name, ": the console cannot lend its handles to the process ", sandbox.name, ": ", system.kernel_status_text(lend_status))
	}
	offset, size, buffer, ok := isolated.encode(item.file, item.function, encoded[:parameter_total], sandbox.region)
	if !ok {
		if missing := isolated.room_missing(item.file, item.function, encoded[:parameter_total], u64(len(sandbox.region))); missing.parameter != 0 {
			return fail("the table ", item.parameter_names[missing.parameter - 1], " of ", item.name, " has ", missing.needed, " bytes; the call region has ", missing.free, " bytes free for it")
		}
		return fail("the arguments of ", item.name, " do not fit in the call region")
	}
	sandbox.calls += 1
	if !system.send(&sandbox.ring.commands, ring.Record{kind = item.export, tag = sandbox.calls, values = {0 = offset, 1 = size}}) {
		sandbox_end(sandbox)
		return fail("the call ring of ", sandbox.name, " is full: the console ", sandbox.service ? "closed the connection" : "stopped the process")
	}
	// The log records that the process writes show under the line while
	// the call runs: the console reads them at this interval, never before
	// the first look at the answer.
	records_due := system.time() + STATUS_INTERVAL
	for {
		if system.time() >= records_due {
			line_records_show_during(item.sandbox)
			records_due = system.time() + STATUS_INTERVAL
		}
		// The stop of the call host is an event.
		wait := system.wait_begin()
		// The other side writes this queue: read a bounded number of records,
		// and ignore each one that does not answer this call.
		for _ in 0 ..< ring.CAPACITY {
			completion, has_completion := system.receive(&sandbox.ring.completions)
			if !has_completion {
				break
			}
			if completion.tag != sandbox.calls {
				continue
			}
			// The completion crosses its one border: the value of a success,
			// or the outcome and the record of the export or of the receiver
			// that refused the call. A word that names no outcome is
			// Answer_Unreadable, never read as a member.
			value, outcome, error := isolated.answer_of_completion(completion)
			if outcome != .Succeeded {
				// A refusal of the receiver names no operation: the call is
				// the one of this export.
				if error.operation == 0 {
					error.operation = i64(item.export)
				}
				// Only the table of error details comes back: the rows that
				// a failed export wrote in a Change table stay out of the
				// values of the console (docs/MODULE_CONTRACT.md, section 8,
				// "The table of error details").
				// A wrong table of error details is an answer that the console
				// cannot read whole: the outcome and the record say so.
				details_wrong := false
				if item.details_parameter != 0 {
					problem, parameter := isolated.error_details_return(item.file, item.function, encoded[:parameter_total], sandbox.region, offset)
					details_wrong = problem != .None
					if details_wrong {
						// The record says what was unreadable, as
						// system.call_isolated says it.
						error = errors.error_make(.Bad_Value, .Records, i64(parameter), i64(problem))
						error.operation = i64(item.export)
					}
				}
				result := export_failure(item, &error, details_wrong ? .Answer_Unreadable : outcome)
				if details_wrong {
					fail_note("the process ", sandbox.name, " gave a wrong count for the table of error details: the details are missing")
				} else if item.details_parameter != 0 {
					failure_details_set(details[:], encoded[item.details_parameter - 1].table.count)
				}
				return result
			}
			// The rows of a Change table come back into the memory of the value.
			if problem, parameter := isolated.tables_return(item.file, item.function, encoded[:parameter_total], sandbox.region, offset); problem != .None {
				name := parameter >= 1 && parameter <= item.parameter_count ? item.parameter_names[parameter - 1] : "of error details"
				return fail("the process ", sandbox.name, " gave a wrong count for the table ", name)
			}
			switch item.result {
			case .Integer:
				return {kind = .Integer, integer = value}
			case .Text:
				// The count comes from the other process: read no more
				// than the buffer, and copy the text out of the call region.
				text, complete := isolated.result_text(sandbox.region, buffer, u64(value))
				if !complete || len(text) > len(scratch) - scratch_count {
					return fail("the result of ", item.name, " has ", u64(value), " bytes: it does not fit")
				}
				return {kind = .Text, text = scratch_text(string(text))}
			case .Record:
				// The other process wrote these bytes: they are values, and
				// the console reads them with the description.
				record := scratch_bytes(int(buffer.count))
				if record == nil || !isolated.result_record(sandbox.region, buffer, record) {
					return fail("the result of ", item.name, " does not fit")
				}
				return {kind = .Record, record = record, file = item.file, detail = item.function.result_detail}
			case .Table:
				// The other process wrote the records and the count:
				// read no more than the buffer, and copy the records
				// out of the call region.
				described, _ := module.record_type(item.file, item.function.result_detail)
				rows, complete := isolated.result_table(sandbox.region, buffer, u64(value), u64(described.size))
				if !complete {
					return fail("the result of ", item.name, " has ", u64(value), " records; ", i64(len(rows) / int(max(described.size, 1))), " fit in the call region")
				}
				bytes := table_bytes(len(rows))
				if bytes == nil && len(rows) > 0 {
					return fail("the line has no room for the ", u64(value), " records of ", item.name)
				}
				copy(bytes, rows)
				return {kind = .Table, record = bytes, file = item.file, detail = item.function.result_detail}
			case .Enum:
				return enum_result(item, value)
			case .None, .Handle, .Bytes, .Stream, .Record_Input, .Record_Literal, .Member, .Function, .List, .Hash, .Boolean, .Record_With, .Module_Ref, .Tree_Ref, .Recipe_Ref, .Follow_Ref, .Store_Ref, .Plan_Value, .Project_Value:
				// None gives no value; callable_by_console refuses an
				// export with a Handle or a Bytes result, and no export
				// gives a Stream.
			}
			return {}
		}
		if state, cause, outcome := system.process_state(sandbox.process); state == .Stopped {
			report := system.process_stop_report(sandbox.process)
			sandbox_end(sandbox)
			buffer: [96]u8
			reason := system.Writer{buffer = buffer[:]}
			stop_reason_write(&reason, cause, outcome, report.vector)
			result := fail("the process ", sandbox.name, " stopped: ", system.written(&reason))
			// Fault causes have a stack trace; a Failed or Refused self-stop
			// may carry a typed error record in the stop report.
			switch cause {
			case .Fault, .Not_Committed, .Cannot_Return:
				fault_print(&report)
			case .Itself:
				if op.stop_outcome_takes_error(outcome) && report.error.kind != 0 {
					argument := ""
					if report.error.argument >= 1 && report.error.argument <= i64(item.parameter_count) {
						argument = item.parameter_names[report.error.argument - 1]
					}
					text_buffer: [240]u8
					text_out := system.Writer{buffer = text_buffer[:]}
					system.error_text(&text_out, &report.error, item.name, argument)
					fail_note(system.written(&text_out))
				}
			case .None, .Holder, .Last_Thread_Ended, .Handles_Closed, .Fault_Unanswered:
			}
			return result
		}
		if intrinsics.atomic_load_explicit(&work.cancel, .Relaxed) != 0 {
			sandbox_end(sandbox)
			return fail("Escape stopped the call of ", item.name, sandbox.service ? ": the console closed the connection to " : ": the console stopped the process ", sandbox.name)
		}
		system.wait_records(&wait, &sandbox.ring.completions)
		system.wait_word(&wait, &work.cancel, 0)
		// The time only wakes the thread to read the log records again:
		// a call has no time limit.
		system.wait_end(&wait, records_due)
	}
}

// request_record sends one command to the root service and waits for its
// completion. answered is false when the root service gave none.
request_record :: proc "contextless" (kind: root_ring.Root_Command, name: string, value: u64 = 0, time_limit: u64 = 3000, stoppable := false) -> (completion: ring.Record, answered: bool) {
	if requests.head == nil {
		return {}, false
	}
	// The ring holds a name of 31 bytes: a longer name is refused here,
	// because a cut name can be the name of another process.
	if len(name) >= len(system.Name) {
		return {kind = u32(call_outcome.Call_Outcome.Argument_Refused), values = errors.ring_fail(u32(kind), .Too_Long, .Bytes, 1, i64(len(name)), len(system.Name) - 1)}, true
	}
	packed := system.name_pack(name)
	request_count += 1
	system.send(&requests.commands, ring.Record{kind = u32(kind), tag = request_count, values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3], 4 = value}})
	// A completion with another tag answers a command that this process
	// waits for no more: root_answer_step skips it. stoppable: a wait of a
	// line, which Escape ends as a wait with no answer; the root service
	// can start a service first, and the principal must not wait for it
	// with no way out. A wait outside a line reads no Escape.
	deadline := system.time() + time_limit
	if stoppable {
		call_stoppable_enter()
	}
	defer if stoppable {
		call_stoppable_leave()
	}
	for {
		wait := system.wait_begin()
		if record, came, done := system.root_answer_step(&requests, request_count, system.time(), deadline, &abandoned_connects); done {
			return record, came
		}
		if stoppable {
			if intrinsics.atomic_load_explicit(&work.cancel, .Relaxed) != 0 {
				return {}, false
			}
			system.wait_word(&wait, &work.cancel, 0)
		}
		system.wait_records(&wait, &requests.completions)
		system.wait_end(&wait, deadline)
	}
}

// request asks the root service to start or to stop a process. It gives
// nothing: a refusal is the error of the line, with the error record of the
// root service.
request :: proc "contextless" (kind: root_ring.Root_Command, name: string) -> Value {
	completion, answered := request_record(kind, name)
	if !answered {
		return fail_no_answer()
	}
	if completion.kind != u32(call_outcome.Call_Outcome.Succeeded) {
		return fail_root("", completion)
	}
	return {}
}

// grants gives what a process has from the root service, of the grants
// that the root service can revoke: one row for each grant that it holds,
// then one for each grant that it lost.
grants :: proc "contextless" (arguments: []Value) -> Value {
	name := arguments[0].text
	completion, answered := request_record(.Grants, name)
	if !answered {
		return fail_no_answer()
	}
	if completion.kind != u32(call_outcome.Call_Outcome.Succeeded) {
		return fail_root("", completion)
	}
	columns := [5]Column{text_column("process", 32), text_column("grant", 24), text_column("state", 8), integer_column("principal"), text_column("principal_name", 32)}
	table, made := made_table("Grant", columns[:])
	if !made {
		return fail("grants: the line has no room for the description")
	}
	// Who the grants are for: the principal of the session of the process.
	principal_name := system.name_unpack({completion.values[3], completion.values[4], completion.values[5], completion.values[6]})
	for set, pass in ([2]system.Root_Grants{transmute(system.Root_Grants)completion.values[0], transmute(system.Root_Grants)completion.values[1]}) {
		for grant in system.Root_Grant {
			if grant not_in set {
				continue
			}
			row := made_row(&table)
			made_text(&table, row, 0, name)
			made_text(&table, row, 1, system.root_grant_names[grant])
			made_text(&table, row, 2, pass == 0 ? "held" : "lost")
			made_integer(&table, row, 3, i64(completion.values[2]))
			made_text(&table, row, 4, system.name_of(principal_name[:]))
		}
	}
	return made_value(&table, "grants")
}

// principal_create asks the root service for a new named principal. The
// passphrase is never a text of the console: the console keeps each line in
// its history, so the passphrase is typed in the window of unlock.
principal_create :: proc "contextless" (arguments: []Value) -> Value {
	completion, answered := request_record(.Principal_Create, arguments[0].text)
	if !answered {
		return fail_no_answer()
	}
	if completion.kind != u32(call_outcome.Call_Outcome.Succeeded) {
		return fail_root("", completion)
	}
	return {}
}

// lock_session ends the session of the named principal that is unlocked,
// and gives the count of its processes that stopped.
lock_session :: proc "contextless" (arguments: []Value) -> Value {
	completion, answered := request_record(.Principal_Lock, "")
	if !answered {
		return fail_no_answer()
	}
	if completion.kind != u32(call_outcome.Call_Outcome.Succeeded) {
		return fail_root("", completion)
	}
	return {kind = .Integer, integer = i64(completion.values[0])}
}

@(rodata)
principal_state_names := [root_ring.Principal_State]string {
	.Absent   = "absent",
	.Machine  = "machine",
	.Locked   = "locked",
	.Unlocked = "unlocked",
	.Creating = "creating",
}

// first_bytes_hexadecimal writes 8 bytes, in their order in memory, as 16
// hexadecimal digits: the start of a key or of a measure as a reader
// compares it.
first_bytes_hexadecimal :: proc "contextless" (value: u64) -> (digits: [16]u8) {
	bytes := transmute([8]u8)value
	hexadecimal := "0123456789abcdef"
	for item, index in bytes {
		digits[2 * index] = hexadecimal[item >> 4]
		digits[2 * index + 1] = hexadecimal[item & 15]
	}
	return
}

// list_principals gives one row for each principal of the root service.
list_principals :: proc "contextless" (arguments: []Value) -> Value {
	columns := [5]Column{integer_column("number"), text_column("name", 32), text_column("state", 12), text_column("public_key_head", 16), text_column("measure_head", 16)}
	table, made := made_table("Principal", columns[:])
	if !made {
		return fail("principals: the line has no room for the description")
	}
	for number in u64(0) ..< 2 {
		completion, answered := request_record(.Principals, "", number)
		if !answered {
			return fail_no_answer()
		}
		if completion.kind != u32(call_outcome.Call_Outcome.Succeeded) {
			continue // No record with this number.
		}
		// A state that names no member is refused: it is not taken for a
		// state that the root service did not give.
		state, state_known := enum_word.member_of_word(root_ring.Principal_State, completion.values[0])
		if !state_known {
			return fail("principals: the root service gave a state that names no state of a principal")
		}
		principal_name := system.name_unpack({completion.values[1], completion.values[2], completion.values[3], completion.values[4]})
		row := made_row(&table)
		made_integer(&table, row, 0, i64(number))
		made_text(&table, row, 1, system.name_of(principal_name[:]))
		made_text(&table, row, 2, principal_state_names[state])
		if completion.values[5] != 0 {
			key_digits := first_bytes_hexadecimal(completion.values[5])
			made_text(&table, row, 3, string(key_digits[:]))
		}
		// The measure of the system belongs to the machine: principal 0.
		if number == 0 && completion.values[6] != 0 {
			measure_digits := first_bytes_hexadecimal(completion.values[6])
			made_text(&table, row, 4, string(measure_digits[:]))
		}
	}
	return made_value(&table, "principals")
}

// revoke asks the root service to end one grant of a process that runs,
// and gives the count of the holdings that ended.
revoke :: proc "contextless" (arguments: []Value) -> Value {
	name := arguments[0].text
	for grant in system.Root_Grant {
		if system.root_grant_names[grant] != arguments[1].text {
			continue
		}
		if grant == .Palette && name == "console" {
			palette_stop_before_revoke() // The table and the ring end with the grant.
		}
		completion, answered := request_record(.Revoke, name, u64(grant))
		if !answered {
			return fail_no_answer()
		}
		if completion.kind == u32(call_outcome.Call_Outcome.Succeeded) {
			return {kind = .Integer, integer = i64(completion.values[0])}
		}
		return fail_root("", completion)
	}
	return fail("no grant has the name ", arguments[1].text, ": the grants are log, machine, image, log_records, store, network, acts_for_principal, history, debug, palette")
}

// replace asks the root service to give a module where a module imports
// another one. An empty second text removes the replacement.
replace :: proc "contextless" (arguments: []Value) -> Value {
	name, by := arguments[0].text, arguments[1].text
	value: u64
	if by != "" {
		for &entry, index in system.image_entries(image) {
			if system.name_of(entry.name[:]) == by {
				value = u64(index + 1)
			}
		}
		if value == 0 {
			return fail("no module has the name ", by)
		}
	}
	completion, answered := request_record(.Replace, name, value)
	if !answered {
		return fail_no_answer()
	}
	// The outcome and its record come from the root service: the border of
	// a completion reads them, and the reason of a refusal is read by the
	// named fields of the contract (root_ring.Replace_Refusal).
	outcome, refusal := call_outcome.completion_outcome(completion.kind, completion.values)
	if outcome == .Succeeded {
		return {}
	}
	reason, _, known := root_ring.replace_refusal_of_record(outcome, refusal)
	if !known {
		return fail_root("", completion)
	}
	switch reason {
	case .No_Grant:
		return fail("the console has no grant to change the replacement table")
	case .Entry_Past_The_Image:
		return fail("no module has the name ", by)
	case .Replaces_Itself:
		return fail("a module does not replace itself")
	case .No_Module:
		return fail(by == "" ? "no replacement of the module " : "no module has the name ", name)
	case .No_Signed_Row:
		// Its log line gives the whole reason (docs/MODULE_CONTRACT.md, "Who
		// may replace a module").
		return fail("the root service refused the replacement of ", name, " by ", by, ": no signed row names it")
	case .Chain:
		return fail("a chain of replacements is refused: ", name, ", ", by)
	case .Row_Not_Authentic:
		return fail("the root service refused the replacement of ", name, " by ", by, ": its signature does not verify")
	case .List_Not_Valid:
		return fail("the root service refused the replacement of ", name, " by ", by, ": the replacement list breaks its format")
	case .Table_Full:
		return fail("the replacement table is full")
	}
	return fail_root("", completion)
}

// list_replacements gives the replacement table of the machine.
list_replacements :: proc "contextless" (arguments: []Value) -> Value {
	if replacement_table == nil {
		return fail("the console has no grant to read the replacement table")
	}
	columns := [4]Column{text_column("module", 32), text_column("by", 32), text_column("module_hash_head", 16), text_column("by_hash_head", 16)}
	table, made := made_table("Replacement", columns[:])
	if !made {
		return fail("replacements: the line has no room for the description")
	}
	for item in system.replacements_read(replacement_table, &replacement_records) {
		row := made_row(&table)
		from_head, to_head: [16]u8
		made_text(&table, row, 0, module_name_of(item.from))
		made_text(&table, row, 1, module_name_of(item.to))
		made_text(&table, row, 2, hash_head_text(&from_head, item.from))
		made_text(&table, row, 3, hash_head_text(&to_head, item.to))
	}
	return made_value(&table, "replacements")
}

start_process :: proc "contextless" (arguments: []Value) -> Value {
	// The log service can be the process that starts: the console tries
	// its connection again.
	line_records_try_again()
	name := arguments[0].text
	// The ring holds a name of 31 bytes: request refuses a longer one, as
	// a cut name can be the name of another process.
	if len(name) >= len(system.Name) {
		return request(.Start, name)
	}
	if len(arguments) == 2 {
		return start_with_list(name, arguments[1])
	}
	// The console asks for the process handle: it names the process as
	// the end Started of a wiring, and its record outputs by their typed
	// names (streams.odin).
	packed := system.name_pack(name)
	completion, answered := disk_request(.Start, {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3], 4 = u64(root_ring.Start_Wiring_List.None), 5 = u64(root_ring.Start_Answer.Process_Handle)}, 3000)
	if !answered {
		return fail_no_answer()
	}
	if outcome, _ := call_outcome.completion_outcome(completion.kind, completion.values); outcome != .Succeeded {
		return fail_root("", completion)
	}
	if !stream_owner_keep(name, system.Handle(completion.values[0])) {
		return fail("start: ", name, " runs, and has no typed name: the console names the record outputs of ", u64(STREAM_OWNER_CAPACITY), " processes that it started at most, until one of them stops")
	}
	return {}
}

// edit_object starts `edit` on the named text object of a store of the
// principal of this console (Root_Command.Start_Edit).
edit_object :: proc "contextless" (arguments: []Value) -> Value {
	store_name := arguments[0].text
	object_path := arguments[1].text
	store_refusal, store_offset := root_ring.edit_store_validate(store_name)
	switch store_refusal {
	case .None:
	case .Empty:
		return fail("edit: the store name is empty; it must have 1 to ", u64(root_ring.EDIT_TARGET_STORE_LIMIT), " bytes")
	case .Too_Long:
		return fail("edit: the store name has ", u64(len(store_name)), " bytes; a store name has at most ", u64(root_ring.EDIT_TARGET_STORE_LIMIT))
	case .Bad_Byte:
		return fail("edit: the byte ", u64(store_offset), " of the store name is not valid")
	}
	path_refusal, path_offset := root_ring.edit_path_validate(object_path)
	switch path_refusal {
	case .None:
	case .Empty:
		return fail("edit: the object name is empty; it must have 1 to ", u64(root_ring.EDIT_TARGET_PATH_LIMIT), " bytes")
	case .Too_Long:
		return fail("edit: the object path has ", u64(len(object_path)), " bytes; a path has at most ", u64(root_ring.EDIT_TARGET_PATH_LIMIT))
	case .Too_Deep:
		return fail("edit: the object path has too many nested trees")
	case .Bad_Segment:
		return fail("edit: the object path has an invalid name at byte ", u64(path_offset))
	}
	if requests.head == nil {
		return fail_no_answer()
	}
	path_memory, create_status := system.memory_create(1)
	if create_status != .Ok {
		return fail("edit: cannot allocate memory for the object path: ", op.STATUS_NAMES[create_status])
	}
	mapped, map_status := system.memory_map(path_memory)
	if map_status != .Ok {
		system.close(path_memory)
		return fail("edit: cannot map memory for the object path: ", op.STATUS_NAMES[map_status])
	}
	intrinsics.mem_copy_non_overlapping(mapped, raw_data(object_path), len(object_path))
	system.memory_unmap(mapped)
	given_path, give_status := system.give(requests_memory, path_memory, {.Read})
	system.close(path_memory)
	if give_status != .Ok {
		return fail("edit: cannot give the object path to the root service: ", op.STATUS_NAMES[give_status])
	}
	packed := system.name_pack(store_name)
	completion, answered := disk_request(.Start_Edit, {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3], 4 = u64(given_path), 5 = u64(len(object_path)), 6 = 0}, 3000)
	if !answered {
		return fail_no_answer()
	}
	if outcome, _ := call_outcome.completion_outcome(completion.kind, completion.values); outcome != .Succeeded {
		return fail_root("edit", completion)
	}
	return {}
}

// How long the console waits for the completion of Start_From_Disk, in
// milliseconds. The root service ends a load at its own deadline at the
// latest, and answers then: twice that deadline only ends a wait for a root
// service that answers nothing.
START_FROM_DISK_ANSWER_LIMIT :: 2 * disk_process.LOAD_DEADLINE_MILLISECONDS

// start_from_disk asks the root service to start a disk process, and waits
// for the end of its load. The name and the hash are checked here first: a
// record of the root ring holds a name of 23 bytes and a hash of 32, and a
// cut name can be the name of another process.
start_from_disk :: proc "contextless" (arguments: []Value) -> Value {
	name := arguments[0].text
	problem, offset := disk_process.name_problem(name)
	switch problem {
	case .None:
	case .Empty:
		return fail("start_from_disk: the name is empty; it must have 1 to ", u64(disk_process.NAME_LIMIT), " bytes")
	case .Too_Long:
		return fail("start_from_disk: the name has ", u64(len(name)), " bytes; the name of a disk process has at most ", u64(disk_process.NAME_LIMIT))
	case .Bad_Byte:
		return fail("start_from_disk: the byte ", u64(offset), " of the name cannot be in the name of an entry of a tree")
	case .Store_Name:
		return fail("start_from_disk: \"", name, "\" is the name of the store of the module files, and no name of a process")
	case .Table_Name:
		return fail("start_from_disk: \"", name, "\" is the name of the object of the disk grant table, and no name of a process")
	}
	// An empty hash: the root service takes the hash of the row of the
	// nickname in the disk grant table.
	hash: [disk_process.HASH_SIZE]u8
	if arguments[1].text != "" {
		parsed: bool
		hash, parsed = disk_process.hash_parse(arguments[1].text)
		if !parsed {
			return fail("start_from_disk: the hash must be ", u64(disk_process.HASH_DIGITS), " hexadecimal digits, or empty for the hash of the row of the nickname; the argument has ", u64(len(arguments[1].text)), " bytes, or a byte that is no digit")
		}
	}
	hash_values := transmute([4]u64)hash
	name_values := disk_process.name_pack(name)
	record, answered := disk_request(.Start_From_Disk, {0 = hash_values[0], 1 = hash_values[1], 2 = hash_values[2], 3 = hash_values[3], 4 = name_values[0], 5 = name_values[1], 6 = name_values[2]}, START_FROM_DISK_ANSWER_LIMIT)
	if !answered {
		return fail_no_answer()
	}
	if record.kind == u32(call_outcome.Call_Outcome.Succeeded) {
		return {}
	}
	return start_from_disk_refusal(name, record)
}

// disk_request sends one command of the disk processes to the root service,
// whose values are not a name of 31 bytes, and waits for its completion.
// answered is false when the root service gave none before the limit.
disk_request :: proc "contextless" (kind: root_ring.Root_Command, values: [7]u64, time_limit: u64) -> (completion: ring.Record, answered: bool) {
	if requests.head == nil {
		return {}, false
	}
	request_count += 1
	system.send(&requests.commands, ring.Record{kind = u32(kind), tag = request_count, values = values})
	deadline := system.time() + time_limit
	for {
		wait := system.wait_begin()
		if record, came, done := system.root_answer_step(&requests, request_count, system.time(), deadline, &abandoned_connects); done {
			return record, came
		}
		system.wait_records(&wait, &requests.completions)
		system.wait_end(&wait, deadline)
	}
}

// nickname_check refuses a nickname that the root service would refuse
// for a grant, with the line of the command: a record holds 23 bytes, and
// a cut nickname can be the nickname of another process.
nickname_check :: proc "contextless" (command_name: string, nickname: string) -> (refusal: Value, refused: bool) {
	problem, offset := disk_process.nickname_grant_problem(nickname)
	switch problem {
	case .None:
		return {}, false
	case .Empty:
		return fail(command_name, ": the nickname is empty; it must have 1 to ", u64(disk_process.NAME_LIMIT), " bytes"), true
	case .Too_Long:
		return fail(command_name, ": the nickname has ", u64(len(nickname)), " bytes; a nickname has at most ", u64(disk_process.NAME_LIMIT)), true
	case .Bad_Byte:
		return fail(command_name, ": the byte ", u64(offset), " of the nickname is not a letter, a digit, '-' or '_'"), true
	case .Store_Name, .Table_Name:
		return fail(command_name, ": \"", nickname, "\" is a name that the store of the module files keeps for itself"), true
	}
	return {}, false
}

// disk_grant_named gives the start grant whose name is a text, in any
// case: "store" or "Store".
disk_grant_named :: proc "contextless" (text: string) -> (grant: start_grant.Grant, found: bool) {
	for name, candidate in start_grant.GRANT_NAMES {
		if len(name) != len(text) {
			continue
		}
		same := true
		for index in 0 ..< len(name) {
			first, second := name[index], text[index]
			if first >= 'A' && first <= 'Z' {
				first += 'a' - 'A'
			}
			if second >= 'A' && second <= 'Z' {
				second += 'a' - 'A'
			}
			if first != second {
				same = false
				break
			}
		}
		if same {
			return candidate, true
		}
	}
	return .Root_Ring, false
}

// disk_grant_command asks the root service to give a grant to the file that
// a nickname names, or to take it. The root service refuses a grant that
// no command gives, with its sentence on the log.
disk_grant_command :: proc "contextless" (command_name: string, action: root_ring.Disk_Grant_Action, arguments: []Value) -> Value {
	nickname := arguments[0].text
	if refusal, refused := nickname_check(command_name, nickname); refused {
		return refusal
	}
	grant, found := disk_grant_named(arguments[1].text)
	if !found {
		return fail(command_name, ": no start grant has the name ", arguments[1].text, "; a command gives a disk process the grant store")
	}
	packed := disk_process.name_pack(nickname)
	completion, answered := disk_request(.Disk_Grant, {0 = packed[0], 1 = packed[1], 2 = packed[2], 4 = u64(action), 5 = u64(grant)}, 3000)
	if !answered {
		return fail_no_answer()
	}
	if completion.kind != u32(call_outcome.Call_Outcome.Succeeded) {
		return fail_root(command_name == "allow" ? "allow: " : "disallow: ", completion)
	}
	return {}
}

allow :: proc "contextless" (arguments: []Value) -> Value {
	return disk_grant_command("allow", root_ring.Disk_Grant_Action.Allow, arguments)
}

disallow :: proc "contextless" (arguments: []Value) -> Value {
	return disk_grant_command("disallow", root_ring.Disk_Grant_Action.Disallow, arguments)
}

// remote_client_request sends Remote_Client with a key of 64 hexadecimal
// digits and an action, and waits for its completion. A key of another form
// is refused here: the record carries 32 bytes.
remote_client_request :: proc "contextless" (command_name: string, text: string, action: root_ring.Remote_Client_Action, uses: remote.Client_Uses = {}) -> (completion: ring.Record, refusal: Value, refused: bool) {
	// A key and a hash of BLAKE3 have the same form: 32 bytes in 64
	// hexadecimal digits.
	key, parsed := disk_process.hash_parse(text)
	if !parsed {
		return {}, fail(command_name, ": the key must be 64 hexadecimal digits; the argument has ", u64(len(text)), " bytes, or a byte that is no digit"), true
	}
	key_values := transmute([4]u64)key
	answered: bool
	completion, answered = disk_request(.Remote_Client, {0 = key_values[0], 1 = key_values[1], 2 = key_values[2], 3 = key_values[3], 4 = u64(action), 5 = remote.client_uses_word(uses)}, 3000)
	if !answered {
		return {}, fail_no_answer(), true
	}
	if completion.kind != u32(call_outcome.Call_Outcome.Succeeded) {
		prefix := "remote_disallow: "
		switch command_name {
		case "remote_allow":
			prefix = "remote_allow: "
		case "remote_display_allow":
			prefix = "remote_display_allow: "
		}
		return completion, fail_root(prefix, completion), true
	}
	return completion, {}, false
}

// remote_allow asks the root service to allow the key of a client of
// `remote` for the principal of this console.
remote_allow :: proc "contextless" (arguments: []Value) -> Value {
	_, refusal, refused := remote_client_request("remote_allow", arguments[0].text, root_ring.Remote_Client_Action.Allow, {.Calls})
	if refused {
		return refusal
	}
	return {}
}

// remote_display_allow asks the root service to allow the key of a viewer
// of `remote_display` for the principal of this console: the view of the
// screen, or the view and the input. A text that names no such use is
// refused here, before any record.
remote_display_allow :: proc "contextless" (arguments: []Value) -> Value {
	uses: remote.Client_Uses
	switch arguments[1].text {
	case "view":
		uses = {.View}
	case "view_and_input":
		uses = {.View, .Input}
	case:
		return fail("remote_display_allow: the use must be \"view\" or \"view_and_input\"")
	}
	_, refusal, refused := remote_client_request("remote_display_allow", arguments[0].text, root_ring.Remote_Client_Action.Allow, uses)
	if refused {
		return refusal
	}
	return {}
}

// remote_disallow asks the root service to end the grant of the key of a
// client of `remote`, and gives the count of the connections that ended.
remote_disallow :: proc "contextless" (arguments: []Value) -> Value {
	completion, refusal, refused := remote_client_request("remote_disallow", arguments[0].text, root_ring.Remote_Client_Action.Revoke)
	if refused {
		return refusal
	}
	if completion.values[1] == root_ring.REMOTE_CLIENT_KEY_CAN_COME_BACK {
		return {kind = .Text, text = scratch_text(completion.values[0], " connections to services ended; the disk grant table of this principal did not take the revocation, so the key can come back at the next start of the machine: revoke it again then")}
	}
	return {kind = .Text, text = scratch_text(completion.values[0], " connections to services ended")}
}

// remote_clients gives one row for each key of a client of `remote` that
// the principal of this console allowed: the root service gives a caller
// the rows of its own principal only.
remote_clients :: proc "contextless" (arguments: []Value) -> Value {
	columns := [4]Column{text_column("key", 64), integer_column("principal"), text_column("state", 9), text_column("uses", 21)}
	table, made := made_table("Remote_Client", columns[:])
	if !made {
		return fail("remote_clients: the line has no room for the description")
	}
	// The rows of the client table, then the contested keys of the disk
	// grant table, whose rows are rows of another principal.
	for place in u64(0) ..< remote.CLIENT_READ_PLACES {
		completion, answered := disk_request(.Remote_Client, {4 = u64(root_ring.Remote_Client_Action.Read), 5 = place}, 3000)
		if !answered {
			return fail_no_answer()
		}
		if completion.kind != u32(call_outcome.Call_Outcome.Succeeded) {
			return fail_root("remote_clients: ", completion)
		}
		if completion.values[5] == 0 {
			continue // A free row, or a row of another principal.
		}
		key := transmute([32]u8)[4]u64{completion.values[0], completion.values[1], completion.values[2], completion.values[3]}
		digits: [64]u8
		hexadecimal := "0123456789abcdef"
		for item, index in key {
			digits[2 * index] = hexadecimal[item >> 4]
			digits[2 * index + 1] = hexadecimal[item & 15]
		}
		row := made_row(&table)
		made_text(&table, row, 0, string(digits[:]))
		made_integer(&table, row, 1, i64(completion.values[4]))
		// A word that names no state is refused: the row does not say
		// "holds" for a key whose state the console cannot read.
		state, state_ok := enum_word.member_of_word(root_ring.Remote_Client_State, completion.values[6])
		if !state_ok {
			return fail("remote_clients: the root service gave the state ", completion.values[6], ", which names no state of a client key")
		}
		state_text: string
		switch state {
		case .Holds:
			state_text = "holds"
		case .Locked:
			state_text = "locked"
		case .Contested:
			state_text = "contested"
		}
		made_text(&table, row, 2, state_text)
		// The uses come through their border too: a word that names no set
		// is refused, not shown as some use.
		uses, uses_ok := remote.client_uses_of_word(completion.values[5])
		if !uses_ok {
			return fail("remote_clients: the root service gave the uses ", completion.values[5], ", which name no set of uses")
		}
		uses_text := "calls"
		switch {
		case uses >= {.Calls, .View, .Input}:
			uses_text = "calls, view and input"
		case uses >= {.Calls, .View}:
			uses_text = "calls and view"
		case uses >= {.View, .Input}:
			uses_text = "view and input"
		case .View in uses:
			uses_text = "view"
		}
		made_text(&table, row, 3, uses_text)
	}
	return made_value(&table, "remote_clients")
}

// nickname_move asks the root service to point a nickname to another file:
// its grants and its store follow.
nickname_move :: proc "contextless" (arguments: []Value) -> Value {
	nickname := arguments[0].text
	if refusal, refused := nickname_check("nickname_move", nickname); refused {
		return refusal
	}
	hash, parsed := disk_process.hash_parse(arguments[1].text)
	if !parsed {
		return fail("nickname_move: the hash must be ", u64(disk_process.HASH_DIGITS), " hexadecimal digits; the argument has ", u64(len(arguments[1].text)), " bytes, or a byte that is no digit")
	}
	hash_values := transmute([4]u64)hash
	packed := disk_process.name_pack(nickname)
	completion, answered := disk_request(.Nickname_Move, {0 = hash_values[0], 1 = hash_values[1], 2 = hash_values[2], 3 = hash_values[3], 4 = packed[0], 5 = packed[1], 6 = packed[2]}, 3000)
	if !answered {
		return fail_no_answer()
	}
	if completion.kind != u32(call_outcome.Call_Outcome.Succeeded) {
		return fail_root("nickname_move: ", completion)
	}
	return {}
}

// disk_persistence asks the root service how long a row of the disk grant
// table lasts across a restart: "persist", "forget", or "global" for the
// global setting. An empty nickname sets the global setting.
disk_persistence :: proc "contextless" (arguments: []Value) -> Value {
	nickname := arguments[0].text
	if nickname != "" {
		if refusal, refused := nickname_check("disk_persistence", nickname); refused {
			return refusal
		}
	}
	persistence: disk_process.Persistence
	switch arguments[1].text {
	case "persist":
		persistence = .Persist
	case "forget":
		persistence = .Forget
	case "global":
		if nickname == "" {
			return fail("disk_persistence: the global setting is \"persist\" or \"forget\"")
		}
		persistence = .Global
	case:
		return fail("disk_persistence: the setting is \"persist\", \"forget\" or \"global\"")
	}
	packed := disk_process.name_pack(nickname)
	completion, answered := disk_request(.Disk_Grant_Persistence, {0 = packed[0], 1 = packed[1], 2 = packed[2], 4 = u64(persistence)}, 3000)
	if !answered {
		return fail_no_answer()
	}
	if completion.kind != u32(call_outcome.Call_Outcome.Succeeded) {
		return fail_root("disk_persistence: ", completion)
	}
	return {}
}

// machine_passphrase asks the root service to set the machine passphrase.
// The passphrase is never a text of the console: the console keeps each
// line in its history, so it is typed in the window of unlock.
machine_passphrase :: proc "contextless" (arguments: []Value) -> Value {
	completion, answered := request_record(.Machine_Passphrase, "")
	if !answered {
		return fail_no_answer()
	}
	if completion.kind != u32(call_outcome.Call_Outcome.Succeeded) {
		return fail_root("", completion)
	}
	return {}
}

// machine_seal asks the root service for a machine key that the TPM seals
// to the measure of the system. The recovery key is never a text of the
// console: the window of unlock shows it one time.
machine_seal :: proc "contextless" (arguments: []Value) -> Value {
	completion, answered := request_record(.Machine_Seal, "")
	if !answered {
		return fail_no_answer()
	}
	if completion.kind != u32(call_outcome.Call_Outcome.Succeeded) {
		return fail_root("", completion)
	}
	return {}
}

// start_policy_choose asks the root service to run a start policy from the
// disk at the next start. The nickname and the hash are checked here
// first, as for start_from_disk: a record holds 23 bytes and 32.
start_policy_choose :: proc "contextless" (arguments: []Value) -> Value {
	nickname := arguments[0].text
	if refusal, refused := nickname_check("start_policy_choose", nickname); refused {
		return refusal
	}
	// An empty hash: the root service takes the hash of the row of the
	// nickname in the disk grant table.
	hash: [disk_process.HASH_SIZE]u8
	if arguments[1].text != "" {
		parsed: bool
		hash, parsed = disk_process.hash_parse(arguments[1].text)
		if !parsed {
			return fail("start_policy_choose: the hash must be ", u64(disk_process.HASH_DIGITS), " hexadecimal digits, or empty for the hash of the row of the nickname; the argument has ", u64(len(arguments[1].text)), " bytes, or a byte that is no digit")
		}
	}
	hash_values := transmute([4]u64)hash
	packed := disk_process.name_pack(nickname)
	completion, answered := disk_request(.Start_Policy_Choice, {0 = hash_values[0], 1 = hash_values[1], 2 = hash_values[2], 3 = hash_values[3], 4 = packed[0], 5 = packed[1], 6 = packed[2]}, 3000)
	if !answered {
		return fail_no_answer()
	}
	if completion.kind != u32(call_outcome.Call_Outcome.Succeeded) {
		return fail_root("start_policy_choose: ", completion)
	}
	return {}
}

// start_policy_default asks the root service to end the choice of a start
// policy: a nickname of no byte.
start_policy_default :: proc "contextless" (arguments: []Value) -> Value {
	completion, answered := disk_request(.Start_Policy_Choice, {}, 3000)
	if !answered {
		return fail_no_answer()
	}
	if completion.kind != u32(call_outcome.Call_Outcome.Succeeded) {
		return fail_root("start_policy_default: ", completion)
	}
	return {}
}

// passphrase_change asks the root service to change the passphrase of the
// principal of the session of this console. The passphrases are never a
// text of the console: the console keeps each line in its history, so they
// are typed in the window of unlock.
passphrase_change :: proc "contextless" (arguments: []Value) -> Value {
	return change_request(root_ring.Principal_Change.Passphrase)
}

// recovery_key_change asks the root service for a new recovery key of the
// principal of the session of this console. The recovery key is never a
// text of the console: the window of unlock shows it one time.
recovery_key_change :: proc "contextless" (arguments: []Value) -> Value {
	return change_request(root_ring.Principal_Change.Recovery_Key)
}

// change_request sends Principal_Change and waits for the end of the
// change, which takes the time of the typing in the window of unlock: the
// line gives what changed, or why nothing changed. The wait has no time
// limit, as a principal types at its own pace; Escape ends the wait, and
// the window of unlock goes on.
change_request :: proc "contextless" (change: root_ring.Principal_Change) -> Value {
	if requests.head == nil {
		return fail_no_answer()
	}
	call_stoppable_enter()
	defer call_stoppable_leave()
	request_count += 1
	system.send(&requests.commands, ring.Record{kind = u32(root_ring.Root_Command.Principal_Change), tag = request_count, values = {4 = u64(change)}})
	for {
		// A completion with another tag answers a command that this
		// process waits for no more; an abandoned Connect closes its
		// handles here.
		if record, came, _ := system.root_answer_step(&requests, request_count, 0, system.WAIT_FOREVER, &abandoned_connects); came {
			if record.kind != u32(call_outcome.Call_Outcome.Succeeded) {
				return fail_root("", record)
			}
			return change_result(record.values[0], record.values[1])
		}
		if intrinsics.atomic_load_explicit(&work.cancel, .Relaxed) != 0 {
			return fail("Escape: the console waits no more for the end of the change; the window of unlock goes on")
		}
		wait: system.Wait
		system.wait_records(&wait, &requests.completions)
		system.wait_word(&wait, &work.cancel, 0)
		system.wait_end(&wait)
	}
}

// change_result gives the value of the line from the end of a change. The
// values come from the root service, so each one is checked against its
// enum: a word that names no member is refused, and never read as a known
// end or cause.
change_result :: proc "contextless" (end_value: u64, problem_value: u64) -> Value {
	end, end_ok := enum_word.member_of_word(principals.Change_End, end_value)
	if !end_ok {
		return fail("the root service gave the end ", end_value, " of the change, which names no end")
	}
	switch end {
	case .Passphrase_Changed, .Recovery_Key_Changed:
		return {kind = .Text, text = principals.change_end_sentences[end]}
	case .Refused:
		problem, problem_ok := enum_word.member_of_word(principals.Change_Problem, problem_value)
		if !problem_ok {
			return fail(principals.change_end_sentences[end], ": the root service gave the cause ", problem_value, ", which names no cause")
		}
		return fail(principals.change_end_sentences[end], ": ", principals.change_problem_sentences[problem])
	case .None, .Cancelled, .Seed_Too_Weak, .Seal_Failed, .Store_Failed, .Store_Unknown:
		return fail(principals.change_end_sentences[end])
	}
	return fail("the root service gave the end ", end_value, " of the change, which names no end")
}

// start_from_disk_refusal makes the line fail with the refusal of the root
// service for a disk process. The kinds of this command get a sentence of
// their own: the general sentence of a kind speaks of a tag, of a tree or
// of a process of the system. The record stays the record of the root
// service.
start_from_disk_refusal :: proc "contextless" (name: string, completion: ring.Record) -> Value {
	error := errors.completion_record(completion.values)
	already := failed
	result: Value
	kind, kind_ok := errors.kind_of_word(error.kind)
	if !kind_ok {
		// fail_root says that the word names no kind.
		return fail_root("start_from_disk: ", completion)
	}
	// An open choice: the few kinds of this command get a sentence of their
	// own, and each other kind of the large set gets the general sentence.
	#partial switch kind {
	case .Not_Authentic:
		head := transmute([8]u8)u64(error.value)
		result = fail("start_from_disk: the bytes of \"", name, "\" in the store module_files do not have the hash asked: their hash starts with ", system.Hash{head[:]}, ". The root service started nothing")
	case .Absent:
		if errors.Unit(error.unit) == .Grants {
			result = fail("start_from_disk: the nickname \"", name, "\" has no row in the disk grant table: name the hash of its file")
		} else {
			result = fail("start_from_disk: the store module_files has no object \"", name, "\"")
		}
	case .Exists:
		if errors.Unit(error.unit) == .Grants {
			head := transmute([8]u8)u64(error.value)
			result = fail("start_from_disk: the nickname \"", name, "\" names the file whose hash starts with ", system.Hash{head[:]}, ": nickname_move points it to another file. The root service started nothing")
		} else {
			result = fail("start_from_disk: a module of the boot image has the name \"", name, "\": start() starts that module, and a disk process takes another name")
		}
	case .Reserved:
		result = fail("start_from_disk: the root service gives the name \"", name, "\" a grant, or keeps it for the system: a disk process takes no grant by its name")
	case .Busy:
		result = fail("start_from_disk: another load from the disk runs: try again after it")
	case .Malformed:
		result = fail("start_from_disk: the loader refused the file of \"", name, "\": it is no module, or an import of it is not in the boot image. The log has the load error")
	case:
		return fail_root("start_from_disk: ", completion)
	}
	if !already {
		argument_names := [2]string{"name", "hash"}
		failure_record_set(error, "root.Start_From_Disk", argument_names[:])
	}
	return result
}

stop_process :: proc "contextless" (arguments: []Value) -> Value {
	// The console that stops itself keeps its line history first: the
	// save after the line never comes.
	if arguments[0].text == "console" {
		history_save()
	}
	return request(.Stop, arguments[0].text)
}

time :: proc "contextless" (arguments: []Value) -> Value {
	return {kind = .Integer, integer = i64(system.time())}
}

hash :: proc "contextless" (arguments: []Value) -> Value {
	result := blake3.hash(transmute([]u8)arguments[0].text)
	return {kind = .Text, text = hex_text(result[:])}
}

length :: proc "contextless" (arguments: []Value) -> Value {
	return {kind = .Integer, integer = i64(len(arguments[0].text))}
}

text :: proc "contextless" (arguments: []Value) -> Value {
	return {kind = .Text, text = scratch_text(arguments[0].integer)}
}

// character_text gives the UTF-8 of one code point: the text encoding
// refuses each code point that is no character of a text.
character_text :: proc "contextless" (arguments: []Value) -> Value {
	code_point := arguments[0].integer
	encoded: [text_encoding.CHARACTER_BYTES_LIMIT]u8
	length := 0
	if code_point >= 0 && code_point <= 0x10FFFF {
		length = text_encoding.character_encode(rune(code_point), encoded[:])
	}
	if length == 0 {
		return fail(code_point, " is no character of a text")
	}
	return {kind = .Text, text = scratch_text(string(encoded[:length]))}
}

repeat :: proc "contextless" (arguments: []Value) -> Value {
	start := scratch_count
	for _ in 0 ..< arguments[1].integer {
		if len(arguments[0].text) > len(scratch) - scratch_count - 256 {
			return fail("the text is too long")
		}
		scratch_text(arguments[0].text)
	}
	return {kind = .Text, text = string(scratch[start:scratch_count])}
}

// buffer_create makes a memory object. The console holds the handle until
// release.
buffer_create :: proc "contextless" (arguments: []Value) -> Value {
	memory, status := system.memory_create(u64(arguments[0].integer))
	if status != .Ok {
		return fail("the budget of the console cannot pay for ", arguments[0].integer, " pages")
	}
	return {kind = .Handle, integer = i64(memory)}
}

// buffer_byte reads one byte of a memory object: the console maps the
// object for the time of the command.
buffer_byte :: proc "contextless" (arguments: []Value) -> Value {
	memory := system.Handle(arguments[0].integer)
	kind, _, _ := system.handle_state(memory)
	// A refused handle has no pages, so it has no byte.
	pages, _ := system.memory_size(memory)
	size := kind == .Memory ? pages * system.PAGE_SIZE : 0
	if arguments[1].integer < 0 || u64(arguments[1].integer) >= size {
		return fail(kind == .Memory ? "the memory object has no byte " : "the handle names no memory object: byte ", arguments[1].integer)
	}
	address, status := system.memory_map(memory, {})
	if status != .Ok {
		return fail("the console cannot map the memory object")
	}
	defer system.memory_unmap(address)
	return {kind = .Integer, integer = i64(([^]u8)(address)[arguments[1].integer])}
}

BYTES_MOST :: 4096 // The most bytes that one call of bytes copies.

// buffer_bytes copies bytes of a memory object into the memory of the
// line: the console maps the object for the time of the command. The value
// keeps the place of its first byte, for the view.
buffer_bytes :: proc "contextless" (arguments: []Value) -> Value {
	memory := system.Handle(arguments[0].integer)
	first, count := arguments[1].integer, arguments[2].integer
	kind, _, _ := system.handle_state(memory)
	if kind != .Memory {
		return fail("bytes: the handle names no memory object")
	}
	if count < 0 || count > BYTES_MOST {
		return fail("bytes: the count is ", count, "; it is 0 to ", i64(BYTES_MOST))
	}
	// A refused handle has no pages, so it has no byte.
	pages, _ := system.memory_size(memory)
	size := pages * system.PAGE_SIZE
	if first < 0 || u64(first) > size || u64(count) > size - u64(first) {
		return fail("bytes: the memory object has ", size, " bytes; it does not have ", count, " bytes from the byte ", first)
	}
	copied := table_bytes(int(count))
	if copied == nil && count > 0 {
		return fail("bytes: the line has no room for ", count, " bytes")
	}
	address, status := system.memory_map(memory, {})
	if status != .Ok {
		return fail("the console cannot map the memory object")
	}
	defer system.memory_unmap(address)
	copy(copied, ([^]u8)(address)[first:][:count])
	return {kind = .Bytes, integer = first, record = copied}
}

release :: proc "contextless" (arguments: []Value) -> Value {
	if kind, _, _ := system.handle_state(system.Handle(arguments[0].integer)); kind != .Memory {
		return fail("release closes a memory object that buffer made")
	}
	system.close(system.Handle(arguments[0].integer))
	return {}
}

// list_variables gives one row for each variable: its name, its type, and
// its value as a text.
list_variables :: proc "contextless" (arguments: []Value) -> Value {
	columns := [3]Column{text_column("name", VARIABLE_NAME_SIZE), text_column("type", 64), text_column("value", 128)}
	table, made := made_table("Variable", columns[:])
	if !made {
		return fail("variables: the line has no room for the description")
	}
	for &variable in variables {
		if variable.name_count == 0 {
			continue
		}
		value := variable.value
		row := made_row(&table)
		type_buffer: [64]u8
		type_writer := system.Writer {
			buffer = type_buffer[:],
		}
		// A list has no type of the module contract: its kind names it.
		if value.kind == .List {
			system.write_part(&type_writer, kind_names[.List])
		} else {
			system.write_type(&type_writer, value.file, type_of_kind(value.kind), value.detail)
		}
		value_buffer: [128]u8
		value_writer := system.Writer {
			buffer = value_buffer[:],
		}
		switch value.kind {
		case .List:
			system.write_part(&value_writer, i64(value.detail))
			system.write_part(&value_writer, value.detail == 1 ? " item" : " items")
		case .None, .Bytes, .Stream, .Record_Input, .Record_Literal, .Member, .Function, .Hash, .Boolean, .Record_With, .Module_Ref, .Tree_Ref, .Recipe_Ref, .Follow_Ref, .Store_Ref, .Plan_Value, .Project_Value:
			// No value, and bytes with no description: the cell stays empty.
			// No variable keeps a Stream or a member not typed.
		case .Integer:
			system.write_part(&value_writer, value.integer)
		case .Enum:
			// The member, as a line names it.
			if described, problem := module.enum_type(value.file, value.detail); problem == .None {
				if name, named := module.enum_name_of_value(value.file, described, value.integer); named {
					system.write_part(&value_writer, ".")
					system.write_part(&value_writer, name)
					break
				}
			}
			system.write_part(&value_writer, value.integer)
		case .Handle:
			system.write_part(&value_writer, u64(value.integer))
		case .Text:
			system.write_part(&value_writer, value.text)
		case .Record:
			record_fields_text(&value_writer, value)
		case .Table:
			if rows, ok := table_of(value); ok {
				system.write_part(&value_writer, i64(rows.rows))
				system.write_part(&value_writer, rows.rows == 1 ? " row" : " rows")
			}
		}
		made_text(&table, row, 0, string(variable.name[:variable.name_count]))
		made_text(&table, row, 1, system.written(&type_writer))
		made_text(&table, row, 2, system.written(&value_writer))
	}
	return made_value(&table, "variables")
}

clear :: proc "contextless" (arguments: []Value) -> Value {
	screen_clear()
	return {}
}

// Nesting depth of the active child project console (0 in the root console).
project_console_depth: u32

shutdown :: proc "contextless" (arguments: []Value) -> Value {
	// The line history first: the machine stops in the call.
	history_save()
	_, status := system.call(.Machine_Stop, u64(machine), 0)
	if status != .Ok {
		return fail("the console has no grant to stop the machine")
	}
	return {}
}

exit_project_console :: proc "contextless" (arguments: []Value) -> Value {
	if project_console_depth == 0 {
		return fail("exit: no project console is active")
	}
	history_save()
	system.stop(.Done)
}
