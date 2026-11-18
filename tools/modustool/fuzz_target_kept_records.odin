package modustool

import "core:mem"
import "core:slice"
import op "modus:contract/operation"
import "modus:contract/settings"
import "modus:support/disk_process"

// The fuzz targets of the records that a process keeps
// (src/md/infrastructure/fuzzing.md, "The targets, in order of value"):
// the record of the settings in the private store of `settings`, with the
// page that it writes and the text of a zone; and the stop reports that the
// root service keeps for the debugger service, from the report that the
// kernel gives.

// ---------------------------------------------------------------------
// The kept settings.

// fuzz_kept_settings_execute reads the input as a kept record, as the text
// of a zone, and as a settings page. The model of a record is read from
// its bytes: a record of this size, magic, version and count is accepted
// only when each value inside its count names a value of its setting; one
// value that names nothing refuses the record whole. A refused record gives
// the defaults; an accepted one gives its values, the default past its
// count, and the valid zone, and kept_of of the choice reads again to the
// same choice. A zone that zone_parse accepts is written and read again to
// the same minutes. A page is read against the same model.
fuzz_kept_settings_execute :: proc(input: []u8) -> Fuzz_Verdict {
	before := slice.clone(input, context.temp_allocator)
	choice, zone, ok := settings.kept_read(input)
	if !slice.equal(before, input) {
		return fuzz_broken(.Contract, "kept_read changed the bytes that it read")
	}
	// The model: what the rule says of these bytes.
	model_ok := len(input) == size_of(settings.Kept_Settings)
	record: settings.Kept_Settings
	model_values: [settings.Setting]u32
	if model_ok {
		copy(mem.ptr_to_bytes(&record), input)
		model_ok = record.magic == settings.KEPT_MAGIC && record.version == settings.KEPT_VERSION && record.count <= settings.SETTING_CAPACITY
	}
	if model_ok {
		for setting in settings.Setting {
			if u32(setting) >= record.count {
				continue // A setting that the record did not hold: its default.
			}
			model_values[setting] = record.values[setting]
			if !settings.value_valid(setting, record.values[setting]) {
				model_ok = false
			}
		}
	}
	if ok != model_ok {
		return fuzz_broken(.Model, "kept_read gives ok %v, and the record has ok %v: a value of no member must refuse the whole record", ok, model_ok)
	}
	if !ok {
		if settings.values_of(choice) != ([settings.Setting]u32{}) || zone != 0 {
			return fuzz_broken(.Contract, "kept_read refuses the record and gives values")
		}
	} else {
		if settings.values_of(choice) != model_values {
			return fuzz_broken(.Model, "kept_read gives the values %v of a record of the values %v", settings.values_of(choice), model_values)
		}
		if zone != settings.zone_offset_minutes_valid(record.zone_offset_minutes) {
			return fuzz_broken(.Contract, "kept_read gives the zone %d of a record of the zone %d", zone, record.zone_offset_minutes)
		}
		kept := settings.kept_of(choice, zone)
		again_choice, again_zone, again_ok := settings.kept_read(mem.ptr_to_bytes(&kept))
		if !again_ok || settings.values_of(again_choice) != settings.values_of(choice) || again_zone != zone {
			return fuzz_broken(.Round_Trip, "the record of kept_of reads as %v, %d, %v", settings.values_of(again_choice), again_zone, again_ok)
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
// A page in a change is refused with the defaults and its count. A stable
// page is accepted only when each value names a value of its setting and
// the word of the appearance in force names one: one word that names
// nothing refuses the whole page, with the defaults and its count. An
// accepted page gives its words as members, and a page written with the
// choice reads again to it.
@(private = "file")
fuzz_settings_page_check :: proc(input: []u8) -> Fuzz_Verdict {
	page: settings.Page
	copy(mem.ptr_to_bytes(&page), input)
	choice, ok := settings.read(&page)
	refused := settings.Choice{change_count = page.change_count}
	if page.change_count & 1 != 0 {
		// A writer that stays in its change: the defaults, with the count.
		if ok || choice != refused {
			return fuzz_broken(.Contract, "read of a page in a change gives %v, ok %v", choice, ok)
		}
		return FUZZ_PASSED
	}
	model_ok := page.appearance_in_force <= u32(max(settings.Appearance_In_Force))
	page_values: [settings.Setting]u32
	for setting in settings.Setting {
		page_values[setting] = page.values[setting]
		if !settings.value_valid(setting, page.values[setting]) {
			model_ok = false
		}
	}
	if ok != model_ok {
		return fuzz_broken(.Model, "read gives ok %v, and the page has ok %v: a word of no member must refuse the whole page", ok, model_ok)
	}
	if !ok {
		if choice != refused {
			return fuzz_broken(.Contract, "read refuses the page and gives %v", choice)
		}
		return FUZZ_PASSED
	}
	if choice.change_count != page.change_count {
		return fuzz_broken(.Contract, "read gives the count %d of a page of the count %d", choice.change_count, page.change_count)
	}
	if settings.values_of(choice) != page_values {
		return fuzz_broken(.Model, "read gives the values %v of a page of the values %v", settings.values_of(choice), page_values)
	}
	if choice.zone_offset_minutes != settings.zone_offset_minutes_valid(page.zone_offset_minutes) || u32(choice.appearance_in_force) != page.appearance_in_force {
		return fuzz_broken(.Contract, "read gives the zone %d and the appearance %d of a page of %d and %d", choice.zone_offset_minutes, u32(choice.appearance_in_force), page.zone_offset_minutes, page.appearance_in_force)
	}
	written: settings.Page
	settings.write(&written, choice, choice.zone_offset_minutes, choice.appearance_in_force)
	again, again_ok := settings.read(&written)
	if !again_ok || settings.values_differ(again, choice) || again.change_count != 2 {
		return fuzz_broken(.Round_Trip, "a page written with the choice that read gave reads as %v, ok %v", again, again_ok)
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
	last, _, last_ok := settings.choice_of_values(values)
	if !last_ok {
		panic("modustool: the last value of a setting names no value of it")
	}
	for record_choice, index in ([2]settings.Choice{{}, last}) {
		kept := settings.kept_of(record_choice, index == 0 ? 0 : settings.ZONE_OFFSET_MINUTES_MOST)
		append(seeds, slice.clone(mem.ptr_to_bytes(&kept)))
		kept.count = settings.SETTING_CAPACITY
		append(seeds, slice.clone(mem.ptr_to_bytes(&kept)))
		kept.count = settings.SETTING_CAPACITY + 1
		append(seeds, slice.clone(mem.ptr_to_bytes(&kept)))
	}
	// A value one past the last value of each setting, which refuses the
	// record whole; then that value past the count of an older record,
	// which the record does not hold.
	for setting in settings.Setting {
		kept := settings.kept_of(last, 0)
		kept.values[setting] = settings.descriptions[setting].value_count
		append(seeds, slice.clone(mem.ptr_to_bytes(&kept)))
		kept.count = u32(setting)
		append(seeds, slice.clone(mem.ptr_to_bytes(&kept)))
	}
	// A record of another version, one byte short and one byte long.
	kept := settings.kept_of(last, 0)
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
	reports: [FUZZ_STOP_REPORT_PRINCIPALS][FUZZ_STOP_REPORT_NAMES]disk_process.Kept_Stop_Report,
}

// fuzz_stop_report_name gives the nickname of a number: names of one and of
// NAME_LIMIT bytes.
@(private = "file")
fuzz_stop_report_name :: proc(number: int) -> string {
	@(static) long_name: [disk_process.NAME_LIMIT]u8
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
	report.process_serial = fuzz_choice_word(choices, 8)
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
	if report.process_serial != 0 || report.frame_count > op.STOP_FRAME_CAPACITY {
		return fuzz_broken(.Contract, "a hidden report keeps the serial %d and %d frames", report.process_serial, report.frame_count)
	}
	if report.address >= disk_process.FIRST_PAGE_BYTES && !in_module(module, report.address) {
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
	table: disk_process.Kept_Stop_Reports
	model: Fuzz_Stop_Report_Model
	for _ in 0 ..< fuzz_choice_below(&choices, FUZZ_STOP_REPORT_STEPS + 1) {
		principal := fuzz_choice_below(&choices, FUZZ_STOP_REPORT_PRINCIPALS)
		number := fuzz_choice_below(&choices, FUZZ_STOP_REPORT_NAMES)
		name := fuzz_stop_report_name(number)
		// Only a keep can take the place of another report.
		eviction_allowed := false
		switch enum_member_at(Fuzz_Stop_Report_Step, fuzz_choice_below(&choices, len(Fuzz_Stop_Report_Step))) {
		case .Keep:
			report := fuzz_stop_report_of(&choices)
			disk_process.stop_report_hide(&report)
			if verdict := fuzz_stop_report_hidden_check(&report); verdict.oracle != .None {
				return verdict
			}
			hidden_again := report
			disk_process.stop_report_hide(&hidden_again)
			if hidden_again != report {
				return fuzz_broken(.Contract, "a hidden report changes when it is hidden again")
			}
			hash: [disk_process.HASH_SIZE]u8
			fuzz_choice_fill(&choices, hash[:])
			if !disk_process.kept_stop_report_keep(&table, u64(principal), name, hash, &report) {
				return fuzz_broken(.Contract, "kept_stop_report_keep refuses the name %q", name)
			}
			model.kept[principal][number] = true
			model.reports[principal][number] = {module_hash = hash, report = report}
			// The report just kept is found at once: a keep never gives
			// away the place that it wrote.
			if found := disk_process.kept_stop_report_find(&table, u64(principal), name); found == nil || found^ != model.reports[principal][number] {
				return fuzz_broken(.Model, "the report just kept for the principal %d is not found as it was kept", principal)
			}
			eviction_allowed = true
		case .Forget:
			disk_process.kept_stop_report_forget(&table, u64(principal), name)
			model.kept[principal][number] = false
		case .Find:
		case .Keep_A_Wrong_Name:
			before := table
			report := fuzz_stop_report_of(&choices)
			too_long: [disk_process.NAME_LIMIT + 1]u8
			for wrong in ([2]string{"", string(too_long[:])}) {
				if disk_process.kept_stop_report_keep(&table, u64(principal), wrong, {}, &report) {
					return fuzz_broken(.Contract, "kept_stop_report_keep keeps a name of %d bytes", len(wrong))
				}
			}
			if mem.compare(mem.ptr_to_bytes(&before), mem.ptr_to_bytes(&table)) != 0 {
				return fuzz_broken(.Contract, "a refused keep changed the table")
			}
		}
		if verdict := fuzz_stop_reports_model_check(&table, &model, eviction_allowed); verdict.oracle != .None {
			return verdict
		}
	}
	return FUZZ_PASSED
}

// fuzz_stop_reports_model_check compares the table with its model. Each
// report of the model is found, with one exception: a keep can take the
// place of one other report, so after a keep (eviction_allowed) at most one
// report of the model is missing, and the model forgets it.
@(private = "file")
fuzz_stop_reports_model_check :: proc(table: ^disk_process.Kept_Stop_Reports, model: ^Fuzz_Stop_Report_Model, eviction_allowed: bool) -> Fuzz_Verdict {
	missing := 0
	for principal in 0 ..< FUZZ_STOP_REPORT_PRINCIPALS {
		held := 0
		for number in 0 ..< FUZZ_STOP_REPORT_NAMES {
			found := disk_process.kept_stop_report_find(table, u64(principal), fuzz_stop_report_name(number))
			if found == nil {
				if model.kept[principal][number] {
					missing += 1
					if !eviction_allowed || missing > 1 {
						return fuzz_broken(.Model, "the table lost a report of the principal %d: %d missing, a keep before: %v", principal, missing, eviction_allowed)
					}
					// Its place went to the report just kept.
					model.kept[principal][number] = false
				}
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
		if held > disk_process.KEPT_STOP_REPORTS_OF_ONE_PRINCIPAL {
			return fuzz_broken(.Contract, "the principal %d holds %d places", principal, held)
		}
	}
	return FUZZ_PASSED
}
