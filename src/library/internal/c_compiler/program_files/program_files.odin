// The files of a program of several C sources, as the export
// `compile_unit` of the module `c_compiler` takes them: one Bytes argument
// that holds each header of the program, and one Text argument that names
// the exports (src/md/features/c_compiler.md, "A unit of a program").
//
// A file list is a run of records, each a head of 8 bytes and two runs of
// bytes, with no padding:
//
// ```
// name_size:    u32, little endian
// content_size: u32, little endian
// name:         name_size bytes
// content:      content_size bytes
// ```
//
// An export list is the names of the exports, separated by spaces, tabs or
// new lines. The package reads both at the border of the export, and
// writes a file list for a host program. It allocates nothing and calls no
// kernel operation.
package program_files

// The bounds of a file list. A name is a name of the table of files of the
// thin libc: chibicc compares it whole, and the module copies it with a
// byte 0 after it.
FILES_MOST :: 256
NAME_BYTES_MOST :: 255
LIST_BYTES_MOST :: 2 * 1024 * 1024
RECORD_HEAD_BYTES :: 8
// The exports of one unit: the bound of the exports of the assembler.
EXPORTS_MOST :: 32

// What is wrong with a file list, an export list, or the name of a source.
// The module answers each with its error record.
Refusal :: enum u8 {
	None           = 0,
	List_Too_Long  = 1, // The list has more than LIST_BYTES_MOST bytes. value: its bytes.
	Head_Cut       = 2, // The list ends inside the head of a record. value: the end of the head.
	Content_Cut    = 3, // The name or the content of a record passes the end of the list. value: its end.
	Name_Empty     = 4, // A name has no byte.
	Name_Too_Long  = 5, // A name has more than NAME_BYTES_MOST bytes. value: its bytes.
	Byte_Zero      = 6, // A name or a content holds a byte 0: chibicc reads a file up to its first byte 0.
	Name_Twice     = 7, // Two files, or a file and the source, or two exports, have one name.
	Too_Many_Files = 8, // More than FILES_MOST files, or more than the room of the caller. value: the count.
	Too_Many_Names = 9, // More than EXPORTS_MOST exports. value: the count.
}

// A refusal, and the byte of the list or the text where it is.
Refusal_Record :: struct {
	refusal: Refusal,
	offset:  u64, // The first byte of the record, the name or the byte that the refusal names.
	value:   u64, // What the member of Refusal says.
}

// A file of the list: views of the list.
File :: struct {
	name:    string,
	content: []u8,
}

// name_check reads one name: the name of the source, of a file or of an
// export. offset is the place of its first byte in its argument.
name_check :: proc "contextless" (name: string, offset: u64) -> Refusal_Record {
	if len(name) == 0 {
		return {refusal = .Name_Empty, offset = offset}
	}
	if len(name) > NAME_BYTES_MOST {
		return {refusal = .Name_Too_Long, offset = offset, value = u64(len(name))}
	}
	for index in 0 ..< len(name) {
		if name[index] == 0 {
			return {refusal = .Byte_Zero, offset = offset + u64(index)}
		}
	}
	return {}
}

// head_read reads the two sizes of the head of a record.
@(private)
head_read :: proc "contextless" (list: []u8, at: u64) -> (name_size: u64, content_size: u64) {
	word :: proc "contextless" (bytes: []u8) -> u64 {
		return u64(bytes[0]) | u64(bytes[1]) << 8 | u64(bytes[2]) << 16 | u64(bytes[3]) << 24
	}
	return word(list[at:at + 4]), word(list[at + 4:at + 8])
}

// file_list_read reads a file list into `files`, and gives the count of its
// files. Each file is checked whole before the next: its head, its name, a
// name that the source or a file before it has, and each byte of its
// content. An empty list has no file. No file is given with a refusal.
file_list_read :: proc "contextless" (list: []u8, source_name: string, files: []File) -> (count: int, refusal: Refusal_Record) {
	if len(list) > LIST_BYTES_MOST {
		return 0, {refusal = .List_Too_Long, value = u64(len(list))}
	}
	capacity := min(len(files), FILES_MOST)
	at := u64(0)
	end := u64(len(list))
	for at < end {
		if end - at < RECORD_HEAD_BYTES {
			return 0, {refusal = .Head_Cut, offset = at, value = at + RECORD_HEAD_BYTES}
		}
		if count == capacity {
			return 0, {refusal = .Too_Many_Files, offset = at, value = u64(count + 1)}
		}
		name_size, content_size := head_read(list, at)
		name_start := at + RECORD_HEAD_BYTES
		// Each size is below 2^32, so the sum does not wrap.
		record_end := name_start + name_size + content_size
		if record_end > end {
			return 0, {refusal = .Content_Cut, offset = at, value = record_end}
		}
		name := string(list[name_start:name_start + name_size])
		if refusal = name_check(name, name_start); refusal.refusal != .None {
			return 0, refusal
		}
		if name == source_name {
			return 0, {refusal = .Name_Twice, offset = name_start}
		}
		for earlier in files[:count] {
			if earlier.name == name {
				return 0, {refusal = .Name_Twice, offset = name_start}
			}
		}
		content := list[name_start + name_size:record_end]
		for index in 0 ..< len(content) {
			if content[index] == 0 {
				return 0, {refusal = .Byte_Zero, offset = name_start + name_size + u64(index)}
			}
		}
		files[count] = {name = name, content = content}
		count += 1
		at = record_end
	}
	return count, {}
}

// export_list_read reads an export list into `names`, and gives the count
// of its names. A text with no name gives 0: then each function that is not
// static is an export.
export_list_read :: proc "contextless" (text: string, names: []string) -> (count: int, refusal: Refusal_Record) {
	capacity := min(len(names), EXPORTS_MOST)
	at := 0
	for at < len(text) {
		if is_separator(text[at]) {
			at += 1
			continue
		}
		start := at
		for at < len(text) && !is_separator(text[at]) {
			at += 1
		}
		name := text[start:at]
		if refusal = name_check(name, u64(start)); refusal.refusal != .None {
			return 0, refusal
		}
		for earlier in names[:count] {
			if earlier == name {
				return 0, {refusal = .Name_Twice, offset = u64(start)}
			}
		}
		if count == capacity {
			return 0, {refusal = .Too_Many_Names, offset = u64(start), value = u64(count + 1)}
		}
		names[count] = name
		count += 1
	}
	return count, {}
}

@(private)
is_separator :: proc "contextless" (character: u8) -> bool {
	return character == ' ' || character == '\t' || character == '\n'
}

// file_list_size gives the bytes of the file list of `files`.
file_list_size :: proc "contextless" (files: []File) -> u64 {
	size := u64(0)
	for file in files {
		size += RECORD_HEAD_BYTES + u64(len(file.name)) + u64(len(file.content))
	}
	return size
}

// file_list_write writes the file list of `files` at the start of `output`,
// and gives its bytes. ok is false, and nothing is written, when output is
// smaller than file_list_size, or a name or a content has 2^32 bytes or
// more, which a head does not hold. The bytes that file_list_read refuses
// are written as they are: the reader is the border.
file_list_write :: proc "contextless" (files: []File, output: []u8) -> (size: u64, ok: bool) {
	size = file_list_size(files)
	if size > u64(len(output)) {
		return 0, false
	}
	for file in files {
		if u64(len(file.name)) > u64(max(u32)) || u64(len(file.content)) > u64(max(u32)) {
			return 0, false
		}
	}
	word_write :: proc "contextless" (bytes: []u8, value: u64) {
		bytes[0] = u8(value)
		bytes[1] = u8(value >> 8)
		bytes[2] = u8(value >> 16)
		bytes[3] = u8(value >> 24)
	}
	at := 0
	for file in files {
		word_write(output[at:], u64(len(file.name)))
		word_write(output[at + 4:], u64(len(file.content)))
		at += RECORD_HEAD_BYTES
		copy(output[at:], file.name)
		at += len(file.name)
		copy(output[at:], file.content)
		at += len(file.content)
	}
	return size, true
}
