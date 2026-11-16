package modustool

import "core:strings"
import "core:testing"

@(private = "file")
command_text :: proc(command: []string) -> string {
	return strings.join(command, " ", context.temp_allocator)
}

@(test)
ship_request_gives_the_next_number :: proc(t: ^testing.T) {
	newest := Release_Number{0, 92, 0}
	request, exact, ok := ship_request_parse("step")
	testing.expect(t, ok)
	testing.expect_value(t, request, Ship_Request.Step)
	number, number_ok := ship_number_next(newest, request, exact)
	testing.expect(t, number_ok)
	testing.expect_value(t, number, Release_Number{0, 93, 0})
	request, exact, ok = ship_request_parse("correction")
	testing.expect(t, ok)
	number, number_ok = ship_number_next(newest, request, exact)
	testing.expect(t, number_ok)
	testing.expect_value(t, number, Release_Number{0, 92, 1})
	// A correction after a correction.
	number, number_ok = ship_number_next({0, 92, 1}, .Correction, {})
	testing.expect_value(t, number, Release_Number{0, 92, 2})
	// A step after a correction starts the patch again.
	number, number_ok = ship_number_next({0, 92, 1}, .Step, {})
	testing.expect_value(t, number, Release_Number{0, 93, 0})
	// An exact number must come after the newest release.
	request, exact, ok = ship_request_parse("0.95.0")
	testing.expect(t, ok)
	testing.expect_value(t, request, Ship_Request.Exact)
	number, number_ok = ship_number_next(newest, request, exact)
	testing.expect(t, number_ok)
	testing.expect_value(t, number, Release_Number{0, 95, 0})
	_, number_ok = ship_number_next(newest, .Exact, newest)
	testing.expect(t, !number_ok)
	_, number_ok = ship_number_next(newest, .Exact, {0, 91, 0})
	testing.expect(t, !number_ok)
	for bad in ([]string{"", "next", "v0.93.0", "0.93", "Step"}) {
		_, _, bad_ok := ship_request_parse(bad)
		testing.expectf(t, !bad_ok, "%q is not a request of ship", bad)
	}
}

@(test)
ship_newest_release_is_the_source_or_a_higher_tag :: proc(t: ^testing.T) {
	source :: "package release\n\nRELEASE_NUMBER :: \"0.92.0\"\n"
	highest, found := release_tags_highest("v0.9.0\nv0.10.0\nnot-a-release\nv0.10\nv1.2.3.4\n")
	testing.expect(t, found)
	testing.expect_value(t, highest, Release_Number{0, 10, 0})
	_, none_found := release_tags_highest("")
	testing.expect(t, !none_found)
	newest, ok := ship_newest_release(source, "")
	testing.expect(t, ok)
	testing.expect_value(t, newest, Release_Number{0, 92, 0})
	// A tag of another publisher after a merge that the source does not
	// show yet: the higher number wins, so two releases never take one number.
	newest, ok = ship_newest_release(source, "v0.92.0\nv0.93.0\n")
	testing.expect(t, ok)
	testing.expect_value(t, newest, Release_Number{0, 93, 0})
	newest, ok = ship_newest_release(source, "v0.5.0\n")
	testing.expect_value(t, newest, Release_Number{0, 92, 0})
	_, ok = ship_newest_release("package release\n", "v0.5.0\n")
	testing.expect(t, !ok)
}

@(test)
ship_plan_is_one_atomic_push_of_a_signed_tag :: proc(t: ^testing.T) {
	number := Release_Number{0, 93, 0}
	publish := ship_publish_commands(number)
	testing.expect_value(t, len(publish), 4)
	testing.expect_value(t, command_text(publish[0]), "git add -A -- " + CHANGELOG_FILE + " " + RELEASE_NUMBER_SOURCE + " " + FRAGMENT_FOLDER)
	testing.expect_value(t, command_text(publish[1]), "git commit -q -m Release 0.93.0")
	testing.expect_value(t, len(publish[1]), 5)
	testing.expect_value(t, publish[1][4], "Release 0.93.0")
	// Annotated and signed.
	testing.expect_value(t, command_text(publish[2]), "git tag -s -a v0.93.0 -m Release 0.93.0")
	// The commit and the tag in one push.
	testing.expect_value(t, command_text(publish[3]), "git push -q --atomic origin HEAD:refs/heads/master refs/tags/v0.93.0")
	undo := ship_undo_commands(number)
	testing.expect_value(t, len(undo), 2)
	testing.expect_value(t, command_text(undo[0]), "git tag -d v0.93.0")
	testing.expect_value(t, command_text(undo[1]), "git reset -q --hard HEAD~1")
	testing.expect_value(t, command_text(ship_fetch_command()), "git fetch -q --tags origin master")
	testing.expect_value(t, command_text(ship_holds_remote_command()), "git merge-base --is-ancestor origin/master HEAD")
	testing.expect_value(t, command_text(ship_merge_command()), "git merge -q --no-edit origin/master")
	testing.expect_value(t, command_text(ship_merge_abort_command()), "git merge --abort")
	testing.expect_value(t, command_text(ship_restore_command()), "git reset -q --hard HEAD")
	testing.expect_value(t, command_text(ship_tag_list_command()), "git tag --list v*")
	testing.expect_value(t, command_text(ship_status_command()), "git status --porcelain")
	testing.expect_value(t, command_text(ship_branch_command()), "git branch --show-current")
}
