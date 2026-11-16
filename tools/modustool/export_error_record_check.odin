package modustool

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:slice"
import "core:strings"

// Each export that fails gives an error record (src/md/api/export_error_records.md).
// A negative result is not always a failure: math.number("-5") is -5. So
// the check does not refuse a negative result; it reads the forms of a
// `return` that give a failure with no record: a negative constant, a
// negated status, or a helper of the same package that gives one.

EXPORT_ERROR_RECORD_FOLDERS :: [?]string{SOURCE_FOLDER_PROGRAMS, SOURCE_FOLDER_MODULES}

// The name of the last parameter of an export that has an error record.
EXPORT_ERROR_RECORD_PARAMETER :: "error"

// One source file of one package, as the check reads it.
Export_Source :: struct {
	path: string,
	text: string,
}

// One `return` of an export that fails with a negative number and gives no
// error record.
Export_Without_Error_Record :: struct {
	file:   string,
	line:   int,
	export: string, // The name of the export in its module.
}

// The procedures and the constants of one package, and what the check
// already knows of each procedure.
@(private = "file")
Negative_Search :: struct {
	procedures: map[string]^ast.Proc_Lit,
	// Each constant of the package: true when its value is a minus before a
	// literal.
	constants:  map[string]bool,
	states:     map[string]Negative_State,
}

@(private = "file")
Negative_State :: enum {
	Searching, // On the path of the search now: a cycle of calls counts as no failure.
	Negative,
	Not_Negative,
}

// The types that a conversion of an integer names: the value inside keeps
// its sign.
@(private = "file")
INTEGER_TYPE_NAMES :: [?]string{"i64", "int", "i32", "i16", "i8", "i128"}

// exports_without_error_record_of_package reads the source files of one
// package, and appends each `return` of an export that gives a failing
// result with no error record. export_count: the exports that the check
// read, each export with an i64 result and no error record.
exports_without_error_record_of_package :: proc(sources: []Export_Source, found: ^[dynamic]Export_Without_Error_Record) -> (export_count: int, ok: bool) {
	context.allocator = context.temp_allocator
	search := Negative_Search {
		procedures = make(map[string]^ast.Proc_Lit),
		constants  = make(map[string]bool),
		states     = make(map[string]Negative_State),
	}
	Export_Read :: struct {
		name:    string,
		file:    string,
		literal: ^ast.Proc_Lit,
	}
	exports := make([dynamic]Export_Read)
	for source in sources {
		file := ast.new_from_positions(ast.File, {}, {})
		file.src = source.text
		file.fullpath = source.path
		reader := parser.default_parser()
		if !parser.parse_file(&reader, file) {
			fmt.eprintfln("modustool: %s: the parser found errors", source.path)
			return 0, false
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
			literal, is_procedure := declaration.values[0].derived.(^ast.Proc_Lit)
			if !is_procedure {
				if !declaration.is_mutable {
					search.constants[identifier.name] = expression_is_negative_literal(declaration.values[0])
				}
				continue
			}
			search.procedures[identifier.name] = literal
			if name, exported := export_name_of_declaration(declaration, identifier.name); exported && export_needs_a_check(literal, name) {
				append(&exports, Export_Read{name = name, file = source.path, literal = literal})
			}
		}
	}
	for read in exports {
		export_count += 1
		for item in return_statements_of(read.literal.body) {
			if len(item.results) == 1 && expression_is_negative(&search, item.results[0]) {
				append(found, Export_Without_Error_Record{file = read.file, line = item.pos.line, export = read.name})
			}
		}
	}
	return export_count, true
}

// export_name_of_declaration gives the name of an export: its link name,
// or the name of the declaration. exported: the declaration has the
// attribute export.
@(private = "file")
export_name_of_declaration :: proc(declaration: ^ast.Value_Decl, declared: string) -> (name: string, exported: bool) {
	name = declared
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
	return name, exported
}

// export_needs_a_check says if the check reads an export: it has a body,
// an i64 result and no error record, and it is not the entry, whose
// result is the code of the end of the program.
@(private = "file")
export_needs_a_check :: proc(literal: ^ast.Proc_Lit, name: string) -> bool {
	if literal.body == nil || name == ENTRY_NAME || literal.type == nil || literal.type.results == nil {
		return false
	}
	results := literal.type.results.list
	if len(results) != 1 || results[0].type == nil {
		return false
	}
	result_type, is_identifier := results[0].type.derived.(^ast.Ident)
	if !is_identifier || result_type.name != "i64" {
		return false
	}
	if literal.type.params != nil {
		for field in literal.type.params.list {
			for parameter in field.names {
				if identifier, is_name := parameter.derived.(^ast.Ident); is_name && identifier.name == EXPORT_ERROR_RECORD_PARAMETER {
					return false
				}
			}
		}
	}
	return true
}

// return_statements_of gives each `return` of a body, and none of a
// procedure literal inside it: that `return` ends the inner procedure.
@(private = "file")
return_statements_of :: proc(body: ^ast.Stmt) -> []^ast.Return_Stmt {
	statements := make([dynamic]^ast.Return_Stmt, context.temp_allocator)
	visitor := ast.Visitor {
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			#partial switch item in node.derived {
			case ^ast.Proc_Lit:
				return nil
			case ^ast.Return_Stmt:
				append((^[dynamic]^ast.Return_Stmt)(visitor.data), item)
			}
			return visitor
		},
		data = &statements,
	}
	ast.walk(&visitor, body)
	return statements[:]
}

// expression_is_negative_literal says if a value is a minus before a
// literal: the value of a negative constant.
@(private = "file")
expression_is_negative_literal :: proc(expression: ^ast.Expr) -> bool {
	unary, is_unary := expression.derived.(^ast.Unary_Expr)
	if !is_unary || unary.op.kind != .Sub || unary.expr == nil {
		return false
	}
	_, is_literal := unary.expr.derived.(^ast.Basic_Lit)
	return is_literal
}

// expression_is_negative says if the value of a `return` is a failing
// result: the forms of src/md/api/export_error_records.md, "The chosen form".
// A minus before a variable is an answer, not a failure: math.number
// negates the number that it read.
@(private = "file")
expression_is_negative :: proc(search: ^Negative_Search, expression: ^ast.Expr) -> bool {
	if expression == nil {
		return false
	}
	#partial switch item in expression.derived {
	case ^ast.Paren_Expr:
		return expression_is_negative(search, item.expr)
	case ^ast.Unary_Expr:
		if item.op.kind != .Sub || item.expr == nil {
			return false
		}
		#partial switch operand in item.expr.derived {
		case ^ast.Basic_Lit, ^ast.Call_Expr:
			return true
		case ^ast.Ident:
			_, is_constant := search.constants[operand.name]
			return is_constant
		}
		return false
	case ^ast.Ident:
		return search.constants[item.name]
	case ^ast.Ternary_If_Expr:
		return expression_is_negative(search, item.x) || expression_is_negative(search, item.y)
	case ^ast.Ternary_When_Expr:
		return expression_is_negative(search, item.x) || expression_is_negative(search, item.y)
	case ^ast.Call_Expr:
		callee, is_identifier := item.expr.derived.(^ast.Ident)
		if !is_identifier {
			return false
		}
		integer_types := INTEGER_TYPE_NAMES
		if len(item.args) == 1 && slice.contains(integer_types[:], callee.name) {
			return expression_is_negative(search, item.args[0])
		}
		return procedure_gives_negative(search, callee.name)
	}
	return false
}

// procedure_gives_negative says if a procedure of the package has a
// `return` of a failing result. A name that is no procedure of the package
// (a procedure of another package, a built-in procedure) gives false.
@(private = "file")
procedure_gives_negative :: proc(search: ^Negative_Search, name: string) -> bool {
	if state, known := search.states[name]; known {
		return state == .Negative
	}
	literal, found := search.procedures[name]
	if !found || literal.body == nil {
		return false
	}
	search.states[name] = .Searching
	negative := false
	for item in return_statements_of(literal.body) {
		if len(item.results) == 1 && expression_is_negative(search, item.results[0]) {
			negative = true
			break
		}
	}
	search.states[name] = negative ? .Negative : .Not_Negative
	return negative
}

// exports_without_error_record_of_tree reads each package of the programs
// and of the modules under a root ("" is the repository).
exports_without_error_record_of_tree :: proc(root: string) -> (found: []Export_Without_Error_Record, package_count: int, export_count: int, ok: bool) {
	files := make([dynamic]string, context.temp_allocator)
	folders := EXPORT_ERROR_RECORD_FOLDERS
	for folder in folders {
		source_files_of_a_folder(root == "" ? folder : join(root, "/", folder), &files) or_return
	}
	slice.sort(files[:])
	// One package is the files of one folder: the files of a folder under it
	// are another package.
	packages := make(map[string][dynamic]Export_Source, context.temp_allocator)
	for file in files {
		if source_is_a_test(file) {
			continue
		}
		text, read_ok := site_read_quiet(file)
		if !read_ok {
			fmt.eprintfln("modustool: cannot read %s", file)
			return nil, 0, 0, false
		}
		folder := file[:max(strings.last_index_byte(file, '/'), 0)]
		sources, known := packages[folder]
		if !known {
			sources = make([dynamic]Export_Source, context.temp_allocator)
		}
		append(&sources, Export_Source{path = file, text = text})
		packages[folder] = sources
	}
	package_folders := make([dynamic]string, context.temp_allocator)
	for folder in packages {
		append(&package_folders, folder)
	}
	// The order of a map changes from run to run; the lines of the check do not.
	slice.sort(package_folders[:])
	list := make([dynamic]Export_Without_Error_Record, context.temp_allocator)
	for folder in package_folders {
		count := exports_without_error_record_of_package(packages[folder][:], &list) or_return
		export_count += count
		package_count += 1
	}
	return list[:], package_count, export_count, true
}

// export_error_record_check refuses an export that fails with a negative
// number and gives no error record.
export_error_record_check :: proc() -> bool {
	found, package_count, export_count, ok := exports_without_error_record_of_tree("")
	if !ok {
		return false
	}
	for item in found {
		fmt.eprintfln("modustool: %s:%d: the export %s gives a negative number with no error record: give it the last parameter error: ^errors.Error_Record, and write the record on this path with errors.fail (docs/MODULE_CONTRACT.md, \"8. Errors that diagnose\")", item.file, item.line, item.export)
	}
	if len(found) > 0 {
		fmt.eprintfln("modustool: test failed: %d returns of exports give a negative number with no error record", len(found))
		return false
	}
	test_passed_print("each export that fails gives an error record (%d exports with an integer result and no error record read in %d packages)", export_count, package_count)
	return true
}
