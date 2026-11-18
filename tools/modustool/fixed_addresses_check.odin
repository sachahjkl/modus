package modustool

import "core:fmt"
import "core:os"
import "core:strings"
import "modustool:foundation"

// The fixed ranges have one source: the enumeration Fixed_Range of
// src/library/contract/fixed_addresses (its comment says why). A constant of another
// file written as BAND_START + n * SLOT would be a range with no member,
// which no check of the package sees. So no file of these folders, but the
// package itself, names BAND_START or SLOT of that package.
FIXED_ADDRESSES_FOLDER :: foundation.SOURCE_FOLDER_CONTRACT + "/fixed_addresses"
// The end of the line that imports the package, with its quotes.
FIXED_ADDRESSES_IMPORT :: "\"" + foundation.CONTRACT_IMPORT_START + "fixed_addresses\""
// The kernel too, with its kernel parts: a part can import the package.
FIXED_ADDRESSES_CHECKED_FOLDERS :: [?]string{foundation.SOURCE_FOLDER_KERNEL, foundation.SOURCE_FOLDER_CONTRACT, foundation.SOURCE_FOLDER_SUPPORT, foundation.SOURCE_FOLDER_PRIVATE, foundation.SOURCE_FOLDER_MODULES}
FIXED_ADDRESSES_PRIVATE_NAMES :: [?]string{"BAND_START", "SLOT"}

fixed_addresses_check :: proc() -> bool {
	files := make([dynamic]string, context.temp_allocator)
	folders := FIXED_ADDRESSES_CHECKED_FOLDERS
	names := FIXED_ADDRESSES_PRIVATE_NAMES
	for folder in folders {
		foundation.source_files_of_a_folder(folder, &files) or_return
	}
	found := 0
	for path in files {
		if strings.has_prefix(path, FIXED_ADDRESSES_FOLDER + "/") {
			continue
		}
		bytes, read_error := os.read_entire_file(path, context.temp_allocator)
		if read_error != nil {
			fmt.eprintfln("modustool: test failed: cannot read %s: %v", path, read_error)
			return false
		}
		text := string(bytes)
		alias, imports := fixed_addresses_import_name(text)
		if !imports {
			continue
		}
		for name in names {
			qualified := strings.concatenate({alias, ".", name}, context.temp_allocator)
			at := 0
			for {
				index := strings.index(text[at:], qualified)
				if index < 0 {
					break
				}
				end := at + index + len(qualified)
				// The name, not a longer name that starts with it.
				if end >= len(text) || !identifier_byte(text[end]) {
					line := strings.count(text[:at + index], "\n") + 1
					fmt.eprintfln("modustool: test failed: %s:%d names %s: an address of the band comes from a member of Fixed_Range only (%s)", path, line, qualified, FIXED_ADDRESSES_FOLDER)
					found += 1
				}
				at = end
			}
		}
	}
	if found > 0 {
		return false
	}
	foundation.test_passed_print("no file outside %s names BAND_START or SLOT (%d files read)", FIXED_ADDRESSES_FOLDER, len(files))
	return true
}

// fixed_addresses_import_name gives the name under which a source file
// imports the package of the fixed addresses: its alias, or the name of the package.
@(private = "file")
fixed_addresses_import_name :: proc(text: string) -> (name: string, imports: bool) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		trimmed := strings.trim_space(line)
		if !strings.has_prefix(trimmed, "import ") || !strings.has_suffix(trimmed, FIXED_ADDRESSES_IMPORT) {
			continue
		}
		middle := strings.trim_space(trimmed[len("import "):len(trimmed) - len(FIXED_ADDRESSES_IMPORT)])
		return middle == "" ? "fixed_addresses" : middle, true
	}
	return "", false
}

@(private = "file")
identifier_byte :: proc(byte: u8) -> bool {
	return byte == '_' || byte >= 'a' && byte <= 'z' || byte >= 'A' && byte <= 'Z' || byte >= '0' && byte <= '9'
}
