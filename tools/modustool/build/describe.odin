package build

import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "core:reflect"
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
//     lends, with the rights that the callee needs (src/library/support/system).
//   - A parameter of type ^Table_To_Read(Name), ^Table_To_Change(Name) or
//     ^Table_To_Append(Name) is a Table of the record Name with the
//     direction of its name; ^Bytes_To_Read, ^Bytes_To_Change and
//     ^Bytes_To_Append are Bytes (src/library/support/system, docs/MODULE_CONTRACT.md
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
//     literal; a part left out 0; a comment before it that gives the
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
	// The structs of all the files first: an export of one file can use a
	// struct of another file.
	for path in foundation.files_with_suffix(folder, ".odin") or_return {
		if strings.has_suffix(path, "_test.odin") {
			continue
		}
		source := foundation.read_file(path) or_return
		file := parse_source(path, string(source), &state) or_return
		budget_request_read(file, &description.budget) or_return
		integer_constants_read(file, &integer_constants)
		append(&files, file)
		if markdown := markdown_of(file.docs); description.markdown == "" {
			description.markdown = markdown
			description.text = markdown
		}
	}
	budget_window_resolve(&description.budget, integer_constants) or_return
	for file in files {
		describe_file(file, &list, &state) or_return
	}
	description.records = state.records[:]
	for item, index in list {
		for other in list[:index] {
			if other.name == item.name {
				fmt.eprintfln("modustool: describe %s: two exports have the name %s", folder, item.name)
				return {}, false
			}
		}
	}
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

// What the tool keeps while it reads a package.
Describe_State :: struct {
	structs: map[string]Struct_Source, // By name; a struct of an imported package by "package.Name".
	imports: map[string]string, // The folder of each package that the files import, by the name that the files use.
	read:    map[string]bool, // The imported packages whose structs are in `structs`.
	enums:   map[string]string, // The backing type of each enum, by name as `structs`.
	records: [dynamic]Record_Description, // The records that an export uses, each one time.
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
		state.enums = make(map[string]string, context.temp_allocator)
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
		if type, is_enum := declaration.values[0].derived.(^ast.Enum_Type); is_enum && type.base_type != nil {
			state.enums[key] = type_text(file.src, type.base_type)
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
		if strings.has_suffix(path, "_test.odin") {
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
// contract package package_name (the folder under src/library/contract),
// through an import of that package under any name. "" for another type: a
// type of the same name in another package is not the type of the
// contract.
@(private = "file")
contract_type_name :: proc(state: ^Describe_State, type: ^ast.Expr, package_name: string) -> string {
	selector, is_selector := type.derived.(^ast.Selector_Expr)
	if !is_selector {
		return ""
	}
	library, is_name := selector.expr.derived.(^ast.Ident)
	if !is_name {
		return ""
	}
	folder, imported := state.imports[library.name]
	if !imported || folder != strings.concatenate({foundation.SOURCE_FOLDER_CONTRACT, "/", package_name}, context.temp_allocator) {
		return ""
	}
	return selector.field.name
}

// field_kind_field reads the type of a field of a record that states a
// field kind: a type of value_kinds.FIELD_KIND_TYPES, or a contract enum of
// value_kinds.CONTRACT_ENUM_TYPES (a Status). It gives the field with its
// type, its kind and its detail, and its size and its alignment.
// is_kind is false for another type.
@(private = "file")
field_kind_field :: proc(state: ^Describe_State, type: ^ast.Expr) -> (item: Field_Description, size, alignment: u32, is_kind: bool) {
	if row, found := value_kinds.field_kind_of_type_name(contract_type_name(state, type, "value_kinds")); found {
		switch row.kind {
		case .Hexadecimal:
			// 8 bytes keep the detail 0 of the fields before the sizes.
			return {type = .Integer, detail = row.size == 8 ? 0 : row.size, unsigned = true, kind = .Hexadecimal}, row.size, row.size, true
		case .Module_Name:
			return {type = .Text, detail = row.size, kind = .Module_Name}, row.size, 1, true
		case .Hash:
			return {type = .Bytes, detail = row.size, kind = .Hash}, row.size, 1, true
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
		if contract_type_name(state, type, row.package_name) != row.name {
			continue
		}
		enum_size := op.CONTRACT_ENUM_SIZES[which]
		return {type = .Integer, detail = enum_size == 8 ? 0 : enum_size, unsigned = true, kind = .Status, contract_enum = which}, enum_size, enum_size, true
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
	if base, is_enum := state.enums[strings.concatenate({prefix, text}, context.temp_allocator)]; is_enum {
		return integer_size(state, prefix, base)
	}
	if base, is_enum := state.enums[text]; is_enum {
		return integer_size(state, "", base)
	}
	return 0, false
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
// knows.
@(private = "file")
struct_record :: proc(state: ^Describe_State, type: ^ast.Expr, result: bool) -> (number: u32, is_record, ok: bool) {
	key, record_name := struct_name(state, type)
	found, has_struct := state.structs[key]
	if key == "" || !has_struct {
		return 0, false, false
	}
	declared := found.type
	if declared.is_packed || declared.is_raw_union || declared.align != nil || declared.poly_params != nil || declared.fields == nil || len(declared.fields.list) == 0 {
		return 0, true, describe_fail(found.path, declared, "the record %s must have fields, and the layout of the C language: no #packed, no #align, no parameter", record_name)
	}
	fields := make([dynamic]Field_Description, context.temp_allocator)
	size, alignment: u32 = 0, 1
	has_handle := false
	for field in declared.fields.list {
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
		} else if kind_item, kind_size, kind_alignment, is_kind := field_kind_field(state, field.type); is_kind {
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
			return 0, true, describe_fail(found.path, field, "the record %s: the type %s has no description. A field is an integer (i64, u64, i32, u32, i16, u16, i8, u8, or an enum of one of them), an integer with a unit (value_kinds.Size_In_Pages and the other types of value_kinds), a field with a kind (value_kinds.Hexadecimal_32, value_kinds.Module_Name_Field, value_kinds.Hash_Field and the other types of value_kinds.FIELD_KIND_TYPES, or a contract enum such as operation.Log_Level), a Lent({{...}}) (Handle) or a [N]u8 (Text)", record_name, type_text(found.source, field.type))
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
describe_source :: proc(path, source: string, list: ^[dynamic]Export_Description, package_text: ^string = nil, records: ^[]Record_Description = nil) -> bool {
	context.allocator = context.temp_allocator
	state: Describe_State
	state.records = make([dynamic]Record_Description, context.temp_allocator)
	state.structs = make(map[string]Struct_Source, context.temp_allocator)
	file := parse_source(path, source, &state) or_return
	if package_text != nil {
		package_text^ = text_of(file.docs)
	}
	describe_file(file, list, &state) or_return
	if records != nil {
		records^ = state.records[:]
	}
	return true
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
		for attribute in declaration.attributes {
			for element in attribute.elems {
				#partial switch item in element.derived {
				case ^ast.Ident:
					exported |= item.name == "export"
				case ^ast.Field_Value:
					field, is_field := item.field.derived.(^ast.Ident)
					literal, is_literal := item.value.derived.(^ast.Basic_Lit)
					if is_field && is_literal && field.name == "link_name" {
						name = strings.trim(literal.tok.text, "\"`")
					}
				}
			}
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
		result_text := ""
		if type.results != nil {
			if len(type.results.list) != 1 || len(type.results.list[0].names) > 1 || type.results.list[0].type == nil {
				return describe_fail(path, declaration, "%s has more than one result", name)
			}
			result_text = type_text(source, type.results.list[0].type)
		}

		if name == ENTRY_NAME {
			address := len(fields) == 1 && len(fields[0].names) == 1 && fields[0].type != nil
			if address {
				text := type_text(source, fields[0].type)
				address = text == "rawptr" || strings.has_prefix(text, "^")
			}
			if !address || result_text != "" && result_text != "i64" {
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
		switch {
		case description.result == .Record:
			if result_text != "" {
				return describe_fail(path, declaration, "%s: the callee writes a Record result in the memory of the caller: the export has no result type", name)
			}
		case result_text == "i64":
			if description.result != .Text && description.result != .Table {
				description.result = .Integer
			}
		case result_text != "":
			return describe_fail(path, declaration, "%s: the result type %s has no description. Use i64", name, result_text)
		case description.result == .Text:
			return describe_fail(path, declaration, "%s: a Text result gives its count of bytes: the result type is i64", name)
		case description.result == .Table:
			return describe_fail(path, declaration, "%s: a Table result gives its count of records: the result type is i64", name)
		}
		if description.error_record != 0 && (description.result == .Record || description.result == .None) {
			return describe_fail(path, declaration, "%s: an export with an error record gives an i64 result: it fails when the result is negative", name)
		}
		if arguments := module.call_argument_count(len(parameters), u8(description.result), description.error_record != 0); arguments > module.PARAMETER_CAPACITY {
			return describe_fail(path, declaration, "%s takes %d arguments in the call form, the buffer of a result and the error record included; an export takes at most %d", name, arguments, module.PARAMETER_CAPACITY)
		}
		description.parameters = parameters[:]
		description.names = names[:]
		description.details = details[:]
		description.directions = directions[:]
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

// The constant of a source that states the budget of its module
// (docs/MODULE_CONTRACT.md, "The budget that a module asks for").
BUDGET_REQUEST_NAME :: "MODULE_BUDGET"

// The largest width and the largest height of a window part: the limit of
// a surface of display.open. A larger part is a fault of the source, and
// the product of two parts stays far from the end of 64 bits.
BUDGET_WINDOW_PART_LIMIT :: 2048

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
	FORM :: "the form is " + BUDGET_REQUEST_NAME + " :: system.Stated_Budget{working_memory_pages = N, processes = N, threads = N, window_width = WIDTH, window_height = HEIGHT}"
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
		window_names: [2]string
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
			case:
				return describe_fail(path, element, "%s has no part %s: its parts are working_memory_pages, processes, threads, window_width and window_height; the tool counts the other pages, and processor time and log records are limits that the starter sets", BUDGET_REQUEST_NAME, field.name)
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
	places := [2]^u64{&budget.parts.window_width, &budget.parts.window_height}
	part_names := [2]string{"window_width", "window_height"}
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
	return true
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
// hexadecimal.
field_value :: proc(record: []u8, item: module.Field) -> string {
	// A byte that names no type or no kind has no value: "?", as a field
	// of no value.
	type, type_ok := module.field_type(item)
	kind, kind_ok := module.field_kind(item)
	if !type_ok || !kind_ok {
		return "?"
	}
	switch type {
	case .None, .Record, .Table:
		// record_type refuses a field of these types: it has no value.
	case .Bytes:
		bytes := module.field_bytes(record, item)
		if bytes == nil {
			return "?"
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
				if name, named := op.contract_enum_member_name(which, u64(value)); which_ok && named {
					return name
				}
			case .Plain, .Module_Name, .Hash:
				// A decimal number: record_type refuses the two last on an
				// Integer.
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

