#+build !freestanding
package console

import "core:strings"
import "core:sync"
import "core:testing"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import pr "modus:contract/plans_recipes"
import "modus:contract/ring"
import "modus:line_editor"

// Console tests share package globals (commands, scratch, failure); serialize
// them so parallel odin test runners never race.
@(private = "file")
ergonomics_test_lock: sync.Mutex

// Host-only link stub for the assembly trampoline called by call_export
// (never invoked by these host tests).
@(export, link_name = "export_call")
host_export_call_stub :: proc "c" (_: uintptr, _: rawptr, _: rawptr, _: rawptr) {}

@(private = "file")
ergonomics_failure_text :: proc() -> string {
	return string(failure.sentence[:failure.sentence_count])
}

@(private = "file")
ergonomics_reset_state :: proc() {
	command_count = 0
	scratch_count = 0
	table_used = 0
	failed = false
	failure_reset()
	// Register the commands tested without requiring live kernel handles.
	command("help", {.Text}, .Table, "the commands, or the help on one name", help, optional_last = true)
	command("describe", {.Text}, .Text, "the help on one name: a command or a word of Lex", describe)
	command("start", {.Text, .None}, .None, "start a boot-image module or a disk process, with a wiring list or a hash", start_process, optional_last = true)
	command("start_from_disk", {.Text, .Text}, .None, "start a module of the store module_files, by nickname and hash", start_from_disk)
	command("connect", {.Text}, .Record, "call the exports of a service that runs", connect_service)
	command("isolate", {.Text}, .Record, "load a module in a sandboxed process", isolate_module)
	command("load", {.Text}, .Record, "load a module here: direct calls", load_module)
	command("allow", {.Text, .Text}, .None, "give a disk process a grant, by nickname", allow)
	command("revoke", {.Text, .Text}, .Integer, "end a grant of a process that runs", revoke)
	command("projects.install", {.Text, .Text}, .Record, "ingest, build, verify, and deliver a project module into module_files", projects_install_command, optional_last = true)
	command("plans.apply", {.Text, .None, .Record}, .Table, "apply a plan after trusted display consent and return the committed generation", plans_apply_command, optional_last = true)
	command("plans.rollback", {.Integer}, .Table, "roll back to the previous or numbered plan generation after trusted display consent", plans_rollback_command, optional_last = true)
	plans_commands_attach_types()
}

@(private = "file")
ergonomics_clear_line :: proc() {
	scratch_count = 0
	table_used = 0
	failed = false
	failure_reset()
}

@(test)
help_accepts_zero_or_one_text_argument_and_refuses_bad_calls :: proc(t: ^testing.T) {
	sync.mutex_lock(&ergonomics_test_lock)
	defer sync.mutex_unlock(&ergonomics_test_lock)
	ergonomics_reset_state()

	// 0 arguments: returns the full Table of Command rows.
	table_val := call_run("help", nil)
	testing.expect(t, !failed, "help() must succeed")
	testing.expect_value(t, table_val.kind, Kind.Table)
	tbl, ok := table_of(table_val)
	testing.expect(t, ok && tbl.rows == command_count)

	// 1 Text argument: delegates to describe for Lex words and commands.
	ergonomics_clear_line()
	let_args := [1]Value{{kind = .Text, text = "let"}}
	let_val := call_run("help", let_args[:])
	testing.expect(t, !failed, "help(\"let\") must succeed")
	testing.expect_value(t, let_val.kind, Kind.Text)
	testing.expect(t, strings.contains(let_val.text, "let binds names for one expression"))

	// Every key command listed in the ergonomics checklist has crisp help text.
	topics := [?]string{
		"start", "start_from_disk", "connect", "isolate", "load",
		"projects.install", "allow", "revoke",
		"plans.difference", "plans.apply", "plans.rollback",
	}
	for topic in topics {
		ergonomics_clear_line()
		args := [1]Value{{kind = .Text, text = topic}}
		val := call_run("help", args[:])
		testing.expectf(t, !failed && val.kind == .Text && len(val.text) > 0, "help(%q) must return help text", topic)
		testing.expectf(t, !strings.contains(val.text, ", result)"), "help(%q) must not list output buffer result as a console argument", topic)
	}

	// Unknown topic fails with nearest-name suggestion.
	ergonomics_clear_line()
	typo_args := [1]Value{{kind = .Text, text = "lte"}}
	_ = call_run("help", typo_args[:])
	testing.expect(t, failed)
	testing.expect(t, strings.contains(ergonomics_failure_text(), "did you mean let"))

	// Non-Text argument is refused.
	ergonomics_clear_line()
	int_args := [1]Value{{kind = .Integer, integer = 7}}
	_ = call_run("help", int_args[:])
	testing.expect(t, failed)

	// More than 1 argument is refused cleanly.
	ergonomics_clear_line()
	two_args := [2]Value{{kind = .Text, text = "let"}, {kind = .Text, text = "start"}}
	_ = call_run("help", two_args[:])
	testing.expect(t, failed)
	testing.expect(t, strings.contains(ergonomics_failure_text(), "0 or 1 arguments, not 2"))
}

@(test)
unified_start_refuses_bad_second_argument_and_bad_disk_inputs :: proc(t: ^testing.T) {
	sync.mutex_lock(&ergonomics_test_lock)
	defer sync.mutex_unlock(&ergonomics_test_lock)
	ergonomics_reset_state()

	// Wrong 2nd argument kind (neither Table nor Text) is refused cleanly.
	bad_kind := [2]Value{{kind = .Text, text = "notes"}, {kind = .Integer, integer = 42}}
	_ = call_run("start", bad_kind[:])
	testing.expect(t, failed)
	testing.expect(t, strings.contains(ergonomics_failure_text(), "wiring Table or a hash Text"))

	// 2nd argument Text with non-64-hex hash is refused before sending to root.
	ergonomics_clear_line()
	bad_hash := [2]Value{{kind = .Text, text = "db_browser"}, {kind = .Text, text = "not-a-hash"}}
	_ = call_run("start", bad_hash[:])
	testing.expect(t, failed)
	testing.expect(t, strings.contains(ergonomics_failure_text(), "64 hexadecimal digits"))

	// 2nd argument Text with reserved disk store name is refused.
	ergonomics_clear_line()
	bad_name := [2]Value{{kind = .Text, text = "module_files"}, {kind = .Text, text = ""}}
	_ = call_run("start", bad_name[:])
	testing.expect(t, failed)
	testing.expect(t, strings.contains(ergonomics_failure_text(), "module_files"))

	// 3 arguments are refused cleanly.
	ergonomics_clear_line()
	three_args := [3]Value{{kind = .Text, text = "notes"}, {kind = .Text, text = ""}, {kind = .Text, text = ""}}
	_ = call_run("start", three_args[:])
	testing.expect(t, failed)
	testing.expect(t, strings.contains(ergonomics_failure_text(), "1 or 2 arguments, not 3"))
}

@(test)
projects_install_validates_nickname_and_build_mode :: proc(t: ^testing.T) {
	sync.mutex_lock(&ergonomics_test_lock)
	defer sync.mutex_unlock(&ergonomics_test_lock)
	ergonomics_reset_state()

	// Mode parser accepts all 4 named modes + empty default and refuses others.
	mode, ok := recipes_build_mode_of_text("")
	testing.expect(t, ok && mode == pr.Build_Mode.Prefer_Cache)
	mode, ok = recipes_build_mode_of_text("prefer_cache")
	testing.expect(t, ok && mode == pr.Build_Mode.Prefer_Cache)
	mode, ok = recipes_build_mode_of_text("build_only")
	testing.expect(t, ok && mode == pr.Build_Mode.Build_Only)
	mode, ok = recipes_build_mode_of_text("cache_only")
	testing.expect(t, ok && mode == pr.Build_Mode.Cache_Only)
	mode, ok = recipes_build_mode_of_text("verify")
	testing.expect(t, ok && mode == pr.Build_Mode.Verify)
	_, ok = recipes_build_mode_of_text("bogus")
	testing.expect(t, !ok)

	// Empty project name is refused before touching any service.
	empty_args := [1]Value{{kind = .Text, text = ""}}
	_ = call_run("projects.install", empty_args[:])
	testing.expect(t, failed)

	// Unknown build mode is refused cleanly.
	ergonomics_clear_line()
	bad_mode := [2]Value{{kind = .Text, text = "db_browser"}, {kind = .Text, text = "fast_magic"}}
	_ = call_run("projects.install", bad_mode[:])
	testing.expect(t, failed)
	testing.expect(t, strings.contains(ergonomics_failure_text(), "unknown build mode"))

	// Non-Text mode argument is refused by type check.
	ergonomics_clear_line()
	bad_type := [2]Value{{kind = .Text, text = "db_browser"}, {kind = .Integer, integer = 1}}
	_ = call_run("projects.install", bad_type[:])
	testing.expect(t, failed)

	// 0 arguments and 3 arguments are refused cleanly.
	ergonomics_clear_line()
	_ = call_run("projects.install", nil)
	testing.expect(t, failed)
	ergonomics_clear_line()
	three := [3]Value{{kind = .Text, text = "a"}, {kind = .Text, text = "verify"}, {kind = .Text, text = "extra"}}
	_ = call_run("projects.install", three[:])
	testing.expect(t, failed)
}

@(test)
start_from_disk_refusal_formats_unified_and_explicit_errors :: proc(t: ^testing.T) {
	sync.mutex_lock(&ergonomics_test_lock)
	defer sync.mutex_unlock(&ergonomics_test_lock)
	ergonomics_reset_state()

	make_completion :: proc(outcome: call_outcome.Call_Outcome, err: errors.Error_Record) -> ring.Record {
		return ring.Record{
			kind   = u32(outcome),
			values = errors.completion_values(err),
		}
	}

	// Unified 1-arg start("nothing"): absent grant row gives actionable hash hint.
	ergonomics_clear_line()
	absent_grant := make_completion(.Argument_Refused, errors.Error_Record{
		kind = i64(errors.Kind.Absent),
		unit = i64(errors.Unit.Grants),
	})
	_ = start_from_disk_refusal_for("start", "nothing", absent_grant, unified_no_hash = true)
	testing.expect(t, failed)
	testing.expect_value(
		t,
		ergonomics_failure_text(),
		`start: no boot-image module has the name "nothing", and no disk grant row pins its hash; pass the 64-digit hash with start("nothing", "<hash>")`,
	)
	testing.expect_value(t, string(failure.operation[:failure.operation_count]), "root.Start_From_Disk")

	// Unified 1-arg start("nothing"): absent store object names both boot image and module_files.
	ergonomics_clear_line()
	absent_obj := make_completion(.Argument_Refused, errors.Error_Record{
		kind = i64(errors.Kind.Absent),
		unit = i64(errors.Unit.Objects),
	})
	_ = start_from_disk_refusal_for("start", "nothing", absent_obj, unified_no_hash = true)
	testing.expect(t, failed)
	testing.expect_value(
		t,
		ergonomics_failure_text(),
		`start: no boot-image module and no object in module_files has the name "nothing"`,
	)

	// Explicit start_from_disk("visitor", ""): absent grant row keeps explicit refusal.
	ergonomics_clear_line()
	_ = start_from_disk_refusal_for("start_from_disk", "visitor", absent_grant, unified_no_hash = false)
	testing.expect(t, failed)
	testing.expect_value(
		t,
		ergonomics_failure_text(),
		`start_from_disk: the nickname "visitor" has no row in the disk grant table: name the hash of its file`,
	)

	// Hash mismatch reports Not_Authentic and states nothing started.
	ergonomics_clear_line()
	bad_hash := make_completion(.Argument_Refused, errors.Error_Record{
		kind  = i64(errors.Kind.Not_Authentic),
		value = 0x0123456789abcdef,
	})
	_ = start_from_disk_refusal_for("start", "visitor", bad_hash, unified_no_hash = false)
	testing.expect(t, failed)
	testing.expect(t, strings.contains(ergonomics_failure_text(), `the bytes of "visitor" in the store module_files do not have the hash asked`))
	testing.expect(t, strings.contains(ergonomics_failure_text(), "The root service started nothing"))
}

@(test)
help_and_describe_completion_has_no_duplicate_candidates :: proc(t: ^testing.T) {
	sync.mutex_lock(&ergonomics_test_lock)
	defer sync.mutex_unlock(&ergonomics_test_lock)
	ergonomics_reset_state()

	owners := [2]string{"help", "describe"}
	for owner in owners {
		table: Candidate_Table
		names_collect(&table, line_editor.Completion_Context{place = .Quoted, owner = owner})
		testing.expectf(t, table.count > 0, "%s completion must collect candidates", owner)

		seen_start := false
		seen_projects_install := false
		seen_let := false
		seen_plans_apply := false
		for i in 0 ..< table.count {
			name := table.items[i].name
			if name == "start" {
				seen_start = true
			}
			if name == "projects.install" {
				seen_projects_install = true
			}
			if name == "let" {
				seen_let = true
			}
			if name == "plans.apply" {
				seen_plans_apply = true
			}
			for j in i + 1 ..< table.count {
				testing.expectf(t, name != table.items[j].name, "%s completion must not duplicate candidate %q", owner, name)
			}
		}
		testing.expectf(t, seen_start && seen_projects_install && seen_let && seen_plans_apply, "%s completion must include both commands and Lex/service topics", owner)
	}
}

@(test)
plans_apply_and_rollback_validate_arguments_and_help_text :: proc(t: ^testing.T) {
	sync.mutex_lock(&ergonomics_test_lock)
	defer sync.mutex_unlock(&ergonomics_test_lock)
	ergonomics_reset_state()

	// Help guides document the 1-step forms without apply_poll / rollback_poll.
	apply_help := call_run("help", []Value{{kind = .Text, text = "plans.apply"}})
	testing.expect(t, !failed && apply_help.kind == .Text)
	testing.expect(t, !strings.contains(apply_help.text, "apply_poll"))

	ergonomics_clear_line()
	rb_help := call_run("help", []Value{{kind = .Text, text = "plans.rollback"}})
	testing.expect(t, !failed && rb_help.kind == .Text)
	testing.expect(t, !strings.contains(rb_help.text, "rollback_poll"))

	// plans.apply: 0, 1, or 4 arguments are refused cleanly (2 or 3 allowed).
	ergonomics_clear_line()
	_ = call_run("plans.apply", []Value{{kind = .Text, text = "evening"}})
	testing.expect(t, failed)
	testing.expect(t, strings.contains(ergonomics_failure_text(), "2 or 3 arguments, not 1"))

	// plans.apply: empty name refused before connecting plans.
	ergonomics_clear_line()
	_ = call_run("plans.apply", []Value{{kind = .Text, text = ""}, {kind = .Integer, integer = 1}})
	testing.expect(t, failed)
	testing.expect(t, strings.contains(ergonomics_failure_text(), "plan name is empty"))

	// plans.apply: overlong name (> PLAN_DISPLAY_NAME_BYTES) refused before connecting plans.
	ergonomics_clear_line()
	long_name := "a_plan_name_that_is_longer_than_forty_eight_bytes_limit"
	_ = call_run("plans.apply", []Value{{kind = .Text, text = long_name}, {kind = .Integer, integer = 1}})
	testing.expect(t, failed)
	testing.expect(t, strings.contains(ergonomics_failure_text(), "at most 48 bytes"))

	// plans.apply: non-plan / non-table 2nd argument refused before connecting plans.
	ergonomics_clear_line()
	_ = call_run("plans.apply", []Value{{kind = .Text, text = "evening"}, {kind = .Integer, integer = 7}})
	testing.expect(t, failed)
	testing.expect(t, strings.contains(ergonomics_failure_text(), "must be a plan or a Table of Plan_Entry_Row"))

	// plans.rollback: generation < 1 refused before connecting plans.
	for bad_gen in ([?]i64{0, -1, min(i64)}) {
		ergonomics_clear_line()
		_ = call_run("plans.rollback", []Value{{kind = .Integer, integer = bad_gen}})
		testing.expect(t, failed)
		testing.expect(t, strings.contains(ergonomics_failure_text(), "must be at least 1"))
	}

	// plans.rollback: 2 arguments refused cleanly (0 or 1 allowed).
	ergonomics_clear_line()
	_ = call_run("plans.rollback", []Value{{kind = .Integer, integer = 1}, {kind = .Integer, integer = 2}})
	testing.expect(t, failed)
	testing.expect(t, strings.contains(ergonomics_failure_text(), "0 or 1 arguments, not 2"))

	// Built-in frontends own plans.apply and plans.rollback with run != nil.
	apply_cmd := command_find("plans.apply")
	rb_cmd := command_find("plans.rollback")
	testing.expect(t, apply_cmd != nil && apply_cmd.run != nil && apply_cmd.optional_last)
	testing.expect(t, rb_cmd != nil && rb_cmd.run != nil && rb_cmd.optional_last)
}
