#+build !freestanding
#+build !modus
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
			{"a measure near its limit", tokens.near_limit},
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

// darker_than says if the first color has less luminance than the second.
@(private = "file")
darker_than :: proc(first, second: Color) -> bool {
	return relative_luminance_ppm(first) < relative_luminance_ppm(second)
}

// The surfaces that lie over the desktop (a menu, a dialog) take their
// shadow, their edge and their recess from the tokens. In the light
// appearance none of them is a near black box around a light card: the
// shadow stays near the background, the edge keeps 3 to 1 as a graphic, and
// the recess keeps the text readable. In the dark appearance each keeps the
// shade that the desktop drew before it was a token.
@(test)
the_surfaces_over_the_desktop_follow_the_appearance :: proc(t: ^testing.T) {
	dark, light := color_tokens_of(.Dark), color_tokens_of(.Light)
	testing.expect_value(t, dark.shadow, shade(DARK_BACKGROUND, 55))
	testing.expect_value(t, dark.edge, shade(DARK_BACKGROUND, 50))
	testing.expect_value(t, dark.recess, shade(DARK_CARD_BOTTOM, 80))
	for of in Appearance {
		tokens := color_tokens_of(of)
		// A shadow and an edge are darker than the surfaces that they frame.
		for surface in ([?]Color{tokens.card_top, tokens.card_bottom}) {
			testing.expectf(t, darker_than(tokens.shadow, surface), "%v appearance: the shadow %06x is not darker than the card %06x", of, u32(tokens.shadow), u32(surface))
			testing.expectf(t, darker_than(tokens.edge, surface), "%v appearance: the edge %06x is not darker than the card %06x", of, u32(tokens.edge), u32(surface))
		}
		// Text on the recess, as on a card.
		expect_contrast(t, of, "the text on the recess", tokens.text, tokens.recess, TEXT_CONTRAST_LEAST)
		expect_contrast(t, of, "the strong text on the recess", tokens.text_strong, tokens.recess, TEXT_CONTRAST_LEAST)
		// The strong text is the title of a card over the desktop: a
		// notification, the preview of a plate, the asker of the powerbox.
		for surface in ([?]Color{tokens.card_top, tokens.card_bottom, tokens.track}) {
			expect_contrast(t, of, "the strong text on a card", tokens.text_strong, surface, TEXT_CONTRAST_LEAST)
		}
	}
	// The light edge is a graphic on the background and on a card.
	for surface in ([?]Color{light.background, light.card_top, light.card_bottom}) {
		expect_contrast(t, .Light, "the edge", light.edge, surface, GRAPHIC_CONTRAST_LEAST)
	}
	// The light shadow is a depth, not a black box: lighter than the edge,
	// and under 2 to 1 on the background.
	testing.expect(t, darker_than(light.edge, light.shadow))
	testing.expectf(t, value_contrast_ratio(light.shadow, light.background) < 2.0, "the light shadow %06x has %.2f to 1 on the background: a box, not a depth", u32(light.shadow), value_contrast_ratio(light.shadow, light.background))
	// White is never the text of a card of the light appearance: it has
	// no contrast on its white.
	testing.expect(t, value_contrast_ratio(COLOR_WHITE, light.card_top) < LARGE_TEXT_CONTRAST_LEAST)
}

// The border of a card is darker at the bottom in both appearances, and
// in the light appearance it is a tint of the accent, never the near black
// of the dark rule (the dark rule on a white card is a black frame).
@(test)
the_border_of_a_card_follows_the_appearance :: proc(t: ^testing.T) {
	light := color_tokens_of(.Light)
	accents := [?]Color{DARK_KERNEL, DARK_PROCESS, DARK_FAILED, light.kernel, light.warning, COLOR_BLACK, COLOR_WHITE}
	for accent in accents {
		dark_top, dark_bottom := card_border_colors(accent, .Dark)
		testing.expect_value(t, dark_top, shade(accent, 28))
		testing.expect_value(t, dark_bottom, shade(accent, 14))
		light_top, light_bottom := card_border_colors(accent, .Light)
		testing.expect_value(t, light_top, mix(COLOR_WHITE, accent, 40 * 255 / 100))
		testing.expect_value(t, light_bottom, mix(COLOR_WHITE, accent, 55 * 255 / 100))
		// The edges of the range: black and white give no darker bottom.
		if accent != COLOR_WHITE && accent != COLOR_BLACK {
			testing.expectf(t, darker_than(dark_bottom, dark_top), "the dark border of %06x is not darker at the bottom", u32(accent))
			testing.expectf(t, darker_than(light_bottom, light_top), "the light border of %06x is not darker at the bottom", u32(accent))
		}
	}
	// Each concept that titles a card: its light border is far from the
	// near black of the dark rule.
	for accent in ([?]Color{light.kernel, light.process, light.memory, light.firmware, light.machine, light.failed, light.warning}) {
		top, bottom := card_border_colors(accent, .Light)
		near_black, _ := card_border_colors(accent, .Dark)
		testing.expectf(t, value_contrast_ratio(top, light.card_top) < value_contrast_ratio(near_black, light.card_top), "the light border %06x is as heavy as the dark rule", u32(top))
		testing.expectf(t, value_contrast_ratio(bottom, light.card_top) < 4.5, "the light border %06x of %06x is a dark frame", u32(bottom), u32(accent))
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
	testing.expect_value(t, light.near_limit, shade(DARK_NEAR_LIMIT, 70))
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

// The outline of the focus is the strong text (src/md/features/accessibility.md,
// "3. Keyboard access to everything"). It lies outside the element, so
// before the focus its pixels were the surface around the element: the
// strong text keeps at least 3 to 1 against each such surface (WCAG 2.2,
// success criterion 2.4.13), in each appearance and in each contrast. The
// bar is the gradient of the cards, with the track as its line and a line
// of light under it at the bottom edge; the mark of a mode by keys is the
// strong text on the recess, as a text.
@(test)
the_outline_of_the_focus_keeps_its_contrast :: proc(t: ^testing.T) {
	Token_Set :: struct {
		name:   string,
		tokens: Color_Tokens,
	}
	sets := [?]Token_Set {
		{"dark", color_tokens_of(.Dark)},
		{"light", color_tokens_of(.Light)},
		{"high contrast dark", colors_for_contrast_mode(.Forced_High_Contrast_Dark, true)},
		{"high contrast light", colors_for_contrast_mode(.Forced_High_Contrast_Light, false)},
	}
	for set in sets {
		tokens := set.tokens
		Surface :: struct {
			name:  string,
			color: Color,
		}
		surfaces := [?]Surface {
			{"the background", tokens.background},
			{"the top of a card", tokens.card_top},
			{"the bottom of a card", tokens.card_bottom},
			{"the recess", tokens.recess},
			{"the track", tokens.track},
			{"the top of the bar", tokens.card_top},
			{"the bottom of the bar", tokens.card_bottom},
			{"the line of light of the bar", shade(tokens.card_top, 125)},
		}
		for surface in surfaces {
			ratio := value_contrast_ratio(tokens.text_strong, surface.color)
			testing.expectf(t, ratio >= GRAPHIC_CONTRAST_LEAST, "%s: the outline of the focus (%06x) on %s (%06x): a contrast of %.2f; at least %.1f", set.name, u32(tokens.text_strong), surface.name, u32(surface.color), ratio, GRAPHIC_CONTRAST_LEAST)
			// The integer measure of the system says the same: it is the
			// one that a process can compute at run time.
			testing.expectf(t, contrast_ratio_x100(tokens.text_strong, surface.color) >= 300, "%s: the integer contrast on %s is under 3 to 1", set.name, surface.name)
		}
		ratio := value_contrast_ratio(tokens.text_strong, tokens.recess)
		testing.expectf(t, ratio >= TEXT_CONTRAST_LEAST, "%s: the words of a mode by keys on the recess: a contrast of %.2f", set.name, ratio)
	}
}

// A test that never fails proves nothing: a color one step from a surface
// is refused by the same check.
@(test)
the_contrast_check_of_the_outline_refuses_a_faint_outline :: proc(t: ^testing.T) {
	for of in Appearance {
		tokens := color_tokens_of(of)
		for surface in ([?]Color{tokens.background, tokens.card_top, tokens.card_bottom, tokens.recess}) {
			testing.expect(t, value_contrast_ratio(surface, surface) < GRAPHIC_CONTRAST_LEAST)
			testing.expect(t, contrast_ratio_x100(surface, surface) < 300)
			testing.expect(t, value_contrast_ratio(tokens.edge, surface) < value_contrast_ratio(tokens.text_strong, surface))
		}
	}
}
