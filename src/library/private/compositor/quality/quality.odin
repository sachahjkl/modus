// The measures of the standard of quality that the compositor takes, with
// no state of its own and no clock: the choice of the quality profile, the
// times of the last frames, and the table that ties a key to the frame
// that shows it. The design:
// (src/md/features/desktop_to_browser.md, "The three measures on the path of the system").
// The compositor holds the state, reads the clock and writes the lines, so
// a host test gives these procedures each refused case.
package quality

// The two quality profiles (docs/glossary/desktop.md, "Quality profile").
Quality_Profile :: enum {
	Processor, // No GPU that the system drives.
	Gpu, // A GPU that the system drives.
}

// Why the compositor chose its profile.
Profile_Reason :: enum {
	No_Gpu_Device, // The system drives no GPU device.
	Gpu_Device, // The system drives a GPU device.
}

@(rodata)
profile_sentences := [Quality_Profile]string {
	.Processor = "the processor profile",
	.Gpu       = "the GPU profile",
}

@(rodata)
reason_sentences := [Profile_Reason]string {
	.No_Gpu_Device = "the system drives no GPU device",
	.Gpu_Device    = "the system drives a GPU device",
}

// profile_of chooses the profile at the start: the GPU profile only with a
// GPU that the system drives. Today no device service drives one, so the
// compositor passes false.
profile_of :: proc "contextless" (gpu_driven: bool) -> (profile: Quality_Profile, reason: Profile_Reason) {
	if gpu_driven {
		return .Gpu, .Gpu_Device
	}
	return .Processor, .No_Gpu_Device
}

// The times that a line gives, the newest first to go out: the last
// SAMPLE_CAPACITY times, in nanoseconds of the clock of the system.
SAMPLE_CAPACITY :: 64

Samples :: struct {
	values: [SAMPLE_CAPACITY]u64,
	count:  int, // The values in use, at most SAMPLE_CAPACITY.
	next:   int, // The place of the next value: the oldest one when the table is full.
}

// samples_add keeps one time; the oldest goes when the table is full.
samples_add :: proc "contextless" (samples: ^Samples, value: u64) {
	samples.values[samples.next] = value
	samples.next = (samples.next + 1) % SAMPLE_CAPACITY
	samples.count = min(samples.count + 1, SAMPLE_CAPACITY)
}

// samples_clear forgets each time.
samples_clear :: proc "contextless" (samples: ^Samples) {
	samples^ = {}
}

// samples_least_and_median gives the least time and the median of the
// times kept, and their count: 0 for none.
samples_least_and_median :: proc "contextless" (samples: ^Samples) -> (least, median: u64, count: int) {
	count = clamp(samples.count, 0, SAMPLE_CAPACITY)
	if count == 0 {
		return 0, 0, 0
	}
	sorted: [SAMPLE_CAPACITY]u64
	for index in 0 ..< count {
		value := samples.values[index]
		place := index
		for place > 0 && sorted[place - 1] > value {
			sorted[place] = sorted[place - 1]
			place -= 1
		}
		sorted[place] = value
	}
	return sorted[0], sorted[count / 2], count
}

// The keys that the table keeps until a frame shows them: a key that no
// frame shows leaves when KEY_CAPACITY newer keys came. The table holds
// measures, not input: a key always reaches its window.
KEY_CAPACITY :: 32

// Where a key of the table is.
Key_State :: enum u8 {
	Free, // No key, or a key that is not measured.
	Sent, // The window got it, and named no frame that shows it.
	Shown, // A Present of the window named it: the next flip shows it.
}

Measured_Key :: struct {
	serial:  u64, // The serial of the key in the event Key.
	window:  int, // The window that got it: its place in the client table of the compositor.
	read_at: u64, // When the input service read the key, in nanoseconds of the clock of the system.
	state:   Key_State,
}

Key_Table :: struct {
	keys:        [KEY_CAPACITY]Measured_Key,
	next:        int, // The place of the next key.
	serial_last: u64, // The serial of the newest key: 0 before the first one.
	refused:     u64, // The serials that a window named and that no key of the table has: a serial past the newest one.
}

// key_sent gives the serial of a key that goes to a window, never 0, and
// keeps it. A time of the input service that is 0, or after the time of
// now, is no time of a read: the key keeps its serial and is not measured.
key_sent :: proc "contextless" (table: ^Key_Table, window: int, read_at, now: u64) -> (serial: u64) {
	table.serial_last += 1
	state := read_at != 0 && read_at <= now ? Key_State.Sent : Key_State.Free
	table.keys[table.next] = {serial = table.serial_last, window = window, read_at = read_at, state = state}
	table.next = (table.next + 1) % KEY_CAPACITY
	return table.serial_last
}

// key_shown takes the serial that a Present of a window names: each key of
// that window up to that serial is shown by the frame that draws the
// Present. 0 names no key. A serial past the newest key is refused and
// counted; a key of another window is never tied. It gives the keys tied.
key_shown :: proc "contextless" (table: ^Key_Table, window: int, serial: u64) -> (tied: int) {
	if serial == 0 {
		return 0
	}
	if serial > table.serial_last {
		table.refused += 1
		return 0
	}
	for &key in table.keys {
		if key.state == .Sent && key.window == window && key.serial <= serial {
			key.state = .Shown
			tied += 1
		}
	}
	return tied
}

// keys_flipped measures each shown key at the flip of the frame that shows
// it, keeps its time in samples, and frees it. It gives the keys measured.
keys_flipped :: proc "contextless" (table: ^Key_Table, flipped_at: u64, samples: ^Samples) -> (measured: int) {
	for &key in table.keys {
		if key.state != .Shown {
			continue
		}
		if flipped_at >= key.read_at {
			samples_add(samples, flipped_at - key.read_at)
			measured += 1
		}
		key.state = .Free
	}
	return measured
}

// window_gone frees the keys of a window that closed: a program that takes
// its place in the table never ties them.
window_gone :: proc "contextless" (table: ^Key_Table, window: int) {
	for &key in table.keys {
		if key.window == window {
			key.state = .Free
		}
	}
}
