# Glossary

The glossary defines each term of the system. Each concept has one term, and one term names one concept: the documents, the code and the names of the programs use that term and no synonym. A reader who knows another system finds here the word that this system uses, and why it does not use the word that the reader expects.

An entry starts with one sentence that says what the term is. The paragraphs after it explain it, in at most 100 words: what it is for, how a program gets it and uses it, the terms next to it, what it is not, an example from the system, and where its full design is. The last line, "Do not use", lists the words of other systems that the term replaces here.

## Code

### Module

A module is the one format of compiled code in the system: a file of position-independent machine code that exports functions and is named by the hash of its bytes.

A library, a program, a service, a command and the kernel are all modules of one format, where other systems have executables, shared objects and kernel modules. Its identity is the BLAKE3 hash of the whole file, and each import names a module by that hash. Example: `load("calendar")` in the console calls the exports of `calendar` directly; `isolate("calendar")` starts it in a call host. A module is not a package of a source language: the packages of `src/library` are compiled into modules and have no hash of their own.

The design: `docs/MODULE_CONTRACT.md`, "1. The module file".

Do not use: unit, library, executable, binary, package, DLL, shared object. "Kernel module" names the Linux concept only.

### Export

An export is a function that a module makes callable from outside the module, with a description of its parameters and its result.

An export is the only thing that a module offers: a reader reaches data through a function. Its record in the Functions table of the module metadata gives its name, its code, its parameters, its result and its error record, so a caller needs no other knowledge. One export serves a direct call through a slot, an isolated call through a call ring, and a command of the console. Example: `sample.sum_values(readings: Table(Reading, Read)) -> Integer`. An export is not a symbol of an object file: no search by name happens at run time.

The design: `docs/MODULE_CONTRACT.md`, "4. The call form".

Do not use: symbol, entry.

### Import

An import is the name of another module inside a module: its hash, with the exports that the importing module calls.

An import replaces the library search path of other systems. The loader does not search: it finds the module with that hash in its load source, or the load fails with the stage Find. A module with another hash is another module, and only a replacement can put it in the place of the import. Example: the module `agenda` imports `calendar`; `manual.edges()` shows that edge, and `replace("calendar", "calendar_fixed")` makes the loader give `calendar_fixed` in its place.

The design: `docs/MODULE_CONTRACT.md`, "2. Loading".

Do not use: dependency, link.

### Module graph

The module graph is the set of modules as nodes and their imports as edges: one edge goes from the module that imports to the module that it imports.

The module graph answers two questions: which modules a program contains, and which programs a bad module reaches. Only an import by hash is an edge: a source library, a load by name, a connection to a service and a replacement are not edges. The site draws the graph of the build from the files. `manual.edges()` gives the graph of the programs that run, from the module records of the kernel, with the replacements that the loader applied.

The design: `docs/MODULE_CONTRACT.md`, "Replacement of an import".

Do not use: dependency graph, call graph, link map.

### Command

A command is an export that the console can call: it is not a separate kind of thing.

In other systems a command is a program that parses text arguments and writes text. Here the console reads the description of an export, completes its name and its arguments, checks their types, calls the export and shows its typed result. So help, completion and argument checks come from the module metadata, not from code in each program. An export is a command when the console can give each of its parameters. Example: `monitor.programs()` calls the export `programs` of the module `monitor`, and gives a table.

The rule: `docs/PROPERTIES.md`, "19. A command is a function: no text between programs".

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

### Replacement

A replacement is a record `{hash, hash}` that the starter of a program gives to the loader: where a module imports the first module, the loader loads the second one.

A replacement fixes a module in every program that imports it, with no new build of the programs. Example: module B has a security fault; a replacement `{B, B2}` makes each import of B load B2. The loader compares the description of each export that the importer uses, and one difference refuses the load. A replacement is visible in the module record of B2, and a program cannot ask for one or refuse one. The root service applies it only for a signed replacement row.

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

The replacement table is the list of the replacements of the machine, which the root service holds and gives to the loader of each program that it starts.

A program that loads modules, such as the console or the manual, receives the table with the right Read and reads it before each load. A program cannot change it. A program with the role Replace asks the root service: `replace("calendar", "calendar_fixed")` adds a record, `replace("calendar", "")` removes it, and `replacements()` lists the table. A change applies to the loads that follow; a program that runs keeps its modules. It is not the replacement list, which holds the signed pairs.

The design: `docs/MODULE_CONTRACT.md`, "Replacement of an import".

Do not use: override list, LD_PRELOAD, redirection table.

### Loader

The loader is the code in user space that builds a program or a module space from a module and its imports (`src/library/support/system/load.odin`).

The kernel loads no module: it maps memory objects and records what the loader asserts. The loader finds each module by hash in its load source, maps its segments, rebases them, binds each slot, and writes a module record. On a failure the module space stays as it was, and the caller receives a load error. The loader runs in the program that starts another program, such as the root service, or in a program that loads a module for itself. It has no search path.

The design: `docs/MODULE_CONTRACT.md`, "2. Loading", and `docs/ARCHITECTURE.md`, "U3. Module store and loader".

Do not use: linker, dynamic linker.

### Prepared module

A prepared module is the set of memory objects that hold the parts of a module that do not change after the load, kept by the program that starts programs, by the hash of the module.

A prepared module lets many programs share the pages of one module: its code, and the segments that are read-only after the load. The table `system.Prepared_Modules` keeps each handle without the right Write, so a write of a program to its code is a page fault. Each program still receives its own copy of each writable segment. The kernel learns nothing of the module format: it maps memory objects with the rights of their handles.

The design: `docs/MODULE_CONTRACT.md`, "2. Loading".

Do not use: shared library, image cache, page cache.

### Shared code

Shared code is the pages of a prepared module that each program of the module maps without Write: its code, its constants and its data that is read-only after the rebase.

Shared code is why one module in many programs costs its pages once. Each program still has its own copy of each writable segment, made from the bytes of the file. Shared code needs code that the loader never writes: a call to another module goes through a slot in data, so the code pages stay identical to the file.

A merge of two modules into one makes a new hash, and two programs that merge the same module do not share its pages.

The design: `docs/MODULE_CONTRACT.md`, "2. Loading".

Do not use: text segment, shared object.

### Slot

A slot is 8 bytes of data of a module that the loader writes with the address of one export of an import.

A call to another module is one indirect call through a slot: `call *slot(%rip)`. So the code never changes with the place of the other module, and code pages stay shared. After the bind the loader makes the slots read-only. A slot is bound once, at load, with no lazy binding: a missing export fails the load, never a later call. Measured: a call through a slot costs about 3.5 ns in the program `imports`.

The design: `docs/MODULE_CONTRACT.md`, "3. Static is dynamic".

Do not use: GOT entry, import address, stub.

### Load source

The load source is what a loader can read: the files that its program was granted, each named by its hash, and the replacements that the starter of the program gives.

The load source closes the hole of a global library directory. A loader finds an import only there, and checks the hash and the tables of each file before it uses it. The root service and the console give the boot image; a call host receives a list of files from the console. For a disk program, the root service adds the files that an import scan found. A file that the load source does not hold gives the load error Find.

The rule: `docs/PROPERTIES.md`, "20. No ambient access: the other holes to close".

Do not use: search path, library path, module store (for this).

### Disk program

A disk program is a program whose module file is an object of the store `programs` of the storage service, and not a file of the boot image.

A disk program adds a program to a machine with no new boot image. The principal names its file by a nickname and by its hash: `start_from_disk("visitor", "5f0c…")`. The root service starts the bytes only when their BLAKE3 hash is that hash: the storage service carries the bytes and does not choose them. Its name gives it no grant: it receives the grants of its nickname in the disk grant table. A disk program is not a package: it has no signer and no version, and nothing is installed.

The design: `docs/MODULE_CONTRACT.md`, "A program from a disk".

Do not use: installed program, side-loaded program.

### Module file service

The module file service is the program `programs`: it stores a module file that a web server gives in the store `programs` of its principal, and lists the files of that store with the hash of their bytes.

A developer adds a program to a machine that runs, with no disk from the modus tool. In the console, `programs.receive(nickname, path)` gives the hash of the bytes that came, then `start_from_disk(nickname, hash)` starts them. `programs.list()` gives each file with the hash that the service computes again. The service starts no program and proves nothing: the root service checks the bytes against the hash. It is not a package manager: it reads no signature, version or dependency.

The design: `docs/MODULE_CONTRACT.md`, "A program from a disk".

Do not use: package manager, installer, downloader.

### Import scan

An import scan is the read of the store `programs` of a principal by the root service, to find each import of a disk program that the boot image does not hold by the BLAKE3 hash of the bytes of a file.

A developer puts a program and its library modules in the store `programs`, under any nicknames. At the start, the root service reads each entry, keeps the bytes whose hash an import names, and gives them to the loader beside the boot image. A hash that no file has refuses the start. The scan trusts no name and no hash that the storage service gives. It is not a search path: only bytes with the hash of the import are kept.

The design: `docs/MODULE_CONTRACT.md`, "A program from a disk".

Do not use: dependency resolution, library lookup, search of an import.

### Module space

A module space is the set of modules that a loader put in one program, each module one time.

Two modules that import a third one call the same copy of it: the module space counts the uses of each module. A module that another module of the space uses stays when its caller unloads it; a module with no use leaves, and its imports lose one use. `system.module_space_release` removes a module; when the kernel refuses the removal, the load error has the stage Unmap.

The design: `docs/MODULE_CONTRACT.md`, "2. Loading".

Do not use: link map, address space (for this).

### Load error

A load error is the record of a load that failed (`module.Load_Error`, 392 bytes): the stage, the module that was being loaded, the import, a replacement on the path, the export, and the two descriptions that differ.

A load error is the error record of the loader. It names modules by hash and by name, because the caller of a call host does not have these names. Zero is "no error", and the caller owns the record. `system.load_error_text` writes it as sentences, for example "error: agenda imports calendar, and its replacement calendar_changed fails the check". A caller that gives a table of error details receives one load error for each import that is missing or has the wrong hash.

The design: `docs/MODULE_CONTRACT.md`, "The error of a load".

Do not use: exception, errno, error message.

### Stop report

A stop report is the record that the kernel keeps of a program that stopped on a fault (`op.Stop_Report`): the stop code, the instruction, the address, the module record of the module that ran, and the stack trace.

A stop report replaces a core dump. It is small and typed, and the kernel writes it at the fault, from the frame of the thread, its frame pointers and the module records of the program. The holder of the program handle with the right Read reads it with `Program_State`. The stop code says why the program stopped: a fault and its vector, a refused return, or a fault ring that ended with a waiting thread. Example: the console prints "error: the instruction is at offset ... of calendar_fixed ...".

The design: `docs/MODULE_CONTRACT.md`, "A fault: the stack trace".

Do not use: core dump, crash report, signal info.

### Kept stop report

A kept stop report is the copy of the stop report of a disk program that the root service keeps after the program stopped on a fault (`disk_program.Kept_Stop_Report`), with the hash of its module file.

The root service holds the only handle of a disk program and closes it at the reap, so the kernel forgets the stop report. The copy keeps the frames that a module record holds, and no other word of the memory of the program. `stop_report("visitor")` in the console asks the debugger service for it, with no attach; the service names each frame by its procedure and its line. It is not a log: a new fault of the nickname replaces it, and a run with no fault removes it.

The design: `docs/MODULE_CONTRACT.md`, "The debug object of a disk program".

Do not use: crash log, saved stop report.

### Refused return

A refused return is a return of the kernel to a thread that the processor refuses at `iretq`: the kernel stops the program of the thread, as its own fault, with the stop code `STOP_CODE_RETURN`.

The kernel returns to a program only with `iretq`, and checks the frame before each return: an instruction address at or above `USER_END`, or a stack address that is not canonical, cannot pass. A fault of the `iretq` itself is a fault of the thread, not of the kernel: the stop report has the refused address, and the machine goes on. A refused return can come from a frame that a program wrote with thread control, which checks the frame first.

The design: `docs/ARCHITECTURE.md`, "The return to a program".

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

Every module keeps frame pointers, so that the kernel, a debugger or a profiler walks the stack with no unwind tables and runs no code of the program. The modus tool compiles each module through LLVM with `--frame-pointer=all`. The cost, measured: the code of `console` is 0.45 % larger, and a call through a slot is about 0.4 ns slower.

The rule: `docs/MODULE_CONTRACT.md`, "Closed rules".

Do not use: base pointer, frame record.

### Stack trace

A stack trace is the list of the return addresses of the calls that led to a fault, from the frame pointers, each with the module record that holds it.

The kernel writes the stack trace into the stop report: frame 0 is the instruction, and each next frame is a return address. The walk stops at 16 frames, or at a frame pointer that is 0, not aligned, not above the one before, or not memory of the program. A reader names each frame "module + offset"; the modus tool names the function from the linked file of the module.

The design: `docs/MODULE_CONTRACT.md`, "A fault: the stack trace".

Do not use: backtrace, call stack (for this), unwind.

### Module record

A module record is what the kernel keeps of one module in a program (`op.Module_Record`, 88 bytes): its base address, its size, its hash, the hash that a replacement put it in place of, and its module writer.

The loader writes the record with `Program_Module` after it mapped the module. The kernel does not read the module: the record is what the loader asserts. The kernel uses it to name the module of a fault address and of each frame of a stack trace, and `Inspect` gives the records of a program. A program has at most 16 module records.

The module records of a program that runs are its identity: `manual.running()` and `manual.edges()` read them.

The design: `docs/MODULE_CONTRACT.md`, "2. Loading".

Do not use: link map entry, loaded image list.

### Module writer

The module writer of a module record is the party that wrote it: the program itself (`program`), or a holder of its program handle with Control, its starter (`starter`).

The kernel sets it at each `Program_Module`, from the caller and the target. A program cannot replace or remove a record of the writer `starter`, or map memory at its addresses. So a record of the writer `starter` names the code that the starter put there, and a record of the writer `program` is what the program says of itself. Example: the root service starts `imports`, whose module has the writer `starter`; `imports` loads `calendar`, whose record has the writer `program`. It is not the `system.Writer` of a text.

The design: `docs/MODULE_CONTRACT.md`, "The writer of a module record".

Do not use: owner, author.

### Table

A table is a set of records of one record description that follow each other in memory, with their count.

The table is the unit of data of the system. The console holds a table as one value and passes it to the next function with no parsing. The callee writes a Table result in memory of the caller, with the count of the full table: a count above the capacity means that the table did not fit. A record of a table holds no Handle field. Example: `monitor.programs()` gives a table of `Program` records.

The rules: `docs/PROPERTIES.md`, "12. Module metadata in flat tables, read through functions", and `docs/PROPERTIES.md`, "19. A command is a function: no text between programs".

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

An information function is a function that reads the flat tables of modules, the module records of the kernel or the replacement table, and fills a table in memory of the caller (`src/library/support/information`).

The information functions replace a database of modules. They allocate nothing and keep no state; each one reads the tables in a line and gives records. The manual service exports them, so the console can combine them: `manual.running()`, `manual.edges()`, `manual.check()`. A new kind of question is a new function, or a combination of functions in the console.

The rule: `docs/PROPERTIES.md`, "12. Module metadata in flat tables, read through functions".

Do not use: query, reflection API, introspection.

### Catalog

A catalog is the input of an information function: the modules that a program can see, and the replacements of the machine.

A catalog is the boot image that the program was granted and the records of the replacement table. An information function sees nothing else: a program with no grant of the boot image has an empty catalog.

Do not use: registry, repository, package database, index.

### Problem

A problem is the error value that a reader of input that nobody checked gives for a rule that the input breaks: the kind, the place, the byte, the bad value and its limit.

A problem is the error record of a parser of hostile bytes. An information function gives one for a module file (`information.Problem`): the table and the record of the module, and the byte of the file. The network service gives one for a frame (`datagram.Problem`): the layer of the frame and the byte. Example: `manual.check` gives a problem for a Table parameter whose record has a Handle field.

Do not use: exception, errno, error code.

### Boot image

The boot image is the one block of data that the boot program loads with the kernel: the modules of the first programs and the resources, each with its name and its hash.

The boot image starts the system with no file system. Its header has a table of modules and a table of resources (`src/library/contract/boot_info`), each entry with a name, the BLAKE3 hash of the bytes, the offset and the size. The boot program checks each entry against the system description before the kernel starts, and the root service checks them again. The root service is the load source of the first programs; another program receives the boot image only by the grant `Image`.

The design: `docs/ARCHITECTURE.md`, "U2b. Resources of the boot image".

Do not use: initrd, ramdisk.

### Position-independent

Position-independent code runs correctly at any address with no change to its bytes.

All code of the system is position-independent: a module reaches its own data relative to the instruction, and another module through a slot. The loader writes only data (the rebases and the slots), never code. So code pages stay shared and never writable.

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

A module names only its exports. With the debug object, the frame "fault + 0x1478" reads "fault::three + 0x8 in fault (src/programs/fault/main.odin:15)". The modus tool writes it at the build from the DWARF of the linked file, so the system reads no DWARF: a program reads only sorted tables of fixed records. The object names its module by the hash of the module file; the bytes of the module are the same without it. It is not the whole debug information of the compiler.

The design: `docs/MODULE_CONTRACT.md`, "Debug information".

Do not use: symbol file, PDB, dSYM, debug info (for the file), symbols.

### Procedure table

The procedure table is the table of a debug object that gives, for each procedure of the module, its start, its size and its name with its package.

The records are sorted by their start and never overlap, so a reader finds the procedure that holds an offset with one binary search (`debug_object.place_of`). A name holds only visible ASCII characters, so a hostile name cannot forge a line of the log or of a terminal. Code that the compiler inlined has the name of the procedure that holds it. Example: the name `fault::three` has the package `fault`. It is not the Functions table of the module metadata, which describes the exports only, for callers.

The design: `docs/MODULE_CONTRACT.md`, "The debug object".

Do not use: symbol table, function table.

### Line table

The line table is the table of a debug object that gives, for each range of the code of a module, the source file and the line that the code comes from.

The code from the offset of a row up to the next row comes from its line. The rows are sorted by their offset, so a reader finds the line of an instruction with one binary search. A row with the file 0 says that the code after it has no source line. For a return address the reader looks up the byte before it, so the line is that of the call. Example: the machine test checks that the stack of `fault` names the lines 15 and 20 of `src/programs/fault/main.odin`.

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

The debug image is one file that holds the debug object of each module of a build, in the form of a boot image, so that the programs of a machine can name the procedures and lines of every module.

The modus tool writes it as `build/debug.image` and copies it to the boot volume beside the boot program. The boot program reads it and does not verify it, because no code comes from it; a start with no debug image gives no names. The root service maps it read-only in each program with the grant `Debug_Image`, which finds an object with `system.debug_object_of`. It is not part of the boot image, so a change of a debug object changes no signature and no measure of the trusted boot.

The design: `docs/MODULE_CONTRACT.md`, "Where the debug objects are".

Do not use: symbol server, debug archive.

## Running code

### Program

A program is a running module with its own address space and its own handle table.

A program is the unit of isolation: its memory and its handles are its own, and it reaches nothing else. Its starter makes it with `Program_Create`, maps its module, gives it handles, and starts its first thread with `Program_Start`. The starter keeps the program handle: with Control it stops the program, and with Read it reads its stop report. When the last handle closes, the kernel stops the program. A program is not a Unix process: it inherits nothing from its starter, and receives one context.

The design: `docs/ARCHITECTURE.md`, "K1. Handle table", and `docs/PROPERTIES.md`, "2. Sandbox by default".

Do not use: process, task, application, app.

### Program slot

A program slot is the place of a program in the table of the programs of the kernel: the index that `Inspect` with the kind `Program` takes, and that `Program_State` gives for a program handle.

A program slot serves a new program after the last handle of the program before it closes. So the slot alone does not name one program: with its program serial (`Program_Report.program_serial`), a number that changes for each new program in the slot, it does. The monitor and the inspect tool name a program by the two numbers; the disk program page names each disk program so.

A program slot is not a process number: no program names another program by it, and no operation acts on a program by its slot.

Do not use: process ID, PID, program number.

### Thread

A thread is one flow of execution inside a program: a register state, a thread record and a kernel ring.

The threads of a program share its memory and its handles. `Thread_Create` makes a thread: a budget pays for its slot and its thread area, and the call gives the entry address, the stack, one parameter and its thread schedule. The thread starts at the entry with the parameter in its first register. It asks the kernel for work through its own kernel ring, and waits with the word wait. It ends with `Thread_Stop`, by its own return, or by a stop of its program. A thread handle with Control ends it from another thread.

The design: `docs/ARCHITECTURE.md`, "K3. Scheduler".

Do not use: fiber, task.

### Thread record

The thread record is the page that a thread can read about itself (`op.Thread_Record`): its own address, the parameter of its entry, its number, its event word, and the fault ring when the thread is a fault handler.

The `gs` register of the thread holds the address of the record, and the first word of the record is that address, so `mov rax, [gs:0]` gives it on any stack. The kernel ring of the thread is one page after the record. The kernel writes the record when the thread starts; after that it only adds to the event word and writes the fault ring.

The record holds no data of a module: the system has no thread-local storage, and `fs` is free for the program.

The rule: `docs/MODULE_CONTRACT.md`, "Closed rules".

Do not use: thread-local storage, TLS, TEB.

### Word wait

The word wait is the one way for a thread to wait for something else than a time: the thread waits while each 32-bit word of a list holds a given value.

`Word_Wait` takes a list of words, each with the value that it holds while the thread waits, and a deadline. Another thread changes a word, then calls `Word_Wake` on it. If a word does not hold its value when the thread enters the wait, the wait ends at once, so no wake is lost. Two programs that map one memory object wait on one word. Every wait of the system uses it: a ring waits on its counters, a lock on its word, a thread on its event word.

The design: `docs/ARCHITECTURE.md`, "K4. Rings and wait".

Do not use: futex.

### Lock

A lock is one word of memory that one thread holds at a time (`system.Lock`).

A lock takes no kernel entry when it is free: one compare-and-exchange takes it. A thread enters the kernel only to wait for a lock that another thread holds, with the word wait, and the thread that frees it wakes one waiter. A zero lock is free. A lock in shared memory works between two programs.

A lock of a program is not a lock of the kernel: the kernel has its own locks, which are words of the kernel that one processor holds.

Do not use: mutex, critical section, semaphore.

### Event word

The event word is a word of the thread record that the kernel adds 1 to when an event of the thread arrives.

The events are: an interrupt of the program, the stop of a program whose handle the program holds, and the end of another thread of the program. The thread reads the word, reads the state that it needs, then waits on the word with the value that it read first: an event between the read and the wait ends the wait at once. `system.wait_begin` starts each wait list with the event word.

An event word replaces signals: the kernel never runs code of the program in the middle of other code.

Do not use: signal, notification.

### Processor

A processor is one unit of the machine that executes instructions, and runs one thread at a time.

A machine has several processors. The kernel keeps one processor record and one run queue for each, and its locks are made so that the processors work in parallel. The first machine is QEMU with 4 processors in the machine test.

Do not use: core, CPU, hart.

### Processor record

The processor record is the record that the kernel keeps for one processor: its kernel stack, its current thread, its page table, its frame cache, its counts and its observed kinds.

Most fields of a processor record are written only by its own processor, so they need no lock. Other processors read some fields with atomic loads, and set a few flags (`pending`, `preempt`) to ask the processor for work.

The design: `docs/ARCHITECTURE.md`, "The data of the kernel".

Do not use: per-CPU data.

### Switch of threads

A switch of threads is the moment when a processor leaves one thread and takes another one, or the same one again, from a run queue (`schedule`).

A processor leaves a thread when the thread waits, when its turn ends, at a preemption or at a stop. The kernel saves the extended state of the thread that it leaves and restores the extended state of the thread that it takes there, and nowhere else: a kernel entry saves no vector register, because the kernel has no vector code. A kernel event `Switch` records each switch for a program with the right Events.

The design: `docs/ARCHITECTURE.md`, "The extended state of the processor".

Do not use: context switch, task switch.

### Extended state

The extended state is the registers of a thread that are not general registers and that the processor saves and restores as a block: the x87 registers, the SSE registers and `MXCSR`, and, when the kernel enables them, the AVX and AVX-512 registers.

The kernel saves each state component that it enables, and sets `XCR0` itself: a kernel that keeps the setting of the firmware lets a program read the AVX registers of another thread. It saves the state only at a switch of threads. Thread control reads and writes the extended state of a held thread. It is not the general registers, which the frame of the thread holds.

The design: `docs/ARCHITECTURE.md`, "The extended state of the processor".

Do not use: FPU state, floating-point state, vector state, XSAVE state.

### State component

A state component is one part of the extended state that one bit of `XCR0` enables and that the processor saves as one unit.

The kernel enables x87 (bit 0) and SSE (bit 1) always, AVX (bit 2) when the processor has it, and the three parts of AVX-512 (bits 5 to 7: the opmask registers, the high halves of zmm0 to zmm15, and zmm16 to zmm31) when the processor has AVX-512 F. It enables no component that it does not save: MPX, PKRU and AMX stay off. Every processor of the machine must have the same components at the same offsets, else it stays stopped.

The design: `docs/ARCHITECTURE.md`, "The extended state of the processor".

Do not use: XSAVE feature, xfeature.

### Extended state area

The extended state area is the memory where the kernel saves the extended state of one thread: a fixed field of 2688 bytes, aligned on 64 bytes, in the entry of the thread in the thread table of the kernel.

The area is complete while the thread is on no processor; while the thread runs, its state is in the registers. Only the kernel reads and writes it, and no program maps it. It is part of the slot of the thread, which the budget pays with its `threads` amount: 256 slots cost 672 KiB of kernel memory.

The design: `docs/ARCHITECTURE.md`, "The extended state of the processor".

Do not use: FPU area, XSAVE area, save area.

### Usable instruction set

A usable instruction set is a group of instructions of the processor (SSE4.2, AVX2, AVX-512 F, BMI2, ...) that the processor has and whose registers the kernel saves.

A program reads the sets once with `src/library/support/instruction_sets`, from `CPUID` and `XCR0`, with no kernel operation. A set that the processor has but whose state the kernel does not save is not usable: an instruction of it stops the program with an invalid opcode.

Do not use: CPU feature, ISA extension.

### Start state

The start state is the content of the extended state area of a new thread: the x87 control word `0x037F`, `MXCSR` `0x1F80`, every register zero, and a header that says that only x87 and SSE are in the area.

A new thread receives no state of the thread that had its slot before: the kernel writes the start state at each creation.

Do not use: init state (for this), initial FPU state.

### Stage

A stage is one part of the start of the machine, with a start time and a duration: the firmware, two parts of the boot program, and four parts of the kernel.

The boot record holds the stages; the boot display and the card of the start show them with their measured time.

Do not use: phase.

### Step of the start

A step of the start is one point on the path of the start that the boot display shows (`bootscreen.Step`): ten points from the firmware to the desktop.

The steps are Firmware, Kernel_Module, Boot_Image, Memory_Map, Kernel, Processors, Root, Input, Compositor and Desktop. The program that draws says which step the machine does now. A step has no time; a stage is a part with a measured time.

Do not use: phase, progress.

### Card

A card is the frame of one subject in a display: a title in its accent, a caption that names its record, and its content.

The boot display, the monitor and the site draw their facts in cards, so that each subject has one place and one color.

The rules: `docs/DESIGN.md`, "10. Elements".

Do not use: panel, box, widget.

### Tile

A tile is a rectangle that stands for one thing of a set, with its name inside; its width can show a size.

Example: the card of the boot image shows a tile for each file of the image.

The rules: `docs/DESIGN.md`, "12. The card of the boot image".

Do not use: chip, badge.

### Size strip

A size strip is a bar of one row in which each file of a set is a part as wide as its share of the bytes, with a least width.

The parts fill the bar exactly and carry no name. The card of the boot image starts with one, so the eye sees at once which files are large.

The rules: `docs/DESIGN.md`, "12. The card of the boot image".

Do not use: treemap, histogram, size bar.

### Accent

An accent is the color of the concept that a card is about.

One concept keeps one accent on every display, so a reader finds the same subject by its color.

The rules: `docs/DESIGN.md`, "4. Color".

Do not use: theme color.

### Boot record

The boot record is the record that the kernel keeps of how the machine started (`op.Boot_Report`): the stages, the memory ranges, the firmware, the framebuffer, the sizes of the kernel and of the boot image, and the trust record of the boot program.

A program with the machine handle and the right Inspect reads it. The boot display and the monitor show it.

Do not use: boot log, dmesg.

### Guard page

A guard page is a page of addresses with no memory, next to a stack: a use of it is a page fault, not a write on other memory.

The kernel puts a guard page before and after each kernel stack and each interrupt stack. The loader leaves one page with no memory between two modules. A stack that overflows into a guard page stops at once, at the instruction that overflowed.

Do not use: red zone, canary.

### Interrupt stack

An interrupt stack is a stack of one processor that the processor itself loads for one kind of exception, at any privilege, from the task state.

Some exceptions can come when no stack is safe: the kernel stack is full, or the stack pointer is still the one that a program chose. So the gate of each such exception names an interrupt stack, and the processor switches to it also when it already runs in the kernel. Each processor has one for the double fault, the debug exception, the non-maskable interrupt and the machine check, each between guard pages. It is not the kernel stack, where the kernel runs an entry.

The design: `docs/ARCHITECTURE.md`, "The return to a program".

Do not use: IST, exception stack, NMI stack.

### Kernel stack

A kernel stack is the stack of 16 pages of one processor where the kernel runs each entry from a program, each interrupt that it takes and each operation.

Each entry from a program starts at its top, and no entry continues an earlier one. A guard page is before it and after it. The build measures the deepest chain of calls on it and fails when less than 4 pages stay free. It is not an interrupt stack: those hold the frames of the exceptions that can come when no stack is safe.

The design: `src/md/infrastructure/kernel_stack_depth.md`; `docs/TOOLS.md`, "The deepest stack of the kernel".

Do not use: thread stack (for this), system stack.

### Deepest chain

The deepest chain is the chain of calls of the kernel that uses the most bytes of a kernel stack, from a place where the kernel starts on it.

The tool computes it at each build from the frame of each procedure that `llc` writes, the calls of the listing of the linked kernel, and the scan of the stack pointer. Stated rules cover what the listing cannot show, such as the targets of the indirect calls and the bounded recursions. Each build prints the chain, procedure by procedure, in a measure line. It is a bound, not a measure of a run: a chain of the graph can be a chain that no input runs.

The design: `src/md/infrastructure/kernel_stack_depth.md`.

Do not use: stack depth (for the chain), call stack (for this), worst-case stack.

### Cycle break

A cycle break is a stated rule of the measure of the kernel stack: below one procedure, no chain runs a named other procedure again, so a cycle of calls through them has a depth.

The listing of the kernel shows a cycle when a procedure can reach itself through others, and a cycle has no depth. A state of the kernel can cut it: `lock_order_broken` logs, and the log takes a lock, but it starts the report of a fault first, and from then the log takes no lock. The row names the two procedures and its reason in the source of the tool; the measure takes the depth of the first with the second left out, and a cycle with no row stops the build.

The design: `src/md/infrastructure/kernel_stack_depth.md`.

Do not use: cycle exception, recursion bound (for this).

### Scan of the stack pointer

The scan of the stack pointer is the part of the measure of the kernel stack that follows the bytes on the stack through each compiled procedure of the listing, path by path.

The scan counts each `push`, `pop`, and constant `sub` or `add` on `%rsp`. At a call the count can be above the frame from `llc`: the arguments that `llc` pushed before the call are outside the frame, and the measure adds them under the callee. A jump through a register with the count 0 is an indirect tail call, which needs a stated rule that names its targets. Each `ret` and each tail call must find 0, else the build stops. The scan does not replace the frame from `llc`.

The design: `src/md/infrastructure/kernel_stack_depth.md`.

Do not use: stack tracking, stack pointer analysis, push depth.

### Direct map

The direct map is the part of the kernel half of the addresses that shows all physical memory.

The kernel reads and writes any frame through it: a thread record, an event ring, a page table. It is never executable, so no write of data can become code of the kernel.

Do not use: physmap, identity map.

### Run

A run is a set of pages that follow each other in a page table with one protection (`Mapping_Run`).

The report `Inspect` of kind `Mappings` (`op.Mapping_Report`) gives the runs of the kernel half or of the half of the program that asks: one record for each run, not one for each page, so its size follows the mappings and not the memory.

Do not use: extent, VMA.

### Self test

A self test is a boot of the machine in which the kernel does one thing that the processor must refuse, to prove that the processor refuses it.

Six tests are of the page tables: a stack overflow, a write to the code of the kernel and to its view in the direct map, a run of data, and a read and a run of memory of a program from the kernel. The expected fault stops the machine with its report, and the machine test checks that report. The seventh is a register trial that writes an address that is not canonical to `IA32_KERNEL_GS_BASE`: the kernel goes on after the refusal and stops the machine with the code 0. It needs KVM: QEMU with TCG takes that write.

Do not use: negative test, lkdtm.

### Log record

A log record is one entry of the log of the kernel (`op.Log_Record`, 256 bytes): a number, a time, a program (its name, its program slot and its program serial), the own number of the record among the records of its program, a thread, a level, a channel, a text and the value runs of the text.

A program writes a record with the kernel operation `Log` and a log handle with Write. The kernel sets the number, the time, the program and the thread, so a program cannot write a record in the name of another one. A long text continues in the next record. The log service serves the records as a table, `log.records(after)`, to each caller in its log scope. It is not a line of the serial port, which the serial writer prints from the record.

The design: `docs/TOOLS.md`, "The log".

Do not use: log line, message.

### Serial writer

The serial writer is the one processor that writes the serial port at a time: the drain of the log at the tick of any processor or in a long wait for a lock, the flush before the machine stops, or the report of a fault of the kernel.

The operation `Log` writes the records of the log only. At a tick, a processor writes the lines that the serial port does not have yet, for a bounded time. So a `Log` never waits for the lines of other programs, and its time tells it nothing of what they wrote. In a flood the serial port loses lines, and one line gives their count. A processor takes the serial writer with a compare-and-exchange: the tick does not wait for it. It is not a lock of the lock order.

The design: `src/md/features/log_side_channels.md`.

Do not use: serial lock, console driver, printk.

### Value run

A value run is a part of the text of a log record that is one value: a start, a length and its value kind.

A writer states the kind of each part of a line of the log (`system.Size`, `system.Duration`, `system.Module_Name`, a number), and the record keeps the runs beside its text. A reader draws each run in the color of its kind; a reader that ignores the runs reads the same text. A run gives a color, never text: runs that do not fit their text leave the record plain. It is not a run of code, which is a part of a line of the console, with a code kind.

The design: `docs/TOOLS.md`, "The log".

Do not use: span (for this), token, highlight range.

### Integer unit

An integer unit is what an Integer parameter of a command or of an export, or an Integer field of a record, counts: a value kind, Size or Time, and one unit of that kind, such as pages or milliseconds.

The palette shows the unit after the number of a field, `buffer(count: 4 pages)`, so the principal types the number in the unit that the command reads. An export states the unit in its description, from a type of the contract such as `value_kinds.Size_In_Bytes`, so the check of a replacement refuses another unit. A plain count, such as the number of a thread, has no integer unit.

The design: `src/md/features/palette.md`, "The form of an entry, from its descriptions". The format: `docs/MODULE_CONTRACT.md`, "The unit of an Integer parameter" and "The unit of an Integer field".

Do not use: dimension, measure (for this).

### Cut mark

A cut mark is the end of a text that a place of a fixed size does not hold: the start of the text, cut after a whole character, then "... and N bytes more" (`modus:contract/cut_mark`).

N counts each byte that the place does not hold, so the reader knows what is missing. It is the one form of a cut text in the system: a text is written whole, cut with this mark, or refused; never cut in silence. `modustool check` refuses a source that sets the count of a writer by hand.

The rule: `docs/ARCHITECTURE.md`, "A text is never cut in silence".

Do not use: ellipsis, truncation, "..." (alone).

### Channel

A channel is the short name of 16 bytes at most that a program gives to a log record, to group the records of one subject.

A record with no channel has 16 zero bytes there. A reader of the log, such as the step `Record` of the machine test, chooses records by program, channel and level.

Do not use: facility, tag, category, logger.

### Level

A level says how much a log record matters: Info, Debug, Warning or Error.

Info is 0, the default. Debug is for the reader who looks for a fault.

Do not use: severity, priority.

### Own records

The own records of a program are the log records that the kernel wrote for the `Log` operations of that program: the records with its program slot and its program serial.

The kernel sets the slot and the serial of each record, so a program cannot write a record in the name of another one. The two numbers together name one program: a new program in the same slot has another serial, and does not read the records of the program before it. A record that another program wrote about this program, such as the line "root: started log_reader" of the root service, is not one of its own records. A caller of the log service that does not act for the principal receives its own records only.

The design: `src/md/features/log_reader_scope.md`.

Do not use: my log, private log, log of a program (for this).

### Own number

The own number of a log record is its place among the records of its program: 0 for the first record that the program wrote, 1 for the next one (`op.Log_Record.own_number`).

The kernel counts the records of each program and writes the count in each record. A reader of its own records receives the own number as the number of each row, and gives `after` in own numbers. Its count `lost` is a gap in its own numbers, so it learns no number or count of the records of other programs. A reader of the whole log receives the number of the record in the whole log. The own number wraps after 2^32 records.

The design: `src/md/features/log_reader_scope.md`.

Do not use: local sequence, private number, cursor (for this).

### Own log ring

The own log ring of a program is the ring of its last 64 log records that the kernel keeps beside the whole log, and that only its own records fill (`op.OWN_LOG_RECORD_CAPACITY`).

The kernel writes each record of a program in the whole log and in its own log ring. A log storm of another program pushes records out of the whole log, never out of this ring, so a reader of its own records learns nothing of how many records the others wrote. The budget of the program pays the ring. Only the log service reads a ring, with the kernel operation `Log_Read`. It is not a copy that the program maps.

The design: `src/md/features/own_log_ring.md`.

Do not use: per-program buffer, log buffer, log mailbox.

### Log scope

The log scope of a connection to the log service is the set of log records that its caller receives from `log.records(after)` and `log.value_runs(after)`: the whole log, or its own records.

The root service writes it in the grant of the connection, and the log service chooses the records; the reader never maps the memory of the log. A caller that acts for the principal, such as the console, receives the whole log; each other caller receives its own records. A starter reads the records of a child with `log.program_records(program, after)`, where it lends the program handle of the child. A log scope never names a channel, because the writer chooses a channel.

The design: `src/md/features/log_reader_scope.md`.

Do not use: log permission, log view, log access level.

### Lock of the kernel

A lock of the kernel is a word that one processor holds at a time, to change one kind of data of the kernel.

The kernel has no lock for the whole kernel: each lock protects a table or a part of a table, and each kind of lock has its place in the lock order. Interrupts are off in the kernel, so a processor never takes a lock again in an interrupt. The lock count of each kind is in the system report, and a kernel event `Lock_Wait` records each wait. A lock of the kernel is not the lock of a program, which is a word of the program.

The design: `docs/ARCHITECTURE.md`, "Locks of the kernel".

Do not use: spinlock, mutex (for this).

### Lock order

The lock order is the order of the kinds of locks of the kernel: control, program, origin, region, frame, cache, log, wait, run.

A processor takes a lock only if it holds no lock of a later kind. A cycle of waits needs a processor that waits for an earlier kind while it holds a later one, which the order forbids: so no deadlock exists. The test build checks the order at each take and stops the machine with a report if it is broken.

The design: `docs/ARCHITECTURE.md`, "The locks, in their order".

Do not use: lock hierarchy, lock ranking.

### Control lock

The control lock is the one lock of the kernel for the paths that cross programs or end objects that several programs name: start, stop, give to another program, revoke.

These paths touch a set of programs with no bound: a revocation follows the origins through any program, and a stop closes handles that stop other programs. One lock makes each of them atomic for the others. They are rare (a program does them when it starts, stops or gives access, not in its work), and the measures show that the hot paths do not take it.

The design: `docs/ARCHITECTURE.md`, "The locks, in their order".

Do not use: big kernel lock, giant lock, kernel lock.

### Program lock

The program lock is the lock of one program: its handles, its mappings and its page table.

A kernel operation of a program takes its own program lock, so two programs work in parallel. A processor holds two program locks only under the control lock.

The design: `docs/ARCHITECTURE.md`, "The locks, in their order".

Do not use: address space lock, mmap lock.

### Frame lock

The frame lock is the lock of the page frames, the reserved pages, the pages of the budgets and the slots of the memory objects.

Each move of pages between a budget, the reserved pages and the frame table is one section under the frame lock, so the sum of the frames holds whenever it is free. The frame cache of each processor keeps most first uses away from it.

The design: `docs/ARCHITECTURE.md`, "Rules that keep each path correct".

Do not use: zone lock, page allocator lock.

### Run queue

A run queue is the threads that are ready and that no processor runs, of one processor: its home threads.

Its run lock protects it and the scheduling state of these threads. A new thread goes to the queue of the processor that created it; a woken thread goes to the queue of its home. A processor with less work takes threads from a queue with more, so the ready threads spread over the processors. The strategy of the machine orders each queue.

The design: `docs/ARCHITECTURE.md`, "Rules that keep each path correct", and `docs/SCHEDULING.md`, "2. What this system takes".

Do not use: runqueue, ready list.

### Strategy

A strategy is the rule that orders the ready threads of each run queue: six procedures of the kernel over fixed fields of the thread and of the run queue.

The machine has one strategy at a time: round robin, fair or EEVDF. The kernel calls a strategy through a `switch` with a direct call in each case, because the strategies are a closed set. A strategy owns no memory: its state is fields of the thread and of the queue. A program with the right Schedule changes the strategy while the system runs (`Strategy_Set`); the principal does it through the program `scheduler`, for example with `strategy("eevdf")`. The limit of a budget is not a strategy: it holds under each one.

The design: `docs/SCHEDULING.md`, "2. What this system takes".

Do not use: scheduler class, policy, scheduling algorithm, governor.

### Turn

A turn is the time that a thread runs on a processor from its pick to the moment when it leaves: it waits, its budget has no time, or its strategy ends the turn.

A turn is not a state of a thread: a wake preemption ends a turn, and the thread stays ready.

Do not use: quantum, timeslice (for this).

### Time slice

The time slice is the longest turn under each strategy: 10 ticks.

At the end of a time slice the processor passes through the balance between the processors. So each processor that has a thread looks at the other queues at least each 10 ms. Under round robin each turn has this length.

The design: `docs/SCHEDULING.md`, "The time slice is the longest turn".

Do not use: quantum.

### Weight

A weight is a number from 1 to 1024 of a thread: its share of a processor against the other threads of its queue, under a strategy with weights.

The weight is set when the thread is created. The weight 0 gives the new-thread weight limit of the creating thread or of its program: 1024, the full weight, unless it was lowered. A write of the thread schedule changes the weight while the thread lives: a program only lowers it, and only the holder of the right **Schedule** on the machine raises it. The processor limit of the budget holds under any weight.

The design: `docs/SCHEDULING.md`, "Weights and requests: a field at thread creation" and "The schedule of a live thread".

Do not use: priority, nice value, shares.

### Virtual time

The virtual time of a thread is its run time in weighted cycles: a run of c cycles adds c * 1024 / weight.

The fair strategy runs the thread whose virtual time is least; EEVDF runs an eligible thread with the earliest virtual deadline. A thread with half the weight gains virtual time twice as fast, so it runs half as much. Two virtual times are compared by the sign of their difference, so the counter can wrap.

The design: `docs/SCHEDULING.md`, "Integer arithmetic and the overflow argument".

Do not use: vruntime, virtual runtime.

### Queue clock

The queue clock is the virtual time of a run queue that never goes back: the least virtual time of its ready threads, as the kernel last saw it.

A thread that wakes or moves is placed against it. The kernel keeps each queued thread within a bound under the clock, so a thread that did not run for a while does not take the processor for a long time when it comes back.

Do not use: min_vruntime.

### Lag

The lag of a thread, under EEVDF, is the average virtual time of its queue minus its own virtual time: what the thread is owed.

A positive lag makes the thread eligible. The lag is kept across a wait, within a bound of two requests (at least one tick), so a thread that slept is neither punished nor paid for its sleep without limit.

Do not use: debt, credit.

### Eligible

A thread is eligible, under EEVDF, when its lag is zero or more.

Only an eligible thread can be picked, when one exists: a thread that ran more than its share waits until the others caught up.

Do not use: runnable (for this).

### Request

A request is the processor time that a thread asks for at each turn under EEVDF, in microseconds: 1 to 100 000, and 0 is 3000.

The request sets the virtual deadline, not the share: a short request makes the thread run sooner and more often, for shorter turns. Its cost, more switches, is in the time of the thread, which its budget pays. A write of the thread schedule changes it while the thread lives: a program only lowers it, and the holder of the right **Schedule** on the machine also raises it.

The design: `docs/SCHEDULING.md`, "Weights and requests: a field at thread creation".

Do not use: slice (for this), quantum.

### Thread schedule

A thread schedule is the weight, the request, the weight limit and the new-thread weight limit of one thread: the values that are set for it for the scheduling strategies (`op.Thread_Schedule`).

A program holds its policy of scheduling as these values: it chooses them, and the kernel applies them at each tick. `Thread_Create` gives the first thread schedule, and thread control reads and writes it. A program and a holder of a thread handle only lower the values; only the holder of the machine handle with **Schedule** and **Inspect** raises them and writes the two limits. Example: `{weight = 256, request = 500}` gives a quarter of the full share, in turns of 500 microseconds. It is not the thread placement.

The design: `docs/SCHEDULING.md`, "The schedule of a live thread".

Do not use: scheduling parameters, scheduling attributes, priority.

### Program schedule

A program schedule is the new-thread weight limit of one program: the value that bounds each thread that any thread of the program creates (`op.Program_Schedule`).

Only the holder of the machine handle with **Schedule** and **Inspect** reads and writes it, with two commands of thread control. One write bounds all the new threads of a program at one moment, which one write for each thread cannot do: a thread can create a thread between the read of the report and its own write. Example: the share policy writes `{new_thread_weight_limit = 32}` to a program of the program weight 1024. It is not a thread schedule, which holds the values of one thread.

The design: `docs/SCHEDULING.md`, "The schedule of a live thread"; `src/md/features/scheduling_policy.md`.

Do not use: program priority, program limit.

### Weight limit

A weight limit is the most that the weight of one thread can be: a number from 1 to 1024, and 1024, the full weight, for a thread that nobody limited.

It makes a lowered weight last across the creation of threads: without it, a program leaves a lowered weight by a new thread. Only a write through the machine handle with **Schedule** and **Inspect** sets it. A new thread gets the new-thread weight limit of its creator as its weight limit. Example: the machine handle writes `{weight_limit = 256}` for a thread; its weight becomes 256, and its own write of 1024 is refused. It is not a share for a program, and not the new-thread weight limit.

The design: `docs/SCHEDULING.md`, "The schedule of a live thread".

Do not use: maximum priority, weight cap, ceiling.

### New-thread weight limit

A new-thread weight limit is the weight limit that one thread, or all the threads of one program, give to each thread that they create: a number from 1 to 1024, and for a thread at most its weight limit.

A thread has one in its thread schedule, a program in its program schedule. A creation takes the smaller of the two, and the new thread gets it as its weight limit and as its own new-thread weight limit. Only the machine handle with **Schedule** and **Inspect** sets it. Example: the share policy writes `{new_thread_weight_limit = 32}` to a program and its one thread; that thread keeps the weight 1024, and each thread that it creates has the weight 32. It is not the weight limit of the thread itself.

The design: `docs/SCHEDULING.md`, "The schedule of a live thread"; `src/md/features/scheduling_policy.md`.

Do not use: child weight, inherited weight, creation weight.

### Program weight

A program weight is a number from 32 to 1024 that the share policy divides between the threads of one program: the part of the processors of that program against the other programs.

The principal sets it for the programs with one name: `scheduler.share("paint", 256)`. A program with no setting has 1024. It is a setting of the program `scheduler`: the kernel knows the weight of each thread only. The least value is 32 because a program has at most 32 threads, so each thread has a weight of 1 or more. It has an effect only while the share policy is on. Example: with the program weight 1024, the 8 threads of a program that compute have the weight 128 each.

The design: `docs/SCHEDULING.md`, "A share for each program".

Do not use: program priority, group weight, program share.

### Share policy

The share policy is the rule of the program `scheduler` that gives each program one program weight, whatever its count of threads: each round, it writes to each thread the program weight divided by the count of the threads of its program that count.

A thread counts when it is ready or ran since the last round. Each program and each of its threads also get a new-thread weight limit, so a thread created between two rounds has a small part. The kernel has no part of the rule. The policy is off until the principal turns it on (`scheduler.policy(1)`). It is not a strategy, which orders the threads of a queue. Example: a program with 8 threads that compute and a program with one have the same weight in all, 1024.

The design: `docs/SCHEDULING.md`, "A share for each program"; `src/md/features/scheduling_policy.md`.

Do not use: group scheduling, fair share scheduler, cgroup.

### Thread placement

A thread placement is the set of the processors that can run one thread, and the limit of that set (`op.Thread_Placement`).

A set has one bit for each processor of the processor report. A thread with no placement can run on every processor. A program and a holder of a thread handle only narrow the set; only the holder of the machine handle with **Schedule** and **Inspect** widens it and writes the limit. New threads get the limit of their creator, so a program stays inside it. The holder uses it to keep two programs off the same processors, against side channels. Example: `{processors = 0b0100}` keeps a thread on the processor 2.

The design: `docs/SCHEDULING.md`, "The placement of a thread".

Do not use: affinity, affinity mask, CPU set, pinning, cpuset.

### Machine number

A machine number is the number that names one thread among all the threads of the machine (`op.Thread_Report.machine_number`).

A thread number names a thread inside its program only. The machine handle with **Schedule** needs a name for any thread: the thread report of `Inspect` gives the machine number of each thread, and thread control takes it for the commands of the thread schedule. Its high bits change for each new thread in the same place of the thread table, so the number of a thread that ended names no later thread, and the kernel gives `Bad_State` for it. It is not a handle: it gives no right.

The design: `docs/SCHEDULING.md`, "The schedule of a live thread".

Do not use: thread identifier, TID, global thread number.

### Virtual deadline

The virtual deadline of a thread, under EEVDF, is its virtual time plus its request in weighted cycles.

Among the eligible threads, the one with the earliest virtual deadline runs. A thread with a short request gets an early deadline, and so a short delay.

Do not use: deadline (alone: the deadline of a wait).

### Wake preemption

A wake preemption is the end of the turn of the thread that runs on a processor because a thread that woke must run first, by the rule of the strategy.

When the processor of the woken thread is the waker's own, the waker ends the turn itself. On another processor, the waker sets a flag of that processor and sends it an interrupt. A thread of another program preempts one processor at most once in each millisecond: without this limit, a program with threads that wake each other makes other programs pay for the interrupts. Round robin has no wake preemption.

The design: `docs/SCHEDULING.md`, "Wake preemption, also on another processor".

Do not use: wakeup preemption, preempt-on-wake.

### Spinner

A spinner is a thread of the program `scheduler` that computes with no end, and counts its work.

The program `scheduler` runs spinners with different weights and requests, and compares their counts under each strategy.

Do not use: busy loop, hog, load generator.

### Serial

A serial is a number of a slot of a kernel table (a thread, a program, a memory object) that changes for each new object in the slot.

A slot serves many objects in time. A path that names a slot across a wait for a lock keeps the serial and checks it after the wait: the slot can hold another object then. The kernel events and the reports give the serial of a program with its slot, so a reader does not mix two programs of one slot. The generation of a handle is the same idea for the handles of one program.

The design: `docs/ARCHITECTURE.md`, "Rules that keep each path correct".

Do not use: generation (for handles only), epoch, version.

### Wait table

The wait table is the threads that wait on words, in buckets chosen by the physical address of the word, each bucket with its wait lock.

A thread registers each word of its wait in the bucket of the word, after it compared the value. A waker changes the word before it enters the kernel, so either the waker finds the entry, or the thread finds the new value.

The design: `docs/ARCHITECTURE.md`, "Rules that keep each path correct".

Do not use: futex hash table.

### Locker

A locker is a program that the program `locks` starts several times, to measure the locks of the kernel.

A locker works only on its own objects, so it waits for another locker only when the kernel makes it wait. The lock counts of the kernel then count what the lockers do.

Do not use: load generator, stress worker.

### Frame cache

The frame cache is the stack of at most 256 free page frames of one processor, in its processor record, with its cache lock.

A page on first use takes its frame from the frame cache of its processor, under the cache lock only. The end of a memory object puts its frames there. The stack takes and gives frames to the frame table by batches of 128, under the frame lock. So most first uses do not take the frame lock that all processors share.

The design: `docs/ARCHITECTURE.md`, "Rules that keep each path correct".

Do not use: per-CPU page list, magazine, pcp list.

### Cache lock

The cache lock is the lock of the frame cache of one processor.

Its processor takes it at each take and each put; another processor takes it only to read or empty the stack. It comes after the frame lock in the lock order.

Do not use: per-CPU lock.

### Lock count

A lock count is what the kernel counts for one kind of lock, on all the processors: the times that a processor took it, and the times that it had to wait for it (`Lock_Count` in the system report).

The program `locks` reads the counts, so a measure shows which lock the work waits for.

Do not use: lock statistics, contention counter.

### Thread area

A thread area is the memory that the kernel makes for one thread in the address space of its program: the thread record, the kernel ring of the thread, and one page with no memory.

Each thread needs a place where the kernel and the program share its state with no call: the thread record, which the program reads, and the kernel ring, through which the thread sends its kernel operations. The areas are at fixed addresses from `THREAD_AREA_BASE`, so a thread finds its own area from its number. The last page has no memory: a write past the ring faults. The budget pays for each area with its thread. A page fault in a thread area is never given to a fault handler: the kernel stops the program.

The design: `docs/ARCHITECTURE.md`, "Kernel systems".

### Kernel event

A kernel event is a fact of the kernel that the kernel writes as an event record when a rule of the event table accepts it: one kernel operation with its duration, a switch of threads, a fault of a program, or a wait for a lock of the kernel.

Kernel events let a program see the work of the kernel as it happens, with no code of the program in the kernel. A rule is data, not code, so its cost has a bound; with no rule, an event point costs one branch. The program reads the records in the event rings with no kernel entry. It needs the right Events on the machine, because the records are a precise clock over the work of other programs.

The design: `docs/ARCHITECTURE.md`, "Kernel events".

Do not use: tracepoint, probe, perf event, eBPF program.

### Event point

An event point is a fixed place in the code of the kernel where a kernel event can be recorded.

The kernel has four: each command of a kernel entry, the switch of threads, a fault of a program, and a lock taken after a wait. With no rule of its kind, an event point costs one load of the observed kinds and one branch. An event point never faults, takes no lock, never waits and uses no address of a program.

Do not use: hook, probe, tracepoint, instrumentation point.

### Observed kinds

The observed kinds are a word of the processor record: the set of the kinds of kernel events that have a rule in the event table now.

An event point reads it first. It is 0 when no event table exists. The kernel changes it only under the control lock, and synchronizes the other processors before it frees an old table.

Do not use: trace mask, enabled events.

### Event rule

An event rule is one record of the event table (`op.Event_Rule`, 64 bytes): a kind of kernel event, a program or every program, a detail to match, a least duration, and "one in N".

The kernel applies the rule; it is data, not code. A rule that names a program needs a program handle with Read; a rule for every program needs only the right Events. "One in N" is a count, not a random choice.

Do not use: filter, predicate, eBPF program.

### Event table

The event table is the rules (at most 16) that one program with the right Events gave to the kernel with `Events_Set`, with the memory object of its event rings.

The machine has one event table at most. The program that gave it owns it: the table ends when that program ends, when it gives the memory 0, or when its last machine handle with Events closes or is revoked. So a revocation takes back what the right gave.

Do not use: trace session, perf session, ftrace instance.

### Event ring

An event ring is the part of the memory object of the event table that belongs to one processor: a head that the kernel writes, a word that the program writes, and the event records.

Only the kernel of that processor writes its records, so it takes no lock. The kernel indexes with its own counts and reads only the word `read` of the program: a false word loses records of that program and nothing else. A full ring drops the record and adds 1 to the lost count.

Do not use: trace buffer, perf ring buffer, per-CPU buffer.

### Event record

An event record is one record of an event ring (`op.Event_Record`, 64 bytes): the cycle counter, the kind, the processor, the program and its serial, the thread, a detail and two values.

For an operation the detail is the operation number and the first value its duration in cycles. For a fault the address of a page fault is given only to a rule that names the program.

Do not use: trace record, sample.

### Lost count

The lost count is the count of the records of one event ring that the kernel did not write because the ring was full.

The kernel never waits for a place and never writes over a record that the program did not read: a full ring loses the record, and the count says so.

Do not use: dropped events, overrun count.

### Performance counter

A performance counter is a register of the processor that counts one event of the processor, such as the cycles, the retired instructions or the cache misses.

The kernel programs four of them (the general counters 0 to 3) for a thread that asks, as the thread counters, and counts in user mode only. The plan of each vendor comes from `CPUID` at boot, each processor takes the trial of their registers at its start, and the line of the boot names the plan and the trial. An event record carries the cycle counter only, not a performance counter.

The design: `docs/ARCHITECTURE.md`, "The counters of a thread".

Do not use: PMC, PMU counter.

### Register trial

A register trial is one access of the kernel to a model-specific register that the processor can refuse with a protection fault, after which the kernel goes on and knows of the refusal.

A hypervisor can list a register in `CPUID` and refuse each access to it, and any other protection fault of the kernel stops the machine. So at the start of each processor, the kernel takes each access of the counter plan once as a register trial. A protection fault at that one instruction goes on at a refusal label, which gives false. A refused register is an outcome: the machine then has no thread counters. Only the kernel makes a register trial; no program asks for one.

The design: `docs/ARCHITECTURE.md`, "The counters of a thread".

Do not use: safe MSR access, rdmsr_safe, exception fixup.

### Thread counters

The thread counters are the counts of four events of the processor for the code of one thread, in user mode only, since its last start (`op.Thread_Counters`): the instructions retired, the cycles, the cache misses and the branch misses.

A developer measures with them the cost of a data layout, and not only its time. The calling thread starts and reads them with thread control, through the machine handle with the right **Counters**, which the root service gives by a start grant. The kernel keeps the counts of a thread when it leaves a processor, so no count of another thread reaches it. A machine with no counters gives `Unsupported`. Example: `system.thread_counters_start(machine)`, a loop, then `system.thread_counters_read(machine)`.

The design: `docs/ARCHITECTURE.md`, "The counters of a thread".

Do not use: perf counters, hardware counters, PMU sample.

### Service

A service is a program that other programs call through rings, and that has no privilege of its own.

A service is not part of the kernel and is not trusted more than another program: it has the handles that the root service gave it. A caller reaches a service through a connection that the root service makes. A service acts only on the handles that the caller sends with the request, never on its own access in the name of the caller. Examples: the storage service, the network service, the manual, the monitor, the compositor.

The design: `docs/ARCHITECTURE.md`, "The whole system".

Do not use: daemon, server, driver.

### Device service

A device service is a service that owns the queues of one device class: block, network card, display, input.

The kernel contains no device code. It maps the registers and the queues of a device into one device service, and turns each interrupt into an event. The service translates between the protocol of the device and the ring of its class; for virtio this translation is thin.

The design: `docs/ARCHITECTURE.md`, "U4. Device services", and `docs/PROPERTIES.md`, "7. No drivers in the kernel, and fixed hardware first".

Do not use: driver.

### Input service

The input service is the device service of the keyboard and the mouse.

It reads the virtio input devices and sends key and pointer events to the compositor, which gives them to the window that has the focus.

Do not use: input driver.

### Root service

The root service is the first program: the kernel gives it every handle that exists at boot, and it gives them out.

The root service is the only program that creates access from nothing: every other handle came from it, directly or through a chain. It checks the boot image against the system description, starts the services with only the handles that each needs, and makes the connections between callers and services. A program asks it for a start or a connection through its root ring; the console has `start`, `stop`, `connect`, `grants` and `revoke`. The root service has no privilege in the kernel: its power is the handles that it holds.

The design: `docs/ARCHITECTURE.md`, "U2. Root service".

Do not use: init, PID 1, system manager.

### Context

The context is the one typed record that a program receives when it starts: 16 handles and 24 values of 64 bits (`op.Context`).

The context replaces `argv`, the environment and inherited files. The index of each handle is its role, which the starter fixes; the system fixes the roles of the log handle and of some values (the seed of the program, the mapped ranges). It holds no text: a program has nothing to parse. A program with an all-zero context has no handle: it can compute and stop, and reach nothing. Example: a call host receives its call ring at role 0.

The design: `docs/MODULE_CONTRACT.md`, "6. The context", and `docs/PROPERTIES.md`, "19. A command is a function: no text between programs".

Do not use: argv, argc, environment, arguments.

### Context slot

A context slot is one place of the context, a handle or a value, with the role that the starter and its program agree on.

The context slots of a program that the root service starts are one table: the `GRANT_` constants of `src/library/support/system/grants.odin`. Two roles share a context slot only when no program holds both. The root service writes each handle with `system.grant_put`, which refuses a context slot that holds a handle already, so a program never starts with a handle lost. A context slot is not a slot of a module, which holds the address of an export.

Example: the handle 7 is the call ring of the private store; the text region of a terminal is the handle 4.

The design: `docs/MODULE_CONTRACT.md`, "6. The context", and `src/md/api/root_ring.md`.

Do not use: argument index, environment slot.

### Kernel

The kernel is the code that runs with processor privilege: it isolates the programs, schedules the processors, owns the handle tables and grants access to memory and devices.

The kernel has five systems: the handle table, memory, the scheduler, rings and wait, and the device grant. It has no file system, no network protocol, no device driver, no loader and no names. It is a module, which the boot program checks against the system description and loads. Its interface is a short list of kernel operations, counted in `docs/PROPERTIES.md`.

The kernel is the control plane: it checks a right once and maps memory, and data then moves between programs with no kernel entry.

The design: `docs/ARCHITECTURE.md`, "Kernel systems", and `docs/PROPERTIES.md`, "1. Small kernel with a small, counted interface".

Do not use: core, supervisor.

### Kernel operation

A kernel operation is one request that a program makes to the kernel: a command record in the kernel ring of its thread.

The kernel has a counted list of operations (`op.Operation`), and only a change of `docs/PROPERTIES.md` changes the count. A thread writes several commands in its kernel ring, then enters the kernel once with `syscall`; the kernel runs them in order and writes one completion record for each: a status, and the results or an error record. The entry can also wait until a wake or a time. A kernel operation needs a handle for each object that it acts on.

The design: `docs/ARCHITECTURE.md`, "K4. Rings and wait", and `docs/PROPERTIES.md`, "1. Small kernel with a small, counted interface".

Do not use: system call, syscall.

### Boot program

The boot program is the UEFI program that checks, measures and loads the system, then starts the kernel.

It holds the kernel module, the boot image and the public key of the principal that signs the system. It verifies the signature of the system description, compares each module and resource with it, asks the firmware to measure the description into the TPM, loads the kernel module, and gives the kernel the memory map, the framebuffer and the trust record in one record. A failed check stops the boot with the file and the two hashes on the screen.

The design: `docs/ARCHITECTURE.md`, "U1. Boot program", and `docs/PROPERTIES.md`, "17. Trusted boot: UEFI program, Secure Boot, TPM".

Do not use: boot loader, bootloader.

### Fixed range

A fixed range is an address and a span of the address space of a program where the system places one mapping that it gives: the settings page, a glyph cache, the date page, the disk program page, the fresh bytes page, the files of a module.

Each fixed range is one member of the enumeration `Fixed_Range` of `src/library/contract/fixed_addresses`, one slot of 1 TiB of the band from `BAND_START`. So no two ranges overlap, and the compiler checks that the band holds every member. The band has 16 slots (`SLOT_COUNT`), and 16 members take them all: a new range needs a larger band first. A mapping that a program places by its own choice is outside the band, from `OWN_CHOICE_START`. `modustool check` refuses an address of the band written another way.

Do not use: well-known address, fixed mapping.

### Mapped ranges

The mapped ranges are the fixed ranges that the starter of a program mapped for it: a set of bits, bit n for the member n of `Fixed_Range`, in the value 20 of its context.

A program reads nothing at a range whose bit is clear (`fixed_addresses.ranges_mapped`).

Do not use: mapping flags, present mask.

## Access

### Handle

A handle is a number that a program holds to name one kernel object with a set of rights: a program can act only on the objects of its handles.

A handle removes ambient access: no global name exists, so a kernel operation names each object that it acts on by a handle. The kernel checks the kind of the object and the rights of the handle: a wrong handle gives `Bad_Handle`, a missing right `No_Right`. A program gets a handle in its context from its starter, as the result of an operation that makes an object, or from another program with `Handle_Give`, which never adds a right. A handle is not a file descriptor: no child inherits it, and it carries rights.

The design: `docs/ARCHITECTURE.md`, "K1. Handle table".

Do not use: file descriptor, capability, token, reference.

### Memory object

A memory object is a set of pages that the kernel names by a handle; programs map it, and two programs that map the same one share its pages.

A memory object is the one form of memory in the system: the memory of a program, a ring, a call region, a framebuffer, the registers of a device. `Memory_Create` makes one, and a budget pays for each page at once, so an access never fails for lack of memory. `Memory_Map` maps it into a program with the rights of the handle. Its pages return to the budget that paid when its last handle or mapping ends. A memory object is not anonymous memory of one process: it has no owner but its handles.

The design: `docs/ARCHITECTURE.md`, "K2. Memory".

Do not use: region, shared memory segment, buffer.

### Page on first use

A page on first use is a page of a memory object that gets its page frame at its first read or write, from a program (a page fault) or from the kernel.

The frame is all zero. The budget paid for the page when the memory object was created, so the kernel keeps a free frame for it at all times: the first use never fails. A page that nobody touches costs no frame and no zeroing. A kernel event `Fault` with the outcome "first use" records it.

Do not use: lazy allocation, demand paging, demand-zero page.

### Uncommitted object

An uncommitted object is a memory object made with the flag `Uncommitted`: its budget pays only its frame list, and each page is paid when it is committed.

An uncommitted object reserves a range of addresses with no memory behind it: its mapping is the reservation. A program commits the pages that it needs with `Memory_Commit`, and gives them back with a decommit. An access to a page that is not committed is a fault: with no fault handler it stops the program with `STOP_CODE_NOT_COMMITTED`; with one, the handler can commit the page and answer Resume. A program builds arenas, stacks that grow and sparse tables this way.

The design: `docs/ARCHITECTURE.md`, "The virtual memory of a program".

Do not use: reserved object, reservation, VirtualAlloc(MEM_RESERVE), mmap(PROT_NONE).

### Committed page

A committed page is a page of a memory object that its budget paid for: it gets a frame at its first use.

Each page of an object that is not uncommitted is committed. A page of an uncommitted object is committed after `Memory_Commit`; the kernel keeps it as one bit in the slot of the page.

The design: `docs/ARCHITECTURE.md`, "The state of a page".

Do not use: committed memory.

### Decommit

A decommit is the act of `Memory_Commit` with the flag `Decommit`: the pages of an uncommitted object are no longer paid.

Their frames and their pages return to the budget of the object at once; the addresses stay reserved, and a page committed again is zero. A decommit needs an object that only this program names, with one mapping at most, so the shoot-down is the one of this program.

The design: `docs/ARCHITECTURE.md`, "Commit and decommit".

Do not use: madvise(DONTNEED), VirtualFree(MEM_DECOMMIT), discard.

### Page protection

A page protection is what a page of a mapping lets a program do: read, read and write, read and execute, or nothing (`No_Access`).

`Memory_Map` sets the protection of a whole mapping from the rights of the handle. `Memory_Protect` changes it for ranges of pages, and can only take away what the mapping has: write and execute together are refused. A guard page, a read-only table after its build, and a collector that traps writes use it.

The design: `docs/ARCHITECTURE.md`, "Protection and the shoot-down".

Do not use: mprotect, page rights.

### Held entry

A held entry is an entry of a page table of a program that a mapping covers: a page of the mapping, present or not, a large page, or an entry that names a table with held entries.

A table with no held entry is freed, and its page returns to the budget that paid for it. So a program that maps and unmaps memory does not keep page tables that no budget sees.

The design: `docs/ARCHITECTURE.md`, "The page tables of a program".

Do not use: used entry, reference of a table.

### Shoot-down

A shoot-down is the step where each other processor that uses the page table of a program forgets its old translations, after the kernel cleared or reduced entries.

The kernel sends `processor_sync` to each processor whose page table is the one of the program; each one reloads its page table at its next kernel entry, its idle wait or its wait for a lock. The operation returns after each of them did, so no thread uses an old entry afterwards. A table of ranges in one command makes one shoot-down for all its ranges.

Do not use: TLB flush, TLB shootdown (for this).

### Large page

A large page is a page of 2 MiB: one entry of the second level of a page table.

Only an object made with `Large_Pages` uses them: it is contiguous, aligned on 2 MiB, and a whole number of large pages. A mapping uses a large page for each 2 MiB that is aligned in it. One entry then covers 512 pages, so random reads over a large object miss the translation cache less.

The design: `docs/ARCHITECTURE.md`, "Large pages".

Do not use: huge page, superpage.

### Fault kind

A fault kind is a processor exception that the kernel can give to a fault handler, named by its vector (`op.Fault_Kind`).

The kinds are divide error, debug, breakpoint, invalid opcode, segment not present, stack fault, general protection, page fault, x87 floating point, alignment check and SIMD floating point. A handler asks for a set of them (`op.Fault_Kinds`); 0 is page faults only. The non-maskable interrupt, the double fault and the machine check are never given: they are not faults of an instruction of a thread.

The design: `docs/ARCHITECTURE.md`, "The fault ring".

Do not use: signal number, exception code, trap number.

### Fault class

A fault class says where a thread continues after a fault kind: a fault did not run its instruction, which runs again; a trap ran it, and the thread continues at the next one.

Debug and breakpoint are traps; the other fault kinds are faults. One debug exception is a fault: an execute breakpoint of the thread, which stops it before its instruction. The class decides the rule of Resume: a trap and a page fault resume by themselves, and another fault resumes only after thread control wrote the registers or the extended state of the thread: without that write, the same instruction faults again with no end.

Do not use: exception class, exception type, abort (for this).

### Fault handler

A fault handler is the thread of a program that `Fault_Handler_Set` named, with the fault kinds that it takes: the faults of these kinds of the other threads of the program become records in its thread record.

A fault handler lets a program decide what a fault means: a guard page, a stack that grows, memory committed at the first touch, the barrier of a collector. The kernel holds no policy. A program has one handler at most. A fault of the handler itself, or of a kind that it did not ask for, stops the program. A fault handler is not a signal handler: the thread that faulted waits, and another thread reads a record and answers with an operation.

The design: `docs/ARCHITECTURE.md`, "The fault ring".

Do not use: signal handler, exception handler, pager (for this).

### Fault ring

The fault ring is the records of the faults of a program that the kernel gives to its fault handler, in place of a stop: a part of the thread record of the handler.

When a thread faults, the kernel writes a fault record, adds 1 to `fault_written`, and wakes the threads that wait on that word; the faulting thread waits, as a held thread. A thread of the program repairs with `Memory_Commit`, `Memory_Protect` or thread control, and answers with `Fault_Answer`: Resume or Stop. A fault that finds the ring full stops the program. The ring needs no new memory: the budget paid for the thread record with the thread.

The design: `docs/ARCHITECTURE.md`, "The fault ring".

Do not use: signal, SIGSEGV handler, userfaultfd, exception port.

### Fault record

A fault record is one record of the fault ring (`op.Fault_Record`, 64 bytes): the number of the faulting thread, the serial of the fault, the address and the kind of access of a page fault, the address where the thread continues, the fault kind and the error code of the processor.

`Fault_Answer` names the thread number and the serial, so an answer for an earlier fault, or for an ended thread whose number serves again, is refused. The serial is a count of the program, so it shows nothing of other programs.

Do not use: siginfo, fault message.

### Thread control

Thread control is the kernel operation `Thread_Control`: it stops a thread, reads and writes its registers and its extended state, and resumes it.

No other operation stops a thread without its end, or gives its registers. A debugger, a collector, a profiler and the program of a guest need both. One operation with a command (`op.Thread_Control_Command`) keeps the count of kernel operations low: `Stop`, `Resume`, the reads and writes of the registers, and commands for the schedule, the placement, the breakpoints, the memory and the thread counters. **Control**, the right to end a thread, does not read or write its registers. It is not ptrace: the rights of a handle decide everything.

The design: `docs/ARCHITECTURE.md`, "The control of a thread".

Do not use: ptrace, debug API, SuspendThread, thread_suspend (for this).

### Stop count

The stop count of a thread is the count of the stops of thread control that hold it: each `Stop` adds 1, each `Resume` takes 1, and the thread runs only at 0.

A stop is a count, not a state, so two holders that each stop a thread each resume it, and neither releases the hold of the other. The stops of the debugger of the program are counted apart, and the end of the debugging takes back those only. `Resume` at 0 gives `Bad_State`. When `Stop` returns, the thread runs no instruction. The count does not change the wait of the thread: its wait ends as before, but the thread does not run until its count is 0.

The design: `docs/ARCHITECTURE.md`, "The control of a thread".

Do not use: suspend count, freeze.

### Held thread

A held thread is a thread that no processor runs and that stays off every processor: its stop count is above 0, or it waits for an answer of the fault ring.

Only a held thread has complete registers in the kernel: the frame of its last kernel entry, and the extended state that the switch of threads saved. A thread that runs has its registers in a processor, where no other thread can read them. So thread control reads and writes the registers of a held thread only, and gives `Bad_State` for any other. A thread that waits for the answer of its fault handler is held too: the handler reads its registers, corrects them and answers.

The design: `docs/ARCHITECTURE.md`, "The control of a thread".

Do not use: stopped thread, suspended thread (for this).

### Register image

A register image is the general registers, the instruction address, the flags and the two selectors of a held thread, as thread control reads and writes them (`op.Thread_Registers`, 176 bytes).

It holds the 16 general registers, `rip`, `rflags`, `cs`, `ss`, and `in_kernel_entry`, which is 1 while the last kernel entry of the thread, a `syscall`, has not returned. The kernel refuses a write whole when a field holds a value that a thread of a program cannot hold, such as a selector of the kernel or an `rip` in the kernel half, and the error record names the refused field. The extended state (vector registers) has its own commands and its own area.

The design: `docs/ARCHITECTURE.md`, "The control of a thread".

Do not use: register context, CONTEXT, user_regs_struct.

### Debugger

A debugger is a program that holds the handle of another program with the right **Debug**, and that made one of its own threads the debug handler of that program.

It receives the debug exceptions and the breakpoints of that program, holds its threads, reads and writes their registers and their breakpoints, and reads the memory of the program. A program has one debugger at a time, and does not debug itself. Two holders have the right Debug: the debugger service and the creator of the program. A debugger that ends never holds and never stops the program. It is not ptrace, and not a developer tool, which never reads the bytes of a program.

The design: `docs/ARCHITECTURE.md`, "The debugger of a program".

Do not use: tracer, attach to a process.

### Debugger service

The debugger service is the program `debugger`: the one debugger of the system for the programs that the root service starts, whose exports are the commands of a debugger.

It asks the root service for the debug access to a program on behalf of one of its callers, becomes the debugger of that program for the kernel, and gives each fact of the debugging as a table: the threads, the registers, the stack, the variables. The console calls its exports under short names (`debug("clock")`, `stack(0)`), and a window or a developer on another machine calls the same exports. It debugs one program at a time, for one caller. It is not the program `debugged`, which tests the contract of the kernel.

The design: `docs/TOOLS.md`, "The debugger".

Do not use: debug server, debug agent, gdbserver, debug stub.

### Debug access

The debug access is the handle of one program with the right **Debug**, which the root service gives to the debugger service on behalf of a caller.

One rule over grants, which names no program, gives it: the caller acts for the principal whose session runs the program, holds each start grant of the program, and no such grant reaches what belongs to that one program, such as a service or a private store. The access is the grant `debug` of the caller: `revoke` ends it. It is not the right Debug of the creator of a program.

Example: `debug("storage")` is refused with `No_Grant`: "the grant Serve of the program refuses it".

The design: `docs/TOOLS.md`, "Who can debug which program".

Do not use: debug permission, ptrace scope, debug privilege.

### Watch

A watch is a data breakpoint that the debugger service sets on 1, 2, 4 or 8 bytes of the debugged program: a thread that writes one of them stops after the instruction of the write.

It takes one of the four breakpoints of the debugger, as an execute breakpoint does. It names its bytes by an address or by the path of a global. It does not see an access that the kernel makes for the program.

Example: `watch("debug_target::rounds", 8)`, then `wait_stop(3000)` gives a row with the kind `watch 0` and the procedure that wrote the count.

The design: `docs/TOOLS.md`, "The exports of the service".

Do not use: watchpoint, data watch, memory breakpoint.

### Value path

A value path is the text that names one value of a debugged program: the name of a variable or of a global, then steps to one of its parts.

A step is `.field` (a field of a record), `[number]` (an element of an array or of a slice, from 0) or `^` (the value that a pointer points to). The name is a variable that is visible at the instruction of a frame, else a global; a global has its package in its name, and then needs no held thread. As in the language, the field of a pointer to a record is the field of the record. A path has 8 steps at most.

Example: `pair.next^.first`, `table[3]`, `debug_target::shape.size`.

The design: `docs/TOOLS.md`, "The variables and the types".

Do not use: expression, watch expression, selector, accessor.

### Debug place

A debug place is the text that names a place of a debugged program for the debugger service: a procedure, a file and a line, an address or a value path of a global.

`break_at` takes a procedure (`debug_target::add_step`) or a file and a line (`src/programs/debug_target/main.odin:82`); `watch` and `memory` take an address (`0x403010`) or a global (`debug_target::rounds`). The service parses it: the console and the window of the debugger pass the text as it is, and compute no address. The window of the debugger has a field for it, with the buttons break at, watch and memory.

It is not a place of the storage service ("Place"), which a connection holds as a number.

Example: `debugger.break_at("src/programs/fault/main.odin:15")`; in the window, `debug_target::rounds 4` then the button watch.

The design: `docs/TOOLS.md`, "The window of the debugger"; `src/md/features/debugger_window.md`.

Do not use: breakpoint location, location spec, address expression.

### Debug handler

A debug handler is the thread of a debugger whose fault ring receives the faults of the kinds Debug and Breakpoint of the debugged program.

The debugger names it with `Fault_Handler_Set` and its program handle with Debug. Those faults go to it before the fault handler of the program itself, and only the debugger answers them (`Fault_Answer` with the same handle, `Resume` only). The ring is in the thread record of the debug handler, so the debugger pays for it. A thread is the debug handler of one program, and it is not the fault handler of its own program: one ring has one role.

The design: `docs/ARCHITECTURE.md`, "The debugger of a program".

Do not use: tracer thread, exception port.

### Breakpoint

A breakpoint is one of the four places where a thread stops with a fault of the kind Debug: an instruction that it reaches, or bytes that it writes or reads.

It is a debug register of the processor, not a byte written in the code: the code of a module is shared by each program that maps it. Only the debugger of its program writes them. An execute breakpoint stops the thread before its instruction; a data breakpoint of 1, 2, 4 or 8 bytes stops it after its access. A breakpoint belongs to one thread, and is never at an address of the kernel. It is not the fault kind `Breakpoint`, which `int3` gives.

The design: `docs/ARCHITECTURE.md`, "The debugger of a program".

Do not use: watchpoint.

### Debug status

The debug status is the error code of a fault record of the kind Debug: it says what made the debug exception.

Bit n is the breakpoint n of the thread (`op.DEBUG_STATUS_BREAKPOINTS`); bit 14 is a single step, one instruction that ran with the trap flag set (`op.DEBUG_STATUS_STEP`); 0 is the instruction `int1` of the program. The kernel reads it from the status register of the processor at each debug exception, clears that register, and keeps only the breakpoints that the thread has on.

The design: `docs/ARCHITECTURE.md`, "The debugger of a program".

Do not use: trap reason, debug cause.

### Reserved page

A reserved page is a page that a budget paid for and that has no page frame yet.

The kernel keeps one free frame for each reserved page, so an access never fails for lack of memory, and the system never takes memory back from a program that paid.

Do not use: overcommit.

### Frame list

A frame list is the record of the page frames of one memory object: in the kernel record of the object for at most 4 pages, else in list pages that the budget pays for.

Each slot of the list is 8 bytes: the frame, and in its low bits the state of the page (committed, deny write, deny execute, no access). 0 is a page with no frame yet.

The design: `docs/ARCHITECTURE.md`, "The state of a page".

Do not use: page list, radix tree.

### Right

A right is one kind of operation that a handle permits on its object.

The rights are Give, Read, Write, Execute, Control, Inspect, Devices, Stop, Spend, Physical, Schedule, Commit, Events, Debug and Counters. Each one means something for each kind of object: Read on a memory object is a mapping that reads, Control on a program starts and stops it. A new object has each right of its kind; `Handle_Give` copies a handle with a part of its rights, and no operation adds a right. Narrow rights let a program give exactly what another needs: Commit pays pages of one object, and nothing more.

The list: `src/library/contract/operation/operation.odin`.

Do not use: permission, privilege, mode.

### Budget

A budget is an object that holds pages, program slots, thread slots and the log records of each second, and has one limit in time, processor time; it pays for each object that a program creates.

A budget makes every cost visible and bounded: `Memory_Create`, `Program_Create` and `Thread_Create` take a budget handle with the right Spend, and the budget pays. When an object ends, what it used returns to the budget that paid. A program moves a part of its budget to a new budget with `Budget_Create`, and gives that one to a child, which can never use more. A budget is not a quota on a user: it is a handle, which a program divides among its children.

The design: `docs/PROPERTIES.md`, "20. No ambient access: the other holes to close".

Do not use: quota, limit, cgroup, job.

### Limit

A limit is a property of a budget for time: the microseconds of processor time that the budget can use in each second.

Time does not return, so it does not move as pages do. A limit holds for the budget and for each budget that came from it: what a thread uses counts in its budget and in each budget above. A new budget has a limit that is not above the limit of the budget that it came from. With the limit 0 a budget has no time: its threads do not run. The log records of each second are an amount, not a limit (`src/md/features/log_side_channels.md`).

Do not use: quota, cap, bandwidth, rate limit.

### Budget request

A budget request is the pages, the programs and the threads that a module asks for its program: the table `Budget` of its file (`module.Budget_Request`).

The source states its stated budget; the build adds the counted parts and writes the table, so the hash of the module names it. It is never a grant: the starter decides, by its least budget and its largest budget, and a budget exception can widen or limit it. A part that is 0, or a file with no table, asks for the least budget. Processor time and log records are not in it: the starter sets them.

The design: `docs/MODULE_CONTRACT.md`, "The budget that a module asks for".

Do not use: budget grant, resource manifest, reservation.

### Stated budget

A stated budget is the part of a budget request that the source of a module states: its working memory, its programs, its threads and the size of its window.

It is one constant of the source, `MODULE_BUDGET`, of the type `system.Stated_Budget`, with the reasons in its comment. It holds only what the tool cannot count. The build adds the counted parts to it and writes the sum as the budget request. A window part names the constant of the size that the program passes to `display.open`, or is a literal.

Example: `MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 3799, programs = 1, threads = 2}`.

The design: `src/md/features/module_budget_request.md`.

Do not use: budget manifest, declared budget.

### Working memory

The working memory is the pages that a program chooses to use: its tables, its caches, the budgets of its children, a stack of another size, its page tables.

It is the part `working_memory_pages` of a stated budget. It holds what no file of the build shows. A table in the data of the module is not working memory: the tool counts it with the module.

Do not use: heap, scratch memory.

### Counted part

A counted part is a part of a budget request that the tool computes from the files of the build: the module pages, the thread pages and the window pages.

The module pages are the memory size of the module and of each module that it imports. The thread pages are a stack and a thread area for each thread: 72 pages for the first one, with the context and the own log ring of the program, and 19 for each other one. The window pages are the two pictures of its window. A counted part changes with a build, with no change of the source.

The design: `src/md/features/module_budget_request.md`; the guide: `docs/MODULE_CONTRACT.md`, "The budget that a module asks for".

Do not use: overhead, estimate, automatic budget.

### Least budget

The least budget is the budget that a starter gives to a module that asks for nothing, and for each part of a budget request that is 0.

The least budget of the root service is 2048 pages, one program and one thread (`LEAST_BUDGET` in `src/programs/root/budgets.odin`). A module whose request is smaller gets its smaller request: the least budget fills a part that the module does not state, it is no floor.

Do not use: default budget, minimum budget.

### Largest budget

The largest budget is the most that a starter gives to one program for each part of a budget request.

A part above it starts the program with the largest budget of that part, and the starter writes one line on the log. The largest budget of the root service is 16384 pages, 8 programs and 32 threads for a program of the boot image (`LARGEST_BUDGET` in `src/programs/root/budgets.odin`). A disk program, and a module of another project, has a smaller one, 8192 pages, one program and 4 threads, and one budget of the root service pays all of them together (`src/library/support/disk_program/budget.odin`).

Do not use: maximum budget, cap, ceiling.

### Budget exception

A budget exception is a row of a starter that gives one program, by its name, another largest budget or other limits in time, with the reason beside it.

A row with a larger amount widens a request, a row with a smaller amount limits it. The root service has two (`budget_exceptions` in `src/programs/root/budgets.odin`). The name of a disk program never selects a row: a name gives nothing.

Do not use: budget override, special case.

### Period

The period is the 100 ms in which the kernel applies the processor limit of a budget.

A thread of a budget that used its part of the period does not run until the next period.

Do not use: window, slice.

### Grant

A grant is the act that gives a handle to a program, and the record of that act.

A grant is the one way that access grows. The root service records each grant that it makes, by the name of the grant and the program, at the start of the program or at a connection. The console shows the grants of a program (`grants("notes")`) and revokes one (`revoke("kernel_events", "machine")`).

A grant is not a permission in a list that a check reads: once given, the handle is the access, and a revocation ends it.

The rules: `docs/PROPERTIES.md`, "20. No ambient access: the other holes to close".

Do not use: permission, authorization, consent.

### Start grant

A start grant is one thing of the list of what the root service gives a program by its name: a service, a private store, a right of the machine.

The root service decides the start grants of a program from its name (`grants_of`) one time, at its start, and keeps them in the program role of the program that runs. Each rule after the start reads them there: the sender of a command of the root ring, the grant of a connection, the debug access. The list and the number of each start grant are a contract (`src/library/contract/start_grant`). Its name has capital letters: `Store`, `Serve`, `System_Part`. A start grant is not a recorded grant, whose name is in lower case: the start grants `Inspect`, `Stop` and `Schedule` are rights of the one recorded grant `machine`.

Example: `debug("notes")` is refused: "the grant Store of the program refuses it".

The design: `docs/TOOLS.md`, "Who can debug which program".

Do not use: capability set, permission, privilege.

### Recorded grant

A recorded grant is a handle, or a connection, that the root service gave a program and can end while the program runs.

The root service records it by the program and by one of ten names in lower case (`Root_Grant` and `root_grant_names` in `src/library/support/system/grants.odin`): `log`, `machine`, `image`, `store`, `debug`. `grants("notes")` in the console shows the recorded grants of a program, and `revoke("notes", "store")` ends one: the kernel ends each handle and each mapping that came from it.

A recorded grant is not a start grant, which says what the root service gives a program by its name, and whose name has capital letters (`Store`).

The design: `docs/ARCHITECTURE.md`, "U2. Root service".

Do not use: permission, access right, token.

### Program role

A program role is what the root service gives a program at its start: its start grants and the terms beside them, kept with the program while it runs.

The root service reads the role of a program of the boot image one time, at its start, from its name (`role_of` in `src/programs/root/roles.odin`): the start grants of `grants_of`, the services that it can connect to, the blocks of its private store, the log with the right Give, the size of its terminal. Each rule after the start reads the role that the program keeps, never its name. A disk program has the role of the row of its nickname in the disk grant table.

Example: the role of `remote` holds Connect, Network, Acts_For_Principal and Remote_Clients, and the nine services that it connects to.

The design: `src/md/api/root_ring.md`.

Do not use: permission set.

### Root ring

The root ring is the ring of a program to the root service: the program writes a command record on it, and the root service answers with a completion.

A program receives a root ring at its start only when its program role holds a start grant that sends a command (Root_Ring, Connect, Principals, Debugger); a disk program has none. The root service reads the kind of each record at one border, which refuses a word that names no command, then checks the sender with the table `ROOT_COMMAND_SENDERS`, then runs the command. The commands and their words are the contract `src/library/contract/root_ring`.

Example: `start("clock")` in the console sends `Root_Command.Start` with the name `clock` on the root ring of the console.

The design: `src/md/api/root_ring.md`.

Do not use: control socket, init channel.

### Nickname

A nickname is the name that the principal gives a disk program: the name of the entry of its module file in the store `programs`.

The principal chooses the nickname, and the file never does. The root service names a disk program by its nickname, and the log writes the hash of the file beside it; its window has the nickname as its title. The store of a disk program is attached to its nickname, so a new version under the same nickname keeps its data. A nickname gives no grant by itself, and it is not the name of a module of the boot image.

Example: `allow("visitor", "store")`, then `start_from_disk("visitor", "")`.

The design: `docs/MODULE_CONTRACT.md`, "The grants of a disk program".

Do not use: alias, pet name, display name.

### Hash prefix

The hash prefix is the first 16 hexadecimal digits of the hash of a module file: the first 8 bytes of the hash, the first byte first.

The menu of the windows and the palette show it faded beside the nickname of a disk program, and the monitor under it, so that a reader tells two files under one nickname apart, and a nickname that only looks like the name of a program of the system from that program: `store_importer 5f0c1a2b9e3d4f60`. The hash prefix is a help, not an identity: the root service checks the whole hash of the command before a start, and its line on the log writes all 64 digits.

Do not use: short hash, abbreviated hash, fingerprint.

### Disk program page

The disk program page is one page that the root service writes and maps read-only, at its fixed range, into each program that it starts with the right Inspect of the machine: one row for each disk program that runs, with its program slot, its program serial, its nickname and the whole hash of its file.

The monitor reads the program slot and the program serial of each program from the kernel, and finds in the page which programs the root service started from a disk, with the hash that it checked: its window shows the hash prefix, and `monitor.programs()` gives the whole hash. A row names a program by its slot and its serial, not by its name. The page gives no handle and no right to act. It is not a list of the programs: the reports of `Inspect` list them.

The design: `docs/MODULE_CONTRACT.md`, "The grants of a disk program".

Do not use: program table, origin page.

### Disk grant table

A disk grant table is the table of the root service that binds each nickname of one principal to the hash of one module file, with the grants of that file.

The root service keeps one disk grant table for each principal. `allow` and `disallow` change the grants of a row, and each start of a disk program reads it: a row with another hash refuses the start, and the grants of the row are the grants of the start. The table persists only under a key of its principal, with a tag of keyed BLAKE2b; a table whose tag fails gives no grant. It is not the grant table of the boot image (`grants_of`).

The design: `docs/MODULE_CONTRACT.md`, "The grants of a disk program".

Do not use: permission table, access list, manifest.

### Guest

A guest is a machine that a program of the system runs on the processor, with the virtualization support of the processor, and with its own kernel and its own programs.

A guest holds only what its program was granted. It is a program that `Program_Create` made and that no thread ran: its addresses are the guest physical addresses, and `Memory_Map` with its handle gives it memory. The program that holds it runs its guest processor with `Guest_Run`, and answers each guest exit. A foreign system (Linux) runs in a guest, and its concepts stay inside it. Built: the AMD form, one guest processor for each guest; the program `guest_demo` runs a guest of seven bytes.

The design: `docs/ARCHITECTURE.md`, "A guest", and `docs/PROPERTIES.md`, "Objective".

Do not use: virtual machine, VM, container.

### Guest processor

A guest processor is the processor of a guest, as the kernel keeps it between two runs: its registers, its segments, its control registers and its extended state.

A thread runs it with `Guest_Run`: during the operation, the thread is the guest processor, and its budget pays the time. The general registers, `rip` and `rflags` go in and out in a `Guest_Registers` record of the caller; the kernel keeps the rest in the control block of the processor. One thread runs a guest processor at a time.

The design: `docs/ARCHITECTURE.md`, "A guest".

Do not use: vCPU, virtual processor.

### Guest exit

A guest exit is the moment when a guest processor stops and the kernel gets the processor back: an instruction that the guest may not run alone, an access to memory that no mapping allows, or an interrupt of the machine.

The kernel handles one exit itself: a page on first use. Each other exit ends `Guest_Run`, and its completion record says what it was (`Guest_Exit_Kind`): a port write with its port and its value, a port read, `hlt`, `cpuid`, an access to memory, an interrupt. The program answers it with a change of the registers record, then runs the guest again.

The design: `docs/ARCHITECTURE.md`, "A guest", section 3.

Do not use: VM exit, world switch.

### Nested page table

A nested page table is the page table that translates the guest physical addresses of a guest to the memory of the machine.

The processor walks it for each access of a guest, after the page table of the guest itself. The nested page table of a guest is the page table of its program: a mapping of a memory object in that program is guest memory, and an unmap or a revocation takes it away.

The design: `docs/ARCHITECTURE.md`, "A guest", section 1.

Do not use: extended page table, EPT, second-level table.

### Driver domain

A driver domain is a guest that owns one device and serves it to the system; it is not built yet.

The device reaches only the memory of that guest, so a driver of another system can serve a device with no access to the rest.

Do not use: passthrough, driver VM.

### Holding

A holding is a handle or a mapping of a program: one thing that the program has of an object.

The kernel keeps the origin of each holding, so that a revocation reaches each handle and each mapping that came from a handle, in any program.

Do not use: reference, capability.

### Origin

The origin of a holding is the handle that it came from.

A handle that `Handle_Give` made came from the handle that was given. A mapping came from the memory handle that was mapped. A holding that the kernel made has no origin. When a handle closes, what came from it comes from its own origin, so the chain stays whole. The kernel keeps the origins in one table under the origin lock.

Do not use: parent, derivation, delegation chain.

### Revocation

A revocation is the act that ends each holding that came from a handle, in one program or in each program (`Handle_Revoke`).

A revocation makes a grant temporary: what a program gave, it can take back, through each chain of gifts. The handle that revokes stays. A program that lost a holding gets an event and cannot refuse; a thread that uses memory that its program lost stops its program on a page fault. A revocation ends holdings, not objects: an object that a program made with a budget handle lives on after the handle is revoked.

Example: `revoke("kernel_events", "machine")` in the console ends the machine handle of `kernel_events`.

The design: `docs/ARCHITECTURE.md`, "Rules that keep each path correct".

Do not use: recall, invalidation.

### Lent handle

A lent handle is a handle that a caller gives to a callee for the time of one call.

The description of an export names the rights that it needs on each Handle parameter. The caller gives the callee a handle that comes from a copy of its own handle with these rights only, and revokes the copy after the call (`system.lend`, `system.lend_end`). The callee proves the handle with `Handle_State` before it uses it. The caller keeps its own handle. A mapping that the export kept for later ends with the revocation, and its next use stops the program of the callee.

The design: `docs/MODULE_CONTRACT.md`, "Records and handles, as implemented".

Do not use: borrowed handle, loan, passed capability, inherited descriptor.

### Ambient access

Ambient access is access that a program has because it runs, and not because it received a handle.

The system has none: a program with no handle can compute and stop, and reach nothing. Each new interface passes one test: "can a program with zero handles use it?" If yes, the interface is a defect.

The rule: `docs/PROPERTIES.md`, "20. No ambient access: the other holes to close".

Do not use: ambient authority.

### Sandbox

A sandbox is the state of every program: it can reach only the objects of its handles.

The sandbox is not a mode that a program enters: it is how each program starts, with the handles of its context only.

The rule: `docs/PROPERTIES.md`, "2. Sandbox by default".

Do not use: jail, container.

### Principal

A principal is a key pair and the root handles that the key unlocks: documents, grant records, settings.

A principal answers "for whom does this run" without users. The kernel does not know it: the answer to "who executes" is always a program with its handles. The root service names each principal by its number, and records the principal of the session of each program that it starts; the storage service gives each principal its own stores. Principal 0 is the machine: the programs of the system belong to it, and it does not see the stores of a named principal.

The design: `docs/PRINCIPALS.md`, "2. Principal 0: the machine".

Do not use: user, account, owner, root, administrator, executor, person, publisher.

### Named principal

A named principal is a principal with a number of 1 or more: a name for display, an Ed25519 key to sign grants, an X25519 key to unlock documents, and a passphrase.

The program `unlock` keeps its record in its own store; the two secret keys are sealed with ChaCha20-Poly1305 under a key that Argon2id derives from the passphrase. `principal_create("name")` in the console makes one.

The design: `docs/PRINCIPALS.md`, "3. A named principal".

Do not use: user account, login.

### Session

A session is the tree of programs that started from the root handles of one principal.

The root service records the principal of each program that it starts: 0 for the programs of the system, the named principal that is unlocked for a program that the desktop starts, and the principal of the asking program for a program that a program starts. The log says it: "root: started notes, in the session of principal 1 "alice"". The principal of the session names the stores of the program. A program of the session with the grant to act for the principal acts for that principal only.

The design: `docs/PRINCIPALS.md`, "5. The session".

Do not use: login, user session.

### Unlock

The unlock is the act that starts the session of a named principal: Argon2id derives a key from its passphrase, and that key opens the seal of its secret keys.

A wrong passphrase gives another key, and the seal does not open: no passphrase and no hash of a passphrase is kept or compared. After the unlock the program `unlock` tells the root service, which starts the session, and gives it the key of the tag of the disk grant table of the principal, which keyed BLAKE2b derives from the unlock key. Then it erases the secret keys.

The design: `docs/PRINCIPALS.md`, "4. The unlock and the lock".

Do not use: login, sign in, authentication.

### Lock of a session

The lock of a session is the act that ends the session of a named principal: each program of the session stops, and an unlock is needed again (`lock()` in the console).

The programs stop; they are not frozen. A program that keeps its state in its store at each change loses nothing. The lock also stops the window of `unlock` that the session asked for (a change of the passphrase, a machine passphrase, a seal of the machine key), so nobody at the locked machine reads its recovery key; such a window writes nothing before Enter, so the stop loses no recovery key (`PRINCIPALS.md`, "4. The unlock and the lock"). The lock of a session is not a lock of memory.

Do not use: log out, sign out.

### Passphrase

A passphrase is the text that derives the key of the seal of a named principal: 8 to 128 bytes of UTF-8 with no control character.

It is typed in the window of `unlock` only, shown as dots, and kept nowhere. It is never a text of the console, which keeps each line in its history. When the TPM seals the keys of the principal, the passphrase also gives the authorization value of the sealed object, so the TPM counts each wrong one.

The design: `docs/PRINCIPALS.md`, "The passphrase".

Do not use: password, PIN.

### Change of the passphrase

A change of the passphrase is the act by which a named principal, in its session, proves its current passphrase in the window of `unlock` and has its keys sealed again under a new passphrase, or under a new recovery key.

A console of the session asks with `passphrase_change()` or `recovery_key_change()`; the console of the machine cannot. The current passphrase opens the keys as an unlock does. The keys themselves do not change. After the write, `unlock` erases the versions of the file, so the old passphrase and the old recovery key open nothing that the storage service reads on the disk; a copy of the disk made before the change still opens with them. A lost passphrase is not changed this way: the recovery key replaces it.

The design: `docs/PRINCIPALS.md`, "A change of the passphrase".

Do not use: password reset, password change.

### Machine passphrase

A machine passphrase is an optional passphrase of principal 0, the machine, that guards the machine key.

It has the rules of a passphrase, and it is typed in the window of `unlock` only: two times after `machine_passphrase()` in the console, then at each start of the machine. It opens no session: principal 0 stays the machine. With a machine passphrase, the disk grant table of principal 0 persists, and until the passphrase is typed the disk programs of principal 0 start with no grant. With the TPM service and Secure Boot on, the TPM seals the machine key with it and counts each wrong one.

The design: `docs/PRINCIPALS.md`, "Principal 0 and its machine passphrase".

Do not use: admin password, root password, master password.

### Machine key

The machine key is a key of 32 random bytes of principal 0 that signs its disk grant table.

The record of the machine key holds it in one of three forms: sealed under the machine passphrase alone (`MACHINEK`), sealed by the TPM with the machine passphrase (`MACHINEP`), or sealed by the TPM with no passphrase (`MACHINET`, after `machine_seal()`). `unlock` opens it, and gives the root service only the key of the tag of the table, which keyed BLAKE2b derives from the machine key: the root service cannot open a seal with it. The machine key is not the attestation key of the TPM.

The design: `docs/PRINCIPALS.md`, "Principal 0 and its machine passphrase".

Do not use: master key, device key.

### Acts for the principal

Acts for the principal is a grant of the root service (`acts_for_principal`): in each service that the program is connected to, it sees what the service holds for all callers, for the principal of its session.

Without it, a caller of a service sees only its own data. The console and the remote service have it; `revoke("remote", "acts_for_principal")` ends it, and the next call is refused. The grant travels in bit 63 of the grant of each connection (`isolated.CALLER_ACTS_FOR_PRINCIPAL`). A connection of the remote service acts for the principal of the client key that it is for, not for the session of the remote service.

The design: `docs/PRINCIPALS.md`, "5. The session".

Do not use: superuser, privileged, person.

### Client key

A client key is the Ed25519 public key that a client of the remote service proves in the QUIC handshake, and that a principal allows so that each call of that client acts for it.

The client sends it as a raw public key, with a CertificateVerify signed by its private key (mutual TLS 1.3). A principal allows it from a console that acts for it, with `remote_allow(key)`, and ends the grant with `remote_disallow(key)`. One key belongs to one principal, and the disk grant table of the principal keeps it across a restart. A key that no principal allowed is refused in the handshake, before any call. It is not the key of the server of `remote`.

The design: `docs/PRINCIPALS.md`, "The client keys of remote".

Do not use: client certificate, API key.

### Client table

The client table is the page in which the root service keeps each client key that a principal allowed, with that principal and a serial; the remote service reads it and never writes it.

Each row is one grant (`remote.Client`), and its serial names that grant: a new row, a lock and an unlock of the session of its principal each give a new serial, and the connections that the root service made for the row end when the serial changes. The remote service maps the table with the right Read only, by its start grant `Remote_Clients`, and waits on its version. The table lasts until the machine stops; the disk grant table of each principal keeps its keys across a restart.

The design: `docs/PRINCIPALS.md`, "The client keys of remote".

Do not use: allow list, access list, key ring.

### Input

Input is the keys and the pointer, as the system receives them.

A text that describes an act at the desktop names the input or the act ("Space is pressed"), not who acts: the system knows programs and principals, not people.

Do not use: user, person.

## Communication

### Ring

A ring is a pair of queues of fixed records in shared memory, between two programs or between a program and the kernel: one queue carries command records, the other carries completion records.

A ring is the one way that two programs communicate, and the base interface of the kernel. Each queue has one writer and one reader, so no queue operation takes a lock or enters the kernel; a side that must wait uses the word wait. The receiver checks each record as hostile data. Examples: the kernel ring of each thread, the call ring of a call host, the terminal ring. A ring is not a pipe or a socket: it carries typed records, not a stream of bytes.

The design: `docs/ARCHITECTURE.md`, "K4. Rings and wait".

Do not use: pipe, socket, channel, port, message queue.

### Capacity

The capacity of a ring is the count of records of each of its queues: a power of two, fixed when the ring is created.

The capacity comes from the size of the memory of the ring: a ring of 1 + capacity / 32 pages, from 32 to 65536 records. It is not written in the shared memory, so the other side cannot lie about it. Choose it for the largest burst of the writer: a full queue slows the writer to the speed of the reader.

Do not use: buffer size, queue depth, backlog.

### Terminal

A terminal is a program that shows the text records of one other program, keeps its lines, and gives its keys to that program.

The root service starts a program and its terminal, and gives the two a terminal ring and a text region. The terminal starts no program. It reads records as fast as the program writes them and draws at the rate of the screen, so the display does not slow the program. The kernel has no concept of a terminal.

A terminal is not a TTY: no escape sequence and no line discipline exist. The program edits its own line and sends records with a kind and typed fields.

The contract: `src/library/support/terminal/terminal.odin`.

Do not use: TTY, pty, terminal emulator, standard output, standard input.

### Shared queue

A shared queue is one queue of records in shared memory that several threads write and several threads read, with no lock.

Each record has a turn word that says whose turn it is on it. A writer takes a count with one compare-and-exchange, writes the record, then changes the turn word; a reader does the same. So two writers never have the same count, and a reader never reads a record before its writer completed it. Use a shared queue when several threads take work from one place; use a ring for one writer and one reader.

The contract: `src/library/contract/ring/shared.odin`.

Do not use: MPMC queue, channel, work queue, mailbox.

### Event

An event is a count in memory that several threads wait on (`system.Event`): a thread adds 1 to it and wakes all the threads that wait.

A waiter reads the count, reads the state that the event changes, then waits while the count holds the value that it read: an event between the read and the wait ends the wait at once. The zero value is an event that never happened. An event in shared memory works between programs.

Do not use: condition variable, semaphore, signal, barrier.

### Source library

A source library is a named folder of source packages that a module compiles in.

An import of the source names the library and the package: `modus:contract/ring`. The modules have one source library, `modus`, in the folder `src/library`. It has two parts: `contract` (what two parties agree on) and `support` (what a program compiles in to use the contracts). A program of the system and a program outside the repository import a package with the same line. The kernel has a second source library of its own, `kernel`, in the folder `src/kernel`, for its kernel parts: `kernel:iommu`. A source library is not a module: it has no file and no hash of its own, and it is not an edge of the module graph.

The design: `docs/MODULE_CONTRACT.md`, "The source library of a module".

Do not use: collection, SDK, libc, static library.

### Private part

A private part is a package of the source library that one module alone compiles in, with its host tests.

A private part holds the logic of one module that has host tests: a module package has none, because a test of it builds the whole program for the host. Its folder is `src/library/private/<module>/<part>`, and its import line names the module: `modus:private/storage/storage_tree`. The tool refuses an import of it from another module, and refuses a support package that only one module reaches. The tool reads some private parts too, as a disk image of the storage service; that does not make them shared. The move of the packages of the library that one module reaches is planned work of `ROADMAP.md`.

The design: `src/md/infrastructure/repository_layout.md`.

Do not use: internal package, helper package, program package.

### Kernel part

A kernel part is a pure package in a folder under `src/kernel`, which the kernel alone compiles in, with its host tests.

A kernel part is imported through a second source library, `kernel`: `kernel:iommu`. Only the compile of the kernel, the host tests of its parts and the tool get that source library, so the compiler refuses the import in a module, and the tool refuses it in each other file of `src/`. A kernel part is pure: the state of the kernel stays in the package of the kernel, and a host test runs each procedure with no machine. The tool checks it: each package variable of a kernel part is `@(rodata)`, no variable is `@(static)` or `@(thread_local)`, and a kernel part holds no foreign block, no asm and no intrinsic that reads the machine. A format that only the kernel reads, such as an ACPI table, is a kernel part and not a contract. The kernel parts are `iommu`, `acpi_processors`, `debug_exception` and `processor_counters`.

The design: `src/md/infrastructure/repository_layout.md`.

Do not use: kernel module (a module is a file), kernel library, subsystem.

### Module group

A module group is the folder of `src/modules` that holds the modules of one use: `system`, `libraries`, `demonstrations` or `tests`.

The group of a module is the folder of its source, and the tool reads it from there. It is not a second format: the module file holds no group, and the loader and the root service never read it. A release leaves out the group `tests`. The one folder of modules is planned work of `ROADMAP.md`; today the programs are in `src/programs` and the other modules in `src/modules`.

The design: `src/md/infrastructure/repository_layout.md`.

Do not use: role (the term is program role, the grants of a program), category, kind of module.

### Test module

A test module is a module that only a machine test starts or imports, and that is wrong on purpose or shows nothing of its own.

Examples: `test_callee` and `test_caller`, the loader test of an import; `hostile_exports`, exports that are wrong on purpose; `lonely`, a module whose import is not in the boot image; `debug_target`, the program that the test of the debugger debugs. A test module is in the module group `tests`. A program that shows a property to a principal is a demonstration, not a test module, even when a machine test starts it.

The design: `src/md/infrastructure/repository_layout.md`.

Do not use: fixture (a fixture is the small tree of a host test), mock, stub.

### Outside module

An outside module is a module whose source is in a folder outside the repository of the system.

Its developer writes one Odin package that imports the packages of the system from the source library, and a module build file. The command `modustool module-build` builds it with the two steps of a module of the system, and writes the module file and the debug object in a folder of the developer. An outside module is a module as each other: one file, named by its hash, with described exports. The tool does not yet put one in a boot image.

The design: `docs/TOOLS.md`, "A module from a source outside the repository".

Do not use: third-party module, external module, plugin.

### Module build file

A module build file is the file `module.txt` in the folder of an outside module, which holds the fields of a row of the module table.

Each line is `key: value`. The key `name` is the name of the module. The keys `imports`, `defines` and `library` are the imports by name, the settings of the compiler and whether the module is a library module; each can be absent. The tool refuses a line that it does not know. A module of the system has no module build file: its row is in the module table of the tool.

The design: `docs/TOOLS.md`, "A module from a source outside the repository".

Do not use: manifest, build script, project file.

### Documentation

The documentation of a module is the text that the module carries in its file for a reader: one line that says what the module is, a text for the module, and a text for each export.

The build tool takes it from the comments of the source. It is part of the file, so it has the hash of the module: a text cannot describe another version of the code. With the description of each export, it is all that a reader needs to use the module: `help()` in the console and the pages of the site show it. A documentation text keeps the Markdown of its comment, which the program `manual` reads.

The design: `docs/MODULE_CONTRACT.md`, "1. The module file".

Do not use: man page, help file, docstring, README.

### Time page

The time page is one page that the kernel writes and that each program can only read, at a fixed address (`TIME_ADDRESS`).

It holds the milliseconds since boot, the frequency of the cycle counter and the cycle counter at the time 0. A program reads the time with one load from memory, with no kernel entry; a finer time comes from the cycle counter.

Do not use: vDSO, vsyscall, clock system call.

### Real-time clock

The real-time clock is the clock of the machine that keeps the date when the machine is off.

On a PC it is the CMOS clock, at the ports 0x70 and 0x71. The program `date` reads it at its start and each 10 s, and writes the date page.

Do not use: RTC (in text), hardware clock, BIOS clock.

### Date

A date is a count of milliseconds since 1970-01-01 00:00:00 UTC.

Leap seconds are not counted: a day has 86400 seconds.

Do not use: timestamp, wall clock, epoch time, Unix time (in text).

### Date page

The date page is one page that the root service creates and maps read-only into each program that it starts, at its fixed range.

The program `date` writes there the date of the time 0 of the system. So a program reads the date with no kernel entry: that date plus the milliseconds of the time page. The page also holds the time zone, which the program `date` copies from the settings page, so the local time is in one page.

Do not use: wall-clock page, vDSO, clock page.

### Time zone

The time zone is the fixed offset from UTC, in minutes, that the principal chooses with the setting `time_zone`: the local time is the date of UTC and this offset.

Its text is the form of ISO 8601: `+08:00`, `-03:30`. It goes from `-12:00` to `+14:00` by quarters of an hour, and `+00:00`, UTC, is the default. It has no summer time. The program `settings` writes it on the settings page; the program `date` copies it into the date page. The bar shows the local time, and the date of the system stays in UTC. It is not a named zone with rules (`Europe/Paris`): the system has no tz database.

The design: `src/md/features/time_zone.md`.

Do not use: timezone (one word), TZ, locale, UTC offset (for the setting).

### Back pressure

Back pressure is the rule of a queue whose writer waits while the queue is full, so that no record is lost.

It is the first form of the rule of the path of a key: the input service takes no byte of the keyboard from the controller while the input ring has no room, and the console takes no key from the terminal ring while 128 keys wait for the end of a line. The writer waits with `system.wait_room`. A writer that cannot wait (the compositor for a window, the terminal for its program) uses the second form: a stated capacity, and a loss period for each refusal.

The design: `docs/ARCHITECTURE.md`, "The path of a key".

Do not use: writer stall, push back.

### Loss period

A loss period is the time from the first record that a full queue refuses to the moment when the queue takes a record again.

A writer that cannot wait counts each record that it loses, and writes two lines in the log for one period: one when the loss begins, one with the count when it ends. It writes no line for each record: a queue that refuses 1000 keys must not fill the log. The compositor has one for each window, the terminal one for its program, the console one for the keys that wait during a line. The code: `key_path.Loss_Period` (`src/library/support/key_path`). The design: `ARCHITECTURE.md`, "The path of a key".

Do not use: drop window, loss burst.

### Terminal ring

The terminal ring is the ring between a program and its terminal.

In the command queue, a record from the program has a kind (text, status, clear, edit line, hint line, completion list, runs of code), a count of bytes in the text region and a style; it has no place on the screen. In the completion queue, a record from the terminal is a key record. The queue of keys holds 4096 keys: the keys typed ahead. The terminal never waits for a program: when the queue is full, a new key is lost and counted in a loss period. A record whose kind names no record is refused and counted: the terminal writes one line at the first one, and the count when the program stops. The test program `hostile_terminal` writes three such records in the machine test.

The contract: `src/library/support/terminal/terminal.odin`.

Do not use: escape sequence, control character, stream.

### Key record

A key record is a record from a terminal to its program: the code of one key that was pressed, its character, and the modifiers that were held (Shift, Control).

The character is a code point, or 0 for a key with no character: é of the layout of France is 233. A program that keeps the character writes its UTF-8. The program decides what a key does. The terminal keeps Page Up and Page Down for its own view.

Do not use: standard input, character device, raw mode, cooked mode.

### Edit line

The edit line is the one line that a program changes: its line of input with a cursor, or a line that says what the program does now.

The program sends the text and the place of the cursor; the terminal draws it after the last line. The program owns the editing, so the terminal needs no knowledge of a line of input.

Do not use: line discipline, readline, cursor addressing, prompt.

### Line editor

The line editor is the procedures of `src/library/support/line_editor` that change an edit line with keys: the caret, a character at the caret, Backspace, Delete.

They have no state of their own: the line is a record of the program. The line is UTF-8, and each key moves the caret over a whole character, or inserts or removes a whole character. The caret is a place in bytes, always before a whole character.

Do not use: readline, line discipline.

### Hint line

A hint line is one dim line that a program shows under its edit line: the signature of the call at the caret, or how to use the list that is open.

It has a long form and a short form; the terminal shows the long one when it fits in its columns. The terminal draws it in the free row. A new one replaces the one before.

The design: `docs/CONSOLE.md`, "5. Who draws the list, and the line under the edit line".

Do not use: tooltip, status (for this), echo area.

### Free row

The free row is the row of the view of a terminal under the edit line, which the terminal keeps free at all times.

The hint line is drawn in it, so the text does not move when a hint comes or goes.

Do not use: spacer, padding line.

### Completion list

A completion list is the names that can take the place of the name at the caret, best first, with one chosen row.

The program gives the rows, at most 8 at a time; its terminal draws them over its text, at the edit line. In the console the fuzzy match orders the names. With more names than rows the list has a scroll bar, which takes the pointer: the terminal tells the program the first row that the pointer asks for, and the program moves its view and its chosen row.

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

### Line history

The line history is the lines that were entered in the console, in a ring of bytes in its memory, the newest first.

The console keeps it in its store, so it survives a stop of the console.

The design: `docs/CONSOLE.md`, "6. The line history across a stop".

Do not use: history (alone), scrollback, command log.

### Line history file

The line history file is the line history as bytes, kept in the history store: a version, the lines, and a BLAKE3 hash (`src/library/support/line_editor/history_file.odin`).

A file that fails a check gives an empty history: a damaged file never stops the console.

Do not use: history dump, .bash_history.

### History search

The history search is the completion list over the line history: Control-R opens it, and the fuzzy match orders the lines.

The age of a line is its tie order: for equal scores the newest line comes first. Enter puts the chosen line in the edit line, where it can be changed before it runs.

The design: `docs/CONSOLE.md`, "1. The keys".

Do not use: reverse-i-search, incremental search.

### Text region

The text region is the shared memory beside a terminal ring where the program writes the bytes of its text, in order (4 MiB).

A record gives only a count of bytes: the terminal keeps its own place, so a program cannot make the terminal read another place. The terminal has the right Read only on it.

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

The program gives the meaning; the terminal chooses the color of each tone, so one table changes the colors of every program.

Do not use: color code, severity (for text).

### Token

A token is the smallest part of a line of the console: a name, a number, a text, an operator, the arrow `->`, or one byte of no other token.

One scanner (`src/library/support/console_language`) gives them to the parser of the console and to its colors, so the colors never disagree with the parser.

Do not use: lexeme, word (for this).

### Code kind

A code kind is what a part of a line of the console or of a row of its list is: a function, a module, a type, a parameter, a variable, a number, a text, an unfinished text, an operator, the arrow, words that are not code, or unknown.

A program sends kinds, not colors; the terminal maps each kind to a code class (`src/library/support/terminal/code_runs.odin`).

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

A status is one line that a program replaces at any time, with a value and a total.

The terminal shows it apart from the lines: no line is drawn again. A program shows its progress this way, with no carriage return in a stream.

Do not use: progress bar hack, carriage return.

### Call form

The call form is where a call of an export puts each of its arguments and finds each result: the C convention of the machine, in a subset that every compiler gives.

On x86-64 an export takes up to 12 integer arguments (`module.PARAMETER_CAPACITY`): the first 6 in registers, the others on the stack, one word of 8 bytes each. The results are in `rax` and `rdx`. A record, a slice and a table are never passed by value: the argument is an address. The one routine `export_call` calls each export from an array of values. It is not the calling convention of a language: an Odin procedure of the convention `"odin"` passes one more argument, its context.

The design: `docs/MODULE_CONTRACT.md`, "4. The call form".

Do not use: ABI (for this), calling sequence.

### Direct call

A direct call is a call of an export of a module that is in the address space of the caller.

The arguments are where the call form puts them: up to 12 integers, 6 in registers and the others on the stack, and 8 floats; a record, a text or a table goes as the address of memory of the caller. A direct call costs what a call of a function costs: a call through a slot of an import took 3.5 ns. The callee runs with all the access of the caller, so a direct call is for a module that the caller trusts.

The design: `docs/MODULE_CONTRACT.md`, "4. The call form".

Do not use: in-process call, local call.

### Isolated call

An isolated call is a call of an export of a module that runs in another program: the arguments travel in a ring.

An isolated call lets a program call a module that it does not trust: the module runs in a call host, or in a service, with no handle but those that the call lends. The caller writes the argument record in the call region and a command record in the call ring; the receiver copies the record once, checks it, and calls the export. A fault of the module stops the call host only. An isolated call costs a wake of the other program and its answer.

The design: `docs/MODULE_CONTRACT.md`, "The isolated call, as implemented".

Do not use: remote call, RPC, IPC call.

### Record description

A record description is the part of the description of a module that gives the name, the size and the fields of one record that an export receives or gives.

A field is an Integer (1, 2, 4 or 8 bytes), a Handle (4 bytes, with the rights that the export needs), or a Text of a fixed size. A record has 256 bytes at most and holds values only, never an address. Two record descriptions that are equal name the same record, in one module or in two: the check of a replacement and the console compare them field by field.

The design: `docs/MODULE_CONTRACT.md`, "Records and handles, as implemented".

Do not use: struct type, schema, class.

### Call host

A call host is the program that loads one module and executes the isolated calls of its exports (`src/programs/host`).

The caller starts one call host for each module. The call host has no handle but its call ring, its call region, its budget and the log. It checks the file of the module, loads it, and answers a first completion: Ok, or `Load_Failed` with its load error. A call has no time limit: the caller ends it by closing the program handle, and the next call starts a new call host. Example: `isolate("sample")` in the console.

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

### Argument record

An argument record is the record that holds the arguments of one isolated call: one field for each parameter, in order.

It is derived from the description of the export: an Integer is 8 bytes, a Text is `{offset, count}` in the call region, a table is 32 bytes. Nobody writes a second encoding.

The design: `docs/MODULE_CONTRACT.md`, "The isolated call, as implemented".

Do not use: message, payload, marshalled arguments.

### Kernel ring

A kernel ring is the ring between one thread and the kernel: each kernel operation is a command record in it.

Each thread has its own kernel ring, one page after its thread record, with 32 places. A thread writes several commands, then enters the kernel once with `syscall`; the kernel runs them in order and writes one completion record for each. So a batch of operations costs one entry.

The design: `docs/ARCHITECTURE.md`, "K4. Rings and wait".

Do not use: system call table.

### Record

A record is a block of bytes of a fixed layout with typed fields, in which all-zero bytes are a valid value.

All data between programs, and between a program and the kernel, is records: a ring record, a context, an error record, a row of a table. A record holds no address that the other side must follow, and no text that it must parse. A new field at the end is zero for an old writer.

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

The kernel maps it into one program, and is then off the path of the data: the program and the device exchange records with no kernel entry.

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

A short name of an export is a built-in name of the console that calls one export of a service: `programs()` calls `monitor.programs()`.

The fact that the command gives is a fact of the service, and the console holds no copy of it. The command connects to the service when the console has no connection to it yet, then calls the export through the connection, as any call of `service.export`. When the service does not run, the line fails with the error of the connection. It is not a second implementation of the command in the console.

The design: `docs/CONSOLE.md`, "The built-in commands and the services".

Do not use: alias, shortcut, wrapper command.

## Devices

### Physical address

A physical address is the number that the memory and the devices use for a byte of memory, before the page tables translate anything.

A program sees only virtual addresses. A device sees only physical addresses: it reads and writes memory by itself, with no page table between. So only a device service needs one. It calls `Memory_Physical` with the machine handle and the right **Physical**, which the root service gives to device services only. Example: the block service gives its device the physical address of the data region of its client. A physical address is not a handle: a program that knows one cannot map it.

The design: `docs/ARCHITECTURE.md`, "K5. Device grant and interrupts".

Do not use: real address, bus address.

### Device memory

Device memory is a memory object over the registers of a device, at physical addresses that are not memory of the kernel, and mapped with no cache.

Device memory gives a device service the registers of its device as an ordinary memory object, with a handle and its rights. The root service makes one with `Device_Create`, the kind `Memory`, for each base address register of the device. The kernel refuses a range that meets free or loaded memory. A mapping uses no cache, because a read of a register has an effect. Device memory is not the memory where a device moves data, such as the data region. It pays nothing from a budget.

The design: `docs/ARCHITECTURE.md`, "K5. Device grant and interrupts".

Do not use: MMIO region, BAR mapping.

### Message interrupt

A message interrupt is an interrupt that a device sends as a write of a value to an address of the interrupt controller of a processor (MSI-X).

The old interrupt lines are few and shared; a message interrupt belongs to one device. The root service makes one with `Device_Create`, the kind `Message`, writes it in the table of the device, and gives the handle to the device service. When the device writes the value, the kernel counts it and wakes the threads of the holder. The service reads the count with `Interrupt_Read`, then reads its queues. A message interrupt is not a vector: a program never sees the vector.

The design: `docs/ARCHITECTURE.md`, "K5. Device grant and interrupts".

Do not use: MSI, vector.

### IOMMU

The IOMMU is the unit of the machine that translates each address that a device gives before the access reaches memory, through tables that the kernel writes.

Without an IOMMU, a device service with a fault can make its device write any page of the machine. With it, the kernel maps in the tables of a device only the pages that its service declared with `Memory_Physical`. The kernel drives the units of Intel (VT-d) and of AMD (AMD-Vi), with one boot image for both. A machine with no IOMMU writes one line at its start and runs with no such isolation. The IOMMU is not the page table of a program: a program never sees it.

The design: `src/md/infrastructure/iommu.md`.

Do not use: DMA remapper, SMMU.

### Remapping unit

A remapping unit is one part of the IOMMU, with its own registers and tables, that translates the accesses of the devices that the table DMAR or IVRS gives it.

A machine of Intel has several units: often one for its graphics device and one that covers every other device. The kernel gives each device the unit that names it, else the unit that covers every device. The domain, the invalidations and the DMA faults of the device are on that unit. A device that no unit covers reaches all memory, and `Device_Create` of its registers writes one line that says so. A remapping unit is not a device domain: one unit holds the domains of many devices.

The design: `src/md/infrastructure/iommu.md`, "The hardware".

Do not use: DRHD, IOMMU unit.

### Device domain

A device domain is the memory that one device can reach through the IOMMU: the pages that its service declared, at their device addresses.

The kernel keeps one domain for each device that has a service: an entry for its requester on its remapping unit, and page tables of the declared pages. The first program that declares memory to the device owns the domain and pays for its tables. The device writes a page only while the service holds a handle with **Write**. A device with no service has an empty domain, which refuses each access. Example: the device of the data disk reaches its queue and the data region of the storage service only.

The design: `src/md/infrastructure/iommu.md`, "Mechanism in the kernel, policy outside".

Do not use: IOMMU domain, DMA window.

### Shared requester

A shared requester is the one requester that a conventional bridge of PCI gives the accesses of each device behind it.

The IOMMU sees only the shared requester, so the devices behind the bridge have one device domain. The kernel makes it only for a service that holds the registers of each of those devices; else the declaration gives `Bad_State`, with one line. So the root service gives all of them to one service. Example: in the part `iommu_amd` of the machine test, the disk of the measures and an entropy device share the requester 0:1C.0. A device of PCI Express behind a root port keeps its own requester.

The design: `src/md/infrastructure/iommu.md`, "The domain of a conventional bridge".

Do not use: alias requester, DMA alias.

### Device address

A device address is the address that a device gives for a page of a memory object, which the IOMMU translates to the frame of that page.

`Memory_Physical` gives it. For a contiguous object, it is the physical address of the page, with and without an IOMMU. For an object that is not contiguous, on a machine with an IOMMU, the kernel gives the object a device window: the device sees one run, and the service gives one address. Example: the network device reads the data of a send from the datagram region of an endpoint through its device window. A device address is not a physical address: only the IOMMU knows the frame behind a device window.

The design: `src/md/infrastructure/iommu.md`, "Device addresses".

Do not use: bus address, IOVA, DMA address.

### Device window

A device window is the run of device addresses where the IOMMU shows the pages of a memory object that is not contiguous, in their order.

`Memory_Physical` from a device service gives an object its window, and gives each page its frame until the object ends. The slot of the object fixes the window, so it is the same in every device domain. A large object, an `Uncommitted` object, or an object for a unit with too few address bits gets no window. Example: a datagram region of 128 pages anywhere in memory is one run of 512 KiB for the network device. A device window is not a mapping of a program: no program reads through it.

The design: `src/md/infrastructure/iommu.md`, "Device addresses".

Do not use: aperture.

### Reserved memory range

A reserved memory range is memory that the firmware keeps for a device, listed in the table DMAR or IVRS, which the device keeps reading and writing after the start.

The firmware uses one, for example, to emulate a USB keyboard, or as the memory of an integrated graphics device. The kernel maps each range at its own address in a standing domain of each device that the range names, before translation is on, so the device keeps working. The domain of a service of that device maps the ranges too. `Device_Create` refuses a range that meets one, and no declaration maps it: no program gets it. A reserved memory range is not device memory: it is memory, not registers.

The design: `src/md/infrastructure/iommu.md`, "Reserved memory ranges".

Do not use: RMRR.

### DMA fault

A DMA fault is an access of a device to an address that its device domain does not map, which the IOMMU refuses.

The unit records the requester, the page and the kind of access, and sends its fault event to the first processor. The kernel writes one line with the device, its service, the address and the count of faults of that device. After the first 4 faults of a device, it writes a line only at each power of two. A DMA fault stops no program, and the page does not change. It is not a page fault: no thread caused it. It is not a refused interrupt either, which has its own count.

The design: `src/md/infrastructure/iommu.md`, "A DMA fault".

Do not use: IOMMU fault, DMAR fault.

### Queue of invalidations

The queue of invalidations is a ring of descriptors in memory of the kernel through which the kernel tells a remapping unit to forget the entries that it keeps.

A unit keeps the entries that it read. When the kernel clears or changes one, it writes descriptors that name the domain or the interrupt entry, then a wait descriptor, and waits until the unit writes the number of the wait. The unit then forgot each entry and drained the accesses in flight, so a page can become free. A unit that does not reach the wait in one second stops the machine. On a unit of AMD, the queue is a ring of commands. No program sees the queue.

The design: `src/md/infrastructure/iommu.md`, "The end of a grant".

Do not use: QI, invalidation queue, IQ.

### Device table

The device table is the table of a remapping unit of AMD that holds one entry of 32 bytes for each requester: the tables of its device domain, its domain identifier, and its interrupt table.

One device table serves every unit of AMD. An entry of zeros passes every access with no translation, so the kernel writes each entry at the start as the empty domain: one empty table and neither read nor write. A device domain writes the entry of its device, and its end writes the empty entry again. After each change, the unit forgets the entry. A device table is not the context table of Intel, which holds the entries of one bus: it holds those of every bus.

The design: `src/md/infrastructure/iommu.md`, "Two vendors behind one kernel side".

Do not use: DTE, dev table.

### Event log

The event log is a ring of records of 16 bytes in memory of the kernel where a remapping unit of AMD writes each access that it refused, and each fault of its own.

The unit writes a record, then sends the message interrupt of its function to the first processor. The kernel reads each record: a page fault becomes the line of a DMA fault or of a refused interrupt; another record is a line with a count of its own. A full log stops the records: the kernel counts it, empties the log and starts it again. An event log is not the log of the system: the kernel writes the lines of the log from it.

The design: `src/md/infrastructure/iommu.md`, "Two vendors behind one kernel side".

Do not use: PPR log, event buffer.

### Interrupt remapping

Interrupt remapping is the check by the IOMMU of each message interrupt of a device against an interrupt table that the kernel writes, so a device sends only the message interrupts that its service was given.

A message interrupt is a write of 4 bytes: without remapping, a device service can make its device send any vector of any processor. With remapping, the kernel writes one interrupt entry for each message interrupt that `Device_Create` makes, bound to the requester of its device, and the unit refuses every other message. A refused interrupt is a line of the log with its own count; nothing stops. Interrupt remapping is not a route of the lines of the 8259: those lines do not go through the IOMMU.

The design: `src/md/infrastructure/iommu.md`, "Interrupt remapping".

Do not use: IR, IRTE, interrupt translation.

### Bus

The bus is the PCI bus of the machine: each device has a place on it (bus, device, function) and a configuration of 256 bytes or more.

A program that can write the configuration of any device can make any device read or write any memory. So only the root service holds the ports of the configuration. It checks the device at each fixed place, enables it, and starts its device service with a read-only copy of the configuration, the device memory of its registers and one message interrupt. The kernel finds no device; with an IOMMU, it only reads the bus. The code of the bus is `src/library/support/pci`.

The design: `docs/ARCHITECTURE.md`, "U4. Device services".

Do not use: PCI tree.

### Disk

A disk is a device that keeps blocks when the machine stops.

A disk is the one place where data survives a stop of the machine. The system reads and writes a disk only through its block service, as a row of blocks numbered from 0. The test machine has three disks: the boot volume, which the firmware reads and no block service serves; the data disk; and the disk of the measures. A disk is not a volume with a file system: the storage service writes its own format on the whole data disk, with no partition table.

The design: `docs/STORAGE.md`, "3. The format on the disk".

Do not use: drive, volume (except the boot volume), LUN.

### Block

A block is 4096 bytes of a disk at a number from 0: the unit of each read and write of the block contract.

A block service reads and writes whole blocks (`BLOCK_SIZE` in `src/library/contract/block`). A request names its first block, a count of blocks and a place in the data region; a device with smaller sectors still serves whole blocks. The storage service builds everything that it writes from blocks: a node, an object node, a block of data, a root block. A block has the size of a page, but a block is on the disk and a page is in memory: the two words are not exchangeable.

The design: `docs/STORAGE.md`, "3.1 The blocks".

Do not use: sector, page (for a disk).

### Block service

A block service is the device service of one disk: it serves read, write and flush of blocks to one client through a block ring.

A block service keeps the code that knows a disk device out of the kernel and out of the storage service. The first one is the program `block`, for a virtio block device. The client sends `Attach` with its data region, then reads, writes and flushes. The device moves the bytes with no copy and no kernel entry for each request. A write is on the disk only after a later `Flush`. A block service is not a block layer: it has no cache, no scheduler and no partition.

The design: `src/library/contract/block`.

Do not use: disk driver, block layer.

### Block ring

The block ring is the ring between a block service and its one client: one command record is one request on blocks, and its completion record has the tag of the command and a status.

The block ring carries each request of a client to its disk with no kernel entry for each request. The root service makes it and gives it to the block service and to its client. A command has a kind (`Attach`, `Info`, `Read`, `Write`, `Flush`, `Statistics`), a tag and values. Many requests are in flight, and the device does them in any order. A completion that is not `Ok` carries an error record. A block ring is not a queue of the device: only the block service sees those.

The design: `src/library/contract/block`.

Do not use: I/O queue, submission queue.

### Data region

The data region is the memory object of the client of a block service where the device reads and writes the bytes of the blocks, with no copy.

The device moves the bytes of a block to and from memory of the client, so no program copies them. The client makes the region `Contiguous` and gives it to the block service with `Attach`. A request names a place in the region in bytes, never an address, and the service checks that each byte is in the region: a client cannot make the device write outside its own memory. The data region is not a cache: the client decides what it holds. The frame region is the same idea for a frame service.

The design: `src/library/contract/block`.

Do not use: DMA buffer, bounce buffer.

### Data disk

The data disk is the disk of the storage service: it holds the private stores of each program.

The data disk is the one disk whose content the system keeps. The root service starts its block service when the storage service starts, and gives the block ring to the storage service only. The storage service writes its own format on the whole disk. The modus tool makes a disk of 64 MiB for a run, and a new one for each machine test. The data disk is not a disk of the user: a program sees only its own private store.

The design: `docs/STORAGE.md`, "3. The format on the disk".

Do not use: data drive, home disk.

### Disk of the measures

The disk of the measures is a disk that holds no data that a program keeps: the program `disk` measures the block service on it.

A measure of the block service writes blocks, and a measure on the data disk destroys the stores. So the test machine has a second disk, and the root service gives its block ring to a test program only, such as `disk`. The program `disk` measures reads and writes with one request in flight and then with many, counts the kernel entries for each request, checks a pattern that it wrote, and shows the result. The storage service never uses this disk.

The design: `src/programs/disk`.

Do not use: scratch disk, test disk.

### Network device

A network device is a device that sends and receives frames on a link.

The test machine has one virtio network device, whose link goes to the peer of the modus tool or to the user network of QEMU. The root service starts its frame service when the first program that needs the network starts. The frame service is the only program that touches the device, and the network service is its only client: no other program can send a frame. A network device is not an interface with an address: the IPv4 address belongs to the network service.

The design: `docs/ARCHITECTURE.md`, "U4. Device services".

Do not use: NIC, network card, network adapter.

### Frame

In the group Devices, a frame is one Ethernet frame: the bytes from the destination hardware address to the end of the data, with no check sequence, 1514 bytes at most.

A frame is the unit that a network device sends and receives, and the unit of the frame contract: 14 bytes of header and 1500 bytes of data. The device adds and removes the check sequence. The network service builds and reads each frame with `src/library/support/network`. A datagram or a segment fits one frame, so the system never fragments. A frame is not a datagram and not a packet of IPv4: those are its content. It is not the frame of QUIC either, which has its own entry.

The design: `src/library/contract/frame`.

Do not use: packet (for this), datagram (for this), message.

### Hardware address

A hardware address is the 6 bytes that name a network device on its link.

A frame names its destination and its source by hardware addresses. The network service learns the hardware address of its own device from the completion of the command `Info` of the frame ring, and learns the hardware address of each other machine of the link by ARP, as a neighbor. The device of the test machine has 52:54:00:12:34:56.

A hardware address has meaning on one link only: it is not an address of IPv4 and it does not cross the gateway.

The design: `src/library/contract/frame`.

Do not use: MAC address, physical address (for this).

### Frame service

A frame service is the device service of one network device: it sends and receives frames for one client through a frame ring, and it does not read a frame.

The frame service keeps the code that knows a network device out of the kernel and out of the network service. The first one is the program `frame`, for a virtio network device. Its one client, the network service, sends `Attach` with its frame region, then `Send` for each frame and `Receive` for each place where a frame can arrive. The device reads and writes the frames with no copy, and drops a frame when no `Receive` waits. A frame service is not a network stack: it knows no protocol.

The design: `src/library/contract/frame`.

Do not use: NIC driver, network driver.

### Frame ring

The frame ring is the ring between a frame service and its one client: one command record is the send of one frame, or a place for one frame that arrives.

The frame ring carries the requests of the client to its device with no kernel entry for each request. Its commands are `Attach`, `Info`, `Send`, `Receive`, `Statistics`, `Read_Region_Add` and `Read_Region_Remove`. Many requests are in flight. A `Receive` stays in flight until a frame arrives: the client gives the places before the frames come, so the service allocates no memory for a frame. A frame ring is not one queue for each direction: one ring carries both, and the tag of the command says which request completed.

The design: `src/library/contract/frame`.

Do not use: TX queue, RX queue, descriptor ring (for this).

### Frame region

The frame region is the memory object of the client of a frame service where the device reads and writes the frames, with no copy.

It is the data region of the frame contract: contiguous, and given to the service with `Attach`. A request names a place in the region in bytes, never an address; a byte outside it gives `Out_Of_Range`. The network service owns the frame region. It copies each datagram that arrives one time, from the frame region to the datagram region of a program, and writes only the headers of a datagram to send. A frame region is not a socket buffer: a program with an endpoint never sees it.

The design: `src/library/contract/frame`.

Do not use: DMA buffer, skb, mbuf.

### Read region

A read region is a memory object that the client of a frame service gives with the right Read only, where the device reads the second part of a frame to send.

The read region lets the device read data where its writer put it, so that no service copies it. The network service gives the datagram region of each endpoint as a read region. A `Send` then names the headers in the frame region and the data in the read region. The frame service refuses a read region with the right **Write**, and keeps its handle until the last `Send` that reads the region is complete. A read region is not a frame region: the device never writes it.

The design: `src/md/infrastructure/network_data_path.md`, "The send with no copy".

Do not use: send buffer, transmit buffer, scatter list.

### Virtio

Virtio is the standard of devices that work through queues in shared memory, which the first machine uses for its disks and its network device.

A virtio device is already a set of queues in memory, so a device service translates between these queues and a ring with little code. The system uses virtio 1 over PCI, the modern interface only. `src/library/support/virtio` holds what each virtio device service does the same way: the capabilities, the features and the split queues. The block service and the frame service use it. Virtio is not a part of the kernel: the kernel has no code for any device.

The design: `docs/ARCHITECTURE.md`, "U4. Device services".

Do not use: paravirtual device.

## Network

### Network service

The network service is the one client of the frame service: it gives each program with a network grant one endpoint, and it checks each datagram and segment against that grant.

The device of the first machine has one pair of queues, so one program reads its frames: the network service. It enforces the grant of each program: no program has ambient access to the network. It speaks Ethernet, ARP, IPv4 and ICMP echo. For UDP and TCP it checks the ports and the lengths of each header and keeps no state of a connection. The root service starts it with the first program that has a network grant. It is not a network stack: it has no sockets, no retransmission and no routing table.

The design: `docs/NETWORK.md`, "The parts".

Do not use: network stack, TCP/IP stack, netd, network daemon.

### Data path

The data path is the code that reads or writes the bytes of the data that a program sends or receives through a device.

The term asks one question: does this code touch the bytes? The kernel is off the data path: no kernel entry carries data. One read or one write of each byte by one program is a pass: a copy is a pass, and so is a checksum. Example: the network service makes one pass on receive, the copy into the datagram region, and none over the data on send. The data path is not the control path of a packet, which reads only the headers.

The design: `docs/NETWORK.md`, "The path of a datagram and of a segment".

Do not use: fast path, hot path (for this).

### Control path of a packet

The control path of a packet is the code that reads the headers of a datagram or a segment and decides where it goes, and that reads no byte of its data.

A packet, in this term only, is the IPv4 packet that a frame carries: one datagram or one segment with its headers. When programs share one device, one program must read the ports of each packet, find the endpoint and check the grant. That work costs code and no pass over the data. Example: the network service is on the control path of each datagram and segment. It is not the data path, and not the control plane of the kernel, which runs no code for a packet.

The design: `docs/NETWORK.md`, "The path of a datagram and of a segment".

Do not use: slow path, packet path.

### Endpoint

An endpoint is what a program holds to send and receive datagrams or segments: a datagram ring and a datagram region, with a grant that names what it can reach.

An endpoint replaces the socket of other systems, but the program does not choose its remote. The root service names the grant, and the network service enforces it: a request to another remote fails with `Not_Granted`, and what another remote sends never reaches the program. An endpoint is a datagram endpoint (UDP) or a segment endpoint (TCP), each with a client grant or a listen grant. A program has one. The console shows its grant with `grants` and ends it with `revoke`. An endpoint is not a connection.

The design: `src/library/contract/datagram`.

Do not use: socket, port (for this), connection (for this).

### Datagram

A datagram is one UDP datagram: its header of 8 bytes and its data, 1472 bytes of data at most, what a program sends and receives through a datagram endpoint.

1472 bytes is the data of one Ethernet frame after the IPv4 and UDP headers, so a datagram is never a fragment. The program writes the whole datagram in a place of its datagram region, with the header and its checksum (`network.udp_header_write`), and sends it with `Send`. The network service checks the ports in its own copy of the header, and the device reads the rest from the place. Example: QUIC is a library in the program over datagrams. A datagram is not a frame and not a segment.

The design: `src/library/contract/datagram`.

Do not use: packet, message.

### Remote

A remote is the IPv4 address and the UDP port or TCP port at the other end of a datagram or of a connection.

A grant names remotes: a client grant names one, and a listen grant admits the remotes that came to it. A command of the datagram ring names a remote by its address and its port. An error record of `Not_Granted` holds the remote of the request and the remote of the grant. Example: the remote of the client grant of `fetch` is 10.0.2.100 port 80. A remote is not the host, which is the computer that runs QEMU, and not the peer, which is one part of the modus tool.

The design: `src/library/contract/datagram`.

Do not use: peer (for this), destination, host.

### UDP port

A UDP port is the 16-bit number of UDP that names one endpoint at an address.

The network service finds the endpoint of a datagram that arrives by its destination port. With a client grant, the network service gives the local port, and the command `Info` returns it. The program writes that port as the source port of each datagram, and the network service refuses another one. A listen grant names its port: the remote service listens on the UDP port 7100. A UDP port is not the Ports object of the kernel, and not a TCP port: one number names two different ports in UDP and in TCP.

The design: `src/library/contract/datagram`.

Do not use: port (alone), socket number.

### TCP port

A TCP port is the 16-bit number of TCP that names one end of a connection at an address.

The network service reads the TCP ports of each segment to find the endpoint and check the grant: a client grant has a block of 64 local TCP ports, and a listen grant has one. The program writes the ports in its header, and the network service checks the local port of each segment that leaves in its own copy of the header. Example: `server` has the listen grant of the TCP port 80. A TCP port is not the Ports object of the kernel, and not a UDP port.

The design: `docs/NETWORK.md`, "The grant of a segment endpoint".

Do not use: port (alone), socket number.

### Segment

A segment is one TCP segment: its header, its options and its data, 1480 bytes at most, what a program sends and receives through a segment endpoint.

1480 bytes is the room of one Ethernet frame after the IPv4 header, so a segment is never a fragment. The TCP library of the program writes each segment in a place of the datagram region, with its checksum, and the program sends it with `Send`. The network service checks the ports and writes the IPv4 header. For a segment that arrives, the TCP library checks the checksum and drops a wrong one. A segment is not a datagram and not a packet: the program sees no IPv4 header.

The design: `docs/NETWORK.md`, "The segment endpoint".

Do not use: packet, TCP packet, message.

### Segment endpoint

A segment endpoint is an endpoint whose grant has the protocol TCP: the program writes and reads whole segments, and the network service keeps no state of a connection.

A segment endpoint puts TCP in the program: each connection is in its own memory. The ring, the region, the commands and the error records are those of a datagram endpoint; only the grant differs, with TCP ports, and a block of them for a client grant. The program drives it with the TCP library: `tcp.step` takes the segments that arrived and writes the segments to send. Example: `server` has one. A segment endpoint is not a TCP socket: it is not one connection, and it does not accept or connect.

The design: `docs/NETWORK.md`, "The segment endpoint".

Do not use: TCP socket, listening socket.

### Client grant

A client grant is the grant of an endpoint that reaches one remote: one remote address and one remote port.

A client grant lets a program reach exactly one server. The network service refuses a request to another remote with `Not_Granted`, and drops what another remote sends. With a datagram endpoint, the program gets one local UDP port. With a segment endpoint, it gets a block of 64 local TCP ports, because a closed connection stays in TIME-WAIT. Example: `fetch` has a TCP client grant of 10.0.2.100 port 80. A client grant is not a rule of a firewall: it is the only remote that the endpoint can name.

The design: `docs/NETWORK.md`, "The grant of a segment endpoint".

Do not use: outbound rule, connect permission.

### Listen grant

A listen grant is the grant of an endpoint that receives on one local TCP or UDP port that the root service names, from any remote, and answers only the admitted remotes.

A server must receive from remotes that it does not know in advance, but must not reach a machine that did not come to it. With a listen grant, the program answers, but it does not reach: a send to a remote that is not admitted fails with `Not_Granted`. A UDP listen grant can also name one remote address. Examples: `server` on the TCP port 80; `remote` on the UDP port 7100, for the address 10.0.2.2 only. A listen grant is not a listening socket: it accepts nothing.

The design: `docs/NETWORK.md`, "The listen grant of UDP".

Do not use: listening socket, bind permission, server socket.

### Admitted remote

An admitted remote is a remote that came to the port of a listen grant, and that the program can therefore answer.

A remote becomes admitted when it sends a SYN to the TCP port of a listen grant, or a datagram of 1200 bytes at least to its UDP port, while a `Receive` of the endpoint waits. The program releases one with `Release` when its connection ended, and a place with no traffic for 120 s serves again. The table of admitted remotes is the one state of TCP in the network service. An admitted remote is not an entry of connection tracking: it is one address and one port.

The design: `docs/NETWORK.md`, "The grant of a segment endpoint".

Do not use: connection tracking entry, conntrack, NAT entry.

### Connection

In the group Network, a connection is the state of one TCP connection in the program that owns it: one record of fixed size of the TCP library, `tcp.Connection`.

TCP is a library in the program, so the state of each connection is in the memory of the program. The record holds the state, the sequence numbers, the windows, the timers and the counts. The program reads each field with no call; `server` draws them. The records are the rows of a connection table: `tcp.connect` opens one actively, and a SYN to the listen port opens one at the next `tcp.step`. A TCP connection is not the connection of the group Communication, and not a socket: no handle names it.

The design: `docs/NETWORK.md`, "The TCP library".

Do not use: socket, TCB (in this system), session.

### Web page

A web page is an object of the private store of `server` that `server` serves by its name, at the target `/name`.

`server` shows that a program reaches only what it was granted: its pages come from its own private store, not from a shared folder. The principal changes them from the console through the exports of `server`, such as `server.put` and `server.remove`. `server` reads its pages into its memory at its start, so a request never waits for the storage service. PUT and DELETE over HTTP are refused, because the network is not authenticated. A web page is not a file of a web root: it has no path and no folder.

The design: `docs/NETWORK.md`, "The HTTP server".

Do not use: file (for this), static file, asset.

### Access record

An access record is the record of one request that `server` answered: the remote, the method, the target, the status, the bytes of the body and the time.

The access records let the principal see the traffic of the server with no text log to parse. `server` keeps the last ones in its window, and writes one log record for each request on its log channel `requests`. The time runs from the first byte of the head to the last byte of the answer in the send buffer. Example: "server: GET /hello.html 200, 12 bytes, 157 us, 10.0.2.2 port 49200". An access record is not a line of an access log in a common format: it is a record of fixed size.

The design: `src/programs/server`.

Do not use: access log line, hit.

### Connection table

A connection table is the connection records of one program, the memory of their buffers, and what is common to them: the local address, the listen port, the block of local ports and the secret of the initial sequence numbers.

The TCP library allocates nothing: the caller gives the table (`tcp.Table`) with its records and one block of memory for all the buffers. One call, `tcp.step`, works on the whole table: it takes the segments that arrived, runs the timers, writes the segments to send, and gives the next deadline. The table also counts what no connection took, such as the SYNs refused. Example: `server` serves one table of 48 connections from one thread. A connection table is not a pool of sockets in a kernel.

The design: `docs/NETWORK.md`, "The form of the interface".

Do not use: socket table, connection pool.

### Datagram ring

The datagram ring is the ring between a program and the network service for one endpoint.

Its commands, in `src/library/contract/datagram`:

- `Send` and `Receive`: a datagram, or a whole segment.
- `Info`, `Statistics` and `Problems`: the facts, the counts and the refused frames.
- `Resolve` and `Echo`: ARP and ICMP echo.
- `Release` and `Validate`: for a listen grant.

Many requests are in flight. A `Receive` stays in flight until a datagram arrives, and the network service drops a datagram when no place waits. A refused request has an error record. A datagram ring is not a socket: a request names a place in the datagram region, never an address.

The design: `src/library/contract/datagram`.

Do not use: socket, channel.

### Datagram region

The datagram region is the memory of an endpoint, 512 KiB, where the program writes the data to send and the network service writes the data that arrives.

The root service makes the region and gives it to the program and to the network service. A program does not give a region of its own: if it did, a revocation of that memory stops the network service on a page fault. A request names a place in bytes; a byte outside gives `Out_Of_Range`. The device reads the data to send from the region, a read region of the frame service, and the `Send` completes when the device read it. A datagram region is not a socket buffer of a kernel.

The design: `docs/NETWORK.md`, "The send with no copy".

Do not use: socket buffer, send buffer, receive buffer.

### Neighbor

A neighbor is an address of the link and its hardware address, which the network service learned from an answer to its own ARP request.

A frame needs the hardware address of the next machine on the link. The network service asks it by ARP and keeps the answer in a table of neighbors. It learns only an address that one of its own requests asked, so an ARP frame that nobody asked for changes nothing. When the table is full, the answer replaces the oldest entry that no waiting request uses. A program asks for a new resolution with the command `Resolve`. A neighbor is not an entry of a cache that each ARP frame of the link can change.

The design: `src/library/support/network`.

Do not use: ARP cache entry, neighbour entry.

### Gateway

The gateway is the machine of the link that carries IPv4 packets to other networks: 10.0.2.2 on the first machine.

The network service sends each datagram whose address is not on its link (10.0.2.0/24) to the hardware address of the gateway. With the network of the tests, the gateway is the peer of the modus tool; with the user network of QEMU, it is libslirp. The host reaches the machine from the address of the gateway, so the listen grant of the remote service admits that address only. The gateway is not a routing table: the network service has one route.

The design: `docs/NETWORK.md`, "The parts".

Do not use: router, default route.

### Peer

The peer is the part of the modus tool that is the gateway and the echo server of the network of the test machine, a TCP client that the tool drives, and the QUIC client of the remote service.

The peer makes the network tests closed and repeatable: no frame leaves the host, and each run has the same answers. It reads each frame with its own code, so a fault of the network service in a checksum or a length is a fault that the peer sees. It sends frames that the network service must refuse, and can drop, reorder and repeat the frames of TCP. The peer is not a simulator of a network: it speaks the real protocols. It is in `tools/modustool/peer.odin`.

The design: `docs/NETWORK.md`, "With the controlled peer".

Do not use: mock, fake server, simulator.

### Host

The host is the computer that runs QEMU and the modus tool; the system does not run on it.

The host builds the system, starts the machine, and drives the tests. For the network of the machine, the host is at the address of the gateway, 10.0.2.2: the peer of the tool answers for it, and each call of the tool to the remote service comes from that address.

The host is not the machine: the machine is the computer, real or emulated, that runs the system. The host is not a remote either: a remote is any address and port at the other end of a datagram.

The design: `docs/QUIC.md`, "7. `remote` over QUIC (built)".

Do not use: build machine (for this), remote (for this).

### Remote service

The remote service is the program `remote`: a QUIC server that takes each call of the host on a call stream, makes it as an isolated call of an export of a service, and writes the call answer on the same stream.

The remote service lets the modus tool on the host call an export of a running service, for tests and for the console of the developer. It has a UDP listen grant on the port 7100 that admits the address of the host only. It makes an Ed25519 key at its start and logs it, and the tool pins that key. A call acts for the principal that allowed the key of the client. The remote service is not a debug agent: it calls only exports.

The design: `docs/QUIC.md`, "7. `remote` over QUIC (built)".

Do not use: RPC server, debug agent, gdbstub.

### Call socket

The call socket is the Unix socket where the peer of the modus tool takes the calls of the tool to the remote service, one connection of the socket for each call.

The call socket keeps the calls on the host to one user: it is in a folder of that user with no right for the group and the others. `modustool run` takes the socket `calls-run.socket` and prints its path, and `modustool call` finds it by the same rule. On a connection, the tool writes a header with the key to pin, then the call request; the peer writes the outcome and the call answer. The call socket is not a port of the network: no other machine reaches it.

The design: `docs/QUIC.md`, "The client of the tool".

Do not use: call port, loopback port (for this).

### Call stream

A call stream is one bidirectional QUIC stream of a connection to the remote service that carries one call: the call request from the host, then the call answer from the remote service.

The stream names the call: no number in a header matches an answer to its request. The host writes the call request and ends its direction; the remote service makes the call, writes the call answer and ends its direction. QUIC sends a lost datagram again, so the host never sends a call again: a call whose answer did not come can have run. A call that fails ends its stream with a stream error code, and the other calls go on. A call stream is not a channel of many calls.

The design: `docs/QUIC.md`, "One call, one stream".

Do not use: RPC channel, request stream (for this).

### Stream error code

A stream error code is the application error code of a RESET_STREAM, a STOP_SENDING or a CONNECTION_CLOSE of the remote service: a value of `remote.Stream_Error`, which the tool prints by its name.

The values are `Too_Large` (1), a request of more than `REQUEST_LIMIT` bytes; `Timeout` (2), a bound of time that passed; and `Cancelled` (3), a stream that the host ended before the call. A request that does not pass its check gets no stream error code: it gets a call answer with the status Refused and its error record. A stream error code is not a status of a call and not an error number: it says why the transport of one call ended.

The design: `docs/QUIC.md`, "Errors and ends of a call".

Do not use: status (for this), error number.

### Call request

A call request is the bytes of a call stream from the host to the remote service: a fixed header, `remote.Request`, then the bytes of the call region from offset 0.

The header names the service, the BLAKE3 hash of its module and the index of the export. The host encodes the arguments with the description of the export. The remote service trusts nothing in a request: `remote.request_check` checks each count and each place against the bytes of the stream and the size of the call region. A refusal is a call answer with the status Refused. A call request is not a message with names in text: it names the export by its index and the module by its hash.

The design: `docs/MODULE_CONTRACT.md`, "A call from the host".

Do not use: RPC request, message, packet.

### Call answer

A call answer is the bytes of a call stream from the remote service to the host: a fixed header, `remote.Answer`, then the bytes of the result.

The header has 112 bytes: the status, the integer result, the error record, and the count of the bytes of the result that follow (`total`). The host trusts nothing in it: `remote.answer_check` checks that the bytes are exactly a header and its total, and that the status names a member. The host decodes the result with the description of the export and prints it. The answers come back in any order; the host matches each one to its call by its stream. A call answer is not a response of HTTP: it has no headers of text.

The design: `src/library/contract/remote`.

Do not use: response, reply.

### Developer tool

A developer tool is a program that shows how the system runs: what a program holds in memory and how its threads run; it reads reports of the kernel with a grant and changes nothing.

A developer tool makes the state of the kernel visible with no debugger attached. Each tool reads reports with the operation `Inspect`, with the machine handle and the right **Inspect**. Examples: `monitor` shows the counts of each program, `scheduler` the run queues, and `inspect` the address space and the threads of one program. Each tool also serves its facts as exports, so the console reads them as tables, such as `monitor.programs()`. A developer tool is not a debugger: it does not stop a thread or read the bytes of another program.

The design: `docs/TOOLS.md`, "What each tool reads".

Do not use: debugger (for this), profiler, task manager.

### Sample

A sample is one read of all the reports that a developer tool shows, at one time.

A developer tool reads several reports, and the system runs between two reads. A sample groups them so that the window shows one state. `inspect` takes a sample each 250 ms, and shows the time and the kernel entries of one sample, so the cost of the tool is visible. A sample whose reports come from two programs of one slot is dropped. A value that changed since the last sample has another color. A sample is not a snapshot of the store, and not a frame of the screen.

The design: `docs/TOOLS.md`, "The program `inspect`".

Do not use: snapshot (for this), poll, frame (for this).

### Folded gap

A folded gap is the part of the band of an address space between two mappings that has no mapping: the band draws it with a fixed width and lines at an angle.

An address space of a program has small mappings far apart. On a scale by address, the mappings are invisible lines. `inspect` folds each gap, so each mapping keeps a readable width, and draws lines at an angle on the gap to show that it has no measure on the scale.

A folded gap is not an ellipsis of a text: it is a part of a drawn band, and its width says nothing of its size.

The design: `docs/TOOLS.md`, "The program `inspect`", and `docs/DESIGN.md`, "2. Forms".

Do not use: ellipsis, break.

### Near export

A near export is the export of a module with the highest address at or below an address: a reader names the address "module + offset, near name".

A module names its exports only. With no debug image, a frame of a stack trace in a function that is not an export has no name of its own. The near export gives it the name of the export before it, as a hint, with the offset from the module. With a debug image, a frame has the name of its procedure and its source line. A near export is not a symbol: it is an export, and it can be far from the real function.

The design: `docs/TOOLS.md`, "Names and lines".

Do not use: symbol (for this), nearest symbol.

### Confirmed place

A confirmed place is a place of the pointer that the modus tool read from the compositor before a press, through the remote service.

A press must land where the step wants it, and the tool does not trust its count of the moves that it sent to QEMU. So, in a machine test, the tool calls `compositor.pointer()` before each press, and moves the pointer again from the place that the compositor gives, a few tries at most. Before the remote service runs, the tool does not confirm the place. A confirmed place is not a move of the pointer by the system: the compositor only reports where the pointer is.

The design: `docs/TOOLS.md`, "How the tool sends input and waits".

Do not use: pointer sync, warp.

## Storage

### Object

An object is bytes that never change, named by their hash: a new content is a new object.

The object is the unit of stored data. A module, a font, a picture and the text of a note are the same thing: bytes and their hash. Today an object is an entry of kind object in a tree. A program writes it with `storage.write(place, name, data)`, or by ranges and `commit`, and reads it with `read` or `read_range`. A write gives the entry a new state, and the state before becomes a version. An object is not a file: it has no path, no owner and no permission bits.

The design: `docs/STORAGE.md`, "1. The model".

Do not use: file, blob, inode.

### Tree

A tree is an object that names other objects and trees, each by an entry with a name.

A tree is the only kind of folder. A handle on a tree reaches what is under it and nothing above it. On the disk, each tree is its own B+ tree of nodes, with no limit of entries but the disk. A program makes a tree with `storage.add`, opens it with `storage.open(place, name)`, which gives a new place, and lists it by pages with `storage.list`. A tree is not a directory: no entry names its parent. Today a tree that changes has no hash.

The design: `docs/STORAGE.md`, "1. The model".

Do not use: directory, folder, list (for this), manifest, catalog (for this).

### Entry

An entry is one name of a tree and what it names: an object or a tree.

An entry is the only link between a name and data. It holds the kind, the size, the generation, the time and the date of its last change, the hash of an object, the pointer of its root, and the version index of an object. A name has 1 to 64 bytes, no byte `/`, and is not `.` or `..`, so a name always goes one step down. A rename moves an entry with its versions. An entry is not a path and not a hard link.

The design: `docs/STORAGE.md`, "3.2 An entry".

Do not use: directory entry, link, file name, path.

### Node

A node is one block of the B+ tree of a tree: a leaf of up to 24 entries, or a branch of up to 50 children.

A node keeps a tree of any size in blocks of 4096 bytes, with a search in a few reads. A commit never writes over a node that the root on the disk names: it writes each changed node to a free block, then the node above it (copy on write). The open of the disk checks each node; a node that breaks a rule of its format is damage of its store. A node is not an object node, which is a block of the block tree of one object.

The design: `docs/STORAGE.md`, "3.1 The blocks".

Do not use: page (for this), bucket, inode.

### Store

A store is a cell that names one tree now: the one thing of storage that changes.

The store is the unit of access and of accounting. A grant of the root service gives a program a connection to one store, with a limit of blocks. A commit moves the store to another tree in one atomic step. A program sees the counts of its store with `storage.usage()`. A store is not a volume or a mount: a program never names a store by a path. It is not a head of a version control system either: today the versions are kept for each object, not for the store.

The design: `docs/STORAGE.md`, "1. The model".

Do not use: reference (for this), volume, file system, mount, head.

### Place

A place is a number that a connection to the storage service holds: the names of a path from the root of the connection, and the right to change or read only.

A place lets a program name a tree with no path in a call: each export takes a place and one name, as `storage.write(place, name, data)`. The place 0 is the root of the connection. `storage.open(place, name)` gives a new place, and `storage.close(place)` frees it. A place follows the names, not the bytes, and is valid on its connection only. A place is not a file descriptor and not a working directory: it is not a handle of the kernel, and it never reaches above its root.

The design: `docs/STORAGE.md`, "4.1 Places".

Do not use: file descriptor, directory handle, working directory, path.

### Share

A share is a connection to the storage service that the service itself makes for a caller, whose root is a tree of the store of the caller, with or without the right to change.

A share gives another program one part of a store. `storage.share(place, read_only)` gives the caller two handles, which it gives to the other program with `Handle_Give`. That program reaches the tree and what is under it, and nothing above. `storage.unshare(share)` revokes the handles in each program. When the grant of the store of the maker ends, each of its shares ends too. A share is not a mount: it adds no name to any tree.

The design: `docs/STORAGE.md`, "4.3 Read only, and revocation".

Do not use: mount, bind, export (for this), link.

### Removal queue

The removal queue is the trees of a store that a remove took out of their tree and whose blocks the storage service has not freed yet.

A remove of a large tree must not be one huge commit. So `storage.remove(place, name)` of a tree takes the entry out of its tree in one commit, and the name is gone at once. The service then frees the queue in small commits, when no call waits. The queue is on the disk, so a loss of power loses no step. Its blocks stay counted in the store until they are free. The removal queue is not a trash: nothing in it comes back, and no program reads it.

The design: `docs/STORAGE.md`, "4.4 The removal of a tree".

Do not use: trash, bin, garbage list.

### Version

A version is the state of one object at one commit: its size, the root of its block tree, and the generation, the time and the date of that commit.

Versions remove the save action: each commit that changes an object keeps the state before it as a version, with no call of the program. A version costs only the blocks that only it names. A program reads them with `versions`, `version` and `compare`, and uses them with `restore` and `clone`. The retention rule and the limit of the store thin them; a version erase ends them all. A version is not a backup on another disk, and not a revision that a program makes on purpose.

The design: `docs/ARCHITECTURE.md`, "U5. Storage service".

Do not use: snapshot (when it means one object), backup, revision, undo step.

### Current version

The current version is the state of an object that its last commit made: what a read gives.

The entry of the object names the current version directly: its size, its hash and the root of its block tree. It is not in the version index. A commit makes a new current version, and the current version of before becomes a version. A pending change of a connection is not yet the current version: the connection sees it on its reads, and each other connection sees the current version.

The current version is not a working copy: it is on the disk, at the commit that made it.

The design: `docs/STORAGE.md`, "3.2 An entry".

Do not use: head, working copy, latest revision.

### Version index

The version index is the blocks of one object that list its versions: an index block that names leaf blocks, which hold the version entries, the oldest first.

The entry of an object points to its version index. A commit that changes the object rewrites the index and the leaf that it changes: 2 blocks, copy on write. The index also keeps the time of the last application of the retention rule to the object. A version index with a wrong check does not lock its object: `versions`, `version` and `restore` give `Damaged`, and the next commit drops those versions. A version index is not a journal: it records states, not operations, and nothing replays it.

The design: `docs/ARCHITECTURE.md`, "U5. Storage service".

Do not use: history file, journal, log.

### Shared block

A shared block is a block that two states, two objects or two nodes name: a block that a change did not touch, or a block of a clone.

Copy on write makes shared blocks: a commit writes new blocks only on the paths that it changes, and the new state names each other block of the state before. A store counts each distinct block one time in its blocks in use. Example: after 1000 writes in an object of 8 GiB, the version before them holds 4 blocks of its own, and the others are shared. Two objects of one store with the same bytes share their blocks through the hash index. A shared block is not an extent reference.

The design: `docs/STORAGE.md`, "Versions, thinning and the limit".

Do not use: deduplicated block, extent reference.

### Reference count

A reference count is, for each block in use, the count of what names it: the nodes that name it, and the entries and versions that name it as a root.

The reference count lets the storage service free a block at the commit that drops its last name, with no walk of the disk. A node with no name left gives one name less to each of its children. The counts are in the memory of the service only: the open of the disk makes them again. Only object nodes and blocks of data can have a count above 1. A reference count is not a link count of a file: no program sees it.

The design: `docs/STORAGE.md`, "Versions, thinning and the limit".

Do not use: link count, refcount (in text).

### Thinning

Thinning is the removal of versions of an object in a commit, by the retention rule or at the limit of the store; its blocks that no other state names become free.

Thinning keeps the versions from filling the disk, with no action of a program. The retention rule thins an object at a commit of that object. At the limit of the store, a change that does not fit thins the oldest versions of the store in its own commit. A change that does not fit with each earlier version thinned is refused before any thinning, so a refused change destroys no history. Thinning is not a collection of garbage, and a freed block keeps its bytes: a version erase writes zeros over them.

The design: `docs/ARCHITECTURE.md`, "U5. Storage service".

Do not use: garbage collection, pruning, cleanup, compaction.

### Version erase

A version erase ends each version of one object in one commit, then writes zero bytes over each block that this commit freed.

It removes an old state that is a hazard: after a change of the passphrase of a principal, `unlock` erases the versions of its file, so the old secret opens nothing on the disk. `storage.erase_versions(place, name)` needs the grant to erase versions. The current version stays, and a block that another state names keeps its bytes. A version erase is not a thinning, not a remove, and not an erase of the medium: a flash disk or a snapshot of the host can keep the old sectors.

The design: `docs/STORAGE.md`, "4.8 The erase of versions".

Do not use: wipe, shred, secure delete, purge.

### Grant to erase versions

The grant to erase versions is the start grant `Versions_Erase`: the storage service lets its holder end the versions of the objects of its own private store, with a version erase.

Versions protect the principal against a fault of the program that writes an object, so no program ends them by itself. The root service gives this grant only to a program that keeps a secret that an earlier version must not keep: today `unlock`. A call of `erase_versions` with no such grant is refused with `No_Grant`, unit `Versions_Erase`. A share never has it. The grant is not a right over another store, and not a right to remove an object.

The design: `src/md/features/version_erase.md`.

Do not use: delete right, history right.

### Retention rule

The retention rule is which versions the storage service keeps: each version for 10 minutes, then the newest of each hour until it is one day old, then the newest of each day.

The rule keeps many versions of a recent state and few of an old one, with no setting. The service applies it to an object at a commit of that object. The age of a version is the smaller of its age by the date and by the time since the format, so a wrong clock never makes a version older. It is not a policy that a program sets: it is the same for each store, and the limit of the store can still thin a version that it keeps.

The design: `docs/ARCHITECTURE.md`, "U5. Storage service".

Do not use: backup policy, history limit.

### Clone

A clone is a new entry that names the block tree of another object: the two share each block until one of them changes.

A clone copies an object of any size in one commit that writes no block of data. `storage.clone(place, name, new_name)` makes `new_name` under the same place name the root of the block tree of `name`. A state of `new_name` before the clone becomes a version. After the clone, a change of either object writes new blocks on its own paths only. A clone is not a copy of the bytes, not a hard link (a change of one does not change the other), and not a reflink of a file system.

The design: `docs/ARCHITECTURE.md`, "U5. Storage service".

Do not use: copy (for this), hard link, reflink.

### Restore

A restore is a commit that makes a version of an object its current version again; the current version before it becomes a version, so nothing is lost.

`storage.restore(place, name, generation)` writes no block of data: the entry names the root of the block tree of the version. The result is the generation of the commit. Because the state of before becomes a version, a restore can itself be undone by another restore.

A restore is not a rollback of the store: it changes one object, and each other object keeps its current version.

The design: `docs/ARCHITECTURE.md`, "U5. Storage service".

Do not use: revert, rollback, undo.

### Time since the format

The time since the format is the milliseconds of the storage service since the format of the data disk: the root block keeps it at each commit.

A version needs a time that never goes back, also when the machine has no date. At its start, the service takes the time since the format from the root and adds its own time since its start. Each entry and each version keeps it beside the date, and the retention rule counts its hours and days from it. It is not the time since the start of the machine, and not a date: it does not count the time when no machine ran.

The design: `docs/ARCHITECTURE.md`, "U5. Storage service".

Do not use: uptime, timestamp.

### Snapshot

A snapshot is the tree that a store named at one commit; the system does not keep it apart.

The state of a store at a generation G is, for each object, its version with the highest generation at or below G. So the versions of each object hold each snapshot, with no structure of its own. In the model, the versions of a store will be the trees that it named; that history of a store is a later step.

A snapshot is not a copy and not a backup.

The design: `docs/STORAGE.md`, "1.3 Where the model does not hold as it was first stated".

Do not use: checkpoint, backup.

### Private store

A private store is the store of one program: the root service names it after the program and gives it a limit of blocks, and no other program sees it.

The private store replaces the shared file system: a program keeps its data where no other program can read or damage it. A program with the grant `Store` gets a connection to it. Two principals that run one program have two stores, as `notes` and `notes.principal.1`. The limit of blocks counts the versions too. Another program reaches a part of it only through a share. A private store is not a home folder of a user and not a container.

The design: `docs/PROPERTIES.md`, "8. No global, mutable, shared file system".

Do not use: home directory, app data, container.

### Document

A document is an object that belongs to the principal and not to one program, which a program reaches only through a grant of the document service.

A document solves what the private store does not: data that several programs open, such as a text or a picture. In the design, the document service owns the documents, shows the picker where the principal chooses one, returns a handle to the program that asked, and records each grant so that it can be listed and revoked. The document service is not built. A document is not a file of a shared file system: a program cannot list or open the documents by itself.

The design: `docs/ARCHITECTURE.md`, "U6. Document service".

Do not use: file, user file.

### Module store

The module store is the set of all modules and system data, each named by the hash of its content.

In the model, the module store is the objects of the tree of the system: the root service loads each module, font and pointer theme by its hash, and an object can come by any channel, because its hash proves it. It is not built: today the boot image is the source of each module, except the module files of the disk programs in the store `programs`. The module store is not a store of the storage service, and not a repository of packages with versions by name.

The design: `docs/STORAGE.md`, "5. Not built: the next steps".

Do not use: package store, repository, the Nix store.

### System description

The system description is the list of hashes that defines one version of the whole system: the kernel, then each module and each resource of the boot image, with its kind, its size and its BLAKE3 hash.

The system description makes the system reproducible and verifiable: two machines with the same description run the same bytes. The signing key of the machine signs its hash. The boot program verifies the signature and each hash before it starts the kernel, and the root service checks the boot image against it again. The system description is not the boot image, which carries the bytes, and not a generation of the storage service.

The design: `docs/TRUSTED_BOOT.md`, "3. The system description".

Do not use: image, generation, manifest, profile, system list.

### Distinct result

A distinct result is one content of one output of a build (a module, its LLVM IR, its object, the boot program) among the contents that several builds of the same source gave.

The identity of a module is the hash of its content, so one source must give one distinct result for each output. `modustool check` builds everything a second time and compares; `modustool repeat` builds again and again. When an output differs, each distinct result stays in `build/different_builds/`, and the tool prints where the first difference is. A distinct result is not a version of a module: it is a fault of the build to correct.

The design: `docs/REPRODUCIBLE_BUILD.md`, "6. What is proved, and what is not".

Do not use: variant (except in the names of the kept files), version.

### Storage service

The storage service is the service that keeps the stores, their trees, their objects and their versions on the data disk, through the block service of that disk.

The storage service is the one program that writes the data disk. Each other program reaches its own store through a connection that the root service gives, with a limit of blocks. Each change is one commit, on the disk when the call returns, and a stop of the machine never shows a part of a commit. At its start, the service opens the disk and checks each block. The storage service is not a file system: it has no paths, no mount, and no global tree of names.

The design: `docs/STORAGE.md`, "4. The interface of the service".

Do not use: file system.

### Root block

The root block is the block of the data disk that names each store, with the generation of the last commit; the disk has two places for it.

The root block makes a commit atomic. A commit writes its new blocks to free blocks, asks the disk to keep them (`Flush`), then writes the root block in the place of the older of the two roots. The root has its own check. At the start, the storage service takes the valid root with the highest generation. The root block is not a superblock that a program can read: only the storage service and the modus tool read it.

The design: `docs/STORAGE.md`, "3.3 The commit and the open".

Do not use: superblock, uberblock, meta page.

### Commit

A commit is one change of the stores that is on the disk completely or not at all: new blocks first, then a new root block.

The commit is the unit of change and of history: each commit that changes an object makes a version, and each commit has its own generation. Each export that changes something is one commit, on the disk when the call returns: `write`, `add`, `rename`, `remove`, `restore`, `clone`, and `commit` for pending changes. A refused commit changes nothing. A commit is not a save that a program asks for, and not a transaction that holds several calls open.

The design: `docs/STORAGE.md`, "3.3 The commit and the open".

Do not use: transaction (for this), save, sync.

### Commit read back

The commit read back is the step of each commit in which the storage service reads back from the device each block that the commit wrote, before its root, and then its root, and compares the bytes with the bytes that it wrote.

It finds a dropped write while the root before the commit is still whole. If the bytes differ, the service refuses the commit (`Device`, unit `Dropped_Writes`) and keeps the state of the root before, with no restart. It costs one read for each block that the commit wrote. It is not a check of the medium: a device that answers the read from the cache that lost the write passes it.

The design: `src/md/features/dropped_write.md`.

Do not use: write check, readback.

### Generation

A generation is the number of a commit: each commit has the generation of the commit before it plus 1, on the whole disk.

The generation orders every state on the disk. The root block keeps it, so the start takes the root with the highest valid one. Each entry and each version keeps the generation of its commit; `version`, `restore` and `compare` name a version by it. A generation counts the commits of the whole disk, not of one store, so a test cannot predict an absolute generation: it reads a base of the generations. A generation is not a version of an object and not a time.

The design: `docs/STORAGE.md`, "3.3 The commit and the open".

Do not use: epoch, transaction id, version (for this).

### History store

The history store is the store of the line history of the console in the storage service, apart from its private store.

The line history must survive a stop, but the console must not need the grant of its private store, or the grant to act for the principal, for it. So the root service gives the console a second connection, with the grant `history`. Its store is `console.history`, and its limit is 4 blocks. The history store is not a file of a shell in a home folder: no other program reads it, and `revoke("console", "history")` ends it.

The design: `docs/CONSOLE.md`, "6. The line history across a stop".

Do not use: shell history file, profile directory.

### Base of the generations

The base of the generations is, in a machine test, the generation of one commit that a step `Generation` reads from the log, so that the steps after it name the generations that they wait for as the base and a count.

A generation counts the commits of the whole disk, and the console commits its line history after each line, so an absolute generation in a test changes with each line before it. A later step names `{generation}` or `{generation+4}` in its text. A step that names `{generation}` before any step `Generation` stops the test. The base is a number of the modus tool, not of the system.

The design: the step `Generation` of `tools/modustool/machine.odin`.

Do not use: offset, delta.

### Damaged object

A damaged object is an object whose state names a block with a wrong check under a valid root block: the storage service does not give its bytes.

Damage is a change on the disk that the service did not make. The open of the disk checks each block that a root names. A wrong block of an object damages only that object: a read gives `Damaged`, and the other objects are served. A write or a remove of the object replaces the damaged state. A wrong node damages its whole store. A damaged object is not a bad sector: the device reported no error, and the check found the damage.

The design: `docs/STORAGE.md`, "3.3 The commit and the open".

Do not use: corrupt file, bad sector.

### Dropped write

A dropped write is a write that the disk answers with Ok and does not keep.

The device reports no error, so the storage service learns of a dropped write only at a read. The commit read back finds it first: the service refuses the commit, and the objects read as they were before it. After a loss of power before the read back, the open uses the root before, when that root names no wrong block. A device that answers from the cache that lost the write hides the drop. A dropped write is not a loss of power, and not a torn write: no part of the block reaches the disk.

The design: `src/md/features/dropped_write.md`.

Do not use: lost write (for this), silent write failure, phantom write.

### Check

A check is 8 bytes of a hash of a block, kept in the pointer that names the block: a block that does not have its check is not used.

The check finds each change of a block that the storage service did not make, and each block that a cut commit left. A pointer is a block number and a check. The check of a block of data is the first 8 bytes of its value; the check of each other block is the first 8 bytes of its BLAKE3 hash. The open compares the check of each block that a root names. A check is not a CRC: it is a cryptographic hash, kept in the block above.

The design: `docs/STORAGE.md`, "3.1 The blocks".

Do not use: checksum, CRC, digest.

### Block tree

A block tree is the blocks of one state of an object: its blocks of data, where the block n holds the bytes from n × 4096, and the object nodes above them.

The block tree makes a large object cheap to change: a commit of K changed blocks writes those K blocks and the object nodes on their paths, and names each other block of the state before. A block of zero bytes is a hole and is not in the tree. A program never sees the block tree: it reads and writes bytes and ranges. Example: an object of 8 GiB written by three range writes holds 13 blocks. A block tree is not an extent tree: it has no runs of blocks.

The design: `docs/STORAGE.md`, "The block tree".

Do not use: extent tree, block map, list of blocks.

### Object node

An object node is one block of a block tree above the blocks of data: 64 children, each an object node of the level below, a block of data, or a hole.

Each child holds its block number, its check, the count of blocks under it, and its value. 64 is a power of two, so an object node covers a whole subtree of the BLAKE3 tree of the bytes, and its value comes from the values of its children. The open checks each object node. An object node is not a node, which is a block of the B+ tree of a tree. It is not an indirect block either: it carries the value of each child.

The design: `docs/STORAGE.md`, "The block tree".

Do not use: indirect block, extent node, node (for this: a node is of a tree).

### Hole

A hole is a part of an object whose bytes are all zero: nothing names it, it costs no block, and it reads as zero bytes.

Holes let an object have a large size and few blocks. The service never writes a block of zero bytes: a write that leaves one makes a hole. A hole has the value zero, so it costs nothing in the hash of the object either, and no block in the limit of the store. Example: `read_range` across a hole gives zero bytes. A hole is not a reserved area: a write in a hole takes new blocks at its commit.

The design: `docs/STORAGE.md`, "The block tree".

Do not use: sparse region, gap, zero block (for this).

### Value

A value is the BLAKE3 chaining value of a part of an object, as a subtree of the BLAKE3 tree of its bytes, with zero bytes past its size; a hole has the value zero.

Values let the storage service compute the hash of an object from the blocks that a commit changed, not from the whole object. The value of a block of data is its chaining value at its place in the object, and its first 8 bytes are the check of the block. Each object node keeps the value of each child. A value is not a hash of a block alone: the same bytes at two places have two values.

The design: `docs/STORAGE.md`, "The block tree".

Do not use: digest, checksum, fingerprint.

### Hash of an object

The hash of an object is its name: the BLAKE3 hash of its bytes, except that a hole before its last block counts with the value zero.

The hash comes from the values on the path of the last block and the bytes of that block, so a commit never hashes the whole object. With no hole before its last block, the hash is exactly the BLAKE3 hash of its bytes. It is always a function of the bytes alone, because a block of zero bytes is always a hole. The hash of an object is not always the hash of a module: a module file with a hole has another hash as an object.

The design: `docs/STORAGE.md`, "The hash of an object".

Do not use: content id, checksum (for this).

### Hash index

The hash index is the table in the memory of the storage service that finds the root of the current state of an object of a store by the hash of that state.

The hash index keeps the same object one time: a commit whose new state has the hash and the size of a current object of the same store names the root of that object, and writes no block of it. The open of the disk makes the index, so it is never on the disk. Example: the program `ranges` writes an object of 1 MiB under two names, and the store holds 261 blocks for both. The hash index is not an index on the disk, and never names a block of another store.

The design: `src/md/data/hash_index.md`.

Do not use: deduplication, dedup table, content-addressed store.

### Range

A range is a count of bytes from an offset of an object.

Ranges let a program read and change a part of a large object with no copy of the rest. `storage.read_range(place, name, offset, result)` reads bytes from `offset`, with the pending changes of the connection. `storage.write_range(place, name, offset, data)` changes one range as a pending change, and `storage.compare` gives the ranges that differ between two states. Example: the program `ranges` makes 1000 writes of 16 bytes in an object of 8 GiB, then one commit. A range is not an extent of the disk: it says nothing of the blocks.

The design: `docs/STORAGE.md`, "Ranges".

Do not use: extent (for this), segment, slice (for this).

### Pending change

A pending change is a range write or a change of size that the storage service keeps for one connection until its commit: not on the disk, and not hashed.

Pending changes group many small writes into one commit, which is one version. A read of the connection sees its pending changes; another connection sees the last commit. `storage.commit(place, name)` makes them one commit. Another change of the object before the commit comes first: the commit is then refused, and the pending changes are dropped. A loss of power or the end of the connection drops them. A pending change is not a dirty page that the system writes later by itself.

The design: `docs/STORAGE.md`, "Ranges".

Do not use: dirty page, write buffer, uncommitted write, transaction (for this).

## Desktop

### Surface

A surface is a memory object that one program draws into and the compositor shows as the content of a window.

A surface keeps the pixels out of the kernel and out of the rings: the program writes pixels in its own memory, and the compositor reads the same memory. A program opens a surface with `display.open(ctx, width, height, title)`, which needs the grant of the display. It draws a picture, then sends `Present` with the rectangle that changed. The compositor sends the input of the window back on the same ring. A surface is not a framebuffer: only the compositor writes the screen.

The design: `docs/DESIGN.md`, "3. Surfaces".

Do not use: window buffer, framebuffer (reserved for the UEFI one).

### Picture

A picture is one complete image in the memory of a surface; a surface has two pictures.

The program draws one picture while the compositor reads the other, and `Present` names the picture that is complete; the next frame draws in the other one. The picture that a frame draws holds the frame of two frames before, so the interface package keeps, for each picture, the rectangles where it differs from the last frame presented. A picture is not a picture record: a picture record shows pixels that the program holds in its own memory, inside its surface.

The design: `docs/INTERFACE.md`, "2.2 Damage by difference".

Do not use: back buffer, front buffer, swap chain.

### Whole frame

A whole frame is a picture of a window that reaches the screen complete: the screen never shows a picture that a program is drawing.

It is a rule of the system for every window, and a program writes no code for it. The program draws only the picture that the compositor does not read, and a program that stops in a draw leaves its last complete picture on the screen. The compositor counts the breaks of the rule (`pictures_drawn_again` in `compositor.windows()`). A hostile program can break it, but it spoils only its own window. The frames of the compositor keep the rule too, by a page flip.

The design: `src/md/infrastructure/whole_frame.md`.

Do not use: tear-free, double buffering, vertical synchronization.

### Screen page

A screen page is one whole screen in the video memory of the display: the display shows one screen page at a time.

The video memory of the test machine holds two screen pages. The page 0 is the framebuffer of the firmware. The compositor writes each frame into the page that the display does not show, then a page flip shows it. A screen page holds the frame of two frames before, so the compositor keeps the rectangles where each page differs. On a display with no page flip, the compositor has one screen page. A screen page is not a picture, which is in the memory of a surface.

The design: `src/md/infrastructure/whole_frame.md`, "The screen: two screen pages and a page flip".

Do not use: back buffer, front buffer, framebuffer (for the page 1).

### Page flip

A page flip is the one write of a display register that makes the display show another screen page.

The compositor writes the first line of the page in the register `Offset_Y`, then reads it back: a value that differs is a refused flip, and the compositor goes back to one screen page. `compositor.screen()` counts the flips in `page_flips`. A page flip is not a `Present`: a `Present` names the picture of a surface that the compositor reads next, and a page flip names the screen page that the display shows.

The design: `src/md/infrastructure/whole_frame.md`, "The screen: two screen pages and a page flip".

Do not use: buffer swap, vsync.

### Compositor

The compositor is the service that owns the display: it combines the surfaces of the programs into the framebuffer and routes the input to the program that has the focus.

The compositor is the one program that writes the screen. It draws the background, the bar, each window with its title bar, the menus, the palette and the pointer, and only the damage rectangles of a frame. It sends each key to the program in front, and each pointer event to the program of the surface under the pointer. Today it is also the desktop shell. The compositor is not a display server with a protocol of drawing: a program gives it pixels, never commands to draw.

The design: `docs/ARCHITECTURE.md`, "U8. Graphics: WebGPU library and compositor".

Do not use: window manager, display server.

### Damage rectangle

A damage rectangle is a rectangle of the screen or of a surface that changed and that the next frame draws again.

To draw only what changed costs much less than to draw the whole screen. The compositor keeps a few damage rectangles and joins a rectangle that touches another. A program sends the rectangle that changed in its picture with `display.present_rectangle`. The interface package finds the damage rectangles of a window itself, by damage by difference. A damage rectangle is never too small: if a rule cannot say what changed, the damage is larger, and only the time grows.

The design: `docs/INTERFACE.md`, "2.2 Damage by difference".

Do not use: dirty region, invalid area.

### Boot display

The boot display is the picture of how the machine started, drawn from the boot record and the other records of the kernel.

The boot display shows each stage of the start and its time, the memory, the firmware, the processors, the programs and the modules of the boot image. Three programs draw it with one package, `src/library/support/bootscreen`: the boot program, the root service while it starts the first programs, so that a failure stays on the screen with its cause, and the program `boot`. The boot display is not a splash screen and not a log of text: it is made of cards with measures.

The design: `docs/DESIGN.md`, "12. The card of the boot image".

Do not use: splash screen, boot log, POST screen.

### Console

The console is a normal program that calls commands, functions with typed parameters and a typed result, in a small programming language.

The console replaces the shell: a command is an export of a module, so its arguments and its result are typed values. The console has a terminal and no surface, and acts for the principal of its session. Examples: `grants("notes")` shows the grants of a program; `load("calendar")` loads a module into the console and calls its exports directly. The console is not a TTY and not a shell: it starts no program by a path, passes no text between programs, and has no pipe.

The design: `docs/CONSOLE.md`, "The language of the console".

Do not use: TTY, shell.

### Desktop shell

The desktop shell is the program that starts programs and shows their windows to the principal.

In the first version, the compositor is the desktop shell: its bar has the menu of the programs and the menu of the windows, the palette starts a program and reaches a window, and the close button of a window stops its program. It starts a program by the command `Start` to the root service, which decides the grants of the program. The desktop shell is not a window manager with rules of placement: the compositor places new windows at fixed steps on the grid.

The design: `docs/ARCHITECTURE.md`, "U10. Desktop shell".

Do not use: window manager.

### Focus

The focus is the state of the window in front: its program receives the keys, and its title bar shows it in blue.

The focus decides where each key goes. A press on a window, or a line of the menu of the windows, brings it to the front and gives it the focus. While the palette is open, no program receives a key. Inside a window, the interface package has a focus of its own: the element that takes the keys, which Tab moves. The focus of the compositor chooses a window; the focus of the interface state chooses an element in it. No program can give itself the focus.

The design: `docs/INTERFACE.md`, "4. Input and focus".

Do not use: active window, keyboard owner.

### Title bar

The title bar is the top part of the frame of a window, 24 pixels high: the title and the close button.

The title bar says which window has the focus: its title bar is blue with a white title, and the title bar of another window is a quiet grey with a dim title. The close button at its right end is a deep red square, the color of the concept "stop a program": a press on it stops the program of the window. A drag of the title bar moves the window. The compositor draws the title bar, not the program: a program cannot hide the close button.

The design: `docs/DESIGN.md`, "Windows".

Do not use: header, caption, decoration.

### Bar

The bar is the line at the top of the screen that the compositor draws: the mark of the system, the buttons of the two menus, the key of the palette, and the clock.

The bar is the fixed place of the desktop where the input starts a program or finds a window. A press on a button opens its menu under it. `src/library/support/bar` holds the places of the buttons and of each line of the menus, and the table of the names of the programs, `bar.names`: the compositor draws from it, and the modus tool presses the same places in the machine tests. The bar is not a task bar and not a dock: it holds two menus and no state of a program.

The design: `docs/DESIGN.md`, "Background and bar".

Do not use: task bar, panel, dock.

### Bar layout

The bar layout is the widths of the texts of the bar, measured in the font that draws them, from which come the place of each button and of each line of a menu.

The names of the bar are in the interface font, which has proportional widths. With places from a fixed width, a press can land beside the entry that the eye sees. So the compositor measures `bar.Layout` at its start and when the font changes, and writes it on the log. The modus tool measures the same layout from the same glyph cache, so it presses the right places. The bar layout is not a set of constants: it depends on the font in use.

The design: `docs/FONTS.md`, "12.8 The parts, each one working".

Do not use: bar geometry, bar metrics.

### Menu of the programs

The menu of the programs is the menu of the bar with one line for each name of the table `bar.names`: a press on a line starts that program.

The menu is the way of the pointer to start a program. It is a card under the button `programs`, in two columns. A press sends `Start` with the name to the root service, which decides the grants of the program. The menu of the programs is not the palette, which the key super opens and which narrows as the input types. It is not a start menu with folders: it has one flat table.

The design: `docs/DESIGN.md`, "Menus".

Do not use: start menu, application menu.

### Menu of the windows

The menu of the windows is the menu of the bar with one line for each window: a press on a line brings the window to the front and gives it the focus.

The menu lets the input reach a window that other windows cover. It lists the windows in the order of the client table of the compositor, and marks the window that has the focus. The line of a disk program has its nickname and the hash prefix of its file. The menu does not move a window. The menu of the windows is not a task switcher with pictures of the windows, and not a task bar.

The design: `docs/DESIGN.md`, "Menus".

Do not use: task bar, window list, switcher.

### Palette

The palette is the panel that the key super opens, where the input types a part of a name and chooses one entry of one list: a program to start, a window to bring to the front, or another operation.

The palette is the way of the keyboard to each operation of the desktop. The compositor draws it and holds its state; the panel holds no right of its own. The list ranks the palette entries by the fuzzy match of the console. Example: the key super, "pla", Enter starts `plasma`. The palette is not a run dialog: it runs only its entries, never a path or a line of the console. It is not a set of colors either.

The design: `docs/DESIGN.md`, "Palette".

Do not use: launcher, command palette, everything palette, run dialog.

### Palette entry

A palette entry is one thing that the palette lists and that the input can choose: a name, a kind, and the fact that its icon says.

The entries are data: the panel only ranks, draws and dispatches them. An entry has a kind, which the row says by its kind icon and in words, a name that the typed part matches, and a fact that the color or the form of the icon says, such as "this entry destroys something". The compositor makes the entries from `bar.names`, its client table and the palette table, when one of them changes. The record is `palette.Entry`. A palette entry is not a command line: it holds no text that another program parses.

The design: `src/md/features/palette.md`.

Do not use: palette item, palette command, action.

### Kind icon

A kind icon is the small picture of one kind of thing, a grid of 12 by 12 square cells, that each display of the system and the site draw from one table.

It lets a reader tell a window from a program, or a handle from a number, before the reader reads a word. `src/library/support/kind_icons` holds the cells only, with no color: the display gives the color. The system draws a cell as a square of 1, 2 or 3 pixels, and the site draws the same cells in SVG, so an icon is never scaled by a filter. A kind icon is not the mark of the system, and it never stands alone: the row says the kind in words too.

The design: `docs/DESIGN.md`, "The icons of the kinds".

Do not use: glyph (for this), symbol (for this), pictogram, badge.

### Palette provider

A palette provider is a program that gives palette entries of its own to the panel and runs the one that the input chooses, with its own rights.

The provider keeps the rule that the panel holds no right: an entry runs in the program that gave it, with its grants. The console is the palette provider: it has the grant `Palette`, writes its commands and its settings in the palette table, and runs a chosen entry as a line. `revoke("console", "palette")` ends it, and the palette keeps the programs and the windows. A palette provider is not a plugin of the compositor: it runs in its own program, and draws nothing in the panel.

The design: `docs/CONSOLE.md`, "8. The palette provider".

Do not use: palette source, palette backend, palette plugin.

### Palette form

The palette form is the input band of the palette while it holds the call of a command with parameters: one typed field for each parameter.

The form lets the input give the arguments of a command without a line. Each field has the name and the kind of its parameter, and the palette provider gives its candidates. Tab takes a candidate or goes to the next field; Enter in the last field runs. The values go to the provider as typed values, and the provider builds the line. Example: `revoke(name: plasma, grant: log)`. The palette form is not an edit line: it holds no expression and no variable.

The design: `src/md/features/palette.md`, "The form of an entry, from its descriptions".

Do not use: dialog, prompt, argument box.

### Field control

A field control is the form in which the palette shows one field of a palette form, chosen from what the field is: a typed text, a typed Integer, a typed number with its unit, a list of candidates, or a row of buttons.

The field chooses its control, so no command needs a form of its own and a provider gives data only. One table of the code gives it (`palette.field_control`). Example: the field of `strategy(name: )` is a row of three buttons, `round_robin`, `fair`, `eevdf`, because its candidates are the only values of the parameter. A field control is not an element of the interface package: the palette draws it in its own panel, and a program cannot give the palette one.

The design: `src/md/features/palette.md`, "The form of an entry, from its descriptions".

Do not use: widget, input type.

### Setting row

A setting row is one row of the palette that holds every value of one setting: the name of the setting, then one button for each value, with a line under the value in use.

The row lets a principal see the values of a setting together and set one with one key. The palette provider writes one palette entry for each value, and the palette joins the entries of one setting into one row. Left and Right choose a value, Enter sets it. Example: `font  [vector] spleen`, with the line under the font in use. A setting row is not a palette form: it has no field and no typed value.

The design: `src/md/features/palette.md`, "The form of an entry, from its descriptions".

Do not use: radio group, toggle, option row.

### Palette table

The palette table is the memory object where the palette provider writes its entries, and which the compositor maps read-only.

The table carries data and no text of a line: for each entry its kind, its name, the kinds of its parameters and of its result, a help sentence and an act name. The compositor copies the table and checks each field of the copy before it uses it: a table that fails is no table. One ring goes with the table: the compositor names the chosen entry, and the provider answers in the result area. The palette table is not a call region: the compositor waits for no answer in its loop.

The design: `docs/CONSOLE.md`, "8. The palette provider".

Do not use: command table of the palette, entry file, palette registry.

### Interface package

The interface package is `src/library/support/interface`: the code that builds the window of a program as a draw table at each frame, lays it out on the grid, takes the pointer and the keys, finds the damage, and draws.

The package gives each program one way to draw its window by the design rules. It works in immediate mode: at each frame, the program calls an element procedure for each part of its window, such as `button`. Each call appends draw records and gives back what the input did to that element. The package allocates nothing, and an error is a value. Example: `disk`, `monitor` and the palette are drawn with it. The interface package is not a toolkit with objects, callbacks and a tree.

The design: `docs/INTERFACE.md`, "2. The model: an immediate pass over flat tables".

Do not use: toolkit, widget library, UI framework.

### Library module

A library module is a module that holds code that many programs import, in place of a package that each program compiles into its own file.

A package that many programs compile in is many copies of the same code, with no record of what each program holds. A library module is one file with one hash: the import table of each program names it, and a change of its code builds one module. Its exports are coarse: a call passes whole tables of the caller, by address, with no copy. Example: the drawing module. A library module is not a second kind of import: the loader binds it as each import.

The design: `docs/MODULE_CONTRACT.md`, "A library as a module".

Do not use: shared library, dynamic library, runtime library.

### Drawing module

The drawing module is the module `drawing`: the code that finds the damage between two draw tables and draws the records of a draw table into pixels, for each program that imports it.

It is the first library module. A window calls `damage_of_draw_table_10` once for a frame to get the damage rectangles, then `execute_draw_table_in_rectangles_10` once to draw the records in them, into the pixels of its surface. Each argument is memory of the program, passed by address. The 10 in the names is the version of the draw record. The terminal and the compositor draw through it too. The drawing module is not a render service: it runs in the program that calls it.

The design: `docs/INTERFACE.md`, "7. Where it lives: the elements in each program, the drawing in a module".

Do not use: renderer module, graphics library, render service.

### Draw record

A draw record is one thing to draw, in 40 bytes: a rectangle, a gradient, a run of text, a clip, a picture, a text grid or a line, with its place and its colors.

Records of one fixed size make the output of a frame plain data: a table that can be compared, measured, drawn again in a part, or tested. A record holds its kind, its rectangle, two colors, a range of bytes in the text table, and a part of the element identity that wrote it. The format has a version, `DRAW_RECORD_VERSION`, and the execution checks each record. A draw record is not a command to a graphics processor: it is drawn on the processor, in the memory of the program.

The design: `docs/INTERFACE.md`, "2.1 Draw record (format version 10)".

Do not use: draw command, display list item, primitive.

### Draw table

A draw table is the draw records of one frame of a window, the bytes of their texts and the cells of their text grids, and the picture memories that they name, in the memory of the program.

The draw table is what a frame produces. The program owns it (`Draw_Table` of `src/library/support/interface`) and keeps the table of the frame before, so that the next frame can find the damage by difference. A table that is full stops taking records and sets `full`; a record that names memory outside the table sets `refused`. Example: `interface_elements` draws a window of 68 records. A draw table is not a tree: its order is the order of the drawing, and two tables compare record by record at the same index.

The design: `docs/INTERFACE.md`, "2.1 Draw record (format version 10)".

Do not use: display list, command buffer, render tree.

### Window memory

A window memory is the record of a program that holds the drawing of one window and the memory of its two draw tables.

The program declares one for each window (`Window_Memory(RECORDS, TEXT)` of `src/library/support/interface`), with the capacity of each draw table in records and in bytes of text, and starts each frame with `window_frame_start`. The record is memory of the program, so the package allocates nothing. Example: `budget` keeps `window_memory: interface.Window_Memory(512, 8192)`.

A window memory is not the surface of the window: the pixels are in the memory object of the surface, which the compositor reads.

The design: `docs/INTERFACE.md`, "2.3 Memory of the caller, errors as values".

Do not use: window buffer, frame memory.

### Text grid

A text grid is a grid of text cells of a program (a character, reverse, a color, or a fill), drawn by one draw record.

A terminal changes many cells many times in one second, and one record for each cell makes a large table. So one text grid record names the whole grid. A cell holds one code point. `draw_text_grid` copies the cells into the text table of the frame, so the record holds values only, and the difference compares the cells: in each row, the span of the changed cells is damaged. The console draws no pixels: the text grid of the terminal draws it. A text grid is not a screen buffer of a text mode.

The design: `docs/INTERFACE.md`, "2.4 Text grid".

Do not use: character matrix, screen buffer.

### Picture record

A picture record is a draw record that shows the pixels of a picture of the program, with a generation that changes when the pixels change.

A program that computes or holds its own pixels, such as `life`, `paint` or `plasma`, puts its image in a draw table as one record. The record names its pixels by values: its picture memory, its first pixel, its stride and its size. The program raises the generation when its pixels change; with the same generation the record damages nothing. A picture record is not a picture of a surface: it shows a canvas that the program holds, inside its surface, and it holds no address.

The design: `src/md/api/picture.md`.

Do not use: image node, bitmap item.

### Picture memory

A picture memory is one run of pixels of a program in which picture records name their pictures by the index of a first pixel and a stride.

A description carries values only, so a picture record cannot name a canvas by its address. The draw table holds a list of picture memories, and a picture record names one by its number. `draw_picture(table, x, y, canvas, generation)` finds the memory that holds the canvas and writes the values. The compositor has one picture memory for each surface. A picture memory is not a surface and not a picture of a surface: it is memory of the program that its records show.

The design: `src/md/api/picture.md`.

Do not use: picture buffer, pixel pool.

### Line record

A line record is a draw record of a straight line between two points, with a thickness of 1 to 32 pixels and one color.

A line record draws the lines at an angle that the design rules allow, sparingly: a folded gap, a chart. `draw_line(table, from_x, from_y, to_x, to_y, thickness, color)` writes it. The execution in a damage rectangle draws the same pixels as a whole frame, and the damage is the rectangle that holds the whole path. A line record has no rounded ends, no antialiasing and no dashes. It is not a path with curves.

The design: `docs/INTERFACE.md`, "2.5 Line".

Do not use: stroke, path, polyline.

### Element

An element is a part of a window that one call of the interface package draws: a card, a line of a label and a value, a bar, a table, a button, a list with a choice, or a text input.

An element is a call, not an object: the program calls it at each frame with its area and its data, and gets back an `Element_Result` (pressed, has the focus, changed). An element that takes input also takes an element identity, so the interface state can follow it. Example: `button(frame, area, identity("start"), "start")` draws a button and says if the input pressed it. An element is not a widget: it does not live between frames, has no callback, and holds no copy of the data of the program.

The design: `docs/INTERFACE.md`, "2. The model: an immediate pass over flat tables".

Do not use: widget, control, component, view.

### Element identity

An element identity is a number that names one element from one frame to the next, made from a text: the focus and the state of the pointer follow it.

In immediate mode no object lives between frames, so the interface state needs a stable name for each element that takes input. `identity("list")` gives the 64-bit FNV-1a hash of the text. Two elements with one text have one identity; `identity_with(base, row)` and `identity_in(parent, name)` make them two. Each draw record keeps the low 32 bits of the identity that wrote it, so a tool can say which element changed.

An element identity is not a handle: it names nothing in the kernel and gives no access.

The design: `docs/INTERFACE.md`, "4. Input and focus".

Do not use: id, key, handle (reserved for the kernel).

### Act name

An act name is a text of at most 32 bytes that names what an element of a window or a palette entry acts on, such as `settings.set:font`.

An act name lets the palette go to the element of a window that does what an entry does. A program names an element with `element_act_name(frame, element, "settings.set:font")`, and the palette provider writes the act name of each entry. When an open window names the act name of the chosen entry, the palette offers "shift enter: go to", and the focus goes to that element. An act name is not an element identity: many programs can use one act name, and it names no rectangle.

The design: `docs/INTERFACE.md`, "4.2 Act names".

Do not use: action, anchor, target.

### Element name

An element name is a text of at most 32 bytes that names an element of a frame for a machine test, such as `watch` or `frame 0`, with the rectangle where it takes a press.

A machine test presses an element by its element name, so a change of the layout moves the press with the element. A button is named by its label; a program names another element with `element_name(frame, area, "frame 0")`. The window layer writes an element line when the rectangle of a name changes. An element name is not an element identity: the interface state does not follow it. It is not an act name: the palette does not read it.

The design: `src/md/infrastructure/test_pointer.md`.

Do not use: test id, locator.

### Action bar

An action bar is the band at the bottom of a window that names its keys: each item is the keycaps of one key combination, then the name of its action.

A window that the keyboard drives draws it with the element `action_bar`. A press on an item gives the program the key of the item, so the press and the key run one piece of code. When the items do not fit, the items of lowest priority go behind a button `more`. Example: the item `Backspace` back of `manual`. An action bar is not the bar of the desktop, and not a bar element. The action of an item is not an act name and not a palette entry.

The design: `src/md/features/action_bar.md`.

Do not use: toolbar, key hint line, shortcut bar, footer.

### Keycap

A keycap is the small rectangle that shows one key of a key combination in an action bar, with the name of the key on it: `Tab`, `Enter`, `Backspace`, or a triangle for an arrow key.

The keycaps of one combination stand side by side with a `+` between them: `Shift` + `Tab`. A keycap has a border of 1 pixel and the gradient of a card. The fonts have no arrow character, so the keycap of an arrow key draws a triangle of rectangles; `Page Up` is the word `Page` and the triangle.

A keycap is not a button: the item of the action bar around it takes the press.

The design: `docs/DESIGN.md`, "The action bar".

Do not use: key badge, key chip, kbd.

### Element line

An element line is the line of the log that says where an element with an element name is, or that it is gone: `interface: debugger_window: the element watch at x,y,width,height`.

A window writes it after a drawn frame in which the rectangle of the name is new or changed, and writes `the element <name> is gone` when its frame no longer has the name. A frame with no change writes no line. The compositor writes the element lines of the palette in pixels of the screen. The modus tool reads the last element line of an element before a press. An element line is not a contract between two programs: no program reads it.

The design: `src/md/infrastructure/test_pointer.md`.

Do not use: layout dump, element report.

### Interface state

The interface state is what the interface package keeps between frames, in the memory of the program: the element with the focus, the element under the pointer, the pressed element, the order of the focus, and the held part of a scroll bar.

The interface state is the only state of the package, and the program owns it. With it, a press and a release on one element press that element, and Tab and Shift+Tab move the focus in the order of the elements of the last frame. The order holds 64 elements (`FOCUS_ORDER_CAPACITY`). The interface state is not a retained tree of the window: it holds element identities only, and no copy of the data that the window shows.

The design: `docs/INTERFACE.md`, "4. Input and focus".

Do not use: UI context, retained state.

### Damage by difference

Damage by difference is the damage rectangles that the interface package finds by a comparison of the draw table of this frame with the draw table of the frame before.

Immediate mode has no tree whose nodes know what changed. The difference gives that back: `damage_by_difference` compares the two tables record by record at the same index. Two equal records damage nothing; two different records damage the old rectangle and the new one. A record added in the middle moves the records after it, so the damage is too large, never too small. The program never tracks damage by hand. Damage by difference is not an invalidation that a program calls.

The design: `docs/INTERFACE.md`, "2.2 Damage by difference".

Do not use: dirty tracking, invalidation.

### Scroll bar

A scroll bar is the element beside a view that shows a part of a longer content: it shows where the view is in the content, and the pointer moves the view with it.

Each scroll bar of the system is the element `scroll_bar`, and the scroll bars of the site have the same form, from one table of sizes and colors. Its parts are two arrow buttons, the track, and the thumb with its grip. A program gives the units of its content, the units in view and the first unit in view, and takes the new first unit. A scroll bar is not a bar element and not the bar of the desktop. It takes no key.

The design: `docs/DESIGN.md`, "The scroll bar".

Do not use: scrollbar (one word, outside a CSS name), scroll mark, scroller.

### Wheel notch

A wheel notch is one step of the wheel of a pointing device, toward the principal or away from the principal.

The pointer record carries the notches as a signed count. A notch toward the principal moves a view toward the end of its content, as the key Down does. The compositor gives them to the palette while it is open, else to the program of the window in front, when the pointer is over its surface: a window behind gets no notch. There, the scroll bar under the pointer moves its view by three lines for each notch. A wheel notch is not a button of the pointer, and not a count of pixels.

The design: `src/md/features/scroll_bar.md`.

Do not use: scroll event, wheel click, wheel delta.

### Scroll bar track

The scroll bar track is the part of a scroll bar between its two arrow buttons, on which the thumb moves.

Its length stands for the whole content. A press on it, before or after the thumb, moves the view by one page toward the pointer. It has a border of 1 pixel and a gradient across it. The word is the word of the design rules for the empty part of a bar (`colors.track`), and of the parts of a scroll bar in a style sheet.

The scroll bar track is not the whole bar: the arrow buttons are outside it.

The design: `docs/DESIGN.md`, "The scroll bar".

Do not use: trough.

### Thumb

The thumb is the part of a scroll bar that lies on its track and stands for the view: its length is the share of the content that the view shows, and its place is the place of the view.

A press on the thumb holds it, and it follows the pointer until the button goes up. It is at least 8 % of the track and 8 pixels long. A thumb longer than 20 pixels has a grip. Under the pointer it takes blue tones.

The thumb is not a thumbnail, which is a small form of a picture of the site.

The design: `docs/DESIGN.md`, "The scroll bar".

Do not use: handle (reserved for the kernel), scroller.

### Grip

The grip is the four short lines in the middle of the thumb of a scroll bar, across it.

It marks the thumb as the part that the pointer holds. Each line is 7 by 1 pixels, 1 pixel from the next. A thumb of 20 pixels or less has no grip.

The grip carries no fact and takes no input of its own: a press on it is a press on the thumb.

The design: `docs/DESIGN.md`, "The scroll bar".

Do not use: gripper, handle (reserved for the kernel), ridges.

### Arrow button

An arrow button is the square at each end of a scroll bar, with a triangle that points to that end: a press on it moves the view by one line.

While it is held and the pointer stays on it, the view moves again after 400 ms, then each 60 ms, by the clock of the system. At rest it shows its triangle only; with the pointer over the bar it has a border and a fill. A bar shorter than 42 pixels has no arrow button.

An arrow button is not the element `button`: it has no label, takes no focus and no key.

The design: `docs/DESIGN.md`, "The scroll bar".

Do not use: stepper, scroll arrow, spin button.

### Pointer

The pointer is the mark on the screen that the pointing device moves: a press acts at its place.

The compositor draws the pointer last, with the pointer picture of the pointer shape that it chose, and puts the hot spot of the picture at the place of the pointer. It sends each pointer event to the program of the surface under the pointer. In a machine test, `compositor.pointer()` gives the place and the shape of the pointer. The pointer is not the caret, which marks a place in a text. The system does not use the word "cursor" for either one.

The design: `docs/POINTERS.md`, "How the compositor draws the pointer".

Do not use: cursor, mouse cursor, mouse pointer.

### Pointer shape

A pointer shape is what the pointer shows, as one name of the system: `arrow`, `text`, `pointing_hand`, `move`, `wait`, and ten more.

One list of names lets any theme serve each program: a program asks for a name, and the theme gives the pictures. The compositor chooses the shape from what is under the pointer, such as `move` over a title bar. A program asks for a shape over its own surface with `display.pointer_shape_set`, and the compositor shows it only while the pointer is over that surface, so a program cannot change the pointer over another program. A pointer shape is not a file name of a theme.

The design: `docs/POINTERS.md`, "The pointer shapes".

Do not use: cursor type, cursor name, cursor kind.

### Pointer picture

A pointer picture is one image of one pointer shape at one nominal size, for one frame of an animation: its width, height, hot spot, delay and pixels with premultiplied alpha.

A pointer theme file holds the pictures of each shape, size by size. An animated shape has several frames, each with its delay: `wait` in the theme of the system has 16 frames of 60 ms. The compositor blends the picture over the screen with premultiplied alpha. A pointer picture is the one picture of the desktop that is not made of rectangles: the pictures of both themes have smooth edges and transparency.

The design: `docs/POINTERS.md`, "3. The format of the system: one pointer theme file".

Do not use: cursor image, sprite, icon.

### Hot spot

The hot spot is the pixel of a pointer picture that the compositor puts at the place of the pointer.

A press acts at the place of the pointer, so the hot spot is the pixel that "points": the point of the arrow, the centre of a crosshair. Each pointer picture has its own hot spot, inside its width and its height. A manifest gives it with `hot` in pixels of the smallest size; the tool multiplies it for the other sizes.

The hot spot is not the top left corner of the picture, except for the arrow.

The design: `docs/POINTERS.md`, "3. The format of the system: one pointer theme file".

Do not use: click point, hotspot, anchor.

### Nominal size

A nominal size is the size in pixels that a theme gives to a pointer picture, to choose among its sizes.

A theme has 1 to 8 sizes for each shape, in increasing order: the theme of the system has 24 and 48, the Posy theme 32 and 64. The frames of one size share one nominal size. The width and the height of a picture can differ from its nominal size.

A nominal size is not the width of a picture, and not a scale of the screen.

The design: `docs/POINTERS.md`, "3. The format of the system: one pointer theme file".

Do not use: cursor size.

### Pointer theme

A pointer theme is the pointer pictures of each pointer shape, with a name, a license and an attribution.

The system has two themes. The theme of the system is outlines that the tool draws at the build; it is always in the boot image. The Posy theme, "Posy's Cursor", comes from a build input of the development shell, and no release image holds it, because its license allows no public download. The Posy theme is the default when the build has its input. The setting `pointer_theme` chooses one of them. A pointer theme is not an icon theme: it holds the pictures of the pointer only.

The design: `docs/POINTERS.md`, "5. The two themes".

Do not use: cursor theme, icon theme.

### Pointer theme file

A pointer theme file is one pointer theme in the format of the system: a header, a table of shapes, a table of pictures, then the pixels.

One file for a whole theme lets a program map it read-only and read it in place, with no parse at run time. The format is `src/library/contract/pointer_pictures`. One function, `pointer_pictures.validate`, checks every field once; the tool and the compositor run it, and the compositor does not trust the file even from the root service. A pointer theme file is not an Xcursor file or a `.cur` file: the tool reads those formats only to make this one.

The design: `docs/POINTERS.md`, "3. The format of the system: one pointer theme file".

Do not use: cursor file, .cur, Xcursor file (for this).

### Pointer form

A pointer form is one set of the pictures of a pointer theme for one appearance of the desktop: the dark form for a dark desktop, the light form for a light one.

A pointer theme file holds one or two forms. The dark form of the theme of the system is a white fill in a dark edge, the light form a dark fill in a white edge, so the fill has a strong contrast on the surfaces of its appearance. A theme with one form, such as the Posy theme, gives it for both. A pointer form is not a pointer theme: the setting `pointer_theme` chooses the theme, the appearance chooses the form.

The design: `docs/POINTERS.md`, "3. The format of the system: one pointer theme file".

Do not use: cursor variant, dark cursor, mode (for this).

### Pointer manifest

A pointer manifest is a text file of the repository that says how the tool makes a pointer theme file: for each pointer shape, the files of an Xcursor theme or an outline, and the adjustments.

The manifest keeps the choices about a theme in text that a reader can review, with no JSON and no general parser. A shape has sources or an outline, not both, and a manifest names a color by its token, never by a value. `modustool pointers` reads it and writes the pointer theme file. An error gives the file, the line, the column and what was expected. A pointer manifest is not the `index.theme` of an icon theme: the system reads no file of a theme at run time.

The design: `docs/POINTERS.md`, "4. The manifest".

Do not use: config, recipe, index.theme.

### Premultiplied alpha

Premultiplied alpha is a form of a pixel whose red, green and blue are already multiplied by its alpha.

With premultiplied alpha, a blend is one multiplication for each channel: `result = source + destination * (255 - alpha) / 255`. Straight alpha needs three more multiplications for each pixel. The pixels of a pointer theme file have premultiplied alpha, the form of an Xcursor file, so the tool converts nothing. Premultiplied alpha is not straight alpha: a straight pixel with alpha 0 can hold any color, and a premultiplied one is all zero.

The design: `docs/POINTERS.md`, "3. The format of the system: one pointer theme file".

Do not use: straight alpha (for this).

### Resource

A resource is a file of the boot image that is not a module: data that a program reads in place, named by the hash of its bytes.

The resources are the pointer theme files, the glyph caches, the link pages of the manual, and the system description with its signature. Their table is apart from the table of the modules, so a reader of modules never takes a resource for a module. No program reads the resource table by itself: the root service finds a resource by its name, checks its hash, and gives one program a read-only mapping of it. A resource is not an asset that a program loads by a path: it has no path.

The design: `docs/ARCHITECTURE.md`, "U2b. Resources of the boot image".

Do not use: asset, data file, blob.

### Caret

The caret is the mark in a text input of the place where the next typed character goes.

The caret shows where the keys act. In the input band of the palette it is a bar of 4 by 32 pixels in the blue of the title bar, at the place of the typed part where the next character goes; in the edit line of the console the line editor keeps its place. A text input shows the caret only when it has the focus.

The caret is not the pointer: the pointer follows the pointing device, the caret follows the keys. The system does not use the word "cursor" for either one.

The design: `docs/DESIGN.md`, "Palette".

Do not use: cursor, text cursor, insertion point.

### Picker

The picker is the surface of the document service where the principal chooses a document; its result is a grant to the program that asked.

The picker makes the choice of the principal the grant: a program cannot list documents, and gets a handle to the one document that the principal chose. The document service records each grant, so that the principal can list and revoke it. The document service and its picker are not built.

The picker is not a file dialog that a program draws: it is the surface of another program, so the program that asks sees only the result.

The design: `docs/ARCHITECTURE.md`, "U6. Document service".

Do not use: file dialog, powerbox.

## Text

### Text encoding

The text encoding is the one form of a text in every contract of the system: UTF-8 with no control character, and a length in bytes.

Each record that two parties share holds its text in this form: a line of the log, the name of an object of a store, a `Text` of the module contract. A party checks a text from another party at its border with `text_encoding.text_valid`, and cuts a text only after a whole character (`complete_characters`). A capacity of a field is a count of bytes, not of characters. An identifier of the system (a module, an export, a setting, a program) stays in the visible characters of ASCII, so that it has one form only.

The design: `src/md/data/text_encoding.md`.

Do not use: charset, code page, string encoding.

### Code point

A code point is the number of one character of Unicode, from 0 to 0x10FFFF.

UTF-8 writes a code point in one to four bytes: the code point 233, é, is the two bytes C3 A9. The cell of a text grid holds a code point, so one cell is one character. The console command `character` gives the text of a code point. A surrogate (0xD800 to 0xDFFF) and a control character are code points that no text of the system holds.

The design: `src/md/data/text_encoding.md`.

Do not use: rune (outside the code), character number, Unicode value.

### Invalid sequence

An invalid sequence is bytes of a text that are no character of the text encoding: a broken sequence of UTF-8, or a control character.

The broken forms are an overlong form, a surrogate, a number above 0x10FFFF, a continuation byte with no first byte, and a sequence cut short; each is one byte long. The control characters are 0 to 31, 127 and 128 to 159: a terminal of the host acts on some. A border that checks a text refuses it (the palette table, the name of an object of a store), the kernel writes `?` in place of each of its bytes in a line of the log, and a reader that draws shows the replacement glyph.

The design: `src/md/data/text_encoding.md`.

Do not use: fault (for this), bad byte, mojibake.

### Replacement glyph

The replacement glyph is the outline of a box that a reader draws in place of a character that the font lacks and of an invalid sequence.

Code draws it in each font and at each scale, so no font needs a glyph for it: the box goes from the top of a capital letter to the baseline, inside one cell. A byte is never drawn as a glyph, so a reader always sees that a character is there. Text shaping places it as `REPLACEMENT_GLYPH`, with the advance of `0`. A character that no font of its fallback chain has draws it too, and so does a character whose outline the renderer refuses, at the advance of its font.

The design: `src/md/data/text_encoding.md`.

Do not use: tofu, missing glyph, question mark (for this).

### Font

A font is a set of glyphs of one design, with the measures that place them side by side.

The modus tool subsets each font file at the build and draws its characters into a glyph cache; a program draws a character past the cache from the font outlines of the boot image. The system has three fonts: Paper Mono, the monospace font of the cells; B612, the interface font; and Spleen 8x16, a bitmap font, the fallback with no valid glyph cache. A font here is one file of one weight: Paper Mono SemiBold is a font of its own, with its own cache.

The design: `docs/FONTS.md`, "6. The font file".

Do not use: typeface (for this), font face.

### Glyph

A glyph is the form of one character in one font.

The character is the number (the byte 0x30 is the character `0`); the glyph is the drawing of it. One character can have several glyphs in one font: Paper Mono has a plain zero and a slashed zero, and a font feature chooses between them. A glyph has an outline and an advance; in a glyph cache it is a box of words of coverage. A character past the glyph cache takes the glyph of the first font of its fallback chain that has it, else the replacement glyph.

The design: `docs/FONTS.md`, "5. The glyph cache".

Do not use: character (for the form), symbol.

### Outline

An outline is the set of closed contours of line segments and quadratic curves that bound a glyph or a pointer shape, in units of its font or of its design size.

The outline is what a TrueType font stores in its table `glyf`: points in units of the font, each on or off the curve. The renderer of `src/library/support/vector_font` cuts each curve into segments, scales the points to the grid, applies the grid fit, and accumulates the coverage of each pixel in fixed point. A pointer shape of the theme of the system is also an outline, written in its pointer manifest, and the same renderer draws it. The modus tool reads no outline of CFF (cubic curves) and no SVG file.

The design: `docs/FONTS.md`, "4. Fixed point".

Do not use: path, vector shape, Bézier.

### Coverage

Coverage is the part of a pixel, or of a third of a pixel, that a glyph covers, from 0 (none) to 255 (all).

The renderer computes the coverage of each third of each pixel from the outline. The glyph cache keeps one word for each pixel: the coverage of the red, green and blue subpixel band, and the coverage of the whole pixel for grayscale. The blend mixes the color of the text with the pixel under it, channel by channel, in linear light. Coverage is not an alpha of a picture: an alpha is one premultiplied value for the whole pixel, and coverage is one value for each band.

The design: `docs/FONTS.md`, "3. Subpixel bands".

Do not use: alpha (for this), opacity, mask.

### Subpixel band

A subpixel band is one of the three color stripes of a pixel of the screen, red, green and blue side by side, for which the vector font has a coverage of its own.

With a coverage for each stripe, an edge of a glyph can sit on a third of a pixel, and a stem looks sharp at small sizes. A filter spreads each third over its neighbours, so that a side of a stem does not show one color alone. The order of the stripes is the setting `subpixel_order`: `rgb` (the default), `bgr` or `none` (grayscale); the system cannot read the order of the panel. Enlarged, a screenshot shows orange and blue edges on each letter: that is the bands at work, not a fault.

The design: `docs/FONTS.md`, "3. Subpixel bands".

Do not use: subpixel, ClearType, LCD stripe.

### Grid fit

Grid fit is the move of the baseline, the x-height and the cap height of a font onto whole pixels, so that the tops of the letters are sharp.

At 13 to 14 pixels to the em, the tops of the letters fall between two rows, and a row of half coverage under each top makes the text soft. The grid fit puts the baseline on a whole pixel, moves the x-height and the cap height to the nearest whole pixel, and scales the points between them (`vector_font.place_y`). The vertical stems need no fit: the subpixel bands place them. The system has no other hinting. The grid fit is the setting `grid_fit`: `on`, the default, or `off`.

The design: `docs/FONTS.md`, "Grid fit (the hinting of this system)".

Do not use: hinting (alone), autohint.

### Glyph cache

A glyph cache is a file that holds the glyphs of one font already drawn, as words of coverage, for each character 32 to 126, each character U+00A0 to U+00FF and the euro sign at each scale of the grid.

It moves all the work of a font out of the programs: the modus tool builds it, and the boot image holds it as a resource. The root service checks its hash once, and maps it read-only at a fixed range in each program with a surface. A program validates it once, then each draw reads the words of a glyph with no other check. No program writes it. It is not an atlas of a GPU and not a cache that fills on demand.

The design: `docs/FONTS.md`, "5. The glyph cache".

Do not use: atlas, texture cache, glyph bitmap.

### Added character

An added character is a character past U+00FF that each font of the system draws, named one by one in a list of the glyph cache contract.

The fonts hold two ranges, ASCII 32 to 126 and the Latin-1 Supplement, and the added characters. Today the list `glyph_cache.added_characters` holds the euro sign U+20AC alone, which AltGr with `e` types on the layout of France. A character joins the list only if each font of the system has a glyph for it, and each change of the list is a new version of the glyph cache. The build refuses a font that lacks one: no font draws it with the glyph of another character.

The design: `src/md/data/text_encoding.md`.

Do not use: extra character, extended range.

### Character index

A character index is the number of a character in each table of a font of the system: 0 to 94 for the characters 32 to 126, then 95 to 190 for U+00A0 to U+00FF, then 191 and up for the added characters.

The fonts hold these two ranges and the added characters, so the numbers name each character that a font draws, with no hole: the control characters 127 to 159 have none. A glyph cache keys its glyphs, its advances and its pairs by it, and so do the Spleen data and a placed glyph. `glyph_cache.character_index` gives the number of a code point, and `glyph_cache.character_of_index` the code point of a number. Another code point has no character index: it is a glyph of its fallback chain, or the replacement glyph.

The design: `src/md/data/text_encoding.md`.

Do not use: glyph id (for this), glyph number, character offset.

### Proportional cache

A proportional cache is a glyph cache of a proportional font: each character has its own advance, each glyph is the box of its ink at each subpixel position, and the cache holds the pair adjustments.

The header flag `FLAG_PROPORTIONAL` marks it. One format serves both kinds of font, and the flag says which rules `validate` applies. A proportional cache keeps three subpixel positions at scale 1, the box of the ink of each glyph, the advance of the font in 1/64 of a pixel, and the sorted pairs. A text of cells refuses it, because its glyphs pass their cells. The two caches of B612 are the resources `interface_glyph_cache` and `interface_glyph_cache_bold`.

The design: `docs/FONTS.md`, "12.4 The glyph cache with subpixel positions".

Do not use: proportional font cache.

### Font service

The font service is the program `glyphs`: it draws the fixed subsets past the glyph caches into the demand cache at its start, then ends.

It reads the font outlines of the boot image and draws each character of the subset of each demand face, in a fixed order, so the demand cache holds the same entries whatever the programs draw. Then it writes on the log what each fallback chain lacks, and ends with the code 0. The root service starts it with the demand cache with Write. Nothing goes from a program to it, and a program never waits for it: a program draws each glyph that the demand cache does not hold itself.

The design: `src/md/features/glyphs_on_demand.md`.

Do not use: font server, rasterizer service, glyph daemon.

### Demand cache

The demand cache is the memory where the font service writes the glyphs of the fixed subsets past the glyph caches, and which each program that gets the glyph caches maps read-only.

It holds a header with a generation, a hash table by face and code point, and words of coverage in the form of a glyph cache (`src/library/contract/demand_cache`). The font service writes an entry, then its key, then the generation; an entry never changes after that. A program copies and checks each entry before it draws a word of it. Its entries do not depend on what the programs draw, so it tells no program what another draws. It is not a glyph cache: it changes while a program reads it.

The design: `src/md/features/glyphs_on_demand.md`.

Do not use: atlas, shared glyph cache, dynamic cache.

### Font outlines

The font outlines are one resource of the boot image that holds the font files of the system, from which each program draws the glyphs past its glyph caches.

The resource is `font_outlines` (`src/library/contract/font_outlines`): a header, one record for each font with the BLAKE3 hash of its file, then the font files of the glyph caches. The root service checks its hash once and maps it read-only at the fixed range `Font_Outlines` in each program that gets the glyph caches, and in the font service. A program validates its header once. The font outlines are not a glyph cache: they hold outlines, not drawn words.

The design: `src/md/features/glyphs_on_demand.md`, "Layer 0: the outlines, shared and read-only".

Do not use: font bundle, font pack.

### Fallback chain

A fallback chain is the list of fonts, in order, that give the glyph of a character past the glyph cache of a face: the first font of the list that has the character gives its glyph and its advance.

The chains are data, one row for each script (`fallback_glyphs.scripts`): Greek, Cyrillic, the box-drawing characters and the block elements, and a default chain for each other character. The first font of each chain is the font of the glyph cache of the face, and a glyph of another font stands on its baseline, with its capitals as high. A character that no font of its chain has draws the replacement glyph. The chain of the interface is B612 then Paper Mono; the chain of the cells is Paper Mono then B612.

The design: `src/md/features/glyphs_on_demand.md`, "The fallback chain by script".

Do not use: font stack, font fallback list.

### Fallback face

A fallback face is a glyph cache of the system that a glyph past it stands beside: B612 Regular, B612 Bold, Paper Mono with and without the grid fit, and Paper Mono SemiBold.

A glyph past the cache has the form, the baseline and the scale of the glyphs of that cache: a glyph of a face of cells stays in its cell, and a glyph of the interface is the box of its ink at a subpixel position. A program finds the face of a glyph cache by the hash of its font file and its flags (`fallback_glyphs.face_of_cache`). Each face has its fallback chain. A fallback face is not a demand face, which names a fixed subset of the demand cache.

The design: `src/md/features/glyphs_on_demand.md`, "The fallback face".

Do not use: font face (for this), font slot.

### Private glyph cache

The private glyph cache is the memory where a program keeps the glyphs past the glyph caches that it drew itself, which no other program reads.

A glyph is drawn at its first use and kept; a new glyph that finds no room evicts the glyphs used the longest time ago, counted in frames of the program. The budget of the program pays for it. A program that draws through the drawing module has two: the one of the module and its own. It holds no advance: that comes from the font file. It is not the demand cache: it is not shared, so its content and its evictions tell no program what another draws.

The design: `src/md/features/glyphs_on_demand.md`, "Layer 2: the private glyph cache".

Do not use: glyph atlas, local cache, per-program cache.

### Demand face

A demand face is one glyph cache of the boot image that the glyphs of the demand cache stand beside: a font file in one form of glyph cache.

The demand cache keeps the glyphs of each face apart, because a glyph past the glyph cache must have the form, the baseline and the scale of the glyphs beside it. There are four: `Interface` (B612 Regular), `Cells` (Paper Mono with the grid fit), `Cells_Without_Grid_Fit` and `Cells_Bold` (Paper Mono SemiBold). Each face has a fixed subset, as the Greek letters of B612 for `Interface`. A demand face is not a font file: `Cells` and `Cells_Without_Grid_Fit` have one font file.

The design: `src/md/features/glyphs_on_demand.md`.

Do not use: font slot, font index.

### Setting

A setting is one choice of the principal of the machine that each program follows: the font, the order of the subpixel bands, the pointer theme, the grid fit, the layout of the keyboard, the appearance or the time zone.

Each setting is one value of the settings page, with 0 as its default: `font`, `subpixel_order`, `pointer_theme`, `grid_fit`, `keyboard_layout`, `appearance`, and `time_zone`, a fixed offset from UTC. The program `settings` is the one writer: its window, `settings.set(name, value)` and `settings.get(name)`. A caller that does not act for the principal gets `No_Grant`. A change takes effect while programs run, and the values survive a stop in the private store of `settings`. A setting is not a configuration file of one program, and the scheduling strategy is not a setting.

The design: `docs/FONTS.md`, "7. The setting".

Do not use: preference, option, configuration.

### Dead key

A dead key is a key of a layout of the keyboard that gives no character itself, and puts its accent on the character of the next key.

The layout of France has four: the circumflex and the diaeresis on the key right of P, and the tilde and the grave accent with AltGr. `^` then `e` gives ê, because the words of French need accented letters that the keyboard has no other key for. A space after a dead key gives the accent alone; a key with no accented form gives the accent, then its own character. The input service keeps the accent that waits; the tables are in `src/library/support/keyboard_layout`.

The design: `src/md/features/keyboard_layout.md`.

Do not use: compose key (for this), accent key, modifier (for this).

### AltGr

AltGr is the right Alt key of the keyboard, which gives the third level of the layout of France: a third character of a key, after the character without Shift and the character with Shift.

With the layout of France, AltGr with the keys of the row of the digits gives the characters that an AZERTY keyboard prints on their right side, as `#`, `{` and `@`; with the key of `e` it gives the euro sign €. AltGr with the key of 2 or of 7 is a dead key. The left Alt key, and Control with Alt, are not AltGr. With the layout of the United States, AltGr changes no character. The key record carries the character of the third level, and no modifier bit of AltGr.

The design: `src/md/features/keyboard_layout.md`.

Do not use: Option, level-3 shift, compose key (for this).

### Settings page

The settings page is the one page of memory that holds the current value of each setting, which each program with a surface reads.

The root service creates the page. The program `settings` receives it with Write; each program with a surface, each terminal and the compositor map it read-only at the fixed range `Settings_Page`. The page holds the choices and the appearance in force only: no address, no size and no hash of a glyph cache, so its writer cannot point a program at memory that it controls. A reader reads again while the change count is odd. It is not a registry and not a file: a record in the store of `settings` survives a stop.

The design: `docs/FONTS.md`, "7. The setting".

Do not use: registry, config file, dconf.

### Appearance

An appearance is one value of each color token: the desktop has two, dark and light.

The dark appearance is the one of the boot display: light text on a dark background. The light appearance is the light form of the site: dark text on a light background, white cards, each concept at a darker shade of its accent. The setting `appearance` chooses `dark`, `light`, or `auto`: the light appearance from 07:00 to 19:00 of the local time and the dark one at night. A picture keeps its pixels in both, and the boot display is always dark.

The design: `src/md/features/appearance.md`.

Do not use: theme (for this: a pointer theme is a set of pointer pictures), dark mode, light mode, skin.

### Appearance in force

The appearance in force is the appearance, dark or light, that each program draws now.

It is one word of the settings page. With the setting `dark` or `light` it is that value; with `auto` it is the value of the rule of the day at this moment, which `src/library/support/appearance` computes from the date page. The program `settings` writes it with each change of the values, and the root service writes it at 07:00 and 19:00 of the local time. A program reads it at each frame through `src/library/support/display`, which gives it to `graphics.appearance_use`; the compositor sends `Settings_Changed` to each window when it changes, so each window draws once.

The design: `src/md/features/appearance.md`.

Do not use: current theme, active mode.

### Color token

A color token is a named color of the design rules that has one value in each appearance: a surface, a concept or a part of the desktop.

`graphics.Color_Tokens` holds each token; `graphics.colors` holds their values in the appearance in force of a program, so a drawer writes `graphics.colors.text` and draws the text of the dark or of the light appearance. The `DARK_` constants of the package are the values of the dark appearance, for constant tables and for what is always dark (the boot display, the mark). White, black and the ink of a text on white are not tokens: they are the same in both appearances.

The design: `src/md/features/appearance.md`, and `src/library/support/graphics/rules.odin`.

Do not use: palette color (the palette is a panel of the desktop), design token, swatch.

### Series color

A series color is one of eight color tokens that tell apart the members of one series: several things of one kind that no concept of the design rules tells apart.

A member takes the series color of its number (`graphics.colors.series[number]`), and a ninth member takes the first color again. The threads of `processors` and the records of `rings` are series. A series color is never the only sign: a number or a word names the member. A record of `rings` carries its series number, not its color, so that it keeps its member when the appearance changes. A series color is not a concept: a thread of a series is not the kernel because it is blue.

The design: `src/md/features/appearance.md`, "The colors of the programs".

Do not use: identity color, tint, palette, hue (for this).

### Warning color

The warning color is the color token of a state that asks for attention and is not a failure.

A record of the log of the level Warning and a ring of `rings` that is full have it (`graphics.colors.warning`). It is a yellow apart from the orange of the boot program, so that "starts" and "take care" are two colors; a failure has the color `failed`. A warning color is never the only sign: the level or a word says the state.

The design: `src/md/features/appearance.md`, "The colors of the programs".

Do not use: caution color, alert color.

### Link color

The link color is the color token of a link: a name in a page that leads to another page.

`manual` draws each link of a page in it (`graphics.colors.link`). A link has the band of the track when it has the focus, so the link color keeps 4.5 to 1 on the track as on the background and a card, in both appearances. The site draws a link in the text color with a line under it: its pages have a form of their own.

The design: `docs/DESIGN.md`, "5. Text", and `src/md/features/appearance.md`.

Do not use: hyperlink color, accent (for this).

### Monospace font

A monospace font is a font whose characters all have one advance, so that a text is a row of equal cells.

The system has two: Paper Mono and Spleen 8x16. The font of the cells is monospace because the grid of the system is cells of 8 x 16 pixels: the terminal fills one cell and draws one character, and a glyph never leaves its cell. A text stays monospace when it is a grid of cells, or when a reader compares it character by character or copies it: hashes, addresses, code, a log record. A text that names or explains is in the interface font.

The design: `docs/FONTS.md`, "12.6 Which text stays monospace".

Do not use: fixed-width font (for this), terminal font.

### Interface font

The interface font is the proportional font of the titles, the labels, the buttons, the menus and the bar: B612.

B612 has 19 different advances in ASCII, and all its digits have one advance, so a column of numbers aligns in it too. Its Bold weight has scale 1 only, for titles. A program uses it through `src/library/support/interface`: an element that names or explains draws an `Interface_Text` record, which text shaping places with a proportional cache. The bar and the menus use it too. If its caches are absent or refused, or if the setting `font` is `spleen`, each element draws in the font of the cells.

The design: `docs/FONTS.md`, "12. The interface font and the text shaping module".

Do not use: UI font, system font (for this), sans.

### Interface text

An interface text is a text that a draw table draws in the interface font: the draw record `Interface_Text`.

Its rectangle is the measured box of the text widened by the ink margin on each side, so the damage of the record covers every pixel of its ink. Its origin is `text_origin_thirds` thirds of a pixel (0, 1 or 2) after `x` and the margin, so a label can start between two pixels. The table shapes the text and draws its placed glyphs with `graphics.text_proportional`. A text in the font of the cells is the record `Text`.

The design: `docs/FONTS.md`, "12.5 What changes in `src/library/support/interface`".

Do not use: proportional text record.

### Font in use

The font in use is the font that actually draws a text of a draw table: the interface font when the table can draw it, else the font of the cells.

A text asks for the interface font, but three things make it fall back: the table has no interface font (an isolated call: the call host maps no glyph cache), the setting `font` is `spleen`, or the text is longer than 256 bytes (`INTERFACE_TEXT_LIMIT`). `interface.font_in_use` decides, and both the measure and the draw call it. So a text is always measured in the font that draws it, and an element never passes its box in either font.

The design: `docs/FONTS.md`, "12.5 What changes in `src/library/support/interface`".

Do not use: effective font.

### Advance

The advance of a glyph is the distance from its origin to the origin of the next glyph, before any pair adjustment.

In a monospace font the advance is one constant: 8 pixels at scale 1. In a proportional font each character has its own: in B612, `i` is 600 units and `M` 1800. The glyph cache keeps the advance of each character at each scale in 1/64 of a pixel. The advance is not the width of the ink: a glyph can have ink before its origin or past its advance, and the ink margin covers that difference.

The design: `docs/FONTS.md`, "12.4 The glyph cache with subpixel positions".

Do not use: width (for this), pitch.

### Pair adjustment

A pair adjustment is the change of the advance that a font gives for one pair of glyphs that follow each other.

Some pairs look too far apart with their advances alone: `T` before `o` leaves a gap under the bar of the T, so the font states a negative adjustment for that pair. The tool reads the pairs from the table `kern` and writes them, sorted, in 1/64 of a pixel, into the proportional cache. Text shaping adds the rounded advance and the rounded adjustment. A monospace cache has no pairs.

The design: `docs/FONTS.md`, "12.1 What B612 has, read in its files".

Do not use: kerning pair (for this).

### Font feature

A font feature is a named choice of glyph forms that a font offers in its table `GSUB`, by a tag of four letters.

Examples: `zero` (the slashed zero), `ss01` (a stylistic set), `numr` (numerators). A feature leads to one or more lookups, and each lookup changes glyphs. The system uses one feature, `zero` of Paper Mono, and only at the build: the tool reads it with `vector_font.single_substitution` and draws its glyph for the character `0` in the subset. The subset holds no `GSUB`, and no program reads features at run time.

The design: `docs/FONTS.md`, "Paper Mono, the font of the system".

Do not use: OpenType feature (for this), font option.

### Single substitution

A single substitution is a lookup of the table `GSUB` that puts one glyph in the place of another (lookup type 1).

It is the simplest lookup: a coverage table lists the glyphs that it changes, and a delta or a list gives the substitute of each one. The feature `zero` of Paper Mono is one: it puts the glyph `zero.zero` in the place of the glyph of the character `0`. The system reads no other kind of lookup: no ligature, no contextual form.

The design: `docs/FONTS.md`, "Paper Mono, the font of the system".

Do not use: glyph swap, alternate.

### Slashed zero

The slashed zero is a zero with a stroke at an angle inside it, so that it does not look like the capital O.

The plain zero of Paper Mono has the same contours as its capital O, and a reader of a hash or an address cannot tell `0` from `O`. So the character `0` of the system is the slashed zero of Paper Mono: the modus tool reads the font feature `zero` and draws its substitute for `0` in the subset. Each picture of the system with a 0 shows it.

The design: `docs/FONTS.md`, "Paper Mono, the font of the system".

Do not use: crossed zero, zero with a slash.

### Text shaping

Text shaping is the step that turns the characters of a text into placed glyphs, with the advances and the pair adjustments of one font.

A proportional text needs it: the x of each glyph is the sum of the advances and adjustments before it. The package `src/library/support/text_shaping` does it for a direct call, and the module `text_shaping` exports the same work: `shape_text` gives the placed glyphs of one text, and `measure_texts` the width of many text ranges in one call. The module holds no font and no state: the caller passes the spacing. Text shaping here does advances and pairs only: no ligature, no other script, no line break.

The design: `docs/FONTS.md`, "12.3 The text shaping module".

Do not use: layout (for this), typesetting.

### Placed glyph

A placed glyph is a record of 16 bytes that text shaping gives for one character: the glyph, its x from the origin of the run, and its advance.

The fields of `text_shaping.Placed_Glyph` are `glyph` (the character index, a glyph of the fallback chain, or `REPLACEMENT_GLYPH`), `x` from the origin of the text and `advance` with the pair adjustment that follows it, both in 1/64 of a pixel, and `cluster`, the first byte of the character in the text. `graphics.text_proportional` draws a table of placed glyphs: it rounds each x to the nearest subpixel position. The x keeps the exact sum, so the rounding of one glyph never moves the next one.

The design: `docs/FONTS.md`, "12.3 The text shaping module".

Do not use: positioned glyph, glyph run entry.

### Ink margin

The ink margin is how far the ink of a text of a proportional font can pass the box that its measure gives, on each side: 2 pixels at scale 1 for B612.

A measure gives the sum of the advances, but ink can start left of the first origin (`j`) and pass the last advance (`K` in Bold), and the subpixel filter spreads it. The damage of an `Interface_Text` record is its measured box widened by `graphics.PROPORTIONAL_INK_MARGIN`, so a frame drawn in its damage equals a whole frame. The margin is a bound measured for B612: another interface font needs its own.

The design: `docs/FONTS.md`, "12.8 The parts, each one working".

Do not use: bleed, overhang (for this).

### Subpixel position

A subpixel position is the fraction of a pixel where a glyph starts: 0, 1/3 or 2/3 of a pixel in the glyph cache of a proportional font.

A glyph of a proportional font rarely starts on a whole pixel. With subpixel bands, the finest step that the screen shows is one third of a pixel, so a proportional cache keeps each glyph at scale 1 drawn at three positions. The draw rounds the x of each placed glyph to the nearest third (`glyph_cache.position_of`): the error is at most 1/6 of a pixel and does not add up along a text. At the scales 2 and 3, and in a monospace cache, the cache keeps one position.

The design: `docs/FONTS.md`, "12.4 The glyph cache with subpixel positions".

Do not use: subpixel offset, bucket.

### Spacing

The spacing is the two tables that text shaping reads for one font at one scale: the advances of the characters of a glyph cache and the pair adjustments, in 1/64 of a pixel.

`text_shaping.spacing_of` takes them from a validated glyph cache: 192 advances by character index and the sorted pairs (`glyph_cache.Pair_Entry`). The caller then passes them to `shape_text` or `measure_texts` as tables. So the module of text shaping holds no font, and an isolated call receives the spacing in its call region like the text.

The design: `docs/FONTS.md`, "12.3 The text shaping module".

Do not use: metrics (for this), kerning data.

### Text range

A text range is a record that names one text in a table of bytes by its first byte and its count, with its width, which the measure writes.

`text_shaping.Text_Range` has 16 bytes: `start`, `count` (at most `TEXT_LIMIT`) and `width` in 1/64 of a pixel. A window passes all its labels as one table of bytes and one table of ranges to `measure_texts`, which writes the width of each range: one call measures a whole frame (the direction Change of a table parameter). `interface.texts_measure` measures the lines of a list this way.

The design: `docs/FONTS.md`, "12.3 The text shaping module".

Do not use: span (for this), slice.

### Boot pass

The boot pass is the start of the program `settings` that the root service makes at the start of the machine, with no window, to put the kept settings on the settings page.

The settings survive a stop as one record (`Kept_Settings`) in the private store of `settings`. The root service cannot read the store itself, so it starts `settings` with the value 1 at `VALUE_BOOT_PASS` of its context. The program reads the record, writes the page, wakes the compositor and stops. A record of another version, or none, gives the defaults. Until the boot pass ends, the boot display and the first frames use the defaults; then each window draws again.

The design: `docs/FONTS.md`, "7. The setting".

Do not use: init script, startup hook.

### Blend table

A blend table is the results of the blend in linear light of one text color over one pixel color, for each coverage of each channel, kept in the memory of a program.

The blend of a partial pixel costs two squares and a square root for each channel. For one text color over one background color, each channel of the result depends on its coverage only: 3 x 256 values. A program keeps a few such tables (`graphics.Blend_Tables`), and fills a value on first use with the formula of the reference blend. A row of a glyph whose two end pixels have one color uses the table of that color. The result is the same bytes as the reference blend.

The design: `docs/FONTS.md`, "Where the time goes, and the fast blend".

Do not use: lookup table (alone), LUT.

### Markdown block

A Markdown block is one unit of the Markdown of a source comment that stands on its own rows: a paragraph, a list item, a fenced block or an example.

The reader of the system (`src/library/support/source_comment_markdown`) gives the blocks of a documentation text in order. A block is a range of bytes of that text, with its kind. A list item has its mark and its depth, a fenced block has the word after its opening fence, and a block says whether an empty line is before it. The Markdown spans of a block follow it. Example: `manual` starts a row for each block, and draws a band behind a fenced block. It is not a block of storage.

The design: `docs/SITE.md`, "The reader of the system".

Do not use: element, node (for this).

### Markdown span

A Markdown span is a run of bytes of a Markdown block with one set of styles: bold, italic, code, link.

A span has no mark: the stars, the backticks and the brackets are outside its range. A span can have several styles, and a span of a link names the bytes of its target. In a paragraph, a line feed in a span is one space; in a fenced block, a span is one line, kept as it is. Example: `manual` draws a bold span in the bold weight, a code span in the font of the cells, and a span of a link in the link color.

The design: `docs/SITE.md`, "The reader of the system".

Do not use: run (alone), token, inline.

### Link page

A link page is a page of the program `manual` for the target of a link that no module describes: a term of the glossary, a heading of a guide, or a declaration of the sources.

The documentation of a module links terms, headings of the guides and declarations of the support packages, but the manual reads only the boot image. So the build writes the page of each such target that the modules of the image link, in the resource `manual_pages`. The page of a term is its name, its short definition and its explanation; the page of a heading is its text and its subheadings; the page of a declaration comes from its source. A link page is not a copy of the site: it holds no picture.

The design: `src/md/features/manual_links.md`.

Do not use: document page.

### Text box

A text box is the place and the width that a window gives to one text: the text is drawn inside it, on one line or on more lines.

A text that is wider than its text box goes on more lines: a line ends at the last space that fits, and a word wider than the whole box ends a line after its last `/`, `:` or `_` that fits. No byte is left out, and the caller gives the box the height of its lines. Example: in `inspect`, a frame of a stop report takes three lines in a card. A text box is not a text grid, and not a cut, which ends with the cut mark.

The design: `docs/INTERFACE.md`, "The text in a box".

Do not use: label box, text area, text field (a text input is the element that takes typed text).

## Randomness

### Random seed

A random seed is the 32 bytes from which a random generator starts.

Each program needs unpredictable bytes (keys, nonces, the secret of the TCP sequence numbers), and the kernel gives none. So its starter writes 32 bytes of its own random stream in the context of the program, and the program reads them once with `random.generator_from_context`, which erases them. The root service has no starter: it gathers the seed of the system from the sources of the processor, and every other seed descends from it. A child has no secret from its starter, which already chooses its code and its grants.

The design: `docs/RANDOMNESS.md`, "1. Where a program gets random bytes".

Do not use: entropy (for this), salt.

### Random generator

A random generator is a record of fixed size in the memory of a program that gives it random bytes, with no kernel entry and no call.

It is `random.Generator` (`src/library/support/random`): ChaCha20 with fast key erasure, so a copy of its state after a draw does not give the bytes before it. `random.fill` draws bytes; `random.fill_for_a_key` draws a secret only above a least seed strength; `random.seed_for_a_child` seeds a child or a second thread. One generator belongs to one thread. It is not a kernel device and not a service: a kernel entry or a call for each draw costs too much on a hot path, and a shared pool is a shared state.

The design: `docs/RANDOMNESS.md`, "2. The generator".

Do not use: RNG, PRNG, CSPRNG (for this), /dev/urandom.

### Entropy report

The entropy report is the record of what the root service found when it gathered the seed of the system: which sources it read, how many of their values it took and refused, and the seed strength.

`random.Entropy_Report` holds the facts of `rdseed`, `rdrand` and the cycle counter. The root service writes it on the log, never the seed, and gives it to the program `randomness`, which shows it in its window. The report says what the sources gave. It does not estimate the entropy of the bytes: the system does not test the output of `rdseed` or `rdrand` for quality.

The design: `docs/RANDOMNESS.md`, "3. The seed of the system, and what is claimed".

Do not use: entropy estimate.

### Seed strength

The seed strength is the strongest source that gave all its values to the seed of the system: `entropy` (rdseed), `processor` (rdrand) or `weak` (the cycle counter only).

The strength is what the system claims about its seed, and no more: `weak` claims 0 bits, because the system does not measure the jitter of the cycle counter. A child has the strength of its starter. A program states the least strength that it accepts with `random.fill_for_a_key`: QUIC and TLS ask for `processor`, so with a weak seed a handshake gives `Seed_Too_Weak`. The system never refuses for the program: each program still starts and draws. The entropy device adds bytes and no claim.

The design: `docs/RANDOMNESS.md`, "3. The seed of the system, and what is claimed".

Do not use: security level.

### Entropy device

The entropy device is the random device of virtio that the machine can have (`virtio-rng-pci` in QEMU): one more source of the seed of the system, never the only one.

When the machine has it, the root service starts the entropy service and mixes its reads into its random generator with `random.device_bytes_mix`. The old key is always an input of the new one, so a hostile device cannot replace the bytes of the processor. A read that adds nothing counts as refused. The seed strength does not change. After the start, the root service reads it every 30 seconds for the fresh bytes refresh.

The design: `src/md/features/entropy_device.md`, and `docs/RANDOMNESS.md`, "3. The seed of the system, and what is claimed".

Do not use: RNG device, hardware RNG, /dev/random.

### Entropy service

The entropy service is the program `entropy`: the device service of the entropy device, with the root service as its one client.

It holds the registers, the interrupt and the queue of the device, and serves the entropy ring: one command `Read` gives a few bytes of the device. It does not test the bytes: the root service refuses a read that adds nothing. It is a program, not a part of the kernel, as each driver is.

The design: `src/md/features/entropy_device.md`.

Do not use: rng driver, entropy daemon.

### Entropy ring

The entropy ring is the ring between the entropy service and its one client, the root service: one command record is one read of the entropy device, and its completion record carries the bytes.

The root service makes it and gives it to the service in its context. The completion carries the bytes in its values, so the ring needs no region. An entropy ring is not a queue of the device: the device has its own queue, which only the entropy service sees.

The design: `src/md/features/entropy_device.md`.

Do not use: random ring.

### Fresh bytes page

The fresh bytes page is the page of one program, read-only at its fixed range, where the root service writes 32 bytes of its stream for that program alone after each fresh bytes refresh.

The random generator of the program reads the change count of the page at each refill and before a key or a child seed, and mixes a new change into its key once. A draw from the buffer reads no page. The page is not shared: a program that a reader took does not give the fresh bytes of the others. It is not a seed: the bytes only add to the key. A machine with no entropy device writes no page.

The design: `src/md/features/fresh_bytes.md`.

Do not use: entropy page, reseed page.

### Fresh bytes refresh

A fresh bytes refresh is one read of the entropy device that the root service mixes into its generator, then the write of the fresh bytes page of each program that has one.

The root service asks for one read every 30 seconds, with one read in flight at most. A read that adds nothing writes no page; after 3 in a row the root service asks for no more. A refresh wakes no program. It is not a reseed of each program at each draw: a program mixes the page at its next refill or key.

The design: `src/md/features/fresh_bytes.md`.

Do not use: reseed of a program, entropy refresh.

### Cryptography module

The cryptography module is the module `cryptography`: the cryptographic primitives that the system took from Odin's `core:crypto`, as exports that use the memory of the caller and give error records.

The system does not write cryptography from nothing: it takes proven code and changes only its shell, and `modustool cryptography-origin` proves each change. The module gives AEAD, SHA-256 with HMAC and HKDF, X25519, Ed25519, Argon2id and the masks of QUIC. It reads each byte of the caller once, erases its copies of a key, and draws no random byte: the caller passes each key and nonce. A program imports it by hash, and the console can call it.

The design: `docs/CRYPTOGRAPHY.md`, "6. The module `cryptography`".

Do not use: crypto library, libcrypto.

### Not authentic

Not authentic is the error kind of a sealed text whose tag does not verify, or of a message whose signature does not verify.

`Not_Authentic` (`src/library/contract/errors`) tells a caller that the bytes are forged, damaged or from another key, and it is the one answer: the call says nothing about which byte was wrong. A failed open leaves no byte of the text in the result. A point of small order given to `x25519` is `Bad_Value`, not `Not_Authentic`: it shares no secret, but it is not a forged text.

The design: `docs/CRYPTOGRAPHY.md`, "6. The module `cryptography`".

Do not use: MAC failure, bad tag.

### Compatibility layer

The compatibility layer is the packages of `src/library/support/cryptography` that give the code taken from Odin the helpers that it expects from its origin, over the primitives of this system.

The code of `core:crypto` imports helpers of the library of Odin. The system does not change that code: it changes only its import lines, so that they name the packages of the layer under the names of their origin. Those packages implement the helpers with the primitives of the system: the erase of a secret, for example, is one that the compiler cannot remove. A change of a file of the layer fails `modustool check` until its new hash is written.

The design: `docs/CRYPTOGRAPHY.md`, "3. The layout".

Do not use: shim, polyfill.

## QUIC

### Connection identifier

A connection identifier is the 0 to 20 bytes by which a QUIC endpoint names a connection in each packet, independent of the addresses.

UDP gives no connection, and its addresses and ports can change on the path. So each QUIC packet carries a Destination Connection ID, and the receiver finds its connection by it. Each side chooses the identifiers that the other side sends to it: a client of this system chooses 8 bytes, the OpenSSL client 0 bytes. The identifier also seeds the Initial keys. A server of this system finds the connection record by the identifier and the remote together, and drops the same identifier from another address or port. In the library an identifier is one record, `quic.Connection_Identifier`, which holds no identifier over 20 bytes.

The design: `docs/QUIC.md`, "The server of several connections".

Do not use: connection ID (in prose), CID.

### Packet protection

Packet protection is the AEAD that encrypts the payload of a QUIC packet and authenticates its header, with the key and the iv of one direction of one encryption level.

Each QUIC packet is sealed on its own: the nonce is the iv with the packet number, and the additional data is the header without header protection. Initial packets use AES-128-GCM; after the handshake this system prefers ChaCha20-Poly1305. `quic.datagram_take` copies each datagram once into private memory, and each later step works on that copy. A tag that does not verify gives `Not_Authentic`. It is not the record layer of TLS over TCP: QUIC carries the handshake in CRYPTO frames and protects whole packets.

The design: `docs/QUIC.md`, "3. Packet protection (the first layer, built)".

Do not use: encryption (for this), record protection.

### Header protection

Header protection is the mask that hides the low bits of the first byte and the packet number of a QUIC packet, made from a sample of the protected payload.

Without it, an observer reads the packet numbers and the key phase of every packet. The mask is 5 bytes, from AES or ChaCha20 over a sample of the protected payload. The cryptography module exports the two masks, and `src/library/support/quic` applies them to the first byte and the packet number. The receiver removes it first (`header_protection_remove`), with a key that does not change at a key update, then reads the key phase and chooses the keys for the open.

The design: `docs/QUIC.md`, "3. Packet protection (the first layer, built)".

Do not use: header encryption.

### Encryption level

An encryption level is one of the sets of keys of a QUIC connection: Initial, Handshake or Application.

The handshake moves through the levels, and each packet type uses one level. Any observer can compute the Initial keys from the connection identifier; the Handshake keys come from the handshake secrets of TLS, and the Application keys from its application traffic secrets. `quic.Encryption_Level` names the three, and the CRYPTO frames of each level carry their own sequence of handshake bytes. The Initial keys go when the client sends its first Handshake packet; the Handshake keys go when the handshake is confirmed. This system has no 0-RTT level.

The design: `docs/QUIC.md`, "What the transport does".

Do not use: epoch, key phase (for this).

### Packet number space

A packet number space is the sequence of packet numbers that one encryption level uses: Initial, Handshake or application data.

Each space has its own packet numbers, its own acknowledgements, its own set of received numbers and its own packets in flight. A packet number is unique in its space and never used again. An ACK frame acknowledges numbers of the space of its packet only. The packet number floor of a space refuses numbers that the set of received numbers forgot.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: sequence number (for this).

### Initial packet

An Initial packet is one of the first packets of a QUIC connection, protected with keys that any observer can compute from the connection identifier, which carries the start of the TLS handshake.

The keys of an Initial packet authenticate nothing: they come from a public value with a fixed salt of version 1, so anyone can make an authentic Initial. A server of this system therefore takes a client only after the client came back with the token of a Retry packet, and an Initial that does not complete its handshake ends at the handshake deadline. A datagram with a client Initial is padded to 1200 bytes, and a server drops a client Initial in a smaller datagram.

The design: `docs/QUIC.md`, "3. Packet protection (the first layer, built)".

Do not use: handshake packet (for this).

### Raw public key

A raw public key is a public key that a TLS peer sends in its Certificate message alone, with no certificate around it.

The server sends the SubjectPublicKeyInfo of its Ed25519 key, 44 bytes, and the client offers `server_certificate_type` with the one type RawPublicKey. No X.509 certificate is read: a parser of certificates is a large parser of hostile input, and the system has no certificate authority, no name and no date to check. The client trusts the key only when it is the pinned key, and CertificateVerify proves that the server holds its private key. A client proves its own key the same way when the server asks for it.

The design: `docs/QUIC.md`, "4. TLS 1.3 for QUIC (the second layer, built)".

Do not use: self-signed certificate (for this).

### Pinned key

The pinned key is the one public key that the caller of a TLS client gives it as the key of the server: the client refuses any other key.

`Tls_Configuration.server_public_key` holds it. A server that presents another key fails the handshake with the alert bad_certificate, and `tls_start` refuses a client with no pinned key. The peer of the modus tool pins the key that `remote` wrote on its log. A pin belongs to one start of the server: each start makes a new key. A pinned key is not a trust anchor: it vouches for no other key and names no one.

The design: `docs/QUIC.md`, "4. TLS 1.3 for QUIC (the second layer, built)".

Do not use: trust anchor, root certificate.

### Transcript

The transcript is the handshake messages of TLS, in order, whose hash the key schedule and the Finished messages use.

Each message of each side goes into the transcript as it comes. The key schedule hashes it at fixed points to derive the secrets, CertificateVerify signs its hash, and each Finished is an HMAC of it. So a change of one byte of one message by the path makes the two sides disagree and the handshake fail. The transcript holds 8192 bytes: a ClientHello of up to 4092 bytes and the flight of the server.

The design: `docs/QUIC.md`, "4. TLS 1.3 for QUIC (the second layer, built)".

Do not use: handshake hash (for the bytes).

### Key schedule

The key schedule is the chain of the secrets of TLS 1.3, each one derived from the one before with HKDF and a transcript hash: early, handshake, master, and the traffic secrets of each side.

The X25519 shared secret enters at the handshake secret; the hash of the transcript at each point binds the secrets to the messages. QUIC takes its packet keys from the traffic secrets: `tls_packet_keys` gives the Handshake and the Application keys through `packet_keys_from_secret`, with the labels "quic key", "quic iv" and "quic hp". The code is `src/library/support/quic/tls_key_schedule.odin`, tested against the trace "Simple 1-RTT Handshake" of RFC 8448. The secrets of TLS are erased once the 1-RTT keys are installed.

The design: `docs/QUIC.md`, "4. TLS 1.3 for QUIC (the second layer, built)".

Do not use: key derivation (for the whole).

### Alert

An alert is the reason of a failure of TLS, as one byte.

The handshake of this system writes the alert in `Tls_Handshake.alert` and in the `found` field of its error record. QUIC has no alert messages: it closes the connection with the error code 0x100 + alert. Examples: bad_certificate (42) for a key that is not the pinned key, unexpected_message for a message of the wrong type at its level, no_application_protocol for another ALPN.

The design: `docs/QUIC.md`, "4. TLS 1.3 for QUIC (the second layer, built)".

Do not use: TLS error (for this).

### Frame

A frame is one unit of the payload of a QUIC packet: a type, then its fields.

A packet carries one frame or more: STREAM frames with the data of a QUIC stream, ACK frames, CRYPTO frames with the bytes of the handshake, CONNECTION_CLOSE, and others. Each frame is read as hostile input, with each length checked first: a frame that is cut or of an unknown type is FRAME_ENCODING_ERROR. It is not the frame of the network device (an Ethernet frame), which the group "Devices" defines: a QUIC frame lives inside a protected packet inside a UDP datagram.

The design: `docs/QUIC.md`, "The frames".

Do not use: message (for this), chunk.

### Ack-eliciting packet

An ack-eliciting packet is a packet with a frame other than PADDING, ACK and CONNECTION_CLOSE, which the peer must acknowledge.

Only ack-eliciting packets count for loss detection, the probe timeout and the congestion window: a packet of ACK frames alone is never acknowledged and never sent again. In the 1-RTT space this side sends an ACK after 2 ack-eliciting packets or 25 ms. The first ack-eliciting packet sent after a receive moves the bound of the idle timeout.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: reliable packet.

### Probe timeout

The probe timeout is the time after which a side that received no acknowledgement sends one or two probe packets, computed from the round-trip time and its variation.

The base probe timeout is the smoothed round trip, 4 times its variation and the max_ack_delay of the peer: about 28 to 45 ms on a fast network. A probe carries the data of the oldest packets in flight, or a PING, and goes past the congestion window. The timeout doubles at each probe that nothing answers. The idle timeout and the closing and draining states use the base value with no doubling (`probe_timeout_base`), so a vanished peer cannot keep a record for hours.

The design: `docs/QUIC.md`, "What the transport does".

Do not use: retransmission timeout, RTO (for this).

### Congestion window

The congestion window is the most bytes of ack-eliciting packets that a side has in flight at one time.

It stops a sender from filling the path faster than the path drains. This layer keeps it fixed at 12 000 bytes (`CONGESTION_WINDOW`), the initial window of RFC 9002: it does not grow and does not shrink after a loss (no NewReno, no pacing). Probes go past it.

It is not the flow control limit: the congestion window protects the path, and the flow control limit protects the buffers of the receiver.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: send window (for this).

### QUIC stream

A QUIC stream is one ordered flow of bytes in each direction inside a QUIC connection, named by a stream identifier.

A connection carries several streams at once, and the bytes of one never wait for a loss of another, which TCP cannot give. This system has bidirectional streams only, and only the client opens them. A stream ends when both directions ended, and its identifier then never names a stream again. A program uses `stream_open`, `stream_write`, `stream_read`, `stream_reset` and `stream_stop_sending`; each stream lives in a stream record. Example: `remote` maps one call to one stream.

The design: `docs/QUIC.md`, "What the transport does".

Do not use: channel (for this), substream.

### Stream record

A stream record is one `quic.Stream` in the table that the caller of a QUIC connection gives: the state and the buffers of one open QUIC stream.

The caller allocates the table, in its own memory, with the connection; each record holds two buffers of 64 KiB. Their count bounds the streams that are open at one time, and a server gives the client a limit of streams equal to its records. When a stream ends, its record is free again and its buffers are written with zeros. A program must read each stream to its end: a stream that it never reads keeps its record for the life of the connection.

The design: `docs/QUIC.md`, "What the transport does".

Do not use: stream slot.

### Limit of streams

The limit of streams is the count of QUIC streams that one side allows the other to open since the start of the connection (MAX_STREAMS).

It is a count since the start, not a count of open streams. A server of this system gives the client a limit equal to its stream records, then raises it by one with a MAX_STREAMS frame each time a stream of the client ended, so the limit never promises a stream that has no record. A client that reaches the limit sends STREAMS_BLOCKED and waits; a frame for a stream past the limit is STREAM_LIMIT_ERROR. Example: a host that opens a 9th stream of `remote` waits for MAX_STREAMS.

The design: `docs/QUIC.md`, "What the transport does".

Do not use: stream credit, concurrency limit (for this).

### Implicit open

An implicit open is the open of a QUIC stream by a frame of the peer that names it, or names a higher stream of the same kind, before the peer sent anything on it.

Streams of one kind open in order, so a frame for client stream 8 also opens the client streams 0 and 4 that are not open yet. The limit of streams bounds that count: a stream far ahead within the limit takes records that exist, and one past it is STREAM_LIMIT_ERROR. The program finds the streams that the peer opened by a walk of `connection.streams`.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

### Flow control limit

A flow control limit is the largest offset of data that a side allows the peer to send, for one stream (MAX_STREAM_DATA) or for the whole connection (MAX_DATA).

It protects the buffers of the receiver: a side never receives more than it has room for. Here each stream has 64 KiB, moved forward when the application read half of it; the connection has the buffers of every stream record (256 KiB for 4), moved forward the same way. Data past a limit closes the connection with FLOW_CONTROL_ERROR; a final size that changes is FINAL_SIZE_ERROR. A reset counts its final size, and the bytes that the application never read give their room back to the connection.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: receive window (for this).

### Anti-amplification limit

The anti-amplification limit is the rule that a server sends at most 3 times the bytes that it received from a client whose address it did not validate.

An attacker can forge the source address of a datagram, and without the limit one small forged datagram can make a server send a large answer to a victim. The limit is held twice: by `src/library/support/quic` in the program, until the address validation of the connection, and by the network service, which knows no QUIC and refuses a Send past 3 times (the status `Amplification`) until the program sends the command `Validate`. A Retry packet answers a datagram of 1200 bytes with at most 113 bytes.

The design: `docs/QUIC.md`, "The listen grant of UDP".

### Address validation

Address validation is the proof that a client receives datagrams at the address that it claims.

Until it, a server holds the anti-amplification limit. A connection of this system validates the address of the client by a Handshake packet of the client, which needs the keys of the flight of the server, or by an Initial that carries the retry token of that address. Each record of `quic.Server` is validated at its start, because a record needs a token. The program then sends `Validate` to the network service for that remote, which makes it a validated remote.

The design: `docs/QUIC.md`, "The server of several connections".

### Handshake confirmed

Handshake confirmed is the point after which a side drops its Handshake keys: a server when its handshake completes, a client when HANDSHAKE_DONE comes.

Before it, a side can still need the Handshake keys to send the flight again. After it, those keys are erased, and a Handshake packet is dropped. A server sends HANDSHAKE_DONE in its first 1-RTT packet after the Finished of the client; a server that receives one gets PROTOCOL_VIOLATION.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: handshake done (for the state).

### Connection record

A connection record is one `quic.Connection` in memory of the program: all the state of one QUIC connection.

The record holds the packet number spaces, the keys, the handshake of TLS, the timers and the connection identifiers: no allocation and no kernel call happen behind it. Its streams are in a separate table of stream records. A record goes in global memory or in a mapping, never on a stack, which leaves too little room for the cryptography module. A server holds a table of records, and a record gets a new generation each time it is taken. It is not a socket: the network service sees only datagrams.

The design: `docs/QUIC.md`, "The server of several connections".

Do not use: session (for this), socket.

### Version Negotiation packet

A Version Negotiation packet is the packet with the version 0 that a server sends to a client whose long header names a version that the server does not speak: it lists the versions that the server speaks.

A server of this system speaks version 1 only. It answers a long header of another version in a datagram of 1200 bytes at least, with one packet of 51 bytes at most, and 16 in one second at most. The packet has no authentication; a client of this system speaks version 1 only and never needs one.

The design: `docs/QUIC.md`, "6. QUIC on the network (the fourth layer, built, with Retry and the budgets of work)".

Do not use: version error.

### Retry token

A retry token is the value that a server gives in a Retry packet and that the client sends back in its next Initial packet, to prove that it receives datagrams at its address.

The server seals with ChaCha20-Poly1305, under a key of its start, the original Destination Connection ID of the client, the identifier of the Retry and the time, with the remote address and port as additional data. The token does not open for another address or port, after another start of the server, or more than 10 s after the Retry. A token takes a record once. It is not the token of NEW_TOKEN, which a client of this system never keeps, and not a token of a token bucket.

The design: `docs/QUIC.md`, "The token of a Retry".

Do not use: cookie (for this), address token (for the token of NEW_TOKEN).

### Validated remote

A validated remote is an admitted remote of a UDP listen grant that the program marked with the command `Validate`, because it proved its address.

The network service then sends to it with no limit of 3 times the bytes that came from it. `quic_echo` and `remote` validate a remote when its client came back with the token of a Retry. A program that validates every remote can send any volume, for 120 s, to an address whose name came in one forged datagram; the principal revokes the grant of such a program.

The design: `docs/QUIC.md`, "The listen grant of UDP".

Do not use: trusted remote, whitelisted address.

### Stateless reset

A stateless reset is a packet that ends a connection whose state a side lost, proven by a token that the side gave before.

It is not built. A server of this system that restarts forgets its connections, and their clients end at their idle timeout. A connection drops a datagram of this kind.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: reset (for this).

### Handshake deadline

The handshake deadline is the time after which a connection whose handshake did not complete ends: 10 s from the start of a client, or from the first authentic Initial at a server.

Anyone can make an authentic Initial packet, so without a deadline a few packets could hold records of a server for the whole idle timeout. `HANDSHAKE_TIME_LIMIT` ends such a record whatever the idle timeout. A client has the same limit: a client that a server over a limit ignores ends at its own deadline. The deadline counts time of the machine: in `remote`, isolated calls count in it too.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: handshake timeout (for the value).

### Packet number floor

The packet number floor is the packet number below which a side refuses each packet of a space, because its set of received numbers forgot those ranges.

The set of received packet numbers keeps 32 ranges. When it drops its lowest range, it can no longer tell whether a number below it came before, so it raises the floor to the end of that range (`packet_number_floor` of a space). A packet below the floor is refused before its open, so that no packet is processed two times.

It is not a replay window of a fixed width: it moves only when the set loses a range.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: replay window.

### Idle timeout

The idle timeout is the time with no activity of the peer after which a side ends a QUIC connection with no packet: the smaller of the values that the two sides give, and 3 base probe timeouts at least.

It frees the record of a peer that vanished. The activity that moves its bound is a packet received, processed and recorded, and the first ack-eliciting packet sent after it; a datagram that does not authenticate moves nothing. A server of this system always has one: `server_init` refuses an idle timeout of 0. `quic_echo` uses 30 s, and logs at each idle end whether the end held its bound. It is not a keep-alive: this side sends nothing to keep a connection open.

The design: `docs/QUIC.md`, "What the transport does".

Do not use: keep-alive.

### Closing state

The closing state is the state of a side that sent CONNECTION_CLOSE: for 3 base probe timeouts, it answers datagrams of the connection with its close.

The close can be lost, so the side answers again when the peer sends more. A record of this system answers the 1st, 2nd, 4th, 8th... datagram, not each one, and does not open them: a third party that knows the identifier makes at most a few packets of about 50 bytes.

The design: `docs/QUIC.md`, "6. QUIC on the network (the fourth layer, built, with Retry and the budgets of work)".

### Draining state

The draining state is the state of a side that received CONNECTION_CLOSE: it sends nothing for 3 base probe timeouts, then ends the connection.

It lets the packets of the peer that are still on the path arrive and be dropped, with no answer.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

### Transport parameters

The transport parameters are the values that each side of QUIC gives the other inside the TLS handshake: its limits, its timeouts and the connection identifiers that it used.

They ride in the extension `quic_transport_parameters`, so the handshake authenticates them. Examples: the flow control limits, the limit of streams and the idle timeout. Each value of the peer is checked: a repeated parameter, a value out of its range or an identifier that is not the one of the packets gives TRANSPORT_PARAMETER_ERROR. A side writes its own from a record that has a field only for each parameter that the system sends, so no value that it sets is lost. They are not settings of the system: they belong to one connection.

The design: `docs/QUIC.md`, "What the transport does".

Do not use: settings.

### Retry packet

A Retry packet is a packet of a server that asks the client to send its Initial packet again with a retry token, to prove its address.

A server of this system answers each Initial with an unknown identifier and no token with a Retry, and keeps nothing: no record, no key, no open of the Initial. Its integrity tag, with a fixed key of version 1, proves to the client only that the Retry answers its own Initial. A client takes one Retry, before any Initial of the server, then derives its Initial keys from the identifier of the Retry and sends its ClientHello again with the token.

The design: `docs/QUIC.md`, "The server of several connections".

Do not use: redirect.

### Table of address budgets

The table of address budgets is the table of a QUIC server that holds a budget of Initial checks for each address whose retry token opened.

A host with one real address can take one Retry and then send many Initials with its valid token that do not open, each with about 30 µs of cryptography. So each address gets its own token bucket of Initial checks. A new address takes a place only when the place holds no information: free, or its bucket full again. So the table gives at most the sum of its buckets, and addresses that rotate through it spend at most half of the shared budget.

The design: `docs/QUIC.md`, "The budgets of work".

Do not use: address cache.

### Budget of work

A budget of work is the most pieces of one kind of work that a QUIC server does for datagrams of unknown identifiers, as a token bucket.

That work is cryptography for a sender that nobody checked yet. The server has three shared budgets: Retries, token checks, and Initial checks with a valid token. A datagram over a budget is dropped before any cryptography. The datagrams of known records have no budget and come first. A flood above a shared budget still stops new clients while it lasts. It is not a budget of the kernel: a budget of memory pays for kernel objects, and a budget of work bounds time spent by one program.

The design: `docs/QUIC.md`, "The budgets of work".

Do not use: rate limit (for this), quota.

### Token bucket

A token bucket is a count of units that grows by a rate in each second up to a depth, and from which each piece of work takes one unit.

A burst takes the depth at once, then the rate, so no boundary of a window lets a burst get the budget of two seconds in one millisecond. `quic.Work_Bucket` counts millionths of a unit, so a rate per second adds its value in each microsecond, and a bucket that was never used starts full. The budgets of work and the table of address budgets are token buckets. The tokens of a bucket are units of work, not retry tokens.

The design: `docs/QUIC.md`, "The budgets of work".

Do not use: leaky bucket, fixed window.

### UDP relay

The UDP relay is the part of the peer of the modus tool that carries UDP datagrams between a program of the host, on a socket of the loopback, and the UDP port 4433 of the machine.

QEMU user networking with `restrict=on` drops each UDP datagram that the machine sends, so a UDP forward of the host cannot reach `quic_echo`. The relay replaces it: a datagram of a client of the host becomes a frame from 10.0.2.2 to the port 4433 of the machine, and the answers go back the same way. A datagram over 1472 bytes is dropped and counted. `modustool test quic-real` uses it to run the OpenSSL QUIC client of the host against `quic_echo`.

The design: `docs/QUIC.md`, "A stack that this project did not write".

Do not use: port forward, proxy, hostfwd (for this).

## Trusted boot

### Signing key

The signing key is the Ed25519 key pair of the principal that signs the system: its private key signs the system description, and the boot program holds its public key.

The signing key answers one question at each start: is this the system that its signer built? The build signs the system description, which names each module and resource by its hash. The boot program verifies the signature before the kernel starts, then compares each file with the description. `modustool key new <folder>` makes the pair, and `SYSTEM_SIGNING_KEY` names it before a build; with no variable, the build signs with the test signing key. It is not a key of the TPM, and not the platform key of Secure Boot.

The design: `docs/TRUSTED_BOOT.md`, "5. The signing key".

Do not use: owner key, master key, release key, platform key (PK is a term of Secure Boot).

### Test signing key

The test signing key is the signing key of the tests: a key pair whose private key is published, so that a system that it signs is never trusted.

The key pair is the one of RFC 8032, section 7.1, TEST 1, in `resources/keys/test_signing_key`. Each build with no `SYSTEM_SIGNING_KEY` uses it: the test builds and the pictures of the site do. Anyone can sign a system with it, so the system says so at each place: the trust record has the key kind `Test`, the boot display says it in red, the root service writes a warning on the log, and the tool writes a file `<volume>.signed_by` beside the boot volume.

The design: `docs/TRUSTED_BOOT.md`, "5. The signing key".

Do not use: development key, demo key.

### Signed message

The signed message is the 64 bytes that the signing key signs for one system description: a fixed label padded with zero bytes to 32 bytes, then the BLAKE3 hash of the description.

The label `system description signature 1` (`SIGNATURE_LABEL` of `src/library/contract/system_description`) binds the signature to this one use: a signature that the key makes for another purpose is never a valid description signature. The number in the label names the version of the form. `system_description.signed_message` builds the bytes. The measure puts the same 64 bytes in the event log of the firmware, so the log names the system by its BLAKE3 identity.

The design: `docs/TRUSTED_BOOT.md`, "1. The claims".

Do not use: payload, digest (for this).

### Description signature

The description signature is the Ed25519 signature, 64 bytes, of the signed message of a system description.

The boot image holds it as its last resource, `system_description_signature`, after the resource `system_description`. The description does not list these two resources, because a file cannot hold its own hash. Before the kernel starts, the boot program verifies it with the public key that it holds, and a signature that does not verify stops the start. It is not a certificate: it names no one and has no date. The signature of an older description verifies too: the version floor of the TPM refuses an older system, once a newer one started.

The design: `docs/TRUSTED_BOOT.md`, "3. The system description".

Do not use: certificate, manifest signature.

### Trust record

The trust record is the record `boot_info.Boot_Trust` that the boot program writes to say what verified the system description, with which key, and what the TPM holds.

It holds the verifier (the boot program alone, or the firmware and the boot program when Secure Boot is on), the key kind and the public key, the hash of the system description, the state of the measure, and the numbers that it compared with the TPM floors. The kernel copies it into the boot record, and the boot display draws its line "trust" from it. It is not an attestation: a replaced boot program can write a false one. Only Secure Boot makes it come from a verified boot program.

The design: `docs/TRUSTED_BOOT.md`, "4. What a failure shows".

Do not use: attestation, security state.

### Measure

The measure is the extension of a register of the TPM with the SHA-256 hash of the system description, which the firmware does at the request of the boot program before the kernel starts.

A TPM register can only be extended, never set, so after the measure PCR 11 names the system that started, and no code that runs later can set it back. The TPM service seals the machine key to it, with PCR 7. The boot program asks the firmware, with the signed message as the data of the event, then reads PCR 11 back into the trust record. If the TPM refuses, the boot continues, and the trust record says `Refused`. The TPM measures and seals; it does not verify the description.

The design: `docs/TRUSTED_BOOT.md`, "6. The measure".

Do not use: attestation (for this), seal, measurement log (for this).

### Measure register

The measure register is PCR 11 of the TPM: the register that holds the measure.

The rules of the TCG for PC firmware leave PCR 8 to 15 to the operating system, and the conventions of Linux give PCR 11 to the whole system image that a boot stage measures before the kernel. `boot_info.MEASURE_REGISTER` is 11. The trust record keeps the value of the SHA-256 bank, and `modustool` computes the same value from the description and compares. The policy of a key sealed by the TPM names PCR 7 (the Secure Boot state) beside it.

The design: `docs/TRUSTED_BOOT.md`, "6. The measure".

Do not use: slot, PCR (alone, for this register).

### TPM service

The TPM service is the program `tpm`: the device service of the TPM of the machine, which seals 32 secret bytes to the values of PCR 7 and PCR 11 and unseals them only while those registers hold the same values.

The root service starts it at boot, before `unlock`, only when the trust record says `Measured`. `unlock` reaches it with the start grant `Tpm`, through a ring of two commands, `Seal` and `Unseal` (`src/library/contract/tpm_service`). The service builds each command of TPM 2.0 itself, so no client extends a register or clears the TPM. It is not a driver in the kernel, and the boot program does not use it: the boot program talks to the TPM through the firmware, before the kernel starts.

The design: `src/md/features/tpm_sealed_machine_key.md`.

Do not use: TPM driver (for the program), TPM daemon, resource manager.

### Sealed by the TPM

A secret is sealed by the TPM when the TPM holds it in a sealed object whose policy is the values of PCR 7 and PCR 11 at the seal: the TPM gives it back only to the same system, measured by the boot program, with the same state of Secure Boot.

A seal needs Secure Boot on. An older system, a changed system, a machine whose Secure Boot was turned off, or a copy of the disk on another machine opens nothing. Two secrets are sealed so: the machine key (`machine_seal()`), and a TPM secret, whose sealed object also has an authorization value. For the machine key of `machine_seal()`, no passphrase is typed: the strength is the TPM, not a derivation. For a TPM secret, the TPM and the passphrase are needed together.

The design: `docs/PRINCIPALS.md`, "The keys sealed by the TPM".

Do not use: bound to the TPM, TPM-encrypted, locked (for this).

### Recovery key

A recovery key is a key of 20 random bytes, shown one time as 32 characters of base32 in 8 groups of 4, that opens a copy of the machine key, or of the keys of a named principal, when the TPM does not release them.

The window of `unlock` shows it once, after a seal by the TPM, or after `recovery_key_change()`. It is never kept on the disk or written on the log. When the TPM refuses (an update of the system, another machine, no TPM, a lockout), the window asks for it; at a passphrase prompt, Ctrl+R asks for it at once. After a recovery, `unlock` seals the key again to the system that runs, and asks for a new passphrase when one was lost. Its 160 random bits need no slow derivation.

Example: `MZXW-6YTB-MZXW-6YTB-MZXW-6YTB-MZXW-6YTB`.

The design: `src/md/features/tpm_sealed_principal_keys.md`.

Do not use: backup key, reset key, PIN, recovery password.

### Authorization value

An authorization value is the secret that a sealed object needs beside its policy: the TPM compares it at each unseal, counts each wrong one, and refuses each try for a time after too many.

The keys of a named principal and the machine key under a machine passphrase use it. The value is keyed BLAKE2b of the key that Argon2id derives from the passphrase, so a reader of the bus of the TPM still runs Argon2id for each guess. After a lockout, the window of `unlock` asks for the recovery key. The count limits the rate of the tries only while the lockout authorization value is secret. It is not the passphrase, and nothing of it is on the disk.

The design: `docs/PRINCIPALS.md`, "The keys sealed by the TPM".

Do not use: PIN, password (for this), TPM password.

### Lockout authorization value

The lockout authorization value is the authorization value of the lockout hierarchy of the TPM: the one secret that resets the count of the wrong authorization values, changes its limits, or clears the TPM through that hierarchy.

A new or cleared TPM has an empty one, and then any system on the machine can reset the count. Before the first use of a passphrase, the TPM service sets 32 random bytes when the value is empty, and erases them: nothing in the system can reset the count. A value that is set already stays. The first system of the machine that sets the value owns the reset of the one count of the TPM. It is not the authorization value of a sealed object, and nobody types it.

The design: `src/md/features/tpm_sealed_principal_keys.md`, "The lockout authorization value".

Do not use: lockout password, lockout PIN.

### TPM secret

The TPM secret is the 32 random bytes that the TPM seals with an authorization value, for a named principal or for the machine passphrase: with the key of the passphrase it gives the seal key of the secret keys of the principal, or of the machine key.

The seal key is keyed BLAKE2b of the TPM secret over the key of the passphrase and a text of its use. So the keys need the TPM, the measure of the system and the passphrase together, and a reader of the TPM secret still runs Argon2id for each guess. A new passphrase, after a recovery or a change of the passphrase, gives a new TPM secret.

It is not the machine key, and not a key of the principal: it signs and opens nothing alone.

The design: `src/md/features/tpm_sealed_principal_keys.md`, `src/md/features/tpm_sealed_machine_passphrase.md`.

Do not use: TPM key, sealed key (for this).

### Key check

The key check is keyed BLAKE2b of the machine key over a fixed text, which the record sealed by the TPM keeps beside the seals.

After an unseal or a recovery, `unlock` compares the check of the key that it received with the check of the record, and gives the root service nothing when they differ. A record whose areas come from another record, or a TPM service that gives another key, then has no effect but a request for the recovery key. Keyed BLAKE2b is a pseudorandom function: the check reveals nothing of the key.

The design: `src/md/features/tpm_sealed_machine_key.md`.

Do not use: fingerprint, hash of the key.

### Firmware signing key

The firmware signing key is the RSA-2048 key and its self-signed X.509 certificate with which the principal that signs the system signs the boot program for Secure Boot.

UEFI Secure Boot verifies Authenticode signatures with RSA keys and X.509 certificates, and cannot verify Ed25519. So a second key closes the gap of the first: without Secure Boot, anyone who can write the boot volume can replace the boot program, its public key and its checks. `modustool key new` makes the pair beside the signing key, and the build signs the boot program with it. A principal present at the machine enrols the certificate in the variable `db` of the firmware. With Secure Boot on, the trust record says `Firmware_And_Boot_Program`.

The design: `docs/TRUSTED_BOOT.md`, "7. Secure Boot".

Do not use: db key (for the pair), Secure Boot key.

### Test firmware signing key

The test firmware signing key is the firmware signing key of the tests, whose private key is published, so that a boot program that it signed is never trusted.

The pair is `resources/keys/test_firmware_signing_key.pem` and `.crt`; `modustool key test-firmware-new` wrote it once. The variable store of the test machines of Secure Boot has its certificate as PK, KEK and the one entry of `db`. `modustool test trusted_boot` checks with it that the signed boot program starts, and that a boot program with one byte changed, or unsigned, does not. The machines of the keys sealed by the TPM in `modustool test principals` start from the same variable store, with a software TPM.

The design: `docs/TRUSTED_BOOT.md`, "7. Secure Boot".

Do not use: development certificate.

### Key folder

The key folder is the folder outside the repository that holds the keys of the publisher of the system: the signing key, the firmware signing key and its certificate, and the release signing key.

`modustool key new <folder>` makes it, each private file readable by its owner only, in a folder that only its owner can open. `modustool key write <folder>` makes the same folder from the four secrets of the workflow of a release. `SYSTEM_SIGNING_KEY` names the signing key in it, and the tool finds the other keys beside it.

The design: `docs/TRUSTED_BOOT.md`, "5. The signing key".

Do not use: keyring, key store, vault.

### Release signing key

The release signing key is the Ed25519 key pair of the publisher of the system whose private key signs the checksum list of the files of a release.

It answers one question: do these downloaded files come from the publisher of the system? It signs no system: the signing key does. No machine holds it, so a new release signing key changes no machine. Its seed is `release_signing_key` in the key folder; its public key is `resources/keys/release_signing_key.public`, and the site publishes it. A key text is 32 bytes in base64url with no padding, the form of the package `signing` of gui_toolkit. `modustool release image` refuses a release signing key whose public key is not the file of the repository.

The design: `src/md/infrastructure/release_image.md`.

Do not use: release key, download key, GPG key.

### Checksum list

The checksum list is the file `SHA256SUMS.txt` of a release: one line for each published file, its SHA-256 in 64 lowercase hexadecimal digits, two spaces and its name.

It has the form that `sha256sum -c` reads. Its line names the compressed image, the file that a principal downloads. The release signature covers it, so the image needs no signature of its own. Example: `3f0c...e1  modus-0.93.0-x86_64.img.zst`.

The design: `src/md/infrastructure/release_image.md`.

Do not use: manifest, hash file, digest list.

### Release signature

The release signature is the Ed25519 signature, by the release signing key, of the release signature context and the checksum list: the file `SHA256SUMS.txt.sig`, in base64url with no padding.

The release signature context is the bytes `modus release checksums 1` and an end of line. It binds the signature to this one use: a signature that the key makes for another message is never a release signature, and a signature of the checksum list alone does not verify. `modustool verify` checks it before it reads a line of the list; OpenSSL 3 checks it with no tool (`docs/INSTALL.md`, "2. Verify the files").

It is not a description signature: that one signs a system description, with the signing key.

The design: `src/md/infrastructure/release_image.md`.

Do not use: detached signature (for this), checksum signature.

### Release volume

The release volume is the boot volume that a release publishes: the main boot image, the kernel of the tests, and the boot program signed with the firmware signing key, signed with the keys of the publisher of the system.

Only `modustool release image` builds it, as `build/boot_volume_release.img`, after a whole build: it is not in the list of the volumes of the build, and no test boots it. Its form is the form of the volume of the machine of Secure Boot of the tests, with other keys.

The design: `src/md/infrastructure/release_image.md`.

Do not use: production volume, installer.

### Release image

The release image is the disk image that a release publishes: a GPT disk whose one partition, the EFI system partition, is the release volume, compressed with zstd.

A principal writes it to a USB key with `dd` (`docs/INSTALL.md`, "3. Write the USB key"). The boot volume of the tests has no partition table; the release image has one, because the firmware of a real machine reads a GPT disk. The GUIDs of the disk come from the hash of the volume, so one volume gives one disk. Its only pointer theme is the theme of the system: a release image never holds the Posy theme. File: `modus-<release number>-x86_64.img.zst`.

The design: `src/md/infrastructure/release_image.md`.

Do not use: ISO, installer, live image.

### Security version

The security version is the number from 1 to 64 in the header of a system description that the version floor of the TPM compares: the boot program refuses a description whose security version is below the floor.

The description signature covers it. The repository holds it as `system_description.SECURITY_VERSION`, and the build writes it into each description. It rises only with the fix of a flaw that a return to an older system brings back, so after a release with no such fix a principal can go back to the release before. Example: the version 2 fixes a flaw of the version 1; after a start of the version 2, the machine refuses the version 1. It is not the version of the format of the description, and not a release number.

The design: `src/md/features/rollback_floors.md`.

Do not use: generation, epoch, rollback counter, release number (for this).

### Key number

The key number is the number from 1 to 64 that the boot program holds beside the public key of the signing key, which the key floor of the TPM compares.

`resources/keys/key_numbers` gives each public key of the publisher of the system its number; the test signing key has 1, and the build refuses a key with no line. A new key after a theft or a loss gets the next number. The first start of a system of the new key raises the key floor: each boot program with a lower number then refuses to start on that machine. It is not a part of the key, and the description signature does not cover it: Secure Boot covers the boot program that holds it.

The design: `src/md/features/rollback_floors.md`.

Do not use: key generation, key version, key index.

### TPM floor

A TPM floor is an index of the TPM, a field of 64 bits that only gains bits, whose highest set bit plus one is the lowest number that the boot program accepts.

The key floor is compared with the key number of the boot program; one version floor for each key number is compared with the security version. The TPM keeps the rule "only rises": no command clears a bit. Only a boot program that the certificate of the publisher verified can raise a floor, before its measure. The boot program reads both floors, stops the start for a number below a floor, then raises both to its numbers. A clear of the TPM removes every floor. It is not a counter of the TPM, and not a PCR.

The design: `src/md/features/rollback_floors.md`.

Do not use: rollback counter, monotonic counter, anti-rollback index.

## Project

The words of this group name how the project is run and published: the documents that hold its rules and its state, the units of the work, and the site, the changelog and the news that report it.

### Property

A property is one of the 21 fundamental concepts of the system, each with its rule, its reasons and its costs, in `docs/PROPERTIES.md`.

The properties are the reference against which every proposal is measured: a proposal that contradicts one is named as such before any work on it. Each property has a number, a title ("10. One code module") and a status in the summary table of the document. The status page of the site shows each property with its status. A comment in a source never names a property by its number: it states the reason in words. `modustool check` refuses "(property 14)" as a comment breach.

The design: `docs/PROPERTIES.md`.

Do not use: principle (for this), requirement, axiom.

### Reuse list

The reuse list is the table of `docs/PROPERTIES.md` that names each reused work: a work of others that the system ships in a module or in the boot image, or that the repository holds as a copy.

Each row gives the work, its place in the repository, its license as an SPDX identifier, and the file with the text of that license. A font subset, a pointer theme, the copied cryptography and each portrait of the hall of fame are reused works. A tool of the host that builds or tests the system (QEMU, the compiler) is not, and neither is a design or a standard that the system follows. `modustool check` compares the list with the records of the repository.

The design: `src/md/infrastructure/reuse_list.md`.

Do not use: third-party list, dependency list, bill of materials.

### Step

A step is one tested commit on `master` that adds one capability to a system that works.

The project grows in steps: each step leaves the system whole, built and tested, with its documents up to date in the same commit. Several features can be written at once on branches; each merge still needs its build and the test of its own part.

A step is not a stage of the start of the machine (the "Step of the start" of the group "Running code"), not a step of a machine test, which waits for one line of the log, and not a sequence step of an operation sequence.

The design: `AGENTS.md`.

Do not use: iteration, sprint, milestone (for this).

### Review

A review is a read of the work against the properties and the rule "no bad compromise", which lists each concession and what removes it.

The project asks for one after each five steps. Each concession that it finds, and that is planned work, becomes an entry of `ROADMAP.md`. Kernel code, concurrent code and code that reads the network also have an independent review before each merge: a fresh read of the change, often by a new agent session. A finding of a review has a label, and its correction never names that label in a comment of the code.

The design: `AGENTS.md`.

Do not use: audit, code review (for the whole), retrospective.

### Working record

A working record is a document that records the work on the site, not the system: `docs/SITE.md`, and each intent file of `src/md`.

A guide says what the system does and how to use it; a working record holds the design of a part and the state of its work. So the site publishes the guides and not the working records (`SITE_WORKING_RECORDS`): a link of a page to a working record names the file in the repository, and says so. An intent file is a working record for the site by its path under `src/md`.

The design: `docs/SITE.md`, "The pages".

Do not use: internal document, notes.

### Intent file

An intent file is a Markdown file of the folder `src/md` that records why a part of the system has its form.

A design is written there before its code, and a change of a design changes its intent file in the same commit. `src/md/README.md` is the entry point of the folder, with a file index that `modustool check` compares with the folder. An intent file is not a guide: a guide says what the system does and how to use it, and the site publishes it. It is not a review, a log or a plan. Example: `src/md/features/palette.md` says why the palette is a panel of the compositor, and which forms were refused.

The design: `src/md/README.md`, "The rules of this folder".

Do not use: design document, specification, RFC, architecture decision record.

### Similarity finder

The similarity finder is the command `modustool similarity`: it measures how similar the code pieces of the Odin sources of the repository are, groups them in similarity families, and proposes where to factor each family.

It reads `src/` and `tools/` with the parser of Odin, gives a similarity score for each pair that it compares, and writes a report under `build/similarity/`. It ranks the families by the syntax nodes that a factoring saves, and proposes a home that obeys the import rules. A human or an agent decides what to factor: a family that is kept is a line of the kept list. It is not a check: it never fails a build, and it never edits a source.

The design: `src/md/infrastructure/similarity_finder.md`.

Do not use: duplicate finder, clone detector, linter (for this).

### Code piece

A code piece is a procedure, a run of two or more statements of one block, or an expression, that the similarity finder compares with other code pieces.

A code piece is a part of the code that one call can replace, so a factoring of it is a procedure. It has a minimum size in syntax nodes, so that the call costs less than what it replaces. It is not a fragment: a fragment is a file of `changelog.d/`.

The design: `src/md/infrastructure/similarity_finder.md`, "2. The code pieces".

Do not use: fragment, clone (for one piece), snippet.

### Similarity score

The similarity score of two code pieces is a number from 0 to 1: two times the syntax nodes that their factoring template keeps, divided by the sum of their sizes.

It is 1 when the two are equal after the normal form of the similarity finder, and 0 when they share no node. A score of 0.9 says that a tenth of the two code pieces is in the blanks and the statements that only one side has. A score of 1 is not a proof of the same behaviour: the normal form applies only the rules that the syntax proves. `modustool similarity pair` gives the score of any two procedures.

The design: `src/md/infrastructure/similarity_finder.md`, "6. The anti-unification and the similarity score".

Do not use: distance (for this), match percentage.

### Similarity family

A similarity family is a set of two or more code pieces that one factoring template covers, each for at least 70% of its nodes when the members are not equal.

A family has a category: a utility to centralise, a local repetition, a parametric family, similar behaviour, a repeated expression, kept apart by the rules, or a platform variant. Its members are the code pieces, with their file and lines and the arguments of each blank. A family of similar behaviour has a statement in some members only, or a blank that Odin cannot pass as a parameter: no one call replaces it.

The design: `src/md/infrastructure/similarity_finder.md`, "7. The families".

Do not use: clone class, clone group, cluster.

### Factoring template

A factoring template is the code that all the members of a similarity family share, with a blank at each place where they differ: the body of the procedure that a factoring makes to replace them.

The similarity finder computes it by anti-unification, the least general generalization of the members: each node that all the members have stays, and each place where they differ becomes a blank. The report prints it from the source of its first member, with `?1`, `?2` at the blanks. Its template hash names the family in the kept list. It is not an instruction template: an instruction template is an `asm` procedure.

The design: `src/md/infrastructure/similarity_finder.md`, "6. The anti-unification and the similarity score".

Do not use: abstraction, generalization (for the result), macro.

### Blank

A blank is one place of a factoring template where the members of a similarity family differ, with the argument of each member at that place.

A blank has a kind: a value, a type, a place, a procedure, or not a parameter. The kind says how the factored procedure takes it: a parameter, a polymorphic parameter, a pointer parameter, a procedure parameter, or not at all. The same arguments at two places give one blank. It is not a hole: a hole is a part of a stored object whose bytes are zero.

The design: `src/md/infrastructure/similarity_finder.md`, "6. The anti-unification and the similarity score".

Do not use: hole (for this), metavariable, pattern variable.

### Changelog

The changelog is the file `CHANGELOG.md`: the releases of the system, newest first, each with the changes that a reader of the system notices.

It follows the format of Keep a Changelog 1.1.0 and semantic version numbers. Each entry starts with a short bold summary, then says what the system does now, for a reader, not how the code changed. No one edits the file by hand: a branch adds a fragment for each change, and `modustool changelog release` moves the fragments into a new release. The site shows the file at `releases/` and in the feed `releases.xml`. It lists every change for a developer; a news entry reports one thing for a reader who is not a developer.

The design: `docs/SITE.md`, "The pages".

Do not use: release notes (for the file), history, news.

### Release

A release is one section of the changelog, with a release number, a release time and the entries of its changes, on one commit of `master` that carries its release tag.

A release marks a state of `master` that passed its checks. `modustool ship` makes it: it moves the fragments of `changelog.d/` into a new section, writes the release number, commits, tags the commit, and pushes the commit and the tag at once. Example: `## [0.93.0] - 2026-11-15 18:48`. The push of its release tag starts the release workflow, which publishes its release image. It is not a version: a stored object of the system has versions. It is not a build: many builds come between two releases.

The design: `src/md/infrastructure/releases.md`.

Do not use: version (a stored object has versions), tag, build.

### Release number

The release number is the number of a release, in the form `<major>.<minor>.<patch>`.

The project is before its first major release, so a release number is `0.N.0` for a release of new work and `0.N.1` for a correction after it. `RELEASE_NUMBER` in `src/library/contract/release` holds the newest one, and `modustool release_number` prints it; the foot of each page of the site and the page graph name it. The tool writes it; no one edits it by hand. `modustool ship step` takes the next `0.N.0`, `modustool ship correction` the next `0.N.1`.

The design: `docs/SITE.md`, "The pages"; `src/md/infrastructure/releases.md`.

Do not use: version number, version.

### Release time

The release time is the moment of a release, in UTC, to the minute, as its heading in the changelog writes it: `2026-11-15 18:48`.

`modustool changelog release` writes the time of the clock of the host, in UTC, so two releases of one day keep their order, and two hosts in two time zones write comparable times. The releases page shows it with "UTC" after it, and the feed `releases.xml` writes it as `2026-11-15T18:48:00Z`. An old heading that has its day alone gets its time from `modustool changelog times`, from the commit of its release. It is not the date of a news entry, which is a day alone.

The design: `src/md/infrastructure/releases.md`.

Do not use: release date (for the whole), timestamp.

### Release tag

A release tag is the annotated, signed git tag `v<release number>` on the commit of a release.

`modustool ship` makes it with `git tag -s -a`, so it holds who released, when, and a signature that the git configuration of the publisher of the system makes. It goes to `origin` in one atomic push with the commit of the release: a tag never exists there without its commit. The release workflow starts from it. The releases before the first `ship` have no tag.

It is not the release: the release is the section of the changelog, and the tag names its commit. It is not a release number: the number has no `v`.

The design: `src/md/infrastructure/releases.md`.

Do not use: release label, version tag (for this).

### Release link

A release link is the line `[<release number>]: https://github.com/sachahjkl/modus/releases/tag/v<release number>` at the end of the changelog, one for each release.

Keep a Changelog defines these lines: a forge that renders Markdown then links the number of each heading to the page of its release tag. The lines are newest first, after the last release, with no empty line between them. `modustool changelog release` writes the link of a new release, `modustool changelog times` adds each missing one, and `modustool changelog check` refuses a missing, wrong or extra link, and links in another order.

It is not a link of the site: the releases page gives each release an anchor.

The design: `src/md/infrastructure/releases.md`.

Do not use: reference link, footnote.

### Fragment

A fragment is one file of `changelog.d/` that holds one change that is not in a release yet: its type and the text of its entry.

A branch adds one fragment for each change that a reader notices, in the same commit as the change: `modustool changelog new <type> <subject> - < text.md` writes `changelog.d/<yyyymmdd-hhmmss>-<subject>.md`. Line 1 is `type: <type>` (Added, Changed, Deprecated, Removed, Fixed or Security), line 2 is empty, then one paragraph:

```
type: Added

**The thing**: what the system does now, for a reader, in one or two sentences.
```

A change with no effect that a reader notices (a document, a comment) has no fragment. `modustool changelog release` moves the fragments into a release and deletes them.

The design: `changelog.d/README.md`.

Do not use: changeset, news file, entry (for the file).

### Roadmap

The roadmap is the file `ROADMAP.md`: the planned work of the system, in three sections, Now, Next and Later, then an optional section Maybe.

It is the one place of the plans: the changelog lists the work that is done, the roadmap the work that is planned. **Now** holds the work in progress, **Next** the work that is decided and comes after, **Later** the work that is wanted and has no order, and **Maybe** what is not decided. The file is written by hand, with no date and no name of a person. `modustool roadmap check` checks its form, and the site shows it at `roadmap/`. It is not the status page, which gives the state of each property.

The design: `docs/TOOLS.md`, "The roadmap".

Do not use: plan, backlog, to-do list, next steps, milestones.

### Roadmap entry

A roadmap entry is one item of a section of the roadmap: a short bold summary, then one or two sentences on what the work gives the user.

An entry names one planned work in the words of its user: a user of the system, or a developer who builds on it. Example:

```
- **A window for the debugger.** The debugger gets a window over the exports that the console uses today.
```

When an intent file holds the design of the work, the entry ends with a design link. An entry has no date and no number: its section is its state. When its work is done, the entry is removed in the commit of its changelog fragment.

The design: `docs/TOOLS.md`, "The roadmap".

Do not use: ticket, issue, task, story, item (for an entry), feature request.

### News entry

A news entry is a dated report in prose, for a reader who is not a developer of the system, of one thing that the reader can see or use, with its picture.

Each entry is one file of `news/`, `news/<yyyy-mm-dd>-<subject>.md`, never moved or merged: a head of a few lines, an empty line, then at most 1200 bytes of text. Its kind is Shown, Measured, Decided or Fixed. `modustool news new <subject>` writes an empty entry, which `modustool news check` refuses until a title and a text are written. The site shows each entry as a card on `news/`, and in the feed `news.xml`. The changelog lists every change for a developer; a news entry reports one thing, and names the guide that explains it.

The design: `docs/SITE.md`, "The news".

Do not use: news item, post, announcement, blog post, changelog entry.

### Film

A film is the pictures of the screen of a test machine, taken 30 times in one second while a scenario of the tool sends its keys, as one file that a player shows at the speed of the machine.

`modustool film <name>` makes a film, such as `terminal` or `boot`: an MP4 file and a WebM file from the same pictures, in the build folder. A film is not a test: only its scenario has steps with a fixed time. A news entry can name a film, and the repository then holds its WebM file. The site shows it on the page of the news in a `video` element that plays only when the reader starts it.

The design: `docs/TOOLS.md`, "The film".

Do not use: video (for the file), clip, movie, recording, screencast.

### Feed

A feed is a file of the site in the Atom format (RFC 4287), for a program that follows a site: `news.xml` has the news entries and `releases.xml` the releases, newest first.

A feed reader subscribes to the address of the file and shows each new entry. Each page names both feeds in its head, so a browser finds them. The id of each entry is the address of its file in the repository on `master`, so it does not change when the site gets an address. With no site address the links of a feed are relative and it has no link `self`.

The design: `docs/SITE.md`, "The news", and "The sitemap, robots.txt and the feeds".

Do not use: RSS (for these files), stream, channel.

### Search index

The search index is the file `search.json` of the site: one entry for each page, and for each thing of a page that a reader looks for, with its title, its page, its anchor, its kind and a short text.

Each entry comes from the same data as its page: a term has its short definition, an export its signature as the console prints it. The search field filters the index in the browser with the fuzzy match of the console, so the site needs no server for its search. The command checks that each entry names a page and an id that exist.

It is not the sitemap: the sitemap lists pages for a search engine; the search index lists things inside pages for the search field.

The design: `docs/SITE.md`, "The index".

Do not use: search database, catalog, sitemap.

### Search field

The search field is the one field of a page of the site where a reader types a search.

On each page it is in the site menu of the bar; on the docs home it is a large field in the page, and the bar has none. One script, `search.js`, serves both places: it loads the search index at the first key, and shows the matches in the look of the completion list of the console. `/` puts the focus in it. The query is in the address as `?q=<query>`, so a search can be linked. With no script, the field is hidden and the site stays whole by its links.

The design: `docs/SITE.md`, "The search".

Do not use: search box, search bar, omnibox.

### Mark

The mark is the picture that stands for the system: a heron on a grid of 24 by 24 square cells, each part filled with one gradient.

`src/library/support/mark` holds it as data: the rows of the still heron, the colors of each part and the animations of the mark. Every picture of the mark comes from that one table. One generator of the tool draws each picture file, in the variant of the mark that its use names: `modustool logo` for `resources/logo`, `modustool site` for the site, and `modustool mark` for one picture. The system draws the mark on the boot display and in the bar.

The design: `docs/DESIGN.md`, "11. The mark".

Do not use: logo, icon, emblem, mascot.

### Name of the mark

The name of the mark is the word "modus" drawn in letters of square cells, 5 columns by 7 rows each, under or beside the heron.

It is drawn from the same cells as the heron, so the files of the mark with a name keep one grid. A picture holds it only where one file must carry the heron and the name: the files `resources/logo/modus*.png` and the picture of the site for other sites. On a page of the site the picture is the heron alone, and the name is text in the font of the name of the mark. The boot display draws it at the right of the heron.

The design: `docs/DESIGN.md`, "11. The mark".

Do not use: wordmark, logotype.

### Font of the name of the mark

The font of the name of the mark is a font file whose glyphs are the cells of the letters of the name of the mark.

It lets a page write the name as text and show the letters of the mark: a reader selects the text, and a screen reader says it. `modustool logo` writes it from `mark.name_letters` as `resources/logo/modus_mark.ttf`. It has only the letters of "modus" and the space: it is not a font for a text. One em is 8 cells, so a font size that is a multiple of 8 pixels draws whole cells. Example: the bar of the site shows "modus" in this font at 16 pixels: cells of 2 pixels.

The design: `docs/DESIGN.md`, "The font of the name".

Do not use: logo font, wordmark font, pixel font.

### Still heron

The still heron is the heron of the mark with no animation: the 24 rows of `heron_rows` in `src/library/support/mark`.

Each animation starts from it and ends on it, and it is the frame 0 of each one. A picture that does not move (a file of `resources/logo`, an icon, the boot display) shows it.

The design: `docs/DESIGN.md`, "11. The mark".

Do not use: rest pose, idle frame, base frame (a base frame is another thing: see Animation of the mark).

### Animation of the mark

An animation of the mark is a short list of frames in which a few cells of the still heron change.

In a frame a cell takes the letter of another part, or becomes empty. Each frame has a duration, and starts from the still heron or from an earlier frame of the same animation, its base frame. After its last frame the heron is still again. The animations are data in `src/library/support/mark/animation.odin`, from the blink of one cell to the dash. The data does not say when one plays: the order of play of the place that shows them chooses which one comes next.

The design: `docs/DESIGN.md`, "11. The mark".

Do not use: idle animation, clip, tween.

### Order of play

The order of play is the rule that chooses the next animation of the mark, on the home of the site and in the program `heron`: each animation plays once in a round, in an order of chance.

The place that plays keeps a memory of the animations that were played, and chooses the next one among the others, each with the same chance. When the memory holds every animation, a new round starts, and the animation played last is left out of its first choice, so no animation follows itself. The rule is one procedure, `mark.next_animation`: the program `heron` calls it, and the modus tool runs it to check the script of the site. On the site the memory lasts for the visit of the tab.

The design: `docs/SITE.md`, "The rhythm of the animations".

Do not use: playlist, shuffle, random choice.

### Still share

The still share is the part of the time, over a long play, that the heron does not move where its animations play: 40 %.

It holds on the home of the site and in the program `heron` (`mark.STILL_SHARE_PERCENT`). The still time between two animations is chosen by chance around a mean, and the mean follows from the still share and from the times of the animations: the mean time of an animation, times the still share, over the moving share. With 15 animations of 1.29 s on average, the mean still time is 858 ms, and a still time is 429 to 1287 ms. A change of an animation changes the still times, not the share.

The design: `docs/SITE.md`, "The rhythm of the animations".

Do not use: idle ratio, duty cycle, pause.

### Move of the heron

A move of the heron is the list of the forms and of the places that the heron takes during an animation of the mark, each in whole cells.

An animation of the mark changes cells; a move takes the whole heron above the line of the water: across the window in the dash, up in the hop and the flap, wider and lower in a crouch. The water stays in its place. A move is a list of keys in `src/library/support/mark` (`move_keys`): a time, a form of the heron and a place in whole cells. The heron is never between two cells, and no picture of it changes its size. The home of the site and the program `heron` play the same keys.

The design: `docs/DESIGN.md`, "The moves".

Do not use: tween, sprite motion, scale.

### Form of the heron

A form of the heron is one drawing, in whole cells, of the part of the heron above the water: the natural heron, or the heron squashed or stretched.

A cell of the heron is a square of one size, so a squashed heron is not a picture made wider: it is the heron drawn with more columns and fewer rows of the same cells. A form names the columns and the rows of a frame that it repeats or leaves out, chosen by hand, then cells corrected by hand (`form_lines` and `form_corrections` in `src/library/support/mark`). The head, the eye, the beak and the crest are the same in every form. Example: the crouch is 28 by 19 cells.

The design: `docs/DESIGN.md`, "The moves".

Do not use: scaled frame, deformation, sampled frame.

### Move on the grid

A move on the grid is a move of the heron in which each cell stays a square of one size at a place of the grid.

It is the way of the system to draw a squash, a stretch and a travel. On the grid the heron takes a form of the heron, and a travel is a count of whole cells. It is not a filter over a scaled picture: the forms and the places are cells from the start. The other way, the free move, is in the program `heron` only, to compare: its cells are stretched to rectangles, at any pixel. Example: in the run of the dash the heron is 32 by 20 cells.

The design: `docs/DESIGN.md`, "The moves".

Do not use: snap, pixel-perfect scaling, quantized motion.

### Variant of the mark

A variant of the mark is one of the two ways to color the pixels of the heron: smooth, where each pixel takes the gradient at its own place, or cells, where each cell is one color.

A request for a picture of the mark names its variant: nothing chooses it from the cell size. A large picture is the smooth variant: the head of the home of the site, the files of `resources/logo`, the boot display. A small icon, one pixel for a cell, is the cells variant: the bar of the site, the bar of the desktop, the icon of a tab. The smooth variant needs at least 2 pixels for a cell, and a request for it at one pixel is refused.

The design: `docs/DESIGN.md`, "The variants of the mark".

Do not use: style, mode, rendering, pixel art mode.

### Tile map

A tile map is one PNG file that holds each distinct frame of the animations of the mark as a tile, in rows from the top left with the still heron first, and under them, for a place that shows the moves, a tile for each drawn form.

A script that plays the animations shows one tile at a time by its place in the file, so a page loads one picture for all the animations. A frame that two animations share is in the file once. The generator of the pictures of the mark draws a tile map in a variant of the mark, a cell size and a color scheme, and writes its table: the place and the size of each tile, the times, the moves in cells. `modustool mark tile_map` writes one.

The design: `docs/SITE.md`, "The moves of the heron".

Do not use: sprite sheet, atlas, film strip.

### Icon file

An icon file is one file that holds the mark at several sizes, each as one PNG file behind a directory, so that a reader takes the entry of the size that it shows.

The generator of the pictures of the mark writes it: each entry is the PNG file of one picture, byte for byte, at most 256 pixels on a side. The site has one, `favicon.ico`, with an entry of 32 pixels in the cells variant and one of 48 pixels in the smooth variant. `modustool mark still --format ico` writes one. It is not the icon of a phone or of the manifest: each of those is one PNG file.

The design: `docs/SITE.md`, "The icons".

Do not use: favicon file, ICO container, multi-size icon.

### Vector file of the mark

A vector file of the mark is a file that holds the mark in the cells variant as rectangles of one color, so that a reader draws the same cells at each size.

The generator of the pictures of the mark cuts the pixels of a picture into rectangles: a run of cells of one color in a row is one rectangle. The tool computes each color; the reader of the file only fills rectangles. The file can hold a rule that gives the colors of the dark scheme to a reader that asks for dark. The smooth variant is not written as a vector file: the reader would compute the gradient. The site has one, `pictures/icon.svg`. `modustool mark still --format svg` writes one.

The design: `docs/TOOLS.md`, "The pictures of the mark".

Do not use: SVG logo, scalable icon, vector logo.

### Animated file of the mark

An animated file of the mark is one animated PNG file that holds each frame of one animation of the mark as a picture, each for the time that the table of the animations gives it.

The generator of the pictures of the mark writes it, and a test reads each frame back and compares its pixels. It plays with no end, and does not show the move of the heron. It is for a page that runs no script, such as a page of a repository. The repository holds none: `modustool mark animation --animation <name>` writes one. It is not a tile map, which a script plays, and not a film, which shows the running system.

The design: `docs/TOOLS.md`, "The pictures of the mark".

Do not use: GIF, animated logo, sprite animation.

### Hall of fame

The hall of fame is the program `hall_of_fame`: one card for each person whose work inspired the system, with the name of the person and one line on what they made.

A card shows a portrait when a picture of the person has a license that lets the repository hold it with a credit, and then the credit of the picture under it. Each other card shows the name and the line alone, with no picture and no initials. A person is in it for work that the system learned from, not for fame. The arrows, Home, End and the pointer choose a card.

The design: `src/md/features/hall_of_fame.md`.

Do not use: temple, wall of fame, credits screen.

### Portrait credit

A portrait credit is the author and the license of one portrait of the hall of fame, which the program shows under the portrait.

`resources/hall_of_fame/CREDITS.md` holds the source, the author and the license of each picture; the program shows the author and the license, and the page of the licenses of the site shows one row for each picture. A host test of the modus tool checks that the program has the credit of each row.

The design: `src/md/features/hall_of_fame.md`.

Do not use: attribution line, copyright notice.

### Site

The site is the documentation of the system as static pages, with their style sheet and their pictures, that `modustool site` writes in `build/site` from the files of the repository and the logs of the machine tests.

Every fact of the site comes from a file: the guides from `docs/`, the reference tables from the sources, the numbers from the logs or the measure record, the news from `news/`. The command checks every page before it writes one, and stops on a fault, such as a broken link, with the page and the reason. Each page is whole with no script and makes no request to another host. The site workflow publishes it at `https://modus.froment.software/`.

The design: `docs/SITE.md`, "The command".

Do not use: website, homepage, landing page.

### Docs

The docs is the section of the site that holds the guides and the reference: the bar names it "Docs", and the addresses of its pages start with `/docs/`.

Its first page is the docs home. The guides explain how each part of the system is designed and why; the reference lists what exists in this build, from the sources. The status page is not a part of it: it reports the state of the work.

The word "Docs" names the section because "Documentation" is already the term for the text that a module carries.

The design: `docs/SITE.md`, "The sections".

Do not use: documentation (for this: Documentation is the text of a module), manual, help center.

### Docs home

The docs home is the first page of the docs, at `/docs/`: a large search field, the chart of what the search finds, then a card for the guides and a card for the reference.

It is a door, not a list. Its search field is the one field of the page, and the bar has none. Under it, the chart shows one segment and one chip for each kind of the search index, with its count; while a text is in the field, the counts follow the matches, and a chip keeps the results to its kind. The card of the guides lists each guide with its one line of description; the card of the reference lists each reference table with its count. It has the presentation layout.

The design: `docs/SITE.md`, "The docs home".

Do not use: docs landing page, portal, hub.

### Gallery

The gallery is the page of the site, at `/gallery/`, that shows every picture of the screen of the gallery table, in groups, each with its caption and the link to its guide.

A reader who wants to see the system finds each picture there: the desktop, the console, the programs, the developer tools, the fonts, the network, the storage and the boot. A picture on the page is a thumbnail, and its link opens the picture at its full size. It is a button of the bar, and the home links to it. It is not a list that a developer keeps by hand beside the pictures: the page is generated from the gallery table, which is checked against the folder of the pictures.

The design: `docs/SITE.md`, "The page of the gallery".

Do not use: screenshots page, album, lightbox.

### Gallery table

The gallery table is the one table of the tool that names each picture of the screen that the site shows: its file, its group, a caption of one sentence, its guide, and whether the home shows it.

It is `site_gallery_rows` in `tools/modustool/site_gallery.odin`. The gallery and the carousel of the home take their pictures and their captions from it, so a caption is written once. Each PNG file of `docs/screenshots` is in one row of it, or in the short list of the excluded files with its reason: `modustool site` stops on a picture that neither names. Example: the row of `heron.png` has the group of the mark, its caption, the guide of the design rules, and the mark of the home.

The design: `docs/SITE.md`, "The gallery table".

Do not use: picture list, screenshot manifest.

### Carousel

The carousel is the part of the home of the site that shows a few pictures of the gallery table in one row, one picture in view, with a numbered link to each picture.

The home shows a few pictures, so that it stays short; the gallery shows them all. The row scrolls sideways and stops at each picture, and a reader with no script reaches each one by its numbered link, by the scroll bar of the row or by a swipe. A small script adds keys. The carousel never changes its picture by itself.

It is not a film and not an animation: a picture changes only when the reader asks, at once.

The design: `docs/SITE.md`, "The carousel of the home".

Do not use: slideshow, banner, rotator.

### Line of time of the start

The line of time of the start is the part of the home of the site that shows each stage of the start of the machine as a segment of a bar whose width is the time of the stage.

It has two bars, because the firmware takes most of the start: the whole start on one scale, then the stages after the first one on a larger scale. Under the bars, one row for each stage gives its name and its time. Each stage has a card with what it does, its code, its line of the log and its guide. It is not the boot display, which the system draws on the screen: the tool draws the line of time from a log.

The design: `docs/SITE.md`, "The line of time of the start".

Do not use: boot chart, start diagram.

### Measure chart

A measure chart is a chart of the home of the site whose bars are the numbers of one line of a log that have one unit, on one scale from zero.

It exists by the rule "a chart or nothing": the home shows a measure only as such a chart, and each other measure is a row of the page of the measured numbers. The tool draws the chart only when the line holds every number of the chart, in its unit. Example: the kernel entries in one second with 1, 2 and 4 programs are three bars.

It is not the chart of what the search finds, whose segments are counts of entries of the index.

The design: `docs/SITE.md`, "The charts of the measures".

Do not use: benchmark chart, statistics card.

### Site control

A site control is a part of a page of the site that a reader presses: a button of the bar, a door of the home, a numbered link of the carousel, a line of a menu, a row of a list.

Each one has five states: at rest, with the pointer over it, with the focus of the keyboard, pressed, and current. One table of the tool names every site control, and one procedure writes the rules of its states. A state changes a color and never a size, and it shows at once.

It is not a link of a text, which takes the band of the track under the pointer. It is not the control of a thread, which is a capability of the kernel.

The design: `docs/SITE.md`, "The states of a control".

Do not use: widget, clickable.

### Thumbnail

A thumbnail is the picture that the gallery shows in the place of a picture of the screen: the same picture at one half of its width and of its height, which the tool writes when it writes the site.

It exists for the bytes of the page: the gallery has more than 100 pictures, and a thumbnail is about 60 000 bytes where the picture is about 157 000. Each pixel of a thumbnail is the mean of a square of 2 by 2 pixels of the picture, so a line of 1 pixel stays a line and a letter keeps its form. The text of a thumbnail is not meant to be read: the link of the thumbnail opens the picture at its full size. The repository holds no thumbnail.

The design: `docs/SITE.md`, "The thumbnails".

Do not use: miniature, low-resolution copy.

### Guide

A guide is a page of the site made from a document of `docs/`: how a part of the system is designed, and why.

Examples: `docs/ARCHITECTURE.md`, `docs/QUIC.md`, `docs/FONTS.md`. A guide states each rule with no name of a person or a role, no step, no choice and no date: git keeps who decided and when. The working records are not guides and are not published. On the site a guide has the documentation layout, and its code spans link to the declarations and documents that they name.

The design: `docs/SITE.md`, "The pages".

Do not use: article, tutorial (for this).

### Reference table

A reference table is a page of the site that the tool generates from the code or the files that define a thing: what exists in this build, each row with a link to its source line.

The tables: the kernel operations, the context of a program, the error kinds, the grants of the root service, the fixed ranges, the commands of the console and of the tool, the types, the licenses, the numbers, the modules and the module graph. Each one reads one form of its source file; when a file loses that form, the command stops with the file and the line. A row with an id is a symbol.

The design: `docs/SITE.md`, "The reference tables".

Do not use: API docs, listing.

### Module page

A module page is the reference page of the site for one module of the build: its documentation, its exports, its imports and, for a program, its grants and its budget.

The page `docs/reference/modules/<name>/` gives the documentation of the module (the comment before `package` in its source), its identity card, its source folder, its size in the boot image, its imports and the modules that import it, a figure of its neighbours in the module graph, and each export as a symbol with its signature as the console prints it. For a program it lists the grants and the budget that the root service gives it. The pages come from the same reader as the build: no module needs to be built.

The design: `docs/SITE.md`, "The module pages".

Do not use: API page, package page.

### Status page

The status page is the page of the site that gives the state of each property: its status, what it promises, what the machine test shows of it, and what is not done.

It writes no sentence of its own: each cell is a part of `docs/PROPERTIES.md` or of `docs/DEMONSTRATIONS.md`. What is not done is on it as plainly as what is done. It is a section of its own, outside the docs, and a line of the project menu of the bar. It is not the roadmap: the status page says what is built and what is missing, the roadmap says what work is planned, and one line of the status page leads to it.

The design: `docs/SITE.md`, "The status page".

Do not use: progress page, "what runs today".

### Site address

The site address is the absolute address where a host serves the site, in the form `https://<host>/<path>`.

`SITE_ADDRESS` holds it (`https://modus.froment.software/`), and `modustool site --address` sets another for one run. Some parts of a page must be absolute to be right for the program that reads them, so they exist only with a site address: the canonical address, Open Graph, the page graph and the sitemap. With no site address the pages have relative links only, and work from a folder of a disk.

The design: `docs/SITE.md`, "What other sites read".

Do not use: base URL, domain (for this), root.

### Canonical address

The canonical address of a page is its one absolute address, which the page names in its head with `<link rel="canonical">`: the site address and the folder of the page, with a final slash.

A page can be reached at several addresses (with `index.html`, through a redirect page); the canonical address tells a search engine which one is the page. Example: `https://modus.froment.software/docs/reference/licenses/`. The command checks that each page has its own and that no two pages share one.

The design: `docs/SITE.md`, "What other sites read".

Do not use: permalink, URL (for this).

### Redirect page

A redirect page is a small file of the site at an old address of a page, which sends the reader straight to the address of today.

The addresses of the site changed twice, and the old ones were public: first `.html` files (`reference/licenses.html`), then folders before the move under the docs (`reference/licenses/`). A rule gives each old path from the path of today, and a redirect page is written at each one: a refresh with a delay of 0 and one visible link, with no script. It is not a page of the site: it is in no sitemap, no search index and no feed, and it never names another redirect page.

The design: `docs/SITE.md`, "The redirect pages".

Do not use: redirect, alias, forward (for this).

### Page graph

The page graph is the JSON-LD of one page: one `@graph` of schema.org nodes, built from the data that the page shows, whose nodes name each other by their `@id`.

It tells a search engine what the page is: the site with its search, the system as a `SoftwareApplication`, its source code, the page and its breadcrumbs, and what the page is about (a `TechArticle` for a guide, a `DefinedTermSet` for the glossary, a `Blog` for the news). No value is typed for the graph. It exists only with a site address, and the command parses each graph and checks that each `@id` that it names exists.

The design: `docs/SITE.md`, "The page graph".

Do not use: structured data (for this), schema, rich snippet.

### Sitemap

The sitemap is the file `sitemap.xml` of the site: the canonical address of each page, for a search engine.

It lists each page that the command writes, once, and no redirect page. A page has a `lastmod` only when the tool knows the date of its last change (the news and the releases): a wrong date teaches a search engine to ignore the field. `robots.txt` names it. Both exist only with a site address.

The design: `docs/SITE.md`, "The sitemap, robots.txt and the feeds".

Do not use: site index, page list.

### Site menu

The site menu is the menu of the bar of the site: one `details` element that holds the sections and the search field.

One list of links serves every width, so a screen reader reads each section once. Under 720 pixels it is a square button with three lines, and the open menu lies over the page. On a wide screen it is open and its button hidden, so it reads as the bar. On the docs home it holds the sections only. With no script, the button still opens it.

The design: `docs/SITE.md`, "The site menu".

Do not use: burger menu, hamburger, drawer.

### Project menu

The project menu is the menu of the bar of the site that holds the sections that are not buttons: Status, Releases and Roadmap.

The bar is one line, so three sections are buttons, the ones that a first reader looks for: Docs, Gallery and News. The three pages that report how the project goes are the lines of one menu, under a button with the word "Project". The menu is a `details` element, so it opens and closes with no script. Under 720 pixels its three sections are lines of the site menu. It is not the site menu, which holds every section and the search field on a narrow screen.

The design: `docs/SITE.md`, "The buttons and the menu of the bar".

Do not use: dropdown, more menu, submenu, overflow menu.

### Subscribe menu

The subscribe menu is the menu under the heading of the page of the releases and of the page of the news that holds the ways to follow the changes of the system.

Its button has the word "Subscribe" and a chevron that turns when the menu opens. Its panel has two links: "Atom feed", the feed of the page (`releases.xml` or `news.xml`), and "Watch releases on GitHub", the releases of the repository. It is a `details` element, as the project menu: it opens and closes with no script, and the panel is as wide as its longest line. It is not the project menu, which is in the bar.

The design: `docs/SITE.md`, "The subscribe menu".

Do not use: RSS menu, follow button.

### Documentation layout

The documentation layout is the layout of a page of the docs: the documentation tree at the left, the text in the middle, "On this page" at the right.

Each guide, reference page, module page, the glossary, the status page and the index pages use it. The home, the docs home, the news and the releases have the presentation layout: one centred column of at most 1152 pixels. The writer of each page states its layout; the tool does not guess it from a path. Under 1100 pixels "On this page" folds above the text; under 720 pixels the tree moves into the site menu.

The design: `docs/SITE.md`, "The two layouts".

Do not use: docs theme, sidebar layout.

### Documentation tree

The documentation tree is the list of the documentation pages of the docs, generated from the pages that exist, at the left of each documentation page.

Its first link is the docs home. Then come the guides in their reading order, the reference pages, the modules in their groups (Kernel, Programs, Modules) and the status. It is one `nav` on each page, in the site menu on a narrow screen. Tree lines show its levels.

The design: `docs/SITE.md`, "The two layouts".

Do not use: sidebar, navigation tree, table of contents (for this).

### On this page

"On this page" is the list of the headings and the symbols of one documentation page, each a link to its id.

It lists the headings of levels 2 and 3 and each symbol, in the order of the page: on a module page, each export. A heading of level 3 or a symbol is a branch of the heading of level 2 before it, with a tree line. From 1100 pixels it is a column at the right of the text with its own scroll; on a narrower screen it is a `details` above the text.

The design: `docs/SITE.md`, "The two layouts".

Do not use: table of contents (for this), outline, minitoc.

### Tree line

A tree line is a line of 1 pixel that joins an item of a navigation of the site to the item above it in the tree.

A vertical line runs down from under a parent, beside its branches, and a short horizontal line, the branch, goes from it to each item. The vertical line stops at the branch of the last item. The documentation tree and "On this page" have tree lines at each level under their first list; the lines that lead to the current item are in the color of the line under a link. A list of the text of a page has none.

The design: `docs/SITE.md`, "The tree lines".

Do not use: guide line, indent guide, connector.

### Symbol

A symbol is one documented thing of a reference page or a module page: a kernel operation, a command of the console or of the tool, an export of a module, or a row of a reference table with an id.

A symbol shows its name as a heading with an id (`operation-<name>`, `export-<name>`), its signature in a block of code, the text of its source comment as Markdown, its facts (the statuses of an operation, the parameters and error record of an export) and a link to its source line. "On this page" lists it.

It is not a symbol of an object file: a module exports by index, and a name is looked up only at build time. A declaration of the sources is in the declaration index, not a symbol.

The design: `docs/SITE.md`, "The reference tables".

Do not use: entry, item, API (for this).

### Value kind

A value kind is what a technical value is for a reader, such as a number, a size, a time, a handle, a status or a module, so that every place that shows the value can give it one look.

The kinds are one enumeration of the system, `value_kinds.Value_Kind` (`src/library/contract/value_kinds`). One table gives each kind its color in each color scheme, and another its kind icon. The site and the log use the same kinds, so a size has one color on a page and in the log. The writer of a table, a symbol or a line of the log states the kind of each value: no text is classified by its look. It is not a type of a language: `Size` and `Number` can both be an `int`.

The design: `docs/SITE.md`, "The kinds of values".

Do not use: value type, badge, chip, tag (for this).

### Declaration index

The declaration index is the list of every top-level declaration of the sources of the system, which `modustool site` reads with the parser of Odin so that a code span can link to what it names.

It reads each source file of the system but the tests. For each procedure, type, constant and global variable, it keeps its package, its file and line, its kind, its one line of Odin and its comment. A code span of a guide, a news entry, the glossary or a source comment whose whole text is a name (`graphics.text_proportional`) then becomes a link with a declaration card.

It is not a symbol table of an object file, and its entries are not symbols: a symbol is a documented thing of a reference page.

The design: `docs/SITE.md`, "The declaration index".

Do not use: symbol table, symbol index (a symbol is a documented thing of a reference page), ctags.

### Declaration card

A declaration card is the short card of one declaration of the declaration index, which opens over a link that names it.

It shows the name, the kind and the package, the one line of Odin colored, the first sentence of the comment ("A procedure with no comment in its source." when there is none), and the file and line as a link. A page holds the card of each declaration that it links to once. The script opens it when the pointer rests 400 ms on the link or the focus reaches it; with no script the link works and no card opens.

The design: `docs/SITE.md`, "The declarations of the sources".

Do not use: tooltip, hover card (for this).

### Type card

A type card is what the site states of one type of the contract: its kind, its size, its alignment, its fields with their offsets and the padding, or its members with their values, where it is named, and its source line.

The size, the alignment, the offsets and the values come from the compiler that builds the tool (`type_info_of`), so they are the numbers of the build, not a reading of the text. The page of the types holds each whole card; a page that names a type holds a short card that its name opens. A reader of a record of a ring sees with it where each byte is.

The design: `docs/SITE.md`, "The types".

Do not use: tooltip, type info, hover card (for this).

### Byte layout

A byte layout is the diagram of the bytes of one record of a format: rows of 8 bytes, the offset of each row, and each field as a rectangle over its bytes with its name and its size.

It answers "where is each byte?" in the manner of the header diagrams of the RFCs. The offsets and the sizes come from the compiler that builds the tool, and the type and the comment of each field from the source, so the diagram cannot differ from the code. A guide marks its place with a fence `byte-layout`, which the tool writes and checks. A byte layout is not a type card: the card lists the fields of a type; the layout draws them in place.

The design: `docs/SITE.md`, "The byte layouts".

Do not use: packet diagram, struct diagram, byte map.

### Guide diagram

A guide diagram is a picture in SVG that the tool draws, when it builds the site, from a fence `mermaid` of a guide: a flowchart or a sequence diagram.

It shows the parts of the system and their order, or a flow in time, in the page of the guide, with the colors of the site and no script. The tool reads a stated subset of the text form of mermaid, measures each label with the font that the site serves for the diagrams, and lays out the boxes and the lines itself. A diagram that it cannot draw stops the build of the site with its file and its line. The text of the diagram stays under the picture. A guide diagram is not a byte layout: a byte layout draws the bytes of a record from the code.

The design: `docs/SITE.md`, "The diagrams".

Do not use: mermaid chart, rendered mermaid.

### Identity card

An identity card is what the site states of one module: its name, its kind, its hash, its size, the counts of its exports, its imports and the modules that import it, its license, and the first sentence of its documentation.

It answers "what is this module?" in one box: the hash is its identity (64 hexadecimal digits), the counts place it in the module graph, and the license comes from the license rows of its source folder. The module page shows it after the documentation; the page of the module graph shows it for the node under the pointer or the focus.

The design: `docs/SITE.md`, "The identity card".

Do not use: tooltip, hover card, module info (for this).

### Document pointer

A document pointer is a part of a source comment that names a document of `docs/` and a place in it, for a reader of the code.

Examples: `(docs/ARCHITECTURE.md, "Kernel systems")`, `docs/FONTS.md, section 12.4`. A pointer is how a comment stays short: the comment gives the reason in a few words and points to the guide for the rest. `modustool site` checks every pointer of every source file: a label that finds no heading stops the command. On a page, the site writes a document reference in its place.

The design: `docs/SITE.md`, "The forms of a pointer".

Do not use: doc link, citation (for this).

### Comment breach

A comment breach is a comment of a source that names a property, a choice, a step, a review, a finding or a decision by its number, its label or its date, in place of the reason.

A number means nothing to a reader of the code, and it goes stale when the record changes. So a comment states the reason in plain words, or points to a heading of a guide. `modustool check` reads every comment of the sources and fails on each breach, with its file, its line and its form: "(property 14)", "(P20)", "choice 186", "D-047".

The design: `docs/TOOLS.md`, "The comments of the sources".

Do not use: violation, lint error (for this).

### Document reference

A document reference is what a page of the site writes for a document pointer, or for a code span that names a document: a link with the title of the document and the text of the heading that the pointer names.

Example: the pointer `(docs/ARCHITECTURE.md, "Kernel systems")` becomes the link "Architecture: Kernel systems", in the color and with the icon of the value kind Guide. A comment shows its references on one line "See:" after its text, so no reference breaks a sentence. A reference to a working record links to the file in the repository, and says so. The command prints the count of references and those whose labels found no heading.

The design: `docs/SITE.md`, "The references to documents".

Do not use: tag, badge, cross-reference (for this).

### Wire form

A wire form is one of the types of the call form of the module contract, a member of `Type` of `src/library/contract/module`: Integer, Text, Record, Handle, Table or Bytes.

It says how a call carries a parameter or a result: in one word of the call form, and what that word holds or points to. An Integer is the value; a Text, a Record, a Table and Bytes are an address of memory of the caller with a header; a Handle is a handle number. Because each parameter has a wire form in the description of an export, one export serves a direct call, an isolated call and the console with no glue code.

The design: `docs/MODULE_CONTRACT.md`, "5. The types".

Do not use: marshalling type, ABI type.

### File version

A file version is the first 8 bytes of the BLAKE3 hash of a file of the site, in hexadecimal, added as `?v=<version>` to each link to that file.

A proxy in front of the site keeps a file for hours. The style sheet, the scripts and the search index change between builds, so each link names their bytes: `style.css?v=<16 hexadecimal digits>`. A new build gives a new address, and no proxy serves an old file with a new page. The same bytes give the same address. A page itself cannot carry a version; the line "This page is from an older build: reload" covers that case.

The design: `docs/SITE.md`, "The versions of the files".

Do not use: cache buster, fingerprint, hash suffix.

### Site workflow

The site workflow is the workflow of GitHub Actions `.github/workflows/site.yml`, which builds the site at each push to `master` and gives it to GitHub Pages.

It holds no logic: each step calls `modustool` or an action pinned by its version tag. It builds the boot image (`modustool build`) and the site (`modustool site`), then deploys `build/site`. A failed check of the site stops the run, and the site of the last run stays online. It runs no machine test: the numbers come from the measure record.

The design: `docs/SITE.md`, "How the site is published".

Do not use: pipeline, CI job, deploy script.

### Release workflow

The release workflow is the workflow of GitHub Actions `.github/workflows/release.yml`, which publishes the release image, the checksum list and the release signature of a release at each push of a tag `v<release number>`.

It holds no logic: each step calls `modustool`, Nix or an action pinned by the commit of its version. A first job runs `nix flake check` of the tagged commit. A second job, the one that reads the keys, checks that the tag names the release number, writes the key folder and makes the files. A third job, with no key, creates the release of the tag with the files and with the notes of the release from `CHANGELOG.md`. A failure stops the run, and nothing is published.

The design: `src/md/infrastructure/release_image.md`.

Do not use: release pipeline, deploy script.

### Check workflow

The check workflow is the workflow of GitHub Actions `.github/workflows/ci.yml`, which runs `nix flake check` at each push.

It holds no logic: one step calls Nix. `nix flake check` runs the hooks and `modustool check` in an empty folder, with the machine tests. A newer push of the same branch cancels an older run.

The design: `docs/TOOLS.md`, "The commands of the tool".

Do not use: CI pipeline, build job.

### Test part

A test part is one row of the table of the machine test: one or more machines that share a data disk, a TPM state or a value from one machine to the next, and nothing with another test part.

`modustool test <part>` runs one test part alone and builds only its boot volumes; `modustool test` runs every test part, several at once, at most one for each four processors of the host. Each test part starts from a new data disk of its own, so it does the same work alone and in the whole test. Example: the test part `random` runs three machines, and its last step checks that the values that the three machines drew differ.

The design: `src/md/infrastructure/machine_test_parts.md`; `docs/TOOLS.md`, "The parts of the machine test".

Do not use: test suite, test group, shard.

### Full check

A full check is `nix flake check` and `modustool screenshots`, both passed.

`nix flake check` runs the hooks and `modustool check` in the sandbox of Nix: the host tests, the checks of the sources, the whole machine test and the second build. It sees only the tracked files of the folders that `flake.nix` names. `modustool screenshots` takes the pictures and the logs of that check from the store, with no second run of the machine test, runs the measure runs on the host, and writes the measure record. A full check runs once at the end of a batch of features, before the release and the publication of the site; each merge before it needs only its build and the test of its own test part.

The design: `src/md/infrastructure/full_check.md`; `docs/TOOLS.md`, "What each tool reads".

Do not use: CI run, test suite, full test.

### Incremental build

An incremental build is a build that keeps each output of an earlier build whose inputs are the same, and builds only the others.

It rests on the rule of the reproducible build: the same inputs give the same bytes. `modustool build` keeps a module when the build record of each of its two steps has the build key of its inputs, and each output has its recorded hash. It runs the conversion alone when only the file of an import changed. The tool builds in every case of doubt: no record, a damaged record, a changed or missing file. It is not a cache: the kept output is the file of the build folder itself.

The design: `docs/TOOLS.md`, "The incremental build".

Do not use: build cache, cached build, partial build.

### Build key

A build key is one BLAKE3 hash over the inputs of the build of one thing (one step of a module, or one boot volume), in a fixed order.

A module has two keys, one for each step of its build. The key of the compile step covers each source file that the compiler reads, the commands with each flag, the programs of the build and the tool. The key of the conversion covers the key of the compile step, the linked file and the module file of each import. The tool never records and never compares a key with an input that it cannot read. It is not the hash of a module, which names the output.

The design: `docs/TOOLS.md`, "The incremental build".

Do not use: cache key, fingerprint, input hash (for the whole key).

### Build record

A build record is the small text file that the tool writes after it built one thing: its build key, the hash of each output, and the list of the files that the compiler read.

A module has one for each step of its build, in `build/modules/`; a boot volume has one in `build/boot/`. At the next build, the tool computes the build key again from the recorded files as they are now, and keeps the outputs when the key is the same and each output has its recorded hash. A record that is absent or damaged is no record: the tool builds, with no error.

It is not the measure record and not the line of the reproducible build that the site quotes.

The design: `docs/TOOLS.md`, "The incremental build".

Do not use: cache entry, stamp, manifest (for this).

### Compile step

The compile step is the first of the two steps of the build of a module: the compiler, `llc`, the assembler and the link, which give the linked file of the module.

It reads the sources of the module and no file of an import: a source declares an export of an import in a `foreign` block, and the link leaves that symbol not defined. So its build key holds no import, and a change inside an import does not run it. The tool runs it when a source, a command, a program of the build or the tool changed, or when the linked file is gone.

It is not the whole build of a module: the conversion follows it.

The design: `docs/TOOLS.md`, "The incremental build".

Do not use: compile phase, compiler stage, object step.

### Conversion

The conversion is the second of the two steps of the build of a module: the tool writes the module file from the linked file, with the description of the exports and the hash of the file of each import, then the debug object.

It is the one step that reads the file of an import. When the file of an import changed and the sources of the importer did not, the tool runs the conversion alone. A converted module has a new hash, so each module that imports it is converted too. Example: a change of the body of an export of a library builds the library and converts each of its importers.

It is not a link: no code of the import enters the module.

The design: `docs/TOOLS.md`, "The incremental build", and `docs/MODULE_CONTRACT.md`, "The steps of one module, as implemented".

Do not use: relink, repackage, packaging step.

### Whole build

A whole build is a build that ignores every build record: it builds each module and each boot volume, and writes new records.

`modustool build whole` asks for one. The commands that prove the build are always whole builds: `check` and `repeat` compare the results of two runs of the compiler, and a kept output would be compared with itself. `nix flake check` builds in an empty folder, so its build has no record to read.

The design: `docs/TOOLS.md`, "The incremental build".

Do not use: clean build, fresh build, full build.

### Measure record

The measure record is the file `docs/measures/measures.txt`: the measured numbers of the last full check, each as the whole line of its log, with the facts of its run.

The site workflow runs no machine test, so the pass that commits the pictures also commits the numbers. `modustool screenshots` writes the record: one line `key value` for each fact (its time, its release, its commit, the state of its tree, its host, the count of checks that passed in the check of the flake and in the measure runs), then each number with its log, its line and its machine, and the stages of the start. The site reads it when the logs of `build/` are not newer. A number of speed is a measure: it is printed and recorded, and never makes a test fail.

The design: `docs/SITE.md`, "The measure record".

Do not use: benchmark results, metrics file, numbers cache.

### Measure history

The measure history is the folder `docs/measures/releases/`: one copy of the measure record for each release that a full check measured, named by its release number.

It lets a reader see whether a change made the system faster or slower. `modustool changelog release` writes the copy of each new release. A release whose record holds the same run as the release before gets no copy. The page of the measured numbers draws, from the copies, one chart for each measure over the releases: one number of its line, at equal steps, from zero. It is not a record of each full check: a full check between two releases replaces the measure record only.

The design: `src/md/features/measure_history.md`; `docs/SITE.md`, "The measure history".

Do not use: benchmark history, performance log, trend file.

### Measure run

A measure run is a machine whose boot image holds the resource `measure_run`, in which each program measures its rates over a duration.

In a test, a program runs its checks by a count of work and writes no rate. In a measure run, the root service says so in the context of each program; the program reads it with `system.measure_run()`, runs the same work for a fixed duration, and writes its rates. Only the boot image differs from the test: it has one resource more. `modustool measure` starts a measure run; `modustool test` never does. It is not the measure build, a build of the kernel with no check.

The design: `docs/TOOLS.md`, "A check by count, a measure by time".

Do not use: benchmark mode, benchmark run, performance mode.

### Settled screen

A settled screen is a screen that shows the last picture of each window: each program sent the picture of its last change, and the compositor drew each picture that it received.

The machine test takes a picture only of a settled screen. When it can call the compositor, it reads the state of the programs before and after it reads the windows and the screen: a program that waited in the two reads, with the same count of kernel entries, did not run between them. When it cannot call, it takes pictures until two in a row are the same. A window that draws with no end is left out. It is not a fixed time before a picture.

The design: `docs/TOOLS.md`, "When the tool takes a picture".

Do not use: idle screen, stable frame, quiescent.

### Due picture

A due picture is a picture that a program owes its window: a change waits for it while the program waits on its clock or for the compositor.

A program that paces its pictures, such as a terminal, says it before such a wait with the record `Picture_Due` (`display.picture_due_set`), and its next `Present` ends it. The compositor gives it as `due` in `compositor.windows()`, and the screen is not a settled screen while a window has one. The terminal decides it at the start of each turn of its loop, so a record that came while it drew its last picture is a due picture too. It is not a picture that the compositor has and did not draw yet: that is `waits`.

The design: `src/md/features/terminal_due_picture.md`.

Do not use: pending frame, redraw flag, frame request.

### Hang bound

The hang bound is the one time in a test: it ends a test that waits for ever, and checks nothing about speed.

A test checks a condition. A time in it has one role, to end a hang, so it is generous and the same for each wait: `HANG_BOUND` for a step of a machine test, and `system.TEST_HANG_BOUND_MILLISECONDS` for the checks of a program, so that the program reports its own hang before the tool ends the machine. A bound of its own needs a named constant with its reason. It is not a timeout that a test asserts: no test fails because the host is slow.

The design: `docs/TOOLS.md`, "The bounds of the tests".

Do not use: timeout (for a test), deadline (for a test), time limit.

### Stall

A stall is a case that writes a count of its progress and whose count did not grow for the hang bound.

A long case (the fault ring under load, for example) can take any time on a slow host and still be right. So the test bounds a stall, not the whole run: it ends the case when the count stays still for `system.TEST_HANG_BOUND_MILLISECONDS`, or after 600 s in all. The report names the step where the count stopped, which tells a lost wake from a slow host.

The design: `docs/TOOLS.md`, "The bounds of the tests".

Do not use: freeze, no progress timeout, watchdog.

### Fuzz target

A fuzz target is a procedure of the tool that gives one fuzz input to the real code of the system on the host and checks its oracles.

It calls the procedures that the system runs, from the source library `modus`, never a copy of them. A raw target gives the input as the bytes that the system reads; a generated target reads the input as choices and builds a whole value from them. The tool runs a target in a child process, so a fault ends the child and not the tool. `modustool fuzz list` names the targets. It is not a host test: a host test checks the cases that its writer chose, a fuzz target the cases that the engine makes.

The design: `src/md/infrastructure/fuzzing.md`.

Do not use: fuzzer harness, fuzz driver, fuzz test.

### Fuzz input

A fuzz input is the bytes of one execution of a fuzz target.

For a raw target, they are the bytes that the code of the system reads. For a generated target, they are a choice sequence: the generator reads its next choice from them at each decision, and reads zeros when they end. Both kinds are bytes, so one engine, one minimizer and one corpus serve both.

The design: `src/md/infrastructure/fuzzing.md`.

Do not use: test case (for this), seed (for this), sample.

### Corpus

The corpus is the set of fuzz inputs of each fuzz target that the repository keeps, one file for each input, named by the BLAKE3 hash of its bytes.

It has the regression inputs, one for each fuzz finding after its fix, which stay for ever, and the reach inputs, the smallest set of inputs that gives each edge class that the long runs reached. `modustool check` runs each input of the corpus again and refuses a corpus over its bounds.

The design: `src/md/infrastructure/fuzzing.md`.

Do not use: seed corpus, test suite (for this).

### Edge counter

An edge counter is a byte that instrumented code adds one to each time it passes one edge of its control flow.

`opt` of the LLVM of the build adds the counters to the IR of the packages under test, and the fuzz target reads them after each execution. An input is kept when it gives an edge a count in a class that no kept input gave. In the planned fuzzing of the kernel operations, the counted kernel gets counters too, which only the tool reads, through the memory file of the machine (`src/md/infrastructure/kernel_fuzzing.md`). It is not the coverage of a glyph.

The design: `src/md/infrastructure/fuzzing.md`.

Do not use: coverage (for this), code coverage, bitmap.

### Oracle

An oracle is a condition that a fuzz target checks after each execution of a fuzz input.

The oracles are, in order: no fault, an end before the hang bound, the contract of the reader, a round trip through the writer, a model that gives the same answers, and a second reader of the system that agrees.

The design: `src/md/infrastructure/fuzzing.md`.

Do not use: assertion (for this), checker.

### Fuzz finding

A fuzz finding is a fuzz input that breaks an oracle, with its signature: the oracle and the place of the fault.

Two inputs with one signature are one fuzz finding. The tool minimizes each one while its signature stays. After its fix, its input enters the corpus as a regression input, and a host test names the expected answer when it is more than "no fault".

The design: `src/md/infrastructure/fuzzing.md`.

Do not use: crash (for every finding), bug report.

### Operation sequence

An operation sequence is the fuzz input of the kernel operations: a list of sequence steps whose arguments follow the forms of `OPERATIONS`, which a child program runs in a test machine.

Its format is the contract package `operation_sequence`: a header, the sequence areas, the sequence steps, and the content of the areas. A handle argument names a start handle or the result of an earlier sequence step by its place, so the sequence does not depend on the values of the handles of one run. The tool builds sequences from choices with a generator, and `check` reads them; the machine that runs them is planned work of `ROADMAP.md`.

The design: `src/md/infrastructure/kernel_fuzzing.md`.

Do not use: syscall program, call trace.

### Sequence step

A sequence step is one command of an operation sequence: an operation word, its flags, and seven arguments, each with its argument source.

The runner writes one command record for each sequence step, and enters the kernel for each one, or once for the steps that the flag "same kernel entry" joins. A sequence step names the result of an earlier step by the place of that step, never by a handle number. It is not a step of the project, which is a commit, and not a step of a machine test.

The design: `src/md/infrastructure/kernel_fuzzing.md`.

Do not use: call (for this), syscall, instruction.

### Argument source

An argument source is where the value of one argument of a sequence step comes from: a plain value, a start handle, an address in a sequence area, a thread entry of the runner, or the result of an earlier sequence step.

It is the enumeration `operation_sequence.Argument_Source`. `check` refuses a word that names no member, and a word that the source does not use and that is not 0. The runner converts each argument into the word of the command record at its run, so one sequence means the same at each run.

The design: `src/md/infrastructure/kernel_fuzzing.md`.

Do not use: argument kind, argument type (for this).

### Sequence area

A sequence area is a memory object of 1 to 16 pages that the runner maps for an operation sequence, with a page with no access after it, and that an address argument names with an offset.

The sequence gives the bytes of the start of each area, at most 4096 bytes for all its areas. An offset can reach the page with no access, so a record that crosses the end of an area is an input of the kernel. The runner holds a start handle with each right of memory for each area. It is not a thread area and not the extended state area.

The design: `src/md/infrastructure/kernel_fuzzing.md`.

Do not use: buffer (for this), region (for this).

### Counted kernel

The counted kernel is the test kernel `kernel_edge_counters`: the sources of the kernel built with an edge counter at each edge, which counts only for a counted program.

The tool reads its counters through the memory file of the test machine, and no program of the system reads them. The release refuses it by its hash, by its signature and by its bytes. A finding on it is confirmed on the kernel that ships, which has no counter. It is planned work of `ROADMAP.md`. It is not the measure build, and not the test build of the kernel checks, which every kernel of the tests has.

The design: `src/md/infrastructure/kernel_fuzzing.md`.

Do not use: instrumented kernel, coverage kernel.

### Counted program

A counted program is a program whose commands and exceptions the counted kernel counts: the runner of the operation sequences, by its name, and each program that a counted program creates.

The counters then say which kernel code one operation sequence reached, and not what the tick, the scheduler or another program did. The kernel that ships has no counted program. It is planned work of `ROADMAP.md`.

The design: `src/md/infrastructure/kernel_fuzzing.md`.

Do not use: traced program, program under test (for this).

### Tagline

The tagline is the one line under the name in the head of the home of the site: the first sentence of the first paragraph of `README.md`.

The rest of that paragraph is a section "What it is" lower on the home, after the news, so the first screen of a phone holds the mark, the name, the tagline and the links. The description of the home in its head and in the page graph stays the whole paragraph, cut at 160 bytes. Like every description of the project, it says what the system does for its user, and names no technical part.

The design: `docs/SITE.md`, "The pages".

Do not use: slogan, subtitle, hero text.

## Terms that the system does not have

These words name concepts that the system removed. Use them only to describe other systems.

file, path, directory, pipe, socket (as an object), signal, fork, environment variable, `argv`, standard input and output, user, group, root, installer, driver (in the kernel), system call table, TTY, shell script, save.
