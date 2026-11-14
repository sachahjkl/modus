title: The tool builds a module of another project
date: 2026-11-14
release: next
picture: none
kind: Shown
guide: docs/TOOLS.md

A module for the system can now be written in a folder of another project. The folder holds one Odin package and one small file, `module.txt`. The file gives the name of the module, the modules that it imports, and two more fields, one `key: value` on each line. The sources import the packages of the system from one source library, `modus`, with the lines of a program of the system.

One command builds the module: `kerneltool module-build .`, with the folder of the system in the variable `MODUS_SYSTEM`. The build runs the steps of a module of the system, with the same checks. It writes the module file and its debug object in the folder of the project, and prints the hash of the module file, which is its identity.

The full check of the system builds two modules in this way, from copies of the program `tally` and of the module `agenda`, and compares each with the module of the system.

The tool does not yet put such a module in the boot image of a machine, so it does not yet run there.
