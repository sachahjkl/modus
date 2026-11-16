type: Fixed

**A log record is never read half written.** A reader of the log, the window `log` and `log.records` included, could keep a copy of the oldest record of the ring while the kernel wrote the next record over it: the head of one record with the text of another. Such a record now counts as lost, as the records that the kernel wrote over do, so a reader copies the last 2046 records at most.
