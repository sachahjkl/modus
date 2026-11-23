package machine

import "modustool:build"
import "modustool:foundation"

// The plan of principal 0 across a restart, and the audit of the
// collector: two machines on one new data disk, part of
// `modustool test persist`, on the volume plan_and_audit, whose image alone
// holds the test modules plan_applier, settings_stand_in and audit_asker
// (src/md/features/declarations.md, "The plan of principal 0 at the
// start"; src/md/features/module_outputs.md, "The audit").
//
//   1. The disk holds no plan: the plans service says No_Plan before the
//      start policy, and the wait never ends at the hang bound.
//      `plan_applier` gives four plans that are refused, each with its
//      error record and no generation current: a Plan_Expected of no
//      current plan, a difference that the principal refuses, and two
//      that the principal accepts and the root service refuses (a hash of
//      no module of the image, a module that does not fill the contract of
//      Settings). Then the plan that names `settings_stand_in` as the
//      holder of Settings, which the principal accepts: generation 1.
//      `audit_asker` gets two lists of pairs refused, then starts
//      `generic_source` with an audited list: each probe of left comes to
//      it through the pair of collector.forward. The console reads the two
//      audit spaces, checks each chain and the refusal of a space that
//      does not exist, stops the collector, and finds both spaces whole in
//      the collector that the next connection starts. Last, the store
//      picker: `store_asker` asks the trusted display for a store, the
//      picker lists the stores of principal 0 through the powerbox, the
//      principal picks one, and the one grant of the windows is the grant
//      of store_asker; `store_stranger` gets No_Grant for the grants and
//      for a picker of its own. Last, `difference_hostile` gives the
//      trusted display an Uncommitted object and an object that it revokes
//      during the reading, and the display serves after each.
//   2. The same disk: the plans service gives the roles of the stored plan
//      before the start policy, so the row "settings" of the start list
//      starts settings_stand_in, with the boot pass, and never
//      `settings`. The collector reads its two audit spaces back, and each
//      chain holds.

TEST_PLAN_AND_AUDIT_DISK :: foundation.BUILD_FOLDER + "/test_plan_and_audit_disk.img"
TEST_OUTPUT_PLAN_AND_AUDIT :: foundation.BUILD_FOLDER + "/test_output_plan_and_audit_%d.txt"

// The lines of a wait for the plan of principal 0 that must never come:
// its end at the hang bound, and a holder of Plans that stopped first.
PLAN_AT_START_LATE_LINE :: "root: the plans service did not read the plan of principal 0 within the hang bound"
PLAN_AT_START_STOPPED_LINE :: "root: the plans service stopped before it read the plan of principal 0"

// The audit spaces of generic_source: 20 probes of left and 20 of right.
AUDIT_SPACES_LOADED_LINE :: "collector: read 2 audit spaces with 40 records from its store"

// The refusal of each case of plan_applier, and the line of the root
// service that refuses the roles of the two plans that the principal
// accepts.
PLAN_APPLIER_WRONG :: "plan_applier: WRONG"

// The failures of the store picker: the asker found a fault, or the
// picker received no list.
STORE_ASKER_WRONG :: "store_asker: WRONG"
STORE_PICKER_NO_LIST_LINE :: "compositor: the store picker received no list of stores"

// A fault that the hostile caller of the trusted display found.
DIFFERENCE_HOSTILE_WRONG :: "difference_hostile: WRONG"

scenario_plan_and_audit_first := [?]Step {
	// The plans service reads the store before the start policy, and finds
	// no plan: the wait ends at its answer.
	{kind = .Wait, text = "root: the plans service reads the plan of principal 0 before the start policy, within the hang bound of "},
	{kind = .Wait, text = "root: principal 0 has no plan stored: the roles of the boot image hold", fails_on = PLAN_AT_START_LATE_LINE},
	{kind = .Wait, text = "root: started start_policy", fails_on = PLAN_AT_START_STOPPED_LINE},
	{kind = .Wait, text = "settings: the boot pass: no settings kept: the defaults", any_order = true},
	{kind = .Wait, text = "display: console" + WINDOW_TAKEN},
	{kind = .Type, text = "start(\"plan_applier\")"},
	// 1. A Plan_Expected of no current plan: refused, with no dialog.
	{kind = .Wait, text = "plan_applier: a Plan_Expected of a plan that is not current: refused with the refusal 19, and no generation is current: as it must", fails_on = PLAN_APPLIER_WRONG},
	// 2. Enter while the focus is on Refuse.
	{kind = .Wait, text = "compositor: the difference of the plan refused by the principal shows: 1 added, 0 removed", any_order = true},
	{kind = .Wait, text = "plan_applier: the dialog of the plan refused by the principal takes the decision of the principal now", fails_on = PLAN_APPLIER_WRONG},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the difference of the plan refused by the principal is refused"},
	{kind = .Wait, text = "plan_applier: refused by the principal: refused with the refusal 28, and no generation is current: as it must", fails_on = PLAN_APPLIER_WRONG},
	// 3. A hash of no module of the image: the principal accepts, the root
	// service refuses its roles (Not_In_Image, 9), and nothing commits.
	{kind = .Wait, text = "plan_applier: the dialog of the plan a holder not in the image takes the decision of the principal now", fails_on = PLAN_APPLIER_WRONG},
	{kind = .Key, text = "tab"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the difference of the plan a holder not in the image is accepted"},
	{kind = .Wait, text = "root: refused the roles of the plan of generation 1: refusal 9 at the override 0; the serial 0 stays in force", any_order = true},
	{kind = .Wait, text = "plan_applier: a holder not in the image: refused with the refusal 32, and no generation is current: as it must", fails_on = PLAN_APPLIER_WRONG},
	// 4. A module of the image that does not fill the contract of Settings
	// (Contract_Not_Filled, 10).
	{kind = .Wait, text = "plan_applier: the dialog of the plan a holder that does not fill takes the decision of the principal now", fails_on = PLAN_APPLIER_WRONG},
	{kind = .Key, text = "tab"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the difference of the plan a holder that does not fill is accepted"},
	{kind = .Wait, text = "root: refused the roles of the plan of generation 1: refusal 10 at the override 0; the serial 0 stays in force", any_order = true},
	{kind = .Wait, text = "plan_applier: a holder that does not fill: refused with the refusal 32, and no generation is current: as it must", fails_on = PLAN_APPLIER_WRONG},
	// The plan that commits: settings_stand_in, accepted.
	{kind = .Wait, text = "plan_applier: the dialog of the plan settings stand-in takes the decision of the principal now", fails_on = PLAN_APPLIER_WRONG},
	{kind = .Key, text = "tab"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the difference of the plan settings stand-in is accepted", fails_on = "compositor: the difference of the plan settings stand-in is refused"},
	{kind = .Wait, text = "root: the roles of the plan of generation 1 are in force: 1 overrides, serial 1, rollback 0", any_order = true},
	{kind = .Wait, text = "plans: applied generation 1 for principal 0", any_order = true},
	{kind = .Wait, text = "plan_applier: the principal accepted the plan: generation 1, whose holder of the role Settings is settings_stand_in", fails_on = PLAN_APPLIER_WRONG},
	{kind = .Wait, text = "root: plan_applier stopped: itself, done"},
	// The audit: two lists of pairs refused before any source reaches the
	// collector, then the collector keeps left and forwards it, and keeps
	// right.
	{kind = .Type, text = "start(\"audit_asker\")"},
	{kind = .Wait, text = "audit_asker: a pair with no source row and a second pair of one source: refused, each with its status and its error record and the budget unchanged: as it must", fails_on = "audit_asker: WRONG"},
	{kind = .Wait, text = "audit_asker: the display refused plan_diff_ask to a caller that does not hold the role Plans, with No_Grant: as it must", fails_on = "audit_asker: WRONG"},
	{kind = .Wait, text = "keeps generic_source.left in space 1", any_order = true},
	{kind = .Wait, text = "keeps generic_source.right in space 2", any_order = true},
	{kind = .Wait, text = "audit_asker: the 20 probes of generic_source.left came through the pair of collector.forward, in their order, then the clean end of the source", fails_on = "audit_asker: WRONG"},
	{kind = .Wait, text = "root: audit_asker stopped: itself, done"},
	{kind = .Type, text = "connect(\"collector\")"},
	{kind = .Wait, text = "[console]   module     collector"},
	// The records that the two spaces keep: 20 of each side.
	{kind = .Type, text = "collector.record_count()"},
	{kind = .Wait, text = "[console] 40"},
	{kind = .Type, text = "collector.space_verify(1)"},
	{kind = .Wait, text = "[console] 0"},
	{kind = .Type, text = "collector.space_verify(2)"},
	{kind = .Wait, text = "[console] 0"},
	// No third space: the refused lists made none.
	{kind = .Type, text = "collector.space_verify(3)"},
	{kind = .Wait, text = "[console] error: collector.space_verify: "},
	// A stop of the collector: the next connection starts it again, and it
	// reads each segment of both spaces back from its store.
	{kind = .Type, text = "stop(\"collector\")"},
	{kind = .Wait, text = "root: collector stopped: "},
	// The console keeps the description that it loaded before the stop:
	// connect makes no connection, and the collector, which starts on
	// demand, starts at the first call and reads its spaces back then.
	{kind = .Type, text = "connect(\"collector\")"},
	{kind = .Wait, text = "[console]   module     collector"},
	{kind = .Type, text = "collector.record_count()"},
	{kind = .Wait, text = "root: started collector", any_order = true},
	{kind = .Wait, text = AUDIT_SPACES_LOADED_LINE, any_order = true},
	{kind = .Wait, text = "[console] 40"},
	{kind = .Type, text = "collector.space_verify(1)"},
	{kind = .Wait, text = "[console] 0"},
	{kind = .Type, text = "collector.space_verify(2)"},
	{kind = .Wait, text = "[console] 0"},
	// The store picker (src/md/features/powerbox.md, "The picker ring"):
	// principal 0 holds several stores on this disk by now (those of the
	// console, plans, the collector and settings_stand_in). store_asker
	// asks the trusted display for a store and sees no list; the picker
	// lists the stores that the storage service gives through the
	// powerbox; the principal picks one, and the one grant of the windows
	// is the grant of store_asker. store_stranger, which does not act for
	// the principal, gets neither that grant nor a list.
	{kind = .Type, text = "start(\"store_asker\")"},
	{kind = .Wait, text = "store_asker: the trusted display shows the store picker for request ", fails_on = STORE_ASKER_WRONG},
	{kind = .Wait, text = "compositor: the store picker lists ", fails_on = STORE_PICKER_NO_LIST_LINE, any_order = true},
	{kind = .Key, text = "down"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: store_asker holds the grant ", fails_on = STORE_ASKER_WRONG},
	{kind = .Type, text = "connect(\"compositor\")"},
	{kind = .Wait, text = "[console]   module     compositor"},
	{kind = .Type, text = "compositor.window_grants()"},
	{kind = .Wait, text = "store_asker"},
	{kind = .Wait, text = "[console] 1 row of Window_Grant_Row"},
	{kind = .Type, text = "start(\"store_stranger\")"},
	{kind = .Wait, text = "store_stranger: the display refused window_grants and powerbox_pick_store with No_Grant: this process sees no store of the principal, as it must", fails_on = "store_stranger: WRONG"},
	{kind = .Wait, text = "root: store_stranger stopped: itself, done"},
	// The grant of store_asker held while the stranger asked: still one row.
	{kind = .Type, text = "compositor.window_grants()"},
	{kind = .Wait, text = "[console] 1 row of Window_Grant_Row"},
	{kind = .Type, text = "stop(\"store_asker\")"},
	{kind = .Wait, text = "root: store_asker stopped: ", fails_on = STORE_ASKER_WRONG},
	// A hostile caller of the trusted display of a plan difference: an
	// Uncommitted object is refused at the border, and an object revoked
	// while the worker reads it ends its dialog or leaves the lines that the
	// worker read, which Escape refuses. The display serves after each.
	{kind = .Type, text = "start(\"difference_hostile\")"},
	{kind = .Wait, text = "difference_hostile: the display refused an Uncommitted object with Bad_Value, kept no copy of it, and still serves: as it must", fails_on = DIFFERENCE_HOSTILE_WRONG},
	{kind = .Wait, text = "difference_hostile: the object of the difference ", fails_on = DIFFERENCE_HOSTILE_WRONG},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "difference_hostile: the dialog of the revoked difference ended with the decision ", fails_on = DIFFERENCE_HOSTILE_WRONG},
	{kind = .Wait, text = "root: difference_hostile stopped: itself, done", fails_on = DIFFERENCE_HOSTILE_WRONG},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

scenario_plan_and_audit_second := [?]Step {
	// The roles of the stored plan hold before the start policy starts.
	{kind = .Wait, text = "root: the roles of generation 1 of the plan of principal 0 hold from the start: 1 overrides, serial ", fails_on = PLAN_AT_START_LATE_LINE},
	{kind = .Wait, text = "root: started start_policy", fails_on = PLAN_AT_START_STOPPED_LINE},
	// The row "settings" reaches the holder of the plan, from the first
	// start of the machine.
	{kind = .Wait, text = "settings_stand_in: the start policy started the holder of the role Settings for the pass 1", fails_on = "settings: the boot pass"},
	{kind = .Wait, text = "display: console" + WINDOW_TAKEN, any_order = true},
	// The collector does not run: the first connect starts it, and it reads
	// its spaces back.
	{kind = .Type, text = "connect(\"collector\")"},
	{kind = .Wait, text = "root: started collector"},
	{kind = .Wait, text = "[console]   module     collector"},
	{kind = .Wait, text = AUDIT_SPACES_LOADED_LINE, any_order = true},
	{kind = .Type, text = "collector.record_count()"},
	{kind = .Wait, text = "[console] 40"},
	{kind = .Type, text = "collector.space_verify(1)"},
	{kind = .Wait, text = "[console] 0"},
	{kind = .Type, text = "collector.space_verify(2)"},
	{kind = .Wait, text = "[console] 0"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

// plan_and_audit_run runs the two machines on a new disk.
plan_and_audit_run :: proc(part: ^Test_Part_Run) -> bool {
	disk_prepare(TEST_PLAN_AND_AUDIT_DISK, build.DATA_DISK_SIZE, true) or_return
	machine_test(part, scenario_plan_and_audit_first[:], {volume = build.BOOT_VOLUME_PLAN_AND_AUDIT, output = self_test_file(TEST_OUTPUT_PLAN_AND_AUDIT, 1), exit_status = build.MACHINE_STOP_OK, data_disk = TEST_PLAN_AND_AUDIT_DISK}) or_return
	return machine_test(part, scenario_plan_and_audit_second[:], {volume = build.BOOT_VOLUME_PLAN_AND_AUDIT, output = self_test_file(TEST_OUTPUT_PLAN_AND_AUDIT, 2), exit_status = build.MACHINE_STOP_OK, data_disk = TEST_PLAN_AND_AUDIT_DISK})
}
