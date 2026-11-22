type: Added

**The kernel for WebAssembly copies process memory and keeps time**: on a browser machine, the copy of the kernel with the memory of a process walks the page table of the process with the checks of a user access (present, user, write) on each page before the first byte moves, and a controller in software gives each processor its interrupts and a timer on the clock of the page. The kernel for WebAssembly exports only `entry`, `modus_processor_loop_run` and its memory, and in Node a boot record with a memory map starts it to the start of the root service.
