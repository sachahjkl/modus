#+feature dynamic-literals
package build

import "core:fmt"
import "core:strings"
import "core:testing"

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
		_, problems := glossary_read_of_texts(TEST_INDEX_OF_CODE, {{"code.md", test_code_file("A module.", item.explanation, "unit")}})
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
		glossary, problems := glossary_read_of_texts(TEST_INDEX_OF_CODE, {{"code.md", test_code_file(item.definition, item.explanation, item.avoided)}})
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
	code_path :: GLOSSARY_FOLDER + "/code.md"
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
		_, problems := glossary_read_of_texts(item.index, item.files)
		testing.expectf(t, len(problems) == 1 && strings.contains(problems[0], item.problem), "%s: %v", item.about, problems)
	}

	// Two groups of one slug would be one page: the reader refuses them.
	two_index := "# Glossary\n\n## The groups\n\n- [Code](code.md)\n- [Kode](kode.md)\n"
	_, slug_problems := glossary_read_of_texts(two_index, {{"code.md", code}, {"kode.md", code}})
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
