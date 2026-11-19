// The readers of the Odin files that the reference tables of the site come
// from (docs/SITE.md, "The reference tables"). Each reader knows the form
// that its file has now, and no more. When a file loses that form, the
// reader gives the file and the line, and the command `site` stops: a table
// never shows a part of a file that the reader did not understand.
//
// The readers read the text of the files, not the compiled module: the
// comments of a contract are its documentation, and the compiler drops them.
// The reader of the table of the roles of the root service reads the tree
// of the parser of Odin, and the comments from the lines that the tree
// names: its rows are literals that a reader of lines cannot tell apart
// from other code.
package foundation

import "core:fmt"
import "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:strings"

// One member of an Odin enumeration, as its file writes it.
Enumeration_Member :: struct {
	name:    string,
	number:  int, // Its value: "= <n>", or its place when the line gives no value.
	comment: string, // The Markdown of the comment of its line, then of the comment lines after it, one line each.
	line:    int,
}

// One constant "NAME :: <decimal>" of a file.
Source_Constant :: struct {
	name:    string,
	value:   int,
	comment: string, // The Markdown of the comment lines just above it, then of the comment of its line, one line each.
	line:    int,
}

// One row of the table of the roles of the root service (`process_roles`
// of src/modules/system/root/roles.odin): a process, its start grants and the
// other terms of its role. A page shows each grant as one value, never the
// literal itself.
Role_Row :: struct {
	name:    string,
	grants:  []string, // The members of the set of start grants, with no period: "Inspect".
	terms:   string, // The record of the other terms as the source writes it, on one line and with no braces; "" for none.
	comment: string, // The comment lines above the row, then the comment of its lines.
	line:    int, // The line where the row starts.
}

// One built-in command of the console:
// `command("<name>", {.<Kind>, ...}, .<Kind>, "<help>", <procedure>)`.
Console_Command_Entry :: struct {
	name:       string,
	parameters: []string,
	result:     string,
	about:      string, // The help: the one line that help() prints.
	// The comment lines just above the line of the command, as Markdown, or
	// "": the whole documentation, which the help cannot hold.
	documentation: string,
	file:          string,
	line:          int,
}

// is_odin_identifier says if a text is an Odin identifier.
is_odin_identifier :: proc(text: string) -> bool {
	if text == "" || (text[0] >= '0' && text[0] <= '9') {
		return false
	}
	for character in transmute([]u8)text {
		if !((character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') || (character >= '0' && character <= '9') || character == '_') {
			return false
		}
	}
	return true
}

// The marks of the comments of one language of the sources. The site and
// the check of the comments read the comments with the same scanner, so a
// comment is the same text for both.
Comment_Syntax :: struct {
	marker:         string, // What opens a comment that runs to the end of the line: "//", ";", "#". Never empty.
	escaped_quotes: string, // The bytes that open and close a string in which a backslash escapes the next byte.
	raw_quotes:     string, // The bytes that open and close a string with no escape.
}

// comment_syntax_of gives the marks of the comments of a source file by the
// extension of its name; known is false for another kind of file.
comment_syntax_of :: proc(path: string) -> (syntax: Comment_Syntax, known: bool) {
	switch {
	case strings.has_suffix(path, ".odin"):
		// A rune literal is a string too: else the quote of '"' opens one.
		return {marker = "//", escaped_quotes = "\"'", raw_quotes = "`"}, true
	case strings.has_suffix(path, ".asm"):
		return {marker = ";", raw_quotes = "\"'`"}, true
	case strings.has_suffix(path, ".nix"):
		return {marker = "#", escaped_quotes = "\""}, true
	}
	return {}, false
}

// source_code_and_comment splits a line of a source into its code and the
// text of its comment. A marker inside a string is not a comment. The
// scanner reads one line at a time: a string that runs over several lines
// (a raw string of Odin, a '' string of Nix) is code only on its first line.
source_code_and_comment :: proc(line: string, syntax: Comment_Syntax) -> (code: string, comment: string) {
	quote: u8 = 0
	for index := 0; index < len(line); index += 1 {
		character := line[index]
		switch {
		case quote != 0:
			if character == '\\' && strings.index_byte(syntax.escaped_quotes, quote) >= 0 {
				index += 1
			} else if character == quote {
				quote = 0
			}
		case strings.index_byte(syntax.escaped_quotes, character) >= 0 || strings.index_byte(syntax.raw_quotes, character) >= 0:
			quote = character
		case strings.has_prefix(line[index:], syntax.marker):
			return strings.trim_space(line[:index]), strings.trim_space(line[index + len(syntax.marker):])
		}
	}
	return strings.trim_space(line), ""
}

// code_and_comment splits a line of Odin into its code and the text of
// its comment "// ...".
code_and_comment :: proc(line: string) -> (code: string, comment: string) {
	syntax, _ := comment_syntax_of(".odin")
	return source_code_and_comment(line, syntax)
}

// One comment of a source: the lines of comment that follow each other,
// joined with one space, as a page of the site shows them.
Comment_Block :: struct {
	text:       string,
	first_line: int, // The line of its first line, from 0.
	starts:     []int, // The offset in text where each of its lines starts.
}

// comment_blocks gives the comments of a source, in their order.
comment_blocks :: proc(content: string, syntax: Comment_Syntax) -> []Comment_Block {
	blocks := make([dynamic]Comment_Block, context.temp_allocator)
	lines := lines_of_text(content)
	index := 0
	for index < len(lines) {
		_, first := source_code_and_comment(lines[index], syntax)
		if first == "" {
			index += 1
			continue
		}
		builder := strings.builder_make(context.temp_allocator)
		starts := make([dynamic]int, context.temp_allocator)
		block_line := index
		for index < len(lines) {
			_, comment := source_code_and_comment(lines[index], syntax)
			if comment == "" {
				break
			}
			if strings.builder_len(builder) > 0 {
				strings.write_byte(&builder, ' ')
			}
			append(&starts, strings.builder_len(builder))
			strings.write_string(&builder, comment)
			index += 1
		}
		append(&blocks, Comment_Block{text = strings.to_string(builder), first_line = block_line, starts = starts[:]})
	}
	return blocks[:]
}

// comment_block_line gives the line, from 1, of the file where a byte of
// the text of a comment is.
comment_block_line :: proc(block: Comment_Block, offset: int) -> int {
	line := block.first_line
	for start, start_index in block.starts {
		if start <= offset {
			line = block.first_line + start_index
		}
	}
	return line + 1
}

// enumeration_read reads the members of an enumeration. The form:
//   a line "<enumeration> :: enum <type> {" at the start of a line;
//   one member on each line: "<Name> = <decimal>," or "<Name>,", with a
//   comment "// ..." or not;
//   a line that is only a comment continues the comment of the member above
//   it (the comments of the contracts run over several lines), as a line of
//   its Markdown: a line "//" alone is an empty line, and the indentation
//   after "// " stays;
//   a line "}" at the start of a line ends it.
enumeration_read :: proc(content, file, enumeration: string) -> (members: []Enumeration_Member, problem: string) {
	lines := lines_of_text(content)
	start := strings.concatenate({enumeration, " :: enum"}, context.temp_allocator)
	list := make([dynamic]Enumeration_Member, context.temp_allocator)
	first := -1
	for line, index in lines {
		if strings.has_prefix(line, start) && strings.has_suffix(line, "{") {
			first = index + 1
			break
		}
	}
	if first < 0 {
		return nil, fmt.tprintf("%s: no line \"%s <type> {{\"", file, start)
	}
	for index in first ..< len(lines) {
		line := lines[index]
		if line == "}" {
			if len(list) == 0 {
				return nil, fmt.tprintf("%s, line %d: the enumeration %s has no member", file, index + 1, enumeration)
			}
			for &member in list {
				member.comment = markdown_comment_end(member.comment)
			}
			return list[:], ""
		}
		code, comment, is_comment := markdown_comment_line(line)
		if code == "" {
			if is_comment && len(list) > 0 {
				list[len(list) - 1].comment = markdown_comment_add(list[len(list) - 1].comment, comment)
			}
			continue
		}
		comment = strings.trim_space(comment)
		if !strings.has_suffix(code, ",") {
			return nil, fmt.tprintf("%s, line %d: a member of %s is \"<Name> = <number>,\" or \"<Name>,\"; the line is \"%s\"", file, index + 1, enumeration, strings.trim_space(line))
		}
		code = strings.trim_suffix(code, ",")
		member := Enumeration_Member{number = len(list), comment = comment, line = index + 1}
		if equals := strings.index_byte(code, '='); equals >= 0 {
			member.name = strings.trim_space(code[:equals])
			member.number = decimal_digits_value(strings.trim_space(code[equals + 1:]))
		} else {
			member.name = code
		}
		if !is_odin_identifier(member.name) || member.number < 0 {
			return nil, fmt.tprintf("%s, line %d: a member of %s is \"<Name> = <decimal>,\" or \"<Name>,\"; the line is \"%s\"", file, index + 1, enumeration, strings.trim_space(line))
		}
		append(&list, member)
	}
	return nil, fmt.tprintf("%s: the enumeration %s has no line \"}\" at its end", file, enumeration)
}

// names_table_read reads a table of texts of an enumeration. The form:
//   a line "<table> := [<Enumeration>]string {" at the start of a line;
//   one line ".<Name> = \"<text>\"," for each member;
//   a line "}" at the start of a line ends it.
names_table_read :: proc(content, file, table: string) -> (names: map[string]string, problem: string) {
	lines := lines_of_text(content)
	start := strings.concatenate({table, " := ["}, context.temp_allocator)
	names = make(map[string]string, context.temp_allocator)
	first := -1
	for line, index in lines {
		if strings.has_prefix(line, start) && strings.has_suffix(line, "{") {
			first = index + 1
			break
		}
	}
	if first < 0 {
		return nil, fmt.tprintf("%s: no line \"%s<Enumeration>]string {{\"", file, start)
	}
	for index in first ..< len(lines) {
		line := lines[index]
		if line == "}" {
			return names, ""
		}
		code, _ := code_and_comment(line)
		equals := strings.index(code, " = ")
		if !strings.has_prefix(code, ".") || equals < 0 {
			return nil, fmt.tprintf("%s, line %d: a line of %s is \".<Name> = \"<text>\",\"", file, index + 1, table)
		}
		text, _, found := quoted_text_after(code, equals)
		if !found {
			return nil, fmt.tprintf("%s, line %d: a line of %s is \".<Name> = \"<text>\",\"", file, index + 1, table)
		}
		names[strings.trim_space(code[1:equals])] = text
	}
	return nil, fmt.tprintf("%s: the table %s has no line \"}\" at its end", file, table)
}

// constants_read reads the constants of a file whose name starts with
// one of the prefixes, from the first line that starts with `first` (from
// the first line of the file when it is ""). The form: a line
// "<NAME> :: <decimal>" at the start of a line, with a comment or not; the
// comment lines just above it, up to a line that is not a comment, are its
// comment too. A constant with one of the prefixes and another value is a
// problem: the table would miss it.
constants_read :: proc(content, file, first: string, prefixes: []string) -> (constants: []Source_Constant, problem: string) {
	lines := lines_of_text(content)
	list := make([dynamic]Source_Constant, context.temp_allocator)
	start := 0
	if first != "" {
		start = -1
		for line, index in lines {
			if strings.has_prefix(line, first) {
				start = index
				break
			}
		}
		if start < 0 {
			return nil, fmt.tprintf("%s: no line that starts with \"%s\"", file, first)
		}
	}
	for index in start ..< len(lines) {
		line := lines[index]
		separator := strings.index(line, " :: ")
		if separator <= 0 || !is_odin_identifier(line[:separator]) {
			continue
		}
		name := line[:separator]
		wanted := false
		for prefix in prefixes {
			wanted ||= strings.has_prefix(name, prefix)
		}
		if !wanted {
			continue
		}
		code, comment := code_and_comment(line[separator + len(" :: "):])
		value := decimal_digits_value(code)
		if value < 0 {
			return nil, fmt.tprintf("%s, line %d: the constant %s is \"%s :: <decimal>\"; its value is \"%s\"", file, index + 1, name, name, code)
		}
		above := index
		for above > 0 && strings.has_prefix(strings.trim_space(lines[above - 1]), "//") {
			above -= 1
		}
		comment_above := ""
		for comment_line in lines[above:index] {
			_, text, _ := markdown_comment_line(comment_line)
			comment_above = markdown_comment_add(comment_above, text)
		}
		append(&list, Source_Constant{name = name, value = value, comment = markdown_comment_end(markdown_comment_add(comment_above, comment)), line = index + 1})
	}
	if len(list) == 0 {
		return nil, fmt.tprintf("%s: no constant \"<NAME> :: <decimal>\" whose name starts with %v", file, prefixes)
	}
	return list[:], ""
}

// comment_above_declaration gives the comment lines just above the first line that
// starts with a prefix ("Operation :: enum"), joined, or "" when there is
// none: the documentation of a declaration, which a reference page shows
// above its table.
comment_above_declaration :: proc(content, prefix: string) -> string {
	lines := lines_of_text(content)
	for line, index in lines {
		if !strings.has_prefix(line, prefix) {
			continue
		}
		above := index
		for above > 0 && strings.has_prefix(strings.trim_space(lines[above - 1]), "//") {
			above -= 1
		}
		comment := ""
		for comment_line in lines[above:index] {
			_, text, _ := markdown_comment_line(comment_line)
			comment = markdown_comment_add(comment, text)
		}
		return markdown_comment_end(comment)
	}
	return ""
}

// role_table_read reads the table of the roles of the root service,
// with the parser of Odin: a reader of lines that met another form of the
// same code would read it wrong and say nothing. The form:
//   a declaration "<table> := <type> {...}" at the top of the file;
//   each element is a record literal with no type, with the fields
//   `name` (a string, required), `grants` (a set of members "{.A, .B}"
//   with no type) and `terms` (a record literal with no type, with no
//   comment inside it), each at most once;
//   the comment of a row is the comment lines above it, after the row
//   before, and the comment of its own lines.
// Any other form stops the command with the file and the line.
role_table_read :: proc(content, file, table: string) -> (rows: []Role_Row, problem: string) {
	lines := lines_of_text(content)
	list := make([dynamic]Role_Row, context.temp_allocator)
	// The tree of the parser lives in an arena of its own: every text that
	// the result keeps is a string of the temporary allocator.
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return nil, fmt.tprintf("%s: no memory for the parser", file)
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	tree := ast.new_from_positions(ast.File, {}, {})
	tree.src = content
	tree.fullpath = file
	reader := parser.default_parser()
	reader.err = tokenizer_quiet_error
	reader.warn = tokenizer_quiet_error
	if !parser.parse_file(&reader, tree) || tree.syntax_error_count > 0 {
		return nil, fmt.tprintf("%s: the parser of Odin refuses the file", file)
	}
	literal: ^ast.Comp_Lit
	for statement in tree.decls {
		declaration, is_declaration := statement.derived.(^ast.Value_Decl)
		if !is_declaration || len(declaration.names) != 1 || len(declaration.values) != 1 {
			continue
		}
		identifier, has_name := declaration.names[0].derived.(^ast.Ident)
		if !has_name || identifier.name != table {
			continue
		}
		literal, _ = declaration.values[0].derived.(^ast.Comp_Lit)
		break
	}
	if literal == nil {
		return nil, fmt.tprintf("%s: no table \"%s := <type> {{...}}\"", file, table)
	}
	previous_end := literal.open.line
	for element in literal.elems {
		row_literal, is_row := element.derived.(^ast.Comp_Lit)
		wrong_row := fmt.tprintf("%s, line %d: a row of %s is a record {{name = \"<process>\", grants = {{.A, .B}}, terms = {{...}}}} with no type", file, element.pos.line, table)
		if !is_row || row_literal.type != nil {
			return nil, wrong_row
		}
		row := Role_Row{line = element.pos.line}
		name_seen, grants_seen, terms_seen := false, false, false
		for part in row_literal.elems {
			field, is_field := part.derived.(^ast.Field_Value)
			if !is_field {
				return nil, wrong_row
			}
			field_name, has_name := field.field.derived.(^ast.Ident)
			if !has_name {
				return nil, wrong_row
			}
			switch field_name.name {
			case "name":
				name_literal, is_literal := field.value.derived.(^ast.Basic_Lit)
				if name_seen || !is_literal || name_literal.tok.kind != .String {
					return nil, wrong_row
				}
				name, _, found := odin_string_at(name_literal.tok.text, 0)
				if !found || name == "" {
					return nil, wrong_row
				}
				row.name = strings.clone(name, context.temp_allocator)
				name_seen = true
			case "grants":
				set, is_set := field.value.derived.(^ast.Comp_Lit)
				if grants_seen || !is_set || set.type != nil {
					return nil, wrong_row
				}
				grants := make([dynamic]string, context.temp_allocator)
				for member in set.elems {
					selector, is_selector := member.derived.(^ast.Implicit_Selector_Expr)
					if !is_selector || selector.field == nil {
						return nil, wrong_row
					}
					append(&grants, strings.clone(selector.field.name, context.temp_allocator))
				}
				row.grants = grants[:]
				grants_seen = true
			case "terms":
				record, is_record := field.value.derived.(^ast.Comp_Lit)
				if terms_seen || !is_record || record.type != nil {
					return nil, wrong_row
				}
				text := content[record.pos.offset:record.end.offset]
				if strings.contains(text, "//") {
					return nil, fmt.tprintf("%s, line %d: the terms of a row of %s hold a comment: the comment goes above the row", file, record.pos.line, table)
				}
				text = strings.trim_suffix(strings.trim_prefix(strings.trim_space(text), "{"), "}")
				row.terms = strings.join(strings.fields(text, context.temp_allocator), " ", context.temp_allocator)
				terms_seen = true
			case:
				return nil, wrong_row
			}
		}
		if !name_seen {
			return nil, wrong_row
		}
		row.comment = row_comment(lines, previous_end + 1, element.end.line)
		previous_end = element.end.line
		append(&list, row)
	}
	if len(list) == 0 {
		return nil, fmt.tprintf("%s, line %d: %s has no row", file, literal.pos.line, table)
	}
	return list[:], ""
}

// string_list_read reads a list of texts, with the parser of Odin. The
// form: a declaration "<list> := <type> {"a", "b"}" at the top of the file,
// whose elements are string literals. A constant in the list, or another
// element, stops the command with the line: the tool reads the texts of the
// source, not the compiled list.
string_list_read :: proc(content, file, list_name: string) -> (texts: []string, problem: string) {
	list := make([dynamic]string, context.temp_allocator)
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return nil, fmt.tprintf("%s: no memory for the parser", file)
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	tree := ast.new_from_positions(ast.File, {}, {})
	tree.src = content
	tree.fullpath = file
	reader := parser.default_parser()
	reader.err = tokenizer_quiet_error
	reader.warn = tokenizer_quiet_error
	if !parser.parse_file(&reader, tree) || tree.syntax_error_count > 0 {
		return nil, fmt.tprintf("%s: the parser of Odin refuses the file", file)
	}
	literal: ^ast.Comp_Lit
	for statement in tree.decls {
		declaration, is_declaration := statement.derived.(^ast.Value_Decl)
		if !is_declaration || len(declaration.names) != 1 || len(declaration.values) != 1 {
			continue
		}
		identifier, has_name := declaration.names[0].derived.(^ast.Ident)
		if !has_name || identifier.name != list_name {
			continue
		}
		literal, _ = declaration.values[0].derived.(^ast.Comp_Lit)
		break
	}
	if literal == nil {
		return nil, fmt.tprintf("%s: no list \"%s := <type> {{...}}\"", file, list_name)
	}
	for element in literal.elems {
		text_literal, is_text := element.derived.(^ast.Basic_Lit)
		if !is_text || text_literal.tok.kind != .String {
			return nil, fmt.tprintf("%s, line %d: an element of %s is a string literal", file, element.pos.line, list_name)
		}
		text, _, found := odin_string_at(text_literal.tok.text, 0)
		if !found {
			return nil, fmt.tprintf("%s, line %d: an element of %s is a string literal", file, element.pos.line, list_name)
		}
		append(&list, strings.clone(text, context.temp_allocator))
	}
	return list[:], ""
}

// row_comment gives the comment of a row, as Markdown: the comment of
// each line from its first line to its last, numbered from 1. A comment
// after code is one line; a line that is only a comment keeps its
// indentation.
row_comment :: proc(lines: []string, first_line, last_line: int) -> string {
	comment := ""
	for number in first_line ..= last_line {
		if number < 1 || number > len(lines) {
			continue
		}
		code, text, is_comment := markdown_comment_line(lines[number - 1])
		if !is_comment {
			continue
		}
		if code != "" {
			text = strings.trim_space(text)
		}
		comment = markdown_comment_add(comment, text)
	}
	return markdown_comment_end(comment)
}

// odin_unquote gives the text of an Odin string with its escapes \" and \\.
odin_unquote :: proc(text: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for index := 0; index < len(text); index += 1 {
		if text[index] == '\\' && index + 1 < len(text) {
			index += 1
		}
		strings.write_byte(&builder, text[index])
	}
	return strings.to_string(builder)
}

// odin_string_at reads an Odin string that starts at a quote: its text,
// with its escapes, and the index after its closing quote.
odin_string_at :: proc(text: string, start: int) -> (value: string, end: int, found: bool) {
	if start >= len(text) || text[start] != '"' {
		return "", 0, false
	}
	for index := start + 1; index < len(text); index += 1 {
		switch text[index] {
		case '\\':
			index += 1
		case '"':
			return odin_unquote(text[start + 1:index]), index + 1, true
		}
	}
	return "", 0, false
}

// console_commands_read reads the built-in commands of the console.
// The form: each line whose code starts with "command(\"" is
// `command("<name>", {.<Kind>, ...}, .<Kind>, "<help>", <procedure>)`,
// with `forms = {...}` after it for a parameter that the parser reads as
// names. The kind None of a parameter is any value: the console prints
// "Value". The form Fact_Name prints "Fact_Type", the form Condition
// "Condition".
// The comment lines just above a command, up to a line that is not a
// comment, are its documentation.
console_commands_read :: proc(content, file: string) -> (commands: []Console_Command_Entry, problem: string) {
	list := make([dynamic]Console_Command_Entry, context.temp_allocator)
	lines := lines_of_text(content)
	for line, index in lines {
		code, _ := code_and_comment(line)
		if !strings.has_prefix(code, "command(\"") {
			continue
		}
		wrong := fmt.tprintf("%s, line %d: a command is `command(\"<name>\", {{.<Kind>, ...}}, .<Kind>, \"<help>\", <procedure>)`", file, index + 1)
		name, after_name, has_name := odin_string_at(code, len("command("))
		if !has_name || !strings.has_prefix(code[after_name:], ", {") {
			return nil, wrong
		}
		list_start := after_name + len(", {")
		list_end := strings.index_byte(code[list_start:], '}')
		if list_end < 0 {
			return nil, wrong
		}
		parameters := make([dynamic]string, context.temp_allocator)
		for part in strings.split(code[list_start:list_start + list_end], ",", context.temp_allocator) {
			kind := strings.trim_space(part)
			if kind == "" {
				continue
			}
			if !strings.has_prefix(kind, ".") || !is_odin_identifier(kind[1:]) {
				return nil, wrong
			}
			append(&parameters, kind[1:] == "None" ? "Value" : kind[1:])
		}
		rest := code[list_start + list_end + 1:]
		if !strings.has_prefix(rest, ", .") {
			return nil, wrong
		}
		rest = rest[len(", ."):]
		comma := strings.index(rest, ", ")
		if comma < 0 || !is_odin_identifier(rest[:comma]) {
			return nil, wrong
		}
		result := rest[:comma]
		about, after_about, has_about := odin_string_at(rest, comma + len(", "))
		if !has_about || !strings.has_prefix(rest[after_about:], ", ") || !strings.has_suffix(rest, ")") {
			return nil, wrong
		}
		// `forms = {...}`: a parameter that the parser reads as names has
		// the name of its form in the signature, as the console writes it.
		if forms_at := strings.index(rest[after_about:], "forms = {"); forms_at >= 0 {
			forms_text := rest[after_about + forms_at + len("forms = {"):]
			forms_end := strings.index_byte(forms_text, '}')
			if forms_end < 0 {
				return nil, wrong
			}
			for part, form_index in strings.split(forms_text[:forms_end], ",", context.temp_allocator) {
				if form_index >= len(parameters) {
					return nil, wrong
				}
				switch strings.trim_space(part) {
				case ".Expression":
				case ".Fact_Name":
					parameters[form_index] = "Fact_Type"
				case ".Condition":
					parameters[form_index] = "Condition"
				case:
					return nil, wrong
				}
			}
		}
		above := index
		for above > 0 && strings.has_prefix(strings.trim_space(lines[above - 1]), "//") {
			above -= 1
		}
		documentation := ""
		for comment_line in lines[above:index] {
			_, text, _ := markdown_comment_line(comment_line)
			documentation = markdown_comment_add(documentation, text)
		}
		append(&list, Console_Command_Entry{name = name, parameters = parameters[:], result = result, about = about, documentation = markdown_comment_end(documentation), file = file, line = index + 1})
	}
	if len(list) == 0 {
		return nil, fmt.tprintf("%s: no line `command(\"<name>\", ...)`", file)
	}
	return list[:], ""
}

// console_signature gives a command as `help()` of the console prints
// it: "repeat(Text, Integer) -> Text"; no arrow for the result None.
console_signature :: proc(command: Console_Command_Entry) -> string {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, command.name)
	strings.write_byte(&builder, '(')
	for parameter, index in command.parameters {
		if index > 0 {
			strings.write_string(&builder, ", ")
		}
		strings.write_string(&builder, parameter)
	}
	strings.write_byte(&builder, ')')
	if command.result != "None" {
		strings.write_string(&builder, " -> ")
		strings.write_string(&builder, command.result)
	}
	return strings.to_string(builder)
}

// The parts of the comment of a kernel operation. The contract writes each
// operation as "<Name> = <n>, // (<parameters>) -> <result>. <text>", and
// the lines after it continue the text.
Operation_Comment_Parts :: struct {
	member:     Enumeration_Member,
	parameters: string, // The text between the parentheses, as the comment writes it.
	result:     string, // The text after "->" up to the end of its sentence, or "".
	text:       string, // The rest of the comment.
}

// operation_comment_split splits the comment of an operation. A comment that
// does not start with "(" has no parameters: all of it is the text.
operation_comment_split :: proc(member: Enumeration_Member) -> Operation_Comment_Parts {
	operation := Operation_Comment_Parts{member = member, text = member.comment}
	comment := member.comment
	if !strings.has_prefix(comment, "(") {
		return operation
	}
	depth := 0
	closing := -1
	for index in 0 ..< len(comment) {
		if comment[index] == '(' {
			depth += 1
		} else if comment[index] == ')' {
			depth -= 1
			if depth == 0 {
				closing = index
				break
			}
		}
	}
	if closing < 0 {
		return operation
	}
	// The form can run over two lines of the comment: a line feed in it is
	// a space.
	one_line :: proc(text: string) -> string {
		joined, _ := strings.replace_all(text, "\n", " ", context.temp_allocator)
		return joined
	}
	operation.parameters = one_line(comment[1:closing])
	rest := comment[closing + 1:]
	if strings.has_prefix(rest, " -> ") {
		rest = rest[len(" -> "):]
		// The result ends at the end of its sentence: a period before a
		// space, a line feed or the end of the comment.
		end := -1
		for index in 0 ..< len(rest) {
			if rest[index] == '.' && (index + 1 == len(rest) || rest[index + 1] == ' ' || rest[index + 1] == '\n') {
				end = index
				break
			}
		}
		if end < 0 {
			operation.result = one_line(strings.trim_space(rest))
			rest = ""
		} else {
			operation.result = one_line(rest[:end])
			rest = rest[end + 1:]
		}
	}
	rest = strings.trim_prefix(rest, ":")
	rest = strings.trim_prefix(rest, ".")
	operation.text = strings.trim_space(rest)
	return operation
}
