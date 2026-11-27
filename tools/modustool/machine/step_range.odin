package machine

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"

// A step range of a test part (src/md/infrastructure/scenario_fault_loop.md,
// "A step range"): `test <part> steps <first> to <last> [of <machine>]
// [with <first> to <last>]...` boots the machine, runs its boot steps, the
// setup steps that `with` names, and the steps of the range, then ends the
// part. The numbers are the numbers of the steps that a failed step prints.

TEST_STEPS_WORD :: "steps"
TEST_TO_WORD :: "to"
TEST_OF_WORD :: "of"
TEST_WITH_WORD :: "with"

// The steps from first to last, both in, numbered from 1.
Step_Span :: struct {
	first, last: int,
}

// A step range, and what its run found. The part that it names keeps it
// in its run record.
Step_Range :: struct {
	given:   bool,
	machine: string, // The name of the log of the machine, "test_output_tpm_key_4"; "": the first machine of the part.
	span:    Step_Span,
	setup:   []Step_Span,
	ran:     bool, // The named machine ran its range: the part ends.
	passed:  bool,
}

// step_range_parse reads the words after `test <part> steps`. problem
// names the first word that it refuses.
step_range_parse :: proc(words: []string, allocator := context.allocator) -> (range: Step_Range, problem: string) {
	span_read :: proc(words: []string, place: int) -> (span: Step_Span, problem: string) {
		if place + 3 > len(words) || words[place + 1] != TEST_TO_WORD {
			return {}, fmt.tprintf("a range is `<first> %s <last>`", TEST_TO_WORD)
		}
		first, first_ok := strconv.parse_int(words[place], 10)
		last, last_ok := strconv.parse_int(words[place + 2], 10)
		switch {
		case !first_ok || !last_ok:
			return {}, fmt.tprintf("`%s %s %s` is no range of steps: a step is a whole number", words[place], TEST_TO_WORD, words[place + 2])
		case first < 1:
			return {}, fmt.tprintf("the range %d %s %d names the step %d, and the first step is 1", first, TEST_TO_WORD, last, first)
		case first > last:
			return {}, fmt.tprintf("the range %d %s %d ends before it starts", first, TEST_TO_WORD, last)
		}
		return {first, last}, ""
	}
	range.given = true
	span, span_problem := span_read(words, 0)
	if span_problem != "" {
		return {}, span_problem
	}
	range.span = span
	setup := make([dynamic]Step_Span, allocator)
	place := 3
	for place < len(words) {
		switch words[place] {
		case TEST_OF_WORD:
			if place + 1 >= len(words) || words[place + 1] == "" || range.machine != "" {
				return {}, fmt.tprintf("`%s` names one machine of the part, by the name of its log", TEST_OF_WORD)
			}
			range.machine = strings.clone(words[place + 1], allocator)
			place += 2
		case TEST_WITH_WORD:
			setup_span, setup_problem := span_read(words, place + 1)
			if setup_problem != "" {
				return {}, setup_problem
			}
			if setup_span.last >= range.span.first {
				return {}, fmt.tprintf("the setup %d %s %d is not before the first step of the range, %d", setup_span.first, TEST_TO_WORD, setup_span.last, range.span.first)
			}
			append(&setup, setup_span)
			place += 4
		case:
			return {}, fmt.tprintf("`%s` after a range: the words that follow it are `%s <machine>` and `%s <first> %s <last>`", words[place], TEST_OF_WORD, TEST_WITH_WORD, TEST_TO_WORD)
		}
	}
	range.setup = setup[:]
	return range, ""
}

// step_reads_the_log_only says if a step only reads the log: the boot
// steps of a range are the steps before the first one that does not.
step_reads_the_log_only :: proc(kind: Step_Kind) -> bool {
	switch kind {
	case .Wait, .Date, .Appearance_Auto, .Bar_Local_Time, .Screen_Size, .Generation, .Remember, .Trace, .Fact, .Quic_Key, .Remote_Key, .Remote_Display_Key:
		return true
	case .Type, .Keys, .Key, .Key_Down, .Key_Up, .Key_Until, .Key_Again_Until, .Assistant_Turn, .Click, .Click_Absolute, .Press_Absolute, .Move_Absolute, .Release_Absolute, .Launch, .Drag, .Shot, .Move, .Resize, .Front, .Close, .Click_Element, .Wheel, .Film_Start, .Film_Stop, .Film_Type, .Film_Hold, .Quit, .Monitor, .Record, .Agree, .Power_Loss_Arm, .Power_Loss, .Disk_Disconnect, .Call, .Peer, .Point, .Distinct, .Peer_Start, .Peer_Result, .Peer_Mark, .Fetch, .Http, .Peer_Quic, .Openssl_Quic, .Remote_Case, .Viewer_Relay, .Remote_Display_Case, .Screen_Text, .Operation_Sequences, .Ask_Wide_Grant, .Export_Replay_History, .Release_Cache_Hold:
		// A step that acts on the machine, on the peer or on the host, or
		// that calls the machine.
	}
	return false
}

// step_calls_remote says if a step calls `remote` with the key of the
// client: the kinds that remote_key_problem checks.
step_calls_remote :: proc(kind: Step_Kind) -> bool {
	return kind == .Call || kind == .Record || kind == .Agree || kind == .Remote_Case || kind == .Point || kind == .Assistant_Turn || kind == .Ask_Wide_Grant
}

// Which part of a selection a step is.
Step_Range_Phase :: enum u8 {
	Boot,
	Setup,
	Range,
}

// A selection of the steps of a scenario: the places of the steps in the
// order of the run, and the count of the boot steps and of the setup steps
// before the range.
Step_Selection :: struct {
	places: []int,
	boot:   int,
	setup:  int,
}

// step_range_select gives the steps of a scenario that a range runs: the
// boot steps, the setup steps, then the range, each once and in order.
// problem: the range ends past the steps of the scenario.
step_range_select :: proc(steps: []Step, range: Step_Range) -> (selection: Step_Selection, problem: string) {
	if range.span.last > len(steps) {
		return {}, fmt.tprintf("the range %d %s %d ends past the %d steps of the machine", range.span.first, TEST_TO_WORD, range.span.last, len(steps))
	}
	for span in range.setup {
		if span.last > len(steps) {
			return {}, fmt.tprintf("the setup %d %s %d ends past the %d steps of the machine", span.first, TEST_TO_WORD, span.last, len(steps))
		}
	}
	chosen := make([]Step_Range_Phase, len(steps), context.temp_allocator)
	taken := make([]bool, len(steps), context.temp_allocator)
	boot_end := 0
	for boot_end < len(steps) && boot_end < range.span.first - 1 && step_reads_the_log_only(steps[boot_end].kind) {
		taken[boot_end] = true
		chosen[boot_end] = .Boot
		boot_end += 1
	}
	for span in range.setup {
		for place in span.first - 1 ..< span.last {
			if !taken[place] {
				taken[place] = true
				chosen[place] = .Setup
			}
		}
	}
	for place in range.span.first - 1 ..< range.span.last {
		taken[place] = true
		chosen[place] = .Range
	}
	places := make([dynamic]int, context.temp_allocator)
	for place in 0 ..< len(steps) {
		if !taken[place] {
			continue
		}
		append(&places, place)
		switch chosen[place] {
		case .Boot:
			selection.boot += 1
		case .Setup:
			selection.setup += 1
		case .Range:
		}
	}
	selection.places = places[:]
	return selection, ""
}

// The marks of a step and the kind of the step that gives each.
@(private = "file")
Step_Mark_Giver :: struct {
	mark: string,
	kind: Step_Kind,
}

@(private = "file")
STEP_MARK_GIVERS := [?]Step_Mark_Giver{{RECORD_MARK, .Record}, {"{generation", .Generation}, {SCREEN_TEXT_MARK, .Screen_Text}, {SCREEN_TEXT_BEFORE_MARK, .Screen_Text}}

// step_range_setup_problem refuses a selection whose step names a value
// that no step before it in the selection gives: a mark, or the key of
// `remote` for a call. It names the last step before it in the scenario
// that gives the value, for the next `with`.
step_range_setup_problem :: proc(steps: []Step, selection: Step_Selection) -> string {
	for place, position in selection.places {
		step := steps[place]
		for giver in STEP_MARK_GIVERS {
			if !strings.contains(step.text, giver.mark) && !strings.contains(step.expected, giver.mark) {
				continue
			}
			given := false
			for earlier in selection.places[:position] {
				given ||= steps[earlier].kind == giver.kind
			}
			if !given {
				return fmt.tprintf("the step %d names %s, and no step of the selection before it is a step %v; %s", place + 1, giver.mark, giver.kind, step_last_before(steps, place, giver.kind))
			}
		}
	}
	// The rule of remote_key_problem, over the selection: a call of remote
	// needs a step Remote_Key since the last start of remote.
	key_read := false
	for place in selection.places {
		step := steps[place]
		if remote_starts_or_ends(step) {
			key_read = false
			continue
		}
		if step.kind == .Remote_Key {
			key_read = true
		} else if step_calls_remote(step.kind) && !key_read {
			return fmt.tprintf("the step %d (%v %s) calls remote, and no step Remote_Key of the selection comes before it since the last start of remote; %s", place + 1, step.kind, step.text, step_last_before(steps, place, .Remote_Key))
		}
	}
	return ""
}

// step_last_before names the last step of a kind before a place of a
// scenario, as the setup that a range lacks.
@(private = "file")
step_last_before :: proc(steps: []Step, place: int, kind: Step_Kind) -> string {
	for earlier := min(place, len(steps)) - 1; earlier >= 0; earlier -= 1 {
		if steps[earlier].kind == kind {
			return fmt.tprintf("the last step %v before it is the step %d: add `%s %d %s %d`, with the steps that it needs", kind, earlier + 1, TEST_WITH_WORD, earlier + 1, TEST_TO_WORD, earlier + 1)
		}
	}
	return fmt.tprintf("no step %v comes before it", kind)
}

// step_range_phase_note notes the start of the boot steps, of the setup
// steps and of the range, at the step at a position of the selection.
step_range_phase_note :: proc(machine: ^Machine, position: int) {
	selection := machine.range_selection
	now := time.tick_now()
	// A phase starts at the first step after the phase before it: a phase
	// with no step lasts no time.
	if position == 0 {
		machine.range_phase_started[.Boot] = now
	}
	if position <= selection.boot {
		machine.range_phase_started[.Setup] = now
	}
	if position <= selection.boot + selection.setup {
		machine.range_phase_started[.Range] = now
	}
}

// step_range_times_print prints the time of the boot steps, of the setup
// steps and of the range: measures, never a condition.
step_range_times_print :: proc(machine: ^Machine, ended: time.Tick, passed: bool) {
	started := machine.range_phase_started
	boot := time.tick_diff(machine.started_at, started[.Setup])
	setup := time.tick_diff(started[.Setup], started[.Range])
	range := time.tick_diff(started[.Range], ended)
	in_range := len(machine.range_places) - machine.range_selection.boot - machine.range_selection.setup
	fmt.printfln("modustool: measure: the step range of %s %s: the start of QEMU and %d boot steps %.1f s, %d setup steps %.1f s, %d steps of the range %.1f s", machine_name_of_log(machine.output), passed ? "passed" : "failed", machine.range_selection.boot, time.duration_seconds(boot), machine.range_selection.setup, time.duration_seconds(setup), in_range, time.duration_seconds(range))
}

// step_place gives the place in its scenario of the step at a position of
// a selection: the position itself when the run has no range.
step_place :: proc(places: []int, position: int) -> int {
	return places == nil ? position : places[position]
}

// machine_name_of_log gives the name of a machine for `of`: the name of
// its log file, with no folder and no ".txt".
machine_name_of_log :: proc(output: string) -> string {
	name := output[strings.last_index_byte(output, '/') + 1:]
	return strings.trim_suffix(name, ".txt")
}
