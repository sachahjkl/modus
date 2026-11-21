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

- **The package** `internal:assemble/assembler` turns a text into a `Module_Parts` of the module file writer. It has no kernel operation call and no allocator: its workspace is a record of fixed tables that the caller gives. Its host tests run each encoding and each refusal.
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
| `add`, `sub`, `cmp`, `and`, `or`, `xor` | the forms of `mov` without a 64-bit immediate; an 8-bit operand uses `80`, a 16/32/64-bit immediate of one signed byte uses `83`, else `81` |
| `test` | register to register, register and memory in either order, immediate to register or memory (`F6 /0`, `F7 /0`) |
| `imul` | 1-operand `r/m` (`F6 /5`, `F7 /5`); 2-operand `r/m` to a 16/32/64-bit register (`0F AF /r`); 2-operand and 3-operand immediate forms (`6B`, `69`) |
| `idiv`, `div`, `neg`, `not`, `inc`, `dec` | a register or memory operand of 8, 16, 32 or 64 bits |
| `shl`, `sal`, `shr`, `sar` | 1-operand shift by 1 (`D0`, `D1`), 2-operand by `%cl` (`D2`, `D3`), or 2-operand by an unsigned 8-bit immediate (`D0`/`D1` for `$1`, else `C0`/`C1`) |
| `lea` | memory (base, scaled index or `%rip`-relative) to a 64-bit register |
| `movsbw`, `movsbl`, `movsbq`, `movswl`, `movswq`, `movslq`, `movsxd`, `movsb`, `movsw`, `movsx` | sign-extending move from a smaller register or memory operand to a wider register (`0F BE`, `0F BF`, `REX.W 63`) |
| `movzbw`, `movzbl`, `movzbq`, `movzwl`, `movzwq`, `movzb`, `movzw`, `movzx` | zero-extending move from an 8- or 16-bit register or memory operand to a wider register (`0F B6`, `0F B7`) |
| `cbw`, `cwtl`/`cwde`, `cltq`/`cdqe`, `cwd`, `cdq`/`cltd`, `cqo`/`cqto` | zero-operand sign extensions of `%al`/`%ax`/`%eax`/`%rax` |
| `stosb`, `rep stosb` | zero-operand byte store (`AA`, `F3 AA`), used by `chibicc` to zero local storage |
| `push`, `pop` | a 64-bit register; `push` also a signed 8- or 32-bit immediate |
| `jmp`, `call` | a direct label of the code (`E9`, `E8` with 32-bit displacement), or an indirect 64-bit register or memory operand `*reg` / `*mem` (`FF /4`, `FF /2`) |
| the 16 conditional jumps (`jo` … `jg` and standard aliases) | a label of the code, with a displacement of 32 bits (`0F 80+cc`) |
| the 16 conditional byte sets (`seto` … `setg` and standard aliases) | an 8-bit register or memory operand (`0F 90+cc /0`) |
| `ret` | none |

The sizes are 8, 16, 32 and 64 bits (suffixes `b`, `w`, `l` and `q`), across all 16 general registers including `%spl`/`%bpl`/`%sil`/`%dil` (explicit REX byte `0x40`) and `%ah`/`%ch`/`%dh`/`%bh` (which refuse any instruction that needs a REX byte). A memory operand is a displacement of 32 bits with a 64-bit base register, a scaled index `disp(base, index, scale)` or `disp(, index, scale)` with scale 1, 2, 4 or 8 (encoded through SIB, refusing `%rsp` as index while allowing `%r12`), or `%rip` with a number or a label. The encoding of each form is one: the assembler never chooses a shorter jump by the place of a label, so it reads the text in one pass and writes each displacement of a label at the end.

### The refusals

The package refuses each text that it does not assemble whole, with a `Refusal_Record`: a member of the enum `Refusal`, the line and the column of its first byte (both from 1), its offset in the text, and a value. The list is the enum; its edges:

- an empty text, a text past 1 MiB, a line past 1024 bytes, a control byte, a byte past ASCII outside a comment;
- an unknown mnemonic, register, section, directive or type;
- a form that the subset does not have (`mov` from memory to memory, `push` of memory, an absolute address, `%rsp` as an index register, a scale other than 1/2/4/8, `%ah`/`%ch`/`%dh`/`%bh` combined with any REX prefix, indirect `*` outside `call`/`jmp`);
- an operand of the wrong size (`mov %eax, %rbx`, `push %eax`, `sete %eax`, `imulb %al, %bl`, `movzx %eax, %rax`), and a size that no operand gives (`mov $1, (%rax)`, `not (%rax)`, `movzx (%rax), %eax`);
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
- **A call of an import through an import slot.** It is in the design of [first_compiler.md](first_compiler.md); the first subset refuses a label that the text does not define.
- **The module through the store `module_files` and `start_from_disk`.** That path starts a process at its entry; a console calls no export of a disk process. It also needs the module file service to write the store from the console, a path that [processes_from_a_disk.md](processes_from_a_disk.md) refuses ("The console writes the store `module_files` through `open_store`").
- **`load` from memory.** The module would run with every handle of the console.
- **A new error kind for a refusal of the text.** Five readers switch on each kind. `Bad_Byte` names the byte where the refusal is, and the log line names the refusal.

## Subtle points

- **The text is copied first.** In an isolated call the text is in the call region, which the caller can change during the call. The labels are views of the text, so the module copies it once and reads the copy only.
- **A `%rip` displacement counts from the end of the instruction.** In `movq $1, x(%rip)` the immediate comes after the displacement; the assembler writes each displacement of a label once the whole instruction is placed.
- **A 32-bit immediate of an `add`.** `addl $0xFFFFFFFF, %eax` is `-1` for the processor: the assembler takes the range -2³¹ to 2³² − 1 for a 32-bit operand, and writes the value in its 32 bits, so the short form `83` takes it.
- **`(%rbp)` and `(%r13)`** (alone or with an index) have no form with no displacement: the assembler writes `mod = 01` and a displacement of one byte 0. **`(%rsp)` and `(%r12)`** alone need the SIB byte `0x24`. A scaled index with no base (`disp(, index, scale)`) writes `mod = 00`, `rm = 4`, `SIB.base = 5`, and a 4-byte displacement.
- **`%spl`, `%bpl`, `%sil`, `%dil` versus `%ah`, `%ch`, `%dh`, `%bh`.** The uniform low-byte registers emit a REX prefix (`0x40` even with no W/R/X/B bits). The legacy high-byte registers refuse any instruction that needs a REX prefix.
- **The name of a module from memory lives in its sandbox.** No file of the boot image holds it, so the entry of the console that names the module is a view of the sandbox, and `unload` sets the sandbox to zero. The record of `unload` takes the name from its argument.
- **The zero bytes of a section are not stored.** `zero` adds to the extent of the section and writes no byte, so a test reaches a label 2 GiB away with no memory of 2 GiB.

## State

Built: the package with its host tests (8/16/32/64-bit moves, ALU, bitwise, `test`, `imul`, `idiv`, `div`, `neg`, `not`, `inc`, `dec`, shifts, `setcc`, sign/zero-extending moves, zero-operand sign extensions, `rep stosb`, scaled indexed SIB addressing, direct and indirect `call`/`jmp`, and end-to-end execution of `chibicc` output for factorial, recursive Fibonacci, signed/unsigned division and modulo, comparisons, bitwise operations, and byte/short arrays), the module `assemble` in the boot image, the command `isolate_memory` of the console, and the step of the main machine test. Left: the export `build` with the store "out", a call of an import through an import slot, floating-point SSE instructions, numeric local labels (`1:` / `1f` / `1b`), atomic instructions (`lock cmpxchg`, `xchg`), a `quad` of a label with a rebase, and the debug object of an assembled module.
