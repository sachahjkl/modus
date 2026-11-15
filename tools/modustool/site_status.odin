// The status page of the site (docs/SITE.md, "The status page"): the state
// of each property in the words of docs/PROPERTIES.md, then for each
// property what it promises and what the machine test shows of it
// (docs/DEMONSTRATIONS.md). What is not done is shown as plainly as what is
// done. No sentence of the page but the one that says how to read a state
// is a summary that the tool writes: each cell is a part of one of the two
// documents. The planned work is not on this page: one line leads to the
// page of the roadmap (site_roadmap.odin).
package modustool

import "core:fmt"
import "core:slice"
import "core:strings"

SITE_DEMONSTRATIONS_FILE :: "docs/DEMONSTRATIONS.md"

// One row of the table of the demonstrations: what the machine test shows
// of one property, its pictures, and what no test shows.
Site_Demonstration :: struct {
	number:   int,
	state:    string, // "Shown", "Shown in part" or "Not shown".
	shown:    string, // What the test shows, as Markdown.
	pictures: []string, // The names of the pictures of docs/screenshots, with no ".png".
	missing:  string, // What no test shows; "—" for nothing.
	line:     int,
}

// One item of the list "What removes each ...": the work that would end a
// part that is not shown.
Site_Demonstration_Removal :: struct {
	text: string,
	line: int,
}

// site_demonstrations_read reads the table of the section "## The table"
// and the numbered items of the section that starts "## What removes". The
// form: a row "| <n> | <property> | <state> | <what the test shows> |
// <pictures> | <what no test shows> |", the pictures as code spans
// separated by commas; an item "<n>. <text>" at the start of a line.
site_demonstrations_read :: proc(content: string) -> (rows: []Site_Demonstration, removals: []Site_Demonstration_Removal, problem: string) {
	list := make([dynamic]Site_Demonstration, context.temp_allocator)
	removal_list := make([dynamic]Site_Demonstration_Removal, context.temp_allocator)
	section := ""
	for line, index in site_lines(content) {
		if strings.has_prefix(line, "## ") {
			section = line[3:]
			continue
		}
		switch {
		case section == "The table" && strings.has_prefix(line, "| "):
			cells := site_table_cells(line)
			number := len(cells) > 0 ? site_digits_value(cells[0]) : -1
			if number < 1 {
				continue // The head of the table and its line of dashes.
			}
			if len(cells) != 6 {
				return nil, nil, fmt.tprintf("%s, line %d: a row of the table has 6 cells: number, property, state, what the test shows, pictures, what no test shows", SITE_DEMONSTRATIONS_FILE, index + 1)
			}
			pictures := make([dynamic]string, context.temp_allocator)
			for part in strings.split(cells[4], ",", context.temp_allocator) {
				name := strings.trim(strings.trim_space(part), "`")
				if name != "" {
					append(&pictures, name)
				}
			}
			append(&list, Site_Demonstration{number = number, state = cells[2], shown = cells[3], pictures = pictures[:], missing = cells[5], line = index + 1})
		case strings.has_prefix(section, "What removes"):
			dot := strings.index(line, ". ")
			if dot > 0 && site_digits_value(line[:dot]) > 0 {
				append(&removal_list, Site_Demonstration_Removal{text = strings.trim_space(line[dot + 2:]), line = index + 1})
			}
		}
	}
	if len(list) == 0 {
		return nil, nil, SITE_DEMONSTRATIONS_FILE + ": the section \"## The table\" has no row \"| <n> | ...\""
	}
	return list[:], removal_list[:], ""
}

// site_property_numbers gives the properties that a text names. The rule:
// "property <n>" with no regard to case, or "P<n>" with a capital P, each a
// whole word; n from 1 to the count of the properties. "properties <n> and
// <m>" names none: the documents write one property at a time.
site_property_numbers :: proc(text: string, property_count: int) -> []int {
	numbers := make([dynamic]int, context.temp_allocator)
	lower := strings.to_lower(text, context.temp_allocator)
	for index in 0 ..< len(lower) {
		if index > 0 && site_is_word_byte(lower[index - 1]) {
			continue
		}
		start := -1
		if strings.has_prefix(lower[index:], "property ") {
			start = index + len("property ")
		} else if text[index] == 'P' {
			start = index + 1
		}
		if start < 0 {
			continue
		}
		end := start
		for end < len(lower) && lower[end] >= '0' && lower[end] <= '9' {
			end += 1
		}
		if end == start || (end < len(lower) && site_is_word_byte(lower[end])) {
			continue
		}
		number := site_digits_value(lower[start:end])
		if number >= 1 && number <= property_count && !slice.contains(numbers[:], number) {
			append(&numbers, number)
		}
	}
	return numbers[:]
}

// site_document_render renders a guide of docs/ again, only for its ids and
// its headings: the page of the guide has the same ids, because the
// renderer gives the same ids to the same text. What the renderer lists as
// not rendered is listed once, by the guide.
site_document_render :: proc(site: ^Site, source: string) -> (renderer: Site_Renderer, ok: bool) {
	content := site_read(source) or_return
	page, is_guide := site.documents[source]
	if !is_guide {
		page = SITE_PAGE
	}
	listed := len(site.not_rendered)
	// The spans of a document rendered again are counted by its own page.
	declaration_spans := site.declaration_spans
	renderer = site_renderer_make(site, page, source)
	site_render_markdown(&renderer, content)
	resize(&site.not_rendered, listed)
	site.declaration_spans = declaration_spans
	return renderer, true
}

site_status_add :: proc(site: ^Site) -> bool {
	path := site_section_page(.Status)
	properties := site.principles.properties
	principles := site_document_render(site, SITE_PROPERTIES_FILE) or_return
	properties_page := site.documents[SITE_PROPERTIES_FILE]

	demonstrations_text := site_read(SITE_DEMONSTRATIONS_FILE) or_return
	demonstrations, removals, demonstrations_problem := site_demonstrations_read(demonstrations_text)
	if demonstrations_problem != "" {
		fmt.eprintfln("modustool: site: %s", demonstrations_problem)
		return false
	}

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "<h1>Status</h1>\n<p>The state of the system in this build: each of the %d properties in the words of its document; then, for each property, what it promises, what the machine test shows today with its pictures, and what is not done.</p>\n", len(properties))
	strings.write_string(&b, "<p>A <strong>property</strong> is one fundamental rule of the system: what it does, and what it must never contain. Its <strong>status</strong> says whether the rule is decided. Its <strong>state</strong> says what a machine test shows of it: <em>Shown</em> when the test does the thing for real and checks the result, <em>Shown in part</em> when a named part has no test, <em>Not shown</em> when the system does not have the thing.</p>\n")

	// The properties.
	strings.write_string(&b, "<h2 id=\"properties\">Properties</h2>\n")
	properties_table := site_table_start(&b, "Properties", {{"Property", .Prose}, {"Status", .Short}}, {.None, .Status})
	for property in properties {
		heading_id := ""
		prefix := fmt.tprintf("%d. ", property.number)
		for heading in principles.headings {
			if heading.level == 2 && strings.has_prefix(heading.text, prefix) {
				heading_id = heading.id
				break
			}
		}
		fmt.sbprintf(&b, "<tr id=\"property-%d\" data-outline=\"%d. ", property.number, property.number)
		site_plain(&b, property.title)
		strings.write_string(&b, "\"><td>")
		if heading_id != "" {
			fmt.sbprintf(&b, "<a href=\"%s#%s\">", site_page_link(site, path, properties_page), heading_id)
		}
		fmt.sbprintf(&b, "%d. ", property.number)
		site_inline(&b, property.title)
		if heading_id != "" {
			strings.write_string(&b, "</a>")
		}
		strings.write_string(&b, "</td>")
		site_cell(&b, property.status)
		strings.write_string(&b, "</tr>\n")
	}
	site_table_end(&b, properties_table)
	strings.write_string(&b, "<p class=\"source\">The status is the column \"Status\" of the summary of the properties.</p>\n")
	site_source_line(site, &b, SITE_PROPERTIES_FILE)

	// Each property in prose: the promise from its first rule, then the
	// demonstration. The page states what is not done as plainly as what is.
	strings.write_string(&b, "<h2 id=\"each-property\">What each property promises, and what runs today</h2>\n")
	for property in properties {
		fmt.sbprintf(&b, "<section class=\"symbol\">\n<h3 id=\"state-%d\">%d. ", property.number, property.number)
		site_inline(&b, property.title)
		strings.write_string(&b, "</h3>\n<p><strong>What it promises.</strong> ")
		site_inline(&b, property.sentence)
		strings.write_string(&b, "</p>\n")
		found := false
		for row in demonstrations {
			if row.number != property.number {
				continue
			}
			found = true
			strings.write_string(&b, "<p><strong>Today: ")
			site_inline(&b, row.state)
			strings.write_string(&b, ".</strong> ")
			site_inline(&b, row.shown)
			strings.write_string(&b, "</p>\n")
			if len(row.pictures) > 0 {
				strings.write_string(&b, "<p><strong>Pictures of the test:</strong> ")
				for picture, index in row.pictures {
					if index > 0 {
						strings.write_string(&b, ", ")
					}
					strings.write_string(&b, "<a href=\"")
					site_escape(&b, site_repository_file(site, strings.concatenate({"docs/screenshots/", picture, ".png"}, context.temp_allocator)))
					strings.write_string(&b, "\"><code>")
					site_escape(&b, picture)
					strings.write_string(&b, "</code></a>")
				}
				strings.write_string(&b, "</p>\n")
			}
			strings.write_string(&b, "<p><strong>Not done.</strong> ")
			if strings.trim_space(row.missing) == "—" {
				strings.write_string(&b, "The demonstration names no part that a test does not show.")
			} else {
				site_inline(&b, row.missing)
			}
			strings.write_string(&b, "</p>\n")
			for removal in removals {
				if slice.contains(site_property_numbers(removal.text, len(properties)), property.number) {
					strings.write_string(&b, "<p><strong>What would complete it.</strong> ")
					site_inline(&b, removal.text)
					strings.write_string(&b, "</p>\n")
				}
			}
			fmt.sbprintf(&b, "<p class=\"source\"><a href=\"%s\">The row of the property</a> in the table of the demonstrations.</p>\n", site_line_address(site, SITE_DEMONSTRATIONS_FILE, row.line))
		}
		if !found {
			strings.write_string(&b, "<p class=\"missing\">No demonstration is recorded for this property.</p>\n")
		}
		strings.write_string(&b, "</section>\n")
	}
	site_source_line(site, &b, SITE_PROPERTIES_FILE, SITE_DEMONSTRATIONS_FILE)

	// The planned work is not on this page: it has its own, from its own file.
	strings.write_string(&b, "<h2 id=\"planned\">What is planned</h2>\n")
	site_roadmap_link_line(site, &b, path)

	site_page_add(site, Site_Page{path = path, title = "Status", description = site_description_cut(fmt.tprintf("The state of each of the %d properties of %s: what it promises, what the machine test shows of it, and what is not done.", len(properties), SITE_SYSTEM_NAME)), section = .Status, crumbs = site_crumbs(.Home), body = strings.to_string(b), sources = site_sources(SITE_PROPERTIES_FILE, SITE_DEMONSTRATIONS_FILE), layout = .Documentation})
	return true
}
