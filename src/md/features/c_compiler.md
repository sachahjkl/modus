# The C compiler: `chibicc`, ported

The module `c_compiler` compiles a C source into a text of assembly that the assembler module reads. It is the step "3. `chibicc`, ported" of [first_compiler.md](first_compiler.md), with the part of the step "4. A thin libc over the handles" that `chibicc` calls. With the assembler, a machine of modus turns a C function into a module, and calls it.

The terms C compiler and Thin libc are in [`docs/glossary/code.md`](../../../docs/glossary/code.md). The build of its C part: [../infrastructure/outside_source.md](../infrastructure/outside_source.md). The guide: [`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "The C compiler".

## Purpose

A machine with no host compiles C. The next native stages of the bootstrap ([bootstrap.md](bootstrap.md)) are C programs, and each needs a C compiler on modus first.

## Constraints

- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "19. A command is a function: no text between processes": the source is an argument of one export, and the output is bytes in memory that the caller lends.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "14. Memory is supplied by the caller": the memory of the compiler is an arena of its budget ([memory_without_a_bound.md](memory_without_a_bound.md)).
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "16. Removed concepts" and "8. No global, mutable, shared file system": no path, no standard stream.
- **The output is the input of the assembler.** Each line that the compiler writes is a line that the assembler takes, or the assembler refuses it whole, with its line and its column ([assembler.md](assembler.md), "The refusals").
- **Small patches.** The work stays `chibicc` at one commit: each change is a patch beside it, so a reader sees what the system changed.

## The chosen form

### The export

```
compile(source: Bytes, output: Handle) -> Integer
```

The Odin package `src/modules/system/c_compiler` copies the source, makes an arena of its budget, calls the C entry, maps the memory object `output` that the caller lends with Read and Write, copies the text there, and gives its bytes.

```
> t = buffer(1)
> n = compile("int add(int a, int b) { return a + b; }", t)
> f = buffer(4)
> m = assemble(bytes(t, 0, n), f)
> isolate_memory("adder", f, m)
> add(2, 3)
5
```

- **Why a text in lent memory, and not a module file.** The assembler is the one program that turns assembly into a module; the compiler writes no second writer of the module format ([first_compiler.md](first_compiler.md), "The refused forms").
- **Why not `build` with the store "out".** The builders do not exist; `compile` wraps the same C entry, as `assemble` does ([assembler.md](assembler.md), "The refused forms").

### The C entry

`main` of `chibicc` is not compiled: it parses arguments, runs other programs, and writes files. The file `src/outside/chibicc/system/compile.c` does what its function `cc1` does for one file, with no file: it gives the source to the reader of files of the thin libc under the name `source.c`, tokenizes, preprocesses, parses and generates into a memory stream, and gives the text to the Odin package. It also holds what `main.c` defined for the other files: the include path `include`, `file_exists` over the table of files, and the options (no common symbols, no `-fPIC` form).

### The patches

| Patch | What it changes, and why |
|---|---|
| `0001-headers-of-the-thin-libc.patch` | `chibicc.h` includes no header of a host program (`glob.h`, `sys/stat.h`, `sys/types.h`, `sys/wait.h`, `time.h`, `unistd.h`): only `main.c` and the date macros used them. It declares the place of an error |
| `0002-reproducible-dates.patch` | `__DATE__`, `__TIME__` and `__TIMESTAMP__` give the start of the epoch. A compiler that reads the clock gives other bytes at each run; the system has no time of a file |
| `0003-assembly-of-modus.patch` | The output is the syntax of the assembler: `section code` and `section data` in place of the sections of ELF, an `export` directive for each function that is not `static`, no `.file` and no `.loc`, data as `byte`, `quad` and `zero` lines |
| `0004-place-of-an-error.patch` | Each diagnostic with a place records the offset of that place in its file, so the error record names the byte |

### The marker of an export: each function that is not static

A C function that is not `static` has external linkage: C already says "other code calls this". So each such function becomes an export, and a `static` function stays inside the module.

- An `int` or a `long` is an `Integer`; a `void` result is no result.
- A function that is not `static` with another type of parameter or of result is refused, with the place of the type: "make it static, or give it int or long".
- **Why not an attribute.** A marker of its own would be one more word of C that only this compiler knows, and a C source of others would need a change for each export. External linkage is the marker that the language has.
- **The sign of an `int` result.** An `Integer` is 64 bits, and `add %edi, %eax` writes zero in the high half of `%rax`. The compiler writes `movsxd %eax, %rax` at the end of each export that gives an `int`, so `add(-2, 1)` gives -1.

### The data

The assembler has no alignment directive. The compiler counts the bytes of the section data that it wrote, and writes `zero` before a variable to reach its alignment: the section data starts on a page, so an offset aligned in the section is an address aligned in memory. A variable with an initializer is `byte` lines, and a `quad` line for each address that it holds (`quad add+0`, `quad numbers+8`); one with none is `zero`. The assembler records a rebase for each `quad` of a label, so a table of functions or of strings holds addresses at each base of the load. A `quad` off 8 bytes of the data (a pointer in a packed struct) is refused by the assembler with its line.

### The thin libc

It is the C library that `chibicc` calls, and nothing more, in C beside the work (`src/outside/chibicc/libc`):

| Part | Procedures |
|---|---|
| Memory | `malloc`, `calloc`, `realloc` over the arena that the Odin package gives as a procedure value; `free` ends nothing |
| Text | `memcmp`, `strlen`, `strcmp`, `strncmp`, `strncasecmp`, `strchr`, `strstr`, `strncpy`, `strdup`, `strndup`, `strtoul`, `strtold`, `strerror`, `dirname`, the classes of `ctype.h` |
| Streams | `FILE` as a memory stream: `open_memstream`, `fopen` of a name of the table of files (read only), `fread`, `fwrite`, `fputc`, `fflush`, `fclose`, `fprintf`, `vfprintf`, `printf` |
| End | `exit` returns to the C entry with `__builtin_longjmp`, and the entry gives the failure to the Odin package |

- **`copy_bytes_without_overlap` and its kin.** `memcpy`, `memmove` and `memset` are the procedures of `src/runtime/memory.asm` in each module.
- **No path.** `fopen` takes a name of the table of files: the source as `source.c`, and the include files of `chibicc` (`include/stddef.h` and the others), which the flake writes into a C table. Each other name is refused, as a file that does not exist. A mode other than `r` is refused.
- **`stderr` and `stdout`** are one memory stream of 4 KiB: the diagnostic. The Odin package writes its first line on the log when the compile fails.
- **`strtold` gives the nearest double.** The module is built with `-mlong-double-64`, so a `long double` of the thin libc is a `double`, and `strtold` rounds each text to the nearest `double`, ties to even. It reads blanks, a sign, a decimal number with its exponent `e`, a hexadecimal number after `0x` with its exponent `p`, `inf`, `infinity`, `nan` and `nan(...)`. A value past the largest `double` gives infinity and `ERANGE`; a value below the least normal `double` that is not exact gives `ERANGE` too; a text with no number gives 0 and `*end` at the text. Its design is the section "The conversion of a floating constant", below.

**Why in C, beside the work, and not in Odin under `src/library`.** `vfprintf` takes a `va_list`, which an Odin procedure cannot receive: the Odin compiler takes `#c_vararg` in a declaration of a `foreign` procedure only. One C program uses it today, and a support package of `src/library` needs two owners. The next ported C program moves the thin libc into a place that both share, with what that program adds.

### One source for each call host

`chibicc` keeps its state in static variables: the macros, the files, the counters of the labels. The module is loaded once in its call host, so a second call would see the state of the first. The first call that reaches the C entry is the only one: a later call fails with the error kind `Refused` and a line of the log, "unload the module and isolate it again". A refusal at the border of the export (an empty source, a source past its bound) does not reach the C entry, and does not count.

### The conversion of a floating constant

`strtold` computes with integers only. The decimal digits go into a decimal of at most 800 significant digits, `0.d1d2...` times a power of 10, with one flag that says that a digit that is not 0 was dropped after them. Shifts by at most 60 bits multiply or divide that decimal by a power of 2 until it is in [0.5, 1), then by 2^53, and the integer part, rounded to the nearest with ties to even, is the fraction of the `double`. A hexadecimal number keeps its first 64 bits and the same flag, and rounds them the same way. The function writes the 64 bits of the `double` itself.

- **Why integers only.** The result is then one result: it depends on no rounding mode and on no precision of a floating point unit. The one floating point step is the return of the 64 bits as a `double`.
- **Why 800 digits.** The exact value of a `double` has at most 767 significant digits, so a digit past 800 never decides a rounding: it only says that the value is above a tie, which the flag records.
- **The bound of the work.** A decimal is 819 bytes on the stack, and an exponent past 100000 gives the same infinity or zero as 100000, so no count overflows and the loop of the shifts ends.
- **A `float` constant is rounded twice.** `chibicc` keeps each floating constant as a `long double`, here a `double`, then converts it to `float`. A decimal text that lies almost exactly between two `float` values can then round to the other one. A hexadecimal text of at most 53 significant bits is exact as a `double`, so it rounds once only.
- **The test.** A host test, which compiles `text.c` with the flags of the module, compares the bits, the end and `errno` with the `strtod` of glibc for each fixed edge (signs, `.5`, `42.`, `1e308`, `1e309`, the least normal and subnormal values, ties, a text of 1000 digits, `0x` with no digit, `1e+`, `inf`, `nan`, texts with no number) and for random values: `%.17g`, `%.25e` and `%a` of random bits, the exact middle of two neighbor `double` values, that middle with a digit past it, and random digits with random exponents. An assembler host test runs the output of `chibicc` for decimal, scientific and hexadecimal constants of `double` and `float`, and compares their bits with those of the host compiler.

### The gaps of the assembler

What `chibicc` writes for a C source, and how the assembler handles it:

| Lines of `chibicc` | What the system does |
|---|---|
| `.file`, `.loc`, `.globl`, `.local`, `.text`, `.data`, `.bss`, `.type`, `.size`, `.align`, `.comm`, `.byte`, `.zero` | The patch writes the directives of modus, or nothing |
| `movsxd`/`movslq`, `movsbl`, `movsbq`, `movswl`, `movswq`, `movsbw`, `movsb`, `movsw`, `movsx`, `movzbl`, `movzbq`, `movzwl`, `movzwq`, `movzbw`, `movzb`, `movzw`, `movzx`, `cbw`, `cwtl`, `cltq`, `cwd`, `cdq`, `cqo` | Assembled, with host tests |
| `sete` and all 16 `setcc`, `test`, `imul`, `idiv`, `div`, `and`, `or`, `xor`, `not`, `neg`, `inc`, `dec`, `shl`/`sal`, `shr`, `sar`, `rep stosb`, 8- and 16-bit registers (`%al`..`%r15b`, `%ax`..`%r15w`), scaled indexed addressing, indirect `call *reg` / `jmp *reg` | Assembled, with host tests |
| `.quad label+offset` in an initializer | The patch writes `quad label+offset`; the assembler writes the address of the label in the module and records a rebase, with host tests that run tables of function pointers, of strings, and a pointer into an array |
| `movss`, `movsd`, `movq`, `addss`…`divsd`, `xorps`/`xorpd`, `pxor`, `ucomiss`/`ucomisd`, `cvtsi2ss`/`cvtsi2sd`, `cvttss2si`/`cvttsd2si`, `cvtss2sd`/`cvtsd2ss`, `%xmm0`..`%xmm15` | Assembled, with bytes compared with `llvm-mc`, and host tests that run `float` and `double` arithmetic, comparisons and conversions |
| Numeric local labels (`1:`/`1f`/`1b` in `alloca`, in the compare-and-swap and in the conversion of an `unsigned long`), `lock cmpxchg`, `xchg` | Assembled, with host tests that run the atomic builtins |
| `mov x@GOTPCREL(%rip), %rax`, a section of thread-local data | Refused by the compiler: a symbol of another module needs an import slot, and the module format has no thread-local data |
| x87 instructions (`fldt`, `fstpt`, `fucomip`), for `long double` | Not added: the assembler refuses each with its line and its column |
| A floating constant (`1.5`, `2.5e10`, `0x1.8p+1`, `1.5f`) | `chibicc` writes its bits as an immediate of `mov` into `%rax` (`%eax` for a `float`), then `movq` to `%xmm0`, with host tests that compare the bits. The comment of the line shows `?` in place of the value: `vfprintf` of the thin libc writes `?` for a floating conversion |

So the C subset that passes today covers signed and unsigned `char`, `short`, `int`, `long`, `_Bool`, `float` and `double` with their constants, pointers, local and global arrays, structs, local initializers (`rep stosb`), global initializers that hold addresses, `alloca`, the atomic builtins `__builtin_atomic_exchange` and `__builtin_compare_and_swap`, calls through a pointer to a function, comparisons, `if`/`else`, `while`, `for`, `do`, `switch`, `&&`/`||`/`!`/`?:`, `+`, `-`, `*`, `/`, `%`, bitwise `&`/`|`/`^`/`~`/`<<`/`>>`, unary `-`, and direct or recursive calls to functions in the same translation unit (`call *%r10`). Exported functions still take and return `int` or `long` (`Integer`) or `void`; `static` helper functions can take any integer, pointer, or small struct type.

## The refused forms

- **TCC.** It writes machine code, so its port needs a second writer of the module format ([first_compiler.md](first_compiler.md)).
- **The thin libc in Odin.** It cannot receive a `va_list`, and it has one owner.
- **The GNU directives in the assembler.** They name ELF ([assembler.md](assembler.md), "The refused forms"); the compiler writes the directives of modus at the one place where it knows the types.
- **An `align` directive.** The compiler knows the offset of each variable, so the padding costs no directive. An `align` waits for a text that is written by hand.
- **The state of `chibicc` reset by a patch.** The static variables are in eight files. A patch that sets each to its start would be large and would miss the next one that the work adds.
- **A copy of the writable data at the first call, written back at each call.** The tool would need the bounds of the writable data of the C part in the module, which the link mixes with the data of the Odin package.
- **An export for each C type.** A `char`, a `short` and the unsigned types need agreed export conventions; a pointer needs a table or a handle in the description.

## Subtle points

- **The place of an error** is an offset in the text after `chibicc` changed it: a `\r\n` became `\n`, and a backslash before a new line went away. For a source with neither, it is the offset in the source.
- **An error in an include file** names no byte of the source: the error record is `Refused`, and the log line names the file and its line.
- **A source of more bytes than its bound** is refused before the C entry: the C part never reads past the copy.
- **The copy of the source is in the arena**, not in the memory of the module. The bound is 256 KiB, and a static copy would take 64 pages of the 512 of a call host for each source, whatever its size: the arena takes the bytes of the source only. The byte that a diagnostic names is read before the arena ends.
- **The memory of the arena runs out.** `malloc` that gets no memory writes "out of memory" and ends the compile: the export fails with the record of the refused commit.

## State

Built: the module `c_compiler` with its export `compile`, the four patches, the thin libc, the table of the include files, the expanded integer instruction subset of the assembler (comparisons, `setcc`, loops, indirect calls, `imul`, `idiv`/`div`, `cqo`/`cdq`, bitwise and shift operations, 8/16/32/64-bit registers, sign/zero-extending moves, `rep stosb`, scaled indexed SIB addressing) with end-to-end host tests running `chibicc` output for factorial, recursive Fibonacci, signed/unsigned division and modulo, comparisons, bitwise ops and byte/short arrays, and the step of the main machine test. The assembler now takes the scalar SSE2 forms, numeric local labels, `xchg`, `lock cmpxchg` and the `quad` of an address with its rebase, and the patch writes `quad` for an address in an initializer, with host tests that run `chibicc` output for each. Left: the export `build` with the store "out", exports with non-`int`/`long` C types, the calls of an import through an import slot, `long double` (x87), and the next ported C program.
