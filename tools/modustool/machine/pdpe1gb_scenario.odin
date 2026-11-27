package machine

import "modustool:build"
import "modustool:foundation"

// Live 4 GiB pdpe1gb verification (src/md/features/frames_of_a_process.md):
// boots `plan_and_audit` on a 4096 MiB QEMU machine with `-cpu max,+pdpe1gb`,
// starts `pdpe1gb_probe`, and verifies refusal edges, resumable 1 GiB
// Frames_Now zeroing across schedule(), 1 GiB PDPT leaf mapping
// (`entries_1g == 1`), zeroed bytes across 2 MiB slice offsets, zero-allocation
// partial Memory_Protect demotion via Process.demotion_tables (`0/511/512`),
// data integrity, and clean 1 GiB run reclamation to `free_runs_1g`.

TEST_OUTPUT_PDPE1GB :: foundation.BUILD_FOLDER + "/test_output_pdpe1gb.txt"
PDPE1GB_MACHINE_MEMORY_MIB :: 4096
PDPE1GB_PROBE_WRONG :: "pdpe1gb_probe: WRONG"

scenario_pdpe1gb := [?]Step {
	{kind = .Wait, text = "display: console" + WINDOW_TAKEN},
	{kind = .Type, text = "start(\"pdpe1gb_probe\")"},
	{kind = .Wait, text = "pdpe1gb_probe: refusals checked", fails_on = PDPE1GB_PROBE_WRONG},
	{kind = .Wait, text = "pdpe1gb_probe: committed 1 GiB run, free_runs_1g ", fails_on = PDPE1GB_PROBE_WRONG},
	{kind = .Wait, text = "pdpe1gb_probe: mapped 1 GiB page entry: entries_1g=1, entries_2m=0, entries_4k=0", fails_on = PDPE1GB_PROBE_WRONG},
	{kind = .Wait, text = "pdpe1gb_probe: demoted 1 GiB page with zero budget cost: entries_1g=0, entries_2m=511, entries_4k=512", fails_on = PDPE1GB_PROBE_WRONG},
	{kind = .Wait, text = "pdpe1gb_probe: ok, 1 GiB run zeroed, mapped, demoted, and returned (free_runs_1g=", fails_on = PDPE1GB_PROBE_WRONG},
	{kind = .Wait, text = "root: pdpe1gb_probe stopped: itself, done", fails_on = PDPE1GB_PROBE_WRONG},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

pdpe1gb_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	return machine_test(part, scenario_pdpe1gb[:], {
		volume      = build.BOOT_VOLUME_PLAN_AND_AUDIT,
		output      = TEST_OUTPUT_PDPE1GB,
		exit_status = build.MACHINE_STOP_OK,
		processor   = .With_Pdpe1gb,
		memory_mib  = PDPE1GB_MACHINE_MEMORY_MIB,
	})
}

@(init)
pdpe1gb_test_part_register :: proc "contextless" () {
	test_part_scenario_register("gigabyte_pages", pdpe1gb_tests_run)
}
