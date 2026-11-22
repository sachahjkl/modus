type: Fixed

**A guest build counts only the exits of its guest**: the interrupts of the timer of the host no longer count toward the bound of exits of the spec, no longer end a build after 1000 in a row, and no longer change the count of exits of the report, so two builds of one spec report the same count on a slow or a fast machine.
