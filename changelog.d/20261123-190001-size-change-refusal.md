type: Fixed

**A refused change of record size changes nothing.** When the memory of the new space or the write of the index is refused, the old space of a module stays open with its records, and takes the next ones.
