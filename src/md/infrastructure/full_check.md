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

**The machine test runs once, in the check `boot-test` of the flake.** It runs `modustool check`: `odin check -vet`, the checks of the sources, the host tests, the fuzz targets, the whole machine test, and the second build. Its output in the store holds `logs/` (each `build/*.txt`: the logs of the machines, `test_times.txt`, `reproducible_build.txt`, `checks_passed.txt`) and `screenshots/` (the pictures of the test).

**`modustool screenshots` takes that output.** It runs `nix build .#checks.x86_64-linux.boot-test --out-link build/flake_check`. When `nix flake check` passed on the same tree, Nix takes the output from the store and runs nothing; else this build is the check, with the same proof. Then the command:

1. copies the pictures and the logs into `build/`, as new files (the files of the store are read-only), after the time of the start of the run, so the measure record reads them as logs of this run;
2. adds the count of the checks of the flake (`checks_passed.txt`) to its own count;
3. copies the pictures to `docs/screenshots` and to a new folder of the development log;
4. builds the volume of the measure runs on the host, runs the measure runs, and writes the measure record.

**The source of the check holds no byte that `screenshots` writes.** `screenshots` writes the pictures of `docs/screenshots` (the bar shows a clock: each run gives new bytes), the measure record (`docs/measures/measures.txt`) and the development log, outside the repository. The source of `boot-test` holds no file of `docs/measures`, and of `docs/screenshots` only the names of the PNG files: the build writes a PNG of one pixel under each name. The checks of the README, the news and the pages of the site read which pictures exist and that each is a PNG with a size, not the bytes of the picture. An empty file is refused: the site renders the text of a picture that is no PNG, and its test fails. So the source is the same before and after `screenshots`, and the order of the two commands does not matter: the second one finds the output of the first in the store. A run of the test that saves a picture with a new name gives a new source after its copy; that is a change of the test, which a new check must prove.

## The host tests at once

What changed: `modustool check` ran the `odin test` of each folder of `HOST_TEST_FOLDERS` one after the other. It now runs them at the same time, each in its own process.

**The pool.** The host tests use the pool of processes of the parallel build of the modules (`build_host_processes_run`): one worker thread for each process at once, each takes the next folder of the list, and after a failure no new process starts while the processes that run end. The count at once is one for each processor that the check counts on, at least one and no more than the folders: the processors of the host, or `NIX_BUILD_CORES` in the sandbox when it is fewer, as for the parts of the machine test. A host test is a compile, then a test program on its own threads: one process for each processor keeps the processors busy with no more processes than they run.

**The order.** The pool takes the folders in the order of the list, and the tool is first: its compile and its tests are the longest, and a long folder that starts last makes the whole run longer. The report has the order of the list.

**The files of a folder.** Each folder writes only its own files, named by its path with `_` for each `/`: its test program `build/test_<name>`, its log `build/host_tests/<name>.txt`, and the temporary folder of its compiler, `build/host_tests/<name>`. The compiler names the object of an assembly file in its temporary folder by the name of the file and an address of its own memory. The two folders of the runtime assemble two different files of one name, `memory_for_host_tests.asm`, so with one temporary folder for all, two compilers at once could write one object, and a test would run the procedures of the other folder. A list in which two folders give one name is refused before any process starts.

**The report.** For each folder that passed, one line with its time: `modustool: measure: the host tests of <folder>: <seconds> s`, then one line with the time of all on the clock. Each time is a measure, never a condition. For each folder that failed, its time, the path of its whole log, and its last 40 lines, where the summary of the test runner is. The count of the folders that did not start after a failure is one line. The kernel flag goes to the folders under `src/kernel` and to the tool only, as for their compile.

Refused forms:

- **A pool of its own for the host tests.** The pool of the build already keeps the output of each process, keeps the order of the commands, and stops after a failure; a second pool would be a second form of the same rule.
- **Each output on the terminal while it runs.** The outputs of several processes would mix line by line. The log of each folder is whole in its file, and the terminal gets the lines that a reader needs.
- **Every folder after a failure.** A check stops at its first failure, as the module build does; a developer runs the folder alone to see the rest.
- **One test program for all the folders.** A package of the library is compiled with its own flags, and the kernel parts must stay out of the library: one program would need the kernel flag everywhere.

## What the full check proves, before and after

Each fact that the two runs proved is proved by the one run of the flake: the build of the tracked files, the host tests, each machine, the second build. The measure runs stay on the host. The pictures were a fact of a run on the host; they are now a fact of the run in the sandbox, which is the same build of the same tree.

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
- The output holds every picture of the test, so it is tens of megabytes.

## State

Built: the output of the check, the command that takes it, the count of the checks, the measure runs on the host, the host tests at once with the time of each folder as a measure. The check runs the binary of the tool that the flake builds once for each change of its sources ([repository_layout.md](repository_layout.md), the tool built once).

Left: the measures of the host checks of `modustool check` in the same time record as the machines.
