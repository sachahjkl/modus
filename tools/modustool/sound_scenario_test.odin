package modustool

import "core:math"
import "core:testing"
import "modus:contract/byte_order"
import "modus:contract/timed_stream"

// A wave file as QEMU writes it at a stop that is not clean: the sizes of
// the header are 0. `tone_first` is the first frame of a cosine of
// `hertz`, -1 for silence only.
@(private = "file")
wave_make :: proc(frames: int, tone_first: int, hertz: f64, channels: u16 = timed_stream.CHANNELS, rate: u32 = timed_stream.FRAME_RATE, bits: u16 = WAVE_BITS, format: u16 = WAVE_FORMAT_PCM) -> []u8 {
	file := make([]u8, WAVE_HEADER_BYTES + frames * timed_stream.FRAME_BYTES, context.temp_allocator)
	copy(file[0:], "RIFF")
	copy(file[8:], "WAVE")
	copy(file[12:], "fmt ")
	byte_order.write_u32_little_endian(file, 16, 16)
	byte_order.write_u16_little_endian(file, 20, format)
	byte_order.write_u16_little_endian(file, 22, channels)
	byte_order.write_u32_little_endian(file, 24, rate)
	byte_order.write_u16_little_endian(file, 34, bits)
	copy(file[36:], "data")
	if tone_first >= 0 {
		for index in tone_first ..< frames {
			phase := 2 * math.PI * hertz * f64(index - tone_first) / timed_stream.FRAME_RATE
			sample := u16(i16(math.cos(phase) * 16384))
			byte_order.write_u16_little_endian(file, WAVE_HEADER_BYTES + index * timed_stream.FRAME_BYTES, sample)
			byte_order.write_u16_little_endian(file, WAVE_HEADER_BYTES + index * timed_stream.FRAME_BYTES + 2, sample)
		}
	}
	return file
}

TONE_FRAME_OF_THE_TEST :: 24000
FRAMES_OF_THE_TEST :: TONE_FRAME_OF_THE_TEST + TONE_CHECK_FRAMES

// silence_insert gives a copy of a wave file with `count` frames of
// silence before the frame `at`: what a device that pads by its timer
// writes.
@(private = "file")
silence_insert :: proc(file: []u8, at: int, count: int) -> []u8 {
	place := WAVE_HEADER_BYTES + at * timed_stream.FRAME_BYTES
	padded := make([]u8, len(file) + count * timed_stream.FRAME_BYTES, context.temp_allocator)
	copy(padded, file[:place])
	copy(padded[place + count * timed_stream.FRAME_BYTES:], file[place:])
	return padded
}

// A file that is not a wave file of PCM is refused: too short for a
// header, another first word, another fourth word, a format that is not
// PCM.
@(test)
a_file_that_is_not_a_wave_of_pcm_is_refused :: proc(t: ^testing.T) {
	good := wave_make(FRAMES_OF_THE_TEST, TONE_FRAME_OF_THE_TEST, TONE_CHECK_HERTZ)
	testing.expect_value(t, tone_check(good[:WAVE_HEADER_BYTES - 1], TONE_FRAME_OF_THE_TEST).problem, Sound_Output_Problem.Not_Wave)
	testing.expect_value(t, tone_check(nil, TONE_FRAME_OF_THE_TEST).problem, Sound_Output_Problem.Not_Wave)
	for place in ([]int{0, 8, 12, 36}) {
		damaged := wave_make(FRAMES_OF_THE_TEST, TONE_FRAME_OF_THE_TEST, TONE_CHECK_HERTZ)
		damaged[place] = 'X'
		testing.expectf(t, tone_check(damaged, TONE_FRAME_OF_THE_TEST).problem == .Not_Wave, "a word changed at %d is taken", place)
	}
	floats := wave_make(FRAMES_OF_THE_TEST, TONE_FRAME_OF_THE_TEST, TONE_CHECK_HERTZ, format = WAVE_FORMAT_PCM + 2)
	testing.expect_value(t, tone_check(floats, TONE_FRAME_OF_THE_TEST).problem, Sound_Output_Problem.Not_Wave)
}

// A wave in another format is refused: one channel, another rate, 8 bits.
@(test)
a_wave_of_another_format_is_refused :: proc(t: ^testing.T) {
	others := [?][]u8 {
		wave_make(FRAMES_OF_THE_TEST, TONE_FRAME_OF_THE_TEST, TONE_CHECK_HERTZ, channels = timed_stream.CHANNELS - 1),
		wave_make(FRAMES_OF_THE_TEST, TONE_FRAME_OF_THE_TEST, TONE_CHECK_HERTZ, rate = 44100),
		wave_make(FRAMES_OF_THE_TEST, TONE_FRAME_OF_THE_TEST, TONE_CHECK_HERTZ, rate = timed_stream.FRAME_RATE + 1),
		wave_make(FRAMES_OF_THE_TEST, TONE_FRAME_OF_THE_TEST, TONE_CHECK_HERTZ, bits = WAVE_BITS / 2),
	}
	for other in others {
		testing.expect_value(t, tone_check(other, TONE_FRAME_OF_THE_TEST).problem, Sound_Output_Problem.Not_The_Format)
	}
}

// Silence only, a header with no frame, a tone one frame before the
// tolerance and at the frame 0, a tone too near the end for the window, a
// tone too long and too short, and a tone of another frequency are
// refused.
@(test)
a_tone_out_of_its_place_or_its_frequency_is_refused :: proc(t: ^testing.T) {
	testing.expect_value(t, tone_check(wave_make(FRAMES_OF_THE_TEST, -1, 0), TONE_FRAME_OF_THE_TEST).problem, Sound_Output_Problem.No_Sound)
	testing.expect_value(t, tone_check(wave_make(0, -1, 0), TONE_FRAME_OF_THE_TEST).problem, Sound_Output_Problem.No_Sound)
	for first in ([]int{TONE_FRAME_OF_THE_TEST - TONE_FRAME_TOLERANCE - 1, 0}) {
		found := tone_check(wave_make(first + TONE_CHECK_FRAMES, first, TONE_CHECK_HERTZ), TONE_FRAME_OF_THE_TEST)
		testing.expect_value(t, found.problem, Sound_Output_Problem.Tone_Early)
		testing.expect_value(t, found.first_sound_frame, first)
	}
	short := wave_make(TONE_FRAME_OF_THE_TEST + TONE_WINDOW_FRAMES - 1, TONE_FRAME_OF_THE_TEST, TONE_CHECK_HERTZ)
	testing.expect_value(t, tone_check(short, TONE_FRAME_OF_THE_TEST).problem, Sound_Output_Problem.Too_Short)
	// Past the tolerance by more than the few frames of a cosine that are
	// silence.
	for length in ([]int{TONE_CHECK_FRAMES + 4 * TONE_LENGTH_TOLERANCE, TONE_CHECK_FRAMES - 4 * TONE_LENGTH_TOLERANCE, TONE_WINDOW_FRAMES}) {
		found := tone_check(wave_make(TONE_FRAME_OF_THE_TEST + length, TONE_FRAME_OF_THE_TEST, TONE_CHECK_HERTZ), TONE_FRAME_OF_THE_TEST)
		testing.expectf(t, found.problem == .Wrong_Length, "a tone of %d frames gives %v", length, found.problem)
	}
	// A tone of 455 Hz crosses about 91 times in the window, and one of
	// 425 Hz about 85 times: each is past the tolerance around 88.
	for hertz in ([]f64{2 * TONE_CHECK_HERTZ, TONE_CHECK_HERTZ / 2, TONE_CHECK_HERTZ + 15, TONE_CHECK_HERTZ - 15}) {
		found := tone_check(wave_make(FRAMES_OF_THE_TEST, TONE_FRAME_OF_THE_TEST, hertz), TONE_FRAME_OF_THE_TEST)
		testing.expectf(t, found.problem == .Wrong_Frequency, "a tone of %v Hz gives %v with %d crossings", hertz, found.problem, found.crossings)
	}
}

// The frame of the line of `tone`: no line, a line with no number, then
// the last line of two.
@(test)
the_frame_of_the_line_of_the_tone :: proc(t: ^testing.T) {
	_, named := tone_frame_of_log("tone: the stream started\n")
	testing.expect(t, !named)
	_, named = tone_frame_of_log(TONE_FRAME_LINE + "of the stream\n")
	testing.expect(t, !named)
	frame: int
	frame, named = tone_frame_of_log(TONE_FRAME_LINE + "12 of the stream\n" + TONE_FRAME_LINE + "24000 of the stream for 24000 frames\n")
	testing.expect(t, named)
	testing.expect_value(t, frame, 24000)
}

// Silence that a device writes before the tone and inside it changes
// neither its frequency nor its length; the place is then not proved, and
// the check says so.
@(test)
silence_from_the_device_does_not_move_the_tone :: proc(t: ^testing.T) {
	good := wave_make(FRAMES_OF_THE_TEST, TONE_FRAME_OF_THE_TEST, TONE_CHECK_HERTZ)
	before := silence_insert(good, 0, 1000)
	inside := silence_insert(before, TONE_FRAME_OF_THE_TEST + 1000 + TONE_WINDOW_FRAMES / 2, 500)
	for padded in ([][]u8{before, inside}) {
		found := tone_check(padded, TONE_FRAME_OF_THE_TEST)
		testing.expect_value(t, found.problem, Sound_Output_Problem.None)
		testing.expect_value(t, found.place, Tone_Place.After_Frames_Of_The_Device)
		testing.expect_value(t, found.first_sound_frame, TONE_FRAME_OF_THE_TEST + 1000)
		testing.expectf(t, abs(found.crossings - tone_crossings_expected()) <= 1, "%d crossings", found.crossings)
	}
	// One frame past the tolerance is not proved either.
	late := wave_make(FRAMES_OF_THE_TEST + 1, TONE_FRAME_OF_THE_TEST + TONE_FRAME_TOLERANCE + 1, TONE_CHECK_HERTZ)
	found := tone_check(late, TONE_FRAME_OF_THE_TEST)
	testing.expect_value(t, found.problem, Sound_Output_Problem.None)
	testing.expect_value(t, found.place, Tone_Place.After_Frames_Of_The_Device)
}

// The tone at its frame, and at the edge of the tolerance, last: no
// problem, the place proved, its first frame, and 88 crossings.
@(test)
the_tone_at_its_frame_passes :: proc(t: ^testing.T) {
	testing.expect_value(t, tone_crossings_expected(), 88)
	for first in ([]int{TONE_FRAME_OF_THE_TEST, TONE_FRAME_OF_THE_TEST + TONE_FRAME_TOLERANCE, TONE_FRAME_OF_THE_TEST - TONE_FRAME_TOLERANCE}) {
		found := tone_check(wave_make(first + TONE_CHECK_FRAMES, first, TONE_CHECK_HERTZ), TONE_FRAME_OF_THE_TEST)
		testing.expect_value(t, found.problem, Sound_Output_Problem.None)
		testing.expect_value(t, found.place, Tone_Place.At_The_Frame_Of_The_Line)
		testing.expect_value(t, found.first_sound_frame, first)
		testing.expectf(t, abs(found.crossings - tone_crossings_expected()) <= 1, "%d crossings", found.crossings)
		testing.expectf(t, abs(found.sound_frames - TONE_CHECK_FRAMES) <= TONE_LENGTH_TOLERANCE, "%d frames that are not silence", found.sound_frames)
	}
}
