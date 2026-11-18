type: Fixed

**The kind 0 names no operation**: a command record of the kind 0 (`None`) is now refused with `Bad_Operation` and the error record `Unknown_Operation`, as a kind past the last operation is. The kernel answered `Ok` to it before, so a command record that a process never filled passed as a success.
