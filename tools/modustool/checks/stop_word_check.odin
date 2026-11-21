package checks

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"
import "modustool:foundation"

// The stop of a process has two facts that come only from their borders
// (src/md/api/process_stop.md, "The migration"). The compiler refuses an
// integer where a stop outcome is due; it accepts a conversion of a word
// to the enum, an operation sent by its word, and the outcome None. This
// check refuses them outside their home packages:
//
// - a conversion of a word to `Stop_Cause` or `Stop_Outcome` outside the
//   contract package `operation`, whose borders read the words; a
//   comparison with a member too, since the two enums have their borders;
// - a mention of the operations `Process_Stop` or `Process_State`
//   (`.Process_Stop`, `Operation.Process_Stop`), and a conversion of a word
//   to `Operation`, outside the support package `system`, whose `stop`,
//   `process_stop`, `process_state`, `process_stop_wait` and
//   `process_place` read the words through their borders: a variable, a
//   word of a command record or a call can carry an operation that a
//   process names;
// - `system.stop(.None)`, which the kernel refuses: a stop of itself names
//   what its work gave.
//
// The kernel, the contract package `operation` and the tool name the
// operations as their dispatch, their forms and their fuzzer. An alias of
// one of the three enums, a `distinct` type or a `#type` of one, in a file
// or inside a procedure, is the enum for the check.

// The home package of the three enums.
STOP_ENUM_FOLDER :: foundation.SOURCE_FOLDER_CONTRACT + "/operation"

// The home package of the stops and of the raw calls of the two
// operations.
STOP_OPERATION_FOLDER :: foundation.SOURCE_FOLDER_PUBLIC + "/system"

// The folders that name the operations of a stop as a part of their
// design: the dispatch of the kernel and its parts, the forms of the
// contract, the library, and the fuzzer and the reference of the tool.
STOP_OPERATION_HOMES :: [?]string{STOP_OPERATION_FOLDER, STOP_ENUM_FOLDER, foundation.SOURCE_FOLDER_KERNEL, foundation.TOOL_SOURCE_FOLDER}

// The two enums of a stop.
STOP_ENUM_NAMES :: [?]string{"Stop_Cause", "Stop_Outcome"}

// The enum of the kernel operations.
OPERATION_ENUM_NAME :: "Operation"

// The members of `Operation` whose words only the support package system
// sends and reads.
STOP_OPERATION_NAMES :: [?]string{"Process_Stop", "Process_State"}

// The depth of a chain of aliases (A :: B, B :: op.Stop_Cause): past it,
// the alias is not read. It ends a cycle too.
@(private = "file")
STOP_ALIAS_DEPTH_LIMIT :: 16

// What a stop word fault is.
Stop_Word_Fault_Kind :: enum {
	Conversion, // A conversion of a word to a stop enum outside its package.
	Operation_Named, // Process_Stop or Process_State named outside the homes of the operations.
	Operation_Conversion, // A conversion of a word to Operation outside the homes of the operations.
	Stop_With_No_Outcome, // system.stop with the outcome None.
}

@(rodata)
stop_word_fault_words := [Stop_Word_Fault_Kind]string {
	.Conversion           = "a conversion of a word to the enum",
	.Operation_Named      = "a mention of the operation",
	.Operation_Conversion = "a conversion of a word to the enum",
	.Stop_With_No_Outcome = "a stop with the outcome",
}

// One fault that the check finds: its place, its kind and the enum, the
// operation or the member that it names.
Stop_Word_Fault :: struct {
	file: string,
	line: int,
	kind: Stop_Word_Fault_Kind,
	name: string,
}

// A fault that stays, with its reason: its file, its kind, and the count of
// such faults in the file that the design holds. One more in the file, or
// one less, refuses the row.
Stop_Word_Exception :: struct {
	file:   string,
	kind:   Stop_Word_Fault_Kind,
	count:  int,
	reason: string,
}

// The faults of a design. Each row names one test that gives the kernel a
// word that it must refuse, which no procedure of the library sends.
@(rodata)
STOP_WORD_EXCEPTIONS := [?]Stop_Word_Exception {
	{foundation.DEMONSTRATION_MODULE_SOURCES + "address_space/main.odin", .Operation_Named, 1, "the machine test of the refusals of Process_Stop: it writes, in command records, the outcome words that the kernel must refuse, which system.stop and system.process_stop never send"},
	{foundation.DEMONSTRATION_MODULE_SOURCES + "errors/main.odin", .Operation_Conversion, 1, "the machine test of a kind of no operation: it writes, on purpose, the word one past the last operation, which the kernel must refuse with Unknown_Operation"},
}

// An exception whose count of faults is not the count that it holds.
Stop_Word_Exception_Fault :: struct {
	exception: Stop_Word_Exception,
	found:     int,
}

// The state of the walk of one file.
@(private = "file")
Stop_Word_Walk :: struct {
	folder:  string,
	file:    string,
	imports: map[string]string, // The name of an import in the file, to the folder of its package.
	aliases: ^map[string]string, // "folder name" of each alias, to the name of the enum of the contract that it names.
	faults:  ^[dynamic]Stop_Word_Fault,
}

// folder_is_home says if the folder of a package is a home folder, under
// the repository or under another root.
@(private = "file")
folder_is_home :: proc(folder: string, home: string) -> bool {
	return folder == home || strings.has_suffix(folder, strings.concatenate({"/", home}, context.temp_allocator))
}

// folder_is_under says if the folder of a package is a home folder or a
// folder inside it, under the repository or under another root.
@(private = "file")
folder_is_under :: proc(folder: string, home: string) -> bool {
	return strings.contains(strings.concatenate({"/", folder, "/"}, context.temp_allocator), strings.concatenate({"/", home, "/"}, context.temp_allocator))
}

// folder_names_stop_operations says if a folder is a home of the
// operations of a stop.
@(private = "file")
folder_names_stop_operations :: proc(folder: string) -> bool {
	homes := STOP_OPERATION_HOMES
	for home in homes {
		if folder_is_under(folder, home) {
			return true
		}
	}
	return false
}

// stop_word_faults_of_sources reads the sources, one folder as one
// package, and gives each stop word fault, in the order of the files and
// the lines, before the exceptions. ok false: a source that the parser
// refuses.
stop_word_faults_of_sources :: proc(sources: []Export_Source) -> (faults: []Stop_Word_Fault, ok: bool) {
	parsed := choice_sources_parse(sources) or_return
	return stop_word_faults_of_parsed(parsed), true
}

// stop_word_faults_of_parsed gives each stop word fault of the parsed
// sources, before the exceptions.
stop_word_faults_of_parsed :: proc(parsed: []Choice_Parsed) -> []Stop_Word_Fault {
	context.allocator = context.temp_allocator
	faults := make([dynamic]Stop_Word_Fault)
	aliases := make(map[string]string)
	walks := make([]Stop_Word_Walk, len(parsed))
	for item, index in parsed {
		walks[index] = Stop_Word_Walk {
			folder  = item.folder,
			file    = item.source.path,
			imports = imports_of(item.file, item.folder),
			aliases = &aliases,
			faults  = &faults,
		}
	}
	// The aliases first, each declaration of each file read again until no
	// new alias comes: an alias can name an alias of another file.
	for _ in 0 ..< STOP_ALIAS_DEPTH_LIMIT {
		before := len(aliases)
		for item, index in parsed {
			visitor := ast.Visitor {
				visit = stop_alias_visit,
				data  = &walks[index],
			}
			for statement in item.file.decls {
				ast.walk(&visitor, statement)
			}
		}
		if len(aliases) == before {
			break
		}
	}
	for item, index in parsed {
		visitor := ast.Visitor {
			visit = stop_word_visit,
			data  = &walks[index],
		}
		for statement in item.file.decls {
			ast.walk(&visitor, statement)
		}
	}
	slice.sort_by(faults[:], proc(a, b: Stop_Word_Fault) -> bool {
		return a.file < b.file || a.file == b.file && a.line < b.line
	})
	return faults[:]
}

// stop_alias_visit notes each constant declaration, of a file or inside a
// procedure, whose value names one of the three enums of the contract.
@(private = "file")
stop_alias_visit :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return nil
	}
	walk := (^Stop_Word_Walk)(visitor.data)
	if declaration, is_declaration := node.derived.(^ast.Value_Decl); is_declaration && !declaration.is_mutable && len(declaration.names) == len(declaration.values) {
		for name, index in declaration.names {
			identifier, has_name := name.derived.(^ast.Ident)
			if !has_name {
				continue
			}
			key := choice_key(walk.folder, identifier.name)
			if key in walk.aliases^ {
				continue
			}
			if enum_name, names_enum := guarded_enum_named(walk, declaration.values[index]); names_enum {
				walk.aliases^[key] = enum_name
			}
		}
	}
	return visitor
}

// stop_word_visit notes each fault of a node.
//
// The syntax tree of Odin has a closed set of nodes: the switch reads the
// few that hold a conversion, a member or a call, and stays partial.
@(private = "file")
stop_word_visit :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return nil
	}
	walk := (^Stop_Word_Walk)(visitor.data)
	#partial switch item in node.derived {
	case ^ast.Call_Expr:
		// A conversion is a call of the type with one argument and no name.
		if len(item.args) == 1 {
			if _, named := item.args[0].derived.(^ast.Field_Value); !named {
				if enum_name, is_guarded := guarded_enum_named(walk, item.expr); is_guarded {
					conversion_note(walk, enum_name, item.pos.line)
				}
			}
		}
		if len(item.args) == 1 && system_procedure_named(walk, item.expr, "stop") && !folder_is_home(walk.folder, STOP_OPERATION_FOLDER) && outcome_none_named(walk, unparenthesized(item.args[0])) {
			append(walk.faults, Stop_Word_Fault{walk.file, item.pos.line, .Stop_With_No_Outcome, "None"})
		}
	case ^ast.Type_Cast:
		if enum_name, is_guarded := guarded_enum_named(walk, item.type); is_guarded {
			conversion_note(walk, enum_name, item.pos.line)
		}
	case ^ast.Implicit_Selector_Expr:
		operations := STOP_OPERATION_NAMES
		if item.field != nil && slice.contains(operations[:], item.field.name) && !folder_names_stop_operations(walk.folder) {
			append(walk.faults, Stop_Word_Fault{walk.file, item.pos.line, .Operation_Named, item.field.name})
		}
	case ^ast.Selector_Expr:
		operations := STOP_OPERATION_NAMES
		if item.field != nil && slice.contains(operations[:], item.field.name) && !folder_names_stop_operations(walk.folder) {
			if enum_name, is_guarded := guarded_enum_named(walk, item.expr); is_guarded && enum_name == OPERATION_ENUM_NAME {
				append(walk.faults, Stop_Word_Fault{walk.file, item.pos.line, .Operation_Named, item.field.name})
			}
		}
	}
	return visitor
}

// conversion_note keeps a conversion to a guarded enum outside its home.
@(private = "file")
conversion_note :: proc(walk: ^Stop_Word_Walk, enum_name: string, line: int) {
	if enum_name == OPERATION_ENUM_NAME {
		if !folder_names_stop_operations(walk.folder) {
			append(walk.faults, Stop_Word_Fault{walk.file, line, .Operation_Conversion, enum_name})
		}
		return
	}
	if !folder_is_home(walk.folder, STOP_ENUM_FOLDER) {
		append(walk.faults, Stop_Word_Fault{walk.file, line, .Conversion, enum_name})
	}
}

// guarded_enum_named says if an expression names `Stop_Cause`,
// `Stop_Outcome` or `Operation` of the contract package operation, or an
// alias of one, or a pointer, an array, a slice, a `distinct` type or a
// `#type` of one, and gives the name of the enum of the contract.
@(private = "file")
guarded_enum_named :: proc(walk: ^Stop_Word_Walk, expression: ^ast.Expr) -> (enum_name: string, is_guarded: bool) {
	if expression == nil {
		return "", false
	}
	#partial switch item in expression.derived {
	case ^ast.Paren_Expr:
		return guarded_enum_named(walk, item.expr)
	case ^ast.Pointer_Type:
		return guarded_enum_named(walk, item.elem)
	case ^ast.Multi_Pointer_Type:
		return guarded_enum_named(walk, item.elem)
	case ^ast.Array_Type:
		return guarded_enum_named(walk, item.elem)
	case ^ast.Dynamic_Array_Type:
		return guarded_enum_named(walk, item.elem)
	case ^ast.Distinct_Type:
		return guarded_enum_named(walk, item.type)
	case ^ast.Helper_Type:
		return guarded_enum_named(walk, item.type)
	case ^ast.Ident:
		// The home package names the enums with no import.
		if folder_is_home(walk.folder, STOP_ENUM_FOLDER) && guarded_name(item.name) {
			return item.name, true
		}
		if aliased, found := walk.aliases^[choice_key(walk.folder, item.name)]; found {
			return aliased, true
		}
	case ^ast.Selector_Expr:
		package_name, is_name := item.expr.derived.(^ast.Ident)
		if !is_name || item.field == nil {
			return "", false
		}
		imported, known := walk.imports[package_name.name]
		if !known {
			return "", false
		}
		if folder_is_home(imported, STOP_ENUM_FOLDER) && guarded_name(item.field.name) {
			return item.field.name, true
		}
		if aliased, found := walk.aliases^[choice_key(imported, item.field.name)]; found {
			return aliased, true
		}
	}
	return "", false
}

// guarded_name says if a name is the name of one of the three enums.
@(private = "file")
guarded_name :: proc(name: string) -> bool {
	names := STOP_ENUM_NAMES
	return name == OPERATION_ENUM_NAME || slice.contains(names[:], name)
}

// system_procedure_named says if a callee is a procedure of the support
// package system with this name, through its import.
@(private = "file")
system_procedure_named :: proc(walk: ^Stop_Word_Walk, callee: ^ast.Expr, procedure: string) -> bool {
	if callee == nil {
		return false
	}
	selector, is_selector := callee.derived.(^ast.Selector_Expr)
	if !is_selector || selector.field == nil || selector.field.name != procedure {
		return false
	}
	package_name, is_name := selector.expr.derived.(^ast.Ident)
	if !is_name {
		return false
	}
	imported, known := walk.imports[package_name.name]
	return known && folder_is_home(imported, STOP_OPERATION_FOLDER)
}

// outcome_none_named says if an argument names the outcome None: `.None`,
// or `None` of `Stop_Outcome` or of an alias of it.
@(private = "file")
outcome_none_named :: proc(walk: ^Stop_Word_Walk, expression: ^ast.Expr) -> bool {
	if expression == nil {
		return false
	}
	#partial switch item in expression.derived {
	case ^ast.Implicit_Selector_Expr:
		return item.field != nil && item.field.name == "None"
	case ^ast.Selector_Expr:
		if item.field == nil || item.field.name != "None" {
			return false
		}
		enum_name, is_guarded := guarded_enum_named(walk, item.expr)
		return is_guarded && enum_name == "Stop_Outcome"
	}
	return false
}

// stop_words_judged splits the faults: each fault that no exception holds,
// and each exception whose count of faults differs from its count. The
// faults of such an exception are refused too: an exception holds its
// places only while it names exactly them.
stop_words_judged :: proc(faults: []Stop_Word_Fault, exceptions: []Stop_Word_Exception) -> (refused: []Stop_Word_Fault, exception_faults: []Stop_Word_Exception_Fault) {
	refused_list := make([dynamic]Stop_Word_Fault, context.temp_allocator)
	fault_list := make([dynamic]Stop_Word_Exception_Fault, context.temp_allocator)
	counts := make([]int, len(exceptions), context.temp_allocator)
	for fault in faults {
		for exception, index in exceptions {
			if stop_word_exception_matches(exception, fault) {
				counts[index] += 1
			}
		}
	}
	for exception, index in exceptions {
		if counts[index] != exception.count {
			append(&fault_list, Stop_Word_Exception_Fault{exception, counts[index]})
		}
	}
	each: for fault in faults {
		for exception, index in exceptions {
			if stop_word_exception_matches(exception, fault) && counts[index] == exception.count {
				continue each
			}
		}
		append(&refused_list, fault)
	}
	return refused_list[:], fault_list[:]
}

// stop_word_exception_matches says if an exception names a fault: the same
// file and the same kind. A tree under another root ends with the path.
@(private = "file")
stop_word_exception_matches :: proc(exception: Stop_Word_Exception, fault: Stop_Word_Fault) -> bool {
	same_file := fault.file == exception.file || strings.has_suffix(fault.file, strings.concatenate({"/", exception.file}, context.temp_allocator))
	return same_file && exception.kind == fault.kind
}

// stop_word_faults_write writes one line for each refused fault and each
// exception that does not hold its count, and gives the two counts.
stop_word_faults_write :: proc(refused: []Stop_Word_Fault, exception_faults: []Stop_Word_Exception_Fault) -> (refused_count: int, stale_count: int) {
	for fault in refused {
		switch fault.kind {
		case .Conversion:
			fmt.eprintfln("modustool: %s:%d: %s %s: read the word through its border in the contract package operation (stop_of_words, stop_cause_of_word, stop_outcome_of_word), or the library (system.process_state, system.process_stop_wait) (src/md/api/process_stop.md)", fault.file, fault.line, stop_word_fault_words[fault.kind], fault.name)
		case .Operation_Named, .Operation_Conversion:
			fmt.eprintfln("modustool: %s:%d: %s %s outside the support package system: use system.stop, system.process_stop, system.process_state, system.process_stop_wait or system.process_place (src/md/api/process_stop.md)", fault.file, fault.line, stop_word_fault_words[fault.kind], fault.name)
		case .Stop_With_No_Outcome:
			fmt.eprintfln("modustool: %s:%d: %s %s, which the kernel refuses: name what the work gave, Done, Failed, Refused or Stopped_On_Request (src/md/api/process_stop.md)", fault.file, fault.line, stop_word_fault_words[fault.kind], fault.name)
		}
	}
	for fault in exception_faults {
		fmt.eprintfln("modustool: %s: the exception %s of the check of the stop words holds %d faults, and the file has %d: change the row of STOP_WORD_EXCEPTIONS, or the code", fault.exception.file, stop_word_fault_words[fault.exception.kind], fault.exception.count, fault.found)
	}
	return len(refused), len(exception_faults)
}
