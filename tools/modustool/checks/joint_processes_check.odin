package checks

import "core:fmt"
import "core:slice"
import "core:strings"
import "modustool:foundation"

// Check of service scopes and the closed list of joint processes in
// src/modules/system/root/start_grant_sets.odin
// (src/md/features/several_principals.md, "The services that keep data").
//
// Every row of `start_grant_sets` must declare `scope` explicitly as
// `.Machine` or `.Session`. Any `.Machine` row that serves connections
// (`.Serve`) and is reachable by a named principal must appear in the closed
// list `joint_process_names`. A `.Machine` row that holds `.Store` must also
// appear in `joint_process_names`.

JOINT_PROCESS_NAMES_LIST :: "joint_process_names"
START_GRANT_SETS_TABLE_NAME :: "start_grant_sets"
SYSTEM_PART_NAMES_LIST_NAME :: "system_part_names"

// row_callable_contains checks whether the serialized terms string of a row
// references `target` inside its `callable` array.
@(private = "file")
row_callable_contains :: proc(terms: string, target: string) -> bool {
	if terms == "" || target == "" {
		return false
	}
	needle := fmt.tprintf("\"%s\"", target)
	return strings.contains(terms, needle)
}

// joint_processes_problems parses a `start_grant_sets.odin` source string and
// returns every violation of the scope and closed joint-process rules.
joint_processes_problems :: proc(source, file: string) -> (problems: []string, row_count: int, joint_count: int) {
	list := make([dynamic]string, context.temp_allocator)
	rows, rows_problem := foundation.start_grant_set_table_read(source, file, START_GRANT_SETS_TABLE_NAME)
	if rows_problem != "" {
		append(&list, rows_problem)
		return list[:], 0, 0
	}
	joint_names, joint_problem := foundation.string_list_read(source, file, JOINT_PROCESS_NAMES_LIST)
	if joint_problem != "" {
		append(&list, joint_problem)
		return list[:], len(rows), 0
	}
	row_by_name := make(map[string]foundation.Start_Grant_Set_Row, context.temp_allocator)
	for row in rows {
		row_by_name[row.name] = row
		switch row.scope {
		case "Machine", "Session":
		case "":
			append(&list, fmt.tprintf("%s, line %d: the row %s has no explicit scope: write scope = .Machine or scope = .Session", file, row.line, row.name))
		case:
			append(&list, fmt.tprintf("%s, line %d: the row %s names scope .%s, which is not .Machine or .Session", file, row.line, row.name, row.scope))
		}
	}

	joint_seen := make(map[string]bool, context.temp_allocator)
	for name in joint_names {
		if joint_seen[name] {
			append(&list, fmt.tprintf("%s: %s lists %s more than once", file, JOINT_PROCESS_NAMES_LIST, name))
			continue
		}
		joint_seen[name] = true
		row, exists := row_by_name[name]
		if !exists {
			append(&list, fmt.tprintf("%s: %s lists %s, which has no row in %s", file, JOINT_PROCESS_NAMES_LIST, name, START_GRANT_SETS_TABLE_NAME))
			continue
		}
		if row.scope != "Machine" {
			append(&list, fmt.tprintf("%s, line %d: %s is in %s and must have scope = .Machine", file, row.line, name, JOINT_PROCESS_NAMES_LIST))
		}
	}

	for row in rows {
		if row.scope != "Machine" {
			continue
		}
		if joint_seen[row.name] {
			continue
		}
		has_serve := slice.contains(row.grants, "Serve")
		has_system_part := slice.contains(row.grants, "System_Part")
		has_store := slice.contains(row.grants, "Store")
		called_by_other := false
		for caller in rows {
			if row_callable_contains(caller.terms, row.name) {
				called_by_other = true
				break
			}
		}
		if has_serve && (!has_system_part || called_by_other) {
			append(&list, fmt.tprintf("%s, line %d: machine-scope service %s accepts connections and is not in %s: make it scope = .Session or add it to %s with a design review", file, row.line, row.name, JOINT_PROCESS_NAMES_LIST, JOINT_PROCESS_NAMES_LIST))
		}
		if has_store {
			append(&list, fmt.tprintf("%s, line %d: machine-scope process %s holds Store and is not in %s: make it scope = .Session", file, row.line, row.name, JOINT_PROCESS_NAMES_LIST))
		}
	}

	return list[:], len(rows), len(joint_names)
}

// joint_processes_check runs the scope and closed joint-process check on
// src/modules/system/root/start_grant_sets.odin.
joint_processes_check :: proc() -> bool {
	source, ok := foundation.read_text_file_quiet(foundation.ROOT_START_GRANT_SETS_FILE)
	if !ok {
		fmt.eprintfln("modustool: test failed: cannot read %s", foundation.ROOT_START_GRANT_SETS_FILE)
		return false
	}
	problems, row_count, joint_count := joint_processes_problems(source, foundation.ROOT_START_GRANT_SETS_FILE)
	for problem in problems {
		fmt.eprintfln("modustool: %s", problem)
	}
	if len(problems) > 0 {
		fmt.eprintfln("modustool: test failed: %d scope or joint-process violations in %s", len(problems), foundation.ROOT_START_GRANT_SETS_FILE)
		return false
	}
	foundation.test_passed_print("%s declares explicit scope on all %d rows and enforces %d closed joint processes", foundation.ROOT_START_GRANT_SETS_FILE, row_count, joint_count)
	return true
}
