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
// bytes for the name of a principal, of a grant or for the head of a
// client key, 32 for the name of a store.

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

// The run of `unlock` that reads the machine key with no window, before
// the start policy, stopped itself. Its sentence is apart, so a wait for
// the stop of the `unlock` of the start list never takes it; its fields
// are those of Process_Stopped, so a reader of the stops reads both.
@(log_fact = "root: {stopped_process} read the machine key with no window and stopped: {cause}, {outcome}")
Unlock_Without_Window_Stopped :: struct {
	stopped_process: value_kinds.Module_Name_Field,
	cause:           op.Stop_Cause,
	outcome:         op.Stop_Outcome,
}

// The run of `unlock` with no window stopped for another cause than
// itself.
@(log_fact = "root: {stopped_process} read the machine key with no window and stopped: {cause}")
Unlock_Without_Window_Stopped_Without_Outcome :: struct {
	stopped_process: value_kinds.Module_Name_Field,
	cause:           op.Stop_Cause,
}

// A process of a test that this service starts by its own procedure, with
// the pages of its budget: shortage, operation_fuzzing.
@(log_fact = "root: started {started_process} with {pages}")
Process_Started_With_Budget :: struct {
	started_process: value_kinds.Module_Name_Field,
	pages:           value_kinds.Size_In_Pages,
}

// The start policy that principal 0 chose, started from the disk by its
// nickname, with the grant Start_Policy only.
@(log_fact = "root: started the chosen start policy \"{started_process}\" from the disk, hash {hash}, with the grant Start_Policy only")
Chosen_Start_Policy_Started :: struct {
	started_process: value_kinds.Module_Name_Field,
	hash:            value_kinds.Hash_Field,
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

// `remote` is connected to a service for one row of its client table, and
// calls for the principal of the row. The client key is the first 8 bytes
// of the key in 16 hexadecimal digits, as key_head_text writes them: a
// Text field, because a Hash field writes each byte of the field, and 24
// bytes so that the field after it starts on 8 bytes with no padding.
@(log_fact = "root: connected {caller} to the service {service}, for principal {principal}, for the client key {client_key}")
Connected_With_Client_Key :: struct {
	caller:     value_kinds.Module_Name_Field,
	service:    value_kinds.Module_Name_Field,
	client_key: [24]u8,
	principal:  u64,
}

// `remote` is connected to a service for one row of its client table, and
// acts for the principal of the row there.
@(log_fact = "root: connected {caller} to the service {service}, acting for principal {principal}, for the client key {client_key}")
Connected_Acting_With_Client_Key :: struct {
	caller:     value_kinds.Module_Name_Field,
	service:    value_kinds.Module_Name_Field,
	client_key: [24]u8,
	principal:  u64,
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

// The fields of a name: the writers of the facts above fill them with the
// procedures of the contract, whose host tests give the edges of a cut.
module_name_field :: value_kinds.module_name_field
text_field :: value_kinds.text_field
