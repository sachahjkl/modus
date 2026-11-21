# Language-neutral module ABI and relocatable object conversion

Any compiled language can produce a modus module without Odin. A compiler emits a freestanding System V AMD64 relocatable ELF object (`.o`), and the developer writes a plain-text manifest that describes the module border. The build tool converts the object and the manifest into a verified module file through the same module file writer that Odin modules use.

The module contract is in [`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "4. The call form". Outside modules and the SDK are in [third_party_module.md](third_party_module.md) and [sdk.md](sdk.md). C sources compiled into a system module are in [outside_source.md](outside_source.md).

## Purpose

- Let C, Rust, Zig, Odin, and assembly authors target modus directly from a freestanding `.o` file.
- Decouple module metadata from Odin syntax tree scraping so one intermediate representation (`Module_Manifest`) serves every language.
- Eliminate the build-time dependency on ELF dynamic linking (`ld.lld -shared`, `.dynsym`, `PT_LOAD`, `PT_GNU_RELRO`) for single-object language-neutral modules.
- Harden the ELF reader and converter against malformed headers, out-of-bounds strings, integer overflows, silent relocation drops, and toolchain-specific quirks.

## Constraints

- **One module format.** Every language produces the exact same module file format, validated by `module.validate` and written by `modus:contract/module_file_writer` ([`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "The module file writer").
- **No language runtime at the border.** Exports and import slots use only the System V AMD64 C call form with flat fixed-layout records. No compiler-specific runtime type information, slice layout, tagged union, or allocator pointer crosses a module border.
- **Freestanding code only.** No libc, no host system calls, no dynamic linker, no thread-local storage, and no runtime global offset table exist inside a modus process.
- **Strict borders.** Every ELF field, symbol index, section offset, relocation target, and manifest line is checked before use. Unknown keys, unknown types, unresolved symbols, and forbidden relocations stop conversion with a specific error message.
- **Deterministic output.** Section ordering, alignment, and synthetic slot placement follow one fixed order so identical object and manifest inputs produce byte-identical module files.

## Chosen form

### 1. Calling convention and data layout

Every export and every imported function uses the System V AMD64 C call form (`extern "C"` in C, Rust, and Zig; `proc "c"` in Odin):

- **Scalar registers and stack.** Up to 12 integer arguments (`module.PARAMETER_CAPACITY`): the first 6 in `rdi`, `rsi`, `rdx`, `rcx`, `r8`, `r9`, and arguments 7 to 12 as 8-byte words on the stack.
- **No aggregate by value.** Records, tables, bytes buffers, and text slices travel by pointer to caller-owned memory.
- **Flat fixed-layout records.** Every record has an explicit byte size (at most 256 bytes) and explicit field offsets matching C struct layout on x86-64. Each field is an integer of 1, 2, 4, or 8 bytes, a fixed-size UTF-8 byte array, a 32-byte hash, or a 4-byte handle number.
- **Text and table descriptors.** A `Text` parameter is a pointer to `{uint8_t *address; uint64_t count;}` (16 bytes). A `Table` or `Bytes` parameter is a pointer to `module.Table_Place`: `{void *address; uint64_t count; uint64_t capacity;}` (24 bytes).
- **Result buffers and error records.** A `Text` or `Table` result appends a buffer pointer `{address, capacity}` as the last parameter and returns the full count in `rax`. A `Record` result appends a destination pointer and returns void. An export with an error record appends an error record pointer as the final argument and returns a negative `i64` on failure.
- **Entry export.** An executable module exports `entry` taking one pointer argument (the process context address). A library module omits `entry` and contains no `Read_Only_After_Load` segment.

### 2. Freestanding relocatable ELF input (`ET_REL`)

The language-neutral converter takes a 64-bit little-endian x86-64 ELF relocatable object (`ET_REL`, machine `EM_X86_64`). Compilers produce this object directly (`clang --target=x86_64-unknown-none-elf -ffreestanding -fPIC -fno-plt -c`, `zig build-obj`, `rustc --emit=obj`, `odin build -build-mode:obj`, or an assembler). Multiple `.o` files can be pre-merged with `ld -r` into one `ET_REL` object.

**Section grouping.** Allocated (`SHF_ALLOC`) sections (excluding `.eh_frame*`) map into at most four page-aligned segments in fixed order:

1. **Code (`Read`, `Execute`)**: `SHF_EXECINSTR` sections without `SHF_WRITE`, followed by any 6-byte indirect jump stubs for `PLT32` calls to imported functions.
2. **Read-only data (`Read`)**: `SHF_ALLOC` sections without `SHF_WRITE` and without `SHF_EXECINSTR` (such as `.rodata`, `.rodata.str*`, `.rodata.cst*`).
3. **Read-only after load (`Read`, `Write`, `Read_Only_After_Load`)**: `.data.rel.ro` and `.data.rel.ro.*` sections, followed by 8-byte synthetic import slots and rebased address slots. If no rebase or import slot targets this segment, `module_file_writer` strips `Write` and `Read_Only_After_Load`.
4. **Writable data (`Read`, `Write`)**: writable `SHT_PROGBITS` sections (`.data*`), followed by writable `SHT_NOBITS` sections (`.bss*`) at the tail so trailing zero bytes occupy no file space.

Zero-size allocated sections retain a valid offset for section symbols without emitting an empty segment. Valid `SHT_GROUP` (COMDAT) metadata sections are verified and skipped. Non-allocated sections (`.comment`, `.debug_*`, `.llvm_addrsig`, `.note.GNU-stack`) and their `.rela.*` sections are skipped.

**Relocation lowering.** Every `SHT_RELA` entry targeting an allocated section is lowered as follows:

| ELF relocation | Defined symbol | Undefined imported symbol |
|---|---|---|
| `R_X86_64_NONE` (0) | Ignored | Ignored |
| `R_X86_64_64` (1) | Writable/RELRO 8-byte aligned only: writes `S + A` and emits a rebase | Writable/RELRO 8-byte aligned with `A == 0`: writes `0` and emits a `module.Import_Slot` |
| `R_X86_64_PC32` (2) | Patches 4-byte `S + A - P` (checked for `i32` range), no rebase | Refused |
| `R_X86_64_PLT32` (4) | Patches 4-byte `S + A - P` (checked for `i32` range), no rebase | Requires `A == -4`: emits a 6-byte `jmp *slot(%rip)` stub and an 8-byte `module.Import_Slot` |
| `R_X86_64_GOTPCREL` (9), `R_X86_64_GOTPCRELX` (41), `R_X86_64_REX_GOTPCRELX` (42) | Requires `A == -4`: allocates an 8-byte rebased slot in `Read_Only_After_Load` and patches `slot + A - P` | Requires `A == -4`: allocates an 8-byte `module.Import_Slot` in `Read_Only_After_Load` and patches `slot + A - P` |
| `R_X86_64_PC64` (24) | Patches 8-byte `S + A - P`, no rebase | Refused |

With `-fno-plt`, compilers emit `call *fn@GOTPCREL(%rip)` (`R_X86_64_GOTPCRELX` or `R_X86_64_REX_GOTPCRELX`), which lowers directly to the modus single-instruction import slot call without a stub or runtime GOT.

**Refused ELF inputs.** The converter refuses with a named diagnostic:

- Non-64-bit, big-endian, non-`EM_X86_64`, or non-`ET_REL` inputs (including `ET_DYN` and `ET_EXEC` on the language-neutral object path).
- `PT_INTERP` dynamic linker segments and `PT_TLS` / `SHF_TLS` thread-local data.
- `SHT_INIT_ARRAY`, `SHT_FINI_ARRAY`, and `SHT_PREINIT_ARRAY` constructor or destructor sections with non-zero size.
- `SHT_REL` or `SHT_RELR` sections targeting allocated sections.
- Writable and executable (`SHF_WRITE | SHF_EXECINSTR`) sections, or `SHT_NOBITS` executable sections.
- `SHN_COMMON` tentative symbols (compile with `-fno-common`).
- Text relocations (`R_X86_64_64` in code or read-only data) and non-PIC 32-bit absolute relocations (`R_X86_64_32`, `R_X86_64_32S`, `R_X86_64_16`, `R_X86_64_8`).
- Runtime GOT and dynamic-linker relocations (`R_X86_64_GOT32`, `R_X86_64_GOTOFF64`, `R_X86_64_GOTPC32`, `R_X86_64_GOT64`, `R_X86_64_GOTPCREL64`, `R_X86_64_GOTPC64`, `R_X86_64_GOTPLT64`, `R_X86_64_PLTOFF64`, `R_X86_64_COPY`, `R_X86_64_IRELATIVE`).
- All thread-local storage relocations (`DTPMOD64`, `DTPOFF64`, `TPOFF64`, `TLSGD`, `TLSLD`, `DTPOFF32`, `GOTTPOFF`, `TPOFF32`, `GOTPC32_TLSDESC`, `TLSDESC_CALL`, `TLSDESC`).
- Unresolved undefined symbols not exported by any listed import module.
- Export symbols that are missing, local (`STB_LOCAL`), non-function (`!= STT_FUNC`), or outside an executable section.
- `modus_own_hash` symbols that are duplicated, wrong size (`!= 32`), or outside writable non-executable memory.

### 3. Language-neutral `Module_Manifest` format

A plain-text manifest describes a module independently of its source language. Both `manifest_parse` and Odin's `describe_package` produce the same `Module_Manifest` / `Module_Description` intermediate structure, which feeds one shared conversion pipeline into `module_file_writer`.

The manifest uses strict line-oriented blocks (blank lines and `#` comment lines are skipped; any unknown key, unknown type, duplicate key, or malformed value is refused with its line number):

```
module: math_c
about: Arithmetic helpers compiled from freestanding C.
library: yes
imports: base_lib
budget: working_memory_pages=4 threads=1

enum Rounding u32
  member down = 0
  member nearest = 1

record Pair size=16
  field left offset=0 type=i64
  field right offset=8 type=i64

export add_pair
  about: Return the sum of both fields of a pair.
  param pair: record(Pair)
  param mode: enum(Rounding) optional
  result: integer
```

Top-level directives:

- `module: <name>` (required): lowercase ASCII module name, 1 to 31 bytes.
- `about: <text>` (required): one-line module documentation in UTF-8 without control characters.
- `library: yes | no` (optional, default `no`): when `yes`, the converter enforces that the output has no `Read_Only_After_Load` segment.
- `imports: <name> ...` (optional): space-separated imported module names in import table order, with no duplicates.
- `budget: <part>=<value> ...` (optional): positive integers for `working_memory_pages`, `processes`, `threads`, `window_width`, and `window_height`.

Block directives (`enum`, `record`, `export`):

- `enum <Name> <u8|i8|u16|i16|u32|i32|u64|i64>` followed by `member <name> = <value>` lines (1 to 64 members).
- `record <Name> size=<bytes>` followed by `field <name> offset=<bytes> type=<type>` lines. Field types: `i8`, `u8`, `i16`, `u16`, `i32`, `u32`, `i64`, `u64`, `hex8`, `hex16`, `hex32`, `hex64`, `size_bytes`, `size_kib`, `size_mib`, `size_pages`, `size_blocks`, `time_ns`, `time_us`, `time_ms`, `time_s`, `text(<N>)`, `module_name`, `hash`, and `handle(<rights>)`.
- `export <name>` followed by `about: <text>`, zero or more `param <name>: <type> [optional] [getter=<export>]` lines, optional `result: <type>`, and optional `error_record: <Record>`. Parameter types: `integer`, `integer(<unit>)`, `text`, `record(<Record>)`, `handle(<rights>)`, `table(<Record>, read|change|append)`, `bytes(read|change|append)`, and `enum(<Enum>)`. Result types: `none`, `integer`, `text`, `record(<Record>)`, `table(<Record>)`, and `enum(<Enum>)`.

### 4. Hardening of the linked-ELF (`ET_DYN`) path

System Odin modules still pass through `ld.lld -shared` and `convert` (`ET_DYN`). The converter now shares the same strict bounds checks and `module_file_writer` finalizer:

- Bounded string table reads (`elf_section_bytes` and `text_until_zero`) replace unbounded `cstring` scans.
- Explicit checks verify `SHT_DYNSYM` presence, symbol table entry counts, relocation symbol index bounds, `PT_INTERP` refusal, `SHF_TLS` refusal, `SHT_REL`/`SHT_RELR` refusal, `file_size <= memory_size` before allocation, checked addition without wraparound, zero-size section handling, non-zero addend refusal on import slots, and duplicate rebase refusal.
- Every refusal reports a clear diagnostic instead of returning silently.

## Refused forms

- **C++ ABI and name mangling.** Name mangling, exceptions, RTTI, and virtual tables tie the border to one compiler family. Every export uses an unmangled C symbol name and the System V AMD64 C call form.
- **POSIX or libc compatibility layer in the kernel.** Modus exposes counted kernel operations and shared-memory rings, not POSIX system calls or file descriptors. A module in C, Rust, or Zig calls contract operations or library module exports directly.
- **ELF dynamic linking (`ET_DYN` and `PT_INTERP`) for language-neutral modules.** Dynamic linking requires symbol hash tables, search paths, PLT lazy binding, and a runtime loader. Freestanding `ET_REL` objects carry exact section and relocation tables that lower directly to flat modus segments, RELR rebases, and indexed import slots.
- **Language-specific runtime pointers across module borders.** Slices, fat pointers, allocator contexts, and tagged unions vary across compilers and versions. Only fixed-layout records and the contract descriptor structs cross exports.
- **Extracting export metadata by parsing C, Rust, or Zig syntax.** A C prototype cannot distinguish a pointer to one record from a table, a handle's rights, or a read-only bytes buffer, and parsing every host language duplicates compiler front ends. One strict manifest format works for every language.
- **JSON, TOML, or YAML for manifests.** Each brings a general parser that accepts constructs outside the module contract. The line-oriented manifest matches `module.txt` and `sdk.manifest` and keeps the parser small and exact.

## Subtle points and hazards

- **Non-zero addend on an import slot.** `module.Import_Slot` binds the exact address of an imported export and has no addend field. An `R_X86_64_64` relocation against an undefined import symbol with a non-zero addend is refused instead of silently dropping the addend.
- **Empty `.text` or `.rodata` sections.** Compilers with `-ffunction-sections` emit a zero-size `.text` section alongside `.text.<fn>`. Skipping zero-size byte copies while keeping the section's assigned address prevents false "section in no segment" failures.
- **Synthetic `Read_Only_After_Load` segments in library modules.** A library module that imports another module or references a global via `GOTPCRELX` acquires a `Read_Only_After_Load` segment. When `library: yes` is set, the converter refuses the module, matching the rule that library modules stay position-invariant across importers.
- **Relative relocations to local section symbols.** Compilers often emit `R_X86_64_PC32` or `R_X86_64_64` against an `STT_SECTION` symbol (such as `.rodata.str1.1`) plus an addend. Resolving `sym_addr = section_memory_offset[symbol.section_index] + symbol.value` handles both named symbols and `STT_SECTION` symbols uniformly.
- **Signed 32-bit displacement overflow.** Every `PC32`, `PLT32`, and `GOTPCREL*` patch checks that the signed 64-bit displacement fits in `i32` before truncating.

## The test that breaks this design on its first day

Compile a freestanding C source with `clang --target=x86_64-unknown-none-elf -ffreestanding -fPIC -fno-plt -c` containing an exported function, a local static string in `.rodata.str1.1`, a rebased data pointer in `.data`, a 32-byte `modus_own_hash` buffer in `.bss`, and a call to an imported export of another modus module. Pair the `.o` file with a language-neutral manifest, convert it with `convert_elf_with_manifest`, and check the resulting module file with `module.validate`. Any missing `R_X86_64_GOTPCRELX` or `R_X86_64_PLT32` lowering, wrong `.rodata`/`.bss` alignment, missing `own_hash_place`, or broken rebase encoding fails this test immediately.

## State

Built: the language-neutral `Module_Manifest` type and strict parser (`tools/modustool/build/manifest.odin`), the hardened ELF reader and freestanding `ET_REL` converter (`tools/modustool/build/elf.odin`, `tools/modustool/build/convert.odin`, `tools/modustool/build/relocatable_elf.odin`), and adversarial host tests covering both synthetic `ET_REL` objects and freestanding C compiled with `clang`. Left: a CLI subcommand exposing `convert-object` for external build systems and debug-object generation from `ET_REL` DWARF sections.
