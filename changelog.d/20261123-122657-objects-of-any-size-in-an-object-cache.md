type: Added

**Objects of any size in an object cache.** `cache-serve`, `cache-put` and `cache-get` carry a blob of any size, such as a release disk or the kernel of a guest, in frames of 1 MiB, and each side checks each frame against the BLAKE3 hash of the whole blob, so a blob keeps its one name. The bound of 16 MiB on one object is gone: each side holds a few frames in memory, whatever the size of the object, and `cache-get` of a blob to a file resumes after an interruption. The protocol is now version 2, and a server or a client of version 1 is refused.
