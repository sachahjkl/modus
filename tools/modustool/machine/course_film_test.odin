// Host tests for the Modus Practical Course film scenario, teaching cards,
// two-line lower-third captions, timeline splicing, ASS output, and film CLI
// registration.
package machine

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import "modustool:build"

@(test)
course_film_scenario_keys_cues_and_teaching_rules :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// 1. CLI registration: `film course` and `film --fast course` parse cleanly.
	film, found := film_of_name("course")
	testing.expect(t, found, "course film is registered in film_of_name")
	testing.expect_value(t, film.name, "course")
	testing.expect_value(t, film.output, TEST_OUTPUT_FILM_COURSE)

	opts, problem := film_arguments_parse({"--fast", "course"})
	testing.expect_value(t, problem, "")
	testing.expect_value(t, opts.name, "course")
	testing.expect_value(t, opts.optimization, build.Optimization_Mode.None)

	// 2. No raw 64-hex hash walls, no collatz, every typed character is supported,
	//    and no variable assignment is followed immediately by a value wait.
	last_typed_was_assignment := false
	for step, index in scenario_course_film {
		testing.expectf(t, !strings.contains(step.text, "collatz"), "step %d must not reference collatz", index + 1)
		if step.kind == .Type || step.kind == .Film_Type {
			_, unknown := key_names_of_a_text(step.text)
			testing.expectf(t, unknown < 0, "step %d (%v) contains untypeable character at %d: %q", index + 1, step.kind, unknown, step.text)
			testing.expectf(t, !strings.contains(step.text, "blake3:"), "step %d must not type raw hashes on screen: %q", index + 1, step.text)
			if step.kind == .Film_Type {
				eq := strings.index(step.text, " = ")
				paren := strings.index_byte(step.text, '(')
				pipe := strings.index(step.text, "|>")
				last_typed_was_assignment = !strings.has_prefix(step.text, "let ") && eq > 0 && (paren < 0 || eq < paren) && (pipe < 0 || eq < pipe)
			}
		} else if step.kind == .Wait && strings.has_prefix(step.text, "[console] ") && !strings.has_prefix(step.text, "[console] > ") {
			testing.expectf(t, !last_typed_was_assignment, "step %d waits for drawn console output %q directly after a variable assignment", index + 1, step.text)
		}
	}

	// 3. Collect all cues in scenario order and build the spliced timeline.
	scenario_cues := make([dynamic]Film_Cue, context.temp_allocator)
	cue_time := time.Duration(0)
	for step in scenario_course_film {
		if step.kind == .Film_Hold && step.text != "" {
			testing.expect_value(t, film_cue_name_problem(step.text), "")
			append(&scenario_cues, Film_Cue{since_start = cue_time, name = step.text})
			cue_time += 5 * time.Second
		}
	}
	cue_text := film_cue_text(scenario_cues[:])
	parsed_cues, parsed_ok := tutorial_cues_parse(cue_text)
	if !testing.expect(t, parsed_ok, "course scenario cues round-trip cleanly") {
		return
	}
	defer tutorial_cues_free(parsed_cues)
	testing.expect_value(t, len(parsed_cues), len(scenario_cues))

	raw_total_s := int(cue_time / time.Second) + 5
	pic_names := make([]string, raw_total_s, context.temp_allocator)
	pic_times := make([]time.Duration, raw_total_s, context.temp_allocator)
	for i in 0 ..< raw_total_s {
		pic_times[i] = time.Duration(i) * time.Second
		pic_names[i] = fmt.tprintf("%010d.ppm", i * 1_000_000)
	}
	runs := film_runs(pic_times)
	raw_total_us := film_slot_microseconds(film_slot_count(runs))

	timeline, ok := tutorial_timeline_build(pic_names, runs, parsed_cues, course_chapter_cards[:], course_captions[:])
	if !testing.expect(t, ok, "full 5-lesson course timeline builds cleanly") {
		return
	}
	defer tutorial_timeline_free(&timeline)
	testing.expect_value(t, len(timeline.card_spans), len(course_chapter_cards))
	testing.expect_value(t, len(timeline.caption_spans), len(course_captions))

	// Exact duration conservation across spliced cards + live runs.
	expected_cards_us: i64 = 0
	for card in course_chapter_cards {
		testing.expect(t, card.two_panel, "every course card uses the two-panel teaching slide layout")
		testing.expect(t, card.duration_ms >= 5500, "teaching slide stays on screen >= 5.5 s")
		expected_cards_us += card.duration_ms * 1000
	}
	actual_total_us: i64 = 0
	for entry in timeline.entries {
		testing.expect(t, entry.duration_us > 0)
		actual_total_us += entry.duration_us
	}
	testing.expect_value(t, actual_total_us, raw_total_us + expected_cards_us)

	// Strict non-overlap between every card and every caption, and every
	// Before_Cue card opens directly into a matching caption.
	for i in 0 ..< len(timeline.card_spans) {
		a := timeline.card_spans[i]
		testing.expect(t, a.end_ms > a.start_ms)
		if i > 0 {
			testing.expect(t, a.start_ms >= timeline.card_spans[i - 1].end_ms)
		}
		for cap in timeline.caption_spans {
			overlaps := cap.start_ms < a.end_ms && cap.end_ms > a.start_ms
			testing.expectf(t, !overlaps, "course caption %d must not overlap card %d", cap.caption_index, a.card_index)
		}
	}
	for i in 1 ..< len(timeline.caption_spans) {
		testing.expect(t, timeline.caption_spans[i].start_ms >= timeline.caption_spans[i - 1].end_ms)
	}
	for card in course_chapter_cards {
		if card.anchor != .Before_Cue {
			continue
		}
		has_caption := false
		for cap in course_captions {
			if cap.cue_name == card.cue_name {
				has_caption = true
				break
			}
		}
		testing.expectf(t, has_caption, "course card %s cue `%s` has an immediate caption", card.id, card.cue_name)
	}

	// 4. Printable ASCII (plus '\n' in caption bodies) for B612 ASCII font coverage,
	//    and clean ASS output with zero fmt formatting errors.
	is_ascii_line :: proc(s: string) -> bool {
		for b in transmute([]u8)s {
			if b < 0x20 || b > 0x7E {
				return false
			}
		}
		return true
	}
	is_ascii_multiline :: proc(s: string) -> bool {
		for b in transmute([]u8)s {
			if b != '\n' && (b < 0x20 || b > 0x7E) {
				return false
			}
		}
		return true
	}
	// Zero snark or dismissive comparisons on slides or captions.
	has_disallowed_phrase :: proc(s: string) -> bool {
		for bad in ([]string{"Linux", "macOS", "awk", "grep", "regex", "Save button", "ad-hoc text"}) {
			if strings.contains(s, bad) {
				return true
			}
		}
		return false
	}

	for card in course_chapter_cards {
		testing.expectf(t, is_ascii_line(card.kicker) && is_ascii_line(card.title) && is_ascii_line(card.subtitle) && is_ascii_line(card.callout) && is_ascii_line(card.footer), "course card %s header/callout/footer use printable ASCII", card.id)
		testing.expectf(t, !has_disallowed_phrase(card.title) && !has_disallowed_phrase(card.subtitle) && !has_disallowed_phrase(card.callout), "course card %s teaches on modus's own terms", card.id)
		testing.expectf(t, len(card.left_blocks) == 3, "course card %s has 3 left-panel teaching blocks", card.id)
		for block in card.left_blocks {
			testing.expectf(t, is_ascii_line(block.heading) && is_ascii_multiline(block.body), "course card %s block uses printable ASCII: %s", card.id, block.heading)
			testing.expectf(t, !has_disallowed_phrase(block.heading) && !has_disallowed_phrase(block.body), "course card %s block avoids snark: %s", card.id, block.heading)
		}
		testing.expectf(t, len(card.right_lines) >= 8 && len(card.right_lines) <= 14, "course card %s right code panel has 8..14 lines", card.id)
		for line in card.right_lines {
			testing.expectf(t, is_ascii_line(line), "course card %s code line uses printable ASCII: %s", card.id, line)
			testing.expectf(t, len(line) <= 56, "course card %s code line fits right panel (<= 56 chars): %s", card.id, line)
			testing.expectf(t, !has_disallowed_phrase(line), "course card %s code line avoids snark: %s", card.id, line)
		}
		ppm, ppm_ok := tutorial_card_ppm_encode_card(160, 90, card)
		testing.expectf(t, ppm_ok && strings.has_prefix(string(ppm), "P6\n160 90\n255\n"), "course card %s renders valid two-panel PPM", card.id)
		delete(ppm)
	}
	for cap in course_captions {
		testing.expectf(t, is_ascii_line(cap.kicker) && is_ascii_line(cap.heading) && is_ascii_multiline(cap.body), "course caption %s uses printable ASCII", cap.cue_name)
		testing.expectf(t, strings.count(cap.body, "\n") == 1, "course caption %s has a 2-line teaching body", cap.cue_name)
		testing.expectf(t, !has_disallowed_phrase(cap.heading) && !has_disallowed_phrase(cap.body), "course caption %s avoids snark", cap.cue_name)
	}

	ass := tutorial_ass_generate(timeline, course_chapter_cards[:], course_captions[:])
	defer delete(ass)
	testing.expect(t, !strings.contains(ass, "%!("), "course ASS contains zero fmt formatting errors")
	for snippet in ([]string{
		"PlayResX: 1920",
		"PlayResY: 1080",
		"Style: SlideTitle,",
		"Style: SlideCode,JetBrains Mono ASCII,",
		"MODUS PRACTICAL COURSE",
		"docs/COURSE.md",
		"modus.systems",
		"{\\an7\\pos(",
		"\\p1}m 0 0 l ",
		"{\\p0}",
		"\\N",
		tutorial_ass_tag_color(TUTORIAL_SYN_ENUM),
		tutorial_ass_tag_color(TUTORIAL_SYN_STRING),
		tutorial_ass_tag_color(TUTORIAL_SYN_OPERATOR),
		tutorial_ass_tag_color(TUTORIAL_SYN_NUMBER),
		tutorial_ass_tag_color(TUTORIAL_SYN_IDENT),
	}) {
		testing.expectf(t, strings.contains(ass, snippet), "course ASS contains `%s`", snippet)
	}
}
