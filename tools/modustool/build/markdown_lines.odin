// The lines of a Markdown guide that the build reads for the manual and the
// glossary: a list marker, a heading, a row of a table, the name of a term.
package build

import "core:strings"

// The start of a list item: its indentation, its marker and its text.
Site_Marker :: struct {
	indent:  int,
	ordered: bool,
	label:   string,
	text:    string,
}

// site_list_marker reads "- text", "* text", "12. text" or "34b. text" after
// spaces.
site_list_marker :: proc(line: string) -> (marker: Site_Marker, found: bool) {
	indent := 0
	for indent < len(line) && line[indent] == ' ' {
		indent += 1
	}
	rest := line[indent:]
	if strings.has_prefix(rest, "- ") || strings.has_prefix(rest, "* ") {
		return {indent = indent, text = rest[2:]}, true
	}
	digits := 0
	for digits < len(rest) && rest[digits] >= '0' && rest[digits] <= '9' {
		digits += 1
	}
	if digits == 0 || digits > 4 {
		return {}, false
	}
	end := digits
	if end < len(rest) && rest[end] >= 'a' && rest[end] <= 'z' {
		end += 1
	}
	if end + 1 < len(rest) && rest[end] == '.' && rest[end + 1] == ' ' {
		return {indent = indent, ordered = true, label = rest[:end], text = rest[end + 2:]}, true
	}
	return {}, false
}

site_heading_level :: proc(line: string) -> (level: int, text: string) {
	for level < len(line) && line[level] == '#' {
		level += 1
	}
	if level == 0 || level > 6 || level >= len(line) || line[level] != ' ' {
		return 0, ""
	}
	return level, strings.trim_space(line[level + 1:])
}

// site_table_row_cells splits a row of a table; "\|" is a "|" of the text.
site_table_row_cells :: proc(line: string) -> []string {
	cells := make([dynamic]string, context.temp_allocator)
	inner := strings.trim_space(line)
	inner = strings.trim_prefix(inner, "|")
	if strings.has_suffix(inner, "|") && !strings.has_suffix(inner, "\\|") {
		inner = inner[:len(inner) - 1]
	}
	cell := strings.builder_make(context.temp_allocator)
	for index := 0; index < len(inner); index += 1 {
		if inner[index] == '\\' && index + 1 < len(inner) && inner[index + 1] == '|' {
			strings.write_byte(&cell, '|')
			index += 1
			continue
		}
		if inner[index] == '|' {
			append(&cells, strings.trim_space(strings.clone(strings.to_string(cell), context.temp_allocator)))
			strings.builder_reset(&cell)
			continue
		}
		strings.write_byte(&cell, inner[index])
	}
	append(&cells, strings.trim_space(strings.clone(strings.to_string(cell), context.temp_allocator)))
	return cells[:]
}

// site_term_name gives the name of a term from the heading of its entry in
// the glossary: its text with no code marks.
site_term_name :: proc(cell: string) -> string {
	name, _ := strings.remove_all(cell, "`", context.temp_allocator)
	return strings.trim_space(name)
}
