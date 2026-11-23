package machine

import "modustool:build"
import "modustool:foundation"

// The screen of memory (src/md/features/screen_of_memory.md): a machine
// with no display device (`-vga none`) runs the desktop in a screen of
// memory of 1920 x 1080, the size of the row display of the default start
// list, with the input service and the console in it. The peer of the
// tool is a viewer with the input: it sees the whole desktop, asks for
// 2560 x 1440, which grows the budgets of the compositor and of
// remote_display, and receives that size and the whole screen; asks for
// 3840 x 2160, which gets Grown_Already; asks for 1280 x 720, which gives
// both extra budgets back, and receives that size and the whole screen;
// then asks a size past the bounds, which ends its session with Bad_Record.

TEST_OUTPUT_SCREEN_OF_MEMORY :: foundation.BUILD_FOLDER + "/test_output_screen_of_memory.txt"

scenario_screen_of_memory := [?]Step {
	{kind = .Wait, text = NO_SCREEN_LINE},
	{kind = .Wait, text = "root: the compositor starts on a screen of memory of 1920 x 1080: the machine has no screen", any_order = true},
	{kind = .Wait, text = "compositor: no screen: a screen of memory of 1920 x 1080", any_order = true},
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Wait, text = "root: the machine is usable, by the start policy ", any_order = true},
	{kind = .Type, text = "start(\"remote_display\")"},
	{kind = .Wait, text = "root: started network"},
	{kind = .Wait, text = "network: an endpoint for remote_display: UDP, the listen port 7101", any_order = true},
	{kind = .Remote_Display_Key, text = "remote_display: the public key of this service: "},
	{kind = .Wait, text = "remote_display: listening on the UDP port 7101, for the host 10.0.2.2 only, and for the viewer keys that a principal allowed", any_order = true},
	{kind = .Type, text = "remote_display_allow(\"{viewer key}\", \"view_and_input\")"},
	{kind = .Wait, text = " for the remote display: view and input"},
	// The viewer sees the whole desktop of memory.
	{kind = .Remote_Display_Case, text = "view"},
	{kind = .Wait, text = "compositor: the capture face is open: a copy of 1920x1080 after each frame", any_order = true},
	{kind = .Wait, text = "remote_display: a measure: the whole screen of 1920x1080", any_order = true},
	// A larger size: the root service grows the budgets of the compositor
	// and of remote_display together, the compositor takes the size, the
	// desktop fits it, and the viewer receives the size and the whole screen.
	{kind = .Remote_Display_Case, text = "ask 2560x1440"},
	{kind = .Wait, text = "root: the budgets of the screen of memory grow for 2560 x 1440: an extra budget of ", any_order = true},
	{kind = .Wait, text = "compositor: an extra budget of ", any_order = true},
	{kind = .Wait, text = "compositor: the screen of memory is now 2560 x 1440, which a viewer asked: ", any_order = true},
	{kind = .Wait, text = "remote_display: the screen is now 2560 x 1440: 1 viewers receive its size and the whole screen", any_order = true},
	// One extra budget for each process: a size that it does not pay waits
	// for a size at most the start size, and the session goes on.
	{kind = .Remote_Display_Case, text = "ask 3840x2160 refused Grown_Already"},
	{kind = .Wait, text = "remote_display: refused the screen of 3840 x 2160 that the viewer ", any_order = true},
	// A size at most the start size: both processes give their extra budget
	// back, and the viewer receives the size and the whole screen.
	{kind = .Remote_Display_Case, text = "ask 1280x720"},
	{kind = .Wait, text = "root: compositor gave back its extra budget of the screen of memory: its pages return", any_order = true},
	{kind = .Wait, text = "root: remote_display gave back its extra budget of the screen of memory: its pages return", any_order = true},
	{kind = .Wait, text = "compositor: the screen of memory is now 1280 x 720, which a viewer asked: ", any_order = true},
	{kind = .Wait, text = "remote_display: the screen is now 1280 x 720: 1 viewers receive its size and the whole screen", any_order = true},
	{kind = .Wait, text = "compositor: the capture face is open: a copy of 1280x720 after each frame", any_order = true},
	// A size past the bounds is a fault of the viewer: its border ends the
	// session.
	{kind = .Remote_Display_Case, text = "ask 7681x4320 ends Bad_Record"},
	{kind = .Wait, text = ": it names a place outside the screen: the connection ends with the code Bad_Record", any_order = true},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

screen_of_memory_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	return machine_test(part, scenario_screen_of_memory[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_SCREEN_OF_MEMORY, exit_status = build.MACHINE_STOP_OK, without_screen = true})
}

// A binary of the tool runs the test part screen_of_memory only when it
// holds this file (test_parts.odin, test_part_scenario_register).
@(init)
screen_of_memory_test_part_register :: proc "contextless" () {
	test_part_scenario_register("screen_of_memory", screen_of_memory_tests_run)
}
