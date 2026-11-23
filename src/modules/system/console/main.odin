// The console: a process that has a terminal. The input
// types expressions of a small language. A command is a function with typed
// parameters and a typed result; it is not a separate process, and it does
// not parse text.
//
// **What it is for.** The console is the place where the principal talks to
// the system. It shows that a [command](term:command) is a function: the
// console reads the [record description](term:record-description) of each
// [export](term:export) of a module, types each argument from it, calls the
// export, and draws the typed result by its kind: an Integer, a Text, a
// Record, a Table, a Handle, Bytes or an error. No command parses a line of
// text, and no command prints: a command gives a result, and the console
// draws it (docs/CONSOLE.md, "Results and their drawers"). The same description serves a [direct call](term:direct-call), an
// [isolated call](term:isolated-call) and a call to a [service](term:service).
//
// **What a reader sees.** The root service starts the console at each
// boot, after the compositor and `date`. The console has no surface: it
// writes records to its [terminal](term:terminal) and reads keys from it
// (src/library/modus/terminal); the process `terminal` draws them in a window. The
// first line is `kernel console. A command is a typed function: try
// help()`, and the log gets `console: ready`. Each line that the input
// enters goes to the log too, after the prompt `> `.
//
// **The language** (`language.odin`): a line is an expression or
// `name = expression`. A value is an Integer, a Text, a Record, a Handle, a
// Table or Bytes. Examples of lines:
//
// ```
// help()
// x = 6 * 7
// load("math")
// connect("log")
// log.records(0)
// log.records(0) |> where(level = Error)
// log.records(0) |> facts(log_reader.Fact_Probe)
// start("life")
// where(grants("remote"), state = "held")
// sort(where(processes(), state = "waiting"), "name")
// ```
//
// **The commands of the console itself** (`commands.odin`, `tables.odin`,
// `debugger_commands.odin`, `facts.odin`):
//
// - Modules: `modules()`, `load(name)` (a direct call: the module runs with
//   the memory and the handles of the console), `isolate(name)` (an
//   isolated call: the module runs in a [call host](term:call-host), with
//   nothing of the console), `unload(name)`, `loaded()`.
// - Services: `connect(name)` makes each export of a running service a
//   command `name.export`.
// - Processes: `processes()` (the export `monitor.processes`, under a short
//   name), `process_modules()`, `start(name)`, `stop(name)`,
//   `grants(name)`, `revoke(name, grant)`.
// - The debugger: `debug(process)`, `break_at(place)`, `stack(thread)`,
//   `locals(thread, frame)`, `step(thread)`, `detach()` and the others:
//   each one is an export of the service `debugger` under a short name
//   (docs/CONSOLE.md, "The commands of the debugger").
// - Principals: `principal_create(name)`, `lock()`, `principals()`.
// - Replacements: `replace(module, other)`, `replacements()`.
// - Tables: `where`, `sort`, `join`, `columns`, `first`, `skip`, `rows`,
//   `row`. `where` takes a condition on a field: `where(t, block = 12)`.
// - Record streams: a typed name, `output_counter.counts`, reads a record
//   output of a process that the console started; `where`, `first` and
//   `table` take it, and `record_outputs(module)` lists them
//   (docs/CONSOLE.md, "Streams").
// - Log facts: `facts(table, package.Type)`, the fields of one fact type
//   of the rows of `log.records` as columns.
// - Others: `help()`, `describe(name)`, `memory()`, `locks()`, `time()`,
//   `hash(text)`, `buffer(pages)`, `bytes(memory, first, count)`,
//   `variables()`, `clear()`, `shutdown()`, `history_clear()`.
//
// **The log records of a line.** While a line calls an export, the console
// shows under the line the log records that the called process writes, by
// process, with each value in the color of its value kind; a
// [log fact](term:log-fact) is the sentence of its fact template. It reads
// them as any caller does: from the service `log`
// (docs/CONSOLE.md, "The log records of a line").
//
// **The keys** (docs/CONSOLE.md, "1. The keys"): Enter runs the line; Tab
// and the typed name open the [completion list](term:completion-list); Up
// and Down walk the [line history](term:line-history); Escape stops an
// isolated call that does not return, and the read of a record stream.
//
// **The two threads.** The first thread reads the keys and owns the
// [edit line](term:edit-line), the line history and the completion list.
// The second thread runs the lines. During a line, the first thread keeps
// the keys that the input types, shows the time of the line, and stops an
// isolated call when the input presses Escape. A slow command never
// freezes the edit line.
//
// **Its grants** (the root service, `start_grant_sets`), each for one group of
// commands:
//
// - **Root_Ring**: start and stop processes, and connect to every service.
// - **Inspect**: `memory()`, `locks()` and `process_modules()` read the
//   reports of the machine.
// - **Stop**: `shutdown()` stops the machine.
// - **Image** and **Debug_Image**: `load` and `isolate` read modules of the
//   boot image; a stop report of an isolated call names its procedures.
// - **Terminal**: its terminal.
// - **Store**: a private store in the storage service.
// - **Acts_For_Principal**: a service shows it what it holds for all
//   callers (the log records, the processes of `monitor`).
// - **Replacements** and **Replace**: read and change the
//   [replacement table](term:replacement-table).
// - **History_Store**: the store of its line history, apart from its
//   private store (docs/CONSOLE.md, "6. The line history across a stop").
// - **Palette**: the console is the [palette provider](term:palette-provider):
//   its commands show in the palette of the desktop
//   (docs/CONSOLE.md, "8. The palette provider").
//
// Its budget has room for 5 processes and 6 threads: the console, its 4
// [sandboxes](term:sandbox) of isolated calls, and their threads.
//
// **What it does not prove.** The console acts for principal 0 only: the
// storage service refuses it the stores of a
// [named principal](term:named-principal) (docs/PRINCIPALS.md). It does not
// show that a process that is not the console cannot reach these commands:
// that is the work of the grants of the root service.
package console

import "modus:contract/text_encoding"
import "modus:contract/value_kinds"
import "modus:lex_evaluator"
import "modus:display"
import "modus:key_path"
import "modus:line_editor"
import "modus:random"
import "modus:system"
import terminal "modus:terminal"
import "modus:text_rendering"
import "base:intrinsics"

// Itself and four sandboxes, each a call host with its thread. The working
// memory holds 7583 pages, and the 144 pages of the stack of the second
// thread past the stack of a thread that names no size.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 7731, processes = 5, threads = 6}

// The stack of the second thread, which runs the lines: the bytes that the
// evaluator may take, and 128 KiB for the host and the command that a call
// runs at the deepest place of a line.
LINE_THREAD_STACK_PAGES :: 160

#assert(LINE_THREAD_STACK_PAGES * system.PAGE_SIZE == lex_evaluator.EVALUATION_STACK_BYTES + 128 * 1024)
#assert(LINE_THREAD_STACK_PAGES - system.THREAD_STACK_PAGES == 144)

LINE_CAPACITY :: line_editor.LINE_CAPACITY
PROMPT :: "> "
PENDING_CAPACITY :: 128
STATUS_INTERVAL :: 100 // Milliseconds between two texts of the time of a line.

Key :: terminal.Key

// The line that the second thread runs. The two threads share this record.
Work :: struct {
	text:     [LINE_CAPACITY]u8,
	count:    int,
	since:    u64, // The time when the line started.
	started:  u32, // The lines that the first thread gave.
	finished: u32, // The lines that the second thread ran.
	refresh:  u32, // 1: the second thread calls the getters of the palette when no line waits.
	wake:     u32, // The first thread adds 1 for a line or a refresh. The second thread waits on this word.
	cancel:   u32, // 1: the input pressed Escape. An isolated call waits on this word.
	// 1: the line is in a call that Escape can stop (a call of a sandboxed
	// process or of a service). The second thread writes it; the first
	// thread reads it to know what Escape means.
	call_stoppable: u32,
}

work: Work
running: bool // For the first thread: a line runs.
pending: line_editor.Waiting_Keys(Key, PENDING_CAPACITY) // The keys that the input typed during a line.
keys_loss: key_path.Loss_Period // The keys that found `pending` full while Escape could stop the call of the line.
// The second thread adds 1 when it ends a line. The first thread waits on
// this word.
changes: u32
// The terminal ring has one writer: the two threads write with this lock.
output_lock: system.Lock

output: terminal.Terminal
line: line_editor.Line
// The lines entered so far. Up and Down walk them: history_place 0 is the
// line that the input types (kept in draft while an older line shows),
// n the line of age n - 1.
history: line_editor.History
// The second thread saves the history after the line ended, while the
// first thread can add the next line: it copies the history under this
// lock, and the first thread adds a line under it. The lock is held for
// one copy in memory, never for a call of the storage service.
history_lock: system.Lock
history_place: int
draft: line_editor.Line
// The output line that goes to the log of the kernel when it ends: one Log
// call takes system.LOG_CALL_LIMIT bytes. A longer line goes to the log in
// parts of that size, each one a line of the log: nothing is cut.
log_line: [system.LOG_CALL_LIMIT]u8
log_count: int

ctx: ^system.Context

// The random generator of this process (src/library/modus/random).
process_generator: random.Generator

// entry starts the console and runs its first thread: it reads the keys
// until the machine stops.
//
// **What it sets up**, in order:
//
// 1. The random generator, from the seed that the root service wrote in the
//    context: it gives the seed of each process that the console starts.
// 2. The terminal (`terminal.open`).
// 3. The commands (`commands_start`): it maps the boot image, the debug
//    image, the root ring and the replacement table that the root service
//    granted, and lists the commands of the console.
// 4. The second thread, `run_lines`, which runs each line.
// 5. The first line on the terminal, the edit line, and the log record
//    `console: ready`.
// 6. The line history of the run before, from its store (`history_load`).
//
// **The loop.** The thread takes each key of the terminal ring. With no
// line running, the key edits the line, opens the completion list, walks
// the history, or runs the line (`key`). While a line runs, Escape asks the
// second thread to stop the isolated call, and each other key waits, in
// order, until the line ends. 128 keys wait in the console; the keys after
// them stay in the terminal ring, in order, and the console takes them
// when the line ends. Only while Escape can stop a call of the line does
// the console read on with 128 keys waiting, to find that Escape: a key
// that is not Escape is then lost, and the log has the count
// (docs/CONSOLE.md, "When a line ends, and the keys typed during a line"). The thread then waits for
// a key, for a change of the second thread, or for 100 ms while a line
// runs, so that the time of the line on the screen moves.
//
// **The stop.** With no random seed or no terminal, the console writes the
// reason on the log (`console: no terminal`) and stops with `Refused`; with
// no second thread, with `Failed`. Else it never returns: `stop("console")` or
// `shutdown()` ends it.
@(export, link_name = "entry")
entry :: proc "c" (start_context: ^system.Context) -> ! {
	// The random generator of this process, from the seed that its starter
	// gave: it gives the seed of each process that this one starts.
	if !random.generator_from_context(&process_generator, start_context) {
		system.log_fact(.Info, No_Random_Seed{})
		system.stop(.Refused)
	}
	ctx = start_context
	ok: bool
	if output, ok = terminal.open(ctx); !ok {
		system.log_fact(.Info, No_Terminal{})
		system.stop(.Refused)
	}
	commands_start()
	palette_provider_start() // palette_provider.odin
	if _, status := system.thread_start(run_lines, nil, LINE_THREAD_STACK_PAGES); status != .Ok {
		system.log_fact(.Info, Thread_Not_Started{})
		system.stop(.Failed)
	}
	print("kernel console. A command is a typed function: try help()\n")
	edit_show()
	system.log_fact(.Info, Ready{})
	// The line history of the run before. The second thread runs no line
	// yet: the history has one user. The keys that come meanwhile wait in
	// the terminal ring.
	history_load()

	for {
		seen := intrinsics.atomic_load_explicit(&changes, .Acquire)
		for {
			// One read of the line for this key: the decision to take the
			// key and the action on it use the same read. The call of the
			// line can end between two reads, and two reads then took a
			// key that only an Escape could justify and dropped it.
			line_now := running_line_read()
			if !line_editor.running_key_can_be_taken(line_now, pending.count, PENDING_CAPACITY) {
				// No place for a key, and no key can act now: the keys
				// stay in the terminal ring, in order, and none is lost.
				break
			}
			given := terminal.input(&output) or_break
			switch given.kind {
			case .None, .Resized:
				continue
			case .List_First:
				// The scroll bar of the completion list: a line that
				// runs has no list, so the record then means nothing.
				if !running {
					completion_view_move(given.list_first)
				}
				continue
			case .Key:
			}
			pressed := given.key
			if !running {
				key(pressed)
				continue
			}
			// Each key waits for the end of the line, in order: it then
			// means what it means when typed slowly. Escape acts at once
			// only when the line waits in a call that it can stop; if not,
			// it is a key of the next line, as the keys before it.
			switch line_editor.running_key_action(pressed.code == display.KEY_ESCAPE, line_now, pending.count, PENDING_CAPACITY) {
			case .Stop_Call:
				system.log_fact(.Info, Escape_Stops_Line{line_time = value_kinds.Time_In_Milliseconds(system.time() - work.since), waiting_keys = u64(pending.count)})
				intrinsics.atomic_store(&work.cancel, 1)
				system.word_wake(&work.cancel)
			case .Wait:
				line_editor.waiting_keys_add(&pending, pressed)
				// The edit line shows each key that waits.
				key_serial_in_line = max(key_serial_in_line, pressed.serial)
			case .Drop:
				// The console must read each key to find an Escape that
				// stops the call, and it has no place for this one.
				if key_path.loss_count(&keys_loss) {
					system.log_fact(.Info, Waiting_Keys_Full{capacity = u64(PENDING_CAPACITY)})
				}
			}
		}
		if running && intrinsics.atomic_load_explicit(&work.finished, .Relaxed) == work.started {
			running = false
			if lost, ended := key_path.loss_end(&keys_loss); ended {
				system.log_fact(.Info, Line_Ended_With_Lost_Keys{lost_keys = lost})
			}
			// The keys that waited, until one of them starts a line.
			for !running {
				waiting := line_editor.waiting_keys_take_first(&pending) or_break
				key(waiting)
			}
		}
		// A choice of the palette, when no line runs: after the keys that
		// waited, as one more key.
		palette_turn()
		edit_show()
		wait: system.Wait
		// While the keys stay in the terminal ring, a key that waits there
		// must not end the wait: the end of the line does, and the time of
		// the status, after which the console looks again at what Escape
		// can do.
		if line_editor.running_key_can_be_taken(running_line_read(), pending.count, PENDING_CAPACITY) {
			system.wait_records(&wait, &output.ring.completions)
		}
		// A choice of the palette is taken only when no line runs: while
		// one runs, a choice that waits in its ring must not end the wait
		// either, and the end of the line does.
		if palette_active() && !running {
			system.wait_records(&wait, &palette_ring.commands)
		}
		system.wait_word(&wait, &changes, seen)
		system.wait_end(&wait, running ? system.time() + STATUS_INTERVAL : system.WAIT_FOREVER)
	}
}

// running_line_read reads, once, the state of the line that the second
// thread runs: whether a line runs, whether it waits in a call that Escape
// can stop, and whether an Escape already asked that call to stop. The
// first thread takes the keys from the terminal ring by it
// (line_editor.running_key_can_be_taken): with no line running, and while
// a key has a place to wait, yes; with no place, only while an Escape can
// still stop the call of the line. After that Escape, and during a line
// with no such call, the keys stay in the terminal ring.
running_line_read :: proc "contextless" () -> line_editor.Running_Line {
	return {
		runs           = running,
		call_stoppable = running && intrinsics.atomic_load_explicit(&work.call_stoppable, .Acquire) != 0,
		stop_asked     = intrinsics.atomic_load_explicit(&work.cancel, .Acquire) != 0,
	}
}

// run_lines is the entry of the second thread: it runs each line that the
// first thread gives.
// A line comes first (line_editor.line_thread_work_choose): a refresh of
// the marks of the palette and the save of the line history wait until no
// line waits. Each is a call of another process, which a loaded host can
// make slow, and a line that the principal entered never waits for one.
run_lines :: proc "c" (parameter: rawptr) -> ! {
	done: u32
	for {
		seen := intrinsics.atomic_load_explicit(&work.wake, .Acquire)
		line_waits := intrinsics.atomic_load_explicit(&work.started, .Acquire) != done
		getters_asked := intrinsics.atomic_load_explicit(&work.refresh, .Acquire) != 0
		switch line_editor.line_thread_work_choose(line_waits, getters_asked, history_save_owed()) {
		case .Palette_Getters:
			intrinsics.atomic_store(&work.refresh, 0)
			palette_table_write(call_getters = true)
			continue
		case .History_Save:
			// The save holds no key: the first thread can enter a line
			// meanwhile, and that line runs after this one commit.
			history_save_owed_line()
			continue
		case .Wait:
			system.word_wait(&work.wake, seen)
			continue
		case .Run_Line:
		}
		done += 1
		services_check()
		run_line(string(work.text[:work.count]))
		// The palette: the answer to its choice, then the table of the
		// commands of now (palette_provider.odin).
		chosen_by_palette := palette_tag != 0
		palette_line_ended()
		palette_table_write()
		// The line ends when its result is drawn: the keys that waited
		// act now.
		intrinsics.atomic_store(&work.finished, done)
		change()
		// A choice of the palette can set a member of a row: its getters
		// say the new member in use, after the end of the line, so the
		// keys never wait for them, and before the save of the history, so
		// the mark does not wait for a commit of the storage service.
		if chosen_by_palette {
			intrinsics.atomic_store(&work.refresh, 1)
		}
	}
}

// second_thread_wake tells the second thread that the first thread gave it
// a line or a refresh.
second_thread_wake :: proc "contextless" () {
	intrinsics.atomic_add(&work.wake, 1)
	system.word_wake(&work.wake)
}

// palette_refresh_ask asks the second thread to call the getters of the
// rows of the palette, and returns at once.
palette_refresh_ask :: proc "contextless" () {
	intrinsics.atomic_store(&work.refresh, 1)
	second_thread_wake()
}

// change tells the first thread that the second thread changed something.
change :: proc "contextless" () {
	intrinsics.atomic_add(&changes, 1)
	system.word_wake(&changes)
}

// key acts on one key while no line runs. The completion list takes the
// key first when it is open; else Enter runs the line, Tab completes, Up
// and Down walk the line history, and a printable key edits the line.
key :: proc "contextless" (pressed: Key) {
	// A key record with no key code is a character of a paste: the
	// terminal types a paste so (src/md/features/clipboard.md). A key of
	// the keyboard always has a code.
	if pressed.code == 0 && line_editor.printable(pressed.character) {
		pasted_characters += 1
	}
	if completion_key(pressed) {
		return
	}
	switch {
	case pressed.code == display.KEY_ENTER:
		line_enter()
	case pressed.code == display.KEY_TAB:
		completion_tab()
	case pressed.code == display.KEY_UP:
		history_walk(1)
	case pressed.code == display.KEY_DOWN:
		history_walk(-1)
	case pressed.modifiers & display.MODIFIER_CONTROL != 0:
		// Control with a key that no list takes: the character is not typed.
	case:
		edit_key := edit_key_of(pressed)
		if line_editor.line_key(&line, edit_key, pressed.character) {
			key_serial_in_line = max(key_serial_in_line, pressed.serial)
			completion_after_edit(edit_key)
		}
	}
}

// line_enter makes the line a line of the terminal, and gives it to the
// second thread.
line_enter :: proc "contextless" () {
	text := line_editor.line_text(&line)
	system.lock(&output_lock)
	echo_write(text)
	system.unlock(&output_lock)
	if len(text) > 0 {
		system.lock(&history_lock)
		if line_editor.history_add(&history, text) {
			// The frecency counts the lines that the history holds, so
			// that a load builds the same table from the kept lines.
			line_editor.frecency_note_line(&completion_frecency, text)
		}
		system.unlock(&history_lock)
		system.log_fact(.Info, Line_Entered{}, text)
		work.count = copy(work.text[:], text)
		work.since = system.time()
		intrinsics.atomic_store(&work.cancel, 0)
		running = true
		intrinsics.atomic_add(&work.started, 1)
		second_thread_wake()
	}
	history_place = 0
	line_editor.line_clear(&line)
	completion_close()
}

// history_walk shows an older line (step 1) or a newer one (step -1). The
// line that the input typed comes back after the newest line.
history_walk :: proc "contextless" (step: int) {
	place := history_place + step
	if place < 0 {
		return
	}
	if place == 0 {
		line = draft
		history_place = 0
		return
	}
	text, ok := line_editor.history_line(&history, place - 1)
	if !ok {
		return
	}
	if history_place == 0 {
		draft = line
	}
	history_place = place
	line_editor.line_set(&line, text)
}

// edit_show gives to the terminal the line that it shows after the last
// line: the edit line with a cursor; or, while a line runs, its
// time and the keys that wait. The terminal gets a record only when the
// text changes.
shown: [terminal.RUN_LIMIT]u8
shown_count := -1
shown_cursor: u64
// The characters of a paste that the line took since edit_show last gave
// the line to the terminal, and whether a line with a paste was shown and
// is not empty again: a machine test waits for the two lines of the log
// before it takes a picture of the line.
pasted_characters: u64
paste_shown: bool
// The serial of the newest key that changed the edit line
// (terminal.Key.serial), first thread only: it takes the keys and calls
// edit_show. Each Edit record names it, and the terminal names
// it with the picture that shows the line, for the measure of a key to the
// screen (src/md/features/desktop_to_browser.md, "The three measures on the path of the system").
key_serial_in_line: u64

edit_show :: proc "contextless" () {
	buffer: [terminal.RUN_LIMIT]u8
	writer := system.Writer {
		buffer = buffer[:],
	}
	cursor := terminal.NO_CURSOR
	style: terminal.Style
	if running {
		elapsed := system.time() - work.since
		system.write_part(&writer, "runs ")
		system.write_part(&writer, elapsed / 1000)
		system.write_part(&writer, ".")
		system.write_part(&writer, elapsed / 100 % 10)
		system.write_part(&writer, " s. Escape stops a call or a record stream. Keys that wait: ")
		for waiting in pending.keys[:pending.count] {
			shown_key: rune = '^' // A key with no character: an arrow key, Control with a key.
			switch {
			case waiting.code == display.KEY_ENTER:
				shown_key = '|'
			case waiting.code == display.KEY_BACKSPACE:
				shown_key = '<'
			case waiting.code == display.KEY_TAB:
				shown_key = '>'
			case waiting.modifiers & display.MODIFIER_CONTROL == 0 && line_editor.printable(waiting.character):
				shown_key = waiting.character
			}
			character: [text_encoding.CHARACTER_BYTES_LIMIT]u8
			length := text_encoding.character_encode(shown_key, character[:])
			system.write_part(&writer, string(character[:length]))
		}
		style.tone = u8(terminal.Tone.Warning)
	} else {
		system.write_part(&writer, PROMPT)
		system.write_part(&writer, line_editor.line_text(&line))
		cursor = u64(len(PROMPT) + line.caret)
	}
	text := system.written(&writer)
	system.lock(&output_lock)
	defer system.unlock(&output_lock)
	if shown_count != len(text) || string(shown[:max(shown_count, 0)]) != text || cursor != shown_cursor {
		shown_count = copy(shown[:], text)
		shown_cursor = cursor
		// The edit line is code: its runs go first, and the Edit
		// that follows takes them. The time of a line that runs has none.
		if !running {
			runs: [terminal.CODE_RUN_LIMIT]terminal.Code_Run
			run_count := edit_runs(text, int(cursor), runs[:])
			terminal.code_runs_send(&output, .Edit, 0, runs[:run_count])
		}
		terminal.edit(&output, text, cursor, style, key_serial_in_line)
		// The terminal has the line now: its next picture shows it.
		if !running && pasted_characters > 0 {
			pasted_characters = 0
			paste_shown = true
			system.log_fact(.Info, Line_After_Paste{}, line_editor.line_text(&line))
		} else if !running && paste_shown && len(line_editor.line_text(&line)) == 0 {
			paste_shown = false
			system.log_fact(.Info, Line_Empty_After_Paste{})
		}
	}
	completion_show()
}

// The columns of the window of the console: the root service gives its
// terminal 96 columns (src/modules/system/root, start_grant_set_terminal). The terminal draws no
// byte past its last column, so the console starts a new row there: a long
// value goes on under its own start, and no byte of it is lost.
WINDOW_COLUMNS :: 96

output_column: int // The column after the last byte of the row that the console writes now.
output_continuation: int // The column where a line that is too long goes on.
output_logged := true // The lines also go to the log of the kernel.

// emit writes one part of an output line: on the terminal with its style,
// and in the line of the log of the kernel. A line longer than the window
// goes on in the next row, at output_continuation; the log has the line
// whole. The caller holds output_lock.
emit :: proc "contextless" (text: string, style: terminal.Style) {
	if output_logged {
		// The log: a line longer than one Log call goes in parts.
		logged := text
		for len(logged) > 0 {
			taken := copy(log_line[log_count:], logged)
			log_count += taken
			logged = logged[taken:]
			if log_count == len(log_line) {
				// A line of the log ends after a whole character; the bytes
				// of a cut character start the next line.
				whole := text_encoding.complete_characters(log_line[:log_count])
				if whole == 0 {
					whole = log_count
				}
				system.log_text(string(log_line[:whole]))
				log_count = copy(log_line[:], log_line[whole:log_count])
			}
		}
	}
	rest := transmute([]u8)text
	for len(rest) > 0 {
		if output_column >= WINDOW_COLUMNS {
			terminal.write(&output, terminal.Run{"", {flags = {.End_Line}}})
			blank := "                                                "
			output_column = clamp(output_continuation, 0, len(blank))
			if output_column > 0 {
				terminal.write(&output, terminal.Run{blank[:output_column], {}})
			}
		}
		// The text is UTF-8, and the terminal shows a character in its
		// cells (text_rendering.cell_width_of): two for a wide character,
		// none for a combining mark. The part ends after a whole character,
		// and a wide character that finds one column left starts the next
		// row, as the terminal would cut it there.
		part_bytes, part_columns := text_rendering.cell_part(rest, WINDOW_COLUMNS - output_column)
		if part_bytes == 0 {
			// A wide character at the last column: the next row takes it.
			// A new row starts at most at the column of a blank of 48
			// spaces, so it has room for it.
			output_column = WINDOW_COLUMNS
			continue
		}
		terminal.write(&output, terminal.Run{string(rest[:part_bytes]), style})
		output_column += part_columns
		rest = rest[part_bytes:]
	}
}

// emit_end ends the output line: on the terminal, and on the log when the
// line has bytes. The caller holds output_lock.
emit_end :: proc "contextless" () {
	terminal.write(&output, terminal.Run{"", {flags = {.End_Line}}})
	output_column = 0
	if output_logged && log_count > 0 {
		system.log_text(string(log_line[:log_count]))
		log_count = 0
	}
}

// print writes a text of the console itself, as its first line: plain
// lines on the terminal and on the log. No command prints: the result of a
// line goes through the drawers (results.odin).
print :: proc "contextless" (text: string) {
	system.lock(&output_lock)
	defer system.unlock(&output_lock)
	rest := text
	for len(rest) > 0 {
		end := 0
		for end < len(rest) && rest[end] != '\n' {
			end += 1
		}
		emit(rest[:end], {})
		if end < len(rest) {
			emit_end()
		}
		rest = rest[min(end + 1, len(rest)):]
	}
}

// screen_clear makes the terminal forget its lines.
screen_clear :: proc "contextless" () {
	system.lock(&output_lock)
	terminal.clear(&output)
	output_column = 0
	system.unlock(&output_lock)
}
