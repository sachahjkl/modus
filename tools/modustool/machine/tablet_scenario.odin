package machine

import "modustool:foundation"
import "modustool:build"

// The virtio tablet: three machines (docs/ARCHITECTURE.md, "The virtio
// tablet").
//
// The first machine has the tablet at its place: the root service arms it
// and gives it to the input service, which says that it is ready. A report
// of the tablet with the button presses the maximize button of the console:
// the window asks for the size of the work area, takes it, and a second
// press, now on the restore button, gives it its size of before. Then the
// console stops the input service; the start policy starts it again, the
// root service resets the tablet before it arms it again, and a press of
// the tablet works again.
//
// The first machine also checks a double press on the title, a drag of the
// title of the maximized window, and Control+Shift+Up during a drag of an
// edge, which asks for no second size.
//
// The second machine has another virtio device at the place of the tablet,
// and the third a tablet at another place: in both, the input service
// starts with the PS/2 mouse only. The fourth has the tablet and no PS/2
// controller: the input service goes on with the tablet.

TEST_OUTPUT_TABLET :: foundation.BUILD_FOLDER + "/test_output_tablet.txt"

TABLET_READY_LINE :: "input: virtio tablet ready, a queue of "
// The middle of the maximize button, and of the restore button at its
// place: from the right side of the frame, past the border, the close
// button and half of the button (compositor/main.odin, frame_records).
MAXIMIZE_BUTTON_X :: -(WINDOW_BORDER + 24 + 28 / 2)
MAXIMIZE_BUTTON_Y :: 12
// A point of the title bar of the console, far from its buttons.
TITLE_POINT_X :: 300

@(private = "file")
scenario_tablet := [?]Step {
	{kind = .Wait, text = "input: ok, the mouse has a wheel"},
	{kind = .Wait, text = TABLET_READY_LINE},
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Wait, text = "compositor: window console is resizable from ", any_order = true},
	{kind = .Wait, text = "root: the machine is usable, by the start policy ", any_order = true},
	// The maximize: the press lands on the button only through the tablet,
	// since no relative move came before it.
	{kind = .Click_Absolute, inside_window = "console", x = MAXIMIZE_BUTTON_X, y = MAXIMIZE_BUTTON_Y},
	{kind = .Wait, text = "compositor: window console asked to draw at "},
	{kind = .Wait, text = "compositor: window console resized from "},
	// The restore, at the button of the maximized window.
	{kind = .Click_Absolute, inside_window = "console", x = MAXIMIZE_BUTTON_X, y = MAXIMIZE_BUTTON_Y},
	{kind = .Wait, text = "compositor: window console asked to draw at "},
	{kind = .Wait, text = "compositor: window console resized from "},
	// A double press on the title toggles the maximize.
	{kind = .Click_Absolute, inside_window = "console", x = TITLE_POINT_X, y = MAXIMIZE_BUTTON_Y},
	{kind = .Click_Absolute, inside_window = "console", x = TITLE_POINT_X, y = MAXIMIZE_BUTTON_Y},
	{kind = .Wait, text = "compositor: window console maximized"},
	{kind = .Wait, text = "compositor: window console asked to draw at "},
	{kind = .Wait, text = "compositor: window console resized from "},
	// A drag of the title of the maximized window: past the distance of a
	// still press, the window takes back its size of before under the
	// pointer, and the drag goes on.
	{kind = .Press_Absolute, inside_window = "console", x = TITLE_POINT_X, y = MAXIMIZE_BUTTON_Y},
	{kind = .Move_Absolute, x = 200, y = 150},
	{kind = .Wait, text = "compositor: window console restored"},
	{kind = .Wait, text = "compositor: window console asked to draw at "},
	{kind = .Release_Absolute},
	// The new surface and the end of the drag come in no fixed order.
	{kind = .Wait, text = "compositor: window console resized from ", any_order = true},
	{kind = .Wait, text = "compositor: window console moved to "},
	// Control+Shift+Up while a drag holds the right edge: the maximize waits
	// for the end of the drag, so the window asks for one size, the size of
	// the drag, and is not maximized.
	{kind = .Press_Absolute, inside_window = "console", x = -1, y = 200},
	{kind = .Key, text = "ctrl-shift-up"},
	{kind = .Move_Absolute, x = 40, y = 0},
	{kind = .Release_Absolute},
	{kind = .Wait, text = "compositor: window console asked to draw at ", fails_on = "compositor: window console maximized"},
	{kind = .Wait, text = "compositor: window console resized from ", fails_on = "compositor: window console asked to draw at "},
	// A stop of the input service: the start policy starts it again, and
	// the root service arms the tablet again.
	{kind = .Type, text = "stop(\"input\")"},
	{kind = .Wait, text = "start_policy: input stopped: "},
	{kind = .Wait, text = TABLET_READY_LINE},
	{kind = .Click_Absolute, inside_window = "console", x = MAXIMIZE_BUTTON_X, y = MAXIMIZE_BUTTON_Y},
	{kind = .Wait, text = "compositor: window console asked to draw at "},
	{kind = .Wait, text = "compositor: window console resized from "},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

// No tablet at its place: the input service has the PS/2 mouse only, and
// the desktop comes up with no line of a tablet.
@(private = "file")
scenario_tablet_absent := [?]Step {
	{kind = .Wait, text = "input: ok, the mouse has a wheel"},
	// The two lines come in no fixed order.
	{kind = .Wait, text = "compositor: surface console", any_order = true, fails_on = TABLET_READY_LINE},
	{kind = .Wait, text = "root: the machine is usable, by the start policy ", any_order = true, fails_on = TABLET_READY_LINE},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0", fails_on = TABLET_READY_LINE},
}

// No PS/2 controller, and the tablet: the input service goes on with the
// pointer of the tablet, which maximizes the console. No key reaches the
// machine: the tool ends QEMU.
@(private = "file")
scenario_tablet_without_controller := [?]Step {
	{kind = .Wait, text = "input: no PS/2 controller: no keyboard; the pointer is the virtio tablet", fails_on = "input: no PS/2 controller: no keyboard and no mouse"},
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Wait, text = "compositor: window console is resizable from ", any_order = true},
	{kind = .Wait, text = "root: the machine is usable, by the start policy "},
	{kind = .Click_Absolute, inside_window = "console", x = MAXIMIZE_BUTTON_X, y = MAXIMIZE_BUTTON_Y},
	{kind = .Wait, text = "compositor: window console maximized"},
	{kind = .Wait, text = "compositor: window console resized from "},
	{kind = .Quit},
}

tablet_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	options := Machine_Options{volume = build.BOOT_VOLUME, output = TEST_OUTPUT_TABLET, exit_status = build.MACHINE_STOP_OK}
	with_tablet, other_device, other_place := options, options, options
	with_tablet.tablet = .At_Its_Place
	other_device.tablet = .Other_Device_At_Its_Place
	other_place.tablet = .At_Another_Place
	without_controller := options
	without_controller.tablet, without_controller.without_ps2_controller, without_controller.exit_status = .At_Its_Place, true, 0
	return machine_test(part, scenario_tablet[:], with_tablet) && machine_test(part, scenario_tablet_absent[:], other_device) && machine_test(part, scenario_tablet_absent[:], other_place) && machine_test(part, scenario_tablet_without_controller[:], without_controller)
}

// A binary of the tool runs the test part tablet only when it holds this
// file (test_parts.odin, test_part_scenario_register).
@(init)
tablet_test_part_register :: proc "contextless" () {
	test_part_scenario_register("tablet", tablet_tests_run)
}
