# An outside source in a module: C at a pinned commit

A module of the system can compile in a work of others that is written in C. The work stays outside the repository: the flake fetches its source at one commit, applies the patches of the system, and gives the tool one folder of the store. The tool compiles each C file of that folder and links the objects into the module, in the one build path of a module. The first such work is `chibicc`, in the module `c_compiler` ([../features/c_compiler.md](../features/c_compiler.md)).

The terms Outside source and Thin libc are in [`docs/glossary/communication.md`](../../../docs/glossary/communication.md) and [`docs/glossary/code.md`](../../../docs/glossary/code.md). The guide: [`docs/TOOLS.md`](../../../docs/TOOLS.md), "The outside sources of a module".

## The constraints

- **One build path.** The C objects join the objects of the Odin package and of the `.asm` files in the same link with `lld`, then the same conversion. A second path would give a module that the checks of the system never proved ([third_party_module.md](third_party_module.md), "The constraints").
- **`src` holds everything that becomes the system** ([repository_layout.md](repository_layout.md)). The patches, the entry and the thin libc become the module, so their folder is `src/outside/<work>`.
- **The code of the system imports `base:` and `modus:` only.** The rule reads the Odin sources: it holds for the Odin package of the module. A C file reaches the machine through the memory that the Odin package gives it, and includes the headers of the thin libc only.
- **The exports come from the Odin source.** The description of an export is read from the Odin package (`describe.odin`). C has no type that says "Bytes" or "a lent handle".
- **No fact of the host in an output.** No path of the store and no time of the build reaches the module file.
- **Reproducible.** One source and one set of patches give one module: the hash of the folder of the store is in the build key of the module.
- **The reuse list names the work** ([reuse_list.md](reuse_list.md)).

## The chosen form

### Three places

| Place | What it holds |
|---|---|
| `src/outside/<work>/` | The files of the system for the work: `LICENSE` (the license of the work, copied), `patches/` (the changes of the work, in the order of their names), `system/` (the C files of the system that the work needs: its entry and its tables), `libc/` (the thin libc and its headers), `self_host/` (the units that the work compiles in when it builds itself, and the module does not: for `chibicc`, the C of `memcpy` and its kin, and the jump of `exit` in assembly) |
| The flake | The source at its commit (`fetchFromGitHub` with its hash), patched, with the files of `src/outside/<work>/` copied in, as one folder of the store; an environment variable names it in each shell and in the check |
| `src/modules/<group>/<module>/` | The Odin package of the module: its exports, its budget, the memory that it lends to the C part |

The row of the module table names the outside source: `c_source = foundation.CHIBICC`, a record of the folder of the repository and of the environment variable.

### The compile of a C file

The tool compiles each `.c` file at the top of the folder of the store, in the order of the names, with `clang` of LLVM 18, the LLVM of the Odin compiler:

```
clang --target=x86_64-unknown-none-elf -std=gnu11 -O2 -ffreestanding -nostdinc
      -I <folder>/libc/include -I <folder> -fPIC -fvisibility=hidden
      -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -mlong-double-64
      -fno-stack-protector -fno-stack-clash-protection -fcf-protection=none
      -fzero-call-used-regs=skip -U_FORTIFY_SOURCE -Wno-format-security
      -fno-asynchronous-unwind-tables -fno-unwind-tables
      -fno-common -ffunction-sections -fdata-sections
      -ffile-prefix-map=<folder>=<work> -c -o objects/c_<name>.o <folder>/<name>.c
```

Why each flag:

- **`-nostdinc` and `-I`.** The headers are the headers of the thin libc only. A `-I` folder comes before each `-isystem` folder, so the headers of the C library of the host, which the wrapper of Nix adds, are never read first.
- **`-fPIC -fvisibility=hidden`.** A module is position-independent, and the version script of the link keeps the exports of the Odin package only. A hidden symbol is called directly, with no table of the linker.
- **The frame pointer.** The kernel walks the frame pointers for a stack trace ([`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "Closed rules").
- **`-mlong-double-64`.** A `long double` is a `double`: no x87 instruction, and no call to a helper of `compiler-rt`, which the module does not hold.
- **The flags that end a protection.** The wrapper of `clang` in Nix adds the protections of a program of the host (the canary of the stack, the probes of the stack, the marks of the control flow, the clear of the registers, the checks of `_FORTIFY_SOURCE`, a format that is not a constant as an error). A canary needs `__stack_chk_guard` from a C library of the host, and a check of `_FORTIFY_SOURCE` its procedures. A later flag of the same kind wins, so the tool writes each one. The headers of the thin libc read no `_FORTIFY_SOURCE`, so a wrapper that writes it after the flags of the tool changes nothing.
- **No unwind table.** No part of the system reads one; the Odin object has none either.
- **`-ffile-prefix-map`.** `__FILE__` in a macro of the work is `<work>/<name>.c`, not a path of the store.

The memory procedures `memcpy`, `memmove` and `memset` come from `src/runtime/memory.asm`, as for each module: the thin libc does not write them again. The tool compiles the C files at the top of the folder only, so the C files of `self_host/` never enter the module.

### The border between Odin and C

The Odin package calls one C procedure in a `foreign` block, the entry of the work, with the C call form. A `foreign` procedure that no import exports is a procedure of the module ([`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "The declaration of an import is checked"). The C part calls no Odin procedure by name: the Odin package gives it a procedure value for its memory. So no Odin procedure is `@(export)` for C, and the description of the exports stays the one of the module.

## The refused forms

- **The C source in the repository.** A copy of about 9 000 lines of others would be read as code of the system by each check, and would drift from its origin with no record. The commit and the patches say exactly what the system changed.
- **An outside module with `module-build`.** An outside module is in no boot image, and the console isolates a module of the boot image ([third_party_module.md](third_party_module.md), "Built and left"). The module of a work that the system ships has a row in the module table, as each module of the system.
- **The patches applied by the tool.** The tool would need a reader of the format of a patch. Nix applies them, and the hash of the folder of the store then covers the source and the patches.
- **The include files read from the host.** A C library of the host has the paths and the standard streams that the system removed.
- **The exports described from the C source.** A C type does not say what an argument is: an `int *` can be a table, a count or an address. The Odin package states the border; the C part runs behind it.
- **The unwrapped `clang`.** Its built-in headers come from another output of its package. The thin libc gives the few headers of the language that it needs (`stdarg.h`, `stddef.h`, `stdint.h`, `stdbool.h`), so the wrapped `clang` of the shells reads no header of its own.

## Subtle points

- **A change of a patch is a new folder of the store.** Its path is in the compile command, so the build key of the module changes, and the module is built again. A new file of `src/outside/` must be in git first: the flake reads the tracked files only.
- **A shell with no variable.** The tool refuses to build a module with an outside source when its variable is not set, with the name of the variable: it never builds the module with no C part.
- **The static state of a C program.** A C program keeps its state in static variables. A call host runs many calls of one module, and the module is loaded once, so the C part sees its state of the last call. The port says how it handles it ([../features/c_compiler.md](../features/c_compiler.md), "One source for each call host").

## State

Built: the field `c_source` of the module table, the compile of the C files, the C commands in the build key, the folder of the store of `chibicc` in the flake, its row in the reuse list from the license of `src/outside/chibicc`. Left: an outside source in an outside module (a key of `module.txt`), debug information for the C part (the debug object has no line of a C file), and a host test of a C file.
