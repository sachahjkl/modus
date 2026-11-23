package machine

import "core:strings"

// The check of the floors at the end of each machine test
// (src/md/features/module_budget_request.md, "The peak of a budget"): the
// root service writes Budget_Floor_Passed when a process paid more than
// the floor of its start before its first state of work, and the test
// fails on that line. The floor that the module states is then wrong, and
// the line names the process, its peak and its floor.

// The words of the sentence of Budget_Floor_Passed after the name of the
// process (src/modules/system/root/facts_start.odin). A host test reads the
// template of the fact and checks that it holds them.
FLOOR_PASSED_MARK :: " passed its floor before its first state of work: "

// floor_passed_line gives the first line of a log that says that a process
// passed its floor, or found false.
floor_passed_line :: proc(log: string) -> (line: string, found: bool) {
	rest := log
	for len(rest) > 0 {
		end := strings.index_byte(rest, '\n')
		current := end < 0 ? rest : rest[:end]
		if strings.contains(current, FLOOR_PASSED_MARK) {
			return strings.trim_space(current), true
		}
		if end < 0 {
			break
		}
		rest = rest[end + 1:]
	}
	return "", false
}
