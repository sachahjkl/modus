#+build !freestanding
#+build !modus
package line_editor

import "core:testing"

// A deterministic model of the two threads of a process that owns an edit
// line (the console, src/modules/system/console/main.odin), driven by a
// seeded generator: bursts of keys through a small queue that the typist
// fills to its end, a line that ends while keys arrive, a call that
// Escape can stop and that ends between the read of the line and the
// action on the key, and saves of the line history that are slow or fail.
// Each turn of the first thread reads the line once, as the console does.

Model_Key :: struct {
	character: rune, // 0: a key with no character (Enter, Escape).
	enter:     bool,
	escape:    bool,
}

MODEL_QUEUE_CAPACITY :: 8 // The queue of the terminal: small, so its end is reached often.
MODEL_WAITING_CAPACITY :: 4 // The keys that wait for the end of a line: small, so it is full often.
MODEL_LINES :: 400
MODEL_LINE_TEXT :: 6

Model_Generator :: struct {
	state: u64,
}

model_next :: proc(generator: ^Model_Generator, bound: u64) -> u64 {
	// xorshift64: a fixed sequence for each seed, so a failure runs again.
	generator.state ~= generator.state << 13
	generator.state ~= generator.state >> 7
	generator.state ~= generator.state << 17
	return generator.state % bound
}

Model :: struct {
	generator:        Model_Generator,
	stoppable_calls:  bool, // The lines may wait in a call that Escape can stop.
	// The typist and the queue of the terminal.
	typed:            [dynamic]string, // Each line with text, in the order of its Enter.
	keys_to_type:     [dynamic]Model_Key,
	typed_count:      int,
	queue:            [MODEL_QUEUE_CAPACITY]Model_Key,
	queue_read:       u64,
	queue_written:    u64,
	// The first thread.
	running:          bool,
	edit:             [dynamic]u8,
	waiting:          Waiting_Keys(Model_Key, MODEL_WAITING_CAPACITY),
	entered:          [dynamic]string,
	dropped:          int,
	escapes_dropped:  int,
	drops_that_could_stay: int,
	// The state that both threads share.
	started:          u32,
	finished:         u32,
	call_stoppable:   bool,
	stop_asked:       bool,
	history_lines:    u64,
	// The thread that runs the lines.
	done:             u32,
	ran:              [dynamic]string,
	work:             Line_Thread_Work,
	busy:             int,
	history_tried:    u64,
	saves:            int,
	saves_with_a_line_waiting: int,
	saves_failed:     int,
}

model_queue_push :: proc(model: ^Model) {
	for model.typed_count < len(model.keys_to_type) && model.queue_written - model.queue_read < MODEL_QUEUE_CAPACITY {
		model.queue[model.queue_written % MODEL_QUEUE_CAPACITY] = model.keys_to_type[model.typed_count]
		model.queue_written += 1
		model.typed_count += 1
		if model_next(&model.generator, 3) == 0 {
			break // The end of a burst.
		}
	}
}

model_queue_pop :: proc(model: ^Model) -> (key: Model_Key, ok: bool) {
	if model.queue_read == model.queue_written {
		return {}, false
	}
	key = model.queue[model.queue_read % MODEL_QUEUE_CAPACITY]
	model.queue_read += 1
	return key, true
}

// model_key acts on a key while no line runs, as console.key does.
model_key :: proc(model: ^Model, key: Model_Key) {
	switch {
	case key.enter:
		if len(model.edit) > 0 {
			append(&model.entered, string(model.edit[:]))
			model.edit = make([dynamic]u8, context.temp_allocator)
			model.history_lines += 1
			model.stop_asked = false
			model.running = true
			model.started += 1
		}
	case key.escape:
		// No list in this model: Escape changes nothing of the line.
	case:
		append(&model.edit, u8(key.character))
	}
}

// model_line_thread_step runs one step of the thread that runs the lines.
model_line_thread_step :: proc(model: ^Model) {
	if model.busy > 0 {
		model.busy -= 1
		// Escape asked the call to stop: it ends at its next step.
		if model.stop_asked && model.call_stoppable {
			model.busy = 0
		}
		if model.busy > 0 {
			return
		}
		switch model.work {
		case .Run_Line:
			model.call_stoppable = false
			model.finished = model.done
		case .History_Save, .Palette_Getters, .Wait:
		}
		model.work = .Wait
		return
	}
	line_waits := model.started != model.done
	model.work = line_thread_work_choose(line_waits, false, history_save_owed(model.history_lines, model.history_tried))
	switch model.work {
	case .Run_Line:
		model.done += 1
		append(&model.ran, model.entered[model.done - 1])
		model.call_stoppable = model.stoppable_calls && model_next(&model.generator, 2) == 0
		model.busy = 1 + int(model_next(&model.generator, 6))
	case .History_Save:
		if line_waits {
			model.saves_with_a_line_waiting += 1
		}
		model.saves += 1
		// One commit for one line; a failed commit gives up the commits
		// owed until the next line.
		if model.stoppable_calls && model_next(&model.generator, 4) == 0 {
			model.history_tried = model.history_lines
			model.saves_failed += 1
		} else {
			model.history_tried += 1
		}
		model.busy = 1 + int(model_next(&model.generator, 8)) // A slow store.
	case .Palette_Getters, .Wait:
	}
}

model_completed_line_finish :: proc(model: ^Model) -> bool {
	if !model.running || model.finished != model.started {
		return false
	}
	model.running = false
	for !model.running {
		key := waiting_keys_take_first(&model.waiting) or_break
		model_key(model, key)
	}
	return true
}

// model_first_thread_turn is one turn of the loop of the console.
model_first_thread_turn :: proc(model: ^Model) {
	for {
		for {
			_ = model_completed_line_finish(model)
			// One read of the line for this key: the two decisions use it.
			line := Running_Line{runs = model.running, call_stoppable = model.call_stoppable, stop_asked = model.stop_asked}
			if !running_key_can_be_taken(line, model.waiting.count, MODEL_WAITING_CAPACITY) {
				break
			}
			key := model_queue_pop(model) or_break
			// The other thread runs between the read and the action: the call
			// can end here.
			if model_next(&model.generator, 2) == 0 {
				model_line_thread_step(model)
			}
			if !line.runs {
				model_key(model, key)
				continue
			}
			switch running_key_action(key.escape, line, model.waiting.count, MODEL_WAITING_CAPACITY) {
			case .Stop_Call:
				model.stop_asked = true
			case .Wait:
				waiting_keys_add(&model.waiting, key)
			case .Drop:
				model.dropped += 1
				if key.escape {
					model.escapes_dropped += 1
				}
				// The read that took the key said that no Escape could act:
				// the key could have stayed in the queue.
				if !line.call_stoppable || line.stop_asked {
					model.drops_that_could_stay += 1
				}
			}
		}
		if model_completed_line_finish(model) && !model.running {
			continue
		}
		break
	}
}

model_run :: proc(t: ^testing.T, seed: u64, stoppable_calls: bool) -> Model {
	model := Model{generator = {seed}, stoppable_calls = stoppable_calls}
	model.edit = make([dynamic]u8, context.temp_allocator)
	model.typed = make([dynamic]string, context.temp_allocator)
	model.keys_to_type = make([dynamic]Model_Key, context.temp_allocator)
	model.entered = make([dynamic]string, context.temp_allocator)
	model.ran = make([dynamic]string, context.temp_allocator)
	for line_number in 0 ..< MODEL_LINES {
		text := make([dynamic]u8, context.temp_allocator)
		for _ in 0 ..< model_next(&model.generator, MODEL_LINE_TEXT) {
			character := rune('a' + model_next(&model.generator, 26))
			append(&text, u8(character))
			append(&model.keys_to_type, Model_Key{character = character})
		}
		// Escape inside a line, while the line before can still run.
		if model_next(&model.generator, 4) == 0 {
			append(&model.keys_to_type, Model_Key{escape = true})
		}
		append(&model.keys_to_type, Model_Key{enter = true})
		if len(text) > 0 {
			append(&model.typed, string(text[:]))
		}
		_ = line_number
	}
	for turn := 0; turn < 1_000_000; turn += 1 {
		model_queue_push(&model)
		model_first_thread_turn(&model)
		model_line_thread_step(&model)
		finished := model.typed_count == len(model.keys_to_type) && model.queue_read == model.queue_written && !model.running && model.waiting.count == 0 && model.busy == 0 && model.started == model.done
		if finished && !history_save_owed(model.history_lines, model.history_tried) {
			break
		}
	}
	return model
}

@(test)
typed_lines_all_run_in_order_through_bursts_full_queues_and_line_ends :: proc(t: ^testing.T) {
	for seed in u64(1) ..= 64 {
		model := model_run(t, seed * 0x9E3779B97F4A7C15, false)
		testing.expectf(t, model.dropped == 0, "seed %d: %d keys dropped with no call that Escape can stop", seed, model.dropped)
		testing.expectf(t, len(model.entered) == len(model.typed), "seed %d: %d lines entered of %d typed", seed, len(model.entered), len(model.typed))
		testing.expectf(t, len(model.ran) == len(model.typed), "seed %d: %d lines ran of %d typed", seed, len(model.ran), len(model.typed))
		for text, index in model.typed {
			if index < len(model.ran) && model.ran[index] != text {
				testing.expectf(t, false, "seed %d: line %d ran %q, typed %q", seed, index, model.ran[index], text)
				break
			}
		}
		testing.expectf(t, model.saves_with_a_line_waiting == 0, "seed %d: %d saves started while a line waited", seed, model.saves_with_a_line_waiting)
		testing.expectf(t, model.saves == len(model.typed), "seed %d: %d commits for %d lines: one commit for each line, whatever the order", seed, model.saves, len(model.typed))
	}
}

@(test)
a_call_that_ends_between_the_read_and_the_action_drops_no_escape :: proc(t: ^testing.T) {
	for seed in u64(1) ..= 64 {
		model := model_run(t, seed * 0xD1B54A32D192ED03, true)
		testing.expectf(t, model.escapes_dropped == 0, "seed %d: %d Escape keys dropped", seed, model.escapes_dropped)
		testing.expectf(t, model.drops_that_could_stay == 0, "seed %d: %d keys dropped that could stay in the queue", seed, model.drops_that_could_stay)
		escapes_typed := 0
		for key in model.keys_to_type {
			escapes_typed += int(key.escape)
		}
		testing.expectf(t, escapes_typed > 0, "seed %d: the model typed no Escape", seed)
		// Each line that was entered ran, in order, and no save started
		// while a line waited.
		testing.expectf(t, len(model.ran) == len(model.entered), "seed %d: %d lines ran of %d entered", seed, len(model.ran), len(model.entered))
		testing.expectf(t, model.saves_with_a_line_waiting == 0, "seed %d: a save started while a line waited", seed)
		// A failed commit is not tried again in a loop: at most one commit
		// for each line.
		testing.expectf(t, model.saves <= len(model.entered), "seed %d: %d commits for %d lines", seed, model.saves, len(model.entered))
		testing.expectf(t, model.saves_failed > 0 || seed > 8, "seed %d: the model failed no save", seed)
	}
}

// The thread that runs the lines: a line comes before the getters and the
// save; the getters before the save; a failed save waits for a new line.
@(test)
a_waiting_line_runs_before_the_getters_and_the_save :: proc(t: ^testing.T) {
	testing.expect_value(t, line_thread_work_choose(true, true, true), Line_Thread_Work.Run_Line)
	testing.expect_value(t, line_thread_work_choose(true, false, true), Line_Thread_Work.Run_Line)
	testing.expect_value(t, line_thread_work_choose(false, true, true), Line_Thread_Work.Palette_Getters)
	testing.expect_value(t, line_thread_work_choose(false, false, true), Line_Thread_Work.History_Save)
	testing.expect_value(t, line_thread_work_choose(false, false, false), Line_Thread_Work.Wait)
	testing.expect(t, !history_save_owed(0, 0), "no line: no save")
	testing.expect(t, history_save_owed(3, 2), "a line that no save tried")
	testing.expect(t, !history_save_owed(3, 3), "a save that failed for 3 lines is not tried again before a fourth line")
	testing.expect(t, history_save_owed(0, max(u64)), "a cleared history after a count that wrapped")
}

@(test)
waiting_keys_keep_their_order_and_refuse_past_the_capacity :: proc(t: ^testing.T) {
	waiting: Waiting_Keys(int, 3)
	_, none := waiting_keys_take_first(&waiting)
	testing.expect(t, !none, "an empty list gives no key")
	testing.expect(t, waiting_keys_add(&waiting, 1))
	testing.expect(t, waiting_keys_add(&waiting, 2))
	testing.expect(t, waiting_keys_add(&waiting, 3))
	testing.expect(t, !waiting_keys_add(&waiting, 4), "one past the capacity is refused")
	testing.expect_value(t, waiting.count, 3)
	for expected in 1 ..= 3 {
		key, ok := waiting_keys_take_first(&waiting)
		testing.expect(t, ok)
		testing.expect_value(t, key, expected)
	}
	testing.expect_value(t, waiting.count, 0)
}

// When a line has already finished before the first thread drains a burst
// longer than MODEL_WAITING_CAPACITY, retiring the finished line before taking
// keys prevents drops and ensures Enter runs in the same turn instead of
// staying in the terminal ring.
@(test)
line_that_ends_before_long_burst_runs_enter_in_one_turn :: proc(t: ^testing.T) {
	model := Model{
		generator = {1},
		running   = true,
		started   = 1,
		finished  = 1,
		done      = 1,
	}
	model.edit = make([dynamic]u8, context.temp_allocator)
	model.entered = make([dynamic]string, context.temp_allocator)
	model.ran = make([dynamic]string, context.temp_allocator)

	// Queue holds MODEL_WAITING_CAPACITY + 2 characters plus Enter: more than
	// the waiting buffer can hold if running were still treated as true.
	line_text := "abcdef"
	for ch in line_text {
		model.queue[model.queue_written % MODEL_QUEUE_CAPACITY] = Model_Key{character = ch}
		model.queue_written += 1
	}
	model.queue[model.queue_written % MODEL_QUEUE_CAPACITY] = Model_Key{enter = true}
	model.queue_written += 1

	model_first_thread_turn(&model)
	testing.expect_value(t, model.dropped, 0)
	testing.expect_value(t, model.queue_read, model.queue_written)
	testing.expect_value(t, len(model.entered), 1)
	if len(model.entered) == 1 {
		testing.expect_value(t, model.entered[0], line_text)
	}
	testing.expect(t, model.running)
}
