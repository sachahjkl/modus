package build

import module "modus:contract/module"
import op "modus:contract/operation"
import "core:fmt"
import "core:odin/ast"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "modustool:foundation"

// The log facts of a module (src/md/features/log_facts.md, "The fact table
// of the module file"). A fact type is a record type of the package scope
// with the attribute `log_fact`, whose literal is its fact template; a call
// `system.log_fact(level, Type{...})` writes it. The tool reads each such
// call in the sources that the compiler read for the module, describes the
// record type of each one, checks it, and writes the table Facts. It has
// no type checker: the value of a call is a composite literal of a named
// type, or the tool refuses the call.
//
// The refusals, each with its reason:
//   - the value of a call is not a composite literal of a named type: the
//     tool cannot find the type of a variable;
//   - the named type has no attribute log_fact: a reader would have no
//     template;
//   - the attribute is on a declaration that is not a record type of the
//     package scope, or on a type private to its file: the canonical name,
//     and so the key, is then another one;
//   - the template is not a literal of text, or breaks a rule of the
//     template language (module.fact_template_check);
//   - the record has padding: those bytes carry memory of the writer that
//     no field names;
//   - the record has a Handle field: a handle number means nothing to a
//     reader of the log;
//   - the values pass op.LOG_FACT_VALUE_CAPACITY: a fact is one record;
//   - two fact types of the module have one key, or a key is 0;
//   - the LLVM IR of the module does not hold the key of a fact type that
//     a call names: the compiler gives the typeid another value.

// The procedure of the support package system that writes a fact.
LOG_FACT_PROCEDURE_NAME :: "log_fact"

// One fact type that a module writes: one row of the table Facts.
Fact_Description :: struct {
	key:          u64, // The fact key: fact_key(package_name, type_name).
	package_name: string, // The name of the package that declares the record type, after `package`.
	type_name:    string, // The name of the record type.
	template:     string, // The fact template: the literal of the attribute.
	record:       Record_Description, // The description of the record type.
	record_index: u32, // The index of the record in Module_Description.records, from 1: facts_merge sets it.
	file:         string, // Where the source declares the record type.
	line:         int,
}

// A source file that the extraction reads: its path and its text. A test
// gives its sources so; a build reads them from the list of the compiler.
Fact_Source :: struct {
	path:   string,
	source: string,
}

// A package whose record types the extraction reads.
@(private = "file")
Fact_Package :: struct {
	name:  string, // The name after `package`.
	files: [dynamic]^ast.File,
	state: Describe_State,
}

// What the extraction keeps while it reads the sources of one module.
@(private = "file")
Fact_Extraction :: struct {
	given:    map[string][dynamic]Fact_Source, // The sources that the caller gave, by folder. Another folder is read from the disk.
	packages: map[string]^Fact_Package, // Each package read, by folder.
	facts:    [dynamic]Fact_Description,
}

@(private = "file")
fact_fail :: proc(path: string, line: int, format: string, args: ..any) -> bool {
	fmt.eprintf("modustool: log fact %s(%d): ", path, line)
	fmt.eprintfln(format, ..args)
	return false
}

// facts_of_sources gives the fact types that the calls of system.log_fact
// in sources write, each one time, in the order of their first call. A
// type of a folder that sources do not hold is read from the disk. ok is
// false at the first refusal, which it prints.
facts_of_sources :: proc(sources: []Fact_Source) -> (facts: []Fact_Description, ok: bool) {
	context.allocator = context.temp_allocator
	extraction: Fact_Extraction
	extraction.given = make(map[string][dynamic]Fact_Source)
	extraction.packages = make(map[string]^Fact_Package)
	extraction.facts = make([dynamic]Fact_Description)
	for item in sources {
		folder := filepath.dir(item.path)
		if folder not_in extraction.given {
			extraction.given[folder] = make([dynamic]Fact_Source)
		}
		append(&extraction.given[folder], item)
	}
	for item in sources {
		if strings.has_suffix(item.path, "_test.odin") || !strings.contains(item.source, foundation.LOG_FACT_ATTRIBUTE_NAME) {
			continue
		}
		file_facts_read(&extraction, item) or_return
	}
	return extraction.facts[:], true
}

// file_facts_read reads one source: each declaration with the attribute
// log_fact, which must be a record type of the package scope, and each
// call of system.log_fact.
@(private = "file")
file_facts_read :: proc(extraction: ^Fact_Extraction, item: Fact_Source) -> bool {
	state: Describe_State
	file := parse_source(item.path, item.source, &state) or_return
	Walk :: struct {
		extraction: ^Fact_Extraction,
		file:       ^ast.File,
		state:      ^Describe_State,
		failed:     bool,
	}
	walked := Walk{extraction = extraction, file = file, state = &state}
	visit :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
		walk_state := (^Walk)(visitor.data)
		if node == nil || walk_state.failed {
			return nil
		}
		#partial switch found in node.derived {
		case ^ast.Value_Decl:
			if _, has_attribute := fact_attribute(found); has_attribute {
				if !declaration_at_package_scope(walk_state.file, found) {
					walk_state.failed = !fact_fail(walk_state.file.fullpath, found.pos.line, "the attribute %s is on a declaration inside a procedure or a `when`: put it on a record type of the package scope, whose canonical name is <package>::<type>, the fact key", foundation.LOG_FACT_ATTRIBUTE_NAME)
					return nil
				}
				is_struct := false
				if len(found.values) == 1 {
					_, is_struct = found.values[0].derived.(^ast.Struct_Type)
				}
				if !is_struct || found.is_mutable {
					walk_state.failed = !fact_fail(walk_state.file.fullpath, found.pos.line, "the attribute %s is on a declaration that is not a record type: a fact is the values of a record", foundation.LOG_FACT_ATTRIBUTE_NAME)
					return nil
				}
			}
		case ^ast.Call_Expr:
			if !fact_call_read(walk_state.extraction, walk_state.file, walk_state.state, found) {
				walk_state.failed = true
				return nil
			}
		}
		return visitor
	}
	walker := ast.Visitor{visit = visit, data = &walked}
	for declaration in file.decls {
		ast.walk(&walker, declaration)
		if walked.failed {
			return false
		}
	}
	return true
}

// fact_attribute gives the template of a declaration with the attribute
// log_fact: the expression of its value. has_attribute is false for a
// declaration with no such attribute.
@(private = "file")
fact_attribute :: proc(declaration: ^ast.Value_Decl) -> (value: ^ast.Expr, has_attribute: bool) {
	for attribute in declaration.attributes {
		for element in attribute.elems {
			#partial switch item in element.derived {
			case ^ast.Field_Value:
				if field, is_field := item.field.derived.(^ast.Ident); is_field && field.name == foundation.LOG_FACT_ATTRIBUTE_NAME {
					return item.value, true
				}
			case ^ast.Ident:
				if item.name == foundation.LOG_FACT_ATTRIBUTE_NAME {
					return nil, true
				}
			}
		}
	}
	return nil, false
}

// declaration_at_package_scope says if a declaration is one of the
// declarations of the top level of its file.
declaration_at_package_scope :: proc(file: ^ast.File, declaration: ^ast.Value_Decl) -> bool {
	for statement in file.decls {
		if top, is_value := statement.derived.(^ast.Value_Decl); is_value && top == declaration {
			return true
		}
	}
	return false
}

// fact_call_read reads one call: nothing for a call that is not
// system.log_fact; for such a call, the fact type of its value, described
// and checked once for the module.
@(private = "file")
fact_call_read :: proc(extraction: ^Fact_Extraction, file: ^ast.File, state: ^Describe_State, call: ^ast.Call_Expr) -> bool {
	selector, is_selector := call.expr.derived.(^ast.Selector_Expr)
	if !is_selector || selector.field.name != LOG_FACT_PROCEDURE_NAME {
		return true
	}
	library, is_name := selector.expr.derived.(^ast.Ident)
	if !is_name || state.imports[library.name] != foundation.SYSTEM_LIBRARY_FOLDER {
		return true
	}
	path, line := file.fullpath, call.pos.line
	if len(call.args) != 2 {
		return fact_fail(path, line, "system.%s takes two arguments: a level and a composite literal of a fact type, as system.%s(.Warning, Bad_Block{{block = number}})", LOG_FACT_PROCEDURE_NAME, LOG_FACT_PROCEDURE_NAME)
	}
	literal, is_literal := call.args[1].derived.(^ast.Comp_Lit)
	if !is_literal || literal.type == nil {
		return fact_fail(path, line, "the value of system.%s is not a composite literal of a named type: the tool has no type checker and reads the fact type from the literal; write Type{{...}} at the call", LOG_FACT_PROCEDURE_NAME)
	}
	folder, type_name: string
	#partial switch named in literal.type.derived {
	case ^ast.Ident:
		folder, type_name = filepath.dir(path), named.name
	case ^ast.Selector_Expr:
		if package_name, is_package := named.expr.derived.(^ast.Ident); is_package {
			if imported, known := state.imports[package_name.name]; known {
				folder, type_name = imported, named.field.name
			}
		}
	}
	if type_name == "" {
		return fact_fail(path, line, "the value of system.%s is not a literal of a type of this package or of a package of the library: the tool cannot find its declaration", LOG_FACT_PROCEDURE_NAME)
	}
	package_read := fact_package(extraction, folder) or_return
	for known in extraction.facts {
		if known.type_name == type_name && known.package_name == package_read.name {
			return true
		}
	}
	fact := fact_type_describe(package_read, folder, type_name, path, line) or_return
	append(&extraction.facts, fact)
	return true
}

// fact_package gives the package of a folder, read one time: the sources
// that the caller gave for it, or else its files on the disk.
@(private = "file")
fact_package :: proc(extraction: ^Fact_Extraction, folder: string) -> (found: ^Fact_Package, ok: bool) {
	if known, read := extraction.packages[folder]; read {
		return known, true
	}
	found = new(Fact_Package)
	found.files = make([dynamic]^ast.File)
	found.state.records = make([dynamic]Record_Description)
	found.state.structs = make(map[string]Struct_Source)
	sources := make([dynamic]Fact_Source)
	if given, is_given := extraction.given[folder]; is_given {
		append(&sources, ..given[:])
	} else {
		for path in foundation.files_with_suffix(folder, ".odin") or_return {
			if strings.has_suffix(path, "_test.odin") {
				continue
			}
			source := foundation.read_file(path) or_return
			append(&sources, Fact_Source{path = path, source = string(source)})
		}
	}
	for item in sources {
		if strings.has_suffix(item.path, "_test.odin") {
			continue
		}
		file := parse_source(item.path, item.source, &found.state) or_return
		append(&found.files, file)
		found.name = file.pkg_name
	}
	extraction.packages[folder] = found
	return found, true
}

// fact_type_describe finds the declaration of a fact type in its package,
// describes its record, and checks the fact type. call_path and call_line
// name the call, for a refusal that has no declaration.
@(private = "file")
fact_type_describe :: proc(package_read: ^Fact_Package, folder, type_name, call_path: string, call_line: int) -> (fact: Fact_Description, ok: bool) {
	declaration: ^ast.Value_Decl
	declaration_file: ^ast.File
	search: for file in package_read.files {
		for statement in file.decls {
			item, is_value := statement.derived.(^ast.Value_Decl)
			if !is_value || len(item.names) != 1 {
				continue
			}
			if name, is_name := item.names[0].derived.(^ast.Ident); is_name && name.name == type_name {
				declaration, declaration_file = item, file
				break search
			}
		}
	}
	if declaration == nil {
		return {}, fact_fail(call_path, call_line, "the fact type %s is no declaration of the package scope of %s: a type declared inside a procedure or a `when` has another canonical name", type_name, folder)
	}
	path, line := declaration_file.fullpath, declaration.pos.line
	template_expression, has_attribute := fact_attribute(declaration)
	if !has_attribute {
		return {}, fact_fail(call_path, call_line, "system.%s writes %s.%s, which has no attribute %s: write @(%s = \"<the sentence, with each field as {{name}}>\") on the type (%s(%d))", LOG_FACT_PROCEDURE_NAME, package_read.name, type_name, foundation.LOG_FACT_ATTRIBUTE_NAME, foundation.LOG_FACT_ATTRIBUTE_NAME, path, line)
	}
	for attribute in declaration.attributes {
		for element in attribute.elems {
			if item, is_field := element.derived.(^ast.Field_Value); is_field {
				if name, is_name := item.field.derived.(^ast.Ident); is_name && name.name == "private" {
					return {}, fact_fail(path, line, "the fact type %s is private to its file: its canonical name holds the file, so its key is not %s::%s; remove the attribute private", type_name, package_read.name, type_name)
				}
			}
		}
	}
	if len(declaration.values) != 1 {
		return {}, fact_fail(path, line, "the attribute %s is on %s, which is not a record type", foundation.LOG_FACT_ATTRIBUTE_NAME, type_name)
	}
	if _, is_struct := declaration.values[0].derived.(^ast.Struct_Type); !is_struct {
		return {}, fact_fail(path, line, "the attribute %s is on %s, which is not a record type: a fact is the values of a record", foundation.LOG_FACT_ATTRIBUTE_NAME, type_name)
	}
	literal: ^ast.Basic_Lit
	if template_expression != nil {
		literal, _ = template_expression.derived.(^ast.Basic_Lit)
	}
	if literal == nil || literal.tok.kind != .String {
		return {}, fact_fail(path, line, "the template of %s is not a literal of text: the tool reads the literal of the attribute, and no constant or expression", type_name)
	}
	template, _, unquoted := strconv.unquote_string(literal.tok.text)
	if !unquoted {
		return {}, fact_fail(path, line, "the template of %s is not a literal that the tool can read", type_name)
	}
	// A record that struct_record_named refuses printed its refusal.
	number, is_record, record_ok := struct_record_named(&package_read.state, type_name, type_name, false)
	if !is_record {
		return {}, fact_fail(path, line, "the record %s has no description", type_name)
	}
	if !record_ok {
		return {}, false
	}
	record := package_read.state.records[number - 1]
	fact = {
		key          = fact_key(package_read.name, type_name),
		package_name = package_read.name,
		type_name    = type_name,
		template     = template,
		record       = record,
		file         = path,
		line         = line,
	}
	problem := fact_type_problem(fact)
	if problem != "" {
		return {}, fact_fail(path, line, "the fact type %s.%s: %s", package_read.name, type_name, problem)
	}
	return fact, true
}

// fact_type_problem gives why a described fact type is refused, or "":
// the kinds of its fields, its padding, its size and its template.
fact_type_problem :: proc(fact: Fact_Description) -> string {
	names := make([dynamic]string, context.temp_allocator)
	for item in fact.record.fields {
		switch item.type {
		case .Integer, .Text, .Bytes:
		case .Handle:
			return fmt.tprintf("the field %s is a Handle: a handle number means nothing to a reader of the log", item.name)
		case .None, .Record, .Table:
			return fmt.tprintf("the field %s has a type that a record does not hold", item.name)
		}
		append(&names, item.name)
	}
	if problem := record_padding_problem(fact.record); problem != "" {
		return problem
	}
	if fact.record.size > op.LOG_FACT_VALUE_CAPACITY {
		return fmt.tprintf("its values have %d bytes; a fact is one log record, with at most %d bytes of values", fact.record.size, op.LOG_FACT_VALUE_CAPACITY)
	}
	fault, place := module.fact_template_check(fact.template, names[:])
	switch fault {
	case .None:
		return ""
	case .Too_Long:
		return fmt.tprintf("the template has %d bytes; at most %d", len(fact.template), module.FACT_TEMPLATE_BYTES_MOST)
	case .Not_Text:
		return fmt.tprintf("the template is not UTF-8 with no control character, at byte %d", place)
	case .Unclosed_Brace:
		return fmt.tprintf("the brace at byte %d of the template is not closed; write {{{{ for a brace", place)
	case .Lone_Closing_Brace:
		return fmt.tprintf("the brace at byte %d of the template closes nothing; write }}}} for a brace", place)
	case .Not_A_Field_Name:
		return fmt.tprintf("the text in braces at byte %d of the template is not the name of a field: the kind of the field decides the form of its value, so a template holds no format", place)
	case .Unknown_Field:
		return fmt.tprintf("the template names a field at byte %d that the record does not have", place)
	case .Field_Twice:
		return fmt.tprintf("the template names a field two times, at byte %d", place)
	case .Field_Not_Named:
		return fmt.tprintf("the template does not name the field %s: a reader shows each value", names[place])
	case .Too_Many_Fields:
		return fmt.tprintf("the record has more than %d fields", module.FACT_FIELD_CAPACITY)
	}
	return ""
}

// record_padding_problem gives the first run of bytes of a record that no
// field names, as a sentence, or "". The record of a log fact and the
// record of a record stream go into memory that another process reads:
// those bytes would carry memory of the writer.
record_padding_problem :: proc(record: Record_Description) -> string {
	end: u32 = 0
	for item in record.fields {
		if item.offset != end {
			return fmt.tprintf("%d bytes of padding before the field %s: those bytes carry memory of the writer that no field names; order the fields from the largest", item.offset - end, item.name)
		}
		end = item.offset + field_description_size(item)
	}
	if end != record.size {
		return fmt.tprintf("%d bytes of padding after the last field: those bytes carry memory of the writer that no field names", record.size - end)
	}
	return ""
}

// field_description_size gives the bytes of a field of a description.
@(private = "file")
field_description_size :: proc(item: Field_Description) -> u32 {
	switch item.type {
	case .Integer:
		return item.detail == 0 ? 8 : item.detail
	case .Handle:
		return 4
	case .Text, .Bytes:
		return item.detail
	case .None, .Record, .Table:
	}
	return 0
}

// facts_merge adds the fact types of a module to its description: the
// record of each one in the records, where an equal description takes the
// same index, and the facts sorted by key. It refuses a key of 0, two fact
// types with one key, two fact types with one key tag (the first bytes of
// the key, which the serial line of a fact writes: op.log_fact_key_tag),
// and a record of a fact type whose name an export uses with another
// description.
facts_merge :: proc(description: ^Module_Description, facts: []Fact_Description) -> bool {
	records := make([dynamic]Record_Description, context.temp_allocator)
	append(&records, ..description.records)
	merged := make([dynamic]Fact_Description, context.temp_allocator)
	for fact in facts {
		if fact.key == 0 {
			return fact_fail(fact.file, fact.line, "the fact type %s.%s has the key 0, which names no fact type: rename the type", fact.package_name, fact.type_name)
		}
		for other in merged {
			if other.key == fact.key {
				return fact_fail(fact.file, fact.line, "the fact types %s.%s and %s.%s have one fact key, %d: rename one of them", fact.package_name, fact.type_name, other.package_name, other.type_name, fact.key)
			}
			// The serial line of a fact names its key by the key tag
			// alone, so two fact types of one module with one tag would
			// be one fact type for the tool.
			if op.log_fact_key_tag(other.key) == op.log_fact_key_tag(fact.key) {
				return fact_fail(fact.file, fact.line, "the fact types %s.%s and %s.%s have one key tag, %06x, the first %d bytes of their fact keys that the serial line of a fact writes: rename one of them", fact.package_name, fact.type_name, other.package_name, other.type_name, op.log_fact_key_tag(fact.key), op.LOG_FACT_LINE_KEY_BYTES)
			}
		}
		item := fact
		index, added := record_description_add(&records, fact.record)
		if !added {
			return fact_fail(fact.file, fact.line, "the record %s of the fact type %s.%s has another description than the record %s that the module describes already: one module describes a record name one way", fact.record.name, fact.package_name, fact.type_name, fact.record.name)
		}
		item.record_index = index
		append(&merged, item)
	}
	slice.sort_by(merged[:], proc(a, b: Fact_Description) -> bool {return a.key < b.key})
	description.records = records[:]
	description.facts = merged[:]
	return true
}

// record_description_add gives the index, from 1, of a record in the
// records of a module: the index of the record of its name, or a new one
// at the end. ok is false when the module describes that name another way:
// one module describes a record name one way, whichever declaration names
// it (an export, a log fact, a record output, a record input, wiring terms).
record_description_add :: proc(records: ^[dynamic]Record_Description, record: Record_Description) -> (index: u32, ok: bool) {
	for known, known_index in records {
		if known.name != record.name {
			continue
		}
		if !record_descriptions_equal(known, record) {
			return 0, false
		}
		return u32(known_index + 1), true
	}
	append(records, record)
	return u32(len(records)), true
}

// record_descriptions_equal says if two descriptions of a record are the
// same bytes in a module file.
record_descriptions_equal :: proc(a, b: Record_Description) -> bool {
	if a.name != b.name || a.size != b.size || len(a.fields) != len(b.fields) {
		return false
	}
	for field, index in a.fields {
		if field != b.fields[index] {
			return false
		}
	}
	return true
}

// llvm_ir_holds_integer says if the LLVM IR holds the integer value as an
// operand of 64 bits: "i64 " and its decimal digits, signed as the IR
// writes it, with no digit after them.
llvm_ir_holds_integer :: proc(ir: string, value: u64) -> bool {
	needle := fmt.tprintf("i64 %d", i64(value))
	rest := ir
	for {
		at := strings.index(rest, needle)
		if at < 0 {
			return false
		}
		after := at + len(needle)
		if after == len(rest) || rest[after] < '0' || rest[after] > '9' {
			return true
		}
		rest = rest[after:]
	}
}

// facts_ir_problem gives the first fact type whose key the LLVM IR of its
// module does not hold, or "". The key is the typeid that the compiler
// gives the type, an immediate in the code: a new compiler with another
// canonical name or another seed of SipHash gives another number, and each
// reader would then find no description.
facts_ir_problem :: proc(ir: string, facts: []Fact_Description) -> string {
	for fact in facts {
		if !llvm_ir_holds_integer(ir, fact.key) {
			return fmt.tprintf("the LLVM IR holds no immediate %d, the fact key of %s.%s that the tool computed: the compiler gives the typeid another value (a new compiler: its canonical name of a type or its seed of SipHash changed)", i64(fact.key), fact.package_name, fact.type_name)
		}
	}
	return ""
}

// facts_reached gives the fact types of the sources of a module whose key
// the LLVM IR of the module holds: the calls that its compile reached. A
// fact type of a support package whose call no code of the module reaches
// has no record of the module, so it gets no row: the drawing module
// compiles the interface package and never writes its element places. A
// fact type of the package of the module itself (its folder, source) must
// be in the IR: that keeps the check of the key against the compiler for
// each module that writes facts of its own. problem names the first fact
// type that the IR lacks.
facts_reached :: proc(ir: string, facts: []Fact_Description, source: string) -> (reached: []Fact_Description, problem: string) {
	kept := make([dynamic]Fact_Description, context.temp_allocator)
	for fact in facts {
		if llvm_ir_holds_integer(ir, fact.key) {
			append(&kept, fact)
			continue
		}
		if filepath.dir(fact.file) == strings.trim_right(source, "/") {
			return nil, facts_ir_problem(ir, {fact})
		}
	}
	return kept[:], ""
}

// module_reached_facts_file gives the path of the list of the fact keys
// that the compile step of a module reached, one decimal key on each line:
// an output of the compile step, which the conversion reads, so that both
// steps name one set of fact types and a kept compile keeps its list.
module_reached_facts_file :: proc(name: string) -> string {
	return foundation.join(foundation.module_build_folder, "/", name, "/", MODULE_REACHED_FACTS_FILE_NAME)
}

// The names of the two lists that the compile step of a module writes for
// its conversion and for the tests of the build: they hold no path of the
// store and no time, so the test inputs of the check of the flake keep them
// (src/md/infrastructure/full_check.md, "The derivations of the check").
MODULE_REACHED_FACTS_FILE_NAME :: "reached_facts.list"
MODULE_SOURCE_LIST_FILE_NAME :: "sources.list"

// module_source_list_file gives the path of the list of the sources of the
// repository that the compiler read for a module.
module_source_list_file :: proc(name: string) -> string {
	return foundation.join(foundation.module_build_folder, "/", name, "/", MODULE_SOURCE_LIST_FILE_NAME)
}

// module_source_list_text gives the text of the list of the sources of a
// module from the list of its compiler: each Odin source of the repository,
// by its path from the root of the repository, one on each line, sorted,
// each one time. The list of the compiler also names the libraries of the
// compiler by their place in the store, and its order is the order of the
// threads of the compiler: neither enters the list.
module_source_list_text :: proc(compiler_sources: []string) -> string {
	paths := make([dynamic]string, context.temp_allocator)
	for listed_path in compiler_sources {
		path, of_the_repository := source_of_the_repository(listed_path)
		if !of_the_repository || !strings.has_suffix(path, ".odin") || slice.contains(paths[:], path) {
			continue
		}
		append(&paths, path)
	}
	slice.sort(paths[:])
	text := strings.builder_make(context.temp_allocator)
	for path in paths {
		fmt.sbprintfln(&text, "%s", path)
	}
	return strings.to_string(text)
}

// module_source_list_write writes the list of the sources of a module, from
// the list that its compiler just wrote.
module_source_list_write :: proc(name: string) -> bool {
	source_files, _, listed := dependency_list_read(module_dependency_file(name))
	if !listed {
		fmt.eprintfln("modustool: the list of the sources of the compiler of %s cannot be read", name)
		return false
	}
	path := module_source_list_file(name)
	if error := os.write_entire_file(path, module_source_list_text(source_files)); error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", path, error)
		return false
	}
	return true
}

// module_source_list_read reads the list of the sources of a module. It
// refuses a list that cannot be read and an empty line inside the list.
module_source_list_read :: proc(name: string) -> (paths: []string, ok: bool) {
	path := module_source_list_file(name)
	text, readable := foundation.read_text_file_quiet(path)
	if !readable {
		fmt.eprintfln("modustool: the list of the sources of %s, %s, cannot be read", name, path)
		return nil, false
	}
	list := make([dynamic]string, context.temp_allocator)
	lines := strings.split_lines(strings.trim_suffix(text, "\n"), context.temp_allocator)
	for line in lines {
		if line == "" {
			if len(lines) == 1 {
				break
			}
			fmt.eprintfln("modustool: the list of the sources of %s, %s, has an empty line", name, path)
			return nil, false
		}
		append(&list, line)
	}
	return list[:], true
}

// module_reached_facts_write writes the list of the fact keys that the
// compile step of a module reached.
module_reached_facts_write :: proc(name: string, reached: []Fact_Description) -> bool {
	text := strings.builder_make(context.temp_allocator)
	for fact in reached {
		fmt.sbprintfln(&text, "%d", fact.key)
	}
	path := module_reached_facts_file(name)
	if error := os.write_entire_file(path, strings.to_string(text)); error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", path, error)
		return false
	}
	return true
}

// module_facts gives the fact types that a module writes: those of its
// sources whose key the list of its compile step names. The caller gives
// the sources (module_sources), which it also reads for the record streams
// of the module.
module_facts :: proc(build: foundation.Module_Build, sources: []Fact_Source) -> (facts: []Fact_Description, ok: bool) {
	of_sources := facts_of_sources(sources) or_return
	path := module_reached_facts_file(build.name)
	listed, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: log facts of %s: the list of the fact keys of its compile step, %s, cannot be read: %v", build.name, path, read_error)
		return nil, false
	}
	keys := make(map[u64]bool, context.temp_allocator)
	for line in strings.split_lines(string(listed), context.temp_allocator) {
		if line == "" {
			continue
		}
		key, parsed := strconv.parse_u64_of_base(line, 10)
		if !parsed {
			fmt.eprintfln("modustool: log facts of %s: the line \"%s\" of %s is not a fact key", build.name, line, path)
			return nil, false
		}
		keys[key] = true
	}
	kept := make([dynamic]Fact_Description, context.temp_allocator)
	for fact in of_sources {
		if fact.key in keys {
			append(&kept, fact)
		}
	}
	return kept[:], true
}

// module_facts_of_sources gives the fact types of the calls of
// system.log_fact in each source of the repository that the compiler read
// for a module (its list of dependencies), reached by its code or not.
module_facts_of_sources :: proc(build: foundation.Module_Build) -> (facts: []Fact_Description, ok: bool) {
	sources := module_sources(build) or_return
	return facts_of_sources(sources)
}

// module_sources gives each source of the repository that the compiler
// read for a module, with no test file: its source list, which the compile
// step writes with no path of the store. The log facts and the record
// streams of a module come from these sources.
module_sources :: proc(build: foundation.Module_Build) -> (sources: []Fact_Source, ok: bool) {
	source_files, listed := module_source_list_read(build.name)
	if !listed {
		fmt.eprintfln("modustool: the sources of %s: the list of its sources cannot be read", build.name)
		return nil, false
	}
	read_sources := make([dynamic]Fact_Source, context.temp_allocator)
	for path in source_files {
		if strings.has_suffix(path, "_test.odin") {
			continue
		}
		source := foundation.read_file(path) or_return
		append(&read_sources, Fact_Source{path = path, source = string(source)})
	}
	return read_sources[:], true
}
