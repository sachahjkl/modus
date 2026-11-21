// Pure daytime appearance schedule for the settings service
// (src/md/api/root_service_split.md; src/md/features/appearance.md).
//
// Evaluates the appearance in force from the principal's setting and the
// local time of day: Auto selects Light from 07:00:00 inclusive through
// 18:59:59 inclusive, Dark at 19:00:00 through 06:59:59, and Dark when the
// system has no date. Explicit Dark or Light overrides always apply, and
// invalid times or unknown Appearance words are refused.
//
// Allocates no memory and calls no kernel operation.
package appearance_rule

import "modus:contract/enum_word"
import "modus:contract/settings"

SECONDS_PER_DAY :: 86_400
LIGHT_START_SECOND :: 7 * 3_600
DARK_START_SECOND :: 19 * 3_600

#assert(0 < LIGHT_START_SECOND && LIGHT_START_SECOND < DARK_START_SECOND && DARK_START_SECOND < SECONDS_PER_DAY)

// Why appearance_for_time or next_transition_seconds refused its input.
Appearance_Time_Refusal :: enum u8 {
	None                       = 0,
	Unknown_Appearance_Setting = 1,
	Invalid_Hour               = 2,
	Invalid_Minute             = 3,
	Invalid_Second             = 4,
}

// validate_hms checks that (hour, minute, second) is a valid 24-hour wall
// clock time of day.
validate_hms :: proc "contextless" (hour, minute, second: i32) -> Appearance_Time_Refusal {
	if hour < 0 || hour > 23 {
		return .Invalid_Hour
	}
	if minute < 0 || minute > 59 {
		return .Invalid_Minute
	}
	if second < 0 || second > 59 {
		return .Invalid_Second
	}
	return .None
}

// hms_of_second_of_day splits a local second of day in [0, 86400) into
// (hour, minute, second). Values outside that range are refused.
hms_of_second_of_day :: proc "contextless" (second_of_day: i64) -> (hour: i32, minute: i32, second: i32, ok: bool) {
	if second_of_day < 0 || second_of_day >= SECONDS_PER_DAY {
		return 0, 0, 0, false
	}
	hour = i32(second_of_day / 3_600)
	minute = i32((second_of_day / 60) % 60)
	second = i32(second_of_day % 60)
	return hour, minute, second, true
}

// appearance_for_time evaluates the appearance in force for setting at local
// wall-clock time (hour, minute, second). When time_known is true, invalid
// hours, minutes, or seconds are refused. When time_known is false, Dark and
// Light keep their explicit choice and Auto falls back to Dark.
appearance_for_time :: proc "contextless" (
	setting: settings.Appearance,
	hour: i32,
	minute: i32,
	second: i32,
	time_known: bool,
) -> (
	in_force: settings.Appearance_In_Force,
	refusal: Appearance_Time_Refusal,
) {
	validated, ok := enum_word.member_of_word(settings.Appearance, u64(setting))
	if !ok {
		return .Dark, .Unknown_Appearance_Setting
	}
	if time_known {
		if time_refusal := validate_hms(hour, minute, second); time_refusal != .None {
			return .Dark, time_refusal
		}
	}
	switch validated {
	case .Dark:
		return .Dark, .None
	case .Light:
		return .Light, .None
	case .Auto:
		if !time_known {
			return .Dark, .None
		}
		sec := i64(hour) * 3_600 + i64(minute) * 60 + i64(second)
		if sec >= LIGHT_START_SECOND && sec < DARK_START_SECOND {
			return .Light, .None
		}
		return .Dark, .None
	}
	return .Dark, .Unknown_Appearance_Setting
}

// next_transition_seconds returns the number of seconds until the next
// 07:00:00 or 19:00:00 transition after (hour, minute, second).
next_transition_seconds :: proc "contextless" (hour, minute, second: i32) -> (wait_seconds: i64, refusal: Appearance_Time_Refusal) {
	if time_refusal := validate_hms(hour, minute, second); time_refusal != .None {
		return 0, time_refusal
	}
	sec := i64(hour) * 3_600 + i64(minute) * 60 + i64(second)
	switch {
	case sec < LIGHT_START_SECOND:
		return LIGHT_START_SECOND - sec, .None
	case sec < DARK_START_SECOND:
		return DARK_START_SECOND - sec, .None
	case:
		return SECONDS_PER_DAY - sec + LIGHT_START_SECOND, .None
	}
}
