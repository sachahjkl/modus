package console

// The completion of the console: a list of names that opens under the
// line while the input types, and the search of the history.
//
// The console knows the names: its commands, the exports of the modules
// and services that it loaded or connected (from their descriptions), its
// variables, the modules of the boot image, the processes that run. It
// ranks them with the fuzzy match of src/library/support/line_editor, and gives the
// rows to show to its terminal (src/library/support/terminal, List_Row and List). The
// terminal owns the cells and draws the list over its text. The rows go
// through the text region of this console and its terminal, which no third
// process reads: the terminal already shows each name that help() prints.
//
// Only the first thread uses this file, and only while no line runs: the
// second thread changes the tables of names during a line, never between
// two lines.

import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/text_encoding"
import "modus:contract/value_kinds"
import "modus:support/console_language"
import "modus:private/console/console_stream"
import "modus:support/lex_evaluator"
import "modus:support/display"
import "modus:support/line_editor"
import "modus:support/system"
import terminal "modus:support/terminal"

List_Mode :: enum u8 {
	Closed  = 0,
	Names   = 1, // The names that complete the name at the caret.
	History = 2, // The lines of the history that match a search.
}

// The names that one list reads. Today the console has at most 128
// commands, 12 services, 16 variables, the modules of the boot image and 64
// processes; a name past this count is not read.
CANDIDATE_CAPACITY :: 512
SEARCH_CAPACITY :: 64 // The bytes of a search of the history.
PROCESS_NAME_CAPACITY :: 64

Completion :: struct {
	mode:           List_Mode,
	escaped:        bool, // Escape closed the list: the next character opens it again.
	list_changed:   bool, // The terminal does not show the list of this record yet.
	place:          line_editor.Completion_Context, // Names: where the caret was when the list was made.
	names:          Candidate_Table,
	ranked:         [line_editor.RANKED_CAPACITY]line_editor.Ranked,
	ranked_count:   int,
	matched_count:  int, // All the names that matched, kept in ranked or not.
	chosen:         int, // In ranked.
	first_shown:    int, // The first row of ranked that the terminal shows.
	search:         [SEARCH_CAPACITY]u8,
	search_count:   int,
	process_names:  [PROCESS_NAME_CAPACITY]system.Name, // The processes that run, for a list in quotes.
	process_count:  int,
	// The names of the processes are kept for one quote: where it starts,
	// and the count of the lines that ran when they were read.
	processes_kept:  bool,
	processes_quote: int,
	processes_lines: u32,
	// The measure of the cost of one key: the longest ranking so far, and
	// the count of rankings.
	longest_ranking: u64, // Nanoseconds.
	rankings:       u64,
	// What the terminal shows under the line now, to send only a change.
	hint_shown:      [2 * terminal.RUN_LIMIT]u8, // The long form, then the short form.
	hint_count:      int,
	hint_long_count: int,
	hint_marked:     [terminal.Hint_Form][2]int,
	// The enum of the members of an Enum argument that the list holds: the
	// file and the index of the enum, for the display text at the right of
	// each member. members_file nil: the members are those of a status
	// field, whose number is the word of their contract enum.
	members_file:    []u8,
	members_enum:    u32,
	// The description of the table of a stage `facts(...)`, whose fields
	// the list offers in a condition after it.
	description:     [DESCRIPTION_SIZE]u8,
}

completion: Completion

// The names that the lines of the history used, how often and how lately
// (src/md/features/fuzzy_match.md, "The frecency model"). The first thread
// counts each line that the history adds and reads it at each key; the
// load builds it from the kept lines, and history_clear empties it while a
// line runs, when no list is open.
completion_frecency: line_editor.Frecency

// A table of candidates in memory of the console: the list of the first
// thread has one, the measure of the second thread has its own.
Candidate_Table :: struct {
	items:   [CANDIDATE_CAPACITY]line_editor.Candidate,
	count:   int,
	dropped: int, // The names that had no room: the list cannot offer them.
}

// edit_key_of gives the key of the line editor of a key of the terminal.
edit_key_of :: proc "contextless" (pressed: Key) -> line_editor.Edit_Key {
	switch pressed.code {
	case display.KEY_LEFT:
		return .Left
	case display.KEY_RIGHT:
		return .Right
	case display.KEY_HOME:
		return .Home
	case display.KEY_END:
		return .End
	case display.KEY_BACKSPACE:
		return .Backspace
	case display.KEY_DELETE:
		return .Delete
	}
	return line_editor.printable(pressed.character) ? .Character : .None
}

// completion_key gives a key to the list that is open, and Control-R and
// Control-S to the search of the history. taken is false when the key is
// for the line.
completion_key :: proc "contextless" (pressed: Key) -> (taken: bool) {
	control := pressed.modifiers & display.MODIFIER_CONTROL != 0
	older := control && pressed.character == 'r'
	newer := control && pressed.character == 's'
	switch completion.mode {
	case .Closed:
		if older {
			history_search_open()
			return true
		}
		// No line is newer than the line that the input types.
		return newer
	case .Names:
		switch {
		case older || pressed.code == display.KEY_DOWN:
			list_move(1)
		case newer || pressed.code == display.KEY_UP:
			list_move(-1)
		case pressed.code == display.KEY_TAB:
			list_take()
		case pressed.code == display.KEY_ENTER:
			// A name that is already the name at the caret: Enter runs the line.
			return list_take()
		case pressed.code == display.KEY_ESCAPE:
			completion_close()
			completion.escaped = true
		case:
			return false
		}
		return true
	case .History:
		switch {
		case older || pressed.code == display.KEY_DOWN:
			list_move(1)
		case newer || pressed.code == display.KEY_UP:
			list_move(-1)
		case pressed.code == display.KEY_ENTER || pressed.code == display.KEY_TAB:
			history_take()
		case pressed.code == display.KEY_ESCAPE:
			// The line that the input typed stays as it was.
			completion_close()
		case pressed.code == display.KEY_BACKSPACE:
			// The search is UTF-8: Backspace removes its last whole
			// character.
			if completion.search_count > 0 {
				completion.search_count = text_encoding.complete_characters(completion.search[:completion.search_count - 1])
				history_rank()
			}
		case control:
		case line_editor.printable(pressed.character):
			length := line_editor.character_length(pressed.character)
			if completion.search_count + length <= SEARCH_CAPACITY {
				text_encoding.character_encode(pressed.character, completion.search[completion.search_count:])
				completion.search_count += length
				history_rank()
			}
		}
		// A machine test takes the picture of the search after this line:
		// the list that the terminal shows then has the search and its choice.
		if completion.mode == .History {
			system.log_fact(.Info, History_Search_Chose{row = u64(completion.chosen + 1), rows = u64(completion.ranked_count), search = value_kinds.text_field(string(completion.search[:completion.search_count]), SEARCH_FIELD_BYTES)})
		}
		// While the search is open, each key is for the search.
		return true
	}
	return false
}

// completion_after_edit makes the list again after a key changed the line:
// a typed character opens it; a key that moves the caret changes a list
// that is open.
completion_after_edit :: proc "contextless" (edit_key: line_editor.Edit_Key) {
	if edit_key == .Character {
		completion.escaped = false
	}
	typed := edit_key == .Character || edit_key == .Backspace || edit_key == .Delete
	if completion.mode == .Names || typed && !completion.escaped {
		names_rank(false)
	}
}

// completion_tab: Tab with no list. One name: it goes in the line. More
// names: the list opens.
completion_tab :: proc "contextless" () {
	names_rank(true)
	if completion.mode != .Names {
		return
	}
	if completion.ranked_count == 1 {
		list_take()
		return
	}
	candidate := &completion.names.items[completion.ranked[0].candidate]
	// The count of the runs of code of the first row: a check reads the
	// colors of the list from the log, not from a pixel.
	buffer: [terminal.RUN_LIMIT]u8
	runs: [terminal.CODE_RUN_LIMIT]terminal.Code_Run
	_, _, run_count := candidate_row_runs(&buffer, candidate^, runs[:])
	system.log_fact(.Info, Completion_List_Opened{matched_names = u64(completion.matched_count), names = u64(completion.names.count), longest_ranking = value_kinds.Time_In_Microseconds(completion.longest_ranking / 1000), rankings = completion.rankings, code_runs = u64(run_count)}, completion.place.query, candidate.name)
}

completion_close :: proc "contextless" () {
	if completion.mode != .Closed {
		completion.list_changed = true
	}
	completion.mode = .Closed
	completion.ranked_count = 0
	completion.escaped = false
}

// list_move moves the choice; the rows shown follow it.
list_move :: proc "contextless" (step: int) {
	if completion.ranked_count == 0 {
		return
	}
	completion.chosen = clamp(completion.chosen + step, 0, completion.ranked_count - 1)
	if completion.chosen < completion.first_shown {
		completion.first_shown = completion.chosen
	}
	if completion.chosen >= completion.first_shown + terminal.LIST_ROWS {
		completion.first_shown = completion.chosen - terminal.LIST_ROWS + 1
	}
	completion.list_changed = true
}

// completion_view_move moves the rows that the terminal shows to a first
// row that the pointer asked for on the scroll bar of the list
// (terminal.Input.List_First). The view of this list holds its choice: the
// choice goes to the nearest row of the new view. The number comes from
// the terminal: it is cut to the list of now, and a list that the
// terminal shows whole does not move.
completion_view_move :: proc "contextless" (first: int) {
	if completion.mode == .Closed || completion.ranked_count <= terminal.LIST_ROWS {
		return
	}
	first_shown := clamp(first, 0, completion.ranked_count - terminal.LIST_ROWS)
	if first_shown == completion.first_shown {
		return
	}
	completion.first_shown = first_shown
	completion.chosen = clamp(completion.chosen, first_shown, first_shown + terminal.LIST_ROWS - 1)
	completion.list_changed = true
}

// ---- The names.

candidate_add :: proc "contextless" (table: ^Candidate_Table, name: string, kind: line_editor.Candidate_Kind, number: int) {
	if name == "" {
		return
	}
	if table.count >= CANDIDATE_CAPACITY {
		table.dropped += 1
		return
	}
	table.items[table.count] = {name = name, kind = kind, number = u32(number), bonus = line_editor.frecency_bonus(&completion_frecency, name)}
	table.count += 1
}

command_kind :: proc "contextless" (item: ^Command) -> line_editor.Candidate_Kind {
	if item.run != nil {
		return .Command
	}
	return item.record != 0 ? .Record : .Export
}

// names_of_a_call fills a table of candidates when the caret is in an
// argument that a call reads as names (Parameter_Form): the fact names
// inside `facts(`, the type names of a package after its dot, the fields
// of the record on the left inside `where(`, and the members of a status
// after the operator of its condition. It gives false for another place.
// The first thread calls it, with the edit line that it owns.
names_of_a_call :: proc "contextless" (table: ^Candidate_Table, place: line_editor.Completion_Context, text: string, caret: int) -> bool {
	table.count, table.dropped = 0, 0
	name, argument, found := line_editor.call_at_caret(text, caret)
	if !found {
		return false
	}
	item := command_find(name)
	if item == nil || item.run == nil {
		return false
	}
	// With "|>" before the call, the value on the left is its first
	// argument, so the argument at the caret is the next parameter.
	call_start := int(uintptr(raw_data(name)) - uintptr(raw_data(text)))
	piped := console_language.pipe_before(text, call_start)
	parameter := argument + (piped ? 1 : 0)
	// Each name after the first of a list of field names is the same
	// parameter.
	if item.parameter_count > 0 && parameter >= item.parameter_count && item.parameter_forms[item.parameter_count - 1] == .Field_Names {
		parameter = item.parameter_count - 1
	}
	if parameter >= item.parameter_count {
		return false
	}
	switch item.parameter_forms[parameter] {
	case .Expression:
		return false
	case .Fact_Name:
		switch place.place {
		case .Name:
			for known, index in fact_names[:fact_name_count] {
				candidate_add(table, known, .Fact_Type, index)
			}
			return true
		case .Member:
			for known, index in fact_names[:fact_name_count] {
				known_package, type_name, _ := fact_name_split(known)
				if known_package == place.owner {
					candidate_add(table, type_name, .Fact_Type, index)
				}
			}
			return true
		case .None, .Quoted:
		}
		return false
	case .Field_Names:
		// Inside columns( after a "|>": the fields of the record on the
		// left, for each name of the list.
		if place.place != .Name || !piped {
			return false
		}
		file, detail, known := pipe_left_record_at(text, call_start)
		if !known {
			return false
		}
		described, described_ok := module.record_type(file, detail)
		if !described_ok {
			return false
		}
		for number in 0 ..< described.field_count {
			field_item, field_ok := module.field(file, described, number)
			if field_ok {
				candidate_add(table, module.string_at(file, field_item.name_offset, field_item.name_count), .Field, int(number))
			}
		}
		return true
	case .Condition:
		if place.place != .Name || !piped {
			// The record of a table that the line names in the call is
			// known when it runs: the completion offers no field there.
			return false
		}
		file, detail, known := pipe_left_record_at(text, call_start)
		if !known {
			return false
		}
		described, described_ok := module.record_type(file, detail)
		if !described_ok {
			return false
		}
		// After the operator: the members of a status field.
		before := completion_token_before(text, place.word_start)
		if before.kind == .Operator && (text[before.start] == '=' || text[before.start] == '<' || text[before.start] == '>') {
			field_token := before
			for field_token.kind == .Operator && field_token.start > 0 {
				field_token = completion_token_before(text, field_token.start)
			}
			if field_token.kind != .Name {
				return true
			}
			field_name := text[field_token.start:field_token.end]
			for number in 0 ..< described.field_count {
				field_item, field_ok := module.field(file, described, number)
				if !field_ok || module.string_at(file, field_item.name_offset, field_item.name_count) != field_name {
					continue
				}
				which, which_ok := module.field_contract_enum(field_item)
				if kind, _ := module.field_kind(field_item); kind != .Status || !which_ok {
					return true
				}
				for word in 0 ..< module.contract_enum_member_count(which) {
					if member, named := module.contract_enum_member_name(which, word); named {
						candidate_add(table, member, .Member, int(which))
					}
				}
			}
			return true
		}
		// Before the operator: the fields. The number of a field is its
		// place in the record, for what the list says of it.
		for number in 0 ..< described.field_count {
			field_item, field_ok := module.field(file, described, number)
			if field_ok {
				candidate_add(table, module.string_at(file, field_item.name_offset, field_item.name_count), .Field, int(number))
			}
		}
		return true
	}
	return false
}

// The groups open at the caret come from the scanner of the line
// (console_language.groups_at), so a '(' in a text or in a comment opens
// nothing.
GROUP_DEPTH_MOST :: console_language.GROUP_DEPTH_MOST
Open_Group :: console_language.Open_Group
groups_at :: console_language.groups_at

// name_before gives the name that ends before a byte place, after its
// spaces: the name of a call before its '('.
name_before :: proc "contextless" (text: string, place: int) -> (name: string, start: int) {
	end := clamp(place, 0, len(text))
	for end > 0 && text[end - 1] == ' ' {
		end -= 1
	}
	start = end
	for start > 0 && (console_language.name_first(text[start - 1]) || console_language.digit(text[start - 1]) || text[start - 1] == '.') {
		start -= 1
	}
	return text[start:end], start
}

// argument_starts says if the word at word_start starts an argument or a
// field: the token before it opens the group or is one of its ','.
argument_starts :: proc "contextless" (text: string, word_start: int) -> bool {
	before := completion_token_before(text, word_start)
	return before.kind == .Operator && (text[before.start] == '(' || text[before.start] == '{' || text[before.start] == ',')
}

// names_of_a_record_literal fills a table of candidates with the fields of
// the record that a literal takes, when the caret is at the name of a field
// inside its braces: the literal is an argument of an export whose
// parameter is that record, by its place or by its name. It gives false for
// another place.
names_of_a_record_literal :: proc "contextless" (table: ^Candidate_Table, place: line_editor.Completion_Context, text: string) -> bool {
	if place.place != .Name || !argument_starts(text, place.word_start) {
		return false
	}
	groups: [GROUP_DEPTH_MOST]Open_Group
	depth, found := groups_at(text, place.word_start, &groups)
	if !found || depth < 2 || groups[depth - 1].opener != .Brace || groups[depth - 2].opener != .Parenthesis {
		return false
	}
	literal, call := groups[depth - 1], groups[depth - 2]
	name, name_start := name_before(text, call.start)
	item := command_find(name)
	if item == nil || item.run != nil || item.record != 0 {
		return false
	}
	// The parameter: by the name before "= {", or by the place of the
	// argument, after the value on the left of a "|>".
	parameter := call.commas + (console_language.pipe_before(text, name_start) ? 1 : 0)
	equal := completion_token_before(text, literal.start)
	if equal.kind == .Operator && text[equal.start] == '=' {
		argument_name, _ := name_before(text, equal.start)
		parameter = -1
		for parameter_name, index in item.parameter_names[:clamp(item.parameter_count, 0, ARGUMENT_CAPACITY)] {
			if parameter_name != "" && parameter_name == argument_name {
				parameter = index
			}
		}
	}
	if parameter < 0 || parameter >= item.parameter_count || item.parameters[parameter] != .Record {
		return false
	}
	table.count, table.dropped = 0, 0
	file, detail := item.file, item.function.parameter_details[parameter]
	described, described_ok := module.record_type(file, detail)
	if !described_ok {
		return false
	}
	for number in 0 ..< described.field_count {
		field_item, field_ok := module.field(file, described, number)
		if field_ok {
			candidate_add(table, module.string_at(file, field_item.name_offset, field_item.name_count), .Field, int(number))
		}
	}
	return true
}

// parameter_names_add adds the names of the parameters of a call to a
// table of candidates, when the word at the caret starts an argument of the
// call, and the call has names: a named argument `name = value`.
parameter_names_add :: proc "contextless" (table: ^Candidate_Table, place: line_editor.Completion_Context, text: string) {
	if place.place != .Name || !argument_starts(text, place.word_start) {
		return
	}
	groups: [GROUP_DEPTH_MOST]Open_Group
	depth, found := groups_at(text, place.word_start, &groups)
	if !found || depth == 0 || groups[depth - 1].opener != .Parenthesis {
		return
	}
	name, _ := name_before(text, groups[depth - 1].start)
	item := command_find(name)
	if item == nil {
		return
	}
	for parameter_name, index in item.parameter_names[:clamp(item.parameter_count, 0, ARGUMENT_CAPACITY)] {
		if item.parameter_forms[index] == .Expression {
			candidate_add(table, parameter_name, .Field, index)
		}
	}
}

// The parameters of the functions around the caret, copied out of the line,
// which changes under the list: 16 at most, of 32 bytes at most.
BINDING_CAPACITY :: 16
BINDING_NAME_SIZE :: 32
binding_names: [BINDING_CAPACITY][BINDING_NAME_SIZE]u8

// bindings_add adds the parameters of each function whose body holds the
// word at the caret to a table of candidates.
bindings_add :: proc "contextless" (table: ^Candidate_Table, place: line_editor.Completion_Context, text: string) {
	if place.place != .Name {
		return
	}
	tokens: [BINDING_CAPACITY]console_language.Token
	count := console_language.parameters_at(text, place.word_start, tokens[:])
	for token, index in tokens[:count] {
		if token.end - token.start > BINDING_NAME_SIZE {
			continue
		}
		size := copy(binding_names[index][:], text[token.start:token.end])
		candidate_add(table, string(binding_names[index][:size]), .Binding, index)
	}
}

// completion_token_before gives the token that ends at or before a byte
// place: the last token of text[:place].
completion_token_before :: proc "contextless" (text: string, place: int) -> console_language.Token {
	last := console_language.Token{}
	for token := console_language.token_next(text, 0); token.kind != .None && token.end <= place; token = console_language.token_next(text, token.end) {
		last = token
	}
	return last
}

// pipe_left_record_at gives the record of the table on the left of the
// "|>" before the call that starts at call_start, when the console knows
// it before the run (pipe_left_record). The line is read up to that call,
// with a name of one byte in its place, as pipe_left_at reads it.
pipe_left_record_at :: proc "contextless" (text: string, call_start: int) -> (file: []u8, detail: u32, known: bool) {
	start := clamp(call_start, 0, len(text))
	line_to_name: [LINE_CAPACITY + 1]u8
	if start >= len(line_to_name) {
		return nil, 0, false
	}
	count := copy(line_to_name[:], text[:start])
	line_to_name[count] = '_'
	read := string(line_to_name[:count + 1])
	memory: [2 * (LINE_CAPACITY + 1)]u8
	form := console_language.pipe_nested_form(read, console_language.expression_start(read), memory[:], completion_line_stages[:])
	if form.refusal != .None {
		return nil, 0, false
	}
	stages := completion_line_stages[:form.stage_count]
	for index in 0 ..< form.stage_count {
		if stages[index].name_start == start {
			left, knowledge := pipe_left_value(read, stages, index)
			// The description of a table of facts() goes in the memory of
			// the list, not of a line: the names of the list are in it.
			return pipe_left_record(read, stages, index, left, knowledge, completion.description[:])
		}
	}
	return nil, 0, false
}

// names_collect fills a table of candidates for a place of the caret.
names_collect :: proc "contextless" (table: ^Candidate_Table, place: line_editor.Completion_Context) {
	table.count, table.dropped = 0, 0
	switch place.place {
	case .None:
	case .Name:
		for &item, index in commands[:command_count] {
			candidate_add(table, item.name, command_kind(&item), index)
		}
		// The name of the evaluation, which no command of the table has: its
		// number is past them.
		candidate_add(table, lex_evaluator.MAP_NAME, .Command, command_count)
		for &sandbox, index in sandboxes {
			if sandbox.service && !sandbox.quiet {
				candidate_add(table, sandbox.name, .Service, index)
			}
		}
		for &variable, index in variables {
			candidate_add(table, string(variable.name[:clamp(variable.name_count, 0, VARIABLE_NAME_SIZE)]), .Variable, index)
		}
		// The processes that the console started with a record output: the
		// owners of typed names.
		for &owner, index in stream_owners {
			if owner.process != 0 {
				candidate_add(table, owner.name, .Process, index)
			}
		}
	case .Member:
		// The exports of a service: the commands "owner.name".
		owner := place.owner
		for &item, index in commands[:command_count] {
			if len(item.name) > len(owner) + 1 && item.name[:len(owner)] == owner && item.name[len(owner)] == '.' {
				candidate_add(table, item.name[len(owner) + 1:], command_kind(&item), index)
			}
		}
		// The record outputs of a process that the console started or of a
		// service that it connected: the typed names "owner.output".
		if found, found_ok := stream_owner_find(owner, false); found_ok {
			for row in 1 ..= console_stream.record_output_count(found.file) {
				if value, _, _, ok := module.record_output(found.file, row); ok && value.record != 0 {
					candidate_add(table, module.string_at(found.file, value.name_offset, value.name_count), .Stream, int(row))
				}
			}
			for row in 1 ..= console_stream.record_input_count(found.file) {
				if value, _, _, _, ok := module.record_input(found.file, row); ok && value.record != 0 {
					candidate_add(table, module.string_at(found.file, value.name_offset, value.name_count), .Stream, int(row))
				}
			}
		}
	case .Quoted:
		switch place.owner {
		case "load", "isolate", "start", "replace":
			for &entry, index in system.image_entries(image) {
				candidate_add(table, system.name_of(entry.name[:]), .Module, index)
			}
		case "connect", "stop", "grants", "revoke":
			processes_collect(place.word_start)
			for &name, index in completion.process_names[:completion.process_count] {
				candidate_add(table, system.name_of(name[:]), .Process, index)
			}
		case "unload":
			for &item, index in loaded[:loaded_count] {
				candidate_add(table, item.name, .Module, index)
			}
		}
	}
}

// processes_collect reads the names of the processes that run, with the
// grant to inspect the machine that the console holds. With no grant, the
// list names the services that the console is connected to: the root
// service has no list of its services to give. It reads them once for the
// quote that starts at quote_place: the names stay until the caret leaves
// the quote or a line runs, so a key in the quote makes no kernel call.
processes_collect :: proc "contextless" (quote_place: int) {
	if completion.processes_kept && completion.processes_quote == quote_place && completion.processes_lines == work.started {
		return
	}
	completion.processes_kept, completion.processes_quote, completion.processes_lines = true, quote_place, work.started
	completion.process_count = 0
	report: op.System_Report
	if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report)); status != .Ok {
		for &sandbox in sandboxes {
			if sandbox.service && !sandbox.quiet && completion.process_count < PROCESS_NAME_CAPACITY {
				completion.process_names[completion.process_count] = {}
				copy(completion.process_names[completion.process_count][:], sandbox.name)
				completion.process_count += 1
			}
		}
		return
	}
	for slot in 1 ..< report.process_slots {
		if completion.process_count == PROCESS_NAME_CAPACITY {
			break
		}
		process: op.Process_Report
		if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process), slot, u64(uintptr(&process)), size_of(process)); status != .Ok {
			continue
		}
		if process.state == .None || process.state == .Stopped {
			continue
		}
		completion.process_names[completion.process_count] = process.name
		completion.process_count += 1
	}
}

// The names of the members with their ".", for the candidates at the start
// of an argument: a candidate keeps its name until the next list.
completion_member_names: [CANDIDATE_CAPACITY * (module.ENUM_MEMBER_NAME_CAPACITY + 1)]u8

// members_of_an_argument fills a table of candidates with the members of
// the enum of an Enum parameter of an export, when the caret is in a member
// of an argument of its call (`settings.set(font = .sp`), by the name of
// the argument or by its place; or, with Tab, at the start of such an
// argument, where each member comes with its ".". It gives the place of
// the completion, and false for another place.
members_of_an_argument :: proc "contextless" (table: ^Candidate_Table, text: string, caret_asked: int, by_tab: bool) -> (place: line_editor.Completion_Context, is_member: bool) {
	caret := clamp(caret_asked, 0, len(text))
	start, end := caret, caret
	for start > 0 && line_editor.name_character(text[start - 1]) {
		start -= 1
	}
	for end < len(text) && line_editor.name_character(text[end]) {
		end += 1
	}
	has_dot := start > 0 && text[start - 1] == '.'
	// A "." after a name is a part of that name: owner.export.
	if has_dot && start > 1 && (line_editor.name_character(text[start - 2]) || text[start - 2] == '.') {
		return {}, false
	}
	if !has_dot && (start != caret || !by_tab) {
		return {}, false
	}
	argument_place := has_dot ? start - 1 : start
	before := completion_token_before(text, argument_place)
	if before.kind != .Operator || (text[before.start] != '(' && text[before.start] != ',' && text[before.start] != '=') {
		return {}, false
	}
	groups: [GROUP_DEPTH_MOST]Open_Group
	depth, found := groups_at(text, argument_place, &groups)
	if !found || depth == 0 || groups[depth - 1].opener != .Parenthesis {
		return {}, false
	}
	name, name_start := name_before(text, groups[depth - 1].start)
	item := command_find(name)
	if item == nil || item.run != nil || item.record != 0 {
		return {}, false
	}
	parameter := groups[depth - 1].commas + (console_language.pipe_before(text, name_start) ? 1 : 0)
	if text[before.start] == '=' {
		argument_name, _ := name_before(text, before.start)
		parameter = -1
		for parameter_name, index in item.parameter_names[:clamp(item.parameter_count, 0, ARGUMENT_CAPACITY)] {
			if parameter_name != "" && parameter_name == argument_name {
				parameter = index
			}
		}
	}
	if parameter < 0 || parameter >= item.parameter_count || item.parameters[parameter] != .Enum {
		return {}, false
	}
	enum_index, _ := module.enum_detail_of(item.function.parameter_details[parameter])
	described, problem := module.enum_type(item.file, enum_index)
	if problem != .None {
		return {}, false
	}
	table.count, table.dropped = 0, 0
	if table == &completion.names {
		completion.members_file, completion.members_enum = item.file, enum_index
	}
	used := 0
	for number in 0 ..< described.member_count {
		member, _ := module.enum_member(item.file, described, number)
		member_name := module.string_at(item.file, member.name_offset, member.name_count)
		if has_dot {
			candidate_add(table, member_name, .Member, int(number))
			continue
		}
		if used + 1 + len(member_name) > len(completion_member_names) {
			table.dropped += 1
			continue
		}
		completion_member_names[used] = '.'
		copy(completion_member_names[used + 1:], member_name)
		candidate_add(table, string(completion_member_names[used:][:1 + len(member_name)]), .Member, int(number))
		used += 1 + len(member_name)
	}
	place = {place = .Name, query = text[start:caret], word_start = start, replace_start = start, replace_end = end}
	return place, true
}

// names_rank makes the list of the names for the place of the caret.
// by_tab: the input asked with Tab: an empty name lists all the names, and
// a name that is already whole stays in the list.
names_rank :: proc "contextless" (by_tab: bool) {
	text := line_editor.line_text(&line)
	// A comment is words for a reader: the completion offers nothing in
	// it, so a key there stays a key of the comment, Enter too.
	if console_language.in_comment(text, line.caret) {
		completion_close()
		return
	}
	place := line_editor.completion_context(text, line.caret, by_tab)
	opens := by_tab || place.place == .Member || place.place == .Quoted || place.place == .Name && len(place.query) > 0
	// A "." at an argument of an Enum parameter opens the list of its
	// members, before a letter of the name is typed.
	if line.caret > 0 && text[line.caret - 1] == '.' {
		opens = true
	}
	if !opens {
		completion_close()
		return
	}
	started := system.nanoseconds()
	if place.place != .Quoted {
		completion.processes_kept = false
	}
	// The members of the enum of an argument: after its ".", or at its
	// start with Tab. Another list holds no member of an Enum argument.
	completion.members_file, completion.members_enum = nil, 0
	if member_place, is_member := members_of_an_argument(&completion.names, text, line.caret, by_tab); is_member {
		place = member_place
		// At the start of an argument: the names of the parameters too,
		// for a named argument.
		parameter_names_add(&completion.names, place, text)
	} else if !names_of_a_record_literal(&completion.names, place, text) && !names_of_a_call(&completion.names, place, text, line.caret) {
		names_collect(&completion.names, place)
		// At the start of an argument of a call whose parameters have
		// names: those names too, for a named argument.
		parameter_names_add(&completion.names, place, text)
		// In the body of a function: its parameters.
		bindings_add(&completion.names, place, text)
		// A name with a dot whose owner is no service: the whole name is
		// the query, against all the names.
		if place.place == .Member && completion.names.count == 0 {
			place.place = .Name
			place.query = text[place.word_start:line.caret]
			place.replace_start = place.word_start
			names_collect(&completion.names, place)
		}
		if place.place == .Name || place.place == .Member {
			pipe_completion_filter(&completion.names, text, place.word_start)
		}
	}
	completion.ranked_count, completion.matched_count = line_editor.rank_candidates(place.query, completion.names.items[:completion.names.count], completion.ranked[:])
	ranking_measured(started)
	completion.place = place
	only_name_is_typed := completion.ranked_count == 1 && completion.names.items[completion.ranked[0].candidate].name == place.query
	if completion.ranked_count == 0 || only_name_is_typed && !by_tab {
		completion_close()
		return
	}
	completion.mode = .Names
	completion.escaped = false
	completion.chosen, completion.first_shown = 0, 0
	completion.list_changed = true
}

// The stages of the line that the input types, for the completion after a
// "|>": the stages of the line that runs are of the second thread.
completion_line_stages: [console_language.PIPE_STAGE_CAPACITY]console_language.Pipe_Stage

// pipe_completion_filter keeps, after a "|>", only the commands that can be
// its call: those that take an argument, and whose first parameter takes
// the value on the left when the console knows its kind before the run.
pipe_completion_filter :: proc "contextless" (table: ^Candidate_Table, text: string, word_start: int) {
	if !console_language.pipe_before(text, word_start) {
		return
	}
	left, knowledge := pipe_left_at(text, word_start)
	kept := 0
	for item in table.items[:table.count] {
		takes := false
		switch item.kind {
		case .Command, .Export, .Record:
			// map takes a list first, which no knowledge before the run
			// refuses.
			takes = int(item.number) < command_count && pipe_stage_takes(&commands[item.number], left, knowledge) || item.name == lex_evaluator.MAP_NAME
		case .Service, .Module, .Process, .Variable, .History_Line, .Fact_Type, .Field, .Member, .Stream, .Binding:
			// No call: "|>" refuses it.
		}
		if takes {
			table.items[kept] = item
			kept += 1
		}
	}
	table.count = kept
}

// pipe_left_at gives what the console knows of the value on the left of
// the "|>" before the name at word_start. The name that the input types
// does not change it: the line is read up to that "|>", with a name of one
// byte in the place of the typed one, so that the "|>" has its call.
pipe_left_at :: proc "contextless" (text: string, word_start: int) -> (value: Value, knowledge: Left_Knowledge) {
	start := clamp(word_start, 0, len(text))
	line_to_name: [LINE_CAPACITY + 1]u8
	if start >= len(line_to_name) {
		return {}, .None
	}
	count := copy(line_to_name[:], text[:start])
	line_to_name[count] = '_'
	read := string(line_to_name[:count + 1])
	memory: [2 * (LINE_CAPACITY + 1)]u8
	form := console_language.pipe_nested_form(read, console_language.expression_start(read), memory[:], completion_line_stages[:])
	if form.refusal != .None {
		return {}, .None
	}
	for index in 0 ..< form.stage_count {
		if completion_line_stages[index].name_start == start {
			return pipe_left_value(read, completion_line_stages[:form.stage_count], index)
		}
	}
	return {}, .None
}

ranking_measured :: proc "contextless" (started: u64) {
	took := system.nanoseconds() - started
	completion.longest_ranking = max(completion.longest_ranking, took)
	completion.rankings += 1
}

// callable_kind says if a name of this kind is called: a chosen one gets
// its '('.
callable_kind :: proc "contextless" (kind: line_editor.Candidate_Kind) -> bool {
	return kind == .Command || kind == .Export || kind == .Record
}

// list_take puts the chosen name in the line, in the place of the name at
// the caret, with a '(' after a command or a closing quote after a name
// in quotes. changed is false when the line stays the same: the name is
// already there.
list_take :: proc "contextless" () -> (changed: bool) {
	if completion.mode != .Names || completion.ranked_count == 0 {
		completion_close()
		return false
	}
	candidate := completion.names.items[completion.ranked[completion.chosen].candidate]
	place := completion.place
	completion_close()
	buffer: [line_editor.LINE_CAPACITY]u8
	writer := system.Writer {
		buffer = buffer[:],
	}
	system.write_part(&writer, candidate.name)
	if place.place == .Quoted && !place.quote_follows {
		system.write_part(&writer, "\"")
	}
	if place.place != .Quoted && callable_kind(candidate.kind) && !place.call_follows {
		system.write_part(&writer, "(")
	}
	text := line_editor.line_text(&line)
	start := clamp(place.replace_start, 0, len(text))
	end := clamp(place.replace_end, start, len(text))
	if system.written(&writer) == text[start:end] {
		return false
	}
	if !line_editor.line_replace(&line, start, end, system.written(&writer)) {
		return false
	}
	system.log_fact(.Info, Completion_Gave_Line{}, line_editor.line_text(&line))
	return true
}

// ---- The search of the history.

history_search_open :: proc "contextless" () {
	completion.mode = .History
	completion.search_count = 0
	history_rank()
}

history_rank :: proc "contextless" () {
	started := system.nanoseconds()
	completion.names.count = line_editor.history_candidates(&history, completion.names.items[:])
	completion.names.dropped = 0
	completion.ranked_count, completion.matched_count = line_editor.rank_candidates(string(completion.search[:completion.search_count]), completion.names.items[:completion.names.count], completion.ranked[:], skip_equal_names = true)
	ranking_measured(started)
	completion.chosen, completion.first_shown = 0, 0
	completion.list_changed = true
}

// history_take puts the chosen line of the history in the line; the input
// can change it, then Enter runs it.
history_take :: proc "contextless" () {
	if completion.ranked_count > 0 {
		line_editor.line_set(&line, completion.names.items[completion.ranked[completion.chosen].candidate].name)
		history_place = 0
		system.log_fact(.Info, History_Search_Gave_Line{}, line_editor.line_text(&line))
	}
	completion_close()
}

// ---- What the terminal shows.

// signature_write writes the parameters and the result of a command, after
// its name if with_name: "write(name: Text, data: Text) -> Integer". The
// parameter number marked (from 0) is between marked_start and marked_end.
signature_write :: proc "contextless" (writer: ^system.Writer, item: ^Command, marked: int, with_name: bool) -> (marked_start, marked_end: int) {
	if with_name {
		system.write_part(writer, item.name)
	}
	system.write_part(writer, "(")
	for kind, index in item.parameters[:clamp(item.parameter_count, 0, ARGUMENT_CAPACITY)] {
		if index > 0 {
			system.write_part(writer, ", ")
		}
		if index == marked {
			marked_start = writer.count
		}
		// A last parameter that a call may leave out is in brackets:
		// start(Text, [Table]). The site writes the same signature
		// (foundation.console_signature).
		optional := item.optional_last && index == item.parameter_count - 1
		if optional {
			system.write_part(writer, "[")
		}
		defer if optional {
			system.write_part(writer, "]")
		}
		if item.parameter_names[index] != "" {
			system.write_part(writer, item.parameter_names[index])
			system.write_part(writer, ": ")
		}
		switch {
		case item.parameter_forms[index] == .Fact_Name:
			system.write_part(writer, "Fact_Type") // A name of a fact type, which the console checks.
		case item.parameter_forms[index] == .Condition:
			system.write_part(writer, "Condition") // A field, an operator and a value: `block = 12`.
		case item.parameter_forms[index] == .Field_Names:
			system.write_part(writer, "Field...") // One name of a field or more: `slot, name`.
		case kind == .Stream || kind == .Record_Input:
			system.write_part(writer, kind_names[kind])
		case kind == .None:
			system.write_part(writer, "Value") // Any kind: the command checks it.
		case:
			system.write_parameter_type(writer, item.file, type_of_kind(kind), item.function.parameter_details[index], item.function.parameter_directions[index])
		}
		if index == marked {
			marked_end = writer.count
		}
	}
	system.write_part(writer, ")")
	if item.result != .None {
		system.write_part(writer, " -> ")
		system.write_type(writer, item.file, type_of_kind(item.result), item.function.result_detail)
	}
	return marked_start, marked_end
}

// owner_name gives the name of the module or of the service of an export.
owner_name :: proc "contextless" (item: ^Command) -> string {
	if item.sandbox >= 1 && item.sandbox <= SANDBOX_CAPACITY {
		return sandboxes[item.sandbox - 1].name
	}
	for &module_loaded in loaded[:loaded_count] {
		if raw_data(module_loaded.file) == raw_data(item.file) {
			return module_loaded.name
		}
	}
	return "a module"
}

// candidate_about writes what a name is: the text at the right of its row.
candidate_about :: proc "contextless" (writer: ^system.Writer, candidate: line_editor.Candidate) {
	switch candidate.kind {
	case .Command, .Export, .Record:
		if candidate.name == lex_evaluator.MAP_NAME && int(candidate.number) >= command_count {
			system.write_part(writer, "name of Lex (list, function) -> list")
			return
		}
		if int(candidate.number) >= command_count {
			return
		}
		item := &commands[candidate.number]
		switch candidate.kind {
		case .Command:
			system.write_part(writer, "command ")
		case .Record:
			system.write_part(writer, "record ")
		case .Export, .Service, .Module, .Process, .Variable, .History_Line, .Fact_Type, .Field, .Member, .Stream, .Binding:
			system.write_part(writer, "export of ")
			system.write_part(writer, owner_name(item))
			system.write_part(writer, " ")
		}
		signature_write(writer, item, -1, false)
	case .Service:
		system.write_part(writer, "service")
	case .Module:
		system.write_part(writer, "module")
	case .Process:
		system.write_part(writer, "process that runs")
	case .Variable:
		if int(candidate.number) < VARIABLE_CAPACITY {
			value := variables[candidate.number].value
			system.write_part(writer, "variable: ")
			if value.kind == .None {
				system.write_part(writer, "None")
			} else {
				system.write_type(writer, value.file, type_of_kind(value.kind), value.detail)
			}
		}
	case .History_Line:
		if candidate.number == 0 {
			system.write_part(writer, "the last line")
		} else {
			system.write_part(writer, u64(candidate.number) + 1)
			system.write_part(writer, " lines ago")
		}
	case .Fact_Type:
		system.write_part(writer, "fact type")
	case .Field:
		system.write_part(writer, "field")
	case .Member:
		// A member of an Enum argument: its display text, which the
		// principal reads, while the list inserts the name; a member with
		// no text, the name of its enum.
		if completion.members_file != nil {
			described, problem := module.enum_type(completion.members_file, completion.members_enum)
			if problem != .None {
				return
			}
			if text, found := module.member_text(completion.members_file, completion.members_enum, u32(candidate.number), principal_language_tags_fallback[:]); found {
				system.write_part(writer, text)
			} else {
				system.write_part(writer, "member of ")
				system.write_part(writer, module.enum_name(completion.members_file, described))
			}
			return
		}
		if which, named := value_kinds.contract_enum_of_word(u8(candidate.number)); named {
			system.write_part(writer, "member of ")
			system.write_part(writer, value_kinds.CONTRACT_ENUM_TYPES[which].name)
		}
	case .Stream:
		system.write_part(writer, "record stream: a typed name")
	case .Binding:
		system.write_part(writer, "parameter of a function of the line")
	}
}

// completion_show gives the terminal the list and the line under the edit
// line, when they changed. The caller holds output_lock.
completion_show :: proc "contextless" () {
	if completion.list_changed {
		completion.list_changed = false
		list_send()
	}
	long_buffer, short_buffer: [terminal.RUN_LIMIT]u8
	long := system.Writer {
		buffer = long_buffer[:],
	}
	short := system.Writer {
		buffer = short_buffer[:],
	}
	marked: [terminal.Hint_Form][2]int
	if !running {
		marked = hint_write(&long, &short)
	}
	both: [2 * terminal.RUN_LIMIT]u8
	both_count := copy(both[:], system.written(&long))
	both_count += copy(both[both_count:], system.written(&short))
	if string(both[:both_count]) == string(completion.hint_shown[:completion.hint_count]) && long.count == completion.hint_long_count && marked == completion.hint_marked {
		return
	}
	completion.hint_count = copy(completion.hint_shown[:], both[:both_count])
	completion.hint_long_count = long.count
	completion.hint_marked = marked
	terminal.hint(&output, {system.written(&long), marked[.Long][0], marked[.Long][1] - marked[.Long][0]}, {system.written(&short), marked[.Short][0], marked[.Short][1] - marked[.Short][0]}, {tone = u8(terminal.Tone.Dim)})
}

// The icon that the terminal draws before a name of the completion list,
// for each kind of candidate.
@(rodata)
list_icon_of_candidate := [line_editor.Candidate_Kind]terminal.List_Icon {
	.Command      = .Command,
	.Export       = .Export,
	.Record       = .Record,
	.Service      = .Service,
	.Module       = .Module,
	.Process      = .Process,
	.Variable     = .Variable,
	.History_Line = .History_Line,
	.Fact_Type    = .Record, // A fact type is a record type.
	.Field        = .None,
	.Member       = .None,
	.Stream       = .Variable, // A value of the line, as a variable is.
	.Binding      = .Variable, // A value of the line, as a variable is.
}

list_send :: proc "contextless" () {
	if completion.mode == .Closed || running {
		terminal.list_show(&output, 0, terminal.NO_CHOICE, 0, 0, 0)
		return
	}
	shown := min(completion.ranked_count - completion.first_shown, terminal.LIST_ROWS)
	for row in 0 ..< shown {
		item := completion.ranked[completion.first_shown + row]
		candidate := completion.names.items[item.candidate]
		buffer: [terminal.RUN_LIMIT]u8
		runs: [terminal.CODE_RUN_LIMIT]terminal.Code_Run
		text, name_length, run_count := candidate_row_runs(&buffer, candidate, runs[:])
		// The runs go first: the List_Row that follows takes them.
		terminal.code_runs_send(&output, .List_Row, row, runs[:run_count])
		terminal.list_row(&output, row, text[:name_length], text[name_length:], transmute([2]u64)item.places, list_icon_of_candidate[candidate.kind])
	}
	anchor := len(PROMPT)
	if completion.mode == .Names {
		anchor += completion.place.replace_start
	}
	terminal.list_show(&output, shown, u64(completion.chosen - completion.first_shown), completion.first_shown, completion.ranked_count, anchor)
}

// hint_write writes the line under the edit line, in its long form and in
// its short form: how to use the list that is open, or the signature of
// the call at the caret (one form: the terminal cuts it). It gives the
// part of each form to mark, as a first and an end byte.
hint_write :: proc "contextless" (long, short: ^system.Writer) -> (marked: [terminal.Hint_Form][2]int) {
	switch completion.mode {
	case .Names:
		system.write_part(long, u64(completion.matched_count))
		system.write_part(long, completion.matched_count == 1 ? string(" name matches") : string(" names match"))
		if completion.matched_count > completion.ranked_count {
			system.write_part(long, ", the best ")
			system.write_part(long, u64(completion.ranked_count))
			system.write_part(long, " in the list")
		}
		if completion.names.dropped > 0 {
			system.write_part(long, ", and more names than the list reads: type more characters")
		}
		system.write_part(long, ". Up, Down: choose. Tab, Enter: take. Escape: close")
		system.write_part(short, u64(completion.matched_count))
		system.write_part(short, completion.names.dropped > 0 ? string(" names and more. Tab: take. Esc: close") : string(" names. Tab: take. Esc: close"))
	case .History:
		system.write_part(long, "search the history: ")
		marked[.Long][0] = long.count
		system.write_part(long, string(completion.search[:completion.search_count]))
		marked[.Long][1] = long.count
		system.write_part(long, "  ")
		system.write_part(long, u64(completion.matched_count))
		system.write_part(long, " lines. Control-R: older, Control-S: newer, Enter: take, Escape: back to the line")
		system.write_part(short, "search: ")
		marked[.Short][0] = short.count
		system.write_part(short, string(completion.search[:completion.search_count]))
		marked[.Short][1] = short.count
		system.write_part(short, "  ")
		system.write_part(short, u64(completion.matched_count))
		system.write_part(short, " lines. ^R ^S Enter Esc")
	case .Closed:
		// In a comment, the call before it is no call at the caret.
		if console_language.in_comment(line_editor.line_text(&line), line.caret) {
			return {}
		}
		name, argument, found := line_editor.call_at_caret(line_editor.line_text(&line), line.caret)
		if !found {
			return {}
		}
		for &item in commands[:command_count] {
			if item.name == name && item.record == 0 {
				start, end := signature_write(long, &item, argument, true)
				marked[.Long] = {start, end}
				return marked
			}
		}
	}
	return marked
}
