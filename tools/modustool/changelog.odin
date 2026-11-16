// The changelog of the system (docs/GLOSSARY.md, "Changelog", "Release",
// "Fragment"). CHANGELOG.md holds the releases, newest first, in the format
// of Keep a Changelog 1.1.0. A branch never edits it: it adds fragments in
// changelog.d/, one file for each change that a reader notices, so two
// branches never change the same lines. `modustool changelog release`
// moves the fragments into a new release; `modustool ship` calls it, then
// commits, tags and pushes the release (src/md/infrastructure/releases.md).
//
//   modustool changelog new <type> <subject> "<text>"   write one fragment
//   modustool changelog new <type> <subject> -          the same, with the text from the standard input
//   modustool changelog check                           every fragment and CHANGELOG.md well formed
//   modustool changelog assemble                        print what the next release brings
//   modustool changelog release <release number>        write the release with its UTC time and its link, set RELEASE_NUMBER, delete the fragments, copy the measure record to the measure history
//   modustool changelog notes <release number>          print one release
//   modustool changelog times                           give each old heading its time from git, add the missing release links
//
// The structure of CHANGELOG.md is strict, so that a page of the site can be
// made from it: `check` refuses each line that is not in its place.
package modustool

import "modus:contract/release"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"

CHANGELOG_FILE :: "CHANGELOG.md"
FRAGMENT_FOLDER :: "changelog.d"
// The one file of the fragment folder that is not a fragment.
FRAGMENT_FOLDER_GUIDE :: "README.md"
RELEASE_NUMBER_SOURCE :: SOURCE_FOLDER_CONTRACT + "/release/release.odin"
// The source of the release number in every place that it ever had: the
// file moved once, and the record of an old release is in the old path. In
// a git pathspec, `*` also matches `/`.
RELEASE_NUMBER_SOURCE_PATTERN :: "*release/release.odin"
RELEASE_NUMBER_LINE_START :: "RELEASE_NUMBER :: "
// The release tag is this prefix and the release number.
RELEASE_TAG_PREFIX :: "v"
// A release link is "[<number>]: " then this address, the prefix and the number.
RELEASE_LINK_ADDRESS_START :: SITE_REPOSITORY_ADDRESS + "/releases/tag/" + RELEASE_TAG_PREFIX
// "yyyy-mm-dd" and "yyyy-mm-dd hh:mm": the two lengths of the moment of a heading.
RELEASE_DAY_LENGTH :: 10
RELEASE_TIME_LENGTH :: 16
CHANGELOG_TITLE :: "# Changelog"
// The longest subject of a fragment name.
FRAGMENT_SUBJECT_MOST :: 48
// "yyyymmdd-hhmmss-": the time at the start of a fragment name.
FRAGMENT_TIME_LENGTH :: 16

// The types of change of Keep a Changelog, in the order of the parts of a release.
CHANGE_TYPES :: [6]string{"Added", "Changed", "Deprecated", "Removed", "Fixed", "Security"}

Release_Number :: struct {
	major, minor, patch: int,
}

// One fragment: one change, as one entry of a release.
Fragment :: struct {
	file_name:  string,
	type_index: int, // An index of CHANGE_TYPES.
	// The lines of the entry, with no "- " and no indentation.
	lines:      []string,
}

// One entry of a release of CHANGELOG.md.
Changelog_Entry :: struct {
	type_index: int,
	lines:      []string,
	line:       int, // The line of its "- ", from 1.
}

Changelog_Release :: struct {
	number:      Release_Number,
	date:        string, // yyyy-mm-dd, in UTC when time_of_day is set.
	// hh:mm in UTC, or "" for an old heading whose time no record holds.
	time_of_day: string,
	line:        int, // The line of its heading, from 1.
	entries:     []Changelog_Entry,
}

// One release link at the end of the file.
Changelog_Link :: struct {
	text: string,
	line: int, // From 1.
}

Changelog :: struct {
	lines:              []string,
	// The index in lines of the heading of the newest release, or len(lines).
	first_release_line: int,
	// The index in lines of the first release link, or len(lines).
	first_link_line:    int,
	releases:           []Changelog_Release, // Newest first.
	links:              []Changelog_Link,
}

run_changelog :: proc(args: []string) -> int {
	usage_text :: "modustool changelog new <type> <subject> \"<text>\" | check | assemble | release <release number> | notes <release number> | times"
	if len(args) == 0 {
		fmt.eprintln(usage_text)
		return EXIT_USAGE
	}
	switch args[0] {
	case "new":
		if len(args) != 4 {
			fmt.eprintln("modustool: changelog new <type> <subject> \"<text>\": three arguments are expected")
			return EXIT_USAGE
		}
		text := args[3]
		// "-": the text comes from the standard input. `odin run` gives
		// the arguments to a shell, which runs the `...` of a text.
		if text == "-" {
			input, err := os.read_entire_file(os.stdin, context.temp_allocator)
			if err != nil {
				fmt.eprintfln("modustool: cannot read the standard input: %v", err)
				return EXIT_FAILURE
			}
			text = string(input)
		}
		return changelog_new(args[1], args[2], text) ? 0 : EXIT_FAILURE
	case "check":
		return changelog_check() ? 0 : EXIT_FAILURE
	case "assemble":
		return changelog_assemble() ? 0 : EXIT_FAILURE
	case "release":
		if len(args) != 2 {
			fmt.eprintln("modustool: changelog release <release number>: one argument is expected, such as 0.59.0")
			return EXIT_USAGE
		}
		return changelog_release(args[1]) ? 0 : EXIT_FAILURE
	case "notes":
		if len(args) != 2 {
			fmt.eprintln("modustool: changelog notes <release number>: one argument is expected, such as 0.58.0")
			return EXIT_USAGE
		}
		return changelog_notes(args[1]) ? 0 : EXIT_FAILURE
	case "times":
		if len(args) != 1 {
			fmt.eprintln("modustool: changelog times takes no argument")
			return EXIT_USAGE
		}
		return changelog_times() ? 0 : EXIT_FAILURE
	}
	fmt.eprintfln("modustool: changelog has no command %s", args[0])
	fmt.eprintln(usage_text)
	return EXIT_USAGE
}

run_release_number :: proc(args: []string) -> int {
	fmt.println(release.RELEASE_NUMBER)
	return 0
}

// The parts of the text, the same for the tool and its tests.

release_number_parse :: proc(text: string) -> (number: Release_Number, ok: bool) {
	parts := strings.split(text, ".", context.temp_allocator)
	if len(parts) != 3 {
		return {}, false
	}
	values: [3]int
	for part, index in parts {
		if len(part) == 0 || len(part) > 6 || (len(part) > 1 && part[0] == '0') {
			return {}, false
		}
		for character in transmute([]u8)part {
			if character < '0' || character > '9' {
				return {}, false
			}
		}
		values[index], _ = strconv.parse_int(part, 10)
	}
	return {values[0], values[1], values[2]}, true
}

release_number_text :: proc(number: Release_Number) -> string {
	return fmt.tprintf("%d.%d.%d", number.major, number.minor, number.patch)
}

release_number_less :: proc(a, b: Release_Number) -> bool {
	if a.major != b.major {
		return a.major < b.major
	}
	if a.minor != b.minor {
		return a.minor < b.minor
	}
	return a.patch < b.patch
}

change_type_index :: proc(name: string) -> int {
	types := CHANGE_TYPES
	for type_name, index in types {
		if type_name == name {
			return index
		}
	}
	return -1
}

// digits_value reads a field of digits only; -1 if one byte is not a digit.
digits_value :: proc(text: string) -> int {
	value := 0
	for character in transmute([]u8)text {
		if character < '0' || character > '9' {
			return -1
		}
		value = value * 10 + int(character - '0')
	}
	return value
}

// date_valid checks a date of the calendar, in the years 2000 to 2999.
date_valid :: proc(year, month, day: int) -> bool {
	if year < 2000 || year > 2999 || month < 1 || month > 12 || day < 1 {
		return false
	}
	days := [12]int{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
	if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) {
		days[1] = 29
	}
	return day <= days[month - 1]
}

// date_text_valid checks "yyyy-mm-dd".
date_text_valid :: proc(text: string) -> bool {
	if len(text) != 10 || text[4] != '-' || text[7] != '-' {
		return false
	}
	return date_valid(digits_value(text[0:4]), digits_value(text[5:7]), digits_value(text[8:10]))
}

// time_of_day_text_valid checks "hh:mm".
time_of_day_text_valid :: proc(text: string) -> bool {
	if len(text) != 5 || text[2] != ':' {
		return false
	}
	hour, minute := digits_value(text[0:2]), digits_value(text[3:5])
	return hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59
}

// release_time_text gives the release time of a moment, as a heading writes
// it: the day and the minute in UTC, "2026-11-15 18:48". The heading has no
// zone, so the zone is fixed: two hosts in two zones write times that compare.
release_time_text :: proc(moment: time.Time) -> string {
	year, month, day := time.date(moment)
	hour, minute, _ := time.clock(moment)
	return fmt.tprintf("%04d-%02d-%02d %02d:%02d", year, int(month), day, hour, minute)
}

// release_moment gives the moment of a heading: "yyyy-mm-dd hh:mm", or the
// day alone for an old heading.
release_moment :: proc(changelog_release: Changelog_Release) -> string {
	if changelog_release.time_of_day == "" {
		return changelog_release.date
	}
	return fmt.tprintf("%s %s", changelog_release.date, changelog_release.time_of_day)
}

// release_moment_shown gives the moment as a page shows it, with its zone.
release_moment_shown :: proc(changelog_release: Changelog_Release) -> string {
	if changelog_release.time_of_day == "" {
		return changelog_release.date
	}
	return fmt.tprintf("%s %s UTC", changelog_release.date, changelog_release.time_of_day)
}

// release_moment_attribute gives the moment for the attribute datetime of
// HTML: "2026-11-15T18:48Z", or the day alone.
release_moment_attribute :: proc(changelog_release: Changelog_Release) -> string {
	if changelog_release.time_of_day == "" {
		return changelog_release.date
	}
	return fmt.tprintf("%sT%sZ", changelog_release.date, changelog_release.time_of_day)
}

// release_moment_atom gives the moment for a feed (RFC 3339). An old heading
// with its day alone gives the start of its day.
release_moment_atom :: proc(changelog_release: Changelog_Release) -> string {
	time_of_day := changelog_release.time_of_day == "" ? "00:00" : changelog_release.time_of_day
	return fmt.tprintf("%sT%s:00Z", changelog_release.date, time_of_day)
}

// release_after tells if the moment of a release is after the moment of
// another. When one of the two has its day alone, the days decide.
release_after :: proc(a, b: Changelog_Release) -> bool {
	if a.time_of_day == "" || b.time_of_day == "" {
		return a.date > b.date
	}
	return release_moment(a) > release_moment(b)
}

release_tag_name :: proc(number: Release_Number) -> string {
	return fmt.tprintf("%s%s", RELEASE_TAG_PREFIX, release_number_text(number))
}

// release_link_text gives the release link of a release.
release_link_text :: proc(number: Release_Number) -> string {
	text := release_number_text(number)
	return fmt.tprintf("[%s]: %s%s", text, RELEASE_LINK_ADDRESS_START, text)
}

// release_link_line_is tells if a line has the form of a link definition of
// Markdown, "[label]: address": the form of a release link.
release_link_line_is :: proc(line: string) -> bool {
	return strings.has_prefix(line, "[") && strings.contains(line, "]: ")
}

// subject_problem gives the fault of a subject of a fragment name, or "".
subject_problem :: proc(subject: string) -> string {
	if len(subject) == 0 {
		return "the subject is empty"
	}
	if len(subject) > FRAGMENT_SUBJECT_MOST {
		return fmt.tprintf("the subject has %d bytes; it can have at most %d", len(subject), FRAGMENT_SUBJECT_MOST)
	}
	for character in transmute([]u8)subject {
		if !((character >= 'a' && character <= 'z') || (character >= '0' && character <= '9') || character == '-') {
			return fmt.tprintf("the subject has the byte %q; it can have only the lowercase letters a to z, the digits and -", rune(character))
		}
	}
	if subject[0] == '-' || subject[len(subject) - 1] == '-' || strings.contains(subject, "--") {
		return "the subject starts or ends with -, or has -- in it"
	}
	return ""
}

// fragment_name_problem gives the fault of the name of a fragment file, or "".
fragment_name_problem :: proc(file_name: string) -> string {
	expected :: "the name of a fragment is <yyyymmdd-hhmmss>-<subject>.md"
	if !strings.has_suffix(file_name, ".md") || len(file_name) <= FRAGMENT_TIME_LENGTH + len(".md") {
		return expected
	}
	stamp := file_name[:FRAGMENT_TIME_LENGTH]
	if stamp[8] != '-' || stamp[15] != '-' {
		return expected
	}
	if !date_valid(digits_value(stamp[0:4]), digits_value(stamp[4:6]), digits_value(stamp[6:8])) {
		return fmt.tprintf("%s: %s is not a date of the calendar", expected, stamp[0:8])
	}
	hour, minute, second := digits_value(stamp[9:11]), digits_value(stamp[11:13]), digits_value(stamp[13:15])
	if hour < 0 || hour > 23 || minute < 0 || minute > 59 || second < 0 || second > 59 {
		return fmt.tprintf("%s: %s is not a time of the day", expected, stamp[9:15])
	}
	if problem := subject_problem(file_name[FRAGMENT_TIME_LENGTH:len(file_name) - len(".md")]); problem != "" {
		return fmt.tprintf("%s: %s", expected, problem)
	}
	return ""
}

// entry_line_problem gives the fault of one line of the text of an entry, or "".
entry_line_problem :: proc(line: string) -> string {
	switch {
	case strings.contains_any(line, "\t\r"):
		return "the line has a tab or a carriage return"
	case strings.has_prefix(line, "#"):
		return "the line is a heading; the type of the fragment gives the part of the release"
	case strings.has_prefix(line, "- ") || strings.has_prefix(line, "* "):
		return "the line starts with \"- \": a fragment is one entry, and the tool writes its \"- \""
	case strings.has_prefix(line, " "):
		return "the line starts with a space; the tool indents the lines of an entry"
	case strings.has_suffix(line, " "):
		return "the line ends with a space"
	}
	return ""
}

// fragment_parse reads a fragment. Each problem is one sentence that names
// the file and the line.
fragment_parse :: proc(file_name: string, content: string) -> (fragment: Fragment, problems: [dynamic]string) {
	problems = make([dynamic]string, context.temp_allocator)
	fragment.file_name = file_name
	fragment.type_index = -1
	place := strings.concatenate({FRAGMENT_FOLDER, "/", file_name}, context.temp_allocator)
	if problem := fragment_name_problem(file_name); problem != "" {
		append(&problems, fmt.tprintf("%s: %s", place, problem))
	}
	lines := strings.split(content, "\n", context.temp_allocator)
	if len(lines) > 0 && lines[len(lines) - 1] == "" {
		lines = lines[:len(lines) - 1]
	}
	if len(lines) == 0 || !strings.has_prefix(lines[0], "type: ") {
		append(&problems, fmt.tprintf("%s, line 1: the line \"type: <type>\" is expected, with a type of Added, Changed, Deprecated, Removed, Fixed, Security", place))
		return
	}
	type_name := lines[0][len("type: "):]
	fragment.type_index = change_type_index(type_name)
	if fragment.type_index < 0 {
		append(&problems, fmt.tprintf("%s, line 1: the type %q is not known; the types are Added, Changed, Deprecated, Removed, Fixed, Security", place, type_name))
	}
	if len(lines) < 2 || lines[1] != "" {
		append(&problems, fmt.tprintf("%s, line 2: an empty line is expected after the type", place))
		return
	}
	text := lines[2:]
	if len(text) == 0 || strings.trim_space(text[0]) == "" {
		append(&problems, fmt.tprintf("%s, line 3: the text of the change is expected; it is empty", place))
		return
	}
	for line, index in text {
		if line == "" {
			append(&problems, fmt.tprintf("%s, line %d: an empty line inside the text; the text of a change is one paragraph", place, index + 3))
			continue
		}
		if problem := entry_line_problem(line); problem != "" {
			append(&problems, fmt.tprintf("%s, line %d: %s", place, index + 3, problem))
		}
	}
	fragment.lines = text
	return
}

// fragment_text gives the text of a fragment file.
fragment_text :: proc(type_name: string, text: string) -> string {
	return fmt.tprintf("type: %s\n\n%s\n", type_name, strings.trim_space(text))
}

// entry_joined gives the text of an entry in one line: the form that two
// entries are compared in.
entry_joined :: proc(lines: []string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for line, index in lines {
		if index > 0 {
			strings.write_byte(&builder, ' ')
		}
		strings.write_string(&builder, strings.trim_space(line))
	}
	return strings.to_string(builder)
}

// changelog_parse reads CHANGELOG.md and checks its structure:
//   line 1: "# Changelog"; then a preamble with no heading;
//   each release: "## [<major>.<minor>.<patch>] - <yyyy-mm-dd hh:mm>", an empty line;
//   then for each type, in the order of CHANGE_TYPES, at most once:
//   "### <type>", an empty line, the entries; each entry is "- <text>",
//   and the next lines of its text start with two spaces;
//   one empty line before each heading, no two empty lines, one line feed at the end;
//   the release numbers descend and the release times do not rise;
//   then an empty line and one release link for each release, in the same order.
// An old heading can have its day alone, "## [0.5.0] - 2026-11-10", when no
// record holds its time; the newest release always has its time, because
// `changelog release` writes it (src/md/infrastructure/releases.md).
changelog_parse :: proc(content: string) -> (changelog: Changelog, problems: [dynamic]string) {
	problems = make([dynamic]string, context.temp_allocator)
	if !strings.has_suffix(content, "\n") || strings.has_suffix(content, "\n\n") {
		append(&problems, fmt.tprintf("%s: the file must end with one line feed", CHANGELOG_FILE))
	}
	lines := strings.split(strings.trim_right(content, "\n"), "\n", context.temp_allocator)
	changelog.lines = lines
	changelog.first_release_line = len(lines)
	changelog.first_link_line = len(lines)
	links := make([dynamic]Changelog_Link, context.temp_allocator)
	at :: proc(problems: ^[dynamic]string, line: int, sentence: string) {
		append(problems, fmt.tprintf("%s, line %d: %s", CHANGELOG_FILE, line, sentence))
	}
	if len(lines) == 0 || lines[0] != CHANGELOG_TITLE {
		at(&problems, 1, "the title \"" + CHANGELOG_TITLE + "\" is expected")
		return
	}
	releases := make([dynamic]Changelog_Release, context.temp_allocator)
	entries := make([dynamic]Changelog_Entry, context.temp_allocator)
	entry_lines := make([dynamic]string, context.temp_allocator)
	// What the line before was.
	Previous :: enum {
		Title,
		Preamble,
		Empty,
		Release_Heading,
		Type_Heading,
		Entry,
		Link,
	}
	previous := Previous.Title
	type_index := -1
	entry_line := 0
	finish_entry :: proc(entries: ^[dynamic]Changelog_Entry, entry_lines: ^[dynamic]string, type_index, entry_line: int) {
		if len(entry_lines) > 0 {
			append(entries, Changelog_Entry{type_index = type_index, lines = slice.clone(entry_lines[:], context.temp_allocator), line = entry_line})
			clear(entry_lines)
		}
	}
	finish_release :: proc(releases: ^[dynamic]Changelog_Release, entries: ^[dynamic]Changelog_Entry, problems: ^[dynamic]string) {
		if len(releases) == 0 {
			return
		}
		last := &releases[len(releases) - 1]
		last.entries = slice.clone(entries[:], context.temp_allocator)
		clear(entries)
		if len(last.entries) == 0 {
			append(problems, fmt.tprintf("%s, line %d: the release %s has no entry", CHANGELOG_FILE, last.line, release_number_text(last.number)))
		}
	}
	type_has_entry := true
	type_heading_line := 0
	for line, index in lines {
		number := index + 1
		if line != "" && (strings.contains_any(line, "\t\r") || strings.has_suffix(line, " ")) {
			at(&problems, number, "the line has a tab, a carriage return or a space at its end")
		}
		if index == 0 {
			continue
		}
		if line == "" {
			if previous == .Empty {
				at(&problems, number, "a second empty line; one empty line separates two parts")
			}
			if previous == .Entry {
				finish_entry(&entries, &entry_lines, type_index, entry_line)
			}
			previous = .Empty
			continue
		}
		// The release links close the file: after the first one, each line
		// is a release link.
		if len(links) > 0 {
			if !release_link_line_is(line) {
				at(&problems, number, "after the first release link, each line is a release link \"[<number>]: <address>\"")
				continue
			}
			if previous == .Empty {
				at(&problems, number, "an empty line between two release links")
			}
			append(&links, Changelog_Link{text = line, line = number})
			previous = .Link
			continue
		}
		if len(releases) > 0 && previous == .Empty && release_link_line_is(line) {
			changelog.first_link_line = index
			append(&links, Changelog_Link{text = line, line = number})
			previous = .Link
			continue
		}
		if strings.has_prefix(line, "#") {
			if previous != .Empty {
				at(&problems, number, "an empty line is expected before a heading")
			}
			if strings.has_prefix(line, "## ") {
				if !type_has_entry {
					at(&problems, type_heading_line, "the part has no entry")
				}
				finish_release(&releases, &entries, &problems)
				if len(releases) == 0 {
					changelog.first_release_line = index
				}
				release_number, date, time_of_day, heading_ok := release_heading_parse(line)
				heading := Changelog_Release{number = release_number, date = date, time_of_day = time_of_day, line = number}
				if !heading_ok {
					at(&problems, number, "the heading \"## [<major>.<minor>.<patch>] - <yyyy-mm-dd hh:mm>\" of a release is expected, with a day of the calendar and a time of the day in UTC")
				} else if len(releases) > 0 {
					newer := releases[len(releases) - 1]
					if !release_number_less(release_number, newer.number) {
						at(&problems, number, fmt.tprintf("the release %s is not older than the release %s above it; the newest release is first", release_number_text(release_number), release_number_text(newer.number)))
					}
					if release_after(heading, newer) {
						at(&problems, number, fmt.tprintf("the release time %s is after the release time %s of the newer release above it, line %d", release_moment(heading), release_moment(newer), newer.line))
					}
				}
				append(&releases, heading)
				type_index = -1
				type_has_entry = true
				previous = .Release_Heading
				continue
			}
			if strings.has_prefix(line, "### ") {
				if len(releases) == 0 {
					at(&problems, number, "a part of a release before the first release heading")
				}
				if !type_has_entry {
					at(&problems, type_heading_line, "the part has no entry")
				}
				new_type := change_type_index(line[len("### "):])
				if new_type < 0 {
					at(&problems, number, fmt.tprintf("the type %q is not known; the types are Added, Changed, Deprecated, Removed, Fixed, Security", line[len("### "):]))
				} else if new_type <= type_index {
					at(&problems, number, "the parts of a release are in the order Added, Changed, Deprecated, Removed, Fixed, Security, each one at most once")
				}
				type_index = max(type_index, new_type)
				type_has_entry = false
				type_heading_line = number
				previous = .Type_Heading
				continue
			}
			at(&problems, number, "a heading of the level 2 (a release) or 3 (a type of change) is expected")
			previous = .Empty
			continue
		}
		if len(releases) == 0 {
			// The preamble: text with no heading.
			previous = .Preamble
			continue
		}
		if previous == .Release_Heading || previous == .Type_Heading {
			at(&problems, number, "an empty line is expected after a heading")
		}
		if strings.has_prefix(line, "- ") {
			if type_index < 0 {
				at(&problems, number, "an entry before the heading of its type (### Added, ...)")
			}
			if previous == .Entry {
				finish_entry(&entries, &entry_lines, type_index, entry_line)
			}
			if problem := entry_line_problem(line[2:]); problem != "" {
				at(&problems, number, problem)
			}
			append(&entry_lines, line[2:])
			entry_line = number
			type_has_entry = true
			previous = .Entry
			continue
		}
		if strings.has_prefix(line, "  ") && previous == .Entry {
			if problem := entry_line_problem(line[2:]); problem != "" {
				at(&problems, number, problem)
			}
			append(&entry_lines, line[2:])
			continue
		}
		at(&problems, number, "an entry \"- <text>\", or a line of its text that starts with two spaces, is expected")
		previous = .Entry
	}
	if previous == .Entry {
		finish_entry(&entries, &entry_lines, type_index, entry_line)
	}
	if !type_has_entry {
		at(&problems, type_heading_line, "the part has no entry")
	}
	finish_release(&releases, &entries, &problems)
	changelog.releases = releases[:]
	changelog.links = links[:]
	if len(releases) > 0 && releases[0].time_of_day == "" && releases[0].date != "" {
		at(&problems, releases[0].line, fmt.tprintf("the newest release %s has its day alone; its heading is \"## [%s] - <yyyy-mm-dd hh:mm>\", with its release time in UTC (`modustool changelog times` gives an old heading its time)", release_number_text(releases[0].number), release_number_text(releases[0].number)))
	}
	release_link_problems(changelog, &problems)
	return
}

// release_link_problems checks the release links: one for each release, in
// the order of the releases, each with the address of its release tag.
release_link_problems :: proc(changelog: Changelog, problems: ^[dynamic]string) {
	for changelog_release, index in changelog.releases {
		expected := release_link_text(changelog_release.number)
		if index >= len(changelog.links) {
			append(problems, fmt.tprintf("%s, line %d: the release %s has no release link; the end of the file needs the line %q (`modustool changelog times` adds the missing ones)", CHANGELOG_FILE, changelog_release.line, release_number_text(changelog_release.number), expected))
			continue
		}
		link := changelog.links[index]
		if link.text != expected {
			append(problems, fmt.tprintf("%s, line %d: the release link %q is expected here, one for each release in the order of the releases", CHANGELOG_FILE, link.line, expected))
		}
	}
	for link in changelog.links[min(len(changelog.releases), len(changelog.links)):] {
		append(problems, fmt.tprintf("%s, line %d: a release link for no release", CHANGELOG_FILE, link.line))
	}
}

// release_heading_parse reads "## [0.93.0] - 2026-11-15 18:48", and the old
// form with the day alone, "## [0.58.0] - 2026-11-11", whose time_of_day is "".
release_heading_parse :: proc(line: string) -> (number: Release_Number, date: string, time_of_day: string, ok: bool) {
	if !strings.has_prefix(line, "## [") {
		return
	}
	rest := line[len("## ["):]
	end := strings.index(rest, "] - ")
	if end < 0 {
		return
	}
	parsed_number, number_ok := release_number_parse(rest[:end])
	if !number_ok {
		return
	}
	moment := rest[end + len("] - "):]
	switch len(moment) {
	case RELEASE_DAY_LENGTH:
		if !date_text_valid(moment) {
			return
		}
		return parsed_number, moment, "", true
	case RELEASE_TIME_LENGTH:
		day, clock := moment[:RELEASE_DAY_LENGTH], moment[RELEASE_DAY_LENGTH + 1:]
		if moment[RELEASE_DAY_LENGTH] != ' ' || !date_text_valid(day) || !time_of_day_text_valid(clock) {
			return
		}
		return parsed_number, day, clock, true
	}
	return
}

// release_heading_text gives the heading of a release; the moment is
// "yyyy-mm-dd hh:mm" (release_time_text).
release_heading_text :: proc(number: Release_Number, moment: string) -> string {
	return fmt.tprintf("## [%s] - %s", release_number_text(number), moment)
}

// fragments_in_release_order sorts the fragments as a release lists them:
// by type in the order of CHANGE_TYPES, then by the time in the name; two
// fragments of the same second by their subject.
fragments_in_release_order :: proc(fragments: []Fragment) {
	slice.sort_by(fragments, proc(a, b: Fragment) -> bool {
		if a.type_index != b.type_index {
			return a.type_index < b.type_index
		}
		return a.file_name < b.file_name
	})
}

// release_parts_text gives the parts of a release ("### Added", ...) from
// fragments in release order.
release_parts_text :: proc(fragments: []Fragment) -> string {
	builder := strings.builder_make(context.temp_allocator)
	types := CHANGE_TYPES
	type_index := -1
	for fragment in fragments {
		if fragment.type_index != type_index {
			type_index = fragment.type_index
			if strings.builder_len(builder) > 0 {
				strings.write_string(&builder, "\n")
			}
			fmt.sbprintf(&builder, "### %s\n\n", types[type_index])
		}
		for line, index in fragment.lines {
			strings.write_string(&builder, index == 0 ? "- " : "  ")
			strings.write_string(&builder, line)
			strings.write_string(&builder, "\n")
		}
	}
	return strings.to_string(builder)
}

// release_section_text gives a whole release, with its heading; the moment
// is its release time, "yyyy-mm-dd hh:mm" (release_time_text).
release_section_text :: proc(number: Release_Number, moment: string, fragments: []Fragment) -> string {
	return fmt.tprintf("%s\n\n%s", release_heading_text(number, moment), release_parts_text(fragments))
}

// changelog_with_release gives CHANGELOG.md with a new release before the
// newest one, and its release link before the other links.
changelog_with_release :: proc(changelog: Changelog, number: Release_Number, section: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for line in changelog.lines[:changelog.first_release_line] {
		strings.write_string(&builder, line)
		strings.write_string(&builder, "\n")
	}
	if changelog.first_release_line == len(changelog.lines) && len(changelog.lines) > 0 && changelog.lines[len(changelog.lines) - 1] != "" {
		strings.write_string(&builder, "\n")
	}
	strings.write_string(&builder, section)
	// The older releases, with no empty line at their end: the links
	// follow after one empty line.
	older := changelog.lines[min(changelog.first_release_line, changelog.first_link_line):changelog.first_link_line]
	for len(older) > 0 && older[len(older) - 1] == "" {
		older = older[:len(older) - 1]
	}
	if len(older) > 0 {
		strings.write_string(&builder, "\n")
		for line in older {
			strings.write_string(&builder, line)
			strings.write_string(&builder, "\n")
		}
	}
	strings.write_string(&builder, "\n")
	strings.write_string(&builder, release_link_text(number))
	strings.write_string(&builder, "\n")
	for line in changelog.lines[changelog.first_link_line:] {
		strings.write_string(&builder, line)
		strings.write_string(&builder, "\n")
	}
	return strings.to_string(builder)
}

// changelog_with_all_release_links gives a changelog text whose release
// links are one for each release heading, in the order of the headings: the
// links that the text had are replaced. It reads the headings alone, so it
// works on a changelog that has faults elsewhere.
changelog_with_all_release_links :: proc(content: string) -> string {
	lines := strings.split(strings.trim_right(content, "\n"), "\n", context.temp_allocator)
	numbers := make([dynamic]Release_Number, context.temp_allocator)
	end := len(lines)
	for line, index in lines {
		if number, _, _, ok := release_heading_parse(line); ok {
			append(&numbers, number)
			// The links come after the last release, so a link above a
			// heading is not one of them.
			end = len(lines)
		} else if release_link_line_is(line) && len(numbers) > 0 && end == len(lines) && index > 0 && lines[index - 1] == "" {
			end = index
		}
	}
	kept := lines[:end]
	for len(kept) > 0 && kept[len(kept) - 1] == "" {
		kept = kept[:len(kept) - 1]
	}
	builder := strings.builder_make(context.temp_allocator)
	for line in kept {
		strings.write_string(&builder, line)
		strings.write_string(&builder, "\n")
	}
	if len(numbers) > 0 {
		strings.write_string(&builder, "\n")
		for number in numbers {
			strings.write_string(&builder, release_link_text(number))
			strings.write_string(&builder, "\n")
		}
	}
	return strings.to_string(builder)
}

// released_fragment_problems checks the fragments against CHANGELOG.md: no fragment
// whose text is already an entry of a release.
released_fragment_problems :: proc(changelog: Changelog, fragments: []Fragment, problems: ^[dynamic]string) {
	released := make(map[string]string, context.temp_allocator)
	for released_release in changelog.releases {
		for entry in released_release.entries {
			released[entry_joined(entry.lines)] = release_number_text(released_release.number)
		}
	}
	for fragment in fragments {
		if number, found := released[entry_joined(fragment.lines)]; found {
			append(problems, fmt.tprintf("%s/%s: its text is already an entry of the release %s; delete the fragment", FRAGMENT_FOLDER, fragment.file_name, number))
		}
	}
}

// The parts that read and write the files of the repository.

// fragments_read reads each fragment of a folder, in the order of the names.
fragments_read :: proc(folder: string, problems: ^[dynamic]string) -> []Fragment {
	fragments := make([dynamic]Fragment, context.temp_allocator)
	entries, err := os.read_all_directory_by_path(folder, context.temp_allocator)
	if err != nil {
		append(problems, fmt.tprintf("%s: cannot list the folder: %v", folder, err))
		return nil
	}
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	for entry in entries {
		if entry.name == FRAGMENT_FOLDER_GUIDE {
			continue
		}
		if entry.type == .Directory {
			append(problems, fmt.tprintf("%s/%s: a folder; the fragment folder holds only fragment files", FRAGMENT_FOLDER, entry.name))
			continue
		}
		content, read_err := os.read_entire_file(strings.concatenate({folder, "/", entry.name}, context.temp_allocator), context.temp_allocator)
		if read_err != nil {
			append(problems, fmt.tprintf("%s/%s: cannot read: %v", FRAGMENT_FOLDER, entry.name, read_err))
			continue
		}
		fragment, fragment_problems := fragment_parse(entry.name, string(content))
		append(problems, ..fragment_problems[:])
		append(&fragments, fragment)
	}
	return fragments[:]
}

changelog_read :: proc(problems: ^[dynamic]string) -> (changelog: Changelog, ok: bool) {
	content, err := os.read_entire_file(CHANGELOG_FILE, context.temp_allocator)
	if err != nil {
		append(problems, fmt.tprintf("%s: cannot read: %v", CHANGELOG_FILE, err))
		return {}, false
	}
	parse_problems: [dynamic]string
	changelog, parse_problems = changelog_parse(string(content))
	append(problems, ..parse_problems[:])
	return changelog, true
}

// release_number_source_problem compares RELEASE_NUMBER in its source with
// the newest release of CHANGELOG.md.
release_number_source_problem :: proc(changelog: Changelog) -> string {
	content, err := os.read_entire_file(RELEASE_NUMBER_SOURCE, context.temp_allocator)
	if err != nil {
		return fmt.tprintf("%s: cannot read: %v", RELEASE_NUMBER_SOURCE, err)
	}
	written, line, found := release_number_source_parse(string(content))
	if !found {
		return fmt.tprintf("%s: no line starts with %q", RELEASE_NUMBER_SOURCE, RELEASE_NUMBER_LINE_START)
	}
	if len(changelog.releases) == 0 {
		return ""
	}
	newest := release_number_text(changelog.releases[0].number)
	if written != newest {
		return fmt.tprintf("%s, line %d: RELEASE_NUMBER is %s; the newest release of %s is %s", RELEASE_NUMBER_SOURCE, line, written, CHANGELOG_FILE, newest)
	}
	return ""
}

// release_number_source_parse finds the text of RELEASE_NUMBER in its
// source, and its line from 1. The command `ship` reads the file, not the
// constant that the tool was compiled with: a merge can change the file.
release_number_source_parse :: proc(content: string) -> (written: string, line: int, found: bool) {
	for text, index in strings.split(content, "\n", context.temp_allocator) {
		if strings.has_prefix(text, RELEASE_NUMBER_LINE_START) {
			return strings.trim(strings.trim_space(text[len(RELEASE_NUMBER_LINE_START):]), "\""), index + 1, true
		}
	}
	return "", 0, false
}

problems_print :: proc(problems: []string) {
	for problem in problems {
		fmt.eprintfln("modustool: %s", problem)
	}
}

// local_date_and_time gives the date and the time of the clock of the host,
// in the time zone of the host (UTC if the tool cannot read it).
local_date_and_time :: proc() -> datetime.DateTime {
	moment, _ := time.time_to_datetime(time.now())
	region, region_ok := timezone.region_load("local", context.temp_allocator)
	if !region_ok {
		return moment
	}
	local, local_ok := timezone.datetime_to_tz(moment, region)
	return local_ok ? local : moment
}

changelog_new :: proc(type_name, subject, text: string) -> bool {
	if change_type_index(type_name) < 0 {
		fmt.eprintfln("modustool: the type %q is not known; the types are Added, Changed, Deprecated, Removed, Fixed, Security", type_name)
		return false
	}
	if problem := subject_problem(subject); problem != "" {
		fmt.eprintfln("modustool: %s", problem)
		return false
	}
	now := local_date_and_time()
	file_name := fmt.tprintf("%04d%02d%02d-%02d%02d%02d-%s.md", now.year, now.month, now.day, now.hour, now.minute, now.second, subject)
	content := fragment_text(type_name, text)
	_, problems := fragment_parse(file_name, content)
	if len(problems) > 0 {
		problems_print(problems[:])
		return false
	}
	path := strings.concatenate({FRAGMENT_FOLDER, "/", file_name}, context.temp_allocator)
	if os.exists(path) {
		fmt.eprintfln("modustool: %s exists; wait one second, or choose another subject", path)
		return false
	}
	if err := os.write_entire_file(path, transmute([]u8)content); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", path, err)
		return false
	}
	fmt.printfln("modustool: wrote %s", path)
	return true
}

// changelog_all_read reads CHANGELOG.md and the fragments, and checks all.
changelog_all_read :: proc() -> (changelog: Changelog, fragments: []Fragment, problems: [dynamic]string) {
	problems = make([dynamic]string, context.temp_allocator)
	read_ok: bool
	changelog, read_ok = changelog_read(&problems)
	fragments = fragments_read(FRAGMENT_FOLDER, &problems)
	if read_ok {
		released_fragment_problems(changelog, fragments, &problems)
		if problem := release_number_source_problem(changelog); problem != "" {
			append(&problems, problem)
		}
	}
	return
}

changelog_check :: proc() -> bool {
	changelog, fragments, problems := changelog_all_read()
	if len(problems) > 0 {
		problems_print(problems[:])
		fmt.eprintfln("modustool: test failed: the changelog has %d problems", len(problems))
		return false
	}
	entry_count := 0
	for checked_release in changelog.releases {
		entry_count += len(checked_release.entries)
	}
	test_passed_print("%s has %d releases and %d entries, %s has %d fragments, all well formed", CHANGELOG_FILE, len(changelog.releases), entry_count, FRAGMENT_FOLDER, len(fragments))
	return true
}

changelog_assemble :: proc() -> bool {
	changelog, fragments, problems := changelog_all_read()
	if len(problems) > 0 {
		problems_print(problems[:])
		return false
	}
	newest := len(changelog.releases) > 0 ? release_number_text(changelog.releases[0].number) : "none"
	if len(fragments) == 0 {
		fmt.printfln("modustool: no fragment in %s: the next release after %s brings nothing yet", FRAGMENT_FOLDER, newest)
		return true
	}
	fragments_in_release_order(fragments)
	fmt.printfln("modustool: %d fragments; the release after %s brings:\n", len(fragments), newest)
	fmt.print(release_parts_text(fragments))
	return true
}

changelog_release :: proc(number_text: string) -> bool {
	number, number_ok := release_number_parse(number_text)
	if !number_ok {
		fmt.eprintfln("modustool: %q is not a release number <major>.<minor>.<patch>, such as 0.59.0", number_text)
		return false
	}
	changelog, fragments, problems := changelog_all_read()
	if len(problems) > 0 {
		problems_print(problems[:])
		return false
	}
	if len(changelog.releases) > 0 && !release_number_less(changelog.releases[0].number, number) {
		fmt.eprintfln("modustool: the release %s is not after the newest release %s", number_text, release_number_text(changelog.releases[0].number))
		return false
	}
	if len(fragments) == 0 {
		fmt.eprintfln("modustool: %s has no fragment: a release lists at least one change", FRAGMENT_FOLDER)
		return false
	}
	fragments_in_release_order(fragments)
	moment := release_time_text(time.now())
	_, date, time_of_day, _ := release_heading_parse(release_heading_text(number, moment))
	if len(changelog.releases) > 0 && release_after(changelog.releases[0], Changelog_Release{date = date, time_of_day = time_of_day}) {
		fmt.eprintfln("modustool: the clock of the host, %s UTC, is before the release time %s of the newest release", moment, release_moment(changelog.releases[0]))
		return false
	}
	content := changelog_with_release(changelog, number, release_section_text(number, moment, fragments))
	// Check the result before a file changes.
	if _, after_problems := changelog_parse(content); len(after_problems) > 0 {
		problems_print(after_problems[:])
		return false
	}
	source, source_err := os.read_entire_file(RELEASE_NUMBER_SOURCE, context.temp_allocator)
	if source_err != nil {
		fmt.eprintfln("modustool: cannot read %s: %v", RELEASE_NUMBER_SOURCE, source_err)
		return false
	}
	// The copy of the measure record is decided before a file changes: a
	// record that does not read stops the release with nothing written.
	measure_history_copy := measure_history_copy_prepare(number) or_return
	source_lines := strings.split(string(source), "\n", context.temp_allocator)
	for &line in source_lines {
		if strings.has_prefix(line, RELEASE_NUMBER_LINE_START) {
			line = fmt.tprintf("%s\"%s\"", RELEASE_NUMBER_LINE_START, number_text)
		}
	}
	new_source := strings.join(source_lines, "\n", context.temp_allocator)
	if err := os.write_entire_file(CHANGELOG_FILE, transmute([]u8)content); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", CHANGELOG_FILE, err)
		return false
	}
	if err := os.write_entire_file(RELEASE_NUMBER_SOURCE, transmute([]u8)new_source); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", RELEASE_NUMBER_SOURCE, err)
		return false
	}
	for fragment in fragments {
		path := strings.concatenate({FRAGMENT_FOLDER, "/", fragment.file_name}, context.temp_allocator)
		if err := os.remove(path); err != nil {
			fmt.eprintfln("modustool: cannot delete %s: %v", path, err)
			return false
		}
	}
	measure_history_copy_write(measure_history_copy) or_return
	fmt.printfln("modustool: wrote the release %s - %s UTC with %d entries and its release link in %s, set RELEASE_NUMBER in %s, deleted %d fragments", number_text, moment, len(fragments), CHANGELOG_FILE, RELEASE_NUMBER_SOURCE, len(fragments))
	return true
}

changelog_notes :: proc(number_text: string) -> bool {
	number, number_ok := release_number_parse(number_text)
	if !number_ok {
		fmt.eprintfln("modustool: %q is not a release number <major>.<minor>.<patch>, such as 0.58.0", number_text)
		return false
	}
	problems := make([dynamic]string, context.temp_allocator)
	changelog, read_ok := changelog_read(&problems)
	if !read_ok || len(problems) > 0 {
		problems_print(problems[:])
		return false
	}
	for found, index in changelog.releases {
		if found.number != number {
			continue
		}
		// The last release ends where the release links start.
		end := changelog.first_link_line
		if index + 1 < len(changelog.releases) {
			end = changelog.releases[index + 1].line - 1
		}
		fmt.println(strings.trim_right_space(strings.join(changelog.lines[found.line - 1:end], "\n", context.temp_allocator)))
		return true
	}
	fmt.eprintfln("modustool: %s has no release %s", CHANGELOG_FILE, number_text)
	return false
}

// The format of a record of git for the release time of an old release: the
// commit time in seconds, then in the zone of the committer.
RELEASE_RECORD_FORMAT :: "--format=%ct %cI"

// command_words copies a list of words of a command into the temporary
// memory: a procedure can then return it.
command_words :: proc(words: ..string) -> []string {
	return slice.clone(words, context.temp_allocator)
}

// release_record_commands gives the git commands that find the commit of an
// old release, in the order that `changelog times` tries them: its release
// tag; the oldest commit that wrote its number in the source of the release
// number; the oldest commit that added its heading to the changelog. A
// release of a branch reaches master in a merge, and `-S` sees the change of
// a merge only against its first parent.
release_record_commands :: proc(number: Release_Number) -> [][]string {
	text := release_number_text(number)
	commands := make([][]string, 3, context.temp_allocator)
	commands[0] = command_words("git", "log", "-1", RELEASE_RECORD_FORMAT, fmt.tprintf("refs/tags/%s", release_tag_name(number)), "--")
	commands[1] = command_words("git", "log", "--diff-merges=first-parent", "--no-patch", fmt.tprintf("-S%s\"%s\"", RELEASE_NUMBER_LINE_START, text), RELEASE_RECORD_FORMAT, "--", RELEASE_NUMBER_SOURCE_PATTERN)
	commands[2] = command_words("git", "log", "--diff-merges=first-parent", "--no-patch", fmt.tprintf("-S## [%s] - ", text), RELEASE_RECORD_FORMAT, "--", CHANGELOG_FILE)
	return commands
}

// release_record_parse reads the output of a command of
// release_record_commands: the last line is the oldest commit. It gives the
// release time in UTC and the day in the zone of the committer, the day that
// an old heading was written with.
release_record_parse :: proc(output: string) -> (moment: string, committer_day: string, ok: bool) {
	last := ""
	for line in strings.split_lines(output, context.temp_allocator) {
		if strings.trim_space(line) != "" {
			last = strings.trim_space(line)
		}
	}
	space := strings.index_byte(last, ' ')
	if space <= 0 {
		return
	}
	seconds, seconds_ok := strconv.parse_i64(last[:space], 10)
	committer_time := last[space + 1:]
	if !seconds_ok || len(committer_time) < RELEASE_DAY_LENGTH || !date_text_valid(committer_time[:RELEASE_DAY_LENGTH]) {
		return
	}
	return release_time_text(time.unix(seconds, 0)), committer_time[:RELEASE_DAY_LENGTH], true
}

// release_heading_with_record gives the heading of an old release with its
// release time, from the outputs of its record commands in their order: the
// first record whose commit was made on the day of the heading. A record on
// another day is not the release: the heading keeps its day alone.
release_heading_with_record :: proc(number: Release_Number, day: string, outputs: []string) -> (heading: string, found: bool) {
	for output in outputs {
		moment, committer_day, ok := release_record_parse(output)
		if ok && committer_day == day {
			return release_heading_text(number, moment), true
		}
	}
	return "", false
}

// command_output runs a command with no terminal and gives its standard
// output; ok is false when it cannot start or fails.
command_output :: proc(command: []string) -> (output: string, ok: bool) {
	state, standard_output, _, error := os.process_exec({command = command}, context.temp_allocator)
	if error != nil || !state.exited || !state.success {
		return "", false
	}
	return string(standard_output), true
}

// changelog_times gives each old heading with its day alone its release time
// from git, and writes each missing release link. It writes nothing when the
// result does not have the form that `changelog check` asks for.
changelog_times :: proc() -> bool {
	content, err := os.read_entire_file(CHANGELOG_FILE, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("modustool: cannot read %s: %v", CHANGELOG_FILE, err)
		return false
	}
	lines := strings.split(strings.trim_right(string(content), "\n"), "\n", context.temp_allocator)
	given := 0
	left := make([dynamic]string, context.temp_allocator)
	for &line in lines {
		number, day, time_of_day, ok := release_heading_parse(line)
		if !ok || time_of_day != "" {
			continue
		}
		commands := release_record_commands(number)
		outputs := make([]string, len(commands), context.temp_allocator)
		for command, index in commands {
			outputs[index], _ = command_output(command)
		}
		heading, found := release_heading_with_record(number, day, outputs)
		if !found {
			append(&left, release_number_text(number))
			continue
		}
		line = heading
		given += 1
	}
	text := changelog_with_all_release_links(strings.concatenate({strings.join(lines, "\n", context.temp_allocator), "\n"}, context.temp_allocator))
	if _, problems := changelog_parse(text); len(problems) > 0 {
		problems_print(problems[:])
		fmt.eprintfln("modustool: %s is not written: the result has %d problems", CHANGELOG_FILE, len(problems))
		return false
	}
	if text != string(content) {
		if write_err := os.write_entire_file(CHANGELOG_FILE, transmute([]u8)text); write_err != nil {
			fmt.eprintfln("modustool: cannot write %s: %v", CHANGELOG_FILE, write_err)
			return false
		}
	}
	fmt.printfln("modustool: %d headings of %s got their release time; every release has its release link", given, CHANGELOG_FILE)
	if len(left) > 0 {
		fmt.printfln("modustool: %d headings keep their day alone: no record of git is on their day: %s", len(left), strings.join(left[:], ", ", context.temp_allocator))
	}
	return true
}
