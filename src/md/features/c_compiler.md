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

`main` of `chibicc` is not compiled: it parses arguments, runs other programs, and writes files. The file `src/outside/chibicc/system/compile.c` does what its function `cc1` does for one file, with no file: it gives the source to the reader of files of the thin libc under its name, `source.c` when the caller gives none, tokenizes, preprocesses, parses and generates into a memory stream, and gives the text to its caller. It also holds what `main.c` defined for the other files: the include path (`include`, then `libc/include`), `file_exists` over the table of files, and the options (no common symbols, no `-fPIC` form).

The record of the call, `Compile_Call`, also takes a unit of a program of several sources: the name of the source, whose folder is the folder of its quoted includes, the other files of the program (its headers, and those of the thin libc), and the names of its exports. The module `c_compiler` gives one source and leaves them zero. The export `compile_record_at(record_address)` takes the record by its address: it is the export of the compiler when the compiler is a module of its own, in the self-hosting ([bootstrap.md](bootstrap.md), "The self-hosting of the C compiler").

### The patches

| Patch | What it changes, and why |
|---|---|
| `0001-headers-of-the-thin-libc.patch` | `chibicc.h` includes no header of a host program (`glob.h`, `sys/stat.h`, `sys/types.h`, `sys/wait.h`, `time.h`, `unistd.h`): only `main.c` and the date macros used them. It declares the place of an error |
| `0002-reproducible-dates.patch` | `__DATE__`, `__TIME__` and `__TIMESTAMP__` give the start of the epoch. A compiler that reads the clock gives other bytes at each run; the system has no time of a file |
| `0003-assembly-of-modus.patch` | The output is the syntax of the assembler: `section code` and `section data` in place of the sections of ELF, an `export` directive for each function that is not `static`, no `.file` and no `.loc`, data as `byte`, `quad` and `zero` lines |
| `0004-place-of-an-error.patch` | Each diagnostic with a place records the offset of that place in its file, so the error record names the byte |
| `0005-units-of-a-program.patch` | Each text starts with `unit`; each function and variable that is not `static` gets `global`; a function is an export when `function_is_export` of the entry says so; a variable gets `align`; the address of each function is a `lea` of `%rip`, as of a variable. So the texts of several sources join into one text of the assembler |
| `0006-a-long-double-is-a-double.patch` | `long double` and the suffix `L` of a constant give a `double`, as `-mlong-double-64` does for clang: `chibicc` compiles its own `long double` with no x87 instruction |
| `0007-static-assert.patch` | Adds `_Static_assert` in file, block, and struct/union scopes (`tokenize.c`, `parse.c`), needed by upstream zstd and SQLite headers |
| `0008-include-guard-nesting.patch` | Fixes `detect_include_guard` in `preprocess.c` to track nested `#if`/`#endif` depth on `tok->next` and refuse early top-level `#endif`/`#else`/`#elif`, so multi-section headers such as zstd's `fse.h` re-include cleanly |

### The marker of an export: each function that is not static

A C function that is not `static` has external linkage: C already says "other code calls this". So each such function of one source becomes an export, and a `static` function stays inside the module. In a program of several sources, external linkage joins the units: each such function is a global label, and the caller names the exports among them.

- An `int` or a `long` is an `Integer`; a `void` result is no result.
- A function that is not `static` with another type of parameter or of result is refused, with the place of the type: "make it static, or give it int or long".
- **Why not an attribute.** A marker of its own would be one more word of C that only this compiler knows, and a C source of others would need a change for each export. External linkage is the marker that the language has.
- **The sign of an `int` result.** An `Integer` is 64 bits, and `add %edi, %eax` writes zero in the high half of `%rax`. The compiler writes `movsxd %eax, %rax` at the end of each export that gives an `int`, so `add(-2, 1)` gives -1.

### The data

The compiler writes `align` before each variable, with its alignment: the data of a unit starts where the data of the unit before it ended, which the compiler of the unit does not know. The section data starts on a page, so an offset aligned in the section is an address aligned in memory. A variable with an initializer is `byte` lines, and a `quad` line for each address that it holds (`quad add+0`, `quad numbers+8`); one with none is `zero`. The assembler records a rebase for each `quad` of a label, so a table of functions or of strings holds addresses at each base of the load. A `quad` off 8 bytes of the data (a pointer in a packed struct) is refused by the assembler with its line.

### The thin libc

It is the C library that `chibicc` calls, and nothing more, in C beside the work (`src/outside/chibicc/libc`):

| Part | Procedures |
|---|---|
| Memory | `malloc`, `calloc`, `realloc` over the arena that the Odin package gives as a procedure value; `free` ends nothing |
| Text | `memcmp`, `strlen`, `strcmp`, `strncmp`, `strncasecmp`, `strchr`, `strstr`, `strncpy`, `strdup`, `strndup`, `strtoul`, `strtold`, `strerror`, `dirname`, the classes of `ctype.h` |
| Streams | `FILE` as a memory stream: `open_memstream`, `fopen` of a name of the table of files (read only), `fread`, `fwrite`, `fputc`, `fflush`, `fclose`, `fprintf`, `vfprintf`, `printf` |
| End | `exit` returns to the C entry with `thin_libc_jump`, and the entry gives the failure to its caller |

- **`copy_bytes_without_overlap` and its kin.** `memcpy`, `memmove` and `memset` are the procedures of `src/runtime/memory.asm` in each module that clang builds. When `chibicc` builds itself, they are the C of `src/outside/chibicc/self_host/bytes.c`.
- **The jump of `exit`.** Under clang, `thin_libc_jump_set` and `thin_libc_jump` are `__builtin_setjmp` and `__builtin_longjmp`, and the trap is `__builtin_trap`. `chibicc` has none of these built-ins: under it, the two procedures are the assembly of `src/outside/chibicc/self_host/jump.s`, which keep and restore the registers that a call keeps, the stack and the place of the return, in a buffer of 8 words, and the trap is `ud2`.
- **The headers read in clang and in `chibicc`.** `stdint.h` writes the types of the data model LP64, which both compilers give: `chibicc` has no macro such as `__INT8_TYPE__`. `stdio.h` puts the attribute `format` of `printf` under `__GNUC__`, which `chibicc` does not define, as `chibicc.h` does.
- **No path.** `fopen` takes a name of the table of files: the source as `source.c` (or the name that the caller gives), the files of the program that the caller gives, and the include files of `chibicc` (`include/stddef.h` and the others), which the flake writes into a C table. Each other name is refused, as a file that does not exist. A mode other than `r` is refused.
- **`stderr` and `stdout`** are one memory stream of 4 KiB: the diagnostic. The Odin package writes its first line on the log when the compile fails.
- **`strtold` gives the nearest double.** The module is built with `-mlong-double-64`, so a `long double` of the thin libc is a `double`, and `strtold` rounds each text to the nearest `double`, ties to even. It reads blanks, a sign, a decimal number with its exponent `e`, a hexadecimal number after `0x` with its exponent `p`, `inf`, `infinity`, `nan` and `nan(...)`. A value past the largest `double` gives infinity and `ERANGE`; a value below the least normal `double` that is not exact gives `ERANGE` too; a text with no number gives 0 and `*end` at the text. Its design is the section "The conversion of a floating constant", below.

**Why in C, beside the work, and not in Odin under `src/library`.** `vfprintf` takes a `va_list`, which an Odin procedure cannot receive: the Odin compiler takes `#c_vararg` in a declaration of a `foreign` procedure only. A support package of `src/library` needs two owners. The C programs have a second thin libc in C ("The C programs", below); one place for both is left work.

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
| `mov x@GOTPCREL(%rip), %rax` for a function that the source declares and does not define | The patch writes `lea x(%rip), %rax`: a function of another unit of the program is a global label of the same text. In one source, the assembler refuses the name as a label that the text never defines |
| A section of thread-local data | Refused by the compiler: the module format has no thread-local data |
| x87 instructions (`fldt`, `fstpt`, `fucomip`), for `long double` | None: a `long double` is a `double`. A text written by hand with one is refused by the assembler, with its line and its column |
| `asm("ud2")` of the thin libc, the trap of `exit` with no entry ready | Assembled |
| A floating constant (`1.5`, `2.5e10`, `0x1.8p+1`, `1.5f`) | `chibicc` writes its bits as an immediate of `mov` into `%rax` (`%eax` for a `float`), then `movq` to `%xmm0`, with host tests that compare the bits. The comment of the line shows `?` in place of the value: `vfprintf` of the thin libc writes `?` for a floating conversion |

So the C subset that passes today covers signed and unsigned `char`, `short`, `int`, `long`, `_Bool`, `float`, `double` and `long double` (a `double`) with their constants, pointers, local and global arrays, structs, local initializers (`rep stosb`), global initializers that hold addresses, `alloca`, the atomic builtins `__builtin_atomic_exchange` and `__builtin_compare_and_swap`, calls through a pointer to a function, comparisons, `if`/`else`, `while`, `for`, `do`, `switch`, `&&`/`||`/`!`/`?:`, `+`, `-`, `*`, `/`, `%`, bitwise `&`/`|`/`^`/`~`/`<<`/`>>`, unary `-`, and direct or recursive calls to functions in the same translation unit (`call *%r10`) and, in a program, in the other units. Exported functions still take and return `int` or `long` (`Integer`) or `void`; `static` helper functions can take any integer, pointer, or small struct type.

## The C programs

SQLite 3.54.1, Lua 5.4.7 and zstd 1.5.7 are C programs of others that the system wants as modules: a database for a service that brings its own, a scripting language that tests a C compiler hard, and the compression of the cache and of the images. Their files of the system are in `src/outside/c_programs`. Today the clang of the host builds each into a module, with the flags and the converter of a module, and a host test runs it.

### The recipes

A recipe of `recipes/` declares one program: the archive at its SHA-256, the folder of the archive that is its root, the patches, the C files of the source, the adapters of this folder, the manifest of the module, the definitions and the flags. The format is in `recipes/README.md`.

- **The hash is written once.** The flake reads `source`, `source_hash`, `unpack`, `root` and `patch` from the recipe, and makes one folder of the store with the root patched. The variables `SQLITE_SOURCE`, `LUA_SOURCE` and `ZSTD_SOURCE` name the three folders.
- **Only the host checks and the default shell see them.** No module of the system build holds a C program, so a new archive builds no system again and runs no machine test.
- **The test of the recipe is the build of its module.** `real_programs_test.odin` reads the recipe and gives its files to the build of the test module of the folder: the same compile, the same link, the same checks.

### The thin libc of the C programs

`thin_libc/` is the part of a C library that the three programs call, in C, with no system call, no path and no clock. Each standard header of `thin_libc/include` includes `modus_thin_libc.h` only.

| Part | What it does |
|---|---|
| Heap | `malloc`, `calloc`, `realloc`, `free` over a heap that the program makes over an arena that the caller lends; the heap refuses the release of a pointer that is no block in use, and counts the bytes in use |
| Text and numbers | The procedures of `string.h`, `ctype.h`, `strtod` and `strtoll`, and the `printf` family with the floating conversions |
| Streams | `FILE` as a memory stream; `fopen` of a name refuses with `ENOENT` |
| Jumps | `setjmp` and `longjmp` in assembly: the registers that a call keeps, the stack and the place of the return |
| Time and locale | Each time is the start of the epoch; the one locale is "C" |
| Elementary functions | `exp`, `log`, `log2`, `log10`, `pow`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2` (`modus_thin_libc_math.c`) |

- **A heap, not the arena of `chibicc`.** SQLite, Lua and zstd release and reuse their memory: a script of Lua releases most of its blocks, and a closed state releases each one. An arena where `free` ends nothing would grow until it fails.
- **Its own, beside the thin libc of `chibicc`.** The two are not one place yet: the left work is in "State".

### The elementary functions

- **`log` gives a double-double.** `pow(x, y)` is `exp(y log x)`: an error ε in `y log x` is a relative error ε of the result. A `log` in one double gives `|y log x|` times 2^-53, up to 700 units for a result near the overflow. The logarithm is `k ln 2 + 2 atanh(s)` with three terms of the series as double-doubles, about 70 good bits, so the error of `pow` stays below one unit. `log2` and `log10` multiply that pair by `1/ln 2` and `1/ln 10` as pairs, so an exact power of 2 or of 10 gives an exact result.
- **`exp` takes a pair.** The reduction `x = k ln 2 + r` and the rational form of fdlibm carry the low part of `y log x` in the low part of `r`.
- **The reduction of an angle.** Below 2^19 π/2, three parts of π/2 of 33 bits subtract in turn, as many as the cancellation asks. Above it, the product of the mantissa with 256 bits of a table of 1280 bits of 2/π gives the quadrant and 128 bits of the fraction (Payne and Hanek). Each angle of a double reduces with no loss.
- **`asin` and `acos` are `atan` of a quotient with `sqrt(1 - x^2)` as a double-double, so `acos` near 1 keeps its bits.
- **Radians.** The functions of C take radians, as the C standard says: a ported program calls them unchanged. The code of the system uses turns ([../data/angles_in_turns.md](../data/angles_in_turns.md)).
- **No fused multiply-add.** `#pragma STDC FP_CONTRACT OFF`: the exact products and sums count on one rounding each.
- **The bound.** Against the C library of the host, on the edges, random bits, and the ranges where each algorithm changes its path, the test allows 1 unit in the last place for `exp`, `log`, `log2`, `pow`, `sin`, `cos`, `asin`, `acos`, `atan` and `atan2`, and 2 units for `tan`, a quotient of the sine and the cosine. `log10` of glibc is 2 units off at inputs where this one gives the correct rounding (checked at 300 bits with mpmath), so the test pins those inputs. `pow` follows each special case of Annex F of C, and gives the exact powers of 2, 3 and 10 exactly.

### The VFS of SQLite

`sqlite/modus_vfs.c` is a VFS whose files are the slots of a store of bytes that the caller lends: each slot has a fixed capacity, a new file takes the first free slot, the lock levels live in the slot, the randomness comes from a seed, and the time is the start of the epoch. SQLite is built with `SQLITE_OS_OTHER`, so it asks the program for `sqlite3_os_init`, which registers the VFS over the store that the program bound first.

- **SQLite calls no `malloc`.** The entry gives SQLite a fixed `.bss` arena with `SQLITE_CONFIG_HEAP` (memsys5, `SQLITE_ENABLE_MEMSYS5`), bounded per session by `Open_Options.heap_bytes`.
- **The bytes of the store are the file.** `main.db` is supplied per call through `database: bytes(change)` (with zero pointers retained past return), and a 4 KiB dirty-page bitmap tracks modified pages for atomic store range commits ([db_browser.md](db_browser.md)).
- **The entry** (`sqlite/modus_sqlite_entry.c`): typed exports (`session_open`, `session_execute`, `session_dirty_ranges`, `session_mark_synced`, `session_info`, `session_last_diagnostic`, `session_close`, `version_number`) returning `Modus_Answer` and `Error_Record`, with typed `Column_Row`, `Cell_Row`, `Query_Summary`, and `Dirty_Range_Row` tables instead of pipe-delimited text ([db_browser.md](db_browser.md)).

### The configuration of Lua

The one patch of Lua adds `#include "modus_lua_conf.h"` to the section "Local configuration" of `luaconf.h`, so each definition of `lua/modus_lua_conf.h` replaces the one of Lua: `print` and the diagnostics write into memory that the caller lends, a write past its end is cut and recorded, no shell, no `popen` and no temporary name, and the seed of the hashes of strings is a constant.

- **The libraries.** Base, coroutine, table, string, math and utf8. io, os and the loader of C modules wait for the parts of the thin libc that they call.
- **The entry** (`lua/modus_lua_entry.c`) runs one script in a new state of `luaL_newstate`, over a heap of an arena that the caller lends, and gives the status of Lua. It calls `luaL_loadstring` and `lua_pcall`: `luaL_dostring` gives only whether a step failed.
- **The heap is empty after `lua_close`.** The entry gives the bytes in use after the close; the test checks 0 after each script, also after an error of memory.

### The configuration of zstd

`zstd/modus_zstd_conf.h` is read first by each C file of the library (`-include`). It takes the place of `lib/common/zstd_deps.h`: no thread, no legacy format, no assembly file of the host, no intrinsics of the compiler, and no choice of code by the processor at run time (`DYNAMIC_BMI2 0`).

- **No `cpuid`.** zstd reads `cpuid` when it makes a context, even when no code of BMI2 is compiled in. The patch of `cpu.h` reads none under `MODUS_ZSTD_NO_CPUID`, as on a processor that zstd does not know.
- **The memory of a context** comes from a heap over a lent arena, through `ZSTD_customMem`.
- **The entry** (`zstd/modus_zstd_entry.c`) writes one frame with its content size and the checksum of its content, and gives a count or the negated `ZSTD_ErrorCode`.

### The checks of the build

For each program, the host test proves that the relocatable object needs no symbol that its files do not define, that its disassembly holds no instruction that reaches the host (`syscall`, `cpuid`, `rdtsc`, `in`, `out` and their kin), that the compiler read no header outside this folder and the root of the source, and that the module has no import. The test prints the size of each module.

## The refused forms

- **TCC.** It writes machine code, so its port needs a second writer of the module format ([first_compiler.md](first_compiler.md)).
- **The thin libc in Odin.** It cannot receive a `va_list`, and it has one owner.
- **The GNU directives in the assembler.** They name ELF ([assembler.md](assembler.md), "The refused forms"); the compiler writes the directives of modus at the one place where it knows the types.
- **The padding counted by the compiler.** The compiler of one unit does not know where its data starts in the text of a program, so it writes `align` and the assembler counts.
- **One C source for the whole program (an amalgamation).** The files of `chibicc` have static functions and static variables of one name (`current_fn`, `count`, `push`): in one source, they collide.
- **A `long double` of 80 bits with x87 instructions.** `chibicc` uses `long double` for the value of each floating constant only; the module of clang already makes it a `double` with `-mlong-double-64`, so the two compilers of the self-hosting compute the same values, and the assembler needs no x87 form.
- **The state of `chibicc` reset by a patch.** The static variables are in eight files. A patch that sets each to its start would be large and would miss the next one that the work adds.
- **A copy of the writable data at the first call, written back at each call.** The tool would need the bounds of the writable data of the C part in the module, which the link mixes with the data of the Odin package.
- **An export for each C type.** A `char`, a `short` and the unsigned types need agreed export conventions; a pointer needs a table or a handle in the description.
- **The C programs as modules of the system build.** The system holds no SQLite ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "12. Module metadata in flat tables, read through functions"): a process brings it as its own module. The build of the system reads none of the three archives.
- **The elementary functions of the host, or of `core:math`.** A module calls nothing of the host, and `core:math` turns into calls of the libm of the host.
- **A correctly rounded library with tables (CORE-MATH, the `pow` of musl with its table of 128 entries).** It brings many more constants to check, for less than one unit in the last place, which none of the three programs needs.

## Subtle points

- **The place of an error** is an offset in the text after `chibicc` changed it: a `\r\n` became `\n`, and a backslash before a new line went away. For a source with neither, it is the offset in the source.
- **An error in an include file** names no byte of the source: the error record is `Refused`, and the log line names the file and its line.
- **A source of more bytes than its bound** is refused before the C entry: the C part never reads past the copy.
- **The copy of the source is in the arena**, not in the memory of the module. The bound is 64 MiB, more than the amalgamation of SQLite, and a static copy would take its pages of a call host for each source, whatever its size: the arena takes the bytes of the source only, and a budget that cannot pay a source refuses it with its error record. The byte that a diagnostic names is read before the arena ends.
- **The memory of the arena runs out.** `malloc` that gets no memory writes "out of memory" and ends the compile: the export fails with the record of the refused commit.

## State

Built: the module `c_compiler` with its exports `compile` and `compile_unit`, the eight patches, the thin libc (with bounded in-memory `.`/`..` path normalization for relative includes in `src/outside/chibicc/libc/stream.c`), the table of the include files, the expanded integer instruction subset of the assembler (comparisons, `setcc`, loops, indirect calls, `imul`, `idiv`/`div`, `cqo`/`cdq`, bitwise and shift operations, 8/16/32/64-bit registers, sign/zero-extending moves, `rep stosb`, scaled indexed SIB addressing) with end-to-end host tests running `chibicc` output for factorial, recursive Fibonacci, signed/unsigned division and modulo, comparisons, bitwise ops and byte/short arrays, and the step of the main machine test. The assembler now takes the scalar SSE2 forms (`sqrtsd` included), numeric local labels, `xchg`, `lock cmpxchg` and the `quad` of an address with its rebase, and the patch writes `quad` for an address in an initializer, with host tests that run `chibicc` output for each. Built also: the units of a program, the self-hosting entry `compile_record_at`, the jump of `exit` in assembly for `chibicc`, and `modustool c-self-host`, whose host test proves that `chibicc` compiles its 14 C sources and that stage 1 and stage 2 have one BLAKE3 hash ([bootstrap.md](bootstrap.md), "The self-hosting of the C compiler"). Built also: the C programs: the recipes of SQLite 3.54.1, Lua 5.4.7 and zstd 1.5.7 with their pinned archives in the flake, the thin libc of the C programs (portable across clang and `chibicc`, with `src/outside/c_programs/thin_libc/modus_thin_libc_chibicc.s` providing `setjmp`, `longjmp` and `sqrt` for `chibicc`), the VFS of SQLite, the configurations of Lua and zstd, a host test that builds the three modules with the clang of the host, and `tools/modustool/build/c_world_chibicc.odin` (`modustool c-self-host --libraries` and `chibicc_compiles_upstream_c_libraries_and_refuses_bad_inputs`), which compiles Lua 5.4.7, zstd 1.5.7 and SQLite 3.54.1 using self-hosted Stage 1 `chibicc` and the native modus assembler (`internal:assemble/assembler`) with manifest binding (`module_parts_finalize`) and validates Lua scripts with `pcall`/`math.sqrt` and zero heap leak, zstd frame compression matching host clang's compressed-frame BLAKE3 hash, and SQLite SQL execution with `PRAGMA integrity_check`. Built also: multi-unit C build support in `src/modules/system/c_builder` (`assembly`, `exports`, `headers`, `units`). Left: exports with non-`int`/`long` C types in `c_compiler` without a manifest file, the calls of an import through an import slot, running the multi-unit C library builds inside a live modus machine, the io and os libraries of Lua, and one thin libc for `chibicc` and the C programs.
