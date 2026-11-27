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
- **Sort the records in the tool, as it writes 0 for the time of the compile.** The tool would rewrite the module after the compiler. The order of debug records at one place is a part of their meaning, and a sort that is right for this case is not proved for the next one.
- **Stock LLVM 22.1.8 from Nixpkgs.** Measured on all 188 modules and the WebAssembly kernel (`freestanding_wasm64p32`): LLVM 22.1.8 fixes the dead store elimination fault (`modustool repeat console 12`: 1 distinct LLVM IR, object, module, and debug object), removes the custom LLVM build, shrinks the 188 modules by 2.1 % (`40 429 118` to `39 567 446` bytes) and `modulus_kernel.wasm` by 6.0 % (`833 958` to `784 293` bytes), and reduces the deepest stack chain of `kernel` by 688 bytes (`44 192` to `43 504` bytes). Two upstream LLVM 22.1.8 faults block the switch:
  1. **`LoopSimplifyPass` IR nondeterminism.** In `extended_state` (`parts_measure`), `LoopSimplifyPass` removes dead predecessors after `LoopFullUnrollPass` and `JumpThreadingPass` and leaves the 10 threaded incoming edges of two `phi` nodes in pointer-address order across multi-threaded Odin builds (`modustool repeat extended_state 8`: 8 distinct LLVM IR files, 1 distinct object, 1 distinct module, 1 distinct debug object). Unoptimized `-o:none` IR and single-threaded `opt -O3` are deterministic. Working around `parts_measure` in source hides one case and leaves the cause; patching LLVM 22 defeats removing the custom LLVM build.
  2. **`X86FixupLEAs` debug-info divergence.** With `-debug-info:same-code` and the default instruction scheduler (LLVM 20+ removed `-misched-topdown`), 186 of 188 modules match byte for byte; `root` and `cryptography` diverge in one instruction of `modus__edwards25519::ge_double` (plus 7 importers in their import tables). Every pass before `x86-fixup-leas` produces identical MIR; 7 `DBG_INSTR_REF` pseudo-instructions push an `ADD64rr` past the search window of `X86FixupLEAs` ([debug_information_and_code.md](debug_information_and_code.md)). Neither `--misched-prera-direction=topdown`, `--misched-postra-direction=topdown`, `--experimental-debug-variable-locations=false`, nor `--disable-x86-lea-opt` removes it, and `llc` has no flag to disable `x86-fixup-leas`.
  3. **Mixed code speed.** Paired alternating host benchmarks (`-o:speed -microarch:x86-64`, best of 5 rounds) show gains on `image_decode` (`png_unfilter Up` SSE2 +66 %, `jpeg_idct` SSE2 +33 %, `jpeg_ycbcr` scalar +70 %), `lz4` incompressible (+56 % compress, +24 % decompress), `graphics` `blend_span` SSE2 (+10 %), and `interface` draw-table diff (+15 % to +33 %), alongside regressions on `lz4` structured binary compress (-39 %), `lex_evaluator` 500-file full/lazy workloads (-44 % / -33 %), and `interface` full-terminal draw (-5 % to -7 %).
  4. **Two source assumptions surfaced by LLVM 22.1.8** (both clean to fix when the switch lands): `text_rendering` `lam_alef_of` triggers a pointer lookup table in `.data.rel.ro` (refused by library modules `text_rendering` and `drawing`) unless it loads by integer index; `hall_of_fame` `portraits_prepare` constant-folds its `#load` slice length check and eliminates `Portrait_Refused`, so compile-time `#assert` checks on `#load(..., string)` replace that runtime fact.
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

- Move to an LLVM release that fixes both the `LoopSimplifyPass` phi-operand nondeterminism and the `X86FixupLEAs` debug-instruction search window, so the flake builds no LLVM of its own and passes all reproducibility and `-debug-info:same-code` checks (the entry "LLVM 22" of `ROADMAP.md`).
