// The glossary of the project (docs/SITE.md, "The glossary"): the one reader
// of the folder docs/glossary. The pages of the site, the links to a term,
// the search, the page graph, the references to a term and the check of the
// tool all read the terms that glossary_read gives.
package modustool

import "core:fmt"
import "core:strings"
import "modustool:foundation"

// The folder of the glossary: one file for each group, and the index.
GLOSSARY_FOLDER :: "docs/glossary"

// The index of the glossary: its title, its introduction and the list of
// the files of the groups, in their order.
GLOSSARY_INDEX_FILE :: GLOSSARY_FOLDER + "/README.md"

// The heading of the index above the list of the groups.
GLOSSARY_INDEX_HEADING :: "The groups"

// The start of the last paragraph of an entry: the words that the term
// replaces.
GLOSSARY_AVOIDED_PREFIX :: "Do not use: "

// The most words of the explanation of a term. A longer explanation repeats
// its guide, and then one fact has two places to keep true.
GLOSSARY_EXPLANATION_WORD_LIMIT :: 100

// One file of the folder: its path from the root of the repository and its
// text.
Glossary_File :: struct {
	path:    string,
	content: string,
}

// One term: a heading of level 3 under the heading of its group, its short
// definition (the first paragraph), its explanation, and the line of the
// words that it replaces.
Glossary_Term :: struct {
	name:             string, // The text of its heading, with no code marks.
	id:               string, // Its anchor on the page: "term-" and the slug of the name, "-2" for a second term of that slug.
	group:            string, // The name of its group.
	group_id:         string, // The id of its group: the folder of the page of the group on the site.
	file:             string, // The file of its group, from the root of the repository.
	line:             int, // The line of its heading in its file, from 1.
	definition:       string, // The first paragraph under the heading, as one line of Markdown: the text of a tooltip, a search result and the page graph.
	explanation:      string, // The Markdown between the short definition and the words to avoid, or "".
	explanation_line: int, // The line in its file of the first line of the explanation.
	avoided:          string, // The words after "Do not use: ", with no period at the end, or "".
}

// One group: one file, with a heading of level 2, a text before its first
// term, and its terms.
Glossary_Group :: struct {
	name:              string,
	id:                string,
	file:              string, // Its file, from the root of the repository.
	line:              int, // The line of its heading in its file.
	introduction:      string, // The Markdown between the heading and the first term, or "".
	introduction_line: int,
	terms:             []Glossary_Term,
}

Glossary :: struct {
	title:             string,
	introduction:      string, // The Markdown of the index between its title and the list of the groups.
	introduction_line: int,
	groups:            []Glossary_Group,
}

// One line of the list of the groups in the index: the name of the group
// and its file.
Glossary_Index_Entry :: struct {
	name: string,
	path: string, // From the root of the repository.
	line: int,
}

Glossary_Index :: struct {
	title:             string,
	introduction:      string,
	introduction_line: int,
	entries:           []Glossary_Index_Entry,
}

// glossary_is_file tells whether a path from the root names a file of the
// folder of the glossary.
glossary_is_file :: proc(path: string) -> bool {
	return strings.has_prefix(path, GLOSSARY_FOLDER + "/") && strings.has_suffix(path, ".md") && strings.index_byte(path[len(GLOSSARY_FOLDER) + 1:], '/') < 0
}

// glossary_group_file_name gives the name of the file of a group: the slug
// of its heading, with "_" for "-", as the names of the files of the
// repository have. The page of the group on the site has the slug.
glossary_group_file_name :: proc(group_name: string) -> string {
	name, _ := strings.replace_all(foundation.site_slug(group_name), "-", "_", context.temp_allocator)
	return strings.concatenate({name, ".md"}, context.temp_allocator)
}

// glossary_term_id gives the anchor of a term. A second term with the same
// slug gets "-2", as a second heading of a page does.
glossary_term_id :: proc(name: string, seen: ^map[string]int) -> string {
	id := strings.concatenate({"term-", foundation.site_slug(name)}, context.temp_allocator)
	seen^[id] += 1
	count := seen^[id]
	if count == 1 {
		return id
	}
	return fmt.tprintf("%s-%d", id, count)
}

// glossary_word_count gives the count of the words of a text: the runs of
// bytes between spaces, tabs and ends of lines.
glossary_word_count :: proc(text: string) -> int {
	count := 0
	inside := false
	for index in 0 ..< len(text) {
		character := text[index]
		space := character == ' ' || character == '\t' || character == '\n' || character == '\r'
		if !space && !inside {
			count += 1
		}
		inside = !space
	}
	return count
}

// glossary_markdown gives the lines of a part as one Markdown text, with no
// empty line at its ends, and the line in the file of its first line.
glossary_markdown :: proc(lines: []string, first_line: int) -> (text: string, line: int) {
	start, end := 0, len(lines)
	for start < end && strings.trim_space(lines[start]) == "" {
		start += 1
	}
	for end > start && strings.trim_space(lines[end - 1]) == "" {
		end -= 1
	}
	if start == end {
		return "", 0
	}
	return strings.join(lines[start:end], "\n", context.temp_allocator), first_line + start
}

// glossary_heading_indices gives the index in lines of each heading outside
// the fences of code, then len(lines). A line of a table of terms, the
// form before the headings, is a problem.
glossary_heading_indices :: proc(path: string, lines: []string, problems: ^[dynamic]string) -> []int {
	indices := make([dynamic]int, context.temp_allocator)
	fenced := false
	for line, index in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "```") {
			fenced = !fenced
			continue
		}
		if fenced {
			continue
		}
		if level, _ := site_heading_level(line); level > 0 {
			append(&indices, index)
		}
		if strings.has_prefix(trimmed, "| Term |") {
			append(problems, fmt.tprintf("%s, line %d: a table of terms: each term is a heading of level 3 in its group", path, index + 1))
		}
	}
	append(&indices, len(lines))
	return indices[:]
}

// glossary_index_read reads the index of the glossary: a title of level 1,
// its introduction, then the heading "The groups" and one line for each
// group, "- [<group>](<file>)", with words after ": " if the line explains
// the group. The file of a group has the name that glossary_group_file_name
// gives.
glossary_index_read :: proc(content: string) -> (index: Glossary_Index, problems: []string) {
	found := make([dynamic]string, context.temp_allocator)
	entries := make([dynamic]Glossary_Index_Entry, context.temp_allocator)
	lines := foundation.site_lines(content)
	headings := glossary_heading_indices(GLOSSARY_INDEX_FILE, lines, &found)
	if strings.trim_space(strings.join(lines[:headings[0]], "", context.temp_allocator)) != "" {
		append(&found, fmt.tprintf("%s: a text before the title: the file starts with its title (a heading of level 1)", GLOSSARY_INDEX_FILE))
	}
	listed := false
	for position in 0 ..< len(headings) - 1 {
		heading := headings[position]
		body := lines[heading + 1:headings[position + 1]]
		level, text := site_heading_level(lines[heading])
		switch {
		case position == 0 && level == 1:
			index.title = text
			index.introduction, index.introduction_line = glossary_markdown(body, heading + 2)
		case level == 2 && text == GLOSSARY_INDEX_HEADING && !listed:
			listed = true
			for line, line_index in body {
				trimmed := strings.trim_space(line)
				if trimmed == "" {
					continue
				}
				line_number := heading + 2 + line_index
				entry, entry_ok := glossary_index_entry_read(trimmed, line_number)
				if !entry_ok {
					append(&found, fmt.tprintf("%s, line %d: a line of the list of the groups is \"- [<group>](<file>)\"", GLOSSARY_INDEX_FILE, line_number))
					continue
				}
				if name := glossary_group_file_name(entry.name); entry.path != strings.concatenate({GLOSSARY_FOLDER, "/", name}, context.temp_allocator) {
					append(&found, fmt.tprintf("%s, line %d: the group %q has the file %s; its file is %s", GLOSSARY_INDEX_FILE, line_number, entry.name, entry.path, name))
					continue
				}
				named_before := false
				for other in entries {
					named_before ||= other.path == entry.path
				}
				if named_before {
					append(&found, fmt.tprintf("%s, line %d: the list names %s a second time", GLOSSARY_INDEX_FILE, line_number, entry.path))
					continue
				}
				append(&entries, entry)
			}
		case:
			append(&found, fmt.tprintf("%s, line %d: the index has its title, its introduction and the heading %q of the list of the groups, and no other heading", GLOSSARY_INDEX_FILE, heading + 1, GLOSSARY_INDEX_HEADING))
		}
	}
	if index.title == "" {
		append(&found, fmt.tprintf("%s: the file has no title (a heading of level 1 on its first line that is not empty)", GLOSSARY_INDEX_FILE))
	}
	if !listed {
		append(&found, fmt.tprintf("%s: the index has no heading %q with the list of the groups", GLOSSARY_INDEX_FILE, GLOSSARY_INDEX_HEADING))
	}
	index.entries = entries[:]
	return index, found[:]
}

// glossary_index_entry_read reads one line of the list of the groups:
// "- [<group>](<file>)", then nothing or ": " and words.
glossary_index_entry_read :: proc(line: string, line_number: int) -> (entry: Glossary_Index_Entry, ok: bool) {
	if !strings.has_prefix(line, "- [") {
		return {}, false
	}
	middle := strings.index(line, "](")
	if middle < len("- [") + 1 {
		return {}, false
	}
	closing := strings.index_byte(line[middle:], ')')
	if closing < 0 {
		return {}, false
	}
	closing += middle
	target := line[middle + len("]("):closing]
	after := line[closing + 1:]
	if target == "" || strings.index_byte(target, '/') >= 0 || !strings.has_suffix(target, ".md") || (after != "" && !strings.has_prefix(after, ": ")) {
		return {}, false
	}
	return {name = line[len("- ["):middle], path = strings.concatenate({GLOSSARY_FOLDER, "/", target}, context.temp_allocator), line = line_number}, true
}

// glossary_read reads the glossary: its index, then the file of each group
// in the order of the index. The files are each file of the folder but the
// index: a file that the index does not list is a problem, as a listed file
// that is not there. Each problem names its file and its line; the reader
// gives the terms that it could read all the same.
glossary_read :: proc(index_content: string, group_files: []Glossary_File) -> (glossary: Glossary, problems: []string) {
	found := make([dynamic]string, context.temp_allocator)
	index, index_problems := glossary_index_read(index_content)
	append(&found, ..index_problems)
	glossary.title = index.title
	glossary.introduction = index.introduction
	glossary.introduction_line = index.introduction_line

	groups := make([dynamic]Glossary_Group, context.temp_allocator)
	seen_ids := make(map[string]int, context.temp_allocator)
	for entry in index.entries {
		file_found := false
		for file in group_files {
			if file.path != entry.path {
				continue
			}
			file_found = true
			group, has_group := glossary_group_read(file, &seen_ids, &found)
			if !has_group {
				break
			}
			if group.name != entry.name {
				append(&found, fmt.tprintf("%s, line %d: the list names the group %q, and the heading of %s is %q", GLOSSARY_INDEX_FILE, entry.line, entry.name, file.path, group.name))
			}
			// Each group is a page of the site, in a folder named by the
			// slug of its heading: two groups of one slug would be one page.
			for other in groups {
				if other.id == group.id {
					append(&found, fmt.tprintf("%s, line %d: the group %q has the slug %q of the group %q: each group is a page, named by its slug", file.path, group.line, group.name, group.id, other.name))
				}
			}
			append(&groups, group)
			break
		}
		if !file_found {
			append(&found, fmt.tprintf("%s, line %d: the list names %s, and the folder has no such file", GLOSSARY_INDEX_FILE, entry.line, entry.path))
		}
	}
	for file in group_files {
		listed := false
		for entry in index.entries {
			listed ||= entry.path == file.path
		}
		if !listed {
			append(&found, fmt.tprintf("%s: a file of the glossary that the list of %s does not name", file.path, GLOSSARY_INDEX_FILE))
		}
	}
	glossary.groups = groups[:]
	return glossary, found[:]
}

// glossary_group_read reads the file of one group: its heading of level 2
// on its first line that is not empty, the text before its first term,
// then its terms, each a heading of level 3.
glossary_group_read :: proc(file: Glossary_File, seen_ids: ^map[string]int, problems: ^[dynamic]string) -> (group: Glossary_Group, ok: bool) {
	lines := foundation.site_lines(file.content)
	headings := glossary_heading_indices(file.path, lines, problems)
	if len(headings) == 1 || strings.trim_space(strings.join(lines[:headings[0]], "", context.temp_allocator)) != "" {
		append(problems, fmt.tprintf("%s: the file does not start with the heading of its group (a heading of level 2)", file.path))
		return {}, false
	}
	terms := make([dynamic]Glossary_Term, context.temp_allocator)
	for position in 0 ..< len(headings) - 1 {
		heading := headings[position]
		body := lines[heading + 1:headings[position + 1]]
		level, text := site_heading_level(lines[heading])
		switch {
		case position == 0 && level == 2:
			group = Glossary_Group{name = text, id = foundation.site_slug(text), file = file.path, line = heading + 1}
			group.introduction, group.introduction_line = glossary_markdown(body, heading + 2)
		case position == 0 && level == 3:
			append(problems, fmt.tprintf("%s, line %d: the term %q comes before the heading of a group", file.path, heading + 1, text))
			return {}, false
		case position == 0:
			append(problems, fmt.tprintf("%s, line %d: a heading of level %d: the file of a group starts with the heading of its group, of level 2", file.path, heading + 1, level))
			return {}, false
		case level == 2:
			append(problems, fmt.tprintf("%s, line %d: a second group %q: each group has its own file", file.path, heading + 1, text))
		case level == 3:
			term := glossary_term_read(file.path, text, heading + 1, body, seen_ids, problems)
			term.group = group.name
			term.group_id = group.id
			append(&terms, term)
		case:
			append(problems, fmt.tprintf("%s, line %d: a heading of level %d: an entry has no heading inside it", file.path, heading + 1, level))
		}
	}
	group.terms = terms[:]
	return group, true
}

// glossary_term_read reads the entry of one term: the lines under its
// heading, in paragraphs (blocks of lines that an empty line outside a
// fence ends).
glossary_term_read :: proc(path, heading: string, heading_line: int, body: []string, seen_ids: ^map[string]int, problems: ^[dynamic]string) -> Glossary_Term {
	term := Glossary_Term{name = site_term_name(heading), file = path, line = heading_line}
	term.id = glossary_term_id(term.name, seen_ids)

	blocks := make([dynamic][2]int, context.temp_allocator)
	fenced := false
	start := -1
	for line, index in body {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "```") {
			fenced = !fenced
		}
		if trimmed == "" && !fenced {
			if start >= 0 {
				append(&blocks, [2]int{start, index})
				start = -1
			}
			continue
		}
		if start < 0 {
			start = index
		}
	}
	if start >= 0 {
		append(&blocks, [2]int{start, len(body)})
	}

	if len(blocks) == 0 {
		append(problems, fmt.tprintf("%s, line %d: the term %q has no short definition", path, heading_line, term.name))
		return term
	}
	first_line := strings.trim_space(body[blocks[0][0]])
	_, is_list := site_list_marker(body[blocks[0][0]])
	if is_list || strings.has_prefix(first_line, "|") || strings.has_prefix(first_line, "```") || strings.has_prefix(first_line, ">") || strings.has_prefix(first_line, GLOSSARY_AVOIDED_PREFIX) {
		append(problems, fmt.tprintf("%s, line %d: the term %q starts with no short definition: its first paragraph is the definition, one paragraph of text", path, heading_line, term.name))
		return term
	}
	parts := make([dynamic]string, context.temp_allocator)
	for line in body[blocks[0][0]:blocks[0][1]] {
		append(&parts, strings.trim_space(line))
	}
	term.definition = strings.join(parts[:], " ", context.temp_allocator)

	explained_end := len(blocks)
	last := blocks[len(blocks) - 1]
	if len(blocks) > 1 && strings.has_prefix(strings.trim_space(body[last[0]]), GLOSSARY_AVOIDED_PREFIX) {
		words := make([dynamic]string, context.temp_allocator)
		for line in body[last[0]:last[1]] {
			append(&words, strings.trim_space(line))
		}
		avoided := strings.join(words[:], " ", context.temp_allocator)
		avoided = strings.trim_space(avoided[len(GLOSSARY_AVOIDED_PREFIX):])
		term.avoided = strings.trim_suffix(avoided, ".")
		explained_end = len(blocks) - 1
	}
	for block in blocks[1:explained_end] {
		if strings.has_prefix(strings.trim_space(body[block[0]]), GLOSSARY_AVOIDED_PREFIX) {
			append(problems, fmt.tprintf("%s, line %d: the words that the term %q replaces are not the last paragraph of its entry", path, heading_line + 1 + block[0], term.name))
		}
	}
	if explained_end > 1 {
		explanation_start := blocks[1][0]
		explanation_end := blocks[explained_end - 1][1]
		term.explanation = strings.join(body[explanation_start:explanation_end], "\n", context.temp_allocator)
		term.explanation_line = heading_line + 1 + explanation_start
	}
	// The explanation is the words after the short definition, up to the
	// words to avoid: neither of the two counts.
	if count := glossary_word_count(term.explanation); count > GLOSSARY_EXPLANATION_WORD_LIMIT {
		append(problems, fmt.tprintf("%s, line %d: the explanation of the term %q has %d words; an explanation has at most %d, and its guide holds the detail", path, heading_line, term.name, count, GLOSSARY_EXPLANATION_WORD_LIMIT))
	}
	return term
}

// glossary_load reads the glossary through read: the index, then each file
// that its list names. A file of the folder that the list does not name is
// not read: glossary_read_folder finds it.
glossary_load :: proc(read: Manual_Document_Reader) -> (glossary: Glossary, problems: []string) {
	index_content, index_ok := read(GLOSSARY_INDEX_FILE)
	if !index_ok {
		found := make([]string, 1, context.temp_allocator)
		found[0] = fmt.tprintf("%s: the file cannot be read", GLOSSARY_INDEX_FILE)
		return {}, found
	}
	index, _ := glossary_index_read(index_content)
	files := make([dynamic]Glossary_File, context.temp_allocator)
	for entry in index.entries {
		if content, read_ok := read(entry.path); read_ok {
			append(&files, Glossary_File{path = entry.path, content = content})
		}
	}
	return glossary_read(index_content, files[:])
}

// glossary_read_folder reads the glossary of the repository: the index and
// each other Markdown file of the folder. It is false when the folder or a
// file cannot be read, with a line that says which.
glossary_read_folder :: proc() -> (glossary: Glossary, problems: []string, ok: bool) {
	paths := foundation.files_with_suffix(GLOSSARY_FOLDER, ".md") or_return
	index_content := ""
	index_found := false
	files := make([dynamic]Glossary_File, context.temp_allocator)
	for path in paths {
		content, read_ok := foundation.site_read_quiet(path)
		if !read_ok {
			fmt.eprintfln("modustool: cannot read %s", path)
			return {}, nil, false
		}
		if path == GLOSSARY_INDEX_FILE {
			index_content, index_found = content, true
		} else {
			append(&files, Glossary_File{path = path, content = content})
		}
	}
	if !index_found {
		fmt.eprintfln("modustool: cannot read %s", GLOSSARY_INDEX_FILE)
		return {}, nil, false
	}
	glossary, problems = glossary_read(index_content, files[:])
	return glossary, problems, true
}

// glossary_terms_in_order gives the terms of each group, in the order of the
// index.
glossary_terms_in_order :: proc(glossary: Glossary) -> []Glossary_Term {
	terms := make([dynamic]Glossary_Term, context.temp_allocator)
	for group in glossary.groups {
		append(&terms, ..group.terms)
	}
	return terms[:]
}

// glossary_check refuses a glossary that does not have its form, and
// prints the terms that have a short definition and no explanation: a
// warning, until each group has its explanations (docs/SITE.md, "The
// glossary").
glossary_check :: proc() -> bool {
	glossary, problems, read_ok := glossary_read_folder()
	if !read_ok {
		fmt.eprintfln("modustool: test failed: cannot read the glossary in %s", GLOSSARY_FOLDER)
		return false
	}
	for problem in problems {
		fmt.eprintfln("modustool: test failed: %s", problem)
	}
	if len(problems) > 0 {
		return false
	}
	terms := glossary_terms_in_order(glossary)
	unexplained := 0
	for term in terms {
		unexplained += term.explanation == "" ? 1 : 0
	}
	if unexplained > 0 {
		fmt.printfln("modustool: warning: %d of the %d terms of %s have a short definition and no explanation:", unexplained, len(terms), GLOSSARY_FOLDER)
		for group in glossary.groups {
			names := make([dynamic]string, context.temp_allocator)
			for term in group.terms {
				if term.explanation == "" {
					append(&names, term.name)
				}
			}
			if len(names) > 0 {
				fmt.printfln("modustool: warning:   %s (%d): %s", group.name, len(names), strings.join(names[:], ", ", context.temp_allocator))
			}
		}
	}
	foundation.test_passed_print("each of the %d terms of the %d groups of %s has its heading, its short definition, an explanation of at most %d words and the form of its entry", len(terms), len(glossary.groups), GLOSSARY_FOLDER, GLOSSARY_EXPLANATION_WORD_LIMIT)
	return true
}
