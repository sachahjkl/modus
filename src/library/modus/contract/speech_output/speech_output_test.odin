#+build !freestanding
#+build !modus
package speech_output

import "core:testing"
import "modus:contract/accessibility"
import "modus:contract/sound_mixer"

// Border converters accept every closed member and refuse every unknown word.
@(test)
speech_output_borders_refuse_unknown_words :: proc(t: ^testing.T) {
	// Speech_Priority: 0 refused, 1..2 accepted, 3..255 refused.
	for word in 0 ..= 255 {
		p, ok := speech_priority_of_word(u8(word))
		if word == int(Speech_Priority.Polite) || word == int(Speech_Priority.Assertive) {
			testing.expectf(t, ok && u8(p) == u8(word), "valid priority %d refused", word)
		} else {
			testing.expectf(t, !ok, "unknown priority %d accepted as %v", word, p)
		}
	}

	// Speech_Toggle_State: 0..1 accepted, 2..255 refused.
	for word in 0 ..= 255 {
		s, ok := speech_toggle_state_of_word(u8(word))
		if word <= int(max(Speech_Toggle_State)) {
			testing.expectf(t, ok && u8(s) == u8(word), "valid toggle state %d refused", word)
		} else {
			testing.expectf(t, !ok, "unknown toggle state %d accepted as %v", word, s)
		}
	}

	// Speech_Refusal: 0..max accepted, past max refused.
	for word in 0 ..= 255 {
		r, ok := speech_refusal_of_word(u8(word))
		if word <= int(max(Speech_Refusal)) {
			testing.expectf(t, ok && u8(r) == u8(word), "valid refusal %d refused", word)
		} else {
			testing.expectf(t, !ok, "unknown refusal %d accepted as %v", word, r)
		}
	}
}

// Super+Alt+S toggle disables and enables speech cleanly, refusing enqueues
// while off and flushing pending utterances when toggled off.
@(test)
speech_toggle_and_voice_parameter_bounds :: proc(t: ^testing.T) {
	q: Speech_Queue
	speech_queue_init(&q, false)
	testing.expect_value(t, q.toggle_state, Speech_Toggle_State.Disabled)

	// Enqueue while disabled is refused with zero mutation.
	serial, refusal := speech_queue_enqueue(&q, .Polite, "Hello")
	testing.expect_value(t, refusal, Speech_Refusal.Speech_Disabled)
	testing.expect_value(t, serial, u64(0))
	testing.expect_value(t, q.count, u32(0))
	testing.expect_value(t, q.next_serial, u64(1))

	// Toggle on via Super+Alt+S.
	testing.expect_value(t, speech_queue_toggle(&q), Speech_Toggle_State.Enabled)
	serial, refusal = speech_queue_enqueue(&q, .Polite, "Speech on")
	testing.expect_value(t, refusal, Speech_Refusal.None)
	testing.expect_value(t, serial, u64(1))
	testing.expect_value(t, q.count, u32(1))

	// Rate edges: 0, 49, 401, max(u16) refused; 50 and 400 accepted.
	for bad_rate in ([?]u16{0, SPEECH_RATE_MIN - 1, SPEECH_RATE_MAX + 1, max(u16)}) {
		r := speech_queue_set_voice_parameters(&q, bad_rate, 100)
		testing.expect_value(t, r, Speech_Refusal.Rate_Out_Of_Range)
		testing.expect_value(t, q.rate_percent, SPEECH_RATE_DEFAULT)
	}
	// Pitch edges: 0, 49, 201, max(u16) refused; 50 and 200 accepted.
	for bad_pitch in ([?]u16{0, SPEECH_PITCH_MIN - 1, SPEECH_PITCH_MAX + 1, max(u16)}) {
		r := speech_queue_set_voice_parameters(&q, 100, bad_pitch)
		testing.expect_value(t, r, Speech_Refusal.Pitch_Out_Of_Range)
		testing.expect_value(t, q.pitch_percent, SPEECH_PITCH_DEFAULT)
	}

	testing.expect_value(t, speech_queue_set_voice_parameters(&q, SPEECH_RATE_MIN, SPEECH_PITCH_MIN), Speech_Refusal.None)
	testing.expect_value(t, speech_queue_set_voice_parameters(&q, SPEECH_RATE_MAX, SPEECH_PITCH_MAX), Speech_Refusal.None)

	// Toggle off flushes pending queue immediately.
	testing.expect_value(t, speech_queue_toggle(&q), Speech_Toggle_State.Disabled)
	testing.expect_value(t, q.count, u32(0))
	_, ok := speech_queue_dequeue(&q)
	testing.expect(t, !ok, "queue must be empty after toggling speech off")
}

// Hostile enqueue inputs (nil queue, invalid priority, empty/whitespace text,
// oversized text, invalid UTF-8/control bytes) are refused with zero mutation.
@(test)
speech_queue_refuses_hostile_enqueues_without_mutation :: proc(t: ^testing.T) {
	_, nil_r := speech_queue_enqueue(nil, .Polite, "Hi")
	testing.expect_value(t, nil_r, Speech_Refusal.Nil_Queue)

	q: Speech_Queue
	speech_queue_init(&q, true)
	snapshot := q

	_, r := speech_queue_enqueue(&q, Speech_Priority(0), "Zero priority")
	testing.expect_value(t, r, Speech_Refusal.Invalid_Priority)
	testing.expect_value(t, q, snapshot)

	_, r = speech_queue_enqueue(&q, Speech_Priority(99), "Unknown priority")
	testing.expect_value(t, r, Speech_Refusal.Invalid_Priority)
	testing.expect_value(t, q, snapshot)

	_, r = speech_queue_enqueue(&q, .Polite, "")
	testing.expect_value(t, r, Speech_Refusal.Empty_Text)
	testing.expect_value(t, q, snapshot)

	_, r = speech_queue_enqueue(&q, .Polite, "   ")
	testing.expect_value(t, r, Speech_Refusal.Empty_Text)
	testing.expect_value(t, q, snapshot)

	oversized: [SPEECH_UTTERANCE_TEXT_LIMIT + 1]u8
	for &b in oversized {
		b = 'a'
	}
	_, r = speech_queue_enqueue(&q, .Polite, string(oversized[:]))
	testing.expect_value(t, r, Speech_Refusal.Text_Too_Long)
	testing.expect_value(t, q, snapshot)

	// Exact bound (256 bytes) succeeds.
	exact_serial, exact_r := speech_queue_enqueue(&q, .Polite, string(oversized[:SPEECH_UTTERANCE_TEXT_LIMIT]))
	testing.expect_value(t, exact_r, Speech_Refusal.None)
	testing.expect_value(t, exact_serial, u64(1))
	_, _ = speech_queue_dequeue(&q)

	// Invalid UTF-8 and control bytes refused.
	bad_utf8 := [2]u8{0xFF, 0xFE}
	_, r = speech_queue_enqueue(&q, .Polite, string(bad_utf8[:]))
	testing.expect_value(t, r, Speech_Refusal.Invalid_Text)

	ctrl := [2]u8{'A', 0x00}
	_, r = speech_queue_enqueue(&q, .Polite, string(ctrl[:]))
	testing.expect_value(t, r, Speech_Refusal.Invalid_Text)
}

// Assertive utterances flush pending Polite utterances while preserving FIFO
// order among Assertive utterances; overflowing Polite utterances replace the
// oldest Polite entry and record replaced_polite_count.
@(test)
speech_queue_assertive_flushes_polite_and_ring_bounds_hold :: proc(t: ^testing.T) {
	q: Speech_Queue
	speech_queue_init(&q, true)

	// Enqueue 3 polite announcements.
	_, r1 := speech_queue_enqueue(&q, .Polite, "one")
	_, r2 := speech_queue_enqueue(&q, .Polite, "two")
	_, r3 := speech_queue_enqueue(&q, .Polite, "three")
	testing.expect(t, r1 == .None && r2 == .None && r3 == .None, "polite enqueues must succeed")
	testing.expect_value(t, q.count, u32(3))

	// Assertive alert flushes all 3 pending polite items immediately.
	s_alert, ra := speech_queue_enqueue(&q, .Assertive, "Disk full")
	testing.expect_value(t, ra, Speech_Refusal.None)
	testing.expect_value(t, s_alert, u64(4))
	testing.expect_value(t, q.count, u32(1))
	testing.expect_value(t, q.flushed_by_assertive_count, u64(3))

	// A second assertive alert queues behind the first assertive without flushing it.
	_, ra2 := speech_queue_enqueue(&q, .Assertive, "Battery critical")
	testing.expect_value(t, ra2, Speech_Refusal.None)
	testing.expect_value(t, q.count, u32(2))

	u1, ok1 := speech_queue_dequeue(&q)
	u2, ok2 := speech_queue_dequeue(&q)
	testing.expect(t, ok1 && ok2, "both assertive utterances must dequeue")
	testing.expect_value(t, speech_utterance_text(&u1), "Disk full")
	testing.expect_value(t, speech_utterance_text(&u2), "Battery critical")

	// Fill ring to exact capacity with Polite utterances, then add 2 more.
	for i in 0 ..< SPEECH_QUEUE_CAPACITY {
		label := [1]u8{u8('A' + i)}
		_, rp := speech_queue_enqueue(&q, .Polite, string(label[:]))
		testing.expect_value(t, rp, Speech_Refusal.None)
	}
	testing.expect_value(t, q.count, u32(SPEECH_QUEUE_CAPACITY))
	testing.expect_value(t, q.replaced_polite_count, u64(0))

	_, ro1 := speech_queue_enqueue(&q, .Polite, "X")
	_, ro2 := speech_queue_enqueue(&q, .Polite, "Y")
	testing.expect(t, ro1 == .None && ro2 == .None, "overflowing polite enqueue replaces oldest")
	testing.expect_value(t, q.count, u32(SPEECH_QUEUE_CAPACITY))
	testing.expect_value(t, q.replaced_polite_count, u64(2))

	front, ok_front := speech_queue_peek(&q)
	testing.expect(t, ok_front)
	// 'A' and 'B' were replaced, so 'C' is now at the front.
	testing.expect_value(t, speech_utterance_text(&front), "C")
}

// speech_utterance_for_element formats role, name, toggle, expanded, and states,
// shields Protected fields, and refuses invalid words or undersized buffers.
@(test)
speech_utterance_for_element_formats_and_protects_secrets :: proc(t: ^testing.T) {
	buf: [256]u8

	// Pressed button: "spleen, button, pressed".
	n, r := speech_utterance_for_element(.Button, "spleen", {.Focusable}, .True, .None, buf[:])
	testing.expect_value(t, r, Speech_Refusal.None)
	testing.expect_value(t, string(buf[:n]), "spleen, button, pressed")

	// Checked disabled checkbox: "High contrast, checkbox, checked, disabled".
	n, r = speech_utterance_for_element(.Checkbox, "High contrast", {.Focusable, .Disabled}, .True, .None, buf[:])
	testing.expect_value(t, r, Speech_Refusal.None)
	testing.expect_value(t, string(buf[:n]), "High contrast, checkbox, checked, disabled")

	// Expanded tree item: "Logs, treeitem, expanded, selected".
	n, r = speech_utterance_for_element(.Tree_Item, "Logs", {.Selected}, .None, .Expanded, buf[:])
	testing.expect_value(t, r, Speech_Refusal.None)
	testing.expect_value(t, string(buf[:n]), "Logs, treeitem, expanded, selected")

	// Protected field announces "Passphrase, protected field" without role/toggle leaks.
	n, r = speech_utterance_for_element(.Text_Box, "Passphrase", {.Focusable, .Protected}, .None, .None, buf[:])
	testing.expect_value(t, r, Speech_Refusal.None)
	testing.expect_value(t, string(buf[:n]), "Passphrase, protected field")

	// Undersized buffer is refused cleanly with written == 0.
	tiny: [4]u8
	n, r = speech_utterance_for_element(.Button, "spleen", {.Focusable}, .True, .None, tiny[:])
	testing.expect_value(t, r, Speech_Refusal.Buffer_Too_Small)
	testing.expect_value(t, n, 0)

	// Invalid enum words refused.
	_, r = speech_utterance_for_element(accessibility.Element_Role(255), "x", {}, .None, .None, buf[:])
	testing.expect_value(t, r, Speech_Refusal.Invalid_Role)
	_, r = speech_utterance_for_element(.Button, "x", transmute(accessibility.Element_States)(u32(1) << 31), .None, .None, buf[:])
	testing.expect_value(t, r, Speech_Refusal.Invalid_States)
	_, r = speech_utterance_for_element(.Button, "x", {}, accessibility.Toggle_State(9), .None, buf[:])
	testing.expect_value(t, r, Speech_Refusal.Invalid_Toggle)
	_, r = speech_utterance_for_element(.Button, "x", {}, .None, accessibility.Expanded_State(9), buf[:])
	testing.expect_value(t, r, Speech_Refusal.Invalid_Expanded)
}

// speech_mixer_submit_pcm bridges active speech audio frames into sound_mixer
// and mutes the slot when speech is disabled.
@(test)
speech_mixer_bridge_submits_and_mutes :: proc(t: ^testing.T) {
	q: Speech_Queue
	speech_queue_init(&q, true)

	mixer: sound_mixer.Mixer_State
	slot, open_refusal := sound_mixer.mixer_open_stream(&mixer, 0, sound_mixer.GAIN_UNITY)
	testing.expect_value(t, open_refusal, sound_mixer.Mixer_Refusal.None)

	pcm := [4]sound_mixer.Stereo_Frame{
		{left = 1000, right = 1000},
		{left = 2000, right = 2000},
		{left = 3000, right = 3000},
		{left = 4000, right = 4000},
	}
	sub_refusal := speech_mixer_submit_pcm(&q, &mixer, slot, 0, pcm[:])
	testing.expect_value(t, sub_refusal, sound_mixer.Mixer_Refusal.None)

	out_frames: [4]sound_mixer.Stereo_Frame
	rendered, render_refusal := sound_mixer.mixer_render_period(&mixer, out_frames[:], 0)
	testing.expect_value(t, render_refusal, sound_mixer.Mixer_Refusal.None)
	testing.expect_value(t, rendered, u64(4))
	testing.expect_value(t, out_frames[0].left, i16(1000))
	testing.expect_value(t, out_frames[3].right, i16(4000))

	// Toggling speech off mutes the mixer slot so rendered audio becomes silent.
	_ = speech_queue_toggle(&q)
	mute_refusal := speech_mixer_submit_pcm(&q, &mixer, slot, 4, pcm[:])
	testing.expect_value(t, mute_refusal, sound_mixer.Mixer_Refusal.None)
	testing.expect_value(t, mixer.slots[slot].state, sound_mixer.Stream_Slot_State.Muted)
}
