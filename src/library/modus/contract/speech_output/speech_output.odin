// Screen reader speech announcement queue and semantic utterance formatter
// (src/md/features/accessibility.md, "5. Speech").
//
// Pure freestanding zero-allocation contract package bridging semantic tree
// announcements (Super+Alt+S toggle state, Polite vs Assertive priority,
// bounded utterance ring, rate and pitch bounds, and role/name/state speech
// formatting) to the multi-process sound mixer (modus:contract/sound_mixer).
package speech_output

import "modus:contract/accessibility"
import "modus:contract/enum_word"
import "modus:contract/sound_mixer"
import "modus:contract/text_encoding"

// Maximum queued speech utterances held in one bounded ring.
SPEECH_QUEUE_CAPACITY :: 16

// Maximum UTF-8 byte length of one speech utterance.
SPEECH_UTTERANCE_TEXT_LIMIT :: 256

// Speech rate bounds, in percent of normal speed [50..400].
SPEECH_RATE_MIN :: u16(50)
SPEECH_RATE_MAX :: u16(400)
SPEECH_RATE_DEFAULT :: u16(100)

// Speech pitch bounds, in percent of base pitch [50..200].
SPEECH_PITCH_MIN :: u16(50)
SPEECH_PITCH_MAX :: u16(200)
SPEECH_PITCH_DEFAULT :: u16(100)

// Audio format constants shared with sound_mixer so synthesis output feeds
// directly into a mixer slot without format negotiation.
SPEECH_MIXER_SAMPLE_RATE_HZ :: sound_mixer.SAMPLE_RATE_HZ
SPEECH_MIXER_CHANNELS :: sound_mixer.CHANNELS

// Priority of a queued announcement. Value 0 names no priority and is refused.
Speech_Priority :: enum u8 {
	Polite    = 1, // Spoken in FIFO order after earlier utterances finish.
	Assertive = 2, // Flushes pending Polite utterances and speaks immediately.
}

// Toggle state controlled by the system shortcut Super+Alt+S.
Speech_Toggle_State :: enum u8 {
	Disabled = 0, // Speech output is off; enqueue requests are refused.
	Enabled  = 1, // Speech output is active and accepts utterances.
}

// Explicit refusal reasons returned by speech queue and formatter borders.
Speech_Refusal :: enum u8 {
	None              = 0,
	Nil_Queue         = 1,
	Speech_Disabled   = 2,
	Invalid_Priority  = 3,
	Empty_Text        = 4,
	Text_Too_Long     = 5,
	Invalid_Text      = 6,
	Rate_Out_Of_Range = 7,
	Pitch_Out_Of_Range = 8,
	Queue_Empty       = 9,
	Buffer_Too_Small  = 10,
	Invalid_Role      = 11,
	Invalid_States    = 12,
	Invalid_Toggle    = 13,
	Invalid_Expanded  = 14,
}

// Border converters from transport words to closed enums.

speech_priority_of_word :: proc "contextless" (word: u8) -> (priority: Speech_Priority, ok: bool) {
	return enum_word.member_of_word(Speech_Priority, u64(word))
}

speech_toggle_state_of_word :: proc "contextless" (word: u8) -> (state: Speech_Toggle_State, ok: bool) {
	return enum_word.member_of_word(Speech_Toggle_State, u64(word))
}

speech_refusal_of_word :: proc "contextless" (word: u8) -> (refusal: Speech_Refusal, ok: bool) {
	return enum_word.member_of_word(Speech_Refusal, u64(word))
}

// One queued speech utterance captured with its voice parameters at enqueue time.
Speech_Utterance :: struct {
	serial:        u64, // Monotonic non-zero serial assigned at enqueue.
	priority:      Speech_Priority,
	rate_percent:  u16,
	pitch_percent: u16,
	text_bytes:    [SPEECH_UTTERANCE_TEXT_LIMIT]u8,
	text_len:      u16,
}

// speech_utterance_text returns the spoken UTF-8 text of an utterance.
speech_utterance_text :: proc "contextless" (utterance: ^Speech_Utterance) -> string {
	if utterance == nil || int(utterance.text_len) > len(utterance.text_bytes) {
		return ""
	}
	return string(utterance.text_bytes[:utterance.text_len])
}

// Bounded announcement ring with Super+Alt+S toggle state, voice bounds, and
// explicit replacement and interruption counters.
Speech_Queue :: struct {
	toggle_state:              Speech_Toggle_State,
	rate_percent:              u16,
	pitch_percent:             u16,
	mixer_gain_q16:            u32, // Fixed-point Q16 gain for sound_mixer integration.
	ring:                      [SPEECH_QUEUE_CAPACITY]Speech_Utterance,
	head:                      u32,
	count:                     u32,
	next_serial:               u64,
	replaced_polite_count:     u64, // Count of oldest Polite utterances replaced when full.
	flushed_by_assertive_count: u64, // Count of pending Polite utterances flushed by Assertive.
	assertive_interrupt_count: u64, // Total Assertive utterances enqueued.
}

@(private = "file")
text_has_visible_byte :: proc "contextless" (bytes: []u8) -> bool {
	index := 0
	for index < len(bytes) {
		b := bytes[index]
		if b == ' ' || b == '\t' || b == '\n' || b == '\r' || b == 0x0B || b == 0x0C {
			index += 1
			continue
		}
		if b == 0xC2 && index + 1 < len(bytes) && bytes[index + 1] == 0xA0 {
			index += 2
			continue
		}
		return true
	}
	return false
}

// speech_queue_init resets queue to valid defaults with Super+Alt+S toggle
// set to Enabled when enabled is true, else Disabled.
speech_queue_init :: proc "contextless" (queue: ^Speech_Queue, enabled: bool = false) {
	if queue == nil {
		return
	}
	queue^ = {
		toggle_state   = enabled ? .Enabled : .Disabled,
		rate_percent   = SPEECH_RATE_DEFAULT,
		pitch_percent  = SPEECH_PITCH_DEFAULT,
		mixer_gain_q16 = sound_mixer.GAIN_UNITY,
		next_serial    = 1,
	}
}

// speech_queue_toggle toggles the Super+Alt+S screen reader speech state.
// Turning speech off clears any pending utterances immediately so audio stops.
speech_queue_toggle :: proc "contextless" (queue: ^Speech_Queue) -> Speech_Toggle_State {
	if queue == nil {
		return .Disabled
	}
	if queue.toggle_state == .Enabled {
		queue.toggle_state = .Disabled
		queue.head = 0
		queue.count = 0
		return .Disabled
	}
	queue.toggle_state = .Enabled
	if queue.next_serial == 0 {
		queue.next_serial = 1
	}
	if queue.rate_percent == 0 {
		queue.rate_percent = SPEECH_RATE_DEFAULT
	}
	if queue.pitch_percent == 0 {
		queue.pitch_percent = SPEECH_PITCH_DEFAULT
	}
	if queue.mixer_gain_q16 == 0 || queue.mixer_gain_q16 > sound_mixer.GAIN_UNITY {
		queue.mixer_gain_q16 = sound_mixer.GAIN_UNITY
	}
	return .Enabled
}

// speech_queue_set_voice_parameters updates speech rate [50..400] and pitch
// [50..200]. Any out-of-range value is refused without modifying queue.
speech_queue_set_voice_parameters :: proc "contextless" (queue: ^Speech_Queue, rate_percent: u16, pitch_percent: u16) -> Speech_Refusal {
	if queue == nil {
		return .Nil_Queue
	}
	if rate_percent < SPEECH_RATE_MIN || rate_percent > SPEECH_RATE_MAX {
		return .Rate_Out_Of_Range
	}
	if pitch_percent < SPEECH_PITCH_MIN || pitch_percent > SPEECH_PITCH_MAX {
		return .Pitch_Out_Of_Range
	}
	queue.rate_percent = rate_percent
	queue.pitch_percent = pitch_percent
	return .None
}

@(private = "file")
ring_slot_at :: proc "contextless" (queue: ^Speech_Queue, offset: u32) -> u32 {
	return (queue.head + offset) % SPEECH_QUEUE_CAPACITY
}

@(private = "file")
ring_compact_remove_at :: proc "contextless" (queue: ^Speech_Queue, remove_offset: u32) {
	if remove_offset >= queue.count {
		return
	}
	for i := remove_offset; i + 1 < queue.count; i += 1 {
		dst := ring_slot_at(queue, i)
		src := ring_slot_at(queue, i + 1)
		queue.ring[dst] = queue.ring[src]
	}
	tail := ring_slot_at(queue, queue.count - 1)
	queue.ring[tail] = {}
	queue.count -= 1
	if queue.count == 0 {
		queue.head = 0
	}
}

// speech_queue_enqueue appends one validated utterance to queue.
// - Refuses disabled speech, invalid priority words, empty/whitespace text,
//   oversized or invalid UTF-8 text, and out-of-range voice parameters with
//   zero mutation of queue.
// - Assertive flushes every pending Polite utterance in the ring (incrementing
//   flushed_by_assertive_count) so urgent alerts speak immediately.
// - Polite replaces the oldest Polite utterance when full (incrementing
//   replaced_polite_count) so no utterance is dropped silently.
speech_queue_enqueue :: proc "contextless" (queue: ^Speech_Queue, priority: Speech_Priority, text: string) -> (serial: u64, refusal: Speech_Refusal) {
	if queue == nil {
		return 0, .Nil_Queue
	}
	checked_priority, priority_ok := speech_priority_of_word(u8(priority))
	if !priority_ok {
		return 0, .Invalid_Priority
	}
	if queue.toggle_state != .Enabled {
		return 0, .Speech_Disabled
	}
	if queue.rate_percent < SPEECH_RATE_MIN || queue.rate_percent > SPEECH_RATE_MAX {
		return 0, .Rate_Out_Of_Range
	}
	if queue.pitch_percent < SPEECH_PITCH_MIN || queue.pitch_percent > SPEECH_PITCH_MAX {
		return 0, .Pitch_Out_Of_Range
	}
	if len(text) == 0 {
		return 0, .Empty_Text
	}
	if len(text) > SPEECH_UTTERANCE_TEXT_LIMIT {
		return 0, .Text_Too_Long
	}
	raw_bytes := transmute([]u8)text
	if !text_encoding.text_valid(raw_bytes) {
		return 0, .Invalid_Text
	}
	if !text_has_visible_byte(raw_bytes) {
		return 0, .Empty_Text
	}

	if queue.next_serial == 0 {
		queue.next_serial = 1
	}

	switch checked_priority {
	case .Assertive:
		queue.assertive_interrupt_count += 1
		// Flush all pending Polite utterances while preserving earlier Assertive items in FIFO order.
		i := u32(0)
		for i < queue.count {
			slot := ring_slot_at(queue, i)
			if queue.ring[slot].priority == .Polite {
				ring_compact_remove_at(queue, i)
				queue.flushed_by_assertive_count += 1
			} else {
				i += 1
			}
		}
		// If still full (all Assertive), replace the oldest entry so the newest alert is never lost.
		if queue.count >= SPEECH_QUEUE_CAPACITY {
			ring_compact_remove_at(queue, 0)
		}

	case .Polite:
		if queue.count >= SPEECH_QUEUE_CAPACITY {
			// Replace the oldest Polite utterance; if all slots are Assertive,
			// count this polite utterance as replaced without displacing Assertive alerts.
			found_polite := false
			for i in u32(0) ..< queue.count {
				slot := ring_slot_at(queue, i)
				if queue.ring[slot].priority == .Polite {
					ring_compact_remove_at(queue, i)
					queue.replaced_polite_count += 1
					found_polite = true
					break
				}
			}
			if !found_polite {
				queue.replaced_polite_count += 1
				return 0, .None
			}
		}
	}

	assigned_serial := queue.next_serial
	queue.next_serial += 1

	insert_slot := ring_slot_at(queue, queue.count)
	entry := &queue.ring[insert_slot]
	entry^ = {
		serial        = assigned_serial,
		priority      = checked_priority,
		rate_percent  = queue.rate_percent,
		pitch_percent = queue.pitch_percent,
		text_len      = u16(len(raw_bytes)),
	}
	copy(entry.text_bytes[:len(raw_bytes)], raw_bytes)
	queue.count += 1

	return assigned_serial, .None
}

// speech_queue_dequeue pops the front utterance in FIFO order.
speech_queue_dequeue :: proc "contextless" (queue: ^Speech_Queue) -> (utterance: Speech_Utterance, ok: bool) {
	if queue == nil || queue.count == 0 {
		return {}, false
	}
	utterance = queue.ring[queue.head]
	queue.ring[queue.head] = {}
	queue.head = (queue.head + 1) % SPEECH_QUEUE_CAPACITY
	queue.count -= 1
	if queue.count == 0 {
		queue.head = 0
	}
	return utterance, true
}

// speech_queue_peek returns the front utterance without removing it.
speech_queue_peek :: proc "contextless" (queue: ^Speech_Queue) -> (utterance: Speech_Utterance, ok: bool) {
	if queue == nil || queue.count == 0 {
		return {}, false
	}
	return queue.ring[queue.head], true
}

// speech_mixer_submit_pcm bridges synthesized 48 kHz stereo PCM frames from a
// speech synthesizer into a sound_mixer.Mixer_State slot. When speech is
// disabled, the mixer slot is muted cleanly and no frames are submitted.
speech_mixer_submit_pcm :: proc "contextless" (
	queue: ^Speech_Queue,
	mixer: ^sound_mixer.Mixer_State,
	slot_index: u32,
	start_frame: u64,
	frames: []sound_mixer.Stereo_Frame,
) -> (refusal: sound_mixer.Mixer_Refusal) {
	if queue == nil || mixer == nil {
		return .Invalid_Slot
	}
	if queue.toggle_state != .Enabled {
		return sound_mixer.mixer_set_muted(mixer, slot_index, true)
	}
	if gain_refusal := sound_mixer.mixer_set_gain(mixer, slot_index, queue.mixer_gain_q16); gain_refusal != .None {
		return gain_refusal
	}
	if unmute_refusal := sound_mixer.mixer_set_muted(mixer, slot_index, false); unmute_refusal != .None {
		return unmute_refusal
	}
	return sound_mixer.mixer_submit_frames(mixer, slot_index, start_frame, frames)
}

@(private = "file")
append_spoken_part :: proc "contextless" (out_buffer: []u8, cursor: ^int, part: string) -> bool {
	if len(part) == 0 {
		return true
	}
	sep := cursor^ > 0 ? 2 : 0
	if cursor^ + sep + len(part) > len(out_buffer) {
		return false
	}
	if sep == 2 {
		out_buffer[cursor^] = ','
		out_buffer[cursor^ + 1] = ' '
		cursor^ += 2
	}
	copy(out_buffer[cursor^:], part)
	cursor^ += len(part)
	return true
}

@(private = "file")
role_uses_checked_wording :: proc "contextless" (role: accessibility.Element_Role) -> bool {
	#partial switch role {
	case .Checkbox, .Radio, .Switch, .Menu_Item_Checkbox, .Menu_Item_Radio:
		return true
	}
	return false
}

// speech_utterance_for_element formats spoken screen-reader text from a
// semantic element's role, accessible name, states, toggle, and expanded
// flags into out_buffer with zero heap allocation.
//
// Protected fields never expose secret content and announce "protected field".
// Invalid enum/bit words or an undersized out_buffer are refused cleanly with
// written == 0.
speech_utterance_for_element :: proc "contextless" (
	role: accessibility.Element_Role,
	name: string,
	states: accessibility.Element_States,
	toggle: accessibility.Toggle_State,
	expanded: accessibility.Expanded_State,
	out_buffer: []u8,
) -> (written: int, refusal: Speech_Refusal) {
	checked_role, role_ok := accessibility.element_role_of_word(u8(role))
	if !role_ok {
		return 0, .Invalid_Role
	}
	checked_states, states_ok := accessibility.element_states_of_word(transmute(u32)states)
	if !states_ok {
		return 0, .Invalid_States
	}
	checked_toggle, toggle_ok := accessibility.toggle_state_of_word(u8(toggle))
	if !toggle_ok {
		return 0, .Invalid_Toggle
	}
	checked_expanded, expanded_ok := accessibility.expanded_state_of_word(u8(expanded))
	if !expanded_ok {
		return 0, .Invalid_Expanded
	}
	if len(name) > 0 && !text_encoding.text_valid(transmute([]u8)name) {
		return 0, .Invalid_Text
	}

	temp: [SPEECH_UTTERANCE_TEXT_LIMIT]u8
	cursor := 0

	if len(name) > 0 && text_has_visible_byte(transmute([]u8)name) {
		if !append_spoken_part(temp[:], &cursor, name) {
			return 0, .Text_Too_Long
		}
	}

	if .Protected in checked_states {
		if !append_spoken_part(temp[:], &cursor, "protected field") {
			return 0, .Text_Too_Long
		}
	} else {
		if checked_role != .None {
			if !append_spoken_part(temp[:], &cursor, accessibility.ELEMENT_ROLE_NAMES[checked_role]) {
				return 0, .Text_Too_Long
			}
		}

		switch checked_toggle {
		case .None:
		case .True:
			word := role_uses_checked_wording(checked_role) ? "checked" : "pressed"
			if !append_spoken_part(temp[:], &cursor, word) {
				return 0, .Text_Too_Long
			}
		case .False:
			word := role_uses_checked_wording(checked_role) ? "not checked" : "not pressed"
			if !append_spoken_part(temp[:], &cursor, word) {
				return 0, .Text_Too_Long
			}
		case .Mixed:
			if !append_spoken_part(temp[:], &cursor, "mixed") {
				return 0, .Text_Too_Long
			}
		}

		switch checked_expanded {
		case .None:
		case .Collapsed:
			if !append_spoken_part(temp[:], &cursor, "collapsed") {
				return 0, .Text_Too_Long
			}
		case .Expanded:
			if !append_spoken_part(temp[:], &cursor, "expanded") {
				return 0, .Text_Too_Long
			}
		}
	}

	if .Selected in checked_states {
		if !append_spoken_part(temp[:], &cursor, "selected") {
			return 0, .Text_Too_Long
		}
	}
	if .Disabled in checked_states {
		if !append_spoken_part(temp[:], &cursor, "disabled") {
			return 0, .Text_Too_Long
		}
	}
	if .Invalid in checked_states {
		if !append_spoken_part(temp[:], &cursor, "invalid") {
			return 0, .Text_Too_Long
		}
	}
	if .Required in checked_states {
		if !append_spoken_part(temp[:], &cursor, "required") {
			return 0, .Text_Too_Long
		}
	}
	if .Busy in checked_states {
		if !append_spoken_part(temp[:], &cursor, "busy") {
			return 0, .Text_Too_Long
		}
	}
	if .Read_Only in checked_states {
		if !append_spoken_part(temp[:], &cursor, "read only") {
			return 0, .Text_Too_Long
		}
	}

	if cursor == 0 {
		return 0, .Empty_Text
	}
	if cursor > len(out_buffer) {
		return 0, .Buffer_Too_Small
	}
	copy(out_buffer[:cursor], temp[:cursor])
	return cursor, .None
}
