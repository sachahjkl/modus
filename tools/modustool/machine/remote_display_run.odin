package machine

import "core:fmt"
import protocol "modus:contract/remote_display"
import "modustool:build"
import "modustool:foundation"

// A machine for a viewer on the host (src/md/features/remote_display.md,
// "A machine for a viewer on the host"): `modustool run --remote-display
// <viewer key>`. The machine runs as a test machine, with no window: its
// log goes to a file, the tool types through QEMU, and its network device
// goes to the peer, whose UDP relay reaches the port of remote_display. The
// scenario allows the viewer key for the view and the input in the console
// of principal 0, starts remote_display, prints the port of the relay and
// the key of the service, then waits until a viewer came and went, and
// stops the machine.

TEST_OUTPUT_REMOTE_DISPLAY_RUN :: foundation.BUILD_FOLDER + "/run_output_remote_display.txt"
// A viewer on the host connects when a person or a program starts it, and
// the machine waits for it: this bound ends only a run that no viewer used.
VIEWER_SESSION_BOUND_SECONDS :: 3600
// The 64 hexadecimal digits of an Ed25519 public key.
PUBLIC_KEY_TEXT_LENGTH :: 64

// public_key_text_is_valid says if a text is 64 hexadecimal digits.
public_key_text_is_valid :: proc(text: string) -> bool {
	if len(text) != PUBLIC_KEY_TEXT_LENGTH {
		return false
	}
	for character in transmute([]u8)text {
		switch character {
		case '0' ..= '9', 'a' ..= 'f', 'A' ..= 'F':
		case:
			return false
		}
	}
	return true
}

// viewer_relay_announce prints what a viewer on the host needs: the port of
// the relay, the line of the key of the service, and the command of the
// viewer. false: the key is not 64 hexadecimal digits.
viewer_relay_announce :: proc(machine: ^Machine, key_prefix: string, key: string) -> bool {
	if !public_key_text_is_valid(key) {
		return false
	}
	relay := &machine.peer.relay
	fmt.printfln("modustool: the UDP relay of the peer reaches the port %d of the machine at 127.0.0.1:%d", relay.machine_port, relay.port)
	fmt.printfln("%s%s", key_prefix, key)
	fmt.printfln("modustool: connect the viewer: viewertool machine %d %s", relay.port, key)
	return true
}

// remote_display_run runs the machine for a viewer on the host, and says if
// its scenario passed.
remote_display_run :: proc(viewer_key: string) -> bool {
	if !public_key_text_is_valid(viewer_key) {
		fmt.eprintfln("modustool: the viewer key \"%s\" is not 64 hexadecimal digits: `modus-viewer -print-key` prints it", viewer_key)
		return false
	}
	part := test_part_run_make("remote_display_run")
	defer test_part_run_free(&part)
	if !test_part_run_start(&part) {
		return false
	}
	// The scenario frees the temporary memory after each step: the typed
	// line lives in memory of its own.
	allow := fmt.aprintf("remote_display_allow(\"%s\", \"view_and_input\")", viewer_key)
	defer delete(allow)
	// The allow comes first, and the root service holds it with no
	// remote_display: the tool prints the port of the relay only when a
	// viewer that connects at once is allowed and the service listens.
	steps := [?]Step {
		{kind = .Wait, text = "compositor: surface console"},
		{kind = .Type, text = allow},
		{kind = .Wait, text = " for the remote display: view and input"},
		{kind = .Type, text = "start(\"remote_display\")"},
		{kind = .Wait, text = "root: started network"},
		{kind = .Wait, text = "network: an endpoint for remote_display: UDP, the listen port 7101", any_order = true},
		{kind = .Wait, text = "remote_display: listening on the UDP port 7101", any_order = true},
		// The key line comes before the line of the listen: the two Waits
		// above leave the place of the search after the start of network.
		{kind = .Viewer_Relay, text = "remote_display: the public key of this service: "},
		// The last viewer ended: the capture face closes.
		{kind = .Wait, text = "remote_display: no viewer: the capture face is closed", seconds = VIEWER_SESSION_BOUND_SECONDS},
		{kind = .Type, text = "shutdown()"},
		{kind = .Wait, text = "kernel: the machine stops with code 0"},
	}
	fmt.printfln("modustool: the log of the machine goes to %s; the machine has no window", TEST_OUTPUT_REMOTE_DISPLAY_RUN)
	part.passed = machine_test(&part, steps[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_REMOTE_DISPLAY_RUN, exit_status = build.MACHINE_STOP_OK, relay_machine_port = protocol.LISTEN_PORT})
	return part.passed
}
