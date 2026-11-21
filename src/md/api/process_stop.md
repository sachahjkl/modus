# The stop of a process: its stop cause and its stop outcome

A stopped process has two facts, kept apart: its stop cause, which the kernel records and no process can forge, and its stop outcome, which a process chooses only when it stops itself. This file records the two enums, how they cross the border of the kernel, their readers, the error record of a failed stop as a later step, the migration from the open stop code, and the forms that were refused.

The operation is in `src/library/modus/contract/operation/operation.odin`, `Process_Stop` and `Process_State`. The terms are in [`docs/glossary/running_code.md`](../../../docs/glossary/running_code.md), "Stop cause" and "Stop outcome".

## The purpose

Before this design, a stopped process had one number, its stop code. `Process_Stop` took any value from the process that stops itself and from any holder of its process handle with **Control**. The kernel wrote its own stops in a range of the same number: `0x100` plus the vector, `0x200`, `0x300`, `0x400`, `0x500`. Three faults followed:

- **A holder forges the end of a process.** A holder with Control stops a process with the code 0, and every reader reads "done". The root service does it at each stop that it makes.
- **A reader decodes a number.** The console, the root service, the start policy and the machine tests compare codes with constants of each module (`0x10E`, `42`, `REPAIRS_CODE | bits`). Property 22 forbids a task that needs a number ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "22. General mechanisms, and a plain expression for each frequent task").
- **The stop carries data.** Children of `fault_ring`, `return_fault`, `debugged` and `kernel_events` put result bits or the number of a step in the code. Property 19 forbids exit codes as a result ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "19. A command is a function: no text between processes").

## The constraints

- The kernel interface is counted ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "1. Small kernel with a small, counted interface"). No operation is added.
- A closed set of choices is an enum with the values of its contract. A word becomes its enum at one place, the border, which refuses a word that names no member ([../infrastructure/choice_constants.md](../infrastructure/choice_constants.md)).
- A process sees no process that it did not start ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close", row 1). A stop fact must not name another process.
- The kernel holds no text and no parser.
- A holder with **Read** reads the facts of a stopped process until its last handle closes. The kernel then forgets them.

## The chosen form

### Two facts, two authors

| Fact | Author | Set when | Who can forge it |
|---|---|---|---|
| Stop cause | the kernel | every stop | nobody |
| Stop outcome | the process | it stops itself | nobody else: it is the claim of the process about its own work |

The stop outcome is `None` for each stop cause but `Itself`. So a reader that checks `outcome == .Done` has also checked that the process stopped itself. That is the one check of a clean stop.

### `Stop_Cause`

```odin
Stop_Cause :: enum u32 {
	None              = 0, // The process has not stopped.
	Itself            = 1, // It called Process_Stop on itself. Its stop outcome says why.
	Holder            = 2, // Another process stopped it with a process handle with Control.
	Last_Thread_Ended = 3, // Its last thread ended with Thread_Stop. It chose no stop outcome.
	Handles_Closed    = 4, // The last handle to it closed.
	Fault             = 5, // A processor exception that no fault handler took, or that a handler answered with a stop. The vector is in the stop report.
	Not_Committed     = 6, // A page fault on a page of an Uncommitted object that is not committed.
	Cannot_Return     = 7, // The processor refused the return of the kernel to one of its threads.
	Fault_Unanswered  = 8, // Its fault ring ended while one of its threads waited for an answer there.
}
```

`Last_Thread_Ended` is not in the first list of members. The kernel has that path today: the end of the last thread stops the process with the code 0. Under `Itself` it would need an outcome that the process never chose. With the outcome `Done`, it would forge a clean end.

`Not_Committed` and `Cannot_Return` keep their own members, as their stop codes did. They are not faults of the code: the first is a growth that the process did not pay, and the second can come from a frame that a holder wrote with thread control.

### `Stop_Outcome`

```odin
Stop_Outcome :: enum u32 {
	None               = 0, // No outcome: the process did not stop itself, or it runs.
	Done               = 1, // The work is finished.
	Failed             = 2, // The work could not be done. The cause is in its log, later in its error record.
	Refused            = 3, // Its input, its arguments or its context were refused: no fault of the process.
	Stopped_On_Request = 4, // A call or an event asked it to stop, and it stopped cleanly.
}
```

`Done` is not 0. A zeroed word, or an argument that a caller forgot, must not claim a finished work.

### The operation word: `Process_Stop (process, outcome)`

The kernel reads the word `outcome` at one place, the dispatch of `Process_Stop`, with `op.stop_outcome_of_operation_word(word, itself)`, a pure procedure of the contract with host tests that takes the word and whether the target is the caller. Past it, the kernel passes the enum: `process_stop(index, cause, outcome)`. `process_stop` stops the machine with `Invariant_Broken` on a pair that the border cannot give: no cause, an outcome with a cause other than `Itself`, or `Itself` with no outcome.

- **The target is the caller.** The kernel compares the target with the caller; it does not trust the argument 0 alone. The cause is `Itself`. The word must name `Done`, `Failed`, `Refused` or `Stopped_On_Request`.
- **The target is another process.** The cause is `Holder`. The word must be 0.
- **A refusal** gives `Bad_Operation` with the error detail `Bad_Value` of argument 2, as `Machine_Stop` does for its code. The limit is the largest member for a stop of the caller, and 0 for a stop of another process. Nothing changes: the target runs on. The form of the argument in `op.OPERATIONS` stays `Value`: a `Choice` would refuse 0, which a holder must pass, so the form alone would refuse a word that the operation takes. The diagnosis reads the target again and gives the limit.
- `Bad_Handle` and `No_Right` stay as they are.

Each stop of the kernel itself passes its cause and `None`: the fault path, the refused return, the fault ring, the close of the last handle, the end of the last thread. A process that `Process_Create` made and that no handle names gets `Handles_Closed`; no reader sees it.

**The first stop keeps its facts.** A process that is stopped already keeps its cause and its outcome, as it keeps its stop report today. A holder's stop after the process stopped itself does not change `Itself`, and a fault after a stop changes nothing.

### The results of `Process_State`

`Process_State (process, report) -> state, cause, outcome, entries, slot, serial`. The two words replace the stop code at the second result, so the results after them move by one.

Each reader takes the three words through one pure procedure of the contract, `op.stop_of_words(state, cause, outcome) -> (Process_State, Stop_Cause, Stop_Outcome, ok)`. It refuses:

- a word that names no member;
- the state `Stopped` with the cause `None`;
- a state other than `Stopped` with a cause or an outcome other than `None`;
- the cause `Itself` with the outcome `None`;
- an outcome other than `None` with a cause other than `Itself`.

Each case is a fault of the kernel. `system.process_state` stops its process through `kernel_word_refused`, as it does today for a state word that names no state. The procedure has host tests for each refusal and is a fuzz target ([../infrastructure/fuzzing.md](../infrastructure/fuzzing.md)).

### `Stop_Report` and `Process_Report`

- **`Stop_Report.code` becomes `cause: u32`**, the word of a `Stop_Cause`, which a reader takes through `op.stop_cause_of_word`. The vector stays in `vector`: the old code repeated it (`0x100 + vector`). A report of a stop that is not a fault stays zero, so its cause word is 0. The reader takes the cause from `Process_State`, not from the report.
- **`Process_Report.code` becomes two words, `stop_cause: u32` and `stop_outcome: u32`.** The record grows by 4 bytes. A record of the kernel holds the words, not the enums, as `Module_Record.writer` does: a shared record holds the word in place of an enum field ([../infrastructure/choice_constants.md](../infrastructure/choice_constants.md)).
- The kept stop report of a disk process copies the report as it is ([../features/debug_object_of_a_disk_process.md](../features/debug_object_of_a_disk_process.md)).

### The library

- `system.stop(outcome: op.Stop_Outcome) -> !`, with no default. `system.stop(.Done)`. A refused stop still ends the process by the fault of [kernel_ring_completion_room.md](kernel_ring_completion_room.md), "The stop of a process": the cause is then `Fault`, never a false `Done`.
- `system.process_stop(process: Handle)` stops another process. It has no outcome parameter.
- `system.process_state(process) -> (state, cause, outcome)`.
- `system.process_place(process) -> (slot, serial, status)` gives the two other results of `Process_State` that a process needs, so that no process calls the operation raw.
- `system.process_stop_wait(process, deadline) -> (cause, outcome, stopped)` waits for the stop of a process up to its deadline. It replaces the helper that each demonstration has (`stop_cause_wait` in `frames`, `child_stop_cause` in `address_space`, `wait_for_stop` in `debugged`).
- `op.STOP_CAUSE_TEXTS` and `op.STOP_OUTCOME_TEXTS`, two whole arrays indexed by the enum, give the words of the readers: "itself", "a holder", "its last thread ended", "its last handle closed", "a fault", "a page that is not committed", "the kernel cannot return to its thread", "a fault that no thread can answer"; "done", "failed", "refused", "stopped on request". The compiler checks that each member has its text.

### The readers

- **The root service** writes one line at each reap: "root: settings stopped: itself, done". The level is `Info` for `Done`, `Stopped_On_Request` and `Holder`, and `Warning` for each other pair. The line is the log fact `root.Process_Stopped` with the fields `stopped_process`, `cause` and `outcome` for a stop of itself, and `root.Process_Stopped_Without_Outcome` with `stopped_process` and `cause` for each other cause, because a template has no condition and the line of a holder has no outcome ([../features/log_facts.md](../features/log_facts.md), "The facts of the root service"). `Stop_Cause` and `Stop_Outcome` are contract enums: a condition names a member (`outcome = Done`), and the sentence writes the words of a reader ("itself, done"). The rescue starts on any stop of the start policy before `Machine_Usable`, as today; the line gives the pair.
- **The start policy** writes the pair of a row that stopped. Its own enum of stop codes leaves: `List_Refused` becomes `Refused`; `Root_Ring_Refused`, `Parts_Page_Refused`, `Needed_Row_Not_Started` and `Usable_Refused` become `Failed`. Each already writes its line before the stop. `disk_start_policy` does the same. A row that stopped itself with `Done` or `Refused` does not start again: its work is finished, or the same input gives the same refusal (`start_list.stop_restarts`, [../features/start_policy.md](../features/start_policy.md), "The subtle points").
- **The console.** A call whose call host stops gives "error: the process calendar stopped: a fault, page fault", with the stack trace from the report for the three fault causes, and "...stopped: failed" or "...: refused" for a stop of the process. `stop_reason` becomes a whole switch on `Stop_Cause`, with the name of the vector for `Fault`. `monitor.processes()` has two Text columns, `cause` and `outcome`, from the two text arrays, as its column `state` does today.
- **The terminal** writes "-- console stopped: itself, done, after 12 lines --".
- **The tool and the machine tests.** A wait on "root: unlock stopped with code 0" becomes "root: unlock stopped: itself, done", then a wait for the fact. The tool reads the runner of the operation sequences through `op.stop_of_words`, with the state `Stopped`, from the two words `stop_cause` and `stop_outcome` of the mailbox. The reference of the kernel fuzzer ([../infrastructure/kernel_fuzzing.md](../infrastructure/kernel_fuzzing.md)) adds the two refusals of `Process_Stop`.
- **The end word of a record output.** The root service writes `Writer_Stopped` with the cause and the outcome of the writer ([../features/module_outputs.md](../features/module_outputs.md), "The end of a stream"). The reader of the end word takes them through `op.stop_of_words`, with the state `Stopped`.

### The error record of a failed stop (a later step)

`Failed` and `Refused` say that something went wrong. The reason is in the log today, which a parent reads only with the log scope and which loses records. The later step gives the stop the error record that an export gives ([export_error_records.md](export_error_records.md)):

- **The operation.** `Process_Stop (process, outcome, error)`. `error` is 0, or the address of an `errors.Error_Record` of 56 bytes in the caller. The kernel copies the seven integers into the record of the process. It interprets no field: the record is a claim of the process, and each reader checks its kind with `kind_known`.
- **The refusals.** `Failed` and `Refused` need a record whose kind is not 0. `Done` and `Stopped_On_Request` need the address 0: a clean stop has no error. A holder's stop needs 0. An address that the caller cannot read gives `Bad_Address`. Each refusal gives `Bad_Operation` or `Bad_Address`, and nothing changes.
- **The fields.** `operation` is 0. `argument` names the parameter of the export that the process ran for, from 1, or 0 for the work as a whole. A child of `debugged` gives the record of the operation that failed; the log fact names its step.
- **The place.** `Stop_Report.error`, zero for each other stop. The report grows by 56 bytes, and each process slot of the kernel by 56 bytes. The kept stop report of a disk process keeps it.
- **The library.** `system.stop(.Failed, &error)`. The parameter `error: ^errors.Error_Record = nil` keeps `system.stop(.Done)` short. The kernel refuses `Failed` with `nil`.
- **The readers.** The console writes the sentence of the record with `system.error_text`, as for an export that failed. The root fact gains the record. `Writer_Stopped` carries it in the place where an end record holds its error record, so a reader of a stream reads one form for both ends.

## The frequent tasks

| Task | Expression |
|---|---|
| A process ends its work | `system.stop(.Done)` |
| A process fails | `system.log(...)`, then `system.stop(.Failed)`; later `system.stop(.Failed, &error)` |
| A process refuses its arguments | `system.stop(.Refused)` |
| A process ends when its window is closed | `system.stop(.Stopped_On_Request)` |
| A starter stops a child | `system.process_stop(child)` |
| A parent learns why its child stopped | `state, cause, outcome := system.process_state(child)`, then a whole switch on `cause`; for `Fault`, `Not_Committed` and `Cannot_Return`, `system.process_stop_report(child)`; later, `report.error` for `Failed` and `Refused` |
| A test waits for a clean stop | `_, outcome, stopped := system.process_stop_wait(child, system.TEST_HANG_BOUND_MILLISECONDS)`, then `stopped && outcome == .Done` |
| A test waits for a fault | `cause, _, stopped := system.process_stop_wait(child, ...)`, then `cause == .Fault && system.process_stop_report(child).vector == u32(op.Fault_Kind.Page_Fault)` |
| A machine test waits for a clean stop | the step `{kind = .Fact, process = "root", fact = "root.Process_Stopped", condition = "stopped_process = \"unlock\""}`, which names the process, then the line "root: unlock stopped: itself, done"; in the console, `log.records({record}) \|> facts(root.Process_Stopped) \|> where(stopped_process = "unlock") \|> where(outcome = Done)` |
| The console shows the processes that failed | `where(monitor.processes(), outcome = "failed")` |

No expression names a number. The check `outcome == .Done` is enough, because the border refuses an outcome with a cause other than `Itself`.

## The migration

Each step is a commit on `master` that leaves a working system, with its tests.

1. **The kernel records the stop cause.** The enum, its border, its texts and host tests. The kernel keeps the cause beside the code, `Process_State` gives it, and `Stop_Report.cause` replaces `Stop_Report.code`. Each reader that tells the stops of the kernel apart reads the cause and the vector: the console, the root service, and the demonstrations `fault_ring`, `return_fault`, `frames`, `errors`, `address_space` and `kernel_events`. The constants `STOP_CODE_*` leave. The code of a stop of the kernel is 0. A holder's code stays recorded, but its cause `Holder` already tells it apart. The tests: a holder that passes 0 gives `Holder`, and each cause of the kernel comes from its demonstration.
2. **No result travels in a stop.** Each code that carries data or a number of a step becomes 0 or 1: the result bits of the children of `fault_ring` and `return_fault` go to the page that the parent shares with the child, as `fault_ring` and `debugged` already do for other values. The numbered steps of `debugged`, `fault_ring`, `kernel_events`, `errors`, `locks` and `locker` become 1 and a line that names the step; the line becomes a fact when log facts convert the module. The runner of the operation sequences writes its end in its mailbox. Each holder passes 0. The scenarios change their waits.
3. **The stop outcome.** The enum, the operation word and its refusals, the holder's word 0, `system.stop(outcome)` with no default, `system.process_stop`, `system.process_stop_wait`. A batch command changes `stop(0)` and `stop()` to `.Done` (30 calls) and `stop(1)` to `.Failed` (195 calls), and each holder's call of `Process_Stop` to `system.process_stop` (22 calls); the diff is read whole. The code leaves the kernel, `Process_State`, `Process_Report`, the root line, the terminal and the console. The glossary adds "stop code" to the words that the two terms replace, and the guides and the built intent files that name it change in the same commit.
4. **`Refused` and `Stopped_On_Request` where they belong.** A review reads each `Failed`: a refusal of the context, of the arguments or of an input becomes `Refused`; a stop that a close or a call asked for becomes `Stopped_On_Request`. The start policy maps its enum.
5. **The check of the tool.** The compiler already refuses `system.stop(1)`: an untyped integer does not convert to an enum. The tool refuses what the compiler lets pass: a conversion to `Stop_Cause` or `Stop_Outcome` outside the contract package `operation`, through an alias too; any mention of `Process_Stop` or `Process_State`, and any conversion of a word to `Operation`, outside `modus:system`, the contract, the kernel and the tool; and `system.stop(.None)`. The operation sequence runner names no operation in its source, so it needs no exception. The exception of [../infrastructure/choice_constants.md](../infrastructure/choice_constants.md) for the stop codes past 255 leaves.
6. **Later: the error record of a failed stop**, as above.

## The refused forms

- **An open number, as today.** Any holder forges "done", each reader decodes constants of another module, and a child sends data through it. A number that the kernel cannot check is a claim that nobody can trust.
- **One enum for the kernel causes and the outcomes.** A process or a holder then passes a member of the kernel range, and the kernel needs a list of refused members inside one enum. A process that failed and then faulted holds one of two facts only. Two authors give two fields.
- **An outcome from a holder.** It is the hole that this design closes. A holder knows why it stopped a process, and it writes that in its own log: "root: the compositor stops for the rescue".
- **The holder named in the stop.** Its process slot and serial would show a process that the reader did not start (property 20, row 1). The holder that needs the fact is the holder itself.
- **A stop text.** It is text between processes (property 19): the kernel would keep a text, and each reader would parse it. The later error record is seven integers that the kernel copies.
- **A number of a step beside the outcome.** It is the open number under another name. A step is a diagnostic: it goes in a log fact, and later the error record names the argument or the operation.
- **The result of a child in the stop.** A result is data. It goes through memory that the parent shares, an export or a record output. Through a log fact, it would take the lossy log as a data path ([../features/log_facts.md](../features/log_facts.md), "The forms refused").
- **`Done` as 0.** A zeroed word would claim a finished work.
- **`Itself` from the argument 0.** The kernel compares the target with the caller, so a handle that names the caller cannot make a stop of the caller look like a holder's stop.
- **A new operation for the stop of the caller.** One operation serves both stops: the comparison of the target decides the cause, and the counted interface stays as it is.
- **The vector in the cause (`Fault` plus the vector).** It repeats the stop report, and it makes the cause an open range again.
- **The error record now, with the outcome.** It needs a field of 56 bytes in each process slot and a change of each reader. The outcome alone closes the hole first; the record is a later step.
- **The error record in the log, or in a page shared with the starter.** The log loses records and is not a data path. A page reaches only the starter, each starter maps one, and the root service could not write the end word of a stream from it.

## The subtle points

- **`Handles_Closed` has almost no reader.** The cause exists when the last handle closed, so no holder remains to call `Process_State`. Only `Inspect`, the monitor, and an end word that the root service writes see it. The console that closes a call host does not read it.
- **The root service holds a handle to each process that it starts**, so `Handles_Closed` never ends a process that it started.
- **A refused `Process_Stop` of the caller returns.** `system.stop` then ends the process by the fault of the time page: the cause is `Fault`, and the outcome is lost. A false `Done` never comes from this path.
- **A fault that a handler answers with a stop is `Fault`**, whatever process answered: a debugger that answers stop does not become a holder.
- **The end of the last thread is not a clean end.** A module that finished its work calls `system.stop(.Done)`. A module whose threads all end by `Thread_Stop` has no outcome, and a test that waits for `Done` fails on it.
- **The stop outcome is a claim.** A process that says `Done` can lie about its work. The design closes the forge by another process, not the lie of a process about itself. A reader that needs proof of the work reads the result of the work.
- **The texts are the words of a row and of a line, not the contract.** A reader compares the enum, never the text.
- **`Stopped_On_Request` has no writer yet.** No process of the system stops itself because a close or a call asked it: the root service stops a process whose window closed as a holder, and so does a start policy. The member waits for the request to stop cleanly ("Open questions", "A request to stop cleanly").
- **What `Refused` covers.** A process stops with `Refused` when its starter gave it a context that it cannot run with: a word of the context that names no member (a role, a mode, a round), no random seed, a missing grant (no terminal, no service ring, no call ring, no ring to the root service, no grant of the network or to inspect the machine, no settings page or date page). A handle of the context that does not map is a missing grant only when it is 0 or the kernel answers `Bad_Handle` or `No_Right`; another status, as a budget that ran short, is `Failed`, which a start policy starts again. It also covers an input that it refuses (a start list, a sequence, a file of a principal that does not decode) and a request that the machine cannot take (`unlock` asked to seal a key with no TPM). A window that does not open, memory that a budget refuses, a device that does not answer and a check of a test that fails are `Failed`: the context was right, and the work did not happen.
- **A machine with no PS/2 controller.** The input service stops with `Failed` on a machine with no PS/2 controller, and its row can restart within its count. The absence is a fact of the machine, not of the context that the starter gave, and the root service writes it as a warning.

## The measures

No measure decides this design. The kernel stores 4 more bytes for each process slot, and `Process_Stop` reads one word, as it does today. The later error record adds 56 bytes for each process slot and one copy of 56 bytes at a failed stop.

## Open questions

The member `Last_Thread_Ended`, the names `Stop_Cause` and `Stop_Outcome`, the rule of the restart of a start policy after `Done` or `Refused`, and the word "stop code", which stays in `Machine_Stop` only (`MACHINE_STOP_CODE_MOST`) and is a word that the two terms of the glossary replace, are decided as recommended, and built.

1. **The error record: required or optional with `Failed` and `Refused`.** Recommendation: required, with a kind that is not 0. An optional record gives a parent a `Failed` with no reason, which is the fault of today.
2. **A request to stop cleanly.** The root service and a start policy stop a child as a holder. A command that asks a process to stop, then a holder's stop after a bound, gives `Stopped_On_Request` in place of `Holder`. Recommendation: not now; a planned entry when a service needs to save state at its stop.

## State

Built: the first five steps of the migration. The stop code is gone.

- **The kernel.** It records the cause and the outcome at each stop, and the first stop keeps both. `Process_Stop` gives `Itself` when the target is the caller, by 0 or by a handle that names it, and `Holder` otherwise; it refuses with `Bad_Operation` and the record `Bad_Value` of argument 2 a word that names no outcome other than `None` for the caller, and a word other than 0 for another process. `Process_State` gives `state, cause, outcome, entries, slot, serial`. `Stop_Report.cause`, `Process_Report.stop_cause` and `Process_Report.stop_outcome` hold the words. A path of the kernel that stops a process with no cause, or with a pair that the border cannot give, stops the machine with `Invariant_Broken` and the line "kernel: the kernel stopped the process slot N with no stop cause, or with a stop outcome that does not fit its cause". The report of `Inspect` for a free slot gives only its state `None` and its serial.
- **The contract.** `op.stop_of_words(state, cause, outcome)` is the border of the three words, `op.stop_outcome_of_operation_word` the border of the operation, `op.STOP_OUTCOME_TEXTS` the words of a reader; host tests give each refused word and each impossible triple first.
- **The library.** `system.stop(outcome)` with no default, `system.process_stop`, `system.process_state`, `system.process_stop_wait`, which replaced the wait of each demonstration, `system.process_place`, and `system.stop_write`, which writes "itself, done" or the text of another cause.
- **The readers.** The root line "root: settings stopped: itself, done" at the level `Info` for `Done`, `Stopped_On_Request` and a holder, `Warning` for each other stop; the start policy, which starts no row again after `Done` or `Refused`; the terminal; the console "the process calendar stopped: failed" or "...: a fault, page fault"; the columns `cause` and `outcome` of `monitor.processes()`; the mailbox of the operation sequences with its two words, format 3; and the demonstrations and machine tests, whose waits read "itself, done".
- **The outcomes.** The stops of the context, of an input and of a request that the machine cannot take give `Refused` (above, "What `Refused` covers"), each other failure `Failed`. The start policy and `disk_start_policy` have no codes of their own.
- **The tests.** `address_space` checks `Last_Thread_Ended` with no outcome, and that a process never holds Control over itself, so `Itself` through a handle is a guard of the kernel that no process reaches. `kernel_events` and `fault_ring` stop a stopped child again as a holder and read its first cause. `errors` reads the report of the freed slot of its child. `address_space` gives the kernel, in command records that skip the library, a holder's stop of a running child with `Done`, `Stopped_On_Request`, one past the last outcome, `1 << 32` (no low bit, which a border that reads 32 bits takes for 0) and the largest word, and a stop of itself with `None`, one past the last outcome, a word past 32 bits and the largest word: each gives `Bad_Operation` with `Bad_Value`, its word and its limit, and nothing stops. The tool checks the triple of the runner of the operation sequences, with each impossible group refused first.
- **The check of the tool.** `choice_constant_check` refuses a conversion to `Stop_Cause` or `Stop_Outcome` outside the contract package `operation`, through an alias, a `distinct` type or a `#type` too; each mention of `Process_Stop` or `Process_State` and each conversion of a word to `Operation` outside the support package `system`, the contract, the kernel and the tool, so that no variable, converted word or command record carries the operation; and `system.stop(.None)`. Two tests are named exceptions with their counts: the refusals of `Process_Stop` in `address_space`, and the kind of no operation in `errors` ([../infrastructure/choice_constants.md](../infrastructure/choice_constants.md), "The chosen form").
- **The outcome of a missing grant.** `system.stop_outcome_of_grant(handle, status)` gives `Refused` for a handle 0, `Bad_Handle` or `No_Right`, and `Failed` for each other status: a budget that ran short is no fault of the context, and a start policy starts the row again. `settings`, `date` and `host` stop through it.

Left: the error record (step 6); a writer of `Stopped_On_Request`; the end word of a record output; and the fuzz target of `op.stop_of_words`.
