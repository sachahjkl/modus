#+build !freestanding
package display_choices

import "core:testing"
import "modus:contract/notifications"
import "modus:contract/plan_values"
import "modus:contract/module"
import "modus:contract/chosen_values"
import "modus:contract/desktop_shell"
import "modus:contract/powerbox"

// The border refuses each value out of its range or that names no member,
// at each edge, and takes each edge inside.
@(test)
the_border_of_each_setting_refuses_its_edges :: proc(t: ^testing.T) {
	refused := [Setting][]u64 {
		.Bar_Edge               = {0, 5, 255, max(u64)},
		.Do_Not_Disturb         = {2, max(u64)},
		.Notification_Show_Time = {0, 999, 60_001, max(u64)},
		.Magnifier_Factor       = {0, 11, 65, max(u64)},
		.Consent_Arm_Time       = {0, 1, powerbox.CONSENT_ARM_MILLISECONDS - 1, 10_001, max(u64)},
	}
	taken := [Setting][]u64 {
		.Bar_Edge               = {1, 2, 3, 4},
		.Do_Not_Disturb         = {0, 1},
		.Notification_Show_Time = {1_000, 8_000, 60_000},
		.Magnifier_Factor       = {12, 16, 64},
		.Consent_Arm_Time       = {powerbox.CONSENT_ARM_MILLISECONDS, 10_000},
	}
	for setting in Setting {
		for word in refused[setting] {
			testing.expectf(t, !word_valid(setting, word), "%v takes %d", setting, word)
		}
		for word in taken[setting] {
			testing.expectf(t, word_valid(setting, word), "%v refuses %d", setting, word)
		}
	}
	_, unknown := setting_of_word(5)
	testing.expect(t, !unknown)
	_, largest := setting_of_word(max(u64))
	testing.expect(t, !largest)
}

// The defaults of the contract pass the border: a default is never a value
// that a setter refuses.
@(test)
each_default_passes_its_border :: proc(t: ^testing.T) {
	for setting in Setting {
		testing.expect(t, word_valid(setting, word_of(CONTRACT_DEFAULTS, setting)))
		testing.expect(t, chosen_values.name_valid(SETTING_NAMES[setting]))
	}
}

// A kept record gives each chosen word that its border takes, and the
// default with its layer for a word that it refuses and for a name that it
// does not hold. A name that the contract does not know changes nothing.
@(test)
a_kept_word_that_the_border_refuses_holds_as_no_choice :: proc(t: ^testing.T) {
	buffer: [chosen_values.HEADER_SIZE + 4 * chosen_values.ENTRY_SIZE]u8
	written, problem := chosen_values.write_record({}, {
		{name = "bar_edge", kind = .Choose, value = 2},
		{name = "notification_show_milliseconds", kind = .Choose, value = 70_000},
		{name = "consent_arm_milliseconds", kind = .Choose, value = 1_500},
		{name = "from_a_later_release", kind = .Choose, value = 3},
	}, buffer[:])
	testing.expect_value(t, problem, chosen_values.Record_Problem.None)
	record, read_problem := chosen_values.read_record(buffer[:written])
	testing.expect_value(t, read_problem, chosen_values.Record_Problem.None)
	choices := choices_of_record(record)
	testing.expect_value(t, choices.bar_edge, desktop_shell.Bar_Position.Bottom)
	testing.expect_value(t, choices.layers[.Bar_Edge], chosen_values.Layer.Chosen)
	testing.expect_value(t, choices.notification_show_milliseconds, CONTRACT_DEFAULTS.notification_show_milliseconds)
	testing.expect_value(t, choices.layers[.Notification_Show_Time], chosen_values.Layer.Contract_Default)
	testing.expect_value(t, choices.consent_arm_milliseconds, u64(1_500))
	testing.expect_value(t, choices.do_not_disturb, Do_Not_Disturb.Off)
	testing.expect_value(t, choices.layers[.Do_Not_Disturb], chosen_values.Layer.Contract_Default)
	empty := choices_of_record({})
	testing.expect_value(t, empty, CONTRACT_DEFAULTS)
}

// The setter refuses a call with no argument, and refuses whole a pair that
// its border refuses: a Presence word past Given, a word that names no
// member, a number at each edge outside its range, a negative number. A
// caller that passes zeros passes absence. Each setting that is taken
// comes last, at its edges.
@(test)
a_set_that_its_border_refuses_changes_nothing :: proc(t: ^testing.T) {
	_, count, _, nothing := changes_of_set({})
	testing.expect_value(t, nothing, Set_Problem.Nothing_Given)
	testing.expect_value(t, count, 0)
	Case :: struct {
		arguments: Set_Arguments,
		argument:  int,
	}
	quiet_given := Set_Arguments{do_not_disturb_presence = .Given, do_not_disturb = .On}
	cases := make([dynamic]Case, context.temp_allocator)
	for word in ([?]u8{0, 5, 0xFE, 0xFF}) {
		with := quiet_given
		with.bar_edge_presence, with.bar_edge = .Given, desktop_shell.Bar_Position(word)
		append(&cases, Case{with, 1})
	}
	for presence in ([?]u64{2, max(u64)}) {
		with := quiet_given
		with.bar_edge_presence, with.bar_edge = module.Presence(presence), .Bottom
		append(&cases, Case{with, 1})
	}
	append(&cases, Case{{do_not_disturb_presence = .Given, do_not_disturb = Do_Not_Disturb(2)}, 2})
	for value in ([?]i64{i64(notifications.SHOW_MILLISECONDS_LEAST) - 1, i64(notifications.SHOW_MILLISECONDS_MOST) + 1, 0, -1, min(i64), max(i64)}) {
		append(&cases, Case{{notification_show_milliseconds_presence = .Given, notification_show_milliseconds = value}, 3})
	}
	for value in ([?]i64{i64(MAGNIFIER_EIGHTHS_LEAST) - 1, i64(MAGNIFIER_EIGHTHS_MOST) + 1, 0, -12}) {
		append(&cases, Case{{magnifier_eighths_presence = .Given, magnifier_eighths = value}, 4})
	}
	for value in ([?]i64{i64(CONSENT_ARM_MILLISECONDS_LEAST) - 1, i64(CONSENT_ARM_MILLISECONDS_MOST) + 1, 0, -500}) {
		append(&cases, Case{{consent_arm_milliseconds_presence = .Given, consent_arm_milliseconds = value}, 5})
	}
	for item in cases {
		_, refused_count, argument, problem := changes_of_set(item.arguments)
		testing.expectf(t, problem == .Bad_Value && argument == item.argument && refused_count == 0, "%v gives %v at %d", item.arguments, problem, argument)
	}
	// Absent with a value that would be refused: not read.
	absent := Set_Arguments{bar_edge = desktop_shell.Bar_Position(0xFF), notification_show_milliseconds = -1, do_not_disturb_presence = .Given, do_not_disturb = .On}
	changes, given, _, fine := changes_of_set(absent)
	testing.expect(t, fine == .None && given == 1 && changes[0].name == "do_not_disturb" && changes[0].value == 1)
	edges := Set_Arguments {
		bar_edge_presence = .Given, bar_edge = .Bottom,
		notification_show_milliseconds_presence = .Given, notification_show_milliseconds = i64(notifications.SHOW_MILLISECONDS_LEAST),
		magnifier_eighths_presence = .Given, magnifier_eighths = i64(MAGNIFIER_EIGHTHS_MOST),
		consent_arm_milliseconds_presence = .Given, consent_arm_milliseconds = i64(CONSENT_ARM_MILLISECONDS_LEAST),
	}
	all, all_count, _, all_fine := changes_of_set(edges)
	testing.expect(t, all_fine == .None && all_count == 4)
	testing.expect_value(t, all[0].value, u64(desktop_shell.Bar_Position.Bottom))
	testing.expect_value(t, all[1].value, notifications.SHOW_MILLISECONDS_LEAST)
	testing.expect_value(t, all[2].value, MAGNIFIER_EIGHTHS_MOST)
	testing.expect_value(t, all[3].value, CONSENT_ARM_MILLISECONDS_LEAST)
}


// plan_of writes the defaults and the locks of a plan of one owner.
@(private = "file")
plan_of :: proc(defaults, locks: []chosen_values.Change) -> (plan: plan_values.Owner_Values) {
	defaults_bytes := make([]u8, chosen_values.HEADER_SIZE + 16 * chosen_values.ENTRY_SIZE, context.temp_allocator)
	locks_bytes := make([]u8, chosen_values.HEADER_SIZE + 16 * chosen_values.ENTRY_SIZE, context.temp_allocator)
	written, _ := chosen_values.write_record({}, defaults, defaults_bytes)
	plan.defaults, _ = chosen_values.read_record(defaults_bytes[:written])
	written, _ = chosen_values.write_record({}, locks, locks_bytes)
	plan.locks, _ = chosen_values.read_record(locks_bytes[:written])
	return plan
}

// The precedence of the settings of the role: a lock of the arm time hides
// a choice of it, a default of the plan gives the edge of the bar under no
// choice, and a time of the plan out of its range holds as no value.
@(test)
a_lock_of_the_role_hides_a_choice :: proc(t: ^testing.T) {
	buffer: [chosen_values.HEADER_SIZE + 8 * chosen_values.ENTRY_SIZE]u8
	written, _ := chosen_values.write_record({}, {{name = "consent_arm_milliseconds", kind = .Choose, value = 2_000}}, buffer[:])
	record, _ := chosen_values.read_record(buffer[:written])
	plan := plan_of({{name = "bar_edge", kind = .Choose, value = u64(desktop_shell.Bar_Position.Bottom)}, {name = "notification_show_milliseconds", kind = .Choose, value = 10}}, {{name = "consent_arm_milliseconds", kind = .Choose, value = 1_000}})
	choices := choices_of_record(record, plan)
	testing.expect(t, choices.consent_arm_milliseconds == 1_000 && choices.layers[.Consent_Arm_Time] == .Locked)
	testing.expect(t, choices.bar_edge == .Bottom && choices.layers[.Bar_Edge] == .Plan_Default)
	testing.expect(t, choices.notification_show_milliseconds == CONTRACT_DEFAULTS.notification_show_milliseconds && choices.layers[.Notification_Show_Time] == .Contract_Default)
	testing.expect(t, setting_locked(plan, .Consent_Arm_Time) && !setting_locked(plan, .Bar_Edge))
}

// The lock of a call of set of the role: only a given setting counts, and
// the first one in the order of the parameters is named.
@(test)
a_call_that_gives_a_locked_setting_of_the_role_is_named :: proc(t: ^testing.T) {
	plan := plan_of({}, {{name = "magnifier_eighths", kind = .Choose, value = 16}, {name = "consent_arm_milliseconds", kind = .Choose, value = 1_000}})
	presences: [Setting]module.Presence
	presences[.Bar_Edge] = .Given
	presences[.Magnifier_Factor] = module.Presence(2)
	_, found := first_locked(plan, presences)
	testing.expect(t, !found)
	presences[.Consent_Arm_Time] = .Given
	setting, arm_found := first_locked(plan, presences)
	testing.expect(t, arm_found && setting == .Consent_Arm_Time)
	presences[.Magnifier_Factor] = .Given
	setting, found = first_locked(plan, presences)
	testing.expect(t, found && setting == .Magnifier_Factor)
}
