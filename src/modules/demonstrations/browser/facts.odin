package browser

import "modus:contract/value_kinds"

// The log facts of the browser (src/md/features/log_facts.md). An address
// has no small bound, so it is a text view, a last field. The counts come
// first, so each record has no padding.

// The bytes of the Text field of the cause of a window that stays fixed:
// the longest sentence of display.SIZE_LIMITS_PROBLEM_SENTENCES, and a zero
// byte.
STAYS_FIXED_CAUSE_FIELD_BYTES :: 64
// The bytes of the Text field of the kind of a page: the longest of
// PAGE_KIND_WORDS, and a zero byte.
PAGE_KIND_FIELD_BYTES :: 40

// The window is open, and shows its first page.
@(log_fact = "browser: ok, the window is ready, with {pages} pages built in")
Window_Ready :: struct {
	pages: u64,
}

// A page was parsed, styled, laid out and painted: the counts of its
// document, and its address.
@(log_fact = "browser: loaded {address}, {kind}: {nodes} nodes, {rules} style rules, {boxes} document boxes, {records} draw records, {bytes} bytes of HTML")
Page_Loaded :: struct {
	nodes:   u64,
	rules:   u64,
	boxes:   u64,
	records: u64,
	bytes:   u64,
	kind:    [40]u8,
	address: value_kinds.Text_View,
}

// A press on a link loaded its address.
@(log_fact = "browser: followed a link from {from} to {to}")
Link_Followed :: struct {
	from: value_kinds.Text_View,
	to:   value_kinds.Text_View,
}

// A form was sent: its fields, and the address that it loads.
@(log_fact = "browser: sent a form of {fields} fields to {to}")
Form_Sent :: struct {
	fields: u64,
	to:     value_kinds.Text_View,
}

// The address field held an address that the browser refuses.
@(log_fact = "browser: refused the address {address}: {problem}")
Address_Refused :: struct {
	problem: value_kinds.Text_View,
	address: value_kinds.Text_View,
}

// The window cannot be resized: the limits that this process gave were
// refused, or the command ring of the window was full.
@(log_fact = "browser: the window stays fixed: {cause}")
Window_Stays_Fixed :: struct {
	cause: [64]u8,
}

#assert(size_of(Window_Stays_Fixed) == STAYS_FIXED_CAUSE_FIELD_BYTES)
#assert(size_of(Page_Loaded) == 5 * 8 + PAGE_KIND_FIELD_BYTES + value_kinds.TEXT_VIEW_BYTES)
