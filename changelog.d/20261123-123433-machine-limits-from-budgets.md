type: Changed

**A machine runs hundreds of processes, and a large program gets a share of the memory.** The largest budget of a process of the boot image is a quarter of the memory and of the threads of the machine, at least 64 MiB, in place of 64 MiB for every machine. Each process holds 1024 handles and 1024 mappings, the root service holds 256 connections, the compositor holds 96 windows, and a start list holds 256 rows.
