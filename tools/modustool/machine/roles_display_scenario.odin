package machine

import "modustool:build"
import "modustool:foundation"

// Live verification of a second Display role holder (`panel_display`) on QEMU
// (src/md/features/roles_and_contracts.md):
//   1. Machine 1 boots `plan_and_audit` on a fresh data disk, runs
//      `display_role_planner` to apply a principal 0 plan naming
//      `panel_display` as holder of Role.Display, accepts the trusted-display
//      consent dialog, and shuts down cleanly.
//   2. Machine 2 boots on the same disk: `root` reads the stored plan before
//      `start_policy`, starts `panel_display` in place of `compositor`, verifies
//      `console` and `clock` open with a barless 1920x1080 work area and
//      complete Present blits, verifies `connect("display")` resolves to
//      `panel_display` and serves `screen()` and `windows()`, switches focus
//      back to `console` with Alt+Tab, stops `clock`, and shuts down cleanly.

TEST_ROLES_DISPLAY_DISK :: foundation.BUILD_FOLDER + "/test_roles_display_disk.img"
TEST_OUTPUT_ROLES_DISPLAY :: foundation.BUILD_FOLDER + "/test_output_roles_display_%d.txt"

DISPLAY_PLANNER_WRONG :: "display_role_planner: WRONG"

scenario_roles_display_first := [?]Step {
	{kind = .Wait, text = "root: principal 0 has no plan stored: the roles of the boot image hold"},
	{kind = .Wait, text = "display: console" + WINDOW_TAKEN},
	{kind = .Type, text = "start(\"display_role_planner\")"},
	{kind = .Wait, text = "display_role_planner: the dialog of the plan panel display takes the decision of the principal now", fails_on = DISPLAY_PLANNER_WRONG},
	{kind = .Key, text = "tab"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the difference of the plan panel display is accepted", fails_on = "compositor: the difference of the plan panel display is refused"},
	{kind = .Wait, text = "root: the roles of the plan of generation 1 are in force: 1 overrides, serial 1, rollback 0", any_order = true},
	{kind = .Wait, text = "display_role_planner: the principal accepted the plan: generation 1, whose holder of the role Display is panel_display", fails_on = DISPLAY_PLANNER_WRONG},
	{kind = .Wait, text = "root: display_role_planner stopped: itself, done"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

scenario_roles_display_second := [?]Step {
	{kind = .Wait, text = "root: the roles of generation 1 of the plan of principal 0 hold from the start: 1 overrides, serial "},
	{kind = .Wait, text = "panel_display: ready 1920x1080", fails_on = "root: started compositor"},
	{kind = .Wait, text = "display: console: the holder of the display took the window, in a work area of 1920x1080", fails_on = "root: started compositor"},
	{kind = .Wait, text = "panel_display: shown console", any_order = true},
	{kind = .Type, text = "d = connect(\"display\")"},
	{kind = .Wait, text = "[console]   module     panel_display"},
	{kind = .Type, text = "d.screen()"},
	{kind = .Wait, text = "[console] 1 row of Screen"},
	{kind = .Type, text = "d.windows()"},
	{kind = .Wait, text = "[console] 1 row of Window"},
	{kind = .Type, text = "start(\"clock\")"},
	{kind = .Wait, text = "display: clock: the holder of the display took the window, in a work area of 1920x1080"},
	{kind = .Wait, text = "panel_display: shown clock", any_order = true},
	{kind = .Key, text = "alt-tab"},
	{kind = .Type, text = "stop(\"clock\")"},
	{kind = .Wait, text = "panel_display: removed clock"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

roles_display_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	if !disk_prepare(TEST_ROLES_DISPLAY_DISK, build.DATA_DISK_SIZE, true) {
		return false
	}
	return machine_test(part, scenario_roles_display_first[:], {
		volume      = build.BOOT_VOLUME_PLAN_AND_AUDIT,
		output      = self_test_file(TEST_OUTPUT_ROLES_DISPLAY, 1),
		exit_status = build.MACHINE_STOP_OK,
		data_disk   = TEST_ROLES_DISPLAY_DISK,
	}) && machine_test(part, scenario_roles_display_second[:], {
		volume      = build.BOOT_VOLUME_PLAN_AND_AUDIT,
		output      = self_test_file(TEST_OUTPUT_ROLES_DISPLAY, 2),
		exit_status = build.MACHINE_STOP_OK,
		data_disk   = TEST_ROLES_DISPLAY_DISK,
	})
}

@(init)
roles_display_test_part_register :: proc "contextless" () {
	test_part_scenario_register("roles_display", roles_display_tests_run)
}
