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

@(test)
next_edge_milliseconds_enforces_refusals_zones_and_subsecond_edges :: proc(t: ^testing.T) {
	// Unknown appearance words are refused even when time is unknown.
	for bad_word in ([?]u32{3, 42, max(u32)}) {
		wait_ms, has_edge, ref := next_edge_milliseconds(settings.Appearance(bad_word), 0, 0, false)
		testing.expect_value(t, ref, Appearance_Time_Refusal.Unknown_Appearance_Setting)
		testing.expect(t, !has_edge && wait_ms == 0)
	}

	// Out-of-range zone offsets are refused whenever time is known.
	for bad_zone in ([?]i64{min(i64), MIN_ZONE_OFFSET_SECONDS - 1, MAX_ZONE_OFFSET_SECONDS + 1, max(i64)}) {
		wait_ms, has_edge, ref := next_edge_milliseconds(.Auto, 0, bad_zone, true)
		testing.expect_value(t, ref, Appearance_Time_Refusal.Invalid_Zone_Offset)
		testing.expect(t, !has_edge && wait_ms == 0)
		wait_dark, edge_dark, ref_dark := next_edge_milliseconds(.Dark, 0, bad_zone, true)
		testing.expect_value(t, ref_dark, Appearance_Time_Refusal.Invalid_Zone_Offset)
		testing.expect(t, !edge_dark && wait_dark == 0)
	}

	// Explicit Dark/Light and unknown time never schedule a day-edge wake.
	for setting in ([?]settings.Appearance{.Dark, .Light}) {
		wait_ms, has_edge, ref := next_edge_milliseconds(setting, 7 * 3_600 * 1000, 0, true)
		testing.expect_value(t, ref, Appearance_Time_Refusal.None)
		testing.expect(t, !has_edge && wait_ms == 0)
	}
	wait_unk, edge_unk, ref_unk := next_edge_milliseconds(.Auto, 0, 0, false)
	testing.expect_value(t, ref_unk, Appearance_Time_Refusal.None)
	testing.expect(t, !edge_unk && wait_unk == 0)

	// Sub-second boundaries around 07:00 and 19:00 UTC.
	Edge_Ms_Case :: struct {
		utc_ms:   i64,
		zone_s:   i64,
		expected: u64,
	}
	cases := [?]Edge_Ms_Case {
		{0, 0, 7 * 3_600 * 1000},
		{1, 0, 7 * 3_600 * 1000 - 1},
		{-1, 0, 7 * 3_600 * 1000 + 1},
		{(6 * 3_600 + 59 * 60 + 59) * 1000 + 999, 0, 1},
		{7 * 3_600 * 1000, 0, 12 * 3_600 * 1000},
		{7 * 3_600 * 1000 + 500, 0, 12 * 3_600 * 1000 - 500},
		{(18 * 3_600 + 59 * 60 + 59) * 1000 + 999, 0, 1},
		{19 * 3_600 * 1000, 0, 12 * 3_600 * 1000},
		// +08:00 at 01:00 UTC is 09:00 local -> 10 hours to 19:00 local.
		{1 * 3_600 * 1000, 8 * 3_600, 10 * 3_600 * 1000},
		// Extreme valid zone offsets (-12:00 and +14:00) at 00:00 UTC.
		{0, MIN_ZONE_OFFSET_SECONDS, 7 * 3_600 * 1000},
		{0, MAX_ZONE_OFFSET_SECONDS, 5 * 3_600 * 1000},
	}
	for c in cases {
		wait_ms, has_edge, ref := next_edge_milliseconds(.Auto, c.utc_ms, c.zone_s, true)
		testing.expect_value(t, ref, Appearance_Time_Refusal.None)
		testing.expect(t, has_edge)
		testing.expect_value(t, wait_ms, c.expected)
	}

	// Extreme i64 UTC timestamps stay overflow-free and within [1, 12h].
	for extreme_ms in ([?]i64{min(i64), max(i64)}) {
		for extreme_zone in ([?]i64{MIN_ZONE_OFFSET_SECONDS, 0, MAX_ZONE_OFFSET_SECONDS}) {
			wait_ms, has_edge, ref := next_edge_milliseconds(.Auto, extreme_ms, extreme_zone, true)
			testing.expect_value(t, ref, Appearance_Time_Refusal.None)
			testing.expect(t, has_edge)
			testing.expect(t, wait_ms >= 1 && wait_ms <= 12 * 3_600 * 1000)
		}
	}
}
