# The full check

A full check is `nix flake check` and `modustool screenshots`, both passed. This file records how the two commands share one run of the machine test.

## Purpose

- Prove that the system builds from the tracked files alone, that every host test and every check of the sources passes, that every machine of the test passes, and that a second build gives the same bytes.
- Give the pictures of the documents, the logs that the measure record reads, and the measure runs of the record.

## Constraints

- The flake check must prove everything alone, in its sandbox: the check workflow and the release workflow run only `nix flake check`.
- A rate is measured on the host, with no other machine ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "A check by count, a measure by time").
- The pictures and the record go into the work tree of the developer, which the sandbox cannot write.

## The chosen form

**The machine test runs once, in the check `boot-test` of the flake.** The check is the join of several derivations, so that Nix runs again only what a change reaches (below, "The derivations of the check"). Its output in the store holds `logs/` (the logs of the machines, `test_times_<part>.txt` for each test part, `reproducible_build.txt`, `checks_passed.txt`) and `screenshots/` (the pictures of the test).

**`modustool screenshots` takes that output.** It prints how many test parts Nix takes from the store, then runs `nix build .#checks.x86_64-linux.boot-test --out-link build/flake_check --max-jobs <count>`. When `nix flake check` passed on the same tree, Nix takes the output from the store and runs nothing; else this build is the check, with the same proof, and it runs only the derivations whose inputs changed. Then the command:

1. copies the pictures and the logs into `build/`, as new files (the files of the store are read-only), after the time of the start of the run, so the measure record reads them as logs of this run;
2. adds the count of the checks of the flake (`checks_passed.txt`) to its own count;
3. copies the pictures to `docs/screenshots` and to a new folder of the development log;
4. builds the volume of the measure runs on the host, runs the measure runs, and writes the measure record.

**The source of the check holds no byte that `screenshots` writes.** `screenshots` writes the pictures of `docs/screenshots` (the bar shows a clock: each run gives new bytes), the measure record (`docs/measures/measures.txt`) and the development log, outside the repository. The sources of the derivations of `boot-test` hold no file of `docs/measures`, and of `docs/screenshots` only the names of the PNG files: `hostChecks` writes a PNG of one pixel under each name. The checks of the README, the news and the pages of the site read which pictures exist and that each is a PNG with a size, not the bytes of the picture. An empty file is refused: the site renders the text of a picture that is no PNG, and its test fails. So the source is the same before and after `screenshots`, and the order of the two commands does not matter: the second one finds the output of the first in the store. A run of the test that saves a picture with a new name gives a new source after its copy; that is a change of the test, which a new check must prove.

## The derivations of the check

The machine test takes most of the time of a full check: 12 to 25 minutes on a host of 16 processors, for every change, also a change of a document. Its test parts share nothing ([machine_test_parts.md](machine_test_parts.md)), so each can be a derivation of its own, which Nix takes from the store when its inputs did not change.

**The rule.** The input of a test part is what its result depends on, and nothing more: the binary of the tool, the bytes of the build that its machines boot and read, the system sources that a part reads at its run, the firmware, QEMU and the other programs of the host. A change of a document or of a host test reaches none of them, so it runs no machine again.

**The derivations**, in the order of their dependencies:

1. `modustoolBinary`: the tool, from its sources that are not tests ([repository_layout.md](repository_layout.md), the tool built once).
2. `systemBuild`: a whole build of the tree (`modustool build whole`), then `modustool test_inputs`, which copies the test inputs (`docs/glossary/project.md`) into its output, and the hash of that folder, as Nix computes the hash of a path. Its source is the source of the old single check: every tracked file that a build or a check can read. Its output changes with any change of the tree.
3. `testInputs`: a fixed-output derivation that copies the folder of `systemBuild`. Its expected hash is the hash file of `systemBuild`, which the flake reads at its evaluation (an import from a derivation). Nix names a fixed-output derivation by its hash alone, and a derivation that depends on it depends on that hash, not on how it was made. So two trees whose builds give the same bytes give one `testInputs`, whatever the change of their sources.
4. One part derivation for each test part, `machine-test-<part>`: it depends on `modustoolBinary`, `testInputs`, the system sources with no test file and no intent file (`src`, `resources`), and the programs of the host. It runs `modustool test <part> from <testInputs>`: the part alone, with no build. Its output holds its logs, its pictures and the count of its checks.
5. `hostChecks`: `modustool check without_machines`: `odin check -vet`, the checks of the sources, the host tests, the fuzz targets, its own whole build of the main volume and the second build. Its source is the whole tree, as before: these checks read the documents.
6. `boot-test`: `modustool test_join` joins the outputs of `hostChecks` and of each part derivation in the layout that `screenshots` reads.

**What a part reads of the build.** Past its boot volumes, a part reads files of each module: the engine of a machine reads the module files and the debug objects, and the part `host_modules` also reads the sources of each compile and the fact keys that it found. Each kind of such a file is a member of `Build_File_Kind`; a part declares the kinds that its own procedures read (`reads` of its row), and the engine adds its own. `test_inputs` refuses, in the whole build and before any machine of any part starts, a part that declares a kind that the test inputs drop, or whose file of a module the inputs lack; `test <part> from` refuses the same before its first machine. A host test reads the sources of the tool: each procedure of a row that names a file of a kind must be of a declared kind, and each procedure that names a dropped kind (the linked file, the list of the compiler, a build record) must be a step of the build or of `check`, in a list that names each one.

Two readers of dropped files were on the path of a part, and each got the form that its fact asks for:

- **The sources of a compile.** The log facts of a module and the check of the declarations of its imports read the sources that the compiler read. They read them from the list of the compiler, which names its libraries in the store. The compile step now writes `sources.list` beside it: the Odin sources of the repository alone, by their path from its root, sorted. The build and the test of the descriptions read that one list, so the build and the part share one reader, and the test inputs keep it. The list of the fact keys that the compile found has the name `reached_facts.list`, as a list and not a log.
- **The debug objects against the linked files.** The test reads the symbols of the linked file of `fault`, which holds the debug information of the compiler with its paths in the store. A stripped copy in the test inputs would be one more output made for one test; a build of `fault` in the part would build a module again in a test of the build. The test checks the build itself, so it runs where the build is: `check` runs it after its build, in both forms, and it left the part `host_modules`.

**The list of the parts comes from the tool.** `systemBuild` writes the names of the test parts beside the test inputs, and the flake makes one part derivation for each name. `test_join` refuses a join that lacks a part of the table, or that has a part twice, so `boot-test` holds the whole test or fails.

**Parallelism.** Nix runs the part derivations at once, up to its `max-jobs`, in place of the pool of the tool: a part derivation runs one part, on the thread of the command. Each machine has `MACHINE_PROCESSOR_COUNT` processors and `MACHINE_MEMORY_MIB` of memory, and a part runs its machines one after the other, so a part holds that many processors and that much memory. `screenshots` passes `--max-jobs` with the bound of the pool of `modustool test` ([machine_test_parts.md](machine_test_parts.md), "The chosen form", the pool):

```
max-jobs = max(1, min(parts, processors / MACHINE_PROCESSOR_COUNT,
                     (MemAvailable - HOST_MEMORY_MARGIN_MIB) / largest part))
```

`MemAvailable` is read from `/proc/meminfo` when `screenshots` starts, before Nix starts any part. The bound by memory has its reason in one failed run of the check: Nix ran about sixteen machines of 1 GiB at once on a host of 16 processors and 32 GB, the host swapped, and a machine got no processor for two minutes, so its step failed at its bound with no fault of the system. A count above the bound by processors runs slower, never wrong: no test depends on the speed of the host. A count above the bound by memory is wrong in a way that no bound of a hang can absorb, because a swapped machine can stand still for longer than any bound. A developer who runs `nix flake check` passes the same bound to `--max-jobs`; the line that `screenshots` prints gives its two parts.

**The measure.** Before it builds the check, `screenshots` reads the output path of each part derivation (`partOutputs` of `boot-test`) and asks Nix which of them are in the store. It prints how many parts Nix takes from the store and how many run. It is a count, never a condition.

**The proof of the cache.** `modustool part_cache` copies the tracked files into three trees: one with no change, one with a line more in an intent file, one with a line more in a host test of the tool. It evaluates the derivation of each test part in each tree, and requires the same derivation for each part in the three trees, and another `systemBuild` in each changed tree, so the change reached the build and the test cannot pass with no change. It compares derivation paths, never a time. Its cost is two whole builds, so it runs on demand and not in each check.

### Refused forms of the derivations

- **One derivation for the whole test.** That was the form before: a change of a document ran every machine again, because the source of the check holds the documents.
- **The source tree as the input of a part.** The build reads the guides (the pages of the manual), so a tree is a coarse key: most changes of a guide give the same bytes of the build. The hash of the bytes is the honest key.
- **A cache of the tool of its own, outside Nix.** It would be a second rule of what a result depends on, beside the one of Nix, and the check workflow, which runs only `nix flake check`, would not use it.
- **Content-addressed derivations of Nix.** They give the same effect with no import from a derivation, but they are an experimental feature that each host and the check workflow must turn on.
- **One fixed-output derivation for each part, of its boot volumes only.** A change of a module changes the main volume and the module files, which nearly every part reads: the parts would differ in their inputs in name only. One folder for all parts is simpler for the same effect.
- **The build in each part derivation.** Each part would build the whole system again: about thirty builds in place of one.
- **The list of the compiler with the paths of the store cut out, written by `test_inputs`.** The build and the part would read two files for one fact, and a reader of the build would never meet the file that the part reads.
- **A part that finds a missing file at its first read.** The part derivation then fails after its machines ran, with a cause far from the input; the check before any machine names the part and the file.
- **The pictures and logs joined by the shell of the flake.** The refusal of a part that lacks, of a part twice and of two parts that save one picture is logic, which a host test of the tool checks.

### Subtle points of the derivations

- The evaluation of the flake builds `systemBuild`, because it reads its hash file: `nix flake check`, `nix flake show` and `nix eval` of a part run a whole build first. A host that forbids an import from a derivation cannot evaluate the check.
- A fixed-output derivation must hold no path of the store. The test inputs hold no LLVM IR, no object, no linked file, no build record and no log: these name the compiler in the store, or the time and the sources of one build. A new kind of output that names a path of the store makes `testInputs` fail with the name of the path.
- The bytes of a build that holds a signature or a variable store with a time are not the same twice. Such a file in the test inputs makes `testInputs` new at each build: the parts run again, with no fault. The measure shows it as parts that run after a change of a document.
- The binary of the tool is one input of every part. A change of the scenario of one part changes the binary, so every part runs again. The state names this.
- The sources of `src` and `resources` are inputs of every part, because a part reads some of them at its run (the source of `fault` for the lines of a stack trace, the examples of a module outside the sources). So a change of a comment of a module runs every part again, even when the bytes of the build stay. A list of the sources that each part reads would narrow it; the parts name no such list today.
- The guides are inputs of the build, for the pages of the manual. A change of a guide whose pages a module names changes the boot image, and every part runs again; a change of another guide does not.
- In a part derivation, the boot volumes and the boot images are links to the store: QEMU reads each volume with `snapshot=on`, and no part writes one. Every other file of the test inputs is copied, so a part can write over it.

## The host tests at once

What changed: `modustool check` ran the `odin test` of each folder of `HOST_TEST_FOLDERS` one after the other. It now runs them at the same time, each in its own process.

**The pool.** The host tests use the pool of host processes of the parallel build of the modules (`build_host_processes_run`): one worker thread for each host process at once, each takes the next folder of the list, and after a failure no new host process starts while the host processes that run end. The count at once is one for each processor that the check counts on, at least one and no more than the folders: the processors of the host, or `NIX_BUILD_CORES` in the sandbox when it is fewer, as for the parts of the machine test. A host test is a compile, then a test program on its own threads: one host process for each processor keeps the processors busy with no more host processes than they run.

**The order.** The pool takes the folders in the order of the list, and the tool is first: its compile and its tests are the longest, and a long folder that starts last makes the whole run longer. The report has the order of the list.

**The files of a folder.** Each folder writes only its own files, named by its path with `_` for each `/`: its test program `build/test_<name>`, its log `build/host_tests/<name>.txt`, and the temporary folder of its compiler, `build/host_tests/<name>`. The compiler names the object of an assembly file in its temporary folder by the name of the file and an address of its own memory. The two folders of the runtime assemble two different files of one name, `memory_for_host_tests.asm`, so with one temporary folder for all, two compilers at once could write one object, and a test would run the procedures of the other folder. A list in which two folders give one name is refused before any host process starts.

**The report.** For each folder that passed, one line with its time: `modustool: measure: the host tests of <folder>: <seconds> s`, then one line with the time of all on the clock. Each time is a measure, never a condition. For each folder that failed, its time, the path of its whole log, and its last 40 lines, where the summary of the test runner is. The count of the folders that did not start after a failure is one line. The kernel flag goes to the folders under `src/kernel` and to the tool only, as for their compile.

Refused forms:

- **A pool of its own for the host tests.** The pool of the build already keeps the output of each process, keeps the order of the commands, and stops after a failure; a second pool would be a second form of the same rule.
- **Each output on the terminal while it runs.** The outputs of several processes would mix line by line. The log of each folder is whole in its file, and the terminal gets the lines that a reader needs.
- **Every folder after a failure.** A check stops at its first failure, as the module build does; a developer runs the folder alone to see the rest.
- **One test program for all the folders.** A package of the library is compiled with its own flags, and the kernel parts must stay out of the library: one program would need the kernel flag everywhere.

## What the full check proves, before and after

Each fact that the two runs proved is proved by the one run of the flake: the build of the tracked files, the host tests, each machine, the second build. A part that Nix takes from the store was proved on the same bytes of the build and the same binary of the tool, so its proof holds for the new tree. The measure runs stay on the host. The pictures were a fact of a run on the host; they are now a fact of the run in the sandbox, which is the same build of the same tree.

## Refused forms

- **`screenshots` as a superset of `check`, and a flake check that proves less.** The workflows run only the flake: a flake check that skips the machine test lets a release ship a system whose machines never ran.
- **Two runs, one in each command.** That was the form before: each run of the machine test and each pair of whole builds twice, for no fact that one run does not prove.
- **The measure runs in the sandbox.** The sandbox runs the machine test with several parts at once, and a rate under that load says little. The measure runs need a quiet host; the host of the developer is that host.
- **`screenshots` that reads `build/` of an earlier `modustool check` on the host.** Nothing would tie those files to the tree; the store path of the flake check is the hash of its inputs.
- **A rule of order, `nix flake check` first.** With the pictures in the source, `screenshots` after the check changes the source, and the next check runs every machine again; a rule that a developer must keep is weaker than a source that does not change.
- **Empty pictures in the repository.** The checks need the names only in the sandbox; the documents need the bytes.

## Subtle points

- The flake sees only the tracked files and the folders that `flake.nix` names. A new file must be added to git before the full check, or the check proves a tree without it.
- The pictures come from the boot image of the flake, which has the pointer theme of the system only ([release_image.md](release_image.md)): the pointer in the pictures is the pointer of a release.
- `build/flake_check` is a root of the garbage collector of Nix: the output of the last check stays in the store until the next one.
- The pictures come from the host that built the check. When Nix takes the output from a binary cache (a cache that the check workflow filled, for example), the pictures and the logs are those of that host: on a host with no SVM or no counters for the test machine, the pictures of `guest` and `kernel_events` show the form with no support. The measure runs stay of the host of `screenshots`. The measure record names the host of `screenshots`, not of the check.
- The output holds every picture of the test, so it is tens of megabytes. The test inputs hold every boot volume of 64 MiB, so each new `testInputs` is a few gigabytes of the store until the collector of Nix removes it.
- The pictures and the logs of a part that Nix takes from the store are those of its earlier run. The pictures show a clock, so the time in a picture can be older than the commit of the measure record.

## State

Built: the output of the check, the command that takes it, the count of the checks, the measure runs on the host, the host tests at once with the time of each folder as a measure. The check runs the binary of the tool that the flake builds once for each change of its sources ([repository_layout.md](repository_layout.md), the tool built once). The check is the join of one derivation for each test part, of the host checks, and of the test inputs named by the hash of their bytes; `screenshots` prints how many parts Nix took from the store; `part_cache` proves that a change of a document or of a host test runs no part again. `screenshots` bounds the parts at once by the processors and by the available memory of the host.

Left: the bound by memory for `nix flake check` when a developer runs it with no `--max-jobs`, which Nix then takes from its own configuration. The measures of the host checks of `modustool check` in the same time record as the machines. A change of the scenario of one test part still runs every part again, because each part derivation takes the whole binary of the tool: each part needs a binary of its own, built from the engine of the machine test and the files of its own scenario only, which needs the scenarios in packages of their own.
