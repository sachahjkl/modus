package build

import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/language_tag"
import "modus:contract/palette_table"
import "modus:contract/text_encoding"
import "modus:contract/value_kinds"
import "core:reflect"
import "core:slice"
import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:strconv"
import "core:strings"
import "modustool:foundation"

// The descriptions of the exports of a module come from its source: the
// description is enough to call a function with no other knowledge of the
// module (docs/MODULE_CONTRACT.md, section 4). This file reads an Odin
// package. An export is a procedure with the attribute @(export).
//
// The rules, which the tool checks:
//   - An export is a function, with the calling convention "c".
//   - A parameter of type i64 is an Integer. A parameter of type ^string is
//     a Text.
//   - A parameter of a type of value_kinds.INTEGER_UNIT_TYPES
//     (value_kinds.Size_In_Pages, value_kinds.Time_In_Milliseconds) is an
//     Integer that counts in that unit: its detail is the integer unit
//     (value_kinds.integer_unit_detail).
//   - A result of type i64 is an Integer. If the last parameter has the type
//     ^[]u8, it is the buffer of a Text result, and the result type is i64.
//   - A parameter of type ^Name is a Record, if Name is a struct of the
//     package, or a struct of a package of the library `modus` that the
//     file imports (^information.Module). A field of
//     the struct has the type i64 (Integer), Lent({...}) (Handle) or [N]u8
//     (Text of N bytes, N a number). The struct has the layout of the C
//     language: no #packed, no #align, no `using`. Its size is at most
//     module.RECORD_SIZE_LIMIT bytes.
//   - If the last parameter has a type ^Name and the name `result`, it is
//     the memory of a Record result. The export has no result type, and
//     the record has no Handle.
//   - If the last parameter has a type ^[]Name and the name `result`, it is
//     the buffer of a Table result of the record Name. The result type is
//     i64, the count of records, and the record has no Handle.
//   - A parameter of type Lent({.Read, .Write}) is a Handle that the caller
//     lends, with the rights that the callee needs (src/library/modus/system).
//   - A parameter of type ^Table_To_Read(Name), ^Table_To_Change(Name) or
//     ^Table_To_Append(Name) is a Table of the record Name with the
//     direction of its name; ^Bytes_To_Read, ^Bytes_To_Change and
//     ^Bytes_To_Append are Bytes (src/library/modus/system, docs/MODULE_CONTRACT.md
//     "Tables and bytes as parameters"). A record of a table has no Handle.
//   - A field of a record can also be an integer of 1, 2 or 4 bytes (u8,
//     i8, u16, i16, u32, i32, u64), or an enum of the package with such a
//     backing type: an Integer field of that size.
//   - A field of a type of value_kinds.FIELD_KIND_TYPES states its field
//     kind: value_kinds.Hexadecimal_8 to Hexadecimal_64 (an unsigned
//     Integer of that size, written in hexadecimal),
//     value_kinds.Module_Name_Field (a Text of the name of a module) and
//     value_kinds.Hash_Field (Bytes of a hash). A field of a contract enum
//     of value_kinds.CONTRACT_ENUM_TYPES (operation.Log_Level) is an
//     unsigned Integer of the kind Status (docs/MODULE_CONTRACT.md, "The
//     kind of a field").
//   - Each parameter has a name.
//   - The comment before the export gives the line of help: its first
//     sentence, without the name of the export.
//   - The export "entry" has one parameter, an address. Its form is fixed by
//     the contract, and its description has no parameter.
//   - The constant MODULE_BUDGET, at most one in the package, is the stated
//     budget of the module: system.Stated_Budget{working_memory_pages = N,
//     processes = N, threads = N, window_width = N, window_height = N}, or
//     MODULE_BUDGET : system.Stated_Budget : {...}; each part an integer
//     literal from 1, decimal or with a prefix 0x, 0o or 0b; a window part
//     also the name of a constant of the package whose value is one integer
//     literal; the parts window_least_width and window_least_height only
//     such names, the same that each call of resizable_set in the package
//     passes as its least size (budget_resizable_check); a part left out 0; a comment before it that gives the
//     reasons; at the top level of a file, alone in its declaration
//     (budget_request_read). The conversion adds the counted parts
//     (budget_count.odin).
// Another type is an error: the tool does not guess a description.

ENTRY_NAME :: "entry"

// describe_package gives the description of the Odin package in a folder:
// the documentation of the module, and the descriptions of its exports. The
// files are in the order of their names, the exports of a file in the order
// of the source. Export n + 1 of the module is exports[n].
// The documentation of the module is the comment before the word `package`,
// in the first file that has one.
describe_package :: proc(folder: string) -> (description: Module_Description, ok: bool) {
	list := make([dynamic]Export_Description, context.temp_allocator)
	state: Describe_State
	state.records = make([dynamic]Record_Description, context.temp_allocator)
	state.structs = make(map[string]Struct_Source, context.temp_allocator)
	files := make([dynamic]^ast.File, context.temp_allocator)
	// The constants of integer literals of all the files: a window part of
	// the stated budget can name a constant of another file.
	integer_constants := make(map[string]u64, context.temp_allocator)
	resizable_calls := make([dynamic]Resizable_Call, context.temp_allocator)
	// The structs of all the files first: an export of one file can use a
	// struct of another file.
	for path in foundation.files_with_suffix(folder, ".odin") or_return {
		if strings.has_suffix(path, "_test.odin") || strings.has_suffix(path, "_wasm64p32.odin") {
			continue
		}
		source := foundation.read_file(path) or_return
		file := parse_source(path, string(source), &state) or_return
		budget_request_read(file, &description.budget) or_return
		integer_constants_read(file, &integer_constants)
		resizable_calls_read(file, &resizable_calls)
		append(&files, file)
		if markdown := markdown_of(file.docs); description.markdown == "" {
			description.markdown = markdown
			description.text = markdown
		}
	}
	budget_window_resolve(&description.budget, integer_constants) or_return
	budget_resizable_check(&description.budget, resizable_calls[:]) or_return
	for file in files {
		describe_file(file, &list, &state) or_return
	}
	description.records = state.records[:]
	description.enums = state.enum_descriptions[:]
	for item, index in list {
		for other in list[:index] {
			if other.name == item.name {
				fmt.eprintfln("modustool: describe %s: two exports have the name %s", folder, item.name)
				return {}, false
			}
		}
	}
	if !enum_getters_resolve(list[:], description.enums) {
		return {}, false
	}
	// The display texts after each export: a table names an enum that an
	// export of any file takes or gives.
	texts := make([dynamic]Member_Text_Description, context.temp_allocator)
	for file in files {
		member_texts_read(file, &state, &texts) or_return
	}
	description.member_texts = member_texts_order(folder, texts[:]) or_return
	palette_rows_fit(folder[strings.last_index_byte(folder, '/') + 1:], list[:], description.enums, description.member_texts) or_return
	description.about = about_of(documentation_text_of_markdown(description.text), "")
	if description.about == "" {
		fmt.eprintfln("modustool: describe %s: no file has a comment before `package`: this comment is the documentation of the module", folder)
		return {}, false
	}
	description.exports = list[:]
	return description, true
}

// A struct of the package, as the source declares it.
Struct_Source :: struct {
	type:   ^ast.Struct_Type,
	path:   string,
	source: string,
	prefix: string, // "package." for a struct of an imported package: the names of its fields are in that package.
}

// An enum of the package or of an imported package, as the source
// declares it.
Enum_Source :: struct {
	base:   string, // The text of its backing type: "u32". "" when the source gives none.
	type:   ^ast.Enum_Type,
	path:   string,
	source: string,
}

// What the tool keeps while it reads a package.
Describe_State :: struct {
	structs: map[string]Struct_Source, // By name; a struct of an imported package by "package.Name".
	imports: map[string]string, // The folder of each package that the files import, by the name that the files use.
	read:    map[string]bool, // The imported packages whose structs are in `structs`.
	enums:   map[string]Enum_Source, // Each enum, by name as `structs`.
	records: [dynamic]Record_Description, // The records that an export uses, each one time.
	enum_descriptions: [dynamic]Enum_Description, // The enums that an export takes or gives, each one time.
	enum_keys:         [dynamic]string, // The key in `enums` of each of enum_descriptions.
}

@(private = "file")
describe_fail :: proc(path: string, node: ^ast.Node, format: string, args: ..any) -> bool {
	fmt.eprintf("modustool: describe %s(%d): ", path, node.pos.line)
	fmt.eprintfln(format, ..args)
	return false
}

@(private = "file")
type_text :: proc(source: string, type: ^ast.Expr) -> string {
	return source[type.pos.offset:type.end.offset]
}

// parse_source reads one source file, and keeps its structs.
parse_source :: proc(path, source: string, state: ^Describe_State) -> (file: ^ast.File, ok: bool) {
	context.allocator = context.temp_allocator
	file = ast.new_from_positions(ast.File, {}, {})
	file.src = source
	file.fullpath = path
	reader := parser.default_parser()
	if !parser.parse_file(&reader, file) {
		fmt.eprintfln("modustool: describe %s: the parser found errors", path)
		return nil, false
	}
	structs_add(file, "", state)
	if state.imports == nil {
		state.imports = make(map[string]string, context.temp_allocator)
	}
	for item in file.imports {
		full := strings.trim(item.fullpath, "\"")
		// The folder lives as long as the description, not as one step.
		folder, in_source_library := foundation.source_library_package_folder(full, context.allocator)
		if !in_source_library {
			continue
		}
		name := item.name.text
		if name == "" {
			name = folder[strings.last_index_byte(folder, '/') + 1:]
		}
		state.imports[name] = folder
	}
	return file, true
}

// structs_add keeps the structs of a parsed file, with the prefix
// "package." for a file of an imported package.
@(private = "file")
structs_add :: proc(file: ^ast.File, prefix: string, state: ^Describe_State) {
	if state.structs == nil {
		state.structs = make(map[string]Struct_Source, context.temp_allocator)
	}
	if state.enums == nil {
		state.enums = make(map[string]Enum_Source, context.temp_allocator)
	}
	for statement in file.decls {
		declaration, is_value := statement.derived.(^ast.Value_Decl)
		if !is_value || len(declaration.names) != 1 || len(declaration.values) != 1 {
			continue
		}
		identifier, has_name := declaration.names[0].derived.(^ast.Ident)
		if !has_name {
			continue
		}
		key := strings.concatenate({prefix, identifier.name}, context.temp_allocator)
		if type, is_struct := declaration.values[0].derived.(^ast.Struct_Type); is_struct {
			state.structs[key] = {type, file.fullpath, file.src, prefix}
		}
		if type, is_enum := declaration.values[0].derived.(^ast.Enum_Type); is_enum {
			base := type.base_type != nil ? type_text(file.src, type.base_type) : ""
			state.enums[key] = {base, type, file.fullpath, file.src}
		}
	}
}

// imported_structs reads the structs of a package that the files import,
// one time.
@(private = "file")
imported_structs :: proc(name: string, state: ^Describe_State) -> bool {
	context.allocator = context.temp_allocator
	if state.read == nil {
		state.read = make(map[string]bool, context.temp_allocator)
	}
	folder, known := state.imports[name]
	if !known || state.read[name] {
		return known
	}
	state.read[name] = true
	for path in foundation.files_with_suffix(folder, ".odin") or_return {
		if strings.has_suffix(path, "_test.odin") || strings.has_suffix(path, "_wasm64p32.odin") {
			continue
		}
		source := foundation.read_file(path) or_return
		file := ast.new_from_positions(ast.File, {}, {})
		file.src = string(source)
		file.fullpath = path
		reader := parser.default_parser()
		if !parser.parse_file(&reader, file) {
			fmt.eprintfln("modustool: describe %s: the parser found errors", path)
			return false
		}
		structs_add(file, strings.concatenate({name, "."}), state)
		// The imports of the package, under "package.name": a type of a
		// field of its structs names a package by the name that its own
		// files use (contract_type_name).
		for item in file.imports {
			full := strings.trim(item.fullpath, "\"")
			imported_folder, in_source_library := foundation.source_library_package_folder(full, context.allocator)
			if !in_source_library {
				continue
			}
			alias := item.name.text
			if alias == "" {
				alias = imported_folder[strings.last_index_byte(imported_folder, '/') + 1:]
			}
			state.imports[strings.concatenate({name, ".", alias})] = imported_folder
		}
	}
	return true
}

// struct_name gives the name of a struct type: "Name", or "package.Name"
// for a struct of an imported package. "" when the type is not a name.
@(private = "file")
struct_name :: proc(state: ^Describe_State, type: ^ast.Expr) -> (key: string, name: string) {
	#partial switch named in type.derived {
	case ^ast.Ident:
		return named.name, named.name
	case ^ast.Selector_Expr:
		library, is_name := named.expr.derived.(^ast.Ident)
		if is_name && imported_structs(library.name, state) {
			return strings.concatenate({library.name, ".", named.field.name}, context.temp_allocator), named.field.name
		}
	}
	return "", ""
}

// imported_package_read reads the structs of a package that the parsed
// files import by a name, one time: their keys are "name.Struct". false
// for a name that the files do not import.
imported_package_read :: proc(state: ^Describe_State, name: string) -> bool {
	return imported_structs(name, state)
}

// is_contract_type says if a type is the type `name` of the contract
// package package_name, through an import of that package under any name.
is_contract_type :: proc(state: ^Describe_State, type: ^ast.Expr, package_name, name: string) -> bool {
	return contract_type_name(state, type, package_name) == name
}

// struct_key_of_type gives the key of a struct in state (struct_record_named)
// from a type name: "Name" for a struct of the package, "package.Name" for
// a struct of an imported package of the library, read at its first use.
// "" when the type names no struct that the tool can read.
struct_key_of_type :: proc(state: ^Describe_State, type: ^ast.Expr) -> string {
	key, _ := struct_name(state, type)
	if _, known := state.structs[key]; !known {
		return ""
	}
	return key
}

// lent_rights reads a type Lent({.Read, .Write}): the rights that the
// callee needs of a handle. is_lent is false for another type.
lent_rights :: proc(type: ^ast.Expr) -> (rights: op.Rights, is_lent, ok: bool) {
	call, is_call := type.derived.(^ast.Call_Expr)
	if !is_call {
		return {}, false, false
	}
	name: string
	#partial switch callee in call.expr.derived {
	case ^ast.Ident:
		name = callee.name
	case ^ast.Selector_Expr:
		name = callee.field.name
	}
	if name != "Lent" {
		return {}, false, false
	}
	if len(call.args) != 1 {
		return {}, true, false
	}
	literal, is_literal := call.args[0].derived.(^ast.Comp_Lit)
	if !is_literal {
		return {}, true, false
	}
	for element in literal.elems {
		selector, is_selector := element.derived.(^ast.Implicit_Selector_Expr)
		if !is_selector {
			return {}, true, false
		}
		right, known := reflect.enum_from_name(op.Right, selector.field.name)
		if !known {
			return {}, true, false
		}
		rights += {right}
	}
	return rights, true, true
}

// record_of gives the number of the description of a struct, from 1. The
// description is made at the first use of the struct. 0: the type is not
// a pointer to a struct of the package.
record_of :: proc(state: ^Describe_State, type: ^ast.Expr, result: bool) -> (number: u32, is_record, ok: bool) {
	pointer, is_pointer := type.derived.(^ast.Pointer_Type)
	if !is_pointer {
		return 0, false, false
	}
	return struct_record(state, pointer.elem, result)
}

// integer_unit_of_parameter reads a type of an Integer parameter, or of an
// Integer field of a record, with a unit: `value_kinds.Size_In_Pages` and the other names of
// value_kinds.INTEGER_UNIT_TYPES, through an import of the contract package
// value_kinds under any name. is_unit is false for another type: a type of
// the same name in another package is not a unit of the contract.
integer_unit_of_parameter :: proc(state: ^Describe_State, type: ^ast.Expr) -> (integer_unit: value_kinds.Integer_Unit, is_unit: bool) {
	name := contract_type_name(state, type, "value_kinds")
	if name == "" {
		return {}, false
	}
	return value_kinds.integer_unit_of_type_name(name)
}

// contract_type_name gives the name of a type `package.Name` of the
// contract package package_name (the folder under src/library/modus/contract),
// through an import of that package under any name. "" for another type: a
// type of the same name in another package is not the type of the
// contract.
//
// prefix is the prefix of the struct whose field has the type ("errors."
// for a struct of an imported package, "" for a struct of the package): a
// struct of the contract package itself names its types with no package,
// as the shape errors.Error_Record_Fact_Fields names Kind_Word.
@(private = "file")
contract_type_name :: proc(state: ^Describe_State, type: ^ast.Expr, package_name: string, prefix := "") -> string {
	contract_folder := strings.concatenate({foundation.active_source_library_public_folder(), "/", foundation.LIBRARY_PART_CONTRACT, "/", package_name}, context.temp_allocator)
	if identifier, is_identifier := type.derived.(^ast.Ident); is_identifier && strings.has_suffix(prefix, ".") {
		if folder, imported := state.imports[prefix[:len(prefix) - 1]]; imported && folder == contract_folder {
			return identifier.name
		}
		return ""
	}
	selector, is_selector := type.derived.(^ast.Selector_Expr)
	if !is_selector {
		return ""
	}
	library, is_name := selector.expr.derived.(^ast.Ident)
	if !is_name {
		return ""
	}
	// A struct of an imported package names a package by the name of the
	// imports of its own files; a struct of the package by the names of
	// the files of the module.
	folder, imported := state.imports[strings.concatenate({prefix, library.name}, context.temp_allocator)]
	if !imported && prefix == "" {
		folder, imported = state.imports[library.name]
	}
	if !imported || folder != contract_folder {
		return ""
	}
	return selector.field.name
}

// field_kind_field reads the type of a field of a record that states a
// field kind: a type of value_kinds.FIELD_KIND_TYPES, or a contract enum of
// value_kinds.CONTRACT_ENUM_TYPES (a Status), by its name or by the name of
// its word type. It gives the field with its type, its kind and its
// detail, and its size and its alignment. is_kind is false for another
// type. prefix is the prefix of the struct of the field (contract_type_name).
@(private = "file")
field_kind_field :: proc(state: ^Describe_State, type: ^ast.Expr, prefix := "") -> (item: Field_Description, size, alignment: u32, is_kind: bool) {
	if row, found := value_kinds.field_kind_of_type_name(contract_type_name(state, type, "value_kinds", prefix)); found {
		// 8 bytes keep the detail 0 of the Integer fields before the sizes.
		integer_detail := row.size == 8 ? 0 : row.size
		switch row.kind {
		case .Hexadecimal, .Hexadecimal_Sixteen_Digits, .Hundredths, .Nanoseconds_As_Microseconds, .Tenths, .Hexadecimal_No_Leading_Zero, .Time_Of_Day:
			return {type = .Integer, detail = integer_detail, unsigned = row.unsigned, kind = row.kind}, row.size, row.size, true
		case .Module_Name:
			return {type = .Text, detail = row.size, kind = .Module_Name}, row.size, 1, true
		case .Hash, .Hash_Head, .Fact_Values, .Log_Body:
			return {type = .Bytes, detail = row.size, kind = row.kind}, row.size, 1, true
		case .Text_View:
			// value_kinds.Text_View starts with its length, a u32: the
			// compiler places it on 4 bytes, and so does the tool.
			return {type = .Bytes, detail = row.size, kind = .Text_View}, row.size, 4, true
		case .Plain, .Status:
			// No type of the table has these kinds: a test of value_kinds
			// checks it.
		}
		return {}, 0, 0, false
	}
	for which in value_kinds.Contract_Enum {
		if which == .None {
			continue
		}
		row := value_kinds.CONTRACT_ENUM_TYPES[which]
		name := contract_type_name(state, type, row.package_name, prefix)
		enum_field_size: u32
		switch {
		case name == "":
			continue
		case name == row.name:
			enum_field_size = module.CONTRACT_ENUM_SIZES[which]
		case row.word_name != "" && name == row.word_name:
			// The word type holds the word whole, at its own size: a
			// status of 8 bytes beside fields of 8 bytes leaves no padding.
			enum_field_size = module.CONTRACT_ENUM_WORD_SIZES[which]
		case:
			continue
		}
		return {type = .Integer, detail = enum_field_size == 8 ? 0 : enum_field_size, unsigned = true, kind = .Status, contract_enum = which}, enum_field_size, enum_field_size, true
	}
	return {}, 0, 0, false
}

// table_of gives the number of the description of the record of a Table
// result: the type is ^[]Name. is_table is false for another type.
table_of :: proc(state: ^Describe_State, type: ^ast.Expr) -> (number: u32, is_table, ok: bool) {
	pointer, is_pointer := type.derived.(^ast.Pointer_Type)
	if !is_pointer {
		return 0, false, false
	}
	slice, is_slice := pointer.elem.derived.(^ast.Array_Type)
	if !is_slice || slice.len != nil {
		return 0, false, false
	}
	return struct_record(state, slice.elem, true)
}

// table_parameter reads a type ^Table_To_Read(Name) and its forms, or
// ^Bytes_To_Read and its forms. is_table is false for another type.
table_parameter :: proc(state: ^Describe_State, type: ^ast.Expr) -> (kind: module.Type, number: u32, direction: module.Direction, is_table, ok: bool) {
	pointer, is_pointer := type.derived.(^ast.Pointer_Type)
	if !is_pointer {
		return
	}
	name_of :: proc(expression: ^ast.Expr) -> string {
		#partial switch named in expression.derived {
		case ^ast.Ident:
			return named.name
		case ^ast.Selector_Expr:
			return named.field.name
		}
		return ""
	}
	@(static, rodata)
	forms := [3]string{"Read", "Change", "Append"}
	if call, is_call := pointer.elem.derived.(^ast.Call_Expr); is_call {
		name := name_of(call.expr)
		for form, value in forms {
			if name != strings.concatenate({"Table_To_", form}, context.temp_allocator) {
				continue
			}
			if len(call.args) != 1 {
				return .Table, 0, foundation.enum_member_at(module.Direction, value), true, false
			}
			record, is_record, record_ok := struct_record(state, call.args[0], true)
			return .Table, record, foundation.enum_member_at(module.Direction, value), true, is_record && record_ok
		}
		return
	}
	name := name_of(pointer.elem)
	for form, value in forms {
		if name == strings.concatenate({"Bytes_To_", form}, context.temp_allocator) {
			return .Bytes, 0, foundation.enum_member_at(module.Direction, value), true, true
		}
	}
	return
}

// integer_size reads the type of an Integer field: i64 and u64 (8 bytes),
// i32, u32, i16, u16, i8, u8, or an enum with one of them as its backing
// type. size is 0 for another type.
@(private = "file")
integer_size :: proc(state: ^Describe_State, prefix, text: string) -> (size: u32, unsigned: bool) {
	switch text {
	case "i64":
		return 8, false
	case "u64":
		return 8, true
	case "i32":
		return 4, false
	case "u32":
		return 4, true
	case "i16":
		return 2, false
	case "u16":
		return 2, true
	case "i8":
		return 1, false
	case "u8":
		return 1, true
	}
	if found, is_enum := state.enums[strings.concatenate({prefix, text}, context.temp_allocator)]; is_enum && found.base != "" {
		return integer_size(state, prefix, found.base)
	}
	if found, is_enum := state.enums[text]; is_enum && found.base != "" {
		return integer_size(state, "", found.base)
	}
	return 0, false
}

// enum_of gives the number of the description of an enum of the package,
// or of an imported package of the library, from 1: the type of an Enum
// parameter or of an Enum result. The description is made at the first use
// of the enum: its name, its size and sign from its backing type, and each
// member in lower case with its value. is_enum is false for a type that is
// no enum that the tool knows; ok is false for an enum that the format
// cannot describe, with a line that says why.
enum_of :: proc(state: ^Describe_State, type: ^ast.Expr) -> (number: u32, is_enum, ok: bool) {
	key, name := struct_name(state, type)
	found, known := state.enums[key]
	if key == "" || !known {
		return 0, false, false
	}
	for item, index in state.enum_keys {
		if item == key {
			return u32(index + 1), true, true
		}
	}
	size, unsigned := integer_size(state, "", found.base)
	if found.base == "" || size == 0 {
		return 0, true, describe_fail(found.path, found.type, "the enum %s has no backing type of 1, 2, 4 or 8 bytes: write enum u32 {{...}}", name)
	}
	members := make([dynamic]Member_Description, context.temp_allocator)
	next := i64(0)
	for item in found.type.fields {
		member_name: string
		value_expression: ^ast.Expr
		#partial switch field in item.derived {
		case ^ast.Ident:
			member_name = field.name
		case ^ast.Field_Value:
			identifier, is_identifier := field.field.derived.(^ast.Ident)
			if !is_identifier {
				return 0, true, describe_fail(found.path, item, "the enum %s: a member is a name, with a value or none", name)
			}
			member_name, value_expression = identifier.name, field.value
		case:
			return 0, true, describe_fail(found.path, item, "the enum %s: a member is a name, with a value or none", name)
		}
		if value_expression != nil {
			negative := false
			if unary, is_unary := value_expression.derived.(^ast.Unary_Expr); is_unary && unary.op.kind == .Sub {
				negative, value_expression = true, unary.expr
			}
			literal, is_literal := value_expression.derived.(^ast.Basic_Lit)
			if !is_literal {
				return 0, true, describe_fail(found.path, item, "the enum %s: the value of %s is an integer literal: the module file holds each value, and the tool evaluates no expression", name, member_name)
			}
			value, readable := integer_literal_value(literal)
			if !readable || negative && value > u64(max(i64)) + 1 {
				return 0, true, describe_fail(found.path, item, "the enum %s: the value of %s is not an integer of 64 bits", name, member_name)
			}
			next = negative ? -i64(value) : i64(value)
		}
		lower := strings.to_lower(member_name, context.temp_allocator)
		if !module.enum_member_name_valid(lower) {
			return 0, true, describe_fail(found.path, item, "the enum %s: the member %s has no name that a line can write: in lower case, a letter, then letters, digits and _, %d bytes at most", name, member_name, module.ENUM_MEMBER_NAME_CAPACITY)
		}
		append(&members, Member_Description{name = lower, value = next})
		next += 1
	}
	described := Enum_Description{name = name, size = u8(size), unsigned = unsigned, members = members[:]}
	// The rules of the reader, here with a sentence: a value that the size
	// does not hold, the absent word, a name or a value given twice.
	if len(members) == 0 || len(members) > module.ENUM_MEMBER_CAPACITY {
		return 0, true, describe_fail(found.path, found.type, "the enum %s has %d members: an enum parameter has 1 to %d", name, len(members), module.ENUM_MEMBER_CAPACITY)
	}
	absent := module.enum_absent_word({size = described.size, unsigned = unsigned})
	for member, index in members {
		if !module.enum_value_fits(described.size, unsigned, member.value) || member.value == absent {
			return 0, true, describe_fail(found.path, found.type, "the enum %s: the value %d of %s is past its backing type, or is the word of each bit set, which says that a call leaves the parameter out", name, member.value, member.name)
		}
		for other in members[:index] {
			if other.name == member.name || other.value == member.value {
				return 0, true, describe_fail(found.path, found.type, "the enum %s: %s and %s have one name or one value: a line names a member, and a call carries its value", name, other.name, member.name)
			}
		}
	}
	append(&state.enum_descriptions, described)
	append(&state.enum_keys, key)
	return u32(len(state.enum_descriptions)), true, true
}

// text_size reads a type [N]u8: a Text field of N bytes. is_text is false
// for another type.
@(private = "file")
text_size :: proc(type: ^ast.Expr) -> (size: u32, is_text, ok: bool) {
	array, is_array := type.derived.(^ast.Array_Type)
	if !is_array || array.len == nil {
		return 0, false, false
	}
	element, is_name := array.elem.derived.(^ast.Ident)
	if !is_name || element.name != "u8" {
		return 0, false, false
	}
	count, is_literal := array.len.derived.(^ast.Basic_Lit)
	if !is_literal {
		return 0, true, false
	}
	value, parsed := strconv.parse_u64_of_base(count.tok.text, 10)
	if !parsed || value == 0 || value > module.RECORD_SIZE_LIMIT {
		return 0, true, false
	}
	return u32(value), true, true
}

// struct_record gives the number of the description of a struct, by its
// type name. 0 and is_record false: the name is no struct that the tool
// knows. The extraction of a record output and a record input reads its
// record so.
struct_record :: proc(state: ^Describe_State, type: ^ast.Expr, result: bool) -> (number: u32, is_record, ok: bool) {
	key, record_name := struct_name(state, type)
	return struct_record_named(state, key, record_name, result)
}

// struct_record_named gives the number of the description of the struct
// that state names by key ("Name", or "package.Name"), with the name
// record_name. 0 and is_record false: the key names no struct that the
// tool knows. The extraction of a fact type reads its record so, with
// no_field_taken: a fact type with no field is a record of 0 bytes, whose
// sentence is its template. Another record has a field: a call carries
// values.
struct_record_named :: proc(state: ^Describe_State, key, record_name: string, result: bool, no_field_taken := false) -> (number: u32, is_record, ok: bool) {
	found, has_struct := state.structs[key]
	if key == "" || !has_struct {
		return 0, false, false
	}
	declared := found.type
	if declared.is_packed || declared.is_raw_union || declared.align != nil || declared.poly_params != nil {
		return 0, true, describe_fail(found.path, declared, "the record %s must have the layout of the C language: no #packed, no #align, no parameter", record_name)
	}
	has_no_field := declared.fields == nil || len(declared.fields.list) == 0
	if has_no_field && !no_field_taken {
		return 0, true, describe_fail(found.path, declared, "the record %s must have fields: a parameter or a result of a call carries values; only a log fact can have none", record_name)
	}
	fields := make([dynamic]Field_Description, context.temp_allocator)
	size, alignment: u32 = 0, 1
	has_handle := false
	field_list: []^ast.Field
	if !has_no_field {
		field_list = declared.fields.list
	}
	for field in field_list {
		if field.type == nil || .Using in field.flags {
			return 0, true, describe_fail(found.path, field, "the record %s: each field has a type, and no `using`", record_name)
		}
		item: Field_Description
		field_size, field_alignment: u32
		if rights, is_lent, lent_ok := lent_rights(field.type); is_lent {
			if !lent_ok {
				return 0, true, describe_fail(found.path, field, "the record %s: write the rights of a handle as Lent({{.Read, .Write}})", record_name)
			}
			item, field_size, field_alignment, has_handle = {type = .Handle, detail = transmute(u32)rights}, 4, 4, true
		} else if kind_item, kind_size, kind_alignment, is_kind := field_kind_field(state, field.type, found.prefix); is_kind {
			// A type of the contract that states how a reader writes the
			// value: a hexadecimal Integer, a status, a module name, a hash.
			item, field_size, field_alignment = kind_item, kind_size, kind_alignment
		} else if integer_unit, is_unit := integer_unit_of_parameter(state, field.type); is_unit {
			// A type of the contract such as value_kinds.Size_In_Pages is a
			// distinct i64: an Integer of 8 bytes with a sign that states
			// what it counts.
			item, field_size, field_alignment = {type = .Integer, detail = 0, integer_unit = integer_unit}, 8, 8
		} else if integer, unsigned := integer_size(state, found.prefix, type_text(found.source, field.type)); integer != 0 {
			// 8 bytes keep the detail 0 of the fields before the sizes.
			item, field_size, field_alignment = {type = .Integer, detail = integer == 8 ? 0 : integer, unsigned = unsigned}, integer, integer
		} else if count, is_text, text_ok := text_size(field.type); is_text {
			if !text_ok {
				return 0, true, describe_fail(found.path, field, "the record %s: a Text field is [N]u8, with a number N from 1 to %d", record_name, module.RECORD_SIZE_LIMIT)
			}
			item, field_size, field_alignment = {type = .Text, detail = count}, count, 1
		} else {
			return 0, true, describe_fail(found.path, field, "the record %s: the type %s has no description. A field is an integer (i64, u64, i32, u32, i16, u16, i8, u8, or an enum of one of them), an integer with a unit (value_kinds.Size_In_Pages and the other types of value_kinds), a field with a kind (value_kinds.Hexadecimal_32, value_kinds.Module_Name_Field, value_kinds.Hash_Field and the other types of value_kinds.FIELD_KIND_TYPES, or a contract enum such as operation.Log_Level or its word type such as operation.Status_Word), a Lent({{...}}) (Handle) or a [N]u8 (Text)", record_name, type_text(found.source, field.type))
		}
		alignment = max(alignment, field_alignment)
		for expression in field.names {
			name, is_identifier := expression.derived.(^ast.Ident)
			if !is_identifier || name.name == "_" {
				return 0, true, describe_fail(found.path, field, "the record %s: each field has a name", record_name)
			}
			size = (size + field_alignment - 1) / field_alignment * field_alignment
			item.name, item.offset = name.name, size
			append(&fields, item)
			size += field_size
		}
	}
	size = (size + alignment - 1) / alignment * alignment
	if size > module.RECORD_SIZE_LIMIT {
		return 0, true, describe_fail(found.path, declared, "the record %s has %d bytes: the limit is %d", record_name, size, module.RECORD_SIZE_LIMIT)
	}
	if result && has_handle {
		return 0, true, describe_fail(found.path, declared, "the record %s is a result or the record of a table: it has no handle", record_name)
	}
	for item, index in state.records {
		if item.name == record_name {
			return u32(index + 1), true, true
		}
	}
	append(&state.records, Record_Description{name = record_name, size = size, fields = fields[:]})
	return u32(len(state.records)), true, true
}

// describe_source adds the descriptions of the exports of one source file.
// package_text receives the documentation text of the package, if the file
// has one. records receives the records that the exports use.
describe_source :: proc(path, source: string, list: ^[dynamic]Export_Description, package_text: ^string = nil, records: ^[]Record_Description = nil, enums: ^[]Enum_Description = nil, member_texts: ^[]Member_Text_Description = nil) -> bool {
	context.allocator = context.temp_allocator
	state: Describe_State
	state.records = make([dynamic]Record_Description, context.temp_allocator)
	state.structs = make(map[string]Struct_Source, context.temp_allocator)
	file := parse_source(path, source, &state) or_return
	if package_text != nil {
		package_text^ = text_of(file.docs)
	}
	describe_file(file, list, &state) or_return
	enum_getters_resolve(list[:], state.enum_descriptions[:]) or_return
	texts := make([dynamic]Member_Text_Description, context.temp_allocator)
	member_texts_read(file, &state, &texts) or_return
	ordered := member_texts_order(path, texts[:]) or_return
	if records != nil {
		records^ = state.records[:]
	}
	if enums != nil {
		enums^ = state.enum_descriptions[:]
	}
	if member_texts != nil {
		member_texts^ = ordered
	}
	return true
}

// member_texts_read adds the display texts of the declared tables of a
// file (src/md/features/enum_parameters.md, "The display text of a
// member"): each declaration with the attribute `member_texts`, whose value
// is the language tag of BCP 47 of its texts, and whose value is an
// enumerated array of texts of an enum that an export takes or gives:
//
//	@(rodata, member_texts = "en")
//	scale_texts := #partial [scale_factor.Scale]string{.Ten_Eighths = "1.25"}
//
// The compiler checks each member of the table; the tool checks the tag
// (language_tag.problem) and keeps its canonical case, the enum, and each
// text against the rules of the reader.
member_texts_read :: proc(file: ^ast.File, state: ^Describe_State, texts: ^[dynamic]Member_Text_Description) -> bool {
	context.allocator = context.temp_allocator
	path := file.fullpath
	for statement in file.decls {
		declaration, is_value := statement.derived.(^ast.Value_Decl)
		if !is_value {
			continue
		}
		tag_text, has_texts := "", false
		for attribute in declaration.attributes {
			for element in attribute.elems {
				item, is_field := element.derived.(^ast.Field_Value)
				if !is_field {
					continue
				}
				field, is_name := item.field.derived.(^ast.Ident)
				if !is_name || field.name != foundation.MEMBER_TEXTS_ATTRIBUTE_NAME {
					continue
				}
				literal, is_literal := item.value.derived.(^ast.Basic_Lit)
				if !is_literal || literal.tok.kind != .String {
					return describe_fail(path, declaration, "the attribute %s takes a text: the language tag of BCP 47 of the texts, \"en\"", foundation.MEMBER_TEXTS_ATTRIBUTE_NAME)
				}
				tag_text, has_texts = strings.trim(literal.tok.text, "\"`"), true
			}
		}
		if !has_texts {
			continue
		}
		// The file stores each tag in its canonical case, so a source can
		// write "EN" or "fr-ca": two tags of one language are one key.
		if problem := language_tag.problem(tag_text); problem != .None {
			return describe_fail(path, declaration, "the attribute %s names \"%s\", which is no well-formed language tag of BCP 47 (RFC 5646, section 2.1): %v", foundation.MEMBER_TEXTS_ATTRIBUTE_NAME, tag_text, problem)
		}
		tag_buffer := make([]u8, language_tag.TAG_CAPACITY)
		tag, _ := language_tag.canonical(tag_text, tag_buffer)
		literal: ^ast.Comp_Lit
		if len(declaration.names) == 1 && len(declaration.values) == 1 {
			literal, _ = declaration.values[0].derived.(^ast.Comp_Lit)
		}
		type: ^ast.Expr = declaration.type
		if type == nil && literal != nil {
			type = literal.type
		}
		array: ^ast.Array_Type
		if type != nil {
			array, _ = type.derived.(^ast.Array_Type)
		}
		element: ^ast.Ident
		if array != nil {
			element, _ = array.elem.derived.(^ast.Ident)
		}
		if literal == nil || array == nil || array.len == nil || element == nil || element.name != "string" {
			return describe_fail(path, declaration, "a table of display texts is one variable of an enumerated array of texts: name := #partial [Enum]string{{.Member = \"text\"}}")
		}
		key, enum_name := struct_name(state, array.len)
		enum_number := 0
		for item, index in state.enum_keys {
			if key != "" && item == key {
				enum_number = index + 1
			}
		}
		if enum_number == 0 {
			return describe_fail(path, declaration, "the display texts of %s: the enum is the type of no Enum parameter or result of an export of the module, so no reader shows them", enum_name)
		}
		described := state.enum_descriptions[enum_number - 1]
		for item in literal.elems {
			selector: ^ast.Implicit_Selector_Expr
			text_literal: ^ast.Basic_Lit
			if pair, is_pair := item.derived.(^ast.Field_Value); is_pair {
				selector, _ = pair.field.derived.(^ast.Implicit_Selector_Expr)
				text_literal, _ = pair.value.derived.(^ast.Basic_Lit)
			}
			if selector == nil || text_literal == nil || text_literal.tok.kind != .String || len(text_literal.tok.text) < 2 {
				return describe_fail(path, item, "the display texts of %s: each row is .Member = \"text\", with a text literal", enum_name)
			}
			raw := text_literal.tok.text
			text := raw[1:len(raw) - 1]
			if strings.contains_rune(text, '\\') && raw[0] == '"' {
				return describe_fail(path, item, "the display texts of %s: the text of .%s has an escape: write the characters themselves", enum_name, selector.field.name)
			}
			member_name := strings.to_lower(selector.field.name, context.temp_allocator)
			member_number := -1
			for member, number in described.members {
				if member.name == member_name {
					member_number = number
				}
			}
			if member_number < 0 {
				return describe_fail(path, item, "the display texts of %s: %s is no member of the enum", enum_name, selector.field.name)
			}
			if len(text) == 0 || len(text) > module.MEMBER_TEXT_CAPACITY || !text_encoding.display_text_valid(transmute([]u8)text) {
				return describe_fail(path, item, "the display text of %s.%s is \"%s\": a display text is 1 to %d bytes of UTF-8 with no control character, no character that a reader does not see or that changes the order of the text, and one character at least that is not a space", enum_name, selector.field.name, text, module.MEMBER_TEXT_CAPACITY)
			}
			append(texts, Member_Text_Description{enum_number = u32(enum_number), member_number = u32(member_number), tag = tag, text = text})
		}
	}
	return true
}

// palette_rows_fit checks that each row of buttons of the palette that an
// export gives fits the fields of a palette entry
// (src/md/features/enum_parameters.md, "The display text of a member"):
// the console makes no entry of a member whose entry does not fit, so a
// button would be missing with no sign. A row is an export of one Enum
// parameter, or whose parameters are each an optional Enum, as the console
// takes it (palette_row_takes). module_name is the name of a service
// before the export, the longest form of the command.
palette_rows_fit :: proc(module_name: string, exports: []Export_Description, enums: []Enum_Description, texts: []Member_Text_Description) -> bool {
	for item in exports {
		if len(item.parameters) == 0 {
			continue
		}
		row := len(item.parameters) == 1 && item.parameters[0] == .Enum
		if !row {
			row = true
			for type, index in item.parameters {
				if type != .Enum || item.optional_parameters >> u16(index) & 1 == 0 {
					row = false
				}
			}
		}
		if !row {
			continue
		}
		command := strings.concatenate({module_name, ".", item.name}, context.temp_allocator)
		for parameter, index in item.names {
			if index >= len(item.details) {
				continue
			}
			enum_number, _ := module.enum_detail_of(item.details[index])
			if enum_number == 0 || int(enum_number) > len(enums) {
				continue
			}
			Part :: struct {
				what, text: string,
				capacity:   int,
			}
			parts := make([dynamic]Part, context.temp_allocator)
			append(&parts, Part{"the act name", strings.concatenate({command, ":", parameter}, context.temp_allocator), palette_table.ACT_NAME_CAPACITY})
			append(&parts, Part{"the name of the row", parameter, palette_table.SETTING_NAME_CAPACITY})
			for member, member_number in enums[enum_number - 1].members {
				shown := member.name
				for text in texts {
					if text.enum_number == enum_number && int(text.member_number) == member_number && text.tag == module.FALLBACK_TAG {
						shown = text.text
					}
				}
				append(&parts, Part{"the name of an entry", strings.concatenate({command, " ", parameter, " to ", shown}, context.temp_allocator), palette_table.NAME_CAPACITY})
				append(&parts, Part{"the line of an entry", strings.concatenate({command, "(", parameter, " = .", member.name, ")"}, context.temp_allocator), palette_table.ABOUT_CAPACITY})
				append(&parts, Part{"a button", shown, palette_table.VALUE_NAME_CAPACITY})
			}
			for part in parts {
				if len(part.text) > part.capacity {
					fmt.eprintfln("modustool: describe %s(%d): %s: %s of the palette, \"%s\", has %d bytes, and the palette holds %d: the button would be missing. Shorten the name of the export, of the parameter or of the member, or its display text", item.file, item.line, item.name, part.what, part.text, len(part.text), part.capacity)
					return false
				}
			}
		}
	}
	return true
}

// member_texts_order sorts the display texts in the order of the format:
// the enum, the member, the bytes of the canonical tag
// (module.member_text_order). Two texts for one member and one tag, from
// two tables of one enum and one tag, are refused.
member_texts_order :: proc(place: string, texts: []Member_Text_Description) -> (ordered: []Member_Text_Description, ok: bool) {
	order :: proc(a, b: Member_Text_Description) -> int {
		return module.member_text_order(a.enum_number, a.member_number, a.tag, b.enum_number, b.member_number, b.tag)
	}
	slice.sort_by(texts, proc(a, b: Member_Text_Description) -> bool {
		return order(a, b) < 0
	})
	for index in 1 ..< max(len(texts), 1) {
		if order(texts[index], texts[index - 1]) == 0 {
			fmt.eprintfln("modustool: describe %s: two tables of display texts give the member %d of the enum %d for the tag %s: one text for each member and tag", place, texts[index].member_number, texts[index].enum_number, texts[index].tag)
			return nil, false
		}
	}
	return texts, true
}

// describe_file adds the descriptions of the exports of one parsed file.
describe_file :: proc(file: ^ast.File, list: ^[dynamic]Export_Description, state: ^Describe_State) -> bool {
	context.allocator = context.temp_allocator
	path, source := file.fullpath, file.src

	for statement in file.decls {
		declaration, is_value := statement.derived.(^ast.Value_Decl)
		if !is_value || len(declaration.names) != 1 {
			continue
		}
		identifier, has_name := declaration.names[0].derived.(^ast.Ident)
		if !has_name {
			continue
		}
		name := identifier.name
		exported := false
		getters_text, optional_text := "", ""
		for attribute in declaration.attributes {
			for element in attribute.elems {
				#partial switch item in element.derived {
				case ^ast.Ident:
					exported |= item.name == "export"
				case ^ast.Field_Value:
					field, is_field := item.field.derived.(^ast.Ident)
					literal, is_literal := item.value.derived.(^ast.Basic_Lit)
					if !is_field {
						continue
					}
					switch field.name {
					case "link_name", foundation.ENUM_GETTERS_ATTRIBUTE_NAME, foundation.OPTIONAL_PARAMETERS_ATTRIBUTE_NAME:
						if !is_literal || literal.tok.kind != .String {
							return describe_fail(path, declaration, "the attribute %s takes a text", field.name)
						}
					}
					text := is_literal ? strings.trim(literal.tok.text, "\"`") : ""
					switch field.name {
					case "link_name":
						name = text
					case foundation.ENUM_GETTERS_ATTRIBUTE_NAME:
						getters_text = text
					case foundation.OPTIONAL_PARAMETERS_ATTRIBUTE_NAME:
						optional_text = text
					}
				}
			}
		}
		if !exported && (getters_text != "" || optional_text != "") {
			return describe_fail(path, declaration, "%s is no export: the attributes %s and %s describe the parameters of an export", name, foundation.ENUM_GETTERS_ATTRIBUTE_NAME, foundation.OPTIONAL_PARAMETERS_ATTRIBUTE_NAME)
		}
		if !exported {
			continue
		}
		if len(declaration.values) != 1 {
			return describe_fail(path, declaration, "%s is not a function: the exports of a module are functions only", name)
		}
		function, is_function := declaration.values[0].derived.(^ast.Proc_Lit)
		if !is_function {
			return describe_fail(path, declaration, "%s is not a function: the exports of a module are functions only", name)
		}
		type := function.type
		convention, _ := type.calling_convention.(string)
		if strings.trim(convention, "\"") != "c" || type.generic {
			return describe_fail(path, declaration, "%s must have the calling convention \"c\" and no generic parameter", name)
		}
		fields: []^ast.Field
		if type.params != nil {
			fields = type.params.list
		}
		// An export that can fail gives the call outcome first, then its
		// value: (outcome: call_outcome.Call_Outcome, value: i64), or the
		// outcome alone when it has no value (src/md/api/call_outcome.md).
		result_text := ""
		returns_outcome := false
		if type.results != nil {
			results := type.results.list
			for item in results {
				if item.type == nil || len(item.names) > 1 {
					return describe_fail(path, declaration, "%s: each result has one name and a type", name)
				}
			}
			switch len(results) {
			case 1:
				result_text = type_text(source, results[0].type)
				if is_contract_type(state, results[0].type, "call_outcome", "Call_Outcome") {
					result_text, returns_outcome = "", true
				}
			case 2:
				if !is_contract_type(state, results[0].type, "call_outcome", "Call_Outcome") || type_text(source, results[1].type) != "i64" {
					return describe_fail(path, declaration, "%s has two results: an export that can fail gives (outcome: call_outcome.Call_Outcome, value: i64), the outcome first", name)
				}
				result_text, returns_outcome = "i64", true
			case:
				return describe_fail(path, declaration, "%s has more than two results: an export gives one value, or the outcome and one value", name)
			}
		}

		if name == ENTRY_NAME {
			address := len(fields) == 1 && len(fields[0].names) == 1 && fields[0].type != nil
			if address {
				text := type_text(source, fields[0].type)
				address = text == "rawptr" || strings.has_prefix(text, "^")
			}
			if !address || returns_outcome || result_text != "" && result_text != "i64" {
				return describe_fail(path, declaration, "the entry has one parameter, an address, and no result or an i64 result")
			}
			// The entry has a comment as each export has: what this module
			// does when the loader starts it. With no comment its text is empty.
			entry_description := Export_Description{name = name, file = path, line = declaration.pos.line}
			entry_description.markdown = markdown_of(declaration.docs)
			entry_description.text = entry_description.markdown
			entry_description.about = about_of(documentation_text_of_markdown(entry_description.markdown), name)
			append(list, entry_description)
			continue
		}

		if type.diverging {
			return describe_fail(path, declaration, "%s does not return: only the entry can have the result !", name)
		}
		description := Export_Description {
			name = name,
			file = path,
			line = declaration.pos.line,
		}
		parameters := make([dynamic]module.Type, context.temp_allocator)
		names := make([dynamic]string, context.temp_allocator)
		details := make([dynamic]u32, context.temp_allocator)
		directions := make([dynamic]module.Direction, context.temp_allocator)
		// An error record: the last parameter, with the name `error`, after
		// the buffer of a result too.
		if count := len(fields); count > 0 && len(fields[count - 1].names) == 1 && fields[count - 1].type != nil {
			last, _ := fields[count - 1].names[0].derived.(^ast.Ident)
			if last != nil && last.name == "error" {
				number, is_record, record_ok := record_of(state, fields[count - 1].type, true)
				if !is_record || !record_ok {
					return describe_fail(path, fields[count - 1], "%s: the parameter error is the address of an error record (^errors.Error_Record), the last parameter", name)
				}
				description.error_record = number
				fields = fields[:count - 1]
			}
		}
		for field, index in fields {
			if field.type == nil || len(field.names) == 0 {
				return describe_fail(path, field, "%s: each parameter has a name and a type", name)
			}
			kind: module.Type
			detail: u32
			direction: module.Direction
			last := index == len(fields) - 1 && len(field.names) == 1
			first_name, _ := field.names[0].derived.(^ast.Ident)
			is_result := last && first_name != nil && first_name.name == "result"
			switch text := type_text(source, field.type); text {
			case "i64":
				kind = .Integer
			case "^string":
				kind = .Text
			case "^[]u8":
				if !last {
					return describe_fail(path, field, "%s: the buffer of a Text result (^[]u8) is the last parameter", name)
				}
				description.result = .Text
				continue
			case:
				if integer_unit, is_unit := integer_unit_of_parameter(state, field.type); is_unit {
					kind, detail = .Integer, value_kinds.integer_unit_detail(integer_unit)
					break
				}
				if rights, is_lent, lent_ok := lent_rights(field.type); is_lent {
					if !lent_ok {
						return describe_fail(path, field, "%s: write the rights of a handle as Lent({{.Read, .Write}})", name)
					}
					kind, detail = .Handle, transmute(u32)rights
					break
				}
				if number, is_enum, enum_ok := enum_of(state, field.type); is_enum {
					if !enum_ok {
						return false
					}
					// The getter joins the detail once each export of the
					// package is known (enum_getters_resolve).
					kind, detail = .Enum, number
					break
				}
				if table_kind, number, table_direction, is_parameter, parameter_ok := table_parameter(state, field.type); is_parameter {
					if !parameter_ok {
						return describe_fail(path, field, "%s: a table parameter is ^Table_To_Read(Name), ^Table_To_Change(Name) or ^Table_To_Append(Name), with Name a struct with no handle, or ^Bytes_To_Read, ^Bytes_To_Change or ^Bytes_To_Append", name)
					}
					kind, detail, direction = table_kind, number, table_direction
					break
				}
				if number, is_table, table_ok := table_of(state, field.type); is_table {
					if !table_ok {
						return false
					}
					if !is_result {
						return describe_fail(path, field, "%s: the buffer of a Table result (^[]Name) is the last parameter, with the name result", name)
					}
					description.result, description.result_detail = .Table, number
					continue
				}
				if number, is_record, record_ok := record_of(state, field.type, is_result); is_record {
					if !record_ok {
						return false
					}
					if is_result {
						description.result, description.result_detail = .Record, number
						continue
					}
					kind, detail = .Record, number
					break
				}
				return describe_fail(
					path,
					field,
					"%s: the type %s has no description. Use i64 (Integer), value_kinds.Size_In_Bytes and the other types of value_kinds.INTEGER_UNIT_TYPES (an Integer with its unit), ^string (Text), Lent({{...}}) (Handle), the address of a struct of the package (Record), ^Table_To_Read(Name) and its forms (Table), ^Bytes_To_Read and its forms (Bytes), a last parameter ^[]u8 (the buffer of a Text result), or a last parameter result: ^[]Name (the buffer of a Table result)",
					name,
					text,
				)
			}
			for expression in field.names {
				parameter, is_identifier := expression.derived.(^ast.Ident)
				if !is_identifier || parameter.name == "_" || len(parameter.name) > 255 {
					return describe_fail(path, field, "%s: each parameter has a name", name)
				}
				append(&parameters, kind)
				append(&names, parameter.name)
				append(&details, detail)
				append(&directions, direction)
			}
		}
		result_enum: u32
		result_is_enum := false
		if result_text != "" && result_text != "i64" && description.result == .None {
			number, is_enum, enum_ok := enum_of(state, type.results.list[0].type)
			if is_enum && !enum_ok {
				return false
			}
			result_enum, result_is_enum = number, is_enum
		}
		switch {
		case description.result == .Record:
			if result_text != "" {
				return describe_fail(path, declaration, "%s: the callee writes a Record result in the memory of the caller: the export has no result type", name)
			}
		case result_is_enum:
			description.result, description.result_detail = .Enum, result_enum
		case result_text == "i64":
			if description.result != .Text && description.result != .Table {
				description.result = .Integer
			}
		case result_text != "":
			return describe_fail(path, declaration, "%s: the result type %s has no description. Use i64, or an enum with a backing type", name, result_text)
		case description.result == .Text:
			return describe_fail(path, declaration, "%s: a Text result gives its count of bytes: the result type is i64", name)
		case description.result == .Table:
			return describe_fail(path, declaration, "%s: a Table result gives its count of records: the result type is i64", name)
		}
		// The signature is the promise, and the compiler checks it: an
		// export with an error record can fail, so it gives the outcome; an
		// export with one result cannot fail.
		if description.error_record != 0 && !returns_outcome {
			return describe_fail(path, declaration, "%s takes an error record, so it can fail: it gives the call outcome first, (outcome: call_outcome.Call_Outcome, value: i64), or call_outcome.Call_Outcome alone when it has no value", name)
		}
		if returns_outcome && description.error_record == 0 {
			return describe_fail(path, declaration, "%s gives a call outcome, so it can fail: its last parameter is the error record, error: ^errors.Error_Record", name)
		}
		if returns_outcome && description.result == .Enum {
			return describe_fail(path, declaration, "%s can fail: the value of the pair is an i64", name)
		}
		if arguments := module.call_argument_count(len(parameters), u8(description.result), description.error_record != 0); arguments > module.PARAMETER_CAPACITY {
			return describe_fail(path, declaration, "%s takes %d arguments in the call form, the buffer of a result and the error record included; an export takes at most %d", name, arguments, module.PARAMETER_CAPACITY)
		}
		description.parameters = parameters[:]
		description.names = names[:]
		description.details = details[:]
		description.directions = directions[:]
		description.getter_names = make([]string, len(parameters))
		if !parameter_attributes_read(path, declaration, &description, getters_text, optional_text) {
			return false
		}
		handles := 0
		for kind, index in parameters {
			#partial switch kind {
			case .Handle:
				handles += 1
			case .Record:
				for item in state.records[details[index] - 1].fields {
					handles += int(item.type == .Handle)
				}
			}
		}
		if handles > module.HANDLE_CAPACITY {
			return describe_fail(path, declaration, "%s: a call lends at most %d handles; this export takes %d", name, module.HANDLE_CAPACITY, handles)
		}
		description.markdown = markdown_of(declaration.docs)
		description.text = description.markdown
		description.about = about_of(documentation_text_of_markdown(description.markdown), name)
		if description.about == "" {
			return describe_fail(path, declaration, "%s has no comment: the first sentence of the comment is the help of the export", name)
		}
		append(list, description)
	}
	return true
}

// parameter_attributes_read reads the two attributes of an export that
// describe its Enum parameters (src/md/features/enum_parameters.md):
//
// - `enum_getters = "font = font, scale = scale"`: each pair names an Enum
//   parameter, then the export that gives its value in use, its getter.
// - `optional_parameters = "font, scale"`: the Enum parameters that a call
//   may leave out.
//
// A name of no parameter, a parameter that is no Enum, a name given twice
// and a pair with no "=" are refused. The getter is resolved into the
// detail once each export of the package is known (enum_getters_resolve).
@(private = "file")
parameter_attributes_read :: proc(path: string, declaration: ^ast.Value_Decl, description: ^Export_Description, getters_text, optional_text: string) -> bool {
	parameter_find :: proc(description: ^Export_Description, name: string) -> int {
		for item, index in description.names {
			if item == name {
				return index
			}
		}
		return -1
	}
	if strings.trim_space(optional_text) != "" {
		for part in strings.split(optional_text, ",", context.temp_allocator) {
			parameter_name := strings.trim_space(part)
			index := parameter_find(description, parameter_name)
			switch {
			case index < 0:
				return describe_fail(path, declaration, "%s: the attribute %s names %q, which is no parameter", description.name, foundation.OPTIONAL_PARAMETERS_ATTRIBUTE_NAME, parameter_name)
			case description.parameters[index] != .Enum:
				return describe_fail(path, declaration, "%s: the attribute %s names %s, which is no enum: only an enum parameter has a word that says that a call leaves it out", description.name, foundation.OPTIONAL_PARAMETERS_ATTRIBUTE_NAME, parameter_name)
			case description.optional_parameters >> u16(index) & 1 != 0:
				return describe_fail(path, declaration, "%s: the attribute %s names %s twice", description.name, foundation.OPTIONAL_PARAMETERS_ATTRIBUTE_NAME, parameter_name)
			}
			description.optional_parameters |= 1 << u16(index)
		}
	}
	if strings.trim_space(getters_text) == "" {
		return true
	}
	for part in strings.split(getters_text, ",", context.temp_allocator) {
		pair := strings.split(part, "=", context.temp_allocator)
		if len(pair) != 2 {
			return describe_fail(path, declaration, "%s: the attribute %s holds pairs `parameter = getter`, separated by commas; %q is none", description.name, foundation.ENUM_GETTERS_ATTRIBUTE_NAME, strings.trim_space(part))
		}
		parameter_name, getter_name := strings.trim_space(pair[0]), strings.trim_space(pair[1])
		index := parameter_find(description, parameter_name)
		switch {
		case index < 0:
			return describe_fail(path, declaration, "%s: the attribute %s names %q, which is no parameter", description.name, foundation.ENUM_GETTERS_ATTRIBUTE_NAME, parameter_name)
		case description.parameters[index] != .Enum:
			return describe_fail(path, declaration, "%s: the attribute %s names %s, which is no enum: a getter gives the member in use of an enum parameter", description.name, foundation.ENUM_GETTERS_ATTRIBUTE_NAME, parameter_name)
		case description.getter_names[index] != "":
			return describe_fail(path, declaration, "%s: the attribute %s names %s twice", description.name, foundation.ENUM_GETTERS_ATTRIBUTE_NAME, parameter_name)
		case getter_name == "":
			return describe_fail(path, declaration, "%s: the attribute %s gives %s no getter", description.name, foundation.ENUM_GETTERS_ATTRIBUTE_NAME, parameter_name)
		}
		description.getter_names[index] = getter_name
	}
	return true
}

// enum_getters_resolve writes the getter of each Enum parameter into its
// detail, once each export of the package is known: export n + 1 of the
// module is exports[n]. A getter that names no export, that takes a
// parameter or gives an error record, or that gives another enum, is
// refused with a line that names the export and the parameter. Two enums
// are one when they are one description (enums is the list of the
// package).
enum_getters_resolve :: proc(exports: []Export_Description, enums: []Enum_Description) -> bool {
	for &item in exports {
		for getter_name, index in item.getter_names {
			if getter_name == "" {
				continue
			}
			getter := -1
			for other, other_index in exports {
				if other.name == getter_name {
					getter = other_index
				}
			}
			if getter < 0 {
				fmt.eprintfln("modustool: describe %s(%d): %s: the getter %s of the parameter %s names no export of the module", item.file, item.line, item.name, getter_name, item.names[index])
				return false
			}
			found := exports[getter]
			if len(found.parameters) != 0 || found.error_record != 0 || found.result != .Enum {
				fmt.eprintfln("modustool: describe %s(%d): %s: the getter %s of the parameter %s must take no parameter, give no error record, and give the enum of the parameter", item.file, item.line, item.name, getter_name, item.names[index])
				return false
			}
			enum_number := item.details[index]
			if found.result_detail != enum_number {
				given := found.result_detail >= 1 && int(found.result_detail) <= len(enums) ? enums[found.result_detail - 1].name : "?"
				fmt.eprintfln("modustool: describe %s(%d): %s: the getter %s gives %s, and the parameter %s takes %s", item.file, item.line, item.name, getter_name, given, item.names[index], enums[enum_number - 1].name)
				return false
			}
			detail, made := module.enum_detail_make(enum_number, u32(getter + 1))
			if !made {
				fmt.eprintfln("modustool: describe %s(%d): %s: the module has more than %d exports or enums: the detail of an enum parameter holds no larger index", item.file, item.line, item.name, module.ENUM_DETAIL_INDEX_MOST)
				return false
			}
			item.details[index] = detail
		}
	}
	return true
}

// The constant of a source that states the budget of its module
// (docs/MODULE_CONTRACT.md, "The budget that a module asks for").
BUDGET_REQUEST_NAME :: "MODULE_BUDGET"

// The largest width and the largest height of a window part: the limit of
// a surface of display.open. A larger part is a fault of the source, and
// the product of two parts stays far from the end of 64 bits.
BUDGET_WINDOW_PART_LIMIT :: 8192

// budget_request_read reads the constant BUDGET_REQUEST_NAME of one parsed
// file into budget: the stated budget. A file with no such constant leaves
// budget as it is. The tool reads integer literals only, so the number of
// the table comes from the numbers of the source; the compiler checks the
// type and the names of the fields, because the constant has the type of
// the record. A window part that names a constant keeps the name:
// budget_window_resolve reads it when each file of the package is read.
budget_request_read :: proc(file: ^ast.File, budget: ^Budget_Description) -> bool {
	path := file.fullpath
	// An argument of the format, not a part of it: its braces are text.
	FORM :: "the form is " + BUDGET_REQUEST_NAME + " :: system.Stated_Budget{working_memory_pages = N, processes = N, threads = N, window_width = WIDTH, window_height = HEIGHT, window_least_width = LEAST_WIDTH, window_least_height = LEAST_HEIGHT, screen_pictures = N}"
	for statement in file.decls {
		// A declaration inside a `when`: the tool reads the source with no
		// setting of the build, so it cannot know the branch that the
		// compiler takes, and it never gives the least budget in silence.
		if when_statement, is_when := statement.derived.(^ast.When_Stmt); is_when {
			if found := budget_request_in_when(when_statement); found != nil {
				return describe_fail(path, found, "%s is inside a `when`: the tool reads the source with no setting of the build and cannot know the branch that the compiler takes. Declare it at the top level of a file, with one value", BUDGET_REQUEST_NAME)
			}
			continue
		}
		declaration, is_value := statement.derived.(^ast.Value_Decl)
		if !is_value || !declaration_names(declaration, BUDGET_REQUEST_NAME) {
			continue
		}
		if len(declaration.names) != 1 {
			return describe_fail(path, declaration, "%s is declared with other names: declare it alone, so that the tool reads one value", BUDGET_REQUEST_NAME)
		}
		if budget.stated {
			return describe_fail(path, declaration, "%s is stated two times in the package: a module asks for one budget", BUDGET_REQUEST_NAME)
		}
		if declaration.is_mutable {
			return describe_fail(path, declaration, "%s is a variable: it is a constant (::), so that the process cannot change the request that the build wrote; %s", BUDGET_REQUEST_NAME, FORM)
		}
		if len(declaration.values) != 1 {
			return describe_fail(path, declaration, "%s has no value: %s", BUDGET_REQUEST_NAME, FORM)
		}
		literal, is_literal := declaration.values[0].derived.(^ast.Comp_Lit)
		if !is_literal {
			return describe_fail(path, declaration, "%s is not a record literal: the tool reads the parts of a literal and evaluates no expression; %s", BUDGET_REQUEST_NAME, FORM)
		}
		// The type is on the literal, or on the declaration in the form
		// `MODULE_BUDGET : system.Stated_Budget : {...}`.
		types := [2]^ast.Expr{literal.type, declaration.type}
		typed := false
		for type in types {
			if type == nil {
				continue
			}
			typed = true
			type_name := ""
			#partial switch named in type.derived {
			case ^ast.Ident:
				type_name = named.name
			case ^ast.Selector_Expr:
				type_name = named.field.name
			}
			if type_name != "Stated_Budget" {
				return describe_fail(path, declaration, "%s has the type %s: its type is system.Stated_Budget, the parts that a source states, so that the compiler checks the names of its parts", BUDGET_REQUEST_NAME, type_text(file.src, type))
			}
		}
		if !typed {
			return describe_fail(path, declaration, "%s has no type: give it the type system.Stated_Budget, so that the compiler checks the names of its parts; %s", BUDGET_REQUEST_NAME, FORM)
		}
		stated: Stated_Budget
		window_names: [4]string
		for element in literal.elems {
			field_value, is_field := element.derived.(^ast.Field_Value)
			field: ^ast.Ident
			if is_field {
				field, _ = field_value.field.derived.(^ast.Ident)
			}
			if field == nil {
				return describe_fail(path, element, "%s: each part has its name (threads = N), so that a part never takes the place of another", BUDGET_REQUEST_NAME)
			}
			place: ^u64
			// The window parts can name a constant: the process passes the
			// same constant to display.open.
			window_index := -1
			switch field.name {
			case "working_memory_pages":
				place = &stated.working_memory_pages
			case "processes":
				place = &stated.processes
			case "threads":
				place = &stated.threads
			case "window_width":
				place, window_index = &stated.window_width, 0
			case "window_height":
				place, window_index = &stated.window_height, 1
			case "window_least_width":
				place, window_index = &stated.window_least_width, 2
			case "window_least_height":
				place, window_index = &stated.window_least_height, 3
			case "screen_pictures":
				place = &stated.screen_pictures
			case:
				return describe_fail(path, element, "%s has no part %s: its parts are working_memory_pages, processes, threads, window_width, window_height, window_least_width, window_least_height and screen_pictures; the tool counts the other pages, and processor time and log records are limits that the starter sets", BUDGET_REQUEST_NAME, field.name)
			}
			if place^ != 0 || (window_index >= 0 && window_names[window_index] != "") {
				return describe_fail(path, element, "%s states the part %s two times", BUDGET_REQUEST_NAME, field.name)
			}
			if constant, is_name := field_value.value.derived.(^ast.Ident); is_name {
				if window_index < 0 {
					return describe_fail(path, element, "%s: the part %s is the name %s: write its number; the tool reads integer literals, and a name only for the size of a window", BUDGET_REQUEST_NAME, field.name, constant.name)
				}
				window_names[window_index] = constant.name
				continue
			}
			// A least part is the name that the call of resizable_set passes:
			// a number would be a second copy that the tool cannot compare.
			if window_index >= 2 {
				return describe_fail(path, element, "%s: the part %s is not a name: write the name of the constant that the source passes to display.resizable_set as %s, so that the tool checks the two against each other", BUDGET_REQUEST_NAME, field.name, field.name[len("window_"):])
			}
			number, is_number := field_value.value.derived.(^ast.Basic_Lit)
			if !is_number {
				return describe_fail(path, element, "%s: the part %s is an expression: write one integer literal; the tool evaluates no expression, so the number of the file comes from the numbers of the source", BUDGET_REQUEST_NAME, field.name)
			}
			value, readable := integer_literal_value(number)
			if !readable {
				return describe_fail(path, element, "%s: the part %s is %s, which is not an integer of 64 bits that the tool can read: a part counts pages, processes, threads or pixels", BUDGET_REQUEST_NAME, field.name, number.tok.text)
			}
			if value == 0 {
				return describe_fail(path, element, "%s: the part %s is 0: leave the part out", BUDGET_REQUEST_NAME, field.name)
			}
			place^ = value
		}
		has_width := stated.window_width != 0 || window_names[0] != ""
		has_height := stated.window_height != 0 || window_names[1] != ""
		if has_width != has_height {
			return describe_fail(path, declaration, "%s states one part of the size of its window: state window_width and window_height, or neither", BUDGET_REQUEST_NAME)
		}
		has_least := window_names[2] != "" || window_names[3] != ""
		if has_least && (window_names[2] == "" || window_names[3] == "") {
			return describe_fail(path, declaration, "%s states one part of the least size of its window: state window_least_width and window_least_height, or neither", BUDGET_REQUEST_NAME)
		}
		if has_least && !has_width {
			return describe_fail(path, declaration, "%s states a least size and no window: state window_width and window_height, the largest size, with it", BUDGET_REQUEST_NAME)
		}
		if stated.screen_pictures > module.SCREEN_PICTURES_LIMIT {
			return describe_fail(path, declaration, "%s asks for %d pictures of the screen: a module holds %d at most, and each one is paid at the size of the screen of the machine", BUDGET_REQUEST_NAME, stated.screen_pictures, module.SCREEN_PICTURES_LIMIT)
		}
		comment := markdown_of(declaration.docs)
		if comment == "" {
			return describe_fail(path, declaration, "%s has no comment: the comment before it gives the reasons of its working memory and of its threads", BUDGET_REQUEST_NAME)
		}
		budget^ = {stated = true, parts = stated, window_names = window_names, comment = comment, file = path, line = declaration.pos.line}
	}
	return true
}

// integer_literal_value reads one integer literal of a source. A separator
// of digits, as in 41_984, is no digit; a prefix 0x, 0o or 0b gives the
// base. readable is false for a literal that is not an integer of 64 bits.
@(private = "file")
integer_literal_value :: proc(number: ^ast.Basic_Lit) -> (value: u64, readable: bool) {
	if number.tok.kind != .Integer {
		return 0, false
	}
	digits, _ := strings.remove_all(number.tok.text, "_", context.temp_allocator)
	return strconv.parse_u64_maybe_prefixed(digits)
}

// integer_constants_read adds to constants each constant of the top level
// of one file whose value is one integer literal: `WIDTH :: 1000`, or
// `WIDTH : int : 1000`. A constant of an expression is left out: the tool
// evaluates none.
integer_constants_read :: proc(file: ^ast.File, constants: ^map[string]u64) {
	for statement in file.decls {
		declaration, is_value := statement.derived.(^ast.Value_Decl)
		if !is_value || declaration.is_mutable || len(declaration.names) != 1 || len(declaration.values) != 1 {
			continue
		}
		name, is_name := declaration.names[0].derived.(^ast.Ident)
		number, is_number := declaration.values[0].derived.(^ast.Basic_Lit)
		if !is_name || !is_number {
			continue
		}
		if value, readable := integer_literal_value(number); readable {
			constants^[name.name] = value
		}
	}
}

// budget_window_resolve gives each window part of a stated budget that
// names a constant the value of that constant, and checks the size of the
// window. constants holds the constants of integer literals of each file
// of the package.
budget_window_resolve :: proc(budget: ^Budget_Description, constants: map[string]u64) -> bool {
	if !budget.stated {
		return true
	}
	places := [4]^u64{&budget.parts.window_width, &budget.parts.window_height, &budget.parts.window_least_width, &budget.parts.window_least_height}
	part_names := [4]string{"window_width", "window_height", "window_least_width", "window_least_height"}
	for name, index in budget.window_names {
		if name == "" {
			continue
		}
		value, found := constants[name]
		if !found {
			fmt.eprintfln("modustool: describe %s(%d): %s: the part %s names %s, which is not a constant of one integer literal in the package: write %s :: N, and if its value is an expression, put #assert(%s == <expression>) beside it, so that the compiler checks the number; the tool evaluates no expression", budget.file, budget.line, BUDGET_REQUEST_NAME, part_names[index], name, name, name)
			return false
		}
		if value == 0 {
			fmt.eprintfln("modustool: describe %s(%d): %s: the part %s names %s, which is 0: a window has one pixel at least", budget.file, budget.line, BUDGET_REQUEST_NAME, part_names[index], name)
			return false
		}
		places[index]^ = value
	}
	for place, index in places {
		if place^ > BUDGET_WINDOW_PART_LIMIT {
			fmt.eprintfln("modustool: describe %s(%d): %s: the part %s is %d, above %d, the largest size of a surface", budget.file, budget.line, BUDGET_REQUEST_NAME, part_names[index], place^, BUDGET_WINDOW_PART_LIMIT)
			return false
		}
	}
	if budget.parts.window_least_width > budget.parts.window_width || budget.parts.window_least_height > budget.parts.window_height {
		fmt.eprintfln("modustool: describe %s(%d): %s: the least size %d x %d is larger than the window, %d x %d", budget.file, budget.line, BUDGET_REQUEST_NAME, budget.parts.window_least_width, budget.parts.window_least_height, budget.parts.window_width, budget.parts.window_height)
		return false
	}
	return true
}

// A call of display.resizable_set in a package, as the tool reads it: the
// names that it passes as its least size.
Resizable_Call :: struct {
	least_names: [2]string, // The names of least_width and least_height, or "" for a part that is not a name.
	readable:    bool, // The record of the call is a literal: the tool read its parts.
	line:        int,
	file:        string,
}

// resizable_calls_read adds each call of resizable_set in one parsed file:
// a call written display.resizable_set or resizable_set. A call through
// another name is not seen: the limit of the check
// (src/md/features/desktop_to_browser.md, "The budgets").
resizable_calls_read :: proc(file: ^ast.File, calls: ^[dynamic]Resizable_Call) {
	visit :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
		if node == nil {
			return nil
		}
		call, is_call := node.derived.(^ast.Call_Expr)
		if !is_call {
			return visitor
		}
		name := ""
		#partial switch callee in call.expr.derived {
		case ^ast.Selector_Expr:
			name = callee.field.name
		case ^ast.Ident:
			name = callee.name
		}
		if name != "resizable_set" {
			return visitor
		}
		calls := (^[dynamic]Resizable_Call)(visitor.data)
		found := Resizable_Call{line = call.pos.line, file = call.pos.file}
		if len(call.args) == 2 {
			if literal, is_literal := call.args[1].derived.(^ast.Comp_Lit); is_literal {
				found.readable = true
				for element in literal.elems {
					field_value, is_field := element.derived.(^ast.Field_Value)
					if !is_field {
						continue
					}
					field, _ := field_value.field.derived.(^ast.Ident)
					value, _ := field_value.value.derived.(^ast.Ident)
					if field == nil {
						continue
					}
					index := -1
					switch field.name {
					case "least_width":
						index = 0
					case "least_height":
						index = 1
					}
					if index >= 0 && value != nil {
						found.least_names[index] = value.name
					}
				}
			}
		}
		append(calls, found)
		return visitor
	}
	visitor := ast.Visitor{visit = visit, data = calls}
	for declaration in file.decls {
		ast.walk(&visitor, declaration)
	}
}

// budget_resizable_check compares the least parts of a stated budget with
// each call of resizable_set in its package: the same constants, so that
// the cut of the window pages follows the least size that the window sets.
// A budget with no least parts is counted with no cut and needs no check.
budget_resizable_check :: proc(budget: ^Budget_Description, calls: []Resizable_Call) -> bool {
	if !budget.stated || budget.window_names[2] == "" {
		return true
	}
	if len(calls) == 0 {
		fmt.eprintfln("modustool: describe %s(%d): %s states the least size %s x %s, and the package has no call of display.resizable_set: a window that is not resizable keeps its size at each scale, so its window pages are not cut; remove the least parts", budget.file, budget.line, BUDGET_REQUEST_NAME, budget.window_names[2], budget.window_names[3])
		return false
	}
	for call in calls {
		if !call.readable {
			fmt.eprintfln("modustool: describe %s(%d): the call of resizable_set passes a record that is not a literal, so the tool cannot compare its least size with the least parts of %s: pass display.Size_Limits{least_width = %s, least_height = %s, ...}", call.file, call.line, BUDGET_REQUEST_NAME, budget.window_names[2], budget.window_names[3])
			return false
		}
		if call.least_names[0] != budget.window_names[2] || call.least_names[1] != budget.window_names[3] {
			fmt.eprintfln("modustool: describe %s(%d): the call of resizable_set passes the least size %s x %s, and %s states %s x %s: name the same constants, so that the count of the window pages follows the least size that the window sets", call.file, call.line, or_else_text(call.least_names[0]), or_else_text(call.least_names[1]), BUDGET_REQUEST_NAME, budget.window_names[2], budget.window_names[3])
			return false
		}
	}
	return true
}

@(private = "file")
or_else_text :: proc(name: string) -> string {
	return name == "" ? "(not a name)" : name
}

// declaration_names says if one of the names of a declaration is name.
@(private = "file")
declaration_names :: proc(declaration: ^ast.Value_Decl, name: string) -> bool {
	for expression in declaration.names {
		if identifier, is_identifier := expression.derived.(^ast.Ident); is_identifier && identifier.name == name {
			return true
		}
	}
	return false
}

// budget_request_in_when gives a declaration of BUDGET_REQUEST_NAME in a
// `when` of the top level of a file, in its body or in its else, at any
// depth of blocks and of `when`s; nil when there is none.
@(private = "file")
budget_request_in_when :: proc(statement: ^ast.Stmt) -> ^ast.Value_Decl {
	if statement == nil {
		return nil
	}
	#partial switch item in statement.derived {
	case ^ast.Value_Decl:
		if declaration_names(item, BUDGET_REQUEST_NAME) {
			return item
		}
	case ^ast.When_Stmt:
		if found := budget_request_in_when(item.body); found != nil {
			return found
		}
		return budget_request_in_when(item.else_stmt)
	case ^ast.Block_Stmt:
		for inner in item.stmts {
			if found := budget_request_in_when(inner); found != nil {
				return found
			}
		}
	}
	return nil
}

// markdown_of gives the Markdown of a comment, as its author wrote it: the
// lines of the comment with "//" and one space taken away, and no empty
// line at its start or at its end (docs/SITE.md, "The Markdown of a source
// comment"). The site renders it.
markdown_of :: proc(docs: ^ast.Comment_Group) -> string {
	if docs == nil {
		return ""
	}
	comment := ""
	for token in docs.list {
		if !strings.has_prefix(token.text, "//") {
			continue
		}
		_, line, _ := foundation.markdown_comment_line(token.text)
		comment = foundation.markdown_comment_add(comment, line)
	}
	return foundation.markdown_comment_end(comment)
}

// text_of gives the documentation text of a comment that a module carries
// (module.Documentation says the form): its Markdown, as its author wrote
// it. The line of help is its first sentence with the marks removed
// (about_of, documentation_text_of_markdown).
text_of :: proc(docs: ^ast.Comment_Group) -> string {
	return markdown_of(docs)
}

// about_of gives the first sentence of a documentation text, without the
// name of the export at its start and without the period at its end.
about_of :: proc(documentation: string, name: string) -> string {
	text := documentation
	if end := strings.index_byte(text, '\n'); end >= 0 {
		text = text[:end]
	}
	if end := strings.index(text, ". "); end >= 0 {
		text = text[:end]
	}
	text = strings.trim_suffix(text, ".")
	if name != "" && strings.has_prefix(text, name) && len(text) > len(name) && text[len(name)] == ' ' {
		text = text[len(name) + 1:]
	}
	return strings.trim_space(text)
}

// field_value gives the text of one field of a record, by its field kind:
// a hexadecimal Integer after "0x" with two digits for each byte, a status
// by the name of its member (its number when it names none), a hash in
// hexadecimal, the values of a fact in hexadecimal up to their last byte
// that is not zero, as the raw form of a fact; 16 digits, the head of a
// hash, hundredths and nanoseconds as microseconds as a sentence writes
// them.
field_value :: proc(record: []u8, item: module.Field) -> string {
	// A byte that names no type or no kind has no value: "?", as a field
	// of no value.
	type, type_ok := module.field_type(item)
	kind, kind_ok := module.field_kind(item)
	if !type_ok || !kind_ok {
		return "?"
	}
	// The kinds whose form the kind alone decides: the text of the sentence
	// of a fact, from the one writer of the contract.
	written: [module.FACT_SENTENCE_BYTES_MOST]u8
	if text, _, by_kind := module.field_kind_text(written[:], record, item); by_kind {
		return strings.clone(text, context.temp_allocator)
	}
	switch type {
	case .None, .Record, .Table, .Enum:
		// record_type refuses a field of these types: it has no value.
	case .Bytes:
		bytes := module.field_bytes(record, item)
		if bytes == nil {
			return "?"
		}
		if kind == .Fact_Values || kind == .Log_Body {
			for len(bytes) > 0 && bytes[len(bytes) - 1] == 0 {
				bytes = bytes[:len(bytes) - 1]
			}
		}
		digits := strings.builder_make(context.temp_allocator)
		for value in bytes {
			fmt.sbprintf(&digits, "%02x", value)
		}
		return strings.to_string(digits)
	case .Integer:
		if u64(item.offset) + u64(module.field_size(item)) <= u64(len(record)) {
			value := module.field_integer(record, item)
			switch kind {
			case .Hexadecimal:
				// Two digits for each byte of the field, as the console
				// writes it: the width says the size.
				alphabet := "0123456789abcdef"
				digits := strings.builder_make(context.temp_allocator)
				strings.write_string(&digits, "0x")
				for index := 2 * int(module.field_size(item)) - 1; index >= 0; index -= 1 {
					strings.write_byte(&digits, alphabet[u64(value) >> (4 * u64(index)) & 0xF])
				}
				return strings.to_string(digits)
			case .Status:
				which, which_ok := module.field_contract_enum(item)
				if name, named := module.contract_enum_member_name(which, u64(value)); which_ok && named {
					return name
				}
			case .Plain, .Module_Name, .Hash, .Fact_Values, .Hash_Head, .Text_View, .Log_Body:
				// A decimal number: record_type refuses each of them but
				// Plain on an Integer.
			case .Hexadecimal_Sixteen_Digits, .Hundredths, .Nanoseconds_As_Microseconds, .Tenths, .Hexadecimal_No_Leading_Zero, .Time_Of_Day:
				// module.field_kind_text wrote them above.
			}
			return fmt.tprintf("%d", value)
		}
	case .Handle:
		if u64(item.offset) + 4 <= u64(len(record)) {
			return fmt.tprintf("0x%x", (^u32)(&record[item.offset])^)
		}
	case .Text:
		return module.field_text(record, item)
	}
	return "?"
}

