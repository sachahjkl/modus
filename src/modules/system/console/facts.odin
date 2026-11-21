package console

import info "modus:contract/boot_info"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "internal:console/console_results"
import "modus:lex_parser"
import "modus:system"
import terminal "modus:terminal"

// The log facts in the console (src/md/features/log_facts.md, "The reader
// path"; src/md/features/log_facts.md, "Filters of a reader: one form").
//
// A log fact is a record with no text: its values and the hash of the
// module whose file describes it. The console holds the boot image, its
// catalog: it finds the module of a fact there, and writes the sentence of
// the fact with module.fact_sentence_write, each value in the color of its
// kind. A fact whose module the image does not hold, a disk process among
// them, shows its raw form, the line of the serial port
// (op.log_fact_line): "#" and the module tag, ":" and the key tag, then
// the value bytes in hexadecimal with each run of zero bytes as a letter.
//
// The command `facts(table, storage.Bad_Block)` gives the fields of one
// fact type as the columns of a table. The fact name is a name that the
// console checks against the fact tables of the image before any call,
// never a text.

// The fact names of the boot image that the console knows: a name past them
// is not offered and not found. Every line of a module is a fact, so the
// image holds about 2000 fact types; the bound keeps room for twice that.
FACT_NAME_CAPACITY :: 4096
FACT_NAME_BYTES :: 64 // The bytes of one fact name, "package.Type": a longer one is not offered and not found.
FACT_MATCH_CAPACITY :: 16 // The modules whose fact table holds one fact name, that facts() reads; more are left out.
FACT_FILE_CAPACITY :: 160 // The module files of the boot image with a fact table that the console keeps; the facts of a module past them show raw.

// The fact names of the boot image: each pair of a package name and a
// record name that a table Facts holds, once. The image does not change
// while the console runs, so the console reads them once, before its
// second thread starts; both threads then only read them.
fact_names: [FACT_NAME_CAPACITY]string
fact_name_count: int
fact_name_bytes: [FACT_NAME_CAPACITY * FACT_NAME_BYTES]u8
fact_name_used: int

// A module file of the image that has a fact table, and its hash.
Fact_File :: struct {
	hash: [32]u8,
	file: []u8,
}

// The module files of the boot image that have a fact table and that the
// checks of the module format took, read once with the fact names. facts()
// and the render read these only, so a file is checked once, never at each
// key or each record. The hash of each file is its entry of the image: the
// boot program hashed each file of the image against the signed system
// description before the kernel ran (src/boot/trust.odin, trust_check,
// which calls system_description.image_check), and the image is granted
// read-only, so the console does not hash a file again.
fact_files: [FACT_FILE_CAPACITY]Fact_File
fact_file_count: int

// One module of the image whose fact table has a row of a fact name.
Fact_Match :: struct {
	hash:        [32]u8,
	file:        []u8,
	key:         u64,
	record:      u32, // The index of the description of the record in the table Records.
	description: module.Record,
}

// The head of each row of facts(): the fields of the row of log.records
// that say which record it is.
FACT_HEAD_COLUMNS :: 4

// facts_start reads the fact names of the boot image and adds the command
// facts.
facts_start :: proc "contextless" () {
	fact_names_read()
	// Gives the facts of one fact type of a table of the rows of
	// `log.records`, one row for each fact: the number, the time, the
	// process and the level of the record, then each field of the fact
	// type, in the order of its record.
	//
	// - `table`: rows of `log.records`, or of a command that keeps their
	//   fields (`where`, `first`, `skip`, `sort`).
	// - `fact`: the name of a fact type, `package.Type`, as a writer
	//   declares it: `log_reader.Fact_Probe`. It is a name, not a text.
	//
	// The console finds each module of the boot image that writes the fact
	// type, and reads the values of the facts through `log.fact_records`.
	// A row of another description of the same fact name is left out. The
	// fields are names of the table: `where` takes them.
	//
	// ```
	// > log.records(0) |> facts(log_reader.Fact_Probe) |> where(probe_number = 7)
	// ```
	//
	// Errors: a name that no fact table of the boot image holds, before any
	// call, with the fact names of its package; a table that is not rows of
	// `log.records`; no connection to the service `log`.
	command("facts", {.Table, .Text}, .Table, "the fields of one fact type of the rows of log.records: facts(t, storage.Bad_Block)", table_facts, forms = {.Expression, .Fact_Name})
}

// fact_names_read reads the fact names of each module of the boot image,
// each once, and keeps each module file with a fact table that
// module.validate takes (fact_files). A module file is hostile input: a
// file that the checks refuse gives no name, and module.fact checks each
// row before it reads it.
fact_names_read :: proc "contextless" () {
	fact_name_count, fact_name_used, fact_file_count = 0, 0, 0
	for &entry in system.image_entries(image) {
		file, ok := fact_image_file(&entry)
		if !ok || module.count(file, .Facts) <= 1 || fact_file_count == FACT_FILE_CAPACITY {
			continue
		}
		if module.validate(file) != .None {
			continue
		}
		fact_files[fact_file_count] = {hash = entry.hash, file = file}
		fact_file_count += 1
		for index in 1 ..< module.count(file, .Facts) {
			row, description, row_ok := module.fact(file, index)
			if !row_ok {
				continue
			}
			package_name := module.string_at(file, row.package_offset, row.package_count)
			type_name := module.string_at(file, description.name_offset, description.name_count)
			fact_name_add(package_name, type_name)
		}
	}
}

// fact_name_add adds the name "package.Type" once.
fact_name_add :: proc "contextless" (package_name, type_name: string) {
	length := len(package_name) + 1 + len(type_name)
	if fact_name_count == FACT_NAME_CAPACITY || length > FACT_NAME_BYTES || length > len(fact_name_bytes) - fact_name_used {
		return
	}
	for name in fact_names[:fact_name_count] {
		if len(name) == length && name[:len(package_name)] == package_name && name[len(package_name)] == '.' && name[len(package_name) + 1:] == type_name {
			return
		}
	}
	start := fact_name_used
	fact_name_used += copy(fact_name_bytes[fact_name_used:], package_name)
	fact_name_bytes[fact_name_used] = '.'
	fact_name_used += 1
	fact_name_used += copy(fact_name_bytes[fact_name_used:], type_name)
	fact_names[fact_name_count] = string(fact_name_bytes[start:fact_name_used])
	fact_name_count += 1
}

// fact_name_known says if a fact name is one of the boot image.
fact_name_known :: proc "contextless" (name: string) -> bool {
	for known in fact_names[:fact_name_count] {
		if known == name {
			return true
		}
	}
	return false
}

// fact_image_file gives the file of an entry of the boot image, inside the
// image.
fact_image_file :: proc "contextless" (entry: ^info.Image_Entry) -> (file: []u8, ok: bool) {
	if entry.offset > u64(len(image)) || entry.size > u64(len(image)) - entry.offset {
		return nil, false
	}
	return image[entry.offset:][:entry.size], true
}

// fact_name_split gives the package name and the record name of a fact
// name: the part before its one dot, and the part after it.
fact_name_split :: proc "contextless" (name: string) -> (package_name, type_name: string, ok: bool) {
	dot := -1
	for index in 0 ..< len(name) {
		if name[index] == '.' {
			if dot >= 0 {
				return "", "", false
			}
			dot = index
		}
	}
	if dot <= 0 || dot == len(name) - 1 {
		return "", "", false
	}
	return name[:dot], name[dot + 1:], true
}

// fact_matches gives each module of the boot image whose table Facts has a
// row of the fact name, in the order of the image, at most len(into). It
// reads the files that fact_names_read checked, and checks none again.
fact_matches :: proc "contextless" (name: string, into: []Fact_Match) -> int {
	package_name, type_name, ok := fact_name_split(name)
	if !ok {
		return 0
	}
	count := 0
	for &kept in fact_files[:fact_file_count] {
		if count == len(into) {
			break
		}
		file := kept.file
		for index in 1 ..< module.count(file, .Facts) {
			row, description, row_ok := module.fact(file, index)
			if !row_ok || module.string_at(file, row.package_offset, row.package_count) != package_name || module.string_at(file, description.name_offset, description.name_count) != type_name {
				continue
			}
			into[count] = {hash = kept.hash, file = file, key = row.key, record = row.record, description = description}
			count += 1
			break
		}
	}
	return count
}

// fact_name_fail fails the line with a name that no fact table holds, and
// the fact names that are close: those of the same package, or each one
// when the package has none.
fact_name_fail :: proc "contextless" (command_name, name: string) -> Value {
	package_name, _, _ := fact_name_split(name)
	start := scratch_count
	same_package := 0
	for known in fact_names[:fact_name_count] {
		known_package, _, _ := fact_name_split(known)
		if package_name != "" && known_package == package_name {
			scratch_text(same_package > 0 ? ", " : "", known)
			same_package += 1
		}
	}
	if same_package == 0 {
		for known, index in fact_names[:fact_name_count] {
			scratch_text(index > 0 ? ", " : "", known)
		}
	}
	close := string(scratch[start:scratch_count])
	switch {
	case fact_name_count == 0:
		return fail(command_name, ": no module of the boot image writes a fact type; \"", name, "\" names nothing")
	case same_package > 0:
		return fail(command_name, ": no fact type has the name ", name, "; the fact types of ", package_name, " are ", close)
	}
	return fail(command_name, ": no fact type has the name ", name, "; the fact types are ", close)
}

// fact_name_evaluate evaluates a Fact_Name node, the argument of a
// parameter of the form Fact_Name: a name with one dot, checked against the
// fact names of the boot image before the command runs.
fact_name_evaluate :: proc "contextless" (command_name: string, fact_name_node: lex_parser.Node_Index) -> Value {
	name := lex_parser.node_text(&line_tree, fact_name_node)
	if lex_parser.node_at(&line_tree, fact_name_node).refusal == .Fact_Name_Missing {
		return fail(command_name, " takes the name of a fact type, as ", command_name, "(t, storage.Bad_Block), not a value")
	}
	if !fact_name_known(name) {
		return fact_name_fail(command_name, name)
	}
	return {kind = .Text, text = name}
}

// ---- The render.

// fact_module_of_hash gives the module file of the boot image with a hash,
// among the checked files with a fact table (fact_files), or nil: a hash
// of zero, a module that the image does not hold, the module of a disk
// process, a module with no fact table, a file that the checks refused. A
// search costs no check of a file and no kernel call: a hash with no
// module costs the same as one with a module.
fact_module_of_hash :: proc "contextless" (hash: [32]u8) -> []u8 {
	zero: [32]u8
	if hash == zero {
		return nil
	}
	for &kept in fact_files[:fact_file_count] {
		if kept.hash == hash {
			return kept.file
		}
	}
	return nil
}

// fact_emit writes one fact on the output line: its sentence with each
// value in the color of its value kind, or its raw form when the boot
// image has no module of the hash or no valid description of the key.
// plain: the style of the text between the values. The caller holds
// output_lock.
fact_emit :: proc "contextless" (hash: [32]u8, key: u64, values: []u8, plain: terminal.Style) {
	sentence: [module.FACT_SENTENCE_BYTES_MOST]u8
	runs: [module.FACT_SENTENCE_RUNS_MOST]value_kinds.Value_Run_In_Call
	if file := fact_module_of_hash(hash); file != nil {
		count, run_count, refusal := module.fact_sentence_write(file, key, values, sentence[:], runs[:])
		if refusal == .None {
			text := string(sentence[:count])
			place := 0
			for run in runs[:run_count] {
				kind, kind_ok := value_kinds.value_kind_of(run.kind)
				start, end := int(run.start), int(run.start) + int(run.length)
				if !kind_ok || start < place || end > len(text) {
					continue
				}
				emit(text[place:start], plain)
				emit(text[start:end], value_kind_style(kind))
				place = end
			}
			emit(text[place:], plain)
			return
		}
	}
	// The raw form is the line of the fact on the serial port: no field
	// name, because the names are in the module file only. A fact of
	// several records is the line of each of its records, joined.
	part_count := op.log_fact_part_count(len(values))
	for part in 0 ..< part_count {
		start := part * op.LOG_FACT_VALUE_CAPACITY
		end := min(len(values), start + op.LOG_FACT_VALUE_CAPACITY)
		fact_part_raw_emit(hash, key, part, part_count, values[start:end], plain, continuation = part > 0)
	}
}

// fact_part_raw_emit writes the raw form of one record of a fact: its part
// of the line of the serial port, after the line of the record before it
// for a continuation.
fact_part_raw_emit :: proc "contextless" (hash: [32]u8, key: u64, part, part_count: int, values: []u8, plain: terminal.Style, continuation := false) {
	fact := op.Log_Fact{module_hash = hash, key = key, value_count = u16(min(len(values), op.LOG_FACT_VALUE_CAPACITY)), part = u8(clamp(part, 0, 255)), part_count = u8(clamp(part_count, 0, 255))}
	copy(fact.values[:], values)
	raw: [op.LOG_FACT_LINE_BYTES_MOST]u8
	emit(string(raw[:op.log_fact_line(&fact, &raw, continuation)]), plain)
}

// ---- facts().

// The fields of a row of log.records that facts() reads.
Log_Row_Fields :: struct {
	number, time, process, level, form: module.Field,
}

// log_row_fields finds the fields of the rows of log.records in a table,
// with their types: a table of other rows fails the line.
log_row_fields :: proc "contextless" (command_name: string, table: Table, detail: u32) -> (fields: Log_Row_Fields, ok: bool) {
	Wanted :: struct {
		name:  string,
		place: ^module.Field,
	}
	wanted := [5]Wanted{{"number", &fields.number}, {"time", &fields.time}, {"process", &fields.process}, {"level", &fields.level}, {"form", &fields.form}}
	for item in wanted {
		found, has := table_field(table, item.name)
		if !has {
			fail(command_name, " takes rows of log.records: the records ", type_text(table.file, .Record, detail), " have no field ", item.name, "; their fields are ", field_names(table))
			return {}, false
		}
		item.place^ = found
	}
	level_enum, level_ok := module.field_contract_enum(fields.level)
	form_enum, form_ok := module.field_contract_enum(fields.form)
	if fields.number.type != u8(module.Type.Integer) || fields.time.type != u8(module.Type.Integer) || fields.process.type != u8(module.Type.Text) || !level_ok || level_enum != .Log_Level || !form_ok || form_enum != .Log_Record_Form {
		fail(command_name, " takes rows of log.records: the fields number, time, process, level and form of ", type_text(table.file, .Record, detail), " are not of their types")
		return {}, false
	}
	return fields, true
}

// facts_columns gives the columns of the table of facts() for a fact type:
// the head (number, time, process, level), then each field of the record
// of the fact type, whose `from` is its offset in the values of a fact.
facts_columns :: proc "contextless" (file: []u8, description: module.Record, columns: ^[COLUMN_CAPACITY]Column) -> (count: int, ok: bool) {
	columns[0] = console_results.integer_column("number")
	columns[1] = console_results.time_column("time", .Microseconds)
	columns[2] = {name = "process", type = .Text, detail = value_kinds.MODULE_NAME_FIELD_BYTES, kind = .Module_Name}
	columns[3] = {name = "level", type = .Integer, detail = 1, unsigned = true, kind = .Status, contract_enum = .Log_Level}
	count = FACT_HEAD_COLUMNS
	for number in 0 ..< description.field_count {
		item := module.field(file, description, number) or_return
		name := module.string_at(file, item.name_offset, item.name_count)
		for head in columns^[:count] {
			// A field of the fact with the name of a field of the head:
			// `where` would not know which of the two values a name means.
			if head.name == name {
				return count, false
			}
		}
		column := console_results.column_of_field(name, item) or_return
		if count == COLUMN_CAPACITY {
			return count, false
		}
		columns[count] = column
		count += 1
	}
	return count, true
}

// facts_description gives the description of the table that facts() gives
// for a fact name: the console checks a condition on it before the run,
// and the completion offers its fields. It goes in buffer, or in the
// memory of the line when buffer is nil. known is false for a name that no
// module of the image writes.
facts_description :: proc "contextless" (name: string, buffer: []u8 = nil) -> (file: []u8, detail: u32, known: bool) {
	matches: [1]Fact_Match
	if fact_matches(name, matches[:]) == 0 {
		return nil, 0, false
	}
	columns: [COLUMN_CAPACITY]Column
	count, columns_ok := facts_columns(matches[0].file, matches[0].description, &columns)
	if !columns_ok {
		return nil, 0, false
	}
	_, type_name, _ := fact_name_split(name)
	if buffer == nil {
		file, _, known = description_make(type_name, columns[:count])
		return file, 1, known
	}
	// description_write writes in zero bytes.
	for &value in buffer {
		value = 0
	}
	file, _, known = console_results.description_write(buffer, type_name, columns[:count])
	return file, 1, known
}

// table_facts gives the facts of one fact type among the rows of a table of
// log.records: see facts_start.
table_facts :: proc "contextless" (arguments: []Value) -> Value {
	name := arguments[1].text
	table, table_ok := table_of(arguments[0])
	if !table_ok {
		return fail("facts: the table has no valid description")
	}
	fields, fields_ok := log_row_fields("facts", table, arguments[0].detail)
	if !fields_ok {
		return {}
	}
	matches: [FACT_MATCH_CAPACITY]Fact_Match
	match_count := fact_matches(name, matches[:])
	if match_count == 0 {
		return fact_name_fail("facts", name)
	}
	first := matches[0]
	columns: [COLUMN_CAPACITY]Column
	column_count, columns_ok := facts_columns(first.file, first.description, &columns)
	if !columns_ok {
		return fail("facts: the fact type ", name, " has a field named as a field of the head, or more fields than a table has columns (", i64(COLUMN_CAPACITY - FACT_HEAD_COLUMNS), ")")
	}
	_, type_name, _ := fact_name_split(name)
	file, size, made := description_make(type_name, columns[:column_count])
	if !made {
		return fail("facts: the rows of ", name, " have ", u64(size), " bytes, the limit is ", u64(module.RECORD_SIZE_LIMIT))
	}
	// The same fact name with another description is another fact type
	// for this table: its rows are left out.
	equal: [FACT_MATCH_CAPACITY]bool
	for &match, index in matches[:match_count] {
		equal[index] = module.records_equal(first.file, first.record, match.file, match.record)
	}
	// The facts of the table, from its least number: the numbers of the
	// rows of a scope grow.
	least := max(i64)
	sorted := true
	for index in 0 ..< table.rows {
		number := module.field_integer(table_row(table, arguments[0], index), fields.number)
		least = min(least, number)
		if index > 0 && number < module.field_integer(table_row(table, arguments[0], index - 1), fields.number) {
			sorted = false
		}
	}
	rows_start := (table_used + 7) &~ 7
	row_count := 0
	if table.rows > 0 {
		if !line_records_connect() {
			return fail("facts: the console has no connection to the service log, which gives the values of the facts")
		}
		after := u64(max(least, 0))
		for _ in 0 ..< FACTS_ANSWERS_MOST {
			answer, total, asked := line_records_ask(line_records.fact_records, line_records.fact_records_export, after)
			if !asked {
				return fail("facts: the service log gave no answer to fact_records")
			}
			answer_table, answer_ok := table_of(answer)
			if !answer_ok || answer_table.rows == 0 {
				break
			}
			fact_fields, fact_fields_ok := fact_row_fields(answer_table)
			if !fact_fields_ok {
				return fail("facts: the rows of log.fact_records do not have the fields of a fact")
			}
			last := after
			for index in 0 ..< answer_table.rows {
				fact_row := table_row(answer_table, answer, index)
				number := module.field_integer(fact_row, fact_fields.number)
				last = max(last, u64(max(number, 0)))
				log_row := facts_log_row(table, arguments[0], fields.number, number, sorted)
				if log_row == nil {
					continue
				}
				key := u64(module.field_integer(fact_row, fact_fields.key))
				hash := module.field_bytes(fact_row, fact_fields.module_hash)
				values := module.field_bytes(fact_row, fact_fields.values)
				value_count := module.field_integer(fact_row, fact_fields.value_count)
				// The first record of a fact holds its whole record of fixed
				// fields; the records after it hold the out-of-line area of
				// its text views, which a row of the table does not carry.
				if module.field_integer(fact_row, fact_fields.part) != 0 {
					continue
				}
				if len(hash) != 32 || values == nil || value_count < i64(first.description.size) || value_count > i64(len(values)) || !module.record_has_text_view(first.file, first.description) && value_count != i64(first.description.size) {
					continue
				}
				kept := false
				for &match, match_index in matches[:match_count] {
					if equal[match_index] && match.key == key && string(match.hash[:]) == string(hash) {
						kept = true
						break
					}
				}
				if !kept {
					continue
				}
				bytes := table_bytes(int(size))
				if bytes == nil || uintptr(raw_data(bytes)) != uintptr(&table_memory[0]) + uintptr(rows_start + row_count * int(size)) {
					return fail("facts: the line has no room for ", i64(row_count + 1), " rows of ", name)
				}
				facts_row_write(bytes, columns[:column_count], fields, log_row, values)
				row_count += 1
			}
			// The rows of the answer reach the last fact of the scope.
			if u64(answer_table.rows) >= total {
				break
			}
			after = last + 1
		}
	}
	rows := table_memory[rows_start:][:row_count * int(size)]
	return {kind = .Table, record = rows, file = file, detail = 1}
}

// The answers of log.fact_records that facts() reads at most: the log
// keeps 2047 records, and an answer holds the rows that the call region
// holds.
FACTS_ANSWERS_MOST :: 64

// The fields of a row of log.fact_records that facts() and the records of
// a line read.
Fact_Row_Fields :: struct {
	number, key, module_hash, value_count, part, part_count, values: module.Field,
}

// fact_row_fields finds the fields of the rows of log.fact_records, with
// their types.
fact_row_fields :: proc "contextless" (table: Table) -> (fields: Fact_Row_Fields, ok: bool) {
	fields.number = table_field(table, "number") or_return
	fields.key = table_field(table, "key") or_return
	fields.module_hash = table_field(table, "module_hash") or_return
	fields.value_count = table_field(table, "value_count") or_return
	fields.part = table_field(table, "part") or_return
	fields.part_count = table_field(table, "part_count") or_return
	fields.values = table_field(table, "values") or_return
	values_kind, values_kind_ok := module.field_kind(fields.values)
	if fields.part.type != u8(module.Type.Integer) || fields.part_count.type != u8(module.Type.Integer) {
		return {}, false
	}
	if fields.number.type != u8(module.Type.Integer) || fields.key.type != u8(module.Type.Integer) || fields.value_count.type != u8(module.Type.Integer) || fields.module_hash.type != u8(module.Type.Bytes) || fields.module_hash.detail != 32 || !values_kind_ok || values_kind != .Fact_Values {
		return {}, false
	}
	return fields, true
}

// facts_log_row gives the row of the table with a number, or nil. A table
// whose numbers grow is searched by halves.
facts_log_row :: proc "contextless" (table: Table, value: Value, number_field: module.Field, number: i64, sorted: bool) -> []u8 {
	if !sorted {
		for index in 0 ..< table.rows {
			row := table_row(table, value, index)
			if module.field_integer(row, number_field) == number {
				return row
			}
		}
		return nil
	}
	low, high := 0, table.rows
	for low < high {
		middle := low + (high - low) / 2
		row := table_row(table, value, middle)
		found := module.field_integer(row, number_field)
		switch {
		case found < number:
			low = middle + 1
		case found > number:
			high = middle
		case:
			return row
		}
	}
	return nil
}

// facts_row_write writes one row of facts(): the head from the row of
// log.records, then each field of the fact from its values.
facts_row_write :: proc "contextless" (row: []u8, columns: []Column, fields: Log_Row_Fields, log_row: []u8, values: []u8) {
	console_results.row_integer_set(row, columns[0], module.field_integer(log_row, fields.number))
	console_results.row_integer_set(row, columns[1], module.field_integer(log_row, fields.time))
	console_results.row_text_set(row, columns[2], module.field_text(log_row, fields.process))
	console_results.row_integer_set(row, columns[3], module.field_integer(log_row, fields.level))
	for column in columns[FACT_HEAD_COLUMNS:] {
		width := module.field_size(console_results.column_field(column))
		if u64(column.from) + u64(width) > u64(len(values)) || u64(column.offset) + u64(width) > u64(len(row)) {
			continue
		}
		copy(row[column.offset:][:width], values[column.from:][:width])
	}
}
