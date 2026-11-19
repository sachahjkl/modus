# The first compiler in modus

No program of modus writes a module file today: the modus tool writes each one, on the host. This file states the path to the first programs of modus that write modules, in five steps. Each step is also a stage of the native tier of the bootstrap ([bootstrap.md](bootstrap.md), "Three tiers").

The terms are in [`docs/glossary/code.md`](../../../docs/glossary/code.md), "Module file writer", "Builder".

## Purpose

A builder of [recipes.md](recipes.md) that runs on modus must write its output as module files. A machine with no host then builds a module, and the native chain of the bootstrap has its first stages. The path starts at the smallest program that writes a program, and grows by one capability at each step.

## Constraints

- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "10. One code module": one format, which the loader checks.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "14. Memory is supplied by the caller": the code of the system has no allocator of the language.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "19. A command is a function: no text between processes": a compiler reads a source as data, and gives typed results.
- **One format, one writer.** The tool and each program of modus that writes a module use one body of code. Two writers of one format drift apart.
- **The code of the system imports `base:` and `modus:` packages only.** A writer that the tool and a module of modus share holds no call of the host.

## The chosen form

### 1. The module file writer

A contract package, `modus:contract/module_file_writer`, writes a valid module file from its parts. Two bodies of code compile it in: the tool and the assembler module. It holds no kernel operation call and no allocator: it writes into memory that the caller gives, and gives the size that the file needs when the memory is too small.

What moves out of the tool:

- From `tools/modustool/build/convert.odin`: the layout of the file (the header, the table directory, the alignment of each table, the data of each segment on its own pages with its zero bytes at the end not stored); the tables `Segments`, `Imports`, `Slots`, `Exports`, `Rebases`, `Functions`, `Records`, `Fields`, `Facts`, `Own_Hash`, `Strings`, `Documentation` and `Budget`; `encode_rebases`; `segment_flags_after_the_relocations`; `module_export_name`; and the last check with `module.validate`.
- From `tools/modustool/build/budget_count.odin`: the count of the budget that a module asks for, which is arithmetic on the parts that the source states.

What stays in the tool:

- The read of the linked file of `lld` (`elf.odin`, and the part of `convert` that maps each ELF segment, section, symbol and relocation to a segment, an export, a slot or a rebase). ELF is the format of the host linker, not of modus.
- The description of the exports from the Odin source (`describe.odin`), which uses the parser of the core library of Odin.
- The debug object (`debug_object.odin`, `debug_information.odin`), which reads DWARF from LLVM.

The input of the writer is one record of parts: the segments with their bytes and flags, the exports with their descriptions, the import hashes, the slots, the rebases, the records and their fields, the log facts, the own-hash place and the budget. Each program that writes a module fills that record in its own way: the tool from ELF, the assembler from its labels.

### 2. An assembler module

An assembler module reads a subset of x86-64 assembly and writes a module file through the module file writer. It is the first program of modus that writes a program.

- An export is a label with its type: a directive gives the name, the parameters and their types, and the result, and the assembler writes the description of the export from it.
- An import is an input of its recipe by name: a call of a symbol that the source does not define goes through a slot of that import, which the loader writes.
- Its subset is what the C compiler of step 3 emits, and nothing more at first.
- It is a builder: it exports `build`, takes the source tree as its input, and writes the module file into its store "out".

### 3. `chibicc`, ported

`chibicc` is a C11 compiler of about 10 000 lines, in one pass, that emits assembly. Its output is the input of the assembler of step 2. The port replaces its `main` with the export `build`, and its reads and writes of files with the store of its input and the store "out".

It is chosen over TCC: its code is easier to read, and it emits assembly that the assembler of step 2 reads, so it needs no writer of its own for the module format. TCC writes machine code, so its port needs a second writer of the module format inside it.

`chibicc` is an outside module ([infrastructure/third_party_module.md](../infrastructure/third_party_module.md)): its source is not a source of `src/`.

### 4. A thin libc over the handles

A C program needs a C library. The thin libc gives the part of it that a compiler needs, over the handles of modus:

- no `FILE*` and no path: the input is a tree by handle, the output is a store;
- `malloc` over a growable arena of the budget of the process ([memory_without_a_bound.md](memory_without_a_bound.md)), and a `free` that ends nothing until the arena ends;
- no `printf` to a standard output: a diagnostic is a log fact or the error record of `build`.

Step 3 needs the part of it that `chibicc` calls, so that part comes with step 3. Step 4 gives the rest to the next ported C programs.

### 5. The guest builder

For Odin, Rust and every other compiler that is not native, the guest builder of [recipes.md](recipes.md) runs the existing tool in a Linux guest. It does not wait for the native steps; the native steps do not wait for it.

## The frequent tasks

| Task | Expression |
|---|---|
| Assemble a module | `build(catalog.assemble({ source = here() }))` |
| Compile a C program | `build(catalog.c_build({ source = here() }))` |
| Check that the C compiler builds itself to the same bytes | `build(catalog.c_build_self_check)` |

## The refused forms

- **A second writer of the module format in each program.** Two writers drift apart; a fault of one gives files that the other never writes.
- **The writer as a support package.** The tool cannot import a support package, which calls the kernel. The writer is pure, so it is a contract package.
- **TCC first.** It writes machine code, and a port needs a writer of the module format in it.
- **A full libc first.** The paths, the standard streams and the environment of a full libc are the concepts that the system removed (property 16). The thin libc grows with each port.
- **An ELF linker on modus.** The module format is the output; ELF is a format of the host.

## Subtle points and hazards

- **The tool must give the same bytes after the move.** The writer that moves out of `convert.odin` is the same code. The comparison of the builds of `modustool check` proves it: no module changes its hash.
- **A call to an import goes through a slot.** `chibicc` emits a direct call to a symbol that it does not define. The assembler turns it into a call through the slot of the import that exports it, because a module never patches its code (property 10).
- **The subset of the assembler is a closed set.** An instruction past it is refused with its line, never assembled in part.
- **`chibicc` never frees memory.** So a `free` that ends nothing costs it nothing; a later port that frees much needs more.

## Open questions

- **The debug object of an assembled module**: the assembler writes the lines of its labels, with a writer of the debug object format that moves out of the tool too, or none at first.
- **The syntax of the assembler**: the AT&T syntax that `chibicc` emits, or a syntax of modus with a change of the emitter of `chibicc`.

## State

Designed, not built.
