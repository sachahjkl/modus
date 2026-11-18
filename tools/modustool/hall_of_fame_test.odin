package modustool

import "core:os"
import "core:strings"
import "core:testing"

// Each row of the credits file names a picture of the resources, the
// pixels that `modustool portraits` made from it, and a credit that the
// program shows: its author and its license are texts of the program.
@(test)
hall_of_fame_credits_match_the_pictures_and_the_module :: proc(t: ^testing.T) {
	credits, problem := hall_of_fame_credits_read()
	testing.expectf(t, problem == "", "the credits file is refused: %s", problem)
	testing.expect_value(t, len(credits), 5)
	module_source, read_error := os.read_entire_file(HALL_OF_FAME_MODULE_FILE, context.temp_allocator)
	testing.expectf(t, read_error == nil, "cannot read %s: %v", HALL_OF_FAME_MODULE_FILE, read_error)
	for credit in credits {
		picture := strings.concatenate({HALL_OF_FAME_RESOURCE_FOLDER, "/", credit.file}, context.temp_allocator)
		testing.expectf(t, os.is_file(picture), "%s is not a file of the repository", picture)
		pixels := hall_of_fame_pixels_path(credit.file)
		information, stat_error := os.stat(pixels, context.temp_allocator)
		testing.expectf(t, stat_error == nil && information.size == HALL_OF_FAME_PORTRAIT_WIDTH * HALL_OF_FAME_PORTRAIT_HEIGHT * 4, "%s has %d bytes, not the pixels of one portrait: run modustool portraits", pixels, information.size)
		for text in ([]string{credit.author, credit.license}) {
			quoted := strings.concatenate({"\"", text, "\""}, context.temp_allocator)
			testing.expectf(t, strings.contains(string(module_source), quoted), "the module does not show the credit %s of %s", quoted, credit.file)
		}
		testing.expect(t, strings.has_prefix(credit.address, "https://"), "a source has its address")
	}
}

// A row with a missing cell, a name that is not a PNG file of the program
// folder, and a source with no address are refused; the address ends at
// the end of its cell.
@(test)
hall_of_fame_credits_parse_refuses_a_wrong_row :: proc(t: ^testing.T) {
	HEAD :: "| File | Person | Source | Author | Licence |\n|---|---|---|---|---|\n"
	credits, problem := hall_of_fame_credits_parse(HEAD + "| `a_b.png` | A B | A frame of a video, https://example.org/watch?v=1 | Its producers | CC0 |\n")
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(credits), 1)
	if len(credits) == 1 {
		testing.expect_value(t, credits[0].file, "a_b.png")
		testing.expect_value(t, credits[0].address, "https://example.org/watch?v=1")
		testing.expect_value(t, credits[0].license, "CC0")
		testing.expect_value(t, hall_of_fame_pixels_path(credits[0].file), HALL_OF_FAME_PORTRAIT_FOLDER + "/a_b.pixels")
	}
	refused := [?]string {
		HEAD + "| `a.png` | A | https://example.org | CC0 |\n",
		HEAD + "| `A.png` | A | https://example.org | B | CC0 |\n",
		HEAD + "| `a.jpg` | A | https://example.org | B | CC0 |\n",
		HEAD + "| `a.png` | A | a book | B | CC0 |\n",
		HEAD + "| `a.png` |  | https://example.org | B | CC0 |\n",
		HEAD,
	}
	for text in refused {
		_, refusal := hall_of_fame_credits_parse(text)
		testing.expectf(t, refusal != "", "a wrong table is taken: %q", text)
	}
}
