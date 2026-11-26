#+build !freestanding
package console

import "core:strings"
import "core:sync"
import "core:testing"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import pr "modus:contract/plans_recipes"
import "modus:contract/ring"
import "modus:lex_parser"
import "modus:line_editor"
import "modus:system"

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
	names_count = 0
	loaded_count = 0
	next_module_handle_id = 1
	line_binding_target = ""
	line_loaded_handle = 0
	for &variable in variables {
		variable = {}
	}
	scratch_count = 0
	table_used = 0
	failed = false
	failure_reset()
	// Register the commands tested without requiring live kernel handles.
	command("help", {.None}, .Table, "the commands, the help on one name, or the commands of a module handle", help, optional_last = true)
	command("describe", {.Text}, .Text, "the help on one name: a command or a word of Lex", describe)
	command("start", {.Text, .None}, .None, "start a boot-image module or a disk process, with a wiring list or a hash", start_process, optional_last = true)
	command("start_from_disk", {.Text, .Text}, .None, "start a module of the store module_files, by nickname and hash", start_from_disk)
	command("connect", {.Text}, .Record, "call the exports of a service that runs", connect_service)
	command("isolate", {.Text}, .Record, "load a module in a sandboxed process and return a bound handle", isolate_module)
	command("load", {.Text}, .Record, "load a module here for direct calls and return a bound handle", load_module)
	command("isolate_memory", {.Text, .Handle, .Integer}, .Record, "load a module from memory in a sandboxed process and return a bound handle", isolate_from_memory)
	command("compile_c", {.Text, .Text}, .Record, "compile C source into an isolated module and return a bound handle", compile_c_command)
	command("unload", {.Record}, .Record, "remove a bound module handle that load, isolate, isolate_memory, or connect returned", unload_module)
	command("allow", {.Text, .Text}, .None, "give a disk process a grant, by nickname", allow)
	command("revoke", {.Text, .Text}, .Integer, "end a grant of a process that runs", revoke)
	command("projects.install", {.Text, .Text}, .Record, "ingest, build, verify, and deliver a project module into module_files", projects_install_command, optional_last = true)
	command("recipes.publisher_key", {}, .Text, "return the principal's Ed25519 cache publisher public key", recipes_publisher_key_command)
	command("recipes.configure_publisher", {.Text}, .Text, "configure the principal's Ed25519 cache publisher key from a 64-hex seed", recipes_configure_publisher_command)
	command("recipes.publish", {.Text}, .Record, "publish a locally realised recipe and its closure to the QUIC cache", recipes_publish_command)
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

	// Start budget option parser accepts exact "unbounded" and refuses all other strings.
	for bad_opt in ([?]string{"", "Unbounded", "UNBOUNDED", "unbounded ", " unbounded", "default", "bounded", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}) {
		opt, matched := start_budget_option_of_text(bad_opt)
		testing.expectf(t, !matched && opt == .Default, "bad start budget option %q matched", bad_opt)
	}
	unb_opt, unb_matched := start_budget_option_of_text("unbounded")
	testing.expect(t, unb_matched && unb_opt == .Unbounded)

	// start("notes", "unbounded") reaches the root start path (not disk hash validation).
	ergonomics_clear_line()
	unb_args := [2]Value{{kind = .Text, text = "notes"}, {kind = .Text, text = "unbounded"}}
	_ = call_run("start", unb_args[:])
	testing.expect(t, failed)
	testing.expect(t, !strings.contains(ergonomics_failure_text(), "64 hexadecimal digits"))
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

@(private = "file")
synth_record_storage: [8][512]u8
@(private = "file")
synth_file_storage: [8][4096]u8

@(private = "file")
register_synthetic_handle :: proc(slot_idx: int, binding: string, mod_name: string, export_names: []string, record_name_str: string, shared_file: []u8) -> (handle_id: u64, rec: Value) {
	handle_id = next_module_handle_id
	next_module_handle_id += 1
	entry := &loaded[loaded_count]
	entry^ = {
		name      = mod_name,
		file      = shared_file,
		place     = -1,
		sandbox   = 0,
		handle_id = handle_id,
	}
	entry.binding_count = copy(entry.binding[:], binding)
	loaded_count += 1

	for exp in export_names {
		cname := copy(names[names_count:], binding)
		names_count += cname
		names[names_count] = '.'
		names_count += 1
		ename := copy(names[names_count:], exp)
		names_count += ename
		full := string(names[names_count - cname - 1 - ename : names_count])
		commands[command_count] = {
			name      = full,
			about     = "synthetic export",
			result    = .Integer,
			file      = shared_file,
			handle_id = handle_id,
		}
		command_count += 1
	}
	if len(record_name_str) > 0 {
		cname := copy(names[names_count:], binding)
		names_count += cname
		names[names_count] = '.'
		names_count += 1
		rname := copy(names[names_count:], record_name_str)
		names_count += rname
		full := string(names[names_count - cname - 1 - rname : names_count])
		commands[command_count] = {
			name      = full,
			about     = "make a record from its fields",
			result    = .Record,
			file      = shared_file,
			record    = 1,
			handle_id = handle_id,
		}
		command_count += 1
	}

	hash: [32]u8
	raw_rec := loaded_record(binding, mod_name, len(export_names), "isolated", hash)
	// Persist record bytes and schema outside transient table_memory, just as
	// assign() copies them into a Variable's own memory object.
	rec_len := copy(synth_record_storage[slot_idx][:], raw_rec.record)
	file_len := copy(synth_file_storage[slot_idx][:], raw_rec.file)
	rec = raw_rec
	rec.record = synth_record_storage[slot_idx][:rec_len]
	rec.file = synth_file_storage[slot_idx][:file_len]
	variables[slot_idx] = {
		value         = rec,
		module_handle = handle_id,
	}
	variables[slot_idx].name_count = copy(variables[slot_idx].name[:], binding)
	return handle_id, rec
}

@(test)
module_handle_precheck_refuses_bare_and_nested_calls :: proc(t: ^testing.T) {
	sync.mutex_lock(&ergonomics_test_lock)
	defer sync.mutex_unlock(&ergonomics_test_lock)
	ergonomics_reset_state()

	refused_cases := [?]struct {
		line:     string,
		contains: string,
	}{
		{`isolate("sample")`, `sample = isolate("sample")`},
		{`load("math")`, `math = load("math")`},
		{`isolate_memory("adder", h, 1)`, `adder = isolate_memory("adder", memory, size)`},
		{`compile_c("adder", "int f() { return 1; }")`, `adder = compile_c("adder", source)`},
		{`1 + isolate("sample")`, `sample = isolate("sample")`},
		{`x = 1 + isolate("sample")`, `sample = isolate("sample")`},
		{`a = isolate_memory("a", isolate("sample"), 1)`, `sample = isolate("sample")`},
		{`s = isolate("sample") |> help`, `sample = isolate("sample")`},
		{`let s = isolate("sample") in 1`, `sample = isolate("sample")`},
		{`isolate("help")`, `m = isolate("help")`},
		{`a.b = isolate("sample")`, `not a plain variable name`},
		{`a.b = load("math")`, `not a plain variable name`},
		{`a.b = compile_c("adder", "int f() { return 1; }")`, `not a plain variable name`},
	}
	for tc in refused_cases {
		ergonomics_clear_line()
		lex_parser.parse_console(tc.line, {form_of = parameter_form_of}, &line_tree_buffers, &line_tree)
		assigned := len(line_tree.assigned_name) > 0
		ok := handle_call_precheck(&line_tree, assigned)
		testing.expectf(t, !ok && failed, "precheck must refuse %q before evaluation", tc.line)
		testing.expectf(t, strings.contains(ergonomics_failure_text(), tc.contains), "refusal for %q must contain %q, got %q", tc.line, tc.contains, ergonomics_failure_text())
	}

	accepted_cases := [?]string{
		`s = isolate("sample")`,
		`m = load("math")`,
		`a = isolate_memory("adder", h, 1)`,
		`c = compile_c("adder", "int f() { return 1; }")`,
		`let s = isolate("sample")`,
		`connect("monitor")`,
		`mon = connect("monitor")`,
	}
	for line in accepted_cases {
		ergonomics_clear_line()
		lex_parser.parse_console(line, {form_of = parameter_form_of}, &line_tree_buffers, &line_tree)
		assigned := len(line_tree.assigned_name) > 0
		ok := handle_call_precheck(&line_tree, assigned)
		testing.expectf(t, ok && !failed, "precheck must accept %q, got %q", line, ergonomics_failure_text())
	}

	// Command Palette prepends a valid, non-colliding binding for handle-returning commands.
	palette_cases := [?]struct {
		cmd:      string,
		arg0:     string,
		expected: string,
	}{
		{"isolate", "sample", "sample = "},
		{"load", "math", "math = "},
		{"isolate", "help", "m = "},
		{"load", "foo.bar", "m = "},
		{"compile_c", "adder", "adder = "},
		{"isolate", "", "m = "},
		{"start", "notes", ""},
	}
	for pc in palette_cases {
		buf: [64]u8
		w := system.Writer{buffer = buf[:]}
		palette_handle_prefix_write(&w, pc.cmd, pc.arg0)
		testing.expect_value(t, string(buf[:w.count]), pc.expected)
	}
}

@(test)
module_handle_binding_checks_refuse_builtin_and_full_variables :: proc(t: ^testing.T) {
	sync.mutex_lock(&ergonomics_test_lock)
	defer sync.mutex_unlock(&ergonomics_test_lock)
	ergonomics_reset_state()

	// Refuses dotted or invalid binding names before spawning anything.
	for bad_target in ([?]string{"a.b", "1bad", "let", "a-b"}) {
		ergonomics_clear_line()
		line_binding_target = bad_target
		_, ok := handle_binding_check("isolate", "sample")
		testing.expectf(t, !ok && failed, "binding target %q must be refused", bad_target)
		testing.expect(t, strings.contains(ergonomics_failure_text(), "not a plain variable name"))
	}

	// Refuses binding over built-in commands before spawning anything.
	for builtin in ([?]string{"help", "start", "unload", "isolate"}) {
		ergonomics_clear_line()
		line_binding_target = builtin
		_, ok := handle_binding_check("isolate", "sample")
		testing.expectf(t, !ok && failed, "binding over built-in %q must be refused", builtin)
		testing.expect(t, strings.contains(ergonomics_failure_text(), "built-in command"))
	}

	// Refuses binding when all VARIABLE_CAPACITY slots are occupied by other names.
	for i in 0 ..< VARIABLE_CAPACITY {
		variables[i].name_count = 3
		variables[i].name[0] = 'v'
		variables[i].name[1] = u8('0' + (i / 10))
		variables[i].name[2] = u8('0' + (i % 10))
	}
	ergonomics_clear_line()
	line_binding_target = "fresh_name"
	_, ok_full := handle_binding_check("isolate", "sample")
	testing.expect(t, !ok_full && failed, "full variable table must refuse a new binding before spawning")
	testing.expect(t, strings.contains(ergonomics_failure_text(), "variables"))

	// Reassigning an already-existing variable slot is allowed even when full.
	ergonomics_clear_line()
	line_binding_target = "v00"
	binding, ok_reuse := handle_binding_check("isolate", "sample")
	testing.expect(t, ok_reuse && !failed && binding == "v00")
}

@(test)
module_handle_isolation_compaction_help_unload_and_reassignment :: proc(t: ^testing.T) {
	sync.mutex_lock(&ergonomics_test_lock)
	defer sync.mutex_unlock(&ergonomics_test_lock)
	ergonomics_reset_state()
	defer ergonomics_reset_state()

	@(static) shared_file: [4]u8 = {1, 2, 3, 4}
	@(static) copied_buf: [256]u8
	h1, rec_a := register_synthetic_handle(0, "a", "tally", []string{"add", "count"}, "State", shared_file[:])
	h2, _ := register_synthetic_handle(1, "b", "tally", []string{"add", "count"}, "State", shared_file[:])
	testing.expect(t, h1 != 0 && h2 != 0 && h1 != h2)
	testing.expect(t, command_find("a.add") != nil && command_find("a.count") != nil && command_find("a.State") != nil)
	testing.expect(t, command_find("b.add") != nil && command_find("b.count") != nil && command_find("b.State") != nil)
	testing.expect(t, command_find("add") == nil && command_find("State") == nil, "no unprefixed global commands may exist")

	// help(a) returns only a's commands (3 rows: a.add, a.count, a.State).
	ergonomics_clear_line()
	help_a := call_run("help", []Value{rec_a})
	testing.expect(t, !failed && help_a.kind == .Table)
	tbl_a, ok_a := table_of(help_a)
	testing.expect(t, ok_a && tbl_a.rows == 3)

	// help("a.add") describes a.add cleanly.
	ergonomics_clear_line()
	help_a_add := call_run("help", []Value{{kind = .Text, text = "a.add"}})
	testing.expect(t, !failed && help_a_add.kind == .Text && strings.contains(help_a_add.text, "a.add"))

	// Non-handle Record is refused by both help and unload.
	ergonomics_clear_line()
	bad_cols := [1]Column{integer_column("value")}
	bad_tbl, _ := made_table("Other_Rec", bad_cols[:])
	_ = made_row(&bad_tbl)
	bad_rec := made_record(&bad_tbl, "test")
	_ = call_run("help", []Value{bad_rec})
	testing.expect(t, failed && strings.contains(ergonomics_failure_text(), "not a module handle"))
	ergonomics_clear_line()
	_ = call_run("unload", []Value{bad_rec})
	testing.expect(t, failed && strings.contains(ergonomics_failure_text(), "not a module handle"))

	// A non-owning copy variable (module_handle == 0) is refused by unload and help.
	copy_len := copy(copied_buf[:], rec_a.record)
	copied_rec := rec_a
	copied_rec.record = copied_buf[:copy_len]
	variables[2] = {value = copied_rec, module_handle = 0}
	variables[2].name_count = copy(variables[2].name[:], "old_a")
	ergonomics_clear_line()
	_ = call_run("unload", []Value{variables[2].value})
	testing.expect(t, failed && strings.contains(ergonomics_failure_text(), "already unloaded"))
	ergonomics_clear_line()
	_ = call_run("help", []Value{variables[2].value})
	testing.expect(t, failed && strings.contains(ergonomics_failure_text(), "already unloaded"))
	variables[2] = {}

	// A detached/mutated copy (as `old with {commands = 12}` creates in scratch)
	// matches no owning Variable slot and must never unload the live handle `a`.
	ergonomics_clear_line()
	_ = call_run("unload", []Value{copied_rec})
	testing.expect(t, failed && strings.contains(ergonomics_failure_text(), "already unloaded"))
	testing.expect(t, command_find("a.add") != nil, "detached copy must never unload live handle a")
	ergonomics_clear_line()
	_ = call_run("help", []Value{copied_rec})
	testing.expect(t, failed && strings.contains(ergonomics_failure_text(), "already unloaded"))

	// unload(a) removes ONLY a's commands, leaves b's commands intact, clears variable a, and compacts names[].
	names_before := names_count
	ergonomics_clear_line()
	unloaded_a := call_run("unload", []Value{rec_a})
	testing.expect(t, !failed && unloaded_a.kind == .Record)
	testing.expect(t, command_find("a.add") == nil && command_find("a.count") == nil && command_find("a.State") == nil)
	testing.expect(t, command_find("b.add") != nil && command_find("b.count") != nil && command_find("b.State") != nil)
	testing.expect(t, variables[0].name_count == 0 && variables[0].module_handle == 0)
	testing.expect(t, names_count < names_before)
	testing.expect_value(t, names_count, len("b.add") + len("b.count") + len("b.State"))

	// Re-unloading the same handle is refused.
	ergonomics_clear_line()
	_ = call_run("unload", []Value{rec_a})
	testing.expect(t, failed && strings.contains(ergonomics_failure_text(), "already unloaded"))

	// Failed assignment to b preserves b's handle and commands.
	ergonomics_clear_line()
	assign("b", Value{kind = .None})
	testing.expect(t, failed)
	testing.expect(t, variables[1].module_handle == h2 && command_find("b.add") != nil)

	// Reassigning b = 42 atomically unloads h2 and clears b's commands.
	ergonomics_clear_line()
	assign("b", Value{kind = .Integer, integer = 42})
	testing.expect(t, !failed)
	testing.expect(t, variables[1].module_handle == 0 && variables[1].value.kind == .Integer && variables[1].value.integer == 42)
	testing.expect(t, command_find("b.add") == nil && loaded_count == 0 && names_count == 0)

	// Repeated add + unload cycles compact names[] with zero leak.
	for cycle in 0 ..< 40 {
		_ = cycle
		ergonomics_clear_line()
		hid, _ := register_synthetic_handle(3, "long_handle_name", "sample", []string{"alpha_export", "beta_export", "gamma_export"}, "Sample_Rec", shared_file[:])
		testing.expect(t, hid != 0 && names_count > 0)
		unload_handle_id(hid, clear_variable = true)
		testing.expect_value(t, names_count, 0)
		testing.expect_value(t, loaded_count, 0)
	}
	// Built-in commands stored in .rodata survive every compaction untouched.
	testing.expect(t, command_find("help") != nil && command_find("unload") != nil)
}

@(test)
recipes_publish_console_commands_validate_inputs_and_help_topics :: proc(t: ^testing.T) {
	sync.mutex_lock(&ergonomics_test_lock)
	defer sync.mutex_unlock(&ergonomics_test_lock)
	ergonomics_reset_state()
	defer ergonomics_reset_state()

	// All three publishing commands are registered as built-ins with exact signatures.
	pk := command_find("recipes.publisher_key")
	cp := command_find("recipes.configure_publisher")
	pb := command_find("recipes.publish")
	testing.expect(t, pk != nil && pk.run != nil && pk.parameter_count == 0 && pk.result == .Text)
	testing.expect(t, cp != nil && cp.run != nil && cp.parameter_count == 1 && cp.parameters[0] == .Text && cp.result == .Text)
	testing.expect(t, pb != nil && pb.run != nil && pb.parameter_count == 1 && pb.parameters[0] == .Text && pb.result == .Record)

	// Help topics exist and return descriptive Text for each command.
	for name in ([?]string{"recipes.publisher_key", "recipes.configure_publisher", "recipes.publish"}) {
		ergonomics_clear_line()
		h := call_run("help", []Value{{kind = .Text, text = name}})
		testing.expectf(t, !failed && h.kind == .Text && strings.contains(h.text, name), "help(%q) must succeed", name)
	}

	// Argument validation refuses empty, short, uppercase, non-hex, and all-zero 64-hex values
	// upfront before attempting any service connection.
	zero_hex := "0000000000000000000000000000000000000000000000000000000000000000"
	upper_hex := "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	non_hex := "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
	short_hex := "deadbeef"
	for bad in ([?]string{"", short_hex, upper_hex, non_hex, zero_hex}) {
		ergonomics_clear_line()
		_ = call_run("recipes.configure_publisher", []Value{{kind = .Text, text = bad}})
		testing.expectf(t, failed, "recipes.configure_publisher(%q) must be refused", bad)
		testing.expect(t, strings.contains(ergonomics_failure_text(), "64 non-zero lowercase hexadecimal digits"))

		ergonomics_clear_line()
		_ = call_run("recipes.publish", []Value{{kind = .Text, text = bad}})
		testing.expectf(t, failed, "recipes.publish(%q) must be refused", bad)
		testing.expect(t, strings.contains(ergonomics_failure_text(), "64 non-zero lowercase hexadecimal digits"))
	}

	// Wrong argument counts are refused cleanly.
	ergonomics_clear_line()
	_ = call_run("recipes.publisher_key", []Value{{kind = .Text, text = "extra"}})
	testing.expect(t, failed)
	ergonomics_clear_line()
	_ = call_run("recipes.configure_publisher", nil)
	testing.expect(t, failed)
	ergonomics_clear_line()
	_ = call_run("recipes.publish", nil)
	testing.expect(t, failed)
}

@(test)
project_install_record_fits_record_size_limit :: proc(t: ^testing.T) {
	sync.mutex_lock(&ergonomics_test_lock)
	defer sync.mutex_unlock(&ergonomics_test_lock)
	ergonomics_reset_state()

	columns := [6]Column{
		text_column("outcome", 16),
		text_column("origin", 16),
		{name = "signer", type = .Bytes, detail = 32, kind = .Hash},
		text_column("recipe", 65),
		{name = "output", type = .Bytes, detail = 32, kind = .Hash},
		text_column("module", 65),
	}
	res_table, made := made_table("Project_Install", columns[:])
	testing.expect(t, made, "Project_Install record must fit inside module.RECORD_SIZE_LIMIT")
	testing.expect_value(t, res_table.size, 226)
	row := made_row(&res_table)
	testing.expect(t, row != nil)
	made_text(&res_table, row, 0, "from_cache")
	made_text(&res_table, row, 1, "local_build")
	made_text(&res_table, row, 3, strings.repeat("a", 64, context.temp_allocator))
	made_text(&res_table, row, 5, strings.repeat("b", 64, context.temp_allocator))
	rec := made_record(&res_table, "projects.install")
	testing.expect(t, !failed && rec.kind == .Record)
}
