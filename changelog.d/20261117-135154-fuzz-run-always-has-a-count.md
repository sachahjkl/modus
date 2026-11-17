type: Changed

**A fuzz run always has a count.** modustool fuzz with no count of executions runs the count of the check, and refuses a count of 0, so a forgotten argument never starts a run with no end. A long run names its count.
