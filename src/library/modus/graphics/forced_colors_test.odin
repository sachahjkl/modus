#+build !freestanding
package graphics

import "core:math"
import "core:testing"

// color_contrast_mode_of_word accepts every defined mode and refuses unknown words.
@(test)
color_contrast_mode_border_refuses_unknown_words :: proc(t: ^testing.T) {
	for word in u64(0) ..= 16 {
		mode, ok := color_contrast_mode_of_word(word)
		if word <= u64(max(Color_Contrast_Mode)) {
			testing.expectf(t, ok && u64(mode) == word, "valid contrast mode %d refused", word)
		} else {
			testing.expectf(t, !ok, "unknown contrast mode %d accepted as %v", word, mode)
		}
	}
	_, max_ok := color_contrast_mode_of_word(max(u64))
	testing.expect(t, !max_ok, "max(u64) contrast mode must be refused")
}

// Integer contrast_ratio_x100 matches WCAG 2.x exact edges and tracks the
// floating-point reference formula across sample pairs within 0.01 (1 unit).
@(test)
integer_contrast_ratio_matches_wcag_reference :: proc(t: ^testing.T) {
	testing.expect_value(t, relative_luminance_ppm(COLOR_BLACK), u32(0))
	testing.expect_value(t, relative_luminance_ppm(COLOR_WHITE), u32(1_000_000))
	testing.expect_value(t, contrast_ratio_x100(COLOR_WHITE, COLOR_BLACK), u32(2100))
	testing.expect_value(t, contrast_ratio_x100(COLOR_BLACK, COLOR_WHITE), u32(2100))
	testing.expect_value(t, contrast_ratio_x100(DARK_TITLE, DARK_TITLE), u32(100))

	samples := [?]Color{
		COLOR_BLACK, COLOR_WHITE, DARK_BACKGROUND, DARK_TEXT, DARK_LINK,
		LIGHT_COLOR_TOKENS.background, LIGHT_COLOR_TOKENS.text, DARK_STOP_PROCESS,
		FORCED_HIGH_CONTRAST_DARK_COLORS.link, FORCED_HIGH_CONTRAST_LIGHT_COLORS.link,
	}
	for a in samples {
		for b in samples {
			int_ratio := contrast_ratio_x100(a, b)
			ref_ratio := value_contrast_ratio(a, b) * 100.0
			diff := math.abs(f64(int_ratio) - ref_ratio)
			testing.expectf(t, diff <= 1.0, "integer contrast %d diverged from reference %.2f for %06x/%06x", int_ratio, ref_ratio, u32(a), u32(b))
		}
	}
}

// Forced_High_Contrast_Dark and Forced_High_Contrast_Light guarantee WCAG AAA
// (>= 7.0:1, contrast_ratio_x100 >= 700) on every foreground/surface pair,
// keep surfaces flat (no decorative gradients or dot grid), and override
// base_dark_mode explicitly while Standard follows base_dark_mode.
@(test)
forced_high_contrast_palettes_guarantee_wcag_aaa :: proc(t: ^testing.T) {
	// Standard mode follows base_dark_mode.
	testing.expect_value(t, colors_for_contrast_mode(.Standard, true), DARK_COLOR_TOKENS)
	testing.expect_value(t, colors_for_contrast_mode(.Standard, false), LIGHT_COLOR_TOKENS)

	// Forced modes override base_dark_mode deterministically.
	testing.expect_value(t, colors_for_contrast_mode(.Forced_High_Contrast_Dark, false), FORCED_HIGH_CONTRAST_DARK_COLORS)
	testing.expect_value(t, colors_for_contrast_mode(.Forced_High_Contrast_Dark, true), FORCED_HIGH_CONTRAST_DARK_COLORS)
	testing.expect_value(t, colors_for_contrast_mode(.Forced_High_Contrast_Light, true), FORCED_HIGH_CONTRAST_LIGHT_COLORS)
	testing.expect_value(t, colors_for_contrast_mode(.Forced_High_Contrast_Light, false), FORCED_HIGH_CONTRAST_LIGHT_COLORS)

	forced_modes := [2]Color_Contrast_Mode{.Forced_High_Contrast_Dark, .Forced_High_Contrast_Light}
	for mode in forced_modes {
		palette := colors_for_contrast_mode(mode, true)
		// Decorative dot grid and card/title gradients are flattened in high contrast.
		testing.expect_value(t, palette.point, palette.background)
		testing.expect_value(t, palette.card_top, palette.card_bottom)
		testing.expect_value(t, palette.title, palette.title_end)
		testing.expect_value(t, palette.title_quiet, palette.title_quiet_end)

		surfaces := [?]Color{palette.background, palette.card_top, palette.card_bottom, palette.track}
		foregrounds := [?]struct {
			name:  string,
			color: Color,
		} {
			{"text", palette.text},
			{"dim", palette.dim},
			{"text_strong", palette.text_strong},
			{"firmware", palette.firmware},
			{"boot_program", palette.boot_program},
			{"kernel", palette.kernel},
			{"process", palette.process},
			{"memory", palette.memory},
			{"machine", palette.machine},
			{"no_entry", palette.no_entry},
			{"resource", palette.resource},
			{"failed", palette.failed},
			{"not_usable", palette.not_usable},
			{"warning", palette.warning},
			{"near_limit", palette.near_limit},
			{"link", palette.link},
		}

		for fg in foregrounds {
			for surface in surfaces {
				ratio := contrast_ratio_x100(fg.color, surface)
				testing.expectf(
					t,
					ratio >= WCAG_AAA_CONTRAST_RATIO_X100,
					"%v: %s (%06x on %06x) has contrast %d/100; required >= %d/100",
					mode, fg.name, u32(fg.color), u32(surface), ratio, WCAG_AAA_CONTRAST_RATIO_X100,
				)
			}
		}

		for series_color, idx in palette.series {
			for surface in surfaces {
				ratio := contrast_ratio_x100(series_color, surface)
				testing.expectf(
					t,
					ratio >= WCAG_AAA_CONTRAST_RATIO_X100,
					"%v: series[%d] (%06x on %06x) has contrast %d/100; required >= %d/100",
					mode, idx, u32(series_color), u32(surface), ratio, WCAG_AAA_CONTRAST_RATIO_X100,
				)
			}
		}

		// White text/icons on interactive fills and quiet close mark.
		testing.expect(t, contrast_ratio_x100(COLOR_WHITE, palette.chosen) >= WCAG_AAA_CONTRAST_RATIO_X100, "white on chosen must be >= 7.0:1")
		testing.expect(t, contrast_ratio_x100(COLOR_WHITE, palette.title) >= WCAG_AAA_CONTRAST_RATIO_X100, "white on title must be >= 7.0:1")
		testing.expect(t, contrast_ratio_x100(COLOR_WHITE, palette.stop_process) >= WCAG_AAA_CONTRAST_RATIO_X100, "white on stop_process must be >= 7.0:1")
		testing.expect(t, contrast_ratio_x100(COLOR_WHITE, palette.stop_process_pointer_over) >= WCAG_AAA_CONTRAST_RATIO_X100, "white on stop_process_pointer_over must be >= 7.0:1")
		testing.expect(t, contrast_ratio_x100(palette.stop_process_quiet_mark, palette.stop_process_quiet) >= WCAG_AAA_CONTRAST_RATIO_X100, "quiet close mark must be >= 7.0:1")
		testing.expect(t, contrast_ratio_x100(palette.text, palette.title_quiet) >= WCAG_AAA_CONTRAST_RATIO_X100, "text on quiet title bar must be >= 7.0:1")
	}
}
