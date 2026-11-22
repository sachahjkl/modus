// Tagged-union representation of machine-test scenario steps and named main
// test sections so scenario steps carry only the fields of their active kind
// and the main test can run or report by named section.
package machine

Main_Test_Section :: enum u8 {
	Boot          = 1,
	Desktop       = 2,
	Console       = 3,
	Storage       = 4,
	Network       = 5,
	Security      = 6,
	Accessibility = 7,
}

@(rodata)
MAIN_TEST_SECTION_NAMES := [Main_Test_Section]string{
	.Boot          = "boot",
	.Desktop       = "desktop",
	.Console       = "console",
	.Storage       = "storage",
	.Network       = "network",
	.Security      = "security",
	.Accessibility = "accessibility",
}

Step_Wait_Fact :: struct {
	prefix: string,
}

Step_Send_Text :: struct {
	text: string,
}

Step_Pointer_Move :: struct {
	x: i32,
	y: i32,
}

Step_Capture_Picture :: struct {
	filename: string,
}

Step_Check_Element :: struct {
	role_name: string,
	label:     string,
}

Scenario_Step_Union :: union #no_nil {
	Step_Wait_Fact,
	Step_Send_Text,
	Step_Pointer_Move,
	Step_Capture_Picture,
	Step_Check_Element,
}

Named_Scenario_Step :: struct {
	section: Main_Test_Section,
	step:    Scenario_Step_Union,
}

scenario_step_valid :: proc(ns: Named_Scenario_Step) -> bool {
	switch s in ns.step {
	case Step_Wait_Fact:       return len(s.prefix) > 0
	case Step_Send_Text:       return len(s.text) > 0
	case Step_Pointer_Move:    return s.x >= 0 && s.y >= 0
	case Step_Capture_Picture: return len(s.filename) > 0
	case Step_Check_Element:   return len(s.role_name) > 0 && len(s.label) > 0
	}
	return false
}
