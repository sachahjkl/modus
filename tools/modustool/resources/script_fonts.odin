package resources

import "core:fmt"
import "core:os"
import "core:strings"
import "modus:contract/blake3"
import "modus:contract/font_outlines"
import "modustool:foundation"

// The script font set (src/md/features/script_fonts.md): the fonts past
// the boot image, whole, in the format of the font outlines, one data
// object that the plan of a principal names by its hash. The command
// "script_fonts" reads them from SCRIPT_FONT_SOURCES and writes
// SCRIPT_FONTS_OUTPUT; it prints the hash of the object. The boot image
// does not hold it.

SCRIPT_FONT_SOURCES_VARIABLE :: "SCRIPT_FONT_SOURCES"
SCRIPT_FONTS_OUTPUT :: VECTOR_FONT_BUILD_FOLDER + "/script_fonts.bin"

// The fonts of the set, by the names that text_rendering.outline_font_name
// gives.
SCRIPT_FONT_NAMES :: [?]string{"noto_sans_hebrew", "noto_sans_arabic", "noto_sans_symbols_2", "noto_emoji", "noto_sans_cjk"}

run_script_fonts :: proc(args: []string) -> int {
	sources := os.get_env(SCRIPT_FONT_SOURCES_VARIABLE, context.temp_allocator)
	if sources == "" {
		fmt.eprintln("modustool: " + SCRIPT_FONT_SOURCES_VARIABLE + " is not set. Use the development shell: nix develop")
		return foundation.EXIT_FAILURE
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
			return foundation.EXIT_FAILURE
		}
		bytes, read := foundation.read_file(path)
		if !read {
			return foundation.EXIT_FAILURE
		}
		fonts[index] = {name = name, bytes = bytes}
	}
	size := font_outlines.resource_size(fonts[:])
	words := make([]u64, (size + 7) / 8, context.temp_allocator)
	out := ([^]u8)(raw_data(words))[:size]
	if _, written := font_outlines.resource_write(fonts[:], out); !written {
		fmt.eprintln("modustool: the script font set cannot be written: a name or a file is refused")
		return foundation.EXIT_FAILURE
	}
	hash := blake3.hash(out)
	// The check of the border where the set enters a machine.
	if _, problem := font_outlines.script_fonts_check(out, hash); problem.kind != .None {
		fmt.eprintfln("modustool: the script font set is refused: %s", font_outlines.problem_sentences[problem.kind])
		return foundation.EXIT_FAILURE
	}
	foundation.make_folder(VECTOR_FONT_BUILD_FOLDER)
	if err := os.write_entire_file(SCRIPT_FONTS_OUTPUT, out); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", SCRIPT_FONTS_OUTPUT, err)
		return foundation.EXIT_FAILURE
	}
	digits := strings.builder_make(context.temp_allocator)
	for value in hash {
		fmt.sbprintf(&digits, "%02x", value)
	}
	fmt.printfln("modustool: wrote %s: %d fonts, %d bytes, the hash %s", SCRIPT_FONTS_OUTPUT, len(fonts), size, strings.to_string(digits))
	return 0
}
