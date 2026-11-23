# The outcome of a call: an independent study

This study answers one question. How does a call to an export report that it gave its value, or that it did not, and why? It covers the direct call, the isolated call, a ring completion and a call across machines. It is a research document: it proposes, and it decides nothing.

The current rule is in [`docs/MODULE_CONTRACT.md`](../MODULE_CONTRACT.md), "4. The call form" and "8. Errors that diagnose", and in [`src/md/api/export_error_records.md`](../../src/md/api/export_error_records.md).

## 1. The problem, reduced

Today an export that can fail gives a negative integer in `rax` and writes an `errors.Error_Record` at an address that the caller passes last. Five facts of the repository show that this form is wrong, not only inelegant.

1. **The value and the failure share one word.** `math.number("-5")` gives -5 as an answer. No caller can tell an answer from a failure without knowledge of the export.
2. **The failure has no type.** `export_error_record_check` finds a failing path with a list of syntax forms, because nothing in the type says "this path fails". The intent file states that a failure that gives 0 or an empty text "is found by review only".
3. **The ability to fail depends on the result type.** An export with a Record result gives no integer, so it "cannot refuse". `compositor.pointer()` became a Table of one row only to be able to refuse.
4. **The rule already leaks.** The rule says that -1 is enough. `storage.Export_Error` still holds 13 distinct negative results (-1 to -13), with their own border.
5. **The export is the one call with no outcome word.** A ring completion has its status in `kind`, outside its values. The isolated call and the remote answer add their own status beside the negative value: `isolated.Status`, `remote.Status`, `Answer.call_status`, `Answer.value`. A caller of a remote export reads four words to learn one fact.

The irreducible constraints:

- **C1.** A caller learns the outcome from the description alone (property 19). So the outcome is one described word, outside the space of the value.
- **C2.** Each compiler writes the form with `extern "C"` and no extension (property 19, `language_neutral_abi.md`).
- **C3.** A call that succeeds pays nothing in memory traffic, and no state lives outside the call (properties 14 and 24; "the defect of `errno`").
- **C4.** One description serves the direct call, the call host, a service and a remote. The export does not know which one ran.
- **C5.** A word that names no member is refused at its border. So each set that crosses a border needs a rule for its growth.
- **C6.** A record gives no fact that the caller cannot already see (property 20).

Counts in `src/modules`, by a search of the sources, tests excluded: 625 procedures `proc "c"`, 360 that return `i64`, 280 with an error record, 211 tests of the form `< 0`. No export uses a second integer result.

## 2. What the prior art teaches

Sources read for this study: the Canonical ABI of the WebAssembly component model and the Hubris reference (both fetched). The other systems are cited from their public documents, not fetched again.

| System | Its form | The lesson for modus |
|---|---|---|
| `errno`, the Linux kernel | -1 and a thread value; in the kernel, -4095 to -1 in the result | The sign convention fails where a negative is an answer (`lseek`, `getpriority`, `ptrace`). A value outside the call is lost or stale. Already refused here |
| BSD and macOS system calls | The carry flag says "error"; `rax` holds the value or the code | An outcome outside the value costs nothing. A flag is not writable in C: C2 refuses it |
| HRESULT, NTSTATUS | One word packed as severity, facility, code; `IErrorInfo` beside the call | Several success codes (`S_FALSE`) cause faults: one member for success. A packed word hides three sets in one. Details beside the call are lost |
| seL4 | `seL4_Error`, about ten members, and the details in message registers | A small class set with details in a fixed place stayed stable for many years. It is the nearest relative of the error record |
| Zircon, FIDL | `zx_status_t` for the kernel and the transport; a result union `-> (T) error E` for a method; later a third arm for an unknown method; an epitaph when a channel closes | The transport and the method fail in different ways, and a third origin appeared after the first design. The nested result of the bindings is heavy for a caller |
| Hubris | A response code of 32 bits, 0 for success; dead codes when the server restarted; `REPLY_FAULT`, where the server faults a client that broke the contract | "The callee died" is a class of its own, in the same word. A fault of the client fits a fixed set of tasks. It does not fit a console that passes values that a principal typed |
| gRPC | 17 canonical codes, closed for years, and open details (`ErrorInfo` with a domain and a reason) | A closed set that names what the caller can do, and an open set that names the cause. Its defect: the application, a proxy and the client library write the same codes, so a caller cannot tell who refused |
| WebAssembly component model | `result<T, E>`: a discriminant, then the payload. `MAX_FLAT_RESULTS` is 1, so a result with two flat values goes through memory. WASI gives each interface its own closed error enum | The discriminant comes first. An added case of an enum breaks the interface, so the set has a version. Typed errors for each interface work when the description carries them |
| Rust, Zig, Go, Swift | `Result` with no stable layout; error sets numbered for one compilation; `(value, error)`; typed throws and the `swifterror` register | None of these layouts crosses a border of languages. The useful parts: the caller must read the outcome, and one short form passes a failure up |
| Midori | A bug abandons the process; a recoverable error is a typed part of the signature | Two classes, two mechanisms. Abandonment is cheap when a process is small and isolated, as here |
| Erlang | `{ok, V}` or `{error, Reason}`; a monitor message when a process dies; a time limit with no known outcome | Three different facts: the function refused, the process died, nobody knows. A design that merges them makes a caller ask twice |

## 3. Where the floated candidate breaks

The candidate: `rax` holds the value only; `rdx` holds an `errors.Kind` word on every export, `None` for success, converted at one border; the record keeps the details; transport failures use the same channel. It removes the sign convention, which is right. It breaks in seven places.

1. **`rdx` is not a stable place.** A C compiler gives two result words only through a struct of 16 bytes. System V then places each word by its class. Measured with the compilers of the flake: `{value: i64, outcome}` gives `rax` and `rdx`; `{value: f64, outcome}` gives `xmm0` and `rax`; an export with no value gives `rax`. So "the kind is in `rdx`" holds for an Integer result only. The call form already reserves the float registers.
2. **`errors.Kind` grows, and the word of control must not.** `Kind` has 41 members and gains members with each feature. A newer callee gives a kind that an older caller does not know: a disk process, an outside module, a paired machine. The border refuses the word. The caller then knows that the call failed, and nothing more: not whether anything changed, and not whether a retry is safe.
3. **A kind alone is half a fact.** `Absent`, `No_Grant`, `Full` and `Damaged` take their meaning from the unit. A caller that reads only `rdx` reads "absent" with no subject.
4. **Two copies of one fact.** The kind is in `rdx` and in `record.kind`. Two places can differ, and a reader needs a rule for that case. If the record loses its kind, an export and a ring completion no longer share one record.
5. **"On every export" removes the export that cannot fail.** A getter of an enum parameter "cannot fail" by design (`enum_parameters.md`). A status word on it gives each call a failing path that no code can reach.
6. **"The same channel" hides who refused.** The remote service gives `Absent` when it has no connection to the service. The storage export gives `Absent` for a name. Today `Answer.status` tells them apart. One kind word alone does not. This is the defect of gRPC.
7. **`Kind` has no member for the facts of a path.** "The link broke after the request left" and "the call host stopped" are not kinds of a wrong argument. `several_machines.md` already names four ends of a request: `Answered`, `Refused`, `Unknown_Outcome`, `Unreachable`.

Points 2, 6 and 7 are faults of design. Points 1, 3, 4 and 5 are faults of placement, and a small change removes them.

## 4. The questions, one by one

### 4.1 A failure or a bug

Midori and Hubris treat a broken contract as a bug: the party that broke it stops. modus cannot make this the rule of the callee, for three reasons.

- A command is a function (property 19). The console passes values that a principal typed. `math.next_prime(2^41)` is an input, not a bug of the console.
- A callee in another process never trusts its caller. It checks each value in any case, so the refusal already exists.
- The test rule of the project asks for the refusal: its status, its record, and that nothing changed.

So the callee always returns the refusal, with its diagnosis. The caller decides what the refusal is. A program that computed the arguments itself can stop on it: one named helper stops the process and puts the record in the stop report. That is abandonment, chosen at the one place that knows whether the value was an input.

A bug of the callee is different. A callee that finds its own state broken stops. In a call host, the caller reads `Unknown_Outcome` and the stop report. In a direct call, the process stops, because the module shares its address space.

### 4.2 One closed set, typed errors for each export, or both

Three levels exist, and today they are mixed.

- **The class**: what the caller knows about the effect of the call. A generic caller acts on it: a retry, a pipeline, a relay, a test.
- **The cause**: `errors.Kind` and `errors.Unit`. The sentence writer and a caller that knows the export act on it.
- **The values**: argument, value, limit, found.

The class must be closed and frozen. The cause grows with the system. The fault of the candidate is that it uses the second level as the first.

Typed errors for each export are the third option. The description already has the door: `Function.error_record` names the record description of the error. A second step can add, in the description, the list of the pairs (kind, unit) that an export gives. The tool then checks each failing path against the list, the check of a replacement compares the lists, and a caller switches on a small closed set. This step changes no register and no layout, so it can wait.

One risk is separate: `errors.Unit` is a central list of 62 members that names tables of single modules (`Stop_Reports`, `Recorded_Writes`). An outside module cannot add a unit. This study does not solve it; section 9 lists it.

### 4.3 Growth against the border that refuses

The rule "an unknown word is refused" needs one answer for each level.

- **The class word is frozen.** Its set changes only with the version of the module format. A word that names no member means that the answer cannot be read. The honest member for that case exists: `Unknown_Outcome`. The border gives it, with a record that holds the word. No known member stands in for an unknown one: the caller really does not know.
- **A kind or a unit that the reader does not know stays a number.** The reader keeps the class, which it knows, and shows "kind 57". `Error_Record_Fact_Fields` already does this for the log. `refusal_record_of_values` today returns a zero record instead, which loses the failure.

So the control of a caller never depends on a set that grows.

### 4.4 Where the outcome lives

| Path | Today | Proposed |
|---|---|---|
| Direct call, x86-64 | The sign of `rax` | `rax`: the outcome word. `rdx` or `xmm0`: the value |
| Direct call, AArch64 | Not built | `x0`: the outcome word. `x1`: the value. This is the AAPCS64 rule for a struct of 16 bytes; not compiled for this study |
| Module code built for WebAssembly | Not planned: modules run as x86-64 on the software processor | The discriminant first, then the value, through the return area. The component model does the same for `result<T, E>` |
| Isolated call | `kind`: `isolated.Status`; `values[0]`: the sign | `kind`: the outcome word. `values`: the results, or the error record |
| Ring completion | `kind`: the status of the ring contract | `kind`: the outcome word, in a later step |
| Remote answer | `status`, `call_status`, the sign of `value` | One outcome word |

The outcome comes first because the first integer word of a C struct is always in `rax`, for each result type. A generic reader such as `export_call` then finds the outcome with no description.

### 4.5 A failure of the path and a failure of the function

The caller needs one word, because the export does not know which path ran (C4). The caller also needs to know who refused (section 3, point 6). Both hold when the class set has one member that only the path writes: `Not_Delivered`. The receiving border refuses that word when an export gives it, so an export cannot claim it.

### 4.6 The error record

- **Size**: 56 bytes. It is the size of the values of a completion, and that equality lets one record serve each path. Keep it.
- **Who allocates**: the caller (property 14). The address stays the last argument. `nil` stays "no record" in a direct call.
- **In the common case**: the callee does not touch it. The caller no longer needs to clear it: it reads the record only when the outcome is not `Answered`. Today an Odin caller that declares the record clears 56 bytes before each call.
- **What it lacks**: a chain of causes. A call through `remote`, a service and the block service has three layers, and the record holds one. The table of error details holds siblings, not causes. Section 9 lists this.

### 4.7 Results beyond one value

- **No value, or a Record result**: `rax` alone. An export with a Record result can then refuse, and `compositor.pointer()` can be a Record again.
- **A Text or a Table result**: the value is the count of the full answer. A count above the capacity stays an answer ("it did not fit"), never a second member for success.
- **Two integer results**: the outcome takes the second register. Two values go in a Record result. No export loses anything today.
- **The place of a result holds an answer only with `Answered`.** With each other outcome, the caller does not read it, and a border gives zero for the value. `system.call` already gives zero results for a status that is not Ok.
- **A handle in a result** (not built): it is valid only with `Answered`. With each other outcome, the path closes or revokes what arrived.
- **A part of the work done** (3 rows of 5): it is an answer. The result says what was done, in typed data.

### 4.8 The cost of one call

x86-64, the path of success:

| Form | Callee | Caller | Memory traffic |
|---|---|---|---|
| Today | `mov rax, value` | `lea` of the record, a clear of 56 bytes in most Odin callers, `test rax, rax`, `js` | The clear of the record |
| Proposed | `xor eax, eax`, `mov rdx, value` | `lea` of the record, `test eax, eax`, `jnz` | None |
| The value through memory (section 6) | `mov [place], value`, `xor eax, eax` | two `lea`, `test`, `jnz`, a load of the value | One store and one load, forwarded |

The proposed form adds one instruction that the processor removes at rename, and removes the clear. These are counts of instructions, not measures. The process `errors` already measures a direct call (39 ns for `square_root`): the same case gives the measured number. The software processor of the browser machine decodes each instruction, so a count of instructions matters more there.

### 4.9 Migration

- The return type changes from `i64` to a pair. Each call site that still reads the sign then fails to compile. The sign convention never had a compiler behind it; this form has one.
- `errors.fail` gives the outcome in place of a negative number. The 13 members of `storage.Export_Error` become records.
- `export_error_record_check` becomes one rule with no list of forms: an export has an error record if and only if it returns an outcome.
- The call host, `system.call_isolated`, `remote.Answer` and `modustool call` lose `isolated.Status`, `remote.Status` and `call_status`.
- The version of the module format changes, so that a module of the old form is refused.
- The rings of the services and the completions of the kernel move later, each ring contract in its own step.

## 5. The recommendation

**One frozen word says what the caller knows. The record says why. The value has its own register.**

```
Call_Outcome (a word of 64 bits; the set changes only with the version of the module format)
  0  Answered         The value and the places of the results hold the answer.
  1  Not_Delivered    The path refused before the export ran. Only a path writes it.
  2  Refused          The export judged the call and did no work. Nothing changed.
  3  Failed           The work started and did not finish. The export states what holds then.
  4  Unknown_Outcome  No answer that the caller can read. The call can have run.
```

The rules:

1. **An export whose description has an error record returns the C struct `{u64 outcome; T value}`**, by the rule of the machine for that struct. An export that cannot fail returns its value alone, as today.
2. **The record is written if and only if the outcome is not `Answered`**, at the address that the caller gave. Its kind is in the record only, never in a register.
3. **The members are ordered by what the caller knows**: `Not_Delivered`, then `Refused`, then `Failed`, then `Unknown_Outcome`. A border or a relay can weaken an outcome. It can never strengthen one.
4. **`Refused` is a promise**: nothing changed. It is the refusal that each test of the project already checks. A callee in doubt gives `Failed`.
5. **An export gives `Answered`, `Refused`, `Failed` or `Unknown_Outcome`** (the last when a call that it made itself had no known outcome). A path gives `Not_Delivered` and `Unknown_Outcome`: a wrong export index, an argument outside the call region, a handle that was not lent, no link; then a link that broke, a call host that stopped, a time limit.
6. **A word that names no member is `Unknown_Outcome`**, given by the border with a record that holds the word.
7. **A caller compares the word with `Answered` on the path of success**, which the rule of the casts allows. It takes the member through the border on the other path only.
8. **The caller must read the outcome**: `@(require_results)` in Odin, `warn_unused_result` in C, `#[must_use]` in Rust.
9. **A caller that holds a refusal for a bug stops through one named helper**, which puts the record in the stop report.

The frequent tasks (property 22), in Odin:

```odin
// An export.
next_prime :: proc "c" (after: i64, error: ^errors.Error_Record) -> (outcome: call.Outcome_Word, prime: i64)

// A caller that handles the failure.
outcome, prime := math.next_prime(after, &error)
if outcome != call.Outcome_Word(call.Outcome.Answered) { /* read error */ }

// A caller that holds each failure for a bug.
prime := call.must(math.next_prime(after, &error), &error)
```

What the form removes: the sign convention, the list of syntax forms of the check, the export that cannot refuse because of its result type, three status sets of the paths, and the clear of the record.

**The test that breaks this design on its first day.** Write one export with an Integer value, one with a float value and one with no value, in C, Odin, Rust and Zig. Call each from each. Check `rax` and `rdx` or `xmm0` in the machine code. Then give the border the words 5 and 2^64 - 1, and let an export give `Not_Delivered` through a call host. Done for this study with the compilers of the flake, for C and Odin on x86-64 only: `proc "c" (...) -> (outcome, value)` in Odin and `struct {uint64_t; int64_t}` in C both give `rax` and `rdx`; with a float value, both give `rax` and `xmm0`. Rust, Zig and AArch64 are not checked.

## 6. The strongest alternative

**The outcome alone in the result register; each value through a place of the caller.** It is the form of COM: `outcome f(arguments, T *value, record *error)`.

- For it: no struct by value, so the rule "no aggregate by value" has no exception. Each language writes it, on each machine, WebAssembly included. It is the exact shape of a ring completion: a status word, then values in memory. A generic caller needs one register.
- Against it: one store and one load for each Integer result. One more argument for each fallible export, where the bound is 12 and six are in registers. `math.next_prime` no longer gives its number in a register.

It is the right choice if the exception to "no aggregate by value" is refused, or if module code built for WebAssembly becomes a first target. The classes, the record and the rules of section 5 stay the same in both forms: the choice between them is a choice of placement only.

Other forms, refused:

- **The kind word as the outcome** (the candidate): section 3.
- **One bit, failed or not**: `Unknown_Outcome` and "nothing changed" then live in a set that grows.
- **The kind in `rdx` when the call failed, in place of the value**: a second copy of the kind, and no place for it with a float value.
- **A flag of the processor, or a register kept for the error** (BSD, Swift): C cannot write them.
- **A tag inside the value word**: it takes values from the answer, as the sign does.
- **A fault of the caller for a wrong argument** (Hubris): section 4.1.

## 7. What can make this wrong in five years

- **The class set misses a member.** Candidates: a cancel that the caller asked for, a holder that moved to another machine. Both fit today (`Unknown_Outcome`, `Not_Delivered` with a kind). A new member costs a version of the module format.
- **The promise of `Refused` erodes.** A service with much state gives `Failed` everywhere, and the two members become one. The test rule holds it; no check of the tool can.
- **A handle in a result with `Unknown_Outcome`.** The handle can have arrived when the completion did not. The path needs a rule to find and revoke it. Not designed.
- **A stream.** Its end record carries an outcome, and a gap is `Unknown_Outcome` for a span of records. One word fits there. A stream that fails in the middle after a part was used has no "nothing changed": only `Failed` and `Unknown_Outcome` apply.
- **Several machines.** A relay sees `Refused` from a holder that lies. Rule 3 bounds the damage: the relay can only weaken. A caller still cannot prove the promise of another machine.
- **The record stays at three values.** A cause chain, a text or a path does not fit in 56 bytes.
- **The central unit list.** Each outside module that needs its own subject needs a change of a contract package of the system.
- **The kernel keeps `op.Status`.** Two class sets then exist for years: the status of the kernel and the outcome of a call.

## 8. The contradictions with the documents of today

Per the rule "Push back", each one is named. None is a property; each is a guide or an intent file that changes first if the proposal is kept.

- `docs/MODULE_CONTRACT.md`, "4. The call form": the row "Errors" (a negative integer result), and the row "Results" (the second integer register becomes the value of a fallible export).
- `docs/MODULE_CONTRACT.md`, section 8, rule 1 ("an export gives its result") and "An export" ("it fails when its integer result is negative"; "an export with a Record result has no error record").
- `src/md/infrastructure/language_neutral_abi.md`, "No aggregate by value": the result struct of two words is a first exception. The alternative of section 6 has none.
- `src/md/api/export_error_records.md`: the check and its list of forms.
- `src/md/features/several_machines.md`: its four ends of a request map to the five members. `Unreachable` becomes `Not_Delivered` with a kind.

## 9. The questions that only the owner can decide

1. **Two registers or memory.** Accept the struct of two words as the one aggregate by value (section 5), or keep the rule whole and pay one store and one load (section 6)?
2. **Is "nothing changed" worth a member?** `Refused` and `Failed` as two frozen members, or one member and the promise in the documentation of each export?
3. **Does the kernel follow?** Does the completion of a kernel operation take `Call_Outcome` in its `kind`, with `op.Status` folded into the kinds, or does the kernel keep its own status set?
4. **The cause: one central set for ever, or a declared set for each export?** The list of pairs (kind, unit) in the description is a second step with no change of the call form. Is it wanted, and before or after the first outside modules?
5. **The units of an outside module.** Does `errors.Unit` stay one central list, or does a module declare its own subjects in its description?
6. **The bug policy.** Is the helper that stops the caller on a refusal the default form in the code of the system, or the exception?
7. **The names.** `Call_Outcome` beside the existing term "stop outcome"; `Answered` or `Done`; `Not_Delivered` or `Unreachable`.
8. **The order of the migration.** One batch for each export and each caller, or the exports first and the rings of the services in later steps?
