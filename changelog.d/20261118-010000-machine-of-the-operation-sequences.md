type: Added

**The machine of the operation sequences**: the test part `operation_sequences` runs a seed sequence of each kernel operation, and the seed cases, on the kernel that ships, each in a new program with a new budget, and checks each answer against the statuses of the reference, the forms of the operations, the table of error details and the budget of the sequence. `modustool fuzz replay operations <file>` runs one sequence the same way.
