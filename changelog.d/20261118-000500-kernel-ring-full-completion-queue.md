type: Fixed

**A command push that the ring refuses is never ignored.** A thread that leaves the completion queue of its kernel ring full loses no answer: the kernel leaves the next command unrun in the command queue and returns with no wait, then runs it after the thread reads its completions. A kernel call of `src/library/support/system` on a kernel ring that holds other records gives `Bad_Operation` with the error record `Busy` and does not run, and an answer with another tag than its command gives `Refused`.
