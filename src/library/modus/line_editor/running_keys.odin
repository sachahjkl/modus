package line_editor

// The keys that come while a line runs.
//
// The process that owns the edit line keeps each key that the input types
// while a line runs, in the order of the keys, and acts on them when the
// line ends: the keys then mean what they mean when typed slowly. One key
// can act at once: Escape, when the line waits in a call that Escape can
// stop. Escape with no such call is a key of the next line as each other
// key: it closes the list that the keys before it opened.
//
// The state of the line changes in another thread: the call that Escape
// can stop ends when it ends. The process reads that state once for each
// key (`Running_Line`), and both decisions on the key, to take it and what
// it does, use that one read. With two reads, a call that ended between
// them made the process take a key because Escape could act, then drop it
// because Escape could not: an Enter or an Escape was lost while the key
// could stay in the queue.

// What the process does with a key that comes while a line runs.
Running_Key_Action :: enum u8 {
	Wait      = 0, // The key waits for the end of the line, after the keys before it.
	Stop_Call = 1, // The key stops the call that the line waits in.
	Drop      = 2, // No room, and the process reads on to find an Escape (`running_key_can_be_taken`): the key is lost, and the process counts it.
}

// One read of the state of the line, for one key.
Running_Line :: struct {
	runs:           bool, // A line runs.
	call_stoppable: bool, // The line waits in a call that Escape can stop.
	stop_asked:     bool, // An Escape already asked that call to stop.
}

// running_key_can_be_taken says if the process takes the next key from its
// queue. With no line running, and while a line runs with a place for the
// key, yes. With no place, only while the line waits in a call that an
// Escape can still stop: the process must read each key to find that
// Escape, and a key that is not Escape is then lost (`Drop`). In each other
// case the key stays in the queue of the process, in order, and nothing is
// lost: the full queue then stops its writer or is the stated bound of the
// keys typed ahead.
running_key_can_be_taken :: proc "contextless" (line: Running_Line, waiting: int, capacity: int) -> bool {
	if !line.runs {
		return true
	}
	return waiting < capacity || line.call_stoppable && !line.stop_asked
}

// running_key_action says what a key does while a line runs, from the same
// read of the line that took the key.
//   escape:   the key is Escape.
//   waiting:  the keys that wait; capacity: the most that can wait.
running_key_action :: proc "contextless" (escape: bool, line: Running_Line, waiting: int, capacity: int) -> Running_Key_Action {
	if escape && line.call_stoppable {
		return .Stop_Call
	}
	return waiting < capacity ? .Wait : .Drop
}

// The keys that wait for the end of a line, in the order of the keys.
Waiting_Keys :: struct($Key: typeid, $CAPACITY: int) {
	keys:  [CAPACITY]Key,
	count: int,
}

// waiting_keys_add keeps a key after the others. false: no place.
waiting_keys_add :: proc "contextless" (waiting: ^Waiting_Keys($Key, $CAPACITY), key: Key) -> bool {
	if waiting.count >= CAPACITY {
		return false
	}
	waiting.keys[waiting.count] = key
	waiting.count += 1
	return true
}

// waiting_keys_take_first gives the oldest key that waits. false: none.
waiting_keys_take_first :: proc "contextless" (waiting: ^Waiting_Keys($Key, $CAPACITY)) -> (key: Key, ok: bool) {
	if waiting.count <= 0 {
		return {}, false
	}
	key = waiting.keys[0]
	copy(waiting.keys[:], waiting.keys[1:waiting.count])
	waiting.count -= 1
	return key, true
}

// What the thread that runs the lines does next.
Line_Thread_Work :: enum u8 {
	Run_Line        = 0, // A line waits: it runs first.
	Palette_Getters = 1, // No line waits, and the getters of the palette were asked.
	History_Save    = 2, // No line waits, and the line history has a line whose commit no save tried.
	Wait            = 3, // Nothing to do: the thread waits for a line or a request.
}

// line_thread_work_choose chooses the next work of the thread that runs
// the lines. A line that the principal entered never waits for the
// getters of the palette or for a save of the line history: a save is a
// call of the storage service, which a loaded host can make slow. The
// getters come before the save, so the mark of a choice does not wait for
// a commit.
line_thread_work_choose :: proc "contextless" (line_waits: bool, getters_asked: bool, save_owed: bool) -> Line_Thread_Work {
	switch {
	case line_waits:
		return .Run_Line
	case getters_asked:
		return .Palette_Getters
	case save_owed:
		return .History_Save
	}
	return .Wait
}

// history_save_owed says if the line history has lines whose commit no
// save tried: lines_written counts the lines added to the history,
// lines_tried the lines whose commit was tried. A save makes one commit
// for one line, so the commits count the lines whatever the speed of the
// host; a failed save sets lines_tried to lines_written, and the commits
// owed wait for the next line, not a loop.
history_save_owed :: proc "contextless" (lines_written: u64, lines_tried: u64) -> bool {
	return lines_written != lines_tried
}
