type: Added

**The record and the replay of one thread at its kernel entries.** A replay now also checks how its process stops: a process that stops where its input history goes on, or a history that ended for another reason than the stop of the process, is a divergence at that input point. Each divergence names its exact input point, also at a damaged or missing record, and `replay_status()` shows what differed, the value of the history, the value of the replay, and the instruction address of the record there. The machine test of the debugger records a process and replays it to the same end.
