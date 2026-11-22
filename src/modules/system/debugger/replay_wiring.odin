// Live input-history recording and reverse-step checkpoint tracking integrated
// into the debugger service (src/md/features/record_and_replay.md).
package debugger

import "modus:contract/input_history"

REPLAY_HISTORY_CAPACITY :: 16384
REPLAY_MAX_CHECKPOINTS :: 16

Replay_Checkpoint :: struct {
	active:       bool,
	record_index: u64,
	rip:          u64,
	rsp:          u64,
}

debugger_replay_buffer: [REPLAY_HISTORY_CAPACITY]u8
debugger_replay_writer: input_history.History_Writer
debugger_replay_active: bool
debugger_checkpoints: [REPLAY_MAX_CHECKPOINTS]Replay_Checkpoint
debugger_checkpoint_count: int

debugger_replay_begin :: proc "contextless" (module_hash: [32]u8, cycle_freq, cycle_start, xcr0: u64) -> bool {
	writer, ok := input_history.history_writer_init(debugger_replay_buffer[:], module_hash, cycle_freq, cycle_start, xcr0)
	if !ok {
		return false
	}
	debugger_replay_writer = writer
	debugger_replay_active = true
	debugger_checkpoint_count = 0
	return true
}

debugger_replay_checkpoint :: proc "contextless" (record_index, rip, rsp: u64) -> bool {
	if !debugger_replay_active || debugger_checkpoint_count >= REPLAY_MAX_CHECKPOINTS {
		return false
	}
	debugger_checkpoints[debugger_checkpoint_count] = {
		active       = true,
		record_index = record_index,
		rip          = rip,
		rsp          = rsp,
	}
	debugger_checkpoint_count += 1
	return true
}

// debugger_replay_step_back_target returns the nearest checkpoint strictly
// before current_record so the debugger can replay forward to step backwards.
debugger_replay_step_back_target :: proc "contextless" (current_record: u64) -> (cp: Replay_Checkpoint, found: bool) {
	for i := debugger_checkpoint_count - 1; i >= 0; i -= 1 {
		if debugger_checkpoints[i].active && debugger_checkpoints[i].record_index < current_record {
			return debugger_checkpoints[i], true
		}
	}
	return {}, false
}
