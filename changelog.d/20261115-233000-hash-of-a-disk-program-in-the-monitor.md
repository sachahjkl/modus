type: Added

**The hash of a disk program in the exports of the monitor.** Each row of `monitor.programs()`, and of `programs()` in the console, has a new field `hash`: for a program that the root service started from a disk, the whole BLAKE3 hash of its module file in 64 hexadecimal digits, from the disk program page, with its nickname as its `name`; for each other program, an empty text. The console and the host then read the file of a disk program that the window of the monitor shows, and `join` it with the rows of `manual.running()` by the hash.
