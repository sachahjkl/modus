# The debug object of a disk program

## Purpose

A disk program runs from a module file of the store `programs` ([programs_from_a_disk.md](programs_from_a_disk.md)). Its module is not in the boot image, so the debug image of the machine has no debug object for it: the debugger shows its frames as offsets, with no procedure and no line. A developer who builds a module outside the repository ([`../infrastructure/third_party_module.md`](../infrastructure/third_party_module.md)) runs it on a machine as a disk program, and needs the names of its procedures and its lines there.

This file is the design of where that debug object comes from, who reads it, and how the debugger uses it. The guide is [`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "The debug object of a disk program".

## Constraints

- **The hash of a module is its identity.** Debug information must not change the module ([`../infrastructure/debug_information_and_code.md`](../infrastructure/debug_information_and_code.md)).
- **The storage service is a transport.** It can give any bytes under a name. The root service already refuses to start bytes that do not have the hash of the command.
- **No program gets a new authority by the name of a grant.** The debugger service holds no store.
- **The debugger service never waits without a bound.** Each export ends under the 5000 ms after which the service `remote` ends a call.
- **No change of the boot image.** A disk program is added with no new boot image, so its debug object is not added to the debug image either.

## The chosen form

### Where the debug object is

The debug object of a module file is an object of the root tree of the same store `programs`, beside the module file. The name of the object is the 64 hexadecimal digits of the hash of the module, in lower case (`disk_program.debug_object_name_write`).

- The name is fixed by the module. A nickname is a choice of the principal, and one file can have two nicknames; the hash names the one module that the debug object describes.
- A nickname has at most 23 bytes, so no nickname is a debug object name, and `programs.receive` never writes a module file over a debug object.
- `programs.list()` lists module files only: it skips a debug object as it skips `grant_table`.

The command `program-disk` of the tool writes the debug object beside each module file when the file `<name>.debug` is next to `<name>.module`, as `module-build` writes them. It refuses a debug object that does not name the hash of its module: the tool does not put a wrong object on a disk.

### Who reads it

The debugger service reads it, at `attach`, for the one module of the program that is not in the boot image. It reads through the storage service, with a connection that the root service gives for that one debugging:

1. At `attach`, the debugger service finds a module record whose hash has no entry in the boot image and no object in the debug image: the module of a disk program.
2. It sends the command `Debug_Store` of the root ring, with the name of the program and the call ring of its caller, as for the command `Debug`.
3. The root service answers only when it gave this service the debug access to that program for that caller, and when the program is a disk program. It opens a connection to the store `programs` of the principal of the program, with the limit of that store and the flag that the connection reads only (`isolated.CALLER_READS_ONLY`). The debugger service receives the call ring, the call region and the storage service with the right Read.
4. The debugger service asks for the size of the object, reads it in ranges into memory of its own budget, and checks it whole: `debug_object.check`, then the hash that the object names must be the hash of the module record. Then it closes its side of the connection.
5. On each path after the connection was given, the debugger service sends `Debug_Store` again with the flag of an end, and the root service ends the connection. So the connection lives for the read only: it holds no connection place of the storage service (8 for each service) and no place of its service ring for the rest of the debugging.
6. The root service also ends the connection when the debug access ends (`debug_end`), whatever the debugger service does.

The root service finds the program by the debug access that it gave this service for that caller, and by its name: two principals can run disk programs of one nickname, and the name alone can name the program of the other.

The bounds: the object has at most 8 MiB (`disk_program.DEBUG_OBJECT_BYTES_LIMIT`). The answer of the root service and the read have one deadline of 1500 ms together. With the 2000 ms of the answer to `Debug`, the waits of `attach` take at most 3500 ms: 1500 ms stay under the 5000 ms after which the service `remote` ends a call, for the reports of the program, the attach in the kernel and the transit of `remote`. Each answer of the storage service must make progress, with the rules of a load (`disk_program.read_step`). A read that fails is one line of the log, and the attach goes on with no debug object for the module.

### How the debugger uses it

The debugger service looks up an address of the module in this object, as it looks up a module of the boot image in the debug image. `stack`, `events`, `threads`, `registers`, `break_at`, `watch`, `locals` and `value` name the procedures, the lines, the types and the variables of the disk program. The column `module` of a row names the program. `source` gives the path, the line and the hash of the file, as for each module: the machine holds no source text, and a reader on the host shows the line from a file with that hash.

The object stays in the memory of the service until the debugging ends.

### The stop report of a disk program

A developer whose outside module faults must read where it faulted with no attach: the fault already happened, and a program that stopped cannot be attached to.

**Where the stop report is.** The kernel keeps the stop report of a program while a handle names the program. The root service holds the only handle of a disk program, and closes it when it reaps the stopped program, in the same pass of its loop. So the console, `inspect` and `errors` never see the stop report of a disk program: the console reads the stop report of a call host that it started, `errors` the stop report of its own cases, and `inspect` a program that a handle still names. The kernel line of the fault names the module by the start of its hash and an offset.

**The chosen form.** The root service keeps the stop report, and the debugger service names it:

1. At the reap of a disk program whose stop report is not zero (a fault), the root service reads the report with its handle, takes out each value that can be a word of the memory of the program (`disk_program.stop_report_hide`), and keeps it with the principal, the nickname and the hash of the module file (`disk_program.Kept_Stop_Reports`). The log says "root: kept the stop report of <nickname>, a disk program of principal <n>: stop_report(\"<nickname>\") names its frames".
2. `stop_report("<nickname>")` in the console calls the export `stop_report` of the debugger service. The service sends `Debug_Store` with the flag of a kept stop report (values[6]).
3. The root service answers when the caller acts for its principal, its grant `debug` is not revoked, and the root service keeps a stop report of a disk program of that principal with that nickname. The answer is the connection that reads only of an attach, and a fourth handle: one page with the kept stop report, which the service may read only.
4. The service copies the report, reads the debug object of the hash that the report names, with the bounds and the check of an attach, closes the connection, and sends the end. It gives one row for each frame: the module, the procedure, the offset, the file and the line, and in the row 0 what stopped the program. A row gives no absolute address: the module and the offset name the place. Then it frees the object. When the service debugs the same module, and the store of the same principal gave its object, it uses that object and reads none: another store can hold other names under the same hash.

The reasons:

- **The root service holds the report, and reads no debug object.** Its loop already holds the handle at the stop. A copy of one record costs about 1 KiB for each kept report. A debug object is a large input from a transport that the root service does not trust: its reader stays in the debugger service, which has the bounds and the check already.
- **The debugger service names it.** It is the one program that reads the debug object of a disk program, through the one connection that the root service gives for it. A second reader of the store, in the console, would be a second path with its own bounds.
- **The rule is the rule of `inspect`, for one principal.** The kept report is in the form that `Inspect` gives to each holder of the machine with the right Inspect: only the frames that a module record holds, and the address of a page fault in the first page or in the module of the instruction. The caller must act for the principal of the program, which can read the store `programs` and its debug objects anyway. The debug access is not needed: the report holds no byte of the memory of the program.
- **A command flag, not a new command.** The flag changes only which program the connection is for: a program that the service debugs for that caller, or a kept report of the principal of that caller. The connection, its bounds, its end and its reader are the same.

The bounds: the root service keeps 8 reports (`disk_program.KEPT_STOP_REPORT_CAPACITY`). A new fault of a nickname replaces the report of that nickname. Else a principal that holds 4 places (`disk_program.KEPT_STOP_REPORTS_OF_ONE_PRINCIPAL`) gives its own oldest place, so the faults of one principal never take more than half of the table from the others; else a new report takes a free place, or the place of the oldest. A stop of a nickname with no fault removes the report of its older fault: a kept report always tells how the last run of the nickname ended. An age in the row 0 was refused: a reader would have to compare it with runs that the system does not list. The reports last until the machine stops. The export waits at most 1500 ms for the answer and the read together, as the read of an attach. The connection ends at the end that the service sends, when the caller or the service stops, and when a new connection of the service replaces it.

## Refused forms

- **The debug object inside the module file.** It changes the hash of the module, and so the identity that the principal names in `start_from_disk`. A build with debug information and one without would give two modules.
- **Trusting a debug object that names another hash.** It describes another build: its offsets name the wrong procedures. The reader refuses it, as each reader of the debug image does.
- **The debug object under the nickname** (`visitor.debug`). One file can have two nicknames, and a move of a nickname to a new file would leave the old object under it.
- **A tree `debug` in the store.** The name `debug` would be a third name that no nickname can take. The names of 64 digits need no reservation.
- **The root service reads the object at the load of the program.** It reads a large object for each start, also for a program that nobody debugs, into the budget of the root service.
- **The debug object in the debug image.** The debug image is a file of the boot volume: a disk program would need a new boot volume.
- **A start grant `Store` or `Acts_For_Principal` for the debugger service.** `Store` gives the store `debugger`, not the store `programs`. `Acts_For_Principal` gives a view of each store of the principal, for each caller. The debug access to one program already says that its caller may read each byte of that program: the connection is a part of that access, lives for the read of one object, and ends at the latest with the access.
- **A connection that can write.** The debugger service has no reason to change the store, and the store holds the disk grant table.
- **A connection that lives for the whole debugging.** It holds one of the 8 connection places of the storage service while a developer debugs: a connection of another program, or the load of a module file, can then fail with `No_Slot`. It also keeps the reach of the whole store open for no use.
- **A read that waits for the storage service with no deadline.** The service is the debugger of one program for one caller, and serves each other caller between two calls.
- **The console, `inspect` and `errors` name the frames of a disk program themselves.** None of them sees its stop report: the root service reaps the program, and the report leaves the kernel with the last handle. Each would also need its own reader of the store and its own bounds.
- **The root service names the frames, and writes a named stop report on the log.** It would read and check a debug object of up to 8 MiB, from a transport that it does not trust, into its own budget: the code that reads hostile input moves into the program that holds every grant.
- **The root service keeps the stopped program until a reader comes.** A stopped program keeps its pages and its slot while a handle names it: the one budget of all disk programs would pay for a program that does not run.
- **The console receives a handle of each disk program that it starts, with the right Read.** The console would hold a handle that keeps a stopped program, and it would need a reader of the store in each program that shows a stop report.
- **The whole stop report, as `Program_State` gives it.** A frame that no module record holds, and the address of a page fault outside the module, can be words of the memory of the program. The caller of the kept report holds no debug access: it gets what `Inspect` gives.
- **The kept report read by any caller with the grant Inspect.** The debug object is an object of the store of one principal. A caller of another principal would read the names of its procedures and its sources.

## Subtle points

- **The store of the principal of the program, not of the caller.** The root service gives the debug access only when the two are the same; it names the store by the principal of the program.
- **The connection reads only.** The storage service refuses each change on it (`No_Grant`, unit `Changes`, the result `storage.Export_Error.Place`), as on a share that reads only. A share made from it reads only.
- **The connection reads the whole store, not one object.** Its root is the root tree of the store `programs` of the principal: each module file, each debug object, `grant_table`, and the versions of each. That is more than the program that the caller may debug. It is accepted because the reach is small and short: the holder is the debugger service, a program of the system that the root service starts; it reads one object by a name that it computes from the hash, and no export of it gives a byte of the store to a caller; the connection lives for that read only, at most 1500 ms, and ends at the end of the read or of the debug access; it cannot change the store, and the disk grant table is no secret: its tag protects it against a change, and it holds no key. A connection to one object is not built: the storage service names a connection by a store, and a share of one object would need a share by the module file service or by the root service, which holds no connection to the store while a debugger reads.
- **The read is part of `attach`.** No other export of the service waits for the storage service. A second module of a disk program, when a disk program imports from the store, needs a second object; today one module of a disk program is not in the boot image.
- **The console, `inspect` and `errors` read the debug image only.** They never hold the stop report of a disk program. The export `stop_report` of the debugger names it.
- **A kept report outlives its program.** The nickname can name another file since: the report keeps the hash of the file that faulted, and the service reads the debug object of that hash, never of the nickname.
- **The object of a kept report is read into the budget of the service.** The budget holds one debug object of the largest size. While the service debugs a disk program with a large object, the read for a stop report of another module can find no memory: one line of the log says so, and the rows name offsets. A report of the module that the service debugs, for the same principal, uses the object that it holds.
- **The page of the report is memory of the root service.** The root service makes it, gives it with the right Read only, and closes its own handle at once: the service holds it until it copied the report.

## Built and left

Built: the name of the object, the command `program-disk` that writes it, the list of the module file service that skips it, the command `Debug_Store` of the root ring, the flag of a connection that reads only, the read at `attach` with its bounds and its check, and the names of the debugger for the module of a disk program. The test part `disk_programs` attaches the debugger to an outside module from the disk, and waits for the procedure, the file and the line of a frame. The kept stop report of a disk program: the root service keeps it at the reap, `Debug_Store` with its flag gives it with the connection, and the export `stop_report` names its frames. The test part `disk_programs` starts a copy of the outside module that faults, and waits for the procedure, the file and the line of its frames.

Left:

- **The debug object of an import from the store.** It comes with the imports of a disk program from the store `programs`.
