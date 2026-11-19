type: Changed

**The table of the processes starts its service**: `processes()` works at once in each start policy, the rescue included, because the root service starts `monitor` at its first connection; `start("monitor")` is no longer needed first.
