package build

import "core:strings"
import "core:testing"
import "modus:contract/chosen_values"
import "modustool:foundation"

// The log facts of the browser against the sentences that its readers
// wait for (src/md/features/log_facts.md): each count at 0, 1 and
// max(u64), each Text field at its longest text, and each view at the
// edges of a text view.

@(private = "file")
BROWSER_EDGE_COUNTS := [3]u64{0, 1, max(u64)}

@(test)
the_facts_of_the_browser_write_their_sentences :: proc(t: ^testing.T) {
	file, ok := facts_file_of_folder(t, strings.concatenate({foundation.DEMONSTRATION_MODULE_SOURCES, "browser"}, context.temp_allocator))
	if !ok {
		return
	}
	// The longest kind of a page, and the longest cause of a window that
	// stays fixed.
	longest_kind := "a read of another origin, refused"
	longest_cause := "a least size is below the least size of a resizable surface"
	most := make(map[string]u32, context.temp_allocator)
	most["kind"] = u32(len(longest_kind))
	most["cause"] = u32(len(longest_cause))
	problems := make([dynamic]string, context.temp_allocator)
	for name in chosen_values.RECORD_PROBLEM_NAMES {
		append(&problems, name)
	}
	most["problem"] = longest(problems[:])
	facts_expect_text_fields_last(t, file, most)
	for count in BROWSER_EDGE_COUNTS {
		other := max(u64) - count
		facts_expect_line(t, fact_test_render(t, file, "browser", "Window_Ready", {{"pages", count}}), line_of_before("browser: ok, the window is ready, with ", count, " pages built in"))
		for text in view_texts() {
			rendered, written := views_render(t, file, "browser", "Page_Loaded", {{"nodes", count}, {"rules", other}, {"boxes", count}, {"records", other}, {"bytes", count}, {"kind", longest_kind}}, {text})
			if len(written) == 1 {
				facts_expect_line(t, rendered, line_of_before("browser: loaded ", written[0], ", ", longest_kind, ": ", count, " nodes, ", other, " style rules, ", count, " document boxes, ", other, " draw records, ", count, " bytes of HTML"))
			}
			rendered, written = views_render(t, file, "browser", "Form_Sent", {{"fields", count}}, {text})
			if len(written) == 1 {
				facts_expect_line(t, rendered, line_of_before("browser: sent a form of ", count, " fields to ", written[0]))
			}
		}
	}
	rendered, written := views_render(t, file, "browser", "Link_Followed", {}, {"modus://welcome", "modus://properties"})
	if len(written) == 2 {
		facts_expect_line(t, rendered, line_of_before("browser: followed a link from ", written[0], " to ", written[1]))
	}
	rendered, written = views_render(t, file, "browser", "Address_Refused", {}, {"the address names no host", "modus://"})
	if len(written) == 2 {
		facts_expect_line(t, rendered, line_of_before("browser: refused the address ", written[1], ": ", written[0]))
	}
	facts_expect_line(t, fact_test_render(t, file, "browser", "Window_Stays_Fixed", {{"cause", longest_cause}}), line_of_before("browser: the window stays fixed: ", longest_cause))
}
