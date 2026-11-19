// The process `tone`: a tone of 440 Hz through the sound service, at a
// time that it names (src/md/features/timed_stream.md).
//
// **Who uses it.** A principal starts it from the console:
// `start("tone")`. Its grant **Sound_Device** gives it the stream ring of
// the sound service, which the root service starts for it; it is the one
// process that plays while it runs, so a second `start("tone")` is
// refused.
//
// **What it does**, in order:
//
// 1. It makes a sample region of REGION_PAGES pages from its own budget,
//    writes 500 ms of a tone of 440 Hz in it, and lends it to the sound
//    service with `Attach`, with the right Read only.
// 2. It lends the region a second time and sends `Attach` again, which
//    the service refuses, and a `Start` with a value, which it refuses.
//    It sends `Start`, and asks for the tone at 500 ms after the frame 0
//    of the stream.
// 3. It sends six records that the service must refuse, and checks the
//    status and the error record of each: over the tone, late, too far,
//    an unknown format, too many frames, and frames past the region.
// 4. It waits for the completion of the tone, and checks that the tone
//    played at the frame of its time. The tool then finds the tone at that
//    frame in the output of the machine.
// 5. It keeps the stream until it is stopped: the device plays silence.
//
// **What a reader sees.** No window: its lines on the log, each case
// ending with "as it must", and the tone on the sound output of the
// machine.
//
// **The stop**: with no stream ring, no sample region, a refused `Attach`
// or `Start`, or a case that does not get its refusal, it writes the
// reason on the log and stops with `Failed`.
package tone

import "modus:contract/errors"
import "modus:contract/ring"
import "modus:contract/timed_stream"
import "modus:support/system"

// The sample region: 500 ms of frames, and the rest of its last page.
TONE_FRAMES :: timed_stream.FRAME_RATE / 2
REGION_PAGES :: (TONE_FRAMES * timed_stream.FRAME_BYTES + system.PAGE_SIZE - 1) / system.PAGE_SIZE
REGION_BYTES :: REGION_PAGES * system.PAGE_SIZE

// What the process needs besides its region: the same as `counters`.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 204, processes = 1, threads = 1}
#assert(MODULE_BUDGET.working_memory_pages == 180 + REGION_PAGES)

TONE_HERTZ :: 440
// The tone plays at this time after the frame 0 of the stream: past the
// latency that the service holds, by far.
TONE_OFFSET_NANOSECONDS :: timed_stream.NANOSECONDS_IN_A_SECOND / 2
// Half of the largest sample: loud, and far from a clip.
TONE_AMPLITUDE :: 16384.0

// The tags of the commands: the tone, then each case.
TAG_ATTACH :: 1
TAG_START :: 2
TAG_TONE :: 3
TAG_SECOND_ATTACH :: 4
TAG_DAMAGED_START :: 5
TAG_FIRST_CASE :: 6

stream: ring.Ring
tone_completion: ring.Record
tone_completed: bool

fail :: proc "contextless" (parts: ..system.Part) -> ! {
	system.log(..parts)
	system.stop(.Failed)
}

// cosine gives the cosine of a small angle by its series: the step of the
// tone, 0.058 radians, needs eight terms for the precision of a double.
// The module has no library of mathematics.
cosine :: proc "contextless" (angle: f64) -> (sum: f64) {
	term := 1.0
	for order in 0 ..< 8 {
		sum += term
		n := f64(2 * order)
		term *= -angle * angle / ((n + 1) * (n + 2))
	}
	return sum
}

// tone_write writes the frames of the tone: the same sample in both
// channels, a cosine, so the first frame is the loudest and not silence.
// The recurrence of two terms gives each next value with one product.
tone_write :: proc "contextless" (region: [^]u32) {
	step := cosine(2 * 3.141592653589793 * TONE_HERTZ / f64(timed_stream.FRAME_RATE))
	before, now := step, 1.0 // The cosine of -step and of 0.
	for index in 0 ..< TONE_FRAMES {
		sample := u32(u16(i16(now * TONE_AMPLITUDE)))
		region[index] = sample | sample << 16
		before, now = now, 2 * step * now - before
	}
}

// receive_tag waits for the completion of a tag. The completion of the tone
// can come first: it is kept. The bound only ends a hang.
receive_tag :: proc "contextless" (tag: u32) -> (record: ring.Record, ok: bool) {
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for {
		wait := system.wait_begin()
		for {
			received := system.receive(&stream.completions) or_break
			if received.tag == tag {
				return received, true
			}
			if received.tag == TAG_TONE {
				tone_completion, tone_completed = received, true
				if tag == TAG_TONE {
					return received, true
				}
				continue
			}
			fail("tone: a completion with the tag ", u64(received.tag), " came, and no command has it")
		}
		if tag == TAG_TONE && tone_completed {
			return tone_completion, true
		}
		if system.time() >= deadline {
			return {}, false
		}
		system.wait_records(&wait, &stream.completions)
		system.wait_end(&wait, deadline)
	}
}

// call sends one command and waits for its completion.
call :: proc "contextless" (command: timed_stream.Command, tag: u32, values: [7]u64 = {}) -> ring.Record {
	if !system.send(&stream.commands, ring.Record{kind = u32(command), tag = tag, values = values}) {
		fail("tone: the stream ring is full")
	}
	record, ok := receive_tag(tag)
	if !ok {
		fail("tone: no completion of ", timed_stream.COMMAND_NAMES[command], " before the hang bound")
	}
	return record
}

// status_of reads the status of a completion through the border of the
// contract. A word that names no status is a refusal that the process
// cannot read: it stops, and never takes the word for a status.
status_of :: proc "contextless" (record: ring.Record) -> timed_stream.Status {
	status, known := timed_stream.status_of_completion_word(record.kind)
	if !known {
		fail("tone: the sound service answered the tag ", u64(record.tag), " with the word ", u64(record.kind), ", which names no status")
	}
	return status
}

// A record that the service must refuse, with what its completion holds.
Refused_Case :: struct {
	name:   string,
	values: [7]u64,
	status: timed_stream.Status,
	kind:   errors.Kind,
	unit:   errors.Unit,
	argument: i64,
}

// case_check sends one command that the service must refuse, and checks
// its status and its error record.
case_check :: proc "contextless" (tag: u32, command: timed_stream.Command, refused: Refused_Case) {
	record := call(command, tag, refused.values)
	error := errors.completion_record(record.values)
	if status_of(record) != refused.status || error.kind != i64(refused.kind) || error.unit != i64(refused.unit) || error.argument != refused.argument || error.operation != i64(command) {
		fail("tone: ", refused.name, " got the status ", u64(record.kind), ", the kind ", error.kind, ", the unit ", error.unit, ", the argument ", error.argument)
	}
	system.log("tone: ", refused.name, " is refused with ", timed_stream_status_name(refused.status), ": as it must")
}

timed_stream_status_name :: proc "contextless" (status: timed_stream.Status) -> string {
	switch status {
	case .Ok:
		return "Ok"
	case .Bad_Command:
		return "Bad_Command"
	case .Out_Of_Range:
		return "Out_Of_Range"
	case .No_Region:
		return "No_Region"
	case .Late:
		return "Late"
	case .Too_Far:
		return "Too_Far"
	case .Overlap:
		return "Overlap"
	case .Not_Started:
		return "Not_Started"
	case .Device_Error:
		return "Device_Error"
	}
	return ""
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	ring_memory := ctx.handles[timed_stream.GRANT_RING]
	status: system.Status
	if stream, status = system.ring_open(ring_memory); status != .Ok {
		fail("tone: no stream ring")
	}
	memory, memory_status := system.memory_create(REGION_PAGES)
	address, map_status := system.memory_map(memory, {.Write})
	if memory_status != .Ok || map_status != .Ok {
		fail("tone: no sample region")
	}
	tone_write(([^]u32)(address))

	// The region goes to the sound service through the stream ring. The
	// sound service maps the ring when it starts: until then, the kernel
	// does not know the other side. The bound only ends a hang.
	given: system.Handle
	give_status := system.Status.Bad_Handle
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; give_status != .Ok && system.time() < deadline; {
		if given, give_status = system.give(ring_memory, memory, {.Read}); give_status != .Ok {
			system.sleep(system.time() + 1)
		}
	}
	if give_status != .Ok {
		fail("tone: the sound service does not map the stream ring")
	}
	if attached := call(.Attach, TAG_ATTACH, {0 = u64(given)}); status_of(attached) != .Ok {
		fail("tone: the sound service refused the sample region with the status ", u64(attached.kind))
	}
	// A second region is refused, and the service closes the handle that
	// it got, as it keeps it not; a damaged Start is refused, and the
	// stream does not start.
	second, second_status := system.give(ring_memory, memory, {.Read})
	if second_status != .Ok {
		fail("tone: the second give of the region gave the status ", second_status)
	}
	case_check(TAG_SECOND_ATTACH, .Attach, {"a second sample region", {0 = u64(second)}, .Bad_Command, .State, .None, 0})
	case_check(TAG_DAMAGED_START, .Start, {"a Start with a value", {0 = 1}, .Bad_Command, .Bad_Value, .None, 1})
	started := call(.Start, TAG_START)
	if status_of(started) != .Ok {
		fail("tone: the sound service refused Start with the status ", u64(started.kind))
	}
	anchor := timed_stream.Anchor{frame = 0, time = started.values[0]}
	if started.values[2] != u64(timed_stream.Format.Signed_16_Stereo_48000) {
		fail("tone: the stream has the format ", started.values[2])
	}
	system.log("tone: the stream started; the service holds ", started.values[1], " ns of frames")

	tone_time := anchor.time + TONE_OFFSET_NANOSECONDS
	format := u64(timed_stream.Format.Signed_16_Stereo_48000)
	if !system.send(&stream.commands, ring.Record{kind = u32(timed_stream.Command.Play), tag = TAG_TONE, values = {0 = tone_time, 1 = format, 2 = TONE_FRAMES, 3 = 0}}) {
		fail("tone: the stream ring is full")
	}

	// The refusals first; the tone is the case that plays.
	cases := [?]Refused_Case {
		{"a record over the tone", {0 = tone_time + TONE_OFFSET_NANOSECONDS / 5, 1 = format, 2 = 1}, .Overlap, .Overlap, .Frames, 1},
		{"a record at the frame 0", {0 = anchor.time, 1 = format, 2 = 1}, .Late, .Too_Small, .Nanoseconds, 1},
		{"a record 20 s ahead", {0 = anchor.time + 20 * timed_stream.NANOSECONDS_IN_A_SECOND, 1 = format, 2 = 1}, .Too_Far, .Over_Limit, .Nanoseconds, 1},
		{"a record of an unknown format", {0 = tone_time + timed_stream.NANOSECONDS_IN_A_SECOND, 1 = u64(max(timed_stream.Format)) + 1, 2 = 1}, .Bad_Command, .Bad_Value, .None, 2},
		{"a record of too many frames", {0 = tone_time + timed_stream.NANOSECONDS_IN_A_SECOND, 1 = format, 2 = timed_stream.FRAME_COUNT_LIMIT + 1}, .Bad_Command, .Too_Long, .Frames, 3},
		{"a record past the end of the region", {0 = tone_time + timed_stream.NANOSECONDS_IN_A_SECOND, 1 = format, 2 = 2, 3 = REGION_BYTES - timed_stream.FRAME_BYTES}, .Out_Of_Range, .Out_Of_Range, .Bytes, 4},
	}
	for refused, index in cases {
		case_check(TAG_FIRST_CASE + u32(index), .Play, refused)
	}

	tone, ok := receive_tag(TAG_TONE)
	if !ok {
		fail("tone: the tone did not end before the hang bound")
	}
	if status_of(tone) != .Ok {
		fail("tone: the sound service refused the tone with the status ", u64(tone.kind))
	}
	played_time, frame, underruns := tone.values[0], tone.values[1], tone.values[2]
	expected_frame, _ := timed_stream.frame_of_time(anchor, tone_time)
	expected_time, _ := timed_stream.time_of_frame(anchor, expected_frame)
	system.log("tone: the tone of 440 Hz played from the frame ", frame, " of the stream for ", u64(TONE_FRAMES), " frames; underruns before its end: ", underruns)
	// A record keeps its frames: an underrun moves its time, never its
	// frame. With no underrun, its time is the time of that frame.
	if frame != expected_frame || (underruns == 0 && played_time != expected_time) {
		fail("tone: the tone played from the frame ", frame, " at ", played_time, " ns; its time names the frame ", expected_frame, " at ", expected_time, " ns")
	}
	system.log("tone: the tone played at the frame of its time: as it must")

	for {
		system.sleep(system.WAIT_FOREVER)
	}
}
