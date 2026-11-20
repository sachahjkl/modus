package build

import "base:runtime"
import "modus:contract/blake3"
import module "modus:contract/module"
import op "modus:contract/operation"
import "core:fmt"
import "core:strings"
import "modustool:foundation"

// The render of the serial line of a log fact on the host
// (src/md/features/log_facts.md, "The serial port"). The kernel writes a
// fact as bytes: "#", the module tag (the first bytes of the module hash),
// ":", the key tag (the high bytes of the fact key), and the value bytes up
// to their last byte that is not zero, with each run of zero bytes as
// letters (op.log_fact_line). The tool holds each module file that it
// built: it finds the module by its tag, the fact type by its key tag, and
// writes the fact template with the values. A line whose module, fact or
// description it does not find stays raw, as a reader with no module file
// shows it.

// The bytes of the module hash that the line of a fact names.
FACT_LINE_MODULE_TAG_BYTES :: op.LOG_FACT_LINE_MODULE_HASH_BYTES

// One module file of a catalog: its hash, and its bytes once a line names it.
Fact_Catalog_Module :: struct {
	hash: [module.HASH_SIZE]u8,
	path: string, // "": the bytes were given, not read.
	file: []u8, // nil until a line names the module.
}

// The module files whose facts the tool renders. Its memory is of its own
// allocator: a machine keeps it across the steps of its test, after the
// temporary memory of each step is freed.
Fact_Catalog :: struct {
	modules:   [dynamic]Fact_Catalog_Module,
	allocator: runtime.Allocator,
}

// fact_catalog_add adds a module to a catalog, by its file or by its path
// and its hash. It refuses a module whose hash has the module tag of the
// hash of another one: a line of a fact names a module by its tag.
fact_catalog_add :: proc(catalog: ^Fact_Catalog, hash: [module.HASH_SIZE]u8, path: string, file: []u8) -> (problem: string) {
	tag := module_tag_of(hash)
	for item in catalog.modules {
		if item.hash == hash {
			return ""
		}
		if module_tag_of(item.hash) == tag {
			return fmt.tprintf("two module files have hashes that start with the same %d bytes, the module tag %x: the line of a log fact names its module by it", FACT_LINE_MODULE_TAG_BYTES, tag[:])
		}
	}
	if catalog.allocator.procedure == nil {
		catalog.allocator = context.allocator
	}
	if catalog.modules == nil {
		catalog.modules = make([dynamic]Fact_Catalog_Module, catalog.allocator)
	}
	append(&catalog.modules, Fact_Catalog_Module{hash = hash, path = strings.clone(path, catalog.allocator), file = file})
	return ""
}

// fact_catalog_of_build gives the catalog of each module file of the
// build, with no file read but for its hash. problem: two hashes share
// their module tag, or a file cannot be read.
fact_catalog_of_build :: proc(allocator: runtime.Allocator) -> (catalog: Fact_Catalog, problem: string) {
	catalog.allocator = allocator
	for build in foundation.module_builds {
		path := foundation.module_path(build.name)
		file, readable := foundation.read_file(path)
		if !readable {
			return catalog, fmt.tprintf("the module file %s cannot be read", path)
		}
		if problem = fact_catalog_add(&catalog, blake3.hash(file), path, nil); problem != "" {
			return catalog, problem
		}
	}
	return catalog, ""
}

// fact_catalog_add_modules adds modules from outside the build to a
// catalog, as the outside modules of a test disk, which run beside the
// modules of the build. problem: the module tag of one of them is the tag
// of another module, so a line of a fact of one would render as a fact of
// the other.
fact_catalog_add_modules :: proc(catalog: ^Fact_Catalog, modules: []Fact_Catalog_Module) -> (problem: string) {
	for item in modules {
		if problem = fact_catalog_add(catalog, item.hash, item.path, item.file); problem != "" {
			return problem
		}
	}
	return ""
}

// outside_module_tags_check refuses outside modules whose module tag is
// the tag of a module of the build or of another of them.
outside_module_tags_check :: proc(modules: []Fact_Catalog_Module) -> (problem: string) {
	catalog, catalog_problem := fact_catalog_of_build(context.temp_allocator)
	if catalog_problem != "" {
		return catalog_problem
	}
	return fact_catalog_add_modules(&catalog, modules)
}

// fact_catalog_file gives the module file whose hash has the module tag
// `tag`, read one time. nil: no module of the catalog has it.
fact_catalog_file :: proc(catalog: ^Fact_Catalog, tag: [FACT_LINE_MODULE_TAG_BYTES]u8) -> []u8 {
	for &item in catalog.modules {
		if module_tag_of(item.hash) != tag {
			continue
		}
		if item.file == nil && item.path != "" {
			file, readable := foundation.read_file(item.path)
			if !readable || blake3.hash(file) != item.hash || module.validate(file) != .None {
				return nil
			}
			item.file = make([]u8, len(file), catalog.allocator)
			copy(item.file, file)
		}
		return item.file
	}
	return nil
}

// fact_catalog_file_of_hash gives the module file whose whole hash is
// hash, read one time. nil: no module of the catalog has it, a module
// whose hash only starts with the same bytes too.
fact_catalog_file_of_hash :: proc(catalog: ^Fact_Catalog, hash: [module.HASH_SIZE]u8) -> []u8 {
	for item in catalog.modules {
		if item.hash == hash {
			return fact_catalog_file(catalog, module_tag_of(hash))
		}
	}
	return nil
}

// module_tag_of gives the module tag of a hash: its first bytes, which the
// line of a fact names.
module_tag_of :: proc(hash: [module.HASH_SIZE]u8) -> [FACT_LINE_MODULE_TAG_BYTES]u8 {
	// A parameter array cannot be sliced: it is copied first.
	own := hash
	tag: [FACT_LINE_MODULE_TAG_BYTES]u8
	copy(tag[:], own[:FACT_LINE_MODULE_TAG_BYTES])
	return tag
}

// The parts of the line of a fact after its head.
Fact_Line :: struct {
	module_tag:  [FACT_LINE_MODULE_TAG_BYTES]u8, // The first bytes of the module hash (docs/glossary/running_code.md, "Module tag").
	key_tag:     u32, // The high bytes of the fact key (op.log_fact_key_tag): one fact type of a module has it.
	values:      [op.LOG_FACT_VALUES_MOST]u8, // Each value byte of the fact, the records of a fact of several records joined.
	value_count: int, // The value bytes that the line holds: the bytes after them are zero.
	part_count:  int, // The records of the fact: 1, or the count after "*".
}

// fact_line_parse reads the line of a fact after its head, as
// op.log_fact_line writes it: "#", the digits of the module tag, ":", the
// digits of the key tag, then a space and the value bytes, each two digits
// or a letter of a run of zero bytes. A digit is lower case. A fact of
// several records has "*" and the digit of its count after the key tag,
// and "/" before the values of each record after the first; each record
// before the last holds op.LOG_FACT_VALUE_CAPACITY bytes, with its last
// zeros cut. ok is false for any other text: it is not a fact. It also
// refuses each text that op.log_fact_line never writes, so one line is one
// fact: a zero byte as two digits, a run that ends the values of a record,
// a letter after a letter that is not the longest run, a space with no
// value after it, a count of 0, 1 or past op.LOG_FACT_RECORDS_MOST, another
// count of "/" than the count of records less one, and a "/" with no count:
// a record whose first record the line lost, which a reader shows raw.
fact_line_parse :: proc(text: string) -> (line: Fact_Line, ok: bool) {
	digit :: proc(character: u8) -> (value: u8, ok: bool) {
		switch character {
		case '0' ..= '9':
			return character - '0', true
		case 'a' ..= 'f':
			return character - 'a' + 10, true
		}
		return 0, false
	}
	byte_at :: proc(text: string, place: int) -> (value: u8, ok: bool) {
		if place + 1 >= len(text) {
			return 0, false
		}
		high := digit(text[place]) or_return
		low := digit(text[place + 1]) or_return
		return high << 4 | low, true
	}
	HASH_DIGITS :: 2 * FACT_LINE_MODULE_TAG_BYTES
	KEY_DIGITS :: 2 * op.LOG_FACT_LINE_KEY_BYTES
	HEAD :: 1 + HASH_DIGITS + 1 + KEY_DIGITS
	if len(text) < HEAD || text[0] != '#' || text[1 + HASH_DIGITS] != ':' {
		return {}, false
	}
	for index in 0 ..< FACT_LINE_MODULE_TAG_BYTES {
		line.module_tag[index] = byte_at(text, 1 + 2 * index) or_return
	}
	for index in 0 ..< op.LOG_FACT_LINE_KEY_BYTES {
		key_byte := byte_at(text, 2 + HASH_DIGITS + 2 * index) or_return
		line.key_tag = line.key_tag << 8 | u32(key_byte)
	}
	rest := text[HEAD:]
	line.part_count = 1
	if len(rest) > 0 && rest[0] == op.LOG_FACT_LINE_PART_COUNT_MARK {
		if len(rest) < 2 || rest[1] < '2' || rest[1] > '0' + u8(op.LOG_FACT_RECORDS_MOST) {
			return {}, false
		}
		line.part_count = int(rest[1] - '0')
		rest = rest[2:]
	}
	// The values of each record: the first after a space, or nothing; each
	// next one after "/".
	part := 0
	if len(rest) > 0 && rest[0] == ' ' {
		if len(rest) == 1 {
			return {}, false
		}
		end := strings.index_byte(rest, op.LOG_FACT_LINE_PART_MARK)
		if end < 0 {
			end = len(rest)
		}
		if end == 1 {
			// A space with no value after it.
			return {}, false
		}
		count := fact_line_values_parse(rest[1:end], line.values[:op.LOG_FACT_VALUE_CAPACITY]) or_return
		line.value_count = count
		rest = rest[end:]
	}
	for len(rest) > 0 {
		if rest[0] != op.LOG_FACT_LINE_PART_MARK {
			return {}, false
		}
		part += 1
		if part >= line.part_count {
			// A "/" with no count, or more records than the count.
			return {}, false
		}
		end := strings.index_byte(rest[1:], op.LOG_FACT_LINE_PART_MARK)
		end = end < 0 ? len(rest) : end + 1
		start := part * op.LOG_FACT_VALUE_CAPACITY
		// The last record of a fact of the most records holds the rest of
		// the bound of the values, less than one record: a record of more
		// is refused, never read past the values.
		count := fact_line_values_parse(rest[1:end], line.values[start:][:min(op.LOG_FACT_VALUE_CAPACITY, len(line.values) - start)]) or_return
		// The records before hold their whole bytes, their last zeros cut.
		line.value_count = count == 0 ? max(line.value_count, start) : start + count
		rest = rest[end:]
	}
	if part != line.part_count - 1 {
		return {}, false
	}
	// A fact of several records holds more than one record: each record
	// before the last is whole.
	if line.part_count > 1 {
		line.value_count = max(line.value_count, (line.part_count - 1) * op.LOG_FACT_VALUE_CAPACITY)
	}
	return line, true
}

// fact_line_values_parse reads the value bytes of one record of the line of
// a fact into values, which are zero: two digits for each byte that is not
// zero, a letter for each run of zero bytes. It gives the count of the bytes
// up to the last one that is not zero, and refuses each text that
// op.log_fact_line never writes.
@(private = "file")
fact_line_values_parse :: proc(encoded: string, values: []u8) -> (count: int, ok: bool) {
	digit :: proc(character: u8) -> (value: u8, ok: bool) {
		switch character {
		case '0' ..= '9':
			return character - '0', true
		case 'a' ..= 'f':
			return character - 'a' + 10, true
		}
		return 0, false
	}
	RUN_LAST :: op.LOG_FACT_LINE_ZERO_RUN_FIRST + u8(op.LOG_FACT_LINE_ZERO_RUN_MOST - 1)
	place := 0
	last_run := 0 // The zero bytes of the letter just before, or 0 after two digits.
	for place < len(encoded) {
		character := encoded[place]
		if character >= op.LOG_FACT_LINE_ZERO_RUN_FIRST && character <= RUN_LAST {
			if last_run != 0 && last_run != op.LOG_FACT_LINE_ZERO_RUN_MOST {
				return 0, false
			}
			last_run = int(character - op.LOG_FACT_LINE_ZERO_RUN_FIRST) + 1
			if count + last_run > len(values) {
				return 0, false
			}
			// The values are zero already.
			count += last_run
			place += 1
			continue
		}
		if place + 1 >= len(encoded) {
			return 0, false
		}
		high := digit(encoded[place]) or_return
		low := digit(encoded[place + 1]) or_return
		value := high << 4 | low
		if value == 0 || count >= len(values) {
			return 0, false
		}
		values[count] = value
		count += 1
		place += 2
		last_run = 0
	}
	if last_run != 0 {
		return 0, false
	}
	return count, true
}

// fact_key_of_tag gives the fact key of a module file whose key tag is
// tag. The build refuses two fact types of one module with one key tag
// (facts_merge), so a tag names one key; a file that holds two, which the
// tool did not build, gives none: a line of it stays raw.
fact_key_of_tag :: proc(file: []u8, tag: u32) -> (key: u64, ok: bool) {
	for row_index in 1 ..< module.count(file, .Facts) {
		row, _, row_ok := module.fact(file, row_index)
		if !row_ok || op.log_fact_key_tag(row.key) != tag {
			continue
		}
		if ok {
			return 0, false
		}
		key, ok = row.key, true
	}
	return key, ok
}

// fact_line_render gives the sentence of the line of a fact after its
// head: the fact template of its module file, with the value of each
// field, written by its kind, by the one render of the contract that the
// readers of the system call too (module.fact_sentence_write). rendered is
// false when the text is not the line of a fact, or when the catalog has no
// module, no fact type or no valid description for it: the line stays raw.
// The line holds the values up to their last byte that is not zero: the
// bytes after them up to the size of the record are zero.
fact_line_render :: proc(catalog: ^Fact_Catalog, text: string) -> (sentence: string, rendered: bool) {
	line := fact_line_parse(text) or_return
	file := fact_catalog_file(catalog, line.module_tag)
	if file == nil {
		return "", false
	}
	key := fact_key_of_tag(file, line.key_tag) or_return
	_, _, description := module.fact_find(file, key) or_return
	most := fact_values_most(file, description)
	if line.value_count > most {
		return "", false
	}
	// The record, and the whole out-of-line area of a record with text
	// views: the bytes after the last one that is not zero are zero, and
	// the last bytes of a text of the area can be zeros that the line cut.
	return fact_values_render(file, key, line.values[:most])
}

// fact_values_render gives the sentence of a fact of a module file from the
// bytes of its record, by the one render of the contract. rendered is false
// when the file has no fact type of the key, when the count of the bytes is
// not the size of its record, or when its template breaks a rule. A step
// Record reads a fact of log.fact_records with it.
fact_values_render :: proc(file: []u8, key: u64, values: []u8) -> (sentence: string, rendered: bool) {
	written: [module.FACT_SENTENCE_BYTES_MOST]u8
	count, _, refusal := module.fact_sentence_write(file, key, values, written[:], nil)
	if refusal != .None {
		return "", false
	}
	return strings.clone(string(written[:count]), context.temp_allocator), true
}

// The text in a line of the serial port between the head of a process and
// the line of a fact: "] #". A quick search: a log with no fact is
// returned as it is.
FACT_LINE_MARK :: "] #"

// A line of a fact that fact_lines_render rendered: its place in the
// rendered text, the process of its head and its fields. A step of a
// machine test waits for a fact by these, not by its sentence: two fact
// types can render one sentence.
Fact_Line_Place :: struct {
	start, end: int, // The bytes of the rendered line, its end of line included, from the start of the text that was rendered.
	raw_count:  int, // The bytes of the raw line that the serial port got, its end of line included: a measure compares them with end - start.
	process:    string, // The name in the head of the line, in the allocator of the list.
	line:       Fact_Line,
}

// fact_lines_render gives the text of a log with the line of each fact
// rendered: "[name] " then the sentence, and the end of the line as it is,
// and the count of the lines that it rendered. A line that
// fact_line_render does not render stays raw. The same lines give the same
// text, so a place in the text of one read is the same place in the next
// one, and the lines after a place render alone. places, when it is not
// nil, receives the place of each rendered line.
fact_lines_render :: proc(catalog: ^Fact_Catalog, text: string, places: ^[dynamic]Fact_Line_Place = nil) -> (rendered_text: string, fact_lines: int) {
	if !strings.contains(text, FACT_LINE_MARK) {
		return text, 0
	}
	builder := strings.builder_make(context.temp_allocator)
	rest := text
	for len(rest) > 0 {
		end := strings.index_byte(rest, '\n')
		line := end < 0 ? rest : rest[:end + 1]
		rest = rest[len(line):]
		body := strings.trim_right(line, "\r\n")
		mark := strings.index(body, FACT_LINE_MARK)
		if mark > 0 && body[0] == '[' && strings.index_byte(body[:mark], ']') < 0 {
			if sentence, rendered := fact_line_render(catalog, body[mark + 2:]); rendered {
				start := strings.builder_len(builder)
				strings.write_string(&builder, body[:mark + 2])
				strings.write_string(&builder, sentence)
				strings.write_string(&builder, line[len(body):])
				fact_lines += 1
				if places != nil {
					// fact_line_render read the same text: it parses.
					parsed, _ := fact_line_parse(body[mark + 2:])
					process := strings.clone(body[1:mark], places.allocator)
					append(places, Fact_Line_Place{start = start, end = strings.builder_len(builder), raw_count = len(line), process = process, line = parsed})
				}
				continue
			}
		}
		strings.write_string(&builder, line)
	}
	return strings.to_string(builder), fact_lines
}
