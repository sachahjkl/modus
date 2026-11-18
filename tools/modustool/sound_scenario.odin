package modustool

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "modus:contract/byte_order"
import "modus:contract/timed_stream"

// Sound, the first timed stream: one machine with a virtio sound device
// whose output goes to a wave file (src/md/features/timed_stream.md, "The
// proof"). The program `tone` asks for a tone of 440 Hz at 500 ms after the
// frame 0 of the stream, checks six refusals of the sound service, and
// writes the frame where the tone played. A second `tone` is refused while
// the first one holds the device. After the machine, the tool reads the
// file: the first frame that is not silence must be the frame of the line,
// and the left channel must cross zero as a tone of 440 Hz does. The check
// counts frames: it reads no time of the host.

TEST_OUTPUT_SOUND :: BUILD_FOLDER + "/test_output_sound.txt"
// The wave file of the sound device, beside the log of its machine.
SOUND_OUTPUT_SUFFIX :: "_sound.wav"

// The line of `tone` that names the frame where the tone played.
TONE_FRAME_LINE :: "tone: the tone of 440 Hz played from the frame "

scenario_sound := [?]Step {
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"tone\")"},
	// The root service writes its line when the start returns, and the
	// sound service writes its own at the same time.
	{kind = .Wait, text = "root: started sound for the device at the place 20 of the bus", any_order = true},
	{kind = .Wait, text = "sound: ok, the output stream 0 of 2, 48000 frames in one second, 2 channels of signed 16-bit samples; 4 periods of 480 frames with the device; a transmit queue of 64"},
	{kind = .Wait, text = "sound: the stream started: the frame 0 plays at "},
	{kind = .Wait, text = "tone: the stream started; the service holds 40000000 ns of frames"},
	{kind = .Wait, text = "tone: a record over the tone is refused with Overlap: as it must"},
	{kind = .Wait, text = "tone: a record at the frame 0 is refused with Late: as it must"},
	{kind = .Wait, text = "tone: a record 20 s ahead is refused with Too_Far: as it must"},
	{kind = .Wait, text = "tone: a record of an unknown format is refused with Bad_Command: as it must"},
	{kind = .Wait, text = "tone: a record of too many frames is refused with Bad_Command: as it must"},
	{kind = .Wait, text = "tone: a record past the end of the region is refused with Out_Of_Range: as it must"},
	{kind = .Wait, text = TONE_FRAME_LINE + "24000 of the stream for 24000 frames; underruns before its end: "},
	{kind = .Wait, text = "tone: the tone played at the frame of its time: as it must"},
	// One program plays at a time.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"tone\")"},
	{kind = .Wait, text = "root: cannot start tone: the sound device plays for another program; one program plays at a time"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

sound_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	output_file := machine_file(TEST_OUTPUT_SOUND, SOUND_OUTPUT_SUFFIX)
	_ = os.remove(output_file)
	if !machine_test(part, scenario_sound[:], {volume = BOOT_VOLUME, output = TEST_OUTPUT_SOUND, exit_status = MACHINE_STOP_OK, sound_device = true}) {
		return false
	}
	machine_log, log_error := os.read_entire_file(TEST_OUTPUT_SOUND, context.temp_allocator)
	if log_error != nil {
		fmt.eprintfln("modustool: cannot read %s: %v", TEST_OUTPUT_SOUND, log_error)
		return false
	}
	frame, named := tone_frame_of_log(string(machine_log))
	if !named {
		fmt.eprintfln("modustool: the log %s has no line \"%s<frame>\"", TEST_OUTPUT_SOUND, TONE_FRAME_LINE)
		return false
	}
	file, file_error := os.read_entire_file(output_file, context.temp_allocator)
	if file_error != nil {
		fmt.eprintfln("modustool: cannot read the sound output %s: %v", output_file, file_error)
		return false
	}
	found := tone_check(file, frame)
	if found.problem != .None {
		fmt.eprintfln("modustool: the sound output %s: %s (the line names the frame %d; the first frame that is not silence: %d; crossings of zero in %d frames: %d, a tone of %d Hz has %d)", output_file, SOUND_OUTPUT_PROBLEM_TEXTS[found.problem], frame, found.first_sound_frame, TONE_WINDOW_FRAMES, found.crossings, TONE_CHECK_HERTZ, tone_crossings_expected())
		return false
	}
	test_passed_print("the sound output holds the tone from the frame %d, as the line of tone names, with %d crossings of zero in %d frames (a tone of %d Hz has %d); it holds %d frames", found.first_sound_frame, found.crossings, TONE_WINDOW_FRAMES, TONE_CHECK_HERTZ, tone_crossings_expected(), found.frames)
	// The file of a test that passed would fill the build folder: about
	// 192 KB for each second of the machine.
	_ = os.remove(output_file)
	return true
}

// tone_frame_of_log gives the frame that the last line of `tone` names.
tone_frame_of_log :: proc(log: string) -> (frame: int, named: bool) {
	place := strings.last_index(log, TONE_FRAME_LINE)
	if place < 0 {
		return 0, false
	}
	rest := log[place + len(TONE_FRAME_LINE):]
	digits := 0
	for digits < len(rest) && rest[digits] >= '0' && rest[digits] <= '9' {
		digits += 1
	}
	if digits == 0 {
		return 0, false
	}
	return strconv.parse_int(rest[:digits], 10)
}

// The tone of src/modules/demonstrations/tone, and the window of frames
// that the check counts in: 100 ms after its first frame, well inside its
// 500 ms, so the frames that QEMU held at the stop of the machine do not
// matter.
TONE_CHECK_HERTZ :: 440
TONE_WINDOW_FRAMES :: timed_stream.FRAME_RATE / 10
// The first frame of the tone can differ from the frame of the line by a
// conversion of QEMU: a few frames, never a period.
TONE_FRAME_TOLERANCE :: 2
// A count of crossings is exact to one crossing at each end of the window.
TONE_CROSSINGS_TOLERANCE :: 2

// The header of the wave file that QEMU writes: 44 bytes, PCM.
WAVE_HEADER_BYTES :: 44
WAVE_FORMAT_PCM :: 1
WAVE_BITS :: 16

tone_crossings_expected :: proc() -> int {
	return 2 * TONE_CHECK_HERTZ * TONE_WINDOW_FRAMES / timed_stream.FRAME_RATE
}

// What is wrong with a sound output.
Sound_Output_Problem :: enum {
	None,
	Not_Wave, // The file has no header of a wave file of PCM.
	Not_The_Format, // Its channels, rate or bits are not the format of the timed stream.
	No_Sound, // Each frame is silence.
	Tone_Elsewhere, // The first frame that is not silence is not the frame of the line.
	Too_Short, // The file ends before the window of the check.
	Wrong_Frequency, // The crossings of zero are not those of the tone.
}

@(rodata)
SOUND_OUTPUT_PROBLEM_TEXTS := [Sound_Output_Problem]string {
	.None            = "",
	.Not_Wave        = "it has no header of a wave file of PCM",
	.Not_The_Format  = "its channels, its rate or its bits are not 2 channels of 48000 frames of 16 bits",
	.No_Sound        = "each frame is silence",
	.Tone_Elsewhere  = "the tone does not start at the frame of the line",
	.Too_Short       = "it ends before the window of the check",
	.Wrong_Frequency = "the left channel does not cross zero as a tone of 440 Hz does",
}

// What the check found in a sound output.
Tone_Check :: struct {
	problem:           Sound_Output_Problem,
	frames:            int,
	first_sound_frame: int, // -1: none.
	crossings:         int,
}

// tone_check reads a wave file of the sound device: its header, then its
// frames to the end of the file. QEMU writes the sizes of the header only
// at a clean end, so the check does not read them.
tone_check :: proc(file: []u8, expected_frame: int) -> (check: Tone_Check) {
	check.first_sound_frame = -1
	if len(file) < WAVE_HEADER_BYTES || string(file[0:4]) != "RIFF" || string(file[8:12]) != "WAVE" || string(file[12:16]) != "fmt " || string(file[36:40]) != "data" || byte_order.read_u16_little_endian(file, 20) != WAVE_FORMAT_PCM {
		check.problem = .Not_Wave
		return
	}
	if byte_order.read_u16_little_endian(file, 22) != timed_stream.CHANNELS || byte_order.read_u32_little_endian(file, 24) != timed_stream.FRAME_RATE || byte_order.read_u16_little_endian(file, 34) != WAVE_BITS {
		check.problem = .Not_The_Format
		return
	}
	frames := file[WAVE_HEADER_BYTES:]
	check.frames = len(frames) / timed_stream.FRAME_BYTES
	for index in 0 ..< check.frames {
		if byte_order.read_u32_little_endian(frames, index * timed_stream.FRAME_BYTES) != 0 {
			check.first_sound_frame = index
			break
		}
	}
	switch {
	case check.first_sound_frame < 0:
		check.problem = .No_Sound
		return
	case abs(check.first_sound_frame - expected_frame) > TONE_FRAME_TOLERANCE:
		check.problem = .Tone_Elsewhere
		return
	case check.first_sound_frame + TONE_WINDOW_FRAMES > check.frames:
		check.problem = .Too_Short
		return
	}
	// The sign of the left sample: a zero keeps the sign before it.
	positive := i16(byte_order.read_u16_little_endian(frames, check.first_sound_frame * timed_stream.FRAME_BYTES)) > 0
	for index in check.first_sound_frame + 1 ..< check.first_sound_frame + TONE_WINDOW_FRAMES {
		sample := i16(byte_order.read_u16_little_endian(frames, index * timed_stream.FRAME_BYTES))
		if sample != 0 && (sample > 0) != positive {
			positive = sample > 0
			check.crossings += 1
		}
	}
	if abs(check.crossings - tone_crossings_expected()) > TONE_CROSSINGS_TOLERANCE {
		check.problem = .Wrong_Frequency
	}
	return
}
