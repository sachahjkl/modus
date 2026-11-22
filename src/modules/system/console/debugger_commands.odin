package console

import "modus:contract/value_kinds"

// The commands of the debugger (docs/TOOLS.md, "The debugger"): each one
// is an export of the service `debugger`, under a short name. The console
// holds no state of the debugging and draws nothing here: the command
// connects to the service when the console has no connection to it yet,
// calls the export through the connection (`bound_call`), and the drawers
// of the console draw the table that the export gives.
//
// Four exports have a short name that is not their own, because the
// console has a command with that name already:
//
//   attach    debug         the word of the design: `debug("clock")`
//   release   resume        `release` closes a handle of the console
//   memory    debug_memory  `memory` gives the memory of the machine
//
// and `hold` is the name of the service too: `stop` stops a whole process.

debug_attach :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "attach", arguments)
}

debug_detach :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "detach", arguments)
}

debug_threads :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "threads", arguments)
}

debug_hold :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "hold", arguments)
}

debug_resume :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "release", arguments)
}

debug_continue_all :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "continue_all", arguments)
}

debug_registers :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "registers", arguments)
}

debug_stack :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "stack", arguments)
}

debug_locals :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "locals", arguments)
}

debug_value :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "value", arguments)
}

debug_source :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "source", arguments)
}

debug_break_at :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "break_at", arguments)
}

debug_breaks :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "breaks", arguments)
}

debug_break_remove :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "break_remove", arguments)
}

debug_watch :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "watch", arguments)
}

debug_step :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "step", arguments)
}

debug_step_over :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "step_over", arguments)
}

debug_step_line :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "step_line", arguments)
}

debug_memory :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "memory", arguments)
}

debug_events :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "events", arguments)
}

debug_wait_stop :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "wait_stop", arguments)
}

debug_stop_report :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "stop_report", arguments)
}

debug_record :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "record", arguments)
}

debug_replay_start :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "replay_start", arguments)
}

debug_record_start :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "record_start", arguments)
}

debug_record_end :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "record_end", arguments)
}

debug_replay_status :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "replay_status", arguments)
}

debug_replay_checkpoint :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "replay_checkpoint", arguments)
}

debug_replay_step_back :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "replay_step_back", arguments)
}

// debugger_commands_start lists the commands of the debugger. The comment
// above each command is its documentation on the site.
debugger_commands_start :: proc "contextless" () {
	// Makes the service `debugger` the debugger of a process for the
	// console, and gives one row: the process, its slot, its threads, its
	// modules and how many of them have a debug object. It is the export
	// `attach` of the service.
	//
	// - `process`: the name of a process that runs.
	//
	// The root service gives the debug access when the console acts for
	// the principal whose session runs the process, and when each grant of
	// the process is a grant that the console holds itself. A service is
	// refused. The grant is `debug` in `grants("console")`, and
	// `revoke("console", "debug")` ends it.
	//
	// ```
	// > debug("clock")
	// ```
	//
	// Errors: those of `connect("debugger")`, and those of the export.
	command("debug", {.Text}, .Table, "debug a process: debugger.attach()", debug_attach)
	// Ends the debugging: the process gets back each thread that the
	// debugger held, with no breakpoint. It gives one row: the process, the
	// breakpoints that the debugger had and the threads that it held.
	command("detach", {}, .Table, "end the debugging: debugger.detach()", debug_detach)
	// Gives one row for each thread of the debugged process: its number,
	// its state, and the instruction of a thread that is held or stopped,
	// with its procedure, its file and its line.
	command("threads", {}, .Table, "the threads of the debugged process: debugger.threads()", debug_threads)
	// Stops one thread of the debugged process, and gives its row. The
	// command `stop` stops a whole process by its name: this one holds one
	// thread, which runs again with `resume` or `continue_all`.
	//
	// - `thread`: the number of a thread, as `threads()` gives it.
	command("hold", {.Integer}, .Table, "hold one thread of the debugged process: debugger.hold()", debug_hold)
	// Lets one thread run again, and gives its row: a thread that `hold`
	// stopped, or that a breakpoint, a watch or a step stopped. It is the
	// export `release` of the service; `release` in the console closes a
	// handle.
	//
	// - `thread`: the number of a thread that is held or stopped.
	command("resume", {.Integer}, .Table, "let one thread of the debugged process run: debugger.release()", debug_resume)
	// Lets each thread of the debugged process run again, and gives one row
	// for each thread.
	command("continue_all", {}, .Table, "let each thread of the debugged process run: debugger.continue_all()", debug_continue_all)
	// Gives one row for each register of a held thread: the 16 general
	// registers, `rip` with its procedure and its line, and `rflags` with
	// the flags that are set.
	//
	// - `thread`: the number of a thread that is held or stopped.
	command("registers", {.Integer}, .Table, "the registers of a held thread: debugger.registers()", debug_registers)
	// Gives one row for each frame of the stack of a held thread: the
	// procedure, the file and the line of the instruction, then of each
	// call, with the frame pointer and the return address.
	//
	// - `thread`: the number of a thread that is held or stopped.
	command("stack", {.Integer}, .Table, "the frames of the stack of a held thread: debugger.stack()", debug_stack)
	// Gives one row for each parameter and each local variable that is
	// visible at the instruction of a frame: its name, its role, its type,
	// its value or "not readable", and its location.
	//
	// - `thread`: the number of a thread that is held or stopped.
	// - `frame`: the number of a frame, as `stack` gives it.
	command("locals", {.Integer, .Integer}, .Table, "the variables of a frame: debugger.locals()", debug_locals)
	// Gives one variable or one global by a path, as one row for each of
	// its fields or of its elements.
	//
	// - `thread`, `frame`: as for `locals`. A global with its package
	//   (`debug_target::rounds`) needs no held thread.
	// - `path`: a name, then steps: `.field`, `[number]`, `^`.
	//
	// ```
	// > value(0, 0, "pair.next^.first")
	// ```
	command("value", {.Integer, .Integer, .Text}, .Table, "a variable or a global, by a path: debugger.value()", debug_value)
	// Gives the source line of the instruction of a frame: its number, the
	// path of its file and the hash of that file at the build. The system
	// holds no source text; `modustool call` shows the line on the host
	// when the file of the repository has that hash.
	//
	// - `thread`, `frame`: as for `locals`.
	command("source", {.Integer, .Integer}, .Table, "the source line of a frame: debugger.source()", debug_source)
	// Sets an execute breakpoint, and gives one row for each breakpoint of
	// the debugger.
	//
	// - `place`: the full name of a procedure (`fault::three`), or a file
	//   and a line (`src/modules/demonstrations/fault/main.odin:15`).
	//
	// The debugger has four breakpoints, for breakpoints and watches
	// together.
	command("break_at", {.Text}, .Table, "a breakpoint at a procedure or at a line: debugger.break_at()", debug_break_at)
	// Gives one row for each breakpoint of the debugger.
	command("breaks", {}, .Table, "the breakpoints of the debugger: debugger.breaks()", debug_breaks)
	// Removes one breakpoint, and gives one row for each one that stays.
	//
	// - `number`: the number of a breakpoint, as `breaks()` gives it.
	command("break_remove", {.Integer}, .Table, "remove a breakpoint: debugger.break_remove()", debug_break_remove)
	// Sets a data breakpoint on bytes that the process writes, and gives
	// one row for each breakpoint of the debugger.
	//
	// - `place`: an address (`0x403010`), or the path of a global with its
	//   package.
	// - `length`: 1, 2, 4 or 8 bytes.
	command("watch", {.Text, .Integer}, .Table, "stop at a write of some bytes: debugger.watch()", debug_watch)
	// Runs one instruction of a thread that is held or stopped, and gives
	// its row at its new instruction.
	//
	// - `thread`: the number of a thread that is held or stopped.
	command("step", {.Integer}, .Table, "one instruction of a held thread: debugger.step()", debug_step)
	// Runs a thread that is held or stopped until the source line of its
	// instruction changes, and gives its row there.
	//
	// - `thread`: the number of a thread that is held or stopped.
	command("step_line", {.Integer}, .Table, "a held thread, to its next source line: debugger.step_line()", debug_step_line)
	// Runs a thread that is held or stopped to the next source line of its
	// procedure, and gives its row there: a call of the line runs to its
	// end, and the thread does not stop inside it.
	//
	// - `thread`: the number of a thread that is held or stopped.
	command("step_over", {.Integer}, .Table, "a held thread, to its next source line, over each call: debugger.step_over()", debug_step_over)
	// Gives the bytes of the debugged process from an address, sixteen in
	// each row. It is the export `memory` of the service; `memory` in the
	// console gives the memory of the machine.
	//
	// - `place`: an address (`0x403010`), or the path of a global with its
	//   package.
	// - `count`: 1 to 4096 bytes.
	command("debug_memory", {.Text, .Integer}, .Table, "the bytes of the debugged process: debugger.memory()", debug_memory, {{}, value_kinds.size_in(.Bytes)})
	// Gives one row for each stop of a thread since the last call: the
	// thread, the kind (`breakpoint N`, `watch N`, `step`), and the
	// instruction with its procedure and its line.
	command("events", {}, .Table, "the stops of the debugged process: debugger.events()", debug_events)
	// Waits until a thread of the debugged process stops, at most the
	// given milliseconds (3000 at most), and gives the rows of
	// `events`.
	//
	// - `milliseconds`: the longest wait.
	command("wait_stop", {.Integer}, .Table, "wait for a stop of the debugged process: debugger.wait_stop()", debug_wait_stop, {value_kinds.time_in(.Milliseconds)})
	// Gives one row for each frame of the stop report of a disk process
	// that stopped on a fault: the module, the procedure, the file and the
	// line, from the debug object of its module in the store `module_files`.
	// It needs no `debug`: the process stopped, and the root service kept
	// its report. Row 0 also says what stopped it.
	//
	// - `process`: the nickname of the disk process.
	//
	// ```
	// > stop_report("visitor")
	// ```
	command("stop_report", {.Text}, .Table, "the frames of a disk process that faulted, named: debugger.stop_report()", debug_stop_report)
	// Starts a process held before its first instruction, makes the
	// service `debugger` its debugger for the console, records each
	// process input of it from that instruction, then lets it run. It
	// gives the row of the record: its state, its input points, its bytes,
	// why it ended, its checkpoints, and the input point of a divergence.
	// Memory that the process and another process both write is recorded
	// too: the other process writes only while the process is at an input
	// point.
	//
	// - `process`: the name of a module of the boot image.
	//
	// The root service starts the module for the console, as `start`
	// does, under the rule of `debug`.
	//
	// ```
	// > record("clock")
	// ```
	command("record", {.Text}, .Table, "start a process recorded from its first instruction: debugger.record()", debug_record)
	// Asks the kernel to write each process input of the debugged process
	// into an input history, and gives the row of the record. The kernel
	// records only a process that did not run yet: `record` starts one.
	//
	// ```
	// > record_start()
	// ```
	command("record_start", {}, .Table, "record the inputs of the debugged process: debugger.record_start()", debug_record_start)
	// Ends the record of the debugged process, and gives the row of the
	// record with why it ended. The history and its checkpoints stay until
	// the next record, after the end of the debugging too.
	command("record_end", {}, .Table, "end the record of the debugged process: debugger.record_end()", debug_record_end)
	// Runs the recorded module again from the history, and gives the row
	// of the record: `replaying`, then `replayed` with why the replay
	// ended. The replay reaches the same instructions with the same
	// values, or stops at the first difference, whose input point is in
	// the row. A replay sends nothing to any process.
	//
	// ```
	// > replay_start()
	// ```
	command("replay_start", {}, .Table, "run the recorded module again from its history: debugger.replay_start()", debug_replay_start)
	// Gives the row of the record of the console, also after the kernel
	// ended it by itself (the process stopped, the history is full, the
	// bound of one stint, a revocation) and after the debugging ended.
	command("replay_status", {}, .Table, "the record of the debugged process: debugger.replay_status()", debug_replay_status)
	// Keeps a checkpoint of a held thread at the last input point of the
	// record, and gives one row for each checkpoint: its number, its input
	// point, the bytes of the history before it, the instruction and the
	// stack pointer of the thread.
	//
	// - `thread`: the number of a thread that is held or stopped.
	command("replay_checkpoint", {.Integer}, .Table, "a checkpoint of a held thread: debugger.replay_checkpoint()", debug_replay_checkpoint)
	// Gives the way back by some input points: the nearest checkpoint at
	// or before the target point, and the input points that a replay runs
	// from it to reach that point.
	//
	// - `points`: the input points to go back, from 1.
	//
	// ```
	// > replay_step_back(1)
	// ```
	command("replay_step_back", {.Integer}, .Table, "the checkpoint and the points of a step back: debugger.replay_step_back()", debug_replay_step_back)
}
