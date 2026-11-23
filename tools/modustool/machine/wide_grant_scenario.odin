package machine

import "modustool:build"
import "modustool:foundation"

// The path of a wide grant, end to end (src/md/features/wide_grants.md,
// "The path of a grant, end to end"), on one machine: the peer of the tool
// is the agent, with its own client key, through `remote`. The machine
// passphrase is set first: principal 0 proves its grant with it. Then the
// agent asks for a grant through `remote` (the stream Wide_Grant_Ask);
// the trusted display shows the screen, and Enter gives it; `unlock` asks
// for the machine passphrase in its window, which takes the keys of the
// machine only; the root service mints the proof, the collector of
// principal 0 creates the grant, and the root service wires the act records
// of `remote` and of the trusted display to it. A call of the agent under
// the grant runs only once its record left: a call that runs proves a
// reader of its record. Control, Shift and Escape on the keys of the
// machine revoke the grant; `remote` ends the connection of the agent with
// the code Revoked, and the next call, on a new connection, runs with the
// grant to call alone.
//
// A full ring of act records cannot be forced here: the space of each
// writer holds thousands of records, and the collector stops reading a ring
// while its space has room for one ring only. The host tests of
// wide_grants check it (act_wiring_test.odin, "a full act space never
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
	// The ask of the agent: no key and no principal in the stream; the
	// first screen of the run.
	{kind = .Ask_Wide_Grant, text = "view_and_input", milliseconds = 60 * 60 * 1000, expected = "1"},
	{kind = .Wait, text = "remote: the client key ", any_order = true},
	{kind = .Wait, text = "root: the trusted display shows the screen 1 of a wide grant of principal 0"},
	// A second ask while the first flow runs: refused, Busy.
	{kind = .Ask_Wide_Grant, text = "view", milliseconds = 60 * 1000, outcome = .Refused},
	// The screen takes the keys of the machine: Enter gives the grant, with
	// the window in front ticked and the two scopes of the ask.
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
	// The revocation on the keys of the machine, in one press.
	{kind = .Key, text = "ctrl-shift-esc"},
	{kind = .Wait, text = "compositor: the principal pressed revoke on the wide grant 1"},
	{kind = .Wait, text = "root: the wide grant 1 of principal 0 ended: reason 1"},
	{kind = .Wait, text = " ended (a revocation, or a lock of its session): the connection from 10.0.2.2 port ", any_order = true},
	// The next call, on a new connection: the grant to call holds alone.
	{kind = .Call, text = "monitor.processes()", expected = "remote"},
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
