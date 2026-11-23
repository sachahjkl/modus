type: Added

**A screen of memory that grows.** A viewer asks a screen of memory larger than its start size, and the root service gives the compositor and `remote_display` the pages of that size at the same step, within the share of a process, or refuses both with the cause; the pages return when the size comes back to at most the start size, or when either process stops. One growth at a time: a larger size again waits for a size at most the start size, and gets the cause `Grown_Already`.
