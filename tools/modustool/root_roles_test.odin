package modustool

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import "modus:contract/block"
import "modus:contract/entropy_service"
import "modus:contract/frame"
import op "modus:contract/operation"
import "modus:contract/root_ring"
import "modus:contract/start_grant"
import "modus:support/pci"
import "modus:support/system"

// Each role that the root service gives by a name starts: its handles take
// one context slot each. The roles are the rows of `process_roles`, as the
// site and the check of each build read them; the handles of a role are
// root_ring.role_handles, which the start follows; the slot of each handle
// is the row of ROLE_HANDLE_SLOTS and the number of its constant, read from
// the source of the table. A new grant of a role that puts two handles on
// one slot fails here, and not at the boot of the machine.
@(test)
each_role_of_process_roles_takes_each_context_slot_once :: proc(t: ^testing.T) {
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
	rows, rows_problem := site_role_table_read(roles_text, SITE_ROOT_ROLES_FILE, PROCESS_ROLES_TABLE)
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
			testing.expectf(t, known, "the row %s of process_roles names %s, which is no start grant", row.name, member)
		}
		taken: bit_set[0 ..< op.CONTEXT_HANDLES]
		for handle in root_ring.role_handles(role) {
			slot := slots[handle]
			if slot < 0 || slot >= op.CONTEXT_HANDLES {
				continue
			}
			testing.expectf(t, slot not_in taken, "the role %s of process_roles puts two handles on the context slot %d (one of them %v): it does not start", row.name, slot, handle)
			taken += {slot}
		}
	}
}

// The layout of the context of a device service, which the root service
// tries before it arms the device. A ring of the contract in a slot of the
// layout, or outside the handles, is refused first, with that slot; -1,
// one past the handles, the largest slot, the log, the budget, the machine,
// the queues, the last BAR and the last device behind a bridge. The rings
// of the block, frame and entropy contracts pass, last, and the trial takes
// exactly the slots of the layout.
@(test)
the_layout_of_a_device_service_takes_each_slot_once :: proc(t: ^testing.T) {
	refused := [?]int{-1, op.CONTEXT_HANDLES, max(int), op.CONTEXT_LOG, op.CONTEXT_BUDGET, pci.GRANT_MACHINE, pci.GRANT_QUEUES, pci.GRANT_INTERRUPT, pci.GRANT_CONFIGURATION, pci.GRANT_BAR + pci.BAR_COUNT - 1, pci.GRANT_BRIDGE_DEVICE + pci.BRIDGE_DEVICE_COUNT - 1}
	for ring_slot in refused {
		trial := pci.service_context_trial(ring_slot)
		testing.expectf(t, trial.refusal == (system.Context_Refusal{refused = true, place = ring_slot}), "the ring at the slot %d is taken: %v", ring_slot, trial.refusal)
	}
	rings := [?]int{block.SERVICE_RING, frame.SERVICE_RING, entropy_service.SERVICE_RING}
	for ring_slot in rings {
		trial := pci.service_context_trial(ring_slot)
		testing.expectf(t, !trial.refusal.refused, "the ring of a contract at the slot %d is refused at %d", ring_slot, trial.refusal.place)
		expected: bit_set[0 ..< op.CONTEXT_HANDLES; u16]
		expected += {ring_slot, op.CONTEXT_LOG, pci.GRANT_MACHINE, pci.GRANT_INTERRUPT, pci.GRANT_CONFIGURATION, pci.GRANT_QUEUES}
		for index in 0 ..< pci.BAR_COUNT {
			expected += {pci.GRANT_BAR + index}
		}
		for index in 0 ..< pci.BRIDGE_DEVICE_COUNT {
			expected += {pci.GRANT_BRIDGE_DEVICE + index}
		}
		testing.expect_value(t, trial.taken, expected)
	}
}

// The table of the roles is whole against the modules of the build. The
// faults come first, each with its line: a module with an entry in the
// boot image and no row, a row that names no such module (a disk process,
// the root service, a name of no module), a module with two rows, a grant
// that is no start grant, a part of the system whose row lacks System_Part
// or holds another grant or a term, a module that is no part of the system
// with System_Part, a part of the system with no row.
// The table of the repository, which the build checks, holds none of them,
// last.
@(test)
the_table_of_the_roles_is_whole :: proc(t: ^testing.T) {
	builds := []Module_Build {
		{name = "root", source = SYSTEM_MODULE_SOURCES + "root", entry = true, image = true},
		{name = "alpha", source = DEMONSTRATION_MODULE_SOURCES + "alpha", entry = true, image = true},
		{name = "beta", source = DEMONSTRATION_MODULE_SOURCES + "beta", entry = true, image = true},
		{name = "compositor", source = SYSTEM_MODULE_SOURCES + "compositor", entry = true, image = true},
		{name = "block", source = SYSTEM_MODULE_SOURCES + "block", entry = true, image = true},
		{name = "visitor", source = TEST_MODULE_SOURCES + "visitor", entry = true, image = true, disk = true},
		{name = "library", source = LIBRARY_MODULE_SOURCES + "library", image = true},
	}
	system_parts := []string{"root", "compositor", "block"}
	// The whole table, with one row replaced or added.
	with :: proc(base: []Site_Role_Row, replaced: Site_Role_Row) -> []Site_Role_Row {
		rows := make([dynamic]Site_Role_Row, context.temp_allocator)
		found := false
		for row in base {
			if row.name == replaced.name {
				append(&rows, replaced)
				found = true
			} else {
				append(&rows, row)
			}
		}
		if !found {
			append(&rows, replaced)
		}
		return rows[:]
	}
	expect_one :: proc(t: ^testing.T, rows: []Site_Role_Row, system_parts: []string, builds: []Module_Build, part: string) {
		problems := process_roles_problems(rows, system_parts, builds, "roles.odin")
		testing.expectf(t, len(problems) == 1 && strings.contains(problems[0], part), "the problems are %v, not one with %q", problems, part)
	}
	whole := []Site_Role_Row {
		{name = "alpha", line = 1},
		{name = "beta", grants = {"Inspect"}, line = 2},
		{name = "compositor", grants = {"Serve", "System_Part"}, line = 3},
		{name = "block", grants = {"System_Part"}, line = 4},
	}
	// A module with an entry in the boot image and no row.
	expect_one(t, {whole[1], whole[2], whole[3]}, system_parts, builds, "the process alpha of the boot image has no row")
	// A row of a disk process, of the root service, of no module.
	for name in ([?]string{"visitor", "root", "gamma"}) {
		expect_one(t, with(whole, {name = name, line = 5}), system_parts, builds, fmt.tprintf("line 5: the row %s names no process", name))
	}
	// A module with two rows, and a grant that is no start grant.
	two := make([dynamic]Site_Role_Row, context.temp_allocator)
	append(&two, ..whole)
	append(&two, Site_Role_Row{name = "alpha", line = 5})
	expect_one(t, two[:], system_parts, builds, "line 5: the process alpha has a second row")
	expect_one(t, with(whole, {name = "alpha", grants = {"Inspect", "Inspect_Everything"}, line = 1}), system_parts, builds, "line 1: the row alpha names the grant Inspect_Everything")
	// A part of the system that lacks System_Part, that holds another grant
	// or a term, and the compositor without Serve.
	broken_parts := [?]Site_Role_Row {
		{name = "block", line = 4},
		{name = "block", grants = {"Inspect"}, line = 4},
		{name = "block", grants = {"System_Part", "Acts_For_Principal"}, line = 4},
		{name = "block", grants = {"System_Part", "Serve"}, line = 4},
		{name = "block", grants = {"System_Part"}, terms = "on_demand = true", line = 4},
		{name = "compositor", grants = {"System_Part"}, line = 3},
	}
	for broken in broken_parts {
		expect_one(t, with(whole, broken), system_parts, builds, fmt.tprintf("line %d: the row %s of a part of the system", broken.line, broken.name))
	}
	// A module that is no part of the system, with System_Part.
	expect_one(t, with(whole, {name = "alpha", grants = {"System_Part"}, line = 1}), system_parts, builds, "line 1: the row alpha has the grant System_Part")
	expect_one(t, with(whole, {name = "beta", grants = {"Inspect", "System_Part"}, line = 2}), system_parts, builds, "line 2: the row beta has the grant System_Part")
	// A part of the system with no row.
	expect_one(t, whole, []string{"root", "compositor", "block", "glyphs"}, builds, "system_part_names names glyphs, which has no row")
	// A module with no entry may have a row: a service that starts as
	// a process at its first connection.
	testing.expect_value(t, len(process_roles_problems(with(whole, {name = "library", line = 5}), system_parts, builds, "roles.odin")), 0)
	testing.expect_value(t, len(process_roles_problems(whole, system_parts, builds, "roles.odin")), 0)
	roles_text, roles_read := site_read_quiet(SITE_ROOT_ROLES_FILE)
	testing.expect(t, roles_read)
	rows, repository_parts, problem := process_roles_read(roles_text)
	testing.expect_value(t, problem, "")
	testing.expect(t, len(repository_parts) > 1 && slice.contains(repository_parts, "block"))
	testing.expect_value(t, len(process_roles_problems(rows, repository_parts, module_builds[:], SITE_ROOT_ROLES_FILE)), 0)
}
