#+build !freestanding
package graphics

import "core:testing"

// The contrast rules of docs/DESIGN.md hold in each appearance
// (src/md/features/appearance.md, "The contrast rules hold in both
// appearances"): each pair that a rule names, computed from the one table
// of the tokens.
@(test)
the_rules_keep_their_contrast_in_each_appearance :: proc(t: ^testing.T) {
	for of in Appearance {
		tokens := color_tokens_of(of)
		surfaces := [?]Color{tokens.background, tokens.card_top, tokens.card_bottom}
		// The text and the dim text: on each surface. A caption is the dim
		// text at TEXT_CAPTION, a size under the large text, so the bound of
		// a text holds for it on each surface of a card. On the track (the
		// label of a button, a band) the text; the dim text is there only
		// as a large text, the placeholder of an input at scale 2.
		for surface in surfaces {
			expect_contrast(t, of, "the text", tokens.text, surface, TEXT_CONTRAST_LEAST)
			expect_contrast(t, of, "the dim text", tokens.dim, surface, TEXT_CONTRAST_LEAST)
		}
		expect_contrast(t, of, "the text on the track", tokens.text, tokens.track, TEXT_CONTRAST_LEAST)
		expect_contrast(t, of, "the strong text on the track", tokens.text_strong, tokens.track, TEXT_CONTRAST_LEAST)
		expect_contrast(t, of, "the dim placeholder on the track", tokens.dim, tokens.track, LARGE_TEXT_CONTRAST_LEAST)
		// A measure of a concept is a text in the color of that concept.
		concepts := [?]struct {
			name:  string,
			color: Color,
		} {
			{"the firmware", tokens.firmware},
			{"the boot program", tokens.boot_program},
			{"the kernel", tokens.kernel},
			{"a process", tokens.process},
			{"memory", tokens.memory},
			{"the machine", tokens.machine},
			{"a module with no entry", tokens.no_entry},
			{"a resource", tokens.resource},
			{"a failure", tokens.failed},
			{"a warning", tokens.warning},
			{"a link", tokens.link},
		}
		for concept in concepts {
			for surface in surfaces {
				expect_contrast(t, of, concept.name, concept.color, surface, TEXT_CONTRAST_LEAST)
			}
		}
		// The link with the focus is on a band of the track.
		expect_contrast(t, of, "a link on the track", tokens.link, tokens.track, TEXT_CONTRAST_LEAST)
		// A member of a series is a text (a name in the log, "thread 1")
		// on each surface, and a graphic on the track (the part of the work
		// of a node of `rings` that is done).
		for color in tokens.series {
			for surface in surfaces {
				expect_contrast(t, of, "a series color", color, surface, TEXT_CONTRAST_LEAST)
			}
			expect_contrast(t, of, "a series color on the track", color, tokens.track, GRAPHIC_CONTRAST_LEAST)
		}
		// White on the fills of the blue and of the red.
		expect_contrast(t, of, "white on the chosen row", COLOR_WHITE, tokens.chosen, TEXT_CONTRAST_LEAST)
		expect_contrast(t, of, "white on the close button", COLOR_WHITE, tokens.stop_process, TEXT_CONTRAST_LEAST)
		// The x of the close button of a window that is not in front is a
		// graphic on its quiet red.
		expect_contrast(t, of, "the x of a quiet close button", tokens.stop_process_quiet_mark, tokens.stop_process_quiet, GRAPHIC_CONTRAST_LEAST)
		// A chosen character of a grid is the chosen blue on white.
		expect_contrast(t, of, "the chosen blue on white", tokens.chosen, COLOR_WHITE, TEXT_CONTRAST_LEAST)
		// Each class of code on a card: the console and the terminal.
		for class in Code_Class {
			if class == .None {
				continue
			}
			for surface in surfaces {
				expect_contrast(t, of, "a class of code", code_class_color(class, of), surface, TEXT_CONTRAST_LEAST)
			}
		}
	}
}

// The text of the light appearance is the ink that the dark appearance has
// as its background: the two are one color of the rules, and the text on a
// fill of white has it in both.
@(test)
the_ink_is_the_dark_background_and_the_light_text :: proc(t: ^testing.T) {
	testing.expect_value(t, color_tokens_of(.Dark).background, Color(COLOR_INK))
	testing.expect_value(t, color_tokens_of(.Light).text, Color(COLOR_INK))
}

// appearance_use changes the tokens that each draw reads, and the dark
// appearance is the one of a process that has no settings page.
@(test)
appearance_use_changes_the_tokens :: proc(t: ^testing.T) {
	testing.expect_value(t, appearance, Appearance.Dark)
	testing.expect_value(t, colors.background, Color(DARK_BACKGROUND))
	appearance_use(.Light)
	testing.expect_value(t, appearance, Appearance.Light)
	testing.expect_value(t, colors, color_tokens_of(.Light))
	appearance_use(.Dark)
	testing.expect_value(t, colors, color_tokens_of(.Dark))
}

// Each surface and the text change between the two appearances; the blues
// and the reds of the desktop do not: white keeps its contrast on them.
@(test)
the_two_appearances_differ_where_they_must :: proc(t: ^testing.T) {
	dark, light := color_tokens_of(.Dark), color_tokens_of(.Light)
	testing.expect(t, dark.background != light.background)
	testing.expect(t, dark.card_top != light.card_top)
	testing.expect(t, dark.track != light.track)
	testing.expect(t, dark.text != light.text)
	testing.expect(t, dark.dim != light.dim)
	testing.expect_value(t, light.title, dark.title)
	testing.expect_value(t, light.chosen, dark.chosen)
	testing.expect_value(t, light.stop_process, dark.stop_process)
	// The light value of a concept is its accent at the shade of its value
	// kind on the light page of the site.
	testing.expect_value(t, light.firmware, shade(DARK_FIRMWARE, 83))
	testing.expect_value(t, light.boot_program, shade(DARK_BOOT_PROGRAM, 65))
	testing.expect_value(t, light.kernel, shade(DARK_KERNEL, 73))
	testing.expect_value(t, light.process, shade(DARK_PROCESS, 58))
	testing.expect_value(t, light.memory, shade(DARK_MEMORY, 65))
	testing.expect_value(t, light.machine, shade(DARK_MACHINE, 78))
	testing.expect_value(t, light.no_entry, shade(DARK_NO_ENTRY, 55))
	testing.expect_value(t, light.resource, shade(DARK_RESOURCE, 60))
	testing.expect_value(t, light.failed, shade(DARK_FAILED, 78))
	// The tokens that the processes share: the same rule, the shade that
	// keeps 4.5 to 1 on the light surfaces.
	testing.expect_value(t, light.warning, shade(DARK_WARNING, 57))
	testing.expect_value(t, light.link, shade(DARK_LINK, 55))
	dark_series := DARK_SERIES
	series_light_percents := [SERIES_COLOR_COUNT]u32{76, 64, 56, 75, 79, 57, 54, 63}
	for number in 0 ..< SERIES_COLOR_COUNT {
		testing.expect_value(t, dark.series[number], dark_series[number])
		testing.expect_value(t, light.series[number], shade(dark_series[number], series_light_percents[number]))
	}
	// The surfaces of the light form of the site, from their rule.
	testing.expect_value(t, light.card_bottom, mix(COLOR_WHITE, light.background, 50 * 255 / 100))
	testing.expect_value(t, light.track, mix(light.background, DARK_DIM, 25 * 255 / 100))
	testing.expect_value(t, light.dim, shade(DARK_DIM, 60))
}
