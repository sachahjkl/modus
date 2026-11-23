// Explicit UI/worker session state machine and docs/WRITING.md-compliant
// status sentences for db_browser (src/md/features/db_browser.md).
package db_browser_core

// Inline capacity: newest CoW versions displayed in the sidebar Versions list.
VERSION_LIST_CAPACITY :: 128

// Inline capacity: sanitized single-line diagnostic sentence shown in the status band.
DIAGNOSTIC_DETAIL_BYTES :: 192

Sidebar_Mode :: enum u8 {
	Tables   = 0,
	Versions = 1,
}

Focus_Area :: enum u8 {
	Editor  = 0,
	Grid    = 1,
	Sidebar = 2,
}

// Closed set of user-facing problem states. Every sentence obeys docs/WRITING.md:
// no raw SQLite numeric codes, no forbidden words, sentence case, and one clear fact.
Problem_Kind :: enum u8 {
	None                   = 0,
	No_Store               = 1,
	Store_Revoked          = 2,
	Store_Write_Refused    = 3,
	Database_Too_Large     = 4,
	Database_Damaged       = 5,
	Engine_Unavailable     = 6,
	Engine_Crashed         = 7,
	Engine_Timeout         = 8,
	Sql_Error              = 9,
	Out_Of_Budget          = 10,
	Read_Only              = 11,
	Queue_Full             = 12,
	Version_Unreadable     = 13,
	Store_Pick_Unavailable = 14,
	Selection_Too_Long     = 15,
	Editor_Full            = 16,
}

@(rodata)
PROBLEM_SENTENCES := [Problem_Kind]string {
	.None                   = "",
	.No_Store               = "No store is open. Changes stay in memory until this window closes.",
	.Store_Revoked          = "The store connection ended. The database is read only.",
	.Store_Write_Refused    = "The store refused to keep the database changes.",
	.Database_Too_Large     = "The database does not fit the memory budget of this window.",
	.Database_Damaged       = "The database file is damaged and cannot be opened.",
	.Engine_Unavailable     = "The SQLite engine is not available.",
	.Engine_Crashed         = "The SQLite engine stopped during the query. Try again.",
	.Engine_Timeout         = "The query passed the time limit and the engine stopped.",
	.Sql_Error              = "The SQL statement did not run.",
	.Out_Of_Budget          = "The query used all memory in the engine budget.",
	.Read_Only              = "The database is read only. Write statements are refused.",
	.Queue_Full             = "The database worker is busy. Try again.",
	.Version_Unreadable     = "This version cannot be read and cannot be restored.",
	.Store_Pick_Unavailable = "The store picker is not available for this window.",
	.Selection_Too_Long     = "The selection does not fit the copy buffer.",
	.Editor_Full            = "The SQL editor buffer is full.",
}

Version_Entry :: struct {
	generation: i64,
	date:       i64,
	bytes:      i64,
	current:    bool,
}

// Explicit session state owned by the UI thread. Every async worker result
// carries a monotonically increasing serial so stale replies are dropped.
Session_State :: struct {
	mode:                Sidebar_Mode,
	focus:               Focus_Area,
	store_connected:     bool,
	read_only:           bool,
	engine_ready:        bool,
	busy:                bool,
	next_serial:         u64,
	last_applied_serial: u64,
	problem:             Problem_Kind,
	detail:              [DIAGNOSTIC_DETAIL_BYTES]u8,
	detail_len:          int,
	error_offset:        i32, // -1 when no SQL error offset is active.
	preview_generation:  i64, // 0 when viewing live database.
	versions:            [VERSION_LIST_CAPACITY]Version_Entry,
	version_count:       int,
	version_chosen:      int,
}

session_init :: proc "contextless" (s: ^Session_State) {
	s^ = {}
	s.mode = .Tables
	s.focus = .Editor
	s.error_offset = -1
}

session_next_serial :: proc "contextless" (s: ^Session_State) -> u64 {
	s.next_serial += 1
	s.busy = true
	return s.next_serial
}

// session_accept_serial drops out-of-order stale worker responses.
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

// session_mark_revoked transitions cleanly to read-only when the store grant ends.
session_mark_revoked :: proc "contextless" (s: ^Session_State) {
	s.store_connected = false
	s.read_only = true
	session_set_problem(s, .Store_Revoked)
}

session_set_problem :: proc "contextless" (
	s: ^Session_State,
	kind: Problem_Kind,
	detail := "",
	error_offset: i32 = -1,
) {
	s.problem = kind
	s.error_offset = error_offset
	if len(detail) > 0 {
		s.detail_len = sanitize_single_line_text(transmute([]u8)detail, s.detail[:])
	} else {
		s.detail_len = 0
	}
}

session_clear_problem :: proc "contextless" (s: ^Session_State) {
	// Persistent store loss stays visible until a new store connects.
	if s.problem == .Store_Revoked || s.problem == .No_Store {
		s.detail_len = 0
		s.error_offset = -1
		return
	}
	s.problem = .None
	s.detail_len = 0
	s.error_offset = -1
}

session_enter_versions :: proc "contextless" (s: ^Session_State, entries: []Version_Entry) -> bool {
	if len(entries) == 0 {
		return false
	}
	count := min(len(entries), VERSION_LIST_CAPACITY)
	for i in 0 ..< count {
		s.versions[i] = entries[i]
	}
	s.version_count = count
	// Versions are stored oldest-first; select newest (current) by default.
	s.version_chosen = count - 1
	s.mode = .Versions
	s.preview_generation = s.versions[s.version_chosen].generation
	return true
}

session_exit_versions :: proc "contextless" (s: ^Session_State) {
	s.mode = .Tables
	s.preview_generation = 0
	if s.problem == .Version_Unreadable {
		s.problem = .None
		s.detail_len = 0
	}
}

session_choose_version :: proc "contextless" (s: ^Session_State, index: int) -> (generation: i64, ok: bool) {
	if s.mode != .Versions || s.version_count <= 0 {
		return 0, false
	}
	clamped := clamp(index, 0, s.version_count - 1)
	s.version_chosen = clamped
	s.preview_generation = s.versions[clamped].generation
	return s.preview_generation, true
}

session_can_restore_chosen :: proc "contextless" (s: ^Session_State) -> bool {
	if s.mode != .Versions || !s.store_connected || s.read_only {
		return false
	}
	if s.version_chosen < 0 || s.version_chosen >= s.version_count {
		return false
	}
	return !s.versions[s.version_chosen].current
}

// session_status_sentence returns the left status-band sentence following docs/WRITING.md.
session_status_sentence :: proc "contextless" (s: ^Session_State, out: []u8) -> string {
	if s.problem == .Sql_Error && s.detail_len > 0 {
		pos := 0
		append_text(out, &pos, "SQL statement did not run: ")
		append_text(out, &pos, string(s.detail[:s.detail_len]))
		return string(out[:pos])
	}
	if s.problem != .None {
		text := PROBLEM_SENTENCES[s.problem]
		n := copy(out, text)
		return string(out[:n])
	}
	if s.mode == .Versions && s.preview_generation > 0 {
		pos := 0
		num: [24]u8
		append_text(out, &pos, "Previewing version v")
		append_text(out, &pos, format_i64(s.preview_generation, num[:]))
		append_text(out, &pos, ". Press Enter to restore or Esc to return.")
		return string(out[:pos])
	}
	if s.busy {
		n := copy(out, "Running query.")
		return string(out[:n])
	}
	return ""
}
