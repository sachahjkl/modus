type: Changed

**No wait on device memory.** `Word_Wait` and `Word_Wake` refuse a word of a memory object of a device with `Bad_Address`, and the error record has `found` 2. No service of the system waits on a register: each waits on its rings and its interrupt events.
