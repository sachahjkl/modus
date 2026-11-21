package checks

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "modustool:build"
import "modustool:foundation"

// The check of the fact waits of the scenarios
// (src/md/infrastructure/scenario_fault_loop.md, "The check of the fact
// waits"). It reads the literal of each step of the sources of the tool,
// and holds each text of the log that a step waits for against the fact
// templates of the module files of the build (build.fact_wait_verdict).
// It needs the module files, so it runs after a build and before any
// machine starts.

// The folder of the tool: its scenarios, and the constants that a step names.
SCENARIO_WAITS_FOLDER :: "tools/modustool"

// The kinds of a step whose text is a text of the log: a Wait and each
// step that reads the log as a Wait does, and a Record, whose text a fact
// renders too. The text of every other kind is a key, a call or a name.
SCENARIO_WAIT_KINDS :: [?]string{"Wait", "Date", "Appearance_Auto", "Bar_Local_Time", "Screen_Size", "Generation", "Remember", "Trace", "Quic_Key", "Remote_Key", "Remote_Display_Key", "Viewer_Relay", "Record"}

// One text of the log that a step of a scenario waits for, as its literal
// gives it.
Scenario_Wait :: struct {
	path:  string,
	line:  int,
	kind:  string, // The kind of the step: "Wait".
	field: string, // "text", "fails_on", or "expected" of a step Key_Until.
	text:  string,
}

// What the read of the sources found.
Scenario_Waits :: struct {
	waits:      [dynamic]Scenario_Wait,
	unread:     int, // Texts of a step that are no literal and no constant: a text that the code formats. The check cannot read them.
	// The form of each text line that a source of the system writes with
	// system.log, as a template: each part that is no literal nor constant
	// is a field, "{value}". A module that writes facts can still write
	// text lines with the same prefix, and a wait on one of them is right.
	text_lines: [dynamic]string,
}

// The procedures of the system that write a text line, each part of it an
// argument after the level.
SCENARIO_TEXT_LINE_PROCEDURE :: "log"
SCENARIO_TEXT_LINE_PACKAGE :: "system"

// The sources of the tool, parsed, and their constants of text.
@(private = "file")
Scenario_Walk :: struct {
	constants: map[string]^ast.Expr, // The value of each constant of the tool by its name; two different values of one name are nil.
	path:        string,
	reads_steps: bool, // The source is of the tool: its compound literals can be steps.
	found:       ^Scenario_Waits,
}

// scenario_waits_of_sources reads the step literals of sources of the
// tool, given as path and text. ok is false for a source that the parser
// refuses.
scenario_waits_of_sources :: proc(sources: []Export_Source) -> (found: Scenario_Waits, ok: bool) {
	context.allocator = context.temp_allocator
	found.waits = make([dynamic]Scenario_Wait)
	files := make([dynamic]^ast.File)
	constants := make(map[string]^ast.Expr)
	for source in sources {
		file := ast.new_from_positions(ast.File, {}, {})
		file.src = source.text
		file.fullpath = source.path
		reader := parser.default_parser()
		reader.err = foundation.tokenizer_quiet_error
		reader.warn = foundation.tokenizer_quiet_error
		if !parser.parse_file(&reader, file) || reader.error_count > 0 || file.syntax_error_count > 0 {
			fmt.eprintfln("modustool: %s: the parser found errors: the check of the fact waits cannot read it", source.path)
			return found, false
		}
		append(&files, file)
		for statement in file.decls {
			declaration, is_value := statement.derived.(^ast.Value_Decl)
			if !is_value || declaration.is_mutable || len(declaration.names) != len(declaration.values) {
				continue
			}
			for name, index in declaration.names {
				identifier, has_name := name.derived.(^ast.Ident)
				if !has_name {
					continue
				}
				// A name that two packages declare with two values names no
				// one text: the check reads neither.
				if earlier, seen := constants[identifier.name]; seen && earlier != nil {
					earlier_text, earlier_ok := scenario_text_of(constants, earlier, 0)
					later_text, later_ok := scenario_text_of(constants, declaration.values[index], 0)
					if !earlier_ok || !later_ok || earlier_text != later_text {
						constants[identifier.name] = nil
					}
					continue
				}
				constants[identifier.name] = declaration.values[index]
			}
		}
	}
	walk := Scenario_Walk {
		constants = constants,
		found     = &found,
	}
	visitor := ast.Visitor {
		visit = scenario_visit,
		data  = &walk,
	}
	for file in files {
		walk.path = file.fullpath
		// A record of a module can have a field `kind` with a member Wait:
		// only a source of the tool holds steps.
		walk.reads_steps = strings.has_prefix(file.fullpath, SCENARIO_WAITS_FOLDER)
		for statement in file.decls {
			ast.walk(&visitor, statement)
		}
	}
	return found, true
}

// scenario_visit reads each compound literal that names the kind of a step.
@(private = "file")
scenario_visit :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return nil
	}
	walk := (^Scenario_Walk)(visitor.data)
	if call, is_call := node.derived.(^ast.Call_Expr); is_call {
		scenario_text_line_read(walk, call)
		return visitor
	}
	literal, is_literal := node.derived.(^ast.Comp_Lit)
	if !is_literal || !walk.reads_steps {
		return visitor
	}
	kind := ""
	for element in literal.elems {
		field, is_field := element.derived.(^ast.Field_Value)
		if !is_field || scenario_field_name(field) != "kind" {
			continue
		}
		if selector, is_selector := field.value.derived.(^ast.Implicit_Selector_Expr); is_selector {
			kind = selector.field.name
		}
	}
	if kind == "" {
		return visitor
	}
	is_wait_kind := false
	for wait_kind in SCENARIO_WAIT_KINDS {
		is_wait_kind ||= kind == wait_kind
	}
	for element in literal.elems {
		field, is_field := element.derived.(^ast.Field_Value)
		if !is_field {
			continue
		}
		name := scenario_field_name(field)
		read := name == "fails_on" || name == "text" && is_wait_kind || name == "expected" && kind == "Key_Until"
		if !read {
			continue
		}
		text, text_ok := scenario_text_of(walk.constants, field.value, 0)
		if !text_ok {
			walk.found.unread += 1
			continue
		}
		append(&walk.found.waits, Scenario_Wait{path = walk.path, line = field.pos.line, kind = kind, field = name, text = text})
	}
	return visitor
}

// scenario_text_line_read reads a call system.log(level, parts...) of a
// source of the system as the template of its text line: a literal part
// as its text with each brace doubled, and every other part as a field.
@(private = "file")
scenario_text_line_read :: proc(walk: ^Scenario_Walk, call: ^ast.Call_Expr) {
	selector, is_selector := call.expr.derived.(^ast.Selector_Expr)
	if !is_selector || selector.field.name != SCENARIO_TEXT_LINE_PROCEDURE || len(call.args) < 2 {
		return
	}
	package_name, is_name := selector.expr.derived.(^ast.Ident)
	if !is_name || package_name.name != SCENARIO_TEXT_LINE_PACKAGE {
		return
	}
	builder := strings.builder_make(context.temp_allocator)
	for argument in call.args[1:] {
		text, is_text := scenario_text_of(walk.constants, argument, 0)
		if !is_text {
			strings.write_string(&builder, "{value}")
			continue
		}
		for character in transmute([]u8)text {
			if character == '{' || character == '}' {
				strings.write_byte(&builder, character)
			}
			strings.write_byte(&builder, character)
		}
	}
	append(&walk.found.text_lines, strings.to_string(builder))
}

@(private = "file")
scenario_field_name :: proc(field: ^ast.Field_Value) -> string {
	identifier, is_identifier := field.field.derived.(^ast.Ident)
	return is_identifier ? identifier.name : ""
}

// The deepest chain of constants that a text follows: a constant that
// names itself has no text.
@(private = "file")
SCENARIO_CONSTANT_DEPTH_MOST :: 16

// scenario_text_of gives the text of an expression of a step: a string
// literal, a constant of the tool by its name or its package and name, and
// a sum of those. ok is false for anything else: a call that formats a
// text, a variable.
@(private = "file")
scenario_text_of :: proc(constants: map[string]^ast.Expr, expression: ^ast.Expr, depth: int) -> (text: string, ok: bool) {
	if expression == nil || depth > SCENARIO_CONSTANT_DEPTH_MOST {
		return "", false
	}
	#partial switch value in expression.derived {
	case ^ast.Basic_Lit:
		if value.tok.kind != .String {
			return "", false
		}
		unquoted, allocated, unquote_ok := strconv.unquote_string(value.tok.text, context.temp_allocator)
		_ = allocated
		return unquoted, unquote_ok
	case ^ast.Binary_Expr:
		if value.op.text != "+" {
			return "", false
		}
		left := scenario_text_of(constants, value.left, depth + 1) or_return
		right := scenario_text_of(constants, value.right, depth + 1) or_return
		return strings.concatenate({left, right}, context.temp_allocator), true
	case ^ast.Paren_Expr:
		return scenario_text_of(constants, value.expr, depth + 1)
	case ^ast.Ident:
		return scenario_text_of(constants, constants[value.name], depth + 1)
	case ^ast.Selector_Expr:
		return scenario_text_of(constants, constants[value.field.name], depth + 1)
	}
	return "", false
}

// scenario_waits_check reads each step of the scenarios of the tool and
// refuses each fact wait that no fact template of the module files of the
// build renders, with its file, its line and the nearest template. It runs
// after a build: the module files are its catalog.
scenario_waits_check :: proc() -> bool {
	started := time.tick_now()
	paths := make([dynamic]string, context.temp_allocator)
	foundation.source_files_of_a_folder(SCENARIO_WAITS_FOLDER, &paths) or_return
	system_paths := make([dynamic]string, context.temp_allocator)
	foundation.source_files_of_a_folder(foundation.SOURCE_FOLDER_MODULES, &system_paths) or_return
	foundation.source_files_of_a_folder(foundation.SOURCE_FOLDER_LIBRARY, &system_paths) or_return
	sources := make([dynamic]Export_Source, context.temp_allocator)
	for path, index in ([][]string{paths[:], system_paths[:]}) {
		for file in path {
			// A host test gives texts that are wrong on purpose.
			if strings.has_suffix(file, "_test.odin") {
				continue
			}
			bytes, read_error := os.read_entire_file(file, context.temp_allocator)
			if read_error != nil {
				fmt.eprintfln("modustool: test failed: cannot read %s: %v", file, read_error)
				return false
			}
			// A source of the system matters only for its text lines: one
			// that writes none is not parsed.
			if index == 1 && !strings.contains(string(bytes), SCENARIO_TEXT_LINE_PACKAGE + "." + SCENARIO_TEXT_LINE_PROCEDURE + "(") {
				continue
			}
			append(&sources, Export_Source{path = file, text = string(bytes)})
		}
	}
	found := scenario_waits_of_sources(sources[:]) or_return
	catalog, catalog_problem := build.fact_catalog_of_build(context.temp_allocator)
	if catalog_problem != "" {
		fmt.eprintfln("modustool: test failed: the fact waits of the scenarios cannot be checked: %s", catalog_problem)
		return false
	}
	known := build.fact_wait_templates_of_catalog(&catalog, found.text_lines[:])
	problems := scenario_wait_problems(&known, found.waits[:])
	for problem in problems {
		fmt.eprintfln("modustool: test failed: %s", problem)
	}
	fact_waits := 0
	for wait in found.waits {
		verdict, _, _ := build.fact_wait_verdict(&known, wait.text)
		if verdict != .Not_A_Fact_Wait {
			fact_waits += 1
		}
	}
	fmt.printfln("modustool: measure: the check of the fact waits read %d texts of steps in %.2f s: %d fact waits, %d texts that the code formats and the check cannot read", len(found.waits), time.duration_seconds(time.tick_since(started)), fact_waits, found.unread)
	if len(problems) > 0 {
		return false
	}
	foundation.test_passed_print("each of the %d fact waits of the scenarios is the start of a sentence that a fact template of the build renders (%d templates)", fact_waits, len(known.templates))
	return true
}

// scenario_wait_problems gives one line for each fact wait that no
// template renders: its place, its text, and the template of its prefix
// that renders the longest start of it.
scenario_wait_problems :: proc(known: ^build.Fact_Wait_Templates, waits: []Scenario_Wait) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	for wait in waits {
		verdict, nearest, matched := build.fact_wait_verdict(known, wait.text)
		if verdict != .Matches_None {
			continue
		}
		body := build.fact_wait_body(wait.text)
		owner := len(nearest.modules) > 0 ? nearest.modules[0] : "no module"
		append(&problems, fmt.tprintf("%s:%d: the step %s waits for the fact text \"%s\" (%s), which no fact template and no text line of the build renders; the nearest, of %s, renders \"%s\" then not \"%s\": \"%s\"", wait.path, wait.line, wait.kind, wait.text, wait.field, owner, body[:matched], body[matched:], nearest.template))
	}
	return problems[:]
}
