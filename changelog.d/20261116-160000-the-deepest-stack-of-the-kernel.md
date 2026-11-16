type: Added

**The deepest stack of the kernel, measured.** Each build prints the deepest chain of calls on the kernel stack of 16 pages, procedure by procedure, with the bytes that stay free, from the frames that `llc` writes and the calls of the linked kernel. It counts the two frames of `execute` of a command with a table of error details and one interrupt over the idle wait, and the build fails when less than 4 pages stay free.
