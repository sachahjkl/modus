package modustool

import "core:fmt"
import "core:strings"
import "core:testing"
import op "modus:contract/operation"
import "modus:contract/root_ring"
import "modus:contract/start_grant"

// Each role that the root service gives by a name starts: its handles take
// one context slot each. The roles are the rows of `program_roles`, as the
// site and the check of each build read them; the handles of a role are
// root_ring.role_handles, which the start follows; the slot of each handle
// is the row of ROLE_HANDLE_SLOTS and the number of its constant, read from
// the source of the table. A new grant of a role that puts two handles on
// one slot fails here, and not at the boot of the machine.
@(test)
each_role_of_program_roles_takes_each_context_slot_once :: proc(t: ^testing.T) {
	grants_text, grants_read := site_read_quiet(SITE_SYSTEM_GRANTS_FILE)
	testing.expectf(t, grants_read, "cannot read %s", SITE_SYSTEM_GRANTS_FILE)
	roles_text, roles_read := site_read_quiet(SITE_ROOT_ROLES_FILE)
	testing.expectf(t, roles_read, "cannot read %s", SITE_ROOT_ROLES_FILE)
	if !grants_read || !roles_read {
		return
	}
	constants, constants_problem := site_constants_read(grants_text, SITE_SYSTEM_GRANTS_FILE, "", {"GRANT_"})
	testing.expect_value(t, constants_problem, "")
	slots: [root_ring.Role_Handle]int
	named: bit_set[root_ring.Role_Handle]
	inside := false
	for line in strings.split_lines(grants_text, context.temp_allocator) {
		if strings.has_prefix(line, "ROLE_HANDLE_SLOTS :=") {
			inside = true
			continue
		}
		if !inside {
			continue
		}
		if strings.trim_space(line) == "}" {
			break
		}
		row := strings.trim_space(line)
		equal := strings.index(row, "=")
		if !strings.has_prefix(row, ".") || equal < 0 {
			continue
		}
		member := strings.trim_space(row[1:equal])
		place := strings.trim_suffix(strings.trim_space(row[equal + 1:]), ",")
		value := -1
		if place == "op.CONTEXT_LOG" {
			value = op.CONTEXT_LOG
		}
		for constant in constants {
			if constant.name == place {
				value = constant.value
			}
		}
		testing.expectf(t, value >= 0 && value < op.CONTEXT_HANDLES, "the row %s of ROLE_HANDLE_SLOTS names %s, which is no handle of the table", member, place)
		for handle in root_ring.Role_Handle {
			if fmt.tprint(handle) == member {
				slots[handle] = value
				named += {handle}
			}
		}
	}
	every_handle: bit_set[root_ring.Role_Handle]
	for handle in root_ring.Role_Handle {
		every_handle += {handle}
	}
	testing.expect_value(t, named, every_handle)
	rows, rows_problem := site_role_table_read(roles_text, SITE_ROOT_ROLES_FILE, PROGRAM_ROLES_TABLE)
	testing.expect_value(t, rows_problem, "")
	testing.expect(t, len(rows) > 0)
	for row in rows {
		role: bit_set[start_grant.Grant]
		for member in row.grants {
			known := false
			for grant in start_grant.Grant {
				if start_grant.GRANT_NAMES[grant] == member {
					role += {grant}
					known = true
				}
			}
			testing.expectf(t, known, "the row %s of program_roles names %s, which is no start grant", row.name, member)
		}
		taken: bit_set[0 ..< op.CONTEXT_HANDLES]
		for handle in root_ring.role_handles(role) {
			slot := slots[handle]
			if slot < 0 || slot >= op.CONTEXT_HANDLES {
				continue
			}
			testing.expectf(t, slot not_in taken, "the role %s of program_roles puts two handles on the context slot %d (one of them %v): it does not start", row.name, slot, handle)
			taken += {slot}
		}
	}
}

// The table of the roles is whole against the modules of the build. The
// faults come first, each with its line: a program of the boot image with
// no row, a row of a module that is no program of the boot image (a disk
// program, the root service, a name of no module), a program with two
// rows, a grant that is no start grant. The table of the repository, which
// the build checks, holds none of them, last.
@(test)
the_table_of_the_roles_is_whole :: proc(t: ^testing.T) {
	builds := []Module_Build {
		{name = "root", source = PROGRAM_SOURCES + "root", image = true},
		{name = "alpha", source = PROGRAM_SOURCES + "alpha", image = true},
		{name = "beta", source = PROGRAM_SOURCES + "beta", image = true},
		{name = "visitor", source = PROGRAM_SOURCES + "visitor", image = true, disk = true},
		{name = "library", source = MODULE_SOURCES + "library", image = true},
	}
	expect_one :: proc(t: ^testing.T, rows: []Site_Role_Row, builds: []Module_Build, part: string) {
		problems := program_roles_problems(rows, builds, "roles.odin")
		testing.expectf(t, len(problems) == 1 && strings.contains(problems[0], part), "the problems are %v, not one with %q", problems, part)
	}
	// A program of the boot image with no row.
	expect_one(t, {{name = "alpha", line = 1}}, builds, "the program beta of the boot image has no row")
	whole := []Site_Role_Row{{name = "alpha", line = 1}, {name = "beta", grants = {"Inspect"}, line = 2}}
	// A row of a disk program, of the root service, of no module.
	for name in ([?]string{"visitor", "root", "gamma"}) {
		rows := make([dynamic]Site_Role_Row, context.temp_allocator)
		append(&rows, ..whole)
		append(&rows, Site_Role_Row{name = name, line = 3})
		expect_one(t, rows[:], builds, fmt.tprintf("line 3: the row %s names no program", name))
	}
	// A program with two rows, and a grant that is no start grant.
	expect_one(t, {{name = "alpha", line = 1}, {name = "beta", line = 2}, {name = "alpha", line = 3}}, builds, "line 3: the program alpha has a second row")
	expect_one(t, {{name = "alpha", grants = {"Inspect", "Inspect_Everything"}, line = 1}, {name = "beta", line = 2}}, builds, "line 1: the row alpha names the grant Inspect_Everything")
	// A module that is no program may have a row: a service that starts as
	// a program at its first connection.
	testing.expect_value(t, len(program_roles_problems({{name = "alpha", line = 1}, {name = "beta", line = 2}, {name = "library", line = 3}}, builds, "roles.odin")), 0)
	testing.expect_value(t, len(program_roles_problems(whole, builds, "roles.odin")), 0)
	roles_text, roles_read := site_read_quiet(SITE_ROOT_ROLES_FILE)
	testing.expect(t, roles_read)
	rows, problem := site_role_table_read(roles_text, SITE_ROOT_ROLES_FILE, PROGRAM_ROLES_TABLE)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(program_roles_problems(rows, module_builds[:], SITE_ROOT_ROLES_FILE)), 0)
}
