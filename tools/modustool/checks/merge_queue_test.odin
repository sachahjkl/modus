package checks

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import "modustool:foundation"

// A host of the queue with no git and no Nix: a group fails its check when
// it holds a branch of `failing`, or more than one branch when
// `fails_with_two` is set (a check that fails with no branch at fault); a
// branch of `conflicting` does not merge while the branch `needed` is
// neither on master nor before it in its group.
@(private = "file")
Queue_Test_Host :: struct {
	failing:        []int,
	conflicting:    []int,
	needed:         int,
	fails_with_two: bool,
	landing_fails:  bool,
	tree_fails:     bool,
	master:         [dynamic]int, // The branches that master took, in order.
	group:          []int, // The group that the last merge made.
	merges:         int,
	checks:         int,
	landings:       [dynamic][]int,
}

@(private = "file")
QUEUE_TEST_PREFIX :: "work/b"

@(private = "file")
queue_test_names :: proc(count: int) -> []string {
	names := make([]string, count, context.temp_allocator)
	for &name, place in names {
		name = fmt.tprintf("%s%d", QUEUE_TEST_PREFIX, place)
	}
	return names
}

@(private = "file")
queue_test_place :: proc(name: string) -> int {
	place, ok := strconv.parse_int(name[len(QUEUE_TEST_PREFIX):])
	assert(ok)
	return place
}

@(private = "file")
queue_test_merge :: proc(data: rawptr, branches: []string) -> Queue_Merge_Result {
	host := (^Queue_Test_Host)(data)
	host.merges += 1
	if host.tree_fails {
		return {outcome = .Tree_Fault}
	}
	group := make([]int, len(branches), context.temp_allocator)
	for name, index in branches {
		group[index] = queue_test_place(name)
		if slice.contains(host.conflicting, group[index]) && !slice.contains(host.master[:], host.needed) && !slice.contains(group[:index], host.needed) {
			// Not a slice literal: its array would be on the stack of this
			// procedure after its return.
			files := make([]string, 1, context.temp_allocator)
			files[0] = "src/modulus/enter.odin"
			return {outcome = .Conflict, conflict_place = index, conflict_files = files}
		}
	}
	host.group = group
	return {outcome = .Merged}
}

@(private = "file")
queue_test_check :: proc(data: rawptr) -> bool {
	host := (^Queue_Test_Host)(data)
	host.checks += 1
	if host.fails_with_two && len(host.group) > 1 {
		return false
	}
	for place in host.group {
		if slice.contains(host.failing, place) {
			return false
		}
	}
	return true
}

@(private = "file")
queue_test_land :: proc(data: rawptr, branches: []string) -> bool {
	host := (^Queue_Test_Host)(data)
	if host.landing_fails {
		return false
	}
	landed := make([]int, len(branches), context.temp_allocator)
	for name, index in branches {
		landed[index] = queue_test_place(name)
	}
	append(&host.master, ..landed)
	append(&host.landings, landed)
	return true
}

@(private = "file")
queue_test_run :: proc(count: int, host: ^Queue_Test_Host) -> Queue_Report {
	host.master = make([dynamic]int, context.temp_allocator)
	host.landings = make([dynamic][]int, context.temp_allocator)
	return queue_run(queue_test_names(count), {data = host, group_merge = queue_test_merge, group_check = queue_test_check, group_land = queue_test_land})
}

// Each landed branch is after each branch that landed before it: master
// takes the batch in its order.
@(private = "file")
queue_test_order_kept :: proc(t: ^testing.T, host: ^Queue_Test_Host) {
	for place in 1 ..< len(host.master) {
		testing.expectf(t, host.master[place - 1] < host.master[place], "master took %v, out of the order of the batch", host.master[:])
	}
}

@(private = "file")
queue_test_count :: proc(report: Queue_Report, state: Queue_Branch_State) -> int {
	count := 0
	for each in report.states {
		if each == state {
			count += 1
		}
	}
	return count
}

@(test)
queue_refuses_a_wrong_list_of_branches :: proc(t: ^testing.T) {
	testing.expect(t, queue_arguments_problem(nil) != "")
	testing.expect(t, queue_arguments_problem([]string{}) != "")
	for bad in ([]string{"", "-f", "--force", QUEUE_TARGET, QUEUE_BRANCH}) {
		problem := queue_arguments_problem([]string{"work/a", bad})
		testing.expectf(t, problem != "", "%q must be refused", bad)
	}
	twice := queue_arguments_problem([]string{"work/a", "work/b", "work/a"})
	testing.expect(t, strings.contains(twice, "work/a is named twice"))
	// The bound, then one past it.
	testing.expect_value(t, queue_arguments_problem(queue_test_names(QUEUE_BRANCH_LIMIT)), "")
	testing.expect(t, queue_arguments_problem(queue_test_names(QUEUE_BRANCH_LIMIT + 1)) != "")
	// Two names that only start alike are two branches.
	testing.expect_value(t, queue_arguments_problem([]string{"work/a", "work/a2", "work/a/b"}), "")
	testing.expect_value(t, queue_arguments_problem([]string{"work/a"}), "")
}

@(test)
queue_refuses_each_branch_that_git_does_not_allow :: proc(t: ^testing.T) {
	branches := []string{"work/gone", "work/behind", "work/negative", "work/changed", "work/good"}
	facts := []Queue_Branch_Facts {
		{exists = false, commits_ahead = 3},
		{exists = true, commits_ahead = 0},
		{exists = true, commits_ahead = -1},
		{exists = true, commits_ahead = 1, worktree = "/tmp/changed", worktree_changed = true},
		{exists = true, commits_ahead = 1, worktree = "/tmp/good"},
	}
	problems := queue_branch_problems(branches, facts)
	testing.expect_value(t, len(problems), 4)
	if len(problems) == 4 {
		testing.expect(t, strings.has_prefix(problems[0], "work/gone: no such branch"))
		testing.expect(t, strings.has_prefix(problems[1], "work/behind: "))
		testing.expect(t, strings.has_prefix(problems[2], "work/negative: "))
		testing.expect(t, strings.contains(problems[3], "/tmp/changed"))
	}
	testing.expect_value(t, len(queue_branch_problems(branches[4:], facts[4:])), 0)
}

@(test)
queue_merges_under_the_configured_user_only :: proc(t: ^testing.T) {
	identity_variables := QUEUE_IDENTITY_VARIABLES
	for variable in identity_variables {
		problem := queue_identity_problem("name", "name@host", []string{variable})
		testing.expectf(t, strings.contains(problem, variable), "the variable %s must be refused", variable)
	}
	testing.expect(t, queue_identity_problem("", "name@host", nil) != "")
	testing.expect(t, queue_identity_problem("name", "", nil) != "")
	testing.expect(t, queue_identity_problem(" \n", "name@host", nil) != "")
	testing.expect_value(t, queue_identity_problem("name\n", "name@host\n", nil), "")
}

@(test)
queue_gives_each_merge_the_summary_of_its_branch :: proc(t: ^testing.T) {
	// The description first, its first line only.
	testing.expect_value(t, queue_merge_message("work/a", "The editor edit\nmore lines\n", "Another subject"), "Merge branch 'work/a': the editor edit")
	// Else the oldest subject: the first line of `git log --reverse`.
	testing.expect_value(t, queue_merge_message("work/a", "", "Log facts, step 9: a serial form\nThe screenshots with it\n"), "Merge branch 'work/a': log facts, step 9: a serial form")
	testing.expect_value(t, queue_merge_message("work/a", " \n", "\n  QUIC keys\n"), "Merge branch 'work/a': QUIC keys")
	// A branch of merges alone has no summary.
	testing.expect_value(t, queue_merge_message("work/a", "", ""), "Merge branch 'work/a'")
	testing.expect_value(t, queue_summary_lowered(""), "")
	testing.expect_value(t, queue_summary_lowered("A"), "a")
	testing.expect_value(t, queue_summary_lowered("AB tests"), "AB tests")
	testing.expect_value(t, queue_summary_lowered("Z"), "z")
	testing.expect_value(t, queue_summary_lowered("@ sign"), "@ sign")
	testing.expect_value(t, queue_summary_lowered("already lower"), "already lower")
	testing.expect_value(t, queue_pictures_message([]string{"work/a", "work/b"}), "The screenshots of the merge queue: work/a, work/b")
}

@(test)
queue_takes_the_tree_side_for_the_pictures_and_the_record_only :: proc(t: ^testing.T) {
	files := []string{foundation.DOCUMENT_SCREENSHOT_FOLDER + "/console.png", MEASURE_RECORD_FILE, foundation.DOCUMENT_SCREENSHOT_FOLDER + "_old/console.png", MEASURE_RECORD_FOLDER + "/releases/0.93.0.txt", MEASURE_RECORD_FILE + ".bak", "src/modulus/enter.odin", foundation.DOCUMENT_SCREENSHOT_FOLDER}
	tree_side, others := queue_conflicts_split(files)
	testing.expect_value(t, len(tree_side), 2)
	testing.expect_value(t, len(others), 5)
	empty_tree_side, empty_others := queue_conflicts_split(nil)
	testing.expect_value(t, len(empty_tree_side) + len(empty_others), 0)
}

@(test)
queue_finds_the_worktree_of_a_branch :: proc(t: ^testing.T) {
	porcelain := "worktree /home/a/kernel\nHEAD 8ab9e7c0\nbranch refs/heads/master\n\nworktree /home/a/work tree/b\nHEAD 8ab9e7c0\nbranch refs/heads/work/b\n\nworktree /home/a/detached\nHEAD 1111\ndetached\n\nworktree /home/a/b2\nHEAD 2222\nbranch refs/heads/work/b2\n"
	path, found := queue_worktree_of_branch(porcelain, "work/b")
	testing.expect(t, found)
	testing.expect_value(t, path, "/home/a/work tree/b")
	path, found = queue_worktree_of_branch(porcelain, "work/b2")
	testing.expect_value(t, path, "/home/a/b2")
	for absent in ([]string{"work", "work/b3", "b", "detached", ""}) {
		_, absent_found := queue_worktree_of_branch(porcelain, absent)
		testing.expectf(t, !absent_found, "%q has no worktree", absent)
	}
	_, empty_found := queue_worktree_of_branch("", "work/b")
	testing.expect(t, !empty_found)
}

@(test)
queue_bounds_its_full_checks :: proc(t: ^testing.T) {
	testing.expect_value(t, queue_check_budget(-1), 0)
	testing.expect_value(t, queue_check_budget(0), 0)
	testing.expect_value(t, queue_check_budget(1), 1)
	testing.expect_value(t, queue_check_budget(2), 3)
	testing.expect_value(t, queue_check_budget(12), 1 + 2 * 4 * QUEUE_FAULT_LIMIT)
	testing.expect_value(t, queue_check_budget(QUEUE_BRANCH_LIMIT), 1 + 2 * 5 * QUEUE_FAULT_LIMIT)
	for count in 1 ..= QUEUE_BRANCH_LIMIT {
		testing.expect(t, queue_check_budget(count) <= 2 * count - 1)
	}
	testing.expect_value(t, queue_depth(1), 0)
	testing.expect_value(t, queue_depth(2), 1)
	testing.expect_value(t, queue_depth(3), 2)
	testing.expect_value(t, queue_depth(12), 4)
	testing.expect_value(t, queue_depth(16), 4)
	testing.expect_value(t, queue_depth(17), 5)
	group := []int{0, 1, 2, 3, 4}
	first, second := queue_halves(group)
	testing.expect(t, slice.equal(first, []int{0, 1, 2}))
	testing.expect(t, slice.equal(second, []int{3, 4}))
	one_first, one_second := queue_halves(group[:1])
	testing.expect_value(t, len(one_first), 1)
	testing.expect_value(t, len(one_second), 0)
}

@(test)
queue_stops_at_the_first_conflict_with_nothing_merged :: proc(t: ^testing.T) {
	host := Queue_Test_Host {
		conflicting = []int{3},
		needed      = 99,
	}
	report := queue_test_run(6, &host)
	testing.expect_value(t, report.stop, Queue_Stop.First_Conflict)
	testing.expect_value(t, report.states[3], Queue_Branch_State.Merge_Conflict)
	testing.expect_value(t, len(report.conflict_files[3]), 1)
	testing.expect_value(t, queue_test_count(report, .Not_Checked), 5)
	testing.expect_value(t, host.checks, 0)
	testing.expect_value(t, len(host.master), 0)
}

@(test)
queue_stops_on_a_fault_of_the_tree :: proc(t: ^testing.T) {
	host := Queue_Test_Host {
		tree_fails = true,
	}
	report := queue_test_run(4, &host)
	testing.expect_value(t, report.stop, Queue_Stop.Tree_Fault)
	testing.expect_value(t, host.checks, 0)
	testing.expect_value(t, queue_test_count(report, .Not_Checked), 4)
}

@(test)
queue_runs_no_group_for_an_empty_batch :: proc(t: ^testing.T) {
	host := Queue_Test_Host{}
	report := queue_test_run(0, &host)
	testing.expect_value(t, report.stop, Queue_Stop.Done)
	testing.expect_value(t, host.merges, 0)
	testing.expect_value(t, report.check_count, 0)
}

@(test)
queue_names_the_one_branch_at_fault_within_its_bound :: proc(t: ^testing.T) {
	// The branch at fault at the end of the deepest path of 12: each failed
	// group on the way checks its two halves.
	host := Queue_Test_Host {
		failing = []int{1},
	}
	report := queue_test_run(12, &host)
	testing.expect_value(t, report.stop, Queue_Stop.Done)
	testing.expect_value(t, report.check_count, 1 + 2 * queue_depth(12))
	testing.expect_value(t, report.states[1], Queue_Branch_State.Check_Failed)
	testing.expect_value(t, queue_test_count(report, .Merged), 11)
	queue_test_order_kept(t, &host)
	// One branch at fault at each place of each size of batch costs at most
	// 1 + 2⌈log₂ n⌉, and names that branch alone.
	for count in 1 ..= QUEUE_BRANCH_LIMIT {
		for at_fault in 0 ..< count {
			each_host := Queue_Test_Host {
				failing = []int{at_fault},
			}
			each := queue_test_run(count, &each_host)
			testing.expect(t, each.check_count <= 1 + 2 * queue_depth(count))
			testing.expect_value(t, queue_test_count(each, .Check_Failed), 1)
			testing.expect_value(t, each.states[at_fault], Queue_Branch_State.Check_Failed)
			testing.expect_value(t, queue_test_count(each, .Merged), count - 1)
			queue_test_order_kept(t, &each_host)
		}
	}
}

@(test)
queue_stops_after_the_limit_of_branches_at_fault :: proc(t: ^testing.T) {
	every := make([]int, 12, context.temp_allocator)
	for &place, index in every {
		place = index
	}
	host := Queue_Test_Host {
		failing = every,
	}
	report := queue_test_run(12, &host)
	testing.expect_value(t, report.stop, Queue_Stop.Fault_Limit)
	testing.expect_value(t, queue_test_count(report, .Check_Failed), QUEUE_FAULT_LIMIT)
	testing.expect_value(t, queue_test_count(report, .Merged), 0)
	testing.expect_value(t, queue_test_count(report, .Not_Checked), 12 - QUEUE_FAULT_LIMIT)
	testing.expect(t, report.check_count <= report.check_budget)
	testing.expect_value(t, len(host.landings), 0)
}

@(test)
queue_never_checks_past_its_budget :: proc(t: ^testing.T) {
	// Each group of two or more fails, each branch alone passes: no branch
	// is at fault, and the whole tree of the halves would cost 2n - 1.
	for count in 1 ..= QUEUE_BRANCH_LIMIT {
		host := Queue_Test_Host {
			fails_with_two = true,
		}
		report := queue_test_run(count, &host)
		testing.expect(t, host.checks <= queue_check_budget(count))
		testing.expect_value(t, report.check_count, host.checks)
		testing.expect_value(t, queue_test_count(report, .Check_Failed), 0)
		if report.stop == .Done {
			testing.expect_value(t, queue_test_count(report, .Merged), count)
		} else {
			testing.expect_value(t, report.stop, Queue_Stop.Check_Budget)
			testing.expect_value(t, host.checks, queue_check_budget(count))
			testing.expect(t, queue_test_count(report, .Not_Checked) > 0)
		}
		queue_test_order_kept(t, &host)
	}
	// For 12: the budget of 17 stops the tree of 23 groups.
	host := Queue_Test_Host {
		fails_with_two = true,
	}
	report := queue_test_run(12, &host)
	testing.expect_value(t, report.stop, Queue_Stop.Check_Budget)
	testing.expect_value(t, report.check_count, 17)
}

@(test)
queue_names_a_later_conflict_and_goes_on_without_it :: proc(t: ^testing.T) {
	// Branch 4 merges only after branch 0, which fails its check: the group
	// after the failure of 0 names 4 at fault with no check, and goes on.
	host := Queue_Test_Host {
		failing     = []int{0},
		conflicting = []int{4},
		needed      = 0,
	}
	report := queue_test_run(8, &host)
	testing.expect_value(t, report.states[0], Queue_Branch_State.Check_Failed)
	testing.expect_value(t, report.states[4], Queue_Branch_State.Merge_Conflict)
	testing.expect_value(t, report.stop, Queue_Stop.Fault_Limit)
	queue_test_order_kept(t, &host)
	for state, place in report.states {
		if state == .Merged {
			testing.expect(t, place != 0 && place != 4)
		}
	}
}

@(test)
queue_stops_when_master_does_not_take_a_group :: proc(t: ^testing.T) {
	host := Queue_Test_Host {
		landing_fails = true,
	}
	report := queue_test_run(5, &host)
	testing.expect_value(t, report.stop, Queue_Stop.Landing_Failed)
	testing.expect_value(t, report.check_count, 1)
	testing.expect_value(t, queue_test_count(report, .Merged), 0)
}

@(test)
queue_merges_a_good_batch_with_one_check :: proc(t: ^testing.T) {
	host := Queue_Test_Host{}
	report := queue_test_run(12, &host)
	testing.expect_value(t, report.stop, Queue_Stop.Done)
	testing.expect_value(t, report.check_count, 1)
	testing.expect_value(t, host.merges, 1)
	testing.expect_value(t, len(host.landings), 1)
	testing.expect_value(t, queue_test_count(report, .Merged), 12)
	queue_test_order_kept(t, &host)
}
