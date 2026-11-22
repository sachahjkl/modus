package machine

import "core:testing"

@(test)
tagged_union_scenario_steps_and_named_sections_validate :: proc(t: ^testing.T) {
	testing.expect_value(t, MAIN_TEST_SECTION_NAMES[.Boot], "boot")
	testing.expect_value(t, MAIN_TEST_SECTION_NAMES[.Accessibility], "accessibility")

	valid := [?]Named_Scenario_Step{
		{section = .Boot, step = Step_Wait_Fact{prefix = "kernel: ok"}},
		{section = .Console, step = Step_Send_Text{text = "help
"}},
		{section = .Desktop, step = Step_Pointer_Move{x = 120, y = 40}},
		{section = .Desktop, step = Step_Capture_Picture{filename = "desktop.png"}},
		{section = .Accessibility, step = Step_Check_Element{role_name = "button", label = "Close"}},
	}
	for s in valid {
		testing.expect(t, scenario_step_valid(s))
	}
	testing.expect(t, !scenario_step_valid({section = .Boot, step = Step_Wait_Fact{prefix = ""}}))
	testing.expect(t, !scenario_step_valid({section = .Desktop, step = Step_Pointer_Move{x = -1, y = 0}}))
}
