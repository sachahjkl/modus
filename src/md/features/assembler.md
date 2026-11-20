# The assembler

The assembler is the first program of modus that writes a program: it reads a text of x86-64 assembly and gives the parts of a module file, which the module file writer writes. It is the step "2. An assembler module" of [first_compiler.md](first_compiler.md).

The terms Assembler and Module from memory are in [`docs/glossary/code.md`](../../../docs/glossary/code.md). The guide is [`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "The assembler".

## Purpose

A machine with no host makes a module, and calls it. The assembler is the smallest program that does it: each line of its input is one instruction, one label or one directive, so a reader checks each byte of the output against the text.

## Constraints

- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "10. One code module": the output is a module file, which the loader checks; the assembler has no other output format.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "14. Memory is supplied by the caller": the package allocates nothing; the caller gives the workspace and the memory of the file.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "19. A command is a function: no text between processes": the text is an argument of one export; the result is a module file, a size and an error record.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "2. Sandbox by default": a module that the assembler made runs in a call host, with no handle of its caller.
- **The input of step 3.** The subset is what `chibicc` emits for a function that adds, loops, calls and returns, and nothing more at first.

## The chosen form

### Two parts

- **The package** `modus:private/assemble/assembler` turns a text into a `Module_Parts` of the module file writer. It has no kernel operation call and no allocator: its workspace is a record of fixed tables that the caller gives. Its host tests run each encoding and each refusal.
- **The module** `assemble` (`src/modules/system/assemble`) exports `assemble(source: Bytes, file: Handle) -> Integer`. It copies the text, calls the package, asks `file_size_needed`, maps the memory object `file` that the caller lends with Read and Write, writes the file there with `write`, and gives its size. A refusal is an error record, and one line of the log with the line, the column and the sentence of the refusal.

### The syntax: AT&T

The instructions are in the syntax of AT&T: the source first, `%` before a register, `$` before an immediate, `8(%rbp)` for memory, `q` and `l` as the suffixes of a size.

- **Why.** The input of the next step is the output of `chibicc`, which is in this syntax. Its instruction lines then pass with no change of its emitter.
- **The cost.** The order of the operands is the reverse of the Intel manual, so a test compares the bytes, not the text, with the manual.

The directives are of modus, not of the GNU assembler:

| Directive | What it does |
|---|---|
| `section code`, `section data` | The section of the lines after it. `code` is the section at the start |
| `export name(a: Integer, b: Text) -> Integer` | Declares the export `name` at the label `name`, with the types of its parameters and of its result; with no `->`, the export gives nothing |
| `byte 1, 0x41, -1` | Bytes at the place of the section: each from -128 to 255 |
| `zero 4096` | Zero bytes at the place of the section: the file stores no zero byte at the end of a section |

A label is a name and `:` at the start of a statement. A statement ends at a new line or at `;`, so a whole program is one line of the console. `#` starts a comment to the end of the line.

- **Why the directives are of modus.** A directive of the GNU assembler names a concept of ELF (a symbol binding, a section by name, a relocation type). The module format has none of them, and it needs the types of an export, which no directive of the GNU assembler gives.

### The subset

| Instruction | Forms |
|---|---|
| `mov` | register to register, memory to register, register to memory, immediate to register (a 64-bit immediate with `B8+r`), immediate to memory |
| `add`, `sub`, `cmp` | the forms of `mov` but a 64-bit immediate; an immediate of one byte with `83`, else `81` |
| `lea` | memory to a 64-bit register |
| `movsxd` | a 32-bit register or memory to a 64-bit register, with its sign: the C compiler loads each `int` with it ([c_compiler.md](c_compiler.md), "The gaps of the assembler") |
| `push`, `pop` | a 64-bit register; `push` also an immediate |
| `jmp`, `call`, the 16 conditional jumps (`jo` … `jg`) | a label of the code, with a displacement of 32 bits |
| `ret` | none |

The sizes are 64 and 32 bits. A memory operand is a displacement and a base: a 64-bit register, or `%rip` with a number or a label. The encoding of each form is one: the assembler never chooses a shorter form by the place of a label, so it reads the text in one pass and writes each displacement of a label at the end.

### The refusals

The package refuses each text that it does not assemble whole, with a `Refusal_Record`: a member of the enum `Refusal`, the line and the column of its first byte (both from 1), its offset in the text, and a value. The list is the enum; its edges:

- an empty text, a text past 1 MiB, a line past 1024 bytes, a control byte, a byte past ASCII outside a comment;
- an unknown mnemonic, register, section, directive or type;
- a form that the subset does not have (`mov` from memory to memory, `push` of memory, an index register, an absolute address);
- an operand of the wrong size (`mov %eax, %rbx`, `push %eax`), and a size that no operand gives (`mov $1, (%rax)`);
- an immediate past its field, a displacement past 32 bits, a byte past -128 to 255;
- a label defined twice, a label never defined, a jump to a label of the data;
- a distance past ±2 GiB between a jump or a `%rip` operand and its label;
- a section past its capacity (64 KiB of bytes, 1 TiB of extent), past 512 labels, 2048 references or 32 exports;
- an export twice, a name that is not a name of the module format, more than 12 parameters;
- a text with no instruction.

The module gives a refusal as the error record `Bad_Byte` of the argument `source`, with the offset of its first byte as the value and that byte as found. The kind of the error record is a kind of the contract; the line and the column are in the line of the log.

## The machine step: a module from the memory of the console

The console isolates a module from memory, a module whose file is in a memory object: `isolate_memory(name, memory, size)`. It copies the `size` bytes into a memory object of its own, checks the copy with `module.validate`, computes its BLAKE3 hash, and starts a call host with the copy as its one file. The exports become commands, as after `isolate`.

```
> f = buffer(4)
> n = assemble("export add(a: Integer, b: Integer) -> Integer; add: mov %rdi, %rax; add %rsi, %rax; ret", f)
> isolate_memory("adder", f, n)
> add(2, 3)
5
```

- **Why a copy.** The memory object `f` stays with the console and the module of `assemble` can write it again; the descriptions that the commands read must not change under them.
- **Why `isolate` and not `load`.** A direct call runs the code with every handle of the console. A module that a program wrote a moment before is code that nobody checked; the call host gives it its call ring and nothing else.
- **What it refuses.** A name that is not a name, a size of 0 or past the memory object, a size past 4 MiB, a file that `module.validate` refuses, a module with an import (the boot image is the load source of a call host, and an import of a module from memory is a later step), a module loaded already.

## The refused forms

- **The export `build` with the store "out"** ([recipes.md](recipes.md), "The builder"). The design of [first_compiler.md](first_compiler.md) names it. It needs the root service to start a builder with an input store and a store "out", which is not built. The export `assemble` writes into memory that the caller gives; `build` wraps the same package when the builders exist.
- **The syntax of Intel.** The emitter of `chibicc` would change in each of its instruction lines.
- **The directives of the GNU assembler.** They name ELF; the export needs types.
- **A short jump chosen by the distance.** It needs passes until the sizes stop to change. One form for each instruction gives one pass and one displacement to write for each reference.
- **A label as an absolute address** (`mov table, %rax`, a `quad` of a label). It needs a rebase. A `%rip` operand reaches a label with no rebase, and the code stays the same at each base.
- **A call of an import through a slot.** It is in the design of [first_compiler.md](first_compiler.md); the first subset refuses a label that the text does not define.
- **The module through the store `module_files` and `start_from_disk`.** That path starts a process at its entry; a console calls no export of a disk process. It also needs the module file service to write the store from the console, a path that [processes_from_a_disk.md](processes_from_a_disk.md) refuses ("The console writes the store `module_files` through `open_store`").
- **`load` from memory.** The module would run with every handle of the console.
- **A new error kind for a refusal of the text.** Five readers switch on each kind. `Bad_Byte` names the byte where the refusal is, and the log line names the refusal.

## Subtle points

- **The text is copied first.** In an isolated call the text is in the call region, which the caller can change during the call. The labels are views of the text, so the module copies it once and reads the copy only.
- **A `%rip` displacement counts from the end of the instruction.** In `movq $1, x(%rip)` the immediate comes after the displacement; the assembler writes each displacement of a label once the whole instruction is placed.
- **A 32-bit immediate of an `add`.** `addl $0xFFFFFFFF, %eax` is `-1` for the processor: the assembler takes the range -2³¹ to 2³² − 1 for a 32-bit operand, and writes the value in its 32 bits, so the short form `83` takes it.
- **`(%rbp)` and `(%r13)`** have no form with no displacement: the assembler writes a displacement of one byte 0. **`(%rsp)` and `(%r12)`** need the byte SIB `24`.
- **The zero bytes of a section are not stored.** `zero` adds to the extent of the section and writes no byte, so a test reaches a label 2 GiB away with no memory of 2 GiB.

## State

Built: the package with its host tests, the module `assemble` in the boot image, the command `isolate_memory` of the console, the step of the main machine test, and `movsxd`, with a host test of the whole text that the C compiler writes for a function that adds. Left: the export `build` with the store "out", a call of an import through a slot, the rest of the subset that `chibicc` emits (the other sizes, the index registers, `imul`, `idiv`, the other extensions of a sign, the `set` instructions, an indirect call; the list is in [c_compiler.md](c_compiler.md), "The gaps of the assembler"), a `quad` of a label with a rebase, and the debug object of an assembled module.
