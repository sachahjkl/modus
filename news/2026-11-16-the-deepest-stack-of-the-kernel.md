title: Each build measures the deepest stack of the kernel
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/TOOLS.md

Each processor of modus runs the kernel on a stack of 16 pages, with a guard page under it. A chain of calls that is deeper stops the machine at that page.

Each build now reads the frame of each procedure of the kernel, which LLVM writes, and the calls of the linked kernel. It prints the deepest chain of calls on that stack, procedure by procedure, with the bytes that stay free. The chain counts the two frames of `execute` of a command with a table of error details, and one interrupt that comes while the kernel waits idle.

The build fails when less than 4 of the 16 pages stay free. A call that the tool cannot follow, or a recursion with no stated bound, also stops the build, with the name of the procedure.
