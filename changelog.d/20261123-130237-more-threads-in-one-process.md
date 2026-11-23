type: Changed

**More threads in one process.** A process holds 256 threads, in place of 32, and a thread report gives all of them. The stack of the first thread starts at `0x7FFF_FFBD_D000`, below the 256 thread areas. The least process weight of `scheduler.share` is 256, so that each of 256 threads keeps a weight of 1 or more, and the new-thread weight limit under the share policy is the process weight divided by 256.
