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

// The keys of a line of the key to the screen. The line of the frames
// comes with it, so a machine test that types more characters than this
// into the console sees both; it also comes alone after FRAMES_OF_A_LINE
// frames, with no key. That count is large, about one line a minute at
// 60 frames a second: the log of the system keeps 2047 records for every
// process, and a line each second would push the records of the others out.
KEYS_OF_A_LINE :: 16
FRAMES_OF_A_LINE :: 4096

frame_samples: quality.Samples // The last frames.
key_samples: quality.Samples // The keys since the last line.
key_table: quality.Key_Table
keys_since_line: int
frames_since_line: int
// The counts of the key table that the log gave last.
keys_lost_logged, serials_refused_logged: u64
// The read of the first record of this turn, 0 before it; and the start
// of the frame that draw draws now.
turn_read_at: u64
frame_started_at: u64

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

// quality_frame_start starts the time of the frame that draw draws: at the
// first record of this turn, or now when this turn read none. The wait of
// an earlier turn for the next frame is the pacing of the compositor, and
// is not in it.
quality_frame_start :: proc "contextless" () {
	frame_started_at = quality.frame_span_start(turn_read_at, system.nanoseconds())
}

// quality_key_values gives the values of the event Key for a window from
// the record of the input service: the serial of the key in place of the
// time of the input service. Only a press with a character that a text
// holds, and with no Control, is measured: the console shows it in its
// line. Another key has the serial 0. The window keeps the newest serial
// that it got: a Present past it is refused.
quality_key_values :: proc "contextless" (window: int, values: [7]u64) -> [7]u64 {
	event := values
	event[display.KEY_EVENT_SERIAL] = 0
	character := display.key_character_of(values[1])
	pressed := values[2] != 0
	control := u32(values[3]) & display.MODIFIER_CONTROL != 0
	if pressed && !control && text_encoding.character_in_text(character) {
		serial := quality.key_sent(&key_table, window, values[display.INPUT_KEY_READ_AT], system.nanoseconds())
		event[display.KEY_EVENT_SERIAL] = serial
		clients[window].key_serial_sent = serial
	}
	return event
}

// quality_present takes the serial that a Present names, and notes the
// first picture of a window: the next flip shows it.
quality_present :: proc "contextless" (window: int, client: ^Client, first_picture: bool, serial: u64) {
	quality.key_shown(&key_table, window, serial, client.key_serial_sent)
	if first_picture {
		client.start_due = true
	}
}

// quality_start_log writes the line of the start of a window.
quality_start_log :: proc "contextless" (client: ^Client, span: u64) {
	system.log("compositor: measure: the start of the window ", system.name_of(client.title[:]), ", from Process_Start to its first frame: ", span / 1000, ".", span / 100 % 10, " us")
}

// quality_window_started takes the record Client_Started: the time of the
// start of the process of a window. It comes before or after the first
// flip of the window: the line comes when both times are known.
quality_window_started :: proc "contextless" (memory: system.Handle, started_at: u64) {
	handles: [CLIENT_CAPACITY]u64
	for &client, index in clients {
		handles[index] = u64(client.ring_memory)
	}
	window, found := quality.window_of_handle(handles[:], u64(memory))
	if !found {
		return
	}
	client := &clients[window]
	if _, span, ready := quality.window_start_started(&client.start, started_at, system.nanoseconds()); ready {
		quality_start_log(client, span)
	}
}

// quality_window_gone frees the keys of a window that closed.
quality_window_gone :: proc "contextless" (window: int) {
	quality.window_gone(&key_table, window)
}

// quality_frame_line writes the line of the frames.
quality_frame_line :: proc "contextless" () {
	frames_since_line = 0
	least, median, count := quality.samples_least_and_median(&frame_samples)
	system.log("compositor: measure: the time of a frame, from the first record that the compositor reads to the flip: least ", least / 1000, ".", least / 100 % 10, " us, median ", median / 1000, ".", median / 100 % 10, " us, over ", u64(count), " frames")
}

// quality_frame_flipped ends the measures at the flip of a frame: the
// frame, each key that a Present of the frame showed, and the first
// picture of each window.
quality_frame_flipped :: proc "contextless" () {
	flipped := system.nanoseconds()
	if frame_started_at != 0 && flipped >= frame_started_at {
		quality.samples_add(&frame_samples, flipped - frame_started_at)
		frames_since_line += 1
	}
	frame_started_at = 0
	keys_since_line += quality.keys_flipped(&key_table, flipped, &key_samples)
	if keys_since_line >= KEYS_OF_A_LINE {
		keys_since_line = 0
		quality_frame_line()
		least, median, count := quality.samples_least_and_median(&key_samples)
		system.log("compositor: measure: the time of a key to the screen, from its record in the input service to the flip that shows it: least ", least / 1000, ".", least / 100 % 10, " us, median ", median / 1000, ".", median / 100 % 10, " us, over ", u64(count), " keys")
		quality.samples_clear(&key_samples)
		// The measures that the table lost, and the serials that a window
		// named past its keys, when they changed.
		if key_table.lost != keys_lost_logged || key_table.refused != serials_refused_logged {
			keys_lost_logged, serials_refused_logged = key_table.lost, key_table.refused
			system.log("compositor: the measure of the keys to the screen: ", key_table.lost, " keys left the table before a flip showed them, and ", key_table.refused, " serials that a window named were past the keys that it got, since the start")
		}
	} else if frames_since_line >= FRAMES_OF_A_LINE {
		quality_frame_line()
	}
	for &client in clients {
		if !client.start_due {
			continue
		}
		client.start_due = false
		if span, ready := quality.window_start_flipped(&client.start, flipped); ready {
			quality_start_log(&client, span)
		}
	}
}
