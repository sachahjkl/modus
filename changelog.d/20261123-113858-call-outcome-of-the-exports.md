type: Changed

**The call outcome of the exports.** Each export that can fail gives its call outcome first and its value second, and the compiler makes each caller read the outcome: one word says whether the call succeeded, what it did to the state and what to do next, and a negative value is only a value. The console writes a failure as `error: <export>: <outcome>: <sentence>`, `modustool call` writes the same line, and the storage service answers with the same outcomes in place of its own negative numbers. A module in C includes `modus_call_outcome.h` and returns the pair `Modus_Answer`.
