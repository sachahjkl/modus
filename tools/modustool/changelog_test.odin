package modustool

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
GOOD_CHANGELOG :: `# Changelog

All notable changes. The format is Keep a Changelog.

## [0.2.0] - 2026-11-11 09:05

### Added

- **Two**: a thing
  on two lines.

### Fixed

- A fault.

## [0.1.0] - 2026-11-10

### Added

- One.

[0.2.0]: https://github.com/sachahjkl/modus/releases/tag/v0.2.0
[0.1.0]: https://github.com/sachahjkl/modus/releases/tag/v0.1.0
`

// A release with its heading, its entry and its link, for the cases of faults.
@(private = "file")
ONE_RELEASE :: "# Changelog\n\n## [0.1.0] - 2026-11-10 08:00\n\n### Added\n\n- One.\n\n[0.1.0]: https://github.com/sachahjkl/modus/releases/tag/v0.1.0\n"

@(private = "file")
has_problem :: proc(problems: [dynamic]string, part: string) -> bool {
	for problem in problems {
		if strings.contains(problem, part) {
			return true
		}
	}
	return false
}

@(test)
changelog_well_formed_is_read :: proc(t: ^testing.T) {
	changelog, problems := changelog_parse(GOOD_CHANGELOG)
	testing.expect_value(t, len(problems), 0)
	testing.expect_value(t, len(changelog.releases), 2)
	testing.expect_value(t, changelog.releases[0].number, Release_Number{0, 2, 0})
	testing.expect_value(t, changelog.releases[0].date, "2026-11-11")
	testing.expect_value(t, changelog.releases[0].time_of_day, "09:05")
	// An old heading keeps its day alone.
	testing.expect_value(t, changelog.releases[1].time_of_day, "")
	testing.expect_value(t, len(changelog.releases[0].entries), 2)
	testing.expect_value(t, entry_joined(changelog.releases[0].entries[0].lines), "**Two**: a thing on two lines.")
	testing.expect_value(t, changelog.releases[0].entries[1].type_index, 4)
	testing.expect_value(t, changelog.releases[1].line, 16)
	testing.expect_value(t, changelog.first_release_line, 4)
	testing.expect_value(t, changelog.first_link_line, 21)
	testing.expect_value(t, len(changelog.links), 2)
	testing.expect_value(t, changelog.links[1].line, 23)
	// The last release ends at the links: its one entry is its own.
	testing.expect_value(t, len(changelog.releases[1].entries), 1)
	_, one_problems := changelog_parse(ONE_RELEASE)
	testing.expectf(t, len(one_problems) == 0, "%v", one_problems)
}

@(test)
release_heading_is_read :: proc(t: ^testing.T) {
	number, date, time_of_day, ok := release_heading_parse("## [0.93.0] - 2026-11-15 18:48")
	testing.expect(t, ok)
	testing.expect_value(t, number, Release_Number{0, 93, 0})
	testing.expect_value(t, date, "2026-11-15")
	testing.expect_value(t, time_of_day, "18:48")
	_, old_date, old_time, old_ok := release_heading_parse("## [0.58.0] - 2026-11-11")
	testing.expect(t, old_ok)
	testing.expect_value(t, old_date, "2026-11-11")
	testing.expect_value(t, old_time, "")
	bad_headings := []string {
		"## [0.93.0] - 2026-11-15 24:00",
		"## [0.93.0] - 2026-11-15 18:60",
		"## [0.93.0] - 2026-11-15T18:48",
		"## [0.93.0] - 2026-11-15 18:48:00",
		"## [0.93.0] - 2026-11-15 8:48",
		"## [0.93.0] - 2026-11-15 18-48",
		"## [0.93.0] - 2026-11-15 ab:cd",
		"## [0.93.0] - 2026-02-30 18:48",
		"## [0.93.0] -  2026-11-15",
	}
	for bad in bad_headings {
		_, _, _, bad_ok := release_heading_parse(bad)
		testing.expectf(t, !bad_ok, "%q is not a release heading", bad)
	}
	testing.expect_value(t, release_heading_text({0, 93, 0}, "2026-11-15 18:48"), "## [0.93.0] - 2026-11-15 18:48")
	// The release time of a moment is in UTC: 1794658124 is 2026-11-14 12:08:44 UTC.
	testing.expect_value(t, release_time_text(time.unix(1794658124, 0)), "2026-11-14 12:08")
	timed := Changelog_Release{date = "2026-11-15", time_of_day = "08:05"}
	day_alone := Changelog_Release{date = "2026-11-15"}
	testing.expect_value(t, release_moment(timed), "2026-11-15 08:05")
	testing.expect_value(t, release_moment(day_alone), "2026-11-15")
	testing.expect_value(t, release_moment_shown(timed), "2026-11-15 08:05 UTC")
	testing.expect_value(t, release_moment_shown(day_alone), "2026-11-15")
	testing.expect_value(t, release_moment_attribute(timed), "2026-11-15T08:05Z")
	testing.expect_value(t, release_moment_atom(timed), "2026-11-15T08:05:00Z")
	testing.expect_value(t, release_moment_atom(day_alone), "2026-11-15T00:00:00Z")
	// Two times of one day keep their order; a day alone compares by its day.
	testing.expect(t, release_after(Changelog_Release{date = "2026-11-15", time_of_day = "18:48"}, timed))
	testing.expect(t, !release_after(timed, Changelog_Release{date = "2026-11-15", time_of_day = "18:48"}))
	testing.expect(t, !release_after(day_alone, timed))
	testing.expect(t, release_after(Changelog_Release{date = "2026-11-16"}, timed))
}

@(test)
release_links_are_checked :: proc(t: ^testing.T) {
	testing.expect_value(t, release_link_text({0, 93, 0}), "[0.93.0]: https://github.com/sachahjkl/modus/releases/tag/v0.93.0")
	testing.expect_value(t, release_tag_name({0, 93, 0}), "v0.93.0")
	two :: "# Changelog\n\n## [0.2.0] - 2026-11-11 09:05\n\n### Added\n\n- Two.\n\n## [0.1.0] - 2026-11-10\n\n### Added\n\n- One.\n\n"
	link_two :: "[0.2.0]: https://github.com/sachahjkl/modus/releases/tag/v0.2.0\n"
	link_one :: "[0.1.0]: https://github.com/sachahjkl/modus/releases/tag/v0.1.0\n"
	Case :: struct {
		content, expected: string,
	}
	cases := []Case {
		{two + link_two, "line 9: the release 0.1.0 has no release link"},
		{two + link_one + link_two, "line 15: the release link \"[0.2.0]: https://github.com/sachahjkl/modus/releases/tag/v0.2.0\" is expected here"},
		{two + link_two + link_one + "[0.0.1]: https://github.com/sachahjkl/modus/releases/tag/v0.0.1\n", "line 17: a release link for no release"},
		{two + link_two + "[0.1.0]: https://example.com/v0.1.0\n", "line 16: the release link \"[0.1.0]: https://github.com/sachahjkl/modus/releases/tag/v0.1.0\" is expected here"},
		{two + link_two + "\n" + link_one, "line 17: an empty line between two release links"},
		{two + link_two + link_one + "More text.\n", "line 17: after the first release link, each line is a release link"},
		{two + link_two + link_one + "## [0.0.1] - 2026-11-09\n", "line 17: after the first release link"},
	}
	for test_case in cases {
		_, problems := changelog_parse(test_case.content)
		testing.expectf(t, has_problem(problems, test_case.expected), "%q: the problem %q is expected, the problems are %v", test_case.content, test_case.expected, problems)
	}
	_, good_problems := changelog_parse(two + link_two + link_one)
	testing.expectf(t, len(good_problems) == 0, "%v", good_problems)
	// The newest release has its time.
	_, day_problems := changelog_parse("# Changelog\n\n## [0.1.0] - 2026-11-10\n\n### Added\n\n- One.\n\n" + link_one)
	testing.expect(t, has_problem(day_problems, "line 3: the newest release 0.1.0 has its day alone"))
	// The links are written for each heading, in the order of the headings,
	// and the links that the text had are replaced.
	testing.expect_value(t, changelog_with_all_release_links(two), two + link_two + link_one)
	testing.expect_value(t, changelog_with_all_release_links(two + link_one), two + link_two + link_one)
	testing.expect_value(t, changelog_with_all_release_links(two + link_two + link_one), two + link_two + link_one)
	testing.expect_value(t, changelog_with_all_release_links("# Changelog\n\nThe preamble.\n"), "# Changelog\n\nThe preamble.\n")
}

@(test)
release_time_comes_from_the_records_of_git :: proc(t: ^testing.T) {
	commands := release_record_commands({0, 92, 0})
	testing.expect_value(t, len(commands), 3)
	testing.expect_value(t, strings.join(commands[0], " ", context.temp_allocator), "git log -1 --format=%ct %cI refs/tags/v0.92.0 --")
	testing.expect_value(t, strings.join(commands[1], " ", context.temp_allocator), "git log --diff-merges=first-parent --no-patch -SRELEASE_NUMBER :: \"0.92.0\" --format=%ct %cI -- " + RELEASE_NUMBER_SOURCE_PATTERN)
	testing.expect_value(t, strings.join(commands[2], " ", context.temp_allocator), "git log --diff-merges=first-parent --no-patch -S## [0.92.0] -  --format=%ct %cI -- " + CHANGELOG_FILE)
	// The last line is the oldest commit; its UTC time, and its day in the
	// zone of the committer.
	moment, committer_day, ok := release_record_parse("1794700000 2026-11-15T00:46:40+01:00\n1794658124 2026-11-14T13:08:44+01:00\n")
	testing.expect(t, ok)
	testing.expect_value(t, moment, "2026-11-14 12:08")
	testing.expect_value(t, committer_day, "2026-11-14")
	for bad in ([]string{"", "\n", "abc 2026-11-14T13:08:44+01:00\n", "1794658124\n", "1794658124 2026-13-14T13:08:44+01:00\n", "1794658124 2026\n"}) {
		_, _, bad_ok := release_record_parse(bad)
		testing.expectf(t, !bad_ok, "%q is not a record", bad)
	}
	// The first record on the day of the heading gives the time: here the
	// tag is absent, the second record is on another day, the third is right.
	outputs := []string{"", "1794700000 2026-11-15T00:46:40+01:00\n", "1794658124 2026-11-14T13:08:44+01:00\n"}
	heading, found := release_heading_with_record({0, 92, 0}, "2026-11-14", outputs)
	testing.expect(t, found)
	testing.expect_value(t, heading, "## [0.92.0] - 2026-11-14 12:08")
	// No record on its day: the heading keeps its day alone.
	_, none_found := release_heading_with_record({0, 92, 0}, "2026-11-10", outputs)
	testing.expect(t, !none_found)
	written, line, source_found := release_number_source_parse("package release\n\nRELEASE_NUMBER :: \"0.92.0\"\n")
	testing.expect(t, source_found)
	testing.expect_value(t, written, "0.92.0")
	testing.expect_value(t, line, 3)
}

@(test)
changelog_faults_are_named_with_their_line :: proc(t: ^testing.T) {
	Case :: struct {
		content, expected: string,
	}
	cases := []Case {
		{"# Change log\n", "line 1: the title"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n\n### Added\n\n- One.", "end with one line feed"},
		{"# Changelog\n\n## [0.1] - 2026-11-10\n\n### Added\n\n- One.\n", "line 3: the heading"},
		{"# Changelog\n\n## [0.1.0] - 2026-02-30\n\n### Added\n\n- One.\n", "line 3: the heading"},
		{"# Changelog\n\n## [0.01.0] - 2026-11-10\n\n### Added\n\n- One.\n", "line 3: the heading"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n\n### Added\n\n- One.\n\n## [0.2.0] - 2026-11-10\n\n### Added\n\n- Two.\n", "line 9: the release 0.2.0 is not older"},
		{"# Changelog\n\n## [0.2.0] - 2026-11-10\n\n### Added\n\n- One.\n\n## [0.1.0] - 2026-11-11\n\n### Added\n\n- Two.\n", "line 9: the release time 2026-11-11 is after"},
		{"# Changelog\n\n## [0.2.0] - 2026-11-10 08:00\n\n### Added\n\n- One.\n\n## [0.1.0] - 2026-11-10 09:00\n\n### Added\n\n- Two.\n", "line 9: the release time 2026-11-10 09:00 is after"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10 8:00\n\n### Added\n\n- One.\n", "line 3: the heading"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n\n### Fixed\n\n- One.\n\n### Added\n\n- Two.\n", "line 9: the parts of a release are in the order"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n\n### Added\n\n- One.\n\n### Added\n\n- Two.\n", "line 9: the parts of a release are in the order"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n\n### Improved\n\n- One.\n", "line 5: the type \"Improved\" is not known"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n\n### Added\n\n### Fixed\n\n- One.\n", "line 5: the part has no entry"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n\n## [0.0.1] - 2026-11-10\n\n### Added\n\n- One.\n", "line 3: the release 0.1.0 has no entry"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n### Added\n\n- One.\n", "line 4: an empty line is expected before a heading"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n\n### Added\n- One.\n", "line 6: an empty line is expected after a heading"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n\n### Added\n\n- One.\n\n\n- Two.\n", "line 9: a second empty line"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n\n### Added\n\n- One.\nnot indented\n", "line 8: an entry \"- <text>\""},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n\n### Added\n\n- One. \n", "line 7: the line has a tab"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n\n#### Added\n\n- One.\n", "line 5: a heading of the level 2"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n\n- One.\n", "line 5: an entry before the heading of its type"},
	}
	for test_case in cases {
		_, problems := changelog_parse(test_case.content)
		testing.expectf(t, has_problem(problems, test_case.expected), "%q: the problem %q is expected, the problems are %v", test_case.content, test_case.expected, problems)
	}
}

@(test)
fragment_well_formed_is_read :: proc(t: ^testing.T) {
	fragment, problems := fragment_parse("20261111-120000-thing.md", "type: Fixed\n\n**A thing**: it works\nnow.\n")
	testing.expect_value(t, len(problems), 0)
	testing.expect_value(t, fragment.type_index, 4)
	testing.expect_value(t, len(fragment.lines), 2)
	written, written_problems := fragment_parse("20261111-120000-thing.md", fragment_text("Added", "  one line  "))
	testing.expect_value(t, len(written_problems), 0)
	testing.expect_value(t, written.lines[0], "one line")
}

@(test)
fragment_hostile_is_refused :: proc(t: ^testing.T) {
	Case :: struct {
		file_name, content, expected: string,
	}
	good :: "type: Added\n\nText.\n"
	cases := []Case {
		{"thing.md", good, "the name of a fragment is"},
		{"20261111-120000-thing.txt", good, "the name of a fragment is"},
		{"20261311-120000-thing.md", good, "is not a date of the calendar"},
		{"20261111-250000-thing.md", good, "is not a time of the day"},
		{"20261111-120000-Thing.md", good, "only the lowercase letters"},
		{"20261111-120000-a/b.md", good, "only the lowercase letters"},
		{"20261111-120000--thing.md", good, "starts or ends with -"},
		{"20261111-120000-a--b.md", good, "starts or ends with -"},
		{"20261111-120000-.md", good, "the name of a fragment is"},
		{"20261111-120000-thing.md", "", "line 1: the line \"type: <type>\""},
		{"20261111-120000-thing.md", "Added\n\nText.\n", "line 1: the line \"type: <type>\""},
		{"20261111-120000-thing.md", "type: added\n\nText.\n", "the type \"added\" is not known"},
		{"20261111-120000-thing.md", "type: Improved\n\nText.\n", "the type \"Improved\" is not known"},
		{"20261111-120000-thing.md", "type: Added\nText.\n", "line 2: an empty line is expected"},
		{"20261111-120000-thing.md", "type: Added\n\n", "line 3: the text of the change is expected"},
		{"20261111-120000-thing.md", "type: Added\n\n   \n", "line 3: the text of the change is expected"},
		{"20261111-120000-thing.md", "type: Added\n", "line 2: an empty line is expected"},
		{"20261111-120000-thing.md", "type: Added\n\nOne.\n\nTwo.\n", "line 4: an empty line inside the text"},
		{"20261111-120000-thing.md", "type: Added\n\nOne.\n- Two.\n", "line 4: the line starts with \"- \""},
		{"20261111-120000-thing.md", "type: Added\n\n## Heading\n", "line 3: the line is a heading"},
		{"20261111-120000-thing.md", "type: Added\n\nOne.\r\n", "line 3: the line has a tab or a carriage return"},
		{"20261111-120000-thing.md", "type: Added\n\nOne\tTwo.\n", "line 3: the line has a tab"},
		{"20261111-120000-thing.md", "type: Added\n\n  One.\n", "line 3: the line starts with a space"},
	}
	for test_case in cases {
		_, problems := fragment_parse(test_case.file_name, test_case.content)
		testing.expectf(t, has_problem(problems, test_case.expected), "%s %q: the problem %q is expected, the problems are %v", test_case.file_name, test_case.content, test_case.expected, problems)
	}
}

@(test)
release_is_assembled_in_the_fixed_order :: proc(t: ^testing.T) {
	fragments := []Fragment {
		{file_name = "20261112-090000-later-fix.md", type_index = 4, lines = {"A later fix."}},
		{file_name = "20261112-080000-security.md", type_index = 5, lines = {"A closed fault."}},
		// Two fragments of the same second: the subject decides.
		{file_name = "20261112-080000-zeta.md", type_index = 0, lines = {"Zeta.", "On two lines."}},
		{file_name = "20261112-080000-alpha.md", type_index = 0, lines = {"Alpha."}},
		{file_name = "20261112-070000-early-fix.md", type_index = 4, lines = {"An early fix."}},
		{file_name = "20261112-100000-change.md", type_index = 1, lines = {"A change."}},
	}
	fragments_in_release_order(fragments)
	section := release_section_text({0, 3, 0}, "2026-11-12 10:00", fragments)
	expected :: `## [0.3.0] - 2026-11-12 10:00

### Added

- Alpha.
- Zeta.
  On two lines.

### Changed

- A change.

### Fixed

- An early fix.
- A later fix.

### Security

- A closed fault.
`
	testing.expect_value(t, section, expected)
	old, _ := changelog_parse(GOOD_CHANGELOG)
	content := changelog_with_release(old, {0, 3, 0}, section)
	changelog, problems := changelog_parse(content)
	testing.expectf(t, len(problems) == 0, "%v", problems)
	testing.expect_value(t, len(changelog.releases), 3)
	testing.expect_value(t, changelog.releases[0].number, Release_Number{0, 3, 0})
	testing.expect_value(t, changelog.releases[0].time_of_day, "10:00")
	testing.expect_value(t, len(changelog.releases[0].entries), 6)
	// The older releases follow unchanged, then the new link above the others.
	good_changelog := GOOD_CHANGELOG
	older := good_changelog[strings.index(good_changelog, "## [0.2.0]"):strings.index(good_changelog, "[0.2.0]: ")]
	testing.expect(t, strings.contains(content, older))
	testing.expect(t, strings.has_suffix(content, "- One.\n\n[0.3.0]: https://github.com/sachahjkl/modus/releases/tag/v0.3.0\n[0.2.0]: https://github.com/sachahjkl/modus/releases/tag/v0.2.0\n[0.1.0]: https://github.com/sachahjkl/modus/releases/tag/v0.1.0\n"), content)
	testing.expect_value(t, len(changelog.links), 3)
	// A first release in a changelog with no release.
	empty, empty_problems := changelog_parse("# Changelog\n\nThe preamble.\n")
	testing.expect_value(t, len(empty_problems), 0)
	first_content := changelog_with_release(empty, {0, 3, 0}, section)
	first, first_problems := changelog_parse(first_content)
	testing.expectf(t, len(first_problems) == 0, "%v", first_problems)
	testing.expect_value(t, len(first.releases), 1)
	testing.expect(t, strings.has_suffix(first_content, "- A closed fault.\n\n[0.3.0]: https://github.com/sachahjkl/modus/releases/tag/v0.3.0\n"), first_content)
}

@(test)
released_fragment_is_refused :: proc(t: ^testing.T) {
	changelog, _ := changelog_parse(GOOD_CHANGELOG)
	fragments := []Fragment {
		{file_name = "20261112-080000-again.md", type_index = 0, lines = {"**Two**: a thing on", "two lines."}},
		{file_name = "20261112-080000-new.md", type_index = 0, lines = {"New."}},
	}
	problems := make([dynamic]string, context.temp_allocator)
	released_fragment_problems(changelog, fragments, &problems)
	testing.expect_value(t, len(problems), 1)
	testing.expect(t, has_problem(problems, "changelog.d/20261112-080000-again.md: its text is already an entry of the release 0.2.0"))
}

@(test)
fragment_folder_is_read :: proc(t: ^testing.T) {
	folder :: BUILD_FOLDER + "/test_changelog_fragments"
	_ = os.remove_all(folder)
	testing.expect(t, make_folder(folder))
	defer os.remove_all(folder)
	problems := make([dynamic]string, context.temp_allocator)
	// An empty folder: no fragment, no problem.
	testing.expect_value(t, len(fragments_read(folder, &problems)), 0)
	testing.expect_value(t, len(problems), 0)
	_ = os.write_entire_file(folder + "/" + FRAGMENT_FOLDER_GUIDE, transmute([]u8)string("# changelog.d\n"))
	_ = os.write_entire_file(folder + "/20261112-080000-b.md", transmute([]u8)string("type: Fixed\n\nB.\n"))
	_ = os.write_entire_file(folder + "/20261112-080000-a.md", transmute([]u8)string("type: Added\n\nA.\n"))
	_ = os.write_entire_file(folder + "/notes.txt", transmute([]u8)string("type: Added\n\nA.\n"))
	_ = os.make_directory(folder + "/inner")
	fragments := fragments_read(folder, &problems)
	testing.expect_value(t, len(fragments), 3)
	testing.expect_value(t, fragments[0].file_name, "20261112-080000-a.md")
	testing.expect_value(t, len(problems), 2)
	testing.expect(t, has_problem(problems, "inner: a folder"))
	testing.expect(t, has_problem(problems, "notes.txt: the name of a fragment is"))
}

@(test)
release_number_is_read :: proc(t: ^testing.T) {
	number, ok := release_number_parse("0.58.0")
	testing.expect(t, ok)
	testing.expect_value(t, number, Release_Number{0, 58, 0})
	for bad in ([]string{"", "0.58", "0.58.0.1", "0.058.0", "a.b.c", "0..1", "-1.0.0", "0.58.0-rc"}) {
		_, bad_ok := release_number_parse(bad)
		testing.expectf(t, !bad_ok, "%q is not a release number", bad)
	}
	testing.expect(t, release_number_less({0, 58, 0}, {0, 58, 1}))
	testing.expect(t, release_number_less({0, 58, 1}, {0, 59, 0}))
	testing.expect(t, !release_number_less({0, 59, 0}, {0, 59, 0}))
}
