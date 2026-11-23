# The assembler

The assembler is the first program of modus that writes a program: it reads a text of x86-64 assembly and gives the parts of a module file, which the module file writer writes. It is the step "2. An assembler module" of [first_compiler.md](first_compiler.md).

The terms Assembler, Module from memory, Assembly unit and Global label are in [`docs/glossary/code.md`](../../../docs/glossary/code.md). The guide is [`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "The assembler".

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

- **The package** `internal:assemble/assembler` turns a text into a `Module_Parts` of the module file writer. It has no kernel operation call and no allocator: its workspace is a record of slices of memory that the caller gives (`workspace_make`), and their lengths are the bounds of a text. Its host tests run each encoding and each refusal.
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
| `quad 7, table + 16, 1f` | 8 bytes for each value: a number, or a label with an optional `+` or `-` and a number, which gives its address in the module and one rebase |
| `align 16` | Moves the place of the section to a multiple of a power of two, 1 to 4096: zero bytes in the data, `nop` bytes in the code |
| `unit` | Starts the next assembly unit, in the section code: a label stays in its unit unless a `global` names it |
| `global name` | Makes the label `name` of the unit a global label, which each other unit that does not define the name reaches |

A label is a name and `:` at the start of a statement. A numeric local label (`docs/glossary/code.md`, "Numeric local label") is one digit and `:`; `Nf` names the next definition of the digit after the operand, and `Nb` the last one before it. A statement ends at a new line or at `;`, so a whole program is one line of the console. `#` starts a comment to the end of the line.

- **Why numeric local labels.** `chibicc` writes `1:`, `jmp 1b` and `je 1f` inside the templates of `alloca`, of `lock cmpxchg` and of the conversion of an `unsigned long` to a floating type, where a unique name needs a counter in each template. The assembler keeps, for each digit, the count of its definitions so far: `Nb` names the last one, and `Nf` the next one, which a definition later places. A label of two digits is refused: no emitter of the subset writes one.
- **Why `align`.** The compiler of a unit does not know where its data starts in the text of a program: the data of each unit follows the data of the unit before it. The section data starts on a page, so an alignment of a page or less is exact in memory.
- **Why the directives are of modus.** A directive of the GNU assembler names a concept of ELF (a symbol binding, a section by name, a relocation type). The module format has none of them, and it needs the types of an export, which no directive of the GNU assembler gives.

### The units of a program

A program of several C sources is one text of the assembler. The text of each source is one assembly unit, which `unit` starts, and the units follow each other in the text. A label belongs to its unit. `global name` makes a label of its unit a global label. Once the text is read, each label that a unit names and does not define takes the place of the global label of that name. An export names a label of its unit, or a global label.

- **Why in the assembler, and not in a linker.** The module format has one segment of code and one of data, and no object file. A program that joins objects would need a format of objects of its own. The assembler already places each label at the end of its one pass: a unit adds one key to the table of names.
- **Why the table of names is a hash table.** The text of `chibicc` that compiles itself has 6928 labels and 8505 operands that name a label: a search in the list of the labels for each name costs about 59 million compares of names. The table has `LABEL_SLOTS_PER_LABEL`, 4, slots for each label. A global label has a second slot, under the key `GLOBAL_UNIT`, so the table stays at most half full, and each search ends at an empty slot. A numeric local label has one slot for its digit and its order.
- **What it refuses.** A name that two units make global (`Global_Twice`, with the line of the first `global` as the value), a global name that no unit defines, a label of another unit that no `global` names (`Label_Not_Defined` at the first operand that names it), `global` of a digit, and words after `unit`.

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
| `ud2` | none: the trap (`0F 0B`) of a C program that must not go on |
| `xchg` | the accumulator and a register of 16, 32 or 64 bits in the short form `90+r`; else a register with a register or memory (`86`, `87`) |
| `cmpxchg`, `lock cmpxchg` | a register into memory or, with no `lock`, into a register (`0F B0`, `0F B1`; `lock` is `F0`) |
| `movss`, `movsd`, `movaps`, `movapd` | `%xmm` or memory to `%xmm` (`F3`/`F2`/none/`66` `0F 10`, `0F 28`), `%xmm` to memory (`0F 11`, `0F 29`) |
| `movq` | a 64-bit register to `%xmm` (`66 REX.W 0F 6E`), `%xmm` to a 64-bit register (`66 REX.W 0F 7E`), `%xmm` or memory to `%xmm` (`F3 0F 7E`), `%xmm` to memory (`66 0F D6`) |
| `addss`, `addsd`, `subss`, `subsd`, `mulss`, `mulsd`, `divss`, `divsd`, `sqrtss`, `sqrtsd`, `andps`, `andpd`, `orps`, `orpd`, `xorps`, `xorpd`, `pxor`, `ucomiss`, `ucomisd`, `comiss`, `comisd`, `cvtss2sd`, `cvtsd2ss` | `%xmm` or memory to `%xmm`: the prefix of the form, then `0F` and one byte |
| `cvtsi2ss`, `cvtsi2sd` and the suffixes `l`, `q` | a 32- or 64-bit register or memory to `%xmm` (`F3`/`F2` `0F 2A`, `REX.W` for 64 bits) |
| `cvttss2si`, `cvttsd2si` and the suffixes `l`, `q` | `%xmm` or memory to a 32- or 64-bit register (`F3`/`F2` `0F 2C`, `REX.W` for 64 bits) |

The registers `%xmm0` to `%xmm15` go in the forms of SSE and in `movq` only: an integer form, a base and an index refuse them. A test compares the bytes of each SSE form, of `xchg` and of `cmpxchg` with the output of `llvm-mc` for the same line.

The sizes are 8, 16, 32 and 64 bits (suffixes `b`, `w`, `l` and `q`), across all 16 general registers including `%spl`/`%bpl`/`%sil`/`%dil` (explicit REX byte `0x40`) and `%ah`/`%ch`/`%dh`/`%bh` (which refuse any instruction that needs a REX byte). A memory operand is a displacement of 32 bits with a 64-bit base register, a scaled index `disp(base, index, scale)` or `disp(, index, scale)` with scale 1, 2, 4 or 8 (encoded through SIB, refusing `%rsp` as index while allowing `%r12`), or `%rip` with a number or a label. The encoding of each form is one: the assembler never chooses a shorter jump by the place of a label, so it reads the text in one pass and writes each displacement of a label at the end.

### The refusals

The package refuses each text that it does not assemble whole, with a `Refusal_Record`: a member of the enum `Refusal`, the line and the column of its first byte (both from 1), its offset in the text, and a value. The list is the enum; its edges:

- an empty text, a text past 16 MiB, a line past 1024 bytes, a control byte, a byte past ASCII outside a comment;
- an unknown mnemonic, register, section, directive or type;
- a form that the subset does not have (`mov` from memory to memory, `push` of memory, an absolute address, `%rsp` as an index register, a scale other than 1/2/4/8, `%ah`/`%ch`/`%dh`/`%bh` combined with any REX prefix, indirect `*` outside `call`/`jmp`);
- an operand of the wrong size (`mov %eax, %rbx`, `push %eax`, `sete %eax`, `imulb %al, %bl`, `movzx %eax, %rax`), and a size that no operand gives (`mov $1, (%rax)`, `not (%rax)`, `movzx (%rax), %eax`);
- an immediate past its field, a displacement past 32 bits, a byte past -128 to 255;
- a label defined twice, a label never defined (`1f` with no `1:` after it, `1b` with none before it, a label of two digits), a jump to a label of the data;
- a vector register in an integer form, a conversion with no size of its integer (`cvtsi2ss (%rax), %xmm0`), `movq` with no 64-bit general register, `lock` before another instruction than `cmpxchg`, or `lock cmpxchg` into a register;
- a `quad` of a label in the section code or off 8 bytes of the section data, or a label with its offset below 0 or past 2^63 − 1;
- an alignment that is not a power of two from 1 to 4096, a name that two units make global, `global` of a digit, words after `unit`;
- a distance past ±2 GiB between a jump or a `%rip` operand and its label;
- a section past its buffer in the workspace or past 1 TiB of extent, more labels, operands that name a label, `quad` values of a label or exports than the workspace holds;
- an export twice, a name that is not a name of the module format, more than 12 parameters;
- a text with no instruction.

The module gives a refusal as the error record `Bad_Byte` of the argument `source`, with the offset of its first byte as the value and that byte as found. The kind of the error record is a kind of the contract; the line and the column are in the line of the log.

### The bounds of the workspace

The caller gives the memory of the workspace: `workspace_make` takes a slice for the code, the data, the labels, the slots of the table of names, the operands that name a label, the `quad` values of a label and their rebases, and the exports with their parts. The lengths of the slices are the bounds of a text. The package itself takes a text of at most `TEXT_BYTES_MOST`, 256 MiB: a place holds its offset in 32 bits.

The module `assemble` takes a text of at most 256 MiB, and carves a workspace of a scale from an arena of the budget of its call host at each call (`workspace_carve`): the scale 0 has the bounds of the table below, and each scale doubles each bound. It starts at the scale whose share of text holds the text (256 KiB at the scale 0, `workspace_scale_of_text`), so a text of one source takes one assembly. A refusal of a full table gives the next scale, and a section past its buffer gives the first scale whose buffer holds it (`workspace_scale_after`); the module ends the arena, carves the larger workspace and assembles again. It stops at a text that passes, at a refusal that no table makes, at the scale 12 (512 MiB of code, more than a jump of 2 GiB reaches), or when the budget refuses the workspace: then the call fails with the error record of the budget. The workspace of the scale 0 is about 1 MiB (the `Workspace_Memory`), which a call host of 512 pages pays; the program of `chibicc` (2 MiB of text, 295 KiB of code, 6928 labels) takes the scale 3, about 8 MiB. `modustool c-self-host` gives a workspace of 2 MiB of code, 1 MiB of data, 65536 labels, 131072 operands and 1024 exports for the program of `chibicc` (docs/TOOLS.md, "The self-hosting of the C compiler").

| Bound of `Workspace_Memory`, the scale 0 | Value | What it holds |
|---|---|---|
| `UNIT_TEXT_BYTES_MOST` | 256 KiB | The share of text of the scale 0 |
| `CODE_BYTES_MOST` | 128 KiB | The code of a text of 256 KiB that `chibicc` writes: about 20 bytes of text for an instruction of about 5 bytes gives 64 KiB, and the bound doubles it |
| `DATA_BYTES_MOST` | 128 KiB | The strings and the initialized globals; `zero` does not count |
| `LABEL_CAPACITY` | 2048 | A label of `chibicc` for each 10 lines or so: the labels of each branch, of each return and of each string. The table of names has 4 slots for each |
| `REFERENCE_CAPACITY` | 4096 | An operand that names a label for each 5 lines or so: the jumps, the calls and the `%rip` operands |
| `REBASE_CAPACITY` | 2048 | A `quad` of a label: each pointer of a global initializer |
| `EXPORT_CAPACITY` | 128 | An `export` directive: a library of a program has many |

- **Why tables of the caller, and not tables of the size of the text.** The package allocates nothing and calls no kernel operation; the caller sizes the tables for its texts. A text past a bound is refused whole, with its line, so a bound costs a refusal, never a wrong file.
- **Why a scale that doubles, and not two fixed tiers.** The tiers `Unit` and `Program` held `chibicc` and refused the next program: SQLite or Lua passes a bound of a fixed tier, and each new program would need a new tier. A doubling reaches any text that the budget pays, in a count of assemblies that grows with the logarithm of the text, and the first scale from the size of the text skips the small ones.
- **Why the exports are slices of the workspace.** At 32 exports they were an array of the record; a record of thousands is a value of hundreds of KiB on the stack of the call host. As slices they scale as the other tables.
- **Why the place of a text too long is its first byte.** The length is refused before any byte is read; a place at the bound would read the text up to it.

Changed: the module had a tier of one source and a tier of a program, a text of 4 MiB, 32 exports, and a text of the package of 16 MiB.

.

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
- **What it refuses.** A name that is not a name, a size of 0 or past the memory object, a size past 64 MiB (`disk_process.FILE_BYTES_LIMIT`), a file that `module.validate` refuses, a module with an import (the boot image is the load source of a call host, and an import of a module from memory is a later step), a module loaded already.

## The refused forms

- **The export `build` with the store "out"** ([recipes.md](recipes.md), "The builder"). The design of [first_compiler.md](first_compiler.md) names it. It needs the root service to start a builder with an input store and a store "out", which is not built. The export `assemble` writes into memory that the caller gives; `build` wraps the same package when the builders exist.
- **The syntax of Intel.** The emitter of `chibicc` would change in each of its instruction lines.
- **The directives of the GNU assembler.** They name ELF; the export needs types.
- **A short jump chosen by the distance.** It needs passes until the sizes stop to change. One form for each instruction gives one pass and one displacement to write for each reference.
- **A label as an absolute address in the code** (`mov table, %rax`, `mov table(%rax), %rcx`). It needs a rebase of the code, and the code is never writable. A `%rip` operand reaches a label with no rebase, and the code stays the same at each base. A `quad` of a label in the data is the one absolute address: the data is writable at the load.
- **The names of a unit made unique by the compiler.** A prefix on each `static` name and on each `.L` label of a unit changes each line of the emitter that writes a name, and a unit written by hand, such as the jump of `exit`, needs the same prefixes. The scope of a unit is in the table of names, once.
- **A rebase table that the text writes.** A directive of rebases lets a text name a place that holds no address. The assembler records a rebase for each `quad` of a label, and for nothing else.
- **x87 instructions.** `chibicc` uses them for `long double` only; a later step adds them when a ported program needs a `long double`.
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
- **A `quad` of a label holds the offset of the label in the module**, not an address: the loader adds the base of the load (`module.rebase`). Its 8 bytes are written once the code has its size, because the data starts on the page after the code.
- **`xchg %eax, %eax` is not `90`.** In the 64-bit mode `90` is NOP and keeps the high half of `%rax`, which `xchg %eax, %eax` clears: it takes `87 C0`. `xchg %rax, %rax` is `90`, as `llvm-mc` writes it.
- **The prefix of an SSE form comes before REX.** `F3 45 0F 10` is `movss %xmm8, %xmm15`: a REX before `F3` is ignored by the processor. With `lock` and 16 bits the order is `66 F0`, as `llvm-mc` writes it.
- **A numeric local label is of the text, not of a unit.** `1f` and `1b` count the definitions of the digit in the whole text: `chibicc` writes each `1:` in the same template as its `1f` or `1b`, so no reference crosses a `unit`.
- **The buffers keep the bytes of an earlier text.** `assemble` resets the counts and the table of names, not the buffers of the sections: the gap of a `zero` or of an `align` before a byte is written with zero bytes when that byte is written.
- **The zero bytes of a section are not stored.** `zero` adds to the extent of the section and writes no byte, so a test reaches a label 2 GiB away with no memory of 2 GiB.

## State

Built: the package with its host tests (8/16/32/64-bit moves, ALU, bitwise, `test`, `imul`, `idiv`, `div`, `neg`, `not`, `inc`, `dec`, shifts, `setcc`, sign/zero-extending moves, zero-operand sign extensions, `rep stosb`, scaled indexed SIB addressing, direct and indirect `call`/`jmp`, and end-to-end execution of `chibicc` output for factorial, recursive Fibonacci, signed/unsigned division and modulo, comparisons, bitwise operations, and byte/short arrays), the module `assemble` in the boot image, the command `isolate_memory` of the console, and the step of the main machine test. Built also: the scalar SSE2 forms and `movq`, `xchg` and `lock cmpxchg`, numeric local labels, and `quad` with the rebases of its labels, with host tests that run `chibicc` output for tables of function pointers and of strings, `float` and `double` arithmetic and conversions, and the atomic builtins. Built also: the units of a program (`unit`, `global`), `align`, `ud2`, the workspace of the memory of the caller and the hash table of the names, with host tests of each and of each refusal; the text of the 14 sources of `chibicc` assembles with no refusal, into the module of stage 1 of the self-hosting of the C compiler ([bootstrap.md](bootstrap.md), "The self-hosting of the C compiler"). Left: the export `build` with the store "out", a call of an import through an import slot, x87 instructions, and the debug object of an assembled module.
