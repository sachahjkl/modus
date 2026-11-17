package modustool

import "core:fmt"
import "core:strings"
import "core:testing"
import op "modus:contract/operation"
import "modus:contract/root_ring"
import "modus:contract/start_grant"

// Each role that the root service gives by a name starts: its handles take
// one context slot each. The roles are the cases of `grants_of`, as the site
// reads them; the handles of a role are root_ring.role_handles, which the
// start follows; the slot of each handle is the row of ROLE_HANDLE_SLOTS and
// the number of its constant, read from the source of the table. A new
// grant of a role that puts two handles on one slot fails here, and not at
// the boot of the machine.
@(test)
each_role_of_grants_of_takes_each_context_slot_once :: proc(t: ^testing.T) {
	grants_text, grants_read := site_read_quiet(SITE_SYSTEM_GRANTS_FILE)
	testing.expectf(t, grants_read, "cannot read %s", SITE_SYSTEM_GRANTS_FILE)
	root_text, root_read := site_read_quiet(SITE_ROOT_FILE)
	testing.expectf(t, root_read, "cannot read %s", SITE_ROOT_FILE)
	if !grants_read || !root_read {
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
	cases, _, cases_problem := site_name_switch_read(root_text, SITE_ROOT_FILE, "grants_of")
	testing.expect_value(t, cases_problem, "")
	testing.expect(t, len(cases) > 0)
	for role_case in cases {
		role: bit_set[start_grant.Grant]
		for member in role_case.members {
			known := false
			for grant in start_grant.Grant {
				if start_grant.GRANT_NAMES[grant] == member {
					role += {grant}
					known = true
				}
			}
			testing.expectf(t, known, "the case %v of grants_of names %s, which is no start grant", role_case.names, member)
		}
		taken: bit_set[0 ..< op.CONTEXT_HANDLES]
		for handle in root_ring.role_handles(role) {
			slot := slots[handle]
			if slot < 0 || slot >= op.CONTEXT_HANDLES {
				continue
			}
			testing.expectf(t, slot not_in taken, "the role %v of grants_of puts two handles on the context slot %d (one of them %v): it does not start", role_case.names, slot, handle)
			taken += {slot}
		}
	}
}
