## Communication

### Ring

A ring is a pair of queues of fixed records in shared memory, between two processes or between a process and the kernel: one queue carries command records, the other carries completion records.

A ring is the one way that two processes communicate, and the base interface of the kernel. Each queue has one writer and one reader, so no queue operation takes a lock or enters the kernel; a side that must wait uses the word wait. The receiver checks each record as hostile data. Examples: the kernel ring of each thread, the call ring of a call host, the terminal ring. A ring is not a pipe or a socket: it carries typed records, not a stream of bytes.

The design: `docs/ARCHITECTURE.md`, "K4. Rings and wait".

Do not use: pipe, socket, channel, port, message queue.

### Capacity

The capacity of a ring is the count of records of each of its queues: a power of two, fixed when the ring is created.

The capacity comes from the size of the memory of the ring: a ring of 1 + capacity / 32 pages, from 32 to 65536 records. It is not written in the shared memory, so the other side cannot lie about it. Choose it for the largest burst of the writer: a full queue slows the writer to the speed of the reader.

Do not use: buffer size, queue depth, backlog.

### Terminal

A terminal is a process that shows the text records of one other process, keeps its lines, and gives its keys to that process.

The root service starts a process and its terminal, and gives the two a terminal ring and a text region. The terminal starts no process. It reads records as fast as the process writes them and draws at the rate of the screen, so the display does not slow the process. The kernel has no concept of a terminal.

A terminal is not a TTY: no escape sequence and no line discipline exist. The process edits its own line and sends records with a kind and typed fields.

The contract: `src/library/modus/terminal/terminal.odin`.

Do not use: TTY, pty, terminal emulator, standard output, standard input.

### Shared queue

A shared queue is one queue of records in shared memory that several threads write and several threads read, with no lock.

Each record has a turn word that says whose turn it is on it. A writer takes a count with one compare-and-exchange, writes the record, then changes the turn word; a reader does the same. So two writers never have the same count, and a reader never reads a record before its writer completed it. Use a shared queue when several threads take work from one place; use a ring for one writer and one reader.

The contract: `src/library/modus/contract/ring/shared.odin`.

Do not use: MPMC queue, channel, work queue, mailbox.

### Event

An event is a count in memory that several threads wait on (`system.Event`): a thread adds 1 to it and wakes all the threads that wait.

A waiter reads the count, reads the state that the event changes, then waits while the count holds the value that it read: an event between the read and the wait ends the wait at once. The zero value is an event that never happened. An event in shared memory works between processes.

Do not use: condition variable, semaphore, signal, barrier.

### Source library

A source library is a named folder of source packages that a module compiles in.

An import of the source names the library and the package: `modus:contract/ring`. The system has three: `modus`, the public library (`src/library/modus`); `internal`, for the internal parts (`src/library/internal`); `modulus`, for the kernel parts (`src/modulus`, `modulus:iommu`). The flag of the compiler is `-collection`. A source library is not a module: it has no file, no hash and no edge in the module graph.

The design: `src/md/infrastructure/repository_layout.md`, "The two source libraries of the modules".

Do not use: collection, libc, static library.

### Public library

The public library is the source library `modus`: the contract packages and the support packages, the one part of the sources of the system that ships.

Its folder is `src/library/modus`: `modus:contract/ring` for a contract, `modus:quic` for a support package. A module of the system and an outside module import it with the same lines. The SDK holds its folder whole. A package that a program outside the repository needs is a package of the public library. It holds no internal part and no kernel part.

The design: `src/md/infrastructure/repository_layout.md`, "The two source libraries of the modules".

Do not use: standard library, runtime, framework.

### Internal part

An internal part is a package of the source library `internal` that one module alone compiles in, with its host tests.

It holds the logic of one module that has host tests: a module package has none, because a test of it builds the whole module for the host. Its folder is `src/library/internal/<module>/<part>`, and its import line names the module: `internal:storage/storage_tree`. The tool refuses its import from another module, and the compiler refuses it in the kernel and in an outside module, which get no flag `internal`. It never ships.

The design: `src/md/infrastructure/repository_layout.md`, "Where the internal part of a module lives".

Do not use: private part, private package, helper package, program package.

### Kernel part

A kernel part is a pure package in a folder under `src/modulus`, which the kernel alone compiles in, with its host tests.

A kernel part is imported through the source library `modulus`: `modulus:iommu`. Only the kernel, the host tests of its parts and the tool get that source library: the compiler refuses the import in a module, and the tool in each other file of `src/`. A kernel part is pure: the tool refuses a package variable that is not `@(rodata)`, a foreign block, asm and an intrinsic that reads the machine. A format that only the kernel reads, such as an ACPI table, is a kernel part and not a contract.

The design: `src/md/infrastructure/repository_layout.md`.

Do not use: kernel module (a module is a file), kernel library, subsystem.

### Module group

A module group is the folder of `src/modules` that holds the modules of one use: `system`, `libraries`, `demonstrations` or `tests`.

The group of a module is the folder of its source, and the tool reads it from there. It is not a second format: the module file holds no group, and the loader and the root service never read it. Its folder is `src/modules/<group>/<module>`: `src/modules/system/root`. A release leaving out the group `tests` is planned work of `ROADMAP.md`.

The design: `src/md/infrastructure/repository_layout.md`.

Do not use: role (a role is a contract, and the grants of a program are its start grant set), category, kind of module.

### Test module

A test module is a module that only a machine test starts or imports, and that is wrong on purpose or shows nothing of its own.

Examples: `test_callee` and `test_caller`, the loader test of an import; `hostile_exports`, exports that are wrong on purpose; `lonely`, a module whose import is not in the boot image; `debug_target`, the module that the test of the debugger debugs. A test module is in the module group `tests`. A module that shows a property to a principal is a demonstration, not a test module, even when a machine test starts it.

The design: `src/md/infrastructure/repository_layout.md`.

Do not use: fixture (a fixture is the small tree of a host test), mock, stub.

### Outside module

An outside module is a module whose source is in a folder outside the repository of the system.

Its developer writes one Odin package that imports the packages of the system from the source library, and a module build file. The command `modustool module-build` builds it with the two steps of a module of the system, and writes the module file and the debug object in a folder of the developer. An outside module is a module as each other: one file, named by its hash, with described exports. The tool does not yet put one in a boot image.

The design: `docs/TOOLS.md`, "A module from a source outside the repository".

Do not use: third-party module, external module, plugin.

### SDK

The SDK, the development kit of the system, is the archive of a release that holds what an outside module needs, with no checkout of the system and with no Nix.

It holds the public library, the runtime, the module files of the module group `libraries` of the release, the contract description, the tool and a manifest of the hash of each file, at the paths of a checkout. Its file is `modus-sdk-<release number>.tar.zst`; the release signature covers it. The compiler that it names is a second archive of the release. A module that imports a library module runs on the release of its SDK. It is not a checkout: it holds no internal part and no kernel.

The design: `src/md/infrastructure/sdk.md`.

Do not use: devkit, toolchain, distribution.

### Outside source

An outside source is the source of a work of others in C that a module of the system compiles in, which the flake fetches at one commit and patches.

The repository holds no source file of the work: the folder `src/outside/<work>` holds its license, the patches of the system, the files of the system that it needs and the thin libc. The flake makes one folder of the store from them, and the tool compiles its C files into the module. The row of the module table names it with `c_source`. `chibicc` is the first one. It is not an outside module, whose Odin source is in a folder of a developer.

The design: `src/md/infrastructure/outside_source.md`; the guide: `docs/TOOLS.md`, "The outside sources of a module".

Do not use: vendored code, third-party source.

### Rich module

A rich module is an outside module whose interface is built with `gui_toolkit`, the toolkit of rich modules.

It imports `gt:` packages and the core library of Odin on the target modus, which a source of `src/` never does. It still draws through the draw table, and later through the WebGPU subset. A module of the system in `src/modules` uses the `interface` package instead. Examples: an editor, the browser `wren` once it is ported.

The design: `src/md/features/desktop_to_browser.md`.

Do not use: rich client, GUI application.

### Module build file

A module build file is the file `module.txt` in the folder of an outside module, which holds the fields of a row of the module table.

Each line is `key: value`. The key `name` is the name of the module. The keys `imports`, `defines` and `library` are the imports by name, the settings of the compiler and whether the module is a library module; each can be absent. The tool refuses a line that it does not know. A module of the system has no module build file: its row is in the module table of the tool.

The design: `docs/TOOLS.md`, "A module from a source outside the repository".

Do not use: manifest, build script, project file.

### Documentation

The documentation of a module is the text that the module carries in its file for a reader: one line that says what the module is, a text for the module, and a text for each export.

The build tool takes it from the comments of the source. It is part of the file, so it has the hash of the module: a text cannot describe another version of the code. With the description of each export, it is all that a reader needs to use the module: `help()` in the console and the pages of the site show it. A documentation text keeps the Markdown of its comment, which the process `manual` reads.

The design: `docs/MODULE_CONTRACT.md`, "1. The module file".

Do not use: man page, help file, docstring, README.

### Time page

The time page is one page that the kernel writes and that each process can only read, at a fixed address (`TIME_ADDRESS`).

It holds the milliseconds since boot, the frequency of the cycle counter and the cycle counter at the time 0. A process reads the time with one load from memory, with no kernel entry; a finer time comes from the cycle counter.

Do not use: vDSO, vsyscall, clock system call.

### Real-time clock

The real-time clock is the clock of the machine that keeps the date when the machine is off.

On a PC it is the CMOS clock, at the ports 0x70 and 0x71. The process `date` reads it at its start and each 10 s, and writes the date page.

Do not use: RTC (in text), hardware clock, BIOS clock.

### Date

A date is a count of milliseconds since 1970-01-01 00:00:00 UTC.

Leap seconds are not counted: a day has 86400 seconds.

Do not use: timestamp, wall clock, epoch time, Unix time (in text).

### Date page

The date page is one page that the root service creates and maps read-only into each process that it starts, at its fixed range.

The process `date` writes there the date of the time 0 of the system. So a process reads the date with no kernel entry: that date plus the milliseconds of the time page. The page also holds the time zone, which the process `date` copies from the settings page, so the local time is in one page.

Do not use: wall-clock page, vDSO, clock page.

### Time zone

The time zone is the fixed offset from UTC, in minutes, that the principal chooses with the setting `time_zone`: the local time is the date of UTC and this offset.

Its text is the form of ISO 8601: `+08:00`, `-03:30`. It goes from `-12:00` to `+14:00` by quarters of an hour, and `+00:00`, UTC, is the default. It has no summer time. The process `settings` writes it on the settings page; the process `date` copies it into the date page. The bar shows the local time, and the date of the system stays in UTC. It is not a named zone with rules (`Europe/Paris`): the system has no tz database.

The design: `src/md/features/time_zone.md`.

Do not use: timezone (one word), TZ, locale (for this), UTC offset (for the setting).

### Back pressure

Back pressure is the rule of a queue whose writer waits while the queue is full, so that no record is lost.

It is the first form of the rule of the path of a key: the input service takes no byte of the keyboard from the controller while the input ring has no room, and the console takes no key from the terminal ring while 128 keys wait for the end of a line. The writer waits with `system.wait_room`. A writer that cannot wait (the compositor for a window, the terminal for its process) uses the second form: a stated capacity, and a loss period for each refusal.

The design: `docs/ARCHITECTURE.md`, "The path of a key".

Do not use: writer stall, push back.

### Loss period

A loss period is the time from the first record that a full queue refuses to the moment when the queue takes a record again.

A writer that cannot wait counts each record that it loses, and writes two lines in the log for one period: one when the loss begins, one with the count when it ends. It writes no line for each record: a queue that refuses 1000 keys must not fill the log. The compositor has one for each window, the terminal one for its process, the console one for the keys that wait during a line. The code: `key_path.Loss_Period` (`src/library/modus/key_path`). The design: `ARCHITECTURE.md`, "The path of a key".

Do not use: drop window, loss burst.

### Terminal ring

The terminal ring is the ring between a process and its terminal.

In the command queue, a record from the process has a kind (text, status, clear, edit line, hint line, completion list, runs of code), a count of bytes in the text region and a style; it has no place on the screen. In the completion queue, a record from the terminal is a key record; it holds 4096 keys. The terminal never waits for a process: a key that finds the queue full is lost and counted. A record whose kind names no record is refused and counted, with one line at the first one.

The contract: `src/library/modus/terminal/terminal.odin`.

Do not use: escape sequence, control character, stream.

### Key record

A key record is a record from a terminal to its process: the code of one key that was pressed, its character, and the modifiers that were held (Shift, Control).

The character is a code point, or 0 for a key with no character: é of the layout of France is 233. A process that keeps the character writes its UTF-8. The process decides what a key does. The terminal keeps Page Up and Page Down for its own view.

Do not use: standard input, character device, raw mode, cooked mode.

### Edit line

The edit line is the one line that a process changes: its line of input with a cursor, or a line that says what the process does now.

The process sends the text and the place of the cursor; the terminal draws it after the last line. The process owns the editing, so the terminal needs no knowledge of a line of input.

Do not use: line discipline, readline, cursor addressing, prompt.

### Line editor

The line editor is the procedures of `src/library/modus/line_editor` that change an edit line with keys: the caret, a character at the caret, Backspace, Delete.

They have no state of their own: the line is a record of the process. The line is UTF-8, and each key moves the caret over a whole character, or inserts or removes a whole character. The caret is a place in bytes, always before a whole character.

Do not use: readline, line discipline.

### Hint line

A hint line is one dim line that a process shows under its edit line: the signature of the call at the caret, or how to use the list that is open.

It has a long form and a short form; the terminal shows the long one when it fits in its columns. The terminal draws it in the free row. A new one replaces the one before.

The design: `docs/CONSOLE.md`, "5. Who draws the list, and the line under the edit line".

Do not use: tooltip, status (for this), echo area.

### Free row

The free row is the row of the view of a terminal under the edit line, which the terminal keeps free at all times.

The hint line is drawn in it, so the text does not move when a hint comes or goes.

Do not use: spacer, padding line.

### Completion list

A completion list is the names that can take the place of the name at the caret, best first, with one chosen row.

The process gives the rows, at most 8 at a time; its terminal draws them over its text, at the edit line. In the console the fuzzy match orders the names. With more names than rows the list has a scroll bar, which takes the pointer: the terminal tells the process the first row that the pointer asks for, and the process moves its view and its chosen row.

The design: `docs/CONSOLE.md`, "5. Who draws the list, and the line under the edit line".

Do not use: dropdown, popup, autocomplete menu, suggestions.

### Chosen row

The chosen row is the one line of a list, a menu or a completion list that Enter or a press takes.

It is drawn in the chosen blue `colors.chosen` with its text in white, on every display of the system.

The rules: `docs/DESIGN.md`, "The chosen row".

Do not use: selection (for this), highlight, focused item.

### Fuzzy match

A fuzzy match is a match where the characters of a query appear in a name in their order, with gaps allowed, lower and upper case equal.

A score orders the names that match: a match at the first byte of the name, after `.` or `_`, or right after the match before scores more, and a gap scores less. Example: `stwr` matches `storage.write`.

The design: `docs/CONSOLE.md`, "3. The fuzzy match".

Do not use: fuzzy search, subsequence search, filter (for this).

### Frecency

Frecency is a bounded score of how often and how lately the principal used a name, decaying by uses rather than by clock time.

It adds a small bonus (0 to 8 points) to a fuzzy match score so frequently used names come first among near equal matches, without overriding a better structural match. The console derives it from its line history; the palette keeps it in the memory of the compositor.

The design: `src/md/features/fuzzy_match.md`, "The frecency model", and `docs/CONSOLE.md`, "3. The fuzzy match".

Do not use: popularity, usage score, MRU score.

### Line history

The line history is the lines that were entered in the console, in a ring of bytes in its memory, the newest first.

The console keeps it in its store, so it survives a stop of the console.

The design: `docs/CONSOLE.md`, "6. The line history across a stop".

Do not use: history (alone), scrollback, command log.

### Line history file

The line history file is the line history as bytes, kept in the history store: a version, the lines, and a BLAKE3 hash (`src/library/modus/line_editor/history_file.odin`).

A file that fails a check gives an empty history: a damaged file never stops the console.

Do not use: history dump, .bash_history.

### History search

The history search is the completion list over the line history: Control-R opens it, and the fuzzy match orders the lines.

The age of a line is its tie order: for equal scores the newest line comes first. Enter puts the chosen line in the edit line, where it can be changed before it runs.

The design: `docs/CONSOLE.md`, "1. The keys".

Do not use: reverse-i-search, incremental search.

### Text region

The text region is the shared memory beside a terminal ring where the process writes the bytes of its text, in order (4 MiB).

A record gives only a count of bytes: the terminal keeps its own place, so a process cannot make the terminal read another place. The terminal has the right Read only on it.

Do not use: scrollback (for this), pipe buffer.

### Run

A run of text is a set of bytes of text that have one style: a line is a list of runs.

One text record of the terminal ring is one run, of 256 bytes at most. The record with the flag End_Line ends the line.

Do not use: span, segment, chunk.

### Style

A style says what a run of text is and how to show it (8 bytes): a tone, flags (end of the line, own color, reverse), a code kind, a value kind and a color.

The zero style is plain text. The color of a run is its own color with the flag Color; else the color of its value kind, when it has one; else the color of its code kind, when it has one; else the color of its tone. The terminal chooses each color but the own color in the appearance in force when it draws, so a line written before a change of the appearance takes the colors of the new one: the console sends the value kind of a value, not its color.

Do not use: attribute, SGR, escape code.

### Tone

A tone is what a run of text means: default, dim, strong, good, warning, bad, accent or number.

The process gives the meaning; the terminal chooses the color of each tone, so one table changes the colors of every process.

Do not use: color code, severity (for text).

### Token

A token is the smallest part of a line of the console: a name, a number, a text, an operator, the arrow `->`, the pipe operator `|>`, or one byte of no other token.

One scanner (`src/library/modus/console_language`) gives them to the parser of Lex and to the colors of the console, so the colors never disagree with the parser.

Do not use: lexeme, word (for this).

### Code kind

A code kind is what a part of a line of the console or of a row of its list is: a function, a module, a type, a parameter, a variable, a number, a text, an unfinished text, an operator, the arrow, words that are not code, or unknown.

A process sends kinds, not colors; the terminal maps each kind to a code class (`src/library/modus/terminal/code_runs.odin`).

The design: `docs/CONSOLE.md`, "7. The colors of the code".

Do not use: token type, syntax class, highlight group.

### Code class

A code class is one of the seven classes of the colors of code: keyword, type, literal, name, directive, comment and punctuation.

One table gives each class its color, for the site and for the terminal, so code has the same colors everywhere.

The rules: `docs/DESIGN.md`, "The colors of code".

Do not use: theme color, scope, highlight group.

### Run of code

A run of code is a part of one row with one code kind: a start, a length and the kind (4 bytes).

A row has at most 64 runs. A run gives a color, never text: a run that is refused, or a row with too many runs, leaves the text whole and plain.

Do not use: span (for this), highlight range.

### Status

A status is one line that a process replaces at any time, with a value and a total.

The terminal shows it apart from the lines: no line is drawn again. A process shows its progress this way, with no carriage return in a stream.

Do not use: progress bar hack, carriage return.

### Call form

The call form is where a call of an export puts each of its arguments and finds each result: the C convention of the machine, in a subset that every compiler gives.

On x86-64 an export takes up to 12 integer arguments (`module.PARAMETER_CAPACITY`): the first 6 in registers, the others on the stack, one word of 8 bytes each. The results are in `rax` and `rdx`. A record, a slice and a table are never passed by value: the argument is an address. The one routine `export_call` calls each export from an array of values. It is not the calling convention of a language: an Odin procedure of the convention `"odin"` passes one more argument, its context.

The design: `docs/MODULE_CONTRACT.md`, "4. The call form".

Do not use: ABI (for this), calling sequence.

### Direct call

A direct call is a call of an export of a module that is in the address space of the caller.

The arguments are where the call form puts them: up to 12 integers, 6 in registers and the others on the stack, and 8 floats; a record, a text or a table goes as the address of memory of the caller. A direct call costs what a call of a function costs: a call through an import slot took 3.5 ns. The callee runs with all the access of the caller, so a direct call is for a module that the caller trusts.

The design: `docs/MODULE_CONTRACT.md`, "4. The call form".

Do not use: in-process call, local call.

### Isolated call

An isolated call is a call of an export of a module that runs in another process: the arguments travel in a ring.

An isolated call lets a process call a module that it does not trust: the module runs in a call host, or in a service, with no handle but those that the call lends. The caller writes the argument record in the call region and a command record in the call ring; the receiver copies the record once, checks it, and calls the export. A fault of the module stops the call host only. An isolated call costs a wake of the other process and its answer.

The design: `docs/MODULE_CONTRACT.md`, "The isolated call, as implemented".

Do not use: remote call, RPC, IPC call.

### Record description

A record description is the part of the description of a module that gives the name, the size and the fields of one record type that the module names: in an export, a log fact, a record output or a record input.

The tool writes each record type once in the table `Records`, whichever declaration names it. A field is an Integer, a Handle or a Text of a fixed size; each declaration refuses the kinds that it cannot carry. A record has 256 bytes at most and holds values only, never an address. Two equal record descriptions name the same record: a replacement, a wiring and the console compare them field by field.

The design: `docs/MODULE_CONTRACT.md`, "Records and handles, as implemented"; for log facts, `src/md/features/log_facts.md`; for record outputs and record inputs, `src/md/features/module_outputs.md`.

Do not use: struct type, schema, class.

### Call host

A call host is the process that loads one module and executes the isolated calls of its exports (`src/modules/system/host`).

The caller starts one call host for each module. The call host has no handle but its call ring, its call region, its budget and the log. It checks the file of the module, loads it, and answers a first completion: Ok, or `Load_Failed` with its load error. A call has no time limit: the caller ends it by closing the process handle, and the next call starts a new call host. Example: `isolate("sample")` in the console.

The design: `docs/MODULE_CONTRACT.md`, "The isolated call, as implemented".

Do not use: worker, helper process, server.

### Call ring

A call ring is the ring between a caller and a call host or a service: one command record is one isolated call.

The kind of the command is the index of the export, its first value the offset of the argument record in the call region. A lent handle travels through it, so the receiver can prove that the handle came from the caller.

Do not use: channel, pipe.

### Call region

A call region is the memory object that a caller and a call host or a service share: the caller writes the argument record and the bytes of its texts and tables in it.

A record result, a Table result and the error record come back in it. Each side treats it as hostile memory: the receiver copies the argument record once before it checks it.

Do not use: shared buffer, arena.

### Connection

A connection is one call ring and one call region between one caller and one service that serves its own exports.

The root service makes it and ends it, and gives the service the grant of the caller with it: the principal of its session, an amount, and whether it acts for the principal. Example: "root: connected console to the service storage, acting for principal 0".

Do not use: session, socket, channel.

### Service ring

A service ring is the ring between the root service and a service that serves its own exports.

One command record names one connection that starts or ends, with the grant of the caller. A service has no other way to receive a caller: it cannot be reached by a name.

Do not use: control channel, accept queue.

### Connection page

A connection page is one page for each connection that the root service writes alone, and that the client and the holder map with the right Read only.

It holds the holder serial (the process serial of the holder that serves the connection), the `Connection_State` (`Held`, `Holder_Stopped`, `Ended`), and the stop cause and the stop outcome of the last holder that stopped. A client waits on it beside its call ring. When a holder starts again, the connection keeps its call ring and its call region, and only the page changes. It is paid by the work budget of the connection. Designed, not built.

The design: `src/md/features/supervision.md`, "What a client sees when the holder of its role stops".

Do not use: heartbeat, status channel, reconnect event.

### Call in doubt

A call in doubt is a call that a holder took from its call ring and did not answer before it stopped: it ran, or it did not.

The library of the client knows it: the holder serial changed, the command was read, and no completion came. At the new holder serial, the library writes it again once, if its export is idempotent or carries a request serial. A call of an export that is neither, and a call whose replay met a second stop, goes to its caller with the status `Holder_Stopped`.

The design: `src/md/features/supervision.md`, "The calls in flight".

Do not use: pending call, lost call, retry.

### Request serial

A request serial is the number that the library of a client gives each call of an export that is not idempotent, one more on each connection.

The holder writes the serial and the completion record of the call in the same commit as its effect. A replayed call whose serial is at or below the kept serial gets the kept completion and does not run again. A holder keeps 8 answers for each connection, and the library holds a ninth such call until a place is free. The answer of such a call is in the values of its completion, never in the call region.

The design: `src/md/features/supervision.md`, "The rule that makes a replay safe".

Do not use: idempotency key, sequence number, nonce.

### Argument record

An argument record is the record that holds the arguments of one isolated call: one field for each parameter, in order.

It is derived from the description of the export: an Integer is 8 bytes, a Text is `{offset, count}` in the call region, a table is 32 bytes. Nobody writes a second encoding.

The design: `docs/MODULE_CONTRACT.md`, "The isolated call, as implemented".

Do not use: message, payload, marshalled arguments.

### Kernel ring

A kernel ring is the ring between one thread and the kernel: each kernel operation is a command record in it.

Each thread has its own kernel ring, one page after its thread record, with 32 places. A thread writes several commands, then enters the kernel once with `syscall`; the kernel runs them in order and writes one completion record for each. So a batch of operations costs one entry. A command that finds the completion queue full stays in the command queue, unrun, until the thread reads its completions and enters again.

The design: `docs/ARCHITECTURE.md`, "K4. Rings and wait".

Do not use: system call table.

### Record

A record is a block of bytes of a fixed layout with typed fields, in which all-zero bytes are a valid value.

All data between processes, and between a process and the kernel, is records: a ring record, a context, an error record, a row of a table. A record holds no address that the other side must follow, and no text that it must parse. A new field at the end is zero for an old writer.

The rule: `docs/PROPERTIES.md`, "Zero is initialization (ZII)".

Do not use: struct, message, packet, object.

### Command record

A command record is a record that asks the other side of a ring for one operation.

Its kind names the operation, its tag lets the caller match the completion, and its seven values are the arguments.

Do not use: request, message, call.

### Completion record

A completion record is a record that reports the result of one command record.

Its kind is a status (0 is success) and its tag is the tag of the command. When the status is not 0, its seven values are an error record; else they are the results.

Do not use: response, reply, event.

### Device queue

A device queue is the queue that a device defines for its own commands, such as a virtio queue.

The kernel maps it into one process, and is then off the path of the data: the process and the device exchange records with no kernel entry.

The rule: `docs/PROPERTIES.md`, "5. Kernel off the data path".

Do not use: ring (reserved for program-to-program).

### Zero is initialization (ZII)

Zero is initialization is the rule that all-zero bytes are a valid value with a defined meaning, for every record of the system.

Memory from the kernel is zero, so it is already initialized. Handle 0 names no object, index 0 of each table is empty, a zero field of a command means "default", and a zero error record means "no error". A new field at the end of a record is zero for old writers, so records grow with no version number.

The rule: `docs/PROPERTIES.md`, "Zero is initialization (ZII)".

Do not use: default constructor.

### Result drawer

A result drawer is the one procedure of the console that draws the results of one kind: an Integer, a Text, a Record, a Table, a Handle, Bytes or an error.

A command of the console gives a result and never writes to the terminal; the console draws the one result of a line with the drawer of its kind. A drawer knows no command: for a record or a table it reads the description of the record, so one drawer serves each table of each service. It is not a formatter of one command, and it is not the terminal: the terminal draws the cells that the console sends.

The design: `docs/CONSOLE.md`, "Results and their drawers".

Do not use: printer, formatter, renderer, pretty-printer.

### Short name of an export

A short name of an export is a built-in name of the console that calls one export of a service: `processes()` calls `monitor.processes()`.

The fact that the command gives is a fact of the service, and the console holds no copy of it. The command connects to the service when the console has no connection to it yet, then calls the export through the connection, as any call of `service.export`. When the service does not run, the line fails with the error of the connection. It is not a second implementation of the command in the console.

The design: `docs/CONSOLE.md`, "The built-in commands and the services".

Do not use: alias, shortcut, wrapper command.

### Pipe operator

The pipe operator `|>` of a line of the console gives the value on its left as the first argument of the call on its right: `a |> f(b)` is `f(a, b)`.

A line then reads in the order in which its calls run: `processes() |> where(name = "server") |> rows` is `rows(where(processes(), name = "server"))`. The operator has the lowest priority and adds no meaning: the console writes the line with calls in calls before it runs it, and a fault of the operator fails the line before any call. It is not a pipe between processes: no text goes from one process to another. `|` alone is no operator.

The design: `docs/CONSOLE.md`, "The pipe operator".

Do not use: pipe (alone), pipeline, bar, forward operator.

### Placeholder

The placeholder `_` marks the argument of the call on the right of `|>` that takes the value on its left: `a |> f(b, _)` is `f(b, a)`.

With no `_`, the value is the first argument. A call holds at most one `_`, as one whole argument. A `_` outside the call on the right of `|>`, inside a call nested in it, or inside an expression is refused before any call. Example: `compile(src, t) |> bytes(t, 0, _) |> assemble(f)`. It is not a variable: `_` alone is no name.

The design: `src/md/features/pipe_operator.md`, "The placeholder `_`".

Do not use: hole, wildcard, blank (for this), `$`.

### Condition

A condition is the argument of `where` in the console: a field of the record of a table, an operator and a value, as `block = 12` or `level = Warning`.

The parser reads it as a condition, never as an expression, so the field is a name of the record description and not a variable. The operators are `=`, `!=`, `<`, `<=`, `>` and `>=`; a Text and a status take `=` and `!=` only, and a status takes the name of a member of its contract enum. The console refuses a field that the record lacks and a value of another kind before a row is read, and before any call when it knows the record. It is no text that a process parses.

The design: `docs/CONSOLE.md`, "Conditions".

Do not use: filter expression, where clause.

### Record output

A record output is a stream of records of one record type that a module declares and writes while it works, with no known end.

The module file names each record output in its table `Record_Outputs`, with its record description. A wiring joins it to the record input of another process through one output ring for each reader; a declaration with no wiring costs nothing. Each process also has the record output `log`, which only its starter wires. A record output loses no record: a full ring makes its writer wait, or refuses the record and says so. It replaces standard output, and it is never the lossy log of the kernel. Example: `requests: system.Record_Output(Access_Record)`, which the console names `server.requests`.

The design: `src/md/features/module_outputs.md`.

Do not use: output (alone, except after "record output" in the same passage), channel, standard output, stdout, pipe, port, topic, sink.

### Record input

A record input is a stream of records of one record type that a module declares and reads.

The module file names each record input in its table `Record_Inputs`, with the index of its record description and of the record of its wiring terms, and its count of wirings. The reader checks each record against its record description, as hostile data. A reader with no declared record input, such as the console, and a generic record input receive the record description of the record output with their end. A record input is not the Input of the group Access (`docs/glossary/access.md`, "Input"), which is the keys and the pointer, and not the input service.

The design: `src/md/features/module_outputs.md`.

Do not use: input (alone, except after "record input" in the same passage), channel, standard input, stdin, port, source (for this).

### Output ring

An output ring is the ring that carries the records of one record output to one reader: compartments of the size of the record in its command queue, and completions of 64 bytes.

The root service makes it from the budget of the asker of the wiring, and gives one end to the writer and one to the reader. Each side computes the size of a compartment and the capacity from the record description and the size of the memory, never from the shared bytes. Its first compartment is a joined record. The completion queue carries the refusals of the reader and the acknowledgement of the end, not one answer for each record.

The design: `src/md/features/module_outputs.md`, "The ring and its records".

Do not use: pipe, stream buffer, channel.

### Compartment

A compartment is the part of the command queue of an output ring that holds one record: the compartment word, then the record, rounded up to a multiple of 64 bytes.

Both sides compute its size from the record description: a record of 72 bytes takes a compartment of 128 bytes, a log record of 256 bytes one of 320. The writer copies a whole compartment in, and the reader copies it out into private memory before it checks it (`output.record_of_compartment`). A compartment is not a place of the storage service ("Place") and not an import slot ("Import slot").

The design: `src/md/features/module_outputs.md`, "The ring and its records".

Do not use: place (for this), slot (for this), cell (for this), frame (for this), entry (for this).

### Compartment word

A compartment word is the first 8 bytes of each compartment of an output ring: the kind of the compartment (a record, a gap record, an end record or a joined record) and the serial of the record.

The serial counts the records of the record output from 0, so a copy of one record has one serial in each ring. The reader takes the kind through one border, which refuses a word that names no kind, and refuses a serial that does not follow: the serials of a ring jump only by the count of a joined record or a gap record. All-zero bytes are a record with the serial 0.

The design: `src/md/features/module_outputs.md`, "The ring and its records".

Do not use: frame header, envelope, place word, slot word.

### Gap record

A gap record is the compartment of an output ring that says how many records are missing there: records that the ring refused because it was full, or records that the writer lost before it wrote them.

A writer that does not wait gets `Full` and counts each refused record, and a ring of the pace `Never_Holds_Writer` refuses for its reader alone. When the ring has room again, the library writes one gap record with the count before the next record. A writer that lost records of its source says it with `system.output_gap`: the log service does so for the records that the kernel wrote over before `log.follow` read them. So the reader knows where records are missing and how many, and the console draws it as one dim row.

The design: `src/md/features/module_outputs.md`, "Fan-out and flow control".

Do not use: drop marker, overflow record.

### End record

An end record is the last compartment of an output ring that the writer writes: the end of its stream, with an error record that is zero for a clean end.

The reader reads each record before it, acknowledges it in the completion queue, and closes its end. A writer that stops with no end record gets an end word from the root service in place of it, with its stop cause and its stop outcome.

The design: `src/md/features/module_outputs.md`, "The end of a stream".

Do not use: EOF, close message, terminator.

### Wiring

A wiring is the act that joins one record output of one process to one record input of another process, and the record of that act in the root service.

The command `Wire` of the root ring makes it, or a wiring list of `Start`. Each end is a process whose start the asker asked for, a service of a connection of the asker, or the asker. The root service checks that the two record descriptions are equal, makes the output ring from the budget of the asker, and records a grant that the asker or the principal ends. A wiring made while the writer runs starts at a joined record. No process reaches a record output by a name.

The design: `src/md/features/module_outputs.md`, "The wiring and its rights".

Do not use: subscription, binding, connection (a connection is a call ring and a call region), pipe.

### Wiring ring

The wiring ring is the ring between the root service and a process that declares a record output or a record input: one command record gives one end of an output ring, with its handle, its pace or its wiring terms.

The process finds it at the handle 16 of its context, or an asker with its list page, and answers each command with one completion, then writes `Closed` when it closes that end. Each handle comes through the memory of the ring, so the process proves it. No command ends an end: the end page of the wiring says it. The writer reads the wiring ring at each write with one compare of its counters. A process that declares no record output and no record input has none.

The design: `src/md/features/module_outputs.md`, "The wiring and its rights".

Do not use: control channel, subscription queue.

### Record stream

A record stream is the records of one record output as one reader reads them, in order, up to the end record.

The console holds the reader end of a wiring as a value of the kind Stream (`Stream(Access_Record)`), filters it with `where(status >= 500)`, whose field names it checks against the record description, and draws each row as it comes until the end record or Escape. A variable keeps no record stream: it lives with its line.

The design: `src/md/features/module_outputs.md`, "The console form".

Do not use: pipe, feed, live table, stream (alone, for this).

### Typed name

A typed name is the name of a record output in a line of the console: the name of its owner, a dot, and the name of the record output, as `server.requests`.

The owner is a process that the console started or a service that it connected. The console reads the record outputs and their record descriptions in the module file of the owner, so it checks and completes the name, and the fields of a condition after it, before the line runs. A typed name gives a record stream that holds no wiring: the first command that reads it wires it. It is no global name: it is local to the handle that the console holds.

The design: `src/md/features/module_outputs.md`, "The console form".

Do not use: topic, path (for this), stream address, channel name.

### Condition of a wiring

A condition of a wiring is one field of the record of a record output, one operator and one value that a row of a wiring list carries, so that the writer writes into that ring only the records that pass it.

The asker writes the terms with the row; the root service checks them against the record description and gives the writer the place of the field, never reading a record itself. The serials of such a ring move forward by any count. The console sends the first condition of a record stream this way, and refuses a record that fails it as a fault of the writer.

The design: `src/md/features/module_outputs.md`, "The condition of a wiring".

Do not use: subscription filter, predicate pushdown, server-side filter.

### Body region

A body region is the memory object of the writer of a record output that holds the bytes that a record of that record output names past its 256 bytes.

The root service gives it to each reader with the right Read only. A field of the kind Body in the record names a place in it, an offset and a count; the reader checks the place against the size of the region and copies the bytes once. The writer reuses the bytes only after each reader read the record.

The design: `src/md/features/module_outputs.md`, "The ring and its records".

Do not use: payload buffer, shared buffer, blob.

### Joined record

A joined record is the first compartment of each output ring: it says how many records of the record output the writer wrote before this reader joined.

The writer writes it when it takes the new end, before its next record. A joined record of 0 says that the reader has the whole stream: each wiring of the wiring list of a start gets one, because the root service applies the list before the first instruction of the child. A wiring that comes while the writer runs gets the records from that point only. The console draws it as the first row of a stream, "joined after 5 000 records".

The design: `src/md/features/module_outputs.md`, "The joined record".

Do not use: start marker, subscription point, replay.

### Generic record input

A generic record input is a record input that declares no record type, `system.Record_Input(system.Any_Record)`, and whose type its wiring fixes from the record output of the writer.

The root service reads the record description from the module file of the writer and gives it to the reader with its end. With the count `Many`, the first wiring fixes one type for each later one, until the stop of the reader; with `Many_Types`, each wiring keeps its own type. A module that moves records and reads no field, such as `merge` or the collector, works on any stream so. It does not take any bytes: each record is checked against the fixed type.

The design: `src/md/features/module_outputs.md`, "Generic record inputs and the utility modules".

Do not use: untyped input, dynamic input, any-type stream.

### Generic record output

A generic record output is a record output that declares no record type and takes the type of the one generic record input of its module.

With the mark `Paired`, it has one ring for each wiring of that record input, of the type of that wiring: the record output `forward` of the collector. A wiring of it before its type is fixed is refused. The tool refuses a generic record output in a module with no generic record input or with two.

The design: `src/md/features/module_outputs.md`, "Generic record inputs and the utility modules".

Do not use: untyped output, passthrough type.

### Utility module

A utility module is a module that works on a stream of any record, with a generic record input and a generic record output, and no window and no grant: `merge` and `filter`.

A starter wires it in the list of a start, as any record stream. `merge` joins several sources of one record into one stream, and `filter` keeps the records that pass the one condition of its wiring terms. Each runs as a process of its own, of the module group `libraries`. Example: `start("merge", wire(alpha.out, merge.sources) + wire(beta.out, merge.sources))`, then `merge.merged`. The design: `src/md/features/module_outputs.md`, "Generic record inputs and the utility modules".

Do not use: tee, adapter, pipe stage.

### Record output log

The record output log is the one record output that each process has with no declaration: a copy of each log record that the process writes, which loses none.

Only the starter wires it, in the wiring list of the `Start` of the process, to one reader, which has each record from the first one. The writer waits while the ring of its reader is full; the kernel log below it stays lossy. An audit of the log of a process reads it. Example: a row `{writer_end = Child, writer_stream = Log, reader_end = Asker}` in the list of a `Start`. The guide: `docs/MODULE_CONTRACT.md`, "The record outputs and the record inputs".

Do not use: audit log, log stream, log pipe, lossless log.

### Log follow

Log follow is the record output `follow` of the log service: one row for each record of the whole log, from the moment a reader wires it, written as the records come.

Only a reader that acts for the principal wires it, with the end `Connected`. The service never waits for a follower: a full ring holds the rows of its follower only, and where the kernel wrote over records before the service wrote them, the follower reads one gap record of their count. Example: `log.follow |> where(level = Warning)`. The design: `src/md/features/log_facts.md`, "The frequent tasks".

Do not use: tail, log subscription, live log.

### Wiring list

A wiring list is the table of wiring records that a starter gives with `Start`, which the root service applies whole before the first instruction of the child.

Each row names a writer and a reader: the child, a process that the starter started, a service of a connection, or the starter as the reader. `Wire` lends the same form with one row and no child. A record output that no row names has no reader. The list is whole or refused: on a refusal, no process starts and the budget of the starter does not change. In the console it is a `Table(Wiring)`, and `+` joins two lists. Example: `start(server, audit(server))`.

The design: `src/md/features/module_outputs.md`, "The wiring list of a start".

Do not use: manifest, wiring plan, pipeline, redirection.

### List page

The list page is the memory object in which an asker writes a wiring list for `Wire` or `Start`, and which the root service owns.

The root service makes it once from the budget of the asker, keeps its own handle, and gives the asker a handle with Write. It copies the list from its own handle, so a revocation by the asker reaches only the handle of the asker, never the copy of the root service.

The design: `src/md/features/module_outputs.md`, "The wiring and its rights".

Do not use: lent list, argument memory.

### End page

The end page is the page of one wiring in which the root service alone writes the end words, and which each side maps with Read only.

A side waits on its end word beside its queue, and reads it once its queue is empty. A side cannot forge the end of the other, as it could in the head page of the ring, which both sides write.

The design: `src/md/features/module_outputs.md`, "The end of a stream".

Do not use: end record (an end record is a compartment), status page.

### Description file

A description file is the small module file that the root service gives the reader of a wiring: the one record of the wiring, its fields and their names.

A process has no copy of its own module file, so the reader checks each compartment against this file, which the root service writes from the module file of the writer after the type check. A generic reader takes the type that its wiring fixed from it.

The design: `src/md/features/module_outputs.md`, "The wiring and its rights".

Do not use: schema, type message.

### Wiring page

A wiring page is a page of the budget of an asker in which the root service keeps the records of the wirings that the asker asked for: a head and 63 wiring records.

The root service makes the first page at the first wiring of the asker, chains a new page when the pages are full, and gives a page back to the budget when its last wiring ends. So the root service keeps no table of a fixed size for the wirings: each one is paid by its asker. The wirings of a page end when the asker stops.

The design: `src/md/features/module_outputs.md`, "The budget".

Do not use: subscription table, wiring table.

### Wiring terms

The wiring terms are the record that the asker of a wiring gives for the record input, and that the reader receives with its end.

A source declares them with the record input, `system.Record_Input_With_Terms(system.Any_Record, output.Condition_Terms)`, and the module file holds their record type in its row of the table `Record_Inputs`. The root service checks their size against that description and copies them once; the reader checks their fields. Examples: the condition of `filter` (a field, an operator and a value), the kind, the bound and the forward of a collector space. A free text is never a term.

The design: `src/md/features/module_outputs.md`, "The wiring and its rights".

Do not use: options, arguments (for this), parameters of a stream.

### Collector

The collector is a module that reads the record outputs that a wiring gives it, and keeps their records in its private store, one collector space for each pair of a source and a record output.

A starter names it in the wiring list of a start, or a start policy in its rows; the root service never wires it by itself. One collector serves one principal, so the records stay in a store of that principal, and it serves its spaces only to a caller that acts for that principal, never to a source. With its record output `forward`, it keeps each record of a record input, then forwards it. It never reads the log: it is one more reader of record outputs.

The design: `src/md/features/module_outputs.md`, "The collector".

Do not use: log (for this), journal, syslog, sink, recorder.

### Collector space

A collector space is the records of one record output of one source process that the collector keeps, with their own bound in blocks of its store.

The asker gives its kind and its bound as the wiring terms. A space of the kind `Keep` removes its oldest records when it is full and counts them, so a noisy record output fills only its own space. A space of the kind `Audit` is an audit space. A new version of a source whose record description changed gets a new space.

The design: `src/md/features/module_outputs.md`, "The collector".

Do not use: log file, bucket, partition.

### Audit space

An audit space is a collector space that keeps each record and removes none: append-only, in the store of the collector of the principal of the starter.

A full audit space holds its writer, which waits, in place of a loss. Each audit segment holds the BLAKE3 hash of the audit segment before it, so a removal or a change shows when `collector.verify` walks the chain. The source of the space can neither read it nor erase it, and cannot end its wiring; only the principal ends the space whole. It proves each record that its source wrote or received through the collector, not that its source wrote a record for each act.

The design: `src/md/features/module_outputs.md`, "The audit".

Do not use: audit log, journal (for this), trail.

### Audit segment

An audit segment is one object of the private store of the collector that holds 16 records of one audit space, in the order of their serials.

The collector writes the open audit segment again with each new record, before it keeps or forwards that record; an audit segment of 16 records is closed and never written again. Each one holds the hash of the audit segment before it and its own hash, so a start of the collector refuses a changed, moved or missing one with `Store_Damaged`. It is not a TCP segment.

The design: `src/md/features/module_outputs.md`, "The audit segments in the store".

Do not use: segment (alone, for this), chunk, page (for this), log file.
