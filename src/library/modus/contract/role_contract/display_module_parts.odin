package role_contract

import "modus:contract/display_choices"
import "modus:contract/module"
import "modus:contract/module_file_writer"
import "modus:contract/notifications"

// The parts of a module file that fills the contract of Display and holds no
// code: what a host test of a holder, of the check of a holder and of the
// conformance suite writes, so that each one follows the one contract.
// The caller keeps the record while it writes the file: its slices point
// into it.
Display_Module_Parts :: struct {
	exports:        [DISPLAY_MODULE_EXPORT_COUNT]module_file_writer.Export_Part,
	records:        [5]module_file_writer.Record_Description,
	enums:          [3]module_file_writer.Enum_Description,
	set_details:    [5]u32,
	set_ranges:     [3]module.Parameter_Setting,
	reset_details:  [1]u32,
}

// The exports of a module that fills the contract: pointer, windows and
// screen, then the settings of the role. A writer gives set_ranges as the
// rows of the table Parameter_Settings.
DISPLAY_MODULE_EXPORT_COUNT :: 11

@(private = "file", rodata)
display_value_field := [1]module_file_writer.Field_Description{{name = "value", offset = 0, type = .Integer, detail = 8}}
@(private = "file", rodata)
display_edge_members := [2]module_file_writer.Member_Description{{name = "top", value = 1}, {name = "bottom", value = 2}}
@(private = "file", rodata)
display_quiet_members := [2]module_file_writer.Member_Description{{name = "off", value = 0}, {name = "on", value = 1}}
@(private = "file", rodata)
display_setting_members := [2]module_file_writer.Member_Description{{name = "bar_edge", value = 0}, {name = "do_not_disturb", value = 1}}
@(private = "file", rodata)
display_set_types := [5]module.Type{.Enum, .Enum, .Integer, .Integer, .Integer}
@(private = "file", rodata)
display_set_names := [5]string{"bar_edge", "do_not_disturb", "notification_show_milliseconds", "magnifier_eighths", "consent_arm_milliseconds"}
@(private = "file", rodata)
display_set_needs := [5]module.Parameter_Need{.Optional, .Optional, .Optional, .Optional, .Optional}
@(private = "file", rodata)
display_one_enum := [1]module.Type{.Enum}
@(private = "file", rodata)
display_one_setting := [1]string{"setting"}

// display_module_parts_write writes the parts into a record of the caller.
// The records are 1 Pointer, 2 Window, 3 Screen, 4 Error_Record and
// 5 Setting_State; the enums are 1 Bar_Position, 2 Do_Not_Disturb and
// 3 Setting.
display_module_parts_write :: proc "contextless" (parts: ^Display_Module_Parts) {
	parts.records = {
		{name = "Pointer", size = 8, fields = display_value_field[:]},
		{name = "Window", size = 8, fields = display_value_field[:]},
		{name = "Screen", size = 8, fields = display_value_field[:]},
		{name = "Error_Record", size = 8, fields = display_value_field[:]},
		{name = "Setting_State", size = 8, fields = display_value_field[:]},
	}
	parts.enums = {
		{name = "Bar_Position", size = 1, unsigned = true, members = display_edge_members[:]},
		{name = "Do_Not_Disturb", size = 4, unsigned = true, members = display_quiet_members[:]},
		{name = "Setting", size = 4, unsigned = true, members = display_setting_members[:]},
	}
	// The getters of the parameters of set are the exports 5 and 6, from 1.
	parts.set_details[0], _ = module.enum_detail_make(1, 5)
	parts.set_details[1], _ = module.enum_detail_make(2, 6)
	parts.reset_details[0], _ = module.enum_detail_make(3, 0)
	// The ranges of the three numbers of set, the export 4, from the
	// constants of the contract.
	parts.set_ranges = {
		{export_index = 4, parameter = 2, has_range = 1, least = i64(notifications.SHOW_MILLISECONDS_LEAST), most = i64(notifications.SHOW_MILLISECONDS_MOST)},
		{export_index = 4, parameter = 3, has_range = 1, least = i64(display_choices.MAGNIFIER_EIGHTHS_LEAST), most = i64(display_choices.MAGNIFIER_EIGHTHS_MOST)},
		{export_index = 4, parameter = 4, has_range = 1, least = i64(display_choices.CONSENT_ARM_MILLISECONDS_LEAST), most = i64(display_choices.CONSENT_ARM_MILLISECONDS_MOST)},
	}
	parts.exports = {
		{name = DISPLAY_EXPORT_POINTER, result = .Table, result_detail = 1, error_record = 4},
		{name = DISPLAY_EXPORT_WINDOWS, result = .Table, result_detail = 2, error_record = 4},
		{name = DISPLAY_EXPORT_SCREEN, result = .Table, result_detail = 3, error_record = 4},
		{name = DISPLAY_EXPORT_SET, parameters = display_set_types[:], parameter_names = display_set_names[:], parameter_details = parts.set_details[:], parameter_needs = display_set_needs[:], result = .Integer, error_record = 4},
		{name = "bar_edge", result = .Enum, result_detail = 1},
		{name = "do_not_disturb", result = .Enum, result_detail = 2},
		{name = "notification_time", result = .Integer},
		{name = "magnifier_factor", result = .Integer},
		{name = "consent_arm_time", result = .Integer},
		{name = DISPLAY_EXPORT_RESET, parameters = display_one_enum[:], parameter_names = display_one_setting[:], parameter_details = parts.reset_details[:], result = .Integer, error_record = 4},
		{name = DISPLAY_EXPORT_SETTINGS_STATE, result = .Table, result_detail = 5, error_record = 4},
	}
}
