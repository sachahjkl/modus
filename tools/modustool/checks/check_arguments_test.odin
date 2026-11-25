package checks

import "core:testing"
import "modustool:foundation"

// check_arguments_parse refuses bad modes, extra arguments, and bad fuzz
// shard bounds before accepting each valid sub-mode.
@(test)
check_arguments_parse_refuses_bad_inputs_and_accepts_sub_modes :: proc(t: ^testing.T) {
	refused := [?][]string{
		{"unknown"},
		{"static", "extra"},
		{"without_machines", "extra"},
		{"reproducible", "extra"},
		{"host_tests", "unknown"},
		{"host_tests", "system", "extra"},
		{"fuzz"},
		{"fuzz", "1"},
		{"fuzz", "1", "4", "extra"},
		{"fuzz", "0", "4"},
		{"fuzz", "1", "0"},
		{"fuzz", "0", "0"},
		{"fuzz", "5", "4"},
		{"fuzz", "-1", "4"},
		{"fuzz", "1", "-4"},
		{"fuzz", "+1", "4"},
		{"fuzz", "1_0", "10"},
		{"fuzz", "a", "4"},
		{"fuzz", "1", "b"},
		{"fuzz", "", "4"},
		{"fuzz", "1", ""},
	}
	for args in refused {
		_, problem := check_arguments_parse(args)
		testing.expectf(t, problem != "", "args %v must be refused", args)
	}

	parsed, problem := check_arguments_parse(nil)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, parsed.mode, Check_Mode.All)

	parsed, problem = check_arguments_parse([]string{"without_machines"})
	testing.expect_value(t, problem, "")
	testing.expect_value(t, parsed.mode, Check_Mode.Without_Machines)

	parsed, problem = check_arguments_parse([]string{"static"})
	testing.expect_value(t, problem, "")
	testing.expect_value(t, parsed.mode, Check_Mode.Static)

	parsed, problem = check_arguments_parse([]string{"reproducible"})
	testing.expect_value(t, problem, "")
	testing.expect_value(t, parsed.mode, Check_Mode.Reproducible)

	parsed, problem = check_arguments_parse([]string{"host_tests"})
	testing.expect_value(t, problem, "")
	testing.expect_value(t, parsed.mode, Check_Mode.Host_Tests)
	testing.expect_value(t, parsed.host_tests_scope, Host_Tests_Scope.All)

	parsed, problem = check_arguments_parse([]string{"host_tests", "system"})
	testing.expect_value(t, problem, "")
	testing.expect_value(t, parsed.mode, Check_Mode.Host_Tests)
	testing.expect_value(t, parsed.host_tests_scope, Host_Tests_Scope.System)

	parsed, problem = check_arguments_parse([]string{"host_tests", "tool"})
	testing.expect_value(t, problem, "")
	testing.expect_value(t, parsed.mode, Check_Mode.Host_Tests)
	testing.expect_value(t, parsed.host_tests_scope, Host_Tests_Scope.Tool)

	parsed, problem = check_arguments_parse([]string{"fuzz", "1", "1"})
	testing.expect_value(t, problem, "")
	testing.expect_value(t, parsed.mode, Check_Mode.Fuzz)
	testing.expect_value(t, parsed.fuzz_shard, 1)
	testing.expect_value(t, parsed.fuzz_total, 1)

	parsed, problem = check_arguments_parse([]string{"fuzz", "4", "4"})
	testing.expect_value(t, problem, "")
	testing.expect_value(t, parsed.mode, Check_Mode.Fuzz)
	testing.expect_value(t, parsed.fuzz_shard, 4)
	testing.expect_value(t, parsed.fuzz_total, 4)
}

// host_test_folders_for_scope partitions HOST_TEST_FOLDERS into disjoint
// system and tool sets whose union preserves every folder.
@(test)
host_test_folders_for_scope_partitions_all_folders :: proc(t: ^testing.T) {
	all := host_test_folders_for_scope(.All)
	system := host_test_folders_for_scope(.System)
	tool := host_test_folders_for_scope(.Tool)
	testing.expect_value(t, len(all), len(HOST_TEST_FOLDERS))
	testing.expect(t, len(system) > 0 && len(tool) > 0, "both scopes are non-empty")
	testing.expect_value(t, len(system) + len(tool), len(all))
	for folder in tool {
		testing.expectf(t, foundation.source_folder_is_of_the_tool(folder), "%s belongs to tool scope", folder)
	}
	for folder in system {
		testing.expectf(t, !foundation.source_folder_is_of_the_tool(folder), "%s belongs to system scope", folder)
	}
	seen := make(map[string]bool, context.temp_allocator)
	for folder in tool {
		testing.expectf(t, !seen[folder], "%s appears once", folder)
		seen[folder] = true
	}
	for folder in system {
		testing.expectf(t, !seen[folder], "%s appears once", folder)
		seen[folder] = true
	}
	for folder in all {
		testing.expectf(t, seen[folder], "%s is covered by system or tool scope", folder)
	}
}
