// The portraits of the module hall_of_fame (src/md/features/hall_of_fame.md).
// The pictures and their credits are resources of the repository; the
// command "portraits" converts each picture to the pixels that the module
// holds, so that a build decodes no PNG file. The credits file is the one
// list of the portraits: the command, the page of the licenses of the site
// and a host test read it.
package resources

import "core:fmt"
import "core:image/png"
import "core:os"
import "core:slice"
import "core:strings"
import "modustool:foundation"

HALL_OF_FAME_RESOURCE_FOLDER :: "resources/hall_of_fame"
HALL_OF_FAME_CREDITS_FILE :: HALL_OF_FAME_RESOURCE_FOLDER + "/CREDITS.md"
HALL_OF_FAME_MODULE_FOLDER :: foundation.DEMONSTRATION_MODULE_SOURCES + "hall_of_fame"
HALL_OF_FAME_MODULE_FILE :: HALL_OF_FAME_MODULE_FOLDER + "/main.odin"
HALL_OF_FAME_PORTRAIT_FOLDER :: HALL_OF_FAME_MODULE_FOLDER + "/portraits"
// Each picture of the resources is a crop of this size.
HALL_OF_FAME_SOURCE_WIDTH :: 480
HALL_OF_FAME_SOURCE_HEIGHT :: 640
// Each pixel of a portrait is the mean of a square of this side of the
// source: a whole divisor, so that no pixel of the source counts twice.
HALL_OF_FAME_REDUCTION :: 5
// The size of a portrait in the process: PORTRAIT_WIDTH and
// PORTRAIT_HEIGHT of src/modules/demonstrations/hall_of_fame/main.odin.
HALL_OF_FAME_PORTRAIT_WIDTH :: HALL_OF_FAME_SOURCE_WIDTH / HALL_OF_FAME_REDUCTION
HALL_OF_FAME_PORTRAIT_HEIGHT :: HALL_OF_FAME_SOURCE_HEIGHT / HALL_OF_FAME_REDUCTION
#assert(HALL_OF_FAME_PORTRAIT_WIDTH * HALL_OF_FAME_REDUCTION == HALL_OF_FAME_SOURCE_WIDTH)
#assert(HALL_OF_FAME_PORTRAIT_HEIGHT * HALL_OF_FAME_REDUCTION == HALL_OF_FAME_SOURCE_HEIGHT)

// One row of the table of the credits file: a picture of the resources and
// what its credit says.
Hall_Of_Fame_Credit :: struct {
	file:    string, // The picture in HALL_OF_FAME_RESOURCE_FOLDER: "linus_torvalds.png".
	person:  string, // The name of the person in the picture.
	source:  string, // Where the picture comes from, as the file writes it.
	address: string, // The first address "https://..." of the source.
	author:  string, // Who made the picture.
	license: string, // The license of the picture, as the file writes it.
}

// hall_of_fame_credits_parse reads the rows of the table of the credits
// file: each line that starts with "| `" is a row of five cells, the file
// in backquotes, the person, the source, the author and the license. A row
// with another count of cells, a file that is not a PNG name of lower case
// letters, digits and "_", an empty cell or a source with no address is a
// problem.
hall_of_fame_credits_parse :: proc(content: string) -> (credits: []Hall_Of_Fame_Credit, problem: string) {
	rows := make([dynamic]Hall_Of_Fame_Credit, context.temp_allocator)
	for line, index in foundation.lines_of_text(content) {
		if !strings.has_prefix(line, "| `") {
			continue
		}
		inner := strings.trim_suffix(strings.trim_space(line[len("| "):]), " |")
		cells := strings.split(inner, " | ", context.temp_allocator)
		if len(cells) != 5 {
			return nil, fmt.tprintf("%s: line %d: a row has %d cells, not 5", HALL_OF_FAME_CREDITS_FILE, index + 1, len(cells))
		}
		for &cell in cells {
			cell = strings.trim_space(cell)
			if cell == "" {
				return nil, fmt.tprintf("%s: line %d: a cell is empty", HALL_OF_FAME_CREDITS_FILE, index + 1)
			}
		}
		credit := Hall_Of_Fame_Credit {
			file    = strings.trim_suffix(strings.trim_prefix(cells[0], "`"), "`"),
			person  = cells[1],
			source  = cells[2],
			author  = cells[3],
			license = cells[4],
		}
		stem := strings.trim_suffix(credit.file, ".png")
		if !strings.has_suffix(credit.file, ".png") || stem == "" || !hall_of_fame_name_valid(stem) {
			return nil, fmt.tprintf("%s: line %d: %q is not the name of a PNG file of lower case letters, digits and _", HALL_OF_FAME_CREDITS_FILE, index + 1, credit.file)
		}
		start := strings.index(credit.source, "https://")
		if start < 0 {
			return nil, fmt.tprintf("%s: line %d: the source has no address https://", HALL_OF_FAME_CREDITS_FILE, index + 1)
		}
		credit.address = credit.source[start:]
		// An address of Wikimedia Commons can hold parentheses, so only a
		// space, a comma or a semicolon ends it.
		if end := strings.index_any(credit.address, " ,;"); end > 0 {
			credit.address = credit.address[:end]
		}
		append(&rows, credit)
	}
	if len(rows) == 0 {
		return nil, fmt.tprintf("%s: the table has no row", HALL_OF_FAME_CREDITS_FILE)
	}
	return rows[:], ""
}

// hall_of_fame_name_valid says if a name has only lower case letters,
// digits and "_": the name of a file of the module folder.
hall_of_fame_name_valid :: proc(name: string) -> bool {
	for character in transmute([]u8)name {
		if !(character >= 'a' && character <= 'z' || character >= '0' && character <= '9' || character == '_') {
			return false
		}
	}
	return true
}

// hall_of_fame_credits_read reads and parses the credits file.
hall_of_fame_credits_read :: proc() -> (credits: []Hall_Of_Fame_Credit, problem: string) {
	data, err := os.read_entire_file(HALL_OF_FAME_CREDITS_FILE, context.temp_allocator)
	if err != nil {
		return nil, fmt.tprintf("cannot read %s: %v", HALL_OF_FAME_CREDITS_FILE, err)
	}
	return hall_of_fame_credits_parse(string(data))
}

// hall_of_fame_pixels_path gives the file of the pixels of a picture of the
// resources, in the folder of the module.
hall_of_fame_pixels_path :: proc(picture_file: string) -> string {
	return strings.concatenate({HALL_OF_FAME_PORTRAIT_FOLDER, "/", strings.trim_suffix(picture_file, ".png"), ".pixels"}, context.temp_allocator)
}

// run_portraits converts each picture of the credits file to its pixels:
// HALL_OF_FAME_PORTRAIT_WIDTH x HALL_OF_FAME_PORTRAIT_HEIGHT colors of 32
// bits (0x00RRGGBB), line after line, each the mean of a square of
// HALL_OF_FAME_REDUCTION x HALL_OF_FAME_REDUCTION pixels of the source.
run_portraits :: proc(args: []string) -> int {
	credits, problem := hall_of_fame_credits_read()
	if problem != "" {
		fmt.eprintfln("modustool: %s", problem)
		return foundation.EXIT_FAILURE
	}
	if err := os.make_directory_all(HALL_OF_FAME_PORTRAIT_FOLDER); err != nil && err != .Exist {
		fmt.eprintfln("modustool: cannot make %s: %v", HALL_OF_FAME_PORTRAIT_FOLDER, err)
		return foundation.EXIT_FAILURE
	}
	for credit in credits {
		source_path := strings.concatenate({HALL_OF_FAME_RESOURCE_FOLDER, "/", credit.file}, context.temp_allocator)
		source, ok := foundation.read_file(source_path)
		if !ok {
			return foundation.EXIT_FAILURE
		}
		picture, err := png.load_from_bytes(source, {}, context.temp_allocator)
		if err != nil {
			fmt.eprintfln("modustool: cannot decode %s: %v", source_path, err)
			return foundation.EXIT_FAILURE
		}
		if picture.channels < 3 || picture.depth != 8 || picture.width != HALL_OF_FAME_SOURCE_WIDTH || picture.height != HALL_OF_FAME_SOURCE_HEIGHT {
			fmt.eprintfln("modustool: %s has %dx%d pixels of %d channels of %d bits: it must have %dx%d pixels of 3 or 4 channels of 8 bits", source_path, picture.width, picture.height, picture.channels, picture.depth, HALL_OF_FAME_SOURCE_WIDTH, HALL_OF_FAME_SOURCE_HEIGHT)
			return foundation.EXIT_FAILURE
		}
		bytes := picture.pixels[:]
		pixels := make([]u32, HALL_OF_FAME_PORTRAIT_WIDTH * HALL_OF_FAME_PORTRAIT_HEIGHT, context.temp_allocator)
		for y in 0 ..< HALL_OF_FAME_PORTRAIT_HEIGHT {
			for x in 0 ..< HALL_OF_FAME_PORTRAIT_WIDTH {
				sums: [3]int
				for row in 0 ..< HALL_OF_FAME_REDUCTION {
					for column in 0 ..< HALL_OF_FAME_REDUCTION {
						source_x := x * HALL_OF_FAME_REDUCTION + column
						source_y := y * HALL_OF_FAME_REDUCTION + row
						texel := bytes[(source_y * picture.width + source_x) * picture.channels:]
						sums[0] += int(texel[0])
						sums[1] += int(texel[1])
						sums[2] += int(texel[2])
					}
				}
				count :: HALL_OF_FAME_REDUCTION * HALL_OF_FAME_REDUCTION
				pixels[y * HALL_OF_FAME_PORTRAIT_WIDTH + x] = u32((sums[0] + count / 2) / count) << 16 | u32((sums[1] + count / 2) / count) << 8 | u32((sums[2] + count / 2) / count)
			}
		}
		output := hall_of_fame_pixels_path(credit.file)
		if write_err := os.write_entire_file(output, slice.to_bytes(pixels)); write_err != nil {
			fmt.eprintfln("modustool: cannot write %s: %v", output, write_err)
			return foundation.EXIT_FAILURE
		}
		fmt.printfln("modustool: wrote %s: %dx%d pixels from %s", output, HALL_OF_FAME_PORTRAIT_WIDTH, HALL_OF_FAME_PORTRAIT_HEIGHT, source_path)
	}
	return 0
}
