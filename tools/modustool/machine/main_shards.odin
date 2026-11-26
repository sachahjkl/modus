// Pure logical shard partitioning table for the monolithic main machine test
// scenario (src/md/infrastructure/fast_build.md).
//
// Partitions `scenario` by exact unique boundary markers into independent
// logical sections of roughly 240 steps each, pairing every section with the
// shared boot prelude and shutdown epilogue without altering `scenario` itself
// or coupling core tool binaries to `main_scenario.odin`.
package machine

// Plan value: number of balanced logical sections partitioning the main machine
// scenario (targeting roughly 240 steps per section across about 2400 steps).
MAIN_SHARD_COUNT :: 10

// Prefix of the machine test part name for each shard of the main scenario.
MAIN_SHARD_PART_PREFIX :: "main_"

// Unique boundary marker identifying one step in a scenario. When next_text is
// non-empty, the immediately following step must carry that exact text.
Main_Shard_Marker :: struct {
	kind:      Step_Kind,
	text:      string,
	next_text: string,
}

// Declarative specification of one logical shard of the main scenario.
Main_Shard_Spec :: struct {
	name:      string,
	part_name: string,
	summary:   string,
	start:     Main_Shard_Marker,
}

// Shared usable-boot prelude of the main scenario, kept in the core tool so
// `modustool boot-snapshot` compiles without `main_scenario.odin`. A host test
// verifies step-for-step equality with `scenario[:prelude_end]`.
MAIN_BOOT_PRELUDE := [?]Step {
	{kind = .Wait, text = "boot program: ok"},
	{kind = .Wait, text = "kernel: steal time: "},
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "kernel: boot: firmware: ", any_order = true},
	{kind = .Wait, text = "kernel: boot: boot program: load the kernel, the boot image: ", any_order = true},
	{kind = .Wait, text = "kernel: boot: boot program: page tables, memory map, jump: ", any_order = true},
	{kind = .Wait, text = "kernel: boot: kernel: page frames, kernel page table: ", any_order = true},
	{kind = .Wait, text = "kernel: boot: kernel: first processor, timer: ", any_order = true},
	{kind = .Wait, text = "kernel: boot: kernel: other processors: ", any_order = true},
	{kind = .Wait, text = "kernel: boot: kernel: root service: ", any_order = true},
	{kind = .Wait, text = "wired_writer: wrote 16 numbers to 1 reader, and ended numbers", any_order = true, fails_on = "wired_writer: wrote 16 numbers to 0 reader"},
	{kind = .Wait, text = "wired_reader: read the joined record of 0, the 16 numbers of wired_writer in order, and a clean end", any_order = true, fails_on = "wired_reader: no writer came"},
	{kind = .Wait, text = "wired_reader: read the joined record of 0, the 16 numbers of wired_writer in order, and a clean end", any_order = true, fails_on = "wired_reader: WRONG"},
	{kind = .Wait, text = "root: ok"},
	{kind = .Wait, text = "root: Machine_Stop refused the codes 256 and 18446744073709551615 with Argument_Refused and the record Bad_Value of the code, limit 255, and the machine runs on: as it must"},
	{kind = .Wait, text = "input: ok, the mouse has a wheel", any_order = true},
	{kind = .Date, text = " UTC, seconds since 1970 ", any_order = true},
	{kind = .Wait, text = "compositor: two screen pages: each frame reaches the screen whole, by a page flip", any_order = true, fails_on = "compositor: one screen page"},
	{kind = .Screen_Size, text = SCREEN_SIZE_LINE, any_order = true},
	{kind = .Wait, text = "compositor: first frame", any_order = true},
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Wait, text = "compositor: the script greek: the chain of the interface draws 49 of its 49 characters, the chain of the cells 49", any_order = true},
	{kind = .Wait, text = "compositor: the script cyrillic: the chain of the interface draws 96 of its 96 characters, the chain of the cells 96", any_order = true},
	{kind = .Wait, text = "compositor: the script box drawing: the chain of the interface draws 160 of its 160 characters, the chain of the cells 160", any_order = true},
	{kind = .Wait, text = "storage: ok, a new disk: generation 1, 16384 blocks", any_order = true},
	{kind = .Wait, text = "root: connected console to the store of its line history in the service storage, 24 blocks", any_order = true},
	{kind = .Wait, text = "console: no line history kept: the history starts empty", any_order = true},
	{kind = .Move, text = "console", to_x = 64, to_y = 56},
	{kind = .Wait, text = "settings: the boot pass: no settings kept: the defaults: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 1.25; in ", any_order = true},
	{kind = .Wait, text = "root: settings stopped: itself, done"},
}

// Resolved 0-based half-open [first, end) slices of one main scenario shard.
Main_Shard_Range :: struct {
	name:           string,
	summary:        string,
	prelude_first:  int,
	prelude_end:    int,
	body_first:     int,
	body_end:       int,
	epilogue_first: int,
	epilogue_end:   int,
}

// Closed border refusal set for main scenario shard partitioning.
Main_Shard_Refusal :: enum u8 {
	None,
	Empty_Scenario,
	Prelude_Not_Found,
	Prelude_Ambiguous,
	Epilogue_Not_Found,
	Epilogue_Ambiguous,
	Marker_Not_Found,
	Marker_Ambiguous,
	Order_Invalid,
	Coverage_Gap,
	Shard_Out_Of_Range,
}

// Last step of the shared boot prelude in `main_scenario.odin`.
MAIN_SHARD_PRELUDE_END :: Main_Shard_Marker {
	kind = .Wait,
	text = "root: settings stopped: itself, done",
}

// First step of the shared shutdown epilogue in `main_scenario.odin`.
MAIN_SHARD_EPILOGUE_START :: Main_Shard_Marker {
	kind      = .Type,
	text      = "memory()",
	next_text = "free_no_budget_holds  0 pages",
}

// Ordered logical shard boundaries of `main_scenario.odin`.
@(rodata)
main_shard_specs := [MAIN_SHARD_COUNT]Main_Shard_Spec {
	{
		name      = "console_and_desktop",
		part_name = "main_console_and_desktop",
		summary   = "Console language, UTF-8 fallback glyphs, desktop windows, and palette search",
		start     = {kind = .Type, text = "1 + 2 * 3"},
	},
	{
		name      = "palette_provider",
		part_name = "main_palette_provider",
		summary   = "Fault isolation, palette confirmation, console palette commands, settings, and revocation",
		start     = {kind = .Launch, text = "fault"},
	},
	{
		name      = "console_calls_and_compiler",
		part_name = "main_console_calls_and_compiler",
		summary   = "Console diagnostics, direct and isolated calls, pipes, revocation, assembler, and C compiler",
		start     = {kind = .Type, text = "where(processes(), name = \"paint\")"},
	},
	{
		name      = "demos_and_concurrency",
		part_name = "main_demos_and_concurrency",
		summary   = "Remote allow, demonstrations, IPC rings, threads, locks, budgets, clock, and scheduler",
		start     = {kind = .Type, text = "remote_allow(\"{client key}\")"},
	},
	{
		name      = "memory_and_services",
		part_name = "main_memory_and_services",
		summary   = "Virtual memory, boot display, paging, frame runs, and multi-role services",
		start     = {kind = .Launch, text = "address_space"},
	},
	{
		name      = "manual_and_imports",
		part_name = "main_manual_and_imports",
		summary   = "Manual pages and Markdown checks, library imports, and loader refusals",
		start     = {kind = .Launch, text = "manual"},
	},
	{
		name      = "log_and_streams",
		part_name = "main_log_and_streams",
		summary   = "Log scopes and facts, record outputs, merge and filter streams, and root refusals",
		start     = {kind = .Launch, text = "log"},
	},
	{
		name      = "tables_terminal_and_storage",
		part_name = "main_tables_terminal_and_storage",
		summary   = "Table call parameters, terminal scroll and flood, block device, and storage service",
		start     = {kind = .Type, text = "sd = load(\"sample\")"},
	},
	{
		name      = "notes_editor_inspect_and_ui",
		part_name = "main_notes_editor_inspect_and_ui",
		summary   = "Notes versions, editor undo, diagnostic errors, inspect, interface elements, fonts, and pointers",
		start     = {kind = .Launch, text = "notes"},
	},
	{
		name      = "settings_editor_and_builders",
		part_name = "main_settings_editor_and_builders",
		summary   = "Live settings, scale and appearance, tables conformance, line editor, and sandboxed builders",
		start     = {kind = .Launch, text = "settings", next_text = "compositor: surface settings"},
	},
}

// Per-shard minimal setup steps making each shard self-contained when run on
// its own machine (from cold boot or from a restored usable-boot QMP snapshot).
@(private = "file")
main_shard_setup_palette_provider := [?]Step {
	{kind = .Launch, text = "monitor"},
	{kind = .Wait, text = "compositor: surface monitor"},
	{kind = .Move, text = "monitor", to_x = 568, to_y = 40},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"plasma\")"},
	{kind = .Wait, text = "compositor: surface plasma"},
	{kind = .Move, text = "plasma", to_x = 232, to_y = 144},
}

@(private = "file")
main_shard_setup_console_calls_and_compiler := [?]Step {
	{kind = .Launch, text = "monitor"},
	{kind = .Wait, text = "compositor: surface monitor"},
	{kind = .Move, text = "monitor", to_x = 568, to_y = 40},
	{kind = .Launch, text = "paint"},
	{kind = .Wait, text = "compositor: surface paint"},
	{kind = .Move, text = "paint", to_x = 520, to_y = 408},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "name = \"kernel\""},
	{kind = .Type, text = "connect(\"monitor\")"},
	{kind = .Wait, text = "[console]   module     monitor"},
}

@(private = "file")
main_shard_setup_memory_and_services := [?]Step {
	{kind = .Type, text = "start(\"life\")"},
	{kind = .Wait, text = "compositor: surface life"},
	{kind = .Move, text = "life", to_x = 24, to_y = 408},
	{kind = .Launch, text = "monitor"},
	{kind = .Wait, text = "compositor: surface monitor"},
	{kind = .Move, text = "monitor", to_x = 568, to_y = 40},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "revoke(\"monitor\", \"machine\")"},
	{kind = .Wait, text = "root: revoked the grant machine of monitor, holdings ended: 1"},
}

@(private = "file")
main_shard_setup_manual_and_imports := [?]Step {
	{kind = .Launch, text = "tally"},
	{kind = .Wait, text = "tally: ok", any_order = true},
	{kind = .Wait, text = "compositor: surface tally"},
	{kind = .Move, text = "tally", to_x = 616, to_y = 528},
	{kind = .Front, text = "console"},
}

@(private = "file")
main_shard_setup_log_and_streams := [?]Step {
	{kind = .Type, text = "start(\"life\")"},
	{kind = .Wait, text = "compositor: surface life"},
	{kind = .Move, text = "life", to_x = 24, to_y = 408},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "p = isolate(\"probe\")"},
	{kind = .Wait, text = "[console]   call       isolated"},
	{kind = .Type, text = "remote_allow(\"{client key}\")"},
	{kind = .Wait, text = "root: principal 0 allowed the client key "},
	{kind = .Launch, text = "remote"},
	{kind = .Wait, text = "root: started remote", any_order = true},
	{kind = .Remote_Key, text = "remote: the public key of this service: "},
	{kind = .Wait, text = "remote: listening on the UDP port 7100, for the host 10.0.2.2 only", any_order = true},
	{kind = .Call, text = "compositor.pointer()", expected = "1 rows of Pointer", pointer = true},
	{kind = .Front, text = "console"},
}

@(private = "file")
main_shard_setup_tables_terminal_and_storage := [?]Step {
	{kind = .Launch, text = "monitor"},
	{kind = .Wait, text = "compositor: surface monitor"},
	{kind = .Move, text = "monitor", to_x = 568, to_y = 40},
	{kind = .Launch, text = "log"},
	{kind = .Wait, text = "[log] log: ok, ", any_order = true},
	{kind = .Wait, text = " gone before its start, 0 lost since, "},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "revoke(\"console\", \"palette\")"},
	{kind = .Wait, text = "root: revoked the grant palette of console"},
	{kind = .Type, text = "remote_allow(\"{client key}\")"},
	{kind = .Wait, text = "root: principal 0 allowed the client key "},
	{kind = .Launch, text = "remote"},
	{kind = .Wait, text = "root: started remote", any_order = true},
	{kind = .Remote_Key, text = "remote: the public key of this service: "},
	{kind = .Wait, text = "remote: listening on the UDP port 7100, for the host 10.0.2.2 only", any_order = true},
	{kind = .Call, text = "compositor.pointer()", expected = "1 rows of Pointer", pointer = true},
	{kind = .Front, text = "console"},
}

@(private = "file")
main_shard_setup_notes_editor_inspect_and_ui := [?]Step {
	{kind = .Launch, text = "monitor"},
	{kind = .Wait, text = "compositor: surface monitor"},
	{kind = .Move, text = "monitor", to_x = 568, to_y = 40},
	{kind = .Launch, text = "log"},
	{kind = .Wait, text = "[log] log: ok, ", any_order = true},
	{kind = .Wait, text = " gone before its start, 0 lost since, "},
	{kind = .Launch, text = "threads"},
	{kind = .Wait, text = "threads: ok, 4 threads draw in one surface"},
	{kind = .Launch, text = "workers"},
	{kind = .Wait, text = "workers: ok, 4 threads computed 140 tiles: "},
	{kind = .Move, text = "workers", to_x = 304, to_y = 328},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "remote_allow(\"{client key}\")"},
	{kind = .Wait, text = "root: principal 0 allowed the client key "},
	{kind = .Launch, text = "remote"},
	{kind = .Wait, text = "root: started remote", any_order = true},
	{kind = .Remote_Key, text = "remote: the public key of this service: "},
	{kind = .Wait, text = "remote: listening on the UDP port 7100, for the host 10.0.2.2 only", any_order = true},
	{kind = .Call, text = "compositor.pointer()", expected = "1 rows of Pointer", pointer = true},
	{kind = .Front, text = "console"},
}

@(private = "file")
main_shard_setup_settings_editor_and_builders := [?]Step {
	{kind = .Launch, text = "monitor"},
	{kind = .Wait, text = "compositor: surface monitor"},
	{kind = .Move, text = "monitor", to_x = 568, to_y = 40},
	{kind = .Launch, text = "rings"},
	{kind = .Wait, text = "rings: ok, 6 processes, 6 rings, 5 records"},
	{kind = .Move, text = "rings", to_x = 176, to_y = 32},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"time_page\")"},
	{kind = .Wait, text = "display: time_page" + WINDOW_TAKEN, any_order = true},
	{kind = .Wait, text = "time_page: ok, the time never went back, the page and the kernel give the same time, the kernel refuses to remove the time page"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"monitor\")"},
	{kind = .Wait, text = "[console]   module     monitor"},
	{kind = .Type, text = "remote_allow(\"{client key}\")"},
	{kind = .Wait, text = "root: principal 0 allowed the client key "},
	{kind = .Launch, text = "remote"},
	{kind = .Wait, text = "root: started remote", any_order = true},
	{kind = .Remote_Key, text = "remote: the public key of this service: "},
	{kind = .Wait, text = "remote: listening on the UDP port 7100, for the host 10.0.2.2 only", any_order = true},
	{kind = .Call, text = "compositor.pointer()", expected = "1 rows of Pointer", pointer = true},
	{kind = .Front, text = "console"},
}

// main_shard_setup_steps returns the minimal setup steps needed before shard
// body steps when running shard in its own isolated VM.
main_shard_setup_steps :: proc(shard_name: string) -> []Step {
	switch shard_name {
	case "palette_provider":
		return main_shard_setup_palette_provider[:]
	case "console_calls_and_compiler":
		return main_shard_setup_console_calls_and_compiler[:]
	case "memory_and_services":
		return main_shard_setup_memory_and_services[:]
	case "manual_and_imports":
		return main_shard_setup_manual_and_imports[:]
	case "log_and_streams":
		return main_shard_setup_log_and_streams[:]
	case "tables_terminal_and_storage":
		return main_shard_setup_tables_terminal_and_storage[:]
	case "notes_editor_inspect_and_ui":
		return main_shard_setup_notes_editor_inspect_and_ui[:]
	case "settings_editor_and_builders":
		return main_shard_setup_settings_editor_and_builders[:]
	}
	return nil
}

// main_shard_marker_find counts every step matching marker and returns the
// index of the first match alongside the total match count.
main_shard_marker_find :: proc(steps: []Step, marker: Main_Shard_Marker) -> (first_index: int, matches: int) {
	first_index = -1
	for step, index in steps {
		if step.kind != marker.kind || step.text != marker.text {
			continue
		}
		if marker.next_text != "" {
			if index + 1 >= len(steps) || steps[index + 1].text != marker.next_text {
				continue
			}
		}
		if matches == 0 {
			first_index = index
		}
		matches += 1
	}
	return first_index, matches
}

// main_scenario_shards_of resolves an ordered shard specification table against
// steps, verifying unique markers, strict ordering, and gap-free coverage of
// every step between prelude_end_marker and epilogue_start_marker.
main_scenario_shards_of :: proc(
	steps: []Step,
	specs: []Main_Shard_Spec,
	prelude_end_marker: Main_Shard_Marker,
	epilogue_start_marker: Main_Shard_Marker,
	allocator := context.allocator,
) -> (
	shards: []Main_Shard_Range,
	refusal: Main_Shard_Refusal,
) {
	if len(steps) == 0 || len(specs) == 0 {
		return nil, .Empty_Scenario
	}
	prelude_last, prelude_matches := main_shard_marker_find(steps, prelude_end_marker)
	if prelude_matches == 0 {
		return nil, .Prelude_Not_Found
	}
	if prelude_matches > 1 {
		return nil, .Prelude_Ambiguous
	}
	prelude_end := prelude_last + 1

	epilogue_first, epilogue_matches := main_shard_marker_find(steps, epilogue_start_marker)
	if epilogue_matches == 0 {
		return nil, .Epilogue_Not_Found
	}
	if epilogue_matches > 1 {
		return nil, .Epilogue_Ambiguous
	}
	if prelude_end >= epilogue_first {
		return nil, .Order_Invalid
	}

	starts := make([]int, len(specs), context.temp_allocator)
	for spec, index in specs {
		found_at, match_count := main_shard_marker_find(steps, spec.start)
		if match_count == 0 {
			return nil, .Marker_Not_Found
		}
		if match_count > 1 {
			return nil, .Marker_Ambiguous
		}
		starts[index] = found_at
	}

	if starts[0] < prelude_end {
		return nil, .Order_Invalid
	}
	if starts[0] > prelude_end {
		return nil, .Coverage_Gap
	}
	for index in 1 ..< len(starts) {
		if starts[index] <= starts[index - 1] {
			return nil, .Order_Invalid
		}
	}
	if starts[len(starts) - 1] >= epilogue_first {
		return nil, .Order_Invalid
	}

	out := make([]Main_Shard_Range, len(specs), allocator)
	for spec, index in specs {
		body_end := index + 1 < len(specs) ? starts[index + 1] : epilogue_first
		out[index] = Main_Shard_Range {
			name           = spec.name,
			summary        = spec.summary,
			prelude_first  = 0,
			prelude_end    = prelude_end,
			body_first     = starts[index],
			body_end       = body_end,
			epilogue_first = epilogue_first,
			epilogue_end   = len(steps),
		}
	}
	return out, .None
}

// main_scenario_shards resolves the canonical main_shard_specs table against
// the provided main scenario step slice.
main_scenario_shards :: proc(steps: []Step, allocator := context.allocator) -> (shards: []Main_Shard_Range, refusal: Main_Shard_Refusal) {
	return main_scenario_shards_of(steps, main_shard_specs[:], MAIN_SHARD_PRELUDE_END, MAIN_SHARD_EPILOGUE_START, allocator)
}

// main_shard_find locates a resolved shard by name.
main_shard_find :: proc(shards: []Main_Shard_Range, name: string) -> (shard: Main_Shard_Range, found: bool) {
	for item in shards {
		if item.name == name {
			return item, true
		}
	}
	return {}, false
}

// main_shard_step_span returns the 1-based inclusive Step_Span of shard's body
// for use with `modustool test main steps ...`.
main_shard_step_span :: proc(shard: Main_Shard_Range) -> Step_Span {
	return {first = shard.body_first + 1, last = shard.body_end}
}

// main_shard_steps materializes the full runnable step slice (shared boot
// prelude, shard body, and shared shutdown epilogue) for one shard.
main_shard_steps :: proc(steps: []Step, shard: Main_Shard_Range, allocator := context.allocator) -> (out: []Step, refusal: Main_Shard_Refusal) {
	n := len(steps)
	if n == 0 {
		return nil, .Empty_Scenario
	}
	if shard.prelude_first < 0 || shard.prelude_end < shard.prelude_first || shard.prelude_end > n ||
	   shard.body_first < shard.prelude_end || shard.body_end <= shard.body_first || shard.body_end > n ||
	   shard.epilogue_first < shard.body_end || shard.epilogue_end < shard.epilogue_first || shard.epilogue_end > n {
		return nil, .Shard_Out_Of_Range
	}
	prelude_len := shard.prelude_end - shard.prelude_first
	body_len := shard.body_end - shard.body_first
	epilogue_len := shard.epilogue_end - shard.epilogue_first
	out = make([]Step, prelude_len + body_len + epilogue_len, allocator)
	copy(out[:prelude_len], steps[shard.prelude_first:shard.prelude_end])
	copy(out[prelude_len : prelude_len + body_len], steps[shard.body_first:shard.body_end])
	copy(out[prelude_len + body_len:], steps[shard.epilogue_first:shard.epilogue_end])
	return out, .None
}

// main_shard_runnable_steps materializes a self-contained runnable step slice
// for shard: optional boot prelude (omitted when restoring a usable-boot QMP
// snapshot), minimal per-shard setup steps, the shard body, and the shared
// shutdown epilogue.
main_shard_runnable_steps :: proc(steps: []Step, shard: Main_Shard_Range, include_prelude: bool, allocator := context.allocator) -> (out: []Step, refusal: Main_Shard_Refusal) {
	n := len(steps)
	if n == 0 {
		return nil, .Empty_Scenario
	}
	if shard.prelude_first < 0 || shard.prelude_end < shard.prelude_first || shard.prelude_end > n ||
	   shard.body_first < shard.prelude_end || shard.body_end <= shard.body_first || shard.body_end > n ||
	   shard.epilogue_first < shard.body_end || shard.epilogue_end < shard.epilogue_first || shard.epilogue_end > n {
		return nil, .Shard_Out_Of_Range
	}
	setup := main_shard_setup_steps(shard.name)
	prelude_len := include_prelude ? (shard.prelude_end - shard.prelude_first) : 0
	setup_len := len(setup)
	body_len := shard.body_end - shard.body_first
	epilogue_len := shard.epilogue_end - shard.epilogue_first
	// Bring `console` to the front before the shared epilogue types `memory()`
	// and `shutdown()`, because a shard body can finish with another window
	// focused.
	epilogue_front := epilogue_len > 0 ? 1 : 0
	out = make([]Step, prelude_len + setup_len + body_len + epilogue_front + epilogue_len, allocator)
	offset := 0
	if prelude_len > 0 {
		copy(out[offset : offset + prelude_len], steps[shard.prelude_first:shard.prelude_end])
		offset += prelude_len
	}
	if setup_len > 0 {
		copy(out[offset : offset + setup_len], setup)
		offset += setup_len
	}
	copy(out[offset : offset + body_len], steps[shard.body_first:shard.body_end])
	offset += body_len
	if epilogue_front > 0 {
		out[offset] = {kind = .Front, text = "console"}
		offset += 1
	}
	copy(out[offset : offset + epilogue_len], steps[shard.epilogue_first:shard.epilogue_end])
	return out, .None
}
