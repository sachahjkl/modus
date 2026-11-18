// The files and the texts that each package of the tool reads and writes:
// a folder made or emptied, a file read, moved or copied, the files of a
// folder, the lines of a text and of a manifest, and the small readers of
// a text that several concerns share
// (src/md/infrastructure/repository_layout.md, "The tool in packages").
package foundation

import "base:intrinsics"
import "core:fmt"
import "core:odin/tokenizer"
import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

join :: proc(parts: ..string) -> string {
	return strings.concatenate(parts, context.temp_allocator)
}

read_file :: proc(path: string) -> (data: []u8, ok: bool) {
	err: os.Error
	data, err = os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("modustool: cannot read %s: %v", path, err)
		return nil, false
	}
	return data, true
}

// file_move renames a file, or copies it and removes the source when the
// two paths are on two file systems (build/ can be a link to another disk:
// /tmp/disk, when the memory file system of the computer is full).
file_move :: proc(source, destination: string) -> os.Error {
	if err := os.rename(source, destination); err == nil {
		return nil
	}
	if err := os.copy_file(destination, source); err != nil {
		return err
	}
	return os.remove(source)
}

// files_with_suffix gives the paths of the files of a folder that end with suffix.
files_with_suffix :: proc(folder, suffix: string) -> (paths: []string, ok: bool) {
	entries, err := os.read_all_directory_by_path(folder, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("modustool: cannot list %s: %v", folder, err)
		return nil, false
	}
	list := make([dynamic]string, context.temp_allocator)
	for entry in entries {
		if strings.has_suffix(entry.name, suffix) {
			append(&list, join(folder, "/", entry.name))
		}
	}
	slice.sort(list[:])
	return list[:], true
}

// make_folder makes a folder and each folder above it. Two processes of the
// parallel build can make the same folder above theirs at the same time:
// the one that loses gets "exists" for that folder before its own folder is
// made, so it tries again.
make_folder :: proc(path: string) -> bool {
	err: os.Error
	for _ in 0 ..< 4 {
		err = os.make_directory_all(path)
		if err == nil || os.exists(path) {
			return true
		}
	}
	fmt.eprintfln("modustool: cannot create %s: %v", path, err)
	return false
}

reset_folder :: proc(path: string) -> bool {
	if os.exists(path) {
		if err := os.remove_all(path); err != nil {
			fmt.eprintfln("modustool: cannot remove %s: %v", path, err)
			return false
		}
	}
	return make_folder(path)
}

// file_copy_as_new writes the bytes of source to a new file target, with
// the permissions of a new file: a copy of a file of the store keeps no
// read-only mode, so a later copy can write over it.
file_copy_as_new :: proc(target, source: string) -> bool {
	bytes, read_error := os.read_entire_file(source, context.temp_allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: cannot read %s: %v", source, read_error)
		return false
	}
	_ = os.remove(target)
	if write_error := os.write_entire_file(target, bytes); write_error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", target, write_error)
		return false
	}
	return true
}

// source_files_of_a_folder appends the .odin files of a folder and of its
// folders.
source_files_of_a_folder :: proc(folder: string, files: ^[dynamic]string) -> bool {
	entries, err := os.read_all_directory_by_path(folder, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("modustool: cannot list %s: %v", folder, err)
		return false
	}
	for entry in entries {
		path := join(folder, "/", entry.name)
		switch {
		case entry.type == .Directory:
			source_files_of_a_folder(path, files) or_return
		case strings.has_suffix(entry.name, ".odin"):
			append(files, path)
		}
	}
	return true
}

// read_text_file_quiet reads a file that can be absent, with no message.
read_text_file_quiet :: proc(path: string) -> (text: string, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return string(data), err == nil
}

// read_text_file reads one text file of the repository.
read_text_file :: proc(path: string) -> (text: string, ok: bool) {
	data := read_file(path) or_return
	return string(data), true
}

// html_escape writes a text of a file as HTML text: each character that
// HTML reads as markup becomes its reference.
html_escape :: proc(builder: ^strings.Builder, text: string) {
	for index in 0 ..< len(text) {
		switch text[index] {
		case '&':
			strings.write_string(builder, "&amp;")
		case '<':
			strings.write_string(builder, "&lt;")
		case '>':
			strings.write_string(builder, "&gt;")
		case '"':
			strings.write_string(builder, "&quot;")
		case '\'':
			strings.write_string(builder, "&#39;")
		case:
			strings.write_byte(builder, text[index])
		}
	}
}

// png_size reads the width and the height of a PNG file from its
// header chunk, which the format puts first.
png_size :: proc(data: []u8) -> (width, height: int, ok: bool) {
	signature := [8]u8{0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'}
	if len(data) < 24 {
		return 0, 0, false
	}
	for index in 0 ..< len(signature) {
		if data[index] != signature[index] {
			return 0, 0, false
		}
	}
	if string(data[12:16]) != "IHDR" {
		return 0, 0, false
	}
	big_endian :: proc(bytes: []u8) -> int {
		return int(bytes[0]) << 24 | int(bytes[1]) << 16 | int(bytes[2]) << 8 | int(bytes[3])
	}
	return big_endian(data[16:20]), big_endian(data[20:24]), true
}

// lines_of_text splits a file into lines with no carriage return.
lines_of_text :: proc(content: string) -> []string {
	lines := strings.split(content, "\n", context.temp_allocator)
	for &line in lines {
		line = strings.trim_right(line, "\r")
	}
	return lines
}

// decimal_digits_value gives the value of a text of decimal digits, or -1.
decimal_digits_value :: proc(text: string) -> int {
	if len(text) == 0 || len(text) > 12 {
		return -1
	}
	value := 0
	for character in transmute([]u8)text {
		if character < '0' || character > '9' {
			return -1
		}
		value = value * 10 + int(character - '0')
	}
	return value
}

// manifest_lines gives the lines of a manifest that are not comments, each
// as its fields.
manifest_lines :: proc(path: string) -> (lines: [][]string, ok: bool) {
	text, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("modustool: cannot read %s: %v", path, err)
		return nil, false
	}
	list := make([dynamic][]string, context.temp_allocator)
	for line in strings.split_lines(string(text), context.temp_allocator) {
		if len(line) == 0 || line[0] == '#' {
			continue
		}
		append(&list, strings.fields(line, context.temp_allocator))
	}
	return list[:], true
}

CRYPTOGRAPHY_MANIFEST :: CRYPTOGRAPHY_FOLDER + "/origin.manifest"

CRYPTOGRAPHY_FOLDER :: SOURCE_FOLDER_SUPPORT + "/cryptography"

// text_slug gives an id from a text: the lowercase letters and the digits,
// one "-" for each run of other characters, none at the ends.
text_slug :: proc(text: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	dash := false
	for index in 0 ..< len(text) {
		character := text[index]
		if character >= 'A' && character <= 'Z' {
			character += 'a' - 'A'
		}
		if (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9') {
			if dash && strings.builder_len(builder) > 0 {
				strings.write_byte(&builder, '-')
			}
			strings.write_byte(&builder, character)
			dash = false
		} else {
			dash = true
		}
	}
	if strings.builder_len(builder) == 0 {
		return "part"
	}
	return strings.to_string(builder)
}

is_word_byte :: proc(character: u8) -> bool {
	return (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') || (character >= '0' && character <= '9') || character == '_' || character >= 0x80
}

// json_string_write writes a text as a JSON string. Each character that
// can end the string or a line of a script is escaped, also when the JSON
// is put inside a page or a script: the quote, the backslash, the control
// characters, < > & (no "</script>" in the text), U+2028 and U+2029 (line
// ends for a script). A byte that is not UTF-8 becomes U+FFFD.
json_string_write :: proc(b: ^strings.Builder, text: string) {
	strings.write_byte(b, '"')
	index := 0
	for index < len(text) {
		character, size := utf8.decode_rune_in_string(text[index:])
		switch {
		case character == utf8.RUNE_ERROR && size <= 1:
			strings.write_string(b, "\\ufffd")
			size = 1
		case character == '"':
			strings.write_string(b, "\\\"")
		case character == '\\':
			strings.write_string(b, "\\\\")
		case character == '\n':
			strings.write_string(b, "\\n")
		case character == '<':
			strings.write_string(b, "\\u003c")
		case character == '>':
			strings.write_string(b, "\\u003e")
		case character == '&':
			strings.write_string(b, "\\u0026")
		case character == 0x2028:
			strings.write_string(b, "\\u2028")
		case character == 0x2029:
			strings.write_string(b, "\\u2029")
		case character < 0x20 || character == 0x7F:
			fmt.sbprintf(b, "\\u%04x", int(character))
		case:
			strings.write_string(b, text[index:index + size])
		}
		index += size
	}
	strings.write_byte(b, '"')
}

// quoted_text_after gives the text between the first two quotes after start.
quoted_text_after :: proc(line: string, start: int = 0) -> (text: string, end: int, found: bool) {
	first := strings.index_byte(line[start:], '"')
	if first < 0 {
		return "", 0, false
	}
	first += start + 1
	second := strings.index_byte(line[first:], '"')
	if second < 0 {
		return "", 0, false
	}
	return line[first:first + second], first + second + 1, true
}

// The tokenizer reports a fault of the text to its handler; the caller
// reads the count of faults, and a block with a fault is written plain.
tokenizer_quiet_error :: proc(pos: tokenizer.Pos, format: string, args: ..any) {}

// enum_member_at gives the member of an enum at a place, from 0, in the
// order of its members: a choice of the tool by a place (a draw of the
// fuzzer, a count of the sections that a check saw), which is no word of
// another party. A place past the last member is a fault of the tool, and
// stops it: no member stands in for it.
enum_member_at :: proc($Enum: typeid, place: int) -> Enum where intrinsics.type_is_enum(Enum) {
	count := 0
	for member in Enum {
		if count == place {
			return member
		}
		count += 1
	}
	fmt.panicf("modustool: the place %d is past the %d members of %v", place, count, typeid_of(Enum))
}

// markdown_comment_line splits a line of an Odin source into its code and
// its comment, as a part of the Markdown of the comment: the marker "//"
// and one space go, the indentation after them stays, so that a nested list
// item and a line of an example keep their form. is_comment is true for a
// line "//" with no text: an empty line of the comment.
markdown_comment_line :: proc(line: string) -> (code: string, comment: string, is_comment: bool) {
	syntax, _ := comment_syntax_of(".odin")
	quote: u8 = 0
	for index := 0; index < len(line); index += 1 {
		character := line[index]
		switch {
		case quote != 0:
			if character == '\\' && strings.index_byte(syntax.escaped_quotes, quote) >= 0 {
				index += 1
			} else if character == quote {
				quote = 0
			}
		case strings.index_byte(syntax.escaped_quotes, character) >= 0 || strings.index_byte(syntax.raw_quotes, character) >= 0:
			quote = character
		case strings.has_prefix(line[index:], syntax.marker):
			text := strings.trim_right_space(line[index + len(syntax.marker):])
			text = strings.trim_prefix(text, " ")
			text, _ = strings.replace_all(text, "\t", "    ", context.temp_allocator)
			return strings.trim_space(line[:index]), text, true
		}
	}
	return strings.trim_space(line), "", false
}

// markdown_comment_add adds a line to the Markdown of a comment. An empty
// line stays: it separates two paragraphs.
markdown_comment_add :: proc(comment, line: string) -> string {
	if comment == "" && strings.trim_space(line) == "" {
		return ""
	}
	if comment == "" {
		return line
	}
	return strings.concatenate({comment, "\n", line}, context.temp_allocator)
}

// markdown_comment_end gives the Markdown of a comment with no empty line
// at its end.
markdown_comment_end :: proc(comment: string) -> string {
	return strings.trim_right(comment, " \n")
}
