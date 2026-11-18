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

// A Present that names a serial ties only the keys of its own window up to
// that serial. 0, a serial past the newest key and the serial of another
// window tie nothing; a key with no time, or a time after now, is never
// measured; a closed window leaves no key to tie.
@(test)
key_shown_ties_only_the_keys_of_its_window :: proc(t: ^testing.T) {
	table: Key_Table
	samples: Samples
	first := key_sent(&table, 1, 100, 200)
	second := key_sent(&table, 1, 150, 200)
	other := key_sent(&table, 2, 160, 200)
	no_time := key_sent(&table, 1, 0, 200)
	future := key_sent(&table, 1, 300, 200)
	testing.expect(t, first == 1 && second == 2 && other == 3 && no_time == 4 && future == 5, "the serials start at 1 and grow by 1")

	testing.expect_value(t, key_shown(&table, 1, 0), 0)
	testing.expect_value(t, key_shown(&table, 1, table.serial_last + 1), 0)
	testing.expect_value(t, table.refused, 1)
	testing.expect_value(t, key_shown(&table, 2, first), 0)
	testing.expect_value(t, keys_flipped(&table, 400, &samples), 0)
	testing.expect_value(t, samples.count, 0)

	// The serial of the key with no time ties the two keys before it, and
	// not the key of window 2.
	testing.expect_value(t, key_shown(&table, 1, no_time), 2)
	testing.expect_value(t, keys_flipped(&table, 400, &samples), 2)
	least, median, count := samples_least_and_median(&samples)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, least, 250)
	testing.expect_value(t, median, 300)
	// A key is measured once.
	testing.expect_value(t, key_shown(&table, 1, no_time), 0)
	testing.expect_value(t, key_shown(&table, 1, future), 0)

	window_gone(&table, 2)
	testing.expect_value(t, key_shown(&table, 2, other), 0)
}

// A key that no frame shows leaves when KEY_CAPACITY newer keys came: the
// serial of the oldest then ties nothing, and the newest still ties.
@(test)
keys_leave_the_table_after_its_capacity :: proc(t: ^testing.T) {
	table: Key_Table
	samples: Samples
	oldest := key_sent(&table, 0, 10, 10)
	for _ in 0 ..< KEY_CAPACITY {
		key_sent(&table, 0, 20, 20)
	}
	testing.expect_value(t, key_shown(&table, 0, oldest), 0)
	testing.expect_value(t, key_shown(&table, 0, table.serial_last), KEY_CAPACITY)
	testing.expect_value(t, keys_flipped(&table, 25, &samples), KEY_CAPACITY)
	_, median, _ := samples_least_and_median(&samples)
	testing.expect_value(t, median, 5)
}
