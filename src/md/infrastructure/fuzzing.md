# Fuzzing

## Purpose

Each border of the system reads bytes that it does not trust: a module file from the network, the blocks of a disk, a datagram, a record of another program, the arguments of a kernel operation. A host test checks the hostile cases that its writer thought of. Fuzzing checks the cases that nobody thought of: the tool gives the real code of the system millions of inputs, made from the inputs that reached new code, and checks after each one that the code did what its contract says.

This file records the form of that machinery: the targets and their order, how a fuzz target calls the code of the system, the edge counters that guide it, the mutators, the oracles, the corpus in the repository, the bounded run of `modustool check`, the long runs, and the fuzzing of the kernel operations in a test machine.

## Constraints

- **The real code, not a copy.** A fuzz target calls the procedures that the system runs (`module.validate`, `storage_mount`, `quic`, `tcp`, `web`), from the source library `modus`. A second reader written for the test proves nothing about the first.
- **The tool uses the Odin standard library only** ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The commands of the tool"). No engine, mutator or runtime of another project is linked into the tool. Programs of the host that the build already runs (`odin`, `opt`, `llc`, the linker, QEMU) stay programs that the tool starts.
- **A test checks a condition, never a speed** ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The bounds of the tests"). The run of `modustool check` is a count of executions, not a duration. A rate of executions is printed as a measure.
- **The check is deterministic.** Two runs of `modustool check` on the same sources run the same inputs and give the same verdict.
- **No new kernel operation and no new grant in the system that ships** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "1. Small kernel with a small, counted interface"). The kernel side of the fuzzing lives in a test volume.
- **No program of the system reads the edge counters of the kernel** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close"). Which code of the kernel ran is a side channel on what other programs do.
- **A module of a release is never instrumented** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "11. Reproducible system"). The instrumented outputs are in their own folder of `build/`, and the release image refuses every test volume ([release_image.md](release_image.md)).
- **The corpus in the repository has a bound.** It is reviewed as code is reviewed, and a clone of the repository stays small.

## The targets, in order of value

The order weighs three facts: who can write the bytes (the network and the disk first), how much code reads them, and how few hostile host tests exist.

1. **The module file** (`src/library/contract/module`: `validate`, then each reader of a table: `record`, `field`, `string_at`, `function`, `export_address`, `bind`, `rebase`), with the import scan of `disk_program`. A module comes from the network into the store `programs` ([../features/programs_from_a_disk.md](../features/programs_from_a_disk.md)). Its package has no host test of its own. The invariant is the core of the flat tables: a file that `validate` accepts gives no read out of bounds through any reader, for any index.
2. **The debug object** (`src/library/contract/debug_object`). It comes beside a disk program, from the same network, and the debugger service reads it.
3. **The storage format on the disk** (`storage_mount`, `storage_tree`, `storage_object`, `storage_retention`, the hash index). A principal or an attacker with the disk writes any block. A damaged block must give a refusal or a damaged store, never a fault and never a wrong object.
4. **QUIC and TLS 1.3** (`src/library/support/quic`: `datagram_take`, `header_read`, `packet_open`, the frames, `transport_parameters_read`, `tls_receive` and each message reader). They read the network before any key is known.
5. **TCP and HTTP** (`tcp/segment`, `web/request`). The same network.
6. **The remote protocol** (`src/library/contract/remote`: `request_check`, `answer_check`). It reads a client that the handshake admitted.
7. **The records between programs**: the call region (`src/library/contract/isolated` `decode`), the error records (`errors.completion_record`, the sentences of `src/library/support/sentence`), the client table, the palette table, the demand cache and glyph cache records, the value runs, the text encoding check, the kept stop report, the kept settings (`settings.kept_read`).
8. **The disk grant table** (`disk_program.table_decode`). Its tag is checked first, so a fuzz target gives the key to the decoder: a fault after the tag is a fault of a key holder, and the decoder must still refuse it.
9. **The system description and the boot image** (`system_description.entries`, `kernel_check`, `image_check`), and the TPM answers (`src/library/support/tpm2`).
10. **The fonts and the shaping tables** (`vector_font`, `text_shaping`), the pointer theme (`pointer_pictures.validate`), the IOMMU tables of the firmware (`iommu.dmar_read`, `ivrs_read`, `mcfg_read`). A signed image or the firmware writes them today. A fault there still stops a service or the start, and the readers are long.
11. **The kernel operations**: the 35 operations through command records, with the images that the kernel reads in the memory of a program (`Thread_Registers`, `Thread_Breakpoints`, the extended state, the `Page_Range` tables). This target needs a test machine, so it has its own form below. Its value is the highest; its order here is the order of the work, because it builds on the engine of the host targets.

The search of the processors in the ACPI tables reads the firmware through raw addresses inside the kernel (`src/kernel/apic.odin`). No host code can call it. It becomes a target when its reader moves into a contract package, as the readers of DMAR and IVRS did.

## The chosen form

### The harness is the tool

A fuzz target is a procedure of the tool: it takes the bytes of one fuzz input and calls the code of the system. The tool already imports the contract and support packages, already writes most formats (the converter writes module files, the build writes stores, the peer speaks QUIC and TCP), and already reads the Odin types with `core:odin/parser`. One program then holds the targets, their generators and their writers, and all automation stays one command.

The tool runs each target in a **child process**: a second copy of the tool binary, started as `fuzz-child <target>`. A fault of the code under test ends the child, not the tool. The child runs the loop (choose, mutate, execute, read the edge counters, keep) in its own memory, as an in-process engine does, so an execution costs a call and not a process.

The child and the tool share one file, mapped by both: the **mailbox**. Before each execution the child copies the input into it and adds one to its count of executions. When the child ends on a signal, the tool reads the input that ended it from the mailbox. When the count stays still for the hang bound, the input is an input that never returns, and the tool ends the child. This is a stall bound, not a test of speed ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The bounds of the tests").

The code under test is the source of the system compiled for the host: the same packages, the collection `modus`, bounds checks on as in each module of the system. It is another compile of the same source, so a fault found on the host is confirmed by its host test, and a fault of a program is confirmed in a machine when its code depends on the target.

### Edge counters from the LLVM of the build

The build of a module already passes through LLVM IR and `llc` ([llvm_of_the_build.md](llvm_of_the_build.md)). The instrumented child is built the same way:

1. `odin build tools/modustool -print-linker-flags -keep-temp-files` writes one IR file for each package (a large package gives one for each of some of its files), and prints the commands of nasm and of the link, with no link.
2. `opt -passes=sancov-module` of the flake's LLVM 18 instruments only the IR of the packages under test, with `-sanitizer-coverage-level=3` (each block and each critical edge), `-sanitizer-coverage-inline-8bit-counters` (one byte for each edge, no call), `-sanitizer-coverage-pc-table` (the address of each edge, for the report) and `-sanitizer-coverage-trace-compares` (the two values of each comparison).
3. `llc` makes each object, nasm each assembly file with the command that the compiler printed, and `clang` of LLVM 18 links them with the flags that the compiler printed. The flake puts that `clang` on the path: it is the one that the compiler itself links with.

One IR file for each package is what makes the selection exact, so no list of procedures is needed: the refused alternative, one IR file with `-sanitizer-coverage-allowlist`, matches procedures by name patterns, which a new procedure of a package can miss.

The tool gives the callbacks that the pass calls (`__sanitizer_cov_8bit_counters_init`, `__sanitizer_cov_pcs_init`, `__sanitizer_cov_trace_cmp1` to `8`, the forms with a constant, `__sanitizer_cov_trace_switch`) as Odin procedures with these link names. The tool and the Odin runtime are not instrumented, so the counters say which code of the system an input reached, and nothing else.

An input is kept when it gives an edge a count that no kept input gave, by the classes of AFL: 1, 2, 3, 4 to 7, 8 to 15, 16 to 31, 32 to 127, 128 and more.

### Two kinds of fuzz input, one engine

- **A raw target** reads the fuzz input as the bytes that the system reads: a module file, a datagram, a block, a request.
- **A generated target** reads the fuzz input as a sequence of choices. A generator of the tool reads its next choice from the input each time it decides (a count, a kind of record, a value, whether to break a field), and builds a whole value from them: a module file with consistent tables, a store of several blocks, a QUIC flight with its keys, an operation sequence. An input that runs out of choices reads zeros. This is the choice sequence of Hypothesis.

Both kinds are bytes, so one engine, one corpus format and one minimizer serve both. A generated target reaches the code behind the first checks of a format; a raw target reaches the first checks themselves. The important formats get both.

### The mutators

- **Bytes.** Flip a bit; set a byte, a 16, 32 or 64-bit word (both orders of bytes) to a boundary value (0, 1, the maximum, the maximum of the signed type, a power of two and its neighbours); add or subtract a small number; insert, erase, copy and repeat a range; splice two kept inputs.
- **Constants of the source.** The tool reads the package under test with `core:odin/parser`. Each constant and each enumerated value of the package becomes a word of the dictionary of the target: the magic values, the format numbers, the sizes, the limits and the limit plus one.
- **The values of the comparisons.** After an execution, the tool reads the two values of each traced comparison. Where one value is in the input, a mutation puts the other one there. A magic value or a checksum of the format is then passed in a few executions.
- **The fields of the contract records.** A fuzz target of a format registers the regions of the input that the reader takes as a record, with the type of the record (a `module.Table_Entry` at this offset, an array of `store.Pointer` there). The mutator reads the fields of that type from the type information of the compiler (`core:reflect`): their offsets, sizes and types are the compiler's, not a second description. It then writes one field: an enumerated field gets each named value and the maximum plus one; an integer field gets the boundary values, the size of the input, and the offset or the count of another region.
- **The choices.** For a generated target, the byte mutators act on the choices. A change of one choice changes one decision of the generator, and the generator still builds a whole value.

### The oracles

After each execution the target checks, in this order:

1. **No fault.** A bounds check of Odin, a division by zero, an access past the input. The child places each input at the end of a page, before a page that it maps with no access, so a read one byte past the input faults even through a raw pointer, which no bounds check sees. Every second execution places it at the start of a page, after such a page, for a read before the input.
2. **An end.** The stall bound above.
3. **The contract of the reader.** The result is one of the values that its type names, and a refusal names a problem that the reader documents. A reader that accepts gives a value whose invariants hold: for a module file, each reader of each table at each index stays in the file; for a store, each object that the mount names has blocks that the mount counted.
4. **A round trip**, where a writer exists: `settings.kept_of` and `kept_read`, `remote.request_write` and `request_check`, `answer_write` and `answer_check`, `table_encode` and `table_decode`, `client_table_write` and `client_table_read`, `transport_parameters_write` and `transport_parameters_read`, the frame writers and the frame readers of QUIC. What the reader accepts and the writer writes again gives the same bytes; what the writer writes the reader accepts. Where the record of the reader has more fields than the record of the writer, the oracle expects the value that a reader gives to an absent field, and the system gives that value in one procedure, never a list in the target. The transport parameters are the case: `transport_parameters_write` takes a `Sent_Transport_Parameters`, which has no field for the five parameters that the system never sends, and `transport_parameters_of_sent` gives the record that a reader finds, with the defaults of RFC 9000, section 18.2. The oracle writes the `sent` part of the record read first and compares the second reading with `transport_parameters_of_sent` of that part. A target that compared the whole record read first reported the omission by design as a fault.
5. **A model.** The B-tree of the storage runs a generated sequence of `put`, `remove`, `get` and `first_from` beside a sorted map of the Odin library, and must give the same answers. Then the blocks that it wrote are mounted, and the walk of the mount must count the same entries. Then a generated damage writes over some blocks, and the mount must refuse them or report a damaged store.
6. **A second implementation.** Where the system has two readers of one fact, they must agree: the walk of `storage_mount` and the lookups of `storage_tree`; a QUIC client and a QUIC server of the system in one process, one datagram of their exchange mutated as plain frames and sealed again with the keys of the run. A reader of another project is used only as a program of the host, outside the tool: the QUIC client of OpenSSL stays the machine test `quic-real`.

### Fuzz findings, minimization and the corpus

A fuzz finding is an input that breaks an oracle. Its signature is the oracle and the place of the fault: the procedure of the faulting address, from the table of the edges, or the file and line that the bounds check of Odin prints. Two findings with one signature are one finding.

The tool minimizes each finding while its signature stays: for a raw target, by removing ranges of bytes and by lowering bytes; for a generated target, by the passes of Hypothesis on the choices (remove a range, set a range to zero, lower one choice). Each smaller input of a generated target is still an input that the generator can build, so the minimized value is valid where the generator makes it valid.

The **corpus** of each target is in the repository, in `tools/modustool/fuzzing_corpus/<target>/`, one file for each input, named by the BLAKE3 hash of its bytes. It has two parts:

- **The regression inputs**: each minimized finding after its fix. They are never removed.
- **The reach inputs**: the smallest set of kept inputs that gives each edge class that the long runs reached. The command that writes them keeps the smallest input for each edge class, then removes each input whose classes another input gives.

The corpus of one target holds at most 512 inputs and 1 MiB; the whole corpus holds at most 16 MiB. `modustool check` refuses a corpus over a bound, a file whose name is not the hash of its bytes, and a folder that names no target.

**A finding becomes a host test in two forms.** Its minimized input enters the regression inputs, so each run of `modustool check` runs it again with all the oracles. When the right answer is more than "no fault" (a refusal with a named problem), `modustool fuzz show` prints the input as an Odin array literal and the result of the current code, and the developer writes a named host test in the package of the reader with the expected problem.

### The run of the check and the long runs

**`modustool check`** runs, for each host target, each input of its corpus, then a fixed count of new executions (a named constant of the tool; a target whose execution does much, such as a whole handshake, states a smaller count). The seed of the generator is the BLAKE3 hash of the paths and the bytes of the sources of the tool and of the source library, the inputs of the child, so the same sources run the same inputs, and a change of the code under test explores other inputs. The check fails on any fuzz finding and prints it. It prints the executions in one second as a measure.

**`modustool test`** has the part `operation_fuzzing`: the operation sequences of the corpus run again on the test volume of the kernel fuzzing.

**The long runs** are commands of the tool, never a part of a check:

- `fuzz <target> [executions] [processes]`: runs a target for a count of executions, or until it is stopped; with several processes, each process runs a child, and the children share the kept inputs through the folder of the run in `build/fuzzing/`.
- `fuzz all [executions]`: each host target in turn.
- `fuzz operations [executions]`: the kernel operations in a test machine.
- `fuzz list`: the targets and the inputs of their corpus.
- `fuzz show <target> <file>`, `fuzz minimize <target> <file>`: one input again, with its outcome and its bytes as an Odin array; the smallest input with the same signature.
- `fuzz regression <target> <file>`: adds a fixed fuzz finding to the regression inputs, and refuses one that still breaks an oracle.
- `fuzz corpus <target>`: writes the reach inputs from the kept inputs of the runs.

A run prints each new finding with its signature and its minimized file, the edges that it reached for each package, and the executions in one second as a measure.

### The kernel operations

The kernel is fuzzed as syzkaller fuzzes a kernel: by sequences of operations whose arguments follow a description of each operation, run by a program inside a machine, guided by edge counters of the kernel. The description is the one that the system already has: `OPERATIONS` of `src/library/contract/operation/forms.odin`, which gives the form of each parameter (a handle of a kind with rights, an address, a count with its limit, flags with the known bits, a choice with its maximum).

**The operation sequence.** A generated target builds a list of up to 64 command records. For each parameter, the generator chooses mostly a value that fits the form, sometimes a value at its edge, sometimes any value:

- a handle: a handle that an earlier command of the sequence gave back, by its place in the sequence, with the kind and the rights of the form or other ones; 0; a value that names no handle;
- an address: inside a mapped area of the child, at its first or last byte, across its end, in the half of the kernel, not canonical;
- a count: 0, 1, the limit, the limit plus one, the maximum;
- flags: a subset of the known bits, then one unknown bit;
- a choice: each value up to the maximum, then the maximum plus one.

An address that an operation reads as a record (a `Page_Range` table, a register image, a breakpoint image, an extended state area) gets the bytes of that record, made by the field mutator from its type. The tool keeps one table of these records, one row for each address parameter of `OPERATIONS`, and refuses a parameter with no row: a new operation then stops the generator until its records are described.

The kind of the handle that each operation gives back, and the statuses that each operation can give, are read by the tool from the reference comment of the operation (`-> memory handle`, the list "**Statuses**"), with `core:odin/parser`, as the site reads them. A status that the comment does not list is a fuzz finding: the kernel or its reference is wrong.

**The machine.** A test volume, built as the volumes of the self tests are, holds:

- a kernel whose IR passed `opt` with `-sanitizer-coverage-trace-pc-guard`. The callback of the guard is a procedure of the kernel that adds one to the counter of the edge only while the processor runs the commands of a thread of the program under test, as KCOV counts only the system calls of one task. Interrupts, the scheduler and the commands of the other programs add nothing. This kernel knows the program under test by the name that `operation_fuzzing` gives it in `Program_Create`; the kernel that ships has no such rule. An ignore list that the tool writes keeps the callback and the entry paths out of the pass;
- the program `operation_fuzzing`, a device service of an `ivshmem-plain` device of QEMU. Its memory is a file of the host that the tool maps too: it is the mailbox of the machine.

For each operation sequence, the tool writes it into the mailbox. `operation_fuzzing` copies it, then checks it, starts a child program with a budget of its own, gives it the sequence, and waits for its end or its fault on the fault ring. The child runs the commands from its ring and writes each status and each result. The service stops the child, writes the statuses into the mailbox, and adds one to the count of executions.

The tool reads the counters of the kernel through the memory of the machine: QEMU runs with its memory in a file of the host (`memory-backend-file` with `share=on`), the instrumented kernel writes the physical address of its counters on the serial port at its start, and the tool maps the file. No program of the system reads them.

**The oracles of the kernel.**

- The kernel stops on its own fault with its report on the serial port.
- The checks of a test build of the kernel (the order of the locks, the sums of the frames, the placement) stop it.
- After the stop of each child, its budget holds no frame and no handle: a leak of the kernel.
- A status outside the list of the reference.
- The count of executions stays still for the hang bound: a deadlock or a lost wake of the kernel.

**A fault of the kernel stops the machine.** The tool reads the last sequence from the mailbox file, which outlives the machine, and starts the machine again. `fuzz replay operations <file>` runs one sequence on a new machine: first on the test volume, then on the main volume, whose kernel is the kernel that ships. The fuzz finding is real when the plain kernel shows it too. The minimizer runs each smaller sequence on a new machine.

## The refused forms

- **libFuzzer, AFL++ or honggfuzz as the engine.** Each one is C or C++ linked into the target (`libclang_rt.fuzzer`, the runtime of `afl-cc`, the runtime of honggfuzz). The tool uses the Odin standard library only, and the structure-aware mutators read Odin types, so they need glue code of another language there. libFuzzer itself is in maintenance only. The corpus format (one file for each input) stays the format of these engines, so a developer can point one of them at it by hand.
- **A flag of instrumentation in the fork of the compiler.** The pass `sancov-module` takes its options from the command line options of LLVM, which Odin does not pass. The fork then carries one more change at each release of Odin, for the same pass that `opt` runs on the IR that the build already writes.
- **Counters written into the source by the tool.** The experience of go-fuzz (golang/go issue 14565): a rewrite of the source breaks with each change of the language, cannot count each edge of an `&&`, and gives slow code.
- **No counters, generation only.** Cheaper to build, but each input is a new random draw: the engine cannot keep an input that reached a deep check and work from it. Nyx found more faults with counters at a lower rate of executions than a faster blind fuzzer.
- **Snapshot fuzzing of the machine (Nyx, kAFL).** It restores a whole machine thousands of times a second and gives the counters of any code through Intel PT. It needs a patched KVM, an Intel processor with PT, and its own QEMU. The system runs on one fixed machine: upstream QEMU with KVM, on Intel and on AMD hosts. A new machine after each fault of the kernel costs one boot, and such faults are rare.
- **The counters of the kernel in a memory object of a program.** A program that reads which code of the kernel ran learns what other programs do. Even in a test volume, a grant that gives it is a grant that the system has.
- **A plugin of TCG for the counters of the kernel.** It needs QEMU without KVM, and it sees the code of every program and every interrupt, so the counters do not say what the sequence did.
- **A slow input as a fuzz finding.** A rate depends on the host. A long run prints the slowest inputs as a measure; an input that never returns is the one fuzz finding of time.
- **A random seed in the check.** A check that fails once and passes again is read to its cause first, and a random seed makes the cause hard to find. The seed from the build key gives new inputs for new code and the same inputs for the same code.
- **OSS-Fuzz and ClusterFuzzLite.** Both build their targets with clang and libFuzzer in their own images, for a fixed list of languages, and Odin is not one of them.
- **A reader of another project as a differential oracle inside the tool** (FreeType for the fonts, OpenSSL for QUIC as a library). The tool then links a library of another project. The QUIC client of OpenSSL stays a program of the host in the machine test `quic-real`.

## The subtle points

- **A target must be a function of its input.** A reader that keeps a state between two calls, or reads a clock, or draws random bytes, gives other edges for the same input. The target resets each state, gives a fixed clock, and seeds each generator of the code under test from the input. The tool runs each new kept input twice and prints the edges that differ.
- **The host compile is not the module.** The target triple, the level of optimization and the allocator differ. A fault that comes from the code of the source shows on both; a fault that comes from the code that LLVM made for the freestanding target shows only in a machine. This is one reason the kernel target runs in a machine.
- **The page after the input sees what bounds checks miss.** A slice access of Odin is checked; an access through a raw pointer (`^Header` over the bytes of a file, `[^]u8`) is not. Only the page with no access finds such a read past the input. A read past an inner buffer of the reader is not found that way; `-sanitize:address` of Odin finds some of those in a long run, where the runtime of the sanitizer exists on the host.
- **The tag of an authenticated format.** A fuzz target of the disk grant table gives the key to the decoder. Without the key, every input stops at the tag and the decoder behind it is never reached.
- **The instrumented kernel is another kernel.** The callback adds instructions to each edge, so a fault of the order of instructions or of the depth of the stack can show only there. The replay on the main volume decides. The measure of the deepest stack runs on each kernel that the build makes ([kernel_stack_depth.md](kernel_stack_depth.md)), the instrumented one too.
- **A sequence can depend on time in the machine.** A command that waits, a budget of processor time, the order of two processors. The machine of the fuzzing has one processor, and the generator gives a wait a deadline of zero or the hang bound. A sequence that gives other statuses in two runs is printed as unstable, not kept.
- **TCP has no integrity.** A segment injected with its sequence and its acknowledgment in the windows is data of the remote for the receiver. The oracle of the order of the bytes holds only for a run with no injected segment; a run with one checks the bounds of the records only. The first finding of `tcp_connection` was this fault of the oracle, and its input stays in the corpus.
- **A count of steps is a choice drawn before each step.** In a generated target, `for _ in 0 ..< fuzz_choice_below(...)` reads its bound again at each turn, so a zero choice ends the steps there. The inputs of the corpus are read this way: a change of this reading changes what each of them means.
- **The documented statuses are a contract.** A status that the kernel gives and the reference does not list is a fault of one of the two; the fuzz finding does not say which.

## State

Built: the engine on the host. The child with its mailbox, its pages with no access and its handler of faults; the instrumented build; the edge counters and the traced comparisons; the mutators of bytes, of the dictionary of the sources, of the compared values and of the fields of the contract records; the minimizer; the corpus with its bounds and its check; the commands `fuzz` and the part of `modustool check`; the targets of the module file, of the debug object, of the B-tree and of the open of a disk, of QUIC, of TLS, of the transport parameters, of TCP and of the head of an HTTP request. A host test of the tool plants a fault that the engine must find in a fixed count of executions with a fixed seed, then minimize to its smallest input.

Built after them, with a seed of each form and its edges:

- **The remote protocol**: `remote_request` (`request_check`, `result_bytes`, `details_bytes`, the round trip through `request_write`), `remote_answer` (`answer_check`, `details_shown`, the round trip through `answer_write`), `remote_client_table` (the read and the write of the client table, `client_find`, `client_restore_decision`, `client_grant_holds`), and `isolated_call`: `isolated.decode` of a description of types and directions that the module format names, with any counts and details, over a call region. The descriptions name records of one fixed module that the target writes at its start.
- **The records of a ring**: `ring_records` gives each record to `display.event_of_record`, `terminal.input_of_record`, `system.service_command_of_record`, `root_ring.command_of_word` and its refusal, `command_of_record`, `machine_key_report_of_values`, `root_ring.member_of_word` and the borders of the words of an error record. A refusal gives the zero value; a member equals its word.
- **The disk grant table**: `disk_grant_table`, behind its tag (the first byte of an input says if the target seals it). What the decoder accepts encodes and decodes to its part that persists, and to its own bytes when each row and each key persists.
- **The system description**: `system_description` reads a description: the one that entries accept is the bytes that its writer gives for its entries. `boot_image_generated` builds a kernel, the files of a boot image and their description, and changes one byte: a changed byte of the kernel, of a listed file, or of the description outside its security version fails a check. The signature covers the security version; the checks do not.
- **The fonts**: `vector_font` (the tables, each glyph, outline, advance, pair and substitution, the measures and the draw of one glyph), `glyph_cache` (`validate`, then each glyph of each scale and position, each advance and pair), `font_outlines` (`validate`, then the round trip through `resource_write`).
- **The pointer theme**: `pointer_pictures` (`validate`, then `choose` for each form, shape, size and time). The manifest of a theme is read by the tool at the build, not by the system, and the instrumented build counts the edges of the source library only.
- **The tables of the firmware**: `firmware_tables` (`dmar_read`, `scope_resolve`, `unit_of`, `ivrs_read`, `amd_unit_of`, `mcfg_read`).

The oracle of `remote_answer` named one fault of a border before its first run: `answer_check` accepted a status that names no member of `remote.Status`. It now refuses it, and its host test gives it the largest member plus one and the largest word.

The edges of `support/terminal` are not counted: the instrumented build selects an IR file by the name of the folder of a package, and the package of that folder is `terminal_records`. Its target still runs it; the engine is guided by the other packages of the target.

Left, in this order: the other records between programs (the sentences of the error records, the palette table, the demand cache, the value runs, the text encoding check, the kept stop report, the kept settings) and the TPM answers; the search of the processors in the ACPI tables, which reads raw addresses inside the kernel; the kernel operations in a test machine ("The kernel operations"); a scheduled workflow that runs `fuzz all` and keeps its fuzz findings as files of the run; two threads of one operation sequence on two processors.
