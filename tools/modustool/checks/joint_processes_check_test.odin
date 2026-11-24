package checks

import "core:strings"
import "core:testing"

@(test)
joint_processes_check_refuses_unlisted_machine_service_and_missing_scope :: proc(t: ^testing.T) {
	// Missing scope is refused.
	missing_scope := `package root
joint_process_names := [?]string{"storage"}
start_grant_sets := [?]Row {
	{name = "storage", scope = .Machine, grants = {.Serve}},
	{name = "notes", grants = {.Store}},
}
`
	problems, _, _ := joint_processes_problems(missing_scope, "test.odin")
	testing.expect_value(t, len(problems), 1)
	if len(problems) == 1 {
		testing.expect(t, strings.contains(problems[0], "no explicit scope"), problems[0])
	}

	// Unknown scope is refused.
	bad_scope := `package root
joint_process_names := [?]string{"storage"}
start_grant_sets := [?]Row {
	{name = "storage", scope = .Machine, grants = {.Serve}},
	{name = "notes", scope = .Global, grants = {.Store}},
}
`
	problems, _, _ = joint_processes_problems(bad_scope, "test.odin")
	testing.expect_value(t, len(problems), 1)
	if len(problems) == 1 {
		testing.expect(t, strings.contains(problems[0], "not .Machine or .Session"), problems[0])
	}

	// A Machine-scope service with .Serve not in joint_process_names is refused.
	unlisted_service := `package root
joint_process_names := [?]string{"storage"}
start_grant_sets := [?]Row {
	{name = "storage", scope = .Machine, grants = {.Serve}},
	{name = "sneaky", scope = .Machine, grants = {.Serve}},
}
`
	problems, _, _ = joint_processes_problems(unlisted_service, "test.odin")
	testing.expect_value(t, len(problems), 1)
	if len(problems) == 1 {
		testing.expect(t, strings.contains(problems[0], "sneaky"), problems[0])
	}

	// A Machine-scope System_Part service that is callable by another row and not in joint_process_names is refused.
	callable_part := `package root
joint_process_names := [?]string{"storage"}
start_grant_sets := [?]Row {
	{name = "storage", scope = .Machine, grants = {.Serve}},
	{name = "devices", scope = .Machine, grants = {.System_Part, .Serve}},
	{name = "caller", scope = .Session, grants = {.Connect}, terms = {callable = {0 = "devices"}}},
}
`
	problems, _, _ = joint_processes_problems(callable_part, "test.odin")
	testing.expect_value(t, len(problems), 1)
	if len(problems) == 1 {
		testing.expect(t, strings.contains(problems[0], "devices"), problems[0])
	}

	// A Machine-scope process holding .Store and not in joint_process_names is refused.
	machine_store := `package root
joint_process_names := [?]string{"storage"}
start_grant_sets := [?]Row {
	{name = "storage", scope = .Machine, grants = {.Serve}},
	{name = "cache", scope = .Machine, grants = {.Store}},
}
`
	problems, _, _ = joint_processes_problems(machine_store, "test.odin")
	testing.expect_value(t, len(problems), 1)
	if len(problems) == 1 {
		testing.expect(t, strings.contains(problems[0], "holds Store"), problems[0])
	}

	// Duplicate or unknown entry in joint_process_names is refused, as is a joint process marked .Session.
	bad_joint := `package root
joint_process_names := [?]string{"storage", "storage", "ghost", "plans"}
start_grant_sets := [?]Row {
	{name = "storage", scope = .Machine, grants = {.Serve}},
	{name = "plans", scope = .Session, grants = {.Serve, .Store}},
}
`
	problems, _, _ = joint_processes_problems(bad_joint, "test.odin")
	testing.expect_value(t, len(problems), 3)

	// Valid table passes: joint Machine services, root-only System_Part service not in any callable list, and Session services.
	valid := `package root
joint_process_names := [?]string{"storage", "unlock"}
start_grant_sets := [?]Row {
	{name = "storage", scope = .Machine, grants = {.Serve, .Data_Disk}},
	{name = "unlock", scope = .Machine, grants = {.Store, .Principals}},
	{name = "devices", scope = .Machine, grants = {.System_Part, .Serve}},
	{name = "plans", scope = .Session, grants = {.Serve, .Store}},
	{name = "settings", scope = .Session, grants = {.Settings, .Serve, .Store}},
}
`
	valid_problems, rows, joints := joint_processes_problems(valid, "test.odin")
	testing.expect_value(t, len(valid_problems), 0)
	testing.expect_value(t, rows, 5)
	testing.expect_value(t, joints, 2)
}

@(test)
joint_processes_check_holds_on_the_repository :: proc(t: ^testing.T) {
	testing.expect(t, joint_processes_check())
}
