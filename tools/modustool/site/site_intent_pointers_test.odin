package site

import "core:strings"
import "core:testing"
import "modustool:checks"

// A link of an intent file to a guide, with the heading of a place after
// it, is a pointer: a heading that the guide does not have is a fault, a
// heading that it has is none, and a link with no label is not read. A
// file of a folder of the intent is three folders under the root.
@(test)
intent_pointers_to_a_guide :: proc(t: ^testing.T) {
	site := reference_test_site()
	good := checks.Intent_File {
		path    = "features/kernel.md",
		content = "# The kernel\n\nSee [`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), \"Kernel systems\".\nAnd [the guide](../../../docs/ARCHITECTURE.md) alone.\nAnd [the guide](../../../docs/ARCHITECTURE.md), which has no heading after it.\n",
	}
	testing.expectf(t, len(intent_pointer_problems(&site, good)) == 0, "%v", intent_pointer_problems(&site, good))
	// The entry point is two folders under the root.
	from_the_entry_point := checks.Intent_File {
		path    = "README.md",
		content = "# The intent\n\nSee [`docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md), \"Kernel systems\".\n",
	}
	testing.expectf(t, len(intent_pointer_problems(&site, from_the_entry_point)) == 0, "%v", intent_pointer_problems(&site, from_the_entry_point))
	stale := checks.Intent_File {
		path    = "features/kernel.md",
		content = "# The kernel\n\nText.\n\nSee [`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), \"No such heading\".\n",
	}
	problems := intent_pointer_problems(&site, stale)
	testing.expectf(t, len(problems) == 1, "%v", problems)
	if len(problems) == 1 {
		testing.expect(t, strings.has_prefix(problems[0], "src/md/features/kernel.md, line 5: "), problems[0])
		testing.expect(t, strings.contains(problems[0], "names no heading"), problems[0])
	}
	// Two pointers on one line: each has its own labels, and only the
	// stale one is a fault.
	two := checks.Intent_File {
		path    = "features/kernel.md",
		content = "# The kernel\n\nSee [`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), \"Kernel systems\"; [`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), \"No such heading\".\n",
	}
	two_problems := intent_pointer_problems(&site, two)
	testing.expectf(t, len(two_problems) == 1, "%v", two_problems)
	if len(two_problems) == 1 {
		testing.expect(t, strings.has_prefix(two_problems[0], "src/md/features/kernel.md, line 3: "), two_problems[0])
		testing.expect(t, strings.contains(two_problems[0], "No such heading") && !strings.contains(two_problems[0], "Kernel systems"), two_problems[0])
	}
	// A link with a wrong count of "..": the path that it names is not a
	// document, so the heading after it cannot be checked. It is a fault,
	// not a link that passes unread.
	wrong_depth := checks.Intent_File {
		path    = "features/kernel.md",
		content = "# The kernel\n\nSee [`docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md), \"Kernel systems\".\n",
	}
	depth_problems := intent_pointer_problems(&site, wrong_depth)
	testing.expectf(t, len(depth_problems) == 1, "%v", depth_problems)
	if len(depth_problems) == 1 {
		testing.expect(t, strings.has_prefix(depth_problems[0], "src/md/features/kernel.md, line 3: "), depth_problems[0])
		testing.expect(t, strings.contains(depth_problems[0], "names no document"), depth_problems[0])
	}
}

// An intent file is a working record: a code span of a guide and a pointer
// of a comment that name one are references to the file in the repository,
// and a pointer to a file that the folder does not have is a fault.
@(test)
intent_files_are_working_records :: proc(t: ^testing.T) {
	testing.expect(t, site_is_working_record("src/md/README.md"))
	testing.expect(t, site_is_working_record("src/md/features/palette.md"))
	testing.expect(t, !site_is_working_record("src/processes/console/README.md"))
	end, found := checks.site_document_path_end("see src/md/features/palette.md, \"The form\"", 4)
	testing.expect(t, found)
	testing.expect_value(t, end, len("see src/md/features/palette.md"))
	_, in_a_longer_path := checks.site_document_path_end("other/src/md/README.md", len("other/"))
	testing.expect(t, !in_a_longer_path)
	_, not_markdown := checks.site_document_path_end("src/md/features/palette.odin", 0)
	testing.expect(t, !not_markdown)
	pointers := checks.site_document_pointers("The form (src/md/README.md, \"File Index\") and docs/ARCHITECTURE.md.")
	testing.expect_value(t, len(pointers), 2)
	if len(pointers) == 2 {
		testing.expect_value(t, pointers[0].path, "src/md/README.md")
		testing.expect_value(t, len(pointers[0].labels), 1)
		testing.expect_value(t, pointers[1].path, "docs/ARCHITECTURE.md")
	}
	site := reference_test_site()
	path, names_document := site_document_of_code_span(&site, "src/md/README.md")
	testing.expect(t, names_document)
	testing.expect_value(t, path, "src/md/README.md")
	targets := site_document_targets(&site, "src/md/README.md", []string{"\"File Index\""})
	testing.expect_value(t, len(targets), 1)
	if len(targets) == 1 {
		testing.expect(t, targets[0].outside && targets[0].resolved, "the file index of the intent folder is not found")
		testing.expect(t, strings.has_prefix(targets[0].link, checks.SITE_REPOSITORY_ADDRESS + "/blob/master/src/md/README.md#L"), targets[0].link)
	}
	absent := site_pointer_problem(&site, "a.odin", 3, "src/md/features/no_such_file.md", nil)
	testing.expect(t, strings.contains(absent, "no such file"), absent)
}
