## Code

### Module

A module is the one format of compiled code in the system: a file of position-independent machine code that exports functions and is named by the hash of its bytes.

A library, a process, a service, a command and the kernel are all modules of one format, where other systems have executables, shared objects and kernel modules. Its identity is the BLAKE3 hash of the whole file, and each import names a module by that hash. Example: `load("calendar")` in the console calls the exports of `calendar` directly; `isolate("calendar")` starts it in a call host. A module is not a package of a source language: the packages of `src/library` are compiled into modules and have no hash of their own.

The design: `docs/MODULE_CONTRACT.md`, "1. The module file".

Do not use: unit, library, executable, binary, package, DLL, shared object. "Kernel module" names the Linux concept only.

### Export

An export is a function that a module makes callable from outside the module, with a description of its parameters and its result.

An export is the only thing that a module offers: a reader reaches data through a function. Its record in the Functions table of the module metadata gives its name, its code, its parameters, its result and its error record, so a caller needs nothing else. One export serves a direct call through an import slot, an isolated call through a call ring, and a command of the console. Example: `sample.sum_values(readings: Table(Reading, Read)) -> Integer`. An export is not a symbol of an object file: no search by name happens at run time.

The design: `docs/MODULE_CONTRACT.md`, "4. The call form".

Do not use: symbol, entry.

### Import

An import is the name of another module inside a module: its hash, with the exports that the importing module calls.

An import replaces the library search path of other systems. The loader does not search: it finds the module with that hash in its load source, or the load fails with the stage Find. A module with another hash is another module, and only a replacement can put it in the place of the import. Example: the module `agenda` imports `calendar`; `manual.edges()` shows that edge, and `replace("calendar", "calendar_fixed")` makes the loader give `calendar_fixed` in its place.

The design: `docs/MODULE_CONTRACT.md`, "2. Loading".

Do not use: dependency, link.

### Module graph

The module graph is the set of modules as nodes and their imports as edges: one edge goes from the module that imports to the module that it imports.

The module graph answers two questions: which modules a process contains, and which processes a bad module reaches. Only an import by hash is an edge: a source library, a load by name, a connection to a service and a replacement are not edges. The site draws the graph of the build from the files. `manual.edges()` gives the graph of the processes that run, from the module records of the kernel, with the replacements that the loader applied.

The design: `docs/MODULE_CONTRACT.md`, "Replacement of an import".

Do not use: dependency graph, call graph, link map.

### Command

A command is an export that the console can call: it is not a separate kind of thing.

In other systems a command is a program that parses text arguments and writes text. Here the console reads the description of an export, completes its name and its arguments, checks their types, calls the export and shows its typed result. So help, completion and argument checks come from the module metadata, not from code in each module. An export is a command when the console can give each of its parameters. Example: `monitor.processes()` calls the export `processes` of the module `monitor`, and gives a table.

The rule: `docs/PROPERTIES.md`, "19. A command is a function: no text between processes".

Do not use: CLI program, tool, script.

### Module metadata

The module metadata is the description of a module inside its own file: its segments, imports, exports with the type of each parameter and result, origin and documentation.

The module metadata is the one source of facts about a module. The loader reads its loader tables; the console, the manual and the information functions read its description tables. No separate manifest or header file exists, so no copy can disagree with the module. The hash covers the metadata, so a description cannot describe another version of the code. Example: `manual.check` reads the metadata of a module file and gives a problem for each rule that it breaks.

The design: `docs/MODULE_CONTRACT.md`, "1. The module file", and `docs/PROPERTIES.md`, "12. Module metadata in flat tables, read through functions".

Do not use: headers, manifest, symbol table.

### Flat table

A flat table is an array of records of a fixed size at a known offset: the form of the module metadata inside a module.

A flat table needs no parser: a reader takes the offset, the count and the record size from the table directory, and reads a record by its index. Index 0 is the empty record. A record can gain fields at its end, and a reader of another size still reads it. A question across many modules is one linear read of small tables, not a query in a database.

The rules: `docs/PROPERTIES.md`, "12. Module metadata in flat tables, read through functions", and `docs/PROPERTIES.md`, "13. Data-oriented kernel internals".

Do not use: section, blob.

### Contract description

The contract description is a file of the module format, with no code and no export, that describes the records, the enums and the constants of the contract packages.

The describe step of the build writes it: the parser names each declaration of a contract package, and the compiler gives each size, offset and value. Its tables are those of the module format, with two more: `Enumerations` and `Constants`. Each language binding is written from it and from the module files of the library modules, never from the Odin source. The SDK holds it. It is planned work.

The design: `src/md/infrastructure/sdk.md`, "The contract description".

Do not use: interface definition, IDL, schema.

### Language binding

A language binding is the set of files that let a program of another language read and write the records of the contracts and call the exports of the library modules.

The tool writes each one from the contract description and the module files, with one generator. The C language binding, a header for each contract package and for each library module, is the first; Zig and Rust are later targets. Each is a file of the release, signed with it. A check compiles a C program against it and compares each layout with the compiler of the contracts. It is a derived file: the module format stays the source of truth. It is planned work.

The design: `src/md/infrastructure/sdk.md`, "The language bindings".

Do not use: FFI, wrapper, stub, bindings (alone).

### Replacement

A replacement is a record `{hash, hash}` that the starter of a process gives to the loader: where a module imports the first module, the loader loads the second one.

A replacement fixes a module in every process that imports it, with no new build of its importers. Example: module B has a security fault; a replacement `{B, B2}` makes each import of B load B2. The loader compares the description of each export that the importer uses, and one difference refuses the load. A replacement is visible in the module record of B2, and a process cannot ask for one or refuse one. The root service applies it only for a signed replacement row.

The design: `docs/MODULE_CONTRACT.md`, "Replacement of an import" and "Who may replace a module".

Do not use: override, shim, LD_PRELOAD, DLL redirection.

### Replacement row

A replacement row is a record of the replacement list: the hash of a module, the hash of the module that a loader gives in its place, the importer scope, and an Ed25519 signature over those three by the key of a principal.

A replacement row is the consent of a principal to one replacement. The root service writes a replacement in the replacement table only for a row whose signature verifies under the key that it trusts for its scope: for the scope System, the signing key of the system. Example: `replace("calendar", "calendar_fixed")` succeeds because the boot image holds a signed row for that pair; `replace("calendar", "math")` is refused. The row is not a proof that the module is correct: the check of the loader still compares the descriptions.

The design: `docs/MODULE_CONTRACT.md`, "Who may replace a module".

Do not use: replacement certificate, allow list entry.

### Replacement list

The replacement list is the resource `replacement_list` of the boot image: the replacement rows that the tool signed when it wrote the boot image.

The tool signs each row with the key that signs the system description of the volume, so the system description lists the list and a test volume signs it with the test signing key. The format is `src/library/contract/replacement_list`: a header of 16 bytes, then rows of 136 bytes, at most 64. The root service reads it at each `replace` that adds a record, and verifies the row of the pair; it is not the replacement table, which holds the replacements that apply now.

The design: `docs/MODULE_CONTRACT.md`, "Who may replace a module".

Do not use: allow list, whitelist, replacement manifest.

### Replacement table

The replacement table is the list of the replacements of the machine, which the root service holds and gives to the loader of each process that it starts.

A process that loads modules, such as the console or the manual, receives the table with the right Read and reads it before each load. A process cannot change it. A process with the role Replace asks the root service: `replace("calendar", "calendar_fixed")` adds a record, `replace("calendar", "")` removes it, and `replacements()` lists the table. A change applies to the loads that follow; a process that runs keeps its modules. It is not the replacement list, which holds the signed pairs.

The design: `docs/MODULE_CONTRACT.md`, "Replacement of an import".

Do not use: override list, LD_PRELOAD, redirection table.

### Loader

The loader is the code in user space that builds a process or a module space from a module and its imports (`src/library/support/system/load.odin`).

The kernel loads no module: it maps memory objects and records what the loader asserts. The loader finds each module by hash in its load source, maps its segments, rebases them, binds each import slot, and writes a module record. On a failure the module space stays as it was, and the caller receives a load error. The loader runs in the process that starts another process, such as the root service, or in a process that loads a module for itself. It has no search path.

The design: `docs/MODULE_CONTRACT.md`, "2. Loading", and `docs/ARCHITECTURE.md`, "U3. Module store and loader".

Do not use: linker, dynamic linker.

### Prepared module

A prepared module is the set of memory objects that hold the parts of a module that do not change after the load, kept by the process that starts processes, by the hash of the module.

A prepared module lets many processes share the pages of one module: its code, and the segments that are read-only after the load. The table `system.Prepared_Modules` keeps each handle without the right Write, so a write of a process to its code is a page fault. Each process still receives its own copy of each writable segment. The kernel learns nothing of the module format: it maps memory objects with the rights of their handles.

The design: `docs/MODULE_CONTRACT.md`, "2. Loading".

Do not use: shared library, image cache, page cache.

### Shared code

Shared code is the pages of a prepared module that each process of the module maps without Write: its code, its constants and its data that is read-only after the rebase.

Shared code is why one module in many processes costs its pages once. Each process still has its own copy of each writable segment, made from the bytes of the file. Shared code needs code that the loader never writes: a call to another module goes through an import slot in data, so the code pages stay identical to the file.

A merge of two modules into one makes a new hash, and two processes that merge the same module do not share its pages.

The design: `docs/MODULE_CONTRACT.md`, "2. Loading".

Do not use: text segment, shared object.

### Import slot

An import slot is 8 bytes of data of a module that the loader writes with the address of one export of an import.

A call to another module is one indirect call through an import slot: `call *slot(%rip)`. So the code never changes with the place of the other module, and code pages stay shared. After the bind the loader makes the import slots read-only. An import slot is bound once, at load, with no lazy binding: a missing export fails the load, never a later call. Measured: a call through an import slot costs about 3.5 ns in the process `imports`.

The design: `docs/MODULE_CONTRACT.md`, "3. Static is dynamic".

Do not use: GOT entry, import address, stub, slot (alone).

### Load source

The load source is what a loader can read: the files that its process was granted, each named by its hash, and the replacements that the starter of the process gives.

The load source closes the hole of a global library directory. A loader finds an import only there, and checks the hash and the tables of each file before it uses it. The root service and the console give the boot image; a call host receives a list of files from the console. For a disk process, the root service adds the files that an import scan found. A file that the load source does not hold gives the load error Find.

The rule: `docs/PROPERTIES.md`, "20. No ambient access: the other holes to close".

Do not use: search path, library path, module store (for this).

### Disk process

A disk process is a process whose module file is an object of the store `module_files` of the storage service, and not a file of the boot image.

A disk process adds a module to a machine with no new boot image. The principal names its file by a nickname and by its hash: `start_from_disk("visitor", "5f0c…")`. The root service starts the bytes only when their BLAKE3 hash is that hash: the storage service carries the bytes and does not choose them. Its name gives it no grant: it receives the grants of its nickname in the disk grant table. A disk process is not a package: it has no signer and no version, and nothing is installed.

The design: `docs/MODULE_CONTRACT.md`, "A module from a disk".

Do not use: installed program, side-loaded program.

### Module file service

The module file service is the module `module_files`: it stores a module file that a web server gives in the store `module_files` of its principal, and lists the files of that store with the hash of their bytes.

A developer adds a process to a machine that runs, with no disk from the modus tool. In the console, `module_files.receive(nickname, path)` gives the hash of the bytes that came, then `start_from_disk(nickname, hash)` starts them. `module_files.list()` gives each file with the hash that the service computes again. The service starts no process and proves nothing: the root service checks the bytes against the hash. It is not a package manager: it reads no signature, version or dependency.

The design: `docs/MODULE_CONTRACT.md`, "A module from a disk".

Do not use: package manager, installer, downloader.

### Import scan

An import scan is the read of the store `module_files` of a principal by the root service, to find each import of a disk process that the boot image does not hold by the BLAKE3 hash of the bytes of a file.

A developer puts a process and its library modules in the store `module_files`, under any nicknames. At the start, the root service reads each entry, keeps the bytes whose hash an import names, and gives them to the loader beside the boot image. A hash that no file has refuses the start. The scan trusts no name and no hash that the storage service gives. It is not a search path: only bytes with the hash of the import are kept.

The design: `docs/MODULE_CONTRACT.md`, "A module from a disk".

Do not use: dependency resolution, library lookup, search of an import.

### Module space

A module space is the set of modules that a loader put in one process, each module one time.

Two modules that import a third one call the same copy of it: the module space counts the uses of each module. A module that another module of the space uses stays when its caller unloads it; a module with no use leaves, and its imports lose one use. `system.module_space_release` removes a module; when the kernel refuses the removal, the load error has the stage Unmap.

The design: `docs/MODULE_CONTRACT.md`, "2. Loading".

Do not use: link map, address space (for this).

### Load error

A load error is the record of a load that failed (`module.Load_Error`, 392 bytes): the stage, the module that was being loaded, the import, a replacement on the path, the export, and the two descriptions that differ.

A load error is the error record of the loader. It names modules by hash and by name, because the caller of a call host does not have these names. Zero is "no error", and the caller owns the record. `system.load_error_text` writes it as sentences, for example "error: agenda imports calendar, and its replacement calendar_changed fails the check". A caller that gives a table of error details receives one load error for each import that is missing or has the wrong hash.

The design: `docs/MODULE_CONTRACT.md`, "The error of a load".

Do not use: exception, errno, error message.

### Stop report

A stop report is the record that the kernel keeps of a process that stopped on a fault (`op.Stop_Report`): the stop cause, the vector, the instruction, the address, the module record of the module that ran, and the stack trace.

A stop report replaces a core dump. It is small and typed, and the kernel writes it at the fault, from the frame of the thread, its frame pointers and the module records of the process. The holder of the process handle with the right Read reads it with `Process_State`. The kernel writes one for the stop causes `Fault`, `Not_Committed` and `Cannot_Return`; another stop leaves it zero. Example: the console prints "error: the instruction is at offset ... of calendar_fixed ...".

The design: `docs/MODULE_CONTRACT.md`, "A fault: the stack trace".

Do not use: core dump, crash report, signal info.

### Kept stop report

A kept stop report is the copy of the stop report of a disk process that the root service keeps after the process stopped on a fault (`disk_process.Kept_Stop_Report`), with the hash of its module file.

The root service holds the only handle of a disk process and closes it at the reap, so the kernel forgets the stop report. The copy keeps the frames that a module record holds, and no other word of the memory of the process. `stop_report("visitor")` in the console asks the debugger service for it, with no attach; the service names each frame by its procedure and its line. It is not a log: a new fault of the nickname replaces it, and a run with no fault removes it.

The design: `docs/MODULE_CONTRACT.md`, "The debug object of a disk process".

Do not use: crash log, saved stop report.

### Refused return

A refused return is a return of the kernel to a thread that the processor refuses at `iretq`: the kernel stops the process of the thread, as its own fault, with the stop cause `Cannot_Return`.

The kernel returns to a process only with `iretq`, and checks the frame before each return: an instruction address at or above `USER_END`, or a stack address that is not canonical, cannot pass. A fault of the `iretq` itself is a fault of the thread, not of the kernel: the stop report has the refused address, and the machine goes on. A refused return can come from a frame that a process wrote with thread control, which checks the frame first.

The design: `docs/ARCHITECTURE.md`, "The return to a process".

Do not use: bad iret, iret fault.

### Error record

An error record is the record of 56 bytes that a call that failed gives back to its caller (`errors.Error_Record`): what is wrong, which argument, the value that it had, the limit, and what the system found.

An error record replaces `errno`, exceptions and error texts. A status stays the fast answer; the error record explains it. It is a value of the call, in memory that the caller owns: no global last error, no text. A kernel operation gives it in its completion record, a ring of a service in a completion, and an export at an address that the caller gives. `system.error_text` writes one sentence from it, for example "Memory_Map: the argument memory, handle 0x30004, has the rights Give Read; the operation needs Read Write".

The design: `docs/MODULE_CONTRACT.md`, "The error record".

Do not use: errno, exception, error code, detail record, error message.

### Error detail

An error detail is one thing that a call that failed has to say, as one record of the error form of the call: an error record for an export and a kernel command, a load error for the loader.

An error record holds one failure: the first argument that is wrong. A caller that wants each failure gives a table of error details, and the callee appends one detail for each thing that it finds, in order. The error record of the call is the first detail, so a caller with no table receives the same first answer.

Example: the console gives a table of 16 details to each command, and prints each detail after the error when there is more than one.

The design: `docs/MODULE_CONTRACT.md`, "The table of error details".

Do not use: sub-error, cause, inner error, error list, diagnostic.

### Table of error details

A table of error details is an optional Append table of error details, in memory of the caller: the last parameter of an export that has an error record, or the table that a kernel command names in its last value.

The callee writes the details that fit, and the count is the count of all the details. With no table, the call gives its error record only. On success the callee does not touch the table, so the path of success costs nothing. In Odin the parameter is `details: ^system.Table_To_Append(errors.Error_Record)`. A kernel command names its table with a bit of its kind, through `system.call_with_error_details`; the kernel then writes one detail for each argument that it finds wrong.

The design: `docs/MODULE_CONTRACT.md`, "The table of error details"; for a kernel command, "Kernel operations".

Do not use: error list, error buffer, error stack, error chain.

### Error kind

An error kind is the first field of an error record: what is wrong (`errors.Kind`).

Examples of kinds: an empty argument, a handle that was revoked (`Handle_Ended`), a handle without a right (`Handle_Rights`), a budget that cannot pay (`Budget`), a value out of range (`Bad_Value`), a table that is full (`Full`). Each kind fixes the meaning of the fields `limit` and `found`. Each status of the kernel has its kinds; a kind that does not explain the status becomes `Refused`, an honest "no more detail".

The documentation of an export names the kinds that it gives, and `manual` shows them.

The list: `src/library/contract/errors/errors.odin`.

Do not use: error code, errno value, exception type.

### Frame pointer

A frame pointer is the register `rbp` of a function: the address of its frame on the stack, where the frame pointer and the return address of its caller are.

Every module keeps frame pointers, so that the kernel, a debugger or a profiler walks the stack with no unwind tables and runs no code of the process. The modus tool compiles each module through LLVM with `--frame-pointer=all`. The cost, measured: the code of `console` is 0.45 % larger, and a call through an import slot is about 0.4 ns slower.

The rule: `docs/MODULE_CONTRACT.md`, "Closed rules".

Do not use: base pointer, frame record.

### Stack trace

A stack trace is the list of the return addresses of the calls that led to a fault, from the frame pointers, each with the module record that holds it.

The kernel writes the stack trace into the stop report: frame 0 is the instruction, and each next frame is a return address. The walk stops at 16 frames, or at a frame pointer that is 0, not aligned, not above the one before, or not memory of the process. A reader names each frame "module + offset"; the modus tool names the function from the linked file of the module.

The design: `docs/MODULE_CONTRACT.md`, "A fault: the stack trace".

Do not use: backtrace, call stack (for this), unwind.

### Module record

A module record is what the kernel keeps of one module in a process (`op.Module_Record`, 88 bytes): its base address, its size, its hash, the hash that a replacement put it in place of, and its module writer.

The loader writes the record with `Process_Module` after it mapped the module. The kernel does not read the module: the record is what the loader asserts. The kernel uses it to name the module of a fault address and of each frame of a stack trace, and `Inspect` gives the records of a process. A process has at most 16 module records.

The module records of a process that runs are its identity: `manual.running()` and `manual.edges()` read them.

The design: `docs/MODULE_CONTRACT.md`, "2. Loading".

Do not use: link map entry, loaded image list.

### Module writer

The module writer of a module record is the party that wrote it: the process itself (`process`), or a holder of its process handle with Control, its starter (`starter`).

The kernel sets it at each `Process_Module`, from the caller and the target. A process cannot replace or remove a record of the writer `starter`, or map memory at its addresses. So a record of the writer `starter` names the code that the starter put there, and a record of the writer `process` is what the process says of itself. Example: the root service starts `imports`, whose module has the writer `starter`; `imports` loads `calendar`, whose record has the writer `process`. It is not the `system.Writer` of a text.

The design: `docs/MODULE_CONTRACT.md`, "The writer of a module record".

Do not use: owner, author.

### Table

A table is a set of records of one record description that follow each other in memory, with their count.

The table is the unit of data of the system. The console holds a table as one value and passes it to the next function with no parsing. The callee writes a Table result in memory of the caller, with the count of the full table: a count above the capacity means that the table did not fit. A record of a table holds no Handle field. Example: `monitor.processes()` gives a table of `Process` records.

The rules: `docs/PROPERTIES.md`, "12. Module metadata in flat tables, read through functions", and `docs/PROPERTIES.md`, "19. A command is a function: no text between processes".

Do not use: list, array (for this), result set, rowset, data frame.

### Table parameter

A table parameter is a parameter of an export of the type Table: records of one description in memory of the caller, with a direction.

A table parameter lets a call work on many records at once with no copy in a direct call. In a direct call the callee receives the address of a table place and works in the memory of the caller. In an isolated call the caller copies the records into the call region, or lends a memory object when they do not fit; the receiver checks every offset and count before the export runs.

Example: the cryptography module seals N packets in one call: `seal(packets: Table(Packet, Change), bytes: Bytes(Change), key: Key)`.

The design: `docs/MODULE_CONTRACT.md`, "Tables and bytes as parameters".

Do not use: array argument, buffer argument, list parameter.

### Bytes

Bytes is a parameter type: bytes with no description, in memory of the caller, with a direction.

Bytes is a table parameter whose record is one byte. The bytes need not be UTF-8: they can be the bytes of packets or of a picture. A Text is the read-only form of UTF-8 for a reader; Bytes is the form for data. In Odin the types are `^system.Bytes_To_Read`, `^system.Bytes_To_Change` and `^system.Bytes_To_Append`.

The design: `docs/MODULE_CONTRACT.md`, "Tables and bytes as parameters".

Do not use: blob, buffer, byte array, binary.

### Enum parameter

An enum parameter is a parameter of an export of the type Enum: one member of a closed set, whose members the module file names.

An enum parameter lets each front end read one description of a closed set: the console completes the members and refuses a wrong one before the call, and the palette shows one button for each member. In Odin the type of the parameter is the enum itself, `keyboard_layout: settings.Keyboard_Layout`, with a backing type of 1, 2, 4 or 8 bytes. An enum parameter is not a Text that names a value, and not an Integer: a number of another set is refused.

Example: `settings.set(keyboard_layout = .french)`.

The design: `docs/MODULE_CONTRACT.md`, "Enum parameters".

Do not use: choice parameter, keyword parameter.

### Member

A member is one value of an enum that a module file describes: a name in lower case and the value that a call carries.

A line of the console names a member after a dot, `.french`, and never by its number: the Enum parameter that receives it gives its enum, and the console writes the value of the member of that name. A member of a contract enum in a condition, `level = Warning`, is the name of a status field, with no dot.

Example: `.united_states` and `.french` are the members of `Keyboard_Layout`.

The design: `docs/MODULE_CONTRACT.md`, "Enum parameters".

Do not use: enumerator, enum case, enum variant.

### Getter

A getter is the export that an Enum parameter names in its module file to give the member in use: it takes no parameter, gives no error record, and gives the same enum.

The palette calls the getter of each row of buttons when it opens, and marks the member that it gives. The pairing of a parameter and its getter is written in the module file, from the attribute `enum_getters` of the source: no reader finds a getter by its name. A getter is not an export that a call must make before the setter.

Example: `settings.keyboard_layout()` is the getter of the parameter `keyboard_layout` of `settings.set`.

The design: `docs/MODULE_CONTRACT.md`, "Enum parameters".

Do not use: accessor, property getter.

### Optional parameter

An optional parameter is an Enum parameter that a call may leave out: the caller then gives its absent word.

The bit of the parameter in `Function.optional_parameters` says it, from the attribute `optional_parameters` of the source. The absent word is each bit of the size of the enum set, which no member may have: the export reads it with `enum_word.member_of_argument`, which says that the call did not give it. A parameter of another type is never optional; the last parameter of a built-in command that a call may leave out is a fact of that command, not of the format.

Example: `settings.set(font = .spleen)` leaves out the six other settings, which keep their values.

The design: `docs/MODULE_CONTRACT.md`, "Enum parameters".

Do not use: default parameter, nullable parameter.

### Direction

A direction says what the callee does with the memory of a table parameter or of a Bytes parameter: Read, Change or Append.

- Read: the callee reads the records from 0 to the count, and writes nothing.
- Change: the callee reads and writes the records from 0 to the count; the count stays.
- Append: the callee writes after the count, up to the capacity, and gives the count of the full answer, also the records that did not fit.

Read is the zero direction because it has the least power. A lent memory object gets the rights of the direction. A replacement whose export has another direction fails its check.

The design: `docs/MODULE_CONTRACT.md`, "Tables and bytes as parameters".

Do not use: mode, access, in/out, intent.

### Table place

A table place is the record of 24 bytes `{address, count, capacity}` in memory of the caller that names the memory of a table parameter or of a Bytes parameter in a direct call.

The callee receives the address of the table place in one register. Count and capacity are in records (in bytes for Bytes). No record size travels with the place: the caller and the callee have the same description, because the import names the exact module. In an isolated call the field of the argument record has 32 bytes in its place: the start, the count, the capacity and a lent memory object or 0.

The design: `docs/MODULE_CONTRACT.md`, "Tables and bytes as parameters".

Do not use: descriptor, span, fat pointer, buffer record (for this).

### Information function

An information function is a function that reads the flat tables of modules, the module records of the kernel or the replacement table, and fills a table in memory of the caller (`src/library/private/manual/information`).

The information functions replace a database of modules. They allocate nothing and keep no state; each one reads the tables in a line and gives records. The manual service exports them, so the console can combine them: `manual.running()`, `manual.edges()`, `manual.check()`. A new kind of question is a new function, or a combination of functions in the console.

The rule: `docs/PROPERTIES.md`, "12. Module metadata in flat tables, read through functions".

Do not use: query, reflection API, introspection.

### Catalog

A catalog is the input of an information function: the modules that a process can see, and the replacements of the machine.

A catalog is the boot image that the process was granted and the records of the replacement table. An information function sees nothing else: a process with no grant of the boot image has an empty catalog.

Do not use: registry, repository, package database, index.

### Problem

A problem is the error value that a reader of input that nobody checked gives for a rule that the input breaks: the kind, the place, the byte, the bad value and its limit.

A problem is the error record of a parser of hostile bytes. An information function gives one for a module file (`information.Problem`): the table and the record of the module, and the byte of the file. The network service gives one for a frame (`datagram.Problem`): the layer of the frame and the byte. Example: `manual.check` gives a problem for a Table parameter whose record has a Handle field.

Do not use: exception, errno, error code.

### Boot image

The boot image is the one block of data that the boot program loads with the kernel: the modules of the first processes and the resources, each with its name and its hash.

The boot image starts the system with no file system. Its header has a table of modules and a table of resources (`src/library/contract/boot_info`), each entry with a name, the BLAKE3 hash of the bytes, the offset and the size. The boot program checks each entry against the system description before the kernel starts, and the root service checks them again. The root service is the load source of the first processes; another process receives the boot image only by the grant `Image`.

The design: `docs/ARCHITECTURE.md`, "U2b. Resources of the boot image".

Do not use: initrd, ramdisk.

### Position-independent

Position-independent code runs correctly at any address with no change to its bytes.

All code of the system is position-independent: a module reaches its own data relative to the instruction, and another module through an import slot. The loader writes only data (the rebases and the import slots), never code. So code pages stay shared and never writable.

The rule: `docs/PROPERTIES.md`, "10. One code module".

Do not use: relocatable, PIC, PIE.

### Scalar form

The scalar form of a procedure computes one value with one instruction, in the general registers.

The scalar form is the reference of each vector form of the same procedure, and the code of a target with no vectors. A host test compares the two forms for every input that it can reach: they must give the same bytes.

The rule: `docs/SIMD.md`, "1. The rule of the same bytes".

Do not use: plain C version, fallback (for this), slow path.

### Instruction template

An instruction template is an `asm` procedure of Odin: instructions of the processor, with parameters and results in registers that it names, that the compiler puts in the code of each caller with no call and no return.

The kernel writes its small instructions this way: ports, model-specific registers and control registers. Code that owns the stack or the frame stays in the assembler file `src/kernel/processor.asm`.

The design: `docs/ARCHITECTURE.md`, "The instructions of the kernel".

Do not use: inline assembly, intrinsic (for this), asm helper.

### Vector form

A vector form of a procedure computes several values with one instruction, in the 128-bit registers of SSE2, and gives the same bytes as its scalar form for every input.

The system has one vector width, SSE2, which every x86-64 processor has, so a vector form needs no test of the processor. An AVX2 form was measured and lost to the SSE2 form for the blend of a glyph and for BLAKE3, so the system has none. The kernel has no vector code at all.

The design: `docs/SIMD.md`, "2. One form: SSE2".

Do not use: SIMD version, kernel (for this), fast path, intrinsics version.

### Debug object

A debug object is the file that names the procedures, the source lines, the types and the variables of the code of one module, so that a reader can turn an address of the module into a name and a line, and a debugger can show a variable.

A module names only its exports. With the debug object, the frame "fault + 0x1478" reads "fault::three + 0x8 in fault (src/modules/demonstrations/fault/main.odin:15)". The modus tool writes it at the build from the DWARF of the linked file, so the system reads no DWARF: a process reads only sorted tables of fixed records. The object names its module by the hash of the module file; the bytes of the module are the same without it. It is not the whole debug information of the compiler.

The design: `docs/MODULE_CONTRACT.md`, "Debug information".

Do not use: symbol file, PDB, dSYM, debug info (for the file), symbols.

### Procedure table

The procedure table is the table of a debug object that gives, for each procedure of the module, its start, its size and its name with its package.

The records are sorted by their start and never overlap, so a reader finds the procedure that holds an offset with one binary search (`debug_object.place_of`). A name holds only visible ASCII characters, so a hostile name cannot forge a line of the log or of a terminal. Code that the compiler inlined has the name of the procedure that holds it. Example: the name `fault::three` has the package `fault`. It is not the Functions table of the module metadata, which describes the exports only, for callers.

The design: `docs/MODULE_CONTRACT.md`, "The debug object".

Do not use: symbol table, function table.

### Line table

The line table is the table of a debug object that gives, for each range of the code of a module, the source file and the line that the code comes from.

The code from the offset of a row up to the next row comes from its line. The rows are sorted by their offset, so a reader finds the line of an instruction with one binary search. A row with the file 0 says that the code after it has no source line. For a return address the reader looks up the byte before it, so the line is that of the call. Example: the machine test checks that the stack of `fault` names the lines 15 and 20 of `src/modules/demonstrations/fault/main.odin`.

The design: `docs/MODULE_CONTRACT.md`, "The debug object".

Do not use: line program (the form of DWARF that the tool reads), line info.

### Type table

The type table is the table of a debug object that gives, for each type that a variable of the module uses, its name, its size, its kind, and what it is made of.

A debugger needs the type of a variable to show its bytes as a value: an integer, a record with its fields, the name of an enumeration value. The fields of the records are in the field table, and the named values of the enumerations in the enumeration value table. The type 0 is "no type". A type can name itself through a pointer, so a reader bounds the depth that it follows. It is not the Records table of the module metadata, which describes the records of the exports, for callers.

The design: `docs/MODULE_CONTRACT.md`, "The types and the variables".

Do not use: type info, type section, DWARF types.

### Global table

The global table is the table of a debug object that gives, for each global variable of the module, its name, its address in the memory of the module, and its type.

A record has 16 bytes. The address is an offset from the address where the module is mapped. The name has its package (`errors::UNIT_NAMES`). The records are sorted by their address, then by their name. A static variable of a procedure is in the table; a variable of a thread and a variable that the link dropped are not. `debug_object.global_by_name` finds a global with one pass over the table.

The design: `docs/MODULE_CONTRACT.md`, "The types and the variables".

Do not use: data symbols, static table.

### Variable table

The variable table is the table of a debug object that gives, for each parameter and each local variable of a procedure, its name, its type, a range of instructions, and its variable location in that range.

A variable that the compiler moves has one range for each variable location. A reader finds the variables of the procedure of an instruction with binary searches (`debug_object.variable_range_of_offset`), then takes for each one the range that holds the instruction (`debug_object.variable_at`). A variable that is readable nowhere has one range that is "not readable". Example: at the first instruction of `fault::three`, the parameter `address` is a `uintptr` in the register 5 (`rdi`).

The design: `docs/MODULE_CONTRACT.md`, "The types and the variables".

Do not use: locals table, scope table, symbol table.

### Variable location

A variable location is where the value of a variable is in one range of instructions: in a register, or in memory at a register plus an offset.

A location is in a register, in memory at a register plus an offset, or "not readable". "Not readable" says that the debug information of the compiler gives no location that the table describes; the tool never guesses one, and a debugger shows "not readable". A location is true for the innermost frame; for a frame of a caller only a location from the frame pointer is readable. It is not a place of the storage service, and not the place (procedure, file, line) that `debug_object.place_of` gives.

The design: `docs/MODULE_CONTRACT.md`, "The types and the variables".

Do not use: place (for a variable), location expression (the form of DWARF that the tool reads), storage (for a variable).

### Debug image

The debug image is one file that holds the debug object of each module of a build, in the form of a boot image, so that the processes of a machine can name the procedures and lines of every module.

The modus tool writes it as `build/debug.image` and copies it to the boot volume beside the boot program. The boot program reads it and does not verify it, because no code comes from it; a start with no debug image gives no names. The root service maps it read-only in each process with the grant `Debug_Image`, which finds an object with `system.debug_object_of`. It is not part of the boot image, so a change of a debug object changes no signature and no measure of the trusted boot.

The design: `docs/MODULE_CONTRACT.md`, "Where the debug objects are".

Do not use: symbol server, debug archive.

### Module file writer

The module file writer is the contract package that writes a valid module file from its parts: the segments, the exports, the imports, the import slots, the rebases, the records, the log facts and the budget.

Its package is `modus:contract/module_file_writer`. The tool and each program of modus that writes a module compile it in, so the format has one writer. It writes into memory that the caller gives, with no allocator and no kernel operation, and refuses a part that a loader or a reader would refuse. The tool fills its parts from the linked file of `lld`; an assembler fills them from its labels. It is not the module writer of a module record.

The design: `src/md/features/first_compiler.md`; the guide: `docs/MODULE_CONTRACT.md`, "The module file writer".

Do not use: module writer (for this), linker, emitter.

### Assembler

The assembler is the module `assemble`, which reads a text of x86-64 assembly and writes a module file into a memory object that its caller lends.

Its syntax is the syntax of AT&T, with directives of modus: `section`, `export` with the types of the parameters and of the result, `byte` and `zero`. Its package `modus:private/assemble/assembler` gives the parts of the module file writer, and refuses each text that it does not assemble whole, with the line and the column. It is the first program of modus that writes a program. It is not the assembler of the host that the build of a module runs.

The design: `src/md/features/assembler.md`; the guide: `docs/MODULE_CONTRACT.md`, "The assembler".

Do not use: compiler (for this), asm.

### Module from memory

A module from memory is a module whose file the console copies from a memory object and runs in a call host, with no file of the boot image.

The command is `isolate_memory(name, memory, size)`. The console checks the copy with `module.validate`, writes its BLAKE3 hash on the log, and gives the call host the copy as its one file, so such a module takes no import. Its exports become commands, as after `isolate`. A module that the assembler wrote is one. It is not a disk process: no store holds it, and the root service does not start it.

The design: `src/md/features/assembler.md`, "The machine step: a module from the memory of the console".

Do not use: dynamic module, loaded file.

### C compiler

The C compiler is the module `c_compiler`, which reads a C source and writes a text of assembly that the assembler takes, into a memory object that its caller lends.

It is `chibicc`, ported: its source is an outside source with four patches. Its export is `compile(source, output)`. Each function of the source that is not `static` becomes an export of the text, with its `int` and `long` types as Integers. A call host compiles one source. It is the stage after the assembler in the native tier of the bootstrap. It is not the compiler of the host that builds the system.

The design: `src/md/features/c_compiler.md`; the guide: `docs/MODULE_CONTRACT.md`, "The C compiler".

Do not use: cc, toolchain.

### Thin libc

The thin libc is the C library that a ported C program compiles in: the procedures that the program calls, over an arena and over streams in memory, with no path and no standard stream of a terminal.

`malloc` pushes on an arena of the budget, and `free` ends nothing. `fopen` opens a name of a table of files, to read. `stderr` is the diagnostic, which the module writes on its log, and `exit` returns to the entry of the program. Today it is the part that `chibicc` calls, in C beside it; it grows with each port. It is not a C library of the host.

The design: `src/md/features/c_compiler.md`, "The thin libc".

Do not use: C runtime, standard library (for this).

### Declaration

A declaration is a tree of a store whose root holds one text entry in Lex, with the extension `.lex`, whose value is one record.

A declaration describes a system, a session or a project, in the manner of Nix, and has a hash, as a module has. A sandboxed evaluation process reads its text in the evaluation mode `declaration` and gives typed values only: a plan, a table of recipes, the console of a project. Its evaluation has no effect. Example: `kernel = declaration(here())`. No service reads it.

The design: `src/md/features/declarations.md`.

Do not use: configuration file, flake, script.

### Declaration reference

A declaration reference is the value of a declaration at the console: the hash of the declaration, a chain of field names, and the records that a `with` composed with it.

The console never evaluates the text of a declaration. `kernel.tools` gives a reference, and a command that needs its value, such as `recipes.build`, gives the reference to its service, which has an evaluation process force it. A variable keeps the reference, never a thunk, so a declaration of any size takes one of the 16 variables. It is not a pin, which is the hash that a declaration input resolved to.

The design: `src/md/features/declarations.md`, "One parser, one lazy evaluator, two modes".

Do not use: handle (for this), pointer, thunk (for this).

### Plan

A plan is the typed record that an evaluation gives and the root service applies: the hashes of modules, start rows, wirings, rows of the disk grant table, settings and a substitution policy.

A plan names each object by its hash, so the root service never resolves a name. `plan { … }` is a value with no effect; `plans.apply(p)` shows the difference of its grants against the current applied plan, then applies it. A plan runs nothing, and it is no text.

The design: `src/md/features/declarations.md`.

Do not use: configuration, profile, manifest.

### Applied plan

An applied plan is a plan that the root ring command `Apply` wrote in the store `applied_plans` of a principal, with its number.

Each `plans.apply` writes the number after the highest one, then names it in the row "current plan" of the disk grant table: that write makes it current. `plans.rollback()` names the applied plan before it again, and writes no plan. The applied plans that the store keeps are roots of the garbage collector of `module_files`. It is not a generation, which numbers a commit.

The design: `src/md/features/declarations.md`.

Do not use: generation (for this), profile, system list.

### Catalog declaration

A catalog declaration is a declaration whose value is a record of recipes, modules and functions.

A declaration takes the recipes, the tools and the functions that it uses from catalog declarations. `catalog`, the catalog declaration of the system, is the default one, with no mechanism of its own. `gt.overlay(catalog)` and `catalog with { odin = … }` give a new catalog declaration. It is not the catalog of an information function, which is the modules that a process can see.

The design: `src/md/features/declarations.md`.

Do not use: catalog (for this), package set, registry, channel.

### Declaration input

A declaration input is a declaration that a project or a plan names in its record `inputs`: a catalog declaration, one exact declaration by hash, or a reference that a source module resolves.

`declaration(hash)` names one exact declaration; `follow(publisher, name)` names a release pointer; `catalog.git.source(…)` names a branch of a repository. The evaluation takes the hash of each from its pin, never from the network. It is not the input of the keys and the pointer, and not an input of a recipe, which is a tree that a builder reads.

The design: `src/md/features/declarations.md`.

Do not use: input (for this), dependency, flake input.

### Pin

A pin is the tree hash that a declaration input resolved to, with the identity of its state in its format, kept in `pins.lex` of the source tree of a project or in a plan.

`pins.lex` is a record literal of Lex, one line for each input, so a review sees each input that moved. An evaluation reads the pins and never the network, so one declaration gives one plan. The tree hash of a project covers `pins.lex`. Only `projects.update` writes it; `projects.inputs(kernel)` shows each pin. It is not a pinned key of TLS.

The design: `src/md/features/declarations.md`.

Do not use: lock file, lock entry, `flake.lock`, pinned key (for this).

### Source module

A source module is a module of the catalog declaration that turns a reference of one format of versions into a modus tree: a resolver that `projects.update` runs, and a fetch recipe.

Git, Jujutsu, Mercurial, Pijul and an archive at an address are each one source module: `catalog.git.source(address, branch)`, `catalog.jj.source(address, change)`. The resolver has a network grant for the host of the address only; the fetch recipe refuses a tree whose hash is not the hash of the pin. A new format is one more module, with no change of Lex or of `projects.update`. It is not a substituter, which gives the output of a recipe.

The design: `src/md/features/declarations.md`.

Do not use: fetcher plugin, VCS backend, remote.

### Release pointer

A release pointer is a record that a publisher signs: a name, a number that only grows, the hash of a tree, and the signature.

`follow(publisher, name)` takes the newest release pointer of that name, and `projects.update` asks the sources of the substitution policy for it. Any source can give it, because the signature is checked against the key of the publisher. It does the work of a channel, with no server of authority. It is not a release of the changelog.

The design: `src/md/features/declarations.md`.

Do not use: channel, tag, latest version.

### Project

A project is a tree that a principal shares: `project.lex`, its declaration, `pins.lex`, its pins, and its sources.

`project.lex` holds `project { source = here(), inputs = {…}, outputs = {…}, console = {…} }`. The tree hash covers both files, so a project given by its hash is wholly fixed. `recipes.build(p)` realises `outputs.default`, `recipes.build(p.tools)` one output, and `projects.enter(p)` starts its child console (`docs/glossary/desktop.md`, "Console of a project"). It is not the work of the repository of modus, which the group Project of this glossary names.

The design: `src/md/features/declarations.md`, "Projects".

Do not use: package, flake, workspace.

### Plans service

The plans service is the service `plans`: it gives the commands `plans.apply`, `plans.difference` and `plans.rollback`.

It holds the right to send the root ring commands `Apply` and `Rollback` for the principal of the caller, and for no other. The root service computes the difference of a plan itself, so `plans` can hide no grant. It reads a plan through an evaluation process that it starts. The applied plans are in the store `applied_plans`.

The design: `src/md/features/declarations.md`, "The services of the declarations".

Do not use: declarations service, system manager.

### Projects service

The projects service is the service `projects`: it gives the commands `projects.update`, `projects.enter` and `projects.inputs`.

`projects.update` runs the resolvers of the source modules and writes `pins.lex` in the store of the project, which the caller gives with Write. `projects.enter` asks the root service for a child console. In that console, a command with no project acts on the project of `here()`: `projects.update()`. It acts for the principal of the caller, and cannot apply a system.

The design: `src/md/features/declarations.md`, "The services of the declarations".

Do not use: package manager, project manager.

### Recipes service

The recipes service is the service `recipes`: it gives the commands `recipes.build` and `recipes.provenance`.

It asks the root service to realise a recipe, from a realisation or by a build in a sandbox, and applies the substitution policy of the principal of the caller. It reads a declaration through an evaluation process that it starts. It cannot apply a system or write pins. It is not a builder, which is the module that a build runs.

The design: `src/md/features/declarations.md`, "The services of the declarations"; `src/md/features/recipes.md`.

Do not use: build daemon, builder (for this).

### Recipe

A recipe is a builder hash, a table of the names and hashes of its inputs, and a typed argument record: it names how an output is made.

The recipe hash, its identity, is the BLAKE3 hash of the builder hash, the inputs sorted by name, and the bytes of the argument record. `recipe(builder, arguments)` is a lazy value of Lex; forcing it gives its hash and builds nothing. `recipes.build` realises it, from a realisation or in a sandbox. It is a record, not a script.

The design: `src/md/features/recipes.md`.

Do not use: derivation, build script, makefile.

### Realisation

A realisation is a signed record that says which output a recipe gave: the recipe hash, the output hash, the builder hash, and the key and the signature of its signer.

A machine that holds a realisation and its output skips the build. A realisation is used only when a key that the substitution policy trusts signed it; a fetch needs none, because its recipe holds its output hash. Two realisations of one recipe with two outputs give the log fact `Realisation_Disagreement`.

The design: `src/md/features/recipes.md`.

Do not use: build result, cache entry, substitute.

### Builder

A builder is a module that exports `build`, with a fixed contract, and writes the output of a recipe into its store "out".

The root service starts it in a sandbox: its inputs as clones with Read, an empty store "out", no network, a random seed equal to the recipe hash, and a frozen date page. It is a plain module: a native compiler, the guest builder, or a small module of a developer. It is not a daemon that builds for others.

The design: `src/md/features/recipes.md`.

Do not use: build daemon, build server, toolchain.

### Guest builder

The guest builder is the builder that runs an existing tool of Linux in a guest, with its inputs as a read-only disk and its output as a blank disk.

Its Linux is an object by hash that the recipe names. The command of its argument record, such as `run = ["cargo", "build", "--release", "--offline"]`, goes into the guest, a foreign system, so no text passes between two processes of modus. It builds with any existing compiler at once. It is not a layer of Linux in the system.

The design: `src/md/features/recipes.md`.

Do not use: container build, chroot.

### Fetcher

The fetcher is the one builder with the network: it fetches an address and writes an output whose hash the recipe gives in advance.

Its network grant names the host of the address only. An output with another hash is refused and discarded, so its realisation needs no signature: each machine checks the output against its recipe. `git_fetch` fetches a git repository at one commit and writes its tree as a tree of modus. It is not a download into a shared folder.

The design: `src/md/features/recipes.md`.

Do not use: downloader, fixed-output derivation.

### Substitution policy

The substitution policy is the typed record `Substitution` of a plan that says where a realisation can come from: its sources, its trusted signers and its mode.

For each recipe, a machine uses its own realisation, else a realisation that a source gives and a trusted signer signed, else a build in the sandbox. The modes are `Prefer_Cache`, `Build_Only`, `Cache_Only` and `Verify`. Each principal has its own, in its plan; the named argument `recipes.build(kernel, substitution = {…})` changes it for one build.

The design: `src/md/features/recipes.md`, "The substitution policy".

Do not use: substituters, nix.conf, cache configuration.

### Object cache

An object cache is a source of objects by hash, of realisations and of release pointers, reached by the cache protocol over QUIC.

An object cache needs no trust: an object checks itself against its hash, and a realisation or a release pointer against its signer. A mirror, a peer of the local network, a removable disk and another machine of modus are object caches. It is not the build record of the tool.

The design: `src/md/features/recipes.md`, "The object cache and its protocol".

Do not use: binary cache, substituter, package repository.

### Bootstrap seed

The bootstrap seed is the one object of the chain of the bootstrap that no recipe made: a program small enough that a reader checks it byte by byte.

In the chain of live-bootstrap, it is hex0, about 500 bytes, which reads hexadecimal text and writes bytes. Each stage after it is the output of a recipe whose builder is the stage before. It is not the random seed of a process.

The design: `src/md/features/bootstrap.md`.

Do not use: seed (for this), bootstrap binary, trusted compiler.

### Self-hosting

Self-hosting is the check that a program builds its own source to the same bytes as the release before it built that source.

The tool of release N − 1 builds the source of release N, which gives N₁; N₁ builds the same source, which gives N₂. The check is the equality of their hashes. It proves that the steps of the program are a function of its source, not of the program that ran them. It does not prove the compiler: the bootstrap from the seed does.

The design: `src/md/features/bootstrap.md`.

Do not use: stage comparison, triple test.
