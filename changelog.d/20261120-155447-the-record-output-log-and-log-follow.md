type: Added

**The whole log of a process, kept, and the whole log as it comes**: a starter wires the record output `log` of its child in the list of its start, and the reader then receives each log record of the child from the first one, while the kernel log still refuses what passes its budget of each second; a reader that acts for the principal wires `log.follow` and receives each record of the whole log as it comes, with one gap record where the kernel wrote over records before the log service passed them on.
