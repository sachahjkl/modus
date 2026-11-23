# The outcome of a call

Decided: designed, not built. This file gives one form for the end of every call of the system: a direct call, an isolated call, a call of a service, a ring command, a kernel operation and a call from another machine. It replaces the sign of the integer result, and the eleven sets of statuses that say today how a call ended.

The prior art, the inventory of the system today and the measures are in [`docs/research/call_outcome_study.md`](../../../docs/research/call_outcome_study.md). The critique that shaped the effect groups, the rule of growth and the rule of weakening is [`docs/research/call_outcome_fable_critique.md`](../../../docs/research/call_outcome_fable_critique.md), with the independent study [`docs/research/call_outcome_fable.md`](../../../docs/research/call_outcome_fable.md). The rules that this form changes are in [`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "4. The call form" and "8. Errors that diagnose".

## The purpose

A caller must know three things after a call, in this order, with no description and no guess:

1. What the call did to the state: all its work, nothing, a part that the export states, or a change that nobody knows.
2. What the caller can do next: fix an argument, get a grant, create the thing, read again, wait, or give up.
3. Why, in the words of the call: which argument, which value, which limit.

Today the first two answers come from the sign of the integer result, which is also a value (`math.number("-5")` is -5), and from eleven sets of statuses (the section "2.2 Eleven sets that each say how a call ended" of [`docs/research/call_outcome_study.md`](../../../docs/research/call_outcome_study.md)). The storage service gives 13 distinct negative numbers that repeat the kind of its error record. The third answer, the error record, is right and stays.

## The constraints

- **One mechanism for one concept** (the first rule of the objective of [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md)). "How did this call end" is one concept.
- **A call to a service and a call to the kernel look the same** (property 6).
- **Zero is initialization** (property 13): the outcome 0 is success, and an error record of zero bytes is no error.
- **The caller gives the memory** (property 14): the error record is in memory of the caller or in the values of a completion.
- **No contract depends on one language** (property 19): C, Rust, Zig, Odin and assembly produce the form with no extension of the compiler.
- **Static and dynamic are the same module** (property 10): a direct call and an isolated call of one export give the same outcome for the same failure.
- **A closed set of choices is an enum, read at one border** that refuses a word that names no member ([../infrastructure/choice_constants.md](../infrastructure/choice_constants.md)).
- **The success path pays nothing** ([`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "8. Errors that diagnose", rule 1).
- **The kernel decides a refusal where the operation fails, and explains it later**, under other locks; the explanation can be partial. So the decision and the explanation are two facts.
- **The table of error details** holds one error record per row, each with its own kind. So the kind cannot leave the record.
- **The targets**: x86-64 now, AArch64 at best, and WebAssembly as a later code format (property 15, "Direction").

## The chosen form

### Three facts, two places

A call that ends gives three facts:

- **The call outcome**: one word, a member of one closed enum of the whole system, `call_outcome.Call_Outcome`. It says what the caller can do next. The code that fails decides it, at the moment of the failure.
- **The effect group** of the outcome: a total function of the member, `call_outcome.effect_group_of`, with four members that never change. It says what the call did to the state. No word carries it: the reader computes it from the outcome.
- **The error record**, on a failure only: the 56 bytes of today (`kind`, `unit`, `operation`, `argument`, `value`, `limit`, `found`). It says why. Its form does not change.

The outcome is not the kind of the record in a second place. One outcome has many kinds, and some kinds explain several outcomes: `Absent` explains `Nothing_Has_That_Name`, and with the unit `Region` it explains `Argument_Refused`; `Refused` explains each outcome.

The value of the call is a value only. Its sign means nothing.

### The effect groups

| Value | Effect group | What holds after the call | What generic code does |
|---|---|---|---|
| 0 | `Whole_Work_Done` | The call did all its work. Its value and its results are valid | Use them |
| 1 | `Nothing_Changed` | The call changed nothing that the caller can see: no byte of a result, no handle, no state of the callee | Act on the outcome; a test checks that nothing changed |
| 2 | `Partial_Change_Stated` | The call did a part of its work and stopped. The documentation of the export states what holds then, and the record says where it stopped | Read what the documentation states; never call again blindly |
| 3 | `Change_In_Doubt` | The call ran in whole, in part or not at all, and nobody can tell the caller which | Read the state, or rely on an idempotent export or a request serial |

The four effect groups never change: no member is added to this enum, and no outcome moves to another group. A relay, a test, a replay and a library that calls again switch on the effect group, never on the outcomes. A call in doubt is a call whose outcome is in the group `Change_In_Doubt`.

### The members

The values are the contract and never move. A callee runs the tests in their order, and gives the first member whose test holds. The borders give the members of the group `Change_In_Doubt`, in their own order (below, "The failures of the path").

| Value | Member | Effect group | The test, in order | What the caller does | Main kinds of the record |
|---|---|---|---|---|---|
| 0 | `Succeeded` | `Whole_Work_Done` | The call did all its work | Use the value and the results | none |
| 12 | `Stopped_After_A_Partial_Change` | `Partial_Change_Stated` | 1. The callee changed state that the caller can see, then stopped its work. This test comes first: a change that happened is never hidden behind a refusal | Read what the documentation of the export states | the kind of the cause, with the record of its own callee as a detail |
| 9 | `Operation_Unsupported` | `Nothing_Changed` | 2. The receiver does not have this export, command or operation | Use another receiver, or another build | `Unsupported`, `Unknown_Operation` |
| 1 | `Argument_Refused` | `Nothing_Changed` | 3. An argument breaks a rule that the call states for it: its form, its size, its range, its encoding, its alignment, the kind of object of a handle, a handle that names no object of the caller, an address outside the memory of the caller | Fix the argument | `Bad_Value`, `Too_Long`, `Too_Small`, `Bad_Address`, `Handle_Ended`, `Handle_Kind`, `Malformed`, `Not_Authentic`, `Overlap` |
| 4 | `Grant_Or_Right_Missing` | `Nothing_Changed` | 4. The grant of the caller, or a right of its handle, does not allow the call. This test comes before the names, so a caller with no grant learns nothing of a name | Get a grant or a handle with the right; another call does not help | `No_Grant`, `Handle_Rights`, `Reserved`, `Starter_Module` |
| 2 | `Nothing_Has_That_Name` | `Nothing_Changed` | 5. A name or a number of the call names nothing that exists | Create the thing, or name another one | `Absent` |
| 3 | `Name_Already_Taken` | `Nothing_Changed` | 6. The call makes a thing, and its name names a thing that exists | Use the thing, or another name | `Exists` |
| 8 | `Another_Change_Came_First` | `Nothing_Changed` | 7. Another change of the object came after the state that the caller read, and the call depended on that state | Read again, and do the sequence of calls again | `Absent` of the unit `Pending` with `found` 1, and the kinds of a later race |
| 7 | `Wrong_State` | `Nothing_Changed` | 8. The object that the call names is in a state where the call does not apply | Change the state first, or wait for a change that the caller knows of | `State`, `Object_Shared`, `Object_Marked`, `No_Target`, `Seed_Too_Weak` |
| 5 | `Callee_Busy` | `Nothing_Changed` | 9. A capacity that the callee shares with other callers is full now, and it frees with no act of this caller: requests in flight, a ring, a frame of memory | Call again later | `Busy`, `Full` of a shared table |
| 6 | `Budget_Or_Capacity_Exhausted` | `Nothing_Changed` | 10. A budget, a limit or a capacity cannot pay for the call, and it frees only when something is ended or a larger grant is given | Free something, or ask for more | `Budget`, `Budget_Hidden`, `Over_Limit`, `Full` of a table of the caller |
| 10 | `Data_Damaged` | `Nothing_Changed` | 11. Data that the callee holds failed its check | Take an earlier version; another call fails again | `Damaged` |
| 11 | `Callee_Unavailable` | `Nothing_Changed` | 12. The call did not run, because a party that it needs failed or did not answer: the callee was not there, a device, a link, a peer | Call again later | `Device`, `Link_Down`, `No_Answer`, `Callee_Stopped` |
| 13 | `Callee_Stopped_During_The_Call` | `Change_In_Doubt` | The process that ran the call stopped after it read the command and before it answered | Treat the call as in doubt | `Callee_Stopped` |
| 14 | `Connection_Ended_During_The_Call` | `Change_In_Doubt` | The connection or the link ended after the command left and before the answer came | Treat the call as in doubt | `Connection_Ended` |
| 15 | `Deadline_Passed_During_The_Call` | `Change_In_Doubt` | The deadline of the caller, or the hang bound, passed after the command left and before the answer came. The callee can still run the call | Treat the call as in doubt | `No_Answer` |
| 16 | `Answer_Unreadable` | `Change_In_Doubt` | An answer came, and the reader cannot read it by the contract that it knows: a word that names no outcome, a count that went down, a table outside the call region, a reply to another call | Trust nothing of the answer; treat the call as in doubt | `Bad_Value` of the word, `Too_Small`, `Out_Of_Range` |

- **`Argument_Refused` is not "fails again in each state".** An address is valid after a map, and a handle number names an object after a gift. Its test names the rules of the argument, and the record names the argument.
- **`Callee_Busy` against `Budget_Or_Capacity_Exhausted`**: the first frees by itself, the second needs an act. A full table of the machine that every process shares (the memory objects, the frames of memory) is `Callee_Busy`; the handle table of the caller, its budget and the limit of its store are `Budget_Or_Capacity_Exhausted`.
- **`Another_Change_Came_First` against `Wrong_State`**: after the first, reading again and doing the same sequence again can pass; after the second, the caller changes the state first.
- **`Callee_Unavailable` against the group `Change_In_Doubt`**: one fact tells them apart, whether the command left or was read. The library reads it from the counters of the queue, never from a guess. A device that failed during a write ran a part of it: the callee gives `Stopped_After_A_Partial_Change` when its contract states what holds (the block service: each block of the request holds its old bytes or its new bytes), else the group `Change_In_Doubt`.

Two error kinds are new: `Callee_Stopped` (`value`: the stop cause word; `found`: the stop outcome word, or 0) and `Connection_Ended` (`found`: the connection state word).

The set has no member for an internal error and no member for "unknown". A callee that finds its own state broken stops (below, "A bug is not an outcome"). A word that a reader does not know has its own rule (below, "A word that names no outcome").

### The rule of weakening

No border, relay or export gives an effect group that promises more than what it received or caused. The groups promise, from the most to the least: `Whole_Work_Done` and `Nothing_Changed` (the state is known), `Partial_Change_Stated` (the documentation states it), `Change_In_Doubt` (nothing is known).

- **An export that changed something, then met a refusal of its own callee**, gives `Stopped_After_A_Partial_Change`, never the refusal that it received. The record of its callee goes in its table of error details.
- **An export that passes on an outcome of its own callee** passes it as it came only when the export changed nothing itself. A callee that answered with the group `Change_In_Doubt` makes the call of the export in doubt too.
- **A relay** (a receiver, `remote`, the agent bridge, a proxy between machines) gives its client one outcome. A relay that cannot read the answer gives `Answer_Unreadable`; a chain of two relays never adds a word.
- **A reader of another process keeps the record as it came.** It never rewrites a record that it judges wrong: an older reader with an older table would erase a correct record of a newer callee. The kernel keeps its own rule ("a kind that does not explain the status becomes `Refused`") for the records that it writes, because one build writes and checks both.

### The rule of growth

The members are a closed set with a version; the effect groups never change.

- **A new member joins the group `Nothing_Changed` only.** The groups `Whole_Work_Done`, `Partial_Change_Stated` and `Change_In_Doubt` keep their members for ever.
- **A new member names the member that it refines**: its parent, in the table `call_outcome.PARENT_OF`, which the compiler checks whole. A member of today is its own parent.
- **A new member comes with a new version of the contract.** A border that knows that its reader is older gives the parent. A relay between two paired machines knows the generation of its peer.
- **Until the kernel step, the set can change** (below, "The order of the work"): two services run on it first, and a member that their use shows wrong changes then. After the kernel step, only the rule of growth changes the set.

### A word that names no outcome

A reader takes the outcome word through one border, `call_outcome.outcome_of_word`. For a word that names no member, the border gives `Answer_Unreadable` and the record `Bad_Value` with the word as `value` and the last member that the reader knows as `limit`. It never gives a member that the word does not name, as `system.status_of_word` does for a status today. The sentence says that the answer names an outcome that this reader does not know; it does not say that the callee broke its contract.

- **Which readers have the border**: each library that reads a completion or an answer from another process (`system.call_isolated`, the client of a service, the remote tool, the agent bridge, the console). A direct call has no border: the loader binds the import by hash, and the check of a replacement refuses a module whose `Call_Outcome` has other members than the one of the module that it replaces. A module that can fail carries the description of `Call_Outcome` as it carries an enum of a parameter.
- **A newer callee and an older caller.** With the rule of growth, a border that knows the older reader gives the parent, so the reader keeps the promise "nothing changed". A word that still reaches a reader that does not know it is `Answer_Unreadable`: the reader cannot tell a newer callee from a broken one, so it promises nothing.
- **A kind or a unit that names no member** stays the rule of today: the sentence says the number and that it names nothing (`errors.kind_of_word`). The decisions of the caller depend on the outcome, so an unknown kind changes no decision.

### Where the outcome is

| Call | The outcome | The value | The error record |
|---|---|---|---|
| Direct call, x86-64 | `rax` | `rdx` (integer), `xmm0` (float) | at the address of the last argument |
| Direct call, AArch64 | `x0` | `x1` | at the address of the last argument |
| Direct call, RISC-V (no target today) | `a0` | `a1` | at the address of the last argument |
| Direct call, WebAssembly (a later code format) | the first result of a function of type `(...) -> (i64, i64)` | the second result | at the address of the last argument |
| Kernel operation, ring command, isolated call, call of a service | `kind` of the completion | `values[0]` of the completion | the seven `values` of the completion |
| Call from another machine (`remote`) | `Answer.outcome`, and `Answer.relay_outcome` for the request | `Answer.value` | `Answer.error` |

- **The direct call** of an export that can fail returns two words: the outcome first, the value second. In C it is one struct returned by value, `struct modus_answer { uint64_t outcome; int64_t value; }`, which every compiler returns in `rax` and `rdx` on System V and in `x0` and `x1` on AArch64. It is the one aggregate by value of the call form. The rule "no record by value" refused the edge cases of the conventions; a struct of two words of 8 bytes is not one of them. In Odin it is `-> (outcome: Call_Outcome, value: i64)`, which the compiler of the flake returns in the same registers. chibicc returns a struct of 16 bytes in `rax` and `rdx` too.
- **The outcome first** puts the outcome in the first integer register of the result for each type of value, on each machine. With a float value, System V gives the float in `xmm0` and the outcome in `rax`, and AAPCS64 gives the outcome in `x0` and the bits of the float in `x1` (measured in the section "5. Measures of this note" of [`docs/research/call_outcome_study.md`](../../../docs/research/call_outcome_study.md)). An export that can fail and has no value (a Record result, or no result) returns the outcome alone, in the same register.
- **Odin inside a module.** `or_return` reads the last result, so the procedures of a package that are not exports keep the order `(value, outcome)`, and the client library of a service gives that order to an Odin caller. Only the export and the import slot have the order of the call form: the export swaps the two words at its `return`.
- **`Call_Outcome` is `enum u64`** in the call form: `rax` holds the whole word, so no reader masks bits. The completion of a ring has a `kind` of 32 bits; each member has a value below 2^32, and the border reads the word in 64 bits as `enum_word.member_of_word` does.
- **WebAssembly.** The system gives each export and import of a WebAssembly module the type `(i64, i64)` for the pair. The C ABI of LLVM for WebAssembly returns a struct through memory (measured for `freestanding_wasm64p32`), so the engine module of the system adapts that one form at the border of the instance. The browser machine of today runs the x86-64 code of the modules in a software processor ([../features/browser_machine.md](../features/browser_machine.md)), so it reads `rax` and `rdx` as the hardware does.
- **One completion form.** A failed completion holds the outcome in its `kind` and the error record in its `values`, for the kernel, each ring and each isolated call. In an isolated call the receiver gives the export a private error record, and copies it into the completion on a failure: the argument record has no place for the error record, and the caller reads no record from the call region. The table of error details stays in the call region.
- **Two outcome words in the answer of `remote`.** `relay_outcome` is the outcome of the request to `remote`; `outcome` is the outcome of the export. The one error record belongs to the first that is not `Succeeded`: its `argument` names a field of the request for the relay, and a parameter of the export for the export. The header keeps 112 bytes: the two words take the places of `status` and `call_status`. The two words stay inside the header of `remote`; its client gets one outcome, by the rule of weakening.

### An export that cannot fail

An export that cannot fail returns its value alone: `-> i64` in Odin, `int64_t` in C. An export that can fail returns the pair, and takes the error record as its last parameter. The signature is the promise, and the compiler checks it: an export with one result has no way to give an outcome. The description keeps the field that says it today, `Function.error_record`: an export with an error record returns the pair.

So a direct call of an export that cannot fail has no outcome to read. An isolated call of it can still end with `Callee_Unavailable`, `Operation_Unsupported`, `Argument_Refused` (the receiver refused the call record), or a member of the group `Change_In_Doubt`: those come from the path, not from the export.

An export with a Record result can now fail: it returns the outcome alone. The compositor can give `pointer()` as a Record.

### The value of a call that did not succeed

- **A border writes 0.** A receiver, a relay and the library give the value 0 with each outcome but `Succeeded`, so the caller gets the same bytes at each run, and no word of a callee passes by accident.
- **The 0 is not a protection.** 0 is an answer of many exports: `math.next_prime` gave 0 as a failure, which a caller can take as a prime ([export_error_records.md](export_error_records.md)). A caller of a direct call reads the value only after it read `Succeeded`.
- **The compiler forces the read of the outcome.** The binding of an export that can fail is `@(require_results)` in Odin, `__attribute__((warn_unused_result))` in C and `#[must_use]` in Rust, and the build treats the warning as an error. No check of the tool reads the literal form of a `return`.

### A bug is not an outcome

- **A bug of the callee** stops the process that has it. An Odin bounds check, a contract check of the callee and a fault end that process at once, and run no more of its code. In an isolated call or a call of a service, the caller gets `Callee_Stopped_During_The_Call`; the supervision design starts the holder again and replays what it can ([../features/supervision.md](../features/supervision.md)). In a direct call the callee is in the process of the caller, so the process of the caller stops: this is the trust that a direct call takes.
- **A bad call of the caller** (an argument record outside the call region, a handle that did not come through the call ring, an enum word that names no member, a count past its bound) is `Argument_Refused` with its record. It is never a fault of the caller. A callee has no authority over its caller (property 2), the kernel is not on the path of a call (properties 5 and 6), and the caller can be a principal at the console or an agent, for whom a wrong value is not a bug. A compiled caller that treats `Argument_Refused` as its own bug stops itself: it is a choice of the caller, never of the callee.
- **Who refused, in an isolated call.** The receiver and the export both give `Argument_Refused`, because the caller does the same thing next. The record tells them apart with no guess: a refusal of the receiver has the unit `Region` (a place outside the call region) or `Lent_Handles` (a handle that did not come through the call ring), and an export never writes these units.

### The failures of the path

The failures of the path use the same word. A border runs these tests in order:

1. The process that ran the call stopped. If it had read the command: `Callee_Stopped_During_The_Call`. If not: `Callee_Unavailable` with the kind `Callee_Stopped`.
2. The connection or the link ended. If the command had left: `Connection_Ended_During_The_Call`. If not: `Callee_Unavailable`.
3. The deadline passed after the command left: `Deadline_Passed_During_The_Call`. The supervision design keeps such a call in doubt for its replay.
4. An answer came that the reader cannot read: `Answer_Unreadable`.
5. The library refused before it sent: the arguments do not fit in the call region (`Argument_Refused`, `Too_Long` of the table), the call ring is full (`Callee_Busy`), a lend failed (the outcome of the kernel). Nothing left, so nothing changed.

So the caller tells "the callee refused" (the group `Nothing_Changed`), "the callee stopped" (`Callee_Stopped_During_The_Call`, with the stop cause and the stop outcome in the record) and "the answer is unreadable" (`Answer_Unreadable`) with one comparison.

### Results past one value

- The value is one word. A second word of result is a Record result, which can now fail.
- A Text or a Table that did not fit is a success: the value is the count of the full answer, larger than the capacity. It is an answer that the caller needs (the capacity to give), not a refusal. A caller that reads only the outcome misses it; the rule of today stays: the caller reads `min(count, capacity)`.
- An Append table and the table of error details keep their rules. A table in a lent memory object keeps what the callee wrote before it failed: such an export gives `Stopped_After_A_Partial_Change` when it wrote there, and states what holds.
- A batch whose rows succeed and fail one by one is a success, with one status for each row. A work that is not a batch and stops half way is `Stopped_After_A_Partial_Change`: never a success that hides a failure in its value.
- The end record of a stream carries an outcome and the count of the records that are sound.
- A float result (not in the description today) of an export that can fail is the value of the pair: in `xmm0` on x86-64 and in `x1` on AArch64, with the outcome first on both machines.
- A handle reaches the caller only with `Succeeded`.

### The sentence and the agent

A sentence comes from the outcome, the record and the names of the description (`modus:sentence`): "storage.read: Nothing_Has_That_Name: the argument name, "notes", names no object". An agent reads the same facts as typed values: the outcome and its effect group by the names of their members, the record by its described fields, and the kinds and units by the names of their members. The description says whether an export can fail, so `help()` and `describe` show it.

### The cost

- **Direct call, success**: the callee sets `rax` to 0 (one `xor`) and puts its value in `rdx`, and the caller tests `rax` (one test and one branch). Today the caller tests the sign of `rax` with one test and one branch. No byte of memory more.
- **Direct call, failure**: the same writes of the record as today.
- **The effect group**: one load from a table of 17 bytes, only on a failure, in generic code.
- **Completions**: the word is the `kind` that each completion writes today. An isolated call that fails copies the record into the completion, and the caller no longer reads 56 bytes of the call region.
- **`remote`**: the header keeps its size.
- **WebAssembly**: when the compiler gives the pair through memory, two stores and two loads of the instance per call.

## The vocabularies of today

Each set of today becomes `Call_Outcome` in its migration step. Where one word of today becomes two members, the record or the place of the failure decides.

| Set of today | Word | Member |
|---|---|---|
| `op.Status` | `Ok` | `Succeeded` |
| | `Bad_Operation` | `Argument_Refused`; `Operation_Unsupported` with `Unknown_Operation` |
| | `Bad_Handle`, `Bad_Address` | `Argument_Refused` |
| | `No_Memory` | `Callee_Busy` |
| | `No_Slot` | `Budget_Or_Capacity_Exhausted` for a table of the caller; `Callee_Busy` for a table of the machine |
| | `Bad_State` | `Wrong_State` |
| | `No_Right` | `Grant_Or_Right_Missing` |
| | `No_Budget` | `Budget_Or_Capacity_Exhausted` |
| `isolated.Status` | `Ok` | `Succeeded` |
| | `Bad_Export` | `Operation_Unsupported` |
| | `Bad_Arguments`, `Bad_Handle` | `Argument_Refused` |
| | `Load_Failed` | `Argument_Refused` with `Malformed`; `Nothing_Has_That_Name` for an import that is not in the load source |
| `call_status.Call_Status` | `Ok` | `Succeeded` |
| | `Lend_Failed` | the outcome of the kernel refusal |
| | `No_Room` | `Argument_Refused` |
| | `Ring_Full` | `Callee_Busy` |
| | `Stopped` | `Callee_Stopped_During_The_Call`; `Callee_Unavailable` when the command was not read |
| | `Refused` | the outcome of the receiver |
| | `Wrong_Answer`, `Failed_With_Wrong_Details` | `Answer_Unreadable` |
| | `Failed` | the outcome of the export |
| | `Not_Done` | `Operation_Unsupported` |
| `remote.Status` | `Ok` | `relay_outcome` `Succeeded` |
| | `Refused` | `relay_outcome`: `Argument_Refused` for a field of the request or another hash, `Nothing_Has_That_Name` for a service with no connection |
| The ends of a request between machines ([../features/several_machines.md](../features/several_machines.md)) | `Answered` | the outcome of the answer |
| | `Refused` | `Grant_Or_Right_Missing` for `Not_Paired` and `Use_Not_Granted`, `Nothing_Has_That_Name` for `Object_Absent`, the outcome of the role for `Role_Refused` |
| | `Unknown_Outcome` | `Connection_Ended_During_The_Call`, `Deadline_Passed_During_The_Call` or `Answer_Unreadable`, by its cause |
| | `Unreachable` | `Callee_Unavailable` |
| `block.Status`, `frame.Status`, `datagram.Status`, `entropy_service.Status` | `Ok` | `Succeeded` |
| | `Bad_Command` | `Argument_Refused`; `Operation_Unsupported` with `Unsupported` |
| | `Out_Of_Range`, `No_Region`, `Too_Large` | `Argument_Refused` |
| | `Unsupported` | `Operation_Unsupported` |
| | `Device_Error` | `Callee_Unavailable` for a read; `Stopped_After_A_Partial_Change` for a write |
| | `Too_Many`, `Busy` | `Callee_Busy` |
| | `Not_Granted` | `Grant_Or_Right_Missing` |
| | `No_Answer`, `Link_Down` | `Callee_Unavailable` |
| | `Amplification` | `Budget_Or_Capacity_Exhausted` |
| `storage.Export_Error` | -1 `No_Store` | `Grant_Or_Right_Missing` |
| | -2 `No_Budget` | `Budget_Or_Capacity_Exhausted` |
| | -3 `Name` | `Argument_Refused` |
| | -4 `Too_Large` | `Argument_Refused` |
| | -5 `Full` | `Budget_Or_Capacity_Exhausted` |
| | -6 `Disk` | `Callee_Unavailable`: a commit is whole or absent |
| | -7 `Absent` | `Nothing_Has_That_Name` |
| | -8 `Damaged` | `Data_Damaged` |
| | -9 `No_Version` | `Nothing_Has_That_Name` |
| | -10 `Acts_For_Principal` | `Grant_Or_Right_Missing` |
| | -11 `Exists` | `Name_Already_Taken` |
| | -12 `Place` | `Argument_Refused` for a place of another connection; `Grant_Or_Right_Missing` for a connection that reads only |
| | -13 `Pending` | `Nothing_Has_That_Name` for no pending change; `Another_Change_Came_First` when another change came first |
| The calls of supervision ([../features/supervision.md](../features/supervision.md)) | the library status `Holder_Stopped` | `Callee_Stopped_During_The_Call` for a call in doubt; `Callee_Unavailable` for a call that did not leave |
| | the library status `No_Answer` | `Deadline_Passed_During_The_Call` |
| | the library status `Ended` | `Connection_Ended_During_The_Call`; `Callee_Unavailable` for a call that did not leave |
| `agent_bridge.Bridge_Status` | `Ok`, `Refused`, `Transport_Error` | the outcome of the call. "Waits for the approval of the principal" stays a state of the request of the bridge, not an outcome |

## The frequent tasks

| Task | Expression |
|---|---|
| Test a call | `size, outcome := storage.size(name, &error)` then `if outcome != .Succeeded` |
| Give the failure to my own caller, when this code changed nothing | `size := storage.size(name, &error) or_return` (the client library gives the order `(value, outcome)`) |
| Write an export that can fail | `size :: proc "c" (name: ^Text, error: ^errors.Error_Record) -> (outcome: Call_Outcome, value: i64)` |
| Create a thing that is absent | `if outcome == .Nothing_Has_That_Name { ... }` |
| Do the sequence again after a race | `if outcome == .Another_Change_Came_First { ... }` |
| Call again later | `if outcome == .Callee_Busy || outcome == .Callee_Unavailable { ... }` |
| Act on the effect in generic code | `switch call_outcome.effect_group_of(outcome)` |
| Treat a call as one that ran or did not | `if call_outcome.effect_group_of(outcome) == .Change_In_Doubt { ... }` |
| Show why a call failed | `sentence.call_failure(outcome, error, function)`: one sentence |
| Test a refusal | `outcome == .Argument_Refused && error.kind == i64(errors.Kind.Too_Long)`, then check that nothing changed |
| Know if an export can fail | its signature, or `describe(storage.size)` |

No task reads the sign of a value, a range of numbers, or the description to know if a call failed.

## The alternatives

### The kind as the outcome word

The outcome word is `errors.Kind` (40 members today), in a register and in the `kind` of each completion; the error record keeps the details only.

- **For**: one enum; the sentence and the decision read the same word; no table from kinds to outcomes.
- **Against**: a record of a table of error details and a stored record (a completion, a log fact) are read alone, so each needs its kind: the kind is then in the register and in the record, the same fact in two places. The kernel decides a refusal before it can explain it, and its explanation can be `Refused`: with the kind as the decision, the caller loses the class when the explanation is partial. Each caller maps 40 kinds, and more each year, to an action.
- **Not chosen**: it puts the vocabulary that grows on the path of the decision.

### A typed reason for each export

Each export declares its own enum of reasons in its description (as FIDL `error`, a WIT `result<T, E>`, a Zig error set), and gives it in the register of the outcome; the system adds the members of the path.

- **For**: precise and typed for an agent; the replacement check compares the sets; an inferred set (Zig) keeps the list exact.
- **Against**: each export invents a vocabulary, which is the problem of today with eleven sets. A generic caller (the console, `remote`, the bridge, a library that calls again) cannot act on a reason that it does not know. Swift and Midori report that a typed reason constrains the change of a function and that most errors are passed on or shown, not handled one by one. The reasons of the storage service are already kinds and units of the record.
- **Not chosen**: the description says "can fail", and the reason is data of the whole system.

### The effect alone in the word

The word carries the four effect groups only, and the action comes from the kind of the record.

- **For**: a set that never changes; generic code needs nothing else.
- **Against**: the kernel decides the class before it can explain it, and a record that degrades to `Refused` then loses "a budget is short" against "an argument is wrong". The frequent tasks read the record to compare one class.
- **Not chosen**: the word carries the action, and the effect is a total function of it.

### The outcome in memory only

The value is in `rax`, and the call failed when the `kind` of the error record is not 0.

- **For**: one place for every fact; no second register.
- **Against**: each call writes 8 bytes and reads them back, on the path of success, against rule 1 of "8. Errors that diagnose". A completion still needs its `kind` word, so the kernel and the rings keep a second form.
- **Not chosen**: it costs memory on every call and keeps two forms.

## The refused forms

- **The sign of the value.** A negative value is also an answer, so the sign tells nothing alone, and the check of the tool must guess from the syntax. HRESULT and Zircon show its cost; Fuchsia is moving away from it.
- **Distinct negative values for distinct failures** (`storage.Export_Error`). The same fact as the kind of the record, in a second vocabulary.
- **A sentinel and a value per thread** (`errno`, `GetLastError`). A value outside the call.
- **Exceptions and unwinding.** They depend on a language and a runtime, and a border between two languages cannot unwind (property 19).
- **A register of its own for the error** (`r12` as Swift does) **or a flag of the processor** (the carry, as P0709 proposes). No C compiler can produce either.
- **One set of statuses for each ring, each service and each layer.** The eleven sets of today.
- **A member for an internal error, or for "unknown".** An internal error keeps a broken process running; "unknown" turns a word that a reader does not know into a member.
- **A refusal after a change.** A refusal promises that nothing changed. An export that changed something gives `Stopped_After_A_Partial_Change`.
- **A fault of the caller for a bad call** (the reply fault of Hubris). It gives the callee authority over its caller, needs the kernel on the path of a call, and stops a principal or an agent for a typing mistake.
- **A layer and an outcome packed in one word**, or a range of values reserved for each owner (the facilities of HRESULT, the dead codes of Hubris, the positive codes of Zircon). An encoding that a reader must decode (property 22).
- **A member of the path that an export cannot give** (`Not_Delivered` of the independent study). The relay gives its own outcome word in the header of `remote`, and the rule of weakening covers the rest.
- **A reader that rewrites a record of another process** to `Refused`. An older table erases a correct record of a newer callee.
- **The value 0 as a protection of a caller that forgets the outcome**, and a check of the literal form of a `return`. The compiler forces the read of the outcome.
- **A flag "total" beside the signature.** The signature already says it, and the compiler checks it.
- **The value first and the outcome second**, the form of Go and of the multiple results of Odin. On x86-64 a float value then moves the outcome from `rdx` to `rax` (measured), so a reader needs the type of the value to find the outcome.
- **Short names of members** (`Invalid`, `Absent`, `In_Doubt`). A reader of a log line or of a test reads the member with no document; each name is a whole phrase.
- **A text in the outcome.** Property 19.
- **A partial error at the level of the call.** A batch gives a status per row with `Succeeded` (AIP-193 refuses partial errors for the same reason).

## The check against each property

- **Objective, rule 1**: one outcome set in place of eleven. Kept.
- **Property 2**: a callee cannot stop its caller; a record names no other process. `Callee_Stopped` names the stop cause and the stop outcome of the callee, which the caller reads already through the handle of its call host or the connection page. Kept.
- **Property 4**: the outcome is the `kind` of a completion of the rings. Kept.
- **Property 6**: a call to the kernel and a call to a service end with the same word, after the kernel step. Kept and strengthened.
- **Property 10**: the same failure gives the same outcome in a direct call, a call host and a service; the isolated ways add the outcomes of the path only. Kept; the test of the three ways compares the outcomes too.
- **Property 12**: the description says whether an export can fail, with the field of today. Kept.
- **Property 13**: `Succeeded` and `Whole_Work_Done` are 0; a record of zero bytes is no error. A completion of zero bytes reads as a success with the value 0: the tag of the completion, which the library checks, is what proves that it answers the command. Kept.
- **Property 14**: the record is in memory of the caller or in the completion. Its text names the status `No_Budget`; at the kernel step it becomes "the outcome `Budget_Or_Capacity_Exhausted` with the error kind `Budget`". This is a change of the words of the property, not of its rule, made in the property first.
- **Property 19**: two words of result, reachable from C, Rust, Zig, Odin and assembly; no exception, no text. The table "The choice" of "4. The call form" changes: the results row says the outcome and the value, and the one struct of an outcome and a value is allowed by value. Kept.
- **Property 20**: the test of the grant comes before the test of the names, so a caller with no grant learns nothing of a name. Kept.
- **Property 22**: each frequent task is one expression (above). Kept.
- **Property 23**: a conformance suite of a role checks outcomes and their effect groups, and the replacement check compares `Call_Outcome`. Kept.
- **Property 24**: the outcome of a kernel entry is in its completion, which is recorded; a direct call is code of the process. Kept.
- **Property 25**: it takes the small set of classes of gRPC with its ordered tests, the response code in a register of Hubris, the separate member of the path of FIDL and the abandonment of Midori, and leaves the sign of HRESULT, the per-thread value of `errno` and exceptions. Kept.

No property changes its rule. Property 14 changes one name in its text, at the kernel step.

## The subtle points

- **The kernel decides, then explains.** The operation that fails sets the outcome at once; `diagnose` writes the record later. A record of the kernel that does not explain the outcome becomes `Refused`, as today, because one build writes and checks both. The kernel loses one fact of today: `Refused` held the old status in `found`, and the outcome now holds the class.
- **A deadline makes a call in doubt, not a refusal.** The callee can still run the call after the caller stopped to wait.
- **A handle in a result of a call in doubt.** The handle can have arrived when the completion did not. The path needs a rule that finds and ends it; it is open below.
- **An outcome and a kind with related names** (`Nothing_Has_That_Name` and `Absent`, `Name_Already_Taken` and `Exists`, `Data_Damaged` and `Damaged`, `Operation_Unsupported` and `Unsupported`): the kind is the plain explanation of the outcome, with its unit.
- **`or_return` is sound only before a change.** A code that changed state and then meets a refusal gives `Stopped_After_A_Partial_Change` (the rule of weakening); the frequent task says it.
- **The records of a log fact or a record output** that hold an outcome hold the word, and their reader takes it through the border.
- **The agent bridge** keeps "waits for the approval of the principal" as a state of its request: it is not an outcome of a call. Its words have `Ok = 1` today, against property 13; the migration ends them.

## The order of the work

Each step is an entry of [`ROADMAP.md`](../../../ROADMAP.md), in this order:

1. **The exports.** The contract package `call_outcome` (the enum, the effect groups, `PARENT_OF`, the border and its host tests); the two kinds; each export with an error record returns the pair; `storage.Export_Error` ends; the bindings force the read of the outcome; `export_error_record_check` ends, because an export with an error record and one result does not compile into a description; the guides "4. The call form" and "8. Errors that diagnose"; the assembler, chibicc and the manifest of other languages ([../infrastructure/language_neutral_abi.md](../infrastructure/language_neutral_abi.md)); the console and `modus:sentence`.
2. **The isolated call and `remote`.** `isolated.Status` and `call_status.Call_Status` end; the record travels in the completion; the answer of `remote` has its two outcome words; the ends of a request between machines, the agent bridge and the calls of supervision give `Call_Outcome`.
3. **The rings.** `block.Status`, `frame.Status`, `datagram.Status`, `entropy_service.Status` and the statuses of the root ring and the TPM service end; each service writes the outcome and the record.
4. **The kernel**, last, after two services ran on the set: `op.Status` becomes `Call_Outcome` in each completion, the table "each status has its kinds" becomes the table of the contract, and property 14 changes its words. Until this step the set can change.

A host test of the contract checks that each member has an effect group and a parent, that each new member is in `Nothing_Changed`, that each kind explains at least one outcome, and that the border refuses 17, the largest word, and each word past the last member. A test of each step gives each refused input and checks the outcome, the record and that nothing changed.

## Open questions

1. **A handle in the result of a call in doubt**: the rule that finds and ends a handle that arrived when the completion did not.
2. **A documented list of the outcomes of each export**, in the description, which the replacement check compares. It waits for a reader that needs it.
3. **A row status in a batch**: is the status of each row of a table a `Call_Outcome` word, so that a batch of N rows reads as N calls?

## State

Decided: designed, not built. Nothing of this form is in the code. The steps are in the section Next of [`ROADMAP.md`](../../../ROADMAP.md).
