type: Added

**A frozen time stamp counter in a guest.** `rdtsc` and `rdtscp` of a guest exit to its process as an exit `Other` (codes 0x6E and 0x87) with the next instruction, and the machine of a Linux guest answers them from its virtual clock, so a build in a guest reads no time of the machine and no processor number.
