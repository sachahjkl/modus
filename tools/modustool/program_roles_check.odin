package modustool

import "core:fmt"
import "core:strings"
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

// program_roles_problems gives each fault of the rows against the modules
// of a build: a program of the boot image with no row, a row of no module
// of the boot image, a program with two rows, a grant that the contract
// does not have.
program_roles_problems :: proc(rows: []Site_Role_Row, builds: []Module_Build, file: string) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	named := make(map[string]bool, context.temp_allocator)
	for row in rows {
		if named[row.name] {
			append(&problems, fmt.tprintf("%s, line %d: the program %s has a second row in %s", file, row.line, row.name, PROGRAM_ROLES_TABLE))
		}
		named[row.name] = true
		in_image := false
		for build in builds {
			in_image ||= build.name == row.name && module_in_boot_image(build)
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
	}
	for build in builds {
		if !strings.has_prefix(build.source, PROGRAM_SOURCES) || !module_in_boot_image(build) || build.name == ROOT_SERVICE_MODULE {
			continue
		}
		if !named[build.name] {
			append(&problems, fmt.tprintf("%s: the program %s of the boot image has no row in %s: write its role, with no grant when it needs none", file, build.name, PROGRAM_ROLES_TABLE))
		}
	}
	return problems[:]
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
	rows, problem := site_role_table_read(text, SITE_ROOT_ROLES_FILE, PROGRAM_ROLES_TABLE)
	if problem != "" {
		fmt.eprintfln("modustool: %s", problem)
		return false
	}
	problems := program_roles_problems(rows, module_builds[:], SITE_ROOT_ROLES_FILE)
	for item in problems {
		fmt.eprintfln("modustool: %s", item)
	}
	return len(problems) == 0
}
