type: Security

**A log ring for each program.** The kernel keeps the last 64 log records of each program in a ring that only that program fills, paid by its own budget, and the log service reads the own records of a caller there with the new kernel operation `Log_Read` (the kernel has 35 operations). A log storm of one program no longer pushes out the records of another, so a reader of its own records learns nothing of how many records the other programs wrote; the whole log keeps every record, in order, for a reader that acts for the principal.
