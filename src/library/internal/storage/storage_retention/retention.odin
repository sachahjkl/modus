// The retention rule of the versions of an object (docs/ARCHITECTURE.md,
// U5, "Versions"): each version is kept for 10 minutes; after that, the
// newest version of each hour, until the version is one day old; after
// that, the newest version of each day. Pure code: the storage service
// applies it, and the host tests check it.
//
// The two times are plan-only values of the owner `storage`: a plan of
// principal 0 can keep more or fewer versions, which spends the disk of the
// machine (src/md/features/module_settings.md, "Plan records"). rule_of
// is the one border of the two times and of their order.
//
// The times are the time since the format of the disk, in milliseconds,
// until the system has a date. An hour and a day are counted from the
// format: the buckets do not move from one application to the next, so a
// version that the rule keeps stays kept until it changes zone.
package storage_retention

import "modus:contract/chosen_values"
import "modus:contract/plan_values"

KEEP_ALL_MILLISECONDS :: 10 * 60 * 1000 // The age under which each version is kept: 10 minutes.
HOUR_MILLISECONDS :: 60 * 60 * 1000 // The bucket of the zone of the hours, and its end at one day.
DAY_MILLISECONDS :: 24 * HOUR_MILLISECONDS // The bucket of the zone of the days.

// The rule: the age under which each version is kept, and the age at which
// the zone of the hours ends and the zone of the days starts.
Rule :: struct {
	keep_all_milliseconds: u64,
	hours_end_milliseconds: u64,
}

DEFAULT_RULE :: Rule{keep_all_milliseconds = KEEP_ALL_MILLISECONDS, hours_end_milliseconds = DAY_MILLISECONDS}

// The fields of the plan values of the owner `storage`, in minutes and in
// hours, and their borders: each version kept 1 minute to one day; the
// zone of the hours ends after 1 hour to 30 days.
KEEP_ALL_FIELD :: "keep_all_minutes"
HOURS_END_FIELD :: "hours_end_hours"
KEEP_ALL_MINUTES_LEAST :: u64(1)
KEEP_ALL_MINUTES_MOST :: u64(24 * 60)
HOURS_END_HOURS_LEAST :: u64(1)
HOURS_END_HOURS_MOST :: u64(30 * 24)

// rule_of reads the rule from the plan values of the owner `storage`: each
// time at its border, then their order: the zone of the hours ends after
// the time that keeps each version. A pair that breaks the order gives the
// default rule whole.
rule_of :: proc "contextless" (plan: plan_values.Owner_Values) -> (rule: Rule, order_refused: bool) {
	rule = DEFAULT_RULE
	empty: chosen_values.Record
	minutes_border :: proc "contextless" (word: u64) -> bool {return word >= KEEP_ALL_MINUTES_LEAST && word <= KEEP_ALL_MINUTES_MOST}
	hours_border :: proc "contextless" (word: u64) -> bool {return word >= HOURS_END_HOURS_LEAST && word <= HOURS_END_HOURS_MOST}
	if minutes, _, found := plan_values.value_in_force(KEEP_ALL_FIELD, empty, plan, minutes_border); found {
		rule.keep_all_milliseconds = minutes * 60 * 1000
	}
	if hours, _, found := plan_values.value_in_force(HOURS_END_FIELD, empty, plan, hours_border); found {
		rule.hours_end_milliseconds = hours * HOUR_MILLISECONDS
	}
	if rule.keep_all_milliseconds >= rule.hours_end_milliseconds {
		return DEFAULT_RULE, true
	}
	return rule, false
}

// keeps says, for the times of the versions of one object, the oldest
// first, which versions the rule keeps at the time `now`. keep has the
// length of times. It gives the count of the versions to thin.
//
// Example: versions 5, 20 and 50 minutes old, the two older ones in the
// same hour from the format: the version of 5 minutes is kept (under 10
// minutes), and of the two others the newest of the hour (20 minutes) is
// kept; `thinned` is 1.
keeps :: proc "contextless" (times: []u64, now: u64, keep: []bool, rule: Rule = DEFAULT_RULE) -> (thinned: int) {
	last_hour, last_day := max(u64), max(u64) // The bucket of the last version kept in each zone.
	for index := len(times) - 1; index >= 0; index -= 1 {
		time := times[index]
		age := now > time ? now - time : 0
		switch {
		case age < rule.keep_all_milliseconds:
			keep[index] = true
		case age < rule.hours_end_milliseconds:
			bucket := time / HOUR_MILLISECONDS
			keep[index] = bucket != last_hour
			last_hour = bucket
		case:
			bucket := time / DAY_MILLISECONDS
			keep[index] = bucket != last_day
			last_day = bucket
		}
		if !keep[index] {
			thinned += 1
		}
	}
	return thinned
}

// DATE_SECONDS_LIMIT is the first second of the year 10000: a date at or
// after it is no date that a clock gives, and it is not used.
DATE_SECONDS_LIMIT :: u64(253402300800)

// age gives the age of a version in milliseconds: the smaller of its age in
// the time since the format and its age in the date. The time since the
// format counts only the time when a machine ran, so it never makes a
// version older than it is; the date counts the time when no machine ran,
// but a clock can be wrong on one start and right on the next (an empty
// battery), and then each version of the wrong start would look years old.
// A date of 0 is no date. A version whose time or date is after now has
// the age 0.
//   now_time, version_time: milliseconds since the format.
//   now_date, version_date: seconds since 1970 (UTC).
age :: proc "contextless" (now_time, version_time: u64, now_date, version_date: u64) -> u64 {
	by_time := now_time > version_time ? now_time - version_time : 0
	if now_date == 0 || version_date == 0 || now_date >= DATE_SECONDS_LIMIT || version_date >= DATE_SECONDS_LIMIT {
		return by_time
	}
	by_date := now_date > version_date ? (now_date - version_date) * 1000 : 0
	return min(by_time, by_date)
}

// rule_now gives the time that keeps measures from: the date in
// milliseconds when it is known, else the time since the format. The time
// of a version for keeps is rule_now minus its age.
rule_now :: proc "contextless" (now_time: u64, now_date: u64) -> u64 {
	return now_date != 0 && now_date < DATE_SECONDS_LIMIT ? now_date * 1000 : now_time
}
