# The outcome of a call: prior art and the state of modus

Status: research note, 2026-11-23. Sources were fetched on that date unless marked UNVERIFIED. "Inference" marks a deduction of this note from verified facts. "Measured" marks a fact that this note measured with the compiler of the flake.

The design that this note supports is the proposed intent file [`src/md/api/call_outcome.md`](../../src/md/api/call_outcome.md).

| Key | URL |
|---|---|
| ERRNO | https://man7.org/linux/man-pages/man3/errno.3.html |
| P9ERR | https://9p.io/magic/man2html/2/errstr |
| HRES | https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-erref/0642cb2f-2075-4469-918c-4441e69c548a |
| NTST | https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-erref/87fba13e-bf06-450e-83b1-9241dc81e781 |
| IERR | https://learn.microsoft.com/en-us/windows/win32/api/oaidl/nn-oaidl-ierrorinfo |
| ZXERR | https://fuchsia.dev/fuchsia-src/concepts/kernel/errors |
| FLANG | https://fuchsia.dev/fuchsia-src/reference/fidl/language/language |
| RFC60 | https://fuchsia.dev/fuchsia-src/contribute/governance/rfcs/0060_error_handling |
| RFC138 | https://fuchsia.dev/fuchsia-src/contribute/governance/rfcs/0138_handling_unknown_interactions |
| SEL4 | https://docs.sel4.systems/projects/sel4/api-doc.html |
| HUB | https://hubris.oxide.computer/reference/ |
| GRPC | https://grpc.io/docs/guides/status-codes/ |
| AIP193 | https://google.aip.dev/193 |
| CABI | https://github.com/WebAssembly/component-model/blob/main/design/mvp/CanonicalABI.md |
| RUST | https://doc.rust-lang.org/std/result/ |
| ZIG | https://ziglang.org/documentation/master/ |
| SW413 | https://github.com/swiftlang/swift-evolution/blob/main/proposals/0413-typed-throws.md |
| SWCC | https://github.com/swiftlang/swift/blob/main/docs/ABI/CallingConventionSummary.rst |
| GOERR | https://go.dev/blog/errors-are-values |
| EXPCT | https://en.cppreference.com/w/cpp/utility/expected |
| P0709 | https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2019/p0709r4.pdf |
| DUFFY | https://joeduffyblog.com/2016/02/07/the-error-model/ |
| OTP | https://www.erlang.org/doc/system/design_principles.html |
| SYSV | https://gitlab.com/x86-psABIs/x86-64-ABI |
| AAPCS | https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst |
| RVABI | https://github.com/riscv-non-isa/riscv-elf-psabi-doc |

## 1. The question

An export of a module that can fail gives a negative integer in `rax` and writes an error record at an address that the caller gives ([`docs/MODULE_CONTRACT.md`](../MODULE_CONTRACT.md), "8. Errors that diagnose"). The contract says that a negative result is also a real answer (`math.number("-5")`). So the sign tells nothing alone: the reader needs the description of the export and the error record to know if the call failed. This note asks how other systems give the outcome of a call, how they separate the kinds of failure, how they carry details, how the form grows, what it costs, and what went wrong for them.

## 2. What modus has today

### 2.1 The sign of the integer result

- `system.call_direct` decides a failure with `function.error_record != 0 && result < 0` (`src/library/modus/system/calls.odin`). The remote service decides it the same way ("When value is negative and the export has an error record", `src/library/modus/contract/remote/remote.odin`).
- The check `export_error_record_check` reads the sources to find a `return` of a negative value in an export with no record. It cannot know if a negative value is a failure or an answer, so it reads forms of the syntax only ([`src/md/api/export_error_records.md`](../../src/md/api/export_error_records.md)).
- The storage service gives a distinct negative number for each failure (`storage.Export_Error`, -1 to -12) and also writes the error record, whose kind says the same thing (`Absent`, `Exists`, `Damaged`). The same fact is in two places, and its numbers are a second vocabulary.
- An export with a Record result has no integer result, so it cannot fail. The compositor gives `pointer()` as a Table of one row for this reason only ([`docs/MODULE_CONTRACT.md`](../MODULE_CONTRACT.md), "A call from the host").

### 2.2 Eleven sets that each say how a call ended

| Set | Where | Members | What it says |
|---|---|---|---|
| `op.Status` | the kernel completion | 9 | the class of a kernel refusal; the error record explains it |
| `isolated.Status` | the completion of an isolated call | 5 | the receiver refused the call record |
| `call_status.Call_Status` | the caller library | 10 | the caller view: lend failed, no room, ring full, stopped, refused, wrong answer, failed |
| `remote.Status` | the answer of `remote` | 2 | the remote service refused its own request |
| `block.Status`, `frame.Status`, `datagram.Status`, `entropy_service.Status` | the completions of the device rings | 6, 7, 10, 3 | the refusal of a ring command |
| `storage_status.Status` | the storage client | not counted | the storage call |
| `agent_bridge.Bridge_Status` | the agent bridge | 5 | `None = 0` and `Ok = 1` |
| `storage.Export_Error` | the integer result | 12 | negative numbers |
| the ends of a request of `machine_wire` | a request between paired machines | 4 | `Answered`, `Refused`, `Unknown_Outcome`, `Unreachable` ([`src/md/features/several_machines.md`](../../src/md/features/several_machines.md)) |
| `errors.Kind` | the error record | 40 | what is wrong, for a sentence |

- The comments of `datagram.Status` give, for each status, the error kind that the record holds: the status repeats the kind.
- `Bridge_Status` has `Ok = 1`. Each other set has its success at 0, as property 13 asks.
- `Unknown_Outcome` of the requests between machines and the call in doubt of the glossary (`docs/glossary/communication.md`) are one concept with two names.
- Inference: the problem is larger than the sign. The system has one concept, "how did this call end", and eleven vocabularies for it. The first rule of the objective ("one mechanism for one concept") refuses this.

### 2.3 What modus already does right

- **The kernel has two levels.** A completion holds `op.Status` in its kind and the error record in its values. The status is the fast answer, decided where the operation fails. The record is found after the failure, by `diagnose`, under other locks, and it can degrade to `Refused` when the cause is gone. "It never contradicts the status. Each status has its kinds." This is the form of gRPC (a small code and structured details), and it has a reason that gRPC does not state: the explanation is found later than the decision.
- **The error record is a described record of 56 bytes**, in memory of the caller or in the values of a completion, with no text, and a table of error details whose each row is one more error record. Each row has its own kind, so the kind cannot leave the record.
- **The supervision design** names the call in doubt: a call that the holder took and did not answer before it stopped ([`src/md/features/supervision.md`](../../src/md/features/supervision.md), "The calls in flight"). It gives `Holder_Stopped` and `No_Answer` to a caller, and replays an idempotent export or an export with a request serial.
- **The border of a status word** (`system.status_of_word`) turns a word that names no status into the refusal `Bad_Operation` with the record `Bad_Value` of the word, "never the status that the caller happens to test". This is the precedent for an outcome word that names no member.

## 3. Prior art

### 3.1 C and POSIX: `-1` and `errno`

- A function gives a value that says "failed" (often -1 or a null pointer), and the reason is in `errno`, a value per thread. A function that succeeds can change `errno`, so a caller reads it only after a failure that the return value showed. [ERRNO]
- Separation of kinds: one flat namespace of numbers, with no class and no details.
- What went wrong: the reason is a value outside the call (a second call overwrites it); the sentinel differs by function (`-1`, `NULL`, `MAP_FAILED`, a positive error number for `pthread_*`); a function with no free sentinel (`strtol`) needs `errno = 0` before the call. [ERRNO] The modus contract already refuses this ("the defect of `errno`", [`docs/MODULE_CONTRACT.md`](../MODULE_CONTRACT.md), "The three places").

### 3.2 Plan 9: `errstr`

- A system call gives -1, and `errstr` gives a text of the reason, per process. A process sets its own text with `werrstr`. [P9ERR] The text crosses the file protocol in an `Rerror` message (UNVERIFIED: from the 9P manual, not fetched).
- Separation of kinds: none. The reason is a text, so a program compares texts.
- What went wrong (inference): a text is the only form, so a caller parses English to act. Property 19 refuses text between processes.

### 3.3 Windows: HRESULT, NTSTATUS, `GetLastError`, `IErrorInfo`

- An HRESULT is 32 bits: a severity bit (the sign bit: 1 is a failure), a facility and a code. NTSTATUS has a severity, a customer bit and a facility. [HRES] [NTST]
- So a success can carry information: `S_FALSE` is a success that is not `S_OK`. Inference: the sign carries the outcome and the low bits carry the reason, the form that modus has today, with the same hazard: `if (hr)` and `SUCCEEDED(hr)` give different answers for `S_FALSE`, and a negative value is never a value.
- `GetLastError` is `errno` per thread. `IErrorInfo` gives a rich object (a description text, a source, a help file) beside the HRESULT, through a per-thread slot that the callee sets. [IERR]
- What went wrong: three forms of error in one system (Win32 codes, HRESULT, NTSTATUS), and conversions between them that lose information. Facilities split one number space by owner, so a reader cannot act on a code of a facility that it does not know.

### 3.4 Mach: `kern_return_t` and MIG

- A kernel call and a MIG call give a `kern_return_t`: an integer, 0 for `KERN_SUCCESS`. A MIG reply holds a return code, and MIG adds its own codes for a message that it cannot decode. UNVERIFIED (not fetched).
- Inference: transport codes and function codes share one integer space, with ranges by convention.

### 3.5 seL4

- An invocation of a capability gives an `seL4_Error`: a small enum, with no error at 0. Its details are in the message registers of the IPC buffer. [SEL4] The list of the members is from memory of the manual: UNVERIFIED.
- Inference: a small closed class in a register and details in memory of the caller is the form of the modus kernel.

### 3.6 Zircon: `zx_status_t`

- In the kernel and in libzircon, a status is an integer: 0 or a positive value is success, each error is negative (`ZX_ERR_INTERNAL`, `ZX_ERR_BAD_STATE`, `ZX_ERR_PEER_CLOSED`). The page states a planned change to "0 for success and positive values for errors". [ZXERR]
- What went wrong: positive values for errors that an application defines were deprecated (3.7). Inference: Fuchsia also met the ambiguity of a sign that is both a value and an outcome, and is moving away from it.

### 3.7 Fuchsia FIDL: `error`, `framework_err`, epitaphs

- A two-way method can declare an error type: `int32`, `uint32` or an enum of them. The method is then encoded as a union of the response and the error. [FLANG] [RFC60]
- RFC-0060 found that before this syntax, methods gave a status and a value in an ad hoc way: "about 20% of the time" the error came after the result, and statuses were bools, ints, enums, strings and structs. It kept the error to 32 bits, refused arbitrary error data because it "could have encouraged anti-patterns like returning error message strings", and kept transport errors apart: a transport error closed the channel. [RFC60]
- RFC-0138 added flexible methods. A flexible method that the server does not know gets a third union member, `transport_err`, later renamed `framework_err`: a strict enum with one member, `UNKNOWN_METHOD = -2`, the value of `ZX_ERR_NOT_SUPPORTED`. The RFC states that for an application, where a transport error came from is not a distinction that it needs. [RFC138]
- An epitaph is the last message of a channel: a `zx_status_t` that says why the server closed it. Error codes that an application defines are deprecated. [FLANG]
- Lessons: (1) one declared form replaces ad hoc conventions; (2) an error is a small integer enum, never data or text; (3) the transport adds its own failures to the same union, as a separate member, and their set is small; (4) "the callee stopped" is a fact of the channel (the epitaph), not of one call.

### 3.8 Hubris

- `send` gives two integers: a response code and the length of the reply. The response code is defined by the application: 0 is success and non-zero is an error. The reply buffer is written also for an error, so an operation can give detailed data with an error. [HUB]
- A dead code is a response code that the kernel gives when the peer restarted: the top 24 bits are 1 and the low 8 bits hold the new generation of the peer. Applications start their own codes at 1 to stay clear of them. [HUB]
- `REPLY_FAULT` lets a server fault a client whose request it cannot accept; the reason is an enum of the ABI, for example a reply buffer that is too small. The kernel marks the client faulted, and its supervisor restarts it. [HUB]
- Inference: the response code is in a register, the details are in memory of the caller, and the transport (the death of the peer) uses the same channel with a reserved range. A malformed request is a fault of the client because Hubris is a static system: each task is trusted code of one firmware image, and the kernel carries each message.

### 3.9 Genode RPC, Barrelfish

- Genode declares the exceptions of an RPC function in its interface, and transports a thrown exception as a code in the reply, which the client stub throws again. UNVERIFIED (the page was not reachable).
- Barrelfish gives `errval_t`, a word that can hold a stack of error codes, each pushed by a layer. UNVERIFIED (not fetched). Inference: a stack in one word is an encoding that a reader must decode.

### 3.10 gRPC and AIP-193

- A call ends with a status: one of 17 canonical codes, with an optional message and details. The code set is small and system-wide. The codes say what the caller can do: `UNAVAILABLE` (try the call again), `FAILED_PRECONDITION` (do not try again until the state is fixed), `INVALID_ARGUMENT` (wrong whatever the state). [GRPC]
- Seven codes are given by user code only, never by the library: `INVALID_ARGUMENT`, `NOT_FOUND`, `ALREADY_EXISTS`, `FAILED_PRECONDITION`, `ABORTED`, `OUT_OF_RANGE`, `DATA_LOSS`. The library gives the others too (`CANCELLED`, `DEADLINE_EXCEEDED`, `UNAVAILABLE`). So transport and function failures share one code space, and the definition of a code says who can give it. [GRPC]
- `UNKNOWN` is the code for a status from another address space whose error space this address space does not know. [GRPC] Inference: an unknown code becomes a code that names the unknown. modus refuses that conversion for a contract enum, but it has the same need: a reader that does not know a word.
- AIP-193 requires an `ErrorInfo` detail with a `reason` (UPPER_SNAKE_CASE, at most 63 characters, unique within a `domain`) and a `domain`, keeps the message stable, and says that APIs do not support partial errors. [AIP193] Inference: the `reason` within a `domain` is the `kind` and the `unit` of the error record; a field violation is its `argument`.
- Cost: the status travels in the trailers of HTTP/2; the details are protocol buffers. It is not comparable with a register.
- Inference: the set of 17 codes has kept its members over many years of use; a small set of classes by the action of the caller is stable, and the details change. The exact history is UNVERIFIED.

### 3.11 The WebAssembly component model

- An interface declares `result<T, E>` with a type `E` for each function, often an enum or a variant of the interface. [CABI]
- The canonical ABI turns `result` into a variant: a discriminant, then the joined payload of the cases. A function with more than `MAX_FLAT_RESULTS = 1` flat result gives its result through memory: the callee returns a pointer (lift), or the caller passes one (lower). [CABI] So `result<u64, error-enum>` is three flat values and goes through memory.
- Inference: the component model has no transport failure, because a call between components is in one process and a trap ends the whole instance. The error type is per interface, so a generic host cannot act on it without the interface.

### 3.12 Rust: `Result` and `?`

- `Result<T, E>` has two cases, and `?` gives the error to the caller in one character. [RUST] The type `E` is chosen per function or per crate; programs convert with `From`.
- ABI: an `extern "C"` function has no stable form for a `Result`; a `#[repr(C)]` struct of two `u64` is returned in `rax` and `rdx` on System V (inference from [SYSV]).
- What went wrong: each crate has its own error enum, and crates such as `anyhow` and `thiserror` exist to erase or to wrap them. Inference: typed errors per function are precise inside one program, and costly at a border between parts that are built apart.

### 3.13 Zig: error unions and error sets

- An error set is a set of names; each name is a global integer of the compilation. A function can infer its error set (`!T`), and a subset converts to a superset. The integer type of an error has the least bits that hold all the error values of the compilation, or the count that `--error-limit` gives. [ZIG]
- Inference: inferred sets make the compiler, not the author, keep the list exact. The global numbering works because one compilation sees all the code; between modules that are built apart, the numbers differ.

### 3.14 Swift: `throws`, the error register, typed throws

- An error is returned in a dedicated register: `r12` on x86-64 and `x21` on AArch64, both callee-saved in C. [SWCC] This keeps `rax` and `rdx` for values, but no C compiler can produce it: LLVM has the convention `swiftcall` for it.
- Swift 6 added `throws(E)`. The proposal says that errors are usually propagated or rendered and not handled exhaustively, that untyped `throws` is better for most code, and that a typed error constrains the evolution of a function; its example is a file loader that later reads from the network. It keeps typed throws for code inside one module, for generic code that passes errors through, and for constrained code that cannot allocate. [SW413]
- Lesson: "it can fail" is part of the signature; the exact type of the reason is part of it only where the set cannot change.

### 3.15 Go

- A function gives its values and an `error` as its last result: an interface with one method that gives a text. [GOERR] No rule of the compiler checks the convention.
- What went wrong: errors are compared by identity or by type and wrapped with text, and a caller tests `err != nil` at each call. Inference: multiple results are the cheapest form at the machine (two registers), and the open interface makes a generic action (try again, ask for a grant) a matter of convention.

### 3.16 C++: exceptions, `std::expected`, P0709

- Exceptions with tables have no cost on success and a large cost on a throw, and they need unwinding information and a runtime. A system ABI does not unwind across a border between modules of two languages (inference; P0709 gives the cost and the bans of exceptions in many code bases).
- `std::expected<T, E>` (C++23) holds a value or an error. [EXPCT]
- P0709 ("Zero-overhead deterministic exceptions") proposes that a function marked `throws` returns a union of the value and an error of two words, with the discriminant in a flag of the processor, for example the carry. [P0709] Inference: a flag is not reachable from C; the paper confirms that an error as a value in registers is the efficient form.
- Exception specifications (`throw(X)`) were deprecated: they promised a type, and the runtime called `std::unexpected` when the promise broke. [DUFFY]

### 3.17 Midori: "The Error Model"

- Two forms. A bug is not a recoverable error: a contract violation, an index out of range, an overflow, a null dereference end the process at once ("abandonment"), with no user code run. A recoverable error is a checked exception, declared by `throws`, with `try` at each call that can throw. [DUFFY]
- Proportions: contracts outnumbered exceptions by 10 to 1, and plain `throws` outnumbered methods with several failure modes by another 10 to 1. Typed exceptions were used inside a system and translated into plain `throws` at the public border of the API. [DUFFY]
- On Java: checked exceptions with types make the versions of interfaces painful; with a single kind of `throw`, the version problem is no worse than with error codes. [DUFFY]
- On return codes: they cost a test at each call on the path of success, and they are easy to forget. The `Result` of Rust with `try!` is "a beautiful sweet spot". [DUFFY]
- Lessons for modus: (1) a bug ends the process that has it, and processes are cheap and isolated; (2) the signature says "can fail" and little more; (3) the details are not part of the type of the function.

### 3.18 Erlang/OTP

- A function gives `{ok, Value}` or `{error, Reason}`, where `Reason` is any term. A process that meets an unexpected state crashes, and its supervisor starts it again ("let it crash"). [OTP]
- Inference: two separate mechanisms, a value for an expected failure and a crash for a bug, with supervision as the answer to the crash. modus has the supervision design already.

## 4. Comparison

| System | Where the outcome is | Classes | Details | Transport failures | A value that the reader does not know | Growth | What went wrong |
|---|---|---|---|---|---|---|---|
| POSIX | a sentinel per function, `errno` per thread | none | none | same numbers | not handled | add numbers | value outside the call; the sentinel varies |
| Plan 9 | -1 and a text per process | none | text | text | not handled | free text | a caller parses English |
| HRESULT | sign bit of 32 bits | severity, facility | `IErrorInfo` per thread | same space | facility unknown | codes per facility | three forms; `S_FALSE` |
| seL4 | `seL4_Error` in a register | small enum | message registers | not applicable | not handled | rare | none found |
| Zircon | negative `zx_status_t` | one flat set | none | `PEER_CLOSED` | not handled | add codes | sign ambiguity; moving away |
| FIDL | union member | enum of 32 bits per method | refused | `framework_err`, epitaph | flexible method | per protocol | ad hoc forms before RFC-0060 |
| Hubris | response code in a register | per server | reply buffer | dead code range | not handled | per server | none found |
| gRPC | status trailer | 17 codes by action | `ErrorInfo` reason and domain | same codes | becomes `UNKNOWN` | details only | partial errors refused |
| Wasm components | discriminant; memory past one value | `E` per function | in `E` | a trap ends the instance | not applicable | per interface | no generic action |
| Rust | `Result` | `E` per crate | in `E` | not applicable | not applicable | per crate | wrapping crates |
| Zig | error union, global integers | inferred sets | none | not applicable | not applicable | inferred | global numbering |
| Swift | `r12` or `x21` | `any Error`, typed optional | in the value | not applicable | not applicable | typed limits evolution | not reachable from C |
| Go | last result | open interface | text, wrapping | same | not applicable | free | convention only |
| Midori | `throws`; abandonment | mostly one | exception object | the process ends | not applicable | plain `throws` | none found |
| Erlang | tagged tuple; crash | any term | the term | crash and supervisor | not applicable | free | none found |
| modus today | sign of `rax`; ten status sets | ten sets | error record, table of details | `Call_Status` | the border refuses | per set | sign ambiguity; duplicates |

## 5. Measures of this note

The compiler of the flake (`odin-dev-2026-11a`, `-o:speed`) compiled `proc "c" (a: i64) -> (value: i64, outcome: Outcome)` and the same procedure that returns a struct of two `i64`. Measured:

- **x86-64 System V**: the value is in `rax` and the outcome in `rdx`, in the two forms. No byte of memory is written. The callee computes the outcome in two instructions with no branch (`sar`, `and`), and the caller tests it with one test and one branch, as the test of the sign of `rax` does today.
- **AArch64** (`freestanding_arm64`): the value is in `x0` and the outcome in `x1`.
- **A float value.** `proc "c" (x: f64) -> (value: f64, outcome: Outcome)` and the same procedure with the outcome first. On x86-64 both orders give the float in `xmm0` and the outcome in `rax`: with the value first, the outcome moves from `rdx` to `rax` when the value is a float. On AArch64 the order decides: the first word is in `x0` and the second in `x1`, and the float travels as bits in an integer register. So only the order "outcome first" puts the outcome in one register (`rax`, `x0`) for each type of value.
- **WebAssembly** (`freestanding_wasm64p32`): the C ABI of the compiler returns the pair through memory: the first parameter is the address of the result, and the callee makes two stores. Core WebAssembly has results of several values, but this C ABI does not use them.
- **`or_return`**: with an enum whose zero is success, `tripled := inner(a) or_return` passes the outcome to the caller in one expression, and gives 0 as the value of a failure.
- **chibicc** (its source in the store): `copy_struct_reg` and `copy_ret_buffer` return a struct of up to 16 bytes in `rax` and `rdx`, as System V requires. So a C export can give the pair as a struct of two `int64_t`.
- System V returns two INTEGER eightbytes in `rax` and `rdx` [SYSV]; AAPCS64 returns a composite of 16 bytes or less in `x0` and `x1` [AAPCS]; the RISC-V psABI returns a value of up to two XLEN in `a0` and `a1` [RVABI]. UNVERIFIED for the exact clauses: these three documents were not fetched; the measures above confirm x86-64 and AArch64.

## 6. Lessons for modus

1. **A small closed set of classes, by the action of the caller, in a register; the details in memory of the caller.** gRPC, seL4, Hubris and the modus kernel agree. The class is decided where the call fails; the details can be found later and can be partial.
2. **The explanation is not the control word.** The table of error details holds one kind per row, and a stored record (a log fact, a completion) is read alone. So the kind stays in the record, and the control word is another fact: the class.
3. **The sign of a value is not an outcome.** HRESULT and Zircon show the cost, and Fuchsia is moving away from it.
4. **Transport failures go in the same channel, as a few distinct classes.** FIDL (`framework_err`), gRPC (`UNAVAILABLE`, `DEADLINE_EXCEEDED`) and Hubris (dead codes) do it. What a caller needs to know is whether the call ran: refused with no change, or in doubt.
5. **A typed error per function belongs inside a module.** Swift and Midori state it from use, and Rust needs wrapping crates. At a border between parts that are built apart, the signature says "can fail", and the reason is data of the whole system.
6. **A bug ends the process that has it.** Midori and Erlang do it; modus has cheap isolated processes and the supervision design.
7. **A reader meets a word that it does not know.** gRPC turns it into `UNKNOWN`; modus turns an unknown status word into a refusal with the record of the word (`system.status_of_word`). The second form keeps the rule of the enums.
8. **Two words of return cost nothing on x86-64 and AArch64.** They are reachable from C, Rust, Zig, Odin and assembly. They go through memory on WebAssembly only.
9. **The outcome comes first in the pair.** It is then in one register for each type of value on each machine (measured). The cost is at the border of Odin: `or_return` reads the last result, so Odin code swaps the two words at the export and at the import slot.
