package manual

import "modus:contract/value_kinds"
import "modus:support/system"

// The log facts of the manual (src/md/features/log_facts.md, "The
// migration"): each line, as a record of fields. Each fact
// template is the sentence that the line wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before.
//
// The target and the title of a link page have up to 256 bytes, and the
// label of a link has no bound but its page: more than the values of one
// record hold. The lines of a link and of a link page stay text.

// The overview of the modules of the boot image.
@(log_fact = "manual: overview: {modules} modules, {exports} exports, {imports} imports, {running_modules} modules that run in processes")
Overview_Shown :: struct {
	modules:         u64,
	exports:         u64,
	imports:         u64,
	running_modules: u64,
}

// The measures of the functions of information at the start: the time of
// one list of the modules and of their exports, and of one reverse
// question.
@(log_fact = "manual: information: {modules} modules and {exports} exports listed in {list_time}; who imports calendar: {importers} modules, in {question_time}; {problems} modules break a rule")
Information_Measured :: struct {
	modules:       u64,
	exports:       u64,
	list_time:     value_kinds.Time_In_Microseconds,
	importers:     u64,
	question_time: value_kinds.Time_In_Microseconds,
	problems:      u64,
}

// The list of the modules has no room for each module of the boot image.
@(log_fact = "manual: the list shows {shown} of the {modules} modules of the boot image")
List_Cut :: struct {
	shown:   u64,
	modules: u64,
}

// The window shows the page of a module.
@(log_fact = "manual: {module_name}: {entry_words}, {exports} exports, {rows} rows")
Module_Page_Shown :: struct {
	exports:     u64,
	rows:        u64,
	entry_words: [24]u8,
	module_name: value_kinds.Module_Name_Field,
}

// The window is open: the modules of the boot image, and those with their
// documentation.
@(log_fact = "manual: ok, {modules} modules, {documented} have their documentation")
Window_Ready :: struct {
	modules:    u64,
	documented: u64,
}

// The link pages break a rule of their format, by its number: they are not
// read.
@(log_fact = "manual: the link pages break the rule {rule} of their format: not read")
Link_Pages_Refused :: struct {
	rule: u64,
}

// The link pages of the boot image are read.
@(log_fact = "manual: {pages} link pages")
Link_Pages_Read :: struct {
	pages: u64,
}

// The check of the Markdown of the page of the manual failed: the marks
// that it drew, the marks left, and the widest row.
@(log_fact = "manual: the Markdown of its page: FAILED: {bold} bold, {italics} italics, {code} code, {list_items} list items, {links_that_open} links that open a page of {links}, {marks_left} marks left, the widest row {widest} of {text_width} pixels")
Markdown_Check_Failed :: struct {
	bold:            u64,
	italics:         u64,
	code:            u64,
	list_items:      u64,
	links_that_open: u64,
	links:           u64,
	marks_left:      u64,
	widest:          u64,
	text_width:      u64,
}

// The key back has no page before the page of now.
@(log_fact = "manual: back: no page before")
No_Page_Before :: struct {}

// The key back shows the page before.
@(log_fact = "manual: back to the page before")
Back_To_Page_Before :: struct {}

// The page has no link that opens: the focus moves nowhere.
@(log_fact = "manual: the page has no link that opens")
No_Link_That_Opens :: struct {}

// The boot image has no resource of the link pages.
@(log_fact = "manual: the boot image has no link pages")
No_Link_Pages :: struct {}

// The link pages do not have the hash that their entry names: they are not
// read.
@(log_fact = "manual: the link pages do not have the hash of their entry: not read")
Link_Pages_Hash_Wrong :: struct {}

// The check of the Markdown of the page of the manual passed.
@(log_fact = "manual: the Markdown of its page: bold, italics, code, list items and links that open a page; no mark is left and no row passes the window: as it must")
Markdown_Check_Passed :: struct {}

// The bytes of the Text field of the words of the entry of a module: the
// longest, "a module with an entry", and a zero byte.
ENTRY_WORDS_FIELD_BYTES :: 24

// module_field gives the field of the name of a module of the boot image:
// its text before the first zero byte.
module_field :: proc "contextless" (name: []u8) -> value_kinds.Module_Name_Field {
	return value_kinds.module_name_field(system.name_of(name))
}
