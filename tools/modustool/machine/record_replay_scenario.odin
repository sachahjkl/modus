// Live machine record and replay of a window process (`plasma`), a planted
// `rdrand` module (`replay_rdrand_probe`), and the console (`console` through
// `replay_probe`), exporting each recorded kernel input history from the
// machine memory file and diagnosing each through `modustool replay`
// (src/md/features/record_and_replay.md).
package machine

import "core:os"
import "modustool:build"
import "modustool:foundation"

TEST_OUTPUT_RECORD_REPLAY :: foundation.BUILD_FOLDER + "/test_output_record_replay.txt"
RECORD_REPLAY_MEMORY_FILE :: foundation.BUILD_FOLDER + "/test_output_record_replay_memory.raw"

@(rodata)
scenario_record_replay := [?]Step {
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true},
	{kind = .Front, text = "console"},

	// 1. Live record and replay of a window process (`plasma`):
	//    start recorded from its first instruction via `debugger`, draw its
	//    first frame, end the record, close the live window, replay the
	//    history alone with zero divergences, and verify the exported history
	//    with `modustool replay`.
	{kind = .Type, text = "columns(record(\"plasma\"), state)"},
	{kind = .Wait, text = "[console] recording", any_order = true},
	{kind = .Wait, text = "plasma: ok", any_order = true},
	{kind = .Wait, text = "display: plasma" + WINDOW_TAKEN},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "columns(record_end(), state, end)"},
	{kind = .Wait, text = "[console] ended  record ended"},
	{kind = .Type, text = "columns(detach(), process)"},
	{kind = .Wait, text = "[console] plasma"},
	{kind = .Close, text = "plasma"},
	{kind = .Wait, text = "root: plasma stopped"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "columns(replay_start(), state)"},
	{kind = .Wait, text = "[console] replaying", any_order = true},
	{kind = .Wait, text = "root: plasma stopped: a holder"},
	{kind = .Type, text = "columns(replay_status(), state, end, divergence)"},
	{kind = .Wait, text = "[console] replayed  record ended           0"},
	{kind = .Export_Replay_History, text = "plasma", expected = "clean"},

	// 2. Live record and replay of a planted `rdrand` module
	//    (`replay_rdrand_probe`): CPUID faulting hides `rdrand` (bit 30 = 0),
	//    executing `rdrand` directly succeeds and feeds a fresh checksum into
	//    `Word_Wake`, and replay stops at that exact input point with
	//    `Unexpected_Arguments`.
	{kind = .Type, text = "columns(record(\"replay_rdrand_probe\"), state)"},
	{kind = .Wait, text = "[console] recording", any_order = true},
	{kind = .Wait, text = "replay_rdrand_probe: ran with cpuid rdrand 0, rdrand ok 1, checksum ", any_order = true},
	{kind = .Wait, text = "root: replay_rdrand_probe stopped: itself, done"},
	{kind = .Type, text = "columns(replay_status(), state, end)"},
	{kind = .Wait, text = "[console] ended  process stopped"},
	{kind = .Type, text = "columns(replay_start(), state)"},
	{kind = .Wait, text = "[console] replaying", any_order = true},
	{kind = .Wait, text = "kernel: process replay_rdrand_probe: replay stopped on divergence kind 5 at point ", any_order = true},
	{kind = .Wait, text = "root: replay_rdrand_probe stopped: a holder"},
	{kind = .Type, text = "columns(replay_status(), state, end, differed)"},
	{kind = .Wait, text = "[console] replayed  divergence  arguments"},
	{kind = .Export_Replay_History, text = "replay_rdrand_probe", expected = "diverged"},

	// 3. Live record and replay of the console (`console` via `replay_probe`):
	//    records the real `console` module with a typed line ("6 * 7" -> "42")
	//    over a shared terminal ring and read-only text region, replays it
	//    alone with zero divergences, and verifies the exported history with
	//    `modustool replay`.
	{kind = .Type, text = "start(\"replay_probe\")"},
	{kind = .Wait, text = "replay_probe: the record holds the shared mapping, a delta of the shared page for each round, the cycle counter and cpuid, and ends with the stop of the reader: as it must"},
	{kind = .Wait, text = "replay_probe: the replay with no writer reached the end of the history with 0 divergences: as it must"},
	{kind = .Wait, text = "replay_probe: a changed byte of the shared page in the history: the replay stopped at the first entry after it that carries the sum: as it must"},
	{kind = .Wait, text = "replay_probe: the console recorded a typed line and replayed alone to the end of its history with 0 divergences: as it must"},
	{kind = .Wait, text = "replay_probe: ok, 4 cases: a record with a shared writer, its replay with no writer, the first divergence, and the console"},
	{kind = .Wait, text = "root: replay_probe stopped: itself, done"},
	{kind = .Export_Replay_History, text = "console", expected = "clean"},

	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

// record_replay_tests_run runs the live machine record and replay test part
// with a shared QEMU guest memory file so exported histories can be verified
// through `modustool replay`.
record_replay_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	_ = os.remove(RECORD_REPLAY_MEMORY_FILE)
	passed := machine_test(part, scenario_record_replay[:], {
		volume      = build.BOOT_VOLUME,
		output      = TEST_OUTPUT_RECORD_REPLAY,
		exit_status = build.MACHINE_STOP_OK,
		memory_file = RECORD_REPLAY_MEMORY_FILE,
	})
	if passed {
		_ = os.remove(RECORD_REPLAY_MEMORY_FILE)
	}
	return passed
}

// A binary of the tool runs the test part record_replay only when it holds
// this file (test_parts.odin, test_part_scenario_register).
@(init)
record_replay_test_part_register :: proc "contextless" () {
	test_part_scenario_register("record_replay", record_replay_tests_run)
}
