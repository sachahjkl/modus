package machine

import "core:fmt"
import "core:os"
import "core:strings"
import "modustool:build"
import "modustool:foundation"

// The console image on QEMU (src/md/features/console_renderers.md,
// "The console image on QEMU"): `modustool run --console` boots
// BOOT_VOLUME_CONSOLE with no display device and no window, sends the kernel
// log on COM1 to CONSOLE_RUN_LOG, and connects COM2 (serial_terminal) directly
// to the developer's terminal.

CONSOLE_RUN_LOG :: foundation.BUILD_FOLDER + "/run_console_log.txt"

RUN_CONSOLE_FLAG :: "--console"
RUN_REMOTE_DISPLAY_FLAG :: "--remote-display"
RUN_WITHOUT_CHECKS_WORD :: "without_checks"

RUN_COMMAND_USAGE :: "run [without_checks] | run --console [without_checks] | run --remote-display <viewer key>"

// Run_Mode is the execution mode of `modustool run`.
Run_Mode :: enum {
	Desktop,
	Remote_Display,
	Console,
}

// Run_Command_Options holds the parsed arguments of `modustool run`.
Run_Command_Options :: struct {
	mode:       Run_Mode,
	checks:     bool,
	viewer_key: string,
}

// run_arguments_parse parses the arguments of `modustool run` and refuses
// unknown flags, duplicate options, conflicting modes, and missing or invalid
// viewer keys before any build starts.
run_arguments_parse :: proc(args: []string) -> (options: Run_Command_Options, problem: string) {
	options.mode = .Desktop
	options.checks = true
	checks_set := false
	mode_set := false
	for index := 0; index < len(args); index += 1 {
		argument := args[index]
		switch {
		case argument == RUN_WITHOUT_CHECKS_WORD:
			if checks_set {
				return {}, "run: `without_checks` is written two times; the form: `" + RUN_COMMAND_USAGE + "`"
			}
			if options.mode == .Remote_Display {
				return {}, "run: `without_checks` cannot be combined with `--remote-display`; the form: `" + RUN_COMMAND_USAGE + "`"
			}
			options.checks = false
			checks_set = true
		case argument == RUN_CONSOLE_FLAG:
			if mode_set {
				if options.mode == .Console {
					return {}, "run: `--console` is written two times; the form: `" + RUN_COMMAND_USAGE + "`"
				}
				return {}, "run: `--console` cannot be combined with `--remote-display`; the form: `" + RUN_COMMAND_USAGE + "`"
			}
			options.mode = .Console
			mode_set = true
		case argument == RUN_REMOTE_DISPLAY_FLAG:
			if mode_set {
				if options.mode == .Remote_Display {
					return {}, "run: `--remote-display` is written two times; the form: `" + RUN_COMMAND_USAGE + "`"
				}
				return {}, "run: `--remote-display` cannot be combined with `--console`; the form: `" + RUN_COMMAND_USAGE + "`"
			}
			if checks_set {
				return {}, "run: `--remote-display` cannot be combined with `without_checks`; the form: `" + RUN_COMMAND_USAGE + "`"
			}
			if index + 1 >= len(args) {
				return {}, "run --remote-display <viewer key>: the viewer key is the 64 hexadecimal digits that `modus-viewer -print-key` prints"
			}
			index += 1
			options.mode = .Remote_Display
			options.viewer_key = args[index]
			mode_set = true
		case strings.has_prefix(argument, "-"):
			return {}, fmt.tprintf("run: unknown option `%s`; the form: `%s`", argument, RUN_COMMAND_USAGE)
		case:
			return {}, fmt.tprintf("run: unexpected argument `%s`; the form: `%s`", argument, RUN_COMMAND_USAGE)
		}
	}
	return options, ""
}

// console_machine_run starts the console image under QEMU with no window:
// COM1 writes the kernel log to CONSOLE_RUN_LOG and COM2 connects directly to
// the developer's terminal.
console_machine_run :: proc() -> bool {
	if !disk_prepare(DATA_DISK, build.DATA_DISK_SIZE, false) {
		return false
	}
	peer: Peer
	if !peer_start(&peer, CALL_SOCKET_RUN_NAME) {
		return false
	}
	peer.remote.keys_from_calls = true
	defer peer_stop(&peer)
	command, ok := machine_command(build.BOOT_VOLUME_CONSOLE, "", DATA_DISK, &peer, without_screen = true, console_log = CONSOLE_RUN_LOG)
	if !ok {
		return false
	}
	fmt.printfln("modustool: console mode: COM2 is on this terminal; the kernel log on COM1 goes to %s", CONSOLE_RUN_LOG)
	// QEMU owns stdin and stdout directly so its stdio chardev puts the
	// terminal in raw mode for ANSI 24-bit output and VT100 key input on COM2.
	host_process, start_error := os.process_start({command = command, stdin = os.stdin, stdout = os.stdout, stderr = os.stderr})
	if start_error != nil {
		fmt.eprintfln("modustool: cannot start %s: %v", command[0], start_error)
		return false
	}
	state, wait_error := os.process_wait(host_process)
	if wait_error != nil {
		fmt.eprintfln("modustool: wait for %s failed: %v", command[0], wait_error)
		return false
	}
	if state.exit_code != 0 && state.exit_code != build.MACHINE_STOP_OK {
		fmt.eprintfln("modustool: %s failed (code %d)", command[0], state.exit_code)
		return false
	}
	return true
}
