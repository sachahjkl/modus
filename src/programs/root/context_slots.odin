package root

import "modus:contract/block"
import "modus:contract/datagram"
import "modus:contract/date"
import "modus:contract/frame"
import "modus:contract/remote"
import "modus:contract/settings"
import "modus:contract/tpm_service"
import "modus:support/disk_program"
import "modus:support/principals"
import "modus:support/system"

// The slots that a contract package or a support package names for its
// reader, checked against the one table of the context slots
// (src/library/support/system/grants.odin). A contract package imports no
// support package, so it keeps its own number; this service writes each
// slot by the name of the table, and the build stops when the two differ.
#assert(block.GRANT_RING == system.GRANT_DEVICE_RING)
#assert(frame.GRANT_RING == system.GRANT_DEVICE_RING)
#assert(date.GRANT_PAGE == system.GRANT_DATE_PAGE)
#assert(date.GRANT_PORTS == system.GRANT_DATE_PORTS)
#assert(datagram.GRANT_RING == system.GRANT_DATAGRAM_RING)
#assert(datagram.GRANT_REGION == system.GRANT_DATAGRAM_REGION)
#assert(datagram.SERVICE_CONTROL == system.GRANT_NETWORK_CONTROL)
#assert(settings.GRANT_PAGE == system.GRANT_SETTINGS_PAGE)
#assert(tpm_service.GRANT_RING == system.GRANT_TPM_RING)
#assert(tpm_service.GRANT_SERVICE == system.GRANT_TPM_SERVICE)
#assert(tpm_service.GRANT_REGION == system.GRANT_TPM_REGION)
#assert(remote.GRANT_CLIENT_TABLE == system.GRANT_CLIENT_TABLE)
#assert(disk_program.SERVICE_VALUE_PRINCIPAL == system.GRANT_VALUE_SERVICE_PRINCIPAL)
#assert(principals.VALUE_MODE == system.GRANT_VALUE_UNLOCK_MODE)
#assert(principals.VALUE_NAME == system.GRANT_VALUE_UNLOCK_NAME)
#assert(principals.VALUE_SEAL_ALLOWED == system.GRANT_VALUE_SEAL_ALLOWED)

// grant_slot_refused writes the line of a start that a taken slot stopped:
// two roles of the program have one slot, and the program does not start
// with one of the two handles lost. A slot is an int that the starter
// named, which can be negative: the line writes its word.
grant_slot_refused :: proc "contextless" (name: string, slot: int) {
	system.log_in("programs", .Error, "root: cannot start ", system.Module_Name{name}, ": two grants of its role take the handle ", u64(slot), " of its context, and a handle would be lost")
}

// context_refused says if a write into the context of a program was
// refused, and writes its line: each starter of this service reads it once,
// before the start, so no program starts with a handle or a value lost.
context_refused :: proc "contextless" (name: string, grants: ^system.Context_Grants, values: ^system.Context_Values) -> bool {
	if grants.refusal.refused {
		grant_slot_refused(name, grants.refusal.place)
		return true
	}
	if values.refusal.refused {
		system.log_in("programs", .Error, "root: cannot start ", system.Module_Name{name}, ": two parts of its start write the value ", u64(values.refusal.place), " of its context, and a value would be lost")
		return true
	}
	return false
}
