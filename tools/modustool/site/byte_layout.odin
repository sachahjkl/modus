// The byte layouts (docs/SITE.md, "The byte layouts"): the diagram of the
// bytes of one record of a format, in the manner of the header diagrams of
// the RFCs, which the site writes in the place of a fence `byte-layout` of a
// guide. The offsets and the sizes come from the compiler (type_info_of),
// which lays out the struct that the system uses; the type of each field as
// the source writes it, and its comment, come from the parser of Odin. The
// body of the fence is the text form of the layouts: the site and
// `modustool check` refuse another body, and `modustool byte-layouts write`
// writes it again, so neither the diagram nor the raw Markdown can differ
// from the code. The design: src/md/features/byte_layout.md.
package site

import "base:runtime"
import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:strings"
import "modus:contract/draw_record"
import module "modus:contract/module"
import "modus:contract/output"
import "modustool:foundation"
import "modustool:build"
import "modustool:checks"

// A row of a diagram: 8 bytes, so that a 64-bit field of the format is one
// rectangle and never crosses two rows.
BYTE_LAYOUT_ROW_BYTES :: 8
// The language of a fenced block of a guide that marks the place of
// layouts; the names of the layouts follow it on the same line.
BYTE_LAYOUT_FENCE_LANGUAGE :: "byte-layout"
BYTE_LAYOUT_FORMAT_FILE :: foundation.SOURCE_FOLDER_CONTRACT + "/module/format.odin"
BYTE_LAYOUT_FACTS_FILE :: foundation.SOURCE_FOLDER_CONTRACT + "/module/facts.odin"
BYTE_LAYOUT_RECORD_STREAMS_FILE :: foundation.SOURCE_FOLDER_CONTRACT + "/module/record_streams.odin"
BYTE_LAYOUT_OUTPUT_FILE :: foundation.SOURCE_FOLDER_CONTRACT + "/output/output.odin"
BYTE_LAYOUT_WIRING_LIST_FILE :: foundation.SOURCE_FOLDER_CONTRACT + "/output/wiring_list.odin"
BYTE_LAYOUT_DRAW_RECORD_FILE :: foundation.SOURCE_FOLDER_CONTRACT + "/draw_record/draw_record.odin"
// The folder whose Markdown files the check and the command read: the
// guides that the site shows.
BYTE_LAYOUT_DOCUMENT_FOLDER :: "docs"

// One layout that a fence can name: a struct of a contract, or one word.
Byte_Layout_Source :: struct {
	key:         string, // The name that a fence gives: "module.Header".
	file:        string, // The source file that the parser reads.
	declaration: string, // The struct in that file, or the constant whose comment a word takes.
	info:        ^runtime.Type_Info, // The type of the record, or of the word; nil for a table with no record of a fixed size.
	word_size:   int, // A word: its size as the contract states it; 0 for a struct.
	what:        string, // One line: what one record of this layout is; for a table with no record, why.
}

// One field of a layout, or one run of bytes that no field uses.
Byte_Layout_Field :: struct {
	name:       string,
	type_text:  string, // As the source writes it: "[PARAMETER_CAPACITY]u32".
	offset:     int,
	size:       int,
	is_padding: bool,
	comment:    string, // The Markdown of the comment of the field in the source, or "".
}

Byte_Layout :: struct {
	key:    string,
	what:   string,
	size:   int,
	fields: []Byte_Layout_Field, // In the order of their offsets, with a row for each run of padding.
}

// One rectangle of a diagram: a field, or the part of a field in one row,
// or a field over whole rows.
Byte_Layout_Piece :: struct {
	field:  int, // The index of the field in the layout.
	row:    int, // From 0.
	column: int, // The byte of the row where it starts, from 0.
	span:   int, // Its bytes in the row.
	rows:   int, // The rows that it covers: more than 1 only for a field over whole rows.
	first:  bool, // The first piece of its field: it holds the size, the others say "continued".
}

// A field of a struct as the parser reads it.
Byte_Layout_Source_Field :: struct {
	name:      string,
	type_text: string,
	comment:   string,
}

// A declaration of a source file as the parser reads it: the fields of a
// struct, or the comment of a constant.
Byte_Layout_Declaration :: struct {
	fields:  []Byte_Layout_Source_Field,
	comment: string,
}

// byte_layout_table_sources gives the layout of one record of each table
// kind of the module format. A table with no record of a fixed size has no
// type information and states why. A host test fails on a table kind that
// has neither, so a new table of the format reaches the guide.
byte_layout_table_sources :: proc() -> [module.Table_Kind]Byte_Layout_Source {
	file :: BYTE_LAYOUT_FORMAT_FILE
	return [module.Table_Kind]Byte_Layout_Source {
		.None          = {what = "the entry 0 of the table directory names no table"},
		.Segments      = {key = "module.Segment", file = file, declaration = "Segment", info = type_info_of(module.Segment), what = "one record of the table Segments"},
		.Imports       = {key = "module.Import", file = file, declaration = "Import", info = type_info_of(module.Import), what = "one record of the table Imports"},
		.Slots         = {key = "module.Slot", file = file, declaration = "Slot", info = type_info_of(module.Slot), what = "one record of the table Slots"},
		.Exports       = {key = "module.Export", file = file, declaration = "Export", info = type_info_of(module.Export), what = "one record of the table Exports"},
		.Rebases       = {key = "module.Rebases", file = file, declaration = "REBASE_WORD_SIZE", info = type_info_of(u64), word_size = module.REBASE_WORD_SIZE, what = "one word of the table Rebases"},
		.Functions     = {key = "module.Function", file = file, declaration = "Function", info = type_info_of(module.Function), what = "one record of the table Functions"},
		.Strings       = {what = "the table Strings is bytes, with no record"},
		.Documentation = {key = "module.Documentation", file = file, declaration = "Documentation", info = type_info_of(module.Documentation), what = "one record of the table Documentation"},
		.Records       = {key = "module.Record", file = file, declaration = "Record", info = type_info_of(module.Record), what = "one record of the table Records"},
		.Fields        = {key = "module.Field", file = file, declaration = "Field", info = type_info_of(module.Field), what = "one record of the table Fields"},
		.Budget        = {key = "module.Budget_Request", file = file, declaration = "Budget_Request", info = type_info_of(module.Budget_Request), what = "the record 1 of the table Budget"},
		.Facts         = {key = "module.Fact", file = BYTE_LAYOUT_FACTS_FILE, declaration = "Fact", info = type_info_of(module.Fact), what = "one record of the table Facts"},
		.Own_Hash      = {key = "module.Own_Hash_Place", file = BYTE_LAYOUT_FACTS_FILE, declaration = "Own_Hash_Place", info = type_info_of(module.Own_Hash_Place), what = "the record 1 of the table Own_Hash"},
		.Record_Outputs = {key = "module.Record_Output", file = BYTE_LAYOUT_RECORD_STREAMS_FILE, declaration = "Record_Output", info = type_info_of(module.Record_Output), what = "one record of the table Record_Outputs"},
		.Record_Inputs  = {key = "module.Record_Input", file = BYTE_LAYOUT_RECORD_STREAMS_FILE, declaration = "Record_Input", info = type_info_of(module.Record_Input), what = "one record of the table Record_Inputs"},
	}
}

// byte_layout_draw_record_sources gives the layout of a draw record and of
// the fields of each of its kinds (docs/INTERFACE.md, "2.1 Draw record").
byte_layout_draw_record_sources :: proc() -> []Byte_Layout_Source {
	file :: BYTE_LAYOUT_DRAW_RECORD_FILE
	sources := [?]Byte_Layout_Source {
		{key = "draw_record.Draw_Record", file = file, declaration = "Draw_Record", info = type_info_of(draw_record.Draw_Record), what = "one record of a draw table"},
		{key = "draw_record.Rectangle_Fields", file = file, declaration = "Rectangle_Fields", info = type_info_of(draw_record.Rectangle_Fields), what = "the fields of a Rectangle"},
		{key = "draw_record.Gradient_Fields", file = file, declaration = "Gradient_Fields", info = type_info_of(draw_record.Gradient_Fields), what = "the fields of a Gradient"},
		{key = "draw_record.Text_Fields", file = file, declaration = "Text_Fields", info = type_info_of(draw_record.Text_Fields), what = "the fields of a Text"},
		{key = "draw_record.Picture_Fields", file = file, declaration = "Picture_Fields", info = type_info_of(draw_record.Picture_Fields), what = "the fields of a Picture"},
		{key = "draw_record.Text_Grid_Fields", file = file, declaration = "Text_Grid_Fields", info = type_info_of(draw_record.Text_Grid_Fields), what = "the fields of a Text_Grid"},
		{key = "draw_record.Path_Fields", file = file, declaration = "Path_Fields", info = type_info_of(draw_record.Path_Fields), what = "the fields of a Path"},
		{key = "draw_record.Path_Point_Record", file = file, declaration = "Path_Point_Record", info = type_info_of(draw_record.Path_Point_Record), what = "one point of a path in the text table"},
	}
	list := make([]Byte_Layout_Source, len(sources), context.temp_allocator)
	copy(list, sources[:])
	return list
}

// byte_layout_sources gives every layout that a fence can name: the header
// of a module file, the entry of its table directory, the record of each
// table kind, in the order of the file, then the draw record.
byte_layout_sources :: proc() -> []Byte_Layout_Source {
	file :: BYTE_LAYOUT_FORMAT_FILE
	list := make([dynamic]Byte_Layout_Source, context.temp_allocator)
	append(&list, Byte_Layout_Source{key = "module.Header", file = file, declaration = "Header", info = type_info_of(module.Header), what = "the start of the file"})
	append(&list, Byte_Layout_Source{key = "module.Table_Entry", file = file, declaration = "Table_Entry", info = type_info_of(module.Table_Entry), what = "one entry of the table directory"})
	tables := byte_layout_table_sources()
	for source in tables {
		if source.info != nil {
			append(&list, source)
		}
	}
	for source in byte_layout_draw_record_sources() {
		append(&list, source)
	}
	for source in byte_layout_output_ring_sources() {
		append(&list, source)
	}
	return list[:]
}

// byte_layout_output_ring_sources gives the layouts of the shared memory of
// an output ring (src/md/features/module_outputs.md, "The ring and its
// records"): the word at the start of each compartment, and the end words
// of the head page.
byte_layout_output_ring_sources :: proc() -> []Byte_Layout_Source {
	file :: BYTE_LAYOUT_OUTPUT_FILE
	sources := [?]Byte_Layout_Source {
		{key = "output.Compartment_Word", file = file, declaration = "Compartment_Word", info = type_info_of(output.Compartment_Word), what = "the start of each compartment of an output ring"},
		{key = "output.End_Words", file = file, declaration = "End_Words", info = type_info_of(output.End_Words), what = "the end words in the head page of an output ring"},
		{key = "output.Wiring_List_Head", file = BYTE_LAYOUT_WIRING_LIST_FILE, declaration = "Wiring_List_Head", info = type_info_of(output.Wiring_List_Head), what = "the head of a wiring list"},
		{key = "output.Wiring", file = BYTE_LAYOUT_WIRING_LIST_FILE, declaration = "Wiring", info = type_info_of(output.Wiring), what = "one row of a wiring list"},
	}
	list := make([]Byte_Layout_Source, len(sources), context.temp_allocator)
	copy(list, sources[:])
	return list
}

// byte_layout_source_size gives the bytes of one record or word of a source.
byte_layout_source_size :: proc(source: Byte_Layout_Source) -> int {
	if source.word_size > 0 {
		return source.word_size
	}
	if source.info == nil {
		return 0
	}
	return source.info.size
}

// byte_layout_comment gives the Markdown of the comment of a field: the
// lines before it, then the comment at the end of its line.
byte_layout_comment :: proc(before, line: ^ast.Comment_Group) -> string {
	above, after := build.markdown_of(before), build.markdown_of(line)
	if above == "" {
		return after
	}
	if after == "" {
		return above
	}
	return strings.concatenate({above, "\n", after}, context.temp_allocator)
}

// byte_layout_declarations_read reads the top-level constant declarations
// of a source file with the parser of Odin: the fields of each struct, with
// their type as the source writes it and their comment, and the comment of
// each other constant.
byte_layout_declarations_read :: proc(path: string) -> (declarations: map[string]Byte_Layout_Declaration, problem: string) {
	source, read_ok := foundation.read_text_file(path)
	if !read_ok {
		return nil, fmt.tprintf("cannot read %s", path)
	}
	file := ast.new_from_positions(ast.File, {}, {})
	file.src = source
	file.fullpath = path
	reader := parser.default_parser()
	if !parser.parse_file(&reader, file) {
		return nil, fmt.tprintf("%s: the parser found errors", path)
	}
	declarations = make(map[string]Byte_Layout_Declaration, context.temp_allocator)
	for statement in file.decls {
		declaration, is_value := statement.derived.(^ast.Value_Decl)
		if !is_value || declaration.is_mutable || len(declaration.names) != 1 || len(declaration.values) != 1 {
			continue
		}
		identifier, has_name := declaration.names[0].derived.(^ast.Ident)
		if !has_name {
			continue
		}
		found := Byte_Layout_Declaration{comment = byte_layout_comment(declaration.docs, declaration.comment)}
		if structure, is_struct := declaration.values[0].derived.(^ast.Struct_Type); is_struct && structure.fields != nil {
			fields := make([dynamic]Byte_Layout_Source_Field, context.temp_allocator)
			for field in structure.fields.list {
				type_text := ""
				if field.type != nil {
					type_text = source[field.type.pos.offset:field.type.end.offset]
				}
				comment := byte_layout_comment(field.docs, field.comment)
				for name in field.names {
					if name_identifier, is_identifier := name.derived.(^ast.Ident); is_identifier {
						append(&fields, Byte_Layout_Source_Field{name = name_identifier.name, type_text = type_text, comment = comment})
					}
				}
			}
			found.fields = fields[:]
		}
		declarations[identifier.name] = found
	}
	return declarations, ""
}

// byte_layout_make gives the layout of one source: the offset and the size
// of each field from the type information, its type and its comment from
// the declaration of the source, and a row of padding for each run of bytes
// that no field uses. The type information and the declaration must name
// the same fields in the same order.
byte_layout_make :: proc(source: Byte_Layout_Source, declarations: map[string]Byte_Layout_Declaration) -> (layout: Byte_Layout, problem: string) {
	if source.info == nil {
		return {}, fmt.tprintf("the byte layout %s has no type information", source.key)
	}
	declaration, found := declarations[source.declaration]
	if !found {
		return {}, fmt.tprintf("%s: no declaration %s for the byte layout %s", source.file, source.declaration, source.key)
	}
	layout = Byte_Layout{key = source.key, what = source.what, size = byte_layout_source_size(source)}
	fields := make([dynamic]Site_Type_Field, context.temp_allocator)
	comments := make(map[string]string, context.temp_allocator)
	if source.word_size > 0 {
		if source.info.size != source.word_size {
			return {}, fmt.tprintf("the byte layout %s is a word of %d bytes, and its type %s has %d bytes", source.key, source.word_size, site_type_info_text(source.info), source.info.size)
		}
		append(&fields, Site_Type_Field{name = "word", type_text = site_type_info_text(source.info), offset = 0, size = source.word_size})
		comments["word"] = declaration.comment
	} else {
		structure, is_struct := runtime.type_info_base(source.info).variant.(runtime.Type_Info_Struct)
		if !is_struct {
			return {}, fmt.tprintf("the byte layout %s names %s, which is not a struct", source.key, site_type_info_text(source.info))
		}
		if int(structure.field_count) != len(declaration.fields) {
			return {}, fmt.tprintf("%s: the struct %s has %d fields in the source and %d in the type information of the tool", source.file, source.declaration, len(declaration.fields), structure.field_count)
		}
		for index in 0 ..< int(structure.field_count) {
			source_field := declaration.fields[index]
			if structure.names[index] != source_field.name {
				return {}, fmt.tprintf("%s: the field %d of the struct %s is %s in the source and %s in the type information of the tool", source.file, index, source.declaration, source_field.name, structure.names[index])
			}
			append(&fields, Site_Type_Field{name = source_field.name, type_text = source_field.type_text, offset = int(structure.offsets[index]), size = structure.types[index].size})
			comments[source_field.name] = source_field.comment
		}
	}
	rows, _ := site_type_layout(fields[:], layout.size)
	list := make([dynamic]Byte_Layout_Field, context.temp_allocator)
	for row in rows {
		field := Byte_Layout_Field{name = row.name, type_text = row.type_text, offset = row.offset, size = row.size, is_padding = row.is_padding}
		if !row.is_padding {
			field.comment = comments[row.name]
		}
		append(&list, field)
	}
	layout.fields = list[:]
	return layout, ""
}

// byte_layouts_read gives every layout of byte_layout_sources by its key,
// or prints each fault and gives false.
byte_layouts_read :: proc() -> (layouts: map[string]Byte_Layout, ok: bool) {
	layouts = make(map[string]Byte_Layout, context.temp_allocator)
	files := make(map[string]map[string]Byte_Layout_Declaration, context.temp_allocator)
	ok = true
	for source in byte_layout_sources() {
		declarations, read := files[source.file]
		if !read {
			problem: string
			declarations, problem = byte_layout_declarations_read(source.file)
			if problem != "" {
				fmt.eprintfln("modustool: byte layouts: %s", problem)
				return nil, false
			}
			files[source.file] = declarations
		}
		layout, problem := byte_layout_make(source, declarations)
		if problem != "" {
			fmt.eprintfln("modustool: byte layouts: %s", problem)
			ok = false
			continue
		}
		layouts[source.key] = layout
	}
	return layouts, ok
}

// byte_layout_row_count gives the rows of 8 bytes of a record of a size.
byte_layout_row_count :: proc(size: int) -> int {
	return (size + BYTE_LAYOUT_ROW_BYTES - 1) / BYTE_LAYOUT_ROW_BYTES
}

// byte_layout_pieces gives the rectangles of a layout. A field that starts
// at a row and covers two rows or more is one rectangle of whole rows; any
// other field has one rectangle for each row that it crosses.
byte_layout_pieces :: proc(layout: Byte_Layout) -> []Byte_Layout_Piece {
	pieces := make([dynamic]Byte_Layout_Piece, context.temp_allocator)
	for field, index in layout.fields {
		start := field.offset
		end := field.offset + field.size
		first := true
		for start < end {
			piece := Byte_Layout_Piece{field = index, row = start / BYTE_LAYOUT_ROW_BYTES, column = start % BYTE_LAYOUT_ROW_BYTES, rows = 1, first = first}
			if piece.column == 0 && end - start >= 2 * BYTE_LAYOUT_ROW_BYTES {
				piece.span = BYTE_LAYOUT_ROW_BYTES
				piece.rows = (end - start) / BYTE_LAYOUT_ROW_BYTES
			} else {
				piece.span = min(BYTE_LAYOUT_ROW_BYTES - piece.column, end - start)
			}
			append(&pieces, piece)
			start += piece.span * piece.rows
			first = false
		}
	}
	return pieces[:]
}

// byte_layout_pad_left gives a text with spaces before it, to a width.
byte_layout_pad_left :: proc(text: string, width: int) -> string {
	if len(text) >= width {
		return text
	}
	spaces := strings.repeat(" ", width - len(text), context.temp_allocator)
	return strings.concatenate({spaces, text}, context.temp_allocator)
}

// byte_layout_pad_right gives a text with spaces after it, to a width.
byte_layout_pad_right :: proc(text: string, width: int) -> string {
	if len(text) >= width {
		return text
	}
	spaces := strings.repeat(" ", width - len(text), context.temp_allocator)
	return strings.concatenate({text, spaces}, context.temp_allocator)
}

// byte_layout_text_line writes one line of the text form: the offset and
// the size at the right of their columns, the name at the left of its
// column, then the type, and no space at the end.
byte_layout_text_line :: proc(b: ^strings.Builder, offset, size, name, type_text: string, name_width: int) {
	text := strings.concatenate({byte_layout_pad_left(offset, 6), "  ", byte_layout_pad_left(size, 4), "  ", byte_layout_pad_right(name, name_width), "  ", type_text}, context.temp_allocator)
	strings.write_string(b, strings.trim_right(text, " "))
	strings.write_byte(b, '\n')
}

// byte_layout_text gives the text form of a layout, for a reader of the
// raw Markdown: a line that names it, then one line for each field with
// its offset, its size, its name and its type. A list, not a grid of
// characters: a field of one byte would have a column too narrow for its
// name. Each line ends with a line feed; no line ends with a space.
byte_layout_text :: proc(layout: Byte_Layout) -> string {
	name_width := len("field")
	for field in layout.fields {
		name_width = max(name_width, len(field.name))
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s, %s: %s\n", layout.key, site_type_size_text(layout.size), layout.what)
	byte_layout_text_line(&b, "offset", "size", "field", "type", name_width)
	for field in layout.fields {
		byte_layout_text_line(&b, fmt.tprintf("%d", field.offset), fmt.tprintf("%d", field.size), field.name, field.type_text, name_width)
	}
	return strings.to_string(b)
}

// byte_layouts_text gives the body of a fence: the text form of each
// layout, an empty line between two.
byte_layouts_text :: proc(layouts: []Byte_Layout) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for layout in layouts {
		append(&parts, byte_layout_text(layout))
	}
	return strings.join(parts[:], "\n", context.temp_allocator)
}

// byte_layout_fence_keys gives the names of the layouts of an opening line
// of a fence, or false when the fence is not a fence of layouts.
byte_layout_fence_keys :: proc(language: string) -> (keys: []string, is_layout: bool) {
	words := strings.fields(language, context.temp_allocator)
	if len(words) == 0 || words[0] != BYTE_LAYOUT_FENCE_LANGUAGE {
		return nil, false
	}
	return words[1:], true
}

// byte_layouts_of_keys gives the layouts that a fence names, and a fault
// for a fence that names none or a name that is not a layout.
byte_layouts_of_keys :: proc(keys: []string, layouts: map[string]Byte_Layout) -> (found: []Byte_Layout, problem: string) {
	if len(keys) == 0 {
		return nil, fmt.tprintf("a fence %s names no layout; the layouts are %s", BYTE_LAYOUT_FENCE_LANGUAGE, byte_layout_key_list())
	}
	list := make([dynamic]Byte_Layout, context.temp_allocator)
	for key in keys {
		layout, is_layout := layouts[key]
		if !is_layout {
			return nil, fmt.tprintf("a fence %s names %s, which is not a layout; the layouts are %s", BYTE_LAYOUT_FENCE_LANGUAGE, key, byte_layout_key_list())
		}
		append(&list, layout)
	}
	return list[:], ""
}

// byte_layout_key_list gives the names of the layouts, in their order.
byte_layout_key_list :: proc() -> string {
	keys := make([dynamic]string, context.temp_allocator)
	for source in byte_layout_sources() {
		append(&keys, source.key)
	}
	return strings.join(keys[:], ", ", context.temp_allocator)
}

// byte_layout_document_rewrite gives a Markdown text with the body of each
// fence of layouts made again from the code, and the faults of its fences.
// A fence of layouts starts at the start of its line, so that its body is
// the text with no indentation.
byte_layout_document_rewrite :: proc(content, path: string, layouts: map[string]Byte_Layout) -> (rewritten: string, fences: int, problems: []string) {
	lines := foundation.lines_of_text(content)
	list := make([dynamic]string, context.temp_allocator)
	found_problems := make([dynamic]string, context.temp_allocator)
	index := 0
	for index < len(lines) {
		line := lines[index]
		trimmed := strings.trim_left(line, " ")
		keys, is_layout := byte_layout_fence_keys(strings.has_prefix(trimmed, "```") ? trimmed[3:] : "")
		if !is_layout {
			append(&list, line)
			index += 1
			continue
		}
		if trimmed != line {
			append(&found_problems, fmt.tprintf("%s, line %d: a fence %s starts at the start of its line", path, index + 1, BYTE_LAYOUT_FENCE_LANGUAGE))
		}
		end := index + 1
		for end < len(lines) && strings.trim_space(lines[end]) != "```" {
			end += 1
		}
		if end >= len(lines) {
			append(&found_problems, fmt.tprintf("%s, line %d: a fence %s has no end", path, index + 1, BYTE_LAYOUT_FENCE_LANGUAGE))
			append(&list, ..lines[index:])
			break
		}
		fences += 1
		found, problem := byte_layouts_of_keys(keys, layouts)
		if problem != "" {
			append(&found_problems, fmt.tprintf("%s, line %d: %s", path, index + 1, problem))
			append(&list, ..lines[index:end + 1])
		} else {
			append(&list, line)
			body := strings.trim_suffix(byte_layouts_text(found), "\n")
			body_lines := strings.split(body, "\n", context.temp_allocator)
			append(&list, ..body_lines)
			append(&list, lines[end])
		}
		index = end + 1
	}
	joined := strings.join(list[:], "\n", context.temp_allocator)
	return joined, fences, found_problems[:]
}

// byte_layout_documents_rewrite rewrites the fences of each Markdown file
// of the guides. With write, it writes each file whose text changes; else
// each such file is a fault.
byte_layout_documents_rewrite :: proc(write: bool) -> bool {
	layouts, layouts_ok := byte_layouts_read()
	if !layouts_ok {
		return false
	}
	paths, paths_ok := foundation.files_with_suffix(BYTE_LAYOUT_DOCUMENT_FOLDER, ".md")
	if !paths_ok {
		fmt.eprintfln("modustool: byte layouts: cannot list %s", BYTE_LAYOUT_DOCUMENT_FOLDER)
		return false
	}
	problems := make([dynamic]string, context.temp_allocator)
	fences, written := 0, 0
	for path in paths {
		content, read_ok := foundation.read_text_file(path)
		if !read_ok {
			append(&problems, fmt.tprintf("cannot read %s", path))
			continue
		}
		rewritten, count, found := byte_layout_document_rewrite(content, path, layouts)
		fences += count
		append(&problems, ..found)
		if rewritten == content {
			continue
		}
		if !write {
			append(&problems, fmt.tprintf("%s: a fence %s does not hold the text that the code gives: run `modustool byte-layouts write`", path, BYTE_LAYOUT_FENCE_LANGUAGE))
			continue
		}
		if write_error := os.write_entire_file(path, transmute([]u8)rewritten); write_error != nil {
			append(&problems, fmt.tprintf("cannot write %s", path))
			continue
		}
		written += 1
		fmt.printfln("modustool: byte layouts: wrote the fences of %s", path)
	}
	if len(problems) > 0 {
		checks.problems_print(problems[:])
		fmt.eprintfln("modustool: test failed: the byte layouts of the guides have %d problems", len(problems))
		return false
	}
	if write {
		fmt.printfln("modustool: byte layouts: %d layouts, %d fences, %d files written", len(layouts), fences, written)
		return true
	}
	foundation.test_passed_print("%d byte layouts; the %d fences %s of the guides hold the text that the code gives", len(layouts), fences, BYTE_LAYOUT_FENCE_LANGUAGE)
	return true
}

// byte_layouts_check is the check of `modustool check`: each fence of
// layouts of the guides holds the text that the code gives.
byte_layouts_check :: proc() -> bool {
	return byte_layout_documents_rewrite(false)
}

run_byte_layouts :: proc(args: []string) -> int {
	usage_text :: "modustool byte-layouts write | check"
	if len(args) == 1 && args[0] == "write" {
		return byte_layout_documents_rewrite(true) ? 0 : foundation.EXIT_FAILURE
	}
	if len(args) == 1 && args[0] == "check" {
		return byte_layouts_check() ? 0 : foundation.EXIT_FAILURE
	}
	if len(args) > 0 {
		fmt.eprintfln("modustool: byte-layouts has no command %s", args[0])
	}
	fmt.eprintln(usage_text)
	return foundation.EXIT_USAGE
}

// byte_layout_name_html writes a name with a place to break after each
// "_", so that a long name wraps at a word in a narrow rectangle.
byte_layout_name_html :: proc(b: ^strings.Builder, name: string) {
	parts := strings.split(name, "_", context.temp_allocator)
	for part, index in parts {
		if index > 0 {
			strings.write_string(b, "_<wbr>")
		}
		foundation.html_escape(b, part)
	}
}

// byte_layout_title gives the title of a rectangle: what a pointer that
// rests on it shows.
byte_layout_title :: proc(site: ^Site, field: Byte_Layout_Field) -> string {
	if field.is_padding {
		return fmt.tprintf("padding: offset %d, %s that no field uses", field.offset, site_type_size_text(field.size))
	}
	title := fmt.tprintf("%s: %s, offset %d, %s", field.name, field.type_text, field.offset, site_type_size_text(field.size))
	if field.comment == "" {
		return title
	}
	comment := site_source_comment_plain(site, field.comment)
	if comment == "" {
		return title
	}
	return strings.concatenate({title, ". ", comment}, context.temp_allocator)
}

// byte_layout_html writes the diagram of one layout: a figure with its
// caption, then a grid of 9 columns (the offsets, then the 8 bytes of a
// row) in a box that scrolls sideways on a narrow screen. Each rectangle is
// placed by classes: a page holds no style attribute.
byte_layout_html :: proc(site: ^Site, b: ^strings.Builder, id: string, layout: Byte_Layout) {
	fmt.sbprintf(b, "<figure class=\"byte-layout\" id=\"%s\">\n<figcaption>", id)
	if _, is_type := site_type_index(site, layout.key); is_type {
		site_type_reference(site, b, layout.key, layout.key, false)
	} else {
		strings.write_string(b, "<code>")
		foundation.html_escape(b, layout.key)
		strings.write_string(b, "</code>")
	}
	strings.write_string(b, ", ")
	foundation.html_escape(b, site_type_size_text(layout.size))
	strings.write_string(b, ": ")
	foundation.html_escape(b, layout.what)
	strings.write_string(b, "</figcaption>\n<div class=\"byte-layout-box\" role=\"region\" tabindex=\"0\" aria-label=\"The bytes of ")
	foundation.html_escape(b, layout.key)
	strings.write_string(b, "\"><div class=\"byte-layout-grid\">\n")
	// The rulers: the byte of the row, then its bits.
	strings.write_string(b, "<span class=\"byte-ruler byte-ruler-corner\">byte</span>")
	for column in 0 ..< BYTE_LAYOUT_ROW_BYTES {
		fmt.sbprintf(b, "<span class=\"byte-ruler byte-column-%d\">%d</span>", column + 1, column)
	}
	strings.write_string(b, "\n<span class=\"byte-ruler byte-ruler-bits byte-ruler-corner\">bit</span>")
	for column in 0 ..< BYTE_LAYOUT_ROW_BYTES {
		fmt.sbprintf(b, "<span class=\"byte-ruler byte-ruler-bits byte-column-%d\">%d–%d</span>", column + 1, column * 8, column * 8 + 7)
	}
	strings.write_byte(b, '\n')
	for row in 0 ..< byte_layout_row_count(layout.size) {
		fmt.sbprintf(b, "<span class=\"byte-offset byte-row-%d\">%d</span>\n", row + 1, row * BYTE_LAYOUT_ROW_BYTES)
	}
	for piece in byte_layout_pieces(layout) {
		field := layout.fields[piece.field]
		class := "byte-cell"
		if field.is_padding {
			class = "byte-cell byte-cell-padding"
		} else if !piece.first {
			class = "byte-cell byte-cell-continued"
		}
		fmt.sbprintf(b, "<div class=\"%s byte-column-%d byte-span-%d byte-row-%d byte-rows-%d\" title=\"", class, piece.column + 1, piece.span, piece.row + 1, piece.rows)
		foundation.html_escape(b, byte_layout_title(site, field))
		strings.write_string(b, "\"><code>")
		byte_layout_name_html(b, field.name)
		strings.write_string(b, "</code><span class=\"byte-cell-size\">")
		if piece.first {
			foundation.html_escape(b, site_type_size_text(field.size))
		} else {
			strings.write_string(b, "continued")
		}
		strings.write_string(b, "</span></div>\n")
	}
	strings.write_string(b, "</div></div>\n</figure>\n")
}

// byte_layout_fence_write writes the diagrams of a fence of layouts of a
// guide in the place of its block. A fence that names no layout, or whose
// body is not the text that the code gives, is a fault that stops the
// command; it is recorded in the second pass over the guides only, so that
// it is printed once.
byte_layout_fence_write :: proc(renderer: ^Site_Renderer, keys: []string, body: string, line: int) {
	site := renderer.site
	place := fmt.tprintf("%s, line %d", site_renderer_place(renderer), line)
	found, problem := byte_layouts_of_keys(keys, site.byte_layouts)
	if problem == "" && body != byte_layouts_text(found) {
		problem = fmt.tprintf("the fence %s does not hold the text that the code gives: run `modustool byte-layouts write`", BYTE_LAYOUT_FENCE_LANGUAGE)
	}
	if problem != "" && !site.document_headings_pending {
		append(&site.byte_layout_problems, fmt.tprintf("%s: %s", place, problem))
	}
	for layout in found {
		id := site_unique_id(renderer, strings.concatenate({"byte-layout-", foundation.text_slug(layout.key)}, context.temp_allocator))
		byte_layout_html(site, &renderer.builder, id, layout)
	}
}

// The rules of the diagrams that hold no number of rows. The lines are the
// outline of each rectangle, 1 pixel in the gap of 1 pixel of the grid, so
// two neighbours share one line at every zoom. The colors are the tokens of
// the site: they follow its light and its dark form.
BYTE_LAYOUT_RULES :: `
.byte-layout { margin: 0 0 16px; }
.byte-layout figcaption { padding: 0 0 8px; color: var(--text); }
.byte-layout-box { overflow-x: auto; padding: 1px; }
.byte-layout-box:focus-visible { outline: 2px solid var(--line); outline-offset: 2px; }
.byte-layout-grid { display: grid; grid-template-columns: max-content repeat(8, minmax(6em, 1fr)); grid-template-rows: auto auto; grid-auto-rows: minmax(40px, auto); gap: 1px; font-family: var(--mono); font-size: 13px; line-height: 16px; }
.byte-ruler { grid-row: 1; padding: 0 4px; color: var(--dim); font-size: 12px; text-align: center; font-variant-numeric: tabular-nums; }
.byte-ruler-bits { grid-row: 2; padding-bottom: 4px; }
.byte-ruler-corner { grid-column: 1; text-align: right; }
.byte-offset { grid-column: 1; padding: 4px 8px 0 0; color: var(--dim); text-align: right; font-variant-numeric: tabular-nums; }
.byte-cell { display: flex; flex-direction: column; justify-content: center; align-items: center; min-width: 0; padding: 4px 2px; background: var(--card-top); outline: 1px solid var(--dim); text-align: center; overflow-wrap: anywhere; cursor: help; }
.byte-cell code { background: none; padding: 0; font-size: 13px; overflow-wrap: anywhere; }
.byte-cell-size { color: var(--dim); font-size: 12px; }
.byte-cell-continued code { color: var(--dim); }
.byte-cell-padding { background: var(--background); color: var(--dim); }
.byte-cell-padding code { color: var(--dim); }
`

// byte_layout_rules gives the rules of the diagrams: the rules above, then
// the place classes of a rectangle. The rows go up to the most rows of a
// layout of today, from the same table of sources, so a larger record gets
// its rules at the same build. The first column of the grid holds the
// offsets, and the first two rows the rulers.
byte_layout_rules :: proc() -> string {
	most_rows := 1
	for source in byte_layout_sources() {
		most_rows = max(most_rows, byte_layout_row_count(byte_layout_source_size(source)))
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, BYTE_LAYOUT_RULES)
	for column in 1 ..= BYTE_LAYOUT_ROW_BYTES {
		fmt.sbprintf(&b, ".byte-column-%d {{ grid-column-start: %d; }}\n", column, column + 1)
	}
	for span in 1 ..= BYTE_LAYOUT_ROW_BYTES {
		fmt.sbprintf(&b, ".byte-span-%d {{ grid-column-end: span %d; }}\n", span, span)
	}
	for row in 1 ..= most_rows {
		fmt.sbprintf(&b, ".byte-row-%d {{ grid-row-start: %d; }}\n", row, row + 2)
		fmt.sbprintf(&b, ".byte-rows-%d {{ grid-row-end: span %d; }}\n", row, row)
	}
	return strings.to_string(b)
}
