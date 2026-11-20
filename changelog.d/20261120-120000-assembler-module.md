type: Added

**An assembler module.** The module `assemble` reads a subset of x86-64 assembly in the syntax of AT&T, with an `export` directive that gives the types of each export, and writes a module file into a memory object that its caller lends; a text that it does not assemble whole is refused with its line and its column. The console command `isolate_memory(name, memory, size)` isolates the module that such an object holds, so `add(2, 3)` of a module assembled in the console gives 5.
