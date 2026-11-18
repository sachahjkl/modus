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

// The keys that the table keeps until a frame shows them. When it is full,
// a new key takes the place of the oldest key that is not shown, and of
// the oldest shown key only when each key is shown; each one is a measure
// lost, and counted. The table holds measures, not input: a key always
// reaches its window.
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
	serial_last: u64, // The serial of the newest key: 0 before the first one.
	refused:     u64, // The serials that a window named past the newest key that it got.
	lost:        u64, // The keys whose place a new key took before a flip measured them.
}

// key_place gives the place of a new key: a free place, else the oldest
// key that is sent and not shown, else the oldest shown key. lost is true
// when the place holds a key that no flip measured.
@(private)
key_place :: proc "contextless" (table: ^Key_Table) -> (place: int, lost: bool) {
	oldest_sent, oldest_shown := -1, -1
	for key, index in table.keys {
		switch key.state {
		case .Free:
			return index, false
		case .Sent:
			if oldest_sent < 0 || key.serial < table.keys[oldest_sent].serial {
				oldest_sent = index
			}
		case .Shown:
			if oldest_shown < 0 || key.serial < table.keys[oldest_shown].serial {
				oldest_shown = index
			}
		}
	}
	if oldest_sent >= 0 {
		return oldest_sent, true
	}
	return max(oldest_shown, 0), true
}

// key_sent gives the serial of a key that goes to a window, never 0, and
// keeps it. A time of the input service that is 0, or after the time of
// now, is no time of a read: the key keeps its serial and takes no place.
key_sent :: proc "contextless" (table: ^Key_Table, window: int, read_at, now: u64) -> (serial: u64) {
	table.serial_last += 1
	if read_at == 0 || read_at > now {
		return table.serial_last
	}
	place, lost := key_place(table)
	if lost {
		table.lost += 1
	}
	table.keys[place] = {serial = table.serial_last, window = window, read_at = read_at, state = .Sent}
	return table.serial_last
}

// key_shown takes the serial that a Present of a window names: each key of
// that window up to that serial is shown by the frame that draws the
// Present. sent_to_window is the newest serial that the compositor sent to
// that window: a serial past it names no key of the window, and is refused
// and counted, so a program cannot name the keys of a later window or a
// serial that no key has. 0 names no key. It gives the keys tied.
key_shown :: proc "contextless" (table: ^Key_Table, window: int, serial: u64, sent_to_window: u64) -> (tied: int) {
	if serial == 0 {
		return 0
	}
	if serial > sent_to_window || serial > table.serial_last {
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

// frame_span_start gives the start of the time of a frame: the read of the
// first record of the turn that draws it, or the start of the draw when
// that turn read none. The wait for the next frame of an earlier turn is
// not in it: it is the pacing of the compositor, not the cost of a frame.
frame_span_start :: proc "contextless" (turn_read_at, draw_started: u64) -> u64 {
	if turn_read_at != 0 && turn_read_at <= draw_started {
		return turn_read_at
	}
	return draw_started
}

// The two times of the start of a window, from two programs in either
// order: the root service sends the start, the compositor flips the first
// frame. The line comes when both are known, once.
Window_Start :: struct {
	started_at:      u64, // When the root service called system.program_start; 0: not known.
	first_flip_at:   u64, // The flip of the first frame that drew a picture of the window; 0: not yet.
	done:            bool, // The span was given, or can never be.
}

// window_start_started takes the time of the start. A time of 0, after
// now, or a second one is refused: it gives false, and nothing changes.
// With the first flip known, it gives the span.
window_start_started :: proc "contextless" (start: ^Window_Start, started_at, now: u64) -> (taken: bool, span: u64, ready: bool) {
	if start.done || start.started_at != 0 || started_at == 0 || started_at > now {
		return false, 0, false
	}
	start.started_at = started_at
	span, ready = window_start_span(start)
	return true, span, ready
}

// window_start_flipped takes the flip of the first frame of the window:
// only the first one counts. With the start known, it gives the span.
window_start_flipped :: proc "contextless" (start: ^Window_Start, flipped_at: u64) -> (span: u64, ready: bool) {
	if start.done || start.first_flip_at != 0 || flipped_at == 0 {
		return 0, false
	}
	start.first_flip_at = flipped_at
	return window_start_span(start)
}

// window_start_span gives the span when both times are known, once. A
// first flip before the start belongs to no start of this program: no
// span, and none later.
@(private)
window_start_span :: proc "contextless" (start: ^Window_Start) -> (span: u64, ready: bool) {
	if start.started_at == 0 || start.first_flip_at == 0 {
		return 0, false
	}
	start.done = true
	if start.first_flip_at < start.started_at {
		return 0, false
	}
	return start.first_flip_at - start.started_at, true
}

// window_of_handle gives the place of the window whose ring handle the
// root service named, in the ring handles of the client table (0: a free
// place). The handle 0 names no window.
window_of_handle :: proc "contextless" (handles: []u64, handle: u64) -> (window: int, found: bool) {
	if handle == 0 {
		return -1, false
	}
	for value, index in handles {
		if value == handle {
			return index, true
		}
	}
	return -1, false
}
