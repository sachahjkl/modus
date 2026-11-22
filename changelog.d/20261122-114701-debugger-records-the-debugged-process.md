type: Added

**The debugger records the debugged process.** `record_start()`, `record_end()`, `replay_status()`, `replay_checkpoint(thread)` and `replay_step_back(points)`, as exports of `debugger` and as console commands, ask the kernel to write the input history of the attached process, show its input points, its bytes and why it ended, keep checkpoints of a held thread, and give the nearest checkpoint and the input points of a step back; each refusal of the kernel, such as a process that ran already, is the error record of the export.
