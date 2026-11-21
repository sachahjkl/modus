// Multi-process sound mixer, microphone capture indicator, and device clock
// drift tracker (src/md/features/timed_stream.md).
//
// This package holds pure freestanding contracts and zero-allocation
// procedures shared between a class sound service and its clients:
//
//   - Mixer_State: mixes up to MAX_MIXER_STREAMS concurrent 48 kHz stereo
//     signed 16-bit PCM streams in 32-bit signed integers with exact
//     saturation clamping to [-32768, 32767], independent fixed-point Q16
//     gain, mute state, start-frame alignment, and per-stream underrun
//     counting.
//   - Capture_State: tracks active microphone capture readers and enforces a
//     mandatory visible indicator that cannot be cleared while any reader
//     holds a capture stream.
//   - Clock_Drift_Tracker: pure integer fixed-point rate estimator that
//     derives device crystal drift in parts per million from monotonic
//     completion samples, rejects backwards timestamps, ignores extreme
//     outliers, clamps to hardware crystal bounds, and predicts exact
//     adjusted frame counts and times over multi-hour spans with zero
//     floating-point arithmetic.
//
// This package allocates no memory and calls no kernel operation.
package sound_mixer

import "modus:contract/enum_word"
import "modus:contract/timed_stream"

// Maximum concurrent playback streams in one mixer instance.
MAX_MIXER_STREAMS :: 8

// Maximum concurrent microphone capture readers tracked by one capture state.
MAX_CAPTURE_READERS :: 8

// Fixed-point Q16 unity gain (1.0). Values above GAIN_UNITY are refused so
// per-stream scaling cannot amplify beyond unity before summing.
GAIN_UNITY :: u32(65536)

// Nominal stream format constants derived from timed_stream.
SAMPLE_RATE_HZ :: timed_stream.FRAME_RATE
CHANNELS :: timed_stream.CHANNELS
FRAME_BYTES :: timed_stream.FRAME_BYTES
NANOSECONDS_IN_A_SECOND :: timed_stream.NANOSECONDS_IN_A_SECOND

// Exact signed 16-bit PCM saturation bounds.
SAMPLE_MIN :: i32(min(i16))
SAMPLE_MAX :: i32(max(i16))

// Fixed-point parts-per-million scale and hardware crystal drift bounds.
PPM_SCALE :: i64(1_000_000)
DRIFT_PPM_LIMIT :: i64(500)
// Instantaneous interval deviation beyond 5 percent (50,000 ppm) indicates a
// scheduling stall or corrupted completion rather than crystal drift and is
// ignored without disturbing the accumulated estimate.
DRIFT_OUTLIER_PPM_LIMIT :: i64(50_000)

// Stack chunk size for zero-allocation period rendering.
@(private = "file")
RENDER_CHUNK_FRAMES :: 64

// One stereo PCM frame: left sample then right sample, signed 16-bit little
// endian, matching timed_stream.Format.Signed_16_Stereo_48000.
Stereo_Frame :: struct {
	left:  i16,
	right: i16,
}
#assert(size_of(Stereo_Frame) == FRAME_BYTES)

// State of one mixer playback slot.
Stream_Slot_State :: enum u32 {
	Free   = 0, // Slot is unused.
	Active = 1, // Slot is open and contributes scaled PCM samples when rendered.
	Muted  = 2, // Slot is open and silenced without releasing its slot.
}

// State of the mandatory microphone capture indicator.
Capture_Indicator_State :: enum u32 {
	Off    = 0, // No process holds a capture stream.
	Active = 1, // At least one process holds a capture stream; indicator must stay visible.
}

// Explicit refusal reason returned by mixer, capture, and clock drift borders.
Mixer_Refusal :: enum u32 {
	None                     = 0,
	Too_Many_Streams         = 1,
	Invalid_Slot             = 2,
	Slot_Not_Open            = 3,
	Gain_Out_Of_Range        = 4,
	Empty_Buffer             = 5,
	Frame_Range_Overflow     = 6,
	Too_Many_Capture_Readers = 7,
	Invalid_Capture_Reader   = 8,
	Capture_Reader_Not_Open  = 9,
	Capture_Indicator_Locked = 10,
	Clock_Moved_Backwards    = 11,
	Invalid_Clock_Sample     = 12,
}

// Border converters from transport words to closed enums.

stream_slot_state_of_word :: proc "contextless" (word: u32) -> (state: Stream_Slot_State, ok: bool) {
	return enum_word.member_of_word(Stream_Slot_State, u64(word))
}

capture_indicator_state_of_word :: proc "contextless" (word: u32) -> (state: Capture_Indicator_State, ok: bool) {
	return enum_word.member_of_word(Capture_Indicator_State, u64(word))
}

mixer_refusal_of_word :: proc "contextless" (word: u32) -> (refusal: Mixer_Refusal, ok: bool) {
	return enum_word.member_of_word(Mixer_Refusal, u64(word))
}

// One client playback stream slot inside Mixer_State.
Mixer_Stream_Slot :: struct {
	state:          Stream_Slot_State,
	gain_q16:       u32, // Fixed-point Q16 gain in [0, GAIN_UNITY].
	start_frame:    u64, // Timeline frame index corresponding to frames[0].
	frames:         []Stereo_Frame, // Caller-owned PCM frames; not owned or freed by the mixer.
	underrun_count: u64, // Periods where this active stream ran short before period end.
	frames_mixed:   u64, // Total frames read from this stream across rendered periods.
}

// Multi-stream 48 kHz stereo PCM mixer state. Zero-initialized state has zero
// active streams and renders silence.
Mixer_State :: struct {
	slots:               [MAX_MIXER_STREAMS]Mixer_Stream_Slot,
	active_stream_count: u32,
	total_underruns:     u64,
	periods_rendered:    u64,
}

// Microphone capture reader tracker with mandatory visible indicator state.
// Zero-initialized state has zero readers and indicator Off.
Capture_State :: struct {
	reader_open:         [MAX_CAPTURE_READERS]bool,
	active_reader_count: u32,
	indicator:           Capture_Indicator_State,
}

// Pure integer fixed-point hardware clock drift estimator.
// Zero-initialized state is uninitialized with 0 ppm drift.
Clock_Drift_Tracker :: struct {
	initialized:       bool,
	anchor_frame:      u64,
	anchor_time_ns:    u64,
	last_frame:        u64,
	last_time_ns:      u64,
	total_good_frames: u64,
	total_good_ns:     u64,
	sample_count:      u64,
	outlier_count:     u64,
	drift_ppm:         i64, // Estimated drift in parts per million, clamped to [-DRIFT_PPM_LIMIT, DRIFT_PPM_LIMIT].
}

// clamp_i32_to_i16 saturates an accumulated 32-bit sample to the exact signed
// 16-bit range [-32768, 32767] and never wraps.
clamp_i32_to_i16 :: proc "contextless" (value: i32) -> i16 {
	if value > SAMPLE_MAX {
		return max(i16)
	}
	if value < SAMPLE_MIN {
		return min(i16)
	}
	return i16(value)
}

// scale_sample_q16 scales one signed 16-bit sample by a validated Q16 gain in
// [0, GAIN_UNITY]. Using 64-bit intermediate multiplication guarantees zero
// overflow even at (-32768 * 65536).
@(private = "file")
scale_sample_q16 :: proc "contextless" (sample: i16, gain_q16: u32) -> i32 {
	if gain_q16 == GAIN_UNITY {
		return i32(sample)
	}
	if gain_q16 == 0 {
		return 0
	}
	return i32((i64(sample) * i64(gain_q16)) >> 16)
}

// mixer_open_stream allocates a free slot in mixer with initial start_frame
// and Q16 gain. Refuses gain > GAIN_UNITY or when MAX_MIXER_STREAMS are open,
// leaving mixer state unchanged on refusal.
mixer_open_stream :: proc "contextless" (mixer: ^Mixer_State, start_frame: u64 = 0, gain_q16: u32 = GAIN_UNITY) -> (slot_index: u32, refusal: Mixer_Refusal) {
	if mixer == nil {
		return 0, .Invalid_Slot
	}
	if gain_q16 > GAIN_UNITY {
		return 0, .Gain_Out_Of_Range
	}
	for index in u32(0) ..< MAX_MIXER_STREAMS {
		if mixer.slots[index].state == .Free {
			mixer.slots[index] = Mixer_Stream_Slot {
				state       = .Active,
				gain_q16    = gain_q16,
				start_frame = start_frame,
			}
			mixer.active_stream_count += 1
			return index, .None
		}
	}
	return 0, .Too_Many_Streams
}

// mixer_close_stream releases an open stream slot and zeroes its state.
mixer_close_stream :: proc "contextless" (mixer: ^Mixer_State, slot_index: u32) -> Mixer_Refusal {
	if mixer == nil || slot_index >= MAX_MIXER_STREAMS {
		return .Invalid_Slot
	}
	if mixer.slots[slot_index].state == .Free {
		return .Slot_Not_Open
	}
	mixer.slots[slot_index] = {}
	if mixer.active_stream_count > 0 {
		mixer.active_stream_count -= 1
	}
	return .None
}

// mixer_set_gain updates the Q16 gain of an open stream slot. Values past
// GAIN_UNITY are refused without changing the slot.
mixer_set_gain :: proc "contextless" (mixer: ^Mixer_State, slot_index: u32, gain_q16: u32) -> Mixer_Refusal {
	if mixer == nil || slot_index >= MAX_MIXER_STREAMS {
		return .Invalid_Slot
	}
	if mixer.slots[slot_index].state == .Free {
		return .Slot_Not_Open
	}
	if gain_q16 > GAIN_UNITY {
		return .Gain_Out_Of_Range
	}
	mixer.slots[slot_index].gain_q16 = gain_q16
	return .None
}

// mixer_set_muted sets or clears the mute state of an open stream slot.
mixer_set_muted :: proc "contextless" (mixer: ^Mixer_State, slot_index: u32, muted: bool) -> Mixer_Refusal {
	if mixer == nil || slot_index >= MAX_MIXER_STREAMS {
		return .Invalid_Slot
	}
	if mixer.slots[slot_index].state == .Free {
		return .Slot_Not_Open
	}
	mixer.slots[slot_index].state = muted ? .Muted : .Active
	return .None
}

// mixer_submit_frames attaches a timed PCM slice starting at start_frame to an
// open slot. Empty slices and frame ranges that overflow u64 are refused
// without modifying the slot.
mixer_submit_frames :: proc "contextless" (mixer: ^Mixer_State, slot_index: u32, start_frame: u64, frames: []Stereo_Frame) -> Mixer_Refusal {
	if mixer == nil || slot_index >= MAX_MIXER_STREAMS {
		return .Invalid_Slot
	}
	if mixer.slots[slot_index].state == .Free {
		return .Slot_Not_Open
	}
	if len(frames) == 0 {
		return .Empty_Buffer
	}
	if u64(len(frames)) > max(u64) - start_frame {
		return .Frame_Range_Overflow
	}
	mixer.slots[slot_index].start_frame = start_frame
	mixer.slots[slot_index].frames = frames
	return .None
}

// mixer_render_period mixes all active streams covering
// [period_start_frame, period_start_frame + len(out_stereo_frames)) into
// out_stereo_frames using 32-bit signed accumulation with exact 16-bit
// saturation clamping. Counts one underrun per active stream whose timeline
// has begun before the period end yet lacks samples through the period end.
mixer_render_period :: proc "contextless" (mixer: ^Mixer_State, out_stereo_frames: []Stereo_Frame, period_start_frame: u64) -> (rendered_frames: u64, refusal: Mixer_Refusal) {
	if mixer == nil {
		return 0, .Invalid_Slot
	}
	period_count := u64(len(out_stereo_frames))
	if period_count == 0 {
		return 0, .None
	}
	if period_count > max(u64) - period_start_frame {
		return 0, .Frame_Range_Overflow
	}
	period_end := period_start_frame + period_count

	// Account per-stream underruns once per rendered period for active slots
	// whose start_frame is inside or before this period yet whose queued buffer
	// ends before period_end.
	for index in 0 ..< MAX_MIXER_STREAMS {
		slot := &mixer.slots[index]
		switch slot.state {
		case .Free, .Muted:
			continue
		case .Active:
			slot_end := slot.start_frame + u64(len(slot.frames))
			if slot.start_frame < period_end && slot_end < period_end {
				slot.underrun_count += 1
				mixer.total_underruns += 1
			}
		}
	}

	// Render in fixed stack chunks so arbitrary period sizes require zero heap
	// allocation and zero per-frame inner-loop branching across channels.
	accum_left: [RENDER_CHUNK_FRAMES]i32
	accum_right: [RENDER_CHUNK_FRAMES]i32

	offset := u64(0)
	for offset < period_count {
		chunk_len := min(u64(RENDER_CHUNK_FRAMES), period_count - offset)
		chunk_start := period_start_frame + offset
		chunk_end := chunk_start + chunk_len

		for i in u64(0) ..< chunk_len {
			accum_left[i] = 0
			accum_right[i] = 0
		}

		for slot_idx in 0 ..< MAX_MIXER_STREAMS {
			slot := &mixer.slots[slot_idx]
			switch slot.state {
			case .Free, .Muted:
				continue
			case .Active:
				if len(slot.frames) == 0 {
					continue
				}
				slot_end := slot.start_frame + u64(len(slot.frames))
				overlap_start := max(chunk_start, slot.start_frame)
				overlap_end := min(chunk_end, slot_end)
				if overlap_start >= overlap_end {
					continue
				}
				gain := slot.gain_q16
				local_base := overlap_start - chunk_start
				src_base := overlap_start - slot.start_frame
				count := overlap_end - overlap_start
				for i in u64(0) ..< count {
					frame := slot.frames[src_base + i]
					accum_left[local_base + i] += scale_sample_q16(frame.left, gain)
					accum_right[local_base + i] += scale_sample_q16(frame.right, gain)
				}
				slot.frames_mixed += count
			}
		}

		for i in u64(0) ..< chunk_len {
			out_stereo_frames[offset + i] = Stereo_Frame {
				left  = clamp_i32_to_i16(accum_left[i]),
				right = clamp_i32_to_i16(accum_right[i]),
			}
		}
		offset += chunk_len
	}

	mixer.periods_rendered += 1
	return period_count, .None
}

// capture_open_reader registers a new microphone capture reader and sets the
// visible indicator to Active.
capture_open_reader :: proc "contextless" (state: ^Capture_State) -> (reader_index: u32, refusal: Mixer_Refusal) {
	if state == nil {
		return 0, .Invalid_Capture_Reader
	}
	for index in u32(0) ..< MAX_CAPTURE_READERS {
		if !state.reader_open[index] {
			state.reader_open[index] = true
			state.active_reader_count += 1
			state.indicator = .Active
			return index, .None
		}
	}
	return 0, .Too_Many_Capture_Readers
}

// capture_close_reader closes an active capture reader and turns the indicator
// Off only after the final reader has closed.
capture_close_reader :: proc "contextless" (state: ^Capture_State, reader_index: u32) -> Mixer_Refusal {
	if state == nil || reader_index >= MAX_CAPTURE_READERS {
		return .Invalid_Capture_Reader
	}
	if !state.reader_open[reader_index] {
		return .Capture_Reader_Not_Open
	}
	state.reader_open[reader_index] = false
	if state.active_reader_count > 0 {
		state.active_reader_count -= 1
	}
	state.indicator = state.active_reader_count > 0 ? .Active : .Off
	return .None
}

// capture_indicator_state reports the authoritative capture indicator state.
// Any active reader forces the indicator to Active.
capture_indicator_state :: proc "contextless" (state: ^Capture_State) -> Capture_Indicator_State {
	if state == nil || state.active_reader_count == 0 {
		return .Off
	}
	return .Active
}

// capture_clear_indicator explicitly refuses to clear the microphone indicator
// while any capture reader remains open.
capture_clear_indicator :: proc "contextless" (state: ^Capture_State) -> Mixer_Refusal {
	if state == nil {
		return .Invalid_Capture_Reader
	}
	if state.active_reader_count > 0 {
		state.indicator = .Active
		return .Capture_Indicator_Locked
	}
	state.indicator = .Off
	return .None
}

// div_u128_by_u64 computes exact unsigned 128-bit by 64-bit integer division
// using only shifts, subtractions, and comparisons so freestanding targets
// never emit compiler runtime calls (__udivti3).
@(private = "file")
div_u128_by_u64 :: proc "contextless" (dividend: u128, divisor: u64) -> (quotient: u128, remainder: u64) {
	rem: u128 = 0
	q: u128 = 0
	div := u128(divisor)
	for shift := u32(127); ; shift -= 1 {
		rem = (rem << 1) | ((dividend >> shift) & 1)
		if rem >= div {
			rem -= div
			q |= u128(1) << shift
		}
		if shift == 0 {
			break
		}
	}
	return q, u64(rem)
}

// compute_raw_drift_ppm computes exact signed parts-per-million deviation of
// (elapsed_frames / elapsed_ns) from nominal 48000 / 10^9 = 6 / 125000,
// rounded to the nearest integer ppm. Caller guarantees elapsed_ns > 0.
@(private = "file")
compute_raw_drift_ppm :: proc "contextless" (elapsed_frames: u64, elapsed_ns: u64) -> (ppm: i64, ok: bool) {
	if elapsed_ns == 0 {
		return 0, false
	}
	// Avoid overflowing u64 divisor (elapsed_ns * 6). When elapsed_ns exceeds
	// max(u64)/6 (~3.07e18 ns, >97 years), scale both sides down by 8.
	frames_u128 := u128(elapsed_frames)
	ns_u64 := elapsed_ns
	if ns_u64 > max(u64) / timed_stream.FRAMES_IN_A_STEP {
		frames_u128 >>= 3
		ns_u64 >>= 3
		if ns_u64 == 0 {
			return 0, false
		}
	}
	actual_scaled := frames_u128 * u128(timed_stream.NANOSECONDS_IN_A_STEP)
	nominal_scaled := u128(ns_u64) * u128(timed_stream.FRAMES_IN_A_STEP)
	denominator := ns_u64 * timed_stream.FRAMES_IN_A_STEP

	negative := actual_scaled < nominal_scaled
	diff := negative ? (nominal_scaled - actual_scaled) : (actual_scaled - nominal_scaled)

	// Scale difference by 1_000_000 (parts per million) and round to nearest.
	numerator := diff * u128(PPM_SCALE) + u128(denominator / 2)
	q, _ := div_u128_by_u64(numerator, denominator)
	if q > u128(max(i64) - 1) {
		return negative ? -max(i64) : max(i64), true
	}
	magnitude := i64(q)
	return negative ? -magnitude : magnitude, true
}

// clamp_drift_ppm clamps a raw ppm measurement to [-DRIFT_PPM_LIMIT, DRIFT_PPM_LIMIT].
@(private = "file")
clamp_drift_ppm :: proc "contextless" (raw_ppm: i64) -> i64 {
	if raw_ppm > DRIFT_PPM_LIMIT {
		return DRIFT_PPM_LIMIT
	}
	if raw_ppm < -DRIFT_PPM_LIMIT {
		return -DRIFT_PPM_LIMIT
	}
	return raw_ppm
}

// clock_drift_observe records one hardware completion sample
// (frame_count, monotonic_ns). Refuses backwards timestamps or backwards frame
// counts with Clock_Moved_Backwards, refuses duplicate timestamps with
// Invalid_Clock_Sample, ignores extreme rate outliers without perturbing the
// accumulated estimate, and clamps valid drift to [-DRIFT_PPM_LIMIT,
// +DRIFT_PPM_LIMIT].
clock_drift_observe :: proc "contextless" (tracker: ^Clock_Drift_Tracker, frame_count: u64, monotonic_ns: u64) -> Mixer_Refusal {
	if tracker == nil {
		return .Invalid_Clock_Sample
	}
	if !tracker.initialized {
		tracker.initialized = true
		tracker.anchor_frame = frame_count
		tracker.anchor_time_ns = monotonic_ns
		tracker.last_frame = frame_count
		tracker.last_time_ns = monotonic_ns
		tracker.total_good_frames = 0
		tracker.total_good_ns = 0
		tracker.sample_count = 1
		tracker.outlier_count = 0
		tracker.drift_ppm = 0
		return .None
	}
	if monotonic_ns < tracker.last_time_ns || frame_count < tracker.last_frame {
		return .Clock_Moved_Backwards
	}
	if monotonic_ns == tracker.last_time_ns {
		return .Invalid_Clock_Sample
	}

	step_frames := frame_count - tracker.last_frame
	step_ns := monotonic_ns - tracker.last_time_ns

	step_ppm, step_ok := compute_raw_drift_ppm(step_frames, step_ns)
	if !step_ok {
		return .Invalid_Clock_Sample
	}
	if step_ppm > DRIFT_OUTLIER_PPM_LIMIT || step_ppm < -DRIFT_OUTLIER_PPM_LIMIT {
		// Advance the reference point past the transient stall so the next
		// normal completion interval measures cleanly without including the gap.
		tracker.last_frame = frame_count
		tracker.last_time_ns = monotonic_ns
		tracker.outlier_count += 1
		return .None
	}

	if step_frames > max(u64) - tracker.total_good_frames || step_ns > max(u64) - tracker.total_good_ns {
		return .Frame_Range_Overflow
	}
	tracker.total_good_frames += step_frames
	tracker.total_good_ns += step_ns
	tracker.last_frame = frame_count
	tracker.last_time_ns = monotonic_ns
	tracker.sample_count += 1

	cumulative_ppm, cumulative_ok := compute_raw_drift_ppm(tracker.total_good_frames, tracker.total_good_ns)
	if !cumulative_ok {
		return .Invalid_Clock_Sample
	}
	tracker.drift_ppm = clamp_drift_ppm(cumulative_ppm)
	return .None
}

// clock_drift_predict_frames predicts the exact integer frame count elapsed
// over elapsed_ns monotonic nanoseconds at the tracker's adjusted rate,
// rounded to the nearest frame, with zero floating-point drift.
clock_drift_predict_frames :: proc "contextless" (tracker: ^Clock_Drift_Tracker, elapsed_ns: u64) -> (frames: u64, ok: bool) {
	ppm := tracker != nil ? clamp_drift_ppm(tracker.drift_ppm) : 0
	rate_scale := u64(PPM_SCALE + ppm) // Always in [999_500, 1_000_500].
	// frames = round(elapsed_ns * 6 * (1_000_000 + ppm) / (125_000 * 1_000_000))
	denominator := u64(timed_stream.NANOSECONDS_IN_A_STEP) * u64(PPM_SCALE)
	numerator := u128(elapsed_ns) * u128(u64(timed_stream.FRAMES_IN_A_STEP) * rate_scale) + u128(denominator / 2)
	q, _ := div_u128_by_u64(numerator, denominator)
	if q > u128(max(u64)) {
		return 0, false
	}
	return u64(q), true
}

// clock_drift_predict_time_ns predicts the exact monotonic nanoseconds elapsed
// for elapsed_frames hardware frames at the tracker's adjusted rate, rounded
// to the nearest nanosecond.
clock_drift_predict_time_ns :: proc "contextless" (tracker: ^Clock_Drift_Tracker, elapsed_frames: u64) -> (elapsed_ns: u64, ok: bool) {
	ppm := tracker != nil ? clamp_drift_ppm(tracker.drift_ppm) : 0
	rate_scale := u64(PPM_SCALE + ppm)
	// ns = round(elapsed_frames * 125_000 * 1_000_000 / (6 * (1_000_000 + ppm)))
	denominator := u64(timed_stream.FRAMES_IN_A_STEP) * rate_scale
	numerator := u128(elapsed_frames) * u128(u64(timed_stream.NANOSECONDS_IN_A_STEP) * u64(PPM_SCALE)) + u128(denominator / 2)
	q, _ := div_u128_by_u64(numerator, denominator)
	if q > u128(max(u64)) {
		return 0, false
	}
	return u64(q), true
}

// clock_drift_adjusted_rate_milli_hz returns the exact adjusted sample rate in
// millihertz (48_000_000 at 0 ppm, 48_004_800 at +100 ppm, 47_988_000 at -250 ppm).
clock_drift_adjusted_rate_milli_hz :: proc "contextless" (tracker: ^Clock_Drift_Tracker) -> u64 {
	ppm := tracker != nil ? clamp_drift_ppm(tracker.drift_ppm) : 0
	// 48000 Hz * 1000 mHz/Hz * (1_000_000 + ppm) / 1_000_000 = 48 * (1_000_000 + ppm)
	return u64(48) * u64(PPM_SCALE + ppm)
}
