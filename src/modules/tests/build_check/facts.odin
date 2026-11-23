package build_check

import "modus:contract/value_kinds"

// The log facts of the test module build_check
// (src/md/features/log_facts.md). A text view is the last field.

// A check failed: what the test checked, and the value that it found.
@(log_fact = "build_check: WRONG: {what} {value}")
Wrong :: struct {
	value: u64,
	what:  value_kinds.Text_View,
}

// A build gave an output: the outcome word, and the first 8 bytes of the
// output hash.
@(log_fact = "build_check: {what}: the outcome {outcome}, the output {output_head}")
Built :: struct {
	outcome:     u64,
	output_head: u64,
	what:        value_kinds.Text_View,
}

// A build was refused as the test asks: the word of the refusal
// (plans_recipes.Recipe_Refusal).
@(log_fact = "build_check: the build of {act} was refused as asked: the refusal {refusal}")
Refused_As_Asked :: struct {
	refusal: u64,
	act:     value_kinds.Text_View,
}

// Each check passed.
@(log_fact = "build_check: each check of the builders passed")
Done :: struct {}
