package machine

import "modustool:build"
import "modustool:foundation"

// The remote display (src/md/features/remote_display.md): the peer of the
// tool is the viewer, with its own key, through the network service.
// Each refusal comes first: a key that no principal allowed, input from a
// key of the view alone, a damaged request, a record past its bound. Then
// the viewer rebuilds the screen from the tiles, the tool compares it with
// a picture of QEMU of the same moment, the key super of the viewer opens
// the palette, and a revocation ends the session in its middle.
//
// The measures: the bytes of a whole screen and of a frame of a small
// damage, at the viewer (lines of the tool) and in the machine (lines of
// the service).

TEST_OUTPUT_REMOTE_DISPLAY :: foundation.BUILD_FOLDER + "/test_output_remote_display.txt"

scenario_remote_display := [?]Step {
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Type, text = "start(\"remote_display\")"},
	{kind = .Wait, text = "root: started network"},
	{kind = .Wait, text = "network: an endpoint for remote_display: UDP, the listen port 7101", any_order = true},
	{kind = .Remote_Display_Key, text = "remote_display: the public key of this service: "},
	{kind = .Wait, text = "remote_display: listening on the UDP port 7101, for the host 10.0.2.2 only, and for the viewer keys that a principal allowed", any_order = true},
	// A key that no principal allowed: refused in the handshake.
	{kind = .Remote_Display_Case, text = "unknown key"},
	{kind = .Wait, text = "remote_display: refused the viewer key ", any_order = true},
	// The view alone: the screen, and no input.
	{kind = .Type, text = "remote_display_allow(\"{viewer key}\", \"view\")"},
	{kind = .Wait, text = " for the remote display: view; the uses of the remote display last until the machine stops"},
	{kind = .Remote_Display_Case, text = "view"},
	{kind = .Wait, text = "compositor: the capture face of remote_display is open: a copy of ", any_order = true},
	{kind = .Wait, text = "remote_display: a measure: the whole screen of ", any_order = true},
	{kind = .Remote_Display_Case, text = "compare"},
	{kind = .Remote_Display_Case, text = "small frames"},
	{kind = .Wait, text = "remote_display: a measure: frames of a small damage", any_order = true},
	// Input from a key of the view alone: the connection ends, and the
	// compositor received no key and no pointer of a viewer.
	{kind = .Remote_Display_Case, text = "input from a key of the view"},
	{kind = .Wait, text = " sent input, and principal 0 allowed it for the view only: nothing reaches the desktop, and the connection ends with the code Input_Not_Allowed", any_order = true},
	{kind = .Wait, text = " pictures, 0 keys and 0 pointer records of viewers, 0 refused commands", any_order = true},
	// A tile request one pixel past the screen.
	{kind = .Remote_Display_Case, text = "damaged request"},
	{kind = .Wait, text = ": it names a place outside the screen: the connection ends with the code Bad_Record", any_order = true},
	// A header one byte past the bound of a record of the viewer.
	{kind = .Remote_Display_Case, text = "past bound"},
	{kind = .Wait, text = ": it is past its bound: the connection ends with the code Too_Large", any_order = true},
	// The input: the key super of the viewer opens the palette, as the key
	// of the keyboard does, and Escape closes it.
	{kind = .Type, text = "remote_display_allow(\"{viewer key}\", \"view_and_input\")"},
	{kind = .Wait, text = " more uses: view and input"},
	{kind = .Remote_Display_Case, text = "super"},
	{kind = .Wait, text = "compositor: the first key of a viewer of the remote display goes along the path of the keys", any_order = true},
	{kind = .Wait, text = "compositor: the palette is open", any_order = true},
	{kind = .Remote_Display_Case, text = "escape"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	// The revocation in the middle of the session.
	{kind = .Type, text = "remote_disallow(\"{viewer key}\")"},
	{kind = .Wait, text = " ended (a revocation, or a lock of its session): the connection from 10.0.2.2 port ", any_order = true},
	{kind = .Remote_Display_Case, text = "revoked"},
	{kind = .Wait, text = "compositor: the capture face ended (the service closed it)"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

remote_display_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	return machine_test(part, scenario_remote_display[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_REMOTE_DISPLAY, exit_status = build.MACHINE_STOP_OK})
}
