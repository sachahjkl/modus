#+build !freestanding
#+build !modus
package sound_mixer

import "core:testing"
import "modus:contract/timed_stream"

// Border enum decoders must reject out-of-range words and round-trip every
// valid member.
@(test)
enum_word_borders_refuse_unknown_values :: proc(t: ^testing.T) {
	for bad in ([]u32{u32(max(Stream_Slot_State)) + 1, max(u32)}) {
		_, ok := stream_slot_state_of_word(bad)
		testing.expectf(t, !ok, "unknown Stream_Slot_State word %d must be refused", bad)
	}
	for member in Stream_Slot_State {
		got, ok := stream_slot_state_of_word(u32(member))
		testing.expect(t, ok)
		testing.expect_value(t, got, member)
	}

	for bad in ([]u32{u32(max(Capture_Indicator_State)) + 1, max(u32)}) {
		_, ok := capture_indicator_state_of_word(bad)
		testing.expectf(t, !ok, "unknown Capture_Indicator_State word %d must be refused", bad)
	}
	for member in Capture_Indicator_State {
		got, ok := capture_indicator_state_of_word(u32(member))
		testing.expect(t, ok)
		testing.expect_value(t, got, member)
	}

	for bad in ([]u32{u32(max(Mixer_Refusal)) + 1, max(u32)}) {
		_, ok := mixer_refusal_of_word(bad)
		testing.expectf(t, !ok, "unknown Mixer_Refusal word %d must be refused", bad)
	}
	for member in Mixer_Refusal {
		got, ok := mixer_refusal_of_word(u32(member))
		testing.expect(t, ok)
		testing.expect_value(t, got, member)
	}
}

// Positive and negative i16 saturation clamping: must clamp to [+32767, -32768]
// and NEVER wrap, while still accumulating in full i32 before clamping.
@(test)
saturation_clamping_never_wraps :: proc(t: ^testing.T) {
	testing.expect_value(t, clamp_i32_to_i16(32767), i16(32767))
	testing.expect_value(t, clamp_i32_to_i16(32768), i16(32767))
	testing.expect_value(t, clamp_i32_to_i16(max(i32)), i16(32767))
	testing.expect_value(t, clamp_i32_to_i16(-32768), i16(-32768))
	testing.expect_value(t, clamp_i32_to_i16(-32769), i16(-32768))
	testing.expect_value(t, clamp_i32_to_i16(min(i32)), i16(-32768))
	testing.expect_value(t, clamp_i32_to_i16(0), i16(0))

	mixer: Mixer_State
	slot_a, ref_a := mixer_open_stream(&mixer, 0, GAIN_UNITY)
	slot_b, ref_b := mixer_open_stream(&mixer, 0, GAIN_UNITY)
	testing.expect_value(t, ref_a, Mixer_Refusal.None)
	testing.expect_value(t, ref_b, Mixer_Refusal.None)

	// +32767 + +32767 -> +32767 on left; -32768 + -32768 -> -32768 on right.
	buf_a := [2]Stereo_Frame{{left = 32767, right = -32768}, {left = 20000, right = -20000}}
	buf_b := [2]Stereo_Frame{{left = 32767, right = -32768}, {left = 20000, right = -20000}}
	testing.expect_value(t, mixer_submit_frames(&mixer, slot_a, 0, buf_a[:]), Mixer_Refusal.None)
	testing.expect_value(t, mixer_submit_frames(&mixer, slot_b, 0, buf_b[:]), Mixer_Refusal.None)

	out: [2]Stereo_Frame
	rendered, render_ref := mixer_render_period(&mixer, out[:], 0)
	testing.expect_value(t, render_ref, Mixer_Refusal.None)
	testing.expect_value(t, rendered, u64(2))
	testing.expect_value(t, out[0].left, i16(32767))
	testing.expect_value(t, out[0].right, i16(-32768))
	testing.expect_value(t, out[1].left, i16(32767))
	testing.expect_value(t, out[1].right, i16(-32768))

	// Add a 3rd stream with negative value to verify accumulation happens in i32
	// BEFORE clamping: (+32767 + +32767 - 32767) == +32767, and (+20000 + +20000 - 15000) == +25000.
	slot_c, ref_c := mixer_open_stream(&mixer, 0, GAIN_UNITY)
	testing.expect_value(t, ref_c, Mixer_Refusal.None)
	buf_c := [2]Stereo_Frame{{left = -32767, right = 32767}, {left = -15000, right = 15000}}
	testing.expect_value(t, mixer_submit_frames(&mixer, slot_c, 0, buf_c[:]), Mixer_Refusal.None)

	rendered, render_ref = mixer_render_period(&mixer, out[:], 0)
	testing.expect_value(t, render_ref, Mixer_Refusal.None)
	testing.expect_value(t, rendered, u64(2))
	testing.expect_value(t, out[0].left, i16(32767))
	testing.expect_value(t, out[0].right, i16(-32768))
	testing.expect_value(t, out[1].left, i16(25000))
	testing.expect_value(t, out[1].right, i16(-25000))
}

// Slot capacity, invalid slots, gain bounds, empty buffers, and u64 range
// overflows must all be refused without corrupting existing state.
@(test)
slot_bounds_gain_limits_and_overflows_are_refused :: proc(t: ^testing.T) {
	// Nil mixer refused everywhere.
	_, nil_ref := mixer_open_stream(nil)
	testing.expect_value(t, nil_ref, Mixer_Refusal.Invalid_Slot)
	testing.expect_value(t, mixer_close_stream(nil, 0), Mixer_Refusal.Invalid_Slot)
	testing.expect_value(t, mixer_set_gain(nil, 0, GAIN_UNITY), Mixer_Refusal.Invalid_Slot)
	testing.expect_value(t, mixer_set_muted(nil, 0, true), Mixer_Refusal.Invalid_Slot)
	_, nil_render_ref := mixer_render_period(nil, nil, 0)
	testing.expect_value(t, nil_render_ref, Mixer_Refusal.Invalid_Slot)

	mixer: Mixer_State

	// Gain past GAIN_UNITY (65537, max(u32)) refused at open without taking a slot.
	for bad_gain in ([]u32{GAIN_UNITY + 1, max(u32)}) {
		_, ref := mixer_open_stream(&mixer, 0, bad_gain)
		testing.expect_value(t, ref, Mixer_Refusal.Gain_Out_Of_Range)
		testing.expect_value(t, mixer.active_stream_count, u32(0))
	}

	// Open all 8 slots, then verify the 9th is refused with Too_Many_Streams.
	opened: [MAX_MIXER_STREAMS]u32
	for i in 0 ..< MAX_MIXER_STREAMS {
		slot, ref := mixer_open_stream(&mixer, 0, GAIN_UNITY)
		testing.expect_value(t, ref, Mixer_Refusal.None)
		opened[i] = slot
	}
	testing.expect_value(t, mixer.active_stream_count, u32(MAX_MIXER_STREAMS))
	_, ninth_ref := mixer_open_stream(&mixer, 0, GAIN_UNITY)
	testing.expect_value(t, ninth_ref, Mixer_Refusal.Too_Many_Streams)
	testing.expect_value(t, mixer.active_stream_count, u32(MAX_MIXER_STREAMS))

	// Gain 65537 and max(u32) refused on an open slot, leaving existing gain intact.
	testing.expect_value(t, mixer_set_gain(&mixer, opened[0], 32768), Mixer_Refusal.None)
	for bad_gain in ([]u32{GAIN_UNITY + 1, max(u32)}) {
		testing.expect_value(t, mixer_set_gain(&mixer, opened[0], bad_gain), Mixer_Refusal.Gain_Out_Of_Range)
		testing.expect_value(t, mixer.slots[opened[0]].gain_q16, u32(32768))
	}
	// Edge gains 0 and GAIN_UNITY accepted.
	testing.expect_value(t, mixer_set_gain(&mixer, opened[0], 0), Mixer_Refusal.None)
	testing.expect_value(t, mixer_set_gain(&mixer, opened[0], GAIN_UNITY), Mixer_Refusal.None)

	// Invalid slot indices refused.
	for bad_slot in ([]u32{MAX_MIXER_STREAMS, max(u32)}) {
		testing.expect_value(t, mixer_close_stream(&mixer, bad_slot), Mixer_Refusal.Invalid_Slot)
		testing.expect_value(t, mixer_set_gain(&mixer, bad_slot, GAIN_UNITY), Mixer_Refusal.Invalid_Slot)
		testing.expect_value(t, mixer_set_muted(&mixer, bad_slot, true), Mixer_Refusal.Invalid_Slot)
		one := [1]Stereo_Frame{{left = 1, right = 1}}
		testing.expect_value(t, mixer_submit_frames(&mixer, bad_slot, 0, one[:]), Mixer_Refusal.Invalid_Slot)
	}

	// Empty buffer and u64 frame range overflow refused.
	empty: []Stereo_Frame
	testing.expect_value(t, mixer_submit_frames(&mixer, opened[0], 0, empty), Mixer_Refusal.Empty_Buffer)
	two := [2]Stereo_Frame{{left = 10, right = 20}, {left = 30, right = 40}}
	testing.expect_value(t, mixer_submit_frames(&mixer, opened[0], max(u64) - 1, two[:]), Mixer_Refusal.Frame_Range_Overflow)
	testing.expect_value(t, mixer_submit_frames(&mixer, opened[0], max(u64), two[:1]), Mixer_Refusal.Frame_Range_Overflow)

	// Period render overflow refused.
	out: [4]Stereo_Frame
	_, ovf_ref := mixer_render_period(&mixer, out[:], max(u64) - 2)
	testing.expect_value(t, ovf_ref, Mixer_Refusal.Frame_Range_Overflow)

	// Closing one slot allows reopening, and double-close is refused.
	testing.expect_value(t, mixer_close_stream(&mixer, opened[3]), Mixer_Refusal.None)
	testing.expect_value(t, mixer.active_stream_count, u32(MAX_MIXER_STREAMS - 1))
	testing.expect_value(t, mixer_close_stream(&mixer, opened[3]), Mixer_Refusal.Slot_Not_Open)
	testing.expect_value(t, mixer_set_gain(&mixer, opened[3], 100), Mixer_Refusal.Slot_Not_Open)
	testing.expect_value(t, mixer_set_muted(&mixer, opened[3], true), Mixer_Refusal.Slot_Not_Open)

	reopened, reopen_ref := mixer_open_stream(&mixer, 100, GAIN_UNITY)
	testing.expect_value(t, reopen_ref, Mixer_Refusal.None)
	testing.expect_value(t, reopened, opened[3])
}

// Zero streams produce silence (overwriting pre-filled buffer), 8 streams mix
// accurately across chunk boundaries (480 frames), gains and mute work, and
// offset/overlapping start_frame alignments + underruns are exact.
@(test)
mixing_zero_one_eight_streams_and_offset_alignments :: proc(t: ^testing.T) {
	mixer: Mixer_State

	// 0 active streams: output must be zeroed even if pre-filled with garbage.
	out: [timed_stream.PERIOD_FRAMES]Stereo_Frame
	for &f in out {
		f = {left = 12345, right = -12345}
	}
	rendered, ref := mixer_render_period(&mixer, out[:], 0)
	testing.expect_value(t, ref, Mixer_Refusal.None)
	testing.expect_value(t, rendered, u64(timed_stream.PERIOD_FRAMES))
	for f in out {
		testing.expect_value(t, f, Stereo_Frame{0, 0})
	}

	// Zero-length output buffer is a valid no-op.
	empty_out: []Stereo_Frame
	rendered, ref = mixer_render_period(&mixer, empty_out, 0)
	testing.expect_value(t, ref, Mixer_Refusal.None)
	testing.expect_value(t, rendered, u64(0))

	// 8 simultaneous streams across a full 480-frame period (crosses multiple
	// internal 64-frame stack chunks cleanly).
	stream_buffers: [MAX_MIXER_STREAMS][timed_stream.PERIOD_FRAMES]Stereo_Frame
	for s in 0 ..< MAX_MIXER_STREAMS {
		slot, open_ref := mixer_open_stream(&mixer, 0, GAIN_UNITY)
		testing.expect_value(t, open_ref, Mixer_Refusal.None)
		for i in 0 ..< timed_stream.PERIOD_FRAMES {
			stream_buffers[s][i] = Stereo_Frame{left = i16((s + 1) * 100), right = i16(-((s + 1) * 50))}
		}
		testing.expect_value(t, mixer_submit_frames(&mixer, slot, 0, stream_buffers[s][:]), Mixer_Refusal.None)
	}
	// Set stream 0 to half gain (32768 -> 50 left, -25 right) and mute stream 7 (800 left, -400 right -> 0).
	testing.expect_value(t, mixer_set_gain(&mixer, 0, GAIN_UNITY / 2), Mixer_Refusal.None)
	testing.expect_value(t, mixer_set_muted(&mixer, 7, true), Mixer_Refusal.None)

	rendered, ref = mixer_render_period(&mixer, out[:], 0)
	testing.expect_value(t, ref, Mixer_Refusal.None)
	testing.expect_value(t, rendered, u64(timed_stream.PERIOD_FRAMES))
	// Expected left: 50 + 200 + 300 + 400 + 500 + 600 + 700 + 0 = 2750
	// Expected right: -25 - 100 - 150 - 200 - 250 - 300 - 350 + 0 = -1375
	for f in out {
		testing.expect_value(t, f.left, i16(2750))
		testing.expect_value(t, f.right, i16(-1375))
	}
	testing.expect_value(t, mixer.total_underruns, u64(0))

	// Test overlapping / offset start_frame alignments and underrun accounting.
	offset_mixer: Mixer_State
	s_early, _ := mixer_open_stream(&offset_mixer, 0, GAIN_UNITY) // Covers [90, 105) -> overlaps [100, 105), underruns [105, 120)
	s_mid, _ := mixer_open_stream(&offset_mixer, 0, GAIN_UNITY) // Covers [103, 125) -> overlaps [103, 120), no underrun
	s_future, _ := mixer_open_stream(&offset_mixer, 500, GAIN_UNITY) // Future [500, 510) -> no overlap, no underrun

	early_buf: [15]Stereo_Frame
	for &f in early_buf {
		f = {left = 1000, right = -1000}
	}
	mid_buf: [22]Stereo_Frame
	for &f in mid_buf {
		f = {left = 2000, right = 500}
	}
	future_buf: [10]Stereo_Frame
	for &f in future_buf {
		f = {left = 9999, right = 9999}
	}
	testing.expect_value(t, mixer_submit_frames(&offset_mixer, s_early, 90, early_buf[:]), Mixer_Refusal.None)
	testing.expect_value(t, mixer_submit_frames(&offset_mixer, s_mid, 103, mid_buf[:]), Mixer_Refusal.None)
	testing.expect_value(t, mixer_submit_frames(&offset_mixer, s_future, 500, future_buf[:]), Mixer_Refusal.None)

	period_out: [20]Stereo_Frame
	rendered, ref = mixer_render_period(&offset_mixer, period_out[:], 100)
	testing.expect_value(t, ref, Mixer_Refusal.None)
	testing.expect_value(t, rendered, u64(20))

	// [100, 103): only s_early -> (1000, -1000)
	for i in 0 ..< 3 {
		testing.expect_value(t, period_out[i], Stereo_Frame{1000, -1000})
	}
	// [103, 105): s_early + s_mid -> (3000, -500)
	for i in 3 ..< 5 {
		testing.expect_value(t, period_out[i], Stereo_Frame{3000, -500})
	}
	// [105, 120): only s_mid -> (2000, 500)
	for i in 5 ..< 20 {
		testing.expect_value(t, period_out[i], Stereo_Frame{2000, 500})
	}

	testing.expect_value(t, offset_mixer.slots[s_early].underrun_count, u64(1))
	testing.expect_value(t, offset_mixer.slots[s_mid].underrun_count, u64(0))
	testing.expect_value(t, offset_mixer.slots[s_future].underrun_count, u64(0))
	testing.expect_value(t, offset_mixer.total_underruns, u64(1))
}

// Microphone capture indicator must stay lit while any reader holds a capture
// stream, refuse explicit clearing while readers are open, and turn off only
// when the last reader closes.
@(test)
capture_indicator_stays_lit_until_last_reader_closes :: proc(t: ^testing.T) {
	state: Capture_State
	testing.expect_value(t, capture_indicator_state(&state), Capture_Indicator_State.Off)
	testing.expect_value(t, capture_clear_indicator(&state), Mixer_Refusal.None)

	// Nil and out-of-range reader operations refused.
	_, nil_ref := capture_open_reader(nil)
	testing.expect_value(t, nil_ref, Mixer_Refusal.Invalid_Capture_Reader)
	testing.expect_value(t, capture_close_reader(nil, 0), Mixer_Refusal.Invalid_Capture_Reader)
	testing.expect_value(t, capture_clear_indicator(nil), Mixer_Refusal.Invalid_Capture_Reader)
	testing.expect_value(t, capture_indicator_state(nil), Capture_Indicator_State.Off)

	readers: [MAX_CAPTURE_READERS]u32
	for i in 0 ..< MAX_CAPTURE_READERS {
		r, ref := capture_open_reader(&state)
		testing.expect_value(t, ref, Mixer_Refusal.None)
		readers[i] = r
		testing.expect_value(t, capture_indicator_state(&state), Capture_Indicator_State.Active)
		testing.expect_value(t, state.indicator, Capture_Indicator_State.Active)
	}
	// 9th reader refused.
	_, extra_ref := capture_open_reader(&state)
	testing.expect_value(t, extra_ref, Mixer_Refusal.Too_Many_Capture_Readers)

	// Clearing indicator while readers exist is refused and keeps indicator Active.
	testing.expect_value(t, capture_clear_indicator(&state), Mixer_Refusal.Capture_Indicator_Locked)
	testing.expect_value(t, capture_indicator_state(&state), Capture_Indicator_State.Active)
	testing.expect_value(t, state.indicator, Capture_Indicator_State.Active)

	// Close 7 of 8 readers: indicator must stay Active after each close.
	for i in 0 ..< MAX_CAPTURE_READERS - 1 {
		testing.expect_value(t, capture_close_reader(&state, readers[i]), Mixer_Refusal.None)
		testing.expect_value(t, capture_indicator_state(&state), Capture_Indicator_State.Active)
		testing.expect_value(t, capture_clear_indicator(&state), Mixer_Refusal.Capture_Indicator_Locked)
	}
	// Double-close and out-of-range close refused.
	testing.expect_value(t, capture_close_reader(&state, readers[0]), Mixer_Refusal.Capture_Reader_Not_Open)
	testing.expect_value(t, capture_close_reader(&state, MAX_CAPTURE_READERS), Mixer_Refusal.Invalid_Capture_Reader)
	testing.expect_value(t, capture_close_reader(&state, max(u32)), Mixer_Refusal.Invalid_Capture_Reader)

	// Close the final reader: indicator turns Off and clear succeeds.
	testing.expect_value(t, capture_close_reader(&state, readers[MAX_CAPTURE_READERS - 1]), Mixer_Refusal.None)
	testing.expect_value(t, state.active_reader_count, u32(0))
	testing.expect_value(t, capture_indicator_state(&state), Capture_Indicator_State.Off)
	testing.expect_value(t, state.indicator, Capture_Indicator_State.Off)
	testing.expect_value(t, capture_clear_indicator(&state), Mixer_Refusal.None)
}

// Clock drift estimation at 0 ppm, +100 ppm, -250 ppm, crystal bound clamping
// (±500 ppm), outlier immunity, backwards timestamp refusal, and exact 1+ hour
// integer rate prediction with zero floating-point drift.
@(test)
clock_drift_estimator_accuracy_bounds_and_backwards_refusal :: proc(t: ^testing.T) {
	ONE_SEC :: u64(NANOSECONDS_IN_A_SECOND)
	ONE_HOUR :: u64(3600) * ONE_SEC

	// Nil tracker refused.
	testing.expect_value(t, clock_drift_observe(nil, 0, 0), Mixer_Refusal.Invalid_Clock_Sample)

	// 1. Exact 0 ppm over 100 seconds.
	zero_tracker: Clock_Drift_Tracker
	testing.expect_value(t, clock_drift_observe(&zero_tracker, 0, 1_000_000), Mixer_Refusal.None)
	for sec in u64(1) ..= 100 {
		testing.expect_value(t, clock_drift_observe(&zero_tracker, sec * SAMPLE_RATE_HZ, 1_000_000 + sec * ONE_SEC), Mixer_Refusal.None)
	}
	testing.expect_value(t, zero_tracker.drift_ppm, i64(0))
	testing.expect_value(t, clock_drift_adjusted_rate_milli_hz(&zero_tracker), u64(48_000_000))
	hour_frames, ok := clock_drift_predict_frames(&zero_tracker, ONE_HOUR)
	testing.expect(t, ok)
	testing.expect_value(t, hour_frames, u64(3600 * SAMPLE_RATE_HZ))

	// 2. Exact +100 ppm over 100 seconds (48004.8 frames/sec -> 4_800_480 frames in 100s).
	fast_tracker: Clock_Drift_Tracker
	testing.expect_value(t, clock_drift_observe(&fast_tracker, 1000, 5_000_000_000), Mixer_Refusal.None)
	for step in u64(1) ..= 10 {
		// Every 10 seconds: 480_000 + 48 = 480_048 frames.
		testing.expect_value(t, clock_drift_observe(&fast_tracker, 1000 + step * 480_048, 5_000_000_000 + step * 10 * ONE_SEC), Mixer_Refusal.None)
	}
	testing.expect_value(t, fast_tracker.drift_ppm, i64(100))
	testing.expect_value(t, clock_drift_adjusted_rate_milli_hz(&fast_tracker), u64(48_004_800))

	// Predict over 1 hour and 2 hours: +100 ppm adds exactly 17,280 frames/hour (+0.36 s).
	fast_1h, fast_1h_ok := clock_drift_predict_frames(&fast_tracker, ONE_HOUR)
	testing.expect(t, fast_1h_ok)
	testing.expect_value(t, fast_1h, u64(172_800_000 + 17_280))
	fast_2h, fast_2h_ok := clock_drift_predict_frames(&fast_tracker, 2 * ONE_HOUR)
	testing.expect(t, fast_2h_ok)
	testing.expect_value(t, fast_2h, u64(345_600_000 + 34_560))

	// Inverse prediction must recover exact 1 hour nanoseconds.
	fast_ns, fast_ns_ok := clock_drift_predict_time_ns(&fast_tracker, fast_1h)
	testing.expect(t, fast_ns_ok)
	testing.expect_value(t, fast_ns, ONE_HOUR)

	// 3. Exact -250 ppm over 100 seconds (47988 frames/sec -> 479_880 frames per 10s).
	slow_tracker: Clock_Drift_Tracker
	testing.expect_value(t, clock_drift_observe(&slow_tracker, 0, 10 * ONE_SEC), Mixer_Refusal.None)
	for step in u64(1) ..= 10 {
		testing.expect_value(t, clock_drift_observe(&slow_tracker, step * 479_880, 10 * ONE_SEC + step * 10 * ONE_SEC), Mixer_Refusal.None)
	}
	testing.expect_value(t, slow_tracker.drift_ppm, i64(-250))
	testing.expect_value(t, clock_drift_adjusted_rate_milli_hz(&slow_tracker), u64(47_988_000))
	slow_1h, slow_1h_ok := clock_drift_predict_frames(&slow_tracker, ONE_HOUR)
	testing.expect(t, slow_1h_ok)
	testing.expect_value(t, slow_1h, u64(172_800_000 - 43_200))
	slow_ns, slow_ns_ok := clock_drift_predict_time_ns(&slow_tracker, slow_1h)
	testing.expect(t, slow_ns_ok)
	testing.expect_value(t, slow_ns, ONE_HOUR)

	// 4. Backwards timestamps and backwards frame counts MUST be refused with
	// Clock_Moved_Backwards without changing tracker state; duplicate timestamp
	// refused with Invalid_Clock_Sample.
	saved_last_frame := fast_tracker.last_frame
	saved_last_ns := fast_tracker.last_time_ns
	saved_ppm := fast_tracker.drift_ppm
	testing.expect_value(t, clock_drift_observe(&fast_tracker, saved_last_frame + 480, saved_last_ns - 1), Mixer_Refusal.Clock_Moved_Backwards)
	testing.expect_value(t, clock_drift_observe(&fast_tracker, saved_last_frame + 480, 0), Mixer_Refusal.Clock_Moved_Backwards)
	testing.expect_value(t, clock_drift_observe(&fast_tracker, saved_last_frame - 1, saved_last_ns + ONE_SEC), Mixer_Refusal.Clock_Moved_Backwards)
	testing.expect_value(t, clock_drift_observe(&fast_tracker, saved_last_frame + 480, saved_last_ns), Mixer_Refusal.Invalid_Clock_Sample)
	testing.expect_value(t, fast_tracker.last_frame, saved_last_frame)
	testing.expect_value(t, fast_tracker.last_time_ns, saved_last_ns)
	testing.expect_value(t, fast_tracker.drift_ppm, saved_ppm)

	// 5. Extreme outlier (5 second scheduling stall with only 480 frames) is
	// ignored without corrupting drift_ppm, and normal samples after it keep
	// tracking +100 ppm cleanly.
	testing.expect_value(t, clock_drift_observe(&fast_tracker, saved_last_frame + 480, saved_last_ns + 5 * ONE_SEC), Mixer_Refusal.None)
	testing.expect_value(t, fast_tracker.outlier_count, u64(1))
	testing.expect_value(t, fast_tracker.drift_ppm, i64(100))
	after_outlier_frame := fast_tracker.last_frame
	after_outlier_ns := fast_tracker.last_time_ns
	testing.expect_value(t, clock_drift_observe(&fast_tracker, after_outlier_frame + 480_048, after_outlier_ns + 10 * ONE_SEC), Mixer_Refusal.None)
	testing.expect_value(t, fast_tracker.drift_ppm, i64(100))

	// 6. Clamping to sane hardware crystal bounds (±500 ppm) for sustained
	// drifts above ±500 ppm (within the 5% outlier guard).
	clamp_pos: Clock_Drift_Tracker
	testing.expect_value(t, clock_drift_observe(&clamp_pos, 0, ONE_SEC), Mixer_Refusal.None)
	// +1000 ppm: 48_048 frames in 1 second -> clamped to +500 ppm.
	testing.expect_value(t, clock_drift_observe(&clamp_pos, 48_048, 2 * ONE_SEC), Mixer_Refusal.None)
	testing.expect_value(t, clamp_pos.drift_ppm, DRIFT_PPM_LIMIT)

	clamp_neg: Clock_Drift_Tracker
	testing.expect_value(t, clock_drift_observe(&clamp_neg, 0, ONE_SEC), Mixer_Refusal.None)
	// -1000 ppm: 47_952 frames in 1 second -> clamped to -500 ppm.
	testing.expect_value(t, clock_drift_observe(&clamp_neg, 47_952, 2 * ONE_SEC), Mixer_Refusal.None)
	testing.expect_value(t, clamp_neg.drift_ppm, -DRIFT_PPM_LIMIT)
}
