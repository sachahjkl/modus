// Explicit UI/worker session state machine and docs/WRITING.md-compliant
// sentences for files (src/md/features/store_explorer.md).
package files_core

Sidebar_Mode :: enum u8 {
	Browse   = 0,
	Versions = 1,
}

Prompt_Mode :: enum u8 {
	None           = 0,
	Filter         = 1,
	New_Object     = 2,
	New_Tree       = 3,
	Confirm_Remove = 4,
}

// Closed set of user-facing problem states. Every sentence obeys docs/WRITING.md:
// no raw numeric codes, no forbidden words, sentence case, each fact stated once.
Problem_Kind :: enum u8 {
	None               = 0,
	No_Store           = 1,
	Store_Revoked      = 2,
	Store_Open_Refused = 3,
	Tree_Read_Refused  = 4,
	Object_Damaged     = 5,
	Object_Unreadable  = 6,
	Name_Refused       = 7,
	Entry_Exists       = 8,
	Write_Refused      = 9,
	Remove_Refused     = 10,
	Version_Unreadable = 11,
	Restore_Refused    = 12,
	Path_Too_Deep      = 13,
	Queue_Full         = 14,
	Read_Only          = 15,
	Edit_Open_Refused  = 16,
}

@(rodata)
PROBLEM_SENTENCES := [Problem_Kind]string {
	.None               = "",
	.No_Store           = "No store is granted to this window.",
	.Store_Revoked      = "The store connection ended. The view is read only.",
	.Store_Open_Refused = "The store cannot be opened with the grants of this window.",
	.Tree_Read_Refused  = "The tree entries cannot be read from the store.",
	.Object_Damaged     = "The object is damaged and cannot be read.",
	.Object_Unreadable  = "The object cannot be read from the store.",
	.Name_Refused       = "The name is empty, too long, or contains a disallowed character.",
	.Entry_Exists       = "An entry with that name already exists in this tree.",
	.Write_Refused      = "The store refused to create the entry.",
	.Remove_Refused     = "The store refused to delete the entry.",
	.Version_Unreadable = "This version cannot be read and cannot be restored.",
	.Restore_Refused    = "The store refused to restore this version.",
	.Path_Too_Deep      = "The tree path reached the navigation depth limit.",
	.Queue_Full         = "The storage worker is busy. Try again.",
	.Read_Only          = "The store is read only. Changes are refused.",
	.Edit_Open_Refused  = "The editor cannot open this object with the current grants or path.",
}

// Format property: STORAGE7 entry name maximum is 255 bytes, so prompts
// (Confirm_Remove, New_Object, New_Tree) never truncate a valid entry name.
PROMPT_INPUT_MAX :: ENTRY_NAME_MAX_BYTES

Session_State :: struct {
	mode:                Sidebar_Mode,
	prompt:              Prompt_Mode,
	prompt_buf:          [PROMPT_INPUT_MAX]u8,
	prompt_len:          int,
	inspector_mode:      Inspector_Mode,
	inspector_override:  bool, // True when the principal toggled Text/Hex manually.
	store_connected:     bool,
	read_only:           bool,
	busy:                bool,
	next_serial:         u64,
	last_applied_serial: u64,
	problem:             Problem_Kind,
	preview_generation:  i64,
}

session_init :: proc "contextless" (s: ^Session_State) {
	s^ = {}
	s.mode = .Browse
	s.prompt = .None
	s.inspector_mode = .Text
}

session_next_serial :: proc "contextless" (s: ^Session_State) -> u64 {
	s.next_serial += 1
	s.busy = true
	return s.next_serial
}

session_accept_serial :: proc "contextless" (s: ^Session_State, serial: u64) -> bool {
	if serial == 0 || serial < s.last_applied_serial {
		return false
	}
	s.last_applied_serial = serial
	if serial >= s.next_serial {
		s.busy = false
	}
	return true
}

session_mark_revoked :: proc "contextless" (s: ^Session_State) {
	s.store_connected = false
	s.read_only = true
	s.prompt = .None
	s.problem = .Store_Revoked
}

session_set_problem :: proc "contextless" (s: ^Session_State, kind: Problem_Kind) {
	s.problem = kind
}

session_clear_problem :: proc "contextless" (s: ^Session_State) {
	if s.problem == .Store_Revoked || s.problem == .No_Store {
		return
	}
	s.problem = .None
}

session_prompt_open :: proc "contextless" (s: ^Session_State, mode: Prompt_Mode, initial := "") {
	s.prompt = mode
	n := min(len(initial), PROMPT_INPUT_MAX)
	copy(s.prompt_buf[:n], initial[:n])
	s.prompt_len = n
}

session_prompt_close :: proc "contextless" (s: ^Session_State) {
	s.prompt = .None
	s.prompt_len = 0
}

// session_prompt_push_rune encodes a printable Unicode scalar value into UTF-8
// inside s.prompt_buf. Refuses C0/DEL control characters, surrogates, and overflow.
session_prompt_push_rune :: proc "contextless" (s: ^Session_State, ch: rune) -> bool {
	code := u32(ch)
	if code < 0x20 || code == 0x7F || (code >= 0xD800 && code <= 0xDFFF) || code > 0x10FFFF {
		return false
	}
	encoded: [4]u8
	width := 0
	switch {
	case code < 0x80:
		encoded[0] = u8(code)
		width = 1
	case code < 0x800:
		encoded[0] = u8(0xC0 | (code >> 6))
		encoded[1] = u8(0x80 | (code & 0x3F))
		width = 2
	case code < 0x10000:
		encoded[0] = u8(0xE0 | (code >> 12))
		encoded[1] = u8(0x80 | ((code >> 6) & 0x3F))
		encoded[2] = u8(0x80 | (code & 0x3F))
		width = 3
	case:
		encoded[0] = u8(0xF0 | (code >> 18))
		encoded[1] = u8(0x80 | ((code >> 12) & 0x3F))
		encoded[2] = u8(0x80 | ((code >> 6) & 0x3F))
		encoded[3] = u8(0x80 | (code & 0x3F))
		width = 4
	}
	if s.prompt_len + width > PROMPT_INPUT_MAX {
		return false
	}
	copy(s.prompt_buf[s.prompt_len:][:width], encoded[:width])
	s.prompt_len += width
	return true
}

// session_prompt_backspace removes one complete UTF-8 character from prompt_buf.
session_prompt_backspace :: proc "contextless" (s: ^Session_State) -> bool {
	if s.prompt_len <= 0 {
		return false
	}
	s.prompt_len -= 1
	for s.prompt_len > 0 && (s.prompt_buf[s.prompt_len] & 0xC0) == 0x80 {
		s.prompt_len -= 1
	}
	return true
}

session_prompt_text :: proc "contextless" (s: ^Session_State) -> string {
	return string(s.prompt_buf[:s.prompt_len])
}

session_toggle_inspector_mode :: proc "contextless" (s: ^Session_State) {
	s.inspector_mode = s.inspector_mode == .Text ? .Hex : .Text
	s.inspector_override = true
}

session_can_restore :: proc "contextless" (s: ^Session_State, snap: ^Explorer_Snapshot) -> bool {
	if s.mode != .Versions || !s.store_connected || s.read_only || snap == nil {
		return false
	}
	if snap.version_chosen < 0 || snap.version_chosen >= snap.version_count {
		return false
	}
	return !snap.versions[snap.version_chosen].current
}

// session_status_sentence builds the left status band message following docs/WRITING.md.
session_status_sentence :: proc "contextless" (s: ^Session_State, snap: ^Explorer_Snapshot, out: []u8) -> string {
	pos := 0
	switch s.prompt {
	case .Filter:
		append_text(out, &pos, "Filter: ")
		append_text(out, &pos, session_prompt_text(s))
		append_text(out, &pos, " (Enter applies, Esc clears)")
		return string(out[:pos])
	case .New_Object:
		append_text(out, &pos, "New object name: ")
		append_text(out, &pos, session_prompt_text(s))
		return string(out[:pos])
	case .New_Tree:
		append_text(out, &pos, "New tree name: ")
		append_text(out, &pos, session_prompt_text(s))
		return string(out[:pos])
	case .Confirm_Remove:
		append_text(out, &pos, "Delete \"")
		append_text(out, &pos, session_prompt_text(s))
		append_text(out, &pos, "\"? Enter deletes, Esc keeps.")
		return string(out[:pos])
	case .None:
	}

	if s.problem != .None {
		append_text(out, &pos, PROBLEM_SENTENCES[s.problem])
		return string(out[:pos])
	}
	if s.mode == .Versions && snap != nil && snap.preview_generation > 0 {
		num: [24]u8
		append_text(out, &pos, "Previewing version v")
		append_text(out, &pos, format_i64(snap.preview_generation, num[:]))
		append_text(out, &pos, ". Enter restores, Esc returns.")
		return string(out[:pos])
	}
	if s.busy {
		append_text(out, &pos, "Reading store.")
		return string(out[:pos])
	}
	return ""
}
