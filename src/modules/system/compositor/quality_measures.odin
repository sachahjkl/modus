package compositor

import "modus:private/compositor/quality"
import "modus:contract/text_encoding"
import "modus:support/display"
import "modus:support/system"

// The three measures of the standard of quality, on the path of the
// system, and the quality profile at the start
// (src/md/features/desktop_to_browser.md, "The three measures on the path of the system").
// Each time is of system.nanoseconds(), the clock of the system. Each
// measure is one sentence of the log: no test reads a time.

// The keys of a line of the key to the screen: the line of the frames
// comes with it, so a machine test that types this many characters into
// the console sees both.
KEYS_OF_A_LINE :: 16

frame_samples: quality.Samples // The last frames that a record started.
key_samples: quality.Samples // The keys since the last line.
key_table: quality.Key_Table
keys_since_line: int
// The read of the first record of a turn, 0 before it; and the read of the
// first record that the next frame draws, 0 when none waits.
turn_read_at: u64
frame_first_record_at: u64

// quality_profile_log writes the profile that the system chose: the
// system drives no GPU, so it is the processor profile.
quality_profile_log :: proc "contextless" () {
	profile, reason := quality.profile_of(false)
	system.log("compositor: the quality profile is ", quality.profile_sentences[profile], ": ", quality.reason_sentences[reason])
}

// quality_turn_start forgets the read of the turn before.
quality_turn_start :: proc "contextless" () {
	turn_read_at = 0
}

// quality_record_read notes the read of a record of the root service, of
// the input service or of a window: the first one of the turn.
quality_record_read :: proc "contextless" () {
	if turn_read_at == 0 {
		turn_read_at = system.nanoseconds()
	}
}

// quality_turn_end starts the measure of the next frame at the first
// record of this turn, when the turn left damage and no earlier record
// waits for a frame.
quality_turn_end :: proc "contextless" () {
	if frame_first_record_at == 0 && turn_read_at != 0 && damage_count > 0 {
		frame_first_record_at = turn_read_at
	}
}

// quality_key_values gives the values of the event Key for a window from
// the record of the input service: the serial of the key in place of the
// time of the input service. Only a press with a character that a text
// holds, and with no Control, is measured: the console shows it in its
// line. Another key has the serial 0.
quality_key_values :: proc "contextless" (window: int, values: [7]u64) -> [7]u64 {
	event := values
	event[display.KEY_EVENT_SERIAL] = 0
	character := display.key_character_of(values[1])
	pressed := values[2] != 0
	control := u32(values[3]) & display.MODIFIER_CONTROL != 0
	if pressed && !control && text_encoding.character_in_text(character) {
		event[display.KEY_EVENT_SERIAL] = quality.key_sent(&key_table, window, values[display.INPUT_KEY_READ_AT], system.nanoseconds())
	}
	return event
}

// quality_present takes the serial that a Present names, and notes the
// first picture of a window whose start the root service gave.
quality_present :: proc "contextless" (window: int, client: ^Client, first_picture: bool, serial: u64) {
	quality.key_shown(&key_table, window, serial)
	if first_picture && client.started_at != 0 {
		client.start_due = true
	}
}

// quality_window_started takes the record Client_Started: the time of the
// start of the program of a window. A window that showed a picture before
// it has no measure.
quality_window_started :: proc "contextless" (memory: system.Handle, started_at: u64) {
	for &client in clients {
		if client.ring_memory == memory && memory != 0 {
			if client.presents == 0 && started_at != 0 && started_at <= system.nanoseconds() {
				client.started_at = started_at
			}
			return
		}
	}
}

// quality_window_gone frees the keys of a window that closed.
quality_window_gone :: proc "contextless" (window: int) {
	quality.window_gone(&key_table, window)
}

// quality_frame_flipped ends the measures at the flip of a frame: the
// frame that a record started, each key that a Present of the frame
// showed, and the first picture of each window that started.
quality_frame_flipped :: proc "contextless" () {
	flipped := system.nanoseconds()
	if frame_first_record_at != 0 {
		if flipped >= frame_first_record_at {
			quality.samples_add(&frame_samples, flipped - frame_first_record_at)
		}
		frame_first_record_at = 0
	}
	keys_since_line += quality.keys_flipped(&key_table, flipped, &key_samples)
	if keys_since_line >= KEYS_OF_A_LINE {
		keys_since_line = 0
		frame_least, frame_median, frame_count := quality.samples_least_and_median(&frame_samples)
		system.log("compositor: measure: the time of a frame, from the first record that the compositor reads to the flip: least ", frame_least / 1000, ".", frame_least / 100 % 10, " us, median ", frame_median / 1000, ".", frame_median / 100 % 10, " us, over ", u64(frame_count), " frames")
		key_least, key_median, key_count := quality.samples_least_and_median(&key_samples)
		system.log("compositor: measure: the time of a key to the screen, from its record in the input service to the flip that shows it: least ", key_least / 1000, ".", key_least / 100 % 10, " us, median ", key_median / 1000, ".", key_median / 100 % 10, " us, over ", u64(key_count), " keys")
		quality.samples_clear(&key_samples)
	}
	for &client in clients {
		if !client.start_due {
			continue
		}
		client.start_due = false
		if flipped >= client.started_at {
			spent := flipped - client.started_at
			system.log("compositor: measure: the start of the window ", system.name_of(client.title[:]), ", from Program_Start to its first frame: ", spent / 1000, ".", spent / 100 % 10, " us")
		}
	}
}
