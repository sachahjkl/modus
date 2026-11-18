package modustool

import "core:os"
import "core:strings"
import "core:testing"
import "modustool:foundation"

@(private = "file")
SMALL_README :: "<p align=\"center\"><img src=\"resources/logo/modus_transparent.png\" width=\"256\" alt=\"The mark\"></p>\n\n# Title\n\nThe lead.\nIts second line.\n\n![A <b>bold</b> & \"quoted\" caption](docs/screenshots/x.png)\n\n| | |\n|---|---|\n| ![Left](docs/screenshots/left.png) | ![Right](docs/screenshots/right.png) |\n\n## Use\n\nThe flake.\n\n## Licences\n\nMIT.\n"

@(private = "file")
SMALL_PROPERTIES :: `# Properties

## Objective

Build a thing.

Three rules:

1. **One.** First rule.
2. **Two.** Second rule.

## Summary

| # | Property | Status |
|---|---|---|
| 1 | One | Decided |
| 2 | Two | Proposed |

## 1. One

Status: Decided.

- **Why**: A reason.
- **Rule**: The first rule. More text.

## 2. Two

Status: Proposed.

| A | B |
|---|---|
| x | y |
| z | w |

### A part

- **Rule** (a note): The rule of the part.

## Tensions

- Not a property.
`

@(test)
site_escapes_a_caption :: proc(t: ^testing.T) {
	readme, problem := site_readme_parse(SMALL_README)
	testing.expect_value(t, problem, "")
	caption := readme.captions["docs/screenshots/x.png"]
	testing.expect_value(t, caption, "A <b>bold</b> & \"quoted\" caption")
	testing.expect_value(t, site_inline_text(caption), "A &lt;b&gt;bold&lt;/b&gt; &amp; &quot;quoted&quot; caption")
	builder := strings.builder_make(context.temp_allocator)
	site_plain(&builder, "`a<b` **c&d** 'e'")
	testing.expect_value(t, strings.to_string(builder), "a&lt;b c&amp;d &#39;e&#39;")
	testing.expect_value(t, site_inline_text("x `<y>` **z** [w](v.md) [Blow §2] `open"), "x <code>&lt;y&gt;</code> <strong>z</strong> w [Blow §2] `open")
	testing.expect_value(t, site_inline_text("**not closed"), "<strong>not closed</strong>")
}

@(test)
site_properties_of_the_repository :: proc(t: ^testing.T) {
	data, err := os.read_entire_file(SITE_PROPERTIES_FILE, context.temp_allocator)
	testing.expect(t, err == nil, "cannot read docs/PROPERTIES.md")
	principles, problem := site_properties_parse(string(data))
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(principles.properties), 21)
	testing.expect_value(t, len(principles.rules), 3)
	testing.expect(t, strings.has_prefix(principles.objective, "Build a kernel"))
	for property, index in principles.properties {
		testing.expect_value(t, property.number, index + 1)
		testing.expectf(t, property.title != "" && property.status != "", "the property %d has no title or no status", property.number)
		testing.expectf(t, strings.has_suffix(property.sentence, "."), "the sentence of the property %d does not end with a period: %s", property.number, property.sentence)
	}
	if len(principles.properties) != 21 {
		return
	}
	testing.expect(t, strings.has_prefix(principles.properties[0].sentence, "The kernel does four things"))
	testing.expect_value(t, principles.properties[0].status, "Decided")
	testing.expect(t, len(principles.properties[8].parts) == 1 && strings.has_prefix(principles.properties[8].parts[0].title, "Persistence"))
	testing.expect(t, len(principles.properties[12].parts) == 1 && strings.has_prefix(principles.properties[12].parts[0].sentence, "A record that is all zero bytes"))
	testing.expect(t, strings.has_prefix(principles.properties[14].sentence, "A process can contain several protection domains"))
	testing.expect(t, strings.contains(principles.properties[15].sentence, "Many concepts of current systems have no place here"))
	testing.expect(t, strings.contains(principles.properties[19].sentence, "Nothing is open to a process just because it runs"))
}

@(test)
site_properties_of_a_small_file :: proc(t: ^testing.T) {
	principles, problem := site_properties_parse(SMALL_PROPERTIES)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, principles.objective, "Build a thing.")
	testing.expect_value(t, len(principles.rules), 2)
	testing.expect_value(t, len(principles.properties), 2)
	if len(principles.properties) != 2 {
		return
	}
	testing.expect_value(t, principles.properties[0].sentence, "The first rule.")
	testing.expect_value(t, principles.properties[1].status, "Proposed")
	testing.expect_value(t, principles.properties[1].sentence, "x, z.")
	testing.expect_value(t, len(principles.properties[1].parts), 1)
	if len(principles.properties[1].parts) == 1 {
		testing.expect_value(t, principles.properties[1].parts[0].title, "A part")
		testing.expect_value(t, principles.properties[1].parts[0].sentence, "The rule of the part.")
	}
}

@(test)
site_properties_of_a_damaged_file :: proc(t: ^testing.T) {
	Damage :: struct {
		before, after: string,
	}
	damages := []Damage {
		{"## Objective", "## Goal"},
		{"1. **One.** First rule.\n2. **Two.** Second rule.", "No rule."},
		{"| # | Property | Status |", "| Number | Property | Status |"},
		{"| 2 | Two | Proposed |\n", ""},
		{"| 2 | Two | Proposed |", "| 3 | Two | Proposed |"},
		{"## 2. Two", "## 3. Two"},
		{"- **Why**: A reason.\n- **Rule**: The first rule. More text.", ""},
		{"- **Rule** (a note): The rule of the part.", ""},
		{"## 1. One", "## 1. "},
	}
	for damage in damages {
		damaged, changed := strings.replace_all(SMALL_PROPERTIES, damage.before, damage.after, context.temp_allocator)
		testing.expectf(t, changed, "the text %q is not in the small file", damage.before)
		_, problem := site_properties_parse(damaged)
		testing.expectf(t, problem != "", "no problem found after %q became %q", damage.before, damage.after)
	}
	_, empty_problem := site_properties_parse("")
	testing.expect(t, empty_problem != "")
}

@(test)
site_readme_of_the_repository :: proc(t: ^testing.T) {
	data, err := os.read_entire_file(SITE_README_FILE, context.temp_allocator)
	testing.expect(t, err == nil, "cannot read README.md")
	readme, problem := site_readme_parse(string(data))
	testing.expect_value(t, problem, "")
	testing.expect(t, strings.has_prefix(readme.lead, "A fast, modular operating system, sandboxed by default."))
	testing.expect(t, readme.mark_description != "")
	testing.expect(t, readme.use_paragraph != "")
	testing.expect(t, len(readme.licence_paragraphs) > 0)
}

@(test)
site_readme_of_a_small_file :: proc(t: ^testing.T) {
	readme, problem := site_readme_parse(SMALL_README)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, readme.lead, "The lead. Its second line.")
	testing.expect_value(t, readme.mark_description, "The mark")
	testing.expect_value(t, readme.captions["docs/screenshots/left.png"], "Left")
	testing.expect_value(t, readme.captions["docs/screenshots/right.png"], "Right")
	testing.expect_value(t, readme.use_paragraph, "The flake.")
	Damage :: struct {
		before, after: string,
	}
	damages := []Damage {
		{"# Title", "Title"},
		{"(docs/screenshots/right.png)", "(docs/screenshots/right.png"},
		{"![Left](", "![Left]"},
		{"![Left]", "![]"},
		{"alt=\"The mark\"", "title=\"The mark\""},
		{"## Use", "## Using"},
		{"## Licences", "## Licenses"},
	}
	for damage in damages {
		damaged, changed := strings.replace_all(SMALL_README, damage.before, damage.after, context.temp_allocator)
		testing.expectf(t, changed, "the text %q is not in the small file", damage.before)
		_, damaged_problem := site_readme_parse(damaged)
		testing.expectf(t, damaged_problem != "", "no problem found after %q became %q", damage.before, damage.after)
	}
}

@(test)
site_first_sentences :: proc(t: ^testing.T) {
	testing.expect_value(t, site_first_sentence("  One. Two."), "One.")
	testing.expect_value(t, site_first_sentence("The concept of \"who executes\". The answer."), "The concept of \"who executes\".")
	testing.expect_value(t, site_first_sentence("Version 0.5 is here"), "Version 0.5 is here")
	testing.expect_value(t, site_first_sentence(""), "")
}

@(test)
site_lines_of_a_log :: proc(t: ^testing.T) {
	log := "[a] a: one 1\r\n[b:channel] b: frame 2 us\n[b] b: frame 3 us\nplain frame 4 us\n"
	text, line_number, count := site_line_choose(log, "frame", .Last)
	testing.expect_value(t, text, "plain frame 4 us")
	testing.expect_value(t, line_number, 4)
	testing.expect_value(t, count, 3)
	text, line_number, count = site_line_choose(log, "frame", .First)
	testing.expect_value(t, text, "b: frame 2 us")
	testing.expect_value(t, line_number, 2)
	testing.expect_value(t, count, 3)
	_, _, count = site_line_choose(log, "absent", .First)
	testing.expect_value(t, count, 0)
	absent := site_measure_read(Site_Measure{sentence = "absent", files = {foundation.BUILD_FOLDER + "/no_log_of_the_site_test.txt", ""}, pattern = "x"})
	testing.expect(t, !absent.found)
	testing.expect(t, strings.contains(absent.missing, "no file"))
}

// The head of the home holds the tagline, the first sentence of the lead of
// README.md, and not the rest; the rest is once in the page, lower.
@(test)
site_tagline_of_the_home :: proc(t: ^testing.T) {
	readme, problem := site_readme_parse(SMALL_README)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, readme.tagline, "The lead.")
	testing.expect_value(t, readme.explanation, "Its second line.")

	site := test_site()
	site.readme = readme
	head := strings.builder_make(context.temp_allocator)
	site_home_head(&site, &head)
	head_html := strings.to_string(head)
	testing.expect(t, strings.contains(head_html, "<p class=\"lead\">The lead.</p>"))
	// The picture is the heron alone, and the title is the name as text in
	// the font of the name of the mark.
	testing.expect(t, strings.contains(head_html, "width=\"192\" height=\"192\" alt=\"The mark\">"))
	testing.expect(t, strings.contains(head_html, "<h1><span class=\"mark-name\">" + SITE_SYSTEM_NAME + "</span></h1>"))
	testing.expect(t, !strings.contains(head_html, "Its second line."))
	page := strings.builder_make(context.temp_allocator)
	site_home_head(&site, &page)
	site_home_explanation(&site, &page)
	page_html := strings.to_string(page)
	testing.expect_value(t, strings.count(page_html, "Its second line."), 1)
	testing.expect(t, strings.index(page_html, "Its second line.") > strings.index(page_html, "</header>"))

	// A lead of one sentence has no explanation and no section for it.
	one_sentence, _ := strings.replace(SMALL_README, "The lead.\nIts second line.", "The lead.", 1, context.temp_allocator)
	short, short_problem := site_readme_parse(one_sentence)
	testing.expect_value(t, short_problem, "")
	testing.expect_value(t, short.tagline, "The lead.")
	testing.expect_value(t, short.explanation, "")
	site.readme = short
	empty := strings.builder_make(context.temp_allocator)
	site_home_explanation(&site, &empty)
	testing.expect_value(t, strings.to_string(empty), "")

	// The README of the repository: a tagline of one sentence, and the rest.
	if data, err := os.read_entire_file(SITE_README_FILE, context.temp_allocator); err == nil {
		repository, _ := site_readme_parse(string(data))
		testing.expect(t, strings.has_suffix(repository.tagline, "."))
		testing.expect(t, !strings.contains(repository.tagline, ". "))
		testing.expect(t, repository.explanation != "")
		testing.expect_value(t, strings.concatenate({repository.tagline, " ", repository.explanation}, context.temp_allocator), repository.lead)
	}
}
