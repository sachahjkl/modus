title: A program from the disk imports a library from the same store
date: 2026-11-15
release: next
picture: none
kind: Shown
guide: docs/MODULE_CONTRACT.md

A program and its library modules can now reach a machine that runs, with no new boot image. Put both files in the store of the programs, under any names. `start_from_disk("store_importer", hash)` then starts the program with its library.

The import of the program names the hash of the library, not a name. The root service reads each file of the store, computes the hash of its bytes, and gives the loader the file whose hash the import names. The imports of that library are found the same way.

A file with other bytes under the name of the library does not run: the start is refused, and the log names the hash that no file has.
