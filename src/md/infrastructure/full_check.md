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

So the order of the two commands does not matter: the second one finds the output of the first in the store.

## What the full check proves, before and after

Each fact that the two runs proved is proved by the one run of the flake: the build of the tracked files, the host tests, each machine, the second build. The measure runs stay on the host. The pictures were a fact of a run on the host; they are now a fact of the run in the sandbox, which is the same build of the same tree.

## Refused forms

- **`screenshots` as a superset of `check`, and a flake check that proves less.** The workflows run only the flake: a flake check that skips the machine test lets a release ship a system whose machines never ran.
- **Two runs, one in each command.** That was the form before: each run of the machine test and each pair of whole builds twice, for no fact that one run does not prove.
- **The measure runs in the sandbox.** The sandbox runs the machine test with several parts at once, and a rate under that load says little. The measure runs need a quiet host; the host of the developer is that host.
- **`screenshots` that reads `build/` of an earlier `modustool check` on the host.** Nothing would tie those files to the tree; the store path of the flake check is the hash of its inputs.

## Subtle points

- The flake sees only the tracked files and the folders that `flake.nix` names. A new file must be added to git before the full check, or the check proves a tree without it.
- The pictures come from the boot image of the flake, which has the pointer theme of the system only ([release_image.md](release_image.md)): the pointer in the pictures is the pointer of a release.
- `build/flake_check` is a root of the garbage collector of Nix: the output of the last check stays in the store until the next one.
- The output holds every picture of the test, so it is tens of megabytes.

## State

Built: the output of the check, the command that takes it, the count of the checks, the measure runs on the host.

Left: the measures of the host checks of `modustool check` in the same time record as the machines.
