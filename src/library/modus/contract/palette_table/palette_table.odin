// The palette table: what a palette provider shares with the palette of the
// desktop (docs/DESIGN.md, "Palette"), and
// (docs/CONSOLE.md, "8. The palette provider").
//
// **What it is for.** The palette is a panel of the compositor. A palette
// provider, the console, gives it entries of its own: one for each of its
// commands. The provider writes them in one memory object, the entry
// table, which the compositor maps read-only. One ring goes between the two
// processes: the compositor names the entry that the input chose (`Choose`),
// and the provider answers what the entry gave (`Result`). No text of a
// line goes from one process to the other: an entry is a record, a choice
// is a number, and a result is runs of text with what each run is.
//
// **The memory object**: the root service makes it, at least
// `MIN_TABLE_PAGES` pages (`table_pages_for`). A `Header` at byte 0 (with
// `entry_count` and `byte_length`), the result area at `RESULT_OFFSET`,
// the candidate area at `CANDIDATES_OFFSET`, then `Header.entry_count`
// records `Entry` at `ENTRIES_OFFSET`, while they fit.
//
// **The object of the entries.** When the entries pass the table, the
// provider makes a larger object that holds the entries alone, from its
// byte 0, and gives it with `Table_Replaced`. The header, the result area
// and the candidates stay in the table: the compositor reads them on its
// interface thread, and the table is memory that the root service made,
// which the provider can neither revoke in the compositor nor leave with
// pages that have no frame. The compositor never maps the object of the
// entries: it copies it by the kernel (`Memory_Read`), so a revocation or a
// page with no frame is a status there, and not a fault that stops the
// trusted display. `Header.entries_object` names the place of the
// entries: 0 the table, n the object of the nth `Table_Replaced`.
//
// **The reader trusts nothing.** The provider is another process: the
// reader copies the table (`snapshot_take`), then checks each count, each
// length, each kind and each byte of the copy. It never reads the shared
// memory again for a value that it checked. A table that fails is no
// table.
//
// **The writer** changes the table between two additions to
// `Header.change_count`: an odd count says that the table changes now.
//
// **Each text is UTF-8** (src/library/modus/contract/text_encoding): each length
// is a count of bytes, and each check refuses a text with an invalid sequence. A
// capacity holds fewer characters than bytes when a text has characters
// outside ASCII; a writer cuts a text at a whole character.
package palette_table

import "base:intrinsics"
import "modus:contract/enum_word"
import "modus:contract/text_encoding"
import "modus:contract/value_kinds"

MAGIC :: 0x544C4150 // "PALT", little-endian.
VERSION :: 11 // A new field or a new meaning of a field is a new version. 11: 12 parameters matching module.PARAMETER_CAPACITY, 32-byte setting names, chunked text arguments up to 1024 bytes, Range_Stop and Choice candidates.

INITIAL_ENTRY_CAPACITY :: 256 // Initial allocation hint for a new table; not a protocol limit.
NAME_CAPACITY :: 64 // The bytes of the name of an entry.
SIGNATURE_CAPACITY :: 128 // The bytes of the signature of an entry: its name, its parameters, its result.
ABOUT_CAPACITY :: 128 // The bytes of the help sentence of an entry.
// Format property: matches module.PARAMETER_CAPACITY so no export of the
// system is hidden from the palette.
PARAMETER_CAPACITY :: 12
RESULT_CAPACITY :: 2048 // The bytes of the result area.
RESULT_LINE_CAPACITY :: 12 // The lines of a result that the panel shows.
RESULT_COLUMN_CAPACITY :: 76 // The cells of one line of a result that the panel shows.
PARAMETER_NAME_CAPACITY :: 16 // The bytes of the name of a parameter. A longer name is absent.
// Inline capacity: 6 u64 words in one ring.Record (values[1..6]), covering
// short names (process, module, grant, enum, setting) in a single ring record.
// Longer texts cross as ordered chunk records up to ARGUMENT_TEXT_CAPACITY.
ARGUMENT_INLINE_TEXT_CAPACITY :: 48
// Format property: matches chosen_values.TEXT_BYTES_MOST so any bounded module
// text setting (such as browser.home) crosses the palette ring whole.
ARGUMENT_TEXT_CAPACITY :: 1024
ARGUMENT_MAX_CHUNKS :: (ARGUMENT_TEXT_CAPACITY + ARGUMENT_INLINE_TEXT_CAPACITY - 1) / ARGUMENT_INLINE_TEXT_CAPACITY
CANDIDATE_CAPACITY :: 96 // The candidates of one page: a parameter has any count of candidates, which come by pages.
CANDIDATE_NAME_CAPACITY :: 31 // The bytes of the name of a candidate.
ACT_NAME_CAPACITY :: 32 // The bytes of the act name of an entry: what it acts on, as an element of a window names it ("settings.set:font").
// Format property: matches module.NAME_CAPACITY / chosen_values.NAME_CAPACITY
// so every setting parameter name fits a setting row.
SETTING_NAME_CAPACITY :: 32
VALUE_NAME_CAPACITY :: 24 // The bytes of the name of the value of a Provider_Setting entry: one button of its setting row.
SNAPSHOT_TRIES :: 4 // The times that a reader copies a table that changes while it reads.

// What an entry is.
Entry_Kind :: enum u8 {
	Command = 0, // A command of the provider itself.
	Export  = 1, // An export of a module or of a service, which the provider calls.
	// One value that the provider sets, one button of a setting row: one
	// member of an enum parameter of an export (src/md/features/
	// enum_parameters.md), or one scheduling strategy. The provider says
	// the value in use with the flag In_Use: it called the getter of the
	// parameter, or read the strategy.
	Provider_Setting = 2,
}

// entry_kind_of_word is the border of the kind of an entry (Entry.kind):
// the member, or false for a word that names no kind. snapshot_take refuses
// a table with such an entry, and each reader of a copy takes the kind
// through this border again, so no reader holds a kind that the provider
// did not name.
entry_kind_of_word :: proc "contextless" (word: u64) -> (kind: Entry_Kind, ok: bool) {
	return enum_word.member_of_word(Entry_Kind, word)
}

// The facts of an entry that are true or false.
Entry_Flag :: enum u8 {
	Destroys = 0, // The entry destroys something: the panel asks for a second Enter before it sends the choice.
	In_Use   = 1, // A Provider_Setting entry: the machine uses this value now, as the provider read it when it wrote the table. On each other kind the flag is refused.
}
Entry_Flags :: bit_set[Entry_Flag;u8]

// The kind of a value: the numbers of the types of the module contract.
Value_Kind :: enum u8 {
	None    = 0, // No value. A parameter: a value of any kind.
	Integer = 1,
	Text    = 2,
	Record  = 3,
	Handle  = 4,
	Table   = 5,
	Bytes   = 6,
	Enum    = 7, // A member of an enum: a field of the form takes it from the candidates of its parameter, and the panel sends its name as a Text.
}

// value_kind_of_word is the border of the kind of a value in a word of a
// record: the member, or false for a word that names none.
value_kind_of_word :: proc "contextless" (word: u64) -> (kind: Value_Kind, ok: bool) {
	return enum_word.member_of_word(Value_Kind, word)
}

// result_kind_of is the border of the kind of the result of an entry
// (Entry.result). snapshot_take refuses a table with a byte that names no
// kind; a reader of a copy takes the byte through this border again.
result_kind_of :: proc "contextless" (entry: ^Entry) -> (kind: Value_Kind, ok: bool) {
	return value_kind_of_word(u64(entry.result))
}

// parameter_kind_of is the border of the kind of the parameter index of an
// entry (Entry.parameters): false for an index past PARAMETER_CAPACITY and
// for a byte that names no kind.
parameter_kind_of :: proc "contextless" (entry: ^Entry, index: int) -> (kind: Value_Kind, ok: bool) {
	if index < 0 || index >= PARAMETER_CAPACITY {
		return {}, false
	}
	return value_kind_of_word(u64(entry.parameters[index]))
}

// One entry: 664 bytes.
//
// The integer unit of a parameter says what its Integer counts, a size or
// a time and its unit, as the command states it: the panel shows the unit
// after the number of the field. The panel takes the text of the unit
// from the contract, so the provider writes a number and no text there.
//
// The three texts before the units are for the form of the entry in the panel
// (docs/DESIGN.md, "Palette"). The act name says what the entry acts on,
// in the words that an element of a window uses for the same thing: the
// panel offers to go to a window that names it. The name of a setting and
// the name of a value say which setting row an entry joins, and which
// button it is there: the entries of one row follow each other in the
// table, and differ only in their value. The provider writes the three, so
// the panel never parses the name of an entry.
Entry :: struct {
	kind:                   u8, // What the entry is: the word of an Entry_Kind, read through entry_kind_of_word.
	flags:                  Entry_Flags, // Its facts.
	parameter_count:        u8, // Its parameters: 0 to PARAMETER_CAPACITY. 0: the panel runs it with no argument.
	result:                 u8, // The kind of its result: the word of a Value_Kind, read through result_kind_of.
	name_length:            u8, // The bytes of `name` in use: 1 to NAME_CAPACITY.
	signature_length:       u8, // The bytes of `signature` in use. It starts with the name.
	about_length:           u8, // The bytes of `about` in use.
	reserved_first:         u8, // 0.
	parameters:             [PARAMETER_CAPACITY]u8, // The kind of each parameter: the word of a Value_Kind, read through parameter_kind_of.
	parameter_name_lengths: [PARAMETER_CAPACITY]u8, // The bytes of each parameter name in use. 0: the parameter has no name.
	name:                   [NAME_CAPACITY]u8, // The name, identifiers joined by spaces: ASCII 32 to 126 (text_encoding.identifier_words_valid); on a Provider_Setting entry, a display text, as its value name (text_encoding.display_text_valid).
	signature:              [SIGNATURE_CAPACITY]u8, // "revoke(name: Text, grant: Text) -> Integer": UTF-8.
	about:                  [ABOUT_CAPACITY]u8, // What the entry does, in one sentence: UTF-8.
	parameter_names:        [PARAMETER_CAPACITY][PARAMETER_NAME_CAPACITY]u8, // The name of each parameter: UTF-8.
	act_name_length:        u8, // The bytes of `act_name` in use. 0: no element of a window acts on what the entry does.
	setting_name_length:    u8, // The bytes of `setting_name` in use. 0: the entry joins no setting row. Only on a Provider_Setting entry.
	value_name_length:      u8, // The bytes of `value_name` in use. Only on an entry with a setting name, and then at least 1.
	reserved_end:           u8, // 0.
	act_name:               [ACT_NAME_CAPACITY]u8, // "settings.set:font", "strategy": an identifier, ASCII 33 to 126 (text_encoding.identifier_valid).
	setting_name:           [SETTING_NAME_CAPACITY]u8, // "font", "strategy": identifiers joined by spaces, ASCII 32 to 126.
	value_name:             [VALUE_NAME_CAPACITY]u8, // "spleen", "1.75", "eevdf": the display text of a button (text_encoding.display_text_valid).
	parameter_units:        [PARAMETER_CAPACITY]value_kinds.Integer_Unit, // What the Integer of each parameter counts. {}: a plain number, and each parameter that is no Integer.
	reserved_tail:          [4]u8, // 0. Keeps Entry 8-byte aligned.
}
#assert(size_of(Entry) == 664)

// The start of the memory object.
Header :: struct {
	magic:        u32, // MAGIC.
	version:      u32, // VERSION.
	change_count: u32, // The provider adds 1 before a change and 1 after it: odd while it writes. It is the generation of the table.
	entry_count:  u32, // The entries in use.
	byte_length:  u64, // Total valid byte length: ENTRIES_OFFSET + u64(entry_count) * size_of(Entry).
	entries_object: u32, // The place of the entries: 0 the table, n the object of the entries of the nth Table_Replaced.
}

RESULT_OFFSET :: 64 // The first byte of the result area.
CANDIDATES_OFFSET :: RESULT_OFFSET + RESULT_CAPACITY // The first byte of the candidate area: CANDIDATE_CAPACITY records Candidate.
ENTRIES_OFFSET :: CANDIDATES_OFFSET + CANDIDATE_CAPACITY * size_of(Candidate) // The first byte of the entries.

// One candidate of a parameter, in the candidate area: 32 bytes.
Candidate :: struct {
	length: u8, // The bytes of `name` in use: 1 to CANDIDATE_NAME_CAPACITY.
	name:   [CANDIDATE_NAME_CAPACITY]u8, // A value that the parameter can take: UTF-8.
}
#assert(size_of(Candidate) == 32)

// What the candidates of a parameter are: the list says it in words.
Candidate_Kind :: enum u64 {
	None       = 0, // The provider gives no candidate for the parameter.
	Process    = 1, // The processes that run.
	Module     = 2, // The modules of the boot image.
	Grant      = 3, // The grants that the root service can revoke.
	Strategy   = 4, // The scheduling strategies of the kernel, as the command `strategy` takes them.
	Member     = 5, // The members of the enum of the parameter, as its module file names them, with no ".".
	Range_Stop = 6, // Stops of a ranged Integer parameter (module.Parameter_Setting): suggestions across [least, most].
	Choice     = 7, // Open choices returned by a parameter's choices_export (module.Parameter_Setting).
}

// The bit of values[3] of the answer Candidates_Ready that says that the
// candidates are the only values that the parameter takes, and not
// suggestions. The panel then shows a few of them as a row of buttons.
CANDIDATES_CLOSED :: 1
MIN_TABLE_BYTES :: ENTRIES_OFFSET
MIN_TABLE_PAGES :: (MIN_TABLE_BYTES + 4095) / 4096
#assert(size_of(Header) <= RESULT_OFFSET)

// table_bytes_for gives the exact byte length of a table with entry_count
// entries, or ok false on overflow.
table_bytes_for :: proc "contextless" (entry_count: u64) -> (bytes: u64, ok: bool) {
	if entry_count > (max(u64) - ENTRIES_OFFSET) / size_of(Entry) {
		return 0, false
	}
	return ENTRIES_OFFSET + entry_count * size_of(Entry), true
}

// table_pages_for gives the page count (4096-byte pages) required for a table
// holding entry_count entries, or ok false on overflow.
table_pages_for :: proc "contextless" (entry_count: u64) -> (pages: u64, ok: bool) {
	bytes := table_bytes_for(entry_count) or_return
	if bytes > max(u64) - 4095 {
		return 0, false
	}
	return (bytes + 4095) / 4096, true
}

// Where a reader copies the entries from: the table (entries_of_table),
// or the object of the entries that the provider gave with Table_Replaced,
// which the compositor copies by the kernel and never maps.
Entries_Source :: struct {
	user:   rawptr,
	bytes:  u64, // The bytes of the place of the entries.
	object: u32, // The place, as Header.entries_object names it.
	// Copies the first len(into) bytes of the place into into. False: the
	// place gave no bytes (a page with no frame, a revoked handle).
	copy:   proc "contextless" (user: rawptr, into: []u8) -> bool,
}

// entries_of_table gives the source of the entries that a table holds
// itself, from ENTRIES_OFFSET: memory is the mapping of the table.
entries_of_table :: proc "contextless" (memory: []u8) -> Entries_Source {
	if len(memory) < MIN_TABLE_BYTES {
		return {}
	}
	return {user = rawptr(uintptr(raw_data(memory)) + ENTRIES_OFFSET), bytes = u64(len(memory) - ENTRIES_OFFSET), copy = proc "contextless" (user: rawptr, into: []u8) -> bool {
		intrinsics.mem_copy_non_overlapping(raw_data(into), user, len(into))
		return true
	}}
}

// table_entry_capacity gives how many entries fit in a memory region of
// byte_length bytes.
table_entry_capacity :: proc "contextless" (byte_length: u64) -> u64 {
	if byte_length < ENTRIES_OFFSET {
		return 0
	}
	return (byte_length - ENTRIES_OFFSET) / size_of(Entry)
}

// The ring between the two processes. A command goes from the panel to the
// provider; a completion comes back with the tag of its command.
Command :: enum u32 {
	None   = 0, // Not a command.
	// Choose names the entry that the input chose. values[0]: the
	// change_count of the table that the panel showed. values[1]: the
	// index of the entry in that table. values[2]: name_hash of its name.
	// values[3]: a Choose_Mode. values[4]: with Run_With_Arguments, the
	// count of parameters supplied by the Argument commands of the same tag
	// before it (each Text parameter spans 1..ARGUMENT_MAX_CHUNKS records).
	Choose = 1,
	// Candidates asks for one page of the values that one parameter of an
	// entry can take. values[0..2]: as Choose. values[3]: the number of the
	// parameter, from 0. values[4]: the cursor, the place in the list of
	// the matching candidates where the page starts. An Argument command of
	// the same tag before it, of the same parameter and of the kind Text,
	// gives the search text: the list holds the candidates whose names it
	// matches (line_editor.fuzzy_match); with none, each candidate. The
	// answer is Candidates_Ready.
	Candidates = 2,
	// Argument gives one typed value (or one ordered chunk of a Text value)
	// for the Choose or Candidates command of the same tag that follows.
	// values[0]: parameter index in bits [0..7], Value_Kind in [8..15],
	// chunk_length in [16..23], chunk_index in [24..31], total_length in
	// [32..47]. values[1]: an Integer, as an i64. values[1..6]: up to
	// ARGUMENT_INLINE_TEXT_CAPACITY (48) bytes per chunk, reassembled by
	// Argument_Assembly up to ARGUMENT_TEXT_CAPACITY (1024) bytes.
	Argument = 3,
	// Manual asks for the page of the manual of a module. values[0..3]:
	// its name, 31 bytes at most, zero bytes after it.
	Manual = 4,
	// Refresh says that the panel opened. The provider reads again the
	// facts of its entries that change with no line of its own (the value
	// in use of a Provider_Setting) and writes its table again when one
	// changed. It has no value and no answer: a new table says the change.
	Refresh = 5,
}

// What the provider does with a chosen entry.
Choose_Mode :: enum u64 {
	Run  = 0, // Run the entry as a line. Only an entry with no parameter.
	Edit = 1, // Write the entry in the edit line of the provider, with the caret between its parentheses.
	Run_With_Arguments = 2, // Run the entry as a line, with the typed values of the Argument commands before it.
}

// What a choice gave: the kind of a completion is always 0, and values[0]
// is one of these. values[1]: the Value_Kind of the result. values[2]: the
// bytes of the result area in use.
Outcome :: enum u64 {
	None             = 0, // Not an outcome.
	Shown_In_Panel   = 1, // The result area holds the result: the panel draws it.
	Shown_In_Console = 2, // The result is too large for the panel, or has no value to show: the window of the provider has it.
	Failed           = 3, // The line failed: the result area holds its error.
	Refused          = 4, // The provider did not run the entry: the table changed, or the choice names no entry that it can run. The result area holds the sentence.
	Edit_Opened      = 5, // The edit line of the provider holds the entry.
	Candidates_Ready = 6, // The candidate area holds one page of the candidates. values[1]: a Candidate_Kind. values[2]: the count of the page, CANDIDATE_CAPACITY at most. values[3]: CANDIDATES_CLOSED when they are the only values of the parameter, else 0. values[4]: the count of the whole list that matches. values[5]: the cursor where the page starts.
	Manual_Opened    = 7, // The window of the manual shows the page.
	Table_Replaced   = 8, // The provider moved its entries into a larger object of the entries alone: values[1] is the read-only memory handle given through the palette ring, values[2] its bytes, values[3] its number, which Header.entries_object names from then on (1, 2, and so on).
}

// command_of_ring_word is the border of the kind of a record that the
// compositor writes in the ring of the provider: the command, or false for
// a word that names no command, None included. The provider refuses it with
// a line. It reads and changes no state.
command_of_ring_word :: proc "contextless" (word: u32) -> (command: Command, ok: bool) {
	member := enum_word.member_of_word(Command, u64(word)) or_return
	return member, member != .None
}

// outcome_of_word is the border of the outcome word of an answer of the
// provider: the member, or false for a word that names none.
outcome_of_word :: proc "contextless" (word: u64) -> (outcome: Outcome, ok: bool) {
	for member in Outcome {
		if u64(member) == word {
			return member, true
		}
	}
	return {}, false
}

// The result area holds lines of runs. One run: a byte Run_Part, a byte
// length, then that many bytes of UTF-8. A run with the part End_Line and
// the length 0 ends a line.
Run_Part :: enum u8 {
	Plain     = 0, // A text value.
	Label     = 1, // The name of a field.
	Note      = 2, // What the drawer says about the result.
	Failure   = 3, // The sentence of an error.
	Number    = 4, // An Integer.
	Handle    = 5, // A handle.
	Type      = 6, // The name of a record.
	Status    = 7, // An error kind.
	Operation = 8, // The operation of an error.
	Size      = 9, // A field that counts a size, and its unit.
	Time      = 10, // A field that counts a time, and its unit.
	Module    = 11, // A field that holds the name of a module.
	Version   = 12, // A field that holds a hash, in hexadecimal.
	End_Line  = 255, // The line ends.
}

// The last part of a run that holds text: a byte past it, but End_Line, is
// refused.
RUN_PART_LAST :: Run_Part.Version

// name_hash gives the 64-bit FNV-1a hash of a name: a choice carries it, so
// that the provider never runs an entry that the panel did not show.
name_hash :: proc "contextless" (name: string) -> u64 {
	hash: u64 = 0xCBF2_9CE4_8422_2325
	for index in 0 ..< len(name) {
		hash = (hash ~ u64(name[index])) * 0x0000_0100_0000_01B3
	}
	return hash
}

// A copy of a table that passed each check. entries is a caller-supplied
// backing slice sized for at least entry_count entries.
Snapshot :: struct {
	generation:  u32, // The change_count of the copy: even.
	entry_count: int, // The entries in use.
	entries:     []Entry, // Caller-supplied backing buffer for the entries.
}

// Why a table is refused.
Problem :: enum u8 {
	None             = 0, // The table is good.
	Too_Small        = 1, // The memory is smaller than the header or truncated before byte_length.
	Never_Stable     = 2, // The change count stayed odd, or changed during each copy.
	Bad_Magic        = 3,
	Bad_Version      = 4,
	Too_Many_Entries = 5, // More entries than the caller's Snapshot.entries slice holds.
	Bad_Kind         = 6, // An entry: a kind, a flag, a kind of a parameter or of the result out of its range, an integer unit out of the contract or on a parameter that is no Integer, or a reserved byte that is not 0.
	Bad_Length       = 7, // An entry: a length or a count past its field, or an empty name.
	Bad_Byte         = 8, // An entry: a text with an invalid sequence of UTF-8 (a broken sequence or a control character), or a name, an act name, a setting name or a value name outside ASCII.
	Bad_Signature    = 9, // An entry: the signature does not start with the name.
	Bad_Setting      = 10, // A Provider_Setting entry that has parameters; the flag In_Use on an entry that is no Provider_Setting; the name of a setting on another kind, or with no name of a value.
	Bad_Byte_Length  = 11, // Header.byte_length does not match ENTRIES_OFFSET + entry_count * size_of(Entry) or overflows.
	// Header.entries_object names another place than the one that the reader holds: the provider moves its
	// entries, and its Table_Replaced comes. The reader shows no entry of the provider until it holds that place.
	Entries_Moving   = 12,
	Entries_Lost     = 13, // The object of the entries gave no bytes: a page with no frame, or a revoked handle.
}

// The name of each problem, as a log writes it.
@(rodata)
problem_names := [Problem]string {
	.None             = "no problem",
	.Too_Small        = "the memory is smaller than the table",
	.Never_Stable     = "the change count never stayed even",
	.Bad_Magic        = "a wrong magic number",
	.Bad_Version      = "a version that the reader does not know",
	.Too_Many_Entries = "more entries than the snapshot buffer holds",
	.Bad_Kind         = "a kind or a flag out of its range",
	.Bad_Length       = "a length past its field, or an empty name",
	.Bad_Byte         = "a text that is not UTF-8 or has a control character, or a name that is not ASCII",
	.Bad_Signature    = "a signature that does not start with the name",
	.Bad_Setting      = "a setting or a value that the machine does not have",
	.Bad_Byte_Length  = "a header byte length that does not match the entry count",
	.Entries_Moving   = "the entries move to another object",
	.Entries_Lost     = "the object of the entries gives no bytes",
}

// The bits of the flags that the contract knows: each other bit of a table is refused.
ENTRY_FLAGS_KNOWN :: u8(1 << u8(Entry_Flag.Destroys)) | u8(1 << u8(Entry_Flag.In_Use))

// entry_problem checks one entry of a copy.
entry_problem :: proc "contextless" (entry: ^Entry) -> Problem {
	entry_kind, entry_kind_ok := entry_kind_of_word(u64(entry.kind))
	_, result_ok := result_kind_of(entry)
	if !entry_kind_ok || (transmute(u8)entry.flags) &~ ENTRY_FLAGS_KNOWN != 0 || !result_ok || entry.reserved_first != 0 || entry.reserved_end != 0 || entry.reserved_tail != {} {
		return .Bad_Kind
	}
	if int(entry.act_name_length) > ACT_NAME_CAPACITY || int(entry.setting_name_length) > SETTING_NAME_CAPACITY || int(entry.value_name_length) > VALUE_NAME_CAPACITY {
		return .Bad_Length
	}
	// The act name and the name of a setting row are identifiers of the
	// system: ASCII, one form for each name. The name of a value is the
	// display text of a button, which a principal reads and which a
	// translation can write in any script: a display text, UTF-8 with no
	// control character, no character that a reader does not see or that
	// changes the order of the text, and one character that is not a space.
	// Each can be absent (length 0); the rules of their presence are below.
	act_name_valid := entry.act_name_length == 0 || text_encoding.identifier_valid(entry.act_name[:entry.act_name_length])
	value_name_valid := entry.value_name_length == 0 || text_encoding.display_text_valid(entry.value_name[:entry.value_name_length])
	if !act_name_valid || !value_name_valid || !text_encoding.identifier_words_valid(entry.setting_name[:entry.setting_name_length]) {
		return .Bad_Byte
	}
	// A setting row is made of Provider_Setting entries only, and each of
	// its buttons has a name.
	setting_kind := entry_kind == .Provider_Setting
	if entry.setting_name_length != 0 && (!setting_kind || entry.value_name_length == 0) || entry.setting_name_length == 0 && entry.value_name_length != 0 {
		return .Bad_Setting
	}
	if entry_kind == .Provider_Setting && entry.parameter_count != 0 || entry_kind != .Provider_Setting && .In_Use in entry.flags {
		return .Bad_Setting
	}
	if entry.name_length == 0 || int(entry.name_length) > NAME_CAPACITY || int(entry.signature_length) > SIGNATURE_CAPACITY || int(entry.about_length) > ABOUT_CAPACITY || int(entry.parameter_count) > PARAMETER_CAPACITY {
		return .Bad_Length
	}
	for _, index in entry.parameters {
		kind, kind_ok := parameter_kind_of(entry, index)
		if !kind_ok {
			return .Bad_Kind
		}
		// A unit only on an Integer that the entry has: the panel shows
		// the unit of each field, and a field of another kind has no number.
		integer_unit := entry.parameter_units[index]
		if !value_kinds.integer_unit_valid(integer_unit) || integer_unit.kind != .None && (kind != .Integer || index >= int(entry.parameter_count)) {
			return .Bad_Kind
		}
	}
	for length, index in entry.parameter_name_lengths {
		if int(length) > PARAMETER_NAME_CAPACITY {
			return .Bad_Length
		}
		if !text_encoding.text_valid(entry.parameter_names[index][:length]) {
			return .Bad_Byte
		}
	}
	// The name is a command, an export, or words of identifiers ("set font
	// to spleen"): ASCII. The name of a Provider_Setting entry ends with the
	// display text of its value ("settings.set scale to 1.75"): a display
	// text, as that text. The signature and the help sentence are text for a reader:
	// UTF-8.
	name_bytes := entry.name[:entry.name_length]
	name_valid := setting_kind ? text_encoding.display_text_valid(name_bytes) : text_encoding.identifier_words_valid(name_bytes)
	if !name_valid || !text_encoding.text_valid(entry.signature[:entry.signature_length]) || !text_encoding.text_valid(entry.about[:entry.about_length]) {
		return .Bad_Byte
	}
	if entry.signature_length < entry.name_length || string(entry.signature[:entry.name_length]) != string(entry.name[:entry.name_length]) {
		return .Bad_Signature
	}
	return .None
}

// header_read copies and validates the Header of a table without copying
// entries, so a reader knows how large a Snapshot.entries slice to size.
// entries is the place of the entries that the reader holds.
header_read :: proc "contextless" (memory: []u8, entries: Entries_Source) -> (out: Header, problem: Problem) {
	if len(memory) < MIN_TABLE_BYTES {
		return {}, .Too_Small
	}
	header := (^Header)(raw_data(memory))
	for _ in 0 ..< SNAPSHOT_TRIES {
		before := intrinsics.atomic_load_explicit(&header.change_count, .Acquire)
		if before & 1 != 0 {
			continue
		}
		magic := intrinsics.volatile_load(&header.magic)
		version := intrinsics.volatile_load(&header.version)
		count := intrinsics.volatile_load(&header.entry_count)
		byte_length := intrinsics.volatile_load(&header.byte_length)
		entries_object := intrinsics.volatile_load(&header.entries_object)
		if intrinsics.atomic_load_explicit(&header.change_count, .Acquire) != before {
			continue
		}
		if problem = header_problem(magic, version, count, byte_length, entries_object, entries); problem != .None {
			return {}, problem
		}
		return {magic = magic, version = version, change_count = before, entry_count = count, byte_length = byte_length, entries_object = entries_object}, .None
	}
	return {}, .Never_Stable
}

// header_problem checks the fields of a header that a reader read once,
// against the place of the entries that it holds.
@(private = "file")
header_problem :: proc "contextless" (magic, version, count: u32, byte_length: u64, entries_object: u32, entries: Entries_Source) -> Problem {
	if magic != MAGIC {
		return .Bad_Magic
	}
	if version != VERSION {
		return .Bad_Version
	}
	expected_bytes, fits := table_bytes_for(u64(count))
	if !fits || byte_length != expected_bytes {
		return .Bad_Byte_Length
	}
	if entries_object != entries.object {
		return .Entries_Moving
	}
	if u64(count) * size_of(Entry) > entries.bytes {
		return .Too_Small
	}
	return .None
}

// snapshot_take copies a table and checks the copy. memory is the mapping
// of the reader; entries is the place of the entries that it holds. The
// copy is whole only when the change count is even and the same before and
// after it; the reader tries SNAPSHOT_TRIES times. On a problem the
// snapshot has no entry; index is the entry that failed.
snapshot_take :: proc "contextless" (memory: []u8, entries: Entries_Source, snapshot: ^Snapshot) -> (problem: Problem, index: int) {
	snapshot.entry_count = 0
	snapshot.generation = 0
	if len(memory) < MIN_TABLE_BYTES {
		return .Too_Small, 0
	}
	header := (^Header)(raw_data(memory))
	copied := false
	count: u32
	for _ in 0 ..< SNAPSHOT_TRIES {
		before := intrinsics.atomic_load_explicit(&header.change_count, .Acquire)
		if before & 1 != 0 {
			continue
		}
		// Header fields are read once: the copy uses these values and no later ones.
		magic := intrinsics.volatile_load(&header.magic)
		version := intrinsics.volatile_load(&header.version)
		count = intrinsics.volatile_load(&header.entry_count)
		byte_length := intrinsics.volatile_load(&header.byte_length)
		entries_object := intrinsics.volatile_load(&header.entries_object)
		// Only report a header validation error if change_count stayed equal
		// to before; a torn read during a concurrent write must retry.
		found := header_problem(magic, version, count, byte_length, entries_object, entries)
		if found == .None && u64(len(snapshot.entries)) < u64(count) {
			found = .Too_Many_Entries
		}
		if found != .None {
			if intrinsics.atomic_load_explicit(&header.change_count, .Acquire) != before {
				continue
			}
			return found, 0
		}
		if count > 0 {
			into := ([^]u8)(&snapshot.entries[0])[:int(count) * size_of(Entry)]
			if entries.copy == nil || !entries.copy(entries.user, into) {
				return .Entries_Lost, 0
			}
		}
		if intrinsics.atomic_load_explicit(&header.change_count, .Acquire) == before {
			snapshot.generation = before
			copied = true
			break
		}
	}
	if !copied {
		return .Never_Stable, 0
	}
	for &entry, number in snapshot.entries[:count] {
		if found := entry_problem(&entry); found != .None {
			// A refused table gives no generation either: a caller that
			// keeps the generation of its last snapshot would take this one
			// for read, and never read the table again.
			snapshot.generation = 0
			return found, number
		}
	}
	snapshot.entry_count = int(count)
	return .None, 0
}

// result_copy copies the result area of a table and checks the copy: runs
// that end inside the copy, parts in their range, valid UTF-8, at most
// RESULT_LINE_CAPACITY lines. length is the count that the provider gave.
// It gives the count of the bytes of the copy, or ok false.
result_copy :: proc "contextless" (memory: []u8, length: u64, result: ^[RESULT_CAPACITY]u8) -> (count: int, ok: bool) {
	if len(memory) < MIN_TABLE_BYTES || length > RESULT_CAPACITY {
		return 0, false
	}
	count = int(length)
	if count > 0 {
		intrinsics.mem_copy_non_overlapping(&result[0], &memory[RESULT_OFFSET], count)
	}
	return count, result_valid(result[:count])
}

// result_valid checks the runs of a copy of a result area.
result_valid :: proc "contextless" (runs: []u8) -> bool {
	place, lines := 0, 0
	for place < len(runs) {
		if len(runs) - place < 2 {
			return false
		}
		part, length := runs[place], int(runs[place + 1])
		place += 2
		if part == u8(Run_Part.End_Line) {
			if length != 0 {
				return false
			}
			lines += 1
			continue
		}
		if part > u8(RUN_PART_LAST) || length > len(runs) - place || !text_encoding.text_valid(runs[place:][:length]) {
			return false
		}
		place += length
	}
	return lines <= RESULT_LINE_CAPACITY
}

// Result_Writer writes runs into a result area, or into a buffer before
// it. fits is false when a run or a line did not fit the panel: the result
// then shows in the window of the provider only.
Result_Writer :: struct {
	buffer: []u8, // RESULT_CAPACITY bytes at most.
	count:  int, // The bytes written.
	column: int, // The cells of the line that is written now.
	lines:  int, // The lines ended.
	fits:   bool, // Each run and each line fit so far. The caller sets it true first.
}

// result_run adds one run of a line. A text of more than 255 bytes is
// several runs, each cut after a whole character. Each byte of an invalid sequence of
// the text becomes "?", so that the area passes its check. The column
// counts characters: the panel draws one cell for each.
result_run :: proc "contextless" (result: ^Result_Writer, part: Run_Part, text: string) {
	rest := transmute([]u8)text
	for len(rest) > 0 && result.fits {
		taken := min(len(rest), 255)
		if taken < len(rest) {
			if whole := text_encoding.complete_characters(rest[:taken]); whole > 0 {
				taken = whole
			}
		}
		if result.count + 2 + taken > len(result.buffer) || result.lines >= RESULT_LINE_CAPACITY {
			result.fits = false
			return
		}
		// The columns are counted on the run as it is written: a control
		// of two bytes becomes "??", two cells.
		run := result.buffer[result.count + 2:][:taken]
		copy(run, rest[:taken])
		text_encoding.invalid_sequences_replace(run)
		result.column += text_encoding.character_count(run)
		if result.column > RESULT_COLUMN_CAPACITY {
			result.fits = false
			return
		}
		result.buffer[result.count] = u8(part)
		result.buffer[result.count + 1] = u8(taken)
		result.count += 2 + taken
		rest = rest[taken:]
	}
}

// result_line_end ends the line.
result_line_end :: proc "contextless" (result: ^Result_Writer) {
	if !result.fits || result.count + 2 > len(result.buffer) || result.lines >= RESULT_LINE_CAPACITY {
		result.fits = false
		return
	}
	result.buffer[result.count] = u8(Run_Part.End_Line)
	result.buffer[result.count + 1] = 0
	result.count += 2
	result.lines += 1
	result.column = 0
}

// candidates_copy copies the candidate area of a table and checks the
// copy: a count of CANDIDATE_CAPACITY at most, each length from 1 to
// CANDIDATE_NAME_CAPACITY, each name valid UTF-8. count is the count that the
// provider gave. On a problem the copy has no candidate.
candidates_copy :: proc "contextless" (memory: []u8, count: u64, candidates: ^[CANDIDATE_CAPACITY]Candidate) -> (copied: int, ok: bool) {
	if len(memory) < MIN_TABLE_BYTES || count > CANDIDATE_CAPACITY {
		return 0, false
	}
	copied = int(count)
	if copied > 0 {
		intrinsics.mem_copy_non_overlapping(&candidates[0], &memory[CANDIDATES_OFFSET], copied * size_of(Candidate))
	}
	for &candidate in candidates[:copied] {
		if candidate.length == 0 || int(candidate.length) > CANDIDATE_NAME_CAPACITY || !text_encoding.text_valid(candidate.name[:candidate.length]) {
			return 0, false
		}
	}
	return copied, true
}

// argument_chunk_count gives how many Command.Argument ring records carry one
// value: 1 for an Integer or an inline Text (<= ARGUMENT_INLINE_TEXT_CAPACITY),
// and ceil(len(text) / ARGUMENT_INLINE_TEXT_CAPACITY) for a longer Text.
argument_chunk_count :: proc "contextless" (kind: Value_Kind, text: string) -> int {
	if kind != .Text {
		return 1
	}
	length := min(len(text), ARGUMENT_TEXT_CAPACITY)
	if length < len(text) {
		length = text_encoding.complete_characters(transmute([]u8)text[:length])
	}
	if length <= ARGUMENT_INLINE_TEXT_CAPACITY {
		return 1
	}
	return (length + ARGUMENT_INLINE_TEXT_CAPACITY - 1) / ARGUMENT_INLINE_TEXT_CAPACITY
}

// argument_pack_chunk gives the values of chunk chunk_index of an Argument
// command: values[0] packs parameter (bits 0..7), Value_Kind (bits 8..15),
// chunk_length (bits 16..23), chunk_index (bits 24..31), and total_length
// (bits 32..47). An Integer uses chunk 0 with chunk_length = total_length = 0.
// A Text up to ARGUMENT_INLINE_TEXT_CAPACITY uses 1 record (fast tier); longer
// texts up to ARGUMENT_TEXT_CAPACITY cross as ordered chunks (slow tier).
argument_pack_chunk :: proc "contextless" (parameter: int, kind: Value_Kind, integer: i64, text: string, chunk_index: int) -> (values: [7]u64, more: bool) {
	if kind == .Integer {
		values[0] = u64(parameter) & 0xFF | u64(kind) << 8
		values[1] = u64(integer)
		return values, false
	}
	total := min(len(text), ARGUMENT_TEXT_CAPACITY)
	if total < len(text) {
		total = text_encoding.complete_characters(transmute([]u8)text[:total])
	}
	offset := max(chunk_index, 0) * ARGUMENT_INLINE_TEXT_CAPACITY
	if offset > total || (offset == total && chunk_index > 0) {
		return {}, false
	}
	chunk_len := min(total - offset, ARGUMENT_INLINE_TEXT_CAPACITY)
	values[0] = u64(parameter) & 0xFF | u64(kind) << 8 | u64(chunk_len) << 16 | u64(chunk_index) << 24 | u64(total) << 32
	bytes: [ARGUMENT_INLINE_TEXT_CAPACITY]u8
	if chunk_len > 0 {
		copy(bytes[:], text[offset:offset + chunk_len])
	}
	packed := transmute([6]u64)bytes
	for value, index in packed {
		values[1 + index] = value
	}
	return values, offset + chunk_len < total
}

// argument_pack gives the single-record values of an inline Argument command:
// an Integer in values[1], or up to ARGUMENT_INLINE_TEXT_CAPACITY bytes of a
// Text in values[1..6]. A longer Text is cut after a whole character; callers
// sending full texts up to ARGUMENT_TEXT_CAPACITY use argument_pack_chunk.
argument_pack :: proc "contextless" (parameter: int, kind: Value_Kind, integer: i64, text: string) -> (values: [7]u64) {
	length := min(len(text), ARGUMENT_INLINE_TEXT_CAPACITY)
	if length < len(text) {
		length = text_encoding.complete_characters(transmute([]u8)text[:length])
	}
	values, _ = argument_pack_chunk(parameter, kind, integer, text[:length], 0)
	return values
}

// One typed value that one or more Argument commands carried, checked.
Argument_Value :: struct {
	kind:    Value_Kind, // Integer or Text.
	integer: i64, // An Integer.
	length:  int, // A Text: its bytes, up to ARGUMENT_TEXT_CAPACITY.
	text:    [ARGUMENT_TEXT_CAPACITY]u8, // A Text: UTF-8, and no quote.
}

// One validated Argument chunk record read from the palette ring.
Argument_Chunk :: struct {
	parameter:    int,
	kind:         Value_Kind,
	integer:      i64,
	chunk_index:  int,
	chunk_length: int,
	total_length: int,
	bytes:        [ARGUMENT_INLINE_TEXT_CAPACITY]u8,
}

// argument_unpack_chunk checks one raw Argument ring record at the border.
// Refuses out-of-range parameter, unknown or unsupported kind, nonzero high
// bits, non-zero lengths on Integer, lengths past ARGUMENT_INLINE_TEXT_CAPACITY
// or ARGUMENT_TEXT_CAPACITY, and out-of-range chunk_index.
argument_unpack_chunk :: proc "contextless" (values: [7]u64) -> (chunk: Argument_Chunk, ok: bool) {
	parameter := int(values[0] & 0xFF)
	kind_word := values[0] >> 8 & 0xFF
	chunk_length := int(values[0] >> 16 & 0xFF)
	chunk_index := int(values[0] >> 24 & 0xFF)
	total_length := int(values[0] >> 32 & 0xFFFF)
	if values[0] >> 48 != 0 || parameter >= PARAMETER_CAPACITY {
		return {}, false
	}
	value_kind, value_kind_ok := value_kind_of_word(kind_word)
	if !value_kind_ok {
		return {}, false
	}
	switch value_kind {
	case .Integer:
		if chunk_length != 0 || chunk_index != 0 || total_length != 0 {
			return {}, false
		}
		return {parameter = parameter, kind = .Integer, integer = i64(values[1])}, true
	case .Text:
		if chunk_length > ARGUMENT_INLINE_TEXT_CAPACITY || total_length > ARGUMENT_TEXT_CAPACITY || chunk_index >= ARGUMENT_MAX_CHUNKS {
			return {}, false
		}
		offset := chunk_index * ARGUMENT_INLINE_TEXT_CAPACITY
		if offset > total_length || chunk_length > total_length - offset {
			return {}, false
		}
		// Every non-final chunk must be full; chunk 0 with total_length 0 has chunk_length 0.
		if offset + chunk_length < total_length && chunk_length != ARGUMENT_INLINE_TEXT_CAPACITY {
			return {}, false
		}
		if total_length > 0 && chunk_length == 0 {
			return {}, false
		}
		packed: [6]u64
		for index in 0 ..< 6 {
			packed[index] = values[1 + index]
		}
		return {
			parameter    = parameter,
			kind         = .Text,
			chunk_index  = chunk_index,
			chunk_length = chunk_length,
			total_length = total_length,
			bytes        = transmute([ARGUMENT_INLINE_TEXT_CAPACITY]u8)packed,
		}, true
	case .None, .Record, .Handle, .Table, .Bytes, .Enum:
	}
	return {}, false
}

// argument_unpack reads one self-contained inline Argument command (single
// chunk). ok is false for chunked records (use Argument_Assembly), invalid
// UTF-8, or a quote.
argument_unpack :: proc "contextless" (values: [7]u64) -> (parameter: int, argument: Argument_Value, ok: bool) {
	chunk, chunk_ok := argument_unpack_chunk(values)
	if !chunk_ok {
		return 0, {}, false
	}
	if chunk.kind == .Integer {
		return chunk.parameter, {kind = .Integer, integer = chunk.integer}, true
	}
	if chunk.chunk_index != 0 || chunk.chunk_length != chunk.total_length {
		return 0, {}, false
	}
	argument.kind = .Text
	argument.length = chunk.total_length
	copy(argument.text[:chunk.total_length], chunk.bytes[:chunk.chunk_length])
	if !text_encoding.text_valid(argument.text[:argument.length]) {
		return 0, {}, false
	}
	for value in argument.text[:argument.length] {
		if value == '"' {
			return 0, {}, false
		}
	}
	return chunk.parameter, argument, true
}

// Argument_Assembly reassembles one tag's inline and multi-chunk Argument
// records. chunked_arguments counts every Text argument that crossed the
// ARGUMENT_INLINE_TEXT_CAPACITY fast tier into the multi-record slower tier.
Argument_Assembly :: struct {
	values:            [PARAMETER_CAPACITY]Argument_Value,
	given:             bit_set[0 ..< PARAMETER_CAPACITY],
	in_progress:       bit_set[0 ..< PARAMETER_CAPACITY],
	expected_length:   [PARAMETER_CAPACITY]int,
	received_length:   [PARAMETER_CAPACITY]int,
	next_chunk:        [PARAMETER_CAPACITY]int,
	chunked_arguments: u64, // Visible counter of slow-tier (> 48 B) arguments assembled.
}

// argument_assembly_reset clears per-tag state while preserving the lifetime
// chunked_arguments counter.
argument_assembly_reset :: proc "contextless" (assembly: ^Argument_Assembly) {
	assembly.given = {}
	assembly.in_progress = {}
	assembly.expected_length = {}
	assembly.received_length = {}
	assembly.next_chunk = {}
}

// argument_assembly_take validates and incorporates one Command.Argument record.
// Refuses out-of-order chunks, mismatched totals, duplicate completed
// parameters, invalid UTF-8, or quotes on completion.
argument_assembly_take :: proc "contextless" (assembly: ^Argument_Assembly, values: [7]u64) -> bool {
	chunk, ok := argument_unpack_chunk(values)
	if !ok {
		return false
	}
	p := chunk.parameter
	if p in assembly.given {
		return false
	}
	if chunk.kind == .Integer {
		if p in assembly.in_progress {
			return false
		}
		assembly.values[p] = {kind = .Integer, integer = chunk.integer}
		assembly.given += {p}
		return true
	}
	if p not_in assembly.in_progress {
		if chunk.chunk_index != 0 {
			return false
		}
		assembly.values[p] = {kind = .Text, length = 0}
		assembly.expected_length[p] = chunk.total_length
		assembly.received_length[p] = 0
		assembly.next_chunk[p] = 0
		assembly.in_progress += {p}
	} else {
		if chunk.chunk_index != assembly.next_chunk[p] || chunk.total_length != assembly.expected_length[p] {
			return false
		}
	}
	offset := assembly.received_length[p]
	if offset != chunk.chunk_index * ARGUMENT_INLINE_TEXT_CAPACITY || offset + chunk.chunk_length > assembly.expected_length[p] {
		return false
	}
	if chunk.chunk_length > 0 {
		copy(assembly.values[p].text[offset:offset + chunk.chunk_length], chunk.bytes[:chunk.chunk_length])
	}
	assembly.received_length[p] = offset + chunk.chunk_length
	assembly.next_chunk[p] += 1
	if assembly.received_length[p] == assembly.expected_length[p] {
		total := assembly.expected_length[p]
		assembly.in_progress -= {p}
		if !text_encoding.text_valid(assembly.values[p].text[:total]) {
			return false
		}
		for b in assembly.values[p].text[:total] {
			if b == '"' {
				return false
			}
		}
		assembly.values[p].length = total
		assembly.given += {p}
		if total > ARGUMENT_INLINE_TEXT_CAPACITY {
			assembly.chunked_arguments += 1
		}
	}
	return true
}

// The largest count of the whole list of candidates that an answer may
// name: a place in it fits an int of each side and a cursor word.
CANDIDATE_TOTAL_LIMIT :: u64(max(i32))

// candidate_page_valid checks the numbers of a page of candidates that a
// provider answered: a whole list of at most CANDIDATE_TOTAL_LIMIT, a page
// inside it, with no more candidates than the area holds, and a page that
// ends the list or is full. The form checks too that the page starts at
// the place that it asked.
candidate_page_valid :: proc "contextless" (count, total, first: u64) -> bool {
	if total > CANDIDATE_TOTAL_LIMIT || count > CANDIDATE_CAPACITY || first > total || count > total - first {
		return false
	}
	return first + count == total || count == CANDIDATE_CAPACITY
}
