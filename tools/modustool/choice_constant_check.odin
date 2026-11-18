package modustool

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:slice"
import "core:strconv"
import "core:strings"
import "modustool:foundation"

// A closed set of choices is an enum, never a family of integer constants
// passed as an integer (src/md/infrastructure/choice_constants.md). The
// check reads each source of the system and of the tool that is not a
// test, and finds the families of small integer constants of one package
// whose members the code uses as choices: a case of a switch, a value
// compared with a value named like a choice, or a value given to a name
// like a choice. A family is the constants with one first word, or with
// one last word (READ_REQUEST, WRITE_REQUEST). A family with two such
// members or more is refused, unless the short list of exceptions below
// names it with its reason.

CHOICE_CONSTANT_FOLDERS :: [?]string{foundation.SOURCE_FOLDER_KERNEL, foundation.SOURCE_FOLDER_BOOT, foundation.SOURCE_FOLDER_MODULES, foundation.SOURCE_FOLDER_LIBRARY, foundation.TOOL_SOURCE_FOLDER}

// The depth of the constants that a value names through other constants
// (B :: A + 1): past it, the value is not read. It ends a cycle too.
@(private = "file")
CHOICE_VALUE_DEPTH_LIMIT :: 16

// A copy of a package of the Odin library: its forms are not the forms of
// this system.
CHOICE_CONSTANT_SKIPPED_FOLDER :: foundation.SOURCE_FOLDER_SUPPORT + "/cryptography"

// The largest magnitude of a constant that can be a member of a family, on
// each side of 0: a larger value is a mask, an address, a magic number or
// a size. A negative member is an answer of an export (ERROR_NAME :: -3).
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

// Where the word that the names of a family share is.
Choice_Word_Place :: enum {
	First, // MODE_UNLOCK, MODE_CREATE: the family MODE_.
	Last, // READ_REQUEST, WRITE_REQUEST: the family _REQUEST.
}

// One family that the check finds: the constants of one package with one
// first word or one last word, that the code uses as choices.
Choice_Family :: struct {
	folder:     string, // The folder of the package that declares the constants.
	word:       string, // The word of each name, as `MODE` or `REQUEST`.
	word_place: Choice_Word_Place,
	members:    []string, // The names, in order.
	use_file:   string, // The first use as a choice: its file and its line.
	use_line:   int,
	use_form:   Choice_Use_Form,
}

// A family that stays a family of constants, with its reason. It names the
// word of the family at its place.
Choice_Constant_Exception :: struct {
	folder:     string,
	word:       string,
	word_place: Choice_Word_Place,
	reason:     string,
}

// The justified exceptions. Each but one is an open set of an outside
// standard: a value that names no constant is legal on the wire, and the
// reader skips it or answers it as the standard says. An enum would have
// to hold each value of the standard, or the reader would refuse a legal
// value. The row FIELD names places, which the check cannot tell from
// choices by their use.
@(rodata)
CHOICE_CONSTANT_EXCEPTIONS := [?]Choice_Constant_Exception {
	{foundation.SOURCE_FOLDER_SUPPORT + "/quic", "FRAME", .First, "the frame types of QUIC (RFC 9000, section 12.4): the numbers of the wire, read and written as numbers"},
	{foundation.SOURCE_FOLDER_SUPPORT + "/quic", "PARAMETER", .First, "the transport parameters of QUIC (RFC 9000, section 18.2): a receiver ignores a parameter that it does not know"},
	{foundation.SOURCE_FOLDER_SUPPORT + "/network", "PROTOCOL", .First, "the protocol numbers of IPv4 (IANA): a packet of another protocol is legal and is not read"},
	{foundation.SOURCE_FOLDER_SUPPORT + "/network", "ICMP", .First, "the message types of ICMP (RFC 792): a message of another type is legal and is not read"},
	{foundation.SOURCE_FOLDER_SUPPORT + "/virtio", "CAPABILITY", .First, "the capability types of virtio (virtio 1.2, section 4.1.4): a capability of another type is legal and is skipped"},
	{foundation.SOURCE_FOLDER_KERNEL + "/iommu", "AMD", .First, "the entry and block types of the ACPI table IVRS and the event codes of the event log of AMD-Vi (AMD I/O virtualization, sections 2.5 and 5.2): an entry of another type is legal and is skipped by its length, and an event of another code is written with its number"},
	{foundation.SOURCE_FOLDER_KERNEL + "/iommu", "STRUCTURE", .First, "the structure types of the ACPI table DMAR (Intel VT-d, section 8.1): a structure of another type is legal and is skipped by its length"},
	{foundation.SOURCE_FOLDER_KERNEL + "/iommu", "SCOPE", .First, "the device scope types of the ACPI table DMAR (Intel VT-d, section 8.3.1): a scope of another type is legal and is skipped"},
	{foundation.SOURCE_FOLDER_KERNEL + "/acpi_processors", "ENTRY", .First, "the entry types of the ACPI table APIC (ACPI 6.5, section 5.2.12): an entry of another type is legal and is skipped by its length"},
	{foundation.SOURCE_FOLDER_SUPPORT + "/display", "KEY", .First, "the scan codes of the keyboard (PS/2 set 1): a key record carries any scan code, and a key with no name is a legal key"},
	{foundation.SOURCE_FOLDER_PRIVATE + "/input/keyboard_layout", "KEY", .First, "the scan codes of the keyboard (PS/2 set 1): a key record carries any scan code, and a key with no name is a legal key"},
	{foundation.SYSTEM_MODULE_SOURCES + "input", "SCAN", .First, "the scan codes of the keyboard (PS/2 set 1): the device sends any scan code"},
	{foundation.SOURCE_FOLDER_SUPPORT + "/key_path", "MOUSE", .First, "the identity bytes of a PS/2 mouse: another device answers another byte, which is legal and is read as a mouse with no wheel"},
	{foundation.SOURCE_FOLDER_KERNEL, "GUEST", .First, "the exit codes of AMD SVM (AMD64 volume 2, appendix C): the processor gives any code, and an exit that the kernel does not serve stops the guest with its number"},
	{foundation.TOOL_SOURCE_FOLDER, "DW", .First, "the forms, the tags and the base type encodings of DWARF 5 (sections 7.5 and 7.8): a debug object holds codes that the tool does not read, and it skips them by their form"},
	{foundation.TOOL_SOURCE_FOLDER, "ELF", .First, "the section, program header and relocation types of ELF (System V ABI, chapter 4): an object file holds types that the tool does not read, and it skips them"},
	{foundation.TOOL_SOURCE_FOLDER, "NBD", .First, "the options, the replies and the commands of the network block device protocol (NBD, the protocol document): a client sends options that the server of the tests answers as unsupported"},
	{foundation.SOURCE_FOLDER_CONTRACT + "/remote", "FIELD", .First, "the places of the fields of a Request, from 1, which the argument of an error record names (REQUEST_FIELD_NAMES): a place in a record, not a choice; the test of the peer selects the field to break by its place"},
	{foundation.SOURCE_FOLDER_KERNEL, "EVENT", .First, "the event types of the event injection of AMD SVM (AMD64 volume 2, section 15.20): the numbers of the processor"},
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

// One source that the parser read, with the folder of its package.
@(private = "file")
Choice_Parsed :: struct {
	source: Export_Source,
	folder: string,
	file:   ^ast.File,
}

// choice_sources_parse parses the sources once, for the check of the
// families and for the check of the casts. ok false: a source that the
// parser refuses.
@(private = "file")
choice_sources_parse :: proc(sources: []Export_Source) -> (parsed: []Choice_Parsed, ok: bool) {
	context.allocator = context.temp_allocator
	list := make([dynamic]Choice_Parsed)
	for source in sources {
		file := ast.new_from_positions(ast.File, {}, {})
		file.src = source.text
		file.fullpath = source.path
		reader := parser.default_parser()
		// The parser gives true after an error in a declaration: its count of
		// errors is the answer, else a broken source would read as a source
		// with no family and no cast.
		if !parser.parse_file(&reader, file) || reader.error_count > 0 || file.syntax_error_count > 0 {
			fmt.eprintfln("modustool: %s: the parser found errors: the check of the choice constants cannot read it", source.path)
			return nil, false
		}
		folder := source.path[:max(strings.last_index_byte(source.path, '/'), 0)]
		append(&list, Choice_Parsed{source, folder, file})
	}
	return list[:], true
}

// choice_families_of_sources reads the sources, one folder as one package,
// and gives each family whose members the code uses as choices. ok false:
// a source that the parser refuses.
choice_families_of_sources :: proc(sources: []Export_Source) -> (families: []Choice_Family, ok: bool) {
	parsed := choice_sources_parse(sources) or_return
	return choice_families_of_parsed(parsed), true
}

// choice_families_of_parsed gives each family of the parsed sources whose
// members the code uses as choices.
@(private = "file")
choice_families_of_parsed :: proc(parsed: []Choice_Parsed) -> []Choice_Family {
	context.allocator = context.temp_allocator
	constants := make(map[string]bool)
	procedures := make(map[string][]string)
	// "folder name" of each constant of a package, to its value as written:
	// a value can name another constant, so each value is read after all.
	declared := make(map[string]^ast.Expr)
	for item in parsed {
		folder := item.folder
		file := item.file
		for statement in file.decls {
			declaration, is_value := statement.derived.(^ast.Value_Decl)
			if !is_value || len(declaration.names) != len(declaration.values) {
				continue
			}
			// One name and one value, or several of each (A, B :: 1, 2).
			for name, index in declaration.names {
				identifier, has_name := name.derived.(^ast.Ident)
				if !has_name {
					continue
				}
				value := declaration.values[index]
				if literal, is_procedure := value.derived.(^ast.Proc_Lit); is_procedure {
					procedures[choice_key(folder, identifier.name)] = parameter_names_of(literal)
					continue
				}
				if !declaration.is_mutable {
					declared[choice_key(folder, identifier.name)] = value
				}
			}
		}
	}
	for key, value in declared {
		folder := key[:strings.index_byte(key, ' ')]
		if number, is_integer := small_integer_of(declared, folder, value, 0); is_integer && number >= -CHOICE_VALUE_LIMIT && number <= CHOICE_VALUE_LIMIT {
			constants[key] = true
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
	// The families: the used constants of one folder with one first word,
	// then those with one last word. A constant joins a family by its last
	// word only when its first word gives it no family, and when its name
	// has two words: else two families of an outside standard
	// (GUEST_EXIT_INTERRUPT, EVENT_TYPE_EXTERNAL_INTERRUPT) would make a
	// third of their members.
	first_word_counts := make(map[string]int)
	for _, use in uses {
		first_word_counts[choice_key(use.folder, first_word_of(use.name))] += 1
	}
	list := make([dynamic]Choice_Family)
	for place in Choice_Word_Place {
		grouped := make(map[string][dynamic]Choice_Use)
		for _, use in uses {
			word: string
			switch place {
			case .First:
				word = first_word_of(use.name)
			case .Last:
				if strings.index_byte(use.name, '_') < 0 || first_word_counts[choice_key(use.folder, first_word_of(use.name))] >= CHOICE_FAMILY_LEAST_MEMBERS {
					continue
				}
				word = last_word_of(use.name)
			}
			key := choice_key(use.folder, word)
			members_of_key := grouped[key]
			append(&members_of_key, use)
			grouped[key] = members_of_key
		}
		for key, members in grouped {
			if len(members) < CHOICE_FAMILY_LEAST_MEMBERS {
				continue
			}
			// The first use in the order of the files and the lines, so
			// that the line of the check does not change from run to run.
			slice.sort_by(members[:], proc(a, b: Choice_Use) -> bool {
				return a.file < b.file || a.file == b.file && a.line < b.line
			})
			names := make([]string, len(members))
			for member, index in members {
				names[index] = member.name
			}
			slice.sort(names)
			first := members[0]
			family := Choice_Family{folder = first.folder, word = key[strings.index_byte(key, ' ') + 1:], word_place = place, members = names, use_file = first.file, use_line = first.line, use_form = first.form}
			if !choice_family_listed(list[:], family) {
				append(&list, family)
			}
		}
	}
	slice.sort_by(list[:], proc(a, b: Choice_Family) -> bool {
		if a.folder != b.folder {
			return a.folder < b.folder
		}
		if a.word_place != b.word_place {
			return a.word_place < b.word_place
		}
		return a.word < b.word
	})
	return list[:]
}

// choice_family_listed says if a family with the same folder and the same
// members is in the list already: the first and the last word of two names
// can both be shared.
@(private = "file")
choice_family_listed :: proc(list: []Choice_Family, family: Choice_Family) -> bool {
	for item in list {
		if item.folder == family.folder && slice.equal(item.members, family.members) {
			return true
		}
	}
	return false
}

// choice_visit notes each constant that a node uses as a choice.
@(private = "file")
choice_visit :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return nil
	}
	walk := (^Choice_Walk)(visitor.data)
	#partial switch item in node.derived {
	case ^ast.Switch_Stmt:
		// The cases of a switch on a length are quantities, not choices
		// (switch len(moment) { case RELEASE_DAY_LENGTH: }).
		if switch_tag_is_a_length(item.cond) {
			break
		}
		body, is_block := item.body.derived.(^ast.Block_Stmt)
		if !is_block {
			break
		}
		for statement in body.stmts {
			clause, is_clause := statement.derived.(^ast.Case_Clause)
			if !is_clause {
				continue
			}
			for expression in clause.list {
				choice_use_note(walk, expression, .Case_Of_A_Switch)
			}
		}
	case ^ast.Binary_Expr:
		// The other side is a variable named like a choice: two constants
		// compared (#assert(BOX_COLUMNS == FORM_COLUMNS_MOST)) are
		// quantities.
		if item.op.kind == .Cmp_Eq || item.op.kind == .Not_Eq {
			if name_is_a_variable_choice(choice_name_of(item.left)) {
				choice_use_note(walk, item.right, .Compared_With_A_Choice)
			}
			if name_is_a_variable_choice(choice_name_of(item.right)) {
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
// package: "modus:" names the source library and "kernel:" a kernel part, a
// relative path the folder of the file. An import of base: or core: is not read.
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
		library_folder, in_source_library := foundation.source_library_package_folder(path)
		switch {
		case in_source_library:
			target = library_folder
		case strings.contains(path, ":"):
			continue
		case:
			// "../x" names a folder beside the one of the file: the key of
			// a package is its folder with no "." and no "..".
			target = path_without_dots(foundation.join(folder, "/", path))
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

// small_integer_of reads the value of a constant: an integer literal, a
// character literal, a conversion of a value to an integer type, a
// constant of the same package, a negation of such a value (the negative
// answers of an export, ERROR_NAME :: -3), or an operation of the
// arithmetic or of the bits on such values (B :: A + 1, C :: KEY_EXTENDED
// | 0x53). A literal past the largest i64, and a shift of a negative value
// or past the bits, are not read.
//
// The syntax tree of Odin has a closed set of nodes and of operators: the
// switches below read the few that a constant of a choice can have, and a
// value of any other form is not read, so they stay partial.
@(private = "file")
small_integer_of :: proc(declared: map[string]^ast.Expr, folder: string, expression: ^ast.Expr, depth: int) -> (value: i64, ok: bool) {
	if expression == nil || depth > CHOICE_VALUE_DEPTH_LIMIT {
		return 0, false
	}
	#partial switch item in expression.derived {
	case ^ast.Basic_Lit:
		#partial switch item.tok.kind {
		case .Integer:
			digits, _ := strings.remove_all(item.tok.text, "_")
			parsed := strconv.parse_u64(digits) or_return
			return i64(parsed), parsed <= u64(max(i64))
		case .Rune:
			text := item.tok.text
			if len(text) < 3 {
				return 0, false
			}
			character, _, _, read := strconv.unquote_char(text[1:len(text) - 1], '\'')
			return i64(character), read && character >= 0
		}
	case ^ast.Unary_Expr:
		operand := small_integer_of(declared, folder, item.expr, depth + 1) or_return
		#partial switch item.op.kind {
		case .Sub:
			return -operand, true
		case .Add:
			return operand, true
		}
	case ^ast.Call_Expr:
		callee, is_name := item.expr.derived.(^ast.Ident)
		types := CHOICE_CONVERSION_TYPES
		if is_name && len(item.args) == 1 && slice.contains(types[:], callee.name) {
			return small_integer_of(declared, folder, item.args[0], depth + 1)
		}
	case ^ast.Paren_Expr:
		return small_integer_of(declared, folder, item.expr, depth + 1)
	case ^ast.Ident:
		if named, found := declared[choice_key(folder, item.name)]; found {
			return small_integer_of(declared, folder, named, depth + 1)
		}
	case ^ast.Binary_Expr:
		left := small_integer_of(declared, folder, item.left, depth + 1) or_return
		right := small_integer_of(declared, folder, item.right, depth + 1) or_return
		#partial switch item.op.kind {
		case .Add:
			return left + right, true
		case .Sub:
			return left - right, true
		case .Mul:
			return left * right, true
		case .Or:
			return left | right, true
		case .And:
			return left & right, true
		case .Xor:
			return left ~ right, true
		case .Shl:
			return left << uint(right), left >= 0 && right >= 0 && right < 63
		case .Shr:
			return left >> uint(right), left >= 0 && right >= 0 && right < 64
		}
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

// name_is_a_variable_choice says if a name is a choice and not a constant:
// a constant has no lowercase letter.
name_is_a_variable_choice :: proc(name: string) -> bool {
	for character in name {
		if character >= 'a' && character <= 'z' {
			return name_is_a_choice(name)
		}
	}
	return false
}

// switch_tag_is_a_length says if the tag of a switch is a call of len.
@(private = "file")
switch_tag_is_a_length :: proc(tag: ^ast.Expr) -> bool {
	if tag == nil {
		return false
	}
	call, is_call := tag.derived.(^ast.Call_Expr)
	if !is_call {
		return false
	}
	callee, is_name := call.expr.derived.(^ast.Ident)
	return is_name && callee.name == "len"
}

// first_word_of gives the first word of a name: `MODE` of `MODE_UNLOCK`.
first_word_of :: proc(name: string) -> string {
	if underscore := strings.index_byte(name, '_'); underscore > 0 {
		return name[:underscore]
	}
	return name
}

// last_word_of gives the last word of a name: `REQUEST` of `READ_REQUEST`.
last_word_of :: proc(name: string) -> string {
	if underscore := strings.last_index_byte(name, '_'); underscore >= 0 && underscore < len(name) - 1 {
		return name[underscore + 1:]
	}
	return name
}

// choice_family_text writes the name of a family: `MODE_` or `_REQUEST`.
choice_family_text :: proc(word: string, place: Choice_Word_Place) -> string {
	switch place {
	case .First:
		return strings.concatenate({word, "_"}, context.temp_allocator)
	case .Last:
		return strings.concatenate({"_", word}, context.temp_allocator)
	}
	return word
}

// choice_exception_matches says if an exception names a family.
choice_exception_matches :: proc(exception: Choice_Constant_Exception, family: Choice_Family) -> bool {
	return exception.folder == family.folder && exception.word == family.word && exception.word_place == family.word_place
}

// choice_exception_of finds the exception of a family; nil with none.
choice_exception_of :: proc(family: Choice_Family) -> ^Choice_Constant_Exception {
	for &exception in CHOICE_CONSTANT_EXCEPTIONS {
		if choice_exception_matches(exception, family) {
			return &exception
		}
	}
	return nil
}

// How the code uses a cast of a word to an enum that the check refuses. A
// cast that is one operand of `==` or `!=` with a member is the one form
// that the check accepts: its value is compared once and never kept.
Enum_Cast_Form :: enum {
	Kept, // A value of a declaration, of an assignment, of a field, of a return, an index, or an operand of another expression.
	Passed, // An argument of a call.
	Switched, // The tag of a switch.
}

@(rodata)
enum_cast_form_words := [Enum_Cast_Form]string {
	.Kept     = "kept",
	.Passed   = "passed to a procedure",
	.Switched = "switched on",
}

// One cast of a word to an enum that the check refuses: its place, the enum
// as the source names it (`Status`, `op.Operation`, `^Mode`, `[4]Mode`), and
// its form. An `auto_cast` names no type in the syntax tree: its type name
// is AUTO_CAST_TYPE_NAME, and the check refuses each one.
Enum_Cast :: struct {
	folder:    string, // The folder of the package of the file.
	file:      string,
	line:      int,
	type_name: string,
	form:      Enum_Cast_Form,
}

// The type name of an `auto_cast`, whose target only the type checker of
// the compiler knows.
AUTO_CAST_TYPE_NAME :: "auto_cast"

// A cast that stays, with its reason: its file, the enum as the source
// names it, and the count of such casts in the file that the design holds.
// One more cast of that enum in the file, or one less, refuses the row.
Enum_Cast_Exception :: struct {
	file:      string,
	type_name: string,
	count:     int,
	reason:    string,
}

// The justified casts. Each row names one place of a design.
@(rodata)
ENUM_CAST_EXCEPTIONS := [?]Enum_Cast_Exception {
	{foundation.SOURCE_FOLDER_KERNEL + "/enter.odin", "op.Operation", 1, "the dispatch of the kernel on the kind of a command record: its default branch refuses a kind of no operation and reads the bit of a table of error details, at no cost to a command with no table (src/md/features/kernel_error_details.md)"},
	{foundation.DEMONSTRATION_MODULE_SOURCES + "errors/main.odin", "op.Operation", 1, "the machine test of the refusal of a kind of no operation: it writes, on purpose, the word one past the last operation, which the kernel must refuse with Unknown_Operation"},
	{foundation.TOOL_SOURCE_FOLDER + "/peer_remote.odin", "remote.Request_Kind", 1, "the peer of the tests of remote breaks one field of a request on purpose: it writes a kind of no request, which remote must refuse with an error record that names the field"},
}

// An exception whose count of casts is not the count that it holds: none
// (a stale row) or a count other than its own.
Enum_Cast_Exception_Fault :: struct {
	exception: Enum_Cast_Exception,
	found:     int,
}

// enum_casts_judged splits the casts that the check found: each cast that
// no exception holds, and each exception whose count of casts differs from
// its count. The casts of such an exception are refused too: an exception
// holds its places only while it names exactly them.
enum_casts_judged :: proc(casts: []Enum_Cast, exceptions: []Enum_Cast_Exception) -> (refused: []Enum_Cast, faults: []Enum_Cast_Exception_Fault) {
	refused_list := make([dynamic]Enum_Cast, context.temp_allocator)
	fault_list := make([dynamic]Enum_Cast_Exception_Fault, context.temp_allocator)
	counts := make([]int, len(exceptions), context.temp_allocator)
	for cast_of_word in casts {
		for exception, index in exceptions {
			if enum_cast_exception_matches(exception, cast_of_word) {
				counts[index] += 1
			}
		}
	}
	for exception, index in exceptions {
		if counts[index] != exception.count {
			append(&fault_list, Enum_Cast_Exception_Fault{exception, counts[index]})
		}
	}
	each: for cast_of_word in casts {
		for exception, index in exceptions {
			if enum_cast_exception_matches(exception, cast_of_word) && counts[index] == exception.count {
				continue each
			}
		}
		append(&refused_list, cast_of_word)
	}
	return refused_list[:], fault_list[:]
}

// The state of the walk of one file for the casts.
@(private = "file")
Enum_Cast_Walk :: struct {
	folder:   string,
	file:     string,
	imports:  map[string]string, // The name of an import in the file, to the folder of its package.
	enums:    map[string]bool, // "folder name" of each enum type, an alias of one included.
	accepted: map[rawptr]bool, // The casts that are one operand of == or != with a member.
	forms:    map[rawptr]Enum_Cast_Form, // The form of an expression that a parent node gave: Passed or Switched.
	casts:    ^[dynamic]Enum_Cast,
}

// enum_casts_of_sources reads the sources, one folder as one package, and
// gives each cast of a word to an enum that the code keeps, passes or
// switches on. ok false: a source that the parser refuses.
enum_casts_of_sources :: proc(sources: []Export_Source) -> (casts: []Enum_Cast, ok: bool) {
	parsed := choice_sources_parse(sources) or_return
	return enum_casts_of_parsed(parsed), true
}

// enum_casts_of_parsed gives each refused cast of the parsed sources, in
// the order of the files and the lines.
@(private = "file")
enum_casts_of_parsed :: proc(parsed: []Choice_Parsed) -> []Enum_Cast {
	context.allocator = context.temp_allocator
	enums := make(map[string]bool)
	// An alias names an enum of its own package or of an import
	// (`Entry_Kind :: store_contract.Entry_Kind`): it is read after each
	// enum is known, as a chain of aliases is.
	Alias :: struct {
		key:     string,
		value:   ^ast.Expr,
		folder:  string,
		imports: map[string]string,
	}
	aliases := make([dynamic]Alias)
	// The declarations of a file, those inside a `when` block of the file
	// included: a block of a target declares its enums there.
	collect :: proc(statements: []^ast.Stmt, folder: string, imports: map[string]string, enums: ^map[string]bool, aliases: ^[dynamic]Alias) {
		for statement in statements {
			if statement == nil {
				continue
			}
			#partial switch item in statement.derived {
			case ^ast.When_Stmt:
				body, is_block := item.body.derived.(^ast.Block_Stmt)
				if is_block {
					collect(body.stmts, folder, imports, enums, aliases)
				}
				if item.else_stmt != nil {
					else_statements := []^ast.Stmt{item.else_stmt}
					if else_block, is_else_block := item.else_stmt.derived.(^ast.Block_Stmt); is_else_block {
						else_statements = else_block.stmts
					}
					collect(else_statements, folder, imports, enums, aliases)
				}
			case ^ast.Value_Decl:
				if item.is_mutable || len(item.names) != len(item.values) {
					continue
				}
				for name, index in item.names {
					identifier, has_name := name.derived.(^ast.Ident)
					if !has_name {
						continue
					}
					key := choice_key(folder, identifier.name)
					value := item.values[index]
					// A distinct type is an enum when the type that it
					// makes distinct is one: an enum or an alias of one.
					if distinct_type, is_distinct := value.derived.(^ast.Distinct_Type); is_distinct {
						value = distinct_type.type
					}
					_, is_enum_type := value.derived.(^ast.Enum_Type)
					_, is_name := value.derived.(^ast.Ident)
					_, is_selector := value.derived.(^ast.Selector_Expr)
					if is_enum_type {
						enums^[key] = true
					} else if is_name || is_selector {
						append(aliases, Alias{key, value, folder, imports})
					}
				}
			}
		}
	}
	for item in parsed {
		collect(item.file.decls[:], item.folder, imports_of(item.file, item.folder), &enums, &aliases)
	}
	for _ in 0 ..< CHOICE_VALUE_DEPTH_LIMIT {
		added := false
		for alias in aliases {
			if alias.key in enums {
				continue
			}
			walk := Enum_Cast_Walk{folder = alias.folder, imports = alias.imports, enums = enums}
			if _, is_enum := enum_type_name_of(&walk, alias.value); is_enum {
				enums[alias.key] = true
				added = true
			}
		}
		if !added {
			break
		}
	}
	casts := make([dynamic]Enum_Cast)
	for item in parsed {
		walk := Enum_Cast_Walk {
			folder   = item.folder,
			file     = item.source.path,
			imports  = imports_of(item.file, item.folder),
			enums    = enums,
			accepted = make(map[rawptr]bool),
			forms    = make(map[rawptr]Enum_Cast_Form),
			casts    = &casts,
		}
		visitor := ast.Visitor {
			visit = enum_cast_visit,
			data  = &walk,
		}
		for statement in item.file.decls {
			ast.walk(&visitor, statement)
		}
	}
	slice.sort_by(casts[:], proc(a, b: Enum_Cast) -> bool {
		return a.file < b.file || a.file == b.file && a.line < b.line
	})
	return casts[:]
}

// enum_cast_visit notes each cast of a word to an enum that is not one
// operand of == or != with a member. The walk visits a node before its
// children, so a comparison, a call and a switch mark their operands
// before the walk reaches them.
//
// The syntax tree of Odin has a closed set of nodes: the switch reads the
// few that hold a cast or mark one, and stays partial.
@(private = "file")
enum_cast_visit :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return nil
	}
	walk := (^Enum_Cast_Walk)(visitor.data)
	#partial switch item in node.derived {
	case ^ast.Binary_Expr:
		if item.op.kind == .Cmp_Eq || item.op.kind == .Not_Eq {
			left, right := unparenthesized(item.left), unparenthesized(item.right)
			if enum_member_of(walk, right) {
				walk.accepted[rawptr(left)] = true
			}
			if enum_member_of(walk, left) {
				walk.accepted[rawptr(right)] = true
			}
		}
	case ^ast.Switch_Stmt:
		if item.cond != nil {
			walk.forms[rawptr(unparenthesized(item.cond))] = .Switched
		}
	case ^ast.Call_Expr:
		if type_name, is_cast := enum_cast_type_of(walk, item); is_cast {
			enum_cast_note(walk, node, type_name, item.pos.line)
		}
		for argument in item.args {
			if inner := unparenthesized(argument); rawptr(inner) not_in walk.forms {
				walk.forms[rawptr(inner)] = .Passed
			}
		}
	case ^ast.Type_Cast:
		if type_name, is_enum := enum_type_name_of(walk, item.type); is_enum {
			enum_cast_note(walk, node, type_name, item.pos.line)
		}
	case ^ast.Auto_Cast:
		// The target of an auto_cast is the type that the compiler infers:
		// the syntax tree does not hold it, so each one is refused.
		enum_cast_note(walk, node, AUTO_CAST_TYPE_NAME, item.pos.line)
	}
	return visitor
}

// enum_cast_note keeps a cast that the code keeps, passes or switches on.
@(private = "file")
enum_cast_note :: proc(walk: ^Enum_Cast_Walk, node: ^ast.Node, type_name: string, line: int) {
	if rawptr(node) in walk.accepted {
		return
	}
	form := walk.forms[rawptr(node)] or_else .Kept
	append(walk.casts, Enum_Cast{folder = walk.folder, file = walk.file, line = line, type_name = type_name, form = form})
}

// unparenthesized gives the expression inside its parentheses.
@(private = "file")
unparenthesized :: proc(expression: ^ast.Expr) -> ^ast.Expr {
	inner := expression
	for inner != nil {
		parenthesized, is_paren := inner.derived.(^ast.Paren_Expr)
		if !is_paren {
			break
		}
		inner = parenthesized.expr
	}
	return inner
}

// enum_cast_type_of says if a call is a cast to an enum: a callee that
// names an enum type, with one argument and no name on it.
@(private = "file")
enum_cast_type_of :: proc(walk: ^Enum_Cast_Walk, call: ^ast.Call_Expr) -> (type_name: string, is_cast: bool) {
	if len(call.args) != 1 {
		return "", false
	}
	if _, named := call.args[0].derived.(^ast.Field_Value); named {
		return "", false
	}
	return enum_type_name_of(walk, call.expr)
}

// enum_type_name_of says if an expression names an enum type of the
// package or of an import, or a pointer, an array or a slice of one, and
// gives the name as the source writes it: `Mode`, `other.Mode`, `^Mode`,
// `[]Mode`. A cast to a pointer or to an array of an enum makes members of
// words as a cast to the enum does.
@(private = "file")
enum_type_name_of :: proc(walk: ^Enum_Cast_Walk, expression: ^ast.Expr) -> (type_name: string, is_enum: bool) {
	if expression == nil {
		return "", false
	}
	// The prefix of a type that holds the enum, and the type that it holds.
	element_of :: proc(expression: ^ast.Expr) -> (prefix: string, element: ^ast.Expr) {
		#partial switch item in expression.derived {
		case ^ast.Pointer_Type:
			return "^", item.elem
		case ^ast.Multi_Pointer_Type:
			return "[^]", item.elem
		case ^ast.Array_Type:
			return "[]", item.elem
		case ^ast.Dynamic_Array_Type:
			return "[dynamic]", item.elem
		}
		return "", nil
	}
	if prefix, element := element_of(expression); element != nil {
		inner := enum_type_name_of(walk, element) or_return
		return strings.concatenate({prefix, inner}, context.temp_allocator), true
	}
	#partial switch item in expression.derived {
	case ^ast.Ident:
		if choice_key(walk.folder, item.name) in walk.enums {
			return item.name, true
		}
	case ^ast.Selector_Expr:
		package_name, is_name := item.expr.derived.(^ast.Ident)
		if !is_name || item.field == nil {
			return "", false
		}
		if imported, known := walk.imports[package_name.name]; known && choice_key(imported, item.field.name) in walk.enums {
			return strings.concatenate({package_name.name, ".", item.field.name}, context.temp_allocator), true
		}
	case ^ast.Paren_Expr:
		return enum_type_name_of(walk, item.expr)
	}
	return "", false
}

// enum_member_of says if an expression names one member of an enum: `.Ok`,
// `Status.Ok` or `system.Status.Ok`.
@(private = "file")
enum_member_of :: proc(walk: ^Enum_Cast_Walk, expression: ^ast.Expr) -> bool {
	if expression == nil {
		return false
	}
	#partial switch item in expression.derived {
	case ^ast.Implicit_Selector_Expr:
		return true
	case ^ast.Selector_Expr:
		_, is_enum := enum_type_name_of(walk, item.expr)
		return is_enum
	}
	return false
}

// enum_cast_exception_matches says if an exception names a cast: the same
// file and the same enum. A tree under another root ends with the path.
enum_cast_exception_matches :: proc(exception: Enum_Cast_Exception, cast_of_word: Enum_Cast) -> bool {
	same_file := cast_of_word.file == exception.file || strings.has_suffix(cast_of_word.file, strings.concatenate({"/", exception.file}, context.temp_allocator))
	return same_file && exception.type_name == cast_of_word.type_name
}

// choice_families_of_tree reads each source of the system that is not a
// test, under a root ("" is the repository), and gives the families of
// constants and the casts of a word to an enum that it finds.
choice_families_of_tree :: proc(root: string) -> (families: []Choice_Family, casts: []Enum_Cast, file_count: int, ok: bool) {
	files := make([dynamic]string, context.temp_allocator)
	folders := CHOICE_CONSTANT_FOLDERS
	for folder in folders {
		foundation.source_files_of_a_folder(root == "" ? folder : foundation.join(root, "/", folder), &files) or_return
	}
	slice.sort(files[:])
	sources := make([dynamic]Export_Source, context.temp_allocator)
	skipped := foundation.join(root == "" ? CHOICE_CONSTANT_SKIPPED_FOLDER : foundation.join(root, "/", CHOICE_CONSTANT_SKIPPED_FOLDER), "/")
	for file in files {
		if source_is_a_test(file) || strings.has_prefix(file, skipped) {
			continue
		}
		text, read_ok := foundation.site_read_quiet(file)
		if !read_ok {
			fmt.eprintfln("modustool: cannot read %s", file)
			return nil, nil, 0, false
		}
		append(&sources, Export_Source{path = file, text = text})
	}
	// One parse of the sources for the two checks.
	parsed := choice_sources_parse(sources[:]) or_return
	return choice_families_of_parsed(parsed), enum_casts_of_parsed(parsed), len(sources), true
}

// choice_constant_check refuses a family of integer constants that the
// code uses as a closed set of choices, a cast of a word to an enum that
// the code keeps, passes or switches on, and an exception that names no
// such family or cast.
choice_constant_check :: proc() -> bool {
	families, casts, file_count, ok := choice_families_of_tree("")
	if !ok {
		return false
	}
	// A cast skips the border: the word becomes a member that the writer
	// may not have named, and each switch after it runs no case for it.
	refused_casts, exception_faults := enum_casts_judged(casts, ENUM_CAST_EXCEPTIONS[:])
	for cast_of_word in refused_casts {
		if cast_of_word.type_name == AUTO_CAST_TYPE_NAME {
			fmt.eprintfln("modustool: %s:%d: an auto_cast is %s: its target is no type that the check can read, so it can skip the border of an enum; write the conversion with its type (src/md/infrastructure/choice_constants.md)", cast_of_word.file, cast_of_word.line, enum_cast_form_words[cast_of_word.form])
			continue
		}
		fmt.eprintfln("modustool: %s:%d: a cast of a word to the enum %s is %s: read the word through its border, which refuses a word that names no member, and pass the member; a cast is allowed only as one operand of == or != with a member (src/md/infrastructure/choice_constants.md)", cast_of_word.file, cast_of_word.line, cast_of_word.type_name, enum_cast_form_words[cast_of_word.form])
	}
	// An exception that matches no cast, or another count of casts, is no
	// longer true: its casts are refused above.
	for fault in exception_faults {
		fmt.eprintfln("modustool: %s: the exception %s of the check of the casts of a word to an enum holds %d casts, and the file has %d: change the row of ENUM_CAST_EXCEPTIONS, or the code", fault.exception.file, fault.exception.type_name, fault.exception.count, fault.found)
	}
	casts_refused, casts_stale := len(refused_casts), len(exception_faults)
	refused := 0
	for family in families {
		if choice_exception_of(family) != nil {
			continue
		}
		refused += 1
		members_text, _ := strings.join(family.members, ", ", context.temp_allocator)
		fmt.eprintfln("modustool: %s:%d: the constants %s of %s are a closed set of choices (%s, here %s): make them an enum, with the values of the contract when the value crosses a border, and one conversion at the border that refuses a value that names no member (src/md/infrastructure/choice_constants.md)", family.use_file, family.use_line, choice_family_text(family.word, family.word_place), family.folder, members_text, choice_use_form_words[family.use_form])
	}
	// An exception that matches no family is no longer true: the list
	// stays short only if each of its rows still holds.
	stale := 0
	for exception in CHOICE_CONSTANT_EXCEPTIONS {
		matched := false
		for family in families {
			if choice_exception_matches(exception, family) {
				matched = true
				break
			}
		}
		if !matched {
			stale += 1
			fmt.eprintfln("modustool: %s: the exception %s of the check of the choice constants names no family that the code uses as choices: remove it from CHOICE_CONSTANT_EXCEPTIONS", exception.folder, choice_family_text(exception.word, exception.word_place))
		}
	}
	if refused > 0 || stale > 0 || casts_refused > 0 || casts_stale > 0 {
		fmt.eprintfln("modustool: test failed: %d families of integer constants are closed sets of choices, %d exceptions name no family, %d casts of a word to an enum skip a border, and %d exceptions of casts do not hold their count", refused, stale, casts_refused, casts_stale)
		return false
	}
	foundation.test_passed_print("no family of integer constants is a closed set of choices, and no cast of a word to an enum is kept, passed or switched on, in the %d source files of the system and of the tool that are not tests (%d exceptions of outside standards, %d casts of a design)", file_count, len(CHOICE_CONSTANT_EXCEPTIONS), len(ENUM_CAST_EXCEPTIONS))
	return true
}
