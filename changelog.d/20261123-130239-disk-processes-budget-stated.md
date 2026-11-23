type: Changed

**The budget of the disk processes is stated.** All disk processes share 128 MiB, 4 processes and 16 threads, and one of them gets at most 64 MiB, on every machine: the budget never returns to the root service, so it no longer grows with the memory of the machine. The share of the machine for the largest budget of a process of the boot image has one border in the root service for a value of the plan of principal 0, from 1 to 64; no plan gives it yet, so it stays a quarter.
