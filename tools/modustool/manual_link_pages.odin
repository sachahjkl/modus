// The link pages of the manual (src/md/features/manual_links.md): the
// resource `manual_pages` of the boot image. The documentation of a module
// links terms of the glossary and headings of the guides; the program
// `manual` reads only the boot image, so the build writes the page of each
// such target in one resource, in the format of
// src/library/contract/manual_pages.
package modustool

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "modus:contract/manual_pages"
import module "modus:contract/module"

MANUAL_PAGES_FILE :: BUILD_FOLDER + "/manual_pages.resource"

// A reader of a document of the repository, by its path from the root: the
// build reads the files, a host test gives texts.
Manual_Document_Reader :: #type proc(path: string) -> (text: string, ok: bool)

// build_manual_pages writes the resource of the link pages from the module
// files of the boot image and the documents of the repository.
build_manual_pages :: proc() -> (resource: Resource_File, ok: bool) {
	files := make([dynamic][]u8, context.temp_allocator)
	for build in module_builds {
		if module_in_boot_image(build) {
			append(&files, read_file(module_path(build.name)) or_return)
		}
	}
	sources, missing := manual_link_pages_make(files[:], site_read_quiet)
	// A target that names nothing stops `modustool site`: here it is only
	// a link that the manual draws with no line under it.
	for target in missing {
		fmt.printfln("modustool: warning: the link to %s in the documentation of a module has no page in the manual", target)
	}
	buffer := make([]u8, manual_pages.encoded_size(sources), context.temp_allocator)
	if !manual_pages.encode(sources, buffer) {
		fmt.eprintfln("modustool: the link pages of the manual break a rule of src/library/contract/manual_pages")
		return {}, false
	}
	if err := os.write_entire_file(MANUAL_PAGES_FILE, buffer); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", MANUAL_PAGES_FILE, err)
		return {}, false
	}
	return {name = manual_pages.RESOURCE_NAME, path = MANUAL_PAGES_FILE}, true
}

// manual_documentation_texts gives the documentation text of each module
// file and of each of its exports.
manual_documentation_texts :: proc(files: [][]u8) -> []string {
	texts := make([dynamic]string, context.temp_allocator)
	for file in files {
		if module.validate(file) != .None {
			continue
		}
		_, text := module.documentation(file)
		append(&texts, text)
		for index in 1 ..< module.count(file, .Exports) {
			if function, found := module.function(file, index); found {
				append(&texts, module.string_at(file, function.text_offset, function.text_count))
			}
		}
	}
	return texts[:]
}

// manual_link_pages_make gives the link pages of the documentation of these
// module files, in the order of the bytes of their targets, and each target
// of a term or a guide that names nothing that the reader has.
manual_link_pages_make :: proc(files: [][]u8, read: Manual_Document_Reader) -> (pages: []manual_pages.Page_Source, missing: []string) {
	targets := make([dynamic]string, context.temp_allocator)
	for text in manual_documentation_texts(files) {
		found, _ := site_comment_links(text)
		append(&targets, ..found)
	}
	return manual_link_pages_of_targets(targets[:], read)
}

// manual_link_pages_of_targets gives the link pages of the targets of
// links: the targets of a term or a guide, and the headings under each
// heading of a guide.
manual_link_pages_of_targets :: proc(targets: []string, read: Manual_Document_Reader) -> (pages: []manual_pages.Page_Source, missing: []string) {
	waiting := make([dynamic]string, context.temp_allocator)
	for target in targets {
		kind := manual_pages.link_target_kind(target)
		if kind == .Term || kind == .Guide {
			append(&waiting, target)
		}
	}
	done := make(map[string]bool, context.temp_allocator)
	page_list := make([dynamic]manual_pages.Page_Source, context.temp_allocator)
	missing_list := make([dynamic]string, context.temp_allocator)
	glossary: Glossary
	glossary_read_done := false
	for len(waiting) > 0 {
		target := pop(&waiting)
		if target in done {
			continue
		}
		done[target] = true
		page: manual_pages.Page_Source
		found := false
		children: []string
		switch manual_pages.link_target_kind(target) {
		case .Term:
			if !glossary_read_done {
				glossary_read_done = true
				if content, read_ok := read(SITE_GLOSSARY_FILE); read_ok {
					glossary, _ = glossary_read(content)
				}
			}
			page, found = manual_term_page(glossary, target)
		case .Guide:
			page, children, found = manual_guide_page(target, read)
		case .Name, .Address:
		}
		// A page that the format refuses (a control character in a guide, a
		// target over its limit) is a link with no page, not a failed build.
		if !found || len(target) > manual_pages.TARGET_SIZE_LIMIT || !manual_pages.markdown_valid(transmute([]u8)page.title) || !manual_pages.markdown_valid(transmute([]u8)page.text) {
			append(&missing_list, target)
			continue
		}
		append(&page_list, page)
		append(&waiting, ..children)
	}
	slice.sort_by(page_list[:], proc(first, second: manual_pages.Page_Source) -> bool {
		return manual_pages.bytes_compare(first.target, second.target) < 0
	})
	slice.sort(missing_list[:])
	return page_list[:], missing_list[:]
}

// manual_term_page gives the page of a target "term:<term>": the name of
// the term, then its short definition and its explanation. The name
// matches with no regard to case, as on the site.
manual_term_page :: proc(glossary: Glossary, target: string) -> (page: manual_pages.Page_Source, found: bool) {
	wanted := site_slug(target[len(manual_pages.TERM_PREFIX):])
	for group in glossary.groups {
		for term in group.terms {
			if site_slug(term.name) != wanted {
				continue
			}
			text := term.definition
			if term.explanation != "" {
				explanation := manual_markdown_of_guide(site_lines(term.explanation), SITE_GLOSSARY_FILE)
				text = strings.concatenate({text, "\n\n", explanation}, context.temp_allocator)
			}
			return {target = target, title = manual_title_of(term.name), text = text}, true
		}
	}
	return {}, false
}

// One heading of a guide, with its id on the page of the site.
Manual_Guide_Heading :: struct {
	level: int,
	text:  string,
	id:    string,
	line:  int, // Its index in the lines of the file.
}

// manual_guide_headings gives the headings of a guide outside its fences.
// The id is the slug of the text, and "-2", "-3"... for a slug that a
// heading before it has, as the site writes it.
manual_guide_headings :: proc(lines: []string) -> []Manual_Guide_Heading {
	headings := make([dynamic]Manual_Guide_Heading, context.temp_allocator)
	seen := make(map[string]int, context.temp_allocator)
	fenced := false
	for line, index in lines {
		if strings.has_prefix(strings.trim_space(line), "```") {
			fenced = !fenced
			continue
		}
		if fenced {
			continue
		}
		level, text := site_heading_level(line)
		if level == 0 {
			continue
		}
		slug := site_slug(text)
		seen[slug] += 1
		id := seen[slug] == 1 ? slug : fmt.tprintf("%s-%d", slug, seen[slug])
		append(&headings, Manual_Guide_Heading{level = level, text = text, id = id, line = index})
	}
	return headings[:]
}

// manual_guide_page gives the page of a target "docs/<NAME>.md#<id>": the
// heading, the text under it up to the next heading, and a list of links
// to the headings directly under it, whose targets come back as children.
// A target with no id is the text before the first heading of level 2, and
// a link to each heading of level 2.
manual_guide_page :: proc(target: string, read: Manual_Document_Reader) -> (page: manual_pages.Page_Source, children: []string, found: bool) {
	path, anchor := target, ""
	if hash := strings.index_byte(target, '#'); hash >= 0 {
		path, anchor = target[:hash], target[hash + 1:]
	}
	content, read_ok := read(path)
	if !read_ok || !strings.has_suffix(path, ".md") {
		return {}, nil, false
	}
	lines := site_lines(content)
	headings := manual_guide_headings(lines)
	place := -1
	if anchor == "" {
		for heading, index in headings {
			if heading.level == 1 {
				place = index
				break
			}
		}
	} else {
		for heading, index in headings {
			if heading.id == anchor {
				place = index
				break
			}
		}
	}
	if place < 0 && anchor != "" {
		return {}, nil, false
	}
	title := site_file_name(path)
	level, body_start := 1, 0
	if place >= 0 {
		title, level, body_start = headings[place].text, headings[place].level, headings[place].line + 1
	}
	// The body ends at the next heading, of any level.
	body_end := len(lines)
	under := make([dynamic]Manual_Guide_Heading, context.temp_allocator)
	next_index := place + 1
	if next_index < len(headings) {
		body_end = headings[next_index].line
	}
	// The headings under this one, to the next heading of its level or
	// higher; the direct ones have the smallest level among them.
	smallest := 7
	for heading in headings[next_index:] {
		if heading.level <= level {
			break
		}
		smallest = min(smallest, heading.level)
	}
	for heading in headings[next_index:] {
		if heading.level <= level {
			break
		}
		if heading.level == smallest {
			append(&under, heading)
		}
	}
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, manual_markdown_of_guide(lines[body_start:body_end], path))
	child_targets := make([dynamic]string, context.temp_allocator)
	if len(under) > 0 {
		if strings.builder_len(builder) > 0 {
			strings.write_string(&builder, "\n\n")
		}
		for heading, index in under {
			child := strings.concatenate({path, "#", heading.id}, context.temp_allocator)
			append(&child_targets, child)
			if index > 0 {
				strings.write_byte(&builder, '\n')
			}
			fmt.sbprintf(&builder, "- [%s](%s)", manual_link_label_of(heading.text), child)
		}
	}
	return {target = target, title = manual_title_of(title), text = strings.to_string(builder)}, child_targets[:], true
}

// manual_title_of gives the title of a page: one line with no marks of
// Markdown, cut after a whole character at the limit of the format.
manual_title_of :: proc(text: string) -> string {
	plain := markdown_inline_plain(text, false)
	plain, _ = strings.replace_all(plain, "\t", " ", context.temp_allocator)
	if len(plain) <= manual_pages.TITLE_SIZE_LIMIT {
		return plain
	}
	cut := manual_pages.TITLE_SIZE_LIMIT
	for cut > 0 && plain[cut] & 0xC0 == 0x80 {
		cut -= 1
	}
	return plain[:cut]
}

// manual_link_label_of gives the label of a link to a heading: its text
// with no "[" or "]", which would end the label.
manual_link_label_of :: proc(text: string) -> string {
	label, _ := strings.replace_all(text, "[", "(", context.temp_allocator)
	label, _ = strings.replace_all(label, "]", ")", context.temp_allocator)
	return label
}

// manual_markdown_of_guide writes lines of a guide in the Markdown of a
// source comment, which the reader of the system reads: a heading is a
// bold paragraph, a row of a table is a list item whose cells are joined by
// "; ", a row of dashes goes, a quote is its text, a tab is four spaces,
// and a relative link of the guide names its guide from the root. The
// lines of a fence stay as they are.
manual_markdown_of_guide :: proc(lines: []string, guide: string) -> string {
	out := make([dynamic]string, context.temp_allocator)
	fenced := false
	in_table := false
	for raw in lines {
		line, _ := strings.replace_all(raw, "\t", "    ", context.temp_allocator)
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "```") {
			fenced = !fenced
			append(&out, line)
			continue
		}
		if fenced {
			append(&out, line)
			continue
		}
		if level, text := site_heading_level(line); level > 0 {
			manual_markdown_blank_line(&out)
			append(&out, strings.concatenate({"**", manual_links_from_root(text, guide), "**"}, context.temp_allocator))
			append(&out, "")
			in_table = false
			continue
		}
		if strings.has_prefix(trimmed, "|") {
			if !in_table {
				manual_markdown_blank_line(&out)
				in_table = true
			}
			if manual_table_separator(trimmed) {
				continue
			}
			cells := site_table_row_cells(trimmed)
			for &cell in cells {
				cell = strings.trim_space(cell)
			}
			append(&out, strings.concatenate({"- ", manual_links_from_root(strings.join(cells, "; ", context.temp_allocator), guide)}, context.temp_allocator))
			continue
		}
		if in_table {
			in_table = false
			if trimmed != "" {
				append(&out, "")
			}
		}
		if strings.has_prefix(trimmed, ">") {
			line = strings.trim_space(trimmed[1:])
		}
		append(&out, manual_links_from_root(line, guide))
	}
	// No empty line at the two ends.
	start, end := 0, len(out)
	for start < end && strings.trim_space(out[start]) == "" {
		start += 1
	}
	for end > start && strings.trim_space(out[end - 1]) == "" {
		end -= 1
	}
	return strings.join(out[start:end], "\n", context.temp_allocator)
}

// manual_markdown_blank_line ends the block before with an empty line.
manual_markdown_blank_line :: proc(out: ^[dynamic]string) {
	if len(out) > 0 && strings.trim_space(out[len(out) - 1]) != "" {
		append(out, "")
	}
}

// manual_table_separator says if a row of a table is its row of dashes.
manual_table_separator :: proc(row: string) -> bool {
	dashes := false
	for character in row {
		switch character {
		case '-':
			dashes = true
		case '|', ':', ' ':
		case:
			return false
		}
	}
	return dashes
}

// manual_links_from_root writes each link of a line of a guide with its
// target from the root of the repository: "STORAGE.md#4-7" in a guide is
// "docs/STORAGE.md#4-7", and "#4-7" is the same guide. An address and a
// target that is outside docs/ stay as they are: the manual opens only the
// pages that the resource has.
manual_links_from_root :: proc(line, guide: string) -> string {
	if !strings.contains(line, "](") {
		return line
	}
	builder := strings.builder_make(context.temp_allocator)
	index := 0
	for index < len(line) {
		if line[index] == '[' {
			if label, target, end, found := markdown_link_at(line, index); found {
				fmt.sbprintf(&builder, "[%s](%s)", label, manual_target_from_root(target, guide))
				index = end
				continue
			}
		}
		strings.write_byte(&builder, line[index])
		index += 1
	}
	return strings.to_string(builder)
}

// manual_target_from_root gives the target of a link of a guide from the
// root of the repository.
manual_target_from_root :: proc(target, guide: string) -> string {
	if strings.has_prefix(target, "#") {
		return strings.concatenate({guide, target}, context.temp_allocator)
	}
	// An address, a target from the root, a term, and a path outside the
	// folder of the guides stay.
	if strings.contains(target, "/") || strings.has_prefix(target, manual_pages.TERM_PREFIX) {
		return target
	}
	if strings.contains(target, ".md") {
		return strings.concatenate({manual_pages.GUIDE_PREFIX, target}, context.temp_allocator)
	}
	return target
}
