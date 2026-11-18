// The pointers of an intent file to a guide, checked against the pages of
// the site: the check of the intent folder reads the files, the site knows
// each heading of each guide.
package site

import "core:fmt"
import "core:strings"
import "modustool:checks"

// intent_pointer_problems checks each link of an intent file to a guide
// that has the heading of a place after it:
// [`docs/CONSOLE.md`](../../docs/CONSOLE.md), "8. The palette provider".
// The link opens the guide for a reader of the repository; the labels are
// those of a pointer of a source comment, and they find their heading by
// the same rule. A link with no label names the guide alone.
intent_pointer_problems :: proc(site: ^Site, file: checks.Intent_File) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	from := strings.concatenate({checks.INTENT_PREFIX, file.path}, context.temp_allocator)
	for link in checks.intent_links(file.content) {
		labels, _ := checks.site_pointer_labels(link.text, link.after)
		if len(labels) == 0 {
			continue
		}
		path, inside_repository := checks.intent_link_path(from, link.target)
		is_document := false
		if inside_repository {
			document_end, has_document_form := checks.site_document_path_end(path, 0)
			is_document = has_document_form && document_end == len(path)
		}
		if !is_document {
			// A Markdown file that is not a document, with the heading of
			// a place after it, is most often a link with a wrong count of
			// "..": it must not pass as a link that nobody checks.
			if strings.has_suffix(link.target, ".md") {
				append(&problems, fmt.tprintf("%s, line %d: the link to %s has the heading of a place after it, %s, and names no document of docs/ and no intent file", from, link.line, link.target, strings.join(labels, ", ", context.temp_allocator)))
			}
			continue
		}
		if problem := site_pointer_problem(site, from, link.line, path, labels); problem != "" {
			append(&problems, problem)
		}
	}
	return problems[:]
}
