// The kept record of chosen values (src/md/features/module_settings.md,
// "The precedence"): what the owner of settings keeps in its store. It holds
// the values that the principal chose, and only them: a setting that the
// principal did not set has no entry, so a later default of the plan or of
// the contract holds for it.
//
// Each entry is a name and a value: a word, or a text. The name is the name
// of the field of the setting, so a contract that adds or moves a setting
// moves no kept value: no index is a key. The owner checks each value at its
// own border before it uses it; a value that its border refuses holds as no
// choice, and stays kept as it was.
//
// A rewrite copies each entry that it does not change, the names that the
// owner does not know too: a module of an earlier release that reads a
// record of a later one keeps the choices of the later one for its return.
// Nothing that the owner did not set is overwritten.
//
// The record is bytes of the caller: no count is fixed; the room of the
// caller bounds it. This package allocates no memory and calls no kernel
// operation.
package chosen_values

import "base:intrinsics"
import "modus:contract/enum_word"
import "modus:contract/text_encoding"

// The bytes "CHOSEN02" and the size of the header: the magic, the count of
// the entries, and the bytes of the texts after the entries.
RECORD_MAGIC :: u64(0x3230_4E45_534F_4843)
HEADER_SIZE :: 16
// The bytes of the name of a setting, zero bytes after it: the longest name
// of a parameter of an export (module.NAME_SIZE).
NAME_SIZE :: 32
// One entry: the name, the kind byte, seven zero bytes, then the value in
// little-endian: a word, or for a text its place in the texts (the low 32
// bits) and its length (the high 32 bits).
ENTRY_SIZE :: NAME_SIZE + 16
// The longest text of one entry. The owner states the bound of each of its
// texts, at most this; the reader refuses a longer text before any owner
// sees it.
TEXT_BYTES_MOST :: 1024

// The kind of the value of an entry. The values are in the store, so they
// are stated.
Entry_Kind :: enum u8 {
	Word = 1,
	Text = 2,
}

// Why a record or a change is refused. A refusal reads nothing more and
// writes nothing.
Record_Problem :: enum u8 {
	None             = 0,
	Too_Short        = 1, // Fewer bytes than a header.
	Bad_Magic        = 2, // The record is not a record of chosen values: its owner reads no value from it, and writes over it only when the principal changes a value.
	Reserved_Not_Zero = 3,
	Count_Past_Bytes = 4, // The count names more entries than the bytes hold, or the texts pass the end of the bytes.
	Bad_Name         = 5, // A name that is empty, longer than NAME_SIZE - 1, holds a byte that is not a small letter, a digit or '_', or has a byte after its first zero.
	Name_Twice       = 6, // Two entries with one name.
	No_Room          = 7, // The record after the change does not fit the bytes of the caller.
	Bad_Kind         = 8, // A kind byte that names no Entry_Kind, or a change of no Change_Kind.
	Bad_Text_Place   = 9, // A text that is not right after the text before it, past the texts, or longer than TEXT_BYTES_MOST; or texts that the entries do not cover whole.
	Text_Not_Utf8    = 10, // A text that is not UTF-8.
}

// The name of each problem, for a line of the log.
@(rodata)
RECORD_PROBLEM_NAMES := [Record_Problem]string {
	.None              = "none",
	.Too_Short         = "too short",
	.Bad_Magic         = "another format",
	.Reserved_Not_Zero = "reserved bytes",
	.Count_Past_Bytes  = "a count past its bytes",
	.Bad_Name          = "a name not valid",
	.Name_Twice        = "a name twice",
	.No_Room           = "no room",
	.Bad_Kind          = "a kind not valid",
	.Bad_Text_Place    = "a text out of place",
	.Text_Not_Utf8     = "a text not UTF-8",
}

// A change of one setting: a new chosen word or text, or a reset that makes
// it absent.
Change_Kind :: enum u8 {
	Choose      = 1,
	Reset       = 2,
	Choose_Text = 3,
}

Change :: struct {
	name:  string,
	kind:  Change_Kind,
	value: u64, // With Choose.
	text:  string, // With Choose_Text: UTF-8, at most TEXT_BYTES_MOST bytes.
}

// A record that read_record checked: its entries and its texts, in the
// bytes of the caller.
Record :: struct {
	entries: []u8,
	count:   int,
	texts:   []u8,
}

// record_size gives the bytes of a checked record, its header included; 0
// for the empty record.
record_size :: proc "contextless" (record: Record) -> int {
	if record.count == 0 && len(record.texts) == 0 && record.entries == nil {
		return 0
	}
	return HEADER_SIZE + record.count * ENTRY_SIZE + len(record.texts)
}

// name_valid says if a text is a name of a setting: 1 to NAME_SIZE - 1
// bytes, each a small letter, a digit or '_', the first a letter.
name_valid :: proc "contextless" (name: string) -> bool {
	if len(name) == 0 || len(name) >= NAME_SIZE {
		return false
	}
	for index in 0 ..< len(name) {
		character := name[index]
		letter := character >= 'a' && character <= 'z'
		digit := character >= '0' && character <= '9'
		if !(letter || (index > 0 && (digit || character == '_'))) {
			return false
		}
	}
	return true
}

@(private)
read_u64 :: proc "contextless" (bytes: []u8) -> u64 {
	value: u64
	for index in 0 ..< 8 {
		value |= u64(bytes[index]) << u64(index * 8)
	}
	return value
}

@(private)
write_u64 :: proc "contextless" (bytes: []u8, value: u64) {
	for index in 0 ..< 8 {
		bytes[index] = u8(value >> u64(index * 8))
	}
}

// entry_name gives the name of an entry of a checked record.
entry_name :: proc "contextless" (record: Record, index: int) -> string {
	entry := record.entries[index * ENTRY_SIZE:][:NAME_SIZE]
	length := 0
	for length < NAME_SIZE && entry[length] != 0 {
		length += 1
	}
	return string(entry[:length])
}

// entry_kind_of_word is the border of the kind byte of an entry.
entry_kind_of_word :: proc "contextless" (word: u8) -> (kind: Entry_Kind, ok: bool) {
	return enum_word.member_of_word(Entry_Kind, u64(word))
}

// entry_kind gives the kind of an entry of a checked record.
entry_kind :: proc "contextless" (record: Record, index: int) -> Entry_Kind {
	kind, ok := entry_kind_of_word(record.entries[index * ENTRY_SIZE + NAME_SIZE])
	return ok ? kind : .Word
}

// entry_value gives the word of a word entry of a checked record.
entry_value :: proc "contextless" (record: Record, index: int) -> u64 {
	return read_u64(record.entries[index * ENTRY_SIZE + NAME_SIZE + 8:][:8])
}

// entry_text gives the text of a text entry of a checked record.
entry_text :: proc "contextless" (record: Record, index: int) -> string {
	word := entry_value(record, index)
	return string(record.texts[int(word & 0xFFFF_FFFF):][:int(word >> 32)])
}

// read_record checks the bytes of a kept record whole: its header, each
// name, each kind, the place of each text and its UTF-8, and no name twice.
// An empty slice is the record of a principal who chose nothing. Bytes
// after the record are not read. The caller gives bytes that it copied from
// the store, so no other party changes them while they are read.
read_record :: proc "contextless" (bytes: []u8) -> (record: Record, problem: Record_Problem) {
	if len(bytes) == 0 {
		return {}, .None
	}
	if len(bytes) < HEADER_SIZE {
		return {}, .Too_Short
	}
	if read_u64(bytes[0:8]) != RECORD_MAGIC {
		return {}, .Bad_Magic
	}
	count := u64(bytes[8]) | u64(bytes[9]) << 8 | u64(bytes[10]) << 16 | u64(bytes[11]) << 24
	text_bytes := u64(bytes[12]) | u64(bytes[13]) << 8 | u64(bytes[14]) << 16 | u64(bytes[15]) << 24
	if count > u64(len(bytes) - HEADER_SIZE) / ENTRY_SIZE || text_bytes > u64(len(bytes) - HEADER_SIZE) - count * ENTRY_SIZE {
		return {}, .Count_Past_Bytes
	}
	entries_end := HEADER_SIZE + int(count) * ENTRY_SIZE
	record = {entries = bytes[HEADER_SIZE:entries_end], count = int(count), texts = bytes[entries_end:][:int(text_bytes)]}
	text_place := 0
	for index in 0 ..< record.count {
		entry := record.entries[index * ENTRY_SIZE:][:ENTRY_SIZE]
		length := 0
		for length < NAME_SIZE && entry[length] != 0 {
			length += 1
		}
		for after in length ..< NAME_SIZE {
			if entry[after] != 0 {
				return {}, .Bad_Name
			}
		}
		if !name_valid(string(entry[:length])) {
			return {}, .Bad_Name
		}
		for reserved in entry[NAME_SIZE + 1:][:7] {
			if reserved != 0 {
				return {}, .Reserved_Not_Zero
			}
		}
		switch entry[NAME_SIZE] {
		case u8(Entry_Kind.Word):
		case u8(Entry_Kind.Text):
			// The texts follow the entries in their order, with no gap: one
			// record has one form, and no text overlaps another.
			word := read_u64(entry[NAME_SIZE + 8:][:8])
			place, text_length := int(word & 0xFFFF_FFFF), int(word >> 32)
			if place != text_place || text_length > TEXT_BYTES_MOST || text_length > len(record.texts) - place {
				return {}, .Bad_Text_Place
			}
			if !text_encoding.text_valid(record.texts[place:][:text_length]) {
				return {}, .Text_Not_Utf8
			}
			text_place += text_length
		case:
			return {}, .Bad_Kind
		}
		for earlier in 0 ..< index {
			if entry_name(record, earlier) == string(entry[:length]) {
				return {}, .Name_Twice
			}
		}
	}
	if text_place != len(record.texts) {
		return {}, .Bad_Text_Place
	}
	return record, .None
}

// entry_of gives the place of the entry of a name, or found false.
@(private)
entry_of :: proc "contextless" (record: Record, name: string) -> (index: int, found: bool) {
	for place in 0 ..< record.count {
		if entry_name(record, place) == name {
			return place, true
		}
	}
	return 0, false
}

// contains says if the record has an entry of a name, of either kind.
contains :: proc "contextless" (record: Record, name: string) -> bool {
	_, found := entry_of(record, name)
	return found
}

// find gives the chosen word of a name, or found false when the principal
// chose no word for it (no entry, or a text).
find :: proc "contextless" (record: Record, name: string) -> (value: u64, found: bool) {
	if index, has := entry_of(record, name); has && entry_kind(record, index) == .Word {
		return entry_value(record, index), true
	}
	return 0, false
}

// find_text gives the chosen text of a name, or found false when the
// principal chose no text for it (no entry, or a word). The text is in the
// bytes of the record.
find_text :: proc "contextless" (record: Record, name: string) -> (text: string, found: bool) {
	if index, has := entry_of(record, name); has && entry_kind(record, index) == .Text {
		return entry_text(record, index), true
	}
	return "", false
}

// One entry of the record that write_record writes.
@(private)
Written_Entry :: struct {
	name: string,
	kind: Entry_Kind,
	word: u64,
	text: string,
}

// write_record writes into out the record that a checked record gives after
// the changes: each entry that no change names stays as it was, in its
// place, the names that the caller does not know too; a Choose or a
// Choose_Text replaces the value of its name or adds an entry at the end; a
// Reset removes the entry. A change with a name that is not valid, of no
// kind, with a text that is not UTF-8 or longer than TEXT_BYTES_MOST, two
// changes of one name, or a result past the room of out is refused, and out
// is then not a record. The record and out are two places: out never holds
// the bytes of record.
write_record :: proc "contextless" (record: Record, changes: []Change, out: []u8) -> (written: int, problem: Record_Problem) {
	for change, index in changes {
		if !name_valid(change.name) {
			return 0, .Bad_Name
		}
		switch change.kind {
		case .Choose, .Reset:
		case .Choose_Text:
			if len(change.text) > TEXT_BYTES_MOST {
				return 0, .Bad_Text_Place
			}
			if !text_encoding.text_valid(transmute([]u8)change.text) {
				return 0, .Text_Not_Utf8
			}
		case:
			return 0, .Bad_Kind
		}
		for earlier in 0 ..< index {
			if changes[earlier].name == change.name {
				return 0, .Name_Twice
			}
		}
	}
	// The entry at a place of the result: the entries of the record that
	// stay, then the new names, in the order of the changes.
	result_of :: proc "contextless" (record: Record, changes: []Change, place: int) -> (entry: Written_Entry, ok: bool) {
		at := 0
		for index in 0 ..< record.count {
			name := entry_name(record, index)
			entry = {name = name, kind = entry_kind(record, index)}
			if entry.kind == .Word {
				entry.word = entry_value(record, index)
			} else {
				entry.text = entry_text(record, index)
			}
			kept := true
			for change in changes {
				if change.name != name {
					continue
				}
				switch change.kind {
				case .Reset:
					kept = false
				case .Choose:
					entry = {name = name, kind = .Word, word = change.value}
				case .Choose_Text:
					entry = {name = name, kind = .Text, text = change.text}
				}
			}
			if kept {
				if at == place {
					return entry, true
				}
				at += 1
			}
		}
		for change in changes {
			if change.kind == .Reset || contains(record, change.name) {
				continue
			}
			if at == place {
				if change.kind == .Choose_Text {
					return {name = change.name, kind = .Text, text = change.text}, true
				}
				return {name = change.name, kind = .Word, word = change.value}, true
			}
			at += 1
		}
		return {}, false
	}
	count := 0
	text_bytes := 0
	for {
		entry, ok := result_of(record, changes, count)
		if !ok {
			break
		}
		count += 1
		text_bytes += len(entry.text)
	}
	need := HEADER_SIZE + count * ENTRY_SIZE + text_bytes
	if len(out) < need {
		return 0, .No_Room
	}
	text_at := 0
	texts := out[HEADER_SIZE + count * ENTRY_SIZE:][:text_bytes]
	for place in 0 ..< count {
		entry, _ := result_of(record, changes, place)
		bytes := out[HEADER_SIZE + place * ENTRY_SIZE:][:ENTRY_SIZE]
		intrinsics.mem_zero(raw_data(bytes), ENTRY_SIZE)
		copy(bytes[:NAME_SIZE], entry.name)
		bytes[NAME_SIZE] = u8(entry.kind)
		if entry.kind == .Text {
			copy(texts[text_at:], entry.text)
			write_u64(bytes[NAME_SIZE + 8:], u64(text_at) | u64(len(entry.text)) << 32)
			text_at += len(entry.text)
		} else {
			write_u64(bytes[NAME_SIZE + 8:], entry.word)
		}
	}
	write_u64(out[0:8], RECORD_MAGIC)
	out[8], out[9], out[10], out[11] = u8(count), u8(count >> 8), u8(count >> 16), u8(count >> 24)
	out[12], out[13], out[14], out[15] = u8(text_bytes), u8(text_bytes >> 8), u8(text_bytes >> 16), u8(text_bytes >> 24)
	return need, .None
}

// The layer that gives a value (src/md/features/module_settings.md, "The
// precedence"). A state export of an owner gives it for each setting. The
// values cross the call region, so they are stated.
Layer :: enum u8 {
	Contract_Default = 0,
	Plan_Default     = 1,
	Chosen           = 2,
	Locked           = 3,
}
