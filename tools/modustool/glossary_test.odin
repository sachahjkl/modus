#+feature dynamic-literals
package modustool

import "core:fmt"
import "core:strings"
import "core:testing"

// test_glossary_read reads a glossary of an index and files of groups, each
// a name in the folder of the glossary and a text.
@(private = "file")
test_glossary_read :: proc(index: string, files: [][2]string) -> (Glossary, []string) {
	list := make([]Glossary_File, len(files), context.temp_allocator)
	for file, place in files {
		list[place] = {path = strings.concatenate({GLOSSARY_FOLDER, "/", file[0]}, context.temp_allocator), content = file[1]}
	}
	return glossary_read(index, list)
}

// The index of a glossary of one group, Code.
@(private = "file")
TEST_INDEX_OF_CODE :: "# Glossary\n\nThe terms.\n\n## The groups\n\n- [Code](code.md)\n"

// test_words gives count words, "w1 w2 ...", with separator between them.
@(private = "file")
test_words :: proc(count: int, separator: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for place in 0 ..< count {
		if place > 0 {
			strings.write_string(&builder, separator)
		}
		fmt.sbprintf(&builder, "w%d", place + 1)
	}
	return strings.to_string(builder)
}

// test_code_file gives the file of the group Code with one term, Module:
// its definition, its explanation and its words to avoid ("" for none).
@(private = "file")
test_code_file :: proc(definition, explanation, avoided: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&builder, "## Code\n\n### Module\n\n%s\n", definition)
	if explanation != "" {
		fmt.sbprintf(&builder, "\n%s\n", explanation)
	}
	if avoided != "" {
		fmt.sbprintf(&builder, "\n%s%s.\n", GLOSSARY_AVOIDED_PREFIX, avoided)
	}
	return strings.to_string(builder)
}

// The count of the words of a text: the runs between spaces, tabs and ends
// of lines.
@(test)
glossary_word_count_counts_the_runs_between_spaces :: proc(t: ^testing.T) {
	cases := [?]struct {
		text:  string,
		count: int,
	} {
		{"", 0},
		{" ", 0},
		{"\n\t\r\n", 0},
		{"a", 1},
		{"  a  ", 1},
		{"a b", 2},
		{"  a  b\n\tc ", 3},
		{"`code` and **bold**: (docs/X.md, \"A\").", 5},
	}
	for item in cases {
		testing.expectf(t, glossary_word_count(item.text) == item.count, "%q: %d words", item.text, glossary_word_count(item.text))
	}
	testing.expect_value(t, glossary_word_count(test_words(GLOSSARY_EXPLANATION_WORD_LIMIT + 1, "\n\t ")), GLOSSARY_EXPLANATION_WORD_LIMIT + 1)
}

// An explanation of more than the bound of words is refused, with the term,
// its file, its line and its count; the bound itself, and the words of the
// definition and of the words to avoid, are not.
@(test)
glossary_read_refuses_an_explanation_over_its_bound :: proc(t: ^testing.T) {
	limit := GLOSSARY_EXPLANATION_WORD_LIMIT
	half := limit / 2
	refused := [?]struct {
		about:       string,
		explanation: string,
		count:       int,
	} {
		{"one past the bound", test_words(limit + 1, " "), limit + 1},
		{"one past the bound, on two paragraphs", strings.concatenate({test_words(half + 1, " "), "\n\n", test_words(limit - half, " ")}, context.temp_allocator), limit + 1},
		// A marker of a list is a word, as each run between spaces.
		{"past the bound, in a list", strings.concatenate({"- ", test_words(limit - 2, " "), "\n- one"}, context.temp_allocator), limit + 1},
		{"one past the bound, between tabs and ends of lines", test_words(limit + 1, "\t\n"), limit + 1},
		{"ten times the bound", test_words(limit * 10, " "), limit * 10},
	}
	for item in refused {
		_, problems := test_glossary_read(TEST_INDEX_OF_CODE, {{"code.md", test_code_file("A module.", item.explanation, "unit")}})
		expected := fmt.tprintf("%s/code.md, line 3: the explanation of the term \"Module\" has %d words; an explanation has at most %d", GLOSSARY_FOLDER, item.count, limit)
		testing.expectf(t, len(problems) == 1 && strings.contains(problems[0], expected), "%s: %v", item.about, problems)
	}

	// The definition and the words to avoid do not count.
	accepted := [?]struct {
		about:                            string,
		definition, explanation, avoided: string,
	} {
		{"no explanation", "A module.", "", ""},
		{"one word", "A module.", "One.", ""},
		{"the bound", "A module.", test_words(limit, " "), ""},
		{"the bound, on two paragraphs", "A module.", strings.concatenate({test_words(half, " "), "\n\n", test_words(limit - half, " ")}, context.temp_allocator), ""},
		{"the bound, a long definition and long words to avoid", test_words(limit * 2, " "), test_words(limit, " "), test_words(limit, ", ")},
	}
	for item in accepted {
		glossary, problems := test_glossary_read(TEST_INDEX_OF_CODE, {{"code.md", test_code_file(item.definition, item.explanation, item.avoided)}})
		testing.expectf(t, len(problems) == 0, "%s: %v", item.about, problems)
		terms := glossary_terms_in_order(glossary)
		testing.expectf(t, len(terms) == 1 && glossary_word_count(terms[0].explanation) == glossary_word_count(item.explanation), "%s: %v", item.about, terms)
	}
}

// Each fault of the form of the index or of a file of a group is refused,
// once, with its file and its line.
@(test)
glossary_read_refuses_what_has_not_the_form :: proc(t: ^testing.T) {
	code := "## Code\n\n### Module\n\nA module.\n"
	code_path := GLOSSARY_FOLDER + "/code.md"
	cases := [?]struct {
		about:   string,
		index:   string,
		files:   [][2]string,
		problem: string,
	} {
		// The files of the groups.
		{"a table of terms", TEST_INDEX_OF_CODE, {{"code.md", "## Code\n\n| Term | Definition | Do not use |\n|---|---|---|\n| Module | A module | unit |\n"}}, code_path + ", line 3: a table of terms"},
		{"no short definition", TEST_INDEX_OF_CODE, {{"code.md", "## Code\n\n### Module\n\n### Export\n\nA function.\n"}}, code_path + ", line 3: the term \"Module\" has no short definition"},
		{"a list first", TEST_INDEX_OF_CODE, {{"code.md", "## Code\n\n### Module\n\n- a list\n"}}, code_path + ", line 3: the term \"Module\" starts with no short definition"},
		{"the words to avoid not last", TEST_INDEX_OF_CODE, {{"code.md", "## Code\n\n### Module\n\nA module.\n\nDo not use: unit.\n\nMore text.\n"}}, code_path + ", line 7: the words that the term \"Module\" replaces are not the last paragraph"},
		{"a term before the group", TEST_INDEX_OF_CODE, {{"code.md", "### Module\n\nA module.\n"}}, code_path + ", line 1: the term \"Module\" comes before the heading of a group"},
		{"a heading of level 4", TEST_INDEX_OF_CODE, {{"code.md", "## Code\n\n### Module\n\nA module.\n\n#### Inside\n\nText.\n"}}, code_path + ", line 7: a heading of level 4"},
		{"a title of level 1 in a group", TEST_INDEX_OF_CODE, {{"code.md", "# Code\n\n### Module\n\nA module.\n"}}, code_path + ", line 1: a heading of level 1"},
		{"a second group in one file", TEST_INDEX_OF_CODE, {{"code.md", "## Code\n\n### Module\n\nA module.\n\n## More\n\n### Export\n\nA function.\n"}}, code_path + ", line 7: a second group \"More\""},
		{"a text before the group", TEST_INDEX_OF_CODE, {{"code.md", "Words.\n\n## Code\n\n### Module\n\nA module.\n"}}, code_path + ": the file does not start with the heading of its group"},
		{"an empty file", TEST_INDEX_OF_CODE, {{"code.md", ""}}, code_path + ": the file does not start with the heading of its group"},
		// The index and the set of the files.
		{"no title", "## The groups\n\n- [Code](code.md)\n", {{"code.md", code}}, GLOSSARY_INDEX_FILE + ": the file has no title"},
		{"a text before the title", "Words.\n\n# Glossary\n\n## The groups\n\n- [Code](code.md)\n", {{"code.md", code}}, GLOSSARY_INDEX_FILE + ": a text before the title"},
		{"no list", "# Glossary\n\nThe terms.\n", {}, GLOSSARY_INDEX_FILE + ": the index has no heading \"The groups\""},
		{"a line that is no link", "# Glossary\n\n## The groups\n\n- [Code](code.md)\n\nThe groups of the terms.\n", {{"code.md", code}}, GLOSSARY_INDEX_FILE + ", line 7: a line of the list of the groups"},
		{"a link to a folder", "# Glossary\n\n## The groups\n\n- [Code](groups/code.md)\n", {}, GLOSSARY_INDEX_FILE + ", line 5: a line of the list of the groups"},
		{"a link to no Markdown file", "# Glossary\n\n## The groups\n\n- [Code](code.txt)\n", {}, GLOSSARY_INDEX_FILE + ", line 5: a line of the list of the groups"},
		{"words after the link with no colon", "# Glossary\n\n## The groups\n\n- [Code](code.md) the modules\n", {}, GLOSSARY_INDEX_FILE + ", line 5: a line of the list of the groups"},
		{"an empty name", "# Glossary\n\n## The groups\n\n- [](code.md)\n", {}, GLOSSARY_INDEX_FILE + ", line 5: a line of the list of the groups"},
		{"a file that is not the slug of its group", "# Glossary\n\n## The groups\n\n- [Code](modules.md)\n", {}, GLOSSARY_INDEX_FILE + ", line 5: the group \"Code\" has the file docs/glossary/modules.md; its file is code.md"},
		{"a file named twice", "# Glossary\n\n## The groups\n\n- [Code](code.md)\n- [Code](code.md)\n", {{"code.md", code}}, GLOSSARY_INDEX_FILE + ", line 6: the list names docs/glossary/code.md a second time"},
		{"a listed file that is not there", TEST_INDEX_OF_CODE, {}, GLOSSARY_INDEX_FILE + ", line 7: the list names docs/glossary/code.md, and the folder has no such file"},
		{"a file that the list does not name", TEST_INDEX_OF_CODE, {{"code.md", code}, {"network.md", "## Network\n\n### Frame\n\nBytes.\n"}}, GLOSSARY_FOLDER + "/network.md: a file of the glossary that the list"},
		{"a heading that is not the name in the list", TEST_INDEX_OF_CODE, {{"code.md", "## Modules\n\n### Module\n\nA module.\n"}}, GLOSSARY_INDEX_FILE + ", line 7: the list names the group \"Code\", and the heading of docs/glossary/code.md is \"Modules\""},
		{"another heading in the index", "# Glossary\n\n## More\n\nText.\n\n## The groups\n\n- [Code](code.md)\n", {{"code.md", code}}, GLOSSARY_INDEX_FILE + ", line 3: the index has its title"},
	}
	for item in cases {
		_, problems := test_glossary_read(item.index, item.files)
		testing.expectf(t, len(problems) == 1 && strings.contains(problems[0], item.problem), "%s: %v", item.about, problems)
	}

	// Two groups of one slug would be one page: the reader refuses them.
	two_index := "# Glossary\n\n## The groups\n\n- [Code](code.md)\n- [Kode](kode.md)\n"
	_, slug_problems := test_glossary_read(two_index, {{"code.md", code}, {"kode.md", code}})
	slug_found := false
	for problem in slug_problems {
		slug_found ||= strings.contains(problem, "each group is a page")
	}
	testing.expectf(t, slug_found, "%v", slug_problems)

	// An index that cannot be read gives one problem and no group.
	unread, unread_problems := glossary_load(proc(path: string) -> (text: string, ok: bool) {return "", false})
	testing.expect_value(t, len(unread.groups), 0)
	testing.expectf(t, len(unread_problems) == 1 && strings.contains(unread_problems[0], GLOSSARY_INDEX_FILE), "%v", unread_problems)
}

@(private = "file")
TEST_GLOSSARY_INDEX :: `# Glossary

The terms.

## The groups

- [Code](code.md): the modules.
- [Running code](running_code.md)
`

@(private = "file")
TEST_GLOSSARY_CODE :: `## Code

### Module

The one format of compiled code.

A module metadata describes it.
A second line of the paragraph.

- a list of the explanation

Do not use: library, ` + "`DLL`" + `.

### Module metadata

The description of a module.

### Run

Bytes of text with one style.

Do not use: span.
`

@(private = "file")
TEST_GLOSSARY_RUNNING_CODE :: `## Running code

The text of the group.

### Run

Pages with one protection.

Each run is in a module.
`

// test_glossary gives the glossary of the tests, its files in the other
// order than the index: the index gives the order.
@(private = "file")
test_glossary :: proc() -> (Glossary, []string) {
	return test_glossary_read(TEST_GLOSSARY_INDEX, {{"running_code.md", TEST_GLOSSARY_RUNNING_CODE}, {"code.md", TEST_GLOSSARY_CODE}})
}

@(test)
glossary_read_gives_each_part_of_an_entry :: proc(t: ^testing.T) {
	glossary, problems := test_glossary()
	testing.expectf(t, len(problems) == 0, "%v", problems)
	testing.expect_value(t, glossary.title, "Glossary")
	testing.expect_value(t, glossary.introduction, "The terms.")
	testing.expect_value(t, glossary.introduction_line, 3)
	testing.expect_value(t, len(glossary.groups), 2)
	code := glossary.groups[0]
	testing.expect_value(t, code.name, "Code")
	testing.expect_value(t, code.id, "code")
	testing.expect_value(t, code.file, GLOSSARY_FOLDER + "/code.md")
	testing.expect_value(t, code.line, 1)
	testing.expect_value(t, len(code.terms), 3)
	module_term := code.terms[0]
	testing.expect_value(t, module_term.id, "term-module")
	testing.expect_value(t, module_term.group, "Code")
	testing.expect_value(t, module_term.file, GLOSSARY_FOLDER + "/code.md")
	testing.expect_value(t, module_term.line, 3)
	testing.expect_value(t, module_term.definition, "The one format of compiled code.")
	testing.expect_value(t, module_term.explanation, "A module metadata describes it.\nA second line of the paragraph.\n\n- a list of the explanation")
	testing.expect_value(t, module_term.explanation_line, 7)
	testing.expect_value(t, module_term.avoided, "library, `DLL`")
	// A term with no explanation and no words to avoid.
	testing.expect_value(t, code.terms[1].explanation, "")
	testing.expect_value(t, code.terms[1].avoided, "")
	// The group of the second file of the index, with its text and its
	// lines in its own file. A second term of one name, in another file,
	// has its own anchor.
	running := glossary.groups[1]
	testing.expect_value(t, running.name, "Running code")
	testing.expect_value(t, running.file, GLOSSARY_FOLDER + "/running_code.md")
	testing.expect_value(t, running.introduction, "The text of the group.")
	testing.expect_value(t, running.terms[0].line, 5)
	testing.expect_value(t, code.terms[2].id, "term-run")
	testing.expect_value(t, running.terms[0].id, "term-run-2")
	testing.expect_value(t, code.terms[2].avoided, "span")
	testing.expect_value(t, len(glossary_terms_in_order(glossary)), 4)
	// A page links a name of two entries to its first one.
	terms := site_glossary_terms(glossary)
	testing.expect_value(t, len(terms), 4)
	testing.expect_value(t, terms[0].name, "Module metadata")
	testing.expect_value(t, terms[2].id, "term-run")
	testing.expect(t, !terms[2].second_of_name && terms[3].second_of_name)
	// The name of the file of a group is the slug of its heading.
	testing.expect_value(t, glossary_group_file_name("Running code"), "running_code.md")
	testing.expect_value(t, glossary_group_file_name("Terms that the system does not have"), "terms_that_the_system_does_not_have.md")
	// The files of the folder, and no other path.
	for path in ([]string{GLOSSARY_INDEX_FILE, GLOSSARY_FOLDER + "/code.md"}) {
		testing.expectf(t, glossary_is_file(path), "%s", path)
	}
	for path in ([]string{"docs/GLOSSARY.md", GLOSSARY_FOLDER, GLOSSARY_FOLDER + "/", GLOSSARY_FOLDER + "/old/code.md", GLOSSARY_FOLDER + "/code.txt", "src/md/glossary/code.md"}) {
		testing.expectf(t, !glossary_is_file(path), "%s", path)
	}
}

@(test)
site_glossary_write_sets_the_definition_apart :: proc(t: ^testing.T) {
	site := test_site()
	glossary, _ := test_glossary()
	site.glossary = glossary
	site.terms = site_glossary_terms(glossary)
	code_page := site_glossary_group_page("code")
	renderer := site_renderer_make(&site, code_page, glossary.groups[0].file)
	renderer.glossary = true
	site_glossary_write(&renderer, glossary.groups[0])
	html := strings.to_string(renderer.builder)
	expect := [?]string {
		"<div class=\"term-entry\">\n<h2 id=\"term-module\">Module</h2>\n<p class=\"term-definition\">The one format of compiled code.</p>",
		// The explanation links another term of the group to its entry on the same page.
		"<p>A <a class=\"term\" href=\"#term-module-metadata\">module metadata</a> describes it. A second line of the paragraph.</p>",
		"<ul>\n<li>a list of the explanation</li>\n</ul>",
		"<p class=\"term-avoided\"><span class=\"term-avoided-label\">Do not use</span> library, <code>DLL</code></p>",
	}
	for part in expect {
		testing.expectf(t, strings.contains(html, part), "%q is not in %s", part, html)
	}
	// An entry links a term of another group to its entry on the page of
	// that group, never to the index.
	running := site_renderer_make(&site, site_glossary_group_page("running-code"), glossary.groups[1].file)
	running.glossary = true
	site_glossary_write(&running, glossary.groups[1])
	running_html := strings.to_string(running.builder)
	testing.expect(t, strings.contains(running_html, "<h2 id=\"term-run-2\">Run</h2>"), running_html)
	testing.expect(t, strings.contains(running_html, "in a <a class=\"term\" href=\"../../../../docs/reference/glossary/code/index.html#term-module\">module</a>."), running_html)
	// On another page, a link to a term names the page of its group and
	// has its short definition as its tooltip.
	guide := site_renderer_make(&site, "docs/guides/TEST/index.html", "docs/TEST.md")
	site_render_markdown(&guide, "A module here.\n")
	testing.expect(t, strings.contains(strings.to_string(guide.builder), "<a class=\"term\" href=\"../../../docs/reference/glossary/code/index.html#term-module\" title=\"The one format of compiled code.\">module</a>"), strings.to_string(guide.builder))
	// An entry never links its own term; the next entry links it.
	module_start := strings.index(html, "<h2 id=\"term-module\">")
	metadata_start := strings.index(html, "<h2 id=\"term-module-metadata\">")
	if !testing.expect(t, module_start >= 0 && metadata_start > module_start) {
		return
	}
	testing.expect(t, !strings.contains(html[module_start:metadata_start], "href=\"#term-module\""), html)
	testing.expect(t, strings.contains(html[metadata_start:], "of a <a class=\"term\" href=\"#term-module\">module</a>."), html)
}

// A glossary of three groups, with a name that two groups have and a name
// of two letters, which no page links but the index lists.
@(private = "file")
TEST_INDEX_OF_THREE_GROUPS :: `# Glossary

The terms.

## The groups

- [Network](network.md)
- [Desktop](desktop.md)
- [Terms that the system does not have](terms_that_the_system_does_not_have.md)
`

@(private = "file")
TEST_FILES_OF_THREE_GROUPS := [][2]string {
	{"network.md", "## Network\n\n### Frame\n\nThe bytes that a device sends at once.\n\n### IP\n\nThe protocol of the addresses.\n"},
	{"desktop.md", "## Desktop\n\n### Frame\n\nOne picture of a surface, made whole.\n\n### Window\n\nA surface that the desktop shows. Each window draws a frame.\n"},
	{"terms_that_the_system_does_not_have.md", "## Terms that the system does not have\n\nThese words name concepts that the system removed.\n"},
}

// The pages of the glossary: one page for each group with its entries, and
// an index with every term once, from A to Z, at the anchor of its entry.
@(test)
site_glossary_pages_split_by_group :: proc(t: ^testing.T) {
	site := test_site()
	glossary, problems := test_glossary_read(TEST_INDEX_OF_THREE_GROUPS, TEST_FILES_OF_THREE_GROUPS)
	testing.expectf(t, len(problems) == 0, "%v", problems)
	site.glossary = glossary
	site.terms = site_glossary_terms(glossary)
	site_glossary_documents_add(&site)
	entry := site_glossary_pages_add(&site)
	index_page := site_page_file(SITE_GLOSSARY_FOLDER)
	testing.expect_value(t, entry.path, index_page)
	testing.expect_value(t, entry.count, 4)
	written := make(map[string]string, context.temp_allocator)
	for page in site.pages {
		written[page.path] = page.body
	}
	// The index and one page for each group, a group with no term too.
	paths := site_glossary_page_paths(glossary)
	testing.expect_value(t, len(paths), 4)
	for path in paths {
		testing.expectf(t, path in written, "the page %s is not written", path)
	}
	testing.expect_value(t, paths[1], "docs/reference/glossary/network/index.html")
	testing.expect_value(t, paths[3], "docs/reference/glossary/terms-that-the-system-does-not-have/index.html")
	testing.expectf(t, len(site_glossary_problems(&site, written)) == 0, "%v", site_glossary_problems(&site, written))
	// Each file of the folder is the page of its group, and the index of
	// the folder is the index.
	testing.expect_value(t, site.documents[GLOSSARY_INDEX_FILE], index_page)
	testing.expect_value(t, site.documents[GLOSSARY_FOLDER + "/desktop.md"], site_glossary_group_page("desktop"))
	for page in site.pages {
		if page.path == index_page {
			testing.expect_value(t, page.sources[0], GLOSSARY_INDEX_FILE)
		} else if page.path == site_glossary_group_page("network") {
			testing.expect_value(t, page.sources[0], GLOSSARY_FOLDER + "/network.md")
		}
	}

	// Each term resolves to the page of its group: a link of a page, a link
	// of a comment, a result of the search and a reference to a document.
	network_page := site_glossary_group_page("network")
	desktop_page := site_glossary_group_page("desktop")
	expected_pages := map[string]string {
		"term-frame"   = network_page,
		"term-ip"      = network_page,
		"term-frame-2" = desktop_page,
		"term-window"  = desktop_page,
	}
	defer delete(expected_pages)
	for term in glossary_terms_in_order(glossary) {
		testing.expectf(t, site_glossary_anchor_page(&site, term.id) == expected_pages[term.id], "%s is on %s", term.id, site_glossary_anchor_page(&site, term.id))
	}
	for term in site.terms {
		testing.expectf(t, term.page == expected_pages[term.id], "the term %s names the page %s", term.id, term.page)
	}
	link, link_problem := site_comment_link_target(&site, "term:window")
	testing.expect(t, link_problem == "" && link.address == strings.concatenate({desktop_page, "#term-window"}, context.temp_allocator), link_problem)
	for entry_of_search in site_search_entries(&site) {
		if entry_of_search.kind == .Term {
			testing.expectf(t, entry_of_search.page != index_page, "the search sends %s to the index", entry_of_search.title)
		}
	}
	// A link of a comment to an id of the file of a group names the page of
	// the group; an id of another group, or of no group, names nothing.
	file_link, file_link_problem := site_comment_link_target(&site, GLOSSARY_FOLDER + "/desktop.md#term-frame-2")
	testing.expect(t, file_link_problem == "" && file_link.address == strings.concatenate({desktop_page, "#term-frame-2"}, context.temp_allocator), file_link_problem)
	for wrong in ([]string{GLOSSARY_FOLDER + "/desktop.md#term-frame", GLOSSARY_FOLDER + "/desktop.md#term-nothing", GLOSSARY_INDEX_FILE + "#term-window", GLOSSARY_FOLDER + "/absent.md#term-window"}) {
		_, wrong_problem := site_comment_link_target(&site, wrong)
		testing.expectf(t, wrong_problem != "", "%s names a place", wrong)
	}
	// A reference names a term of the file of its group, never of another
	// file.
	references := site_document_targets(&site, GLOSSARY_FOLDER + "/desktop.md", {"\"Window\""})
	testing.expect(t, len(references) == 1 && references[0].resolved && references[0].link == strings.concatenate({desktop_page, "#term-window"}, context.temp_allocator), fmt.tprintf("%v", references))
	group_reference := site_document_targets(&site, GLOSSARY_FOLDER + "/desktop.md", {"\"Desktop\""})
	testing.expect(t, len(group_reference) == 1 && group_reference[0].resolved, fmt.tprintf("%v", group_reference))
	for wrong in ([]string{"\"IP\"", "\"Network\"", "\"Nothing\""}) {
		wrong_reference := site_document_targets(&site, GLOSSARY_FOLDER + "/desktop.md", {wrong})
		testing.expectf(t, len(wrong_reference) == 1 && !wrong_reference[0].resolved, "%s: %v", wrong, wrong_reference)
	}
	index_reference := site_document_targets(&site, GLOSSARY_INDEX_FILE, {"\"Window\""})
	testing.expect(t, len(index_reference) == 1 && !index_reference[0].resolved, fmt.tprintf("%v", index_reference))

	// The two terms of one name keep their two anchors, each on the page
	// of its group, and both are rows of the index.
	index_html := written[index_page]
	testing.expect_value(t, strings.count(written[network_page], " id=\"term-frame\""), 1)
	testing.expect_value(t, strings.count(written[desktop_page], " id=\"term-frame-2\""), 1)
	testing.expect_value(t, strings.count(written[desktop_page], " id=\"term-frame\""), 0)
	testing.expect(t, strings.contains(index_html, "<div id=\"term-frame\" data-group-page=\"../../../docs/reference/glossary/network/index.html\">"), index_html)
	testing.expect(t, strings.contains(index_html, "<div id=\"term-frame-2\" data-group-page=\"../../../docs/reference/glossary/desktop/index.html\">"), index_html)
	// The index lists every term once, the short names too, from A to Z,
	// each with its group as a label.
	testing.expect_value(t, strings.count(index_html, "<div id=\"term-"), 4)
	frame := strings.index(index_html, "<div id=\"term-frame\"")
	ip := strings.index(index_html, "<div id=\"term-ip\"")
	window := strings.index(index_html, "<div id=\"term-window\"")
	testing.expect(t, frame >= 0 && frame < ip && ip < window, index_html)
	testing.expect(t, strings.contains(index_html, "<h3 id=\"letter-f\">F</h3>"), index_html)
	testing.expect(t, strings.contains(index_html, "<span class=\"glossary-index-group\">Desktop</span>"), index_html)
	// No definition of the index links a term: a link to a term never
	// names the index.
	testing.expect(t, !strings.contains(index_html, "class=\"term\""), index_html)
	// The groups with their counts.
	testing.expect(t, strings.contains(index_html, "<a href=\"../../../docs/reference/glossary/network/index.html\">Network</a> <span class=\"glossary-count\">2 terms</span>"), index_html)
	testing.expect(t, strings.contains(index_html, "<span class=\"glossary-count\">no term</span>"), index_html)
	// An entry of a group links the term of another group on its page.
	testing.expect(t, strings.contains(written[desktop_page], "draws a <a class=\"term\" href=\"../../../../docs/reference/glossary/network/index.html#term-frame\">frame</a>."), written[desktop_page])
	// The index has its script; a page of a group has none.
	for page in site.pages {
		testing.expect_value(t, page.script, page.path == index_page ? SITE_GLOSSARY_SCRIPT : "")
	}

	// The check finds an index row that is missing, a row twice, a row
	// that names another page and an entry that is missing.
	missing_row, _ := strings.replace_all(index_html, " id=\"term-window\"", "", context.temp_allocator)
	twice := strings.concatenate({index_html, "<div id=\"term-ip\"></div>"}, context.temp_allocator)
	wrong_page, _ := strings.replace_all(index_html, "<div id=\"term-window\" data-group-page=\"../../../docs/reference/glossary/desktop/index.html\">", "<div id=\"term-window\" data-group-page=\"../../../docs/reference/glossary/network/index.html\">", context.temp_allocator)
	for broken_index in ([]string{missing_row, twice, wrong_page}) {
		broken := make(map[string]string, context.temp_allocator)
		for path, html in written {
			broken[path] = html
		}
		broken[index_page] = broken_index
		testing.expect(t, len(site_glossary_problems(&site, broken)) > 0)
	}
	no_entry := make(map[string]string, context.temp_allocator)
	for path, html in written {
		no_entry[path] = html
	}
	desktop_without_entry, _ := strings.replace_all(written[desktop_page], " id=\"term-window\"", "", context.temp_allocator)
	no_entry[desktop_page] = desktop_without_entry
	testing.expect(t, len(site_glossary_problems(&site, no_entry)) > 0)
	// A page above the bound fails the check.
	too_large := make(map[string]string, context.temp_allocator)
	for path, html in written {
		too_large[path] = html
	}
	filler := strings.repeat("x", SITE_GLOSSARY_PAGE_BYTE_LIMIT, context.temp_allocator)
	too_large[network_page] = strings.concatenate({written[network_page], filler}, context.temp_allocator)
	testing.expect(t, len(site_glossary_problems(&site, too_large)) > 0)
}

// The script of the index: it reads the anchor of a term, finds its row and
// goes to the page that the row names, with the same anchor.
@(test)
site_glossary_script_follows_the_row :: proc(t: ^testing.T) {
	script := site_glossary_script()
	testing.expect(t, strings.contains(script, "getAttribute(\"" + SITE_GLOSSARY_GROUP_PAGE_ATTRIBUTE + "\")"))
	testing.expect(t, strings.contains(script, "\"#term-\""))
	testing.expect(t, strings.contains(script, "location.replace(page + hash)"))
	testing.expect(t, strings.contains(script, "hashchange"))
}

// Every page of the glossary of the repository, with its frame, has at
// most SITE_GLOSSARY_PAGE_BYTE_LIMIT bytes, and each term has its row at
// the index and its entry on the page of its group.
@(test)
site_glossary_pages_of_the_repository :: proc(t: ^testing.T) {
	site := test_site()
	glossary, problems, read_ok := glossary_read_folder()
	testing.expect(t, read_ok)
	testing.expectf(t, len(problems) == 0, "%v", problems)
	site.glossary = glossary
	site.terms = site_glossary_terms(glossary)
	site_glossary_documents_add(&site)
	testing.expect(t, site_reference_read(&site))
	testing.expect(t, site_declarations_read(&site))
	site_glossary_pages_add(&site)
	written := make(map[string]string, context.temp_allocator)
	for page in site.pages {
		written[page.path] = site_page_html(&site, page)
	}
	glossary_problems := site_glossary_problems(&site, written)
	testing.expectf(t, len(glossary_problems) == 0, "%d problems: %v", len(glossary_problems), glossary_problems)
	for path in site_glossary_page_paths(glossary) {
		testing.expectf(t, len(written[path]) <= SITE_GLOSSARY_PAGE_BYTE_LIMIT, "%s has %d bytes", path, len(written[path]))
	}
	// A term of each group resolves to the page of its group.
	for group in glossary.groups {
		if len(group.terms) == 0 {
			continue
		}
		term := group.terms[0]
		testing.expect_value(t, site_glossary_anchor_page(&site, term.id), site_glossary_group_page(group.id))
	}
}

// The glossary of the repository: each file of the folder is a group of the
// index, each term has its form and an explanation within its bound.
@(test)
glossary_of_the_repository_has_its_form :: proc(t: ^testing.T) {
	glossary, problems, read_ok := glossary_read_folder()
	testing.expect(t, read_ok)
	testing.expectf(t, len(problems) == 0, "%v", problems)
	testing.expect(t, len(glossary.groups) > 10)
	testing.expect(t, len(glossary_terms_in_order(glossary)) > 400)
	for group in glossary.groups {
		testing.expect_value(t, group.file, strings.concatenate({GLOSSARY_FOLDER, "/", glossary_group_file_name(group.name)}, context.temp_allocator))
	}
}
