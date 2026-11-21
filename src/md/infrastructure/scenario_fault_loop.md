# The loop of a fault of a scenario

A full check takes 12 to 25 minutes, and it found one fault for each run: the first failed part ended the build of the flake. About half of the faults of a batch were a wait of a scenario that no longer matched the sentence of its log fact. This file records the three parts that shorten that loop: a step range, the check of the fact waits before any machine, and a full check that names every failed part.

## Purpose

- A developer who fixes one step of a scenario runs that step and its setup, not the whole part.
- A wait whose text no module writes fails in the host checks, in seconds, with its file and its line.
- One run of the full check names each failed part, with its first failed step and its whole log.

## Constraints

- A test never depends on the speed of the hardware ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The bounds of the tests"). A shorter run does not make a test pass that the whole part fails.
- The state of a machine at a step is not a closed set that the tool reads from the steps: a window in front, a connection of the console, a key of `remote`, a commit of the store, the place of the pointer.
- A step names no mark that only this loop reads: the scenarios hold about 2 800 texts of the log.
- A failed part must never be kept in the store as a pass.

## A step range

**The form.** `modustool test <part> steps <first> to <last>` runs the steps `first` to `last` of the first machine of the part. `of <machine>` names another machine of the part by its log, as `test_output_tpm_key_4`. `with <first> to <last>`, given once or more, adds setup steps that run before the range. The word `from` already names the folder of the test inputs (`test <part> from <folder>`), so the range has its own word.

**What runs.** The tool runs, in the order of the scenario:

1. the boot steps: the steps before the first step that is not a wait on the log, so the machine stands where its scenario first acts;
2. the setup steps that `with` names;
3. the steps of the range.

The machines of the part before the named machine run whole: a later machine reads the disk, the TPM state and the values that they left. After the last step of the range, the tool ends QEMU and the part. It runs no later machine and no procedure of the part after the named machine.

**The setup is explicit.** The tool cannot know the state that a range needs, so the developer names it. The tool checks what it can read from the steps, before the machine starts, with the checks that a whole scenario has:

- a mark (`{record}`, `{generation}`, `{screen text}`) that no selected step gives;
- a call of `remote` with no step `Remote_Key` since the last start of `remote` among the selected steps.

Each such refusal names the last step before the range that gives the missing value, so the next command adds it with `with`.

**The refusals.** Before the build and before any machine: a number that is not a whole number, a step 0, a first step after the last one, a setup range that is not before the first step of the range, and a word after the range that is not `of` or `with`. Before the named machine starts, when the tool knows its scenario: a last step past the steps of that machine. After the part: a machine name that the part never started.

**The end.** A range does not stop the machine as its scenario does, so the tool does not check the exit status of QEMU, writes no measure of the log of the main machine, and writes no count of checks. The lines that fail every scenario (a panic, a fault of the kernel) still fail it. The command prints the time of the boot steps, of the setup steps and of the range as measures.

**What it proves.** That the steps of the range pass after the boot and the setup on this build. It proves nothing about the part: a range that passes says that the fix can be right, and the full check proves it.

### Refused forms of the range

- **Run from the start and check only from the first step.** It costs the time of the whole part up to the range, which is the time to remove.
- **A dependency analysis that finds the setup.** A window title, a connection of the console and a typed line do not name the step that made them, and a guessed setup that is wrong fails far from its cause.
- **A mark `setup` on the steps.** The setup that a range needs depends on the range; a mark in the scenario is a second fact that a change of the scenario leaves wrong.
- **A snapshot of the machine before the range (`savevm`).** The state of the tool is outside the machine: the peer, its QUIC keys and TCP connections, the values that `Remember` kept, the pointer that the tool confirmed. A restored machine with a new peer is another machine.
- **The range with `from <folder>`.** A part derivation proves a part; a range proves less, and the check of the flake never runs one.

## The check of the fact waits

**The fault.** A fact template changes its sentence, splits into two facts, or a list becomes one fact for each row. The wait of the scenario still names the old sentence, and the machine runs to the hang bound of that step: one full check for each such fault.

**Which waits are fact waits.** The rule needs no mark on a step. A fact template starts with its fact prefix, the name of its module and ": " (`storage: `). The tool strips the head of a process (`[log_reader] `) and the text after the first mark of the scenario (`{record}`). The text is a fact wait when it starts with the fact prefix of a template of the build, and, when it has the head of a process, when the module of that name (the first word of the head) writes a fact of that prefix. A line of the kernel, of the boot program, or of a process with no fact table is no fact wait. A result of the console, `[console] notes: 2 objects`, is no fact wait either: the console writes no fact of the prefix `notes: `.

**The rule of a fact wait.** It must be the start of a sentence that a template can render, from a place where its prefix stands in the literals of the template. Each field of the template is a wildcard of its class: a Text, a text view, a module name, a status and the bytes of a log body are any characters; every other field is one word with no space, then the text of its integer unit. The end of the wait can be inside a field or before the end of the template; one byte past the end of the template is refused. So the three faults fail: the old sentence leaves the template at the changed word, at the end of the first of the two facts, or at the words of the list.

**The text lines.** A module that writes facts can still write lines as text with the same prefix (`errors: case b again: ...`). The tool reads each call `system.log(level, parts...)` of `src/modules` and `src/library` as one more template: each part that is a literal or a constant is its text, and each other part is a field of any characters. A text line never makes a wait a fact wait; it only renders one. A text line whose only literal is the prefix renders any wait of that prefix: the check refuses less, never more.

**The texts that it reads.** The compound literals of the sources of the tool with a field `kind`: the field `text` of a step whose text is a text of the log (`Wait` and each step that reads the log as a Wait does, and `Record`), the field `fails_on` of any step, and `expected` of `Key_Until`. A text is a string literal, a constant of the tool, or a sum of them. A text that the code formats (`fmt.tprintf`) is counted as not read: the step `Fact` and the check before the start of a machine already cover a fact by its type.

**The templates.** The fact tables of the module files of the build, read through the fact catalog: a module file holds the fact types that its code reaches, so a template that no code writes is no template of the check.

**Where it runs.** After the build of `modustool check without_machines`, which the host checks of the flake run, and after the build of `modustool test`, before any machine. `modustool fact_waits` builds and runs it alone. A part derivation does not run it: it has no source of the tool.

### Refused forms of the check

- **A mark on each wait that names its fact.** Thousands of steps would change, and a mark is a second place of the same fact.
- **The step `Fact` for every wait.** It is the right form for a new wait, and the scenarios move to it; the check holds the waits that are still texts meanwhile.
- **A prefix of the fact templates alone, with no text lines.** The modules that converted part of their lines would give false findings, and a false finding teaches a reader to ignore the check.
- **The templates from the sources.** The module files are what a reader renders, and they drop the fact types that no code reaches.
- **A wait as an infix anywhere in a sentence.** A field of any characters at the start of a template would then hold every wait; the prefix must stand in the literals.

## A full check that names every failed part

**The form.** The build of the check of the flake passes `--keep-going` to Nix: Nix builds every derivation whose inputs it built, past the first failed one. `modustool screenshots` passes it, and the workflows pass it to `nix flake check`. When the build fails, the tool lists the failed parts: `modustool failed_parts`, which `screenshots` calls after a failed build.

**One evaluation.** `screenshots` evaluates the check of the flake once, before the build: the derivation of the whole check, and the derivation and the output of the host checks and of each part. It builds that derivation path (`nix build <check>.drv^out`), and the list reads the same derivations. What changed: the list evaluated the flake again after the build. The work tree of the check had changed meanwhile (another agent wrote in it), so the second evaluation named other derivations, which nothing built: the list called every part "did not run", the parts that passed too, and found no log.

**The list.** For the host checks and each part derivation whose output is not in the store, the tool reads its build log from Nix (`nix log <derivation>`) and writes it whole to `build/failed_parts/<part>.log`. The line of the part gives the first line of the log that says that a step failed, with the log of its machine, and the path of the whole log. A log with no such line (the host checks that stop at a compile error) gives the last line of the tool that says that something failed. A part with no log did not run: a derivation that it needs failed (the binary of the tool, the test inputs), or the build stopped first. No part depends on the host checks: a failed host check stops no part. The list ends with the count of the failed parts, the count of the parts that did not run, and the count of those that passed. When no derivation passed and none failed, a last line says that the evaluation is not the check that the build built, or that the build stopped before any part.

**The command alone.** `modustool failed_parts`, after a `nix flake check --keep-going` by hand, has no evaluation of the build: it evaluates the work tree as it is. On a tree that changed since the check, its last line says that nothing of that evaluation was built.

**A failed part stays a failure.** A part derivation still fails when its part fails: Nix keeps no output of it, so the next build runs it again.

### Refused forms of the list

- **A part derivation that passes with a mark of failure in its output.** Nix would keep the failure in the store and run the part no more until its inputs change, so a failure from a starved host would stay; and the build of the derivations would pass.
- **The list in `test_join`.** The join runs only when each part passed.
- **An evaluation after the build.** It reads the work tree again, which can change while the check runs; the list must name the derivations that the build built.
- **The log of a failed part in the output of the check.** A failed derivation has no output; its build log is the one record of its run.

## Subtle points

- A procedure of a part can check something on the host between two machines. After the named machine, the tool returns a failure to the part, so a chain `machine_test(...) && check(...)` stops, and the part passes or fails on the range alone. A procedure that checks its log after the named machine with no such chain would read a cut log: no part does today.
- A Wait in a range searches from the text of the last Wait that ran, which can be a boot step: a line of the boot can match a Wait of the range that the whole scenario matched later.
- The check of the fact waits reads the constants of the tool and of the system by their name. A name that two packages declare with two values names no text, and the check reads no step that uses it.
- `nix log` needs the build logs that Nix keeps (`keep-build-log`, the default).

## State

Built: the step range with its boot steps, its setup steps, its refusals and its measures; the check of the fact waits with the text lines, in `check without_machines`, in `test` and as `fact_waits`; `--keep-going` in `screenshots` and the workflows, and `failed_parts`.

Left: the scenarios that wait for a fact by its text move to the step `Fact`, so the check of the fact waits holds fewer texts.
