package resources

import "core:fmt"
import "core:os"
import "core:strings"
import "modus:contract/blake3"
import "modus:contract/font_outlines"
import "modustool:foundation"

// The script font set (src/md/features/script_fonts.md): the fonts past
// the boot image, whole, in the format of the font outlines, one data
// object that a plan names by its hash. The command "script_fonts" reads
// them from SCRIPT_FONT_SOURCES and writes SCRIPT_FONTS_OUTPUT; it prints
// the hash of the object. The boot image does not hold the set: it holds
// its name, the resource script_fonts_name, which the build writes beside
// the set (script_fonts_name_write).

SCRIPT_FONT_SOURCES_VARIABLE :: "SCRIPT_FONT_SOURCES"
SCRIPT_FONTS_OUTPUT :: VECTOR_FONT_BUILD_FOLDER + "/script_fonts.bin"
SCRIPT_FONTS_NAME_OUTPUT :: VECTOR_FONT_BUILD_FOLDER + "/script_fonts_name.bin"

// The fonts of the set, by the names that text_rendering.outline_font_name
// gives.
SCRIPT_FONT_NAMES :: [?]string{"noto_sans_hebrew", "noto_sans_arabic", "noto_sans_symbols_2", "noto_emoji", "noto_sans_cjk", "noto_sans_thai", "noto_sans_devanagari", "noto_sans_bengali", "noto_sans_gurmukhi", "noto_sans_gujarati", "noto_sans_oriya", "noto_sans_tamil", "noto_sans_telugu", "noto_sans_kannada", "noto_sans_malayalam"}

// script_fonts_write reads the fonts of SCRIPT_FONT_SOURCES, writes the set
// to SCRIPT_FONTS_OUTPUT and gives its bytes, in temporary memory, and its
// hash. It checks the set as the border of a machine does
// (font_outlines.script_fonts_check): the hash of each font against its
// record is checked here, where the set is made.
script_fonts_write :: proc() -> (set: []u8, hash: blake3.Hash, ok: bool) {
	sources := os.get_env(SCRIPT_FONT_SOURCES_VARIABLE, context.temp_allocator)
	if sources == "" {
		fmt.eprintln("modustool: " + SCRIPT_FONT_SOURCES_VARIABLE + " is not set. Use the development shell: nix develop")
		return nil, {}, false
	}
	names := SCRIPT_FONT_NAMES
	fonts: [len(names)]font_outlines.Font_Input
	for name, index in names {
		path := ""
		rest := sources
		prefix := strings.concatenate({name, "="}, context.temp_allocator)
		for item in strings.split_iterator(&rest, ";") {
			if strings.has_prefix(item, prefix) {
				path = item[len(prefix):]
			}
		}
		if path == "" {
			fmt.eprintfln("modustool: %s has no %s", SCRIPT_FONT_SOURCES_VARIABLE, name)
			return nil, {}, false
		}
		fonts[index] = {name = name, bytes = foundation.read_file(path) or_return}
	}
	size := font_outlines.resource_size(fonts[:])
	if u64(size) > font_outlines.SCRIPT_FONTS_BYTES_LIMIT {
		fmt.eprintfln("modustool: the script font set has %d bytes, and a machine takes at most %d", size, font_outlines.SCRIPT_FONTS_BYTES_LIMIT)
		return nil, {}, false
	}
	words := make([]u64, (size + 7) / 8, context.temp_allocator)
	set = ([^]u8)(raw_data(words))[:size]
	if _, written := font_outlines.resource_write(fonts[:], set); !written {
		fmt.eprintln("modustool: the script font set cannot be written: a name or a file is refused")
		return nil, {}, false
	}
	hash = blake3.hash(set)
	if _, problem := font_outlines.script_fonts_check(set, hash); problem.kind != .None {
		fmt.eprintfln("modustool: the script font set is refused: %s", font_outlines.problem_sentences[problem.kind])
		return nil, {}, false
	}
	foundation.make_folder(VECTOR_FONT_BUILD_FOLDER)
	if err := os.write_entire_file(SCRIPT_FONTS_OUTPUT, set); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", SCRIPT_FONTS_OUTPUT, err)
		return nil, {}, false
	}
	return set, hash, true
}

// script_fonts_name_write writes the set and its name, the 32 bytes of its
// hash, and gives the name as the resource script_fonts_name of the boot
// image: the set of a machine whose plan names none.
script_fonts_name_write :: proc() -> (resource: Resource_File, ok: bool) {
	_, hash := script_fonts_write() or_return
	name := hash
	if err := os.write_entire_file(SCRIPT_FONTS_NAME_OUTPUT, name[:]); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", SCRIPT_FONTS_NAME_OUTPUT, err)
		return {}, false
	}
	return {name = font_outlines.SCRIPT_FONTS_NAME_RESOURCE, path = SCRIPT_FONTS_NAME_OUTPUT}, true
}

// hash_digits gives the 64 hexadecimal digits of a hash.
hash_digits :: proc(hash: blake3.Hash) -> string {
	digits := strings.builder_make(context.temp_allocator)
	for value in hash {
		fmt.sbprintf(&digits, "%02x", value)
	}
	return strings.to_string(digits)
}

run_script_fonts :: proc(args: []string) -> int {
	set, hash, ok := script_fonts_write()
	if !ok {
		return foundation.EXIT_FAILURE
	}
	fmt.printfln("modustool: wrote %s: %d fonts, %d bytes, the hash %s", SCRIPT_FONTS_OUTPUT, len(SCRIPT_FONT_NAMES), len(set), hash_digits(hash))
	return 0
}
