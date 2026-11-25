#+build !freestanding
package console

import "core:strings"
import "core:sync"
import "core:testing"
import pr "modus:contract/plans_recipes"

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
