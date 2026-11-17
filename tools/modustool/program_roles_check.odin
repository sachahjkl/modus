package modustool

import "core:fmt"
import "core:slice"
import "modus:contract/start_grant"

// The check of the table of the roles of the root service
// (docs/TOOLS.md, "The table of the roles of the root service"): each program of the
// boot image has one row, and each row names a module of the boot image
// with start grants that the contract has. The root service gives a name
// with no row the zero role; the table is whole only when the tool keeps
// it whole, so the check runs before each build, and the site reads the
// same rows.

// The table in SITE_ROOT_ROLES_FILE. The root service (ROOT_SERVICE_MODULE)
// has no row: the kernel starts it.
PROGRAM_ROLES_TABLE :: "program_roles"

// The list of the parts of the system in SITE_ROOT_ROLES_FILE: the programs
// that the root service starts itself, with handles that no grant names.
SYSTEM_PART_NAMES_LIST :: "system_part_names"

// The one part of the system whose row holds Serve beside System_Part: its
// exports serve the programs, and its starter gives it a service ring.
SYSTEM_PART_THAT_SERVES :: "compositor"

// program_roles_problems gives each fault of the rows against the modules
// of a build and the parts of the system: a program of the boot image with
// no row, a row of no module of the boot image, a program with two rows, a
// grant that the contract does not have, the grant System_Part on a row
// that is no part of the system, and a part of the system whose row is not
// System_Part alone (with Serve for the compositor) with no term. The debug
// access to a program refuses a part of the system by that grant, and its
// starter gives no handle of another grant.
program_roles_problems :: proc(rows: []Site_Role_Row, system_parts: []string, builds: []Module_Build, file: string) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	named := make(map[string]bool, context.temp_allocator)
	for row in rows {
		if named[row.name] {
			append(&problems, fmt.tprintf("%s, line %d: the program %s has a second row in %s", file, row.line, row.name, PROGRAM_ROLES_TABLE))
		}
		named[row.name] = true
		in_image := false
		for build in builds {
			in_image ||= build.name == row.name && module_in_a_boot_image(build)
		}
		if !in_image || row.name == ROOT_SERVICE_MODULE {
			append(&problems, fmt.tprintf("%s, line %d: the row %s names no program that the root service starts from the boot image", file, row.line, row.name))
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
		system_part := slice.contains(system_parts, row.name)
		has_system_part := slice.contains(row.grants, start_grant.GRANT_NAMES[.System_Part])
		switch {
		case has_system_part && !system_part:
			append(&problems, fmt.tprintf("%s, line %d: the row %s has the grant System_Part, and %s is not in %s: no starter of the root service gives it the handles of a part of the system", file, row.line, row.name, row.name, SYSTEM_PART_NAMES_LIST))
		case system_part && row.name != ROOT_SERVICE_MODULE && !system_part_grants_hold(row):
			append(&problems, fmt.tprintf("%s, line %d: the row %s of a part of the system has the grants %v and the terms \"%s\": it has System_Part, Serve beside it for %s only, and no term", file, row.line, row.name, row.grants, row.terms, SYSTEM_PART_THAT_SERVES))
		}
	}
	for build in builds {
		if !build.program || !module_in_a_boot_image(build) || build.name == ROOT_SERVICE_MODULE {
			continue
		}
		if !named[build.name] {
			append(&problems, fmt.tprintf("%s: the program %s of the boot image has no row in %s: write its role, with no grant when it needs none", file, build.name, PROGRAM_ROLES_TABLE))
		}
	}
	for part in system_parts {
		if part != ROOT_SERVICE_MODULE && !named[part] {
			append(&problems, fmt.tprintf("%s: %s names %s, which has no row in %s", file, SYSTEM_PART_NAMES_LIST, part, PROGRAM_ROLES_TABLE))
		}
	}
	return problems[:]
}

// system_part_grants_hold says if the row of a part of the system has the
// grants of its starter: System_Part, with Serve for the compositor, and no
// term.
system_part_grants_hold :: proc(row: Site_Role_Row) -> bool {
	expected := make([dynamic]string, context.temp_allocator)
	append(&expected, start_grant.GRANT_NAMES[.System_Part])
	if row.name == SYSTEM_PART_THAT_SERVES {
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

// program_roles_read reads the rows and the list of the parts of the
// system from the source of the root service.
program_roles_read :: proc(text: string) -> (rows: []Site_Role_Row, system_parts: []string, problem: string) {
	rows, problem = site_role_table_read(text, SITE_ROOT_ROLES_FILE, PROGRAM_ROLES_TABLE)
	if problem != "" {
		return nil, nil, problem
	}
	system_parts, problem = site_string_list_read(text, SITE_ROOT_ROLES_FILE, SYSTEM_PART_NAMES_LIST)
	return rows, system_parts, problem
}

// program_roles_hold reads the table and checks it against module_builds.
// It prints each fault, and gives false when there is one: the build then
// stops before the first compiler starts.
program_roles_hold :: proc() -> bool {
	text, read := site_read_quiet(SITE_ROOT_ROLES_FILE)
	if !read {
		fmt.eprintfln("modustool: cannot read %s", SITE_ROOT_ROLES_FILE)
		return false
	}
	rows, system_parts, problem := program_roles_read(text)
	if problem != "" {
		fmt.eprintfln("modustool: %s", problem)
		return false
	}
	problems := program_roles_problems(rows, system_parts, module_builds[:], SITE_ROOT_ROLES_FILE)
	for item in problems {
		fmt.eprintfln("modustool: %s", item)
	}
	return len(problems) == 0
}
