package checks

import "core:fmt"
import "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:slice"
import "core:strings"
import "modustool:foundation"

// The check of the package variables whose value the compiler cannot
// make constant data (docs/MODULE_CONTRACT.md, "Package variables are
// constant data at the load").
//
// The compiler puts such an initializer into a procedure that the runtime
// of a program calls at its start, `__$startup_runtime`. A module with an
// entry has no such start: the loader maps its data as the file holds it,
// and the entry runs first. The rule holds for each source of the system. So a variable whose initializer takes a slice
// or the address of another variable, or reads another variable of its
// package, stays zero on the machine, and the same code gives the right
// value in a host test, which starts as a program. A table of nested
// slices is written with the slices as literals inside it, which the
// compiler makes constant data with a rebase for each address.
//
// The check reads each source of the system that is not a test and not
// for the host alone, one folder as one package, the bodies of the when
// blocks too. It refuses in the initializer of each package variable:
//
// - a slice expression, and the operator &;
// - a name of a package variable of the same package;
// - a name of another package that starts with a small letter (a variable
//   or a procedure: its constants and its types start with a capital);
// - a call, except a conversion to a type and the built-ins that the
//   compiler folds (size_of, align_of, offset_of, len, min, max) and a
//   directive (#load);
// - a literal of a map or of a dynamic array;
// - a value of the type any.
//
// The body of a procedure literal runs when it is called: it is not read.

GLOBAL_INITIALIZER_CHECKED_FOLDERS :: [?]string {
	foundation.SOURCE_FOLDER_KERNEL,
	foundation.SOURCE_FOLDER_BOOT,
	foundation.SOURCE_FOLDER_MODULES,
	foundation.SOURCE_FOLDER_LIBRARY,
}

// One package variable whose initializer needs a start of the runtime.
Global_Initializer_Use :: struct {
	file:     string,
	line:     int,
	variable: string,
	what:     string, // What the initializer does: a slice, an address, or the name that it reads.
}

// The built-in procedures whose call the compiler folds into a constant.
@(private = "file")
CONSTANT_BUILTINS :: [?]string{"size_of", "align_of", "offset_of", "len", "min", "max"}

// The built-in types: a call whose callee is a type is a conversion.
@(private = "file")
BUILTIN_TYPES :: [?]string {
	"bool", "b8", "b16", "b32", "b64", "byte", "rune", "string", "cstring", "rawptr", "uintptr", "typeid",
	"int", "uint", "i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128",
	"i16le", "i32le", "i64le", "u16le", "u32le", "u64le", "i16be", "i32be", "i64be", "u16be", "u32be", "u64be",
	"f16", "f32", "f64", "f16le", "f32le", "f64le", "f16be", "f32be", "f64be",
	"complex32", "complex64", "complex128", "quaternion64", "quaternion128", "quaternion256",
}

@(private = "file")
Initializer_Walk :: struct {
	file:      string,
	variable:  string,
	variables: ^map[string]bool,
	types:     ^map[string]bool, // The types that the package declares.
	imports:   ^map[string]bool, // The names of the imported packages of the file.
	uses:      ^[dynamic]Global_Initializer_Use,
}

@(private = "file")
refuse :: proc(walk: ^Initializer_Walk, line: int, what: string) {
	append(walk.uses, Global_Initializer_Use{file = walk.file, line = line, variable = walk.variable, what = what})
}

@(private = "file")
name_is_in :: proc(name: string, names: []string) -> bool {
	for each in names {
		if each == name {
			return true
		}
	}
	return false
}

// callee_is_constant says if a call is a conversion or a built-in that the
// compiler folds: a type, a type of another package (whose name starts
// with a capital letter, as each type of the system), or a directive.
@(private = "file")
callee_is_constant :: proc(walk: ^Initializer_Walk, callee: ^ast.Expr) -> bool {
	builtins := CONSTANT_BUILTINS
	types := BUILTIN_TYPES
	#partial switch item in callee.derived {
	case ^ast.Ident:
		return name_is_in(item.name, builtins[:]) || name_is_in(item.name, types[:]) || walk.types[item.name]
	case ^ast.Selector_Expr:
		base, is_ident := item.expr.derived.(^ast.Ident)
		return is_ident && walk.imports[base.name] && item.field != nil && len(item.field.name) > 0 && item.field.name[0] >= 'A' && item.field.name[0] <= 'Z'
	case ^ast.Basic_Directive, ^ast.Pointer_Type, ^ast.Multi_Pointer_Type, ^ast.Array_Type, ^ast.Dynamic_Array_Type, ^ast.Distinct_Type, ^ast.Typeid_Type, ^ast.Proc_Type, ^ast.Struct_Type, ^ast.Union_Type, ^ast.Enum_Type, ^ast.Bit_Set_Type, ^ast.Matrix_Type:
		return true
	case ^ast.Paren_Expr:
		return callee_is_constant(walk, item.expr)
	}
	return false
}

@(private = "file")
expression_text :: proc(walk: ^Initializer_Walk, expression: ^ast.Expr) -> string {
	#partial switch item in expression.derived {
	case ^ast.Ident:
		return item.name
	case ^ast.Selector_Expr:
		if base, is_ident := item.expr.derived.(^ast.Ident); is_ident && item.field != nil {
			return strings.concatenate({base.name, ".", item.field.name}, context.temp_allocator)
		}
	}
	return "a procedure"
}

@(private = "file")
initializer_visit :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return nil
	}
	walk := (^Initializer_Walk)(visitor.data)
	#partial switch item in node.derived {
	case ^ast.Proc_Lit:
		// A procedure literal runs when it is called: its body is no
		// initializer.
		return nil
	case ^ast.Slice_Expr:
		refuse(walk, item.pos.line, "a slice expression")
		return nil
	case ^ast.Unary_Expr:
		if item.op.kind == .And {
			refuse(walk, item.pos.line, "an address (&)")
			return nil
		}
	case ^ast.Call_Expr:
		if !callee_is_constant(walk, item.expr) {
			refuse(walk, item.pos.line, strings.concatenate({"a call of ", expression_text(walk, item.expr)}, context.temp_allocator))
			return nil
		}
		for argument in item.args {
			ast.walk(visitor, argument)
		}
		return nil
	case ^ast.Comp_Lit:
		if item.type != nil {
			#partial switch kind in item.type.derived {
			case ^ast.Map_Type:
				refuse(walk, item.pos.line, "a literal of a map")
				return nil
			case ^ast.Dynamic_Array_Type:
				refuse(walk, item.pos.line, "a literal of a dynamic array")
				return nil
			}
		}
		for element in item.elems {
			ast.walk(visitor, element)
		}
		return nil
	case ^ast.Selector_Expr:
		// A name of another package that starts with a small letter: a
		// variable or a procedure, which the check cannot tell apart, so it
		// refuses both. Its constants and its types start with a capital.
		if base, is_ident := item.expr.derived.(^ast.Ident); is_ident && walk.imports[base.name] {
			if item.field != nil && len(item.field.name) > 0 && item.field.name[0] >= 'a' && item.field.name[0] <= 'z' {
				refuse(walk, item.pos.line, strings.concatenate({"the name ", base.name, ".", item.field.name, " of another package"}, context.temp_allocator))
			}
			return nil
		}
		// value.field: only the left side can name a variable.
		ast.walk(visitor, item.expr)
		return nil
	case ^ast.Field_Value:
		// The name of a field of a literal is no variable.
		ast.walk(visitor, item.value)
		return nil
	case ^ast.Implicit_Selector_Expr:
		return nil
	case ^ast.Ident:
		if walk.variables[item.name] {
			refuse(walk, item.pos.line, strings.concatenate({"the package variable ", item.name}, context.temp_allocator))
		}
	}
	return visitor
}

// Parsed_Source is one source of a package, kept for the second pass.
@(private = "file")
Parsed_Source :: struct {
	file:    string,
	tree:    ^ast.File,
	imports: map[string]bool,
}

// declarations_of gives the declarations of a list, and of the body of each
// when block in it, at any depth: a when block declares package
// variables too.
@(private = "file")
declarations_of :: proc(statements: []^ast.Stmt, into: ^[dynamic]^ast.Value_Decl) {
	for statement in statements {
		#partial switch item in statement.derived {
		case ^ast.Value_Decl:
			append(into, item)
		case ^ast.When_Stmt:
			when_bodies(item, into)
		}
	}
}

@(private = "file")
when_bodies :: proc(item: ^ast.When_Stmt, into: ^[dynamic]^ast.Value_Decl) {
	if block, is_block := item.body.derived.(^ast.Block_Stmt); is_block {
		declarations_of(block.stmts, into)
	}
	if item.else_stmt == nil {
		return
	}
	#partial switch other in item.else_stmt.derived {
	case ^ast.Block_Stmt:
		declarations_of(other.stmts, into)
	case ^ast.When_Stmt:
		when_bodies(other, into)
	}
}

// global_initializer_uses_of_package reads the sources of one package: the
// names of its package variables and of its types first, then the
// initializer of each variable. sources holds a path and its text for each
// file. false: a file does not parse.
global_initializer_uses_of_package :: proc(sources: [][2]string) -> (uses: []Global_Initializer_Use, ok: bool) {
	list := make([dynamic]Global_Initializer_Use, context.temp_allocator)
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return nil, false
	}
	defer virtual.arena_destroy(&arena)
	{
		context.allocator = virtual.arena_allocator(&arena)
		parsed := make([dynamic]Parsed_Source)
		variables := make(map[string]bool)
		types := make(map[string]bool)
		for source in sources {
			tree := ast.new_from_positions(ast.File, {}, {})
			tree.src = source[1]
			tree.fullpath = source[0]
			reader := parser.default_parser()
			reader.err = foundation.tokenizer_quiet_error
			reader.warn = foundation.tokenizer_quiet_error
			if !parser.parse_file(&reader, tree) || tree.syntax_error_count > 0 {
				return nil, false
			}
			imports := make(map[string]bool)
			for decl in tree.imports {
				name := decl.name.text
				if name == "" {
					path := strings.trim(decl.fullpath, "\"`")
					name = path[max(strings.last_index_any(path, ":/") + 1, 0):]
				}
				imports[name] = true
			}
			append(&parsed, Parsed_Source{file = source[0], tree = tree, imports = imports})
			declarations := make([dynamic]^ast.Value_Decl)
			declarations_of(tree.decls[:], &declarations)
			for value in declarations {
				for name, index in value.names {
					ident, is_ident := name.derived.(^ast.Ident)
					if !is_ident {
						continue
					}
					if value.is_mutable {
						variables[ident.name] = true
					} else if index < len(value.values) {
						#partial switch kind in value.values[index].derived {
						case ^ast.Struct_Type, ^ast.Union_Type, ^ast.Enum_Type, ^ast.Bit_Set_Type, ^ast.Distinct_Type, ^ast.Array_Type, ^ast.Pointer_Type, ^ast.Multi_Pointer_Type, ^ast.Proc_Type, ^ast.Matrix_Type, ^ast.Bit_Field_Type:
							types[ident.name] = true
						}
					}
				}
			}
		}
		for &source in parsed {
			declarations := make([dynamic]^ast.Value_Decl)
			declarations_of(source.tree.decls[:], &declarations)
			for value in declarations {
				if !value.is_mutable {
					continue
				}
				found := make([dynamic]Global_Initializer_Use)
				walk := Initializer_Walk{file = source.file, variables = &variables, types = &types, imports = &source.imports, uses = &found}
				// A value of the type any holds the address of its value,
				// which the start of a program writes.
				if len(value.values) > 0 && value.type != nil {
					if type_name, is_ident := value.type.derived.(^ast.Ident); is_ident && type_name.name == "any" {
						walk.variable = expression_text(&walk, value.names[0])
						refuse(&walk, value.pos.line, "a value of the type any")
					}
				}
				for initializer, index in value.values {
					walk.variable = index < len(value.names) ? strings.clone(expression_text(&walk, value.names[index]), context.temp_allocator) : ""
					visitor := ast.Visitor{visit = initializer_visit, data = &walk}
					ast.walk(&visitor, initializer)
				}
				for use in found {
					append(&list, Global_Initializer_Use{file = strings.clone(use.file, context.temp_allocator), line = use.line, variable = strings.clone(use.variable, context.temp_allocator), what = strings.clone(use.what, context.temp_allocator)})
				}
			}
		}
	}
	return list[:], true
}

// global_initializer_uses_of_tree reads each package of the system, from
// the folder root ("": the folder of the repository). A package is the
// files of one folder that are not tests.
global_initializer_uses_of_tree :: proc(root: string) -> (uses: []Global_Initializer_Use, file_count: int, ok: bool) {
	files := make([dynamic]string, context.temp_allocator)
	folders := GLOBAL_INITIALIZER_CHECKED_FOLDERS
	for folder in folders {
		target := root == "" ? folder : foundation.join(root, "/", folder)
		if !os.is_dir(target) {
			continue
		}
		foundation.source_files_of_a_folder(target, &files) or_return
	}
	slice.sort(files[:])
	list := make([dynamic]Global_Initializer_Use, context.temp_allocator)
	index := 0
	for index < len(files) {
		folder := files[index][:max(strings.last_index(files[index], "/"), 0)]
		package_sources := make([dynamic][2]string, context.temp_allocator)
		for index < len(files) && files[index][:max(strings.last_index(files[index], "/"), 0)] == folder {
			file := files[index]
			index += 1
			if source_is_a_test(file) {
				continue
			}
			source, read_ok := foundation.read_text_file_quiet(file)
			if !read_ok {
				fmt.eprintfln("modustool: cannot read %s", file)
				return nil, 0, false
			}
			// A source for the host alone runs as a program, whose start
			// runs each initializer.
			if host_only_source(source) {
				continue
			}
			append(&package_sources, [2]string{file, source})
			file_count += 1
		}
		found, parsed := global_initializer_uses_of_package(package_sources[:])
		if !parsed {
			fmt.eprintfln("modustool: cannot parse a source of %s for the check of the package variables", folder)
			return nil, 0, false
		}
		append(&list, ..found)
	}
	return list[:], file_count, true
}

// host_only_source says if a source is for the host alone: its build line
// "#+build !freestanding" comes before the line of its package. The same
// words later in the source are text, not a build line.
host_only_source :: proc(source: string) -> bool {
	rest := source
	for line in strings.split_lines_iterator(&rest) {
		text := strings.trim_space(line)
		if strings.has_prefix(text, "package ") {
			return false
		}
		if strings.has_prefix(text, "#+build") && strings.contains(text, "!freestanding") {
			return true
		}
	}
	return false
}

// global_initializer_check refuses each package variable of the system
// whose initializer needs a start of the runtime.
global_initializer_check :: proc() -> bool {
	uses, file_count, ok := global_initializer_uses_of_tree("")
	if !ok {
		return false
	}
	for use in uses {
		fmt.eprintfln("modustool: %s:%d: the package variable %s has in its initializer %s: the compiler makes it a step of the start of a program, which a module never runs, so it stays zero on the machine; write the slices as literals inside the table (docs/MODULE_CONTRACT.md, \"Package variables are constant data at the load\")", use.file, use.line, use.variable, use.what)
	}
	if len(uses) > 0 {
		fmt.eprintfln("modustool: test failed: %d package variables of the system need a start of the runtime", len(uses))
		return false
	}
	foundation.test_passed_print("no package variable of the %d source files of the system that are not tests needs a start of the runtime", file_count)
	return true
}