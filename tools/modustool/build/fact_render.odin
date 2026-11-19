package build

import "base:runtime"
import "modus:contract/blake3"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/text_encoding"
import "core:fmt"
import "core:strings"
import "modustool:foundation"

// The render of the serial line of a log fact on the host
// (src/md/features/log_facts.md, "The serial port"). The kernel writes a
// fact as bytes: "#", the first 8 bytes of the module hash, ":", the fact
// key, and the value bytes up to their last byte that is not zero, in
// hexadecimal (op.log_fact_line). The tool holds each module file that it
// built: it finds the module by the 8 bytes, the fact type by its key, and
// writes the fact template with the values. A line whose module, fact or
// description it does not find stays raw, as a reader with no module file
// shows it.

// The bytes of the module hash that the line of a fact names.
FACT_LINE_HASH_BYTES :: 8

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
// and its hash. It refuses a module whose hash has the first 8 bytes of
// the hash of another one: a line of a fact names a module by them.
fact_catalog_add :: proc(catalog: ^Fact_Catalog, hash: [module.HASH_SIZE]u8, path: string, file: []u8) -> (problem: string) {
	prefix := hash_prefix_of(hash)
	for item in catalog.modules {
		if item.hash == hash {
			return ""
		}
		if hash_prefix_of(item.hash) == prefix {
			return fmt.tprintf("two module files have hashes that start with the same %d bytes, %x: the line of a log fact names its module by them", FACT_LINE_HASH_BYTES, prefix[:])
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
// their first 8 bytes, or a file cannot be read.
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

// fact_catalog_file gives the module file whose hash starts with prefix,
// read one time. nil: no module of the catalog has it.
fact_catalog_file :: proc(catalog: ^Fact_Catalog, prefix: [FACT_LINE_HASH_BYTES]u8) -> []u8 {
	for &item in catalog.modules {
		if hash_prefix_of(item.hash) != prefix {
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

// hash_prefix_of gives the first bytes of a hash, which the line of a fact
// names.
hash_prefix_of :: proc(hash: [module.HASH_SIZE]u8) -> [FACT_LINE_HASH_BYTES]u8 {
	own := hash
	prefix: [FACT_LINE_HASH_BYTES]u8
	copy(prefix[:], own[:FACT_LINE_HASH_BYTES])
	return prefix
}

// The parts of the line of a fact after its head.
Fact_Line :: struct {
	hash_prefix: [FACT_LINE_HASH_BYTES]u8,
	key:         u64,
	values:      [op.LOG_FACT_VALUE_CAPACITY]u8,
	value_count: int, // The value bytes that the line holds: the bytes after them are zero.
}

// fact_line_parse reads the line of a fact after its head, as
// op.log_fact_line writes it: "#", 16 digits, ":", 16 digits, then a space
// and an even count of digits, at most two for each value byte. A digit
// is lower case. ok is false for any other text: it is not a fact.
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
		high := digit(text[place]) or_return
		low := digit(text[place + 1]) or_return
		return high << 4 | low, true
	}
	HEAD :: 1 + 2 * FACT_LINE_HASH_BYTES + 1 + 16
	if len(text) < HEAD || text[0] != '#' || text[1 + 2 * FACT_LINE_HASH_BYTES] != ':' {
		return {}, false
	}
	for index in 0 ..< FACT_LINE_HASH_BYTES {
		line.hash_prefix[index] = byte_at(text, 1 + 2 * index) or_return
	}
	for index in 0 ..< 8 {
		key_byte := byte_at(text, 2 + 2 * FACT_LINE_HASH_BYTES + 2 * index) or_return
		line.key = line.key << 8 | u64(key_byte)
	}
	rest := text[HEAD:]
	if len(rest) == 0 {
		return line, true
	}
	digits := rest[1:]
	if rest[0] != ' ' || len(digits) == 0 || len(digits) % 2 != 0 || len(digits) / 2 > op.LOG_FACT_VALUE_CAPACITY {
		return {}, false
	}
	for index in 0 ..< len(digits) / 2 {
		line.values[index] = byte_at(digits, 2 * index) or_return
	}
	line.value_count = len(digits) / 2
	return line, true
}

// fact_line_render gives the sentence of the line of a fact after its
// head: the fact template of its module file, with the value of each
// field, written by its kind (field_value). rendered is false when the
// text is not the line of a fact, or when the catalog has no module, no
// fact type or no valid description for it: the line stays raw.
fact_line_render :: proc(catalog: ^Fact_Catalog, text: string) -> (sentence: string, rendered: bool) {
	line := fact_line_parse(text) or_return
	file := fact_catalog_file(catalog, line.hash_prefix)
	if file == nil {
		return "", false
	}
	_, fact, description := module.fact_find(file, line.key) or_return
	if line.value_count > int(description.size) || module.fact_template_valid(file, fact, description) != .None {
		return "", false
	}
	values := line.values[:description.size]
	// A Text value is bytes of the writer that nobody checked: the kernel
	// filters no byte of a fact. Its text, up to its first zero byte, takes
	// the rule of the filter of the kernel, so a fact cannot put a line end
	// or an escape sequence in a line that the tool writes.
	for number in 0 ..< description.field_count {
		item, item_ok := module.field(file, description, number)
		if !item_ok || item.type != u8(module.Type.Text) {
			continue
		}
		text_bytes := values[item.offset:][:item.detail]
		end := 0
		for end < len(text_bytes) && text_bytes[end] != 0 {
			end += 1
		}
		text_encoding.invalid_sequences_replace(text_bytes[:end])
	}
	template := module.string_at(file, fact.template_offset, fact.template_count)
	builder := strings.builder_make(context.temp_allocator)
	for at := 0; at < len(template); {
		switch template[at] {
		case '{':
			if template[at + 1] == '{' {
				strings.write_byte(&builder, '{')
				at += 2
				continue
			}
			closing := at + 1 + strings.index_byte(template[at + 1:], '}')
			name := template[at + 1:closing]
			for number in 0 ..< description.field_count {
				item, _ := module.field(file, description, number)
				if module.string_at(file, item.name_offset, item.name_count) == name {
					strings.write_string(&builder, field_value(values, item))
					break
				}
			}
			at = closing + 1
		case '}':
			// fact_template_valid accepts a closing brace only as "}}".
			strings.write_byte(&builder, '}')
			at += 2
		case:
			strings.write_byte(&builder, template[at])
			at += 1
		}
	}
	return strings.to_string(builder), true
}

// The text in a line of the serial port between the head of a process and
// the line of a fact: "] #". A quick search: a log with no fact is
// returned as it is.
FACT_LINE_MARK :: "] #"

// fact_lines_render gives the text of a log with the line of each fact
// rendered: "[name] " then the sentence, and the end of the line as it is,
// and the count of the lines that it rendered. A line that
// fact_line_render does not render stays raw. The same lines give the same
// text, so a place in the text of one read is the same place in the next
// one, and the lines after a place render alone.
fact_lines_render :: proc(catalog: ^Fact_Catalog, text: string) -> (rendered_text: string, fact_lines: int) {
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
				strings.write_string(&builder, body[:mark + 2])
				strings.write_string(&builder, sentence)
				strings.write_string(&builder, line[len(body):])
				fact_lines += 1
				continue
			}
		}
		strings.write_string(&builder, line)
	}
	return strings.to_string(builder), fact_lines
}
