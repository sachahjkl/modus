package machine

import "modustool:build"
import "modustool:foundation"

// The path of a wide grant, end to end (src/md/features/wide_grants.md,
// "The path of a grant, end to end"), on one machine: the peer of the tool
// is the agent, with its own client key, through `remote`, and a viewer of
// `remote_display` with a key of its own. The machine passphrase is set
// first: principal 0 proves each grant with it.
//
//   1. The agent asks through `remote` (the stream Wide_Grant_Ask); a
//      second ask while the screen shows is refused. Enter on the trusted
//      display gives the grant, with the window in front ticked; `unlock`
//      takes the passphrase on the keys of the machine; the root service
//      mints the proof, the collector of principal 0 creates the grant, and
//      the root service wires the act records. A call under the grant runs
//      only once its record left.
//   2. A viewer key while another window is in front leaves the bound: the
//      trusted display refuses it.
//   3. Control, Shift and Escape revoke the grant; `remote` ends the
//      connection of the agent with the code Revoked; the next call runs
//      with the grant to call alone. The collector keeps the act records of
//      each writer in its audit spaces, and each chain verifies.
//   4. A grant of 15 seconds ends by its time.
//   5. A new connection of the agent while its old one is open ends the
//      grant: a reconnect before `remote` ends the old connection at its
//      idle bound counts as a second connection.
//   6. A refused screen pauses the key: its next ask is refused.
//
// Not here: the end by a lock, since a lock of principal 0 stops the
// console that drives the machine (ROADMAP.md); a full ring of act
// records, which the space of each writer, thousands of records, never
// lets fill on a machine (act_wiring_test.odin, "a full act space never
// blocks the end of its grant").

TEST_OUTPUT_WIDE_GRANT :: foundation.BUILD_FOLDER + "/test_output_wide_grant.txt"

scenario_wide_grant := [?]Step {
	{kind = .Wait, text = "compositor: surface console"},
	// The machine passphrase, which proves a grant of principal 0.
	{kind = .Type, text = "machine_passphrase()"},
	{kind = .Wait, text = "root: the machine passphrase is set in the window of unlock"},
	{kind = .Wait, text = "display: unlock" + WINDOW_TAKEN, any_order = true},
	{kind = .Front, text = "unlock"},
	{kind = .Type, text = MACHINE_PASSPHRASE},
	{kind = .Type, text = MACHINE_PASSPHRASE},
	{kind = .Wait, text = "unlock: the machine passphrase is set: the machine key is sealed in the store of unlock under a key of Argon2id, 19456 KiB and 2 passes, derived in "},
	{kind = .Wait, text = "root: unlock stopped: itself, done", any_order = true},
	// The agent: the peer, whose key principal 0 allows from its console.
	{kind = .Front, text = "console"},
	{kind = .Launch, text = "remote"},
	{kind = .Wait, text = "root: started remote", any_order = true},
	{kind = .Remote_Key, text = "remote: the public key of this service: "},
	{kind = .Wait, text = "remote: listening on the UDP port 7100, for the host 10.0.2.2 only, and for the client keys that a principal allowed", any_order = true},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "remote_allow(\"{client key}\")"},
	{kind = .Wait, text = "root: principal 0 allowed the client key "},
	{kind = .Call, text = "monitor.processes()", expected = "remote"},
	// The viewer, allowed to send input.
	{kind = .Type, text = "start(\"remote_display\")"},
	{kind = .Remote_Display_Key, text = "remote_display: the public key of this service: "},
	{kind = .Wait, text = "remote_display: listening on the UDP port 7101, for the host 10.0.2.2 only, and for the viewer keys that a principal allowed", any_order = true},
	{kind = .Type, text = "remote_display_allow(\"{viewer key}\", \"view_and_input\")"},
	{kind = .Wait, text = " for the remote display: view_and_input"},

	// 1. The ask of the agent: no key and no principal in the stream; the
	// first screen of the run.
	{kind = .Ask_Wide_Grant, text = "view_and_input", milliseconds = 60 * 60 * 1000, expected = "1"},
	{kind = .Wait, text = "root: the trusted display shows the screen 1 of a wide grant of principal 0"},
	// A second ask while the first flow runs: refused, Busy.
	{kind = .Ask_Wide_Grant, text = "view", milliseconds = 60 * 1000, outcome = .Refused},
	// The screen takes the keys of the machine: Enter gives the grant, with
	// the window in front, the console, ticked, and the two scopes of the
	// ask.
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "root: started unlock"},
	{kind = .Wait, text = "unlock: the passphrase of principal 0 is asked for a wide grant"},
	{kind = .Wait, text = "display: unlock" + WINDOW_TAKEN, any_order = true},
	{kind = .Front, text = "unlock"},
	{kind = .Type, text = MACHINE_PASSPHRASE},
	{kind = .Wait, text = "unlock: the passphrase of principal 0 proved a wide grant"},
	{kind = .Wait, text = "root: the wide grant 1 of principal 0 holds, with 2 writers of act records"},
	// A call under the grant: it runs, so its record left to the collector.
	{kind = .Call, text = "monitor.processes()", expected = "collector"},

	// 2. Another window in front, out of the bound: a key of the viewer
	// goes nowhere.
	{kind = .Launch, text = "settings"},
	{kind = .Wait, text = "display: settings" + WINDOW_TAKEN, any_order = true},
	{kind = .Remote_Display_Case, text = "escape"},
	{kind = .Wait, text = "compositor: the wide grant 1 refused an input of a viewer out of its windows"},

	// 3. The revocation on the keys of the machine, in one press.
	{kind = .Key, text = "ctrl-shift-esc"},
	{kind = .Wait, text = "compositor: the principal pressed revoke on the wide grant 1"},
	{kind = .Wait, text = "root: the wide grant 1 of principal 0 ended: reason 1"},
	{kind = .Wait, text = " ended (a revocation, or a lock of its session): the connection from 10.0.2.2 port ", any_order = true},
	// The next call, on a new connection: the grant to call holds alone.
	{kind = .Call, text = "monitor.processes()", expected = "remote"},
	// The act records in the collector of principal 0: the spaces of the
	// root service, of remote and of the trusted display, each chain whole
	// up to the store.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"collector\")"},
	{kind = .Wait, text = "[console]   module     collector"},
	{kind = .Type, text = "collector.space_verify(1)"},
	{kind = .Wait, text = "[console] 0"},
	{kind = .Type, text = "collector.space_verify(2)"},
	{kind = .Wait, text = "[console] 0"},
	{kind = .Type, text = "collector.space_verify(3)"},
	{kind = .Wait, text = "[console] 0"},
	{kind = .Type, text = "collector.spaces()"},
	{kind = .Wait, text = "acts"},

	// 4. A grant of 15 seconds ends by its time, with no step of the
	// principal.
	{kind = .Ask_Wide_Grant, text = "view", milliseconds = 15 * 1000, expected = "2"},
	{kind = .Wait, text = "root: the trusted display shows the screen 2 of a wide grant of principal 0"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "unlock: the passphrase of principal 0 is asked for a wide grant"},
	{kind = .Wait, text = "display: unlock" + WINDOW_TAKEN, any_order = true},
	{kind = .Front, text = "unlock"},
	{kind = .Type, text = MACHINE_PASSPHRASE},
	{kind = .Wait, text = "unlock: the passphrase of principal 0 proved a wide grant"},
	{kind = .Wait, text = "root: the wide grant 2 of principal 0 holds, with "},
	{kind = .Wait, text = "root: the wide grant 2 of principal 0 ended: reason 5"},

	// 5. A second connection of the agent ends the grant.
	{kind = .Front, text = "console"},
	{kind = .Ask_Wide_Grant, text = "view_and_input", milliseconds = 60 * 60 * 1000, expected = "3"},
	{kind = .Wait, text = "root: the trusted display shows the screen 3 of a wide grant of principal 0"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "unlock: the passphrase of principal 0 is asked for a wide grant"},
	{kind = .Wait, text = "display: unlock" + WINDOW_TAKEN, any_order = true},
	{kind = .Front, text = "unlock"},
	{kind = .Type, text = MACHINE_PASSPHRASE},
	{kind = .Wait, text = "unlock: the passphrase of principal 0 proved a wide grant"},
	{kind = .Wait, text = "root: the wide grant 3 of principal 0 holds, with 2 writers of act records"},
	{kind = .Call, text = "monitor.processes()", expected = "collector"},
	{kind = .Remote_Case, text = "reconnect under a wide grant"},
	{kind = .Wait, text = "remote: a second connection of the client key ", any_order = true},
	{kind = .Wait, text = "root: the wide grant 3 of principal 0 ended: reason 3"},

	// 6. A refused screen: the key pauses, and its next ask is refused.
	{kind = .Ask_Wide_Grant, text = "view", milliseconds = 60 * 1000, expected = "4"},
	{kind = .Wait, text = "root: the trusted display shows the screen 4 of a wide grant of principal 0"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "root: principal 0 refused the screen of a wide grant"},
	{kind = .Ask_Wide_Grant, text = "view", milliseconds = 60 * 1000, outcome = .Refused},

	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

wide_grant_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	return machine_test(part, scenario_wide_grant[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_WIDE_GRANT, exit_status = build.MACHINE_STOP_OK})
}

// A binary of the tool runs the test part wide_grant only when it holds
// this file (test_parts.odin, test_part_scenario_register).
@(init)
wide_grant_test_part_register :: proc "contextless" () {
	test_part_scenario_register("wide_grant", wide_grant_tests_run)
}
