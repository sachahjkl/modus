type: Changed

**The kernel tables sized from the memory of the machine.** The kernel takes its tables once at its start, from the usable memory: one process slot for each 4 MiB, from 64 to 1024, with 4 threads and 64 memory objects for each slot. A machine of 1 GiB has 256 process slots, 1024 threads and 16384 memory objects for 47.9 MiB of tables, 4.7 % of its memory; a machine of 4 GiB or more has 1024 process slots. A log record names a process slot in two bytes, and `Inspect` gives the slots of the machine in `System_Report.process_slots`.
