package build

import "core:fmt"
import "core:slice"
import "modus:contract/start_grant"
import "modustool:foundation"

// The check of the table of the start grant sets of the root service
// (docs/TOOLS.md, "The table of the start grant sets of the root service"): each module with an
// entry in the boot image has one row, and each row names a module of the boot image
// with start grants that the contract has. The root service gives a name
// with no row the zero start grant set; the table is whole only when the tool keeps
// it whole, so the check runs before each build, and the site reads the
// same rows.

// The table in ROOT_START_GRANT_SETS_FILE. The root service (ROOT_SERVICE_MODULE)
// has no row: the kernel starts it.
START_GRANT_SETS_TABLE :: "start_grant_sets"

// The list of the parts of the system in ROOT_START_GRANT_SETS_FILE: the processes
// that the root service starts itself, with handles that no grant names.
SYSTEM_PART_NAMES_LIST :: "system_part_names"

// The parts of the system whose rows hold Serve beside System_Part: their
// exports serve callers through a service ring given at start.
@(rodata)
SYSTEM_PARTS_THAT_SERVE := [?]string{
	"compositor",
	"powerbox",
	"collector",
	"disk_processes",
	"devices",
	"principals",
}

// start_grant_sets_problems gives each fault of the rows against the modules
// of a build and the parts of the system: a module with an entry in the
// boot image and no row, a row of no module of the boot image, a module
// with two rows, a
// grant that the contract does not have, the grant System_Part on a row
// that is no part of the system, and a part of the system whose row is not
// System_Part alone (with Serve for the compositor) with no term. The debug
// access to a process refuses a part of the system by that grant, and its
// starter gives no handle of another grant.
start_grant_sets_problems :: proc(rows: []foundation.Start_Grant_Set_Row, system_parts: []string, builds: []foundation.Module_Build, file: string) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	named := make(map[string]bool, context.temp_allocator)
	for row in rows {
		if named[row.name] {
			append(&problems, fmt.tprintf("%s, line %d: the process %s has a second row in %s", file, row.line, row.name, START_GRANT_SETS_TABLE))
		}
		named[row.name] = true
		in_image := false
		for build in builds {
			in_image ||= build.name == row.name && foundation.module_in_a_boot_image(build)
		}
		if !in_image || row.name == ROOT_SERVICE_MODULE {
			append(&problems, fmt.tprintf("%s, line %d: the row %s names no process that the root service starts from the boot image", file, row.line, row.name))
		}
		for grant in row.grants {
			known := false
			for member in start_grant.Grant {
				known ||= start_grant.GRANT_NAMES[member] == grant
			}
			if !known {
				append(&problems, fmt.tprintf("%s, line %d: the row %s names the grant %s, which is no start grant", file, row.line, row.name, grant))
			}
		}
		// The start grant of the start policy is a root ring that starts and
		// stops each process of the boot image: one row holds it, and alone.
		has_start_policy := slice.contains(row.grants, start_grant.GRANT_NAMES[.Start_Policy])
		if has_start_policy != (row.name == foundation.START_POLICY_MODULE) || has_start_policy && len(row.grants) != 1 {
			append(&problems, fmt.tprintf("%s, line %d: the row %s has the grants %v: the grant Start_Policy is for the row %s, alone", file, row.line, row.name, row.grants, foundation.START_POLICY_MODULE))
		}
		system_part := slice.contains(system_parts, row.name)
		has_system_part := slice.contains(row.grants, start_grant.GRANT_NAMES[.System_Part])
		switch {
		case has_system_part && !system_part:
			append(&problems, fmt.tprintf("%s, line %d: the row %s has the grant System_Part, and %s is not in %s: no starter of the root service gives it the handles of a part of the system", file, row.line, row.name, row.name, SYSTEM_PART_NAMES_LIST))
		case system_part && row.name != ROOT_SERVICE_MODULE && !system_part_grants_hold(row):
			append(&problems, fmt.tprintf("%s, line %d: the row %s of a part of the system has the grants %v and the terms \"%s\": it has System_Part, Serve beside it for serving system parts only, and no term", file, row.line, row.name, row.grants, row.terms))
		}
	}
	for build in builds {
		if !build.entry || !foundation.module_in_a_boot_image(build) || build.name == ROOT_SERVICE_MODULE {
			continue
		}
		if !named[build.name] {
			append(&problems, fmt.tprintf("%s: the process %s of the boot image has no row in %s: write its start grant set, with no grant when it needs none", file, build.name, START_GRANT_SETS_TABLE))
		}
	}
	for part in system_parts {
		if part != ROOT_SERVICE_MODULE && !named[part] {
			append(&problems, fmt.tprintf("%s: %s names %s, which has no row in %s", file, SYSTEM_PART_NAMES_LIST, part, START_GRANT_SETS_TABLE))
		}
	}
	return problems[:]
}

// system_part_grants_hold says if the row of a part of the system has the
// grants of its starter: System_Part, with Serve for the compositor, and no
// term.
system_part_grants_hold :: proc(row: foundation.Start_Grant_Set_Row) -> bool {
	expected := make([dynamic]string, context.temp_allocator)
	append(&expected, start_grant.GRANT_NAMES[.System_Part])
	if slice.contains(SYSTEM_PARTS_THAT_SERVE[:], row.name) {
		append(&expected, start_grant.GRANT_NAMES[.Serve])
	}
	if row.terms != "" || len(row.grants) != len(expected) {
		return false
	}
	for grant in expected {
		if !slice.contains(row.grants, grant) {
			return false
		}
	}
	return true
}

// start_grant_sets_read reads the rows and the list of the parts of the
// system from the source of the root service.
start_grant_sets_read :: proc(text: string) -> (rows: []foundation.Start_Grant_Set_Row, system_parts: []string, problem: string) {
	rows, problem = foundation.start_grant_set_table_read(text, foundation.ROOT_START_GRANT_SETS_FILE, START_GRANT_SETS_TABLE)
	if problem != "" {
		return nil, nil, problem
	}
	system_parts, problem = foundation.string_list_read(text, foundation.ROOT_START_GRANT_SETS_FILE, SYSTEM_PART_NAMES_LIST)
	return rows, system_parts, problem
}

// start_grant_sets_hold reads the table and checks it against module_builds.
// It prints each fault, and gives false when there is one: the build then
// stops before the first compiler starts.
start_grant_sets_hold :: proc() -> bool {
	text, read := foundation.read_text_file_quiet(foundation.ROOT_START_GRANT_SETS_FILE)
	if !read {
		fmt.eprintfln("modustool: cannot read %s", foundation.ROOT_START_GRANT_SETS_FILE)
		return false
	}
	rows, system_parts, problem := start_grant_sets_read(text)
	if problem != "" {
		fmt.eprintfln("modustool: %s", problem)
		return false
	}
	problems := start_grant_sets_problems(rows, system_parts, foundation.module_builds[:], foundation.ROOT_START_GRANT_SETS_FILE)
	for item in problems {
		fmt.eprintfln("modustool: %s", item)
	}
	return len(problems) == 0
}
