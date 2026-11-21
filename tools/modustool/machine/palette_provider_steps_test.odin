package machine

import "core:strings"
import "core:testing"

// The line that ends the grant of the palette provider of the console: no
// fact of the provider comes after it in the same machine.
@(private = "file")
PROVIDER_REVOKE_LINE :: "revoke(\"console\", \"palette\")"

// provider_fact_waited says if a text that a step waits for is a fact that
// only the palette provider of the console logs: a refresh of the marks, a
// moved mark, or another line of the palette in the console.
@(private = "file")
provider_fact_waited :: proc(text: string) -> bool {
	return strings.has_prefix(text, "console: the palette") || strings.contains(text, "getters in the process of the console")
}

// provider_steps_check gives the first step that waits for a fact of the
// palette provider of the console after a step ended its grant, or -1. Such
// a wait can only end at its bound: the panel then sends the console
// nothing.
@(private = "file")
provider_steps_check :: proc(steps: []Step) -> (wrong_step: int) {
	provided := true
	for step, index in steps {
		if step.kind == .Type && step.text == PROVIDER_REVOKE_LINE {
			provided = false
		}
		if !provided && step.kind == .Wait && provider_fact_waited(step.text) {
			return index
		}
	}
	return -1
}

// A wait for a fact of the provider after the end of its grant is refused,
// at its step: the refresh of the marks, a moved mark, a line of the
// palette. A wait before the revoke, and a wait of the compositor after
// it, are kept. Then each scenario that waits for these facts keeps the
// rule.
@(test)
a_fact_of_the_provider_after_its_grant_ended_is_refused :: proc(t: ^testing.T) {
	revoke := Step{kind = .Type, text = PROVIDER_REVOKE_LINE}
	refresh := Step{kind = .Wait, text = "getters sent, 1 getters in the process of the console not called"}
	mark := Step{kind = .Wait, text = "console: the palette marks .spleen for settings.set font"}
	runs := Step{kind = .Wait, text = "console: the palette runs settings.set(font = .spleen)"}
	compositor := Step{kind = .Wait, text = "compositor: the palette has no provider"}
	for wait in ([]Step{refresh, mark, runs}) {
		testing.expect_value(t, provider_steps_check({revoke, wait}), 1)
		testing.expect_value(t, provider_steps_check({wait, revoke, compositor, wait}), 3)
	}
	// The same text typed, not waited for, and another revoke, are no
	// end of the grant of the console.
	testing.expect_value(t, provider_steps_check({{kind = .Wait, text = PROVIDER_REVOKE_LINE}, refresh}), -1)
	testing.expect_value(t, provider_steps_check({{kind = .Type, text = "revoke(\"console\", \"remote\")"}, mark}), -1)
	testing.expect_value(t, provider_steps_check({}), -1)
	testing.expect_value(t, provider_steps_check({refresh, mark, runs, revoke, compositor}), -1)
	testing.expect_value(t, provider_steps_check(scenario[:]), -1)
	testing.expect_value(t, provider_steps_check(scenario_palette_film[:]), -1)
}
