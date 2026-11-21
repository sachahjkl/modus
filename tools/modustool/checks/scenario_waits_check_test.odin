package checks

import "core:testing"
import "modustool:build"

// The read of the step literals: a literal, a constant of another package,
// a sum of both, a text that the code formats (counted, not read), the
// kinds whose text is no text of the log, and a record of a module with a
// member Wait, which is no step.
@(test)
the_step_literals_and_the_text_lines_are_read :: proc(t: ^testing.T) {
	tool := `package machine
LINE :: "storage: the block "
steps := [?]Step {
	{kind = .Wait, text = "storage: opened the store settings", fails_on = checks.WRONG_LINE},
	{kind = .Wait, text = LINE + "12 has a bad check"},
	{kind = .Type, text = "storage: typed, not waited for"},
	{kind = .Key_Until, text = "r", expected = "start policy: rescue"},
	{kind = .Wait, text = fmt.tprintf("storage: %d", 1)},
}
`
	tool_checks := `package checks
WRONG_LINE :: "storage: WRONG"
`
	system := `package storage
kinds := [?]Thing{{kind = .Wait, text = "storage: no step"}}
f :: proc() {
	system.log(.Info, "storage: the store ", name, " holds {", count, "} objects")
	other.log(.Info, "storage: not a text line of the system")
}
`
	found, ok := scenario_waits_of_sources({{path = "tools/modustool/machine/steps.odin", text = tool}, {path = "tools/modustool/checks/lines.odin", text = tool_checks}, {path = "src/modules/system/storage/main.odin", text = system}})
	testing.expect(t, ok, "the sources parse")
	testing.expect_value(t, len(found.waits), 4)
	testing.expect_value(t, found.unread, 1)
	expected := []struct {
		kind, field, text: string,
		line:              int,
	}{{"Wait", "text", "storage: opened the store settings", 4}, {"Wait", "fails_on", "storage: WRONG", 4}, {"Wait", "text", "storage: the block 12 has a bad check", 5}, {"Key_Until", "expected", "start policy: rescue", 7}}
	for item, index in expected {
		if index >= len(found.waits) {
			break
		}
		wait := found.waits[index]
		testing.expectf(t, wait.kind == item.kind && wait.field == item.field && wait.text == item.text && wait.line == item.line, "the wait %d is %v", index, wait)
	}
	testing.expect_value(t, len(found.text_lines), 1)
	if len(found.text_lines) == 1 {
		testing.expect_value(t, found.text_lines[0], "storage: the store {value} holds {{{value}}} objects")
	}
}

// A source that the parser refuses fails the read: a check that read
// nothing would pass.
@(test)
a_source_that_the_parser_refuses_fails_the_read :: proc(t: ^testing.T) {
	_, ok := scenario_waits_of_sources({{path = "tools/modustool/machine/broken.odin", text = "package machine\nsteps := [?]Step{{kind = .Wait, text = \"x\"\n"}})
	testing.expect(t, !ok, "a broken source fails the read")
}

// The problem line names the place, the text and the nearest template.
@(test)
a_finding_names_its_place_and_the_nearest_template :: proc(t: ^testing.T) {
	template := build.fact_wait_template_make("storage: opened the store {store}", {{name = "store", class = .Word}}, "storage", context.temp_allocator)
	known := build.fact_wait_templates_make({template}, context.temp_allocator)
	problems := scenario_wait_problems(&known, {{path = "a.odin", line = 3, kind = "Wait", field = "text", text = "storage: opened a store"}, {path = "a.odin", line = 4, kind = "Wait", field = "text", text = "storage: opened the store x"}})
	testing.expect_value(t, len(problems), 1)
	if len(problems) == 1 {
		testing.expect_value(t, problems[0], "a.odin:3: the step Wait waits for the fact text \"storage: opened a store\" (text), which no fact template and no text line of the build renders; the nearest, of storage, renders \"storage: opened \" then not \"a store\": \"storage: opened the store {store}\"")
	}
}
