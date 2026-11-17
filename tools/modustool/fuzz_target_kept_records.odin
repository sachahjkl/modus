package modustool

import "core:mem"
import "core:slice"
import op "modus:contract/operation"
import "modus:contract/settings"
import "modus:support/disk_program"

// The fuzz targets of the records that a program keeps
// (src/md/infrastructure/fuzzing.md, "The targets, in order of value"):
// the record of the settings in the private store of `settings`, with the
// page that it writes and the text of a zone; and the stop reports that the
// root service keeps for the debugger service, from the report that the
// kernel gives.

// ---------------------------------------------------------------------
// The kept settings.

// fuzz_kept_settings_execute reads the input as a kept record, as the text
// of a zone, and as a settings page. A record that kept_read refuses gives
// the defaults; one that it accepts gives valid values, and kept_of of
// them reads again to the same values. A zone that zone_parse accepts is
// written and read again to the same minutes. A page always reads as valid
// values, and a page written with them reads again to them.
fuzz_kept_settings_execute :: proc(input: []u8) -> Fuzz_Verdict {
	before := slice.clone(input, context.temp_allocator)
	values, zone, ok := settings.kept_read(input)
	if !slice.equal(before, input) {
		return fuzz_broken(.Contract, "kept_read changed the bytes that it read")
	}
	if !ok {
		if values != ([settings.Setting]u32{}) || zone != 0 {
			return fuzz_broken(.Contract, "kept_read refuses the record and gives values")
		}
	} else {
		for setting in settings.Setting {
			if settings.valid(setting, values[setting]) != values[setting] {
				return fuzz_broken(.Contract, "kept_read gives the value %d of the setting %v", values[setting], setting)
			}
		}
		if settings.zone_offset_minutes_valid(zone) != zone {
			return fuzz_broken(.Contract, "kept_read gives the zone %d", zone)
		}
		kept := settings.kept_of(values, zone)
		again_values, again_zone, again_ok := settings.kept_read(mem.ptr_to_bytes(&kept))
		if !again_ok || again_values != values || again_zone != zone {
			return fuzz_broken(.Round_Trip, "the record of kept_of reads as %v, %d, %v", again_values, again_zone, again_ok)
		}
	}
	// The text of a zone: "-00:00" is read as UTC, which is written
	// "+00:00", so the oracle compares the minutes, not the bytes.
	minutes, parsed := settings.zone_parse(string(input))
	if !parsed {
		if minutes != 0 {
			return fuzz_broken(.Contract, "zone_parse refuses the text and gives %d minutes", minutes)
		}
	} else {
		buffer: [settings.ZONE_TEXT_SIZE]u8
		text := settings.zone_text(buffer[:], minutes)
		again, again_parsed := settings.zone_parse(text)
		if !again_parsed || again != minutes || (text != string(input) && minutes != 0) {
			return fuzz_broken(.Round_Trip, "the zone %d writes %q, which reads as %d", minutes, text, again)
		}
	}
	return fuzz_settings_page_check(input)
}

// fuzz_settings_page_check reads the start of an input as a settings page.
@(private = "file")
fuzz_settings_page_check :: proc(input: []u8) -> Fuzz_Verdict {
	page: settings.Page
	copy(mem.ptr_to_bytes(&page), input)
	choice := settings.read(&page)
	if page.change_count & 1 != 0 {
		// A writer that stays in its change: the defaults, with the count.
		if choice != (settings.Choice{change_count = page.change_count}) {
			return fuzz_broken(.Contract, "read of a page in a change gives %v", choice)
		}
		return FUZZ_PASSED
	}
	if choice.change_count != page.change_count {
		return fuzz_broken(.Contract, "read gives the count %d of a page of the count %d", choice.change_count, page.change_count)
	}
	for setting in settings.Setting {
		if choice.values[setting] != settings.valid(setting, page.values[setting]) {
			return fuzz_broken(.Contract, "read gives the value %d of the setting %v for the word %d", choice.values[setting], setting, page.values[setting])
		}
	}
	if choice.zone_offset_minutes != settings.zone_offset_minutes_valid(page.zone_offset_minutes) || choice.appearance_in_force > max(settings.Appearance_In_Force) {
		return fuzz_broken(.Contract, "read gives the zone %d and the appearance %d", choice.zone_offset_minutes, u32(choice.appearance_in_force))
	}
	written: settings.Page
	settings.write(&written, choice.values, choice.zone_offset_minutes, choice.appearance_in_force)
	again := settings.read(&written)
	if settings.values_differ(again, choice) || again.change_count != 2 {
		return fuzz_broken(.Round_Trip, "a page written with the values that read gave reads as %v", again)
	}
	return FUZZ_PASSED
}

fuzz_kept_settings_seeds :: proc(seeds: ^[dynamic][]u8) {
	// The record of the defaults and of each last value, then the same
	// with the count of the values at its bound and one past it.
	values: [settings.Setting]u32
	for setting in settings.Setting {
		values[setting] = settings.descriptions[setting].value_count - 1
	}
	for record_values, index in ([2][settings.Setting]u32{{}, values}) {
		kept := settings.kept_of(record_values, index == 0 ? 0 : settings.ZONE_OFFSET_MINUTES_MOST)
		append(seeds, slice.clone(mem.ptr_to_bytes(&kept)))
		kept.count = settings.SETTING_CAPACITY
		append(seeds, slice.clone(mem.ptr_to_bytes(&kept)))
		kept.count = settings.SETTING_CAPACITY + 1
		append(seeds, slice.clone(mem.ptr_to_bytes(&kept)))
	}
	// A record of another version, one byte short and one byte long.
	kept := settings.kept_of(values, 0)
	kept.version = settings.KEPT_VERSION + 1
	append(seeds, slice.clone(mem.ptr_to_bytes(&kept)))
	append(seeds, slice.clone(mem.ptr_to_bytes(&kept)[:size_of(kept) - 1]))
	longer := make([]u8, size_of(kept) + 1)
	append(seeds, longer)
	// The texts of the zones at the edges.
	for text in ([?]string{"+00:00", "-00:00", "-12:00", "+14:00", "+14:15", "+05:45", "+08:60"}) {
		append(seeds, slice.clone(transmute([]u8)text))
	}
}

fuzz_kept_settings_regions :: proc(input: []u8, regions: ^[dynamic]Fuzz_Region) {
	if len(input) >= size_of(settings.Kept_Settings) {
		append(regions, Fuzz_Region{offset = 0, type = settings.Kept_Settings, count = 1})
	}
}

// ---------------------------------------------------------------------
// The kept stop reports.

// The places of one table that a generated sequence names: more than the
// table holds, so that a keep takes the place of another one.
@(private = "file")
FUZZ_STOP_REPORT_PRINCIPALS :: 3
@(private = "file")
FUZZ_STOP_REPORT_NAMES :: 6
@(private = "file")
FUZZ_STOP_REPORT_STEPS :: 64

@(private = "file")
Fuzz_Stop_Report_Step :: enum u8 {
	Keep,
	Find,
	Forget,
	Keep_A_Wrong_Name,
}

// The model of a table: the report that the last keep of each principal
// and name gave, if no later keep took its place and no forget freed it.
@(private = "file")
Fuzz_Stop_Report_Model :: struct {
	kept:    [FUZZ_STOP_REPORT_PRINCIPALS][FUZZ_STOP_REPORT_NAMES]bool,
	reports: [FUZZ_STOP_REPORT_PRINCIPALS][FUZZ_STOP_REPORT_NAMES]disk_program.Kept_Stop_Report,
}

// fuzz_stop_report_name gives the nickname of a number: names of one and of
// NAME_LIMIT bytes.
@(private = "file")
fuzz_stop_report_name :: proc(number: int) -> string {
	@(static) long_name: [disk_program.NAME_LIMIT]u8
	if number == FUZZ_STOP_REPORT_NAMES - 1 {
		for &value in long_name {
			value = 'z'
		}
		return string(long_name[:])
	}
	names := [?]string{"a", "b", "c", "agenda", "errors"}
	return names[number]
}

// fuzz_stop_report_of reads a stop report from the choices: a module, a
// frame count up to past its capacity, and words where the hidden values
// can be.
@(private = "file")
fuzz_stop_report_of :: proc(choices: ^Fuzz_Choices) -> (report: op.Stop_Report) {
	report.code = u32(fuzz_choice_word(choices, 2))
	report.vector = u32(fuzz_choice_byte(choices))
	report.module.base = fuzz_choice_word(choices, 8)
	report.module.size = fuzz_choice_word(choices, 4)
	fuzz_choice_fill(choices, report.module.hash[:])
	report.instruction = report.module.base + fuzz_choice_word(choices, 4)
	report.address = fuzz_choice_word(choices, 8)
	report.frame_count = u64(fuzz_choice_below(choices, op.STOP_FRAME_CAPACITY + 3))
	if fuzz_choice_rare(choices, 16) {
		report.frame_count = max(u64)
	}
	for &frame in report.frames {
		frame.base = fuzz_choice_flag(choices) ? report.module.base : fuzz_choice_word(choices, 8)
		frame.address = frame.base + fuzz_choice_word(choices, 2) - u64(fuzz_choice_byte(choices))
	}
	report.program_serial = fuzz_choice_word(choices, 8)
	report.hidden_value_count = u64(fuzz_choice_byte(choices))
	return report
}

// fuzz_stop_report_hidden_check: a hidden report holds no value that a
// module record does not name, and no frame past its count.
@(private = "file")
fuzz_stop_report_hidden_check :: proc(report: ^op.Stop_Report) -> Fuzz_Verdict {
	module := report.module
	in_module := proc(record: op.Module_Record, address: u64) -> bool {
		return record.size != 0 && address >= record.base && address - record.base < record.size
	}
	if report.program_serial != 0 || report.frame_count > op.STOP_FRAME_CAPACITY {
		return fuzz_broken(.Contract, "a hidden report keeps the serial %d and %d frames", report.program_serial, report.frame_count)
	}
	if report.address >= disk_program.FIRST_PAGE_BYTES && !in_module(module, report.address) {
		return fuzz_broken(.Contract, "a hidden report keeps the address %x outside its module", report.address)
	}
	if report.instruction != 0 && !in_module(module, report.instruction) {
		return fuzz_broken(.Contract, "a hidden report keeps the instruction %x outside its module", report.instruction)
	}
	for frame, index in report.frames {
		empty := frame == (op.Stop_Frame{})
		if index >= int(report.frame_count) && !empty {
			return fuzz_broken(.Contract, "a hidden report keeps the frame %d past its count", index)
		}
		if !empty && (frame.base == 0 || frame.address < frame.base) {
			return fuzz_broken(.Contract, "a hidden report keeps the frame %d at %x, of the base %x", index, frame.address, frame.base)
		}
	}
	return FUZZ_PASSED
}

// fuzz_kept_stop_reports_execute runs a generated sequence of keeps, finds
// and forgets on one table beside its model. Each report is hidden first,
// as the root service hides it: a hidden report names no hidden value,
// and hidden again it does not change. A find gives the last report kept,
// or nothing once the table forgot it or gave its place to another; one
// principal never holds more than its share of the places; and a keep with
// a wrong name changes nothing.
fuzz_kept_stop_reports_execute :: proc(input: []u8) -> Fuzz_Verdict {
	choices := fuzz_choices_of(input)
	table: disk_program.Kept_Stop_Reports
	model: Fuzz_Stop_Report_Model
	for _ in 0 ..< fuzz_choice_below(&choices, FUZZ_STOP_REPORT_STEPS + 1) {
		principal := fuzz_choice_below(&choices, FUZZ_STOP_REPORT_PRINCIPALS)
		number := fuzz_choice_below(&choices, FUZZ_STOP_REPORT_NAMES)
		name := fuzz_stop_report_name(number)
		switch Fuzz_Stop_Report_Step(fuzz_choice_below(&choices, len(Fuzz_Stop_Report_Step))) {
		case .Keep:
			report := fuzz_stop_report_of(&choices)
			disk_program.stop_report_hide(&report)
			if verdict := fuzz_stop_report_hidden_check(&report); verdict.oracle != .None {
				return verdict
			}
			hidden_again := report
			disk_program.stop_report_hide(&hidden_again)
			if hidden_again != report {
				return fuzz_broken(.Contract, "a hidden report changes when it is hidden again")
			}
			hash: [disk_program.HASH_SIZE]u8
			fuzz_choice_fill(&choices, hash[:])
			if !disk_program.kept_stop_report_keep(&table, u64(principal), name, hash, &report) {
				return fuzz_broken(.Contract, "kept_stop_report_keep refuses the name %q", name)
			}
			model.kept[principal][number] = true
			model.reports[principal][number] = {module_hash = hash, report = report}
		case .Forget:
			disk_program.kept_stop_report_forget(&table, u64(principal), name)
			model.kept[principal][number] = false
		case .Find:
		case .Keep_A_Wrong_Name:
			before := table
			report := fuzz_stop_report_of(&choices)
			too_long: [disk_program.NAME_LIMIT + 1]u8
			for wrong in ([2]string{"", string(too_long[:])}) {
				if disk_program.kept_stop_report_keep(&table, u64(principal), wrong, {}, &report) {
					return fuzz_broken(.Contract, "kept_stop_report_keep keeps a name of %d bytes", len(wrong))
				}
			}
			if mem.compare(mem.ptr_to_bytes(&before), mem.ptr_to_bytes(&table)) != 0 {
				return fuzz_broken(.Contract, "a refused keep changed the table")
			}
		}
		if verdict := fuzz_stop_reports_model_check(&table, &model); verdict.oracle != .None {
			return verdict
		}
	}
	return FUZZ_PASSED
}

// fuzz_stop_reports_model_check compares the table with its model. A keep
// can take the place of another report, so the model only knows that a
// report it holds is the report of the table, if the table still has one.
@(private = "file")
fuzz_stop_reports_model_check :: proc(table: ^disk_program.Kept_Stop_Reports, model: ^Fuzz_Stop_Report_Model) -> Fuzz_Verdict {
	for principal in 0 ..< FUZZ_STOP_REPORT_PRINCIPALS {
		held := 0
		for number in 0 ..< FUZZ_STOP_REPORT_NAMES {
			found := disk_program.kept_stop_report_find(table, u64(principal), fuzz_stop_report_name(number))
			if found == nil {
				// Its place went to another report: the model forgets it.
				model.kept[principal][number] = false
				continue
			}
			held += 1
			if !model.kept[principal][number] {
				return fuzz_broken(.Model, "the table finds a report of the principal %d that was forgotten or never kept", principal)
			}
			if found^ != model.reports[principal][number] {
				return fuzz_broken(.Model, "the table finds another report than the last one kept")
			}
		}
		if held > disk_program.KEPT_STOP_REPORTS_OF_ONE_PRINCIPAL {
			return fuzz_broken(.Contract, "the principal %d holds %d places", principal, held)
		}
	}
	return FUZZ_PASSED
}
