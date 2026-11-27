package machine

import "modustool:build"
import "modustool:foundation"

// The path of a wide grant, end to end (src/md/features/wide_grants.md,
// "The path of a grant, end to end"), on two machines: the peer of the tool
// is the agent, with its own client key, through `remote`, and a viewer of
// `remote_display` with a key of its own.
//
// Machine 1 (principal 0 with the machine passphrase):
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
// Machine 2 (named principal 1 "alice", locked from principal 0's console):
//
//   Principal 0 starts `remote` and `remote_display` and creates principal 1
//   "alice". A session console of alice allows the agent and viewer keys and
//   closes so principal 0's boot console drives the lock without stopping.
//   The agent and viewer connect for principal 1, the agent obtains a wide
//   grant proved by alice's passphrase, and a call and viewer frame run under
//   the grant. Principal 0's console runs `lock()`: the grant ends with
//   `Session_Locked` (reason 4), `remote` and `remote_display` end both
//   connections with Revoked and refuse new handshakes while locked, the
//   collector persists its end record before stopping, storage erases
//   principal 1's keys, and alice's session ends with zero faults while
//   principal 0's console stays alive. Unlocking alice again reloads her
//   encrypted audit spaces and verifies all three chains.
//
// Not here: a full ring of act records, which the space of each writer,
// thousands of records, never lets fill on a machine (act_wiring_test.odin,
// "a full act space never blocks the end of its grant").

TEST_OUTPUT_WIDE_GRANT :: foundation.BUILD_FOLDER + "/test_output_wide_grant.txt"
TEST_OUTPUT_WIDE_GRANT_LOCK :: foundation.BUILD_FOLDER + "/test_output_wide_grant_lock.txt"
TEST_WIDE_GRANT_LOCK_DISK :: foundation.BUILD_FOLDER + "/test_wide_grant_lock_disk.img"

scenario_wide_grant := [?]Step {
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Wait, text = "root: unlock stopped: itself, done", any_order = true},
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
	// monitor starts on demand and opens a window in front: bring console back before typing.
	{kind = .Front, text = "console"},
	// The viewer, allowed to send input.
	{kind = .Type, text = "start(\"remote_display\")"},
	{kind = .Remote_Display_Key, text = "remote_display: the public key of this service: "},
	{kind = .Wait, text = "remote_display: listening on the UDP port 7101, for the host 10.0.2.2 only, and for the viewer keys that a principal allowed", any_order = true},
	{kind = .Type, text = "remote_display_allow(\"{viewer key}\", \"view_and_input\")"},
	{kind = .Wait, text = " for the remote display: view and input"},

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
	{kind = .Wait, text = "root: the wide grant 1 of principal 0 ended: reason 1", any_order = true},
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

scenario_wide_grant_lock := [?]Step {
	{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true},
	{kind = .Wait, text = "unlock: no named principal: the machine runs as principal 0, with no unlock", any_order = true},
	{kind = .Wait, text = "root: unlock stopped: itself, done"},
	// Start the machine-scope remote services from principal 0's boot console.
	{kind = .Front, text = "console"},
	{kind = .Launch, text = "remote"},
	{kind = .Wait, text = "root: started remote", any_order = true},
	{kind = .Remote_Key, text = "remote: the public key of this service: "},
	{kind = .Wait, text = "remote: listening on the UDP port 7100, for the host 10.0.2.2 only, and for the client keys that a principal allowed", any_order = true},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"remote_display\")"},
	{kind = .Remote_Display_Key, text = "remote_display: the public key of this service: "},
	{kind = .Wait, text = "remote_display: listening on the UDP port 7101, for the host 10.0.2.2 only, and for the viewer keys that a principal allowed", any_order = true},

	// Create named principal 1 "alice" from principal 0's boot console.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "principal_create(\"alice\")"},
	{kind = .Wait, text = "root: started unlock"},
	{kind = .Wait, text = "display: unlock" + WINDOW_TAKEN, any_order = true},
	{kind = .Front, text = "unlock"},
	{kind = .Type, text = PRINCIPAL_PASSPHRASE},
	{kind = .Type, text = PRINCIPAL_PASSPHRASE},
	{kind = .Wait, text = "root: principal 1 \"alice\" is recorded, its public key ", any_order = true},
	{kind = .Wait, text = "root: unlock stopped: itself, done", any_order = true},
	{kind = .Wait, text = "root: the session of principal 1 \"alice\" starts: the desktop starts each process in it"},
	{kind = .Wait, text = "root: the disk grant table of principal 1 is written in the store module_files: 0 rows, with the tag of the key of the principal"},

	// Start a console in alice's session to allow the agent and viewer keys
	// for principal 1, then close it so principal 0's boot console is the sole
	// console window driving the lock.
	{kind = .Launch, text = "console"},
	{kind = .Wait, text = "root: started console, with a terminal, in the session of principal 1 \"alice\""},
	{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "remote_allow(\"{client key}\")"},
	{kind = .Wait, text = "root: principal 1 allowed the client key "},
	{kind = .Type, text = "remote_display_allow(\"{viewer key}\", \"view_and_input\")"},
	{kind = .Wait, text = " for the remote display: view and input"},
	{kind = .Close, text = "console"},
	{kind = .Wait, text = "root: console stopped: "},

	// Connect both the agent (`remote`) and the viewer (`remote_display`) for principal 1.
	{kind = .Call, text = "monitor.processes()", expected = "remote"},
	{kind = .Wait, text = "root: connected remote to the service monitor, acting for principal 1, for the client key ", any_order = true},
	{kind = .Wait, text = "display: monitor" + WINDOW_TAKEN, any_order = true},
	{kind = .Remote_Display_Case, text = "view"},
	{kind = .Wait, text = "compositor: the capture face is open: a copy of ", any_order = true},

	// Ask for and approve a wide grant of principal 1, proved by alice's passphrase.
	{kind = .Ask_Wide_Grant, text = "view_and_input", milliseconds = 60 * 60 * 1000, expected = "1"},
	{kind = .Wait, text = "root: the trusted display shows the screen 1 of a wide grant of principal 1"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "root: started unlock"},
	{kind = .Wait, text = "unlock: the passphrase of principal 1 is asked for a wide grant"},
	{kind = .Wait, text = "display: unlock" + WINDOW_TAKEN, any_order = true},
	{kind = .Front, text = "unlock"},
	{kind = .Type, text = PRINCIPAL_PASSPHRASE},
	{kind = .Wait, text = "unlock: the passphrase of principal 1 proved a wide grant"},
	{kind = .Wait, text = "root: unlock stopped: itself, done", any_order = true},
	{kind = .Wait, text = "root: the wide grant 1 of principal 1 holds, with 2 writers of act records"},
	// Verify both the agent call and the live viewer operate under the active grant.
	{kind = .Call, text = "monitor.processes()", expected = "collector"},
	{kind = .Remote_Display_Case, text = "same session"},

	// Lock principal 1 from principal 0's boot console: principal 0's console
	// stays alive while alice's session and wide grant end cleanly.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "lock()"},
	{kind = .Wait, text = "root: the wide grant 1 of principal 1 ended: reason 4"},
	{kind = .Wait, text = " of principal 1 ended (a revocation, or a lock of its session): the connection from 10.0.2.2 port ", any_order = true},
	{kind = .Wait, text = " of principal 1 ended (a revocation, a lock of its session, or another session in front): the connection from 10.0.2.2 port ", any_order = true},
	{kind = .Wait, text = "root: the session of principal 1 \"alice\" ends: ", any_order = true},
	{kind = .Wait, text = "root: monitor stopped: ", any_order = true},
	{kind = .Wait, text = "root: collector stopped: ", any_order = true, fails_on = "ended with no record of its end"},
	{kind = .Wait, text = "root: collector stopped: ", any_order = true, fails_on = "the end of the act records of grant "},
	{kind = .Wait, text = "storage: the keys of the principal in slot 1 are erased: its session ended", any_order = true, fails_on = "passed its bound with no answer of the collector"},
	{kind = .Wait, text = "compositor: the capture face ended (the service closed it)", any_order = true},
	{kind = .Wait, text = "unlock: principal 1 \"alice\" is locked: its passphrase opens its session", any_order = true},
	{kind = .Wait, text = "display: unlock" + WINDOW_TAKEN, any_order = true},

	// Verify on the peer side that both the agent and viewer connections ended
	// with Revoked and that new handshakes are refused while alice is locked.
	{kind = .Remote_Case, text = "revoked"},
	{kind = .Wait, text = ": the session of its principal 1 is locked; the handshake ends before any call", any_order = true},
	{kind = .Remote_Display_Case, text = "revoked"},

	// Confirm principal 0's boot console is alive and observes principal 1 locked.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "principals()"},
	{kind = .Wait, text = "[console]      1  alice    locked   "},

	// Unlock alice again and verify that her collector reloads all three
	// encrypted audit spaces, including both Grant_Started and Grant_Revoked
	// in space 1 (root.acts), with intact hash chains.
	{kind = .Front, text = "unlock"},
	{kind = .Type, text = PRINCIPAL_PASSPHRASE},
	{kind = .Wait, text = "root: unlock stopped: itself, done", any_order = true},
	{kind = .Wait, text = "root: the session of principal 1 \"alice\" starts: the desktop starts each process in it"},
	{kind = .Launch, text = "console"},
	{kind = .Wait, text = "root: started console, with a terminal, in the session of principal 1 \"alice\""},
	{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"collector\")"},
	{kind = .Wait, text = "collector: read 3 audit spaces with ", any_order = true},
	{kind = .Wait, text = "[console]   module     collector"},
	{kind = .Type, text = "collector.active_grant_count()"},
	{kind = .Wait, text = "[console] 0"},
	{kind = .Type, text = "collector.spaces() |> where(space = 1) |> where(kept = 2) |> columns(source, output)"},
	{kind = .Wait, text = "[console] root    acts", fails_on = "0 rows"},
	{kind = .Type, text = "collector.space_verify(1)"},
	{kind = .Wait, text = "[console] 0"},
	{kind = .Type, text = "collector.space_verify(2)"},
	{kind = .Wait, text = "[console] 0"},
	{kind = .Type, text = "collector.space_verify(3)"},
	{kind = .Wait, text = "[console] 0"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

wide_grant_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	machine_test(part, scenario_wide_grant[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_WIDE_GRANT, exit_status = build.MACHINE_STOP_OK}) or_return
	disk_prepare(TEST_WIDE_GRANT_LOCK_DISK, build.DATA_DISK_SIZE, true) or_return
	return machine_test(part, scenario_wide_grant_lock[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_WIDE_GRANT_LOCK, exit_status = build.MACHINE_STOP_OK, data_disk = TEST_WIDE_GRANT_LOCK_DISK})
}

// A binary of the tool runs the test part wide_grant only when it holds
// this file (test_parts.odin, test_part_scenario_register).
@(init)
wide_grant_test_part_register :: proc "contextless" () {
	test_part_scenario_register("wide_grant", wide_grant_tests_run)
}
