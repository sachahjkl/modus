type: Changed

**The full weight of a thread is 8192.** A weight is from 1 to 8192, in place of 1024, so a process of 256 threads still divides a process weight of 1/32 of the full weight between its threads. The process weight of `scheduler.share` is from 256 to 8192, and 8192 for a process with no setting: `scheduler.share("paint", 2048)` gives a quarter. Under the share policy a new thread has the process weight divided by 256, 32 for a process of the full weight.
