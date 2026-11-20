# The SDK and the language bindings

A developer of another project writes a module for the system, or a host program that speaks a protocol of the system, with no checkout of the repository and with no Nix. A release publishes what that work needs: the SDK, the compiler that the SDK names, and the language bindings for the languages other than Odin. This file is the design of those files of a release.

The terms are in [`docs/glossary/communication.md`](../../../docs/glossary/communication.md) ("SDK", "Public library", "Outside module") and [`docs/glossary/code.md`](../../../docs/glossary/code.md) ("Contract description", "Language binding"). The layout that the SDK copies is [repository_layout.md](repository_layout.md). The build of an outside module is [third_party_module.md](third_party_module.md). The release files and their signature are [release_image.md](release_image.md).

What changed: an outside module needed a built checkout of the system, and the command of the flake to find it. A release now ships the parts of a built checkout that an outside module reads, as a plain archive.

## Purpose

- A developer downloads the files of one release, verifies them, unpacks them, and builds a module with one command. No Nix, no checkout, no build of the system.
- A host program of another project, such as the native viewer of the remote display, compiles the packages of the system that it needs from the same archive, at the same import lines.
- A developer in C, Zig or Rust reads and writes the records of the contracts with the layouts that the compiler of the system gave them, with no copy written by hand.

## The constraints

- **One build path.** An outside module built from the SDK passes the procedures and the commands of a module built from a checkout ([third_party_module.md](third_party_module.md), "The constraints").
- **The SDK ships what the tests ran.** The module files of the SDK are those of the boot image of the release. An import of an outside module names the hash of a module that the release image holds, or the loader of a machine of that release does not find it.
- **No Nix for the developer.** Each program of the SDK and of the compiler archive runs on a Linux on x86-64 with no Nix store: no path of the store in a binary, no loader of the store, no library of the store.
- **One source of truth for the language bindings.** Every language binding is written from the record descriptions of the module format. No generator reads the Odin source of a contract, and no language binding is written by hand.
- **The tool uses the Odin standard library only** (`AGENTS.md`). An archive compression runs a program of the development shell, as the release image runs `zstd`.
- **Signed as the release image.** One checksum list names every file of a release, and one release signature covers the list ([release_image.md](release_image.md), "The files of a release").

## The files of a release

| File | What it holds |
|---|---|
| `modus-sdk-<release number>.tar.zst` | The SDK: the public library, the runtime, the module files of the group `libraries`, the contract description, the tool, the SDK manifest |
| `modus-compiler-<release number>-x86_64-linux.tar.zst` | The compiler that the SDK names: the Odin fork with its `base` and `core`, the LLVM programs that the build runs, `nasm` |
| `modus-c-binding-<release number>.tar.zst` | The C language binding: one header for each contract package and for each library module |
| `modus-zig-binding-<release number>.tar.zst` | The Zig language binding (planned, see "The language bindings") |
| `modus-rust-binding-<release number>.tar.zst` | The Rust language binding (planned, see "The language bindings") |

The release number is in each name: an SDK, a compiler and a language binding of one release go together, and a developer sees the release in each file name. `-x86_64-linux` names the host of the programs of the compiler archive. The SDK holds one program, the tool, for that same host only, so its name has no host; an SDK for a second host gets the host in its name then. A language binding holds no program, so its name has no host.

The release command writes these files in `dist/` beside the release image, and `SHA256SUMS.txt` has one line for each. `modustool verify` and the OpenSSL commands of [`docs/INSTALL.md`](../../../docs/INSTALL.md), "2. Verify the files", verify each file as they verify the image.

## The SDK

### What it holds

The SDK is a part of a built checkout, at the same paths:

```
modus-sdk-<release number>/
  sdk.manifest                       the SDK manifest
  LICENSE                            the license of the repository
  src/library/modus/                 the public library, whole: the contracts, the support packages, the copy of the cryptography with its licenses
  src/runtime/                       the memory procedures in assembly, for a module and for a host program
  build/modules/<module>             the module file of each module of the group `libraries`, at the path where the build writes it
  build/contracts.description        the contract description
  build/tool/modustool               the tool
```

**Why the paths of a checkout.** The tool names each folder of the system by a path from the root of the system, and a build changes its working folder to that root ([third_party_module.md](third_party_module.md), "Where the tool finds the system"). With the same paths in the SDK, the build of an outside module reads the same relative paths in both: one build path, with no second set of path constants. A path that one set misses would read nothing, with no error.

**What it does not hold.** No internal part, no kernel, no kernel part, no module of another group, no source of a module, no guide. An SDK has no folder `src/library/internal`, so the compiler refuses `internal:` in a module of a developer.

### The SDK manifest

`sdk.manifest` is lines of text. First, `key: value` lines, as the module build file has:

```
release: 0.94.0
compiler: dev-2026-11a 81382db6047ac43a2d397046fa45f253aa628f7c
module_format: 3
```

Then an empty line, then one line for each other file of the SDK: its BLAKE3 hash in 64 lowercase hexadecimal digits, two spaces, its path from the root of the SDK, in the order of the paths.

The tool reads the manifest at the start of each command in an SDK, and refuses an SDK with a file that differs from its line, a missing file, or a file under `src/` or `build/` that no line names. A developer who changes a package of the public library then gets a sentence that names the file, not a module that the system never compiled. The release command writes the manifest from the files that it copies, and the archive holds the files in the order of the manifest, with a fixed time, owner and mode, so one release gives one archive, byte for byte. The tool writes the tar format itself; `zstd -19` compresses it.

### Where the tool finds the system

The folder of the system is, in this order:

1. the argument `--system`;
2. the environment variable `MODUS_SYSTEM`;
3. the SDK that holds the binary that runs: the folder two levels above the file of the binary (`build/tool/modustool`), when that folder holds `sdk.manifest`. The binary reads its own path from `/proc/self/exe`;
4. the folder where the command runs.

So a developer runs `<SDK>/build/tool/modustool module-build <the folder of the module>` from any folder, with no variable. A checkout keeps the command of the flake and `MODUS_SYSTEM`.

In an SDK, the tool runs the commands that a developer of another project needs: `module-build`, `verify`, `binding`. Each other command stops with one sentence that it needs a checkout of the system. The binary of the SDK never compiles itself: it is built with `-define:TOOL_BUILDS_ITSELF=false`, as the binary of the check of the flake ([repository_layout.md](repository_layout.md), "The tool built once").

### The programs with no Nix

A program that Nix builds names the loader and the libraries of the store, and does not start on a Linux with no store. So:

- **The tool and `nasm` are linked statically**, with no loader and no library.
- **The release command reads each executable file of the SDK and of the compiler archive** before it writes the archive. It refuses a file with a path of the store in its bytes, an interpreter segment that names the store, and a search path of libraries that is not inside the archive (`$ORIGIN`).
- **The check outside Nix.** A job of the release workflow runs on a runner with no Nix. It downloads the files of the build job, verifies them, unpacks the SDK and the compiler, builds the two example modules of the check, `tally` and `agenda`, and compares the hash of each import with the module file of the boot image. An SDK that needs the store fails there, before the publish job.

### The compiler

The build of a module runs the Odin fork of the system, at one commit, with an LLVM 18 that has one commit of LLVM 21 ([`docs/REPRODUCIBLE_BUILD.md`](../../../docs/REPRODUCIBLE_BUILD.md), "8. The debug information"). The tool passes `-debug-info:same-code`, which the compiler of the Odin project refuses as an unknown option. So "the Odin compiler at the version that the SDK names" is the fork, and a developer cannot get it from the Odin project.

**The chosen form: the release also ships the compiler archive.** It holds the program `odin` of the fork, its `base` and `core`, the LLVM programs and the library that the build runs (`llc`, `ld.lld`, `clang`, `libLLVM`), and `nasm`, built by the flake and checked as the SDK is. The tool runs `odin` from the search path of the shell, reads `odin version`, and refuses a compiler whose version is not the line `compiler` of the manifest, with a sentence that names the archive.

The archive leaves when the two reasons leave: the option for the debug information in the compiler of the Odin project ([debug_information_and_code.md](debug_information_and_code.md)), and LLVM 22, which has the commit of the order of dead store elimination ([llvm_of_the_build.md](llvm_of_the_build.md)). Both are entries of `ROADMAP.md`. The SDK then names a release of the Odin project, and the line `compiler` of the manifest says which.

### A host program

A host program of another project gives its compiler `-collection:modus=<SDK>/src/library/modus`, and assembles `<SDK>/src/runtime/memory_for_host_tests.asm` with `-i<SDK>/` for the include of `memory.asm`. The native viewer of the remote display does this from a checkout today; the SDK gives it the same folders with no checkout. It imports `modus:contract/remote_display`, `modus:quic`, `modus:random` and `modus:cryptography_primitives`.

### A Nix output, as a convenience

The flake gives the SDK and the compiler as one output, for a developer who uses Nix. It is built by the same command of the tool. It is not the path: the archive is, and the check outside Nix proves the archive.

## The versions

- **The SDK carries the release number.** It is in the name of each file and in the manifest; the tool prints it with each refusal of an SDK.
- **The contract packages are the stable part.** Each contract states how it changes, and a developer reads that rule in its guide: the record of a ring grows by fields at its end, and a zero field keeps the meaning of the record before ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "Zero is initialization (ZII)"); a record whose values change their meaning gets a new name of the export that reads it; a file format has its version, which a reader checks (the module format, the debug object, the replacement list). The version of the module format covers the module file only: it does not change for a change of another contract.
- **A support package can change from one release to the next.** A change of a name, a signature or a meaning of a package of `modus:` outside the folder `contract` is a change that a developer notices, so it gets its changelog fragment, with the name of the package.
- **An outside module with an import runs on the release of its SDK.** Its import table names the hash of a library module of that release, and almost each release changes the hash of each library module. A module with no import keeps its file on a later release while the contracts that it compiled in keep their rules.

## Other languages

### What a module is to another language

A module is a module file: the code, and the descriptions of its exports as records of the module format, written by `module_file_writer`. A program reaches the system through two things only:

- the contracts: the records, the rings and the kernel operations;
- the exports of the library modules, described as records in their module files.

Neither is a feature of Odin. A language that writes the records of the contracts at their offsets and calls an export with the C call form can reach the system.

### Today

A developer writes Odin. A module of the system can also compile in C and assembly: C through an outside source and the C compiler of the build ([outside_source.md](outside_source.md)), assembly through `nasm`. The exports are always described from the Odin package of the module: C has no type that says what an argument is. An outside module has no C part yet.

### The contract description

The module format describes a record only where an export or a log fact names it, in the tables `Records` and `Fields`. It holds no member of an enum, no constant and no number of a kernel operation (an enum: `operation.Operation`). A language binding needs each of them, so the contracts get a described form that they lack today.

**The chosen form: the contract description, a file of the module format with no segment and no export, which the build writes from the contract packages.**

- Its tables are the tables of the module format: `Records`, `Fields`, `Strings`, `Documentation`, and two tables more that the module format gets: `Enumerations` (each enum, its type of integer and its members with their names and values) and `Constants` (each constant of a contract package that is a number or a text, with its type and its value).
- The two tables join the module format at the end of its table directory. A reader finds a table by its index (`module.table`), and no check refuses a directory with more entries than the tables that the reader knows. So a reader of today reads a file with the new tables and skips them, and the format version does not change.
- A module file gets the same table `Enumerations` for an enum that its exports and its facts name. The console then writes the name of a member of an enum of a module, which it cannot do today ([../features/log_facts.md](../features/log_facts.md), "Open questions").
- **How the tool gets it.** The describe step of the build reads the declarations of each contract package with the parser, as it reads the exports of a module, and takes each size, offset and value from the compiler: a host program that the tool generates names each type and each constant, and prints `size_of`, `offset_of`, the members of each enum with their values, and each constant. That is the source of the byte layouts of the site today ([../features/byte_layout.md](../features/byte_layout.md)). So a layout is never computed twice.
- **A record that a language binding cannot write is refused at the describe step.** A field of a contract record is a number, an enum, a bit set over an enum, a fixed array of those, or a record of those. A pointer, a slice, a `string`, a `union`, a `Maybe` and a procedure value are refused with the name of the field: a record that crosses a border has no such field in any case ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "12. Module metadata in flat tables, read through functions").
- The pure procedures of a contract package are code, not descriptions: the description has none of them.

### The language bindings

**The chosen form: one generator in the tool, `modustool binding <language> <folder>`, whose inputs are the contract description and the module file of each library module, and nothing else.** Each language is a target of that one generator. The SDK holds the inputs and the tool, so a developer can write each language binding again from the SDK.

**The C language binding, the first target and the base.** Every language with the C call form reads a C header: C, Zig with `@cImport`, Rust with `bindgen`. Its files:

- `include/modus/contract/<package>.h`: for each record a `struct` with each field at its offset, a field of padding where the record has a gap, and a `_Static_assert` of the size and of each offset; for each enum a `typedef` of its integer type and one `#define` for each member, `MODUS_<PACKAGE>_<ENUM>_<MEMBER>`, because a C `enum` has no type of integer that C11 fixes; for each constant one `#define` with its suffix of type; the documentation text of each record and field as a comment.
- `include/modus/module/<module>.h`: for each export of a library module, the declaration of its procedure with the C call form, from the `Functions` table, and its parameter records.
- `include/modus/release.h`: the release number and the version of the module format.

**The Zig and the Rust language bindings, later targets.** The same generator writes a Zig file of `extern struct` and constants, and a Rust crate of `#[repr(C)]` records and constants, from the same inputs. A target is added when a developer of that language needs more than the C header gives through `@cImport` or `bindgen`.

**The check that holds a language binding to the contracts.**

- `modustool check` and the build job of the release workflow write each language binding from the inputs of the build.
- A host test of the tool compiles one C program against the C language binding with the `clang` of the build, with the flags of an outside source (`-ffreestanding -nostdinc`): the program includes each header and prints the size and each offset of each record, and the value of each member and constant. The tool compares each line with the values that the Odin compiler gave the contract description. A language binding that does not agree with the compile of the contracts stops the check and the release, with the name of the record and the field.
- A small C program, written by hand, uses the language binding as a developer does: it fills a command record of a kernel ring and a record of a ring of a service, with the members by name. It must compile with no warning.
- A target of another language gets the same two tests in its compiler before its archive ships.

### What stays Odin only, and what it costs a C developer

The support packages are Odin code: no description holds them, and no language binding gives them. A C developer has the records of the contracts and the exports of the library modules, and writes the rest:

- the kernel entry and the push and the read of a ring, with the order of the memory that the ring contract states, in place of `modus:system`;
- the loader of a module that a process loads at run time;
- the elements of the interface, the network protocols (`modus:tcp`, `modus:quic`) and the client of the storage service;
- the pure procedures of the contracts: the checks of UTF-8, the reads in a byte order, BLAKE3.

Where a library module exports such code, C calls it through its export, as the drawing module is called for a draw table. The answer for the rest is a library module, not a second implementation in each language ([../api/library_modules.md](../api/library_modules.md)).

## Refused forms

- **The SDK in a layout of its own** (`<SDK>/library/`, `<SDK>/modules/`). The tool would need a second set of folder constants for the SDK, and a path that one set misses reads nothing with no error ([third_party_module.md](third_party_module.md), "Where the tool finds the system").
- **The SDK as a Nix output only.** A developer with no Nix gets nothing. The output is a convenience beside the archive.
- **A checkout as the SDK.** It holds the internal parts, the kernel and every module source, needs a build of the system before the first outside module, and gives the compiler `internal`.
- **The name `modus-development-kit-<release number>`.** "SDK" is the word that a developer of another project looks for, and the short name is the name of the archive in each command that the developer types. The term is SDK, and its glossary entry says the complete words once.
- **The SDK with no compiler, "the compiler of the Odin project at the version that it names".** No release of the Odin project takes `-debug-info:same-code`, so the one build path fails at its first compile. A second compile command for an outside module was refused with the second build path ([third_party_module.md](third_party_module.md), "What is checked").
- **The compiler built by the developer from the commit of the fork.** It needs LLVM 18 with one more commit, built from source: a build of LLVM that each developer pays, for a binary that the release already built.
- **The tool linked to the C library of the store.** It starts on no Linux without the store.
- **A language binding from a parse of the Odin source.** A layout computed from a parse is a second computation of what the compiler decides, and can disagree with it. The compiler gives each layout once, to the description; each language binding reads the description.
- **A language binding from the C header** (Zig and Rust through `@cImport` and `bindgen` only, with no target of their own). It is the path of today for those languages, and stays one. A target of its own gives the types of the language (a Rust enum, a Zig `enum` with a type of integer) where the C header has only `#define`.
- **A header written by hand.** It drifts from the contracts at the first change, and no check finds it.
- **The language bindings inside the SDK.** A developer in C needs no Odin library, and a developer in Odin needs no header. Each file of a release serves one developer; the SDK holds the generator, so a developer of the SDK writes a language binding when needed.
- **The support packages translated into C.** Two implementations of the rings and of the protocols drift, and a fault is fixed twice. A shared function is a library module.

## Subtle points

- **The SDK and the release image come from one build.** The release command builds the modules once, then writes the image and the SDK from that build. The packaging of the SDK compares the BLAKE3 hash of each module file of the SDK with the module of the same name in the boot image of the release volume, as the packaging of the volume compares each module with the build.
- **A host program is not an outside module.** It compiles the public library for the host, and the rule of the three places of an outside module does not apply to it. The compiler still refuses `internal:` in it, because its build has no such flag.
- **The two manifests of the cryptography are in the SDK.** They name the files of the copy by their paths in the repository, which are the paths in the SDK, so `cryptography-origin` can prove the copy of an SDK against Odin. A host program then needs no checkout to trust the copy that it compiles in.
- **The documentation of a contract record is a reference comment today.** The describe step takes it into the `Documentation` table of the contract description, so the comments of the C header are the comments of the guides.
- **A language binding is a copy, and property 12 says that the flat tables are the only format.** The copy is for a compiler of another language, which reads no module file. The system never reads a language binding, the tool writes it from the tables at each release, and the check compares it with the compile of the contracts. So the tables stay the one source, and a language binding that drifts stops the release ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "12. Module metadata in flat tables, read through functions").
- **The compiler archive ships the work of others.** The Odin fork, LLVM and `nasm` each go with their license in the archive, and the reuse list names each ([reuse_list.md](reuse_list.md)). The system already fetches them; a release that ships them redistributes them.
- **The archive of the compiler is the largest file of a release.** LLVM is most of it. Its size is a measure of the release command, printed, and not a bound.

## The test that breaks this design on its first day

A runner with no Nix verifies the files of a release, unpacks the SDK and the compiler, builds `agenda`, which imports `calendar`, and finds that the hash of `calendar` in its import table is the hash of `calendar` in the boot image of the release. Then it compiles the C program against the C language binding and compares each layout with the contract description. An SDK that needs the store, a module file of another build, a compiler that is not the fork, and a header that disagrees with the compiler each fail it.

## State

Designed, not built. Each part is an entry of [`ROADMAP.md`](../../../ROADMAP.md): the two source libraries, the SDK with the compiler archive, and the C language binding. The Zig and the Rust targets, and the objects of another compiler in an outside module, are one entry of its section Maybe: without such objects, a header gives a C developer the records but no module of their own. Left with no entry: an SDK for another host than Linux on x86-64.
