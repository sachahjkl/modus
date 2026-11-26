#+build !freestanding
package doom

import "core:testing"
import "modus:contract/timed_stream"

@(private = "file")
make_dmx_lump :: proc(rate: u16, samples: []u8) -> []u8 {
	out := make([]u8, DMX_HEADER_BYTES + len(samples))
	out[0] = u8(DMX_FORMAT_PCM & 0xFF)
	out[1] = u8(DMX_FORMAT_PCM >> 8)
	out[2] = u8(rate & 0xFF)
	out[3] = u8(rate >> 8)
	n := u32(len(samples))
	out[4] = u8(n & 0xFF)
	out[5] = u8((n >> 8) & 0xFF)
	out[6] = u8((n >> 16) & 0xFF)
	out[7] = u8((n >> 24) & 0xFF)
	copy(out[DMX_HEADER_BYTES:], samples)
	return out
}

@(test)
dmx_parse_refuses_bad_lumps_and_accepts_valid_pcm :: proc(t: ^testing.T) {
	// Too short.
	_, _, ok := dmx_parse([]u8{3, 0, 0x11, 0x2B, 1, 0, 0, 0})
	testing.expect(t, !ok)

	// Wrong format word.
	bad_fmt := [?]u8{2, 0, 0x11, 0x2B, 4, 0, 0, 0, 128, 128, 128, 128}
	_, _, ok = dmx_parse(bad_fmt[:])
	testing.expect(t, !ok)

	// Sample rate out of bounds (0 and > 96000).
	bad_rate := [?]u8{3, 0, 0, 0, 4, 0, 0, 0, 128, 128, 128, 128}
	_, _, ok = dmx_parse(bad_rate[:])
	testing.expect(t, !ok)

	// Count exceeds payload length.
	truncated := [?]u8{3, 0, 0x11, 0x2B, 10, 0, 0, 0, 128, 128}
	_, _, ok = dmx_parse(truncated[:])
	testing.expect(t, !ok)

	// Valid 11025 Hz lump with 16-byte DMX pre/post padding stripped.
	raw_samples := make([]u8, 40)
	defer delete(raw_samples)
	for i in 0 ..< len(raw_samples) {
		raw_samples[i] = u8(128 + i)
	}
	lump := make_dmx_lump(11025, raw_samples)
	defer delete(lump)
	rate, pcm, valid := dmx_parse(lump)
	testing.expect(t, valid)
	testing.expect_value(t, rate, u32(11025))
	testing.expect_value(t, len(pcm), 40 - 32)
	testing.expect_value(t, pcm[0], u8(128 + 16))
}

@(test)
sound_mixer_exact_tic_rate_and_stereo_pan :: proc(t: ^testing.T) {
	mixer: Sound_Mixer
	total_frames := 0
	for _ in 0 ..< 35 {
		total_frames += sound_mixer_tic_frames(&mixer)
	}
	testing.expect_value(t, total_frames, timed_stream.FRAME_RATE)

	// Full positive sample (255), panned hard left (sep=0) and hard right (sep=254).
	pcm := [?]u8{255, 255, 255, 255, 255, 255, 255, 255}
	lump := make_dmx_lump(11025, pcm[:])
	defer delete(lump)

	testing.expect(t, !sound_mixer_start(&mixer, -1, lump, 127, 128))
	testing.expect(t, !sound_mixer_start(&mixer, SOUND_CHANNELS, lump, 127, 128))
	testing.expect(t, sound_mixer_start(&mixer, 0, lump, 127, 0))
	testing.expect(t, sound_mixer_is_playing(&mixer, 0))

	out: [8]u32
	sound_mixer_render(&mixer, out[:])
	left := i16(u16(out[0] & 0xFFFF))
	right := i16(u16(out[0] >> 16))
	testing.expect(t, left > 8000)
	testing.expect(t, right < 500)

	sound_mixer_stop(&mixer, 0)
	testing.expect(t, !sound_mixer_is_playing(&mixer, 0))
}
