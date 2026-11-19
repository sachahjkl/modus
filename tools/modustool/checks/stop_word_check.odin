package checks

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"
import "modustool:foundation"

// The stop of a process has two facts that come only from their borders
// (src/md/api/process_stop.md, "The migration"). The compiler refuses an
// integer where a stop outcome is due; it accepts a conversion of a word
// to the enum, and a raw call of the two operations. This check refuses
// both outside their home packages:
//
// - a conversion of a word to `Stop_Cause` or `Stop_Outcome` outside the
//   contract package `operation`, whose borders read the words;
// - `.Process_Stop` or `.Process_State` passed to `call` or
//   `call_with_error` of the support package `system` outside that
//   package, whose `stop`, `process_stop`, `process_state` and
//   `process_stop_wait` read the words through their borders.
//
// A comparison with a member is a conversion too here: the two enums have
// a border of their own, so no reader needs one.

// The home package of the two enums of a stop.
STOP_ENUM_FOLDER :: foundation.SOURCE_FOLDER_CONTRACT + "/operation"

// The home package of the raw calls of the two operations of a stop.
STOP_OPERATION_FOLDER :: foundation.SOURCE_FOLDER_SUPPORT + "/system"

// The two enums of a stop, as `STOP_ENUM_FOLDER` declares them.
STOP_ENUM_NAMES :: [?]string{"Stop_Cause", "Stop_Outcome"}

// The members of `Operation` whose words only the support package system
// sends and reads.
STOP_OPERATION_NAMES :: [?]string{"Process_Stop", "Process_State"}

// The procedures of the support package system that send one command of
// the kernel ring.
STOP_CALL_NAMES :: [?]string{"call", "call_with_error"}

// What a stop word fault is.
Stop_Word_Fault_Kind :: enum {
	Conversion, // A conversion of a word to a stop enum outside its package.
	Raw_Call, // A stop operation passed to a call of the system library outside it.
}

@(rodata)
stop_word_fault_words := [Stop_Word_Fault_Kind]string {
	.Conversion = "a conversion of a word to the enum",
	.Raw_Call   = "a raw call of the operation",
}

// One fault that the check finds: its place, its kind and the enum or the
// operation that it names.
Stop_Word_Fault :: struct {
	file: string,
	line: int,
	kind: Stop_Word_Fault_Kind,
	name: string,
}

// The state of the walk of one file.
@(private = "file")
Stop_Word_Walk :: struct {
	folder:  string,
	file:    string,
	imports: map[string]string, // The name of an import in the file, to the folder of its package.
	faults:  ^[dynamic]Stop_Word_Fault,
}

// folder_is_home says if the folder of a package is a home folder, under
// the repository or under another root.
@(private = "file")
folder_is_home :: proc(folder: string, home: string) -> bool {
	return folder == home || strings.has_suffix(folder, strings.concatenate({"/", home}, context.temp_allocator))
}

// stop_word_faults_of_sources reads the sources, one folder as one
// package, and gives each stop word fault, in the order of the files and
// the lines. ok false: a source that the parser refuses.
stop_word_faults_of_sources :: proc(sources: []Export_Source) -> (faults: []Stop_Word_Fault, ok: bool) {
	parsed := choice_sources_parse(sources) or_return
	return stop_word_faults_of_parsed(parsed), true
}

// stop_word_faults_of_parsed gives each stop word fault of the parsed
// sources.
stop_word_faults_of_parsed :: proc(parsed: []Choice_Parsed) -> []Stop_Word_Fault {
	context.allocator = context.temp_allocator
	faults := make([dynamic]Stop_Word_Fault)
	for item in parsed {
		walk := Stop_Word_Walk {
			folder  = item.folder,
			file    = item.source.path,
			imports = imports_of(item.file, item.folder),
			faults  = &faults,
		}
		visitor := ast.Visitor {
			visit = stop_word_visit,
			data  = &walk,
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

// stop_word_visit notes each conversion to a stop enum and each raw call
// of a stop operation.
//
// The syntax tree of Odin has a closed set of nodes: the switch reads the
// few that hold a conversion or a call, and stays partial.
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
				if name, is_stop_enum := stop_enum_named(walk, item.expr); is_stop_enum && !folder_is_home(walk.folder, STOP_ENUM_FOLDER) {
					append(walk.faults, Stop_Word_Fault{walk.file, item.pos.line, .Conversion, name})
				}
			}
		}
		if stop_call_of_system(walk, item.expr) && !folder_is_home(walk.folder, STOP_OPERATION_FOLDER) {
			for argument in item.args {
				if name, is_stop_operation := stop_operation_named(unparenthesized(argument)); is_stop_operation {
					append(walk.faults, Stop_Word_Fault{walk.file, item.pos.line, .Raw_Call, name})
				}
			}
		}
	case ^ast.Type_Cast:
		if name, is_stop_enum := stop_enum_named(walk, item.type); is_stop_enum && !folder_is_home(walk.folder, STOP_ENUM_FOLDER) {
			append(walk.faults, Stop_Word_Fault{walk.file, item.pos.line, .Conversion, name})
		}
	}
	return visitor
}

// stop_enum_named says if an expression names a stop enum of the contract
// package operation, or a pointer, an array or a slice of one, and gives
// the name of the enum.
@(private = "file")
stop_enum_named :: proc(walk: ^Stop_Word_Walk, expression: ^ast.Expr) -> (name: string, is_stop_enum: bool) {
	if expression == nil {
		return "", false
	}
	names := STOP_ENUM_NAMES
	#partial switch item in expression.derived {
	case ^ast.Paren_Expr:
		return stop_enum_named(walk, item.expr)
	case ^ast.Pointer_Type:
		return stop_enum_named(walk, item.elem)
	case ^ast.Multi_Pointer_Type:
		return stop_enum_named(walk, item.elem)
	case ^ast.Array_Type:
		return stop_enum_named(walk, item.elem)
	case ^ast.Dynamic_Array_Type:
		return stop_enum_named(walk, item.elem)
	case ^ast.Ident:
		// The home package names the enum with no import.
		if folder_is_home(walk.folder, STOP_ENUM_FOLDER) && slice.contains(names[:], item.name) {
			return item.name, true
		}
	case ^ast.Selector_Expr:
		package_name, is_name := item.expr.derived.(^ast.Ident)
		if !is_name || item.field == nil {
			return "", false
		}
		imported, known := walk.imports[package_name.name]
		if known && folder_is_home(imported, STOP_ENUM_FOLDER) && slice.contains(names[:], item.field.name) {
			return item.field.name, true
		}
	}
	return "", false
}

// stop_call_of_system says if a callee is `call` or `call_with_error` of
// the support package system, through its import.
@(private = "file")
stop_call_of_system :: proc(walk: ^Stop_Word_Walk, callee: ^ast.Expr) -> bool {
	if callee == nil {
		return false
	}
	calls := STOP_CALL_NAMES
	#partial switch item in callee.derived {
	case ^ast.Selector_Expr:
		package_name, is_name := item.expr.derived.(^ast.Ident)
		if !is_name || item.field == nil {
			return false
		}
		imported, known := walk.imports[package_name.name]
		return known && folder_is_home(imported, STOP_OPERATION_FOLDER) && slice.contains(calls[:], item.field.name)
	}
	return false
}

// stop_operation_named says if an argument names `Process_Stop` or
// `Process_State` of `Operation`: `.Process_Stop`, `Operation.Process_Stop`
// or `op.Operation.Process_Stop`. The type `op.Process_State` names no
// operation.
@(private = "file")
stop_operation_named :: proc(expression: ^ast.Expr) -> (name: string, is_stop_operation: bool) {
	if expression == nil {
		return "", false
	}
	operations := STOP_OPERATION_NAMES
	#partial switch item in expression.derived {
	case ^ast.Implicit_Selector_Expr:
		if item.field != nil && slice.contains(operations[:], item.field.name) {
			return item.field.name, true
		}
	case ^ast.Selector_Expr:
		if item.field == nil || !slice.contains(operations[:], item.field.name) {
			return "", false
		}
		#partial switch owner in item.expr.derived {
		case ^ast.Ident:
			return item.field.name, owner.name == "Operation"
		case ^ast.Selector_Expr:
			return item.field.name, owner.field != nil && owner.field.name == "Operation"
		}
	}
	return "", false
}

// stop_word_faults_write writes one line for each fault, and gives the
// count.
stop_word_faults_write :: proc(faults: []Stop_Word_Fault) -> int {
	for fault in faults {
		switch fault.kind {
		case .Conversion:
			fmt.eprintfln("modustool: %s:%d: %s %s: read the word through its border in the contract package operation (stop_of_words, stop_cause_of_word, stop_outcome_of_word), or the library (system.process_state, system.process_stop_wait) (src/md/api/process_stop.md)", fault.file, fault.line, stop_word_fault_words[fault.kind], fault.name)
		case .Raw_Call:
			fmt.eprintfln("modustool: %s:%d: %s %s outside the support package system: use system.stop, system.process_stop, system.process_state, system.process_stop_wait or system.process_place (src/md/api/process_stop.md)", fault.file, fault.line, stop_word_fault_words[fault.kind], fault.name)
		}
	}
	return len(faults)
}
