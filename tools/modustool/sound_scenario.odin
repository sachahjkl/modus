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
	{kind = .Wait, text = "tone: a second sample region is refused with Bad_Command: as it must"},
	{kind = .Wait, text = "tone: a Start with a value is refused with Bad_Command: as it must"},
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
		fmt.eprintfln("modustool: the sound output %s: %s (the line names the frame %d; the first frame that is not silence: %d; frames that are not silence: %d, the tone has %d; crossings of zero in %d frames: %d, a tone of %d Hz has %d)", output_file, SOUND_OUTPUT_PROBLEM_TEXTS[found.problem], frame, found.first_sound_frame, found.sound_frames, TONE_CHECK_FRAMES, TONE_WINDOW_FRAMES, found.crossings, TONE_CHECK_HERTZ, tone_crossings_expected())
		return false
	}
	switch found.place {
	case .At_The_Frame_Of_The_Line:
		test_passed_print("the sound output holds the tone from the frame %d, the frame that the line of tone names, with %d frames that are not silence and %d crossings of zero in %d frames (a tone of %d Hz has %d); it holds %d frames", found.first_sound_frame, found.sound_frames, found.crossings, TONE_WINDOW_FRAMES, TONE_CHECK_HERTZ, tone_crossings_expected(), found.frames)
	case .After_Frames_Of_The_Device:
		// Not a failure: QEMU wrote frames that the stream did not give,
		// which depends on the load of the host. The place is not proved.
		test_passed_print("the sound output holds the tone with %d frames that are not silence and %d crossings of zero in %d frames (a tone of %d Hz has %d); it starts at the frame %d, %d frames after the frame that the line names: QEMU wrote frames that the stream did not give, so the place is not proved", found.sound_frames, found.crossings, TONE_WINDOW_FRAMES, TONE_CHECK_HERTZ, tone_crossings_expected(), found.first_sound_frame, found.first_sound_frame - frame)
	}
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

// The tone of src/modules/demonstrations/tone: its frequency, its frames,
// and the window of its frames that the check counts crossings in, its
// first 100 ms.
TONE_CHECK_HERTZ :: 440
TONE_CHECK_FRAMES :: timed_stream.FRAME_RATE / 2
TONE_WINDOW_FRAMES :: timed_stream.FRAME_RATE / 10
// The first frame of the tone can differ from the frame of the line by a
// conversion of QEMU: a few frames, never a period.
TONE_FRAME_TOLERANCE :: 2
// A count of crossings is exact to one crossing at each end of the window.
TONE_CROSSINGS_TOLERANCE :: 2
// A frame of the tone where both samples are below one step of 16 bits is
// silence: about one in 24000 frames of a cosine at half of the largest
// sample.
TONE_LENGTH_TOLERANCE :: 8

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
	Tone_Early, // The tone starts before the frame of the line: the file holds fewer frames before it than the stream gave.
	Too_Short, // The file holds fewer frames of the tone than the window of the check.
	Wrong_Frequency, // The crossings of zero are not those of the tone.
	Wrong_Length, // The frames that are not silence are not the frames of the tone.
}

@(rodata)
SOUND_OUTPUT_PROBLEM_TEXTS := [Sound_Output_Problem]string {
	.None            = "",
	.Not_Wave        = "it has no header of a wave file of PCM",
	.Not_The_Format  = "its channels, its rate or its bits are not 2 channels of 48000 frames of 16 bits",
	.No_Sound        = "each frame is silence",
	.Tone_Early      = "the tone starts before the frame of the line",
	.Too_Short       = "it holds fewer frames of the tone than the window of the check",
	.Wrong_Frequency = "the left channel does not cross zero as a tone of 440 Hz does",
	.Wrong_Length    = "its frames that are not silence are not the 24000 frames of the tone",
}

// Where the tone is in the file, against the frame of the line. QEMU
// writes each frame that the stream gives, in order; a file whose tone is
// later than the line holds frames that the stream did not give, which a
// backend that pads by its timer writes. The place is then not proved.
Tone_Place :: enum {
	At_The_Frame_Of_The_Line, // The file starts with the frame 0 of the stream, and the place is proved.
	After_Frames_Of_The_Device, // The file holds frames before the tone that the stream did not give.
}

// What the check found in a sound output.
Tone_Check :: struct {
	problem:           Sound_Output_Problem,
	place:             Tone_Place,
	frames:            int,
	first_sound_frame: int, // -1: none.
	sound_frames:      int, // The frames that are not silence, from the first one.
	crossings:         int,
}

// frame_is_silence says if both samples of a frame of a file are 0.
@(private = "file")
frame_is_silence :: proc(frames: []u8, index: int) -> bool {
	return byte_order.read_u32_little_endian(frames, index * timed_stream.FRAME_BYTES) == 0
}

// tone_check reads a wave file of the sound device: its header, then its
// frames to the end of the file. QEMU writes the sizes of the header only
// at a clean end, so the check does not read them. It finds the tone by
// its own start, the first frame that is not silence, and counts only the
// frames that are not silence: frames of silence that the device wrote
// before or inside the tone change neither its frequency nor its length.
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
		if !frame_is_silence(frames, index) {
			check.first_sound_frame = index
			break
		}
	}
	switch {
	case check.first_sound_frame < 0:
		check.problem = .No_Sound
		return
	case check.first_sound_frame < expected_frame - TONE_FRAME_TOLERANCE:
		check.problem = .Tone_Early
		return
	}
	check.place = check.first_sound_frame <= expected_frame + TONE_FRAME_TOLERANCE ? .At_The_Frame_Of_The_Line : .After_Frames_Of_The_Device
	// The crossings over the first frames of the tone that are not
	// silence. The sign of the left sample: a zero keeps the sign before it.
	positive := i16(byte_order.read_u16_little_endian(frames, check.first_sound_frame * timed_stream.FRAME_BYTES)) > 0
	for index in check.first_sound_frame ..< check.frames {
		if frame_is_silence(frames, index) {
			continue
		}
		check.sound_frames += 1
		if check.sound_frames > TONE_WINDOW_FRAMES {
			continue
		}
		sample := i16(byte_order.read_u16_little_endian(frames, index * timed_stream.FRAME_BYTES))
		if sample != 0 && (sample > 0) != positive {
			positive = sample > 0
			check.crossings += 1
		}
	}
	switch {
	case check.sound_frames < TONE_WINDOW_FRAMES:
		check.problem = .Too_Short
	case abs(check.crossings - tone_crossings_expected()) > TONE_CROSSINGS_TOLERANCE:
		check.problem = .Wrong_Frequency
	case abs(check.sound_frames - TONE_CHECK_FRAMES) > TONE_LENGTH_TOLERANCE:
		check.problem = .Wrong_Length
	}
	return
}
