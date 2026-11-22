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

Left: publishing signed Tier 1 realisations to the object cache, executing the full Tier 2 live-bootstrap chain inside the Linux guest builder, running the `chibicc` self-host recipe natively inside modus, and running the full upstream SQLite, Lua, and zstd test suites inside modus.
