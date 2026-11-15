title: The debugger names the procedures of an outside module
date: 2026-11-15
release: next
picture: none
kind: Shown
guide: docs/MODULE_CONTRACT.md

A module built outside the repository runs on a machine from its data disk, with no new boot image. Its debug object now goes beside it on the disk, under the hash of the module, and the module file keeps its hash.

When the debugger attaches to such a program, it reads that debug object through the storage service, with a connection that reads only and that ends after the read. It uses the object only when the object names the hash of the module that runs.

The stack of the program then shows its procedures, its source files by the name of the folder of the developer, and its lines: `visitor::sleep_for_ever  outsider/main.odin    83`.
