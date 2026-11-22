// Live delegated service tracking and restart supervision in the root core
// (src/md/api/root_service_split.md).
//
// Tracks the delegated system services (disk_processes, principals, devices,
// settings, powerbox, plans, recipes, projects) by their closed Role so the
// root core advances supervision generations and enforces bounded restart
// windows cleanly whenever a delegated service stops.
package root

import "modus:contract/console_prompt"
import "modus:contract/role_contract"

Delegated_Kind :: enum u8 {
	Disk_Processes = 0,
	Principals     = 1,
	Devices        = 2,
	Settings       = 3,
	Powerbox       = 4,
	Plans          = 5,
	Recipes        = 6,
	Projects       = 7,
}

@(rodata)
DELEGATED_ROLES := [Delegated_Kind]role_contract.Role{
	.Disk_Processes = .Disk_Processes,
	.Principals     = .Principals,
	.Devices        = .Devices,
	.Settings       = .Settings,
	.Powerbox       = .Powerbox,
	.Plans          = .Plans,
	.Recipes        = .Recipes,
	.Projects       = .Projects,
}

Delegated_Service_Slot :: struct {
	role:        role_contract.Role,
	supervision: console_prompt.Start_Row_Supervision,
	stop_count:  u64,
}

delegated_services: [Delegated_Kind]Delegated_Service_Slot
delegated_services_ready: bool

delegated_services_init :: proc "contextless" () {
	if delegated_services_ready {
		return
	}
	for kind in Delegated_Kind {
		role := DELEGATED_ROLES[kind]
		delegated_services[kind] = {
			role = role,
			supervision = {
				active            = true,
				row_id            = u16(kind) + 1,
				rank              = 1,
				restart_group     = 0,
				needed_for_usable = kind == .Disk_Processes || kind == .Principals || kind == .Devices || kind == .Settings,
				window_ms         = 60_000,
				max_restarts      = 5,
			},
		}
	}
	delegated_services_ready = true
}

delegated_service_module_for_role :: proc "contextless" (kind: Delegated_Kind) -> string {
	return role_holder_name(DELEGATED_ROLES[kind])
}

delegated_service_on_stop :: proc "contextless" (module_name: string, now_ms: u64, machine_usable: bool) -> (matched: bool, decision: console_prompt.Restart_Decision) {
	if !delegated_services_ready {
		delegated_services_init()
	}
	for kind in Delegated_Kind {
		role := DELEGATED_ROLES[kind]
		if is_role_holder(module_name, role) {
			slot := &delegated_services[kind]
			slot.stop_count += 1
			return true, console_prompt.supervision_on_row_stop(&slot.supervision, now_ms, machine_usable)
		}
	}
	return false, .Leave_Stopped
}
