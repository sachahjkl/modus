package machine

import "modustool:build"
import "modustool:foundation"

// The screen through the scanout of the virtual GPU
// (src/md/infrastructure/whole_frame.md, "The screen through the scanout of
// the virtual GPU"): the machine has the display device of the machine of
// a person, the VirtIO-GPU with its VGA part, and a display of VNC with no
// window. The root service starts gpu_device, the compositor takes the
// scanout, and the first frame goes to the device in one batch. Then a
// viewer of remote_display rebuilds the screen from the frames of the
// compositor, and the tool compares it with a picture of QEMU of the same
// moment, which reads what the transfers of the scanout wrote: the first
// whole frame, then the frames of a small damage of a line typed in the
// console before the viewer came.

TEST_OUTPUT_GPU_SCANOUT :: foundation.BUILD_FOLDER + "/test_output_gpu_scanout.txt"

// The line of the compositor when a present of the scanout is refused: it
// fails each later wait of the part.
GPU_SCANOUT_ENDED :: "compositor: the scanout of the virtual GPU ended"

scenario_gpu_scanout := [?]Step {
	{kind = .Wait, text = "root: started gpu_device for the GPU at PCI device "},
	{kind = .Wait, text = "gpu_device: ok, scanout 0 at ", any_order = true},
	{kind = .Wait, text = "compositor: the screen is the scanout of the virtual GPU, resource "},
	{kind = .Wait, text = "gpu_device: the first frame of resource ", any_order = true, fails_on = GPU_SCANOUT_ENDED},
	{kind = .Wait, text = "compositor: surface console", fails_on = GPU_SCANOUT_ENDED},
	// A line in the console: frames of a small damage, each one batch of
	// its rectangles, before any viewer.
	{kind = .Type, text = "1 + 1"},
	{kind = .Type, text = "start(\"remote_display\")"},
	{kind = .Wait, text = "root: started network"},
	{kind = .Wait, text = "network: an endpoint for remote_display: UDP, the listen port 7101", any_order = true},
	{kind = .Remote_Display_Key, text = "remote_display: the public key of this service: "},
	{kind = .Wait, text = "remote_display: listening on the UDP port 7101, for the host 10.0.2.2 only, and for the viewer keys that a principal allowed", any_order = true},
	{kind = .Type, text = "remote_display_allow(\"{viewer key}\", \"view\")"},
	{kind = .Wait, text = " for the remote display: view"},
	// The whole screen of the compositor, with the line and its answer
	// that small frames put on the scanout: the screen that the viewer
	// rebuilt is the picture of QEMU.
	{kind = .Remote_Display_Case, text = "view"},
	{kind = .Wait, text = "compositor: the capture face is open: a copy of ", any_order = true},
	{kind = .Remote_Display_Case, text = "compare"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0", fails_on = GPU_SCANOUT_ENDED},
}

gpu_scanout_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	return machine_test(part, scenario_gpu_scanout[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_GPU_SCANOUT, exit_status = build.MACHINE_STOP_OK, gpu_scanout = true, vnc = true})
}

// A binary of the tool runs the test part gpu_scanout only when it holds
// this file (test_parts.odin, test_part_scenario_register).
@(init)
gpu_scanout_test_part_register :: proc "contextless" () {
	test_part_scenario_register("gpu_scanout", gpu_scanout_tests_run)
}
