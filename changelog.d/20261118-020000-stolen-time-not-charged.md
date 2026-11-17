type: Fixed

**A budget no longer pays for the time that the host took.** Under KVM the kernel reads the steal time of each processor and no longer charges a thread, its budgets or its strategy for the time in which the host ran no code of that processor. On a loaded host, the program `limits` read 327 ms used by a budget with a limit of 50 ms in one second, and its check failed. The boot line `kernel: steal time:` says how many processors registered, or why none did.
