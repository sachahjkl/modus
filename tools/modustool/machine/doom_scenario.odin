package machine

import "core:bytes"
import "core:fmt"
import "core:os"
import "core:strings"
import "modustool:build"
import "modustool:checks"
import "modustool:foundation"

// Native Doom (`doomgeneric`) machine test (src/md/features/doom.md):
// pre-populates the private store `doom` on the data disk with `freedoom1.wad`
// from `MODUS_FREEDOOM_WAD`, boots QEMU with virtio-sound-pci, starts `doom`,
// verifies rendering on the title screen, enters E1M1, holds forward movement
// and fire across 35 Hz tics via qmp_key_state_command (`Key_Down`/`Key_Up`),
// verifies live frame changes across title -> E1M1 -> moved screenshots, tests
// opt-in pointer lock acquisition and Super release, and prints measured FPS.

TEST_OUTPUT_DOOM :: foundation.BUILD_FOLDER + "/test_output_doom.txt"
TEST_DISK_DOOM :: foundation.BUILD_FOLDER + "/test_disk_doom.img"

// Environment variable set by flake.nix pointing to Freedoom Phase 1 IWAD.
FREEDOOM_WAD_VARIABLE :: "MODUS_FREEDOOM_WAD"

// Plan value: matches the store_blocks term of `doom` in start_grant_sets.odin.
DOOM_STORE_BLOCKS :: 12000

// PNG header magic for verifying saved screenshots.
@(private = "file", rodata)
PNG_SIGNATURE := [8]u8{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}

doom_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	wad_path := os.get_env(FREEDOOM_WAD_VARIABLE, context.temp_allocator)
	if wad_path == "" {
		fmt.eprintfln("modustool: the test part doom needs the variable %s: run the tool in a shell of the flake (src/md/features/doom.md)", FREEDOOM_WAD_VARIABLE)
		return false
	}
	wad_bytes, wad_err := os.read_entire_file(wad_path, context.temp_allocator)
	if wad_err != nil || len(wad_bytes) < 12 || string(wad_bytes[:4]) != "IWAD" {
		fmt.eprintfln("modustool: cannot read IWAD %s: %v", wad_path, wad_err)
		return false
	}
	objects := [?]build.Module_File{{"freedoom1.wad", wad_bytes}}
	image := build.data_disk_encode({name = "doom", limit = DOOM_STORE_BLOCKS, objects = objects[:]}, build.DATA_DISK_SIZE) or_return
	defer delete(image)
	if write_err := os.write_entire_file(TEST_DISK_DOOM, image); write_err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", TEST_DISK_DOOM, write_err)
		return false
	}
	fmt.printfln("modustool: %s: the store doom holds freedoom1.wad, %d bytes", TEST_DISK_DOOM, len(wad_bytes))

	sound_file := machine_file(TEST_OUTPUT_DOOM, SOUND_OUTPUT_SUFFIX)
	_ = os.remove(sound_file)

	steps := [?]Step {
		{kind = .Wait, text = "storage: ok, generation 2: 1 stores, 1 objects", any_order = true},
		{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true},
		{kind = .Launch, text = "doom"},
		{kind = .Wait, text = "doom: sound stream started; latency ", any_order = true},
		{kind = .Wait, text = "doom: ok, 640x400 window, ", any_order = true},
		{kind = .Wait, text = "display: doom" + WINDOW_TAKEN, any_order = true},
		{kind = .Shot, text = "doom_title"},
		// Navigate the Doom title menu into E1M1: open menu, New Game, Episode 1, Hurt Me Plenty.
		{kind = .Key, text = "ret"},
		{kind = .Key, text = "ret"},
		{kind = .Key, text = "ret"},
		{kind = .Key, text = "ret"},
		// Wait for the next 35-frame heartbeat so E1M1 renders past the screen melt wipe.
		{kind = .Wait, text = "doom: frame "},
		{kind = .Shot, text = "doom_e1m1"},
		// Hold forward movement and fire down across a full 35-tic window via qmp_key_state_command.
		{kind = .Key_Down, text = "up"},
		{kind = .Key_Down, text = "ctrl"},
		{kind = .Wait, text = "doom: frame "},
		{kind = .Key_Up, text = "ctrl"},
		{kind = .Key_Up, text = "up"},
		{kind = .Shot, text = "doom_moved"},
		// Verify opt-in pointer lock on surface click and guaranteed release via Super.
		{kind = .Click, inside_window = "doom", x = 320, y = 200},
		{kind = .Wait, text = "doom: pointer lock acquired (window request)"},
		{kind = .Key, text = "meta_l"},
		{kind = .Wait, text = "doom: pointer lock released (Super key)"},
		{kind = .Front, text = "console"},
		{kind = .Type, text = "shutdown()"},
		{kind = .Wait, text = "kernel: the machine stops with code 0"},
	}

	if !machine_test(part, steps[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_DOOM, exit_status = build.MACHINE_STOP_OK, data_disk = TEST_DISK_DOOM, sound_device = true}) {
		return false
	}

	// Clean up the large wave file captured during the run.
	_ = os.remove(machine_file(TEST_OUTPUT_DOOM, SOUND_OUTPUT_SUFFIX))

	// Print measured FPS lines from the rendered log.
	raw_log, log_err := os.read_entire_file(TEST_OUTPUT_DOOM, context.temp_allocator)
	if log_err != nil {
		fmt.eprintfln("modustool: cannot read %s: %v", TEST_OUTPUT_DOOM, log_err)
		return false
	}
	rendered, render_problem := checks.measure_log_rendered(string(raw_log))
	if render_problem != "" {
		fmt.eprintfln("modustool: cannot render facts of %s: %s", TEST_OUTPUT_DOOM, render_problem)
		return false
	}
	for line in strings.split_lines(rendered, context.temp_allocator) {
		if strings.contains(line, "doom: frame ") && strings.contains(line, " fps)") {
			fmt.printfln("modustool: measure: %s", strings.trim_space(line))
		}
	}

	if !part.skip_shots {
		title_png, title_err := os.read_entire_file(SCREENSHOT_FOLDER + "/doom_title.png", context.temp_allocator)
		e1m1_png, e1m1_err := os.read_entire_file(SCREENSHOT_FOLDER + "/doom_e1m1.png", context.temp_allocator)
		moved_png, moved_err := os.read_entire_file(SCREENSHOT_FOLDER + "/doom_moved.png", context.temp_allocator)
		if title_err != nil || e1m1_err != nil || moved_err != nil {
			fmt.eprintfln("modustool: doom screenshots missing after run")
			return false
		}
		for png_bytes in ([][]u8{title_png, e1m1_png, moved_png}) {
			if len(png_bytes) < len(PNG_SIGNATURE) || !bytes.equal(png_bytes[:len(PNG_SIGNATURE)], PNG_SIGNATURE[:]) {
				fmt.eprintfln("modustool: doom screenshot does not start with a valid PNG signature")
				return false
			}
		}
		if bytes.equal(title_png, e1m1_png) {
			fmt.eprintfln("modustool: test failed: doom_title.png and doom_e1m1.png are identical; Doom did not enter E1M1")
			return false
		}
		if bytes.equal(e1m1_png, moved_png) {
			fmt.eprintfln("modustool: test failed: doom_e1m1.png and doom_moved.png are identical; held movement/fire input did not change the frame")
			return false
		}
		foundation.test_passed_print("doom rendered distinct title (%d B), E1M1 (%d B), and post-movement (%d B) PNG frames", len(title_png), len(e1m1_png), len(moved_png))
	}
	return true
}

@(init)
doom_test_part_register :: proc "contextless" () {
	test_part_scenario_register("doom", doom_tests_run)
}
