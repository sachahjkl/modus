#+build !freestanding
#+build !modus
package graphics

import "core:testing"

// Each threshold at its edges: one under it, at it, one past it; then 0,
// 100 %, one past 100 % and the largest share. A share at a threshold is in
// the higher step.
@(test)
intensity_steps_at_their_edges :: proc(t: ^testing.T) {
	Case :: struct {
		percent:  u64,
		expected: Intensity,
	}
	cases := [?]Case {
		{0, .Normal},
		{1, .Normal},
		{INTENSITY_HIGH_PERCENT - 1, .Normal},
		{INTENSITY_HIGH_PERCENT, .High},
		{INTENSITY_HIGH_PERCENT + 1, .High},
		{INTENSITY_VERY_HIGH_PERCENT - 1, .High},
		{INTENSITY_VERY_HIGH_PERCENT, .Very_High},
		{INTENSITY_VERY_HIGH_PERCENT + 1, .Very_High},
		{100, .Very_High},
		{101, .Very_High},
		{max(u64), .Very_High},
	}
	for test_case in cases {
		testing.expectf(t, intensity_of(test_case.percent) == test_case.expected, "%d %%: the step %v, not %v", test_case.percent, intensity_of(test_case.percent), test_case.expected)
	}
}

// The three steps have three colors in each appearance, each from its
// token: the concept, the warning and a measure near its limit.
@(test)
intensity_colors_are_their_tokens :: proc(t: ^testing.T) {
	for of in Appearance {
		tokens := color_tokens_of(of)
		for concept in ([2]Color{tokens.process, tokens.memory}) {
			normal := intensity_color(.Normal, concept, tokens)
			high := intensity_color(.High, concept, tokens)
			very_high := intensity_color(.Very_High, concept, tokens)
			testing.expect_value(t, normal, concept)
			testing.expect_value(t, high, tokens.warning)
			testing.expect_value(t, very_high, tokens.near_limit)
			testing.expectf(t, normal != high && high != very_high && normal != very_high, "%v appearance: two steps have one color", of)
		}
		// A measure near its limit is not a failure: two colors.
		testing.expect(t, tokens.near_limit != tokens.failed)
	}
}

// A gauge is a graphic on the track, which lies on the background: each
// color of each step keeps 3 to 1 on both, in each appearance.
@(test)
intensity_colors_keep_their_contrast :: proc(t: ^testing.T) {
	for of in Appearance {
		tokens := color_tokens_of(of)
		for concept in ([2]Color{tokens.process, tokens.memory}) {
			for intensity in Intensity {
				color := intensity_color(intensity, concept, tokens)
				expect_contrast(t, of, "a gauge on the track", color, tokens.track, GRAPHIC_CONTRAST_LEAST)
				expect_contrast(t, of, "a gauge on the background", color, tokens.background, GRAPHIC_CONTRAST_LEAST)
			}
		}
	}
}
