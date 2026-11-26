package doom

import "modus:contract/call_outcome"
import "modus:contract/ring"
import "modus:contract/timed_stream"
import "modus:contract/value_kinds"
import "modus:system"

// Format property: Doom mixes up to 8 simultaneous DMX sound channels.
SOUND_CHANNELS :: 8

// Format property: DMX digital sound lump header fields (format = 3).
DMX_FORMAT_PCM :: u16(3)
DMX_HEADER_BYTES :: 8
DMX_PAD_BYTES :: 16
DMX_RATE_MIN :: u32(1000)
DMX_RATE_MAX :: u32(96000)

// Plan value: 16 pages (64 KiB = 16384 stereo frames = ~341 ms at 48 kHz)
// circular sample region shared read-only with the sound service.
SOUND_REGION_PAGES :: 16
SOUND_REGION_BYTES :: SOUND_REGION_PAGES * system.PAGE_SIZE
SOUND_REGION_FRAMES :: SOUND_REGION_BYTES / timed_stream.FRAME_BYTES

// Format property: 48000 / 35 = 1371 frames with remainder 15/35 per Doom tic.
SOUND_FRAMES_PER_TIC_BASE :: timed_stream.FRAME_RATE / 35
SOUND_FRAMES_PER_TIC_REM :: timed_stream.FRAME_RATE % 35

// Plan value: keep submitted audio scheduled 80 ms ahead of the stream clock
// to absorb scheduling jitter without perceptible latency.
SOUND_LEAD_NANOSECONDS :: 80_000_000

SOUND_TAG_ATTACH :: u32(1)
SOUND_TAG_START :: u32(2)
SOUND_TAG_PLAY_FIRST :: u32(16)

Sound_Channel :: struct {
	active:     bool,
	samples:    [^]u8,
	count:      u32,
	pos_fp16:   u64, // Sample position in 48.16 fixed point.
	step_fp16:  u64, // Sample advance per 48 kHz output frame in 48.16 fixed point.
	left_gain:  i32, // 0..256 stereo left multiplier.
	right_gain: i32, // 0..256 stereo right multiplier.
}

Sound_Mixer :: struct {
	channels:     [SOUND_CHANNELS]Sound_Channel,
	tic_rem:      int,
}

Sound_Output :: struct {
	active:       bool,
	stream:       ring.Ring,
	region:       [^]u32,
	anchor:       timed_stream.Anchor,
	latency_ns:   u64,
	next_time_ns: u64,
	write_frame:  int,
	next_tag:     u32,
	in_flight:    int,
	mixer:        Sound_Mixer,
}

// dmx_parse validates a Doom DMX digital SFX lump (8-byte header followed by
// unsigned 8-bit PCM samples, stripping the standard 16-byte pre/post padding
// when present).
dmx_parse :: proc "contextless" (data: []u8) -> (sample_rate: u32, samples: []u8, ok: bool) {
	if len(data) <= DMX_HEADER_BYTES {
		return 0, nil, false
	}
	format := u16(data[0]) | (u16(data[1]) << 8)
	if format != DMX_FORMAT_PCM {
		return 0, nil, false
	}
	rate := u32(u16(data[2]) | (u16(data[3]) << 8))
	if rate < DMX_RATE_MIN || rate > DMX_RATE_MAX {
		return 0, nil, false
	}
	count := u32(data[4]) | (u32(data[5]) << 8) | (u32(data[6]) << 16) | (u32(data[7]) << 24)
	if count == 0 || int(count) > len(data) - DMX_HEADER_BYTES {
		return 0, nil, false
	}
	pcm := data[DMX_HEADER_BYTES : DMX_HEADER_BYTES + int(count)]
	if len(pcm) > DMX_PAD_BYTES * 2 {
		pcm = pcm[DMX_PAD_BYTES : len(pcm) - DMX_PAD_BYTES]
	}
	return rate, pcm, true
}

// stereo_gains converts Doom volume (0..127) and separation (0..254, 128 center)
// into 0..256 left and right integer gains.
stereo_gains :: proc "contextless" (vol, sep: int) -> (left_gain, right_gain: i32) {
	v := clamp(vol, 0, 127)
	s := clamp(sep, 0, 254)
	// Quadratic stereo pan matching Vanilla Doom / Chocolate Doom.
	left_scale := 256 - (s * s) / 256
	inv := 254 - s
	right_scale := 256 - (inv * inv) / 256
	left_gain = i32((v * left_scale) / 127)
	right_gain = i32((v * right_scale) / 127)
	return left_gain, right_gain
}

sound_mixer_start :: proc "contextless" (mixer: ^Sound_Mixer, channel: int, dmx: []u8, vol, sep: int) -> bool {
	if channel < 0 || channel >= SOUND_CHANNELS {
		return false
	}
	rate, pcm, ok := dmx_parse(dmx)
	if !ok || len(pcm) == 0 {
		return false
	}
	left_gain, right_gain := stereo_gains(vol, sep)
	step := (u64(rate) << 16) / u64(timed_stream.FRAME_RATE)
	if step == 0 {
		step = 1
	}
	mixer.channels[channel] = {
		active     = true,
		samples    = raw_data(pcm),
		count      = u32(len(pcm)),
		pos_fp16   = 0,
		step_fp16  = step,
		left_gain  = left_gain,
		right_gain = right_gain,
	}
	return true
}

sound_mixer_update_params :: proc "contextless" (mixer: ^Sound_Mixer, channel, vol, sep: int) {
	if channel < 0 || channel >= SOUND_CHANNELS || !mixer.channels[channel].active {
		return
	}
	mixer.channels[channel].left_gain, mixer.channels[channel].right_gain = stereo_gains(vol, sep)
}

sound_mixer_stop :: proc "contextless" (mixer: ^Sound_Mixer, channel: int) {
	if channel < 0 || channel >= SOUND_CHANNELS {
		return
	}
	mixer.channels[channel].active = false
}

sound_mixer_is_playing :: proc "contextless" (mixer: ^Sound_Mixer, channel: int) -> bool {
	if channel < 0 || channel >= SOUND_CHANNELS {
		return false
	}
	return mixer.channels[channel].active
}

// sound_mixer_tic_frames returns the exact number of 48 kHz frames for the next
// 35 Hz Doom tic using an exact Bresenham accumulator (35 tics = 48000 frames).
sound_mixer_tic_frames :: proc "contextless" (mixer: ^Sound_Mixer) -> int {
	frames := SOUND_FRAMES_PER_TIC_BASE
	mixer.tic_rem += SOUND_FRAMES_PER_TIC_REM
	if mixer.tic_rem >= 35 {
		mixer.tic_rem -= 35
		frames += 1
	}
	return frames
}

// sound_mixer_render mixes all active channels into `out` as packed little-endian
// stereo S16LE frames (low 16 bits left, high 16 bits right).
sound_mixer_render :: proc "contextless" (mixer: ^Sound_Mixer, out: []u32) {
	for i in 0 ..< len(out) {
		acc_l: i32
		acc_r: i32
		for &ch in mixer.channels {
			if !ch.active {
				continue
			}
			idx := u32(ch.pos_fp16 >> 16)
			if idx >= ch.count {
				ch.active = false
				continue
			}
			// Unsigned 8-bit DMX PCM centered at 128 -> signed 16-bit (-32768..32512).
			sample := (i32(ch.samples[idx]) - 128) * 128
			acc_l += (sample * ch.left_gain) >> 8
			acc_r += (sample * ch.right_gain) >> 8
			ch.pos_fp16 += ch.step_fp16
		}
		l := u32(u16(i16(clamp(acc_l, -32768, 32767))))
		r := u32(u16(i16(clamp(acc_r, -32768, 32767))))
		out[i] = l | (r << 16)
	}
}

@(private = "file")
sound_wait_tag :: proc "contextless" (stream: ^ring.Ring, tag: u32) -> (rec: ring.Record, ok: bool) {
	deadline := system.time() + system.ANSWER_BOUND_MILLISECONDS
	for {
		wait := system.wait_begin()
		for {
			received := system.receive(&stream.completions) or_break
			if received.tag == tag {
				return received, true
			}
		}
		if system.time() >= deadline {
			return {}, false
		}
		system.wait_records(&wait, &stream.completions)
		system.wait_end(&wait, deadline)
	}
}

// sound_open initializes optional timed_stream audio when a sound device ring
// is granted in ctx.handles[timed_stream.GRANT_RING]. Runs silent otherwise.
sound_open :: proc "contextless" (out: ^Sound_Output, ctx: ^system.Context) {
	ring_memory := ctx.handles[timed_stream.GRANT_RING]
	if ring_memory == 0 {
		system.log_fact(.Info, Sound_Absent{})
		return
	}
	status: call_outcome.Call_Outcome
	out.stream, status = system.ring_open(ring_memory)
	if status != .Succeeded {
		system.log_fact(.Info, Sound_Absent{})
		return
	}
	memory, mem_status := system.memory_create(SOUND_REGION_PAGES)
	address, map_status := system.memory_map(memory, {.Write})
	if mem_status != .Succeeded || map_status != .Succeeded {
		system.log_fact(.Info, Sound_Absent{})
		return
	}
	out.region = ([^]u32)(address)

	given: system.Handle
	give_status := call_outcome.Call_Outcome.Argument_Refused
	for deadline := system.time() + system.ANSWER_BOUND_MILLISECONDS; give_status != .Succeeded && system.time() < deadline; {
		if given, give_status = system.give(ring_memory, memory, {.Read}); give_status != .Succeeded {
			system.sleep(system.time() + 1)
		}
	}
	if give_status != .Succeeded {
		system.log_fact(.Info, Sound_Absent{})
		return
	}
	if !system.send(&out.stream.commands, ring.Record{kind = u32(timed_stream.Command.Attach), tag = SOUND_TAG_ATTACH, values = {0 = u64(given)}}) {
		return
	}
	attach_rec, attach_ok := sound_wait_tag(&out.stream, SOUND_TAG_ATTACH)
	if !attach_ok {
		return
	}
	attach_status, attach_known := timed_stream.status_of_completion_word(attach_rec.kind)
	if !attach_known || attach_status != .Ok {
		return
	}
	if !system.send(&out.stream.commands, ring.Record{kind = u32(timed_stream.Command.Start), tag = SOUND_TAG_START}) {
		return
	}
	start_rec, start_ok := sound_wait_tag(&out.stream, SOUND_TAG_START)
	if !start_ok {
		return
	}
	start_status, start_known := timed_stream.status_of_completion_word(start_rec.kind)
	if !start_known || start_status != .Ok {
		return
	}
	if start_rec.values[2] != u64(timed_stream.Format.Signed_16_Stereo_48000) {
		return
	}
	out.anchor = timed_stream.Anchor{frame = 0, time = start_rec.values[0]}
	out.latency_ns = start_rec.values[1]
	out.next_time_ns = system.nanoseconds() + max(out.latency_ns, SOUND_LEAD_NANOSECONDS)
	out.next_tag = SOUND_TAG_PLAY_FIRST
	out.active = true
	system.log_fact(.Info, Sound_Started{latency = value_kinds.Time_In_Nanoseconds(out.latency_ns)})
}

// sound_submit_tic drains completed Play records and submits one 35 Hz tic of
// mixed stereo PCM into the circular sample region without blocking.
sound_submit_tic :: proc "contextless" (out: ^Sound_Output) {
	if !out.active {
		return
	}
	// Drain completed Play records so the completion queue never fills.
	for {
		rec := system.receive(&out.stream.completions) or_break
		if out.in_flight > 0 {
			out.in_flight -= 1
		}
		if st, known := timed_stream.status_of_completion_word(rec.kind); known && st == .Device_Error {
			out.active = false
			return
		}
	}
	// Avoid overflowing the 16-page circular sample region (~11 tics capacity).
	if out.in_flight >= 8 {
		return
	}
	frames := sound_mixer_tic_frames(&out.mixer)
	if out.write_frame + frames > SOUND_REGION_FRAMES {
		out.write_frame = 0
	}
	slot := out.region[out.write_frame : out.write_frame + frames]
	sound_mixer_render(&out.mixer, slot)

	now := system.nanoseconds()
	earliest := now + max(out.latency_ns, SOUND_LEAD_NANOSECONDS)
	if out.next_time_ns < earliest {
		out.next_time_ns = earliest
	}
	place_bytes := u64(out.write_frame * timed_stream.FRAME_BYTES)
	record := ring.Record {
		kind = u32(timed_stream.Command.Play),
		tag  = out.next_tag,
		values = {
			0 = out.next_time_ns,
			1 = u64(timed_stream.Format.Signed_16_Stereo_48000),
			2 = u64(frames),
			3 = place_bytes,
		},
	}
	if system.send(&out.stream.commands, record) {
		out.in_flight += 1
		out.next_tag += 1
		if out.next_tag < SOUND_TAG_PLAY_FIRST {
			out.next_tag = SOUND_TAG_PLAY_FIRST
		}
		out.write_frame = (out.write_frame + frames) % SOUND_REGION_FRAMES
		step_ns := (u64(frames) * timed_stream.NANOSECONDS_IN_A_SECOND) / timed_stream.FRAME_RATE
		out.next_time_ns += step_ns
	}
}
