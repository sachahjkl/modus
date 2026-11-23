package manual

import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/value_kinds"
import "modus:graphics"
import "internal:manual/information"
import "modus:sentence"
import "modus:system"

// The manual is also the service of the information of the modules,
// through functions and with no query language: each export below gives a
// table of records, from the flat
// tables of the modules of the boot image (src/library/internal/manual/information). The
// console combines the tables with where, sort, join and columns.
//
// What runs comes from the kernel: the module records of each process,
// with the replacements that the loader applied. The manual reads them with
// its grant, the machine with the right Inspect, and gives them only to a
// caller that acts for the principal: a process sees no other process.
//
// The window shows the same facts: the key o, or overview(), shows the
// table of all the modules; the page of a module has its sizes, the modules
// that import it, and the processes that run it.

machine: system.Handle

// The rows of the window and of the measures: memory of this process.
module_rows: [128]information.Module
export_rows: [512]information.Export
import_rows: [128]information.Import
running_rows: [512]information.Running

catalog :: proc "contextless" () -> information.Catalog {
	return {image = image, replacements = system.replacements_read(replacement_table, &replacement_records)}
}

// table_count gives the pair of an export with a Table result: the count of
// rows, or an outcome with its error record (src/library/modus/contract/errors):
// Nothing_Has_That_Name with Absent, no module has the name of argument 1;
// Data_Damaged with Damaged, the module of the boot image breaks a rule of
// the format, with the kind of the problem and the byte of the file; or the
// outcome of the kernel refusal of a report, with Refused and the status.
@(private = "file")
table_count :: proc "contextless" (count: int, problem: information.Problem, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	switch problem.kind {
	case .None:
		return .Succeeded, i64(count)
	case .No_Module:
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Modules, 1)
	case .Refused:
		status, refusal := system.status_of_word(u32(problem.value))
		if refusal.kind != 0 {
			return call_outcome.fail(error, .Answer_Unreadable, .Refused, .None, 0, 0, 0, i64(problem.value))
		}
		return call_outcome.fail(error, system.outcome_of_own_status(status), .Refused, .None, 0, 0, 0, i64(problem.value))
	case .Header, .Table, .Segment, .Entry, .Export, .Text, .Function, .Record, .Import_Slot, .Direction, .Enum, .Member_Text:
		// Each of these is a fault of the module file that the boot image holds.
	}
	return call_outcome.fail(error, .Data_Damaged, .Damaged, .None, 1, i64(problem.kind), 0, i64(problem.offset))
}

// modules gives one row for each module of the boot image: its name, its hash, its sizes (code, constants, data, zero), whether it has an entry, its counts of exports, imports and records.
//
// A module that breaks a rule of the format has a row too: `problem`, `place`, `index` and `offset` say where, and
// `problem(name)` gives the sentence. The rows are records [`Module`](information.Module).
//
// **Result**: the count of rows.
@(export, link_name = "modules")
modules :: proc "c" (result: ^[]information.Module) -> i64 {
	return i64(information.modules(catalog(), result^))
}

// exports gives one row for each export of a module, by name or by hash, with its signature and the rights that it asks of its handles.
//
// The module "" gives the exports of each module. The rows are records [`Export`](information.Export).
//
// **Result**: the count of rows, or a failure with its call outcome and an error record:
//
// - `Absent`: no module has this name;
// - `Damaged`: the module breaks a rule of the format: `problem(name)` says where.
@(export, link_name = "exports")
exports :: proc "c" (name: ^string, result: ^[]information.Export, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	count, problem := information.exports(catalog(), name^, result^)
	return table_count(count, problem, error)
}

// imports gives one row for each import of a module, by name or by hash: the hash and the name of the imported module, its import slots, and the module that the replacement table of the machine gives in its place.
//
// The module "" gives the imports of each module. The rows are records [`Import`](information.Import); a
// replacement is explained in [the replacement of an import](docs/MODULE_CONTRACT.md#replacement-of-an-import).
//
// **Result**: the count of rows, or a failure with its call outcome and an error record:
//
// - `Absent`: no module has this name;
// - `Damaged`: the module breaks a rule of the format.
@(export, link_name = "imports")
imports :: proc "c" (name: ^string, result: ^[]information.Import, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	count, problem := information.imports(catalog(), name^, result^)
	return table_count(count, problem, error)
}

// importers gives the imports, in each module of the boot image, of a module, by name or by hash: who imports it.
//
// An import that a replacement of the machine changes to this module is a row too. The rows are records
// [`Import`](information.Import).
//
// **Result**: the count of rows, or a failure with its call outcome and an error record:
//
// - `Absent`: no module has this name.
@(export, link_name = "importers")
importers :: proc "c" (name: ^string, result: ^[]information.Import, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	found, problem := information.find(catalog(), name^)
	if problem.kind == .No_Module {
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Modules, 1)
	}
	return .Succeeded, i64(information.importers(catalog(), found.hash, result^))
}

// exporters gives the exports with a name, in each module of the boot image: which modules export a function with this name.
//
// The rows are records [`Export`](information.Export).
//
// **Result**: the count of rows.
@(export, link_name = "exporters")
exporters :: proc "c" (name: ^string, result: ^[]information.Export) -> i64 {
	return i64(information.exporters(catalog(), name^, result^))
}

// described gives the exports, in each module of the boot image, whose help or documentation holds a text: which modules export a function that does this.
//
// The text is compared with the line of help of the export, which has no Markdown mark, and with its
// documentation text, which keeps the marks of its comment: a word between two marks is found, and two words with
// a mark between them are not. The rows are records [`Export`](information.Export).
//
// **Result**: the count of rows.
@(export, link_name = "described")
described :: proc "c" (words: ^string, result: ^[]information.Export) -> i64 {
	return i64(information.described(catalog(), words^, result^))
}

// handles gives the exports, in each module of the boot image, that take a handle with a right: Read, Write, Control, and the other rights of the kernel.
//
// The name of the right is one of `Right`, as the console writes it. The rows are records
// [`Export`](information.Export).
//
// **Result**: the count of rows, or a failure with its call outcome and an error record:
//
// - `Absent`: no right has this name.
@(export, link_name = "handles")
handles :: proc "c" (right: ^string, result: ^[]information.Export, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	for name, which in sentence.right_names {
		if name == right^ {
			return .Succeeded, i64(information.handles(catalog(), which, result^))
		}
	}
	return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .None, 1)
}

// import_slots gives one row for each import slot of a module, by name or by hash: the import and the export that the loader writes in it.
//
// The rows are records [`Import_Slot`](information.Import_Slot).
//
// **Result**: the count of rows, or a failure with its call outcome and an error record:
//
// - `Absent`: no module has this name;
// - `Damaged`: the module breaks a rule of the format.
@(export, link_name = "import_slots")
import_slots :: proc "c" (name: ^string, result: ^[]information.Import_Slot, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	count, problem := information.import_slots(catalog(), name^, result^)
	return table_count(count, problem, error)
}

// segments gives one row for each segment of a module, by name or by hash: its kind, its place in memory and in the file.
//
// The rows are records [`Segment`](information.Segment).
//
// **Result**: the count of rows, or a failure with its call outcome and an error record:
//
// - `Absent`: no module has this name;
// - `Damaged`: the module breaks a rule of the format.
@(export, link_name = "segments")
segments :: proc "c" (name: ^string, result: ^[]information.Segment, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	count, problem := information.segments(catalog(), name^, result^)
	return table_count(count, problem, error)
}

// running gives one row for each module that runs in a process, from the module records of the kernel: the process, the module, its hash, the hash that a replacement changed, and the writer of the record.
//
// The module records are what each loader asserted with the kernel operation `Process_Module`; the manual reads
// them with `Inspect` and the right **Inspect** on the machine. The rows are records
// [`Running`](information.Running). The field `writer` is `starter` for a record that the starter wrote, which
// the process cannot change, and `process` for a record that the process wrote for itself.
//
// **Result**: the count of rows, or a failure with its call outcome and an error record:
//
// - `No_Grant`: the caller does not act for the principal: a process sees no other process;
// - `Refused`: the kernel refused the report to this process, with its status.
@(export, link_name = "running")
running :: proc "c" (result: ^[]information.Running, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if caller := system.service_caller(); caller != nil && caller.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL == 0 {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	count, problem := information.running(machine, catalog(), result^)
	return table_count(count, problem, error)
}

// edges gives one row for each import edge of each process that runs: the process, a module that runs in it with its hash, the module of the same process that imports it, and the module that a replacement put it in place of.
//
// A module that no module of its process imports, as the module of the process, has one row with `imported_by`
// empty. The rows come from the module records of the kernel and the imports of the files of the boot image:
// the module graph of the build, for what runs now. The rows are records
// [`Edge`](information.Edge).
//
// **Result**: the count of rows, or a failure with its call outcome and an error record:
//
// - `No_Grant`: the caller does not act for the principal;
// - `Refused`: the kernel refused the report to this process, with its status.
@(export, link_name = "edges")
edges :: proc "c" (result: ^[]information.Edge, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if caller := system.service_caller(); caller != nil && caller.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL == 0 {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	count, problem := information.edges(machine, catalog(), result^)
	return table_count(count, problem, error)
}

// replacements gives one row for each record of the replacement table of the machine: where an import names the module `from`, a loader gives the module `to`.
//
// The rows are records [`Replacement`](information.Replacement).
//
// **Result**: the count of rows.
@(export, link_name = "replacements")
replacements :: proc "c" (result: ^[]information.Replacement) -> i64 {
	return i64(information.replacements(catalog(), result^))
}

// problem gives the first rule of the format that a module breaks, by name or by hash, as a sentence: the table, the record and the byte of the file. The text is empty when the module keeps each rule.
//
// **Result**: the count of bytes of the sentence, 0 for a module that keeps each rule, or a failure with its call outcome and an error record:
//
// - `Absent`: no module of the boot image has this name or this hash.
@(export, link_name = "problem")
problem :: proc "c" (name: ^string, result: ^[]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	found, problem := information.find(catalog(), name^)
	if problem.kind == .No_Module {
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Modules, 1)
	}
	if problem.kind == .None {
		return .Succeeded, 0
	}
	buffer: [256]u8
	writer := system.Writer {
		buffer = buffer[:],
	}
	information.problem_write(&writer, found.name != "" ? found.name : name^, problem)
	return text_result(system.written(&writer), result)
}

// overview shows in the window the table of all the modules of the boot image: their sizes, their counts of exports and imports, who imports each one, and the processes that run it. The result is the count of modules.
@(export, link_name = "overview")
overview :: proc "c" () -> i64 {
	navigation_leave()
	return i64(overview_build())
}

// importer_count gives the count of modules that import a module, through
// the replacements of the machine too.
@(private = "file")
importer_count :: proc "contextless" (hash: [32]u8) -> int {
	return information.importers(catalog(), hash, nil)
}

// running_count gives the count of processes that run a module, from the
// rows of running().
@(private = "file")
running_count :: proc "contextless" (hash: string, count: int) -> (processes: int) {
	for &row in running_rows[:min(count, len(running_rows))] {
		processes += int(string(row.hash[:]) == hash)
	}
	return processes
}

// overview_build writes the page of the table of all the modules, and
// writes on the log what it shows.
overview_build :: proc "contextless" () -> int {
	page_clear()
	page_kind = .Overview
	count := min(information.modules(catalog(), module_rows[:]), len(module_rows))
	run_count, _ := information.running(machine, catalog(), running_rows[:])
	heading := system.Writer {
		buffer = built[built_count:],
	}
	system.write_part(&heading, "All the modules (")
	system.write_part(&heading, u64(count))
	system.write_part(&heading, ")")
	built_count += heading.count
	heading_set(system.written(&heading), graphics.colors.text)
	put("The flat tables of each module of the boot image, as the manual reads them.", 0, graphics.colors.dim)
	put("Sizes in bytes of memory. o: this table; up, down: the page of a module.", 0, graphics.colors.dim)
	put("", 0, 0)
	// The column of the names has the width of the longest name of the
	// table: no name is cut, and no name meets the number after it.
	name_width := len("name")
	for &row in module_rows[:count] {
		name_width = max(name_width, len(system.name_of(row.name[:])))
	}
	put_built(0, graphics.colors.dim, padded("name", name_width), " code   const    data    zero  exports imports  by  runs")
	totals: [4]i64
	export_total, import_total, run_total := 0, 0, 0
	for &row in module_rows[:count] {
		name := system.name_of(row.name[:])
		hash, _ := information.hash_parse(string(row.hash[:]))
		by := importer_count(hash)
		runs := running_count(string(row.hash[:]), run_count)
		color := graphics.Color(graphics.colors.text)
		switch {
		case row.problem[0] != 0:
			color = graphics.colors.failed
		case runs > 0:
			color = graphics.colors.process
		case row.entry == 0:
			color = graphics.colors.no_entry
		}
		put_built(0, color, padded(name, name_width), right(row.code, 6), right(row.constants, 8), right(row.data, 8), right(row.zero, 8), right(row.exports, 9), right(row.imports, 8), right(i64(by), 4), right(i64(runs), 6))
		totals += {row.code, row.constants, row.data, row.zero}
		export_total += int(row.exports)
		import_total += int(row.imports)
		run_total += runs
	}
	put("", 0, 0)
	put_built(0, graphics.colors.dim, padded("all", name_width), right(totals[0], 6), right(totals[1], 8), right(totals[2], 8), right(totals[3], 8), right(i64(export_total), 9), right(i64(import_total), 8), "     ", right(i64(run_total), 6))
	put("", 0, 0)
	put("green: a process runs it. yellow: no entry, a library. red: it breaks a rule.", 0, graphics.colors.dim)
	system.log_fact(.Info, Overview_Shown{modules = u64(count), exports = u64(export_total), imports = u64(import_total), running_modules = u64(run_count)})
	return count
}

// padded gives a text, whole, and the spaces after it that make it one
// character wider than `width`, in the built lines. With the built lines
// full, it gives what fits and ends.
@(private = "file")
padded :: proc "contextless" (text: string, width: int) -> string {
	writer := system.Writer {
		buffer = built[built_count:],
	}
	information.padded_write(&writer, text, width)
	built_count += writer.count
	return system.written(&writer)
}

// right gives a number with spaces before it, in a field of `width`
// characters, in the built lines.
@(private = "file")
right :: proc "contextless" (value: i64, width: int) -> string {
	digits: [24]u8
	text := system.format(digits[:], value)
	writer := system.Writer {
		buffer = built[built_count:],
	}
	for _ in len(text) ..< width {
		system.write_part(&writer, " ")
	}
	system.write_part(&writer, text)
	built_count += writer.count
	return system.written(&writer)
}

// information_page writes the facts of one module that the information
// functions give: its sizes, who imports it, and the processes that run it.
information_page :: proc "contextless" (hash: [32]u8) {
	found, problem := information.find(catalog(), hex_of(hash))
	if problem.kind != .None {
		writer := system.Writer {
			buffer = built[built_count:],
		}
		information.problem_write(&writer, found.name, problem)
		built_count += writer.count
		put("PROBLEM", 0, graphics.colors.dim)
		put_paragraph(system.written(&writer), 0, graphics.colors.failed)
		put("", 0, 0)
		return
	}
	row: information.Module
	information.module_row(found, &row)
	put("SIZES", 0, graphics.colors.dim)
	put_built(2, graphics.colors.text, "code ", u64(row.code), ", constants ", u64(row.constants), ", data ", u64(row.data), ", zero data ", u64(row.zero), " bytes")
	put("", 0, 0)
	count := min(information.importers(catalog(), hash, import_rows[:]), len(import_rows))
	put_built(0, graphics.colors.dim, "IMPORTED BY (", u64(count), ")")
	for &item in import_rows[:count] {
		replacement := system.name_of(item.replacement[:])
		module_name := system.name_of(item.module[:])
		if replacement != "" {
			put_built(2, graphics.colors.process, module_name, ", import ", u64(item.number), ", import slots ", u64(item.import_slots), ", through the replacement of ", system.name_of(item.name[:]))
		} else {
			put_built(2, graphics.colors.process, module_name, ", import ", u64(item.number), ", import slots ", u64(item.import_slots))
		}
	}
	put("", 0, 0)
	run_count, _ := information.running(machine, catalog(), running_rows[:])
	text := hex_of(hash)
	processes := running_count(text, run_count)
	put_built(0, graphics.colors.dim, "PROCESSES THAT RUN IT (", u64(processes), ")")
	for &item in running_rows[:min(run_count, len(running_rows))] {
		if string(item.hash[:]) != text {
			continue
		}
		process := system.name_of(item.process[:])
		if item.replaces[0] != 0 {
			replaced, _ := information.hash_parse(string(item.replaces[:]))
			put_built(2, graphics.colors.process, process, " (slot ", u64(item.slot), ") at ", system.Hex(u64(item.base)), ", in place of ", module_text(replaced))
		} else {
			put_built(2, graphics.colors.process, process, " (slot ", u64(item.slot), ") at ", system.Hex(u64(item.base)))
		}
	}
	put("", 0, 0)
}

// hex_of gives a hash in hexadecimal, in the built lines.
@(private = "file")
hex_of :: proc "contextless" (hash: [32]u8) -> string {
	text: [64]u8
	information.hash_text(hash, &text)
	// The built lines can be full: the writer ends the text with the cut
	// mark then.
	writer := system.Writer {
		buffer = built[built_count:],
	}
	system.write_bytes(&writer, text[:])
	result := system.written(&writer)
	built_count += len(result)
	return result
}

// information_start keeps the machine handle and measures the functions:
// the time to list all the modules and all their exports, and the time of
// one reverse question. A measure repeats the work for 50 ms or more, so
// that the clock of 1 ms gives microseconds.
information_start :: proc "contextless" (ctx: ^system.Context) {
	machine = ctx.handles[system.GRANT_MACHINE]
	modules_count, exports_count, rounds := 0, 0, 0
	start := system.time()
	for rounds < 10 || system.time() - start < 50 {
		modules_count = information.modules(catalog(), module_rows[:])
		exports_count, _ = information.exports(catalog(), "", export_rows[:])
		rounds += 1
	}
	list_time := (system.time() - start) * 1000 / u64(rounds)
	question, _ := information.find(catalog(), "calendar")
	importer_total, question_rounds := 0, 0
	start = system.time()
	for question_rounds < 10 || system.time() - start < 50 {
		importer_total = information.importers(catalog(), question.hash, import_rows[:])
		question_rounds += 1
	}
	question_time := (system.time() - start) * 1000 / u64(question_rounds)
	problems := 0
	for &row in module_rows[:min(modules_count, len(module_rows))] {
		problems += int(row.problem[0] != 0)
	}
	system.log_fact(.Info, Information_Measured{modules = u64(modules_count), exports = u64(exports_count), list_time = value_kinds.Time_In_Microseconds(list_time), importers = u64(importer_total), question_time = value_kinds.Time_In_Microseconds(question_time), problems = u64(problems)})
}