type: Added

**The background work of a window.** `interface.Background_Work` runs a call that waits for another process on a worker thread, one job at a time, and wakes the loop of the window at its end. `paint` keeps its pictures and `clock` posts its notification through it, so neither window stops drawing while the store or the compositor answers.
