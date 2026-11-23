// The settings of the role Display (src/md/features/module_settings.md,
// "The value model"): the choices of the principal that the holder of the
// display owns, keeps in the store of its role, checks and serves. A holder
// that the plan puts in place of another reads the same names from the same
// store, so the choices of the principal stay.
//
// Each setting has a name, which is its key in the kept record of chosen
// values (modus:contract/chosen_values), a default of the contract, and one
// border that both the setter and the reader of the kept record call.
//
// This package allocates no memory and calls no kernel operation.
package display_choices

import "modus:contract/chosen_values"
import "modus:contract/desktop_shell"
import "modus:contract/enum_word"
import "modus:contract/module"
import "modus:contract/notifications"
import "modus:contract/plan_values"
import "modus:contract/powerbox"

// The settings of the role, in the order of the rows of the state export.
// The values cross the call region in the argument of reset, so they are
// stated; setting_of_word is their border.
Setting :: enum u32 {
	Bar_Edge                = 0, // The edge of the screen that holds the bar.
	Do_Not_Disturb          = 1, // Whether a notification that is not critical shows.
	Notification_Show_Time  = 2, // How long a card shows, in milliseconds.
	Magnifier_Factor        = 3, // The factor of the magnifier when the principal turns it on, in eighths.
	Consent_Arm_Time        = 4, // The arm time of a dialog of the trusted display, never under the one of the contract.
}

// The name of each setting: its key in the kept record, and the name of
// its parameter in the exports of the holder.
@(rodata)
SETTING_NAMES := [Setting]string {
	.Bar_Edge               = "bar_edge",
	.Do_Not_Disturb         = "do_not_disturb",
	.Notification_Show_Time = "notification_show_milliseconds",
	.Magnifier_Factor       = "magnifier_eighths",
	.Consent_Arm_Time       = "consent_arm_milliseconds",
}

// setting_of_word is the border of a word that names a setting.
setting_of_word :: proc "contextless" (word: u64) -> (setting: Setting, ok: bool) {
	return enum_word.member_of_word(Setting, word)
}

// Whether the notifications that are not critical show.
Do_Not_Disturb :: enum u32 {
	Off = 0, // They show: the default.
	On  = 1, // Only a critical card shows.
}

// The range of the factor of the magnifier, in eighths: 1.5 to 8 times.
MAGNIFIER_EIGHTHS_LEAST :: u64(12)
MAGNIFIER_EIGHTHS_MOST :: u64(64)
MAGNIFIER_EIGHTHS_DEFAULT :: u64(16)
#assert(MAGNIFIER_EIGHTHS_LEAST <= MAGNIFIER_EIGHTHS_DEFAULT && MAGNIFIER_EIGHTHS_DEFAULT <= MAGNIFIER_EIGHTHS_MOST)

// The arm time that a principal may choose: never under the one of the
// contract, which protects each dialog from a key meant for a window; and
// at most ten seconds, past which a dialog seems to take no key at all.
CONSENT_ARM_MILLISECONDS_LEAST :: powerbox.CONSENT_ARM_MILLISECONDS
CONSENT_ARM_MILLISECONDS_MOST :: u64(10_000)
#assert(CONSENT_ARM_MILLISECONDS_LEAST < CONSENT_ARM_MILLISECONDS_MOST)

// The choices in force of the role, each with the layer that gives it.
Choices :: struct {
	bar_edge:                       desktop_shell.Bar_Position,
	do_not_disturb:                 Do_Not_Disturb,
	notification_show_milliseconds: u64,
	magnifier_eighths:              u64,
	consent_arm_milliseconds:       u64,
	layers:                         [Setting]chosen_values.Layer,
}

// The defaults of the contract: what holds while the principal chose
// nothing.
CONTRACT_DEFAULTS :: Choices {
	bar_edge                       = .Top,
	do_not_disturb                 = .Off,
	notification_show_milliseconds = notifications.SHOW_MILLISECONDS_DEFAULT,
	magnifier_eighths              = MAGNIFIER_EIGHTHS_DEFAULT,
	consent_arm_milliseconds       = CONSENT_ARM_MILLISECONDS_LEAST,
}

// word_valid is the one border of a value of a setting: the setter calls it
// before it keeps a word, and the reader of the kept record before it uses
// one. A word that names no member, or a number out of its range, is
// refused.
word_valid :: proc "contextless" (setting: Setting, word: u64) -> bool {
	switch setting {
	case .Bar_Edge:
		_, ok := desktop_shell.bar_position_of_word(word)
		return ok
	case .Do_Not_Disturb:
		_, ok := enum_word.member_of_word(Do_Not_Disturb, word)
		return ok
	case .Notification_Show_Time:
		return notifications.show_milliseconds_valid(word)
	case .Magnifier_Factor:
		return word >= MAGNIFIER_EIGHTHS_LEAST && word <= MAGNIFIER_EIGHTHS_MOST
	case .Consent_Arm_Time:
		return word >= CONSENT_ARM_MILLISECONDS_LEAST && word <= CONSENT_ARM_MILLISECONDS_MOST
	}
	return false
}

// The border of the word of each setting, for the precedence.
@(rodata)
setting_borders := [Setting]proc "contextless" (word: u64) -> bool {
	.Bar_Edge               = proc "contextless" (word: u64) -> bool {return word_valid(.Bar_Edge, word)},
	.Do_Not_Disturb         = proc "contextless" (word: u64) -> bool {return word_valid(.Do_Not_Disturb, word)},
	.Notification_Show_Time = proc "contextless" (word: u64) -> bool {return word_valid(.Notification_Show_Time, word)},
	.Magnifier_Factor       = proc "contextless" (word: u64) -> bool {return word_valid(.Magnifier_Factor, word)},
	.Consent_Arm_Time       = proc "contextless" (word: u64) -> bool {return word_valid(.Consent_Arm_Time, word)},
}

// setting_locked says if the plan locks a setting of the role: the setter
// refuses a change of it with No_Grant, and keeps the choice of the
// principal under the lock.
setting_locked :: proc "contextless" (plan: plan_values.Owner_Values, setting: Setting) -> bool {
	return plan_values.locked(plan, SETTING_NAMES[setting])
}

// first_locked gives the first setting that a call of set gives and that a
// lock of the plan holds: the setter refuses the whole call with No_Grant,
// unit Plan_Lock (src/md/features/module_settings.md, "The lock"). A
// presence that is not Given never counts.
first_locked :: proc "contextless" (plan: plan_values.Owner_Values, presences: [Setting]module.Presence) -> (setting: Setting, found: bool) {
	for member in Setting {
		if presences[member] == .Given && setting_locked(plan, member) {
			return member, true
		}
	}
	return {}, false
}

// word_of gives the word of a setting in a set of choices.
word_of :: proc "contextless" (choices: Choices, setting: Setting) -> u64 {
	switch setting {
	case .Bar_Edge:
		return u64(choices.bar_edge)
	case .Do_Not_Disturb:
		return u64(choices.do_not_disturb)
	case .Notification_Show_Time:
		return choices.notification_show_milliseconds
	case .Magnifier_Factor:
		return choices.magnifier_eighths
	case .Consent_Arm_Time:
		return choices.consent_arm_milliseconds
	}
	return 0
}

// choices_of_record gives the choices in force from a checked kept record:
// each chosen word that passes its border, and the default of the contract
// for each other setting. A chosen word that its border refuses holds as no
// choice, and the caller keeps it as it was: a later release may know it.
choices_of_record :: proc "contextless" (record: chosen_values.Record, plan: plan_values.Owner_Values = {}) -> Choices {
	choices := CONTRACT_DEFAULTS
	for setting in Setting {
		// The precedence: a lock of the plan, a choice of the principal, a
		// default of the plan, the default of the contract.
		word, layer, found := plan_values.value_in_force(SETTING_NAMES[setting], record, plan, setting_borders[setting])
		if !found {
			continue
		}
		choices.layers[setting] = layer
		switch setting {
		case .Bar_Edge:
			choices.bar_edge, _ = desktop_shell.bar_position_of_word(word)
		case .Do_Not_Disturb:
			choices.do_not_disturb, _ = enum_word.member_of_word(Do_Not_Disturb, word)
		case .Notification_Show_Time:
			choices.notification_show_milliseconds = word
		case .Magnifier_Factor:
			choices.magnifier_eighths = word
		case .Consent_Arm_Time:
			choices.consent_arm_milliseconds = word
		}
	}
	return choices
}

// Why a call of a setter changes nothing.
Set_Problem :: enum u8 {
	None          = 0,
	Nothing_Given = 1, // Each optional parameter is absent.
	Bad_Value     = 2, // A word that names no member, or a number out of its range: refused_argument names it, from 1.
}

// The arguments of the setter `set` of the role, as its caller wrote them:
// each setting is optional, a Presence word then its value
// (src/md/features/module_settings.md, "The description of a parameter").
Set_Arguments :: struct {
	bar_edge_presence:                       module.Presence,
	bar_edge:                                desktop_shell.Bar_Position,
	do_not_disturb_presence:                 module.Presence,
	do_not_disturb:                          Do_Not_Disturb,
	notification_show_milliseconds_presence: module.Presence,
	notification_show_milliseconds:          i64,
	magnifier_eighths_presence:              module.Presence,
	magnifier_eighths:                       i64,
	consent_arm_milliseconds_presence:       module.Presence,
	consent_arm_milliseconds:                i64,
}

// changes_of_set gives the changes of one call of the setter, from its
// arguments as its caller wrote them: an absent setting changes nothing,
// and one pair that its border refuses (a Presence word past Given, a word
// that names no member, a number out of its range) refuses the whole call.
// refused_argument is the parameter of the refusal, from 1. The setter and
// its host test call this one procedure.
changes_of_set :: proc "contextless" (arguments: Set_Arguments) -> (changes: [len(Setting)]chosen_values.Change, count: int, refused_argument: int, problem: Set_Problem) {
	Word :: struct {
		word:  u64,
		given: bool,
		ok:    bool,
	}
	words: [Setting]Word
	edge, edge_given, edge_ok := module.optional_member_of_arguments(arguments.bar_edge_presence, arguments.bar_edge)
	words[.Bar_Edge] = {u64(edge), edge_given, edge_ok}
	quiet, quiet_given, quiet_ok := module.optional_member_of_arguments(arguments.do_not_disturb_presence, arguments.do_not_disturb)
	words[.Do_Not_Disturb] = {u64(quiet), quiet_given, quiet_ok}
	Integers :: struct {
		setting:  Setting,
		presence: module.Presence,
		value:    i64,
	}
	integers := [3]Integers {
		{.Notification_Show_Time, arguments.notification_show_milliseconds_presence, arguments.notification_show_milliseconds},
		{.Magnifier_Factor, arguments.magnifier_eighths_presence, arguments.magnifier_eighths},
		{.Consent_Arm_Time, arguments.consent_arm_milliseconds_presence, arguments.consent_arm_milliseconds},
	}
	for item in integers {
		value, given, ok := module.optional_integer_of_arguments(item.presence, item.value)
		// A negative number is out of each range: its word would read as a
		// large one.
		words[item.setting] = {u64(max(value, 0)), given, ok && value >= 0}
	}
	for setting in Setting {
		item := words[setting]
		if !item.ok || item.given && !word_valid(setting, item.word) {
			return {}, 0, int(setting) + 1, .Bad_Value
		}
		if item.given {
			changes[count] = {name = SETTING_NAMES[setting], kind = .Choose, value = item.word}
			count += 1
		}
	}
	if count == 0 {
		return {}, 0, 0, .Nothing_Given
	}
	return changes, count, 0, .None
}

// The name of the object of the role store that holds the kept record.
KEPT_OBJECT_NAME :: "display_choices"
