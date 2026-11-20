// The command queue: a batch of branches merged into master after one full
// check, split in halves when the check fails, to name the branch at fault
// (src/md/infrastructure/branch_batches.md; docs/TOOLS.md, "The merge queue").
//
//   modustool queue <branch>...
//
// The decisions are pure procedures, and queue_run calls the merge, the
// check and the landing of a group through a Queue_Host: the host tests
// give a host that answers from a list, and run no git and no Nix.
package checks

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "modustool:foundation"

// The branch that every merge goes into.
QUEUE_TARGET :: SHIP_BRANCH
// The branch of the queue tree: master with the branches of one group.
QUEUE_BRANCH :: "queue/batch"
// The queue tree is beside the main working tree, as the development log
// is: the main tree stays on master while the checks run.
QUEUE_TREE :: "../kernel-queue"
// The most branches in one batch: past it, the budget of the checks grows
// past what a day of checks holds.
QUEUE_BRANCH_LIMIT :: 32
// The branches at fault after which the queue stops: past two, the batch
// has a common cause, which a developer reads before any more checks.
QUEUE_FAULT_LIMIT :: 2

// The variables of git that replace the configured user of a commit.
QUEUE_IDENTITY_VARIABLES :: [?]string{"GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL"}

// What git says of one branch of the batch, before any change.
Queue_Branch_Facts :: struct {
	exists:           bool,
	commits_ahead:    int, // The commits of the branch that master does not hold.
	worktree:         string, // The worktree where the branch is checked out, or "".
	worktree_changed: bool, // That worktree has changes that are not committed.
}

// What became of one branch of the batch.
Queue_Branch_State :: enum {
	Not_Checked, // The run stopped before a check of a group that held it.
	Merged, // Its group passed the full check and master took it.
	Check_Failed, // Alone on master and the branches before it, its full check failed.
	Merge_Conflict, // It does not merge with master and the branches before it.
}

// Why the run of the groups ended.
Queue_Stop :: enum {
	Done, // Every group was checked.
	First_Conflict, // The whole batch did not merge: nothing was checked or merged.
	Fault_Limit, // QUEUE_FAULT_LIMIT branches at fault.
	Check_Budget, // The next check was past the budget of the batch.
	Landing_Failed, // master did not take a group that passed.
	Tree_Fault, // git could not put the queue tree back to master.
}

Queue_Merge_Outcome :: enum {
	Merged,
	Conflict,
	Tree_Fault,
}

// What the merge of one group gave.
Queue_Merge_Result :: struct {
	outcome:        Queue_Merge_Outcome,
	conflict_place: int, // For a conflict: the place in the group of the branch that did not merge.
	conflict_files: []string, // For a conflict: its files in conflict.
}

// The steps of a group that reach git and Nix.
Queue_Host :: struct {
	data:        rawptr,
	// Puts the queue tree back to master, and merges each branch of the
	// group in order.
	group_merge: proc(data: rawptr, branches: []string) -> Queue_Merge_Result,
	// The full check of the queue tree.
	group_check: proc(data: rawptr) -> bool,
	// master takes the queue tree: the pictures and the measure record of
	// the check, then a fast-forward.
	group_land:  proc(data: rawptr, branches: []string) -> bool,
}

Queue_Report :: struct {
	states:         []Queue_Branch_State, // By place in the batch.
	conflict_files: [][]string, // By place in the batch: the files of a branch that did not merge.
	check_count:    int,
	check_budget:   int,
	stop:           Queue_Stop,
}

// queue_arguments_problem gives the first refusal of the list of the
// branches, from the list alone, or "".
queue_arguments_problem :: proc(branches: []string) -> string {
	if len(branches) == 0 {
		return "name one branch or more, in the order of their merges"
	}
	if len(branches) > QUEUE_BRANCH_LIMIT {
		return fmt.tprintf("%d branches: a batch holds at most %d, so that its full checks stay bounded", len(branches), QUEUE_BRANCH_LIMIT)
	}
	for branch, place in branches {
		if branch == "" {
			return "an empty name is no branch"
		}
		if branch[0] == '-' {
			return fmt.tprintf("%q starts with \"-\": the queue takes branch names, and no option", branch)
		}
		if branch == QUEUE_TARGET || branch == QUEUE_BRANCH {
			return fmt.tprintf("%s is no branch of the work: the queue merges into %s through %s", branch, QUEUE_TARGET, QUEUE_BRANCH)
		}
		for earlier in branches[:place] {
			if earlier == branch {
				return fmt.tprintf("%s is named twice: each branch merges once", branch)
			}
		}
	}
	return ""
}

// queue_branch_problems gives one sentence for each branch that the queue
// refuses, from the facts of git: the facts have the order of the branches.
queue_branch_problems :: proc(branches: []string, facts: []Queue_Branch_Facts) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	for branch, place in branches {
		fact := facts[place]
		switch {
		case !fact.exists:
			append(&problems, fmt.tprintf("%s: no such branch", branch))
		case fact.commits_ahead <= 0:
			append(&problems, fmt.tprintf("%s: it has no commit that %s does not hold: nothing to merge", branch, QUEUE_TARGET))
		case fact.worktree_changed:
			append(&problems, fmt.tprintf("%s: its worktree %s has changes that are not committed", branch, fact.worktree))
		}
	}
	return problems[:]
}

// queue_identity_problem gives the refusal of the identity of the merges,
// or "": a merge is made under the configured git user only, so a variable
// that replaces it is refused, not cleared.
queue_identity_problem :: proc(name, email: string, variables_set: []string) -> string {
	if len(variables_set) > 0 {
		return fmt.tprintf("the variable %s is set: a merge of the queue is made under the configured git user only; unset it", variables_set[0])
	}
	if strings.trim_space(name) == "" || strings.trim_space(email) == "" {
		return "git has no user.name or no user.email: a merge of the queue is made under the configured git user"
	}
	return ""
}

// queue_first_line gives the first line of a text that is not empty, with
// no space around it.
queue_first_line :: proc(text: string) -> string {
	for line in strings.split_lines(text, context.temp_allocator) {
		if trimmed := strings.trim_space(line); trimmed != "" {
			return trimmed
		}
	}
	return ""
}

// queue_summary_lowered gives a summary with its first letter in lower
// case, as the merges of master are written, unless the summary starts
// with a word in capitals.
queue_summary_lowered :: proc(summary: string) -> string {
	if summary == "" || summary[0] < 'A' || summary[0] > 'Z' {
		return summary
	}
	if len(summary) > 1 && summary[1] >= 'A' && summary[1] <= 'Z' {
		return summary
	}
	return fmt.tprintf("%c%s", rune(summary[0] - 'A' + 'a'), summary[1:])
}

// queue_merge_message gives the message of the merge of a branch: its
// description in git, else the subject of its oldest commit that master
// does not hold and that is no merge. The newest commit of a branch is
// often the commit of its pictures, which says nothing of the branch.
queue_merge_message :: proc(branch, description, oldest_subject: string) -> string {
	summary := queue_first_line(description)
	if summary == "" {
		summary = queue_first_line(oldest_subject)
	}
	if summary == "" {
		return fmt.tprintf("Merge branch '%s'", branch)
	}
	return fmt.tprintf("Merge branch '%s': %s", branch, queue_summary_lowered(summary))
}

// queue_pictures_message gives the message of the commit of the pictures
// and of the measure record of the check of a group.
queue_pictures_message :: proc(branches: []string) -> string {
	return fmt.tprintf("The screenshots of the merge queue: %s", strings.join(branches, ", ", context.temp_allocator))
}

// queue_file_takes_the_tree_side tells whether a file in conflict takes
// the side of the queue tree: the full check writes it again.
queue_file_takes_the_tree_side :: proc(file: string) -> bool {
	return strings.has_prefix(file, foundation.DOCUMENT_SCREENSHOT_FOLDER + "/") || file == MEASURE_RECORD_FILE
}

// queue_conflicts_split splits the files in conflict of a merge: those that
// take the side of the queue tree, and the others, which stop the merge.
queue_conflicts_split :: proc(files: []string) -> (tree_side, others: []string) {
	tree_list := make([dynamic]string, context.temp_allocator)
	other_list := make([dynamic]string, context.temp_allocator)
	for file in files {
		if queue_file_takes_the_tree_side(file) {
			append(&tree_list, file)
		} else {
			append(&other_list, file)
		}
	}
	return tree_list[:], other_list[:]
}

// queue_worktree_of_branch finds the worktree of a branch in the output of
// `git worktree list --porcelain`: a block for each worktree, its line
// "worktree <path>", then its line "branch refs/heads/<branch>".
queue_worktree_of_branch :: proc(porcelain, branch: string) -> (path: string, found: bool) {
	branch_line := strings.concatenate({"branch refs/heads/", branch}, context.temp_allocator)
	current := ""
	for line in strings.split_lines(porcelain, context.temp_allocator) {
		if strings.has_prefix(line, "worktree ") {
			current = line[len("worktree "):]
		} else if line == "" {
			current = ""
		} else if line == branch_line && current != "" {
			return current, true
		}
	}
	return "", false
}

// queue_depth gives the depth of the tree of the halves of a batch of
// `count` branches: ⌈log₂ count⌉, since a half holds ⌈n/2⌉ at most.
queue_depth :: proc(count: int) -> int {
	depth := 0
	for (int(1) << uint(depth)) < count {
		depth += 1
	}
	return depth
}

// queue_check_budget gives the most full checks of a batch: the worst case
// with QUEUE_FAULT_LIMIT branches at fault, and never more than the whole
// tree of the halves. Each failed group checks its two halves, and the path
// from the batch to one branch holds `depth` failed groups.
queue_check_budget :: proc(count: int) -> int {
	if count <= 0 {
		return 0
	}
	return min(2 * count - 1, 1 + 2 * queue_depth(count) * QUEUE_FAULT_LIMIT)
}

// queue_halves splits a group: the first ⌈n/2⌉ branches, then the rest.
queue_halves :: proc(group: []int) -> (first, second: []int) {
	middle := (len(group) + 1) / 2
	return group[:middle], group[middle:]
}

// queue_run merges the batch through its groups: the whole batch first;
// a group that fails its full check gives its two halves, the first half
// first, each on the master that the groups before it left. The order of
// the batch is kept: a group lands only after each group before it in the
// order was checked or left.
queue_run :: proc(branches: []string, host: Queue_Host) -> Queue_Report {
	report := Queue_Report {
		states         = make([]Queue_Branch_State, len(branches), context.temp_allocator),
		conflict_files = make([][]string, len(branches), context.temp_allocator),
		check_budget   = queue_check_budget(len(branches)),
	}
	// The groups that wait, the next one last.
	waiting := make([dynamic][]int, context.temp_allocator)
	if len(branches) > 0 {
		whole := make([]int, len(branches), context.temp_allocator)
		for &place, index in whole {
			place = index
		}
		append(&waiting, whole)
	}
	faults := 0
	first_group := true
	for len(waiting) > 0 {
		if faults >= QUEUE_FAULT_LIMIT {
			report.stop = .Fault_Limit
			return report
		}
		group := pop(&waiting)
		names := make([]string, len(group), context.temp_allocator)
		for place, index in group {
			names[index] = branches[place]
		}
		merge := host.group_merge(host.data, names)
		switch merge.outcome {
		case .Tree_Fault:
			report.stop = .Tree_Fault
			return report
		case .Conflict:
			if merge.conflict_place < 0 || merge.conflict_place >= len(group) {
				// A host that names no branch of the group gives no branch
				// to blame: the run stops as on a fault of the tree.
				report.stop = .Tree_Fault
				return report
			}
			at_fault := group[merge.conflict_place]
			report.states[at_fault] = .Merge_Conflict
			report.conflict_files[at_fault] = merge.conflict_files
			if first_group {
				report.stop = .First_Conflict
				return report
			}
			faults += 1
			rest := make([dynamic]int, 0, len(group), context.temp_allocator)
			for place in group {
				if place != at_fault {
					append(&rest, place)
				}
			}
			if len(rest) > 0 {
				append(&waiting, rest[:])
			}
			continue
		case .Merged:
		}
		first_group = false
		if report.check_count >= report.check_budget {
			report.stop = .Check_Budget
			return report
		}
		report.check_count += 1
		if host.group_check(host.data) {
			if !host.group_land(host.data, names) {
				report.stop = .Landing_Failed
				return report
			}
			for place in group {
				report.states[place] = .Merged
			}
			continue
		}
		if len(group) == 1 {
			report.states[group[0]] = .Check_Failed
			faults += 1
			continue
		}
		first_half, second_half := queue_halves(group)
		append(&waiting, second_half, first_half)
	}
	report.stop = .Done
	return report
}

// The host of git and Nix.

Queue_Git_Host :: struct {
	tree:     string, // The queue tree.
	branches: []string, // The batch, in order.
	messages: []string, // The message of the merge of each branch of the batch.
}

// queue_tree_run runs a command in the queue tree with the terminal of
// this tool.
queue_tree_run :: proc(tree: string, command: []string) -> bool {
	host_process, error := os.process_start({working_dir = tree, command = command, stdin = os.stdin, stdout = os.stdout, stderr = os.stderr})
	if error != nil {
		fmt.eprintfln("modustool: queue: cannot start %s: %v", command[0], error)
		return false
	}
	state, wait_error := os.process_wait(host_process)
	return wait_error == nil && state.exited && state.success
}

// queue_tree_output runs a command in the queue tree with no terminal and
// gives its standard output.
queue_tree_output :: proc(tree: string, command: []string) -> (output: string, ok: bool) {
	state, standard_output, _, error := os.process_exec({working_dir = tree, command = command}, context.temp_allocator)
	if error != nil || !state.exited || !state.success {
		return "", false
	}
	return string(standard_output), true
}

// queue_lines gives the lines of an output that are not empty.
queue_lines :: proc(output: string) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	for line in strings.split_lines(output, context.temp_allocator) {
		if trimmed := strings.trim_space(line); trimmed != "" {
			append(&lines, trimmed)
		}
	}
	return lines[:]
}

queue_message_of :: proc(host: ^Queue_Git_Host, branch: string) -> string {
	for name, place in host.branches {
		if name == branch {
			return host.messages[place]
		}
	}
	return fmt.tprintf("Merge branch '%s'", branch)
}

// queue_tree_side_take resolves the files in conflict that take the side of
// the queue tree: its version, or its removal when the tree has none.
queue_tree_side_take :: proc(tree: string, files: []string) -> bool {
	for file in files {
		if queue_tree_run(tree, command_words("git", "cat-file", "-e", strings.concatenate({"HEAD:", file}, context.temp_allocator))) {
			queue_tree_run(tree, command_words("git", "checkout", "-q", "--ours", "--", file)) or_return
			queue_tree_run(tree, command_words("git", "add", "--", file)) or_return
		} else {
			queue_tree_run(tree, command_words("git", "rm", "-q", "--", file)) or_return
		}
	}
	return true
}

queue_git_group_merge :: proc(data: rawptr, branches: []string) -> Queue_Merge_Result {
	host := (^Queue_Git_Host)(data)
	// The tree of the last check: its pictures and its record are files
	// of git that the reset puts back; a new picture is a file that git
	// does not track, which the clean removes. build/ is ignored and stays.
	if !queue_tree_run(host.tree, command_words("git", "reset", "-q", "--hard", QUEUE_TARGET)) || !queue_tree_run(host.tree, command_words("git", "clean", "-q", "-f", "-d")) {
		return {outcome = .Tree_Fault}
	}
	for branch, place in branches {
		message := queue_message_of(host, branch)
		reference := strings.concatenate({"refs/heads/", branch}, context.temp_allocator)
		if queue_tree_run(host.tree, command_words("git", "merge", "-q", "--no-ff", "-m", message, reference)) {
			continue
		}
		unmerged, listed := queue_tree_output(host.tree, command_words("git", "diff", "--name-only", "--diff-filter=U"))
		files := queue_lines(unmerged)
		tree_side, others := queue_conflicts_split(files)
		// A merge with no file in conflict failed for another reason: it
		// is a conflict with no file, and the merge is undone.
		if listed && len(files) > 0 && len(others) == 0 && queue_tree_side_take(host.tree, tree_side) && queue_tree_run(host.tree, command_words("git", "commit", "-q", "-m", message)) {
			fmt.printfln("modustool: queue: %s: the pictures and the measure record in conflict take the side of the queue tree", branch)
			continue
		}
		_ = queue_tree_run(host.tree, command_words("git", "merge", "--abort"))
		return {outcome = .Conflict, conflict_place = place, conflict_files = len(others) > 0 ? others : files}
	}
	return {outcome = .Merged}
}

queue_git_group_check :: proc(data: rawptr) -> bool {
	host := (^Queue_Git_Host)(data)
	return queue_tree_run(host.tree, command_words("nix", "flake", "check")) && queue_tree_run(host.tree, command_words("nix", "develop", "-c", "modustool", "screenshots"))
}

queue_git_group_land :: proc(data: rawptr, branches: []string) -> bool {
	host := (^Queue_Git_Host)(data)
	queue_tree_run(host.tree, command_words("git", "add", "-A", "--", foundation.DOCUMENT_SCREENSHOT_FOLDER, MEASURE_RECORD_FILE)) or_return
	// `git diff --cached --quiet` fails when the index holds a change.
	if !queue_tree_run(host.tree, command_words("git", "diff", "--cached", "--quiet")) {
		queue_tree_run(host.tree, command_words("git", "commit", "-q", "-m", queue_pictures_message(branches))) or_return
	}
	// The main tree is on master, with no change: it takes the queue
	// branch by a fast-forward.
	return foundation.run(command_words("git", "merge", "-q", "--ff-only", "refs/heads/" + QUEUE_BRANCH))
}

// queue_tree_remove removes the queue tree and its branch. Each is the
// queue's own, by its name.
queue_tree_remove :: proc() {
	if os.exists(QUEUE_TREE) {
		_ = foundation.run(command_words("git", "worktree", "remove", "--force", QUEUE_TREE))
	}
	_ = command_succeeds(command_words("git", "worktree", "prune"))
	_ = command_succeeds(command_words("git", "branch", "-q", "-D", QUEUE_BRANCH))
}

// queue_tree_make makes the queue tree on master, after the tree of a run
// that stopped before its end.
queue_tree_make :: proc() -> bool {
	queue_tree_remove()
	if os.exists(QUEUE_TREE) {
		fmt.eprintfln("modustool: queue: %s exists and is no worktree of this repository: move it away", QUEUE_TREE)
		return false
	}
	return foundation.run(command_words("git", "worktree", "add", "-q", "-B", QUEUE_BRANCH, QUEUE_TREE, QUEUE_TARGET))
}

// queue_branch_facts_read reads the facts of each branch of the batch.
queue_branch_facts_read :: proc(branches: []string) -> (facts: []Queue_Branch_Facts, ok: bool) {
	worktrees, worktrees_ok := command_output(command_words("git", "worktree", "list", "--porcelain"))
	if !worktrees_ok {
		fmt.eprintln("modustool: queue: git cannot list the worktrees")
		return nil, false
	}
	facts = make([]Queue_Branch_Facts, len(branches), context.temp_allocator)
	for branch, place in branches {
		reference := strings.concatenate({"refs/heads/", branch}, context.temp_allocator)
		facts[place].exists = command_succeeds(command_words("git", "rev-parse", "--verify", "-q", reference))
		if !facts[place].exists {
			continue
		}
		count_text, _ := command_output(command_words("git", "rev-list", "--count", strings.concatenate({QUEUE_TARGET, "..", reference}, context.temp_allocator)))
		facts[place].commits_ahead, _ = strconv.parse_int(strings.trim_space(count_text))
		if path, found := queue_worktree_of_branch(worktrees, branch); found {
			facts[place].worktree = path
			changes, status_ok := command_output(command_words("git", "-C", path, "status", "--porcelain"))
			facts[place].worktree_changed = !status_ok || strings.trim_space(changes) != ""
		}
	}
	return facts, true
}

// queue_messages_read gives the message of the merge of each branch.
queue_messages_read :: proc(branches: []string) -> []string {
	messages := make([]string, len(branches), context.temp_allocator)
	for branch, place in branches {
		description, _ := command_output(command_words("git", "config", "--get", strings.concatenate({"branch.", branch, ".description"}, context.temp_allocator)))
		commit_range := strings.concatenate({QUEUE_TARGET, "..refs/heads/", branch}, context.temp_allocator)
		subjects, _ := command_output(command_words("git", "log", "--reverse", "--no-merges", "--format=%s", commit_range))
		messages[place] = queue_merge_message(branch, description, subjects)
	}
	return messages
}

// queue_branch_remove removes the worktree and the branch of a merged
// branch; a failure is named, and the other branches go on.
queue_branch_remove :: proc(branch: string, worktree: string) {
	if worktree != "" && !foundation.run(command_words("git", "worktree", "remove", worktree)) {
		fmt.eprintfln("modustool: queue: %s: its worktree %s stays: it changed during the run", branch, worktree)
		return
	}
	if !foundation.run(command_words("git", "branch", "-q", "-d", branch)) {
		fmt.eprintfln("modustool: queue: %s: the branch stays", branch)
		return
	}
	fmt.printfln("modustool: queue: %s: the branch and its worktree are removed", branch)
}

// queue_stop_sentence says why a branch was not checked.
queue_stop_sentence :: proc(stop: Queue_Stop, budget: int) -> string {
	switch stop {
	case .Done:
		return "every group was checked"
	case .First_Conflict:
		return "the batch does not merge, so nothing was checked and nothing merged"
	case .Fault_Limit:
		return fmt.tprintf("the queue stopped after %d branches at fault: read their checks first", QUEUE_FAULT_LIMIT)
	case .Check_Budget:
		return fmt.tprintf("the budget of %d full checks of the batch is spent: a check failed with no branch at fault", budget)
	case .Landing_Failed:
		return fmt.tprintf("%s did not take a group that passed: look at the main tree", QUEUE_TARGET)
	case .Tree_Fault:
		return "git could not put the queue tree back to master"
	}
	return ""
}

// queue_report_print prints the state of each branch, in the order of the
// batch, and the count of the full checks.
queue_report_print :: proc(branches: []string, report: Queue_Report) {
	for branch, place in branches {
		switch report.states[place] {
		case .Merged:
			fmt.printfln("modustool: queue: %s: merged into %s", branch, QUEUE_TARGET)
		case .Check_Failed:
			fmt.eprintfln("modustool: queue: %s: at fault: the full check failed with it alone on %s and the branches merged before it; it stays a branch", branch, QUEUE_TARGET)
		case .Merge_Conflict:
			fmt.eprintfln("modustool: queue: %s: at fault: it does not merge with %s and the branches before it, in %s", branch, QUEUE_TARGET, strings.join(report.conflict_files[place], ", ", context.temp_allocator))
		case .Not_Checked:
			fmt.eprintfln("modustool: queue: %s: not checked: %s", branch, queue_stop_sentence(report.stop, report.check_budget))
		}
	}
	fmt.printfln("modustool: queue: %d full checks, of a budget of %d for %d branches", report.check_count, report.check_budget, len(branches))
}

run_queue :: proc(args: []string) -> int {
	usage_text :: "modustool queue <branch>...: the branches in the order of their merges"
	if problem := queue_arguments_problem(args); problem != "" {
		fmt.eprintfln("modustool: queue: %s", problem)
		fmt.eprintln(usage_text)
		return foundation.EXIT_USAGE
	}
	name, _ := command_output(command_words("git", "config", "user.name"))
	email, _ := command_output(command_words("git", "config", "user.email"))
	variables_set := make([dynamic]string, context.temp_allocator)
	identity_variables := QUEUE_IDENTITY_VARIABLES
	for variable in identity_variables {
		if _, found := os.lookup_env(variable, context.temp_allocator); found {
			append(&variables_set, variable)
		}
	}
	if problem := queue_identity_problem(name, email, variables_set[:]); problem != "" {
		fmt.eprintfln("modustool: queue: %s; nothing changed", problem)
		return foundation.EXIT_FAILURE
	}
	branch, branch_ok := command_output(ship_branch_command())
	if !branch_ok || strings.trim_space(branch) != QUEUE_TARGET {
		fmt.eprintfln("modustool: queue: the main tree is on %q: the queue runs from the main tree on %s; nothing changed", strings.trim_space(branch), QUEUE_TARGET)
		return foundation.EXIT_FAILURE
	}
	status, status_ok := command_output(ship_status_command())
	if !status_ok || strings.trim_space(status) != "" {
		fmt.eprintln("modustool: queue: the main tree has changes that are not committed; nothing changed")
		return foundation.EXIT_FAILURE
	}
	if !foundation.run(ship_fetch_command()) {
		fmt.eprintfln("modustool: queue: no answer from %s; nothing changed", SHIP_REMOTE)
		return foundation.EXIT_FAILURE
	}
	if !command_succeeds(ship_holds_remote_command()) {
		fmt.eprintfln("modustool: queue: %s does not hold %s: merge it first; nothing changed", QUEUE_TARGET, SHIP_REMOTE_BRANCH)
		return foundation.EXIT_FAILURE
	}
	facts, facts_ok := queue_branch_facts_read(args)
	if !facts_ok {
		return foundation.EXIT_FAILURE
	}
	if problems := queue_branch_problems(args, facts); len(problems) > 0 {
		for problem in problems {
			fmt.eprintfln("modustool: queue: %s", problem)
		}
		fmt.eprintln("modustool: queue: nothing changed")
		return foundation.EXIT_FAILURE
	}
	messages := queue_messages_read(args)
	for message, place in messages {
		fmt.printfln("modustool: queue: %d. %s", place + 1, message)
	}
	fmt.printfln("modustool: queue: %d branches, at most %d full checks", len(args), queue_check_budget(len(args)))
	if !queue_tree_make() {
		return foundation.EXIT_FAILURE
	}
	git_host := Queue_Git_Host {
		tree     = QUEUE_TREE,
		branches = args,
		messages = messages,
	}
	report := queue_run(args, {data = &git_host, group_merge = queue_git_group_merge, group_check = queue_git_group_check, group_land = queue_git_group_land})
	queue_tree_remove()
	queue_report_print(args, report)
	merged_count := 0
	for state in report.states {
		if state == .Merged {
			merged_count += 1
		}
	}
	if merged_count > 0 {
		if !foundation.run(command_words("git", "push", "-q", SHIP_REMOTE, QUEUE_TARGET)) {
			fmt.eprintfln("modustool: queue: %s refused the push: %s holds the merges; push it, then remove the merged branches", SHIP_REMOTE, QUEUE_TARGET)
			return foundation.EXIT_FAILURE
		}
		fmt.printfln("modustool: queue: %s is pushed with %d merged branches", QUEUE_TARGET, merged_count)
		for state, place in report.states {
			if state == .Merged {
				queue_branch_remove(args[place], facts[place].worktree)
			}
		}
	}
	return merged_count == len(args) ? 0 : foundation.EXIT_FAILURE
}
