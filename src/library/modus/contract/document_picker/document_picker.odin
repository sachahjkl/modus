// Pure freestanding document service picker with capability grant registry and
// strict drop-only drag-and-drop protocol
// (src/md/features/desktop_to_browser.md;
// docs/ARCHITECTURE.md, section U6).
//
// The tables of documents and grants are memory of the caller: the service
// sizes them from its budget, so a principal with thousands of documents is
// one larger table, never a constant of this package. A full table is the
// refusal Table_Full, a value.
//
// The picker reads the documents of one principal by pages: a cursor (the
// identifier after which the page starts) and a search text. A page holds
// what the screen shows; the next page starts after the last identifier of
// the page before, so a document added or removed between two pages moves
// no other document out of reach.
//
// Zero dynamic allocations, zero kernel operations, strict drop-only delivery.
package document_picker

import "modus:contract/enum_word"

MAX_DOC_NAME_BYTES :: 64

Document_Right :: enum u8 {
	Read  = 0,
	Write = 1,
}

Document_Rights :: bit_set[Document_Right; u8]

Picker_Refusal :: enum u8 {
	None             = 0,
	Nil_State        = 1,
	Invalid_Id       = 2,
	Invalid_Name     = 3,
	Empty_Rights     = 4,
	Not_Found        = 5,
	Table_Full       = 6,
	Duplicate_Doc    = 7,
	Drop_Not_Active  = 8,
	Self_Drop        = 9,
	Empty_Page       = 10, // A page with no room for one document.
	Invalid_Query    = 11, // A search text longer than a name.
}

Document_Record :: struct {
	active:       bool,
	doc_id:       u64,
	principal_id: u64,
	name:         [MAX_DOC_NAME_BYTES]u8,
	name_len:     u8,
}

Document_Grant :: struct {
	active:       bool,
	grant_id:     u64,
	doc_id:       u64,
	process_slot: u32,
	rights:       Document_Rights,
}

// The service holds its tables in memory that the caller gives
// (document_service_init); their lengths are their capacities.
Document_Service :: struct {
	documents:     []Document_Record,
	grants:        []Document_Grant,
	next_doc_id:   u64,
	next_grant_id: u64,
}

// One page of the documents of a principal, in the order of their
// identifiers. next_cursor is the cursor of the page after it; more is
// false when no matching document follows the page.
Document_Page :: struct {
	count:       int,
	next_cursor: u64,
	more:        bool,
}

// document_service_init binds the tables of the service to memory of the
// caller and empties them. The service refuses each document and each grant
// with Table_Full when its table has no free row.
document_service_init :: proc "contextless" (s: ^Document_Service, documents: []Document_Record, grants: []Document_Grant) {
	if s == nil {
		return
	}
	for &record in documents {
		record = {}
	}
	for &grant in grants {
		grant = {}
	}
	s^ = {documents = documents, grants = grants, next_doc_id = 1, next_grant_id = 1}
}

document_register :: proc "contextless" (s: ^Document_Service, principal_id: u64, name: string) -> (doc_id: u64, refusal: Picker_Refusal) {
	if s == nil {
		return 0, .Nil_State
	}
	if len(name) == 0 || len(name) > MAX_DOC_NAME_BYTES {
		return 0, .Invalid_Name
	}
	nbytes := transmute([]u8)name
	free_idx := -1
	for &d, i in s.documents {
		if !d.active {
			if free_idx < 0 {
				free_idx = i
			}
			continue
		}
		if d.principal_id == principal_id && int(d.name_len) == len(nbytes) {
			same := true
			for k in 0 ..< len(nbytes) {
				if d.name[k] != nbytes[k] {
					same = false
					break
				}
			}
			if same {
				return 0, .Duplicate_Doc
			}
		}
	}
	if free_idx < 0 {
		return 0, .Table_Full
	}
	id := s.next_doc_id
	s.next_doc_id += 1
	rec := &s.documents[free_idx]
	rec^ = {active = true, doc_id = id, principal_id = principal_id, name_len = u8(len(nbytes))}
	copy(rec.name[:], nbytes)
	return id, .None
}

// ascii_lower gives the lower case of an ASCII letter, and each other byte as it is.
@(private = "file")
ascii_lower :: proc "contextless" (value: u8) -> u8 {
	if value >= 'A' && value <= 'Z' {
		return value + ('a' - 'A')
	}
	return value
}

// name_matches says if a name holds the search text, with the case of ASCII
// folded. An empty search text matches each name.
@(private = "file")
name_matches :: proc "contextless" (name: []u8, query: []u8) -> bool {
	if len(query) == 0 {
		return true
	}
	if len(query) > len(name) {
		return false
	}
	for start in 0 ..= len(name) - len(query) {
		found := true
		for index in 0 ..< len(query) {
			if ascii_lower(name[start + index]) != ascii_lower(query[index]) {
				found = false
				break
			}
		}
		if found {
			return true
		}
	}
	return false
}

// document_page writes into out the documents of one principal whose
// identifier is past cursor and whose name holds query, in the order of
// their identifiers, as many as out holds. A cursor of 0 starts at the first
// document; the cursor of the next page is next_cursor. The work is one pass
// over the table for each document of the page, and one more for `more`:
// a page of k documents in a table of n rows reads k + 1 times n rows.
document_page :: proc "contextless" (s: ^Document_Service, principal_id: u64, cursor: u64, query: string, out: []Document_Record) -> (page: Document_Page, refusal: Picker_Refusal) {
	if s == nil {
		return {}, .Nil_State
	}
	if len(out) == 0 {
		return {}, .Empty_Page
	}
	if len(query) > MAX_DOC_NAME_BYTES {
		return {}, .Invalid_Query
	}
	query_bytes := transmute([]u8)query
	// Each step takes the smallest identifier past the last one taken: the
	// table is in the order of its free rows, not of the identifiers.
	last := cursor
	for page.count < len(out) {
		next: ^Document_Record
		for &d in s.documents {
			if !d.active || d.principal_id != principal_id || d.doc_id <= last {
				continue
			}
			if !name_matches(d.name[:d.name_len], query_bytes) {
				continue
			}
			if next == nil || d.doc_id < next.doc_id {
				next = &d
			}
		}
		if next == nil {
			page.next_cursor = last
			return page, .None
		}
		out[page.count] = next^
		page.count += 1
		last = next.doc_id
	}
	page.next_cursor = last
	for &d in s.documents {
		if d.active && d.principal_id == principal_id && d.doc_id > last && name_matches(d.name[:d.name_len], query_bytes) {
			page.more = true
			break
		}
	}
	return page, .None
}

// document_remove ends a document and each grant on it.
document_remove :: proc "contextless" (s: ^Document_Service, doc_id: u64) -> Picker_Refusal {
	if s == nil {
		return .Nil_State
	}
	if doc_id == 0 {
		return .Invalid_Id
	}
	found := false
	for &d in s.documents {
		if d.active && d.doc_id == doc_id {
			d = {}
			found = true
		}
	}
	if !found {
		return .Not_Found
	}
	for &g in s.grants {
		if g.active && g.doc_id == doc_id {
			g = {}
		}
	}
	return .None
}

// document_grant_on_pick mints a capability grant ONLY after explicit principal pick.
document_grant_on_pick :: proc "contextless" (s: ^Document_Service, doc_id: u64, process_slot: u32, rights: Document_Rights) -> (grant_id: u64, refusal: Picker_Refusal) {
	if s == nil {
		return 0, .Nil_State
	}
	if doc_id == 0 || process_slot == 0 {
		return 0, .Invalid_Id
	}
	if rights == {} {
		return 0, .Empty_Rights
	}
	doc_exists := false
	for &d in s.documents {
		if d.active && d.doc_id == doc_id {
			doc_exists = true
			break
		}
	}
	if !doc_exists {
		return 0, .Not_Found
	}
	free_idx := -1
	for &g, i in s.grants {
		if !g.active {
			free_idx = i
			break
		}
	}
	if free_idx < 0 {
		return 0, .Table_Full
	}
	gid := s.next_grant_id
	s.next_grant_id += 1
	s.grants[free_idx] = {
		active       = true,
		grant_id     = gid,
		doc_id       = doc_id,
		process_slot = process_slot,
		rights       = rights,
	}
	return gid, .None
}

document_grant_revoke :: proc "contextless" (s: ^Document_Service, grant_id: u64) -> Picker_Refusal {
	if s == nil {
		return .Nil_State
	}
	if grant_id == 0 {
		return .Invalid_Id
	}
	for &g in s.grants {
		if g.active && g.grant_id == grant_id {
			g = {}
			return .None
		}
	}
	return .Not_Found
}

document_process_has_grant :: proc "contextless" (s: ^Document_Service, doc_id: u64, process_slot: u32, needed: Document_Rights) -> bool {
	if s == nil || doc_id == 0 || process_slot == 0 || needed == {} {
		return false
	}
	for &g in s.grants {
		if g.active && g.doc_id == doc_id && g.process_slot == process_slot && needed <= g.rights {
			return true
		}
	}
	return false
}

// ============================================================================
// Drag-and-Drop Between Windows (strict drop-only capability delivery)
// ============================================================================

Drag_State :: enum u8 {
	Idle     = 0,
	Dragging = 1,
}

drag_state_of_word :: proc "contextless" (word: u64) -> (st: Drag_State, ok: bool) {
	return enum_word.member_of_word(Drag_State, word)
}

Drag_Session :: struct {
	state:           Drag_State,
	source_window:   u64,
	hovered_window:  u64,
	doc_id:          u64,
	offered_rights:  Document_Rights,
}

drag_begin :: proc "contextless" (d: ^Drag_Session, source_window: u64, doc_id: u64, rights: Document_Rights) -> Picker_Refusal {
	if d == nil {
		return .Nil_State
	}
	if source_window == 0 || doc_id == 0 {
		return .Invalid_Id
	}
	if rights == {} {
		return .Empty_Rights
	}
	d^ = {
		state          = .Dragging,
		source_window  = source_window,
		hovered_window = source_window,
		doc_id         = doc_id,
		offered_rights = rights,
	}
	return .None
}

// drag_hover updates only the visual hover target; NEVER mints a document grant!
drag_hover :: proc "contextless" (d: ^Drag_Session, target_window: u64) -> Picker_Refusal {
	if d == nil {
		return .Nil_State
	}
	if d.state != .Dragging {
		return .Drop_Not_Active
	}
	d.hovered_window = target_window
	return .None
}

drag_cancel :: proc "contextless" (d: ^Drag_Session) {
	if d == nil {
		return
	}
	d^ = {}
}

// drag_drop delivers the document grant to target_process ONLY on explicit drop.
drag_drop :: proc "contextless" (
	d: ^Drag_Session,
	service: ^Document_Service,
	target_window: u64,
	target_process_slot: u32,
) -> (grant_id: u64, refusal: Picker_Refusal) {
	if d == nil || service == nil {
		return 0, .Nil_State
	}
	if d.state != .Dragging {
		return 0, .Drop_Not_Active
	}
	if target_window == 0 || target_process_slot == 0 {
		return 0, .Invalid_Id
	}
	if target_window == d.source_window {
		drag_cancel(d)
		return 0, .Self_Drop
	}
	gid, ref := document_grant_on_pick(service, d.doc_id, target_process_slot, d.offered_rights)
	drag_cancel(d)
	return gid, ref
}
