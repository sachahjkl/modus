package checks

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:slice"
import "core:strings"
import "modustool:foundation"

// The read of a call outcome is forced by the compiler
// (src/md/api/call_outcome.md, "The value of a call that did not succeed").
//
// An export that can fail takes an error record and gives the call outcome
// first: the description refuses another signature, so the module does not
// build. A caller in Odin binds an import in a `foreign` block (at file
// level or inside a `when` statement); this check reads each binding:
//
// - A binding with a last parameter `error` binds an export that can fail:
//   its first result is call_outcome.Call_Outcome (no type alias).
// - A binding that gives call_outcome.Call_Outcome must put it first, must
//   have a last parameter `error`, and must carry @(require_results), so a
//   caller that drops the outcome does not compile.
//
// No check reads the sign of a value, or the literal form of a `return`.

OUTCOME_BINDING_FOLDERS :: [?]string{foundation.SOURCE_FOLDER_MODULES, foundation.SOURCE_FOLDER_PUBLIC, foundation.SOURCE_FOLDER_INTERNAL, foundation.SOURCE_FOLDER_OUTSIDE}

// The import path of the call outcome contract package.
OUTCOME_BINDING_CONTRACT_PATH :: "modus:contract/call_outcome"

// The name of the last parameter of an export that can fail.
OUTCOME_BINDING_ERROR_PARAMETER :: "error"

// One binding that breaks the rule.
Outcome_Binding_Fault :: struct {
	file:    string,
	line:    int,
	binding: string, // The name of the procedure in the foreign block.
	reason:  Outcome_Binding_Reason,
}

Outcome_Binding_Reason :: enum {
	Error_Record_Without_Outcome, // The binding takes an error record and gives no call_outcome.Call_Outcome first.
	Outcome_Not_First,            // The binding puts call_outcome.Call_Outcome after the first result.
	Outcome_Without_Error_Record, // The binding gives call_outcome.Call_Outcome and has no error parameter.
	Outcome_Without_Required_Read, // The binding gives call_outcome.Call_Outcome, and the compiler lets a caller drop it.
}

@(private = "file")
is_call_outcome_expr :: proc(expr: ^ast.Expr, outcome_imports: map[string]bool) -> bool {
	if expr == nil {
		return false
	}
	selector, is_selector := expr.derived.(^ast.Selector_Expr)
	if !is_selector || selector.field == nil || selector.field.name != "Call_Outcome" {
		return false
	}
	pkg, is_ident := selector.expr.derived.(^ast.Ident)
	if !is_ident {
		return false
	}
	return outcome_imports[pkg.name]
}

@(private = "file")
outcome_binding_check_foreign_block :: proc(block: ^ast.Foreign_Block_Decl, path: string, outcome_imports: map[string]bool, found: ^[dynamic]Outcome_Binding_Fault, binding_count: ^int) {
	if block.body == nil {
		return
	}
	body, is_block := block.body.derived.(^ast.Block_Stmt)
	if !is_block {
		return
	}
	for item in body.stmts {
		declaration, is_value := item.derived.(^ast.Value_Decl)
		if !is_value || len(declaration.names) != 1 {
			continue
		}
		type: ^ast.Proc_Type
		if declaration.type != nil {
			type, _ = declaration.type.derived.(^ast.Proc_Type)
		}
		if type == nil && len(declaration.values) == 1 {
			if literal, is_literal := declaration.values[0].derived.(^ast.Proc_Lit); is_literal {
				type = literal.type
			}
			if type == nil {
				type, _ = declaration.values[0].derived.(^ast.Proc_Type)
			}
		}
		if type == nil {
			continue
		}
		name := ""
		if identifier, is_identifier := declaration.names[0].derived.(^ast.Ident); is_identifier {
			name = identifier.name
		}
		takes_error_record := false
		if type.params != nil && len(type.params.list) > 0 {
			last := type.params.list[len(type.params.list) - 1]
			if len(last.names) > 0 {
				if identifier, is_identifier := last.names[len(last.names) - 1].derived.(^ast.Ident); is_identifier {
					takes_error_record = identifier.name == OUTCOME_BINDING_ERROR_PARAMETER
				}
			}
		}
		gives_outcome_first := false
		has_outcome_later := false
		if type.results != nil {
			result_index := 0
			for field in type.results.list {
				count := max(len(field.names), 1)
				is_outcome := is_call_outcome_expr(field.type, outcome_imports)
				for _ in 0 ..< count {
					if is_outcome {
						if result_index == 0 {
							gives_outcome_first = true
						} else {
							has_outcome_later = true
						}
					}
					result_index += 1
				}
			}
		}
		if !takes_error_record && !gives_outcome_first && !has_outcome_later {
			continue
		}
		binding_count^ += 1
		if has_outcome_later {
			append(found, Outcome_Binding_Fault{file = path, line = declaration.pos.line, binding = name, reason = .Outcome_Not_First})
			continue
		}
		if takes_error_record && !gives_outcome_first {
			append(found, Outcome_Binding_Fault{file = path, line = declaration.pos.line, binding = name, reason = .Error_Record_Without_Outcome})
			continue
		}
		if gives_outcome_first && !takes_error_record {
			append(found, Outcome_Binding_Fault{file = path, line = declaration.pos.line, binding = name, reason = .Outcome_Without_Error_Record})
			continue
		}
		required := false
		for attribute in declaration.attributes {
			for element in attribute.elems {
				if identifier, is_identifier := element.derived.(^ast.Ident); is_identifier && identifier.name == "require_results" {
					required = true
				}
			}
		}
		if !required {
			append(found, Outcome_Binding_Fault{file = path, line = declaration.pos.line, binding = name, reason = .Outcome_Without_Required_Read})
		}
	}
}

@(private = "file")
outcome_binding_collect_stmt :: proc(statement: ^ast.Stmt, path: string, outcome_imports: map[string]bool, found: ^[dynamic]Outcome_Binding_Fault, binding_count: ^int) {
	if statement == nil {
		return
	}
	#partial switch node in statement.derived {
	case ^ast.Foreign_Block_Decl:
		outcome_binding_check_foreign_block(node, path, outcome_imports, found, binding_count)
	case ^ast.When_Stmt:
		outcome_binding_collect_stmt(node.body, path, outcome_imports, found, binding_count)
		outcome_binding_collect_stmt(node.else_stmt, path, outcome_imports, found, binding_count)
	case ^ast.Block_Stmt:
		for inner in node.stmts {
			outcome_binding_collect_stmt(inner, path, outcome_imports, found, binding_count)
		}
	}
}

// outcome_binding_faults_of_source reads one source file, and appends each
// binding that breaks the rule. binding_count: the bindings that give an
// outcome or take an error record.
outcome_binding_faults_of_source :: proc(path, text: string, found: ^[dynamic]Outcome_Binding_Fault) -> (binding_count: int, ok: bool) {
	context.allocator = context.temp_allocator
	file := ast.new_from_positions(ast.File, {}, {})
	file.src = text
	file.fullpath = path
	reader := parser.default_parser()
	// The parser can give true for a file with errors: their count decides.
	if !parser.parse_file(&reader, file) || reader.error_count > 0 {
		fmt.eprintfln("modustool: the parser found errors in %s", path)
		return 0, false
	}
	outcome_imports := make(map[string]bool, context.temp_allocator)
	for item in file.imports {
		full := strings.trim(item.fullpath, "\"")
		if full != OUTCOME_BINDING_CONTRACT_PATH {
			continue
		}
		alias := item.name.text
		if alias == "" {
			alias = "call_outcome"
		}
		outcome_imports[alias] = true
	}
	for statement in file.decls {
		outcome_binding_collect_stmt(statement, path, outcome_imports, found, &binding_count)
	}
	return binding_count, true
}

// outcome_binding_faults_of_tree reads each source of the modules, the
// public library and the outside modules under a root ("" is the
// repository).
outcome_binding_faults_of_tree :: proc(root: string) -> (found: []Outcome_Binding_Fault, file_count: int, binding_count: int, ok: bool) {
	files := make([dynamic]string, context.temp_allocator)
	folders := OUTCOME_BINDING_FOLDERS
	for folder in folders {
		foundation.source_files_of_a_folder(root == "" ? folder : foundation.join(root, "/", folder), &files) or_return
	}
	slice.sort(files[:])
	list := make([dynamic]Outcome_Binding_Fault, context.temp_allocator)
	for file in files {
		if source_is_a_test(file) || !strings.has_suffix(file, ".odin") {
			continue
		}
		text, read_ok := foundation.read_text_file_quiet(file)
		if !read_ok {
			fmt.eprintfln("modustool: cannot read %s", file)
			return nil, 0, 0, false
		}
		count := outcome_binding_faults_of_source(file, text, &list) or_return
		binding_count += count
		file_count += 1
	}
	return list[:], file_count, binding_count, true
}

// outcome_binding_check refuses a binding of an export that can fail that
// gives no outcome, or lets a caller drop it.
outcome_binding_check :: proc() -> bool {
	found, file_count, binding_count, ok := outcome_binding_faults_of_tree("")
	if !ok {
		return false
	}
	for item in found {
		switch item.reason {
		case .Error_Record_Without_Outcome:
			fmt.eprintfln("modustool: %s:%d: the binding %s takes an error record, so its export can fail: give the outcome first, -> (outcome: call_outcome.Call_Outcome, value: i64) (docs/MODULE_CONTRACT.md, \"8. Errors that diagnose\")", item.file, item.line, item.binding)
		case .Outcome_Not_First:
			fmt.eprintfln("modustool: %s:%d: the binding %s puts call_outcome.Call_Outcome after the first result: give the outcome first", item.file, item.line, item.binding)
		case .Outcome_Without_Error_Record:
			fmt.eprintfln("modustool: %s:%d: the binding %s gives call_outcome.Call_Outcome with no error parameter: add the last parameter error: ^errors.Error_Record", item.file, item.line, item.binding)
		case .Outcome_Without_Required_Read:
			fmt.eprintfln("modustool: %s:%d: the binding %s gives a call outcome: give it the attribute @(require_results), so that a caller cannot drop the outcome", item.file, item.line, item.binding)
		}
	}
	if len(found) > 0 {
		fmt.eprintfln("modustool: test failed: %d bindings of exports that can fail break the rule of the call outcome", len(found))
		return false
	}
	foundation.test_passed_print("each binding of an export that can fail gives the call outcome first, and the compiler forces its read (%d bindings read in %d files)", binding_count, file_count)
	return true
}
