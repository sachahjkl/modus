# Developer tools

The developer tools show memory and execution.

A developer tool (`glossary/network.md`) shows how the system runs. It reads reports of the kernel with a grant, and it changes nothing. Property 20 sets the limit: a tool inspects a process only with a handle that has the right to inspect.

## About this guide

**The idea in plain words.** In current systems a debugger or a task manager sees every process of the same user because it runs. Here a tool sees only what a grant lets it read: the kernel gives reports (counts, mappings, threads, modules) to a holder of the machine handle with the right **Inspect**, and gives no byte of the memory of another process. So each tool is a normal process, and its access is visible and revocable like any other.

**For whom.** A reader who wants to see how the system runs, and a reader who writes a tool, a source comment or a test of the system.

**Read before.** `PROPERTIES.md`, "20. No ambient access: the other holes to close" (line 2: debug access is a handle to one process). The terms developer tool, sample, folded gap, near export and confirmed place are in `glossary/network.md`.

**The map of this guide.**

| Section | What it says |
|---|---|
| "What each tool reads" | Each tool, its grant, and the reports that it reads |
| "The window of `monitor`" | The graphs of the last minute and the colors of the bars |
| "The log" | The log of the kernel: its records, their processes and levels, and who reads them |
| "The process `inspect`" | The window that shows one process live |
| "Names and lines" | How an address becomes a procedure and a source line |
| "The debugger", "The debugger: the design" | The debugger service: who can debug which process, its exports, the commands of the console, debugging from another machine; then the reasons of its form and what the kernel gives it |
| "What `inspect` does not read: the bytes of another process", "The cost" | The limit of the grant, and the price of a sample |
| "The comments of the sources", "The form of a documented comment" | The rules that the tool checks on every comment, and the form of a comment that the site and the console show |
| "The commands of the tool" | The commands of `modustool`, the parts of the machine test that `modustool test` runs alone, the times of a test, the incremental build, and how the tool sends input and waits |
| "The bounds of the tests" | How a test waits, and why no test asserts a speed |

![The process inspect: the address space of the console as a band scaled by pages, its mappings, its modules and its threads](screenshots/inspect.png)

## What each tool reads

Each developer tool is a process of the boot image. The root service gives it its grants when it starts, and the kernel answers its operation `Inspect` with one report at a time. The table names, for each tool, the handle and the rights that it holds, and the reports that it reads.

A tool with no grant to inspect the machine reads nothing. It says so in its window and in the log: the monitor writes "no grant to inspect the machine".

| Tool | Grant | Reports |
|---|---|---|
| `monitor` | machine, Inspect | `System_Report`, `Process_Report` of each slot. It serves `processes()`, `counts()`, `count()`, `counts_named()` and `served()` |
| `pages` | machine, Inspect | `Mapping_Report` of its own page table and of the kernel half |
| `processors` | machine, Inspect | `Processor_Report` of each processor |
| `locks` | machine, Inspect | `System_Report.locks` |
| `scheduler` | machine, Inspect and Schedule | `Processor_Report`, `System_Report.strategy`, `Thread_Table_Report` (the machine number of its own threads; for the share policy, the threads of each process), `Process_Report` (the run time of each process) |
| `manual` | machine, Inspect; boot image; replacement table | the flat tables of the modules, `Module_Report` of each slot |
| `log` | the log records, Read | `op.Log_Record`. It serves `records(after)` and `value_runs(after)`, to each caller in its log scope, and `process_records(process, after)` and `process_value_runs(process, after)`, the records of a process whose handle the caller lends ("Who reads which records") |
| `debugger` | machine, Inspect; boot image; debug image; the commands `Debug`, `Debug_Store` and `Debug_Start` of the root ring | `Process_Report`, `Module_Report` and `Thread_Table_Report` of the process that it debugs; the registers and the memory of that process through its handle with `Debug` ("The debugger"). It serves the exports of the debugger |
| `inspect` | machine, Inspect; boot image; debug image | `Process_Report`, `Module_Report`, and the four reports below, of the process that the principal chooses. It serves `mappings()`, `threads()` and `modules()` |

## The window of `monitor`

![The window of monitor in the light appearance: three metric cards for the memory, the processor and the kernel, three graph cards of the last minute, and the table of the processes](screenshots/monitor_light.png)

The monitor takes one sample each 500 ms and draws its window after each sample. From the top:

1. Three metric cards, each with one large number and a gauge:
   - **Memory**: the share of the memory in use, the MiB in use of all the MiB, and the reserved memory.
   - **Processor**: the processor time of all the processes in the last sample, the processes, and the processors.
   - **Kernel**: the kernel entries and the interrupts since the start of the machine, and the waits of the locks of the kernel of all their takes, with the kind that waited most when it fits. The gauge is the share of the takes that waited.
2. Three graph cards of the last minute: the last 120 samples, the newest at the right edge. The header of each card gives its scale, its value now and its peak of the minute.
3. The table of the processes: one row for each process, with its name, its resident pages, and its share of the processor in the last 500 ms, as a bar and in percent. The rows that do not fit are counted on the last line; `monitor.processes()` gives them all.

| Graph | What one sample shows | Color | Scale |
|---|---|---|---|
| memory in use | The pages in use | Memory | From 0 to all the memory, in MiB |
| processor time | The processor time of all the processes since the sample before, over that time on every processor | Process | From 0 to 100 % |
| kernel entries | The kernel entries since the sample before, for one second | Kernel | From 0 to the largest value of the minute, rounded up to 1, 2 or 5 times a power of ten; 10 000 and more with k, M, G, T, P or E |

- Each graph is a recess in its card, with a line at each quarter of its height.
- The first sample has no sample before it: its processor time and its rate are the means since the start of the machine.
- A step of the graph is one sample, not a time: a call that the monitor runs between two samples can make one step longer than 500 ms.

**The colors of the bars.** Each gauge and each bar takes the color of its intensity step (`DESIGN.md`, "The intensity of a gauge"): the color of what it measures under 60 %, the warning color from 60 %, and the color of a measure near its limit from 85 %. The number beside the bar gives the same fact.

The design: `src/md/features/monitor_window.md`.

## The log

The log is the list of the lines that the kernel and the processes write as they run. The kernel keeps the newest records in memory and prints each one on the serial port. A record knows which of its bytes are values, so a window can color a size or a time without guessing from the text.

A log record (`glossary/running_code.md`) keeps its text and the value runs of the text: which bytes are a number, a size, a time, a module, a version or a status. The text is the text that the serial port prints, byte for byte: the machine tests wait for texts of the serial port, and a reader that ignores the runs reads the same record.

On the serial port, each line of a process starts with the name of the process in brackets; a line of the kernel has no head. A record carries no name that its writer chooses to group it: a reader chooses records by process and by level. Two lines of the console, from the machine test:

```
[console] error: the instruction is at peek + 0x4 in probe (src/modules/tests/probe/probe.odin:18)
[console] error: frame 0: peek + 0x4 in probe (src/modules/tests/probe/probe.odin:18), the instruction
```

### The writer states the kind

A line of the log is made of parts, after its level: `system.log(.Warning, "storage: the block ", block, " has a wrong check")`, and `log` and `log_with_level` in the kernel. A text is plain. Each other part is a value with a value kind (`src/library/modus/contract/value_kinds`):

| Part | Writes | Value kind |
|---|---|---|
| `u64`, `i64`, `Hex` | the number, in decimal or in 16 hexadecimal digits | Number |
| `Size{value, unit}` | the number, a space and the unit: `bytes`, `KiB`, `MiB`, `pages`, `blocks` | Size |
| `Duration{value, unit}` | the number, a space and the unit: `ns`, `us`, `ms`, `s` | Time |
| `Hash{bytes}` | two hexadecimal digits for each byte: the head of a hash is its first 8 bytes | Version |
| `Module_Name{name}` | the name of a process or of a module | Module |
| a status of the kernel (`system.Status`) | its number | Status |

No text is classified by its look. A value that a writer gives as a text stays plain. The reason: a guess from the look is wrong for a name that holds digits, and only the writer knows that `4096` is a size and not a count.

### The record and its value runs

A log record has 168 bytes of text and at most 8 value runs (`op.LOG_RUN_CAPACITY`): 3 bytes each, a start, a length and the kind. The operation `Log` takes the runs of its text in its fifth value, a count of at most 32 (`op.LOG_CALL_RUN_LIMIT`); the runs (6 bytes each, `Value_Run_In_Call`) follow the text at its address. The kernel copies them once and checks them in its copy: each run inside the text, after the run before it, with at least one byte and a kind. One run that fails: the record has no runs, and its text is whole. The kernel cuts the runs at the bounds of the records: a run across two records is one run in each. A text with more values than runs keeps the runs of its first values; the rest of its text is plain.

A run that fails its check costs the record its colors, never its text: the text is the fact, and the runs only describe it.

### The cost of the value runs

On the path of `log` in the kernel: one store of 6 bytes for each value, and at most 12 runs on the stack (72 bytes, `KERNEL_LOG_RUN_LIMIT` in `src/modulus/serial.odin`). In `log_record`, under the log lock: one pass over the runs for each record, at most 32 steps. No allocation. The serial port gets the same bytes as a record with no runs.

### Log facts

A log fact (`glossary/running_code.md`) is a record of the values of one record type of the source, with no text. The record type has the attribute `log_fact`, whose literal is its fact template; the call names a composite literal of it:

```odin
@(log_fact = "storage: the block {block} has a wrong check {check}, expected {expected}")
Bad_Block :: struct {
	block:    u64,
	check:    value_kinds.Hexadecimal_32,
	expected: value_kinds.Hexadecimal_32,
}

system.log_fact(.Warning, Bad_Block{block = number, check = found, expected = wanted})
```

`system.log_fact` copies the hash of its module from the own-hash place, the fact key (the typeid of the type), and the bytes of the value, and gives them to `Log` in one record of the form `Fact` (`docs/ARCHITECTURE.md`, "The forms of a log record"). It formats nothing. A fact counts one record of the log limit, and the limit drops and counts it as a line of `system.log`. The compiler refuses a record type with padding, and one of more than 144 bytes (`op.LOG_FACT_VALUE_CAPACITY`).

A fact type can have no field: `Usable :: struct {}`, a record of 0 bytes whose sentence is its template, for a line with no value. A fact type can be a distinct type of a record type of its package or of the library, which several modules share, and the call can write it by a conversion of one value. The shape of an error record is so:

```odin
@(log_fact = "storage: the block service refused a request: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Block_Request_Refused :: distinct errors.Error_Record_Fact_Fields

system.log_fact(.Warning, Block_Request_Refused(errors.error_record_fact_fields(record)))
```

The kinds of a field write the forms of the lines of before: 16 hexadecimal digits with no `0x` (`value_kinds.Hexadecimal_Sixteen_Digits`, as `system.Hex`), the head of a hash, `1a2b3c4d…`, from a whole hash (`value_kinds.Hash_Head_Field`), a hash of 16 bytes (`value_kinds.Hash_Sixteen_Bytes_Field`), hundredths, `1.05` (`value_kinds.Hundredths`), nanoseconds as microseconds with one decimal, `812.4 us` (`value_kinds.Nanoseconds_As_Microseconds`), and a status of a contract enum by the name of its member (`operation.Status`, `errors.Kind`, `errors.Unit`), or of its word type of 8 bytes (`operation.Status_Word`, `errors.Kind_Word`, `errors.Unit_Word`), which leaves no padding beside a field of 8 bytes. A status that a line wrote as a number is the name of its member in its fact. Tenths (`value_kinds.Tenths`, `12.3`), an address with no leading zero (`value_kinds.Hexadecimal_No_Leading_Zero`, `0x1a2b`) and a time of day (`value_kinds.Time_Of_Day`, `07:04`) are kinds too, and each contract enum but `Log_Level` has a word type of 8 bytes (`operation.Stop_Cause_Word`, `block.Status_Word`).

A text of no small bound is a text view (`value_kinds.Text_View`): the views are the last fields of the type, and the call gives one string for each, in their order. A text of at most 12 bytes is whole in its 16 bytes; a longer one goes in the out-of-line area of the fact, of at most 1024 bytes, which the records after the first carry. A text that the area has no room for is cut, with the cut mark:

```odin
@(log_fact = "module_files: served {path} with the status {status}")
Request_Served :: struct {
	status: u64,
	path:   value_kinds.Text_View,
}

system.log_fact(.Info, Request_Served{status = status}, path)
```

A fact of more value bytes than one record is several records in a row, at most 9, and one line on the serial port: the first record writes `*` and the digit of the count of the records after the key tag, `#1a2b3c4d:fa0adf*2 0ch23`, and each next record `/` and its values, `/0d`. A reader that cannot join the records of a fact (a record lost in the middle, a part with no first) shows each of them raw after "(a fact whose records are not whole) ". The load error of each stage is a fact of its own shape (`module.Load_Find_Fields` and the others), which a module declares as a distinct type.

The serial port gets the raw line of a fact: `[storage] #1a2b3c4d:fa0adf 0cm1a23h1a2b`. After `#` comes the module tag, the first 4 bytes of the module hash; after `:` the key tag, the first 3 bytes of the fact key; then the value bytes up to their last byte that is not zero. A value byte that is not zero is two hexadecimal digits. A run of zero bytes is one letter, from `g` for 1 byte to `z` for 20, and a longer run is `z` until the rest fits one letter: `m` above is the 7 zero bytes of the block 12 in a field of 8 bytes. The tool writes the sentence of each such line before a step of a machine test reads the log: it finds the module file of the build by its module tag, the row by its key tag, and writes the template with each value by the kind of its field: `[storage] storage: the block 12 has a wrong check 0x0000231a, expected 0x00002b1a`. A line whose module, key or description the tool does not find stays raw. The tool writes the sentence with the one render of the contract, `module.fact_sentence_write`, which the console and the window of the log call too: an Integer in decimal with the unit of a size or a time, a hexadecimal Integer with `0x` and two digits for each byte, a status by the words of its member in a sentence (`module.contract_enum_member_words`: the name of the member, and for a `Stop_Cause` and a `Stop_Outcome` the words that a line of a stop wrote before the facts, `itself`, `a holder`, `done`), a Text up to its first zero byte, a hash in hexadecimal. A Text value is bytes of the writer that the kernel did not filter: the render writes "?" for each byte of an invalid sequence in it, a control character included, as the kernel does for a text. The file of the machine log keeps the raw lines. `modustool run` writes the sentences on the terminal too, line by line as they come. The machine keeps the rendered log, and each read renders only the lines after it; after the machine, one line gives the measure: "modustool: measure: the tool wrote the sentences of <count> lines of log facts of <log> in <time> us, over <count> reads of the log, ...", and a second line gives the serial bytes of the two forms of the same lines: "modustool: measure: the serial lines of <count> log facts of <log> took <bytes> bytes as facts; the same lines as text take <bytes> bytes". After the main machine, the tool also prints the measures of its log, and writes them to `build/log_measures.txt` ("The measures of the log facts"). A fact template writes the sentence of the text line that the fact replaced, so the rendered line is the text line. The readers of the system write the same sentence: the window of the log ("The window of the log") and the records of a line of the console (`docs/CONSOLE.md`, "The log records of a line"), each from the module file that the fact names in the boot image, each value in the color of its kind. A fact whose module the boot image does not hold, the module of a disk process among them, shows its raw form, the line of the serial port. The row of a fact in `log.records` has an empty text, and `log.fact_records` gives its values ("The tables of the log service"); in the console, `facts(table, storage.Bad_Block)` gives the fields of a fact type as columns (`docs/CONSOLE.md`, "Log facts as a table").

### The log facts of the build

The tool reads each call of `system.log_fact` in the sources that the compiler read for a module, and writes the table `Facts` of the module file with the template, the record description and the package of each fact type (`docs/MODULE_CONTRACT.md`, "The log facts and the own-hash place"). It has no type checker, so it refuses, with a message that names the source and the line:

- a call whose value is not a composite literal of a named type nor a conversion of one value to one, and a call with other than two arguments;
- a named type with no attribute `log_fact`, and a type that its package does not declare at the package scope;
- the attribute on a declaration that is not a record type or a distinct type of a record type that the tool reads, on a declaration inside a procedure or a `when`, or on a type private to its file: the key is the typeid of `<package>::<type>`, and those declarations have another canonical name;
- a template that is not a literal of text, or that breaks a rule of its language: a field that it does not name, a name of no field, a field named two times, a brace that is not closed or that closes nothing (`{{` and `}}` write a brace), a format in the braces, more than 512 bytes, a byte that is not text;
- a fact type of `errors.Error_Record_Fact_Fields` whose template does not end with `errors.ERROR_RECORD_FACT_TEMPLATE_END`, so each fact of an error record reads the same;
- a record of an export, of a result or of a table with no field: only a log fact has none;
- a field after a text view, and a call that gives another count of texts than the fact type has views, a named text or a spread of texts;
- a record with padding, a Handle field, or more than 144 bytes of values;
- two fact types of one module with one key or with one key tag (the first 3 bytes of the key: the serial line of a fact names its key by them), a key of 0, and a record of a fact whose name the module describes another way;
- a fact key of a fact type of the package of the module itself that the LLVM IR of the module does not hold as an immediate of 64 bits, after the compile: the compiler then gives the typeid another value;
- two module files of the build whose hashes start with the same module tag, the first 4 bytes: the line of a fact names its module by them.

The table `Facts` holds the fact types whose key the LLVM IR holds: the calls that the code of the module reaches. A fact type of a support package whose call the code does not reach gets no row, and no refusal: the module `drawing` compiles the package `interface` and writes no element line. The compile step writes the keys that it found in `reached_facts.list`, in the build folder of the module, and the conversion reads that list, so a kept compile step keeps its fact types.

`modustool test descriptions` compares the table `Facts` of each module with its sources, and prints one line for each fact type: "the log fact log_reader.Fact_Probe of log_reader, key <key>, comes from its source". The host tests of `tools/modustool/build` (`facts_test.odin`, `fact_kinds_test.odin`) give each refused form and check the refusal.

Each reader of a log file of the tool reads the rendered lines: the steps of a scenario, the checks after a run, the measure record, `quality_lines_check` and the fuzzer of the kernel operations. So a line that becomes a fact keeps each reader of its sentence.

### The step of a log fact

A step `Fact` of a scenario waits for a log fact by its fact type, its process and a condition on one field, not by its sentence:

```odin
{kind = .Fact, process = "log_reader", fact = "log_reader.Fact_Probe", condition = "value = 42"},
```

- **The fact type** is the package name and the record name, as the writer declares it, and as the console names it in `facts(...)`.
- **The condition** has the form of the condition of `where` in the console (`docs/CONSOLE.md`, "Conditions"): a field, an operator (`=`, `!=`, `<`, `<=`, `>`, `>=`) and a value. The value is an Integer (`42`, `-1`, `0x4c4f4746`), a Text in quotes, or the name of a member for a status. The console and the tool read and check it with one package, `console_condition`, so a condition has one set of refusals and one sentence for each. An empty condition takes any values.
- **What matches.** The tool reads the raw line of each fact that it renders, and keeps its place in the rendered log, the process of its head and its value bytes. The step passes at the first line after the place of the last `Wait` whose process is the process of the step, whose module hash and fact key are those of the fact type in a module of the build, and whose values pass the condition. With `any_order`, the next `Wait` searches from the same place. Two fact types that render the same sentence are two facts for the step.

**The check before the machine starts.** Before a machine starts, the tool reads each step `Fact` of its scenario against the tables `Facts` of the module files of the build, and stops with one line for each refused step, its number and its cause:

- a step with no process;
- a name that is not a package name, a dot and a record name;
- a fact type that no module of the build writes, with the fact types of the same package, or each fact type when the package has none;
- a condition with no field, no operator, `==` or a `!` alone, or no value;
- a field that the fact type does not have, with its fields;
- an order on a Text or a status, and any operator on a Bytes field;
- a value of another kind than the field, a negative value for an unsigned field, a value that the field cannot hold, a name of no member for a status;
- a value that is neither an Integer nor a Text in quotes, and text after the value.

The main test waits so for facts of the root service, each by the field that names its process, as a step has one condition: the stop of `log_reader` (`root.Process_Stopped`, `stopped_process = "log_reader"`), its connection (`root.Connected`, `caller = "log_reader"`), the start of the block service (`root.Device_Service_Started`, `service = "block"`), and two revocations (`holder = "net"`, `holder = "console"`). It waits for three facts of the windows by the field that names the window: the surface of `disk` (`compositor.Surface_Made`, `window = "disk"`), its close after the words that name no command (`compositor.Window_Closed_After_Refused_Commands`, `window = "disk"`), and an element line of `inspect` (`interface.Element_Placed`, `window = "inspect"`, from the process `inspect`). Three tests wait for a fact of the storage service by the store or the object that it names: the main test for the first commit of the store of the console at its limit (`storage_service.Store_At_Limit_Thinned_One_Version`, `store = "console"`), the test of `ranges` for the commit of its sparse object (`storage_service.Ranges_Committed`, `object = "sparse"`), and the test of the TPM keys for the erase of the versions of the file of a named principal (`storage_service.Versions_Erased_One_Version`, `object = "principal"`). The main test waits for three facts of the device services and of the network by the field that names their subject: the network device by its hardware address (`frame_service.Device_Ready_Link_Up`, `hardware_address = "52:54:00:12:34:56"`), the end of the endpoint of `net` by the process that owned it (`network_service.Endpoint_Ended`, `owner = "net"`), and the connection of `remote` to a service (`remote_service.Service_Connected`, `service = "monitor"`). The `Wait` after each step reads the rest of the sentence. A check after the machine that counts lines in its log file, as the check of the silent disk, the check of the erase with a dropped zero and the check of the lines of the thread counters, reads the file with the line of each fact rendered, because the file keeps the raw lines. So do the readers of a measured line: the measure record, the page of the measured numbers, the check of the lines of `processor_frame`, the lines that a measure run prints, and the frame that the test of the sound reads in the line of `tone`. Each of them renders with one helper and with the catalog of the module files that the run of the tool keeps, so a run reads each module file once, and again only when a build changed it. A step `Record` reads a fact too: its row in `log.records` has no text, so the tool reads `log.fact_records` from the same number, finds the module of the build by the whole hash of the row, and compares the sentence that it writes with the template. A fact past the last record that this answer reached is read again from its number; a row that the tool cannot read prints a line with its cause.

A renamed fact type or field then fails before the boot, with its cause, not at the bound of a hang. The same check refuses a call of `remote` with no step `Remote_Key` before it. The host tests of `tools/modustool/build` (`fact_step_test.odin`) give each refusal and check its cause and its sentence; those of `tools/modustool/machine` (`fact_steps_test.odin`) check one line for each refused step.

### The check of the fact waits

Most steps still wait for a log fact by its sentence, as a text. After its build, before any machine, the tool holds each such text against the fact templates of the module files of the build. The design is in `src/md/infrastructure/scenario_fault_loop.md`, "The check of the fact waits".

- **What it reads.** Each step literal of the sources of the tool: the text of a `Wait` and of each step that reads the log as a `Wait` does, and of a `Record`; the `fails_on` of any step; the `expected` of a `Key_Until`. A text is a string literal, a constant, or a sum of them. A text that the code formats is counted, not read.
- **A fact wait.** The text, after the head of a process (`[log_reader] `) and before the first mark of the scenario (`{record}`), starts with the fact prefix of a template, the name of a module and ": " (`storage: `). With the head of a process, the module of that name must also write a fact of that prefix: a result of the console, `[console] notes: 2 objects`, is no fact wait.
- **The rule.** A fact wait is the start of a sentence that a fact template renders from a place of its prefix, or that a text line of the system renders: a call `system.log(...)` of `src/modules` or `src/library`, each part that is no literal a field. A Text, a module name and a status field hold any characters; every other field holds one word, then its unit. The end of the wait can be inside a field.
- **A finding** names the file and the line of the step, the text, and the template of its prefix that renders the longest start of it, with the words where they part:

```
modustool: test failed: tools/modustool/machine/storage_scenario.odin:42: the step Wait waits for the fact text "storage: opened the store settings with 12 objects" (text), which no fact template and no text line of the build renders; the nearest, of storage, renders "storage: opened the store settings" then not " with 12 objects": "storage: opened the store {store}"
```

- **Where it runs.** `check without_machines` after its build, `test` after its build, and `modustool fact_waits` alone. It prints the count of the texts and of the fact waits, and its time, as a measure.

### The measures of the log facts

The measures that decide which lines stay text (`src/md/features/log_facts.md`, "The measures that decide it") are printed, and no test asserts one ("The bounds of the tests").

- **After each machine**, the tool prints the time of its render of the facts and the serial bytes of the facts against the same lines as text ("Log facts").
- **After the main machine**, the tool reads its serial log and the module files of the build, prints these lines, and writes them to `build/log_measures.txt`:
  - "modustool: measure: the records of the log of <log>: <count> up to "kernel: ok", <count> up to "root: the machine is usable"": the log records, the lines with a head `[name] ` and the lines of the kernel, one record for each fact and one for each 168 bytes of a text; the line of the root service is its fact `root.Machine_Usable`, which the tool finds on the serial log by the key tag of the fact type; a line of the start that the log lacks fails the machine, and no count is written;
  - "modustool: measure: the module files: root <size> bytes, <size> bytes of code; compositor ...": the bytes of the file, and of its segments of code;
  - "modustool: measure: the lines of the log of <log> by the bytes of their body, with no runs of a text: ...": a fact counts its head of 48 bytes and its values up to the last byte that is not zero; a text counts its bytes, since the serial line does not carry its runs;
  - one line for each shape of a record, 256 bytes with a head of 64 (today), 128 bytes with a head of 64, and 128 bytes with a head of 32 and no name of the process: the records that the whole log keeps, the records that the lines take, and the facts that one record cannot hold.

  The measure record keeps the first two lines ("The release"), so `measure-compare` compares them between two builds.
- **In the measure run of `log_reader`** ("A check by count, a measure by time"), the process prints three lines: "log_reader: measure: the write of one line, ..." (the least and the median of 200 calls of `system.log` and of `system.log_fact` for the line of a bad block and of a connection, each series in a second of its own, under the log limit), "log_reader: measure: the operation Log, ..." (the same for `Log` of a text, of a fact, and of a call that the kernel refuses at the border of the form, which is the cost of the kernel entry), and "log_reader: measure: the render of a log fact by module.fact_sentence_write, ..." (the least and the median of 2047 renders, and 30 rows of the window of the log at the median).

### The serial port and the log limit

The operation `Log` writes the records of the log only. The serial writer (`glossary/running_code.md`) prints them on the serial port after it: at each tick, a processor prints the lines of the records that the serial port does not have yet, in their order, for at most 100 µs, and only while the device takes bytes. Its time is charged to no budget. A processor that waits for a lock more than 1 s prints them too. So a `Log` never waits for the lines of other processes, and a hang of one processor does not silence the others. Before the first tick, each writer of a record prints it at once; before the machine stops, the kernel prints each record that is left; a report of a fault of the kernel prints them before its own lines. When the log wrote over records before the drain printed them, the serial port gets "kernel: <count> records of the log did not reach the serial port", and each scenario of the tool fails at once on that line, and once more on the whole log after the machine ends. A processor with nothing to run drains too, before its idle wait, at the rate of the port, with a window for interrupts after each byte: on a machine with an idle processor the serial port lags the log only by the rate of the port. A machine whose processors are all busy drains at the ticks only, and lags: a test that acts on the moment of a line under load must wait for a state instead. The first drains that wrote 64 KiB together write their measured rate once: "kernel: the drain of the serial port wrote <size> in <time> of port writes: <rate> bytes each second while it writes; <count> bytes in the idle loop, at that rate, and <count> at the ticks, at most <rate> each second for one busy processor". After the flush before the machine stops, the serial port gets the largest lag of a line in the run, from the time of its record to the write of its end on the port: "kernel: the largest lag of a line of the log on the serial port: <time> us". No test asserts either. In a flood, the processes write faster than the device keeps: the serial port then loses lines, and says how many.

The log records of each second are an amount of a budget, as its pages: a child budget takes its records from its starter, with its part of the count of this second, and gives both back when it ends. A budget counts only the records of its own processes, and a `Log` spends each record that its text takes: 4096 bytes are 25 records. So `No_Budget` from `Log` says only that the process wrote the amount of its budget in this second, never that another process wrote much. The kernel writes at most `op.LOG_RECORDS_OF_THE_KERNEL`, 64 records of its own in each second; past them it writes "kernel: <count> lines of the kernel were over its limit of 64 records in each second". The machine has `op.LOG_RECORDS_OF_THE_MACHINE`, 64 000: 1000 for each process slot. The root service gives each process `op.LOG_RECORDS_OF_A_PROCESS`, 1000, and `limits` 40, and keeps 1000; a starter divides its own 1000 among its children. `system.log` never waits: a line that the kernel refuses is dropped and counted, and the next line that the kernel accepts comes after one record "<count> lines of this process were refused by its log limit". When a process stops after refused lines that no later line said, the kernel writes "kernel: <process>: <count> lines were refused by its log limit, the last ones before its stop". The design: `src/md/features/log_side_channels.md`.

### The window of the log

The process `log` shows the newest records, in 30 lines: the time, the mark of the level, the process, and the text in the font of the cells. Over them, a card for each process gives the count of its records, on the lines that the window keeps for them; the processes that those lines do not hold count together in the last card, "others". The process slot and the process serial name a process there, as they do for the log scope: two processes with one name have two cards. A text is whole, on the lines that it needs: the window joins again the records of a text that the kernel kept in several records, and a line ends at a space, never where a record ended (`docs/INTERFACE.md`, "The text in a box"). A name of a process that is wider than its column takes more lines too. Each value run is in the color of its value kind (`docs/DESIGN.md`, "The colors of values"); the rest of the text is in the text color, or in the color "failed" for a record of the level error. The head of the column of the text is the legend: the six kinds that the logs write, each in its color. A text that starts with the name of its process and ": " shows without that start: the column at its left says it. The record keeps its text whole. A log fact shows the sentence of its fact template, each value in the color of its kind: the window holds the boot image (the grant `image`), in which it finds the module file that the fact names. A fact whose module the image does not hold shows its raw form, the line of the serial port, and a record of a form that the window does not know shows "a record of an unknown form".

The top line counts the records that the window did not read, in two counts. "Gone before its start" counts the records that the kernel wrote over before the window kept its first record: it says how long the machine ran before the window started. "Lost since" counts each record after the first kept record that the window did not read, in the color "failed" when it is not 0: the window was slower than the writers. After its first read of the ring, the window writes "log: the memory of the log: <count> records in <size>", then the same counts once: "log: ok, <count> records, <count> gone before its start, <count> lost since, <count> processes". The main machine test requires "0 lost since" and keeps the other count as a measure. The design: `src/md/features/log_window_losses.md`.

### The tables of the log service

`log.records(after)` gives one row for each record: its fields, the count of its value runs (`runs`), and its text. The `level` is a member of `Log_Level` (`Info`, `Debug`, `Warning`, `Error`) and the `form` a member of `Log_Record_Form` (`Text`, `Fact`), each a status of a contract enum: `where(level = Warning)` compares a member, not a text. A fact has an empty text. `log.value_runs(after)` gives the value runs: the number of the record, the start and the length in bytes of its text, and the name of the kind (`size`, `time`...). Join them on `number`. `log.fact_records(after)` gives one row for each log fact, with the bytes that its writer gave and the kernel wrote: the number of the record, its record form and its byte `more`, the fact key, the module hash, the count of the value bytes, the reserved bytes and the 144 value bytes, 0 past their count (a field of the kind `Fact_Values`, which a table draws in hexadecimal up to its last byte that is not zero). A row of `records` has no room for them: join the two on `number`. The service renders no sentence: a reader writes it from the values and the module file that the hash names. The first row of `records` also says in `lost` how many records after `after` the kernel wrote over before the call read them: a reader that is slow knows what it missed.

### Who reads which records

The log has the records of every process, and a process sees no other process. So the log service gives each caller the records of its log scope (`glossary/running_code.md`), and the caller never maps the memory of the log:

| Caller | Its log scope |
|---|---|
| A caller that acts for the principal: the console, `remote` | The whole log |
| Each other caller with a connection to the log service: `log_reader` | Its own records: the records with its process slot and its process serial |
| A process with no connection to the log service | No record through the service. Its records are on the serial port and in the whole log |
| Each caller, in `process_records` and `process_value_runs`, with a process handle that it lends with the right Read: a starter and the handle of its child | The records of that process only |

The kernel writes the process slot, the process serial and the own number in each record. The root service writes the two numbers of the caller in the grant of its connection, and the caller cannot change them (`modus:contract/log_scope`). A new process in the same slot has another serial, so it does not read the records of the process before it. A record that another process wrote about a process, such as "root: started log_reader", is not one of its own records.

A reader of its own records sees no number of the whole log. The number of each of its rows is the own number of the record (`glossary/running_code.md`): 0 for the first record of its process. It gives `after` in own numbers, and `lost` counts its own records that its ring no longer keeps. So it receives no number or count of the records of other processes.

Its rows come from the own log ring of its process (`glossary/running_code.md`): the kernel writes each record of a process in the whole log and in that ring, which keeps the last 64 records of the process and which only its records fill. A log storm of another process pushes records out of the whole log, never out of this ring, so the records that a reader lost say nothing of the others. The log service reads the ring with the kernel operation `Log_Read`, through its handle of the memory of the log (`docs/ARCHITECTURE.md`, "The own log ring of a process"). The ring ends when the slot of its process is free: after the stop, when the last handle to the process closes. A starter that holds the handle of a stopped child still reads the child's ring, and every record stays in the whole log until newer records push it out. A reader that wants more than its last 64 records keeps them as it reads them. A reader whose own records are all gone receives no row, and so no `lost`. The result of the two exports counts the rows of the scope. A reader chooses its rows by process and by level with `where`: a log scope never names a name that the writer chooses, because any process can write any such name. `revoke("console", "acts_for_principal")` changes the scope of the console to its own records. If a service ring has no room for the new grants, the root service refuses the revocation with `No_Slot`, changes nothing, and writes "root: refused the revocation of acts_for_principal of <process>: the service <name> has no room for the new grants; nothing changed".

Each reader of the whole log keeps a copy of a record only when the kernel did not start to write over it during the copy (`op.log_copy_kept`): the record under the writer of the next one counts as lost, so a copy never holds the head of one record and the text of another. A reader then copies the last 2046 records at most, one fewer than the 2047 that the ring holds.

A starter reads the records of its children. A process sees the processes that it started, and the process handle of a child is the proof: `Process_Create` gives it to the starter only. So a starter lends the handle of a child, with the right Read, to `log.process_records(process, after)` and `log.process_value_runs(process, after)`. The log service asks the kernel for the process slot and the process serial of that process, and gives its records, numbered by their own numbers, as it gives a reader its own records: from the own log ring of that process, so a storm of one child never pushes out the records of another. One call gives the records of one process: the own numbers of two processes are two sequences. The scope of these two exports is the process of the handle, also for a caller that acts for the principal. A grandchild is the child of the child: its starter reads its records only if the child gives it the handle of the grandchild. The lent handle keeps the slot of the child, so a stopped child is still read, and a record of an earlier process of the slot is not given. A handle that names no process gives the error record `Handle_Kind`.

The process `log_reader` is the test: it writes one record, and starts two children that each write one record and stop. It then starts a third child, `log_reader storm`, which writes more records than the whole log keeps and stops; a refusal by the log limit of a second makes it write the record again in the next second, so each record reaches the log. The storm child takes 900 of the 1000 log records of each second of `log_reader`, which keeps 100 for its own lines, and gives them back at its stop. The storm pushes the records of `log_reader` and of its two children out of the whole log. `log_reader` then connects, reads the log from the own number 0, and writes "log_reader: its own records: 1 rows from the own number 0, its first record, in the slot <slot>, lost 0: no row of another process or of an earlier run: as it must". With the handle of each child, it then writes "log_reader: the records of log_reader child 1: 1 rows from the own number 0, its one record, lost 0: no row of this process, of the other child or of an earlier run: as it must", and the same for the child 2, then "log_reader: a child wrote <count> records after the records of this process and of its two children, more than the <capacity> that the whole log keeps, and the own log ring of each one kept its records: as it must", and "log_reader: the storm child took 900 of the 1000 log records of each second of this process, which kept 100, and each child gave its records back at its stop: as it must". A memory object in place of a process handle is refused with `Handle_Kind`. The process handle of the log service that `connect` gives has Read and no Give, so its lend fails with `No_Right`: a client reads no record of a service. The machine test starts it two times: the second run receives none of the records of the first one or of its children. It then reads the whole log through `remote`, in order: the last record of the storm child, "log_reader: ok", and the record "root: log_reader stopped: itself, done". The design: `src/md/features/log_reader_scope.md`, `src/md/features/own_log_ring.md` and `src/md/features/log_side_channels.md`.

### The console and the terminal

A log record reaches the console only as the rows of these two tables. The console draws them as a table when a line asks for them. It also reads them itself for the processes that a line calls, and shows those records under the line, with each value run in the color of its value kind (`docs/CONSOLE.md`, "The log records of a line"). A process writes to its terminal apart from the log; a Text record of the terminal carries a value kind for each run (`Style.value_kind`), whose color the terminal chooses in the appearance in force, so a console that writes a record as runs of text, one run for each value run, needs no new form of the terminal.

## The process `inspect`

`inspect` is a window that shows one running process: its memory, its modules, its threads, and the stack trace when it stopped on a fault. It reads the same reports as any holder of the machine with **Inspect**, so it never sees the bytes of the process. The picture at the top of this guide shows it on the console.

One window for one process that the principal chooses in a list. It shows:

1. **The address space** (`Inspect_Kind.Process_Mappings`, `op.Process_Mapping_Report`): each mapping of the process, with its address, its pages, the first page of its memory object, the pages that have a frame (a count that each mapping keeps where an entry becomes present, under the process lock: the report reads one count for each mapping, not one entry for each page), the size and the serial of the memory object, and flags (`op.Process_Mapping_Flag`): Write, Execute, Uncached, Device, Contiguous, Shared (another mapping or handle names the object), Thread_Area, Uncommitted (an object made with Uncommitted: the field `committed` says which part its budget pays), Large (pages of 2 MiB), Protected (`Memory_Protect` changed pages of the mapping), No_Access (its protection is No_Access now) and Write_Combining (device memory mapped write-combining, in place of Uncached). The window draws one band scaled by address. A gap between two mappings is folded: it has a fixed width and lines at an angle (`DESIGN.md`, section 2: lines at an angle are a part with no measure on the scale). The kind of a mapping comes from these facts and from the module records: module code, module constants, module data, thread area, device, shared memory, memory of the process. The kernel does not know a stack: it is memory of the process.
2. **The modules** (`Module_Report`): name (from the boot image), hash, base and size. Each address in the window is `module + offset` when a module record holds it, as the stack trace of a fault names a frame (`MODULE_CONTRACT.md`, section 8).
3. **The threads** (`Inspect_Kind.Threads`, `op.Thread_Table_Report`): the machine number, the thread area, the state, the processor that runs it and its home queue, the weight and the request, the virtual time, the virtual deadline and the lag of the strategy, the processor time, the words of a word wait and its deadline. The kernel reads the fields of the scheduler with no run lock: each field is whole, two fields can come from two instants.
4. **The stop report** of a process that stopped on a fault (`Inspect_Kind.Stop`): the vector, the address, and each frame with the name of its procedure and its source line, `fault::three + 0x8 in fault (src/modules/demonstrations/fault/main.odin:15)`, from the debug image (section "Names and lines"). With no debug image, or a frame that no procedure of the debug object holds, the frame is `module + offset, near export`. The names are made when the stop report changes, not at each picture. The kernel filters the report (see below). The log has the stop as a log fact, `inspect: fault stopped: page fault at 0x0`, then one log fact for each frame, `inspect: fault, the frame 0 of the stack: fault::three + 0x...`, which the machine test waits for.
5. **Live**: a sample each 250 ms. A value that changed since the sample before is drawn in the color of the boot program for one sample. Space freezes the sample. The window shows the time of one sample and its kernel entries.
6. **A hex view** of the memory of `inspect` itself (the code of its export `entry`, and four pages of a memory object of which two were written): 16 bytes in each row, the address as `module + offset`, the ASCII at the right, the boundary of each page marked. A page with no frame is shown as such, and the tool does not read it: it asks `Inspect_Kind.Pages` (`op.Page_Report`) which pages have a frame, so its read gives no frame to a page. `Pages` answers for the process that asks only: about another process it is a side channel (a holder of Inspect watches which pages of a process get a frame, page by page, as the process runs), finer than each other report.
7. **One process, by its slot and its serial.** Each report has the serial of the process of the slot. A sample whose reports have two serials (a process ended, and a new one took its slot between two reports) is dropped, and the window keeps the sample before. The tool chooses a process by its slot and its serial, not by its name: two processes can have one name.

## Names and lines

A stop report gives addresses, and a reader wants the name of a procedure and a line of a source file. The names come from the debug object of each module, which the kernel never reads: a few processes with a grant read the debug image and translate. With no debug image, a frame keeps the form `module + offset`.

The kernel gives an address of a stop report as an address in a module record. The module names its exports only. The names of its other procedures and its source lines are in its debug object (`glossary/code.md`; `MODULE_CONTRACT.md`, "Debug information").

The debug object also holds what a debugger shows: the types, the global variables, and the parameters and the local variables of each procedure with their variable locations (`MODULE_CONTRACT.md`, "The types and the variables"). The names and the lines come from the symbol table and from the line program of the linked file; the types and the variables come from the entries of its DWARF. A process reads all of them through `src/library/modus/contract/debug_object`, with no parser of DWARF.

- **One module, one debug object**: the debug object holds the BLAKE3 hash of its module file. A reader uses it only for a loaded module with that hash (`debug_object.describes_module`).
- **The source of a line**: the debug object holds, for each source file, its path from the root of the repository and the BLAKE3 hash of its content at the build. `debug_object.source_line_of` gives the path, the hash and the line of an instruction. A reader shows the text of the line only from a file with that hash, and says so when the hash differs.

- **Who names**: a process with the grant `Debug_Image` of the root service: `console`, `inspect`, `errors` and `debugger`. The root service maps the debug image read-only into each of them (the fixed range `Debug_Image`). The kernel reads no debug object: its line of the log stays "in module <hash> at offset X".
- **The form of a frame**: `procedure + offset in module (file:line)`. Frame 0 is the instruction. Each next frame is a return address: the procedure and the line are those of the call, the byte before the return address. The offset is the distance of the address from the start of the procedure.
- **The console**: a call host that stops on a fault prints "error: the instruction is at " and the name of its instruction, then one line "error: frame N: ..." for each frame (`fault_print`). A frame that no procedure of the debug object holds stays `module + offset`.
- **The process `errors`**: the case of the process `fault` writes its stack trace with the names: "fault::three + 0x8 in fault (src/modules/demonstrations/fault/main.odin:15), fault::two + 0x... in fault (src/modules/demonstrations/fault/main.odin:20), ...".
- **The machine test** (`Trace`): the tool takes the names that the system wrote, or names a frame `module + offset` from the debug object of the module in `build/modules`, with the same reader.
- **With no debug image** (a volume with no file `DEBUG/OBJECTS.IMG`): each frame is `module + offset`.

Lines of the machine test, after the console called the module `probe`, which tests the sandbox of an isolated call and reads an address that it must not read. Frame 1 is in a part of `host` that no procedure of its debug object holds:

```
[console] error: frame 0: peek + 0x4 in probe (src/modules/tests/probe/probe.odin:18), the instruction
[console] error: frame 1: host + 0x2e14
[console] error: frame 2: entry + 0x224d in host (src/library/modus/system/service.odin:337)
```

## The debugger

A debugger stops a process where its author asks, shows its threads, its registers, its stack and its variables, and runs it one instruction at a time. The debugger of the system is a service, the process `debugger`. Each command of the debugger is an export of that service, and each export gives a table of records: the console, a window and a developer on another machine call the same exports.

The code is `src/modules/system/debugger` (the service), `src/library/internal/debugger/debugging` (the parts with no kernel operation: the path of a value, the walk of the frames, the place of a breakpoint, the location of a variable, the text of a value), `src/library/modus/contract/debug_object` (the reader of the debug objects) and `src/modules/system/console/debugger_commands.odin` (the short names). The kernel part is in `ARCHITECTURE.md`, "The debugger of a process"; the reasons of the form are in "The debugger: the design" below.

### The service

- **Its start.** The root service starts `debugger` when a caller asks for a connection to it: `connect("debugger")`, or the first command of the debugger in the console. It has no window.
- **Its grants.** Serve (its exports); Debugger (the commands `Debug`, `Debug_Store` and `Debug_Start` of the root ring, and no other command: `Debug_Store` gives a connection that reads only to the store of the debug object of a disk process that the service debugs, or that stopped on a fault, with the stop report that the root service kept of it; `Debug_Start` starts a module for the caller held before its first instruction, under the rule of `Debug`, and lets it run or stops it when the service asks); Inspect (the thread report and the module report of a process); Debug_Image (the debug objects); Image (the name of each module, from its hash).
- **How it debugs.** The service is the debugger of the process for the kernel: its main thread is the debug handler, so each breakpoint and each single step of the process is a fault record of that thread. It reads the threads and the module records with `Inspect`, the registers and the memory with `Thread_Control`, and the names, the lines, the types and the variables in the debug object of each module, by the hash of the module. It writes no byte in the process.
- **One process at a time.** The service debugs one process, for one caller. A second `attach` while it does gets the error `Full` (`Debugged_Processes`). Each export but `attach` acts only for the caller that attached.
- **The end of the debugging.** `detach()`; the end of the connection of the caller, or of the caller; the revocation of the grant `debug` of the caller; the stop of the process. The kernel then removes the breakpoints, clears the trap flag that the debugger wrote, and resumes each thread that the debugger held.
- **The log.** One line for each attach, for each stop of a thread at a breakpoint or a watch ("debugger: the thread 0 of clock stopped: breakpoint 1"), and for each end of a debugging.

### Who can debug which process

The root service gives the debug access: the handle of the process with the right `Debug`, and no other right. The service `debugger` asks for it with the command `Debug` of the root ring, on behalf of one of its callers: it names the call ring of the connection of that caller. The root service made that connection, so it knows the caller, and it applies the rule to the caller, not to the service. Only the process with the grant Debugger sends the command.

The rule compares two sets of grants. It names no process:

1. **The caller acts for the principal whose session runs the process.** The caller holds the grant to act for the principal, and the process is in the session of the same principal (`PRINCIPALS.md`). A process of the machine does not debug a process of a named principal, and a process of one principal does not debug a process of another.
2. **Each grant of the process is a grant that the caller holds.** A debugger acts with each handle of the process that it debugs and reads each byte of it, so the right `Debug` on a process is each grant of that process. The grants of the process are those that the root service gave it at its start, which the root service keeps in the state of the process that runs (`Started.start_grant_set` in `src/modules/system/root/main.odin`): the rule reads no table by the name of a process, so it holds for a process that comes from a disk as for a process of the boot image.
3. **A revoked grant is not a grant that the caller holds.** After `revoke("console", "machine")`, the console does not debug a process that has a right of the machine.
4. **A grant refuses the debug access for each caller when what it reaches belongs to that one process.** Two holders of such a grant do not hold the same thing, so the caller does not hold what the process holds. The grants (`GRANTS_OF_ONE_PROCESS` in `src/modules/system/root/main.odin`): Serve (a service holds what its callers lent it and what it keeps for them); Store and History_Store (a store of its own: a caller that acts for the principal reads each store of that principal and writes only its own, and through the registers of the process a debugger would write the store of the process); Terminal (a terminal of its own, with the keys typed in it); Network (an endpoint names its own remote and its own ports); Connect (the services that a process can connect to are its own list); Data_Disk, Scratch_Disk, Network_Device and Sound_Device (a device service started for the process alone); Principals (a ring of its own, and the records of the principals); Remote_Clients (a connection for a row of the client table acts for the principal of that row, which is not the principal of the caller); Start_Policy (a root ring that starts and stops the processes of the machine, which no caller holds); Screen_Capture (the copy of the screen and the input of the desktop, which show and drive each window of the principal in front); Plans (the roles page, which names the holders of the roles of the machine). Each other grant reaches one thing that each of its holders reaches: the machine by its rights, the boot image, the debug image, the replacement table, the settings page, the date page, the records of the log, the commands of the root ring.
5. **A revocation ends a debugging that the rule no longer gives.** After each revocation of a grant of a caller, the root service checks each debugging of that caller against the rule again, and ends each one that fails: the process is given back as on a detach, with no thread left stopped. So `revoke("console", "machine")` ends the debugging of `clock` by the console, and `revoke("remote", "acts_for_principal")` ends each debugging of the host. The end needs nothing of the caller. `detach()` needs no grant either.

What follows from the rule:

| Process | The answer for the console |
|---|---|
| A process with no grant (`debug_target`, `plasma`, `fault`, `hall_of_fame`, each process that the root service gives only the log and a window) | Given |
| A process with a right of the machine that the console holds, Inspect or Stop (`time_page`, `processors`, `pages`, `flow`, `crowd`) | Given, until the grant `machine` of the console is revoked |
| A process with the boot image, with or without Inspect (`pointers`, `rings`, `boot`, `rights`, `frames`, `locks`, `address_space`, `imports`, `return_fault`, `fault_ring`, `debugged`, `replay_probe`, `cryptography_vectors`, `interface_through_module`) | Given, until the grant `image` of the console is revoked |
| A process with a private store (`notes`, `browser`, `hierarchy`, `ranges`, `errors`, `unlock`) | Refused: the grant Store |
| A service (`storage`, `monitor`, `inspect`, `log`, `settings`, `date`, `manual`, `server`, `debugger`, the compositor) | Refused: the grant Serve |
| A process with a terminal (`flood`, a second console) | Refused: the grant Terminal |
| A process with an endpoint of the network (`net`, `fetch`, `quic_echo`, `remote`) | Refused: the grant Network, or Connect |
| A process that connects to services (`tables`, `log_reader`) | Refused: the grant Connect |
| A process with a device (`disk`, `network`, `tone`) | Refused: the grant Scratch_Disk, Network_Device or Sound_Device |
| A device service, a terminal | Refused: the grant System_Part, which the root service gives to the parts of the system that it starts by itself, and which no caller holds |
| A process with a grant that the console does not hold (`scheduler`: Schedule; `kernel_events`: Events) | Refused: that grant |

The grant that a refusal names is the first one of the process that refuses, in the order of the enumeration `Grant` (`src/library/modus/contract/start_grant`).

A start grant and a recorded grant are not one to one. Several start grants are one recorded grant: `Inspect`, `Stop`, `Schedule`, `Events` and `Counters` are rights of the one handle `machine`. A start grant such as `Serve` has no recorded grant, and the recorded grants `log` and `debug` have no start grant.

**A window is not a grant.** Each process with no terminal has a window, and no grant names it, so the rule does not see it. The debugger of a process draws in the window of that process and reads the keys and the pointer events that the compositor sends to it. For the console this is the shell of the same principal, at the same screen.

A refusal is an error record of the kind `No_Grant` with the unit `Debug_Access`; `found` is 1 + the number of the start grant that refuses, in the enumeration `Grant` of `src/library/modus/contract/start_grant`. The sentence of the record and the log of the root service name that grant with the same word, from the one table `GRANT_NAMES` of that package: the console prints "debugger.attach: the caller has no grant for this: the debug access to this process: the grant Store of the process refuses it", and the log has "root: refused console the debug access to notes: the grant Store of the process refuses it". The name of a start grant is the name of its member, with its capital letters (`Store`, `System_Part`); a name in lower case (`store`, `machine`) is a recorded grant, which `grants` shows and `revoke` takes. The number of a start grant does not change when a start grant is added: the new one takes the next number. A reader that does not know a number, because the root service is of a later build, writes "a start grant of the process that this process does not know refuses it", and the detail lines of the record give the number. The other refusals: `No_Grant`, `Acts_For_Principal` (rule 1); `Absent`, `Processes` (no process has the name); `Full`, `Debugged_Processes` (another caller debugs the process).

The grant is a record of the root service: `debug` in `grants()`, a grant of the caller. `revoke` ends each handle that came from it, and the kernel ends the debugging with the last handle. The handle also ends when the connection of the caller to the service ends, when the caller stops, and when a revocation of another grant of the caller takes the access away (rule 5). After `detach()`, the service tells the root service that the debugging ended, with the same command.

The creator of a process also has the right `Debug` on the handle that the creation gave it (`ARCHITECTURE.md`, "The debugger of a process"). The root service gives the right to no process at its start.

### The exports of the service

Each export gives a table, or a negative number with an error record. A caller that does not act for the principal gets `No_Grant` (`Acts_For_Principal`). The reference of each export, with its parameters and its errors, is its comment in `src/modules/system/debugger/exports.odin`.

| Export | What it gives |
|---|---|
| `attach(process)` | One row: the process, its slot, its threads, its modules, and how many modules have a debug object |
| `detach()` | One row: the process, the breakpoints that the debugger had, the threads that it held |
| `threads()` | One row for each thread: its number, its state (`ready`, `waiting`, `held`, `stopped`), and for a thread that is held or stopped its instruction, with its module, its procedure, its offset, its file and its line |
| `hold(thread)`, `release(thread)` | Hold one thread; let one thread run. The row of the thread |
| `continue_all()` | Write the breakpoints in each thread, then let each thread run. One row for each thread |
| `registers(thread)` | 18 rows: the 16 general registers, `rip` with its procedure and its line, `rflags` with the flags that are set |
| `stack(thread)` | One row for each frame: the frame number, the module, the procedure, the offset, the file, the line, the frame pointer, the return address |
| `locals(thread, frame)` | One row for each parameter and each local variable that is visible at the instruction of the frame: its name, its role, its type, its value or "not readable", its location |
| `value(thread, frame, path)` | One variable or one global by a path: one row for each field of a record, each element of an array or of a slice, or one row for a value with no part. Each row: the name, the type, the value, the address |
| `source(thread, frame)` | One row: the line number, the path of the file, and the hash of the file at the build. The system holds no source text |
| `break_at(place)` | An execute breakpoint at a procedure (`fault::three`) or at a file and a line (`src/modules/demonstrations/fault/main.odin:15`). One row for each breakpoint |
| `watch(place, length)` | A data breakpoint on 1, 2, 4 or 8 bytes that the process writes, at an address or at a global. One row for each breakpoint |
| `breaks()`, `break_remove(number)` | The breakpoints of the debugger; remove one |
| `step(thread)` | One instruction. The row of the thread at its new instruction; `pending` 1 when the step did not end in 1000 ms |
| `step_line(thread)` | Instructions until the source line changes, at most 4096 and 2000 ms. The row of the thread; `pending` 1 when the line did not change yet |
| `step_over(thread)` | As `step_line`, and a call of the line runs to its end: the service puts a breakpoint at the instruction after the call, in a free place of the four, and lets the thread run to it. With no free place the thread stops at the first line of the call. A call that does not return in 2000 ms leaves the thread running with `pending` 1 and the breakpoint in place: the stop at the return is an event |
| `memory(place, count)` | At most 4096 bytes from an address or from a global, 16 in each row: the address, the bytes in hexadecimal, their printable characters |
| `events()` | One row for each stop of a thread since the last call: the thread, the kind (`breakpoint N`, `watch N`, `step`, `int3`, `int1`), the instruction, its module, its procedure, its offset, its file and its line |
| `wait_stop(milliseconds)` | Wait for the next stop, at most the given time and 3000 ms, then the rows of `events()` |
| `stop_report(process)` | With no attach: the stop report that the root service kept of a disk process of the principal of the caller that stopped on a fault. One row for each frame: the frame number, the module, the procedure, the offset, the file, the line, and in the row 0 what stopped the process (`MODULE_CONTRACT.md`, "The debug object of a disk process") |
| `record(process)` | Start a module of the boot image held before its first instruction (the command `Debug_Start` of the root service, which starts it for the caller as `start` does, under the rule of `attach`), attach to it, record it from that instruction, then let it run. The row of the record. Memory that the process and another process both write is recorded: the other process writes only while the process is at an input point, at most one stint (`src/md/features/record_and_replay.md`) |
| `record_start()`, `record_end()` | Ask the kernel to record the attached process into an input history of 16 pages of the service, which also pays its point copies and the copies of its shared pages; end that record. The kernel records only a process that did not run: `record` starts one. The row of the record |
| `replay_start()` | Run the recorded module again from the history: the root service starts it with no start grant, held; the kernel writes the context of the record into it, answers each kernel entry, each read of the cycle counter and each `cpuid` from the history, and stops it at the first difference. A replay sends nothing to any process, so a process that maps memory that it received diverges at that map. The row of the record |
| `replay_status()` | With no attach: the row of the history of the caller, which stays after the debugging until the next record. Its state (`recording`, `ended`, `replaying`, `replayed`), its input points, its bytes, its capacity, why it ended (`process stopped`, `record ended`, `stint bound`, `revocation`, `history full`, `divergence`), its checkpoints, and the first divergence of a replay: its input point, what differed (`operation`, `instruction`, `arguments`, `record`, `kind`, `end`), the value of the history and the value of the replay, and the instruction address of the record of the history there |
| `replay_checkpoint(thread)` | A checkpoint of a held thread at the last input point of the record: one row for each checkpoint, its number, its input point, the bytes of the history before it, the instruction and the stack pointer of the thread |
| `replay_step_back(points)` | The way back by some input points: one row with the nearest checkpoint at or before the target point, its input point, the target point, the input points that a replay runs from it, and the instruction and the stack pointer there |
| `watch_back(address, size, before_point)` | With no attach: the last input of the history, before the point (0: the whole history), that wrote a byte of 1 to 4096 bytes at the address. One row: its input point, the bytes of the history before it, its source (`page delta`: a point copy or a shared page; `kernel entry`: bytes that the kernel copied into the process), the first byte written and how many, at most 8 values, the instruction of the thread there, and the checkpoint strictly before the write with the input points of a replay from it (checkpoint 0: the first instruction). A write by an instruction of the process is not an input and is not in the history |

**The errors.** Each failure is an error record (`MODULE_CONTRACT.md`, section 8):

| The failure | Kind, unit | Result |
|---|---|---|
| The caller attached to no process | `Absent`, `Debugged_Processes` | -2 |
| The service debugs a process already | `Full`, `Debugged_Processes` | -3 |
| The root service or the kernel refused | The record of the root service, or `Refused` with the status | -4 |
| No thread has the number; the thread is not held | `Absent`, `Threads`; `Absent`, `Held_Threads` | -5 |
| The module of the address has no debug object | `Absent`, `Debug_Objects` | -6 |
| The stack has no frame with the number | `Absent`, `Stack_Frames` | -7 |
| No variable and no global has the name, or the variable is not readable at this instruction | `Absent`, `Readable_Variables` | -8 |
| The text is not a path; a step of the path names nothing | `Bad_Byte`; `Bad_Value` | -9 |
| No procedure and no line has the place | `Absent`, `Source_Places` | -10 |
| No breakpoint is free; the number names no breakpoint | `Full`, `Breakpoints`; `Absent`, `Breakpoints` | -11 |
| The process does not map the address, or a range of `watch_back` is outside user memory; a count or a length that the export does not take | `Bad_Address`; `Bad_Value`; `Not_Multiple` | -12 |
| The process stopped, or the debug access ended | `Absent`, `Processes` | -13 |
| Two processes that run have the name and the module | `Bad_Value`, `Processes` | -14 |
| A text argument is too long | `Too_Long`, `Bytes` | -15 |
| No record runs or started; a record or a replay runs already; a step back of 0 points or past the history, or a point of `watch_back` past it; the module of the boot image is not the module of the history; a header of the history that is not valid | `Absent`; `Full`; `Out_Of_Range`; `Bad_Value`; `Damaged`, `Input_Histories` | -16 |
| No checkpoint is at or before the target point; a checkpoint is at this input point already | `Absent`; `Exists`, `Checkpoints` | -17 |
| No input of the history before the point wrote a byte of the range of `watch_back` | `Absent`, `Recorded_Writes` | -18 |

**The stops.** A thread that reaches a breakpoint, that writes watched bytes or that ends a step waits for the debugger: `release`, `step` or `continue_all` lets it run. After an execute breakpoint the instruction of the thread is the one of the breakpoint, which did not run; `release` runs it once, and the breakpoint stays. After a watch and after a step, the instruction is the next one. The service takes each stop when it comes, keeps 32 of them for `events()`, and writes one line of the log. A caller learns of a stop with `wait_stop`, with no loop of `events()`.

**The breakpoints.** The debugger has four breakpoints, for execute breakpoints and watches together: they are the debug registers of a thread. The service writes them in each thread of the process when one is set or removed, and at `continue_all()`; a thread that the process makes later has none until then. A thread that runs is held for the write, then released. A watch does not see an access that the kernel makes for the process.

**A step.** The service writes the trap flag in the registers of the thread and lets it run; the record of the step comes after one instruction, and the service clears the flag at the next stop of the thread. The end of a step that its export waited for is the result of the export, not an event. A thread that waits in the kernel runs its next instruction only when its wait ends: `step` waits 1000 ms at most, then gives the row of a thread that runs, with `pending` 1, and the stop comes later as an event of the kind `step`. `step_line` enters a procedure that the line calls. A breakpoint or a watch that the thread reaches before the line changes ends `step_line` there, with `pending` 0, and the stop is also an event. At its bound of 4096 instructions or 2000 ms it gives the row of where the thread is, with `pending` 1, and the caller calls it again.

**The bounds of the exports.** The service has one thread and serves each caller of each principal, and the debugged process chooses how long one of its instructions takes. So no export waits longer than a stated bound, and each bound is under the 5000 ms after which `remote` ends a call:

| Export | What it waits for | Bound |
|---|---|---|
| `attach` | The answer of the root service | 2000 ms. A later answer is taken when it comes: the service closes the handle and tells the root service that the access ended |
| `record`, `replay_start` | The answer of the root service to the held start, then to its release | 2000 ms each. A later answer of the start is taken when it comes: the service closes the handle and the root service stops the held process |
| `stop_report` | The answer of the root service and the read of the debug object, together | 1500 ms. A later answer is taken when it comes: the service closes its handles and tells the root service to end the connection |
| `step` | The record of one step | 1000 ms |
| `step_line` | The records of its steps, together | 2000 ms, and 4096 instructions |
| `step_over` | The records of its steps and of the return of each call, together | 2000 ms, and 4096 instructions outside the calls |
| `wait_stop` | The next stop | 3000 ms, whatever the caller gives |
| `hold`, `break_at`, `watch`, `break_remove`, `continue_all` | The kernel, which waits until a thread on another processor left it | No wait of the service: one kernel operation for each thread |
| `detach`, and each other export | Nothing | No wait: the end command to the root service is sent with no wait for its answer |

**One process in two places.** The service finds the reports of the process by its name and by the hash of its module, which the root service gives with the handle. When two processes that run have that name and that module, the service cannot tell which one its handle names: the attach is refused (`Bad_Value`, `Processes`). The kernel gives no slot for a process handle; a result of `Handle_State` that gives it would end this limit.

### The commands of the console

Each command is an export of the service under a short name (`bound_call`, `CONSOLE.md`): the console connects to `debugger` when it has no connection to it, calls the export, and draws the table as it draws each table. The console holds no state of the debugging. The same exports are also commands with their full names after `connect("debugger")`: `debugger.threads()`.

| Command | Export | Why another name |
|---|---|---|
| `debug("time_page")` | `attach` | The word for the act |
| `detach()` | `detach` | |
| `threads()`, `registers(thread)`, `stack(thread)`, `locals(thread, frame)`, `value(thread, frame, path)`, `source(thread, frame)` | The same names | |
| `hold(thread)` | `hold` | `stop` stops a whole process by its name |
| `resume(thread)` | `release` | `release` closes a handle of the console |
| `continue_all()` | `continue_all` | |
| `break_at(place)`, `watch(place, length)`, `breaks()`, `break_remove(number)` | The same names | |
| `step(thread)`, `step_line(thread)`, `step_over(thread)` | The same names | |
| `debug_memory(place, count)` | `memory` | `memory` gives the memory of the machine |
| `events()`, `wait_stop(milliseconds)` | The same names | |
| `record(process)`, `record_start()`, `record_end()`, `replay_start()`, `replay_status()`, `replay_checkpoint(thread)`, `replay_step_back(points)` | The same names | |
| `watch_back(address, size)` | `watch_back`, with the point 0: the whole history | |

A table of the debugger is a table as any other: `columns(stack(0), frame, procedure, line)`, `where(locals(0, 1), name = "total")`.

```
> debug("debug_target")
> break_at("debug_target::add_step")
> wait_stop(3000)
> columns(stack(0), frame, procedure)
frame  procedure
    0  debug_target::add_step
    1  debug_target::count_rounds
    2  debug_target::run_rounds
> value(0, 0, "debug_target::shape.size")
> step(0)
> detach()
```

### The variables and the types

- **The object of a module.** The service takes the hash of each module of the process from the module report, and uses only the debug object with that hash. With no such object it shows the module and the offset of an address, and an export that needs the object gets `Absent`, `Debug_Objects`.
- **A variable of the innermost frame.** The service takes the variables of the procedure that holds the instruction (`debug_object.variable_range_of_offset`), keeps those that are visible there (`debug_object.variable_at`), and reads each value by its variable location: a register of the register image, or memory at a register plus an offset. A variable whose range there is of the kind `Not_Readable` is shown as "not readable". The service computes no location that the table does not give.
- **A variable of a frame of a caller.** The instruction is the byte before the return address. Only the frame pointer of that frame is known, so only a variable location from the frame pointer is read; each other one is shown as "not readable in this frame".
- **Before a procedure set its frame pointer.** At the first instruction of a procedure, and after its `push rbp`, the frame pointer is still the one of the caller. A variable location from the frame pointer is shown there as "not readable: the procedure did not set its frame pointer yet".
- **A path.** A name, then steps: `.field`, `[number]`, `^` (`pair.next^.first`, `table[3]`). The name is a variable that is visible at the instruction of the frame, else a global. A global is named with its package (`debug_target::rounds`); a name with `::` needs no held thread. As in the language, the field of a pointer to a record is the field of the record. A path has 8 steps at most.
- **A value by its type.** An integer in decimal; a boolean; a float as its bits in hexadecimal ("float bits 0x3ff8000000000000"), because the system has no code that writes a float in decimal; a pointer and the address of a procedure as an address, with the procedure or the global that holds it, and `nil` for 0; an enumeration by the name of its value, or its number with "(no name)"; a record as `{field = value, ...}`, 8 fields and 3 records deep at most; an array as `[value, ...]`, 8 elements at most, then its count; a string by a second read of memory, 64 bytes at most, with "." for a byte that is not printable; a slice as its count and its address; each other type as its size. The service follows a pointer only when the path asks.
- **A global.** Its address is the address where the module is mapped plus the address of the global table (`debug_object.global_by_name`).
- **The stack.** Each procedure that the compiler wrote keeps the frame pointer: the word at `rbp` is the frame pointer of the caller and the word at `rbp` + 8 is the return address. The walk needs no table. It ends at a frame pointer of 0, at one that is not a multiple of 8, at an address that the process does not map, at a frame pointer that is not above the one before it, at a return address of 0, or after 32 frames. At the first instruction of a procedure the return address is the word at the stack pointer, and after its `push rbp` the word above it: the service knows the start of the procedure from the debug object. A procedure of an assembler file can keep no frame pointer: the walk skips its caller or ends there.
- **The source lines.** The debug object holds, for each source file, its path and the BLAKE3 hash of its content at the build (`debug_object.source_line_of`). It holds no source text, and the system has no source file: `source` gives the path, the line and the hash. A reader that has the sources shows the line only from a file with that hash.

### Debugging from another machine

Debugging from another machine needs no mechanism of its own.

- **The service `remote` carries the exports.** `remote` carries a call of an export over QUIC from another machine to a service that it can connect to (`QUIC.md`, section 7). `debugger` is one of them. On the host, `modustool call <key> "debugger.attach(\"clock\")"` calls an export against a machine that `modustool run` started, and prints its table.
- **Who the caller is.** The caller is `remote`, through a connection for one row of the client table: the root service applies the rule of "Who can debug which process" to `remote`, with the principal of that row, the principal that allowed the key of the client (`PRINCIPALS.md`, "The client keys of remote"). `remote` holds the grant to act for the principal, and grants Network, Connect and Remote_Clients, which reach things of `remote` alone: so a client on another machine debugs exactly the processes with no grant, in the session of the principal that allowed its key. Each other process is refused. The connection adds no right; `revoke("remote", "acts_for_principal")` ends each debugging of the host, and the end of the grant of a client key ends the connections to services of that key, and the debuggings with them.
- **What the host can do.** For a process with no grant, a client whose key a principal allowed reads each byte of its memory and each register, writes its registers, and so chooses what the process runs. With the handles of that process it draws in its window and reads the keys and the pointer events that the compositor sends to it. The clients of one principal are the one caller `remote`: they share one debugging, and one can steer or detach the debugging of another (`QUIC.md`, section 7, "Who may call").
- **The time of a call.** `remote` ends a call that takes more than 5000 ms, and with it its connection to the service: the root service then ends the debugging. Each export of the service has a bound under that time ("The bounds of the exports"). `wait_stop` waits 3000 ms at most: a caller on another machine calls it again, or reads `events()` after the line of the stop in the log.
- **The source line.** `modustool call` prints, after a table whose record has the fields `path`, `line` and `hash`, the text of each line from the file of the repository, only when the file has that hash: "source: src/modules/tests/debug_target/main.odin:79: ...". With another hash it says that the file changed since the build. A path that is absolute, that has a part `..` or that names a file of the compiler is not read.
- **Where the debug objects are.** In the debug image of the debugged machine: the service names each address there. The module of a disk process is not in the debug image: at `attach`, the service reads its debug object from the store `module_files`, beside its module file, through a connection that reads only and that the root service gives with the debug access (`MODULE_CONTRACT.md`, "The debug object of a disk process"). A caller on another machine can also read raw values (`registers`, `memory`) and name them with its own debug objects, by the hash of the module.

### The test

`modustool test debugger` runs two machines. The first one is the contract of the kernel (the process `debugged`). The second one is the commands: the console starts the process `debug_target`, which has no grant and values that the test knows, and waits for exact rows: a breakpoint by a procedure name and by a file and a line, the frames of the stack, a local variable of a caller, the fields of a record inside a record, an element of an array, the name of an enumeration value, a text, one step, one line, a watch of a global, and the detach. Then the rule: a process with a private store, a service and a device service are refused; a process with a right of the machine is given, the revocation of the grant `machine` of the console ends its debugging, and a new attach is refused; the revocation of the grant to act for the principal, while a thread is held, gives the process back. Then the same exports from the host through `remote`, with the source line that the tool reads in the repository. The parts with no kernel operation have host tests (`src/library/internal/debugger/debugging`).

### The window of the debugger

The process `debugger_window` shows the rows of the service in one window, with a key or a click for each act: a developer needs the console for no act of the debugger. Start it from the start menu, or with `start("debugger_window")`.

![The window of the debugger, attached to a process, with the frame of the caller of a held thread](screenshots/debugger_window.png)

With no process attached, the keys type a name in the name field, then Enter attaches. With a process attached, and no focus in the debug place field:

| Key | What it does | The export |
|---|---|---|
| up, down | Chooses a thread | `threads` |
| page up, page down | Chooses a frame of the chosen thread | `stack`, then `locals` and `source` |
| `h` | Holds the chosen thread | `hold` |
| `r` | Lets it run | `release` |
| `c` | Lets each thread run | `continue_all` |
| `s` | One instruction | `step` |
| `l` | One source line | `step_line` |
| `o` | One source line, over each call | `step_over` |
| `b` | Puts a breakpoint at the source line of the chosen frame | `break_at` |
| `0` to `3` | Removes the breakpoint with that number | `break_remove` |
| `g` | Shows the registers of the chosen thread in the card of the variables, or the variables again | `registers` |
| `d` | Detaches | `detach` |
| Escape | Takes the focus from the debug place field: the keys above act again | |

**The debug place field.** A debug place is a text that names a place of the debugged process, as the console gives it to the export. A press on the field gives it the focus; then each key is a character of the place. Three buttons beside the field take its text:

| Button | The debug place | The export |
|---|---|---|
| break at (or Enter in the field) | A procedure (`debug_target::add_step`), or a file and a line (`src/modules/tests/debug_target/main.odin:82`) | `break_at` |
| watch | An address (`0x403010`) or a global (`debug_target::rounds`). A last word `1`, `2`, `4` or `8` after a space is the bytes of the watch: 8 with none | `watch` |
| memory | An address or a global: the memory view shows 128 bytes from it | `memory` |

A breakpoint or a watch that the service took empties the field: its text is in the card of the breakpoints. The memory view keeps the text in the field. The service parses the place: a place that it refuses gives the code of its error on the status line.

**A click on a row** does what a key does: a row of the threads chooses that thread; a row of the stack chooses that frame; a row of the source puts a breakpoint at its line; a row of the breakpoints removes that breakpoint.

![The window of the debugger with a breakpoint and a watch at typed places, and the memory view of a global](screenshots/debugger_window_memory.png)

The top band holds the name field, or, with a process attached, the state label (the process and the state of its chosen thread), the debug place field and its three buttons. Under it, two panes with a divider between them: a drag of the divider moves it. The left pane: the threads, each with its number, its state and its place in three columns; under them the breakpoints and the watches, each with the number that removes it. The right pane: the source line of the chosen frame; the memory view, each row an address, 16 bytes in hexadecimal and their printable characters; the stack of the chosen thread; the variables of the chosen frame in three columns (the name, the type and the value), or the registers of the chosen thread in as many columns as the card holds. A thread that runs has no stack to read: the cards say so, and `h` holds it. The window reads the threads and the memory view again each 500 ms, so a thread that stops at a breakpoint shows as stopped with no key, and a byte that the process writes shows at the next read. The status band above the action bar says what the last act did, or the code of an export that failed, and how the debug place field reads its text.

The principal resizes the window from 912 × 600 to 1440 × 960. The layout tree (`src/md/features/box_layout.md`) places each part at each size, with the element tokens of the appearance: a taller window gives the source and the cards of the stack and the variables more rows, and each pane keeps its least width (a row of the threads, a row of the memory view) while the window has room for both.

**What the window holds.** A connection to the service `debugger` and to no other service, the boot image to read the description of the exports of that service, and the grant to act for the principal, which the service asks of each caller. It holds no right over a process. The service debugs one process at a time: while the console is attached, the window attaches to nothing, and the other way.

**The records.** The window reads the rows by the layout of the records of the service. At its start it compares the size of each of those records with the description in the file of the service; when one differs it attaches to nothing and says why.

## The debugger: the design

The reasons of the form of the debugger. What is built is in "The debugger" above.

- **The commands are exports of a service, not code of the console.** A window, another process and a developer on another machine then use the debugger with no second implementation, and each result is a table that the caller combines with the generic commands of the console.
- **The serial port is not used.** The serial port is the log of the kernel. A second protocol on it would be a second way into the machine, with no grant and no connection that proves who calls.
- **The debugger injects no thread and no code into the process**, and writes no byte in its code: the kernel gives it the four parts below, each a right, a command or an argument of an operation that exists.

### What the kernel gives a debugger

Four additions, each a right, a command or an argument of an operation that exists: the count of operations does not change. Each one is built; its rules, its locks and its interleavings are in `ARCHITECTURE.md`, "The debugger of a process".

1. **Who may debug whom.** Property 20, line 2: "Debug access is a handle to one process". The grant is a right of a process handle, `Debug`, and a command of the root ring, `Debug` (a name). The root service gives the handle of the process with `Debug`, and no other right, to the debugger service, on behalf of a caller, by one rule over the grants of the process and of the caller ("Who can debug which process"). Two holders have `Debug` on a process, and no other: the debugger service, by this command, and the creator of the process, on the handle that the creation gave it, as it has the memory that it maps in that process (the test process `debugged` debugs its own children so). A thread of the process is named by its number and this handle.
2. **The faults of the debugged process go to the debugger.** A process names one of its own threads as its fault handler (`ARCHITECTURE.md`, "The fault ring"). The fourth argument of `Fault_Handler_Set` is a process handle with `Debug`: then the handler thread of the caller receives the faults of the kinds `Debug` and `Breakpoint` of that process, before the handler of the process itself, and `Fault_Answer` takes the same handle, with the answer `Resume` only. The ring stays in the thread record of the handler: the debugger pays for it. When the debugging ends (a detach, the end of the handler thread or of its process, the close or the revocation of the handle, the stop of the debugged process), the kernel removes the breakpoints of each thread, clears the trap flag that the debugger wrote, takes back the stops that the debugger made, and resumes each thread that waits for its answer: a debugger that ends never holds and never stops the debugged process. The debugger injects no thread and no code into the process.
3. **Breakpoints, with no write to the code.** The code of a module is shared: each process of the module maps the same pages without Write (`MODULE_CONTRACT.md`, "2. Loading"). A byte `CC` in those pages would stop each process of the module. `Memory_Protect` only takes rights away, and refuses an object that another process names (`Object_Shared`). A private copy of one page for one process needs a page of a mapping that differs from its memory object: the kernel keeps the state of a page in the slots of the object, not in the mapping, so that is a new structure of the kernel. The least addition is the debug registers of the processor: two commands of `Thread_Control`, `Read_Breakpoints` (Inspect) and `Write_Breakpoints` (only the debugger of the process, through its handle with `Debug`), with four breakpoints for each thread (`op.Thread_Breakpoints`): an execute breakpoint at an instruction, or a data breakpoint on 1, 2, 4 or 8 bytes that the thread writes, or reads or writes. The kernel checks that each address is below `USER_END`, writes only the local enable bits of `DR7`, and loads `DR0` to `DR3` and `DR7` at the switch to a thread that has them (one flag of the thread: the others pay one test). An execute breakpoint is a `Debug` fault before the instruction; the record gives the debug status in its error code (`op.DEBUG_STATUS_BREAKPOINTS`, `op.DEBUG_STATUS_STEP`), so the debugger knows which breakpoint; the answer `Resume` sets the resume flag, so the instruction runs once. A breakpoint is of one thread: it never appears in another process. The limit: four breakpoints for each thread, and a thread that the process makes later has none until the debugger sets them.
4. **The bytes of the debugged process.** No report reads the memory of another process (section "What `inspect` does not read"). A command of `Thread_Control`, `Read_Memory` (Inspect and Write: a thread handle with Inspect only sees the thread, it does not read secrets), copies at most 4096 bytes of the process of the thread, from the pages that the process maps, can read and that have a frame (no read gives a frame to a page). It gives the count of bytes before the first page that is not so, and `Bad_Address` when that page holds the first byte or the range is not below `USER_END`.

## What `inspect` does not read: the bytes of another process

The right **Inspect** on the machine shows how every process runs, but it must not show what a process holds: its keys, its documents, its passwords. So the kernel removes from a report each value that can come from the memory of the process. The rule and its reason follow.

The reports give counts, places, states and the stack trace. The stack trace comes from the stack of the process: with a chain of frame pointers that the process broke, a frame holds a word of its memory, and the address of a page fault can be a value that the process computed. The holder of the process handle with Read reads the whole stop report. For a holder of the machine with Inspect, the kernel gives a frame only when a module record of the process holds its address (else the frame is zero, and the tool shows "not code"), and the address of the fault only when it is in the first page or in a module record (else 0); the report counts the values that it took out (`hidden_value_count`). So no report through Inspect gives a byte of the memory of a process. To read the bytes of another process is a stronger right than Inspect: a tool with it reads the secrets of that process (property 20, line 2: "Debug access is a handle to one process. The process that created a process holds it for that process [...] For each other process, the principal grants it"). That right is `Debug`, a right of the process handle (one process, not the machine), that the creator of a process holds on its handle, and that the root service gives to the debugger service on behalf of a caller, visible in `grants()` and revocable ("Who can debug which process"). `inspect` does not have it: its hex view shows the memory of `inspect` itself.

## The cost

A tool that watches the system must not slow it in proportion to what it watches. Each report is built from counts that the kernel keeps anyway, so a sample costs the same for a small process and for a large one.

A sample makes one kernel entry for each report: the process reports of the list (one for each slot), and the mappings, the modules, the threads and the stop report of the chosen process. Each report costs one read for each mapping, thread or module: the pages with a frame are a count of each mapping, not a walk of the page table, so a process that maps 1 GiB 128 times costs the same as one that maps 128 pages. The test build checks the count against the page table at each unmap, in the walk that the unmap makes anyway. The window and the log give the measured time and entries of one sample.

## The comments of the sources

A comment must stay true for a reader who has only the source file. A number of a working record (the number of a property, the label of a review finding) means nothing to that reader, and it goes stale when the record changes. So a check refuses those numbers, and a comment gives its reason in words.

### What the check refuses

`modustool check` reads each comment of the sources and refuses a comment that names a property, a choice, a step, a review or a decision by its number, its label or its date. A comment gives the reason itself, in plain words. When the reason is long, a pointer names a document and its heading, as `(docs/MODULE_CONTRACT.md, "Did not fit, across calls")`, or a numbered section, as `(docs/CONSOLE.md, section 3)`.

The check reads the `.odin`, `.asm` and `.nix` files of `src/modulus`, `src/boot`, `src/runtime`, `src/library/modus/contract`, `src/library/modus`, `src/library/internal`, `src/modules` and `tools`, with their tests, and `flake.nix`. It reads a comment with the scanner of the site (`tools/modustool/foundation/site_source_readers.odin`): the lines of comment that follow each other are one text. A form that a line break cuts is found, at the line where it starts. A string of the code is not a comment.

| Form | Example | Message |
|---|---|---|
| A property by its number | `(property 14)`, `(properties 2 and 20)` | a property by its number |
| A property by its short label | `(P20)`, `(P13;`, `(P20):` | a property by its short label |
| A choice by its number | `(choice 186)` | a choice by its number |
| A step by its number, of two digits or more | `step 91`, `the step after 309` | a step by its number |
| A finding of a review | `finding W8`, `findings W4 and W-new` | a finding of a review by its label |
| The label of a finding alone in a parenthesis, of the letters B, C, F, K, N, W | `(N2)`, `(W-new)` | a finding of a review by its label |
| The label of a finding at the start of a comment, then a colon | `W2: outside recovery`, `F1 and F2: a RST` | a finding of a review by its label |
| The name of a review | `an independent read`, `the hostile read` | a review by its name |
| A review by its number | `Review 10` | a review by its number |
| A note of a review | `note 1 of the second read` | a note of a review by its number |
| A decision by its identifier | `D-047` | a decision by its identifier |
| Who made a decision | `decision of the coordinator`, `owner decision` | who made a decision |
| A date with "owner", "decision", "decided", "added on" or "coordinator" in the 48 bytes before it | `(owner, 2026-11-11: ...)`, `Added on 2026-11-11` | the date of a decision |

Each comment breach is one line of the output: the file, the line, the words, and what they name. One comment breach fails the check.

### What the check allows, and what it does not see

The forms that the check does not refuse:

- A pointer to a document with a section, a label or a heading: `docs/CONSOLE.md, section 3`, `docs/ARCHITECTURE.md, U3`. The heading in quotes of a pointer is not read: it is the text of a heading, and `modustool site` checks that the heading exists. `docs/PROPERTIES.md, property 10` is refused: the number of a property is not a heading.
- A number in a word, a hexadecimal number, a size, a port, a name of a standard: `P256`, `X25519`, `SHA-256`, `0xC2`, `C2_FIELD`, `4433`, `4 KiB`.
- A step of one digit: the steps of an algorithm or of a scenario (`RFC 6582 3.2, step 4`).
- A date with no word of a decision before it: an example of a format, a test vector, the date of a measure.

The check prefers a comment breach that it does not see to a correct comment that it refuses. It does not see:

- a property by its short label with no parenthesis (`P13` alone), and a label of a finding in a sentence with no parenthesis, no "finding" and no colon at the start (`B1` alone);
- the label of a section of a document with no path (`K2, memory`);
- a step of one digit, and a date of a decision with no word of a decision in the 48 bytes before it;
- a comment `/* ... */`, and a line of a string that runs over several lines (the scanner reads one line at a time).

A file that `src/library/modus/cryptography/origin.manifest` lists is not read: it is taken from the cryptography of Odin, `modustool cryptography-origin` proves that it is its origin with listed changes only, and its comments are those of Odin. A file is exempt only by a manifest that the table of exemptions of `tools/modustool/checks/comment_rule_check.odin` names, with the reason.

The marks of Markdown (next section) are not words: a list item, a mark of bold or a link is not a breach, and a breach in bold or in a list item is still a breach. The host test `comment_markdown_and_the_comment_rules` checks both.

## The form of a documented comment

The comments of the sources are also the reference of the system: the site and the console show them. So a comment that documents a declaration is written in a small part of Markdown, which both can show. The rules below say which part.

A comment above a declaration, on the line of a member of an enumeration, or before `package` is a documented comment: the site shows it on the reference pages (the kernel operations, the types, the modules and their exports, the console, the errors, the context, the grants), and a module carries the one of its package and of each export. A documented comment is Markdown, in a small part:

- **Paragraphs**: lines that follow each other are one paragraph; an empty comment line `//` separates two.
- **Emphasis**: `**bold**` and `*italics*`. A star with a space after it, or between two letters (`2*3`), is a star.
- **Code**: a code span in backticks. A span that names a declaration, a kernel operation, an error kind, a module or a command links to it by itself: this is the usual form of a name.
- **Lists**: a line that starts with `- ` or with a number and a period (`1. `). A line right after an item continues it; an item indented by two spaces more is nested.
- **Examples**: a fence of three backticks, with `odin` or with no language: the site colors it as Odin. A run of lines that start with a space, outside a list, is kept as it is and not colored: it is often words aligned in columns.
- **Links**: `[text](target)`, when the text is not the name of what it names. The target is:
  - an address of another host, `https://...`;
  - a term of the glossary, `term:handle`;
  - a guide, `docs/ARCHITECTURE.md`, or a heading of it by the id of the heading on its page, `docs/ARCHITECTURE.md#the-fault-ring`;
  - a kernel operation, an error kind, a module or a command of the console by its name (`Memory_Map`, `load()`);
  - an export of a module, `manual.edges`;
  - a declaration of the sources, `fault_deliver`, `operation.Fault_Record`, `system.word_wait`: a name that several packages declare takes its package.

A comment has no heading, no table, no quote, no line of HTML and no picture: it sits under the heading of its symbol, in a page or in a cell of a table, where a heading would break the outline of the page and a table would not fit. The site shows these lines as words of a paragraph.

A link is a claim of its author: `modustool site` stops on a link whose target names nothing, with its file and its line, as it stops on a pointer whose heading does not exist. A code span that names nothing stays code.

A module carries the same text, with its marks, and the process `manual` reads them in the system (`MODULE_CONTRACT.md`, "Description tables"): a bold word is in the bold weight, a word in italics has a thin line under it, a code span is in the font of the cells, a list item has its mark and its indentation, an example is a block, and a link is a colored name. The help of an export is the first sentence of the comment with the marks removed: the console prints it as one plain line. So the first sentence of a comment must read well with no mark.

The documentation of the kernel operations is the model: for each operation, one sentence that says what it does, its arguments as a list, its results, its statuses as a list with when each comes, the rights that it needs in bold, links to its records and to its guide, and an example call through `src/library/modus/system` when one helps.

## The record outputs and the record inputs of the build

The tool reads each declaration of `system.Record_Output(...)`, `system.Record_Input(...)` and `system.Record_Input_With_Terms(...)` in the sources that the compiler read for a module, and writes the tables `Record_Outputs` and `Record_Inputs` of the module file, sorted by name, with the record of each one in the table `Records` (`docs/MODULE_CONTRACT.md`, "The record outputs and the record inputs"). The comment before a declaration gives its line of help and its text. It has no type checker, so it refuses, with a message that names the source and the line:

- a declaration of one of the two types that is not a package variable of the package of the module: a local variable, a constant, a type, a field of a record, a composite literal, a parameter by value, a declaration inside a `when`, a variable of another package that the module compiles in. A parameter that takes a stream by its address declares none;
- a record or terms type that is not a record type of the package or of an imported package of the library, `system.Any_Record` as the terms, a record with padding or a Handle field;
- arguments past the parameters, a name that names no parameter, a parameter given two times, no record type, no terms type in `Record_Input_With_Terms`, terms in `Record_Input`, and a pairing or a count that is not a member written `.Member`;
- `.Paired` on a record output that is not generic, and `.Many_Types` on a record input that is not generic;
- two record outputs, two record inputs, or a record output and a record input with one name;
- a generic record output in a module with no generic record input, or with two;
- more than 65 535 record outputs or record inputs, and a record whose name the module describes another way.

The tool checks each module file that it writes with `module.record_streams_check`, the reader of the root service. `modustool test descriptions` compares the two tables of each module with its sources, and prints one line for each declaration: "the record output server.requests of the record Access_Record comes from its source". The host tests of `tools/modustool/build` (`record_streams_test.odin`) give each refused form and check the refusal.

## The intent folder

The folder `src/md` holds the intent files (`glossary/project.md`, "Intent file"): one Markdown file for the design of each part of the system, by the standard of [srcmd.org](https://srcmd.org). Its entry point is `src/md/README.md`: an overview of the system, the points that a newcomer gets wrong, the rules of the form of a file (`src/md/README.md`, "The rules of this folder"), and the file index.

**Why a check.** A reader who starts work on a part reads the file index first, and opens only the files that it lists. A file that the index does not list is a design that nobody finds. An entry with no file sends a reader nowhere. Both faults come from a change that touched one side only, so a check keeps the two the same set.

`modustool check` runs `intent_index_check` (`tools/modustool/checks/intent_index.odin`). It reads each `.md` file of `src/md` and of its folders, and refuses:

| Fault | Message |
|---|---|
| `src/md/README.md` is absent | "does not exist: the intent folder has no entry point" |
| The README has no heading `## File Index`, or more than one | "has N headings "## File Index": it has exactly one" |
| A line under that heading is not one link and a description, `- [path](path): description` | "a line of the file index is one link and a description" |
| An entry is not a path from `src/md` (it leaves the folder, or it is an address) | "is not a path from the intent folder" |
| An entry names a file that the folder does not have | "names no file of the intent folder" |
| An entry names the README | "the file index lists the other files, not itself" |
| A file of the folder is not in the index, or is there two times | "is not in the file index", "is N times in the file index" |
| The first heading of a file is not a heading of level 1 | "the first heading of the file is not a heading of level 1" |
| A relative link of a file names no file of the repository | "the link to ... names no file of the repository" |

The section of the index ends at the next heading. A line inside a fence of code is an example, and a link inside a code span is not a link. A link to an address of another site, and a link to a heading of the same file, are not read.

**The pointers of an intent file.** An intent file names a guide with a link whose text is the path of the guide, then the heading in quotes:

```
[`docs/CONSOLE.md`](../../../docs/CONSOLE.md), "8. The palette provider"
```

The link opens the guide for a reader of the repository. The labels after it are those of a document pointer, and the check of the pointers of the site reads them with the same rule (`site_document_pointer_problems`, which `modustool site` and the host test `site_document_pointers_of_the_repository` run): a heading that the guide does not have stops the command. A link to a Markdown file that is no document, with a heading after it, stops the command too: it is most often a link with a wrong count of `..` (a file of `src/md/features` is three folders under the root, and `src/md/README.md` is two), and its heading must not pass unread. A code span of an intent file that names a document is checked as a code span of a guide is.

**A pointer to an intent file.** An intent file is a working record: the site does not publish it. A comment of a source and a code span of a guide name one by its whole path, `src/md/features/palette.md`, with the labels of a place after it. On a page, the reference links to the file in the repository, at the line of the heading. A pointer to a file that the folder does not have is a stale pointer, and stops the command. The name of an intent file has letters, digits and `_`, so that a path in a sentence ends where the name ends.

**What the check does not prove.** It reads the form, not the content: a file that is listed and that says what the code no longer does passes. A design that changes with no change of its intent file passes too. That rule is held by the review of a change.

## The source paths in the documents

A code span of a document that names a file of the repository is a link on the site. A span whose file is gone stays plain code, with no error: the link is lost in silence. A source that moves, or that gets a new name, must change each document that names it. `modustool check` runs `source_paths_check` (`tools/modustool/checks/source_paths_check.odin`), which is the proof of that change.

**What it reads.** Each document of `docs/` but the records of their time, `README.md`, `AGENTS.md`, and each intent file of `src/md`. In them, each code span outside a fence of code, also a span of a heading.

**Which span is a source path.** A span that starts with the path of a folder of the sources, or with the last part of that path, then a `/`. The folders of the sources are the constants of `tools/modustool/foundation/source_folders.odin`. The last part is the name that a folder had before a move: a span that still starts with it is read, and is refused, so an old path cannot stay in a document. The first part of a path that has more parts is not a start: under it, an intent file names a folder of a later state or of a refused form, and such a span names nothing on purpose.

A span that starts with `tools/` is read too: the tool is no source of the system, but a guide names its files, and a file of the tool that moves into a package must change each document that names it. A future folder of the tool is then named in words, not in a span.

| Span | How the check reads it |
|---|---|
| `src/modulus/enter.odin`, `src/library/modus/system`, `tools/modustool/main.odin` | A file or a folder: it must exist |
| `src/modulus/enter.odin:34` | The path before the `:`. A line number is not checked |
| `src/modules/system/*/main.odin`, `src/modules/system/<name>/main.odin` | A name that is not written out ends the path at the folder before it: `src/modules/system` must exist |
| `build/modules/x`, `docs/reference/modules/` | Not a source path: the name of a source folder is inside a longer path |
| `modustool check`, `kernel`, `"modus:contract/ring"` | Not a source path: the span does not start with the name of a folder and a `/` |

A path is read from the root of the repository. A path that names nothing gives the document, the line and the span. When the path exists under the folder of its first name, the sentence gives the new path.

**What it does not read.**

- A fence of code: it holds a tree, a command or a log, not a pointer.
- A path in running text, outside a code span. The site makes no link from it.
- The news entries and the changelog.

**What the check does not prove.** It proves that a path names something, not that it names the right thing. A span that names a package and a declaration in one text, a folder then `.` and a name, is read as a file and is refused: write the declaration and the folder in two spans.

## The imports of the sources of the system

The system has three source libraries (`modus`, `internal`, `modulus`), and the compiler accepts each package of `modus` in each source: an import of a support package compiles in the kernel, and so does an import of a package of the core library. Six rules are then held by the tool, with `library_imports_check` (`tools/modustool/build/library_imports_check.odin`): a source that is not a test imports no package of the core library, which reaches the host; the kernel imports no support package and no internal part; a kernel part is imported from the kernel only; an internal part is imported from its module only; a support package has two owners or more (or one owner of the group `libraries`); and no relative import lands in the folder of a module from outside it, in `src/` or in `tools/`.

**The kernel parts.** A kernel part is a pure package in a folder under `src/modulus`, with host tests: `iommu`, `acpi_processors`, `debug_exception`, `processor_counters`, `stolen_time`, `time_base`, `delivery_count`, `replay_filter`, `software_exit`. It is imported through the source library `modulus`, with the flag `-collection:modulus=src/modulus`: `import "modulus:iommu"`. The tool gives that flag to the compile of the kernel, to the host test of each folder under `src/modulus`, and to its own compile, because two fuzz targets and the depth of the kernel stack read two kernel parts. No other module and no other host test gets it, so the compiler refuses a kernel part there. The check refuses it too in each file of `src/` outside `src/modulus`, because a language server gives one set of source libraries to every folder.

**The rule of each file.** Each import of each source file of `src/` names one of these, and nothing else:

| File | Imports allowed |
|---|---|
| A source of `src/modulus` or of a kernel part that is not a test | A package of `base:`, a contract package, or a kernel part (`modulus:<part>`) |
| A test of `src/modulus` or of a kernel part | The same, and a package of `core:` |
| A source of `src/library/modus/contract` that is not a test | A package of `base:`, or a contract package |
| A test of `src/library/modus/contract` | The same, and a package of `core:` |
| Any other source of `src/` that is not a test | A package of `base:`, of `modus:`, or of `internal:` (its own module only) |
| Any other test of `src/` | The same, a package of `core:`, or a relative path of the repository that does not land in `src/modulus` or in the folder of another module |
| A file that `src/library/modus/cryptography/origin.manifest` names | A package of `base:`, of `modus:`, of `core:`, or a relative path of the copy |

Each other import is refused:

- a package of `core:` in a source that is not a test: it reaches the host, and the system runs on the machine;
- a support package or an internal part in a source of the kernel or of a contract package (`"modus:sentence"`, `"internal:console/console_stream"`);
- a kernel part in a file outside `src/modulus`: `"modulus:iommu"` in a module, a support package, a contract package or their tests, and a relative path that lands in `src/modulus` (`"../../../modulus/iommu"` in a host test of a support package), which the compiler reads from the folder of the file and accepts in a host test;
- `"modulus:"` alone and `"modulus:."`, which name the package of the kernel itself, and a part `.` after the name of a library (`"modus:contract/./ring"`), a second spelling of a package;
- a relative path in a source that is not a test, and in any file of the kernel or of a contract package (`"../../sentence"`);
- a relative path that lands in the folder of a module, `src/modules/<group>/<module>` or under it, from a file outside that folder: from a host test of `src/` (`"../../../modules/libraries/cryptography"`) and from a file of `tools/` (`"../../src/modules/libraries/cryptography"`). The check reads each file of `tools/` for this rule alone, and resolves the path from the folder of the file. The code that a module and a host program both need is a support package of the public library or an internal part of the module (below). A foreign import is not this rule: a host test links the assembly of `src/runtime` by a relative path;
- a path with `..` after the name of a library (`"modus:contract/../sentence"`, `"modulus:../modules/demonstrations/clock"`);
- a package of another library, the vendor library of the compiler too.

**The internal parts.** An internal part is a package that one module alone compiles in, with its host tests, in `src/library/internal/<module>/<part>`: `import "internal:storage/storage_tree"`. The check refuses an import of an internal part from any file of `src/` other than the folder of its module and the internal parts of the same module, its host tests too, and a path whose `<module>` names no module of the table of the modules or that names no part. The boot program, which is no module, has its internal parts in `src/library/internal/boot_program/<part>`, imported from `src/boot` only. One reader more is allowed: a host test may import an internal part of a module of the group `libraries`, because a host program cannot load a module, and such a test stands in for the module whose exports its package calls. The tool is outside `src/`: it reads some internal parts, as the disk images of the storage service, and is no reader that the rule counts.

**The owners of a package.** The owners of a package of the libraries are the bodies of code (the kernel, the boot program, each module) whose chain of imports reaches it; a test is no owner. A support package, with each folder under it, has two owners or more, or one owner that is a module of the group `libraries` (`modus:cryptography_primitives`, the code of the exports of the module `cryptography`, which a program outside the repository compiles in); an internal part has its module as its one owner. The check counts owners, never importing files: a package that a module and an internal part of that module import has one owner. A refusal names the folder of the package and its one owner:

```
modustool: src/library/modus/alone: only console reaches this support package: a support package has two owners or more, or one owner of the group libraries, and a package of one module is its internal part, in src/library/internal/<module>/
```

**The build line of a host test.** A test that imports a package of `core:` runs on the host: its first build line is `#+build !freestanding`, so that no build of the system reads it. A test with no such line is refused, with its file and the line of its first import of `core:`.

**The copy of the cryptography of Odin.** `src/library/modus/cryptography/origin.manifest` names the files that the system took from the cryptography of Odin. They keep the imports of their origin, and `modustool cryptography-origin` proves that nothing else changed. A file that the manifest does not name follows the rule of its folder.

**A kernel part is pure.** The same parser walk reads each source of a kernel part that is not a test, so that its host tests run each procedure with no machine. It refuses, with the file and the line:

- a package variable with no `@(rodata)`: the compiler refuses a write to a variable that is `@(rodata)`, and the memory of the machine refuses a write through a pointer to it, so the attribute is the whole check;
- a variable marked `@(static)` or `@(thread_local)`, which keeps state from one call to the next;
- a foreign import and a foreign block, which link to code outside the part;
- an asm template;
- an intrinsic that reads or changes the machine (`read_cycle_counter`, `volatile_`, `non_temporal_`, `atomic_`, `cpu_relax`, `x86_`, `arm64_`, `wasm_`, `syscall`, `trap`, `debug_trap`, `prefetch_`, `objc_`, `valgrind_` and the names that start with them), under any local name of `base:intrinsics`. An intrinsic that computes a value from its arguments (`count_ones`) stays open.

The package of the kernel itself holds the state of the kernel, and this rule does not read it.

**Why this is complete.** If no file of `src/` imports outside its list, no chain of imports from the kernel reaches a support package, and no source that a build of the system reads imports a package of the core library.

**What it reads.** Each `.odin` file of `src/` and of each folder under it, with the parser of the library of the compiler. It reads more than the compiler compiles: a host test, a file that a build tag leaves out, and an import inside a `when` whatever its condition. The check is stricter than the compiler, never looser. A file with an error of syntax is refused as a file, because the parser does not read it whole. A foreign import names a file of assembly or an object, not a package: the check does not read its path, and refuses it only in a kernel part.

**When it runs.** Before the first compiler of each build starts: `build`, `test`, `run`, `measure`, `screenshots`, `film`, `repeat`, and `module <name>` with no step. `modustool check` runs it first, and `modustool library-imports` runs it alone. A refused import, and a test with no build line, stop the build with the file, the line and the text:

```
modustool: src/modulus/serial.odin:12: the import "modus:sentence" is refused: a source of src/modulus imports a package of base:, under modus:contract/ or under modulus:, by a path with no ".."; the kernel imports no support package and no internal part
modustool: src/library/modus/sentence/parse_test.odin:4: the test imports "core:testing" and has no build line: a test of src/ that imports a package of core: starts with "#+build !freestanding", so that no build of the system reads it
```

**What it does not prove.** It does not prove that a contract package uses no kernel operation: that rule is held by review.

## The table of the start grant sets of the root service

The root service gives each process of the boot image the start grant set of its row in the table `start_grant_sets` (`src/modules/system/root/start_grant_sets.odin`): its start grants and the other terms of its start grant set. A name with no row gets the zero start grant set, so the tool keeps the table whole (`tools/modustool/build/start_grant_sets_check.odin`). It reads the rows with the parser of Odin and refuses:

- a module of the boot image (a row of the table of the modules marked `entry`, in the boot image, not the module of a disk process) with no row, the root service apart;
- a row that names no module of the boot image, a disk process or the root service;
- a module with two rows;
- a grant that is no member of `start_grant.Grant`;
- the grant System_Part on a row that the list `system_part_names` of the same file does not name, a name of that list with no row, and a part of the system whose row is not System_Part alone, with Serve beside it for serving system parts (`compositor`, `powerbox`, `collector`, `plans`, `recipes`, `projects`, `disk_processes`, `devices`, `principals`), and no term: the debug access refuses a part of the system by that grant;
- the grant Start_Policy on a row other than `start_policy`, a row `start_policy` without it, and that row with another grant beside it;
- a row in another form than `{name = "<module>", grants = {.A, .B}, terms = {...}}` with no type, or terms that hold a comment.

**When it runs.** Before the first compiler of each build starts, after the check of the imports, and when `modustool site` reads the table for the page of the grants. A fault stops the build with the file and the line:

```
modustool: src/modules/system/root/start_grant_sets.odin: the process clock of the boot image has no row in start_grant_sets: write its start grant set, with no grant when it needs none
```

The host test `the_table_of_the_start_grant_sets_is_whole` gives each fault to the check, the test `each_start_grant_set_takes_each_context_slot_once` checks that the handles of each row take one context slot each, and `the_layout_of_a_device_service_takes_each_slot_once` tries the ring of a device contract in each slot of the layout of a device service.

## The start lists

Each boot image holds two resources that the start policy reads: `start_list` and `rescue_list` (`src/md/features/start_policy.md`). The rows of each list are a table of the tool (`tools/modustool/build/start_lists.odin`): the default lists, and the one-row lists of the machines of the shortage and of the operation sequences. The tool writes each list through the contract `start_list`, reads it back through its border, and refuses at each build of an image:

- a list that the border refuses: a name that is not a module name, more rows than a list holds, two rows of one module;
- a row that names no module with an entry in that image;
- a rescue list with no row with the mark `Needed`;
- a wiring row that the module files of its two rows refuse: a record output that the writer does not declare, a generic record output, a record input that the reader does not declare or that takes terms, two records that differ, a second row to a record input of one wiring, and a writer that the root service starts by its own procedure;
- a wiring row that the border refuses: a reader row after its writer row, one row at both ends, an end other than the writer and an earlier start row, more than 8 wiring rows;
- wiring rows that need more pages than the reserve of the start policy, `start_list.WIRING_PAGES_RESERVE`.

The wiring rows of a list are a second table of the tool, beside its start rows: each names the writer row, its record output by its name (or `log`), the reader row and its record input. The default list wires `wired_writer.numbers` to `wired_reader.numbers`. The tool reads the module files of the two rows, which the build wrote before the image, and writes the indexes of the two streams into the row.

The list of the image `missing_console` has a row of the console that names a module that does not exist, for the test of the rescue: the build checks that the check refuses it for that row alone, then writes it into that image only. The rescue list of that image adds two rows with 2 restarts each, for the test of the restarts: `stops_refused` stops with the stop outcome `Refused` and the start policy writes that it does not start again, and `stops_failed` stops with `Failed` and starts again with 1, then 0 restarts left, then stays stopped. Only that image holds the two test modules.

**The source of the start policy.** Before the first image is written, the tool reads the sources of `src/modules/system/start_policy`, the tests left out, and refuses more than 400 lines in all, and an import that is not `base:`, `modus:contract/start_list`, `modus:contract/root_ring`, `modus:contract/ring`, `modus:contract/operation`, `modus:contract/value_kinds`, `internal:start_policy/wiring_rows` or `modus:system`: the start policy reads a list in its order and holds no logic of its own. The contracts `operation` and `value_kinds` give the types of the fields of its log facts. The tool also refuses in `src/library/internal/start_policy/wiring_rows`, the tests left out, each import that is not `base:` or a contract: that part makes no call of the kernel, so its host tests reach each of its decisions. The host tests `a_start_list_that_is_not_valid_is_refused`, `a_wiring_row_that_the_module_files_refuse_is_refused` and `a_start_policy_past_its_bound_is_refused` give each fault to the checks.

## The rules that a check holds

These rules of the system are checked when the tool builds, not only read.

**The count of the kernel operations.** `PROPERTIES.md` states how many operations the kernel has, in the sentence "The kernel has <number> operations". The enumeration `Operation` of `src/library/modus/contract/operation/operation.odin` declares them. The tool counts the members of the enumeration, without `None`, and compares the two numbers. A new operation is then refused until the property states the new count, with its reason.

**No source of the system calls an allocator.** A process has no heap: its memory is a mapping that it asks the kernel for, or a variable of its module. The tool reads each source file of the kernel, of the boot program, of the modules and of the source library that is not a test, and refuses a line that calls `make`, `new`, `new_clone`, `delete`, `free` or `free_all`, or that names `context.allocator`, `context.temp_allocator` or `[dynamic]`. A comment and the text of a string are not read. A procedure of the system whose name ends with one of these words, as `caller_grant_make`, is not a call of the built-in procedure. The compiler also gets `-default-to-nil-allocator`: with it a call of an allocator fails when the process runs; the check refuses the call before the process exists.

**Each export that fails gives an error record.** A caller reads why a call failed from the error record of the export (`MODULE_CONTRACT.md`, "8. Errors that diagnose"), never from a bare negative number. A negative result can be an answer (`number("-5")` is -5), so the check reads the forms of a failure, not the values. `export_error_record_check` (`tools/modustool/checks/export_error_record_check.odin`) parses each source file of `src/modules` that is not a test, one folder as one package. For each export with an `i64` result, no parameter `error`, and a name other than `entry`, it refuses a `return` whose value is:

- a minus before a literal, a call or a conversion, or before a constant of the package: `-1`, `-i64(status)`;
- a constant of the package whose value is a minus before a literal: `ERROR :: -1`;
- a `?:` or `if else` expression with such a value on one side, such a value in parentheses, or in a conversion to an integer type;
- a call of a procedure of the same package, in any of its files, with such a `return`, at any depth.

A minus before a variable is an answer, and a procedure literal inside the body is another procedure: the check reads neither. A refused `return` stops the check with its place:

```
modustool: src/modules/system/manual/main.odin:618: the export show gives a negative number with no error record: give it the last parameter error: ^errors.Error_Record, and write the record on this path with errors.fail (docs/MODULE_CONTRACT.md, "8. Errors that diagnose")
```

What it does not see: a `return` of a variable that holds a negative number, a helper of another package, and a failure that gives 0 or an empty text. A 0 and an empty text are also answers (`tally.last()` before the first add, `roman(0)`), and the source does not tell the two apart. Review holds them. The design: `src/md/api/export_error_records.md`.

**A closed set of choices is an enum.** A set of choices is an `enum`, never a family of integer constants passed as an integer. A word that carries a choice across a border (a value of the context, a field of a record, a word of a ring) becomes its member at one place, which refuses a word that names no member, and each `switch` on the member names each member. `choice_constant_check` (`tools/modustool/checks/choice_constant_check.odin`) parses each source of the kernel, of the boot program, of the modules, of the source library and of the tool that is not a test. A constant that a file names with the name of an imported package (`modus:`, or `modustool:` for a package of the tool) is a use of the constant of that package. It keeps the constants of each package whose value is from -255 to 255: an integer or a character literal, a negation of one (the answers of an export, `ERROR_NAME :: -3`), or a value computed from them and from other constants of the package (`B :: A + 1`, `KEY_EXTENDED | 0x53`), in a declaration of one name or of several. It refuses two constants or more of one package, with the same first word, or with the same last word when their first word gives no family (`READ_REQUEST`, `WRITE_REQUEST`), that the code uses as choices:

- a value of a `case`, except in a `switch` on `len(...)`, whose cases are quantities;
- an operand of `==` or `!=` whose other operand is a variable, not a constant, with a word of a choice in its name (`mode`, `kind`, `state`, `form`, `level`, `stage`, `strength`, `role`, `phase`, `action`, `origin`, `change`, `step`, `round`, `variety`, `reason`, `request`, `choice`, `strategy`, `answer`);
- a value given to such a name: an assignment, a declaration, a field of a literal, an index (`values[VALUE_MODE]`), or an argument of such a parameter.

A refused family stops the check with its place:

```
modustool: src/library/modus/principals/principals.odin:93: the constants MODE_ of src/library/modus/principals are a closed set of choices (MODE_CHANGE_PASSPHRASE, MODE_CREATE_PRINCIPAL, MODE_NEW_RECOVERY_KEY, MODE_SEAL_MACHINE_KEY, MODE_SET_MACHINE_PASSPHRASE, here a case of a switch): make them an enum, with the values of the contract when the value crosses a border, and one conversion at the border that refuses a value that names no member (src/md/infrastructure/choice_constants.md)
```

A short list of exceptions in the source names the open sets of outside standards (the frame types of QUIC, the protocol numbers of IPv4, the scan codes of the keyboard, the codes of DWARF and of ELF that the tool reads), and the places of the fields of a remote request, each with its reason. An exception that names no family stops the check too.

**A cast of a word to an enum.** The same check refuses a cast of a word to an enum, `Mode(word)`, `cast(Mode)word` or `transmute(Mode)word`, that the code keeps (a declaration, an assignment, a field, a return, an index, an operand of another expression), passes to a procedure, or switches on. A cast accepts each word, so it skips the border: the word becomes a member that the writer may not have named. The check accepts a cast only as one operand of `==` or `!=` whose other operand is a member (`.Ok`, `Status.Ok`, `system.Status.Ok`): the value is compared once and never kept. It knows each enum type of each package, those of a `when` block of a file included, a `distinct` type of one, and an alias of one (`Entry_Kind :: store_contract.Entry_Kind`), through the imports of each file, a relative import included. A cast to a pointer, an array or a slice of an enum (`(^Mode)(&word)^`, `transmute([4]Mode)bytes`) is refused the same way. Each `auto_cast` is refused: its target is a type that the compiler infers, which the syntax tree does not hold, so a conversion names its type. A refused cast stops the check with its place, the enum and its form:

```
modustool: src/library/modus/sentence/error.odin:30: a cast of a word to the enum op.Object_Kind is kept: read the word through its border, which refuses a word that names no member, and pass the member; a cast is allowed only as one operand of == or != with a member (src/md/infrastructure/choice_constants.md)
```

A second short list names the casts of a design, each with its reason: the dispatch of the kernel on the kind of a command record, and the two tests that write a word of no member on purpose (the machine test of an unknown operation, and the peer that breaks a field of a remote request). A row names its file, its enum and its count of casts in the file: another count of such casts in the file, none included, refuses the row and its casts. The tool chooses a member by its place, from 0 (a draw of the fuzzer), with `enum_member_at`, which stops the tool on a place past the last member.

**The stop words.** The same check refuses the forms that skip the borders of the stop of a process (`src/md/api/process_stop.md`):

- a conversion of a word to `Stop_Cause` or `Stop_Outcome` outside the contract package `operation`, in a comparison with a member too: a reader takes the words through `op.stop_of_words` or the library;
- a mention of the operation `Process_Stop` or `Process_State` (`.Process_Stop`, `op.Operation.Process_Stop`), and a conversion of a word to `Operation`, outside the support package `system`, the contract package `operation`, the kernel and the tool: a process uses `system.stop`, `system.process_stop`, `system.process_state`, `system.process_stop_wait` or `system.process_place`, so no variable, call or command record carries the operation;
- `system.stop(.None)`, which the kernel refuses.

An alias of one of the three enums (`Outcome :: op.Stop_Outcome`), a chain of aliases, a `distinct` type and a `#type` of one, in a file or inside a procedure, are the enum for the check. A short list names the faults of a design, each with its file, its kind, its count and its reason: the machine test of the refusals of `Process_Stop` in `address_space`, and the machine test of a kind of no operation in `errors`. Another count in the file refuses the row and its faults. A refused form stops the check with its place:

```
modustool: src/modules/demonstrations/frames/main.odin:144: a mention of the operation Process_State outside the support package system: use system.stop, system.process_stop, system.process_state, system.process_stop_wait or system.process_place (src/md/api/process_stop.md)
```

What the check does not see: a `#partial switch`, a constant declared inside a procedure or a `when` block, an enum declared inside a procedure, a value past 255 on either side of 0, a value computed from a constant of another package, and a family whose members share neither their first nor their last word. Review holds them. The design: `src/md/infrastructure/choice_constants.md`.

**The table of the checked entries of an image.** The check refuses each source of `src/` and `tools/` that names the field `image_checks` of `system.Load_Source` (a read of the field, or the field in a literal), but the loader (`src/library/modus/system/load.odin`), the root service (`src/modules/system/root/main.odin`) and the host tests of the loader. A process that gave such a table could load a file of an image that nothing checked (`TRUSTED_BOOT.md`, "Layer 1: the signed system description").

```
modustool: src/modules/system/console/main.odin:12: names the field image_checks of system.Load_Source, which only the root service gives (src/modules/system/root/main.odin)
```

**A package variable is constant data.** A module with an entry has no start of the runtime: the loader maps its data as the file holds it (`MODULE_CONTRACT.md`, "Package variables are constant data at the load"). `global_initializer_check` (`tools/modustool/checks/global_initializer_check.odin`) parses each source of the kernel, of the boot program, of the modules and of the source library that is not a test and not for the host alone, one folder as one package. It reads the bodies of the `when` blocks too, and not the body of a procedure literal, which runs when it is called. It refuses a package variable whose initializer holds:

- a slice expression (`params[:]`), or the operator `&`;
- the name of a package variable of the same package, in any of its files;
- a name of another package that starts with a small letter (`system.serving`): a variable or a procedure, which the check cannot tell apart; the constants and the types of the system start with a capital letter;
- a call, except a conversion to a type and the built-ins that the compiler folds (`size_of`, `align_of`, `offset_of`, `len`, `min`, `max`) and a directive (`#load`);
- a literal of a map or of a dynamic array;
- a value of the type `any`.

The compiler makes each of these a step of the start of a program, and the variable stays zero on the machine. What the check does not see: a constant of another package whose name starts with a small letter (refused, though constant), a call of a procedure that the compiler folds and that is not in the list, a variable of a `when` block of another file whose condition is false on the machine, and a source that is a host test by its name alone. A refused variable stops the check with its place:

```
modustool: src/library/modus/contract/root_delegation/role_catalog.odin:368: the package variable settings_faces has in its initializer a slice expression: the compiler makes it a step of the start of a program, which a module never runs, so it stays zero on the machine; write the slices as literals inside the table (docs/MODULE_CONTRACT.md, "Package variables are constant data at the load")
```

**A bound of the tests is for a check.** `service_deadline_check` (`tools/modustool/checks/service_deadline_check.odin`) refuses `TEST_HANG_BOUND_MILLISECONDS` and `TEST_PROGRESS_OVERALL_BOUND_MILLISECONDS` in each source of `src/` but a host test, a test module, a demonstration (each is a case of a machine test) and `src/library/modus/system/test_bounds.odin`. A service or a library that waits for another part of the machine names a deadline of its contract from `system.ANSWER_BOUND_MILLISECONDS`, which is not over the hang bound of the tests, so that the line of the service that gives up comes before the report of the check.

**When they run.** `modustool check` runs the eight after the check of the imports, and `modustool rule-checks` runs them alone. A host test of the tool holds the same four conditions on the sources of the repository.

## The reuse list

`CREDITS.md` is the one checked document for reused code, reimplemented algorithms, design inspirations, and upstream funding links. `modustool check` runs `reuse_list_check` (`tools/modustool/checks/reuse_list.odin`), which verifies all three tables of `CREDITS.md` and compares Reused code with the records of the repository. The design: `src/md/infrastructure/credits_and_licences.md`.

**The form of the three tables.**

- `## Reused code`: `| Work | Place | Upstream | Authors | License | License file | Funding |`. `Place` and `License file` are code spans; `License` is an SPDX expression (or `NONE`); every cell is non-empty (`—` for Funding when none is known).
- `## Reimplemented algorithms`: `| Algorithm | Authors | Upstream | Reference license | Place | Funding |`. `Place` is a code span naming an existing path in `src/`; every cell is non-empty.
- `## Inspirations`: `| System or idea | Authors | Took and left | Link | Funding |`. Every cell is non-empty and no two rows share a system or idea name.

**Where the tool finds the reused works.**

| Works | Record |
|---|---|
| The fonts | The three lists of `tools/modustool/resources/vector_fonts.odin`; for each, `resources/fonts/<name>.license`, its line `License of the source: <words>.`, and the license file of the list |
| Spleen 8x16 | `src/library/modus/graphics/FONT_LICENSE`, its line `SPDX-License-Identifier: <identifier>` |
| The pointer themes | Each theme that the build makes (`pointer_theme_builds`) whose manifest has a line `license` that is not the license of `LICENSE` |
| The cryptography of Odin | `src/library/modus/cryptography/origin.manifest`: one line or more gives the work of `LICENSE.odin.txt`; a line under `_fiat/` gives the work of `LICENSE.fiat-crypto.txt` |
| The libraries of the compiler | `base:runtime`, always: the compiler puts it in each module. Each package of `core:` that a source of the system imports, in a file that is not a test and whose first line is not a build tag with `!freestanding`. Their license file is `LICENSE.odin.txt` |
| The portraits | Each row of `resources/hall_of_fame/CREDITS.md` |
| The works in C | Each outside source of the module table (`foundation.outside_sources`): its folder of the repository is the place, the first line of its `LICENSE` gives the license, and that file is the license file |

The words of a record become an identifier through the table `spdx_names` of the page of the licenses (`SITE.md`, "The licenses"). The words "All rights reserved" give `NONE`. Words with no translation give no identifier, and the check then does not compare the license of that row.

**The faults.** Each one gives the line of the document and the place:

- a reused work with no row;
- a row whose place is no reused work: the system does not ship it and the repository does not hold it;
- two rows with one place;
- a license that is not the identifier of the record;
- a license file that is not the file of the record, or that does not exist;
- a row out of its form, and a document with no section "Reuse list".

```
modustool: docs/PROPERTIES.md: the package core:reflect of the Odin compiler (`core:reflect`) is shipped or copied by the system, and the reuse list has no row for it
```

**What it does not prove.** It does not read a license at the source of a work: it compares the list with what the repository recorded when the work was taken. A new source of a work is a new record, in the same commit. A package that an imported package of `core:` imports in its turn is not named: it has the same license and the same license file.

## The similarity finder

`modustool similarity` measures how similar the code pieces of the Odin sources are, and proposes where to factor them. A code piece is a procedure, a run of two or more statements of one block, or an expression (`glossary/project.md`, "Code piece"). The command reads `src/` and `tools/`, groups the similar pieces in similarity families, gives each family its factoring template, and ranks the families by the syntax nodes that a factoring saves. The design: `src/md/infrastructure/similarity_finder.md`.

It runs outside the build and outside `modustool check`, and it can take minutes. It never edits a source and never fails on a similarity: a human or an agent decides what to factor.

**The commands.**

```
nix develop -c modustool similarity
nix develop -c modustool similarity near src/modules/system/console/commands.odin:120
nix develop -c modustool similarity pair src/modules/system/root/main.odin:300 src/modules/system/unlock/main.odin:410
```

- With no argument, it prints the report with the first 30 families of each list and the time of each phase, and writes the whole report and two tables in `build/similarity/`.
- `near <file>:<line>` prints the procedures whose similarity score with the procedure that holds the line is 0.5 or more, at most 20, each with its template and its blanks.
- `pair <file>:<line> <file>:<line>` prints the score of two procedures, whatever its value, with their template and each blank.

**What it does not read.** The copies of the works of others that `src/library/modus/cryptography/origin.manifest` names, and the sources that a command of the tool writes: `src/library/modus/graphics/font.odin`, and each file whose first line starts with `// This file is the output of`. The report lists each file that it does not read, with the reason. It keeps three areas apart in each measure: the system (`src/`, no test), the tool (`tools/`, no test), and the tests (a file `_test.odin`, a scenario of the tool, a file whose first line is a build tag with `!freestanding`).

**The normal form.** Before it compares, the finder removes the differences that do not change what the code does: the layout, the comments, the parentheses, the names of the locals (each one becomes the order of its declaration in its procedure), the name of an import, the direction of a comparison (`a > b` is `b < a`), a negated equality, a double negation, `x += y` (it is `x = x + y`), the order of the operands of `==`, `!=`, `&`, `|` and `~` when both are pure, a counted `for` loop (it is `for i in a..<b`), a negated condition with two branches, a boolean return (`if c { return true }; return false` is `return c`), and the arithmetic of integer literals. The order of `+`, `*`, `&&` and `||`, the names of the fields and the names of the globals stay: without the types, the syntax does not prove that they are the same behaviour.

**The similarity score.** The finder anti-unifies two pieces: each node that both have stays in the template, and each place where they differ becomes a blank. The score is `2·|T| / (|A| + |B|)`: two times the nodes of the template over the sum of the sizes. It is 1 when the two are equal after the normal form (`glossary/project.md`, "Similarity score").

**The blanks.** A blank is printed `?1`, `?2`; the same pair of arguments at two places is one blank. Its kind says how a factored procedure takes it:

| Kind | Where | In the factored procedure |
|---|---|---|
| value | An expression that is read | A parameter |
| type | A type, a conversion to a type | A polymorphic parameter `$T` |
| place | An expression that is assigned or addressed | A pointer parameter |
| procedure | The name of a called procedure | A procedure parameter |
| not a parameter | An operator of a statement, a field name, a statement | None |

A place that some members do not have is a gap, printed `?-`.

**The categories.**

| Category | What it is |
|---|---|
| utility to centralise | Equal code pieces in two or more packages |
| local repetition | Equal code pieces in one package |
| parametric family | One template whose blanks are all parameters |
| repeated expression | An expression with three or more uses |
| similar behaviour | A gap, a child that only some members have, a blank that is not a parameter, or a run that control leaves (`return`, `break`, `continue`, `defer`, `or_return`): no one call replaces the members |
| kept apart by the rules | A member is in the kernel or in a contract package, or the template needs the host and the members are under `src/` and `tools/` |
| platform variant | The members are in files with one name and another system suffix (`_linux`, `_other`) |

A family whose members are all inside the members of a larger family, with as many uses or more, is not reported. Each member of a family covers at least 70% of its nodes with the template.

**The home.** The finder proposes the home of a factored procedure: the package of the members when they are in one package; "a contract package, by a decision" when a member is in `src/modulus` or `src/library/modus/contract`, which import no support package; else the support package that each file of the members imports, or a new support package.

**The ranking.** A factoring of a family of `k` uses whose template has `|T|` nodes saves `(k - 1) · |T| - k` nodes, less one node for each value or type parameter and two for each place or procedure parameter. The finder takes the family that saves the most, marks the nodes of its members as used, counts the other families again without those nodes, and repeats. So the headline "a factoring of the ranked families saves N nodes and L lines" counts each node once.

**The bound of a run.** Above a product of 1,000,000 nodes of two pieces (`SIMILARITY_WEIGHTED_ALIGNMENT_NODE_PRODUCT_MOST`), the alignment of the children weighs them by their shape only. The report counts these pairs and marks each family that holds one.

**The output.**

| File | What it holds |
|---|---|
| `build/similarity/report.txt` | The measures, the totals of each area and category, the ranked families, the families that save nothing after them, the families that no call replaces, the kept families and the stale lines of the kept list. No time: the same sources give the same bytes |
| `build/similarity/families.tsv` | One row for each reported family: rank, category, saved nodes and lines, uses, lowest score, template nodes, blanks, gaps, home, template hash, first member, reason of a kept family |
| `build/similarity/members.tsv` | One row for each member: template hash of its family, file, first and last line, package, area, score with the first member, coverage, arguments of the blanks |

**The kept list.** A family that is similar on purpose is one line of `tools/modustool/similarity/similarity_kept.txt`: its template hash in 16 hexadecimal digits (the column `template_hash`), a space, and the reason in words.

```
3f2a9c0d41b7e6a5 the kernel keeps its own copy: it imports no support package
```

The template hash does not change when a file moves, when a local is renamed, or when an argument changes. A kept family leaves the ranking and stays in the measures. The report lists each line whose hash names no family, so the list stays true.

**What it does not prove.** A score of 1 says "equal after the normal form", not "the same behaviour". A type of another package in a conversion (`pkg.T(x)`) reads as a call, and a name that `using` brings is read as a global: the report marks a family whose members hold `using`.

## A module from a source outside the repository

`modustool module-build` builds an outside module (`glossary/communication.md`, "Outside module"): a module whose source is in a folder of another project. It writes the module file and the debug object. The build is the build of a module of the system: the same two steps, in the same procedures (`MODULE_CONTRACT.md`, "The steps of one module, as implemented"). The code is `tools/modustool/build/outside_module.odin`.

**What the folder holds.** One Odin package, its `.asm` files if it has some, and the module build file, `module.txt`. A source imports the packages of the system from the source library `modus`: `import "modus:system"`.

**The module build file.** Each line that is not empty is `key: value`. Each key is written at most one time.

```
name: my_process
imports: drawing
defines: DRAWING_THROUGH_MODULE=true
library: no
```

| Key | Value | When the key is absent |
|---|---|---|
| `name` | The name of the module: lower case letters, digits and `_`, at most 31 bytes | The build stops |
| `imports` | The names of modules of the system, in the order of the import table, with a space between two | No import |
| `defines` | Settings of the compiler for this module, `NAME=value`, with a space between two | None |
| `library` | `yes` for a library module (`glossary/desktop.md`, "Library module"), `no` for each other module | `no` |

The tool refuses a line that is not `key: value`, a key that is not in the table, a key that is written two times, and a value that it does not know. The message names the file and the line.

**The command.**

```
modustool module-build <folder of the module> [--system <folder of the system>] [--out <folder of the outputs>]
```

- **The folder of the system** is a checkout of the repository of the system. The tool takes it from `--system`, then from the environment variable `MODUS_SYSTEM`, then from the folder where the command runs. The tool makes the two other folders absolute, then moves to the folder of the system and builds there.
- **The command `modustool` of the flake** runs the binary of the tool in the folder of the system, which compiles itself again when its sources changed ("The tool built once"). It finds that folder with `MODUS_SYSTEM`. So a command that is typed in the folder of another project sets the variable.
- **The folder of the outputs** is `build` in the folder of the module when `--out` is absent. The tool writes `<name>.module`, `<name>.debug`, and a folder `<name>` with the files between the steps. The build writes no file in the folder of the system. The command of the flake writes there only the binary of the tool and its build record, in `build/tool`.
- **A module with an import** needs the built modules of the system: the import table holds the hash of the file of each import. Run `modustool build` in the folder of the system first. The tool reads `build/modules/<import>.module` there.

From the folder of a module, with the system in `~/modus`:

```
export MODUS_SYSTEM=~/modus
nix develop ~/modus#module -c modustool module-build .
```

The shell `module` of the flake has the build tools and the command `modustool`. It has no hook of the repository of the system: the default shell installs those hooks in the repository where it starts.

**What the command prints.** One line for the module file, with its size and its hash, which is the identity of the module. One line for the debug object. One line for each import, with the hash that the import table names. One line with the names of the exports.

```
modustool: the module my_process: /home/someone/my_process/build/my_process.module, 20480 bytes, hash 5d0c...
modustool: the debug object of my_process: /home/someone/my_process/build/my_process.debug, 9216 bytes
modustool: the module my_process imports drawing, hash 91ab...
modustool: the module my_process has 2 exports: start, count
```

The sizes, the hashes and the exports of this example are not those of a real module.

**The rules that hold for each module.** They are parts of the one build, so an outside module passes each of them:

- each function keeps its frame pointer;
- the module has no thread-local data;
- each declaration of an import agrees with the description of its export (`MODULE_CONTRACT.md`, "The declaration of an import is checked");
- a library module has no segment that the loader writes and that is read-only after the load;
- the debug object holds no path of the host;
- the compiler runs with `-vet`.

**The rule of the three places.** Each source that the compiler read for an outside module is in one of three places: the folder of the module or a folder under it, the source library `modus`, the libraries of the compiler. The tool reads the list that the compiler writes, after the compile step and before the conversion. A source in another place stops the build with its path. So a relative import that leaves the folder of the module is refused, and an import of a folder of the system that is not its library too. A package in a folder under the folder of the module is allowed, with a relative import.

**The rules that the tool does not apply to an outside module.** The rule of the comments, the rule of the names, the rule of the imports of the sources of the system, the check of the fixed addresses and the checks of the documents are rules of the repository of the system.

**The path of a source in the debug object.** A source of an outside module has the path from the folder that holds the folder of the module: `my_process/main.odin`. A stop report and the debugger show that path. The debug object holds no folder above the folder of the module.

**The proof.** `modustool check` builds two outside modules (`outside_module_examples_check`). Each is a copy of a module of the system: the module `tally`, which has no import, and the module `agenda`, which imports `calendar`.

1. The tool copies each `.odin` and `.asm` file of the module to `build/third_party_example/<name>`, with no change, and writes the module build file there.
2. It starts itself as a second host process in that folder: `module-build . --system <folder of the system>`.
3. It reads `build/third_party_example/<name>/build/<name>.module`. The loader must accept the file. Each export must have the name and the call form of the same export of the module of the system. The line of documentation must be the same. The import table must name the hash of the file of each import of the build of the system.
4. It reads the debug object. No path of it starts with `/`, and one or more paths start with the name of the folder of the copy.

The check does not compare the bytes of the two module files. The compiler orders the procedures of a module by the path of its packages, and the package of the copy has another path. The passed line of each example prints the start of the two hashes and says whether the bytes are the same: it is a fact of the run, not a condition.

**An outside module in a machine.** A machine starts an outside module from a disk, as it starts any disk process ("The disk of the disk processes"): the boot image does not change. The command `module-disk` writes a data disk whose store `module_files` holds each module file, under the name of its file, and its debug object `<name>.debug` from the same folder, under the hash of the module. It refuses a debug object that names another module. It prints the line of the console that starts each one:

```
modustool module-disk build/data_disk.img ~/my_process/build/my_process.module
modustool run
```

```
> start_from_disk("my_process", "<the 64 digits that the command printed>")
```

`modustool run` starts the machine with `build/data_disk.img`. The command writes no disk over a file that exists: a data disk holds the stores of a principal. The module runs with no grant and with the budget that it asks for, up to the largest budget of a disk process, paid by the one budget of the disk processes (`MODULE_CONTRACT.md`, "The budget that a module asks for"), and its name is no name of a module of the boot image (`MODULE_CONTRACT.md`, "A module from a disk"). The test part `disk_processes` builds a copy of the module `visitor` outside the sources under the name `outsider`, puts its file and its debug object on the disk, and starts it in the machine. The debugger attaches to it, holds its thread, and gives the frame of the procedure where it sleeps with its file and its line:

```
> columns(debug("outsider"), process, described)
outsider          1
> columns(hold(0), thread, state)
> columns(where(stack(0), procedure = "entry"), module, procedure, file, line)
outsider  entry      outsider/main.odin    93
```

A module that faults needs no attach. The test part builds the same copy a second time, under the name `outsider_fault`, with a setting that writes to the address 0 three calls deep after the start. The root service keeps the stop report of a disk process that stopped on a fault, and the debugger names its frames:

```
> start_from_disk("outsider_fault", "<hash>")
> columns(where(stop_report("outsider_fault"), procedure = "visitor::fault_three"), module, procedure, file, line)
outsider_fault  visitor::fault_three  outsider/main.odin   169
```

**What is not built.**

- An import names a module of the system. An outside module does not import another outside module.

## The outside sources of a module

A module of the system can compile in a work of others written in C (`glossary/communication.md`, "Outside source"). The repository holds no source file of the work: the flake fetches it at one commit, applies the patches of the system, and puts it with the files of the system in one folder of the store. The design: `src/md/infrastructure/outside_source.md`.

| Place | What it holds |
|---|---|
| `src/outside/<work>/LICENSE` | The license of the work, copied: the reuse list reads its first line |
| `src/outside/<work>/patches/` | The changes of the work, applied by Nix in the order of their names |
| `src/outside/<work>/system/` | The C files of the system for the work: its entry and its tables |
| `src/outside/<work>/libc/` | The thin libc and its headers in `libc/include` |
| `src/outside/<work>/self_host/` | The units that the work compiles in when it builds itself, and the module does not (`modustool c-self-host`) |
| `flake.nix` | The commit and the hash of the source, and the variable that names the folder of the store in each shell and in the check |
| The module table | The row of the module, with `c_source` |

The work of today is `chibicc` (the variable `CHIBICC_SOURCE`), in the module `c_compiler`.

**The build.** The compile step of the module compiles each `.c` file at the top of the folder of the store with `clang`, in the order of the names, into the folder of the objects of the module, after its Odin package and its `.asm` files. The link and the conversion are those of each module. The headers are those of the thin libc only (`-nostdinc`). The build key of the module holds each command of `clang`, and each command names the folder of the store, whose name holds the hash of its content: a change of a patch or of a file of `outside/` builds the module again.

A new file of `src/outside/` is read by Nix only when git tracks it. A shell with no variable stops the build of the module:

```
modustool: the module c_compiler compiles in the C files of chibicc, and the variable CHIBICC_SOURCE is not set: run the tool in a shell of the flake (src/md/infrastructure/outside_source.md)
```

**A new patch.** Make the change in a checkout of the work at the pinned commit, write it with `git diff` as a file of `src/outside/<work>/patches/` with a name after the last one, add the file to git, and build: Nix applies it, and a patch that does not apply stops the shell with the line of the patch.

**The C programs.** SQLite, Lua and zstd are not modules of the system build. Each has a recipe in `src/outside/c_programs/recipes` (its format is in the `README.md` there): the flake reads its archive, its hash, its root and its patches, and the variables `SQLITE_SOURCE`, `LUA_SOURCE` and `ZSTD_SOURCE` name the patched roots in the default shell and in the host checks. The host test of `src/outside/c_programs` builds the module of each recipe with clang and runs SQL, Lua scripts and zstd frames through its exports. With no variable, the test of the program writes one line and does not run. A patch of a recipe is a file of the folder of the program, named by a line `patch:` of the recipe, with its paths relative to the root.

## The SDK

The SDK (`glossary/communication.md`, "SDK") packages the public surface of modus into a self-contained directory so a developer can build an outside module in Odin or in any compiled language with no repository checkout and no Nix. The design is `src/md/infrastructure/sdk.md` and `src/md/infrastructure/language_neutral_abi.md`; the code is `tools/modustool/build/sdk.odin`.

**What an SDK directory holds.**

- `<sdk>/SDK_MANIFEST.txt`: canonical manifest with `sdk_format`, `release`, `target`, `module_format`, `compiler`, BLAKE3 `root_digest`, optional Ed25519 `public_key` and `signature`, and sorted `<blake3>  <relative-path>` lines for every other file in the directory.
- `<sdk>/library/modus/`: clean copy of `src/library/modus/` only. No file from `src/library/internal/` or `src/modulus/` is included, and both packaging and verification refuse any path segment named `internal` or `modulus`.
- `<sdk>/runtime/`: freestanding memory assembly routines copied from `src/runtime/`.
- `<sdk>/modules/`: `catalog.txt` listing the public system and library modules of the release and verified `.module` files for declaring imports without a checkout.
- `<sdk>/examples/hello_odin/` and `<sdk>/examples/hello_c/`: minimal freestanding Odin and C outside module examples.

**The commands.**

```
modustool sdk-pack <output-dir> [--sign-key <path>] [--modules-dir <path>]
modustool sdk-verify <sdk-dir> [--public-key <path>]
modustool sdk-convert <object.o> <module.manifest> <output.modus> [--sdk <sdk-dir>] [--import-dir <dir>]
```

- `sdk-pack` assembles the SDK directory deterministically, signs `root_digest` with Ed25519 via `modus:cryptography_primitives` when `--sign-key` is supplied (accepting 64 hexadecimal digits or unpadded base64url), and runs `sdk-verify` before returning.
- `sdk-verify` runs outside a repository checkout, parses `SDK_MANIFEST.txt` strictly, checks `root_digest` and the Ed25519 signature (pinning `--public-key` when supplied), walks the directory while refusing symbolic links, stray files, missing files, and any `internal` or `modulus` path, and checks every file's BLAKE3 hash.
- `sdk-convert` runs outside a repository checkout and converts any freestanding System V AMD64 relocatable ELF object (`ET_REL`) paired with a language-neutral `module.manifest` into a verified modus module file validated by `module.validate`, resolving imports from `<sdk-dir>/modules/` or `--import-dir`.
- `modustool module-build <folder> --system <sdk-dir>` detects `SDK_MANIFEST.txt` in `<sdk-dir>`, verifies the SDK, and builds either an Odin outside module (`module.txt`, passing only `-collection:modus=<sdk-dir>/library/modus`) or a language-neutral module (`module.manifest` with `.o` or `.c`) against the SDK.

## The self-hosting check

`modustool self-host` verifies that `modustool` builds itself to identical bytes in two isolated staging directories. The design is in `src/md/features/bootstrap.md`; the code is `tools/modustool/build/bootstrap.odin`.

```
modustool self-host [--staging-dir <folder>] [--verify-chains]
```

1. The running tool clears `<staging>/stage1` and `<staging>/stage2` (default root: `build/self_host`), unsets `NIX_LDFLAGS`, sets `SOURCE_DATE_EPOCH=0`, and compiles `tools/modustool` into `stage1/modustool` with deterministic flags (`-define:TOOL_BUILDS_ITSELF=false`, `-source-code-locations:filename`, `-use-single-module`, `-extra-linker-flags:-Wl,--build-id=none`).
2. The tool runs `stage1/modustool self-host --emit-binary <staging>/stage2/modustool`, so the Stage 1 binary compiles Stage 2 with the same flags.
3. The tool computes the BLAKE3 hash of both binaries and verifies `blake3(stage1) == blake3(stage2)`. When the two binaries differ, the command fails and prints the exact byte offset of the first divergence.
4. When `--verify-chains` is passed, the command also verifies the stage-by-stage `plans_recipes.Recipe_Spec` and `guest_builder.Guest_Build_Spec` DAGs for the `chibicc` self-host chain, the `hex0` to `odin` live-bootstrap guest chain, and the SQLite, Lua, and zstd freestanding C-world validation recipes.

## The self-hosting of the C compiler

`modustool c-self-host` verifies that the C compiler builds itself through the assembler of modus: `chibicc` built by clang compiles the sources of `chibicc`, and two stages built by `chibicc` have one BLAKE3 hash. The design is in `src/md/features/bootstrap.md`, "The self-hosting of the C compiler"; the code is `tools/modustool/build/c_self_host.odin`. It runs in a shell of the flake: it reads the outside source of `chibicc` through the variable `CHIBICC_SOURCE`, and runs clang, nasm and ld.lld.

```
modustool c-self-host
```

1. Stage 0: the tool compiles the C files of the outside source with the flags of a module, links them with the copies and the fills of `src/runtime/memory.asm`, and converts the link into a module with the one export `compile_record_at`, in `build/c_self_host/stage_zero`.
2. Stage 0 compiles each C source of the folder and of its folder `self_host`, each in a fresh copy of the module, and writes each text in `build/c_self_host/stage_zero/texts`. The texts and `self_host/jump.s` are one text of the assembler, whose module is `build/c_self_host/stage_one/chibicc.modus`.
3. Stage 1 compiles the same sources into `build/c_self_host/stage_one/texts`, and the assembler writes `build/c_self_host/stage_two/chibicc.modus`.
4. The tool prints the sources, says whether stage 1 gave the text of stage 0 for each, prints the size and the BLAKE3 hash of the two modules, and fails when they differ, with the first byte where they differ. A refusal of a stage prints the diagnostic of `chibicc`; a refusal of the assembler prints the line, the column, the sentence and the line of the text.

The host test `chibicc_builds_itself_to_the_same_bytes` runs the same chain in a temporary folder.

## The commands of the tool

All the automation of the project is one program of the host, `tools/modustool`. It is one command over packages, one for each concern: `foundation`, `resources`, `build`, `checks`, `fuzz`, `similarity`, `machine` and `site`, in the order of their imports. A package imports another one as `"modustool:<package>"`, with the flag `-collection:modustool=tools/modustool`, never by a relative path. The layout is in "The packages of the tool", below; the design is in `src/md/infrastructure/repository_layout.md`. Each task (a build, a test, the site, a release) is one of its commands, so the same steps run on each computer and in each check. Run a command with `nix develop -c modustool <command>`; `modustool help` prints the list with one line for each.

| Command | What it does |
|---|---|
| `build [whole] [host_processes]` | Builds the modules, the boot images and the boot programs: the usual one, and one for each volume that a test or a measure needs (a start that fails, a shortage of frames, a measure run, the volumes of the trusted boot that the boot program must refuse, the volumes of Secure Boot, one for each self test of the kernel). It keeps each module and each boot volume when its inputs are the same, and only converts a module when the file of an import changed; `build whole` keeps nothing ("The incremental build") |
| `module <name> ...` | Builds one module of the table, and its debug object; with `compile` or `convert` as its last argument, runs one of the two steps alone. The parallel build runs it for each step; run it by hand to see the errors of one module alone |
| `module-build <folder> [--system <folder>] [--out <folder>]` | Builds one outside module from a folder of another project, with its module build file `module.txt` (or against an unpacked SDK directory holding `SDK_MANIFEST.txt`): writes `<name>.module` and `<name>.debug`, and prints the hash of the module and the names of its exports ("A module from a source outside the repository") |
| `module-disk <disk file> <module file> ...` | Writes a data disk whose store `module_files` holds each module file under the name of its file, and prints the line of the console that starts each one ("A module from a source outside the repository") |
| `sdk-pack <output-dir> [--sign-key <path>] [--modules-dir <path>]` | Packs a deterministic, self-contained SDK directory with public library, runtime, public module catalog and `.module` files, examples, and canonical `SDK_MANIFEST.txt` with BLAKE3 root digest and optional Ed25519 signature ("The SDK") |
| `sdk-verify <sdk-dir> [--public-key <path>]` | Verifies every file BLAKE3 hash, absence of stray, missing, symlink, or `internal`/`modulus` paths, and Ed25519 signature of an unpacked SDK directory ("The SDK") |
| `sdk-convert <object.o> <module.manifest> <output.modus> [--sdk <sdk-dir>] [--import-dir <dir>]` | Converts a freestanding `ET_REL` object (`.o`) paired with a language-neutral `module.manifest` into a verified modus module file with no repository checkout ("The SDK") |
| `cache-serve --dir <folder> [--listen <host:port>] [--signer-key <path>] [--authorized-key <path>] [--status-listen <host:port>] [--endpoint <host:port>] [--site <address>]` | Serves an object cache of the folder: blobs and trees by their BLAKE3 hash, and realisations, as binary frames over TCP (`MOCQ` and `MOCR`). An upload needs a key of `--authorized-key` (a file of 64 hexadecimal digits) or the public key of `--signer-key`, and its signature. `--status-listen` adds a second listener that answers `GET /` (the page, in the look of the site), `GET /status.json` and `GET /style.css`, one request on each connection; `--endpoint` is the public address that the page shows (by default the listen address), and `--site` the address of the site (by default the address that `modustool site` gives the site) (`src/md/infrastructure/public_object_cache.md`) |
| `cache-put <host:port> --key <seed file> blob <file>...`, `cache-put <host:port> --key <seed file> release <boot image>` | Puts files on an object cache, each as a blob, signed with the key; `release` puts each file of a boot image that the cache does not hold, then the cache test recipe, its output and its realisation signed with the key. The release workflow runs it with the cache signing key (`src/md/infrastructure/cache_publication.md`) |
| `cache-get <host:port> blob <hash> [<output file>]`, `realisation <recipe hash> --signer <file>`, `release <boot image> [--signer <file>]`, `test-recipe [--signer <file>]` | Takes from an object cache and refuses what does not verify: a blob against its hash, a realisation against the signer that the command gives (by default `resources/keys/cache_signing_key.public`), each file of a boot image, and the cache test recipe against the tree computed again. `cache-get cache.modus.systems:5010 test-recipe` checks the public object cache; it needs the network, so no check runs it |
| `volume <name>` | Builds one boot volume: its boot image with the system description, its boot program, and the volume file. The build runs it for each volume that it must build; run it by hand, after a build, to see the errors of one volume alone |
| `run [without_checks]`, `run --remote-display <viewer key>` | Builds the modules and the main boot volume, then starts the machine under QEMU in a window, with the log of the kernel on the terminal. The tool reads the serial port of QEMU line by line, and writes each line of a log fact as its sentence as soon as the line ends, with the render of the machine tests; a line of text, a fact of a module that the build does not have, and a line that does not end, such as a prompt, are written as they come. The data disk stays from run to run. It starts the peer that takes the calls of `modustool call`, draws the key of its client for this run, and prints it with the line to type in a console of the machine: `remote_allow("<key>")`. With `--remote-display`, the machine has no window and a new data disk: the tool starts `remote_display`, prints the port of the UDP relay of the peer to its port 7101 and the line of its key, allows the viewer key for the view and the input, waits until a viewer came and went, then stops the machine ("A machine for a viewer on the host" in `src/md/features/remote_display.md`) |
| `call <key> "<call>"` | Calls an export of a service of the machine that `run` started, through the process `remote` over QUIC, and prints the typed result. The call acts for the principal that allowed the key of the client of the peer; with no such principal it fails: "remote refused the key of this client in the handshake (access_denied)" |
| `assistant --remote-key <key> --client-key <key> [--fake <script>] [--once] [--key-in-clear-off-host]` | The agent runner of the window `assistant` (`docs/ASSISTANT.md`): it answers each request of the window through `remote`, with the model of `MODUS_ASSISTANT_ENDPOINT` and the key of `MODUS_ASSISTANT_KEY`, or the replies of a script with `--fake`, and runs each act only through the host agent bridge. It never prints the key. The endpoint is this machine unless `--key-in-clear-off-host` accepts that the key crosses the network in clear |
| `test [part]` | The parts of the machine test (below), several at once; the part `host_modules` holds the tests of the loader and of the system descriptions on the host. It prints the time of each part, then the times of the test (below), and ends with "modustool: all tests passed" |
| `test <part> from <folder>` | One part on the test inputs of a folder, with no build, and the count of its checks in `build/checks_passed.txt`: the command of a part derivation of the flake ("The derivations of the check") |
| `test <part> steps <first> to <last> [of <machine>] [with <first> to <last>]...` | The boot steps, the setup steps of each `with` and the steps of the range of one machine of a part, then the part ends ("A step range") |
| `fact_waits` | Builds the modules, then checks each fact wait of the scenarios against the fact templates of the build, with no machine ("The check of the fact waits") |
| `failed_parts` | After a build of the check of the flake with `--keep-going`: the host checks and each part that failed or did not run, with its first failed step and its whole build log in `build/failed_parts/` ("The derivations of the check") |
| `test_inputs <folder>` | Copies the test inputs of the build folder into `<folder>/test_inputs`, and the names of the test parts into `<folder>/test_parts.json`; it refuses a build that lacks a boot volume of a part ("The derivations of the check") |
| `test_join <target> <host checks> <part>=<folder> ...` | Joins the outputs of the host checks and of each part derivation into the output of the check `boot-test`: the logs, the pictures and the count of the checks of all ("The derivations of the check") |
| `part_cache` | Proves that a change of an intent file or of a host test of the tool leaves the derivation of each test part the same, and that a change of the scenario of one part changes the derivation of that part only: four copies of the tracked files in `build/part_cache`, and the derivations of each. It costs three whole builds ("The derivations of the check") |
| `measure ...` | A measure run: a machine that measures with no other load. No argument: the locks, then a frame at 1920 × 1080 on the processor (`processor_frame`), and the three measures of the standard of quality that the compositor writes (the time of a frame, of a key to the screen through the console, of the start of the window of `locks`) with the line of the quality profile; the tool reads all these lines for their form. `scheduler N`, `clock`, `crowd`, `disk`, `flow`, `limits`: the process alone, and its lines. `windows`, `address_space`, `shortage`. The numbers are measures, never conditions ("A check by count, a measure by time") |
| `screenshots` | Prints how many test parts Nix takes from the store and how many run, then builds the check `boot-test` of the flake, with at most one part derivation at once for each four processors of the host: the one run of the machine test of the full check (`src/md/infrastructure/full_check.md`). Nix takes it from the store when `nix flake check` passed on the same tree. Nix goes on past a failed part (`--keep-going`); after a failed build, the command lists each failed part as `failed_parts` does. Then the copy of its pictures to `docs/screenshots` and to the development log, the copy of its logs to `build/`, the measure runs on the host whose numbers the measure record holds (the locks, `processor_frame`, `clock`, `disk`, `scheduler`) and the measure run of `log_reader`, then the measure record. `screenshots compress` compresses the PNG files that are stored with no compression |
| `check` | `odin check -vet`, the imports of the sources of the system, `odin check` of the kernel for `freestanding_wasm64p32` (the kernel of the browser machine, which no build of the image compiles), the example of a process outside the sources and the host tests of each folder, several at once ("The host tests of the check"), the fuzz targets ("The fuzzing"), the checks of the sources (the origin of the cryptography, the mark, the fixed addresses, the bounds of the tests and the periods of each `time.sleep` of the tool, no line cut by a reading tool, the rule on comments, the glossary, the file index of the intent folder, the source paths in the documents, the changelog, the news, the roadmap), then `test`, whose build is followed by the check of the fact waits, the test of the debug objects of the build against its linked files, a second build that must give the same bytes, and the count of its checks in `build/checks_passed.txt`. Each of its builds is a whole build. `check without_machines`: no machine test, and a whole build of the main volume, then the check of the fact waits, before the second build; the check of the flake runs this form |
| `fuzz list`, `fuzz <target> [executions [host_processes [seed]]]`, `fuzz all [executions]`, `fuzz show <target> <file>`, `fuzz minimize <target> <file>`, `fuzz regression <target> <file>`, `fuzz corpus <target>` | Fuzzes the readers of the system on the host: the module file, the debug object, the storage format, QUIC and TLS, TCP and HTTP, the remote protocol and the call region, the records of a ring, the disk grant table, the system description and the boot image, the fonts, the pointer theme and the tables of the firmware. It builds the instrumented child, runs a fuzz target, and minimizes each fuzz finding ("The fuzzing") |
| `fuzz operations <executions> [seed]`, `fuzz regression operations <finding>`, `fuzz replay operations <file>` | Fuzzes the kernel operations on machines of the counted kernel: operation sequences that the counters of the kernel guide, a new machine after each fault, each fault of the kernel kept one time for its signature and minimized by machine lives and by steps, and the reach inputs of the corpus at the end of the run; a fixed finding into the corpus with the answers of the kernel that ships; or one sequence again on the kernel that ships ("The fuzzing of the kernel operations", "The corpus of the kernel operations", "The operation sequences") |
| `repeat <module> <count>` | Builds one module again and again, with no machine, and counts the distinct results (`docs/REPRODUCIBLE_BUILD.md`). Each of its builds is a whole build |
| `self-host [--staging-dir <folder>] [--emit-binary <path>] [--verify-chains]` | Builds `stage1/modustool`, invokes it to build `stage2/modustool` with identical deterministic flags, and verifies `blake3(stage1) == blake3(stage2)` or reports the first diverging byte offset ("The self-hosting check") |
| `c-self-host` | Builds `chibicc` with clang, then twice with itself through the assembler of modus, on the host, and verifies `blake3(stage 1) == blake3(stage 2)` ("The self-hosting of the C compiler") |
| `module-hashes write <file>`, `module-hashes compare <file>` | Records the hash of each module of the build in a file, or compares the build with such a record and fails when a module has another hash ("The hashes of the modules of two builds") |
| `site` | Writes the site in `build/site/` |
| `browser-machine`, `browser-machine boot [<boot image>]`, `browser-machine console` | Builds the kernel for `freestanding_wasm64p32` in `build/browser_machine/modulus_kernel.wasm`, refuses a file whose imports are not the six functions of `modus_page` or whose exports are not `memory`, `entry` and `modus_processor_loop_run`, and writes the page of the browser machine, its worker, the host of the kernel and the boot image of the build beside it. Beside each signed boot image of the page it writes `<image>.trust`, the hash of its system description in hexadecimal, which the worker of the page gives to the trust of the boot record. `boot` first runs the tests of the stage tracker of the host in Node, as `modustool check` does, then starts the kernel in Node 24 with the host of the page, prints the time of each stage of the start as a measure, prints its serial port, and fails with no line `kernel: ok`, with a boot image and no line of the stage of the root service, or on a trap of WebAssembly. It then runs a copy of the image with one byte of the module `console` changed, `damaged_module.image`, and fails unless the root service writes the fact `root.Image_File_Hash_Wrong` at the load of that module: a line of the module `root`, with the module tag of `root`, the key tag of that fact, and the name `console` as its one value. It also fails on a line of `console`: the changed module must not run. Each run ends when the machine stops, or at the hang bound (`src/md/features/browser_machine.md`, "The page and its host"). `console` then writes the console page, `browser_machine_console.html`, and its signed boot image, `console.image`, from the boot image of the build: the console and `dom_terminal` on the second serial port, with no compositor, drawing module, input service or font; it refuses an image that would hold one (`src/md/features/console_renderers.md`, "The console image") |
| `changelog ...`, `news ...`, `release_number` | The fragments of the changelog and its releases, the news entries, the number of the newest release |
| `ship step`, `ship correction`, `ship <release number>` | The release in one command: the changelog, a commit, a signed release tag, one atomic push to `master` ("The release") |
| `queue <branch>...` | Merges a batch of branches into `master` after one full check, splits a batch that fails in halves to name the branch at fault, pushes `master`, and removes the merged branches and their worktrees ("The merge queue") |
| `rename-library` | Moves the folders of the source library into its two source libraries, and rewrites the import lines, the comments and the documents; a second run changes nothing ("The rename of the library") |
| `measure-history` | The copy of the measure record of each release tag that holds one, in `docs/measures/releases/` ("The release") |
| `measure-compare <record before> <record after>` | The line of each measure in two measure records, and the number of each series in each with its ratio ("The comparison of two measure records") |
| `roadmap check` | Checks the form of `ROADMAP.md`, the planned work, and refuses an entry whose work has an entry of the changelog ("The roadmap") |
| `key new <folder>`, `key write <folder>`, `key show` | The keys of the publisher of the system: the signing key, the firmware signing key, the release signing key, and with `key new` the cache signing key; `key write` makes the folder of the first three from the secrets of a workflow (`secrets/README.md`) |
| `key new cache <folder>`, `key write cache <folder>`, `key show cache` | The cache signing key alone: a new one in a folder, the folder from `CACHE_SIGNING_KEY_TEXT` (refused when its public key is not `resources/keys/cache_signing_key.public`), and the public key of the seed that `CACHE_SIGNING_KEY` names (`src/md/infrastructure/cache_publication.md`) |
| `release image`, `release tag-check <tag>` | The files of a release in `dist/`: the GPT disk image of the release volume compressed with zstd, `SHA256SUMS.txt` and its release signature, with the keys of the publisher only and the pointer theme of the system only; the check that a tag names the release number (`INSTALL.md`, `src/md/infrastructure/release_image.md`) |
| `verify <image> <checksum list>` | Verifies the release signature of the checksum list with `resources/keys/release_signing_key.public`, then the SHA-256 of the image (`INSTALL.md`, "2. Verify the files") |
| `font`, `vector_fonts`, `pointers`, `logo`, `portraits` | Convert a source (a font, a pointer theme, the mark, the pictures of the hall of fame) into the files of the repository. A build reads the result, never the source |
| `mark <what> [options]` | Makes one file of the mark: the still mark, a frame, an animation, a tile map, the table of a tile map, the picture for a developer, as a PNG file, an icon file, a vector file or an animated PNG file; `mark uses` prints the table of the uses ("The pictures of the mark") |
| `similarity`, `similarity near <file>:<line>`, `similarity pair <file>:<line> <file>:<line>` | Measures how similar the code pieces of `src/` and `tools/` are: families with their factoring template, ranked by the nodes that a factoring saves, in `build/similarity/`; or the procedures most similar to one; or the score of two procedures ("The similarity finder") |
| `library-imports` | Checks that each import of each source file of `src/` follows the rule of its file, that the kernel and a contract package import no support package, and that each host test that imports a package of `core:` starts with `#+build !freestanding` ("The imports of the sources of the system") |
| `rule-checks` | Checks the count of the kernel operations against the properties, that no source of the system calls an allocator, that each export that fails gives an error record, that no family of integer constants is a closed set of choices, that no cast of a word to an enum skips its border, that no stop word skips its border, that no source outside the one file of the seed uses `rdrand` or `rdseed`, that only the loader and the root service name the field `image_checks`, that no package variable needs a start of the runtime, and that no service or library names a bound of the tests ("The rules that a check holds") |
| `cryptography-take`, `cryptography-system-hashes`, `cryptography-origin` | Take a file of the cryptography of Odin, list the files that the project wrote, and check the origin of each taken file (`docs/CRYPTOGRAPHY.md`) |
| `film [terminal \| palette \| heron \| boot \| desktop \| console \| program]` | Films a scenario of the machine while the scenario types: `build/films/<name>.mp4`, `build/films/<name>.webm` and the cue file `build/films/<name>.cues` ("The film", "The film cues"; needs ffmpeg), and `docs/films/<name>.webm` when a news entry names the film ("The film of a document"). No argument: the film of the terminal |

### The packages of the tool

Each package is a folder of `tools/modustool`. A package imports only the packages above it in this table; the compiler refuses a cycle. Each folder has its host tests, and `modustool check` runs the host tests of each folder in its own process ("The host tests of the check").

| Package | What it holds | It imports |
|---|---|---|
| `foundation` | The folders of the sources and of the build, the source libraries and their flags, the table of the modules, the type of a command, the run of a process and the pool of host processes, the files, the lines of a text, the readers of the Odin sources | nothing of the tool |
| `resources` | The mark and its pictures, the fonts, the pointer themes, the portraits, the PNG files | `foundation` |
| `build` | The compile, the module files, the incremental build, the boot images and the boot volumes, the signatures, the release image, the outside modules, and the checks that each build runs | `foundation`, `resources` |
| `checks` | The checks of the sources and of the documents, the changelog, the roadmap, the news, the reuse list, and the measures | `foundation`, `resources`, `build` |
| `fuzz` | The fuzzing engine, the fuzz targets and their corpus, and the operation sequences on the host | `foundation`, `build` |
| `similarity` | The similarity finder and its kept list | `foundation` |
| `machine` | QEMU, the parts of the machine test with their scenarios, the peer, the films, the measure runs, and the fuzzing of the kernel operations on machines | `foundation`, `resources`, `build`, `checks`, `fuzz` |
| `site` | The pages of the site, the byte layouts, and the pointers of an intent file | `foundation`, `resources`, `build`, `checks` |

The command package is `tools/modustool` itself: `main.odin` holds the table of the commands, its dispatch, and the commands that reach several packages: `run`, `test`, `screenshots`, `measure`, `check` and `fuzz`. It is the only package that imports all the others, and it gives its table to the site as an argument.

### The tool built once

The tool is compiled once for each change of its sources, not at each command. The design is in `src/md/infrastructure/repository_layout.md`.

- **In the development shell**, `modustool` runs `build/tool/modustool`. When the file is absent, the command compiles it first. Before each command, the binary computes the build key of its sources and compares it with its build record, `build/tool/modustool.build_record`, as the incremental build does for a module ("The incremental build"). The key covers the files that its compiler read (the tool, the source library, the kernel parts, the libraries of the compiler, the files of `#load`), every other file of their folders, the command of the compiler and the host program `odin`. When the key differs, the binary prints `modustool: the tool is compiled again (<reason>)`, compiles the tool, and runs the new binary with the same arguments. A command after a change of a guide or of a host test starts with no compile.
- **In the check of the flake and in the release shell**, `modustool` is the binary of the derivation `modustoolBinary`, compiled from the `.odin` files that are not tests of those folders, and from the font that a fuzz target loads. Nix builds it again only when one of those files changes. That binary never compiles itself. A part derivation of the check runs the binary of its own part, `modustool-part-<part>`, compiled from the same files less the scenario files of the other parts ("The derivations of the check").
- **The measure.** Each compile in the development shell prints `modustool: measure: the compile of the tool: <seconds> s`. The derivation compiles with `-show-timings`: its build log (`nix log`) gives the time of each phase of the compiler. Each is a measure, never a condition.
- **A compile that fails** prints the errors of the compiler and runs no command; the next command compiles again.
- **A command that runs while the tool is compiled again.** A command starts the tool again for each step of a module, each boot volume and each outside module, through `/proc/self/exe`: the binary of the command itself. A second command after a change of the sources replaces `build/tool/modustool`, and the first command goes on with its own binary.
- **The first command of a new work tree** compiles the tool two times: the command of the flake makes the first binary with no record, then that binary compiles again with its record.

### The host tests of the check

`modustool check` runs the `odin test` of each folder of `HOST_TEST_FOLDERS` at the same time as the others, in the pool of host processes of the module build. The design is in `src/md/infrastructure/full_check.md`.

- **At once.** At most one host process for each processor: the processors of the host, or `NIX_BUILD_CORES` when it is fewer. The heaviest packages of the tool (`site`, `build`, `checks`, `resources`, `machine`) come first in the list, the longest first, so that none of them starts late and runs alone at the end. After a failure no new folder starts; the folders that run end.
- **The files of a folder.** Its log is `build/host_tests/<name>.txt`, where the name is the path of the folder with `_` for each `/`. Its compiler has its own temporary folder, `build/host_tests/<name>`, so that two compilers never write one object of an assembly file.
- **What the check prints.** One line for each folder that passed, with its time: `modustool: measure: the host tests of src/library/modus/quic: <seconds> s`, then the time of all on the clock. For a folder that failed, the path of its log and its last 40 lines. Each time is a measure, never a condition.
- **The flag of the kernel parts** goes to the host tests of the folders under `src/modulus` and of each folder of the tool only. **The flag of the source library of the tool**, `-collection:modustool=tools/modustool`, goes to each folder of the tool: the command and each of its packages.
- **The flag of the attribute of a fact type**, `-custom-attribute:log_fact`, goes to each folder, as to each compile of a package of `src/`: a module, the kernel, the boot program and the tool. With it the compiler accepts the attribute `log_fact` of a fact type and ignores it (`src/md/features/log_facts.md`). The host test `the_fact_key_is_the_typeid_of_the_compiler` of the package `build` declares one fact type, and checks that the fact key that the tool computes is the typeid that the compiler gives it.
- **One folder alone**: `nix develop -c odin test <folder> -vet -collection:modus=src/library/modus -collection:internal=src/library/internal -custom-attribute:log_fact`, with `-collection:modulus=src/modulus` (and no `internal`) for a kernel part, and with `-collection:modulus=src/modulus` and `-collection:modustool=tools/modustool` for a folder of the tool.

### The fuzzing

A fuzz target gives the real code of the system millions of fuzz inputs, and checks its oracles after each one: no fault, an end before the hang bound, the contract of the reader, a round trip through its writer, a model, and a second reader of the system that agrees. The design is in `src/md/infrastructure/fuzzing.md`.

`modustool fuzz list` prints the targets:

| Target | Kind | What it checks |
|---|---|---|
| `module_file`, `module_generated` | raw, generated | A module file that `validate` accepts gives no read out of bounds through any reader of `src/library/modus/contract/module`; a module built by the rules passes `validate` |
| `debug_object`, `debug_object_generated` | raw, generated | A debug object that `check` accepts gives each reader with no fault, and `encode` of its tables gives its bytes back |
| `storage_tree` | generated | The B-tree against a sorted model, its walk after each commit, then damaged nodes |
| `storage_mount` | generated | The open of a disk gives back each object of the writer of the tool; the open of a damaged disk never gives a wrong object as whole |
| `quic_datagram` | raw | One datagram to a server that waits for its client |
| `quic_connection` | generated | A client and a server in memory, with datagrams changed or resealed with new frames; with no change, the handshake completes |
| `tls_messages` | raw | The messages of TLS 1.3 to a client or a server, level by level |
| `quic_transport_parameters` | raw | The part of the transport parameters that this system sends, from a record that the reader accepts, writes and reads again to that part, with the defaults of RFC 9000 in the other parameters |
| `tcp_segment`, `tcp_connection` | raw, generated | The header reader and its writer agree; two tables in memory with injected segments, and the bytes arrive in order |
| `http_request` | raw | The reader of a request head: its fields stay in their limits, and the head reads the same from its own bytes |
| `remote_request`, `remote_answer` | raw | A call request that `request_check` accepts keeps each place in the call region; an answer that `answer_check` accepts names a status; each writes again to its own bytes |
| `remote_client_table` | raw | The client table reads as it is written, and each decision on a key names the right row; a row holds a use only when the border of its word of uses takes it |
| `remote_display_records` | raw | A record of the remote display of each direction that its border takes writes again to its bytes and stays in its ranges, and a screen piece that decodes codes and decodes to the same pixels |
| `isolated_call` | raw | `isolated.decode` of a description and a call region gives only slices inside the call region |
| `ring_records` | raw | Each input event, terminal input, service command and root command is the member that its word names, or a refusal with the zero value |
| `root_ring` | raw | The dispatch of a record of the root ring, for any start grant set of its sender, stops at the border with `Unsupported` or at the sender with `No_Grant` exactly when the table of the senders refuses it; each word of a command and each refused Replace gives its member or its record; nothing changes |
| `disk_grant_table` | raw | A table behind its tag holds rows by its rules, and encodes and decodes to its part that persists |
| `system_description`, `boot_image_generated` | raw, generated | A description that `entries` accepts is the one that its writer gives; a boot image as built passes the checks, and a changed byte of a file or of the description fails them |
| `vector_font` | raw | A font that `font_open` accepts gives each glyph, outline, pair and substitution, and draws a glyph |
| `font_outlines` | raw | Font outlines that `validate` accepts write again to the same fonts |
| `pointer_pictures` | raw | A theme that `validate` accepts gives a picture of each shape, size and time, with its pixels in the file |
| `draw_record` | raw | The border of a draw record gives a problem of its enumeration and changes nothing; a record that it reads has a box in its bounds, and writes back to its own bytes. The same bytes as the points of a path: the border of the points, with a copy and with none, gives one problem and a count of 0 on a refusal, and the points that it reads start with a `Move`, keep the order of the commands, and cut each curve inside the box of its three points. The same bytes as a table: the border of the order of the clips gives the verdict and the record of a walk of the kind words, and changes no record |
| `draw_path` | raw | A path of fuzzed points, with a stroke width and two alphas from the input, written by `draw_path` and drawn into a canvas framed by guard pixels: no pixel outside the canvas or the box of the record changes, and the path drawn whole and in damage rectangles across the bands of the accumulation gives the same pixels. The arithmetic of Odin wraps with no fault, so this is where a sum of the cells past its bound shows |
| `firmware_tables` | raw | The tables DMAR, IVRS and MCFG that the readers accept keep their counts, ranges and units in their bounds |
| `acpi_processors` | raw | The processors that the table APIC names stay in the table of the caller, and those of the identifiers of 8 bits are processors of the other mode too |
| `sentences` | raw | The sentence of any error record is a valid text; in a small buffer it is the start of the whole sentence, then the cut mark with the count of the bytes that it lacks |
| `palette_table` | raw | The copies of the entries, of the result and of the candidates hold what the checks accept; the runs of a result and an argument write again to themselves |
| `value_runs` | raw | The runs that `value_runs_check` accepts write again to themselves, and their parts in the records of the log are the runs cut at the bounds of the records |
| `text_encoding` | raw | The check of a text agrees with the reader of UTF-8 of the Odin library, each character encodes to its own bytes, and a cut ends after a whole character |
| `kept_stop_reports` | generated | A hidden stop report names no hidden value, and the table of the kept reports follows its model |
| `kept_settings` | raw | The kept record, the text of a zone and the settings page read as valid values, and write again to them |
| `tpm_answers` | raw | Each reader of an answer of the TPM agrees with the check of its header, gives no value on a refusal, and gives slices inside the answer |
| `text_shaping` | raw | One placed glyph for each character, at its first byte, with the advance and the pair of its font file at the face and the size of the input, each in its bound, also over a font file that the input gives; a size out of its range, a text or a range past its limit is refused |
| `html_css` | raw | Any page gives a tree, a style sheet and a layout at each of four widths: each count in its capacity, each link of a node or a box in bounds and in one list only, each range in the text pool, no size negative and no far edge past its word; the same bytes give the same results, no reader changes them, and each draw record of the paint is one that the border of the drawing takes |
| `software_machine` | raw | The sixteen registers and two pages of any code, run over page tables with code, data, a page read only, a page of the supervisor and a hole, for a budget of steps: each step ends with an outcome of its enumeration; a fault counts no step, changes no register and no byte but the accessed and dirty bits, and a page fault agrees with a second walk of the page tables; no step writes a page that the user cannot write; the run of the budget in one call ends in the same state |
| `operation_sequence`, `operation_sequence_generated` | raw, generated | An operation sequence that `check` accepts follows each rule of its format and writes again to its bytes, and a refusal names its step, its area or its argument; each sequence that the generator builds from the forms of `OPERATIONS` is one that `check` accepts and reads back whole |

A raw target reads its input as the bytes that the system reads. A generated target reads its input as choices, and builds a whole value from them.

**The child.** The tool runs a target in a child host process, `modustool fuzz-child`, which a fault ends. The child and the tool share the mailbox, a file in `build/fuzzing/<target>/`: before each execution the child copies the input there and adds one to its count of executions. When the count stays still for the hang bound, the tool ends the child, and the input is an input that never returns. The child places each input against a page with no access, after it or before it, so that a read past the input faults even through a raw pointer.

**The instrumented child.** `modustool fuzz` and `modustool check` build `build/fuzzing/instrumented/modustool_instrumented`: the compiler writes the LLVM IR of each package, `opt -passes=sancov-module` adds an 8-bit edge counter to each edge of the packages under test and traces their comparisons (a package is the name that its sources declare: the folder `src/library/modus/terminal` holds `terminal_records`), `llc` makes the objects, and `clang` links them with the flags that the compiler prints. The engine keeps an input that gives an edge a count in a class that no kept input gave.

**The corpus.** The corpus of each target is in `tools/modustool/fuzz/fuzzing_corpus/<target>/`: the regression inputs in `regression/` and the reach inputs in `reach/`, one file for each input, named by the BLAKE3 hash of its bytes. A target holds at most 512 inputs and 1 MiB; the whole corpus holds at most 16 MiB. `modustool check` refuses a corpus over a bound, a name that is not the hash of its bytes, and a folder that names no target, but `operations`, the corpus of the kernel operations ("The corpus of the kernel operations").

**In `modustool check`.** For each target, the child runs each input of its corpus, then a fixed count of new executions (20 000, fewer for a target whose execution does much). The seed is the BLAKE3 hash of the sources of the tool, with each of its packages, of the source library and of the kernel parts: the same sources run the same inputs. The children of several targets run at once: one for each processor (or `NIX_BUILD_CORES`), at most 8. A finding or a stall of one child ends that child only. The check prints the output and the line of each target in the order of the targets, after every child ended, then minimizes each finding. The check fails on any fuzz finding. The line of each target prints the edges that it reached, and the last line gives the time of all the targets on the clock as a measure.

**A long run.** `modustool fuzz <target> <executions>` runs for its count of executions, with one child for each host process. With no count it runs the count of the check, and it refuses a count of 0: a forgotten argument never starts a run with no end. The children share the inputs that they keep through `build/fuzzing/<target>/kept/`. It prints the executions in one second as a measure, never as a condition.

**A fuzz finding.** The tool minimizes the input while its signature stays (the oracle and the place of the fault), and writes it with a text to `build/fuzzing/<target>/findings/`. `modustool fuzz show <target> <file>` prints its outcome and its bytes as an Odin array, for a named host test of the reader. After the fix, `modustool fuzz regression <target> <file>` adds it to the regression inputs, which each check runs again; the command refuses an input that still breaks an oracle. `modustool fuzz corpus <target>` replaces the reach inputs with the smallest set of the kept inputs that gives each edge class. `modustool fuzz replay operations <file>` runs one operation sequence on a machine of the kernel that ships ("The operation sequences").

### The parts of the machine test

The machine test is a list of test parts. A test part is one or more machines that share a data disk, a TPM state or a value from one machine to the next; two test parts share nothing. The design is in `src/md/infrastructure/machine_test_parts.md`.

`modustool test` with no argument runs every part, several at once: at most one part for each four processors of the host, since each machine has four, and at most one part for each GiB of the available memory of the host (`MemAvailable` at the start) past a margin of 4 GiB, since each machine has 1 GiB. One part runs even when the memory holds none. The first line gives the count and its inputs: "modustool: 33 parts of the machine test, at most 2 at once: 16 processors, 4 for each machine; 6144 MiB of available memory, 4096 MiB kept for the host, 1024 MiB for the largest part". A host that swaps the memory of a machine can stop it for minutes, longer than any bound of a hang. The parts start in the order of the table below, the longest first. After a part fails no new part starts, and the parts that run end. Each part starts from a new data disk of its own, `build/test_data_disk_<part>.img`, so it does the same work alone and in the whole test; the disk of a part that failed stays. Each machine writes its log in a file `build/test_output*.txt`, the other files of the machine beside its log (the picture of the screen that QEMU writes, the disk of the measures, the variable store of its firmware), and its pictures in `build/screenshots`. The lines of two parts that run at once are mixed on the terminal; the line `modustool: measure: the part <name> passed` ends each part, and the summary marks a part that did not start after a failure "not started". Each machine boots its volume with `snapshot=on`: several machines read one volume at once, and no machine writes it. All the pictures go to one folder, so a part that saves a picture with the name of a picture of another part fails its step. In the sandbox of Nix, `NIX_BUILD_CORES` bounds the count of the processors.

In the check of the flake, each part runs in a part derivation of its own ("The derivations of the check").

`modustool test <part>` runs one part only, for the work on it, and builds only the boot volumes of its row ("The incremental build", "The volumes of a command"). An argument that is not a part is refused before the build: the command prints the parts that it knows and ends with the exit code 2.

The table is in the tool (`test_parts`, `tools/modustool/machine/test_parts.odin`), and a host test checks each line below against it: a new part is one row there, one line here, and one entry in `tools/modustool/machine/test_part_files.json`, which names the scenario files of the part. The file that holds the run procedure of the part registers it (`test_part_scenario_register`); a host test refuses a part whose run no file of its own registers.

#### A step range

`modustool test main steps 1270 to 1280` runs some steps of one machine of a part, for the work on a scenario. The design is in `src/md/infrastructure/scenario_fault_loop.md`, "A step range".

- **What runs.** The boot steps (each step before the first one that does more than read the log), then the setup steps of each `with <first> to <last>`, then the steps of the range, in the order of the scenario. The numbers are those that a failed step prints. The machine is the first machine of the part, or the one whose log `of <name>` names (`of test_output_tpm_key_4`); the machines before it run whole, and none after it.
- **The setup is yours.** The tool cannot read from the steps which window, connection or line a range needs. It refuses, before the machine starts, a selection whose step names a mark (`{record}`, `{generation}`, `{screen text}`) or calls `remote` with no step that gives the value before it, and names the last step that gives it: "add `with 812 to 812`".
- **The refusals.** Before the build: a number that is no whole number, a step 0, a range that ends before it starts, a setup that is not before the range, a word that is not `of` or `with`. Before the machine: a range past the steps of the machine. After the part: a machine name that the part never started.
- **The end.** The tool ends QEMU after the last step: it checks no exit status and writes no count of checks. A panic or a fault of the kernel still fails it. It prints the time of the start and the boot steps, of the setup steps and of the range, as measures, and ends with "the step range passed; the part is proved by its whole run".

| Part | What it checks | Its boot volumes |
|---|---|---|
| `main` | The main machine: the desktop, the console, the processes and the developer tools | `main` |
| `tcp` | The two machines of TCP | `main` |
| `assistant` | The machine of the assistant: a request and its reply with an act that reads, a grant-adding act that the bridge stops and the principal refuses in the act dialog, and a malformed model reply that the border of the agent runner refuses with its error record | `main` |
| `random` | The three machines of the randomness: the first has the entropy device (`virtio-rng-pci`), the other two have none | `main` |
| `quic` | The machine of QUIC through the network service | `main` |
| `remote_display` | The machine of the remote display: the peer is the viewers, and each refusal comes first (a key that no principal allowed, records before and after `Session_Start` that the protocol forbids, a record past its bound, input from a key of the view alone, a viewer that never takes its viewer frame, a third viewer); then the viewer rebuilds the screen from its screen pieces, which the tool compares with a picture of QEMU of the same moment, an allow of the input keeps the session, its key super opens the palette, a revocation ends its session with a viewer frame in flight, and the session of a named principal in front ends the session of a key of principal 0 | `main` |
| `network` | The machine of the network service, then a machine with no network device, which refuses the processes with an endpoint and runs the rest | `main` |
| `principals` | The two machines of the principals, then the ten machines of the keys sealed by the TPM, with a software TPM whose state they share: nine with Secure Boot on, on the volumes `secure_boot` and `other_system`, and one with Secure Boot off, where the seal is refused (`PRINCIPALS.md`, "8. The tests") | `main`, `secure_boot`, `other_system` |
| `disk_processes` | The six machines of the disk processes: a module that the boot image does not hold starts from the store `module_files`, gets the store of its nickname, and finds its data after a restart; the module file service stores the same file from the network and lists the hash of the bytes of each file; a process calls a library module that the root service found in the store by the hash of its bytes, and is refused when the file of the library has other bytes; with the machine passphrase, its grant survives the restart, and a table that another key signed gives no grant and is not written over; a grant and a client key of `remote` that a console of the session of the named principal alice gives survive the restart and her unlock ("The disk of the disk processes") | `main` |
| `missing_devices` | The three machines of a part that the machine lacks, each with its line and a later step that works: a machine with no display device (`-vga none`) starts no compositor and no console, and the boot pass of `settings` through the storage service, then `unlock`, run; a machine with no PS/2 controller (`i8042=off`) stops the input service and shows the desktop; an entropy device whose source never answers (`rng-egd` with no client) passes the deadline of its reads, which count as refused | `main` |
| `trusted_boot` | The volumes of the trusted boot: the five refusals of the boot program, a kernel that asks more memory than the machine has, whose stop stays on the boot display, the two machines of the measure with a software TPM, and the three machines of Secure Boot; then the release image: the volume of Secure Boot packaged as the files of a release, verified, decompressed and started from its GPT disk; then the six machines of the TPM floors, with one software TPM: a newer system raises the floors, swtpm alone plants an index with an authorization value and a foreign index, which the next start removes, the older system and the older key are then refused, and with Secure Boot off each floor is foreign | `main`, `changed_module`, `wrong_signature`, `other_system`, `changed_kernel`, `without_description`, `stated_hash`, `kernel_memory_raised`, `secure_boot`, `secure_boot_changed`, `newer_system`, `newer_key` |
| `hierarchy` | The machines of the hierarchy of storage | `main` |
| `tablet` | The four machines of the virtio tablet: at its place (`virtio-tablet-pci` at 0x15) the root service gives it to the input service, a report of the tablet presses the maximize button of the console and then its restore button, a double press on the title maximizes it, a drag of the title restores it under the pointer, Control+Shift+Up during a drag of an edge asks for no second size, and after a stop of the input service the start policy starts it again and the tablet works again; another virtio device at its place, and a tablet at another place, leave the PS/2 mouse only; with no PS/2 controller the input service goes on with the tablet | `main` |
| `power` | The loss of power: of the storage, of the settings, of the ranges, the write that the disk drops, and the disk that stops to answer | `main` |
| `persist` | The eight machines of the persistence of the storage on one disk, which the tool cuts and damages between two machines; then two machines on a new disk: a plan of principal 0 that names the holder of Settings, which the start policy reaches from the first start after the restart, and the audit spaces of the collector, whose pair gives each record of its source and whose chains hold after a stop of the collector and after the restart | `main`, `plan_and_audit` |
| `extended_state` | The three machines of the extended state | `main` |
| `return_fault` | The machine of the return to a process | `main`, `without_return_check` |
| `kernel_events` | The machine of the kernel events, then the thread counters on the same machine: `counters` counts a loop of 1 000 000 turns (at least one instruction retired for each turn, the one count that the test checks) and the same reads of 2 MiB in order and by page, as measures. After the machine, the tool reads the last boot line "kernel: performance counters" of the test machine; a line with counters must say that the first processor passed the trial of the registers. When the kernel found no counters, or a processor refused their trial, it checks only that the commands gave `Unsupported`, and it writes what the host gives as the explanation (`ARCHITECTURE.md`, "The counters of a thread") | `main` |
| `self_tests` | The machines of the self tests of the kernel: each one does one thing that the processor must refuse, from its own boot volume | `self_test_1`, `self_test_2`, `self_test_3`, `self_test_4`, `self_test_5`, `self_test_6`, `self_test_7` |
| `debugger` | The two machines of the debugger: the contract of the kernel with the record and the replay of a process with a shared writer, then the commands of the service `debugger` | `main` |
| `ranges` | The machines of the ranges of storage | `main` |
| `quic-real` | The QUIC client of OpenSSL against `quic_echo`, through the UDP relay of the peer | `main` |
| `outside_module` | No machine: the build of the examples of a module outside the sources, as a developer types it | `main` |
| `host_modules` | No machine: the loader and the descriptions of the exports of the build, on the host | `main` |
| `iommu_amd` | The machine with the IOMMU of AMD with interrupt remapping (`amd-iommu,dma-remap=on,intremap=on`, `kernel-irqchip=split`), with the disk of the measures and an entropy device behind a conventional bridge (`i82801b11-bridge`) at the place 28 of bus 0: the system with translation and interrupt remapping on, then the test device service `iommu_device` on that disk, which also holds the registers of the entropy device, so the kernel gives both one domain of the requester of the bridge; its message interrupt arrives through the interrupt table of that requester, and its device does not reach a page that it did not declare, with the line of the DMA fault from the event log; QEMU records no event for a refused message, so no line of a refused interrupt is waited for; without the registers of the entropy device, its declaration is refused, with the line of the kernel, and a read of the disk into a page that it declared before does not end: the tool stops the machine (which ends each read that QEMU took), gives the disk a new size with `block_resize` and starts it again, and the service then finds its page as it was and no interrupt of the device, the configuration interrupt of the new size too; then `net` through a device window | `main` |
| `iommu` | The machine with the IOMMU of Intel with interrupt remapping (`intel-iommu,intremap=on`, `kernel-irqchip=split`), with the disk of the measures behind a root port of PCI Express and the entropy device: the system with translation and interrupt remapping on, the two reads of the entropy device through the unit, then the test device service `iommu_device` on that disk, whose message interrupt arrives through its entry, whose messages to entries that it was not given are refused with a line, and whose device does not reach a page that it did not declare, then `net`, whose datagram region the network device reads through a device window (`ARCHITECTURE.md`, "K5. Device grant and interrupts") | `main` |
| `fault_ring` | The machine of the fault ring | `main` |
| `sound` | The machine of sound, with a virtio sound device (`virtio-sound-pci`) whose output goes to a wave file: `tone` plays a tone of 440 Hz at 500 ms after the frame 0 of its stream and checks eight refusals of the sound service, a second `tone` is refused, and the tool finds the tone in the file by its start, with the crossings of zero of 440 Hz and its 24 000 frames, and checks its place against the frame that `tone` names (`SOUND.md`, "4. The test") | `main` |
| `crypto` | The machine of the module `cryptography` | `main` |
| `guest` | The machine of a guest: `guest_demo` runs seven bytes of 16-bit code in a guest, receives its port write of 42 to the port 0x80 as an exit record, sees its `hlt`, and gets its `int1` as an exit `Other` with the exit code 0x88 (icebp); `Memory_Protect` refuses a read-only protection and a part of a switching mapping, and an instruction that writes the page that holds it ends the run with the exit `Writes_Own_Page` and the address that it writes. The tool reads the host first: on a host that gives the test machine no SVM, the machine checks only that `Guest_Run` gives `Unsupported`, and the tool writes that no guest ran, and why (`ARCHITECTURE.md`, "A guest") | `main` |
| `linux` | The machine of a shell of Linux: its data disk holds the private store `linux` with the bzImage of Nixpkgs and an initial archive with a static busybox. The start menu starts `linux`, Linux boots in a guest on the serial console, the tool types `echo modus-guest-ok` in the terminal window and waits for the output, then types `poweroff`, and `linux` ends with the halt of the guest. On a host that gives the test machine no SVM, the machine checks only that `linux` says that no guest runs | `main` |
| `no_pit` | The machine with no time base: no 8254 (`-machine q35,pit=off`) and a processor whose CPUID states no frequency of its cycle counter; the kernel writes its line and stops with the code 1 | `main` |
| `fails` | The machine of a start that fails: a boot image with no start policy, so the rescue start policy is absent too, and the boot display shows the cause; then the tool compares the hash of each role contract that the root service writes at its start with the hash that the host computes | `fails` |
| `start_policy` | The eight machines of the start policy (`ARCHITECTURE.md`, "The start policy"): the key R on the serial line, the console input of the firmware with no screen; a start list whose row of the console names a module that does not exist, so the rescue takes over, and the rescue list of that image restarts a row that stops with Failed until its count ends, and no row that stops with Refused; three machines with one variable store: the boot program writes the boot entry `modus (rescue)`, `BootNext` to that entry starts the rescue, and the entry with a word that names no start request stops the boot program; then three machines with a software TPM and Secure Boot on: principal 0 chooses a start policy from the disk, the next start runs it and PCR 12 holds its hash, and a chosen start policy that fails gives way to the rescue, with PCR 12 after two extends | `main`, `missing_console`, `secure_boot` |
| `shortage` | The machine of the shortage of frames | `shortage` |
| `operation_sequences` | The machine of the operation sequences, with the kernel that ships and one processor: the tool writes the seed sequences in the mailbox of `operation_fuzzing` through the memory file of the machine, and checks each answer against the statuses of the reference, the forms of the operations and the budget of the sequence ("The operation sequences") | `operation_sequences` |

### The derivations of the check

In the check of the flake, each test part is a part derivation of its own, `machine-test-<part>`, so Nix runs again only the parts whose inputs changed. The design is in `src/md/infrastructure/full_check.md`, "The derivations of the check".

- **The test inputs.** A whole build of the tree (`systemBuild`) runs `modustool test_inputs`: it copies the files of the build that the machine test reads (the boot volumes and boot images, the module files and their debug objects, the resources, the fonts, the pointers, the keys and the variable stores that the build wrote) into a folder, and Nix hashes the folder. No LLVM IR, object, linked file, build record, list of the compiler or log is a test input: these name the compiler in the store, or the time of one build. The derivation `testInputs` holds the folder, named by that hash.
- **A part derivation** depends on the binary of the tool of its part, on `testInputs`, on the sources of `src` and `resources` with no host test and no intent file, and on the programs of the host. It runs `modustool test <part> from <test inputs>`: the boot volumes and boot images are links to the store, every other file a copy. Its output holds its logs, its pictures and the count of its checks.
- **What a part reads of the build.** Past its boot volumes, each part reads the module files and the debug objects, and a part names in its row the other kinds of files of each module that it reads (`reads`: the source lists `build/modules/<name>/sources.list` and the fact key lists `build/modules/<name>/reached_facts.list` for `host_modules`). `test_inputs` refuses, before any machine starts, a part that reads a kind that the test inputs drop (the linked files, the lists of the compiler, the build records), or a file of a module that they lack. A host test reads the sources of the tool and refuses a procedure of a part that reads a kind that its row does not name.
- **The host checks** (`hostChecks`) run `modustool check without_machines` on the whole tree, with the test of the debug objects against the linked files.
- **The join.** `boot-test` runs `modustool test_join`, which joins the logs and the pictures of the host checks and of each part, adds up their counts of checks, and names the file of the times of each part `test_times_<part>.txt`. It refuses a part that lacks, a part twice and two outputs that write one file.
- **What runs again.** A change of a guide, an intent file, a news entry or a host test gives the same test inputs and the same binary of the tool, so Nix takes each part from the store, unless the change reaches the pages of the manual of the boot image. A change of a source of `src` or `resources` runs every part again: a part reads some sources at its run. A change of the core of the tool changes the binary of each part, so every part runs again. A change of a scenario file changes the binary of the parts that the manifest names for it; when the whole build gives the same test inputs, only those parts run again.
- **At once.** Nix runs the part derivations at once, up to its `max-jobs`. Each part uses four processors and 1 GiB of memory, one machine at a time. `screenshots` passes `--max-jobs` itself, with the bound of `modustool test`: the smaller of the processors divided by four and the available memory less 4 GiB, in GiB, at least one. Pass the same count to `nix flake check`; the line of `screenshots` gives it. A count above the bound by processors runs slower; a count above the bound by memory makes the host swap, and a machine that gets no processor fails its step.
- **Every failed part in one run.** `screenshots` and the workflows build the check with `--keep-going`: Nix runs every part past the first one that fails, and a failed part keeps no output, so the next build runs it again. After a failed build, `modustool failed_parts` (which `screenshots` runs) reads the build log of each derivation whose output is not in the store (`nix log`), writes it whole to `build/failed_parts/<part>.log`, and prints one line for each: `modustool: main failed: modustool: test failed: step 1275: ...; the machine test_output; its whole log: build/failed_parts/main.log`. A part with no log did not run: a derivation that it needs failed, or the build stopped first; no part depends on the host checks. The host checks have the name `host_checks`. `screenshots` evaluates the check once and builds that derivation path, so the list names the derivations that ran even when the work tree changes during the check. After `nix flake check --keep-going` by hand, run `modustool failed_parts` on the same tree: it evaluates the tree as it is, and says so when nothing of that evaluation was built.
- **The measure.** `screenshots` prints "modustool: measure: the test parts of the check of the flake: <n> taken from the store, <m> run". The evaluation of the flake builds the test inputs first, because it reads their hash: a whole build after any change of the tree.
- **The proof.** `modustool part_cache` copies the tracked files into four trees under `build/part_cache`, adds a line to an intent file in one, to a host test of the tool in another, and to the scenario file of the part `debugger` in the last. It requires the same derivation of each part in the first three; in the last, another derivation of `debugger` and the same one of each other part; and another derivation of the whole build in each changed tree.
- **The binary of one part** holds the core of the tool and the scenario files of that part, which `tools/modustool/machine/test_part_files.json` names. It runs that part only: `test` of another part, and the whole test, are refused with the names of the parts that it lacks. A file that no part names is of the core. The design is in `src/md/infrastructure/full_check.md`, "A binary of the tool for each part".

### A step that fails

A step that ends at its bound says only that a line did not come: the system can hang, or the host can give the machine no processor. So the line of a step Wait that ends at its bound says what the host gave the machine over the wait. At the start of the step and at its failure the tool reads utime plus stime and run_delay of each thread of the QEMU of the machine (`/proc/<pid>/task/<tid>/stat` and `schedstat`), and the total of the line `full` of `/proc/pressure/memory`:

```
modustool: test failed: step 3: the machine did not print "compositor: surface console" within 2m0s; the host ran the machine for 400 ms of the 120.0 s of the wait; its threads waited 118000 ms in all for a processor; every task of the host waited for memory for 3000 ms: the host starved the machine, which is no hang of the system
```

The end of the line is a verdict, given only when the counters that it rests on are known:

- **The machine had the processor**: it ran for more than a tenth of the wait, so the line did not come from the system. Read the system.
- **The host starved the machine**: it ran for a tenth of the wait or less, and the wait of its threads for a processor plus the memory stall of the host make half of the wait or more. The test ran more parts at once than the host holds, or another program took the host.
- **The machine was idle**: it ran for a tenth of the wait or less, and the host did not stall it. Its processors halted on an event that did not come: read the system.

A counter that the tool cannot read, or that went backwards over the wait (a thread of QEMU ended), is "unknown", with its reason. These numbers are facts of one failure, never a condition of a test.

On each machine with a TPM device, the log of a step that ends at its bound can hold wait reports: the TPM service and `unlock` write one each 30 s of a long wait of the TPM, "tpm: a wait passed 30 s: ..." or "unlock: the wait for the TPM service passed 30 s, for ...", and a last fact when the wait reaches its own bound. Each names the step of the interface, the TPM command, the locality and the request that waited (`src/md/features/tpm_sealed_machine_key.md`, "A wait that is long"). Read them to see which step of the TPM the machine waited for. They are facts of one failure, never a condition of a test: a wait report fails no step.

Then, while QEMU runs, the first act of the tool, before the picture of the firmware and before it stops QEMU, is to read the state of each processor:

1. Through the machine protocol, it reads the run state of QEMU (`query-status`), stops the machine if it runs, sends `info registers -a` and `info cpus` to the monitor of QEMU (`human-monitor-command`), then lets the machine run again. The stop gives the registers of each processor at one moment.
2. It writes the two texts as the monitor printed them in a file beside the log of the machine: `build/test_output_tpm_key_4_processors.txt` for `build/test_output_tpm_key_4.txt`.
3. It prints, in one write, with the run state of QEMU: `running`, or the state of a machine that QEMU stopped itself (`io-error` after a write error of a disk, `internal-error`, `guest-panicked`), whose processors stand still with no fault of the system:

```
modustool: the processors of build/test_output_tpm_key_4.txt at the failure, QEMU in the state running: build/test_output_tpm_key_4_processors.txt
    processor 0, halted, at 0xffffffff80012345: the kernel: idle_wait + 0x1
    processor 1, running, at 0x7e8c2a0: no known code
    processor 2, running, at 0x7f6a1000: the firmware, in system management mode
    processor 3, halted, at 0xfffffff0: the firmware
```

The instruction address is RIP in 64-bit code, and the base of CS plus EIP in the other modes. Halted is the field `HLT` of the registers. The tool names the code of an address in this order:

- **The firmware, in system management mode**, when the field `SMM` is 1: that memory is the firmware's alone.
- **A process**, at privilege level 3.
- **The kernel**, from `KERNEL_BASE` up: the procedure and the source line come from the debug object of the kernel module of the boot volume, at the address less `KERNEL_BASE`, as the tool names a frame "module + offset" of a stack trace. With no debug object, the line gives the offset.
- **The firmware**: its flash, which QEMU maps under 4 GiB with the sizes of the code file and of the variable store of the machine, and the copy of the end of the flash under 1 MiB. A processor that waits for its start is at the reset vector, in the flash.
- **No known code**: any other address. The firmware also runs code that it copied to memory, and the boot program is where the firmware loaded it; the tool knows neither range, so such an address is no known code. The registers in the file still give it.

This read never makes a test fail, and never hides the first fault: the line of the failed step comes first. If QEMU ended or does not answer, the tool writes one line, "modustool: the processors of <log> at the failure: none: ...", and goes on. A text that the reader of the tool refuses gives one line with the fault, and the file keeps the text. A host test gives the reader damaged texts first (`tools/modustool/machine/processor_state_test.odin`).

### The operation sequences

The test part `operation_sequences` boots the volume `operation_sequences`: the kernel that ships, one processor, and the memory of the machine in a file of the host (`memory-backend-file` with `share=on`). Its boot image holds the process `operation_fuzzing` and its runner, which no other image holds; a release refuses an image that holds one of them. The design is in `src/md/infrastructure/kernel_fuzzing.md`.

The root service starts only `operation_fuzzing`, with the machine with the right Physical only, the boot image and the log. The process makes its mailbox, a contiguous memory object, and writes its physical address on the log: `operation_fuzzing: mailbox at <address>, <pages> pages`. For each operation sequence that the tool writes there, it starts a new runner with a new budget, waits for its stop, writes the answers of the kernel and the budget before and after, and writes the end line `operation_fuzzing: sequence <number> ended` before it counts the sequence.

The tool reads and writes the mailbox at that offset of the memory file. It checks each execution:

- the runner ran or stopped; a refused sequence, a runner that did not start and a runner that did not stop are faults;
- the budget of the sequence holds after the runner what it held before: pages, processes, threads;
- each status is `Ok` or a status of the list "**Statuses**" of the reference comment of its operation, and a word that names no operation, 0 included, gives `Bad_Operation` with the error record `Unknown_Operation` of the kind that the runner sent, and leaves its table of error details unchanged;
- no value that the form of its parameter refuses gives `Ok`;
- each table of error details agrees with the forms: unchanged after `Ok`; after a refusal, the error record first, then one detail of the right problem and limit for each other argument that the form refuses;
- a planted `Handle_State` gives the kind that the reference names, and two planted `Budget_Read` with only refusals between them give the same amounts.

The part runs the seed sequences: one step of each operation with arguments that fit their forms where a start handle can, then the cases that must succeed or be refused with their details. The variants of a fuzz finding that the corpus does not hold are such cases, with the answers that they must get: the status, the error record, a detail that must be there, and an argument that must have no detail. It then runs each regression input of the corpus ("The corpus of the kernel operations"): each sequence of its life with every oracle, then the answer of each step of its last sequence. A file of the corpus that the reader refuses fails the part. The line of the end is "the machine ran <n> operation sequences and <r> regression inputs, <m> steps, through the mailbox: ...".

`modustool fuzz replay operations <file>` runs one sequence file on a new machine of the same volume, with every oracle, and ends with the exit code 0 when no oracle breaks. A file that is no operation sequence is refused before the build.

### The fuzzing of the kernel operations

`modustool fuzz operations <executions> [seed]` runs that count of operation sequences on machines of the volume `operation_fuzzing`, through the same mailbox and the same oracles as the test part. The volume holds the image of the test part and the counted kernel `kernel_edge_counters`. The design is in `src/md/infrastructure/kernel_fuzzing.md`.

- **The counted kernel.** The build makes it from the sources of the kernel with the setting `KERNEL_EDGE_COUNTERS`, and adds a call of a callback in `src/modulus/edge_counters.asm` at each edge of its code with `opt`; no other kernel links that file, and each other kernel gets the setting false. It counts only the commands and the exceptions of the runner and of the processes that it creates. It runs on one processor: it stops at its start on a machine with more, and when another processor ran its code or was not reset. Its boot line `kernel: TEST BUILD: edge counters at <address>, <count> edges` names the physical address and the count of its counters, in decimal. The tool refuses a count of 0 or past 262 144, a number with a sign or a leading zero, and a range outside the memory of the machine, as an error of the build. No process reads the counters: the tool reads them through the memory file of the machine.
- **The checks of the counters.** Each run checks that each counter is 0 after the boot, and again before each sequence, and that each counter past the guards of the linked kernel stays 0 after each sequence. A counter that breaks one ends the run with the exit code 1: a fault of the counted kernel, not a finding. Each build checks that the module `kernel` holds no text `kernel: TEST BUILD:` and that each test kernel holds it.
- **The engine.** The tool writes zeros over the counters before each sequence and reads them after its end line. A sequence whose counters give an edge a count in a class that the run has not seen runs again as the next execution, and the tool keeps its choices when the two runs agree on such a class. The choices of a sequence are, in order: a second run that waits, each reach input of the corpus once, one new draw in four, else a kept input with 1, 2, 4 or 8 mutations. The run prints the kept inputs, the features and the edges, and the second runs.
- **The reach inputs.** At the end of a run that ends with no error and that ran each reach input of the corpus, the tool writes the smallest set of the kept inputs that gives each of their features into `reach/` of the corpus of the kernel operations, smallest first, in the room that the regression inputs leave in the bounds of the corpus, and removes each other file of `reach/`. It prints how many it wrote and how many it left out. Read the change of `reach/` before the commit.
- **The other machines.** A machine test of another volume whose log has the boot line of the counted kernel fails. `fuzz regression operations` and `fuzz replay operations` boot the volume `operation_sequences`, whose kernel is the kernel that ships.

- **The count.** The command refuses no count, a count of 0, a negative count and a text that is not a number, with the exit code 2: each machine life boots a machine, so a run with no count would have no end. With no seed, it takes the hash of the sources and the clock, and prints the seed.
- **The machines.** One machine runs at a time, with one processor; other machines of the host can run beside it. A machine life holds at most 1024 sequences, then the tool ends the machine and boots a new one. A fault of the kernel ends the life too. Two boots in a row that do not reach the line of the mailbox end the run as an error of the build.
- **The sequence of a line.** After each count, the tool waits for the end line of that sequence, within the hang bound, and reads the lines of the kernel up to it: a line that comes after the count still belongs to its sequence. Before a life ends with no fault, the tool reads the log for 1 second more, or until QEMU ends; a fault that it finds there belongs to the last sequence.
- **A fault of the kernel.** The machine stops (the kernel stops with a fault or a broken invariant), a sequence does not end within the hang bound, `operation_fuzzing` or the root service stops, the mailbox holds counts that the tool did not write, or an oracle breaks: a status outside the reference of the operation, a table of error details that disagrees with the forms, or a budget that does not come back whole.
- **An error of the tool.** A read or a write of the memory file that fails, or a file of a finding that the tool cannot write, ends the run with the exit code 1, and is never a finding.
- **The signature.** Each fault has a signature with no number that changes from one run to the next: `stop <reason>: <procedure>: <report>`, `hang: <operation>`, `isolation: <line>`, `mailbox: …`, or `oracle <oracle>: <operation>`. A word with a decimal digit and a word of 16 hexadecimal digits become `#`. The procedure of a stop comes from the debug object of the kernel, at the address of the report. The run keeps one fault for each signature and counts the others.
- **The names.** The generator changes the first byte of a process name that is `root` or `operation_fuzzing`, so the fault of a child never reads as the stop of one of them.
- **The minimization.** On new machines, the tool tries the last sequence alone, then the whole life; then it removes ranges of the sequences before the last, then ranges of the steps of the last sequence, while the last sequence still gives the fault with the same signature. It makes at most 256 boots for one finding. A boot ends within 180 seconds and a sequence within 120 seconds, so one finding of a hang takes at most about 21 hours, and a run of 8 findings about 171 hours, plus its executions.
- **The findings.** Each one is a folder `build/fuzzing/operations/<seed>/<name>/`: `finding.txt` (the signature, the text, the seed, the minimization), `life/` and `minimized/` (one file for each sequence, in their order), and `machine_log.txt`. A run of another seed writes another folder; a run of the same seed writes its findings again. When the minimized life is one sequence, `fuzz replay operations` runs it again.
- **The end.** The run ends at its count, at 8 findings, or at an error of the build or of the tool. It prints the executions in one second of the sequences and of the whole run as a measure, never as a condition, and ends with the exit code 1 when it kept a finding.

### The corpus of the kernel operations

The corpus of the kernel operations is in `tools/modustool/fuzz/fuzzing_corpus/operations/`, with the layout of the corpus of a target ("The fuzzing"): `regression/` and `reach/`, one file for each input, named by the BLAKE3 hash of its bytes, at most 512 inputs and 1 MiB. The design is in `src/md/infrastructure/kernel_fuzzing.md`.

- **A regression input** is a minimized life of a finding after its fix, the signature of the finding, and the answer of each step of its last sequence on the kernel that ships: the status and, for a refusal, the kind and the argument of the error record and each record of the table of error details. The test part `operation_sequences` runs each one and checks each answer, so a change of a refusal fails the part even when the new refusal stays in the forms.
- **`modustool fuzz regression operations <finding>`** takes a folder `build/fuzzing/operations/<seed>/<name>/`, runs its minimized life on a new machine with every oracle, and refuses it with the exit code 1 while it still breaks one. It then writes the input into `regression/` and prints the answer of each step: read them before the commit. A folder with no `finding.txt`, no minimized life or a file that is no sequence is refused with the exit code 2.
- **A change of an answer on purpose.** The commit that changes the answer writes the input again with the command and removes the old file.
- **The reach inputs** are choice sequences of the generator, cut after the last byte that the generator read. `fuzz operations` writes them at the end of its run ("The fuzzing of the kernel operations").
- **The check.** `modustool check` refuses a regression input that its reader refuses: a short file, another magic word or format, a count past its bound, a size that is not its parts, a sequence that `check` refuses, and an answer that names no status or no error kind. It refuses a reach input from which the generator builds a sequence that `check` refuses.

### The disk of the disk processes

The part `disk_processes` needs a data disk that holds a module file before any machine runs. The tool writes that disk itself (`tools/modustool/build/module_disk.odin`, the writer that `module-disk` uses too): a file `build/test_disk_modules_disk.img` in the format of the storage service (`STORAGE.md`, "3. The format on the disk"), with the store `module_files`, whose root tree holds the module files and, for the test, a disk grant table, and the store `module_files.principal.1` of the named principal 1, with a module file and a disk grant table. The writer makes one commit of a new disk: the blocks of data and the object nodes of each file, one leaf with the entries in the order of their names, the store block, then the root. A block of zero bytes is a hole, as in the storage service. The writer changes no disk that exists, and takes at most the 24 entries of one leaf.

The tool prints one line for each file, with the hash that the command `start_from_disk` names:

```
modustool: build/test_disk_modules_disk.img: the store module_files holds visitor, <count> bytes, hash <64 hexadecimal digits>
modustool: build/test_disk_modules_disk.img: the store module_files holds the debug object of the module <64 hexadecimal digits>, <count> bytes
```

The module of the test is `visitor`: a row of the module table of the tool with no `image`, so the build makes its file and no boot image holds it. The disk of the test has these entries:

| Entry | Its bytes | What the machine checks |
|---|---|---|
| `visitor` | The module file | The root service starts it; the process writes that its context holds the log, a window and its budget, and no handle of a grant; with the grant store, it counts its visits in the store of its nickname |
| `changed` | The module file with one byte changed | The line names the hash of the module file: the root service refuses the bytes, and the log holds their hash |
| `notes` | The module file | The grant table of the root service gives the name `notes` a store: the root service refuses the name before any read |
| `outsider` | The module file of `visitor` built outside the sources by `module-build` ("An outside module in a machine") | The root service starts it with no grant; the debugger attaches to it and names a frame of its held thread by its procedure, its file and its line |
| the hash of `outsider` | The debug object of `outsider`, under the 64 hexadecimal digits of the hash of the module | The debugger service reads it through the connection that reads only of the debug access, and checks that it names that module (`MODULE_CONTRACT.md`, "The debug object of a disk process"); `module_files.list()` does not list it, and the import scan does not read it: its name of 64 bytes is no name of a disk process |
| `grant_table` | A disk grant table that gives `visitor` the grant store, with a tag under a key of zero bytes | What a reader of the disk with no passphrase can write: the root service refuses it when the machine passphrase is set, and writes over it; restored later, it is refused under the opened key and kept |
| `store_library` | The library module `store_library`, a row of the module table that no boot image holds | The import scan finds it by the hash of its bytes, for `store_importer` |
| `store_importer` | The process `store_importer`, which imports `store_library` | The root service starts it with the library of the store; the process calls `triple(14)` and writes 42 |

The scenario also asks for a name with no entry. It starts the storage service before the first line that reads the store, so no step depends on the time of the open of the disk.

Then the scenario checks the disk grant table of principal 0 (`MODULE_CONTRACT.md`, "The grants of a disk process"):

1. `allow("visitor", "root_ring")` is refused: no command gives that grant.
2. `allow("visitor", "store")` gives the store to the file of `visitor` that runs.
3. `start_from_disk("visitor", <the hash of changed>)` is refused before any read: the nickname names another file.
4. `start_from_disk("visitor", "")` starts the file of the row with the store `disk-visitor`; the process writes its visit 1 there and reads it again.
5. Two calls of `nickname_move` point the nickname to another file and back; the log says "root: the file ... will get the data of visitor" before each change. The next start has the store, and the visit 2.

The first machine has QEMU user networking, and the listener of the tool serves the module file at `/visitor` (`NETWORK.md`, "The tests"). The console connects to the module file service (`MODULE_CONTRACT.md`, "A module from a disk"):

1. `module_files.receive("received", "/visitor")` fetches the file through the network of the machine, stores it under the nickname `received`, and writes its size and the hash of its bytes: the hash that the tool computed.
2. `module_files.receive("grant_table", "/visitor")` is refused: the service writes no file over the disk grant table.
3. `module_files.list()` writes one line for each module file, with the hash of its bytes: the hash of `changed` is its own, and `received` and `visitor` have the same hash; then "listed 8 module files".
4. `start_from_disk("received", <the hash>)` starts the file with no grant.

Then the import scan (`MODULE_CONTRACT.md`, "A module from a disk"):

1. `start_from_disk("store_importer", <its hash>)`: the root service says that the process imports 1 module that the boot image does not hold, then that the import is the file `store_library` of the store, checked on its bytes. The process writes "triple(14) of the module store_library of the store module_files gives 42".
2. `module_files.receive("store_library", "/store_library_changed")` writes the library with one byte changed over its entry: the listener of the tool serves those bytes.
3. The same start is refused with one line: the process imports the hash of the library, and no file of the boot image or of the store has bytes with this hash; the scan read 7 files, each entry but the process and the disk grant table.

A second machine starts on the same disk. The table of principal 0 did not last: `start_from_disk("visitor", "")` is refused. After a start by the hash and a new `allow`, the process finds the visit 3 in the store of its nickname. Then `machine_passphrase()` opens the window of `unlock`, and the scenario types the passphrase two times there. The root service reads `grant_table`, refuses it with its line ("its tag does not verify under the key of the principal"), and writes its own table of 1 row (`PRINCIPALS.md`, "Principal 0 and its machine passphrase").

A third machine starts on the same disk, and the window of `unlock` asks for the machine passphrase. Before it is typed, `start_from_disk("visitor", "")` is refused, as the table has no row, and `allow` is refused. A wrong passphrase opens nothing. The right one gives the row back: the process has the store of its nickname, and finds the visit 4 there. `start_policy_choose("visitor", "")` is refused, as the machine key needs the machine passphrase (`PRINCIPALS.md`, "The start policy of principal 0"). `disk_persistence("visitor", "forget")` then writes a table of 0 rows. The console then restores the first version of `grant_table`, which the tool signed with the key of zero bytes (`storage.restore`).

A fourth machine starts on the same disk. The machine passphrase opens the record, and the table on the disk does not verify under its key: the root service refuses it and keeps it, with no write. `start_from_disk("visitor", "")`, `allow` and `machine_passphrase()` are refused.

The disk has a second store, `module_files.principal.1`: the store of the module files of the named principal 1, written before that principal exists. It holds `visitor` and the same forged `grant_table` (`PRINCIPALS.md`, "The disk grant table of a named principal").

A fifth machine starts on the same disk. The scenario skips the machine passphrase with Enter, and `principal_create("alice")` opens the window of `unlock`, where the scenario types her passphrase two times. The root service reads the table of principal 1, refuses it, as the principal is new, and writes a table of 0 rows. A console started from the menu of the desktop runs in the session of alice. In it, `start_from_disk("visitor", <the hash>)` reads the store of alice, and `allow("visitor", "store")` writes a table of 1 row. `remote_allow("{client key}")` allows the key of the client of the peer for alice, and writes the table again with 1 client key of `remote`. The next `start_from_disk("visitor", "")` has the store `disk-visitor.principal.1`, and the visit 1 there.

A sixth machine starts on the same disk. The scenario skips the machine passphrase and types the passphrase of alice. The root service reads her table, 1 row and 1 client key, writes nothing, and the key holds again for alice with no new allow (`PRINCIPALS.md`, "The client keys of remote"). In a console of her session, `start_from_disk("visitor", "")` has the grant store again, and the visit 2. Then `remote` starts, and a call of the peer acts for alice. `remote_disallow` in her console writes the table with no key, `remote` ends the open connection with the code Revoked, and refuses the key in the next handshake.

Host tests check the writer with the code of the open of the storage service (`src/library/internal/storage/storage_mount`): no block of the image is wrong, the counts of the store are the counts of what it names, each object gives its bytes, each entry has the hash that its block tree gives, and a file with no hole has the BLAKE3 hash of its bytes.

### The clock of a test machine

The setting `appearance` is `auto` on a new disk, and `auto` follows the hour of the day (`docs/DESIGN.md`, "The appearances"). So the tool gives each test machine a real-time clock at 01:00 UTC of the day of the host (`-rtc base=`, `tools/modustool/machine/machine_clock.odin`): each picture of a test is in the dark appearance, whatever the hour of the run, and a run has six hours before 07:00. `modustool run` gives the machine the clock of the host.

The tool keeps the difference between the clock that it gave and the clock of the host. Each check of a date of the machine (the step `Date`, a call with `date_after`, the field `Date` of `server`) takes the difference off, then checks the date by order against the clock of the host.

The step `Appearance_Auto` checks the line that the setting `auto` writes: "settings: the appearance in force is dark: auto, light from 07:00 to 19:00 of the local time; the local time is 01:04 with a zone of 0 s, at 1794791040 s since 1970". The tool checks the date of the line as a step `Date` does, then computes the rule of the day over that date and that zone with the procedure of the system (`src/library/internal/settings/appearance`), and the line must name the same appearance. The test does not choose the hour: it checks the rule at the hour that the machine read. With `expected`, the zone of the line, in seconds, must be that number.

The test of the time zone (`src/md/features/time_zone.md`) sets `settings.set_time_zone("+08:00")`: the local time of the machine is then from 09:00 to 15:00, in the day. The step `Appearance_Auto` with `expected = "28800"` checks the line of `settings` ("settings: the appearance in force is light: ..."), which comes after the process `date` copied the zone. The step `Bar_Local_Time` checks the line of the bar: "compositor: the bar shows the local time 2026-11-16 09:04:05 with the time zone +08:00, at 1794791045 s since 1970". The tool checks the date of UTC as a step `Date` does, the zone against `expected`, and the local time against that date in that zone. The test then sets `+00:00` again and checks the dark appearance and the bar in UTC.

### The times of a test

`modustool test` reads the monotonic clock of the host at the start and at the end of the build, of each machine and of each step. At the end of a test that ran a machine, passed or failed, it writes `build/test_times.txt` and prints a summary. Each number is a measure: no test reads one, and no time makes a test fail ("The bounds of the tests").

Each part keeps the times of its own machines, and the file joins them in the order of the table of the parts. The file has one line for each machine: its log file, its part, its result, its whole time, the time from the start of QEMU to the first line of its log, the time of its steps and the time of its stop. Under it, one line for each step, in the order of the run, in fixed columns:

| Column | What it holds |
|---|---|
| `step` | The number of the step in its scenario, from 1 |
| `kind` | The kind of the step (`Wait`, `Type`, `Launch`, `Shot`, `Call`, ...) |
| `duration` | The time of the step, in seconds |
| `waited` | The part of that time in a wait for a line of the log |
| `keys`, `key_time` | The keys that the step sent, and the time in their sends, with the wait after each send |
| `pictures` | The pictures of the screen that the step saved |
| `text` | The first 60 bytes of the text of the step |

The last step of a machine that failed is the step that failed, when a step failed.

The summary is a list of lines that start with `modustool: measure:`:

- the whole test, the build, and the machines (the start to the first line of the log, the steps, the stops);
- when several parts ran, the sum of their times beside the time of the test, then each part with its time and its count of machines, the longest first: the longest part bounds the whole test;
- for each kind of step, the count of its steps and the sum of their durations;
- the count of the keys and the time in their sends;
- the count of the pictures and their time: in the step, the wait for a settled screen, each `screendump` of QEMU and the read of its file; on a worker thread, while the scenario goes on, the conversion to PNG and the write;
- the time waited for lines of the log, added by the process of the line. The process is the first word of the text of the step before its first `:` (`clock`, `scheduler`, `[console]`);
- the 25 slowest steps, with their text.

The time of a wait says how late the line came after the step before, not what the process did: a process that runs during several steps has its time in the step that waits for its line.

One run of `modustool test main`, before the tool sent its input in batches, is the measure that the batches answer. The whole test took 625.6 s: the build 147.0 s, the machine 478.4 s for 1013 steps.

| Part | Steps | Time |
|---|---|---|
| Typed lines (`Type`) | 224 | 280.9 s; 4818 keys in all the steps, 285.6 s in their sends |
| Pointer (`Launch`, `Front`, `Move`, `Close`, `Point`, `Click`, `Drag`) | 140 | 100.4 s |
| Waits for a line of the log (`Wait`) | 454 | 49.6 s |
| Pictures (`Shot`) | 66 | 41.2 s: the fixed wait 26.5 s, the `screendump` 6.6 s, the conversion to PNG 8.1 s |

About 400 s of the 478 s were pauses of the tool, not work of the system.

The same test with the input in batches took 83 s of machine time. Of these, the 66 pictures cost 27.0 s, 26.4 s of them in a fixed time of 400 ms before each picture, and the waits for lines of the log cost 41.7 s, most of it in processes that measured a rate for a fixed duration at their start. The two answers are "When the tool takes a picture" and "A check by count, a measure by time".

### The incremental build

A build keeps the outputs of an earlier build when their inputs are the same. The rule that makes it sound is the rule of the reproducible build: the same inputs give the same bytes (`REPRODUCIBLE_BUILD.md`, "The incremental build and the same bytes"). A kept module that is not the module of its sources is a wrong system, so the tool keeps an output only when it can prove each input, and builds in every case of doubt.

**The two steps of a module.** The build of a module has two steps, and each step has its own build key and its own build record.

| Step | What it runs | What it gives | What it reads of an import |
|---|---|---|---|
| The compile step | The compiler, `llc`, the assembler and the link | The linked file, `build/modules/<name>/linked.elf`; for a kernel, also its measure lines, `build/modules/<name>/kernel_stack.measure` ("The deepest stack of the kernel") | Nothing |
| The conversion | The tool only: no compiler | The module file, and its debug object | The whole file: its hash goes into the import table, and the number of each export that an import slot names comes from it |

A source names an export of an import in a `foreign` block: a name, the parameters and the result, written by hand in the source of the importer. No file of the import stands behind it. The compiler makes a call to a symbol that is not defined, and the link leaves the symbol not defined (`ld.lld -shared`, with no file of the import on its command). So the linked file of an importer is the same for every file of its import, and the build key of the compile step holds no import. A change of the body of an export of a library compiles the library, and only converts each module that imports it.

**The inputs of the compile step.** The tool does not guess them: the compiler writes the list of the files that it read (`-export-dependencies:json`, in `build/modules/<name>/dependencies.json`). From it the compile step writes `build/modules/<name>/sources.list`: the Odin sources of the repository alone, by their path from its root, sorted. The log facts of the conversion, the check of the declarations of the imports and the test of the descriptions read that list, which names no file of the store, so the test inputs of the check of the flake keep it ("The derivations of the check").

| Input | How the tool knows it |
|---|---|
| The source files of the module and of each package that it imports, to any depth: the folder of the module, the source library (`modus:contract/`, `modus:`), and the libraries of the compiler (`base:`, `core:`) | The list of the compiler; the tool hashes each file |
| The files of `#load` | The same list |
| Every other file of the folder of each of these packages | The tool lists each folder. A file that the compiler did not read becomes a source with no change of a listed file in one way only: it is in such a folder (a new file, or a file whose build tag now admits the target) |
| The assembly files that the module links: `src/runtime/memory.asm`, the `.asm` files of its folder, and those of `src/library/modus/system` for a module with an entry | The tool lists them as the build does |
| The command of the compiler and the command of `llc`, with each flag: the checks of the kernel, the kind of debug information (`-debug-info:same-code`), the direction of the instruction scheduler of `llc` (`-misched-topdown`), the settings of the module, the features of the target | The text of the two commands (`module_compile_command`, `module_object_command`) |
| The C files of an outside source | The command of `clang` for each one (`module_c_commands`): it names the folder of the store, whose path holds the hash of the source, of the patches and of the files of `src/outside/<work>` |
| The host programs `odin`, `llc`, `nasm`, `ld.lld` and `clang` | The path of each file after each link, its size and its time. In the store of Nix the path holds the hash of the package |
| The tool | One hash over every file of `tools/modustool` and of each package of the repository that it imports, to any depth: an import of the source library (`modus:`), of the kernel parts (`kernel:`), of a package of the tool (`modustool:`), or by a relative path. A change of a file of a package of the tool thus builds each module again. The code that builds a module is in the tool. The executable of the tool is not the identity: two builds of the tool do not give the same file |

**The inputs of the conversion.**

| Input | How the tool knows it |
|---|---|
| The linked file | Its hash, which the record of the compile step holds |
| The sources of the module: the conversion reads them for the description of the exports and for the documentation | The build key of the compile step, which holds each of them, is an input of the key of the conversion |
| The module file of each import of the module table | Its hash at the time of the key |
| The imports in the order of the module table | Their names, in that order: it is the order of the import table of the module file |
| Whether the build writes a debug object | One setting |
| The tool | The same hash as for the compile step |

**Why the compile step is sound with no import in its key.** A kept linked file must be the linked file that a compile step of now would give. Each way in which an import can reach the code of an importer was checked:

- **The body of an export.** The compiler, `llc` and the link never open a file of the import, so no body of it can be inlined in the importer. To inline across two bodies of code, their sources are compiled into one module (`MODULE_CONTRACT.md`, "Closed rules"); then they are sources of that module, and the list of the compiler holds them.
- **The description of an export** (its name, its parameters, its result). The compiled code depends on the declaration in the `foreign` block of the importer, which is a source of the importer. The description in the file of the import is not read by the compile step. The conversion compares the two: it reads each `foreign` procedure of the sources of the importer and the description of the export of that name in the module file of the import, and a declaration with another count of parameters, another type, direction, record layout, result, error record or calling convention stops the build with its file and its line, and so does a symbol that became an import slot of the importer and has no compared declaration (`import_declarations.odin`; `MODULE_CONTRACT.md`, "The declaration of an import is checked"). A change of the sources changes the key of the compile step, which the key of the conversion holds, and a change of the import changes the key of the conversion: each runs the comparison again.
- **A library module** (`glossary/desktop.md`; the field `library` of the module table, set for `drawing`). The conversion refuses its module file when a segment that the loader writes is read-only after the load: a segment with a rebase (a table of addresses) or an import slot (`MODULE_CONTRACT.md`, "A library as a module"). A segment of that range of the linker with no rebase and no import slot is a constant segment for every module, and is not refused. After the modules, each build prints one measure line for each library module: the size of its file, and the size of the file of each module that imports it with their sum: "modustool: measure: the library module drawing has ... bytes; the files of the 24 modules that import it have ... bytes in all". It is a measure to compare two builds; no check reads it.
- **A module that draws through the drawing module** has two entries in its line of the module table: the import `drawing`, and the compiler setting `DRAWING_THROUGH_MODULE=true`, which makes the window layer of `src/library/modus/interface` call the exports. A host test of the tool (`modules_that_draw_through_the_drawing_module_follow_its_rules`) refuses a line with the setting and no import, a line with the setting before the line of the drawing module in the table, and a source of such a module that starts a child of its own file with no load source. The build refuses an import that is not before its importer in the table, so the drawing module comes before the compositor.
- **The layout of a record, and a constant.** An importer that uses a record or a constant of a library imports the package that declares it (`modus:contract/`, `modus:`, or the folder of the module). That package is in the list of the compiler, so its files are inputs of the compile step.
- **A file of `#load`.** It is in the list of the compiler. No source loads a module file of the build; if one did, the list names that file, and the key of the compile step holds its hash.
- **The number of an export, and the hash of the import.** They are in the module file only, and the conversion writes them. They are why the conversion holds the whole file of the import, not its description.

**The build key and the build record.** A build key is one BLAKE3 hash over the inputs of its step, each list sorted. After the steps of a module ran, the tool writes two build records: `build/modules/<name>.compile.build_record` (the key of the compile step, the hash of the linked file, the list of the compiler) and `build/modules/<name>.convert.build_record` (the key of the conversion, the hash of the module and of its debug object). The build with no debug information has its own records in its own folder.

**When a module is kept, converted or built.** At the next build the tool hashes each file of the source folders of the repository one time, on several threads, before the first compiler starts. For each module it computes the key of the compile step again, from the files of the recorded list as they are now.

- The module is **built** (the compile step, then the conversion) when the record of the compile step is absent or damaged, when its key is not the key of now, or when the linked file is absent or has not its recorded hash.
- If not, the module is **converted** (the conversion alone) when the record of the conversion is absent or damaged, when its key is not the key of now, or when the module file or the debug object is absent or has not its recorded hash.
- If not, the module is **kept**: no host process starts.

A damaged record is never an error. The tool decides for a module after its imports were built, converted or kept. A converted module has a new hash, as a built one, so each module that imports it is converted in its turn: a change goes up the levels of the imports as a chain of conversions. An import that is built again to the same bytes changes nothing above it. The tool prints one line with the counts, for example "modustool: 48 of 84 modules kept, 33 converted, 3 built: drawing (built: an input changed), clock (converted: an import or the linked file changed), ...".

**When no record is written.** The tool writes no record for a module when the compiler gave no list, or when it cannot prove that the hash and the build read the same bytes: an input file must be older than the start of the build by one second, and its size and its time must be the same after the build. The conversion reads the sources too, so the rule holds for a module that was only converted: its record of the conversion is removed. A file that was saved during the build, or in the last second before it, costs one more build of its modules.

**The boot volumes.** The build has 27 boot volumes. Each one has its own boot program, because the boot program holds its boot image and its kernel (`#load`).

| Volume | Its boot image | What differs from the main volume |
|---|---|---|
| `main` (`build/boot_volume.img`) | `boot.image`: every module of the image | The system as it is |
| `fails` | `boot_fails.image`: no `start_policy` | The start must fail: no start policy, and no rescue |
| `shortage` | `boot_shortage.image`: no input service, and `shortage`, which no other image holds: it takes nearly every page and stops the machine | Its start list and its rescue list start only the process `shortage` |
| `missing_console` | `boot_missing_console.image`: every module, and `stops_refused` and `stops_failed` | Its start list has a row of the console that names no module: the rescue takes over, and its rescue list tests the restarts after `Refused` and `Failed` |
| `plan_and_audit` | `boot_plan_and_audit.image`: every module, and `plan_applier`, `settings_stand_in` and `audit_asker`, which no other image holds | The machines of the plan of principal 0 and of the audit of the collector in the part `persist` |
| `operation_sequences` | `boot_operation_sequences.image`: every module, and `operation_fuzzing` and `operation_sequence_runner`, which no other image holds | Its start list and its rescue list start only the process `operation_fuzzing` ("The operation sequences") |
| `operation_fuzzing` | `boot_operation_sequences.image` | The counted kernel `kernel_edge_counters`, for `fuzz operations` only ("The fuzzing of the kernel operations") |
| `measure` | `boot_measure.image`: every module, and the resource `measure_run` | A measure run ("A check by count, a measure by time") |
| `without_return_check` | `boot.image` | The kernel `kernel_without_return_check` |
| `changed_module`, `stated_hash` | `boot.image` | One byte of a module, or its stated hash, changed after the system description was made |
| `wrong_signature`, `without_description` | `boot.image` | One bit of the description signature changed; no description |
| `changed_kernel` | `boot.image` | One byte of the kernel changed after the description was made |
| `kernel_memory_raised` | `boot.image` | The kernel states 1 TiB more memory, before the description was made: each check passes, and the firmware gives no pages for the kernel |
| `other_system` | `boot.image` | One byte of a module changed before the description was made; the boot program signed with the firmware signing key, for the machines of the TPM of `test principals` |
| `secure_boot`, `secure_boot_changed` | `boot.image` | The boot program signed with the firmware signing key; the same with one byte changed |
| `newer_system`, `newer_key` | `boot.image` | The security version one above the repository, signed for Secure Boot; the same with the key number one above |
| `self_test_1` to `self_test_7` | `boot.image` | The flag `SELF_TEST` of the compiler of the boot program |

Each volume has its own object folder, `build/boot/<name>/`, and its own build record, `build/boot/<name>.build_record`. The build key of a volume covers:

- the boot image of the build that its boot image is made from, its kernel, the debug image and the public key of the system, as they are now;
- the sources of the boot program: the list of its compiler, with the same rule of the folders as for a module;
- the commands of the compiler, of the assembler and of the linker with each flag, and what the volume is (its self test, its change, its firmware signature);
- the assembly files, the test keys, the host programs that build and sign, and the tool.

The outputs of the record are the files of the volume that a machine or a test reads: the volume, its boot image, the file that says which key signed it, and for `secure_boot` the variable store. The boot program and its object in the object folder are not in the record, as the object of a module is not: only the build of the volume and the checks of two whole builds read them. A volume is kept by the three conditions of a module. With the signing key of the publisher of the system (`SYSTEM_SIGNING_KEY`), no volume is kept, and the tool never hashes that key.

**The check of the kept volumes.** The tool first computes the key of each volume that the command needs. It then reads and hashes the outputs of all the volumes whose key is the same at once, on 8 threads at most: a volume is 64 MiB, and one volume after the other costs the hash of each one on one thread. The same holds for the records of the volumes that a build wrote. The tool always hashes the whole file. It does not trust the size and the time of a volume file in place of its hash: QEMU opens the boot volume for writes, so a machine can change it, and a file with other bytes, the same size and the same time would be a stale volume that a test boots.

**Which volumes a change builds.** Every volume holds the debug image, which has the debug object of each module of the table. So a change of the code of one module builds each of the volumes that the command needs: the boot image tells apart only three groups (a change of the start policy does not change `boot_fails.image`, a change of the input service does not change `boot_shortage.image`), and the debug image removes that difference. A change of the boot program builds every volume. A change of the text of a link page (a term of the glossary, a section of a guide, or the comment or the one line of a declaration, that a module links) changes the resource `manual_pages`, so it builds every volume too. A change that gives the same module and the same debug object (a host test that a build tag leaves out) builds no volume: the module is built again, its bytes are the same, and so are the boot image and the debug image.

**The volumes are built at the same time.** Each volume that must be built has its own host process of the tool (the command `volume`), as each module has. Two volume host processes write no common file: each writes its object folder, its boot image, its volume and the files beside it, and each of these paths holds the name of the volume. The public key of the system, which every boot program loads, is written one time before the first volume host process starts. The variable store of Secure Boot is written by the host process of the volume `secure_boot` only. The count of host processes at once is the count of `build <host_processes>`, or the count of the processors, at most 8: one volume host process runs one compiler with `-o:speed` on a boot program that holds a boot image of 11 MB, mostly on one thread, and holds the volume of 64 MiB in its memory, so the bound keeps the memory of all the host processes under a few gigabytes on a host with many processors.

**The volumes of a command.** A command builds only the volumes that it boots.

| Command | The boot volumes that its build builds |
|---|---|
| `build`, `test` with no part, `check` | The 19 volumes |
| `test <part>` | The volumes of its part ("The parts of the machine test") |
| `run`, `film`, `fact_waits` | The main volume |
| `measure`, with each argument but `shortage`, and `screenshots` | The volume `measure`: `screenshots` takes the machine test from the check of the flake, and starts only its measure runs on the host |
| `measure shortage` | The volume `shortage` |

The volumes of the parts are in the table of the parts (`test_parts`, `tools/modustool/machine/test_parts.odin`), and those of the other commands in `command_volumes`, with the procedures that start the machines of each row: a host test reads the sources of the tool and fails when such a procedure names a volume that is not in its row, or is in no row.

A volume that a command does not need is not built and not checked. It stays with its record, and the next command that needs it compares the record with the inputs of that time. A machine never starts from such a volume: the tool starts a machine only from a volume that the build of the same host process built or kept, and refuses any other with an error.

**The volume file.** A volume is 64 MiB, and its files fill its start. The tool writes the bytes up to the last byte that is not zero, then gives the file its whole size: the file system stores no block for the end, and a read of it gives zero bytes. QEMU reads the volume as a raw disk and sees the same bytes; the hash of the build record is the hash of the content, with the zero bytes.

**What runs at each build.** The debug image, the pointer themes, the font outlines, the link pages of the manual (`MODULE_CONTRACT.md`, "The links of a page of the manual") and the four boot images are built at each build: each one reads outputs of the modules or files of the repository, and its time is in the measure.

**How to force a whole build.** `modustool build whole` ignores every record, builds each module and each boot volume, and writes new records. The commands that prove the build always build whole, with no option: `check` and `repeat`, and the two procedures of the second build set it themselves, so no caller can compare two builds of which one kept its outputs. `nix flake check` builds in an empty folder, with no record.

**What costs a whole build.** A change of a file of `tools/modustool`, or of a package that the tool imports, changes the identity of the tool, so every module and every boot volume that the command needs is built again: a scenario of a machine test is such a file. A change of the compiler or of a host program of the build does the same. A change of a file of a package builds again each module that compiles the package in, also when the file is a host test that a build tag leaves out. A change of a file of a module that other modules import (an import of the module table, not a package) builds that module and converts the others.

**The measure.** Each `build` prints its measure, lines that start with `modustool: measure: the build`: the whole time, the time of the hash of the input files with their count and their bytes, the time of the modules with the count of the modules built, converted and kept (and in it the time of the compile steps, the time of the conversions, the checks and the writes of the records; the time of a step is the time on the clock from the start of its first host process to the end of its last one, in each level, with several host processes at once), then one line for each later step: the debug image, the pointer themes, the font outlines, the link pages of the manual, the four boot images, the checks and the writes of the build records of the boot volumes, and the boot volumes in all. One line gives the count of the volumes built, kept and not needed by the command, with the count of volume host processes at once; then one line for each built volume gives the whole time of its host process. The last line gives the budget that each module asks for, from the table `Budget` of its file, each module one time, kept modules too: its pages, its processes and its threads (`MODULE_CONTRACT.md`, "The budget that a module asks for"). The host process of a volume prints its own line, `modustool: measure: the build of the boot volume <name>`: the signed boot image, the compiler of the boot program, the assembler with the link and the firmware signature, and the volume file. Each number is a measure: nothing reads one.

One whole build before the incremental build, on a host with 16 processors, read in the times of the files that it wrote: 83 s from the first LLVM IR file to the last module (84 modules, one host process of the compiler for each processor), under 1 s for the debug image, the pointer themes and the three boot images, then 51 s for the 18 boot volumes, one after the other, 2.8 s each.

### The deepest stack of the kernel

Each processor has one kernel stack of 16 pages (65 536 bytes, `op.KERNEL_STACK_PAGES`), between guard pages (`glossary/running_code.md`: kernel stack, deepest chain). The compile step of each kernel module measures the deepest chain of calls on it, after the check of the vector instructions. The design is in `src/md/infrastructure/kernel_stack_depth.md`.

**What the tool reads.**

| What | Where it comes from |
|---|---|
| The frame of each compiled procedure | The section `.stack_sizes` of the linked file: `llc -stack-size-section` writes the address and the bytes of each frame. No segment holds the section, so the module file does not change |
| The frame of each procedure of assembly that compiled code calls | The table `assembly_frames` of `kernel_stack_rules` in `tools/modustool/build/kernel_stack.odin`: the bytes that it pushes, read from its source |
| The calls | The listing of `llvm-objdump -d` of the linked kernel, which the check of the vector instructions reads too: a `call` to the start of a procedure is a call, a jump to the start of another procedure is a tail call |
| The arguments pushed outside a frame, and the indirect tail calls | The scan of the stack pointer (`glossary/running_code.md`) through each compiled procedure of the listing: the count at a call, less the frame, is pushed under the callee; a jump through a register at a count of 0 is a tail call |
| The places where the kernel starts on the stack | The table `entries` of `kernel_stack_rules`: `kernel_interrupt` from a process (the frame of 22 values and a return address above it), `kernel_interrupt` after a return that the processor refused (48 bytes more), `first_run`, `schedule_from_the_top` and `processor_entry` (a null return address) |

**The rules that the listing cannot give.** Each one is a row of a table, with its reason:

- A call through a register, or a jump through a register where no frame stays (an indirect tail call): the table of the indirect calls names its procedure and what it reaches (the self test, which reaches no procedure of the kernel). The kernel has no indirect tail call: each of its jumps through a register is a branch of a table of a `switch`, inside its frame.
- A direct call into data: the table of the calls into data names the caller and the data symbol (the self test calls the array `test_code`).
- A procedure that calls itself: the table of the recursions gives the most levels of it on one chain. `execute` has two: a command with a table of error details runs its operation under two frames of `execute`. `tables_free` of the IOMMU and `walk` of `mappings_report` have one level for each level of their table: `iommu.DOMAIN_TABLE_LEVELS_MOST` and `info.PAGE_TABLE_LEVELS`, 4 each. The overflow of the self test has none: the measure leaves it out.
- A cycle break (`glossary/running_code.md`): a cycle through several procedures that a state of the kernel cuts. The measure takes the depth of the procedure of the row with the other procedure left out. The kernel has three:
  - `lock_order_broken` logs, and the log takes a lock; but it starts the report of a fault first, and from then the log takes no lock. No chain below it runs `lock_take`.
  - `queue_ready` logs only on the report of a thread outside its placement, after the start of the report of a fault; from then the log wakes no reader. No chain below it runs `word_wake`.
  - `process_stop` marks its process Stopped first, and `thread_finish` stops only a process that is not Stopped. No chain below it runs `process_stop` again.
- A compiled procedure that no entry reaches: a row of the table of the procedures that no code calls (the conversions of 16-bit floating point numbers that Odin adds).

The measure stops the build with a line that names the procedure when a chain reaches a procedure with no frame, when a call goes to an address where no procedure starts, when a reached procedure has an indirect call or an indirect tail call or calls itself with no row, when a cycle passes through several procedures with no cycle break, and when a compiled procedure has no row and no entry reaches it. It also stops the build when the scan of the stack pointer of a reached procedure cannot read it: a `ret` or a tail call with bytes on the stack, a `pop` under the entry, another write of `%rsp`, a jump to an address where nothing starts, or a call that no path reaches.

**One interrupt over the kernel.** The kernel takes an interrupt of the machine only in `idle_wait` and in `interrupt_window`, the window after each byte of the drain of the serial port in the idle loop (rules `idle_wait` and `interrupt_windows`). The measure adds, to the deepest chain to either of them, 8 bytes of alignment, the frame of the interrupt, a return address and the deepest chain of `kernel_interrupt`.

**The refusal of a register trial.** It is the one protection fault of the kernel that returns. The measure adds, to the deepest chain from an entry to `model_specific_register_trial_read` or `model_specific_register_trial_write` (the table `register_trials`), 8 bytes of alignment, the frame of the fault, a return address, the frame of `kernel_interrupt` and the deepest chain of `kernel::register_trial_refusal_address` (the row `refusal_callee`; nothing when it is inline). The frame of `kernel_interrupt` alone is the bound: the refusal returns before any other path of it. The chain of the first processor runs on the stack of the boot program and is not measured; the start of another processor and the self test are.

**The check.** Each stack keeps a quarter of its bytes free (`STACK_LEAST_FREE_PART`). The build fails when less than 4 pages (16 384 bytes) of the kernel stack stay free after the deepest chain, the entries, the interrupt at the idle wait and the refusal of a register trial together. The measure counts each push and each tail call of the listing, so the margin is for a chain of the graph that no input runs and for a change of the code between two builds.

**The interrupt stacks.** The gates of four vectors name an interrupt stack: the double fault (4 pages), the debug exception, the non-maskable interrupt and the machine check (2 pages each). Each other vector, the timer and the devices too, runs on the kernel stack. On the stacks of the double fault, of the non-maskable interrupt and of the machine check, `kernel_interrupt` runs the report of a stop only: the start of the report, its line, the reason of a fault of the kernel, the stop. The table `report_callees` names these callees. A name that `kernel_interrupt` does not call stops the build. Under the report the log takes no lock and wakes no reader, so the measure leaves out `lock_take` and `word_wake` there. The measure adds one fault inside the report, which the processor pushes on the same stack, and which `fault_report_begin` ends with one line. On the stack of the debug exception only the stub runs: its frame. Each interrupt stack keeps a quarter of its bytes free too, or the build fails with the chain.

**The measure lines.** The step writes four lines in `build/modules/<name>/kernel_stack.measure`, and each build prints them, a kept kernel too, for `kernel`, for `kernel_without_return_check` and for the counted kernel `kernel_edge_counters`. In a chain, "(... bytes pushed for the call)" after a procedure gives the arguments that it pushed outside its frame for the call of the next procedure:

```
modustool: measure: the kernel stack of kernel: the deepest chain uses ... of 65536 bytes, ... bytes free, and the build fails under 16384 bytes free: an interrupt at the idle wait over kernel_interrupt -> ... -> idle_wait (... bytes), then kernel_interrupt -> ... -> kernel::execute (2 levels) -> ...
modustool: measure: the kernel stack of kernel: each entry: an entry from a process ... bytes, ...; an interrupt at the idle wait ... bytes; a fault of the kernel over the deepest chain ... bytes (not checked)
modustool: measure: the kernel stack of kernel: the refusal of a register trial uses ... of 65536 bytes, ... bytes free, and the build fails under 16384 bytes free: the refusal of a register trial over kernel::processor_entry -> ... -> model_specific_register_trial_... (... bytes), then kernel_interrupt ...
modustool: measure: the interrupt stacks of kernel: the double fault ... of 16384 bytes, ... free, the build fails under 4096; the non-maskable interrupt ... of 8192 bytes, ...; the debug exception 176 of 8192 bytes, ... (the stub only); the report: kernel_interrupt -> kernel::log -> ..., then a fault inside it: kernel_interrupt -> kernel::fault_report_begin -> ...
```

The first line names the deepest chain, procedure by procedure. A fault of the kernel stops the machine, so its bound on the kernel stack is printed and not checked: if its report passes the guard page, the processor reports a double fault on its own stack, and the fourth line checks that stack. The third line is the chain of a refused register trial, which the margin checks as the others.

### The hashes of the modules of two builds

The hash of a module file is its identity. A change that must not change the system is proved by it: a move of the sources, a new name of a folder, a change of the tool. Each module of the build after the change has the hash of the build before.

```
nix develop -c modustool build
nix develop -c modustool module-hashes write /tmp/module_hashes_before
(the change)
nix develop -c modustool build
nix develop -c modustool module-hashes compare /tmp/module_hashes_before
```

- `module-hashes write <file>` writes the record: the line `module hashes, form 1`, then one line for each module of the table of the modules, the BLAKE3 hash of `build/modules/<name>.module` in 64 hexadecimal digits, a space and the name.
- `module-hashes compare <file>` hashes the same files again and compares them with the record, by the name of the module. It prints one line for each module whose hash differs, with the two hashes, and one line for each module that only the record or only the build has. Its last line gives the count of the modules with the same hash. It fails when one module differs or is in one of the two only.

The command builds nothing: it reads the build that is there, and stops when a module of the table has no file. The record is a file of the developer, outside the repository.

A build key holds the path of each source, so a move of a folder builds each module again; the comparison then says whether the compiler gave the same bytes. A debug object holds the path of each source, so it changes with a move; the command does not read it.

### How the tool sends input and waits

The machine test acts as the keyboard and the mouse of the machine. Each key and each move goes to the virtual keyboard and the virtual mouse of QEMU, so the input service of the system reads them from the keyboard controller as it reads real devices. The tool has no other way in: no export of the system takes a key or a move.

The tool talks to QEMU on its machine protocol (QMP), on a Unix socket beside the log of the machine (`build/test_output*.qmp`). A second socket of the same protocol is for the worker of a film only ("The film"). A command is one line of JSON, and QEMU answers each command with one line: the tool knows when QEMU did it (`tools/modustool/machine/qmp.odin`, `qmp_socket_linux.odin`, `machine_input.odin`). The monitor of QEMU for a reader stays on the standard input: the tool ends QEMU through it.

**No wait is a fixed time.** After an input, the tool waits for a condition, with the bound of a hang ("The bounds of the tests"):

- **Keys.** The keys of a typed line, with its Enter, are one list. One command of QMP (`input-send-event`) presses and releases several keys with no time between two events. The queue of the virtual keyboard holds 16 bytes, and QEMU drops, with no error, a byte that finds it full; a key is 3 bytes, a key with a prefix (an arrow, Page Up) 5, a key with Shift 6. So the tool cuts the list into commands of 16 bytes at most, and sends the next command when the keyboard controller says that it holds no byte: the system read the bytes before. The tool reads the status of the controller through QEMU, and the read changes nothing in the machine.
- **The condition after the keys.** When the process `remote` runs, the tool reads the count of key records of `compositor.pointer()` before the list, and goes on when the count grew by one record for each press and each release: one call for each read of the count, not several for each key. A count that stops short is a failure, and the message has the count. The same read gives `keys_refused`, the key records that the compositor lost because a window did not read: a number above 0 is a failure. Before `remote` runs, and when the scenario revoked its grant, the condition is that the system read each byte of the keyboard. The input service takes a byte of the keyboard from the controller only when the input ring has room for its record (`ARCHITECTURE.md`, "The path of a key"), so "the controller holds no byte" also says that the input ring took each key record.
- **The dependency on QEMU.** "The controller holds no byte" is bit 0 of the status port at 0. QEMU sets that bit again inside the read of the data port while the queue of the device holds a byte, so the bit at 0 means that the queue is empty. This holds while the property `kbd-throttle` of the i8042 device is false, which is its default; with `kbd-throttle` true the bit stays 0 for 1 ms after each byte, and the condition is false. The tool does not set that property.
- **The echo of a line of the console.** The two conditions above stop at the compositor or at the input ring. A key then goes through the ring of the window and the terminal ring. The console writes each line that it enters on the log, as `[console] > text`, before it runs it. So after the keys of a step `Type` that goes to the console, the tool waits for that line of the log: each key of the line and its Enter reached the console, in order. A line with no echo fails at the step that typed it. The message names the line, gives the counts `keys`, `keys_waiting` and `keys_refused` of the compositor when the tool can call it, and quotes each line of the log that says that a queue refused a record or that the input ring was full. The tool waits for the echo only when it knows that the console takes the line now (`tools/modustool/machine/console_echo.odin`):
  - The console is in front: the last step that changed the front window was the step `Front` of the console, or a step `Click_Element` or `Wheel` in the console. A step `Wheel` in another window makes that window the front one, and so does a step `Resize`, which drags the bottom left corner of a window and waits for the line of the compositor with its new size. A step `Click_Absolute` or `Press_Absolute` makes the window that it presses the front one. A step `Launch`, `Move`, `Close`, `Click` or `Drag`, a step `Click_Element` in another window or in the palette, the key of the palette, and a typed line that has `start(` make the front window unknown. The tool then waits for no echo, as for a line typed into the window of another process.
  - No line can still run: a step `Wait` passed since the step `Type` before. The console enters a line only when the line before it ended. A line typed with no `Wait` since the line before it is owed: the tool waits for its echo, in order, at the next step `Type` of the console that has a `Wait` before it.
  - A step `Keys` and a step `Key` have no echo: they enter no line.
- **The pointer.** A move is a list of relative moves of 40 pixels at most, one packet of the virtual mouse for each, with the same rule of 16 bytes. A packet has 4 bytes: the input service asks the mouse for the IntelliMouse protocol, whose fourth byte is the wheel. A wheel notch is one command of its own (a button `wheel-down` or `wheel-up` that goes down and up), and one packet. With `remote`, the tool then reads `compositor.pointer()` until the pointer is at the place, or until the compositor received each packet: a pointer that is elsewhere moves again from the place that the compositor gives (a confirmed place, `glossary/network.md`). A press and a release wait until the compositor has the button in that state. Without `remote`, each waits until the system read its packet, and the place that the tool believes is the sum of its moves. That sum can be wrong: the input service joins the moves that find its ring full into one move, and the edge of the screen cuts a joined move where it would not cut each move alone. So the compositor writes the place of each press of the left button ("compositor: a press of the left button at 112,12"), and a press of the tool waits for that line: a press at another place is released, the tool takes the place that the compositor wrote, and moves again, at most 6 times (`POINTER_TRIES`). The line of the log that the step already waits for (the menu is open, the window is in front, the window moved) then shows the effect. The menu of the windows lists a window from its first picture, so a step `Front` first waits for "compositor: window <title> is shown", which comes after the line of its surface.
- **The log.** A wait for a line of the log ends when QEMU wrote in the file: the kernel of the host tells the tool (inotify, `log_watch_linux.odin`). A poll with a short period of the whole file would cost a read of the file at each turn. The poll of 50 ms stays under the watch, for the time before QEMU made the file.
- **A picture.** The tool takes a picture when the screen is settled ("When the tool takes a picture"). A step `Shot` after typed keys comes after a step `Wait` for a line that says that the process took the keys: "compositor: the field 1 of revoke shows \"log\"", "console: the history search \"leng\" chooses the row 2 of <count>", "rings: the key a adds a record: <count> records in all". Two equal pictures before the process drew the keys also settle the condition by pictures. The command `screendump` of QMP answers when the file of the picture is whole. A worker thread of the tool then makes the PNG file while the scenario goes on; the tool waits for each worker before the test of the machine ends, and a picture that is not written fails the test.
- **The QUIC cases of the peer.** A step `Peer_Quic` ends when its case ends. Its message quotes the last counts of `quic_echo` that the log has; the process writes them at most once in one second, so they can be older than the case. A count that a scenario needs has a step `Wait` of its own. No time passes between two cases, so a case does not depend on what the cases before it left of a budget of the server: `quic_echo` checks 4 Initial packets of one address at once, then one in each second, and drops the others with no answer. A client of the peer whose handshake ends at its deadline starts a new connection, as a client process does, and the result of the case gives the count of these.
- **A property that a process has only after a time.** A scenario waits for the line that says so before it reads the property. The process `server` sends the field `Date` only when the date is known, and the process `date` knows it up to one second after its start: the scenario waits for "date: ok, " before the first fetch.

**The numbers of time that stay in the step runner:**

| Constant | Value | Role |
|---|---|---|
| `HANG_BOUND`, `BOOT_HANG_BOUND`, `PROGRESS_CASE_HANG_BOUND_SECONDS` | 120 s, 180 s, 660 s | The bound of a hang |
| `CONDITION_POLL_PERIOD` | 1 ms | The period between two reads of a condition through QEMU or through `remote` |
| `LOG_POLL_PERIOD` | 50 ms | The period of the poll of the log when no change of the file woke the wait |
| The poll of the step `Power_Loss` | 1 ms | The period between two reads of the state of the disk that the tool serves |
| `FILM_RATE` | 30 pictures in one second | The rate of a film (`modustool film`): a rate, not a wait |

A film has two more kinds of time, and only a film has them: the period between two typed keys and the hold of a state for its viewer ("The film"). No scenario of a test has such a step, and a host test checks that.

### How a step presses an element

A step `Click_Element` presses an element of a window by its element name (`glossary/desktop.md`, "Element name"), not at a place that the scenario computes. The window writes where the element is, so a change of the layout moves the press with the element. The design is `src/md/infrastructure/test_pointer.md`.

- **The element line.** A window that draws with the interface package writes one log fact when the rectangle of a named element changes, `interface.Element_Placed`, and one when the element is gone, `interface.Element_Gone`. Their sentences are `interface: debugger_window: the element watch at <x>,<y>,<width>,<height>` and `interface: debugger_window: the element breakpoint 0 is gone`. The fields are `window`, `element`, `x`, `y`, `width` and `height`, in pixels of the surface of the window. A frame with no change writes no fact.
- **The names.** A button is named by its label, a text input by its placeholder, an arrow button of a named scroll bar by the name of the bar and "arrow up", "arrow down", "arrow left" or "arrow right", and the view of a named scroll bar by the name of the bar and "view". A process names its other elements with `interface.element_name`: a row of the debugger is "source row 0", "frame 0", "thread 0" or "breakpoint 0"; a row of the list of `inspect` is the name of its process; a color of `paint` is its name. The first element of a frame with a name keeps it.
- **The palette.** The palette is a panel of the compositor, not a window. The compositor writes the element lines of the panel, in pixels of the screen: the facts `compositor.Palette_Element_Placed`, `compositor: the palette: the element round_robin at <x>,<y>,<width>,<height>`, and `compositor.Palette_Element_Gone`, with no field `window`. Each field of a form that the band shows is "field 0", "field 1", ...; each button of a field is the name of its candidate; the arrow buttons of the scroll bar of the list are "scroll bar arrow up" and "scroll bar arrow down". When the panel closes, each element is gone. The step names the palette with the text `the palette` (`PALETTE_ELEMENTS`).
- **The step.** The tool reads the last element line of the element from the fields of its fact, never from its sentence: the fields `window` and `element` are equal to the window and the element of the step, and a line of the palette comes from the process `compositor`. When the log has no line of it, or the last line says that it is gone, the tool waits for a new line, with the hang bound. It then presses the middle of the rectangle: for a window, from the place of the window that the compositor gives.
- **The window in front.** Before the press, the tool brings the window to the front when another window covers the middle of the element. With `remote`, `compositor.windows()` gives the place and the order of each window. Without `remote`, the log gives no order, and the tool brings the window to the front each time. A step `Close` does the same for the close button of its window.
- **The wheel.** A step `Wheel` turns the wheel by `notches` (`NOTCH_TOWARD_THE_END` for each notch toward the end of a content, its negative toward the start) over the middle of an element. The compositor gives the notches only to the window in front, so the tool brings the window to the front first when `compositor.windows()` does not say that it is in front. The element is often the view of a named scroll bar, "<name> view": "scroll bar view" of the console and of the palette. The next step waits for the line of the view that moved: `terminal: the wheel moves the view of console: the view follows the last lines`, `compositor: the wheel moves the rows of the palette: the rows from 4`, `interface_elements: the list chooses compositor`.
- **The line describes the last drawn frame.** A process can write the line of an act before it draws the frame that moves an element. A scenario that presses an element that the act before just moved waits first for the new element line of the element (the step `Wait`).
- **What still takes a place.** A step `Drag` and a step `Point` give a place in pixels: a drag goes to a point of a track, and a step `Point` reads the shape of the pointer at a point. The window `pointers` builds its frames with no window layer and writes no element line: its button stays a step `Click` at a place.

### How a step reads a text off the screen

A step `Screen_Text` reads the text of a named element of a window from a picture of the screen. It is for a value that the machine shows and writes nowhere else: the recovery key of a machine key sealed by the TPM, which the log must never hold (`PRINCIPALS.md`, "The machine key sealed by the TPM").

- **The place.** The tool reads the element line of the element, as a step `Click_Element` does, and the place of the window. It then takes a picture of a settled screen.
- **The font.** The text must be drawn in Spleen 8x16, the bitmap font of the cells: the scenario sets the setting `font` to `spleen` before (`settings.set(font = .spleen)`). The vector font blends its glyphs, and a read of it would be a guess.
- **The read.** The places of the window and of the element are logical pixels; the picture is pixels of the screen at the scale of the machine, 1.25. The tool turns each place into a pixel of the screen by the rule of the drawing module (`screen_place_of_logical`). A cell of the body is 10 by 20 pixels of the screen at 1.25, and Spleen draws its glyph of 8 by 16 in its middle (`spleen_cells_of`): each glyph is compared, pixel by pixel, with each glyph of the font, one cell after the other. A pixel that is not the color of the pixel just left of the first glyph is ink. A cell that matches no glyph fails the read: the tool never guesses a character. `cells_text` is the read; a host test draws a text into a picture and reads it back.
- **The read is the condition.** The element line comes from the layout of a frame, before its picture reaches the screen. With no `remote`, a settled screen means only that two pictures in a row were the same, so it can show the window before the change. The tool therefore takes settled pictures until the cells of the element read as a text of the font with no blank cell at its start or at its end: the box of the element is as wide as its text. A read that never holds fails the step at the hang bound.
- **The use.** A later step of the same test part, in the same machine or in a later one, names the text with `{screen text}` in its text: the step `Type` of the recovery key in `test principals`. `{screen text before}` names the text of the read before the last one: a recovery key that a new one replaced, which a step types to show that it opens nothing new. A step that names a text before the read that gives it fails. A step `Screen_Text` with `shown_only` reads its text under the same condition, and keeps nothing: it proves that a window shows the text, and the two texts kept before stay for the later steps.

### When the tool takes a picture

A picture shows a window that its process drew after the line of the log that the step before waited for. The picture is right when the screen is settled: the screen shows the last picture of each window. That is two facts, and each one alone is not enough:

1. each process sent the picture of its last change;
2. the compositor drew each picture that it received.

A picture that is taken too early is wrong, and no test fails. So the tool reads the two facts, and takes the picture when they hold. The code is `tools/modustool/machine/screen_settle.odin`.

**The condition by calls.** When the tool can call the compositor through `remote`, it makes three reads in this order: `monitor.processes()`, then `compositor.windows()` and `compositor.screen()`, then `monitor.processes()` again. The screen is settled when, for each window:

- its process is in the state `waiting` in the two reads of the processes, with the same count of kernel entries;
- the window has at least one picture of its process (`presents`), no picture that waits for a frame (`waits`), and no change that waits for its next picture (`due`);

and when no change of the desktop itself waits for a frame (`desktop` of `compositor.screen()`: the pointer, the bar, a menu, the palette, a window that appeared, moved or closed).

Why this is the two facts. A process that waits, then runs, then waits again enters the kernel to wait. So a process that waits in the two reads with the same count of kernel entries did not run between them: each picture that it sent, it sent before the first read. The compositor reads the ring of each window before it answers a call, so it counted each of these pictures. With no picture and no change of the desktop that waits for a frame, the screen shows them. The window of a process that writes in a terminal has the title of that process, and the terminal draws it: so the condition holds for each process `terminal` too, which is in a wait in the two reads with the same count of kernel entries.

**A picture that is due.** A process that paces its pictures, such as a terminal (at most one picture in each `FRAME_TIME`), can wait on its clock with a change that it did not draw. That wait looks the same as a wait with nothing to draw: the same state and the same count of kernel entries. So the process says it. Before it waits with such a change, it sends `Picture_Due` with 1 on the ring of its window (`display.picture_due_set`). Its next `Present` ends it, and a frame that changed nothing sends `Picture_Due` with 0. `compositor.windows()` gives it in the field `due`, and the condition does not hold while a window has `due` 1. The process states the fact itself, so the condition needs no time and no copy of the pace of a process. A picture of the console that the condition took before this fact existed showed the head of a table and not its row.

The terminal states it at the start of each turn of its loop, before each wait, from one read of the count of the records that it took (`terminal_records.picture_wait_choose`). A record that comes while the terminal draws a picture is such a change too: the `Present` of that picture ends the due state, so the next wait must state it again. A picture of the console that the condition took when the terminal stated it only before it drew showed the state of a running call and not its result. The design: `src/md/features/terminal_due_picture.md`.

**What the condition by calls leaves out.**

- A window that draws with no end has no last picture: `life`, `plasma`, `threads`, `workers`, `rings`, `processors`, `limits`, `flood` (`processes_that_draw_without_end`). Its part of the picture is the frame that is there. No check compares the pixels of such a window. A process that draws with no end and is not in the list never settles: the picture fails at the hang bound, and the message names its window.
- The windows of `remote` and `monitor`: these two processes run because of the reads themselves, and their windows count the calls.
- A window whose process stopped: it gets no picture more.

**What the condition by calls does not say.** It reads the process of the window, not the processes that work for it. A process that waits for the answer of a service is in a wait: if it draws when the answer comes, the picture can be before that. The step before a picture must wait for the line of the log that the process writes after the answer. The condition closes the time between that line and the picture of the process, which no line of the log marks.

**The condition by pictures.** Before `remote` runs, when the scenario revoked its grant, on a machine with no `remote`, and when a read of the condition by calls fails, the tool takes pictures of the screen one after the other until two in a row are the same. It leaves out the rectangle of each window that draws with no end; the place and the size of the window come from the lines of the compositor in the log. This condition is weaker: it says that the screen did not change during the time of one `screendump` (about 100 ms on the host of the measures above). A process that computes for longer than that before it draws gives two equal pictures of the screen before its change. A scenario that needs more starts `remote` before the picture.

The hang bound ends a wait for a screen that never settles. The test fails, and the message gives the reason of the last read: the window whose process still ran or whose picture waited, or the place of the first pixel that differed.

### The film

`modustool film <name>` builds the main boot volume, starts a test machine, runs the scenario of the film, and writes two files from the same pictures: `build/films/<name>.mp4` and `build/films/<name>.webm`. It copies the MP4 file and three of its pictures, as PNG files, to a new folder of the development log (`<date>_film_<name>`). It copies the WebM file to `docs/films/<name>.webm` when a news entry names the film ("The film of a document"). A film is not a test: no check runs it. The code is `tools/modustool/machine/film.odin`.

| Film | What it shows | Scenario |
|---|---|---|
| `terminal` (also with no argument) | The process `flood` writes lines in the terminal; the keys move in the lines, stop them and start them again | `scenario_film` (`machine.odin`) |
| `palette` | The palette: a process, a window, a command and its record, the form of a command with its candidates, a question before an entry that destroys, a setting that changes the font of the desktop | `scenario_palette_film` (`palette_film_scenario.odin`) |
| `heron` | The process `heron`: the heron plays in its own order; the dash at full speed, then four times slower; the lines of the cells with the hop, the stretch and the flap; the dash frame by frame, with the changed cells outlined; one held frame in the free way and on the grid; the three cell sizes | `scenario_heron_film` (`heron_film_scenario.odin`) |
| `boot` | The check of the boot program, then the boot display held at the stage of the boot program, then drawn again by the root service at each stage, the desktop, then the window of the boot display with the records of the kernel | `scenario_boot_film` (`boot_film_scenario.odin`) |
| `desktop` | The bar and the console; the start menu; two processes started from it; a window moved, a window resized by its corner; the menu of the windows; a window closed; the palette that starts a module and brings a window to the front | `scenario_desktop_film` (`desktop_film_scenario.odin`) |
| `console` | An expression and its value; a variable and a command; an argument of the wrong kind and its error; the completion list; a record; a table; the history search | `scenario_console_film` (`console_film_scenario.odin`) |
| `program` | `start("plasma")` in the console: the module opens its window; the window moved; its row in the table of the processes; `stop("plasma")` | `scenario_program_film` (`program_film_scenario.odin`) |
| `monitor` | monitor at the right of the screen, its graphs on a quiet machine; scheduler, whose tests run spinners, as a load, then closed: the curves and the gauges rise, then come down | `scenario_monitor_film` (`monitor_film_scenario.odin`) |

The films differ by their scenario only. The worker, the list of the encoder and the encoders are the same code.

The films `boot`, `desktop`, `console` and `program` are the chapters of the tutorial of the system, which a separate project edits from their MP4 files and their cue files. The tutorial shows the code of `plasma` before the film `program`: it is the smallest module that draws a window.

**The display.** A test machine has no display (`-display none`): the firmware and the boot program write their console to the serial port, and QEMU draws nothing before the first picture of the system. The machine of a film has a display with no window instead (`-display vnc=unix:build/test_output*.vnc.sock`), so QEMU draws that console, and the film of the start shows the check of the boot program before the boot display. A window never opens: a film runs headless, as a test.

**The machine waits for the scenario.** The machine of a film starts paused (`-S`), and its scenario resumes it with the step `Monitor "cont"`. The tool is then ready before the first line of the start, and it freezes the machine on a line that a viewer must read. A test machine starts at once.

**A key with no line.** The process `heron` writes no line for the dot, for Space, for the keys `s` and `z`, and for an animation of its own order. The film of `heron` sends such a key, holds, and then waits for the next line that the process writes: the line of the key `g` or `l` names the animation, its frame and "held", so it proves the dots and the pause before it. No line names the cell size or the slow play: the film shows them, and no step proves them.

**The worker.** Between the steps `Film_Start` and `Film_Stop`, a thread of the tool asks QEMU for a picture of the screen 30 times in one second (`FILM_RATE`), while the scenario runs its steps. The worker has its own connection to QEMU: each test machine has a second socket of the machine protocol (`build/test_output*.film.qmp`), and a machine with no film leaves it with no connection. The keys of the scenario go on the first socket. So a batch of keys and a picture never share a reply, and the tool needs no lock. QEMU does one command at a time: a batch of keys waits at most for one picture, and a picture at most for one batch.

**The name of a picture is its time.** A picture is `build/films/<name>/<microseconds>.ppm`: the time since the start of the film when the worker asked for it, in ten digits, rounded up. The reply of QEMU comes when the file is whole, and the worker asks for the next picture at the start of the next slot of 1/30 s. When a picture took longer than one slot, the slots that passed get no picture.

**The list of the encoder.** After the machine, the tool reads the times in the names and gives the encoder one list (`pictures.ffconcat`): each picture with the time that it stays on the screen. A slot shows the newest picture that was asked for before its end. A slot with no picture of its own shows the picture before, and the pictures after it keep their own slots: a picture that came late shifts nothing, and the film has the speed of the machine, also on a loaded host. The time of a run of slots is the difference of its two ends in microseconds, so no rounding adds from run to run.

**The encoders.** `ffmpeg`, from the development shell, runs twice on the same list. The two commands differ by the arguments of their encoder (`FILM_MP4_ENCODER`, `FILM_WEBM_ENCODER`) and by their output only:

```
ffmpeg -f concat -safe 0 -i build/films/<name>/pictures.ffconcat
  -vf fps=30,scale=iw*2:ih*2:flags=neighbor:out_color_matrix=bt709:out_range=tv
  -c:v libx264 -preset slow -crf 18 -movflags +faststart -pix_fmt yuv420p
  -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv
  build/films/<name>.mp4

ffmpeg -f concat -safe 0 -i build/films/<name>/pictures.ffconcat
  -vf fps=30,scale=iw*2:ih*2:flags=neighbor:out_color_matrix=bt709:out_range=tv
  -c:v libsvtav1 -preset 6 -crf 45 -an -pix_fmt yuv420p
  -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv
  build/films/<name>.webm
```

| File | Format | For |
|---|---|---|
| `build/films/<name>.mp4` | H.264 in MP4, the index at the start of the file | The development log, and a post on another site: each site that takes a film plays H.264. The repository does not hold it |
| `build/films/<name>.webm` | AV1 in WebM, no sound | The repository and the site ("The film of a document") |

Measured on the film of the palette (36.8 s): the MP4 file has 3 169 392 bytes and the WebM file 1 572 784 bytes, about half, with the text of the screen sharp.

Each file is at a constant 30 pictures in one second. Each pixel of the screen is a square of 2 by 2 pixels of the film, with no filter: the reference screen of 1920 by 1080 is a film of 3840 by 2160. The color planes of the pixel format `yuv420p` have half the size of the picture, so with this scale each pixel of the screen keeps its own color, and the squares of the design stay sharp. The colors are converted and named as those of a film in high definition, so that a player shows the colors of the screen. The tool makes no GIF and no WebP file: at this size and length, with a window that draws at each frame, such a file is many times larger than the MP4 file.

### The film cues

A film cue (`glossary/project.md`, "Film cue") is a named moment of a film: the time when its scene reached a state. A step `Film_Hold` with a text starts the cue of that name; a hold with no text starts none. The tool keeps the time since the start of the film when the hold starts, after the wait of the scene, and writes the cue file `build/films/<name>.cues` at the step `Film_Stop`.

```
0.000 desktop.start
3.412 desktop.start_menu
```

- One line for each cue, in the order of the film: the time in seconds with three digits for the milliseconds, one space, the name. A part of a millisecond is cut, so a cue never comes before its state.
- A name has 1 to 48 bytes (`FILM_CUE_NAME_LIMIT`) of the lowercase letters, the digits, `_` and `.`, and starts with a letter. A name comes one time in a film. The tool refuses another name, or a name that comes again, and the film fails at that step. A host test checks the names of each film of the tool.
- A film with no cue writes an empty cue file, so the file of an earlier run never stays beside a new film.
- Why: a film has the speed of the machine, so a time that an editor guesses drifts from the film on another host. An editor places a caption at the time of its cue. The time of a cue is the time of the film: the first picture of a film is at its start.

The code is `film_cue_note`, `film_cue_text` and `film_cue_name_problem` in `tools/modustool/machine/film.odin`. The design: `src/md/infrastructure/film_cues.md`.

### The film of a document

A news entry can name a film: `film: docs/films/<name>.webm` in its head (`news/README.md`, "The film"). The repository holds that file, as it holds the screen pictures, so `modustool site` copies it and needs no encoder.

- `modustool film <name>` writes `docs/films/<name>.webm` after its two files, when a news entry names the film with that name (`film_is_named_by_a_news_entry`). A film that no entry names stays in the build folder. So the line `film:` is written first, then the command runs.
- The file is the WebM file of the build folder, byte for byte.
- Before the copy, the command makes the checks of `modustool news check` on the file (`film_document_problem`): a WebM file (an EBML header of the document type `webm`), at most 4 MiB (`FILM_DOCUMENT_SIZE_LIMIT`), whose tracks state the width and the height of its pictures. A file that fails is not copied: the repository keeps the film that it has, and the command fails.
- The bound of 4 MiB: each version of the file stays in the history of the repository, and a reader of the site loads it on a phone. The film of the palette, 36.8 s of the whole screen, has 1.5 MiB.
- A film is not the same bytes at each run: the pictures are taken at the times of the host. Run the command to change the film, and commit the new file only then.

The tool reads the width and the height of the pictures from the file itself (`film_document_picture_size`: the element `Tracks` of the segment, the first track with `PixelWidth` and `PixelHeight`). The site states them on the `video` element (`SITE.md`, "The film of a news entry"). The code is `tools/modustool/machine/film_document.odin`, which writes the film, and `tools/modustool/checks/film_document_check.odin`, which reads it for the check of the news.

**A film shows time; a test waits for conditions.** A scenario of a test has no fixed time ("How the tool sends input and waits"). A film is for a viewer, who must see a text being typed and must have the time to read a state. So a film has two kinds of step with a fixed time, and they exist only in the scenario of a film:

| Step | The fixed time | Why |
|---|---|---|
| `Film_Type` | 70 ms between two keys (`FILM_KEY_PERIOD_MILLISECONDS`), more or less at most 25 ms (`FILM_KEY_VARIATION_MILLISECONDS`) | A test types a line in a few milliseconds: no viewer sees the list narrow. A generator with a fixed seed draws each period, so the typing does not look mechanical, and two runs type at the same times |
| `Film_Hold` | `FILM_HOLD_BEAT` 400 ms, `FILM_HOLD_GLANCE` 700 ms, `FILM_HOLD_LOOK` 1200 ms, `FILM_HOLD_READ` 2000 ms | The time that a viewer needs: between two acts, for a list that changed, for a new state of the desktop, for a result or a question to read |

These times never stand for a condition. After each key of `Film_Type` the tool waits, as in a test, until the system read the key. Each scene waits for its line of the log (a step `Wait`) before its hold: the film never shows a state that the machine did not reach, and a film on a slow host is longer, not wrong. The film of the palette uses the keys and the lines of the main scenario of the machine test: it shows what the test checks. It runs without `remote`: the condition after a key is that the system read each byte of the keyboard.

**The measures.** At `Film_Stop` the tool prints, as measures: the count of the pictures and the rate that they reached, the slots with no picture of their own, the longest time between two pictures, and the time of one picture of QEMU (in the middle, and at most). No number of these makes a film fail. Measured on one host with a bare QEMU: two sockets of the machine protocol at once, and 1.7 ms for one picture of 0.86 MB; a picture of the screen of the system is 2.3 MB. The pictures of one film of 37 s are about 2.5 GB in `build/films/<name>/`; the tool removes them after the encoder.

### The pictures of the mark

One generator makes each file of the mark (`tools/modustool/resources/mark_pictures.odin`, `mark_formats.odin`, `mark_tile_map.odin`, `mark_developer_picture.odin`). The data of the mark is in `src/library/modus/mark`; the generator turns a request into the bytes of a file. Three commands ask it:

| Command | What it asks |
|---|---|
| `logo` | Each row of the repository of the table of the uses of the mark, then the font of the name and the picture for a developer |
| `site` | Each row of the site of the table of the uses: the pictures, the tile maps, the icons, the icon file and the vector icon |
| `mark` | One request, from the words of the command |

The table of the uses is in `DESIGN.md`, "The variants of the mark". It is the one table of the files of the mark. `logo` and `site` hold no number of a picture: a new file of the mark is a new row of that table.

A request says what to draw and how:

| Part | Values | Meaning |
|---|---|---|
| What | `still`, `frame`, `animation`, `tile_map`, `table` | The still mark; one frame of an animation; every frame of one animation, as one animated file; a tile map; the table of a tile map, as JSON |
| `--format` | `png`, `ico`, `svg`, `apng`, `json` | The format of the file: see "The formats" below. With no format: `png` for a picture and a tile map, `apng` for an animation, `json` for a table |
| `--entry` | `<variant>:<cell>:<pixels>` | One more entry of an icon file: its variant, its cell size and the side of its square picture. It takes the color scheme and the background of the request. The option can come several times |
| `--dark-rule` | `yes`, `no` | A vector file with the rule that gives the colors of the dark scheme to a reader that asks for dark. The default is `no` |
| `--variant` | `smooth`, `cells` | The variant of the mark. The default is `smooth` |
| `--cell` | A whole count of pixels | The side of a cell of the heron. The default is 8 |
| `--scheme` | `dark`, `light` | The colors. The default is `dark` |
| `--background` | `none`, `scheme` | On nothing, or on the background of the color scheme. The default is `none` |
| `--size` | `<pixels>` or `<width>x<height>` | The drawing is centred in a picture of that size. With no size the picture has the size of its drawing |
| `--name-cell`, `--gap` | Whole counts of pixels | The name under the heron, at that cell size, that many pixels under it |
| `--animation` | A name of `DESIGN.md`, "The animations" | The animation of a frame. For a tile map: that animation only; with no name, every animation |
| `--frame` | A number from 0 | The frame of the animation; 0 is the still heron |
| `--forms` | `yes`, `no` | A tile map with the drawn forms of the moves, or with the frames only. The default is `yes` |
| `--width` | A whole count of pixels | The widest tile map. With no width, a row holds 16 sprites |
| `--out` | A path | The file. The default is `build/mark_<what>` with the end of its format: `.png`, `.ico`, `.svg`, `.apng` or `.json` |

Two more words take no option: `mark uses` prints the table of the uses, and `mark developer` writes `build/mark_animations.png`, every frame and every drawn form with its texts.

Examples:

```
modustool mark still --variant cells --cell 1 --scheme light
modustool mark frame --animation dash --frame 2 --cell 16
modustool mark tile_map --animation hop --width 1024
modustool mark table --forms no --variant cells --cell 1
modustool mark still --format ico --variant cells --cell 1 --size 32 --scheme light --entry smooth:2:48
modustool mark still --format svg --variant cells --cell 1 --scheme light --dark-rule yes
modustool mark animation --animation dash --format apng
```

The fifth example writes the bytes of `favicon.ico` of the site, and the sixth the bytes of its `icon.svg`.

**The formats.** Each format starts from the pixels of one picture, which one procedure of the generator draws. No format computes a color of the heron a second time.

| Format | What the file is | For |
|---|---|---|
| `png` | The pixels of one picture, or of a tile map | `still`, `frame`, `tile_map` |
| `ico` | An icon file: a directory, then one PNG file of the generator for each entry. The first entry is the picture of the request, and each `--entry` adds one. A reader chooses an entry by its size | `still`, `frame` |
| `svg` | A vector file: the pixels of the picture as rectangles of one color. A run of cells of one color in a row is one rectangle, at each cell size. With `--dark-rule yes`, a rule of style gives each rectangle its color of the dark scheme for a reader that asks for dark | `still`, `frame`, in the cells variant |
| `apng` | An animated PNG file: each frame of one animation as one picture, in its place, for the time that `src/library/modus/mark` gives it. The file plays with no end. A reader that does not know the animated form shows the first frame | `animation` |
| `json` | The text of the table of a tile map | `table` |

- The smooth variant is not written as a vector file. The gradient of a part is linear across the picture, and a vector file can state a linear gradient. But the reader of the file then computes each color: it goes between the two rounded colors of the ends, and it rounds in its own way. Some pixels are then one unit away from the colors of `src/library/modus/mark`, on some readers. In the cells variant the tool computes the one color of each cell, and a rectangle of one color is the same in every reader.
- An animated PNG file is a PNG file with three more kinds of chunk: `acTL` holds the count of the frames, `fcTL` the size and the time of one frame, and `fdAT` the data of a frame after the first. The data of each frame is the data of the PNG file that the generator writes for that frame.
- An animated PNG file shows the frames of the heron in its place. It does not show the move of the heron across a page: that is the work of the script of the home of the site.
- Some places choose the reader of a file by the end of its name. For such a place, name the animated file with `--out <name>.png`: the bytes are a PNG file.
- The command writes an animated file where `--out` says. The repository holds none.

The generator refuses a request with no sense, with a sentence, and writes no file. It never bends a request into another one:

- The smooth variant at one pixel for a cell: that picture is the cells variant.
- A cell size that is not a whole count of pixels from 1.
- A picture smaller than its drawing, a width with no height, a side longer than 8192 pixels.
- A gap with no name.
- The still mark with an animation or a frame; a frame with no animation, or past the last frame.
- A tile map with the name, with a background or with a size; a tile map with a frame; a tile map narrower than one tile.
- A format that does not hold what is asked: a tile map as a vector file, the still mark as an animated file, an animation as one PNG picture.
- The smooth variant as a vector file.
- The rule of the dark scheme with a format that is not `svg`, or with a picture of the dark scheme.
- An entry of an icon file that is larger than 256 pixels on a side; two entries of one size; `--entry` with a format that is not `ico`.
- An animation with no name of an animation, or with a frame.

A PNG file of the generator is the smallest that the encoder of the Odin standard library writes for its pixels: the highest level of its deflate, once with each row filter, the smallest kept. No pixel is lost. The picture for a developer is written at the common level, in one pass.

The host tests of the generator are in `mark_pictures_test.odin` and `mark_formats_test.odin`: each kind of request, each refusal, the table of the uses, the words of the command, and each format read back. The test of the icon file compares each entry with the PNG file of its picture, byte for byte. The test of the vector file draws its rectangles as a reader does, for each color scheme, and compares each pixel with the picture. The test of the animated file builds one PNG file from the data of each frame, decodes it, and compares its pixels and its time with the frame. `only_the_generator_draws_the_mark` fails when a file of the tool outside the generator calls a drawing procedure of `src/library/modus/mark`, or builds an icon file, a vector file or an animated file of the mark.

### The release

A release (`glossary/project.md`, "Release") is one section of `CHANGELOG.md`, one commit on `master`, and its release tag `v<release number>` on that commit. `modustool ship` makes the three and pushes them at once. The intent is `src/md/infrastructure/releases.md`. The push of the release tag starts the release workflow, which publishes the release image of the release with `modustool release image` (`INSTALL.md`, `src/md/infrastructure/release_image.md`).

```
## [0.93.0] - 2026-11-15 18:48

### Added

- **A thing**: what the system does now.

[0.93.0]: https://github.com/sachahjkl/modus/releases/tag/v0.93.0
[0.92.0]: https://github.com/sachahjkl/modus/releases/tag/v0.92.0
```

- The heading gives the release time (`glossary/project.md`, "Release time"): the day and the minute in UTC, with no zone in the text. An old heading whose time no record holds gives its day alone; the newest release always has its time.
- The release links (`glossary/project.md`, "Release link") close the file: one empty line after the last release, then one line for each release, newest first, with no empty line between them.

| Command | What it does |
|---|---|
| `modustool ship step` | The release `0.(N+1).0` after the newest release `0.N.x`: a release of new work |
| `modustool ship correction` | The release `0.N.(x+1)`: a correction after the newest release |
| `modustool ship <release number>` | That release; it must come after the newest release |
| `modustool ship ... --dry-run` | Checks the branch, the tree and `origin/master`, then prints the number, the release tag, the commands and the changes of the release. It writes nothing; the fetch updates the remote-tracking branches only |
| `modustool changelog release <release number>` | Writes the section with the time of the host in UTC and its release link, sets `RELEASE_NUMBER`, deletes the fragments, and copies the measure record to `docs/measures/releases/<release number>.txt` (below). `ship` runs it |
| `modustool measure-history` | Gives each release tag `v*` whose tree holds `docs/measures/measures.txt` its copy in `docs/measures/releases/`, with the rule of the copy below. It changes no file that exists, and prints the count of the tags, of the tags with a record, and of the copies written |
| `modustool changelog times` | Gives each old heading with its day alone the time of the commit of its release, and adds each missing release link |

**What `ship` does, in order.**

1. It refuses a branch other than `master`, a tree with changes that are not committed, and a `master` that does not hold `origin/master` after a fetch.
2. It takes the newest release: the higher of `RELEASE_NUMBER` in `src/library/modus/contract/release/release.odin`, read from the file, and of the highest tag `v*`. It takes the next number from it.
3. It runs `changelog release`. If that fails, it puts the tree back to the last commit, and removes the copy of the measure record that git does not track yet.
4. It commits `CHANGELOG.md`, the source of the release number, the deleted fragments and the copy of the measure record, with the message `Release <number>`.
5. It makes the release tag with `git tag -s -a`: annotated, and signed by the git configuration of the publisher of the system. If git cannot sign, `ship` undoes the commit and stops.
6. It pushes with `git push --atomic origin HEAD:refs/heads/master refs/tags/v<number>`: `origin` gets the commit and the tag, or neither.
7. If `origin` refuses the push because `origin/master` moved, `ship` deletes the tag, undoes the commit, fetches, merges `origin/master`, and goes back to step 2 with the next number. It tries three times at most (`SHIP_ATTEMPT_COUNT`). A merge with a conflict is aborted, and `ship` stops.

`ship` does not run the full check: run it on the commit before `ship`. The release workflow starts from the tag.

**The copy of the measure record.** The measure history (`glossary/project.md`) keeps the measure record of each release, for the chart of each measure over the releases (`SITE.md`, "The measure history"; `src/md/features/measure_history.md`). `changelog release` reads `docs/measures/measures.txt` and the history before it writes a file, and refuses a record that does not read. It writes no copy when the copy of the release before holds the same run, the same `time` and `commit`: no full check ran between the two releases. With no record, it writes no copy and says so. The folder `docs/measures/releases/` must exist for the add of `ship`: it holds the copies of the old releases, from `modustool measure-history`.

**The old headings.** `changelog times` reads three records of git for each heading with its day alone, in this order, and takes the first whose commit was made on the day of the heading, in the zone of the committer: the release tag; the oldest commit that wrote `RELEASE_NUMBER :: "<number>"` in a file `*release/release.odin`; the oldest commit that added the heading to `CHANGELOG.md`. It writes that time in UTC. A heading with no record on its day keeps its day alone, and the command names it. The command writes nothing when the result does not have the form that `changelog check` asks for.

`changelog check` refuses, for the release:

| Fault | The rule |
|---|---|
| The heading | `## [<major>.<minor>.<patch>] - <yyyy-mm-dd hh:mm>`, a day of the calendar and a time of the day; the day alone only for a release that is not the newest |
| The order | The release numbers descend and the release times do not rise. Two headings with a time compare by the minute; with a day alone, by the day |
| The release links | One for each release, in the order of the releases, each with the address of its release tag; no link for a number that is not a release; no empty line between two links; nothing after them |

The code is `tools/modustool/checks/changelog.odin` and `tools/modustool/checks/ship.odin`; the host tests are `changelog_test.odin` and `ship_test.odin`. A test checks the plan of git commands as data, and never runs git.

### The merge queue

The merge queue (`glossary/project.md`, "Merge queue") merges a batch of branches into `master` after one full check (`glossary/project.md`, "Full check"), in place of one full check for each branch. The intent is `src/md/infrastructure/branch_batches.md`.

```
nix develop -c modustool queue work/editor work/sound work/viewer
```

Run it from the main working tree, on `master`, with no change in the tree. The branches merge in the order of the arguments.

**What it refuses, with nothing changed.** Each refusal is one sentence; the refusals of the branches come all at once.

| Refusal | The rule |
|---|---|
| The list | No branch; more than `QUEUE_BRANCH_LIMIT` (32) branches; an empty name; a name that starts with `-`; `master` or `queue/batch`; a branch named twice |
| A branch | A branch that does not exist; a branch with no commit that `master` does not hold; a branch whose worktree has changes that are not committed |
| The main tree | A tree that is not on `master`; a tree with changes; a `master` that does not hold `origin/master` after a fetch |
| The identity | No `user.name` or no `user.email` in git; a set variable `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME` or `GIT_COMMITTER_EMAIL`. A merge is made under the configured git user only |

**What it does, in order.**

1. It prints the message of each merge: `Merge branch '<branch>': <summary>`. The summary is the description of the branch (`git branch --edit-description`), or else the subject of its oldest commit that `master` does not hold and that is no merge, with its first letter in lower case.
2. It makes the queue tree: a worktree `../kernel-queue` beside the main tree, on the branch `queue/batch`. The queue tree of a run that stopped before its end is removed first.
3. For each group, the whole batch first: it resets the queue tree to `master`, and merges each branch of the group with `git merge --no-ff`. A conflict in `docs/screenshots/` or in `docs/measures/measures.txt` takes the side of the queue tree, because the full check writes both again. Another conflict aborts the merge and names the branch and its files; in the whole batch, it stops the command, with nothing checked and nothing merged.
4. It runs the full check in the queue tree: `nix flake check`, then `nix develop -c modustool screenshots`.
5. When the check passes, it commits the pictures and the measure record in the queue tree, and `master` takes the queue branch with `git merge --ff-only`. The history of `master` is then a merge commit for each branch, in order, and one commit of the pictures.
6. When the check fails, the group splits in two halves, the first ⌈n/2⌉ branches and the rest, and the first half is tried first. A group of one branch whose check fails names that branch at fault. A conflict in a later group names its branch at fault with no check, and the group is tried again without it.
7. At the end, it removes the queue tree and its branch, prints the state of each branch and the count of the full checks, pushes `master` once when a group landed, then removes each merged branch with `git branch -d` and its worktree with `git worktree remove`.

**The count of the full checks.** For n branches and d = ⌈log₂ n⌉:

| Batch | Full checks |
|---|---|
| No branch at fault | 1 |
| One branch at fault | At most 1 + 2d: 9 for 12 branches |
| The budget | min(2n − 1, 1 + 2d · `QUEUE_FAULT_LIMIT`): 17 for 12 branches, 21 for 32 |

The queue stops after `QUEUE_FAULT_LIMIT` (2) branches at fault, and it never starts a check past the budget. The budget is the worst case of two branches at fault, so it stops only a run where a check fails with no branch at fault, as a check that fails once. The branches that were not checked stay branches, and the report says why.

The exit status is 0 when every branch merged, and 1 otherwise. The code is `tools/modustool/checks/merge_queue.odin`. The host tests, `merge_queue_test.odin`, give the run of the groups a host with no git and no Nix, whose checks fail from a list, and check the refusals, the messages, the side of a conflict, the halves, the budget at each size up to the limit, the order of the merges, and each stop.

### The rename of the library

`modustool rename-library` makes the moves and the rewrites of the step of the two source libraries (`src/md/infrastructure/repository_layout.md`, "The steps"). Its table of the old and the new forms is in its intent file, `src/md/infrastructure/branch_batches.md`. It takes no argument and makes no commit.

- It refuses a tree with files in conflict, a tracked file whose new place holds a tracked file or is under a tracked file, and a new place that exists with no tracked file in it. A refusal changes nothing.
- It moves each tracked file of an old folder to the same place under its new folder, with `git mv`. A move takes the largest folder whose new place holds no tracked file, so a tree before the rename makes three moves. An old folder that ends empty leaves; a file that git does not track stays, and the command names it.
- It rewrites the path of each import line and each old form of a comment in a `.odin` file, and each old form of a `.md`, `.txt` or `.manifest` file. It does not read the news entries, the fragments, `CHANGELOG.md`, `docs/measures/`, the designs that name the old forms on purpose, or its own source and test.
- It prints each move, each file changed with its count, and each line that still holds an old form: a string of a source, which a developer changes by hand.

It is idempotent: a second run moves nothing and rewrites nothing. So a branch that was made before the rename merges `master`, then runs it, and its own additions at the old places move and change. The code is `tools/modustool/checks/library_rename.odin`; the host tests, `library_rename_test.odin`, run it on a temporary tree with a host that moves with no git, three times: before the rename, again, and after a branch added files at the old places.

### The comparison of two measure records

`modustool measure-compare <record before> <record after>` reads two measure records: `docs/measures/measures.txt`, a copy of a release in `docs/measures/releases/`, or the record of a build that a full check wrote before a change. For each measure of the first record, it prints its line in each record. For a measure that a series of the measure history follows, it prints the number of each and the ratio of the second to the first. A measure that one record does not hold, or that one run did not give, is named, with no number. It asserts nothing: two runs of one build differ, and the host runs other work.

A change that moves the code of a writer, as a module that writes log facts in place of lines, compares the record of the full check before it with the record after it: the records of the log up to the start of the desktop, and the module files of the root service and of the compositor ("The measures of the log facts"). The code is `tools/modustool/checks/measure_compare.odin`, and its host test `measure_compare_test.odin`.

### The roadmap

`ROADMAP.md`, at the root of the repository, holds the planned work of the system. It is the one place of the plans: a guide says what is built and what is not built, and no other file lists the work to come. The changelog is its other half: `CHANGELOG.md` lists the work that is done, `ROADMAP.md` the work that is planned.

The file is plain Markdown that a reader understands with no tool. It has no front matter, no metadata field and no HTML.

```
# Roadmap

A few lines that say what the file is.

## Now

- **A short summary.** One or two sentences on what the work gives the user.

## Next

- **Another summary.** One sentence. [Design](src/md/features/the_design.md)

## Later

## Maybe

- **A third summary.** Two ways are open, and each waits for one thing.
```

- The title is `# Roadmap`. A preamble of text can follow it.
- The sections are `## Now`, `## Next` and `## Later`, in this order, each one time. **Now** is the work that is in progress. **Next** is the work that is decided and comes after. **Later** is the work that is wanted and has no order.
- An optional last section `## Maybe` holds what may be done one day and is not decided: each entry says the ways open and what each waits for. It comes after `## Later`, one time or not at all. The file has no other heading.
- A section is a list, which can be empty. An entry (`glossary/project.md`, "Roadmap entry") is `- **<summary>.** <one or two sentences>`. The summary is plain text of at most 80 bytes (`ROADMAP_SUMMARY_MOST`), with its period inside the bold. A next line of the same entry starts with two spaces.
- The sentences say what the work gives a user of the system, or a developer who builds on it. They do not say how the code changes.
- When an intent file holds the design of the work, the entry ends with its design link: `[Design](src/md/<file>.md)`. An entry has no other link.
- The file gives no date: a planned date that passed is a false sentence that nothing corrects. It names no person: git keeps who decided what.

**Who changes the file, and when.** The file is written by hand. An entry is added when a work is planned, and it moves from one section to another when its state changes. When a work is done, its entry is removed in the commit that adds the changelog fragment of the work. A work that is done in part keeps an entry whose summary names the part that is left.

`modustool roadmap check` checks the file; `modustool check` runs it, and `modustool site` stops on the same faults of form. Each problem is one sentence with the line of its fault. The check refuses:

| Fault | The rule |
|---|---|
| The title or a section | Line 1 is `# Roadmap`. The three sections are present, in their order, each one time; `## Maybe` comes after them, one time or not at all; no other heading exists |
| The lines | One empty line before and after a heading, no two empty lines, one line feed at the end, no tab, no space at the end of a line |
| The preamble | No front matter (`---`), no field `key: value`, no entry before the first section |
| The form of an entry | A bold summary with its period, not empty, at most 80 bytes, with none of the characters `*`, `[`, `]`, `<`, `>`; then one space and one or two sentences. A sentence ends at a `.`, a `?` or a `!` outside a code span, before a space or the end of the text |
| A date | A text `yyyy-mm-dd`, or the name of a month with a year after it. A year alone is not refused: `2048 pixels` is a count |
| HTML, a role | A tag of HTML outside a code span; the word `owner` |
| A link | A link in the sentences; a design link that is not the last part of the entry, or that names no file `src/md/<file>.md`, or a file that does not exist |
| An entry twice | Two summaries that are the same but for the case and the marks: on the site they would have one address |
| A work that is done | A summary that is the bold summary of a fragment, or of an entry of a release |

**The last rule, and its limit.** The tool cannot know that a work is done. It knows that an entry of the changelog has the summary of an entry of the roadmap. So the fragment that ends a planned work takes the summary of its roadmap entry as its bold summary, and the check then fails until the entry is removed: the removal cannot be forgotten in that commit. A fragment with another summary is not seen: the rule helps the writer who follows it, and proves nothing about the others. Two summaries that are equal by chance name two works with one name; the roadmap entry then takes a more exact summary. Two summaries are compared with no regard to the case and to the marks (`roadmap_summary_key`).

The code is `tools/modustool/checks/roadmap.odin`; the host tests are `roadmap_test.odin`. The page of the site: `SITE.md`, "The roadmap".

## The bounds of the tests

A test checks a condition: a value, a state, a line of the log. A test that depends on the speed of the computer that runs it fails on a loaded host with no fault of the system, so no test asserts a speed.

- **A time in a test has one role: to end a hang.** The bound is generous, and the same for each wait that has no reason of its own. It is never tuned to how fast the work is on some host.
  - A step of a machine test, and each wait of the tool after an input (the keys, the pointer, a reply of QEMU): `HANG_BOUND`, 120 s (`tools/modustool/foundation/processes.odin`). The QUIC cases and the cases of `remote` of the peer, the HTTP client of the host, the calls of the host, the wait for a key and the start of swtpm use the same bound. A TCP case of the peer has `CASE_TIME_LIMIT`, 180 s: one case runs several timers of the server of 10 s and more, in time of the machine.
  - The first Wait of a machine, its boot: `BOOT_HANG_BOUND`, 180 s.
  - The checks of a process that a machine test runs: `system.TEST_HANG_BOUND_MILLISECONDS`, 60 s (`src/library/modus/system/test_bounds.odin`). It is under the bound of a step, so that the process writes its own report of the hang before the tool ends the machine.
- **A case that can count its progress has a bound on a stall.** It ends when its count does not grow for `system.TEST_HANG_BOUND_MILLISECONDS`, or after `system.TEST_PROGRESS_OVERALL_BOUND_MILLISECONDS` (600 s) in all. The report names the step where the count stopped: a step that stays still tells a lost wake from a slow host. The Wait for the line of such a case has `PROGRESS_CASE_HANG_BOUND_SECONDS` (660 s), more than the overall bound of the process.
- **A number of speed is a measure.** A duration, a rate, a count in one second or "at most N ms" is printed, and can go to the measure record (`docs/measures/measures.txt`). It never makes a test fail. A rate over a duration is measured in a measure run only ("A check by count, a measure by time").
- **A behaviour in time of the system is checked by order and by its own clock.** A deadline that ends a wait, a budget of processor time that throttles a process, a timer of TCP, the idle timeout of QUIC and the clock are behaviours. The check has a lower bound where the behaviour is "not before" ("the idle end held its bound": the end came no earlier than the idle timeout, in time of the machine). Its upper side is the hang bound only, and the line prints how late the end came. A wake is checked by a deadline that is the hang bound: a wait that ended before its deadline was woken.
- **A test waits for a condition, never for a fixed time.** A thread that must be in its wait before a wake is read with `Thread_State` or `Process_State` until it is `Waiting`. A stress of a fixed time goes on until each side did its work at least once.

`modustool check` checks the steps of the machine tests (`tools/modustool/checks/test_bound_check.odin`). The field `seconds` of a step is a named constant, never a number, and a line of comment just above the constant gives its reason. The steps with a bound of their own today: the long case of the fault ring (its progress) and the firmware of the TPM and of Secure Boot (a command of the TPM that the firmware abandons costs it about two minutes).

The same check reads each `time.sleep` of the tool: its period is a name, and no digit stands outside a name in it (`time.Millisecond * 20` is refused too). A poll inside a bounded wait sleeps `CONDITION_POLL_PERIOD` (`tools/modustool/machine/machine_input.odin`); any other period is a constant with its reason, as the pause between the sends of the HTTP case "split" (`HTTP_SPLIT_SEND_PAUSE`), which shapes the input and waits for no state.

The check does not read the checks of the processes: `system.time() + 1000` is a poll interval in one place and a bound in another, and no rule on the text tells them apart. The rule for them is this section.

### A check by count, a measure by time

A process that shows a property of the system has two kinds of numbers. A check is a condition that a test must see: no record lost, each page returned, no spinner starved, the heavier weight got more. A measure is a rate: records in one second, reads in one second. A rate needs a duration, and a duration in each start of each process is time that a test waits for no condition.

So a process separates the two:

- **In a test, a process checks by count.** Each check ends after a fixed count of work, and its line gives the count. No check ends after a duration; the hang bound ends a check that never reaches its count, as a failure.
- **In a measure run, a process measures by time.** It runs the same work for a fixed duration, writes its rates, and still checks its counts.

A **measure run** is a machine whose boot image holds the resource `measure_run`. The root service then writes 1 in the value 22 of the context (`CONTEXT_VALUE_MEASURE_RUN`) of each process that it starts, and a process reads it with `system.measure_run()`. The modules are the modules of the test, byte for byte: the tool builds one boot image more (`build/boot_measure.image`, `build/boot_volume_measure.img`) from the same modules. A measure is then a measure of the code that the test checked. `modustool test` never starts a measure run; each form of `modustool measure` does.

`modustool measure <process>` starts one process alone on a measure run, waits for the lines of its measures and for its last line, stops the machine, and prints the lines of the process, then the lines of the processes that it starts to print measures of their own (`helpers` of its row). The log is `build/test_output_measure_<process>.txt`. A measured line can be a log fact: the print of a measure run and the measure record read the log with the line of each fact rendered by the module files of the build, so a measure keeps its sentence. `modustool screenshots` runs the measure runs whose numbers the measure record holds on the host, one machine at a time, after it took the test from the check of the flake.

| Process | The check of a test, by count | The measure of a measure run |
|---|---|---|
| `clock` | 1 000 000 reads of the time page with 0 kernel entries; 100 000 reads with a kernel entry; the page against the cycle counter over 16 changes of the page | Reads in one second in each way, for 1 s each; the page against the cycle counter for 0.5 s |
| `flow` | 200 000 records through each of 4 rings, each one read in order, 0 lost | Records in one second, for 1 s for each ring |
| `crowd` | 50 000 records from each writer through each of 5 queues, each one read one time | Records in one second, for 1 s for each queue |
| `disk` | 256 requests in each of 5 runs, 0 errors; 128 blocks written, flushed and read back | Blocks in one second, for 1 s for each run |
| `locks` | 16 384 kernel entries and 2048 pages on first use for each locker, with 1, 2 and 4 lockers; 2000 turns of the word wait alone and while 2 lockers enter the kernel 65 536 times each; 16 objects of 600 pages and 2048 pages for each locker of the case of the frames | Kernel entries and pages on first use in one second (300 ms for each row), wakes in one second (500 ms), rounds of 500 ms of the case of the frames |
| `scheduler` | Under each strategy: 16 rounds of the two threads, and 8 stints that a wake ended under EEVDF, by the counts of the kernel; each spinner ran 30 ticks, by the thread report, in each case of the shares; each of the four processes of the share policy ran 30 ticks, by its process report | Wakes in one second (400 ms), the late wakes of a thread that sleeps 2 ms 60 times, the work in one second and the shares over 500 ms; the shares of the four processes of the share policy over 1 s |
| `limits` | The processor time of each budget in the first whole interval of one second, against its limit | The same in the second interval, where each thread computes from the start of the interval |
| `log_reader` | Its own records, the records of its children, the refusals of `Log` and the three facts that it reads back ("The log") | The write of one line as text and as a fact, the operation `Log` of each form, and the render of a fact, after its checks ("The measures of the log facts"). The console starts it, since the start menu does not list it. The measure run first starts the window `log`, which is the service `log` that it connects to, and waits for its line "log: ok, ", as the main test does: the start list starts no process of that service, and the root service refuses a connection to a service with no process |
| `output_measure` | With 1, 2, 4 and 8 readers in turn: each reader reads the joined record of 0, the 2 200 records of the writer in order and its clean end record, and each process stops itself with the outcome Done | In cycles, the least and the median: a write of a record of 120 bytes into each ring, of 1000 writes, for each count of readers; with one reader, a log fact of the same record, of 200 facts, and the time from a write to the read of a reader that waits, of 200 records, with the wakes of a burst of 1000 records (`src/md/features/module_outputs.md`, "The measures that decide it", 1, 2 and 4). The writer and the reader print the lines, which the run prints after those of the asker (`helpers` in `measure_processes`). One asker holds 8 wirings at most: 16 readers are not measured. The console starts it |
| `processors` | The three pictures, with no pause between them, then the line of their times | No measure run: the times of the pictures are printed in each run |
| `processor_frame` | A pixel that each part writes has its color after the part, the drawing module refused no call, and each draw table holds each of its records; after the machine, the tool checks the form of the four lines (each part once, the least not above the median, the frames in one second from the median, a count of frames that is not 0) | A frame at 1920 × 1080 in memory, in three parts: a clear and a present, a frame of the compositor with 4 windows in full and in its damage, the execution of a draw table of a desktop; 21 frames of each, after one frame that is not counted; the least and the median in microseconds, and the frames in one second at the median. It runs in the measure run of `modustool measure` only (`src/md/features/desktop_to_browser.md`, "The first measure: a frame at 1920 × 1080 on the processor") |
| `compositor` | The line of the quality profile once; after the machine, the tool checks the form of the lines of the three measures (the least not above the median, a count that is not 0, a window start with a name and a time) | In each run, with the clock of the system: the time of a frame from the first record that it reads in the turn that draws it to the flip, over the last 64 frames, a line each 4096 frames and with each line of the keys; the time of a key to the screen, from the input service to the flip of the frame whose `Present` names the key, a line for each 16 keys that the console showed, and a line of the lost keys and the refused serials when they changed; the start of each window from `Process_Start` to its first frame, one line each when both times are known, in either order. The measure run waits for the profile and the start of `locks` in any order with the steps after them, and for a line of the frames and of the keys after the 24 keys of `start("processor_frame")`, more than the 16 keys of a line wherever the count stood (`src/md/features/desktop_to_browser.md`, "The three measures on the path of the system") |

Two processes keep a time in their check, because the property is a behaviour in time of the system. `limits` checks a limit of processor time for each second: its check needs one period of the budgets. `scheduler` checks shares, which are proportions over a time: its interval ends on a count of ticks of the spinner with the least share, not on a time of the clock, so a loaded host makes the interval longer and the check the same.

The window of each of these processes shows, in a test, the counts of its checks, and says that the rates are measured by `modustool measure`. It shows no rate that it did not measure. `processor_frame` has no window: its lines are its report.

