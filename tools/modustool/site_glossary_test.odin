#+feature dynamic-literals
package modustool

import "core:fmt"
import "core:strings"
import "core:testing"
import "modustool:build"

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
test_glossary :: proc() -> (build.Glossary, []string) {
	return build.glossary_read_of_texts(TEST_GLOSSARY_INDEX, {{"running_code.md", TEST_GLOSSARY_RUNNING_CODE}, {"code.md", TEST_GLOSSARY_CODE}})
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
	testing.expect_value(t, code.file, build.GLOSSARY_FOLDER + "/code.md")
	testing.expect_value(t, code.line, 1)
	testing.expect_value(t, len(code.terms), 3)
	module_term := code.terms[0]
	testing.expect_value(t, module_term.id, "term-module")
	testing.expect_value(t, module_term.group, "Code")
	testing.expect_value(t, module_term.file, build.GLOSSARY_FOLDER + "/code.md")
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
	testing.expect_value(t, running.file, build.GLOSSARY_FOLDER + "/running_code.md")
	testing.expect_value(t, running.introduction, "The text of the group.")
	testing.expect_value(t, running.terms[0].line, 5)
	testing.expect_value(t, code.terms[2].id, "term-run")
	testing.expect_value(t, running.terms[0].id, "term-run-2")
	testing.expect_value(t, code.terms[2].avoided, "span")
	testing.expect_value(t, len(build.glossary_terms_in_order(glossary)), 4)
	// A page links a name of two entries to its first one.
	terms := site_glossary_terms(glossary)
	testing.expect_value(t, len(terms), 4)
	testing.expect_value(t, terms[0].name, "Module metadata")
	testing.expect_value(t, terms[2].id, "term-run")
	testing.expect(t, !terms[2].second_of_name && terms[3].second_of_name)
	// The name of the file of a group is the slug of its heading.
	testing.expect_value(t, build.glossary_group_file_name("Running code"), "running_code.md")
	testing.expect_value(t, build.glossary_group_file_name("Terms that the system does not have"), "terms_that_the_system_does_not_have.md")
	// The files of the folder, and no other path.
	for path in ([]string{build.GLOSSARY_INDEX_FILE, build.GLOSSARY_FOLDER + "/code.md"}) {
		testing.expectf(t, build.glossary_is_file(path), "%s", path)
	}
	for path in ([]string{"docs/GLOSSARY.md", build.GLOSSARY_FOLDER, build.GLOSSARY_FOLDER + "/", build.GLOSSARY_FOLDER + "/old/code.md", build.GLOSSARY_FOLDER + "/code.txt", "src/md/glossary/code.md"}) {
		testing.expectf(t, !build.glossary_is_file(path), "%s", path)
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
	glossary, problems := build.glossary_read_of_texts(TEST_INDEX_OF_THREE_GROUPS, TEST_FILES_OF_THREE_GROUPS)
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
	testing.expect_value(t, site.documents[build.GLOSSARY_INDEX_FILE], index_page)
	testing.expect_value(t, site.documents[build.GLOSSARY_FOLDER + "/desktop.md"], site_glossary_group_page("desktop"))
	for page in site.pages {
		if page.path == index_page {
			testing.expect_value(t, page.sources[0], build.GLOSSARY_INDEX_FILE)
		} else if page.path == site_glossary_group_page("network") {
			testing.expect_value(t, page.sources[0], build.GLOSSARY_FOLDER + "/network.md")
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
	for term in build.glossary_terms_in_order(glossary) {
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
	file_link, file_link_problem := site_comment_link_target(&site, build.GLOSSARY_FOLDER + "/desktop.md#term-frame-2")
	testing.expect(t, file_link_problem == "" && file_link.address == strings.concatenate({desktop_page, "#term-frame-2"}, context.temp_allocator), file_link_problem)
	for wrong in ([]string{build.GLOSSARY_FOLDER + "/desktop.md#term-frame", build.GLOSSARY_FOLDER + "/desktop.md#term-nothing", build.GLOSSARY_INDEX_FILE + "#term-window", build.GLOSSARY_FOLDER + "/absent.md#term-window"}) {
		_, wrong_problem := site_comment_link_target(&site, wrong)
		testing.expectf(t, wrong_problem != "", "%s names a place", wrong)
	}
	// A reference names a term of the file of its group, never of another
	// file.
	references := site_document_targets(&site, build.GLOSSARY_FOLDER + "/desktop.md", {"\"Window\""})
	testing.expect(t, len(references) == 1 && references[0].resolved && references[0].link == strings.concatenate({desktop_page, "#term-window"}, context.temp_allocator), fmt.tprintf("%v", references))
	group_reference := site_document_targets(&site, build.GLOSSARY_FOLDER + "/desktop.md", {"\"Desktop\""})
	testing.expect(t, len(group_reference) == 1 && group_reference[0].resolved, fmt.tprintf("%v", group_reference))
	for wrong in ([]string{"\"IP\"", "\"Network\"", "\"Nothing\""}) {
		wrong_reference := site_document_targets(&site, build.GLOSSARY_FOLDER + "/desktop.md", {wrong})
		testing.expectf(t, len(wrong_reference) == 1 && !wrong_reference[0].resolved, "%s: %v", wrong, wrong_reference)
	}
	index_reference := site_document_targets(&site, build.GLOSSARY_INDEX_FILE, {"\"Window\""})
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
	glossary, problems, read_ok := build.glossary_read_folder()
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
