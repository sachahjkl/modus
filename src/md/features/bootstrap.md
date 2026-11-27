# The bootstrap

Each module of the system is the output of a recipe ([recipes.md](recipes.md)). Each recipe names a builder, and each builder is the output of another recipe. The bootstrap is where that chain ends: the first builder, which no recipe made. This file states where the chain of modus ends today, where it is to end, and how a machine proves each step.

The terms Bootstrap seed and Self-hosting are in [`docs/glossary/code.md`](../../../docs/glossary/code.md).

## Purpose

A recipe proves that an output follows from its inputs and its builder. It does not prove that the builder is honest: a compiler with a fault, or a planted one, gives an output that matches its recipe. The answer of stage0 and live-bootstrap is a chain that starts from a seed small enough that a reader checks it byte by byte, and builds every compiler from source after it. modus takes the same answer, and the recipes of [recipes.md](recipes.md) make each arrow of the chain a value that a machine can build again.

## Constraints

- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "11. Reproducible system": a build is deterministic, and its output is named by its hash.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "Objective", rule 2: reuse proven software where it fits. stage0 and live-bootstrap exist and are proven.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "Objective", rule 3: a foreign system runs whole inside a guest. A chain of Linux tools runs in the guest builder, never as a layer of the system.
- **Today the build runs on a Linux host**, with the compiler of the flake: a fork of Odin and LLVM 18 with one upstream commit ([infrastructure/llvm_of_the_build.md](../infrastructure/llvm_of_the_build.md)). No program of modus writes a module file yet ([first_compiler.md](first_compiler.md)).

## The chosen form

### Self-hosting of the tool

`modustool` builds `modustool`:

1. The current tool builds the source of `tools/modustool` into an isolated directory `stage1/modustool` (N₁).
2. `stage1/modustool` builds the same source into a second isolated directory `stage2/modustool` (N₂) with identical deterministic flags (`-use-single-module`, `-source-code-locations:filename`, `-define:TOOL_BUILDS_ITSELF=false`, `-Wl,--build-id=none`, and `NIX_LDFLAGS` cleared).
3. The check compares the BLAKE3 hashes of both binaries (H₁ == H₂) and reports the exact byte offset of the first divergence if they differ.

The compiler of both builds is the compiler of the flake. So the check proves that the steps of the tool are a function of its source, not of the tool that ran them or the directory that staged them. It does not prove the compiler; the chain below does. The command is `modustool self-host` ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The self-hosting check").

### The self-hosting of the C compiler

`modustool c-self-host` proves that `chibicc` builds itself through the assembler of modus ([c_compiler.md](c_compiler.md), [assembler.md](assembler.md)):

1. **Stage 0.** clang compiles the C files of the outside source of `chibicc` (its sources with the eight patches, the entry `compile.c`, the thin libc and the table of its include files) with the flags of a module, and the tool links and converts them as a module, with the one export `compile_record_at`.
2. **Stage 1.** Stage 0 compiles each C source of that folder and `self_host/bytes.c`, 14 sources, each into one assembly unit. The texts, then `self_host/jump.s`, are one text; the assembler of modus writes the module of stage 1.
3. **Stage 2.** Stage 1 compiles the same 14 sources, and the assembler writes the module of stage 2 of their texts.
4. **The check.** Stage 1 gives the text of stage 0 for each source, and `blake3(stage 1) == blake3(stage 2)`. When two texts or the two modules differ, the command names the first source and the first byte.

The tool runs each stage on the host: for each source, a copy of the segments of the module in fresh memory, rebased at its place, and one call of its export with the record of `compile.c`. The C part calls no procedure of the host: its files are the table of the record, and its memory is an arena of the tool that a procedure of the record gives. The host test `chibicc_builds_itself_to_the_same_bytes` (`tools/modustool/build/c_self_host_test.odin`) runs the same chain, and first gives stage 0 a source that it must refuse, and two units that the assembler must refuse as one program.

- **Why stage 0 is a module too.** The same loader runs the three stages, so a difference between stage 0 and stage 1 is a difference of the compilers, not of the ways they were run. Stage 0 is the C part of the module `c_compiler`, built by the same steps.
- **Why the texts of stage 0 and of stage 1 must be equal.** The two are the same source of `chibicc`, one compiled by clang and one by `chibicc`. A different text names a fault of `chibicc`, of the thin libc or of the assembler at its first byte, before the hashes of the modules say only that they differ.
- **Why on the host first, then live on modus.** Host `modustool c-self-host` verified the chain before `c_compiler` exported `compile_unit` and before `assemble` doubled its workspace past 128 KiB and exported `assemble_program`. Now the machine test part `bootstrap` (`bootstrap_probe`, `tools/modustool/machine/bootstrap_scenario.odin`) runs the whole `chibicc` self-hosting chain live on modus under QEMU: Stage 0 compiles each of the 14 C sources in a fresh zero-grant `No_Clock` call host of `c_compiler` via `compile_unit`, `assemble.assemble_program` joins the 14 assembly units and `self_host/jump.s` into Stage 1, `bootstrap_probe` loads Stage 1 directly via `system.module_space_load` (strict W^X), checks refusal through `jump.s` (`thin_libc_jump`), compiles the same 14 sources through Stage 1's `compile_record_at` asserting byte-for-byte text equality with Stage 0, assembles Stage 2 via `assemble.assemble_program`, verifies `blake3(stage 1) == blake3(stage 2)`, and matches the exact BLAKE3 hash computed on the host by `modustool c-self-host`. The same machine test loads and runs the compiled freestanding C library modules `sqlite` (3.54.1), `lua` (5.4.7), and `zstd` (1.5.7) live inside modus via `system.module_space_load`, checking module hashes, refusal edges, SQL queries with `PRAGMA integrity_check`, Lua scripts with zero heap leak, and zstd compression frame BLAKE3 hash equality against the host.

### Stage-by-stage chain verification and C-world validation

Each bootstrap chain is expressed as a directed acyclic graph of typed stages backed by `plans_recipes.Recipe_Spec` and, for guest stages, `guest_builder.Guest_Build_Spec`:

- **C compiler self-host chain**: host-built `chibicc` seed → Stage 1 (`chibicc` compiles `chibicc` sources) → Stage 2 (Stage 1 compiles the same sources again), with the fixed-point invariant `blake3(stage1) == blake3(stage2)`.
- **Seed bootstrap chain**: `hex0` (~500-byte auditable seed) → `stage0-posix` → `mescc` → `tcc` → `gcc` → `LLVM 18` → `odin` fork → `modustool`, comparing the final output hash against the host build.
- **C-world validation recipes**: deterministic recipe descriptors, language-neutral `module.manifest` declarations, and validation test vectors for SQLite, Lua, and zstd compiled into freestanding `.modus` modules through the `ET_REL` conversion pipeline.

A pure verifier (`bootstrap_chain_verify` in `tools/modustool/build/bootstrap.odin`) enforces acyclic topological order, cryptographic linkage from each upstream stage's output hash to downstream builder and input hashes, zero network, read-only inputs, frozen epoch clock, and fixed-point equality.

### The bootstrap from a seed

The chain of live-bootstrap, extended to the compiler of the system:

hex0 (about 500 bytes) → M1 assembler → M2-Planet → mes → tcc → gcc 4 → gcc → LLVM 18 with the commit of the build → the Odin fork of the flake → `modustool` → modus.

Each arrow is a recipe. Its builder is the stage before it, its inputs are the source of the next stage by hash, and its output is a tree. The bootstrap seed is the one object of the chain that no recipe made.

### Three tiers

1. **Today: the host build.** The flake builds the system on a Linux host. The release workflow publishes the realisations of its outputs to the object cache, signed by the publisher of the system. A machine of modus then takes each module with its realisation.
2. **The objective: live-bootstrap in the guest builder.** The chain runs in the guest builder of [recipes.md](recipes.md), each stage as a recipe, from the seed to the Odin fork. The outputs of tier 2 and of tier 1 are compared: the same hashes prove that the host compiler of tier 1 added nothing.
3. **Native.** The seed and the first stages run as modus modules, with no guest: the module file writer, the assembler and the C compiler of [first_compiler.md](first_compiler.md) are these first stages. A full native chain to LLVM is not decided.

## The frequent tasks

| Task | Expression |
|---|---|
| Check that the tool builds itself to the same bytes | `recipes.build(modus.tool_self_check)` |
| Build the compiler from the seed | `recipes.build(catalog.bootstrap.odin, substitution = { mode = .Build_Only })` |
| Compare the compiler of the host with the compiler of the seed | `recipes.build(catalog.odin, substitution = { mode = .Verify })` |

## The refused forms

- **A binary compiler as the trusted root.** The trust then rests on bytes that no reader checks. The bootstrap seed is small enough to read.
- **A layer of Linux in the system to run the chain.** Against the rule of foreign systems ([foreign_systems.md](foreign_systems.md)). The chain runs in a guest, which holds only what its process was given.
- **A chain of our own from the seed to C.** stage0 and live-bootstrap exist and are proven; a second chain is the same work again. Tier 3 takes their structure, not a new design.
- **The self-hosting check as the proof of the compiler.** It proves the steps of the tool only.

## Subtle points and hazards

- **The seed of modus is larger than hex0.** A module file has a header and tables ([`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "1. The module file"). In tier 3, the reader of the seed reads the module format too, and the loader that maps it.
- **Tier 2 trusts the guest.** The Linux kernel of the guest builder runs the chain; its image is an object by hash, and its own recipe comes from tier 1. Tier 2 removes the trust of the host compiler, not the trust of the guest kernel. The guest kernel cannot change an output in silence: the stages of the chain check each other by comparison.
- **The licenses of the chain.** stage0, mes and gcc are under licenses of the GNU family. The system does not ship them: they are inputs of recipes, fetched by hash, and only their outputs enter a module. The reuse list names a work that the system ships or copies ([infrastructure/reuse_list.md](../infrastructure/reuse_list.md)).
- **LLVM 18 with one commit.** The chain must build the same LLVM as the flake, with the same commit, or the comparison of tier 2 with tier 1 fails for a reason that is not a fault.

## Open questions

- **Where tier 2 stops**: at the Odin fork, or past it, at each module of the system.
- **Which stages of tier 3 come native**, past the assembler and the C compiler.

## State

Built: the deterministic `modustool self-host` command, bootstrap verification harness (`tools/modustool/build/bootstrap.odin` and `tools/modustool/build/bootstrap_test.odin`), and canonical reproducible recipe catalog (`tools/modustool/build/bootstrap_recipes.odin` and `tools/modustool/build/bootstrap_recipes_test.odin`). `modustool self-host` compiles `tools/modustool` in two isolated staging directories (`stage1/modustool` builds `stage2/modustool`) and verifies exact BLAKE3 fixed-point equality (`H₁ == H₂`) or reports the first diverging byte offset. The canonical recipe catalog defines validated `plans_recipes.Recipe_Spec` and `guest_builder.Guest_Build_Spec` entries for `chibicc_stage1` and `chibicc_stage2` (with Stage 1 == Stage 2 hash verification), `sqlite` (amalgamation build plus self-test recipe), `lua` (Lua VM build plus test suite recipe), `zstd` (codec build plus round-trip verification recipe), and `live_bootstrap_chain` (`hex0` → `M2-Planet` → `mes` → `tcc` → `gcc` → `odin` in verified topological order with deterministic `recipe_hash` stability), alongside end-to-end host tests proving bit-for-bit identical BLAKE3 hashes for both the native x86-64 assembler (`internal:assemble/assembler`) and multi-function freestanding C + x86-64 assembly `ET_REL` → `.modus` conversion.

Built also: `modustool c-self-host` and its host test: `chibicc` built by clang compiles the 14 C sources of `chibicc`, the assembler of modus makes stage 1 of their texts with no refusal, stage 1 gives the same texts, and stage 1 and stage 2 have one BLAKE3 hash. Built also: `chibicc`-compiled upstream C libraries (`tools/modustool/build/c_world_chibicc.odin`, `modustool c-self-host --libraries`, and `chibicc_compiles_upstream_c_libraries_and_refuses_bad_inputs`): self-hosted Stage 1 `chibicc` plus the native modus x86-64 assembler (`internal:assemble/assembler`) compile upstream Lua 5.4.7 (32 units, 850,409 bytes, verified with `fib(10)`, `pcall`/`setjmp`/`longjmp`, `math.sqrt`, `utf8.len`, syntax-error refusal, and zero heap leak), zstd 1.5.7 (29 units, 1,944,989 bytes, verified lossless compression/decompression with compressed-frame BLAKE3 hash equal to host clang-built zstd), and SQLite 3.54.1 (6 units, 9,411,617 bytes, verified `version_number == 3054001`, `CREATE`/`INSERT`/`SELECT SUM`, and `PRAGMA integrity_check == "ok"`) with no host clang or `ld.lld`. Built also: multi-unit C recipe support in `src/modules/system/c_builder` (`assembly`, `exports`, `headers`, `units`) and `bootstrap_chibicc_c_builder_recipe_make` (`tools/modustool/build/tier2_guest_bootstrap.odin`) constructing canonical `plans_recipes.Recipe_Spec` records for `chibicc` Stage 1 and Stage 2. Built also: executable Tier 2 stage0 seed and chained guest recipes (`tools/modustool/build/tier2_guest_bootstrap.odin` and `tools/modustool/build/tier2_guest_bootstrap_test.odin`): an auditable 262-byte x86-64 Linux static ELF `hex0` seed (`TIER2_HEX0_X86_64_SOURCE`) verified on Linux x86-64 to self-assemble bit-for-bit (`blake3(seed) == blake3(stage1)`) and assemble a 191-byte `catm` ELF (`TIER2_CATM_X86_64_SOURCE`) that streams arbitrary payloads losslessly, packaged by `tier2_guest_bootstrap_make` into chained Stage 1 (`hex0_self_host`) → Stage 2 (`stage0_catm`) `guest_builder` `Recipe_Spec` + `Guest_Build_Spec` bundles with read-only inputs, zero network, frozen epoch clock 0, and deterministic `MODTREE1` output hashes. Built also: live QEMU execution in the machine test part `bootstrap` (`src/modules/tests/bootstrap_probe`, `tools/modustool/machine/bootstrap_scenario.odin`), which executes the full `chibicc` Stage 0 → Stage 1 → Stage 2 self-host inside modus through `c_compiler.compile_unit`, `assemble.assemble_program`, and `system.module_space_load` matching the exact host `modustool c-self-host` BLAKE3 hash, and loads and validates freestanding `sqlite`, `lua`, and `zstd` modules live on modus; and live single-stage Linux guest execution in `guest_build` (`tools/modustool/machine/guest_build_scenario.odin`). Left: publishing signed Tier 1 realisations to the object cache, pinning upstream source archives in `flake.nix` for `stage0-posix`/`M2-Planet`, `mes`, and `tcc`, executing the multi-hour downstream Tier 2 chain (`M2-Planet` → `mes` → `tcc` → `gcc` → `LLVM 18` → `Odin` fork) inside `guest_builder` under QEMU to reproduce the host Odin compiler hash, and running the multi-unit `c_builder` `chibicc` recipes end-to-end inside a live QEMU `recipes` service test.
