#+build !freestanding
package appearance_rule

import "core:testing"
import "modus:contract/settings"

@(test)
appearance_for_time_enforces_exact_day_edges_overrides_and_refusals :: proc(t: ^testing.T) {
	// Invalid setting words are refused.
	for bad_word in ([?]u32{3, 99, max(u32)}) {
		in_force, ref := appearance_for_time(settings.Appearance(bad_word), 12, 0, 0, true)
		testing.expect_value(t, ref, Appearance_Time_Refusal.Unknown_Appearance_Setting)
		testing.expect_value(t, in_force, settings.Appearance_In_Force.Dark)
	}

	// Invalid hours, minutes, and seconds are refused whenever time_known is true.
	for bad_hour in ([?]i32{min(i32), -1, 24, 25, max(i32)}) {
		_, ref := appearance_for_time(.Auto, bad_hour, 0, 0, true)
		testing.expect_value(t, ref, Appearance_Time_Refusal.Invalid_Hour)
		_, ref_dark := appearance_for_time(.Dark, bad_hour, 0, 0, true)
		testing.expect_value(t, ref_dark, Appearance_Time_Refusal.Invalid_Hour)
	}
	for bad_min in ([?]i32{min(i32), -1, 60, max(i32)}) {
		_, ref := appearance_for_time(.Auto, 12, bad_min, 0, true)
		testing.expect_value(t, ref, Appearance_Time_Refusal.Invalid_Minute)
	}
	for bad_sec in ([?]i32{min(i32), -1, 60, max(i32)}) {
		_, ref := appearance_for_time(.Auto, 12, 0, bad_sec, true)
		testing.expect_value(t, ref, Appearance_Time_Refusal.Invalid_Second)
	}

	// Exact Auto transition edges: 06:59:59 -> Dark, 07:00:00 -> Light,
	// 18:59:59 -> Light, 19:00:00 -> Dark.
	Edge_Case :: struct {
		h, m, s:  i32,
		expected: settings.Appearance_In_Force,
	}
	edges := [?]Edge_Case {
		{0, 0, 0, .Dark},
		{6, 59, 59, .Dark},
		{7, 0, 0, .Light},
		{12, 30, 45, .Light},
		{18, 59, 59, .Light},
		{19, 0, 0, .Dark},
		{23, 59, 59, .Dark},
	}
	for c in edges {
		got, ref := appearance_for_time(.Auto, c.h, c.m, c.s, true)
		testing.expect_value(t, ref, Appearance_Time_Refusal.None)
		testing.expect_value(t, got, c.expected)
	}

	// Explicit overrides win at all valid times and when time is unknown.
	got_dark, ref_dark := appearance_for_time(.Dark, 12, 0, 0, true)
	testing.expect_value(t, ref_dark, Appearance_Time_Refusal.None)
	testing.expect_value(t, got_dark, settings.Appearance_In_Force.Dark)

	got_light, ref_light := appearance_for_time(.Light, 2, 0, 0, true)
	testing.expect_value(t, ref_light, Appearance_Time_Refusal.None)
	testing.expect_value(t, got_light, settings.Appearance_In_Force.Light)

	// Unknown time: Auto -> Dark, Dark -> Dark, Light -> Light.
	auto_unk, ref_au := appearance_for_time(.Auto, 0, 0, 0, false)
	testing.expect_value(t, ref_au, Appearance_Time_Refusal.None)
	testing.expect_value(t, auto_unk, settings.Appearance_In_Force.Dark)

	light_unk, ref_lu := appearance_for_time(.Light, 0, 0, 0, false)
	testing.expect_value(t, ref_lu, Appearance_Time_Refusal.None)
	testing.expect_value(t, light_unk, settings.Appearance_In_Force.Light)
}

@(test)
hms_and_next_transition_boundaries :: proc(t: ^testing.T) {
	// Out-of-range seconds of day are refused.
	for bad in ([?]i64{-1, SECONDS_PER_DAY, max(i64)}) {
		_, _, _, ok := hms_of_second_of_day(bad)
		testing.expect(t, !ok)
	}

	h, m, s, ok := hms_of_second_of_day(LIGHT_START_SECOND - 1)
	testing.expect(t, ok && h == 6 && m == 59 && s == 59)

	w1, r1 := next_transition_seconds(6, 59, 59)
	testing.expect_value(t, r1, Appearance_Time_Refusal.None)
	testing.expect_value(t, w1, i64(1))

	w2, r2 := next_transition_seconds(7, 0, 0)
	testing.expect_value(t, r2, Appearance_Time_Refusal.None)
	testing.expect_value(t, w2, i64(12 * 3_600))

	w3, r3 := next_transition_seconds(18, 59, 59)
	testing.expect_value(t, r3, Appearance_Time_Refusal.None)
	testing.expect_value(t, w3, i64(1))

	w4, r4 := next_transition_seconds(19, 0, 0)
	testing.expect_value(t, r4, Appearance_Time_Refusal.None)
	testing.expect_value(t, w4, i64(12 * 3_600))

	w5, r5 := next_transition_seconds(23, 59, 59)
	testing.expect_value(t, r5, Appearance_Time_Refusal.None)
	testing.expect_value(t, w5, i64(7 * 3_600 + 1))
}
