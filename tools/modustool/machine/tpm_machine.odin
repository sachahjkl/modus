package machine

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"
import "modustool:foundation"

// The firmware and the software TPM of a test machine, and swtpm alone. The
// engine of a machine (machine_test) starts them for any part that asks, so
// they are of the core of the tool, not of a scenario file of one part.

// The firmware of a test machine. The TPM device is another option of the
// machine (machine_test, tpm_device): a firmware with a TPM driver and no
// device runs as on a machine with no TPM.
Machine_Firmware :: enum {
	Usual, // OVMF_CODE and OVMF_VARS: no TPM driver, no Secure Boot.
	With_Tpm_Driver, // OVMF_TPM_CODE and OVMF_TPM_VARS: a TPM driver, no Secure Boot, no system management mode.
	With_Secure_Boot, // OVMF_FULL_CODE with SECURE_BOOT_VARIABLES: the certificate of the firmware signing key enrolled, Secure Boot on, system management mode, a TPM driver.
}

// The steps of a machine of the TPM or of Secure Boot after "boot program:
// started", until the desktop: the firmware with system management mode is
// slow on a loaded host, and a command of the TPM that the firmware
// abandons costs it about two minutes. 300 s is the bound of each step; a
// refused measure ends the wait at once, with the line of the refusal.
TPM_MACHINE_STEP_SECONDS :: 300
MEASURE_REFUSED_LINE :: "boot program: the TPM refused the measure"

// The control command of swtpm that QEMU sends when the firmware abandons a
// command of the TPM before its answer (CMD_CANCEL_TPM_CMD): the trace of a
// time-out of the interface driver of the firmware.
SWTPM_CANCEL_COMMAND :: "00 00 00 09"

// The first wait of a machine with that firmware: for "boot program:
// started", by name, with its own bound. A boot that is slow under the load
// of the host says nothing about the trusted boot; the tool prints the time
// that it took.
TPM_MACHINE_FIRST_WAIT_SECONDS :: 600

// The log that the firmware writes on its debug console port, beside the
// log of the machine. The firmware of Nixpkgs is a release build: it writes
// few lines there.
FIRMWARE_LOG_SUFFIX :: "_firmware.log"
// The trace of QEMU for the TPM device of a machine of the TPM, each line
// with its time (main.odin, machine_command).
QEMU_TRACE_SUFFIX :: "_qemu_tpm_trace.log"
FIRMWARE_LOG_LINES_SHOWN :: 40

// The line of the firmware when it cannot start a boot option, as its boot
// manager writes it on the console (UefiBootManagerLib of EDK II).
FIRMWARE_LOAD_FAILURE_LINE :: "BdsDxe: failed to load Boot"

// machine_file gives a file of one test machine beside its log.
machine_file :: proc(output, suffix: string) -> string {
	return strings.concatenate({strings.trim_suffix(output, ".txt"), suffix}, context.temp_allocator)
}

// The software TPM of one machine: a folder of its own for each machine,
// with a new state, so that each starts with a TPM with no history and no
// file of another machine.
TPM_START_TIMEOUT :: foundation.HANG_BOUND // It only ends a start of swtpm that hangs.

tpm_folder_of :: proc(output: string) -> string {
	return machine_file(output, "_tpm")
}

tpm_socket_of :: proc(output: string) -> string {
	return strings.concatenate({tpm_folder_of(output), "/swtpm.socket"}, context.temp_allocator)
}

Tpm_Host_Process :: struct {
	host_process: os.Process,
	started: bool,
	folder:  string,
}

// tpm_start starts swtpm for the machine of this output, and waits until
// its control socket exists. --terminate ends it when QEMU closes the
// connection; tpm_stop ends it in each case. state is "" for a TPM with no
// history, in the folder of the machine; else the folder of a state that
// several machines of one test part share, as one TPM across restarts of
// one machine: the part makes it new once.
tpm_start :: proc(tpm: ^Tpm_Host_Process, output: string, state: string = "") -> bool {
	folder := tpm_folder_of(output)
	socket := tpm_socket_of(output)
	foundation.reset_folder(folder) or_return
	state_folder := state != "" ? state : folder
	log := strings.concatenate({"file=", folder, "/swtpm.log,level=20"}, context.temp_allocator)
	host_process, err := os.process_start({command = {"swtpm", "socket", "--tpm2", "--tpmstate", strings.concatenate({"dir=", state_folder}, context.temp_allocator), "--ctrl", strings.concatenate({"type=unixio,path=", socket}, context.temp_allocator), "--log", log, "--terminate"}, stdout = os.stderr, stderr = os.stderr})
	if err != nil {
		fmt.eprintfln("modustool: cannot start swtpm: %v. Use the development shell: nix develop", err)
		return false
	}
	tpm^ = {host_process = host_process, started = true, folder = strings.clone(folder)}
	start := time.tick_now()
	for !os.exists(socket) {
		if time.tick_since(start) > TPM_START_TIMEOUT {
			fmt.eprintfln("modustool: swtpm made no socket %s in %v", socket, TPM_START_TIMEOUT)
			tpm_stop(tpm)
			return false
		}
		time.sleep(CONDITION_POLL_PERIOD)
	}
	return true
}

// tpm_stop ends swtpm and waits for its end: the next machine never starts
// while it runs.
tpm_stop :: proc(tpm: ^Tpm_Host_Process) {
	if !tpm.started {
		return
	}
	_ = os.process_kill(tpm.host_process)
	_, _ = os.process_wait(tpm.host_process)
	tpm.started = false
	delete(tpm.folder)
	tpm.folder = ""
}

// tpm_traffic_report prints what the swtpm log of a machine of the TPM
// shows (docs/TRUSTED_BOOT.md, "The machines of the TPM"):
// - the count of TPM2_Startup commands: one for each start of the
//   firmware; two or more mean that the firmware reset the machine;
// - the count of commands that the firmware abandoned (QEMU sends the
//   control command "cancel"): each one is a command whose answer the
//   firmware did not take, after which it marks its TPM as absent;
// - the name of the last command before the first cancel.
tpm_traffic_report :: proc(output: string) {
	path := strings.concatenate({tpm_folder_of(output), "/swtpm.log"}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return
	}
	lines := strings.split_lines(string(data), context.temp_allocator)
	startups, cancels := 0, 0
	last_command, abandoned_command := "", ""
	for line, index in lines {
		trimmed := strings.trim_space(line)
		// "IsEnEnabled(0x17a = 'GetCapability'): 1": swtpm runs a command.
		if strings.has_prefix(trimmed, "IsEnEnabled(") {
			last_command = trimmed[len("IsEnEnabled("):]
			if end := strings.index_byte(last_command, ')'); end >= 0 {
				last_command = last_command[:end]
			}
			if strings.contains(last_command, "'Startup'") {
				startups += 1
			}
		}
		if strings.has_prefix(trimmed, "Ctrl Cmd:") && index + 1 < len(lines) && strings.trim_space(lines[index + 1]) == SWTPM_CANCEL_COMMAND {
			cancels += 1
			if abandoned_command == "" {
				abandoned_command = last_command
			}
		}
	}
	if cancels == 0 {
		fmt.printfln("modustool: the TPM of %s: %d Startup, 0 commands abandoned (%s)", output, startups, path)
	} else {
		fmt.printfln("modustool: the TPM of %s: %d Startup, %d commands abandoned; the first after the command %s (%s; the times are in %s)", output, startups, cancels, abandoned_command, path, machine_file(output, QEMU_TRACE_SUFFIX))
	}
}

// firmware_failure_report says what a machine with that firmware showed
// when a step failed, while QEMU still runs: a picture of its screen (a
// prompt or a menu of the firmware is there), then the end of the log of
// the firmware and of swtpm.
firmware_failure_report :: proc(machine: ^Machine, output: string) {
	name := machine_file(output, "_firmware_screen")
	name = name[strings.last_index_byte(name, '/') + 1:]
	_ = screen_save(machine, name)
	for path in ([]string{machine_file(output, FIRMWARE_LOG_SUFFIX), strings.concatenate({tpm_folder_of(output), "/swtpm.log"}, context.temp_allocator), machine_file(output, QEMU_TRACE_SUFFIX)}) {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			fmt.eprintfln("modustool: %s: none (%v)", path, err)
			continue
		}
		lines := strings.split_lines(string(data), context.temp_allocator)
		fmt.eprintfln("modustool: the end of %s (%d bytes):", path, len(data))
		for line in lines[max(len(lines) - FIRMWARE_LOG_LINES_SHOWN, 0):] {
			fmt.eprintln("   ", line)
		}
	}
}

// The lines of the boot program and of unlock that the parts of the TPM
// wait for.
MEASURE_LINE :: "boot program: PCR 11 = "
// The line of the boot program that says who verified it: the firmware
// with Secure Boot, or the boot program alone.
SECURE_BOOT_VERIFIED_LINE :: "boot program: verified by the firmware (Secure Boot), then by the boot program"
BOOT_PROGRAM_ONLY_VERIFIED_LINE :: "boot program: verified by the boot program, which the firmware did not verify"
// The line of unlock at Enter on a new recovery key: no record, no file,
// no key of a table and no session comes before it
// (src/md/features/tpm_sealed_principal_keys.md).
RECOVERY_KEY_ENTER_LINE :: "unlock: Enter on the recovery key: it is written down, and the record or the file that holds its copy is written now"

// The largest answer to a command that the tool sends to the TPM.
TPM_TOOL_ANSWER_LIMIT :: 256

// A software TPM that runs alone, with no QEMU, on a state of the software
// TPM of a part: the tool sends it the commands that another system on the
// machine can send.
Tpm_Alone :: struct {
	tpm:        Tpm_Host_Process,
	connection: linux.Fd, // The Unix socket of the commands, in the folder of the output.
}

// The Unix sockets of swtpm alone, in the folder of its output: no port of
// the loopback, which a machine of another part that runs at the same time
// could hold.
TPM_ALONE_SERVER_SOCKET :: "/server.socket"
TPM_ALONE_CONTROL_SOCKET :: "/control.socket"

// tpm_alone_start starts swtpm alone on a state of the software TPM, in the
// folder of the output given, and connects to its socket of the commands.
tpm_alone_start :: proc(state_folder: string, output: string) -> (alone: Tpm_Alone, ok: bool) {
	folder := tpm_folder_of(output)
	foundation.reset_folder(folder) or_return
	log := strings.concatenate({"file=", folder, "/swtpm.log,level=20"}, context.temp_allocator)
	server_path := strings.concatenate({folder, TPM_ALONE_SERVER_SOCKET}, context.temp_allocator)
	server := strings.concatenate({"type=unixio,path=", server_path}, context.temp_allocator)
	control := strings.concatenate({"type=unixio,path=", folder, TPM_ALONE_CONTROL_SOCKET}, context.temp_allocator)
	// not-need-init and startup-clear: swtpm starts the TPM itself, as the
	// firmware of a machine does, with no QEMU.
	host_process, start_error := os.process_start({command = {"swtpm", "socket", "--tpm2", "--tpmstate", strings.concatenate({"dir=", state_folder}, context.temp_allocator), "--server", server, "--ctrl", control, "--flags", "not-need-init,startup-clear", "--log", log}, stdout = os.stderr, stderr = os.stderr})
	if start_error != nil {
		fmt.eprintfln("modustool: cannot start swtpm: %v. Use the development shell: nix develop", start_error)
		return {}, false
	}
	alone.tpm = Tpm_Host_Process{host_process = host_process, started = true, folder = strings.clone(folder)}

	// Wait until swtpm takes a connection.
	start := time.tick_now()
	for {
		connection, connected := call_socket_connect(server_path)
		if connected {
			alone.connection = connection
			break
		}
		if time.tick_since(start) > TPM_START_TIMEOUT {
			fmt.eprintfln("modustool: test failed: swtpm took no connection at %s in %v", server_path, TPM_START_TIMEOUT)
			tpm_stop(&alone.tpm)
			return {}, false
		}
		time.sleep(CONDITION_POLL_PERIOD)
	}
	return alone, true
}

// tpm_alone_stop closes the connection and ends swtpm, which writes its
// state.
tpm_alone_stop :: proc(alone: ^Tpm_Alone) {
	call_socket_close(alone.connection)
	tpm_stop(&alone.tpm)
}

// tpm_alone_transact sends one command and gives its whole answer, in the
// buffer given: the size of its header bounds it. what names the command in
// a line of a failure.
tpm_alone_transact :: proc(alone: ^Tpm_Alone, command: []u8, answer: []u8, what: string) -> (bytes: []u8, ok: bool) {
	if len(command) == 0 || !call_socket_send_all(alone.connection, command) {
		fmt.eprintfln("modustool: test failed: the command %s did not go to swtpm (%s)", what, alone.tpm.folder)
		return nil, false
	}
	// The header of an answer has its size in bytes 2 to 5, big-endian.
	HEADER_SIZE :: 10
	received := 0
	size := HEADER_SIZE
	// The receive of the socket ends after its own short time with no byte;
	// the bound only ends a wait for a TPM that does not answer.
	start := time.tick_now()
	for received < size {
		got, receive_error := linux.recv(alone.connection, answer[received:size], {})
		if (receive_error == .EAGAIN || receive_error == .EINTR) && time.tick_since(start) < foundation.HANG_BOUND {
			continue
		}
		if receive_error != .NONE || got <= 0 {
			fmt.eprintfln("modustool: test failed: swtpm gave %d bytes of an answer of %d to %s: %v (%s)", received, size, what, receive_error, alone.tpm.folder)
			return nil, false
		}
		received += got
		if received >= HEADER_SIZE && size == HEADER_SIZE {
			size = int(u32(answer[2]) << 24 | u32(answer[3]) << 16 | u32(answer[4]) << 8 | u32(answer[5]))
			if size < HEADER_SIZE || size > len(answer) {
				fmt.eprintfln("modustool: test failed: swtpm gave an answer of %d bytes to %s (%s)", size, what, alone.tpm.folder)
				return nil, false
			}
		}
	}
	return answer[:size], true
}
