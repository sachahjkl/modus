package machine

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "modustool:build"
import "modustool:foundation"

// `modustool run` argument parsing accepts Desktop, Console, and Remote_Display
// modes and refuses unknown options, duplicates, and conflicting combinations.
@(test)
run_arguments_parse_accepts_valid_modes_and_refuses_invalid :: proc(t: ^testing.T) {
	key := strings.repeat("a", PUBLIC_KEY_TEXT_LENGTH, context.temp_allocator)

	// Refusal cases first.
	refused := [][]string {
		{"--unknown"},
		{"-c"},
		{"extra"},
		{""},
		{"--console", "--console"},
		{"without_checks", "without_checks"},
		{"--remote-display"},
		{"--remote-display", key, "extra"},
		{"--remote-display", key, "--remote-display", key},
		{"--console", "--remote-display", key},
		{"--remote-display", key, "--console"},
		{"without_checks", "--remote-display", key},
		{"--remote-display", key, "without_checks"},
		{"--console", "unknown"},
	}
	for args in refused {
		_, problem := run_arguments_parse(args)
		testing.expectf(t, problem != "", "`run %v` is refused", args)
	}

	// Valid forms.
	opts, problem := run_arguments_parse(nil)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, opts, Run_Command_Options{mode = .Desktop, checks = true, viewer_key = ""})

	opts, problem = run_arguments_parse([]string{RUN_WITHOUT_CHECKS_WORD})
	testing.expect_value(t, problem, "")
	testing.expect_value(t, opts, Run_Command_Options{mode = .Desktop, checks = false, viewer_key = ""})

	opts, problem = run_arguments_parse([]string{RUN_CONSOLE_FLAG})
	testing.expect_value(t, problem, "")
	testing.expect_value(t, opts, Run_Command_Options{mode = .Console, checks = true, viewer_key = ""})

	opts, problem = run_arguments_parse([]string{RUN_CONSOLE_FLAG, RUN_WITHOUT_CHECKS_WORD})
	testing.expect_value(t, problem, "")
	testing.expect_value(t, opts, Run_Command_Options{mode = .Console, checks = false, viewer_key = ""})

	opts, problem = run_arguments_parse([]string{RUN_WITHOUT_CHECKS_WORD, RUN_CONSOLE_FLAG})
	testing.expect_value(t, problem, "")
	testing.expect_value(t, opts, Run_Command_Options{mode = .Console, checks = false, viewer_key = ""})

	opts, problem = run_arguments_parse([]string{RUN_REMOTE_DISPLAY_FLAG, key})
	testing.expect_value(t, problem, "")
	testing.expect_value(t, opts, Run_Command_Options{mode = .Remote_Display, checks = true, viewer_key = key})
}

// `machine_command` in console mode wires COM1 to the kernel log file, COM2 to
// stdio with signal=off, disables the display device and GUI window, omits the
// tablet, and refuses setting both test_output and console_log.
@(test)
console_machine_command_wires_com1_file_com2_stdio_and_no_window :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "console_run_test_*", context.temp_allocator)
	testing.expect_value(t, err, nil)
	defer os.remove_all(root)

	_ = os.make_directory_all(foundation.BUILD_FOLDER)

	// Provide temporary OVMF paths only if absent from the environment.
	ovmf_code_set := os.get_env("OVMF_CODE", context.temp_allocator) != ""
	ovmf_vars_set := os.get_env("OVMF_VARS", context.temp_allocator) != ""
	if !ovmf_code_set {
		code_path := fmt.tprintf("%s/ovmf_code.fd", root)
		_ = os.write_entire_file(code_path, "code")
		_ = os.set_env("OVMF_CODE", code_path)
	}
	if !ovmf_vars_set {
		vars_path := fmt.tprintf("%s/ovmf_vars.fd", root)
		_ = os.write_entire_file(vars_path, "vars")
		_ = os.set_env("OVMF_VARS", vars_path)
	}
	defer {
		if !ovmf_code_set {
			_ = os.unset_env("OVMF_CODE")
		}
		if !ovmf_vars_set {
			_ = os.unset_env("OVMF_VARS")
		}
	}

	build.boot_volume_ready_note(build.BOOT_VOLUME_CONSOLE)
	defer build.boot_volumes_ready_forget()

	data_disk := fmt.tprintf("%s/data.img", root)
	log_path := fmt.tprintf("%s/console.log", root)
	test_log := fmt.tprintf("%s/test.log", root)

	// Refusal: console_log cannot be combined with test_output.
	_, conflict_ok := machine_command(build.BOOT_VOLUME_CONSOLE, test_log, data_disk, nil, forward = {host_port = 18080}, console_log = log_path)
	testing.expect(t, !conflict_ok, "console_log and test_output together are refused")

	// Valid console command.
	command, ok := machine_command(build.BOOT_VOLUME_CONSOLE, "", data_disk, nil, forward = {host_port = 18080}, without_screen = true, console_log = log_path)
	if !testing.expect(t, ok, "console machine_command succeeds") {
		return
	}

	// Verify -vga none, -display none, no -vga virtio, no virtio-tablet-pci.
	vga_none, display_none, has_chardev := false, false, false
	serial_args := make([dynamic]string, context.temp_allocator)
	for index := 0; index < len(command); index += 1 {
		arg := command[index]
		testing.expectf(t, !strings.contains(arg, "virtio-tablet-pci"), "console mode omits tablet: %s", arg)
		if arg == "-vga" && index + 1 < len(command) {
			testing.expect_value(t, command[index + 1], "none")
			vga_none = true
		}
		if arg == "-display" && index + 1 < len(command) {
			testing.expect_value(t, command[index + 1], "none")
			display_none = true
		}
		if arg == "-chardev" && index + 1 < len(command) && command[index + 1] == "stdio,id=console_serial,signal=off" {
			has_chardev = true
		}
		if arg == "-serial" && index + 1 < len(command) {
			append(&serial_args, command[index + 1])
		}
	}
	testing.expect(t, vga_none, "console mode passes -vga none")
	testing.expect(t, display_none, "console mode passes -display none")
	testing.expect(t, has_chardev, "console mode defines stdio chardev with signal=off")
	testing.expect_value(t, len(serial_args), 2)
	if len(serial_args) == 2 {
		testing.expect_value(t, serial_args[0], strings.concatenate({"file:", log_path}, context.temp_allocator))
		testing.expect_value(t, serial_args[1], "chardev:console_serial")
	}
}

// The `release_image` machine test part is registered, boots only
// BOOT_VOLUME_SECURE_BOOT (which holds BOOT_IMAGE_RELEASE with Secure Boot on),
// and waits for Secure Boot verification and "root: the machine is usable".
@(test)
release_image_test_part_is_wired_to_secure_boot_release_volume :: proc(t: ^testing.T) {
	part, found := test_part_find("release_image")
	testing.expect(t, found, "release_image is in test_parts")
	if !found {
		return
	}
	testing.expect(t, part.run != nil, "release_image registers its scenario procedure")
	testing.expect_value(t, len(part.volumes), 1)
	if len(part.volumes) == 1 {
		testing.expect_value(t, part.volumes[0], build.BOOT_VOLUME_SECURE_BOOT)
	}
	testing.expect(t, !part.starts_no_machine, "release_image boots a machine")

	// BOOT_VOLUME_SECURE_BOOT uses BOOT_IMAGE_RELEASE with Secure Boot signed.
	volume_found := false
	for volume in build.boot_volumes() {
		if volume.path == build.BOOT_VOLUME_SECURE_BOOT {
			volume_found = true
			testing.expect_value(t, volume.image, build.BOOT_IMAGE_RELEASE)
			testing.expect_value(t, volume.firmware_signature, build.Firmware_Signature.Signed)
			testing.expect(t, volume.with_secure_boot_variables)
			testing.expect_value(t, build.boot_volume_release_problem(volume), "")
		}
	}
	testing.expect(t, volume_found, "BOOT_VOLUME_SECURE_BOOT is in boot_volumes")

	// Scenario waits for Secure Boot verification and "root: the machine is usable".
	has_secure_boot, has_usable, ends_with_quit := false, false, false
	steps := scenario_release_boot_image
	for step in steps {
		if step.kind == .Wait && step.text == SECURE_BOOT_VERIFIED_LINE {
			has_secure_boot = true
		}
		if step.kind == .Wait && strings.contains(step.text, "root: the machine is usable") {
			has_usable = true
		}
	}
	if len(steps) > 0 && steps[len(steps) - 1].kind == .Quit {
		ends_with_quit = true
	}
	testing.expect(t, has_secure_boot, "scenario waits for Secure Boot verification")
	testing.expect(t, has_usable, "scenario waits for usable machine")
	testing.expect(t, ends_with_quit, "scenario ends with Quit")

	// `release_image` is listed in test_part_files.json pointing to its file.
	manifest_bytes, read_err := os.read_entire_file("tools/modustool/machine/test_part_files.json", context.temp_allocator)
	testing.expect_value(t, read_err, nil)
	if read_err == nil {
		testing.expect(t, strings.contains(string(manifest_bytes), `"release_image": ["release_image_scenario.odin"]`), "test_part_files.json registers release_image_scenario.odin")
	}
	_ = slice.contains(part.procedures, "release_image_part_tests_run")
	testing.expect(t, slice.contains(part.procedures, "release_image_part_tests_run"), "part lists release_image_part_tests_run")
}
