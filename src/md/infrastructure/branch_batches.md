# The work of a batch of branches

Several features are written at once, each on its own branch, and a batch of a dozen branches then waits for its merge. This file records two commands of the tool for that batch: `modustool queue`, which merges a batch into `master` after one full check, and `modustool rename-library`, which applies the move of the one source library into its two source libraries on any branch, after its merge of `master`.

## Purpose

- A full check costs much more than a merge. One full check for each branch of a batch makes the cost of the batch grow with the count of its branches. The merge queue checks the whole batch once, and pays more checks only when the batch fails.
- A move of most files of the repository must not wait until no branch is in flight. The rename command lets each branch apply the move by itself, after it merged `master`.

## Constraints

- A commit on `master` is proved by a full check ([full_check.md](full_check.md)): `nix flake check`, then `modustool screenshots`.
- Each merge into `master` keeps its own merge commit (`--no-ff`) with the summary of its branch, as the history of `master` shows today: `Merge branch '<branch>': <summary>`.
- A merge is made under the configured git user only, never under another identity.
- The tool uses the Odin standard library only, and has no script ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The commands of the tool").
- A host test runs no git and no Nix: the check of the flake runs the host tests in a sandbox.

## The merge queue

### The chosen form

`modustool queue <branch>...` takes the branches in the order of their merges.

1. **The refusals, with nothing changed.** An empty list; more than `QUEUE_BRANCH_LIMIT` (32) branches; a name that is empty or that starts with `-`; `master` or the branch of the queue; a branch named twice; a branch that does not exist; a branch with no commit that `master` does not hold; a branch whose worktree has changes that are not committed; a main tree that is not on `master` or that has changes; a `master` that does not hold `origin/master` after a fetch; a git with no `user.name` or no `user.email`; a set variable `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME` or `GIT_COMMITTER_EMAIL`, which would replace the configured user. Each refusal is one sentence, and the command lists every refused branch at once.
2. **The queue tree.** A worktree of git beside the main working tree, `../kernel-queue`, on the branch `queue/batch`. The main tree stays on `master` during the hours of the checks, so a developer keeps it.
3. **A group.** The queue tree is reset to `master`, then each branch of the group is merged in order with `git merge --no-ff -m <message>`. Its message is the message of the merge into `master`: when the check passes, `master` takes the queue branch by a fast-forward, and its history is the history of the merges of each branch into `master` in order.
4. **A conflict.** A conflict in the pictures of `docs/screenshots` and in the measure record `docs/measures/measures.txt` takes the side of the queue tree, which is `master` with the branches before: the full check writes both again. Any other conflict stops the group: the merge is aborted, and the sentence names the branch and its files. A conflict in the first group, the whole batch, stops the command: nothing is checked and nothing is merged.
5. **The full check.** In the queue tree: `nix flake check`, then `nix develop -c modustool screenshots`.
6. **The landing.** The pictures and the measure record that the check wrote are committed in the queue tree (`The screenshots of the merge queue: <branches>`), then `master` takes the queue branch with `git merge --ff-only`.
7. **The end.** When a group landed, `master` is pushed once. Then each merged branch loses its worktree (`git worktree remove`) and its branch (`git branch -d`). The queue tree and its branch are removed in every case.

**The summary of a branch.** The description of the branch in git (`git branch --edit-description`), which is the place of git for it. With no description, the subject of the oldest commit of the branch that `master` does not hold and that is not a merge: the newest one is often "The screenshots with …". Its first letter becomes lower case, unless the second letter is a capital (`QUIC`), as the merges of the history are written.

### The bisection, and its cost

When the full check of a group fails, the group splits into two halves, the first ⌈n/2⌉ branches and the rest. The first half is tried first, on `master`; when it passes it lands, and the second half is then tried on that new `master`. A group of one branch whose check fails names that branch at fault: it stays a branch. A conflict in a later group names its branch at fault at once, with no check, and the group is tried again without it.

The cost, for a batch of n branches and d = ⌈log₂ n⌉:

- No branch at fault: 1 full check.
- One branch at fault: at most 1 + 2d full checks. Each failed group checks its two halves, and the path from the batch to the branch has d failed groups. For 12 branches: 9 full checks, not 12.
- The tree of the halves has 2n − 1 groups: 23 for 12 branches. This is the cost with no bound.

**The bound.** The queue stops after `QUEUE_FAULT_LIMIT` (2) branches at fault: past two, the batch has a common cause, and a developer reads it. It never starts a check past its budget, min(2n − 1, 1 + 2d · `QUEUE_FAULT_LIMIT`): that is the worst case of two branches at fault, so the budget stops only a check that fails with no branch at fault, as a check that fails once and then passes. For 12 branches the budget is 17 full checks; for 32 branches, 21. The groups that were not checked stay branches, and the report names them and the reason of the stop.

### The interface that the tests replace

The decisions are pure procedures: the refusals of the arguments and of the facts of each branch, the message of a merge, the side of a conflict, the halves, the budget, and the run of the groups (`queue_run`). `queue_run` calls three procedures of a `Queue_Host`: the merge of a group, its full check, its landing. The command gives the host of git and Nix; a host test gives a host that answers from a list of the branches at fault and of the conflicts, and checks the order of the groups, the count of the checks, the budget and the stop.

### Refused forms

- **One full check for each branch.** n full checks for a batch of n, the cost that the queue removes.
- **The merges into `master` first, and a revert of a branch at fault.** `master` would hold a commit that no check proved, and each fault would add a second commit.
- **A rebase of the branches.** It flattens the merges of `master` into a branch, conflicts again on each, and changes the commits that the branch holds.
- **One octopus merge for the batch.** It loses the summary of each branch and the first-parent history of each merge.
- **A search one branch at a time.** n full checks for one branch at fault, against 1 + 2d.
- **The bisection with no bound.** 2n − 1 full checks when every check fails.
- **The checks in the main tree on a temporary branch.** The main tree would leave `master` for the hours of the checks.
- **The summary of the newest commit.** It is often the commit of the pictures.
- **A message typed for each branch on the command line.** Long, and git already has the description of a branch.
- **A commit with `--no-verify`, or under an identity of the command.** A merge of the queue is a merge of the configured user, with its hooks.

## The rename of the library as a command

### The chosen form

`modustool rename-library`, with no argument, applies the moves and the rewrites of the step of the two source libraries ([repository_layout.md](repository_layout.md), "The steps"). That design, its reasons and its hand changes are in that file; this command is its mechanical part. It changes these forms, and nothing else:

```
the folders               src/library/support/<x>    ->  src/library/modus/<x>
                          src/library/contract       ->  src/library/modus/contract
                          src/library/private        ->  src/library/internal
the import lines          "modus:support/<x>"        ->  "modus:<x>"
                          "modus:private/<m>/<p>"    ->  "internal:<m>/<p>"
                          "modus:contract/<x>"           stays
```

1. **The refusals, with nothing changed.** A tree with files in conflict (`git ls-files -u`); a tracked file whose new place holds a tracked file already, or is under a tracked file; a new place that exists on the disk with no tracked file in it.
2. **The moves.** For each old folder, in the order of the table, each tracked file under it goes to the same place under the new folder, with `git mv`. A move takes the largest folder whose new place holds no tracked file: on a tree before the rename, the three moves are three whole folders; on a branch that merged `master` after the rename, a package that the branch added moves whole, and a file that the branch added to a package that moved goes alone. Then each old folder that is empty leaves; a file that git does not track stays, and the command names it.
3. **The rewrites.** In each `.odin` file: the path of each import line, and the old folders and import paths in the comments. In each `.md`, `.txt` and `.manifest` file: the old folders and import paths anywhere in the text. A path is rewritten whole: a folder whose name only starts with the name of an old folder is not one, and a relative link that ends with an old folder is one.
4. **The report.** Each move, each file changed with its count of rewrites, and each line that still holds an old form: a string of an Odin source (a text that a process draws, an example of a host test, a constant of the tool). A developer changes these lines by hand, with the hand changes of the step.

**Idempotent.** A second run finds no tracked file under an old folder, and no text matches a rule: no new form holds an old form. So it moves nothing, rewrites nothing, and prints the same lines that it left.

**Safe on a branch.** A branch made before the rename merges `master`, then runs the command: it moves only what the branch added at the old places, and rewrites only the old forms that the branch added. So no branch waits for the others, and the move of `master` waits for no branch.

**What it does not read.** The records of their time: the news entries, the fragments of the changelog, `CHANGELOG.md` and `docs/measures/` (the `README.md` of `news/` and of `changelog.d/` are guides, and are read). The files that hold the old forms on purpose: the design of the step and of the SDK, this file, and the source and the host test of the command.

**Its own table.** The command names the old and the new folders in its own constants, not through the constants of the folders of the tool: the hand changes of the step change those, and the command must read the same before and after them.

### Refused forms

- **A `sed` over the list of the files.** The project has no script; `sed` rewrites a string of a source and a design that names the old form on purpose, and it moves no folder.
- **The strings of the Odin sources rewritten.** A text that a process draws changes its module and the width of its text; an example of a test names an old form to test it. The command lists them for a hand change.
- **One `git mv` for each file.** Thousands of host processes on a tree before the rename, where three moves suffice.
- **The rename on `master` only, and each branch made again.** The branches in flight would wait, or lose their history.
- **A commit by the command.** The rename and its hand changes are one commit, which the developer makes after a read of `git diff`.

## Subtle points

- The queue tree shares the references of the main repository: `master` in the queue tree is the `master` that the last landing moved.
- The pictures of a batch are the pictures of the tree of its last group: a commit of the pictures follows the merges of each group.
- The first conflict of the whole batch stops the command; a conflict in a later group comes from a branch at fault that left the batch, and names its branch.
- A branch that a developer changes during the run is merged as it was at the merge of its group.
- After the rename, a source of a branch that names a constant of the tool that the step removed does not compile: that is a hand change of the branch.
- The command `rename-library` has a use only while a branch made before the rename is in flight; then it leaves the tool.

## State

Built: `modustool queue` with its refusals, its queue tree, its bisection with its budget, its landing and its end, and its host tests on a host that replaces git and Nix. `modustool rename-library` with its moves, its rewrites, its report, and its host tests on a temporary tree with a host that replaces git.

Left: the removal of `rename-library` once no branch made before the rename is in flight.
