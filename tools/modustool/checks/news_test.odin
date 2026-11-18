package checks

import "core:strings"
import "core:testing"

@(test)
news_of_a_damaged_entry :: proc(t: ^testing.T) {
	Damage :: struct {
		before, after: string,
	}
	damages := []Damage {
		{"title: A thing a reader can see\n", ""},
		{"title: A thing a reader can see", "title:"},
		{"title: A thing a reader can see", "title: A `thing`"},
		{"title: A thing a reader can see", "title:  A thing"},
		{"title: A thing a reader can see", strings.concatenate({"title: ", strings.repeat("a", NEWS_TITLE_LIMIT + 1, context.temp_allocator)}, context.temp_allocator)},
		{"date: 2026-11-11", "date: 2026-11-12"},
		{"date: 2026-11-11", "date: 2026-02-30"},
		{"release: 0.58.0", "release: 0.58"},
		{"release: 0.58.0", "release: soon"},
		{"picture: docs/screenshots/console.png", "picture: build/console.png"},
		{"picture: docs/screenshots/console.png", "picture: docs/screenshots/../../secret.png"},
		{"picture: docs/screenshots/console.png", "picture: docs/screenshots/console.jpg"},
		{"kind: Measured", "kind: Announced"},
		{"guide: docs/CONSOLE.md", "guide: docs/SITE.md"},
		{"guide: docs/CONSOLE.md", "guide: CONSOLE.md"},
		{"guide: docs/CONSOLE.md", "guide: docs/research/a.md"},
		{"guide: docs/CONSOLE.md", "guide: docs/glossary/"},
		{"guide: docs/CONSOLE.md", "guide: docs/glossary/text.txt"},
		{"guide: docs/CONSOLE.md", "guide: docs/glossary/old/text.md"},
		{"guide: docs/CONSOLE.md", "guide: glossary/text.md"},
		{"guide: docs/CONSOLE.md", "guide: docs/CONSOLE.md\ncolor: blue"},
		{"guide: docs/CONSOLE.md", "guide: docs/CONSOLE.md\nkind: Shown"},
		{"guide: docs/CONSOLE.md\n\n", "guide: docs/CONSOLE.md\n"},
		{"The first sentence.", "# A heading\nThe first sentence."},
		{"The first sentence.", "<p>The first sentence.</p>"},
		{"The first sentence.", "\tThe first sentence."},
		{"The first sentence. The second sentence with `code`.\nA line that continues it.\n", ""},
		{"The first sentence.", strings.repeat("A sentence. ", 120, context.temp_allocator)},
	}
	for damage in damages {
		damaged, changed := strings.replace_all(NEWS_EXAMPLE_TEXT, damage.before, damage.after, context.temp_allocator)
		testing.expectf(t, changed, "the text %q is not in the good entry", damage.before)
		_, problems := news_parse(NEWS_EXAMPLE_NAME, damaged)
		testing.expectf(t, len(problems) > 0, "no problem found after %q became %q", damage.before, damage.after)
	}
	names := []string{"2026-11-11.md", "2026-11-11-A-thing.md", "2026-13-01-a-thing.md", "20261111-a-thing.md", "2026-11-11-a-thing.txt", "2026-11-11--thing.md"}
	for name in names {
		_, problems := news_parse(name, NEWS_EXAMPLE_TEXT)
		testing.expectf(t, len(problems) > 0, "the name %q is accepted", name)
	}
	_, empty_problems := news_parse(NEWS_EXAMPLE_NAME, "")
	testing.expect(t, len(empty_problems) > 0)
}

@(test)
news_new_entry_waits_for_its_title_and_text :: proc(t: ^testing.T) {
	_, problems := news_parse(NEWS_EXAMPLE_NAME, news_text("2026-11-11"))
	// The title has no value, and the text is empty: two problems, and only those.
	testing.expectf(t, len(problems) == 2, "problems: %v", problems)
	for problem in problems {
		testing.expectf(t, strings.contains(problem, "title") || strings.contains(problem, "text"), "an unexpected problem: %s", problem)
	}
}

@(test)
news_names_present_files :: proc(t: ^testing.T) {
	changelog := Changelog {
		releases = []Changelog_Release{{number = {0, 58, 0}, date = "2026-11-11"}},
	}
	good, _ := news_parse(NEWS_EXAMPLE_NAME, NEWS_EXAMPLE_TEXT)
	problems := make([dynamic]string, context.temp_allocator)
	news_files_problems([]News_Entry{good}, changelog, &problems)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)

	absent := good
	absent.release = "0.59.0"
	absent.picture = "docs/screenshots/no_picture_of_the_news_test.png"
	absent.guide = "docs/NO_GUIDE_OF_THE_NEWS_TEST.md"
	clear(&problems)
	news_files_problems([]News_Entry{absent}, changelog, &problems)
	testing.expectf(t, len(problems) == 3, "problems: %v", problems)

	twin := good
	twin.file_name = "2026-11-12-a-thing.md"
	clear(&problems)
	news_files_problems([]News_Entry{good, twin}, changelog, &problems)
	testing.expectf(t, len(problems) == 1, "two entries with one title: %v", problems)
}

// One element of a WebM file of a test: its identifier, its size in one
// byte, its content.
@(private = "file")
test_webm_element :: proc(identifier: []u8, content: []u8) -> []u8 {
	element := make([dynamic]u8, context.temp_allocator)
	append(&element, ..identifier)
	append(&element, 0x80 | u8(len(content)))
	append(&element, ..content)
	return element[:]
}

// The start of a WebM file with a document type: the EBML header.
@(private = "file")
test_webm_header :: proc(document_type: string) -> []u8 {
	return test_webm_element({0x1A, 0x45, 0xDF, 0xA3}, test_webm_element({0x42, 0x82}, transmute([]u8)document_type))
}

// The tracks of a WebM file with one track of pictures of a size.
@(private = "file")
test_webm_tracks :: proc(width, height: u16) -> []u8 {
	sizes := make([dynamic]u8, context.temp_allocator)
	append(&sizes, ..test_webm_element({0xB0}, {u8(width >> 8), u8(width)}))
	append(&sizes, ..test_webm_element({0xBA}, {u8(height >> 8), u8(height)}))
	video := test_webm_element({0xE0}, sizes[:])
	return test_webm_element({0x16, 0x54, 0xAE, 0x6B}, test_webm_element({0xAE}, video))
}

// The smallest WebM file that the tool takes as a film: the header, and a
// segment whose tracks state a picture size.
@(private = "file")
test_webm_film :: proc(width, height: u16) -> []u8 {
	film := make([dynamic]u8, context.temp_allocator)
	append(&film, ..test_webm_header("webm"))
	append(&film, ..test_webm_element({0x18, 0x53, 0x80, 0x67}, test_webm_tracks(width, height)))
	return film[:]
}

// The key film: an entry can leave it out, "none" says the same, and a
// value is a WebM file of docs/films/. An entry with a film has a picture.
@(test)
news_film_key_is_optional :: proc(t: ^testing.T) {
	absent, absent_problems := news_parse(NEWS_EXAMPLE_NAME, NEWS_EXAMPLE_TEXT)
	testing.expectf(t, len(absent_problems) == 0, "problems: %v", absent_problems)
	testing.expect_value(t, absent.film, NEWS_NONE)
	testing.expect(t, !news_entry_has_film(absent), "an entry with no line of the key has no film")
	testing.expect(t, !news_entry_has_film(News_Entry{}), "an entry with no value of the key has no film")

	with_film :: proc(value: string) -> (News_Entry, [dynamic]string) {
		content, _ := strings.replace_all(NEWS_EXAMPLE_TEXT, "guide: docs/CONSOLE.md", strings.concatenate({"guide: docs/CONSOLE.md\nfilm: ", value}, context.temp_allocator), context.temp_allocator)
		return news_parse(NEWS_EXAMPLE_NAME, content)
	}
	none, none_problems := with_film("none")
	testing.expectf(t, len(none_problems) == 0, "problems: %v", none_problems)
	testing.expect(t, !news_entry_has_film(none), "\"film: none\" is no film")

	named, named_problems := with_film("docs/films/palette.webm")
	testing.expectf(t, len(named_problems) == 0, "problems: %v", named_problems)
	testing.expect_value(t, named.film, "docs/films/palette.webm")
	testing.expect(t, news_entry_has_film(named), "the entry names a film")
	// The text starts one line later.
	testing.expect_value(t, named.text_line, 9)

	for value in ([]string{"docs/films/palette.mp4", "build/films/palette.webm", "docs/films/../films/palette.webm", "docs/films/.webm", "docs/films/a/palette.webm", "docs/films/a film.webm", "palette.webm", "docs/films/palette.webm\nfilm: none"}) {
		_, problems := with_film(value)
		testing.expectf(t, len(problems) > 0, "the film %q is accepted", value)
	}

	// A film with no picture: one problem, which names the picture.
	no_picture, changed := strings.replace_all(NEWS_EXAMPLE_TEXT, "picture: docs/screenshots/console.png", "picture: none\nfilm: docs/films/palette.webm", context.temp_allocator)
	testing.expect(t, changed, "the good entry has its picture")
	_, no_picture_problems := news_parse(NEWS_EXAMPLE_NAME, no_picture)
	testing.expectf(t, len(no_picture_problems) == 1, "problems: %v", no_picture_problems)
	if len(no_picture_problems) == 1 {
		testing.expect(t, strings.contains(no_picture_problems[0], "picture"), "the problem names the picture")
	}
}

// The file of a film: a WebM file, under the size bound, whose tracks
// state the size of its pictures.
@(test)
news_film_file_is_a_small_webm_file :: proc(t: ^testing.T) {
	good := test_webm_film(2048, 1536)
	testing.expect_value(t, film_document_problem(good), "")
	testing.expect(t, film_document_is_webm(good), "the file starts as a WebM file")
	width, height, sized := film_document_picture_size(good)
	testing.expect(t, sized, "the file states the size of its pictures")
	testing.expect_value(t, width, 2048)
	testing.expect_value(t, height, 1536)

	// A segment that does not state its size goes to the end of the file.
	open_ended := make([dynamic]u8, context.temp_allocator)
	append(&open_ended, ..test_webm_header("webm"))
	append(&open_ended, 0x18, 0x53, 0x80, 0x67, 0xFF)
	append(&open_ended, ..test_webm_tracks(640, 480))
	open_width, open_height, open_sized := film_document_picture_size(open_ended[:])
	testing.expect(t, open_sized, "a segment of no stated size is read to the end of the file")
	testing.expect_value(t, open_width, 640)
	testing.expect_value(t, open_height, 480)

	// Not a WebM file: an MP4 file, a PNG file, another document type, no byte.
	mp4_start := []u8{0x00, 0x00, 0x00, 0x18, 'f', 't', 'y', 'p', 'i', 's', 'o', 'm', 0x00, 0x00, 0x02, 0x00, 'i', 's', 'o', 'm', 'i', 's', 'o', '2'}
	png_start := []u8{0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n', 0x00, 0x00, 0x00, 0x0D, 'I', 'H', 'D', 'R'}
	other_type := make([dynamic]u8, context.temp_allocator)
	append(&other_type, ..test_webm_header("matroska"))
	append(&other_type, ..test_webm_element({0x18, 0x53, 0x80, 0x67}, test_webm_tracks(2048, 1536)))
	for data in ([][]u8{mp4_start, png_start, other_type[:], nil}) {
		testing.expect(t, !film_document_is_webm(data), "the bytes are not a WebM file")
		testing.expect(t, strings.contains(film_document_problem(data), "not a WebM file"), "the problem says that the file is not a WebM file")
	}

	// A WebM file that is cut, and one with no track of pictures.
	testing.expect(t, film_document_problem(good[:len(good) - 3]) != "", "a file that is cut is refused")
	no_tracks := make([dynamic]u8, context.temp_allocator)
	append(&no_tracks, ..test_webm_header("webm"))
	append(&no_tracks, ..test_webm_element({0x18, 0x53, 0x80, 0x67}, nil))
	testing.expect(t, film_document_is_webm(no_tracks[:]), "the file starts as a WebM file")
	testing.expect(t, film_document_problem(no_tracks[:]) != "", "a file with no track of pictures is refused")

	// One byte over the bound: refused for its size, whatever it holds.
	too_large := make([]u8, FILM_DOCUMENT_SIZE_LIMIT + 1)
	defer delete(too_large)
	copy(too_large, good)
	testing.expect(t, strings.contains(film_document_problem(too_large), "bytes"), "the problem gives the size")
	testing.expect_value(t, film_document_problem(too_large[:len(good)]), "")
}

// An entry that names a film that the repository does not hold.
@(test)
news_names_a_present_film :: proc(t: ^testing.T) {
	changelog := Changelog {
		releases = []Changelog_Release{{number = {0, 58, 0}, date = "2026-11-11"}},
	}
	entry, _ := news_parse(NEWS_EXAMPLE_NAME, NEWS_EXAMPLE_TEXT)
	entry.film = "docs/films/no_film_of_the_news_test.webm"
	problems := make([dynamic]string, context.temp_allocator)
	news_files_problems([]News_Entry{entry}, changelog, &problems)
	testing.expectf(t, len(problems) == 1, "problems: %v", problems)
	if len(problems) == 1 {
		testing.expect(t, strings.contains(problems[0], "docs/films/no_film_of_the_news_test.webm"), "the problem names the film")
	}
}

@(test)
news_of_the_repository :: proc(t: ^testing.T) {
	entries, problems := news_all_read()
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	testing.expect(t, len(entries) > 0, "news/ has no entry")
	for index in 1 ..< len(entries) {
		testing.expect(t, entries[index - 1].date >= entries[index].date, "the entries are not newest first")
	}
}
