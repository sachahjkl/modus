type: Added

**A repair of the count tree that pauses the changes.** When a leaf of the count tree of a large disk has a wrong check, the storage service serves the reads and answers each change with `Busy` (-14, unit `Count_Repair`, with the stores walked and the stores in all) while it counts the names of its blocks again, then writes the leaves in one commit and takes changes again; a loss of power during the repair starts it again at the next start.
