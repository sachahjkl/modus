# Log facts: typed records in place of formatted lines

## Purpose

A line of the log that matters becomes a log fact: a record type of the source, whose values the record carries with no text. The module file describes the type and gives its fact template, and the reader writes the sentence. Today a log record carries a formatted text and value runs: a reader knows that a part is a number, not that it is the `block` of a bad block. The writer formats each line, the formatting is inlined at each call site ([library_modules.md](../api/library_modules.md)), and a test compares sentences. With log facts, a reader filters by a field (`block = 12`), a machine test waits for a fact and its fields, and the tool refuses a test that names a field that no fact type has, before the machine runs.

The guide is [`docs/TOOLS.md`](../../../docs/TOOLS.md), "The log". The log scope does not change: [log_reader_scope.md](log_reader_scope.md).

## Constraints

- **No text between processes** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "19. A command is a function: no text between processes"). A reader parses no text of a writer.
- **No contract depends on a feature of one language** (property 19). The record of a log fact and its description are bytes and flat tables, not the types of Odin.
- **The kernel holds no text parser** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "1. Small kernel with a small, counted interface"). Its check of a log record is a filter of bytes, and it gets no new operation.
- **Module metadata is flat tables, read through functions** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "12. Module metadata in flat tables, read through functions").
- **The hash of a module is its identity** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "11. Reproducible system"). A module file cannot hold its own hash.
- **A library module holds no address that the loader rebases into a read-only segment** ([library_modules.md](../api/library_modules.md)).
- **A process sees no other process** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close", row 1). The log scope stays the one border of the reader.
- **A log record has 256 bytes**, and the whole log and each own log ring keep records of that one size ([own_log_ring.md](own_log_ring.md)).
- **One general mechanism, and a plain expression for each frequent task** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "22. General mechanisms, and a plain expression for each frequent task"). See "The frequent tasks".
- **The kernel log is lossy by design.** The whole log and the own log ring evict, the budget of each second refuses, and the serial port loses the lines of a flood ([log_side_channels.md](log_side_channels.md)).
- **No backward compatibility.** The record changes in place, and the old path leaves.

## The chosen form

### What the log is, and what it is not

The log is diagnostics for a person, a test or an operator. Its readers accept loss: a ring evicts, a budget refuses, the serial port drops lines and counts them. A record has no order that the work of its writer promises, and a reader reaches it through the log service and its log scope.

The work of a module, for another program, goes through a record output of the module, which the other program reads as a record input: the answer of the system to the refused `stdin` and `stdout` of property 19. A record output loses no record, has flow control, is reached through a handle that someone gave, and is part of the contract of its module. Its design is [module_outputs.md](module_outputs.md).

The two share one part: a record type of the source, extracted into the module file as a record description (`docs/glossary/communication.md`, "Record description"). That part is generic. The table `Records` of the module file holds the description of each record that the module names: the records of its exports, of its log facts, of its record outputs and of its record inputs. Nothing in it is a log thing. The kernel log and the record outputs share nothing else: not the path, not the guarantees, not the rights.

**The record output `log`.** Each process has one record output that no module declares: `log`, which carries its own log records, its text lines and its log facts. Its starter can wire it at the start of the process, for an audit. The kernel log stays as it is, lossy diagnostics; a wired `log` has the guarantees of a record output: no record is lost, and the writer waits for its reader. So a process can keep the log of a child whole, which the kernel log never promises. See "The record output `log`" below.

### The fact type in the source

A fact type is a record type with one fact template. The template is an attribute of the type, and the call names the value only: no string is at the call.

```odin
// A block whose check is not the check that its pointer names.
@(log_fact = "storage: the block {block} has a wrong check {check}, expected {expected}")
Bad_Block :: struct {
	block:    u64,
	check:    value_kinds.Hexadecimal_32,
	expected: value_kinds.Hexadecimal_32,
}

system.log_fact(.Warning, Bad_Block{block = number, check = found, expected = wanted})
```

- **The attribute.** `log_fact` is a custom attribute: the build gives the compiler `-custom-attribute:log_fact`, which accepts it on a declaration and ignores it. Without the option the compiler refuses the attribute ("Unknown attribute element name"). The tool reads the attribute and its literal from the syntax tree.
- **The fact key is the typeid of the record type.** `system.log_fact(level, value: $T)` writes `transmute(u64)typeid_of(T)`. See "The fact key: why the typeid".
- **The compiler holds two refusals.** The procedure has the clause `where !intrinsics.type_struct_has_implicit_padding(T) && size_of(T) <= op.LOG_FACT_VALUE_CAPACITY`, so a record with padding or too large fails at the compile of the call, before the tool runs.
- **The tool holds the rest.** It refuses a call whose value is not a composite literal of a named type, because it has no type checker. It refuses the named type of a call when that type has no attribute `log_fact`. And it refuses the attribute on a declaration that is not a record type of the package scope.
- **One fact type for one record type.** The template is on the type, so a record type has one template. The fact name for a reader is the package name and the type name: `storage.Bad_Block`.
- **The kinds of the fields** come from the distinct types of `modus:contract/value_kinds`, as for an export ([console_value_colors.md](console_value_colors.md)). This design adds the kinds that the log uses today and a record description lacked, as the field kind (`value_kinds.Field_Kind`): a hexadecimal Integer (`value_kinds.Hexadecimal_32` and the other sizes), a status of a contract enum (the field has the type of the enum, `operation.Log_Level`, and the reader writes the name of the member), a module name as a Text field (`value_kinds.Module_Name_Field`), and a hash as a fixed array of bytes that the reader writes in hexadecimal (`value_kinds.Hash_Field`, a field of the type Bytes). [console_value_colors.md](console_value_colors.md) holds the form in the description, the borders and the colors.
- **No padding.** The compiler and the tool refuse a fact type with a byte that no field covers. Such a byte carries memory of the writer that no field names.
- **No Handle field.** A handle number means nothing to a reader of the log. The tool refuses it.
- **No Body field.** A `Body` field is an offset and a count in the body region of a record output ([module_outputs.md](module_outputs.md), "A large body"). Only the record of a record output or of a record input takes it: the tool refuses it in a log fact, as in the record of an export. A log fact has no body region, and its values are whole in its record. The type does not exist yet: the check of the fields of a fact type is a whole switch on the type of a field, so the first build with a type `Body` fails to compile until that switch refuses it.
- **At most 144 bytes** of fields (`op.LOG_FACT_VALUE_CAPACITY`): the values of one record. A fact is one record, never more.

### The fact key: why the typeid

The code needs the key of a fact type at its compile, from the type alone, and the tool needs the same number from the source. Three ways were read.

**(a) `typeid_of(T)`, chosen.** The facts, from the sources of the compiler of the flake (the fork of `dev-2026-11a`, `src/name_canonicalization.cpp`, `src/check_builtin.cpp`, `src/llvm_backend_type.cpp`) and from builds:

- **It is a constant in the code.** The checker gives `typeid_of` a value of the type, `exact_value_typeid(t)`, and the back end writes it as `LLVMConstInt` (`lb_typeid`). A build for `freestanding_amd64_sysv` with `-o:speed` and `-reloc-mode:pic`, the flags of a module, writes `store i64 1239833465674507115, ptr @sink` for `typeid_of(T)` in a polymorphic procedure: an immediate, with no address and no table of type information (0 lines with `type_info` in that IR).
- **It is the hash of a name, not of a layout.** `type_hash_canonical_type` is SipHash-2-4 with a fixed key (`k0 = 0xa6592ea25e04ac3c`, `k1 = 0xba3cba04ed28a9ae`) over the canonical name of the type. For a named record type of the package scope, the canonical name is `<package name>::<type name>`: `storage::Bad_Block`. No address, time, path or order of the build enters it.
- **It is the same in each build and in each module.** Two builds gave `18017458693634389201` for `storage.Bad_Block`. The value depends on the two names only, so each module that compiles the package gets the same key.
- **It is unique in a module.** The compiler refuses two packages with one name in one build ("A package name must be unique"), so two fact types of one module have two canonical names.
- **The tool computes it.** SipHash-2-4 with the same key, over `storage::Bad_Block`, gave `18017458693634389201`, the value of the compiler. The tool has its own SipHash (`build.siphash_2_4`), checked against the vectors of its paper: `core:crypto/siphash` brings a package whose name the copy of the cryptography of Odin in the library also has, and the compiler refuses the two in one build.

The contract states the key as bytes: "SipHash-2-4, with the key of 16 bytes above, over `<package name>::<type name>` in UTF-8". A writer in another language computes it, so the contract does not depend on Odin (property 19). In Odin, `typeid_of` computes it.

The costs:

- **The key depends on the compiler.** A new compiler with another canonical name or another seed changes every key. So the tool checks it at each build: for each fact type, it searches the LLVM IR of the module, which the build writes before `llc`, for the immediate of the key that it computed. A fact type whose key the IR does not hold, at a call, fails the build. A host test of the tool compiles one fact type and compares the two values, so a change of the compiler fails before a module is built.
- **RTTI stays on.** `typeid_of` is refused with `-no-rtti`. The modules are built with RTTI today; the IR of `console` holds no table of type information, and the IR of `cryptography` and `root` holds one. Measure 5 shows whether a fact type adds bytes of type information to a module file.
- **A rename is a new key.** A fact type keeps its key while its fields change; the module hash then names the new description. A new name of the type or of its package is a new fact type, which a test that names it sees at its check.
- **The key has 8 bytes**, so the record holds 144 bytes of values, not 152.

**(b) A key that the tool generates, refused.** The tool parses each package before the compile and writes a generated file with one constant for each fact type, which the code reads. A generated file is allowed when nobody edits it: its source changes, and the tool writes it again. The cost: one more step before each compile, a build key that holds the parse, a generated file in each package that writes facts, and a stale file to detect. An index that it generates also names a fact type inside one package, not inside the module: a fact type of a support package needs its package in the key too. The typeid gives the same with no file.

**(c) The other ways read, refused.** The FNV hash of the template with `#hash` (the form before): a string beside the type. The tag of a union of the fact types of a package: two packages of one module give the same tags. The place of a declaration in a link section: an address, and a rule of the linker. No intrinsic of the compiler gives the name of a type as a constant string.

### The fact table of the module file

The tool reads each type with the attribute `log_fact` that a call of `system.log_fact` names, in each package that the module compiles in, and writes the table `Facts` of the module file. One row for each fact type, sorted by fact key:

| Field | Meaning |
|---|---|
| `key` | The fact key, never 0. |
| `record` | The index of the record description in the table `Records`. |
| `template_offset`, `template_count` | The fact template, in the string table. |
| `package_offset`, `package_count` | The name of the package that declares the record type, in the string table. |

A type with the attribute that no call of the module names gets no row: a support package does not add the fact types that a module does not write.

The tool refuses at the build:

- two fact types of one module with the same fact key, a fact key of 0, and a key that the IR of the module does not hold as an immediate `i64` (the compile step reads `<name>.ll` after the compiler wrote it, and before `llc`);
- a fact template that breaks a rule of the template language (below);
- a field that the fact template does not name, and a name in braces that names no field;
- the attribute on a declaration that is not a record type, on a declaration inside a procedure or a `when`, or on a type private to its file: each of them has another canonical name, so the key is not the typeid of `<package>::<type>`;
- a record of a fact type whose name the module describes another way: one module describes a record name one way, whichever declaration names it.

The extraction reads the sources that the compiler read for the module (its list of dependencies), and parses only a file that holds the word `log_fact`. The checks of the template language are one pure procedure of the contract, `module.fact_template_check`, which each reader that renders a fact calls too: the tool and a reader cannot disagree on a template.

The tool describes each record type once in `Records`, whichever declaration names it: an export, a log fact, a record output or a record input. A record type that an export takes and a log fact writes has one row, and both name it by its index. Nothing in a record description says which declaration named it. The refusals of a fact type above are the refusals of the declaration, not of the record description.

The package name gives the fact name that a reader and a test write: `storage.Bad_Block`, the package name and the name of the record type, the two names of the key. A fact type of a support package keeps one name in each module that compiles it in: `interface.Element_Place` is the same name in the compositor and in each window.

A fact template changes the hash of the module, as each byte of the metadata does. So the pair of a module hash and a fact key names one description, and the record needs no version number.

### The fact template

The language is the least that writes today's sentences:

- UTF-8 text, with no control character ([text_encoding.md](../data/text_encoding.md)).
- `{name}` writes the field `name` by its kind: an Integer in decimal, signed or unsigned by its description; a Size or a Time with its unit; a hexadecimal Integer with `0x`; a status by the words of its member, which are its name but for a stop cause and a stop outcome ([console_value_colors.md](console_value_colors.md), "The words of a member in a sentence"); a Text up to its first zero byte; a hash in hexadecimal.
- `{{` and `}}` write one brace.
- At most 256 bytes.

It refuses: a name that names no field, a field that it does not name, a field named twice (one value once in a line), an unclosed brace, a name that is not an identifier, a format inside the braces (a width, a precision, a base), and anything more: no condition, no plural, no expression, no field of a field. The kind in the description decides the form of a value, so the template never says it. A fact type that needs another sentence for another case is two fact types.

### The record

**The size.** A log record has 256 bytes today (`#assert(size_of(Log_Record) == 256)` in `src/library/contract/operation/operation.odin`), 16 records in a page, and a text line of up to 168 bytes takes one record. A fact takes one record of the same 256 bytes, so it costs no more memory in the whole log, in an own log ring or in the budget of each second than a text line of one record. A text line longer than one record costs more records than the fact of the same line. The size stays 256 until a measure shows that a smaller record pays (measure 8).

The record keeps its head: the number, the time, the process slot, the process serial, the own number, the thread, the level, `more` and the name of the process, which the kernel sets. A byte of the head that is reserved today becomes the record form (`op.Log_Record_Form`, an enum with explicit values): `Text = 0` and `Fact = 1`. A zero record is a text record, as before.

The body after the head has 192 bytes. Today a record is a text record: the value runs, then 168 bytes of text, since the channel left. With the form byte:

| Form | Body |
|---|---|
| `Text` | The value runs (24 bytes), then the text (168 bytes). A long text continues in the next records (`more`). |
| `Fact` | The module hash (32 bytes), the fact key (8), the count of the value bytes (2), 6 reserved bytes, then the values (144). One record, `more` is 0. |

Text records and fact records follow each other in the whole log and in each own log ring, with one number sequence. The records of each second of a budget count a fact as one record.

**The version rule.** The record changes in place. Each reader takes the byte of the form through one border, which refuses a byte that names no member: the reader shows "a record of an unknown form" with its head, and no body. The service `log` gives no row of `log.records` for such a record, nor for a record whose level byte names no member of `Log_Level`, and counts it in `lost`, as a torn record: the fields `form` and `level` of a row are enums, and an enum field never holds a word that names no member. Both bytes pass their borders at one place (`record_borders`). Such a record leaves the result too, which counts the rows of the scope, so a result of 0 is true. When the call gives no row at all, `lost` has no row to be in: the contract of `records` says that a reader with no row learns no count ([log_reader_scope.md](log_reader_scope.md), "A reader whose own records are all gone"), and this keeps that form. The gap record of `log.follow` is the form that will say a loss with no row (see "The frequent tasks"). A new form is a new member. The fact record itself has no version: its module hash pins its description.

**The module hash.** A module file cannot hold its own hash, and the kernel does not know which code of a process called `Log`. So the module file names an own-hash place in its writable data, and the loader writes the hash of the module there when it binds the module. `system.log_fact` copies those 32 bytes. The kernel writes the place of the root service when it starts it, because the root service has no loader for imports. A place of zero is no module: a reader shows the fact raw.

The place is a variable of the support package `system`, exported under the symbol `modus_own_hash`: an exported variable has bytes that the compiler cannot take as the zeros of the file, and the version script of the link keeps the symbol local to the module. The conversion finds the symbol in the symbol table of the linked file, checks that it is 32 bytes in a segment that the loader writes, and writes its offset as record 1 of the table `Own_Hash`. A module whose code never reads the place has no table: the link drops the variable. `validate` refuses a place that is not 32 bytes in one segment with Write and no Execute, so no file makes a loader write into its code. Each loader writes the place where it rebases and binds, for the range of the segments that it prepares (`module.own_hash_write`): the loader of `system`, the kernel for the root service, the loader of the tool on the host. The place took the version of the module format to 3: a loader of version 2 would leave it zero.

The refused forms of the place: a field of the header, which has 4 bytes free and needs 8, and makes each file pay for a place that most modules do not have; a table that the loader finds by the name of a symbol at the load, which puts a symbol table in each module file.

### The writer path and its cost

`system.log_fact(level, value)` builds the body on the stack: the module hash, the key, `size_of(value)` and the value bytes. It gives the body to the kernel with one `Log` operation of the form `Fact`. It formats nothing, and the call site holds a composite literal and one call. With the note of the refused lines and the count of a refusal, it never waits for the kernel log, as `system.log` ([log_side_channels.md](log_side_channels.md)). When the record output `log` is wired, it also writes that record output first, and waits there (see "The record output `log`").

The `Log` operation takes the form after the runs: `(log, address, length, level, runs, form)`. This changed from a form before the runs: in the last place, a zero form is `Text`, so each writer of text keeps its call of five values, and a call of five values cannot have its count of runs read as a form. The kernel converts the word to `Log_Record_Form` at its border, and refuses a word that names no member with `Bad_Operation`. For the form `Fact` it refuses runs with `Bad_Operation`, and a length below the head of a fact (48 bytes: the hash, the key, the count and the reserved bytes) or above the 192 bytes with `Bad_Address`. It copies the bytes into one record with no UTF-8 filter, because the body is not text, writes the count of the value bytes from the length and zeros the reserved bytes. It reads no other field of the body. The kernel interface keeps its count of operations. The kernel part of this is two procedures of `src/kernel/serial.odin` (`log_fact_operation`, `log_fact_record`), the border of the form in `Log`, the line of a fact in the serial writer, and the error records of the refusals.

The cost to measure, and the claim that the measures must prove (see "The measures that decide it"): one kernel entry dominates both paths. A fact saves the formatting in the process, the UTF-8 filter and the cut of the runs in the kernel, and the records of a text longer than one record.

`system.log` stays for a throwaway line and a debugging line, as text, with a level: `system.log(.Warning, "storage: the block ", block, " has a wrong check")`. The level is the first argument, as in `system.log_fact`, so one form names the level at each call.

### The record output `log`

**What it carries.** One record of the contract record `Log_Output_Record` for each record that the process gives the kernel log: the level, the form, the time of the system clock that the writer reads in its time page, the module hash, the fact key, the count of the bytes, `more`, and the bytes of the text or of the values. It has the 256 bytes of a log record and the same body, so a fact is one record and a long text is several records with `more`. It has no process slot, no process serial, no own number and no name: the reader knows the writer by the wiring that it holds, and the serial of each record of a record output numbers it. The record is in `Records` of no module file: the contract describes it, so the type check of the wiring compares the description of the contract on both sides.

**Who can wire it, and when.** The starter of a process, in the wiring list of its `Start` command, and only there ([module_outputs.md](module_outputs.md), "The wiring list of a start"). The root service applies the whole list before the first instruction of the process, so the audit holds each record from the first one, after a joined record of 0. The authority is the check of the root service that the asker asked for the start of that process: no process handle with Control and no other grant ([module_outputs.md](module_outputs.md), "The wiring and its rights"). No wiring of `log` comes while the process runs.

**One reader.** `log` takes one wiring. The root service refuses a second row of a wiring list that names `log` of the same child with `Bad_Wiring`, and the whole list with it. A second reader of the same log reads it from the first one, as the collector forwards ([module_outputs.md](module_outputs.md), "The record output `log`").

The wiring gives the starter no new fact: a starter already reads the records of its child by lending the process handle to `log.process_records` ([log_reader_scope.md](log_reader_scope.md)). The difference is the guarantee, not the scope. The records that another process writes about this one (the line of the root service at its start, the report of the kernel at a fault) are not its own records, and are not in its `log`.

**The writer path when `log` is wired.** `system.log` and `system.log_fact` write each record twice, in this order:

1. To the record output `log`, with `system.output_write` and no deadline: the writer waits while the ring of its reader is full. No record is lost, so a reader that does not read stops the writer. A thread with a deadline (a frame loop, the path of a key) waits too: the starter that wires `log` takes that cost for the child.
2. To the kernel log, with `Log`, as before. A refusal of the budget of each second drops the line in the kernel log only; the record output already holds it.

When the reader stops or closes its end, the record output gives `Ended`, the library removes the ring, and the process goes on with the kernel log only. The reader knows the serial of the last record that it read, so the end of the audit is known, not silent. When the writer stops, the reader gets the end word `Writer_Stopped` with its stop cause and its stop outcome ([../api/process_stop.md](../api/process_stop.md)).

**How the end reaches the process: one handle slot of the context.** The context of a process has one handle slot for the end of `log`, beside the log handle (`docs/MODULE_CONTRACT.md`, "6. The context"). The root service writes there, before the first instruction, the handle of the ring with the rights Read and Write, only when the wiring list of the start wires `log`. The library maps the ring at the first write of the log. The end of `log` never goes through the wiring ring, so a process whose only wiring is `log` gets no wiring ring.

**A process with no wiring pays nothing more.** Its slot holds 0. Each write of its log reads that one word, in the line of the context that the log path already reads for the log handle, and goes on to `Log`, as today: no ring, no page, no wiring ring. Measure 9 of [module_outputs.md](module_outputs.md) proves it.

### The serial port

The serial writer writes the line of a fact record from its bytes, with no template: `[storage] #1a2b3c4d5e6f7081:fa0adf38a559f4d1 0c000000000000001a2300001a2b`, for `block = 12`, `check = 0x231a` and `expected = 0x2b1a`. That is the first 8 bytes of the module hash, the fact key, and the value bytes in hexadecimal, in the order of memory (an integer is little-endian), up to their last byte that is not zero. It is a filter of bytes, as the line of a text record is.

The tool renders the line on the host: it holds each module file that it built, finds the module by the 8 bytes, and writes the fact template with the values. The tool refuses a build where two module files share their first 8 bytes. Each step of a machine test reads the rendered line, and the raw line when no module file has that hash. The machine keeps the rendered log and the length of the file that it covers, and each read of the log renders only the whole lines after it: the same lines give the same text, so a place in the log is the same place in each read. A Text value takes the filter of the kernel for a text in the render, because the kernel filters no byte of a fact. The file of the machine log, which QEMU writes, keeps the raw lines; a copy of it with the rendered lines is left. A person who reads the serial port with no tool reads the raw form.

### The reader path

A reader copies a record, then reads its form through the border. For a fact record:

1. It checks that the count of the value bytes is at most 144.
2. It finds the module file by its hash in its catalog: the boot image that it was granted, and the store `module_files` through the module file service. It keeps the last modules that it found, so a log of one writer costs one search.
3. It reads the table `Facts` through the information functions, which check the table as they check each table of a module file. A module file is hostile input: a template that breaks a rule gives the raw form, not a fault.
4. It finds the row by the fact key, with a search in the sorted table.
5. It checks that the count of the value bytes is the size of the record description, else it shows the raw form.
6. It writes the template, each field in the color of its value kind. A Text field is copied, then checked as UTF-8, and a bad sequence is the replacement character.

**The raw form.** With no module file, the reader has no field name: the names are in the module file only. It shows the fact name as `#1a2b3c4d5e6f7081:fa0adf38a559f4d1` and the value bytes in hexadecimal. The proposal said that a reader with no module file shows the field names; that cannot hold, because the record carries no name.

**One render.** Steps 3 to 6 are one pure procedure of the contract, `module.fact_sentence_write`: the file, the key and the value bytes in, the sentence and one value run for each value out, or a refusal (no fact type of the key, a count of the value bytes that is not the size of the record, a template that breaks a rule, a sentence longer than the buffer of the reader). It copies the values before it filters a Text field, so the bytes of the caller do not change. The console, the window `log` and the tool call it, so two readers never write two sentences for one fact. The tool wrote its own loop before; it had no unit after a Size or a Time.

**The catalog of each reader.** The console reads the boot image that it holds. The window `log` gets the grant `image`, the boot image read-only: the catalog is a grant of its own, and the image holds no secret of a process. A disk process names a module of the store `module_files`, which neither reader reaches yet: its facts show raw. The console checks each module file of the image that has a fact table once, at its start, when it reads the fact names, and keeps those files: the fact names, `facts` and the render read only files that the checks took, and a refused file gives no name. The window keeps the last 8 modules that it found and the last 8 hashes that no module of the image has, so a log of one writer costs one search of the image, and a fact of a disk process too. A reader does not hash a module file again: the boot program hashed each file of the image against the signed system description before the kernel ran (`system_description.image_check`, which `trust_check` of the boot program calls), and the image is granted read-only.

**The window and the service share one thread.** The process `log` is the window and the service: one thread takes each new record, draws, and serves `records`. It now checks a module file (`module.validate`) and writes the sentence of a fact when it takes the record, never in a frame: a frame copies the sentence that `take` kept with its row. This is accepted because the checks run once for each module and each hash with no module, which the two caches keep, and a fact costs one render. A call of `records` waits at most for the checks of the modules that the new records name for the first time. If a measure shows that a check holds a call too long, the check moves to a second thread.

**The rows of the log service.** A row of `log.records(after)` keeps its text for a text record, and `log.value_runs` stays for text records. The row gives the level as a status of the contract enum `Log_Level`, and the record form as a status of the contract enum `Log_Record_Form`: a reader knows a fact from its row, and `where(level = Warning)` compares a member, not a text. The text of a fact row is empty. A row of `records` has 256 bytes, the limit of a record description, so the fields of a fact come in a second table joined on `number`, as the value runs do: `log.fact_records(after)` gives, for each fact of the log scope, the record form, `more`, the fact key, the module hash, the count of the value bytes, the reserved bytes and the 144 value bytes. The values are one Bytes field of the field kind `Fact_Values`: the bytes of the record of the fact type that the hash and the key of the same row name, which a reader with no description writes in hexadecimal, as the raw form. A Bytes field was a hash only ([console_value_colors.md](console_value_colors.md)): a field of any content stays refused, and this kind names its content. The first form gave the first 8 value bytes only, and no reader could render. The log service renders nothing: it holds no catalog, and a rendered text loses the fields that a reader filters on.

**The readers that render.** The console writes the sentence of each fact in the records of a line, each value in the color of its kind; it asks `log.fact_records` for the facts of an answer of `records` that holds a row of the form `Fact`. The window `log` reads the records from the memory of the log, with the values whole, and draws the sentence in the place of the text. The service `remote` reads no log record: the tool reads the rows of the log through it, and renders on the host with its own catalog of the build.

### The log channel left

The channel of a log record was the name of 16 bytes that the writer gave at each call (`system.log_in`). A typo made a new stream, any process wrote any name, and most texts already repeated it ("kernel: boot: ..."). The fact type and its module group the records better: a reader chooses its rows by fact type, by process and by level. So the channel left the record, the `Log` operation, `system.log_in`, the serial line (`[name] text`) and each reader, in the first step of the migration, before any fact type exists. No grouping replaces it for `system.log`: a line that a reader groups is worth a fact type. A free name that any writer types is the form that this design removes, by any word.

The glossary entry "Channel" (`docs/glossary/running_code.md`) left with the field, and "Log record" says that a record carries no name that its writer chooses. The word has no meaning in the system: the glossary entry "Ring" lists it under "Do not use", "Log record" lists "log channel", and a record output does not take it.

**One writer of text, with its level.** `system.log(level, ...)` is the one writer of a text line of a process: no second procedure without a level, so each call says its level. The kernel keeps its own two writers, `log` at the level Info and `log_with_level`: they are kernel code, not the library, and most lines of the kernel are of the level Info.

**Each former channel, sorted.** The counts were the calls of `log_in` in `src/`. A channel also came through a variable: `interface.element_places_publish` took one.

| Channel | Calls | Writers | Kind | What its readers use once facts exist |
|---|---|---|---|---|
| `processes` | 248 | the root service: starts, stops, revocations, the trust, the start policy; `interface` through its variable: the element places of each window | (a) a subject tag | The fact types of the root service (`root.Process_Stopped`, with its stop cause and its stop outcome as fields, and `root.Process_Started`; see "The facts of the root service") and `interface.Element_Place` and `interface.Element_Gone`. The step `Fact` and the test pointer read their fields. |
| `surfaces` | 99 | the compositor: windows, the pointer, the clipboard, the measures of a frame; `interface` for the palette | (a) | The fact types of the compositor; its measures as fields that the tool reads. |
| `devices` | 50 | the TPM service, the root service at the start of a device service | (a) | The fact types of `tpm` and of the root service. |
| `storage` | 29 | the storage service | (c) redundant: the process `storage` | The process and the fact types of `storage`. |
| `calls` | 17 | the root service: connections, client keys | (a) | The fact types of the root service (`root.Connected`, `root.Disconnected`). The step `Record` "connected console to the service storage" reads the sentence of `root.Connected`, which the tool writes from its fields. |
| `sound` | 13 | the sound service | (c) redundant: the process | The process. |
| `fault` | 6 | the kernel: a stop on a fault, a full fault ring, a refused return | (a), and the kernel keeps text | The step `Record` reads the process `kernel`, the level `warning` and the text. |
| `network` | 4 | the network service | (c) redundant: the process | The process. |
| `disk` | 4 | the storage service, of the block device | (a) a subject inside one module | The fact types of `storage` (`storage.Disk_Silent`). |
| `""` | 4 | `system.log`, the print of the kernel, `manual` | none | Nothing. |
| `events` | 3 | the kernel: the event table | (a), the kernel keeps text | The process `kernel` and the text. |
| `block`, `ranges`, `hierarchy`, `log` | 3 each | the process of the same name | (c) redundant: the process | The process. The window `log` and the main test read the process `log`. |
| `iommu` | 3 | `iommu` and `iommu_device`, a pair of test modules | (c) | The two processes. |
| `paging` | 2 | the kernel | (c) redundant: the text says "kernel: paging:" | The process `kernel` and the text. |
| `entropy`, `date` | 2 each | the process of the same name | (c) | The process. |
| `boot` | 1 call, 7 lines | the kernel: the stages of the boot | (a), the kernel keeps text | The machine test waits for the lines on the serial port, as today. |
| `frame` | 1 | the frame service | (c) | The process. |
| `requests` | 1 | `server`: one access record for each request | (b) a stream of records disguised as text | The record `Access_Record` (`docs/glossary/network.md`, "Access record"). It is the first user of record outputs: the record output `requests` ([module_outputs.md](module_outputs.md), "The migration"). Until record outputs exist, `server` writes it as the log fact `server.Access_Record`, and its window keeps its last records. |

No other channel is a stream of records. The element places come near: the tool reads each one to press an element, and a lost line fails the test. But their reader is a test, which the log serves, and a loss fails the test with its cause: they stay log facts.

**The readers that filtered by channel, and what each one reads.** Each reads by process and by level now; the facts add their fact type and their fields.

- **The step `Record` of the machine test** (`tools/modustool/machine/machine.odin`): the process, the level and a text; once facts exist, a fact with its fields.
- **The window `log`**: it counts the records by process, named by its process slot and its process serial, and its line `log: ok, ...` says the count of the processes. A card for each process holds its count, on the two lines that the window keeps for them; the processes that they do not hold count in the last card, "others", so no card covers the heads of the columns. Once facts exist, it counts by fact type too, and gets a column `fact`.
- **The records of a call in the console** (`console/line_records.odin`): it groups by process, which a call already is; once facts exist, it shows each fact by its name.
- **The rows of `log.records`** and the row of `log_reader`: the field left, and the text has 168 bytes, as the record.
- **The example of [log_reader_scope.md](log_reader_scope.md)**: a reader chooses its rows by a field, `log.records(0) |> where(level = Warning)`, and by a fact type, `log.records(0) |> facts(storage.Bad_Block)`.
- **The tool, where it reads the head of a line**: the head is `[name]`. The waits of the scenarios with a channel head took the head of the process.
- **`server` and its access records**: one plain line at the level Info for each request, until the log fact `server.Access_Record`, then the record output `requests`.

### Filters of a reader: one form

The console filters log rows with its one command `where` on a column, and gets the columns of a fact type with `facts`. No name of a fact type, of a field or of a level is a free string:

```
> log.records(0) |> facts(storage.Bad_Block) |> where(block = 12)
> log.records(0) |> where(level = Warning) |> where(process = "storage")
```

- **The fact type is a typed name.** `storage.Bad_Block` is a name of the command line, as `server.requests` is ([module_outputs.md](module_outputs.md), "The console form"). The console completes it from the fact tables of the module files of its catalog: each pair of a package name and a record type that a fact table holds. It refuses, before the call, a name that no fact table holds, with the sentence of a name that names nothing and the close names that it has. `facts` keeps the rows of that fact type and gives a table: the columns of the head of a row (number, time, process, level), then the fields of `Bad_Block`. The console resolves the name to the pairs of a module hash and a fact key, and builds the description of the table from the record description.
- **Each field is checked.** Inside `where`, a name is a field of the record of the table, never a variable. The console checks each field against the description of the table that comes in: after `facts(storage.Bad_Block)` the fields are the head and `block`, `check`, `expected`. A name that is not a field, and a value of another kind than its field, are refused before the call, with the fields that the table has. Completion offers those fields.
- **The level is an enum.** The column `level` is a field of the contract enum `Log_Level`, with the kind of a status of a contract enum. The console completes its members, `Info`, `Debug`, `Warning` and `Error`, and refuses a word that names no member. It takes `=` and `!=` only: the order of the numbers of the members is not an order of weight (Debug is 1, Warning is 2), so `>=` on it has no meaning, and the console refuses it.
- **The process is a value.** `process = "storage"` compares the Text field of the name of a process. A process name is a value of the row, not a name that the console resolves: no process has an identity by its name ([log_reader_scope.md](log_reader_scope.md), "Refused forms").

So `where` stays a command of every table, and only `facts` knows the log. The operator `|>` and the comparison form of `where` are those of [module_outputs.md](module_outputs.md), "The console form". The comparison form came with the readers of the facts, and the old form `where(t, "block", 12)` left in the same change, for every table: the console keeps one form.

**How the console reads a condition.** The argument of `where` after the table is a condition: a field name, an operator (`=`, `!=`, `<`, `<=`, `>`, `>=`) and a value. The parser reads it as a condition, never as an expression, so a field name is not a variable. A Status field takes the name of a member of its contract enum, and the console turns it into its number at that one place; a word that names no member is refused with the members. An Integer field takes an Integer and each operator. A Text field takes a Text, and a Status field a member, with `=` and `!=` only. A Bytes field (a hash, the values of a fact) has no value that the console compares, and is refused. An unsigned field takes no negative value, and a field takes no value past its bytes; an unsigned field compares as unsigned, so `key > 0` keeps a key of 2^63. A text or a number after the operator of a status is refused: a member is a name. When the console knows the record of the table on the left before the run (a stage `facts(...)`, or the result of an export), it checks the condition before any call: the field, the operator, the member of a status, and the kind and the range of a value that is one literal; a value that is another expression is checked when it runs. Else the whole condition is checked when `where` runs, before it reads a row. The reading, the checks, the comparison of the values and the sentences are one private package with host tests, `console_condition`; the parser of the console reads only the value of a field that is no status.

**What `facts` does.** `facts(table, storage.Bad_Block)` takes a table of the rows of `log.records` (it checks the fields `number`, `time`, `process`, `level` and `form`). It finds each module of its catalog whose table `Facts` has a row of the package `storage` and the record `Bad_Block`. The description of the first one is the description of the table. It reads `log.fact_records` from the least number of the table, and keeps each row of the form `Fact` whose fact key and module hash are of one of those modules and whose description is equal. The rows of another description are left out. Each row of the result is the number, the time, the process and the level of the log row, then the values of the fact, in the order of its fields.

**The typed name.** The argument of `facts` after the table is a fact name, which the parser reads as a name with one dot, never as an expression. The console refuses, before any call, a name that no fact table of its catalog holds, with the fact names whose package is the same, or every fact name when none is. The completion offers the fact names inside `facts(`, and the fields of the record on the left inside `where(` when the console knows it.

### Which reader sees which fields

The log scope does not change. A reader receives whole records of its scope: the whole log for a caller that acts for the principal, else its own records and the records of a process whose handle it lends ([log_reader_scope.md](log_reader_scope.md)). A fact record holds no value that the text of that record did not hold: the writer chose each value, as it chose each byte of its text. The module hash names a module that the writer chose to name. A reader of a lent child learns the hash of a library that the child loaded only if the child writes it.

**A fact type is no border.** The pair of the module hash and the fact key is a claim of the writer, as the channel was: the kernel reads no field of the body, so any process can write any hash and any key. The process slot and the process serial, which the kernel sets, name the writer; the fact type names a description. So a grant "every record of the fact type `storage.Bad_Block`" is the grant "every record of the channel `devices`" again, which [log_reader_scope.md](log_reader_scope.md) refuses: it shows the reader each process that writes that type. That refusal holds for a fact type, by the same reason. A check by the kernel against the module records of the writer changes nothing: a module record is what the loader of the process asserts (`docs/glossary/code.md`, "Module record").

A reader that renders needs the module file in its catalog. The catalog is a grant of its own (`docs/glossary/code.md`, "Catalog"), and the template is in a file that the reader holds: rendering gives it nothing past its scope.

### The machine tests

- **A wait on the serial port keeps its text.** The tool renders a fact before it matches, and a fact template that writes the sentence of today keeps each wait as it is.
- **A wait for a fact.** The step `Fact` names the fact type as a text (`fact = "storage.Bad_Block"`), the process, and one condition on a field (`condition = "block = 12"`). The tool cannot name the record type of a module in its own code: it does not compile the module packages. So the name is a text that the check before the run reads, as the console reads its typed name. A step has one condition: a second condition is a second step, or the field `condition` grows into a list when a test needs it.
- **One reader of a condition.** The condition has the form of the condition of `where`, and the tool reads and checks it with the package of the console, `console_condition`: the field, the operator, the member of a status, the kind and the range of the value, with the same sentences. A second parser of the same form in the tool is the refused form: two readers would drift.
- **The step reads the raw line.** The render keeps, for each line of a fact that it rendered, its place in the rendered log, the name of its head and the bytes of the line (`build.Fact_Line_Place`). The step matches the process, the module hash and the key of the fact type in a module of the build, and the values against the condition, from the place of the last `Wait`. It reads no sentence, so two fact types with the same sentence are two facts for it. The serial port can lose a line in a flood, as for a `Wait`: the step reads what the serial port got. A test that must not lose the fact reads it through `log.fact_records`.
- **The check before the run.** The tool reads each step `Fact` of a scenario against the fact tables of the module files of the build before the machine of the scenario starts, beside the check of the key of `remote`, and stops with one line for each fault. A step with no process, a fact name that no module has, a field that its fact type lacks, an operator that the field does not take, and a value of another kind than its field fail there. A changed sentence of a `Wait` still fails at the end of a bound, in the machine. The check runs for each machine, not once for the whole test: the scenarios of some parts are built at the run (`measure_process_steps`), so no list holds every scenario before the run.
- **A step `Record` reads a fact by its sentence.** The step reads `log.records` through `remote`, and the row of a fact has no text. So when a row of its read has the form `Fact`, the tool reads `log.fact_records` from the same number and writes the sentence of each fact with the template of the module file of the build, with `module.fact_sentence_write`, as for a line of the serial port. A step `Record` on a line that became a fact passes unchanged, and keeps its place in the order of the whole log. The refused form: each such step turned into a step `Fact`, which reads the serial port and loses the check of the order of `log.records`.
- **The measures.** A measure that the tool reads from the log ([measure_history.md](measure_history.md)) keeps its sentence as its identity, because the template renders the same sentence. Once its writer writes a fact, the tool reads its numbers from the fields, with no parse of digits. No line that the root service converted is a measured line (the line of the budget of the root service at "the machine is usable" stays text), so the measure record reads text; the first writer of a measured line changes its measure in the same commit.
- **The value runs of the main test.** The check `log.value_runs({record})` of the record "log: the memory of the log" ([log_window_losses.md](log_window_losses.md)) becomes a check of the kinds of the fields of its fact.
- **A fact through the console.** The main test reads the fact of `log_reader` with `log.records({record}) |> facts(log_reader.Fact_Probe) |> where(value = 42)`, from the last record of the storm of `log_reader`: the rows of `log.records(0)` of a full log do not fit in the call region of the console. A field of a fact type with the name of a column of the head of `facts` (`number`, `time`, `process`, `level`) is refused by `facts`, so `Fact_Probe` names its third field `probe_number`.

### The facts of the root service

The root service is the first writer that converts: its lines of the processes, the connections, the grants and the devices are the lines that a reader groups. The fact types are in `src/modules/system/root/facts.odin`.

| Line | Fact types | Fields |
|---|---|---|
| A process stopped | `Process_Stopped` (the cause `Itself`), `Process_Stopped_Without_Outcome` (each other cause) | `stopped_process`; `cause` (`Stop_Cause`); `outcome` (`Stop_Outcome`) for a stop of itself |
| A process of the boot image started | `Process_Started`, `Process_Started_With_Terminal`, `Process_Started_In_Session`, `Process_Started_With_Terminal_In_Session` | `started_process`; `principal`, `principal_name` in a session |
| A device service started for a device | `Device_Service_Started`, `Device_Service_Started_Behind_Bridge` | `service`, `device`, `bus` |
| A disk process started | `Disk_Process_Started`, `Disk_Process_Started_With_Store`, `Disk_Process_Started_In_Session`, `Disk_Process_Started_With_Store_In_Session` | `started_process`, `hash`, `store`, `principal`, `principal_name` |
| A connection made or ended | `Connected`, `Connected_Acting`, `Connected_History`, `Disconnected` | `caller`, `service`, `principal`, `limit` |
| A grant revoked | `Grant_Revoked_Connections`, `Grant_Revoked_Endpoints`, `Grant_Revoked_Holdings` | `holder`, `grant`, and the count of what changed |
| A grant to debug given | `Debug_Right_Given` | `debugger`, `target`, `caller`, `principal` |

The rules that decided each line:

- **The template is the sentence of today, word for word.** So each wait of a machine test passes unchanged. A line whose sentence differs by a case (a terminal, the session of a named principal, a store, the outcome of a stop) is one fact type for each case, because a template has no condition. This costs a reader several fact types for one event: `facts(root.Process_Stopped)` gives the stops of a process by itself, and `facts(root.Process_Stopped_Without_Outcome)` the others.
- **The stop keeps its two facts apart.** `Process_Stopped` holds the cause, always `Itself`, beside the outcome, so `where(cause = Itself)` and `where(outcome = Done)` both read it, as [../api/process_stop.md](../api/process_stop.md) names them. The words of the sentence are the words of a reader (`itself, done`), not the names of the members.
- **The name of a grant is a Text field.** `Root_Grant` is an enum of a support package: a field of it is a plain Integer, which writes a number where the sentence writes a name (open question 4). The Text field `grant` holds the name that `root_grant_names` gives, and `where(grant = "store")` reads it.
- **A line stays text** when its sentence holds a part that no field kind writes as the line does: a refusal with a free sentence of its cause ("cannot start X: <the cause>", "refused X from the disk: <the cause>"), a status that the line writes as a number, which a status field writes by its name ("cannot start X: status 5"), and the head of a client key, which a Hash field writes whole ("connected remote to the service monitor, ..., for the client key <head>"). It stays text also when no reader groups it: the stop of `unlock` with no window, one step of the start; the lines of the trust, the TPM, the entropy, the principals, the start policy and the disk grant table, each written once or a few times in a run.

### The kernel and the boot path

The kernel and the boot program keep text records. The reason is not the store: the module file of the kernel is in the boot image, which a reader of the whole log holds. The reasons are two. The lines of the kernel are read on the serial port by a person at a fault of the start, with no tool: the boot stages, a stop on a fault, the report of a fault. And the kernel has no own-hash place and no `system` package: a writer of facts in the kernel is a kernel part of its own. The open question below keeps this choice open.

### The frequent tasks

Property 22 ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "22. General mechanisms, and a plain expression for each frequent task") asks each design for its frequent tasks and the expression of each.

| Task | Expression |
|---|---|
| Find the bad blocks of a disk | `log.records(0) \|> facts(storage.Bad_Block)` |
| Find one bad block | `log.records(0) \|> facts(storage.Bad_Block) \|> where(block = 12)` |
| Follow the warnings of one process, as they come | `log.follow \|> where(process = "storage") \|> where(level = Warning)` |
| Wait in a machine test for a fact with one field | the step `{kind = .Fact, process = "storage", fact = "storage.Bad_Block", condition = "block = 12"}`, which the tool checks against the fact tables before the machine starts |
| Keep the whole log of a child, for an audit | in the console, `start(server, wire(server.log, collector.sources))`; in a starter, the same row in the wiring list of its `Start`, then `system.input_read(&audit, deadline)` on its record input |
| Write a fact | `system.log_fact(.Warning, Bad_Block{block = number, check = found, expected = wanted})` |

**`log.follow`** is the one expression that this list adds to the log service: a record output of the service with the rows of the log scope of the connection, from the next record on, which the console reads as a Stream ([module_outputs.md](module_outputs.md), "The console form"). The kernel log stays lossy below it: when the kernel wrote over records before the service read them, the service writes a gap record with their count, so the follower sees the loss where it is.

**The check.** No expression names a record form, a fact key, a module hash, a byte offset or a number of a level. The fact type, its fields, the members of `Log_Level` and the process are names that the console or the tool completes and checks. The raw form `#<hash>:<key>` appears only for a record whose module file the reader does not have, and no task uses it. A filter on the form and the key in place of `facts` is the incantation that property 22 refuses.

## The migration

Each step is a commit on `master` that leaves a working system, with its tests.

1. **The channel leaves.** Built. The field, the two words of `Log`, `system.log_in` (in its place `system.log` with a level), the head `[name:channel]` of the serial line, the step `Record` without a channel, the window `log` and the console by process, the rows of `log.records`. The glossary removes "Channel" and changes "Log record"; [log_reader_scope.md](log_reader_scope.md) changes its example and its purpose. The text of a record grows to 168 bytes.
2. **The record descriptions take the kinds of the log.** Built. The hexadecimal Integer, the status of a contract enum, the module name as a Text field and the hash as bytes, in the module format, the tool, the console and [console_value_colors.md](console_value_colors.md). No log change: the exports gain the kinds. The format version stays: the kind takes bytes that were reserved and zero, and zero keeps its meaning.
3. **The attribute in the build.** Built. Each command of the tool that compiles a package of `src/` passes `-custom-attribute:log_fact` (`foundation.LOG_FACT_ATTRIBUTE_FLAG`): the build of a module, of the kernel and of the boot program, the host tests, the compile and the check of the tool, and the compile of the tool in the flake. A host test of the tool declares one fact type and compares `typeid_of` of that type with the key that the tool computes (`build.fact_key`). No module declares a fact type yet.
4. **The fact table and the own-hash place.** Built. The table `Facts`, the extraction of each fact type and its checks, the check of each key in the IR, the own-hash place that each loader writes, the version 3 of the module format. A host test of the tool proves each refusal of the build.
5. **The fact record and the first writer.** Built. The form byte, `Log` of the form `Fact` with its refusals, the serial line of a fact, the render of the tool, `system.log_fact`, and one writer: `log_reader`, whose machine test waits for the sentence that the tool writes from the fields of its fact. It reads its three facts back through `log.fact_records`, from its own log ring, and checks what the kernel wrote: the form, `more`, the key, the count of the value bytes, the reserved bytes that it zeroed, and the hash of its module in the fact of `system.log_fact`.
6. **The readers.** Built. The rows of `log.records` with the level and the record form as statuses, the values whole in `log.fact_records` with the field kind `Fact_Values`, the one render `module.fact_sentence_write` that the console, the window `log` and the tool call, the raw form, the grant `image` of the window `log`, `facts` in the console with its typed name, the comparison form of `where` in place of the old form with its checked fields and the enum of the level, and the completion of the fact names and of the fields.
7. **The machine tests read facts.** Built. The step `Fact` with its condition, read by `console_condition`; the check of its steps before the machine starts, with the check of the key of `remote`; the places and the fields of the rendered lines of facts; a step `Fact` in each run of `log_reader`; the fact of `log_reader` read through `facts()` in the console. The measures from fields wait for the first measured line that a writer writes as a fact (step 8).
8. **The writers, one module group at a time.** The root service (`processes`, `calls`, `devices`): built, see "The facts of the root service", with the contract enums `Stop_Cause` and `Stop_Outcome`, the words of a member in a sentence, the step `Record` that reads a fact, and steps `Fact` on five fact types of the root service. Then the compositor and `interface` (`surfaces`, the element places), the storage service (`storage`, `disk`), the device services, then the rest. Each step converts a whole module, so that a reader of that module reads one form. The text of each template is the sentence of today, so each wait of the tests passes unchanged. A measured line that becomes a fact gets its numbers from its fields in the same commit.
9. **The measures decide, then the rest stays text.** After the root service, the measures below run. A line that no reader groups or filters stays `system.log`.
10. **The record output `log` and `log.follow`.** After the steps of the mechanism of [module_outputs.md](module_outputs.md): the contract record `Log_Output_Record`, `log` in the wiring list of `Start` with the refusal of a second row, the handle slot of the context beside the log handle, the write in `system.log` and `system.log_fact` when the slot holds an end, and `log.follow` with its gap records. It is step 7 of [module_outputs.md](module_outputs.md), built once. The tests: a second row for `log` is refused with nothing changed; a child whose `log` is not wired has 0 in its slot; a starter wires `log` of a child whose reader is slow, and receives each record of a burst that the kernel log loses in part.

## The forms refused

- **Keep the formatting in the writer.** The writer pays the formatting at each call, the code of each call site holds it inlined, the record holds a text that a reader cannot filter by field, and a test compares sentences that a change of words breaks.
- **A format string interned by its address.** An address is not an identity: it changes with the base of each load and with each build. A library module cannot hold it in a read-only segment. And a reader needs the memory of the writer, or a table of addresses in the module, to find the string.
- **JSON, or text of `key=value` pairs.** It is text between processes, which property 19 refuses: each reader needs a parser, and the writer still formats. The names repeat in each record, so a line takes more records and more of the budget of each second, and no tool checks a name before the run.
- **The runtime type information of the language as the description.** Its tables describe the types of Odin, which ties a contract to one language (property 19), and they hold addresses that the loader rebases. Nothing checks a template against the fields at the build. The fact key uses the typeid only, an immediate in the code, which the contract defines as bytes.
- **An index of the fact type that the tool assigns.** The code needs the identity at its compile, and the tool reads the module after it. An index needs a generated source before the compile, or a value written into the code after the link. See "The fact key: why the typeid", (b).
- **The template as a string at the call or in a constant beside the type.** Two calls of one fact type repeat a string at the call, and a typo makes a second fact type. A constant beside the type, `#hash` of the template, is a second declaration that names the type by nothing. The attribute is on the type.
- **The name of the fact type in the record.** It is not an identity (two modules have a `Bad_Block`), it takes bytes of the values, and a typo makes a new name.
- **The module hash set by the kernel.** The kernel does not know which code of the process called `Log`, and a module record is what the loader asserts: the kernel then reads the module records at each `Log`, and gains no trust.
- **The kernel renders the template.** It is a text formatter and a reader of module files in the kernel.
- **The log service renders the records to text.** The service then needs the catalog of each writer, and the reader loses the fields that it filters on.
- **A grant to read a fact type of every process.** The reason is in "Which reader sees which fields".
- **A free grouping name kept for `system.log` (a log topic).** It is the channel again under another word: a typo makes a new stream, any process writes any name. A line that a reader groups is worth a fact type.
- **The kernel log as a data path.** The kernel log is never a data path: a record there is lost when a ring evicts, when a budget refuses, when the serial port drops it, and its order with the work is not promised. Its reader needs the log scope, not a handle with a right. The work of a module goes through its record outputs ([module_outputs.md](module_outputs.md)). The one reliable way to keep the log of a process is its record output `log`, wired in the wiring list of its start.
- **A reader that takes the kernel log as the data of its work.** The same reasons. A test that reads a fact checks the work. A process whose work needs the records of another process reads them through a record input that a wiring gives it; an audit reads the record output `log`.
- **The kernel writes the record output `log`.** The kernel is off the data path (property 5), and a write to a ring of another process from the kernel waits on a reader in the kernel. The library of the writer writes it, as each record output.
- **A wiring of `log` while the process runs.** The audit needs the first record, and a wiring after the start gives a joined record of N in its place. A reader that wants the records of now reads `log.follow`.
- **The authority of a process handle with Control.** A process handle goes to other processes with Give, so it names a holder, not the one who asked for the start. The check that the asker asked for the start of the process is the rule of `Stop`, which the root service already keeps.
- **Several readers of `log`.** The writer then copies each record to each reader and waits for the slowest one, for a log that most readers read only to forward. One wiring; a second reader reads from the first one.
- **The end of `log` through a wiring ring.** Every process then pays a wiring ring and its pages for a wiring that most never get. The end comes in one handle slot of the context.
- **A wired `log` that drops a record when its reader is slow.** It is then the kernel log again, with one more copy. An audit that loses records is no audit.
- **A version number in each fact record.** The module hash pins the description already.
- **A fact of more than one record.** A reader then joins records again, and a lost record in the middle leaves half a fact. 144 bytes of values hold every line of today.

## Subtle points

- **The template is a literal of the attribute.** The tool reads it from the syntax tree and refuses another form, so the template cannot come from a constant or a concatenation. The compiler ignores the attribute, so no template byte reaches the code.
- **The key names the type, not its fields.** A fact type whose fields change keeps its key, and its module hash names the new description. A reader that holds an older module file for that hash does not exist: the hash is the file.
- **A type declared inside a procedure, or private to its file,** has another canonical name (the procedure or the file enters it). The tool refuses the attribute there, so the key is always `<package name>::<type name>`.
- **A collision of fact keys** inside one module fails the build. Two modules can have the same key, as two modules that compile one package do: a key is read with its module hash.
- **The value at the call is a composite literal.** The tool reads the named type there to find the attribute. A value from a variable has a type that the tool cannot read with no type checker, so the tool refuses it, and the writer names the literal at the call.
- **The rendered sentence is not the record.** Two fact types can render the same text. A test that waits on text matches both; a test that waits for a fact matches one.
- **A support package and the module hash.** A fact type of `interface` is written with the hash of the module that compiled `interface` in: the record names the description in that file. The fact name is the same in each module, so a filter by name finds every window.
- **A fact name in two modules with two descriptions.** A new version of a module can change the fields of a fact type that keeps its name. `facts` takes the description of the first matching module of its catalog and leaves out each row whose description is not equal. A sentence that says how many it left out is still to build: a result of the console has no place for a note yet.
- **A replacement module** writes its own hash: its facts render with its own template.
- **A Text field from a writer** is UTF-8 that nobody checked. The kernel no longer filters it, so the reader checks it at its border, with the rule of [text_encoding.md](../data/text_encoding.md).
- **The serial line is shorter only when the values are small.** The hexadecimal doubles each value byte. The cut at the last byte that is not zero removes the zeros of a Text field. The measures decide if this form stays.
- **The own-hash place of a disk process** is written by the root service, which loads it from the store `module_files`; the loader of a library writes the place of that library in each process that loads it.
- **The value bytes are a copy of the record of the source.** The compiler and the tool refuse padding, so the bytes are the fields only. A record of the source and its description agree because the tool computes the offsets from the source and compares them with the compiled layout, as for an export record.

## The measures that decide it

Each measure is printed, never asserted ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The bounds of the tests"). Each one runs on the test machine under KVM, with the same line written both ways.

Two of them print now, after each machine: measure 4, the serial bytes of the lines of the facts as values in hexadecimal and as the text of the same lines (the rendered line is the text line, because a template writes the sentence of today), and measure 7, the time of the render of the tool. Measure 3 and measure 5 compare a build before the conversion of the root service with the build after it: the record count up to "kernel: ok" and the size of the module file of `root`, read from the two runs. Measures 1, 2, 6 and 8 need a process or a reader that times them, which is not built.

1. **The write cost.** `system.log` against `system.log_fact` for the same line, in cycles from the call to the return, the least and the median of 1 000 calls: the line of `Bad_Block`, and the line "root: connected <module> to the service <module>, for principal <n>". It must show the share of the kernel entry, and the gain of the fact in the process. A fact that costs more than the text stops the conversion of the writers until its cause is known.
2. **The kernel time of `Log`.** The duration of the operation for each form, from the kernel event of each operation. It must show that the copy of a fact costs no more than the filter of the same text.
3. **The record count.** The records that the main machine test writes up to "kernel: ok" and to the end of the start of the desktop, before and after the conversion of the root service. It must show that no line takes more records, so the budget of each second holds the same lines.
4. **The serial bytes.** The bytes of the serial lines of the same records, both forms. Under KVM a byte costs about 22 µs ([log_side_channels.md](log_side_channels.md)), so more bytes mean more lost lines in a flood. If the fact form writes more bytes for the start of the desktop, the serial form changes before step 8.
5. **The code bytes.** The size of the code of the root service and of the compositor before and after their conversion. It must show the formatting that the call sites no longer inline, and whether a fact type adds bytes of type information to a module file through `typeid_of`.
6. **The reader cost.** The time to render the 2046 records of a whole log in the console and in the window `log`, the least and the median, with a cache of the last modules found. It must show that the window renders its 30 rows in less than one frame of 8.3 ms. If the whole log does not fit, a reader renders only the rows that it shows.
7. **The render of the tool.** The time of the tool to render the serial log of the main machine test on the host. It must show that a machine test waits no longer for a line.
8. **A smaller record.** The records of the main machine test sorted by the bytes that they use: the head, the text or the values. It shows how many fit in 64 and in 128 bytes, and what a record of each size gives: the records that the whole log of 128 pages keeps (2047 today), the records that a line of today takes, and the cost of a copy in `Log` and in `Log_Read`. A smaller record changes the head too, which holds 64 bytes today with the name of the process. The size stays 256 until this measure shows a gain that pays for the change of each reader.

## Open questions

1. **The term.** The proposal says "event". The system has `system.Event` (a count that threads wait on), the kernel event, the event record, the event table, the event rule, the event ring and the event word. A "log event" is one more meaning of the word beside them, and an "event table" of the module file is a second event table. Recommendation: "log fact", as this file writes it, and `system.log_fact`.
2. **No grouping name for `system.log`.** Recommendation: none, as above. The other way is a "log topic" that the writer types; it keeps the fault of the channel.
3. **Facts of the kernel.** Recommendation: the kernel keeps text, for the reasons above, until a reader needs to filter the lines of the kernel by field (a stop on a fault by its address). Then a kernel part writes the facts of the kernel, with the hash of the kernel from the boot record.
4. **The fields of an enum of a module.** A status of a contract enum gets its name, because each reader compiles the contract in. An enum of the module itself (a state of a key) has no description of its members in the module file. Recommendation: an Integer field until a fact needs the names; then a table of enum descriptions, which an export also uses.
5. **The serial form.** Recommendation: hexadecimal with the cut of the last zeros, until measure 4 says that it writes more bytes than the text. The other way is base64, a third shorter, with a decoder in the tool.
6. **The access records of `server`.** Recommendation: a log fact until record outputs exist, then the log fact leaves in the commit that gives them to the record output `requests`, as [module_outputs.md](module_outputs.md) plans: a record has one place.
7. **The level of a fact.** Recommendation: at the call, as the proposal says, because one fact can be a warning in one case and debugging detail in another. The other way is a level in the fact table: one fewer argument, and one meaning for each fact type. The root service gives a case: the stop of a process is a fact of the level Info when it is clean (an outcome `Done` or `Stopped_On_Request`, or a holder) and Warning else, for the same fact type.

## State

Built: the first seven steps of the migration, and step 8 for the root service. The root service writes its starts, its stops, its connections, its revocations, the grant to debug and the start of each device service as log facts, with templates that write the sentences of before; a stop has its stop cause and its stop outcome as statuses of two new contract enums, written in a sentence with the words of a reader. A step `Record` reads a fact by the sentence that the tool writes from `log.fact_records`. The main test waits for five fact types of the root service by a field, and reads the stop of `log_reader` through `facts(root.Process_Stopped)` in the console. The tool prints the serial bytes of the facts in both forms. The channel left the record, `Log`, `system.log_in`, the serial line and each reader; `system.log` takes a level; the text of a record has 168 bytes. A record description takes the four kinds of the log. Each compile of a package of `src/` accepts the attribute `log_fact`, and the tool computes the fact key that the compiler gives as the typeid. The module format has the tables `Facts` and `Own_Hash` (version 3); the tool extracts each fact type that a call names, refuses each form above, and finds each key in the IR; each loader writes the own-hash place. A log record has its record form; `Log` takes the form `Fact` and refuses each wrong fact with its error record; the serial port gets the raw line of a fact, and the tool renders it for the steps of a machine test. `system.log_fact` writes a fact, and `log_reader` is its one writer. `log.fact_records` gives the bytes of each fact of a log scope, its values whole. The console and the window `log` write the sentence of each fact with `module.fact_sentence_write`, each value in the color of its kind, and the raw form when their catalog has no module of the hash; the tool calls the same procedure. `facts(table, storage.Bad_Block)` gives the fields of a fact type as columns, and `where` takes a condition on a field, checked against the record, with the level as a member of `Log_Level`. A step `Fact` of a machine test waits for a fact by its fact type, its process and a condition on a field, which the tool checks against the fact tables of the build before the machine starts; the main test waits so for the fact of `log_reader`, and reads it through `facts()` in the console.

Left: the facts of a disk process, which show raw until a reader reaches the store `module_files`; the sentence of `facts` that says how many rows of another description it left out; the column `fact` and the counts by fact type of the window `log`; `columns`, `sort` and `join` with field names in place of a text of names ([module_outputs.md](module_outputs.md), "The console form"); the step `Fact` that remembers a field for a later step; a refusal at the build of a field of a fact type with the name of a column of the head of `facts`, which `facts` refuses today at the run; a copy of the machine log with the rendered lines; the writers of the other modules, and the measures from the fields of their facts; the measures of this design but measure 4 and measure 7, and the decision of step 9; the record output `log`. No measure of the write cost or of the render of a reader of the system exists yet.
