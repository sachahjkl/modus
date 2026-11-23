type: Changed

**More threads in one process.** A process holds 256 threads, in place of 32, and a thread report gives all of them. The stack of the first thread starts at `0x7FFF_FFBD_D000`, below the 256 thread areas.
