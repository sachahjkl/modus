package checks

import "core:testing"

// The marks of Markdown do not trip the check of the comments, and a
// breach in bold or in a list item is still a breach.
@(test)
comment_markdown_and_the_comment_rules :: proc(t: ^testing.T) {
	exempt := make(map[string]string, context.temp_allocator)
	marked := "// **Bold**, *italic*, [the fault ring](docs/ARCHITECTURE.md#the-fault-ring), `code`.\n//\n// - an item\n//   - a nested item\n// 1. a first result\n//\n// ```odin\n// x := 1\n// ```\n"
	testing.expect_value(t, len(comment_rule_breaches_of_source("a.odin", marked, exempt)), 0)
	testing.expect_value(t, len(comment_rule_breaches_of_source("a.odin", "// **the caller owns it (property 14)**\n", exempt)), 1)
	testing.expect_value(t, len(comment_rule_breaches_of_source("a.odin", "// - a choice (choice 186)\n", exempt)), 1)
}
