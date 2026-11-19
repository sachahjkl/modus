package root

import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The log facts of the root service (src/md/features/log_facts.md): the
// lines that a reader groups or filters, as records of fields. Each fact
// template is the sentence that the line wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before. A line whose
// sentence differs by its case (a terminal, the session of a named
// principal, a store) is one fact type for each case: the template has no
// condition. No field has the name of a column of the head of facts():
// number, time, process, level.
//
// A field of a name holds the bytes of the name and a zero byte after it.
// A Text field is [N]u8 with N written out, as the tool reads it: 24
// bytes for the name of a principal or of a grant, 32 for the name of a
// store.

// A process stopped itself: its stop cause is Itself, and its stop outcome
// says what it did with its work. `where(outcome = Done)` keeps the clean
// stops (src/md/api/process_stop.md).
@(log_fact = "root: {stopped_process} stopped: {cause}, {outcome}")
Process_Stopped :: struct {
	stopped_process: value_kinds.Module_Name_Field,
	cause:           op.Stop_Cause,
	outcome:         op.Stop_Outcome,
}

// A process stopped for another cause than itself: a holder, a fault, its
// last thread or its last handle. It chose no outcome.
@(log_fact = "root: {stopped_process} stopped: {cause}")
Process_Stopped_Without_Outcome :: struct {
	stopped_process: value_kinds.Module_Name_Field,
	cause:           op.Stop_Cause,
}

// A process of the boot image started, for the machine.
@(log_fact = "root: started {started_process}")
Process_Started :: struct {
	started_process: value_kinds.Module_Name_Field,
}

// A process of the boot image started with a terminal, for the machine.
@(log_fact = "root: started {started_process}, with a terminal")
Process_Started_With_Terminal :: struct {
	started_process: value_kinds.Module_Name_Field,
}

// A process of the boot image started in the session of a named principal.
@(log_fact = "root: started {started_process}, in the session of principal {principal} \"{principal_name}\"")
Process_Started_In_Session :: struct {
	started_process: value_kinds.Module_Name_Field,
	principal:       u64,
	principal_name:  [24]u8,
}

// A process of the boot image started with a terminal, in the session of a
// named principal.
@(log_fact = "root: started {started_process}, with a terminal, in the session of principal {principal} \"{principal_name}\"")
Process_Started_With_Terminal_In_Session :: struct {
	started_process: value_kinds.Module_Name_Field,
	principal:       u64,
	principal_name:  [24]u8,
}

// A device service started for the device that this service found at a
// place of the bus 0.
@(log_fact = "root: started {service} for the device at the place {device} of the bus")
Device_Service_Started :: struct {
	service: value_kinds.Module_Name_Field,
	device:  u64,
}

// A device service started for a device behind a bridge, on another bus.
@(log_fact = "root: started {service} for the device at the place {device} of the bus {bus}, behind a bridge")
Device_Service_Started_Behind_Bridge :: struct {
	service: value_kinds.Module_Name_Field,
	device:  u64,
	bus:     u64,
}

// A disk process started for the machine, with no grant.
@(log_fact = "root: started {started_process} from the disk, hash {hash}, with no grant")
Disk_Process_Started :: struct {
	started_process: value_kinds.Module_Name_Field,
	hash:            value_kinds.Hash_Field,
}

// A disk process started for the machine, with the grant store.
@(log_fact = "root: started {started_process} from the disk, hash {hash}, with the grant store: the store {store}")
Disk_Process_Started_With_Store :: struct {
	started_process: value_kinds.Module_Name_Field,
	hash:            value_kinds.Hash_Field,
	store:           [32]u8,
}

// A disk process started with no grant, in the session of a named
// principal.
@(log_fact = "root: started {started_process} from the disk, hash {hash}, with no grant, in the session of principal {principal} \"{principal_name}\"")
Disk_Process_Started_In_Session :: struct {
	started_process: value_kinds.Module_Name_Field,
	hash:            value_kinds.Hash_Field,
	principal:       u64,
	principal_name:  [24]u8,
}

// A disk process started with the grant store, in the session of a named
// principal.
@(log_fact = "root: started {started_process} from the disk, hash {hash}, with the grant store: the store {store}, in the session of principal {principal} \"{principal_name}\"")
Disk_Process_Started_With_Store_In_Session :: struct {
	started_process: value_kinds.Module_Name_Field,
	hash:            value_kinds.Hash_Field,
	store:           [32]u8,
	principal:       u64,
	principal_name:  [24]u8,
}

// A caller is connected to a service, for the principal of its session.
@(log_fact = "root: connected {caller} to the service {service}, for principal {principal}")
Connected :: struct {
	caller:    value_kinds.Module_Name_Field,
	service:   value_kinds.Module_Name_Field,
	principal: u64,
}

// A caller is connected to a service, and acts for the principal of its
// session there.
@(log_fact = "root: connected {caller} to the service {service}, acting for principal {principal}")
Connected_Acting :: struct {
	caller:    value_kinds.Module_Name_Field,
	service:   value_kinds.Module_Name_Field,
	principal: u64,
}

// A caller is connected to the store of its line history.
@(log_fact = "root: connected {caller} to the store of its line history in the service {service}, {limit}, for principal {principal}")
Connected_History :: struct {
	caller:    value_kinds.Module_Name_Field,
	service:   value_kinds.Module_Name_Field,
	limit:     value_kinds.Size_In_Blocks,
	principal: u64,
}

// A connection ended.
@(log_fact = "root: disconnected {caller} from the service {service}")
Disconnected :: struct {
	caller:  value_kinds.Module_Name_Field,
	service: value_kinds.Module_Name_Field,
}

// A grant whose end changes connections in their services: store,
// acts_for_principal, history.
@(log_fact = "root: revoked the grant {grant} of {holder}, connections changed: {connections}")
Grant_Revoked_Connections :: struct {
	holder:      value_kinds.Module_Name_Field,
	grant:       [24]u8,
	connections: u64,
}

// The grant network: its end changes the endpoints in the network service.
@(log_fact = "root: revoked the grant network of {holder}, endpoints changed: {endpoints}")
Grant_Revoked_Endpoints :: struct {
	holder:    value_kinds.Module_Name_Field,
	endpoints: u64,
}

// A grant whose end ends handles: the kernel ends each handle that came
// from it, in each process that holds one.
@(log_fact = "root: revoked the grant {grant} of {holder}, holdings ended: {holdings}")
Grant_Revoked_Holdings :: struct {
	holder:   value_kinds.Module_Name_Field,
	grant:    [24]u8,
	holdings: u64,
}

// The debugger service got the right to debug a process, for a caller.
@(log_fact = "root: gave {debugger} the right to debug {target} for {caller}, for principal {principal}")
Debug_Right_Given :: struct {
	debugger:  value_kinds.Module_Name_Field,
	target:    value_kinds.Module_Name_Field,
	caller:    value_kinds.Module_Name_Field,
	principal: u64,
}

// module_name_field gives the field of a fact that holds the name of a
// process, with a zero byte after it.
module_name_field :: proc "contextless" (name: string) -> (field: value_kinds.Module_Name_Field) {
	copy(field[:value_kinds.MODULE_NAME_FIELD_BYTES - 1], name)
	return
}

// text_field gives a Text field of a fact of N bytes: the text, cut at
// N - 1 bytes, with zero bytes after it.
text_field :: proc "contextless" (text: string, $N: int) -> (field: [N]u8) {
	copy(field[:N - 1], text)
	return
}
