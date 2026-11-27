// Live desktop code-mode state machine and step trace inspector for the
// assistant window (src/md/features/agent_code_mode.md and
// src/md/features/assistant.md).
//
// Builds a cached, filterable index of agent-loop steps and acts from
// conversation.Conversation only when talk.layout_serial or the active filter
// changes, keeping unchanged frames O(1) with zero heap allocation and zero
// main-thread I/O.
package assistant_window

import "internal:assistant/conversation"
import "internal:assistant/conversation_view"
import assistant_contract "modus:contract/assistant"
import "modus:contract/enum_word"
import "modus:graphics"
import "modus:interface"
import "modus:kind_icons"
import "modus:system"

// Active top-level view of the assistant window.
Assistant_View_Tab :: enum u8 {
	Conversation = 0, // Full scrollable conversation and typed results.
	Steps        = 1, // Interactive agent code-mode step list and trace inspector.
}

// Closed filter set for the code-mode step list.
Step_Filter :: enum u8 {
	All      = 0,
	Awaiting = 1, // Acts currently awaiting principal approval on the trusted display.
	Refused  = 2, // Acts refused by the bridge, refused by the principal, or not shown.
}

// High-level live loop state shown in the header badge.
Loop_Badge_State :: enum u8 {
	Idle               = 0,
	Queued             = 1, // Request kept, waiting for a host runner to take it.
	Running            = 2, // Active agent loop running steps.
	Awaiting_Principal = 3, // One or more acts wait for a decision on the trusted display.
	Stopping           = 4, // Principal asked to stop the running loop.
	Finished           = 5, // Newest request ended with a final reply.
	Attention          = 6, // Newest request ended on a limit, repeat, stop, or failure.
}

// Closed set of actions for the right-click context menu and Ctrl+K palette.
Assistant_Menu_Action :: enum u32 {
	None                 = 0,
	Show_Conversation    = 1,
	Show_Steps           = 2,
	Review_Next_Waiting  = 3,
	Fold_All_Results     = 4,
	Expand_All_Results   = 5,
	Filter_All_Steps     = 6,
	Filter_Waiting_Steps = 7,
	Filter_Refused_Steps = 8,
	Stop_Loop            = 9,
	Open_Palette         = 10,
}

// Computed: maximum visible rows formatted per frame for interface.list_of_rows,
// matching interface.LIST_MEASURE_CAPACITY so stack buffers stay bounded.
CODE_STEP_VISIBLE_CAPACITY :: interface.LIST_MEASURE_CAPACITY

// Plan value: maximum right-side status text bytes per visible step row.
CODE_STEP_RIGHT_TEXT_BYTES :: 40

// Plan value: maximum preview bytes copied per line in the step trace pane.
CODE_STEP_DETAIL_LINE_CAPACITY :: 16

// One indexed act row in the cached code-mode step snapshot.
Code_Step_Row :: struct {
	entry_index: u16,
	entry_num:   u64,
	act:         u64,
	serial:      u64,
	step:        u8,
	kind:        assistant_contract.Act_Kind,
	state:       assistant_contract.Act_State,
	has_table:   bool,
	table_rows:  u16,
	total_rows:  u16,
}

// Cached code-mode state owned by the assistant window.
Code_Mode_State :: struct {
	active_tab:     Assistant_View_Tab,
	filter:         Step_Filter,
	synced:         bool,
	layout_serial:  u64,
	synced_filter:  Step_Filter,

	rows:           [assistant_contract.CONVERSATION_ENTRY_CAPACITY]Code_Step_Row,
	row_count:      int,
	selected_row:   int,
	selected_act:   u64,
	first_row:      int,

	total_acts:     int,
	done_acts:      int,
	waiting_acts:   int,
	allowed_acts:   int,
	refused_acts:   int,
	active_step:    u8,
	newest_serial:  u64,
	badge_state:    Loop_Badge_State,
	end_cause:      assistant_contract.Agent_Loop_End,
	has_foldable:   bool,
}

@(rodata)
ASSISTANT_TAB_LABELS := [Assistant_View_Tab]string {
	.Conversation = "Conversation",
	.Steps        = "Code steps",
}

@(rodata)
STEP_FILTER_LABELS := [Step_Filter]string {
	.All      = "All",
	.Awaiting = "Waiting",
	.Refused  = "Refused",
}

@(rodata)
ACT_KIND_LABELS := [assistant_contract.Act_Kind]string {
	.Eval_Lex       = "Lex call",
	.Eval_Step      = "Lex step",
	.Read_Screen    = "Read screen",
	.Read_Log_Facts = "Log facts",
	.Send_Key       = "Send key",
	.Send_Pointer   = "Send pointer",
}

@(rodata)
STEP_STATE_SHORT := [assistant_contract.Act_State]string {
	.Proposed             = "proposed",
	.Done                 = "done",
	.Refused              = "refused",
	.Awaiting_Principal   = "waiting",
	.Allowed_By_Principal = "allowed",
	.Refused_By_Principal = "denied",
	.Not_Shown            = "not shown",
}

@(rodata)
STEP_BADGE_WORDS := [assistant_contract.Act_State]string {
	.Proposed             = "Proposed",
	.Done                 = "Done",
	.Refused              = "Refused",
	.Awaiting_Principal   = "Waiting",
	.Allowed_By_Principal = "Allowed",
	.Refused_By_Principal = "Refused",
	.Not_Shown            = "Not shown",
}

// code_mode_state_color gives the semantic accent color of an act state.
code_mode_state_color :: proc "contextless" (state: assistant_contract.Act_State) -> graphics.Color {
	switch state {
	case .Proposed, .Awaiting_Principal:
		return graphics.colors.warning
	case .Done, .Allowed_By_Principal:
		return graphics.colors.process
	case .Refused, .Refused_By_Principal, .Not_Shown:
		return graphics.colors.failed
	}
	return graphics.colors.dim
}

// code_mode_kind_icon gives the 12x12 kind icon representing an act kind.
code_mode_kind_icon :: proc "contextless" (kind: assistant_contract.Act_Kind) -> ^kind_icons.Cells {
	switch kind {
	case .Eval_Lex, .Eval_Step:
		return &kind_icons.value_kind_cells[.Command]
	case .Read_Screen:
		return &kind_icons.value_kind_cells[.Status]
	case .Read_Log_Facts:
		return &kind_icons.value_kind_cells[.File]
	case .Send_Key, .Send_Pointer:
		return &kind_icons.value_kind_cells[.Operation]
	}
	return &kind_icons.value_kind_cells[.Command]
}

// code_mode_filter_matches reports whether an act state belongs to filter.
code_mode_filter_matches :: proc "contextless" (filter: Step_Filter, state: assistant_contract.Act_State) -> bool {
	switch filter {
	case .All:
		return true
	case .Awaiting:
		return state == .Awaiting_Principal
	case .Refused:
		return state == .Refused || state == .Refused_By_Principal || state == .Not_Shown
	}
	return false
}

// code_mode_sync refreshes the cached step list and live loop counters only
// when conversation.layout_serial or cm.filter changed. Unchanged frames return
// immediately in O(1).
code_mode_sync :: proc "contextless" (cm: ^Code_Mode_State, conv: ^conversation.Conversation) {
	if cm == nil || conv == nil {
		return
	}
	if cm.synced && cm.layout_serial == conv.layout_serial && cm.synced_filter == cm.filter {
		return
	}
	cm.synced = true
	cm.layout_serial = conv.layout_serial
	cm.synced_filter = cm.filter

	cm.row_count = 0
	cm.total_acts = 0
	cm.done_acts = 0
	cm.waiting_acts = 0
	cm.allowed_acts = 0
	cm.refused_acts = 0
	cm.active_step = 0
	cm.newest_serial = conv.last_serial
	cm.end_cause = .Final_Reply
	cm.has_foldable = false

	newest_request: ^conversation.Entry
	has_untaken := false
	matched_selected := -1

	for index in 0 ..< conv.entry_count {
		entry := conversation.entry_at(conv, index)
		switch entry.kind {
		case .Request:
			if !entry.taken {
				has_untaken = true
			}
			if newest_request == nil || entry.serial >= newest_request.serial {
				newest_request = entry
			}
		case .Reply, .Reply_Refused, .Loop_End:
		case .Act:
			cm.total_acts += 1
			if conversation.act_folded_by_default(conv, entry) {
				cm.has_foldable = true
			}
			switch entry.state {
			case .Proposed:
			case .Done:
				cm.done_acts += 1
			case .Awaiting_Principal:
				cm.waiting_acts += 1
			case .Allowed_By_Principal:
				cm.allowed_acts += 1
			case .Refused, .Refused_By_Principal, .Not_Shown:
				cm.refused_acts += 1
			}
			if code_mode_filter_matches(cm.filter, entry.state) && cm.row_count < len(cm.rows) {
				tbl := entry.state == .Done ? conversation.act_table_of(conv, entry) : nil
				cm.rows[cm.row_count] = {
					entry_index = u16(index),
					entry_num   = entry.number,
					act         = entry.act,
					serial      = entry.serial,
					step        = entry.step,
					kind        = entry.act_kind,
					state       = entry.state,
					has_table   = tbl != nil,
					table_rows  = tbl != nil ? u16(tbl.row_count) : 0,
					total_rows  = tbl != nil ? u16(tbl.total_rows) : 0,
				}
				if cm.selected_act != 0 && entry.act == cm.selected_act {
					matched_selected = cm.row_count
				}
				cm.row_count += 1
			}
		}
	}

	// Derive live header badge state without duplicating individual row text.
	running := conversation.request_running(conv)
	switch {
	case cm.waiting_acts > 0:
		cm.badge_state = .Awaiting_Principal
		if running != nil {
			cm.active_step = running.step_count
		}
	case running != nil && running.stop_requested:
		cm.badge_state = .Stopping
		cm.active_step = running.step_count
	case running != nil:
		cm.badge_state = .Running
		cm.active_step = running.step_count
	case has_untaken:
		cm.badge_state = .Queued
	case newest_request != nil && newest_request.turn == .Ended:
		cm.active_step = newest_request.step_count
		cm.end_cause = newest_request.end_cause
		cm.badge_state = newest_request.end_cause == .Final_Reply ? .Finished : .Attention
	case:
		cm.badge_state = .Idle
	}

	// Preserve selection on the same act when rows shift; otherwise default to newest.
	if cm.row_count == 0 {
		cm.selected_row = -1
		cm.selected_act = 0
		cm.first_row = 0
	} else if matched_selected >= 0 {
		cm.selected_row = matched_selected
	} else {
		cm.selected_row = cm.row_count - 1
		cm.selected_act = cm.rows[cm.selected_row].act
	}
	if cm.first_row >= cm.row_count {
		cm.first_row = max(cm.row_count - 1, 0)
	}
}

// code_mode_set_tab switches the active view tab.
code_mode_set_tab :: proc "contextless" (cm: ^Code_Mode_State, tab: Assistant_View_Tab) -> bool {
	if cm == nil || cm.active_tab == tab {
		return false
	}
	cm.active_tab = tab
	return true
}

// code_mode_set_filter updates the active step filter and syncs immediately.
code_mode_set_filter :: proc "contextless" (cm: ^Code_Mode_State, conv: ^conversation.Conversation, filter: Step_Filter) {
	if cm == nil {
		return
	}
	cm.filter = filter
	cm.first_row = 0
	code_mode_sync(cm, conv)
}

// code_mode_select selects row index in the filtered step list and keeps it in view.
code_mode_select :: proc "contextless" (cm: ^Code_Mode_State, index, visible_rows: int) {
	if cm == nil || cm.row_count == 0 {
		return
	}
	clamped := clamp(index, 0, cm.row_count - 1)
	cm.selected_row = clamped
	cm.selected_act = cm.rows[clamped].act
	vis := max(visible_rows, 1)
	if cm.selected_row < cm.first_row {
		cm.first_row = cm.selected_row
	} else if cm.selected_row >= cm.first_row + vis {
		cm.first_row = cm.selected_row - vis + 1
	}
	max_first := max(cm.row_count - vis, 0)
	cm.first_row = clamp(cm.first_row, 0, max_first)
}

// code_mode_move_selection moves the selected row by delta.
code_mode_move_selection :: proc "contextless" (cm: ^Code_Mode_State, delta, visible_rows: int) {
	if cm == nil || cm.row_count == 0 {
		return
	}
	base := cm.selected_row >= 0 ? cm.selected_row : 0
	code_mode_select(cm, base + delta, visible_rows)
}

// code_mode_review_next_waiting opens the Code steps tab focused on the oldest
// act awaiting principal approval on the trusted display. Returns false when no
// act currently waits for the principal.
code_mode_review_next_waiting :: proc "contextless" (cm: ^Code_Mode_State, conv: ^conversation.Conversation, visible_rows: int) -> bool {
	if cm == nil || conv == nil {
		return false
	}
	code_mode_sync(cm, conv)
	if cm.waiting_acts == 0 {
		return false
	}
	cm.active_tab = .Steps
	if cm.filter == .Refused {
		cm.filter = .Awaiting
		code_mode_sync(cm, conv)
	}
	for i in 0 ..< cm.row_count {
		if cm.rows[i].state == .Awaiting_Principal {
			code_mode_select(cm, i, visible_rows)
			return true
		}
	}
	return false
}

// code_mode_selected_entry returns the live conversation.Entry for the selected
// step row, or nil when none is selected.
code_mode_selected_entry :: proc "contextless" (cm: ^Code_Mode_State, conv: ^conversation.Conversation) -> ^conversation.Entry {
	if cm == nil || conv == nil || cm.selected_row < 0 || cm.selected_row >= cm.row_count {
		return nil
	}
	row := cm.rows[cm.selected_row]
	if int(row.entry_index) >= conv.entry_count {
		return nil
	}
	entry := conversation.entry_at(conv, int(row.entry_index))
	if entry.kind != .Act || entry.act != row.act {
		return nil
	}
	return entry
}

// code_mode_fold_all sets all foldable older act results to folded or expanded.
code_mode_fold_all :: proc "contextless" (conv: ^conversation.Conversation, folded: bool) -> (changed: int) {
	if conv == nil {
		return 0
	}
	for index in 0 ..< conv.entry_count {
		entry := conversation.entry_at(conv, index)
		if !conversation.act_folded_by_default(conv, entry) {
			continue
		}
		want_toggled := !folded
		if entry.fold_toggled != want_toggled {
			entry.fold_toggled = want_toggled
			conversation.entry_touch(conv, entry)
			changed += 1
		}
	}
	return changed
}

// code_mode_scroll_to_entry moves view_scroll so entry_number appears at the
// top of the conversation view.
code_mode_scroll_to_entry :: proc "contextless" (scroll: ^conversation_view.Scroll, places: ^conversation_view.Places, view_height: int, entry_number: u64) -> bool {
	if scroll == nil || places == nil || entry_number == 0 {
		return false
	}
	for index in 0 ..< places.count {
		if places.numbers[index] == entry_number {
			conversation_view.scroll_set(scroll, places, view_height, places.tops[index])
			return true
		}
	}
	return false
}

// code_mode_badge_text formats the compact live header badge and its accent.
code_mode_badge_text :: proc "contextless" (cm: ^Code_Mode_State, buffer: []u8) -> (text: string, accent: graphics.Color) {
	if cm == nil {
		return "Ready", graphics.colors.dim
	}
	switch cm.badge_state {
	case .Idle:
		return "Ready", graphics.colors.dim
	case .Queued:
		return "Queued", graphics.colors.link
	case .Running:
		if cm.active_step > 0 {
			return system.format(buffer, "Step ", u64(cm.active_step), " of ", u64(assistant_contract.AGENT_LOOP_STEP_CAPACITY)), graphics.colors.process
		}
		return "Running", graphics.colors.process
	case .Awaiting_Principal:
		if cm.waiting_acts > 1 {
			return system.format(buffer, "Waiting (", u64(cm.waiting_acts), ")"), graphics.colors.warning
		}
		return "Waiting", graphics.colors.warning
	case .Stopping:
		return "Stopping", graphics.colors.warning
	case .Finished:
		return "Finished", graphics.colors.process
	case .Attention:
		switch cm.end_cause {
		case .Step_Limit:
			return "Step limit", graphics.colors.warning
		case .Repeated_Step:
			return "Repeated", graphics.colors.warning
		case .Stopped_By_Principal:
			return "Stopped", graphics.colors.warning
		case .Model_Failed, .Window_Failed, .Grant_Ended:
			return "Attention", graphics.colors.failed
		case .Final_Reply:
			return "Finished", graphics.colors.process
		}
	}
	return "Ready", graphics.colors.dim
}

// code_mode_row_right_text formats the dim right-hand metadata of a step row.
code_mode_row_right_text :: proc "contextless" (row: Code_Step_Row, buffer: []u8) -> string {
	if row.step > 0 {
		return system.format(buffer, "step ", u64(row.step), " | ", STEP_STATE_SHORT[row.state])
	}
	return system.format(buffer, "act ", row.act, " | ", STEP_STATE_SHORT[row.state])
}

// code_mode_review_guidance returns the screen text explaining the approval or
// outcome status of an act in the inspector, obeying docs/WRITING.md.
code_mode_review_guidance :: proc "contextless" (entry: ^conversation.Entry) -> string {
	if entry == nil {
		return ""
	}
	switch entry.state {
	case .Proposed:
		return "Waiting for the bridge answer."
	case .Done:
		return ""
	case .Refused:
		return ""
	case .Awaiting_Principal:
		if entry.dialog == 0 {
			return "Waiting for the trusted display dialog."
		}
		return "Decide this act in the trusted display dialog."
	case .Allowed_By_Principal:
		return "Allowed on the trusted display. Waiting for execution under a wide grant."
	case .Refused_By_Principal:
		return "Refused on the trusted display. Nothing ran."
	case .Not_Shown:
		return "The trusted display did not show this act dialog. Nothing ran."
	}
	return ""
}

// code_mode_build_context_menu fills items for the right-click context menu.
code_mode_build_context_menu :: proc "contextless" (cm: ^Code_Mode_State, running: bool, out: []interface.Context_Menu_Item) -> int {
	if cm == nil || len(out) < 8 {
		return 0
	}
	n := 0
	out[n] = {id = u32(Assistant_Menu_Action.Show_Conversation), label = "Conversation", shortcut = "Ctrl+1", disabled = cm.active_tab == .Conversation}
	n += 1
	out[n] = {id = u32(Assistant_Menu_Action.Show_Steps), label = "Code steps", shortcut = "Ctrl+2", disabled = cm.active_tab == .Steps}
	n += 1
	out[n] = {id = u32(Assistant_Menu_Action.Review_Next_Waiting), label = "Review waiting act", disabled = cm.waiting_acts == 0, separator_before = true}
	n += 1
	out[n] = {id = u32(Assistant_Menu_Action.Fold_All_Results), label = "Fold older results", disabled = !cm.has_foldable, separator_before = true}
	n += 1
	out[n] = {id = u32(Assistant_Menu_Action.Expand_All_Results), label = "Expand older results", disabled = !cm.has_foldable}
	n += 1
	out[n] = {id = u32(Assistant_Menu_Action.Stop_Loop), label = "Stop agent loop", shortcut = "Esc", danger = true, disabled = !running, separator_before = true}
	n += 1
	out[n] = {id = u32(Assistant_Menu_Action.Open_Palette), label = "Command palette", shortcut = "Ctrl+K", separator_before = true}
	n += 1
	return n
}

// code_mode_build_palette fills items for the Ctrl+K / Ctrl+Shift+P palette.
code_mode_build_palette :: proc "contextless" (cm: ^Code_Mode_State, running: bool, out: []interface.Command_Palette_Item) -> int {
	if cm == nil || len(out) < 9 {
		return 0
	}
	n := 0
	out[n] = {id = u32(Assistant_Menu_Action.Show_Conversation), label = "Show conversation", category = "View", shortcut = "Ctrl+1"}
	n += 1
	out[n] = {id = u32(Assistant_Menu_Action.Show_Steps), label = "Show code steps", category = "View", shortcut = "Ctrl+2"}
	n += 1
	out[n] = {id = u32(Assistant_Menu_Action.Review_Next_Waiting), label = "Review waiting act", category = "Approval", disabled = cm.waiting_acts == 0}
	n += 1
	out[n] = {id = u32(Assistant_Menu_Action.Filter_All_Steps), label = "Show all steps", category = "Filter"}
	n += 1
	out[n] = {id = u32(Assistant_Menu_Action.Filter_Waiting_Steps), label = "Filter waiting steps", category = "Filter"}
	n += 1
	out[n] = {id = u32(Assistant_Menu_Action.Filter_Refused_Steps), label = "Filter refused steps", category = "Filter"}
	n += 1
	out[n] = {id = u32(Assistant_Menu_Action.Fold_All_Results), label = "Fold older results", category = "Results", disabled = !cm.has_foldable}
	n += 1
	out[n] = {id = u32(Assistant_Menu_Action.Expand_All_Results), label = "Expand older results", category = "Results", disabled = !cm.has_foldable}
	n += 1
	out[n] = {id = u32(Assistant_Menu_Action.Stop_Loop), label = "Stop agent loop", category = "Agent", shortcut = "Esc", danger = true, disabled = !running}
	n += 1
	return n
}

// code_mode_action_of_word validates a menu or palette action word at the border.
code_mode_action_of_word :: proc "contextless" (word: u32) -> (action: Assistant_Menu_Action, ok: bool) {
	return enum_word.member_of_word(Assistant_Menu_Action, u64(word))
}

// code_mode_apply_action runs one validated action on the code-mode state and
// conversation. Returns true when an external stop or palette trigger is needed.
code_mode_apply_action :: proc "contextless" (
	cm: ^Code_Mode_State,
	conv: ^conversation.Conversation,
	action: Assistant_Menu_Action,
	visible_rows: int,
) -> (wants_stop: bool, wants_palette: bool) {
	if cm == nil || conv == nil {
		return false, false
	}
	switch action {
	case .None:
	case .Show_Conversation:
		code_mode_set_tab(cm, .Conversation)
	case .Show_Steps:
		code_mode_set_tab(cm, .Steps)
		code_mode_sync(cm, conv)
	case .Review_Next_Waiting:
		_ = code_mode_review_next_waiting(cm, conv, visible_rows)
	case .Fold_All_Results:
		_ = code_mode_fold_all(conv, true)
	case .Expand_All_Results:
		_ = code_mode_fold_all(conv, false)
	case .Filter_All_Steps:
		cm.active_tab = .Steps
		code_mode_set_filter(cm, conv, .All)
	case .Filter_Waiting_Steps:
		cm.active_tab = .Steps
		code_mode_set_filter(cm, conv, .Awaiting)
	case .Filter_Refused_Steps:
		cm.active_tab = .Steps
		code_mode_set_filter(cm, conv, .Refused)
	case .Stop_Loop:
		return true, false
	case .Open_Palette:
		return false, true
	}
	return false, false
}
