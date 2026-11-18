// The command ship: the whole release in one command
// (src/md/infrastructure/releases.md; docs/TOOLS.md, "The release").
//
//   modustool ship step [--dry-run]              the release 0.(N+1).0 after the newest release 0.N.x
//   modustool ship correction [--dry-run]        the release 0.N.(x+1)
//   modustool ship <release number> [--dry-run]  that release, which must come after the newest
//
// It refuses a branch other than master, a tree with changes that are not
// committed, and a master that does not hold origin/master. It writes the
// release (`changelog release`), commits it, makes its signed release tag,
// and pushes the commit and the tag in one atomic push. When origin moved,
// the server refuses the push and nothing goes out: ship undoes the commit
// and the tag, merges origin, and tries again with the next number.
//
// Each git command is a list of words that a procedure below gives, so the
// host tests check the plan with no git.
package checks

import "core:fmt"
import "core:os"
import "core:strings"
import "modustool:foundation"
import "modustool:build"

SHIP_REMOTE :: "origin"
SHIP_BRANCH :: "master"
SHIP_REMOTE_BRANCH :: SHIP_REMOTE + "/" + SHIP_BRANCH
// A refused push means that origin moved; past this count of tries, another
// publisher is releasing at the same time, and a principal must look.
SHIP_ATTEMPT_COUNT :: 3
SHIP_DRY_RUN_FLAG :: "--dry-run"

// What a ship asks for.
Ship_Request :: enum {
	Step, // 0.(N+1).0: a release of new work.
	Correction, // 0.N.(x+1): a correction after the newest release.
	Exact, // The number that the command names.
}

ship_request_parse :: proc(text: string) -> (request: Ship_Request, exact: Release_Number, ok: bool) {
	switch text {
	case "step":
		return .Step, {}, true
	case "correction":
		return .Correction, {}, true
	}
	exact = release_number_parse(text) or_return
	return .Exact, exact, true
}

// ship_number_next gives the release number that a request takes after the
// newest release. An exact number must come after it.
ship_number_next :: proc(newest: Release_Number, request: Ship_Request, exact: Release_Number) -> (number: Release_Number, ok: bool) {
	switch request {
	case .Step:
		return {newest.major, newest.minor + 1, 0}, true
	case .Correction:
		return {newest.major, newest.minor, newest.patch + 1}, true
	case .Exact:
		return exact, release_number_less(newest, exact)
	}
	return {}, false
}

// release_tags_highest gives the highest release number among the release
// tags of the output of ship_tag_list_command.
release_tags_highest :: proc(output: string) -> (highest: Release_Number, found: bool) {
	for line in strings.split_lines(output, context.temp_allocator) {
		name := strings.trim_space(line)
		if !strings.has_prefix(name, RELEASE_TAG_PREFIX) {
			continue
		}
		number, ok := release_number_parse(name[len(RELEASE_TAG_PREFIX):])
		if !ok {
			continue
		}
		if !found || release_number_less(highest, number) {
			highest, found = number, true
		}
	}
	return
}

// ship_newest_release gives the newest release: the higher of the number in
// the source and of the highest release tag.
ship_newest_release :: proc(source: string, tag_list: string) -> (newest: Release_Number, ok: bool) {
	written, _, found := release_number_source_parse(source)
	if !found {
		return {}, false
	}
	newest = release_number_parse(written) or_return
	if tagged, tag_found := release_tags_highest(tag_list); tag_found && release_number_less(newest, tagged) {
		newest = tagged
	}
	return newest, true
}

ship_commit_message :: proc(number: Release_Number) -> string {
	return fmt.tprintf("Release %s", release_number_text(number))
}

// The plan: each git command of ship, as data.

ship_branch_command :: proc() -> []string {
	return command_words("git", "branch", "--show-current")
}

ship_status_command :: proc() -> []string {
	return command_words("git", "status", "--porcelain")
}

ship_fetch_command :: proc() -> []string {
	return command_words("git", "fetch", "-q", "--tags", SHIP_REMOTE, SHIP_BRANCH)
}

// Exits with success when HEAD holds every commit of origin/master.
ship_holds_remote_command :: proc() -> []string {
	return command_words("git", "merge-base", "--is-ancestor", SHIP_REMOTE_BRANCH, "HEAD")
}

ship_tag_list_command :: proc() -> []string {
	return command_words("git", "tag", "--list", RELEASE_TAG_PREFIX + "*")
}

// A merge keeps the merges of the branches as they are; a rebase would
// flatten them and conflict again on each.
ship_merge_command :: proc() -> []string {
	return command_words("git", "merge", "-q", "--no-edit", SHIP_REMOTE_BRANCH)
}

ship_merge_abort_command :: proc() -> []string {
	return command_words("git", "merge", "--abort")
}

// Puts the tree back to the last commit, after a release that was written
// and not committed.
ship_restore_command :: proc() -> []string {
	return command_words("git", "reset", "-q", "--hard", "HEAD")
}

// Removes the copy of the measure record that the release wrote: a reset
// keeps a file that git does not track. The tree was clean when ship
// started, so the copy of this release is the only such file there.
ship_measure_history_clean_command :: proc() -> []string {
	return command_words("git", "clean", "-q", "-f", "--", MEASURE_HISTORY_FOLDER)
}

ship_restore :: proc() {
	_ = foundation.run(ship_restore_command())
	_ = foundation.run(ship_measure_history_clean_command())
}

// The commands that publish one release, in their order. The add names the
// fragment folder, whose deleted fragments are part of the commit, and the
// folder of the measure history, which holds the copy of the measure record
// of the release.
ship_publish_commands :: proc(number: Release_Number) -> [][]string {
	tag := release_tag_name(number)
	message := ship_commit_message(number)
	commands := make([][]string, 4, context.temp_allocator)
	commands[0] = command_words("git", "add", "-A", "--", CHANGELOG_FILE, build.RELEASE_NUMBER_SOURCE, FRAGMENT_FOLDER, MEASURE_HISTORY_FOLDER)
	commands[1] = command_words("git", "commit", "-q", "-m", message)
	// Signed and annotated: the tag holds who released, when, and a
	// signature that the git configuration of the publisher makes.
	commands[2] = command_words("git", "tag", "-s", "-a", tag, "-m", message)
	// One atomic push: origin gets the commit and the tag, or neither.
	commands[3] = command_words("git", "push", "-q", "--atomic", SHIP_REMOTE, fmt.tprintf("HEAD:refs/heads/%s", SHIP_BRANCH), fmt.tprintf("refs/tags/%s", tag))
	return commands
}

// The commands that undo a release that origin refused: the tag, then the
// commit. Nothing of it went out.
ship_undo_commands :: proc(number: Release_Number) -> [][]string {
	commands := make([][]string, 2, context.temp_allocator)
	commands[0] = command_words("git", "tag", "-d", release_tag_name(number))
	commands[1] = command_words("git", "reset", "-q", "--hard", "HEAD~1")
	return commands
}

// command_succeeds runs a command with no terminal; a failure is an answer,
// not a fault, so it prints nothing.
command_succeeds :: proc(command: []string) -> bool {
	_, ok := command_output(command)
	return ok
}

// ship_newest_release_read reads the newest release from the source of the
// release number and the release tags of the repository.
ship_newest_release_read :: proc() -> (newest: Release_Number, ok: bool) {
	source, err := os.read_entire_file(build.RELEASE_NUMBER_SOURCE, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("modustool: ship: cannot read %s: %v", build.RELEASE_NUMBER_SOURCE, err)
		return {}, false
	}
	tags, tags_ok := command_output(ship_tag_list_command())
	if !tags_ok {
		fmt.eprintln("modustool: ship: git cannot list the release tags")
		return {}, false
	}
	newest, ok = ship_newest_release(string(source), tags)
	if !ok {
		fmt.eprintfln("modustool: ship: %s has no release number on a line that starts with %q", build.RELEASE_NUMBER_SOURCE, RELEASE_NUMBER_LINE_START)
	}
	return
}

run_ship :: proc(args: []string) -> int {
	usage_text :: "modustool ship step | correction | <release number> [" + SHIP_DRY_RUN_FLAG + "]"
	request_text := ""
	dry_run := false
	for argument in args {
		if argument == SHIP_DRY_RUN_FLAG {
			dry_run = true
		} else if request_text == "" {
			request_text = argument
		} else {
			fmt.eprintln(usage_text)
			return foundation.EXIT_USAGE
		}
	}
	request, exact, request_ok := ship_request_parse(request_text)
	if !request_ok {
		fmt.eprintln(usage_text)
		return foundation.EXIT_USAGE
	}
	branch, branch_ok := command_output(ship_branch_command())
	if !branch_ok || strings.trim_space(branch) != SHIP_BRANCH {
		fmt.eprintfln("modustool: ship: the branch is %q; a release is made on %s", strings.trim_space(branch), SHIP_BRANCH)
		return foundation.EXIT_FAILURE
	}
	status, status_ok := command_output(ship_status_command())
	if !status_ok || strings.trim_space(status) != "" {
		fmt.eprintln("modustool: ship: the tree has changes that are not committed; a release is made from a commit")
		return foundation.EXIT_FAILURE
	}
	if !foundation.run(ship_fetch_command()) {
		fmt.eprintfln("modustool: ship: no answer from %s", SHIP_REMOTE)
		return foundation.EXIT_FAILURE
	}
	if !command_succeeds(ship_holds_remote_command()) {
		fmt.eprintfln("modustool: ship: %s does not hold %s; merge it, check, then ship", SHIP_BRANCH, SHIP_REMOTE_BRANCH)
		return foundation.EXIT_FAILURE
	}
	for attempt in 0 ..< SHIP_ATTEMPT_COUNT {
		if attempt > 0 {
			if !foundation.run(ship_fetch_command()) {
				fmt.eprintfln("modustool: ship: no answer from %s; nothing was published", SHIP_REMOTE)
				return foundation.EXIT_FAILURE
			}
			if !foundation.run(ship_merge_command()) {
				_ = foundation.run(ship_merge_abort_command())
				fmt.eprintfln("modustool: ship: %s does not merge with %s; nothing was published", SHIP_BRANCH, SHIP_REMOTE_BRANCH)
				return foundation.EXIT_FAILURE
			}
		}
		newest, newest_ok := ship_newest_release_read()
		if !newest_ok {
			return foundation.EXIT_FAILURE
		}
		number, number_ok := ship_number_next(newest, request, exact)
		if !number_ok {
			fmt.eprintfln("modustool: ship: the release %s is not after the newest release %s", release_number_text(exact), release_number_text(newest))
			return foundation.EXIT_FAILURE
		}
		number_text := release_number_text(number)
		if dry_run {
			fmt.printfln("modustool: ship: the release %s after %s, its release tag %s; the commands:", number_text, release_number_text(newest), release_tag_name(number))
			fmt.printfln("  modustool changelog release %s", number_text)
			for command in ship_publish_commands(number) {
				fmt.printfln("  %s", strings.join(command, " ", context.temp_allocator))
			}
			if !changelog_assemble() {
				return foundation.EXIT_FAILURE
			}
			fmt.println("modustool: ship: a dry run; nothing was written")
			return 0
		}
		if !changelog_release(number_text) {
			ship_restore()
			fmt.eprintln("modustool: ship: the release was not written; nothing was published")
			return foundation.EXIT_FAILURE
		}
		publish := ship_publish_commands(number)
		// The add and the commit: on a failure, the tree goes back to the
		// last commit.
		for command in publish[:2] {
			if !foundation.run(command) {
				ship_restore()
				fmt.eprintln("modustool: ship: the release was not committed; nothing was published")
				return foundation.EXIT_FAILURE
			}
		}
		if !foundation.run(publish[2]) {
			_ = foundation.run(ship_undo_commands(number)[1])
			fmt.eprintln("modustool: ship: the release tag was not made (is a signing key configured for git?); the commit is undone; nothing was published")
			return foundation.EXIT_FAILURE
		}
		if foundation.run(publish[3]) {
			fmt.printfln("modustool: ship: released %s: the commit and the release tag %s are on %s", number_text, release_tag_name(number), SHIP_REMOTE)
			return 0
		}
		for command in ship_undo_commands(number) {
			_ = foundation.run(command)
		}
		fmt.eprintfln("modustool: ship: %s refused the push of %s (try %d of %d): %s moved; it is merged, and the release takes the next number", SHIP_REMOTE, number_text, attempt + 1, SHIP_ATTEMPT_COUNT, SHIP_REMOTE_BRANCH)
	}
	fmt.eprintfln("modustool: ship: %s kept moving after %d tries; nothing was published", SHIP_REMOTE_BRANCH, SHIP_ATTEMPT_COUNT)
	return foundation.EXIT_FAILURE
}
