package modustool

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:slice"
import "core:strconv"
import "core:strings"

// A closed set of choices is an enum, never a family of integer constants
// passed as an integer (src/md/infrastructure/choice_constants.md). The
// check reads each source of the system that is not a test, and finds the
// families of small integer constants of one package whose members the
// code uses as choices: a case of a switch, a value compared with a value
// named like a choice, or a value given to a name like a choice. A family
// with two such members or more is refused, unless the short list of
// exceptions below names it with its reason.

CHOICE_CONSTANT_FOLDERS :: [?]string{SOURCE_FOLDER_KERNEL, SOURCE_FOLDER_BOOT, SOURCE_FOLDER_PROGRAMS, SOURCE_FOLDER_MODULES, SOURCE_FOLDER_LIBRARY}

// A copy of a package of the Odin library: its forms are not the forms of
// this system.
CHOICE_CONSTANT_SKIPPED_FOLDER :: SOURCE_FOLDER_SUPPORT + "/cryptography"

// The largest value of a constant that can be a member of a family: a
// larger value is a mask, an address, a magic number or a size.
CHOICE_VALUE_LIMIT :: 255

// The members of a family that the code must use as choices before the
// family is refused: one constant is a constant.
CHOICE_FAMILY_LEAST_MEMBERS :: 2

// The words of a name that say that it holds a choice. A name is split at
// each "_"; one of its words must be one of these, whole.
CHOICE_WORDS :: [?]string{"mode", "kind", "state", "form", "level", "stage", "strength", "role", "phase", "action", "origin", "change", "step", "round", "variety", "reason", "request", "choice", "strategy", "answer"}

// The types of a conversion that keeps the constant inside it: u64(MODE_A)
// is still MODE_A.
@(private = "file")
CHOICE_CONVERSION_TYPES :: [?]string{"u8", "u16", "u32", "u64", "uint", "i8", "i16", "i32", "i64", "int", "uintptr"}

// How the code uses a constant as a choice.
Choice_Use_Form :: enum {
	Case_Of_A_Switch,
	Compared_With_A_Choice,
	Given_To_A_Choice,
}

@(rodata)
choice_use_form_words := [Choice_Use_Form]string {
	.Case_Of_A_Switch       = "a case of a switch",
	.Compared_With_A_Choice = "compared with a value named like a choice",
	.Given_To_A_Choice      = "given to a value or a parameter named like a choice",
}

// One family that the check finds: the constants of one package with one
// first word, that the code uses as choices.
Choice_Family :: struct {
	folder:     string, // The folder of the package that declares the constants.
	first_word: string, // The first word of each name, as `MODE`.
	members:    []string, // The names, in order.
	use_file:   string, // The first use as a choice: its file and its line.
	use_line:   int,
	use_form:   Choice_Use_Form,
}

// A family that stays a family of constants, with its reason.
Choice_Constant_Exception :: struct {
	folder:     string,
	first_word: string,
	reason:     string,
}

// The justified exceptions. Each is an open set of an outside standard: a
// value that names no constant is legal on the wire, and the reader skips
// it or answers it as the standard says. An enum would have to hold each
// value of the standard, or the reader would refuse a legal value.
@(rodata)
CHOICE_CONSTANT_EXCEPTIONS := [?]Choice_Constant_Exception {
	{SOURCE_FOLDER_SUPPORT + "/quic", "FRAME", "the frame types of QUIC (RFC 9000, section 12.4): the numbers of the wire, read and written as numbers"},
	{SOURCE_FOLDER_SUPPORT + "/quic", "PARAMETER", "the transport parameters of QUIC (RFC 9000, section 18.2): a receiver ignores a parameter that it does not know"},
	{SOURCE_FOLDER_SUPPORT + "/network", "PROTOCOL", "the protocol numbers of IPv4 (IANA): a packet of another protocol is legal and is not read"},
	{SOURCE_FOLDER_SUPPORT + "/network", "ICMP", "the message types of ICMP (RFC 792): a message of another type is legal and is not read"},
	{SOURCE_FOLDER_SUPPORT + "/virtio", "CAPABILITY", "the capability types of virtio (virtio 1.2, section 4.1.4): a capability of another type is legal and is skipped"},
	{SOURCE_FOLDER_CONTRACT + "/iommu", "AMD", "the entry and block types of the ACPI table IVRS and the event codes of the event log of AMD-Vi (AMD I/O virtualization, sections 2.5 and 5.2): an entry of another type is legal and is skipped by its length, and an event of another code is written with its number"},
	{SOURCE_FOLDER_CONTRACT + "/iommu", "STRUCTURE", "the structure types of the ACPI table DMAR (Intel VT-d, section 8.1): a structure of another type is legal and is skipped by its length"},
	{SOURCE_FOLDER_CONTRACT + "/iommu", "SCOPE", "the device scope types of the ACPI table DMAR (Intel VT-d, section 8.3.1): a scope of another type is legal and is skipped"},
	{SOURCE_FOLDER_SUPPORT + "/display", "KEY", "the scan codes of the keyboard (PS/2 set 1): a key record carries any scan code, and a key with no name is a legal key"},
	{SOURCE_FOLDER_SUPPORT + "/keyboard_layout", "KEY", "the scan codes of the keyboard (PS/2 set 1): a key record carries any scan code, and a key with no name is a legal key"},
	{SOURCE_FOLDER_PROGRAMS + "/input", "SCAN", "the scan codes of the keyboard (PS/2 set 1): the device sends any scan code"},
	{SOURCE_FOLDER_SUPPORT + "/key_path", "MOUSE", "the identity bytes of a PS/2 mouse: another device answers another byte, which is legal and is read as a mouse with no wheel"},
	{SOURCE_FOLDER_KERNEL, "GUEST", "the exit codes of AMD SVM (AMD64 volume 2, appendix C): the processor gives any code, and an exit that the kernel does not serve stops the guest with its number"},
	{SOURCE_FOLDER_KERNEL, "EVENT", "the event types of the event injection of AMD SVM (AMD64 volume 2, section 15.20): the numbers of the processor"},
}

// The state of the walk of one file.
@(private = "file")
Choice_Walk :: struct {
	folder:     string, // The package of the file.
	file:       string,
	imports:    map[string]string, // The name of an import in the file, to the folder of its package.
	constants:  map[string]bool, // "folder name" of each small integer constant.
	procedures: map[string][]string, // "folder name" of each procedure, to the names of its parameters.
	uses:       ^map[string]Choice_Use, // "folder name" to the first use of the constant as a choice.
}

// choice_key names a declaration of a package in the tables of the walk.
@(private = "file")
choice_key :: proc(folder, name: string) -> string {
	return strings.concatenate({folder, " ", name}, context.temp_allocator)
}

@(private = "file")
Choice_Use :: struct {
	folder: string,
	name:   string,
	file:   string,
	line:   int,
	form:   Choice_Use_Form,
}

// choice_families_of_sources reads the sources, one folder as one package,
// and gives each family whose members the code uses as choices. ok false:
// a source that the parser refuses.
choice_families_of_sources :: proc(sources: []Export_Source) -> (families: []Choice_Family, ok: bool) {
	context.allocator = context.temp_allocator
	Parsed :: struct {
		source: Export_Source,
		folder: string,
		file:   ^ast.File,
	}
	parsed := make([dynamic]Parsed)
	constants := make(map[string]bool)
	procedures := make(map[string][]string)
	for source in sources {
		file := ast.new_from_positions(ast.File, {}, {})
		file.src = source.text
		file.fullpath = source.path
		reader := parser.default_parser()
		if !parser.parse_file(&reader, file) {
			fmt.eprintfln("modustool: %s: the parser found errors", source.path)
			return nil, false
		}
		folder := source.path[:max(strings.last_index_byte(source.path, '/'), 0)]
		append(&parsed, Parsed{source, folder, file})
		for statement in file.decls {
			declaration, is_value := statement.derived.(^ast.Value_Decl)
			if !is_value || len(declaration.names) != 1 || len(declaration.values) != 1 {
				continue
			}
			identifier, has_name := declaration.names[0].derived.(^ast.Ident)
			if !has_name {
				continue
			}
			if literal, is_procedure := declaration.values[0].derived.(^ast.Proc_Lit); is_procedure {
				procedures[choice_key(folder, identifier.name)] = parameter_names_of(literal)
				continue
			}
			if declaration.is_mutable {
				continue
			}
			if value, is_integer := small_integer_of(declaration.values[0]); is_integer && value <= CHOICE_VALUE_LIMIT {
				constants[choice_key(folder, identifier.name)] = true
			}
		}
	}
	uses := make(map[string]Choice_Use)
	for item in parsed {
		walk := Choice_Walk {
			folder     = item.folder,
			file       = item.source.path,
			imports    = imports_of(item.file, item.folder),
			constants  = constants,
			procedures = procedures,
			uses       = &uses,
		}
		visitor := ast.Visitor {
			visit = choice_visit,
			data  = &walk,
		}
		for statement in item.file.decls {
			ast.walk(&visitor, statement)
		}
	}
	// The families: the used constants of one folder with one first word.
	grouped := make(map[string][dynamic]Choice_Use)
	for _, use in uses {
		key := choice_key(use.folder, first_word_of(use.name))
		members_of_key := grouped[key]
		append(&members_of_key, use)
		grouped[key] = members_of_key
	}
	list := make([dynamic]Choice_Family)
	for _, members in grouped {
		if len(members) < CHOICE_FAMILY_LEAST_MEMBERS {
			continue
		}
		// The first use in the order of the files and the lines, so that the
		// line of the check does not change from run to run.
		slice.sort_by(members[:], proc(a, b: Choice_Use) -> bool {
			return a.file < b.file || a.file == b.file && a.line < b.line
		})
		names := make([]string, len(members))
		for member, index in members {
			names[index] = member.name
		}
		slice.sort(names)
		first := members[0]
		append(&list, Choice_Family{folder = first.folder, first_word = first_word_of(first.name), members = names, use_file = first.file, use_line = first.line, use_form = first.form})
	}
	slice.sort_by(list[:], proc(a, b: Choice_Family) -> bool {
		return a.folder < b.folder || a.folder == b.folder && a.first_word < b.first_word
	})
	return list[:], true
}

// choice_visit notes each constant that a node uses as a choice.
@(private = "file")
choice_visit :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return nil
	}
	walk := (^Choice_Walk)(visitor.data)
	#partial switch item in node.derived {
	case ^ast.Case_Clause:
		for expression in item.list {
			choice_use_note(walk, expression, .Case_Of_A_Switch)
		}
	case ^ast.Binary_Expr:
		if item.op.kind == .Cmp_Eq || item.op.kind == .Not_Eq {
			if name_is_a_choice(choice_name_of(item.left)) {
				choice_use_note(walk, item.right, .Compared_With_A_Choice)
			}
			if name_is_a_choice(choice_name_of(item.right)) {
				choice_use_note(walk, item.left, .Compared_With_A_Choice)
			}
		}
	case ^ast.Assign_Stmt:
		if item.op.kind == .Eq && len(item.lhs) == len(item.rhs) {
			for target, index in item.lhs {
				if name_is_a_choice(choice_name_of(target)) {
					choice_use_note(walk, item.rhs[index], .Given_To_A_Choice)
				}
			}
		}
	case ^ast.Value_Decl:
		if item.is_mutable && len(item.names) == len(item.values) {
			for name, index in item.names {
				if name_is_a_choice(choice_name_of(name)) {
					choice_use_note(walk, item.values[index], .Given_To_A_Choice)
				}
			}
		}
	case ^ast.Field_Value:
		if name_is_a_choice(choice_name_of(item.field)) {
			choice_use_note(walk, item.value, .Given_To_A_Choice)
		}
	case ^ast.Call_Expr:
		parameters := parameters_of_callee(walk, item.expr)
		for argument, index in item.args {
			if index >= len(parameters) {
				break
			}
			// A named argument is a Field_Value: the case above reads it.
			if _, named := argument.derived.(^ast.Field_Value); named {
				continue
			}
			if name_is_a_choice(parameters[index]) {
				choice_use_note(walk, argument, .Given_To_A_Choice)
			}
		}
	}
	return visitor
}

// choice_use_note keeps the first use of a constant as a choice.
@(private = "file")
choice_use_note :: proc(walk: ^Choice_Walk, expression: ^ast.Expr, form: Choice_Use_Form) {
	folder, name, found := choice_constant_of(walk, expression)
	if !found {
		return
	}
	key := choice_key(folder, name)
	if key in walk.uses^ {
		return
	}
	walk.uses^[key] = Choice_Use{folder = folder, name = name, file = walk.file, line = expression.pos.line, form = form}
}

// choice_constant_of finds the small integer constant that an expression
// names: a name of the package, a name of an imported package, either in
// parentheses or in a conversion to an integer type.
@(private = "file")
choice_constant_of :: proc(walk: ^Choice_Walk, expression: ^ast.Expr) -> (folder: string, name: string, found: bool) {
	if expression == nil {
		return
	}
	#partial switch item in expression.derived {
	case ^ast.Paren_Expr:
		return choice_constant_of(walk, item.expr)
	case ^ast.Call_Expr:
		callee, is_name := item.expr.derived.(^ast.Ident)
		types := CHOICE_CONVERSION_TYPES
		if is_name && len(item.args) == 1 && slice.contains(types[:], callee.name) {
			return choice_constant_of(walk, item.args[0])
		}
	case ^ast.Ident:
		if choice_key(walk.folder, item.name) in walk.constants {
			return walk.folder, item.name, true
		}
	case ^ast.Selector_Expr:
		package_name, is_name := item.expr.derived.(^ast.Ident)
		if !is_name || item.field == nil {
			return
		}
		imported, known := walk.imports[package_name.name]
		if known && choice_key(imported, item.field.name) in walk.constants {
			return imported, item.field.name, true
		}
	}
	return
}

// parameters_of_callee gives the names of the parameters of a procedure of
// the package or of an imported package; nil for another callee.
@(private = "file")
parameters_of_callee :: proc(walk: ^Choice_Walk, callee: ^ast.Expr) -> []string {
	if callee == nil {
		return nil
	}
	#partial switch item in callee.derived {
	case ^ast.Ident:
		return walk.procedures[choice_key(walk.folder, item.name)]
	case ^ast.Selector_Expr:
		package_name, is_name := item.expr.derived.(^ast.Ident)
		if !is_name || item.field == nil {
			return nil
		}
		if imported, known := walk.imports[package_name.name]; known {
			return walk.procedures[choice_key(imported, item.field.name)]
		}
	}
	return nil
}

// parameter_names_of gives the name of each parameter of a procedure, in
// order; "" for a parameter with no name.
@(private = "file")
parameter_names_of :: proc(literal: ^ast.Proc_Lit) -> []string {
	names := make([dynamic]string)
	if literal.type == nil || literal.type.params == nil {
		return nil
	}
	for field in literal.type.params.list {
		if len(field.names) == 0 {
			append(&names, "")
		}
		for parameter in field.names {
			identifier, is_name := parameter.derived.(^ast.Ident)
			append(&names, is_name ? identifier.name : "")
		}
	}
	return names[:]
}

// imports_of maps the name of each import of a file to the folder of its
// package: "modus:" names the source library, a relative path the folder
// of the file. An import of base: or core: is not read.
@(private = "file")
imports_of :: proc(file: ^ast.File, folder: string) -> map[string]string {
	imports := make(map[string]string)
	for statement in file.decls {
		declaration, is_import := statement.derived.(^ast.Import_Decl)
		if !is_import {
			continue
		}
		path := strings.trim(declaration.fullpath, "\"`")
		target: string
		switch {
		case strings.has_prefix(path, SOURCE_LIBRARY_NAME + ":"):
			target = join(SOURCE_FOLDER_LIBRARY, "/", path[len(SOURCE_LIBRARY_NAME) + 1:])
		case strings.contains(path, ":"):
			continue
		case:
			target = join(folder, "/", strings.trim_prefix(path, "./"))
		}
		name := declaration.name.text
		if name == "" {
			name = path[strings.last_index_byte(path, '/') + 1:]
			if colon := strings.last_index_byte(name, ':'); colon >= 0 {
				name = name[colon + 1:]
			}
		}
		imports[name] = target
	}
	return imports
}

// small_integer_of reads the value of a constant: an integer literal, or a
// conversion of one to an integer type.
@(private = "file")
small_integer_of :: proc(expression: ^ast.Expr) -> (value: u64, ok: bool) {
	#partial switch item in expression.derived {
	case ^ast.Basic_Lit:
		if item.tok.kind != .Integer {
			return 0, false
		}
		digits, _ := strings.remove_all(item.tok.text, "_")
		return strconv.parse_u64(digits)
	case ^ast.Call_Expr:
		callee, is_name := item.expr.derived.(^ast.Ident)
		types := CHOICE_CONVERSION_TYPES
		if is_name && len(item.args) == 1 && slice.contains(types[:], callee.name) {
			return small_integer_of(item.args[0])
		}
	case ^ast.Paren_Expr:
		return small_integer_of(item.expr)
	}
	return 0, false
}

// choice_name_of gives the name that holds a value: a name, the field of
// a selector, the index of an index (`values[VALUE_MODE]`).
@(private = "file")
choice_name_of :: proc(expression: ^ast.Expr) -> string {
	if expression == nil {
		return ""
	}
	#partial switch item in expression.derived {
	case ^ast.Ident:
		return item.name
	case ^ast.Selector_Expr:
		return item.field == nil ? "" : item.field.name
	case ^ast.Index_Expr:
		return choice_name_of(item.index)
	case ^ast.Paren_Expr:
		return choice_name_of(item.expr)
	}
	return ""
}

// name_is_a_choice says if one word of a name is a word of a choice.
name_is_a_choice :: proc(name: string) -> bool {
	words := CHOICE_WORDS
	rest := name
	for word in strings.split_iterator(&rest, "_") {
		lower := strings.to_lower(word, context.temp_allocator)
		if slice.contains(words[:], lower) {
			return true
		}
	}
	return false
}

// first_word_of gives the first word of a name: `MODE` of `MODE_UNLOCK`.
first_word_of :: proc(name: string) -> string {
	if underscore := strings.index_byte(name, '_'); underscore > 0 {
		return name[:underscore]
	}
	return name
}

// choice_exception_of finds the exception of a family; nil with none.
choice_exception_of :: proc(family: Choice_Family) -> ^Choice_Constant_Exception {
	for &exception in CHOICE_CONSTANT_EXCEPTIONS {
		if exception.folder == family.folder && exception.first_word == family.first_word {
			return &exception
		}
	}
	return nil
}

// choice_families_of_tree reads each source of the system that is not a
// test, under a root ("" is the repository).
choice_families_of_tree :: proc(root: string) -> (families: []Choice_Family, file_count: int, ok: bool) {
	files := make([dynamic]string, context.temp_allocator)
	folders := CHOICE_CONSTANT_FOLDERS
	for folder in folders {
		source_files_of_a_folder(root == "" ? folder : join(root, "/", folder), &files) or_return
	}
	slice.sort(files[:])
	sources := make([dynamic]Export_Source, context.temp_allocator)
	skipped := root == "" ? CHOICE_CONSTANT_SKIPPED_FOLDER : join(root, "/", CHOICE_CONSTANT_SKIPPED_FOLDER)
	for file in files {
		if source_is_a_test(file) || strings.has_prefix(file, skipped + "/") {
			continue
		}
		text, read_ok := site_read_quiet(file)
		if !read_ok {
			fmt.eprintfln("modustool: cannot read %s", file)
			return nil, 0, false
		}
		append(&sources, Export_Source{path = file, text = text})
	}
	families = choice_families_of_sources(sources[:]) or_return
	return families, len(sources), true
}

// choice_constant_check refuses a family of integer constants that the
// code uses as a closed set of choices, and an exception that names no
// such family.
choice_constant_check :: proc() -> bool {
	families, file_count, ok := choice_families_of_tree("")
	if !ok {
		return false
	}
	refused := 0
	for family in families {
		if choice_exception_of(family) != nil {
			continue
		}
		refused += 1
		members_text, _ := strings.join(family.members, ", ", context.temp_allocator)
		fmt.eprintfln("modustool: %s:%d: the constants %s_ of %s are a closed set of choices (%s, here %s): make them an enum, with the values of the contract when the value crosses a border, and one conversion at the border that refuses a value that names no member (src/md/infrastructure/choice_constants.md)", family.use_file, family.use_line, family.first_word, family.folder, members_text, choice_use_form_words[family.use_form])
	}
	// An exception that matches no family is no longer true: the list
	// stays short only if each of its rows still holds.
	stale := 0
	for exception in CHOICE_CONSTANT_EXCEPTIONS {
		matched := false
		for family in families {
			if exception.folder == family.folder && exception.first_word == family.first_word {
				matched = true
				break
			}
		}
		if !matched {
			stale += 1
			fmt.eprintfln("modustool: %s: the exception %s_ of the check of the choice constants names no family that the code uses as choices: remove it from CHOICE_CONSTANT_EXCEPTIONS", exception.folder, exception.first_word)
		}
	}
	if refused > 0 || stale > 0 {
		fmt.eprintfln("modustool: test failed: %d families of integer constants are closed sets of choices, and %d exceptions name no family", refused, stale)
		return false
	}
	test_passed_print("no family of integer constants is a closed set of choices in the %d source files of the system that are not tests (%d exceptions of outside standards)", file_count, len(CHOICE_CONSTANT_EXCEPTIONS))
	return true
}
