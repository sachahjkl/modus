package terminal_records

import "modus:contract/enum_word"
import "modus:contract/ring"

// The intake of a terminal renderer that draws no window: serial_terminal
// and grid_terminal (src/md/features/console_renderers.md, "One intake").
// It reads each command record of the terminal ring with the checks of the
// terminal of the desktop: a word that names no record is refused and
// counted, the text comes from the text region in two parts, the runs of
// code are checked against their line, and the rows of a completion list
// go through List_Keeping. A renderer draws from the step that it gives,
// and never reads a record itself, so the two renderers cannot differ on
// what a record means.

// What a renderer draws after one record.
Renderer_Step :: enum u8 {
	None  = 0, // Nothing that the renderer shows changed.
	Text  = 1, // A run of text: Renderer_Intake.text, with Renderer_Event.style.
	Clear = 2, // Forget all the lines.
	Edit  = 3, // The edit line changed: Renderer_Intake.edit.
	List  = 4, // The completion list changed: Renderer_Intake.list.shown.
}

// What one record gives a renderer.
Renderer_Event :: struct {
	step:  Renderer_Step,
	style: Style, // Text and Edit: the style of the record.
}

// The edit line as a renderer shows it.
Renderer_Edit :: struct {
	text:       [RUN_LIMIT]u8,
	length:     int,
	has_cursor: bool,
	cursor:     int, // Bytes from the start of the text, at most length.
	code:       Code_Runs, // Checked against the text: no runs when they did not fit.
}

// The state of the intake. Zero is an intake with no text region: each
// text reads as empty.
Renderer_Intake :: struct {
	text_region:       []u8, // The text region of the terminal ring.
	read:              u64, // The bytes of the text region read so far.
	text:              [RUN_LIMIT]u8, // The text of the last Text record.
	text_length:       int,
	edit:              Renderer_Edit,
	edit_runs_pending: Code_Runs,
	list:              List_Keeping,
	records_refused:   u64, // Records whose word names no record.
	runs_refused:      u64, // Runs for the edit line that did not fit it, or that named no target that takes runs.
}

// renderer_intake_make gives an intake that reads the text region.
renderer_intake_make :: proc "contextless" (text_region: []u8) -> Renderer_Intake {
	intake := Renderer_Intake {
		text_region = text_region,
	}
	intake.list.shown.chosen = -1
	return intake
}

// renderer_take gives the next count bytes of the text region as two
// parts: the region starts again at its first byte after its last. A count
// past RUN_LIMIT is cut to it, as the terminal of the desktop cuts it.
renderer_take :: proc "contextless" (intake: ^Renderer_Intake, count: u32) -> (first, second: []u8) {
	count := int(min(count, RUN_LIMIT))
	region_size := len(intake.text_region)
	start := intake.read
	intake.read += u64(count)
	if region_size == 0 {
		return nil, nil
	}
	place := int(start % u64(region_size))
	first_size := min(count, region_size - place)
	// The second part ends before the first part starts: a region smaller
	// than a record never gives a byte twice.
	second_size := min(count - first_size, place)
	return intake.text_region[place:][:first_size], intake.text_region[:second_size]
}

// renderer_intake_take reads one command record and gives what the
// renderer draws.
renderer_intake_take :: proc "contextless" (intake: ^Renderer_Intake, record: ring.Record) -> Renderer_Event {
	kind, kind_ok := kind_of_ring_word(record.kind)
	if !kind_ok {
		intake.records_refused += 1
		return {}
	}
	switch kind {
	case .None:
		// kind_of_ring_word refuses it.
		return {}
	case .Text:
		first, second := renderer_take(intake, record.tag)
		intake.text_length = copy(intake.text[:], first)
		intake.text_length += copy(intake.text[intake.text_length:], second)
		return {step = .Text, style = transmute(Style)record.values[0]}
	case .Status, .Hint:
		// A renderer with no window keeps no status line and no hint line:
		// their text is read past, so the next record reads its own text.
		_, _ = renderer_take(intake, record.tag)
		return {}
	case .Clear:
		return {step = .Clear}
	case .Edit:
		first, second := renderer_take(intake, record.tag)
		edit := &intake.edit
		edit^ = {}
		edit.length = copy(edit.text[:], first)
		edit.length += copy(edit.text[edit.length:], second)
		if record.values[1] != NO_CURSOR {
			edit.has_cursor = true
			edit.cursor = int(min(record.values[1], u64(edit.length)))
		}
		edit.code = intake.edit_runs_pending
		intake.edit_runs_pending = {}
		if edit.code.count != 0 && !code_runs_check(&edit.code, edit.length) {
			intake.runs_refused += 1
		}
		return {step = .Edit, style = transmute(Style)record.values[0]}
	case .List_Row:
		first, second := renderer_take(intake, record.tag)
		list_keep_row(&intake.list, record.values, first, second)
		return {}
	case .List:
		list_keep_show(&intake.list, record.values)
		return {step = .List}
	case .Code_Runs:
		first, second := renderer_take(intake, record.tag)
		target, target_ok := enum_word.member_of_word(Kind, record.values[0])
		if !target_ok {
			intake.runs_refused += 1
			return {}
		}
		switch target {
		case .Edit:
			read, ok := code_runs_read(first, second)
			if !ok {
				intake.runs_refused += 1
			}
			intake.edit_runs_pending = read
		case .List_Row:
			list_keep_code_runs(&intake.list, record.values, first, second)
		case .None, .Text, .Status, .Clear, .Hint, .List, .Code_Runs:
			intake.runs_refused += 1
		}
		return {}
	}
	return {}
}
