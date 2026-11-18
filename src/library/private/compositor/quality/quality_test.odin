#+build !freestanding
package quality

import "core:testing"

// With no GPU the profile is the processor profile, with its reason; the
// GPU profile needs a GPU that the system drives.
@(test)
profile_of_needs_a_driven_gpu :: proc(t: ^testing.T) {
	profile, reason := profile_of(false)
	testing.expect_value(t, profile, Quality_Profile.Processor)
	testing.expect_value(t, reason, Profile_Reason.No_Gpu_Device)
	profile, reason = profile_of(true)
	testing.expect_value(t, profile, Quality_Profile.Gpu)
	testing.expect_value(t, reason, Profile_Reason.Gpu_Device)
}

// No time gives no count; one time is its own least and median; a full
// table keeps the newest SAMPLE_CAPACITY times, and one more pushes out the
// oldest.
@(test)
samples_keep_the_newest_times :: proc(t: ^testing.T) {
	samples: Samples
	least, median, count := samples_least_and_median(&samples)
	testing.expect_value(t, count, 0)
	testing.expect_value(t, least, 0)
	testing.expect_value(t, median, 0)

	samples_add(&samples, 7)
	least, median, count = samples_least_and_median(&samples)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, least, 7)
	testing.expect_value(t, median, 7)

	samples_clear(&samples)
	// The times 1 to SAMPLE_CAPACITY, in a reversed order.
	for value := SAMPLE_CAPACITY; value >= 1; value -= 1 {
		samples_add(&samples, u64(value))
	}
	least, median, count = samples_least_and_median(&samples)
	testing.expect_value(t, count, SAMPLE_CAPACITY)
	testing.expect_value(t, least, 1)
	testing.expect_value(t, median, u64(SAMPLE_CAPACITY / 2 + 1))
	// One more: the oldest, SAMPLE_CAPACITY, goes.
	samples_add(&samples, 1000)
	least, median, count = samples_least_and_median(&samples)
	testing.expect_value(t, count, SAMPLE_CAPACITY)
	testing.expect_value(t, least, 1)
	largest_kept := false
	for value in samples.values {
		testing.expect(t, value != u64(SAMPLE_CAPACITY), "the oldest time stayed")
		largest_kept ||= value == 1000
	}
	testing.expect(t, largest_kept)
}

// A Present ties only the keys of its own window up to its serial. Each
// serial that the window did not get is refused and counted: 0 ties
// nothing, the largest word, a serial past the newest key, the serial of a
// later key of another window. A time of 0 or after now takes no place; a
// time equal to now is measured.
@(test)
key_shown_ties_only_the_keys_of_its_window :: proc(t: ^testing.T) {
	table: Key_Table
	samples: Samples
	first := key_sent(&table, 1, 100, 200)
	at_now := key_sent(&table, 1, 200, 200)
	other := key_sent(&table, 2, 160, 200)
	no_time := key_sent(&table, 1, 0, 200)
	future := key_sent(&table, 1, 300, 200)
	testing.expect(t, first == 1 && at_now == 2 && other == 3 && no_time == 4 && future == 5, "the serials start at 1 and grow by 1")
	window_one_sent := future // The newest serial that window 1 got.

	testing.expect_value(t, key_shown(&table, 1, 0, window_one_sent), 0)
	testing.expect_value(t, table.refused, 0)
	testing.expect_value(t, key_shown(&table, 1, max(u64), window_one_sent), 0)
	testing.expect_value(t, key_shown(&table, 1, table.serial_last + 1, table.serial_last + 1), 0)
	testing.expect_value(t, table.refused, 2)
	// Window 2 got only the serial 3: the later keys of window 1 are refused.
	testing.expect_value(t, key_shown(&table, 2, future, other), 0)
	testing.expect_value(t, table.refused, 3)
	testing.expect_value(t, key_shown(&table, 2, first, other), 0) // An earlier key of window 1: not its own.
	testing.expect_value(t, keys_flipped(&table, 400, &samples), 0)
	testing.expect_value(t, samples.count, 0)

	// The serial of window 1 ties its two keys with a time, and not the key
	// of window 2.
	testing.expect_value(t, key_shown(&table, 1, no_time, window_one_sent), 2)
	testing.expect_value(t, keys_flipped(&table, 400, &samples), 2)
	least, median, count := samples_least_and_median(&samples)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, least, 200)
	testing.expect_value(t, median, 300)
	// A key is measured once.
	testing.expect_value(t, key_shown(&table, 1, future, window_one_sent), 0)
	testing.expect_value(t, table.lost, 0)
}

// A full table: a new key takes the place of the oldest key that is not
// shown, and counts it lost; when each key is shown, of the oldest shown
// key, which is lost before its flip.
@(test)
a_full_table_loses_the_oldest_key_that_is_not_shown :: proc(t: ^testing.T) {
	table: Key_Table
	samples: Samples
	shown := key_sent(&table, 0, 10, 10)
	testing.expect_value(t, key_shown(&table, 0, shown, shown), 1)
	oldest_sent := key_sent(&table, 0, 20, 20)
	for _ in 2 ..< KEY_CAPACITY {
		key_sent(&table, 0, 20, 20)
	}
	testing.expect_value(t, table.lost, 0)
	newest := key_sent(&table, 0, 30, 30) // The table is full: oldest_sent goes.
	testing.expect_value(t, table.lost, 1)
	// The shown key stayed, and oldest_sent ties nothing more than the shown one.
	testing.expect_value(t, keys_flipped(&table, 40, &samples), 1)
	_, median, _ := samples_least_and_median(&samples)
	testing.expect_value(t, median, 30)
	testing.expect_value(t, key_shown(&table, 0, newest, newest), KEY_CAPACITY - 1)
	_ = oldest_sent

	// Each key shown, and one more: the oldest shown key is lost before
	// its flip.
	full: Key_Table
	for _ in 0 ..< KEY_CAPACITY {
		key_sent(&full, 0, 5, 5)
	}
	testing.expect_value(t, key_shown(&full, 0, full.serial_last, full.serial_last), KEY_CAPACITY)
	key_sent(&full, 0, 6, 6)
	testing.expect_value(t, full.lost, 1)
	flipped: Samples
	testing.expect_value(t, keys_flipped(&full, 6, &flipped), KEY_CAPACITY - 1)
}

// A window that closed leaves no key: the program that takes its place in
// the client table ties only its own keys, and not an old serial.
@(test)
a_reused_window_ties_only_its_own_keys :: proc(t: ^testing.T) {
	table: Key_Table
	samples: Samples
	old := key_sent(&table, 3, 10, 10)
	window_gone(&table, 3)
	testing.expect_value(t, key_shown(&table, 3, old, old), 0)
	// The new program of place 3 got no key yet: the old serial is past it.
	testing.expect_value(t, key_shown(&table, 3, old, 0), 0)
	fresh := key_sent(&table, 3, 20, 20)
	testing.expect_value(t, key_shown(&table, 3, fresh, fresh), 1)
	testing.expect_value(t, keys_flipped(&table, 25, &samples), 1)
}

// The time of a frame starts at the first record of the turn that draws
// it, or at the draw when that turn read none, or when its record time is
// after the draw.
@(test)
frame_span_start_takes_the_record_of_the_drawing_turn :: proc(t: ^testing.T) {
	testing.expect_value(t, frame_span_start(0, 500), 500)
	testing.expect_value(t, frame_span_start(400, 500), 400)
	testing.expect_value(t, frame_span_start(500, 500), 500)
	testing.expect_value(t, frame_span_start(600, 500), 500)
}

// The start of a window in both orders gives one span, the first flip
// less the start. A start of 0, after now or a second one is refused; a
// second flip changes nothing; a flip before the start gives no span.
@(test)
window_start_in_either_order :: proc(t: ^testing.T) {
	start_first: Window_Start
	taken, span, ready := window_start_started(&start_first, 100, 150)
	testing.expect(t, taken && !ready)
	span, ready = window_start_flipped(&start_first, 400)
	testing.expect(t, ready)
	testing.expect_value(t, span, 300)
	span, ready = window_start_flipped(&start_first, 900)
	testing.expect(t, !ready, "a second flip gave a span")

	flip_first: Window_Start
	span, ready = window_start_flipped(&flip_first, 400)
	testing.expect(t, !ready)
	taken, span, ready = window_start_started(&flip_first, 0, 500)
	testing.expect(t, !taken && !ready, "a start of 0 was taken")
	taken, span, ready = window_start_started(&flip_first, 600, 500)
	testing.expect(t, !taken && !ready, "a start after now was taken")
	taken, span, ready = window_start_started(&flip_first, 100, 500)
	testing.expect(t, taken && ready)
	testing.expect_value(t, span, 300)
	taken, _, ready = window_start_started(&flip_first, 50, 500)
	testing.expect(t, !taken && !ready, "a second start was taken")

	late: Window_Start
	window_start_flipped(&late, 100)
	taken, span, ready = window_start_started(&late, 200, 300)
	testing.expect(t, taken && !ready, "a flip before the start gave a span")
}

// The handle 0, a handle that no window has, and the handle of a window
// that ended (its place is 0 again) name no window.
@(test)
window_of_handle_refuses_each_unknown_handle :: proc(t: ^testing.T) {
	handles := [4]u64{0, 17, 0, 23}
	window, found := window_of_handle(handles[:], 0)
	testing.expect(t, !found && window == -1)
	_, found = window_of_handle(handles[:], 99)
	testing.expect(t, !found)
	window, found = window_of_handle(handles[:], 23)
	testing.expect(t, found && window == 3)
	handles[3] = 0 // The window ended.
	_, found = window_of_handle(handles[:], 23)
	testing.expect(t, !found)
}
