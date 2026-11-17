type: Changed

**The host tests of the check at once.** `modustool check` runs the host tests of each folder at the same time as the others, at most one process for each processor, and writes the log of each folder to `build/host_tests/`. It prints the time of each folder as a measure, and for a folder that fails the end of its log.
