# The LLVM of the build

## Purpose

One source gives one module, and also one LLVM IR file and one object: a difference in the IR or the object is the early sign of a module that will differ ([`docs/REPRODUCIBLE_BUILD.md`](../../../docs/REPRODUCIBLE_BUILD.md), "The outputs that the tool compares"). The Odin compiler optimizes with the LLVM that it links, and `llc` makes the object. So the order of the work inside LLVM is a part of the build, as the order inside the compiler is.

This file records why the build uses LLVM 18 with one commit of a later LLVM, and which forms were refused. The symptom, the tests that found the cause and the measures are in [`docs/REPRODUCIBLE_BUILD.md`](../../../docs/REPRODUCIBLE_BUILD.md), "9. The order of dead store elimination".

## Constraints

- The release of the Odin compiler that the flake pins builds with LLVM 18. A newer LLVM changes the code of some modules with and without debug information ([debug_information_and_code.md](debug_information_and_code.md)).
- The compiler allocates on several threads. An order that depends on the address of an object in memory is not an order of the source.
- The compiler writes debug information with assignment tracking at each optimization mode above `none`. That is the release, not the fork: it holds for `-debug` and for `-debug-info:same-code`.
- Dead store elimination of LLVM 18 visits the stores that it shortens in the order of a table keyed by the addresses of the instructions. With assignment tracking, each shortened store adds debug records beside a record that several stores share, in the order of that visit.

## The chosen form

**LLVM 18 with the upstream commit that fixes the order**, built by the flake: LLVM commit `c833746c6c06` makes the table keep the order of insertion. The flake fetches the commit by its hash and adds it to the patches of the LLVM 18 of Nixpkgs. The Odin compiler links that LLVM, and `llc` comes from it.

- **The cause, not the symptom.** Any loop that the optimizer unrolls, with a store that a later store overwrites in part, can show the fault. A rule for the sources cannot list those cases.
- **The commit of the project of LLVM, unchanged.** A reader finds its history and its reason upstream, and the change goes away with the move to an LLVM that has it.
- **No change of the code.** The shortening of each store does not depend on the others, so only the order of the debug records changes. Measured on `console`: the module and the debug object are the same bytes with and without the commit.
- **One LLVM in the build.** `llc` does not run this pass, but the build has one LLVM, so a reader does not ask which one made an output.

## The refused forms

- **Move each buffer out of its loop.** It hides one case and leaves the cause. The next module with the same form of code differs, and the check finds it only when two builds happen to differ.
- **`-thread-count:1`.** Measured: the fault stays. With this release the flag leaves two threads. Even with one thread, the order of a table keyed by addresses is a fact of the allocator, not of the source.
- **Stop assignment tracking in `same-code`, by a commit of the fork.** It removes the records whose order shows the fault, and leaves the visit in the order of addresses. A debugger then loses locations that assignment tracking keeps. The fork changes the compiler for a fault of LLVM. This form was not measured.
- **Sort the records in the tool, as it writes 0 for the time of the compile.** The tool would rewrite the program after the compiler. The order of debug records at one place is a part of their meaning, and a sort that is right for this case is not proved for the next one.
- **A newer LLVM.** LLVM 21 has the commit, but the compiler release builds with LLVM 18, and a newer LLVM changes the code of some modules with and without debug information ([debug_information_and_code.md](debug_information_and_code.md)).
- **A patch file in the repository.** The commit upstream is the source of the change. The flake names it by its hash.

## The subtle points

- **The cost is a build of LLVM.** No binary cache has this LLVM. A machine with no copy in its store builds it once, and the first run of the CI too. The tests of LLVM do not run: the commit is tested upstream, and the full check of the system builds every module two times.
- **The module was never different.** The fault changed the IR and the debug sections of the object. A check that compared only the modules would not have seen it, so the check compares every output.
- **Another table keyed by addresses** can exist in LLVM 18. The two builds of each full check and `modustool repeat all` find it.

## State

Built:

- The flake builds LLVM 18.1.8 with the commit. The compiler and `llc` use it.
- The buffer of `palette_candidates_give` is declared inside its loop again.

Left:

- The move to an LLVM that has the commit (the entry "LLVM 22" of `ROADMAP.md`), with a new measure of the modules that differ with and without debug information. The commit then leaves the flake.
