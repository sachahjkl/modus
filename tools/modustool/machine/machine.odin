package machine

import "base:runtime"
import "modus:contract/font_outlines"
import "modus:contract/remote"
import "internal:compositor/bar"
import "internal:compositor/palette"
import "modus:text_rendering"
import "modus:contract/wide_grants"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import "modustool:foundation"
import "modustool:resources"
import "modustool:build"
import "modustool:checks"
import "modustool:fuzz"

// The machine test: the tool starts the machine under QEMU, and it acts as
// the input. It presses keys and moves the mouse through the QEMU monitor,
// it reads the log of the kernel, and it saves pictures of the screen.

SCREENSHOT_FOLDER :: foundation.BUILD_FOLDER + "/screenshots"
// The picture of the screen that QEMU writes for the tool, beside the log of
// its machine: two machines that run at the same time write two files.
SCREEN_DUMP_SUFFIX :: "_screen.ppm"
// The passphrases of the test, which several parts type. They are constants
// of the tool: a test passphrase guards nothing.
PRINCIPAL_PASSPHRASE :: "correct horse battery"
MACHINE_PASSPHRASE :: "a machine of the test"
// The wave file of the sound device, beside the log of its machine.
SOUND_OUTPUT_SUFFIX :: "_sound.wav"
// The boot line of kernel_without_return_check: the same text as
// TEST_BUILD_LINE_WITHOUT_RETURN_CHECK in src/modulus/return_to_process.odin.
// Every machine checks that it did not run that kernel by mistake.
TEST_KERNEL_WITHOUT_RETURN_CHECK_LINE :: "kernel: TEST BUILD: the check of the instruction address before a return to a process is skipped"
// The bound of a Wait for the line of a case that writes a count of its
// progress, which the process reads: the process bounds a stall of the
// count and the whole case (TEST_PROGRESS_OVERALL_BOUND_MILLISECONDS in
// src/library/modus/system, 600 s), and this bound is larger, so that the report of
// the process comes first.
PROGRESS_CASE_HANG_BOUND_SECONDS :: 660
// The bound of the first Wait of each machine: its boot ("compositor:
// surface console" and its like). The boot runs the firmware and the start
// of every service at once, the part of a machine test that a loaded host
// slows the most.
BOOT_HANG_BOUND :: 180 * time.Second
// The most pixels of one relative move of the virtual mouse, on each axis.
MOUSE_STEP :: 40

// A line of 100 keys, none with Shift, so that the terminal sends 100 key
// presses for it: 1000 less 24 times 1, which is 976.
KEYS_HELD_LINE :: "1000 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1"
#assert(len(KEYS_HELD_LINE) == 100)

// The places of the scroll bar of the window of the console, inside its
// surface (src/modules/system/terminal/main.odin, layout; src/modules/system/root/main.odin,
// start_grant_set_terminal: 96 columns and 26 rows). The surface is 8 + 96 * 8 + 8 + 17
// = 801 pixels wide: a gap of 8 before the bar; the bar is its last 17
// pixels, from y = 0 to the line over the status at 8 + 26 * 16 + 8 - 4 =
// 428, with an arrow button of 17 pixels at each end. A press on a button
// of the bar names it (Click_Element); the shape of the pointer over it and
// a drag of the thumb take a place, which these constants give.
CONSOLE_SURFACE_WIDTH :: 8 + 96 * 8 + 8 + 17
CONSOLE_SCROLL_BAR_X :: CONSOLE_SURFACE_WIDTH - 9 // The middle column of the bar.
CONSOLE_SCROLL_BAR_ARROW_DOWN_Y :: 428 - 9 // The middle of the arrow button at the bottom.
CONSOLE_SCROLL_BAR_THUMB_END_Y :: 428 - 17 - 4 // In the last pixels of the track: the thumb of a view that follows the last lines ends there, and is 8 pixels long at least.
CONSOLE_SCROLL_BAR_TRACK_START_Y :: 17 + 4 // Near the start of the track: a thumb dragged there is at its first place.

// The line of remote when the last client of a client key leaves, after
// one call to one service: the slot of that connection is free, and no
// other slot is in use. The capacity is remote.SERVICE_CONNECTIONS.
REMOTE_ONE_SLOT_FREED :: "remote: ended 1 connections to services that no client uses (the last client of their key left, or no call for 60 s): their slots are free; 0 of 128 slots in use"
#assert(remote.SERVICE_CONNECTIONS == 128)

Step_Kind :: enum {
	Wait, // The log of the kernel has text, after the text of the last Wait.
	Date, // As Wait; then the number after text is a date of the machine in seconds since 1970, which date_check checks by order against the clock of the host.
	// As Wait, for the line of the appearance in force that the setting
	// auto gives (text: its start, "settings: the appearance in force is "):
	// date_check checks the date of the line, then the tool computes the
	// rule of the day over that date and its zone, and the line must name
	// the same appearance (machine_clock.odin). With `expected`, the zone of
	// the line in seconds must be that number.
	Appearance_Auto,
	// As Wait, for the line of the bar of the compositor (text: its start,
	// "compositor: the bar shows the local time "): date_check checks its
	// date of UTC, the text of the local time must be that date in the zone
	// of the line, and the zone must be `expected`, "+08:00"
	// (machine_clock.odin).
	Bar_Local_Time,
	// As Wait, for the line of the compositor at its start (text:
	// SCREEN_SIZE_LINE): the size on that line must be the reference
	// screen, else the step fails at once and names the size that the
	// firmware gave (machine_resize.odin, reference_screen_problem).
	Screen_Size,
	Type, // Press the keys of text, then Enter. When the console is in front, the tool then waits for the echo of the line on the log (console_echo.odin).
	Keys, // Press the keys of text, with no Enter.
	Key, // Press one key: text is its QEMU name.
	// Write the character text on the serial line of the machine again and
	// again until the log has `expected` after the last Wait, with the
	// bound of the first wait: a key that the firmware holds while the
	// machine starts, which no process confirms. The console input of the
	// firmware of a machine with no screen is the serial terminal, so the
	// machine needs the option serial_input; without it the step fails
	// with its line (src/md/features/start_policy.md, "The rescue key").
	Key_Until,
	// Press the key text of the keyboard again and again, one press each
	// KEY_AGAIN_PERIOD, until the log has `expected` after the last Wait,
	// with the hang bound. A dialog of the trusted display takes a key only
	// after its arm time, which no line of the log marks, so the step waits
	// for the line of the decision and never for a time
	// (src/md/features/assistant.md, "The act dialog").
	Key_Again_Until,
	Click, // Press the left button at (x, y).
	// Move the pointer with one report of the virtio tablet to (x, y), or,
	// with inside_window, from the corner of that window as the step Point
	// places it, and press the left button in the same report; then release
	// it there. The machine must have the tablet (Machine_Tablet). The tool
	// believes no place of the pointer after it: a step that moves the
	// pointer by relative moves cannot follow it.
	Click_Absolute,
	// As Click_Absolute, with no release: the button stays down.
	Press_Absolute,
	// Move the pointer by (x, y) logical pixels from the place of the last
	// report of the tablet, with the button down: a drag.
	Move_Absolute,
	// Release the button at the place of the last report of the tablet.
	Release_Absolute,
	Launch, // Open the start menu, and press the line of the process text.
	Drag, // Hold the left button from (x, y) to (to_x, to_y).
	Shot, // Save the screen as text.png.
	Move, // Drag the window with the title text to the place (to_x, to_y). The tool reads the place of the window in the log, before and after.
	// Drag the bottom left corner of the window with the title text until
	// its surface is to_x by to_y pixels. The tool reads the place and the
	// size of the window in the log, then waits for the line of the
	// compositor that the window took the new size (machine_resize.odin).
	Resize,
	Front, // Open the menu of the windows, and press the line of the last window with the title text: the window comes to the front. The tool reads the lines of the menu in the log.
	Close, // Press the close button of the window with the title text. The tool reads the place and the size of the window in the log, and brings the window to the front first when another window covers the button (machine_elements.odin).
	// Press the middle of the element with the name `element` of the window
	// with the title text, or of the palette when text is PALETTE_ELEMENTS.
	// The tool waits for the element line that places it, and brings the
	// window to the front first when another window covers the element
	// (machine_elements.odin).
	Click_Element,
	// Turn the wheel of the pointer by `notches` (NOTCH_TOWARD_THE_END for
	// each notch toward the end of a content; negative: toward its start)
	// over the middle of the element `element` of the window with the title
	// text, or of the palette when text is PALETTE_ELEMENTS. The window
	// comes to the front first: only the window in front gets the wheel
	// (machine_elements.odin). The next step waits for the line of the view
	// that moved.
	Wheel,
	// The four steps of a film (film.odin; docs/TOOLS.md, "The film"). Only
	// the scenario of a film has them: Film_Type and Film_Hold are the only
	// steps with a fixed time, because a film shows time.
	Film_Start, // Start the film with the name text: from now on a worker saves the screen FILM_RATE times in one second, while the next steps run.
	Film_Stop, // End the film that the last Film_Start started.
	Film_Type, // Press the keys of text one by one, with the period of a hand that types (film_key_periods), and no Enter.
	Film_Hold, // Do nothing for `milliseconds`: the time that a viewer needs to see the state of the screen. With a text, the hold starts the film cue of that name (film.odin).
	Quit, // End QEMU: the machine does not stop by itself.
	Monitor, // Send the line text to the QEMU monitor, as it is (for example "nmi": a non-maskable interrupt to each processor).
	Trace, // The log has text, after the text of the last Wait, then a stack trace to the end of the line: the tool takes the name that the system wrote in a frame, or names a frame "module + offset" from the debug object of its module, and the names start with `names`.
	Record, // A log record with the process `process`, the level `level` and a text that has `text`, after the record of the last Record step: the tool reads log.records() through the remote service (call.odin). With any_order, the next Record step searches from the same place. A later step names the number of the record that it found with {record} (RECORD_MARK) in its text.
	// The line of a log fact of the fact type `fact` ("log_reader.Fact_Probe"),
	// written by the process `process`, whose fields pass `condition`
	// ("value = 42", the form of a condition of `where`; "": any values),
	// after the text of the last Wait. The tool reads the fields of the
	// line, not its sentence, and checks the step against the fact tables
	// of the build before the machine starts (fact_steps.odin). With
	// any_order, the next Wait searches from the same place.
	Fact,
	Agree, // The process `text`: the mapped pages and the threads that inspect.mappings() and inspect.threads() give are the ones that monitor.processes() gives (two tools, two reports of the kernel).
	// The disk that the tool serves will lose its power at a write of a
	// root: after `commits` writes of a root and a seeded 1 to 40 more,
	// counted from this step, or with text, from the first write of a block
	// whose bytes start with text. The step comes before the work whose
	// commit the loss must cut, so the disk, not a line of the log, places
	// the cut (power_loss.odin).
	Power_Loss_Arm,
	Power_Loss, // Wait until the disk of the last Power_Loss_Arm loses its power: it answers nothing more, and the tool ends QEMU with no warning (power_loss.odin).
	Disk_Disconnect, // The disk that the tool serves closes its connection: QEMU fails each request that waits for an answer, so a machine whose disk went silent can end (silent_disk.odin).
	Call, // Call an export of a service from the host (call.odin), through the remote service: what the tool prints has `expected`. With `rows_call`, that call gives the count of rows of the Table. With `repeat`, the tool also measures the round trip and the calls in one second.
	// The ask of a wide grant of the peer through the remote service
	// (call.odin, wide_grant_ask_send): text the scopes, "view" or
	// "view_and_input", `milliseconds` the duration. With `expected`, the
	// number of the screen of the answer; with the outcome Refused, the
	// answer must be a refusal.
	Ask_Wide_Grant,
	Assistant_Turn, // One turn of the agent runner of the assistant (tools/modustool/agent_runner) through the remote service, with text as the one reply of its fake model: what the runner prints has `expected`.
	Peer, // The peer runs the TCP case text (peer_tcp.odin) and checks its answers.
	Point, // Move the pointer to (x, y) with no press, then read compositor.pointer(): its shape must be the name text (docs/POINTERS.md). With inside_window, (x, y) are from the corner of that window, its title bar included; a negative x is from its right side. It needs the confirmation of the pointer (a Call with pointer before it).
	Remember, // The rest of the line after the text, in the log after the last Wait, is kept for the step Distinct (a value that the machine drew).
	Distinct, // Each value that Remember kept in this test part differs from each other one; text names them.
	// As Wait; then the number after text is the base of the generations of
	// the storage service for the steps after it: a later step names
	// {generation} or {generation+N} in its text or its expected text. A
	// generation counts the commits of the whole disk, and the console
	// commits its line history after each line: a step counts from a base
	// near it, not from the format of the disk.
	Generation,
	Peer_Start, // The peer starts the TCP case text; the next steps run while it runs.
	Peer_Result, // The end of the case of the last Peer_Start: it must pass. text is its name.
	Peer_Mark, // The case of the last Peer_Start learns that the action that it waits for comes now, at the next step. text is its name.
	Fetch, // The TCP of the host fetches the page text of `server` through QEMU user networking (web_host.odin).
	Http, // The TCP of the host runs the HTTP case text against `server` (web_host.odin, http_case_run); `expected` is the body that a page must have.
	Quic_Key, // As Remember: the 64 hexadecimal digits after text, in the log after the last Wait, are the public key of a QUIC server, which the QUIC client of the peer pins (peer_quic.odin).
	Peer_Quic, // The peer runs the QUIC case text (peer_quic.odin) and checks its answers.
	Openssl_Quic, // `openssl s_client -quic` of the host sends the line text to quic_echo through the UDP relay of the peer, and must get it back, from the key that the step Quic_Key read (openssl_quic.odin, peer_relay.odin).
	Remote_Key, // As Quic_Key, for the QUIC client of `remote` in the peer (peer_remote.odin): each Call after it goes over QUIC with this key. The client proves its own key, which a step allows first: remote_allow("{client key}") in a console (CLIENT_KEY_MARK).
	Remote_Case, // The peer runs the case text of `remote` (peer_remote.odin, remote_case_run) and checks its outcome.
	Remote_Display_Key, // As Quic_Key, for the viewer of `remote_display` in the peer (peer_remote_display.odin). The viewer proves its own key, which a step allows first: remote_display_allow("{viewer key}", "view") in a console (VIEWER_KEY_MARK).
	// As Remote_Display_Key, for a viewer on the host that reaches
	// remote_display through the UDP relay of the peer: the tool prints the
	// port of the relay, the line of the key, and the command of the viewer
	// (remote_display_run.odin).
	Viewer_Relay,
	Remote_Display_Case, // The viewer of the peer runs the case text of `remote_display` (peer_remote_display.odin, remote_display_case_run) and checks its outcome.
	// Read the text of the element `element` of the window with the title
	// text off a picture of the screen, in Spleen 8x16 (screen_text.odin).
	// A later step of the part, in this machine or the next, names it with
	// {screen text} in its text.
	Screen_Text,
	// Run operation sequences through the mailbox of the process
	// operation_fuzzing, whose address the log gives after the text of the
	// last Wait, and check each oracle (operation_sequences.odin). text: ""
	// for the seed sequences, or the file of one sequence to replay.
	Operation_Sequences,
}

// The seed of the step Power_Loss_Arm and of the loss of power
// (power_loss.odin): the moment of the loss and the random subsets, one
// seed, printed.
POWER_LOSS_SEED :: 20261111
// The writes of a root after the count of a step Power_Loss_Arm, before the
// cut: 1 to this, from the seed.
POWER_LOSS_SEEDED_ROOTS :: 40

// The end of the fact of the display contract that a window writes when the
// holder of the display took it (modus:display, Window_Taken): the line is
// "display: " + the title + WINDOW_TAKEN. A scenario of another part than
// the display waits for it, never for a line of one holder, so a second
// holder of the display runs the scenario
// (src/md/features/roles_and_contracts.md, "Conformance"). The wait has
// any_order: the window can write its own lines before it reads the event.
WINDOW_TAKEN :: ": the holder of the display took the window"

Step :: struct {
	kind:       Step_Kind,
	text:       string,
	x, y:       int,
	to_x, to_y: int,
	// For Wait: the next Wait searches from the same place. Use it when two
	// processes print in an order that the system does not fix.
	any_order:  bool,
	// For Wait: the bound of a hang of this step in seconds, in place of
	// HANG_BOUND, for a step with a reason of its own that is not speed. It
	// is a named constant whose comment gives that reason: modustool check
	// refuses a number here.
	seconds:    int,
	fails_on:   string, // For Wait: a text that ends the wait as a failure when the machine prints it first, or on the line of the text: the step names its two outcomes. For Key_Again_Until: the other decision of the dialog, which fails the step and stops the presses.
	names:      string, // For Trace: the names of the functions of the first frames, separated by spaces.
	expected:   string, // For Call: a part of what the tool prints.
	outcome:    Call_Result_Kind, // For Call: Result, Failed or Refused. For Ask_Wide_Grant: Refused, or the default for an answer.
	rows_call:  string, // For Call: a call whose Integer result is the count of rows of the Table.
	lose:       int, // For Call: the peer drops this many datagrams of `remote` to the host; QUIC sends them again, and monitor.served() shows that the call ran one time.
	wrong_hash: bool, // For Call: the request names another hash of the module.
	process:    string, // For Record and Fact: the process that wrote the record.
	fact:       string, // For Fact: the fact type, "package.Type".
	condition:  string, // For Fact: a condition on one field of the fact type, "value = 42", or "".
	level:      string, // For Record: Info, Debug, Warning or Error, the member of Log_Level that the row of log.records gives.
	pointer:    bool, // For Call: when the call has its result, the tool confirms each place of the pointer from now on (pointer_confirm).
	repeat:     int, // For Call: the calls of the measure of the round trip.
	least_answer_bytes: int, // For Call: the least bytes of the answer on its stream.
	inside_window: string, // For Click and Drag: (x, y), and the end of a Drag, are inside the surface of the window with this title, as the log of the compositor places it. For Point: from the corner of the window.
	date_after: string, // For Call: the number after this text in what the tool prints is a date of the machine in milliseconds since 1970, which date_check checks by order against the clock of the host.
	milliseconds: int, // For Film_Hold: how long the state stays on the screen. For Ask_Wide_Grant: the duration of the grant.
	element:    string, // For Click_Element and Wheel: the element name ("watch", "frame 0", "round_robin").
	notches:    int, // For Wheel: the notches of the wheel, in NOTCH_TOWARD_THE_END.
	form:       string, // For Point: the pointer form that compositor.pointer() must also report, "dark" or "light" (docs/POINTERS.md).
	shown_only: bool, // For Screen_Text: the text must be read off the screen, and is not kept: the step proves that a window shows it, and a later step still types the texts kept before.
	commits:    int, // For Power_Loss_Arm: the writes of a root that the disk lets through before the seeded count.
}

// The two clocks agree to whole seconds: the machine reads its real-time
// clock in whole seconds, and a date can be rounded down on one side and up
// on the other. It is not a bound on a delay: date_check checks by order.
DATE_TOLERANCE_SECONDS :: 5

// date_check checks a date of the machine, in seconds since 1970, by order
// against the clock of the host: not before earliest, a date of the host
// before the machine wrote it, and not after the date of the host now. QEMU
// gives the machine a real-time clock that is the clock of the host moved by
// clock_offset_seconds (machine_clock.odin): the check takes the offset off
// first. The time between the two dates of the host is how late the tool
// read the date, which a loaded host stretches: it is no fault.
date_check :: proc(index: int, machine_seconds: i64, what: string, earliest: i64, clock_offset_seconds: i64) -> bool {
	host := time.time_to_unix(time.now())
	on_the_host := machine_seconds - clock_offset_seconds
	if on_the_host < earliest - DATE_TOLERANCE_SECONDS || on_the_host > host + DATE_TOLERANCE_SECONDS {
		fmt.eprintfln("modustool: test failed: step %d: the date of the machine (%s) is %d, %d on the clock of the host, not between %d and %d, the dates of the host before it was written and now", index + 1, what, machine_seconds, on_the_host, earliest, host)
		return false
	}
	foundation.test_passed_print("the date of the machine (%s) is %d s since 1970, %d on the clock of the host, between %d and %d", what, machine_seconds, on_the_host, earliest, host)
	return true
}

// The mark of a step text that the tool replaces with the number of the log
// record that the last Record step found. A scenario cannot know the number
// of a record before it runs: the count of the records before it depends on
// what each process wrote since the boot.
RECORD_MARK :: "{record}"

// generation_expand writes the base of the generations in a text: each
// {generation} is the base, and each {generation+N} the base and N. A mark
// with no end, or an N that is not a number, stays as it is: the step then
// waits for a text that the machine does not print, and fails.
generation_expand :: proc(text: string, base: i64) -> string {
	MARK :: "{generation"
	if !strings.contains(text, MARK) {
		return text
	}
	builder := strings.builder_make(context.temp_allocator)
	rest := text
	for {
		at := strings.index(rest, MARK)
		if at < 0 {
			strings.write_string(&builder, rest)
			break
		}
		strings.write_string(&builder, rest[:at])
		after := rest[at + len(MARK):]
		end := strings.index_byte(after, '}')
		offset: i64
		ok := end >= 0
		if ok && end > 0 {
			ok = after[0] == '+'
			if ok {
				offset, ok = strconv.parse_i64(after[1:end])
			}
		}
		if !ok {
			strings.write_string(&builder, MARK)
			rest = after
			continue
		}
		strings.write_i64(&builder, base + offset)
		rest = after[end + 1:]
	}
	return strings.to_string(builder)
}

// number_after reads the decimal number after a text in another text.
number_after :: proc(text: string, after: string) -> (value: i64, found: bool) {
	at := strings.index(text, after)
	if at < 0 {
		return 0, false
	}
	rest := text[at + len(after):]
	end := 0
	for end < len(rest) && (rest[end] >= '0' && rest[end] <= '9' || end == 0 && rest[end] == '-') {
		end += 1
	}
	return strconv.parse_i64(rest[:end])
}

self_test_file :: proc(pattern: string, number: int) -> string {
	// The machine test frees the temporary memory: this text stays.
	return fmt.aprintf(pattern, number)
}

// The measures of the locks of the kernel, with only the desktop.
@(rodata)
scenario_measure := [?]Step {
	{kind = .Wait, text = "boot program: ok"},
	{kind = .Wait, text = "kernel: ok"},
	// The quality profile that the compositor chose at its start
	// (quality_measure.odin).
	{kind = .Wait, text = checks.QUALITY_PROFILE_LINE, any_order = true},
	{kind = .Wait, text = "root: ok"},
	{kind = .Wait, text = "compositor: first frame", any_order = true},
	// The start measures of the compositor, after its first frame in a
	// measure run only (src/md/features/desktop_to_browser.md, "The three
	// measures on the path of the system").
	{kind = .Wait, text = "compositor: copy_bytes_without_overlap, ns for 8 64 512 4096 65536 3145600 bytes, aligned: ", any_order = true},
	{kind = .Wait, text = "compositor: fill_bytes_with_value, not aligned: ", any_order = true},
	{kind = .Wait, text = "compositor: the processor: ERMS ", any_order = true},
	{kind = .Wait, text = "compositor: the bar and the start menu, built and drawn (the least of 20): ", any_order = true},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Launch, text = "locks"},
	// The start of its window: locks draws its first frame before its
	// measures.
	{kind = .Wait, text = checks.QUALITY_WINDOW_START_LOCKS, any_order = true},
	{kind = .Wait, text = "locks: kernel entries in one second, each locker on its own objects: "},
	{kind = .Wait, text = "locks: pages on first use in one second, each locker in its own memory: "},
	{kind = .Wait, text = "locks: word wait, two threads wake each other: "},
	{kind = .Wait, text = "locks: frames: "},
	{kind = .Wait, text = "locks: frame caches after the measures (frames now, batches taken, batches given, drains): processor 0: "},
	{kind = .Wait, text = "locks: ok, the kernel counted each entry, each page returned, no wake was lost, each stopped process returned its pages, its slot and its threads"},
	{kind = .Shot, text = "locks_alone"},
	// One empty kernel entry with xmm, ymm and zmm in use: the cost of the
	// save of the extended state (docs/ARCHITECTURE.md, "The extended state
	// of the processor", section 4).
	{kind = .Launch, text = "extended_state"},
	{kind = .Wait, text = "extended_state: a part of a save and a restore, alone in this process: the loop "},
	{kind = .Wait, text = "extended_state: an instruction alone, the loop included: vzeroupper "},
	{kind = .Wait, text = "extended_state: a hand-over between two threads by the word wait (a wake, a wait, and the save and restore of the thread that waits and of the thread that runs): "},
	{kind = .Wait, text = "extended_state: an empty kernel entry, 100000 times: "},
	{kind = .Wait, text = "extended_state: ok, "},
	{kind = .Front, text = "console"},
	// One key of the completion list of the console, with no other load.
	{kind = .Type, text = "measure_completion()"},
	{kind = .Wait, text = " names (the names of this console, the least of 20 batches of 10)"},
	{kind = .Wait, text = " over 512 names (512 names of 128 bytes, the least of 20 batches of 10)"},
	// A frame at 1920 x 1080 on the processor, in its three parts, after
	// the other measures: no other process draws while it runs. The tool
	// reads the form of its lines after the machine
	// (processor_frame_measure.odin).
	{kind = .Type, text = "start(\"processor_frame\")"},
	// The 24 characters of that line are more than the keys of a line of
	// the time of a key to the screen: the compositor wrote one, with the
	// line of the frames, since the last wait (quality_measure.odin).
	{kind = .Wait, text = checks.QUALITY_FRAME, any_order = true},
	{kind = .Wait, text = checks.QUALITY_KEY, any_order = true},
	{kind = .Wait, text = checks.PROCESSOR_FRAME_CLEAR_AND_PRESENT, fails_on = checks.PROCESSOR_FRAME_WRONG},
	{kind = .Wait, text = checks.PROCESSOR_FRAME_FULL_FRAME, fails_on = checks.PROCESSOR_FRAME_WRONG},
	{kind = .Wait, text = checks.PROCESSOR_FRAME_FRAME_IN_ITS_DAMAGE, fails_on = checks.PROCESSOR_FRAME_WRONG},
	{kind = .Wait, text = checks.PROCESSOR_FRAME_DRAW_TABLE, fails_on = checks.PROCESSOR_FRAME_WRONG},
	{kind = .Wait, text = checks.PROCESSOR_FRAME_DONE, fails_on = checks.PROCESSOR_FRAME_WRONG},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

// The shortage of frames: a machine whose boot image has no desktop; the
// root service gives nearly all its pages to the process shortage, which
// takes all the frames, drains the stacks, frees all, and stops the machine
// (`modustool test shortage`, `modustool measure without_checks shortage`).
@(rodata)
scenario_shortage := [?]Step {
	{kind = .Wait, text = "boot program: ok"},
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "root: started shortage with "},
	{kind = .Wait, text = "shortage: full: "},
	{kind = .Wait, text = "shortage: ok, the stacks were drained for takes that cannot fail, a new object failed only when its budget could pay no page, and each frame returned"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

// The virtual memory of a process with only the desktop (`modustool
// measure address_space`).
@(rodata)
scenario_measure_address_space := [?]Step {
	{kind = .Wait, text = "boot program: ok"},
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "root: ok"},
	{kind = .Wait, text = "compositor: first frame", any_order = true},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Launch, text = "address_space"},
	{kind = .Wait, text = "address_space: arena: 1 GiB of addresses in one mapping, "},
	{kind = .Wait, text = "address_space: sparse table: 1024 pages committed of 262144, 1024 with a frame; decommit: 1024 pages back in the budget at once"},
	{kind = .Wait, text = "address_space: protection of 64 pages, one call with its shoot-down, the middle of 40 calls"},
	{kind = .Wait, text = "address_space: guard page: the child stopped with vector 14 at "},
	{kind = .Wait, text = "address_space: edge case: a map with a flag that the kernel does not know is refused: right", any_order = true},
	{kind = .Wait, text = "address_space: edge case: the end of the last thread stops the process with its own stop cause and no stop outcome: right", any_order = true},
	{kind = .Wait, text = "address_space: edge case: a process gets no Control over itself, and its stop through its own handle is refused: right", any_order = true},
	{kind = .Wait, text = "address_space: edge case: a holder's stop with an outcome and a stop of itself with no outcome are refused, and nothing stops: right", any_order = true},
	{kind = .Wait, text = "address_space: large pages: one random read over 64 MiB: "},
	// Each page table that a mapping made returns to the budget with its
	// unmap, at three levels, for a reservation, for a large page, and
	// while another thread uses a page of the same table.
	{kind = .Wait, text = "address_space: page tables: 64 mappings of one page, each at its own entry of three levels: 3 to 3 pages of tables while mapped, 0 pages kept after the unmap: as it must"},
	{kind = .Wait, text = "address_space: page tables: a reservation of 1024 pages: 4 pages of tables, the same after a commit and a decommit of 16 pages, 0 pages kept after the unmap: as it must"},
	{kind = .Wait, text = "address_space: page tables: a large page: 2 pages of tables above it while mapped, 0 pages kept after the unmap: as it must"},
	{kind = .Wait, text = "address_space: page tables: 1000 rounds of a map and an unmap beside a page that another thread writes and reads: 1000 rounds right, the page of the other thread stayed right, 0 pages kept: as it must"},
	{kind = .Wait, text = "address_space: ok, the arena and the sparse table paid only what they used, the decommit gave each page back, the protection changed with its shoot-down, the guard page stopped the child, the large pages are in the report, each refusal has its error record"},
	{kind = .Shot, text = "address_space"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

// The scheduling strategies with only the desktop (`modustool measure
// scheduler N`).
@(rodata)
scenario_measure_scheduler := [?]Step {
	{kind = .Wait, text = "boot program: ok"},
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "root: ok"},
	{kind = .Wait, text = "compositor: first frame", any_order = true},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Launch, text = "scheduler"},
	{kind = .Wait, text = "scheduler: EEVDF: two threads that wake each other, a spinner on each processor: "},
	{kind = .Wait, text = "scheduler: stress: 100 changes of strategy while "},
	{kind = .Wait, text = "scheduler: shares of the processes with 1, 2, 4 and 8 spinning threads under EEVDF, by the ticks of the kernel: without the share policy "},
	{kind = .Wait, text = "scheduler: one round of the share policy, over "},
	{kind = .Wait, text = "scheduler: EEVDF woke "},
	{kind = .Wait, text = "scheduler: the window took "},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

// The film of the terminal: the process flood writes lines, the scenario
// holds the view, moves in the lines, then stops the lines with a key and
// starts them again. The times between its keys are the times of a film,
// for a viewer (film.odin).
@(rodata)
scenario_film := [?]Step {
	{kind = .Wait, text = "compositor: surface console"},
	// flood is a test module: the start menu has no line of it.
	{kind = .Type, text = "start(\"flood\")"},
	{kind = .Wait, text = "terminal: ok, flood writes in a ring of 4096 records"},
	{kind = .Film_Start, text = "terminal"},
	{kind = .Film_Hold, milliseconds = 5000},
	{kind = .Key, text = "pgup"},
	{kind = .Film_Hold, milliseconds = 2500},
	{kind = .Key, text = "spc"},
	{kind = .Film_Hold, milliseconds = 2500},
	{kind = .Key, text = "pgup"},
	{kind = .Film_Hold, milliseconds = 500},
	{kind = .Key, text = "pgup"},
	{kind = .Film_Hold, milliseconds = 500},
	{kind = .Key, text = "pgup"},
	{kind = .Film_Hold, milliseconds = 1500},
	{kind = .Key, text = "spc"},
	{kind = .Film_Hold, milliseconds = 4000},
	{kind = .Film_Stop},
	{kind = .Shot, text = "film_end"},
	{kind = .Quit},
}

Machine :: struct {
	part:      ^Test_Part_Run, // What the machines of its part share: the remembered values, the screen texts, the times.
	host_process:   os.Process,
	monitor:   ^os.File,
	seen:      int, // The bytes of the log that the Wait steps used.
	failure_scanned: int, // The bytes of the log that common_failure_line read.
	output:    string, // The file of the log of the kernel.
	x, y:      int, // The pointer.
	pointer_known: bool, // The tool knows where the pointer is.
	film:        ^Film_Worker, // The worker of the film that runs, between the steps Film_Start and Film_Stop (film.odin); else nil.
	call_socket: string, // The socket where the peer receives the calls of the tool.
	peer:        ^Peer,
	confirm:     bool, // The tool reads compositor.pointer() before each press: see pointer_confirm.
	tablet_x, tablet_y: int, // The logical place of the last report of the tablet (machine_tablet.odin).
	keys_confirmed: int, // Keys whose records the compositor received before the tool went on (keys_send).
	key_batches_confirmed: int, // The sends of keys that ended with that count of the compositor.
	qmp:         Qmp, // The connection to the machine protocol of QEMU: the keys, the pointer, the pictures.
	log_watch:   Log_Watch, // The wait for a change of the log (log_watch_linux.odin).
	device_bytes: int, // The bytes that the tool sent to the virtual keyboard and mouse since the system had read them all.
	pointer_packets: int, // The packets of the virtual mouse that the tool sent.
	picture_jobs: [dynamic]^Picture_Job, // The pictures that worker threads turn into PNG files.
	picture_time: Picture_Time, // The times of the picture that the tool takes now: each picture of QEMU and each read of its file.
	pictures_settled_by_calls: int, // The pictures that the tool took when the processes and the compositor said that the screen was settled (screen_settle.odin).
	pictures_settled_by_pictures: int, // The pictures that the tool took when two pictures in a row were the same.
	confirmations: [dynamic]time.Duration, // The time of each confirmation of a place.
	corrected:   int, // The places that needed a correction.
	record_next: i64, // The number of the log record where the next Record step searches.
	record_found: i64, // The number of the first log record of the text that the last Record step found: a later step names it {record}.
	record_found_any: bool, // A Record step found a record: record_found holds its number.
	powered_off: bool, // A step Power_Loss ended QEMU: the machine has no exit status.
	// The steps of a step range (step_range.odin): the place of each step
	// that runs in its scenario, and the start of its boot steps, of its
	// setup steps and of its range, for the measures. nil: every step.
	range_places: []int,
	range_selection: Step_Selection,
	range_phase_started: [Step_Range_Phase]time.Tick,
	disk_server: ^Network_Block_Device, // The data disk, when the tool serves it.
	client:      Call_Client,
	serial_input: ^Serial_Input, // The input of the serial line, when the machine has one (Machine_Options.serial_input).
	client_open: bool,
	forward:     Forward, // QEMU user networking: the port of hostfwd and the listener of guestfwd.
	started_at:  time.Tick, // When QEMU started: the first Wait says how long the boot took.
	started_unix: i64, // When QEMU started, in seconds since 1970: no date that the machine prints is before it.
	clock_offset_seconds: i64, // The seconds that the real-time clock of the machine is ahead of the clock of the host (machine_clock.odin).
	times:       Machine_Step_Times, // The times of the step that runs (test_times.odin).
	wait_share:  Host_Share_Sample, // The counters of the host at the start of the step Wait that runs (host_share.odin).
	wait_started: time.Tick, // When that step began.
	echo:        Console_Echo, // The lines typed into the console whose echo the tool waits for (console_echo.odin).
	memory_file: string, // The file of the memory of the machine, or "" (Machine_Options).
	fact_catalog: ^build.Fact_Catalog, // The module files whose log facts log_read renders; nil until the log holds a fact.
	fact_outside_modules: []build.Fact_Catalog_Module, // The modules from outside the build that the catalog adds (Machine_Options).
	fact_rendered: [dynamic]u8, // The log with the sentence of each fact, up to fact_raw_length bytes of the file: each read renders only the lines after it.
	fact_raw_length: int, // The bytes of the file of the log that fact_rendered covers.
	fact_lines: [dynamic]build.Fact_Line_Place, // The place, the process and the fields of each rendered line of a fact of fact_rendered, in order: the step Fact reads them.
	fact_render_time: time.Duration, // The time of the renders: a measure.
	fact_render_lines: int, // The lines of facts that log_read rendered.
	fact_render_reads: int, // The reads of the log that rendered new lines.
	fact_catalog_time: time.Duration, // The time to make the catalog of the module files.
	fact_raw_bytes: int, // The bytes of the serial lines of the facts that log_read rendered, as the serial port got them: a measure.
	fact_sentence_bytes: int, // The bytes of the same lines with their sentences, the text of the line that each fact replaced: a measure.
}

monitor_send :: proc(machine: ^Machine, parts: ..string) {
	line := strings.concatenate({strings.concatenate(parts, context.temp_allocator), "\n"}, context.temp_allocator)
	_, _ = os.write_string(machine.monitor, line)
}

// key_name gives the QEMU name of the key, or keys, of a character.
key_name :: proc(character: u8) -> string {
	switch character {
	case 'a' ..= 'z', '0' ..= '9':
		return strings.clone_from_bytes({character}, context.temp_allocator)
	case 'A' ..= 'Z':
		return foundation.join("shift-", strings.clone_from_bytes({character + 32}, context.temp_allocator))
	case ' ':
		return "spc"
	case '(':
		return "shift-9"
	case ')':
		return "shift-0"
	case '"':
		return "shift-apostrophe"
	case '!':
		return "shift-1"
	case '%':
		return "shift-5"
	case '*':
		return "shift-8"
	case '+':
		return "shift-equal"
	case '=':
		return "equal"
	case '-':
		return "minus"
	case '_':
		return "shift-minus"
	case ',':
		return "comma"
	case '.':
		return "dot"
	case '/':
		return "slash"
	case ':':
		return "shift-semicolon"
	case ';':
		return "semicolon"
	case '[':
		return "bracket_left"
	case ']':
		return "bracket_right"
	case '{':
		return "shift-bracket_left"
	case '}':
		return "shift-bracket_right"
	case '^':
		return "shift-6"
	case '>':
		return "shift-dot"
	case '|':
		return "shift-backslash"
	case '<':
		return "shift-comma"
	case '?':
		return "shift-slash"
	case '@':
		return "shift-2"
	}
	return ""
}

// The text of a Click step that presses a button of the bar: the tool
// takes its middle from the layout of the bar (machine_bar_layout), not
// from a typed place, because the width of a button is the width of its
// name in the font that draws it.
BAR_START_BUTTON :: "the button start of the bar"
BAR_WINDOWS_BUTTON :: "the button windows of the bar"
BAR_FIRST_PLATE :: "the first window plate of the bar" // The plate of the windows that opened first: the console.

WINDOW_GRAB_X :: 100 // A point of the title bar of each window.
WINDOW_GRAB_Y :: 12
// The close button of a window, as the compositor draws it: its center, from
// the right side and from the top of the window.
WINDOW_BORDER :: 2
WINDOW_TITLE_HEIGHT :: 24 // The title bar of a window, above its surface.
WINDOW_CLOSE_RIGHT :: 14
WINDOW_CLOSE_Y :: 12

// The places of the scenarios that name an edge of the screen, from the
// reference screen that a test machine shows, in logical pixels at the
// scale of the desktop of the machine (scale_places.odin;
// src/md/features/desktop_to_browser.md, "The reference screen"). The
// other places of the scenarios are the places of their windows and of
// their elements, which the compositor and the windows give in logical
// pixels too.
//
// A point 6 logical pixels inside the lower right corner, which no window
// of a scenario covers: a press there falls on the background.
SCREEN_CORNER_X :: LOGICAL_SCREEN_WIDTH - 6
SCREEN_CORNER_Y :: LOGICAL_SCREEN_HEIGHT - 6
// A window at this height shows its title bar only, at the bottom of the
// screen: a scenario moves a window there to show the console under it.
WINDOW_TITLE_ONLY_Y :: LOGICAL_SCREEN_HEIGHT - WINDOW_TITLE_HEIGHT
#assert(WINDOW_TITLE_ONLY_Y + WINDOW_GRAB_Y < LOGICAL_SCREEN_HEIGHT)
// The left side of the palette, in the middle of the width of the screen,
// as palette.panel_place gives it; a host test compares the two
// (scenario_places_test.odin).
PALETTE_LEFT :: (LOGICAL_SCREEN_WIDTH - palette.PANEL_WIDTH) / 2
// A point of the palette 208 pixels from its left side: in its input band,
// its list and its footer, and on no text that changes the pointer.
PALETTE_POINT_X :: PALETTE_LEFT + 208

// window_width gives the width of the surface of the last window with a
// title: "compositor: surface title 480x320 at 276,232".
window_width :: proc(machine: ^Machine, title: string) -> (width: int, ok: bool) {
	if machine.confirm {
		_, _, outer_width := window_of_compositor(machine, title) or_return
		return outer_width - 2 * WINDOW_BORDER, true
	}
	text := log_read(machine)
	mark := strings.concatenate({"compositor: surface ", title, " "}, context.temp_allocator)
	made := strings.last_index(text, mark)
	if made < 0 {
		return 0, false
	}
	size := text[made + len(mark):]
	return strconv.parse_int(size[:max(strings.index_byte(size, 'x'), 0)])
}

// window_place gives the place of the last window with a title. The
// compositor writes it when it makes the window, and when the pointer puts the
// window down: "compositor: surface title 480x320 at 276,232" and
// "compositor: window title moved to 60,742".
window_place :: proc(machine: ^Machine, title: string) -> (x, y: int, ok: bool) {
	if machine.confirm {
		x, y, _ = window_of_compositor(machine, title) or_return
		return x, y, true
	}
	text := log_read(machine)
	made := strings.last_index(text, strings.concatenate({"compositor: surface ", title, " "}, context.temp_allocator))
	moved := strings.last_index(text, strings.concatenate({"compositor: window ", title, " moved to "}, context.temp_allocator))
	start := max(made, moved)
	if start < 0 {
		return 0, 0, false
	}
	line := text[start:]
	if end := strings.index_byte(line, '\n'); end >= 0 {
		line = line[:end]
	}
	mark := moved > made ? " moved to " : " at "
	at := strings.index(line, mark)
	if at < 0 {
		return 0, 0, false
	}
	place := strings.trim_space(line[at + len(mark):])
	comma := strings.index_byte(place, ',')
	if comma < 0 {
		return 0, 0, false
	}
	x = strconv.parse_int(place[:comma]) or_return
	y = strconv.parse_int(place[comma + 1:]) or_return
	return x, y, true
}

// window_of_compositor gives the place and the outer width of the window
// with a title, from compositor.windows(): the table of the compositor
// itself. The tool reads it once it has the grant `acts_for_principal` (a
// step Call with pointer); before that step, the places come from the log.
window_of_compositor :: proc(machine: ^Machine, title: string) -> (x, y, width: int, ok: bool) {
	table := table_call(&machine.client, "compositor.windows()") or_return
	for row in 0 ..< len(table.rows) / table.size {
		if table_value(&table, row, "title") != title {
			continue
		}
		x = strconv.parse_int(table_value(&table, row, "x")) or_return
		y = strconv.parse_int(table_value(&table, row, "y")) or_return
		width = strconv.parse_int(table_value(&table, row, "width")) or_return
		return x, y, width, true
	}
	return 0, 0, 0, false
}

// log_read gives the complete lines of the log of the machine. QEMU writes
// the log one byte at a time: the last line can be a part of a line, and a
// part of "at 168,142" reads as another place.
// The font outlines of the build, read once and opened in the state of the
// text rendering of the tool: the bytes of the resource font_outlines of
// the boot image, from which the compositor measures its bar. The machines
// of several parts read it at once: the lock holds its first read.
machine_outlines_words: []u64
machine_outlines_lock: sync.Mutex

// machine_bar_layout gives the places of the bar of the compositor of the
// machine. The last line of the log that names the font of the bar says
// which font it is; in the interface font, the tool measures the layout
// from the font outlines of the build, and confirms it against the numbers
// that the compositor wrote: a press must land on the entry that the eye
// sees. ok is false, with a line, when the two measures differ or the log
// has no such line yet.
machine_bar_layout :: proc(machine: ^Machine) -> (layout: bar.Layout, ok: bool) {
	INTERFACE_LINE :: "compositor: the bar is in the interface font: "
	CELLS_LINE :: "compositor: the bar is in the font of the cells"
	text := log_read(machine)
	interface_at := strings.last_index(text, INTERFACE_LINE)
	cells_at := strings.last_index(text, CELLS_LINE)
	if interface_at < 0 && cells_at < 0 {
		fmt.eprintln("modustool: test failed: the log does not say in which font the compositor draws its bar")
		return {}, false
	}
	if interface_at < cells_at {
		return bar.layout_of(.None), true
	}
	sync.mutex_lock(&machine_outlines_lock)
	defer sync.mutex_unlock(&machine_outlines_lock)
	if machine_outlines_words == nil {
		bytes, read_error := os.read_entire_file(resources.FONT_OUTLINES_OUTPUT, context.allocator)
		if read_error != nil {
			fmt.eprintfln("modustool: test failed: cannot read %s: %v", resources.FONT_OUTLINES_OUTPUT, read_error)
			return {}, false
		}
		// validate needs memory aligned on 8 bytes; the open fonts read it
		// for the rest of the run.
		machine_outlines_words = make([]u64, (len(bytes) + 7) / 8)
		aligned := ([^]u8)(raw_data(machine_outlines_words))[:len(bytes)]
		copy(aligned, bytes)
		delete(bytes)
		room := new(font_outlines.Record_Room, context.temp_allocator)
		outlines, refused := font_outlines.validate(aligned, room[:])
		if refused.kind != .None {
			fmt.eprintfln("modustool: test failed: %s is refused: %s", resources.FONT_OUTLINES_OUTPUT, font_outlines.problem_sentences[refused.kind])
			delete(machine_outlines_words)
			machine_outlines_words = nil
			return {}, false
		}
		if missing := text_rendering.open(&outlines); .B612 in missing {
			fmt.eprintfln("modustool: test failed: %s has no B612 that the text rendering opens", resources.FONT_OUTLINES_OUTPUT)
			return {}, false
		}
	}
	layout = bar.layout_of(.Interface)
	expected := fmt.tprintf("%sthe widest name %d pixels", INTERFACE_LINE, layout.longest_name_width)
	if !strings.has_prefix(text[interface_at:], expected) {
		end := strings.index_byte(text[interface_at:], '\n')
		fmt.eprintfln("modustool: test failed: the tool measures the bar as \"%s\", the compositor wrote \"%s\"", expected, text[interface_at:][:end < 0 ? len(text) - interface_at : end])
		return {}, false
	}
	return layout, true
}

log_read :: proc(machine: ^Machine) -> string {
	log, err := os.read_entire_file(machine.output, context.temp_allocator)
	if err != nil {
		return ""
	}
	text := string(log[:strings.last_index_byte(string(log), '\n') + 1])
	// The line of a log fact is bytes: each step reads its sentence, which
	// the tool writes from the module files of the build
	// (src/md/features/log_facts.md, "The serial port"). A log with no fact
	// is read as it is. The file only grows: the machine keeps the rendered
	// log of the bytes that it read, and each read renders only the whole
	// lines after them, so a read costs the copy of the log and no more.
	if machine.fact_catalog == nil && !strings.contains(text, build.FACT_LINE_MARK) {
		test_times_first_line_note(machine, len(text))
		return text
	}
	machine_fact_catalog_ensure(machine)
	if len(text) < machine.fact_raw_length {
		// A new file of the same name: nothing kept holds for it. The two
		// counts of the serial bytes start again with the lines, so the
		// measure counts the lines of one file.
		clear(&machine.fact_rendered)
		fact_lines_forget(machine)
		machine.fact_raw_length = 0
		machine.fact_raw_bytes, machine.fact_sentence_bytes = 0, 0
	}
	if len(text) > machine.fact_raw_length {
		render_started := time.tick_now()
		rendered_before := len(machine.fact_rendered)
		places_before := len(machine.fact_lines)
		chunk, fact_lines := build.fact_lines_render(machine.fact_catalog, text[machine.fact_raw_length:], &machine.fact_lines)
		// The render places a line from the start of the text that it was
		// given: the kept log holds the lines before it.
		for place_index in places_before ..< len(machine.fact_lines) {
			machine.fact_lines[place_index].start += rendered_before
			machine.fact_lines[place_index].end += rendered_before
			machine.fact_raw_bytes += machine.fact_lines[place_index].raw_count
			machine.fact_sentence_bytes += machine.fact_lines[place_index].end - machine.fact_lines[place_index].start
		}
		append(&machine.fact_rendered, chunk)
		machine.fact_raw_length = len(text)
		machine.fact_render_time += time.tick_since(render_started)
		machine.fact_render_lines += fact_lines
		machine.fact_render_reads += 1
	}
	// A copy in the memory of the step: a reader keeps its text while a
	// later read grows the kept one.
	text = strings.clone(string(machine.fact_rendered[:]), context.temp_allocator)
	test_times_first_line_note(machine, len(text))
	return text
}

// machine_fact_catalog_ensure makes the catalog of the machine and the
// memory of its rendered log, one time: the first read of the log that
// holds a fact, or the first step Record that reads a fact.
machine_fact_catalog_ensure :: proc(machine: ^Machine) {
	if machine.fact_catalog != nil {
		return
	}
	catalog_started := time.tick_now()
	machine.fact_catalog = machine_fact_catalog(machine.fact_outside_modules)
	machine.fact_catalog_time = time.tick_since(catalog_started)
	machine.fact_rendered = make([dynamic]u8, runtime.heap_allocator())
	machine.fact_lines = make([dynamic]build.Fact_Line_Place, runtime.heap_allocator())
}

// machine_fact_catalog gives the catalog of the module files of the build
// and of the modules from outside the build that the machine runs, in
// memory that lives as long as the machine: the temporary memory of a step
// is freed after it.
machine_fact_catalog :: proc(outside_modules: []build.Fact_Catalog_Module) -> ^build.Fact_Catalog {
	catalog := new(build.Fact_Catalog, runtime.heap_allocator())
	read, problem := build.fact_catalog_of_build(runtime.heap_allocator())
	if problem != "" {
		fmt.eprintfln("modustool: the lines of the log facts stay raw: %s", problem)
	} else if outside_problem := build.fact_catalog_add_modules(&read, outside_modules); outside_problem != "" {
		fmt.eprintfln("modustool: the lines of the log facts of the modules from outside the build stay raw: %s", outside_problem)
	}
	catalog^ = read
	return catalog
}

// windows_line gives the line of the last window with a title in the menu
// of the windows. The compositor writes one fact for each window when the
// menu opens, in the order of the menu: "compositor: windows: console, the
// window 1 of 3". from: the bytes of the log before the menu opened. The
// list is whole at the line whose place is the count of the windows.
windows_line :: proc(machine: ^Machine, title: string, from: int) -> (line: int, ok: bool) {
	MARK :: "compositor: windows: "
	PLACE :: ", the window "
	for start := time.now(); time.since(start) < foundation.HANG_BOUND; {
		text := log_read(machine)
		rest := len(text) > from ? text[from:] : ""
		found := false
		place_of_title := 0
		for {
			at := strings.index(rest, MARK)
			if at < 0 {
				break
			}
			rest = rest[at + len(MARK):]
			end := strings.index_byte(rest, '\n')
			if end < 0 {
				break // The line is not whole yet.
			}
			entry := strings.trim_right(rest[:end], "\r")
			rest = rest[end:]
			cut := strings.last_index(entry, PLACE)
			if cut < 0 {
				continue
			}
			numbers := strings.split(entry[cut + len(PLACE):], " of ", context.temp_allocator)
			if len(numbers) != 2 {
				continue
			}
			place, place_ok := strconv.parse_int(numbers[0], 10)
			windows, windows_ok := strconv.parse_int(numbers[1], 10)
			if !place_ok || !windows_ok {
				continue
			}
			if entry[:cut] == title {
				found, place_of_title = true, place
			}
			if place == windows {
				return max(place_of_title - 1, 0), found
			}
		}
		log_change_wait(machine)
	}
	return 0, false
}

// The texts that fail every scenario at once, whatever step waits: in
// normal use the machine never prints them, and a step that waited for a
// line would only fail at the hang bound, with no cause. The kernel prints
// the first when the drain of the serial port lost records
// (src/md/features/log_side_channels.md).
@(rodata)
common_failure_texts := [?]string{"records of the log did not reach the serial port"}

// The start of a line that the kernel writes for itself: a line of a
// process starts with its name in brackets, so a process that quotes a
// text of common_failure_texts does not fail a scenario.
COMMON_FAILURE_LINE_START :: "kernel: "

// common_failure_line gives the first line of log that starts with
// COMMON_FAILURE_LINE_START and ends with a text of common_failure_texts,
// or "". It reads from `from`; a line can start up to a whole line before
// it, so a line that two reads of the log cut is found.
common_failure_line :: proc(log: string, from: int) -> string {
	start := clamp(from, 0, len(log))
	start = strings.last_index_byte(log[:start], '\n') + 1
	for text in common_failure_texts {
		place := start
		for {
			at := strings.index(log[place:], text)
			if at < 0 {
				break
			}
			at += place
			place = at + len(text)
			line_start := strings.last_index_byte(log[:at], '\n') + 1
			line := log[line_start:]
			if end := strings.index_byte(line, '\n'); end >= 0 {
				line = line[:end]
			}
			line = strings.trim_right(line, "\r")
			if strings.has_prefix(line, COMMON_FAILURE_LINE_START) && strings.has_suffix(line, text) {
				return line
			}
		}
	}
	return ""
}

// common_failure_check gives the line of common_failure_texts that the
// machine printed since the last check, and prints the failure, or "".
common_failure_check :: proc(machine: ^Machine, log: string) -> string {
	line := common_failure_line(log, machine.failure_scanned)
	machine.failure_scanned = len(log)
	if line != "" {
		fmt.eprintfln("modustool: test failed: the machine printed \"%s\", which fails every scenario", line)
	}
	return line
}

log_wait :: proc(machine: ^Machine, text: string, any_order := false, limit := foundation.HANG_BOUND) -> bool {
	wait_started := time.tick_now()
	defer test_times_wait_note(machine, wait_started)
	start := time.now()
	for time.since(start) < limit {
		log := log_read(machine)
		if common_failure_check(machine, log) != "" {
			return false
		}
		if len(log) > machine.seen {
			if index := strings.index(log[machine.seen:], text); index >= 0 {
				if !any_order {
					machine.seen += index + len(text)
				}
				return true
			}
		}
		log_change_wait(machine)
	}
	return false
}

// log_wait_or_failure waits until the log, after the last Wait, has text or
// failure. It gives the line of failure when failure came first or is on
// the line of text (wait_or_failure_decide), and text_found when text came
// on a line with no failure. It does not move the place of the log: the
// Wait that follows finds text there at once.
log_wait_or_failure :: proc(machine: ^Machine, text, failure: string, limit: time.Duration) -> (failure_line: string, text_found: bool) {
	wait_started := time.tick_now()
	defer test_times_wait_note(machine, wait_started)
	start := time.now()
	for time.since(start) < limit {
		log := log_read(machine)
		if line := common_failure_check(machine, log); line != "" {
			return line, false
		}
		if len(log) > machine.seen {
			outcome, line := wait_or_failure_decide(log[machine.seen:], text, failure, true)
			switch outcome {
			case .Waiting:
			case .Text_Found:
				return "", true
			case .Failure_Found:
				return line, false
			}
		}
		log_change_wait(machine)
	}
	// At the bound, a last line that never ended is read as it is.
	log := log_read(machine)
	if len(log) > machine.seen {
		outcome, line := wait_or_failure_decide(log[machine.seen:], text, failure, false)
		switch outcome {
		case .Waiting:
		case .Text_Found:
			return "", true
		case .Failure_Found:
			return line, false
		}
	}
	return "", false
}

// What a Wait with a failure text found in the log.
Wait_Outcome :: enum u8 {
	Waiting       = 0, // Neither text yet, or the line of the text has not ended.
	Text_Found    = 1, // The text, on a line that does not have the failure text.
	Failure_Found = 2, // The failure text first, or on the line of the text.
}

// wait_or_failure_decide reads the log after the last Wait for a Wait with
// a failure text. The failure text fails the step when it comes before the
// text, or when it is on the line where the text is: a process that writes
// a list on one line, as the palette does, writes the item that the step
// refuses on the line that it waits for. whole_lines: the line of the text
// counts only once it ended, since its rest can still come; false at the
// bound, where the last line is read as it is. failure_line is the line
// with the failure text.
wait_or_failure_decide :: proc(rest, text, failure: string, whole_lines: bool) -> (outcome: Wait_Outcome, failure_line: string) {
	line_of :: proc(rest: string, at: int) -> (line: string, ended: bool) {
		start := strings.last_index_byte(rest[:at], '\n') + 1
		end := strings.index_byte(rest[at:], '\n')
		if end < 0 {
			return strings.trim_right(rest[start:], "\r"), false
		}
		return strings.trim_right(rest[start:at + end], "\r"), true
	}
	text_at := strings.index(rest, text)
	failure_at := failure == "" ? -1 : strings.index(rest, failure)
	if failure_at >= 0 && (text_at < 0 || failure_at < text_at) {
		line, _ := line_of(rest, failure_at)
		return .Failure_Found, line[strings.index(line, failure):]
	}
	if text_at < 0 {
		return .Waiting, ""
	}
	line, ended := line_of(rest, text_at)
	if failure != "" && strings.contains(line, failure) {
		return .Failure_Found, line
	}
	if whole_lines && !ended {
		return .Waiting, ""
	}
	return .Text_Found, ""
}

// log_last_line gives the last line of the log of the machine that has a
// text, from that text, or "" when none has it.
log_last_line :: proc(machine: ^Machine, text: string) -> string {
	log := log_read(machine)
	at := strings.last_index(log, text)
	if at < 0 {
		return ""
	}
	rest := log[at:]
	end := strings.index_byte(rest, '\n')
	return strings.trim_right(end < 0 ? rest : rest[:end], "\r")
}

// stored_object_of gives an object of the contents of an image, or nil.
stored_object_of :: proc(contents: ^fuzz.Disk_Contents, store: string, name: string) -> ^fuzz.Stored_Object {
	for &item in contents.objects {
		if item.store == store && item.name == name {
			return &item
		}
	}
	return nil
}

// lines_once says if the log of a machine holds each text exactly once,
// and writes the count of each one that it holds another count of times.
// A line of a fact counts by its sentence.
lines_once :: proc(log_path: string, texts: []string) -> bool {
	log := log_file_rendered(log_path) or_return
	once := true
	for text in texts {
		if count := strings.count(log, text); count != 1 {
			fmt.eprintfln("modustool: test failed: the log %s holds \"%s\" %d times, and it must hold it once", log_path, text, count)
			once = false
		}
	}
	return once
}

// The starts of a QEMU with hostfwd that ends at its start, each with a new
// port: another socket of the host can take the port of hostfwd before QEMU
// binds it (Given_Loopback_Ports). A bound: a QEMU that ends at each try
// ends for another reason.
MACHINE_START_TRIES :: 3

// qmp_socket_wait waits until QEMU made the socket of its machine protocol,
// or ended (then the process is reaped). A QEMU that ends before it makes
// the socket fails its start at once, not at the bound of a hang.
qmp_socket_wait :: proc(host_process: os.Process, path: string) -> (made: bool, ended: bool) {
	for start := time.tick_now(); time.tick_since(start) < foundation.HANG_BOUND; {
		if os.exists(path) {
			return true, false
		}
		if state, wait_error := os.process_wait(host_process, 0); wait_error == nil && state.exited {
			return false, true
		}
		time.sleep(CONDITION_POLL_PERIOD)
	}
	return false, false
}

// The machine of one machine test. The zero value of each field but the
// first three is the usual machine.
Machine_Options :: struct {
	volume:         string, // The path of its boot volume.
	output:         string, // The file of its log: it names the machine, and its other files are beside it (machine_file).
	exit_status:    int, // The status of QEMU at the end: MACHINE_STOP_OK when the kernel stops the machine, 0 when the tool ends QEMU.
	data_disk:      string, // "": the data disk of its part.
	user_network:   bool, // QEMU user networking in place of the peer: the listener of the tool also serves served_files (web_host.odin).
	served_files:   []Listener_File,
	// The module files from outside the build that the machine runs, whose
	// log facts the tool renders beside those of the build
	// (disk_processes.odin). Their bytes live as long as the machine.
	fact_outside_modules: []build.Fact_Catalog_Module,
	disk_server:    ^Network_Block_Device, // The data disk that the tool serves, when the tool serves it (power_loss.odin).
	processor:      Processor_Model,
	firmware:       Machine_Firmware,
	iommu:          Machine_Iommu,
	vnc:            bool, // A display for a film (film.odin).
	paused:         bool, // The machine waits for the step Monitor "cont".
	entropy_device: bool,
	// The sound device, whose output goes to the wave file beside the log
	// (SOUND_OUTPUT_SUFFIX): the check of the tone reads it after the machine.
	sound_device:   bool,
	tpm_device:     bool, // A software TPM, on any firmware.
	tpm_state:      string, // The state of the TPM that the machines of a part share, or "" for a new one.
	// The memory of the machine in this file, and one processor: the
	// machine of the operation sequences (operation_sequences.odin). "": none.
	memory_file:    string,
	// The parts that the machine lacks (missing_devices_scenario.odin): no
	// display device, no PS/2 controller, an entropy device whose source
	// never answers.
	without_screen:         bool,
	without_ps2_controller: bool,
	entropy_device_silent:  bool,
	no_network_device: bool, // The machine has no network device (network_scenario.odin).
	gpu_scanout: bool, // The display device is the VirtIO-GPU with its VGA part, as on the machine of a person (gpu_scanout_scenario.odin).
	data_disk_without_ioevent: bool, // The data disk has no ioevent file (machine_command).
	without_pit:    bool, // No 8254: `-machine q35,pit=off` (src/md/features/missing_hardware.md).
	// The variable store of the firmware that the machines of a part share,
	// so a boot entry that one machine writes is there at the next start
	// (start_policy_scenario.odin). "": a new copy for this machine.
	firmware_variables: string,
	// The serial line has an input: a FIFO beside the log, which the step
	// Key_Until writes (serial_input_linux.odin). On a machine with no
	// screen, the console input of the firmware is the serial terminal.
	serial_input: bool,
	// The UDP port of the machine that the UDP relay of the peer reaches
	// (peer_relay.odin). 0: the port of quic_echo, QUIC_SERVER_PORT.
	relay_machine_port: u16,
	tablet: Machine_Tablet, // The virtio tablet of the machine (tablet_scenario.odin).
}

// machine_test runs a scenario on a machine of a part. It passes when each
// step passes and QEMU ends with the status of its options.
machine_test :: proc(part: ^Test_Part_Run, steps: []Step, options: Machine_Options) -> bool {
	volume, output, exit_status := options.volume, options.output, options.exit_status
	data_disk := options.data_disk != "" ? options.data_disk : part.data_disk
	firmware, tpm_device := options.firmware, options.tpm_device
	// A step range: the machines before the named one run whole, the named
	// one runs its selection, and no machine after it starts. A machine
	// after it gives a failure to the procedure of its part, so a chain of
	// machines and checks stops; the worker reads the outcome of the range.
	selected := steps
	selection: Step_Selection
	range_steps: []Step
	defer delete(range_steps)
	defer delete(selection.places)
	range_target := false
	if part.step_range.given {
		if part.step_range.ran {
			return false
		}
		name := machine_name_of_log(output)
		if part.step_range.machine == "" || part.step_range.machine == name {
			range_target = true
			part.step_range.ran = true
			problem: string
			selection, problem = step_range_select(steps, part.step_range)
			if problem == "" {
				problem = step_range_setup_problem(steps, selection)
			}
			if problem != "" {
				// The places are in the temporary memory: the defer that
				// frees the clone must not free them.
				selection = {}
				fmt.eprintfln("modustool: test failed: the step range of %s is refused before its machine starts: %s", name, problem)
				return false
			}
			// The heap: the first step of the scenario frees the temporary
			// memory, and the selection lives as long as the machine.
			range_steps = make([]Step, len(selection.places))
			for place, position in selection.places {
				range_steps[position] = steps[place]
			}
			selection.places = slice.clone(selection.places)
			selected = range_steps
			fmt.printfln("modustool: the machine %s runs %d boot steps, %d setup steps and the steps %d to %d of its %d steps", name, selection.boot, selection.setup, part.step_range.span.first, part.step_range.span.last, len(steps))
		}
	}
	// A scenario that cannot pass is refused before its machine starts,
	// with the cause of each fault, not at the end of a bound.
	if !scenario_check_before_start(selected, range_target ? selection.places : nil) {
		return false
	}
	machine_test_started := time.tick_now()
	// The software TPM runs before QEMU and ends after it, with a folder of
	// its own for each machine, and a state of its own unless the machines
	// of a part share one (tpm_start).
	tpm: Tpm_Host_Process
	if tpm_device && !tpm_start(&tpm, output, options.tpm_state) {
		return false
	}
	defer tpm_stop(&tpm)
	peer: Peer
	if !peer_start(&peer, relay_machine_port = options.relay_machine_port != 0 ? options.relay_machine_port : QUIC_SERVER_PORT) {
		return false
	}
	defer peer_stop(&peer)
	listener: Listener
	forward: Forward
	// The port of hostfwd goes back to the free ports after QEMU ended: the
	// defers run in the reverse order.
	defer loopback_port_take_back(&given_loopback_ports, forward.host_port)
	if options.user_network {
		port, free := free_port(&given_loopback_ports)
		if free {
			forward.host_port = port
		}
		if !free || !listener_start(&listener, options.served_files) {
			fmt.eprintln("modustool: no port of the loopback for the TCP of QEMU")
			return false
		}
		forward.listener = &listener
	}
	defer listener_stop(&listener)
	clock := machine_clock_of(time.time_to_unix(time.now()))
	// The disk of the measures holds no data that a process keeps, the last
	// picture of the screen is in its PNG file, and the copy of the variable
	// store is of this machine only: they would fill the build folder, one
	// of each for each machine.
	defer {
		_ = os.remove(machine_file(output, SCRATCH_DISK_SUFFIX))
		_ = os.remove(machine_file(output, SCREEN_DUMP_SUFFIX))
		for suffix in ([]string{FIRMWARE_VARIABLES_SUFFIX, FIRMWARE_TPM_VARIABLES_SUFFIX, FIRMWARE_FULL_VARIABLES_SUFFIX}) {
			_ = os.remove(machine_file(output, suffix))
		}
	}
	// The FIFO of the input of the serial line, and its writer, before QEMU
	// starts: QEMU then opens it to read with no wait.
	serial_input: Serial_Input
	serial_input_path := ""
	if options.serial_input {
		serial_input_path = machine_file(output, SERIAL_INPUT_SUFFIX)
		if !serial_input_open(&serial_input, serial_input_path) {
			return false
		}
	}
	defer serial_input_close(&serial_input)
	host_process: os.Process
	monitor_read, monitor_write: ^os.File
	qmp: Qmp
	qmp_opened := false
	for try := 1; ; try += 1 {
		command, ok := machine_command(volume, output, data_disk, &peer, forward, options.processor, firmware, options.vnc, options.paused, options.iommu, options.entropy_device, tpm_device, clock.argument, options.memory_file, options.sound_device ? machine_file(output, SOUND_OUTPUT_SUFFIX) : "", options.without_screen, options.without_ps2_controller, options.entropy_device_silent, options.no_network_device, options.data_disk_without_ioevent, options.without_pit, options.firmware_variables, serial_input_path, options.tablet, options.gpu_scanout)
		if !ok {
			return false
		}
		_ = os.remove(output)
		_ = os.remove(qmp_socket_of(output))
		_ = os.remove(film_qmp_socket_of(output))
		_ = os.remove(film_vnc_socket_of(output))
		pipe_err: os.Error
		monitor_read, monitor_write, pipe_err = os.pipe()
		if pipe_err != nil {
			fmt.eprintfln("modustool: cannot create a pipe: %v", pipe_err)
			return false
		}
		start_err: os.Error
		host_process, start_err = os.process_start({command = command, stdin = monitor_read, stderr = os.stderr})
		// QEMU has its copy of the socket of the peer now.
		peer_machine_socket_lent_close(&peer)
		if start_err != nil {
			fmt.eprintfln("modustool: cannot start %s: %v", command[0], start_err)
			os.close(monitor_write)
			os.close(monitor_read)
			return false
		}
		// The keys, the moves of the pointer and the pictures go through the
		// machine protocol of QEMU: QEMU listens when it started.
		socket_made, ended := qmp_socket_wait(host_process, qmp_socket_of(output))
		qmp_opened = socket_made && qmp_open(&qmp, qmp_socket_of(output))
		if qmp_opened || !options.user_network || try == MACHINE_START_TRIES {
			break
		}
		// QEMU closed the protocol before its greeting: it ends.
		if !ended && qmp.ended {
			state, wait_error := os.process_wait(host_process, foundation.HANG_BOUND)
			ended = wait_error == nil && state.exited
		}
		// A QEMU that runs and gave no greeting is a failure of the machine,
		// not of its port: it is not started again.
		if !ended {
			break
		}
		// QEMU ended at its start: the bind of the port of hostfwd is the
		// one step of its start that another socket of the host can make
		// fail (Given_Loopback_Ports).
		qmp_close(&qmp)
		qmp = {}
		os.close(monitor_write)
		os.close(monitor_read)
		loopback_port_take_back(&given_loopback_ports, forward.host_port)
		port, free := free_port(&given_loopback_ports)
		forward.host_port = free ? port : 0
		if !free {
			fmt.eprintln("modustool: no port of the loopback for the TCP of QEMU")
			return false
		}
		fmt.printfln("modustool: QEMU of %s ended at its start, which a port of hostfwd that another socket took gives: start %d of %d, with the port %d", output, try + 1, MACHINE_START_TRIES, port)
	}
	machine := Machine {
		qmp = qmp,
		part = part,
		started_at = time.tick_now(),
		started_unix = time.time_to_unix(time.now()),
		clock_offset_seconds = clock.offset_seconds,
		host_process   = host_process,
		monitor   = monitor_write,
		output    = output,
		call_socket = peer.call_socket,
		peer      = &peer,
		forward   = forward,
		disk_server = options.disk_server,
		memory_file = options.memory_file,
		serial_input = &serial_input,
		fact_outside_modules = options.fact_outside_modules,
	}
	if range_target {
		machine.range_places = selection.places
		machine.range_selection = selection
	}
	passed := qmp_opened && scenario_run(&machine, selected)
	scenario_ended := time.tick_now()
	if range_target && qmp_opened {
		step_range_times_print(&machine, scenario_ended, passed)
	}
	// First after a failure, before any other act: the processors of a
	// stall must not move on before the tool reads where they are.
	if qmp_opened && !passed {
		processors_report(&machine, output, volume, firmware)
	}
	// A scenario that failed between Film_Start and Film_Stop: its worker
	// ends before the connections to QEMU close.
	_ = film_stop(&machine)
	if !passed && (firmware != .Usual || tpm_device) {
		// While QEMU still runs: what the firmware shows and wrote.
		firmware_failure_report(&machine, output)
	}
	// Each picture has its PNG file before the test ends: a picture that
	// is not written fails the test.
	if !pictures_join(&machine) {
		passed = false
	}
	if machine.pictures_settled_by_calls + machine.pictures_settled_by_pictures > 0 {
		foundation.test_passed_print("the tool took %d pictures when the processes were in a wait and the compositor had drawn each picture that it received, and %d when two pictures in a row were the same", machine.pictures_settled_by_calls, machine.pictures_settled_by_pictures)
	}
	if len(machine.confirmations) > 0 {
		slice.sort(machine.confirmations[:])
		foundation.test_passed_print("the tool confirmed %d places of the pointer through compositor.pointer(), %d after a correction; one confirmation took %d us at least, %d us in the middle", len(machine.confirmations), machine.corrected, i64(machine.confirmations[0] / time.Microsecond), i64(machine.confirmations[len(machine.confirmations) / 2] / time.Microsecond))
	}
	if machine.keys_confirmed > 0 {
		foundation.test_passed_print("the tool sent %d keys in %d sends, and went on after each send only when the compositor had received each record of its keys", machine.keys_confirmed, machine.key_batches_confirmed)
	}
	if machine.client_open {
		call_client_close(&machine.client)
	}
	state: os.Process_State
	if range_target {
		// A range does not stop its machine as the whole scenario does:
		// the tool ends QEMU below, and checks no exit status.
	} else if passed && machine.powered_off {
		state, _ = os.process_wait(host_process, foundation.HANG_BOUND)
	} else if passed {
		wait_err: os.Error
		state, wait_err = os.process_wait(host_process, foundation.HANG_BOUND)
		if wait_err != nil || !state.exited {
			fmt.eprintln("modustool: test failed: the machine did not stop")
			passed = false
		} else if state.exit_code != exit_status {
			fmt.eprintfln("modustool: test failed: QEMU ended with status %d", state.exit_code)
			passed = false
		}
	}
	if !state.exited {
		_ = os.process_kill(host_process)
		_, _ = os.process_wait(host_process)
	}
	// The whole log once more after the end: a line lost after the last
	// wait, or during a step that waits for no line, fails the machine too.
	// The flush of machine_stop writes that line before the end.
	if line := common_failure_line(log_read(&machine), 0); line != "" {
		fmt.eprintfln("modustool: test failed: the machine printed \"%s\", which fails every scenario", line)
		passed = false
	}
	if machine.fact_catalog != nil {
		fmt.printfln("modustool: measure: the tool wrote the sentences of %d lines of log facts of %s in %d us, over %d reads of the log, each read rendering only its new lines; the catalog of %d module files took %d us", machine.fact_render_lines, output, i64(machine.fact_render_time / time.Microsecond), machine.fact_render_reads, len(machine.fact_catalog.modules), i64(machine.fact_catalog_time / time.Microsecond))
		// The serial bytes of the two forms of the same lines: a template
		// writes the sentence of the text line that the fact replaced, so
		// the rendered line is the line of the text form, byte for byte
		// (src/md/features/log_facts.md, "The measures that decide it").
		fmt.printfln("modustool: measure: the serial lines of %d log facts of %s took %d bytes as facts; the same lines as text take %d bytes", len(machine.fact_lines), output, machine.fact_raw_bytes, machine.fact_sentence_bytes)
		// The records of the start, the module files of the first writers
		// of facts and the lines by the bytes of their body, from the log
		// of the main machine only: the measure record keeps its lines.
		if output == checks.TEST_OUTPUT && !range_target && !build.log_measures_write(output) {
			passed = false
		}
		delete(machine.fact_rendered)
		fact_lines_forget(&machine)
		delete(machine.fact_lines)
	}
	os.close(monitor_write)
	os.close(monitor_read)
	qmp_close(&machine.qmp)
	_ = os.remove(film_vnc_socket_of(output))
	log_watch_close(&machine.log_watch)
	delete(machine.picture_jobs)
	peer_stop(&peer)
	if passed {
		passed = peer_check(&peer)
	}
	// The kernel with a check skipped runs only from its own boot volume:
	// another machine that prints its line ran a kernel of the test by
	// mistake, and its result is not a result of the kernel.
	if passed && volume != build.BOOT_VOLUME_WITHOUT_RETURN_CHECK {
		log, _ := os.read_entire_file(output, context.temp_allocator)
		if strings.contains(string(log), TEST_KERNEL_WITHOUT_RETURN_CHECK_LINE) {
			fmt.eprintfln("modustool: test failed: the machine of %s ran the kernel of the test with a check skipped: \"%s\"", volume, TEST_KERNEL_WITHOUT_RETURN_CHECK_LINE)
			passed = false
		}
	}
	// The counted kernel runs only from the volume of the fuzzing, which no
	// machine test boots: its counts and its stack are not those of the
	// kernel that ships.
	if passed && volume != build.BOOT_VOLUME_OPERATION_FUZZING {
		log, _ := os.read_entire_file(output, context.temp_allocator)
		if strings.contains(string(log), OPERATION_COUNTERS_LINE_START) {
			fmt.eprintfln("modustool: test failed: the machine of %s ran the counted kernel: \"%s\"", volume, OPERATION_COUNTERS_LINE_START)
			passed = false
		}
	}
	if !passed {
		// The whole log, its facts rendered: the check of the flake keeps
		// no file of a part that fails, but Nix keeps what the build
		// printed (`nix log`), and the cause of a failure is rarely in the
		// last lines. A log whose facts cannot be rendered prints raw.
		log, rendered := log_file_rendered(output)
		if !rendered {
			raw, _ := os.read_entire_file(output, context.temp_allocator)
			log = string(raw)
		}
		lines := strings.split_lines(log, context.temp_allocator)
		// One write: the lines of a machine of another part that runs at the
		// same time do not come between them.
		whole := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&whole, "modustool: the log of the kernel of %s, %d lines (nix log of the part keeps it whole):\n", output, len(lines))
		for line in lines {
			fmt.sbprintf(&whole, "    %s\n", line)
		}
		fmt.eprint(strings.to_string(whole))
	}
	test_times_machine_end(&machine, passed, machine_test_started, machine.started_at, scenario_ended)
	if range_target {
		// The part ends here: a failure stops the chain of its procedure,
		// and the worker reads the outcome of the range.
		part.step_range.passed = passed
		return false
	}
	return passed
}

// remote_starts_or_ends says if a step starts `remote` or closes it: the
// next start makes a new key, so the key of the log is read again.
remote_starts_or_ends :: proc(step: Step) -> bool {
	#partial switch step.kind {
	case .Launch, .Close:
		return step.text == "remote"
	case .Type:
		return strings.contains(step.text, "start(\"remote\")")
	case .Power_Loss:
		return true
	}
	return false
}

// remote_key_problem names the first step that calls `remote` with no step
// Remote_Key since the last start of `remote`, or gives "". The key of
// `remote` belongs to one start: a call with the key of an earlier start,
// or of another machine, is refused by the pin, so a scenario that could
// make one does not run.
remote_key_problem :: proc(steps: []Step) -> string {
	key_read := false
	for step, index in steps {
		if remote_starts_or_ends(step) {
			key_read = false
			continue
		}
		if step.kind == .Remote_Key {
			key_read = true
		} else if step_calls_remote(step.kind) && !key_read {
			return fmt.tprintf("step %d (%v %s) calls remote with no step Remote_Key since the last start of remote", index + 1, step.kind, step.text)
		}
	}
	return ""
}

scenario_run :: proc(machine: ^Machine, steps: []Step) -> bool {
	peer_case_started := 0 // The number of the case of the last step Peer_Start.
	first_wait := true // The first Wait of the machine is its boot: BOOT_HANG_BOUND.
	generation_base: i64 = -1 // The number that the last step Generation read; -1: none.
	for given_step, position in steps {
		step := given_step
		// The number of the step in its scenario: a step range runs some of
		// its steps, and each line names a step by its number there.
		index := step_place(machine.range_places, position)
		if machine.range_places != nil {
			step_range_phase_note(machine, position)
		}
		// The time of the step, for a step that passes and for one that fails.
		step_started := time.tick_now()
		test_times_step_start(machine)
		defer test_times_step_end(machine, index, given_step, step_started)
		if position > 0 {
			console_echo_note_step(&machine.echo, steps[position - 1]) // The step before passed.
		}
		if position > 0 && remote_starts_or_ends(steps[position - 1]) && machine.peer != nil && machine.peer.remote != nil {
			// The step before started or closed `remote`: its key of the
			// start before is forgotten, and the tool no longer reads the
			// pointer through it until a call with pointer again.
			peer_remote_unpin(machine.peer.remote)
			machine.confirm = false
		}
		if strings.contains(step.text, "{generation") || strings.contains(step.expected, "{generation") {
			if generation_base < 0 {
				fmt.eprintfln("modustool: test failed: step %d names {generation} before a step Generation", index + 1)
				return false
			}
			step.text = generation_expand(step.text, generation_base)
			step.expected = generation_expand(step.expected, generation_base)
		}
		if strings.contains(step.text, RECORD_MARK) {
			if !machine.record_found_any {
				fmt.eprintfln("modustool: test failed: step %d names %s before a step Record found a record", index + 1, RECORD_MARK)
				return false
			}
			step.text, _ = strings.replace_all(step.text, RECORD_MARK, fmt.tprintf("%d", machine.record_found), context.temp_allocator)
		}
		has_kept_mark := strings.contains(step.text, SCREEN_TEXT_MARK)
		has_before_mark := strings.contains(step.text, SCREEN_TEXT_BEFORE_MARK)
		if has_kept_mark && machine.part.screen_text_kept == "" {
			fmt.eprintfln("modustool: test failed: step %d names %s before a step Screen_Text", index + 1, SCREEN_TEXT_MARK)
			return false
		}
		if has_before_mark && machine.part.screen_text_before == "" {
			fmt.eprintfln("modustool: test failed: step %d names %s before two steps Screen_Text", index + 1, SCREEN_TEXT_BEFORE_MARK)
			return false
		}
		if has_kept_mark || has_before_mark {
			step.text = screen_text_expand(step.text, machine.part.screen_text_kept, machine.part.screen_text_before)
		}
		if strings.contains(step.text, CLIENT_KEY_MARK) {
			if machine.peer == nil || machine.peer.remote == nil {
				fmt.eprintfln("modustool: test failed: step %d names %s, and the machine has no peer with a client of remote", index + 1, CLIENT_KEY_MARK)
				return false
			}
			step.text = client_key_expand(machine.peer.remote, step.text)
		}
		if strings.contains(step.text, VIEWER_KEY_MARK) {
			if machine.peer == nil || machine.peer.display_viewers[0] == nil {
				fmt.eprintfln("modustool: test failed: step %d names %s, and the machine has no peer with a viewer of remote_display", index + 1, VIEWER_KEY_MARK)
				return false
			}
			step.text = viewer_key_expand(machine.peer.display_viewers[0], step.text)
		}
		switch step.kind {
		case .Wait:
			limit := first_wait ? BOOT_HANG_BOUND : foundation.HANG_BOUND
			if step.seconds > 0 {
				limit = time.Duration(step.seconds) * time.Second
			}
			was_first_wait := first_wait
			first_wait = false
			// The counters of the host now: a wait that ends at its bound
			// then says what the host gave the machine meanwhile.
			machine.wait_share = host_share_sample(machine.host_process.pid)
			machine.wait_started = time.tick_now()
			if step.fails_on != "" {
				failure_line, text_found := log_wait_or_failure(machine, step.text, step.fails_on, limit)
				if failure_line != "" {
					fmt.eprintfln("modustool: test failed: step %d: the machine printed \"%s\" before \"%s\" or on its line", index + 1, failure_line, step.text)
					return false
				}
				if !text_found {
					fmt.eprintfln("modustool: test failed: step %d: the machine printed neither \"%s\" nor \"%s\" within %v; %s", index + 1, step.text, step.fails_on, limit, wait_share_sentence(machine))
					return false
				}
			}
			if !log_wait(machine, step.text, step.any_order, limit) {
				fmt.eprintfln("modustool: test failed: step %d: the machine did not print \"%s\" within %v; %s", index + 1, step.text, limit, wait_share_sentence(machine))
				return false
			}
			// A failed line of the console ends with the sentence of its
			// error record: a bare result after it tells a reader nothing
			// (docs/WRITING.md).
			if strings.has_prefix(step.text, CONSOLE_FAILURE_LINE_START) && !step.any_order {
				rest := log_read(machine)[machine.seen:]
				if end := strings.index_byte(rest, '\n'); end >= 0 {
					rest = rest[:end]
				}
				if ends_with_a_bare_number(rest) {
					fmt.eprintfln("modustool: test failed: step %d: the failed line \"%s\" ends with the bare number \"%s\"", index + 1, step.text, rest)
					return false
				}
			}
			if was_first_wait {
				foundation.test_passed_print("the machine printed \"%s\", %.1f s after the start of QEMU", step.text, time.duration_seconds(time.tick_since(machine.started_at)))
			} else {
				foundation.test_passed_print("the machine printed \"%s\"", step.text)
			}
		case .Date:
			seen_before := machine.seen
			if !log_wait(machine, step.text, step.any_order) {
				fmt.eprintfln("modustool: test failed: step %d: the machine did not print \"%s\"", index + 1, step.text)
				return false
			}
			log := log_read(machine)
			value, found := number_after(log[seen_before:], step.text)
			if !found {
				fmt.eprintfln("modustool: test failed: step %d: no number after \"%s\"", index + 1, step.text)
				return false
			}
			date_check(index, value, step.text, machine.started_unix, machine.clock_offset_seconds) or_return
		case .Screen_Size:
			if !log_wait(machine, step.text, step.any_order) {
				fmt.eprintfln("modustool: test failed: step %d: the machine did not print \"%s\"", index + 1, step.text)
				return false
			}
			// The whole log: a step in any order can find a line before the
			// place of the last step. The size is that of the last start
			// of the compositor.
			if problem := reference_screen_problem(log_read(machine)); problem != "" {
				fmt.eprintfln("modustool: test failed: step %d: %s", index + 1, problem)
				return false
			}
			foundation.test_passed_print("the machine printed \"%s\"", REFERENCE_SCREEN_LINE)
		case .Appearance_Auto:
			appearance_auto_check(machine, index, step) or_return // machine_clock.odin
		case .Bar_Local_Time:
			bar_local_time_check(machine, index, step) or_return // machine_clock.odin
		case .Generation:
			seen_before := machine.seen
			if !log_wait(machine, step.text, step.any_order) {
				fmt.eprintfln("modustool: test failed: step %d: the machine did not print \"%s\"", index + 1, step.text)
				return false
			}
			log := log_read(machine)
			value, found := number_after(log[seen_before:], step.text)
			if !found || value < 1 {
				fmt.eprintfln("modustool: test failed: step %d: no generation after \"%s\"", index + 1, step.text)
				return false
			}
			generation_base = value
			fmt.printfln("modustool: the base of the generations is %d (after \"%s\")", value, step.text)
		case .Trace:
			if !log_wait(machine, step.text) {
				fmt.eprintfln("modustool: test failed: step %d: the machine did not print \"%s\"", index + 1, step.text)
				return false
			}
			log := log_read(machine)
			rest := log[machine.seen:]
			line := rest[:max(strings.index_byte(rest, '\n'), 0)]
			found, named := trace_check(strings.trim_right(line, "\r"), step.names)
			if !named {
				fmt.eprintfln("modustool: test failed: step %d: the stack trace names %s, not %s", index + 1, found, step.names)
				return false
			}
			foundation.test_passed_print("the stack trace after \"%s\" names the functions %s", step.text, found)
		case .Type, .Keys:
			// The keys of the line, and its Enter, go as one list.
			names, unknown := key_names_of_a_text(step.text)
			if unknown >= 0 {
				fmt.eprintfln("modustool: step %d: no key for '%c'", index + 1, step.text[unknown])
				return false
			}
			keys := make([dynamic]string, 0, len(names) + 1, context.temp_allocator)
			append(&keys, ..names)
			if step.kind == .Type {
				append(&keys, "ret")
			}
			// A line that goes to the console: the console writes it on the
			// log when it enters it (console_echo.odin).
			echo_wanted := step.kind == .Type && console_echo_wanted(&machine.echo, step.text)
			if echo_wanted {
				console_echo_owe(machine, step.text)
			}
			if !keys_send(machine, keys[:], fmt.tprintf("\"%s\"", step.text)) {
				fmt.eprintfln("modustool: test failed: step %d: the machine did not take the keys of \"%s\"", index + 1, step.text)
				return false
			}
			if echo_wanted && !machine.echo.line_can_run && !console_echo_wait(machine, index + 1) {
				return false
			}
		case .Key:
			if !keys_send(machine, []string{step.text}, fmt.tprintf("the key %s", step.text)) {
				fmt.eprintfln("modustool: test failed: step %d: the machine did not take the key %s", index + 1, step.text)
				return false
			}
		case .Key_Until:
			// The console input of the firmware of a machine with no screen
			// is the serial terminal, not the PS/2 keyboard of QMP: the key
			// goes on the serial line. A held key repeats in the buffer of the
			// firmware: the presses end when the boot program says that it
			// read the key.
			if machine.serial_input == nil || !machine.serial_input.open {
				fmt.eprintfln("modustool: test failed: step %d: the step Key_Until writes the key on the serial line, and this machine has no serial input: give it the option serial_input", index + 1)
				return false
			}
			pressed := false
			for start := time.now(); time.since(start) < BOOT_HANG_BOUND; {
				log := log_read(machine)
				if len(log) > machine.seen && strings.contains(log[machine.seen:], step.expected) {
					pressed = true
					break
				}
				if !serial_input_write(machine.serial_input, step.text) {
					break
				}
				time.sleep(CONDITION_POLL_PERIOD)
			}
			if !pressed {
				fmt.eprintfln("modustool: test failed: step %d: the machine did not print \"%s\" within %v of the character %q on its serial line", index + 1, step.expected, BOOT_HANG_BOUND, step.text)
				return false
			}
		case .Key_Again_Until:
			// The step decides a dialog of the trusted display with keys
			// that act on its first focus, Refuse, and never move it: a test
			// never allows an act or accepts a plan with repeated keys
			// (src/md/features/assistant.md, "Subtle points"). Its fact
			// fails_on names the other end of the dialog, so the presses
			// stop when the dialog leaves, either way.
			if step.text != "ret" && step.text != "esc" {
				fmt.eprintfln("modustool: test failed: step %d: the step Key_Again_Until presses only ret or esc, which act on Refuse, the first focus of a dialog; it does not press %q", index + 1, step.text)
				return false
			}
			if step.fails_on == "" {
				fmt.eprintfln("modustool: test failed: step %d: the step Key_Again_Until needs fails_on, the fact of the other decision of the dialog", index + 1)
				return false
			}
			decided := false
			for start := time.now(); time.since(start) < foundation.HANG_BOUND; {
				log := log_read(machine)
				if len(log) > machine.seen && strings.contains(log[machine.seen:], step.fails_on) {
					fmt.eprintfln("modustool: test failed: step %d: the machine printed \"%s\" after presses of the key %s, which only refuse", index + 1, step.fails_on, step.text)
					return false
				}
				if len(log) > machine.seen && strings.contains(log[machine.seen:], step.expected) {
					decided = true
					break
				}
				if !keys_send(machine, []string{step.text}, fmt.tprintf("the key %s", step.text)) {
					break
				}
				time.sleep(KEY_AGAIN_PERIOD)
			}
			if !decided {
				fmt.eprintfln("modustool: test failed: step %d: the machine did not print \"%s\" within %v of the key %s", index + 1, step.expected, foundation.HANG_BOUND, step.text)
				return false
			}
			foundation.test_passed_print("the machine printed \"%s\" after presses of the key %s", step.expected, step.text)
		case .Assistant_Turn:
			if assistant_turn_run == nil {
				fmt.eprintfln("modustool: test failed: step %d: this binary of the tool holds no agent runner of the assistant", index + 1)
				return false
			}
			if !machine.client_open {
				if !call_client_open(&machine.client, machine.call_socket) {
					return false
				}
				machine.client_open = true
			}
			printed, ran := assistant_turn_run(&machine.client, machine.call_socket, step.text)
			for line in strings.split_lines(printed, context.temp_allocator) {
				if line != "" {
					fmt.printfln("modustool: assistant turn: %s", line)
				}
			}
			if !ran || !strings.contains(printed, step.expected) {
				fmt.eprintfln("modustool: test failed: step %d: the turn of the agent runner did not print \"%s\"", index + 1, step.expected)
				return false
			}
			foundation.test_passed_print("the turn of the agent runner printed \"%s\"", step.expected)
		case .Click_Absolute, .Press_Absolute, .Move_Absolute, .Release_Absolute:
			x, y := step.x, step.y
			if step.kind == .Move_Absolute {
				x, y = machine.tablet_x + step.x, machine.tablet_y + step.y
			} else if step.kind == .Release_Absolute {
				x, y = machine.tablet_x, machine.tablet_y
			}
			if (step.kind == .Click_Absolute || step.kind == .Press_Absolute) && step.inside_window != "" {
				window_x, window_y, placed := window_place(machine, step.inside_window)
				width, sized := window_width(machine, step.inside_window)
				if !placed || !sized {
					fmt.eprintfln("modustool: test failed: step %d: the log does not have the place of the window %s", index + 1, step.inside_window)
					return false
				}
				x = step.x < 0 ? window_x + width + 2 * WINDOW_BORDER + step.x : window_x + step.x
				y = window_y + step.y
			}
			report_x, x_ok := tablet_report_of_pixel(x, LOGICAL_SCREEN_WIDTH)
			report_y, y_ok := tablet_report_of_pixel(y, LOGICAL_SCREEN_HEIGHT)
			if !x_ok || !y_ok {
				fmt.eprintfln("modustool: test failed: step %d: no report of the tablet lands on %d,%d", index + 1, x, y)
				return false
			}
			// A click presses then releases; a press and a move hold the
			// button; a release lets it go.
			down := step.kind != .Release_Absolute
			sent := machine_command_send(machine, qmp_tablet_click_command(report_x, report_y, down))
			if step.kind == .Click_Absolute {
				sent = sent && machine_command_send(machine, qmp_tablet_click_command(report_x, report_y, false))
			}
			if !sent {
				fmt.eprintfln("modustool: test failed: step %d: QEMU did not take the report of the tablet", index + 1)
				return false
			}
			machine.tablet_x, machine.tablet_y = x, y
			foundation.test_passed_print("the tablet %s at %d,%d (the reports %d,%d)", tablet_act_words(step.kind), x, y, report_x, report_y)
		case .Point:
			x, y := step.x, step.y
			if step.inside_window != "" {
				window_x, window_y, placed := window_place(machine, step.inside_window)
				width, sized := window_width(machine, step.inside_window)
				if !placed || !sized {
					fmt.eprintfln("modustool: test failed: step %d: the log does not have the place of the window %s", index + 1, step.inside_window)
					return false
				}
				x = step.x < 0 ? window_x + width + 2 * WINDOW_BORDER + step.x : window_x + step.x
				y = window_y + step.y
			}
			if !machine.confirm {
				fmt.eprintfln("modustool: test failed: step %d: a step Point reads compositor.pointer(): the tool does not confirm the pointer yet", index + 1)
				return false
			}
			if !pointer_move(machine, x, y) {
				fmt.eprintfln("modustool: test failed: step %d: the pointer did not reach its place", index + 1)
				return false
			}
			// The compositor chooses the shape after the input record and after
			// a request of a process: read it until it is the expected one.
			shape: string
			for start := time.now(); time.since(start) < foundation.HANG_BOUND; {
				read, ok := record_text_field(&machine.client, "compositor.pointer()", "shape")
				if ok {
					shape = read
				}
				if shape == step.text {
					break
				}
				time.sleep(CONDITION_POLL_PERIOD)
			}
			if shape != step.text {
				fmt.eprintfln("modustool: test failed: step %d: the pointer at %d,%d has the shape \"%s\", not \"%s\"", index + 1, x, y, shape, step.text)
				return false
			}
			if step.form == "" {
				foundation.test_passed_print("the pointer at %d,%d has the shape %s", x, y, step.text)
			} else {
				// The form follows the appearance in force at the next frame
				// of the compositor: read it until it is the expected one.
				form: string
				for start := time.now(); time.since(start) < foundation.HANG_BOUND; {
					read, ok := record_text_field(&machine.client, "compositor.pointer()", "form")
					if ok {
						form = read
					}
					if form == step.form {
						break
					}
					time.sleep(CONDITION_POLL_PERIOD)
				}
				if form != step.form {
					fmt.eprintfln("modustool: test failed: step %d: the pointer at %d,%d has the pointer form \"%s\", not \"%s\"", index + 1, x, y, form, step.form)
					return false
				}
				foundation.test_passed_print("the pointer at %d,%d has the shape %s in the pointer form %s", x, y, step.text, step.form)
			}
		case .Front:
			window_front_bring(machine, step.text, index) or_return
		case .Resize:
			window_resize_step(machine, step, index) or_return // machine_resize.odin
		case .Click_Element:
			element_click(machine, step.text, step.element, index) or_return
		case .Wheel:
			element_wheel(machine, step.text, step.element, step.notches, index) or_return
		case .Operation_Sequences:
			operation_sequences_step(machine, index, step.text) or_return
		case .Screen_Text:
			read := screen_text_read(machine, step.text, step.element, index) or_return
			if !step.shown_only {
				screen_text_keep(machine.part, read)
			}
		case .Click, .Drag, .Launch, .Move, .Close:
			step := step
			moved_title: string
			moved_x, moved_y: int
			before := len(log_read(machine))
			if (step.kind == .Click || step.kind == .Drag) && step.inside_window != "" {
				window_x, window_y, placed := window_place(machine, step.inside_window)
				if !placed {
					fmt.eprintfln("modustool: test failed: step %d: the log does not have the place of the window %s", index + 1, step.inside_window)
					return false
				}
				step.x += window_x + WINDOW_BORDER
				step.y += window_y + WINDOW_TITLE_HEIGHT
				if step.kind == .Drag {
					step.to_x += window_x + WINDOW_BORDER
					step.to_y += window_y + WINDOW_TITLE_HEIGHT
				}
			}
			if step.kind == .Close {
				x, y, found := window_place(machine, step.text)
				width, sized := window_width(machine, step.text)
				if !found || !sized {
					fmt.eprintfln("modustool: test failed: step %d: the log does not have the place of the window %s", index + 1, step.text)
					return false
				}
				step.kind = .Click
				step.x, step.y = x + width + 2 * WINDOW_BORDER - WINDOW_CLOSE_RIGHT, y + WINDOW_CLOSE_Y
				// A window over the close button would take the press.
				window_front_where_covered(machine, step.text, step.x, step.y, index) or_return
			}
			if step.kind == .Move {
				// The compositor wrote where it put the window. The pointer
				// takes the title bar.
				x, y: int
				found: bool
				for start := time.now(); !found && time.since(start) < foundation.HANG_BOUND; {
					if x, y, found = window_place(machine, step.text); !found {
						log_change_wait(machine)
					}
				}
				if !found {
					fmt.eprintfln("modustool: test failed: step %d: the log does not have the place of the window %s", index + 1, step.text)
					return false
				}
				moved_title, moved_x, moved_y = step.text, step.to_x, step.to_y
				step.kind = .Drag
				step.x, step.y = x + WINDOW_GRAB_X, y + WINDOW_GRAB_Y
				step.to_x, step.to_y = step.to_x + WINDOW_GRAB_X, step.to_y + WINDOW_GRAB_Y
			}
			// The places of the bar come from the font that draws it: the
			// layout that the compositor wrote in its log, measured here
			// from the same cache of the build.
			layout: bar.Layout
			if step.kind == .Launch || step.kind == .Click && (step.text == BAR_START_BUTTON || step.text == BAR_WINDOWS_BUTTON || step.text == BAR_FIRST_PLATE) {
				known: bool
				if layout, known = machine_bar_layout(machine); !known {
					return false
				}
			}
			if step.kind == .Click && step.text == BAR_START_BUTTON {
				step.x, step.y = bar.button_center(layout)
			}
			if step.kind == .Click && step.text == BAR_WINDOWS_BUTTON {
				step.x, step.y = bar.windows_button_center(layout)
			}
			if step.kind == .Click && step.text == BAR_FIRST_PLATE {
				plate_x, plate_y, plate_width, plate_height := bar.plate(layout, 0)
				step.x, step.y = plate_x + plate_width / 2, plate_y + plate_height / 2
			}
			// A demonstration is in the right pane, which the menu shows only
			// after its quick action: its place is in the open layout.
			launch_demonstration := false
			if step.kind == .Launch {
				section, in_menu := bar.section_of_name(step.text)
				if !in_menu {
					fmt.eprintfln("error: the start menu does not have the module %s", step.text)
					return false
				}
				launch_demonstration = section == .Demonstrations
				found: bool
				step.x, step.y, found = bar.center(bar.with_demonstrations(layout, launch_demonstration), step.text)
				if !found {
					fmt.eprintfln("error: the start menu does not have the module %s", step.text)
					return false
				}
			}
			pointer_known_make(machine, index) or_return
			if step.kind == .Launch {
				menu_x, menu_y := bar.button_center(layout)
				pointer_click(machine, menu_x, menu_y, index) or_return
				// The compositor writes that the menu is open: a press that
				// the machine did not receive is a failure of this step, with
				// its cause, and not of a later one.
				open := false
				for start := time.now(); !open && time.since(start) < foundation.HANG_BOUND; {
					text := log_read(machine)
					if open = len(text) > before && strings.contains(text[before:], "compositor: the start menu is open"); !open {
						log_change_wait(machine)
					}
				}
				if !open {
					fmt.eprintfln("modustool: test failed: step %d: the start menu did not open for %s: the machine did not receive the press on its button", index + 1, step.text)
					return false
				}
				if launch_demonstration {
					action_x, action_y, action_width, action_height := bar.action_line(layout, .Demonstrations)
					shown_before := len(log_read(machine))
					pointer_press_at(machine, action_x + action_width / 2, action_y + action_height / 2, index) or_return
					pointer_button(machine, false) or_return
					shown := false
					for start := time.now(); !shown && time.since(start) < foundation.HANG_BOUND; {
						text := log_read(machine)
						if shown = len(text) > shown_before && strings.contains(text[shown_before:], "compositor: the demonstrations of the start menu are shown"); !shown {
							log_change_wait(machine)
						}
					}
					if !shown {
						fmt.eprintfln("modustool: test failed: step %d: the start menu did not show its demonstrations for %s", index + 1, step.text)
						return false
					}
				}
			}
			pointer_press_at(machine, step.x, step.y, index) or_return
			if step.kind == .Drag {
				if !pointer_move(machine, step.to_x, step.to_y) {
					fmt.eprintfln("modustool: test failed: step %d: the pointer did not reach its place", index + 1)
					return false
				}
			}
			pointer_button(machine, false) or_return
			if moved_title != "" {
				// The compositor writes the new place: the window did move.
				arrived := false
				for start := time.now(); !arrived && time.since(start) < foundation.HANG_BOUND; {
					x, y, found := window_place(machine, moved_title)
					if arrived = found && x == moved_x && y == moved_y; !arrived {
						log_change_wait(machine)
					}
				}
				if !arrived {
					fmt.eprintfln("modustool: test failed: step %d: the window %s is not at %d,%d", index + 1, moved_title, moved_x, moved_y)
					return false
				}
			}
		case .Record:
			if !machine.client_open {
				if !call_client_open(&machine.client, machine.call_socket) {
					return false
				}
				machine.client_open = true
			}
			found := false
			from := machine.record_next
			reads := 0
			last_rows, last_total := 0, i64(0)
			last_ok := false
			last_table: Call_Table
			for start := time.now(); !found && time.since(start) < foundation.HANG_BOUND; {
				table, ok := table_call(&machine.client, fmt.tprintf("log.records(%d)", from))
				reads += 1
				rows := ok ? len(table.rows) / table.size : 0
				last_rows, last_total, last_ok = rows, table.total, ok
				last_table = table
				// A log fact has an empty text in its row: the step reads
				// its sentence, which the tool writes from its values
				// (fact_steps.odin), so a wait on the sentence of a line
				// that became a fact reads it as before. A row of
				// fact_records is not larger than a row of records (an
				// #assert of the log service), and only a fact has one, so
				// the answer from the same number covers each fact of this
				// answer; read_through still says how far it reached, so a
				// fact past it is read again and never skipped.
				fact_sentences: map[i64]string
				fact_read_through := from - 1
				fact_waits := false
				for row in 0 ..< rows {
					if table_value(&table, row, "form") == "Fact" {
						fact_sentences, fact_read_through = record_fact_sentences(machine, from)
						break
					}
				}
				// A text goes on in the next row when its row says so
				// (log.records: a row is one log record, of 168 bytes of
				// text): the rows of one text are joined before the
				// comparison.
				// A row joins the group only when it is the next record of the
				// same writer and form: an answer can miss a record that the
				// kernel wrote over during the read, and a group across that
				// gap would join the records of two processes.
				row_follows :: proc(table: ^Call_Table, last: int) -> bool {
					last_number, _ := strconv.parse_i64(table_value(table, last, "number"))
					next_number, _ := strconv.parse_i64(table_value(table, last + 1, "number"))
					return next_number == last_number + 1 && table_value(table, last + 1, "form") == table_value(table, last, "form") && table_value(table, last + 1, "slot") == table_value(table, last, "slot")
				}
				for row := 0; row < rows; {
					last := row
					for last < rows - 1 && table_value(&table, last, "continues") == "1" && row_follows(&table, last) {
						last += 1
					}
					if last == rows - 1 && table_value(&table, last, "continues") == "1" {
						break // The rest of the text is after the rows of this call: read again from it.
					}
					joined := strings.builder_make(context.temp_allocator)
					number, _ := strconv.parse_i64(table_value(&table, row, "number"))
					last_number, _ := strconv.parse_i64(table_value(&table, last, "number"))
					if table_value(&table, row, "form") == "Fact" {
						// The rows of a fact of several records are one
						// group, and its sentence is in the place of its last
						// record (fact_record_rows_sentences).
						fact_sentence, has_sentence := fact_sentences[last_number]
						if !has_sentence && last_number > fact_read_through {
							// The answer of fact_records did not reach this
							// fact: read again from it, as for a text that
							// goes on.
							fact_waits = true
							break
						}
						// A fact that the answer reached and whose module
						// the build does not hold has no sentence: no text
						// is in it.
						strings.write_string(&joined, fact_sentence)
					} else {
						for part in row ..= last {
							strings.write_string(&joined, table_value(&table, part, "text"))
						}
					}
					if table_value(&table, row, "process") == step.process && table_value(&table, row, "level") == step.level && strings.contains(strings.to_string(joined), step.text) {
						found = true
						machine.record_found, machine.record_found_any = number, true
						if !step.any_order {
							machine.record_next = last_number + 1
						}
						foundation.test_passed_print("the log record %d of %s, level %s, has \"%s\" (%d calls of log.records, %d rows)", number, step.process, step.level, step.text, reads, last - row + 1)
						break
					}
					from = last_number + 1
					row = last + 1
				}
				if !found && (rows == 0 || fact_waits) {
					time.sleep(CONDITION_POLL_PERIOD)
				}
			}
			if !found {
				fmt.eprintfln("modustool: test failed: step %d: no log record of %s, level %s, has \"%s\" (%d calls of log.records, the last one from %d: %v, %d rows of %d)", index + 1, step.process, step.level, step.text, reads, from, last_ok, last_rows, last_total)
				compact := strings.builder_make(context.temp_allocator)
				for row in 0 ..< last_rows {
					fmt.sbprintf(&compact, "%s:%s ", table_value(&last_table, row, "number"), table_value(&last_table, row, "continues"))
				}
				fmt.eprintfln("modustool:     the rows (number:continues): %s", strings.to_string(compact))
				return false
			}
		case .Fact:
			fact_step_run(machine, index, step) or_return // fact_steps.odin
		case .Agree:
			// The process list of the monitor, and the reports of inspect. The
			// monitor reads the processes of the machine at its own rhythm: a
			// process that just started is in its list at its next read. So
			// the step asks again until the two agree; the bound only ends a
			// hang.
			monitor, mappings, threads: Call_Table
			has_monitor, has_mappings, has_threads: bool
			mapped, threads_count, pages: int
			agree_started := time.now()
			for {
				monitor, has_monitor = table_call(&machine.client, "monitor.processes()")
				mapped, threads_count = -1, -1
				if has_monitor {
					for row in 0 ..< len(monitor.rows) / monitor.size {
						if table_value(&monitor, row, "name") == step.text {
							mapped, _ = strconv.parse_int(table_value(&monitor, row, "mapped"))
							threads_count, _ = strconv.parse_int(table_value(&monitor, row, "threads"))
						}
					}
				}
				mappings, has_mappings = table_call(&machine.client, fmt.tprintf("inspect.mappings(%q)", step.text))
				threads, has_threads = table_call(&machine.client, fmt.tprintf("inspect.threads(%q)", step.text))
				pages = 0
				if has_mappings {
					for row in 0 ..< len(mappings.rows) / mappings.size {
						value, _ := strconv.parse_int(table_value(&mappings, row, "pages"))
						pages += value
					}
				}
				if (has_monitor && has_mappings && has_threads && mapped >= 0 && pages == mapped && int(threads.total) == threads_count) || time.since(agree_started) > foundation.HANG_BOUND {
					break
				}
				time.sleep(CONDITION_POLL_PERIOD)
			}
			if !has_monitor || !has_mappings || !has_threads || mapped < 0 || pages != mapped || int(threads.total) != threads_count {
				fmt.eprintfln("modustool: test failed: step %d: %s: monitor.processes() gives %d mapped pages and %d threads, inspect gives %d pages in %d mappings and %d threads", index + 1, step.text, mapped, threads_count, pages, mappings.total, threads.total)
				return false
			}
			foundation.test_passed_print("%s: inspect gives %d pages in %d mappings and %d threads, as monitor.processes() gives", step.text, pages, mappings.total, threads.total)
		case .Ask_Wide_Grant:
			if !machine.client_open {
				if !call_client_open(&machine.client, machine.call_socket) {
					return false
				}
				machine.client_open = true
			}
			authorities := wide_grants.Wide_Authorities{.View_Screen}
			if step.text == "view_and_input" {
				authorities += {.Send_Input}
			}
			answer, transport, sent := wide_grant_ask_send(&machine.client, authorities, u64(step.milliseconds))
			if !sent {
				fmt.eprintfln("modustool: test failed: step %d: the ask of a wide grant got no answer: %s", index + 1, transport.reason)
				return false
			}
			refused := answer.status != .Ok
			if refused != (step.outcome == .Refused) || (!refused && step.expected != "" && fmt.tprint(answer.value) != step.expected) {
				fmt.eprintfln("modustool: test failed: step %d: the ask of a wide grant gave the status %v, the screen %d, and the error record %v", index + 1, answer.status, answer.value, answer.error)
				return false
			}
			foundation.test_passed_print("the ask of a wide grant with the scopes %s for %d ms gave %s", step.text, step.milliseconds, refused ? "its refusal" : fmt.tprintf("the screen %d", answer.value))
		case .Call:
			call_started_unix := time.time_to_unix(time.now()) // No date in the answer is before it.
			if !machine.client_open {
				if !call_client_open(&machine.client, machine.call_socket) {
					return false
				}
				machine.client_open = true
			}
			served_before: i64
			lost_before: int
			if step.lose > 0 {
				before, has_before := record_field(&machine.client, "monitor.served()", "calls")
				if !has_before {
					fmt.eprintfln("modustool: test failed: step %d: monitor.served() gave no record", index + 1)
					return false
				}
				served_before = before
				lost_before = peer_remote_lose(machine.peer.remote, step.lose)
			}
			machine.client.wrong_hash = step.wrong_hash
			result := call_run(&machine.client, step.text)
			if step.pointer {
				// A result: the tool confirms each place from now on. A
				// refusal (the grant `acts_for_principal` was revoked): the blind way
				// again.
				machine.confirm = result.outcome == .Result
				foundation.test_passed_print("the tool %s the place of the pointer through compositor.pointer() from now on", machine.confirm ? "reads" : "no longer reads")
			}
			printed := strings.join(result.lines[:], "\n", context.temp_allocator)
			for line in result.lines {
				fmt.printfln("modustool: call %s: %s", step.text, line)
			}
			if result.outcome != step.outcome || !strings.contains(printed, step.expected) {
				fmt.eprintfln("modustool: test failed: step %d: the call %s gave %v, not %v with \"%s\"", index + 1, step.text, result.outcome, step.outcome, step.expected)
				return false
			}
			if result.outcome == .Failed && len(result.lines) > 0 && ends_with_a_bare_number(result.lines[0]) {
				fmt.eprintfln("modustool: test failed: step %d: the failed line of %s ends with a bare number: %s", index + 1, step.text, result.lines[0])
				return false
			}
			if result.answer_bytes < step.least_answer_bytes {
				fmt.eprintfln("modustool: test failed: step %d: the answer of %s has %d bytes, not %d or more", index + 1, step.text, result.answer_bytes, step.least_answer_bytes)
				return false
			}
			foundation.test_passed_print("the call %s printed \"%s\", an answer of %d bytes on one stream, %d datagrams of remote during the call%s", step.text, step.expected, result.answer_bytes, result.datagrams, result.new_connection ? ", on a new connection" : "")
			if step.date_after != "" {
				milliseconds, found := number_after(printed, step.date_after)
				if !found {
					fmt.eprintfln("modustool: test failed: step %d: no number after \"%s\" in the answer of %s", index + 1, step.date_after, step.text)
					return false
				}
				date_check(index, milliseconds / 1000, step.text, call_started_unix, machine.clock_offset_seconds) or_return
			}
			if step.lose > 0 {
				// QUIC sent the dropped datagrams again; the service ran the
				// call one time: served() counts the call of the step and its
				// own call before.
				lost := peer_remote_lost(machine.peer.remote) - lost_before
				after, has_after := record_field(&machine.client, "monitor.served()", "calls")
				if lost < step.lose || !has_after || after - served_before != 2 {
					fmt.eprintfln("modustool: test failed: step %d: the peer dropped %d datagrams of remote (%d asked), and the monitor ran %d calls, not 2", index + 1, lost, step.lose, after - served_before)
					return false
				}
				foundation.test_passed_print("the peer dropped %d datagrams of remote during %s; QUIC sent them again, and the monitor ran the call one time", lost, step.text)
			}
			if step.rows_call != "" {
				// Another call gives the count of the rows.
				counted := call_run(&machine.client, step.rows_call)
				if counted.outcome != .Result || counted.value != i64(result.rows) {
					fmt.eprintfln("modustool: test failed: step %d: the call gave %d rows, %s gives %d", index + 1, result.rows, step.rows_call, counted.value)
					return false
				}
				foundation.test_passed_print("the call gave %d rows, and %s gives %d", result.rows, step.rows_call, counted.value)
			}
			if step.repeat > 0 {
				least, middle, per_second, measured := call_measure(&machine.client, step.text, step.repeat)
				if !measured {
					fmt.eprintfln("modustool: test failed: step %d: the measure of %s had a call with no answer", index + 1, step.text)
					return false
				}
				foundation.test_passed_print("the call %s from the host: the round trip %d us at least, %d us in the middle, over %d calls; %d calls in one second, one after the other", step.text, i64(least / time.Microsecond), i64(middle / time.Microsecond), step.repeat, per_second)
			}
		case .Remember:
			if !log_wait(machine, step.text, false) {
				fmt.eprintfln("modustool: test failed: step %d: the machine did not print \"%s\"", index + 1, step.text)
				return false
			}
			log := log_read(machine)
			rest := log[machine.seen:]
			line := strings.trim_right(rest[:max(strings.index_byte(rest, '\n'), 0)], "\r")
			append(&machine.part.remembered_values, strings.clone(line))
			fmt.printfln("modustool: the machine drew \"%s\" after \"%s\"", line, step.text)
		case .Distinct:
			remembered := machine.part.remembered_values[:]
			for value, first in remembered {
				for other in remembered[first + 1:] {
					if value == other {
						fmt.eprintfln("modustool: test failed: step %d: %s: the value \"%s\" came two times", index + 1, step.text, value)
						return false
					}
				}
			}
			foundation.test_passed_print("%s: %d values, each different", step.text, len(remembered))
		case .Quic_Key:
			if !log_wait(machine, step.text, false) {
				fmt.eprintfln("modustool: test failed: step %d: the machine did not print \"%s\"", index + 1, step.text)
				return false
			}
			log := log_read(machine)
			rest := log[machine.seen:]
			line := strings.trim_right(rest[:max(strings.index_byte(rest, '\n'), 0)], "\r")
			if !peer_quic_pin(machine.peer, line) {
				fmt.eprintfln("modustool: test failed: step %d: \"%s\" is not a public key of 64 hexadecimal digits", index + 1, line)
				return false
			}
			fmt.printfln("modustool: the QUIC client of the peer pins the key %s", line)
		case .Remote_Key:
			if !log_wait(machine, step.text, false) {
				fmt.eprintfln("modustool: test failed: step %d: the machine did not print \"%s\"", index + 1, step.text)
				return false
			}
			log := log_read(machine)
			rest := log[machine.seen:]
			line := strings.trim_right(rest[:max(strings.index_byte(rest, '\n'), 0)], "\r")
			if !peer_remote_pin_text(machine.peer.remote, line) {
				fmt.eprintfln("modustool: test failed: step %d: \"%s\" is not a public key of 64 hexadecimal digits", index + 1, line)
				return false
			}
			fmt.printfln("modustool: the QUIC client of remote in the peer pins the key %s", line)
		case .Remote_Display_Key:
			if !log_wait(machine, step.text, false) {
				fmt.eprintfln("modustool: test failed: step %d: the machine did not print \"%s\"", index + 1, step.text)
				return false
			}
			log := log_read(machine)
			rest := log[machine.seen:]
			line := strings.trim_right(rest[:max(strings.index_byte(rest, '\n'), 0)], "\r")
			for viewer in machine.peer.display_viewers {
				if !peer_display_pin_text(viewer, line) {
					fmt.eprintfln("modustool: test failed: step %d: \"%s\" is not a public key of 64 hexadecimal digits", index + 1, line)
					return false
				}
			}
			fmt.printfln("modustool: the viewers of remote_display in the peer pin the key %s", line)
		case .Viewer_Relay:
			if !log_wait(machine, step.text, false) {
				fmt.eprintfln("modustool: test failed: step %d: the machine did not print \"%s\"", index + 1, step.text)
				return false
			}
			log := log_read(machine)
			rest := log[machine.seen:]
			line := strings.trim_right(rest[:max(strings.index_byte(rest, '\n'), 0)], "\r")
			if !viewer_relay_announce(machine, step.text, line) {
				fmt.eprintfln("modustool: test failed: step %d: \"%s\" is not a public key of 64 hexadecimal digits", index + 1, line)
				return false
			}
		case .Remote_Display_Case:
			passed, result := remote_display_case_run(machine, step.text)
			if !passed {
				fmt.eprintfln("modustool: test failed: step %d: the case \"%s\" of remote_display: %s", index + 1, step.text, result)
				return false
			}
			foundation.test_passed_print("the case \"%s\" of remote_display: %s", step.text, result)
		case .Remote_Case:
			if !machine.client_open {
				if !call_client_open(&machine.client, machine.call_socket) {
					return false
				}
				machine.client_open = true
			}
			passed, result := remote_case_run(machine, step.text)
			if !passed {
				fmt.eprintfln("modustool: test failed: step %d: the case \"%s\" of remote: %s", index + 1, step.text, result)
				return false
			}
			foundation.test_passed_print("the case \"%s\" of remote: %s", step.text, result)
		case .Openssl_Quic:
			if !openssl_quic_run(machine, step.text) {
				fmt.eprintfln("modustool: test failed: step %d: the QUIC client of OpenSSL", index + 1)
				return false
			}
		case .Peer_Quic:
			passed, result := peer_quic_case(machine.peer, step.text)
			// The last counts of the server that the log has, for the
			// message: quic_echo writes them once in a second when they
			// change, so they can be older than the case. No step reads them
			// here: a step Wait reads a count that the scenario needs. No
			// time passes between two cases: a case that needs the budgets
			// of the server to be full again waits for that itself
			// (peer_quic.odin, peer_quic_connect_again).
			counts := log_last_line(machine, "quic_echo: accepted ")
			if !passed {
				fmt.eprintfln("modustool: test failed: step %d: the QUIC case \"%s\" of the peer: %s; the last counts of the server in the log: %s", index + 1, step.text, result, counts)
				return false
			}
			foundation.test_passed_print("the QUIC case \"%s\" of the peer: %s; the last counts of the server in the log: %s", step.text, result, counts)
		case .Peer_Start:
			peer_case_started = peer_case_start_from_the_tool(machine.peer, step.text)
			fmt.printfln("modustool: the TCP case \"%s\" of the peer runs; the next steps run with it", step.text)
		case .Peer_Mark:
			peer_case_mark(machine.peer, peer_case_started)
			fmt.printfln("modustool: the TCP case \"%s\" of the peer is marked: the next step acts", step.text)
		case .Peer_Result:
			passed, result := peer_case_result(machine.peer, peer_case_started)
			if !passed {
				fmt.eprintfln("modustool: test failed: step %d: the TCP case \"%s\" of the peer: %s", index + 1, step.text, result)
				return false
			}
			foundation.test_passed_print("the TCP case \"%s\" of the peer: %s", step.text, result)
		case .Peer:
			passed, result := peer_case(machine.peer, step.text)
			if !passed {
				fmt.eprintfln("modustool: test failed: step %d: the TCP case \"%s\" of the peer: %s", index + 1, step.text, result)
				return false
			}
			foundation.test_passed_print("the TCP case \"%s\" of the peer: %s", step.text, result)
		case .Fetch:
			if !forward_fetch(machine.forward, step.text, machine.clock_offset_seconds) {
				return false
			}
		case .Http:
			if !http_case_run(machine.forward, step.text, step.expected) {
				fmt.eprintfln("modustool: test failed: step %d: the HTTP case \"%s\"", index + 1, step.text)
				return false
			}
		case .Quit:
			monitor_send(machine, "quit")
		case .Monitor:
			monitor_send(machine, step.text)
		case .Power_Loss_Arm:
			server := machine.disk_server
			if server == nil {
				fmt.eprintfln("modustool: test failed: step %d: the tool does not serve the data disk", index + 1)
				return false
			}
			if step.commits < 0 {
				fmt.eprintfln("modustool: test failed: step %d: a step Power_Loss_Arm with %d commits", index + 1, step.commits)
				return false
			}
			generator := rand.create_u64(POWER_LOSS_SEED)
			at_root := step.commits + 1 + rand.int_max(POWER_LOSS_SEEDED_ROOTS, rand.default_random_generator(&generator))
			power_off_arm(server, at_root, step.text)
			if step.text == "" {
				fmt.printfln("modustool: the disk loses its power at the write of the root %d from now (%d, then %d seeded, seed %d)", at_root, step.commits, at_root - step.commits, POWER_LOSS_SEED)
			} else {
				fmt.printfln("modustool: the disk loses its power at the write of the root %d after the block that starts with \"%s\" (%d, then %d seeded, seed %d)", at_root, step.text, step.commits, at_root - step.commits, POWER_LOSS_SEED)
			}
		case .Power_Loss:
			server := machine.disk_server
			if server == nil {
				fmt.eprintfln("modustool: test failed: step %d: the tool does not serve the data disk", index + 1)
				return false
			}
			sync.mutex_lock(&server.lock)
			armed := server.power_off_at_root != 0
			sync.mutex_unlock(&server.lock)
			if !armed {
				fmt.eprintfln("modustool: test failed: step %d: a step Power_Loss with no step Power_Loss_Arm before it", index + 1)
				return false
			}
			// The bound ends a stall only: each write is progress toward the
			// root of the cut.
			last_writes := -1
			last_progress := time.now()
			for !sync.atomic_load(&server.powered_off) && time.since(last_progress) < foundation.HANG_BOUND {
				sync.mutex_lock(&server.lock)
				writes := server.writes
				sync.mutex_unlock(&server.lock)
				if writes != last_writes {
					last_writes = writes
					last_progress = time.now()
				}
				time.sleep(CONDITION_POLL_PERIOD)
			}
			// A kill: QEMU writes nothing more. The tool knows what was
			// durable when the disk lost its power.
			_ = os.process_kill(machine.host_process)
			machine.powered_off = true
			sync.mutex_lock(&server.lock)
			roots, at_root, counting, writes, marker := server.power_off_roots, server.power_off_at_root, server.power_off_counting, server.writes, server.power_off_marker
			sync.mutex_unlock(&server.lock)
			if !sync.atomic_load(&server.powered_off) {
				if !counting {
					fmt.eprintfln("modustool: test failed: step %d: the machine made no write for the time of a hang, and no write of a block that starts with \"%s\"", index + 1, marker)
				} else {
					fmt.eprintfln("modustool: test failed: step %d: the machine made no write for the time of a hang, after %d of the %d writes of a root", index + 1, roots, at_root)
				}
				return false
			}
			fmt.printfln("modustool: the power of the disk went off at its write %d, the write of the root %d after the start of the count (seed %d)", writes, roots, POWER_LOSS_SEED)
		case .Disk_Disconnect:
			if machine.disk_server == nil {
				fmt.eprintfln("modustool: test failed: step %d: the tool does not serve the data disk", index + 1)
				return false
			}
			disk_server_disconnect(machine.disk_server)
		case .Shot:
			if !screen_save(machine, step.text) {
				return false
			}
		case .Film_Start:
			if !film_start(machine, step.text) {
				fmt.eprintfln("modustool: test failed: step %d: the film %s did not start", index + 1, step.text)
				return false
			}
		case .Film_Stop:
			if machine.film == nil {
				fmt.eprintfln("modustool: test failed: step %d: a step Film_Stop with no film that runs", index + 1)
				return false
			}
			if !film_stop(machine) {
				fmt.eprintfln("modustool: test failed: step %d: the worker of the film ended before its stop", index + 1)
				return false
			}
		case .Film_Type:
			// The seed of the step: each text of a film has its own periods,
			// the same in each run.
			if !film_type(machine, step.text, FILM_TYPING_SEED + u64(index)) {
				fmt.eprintfln("modustool: test failed: step %d: the machine did not take the keys of \"%s\"", index + 1, step.text)
				return false
			}
		case .Film_Hold:
			// A hold with a text starts a cue: its time is the moment the
			// scene reached its state, before the hold.
			if step.text != "" && !film_cue_note(machine, step.text) {
				fmt.eprintfln("modustool: test failed: step %d: the cue %s is refused", index + 1, step.text)
				return false
			}
			// A time of a film, for its viewer: the scenario of a test has
			// no such step, and waits for a condition (film.odin).
			time.sleep(time.Duration(step.milliseconds) * time.Millisecond)
		}
		free_all(context.temp_allocator)
	}
	return true
}

// The windows that the interface package draws (docs/INTERFACE.md, "State
// of the conversions"), for `modustool measure windows`. often: the process
// draws a picture each second or more, so the log has the mean of 10.
@(rodata)
measured_windows := [?]struct {
	name:  string,
	often: bool,
} {
	{"time_page", true},
	{"life", true},
	{"monitor", true},
	{"inspect", true},
	{"scheduler", true},
	{"locks", false},
	{"budget", false},
	{"rights", false},
	{"origin", false},
	{"limits", false},
	{"frames", false},
	{"imports", false},
	{"flow", false},
	{"crowd", false},
	{"tally", false},
	{"manual", false},
	{"errors", false},
	{"interface_elements", true},
}

TEST_OUTPUT_MEASURE_WINDOWS :: foundation.BUILD_FOLDER + "/test_output_measure_windows.txt"

// measure_windows starts each window of measured_windows alone, waits for
// the time of its pictures, closes it, then prints one table. A measure is
// valid when the load of the host is under 8: the table says the load.
measure_windows :: proc(part: ^Test_Part_Run) -> bool {
	// Not in the temporary allocator: the scenario frees it after each step.
	steps := make([dynamic]Step)
	defer delete(steps)
	texts := make([dynamic]string)
	defer {
		for text in texts {
			delete(text)
		}
		delete(texts)
	}
	append(&steps, Step{kind = .Wait, text = "compositor: surface console"})
	for window in measured_windows {
		append(&steps, Step{kind = .Launch, text = window.name})
		drew := strings.concatenate({"display: ", window.name, " drew one picture in "})
		stopped := strings.concatenate({"root: ", window.name, " stopped"})
		append(&texts, drew, stopped)
		append(&steps, Step{kind = .Wait, text = drew})
		if window.often {
			append(&steps, Step{kind = .Wait, text = " the mean of 10"})
		}
		append(&steps, Step{kind = .Close, text = window.name})
		append(&steps, Step{kind = .Wait, text = stopped})
	}
	append(&steps, Step{kind = .Front, text = "console"}, Step{kind = .Type, text = "shutdown()"}, Step{kind = .Wait, text = "kernel: the machine stops with code 0"})
	// A copy outside the temporary allocator: the scenario frees it.
	load_before := strings.clone(load_of_the_host())
	defer delete(load_before)
	if !machine_test(part, steps[:], {volume = build.BOOT_VOLUME_MEASURE, output = TEST_OUTPUT_MEASURE_WINDOWS, exit_status = build.MACHINE_STOP_OK}) {
		return false
	}
	load_after := load_of_the_host()
	log, _ := os.read_entire_file(TEST_OUTPUT_MEASURE_WINDOWS, context.temp_allocator)
	highest := max(strconv.parse_f64(load_before) or_else 99, strconv.parse_f64(load_after) or_else 99)
	fmt.printfln("modustool: the time of one picture of each window, us (the load of the host: %s at the start, %s at the end%s)", load_before, load_after, highest <= 8 ? "" : "; ABOVE 8: NOT VALID")
	fmt.printfln("%-20s %12s %12s %12s", "window", "first", "mean of 3", "mean of 10")
	for window in measured_windows {
		mark := strings.concatenate({"display: ", window.name, " drew one picture in "}, context.temp_allocator)
		values: [3]string = {"-", "-", "-"}
		for line in strings.split_lines(string(log), context.temp_allocator) {
			at := strings.index(line, mark)
			if at < 0 {
				continue
			}
			rest := line[at + len(mark):]
			value := rest[:max(strings.index(rest, " us"), 0)]
			switch {
			case strings.has_suffix(strings.trim_space(line), "the mean of 1"):
				values[0] = value
			case strings.has_suffix(strings.trim_space(line), "the mean of 3"):
				values[1] = value
			case strings.has_suffix(strings.trim_space(line), "the mean of 10"):
				values[2] = value
			}
		}
		fmt.printfln("%-20s %12s %12s %12s", window.name, values[0], values[1], values[2])
	}
	return true
}

// wait_share_sentence reads the counters of the host again at the failure
// of a step Wait, and says what the host gave the machine since the start
// of the step (host_share.odin).
wait_share_sentence :: proc(machine: ^Machine) -> string {
	after := host_share_sample(machine.host_process.pid)
	waited := u64(max(time.tick_since(machine.wait_started), 0) / time.Millisecond)
	return host_share_sentence(machine.wait_share, after, waited)
}

// load_of_the_host gives the load of the host over one minute, from /proc/loadavg.
load_of_the_host :: proc() -> string {
	text, err := os.read_entire_file("/proc/loadavg", context.temp_allocator)
	if err != nil {
		return "unknown"
	}
	return string(text[:max(strings.index_byte(string(text), ' '), 0)])
}
