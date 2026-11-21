# The first compiler in modus

No program of modus writes a module file today: the modus tool writes each one, on the host. This file states the path to the first programs of modus that write modules, in five steps. Each step is also a stage of the native tier of the bootstrap ([bootstrap.md](bootstrap.md), "Three tiers").

The terms Module file writer and Builder are in [`docs/glossary/code.md`](../../../docs/glossary/code.md).

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

A contract package, `modus:contract/module_file_writer`, writes a valid module file from its parts. Two bodies of code compile it in: the tool and the assembler module. It holds no kernel operation call and no allocator: `file_size_needed` gives the size of the file, and `write` writes into memory that the caller gives, or gives that size when the memory is too small. The guide: [`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "The module file writer".

What moved out of `tools/modustool/build/convert.odin`: the layout of the file (the header with the entry and the memory size, the table directory, the alignment of each table, the data of each segment on its own pages with its zero bytes at the end not stored); the tables `Segments`, `Imports`, `Import_Slots`, `Exports`, `Rebases`, `Functions`, `Records`, `Fields`, `Facts`, `Own_Hash`, `Strings`, `Documentation` and `Budget`; the encoding of the rebases; `segment_flags_after_the_relocations`; the records `Record_Description` and `Field_Description`, which the tool now names; and the last check with `module.validate`. The tables `Record_Outputs` and `Record_Inputs` of the format version 5 moved too, with the place of each variable, their refusals and the last check with `module.record_streams_check` ([module_outputs.md](module_outputs.md), "The declaration in the module"): the tool reads the streams from the sources and the places from the symbols of the linked file, and the assembler gives its own.

What stays in the tool:

- The read of the linked file of `lld` (`elf.odin`, and the part of `convert` that maps each ELF segment, section, symbol and relocation to a segment, an export, an import slot or a rebase, and finds the symbol of the own-hash place). ELF is the format of the host linker, not of modus.
- The description of the exports from the Odin source (`describe.odin`), which uses the parser of the core library of Odin.
- The debug object (`debug_object.odin`, `debug_information.odin`), which reads DWARF from LLVM.
- The count of the budget (`budget_count.odin`): it reads the memory size of each import from its file of the build. The writer takes the request that the count gives. An assembler that states a budget needs the count too; it moves then, with the constants of the pages of a thread that it reads from `modus:contract/operation`.
- `module_export_name`: it reads an export of a written file, it writes nothing. A program that binds an import slot by name uses `module.export_find`.

The input of the writer is one record, `Module_Parts`: the segments with their bytes and flags before the relocations, the exports with their descriptions, the import hashes, the import slots, the rebases in order, the records and their fields, the log facts in the order of their keys, the own-hash place, the documentation and the budget request. Each program that writes a module fills that record in its own way: the tool from ELF, the assembler from its labels.

The writer refuses a part with a `Refusal_Record`: a member of the enum `Refusal`, the table of the part and its index in its list. It checks the count of each list before it reads one item, so a list past its bound is refused with no read past its memory. It refuses what a loader or a reader would refuse, at the writer, where the program that made the part still knows its name: a table past its bound, a name that is not a name, an export whose record has no description, two segments that overlap, and the rest of the list in the guide. It reads the written file last with `module.validate` and the readers of the descriptions, so a file that it writes is one that each reader takes.

### 2. An assembler module

An assembler module reads a subset of x86-64 assembly and writes a module file through the module file writer. It is the first program of modus that writes a program. Its design, its syntax, its subset and its refusals are in [assembler.md](assembler.md).

- An export is a label with its type: a directive gives the name, the parameters and their types, and the result, and the assembler writes the description of the export from it.
- An import is an input of its recipe by name: a call of a symbol that the source does not define goes through an import slot of that import, which the loader writes. The first subset refuses such a call.
- Its subset is what the C compiler of step 3 emits, and nothing more at first. Its syntax is the syntax of AT&T that `chibicc` emits, with directives of modus.
- It becomes a builder when the builders exist: it exports `build`, takes the source tree as its input, and writes the module file into its store "out". Until then its export `assemble` takes the text as Bytes and writes the file into a memory object that the caller lends; the console isolates the module of that object (`isolate_memory`).

### 3. `chibicc`, ported

`chibicc` is a C11 compiler of about 9 000 lines, in one pass, that emits assembly. Its output is the input of the assembler of step 2. The module `c_compiler` replaces its `main` with the export `compile`, which takes the source as Bytes and writes the text of assembly into memory that the caller lends; the export `build` with the store "out" wraps the same entry when the builders exist. Its design, its patches and the gaps of the assembler are in [c_compiler.md](c_compiler.md).

It is chosen over TCC: its code is easier to read, and it emits assembly that the assembler of step 2 reads, so it needs no writer of its own for the module format. TCC writes machine code, so its port needs a second writer of the module format inside it.

The source of `chibicc` is an outside source ([infrastructure/outside_source.md](../infrastructure/outside_source.md)): the flake fetches it at one commit and applies the patches of the system, so it is not a source of `src/`. The module is not an outside module of [infrastructure/third_party_module.md](../infrastructure/third_party_module.md): the console isolates a module of the boot image, so the module has a row of the module table, and an Odin package in `src/modules/system/c_compiler` states its export.

### 4. A thin libc over the handles

A C program needs a C library. The thin libc gives the part of it that a compiler needs, over the handles of modus:

- no `FILE*` and no path: the input is a tree by handle, the output is a store;
- `malloc` over a growable arena of the budget of the process ([memory_without_a_bound.md](memory_without_a_bound.md)), and a `free` that ends nothing until the arena ends;
- no `printf` to a standard output: a diagnostic is a log fact or the error record of `build`.

Step 3 needs the part of it that `chibicc` calls, so that part comes with step 3, in C beside `chibicc` ([c_compiler.md](c_compiler.md), "The thin libc"). Step 4 moves it to a place that the next ported C programs share, and gives them the rest.

### 5. The guest builder

For Odin, Rust and every other compiler that is not native, the guest builder of [recipes.md](recipes.md) runs the existing tool in a Linux guest. It does not wait for the native steps; the native steps do not wait for it.

## The frequent tasks

| Task | Expression |
|---|---|
| Assemble a module | `recipes.build(catalog.assemble({ source = here() }))` |
| Compile a C program | `recipes.build(catalog.c_build({ source = here() }))` |
| Check that the C compiler builds itself to the same bytes | `recipes.build(catalog.c_build_self_check)` |

## The refused forms

- **A second writer of the module format in each program.** Two writers drift apart; a fault of one gives files that the other never writes.
- **The writer as a support package.** The tool cannot import a support package, which calls the kernel. The writer is pure, so it is a contract package.
- **A writer that allocates the file.** The code of the system has no allocator of the language (property 14). The caller asks the size first, and gives the memory.
- **Checks of the descriptions written again in the writer.** The writer reads the written file with `module.record_type`, `module.function` and `module.fact`, the checks of each reader. A second copy of those rules would drift from the readers.
- **A writer that sorts its input.** It would change a list of the caller. It refuses rebases or facts out of order, and the caller sorts.
- **TCC first.** It writes machine code, and a port needs a writer of the module format in it.
- **A full libc first.** The paths, the standard streams and the environment of a full libc are the concepts that the system removed (property 16). The thin libc grows with each port.
- **An ELF linker on modus.** The module format is the output; ELF is a format of the host.

## Subtle points and hazards

- **The tool must give the same bytes after the move.** The writer writes the tables in the order of the old conversion, and the strings in the same order. The proof is the hashes of two builds: `modustool module-hashes write` before the move, `modustool module-hashes compare` after it ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The hashes of the modules of two builds").
- **A rebase twice is refused.** The old encoder wrote a location that came twice as two words, and a loader then added the base two times. The writer refuses it (`Rebase_Not_Valid`).
- **A refusal after the write.** A record that only `module.record_type` refuses is known after the bytes are written. The writer then sets them to zero, so no part of a refused file stays in the memory of the caller.
- **A call to an import goes through an import slot.** `chibicc` emits a direct call to a symbol that it does not define. The assembler turns it into a call through the import slot of the import that exports it, because a module never patches its code (property 10).
- **The subset of the assembler is a closed set.** An instruction past it is refused with its line, never assembled in part.
- **`chibicc` never frees memory.** So a `free` that ends nothing costs it nothing; a later port that frees much needs more.

## Open questions

- **The debug object of an assembled module**: the assembler writes the lines of its labels, with a writer of the debug object format that moves out of the tool too, or none at first.

## State

Built: the module file writer, with its host tests, and the tool writes each module through it; the assembler module with its export `assemble`, its host tests and its machine step ([assembler.md](assembler.md), "State"); `chibicc` ported as the module `c_compiler` with its export `compile`, the part of the thin libc that it calls, and the machine step that compiles a C function, assembles it and calls it ([c_compiler.md](c_compiler.md), "State"). Left: the count of the budget in the writer, the export `build` of the assembler and of the compiler, the call of an import through an import slot, the instructions that `chibicc` emits past the subset of the assembler, the thin libc in a shared place for the next ported C programs, and the guest builder.
