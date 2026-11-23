package machine

import "modustool:build"
import "modustool:foundation"

// The remote display (src/md/features/remote_display.md): the peer of the
// tool is the viewer, with its own key, through the network service.
// Each refusal comes first: a key that no principal allowed, a record
// before Session_Start, a second Session_Start, a Viewer_Frame_Taken out of
// order, a kind that names no record, a record of the other direction, a
// damaged request, a record past its bound, input from a key of the view
// alone, a viewer that never takes its viewer frame, and a viewer past the
// capacity of the service.
// Then the viewer rebuilds the screen from the screen pieces, the tool
// compares it with a picture of QEMU of the same moment, an allow that adds
// the input keeps the session, the pointer of the viewer goes over the
// clock, its key super opens the palette, a revocation ends the session
// with a viewer frame in flight, and the session of a named principal in
// front ends the session of a key of principal 0.
//
// The measures: the bytes of a whole screen and of a viewer frame of a
// small damage, at the viewer (lines of the tool) and in the machine
// (lines of the service).

TEST_OUTPUT_REMOTE_DISPLAY :: foundation.BUILD_FOLDER + "/test_output_remote_display.txt"

scenario_remote_display := [?]Step {
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Type, text = "start(\"remote_display\")"},
	{kind = .Wait, text = "root: started network"},
	{kind = .Wait, text = "network: an endpoint for remote_display: UDP, the listen port 7101", any_order = true},
	{kind = .Remote_Display_Key, text = "remote_display: the public key of this service: "},
	{kind = .Wait, text = "remote_display: listening on the UDP port 7101, for the host 10.0.2.2 only, and for the viewer keys that a principal allowed", any_order = true},
	// The refusals. A key that no principal allowed: refused in the
	// handshake.
	{kind = .Remote_Display_Case, text = "unknown key"},
	{kind = .Wait, text = "remote_display: refused the viewer key ", any_order = true},
	{kind = .Type, text = "remote_display_allow(\"{viewer key}\", \"view\")"},
	{kind = .Wait, text = " for the remote display: view"},
	{kind = .Remote_Display_Case, text = "before session start"},
	{kind = .Wait, text = ": a record before Session_Start: the connection ends with the code Bad_Record", any_order = true},
	{kind = .Remote_Display_Case, text = "second session start"},
	{kind = .Wait, text = ": a second Session_Start: the connection ends with the code Bad_Record", any_order = true},
	{kind = .Remote_Display_Case, text = "taken out of order"},
	{kind = .Wait, text = ": a Viewer_Frame_Taken of no viewer frame in flight: the connection ends with the code Out_Of_Order", any_order = true},
	{kind = .Remote_Display_Case, text = "unknown kind"},
	{kind = .Wait, text = ": its kind names no record: the connection ends with the code Bad_Record", any_order = true},
	{kind = .Remote_Display_Case, text = "other direction"},
	{kind = .Wait, text = ": its kind goes the other way: the connection ends with the code Bad_Record", any_order = true},
	{kind = .Remote_Display_Case, text = "damaged request"},
	{kind = .Wait, text = ": it names a place outside the screen: the connection ends with the code Bad_Record", any_order = true},
	{kind = .Remote_Display_Case, text = "past bound"},
	{kind = .Wait, text = ": it is past its bound: the connection ends with the code Too_Large", any_order = true},
	// Input from a key of the view alone: the connection ends, and the
	// compositor received no key and no pointer of a viewer.
	{kind = .Remote_Display_Case, text = "input from a key of the view"},
	{kind = .Wait, text = " sent input, and principal 0 allowed it for the view only: nothing reaches the desktop, and the connection ends with the code Input_Not_Allowed", any_order = true},
	{kind = .Wait, text = " pictures, 0 keys and 0 pointer records of viewers, 0 refused commands", any_order = true},
	{kind = .Remote_Display_Case, text = "never takes its frame"},
	{kind = .Wait, text = " did not take its viewer frame in its bound of 10000 ms: the connection ends with the code Timeout", any_order = true},
	{kind = .Remote_Display_Case, text = "a viewer past the capacity"},
	// The view: the whole screen, then the damage, equal to the screen.
	{kind = .Remote_Display_Case, text = "view"},
	{kind = .Wait, text = "compositor: the capture face is open: a copy of ", any_order = true},
	{kind = .Wait, text = "remote_display: a measure: the whole screen of ", any_order = true},
	{kind = .Remote_Display_Case, text = "compare"},
	{kind = .Remote_Display_Case, text = "small frames"},
	{kind = .Wait, text = "remote_display: a measure: viewer frames of a small damage", any_order = true},
	// The input: an allow that adds it keeps the session open; the pointer
	// of the viewer goes over the clock, and the screen is still the
	// screen around it; the key super opens the palette, and Escape closes
	// it.
	{kind = .Type, text = "remote_display_allow(\"{viewer key}\", \"view_and_input\")"},
	{kind = .Wait, text = " more uses: view and input"},
	{kind = .Remote_Display_Case, text = "same session"},
	{kind = .Remote_Display_Case, text = "pointer over the clock"},
	{kind = .Remote_Display_Case, text = "super"},
	{kind = .Wait, text = "compositor: the first key of a viewer of the remote display goes along the path of the keys", any_order = true},
	{kind = .Wait, text = "compositor: the palette is open", any_order = true},
	{kind = .Remote_Display_Case, text = "escape"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	// The revocation with a viewer frame in flight.
	{kind = .Remote_Display_Case, text = "hold a frame"},
	{kind = .Type, text = "remote_disallow(\"{viewer key}\")"},
	{kind = .Wait, text = " ended (a revocation, a lock of its session, or another session in front): the connection from 10.0.2.2 port ", any_order = true},
	{kind = .Remote_Display_Case, text = "revoked"},
	{kind = .Wait, text = "compositor: the capture face ended (the service closed it)"},
	// The session in front: a key of principal 0 sees nothing while the
	// session of alice is in front.
	{kind = .Type, text = "remote_display_allow(\"{viewer key}\", \"view\")"},
	{kind = .Wait, text = " for the remote display: view"},
	{kind = .Remote_Display_Case, text = "view"},
	{kind = .Type, text = "principal_create(\"alice\")"},
	{kind = .Wait, text = "root: started unlock"},
	{kind = .Wait, text = "compositor: surface unlock"},
	{kind = .Front, text = "unlock"},
	{kind = .Type, text = PRINCIPAL_PASSPHRASE},
	{kind = .Type, text = PRINCIPAL_PASSPHRASE},
	// The root service puts the session in front, so the key of principal 0
	// loses the screen, before it starts the processes of the session.
	{kind = .Wait, text = " of principal 0 loses the view and the input while the session of principal 1 is in front"},
	{kind = .Wait, text = "root: the session of principal 1 \"alice\" starts: the desktop starts each process in it"},
	{kind = .Remote_Display_Case, text = "revoked"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

remote_display_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	return machine_test(part, scenario_remote_display[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_REMOTE_DISPLAY, exit_status = build.MACHINE_STOP_OK})
}

// A binary of the tool runs the test part remote_display only when it holds this file
// (test_parts.odin, test_part_scenario_register).
@(init)
remote_display_test_part_register :: proc "contextless" () {
	test_part_scenario_register("remote_display", remote_display_tests_run)
}
