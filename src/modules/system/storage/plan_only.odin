package storage_service

import module "modus:contract/module"
import "modus:contract/errors"
import "internal:storage/storage_retention"

// plan_only describes the plan-only values of the storage service: the two times of the retention rule of the versions. Only the plan of principal 0 gives them (src/md/features/module_settings.md, "Plan records"); the console types a plan by this description. Each call is refused.
//
// - **keep_all_minutes**: the age under which each version is kept, 1 to 1440 minutes.
// - **hours_end_hours**: the age at which the newest version of each hour stops and the newest of each day starts, 1 to 720 hours, after keep_all_minutes.
//
// The result is -1 with an error record: No_Grant, unit Plan_Lock: the plan is the one door of these values.
//
// ```
// plans.apply("retention", plan { values = { storage = { keep_all_minutes = 30 } } }, {})
// ```
@(export, link_name = "plan_only", parameter_ranges = "keep_all_minutes = 1..1440, hours_end_hours = 1..720")
plan_only_export :: proc "c" (keep_all_minutes_presence: module.Presence, keep_all_minutes: i64, hours_end_hours_presence: module.Presence, hours_end_hours: i64, error: ^errors.Error_Record) -> i64 {
	return errors.fail(error, -1, .No_Grant, .Plan_Lock, 0)
}

// The ranges of the description are the borders of the rule.
#assert(storage_retention.KEEP_ALL_MINUTES_LEAST == 1 && storage_retention.KEEP_ALL_MINUTES_MOST == 1440)
#assert(storage_retention.HOURS_END_HOURS_LEAST == 1 && storage_retention.HOURS_END_HOURS_MOST == 720)
