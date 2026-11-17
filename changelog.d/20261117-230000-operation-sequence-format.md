type: Added

**The format of the operation sequences and their generator**: the contract package `operation_sequence` gives the format of the fuzz input of the kernel operations, whose reader refuses each damaged sequence with its problem and its step, its area or its argument. `modustool fuzz` and the fuzz check of `modustool check` have two new targets: `operation_sequence` gives hostile bytes to that reader, and `operation_sequence_generated` checks that each sequence that the tool builds from the forms of the kernel operations is one that the reader accepts.
