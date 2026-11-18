// The declaration index: each declaration of the sources of the system,
// with its kind, its signature and its place. Each build writes the link
// pages of the manual from it, and the site shows it
// (docs/SITE.md, "The declarations of the sources").
package build

import "core:fmt"
import "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:strings"
import "modustool:foundation"

// comment_links gives each link "[label](target)" of the text of a
// comment, outside its code spans, with the byte where it starts.
comment_links :: proc(text: string) -> (targets: []string, starts: []int) {
	target_list := make([dynamic]string, context.temp_allocator)
	start_list := make([dynamic]int, context.temp_allocator)
	index := 0
	for index < len(text) {
		switch text[index] {
		case '`':
			end := strings.index_byte(text[index + 1:], '`')
			if end < 0 {
				index = len(text)
				continue
			}
			index += end + 2
			continue
		case '[':
			if _, target, end, found := markdown_link_at(text, index); found {
				append(&target_list, target)
				append(&start_list, index)
				index = end
				continue
			}
		}
		index += 1
	}
	return target_list[:], start_list[:]
}

// The folders whose declarations the index holds: the sources of the system.
// The tool is not read: its names are not names of the system.
DECLARATION_INDEX_FOLDERS :: [?]string{foundation.SOURCE_FOLDER_KERNEL, foundation.SOURCE_FOLDER_BOOT, foundation.SOURCE_FOLDER_CONTRACT, foundation.SOURCE_FOLDER_SUPPORT, foundation.SOURCE_FOLDER_PRIVATE, foundation.SOURCE_FOLDER_MODULES}

Declaration_Kind :: enum {
	Procedure,
	Type,
	Constant,
	Variable,
}

declaration_kind_names := [Declaration_Kind]string {
	.Procedure = "procedure",
	.Type      = "type",
	.Constant  = "constant",
	.Variable  = "global variable",
}

// One declaration at the top of a package of the sources.
Indexed_Declaration :: struct {
	name:           string,
	package_name:   string, // The name after "package" in its file.
	folder:         string, // The folder of its file: "src/library/support/graphics".
	file:           string,
	line:           int,
	kind:           Declaration_Kind,
	signature:      string, // One line of Odin, with no body and no comment.
	first_sentence: string, // Of the comment above it, or of its line; or "".
	comment:        string, // The Markdown of the comment above it, or of its line; or "". The manual shows it whole.
}

// The declaration index: each declaration, the declarations of each name,
// and the folders that hold one.
Declaration_Index :: struct {
	declarations:          [dynamic]Indexed_Declaration,
	by_name:               map[string][dynamic]int,
	folders:               map[string]bool,
	packages:              map[string]bool, // The name of each package, and the last part of each folder.
	files_not_parsed:      int,
	first_file_not_parsed: string,
}

// declaration_index_make gives an empty index.
declaration_index_make :: proc() -> Declaration_Index {
	return Declaration_Index {
		declarations = make([dynamic]Indexed_Declaration, context.temp_allocator),
		by_name = make(map[string][dynamic]int, context.temp_allocator),
		folders = make(map[string]bool, context.temp_allocator),
		packages = make(map[string]bool, context.temp_allocator),
	}
}

// declaration_index_add adds one declaration to an index.
declaration_index_add :: proc(index: ^Declaration_Index, declaration: Indexed_Declaration) {
	append(&index.declarations, declaration)
	place := len(index.declarations) - 1
	list, found := index.by_name[declaration.name]
	if !found {
		list = make([dynamic]int, context.temp_allocator)
	}
	append(&list, place)
	index.by_name[declaration.name] = list
	index.folders[declaration.folder] = true
	index.packages[declaration.package_name] = true
	index.packages[declaration.folder[strings.last_index_byte(declaration.folder, '/') + 1:]] = true
}

// declaration_one_line gives a text of Odin on one line: its tokens
// with no comment, one space where the text had spaces, no space inside
// the brackets and no comma before a closing bracket. A text that the
// tokenizer refuses has its spaces made single.
declaration_one_line :: proc(text: string) -> string {
	tokens, ok := odin_tokens(text)
	if !ok {
		words := strings.fields(text, context.temp_allocator)
		return strings.join(words, " ", context.temp_allocator)
	}
	b := strings.builder_make(context.temp_allocator)
	previous_end := -1
	previous_kind := tokenizer.Token_Kind.Invalid
	for token in tokens {
		if token.kind == .Comment {
			continue
		}
		closing := token.kind == .Close_Paren || token.kind == .Close_Bracket || token.kind == .Close_Brace
		if closing && strings.has_suffix(strings.to_string(b), ",") {
			strings.pop_byte(&b)
		}
		opened := previous_kind == .Open_Paren || previous_kind == .Open_Bracket || previous_kind == .Open_Brace
		if previous_end >= 0 && token.start > previous_end && !closing && !opened && token.kind != .Comma {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, text[token.start:token.end])
		previous_end = token.end
		previous_kind = token.kind
	}
	return strings.to_string(b)
}

// declaration_first_brace gives the offset in a text of its first
// "{", or -1.
declaration_first_brace :: proc(text: string) -> int {
	tokens, ok := odin_tokens(text)
	if !ok {
		return -1
	}
	for token in tokens {
		if token.kind == .Open_Brace {
			return token.start
		}
	}
	return -1
}

// declaration_kind_of gives the kind of a declaration from its value:
// a mutable one is a global variable; a procedure literal or a group of
// procedures is a procedure; a type expression is a type; a name with a
// capital and lowercase letters given another name is an alias of a type;
// any other value is a constant.
declaration_kind_of :: proc(name: string, is_mutable: bool, value: ^ast.Expr) -> Declaration_Kind {
	if is_mutable {
		return .Variable
	}
	if value == nil {
		return .Constant
	}
	#partial switch _ in value.derived {
	case ^ast.Proc_Lit, ^ast.Proc_Group:
		return .Procedure
	case ^ast.Struct_Type, ^ast.Enum_Type, ^ast.Union_Type, ^ast.Bit_Set_Type, ^ast.Bit_Field_Type, ^ast.Distinct_Type, ^ast.Array_Type, ^ast.Dynamic_Array_Type, ^ast.Fixed_Capacity_Dynamic_Array_Type, ^ast.Map_Type, ^ast.Pointer_Type, ^ast.Multi_Pointer_Type, ^ast.Proc_Type, ^ast.Matrix_Type, ^ast.Typeid_Type, ^ast.Helper_Type:
		return .Type
	case ^ast.Ident, ^ast.Selector_Expr:
		if name_is_capital(name) && !name_is_constant(name) {
			return .Type
		}
	}
	return .Constant
}

// declaration_signature gives the one line of a declaration: its text
// up to the body of a procedure, or up to the first "{" of another value
// (the fields of a struct, the members of an enum, the items of a table),
// which become "{...}". The line is whole: a card never cuts a text.
declaration_signature :: proc(source: string, declaration: ^ast.Value_Decl, value: ^ast.Expr) -> string {
	start := declaration.pos.offset
	end := declaration.end.offset
	if start < 0 || end > len(source) || end < start {
		return ""
	}
	text := source[start:end]
	if value != nil {
		if procedure, is_procedure := value.derived.(^ast.Proc_Lit); is_procedure {
			if procedure.body != nil && procedure.body.pos.offset > start && procedure.body.pos.offset <= end {
				text = source[start:procedure.body.pos.offset]
			}
		} else if value.pos.offset >= start && value.end.offset <= end {
			if brace := declaration_first_brace(source[value.pos.offset:value.end.offset]); brace >= 0 {
				text = strings.concatenate({source[start:value.pos.offset + brace], "{...}"}, context.temp_allocator)
			}
		}
	}
	return declaration_one_line(text)
}

// declarations_of_statements adds the declarations of a list of
// statements of the top of a file, and of the blocks of a "when" there.
declarations_of_statements :: proc(list: ^[dynamic]Indexed_Declaration, statements: []^ast.Stmt, path, folder, package_name, source: string) {
	for statement in statements {
		if statement == nil {
			continue
		}
		#partial switch item in statement.derived {
		case ^ast.When_Stmt:
			declarations_of_when(list, item, path, folder, package_name, source)
		case ^ast.Value_Decl:
			description := text_of(item.docs)
			if description == "" {
				description = text_of(item.comment)
			}
			first := about_of(description, "")
			for name_expression, name_index in item.names {
				identifier, has_name := name_expression.derived.(^ast.Ident)
				if !has_name || identifier.name == "_" {
					continue
				}
				value: ^ast.Expr
				if len(item.values) == len(item.names) {
					value = item.values[name_index]
				} else if len(item.values) == 1 {
					value = item.values[0]
				}
				append(list, Indexed_Declaration {
					name = identifier.name,
					package_name = package_name,
					folder = folder,
					file = path,
					line = item.pos.line,
					kind = declaration_kind_of(identifier.name, item.is_mutable, value),
					signature = declaration_signature(source, item, value),
					first_sentence = first,
					comment = description,
				})
			}
		}
	}
}

// declarations_of_when adds the declarations of the blocks of a
// "when" at the top of a file: a declaration for one machine is still a
// declaration of the package.
declarations_of_when :: proc(list: ^[dynamic]Indexed_Declaration, statement: ^ast.When_Stmt, path, folder, package_name, source: string) {
	for part in ([]^ast.Stmt{statement.body, statement.else_stmt}) {
		if part == nil {
			continue
		}
		#partial switch block in part.derived {
		case ^ast.Block_Stmt:
			declarations_of_statements(list, block.stmts, path, folder, package_name, source)
		case ^ast.When_Stmt:
			declarations_of_when(list, block, path, folder, package_name, source)
		}
	}
}

// declarations_of_file gives the declarations of one source file. The
// tree of the parser lives in an arena of its own, freed before the next
// file: the index keeps only its texts, which are parts of the source or
// strings of the temporary allocator.
declarations_of_file :: proc(path, source: string) -> (found: []Indexed_Declaration, parsed: bool) {
	list := make([dynamic]Indexed_Declaration, context.temp_allocator)
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return nil, false
	}
	defer virtual.arena_destroy(&arena)
	folder := path[:max(strings.last_index_byte(path, '/'), 0)]
	{
		context.allocator = virtual.arena_allocator(&arena)
		file := ast.new_from_positions(ast.File, {}, {})
		file.src = source
		file.fullpath = path
		reader := parser.default_parser()
		// The command reports a file that the parser refuses by its count.
		reader.err = foundation.tokenizer_quiet_error
		reader.warn = foundation.tokenizer_quiet_error
		if !parser.parse_file(&reader, file) || file.syntax_error_count > 0 {
			return nil, false
		}
		// The texts are cloned out of the arena: the name of the package is
		// a part of the source, but a copy costs nothing here.
		package_name := strings.clone(file.pkg_name, context.temp_allocator)
		declarations_of_statements(&list, file.decls[:], path, folder, package_name, source)
	}
	return list[:], true
}

// declaration_index_fill adds the declarations of the sources of the
// system to an index. With names, it parses only the files whose text holds
// one of them: a file that does not hold a name cannot declare it, so the
// index holds each declaration of these names, and a name resolves as it
// does in the whole index (src/md/features/manual_links.md, "The chosen
// form").
declaration_index_fill :: proc(index: ^Declaration_Index, names: []string) -> bool {
	paths := make([dynamic]string, context.temp_allocator)
	folders := DECLARATION_INDEX_FOLDERS
	for folder in folders {
		odin_files_under(folder, &paths)
	}
	for path in paths {
		source, read_ok := foundation.read_text_file_quiet(path)
		if !read_ok {
			fmt.eprintfln("modustool: cannot read %s", path)
			return false
		}
		if names != nil && !text_holds_one_of(source, names) {
			continue
		}
		found, parsed := declarations_of_file(path, source)
		if !parsed {
			index.files_not_parsed += 1
			if index.first_file_not_parsed == "" {
				index.first_file_not_parsed = path
			}
			continue
		}
		for declaration in found {
			declaration_index_add(index, declaration)
		}
	}
	return true
}

// text_holds_one_of tells whether a text holds one of these names.
text_holds_one_of :: proc(text: string, names: []string) -> bool {
	for name in names {
		if strings.contains(text, name) {
			return true
		}
	}
	return false
}

// The forms of a code span that can name a declaration: a name, a name
// with empty parentheses, and either one after the name of its package.
Declaration_Span :: struct {
	qualifier: string, // The package that the span names, or "".
	name:      string,
	called:    bool, // "name()": a procedure.
}

// The extensions of the files that a span names: "boot.image" and
// "flake.nix" are files, not a name after its package.
SPAN_FILE_EXTENSIONS :: [?]string{"odin", "md", "nix", "lock", "json", "js", "css", "html", "txt", "png", "svg", "ico", "xml", "toml", "yaml", "yml", "sh", "image", "img", "efi", "bin", "manifest", "license", "webmanifest", "c", "h", "rs", "py", "asm", "ld", "log", "pem", "der", "wgsl"}

// declaration_span_read reads the form of a code span: a name,
// "name()", "package.name" or "package.name()". A file name with a known
// extension, a keyword or a built-in type is not a name of a declaration.
declaration_span_read :: proc(code: string) -> (span: Declaration_Span, is_name: bool) {
	text := code
	if strings.has_suffix(text, "()") {
		text = text[:len(text) - 2]
		span.called = true
	}
	if period := strings.index_byte(text, '.'); period >= 0 {
		span.qualifier = text[:period]
		text = text[period + 1:]
		extensions := SPAN_FILE_EXTENSIONS
		for extension in extensions {
			if text == extension {
				return {}, false
			}
		}
		if !foundation.is_odin_identifier(span.qualifier) {
			return {}, false
		}
	}
	if !foundation.is_odin_identifier(text) || is_odin_word(text) {
		return {}, false
	}
	span.name = text
	return span, true
}

// is_odin_word tells whether a name is a keyword of the tokenizer or a
// built-in type of Odin: no declaration of the sources has it.
is_odin_word :: proc(name: string) -> bool {
	built_in := ODIN_BUILT_IN_TYPES
	for type_name in built_in {
		if name == type_name {
			return true
		}
	}
	tokens, ok := odin_tokens(name)
	return ok && len(tokens) == 1 && tokenizer.is_keyword(tokens[0].kind)
}

// is_plain_word tells whether a name is a common word: lowercase
// letters only, as "count" or "build". Such a name is linked only when the
// text around it names the package of the declaration, or when the span
// calls it.
is_plain_word :: proc(name: string) -> bool {
	for character in transmute([]u8)name {
		if character < 'a' || character > 'z' {
			return false
		}
	}
	return true
}

// What the resolution of a name gives.
Declaration_Resolution :: enum {
	Linked,
	Ambiguous, // Several declarations, or a common word that nothing places.
	Not_Found,
}

// declaration_in_context tells whether a declaration is in one of the
// folders that the text around a span names, or under one of them.
declaration_in_context :: proc(declaration: Indexed_Declaration, context_folders: []string) -> bool {
	for folder in context_folders {
		if declaration.folder == folder || strings.has_prefix(declaration.folder, strings.concatenate({folder, "/"}, context.temp_allocator)) {
			return true
		}
	}
	return false
}

// declaration_resolve finds the declaration that a span names. A name
// that several packages declare is resolved by the package that the span
// names, else by the folders that the text around it names (the heading
// and the paragraph); else it stays plain. A common word is linked only
// when that text places it, or when the span calls it.
declaration_resolve :: proc(index: ^Declaration_Index, span: Declaration_Span, context_folders: []string) -> (place: int, resolution: Declaration_Resolution) {
	list, found := index.by_name[span.name]
	if !found || len(list) == 0 {
		return -1, .Not_Found
	}
	candidates := make([dynamic]int, context.temp_allocator)
	for candidate in list {
		declaration := index.declarations[candidate]
		if span.qualifier != "" && declaration.package_name != span.qualifier && declaration.folder[strings.last_index_byte(declaration.folder, '/') + 1:] != span.qualifier {
			continue
		}
		if span.called && declaration.kind != .Procedure {
			continue
		}
		append(&candidates, candidate)
	}
	if len(candidates) == 0 {
		return -1, .Not_Found
	}
	placed := make([dynamic]int, context.temp_allocator)
	for candidate in candidates {
		if declaration_in_context(index.declarations[candidate], context_folders) {
			append(&placed, candidate)
		}
	}
	if len(placed) == 1 {
		return placed[0], .Linked
	}
	if len(candidates) == 1 && (span.qualifier != "" || span.called || !is_plain_word(span.name)) {
		return candidates[0], .Linked
	}
	return -1, .Ambiguous
}

// odin_files_under adds the path of each source file of a folder and
// of its folders, but the tests, to paths.
odin_files_under :: proc(folder: string, paths: ^[dynamic]string) {
	entries, list_error := os.read_all_directory_by_path(folder, context.temp_allocator)
	if list_error != nil {
		return
	}
	for entry in entries {
		path := strings.concatenate({folder, "/", entry.name}, context.temp_allocator)
		if entry.type == .Directory {
			odin_files_under(path, paths)
		} else if strings.has_suffix(entry.name, ".odin") && !strings.has_suffix(entry.name, "_test.odin") {
			append(paths, path)
		}
	}
}
