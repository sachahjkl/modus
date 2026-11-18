# The assembler of the build

The build assembles the files `.asm` of the system with `nasm` (`-f elf64`), as one step of the build of a module ([`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "7. How to build modules with existing tools"). This file records why the build keeps `nasm` when the assembler of LLVM is already in the build environment.

## The constraint

The assembler of LLVM (`llvm-mc`) is in the environment of the flake, with `llc`. One tool less is a gain only if the change adds no constraint that a reader of the code sees.

## The chosen form

The assembly files stay in the syntax of `nasm`. `nasm` is a small process, and the flake fixes its version.

## The refused form: the assembler of LLVM

- Every comment changes its mark, and each memory operand and each macro changes its form. The code is then harder to read and to comment.
- The 16-bit and 32-bit start of a processor (`src/kernel/processor.asm`) would go through the Intel syntax of LLVM, which is less tested than its other syntax.
- The host tests still need `nasm`: the compiler calls it itself for a file `.asm` that a package imports. So the build environment keeps `nasm` in each case.
