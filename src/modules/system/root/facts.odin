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
// number, time, process, level. The other fact types of this service are
// in the files facts_*.odin.
//
// A field of a name holds the bytes of the name and a zero byte after it.
// A Text field is [N]u8 with N written out, as the tool reads it: 24
// bytes for the name of a principal, of a grant or for the head of a
// client key, 32 for the name of a store. The Integer, Status and Bytes
// fields come first and the Text fields last: the serial line of a fact
// stops at its last byte that is not zero, so the zeros after a short name
// cost no byte.

// A process stopped itself: its stop cause is Itself, and its stop outcome
// says what it did with its work. `where(outcome = Done)` keeps the clean
// stops (src/md/api/process_stop.md).
@(log_fact = "root: {stopped_process} stopped: {cause}, {outcome}")
Process_Stopped :: struct {
	cause:           op.Stop_Cause,
	outcome:         op.Stop_Outcome,
	stopped_process: value_kinds.Module_Name_Field,
}

// A process stopped for another cause than itself: a holder, a fault, its
// last thread or its last handle. It chose no outcome.
@(log_fact = "root: {stopped_process} stopped: {cause}")
Process_Stopped_Without_Outcome :: struct {
	cause:           op.Stop_Cause,
	stopped_process: value_kinds.Module_Name_Field,
}

// The run of `unlock` that reads the machine key with no window, before
// the start policy, stopped itself. Its sentence is apart, so a wait for
// the stop of the `unlock` of the start list never takes it; its fields
// are those of Process_Stopped, so a reader of the stops reads both.
@(log_fact = "root: {stopped_process} read the machine key with no window and stopped: {cause}, {outcome}")
Unlock_Without_Window_Stopped :: struct {
	cause:           op.Stop_Cause,
	outcome:         op.Stop_Outcome,
	stopped_process: value_kinds.Module_Name_Field,
}

// The run of `unlock` with no window stopped for another cause than
// itself.
@(log_fact = "root: {stopped_process} read the machine key with no window and stopped: {cause}")
Unlock_Without_Window_Stopped_Without_Outcome :: struct {
	cause:           op.Stop_Cause,
	stopped_process: value_kinds.Module_Name_Field,
}

// A process of a test that this service starts by its own procedure, with
// the pages of its budget: shortage, operation_fuzzing.
@(log_fact = "root: started {started_process} with {pages}")
Process_Started_With_Budget :: struct {
	pages:           value_kinds.Size_In_Pages,
	started_process: value_kinds.Module_Name_Field,
}

// The start policy that principal 0 chose, started from the disk by its
// nickname, with the grant Start_Policy only.
@(log_fact = "root: started the chosen start policy \"{started_process}\" from the disk, hash {hash}, with the grant Start_Policy only")
Chosen_Start_Policy_Started :: struct {
	hash:            value_kinds.Hash_Field,
	started_process: value_kinds.Module_Name_Field,
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
	principal:       u64,
	started_process: value_kinds.Module_Name_Field,
	principal_name:  [24]u8,
}

// A process of the boot image started with a terminal, in the session of a
// named principal.
@(log_fact = "root: started {started_process}, with a terminal, in the session of principal {principal} \"{principal_name}\"")
Process_Started_With_Terminal_In_Session :: struct {
	principal:       u64,
	started_process: value_kinds.Module_Name_Field,
	principal_name:  [24]u8,
}

// A device service started for the device that this service found at a
// place of the bus 0.
@(log_fact = "root: started {service} for the device at the place {device} of the bus")
Device_Service_Started :: struct {
	device:  u64,
	service: value_kinds.Module_Name_Field,
}

// A device service started for a device behind a bridge, on another bus.
@(log_fact = "root: started {service} for the device at the place {device} of the bus {bus}, behind a bridge")
Device_Service_Started_Behind_Bridge :: struct {
	device:  u64,
	bus:     u64,
	service: value_kinds.Module_Name_Field,
}

// A disk process started for the machine, with no grant.
@(log_fact = "root: started {started_process} from the disk, hash {hash}, with no grant")
Disk_Process_Started :: struct {
	hash:            value_kinds.Hash_Field,
	started_process: value_kinds.Module_Name_Field,
}

// A disk process started for the machine, with the grant store.
@(log_fact = "root: started {started_process} from the disk, hash {hash}, with the grant store: the store {store}")
Disk_Process_Started_With_Store :: struct {
	hash:            value_kinds.Hash_Field,
	started_process: value_kinds.Module_Name_Field,
	store:           [32]u8,
}

// A disk process started with no grant, in the session of a named
// principal.
@(log_fact = "root: started {started_process} from the disk, hash {hash}, with no grant, in the session of principal {principal} \"{principal_name}\"")
Disk_Process_Started_In_Session :: struct {
	hash:            value_kinds.Hash_Field,
	principal:       u64,
	started_process: value_kinds.Module_Name_Field,
	principal_name:  [24]u8,
}

// A disk process started with the grant store, in the session of a named
// principal.
@(log_fact = "root: started {started_process} from the disk, hash {hash}, with the grant store: the store {store}, in the session of principal {principal} \"{principal_name}\"")
Disk_Process_Started_With_Store_In_Session :: struct {
	hash:            value_kinds.Hash_Field,
	principal:       u64,
	started_process: value_kinds.Module_Name_Field,
	store:           [32]u8,
	principal_name:  [24]u8,
}

// A caller is connected to a service, for the principal of its session.
@(log_fact = "root: connected {caller} to the service {service}, for principal {principal}")
Connected :: struct {
	principal: u64,
	caller:    value_kinds.Module_Name_Field,
	service:   value_kinds.Module_Name_Field,
}

// A caller is connected to a service, and acts for the principal of its
// session there.
@(log_fact = "root: connected {caller} to the service {service}, acting for principal {principal}")
Connected_Acting :: struct {
	principal: u64,
	caller:    value_kinds.Module_Name_Field,
	service:   value_kinds.Module_Name_Field,
}

// `remote` is connected to a service for one row of its client table, and
// calls for the principal of the row. The client key is the first 8 bytes
// of the key in 16 hexadecimal digits, as key_head_text writes them: a
// Text field, because a Hash field writes each byte of the field, and 24
// bytes so that the record ends on 8 bytes with no padding.
@(log_fact = "root: connected {caller} to the service {service}, for principal {principal}, for the client key {client_key}")
Connected_With_Client_Key :: struct {
	principal:  u64,
	caller:     value_kinds.Module_Name_Field,
	service:    value_kinds.Module_Name_Field,
	client_key: [24]u8,
}

// `remote` is connected to a service for one row of its client table, and
// acts for the principal of the row there.
@(log_fact = "root: connected {caller} to the service {service}, acting for principal {principal}, for the client key {client_key}")
Connected_Acting_With_Client_Key :: struct {
	principal:  u64,
	caller:     value_kinds.Module_Name_Field,
	service:    value_kinds.Module_Name_Field,
	client_key: [24]u8,
}

// A caller is connected to the store of its line history.
@(log_fact = "root: connected {caller} to the store of its line history in the service {service}, {limit}, for principal {principal}")
Connected_History :: struct {
	limit:     value_kinds.Size_In_Blocks,
	principal: u64,
	caller:    value_kinds.Module_Name_Field,
	service:   value_kinds.Module_Name_Field,
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
	connections: u64,
	holder:      value_kinds.Module_Name_Field,
	grant:       [24]u8,
}

// The grant network: its end changes the endpoints in the network service.
@(log_fact = "root: revoked the grant network of {holder}, endpoints changed: {endpoints}")
Grant_Revoked_Endpoints :: struct {
	endpoints: u64,
	holder:    value_kinds.Module_Name_Field,
}

// A grant whose end ends handles: the kernel ends each handle that came
// from it, in each process that holds one.
@(log_fact = "root: revoked the grant {grant} of {holder}, holdings ended: {holdings}")
Grant_Revoked_Holdings :: struct {
	holdings: u64,
	holder:   value_kinds.Module_Name_Field,
	grant:    [24]u8,
}

// The debugger service got the right to debug a process, for a caller.
@(log_fact = "root: gave {debugger} the right to debug {target} for {caller}, for principal {principal}")
Debug_Right_Given :: struct {
	principal: u64,
	debugger:  value_kinds.Module_Name_Field,
	target:    value_kinds.Module_Name_Field,
	caller:    value_kinds.Module_Name_Field,
}

// The entropy service answered a read with the tag of another read: the
// answer adds nothing, and counts as a refused read.
@(log_fact = "root: the entropy service answered the read {answered_read} with the tag of the read {tagged_read}: the answer adds nothing")
Entropy_Answer_Out_Of_Order :: struct {
	answered_read: u64,
	tagged_read:   u64,
}

// The entropy device did not answer the reads in flight by their deadline:
// each counts as refused, and the entropy service stops. The deadline is a
// count of seconds, as the line wrote it: a time field in seconds writes
// " s".
@(log_fact = "root: the entropy device did not answer a read in {deadline_seconds} seconds: {late_reads} reads count as refused, and the entropy service stops: no more bytes of the device")
Entropy_Reads_Late :: struct {
	deadline_seconds: u64,
	late_reads:       u64,
}

// The reads of the fresh bytes were refused too many times in a row: this
// service asks for no more.
@(log_fact = "root: the entropy device gave {refused_reads} refused reads in a row: no more fresh bytes for the running processes")
Fresh_Bytes_Reads_Refused_In_A_Row :: struct {
	refused_reads: u64,
}

// A read of the fresh bytes added nothing: the pages of the processes keep
// their bytes.
@(log_fact = "root: a read of the entropy device for the fresh bytes added nothing: the pages keep their bytes; refused reads in a row: {refused_reads}")
Fresh_Bytes_Read_Added_Nothing :: struct {
	refused_reads: u64,
}

// The entropy service stopped before it answered the reads of the start.
@(log_fact = "root: the entropy service stopped after {answered_reads} of {start_reads} reads: the random seed of the system has the bytes of those reads only")
Entropy_Service_Stopped_Early :: struct {
	answered_reads: u64,
	start_reads:    u64,
}

// The VirtIO-GPU device service started for a PCI GPU device on bus 0.
@(log_fact = "root: started gpu_device for the GPU at PCI device {device}")
Gpu_Driver_Started :: struct {
	device: u64,
}

// The VirtIO-GPU device service could not start for a discovered PCI GPU device.
@(log_fact = "root: gpu_device at PCI device {device} failed to start with {status}")
Gpu_Driver_Failed :: struct {
	status: op.Status,
	device: u32,
}

// The tables of this service after the stop of a process that can ask for
// wirings: the measure record reads its start (OWN_TABLES_MEASURE_LINE).
@(log_fact = "root: the tables of this service after the stop of {stopped_process}: {handles} handles, {prepared_parts} of them prepared parts, and {mappings} mappings, of {capacity} each")
Own_Tables_Measured :: struct {
	handles:         u64,
	prepared_parts:  u64,
	mappings:        u64,
	capacity:        u64,
	stopped_process: value_kinds.Module_Name_Field,
}

// A start found a table of this service full, and the kernel gave no
// report of the tables.
@(log_fact = "root: the start of {started_process} found a table full; the kernel gives no report of the tables of this service")
Own_Tables_Full_Unreported :: struct {
	started_process: value_kinds.Module_Name_Field,
}

// A start found a table of this service full: the count of each table.
@(log_fact = "root: the start of {started_process} found a table full: this service holds {mappings} mappings and {handles} handles, {prepared_parts} of them prepared parts, of {capacity} each")
Own_Tables_Full :: struct {
	mappings:        u64,
	handles:         u64,
	prepared_parts:  u64,
	capacity:        u64,
	started_process: value_kinds.Module_Name_Field,
}

// The root ring of a chosen start policy does not fit the wait of the loop.
@(log_fact = "root: cannot start the start policy {refused_process}: its root ring makes {words} words of the wait of the loop of this service, past its {word_limit}; the queues of the wait are full")
Start_Policy_Wait_Full :: struct {
	words:           u64,
	word_limit:      u64,
	refused_process: value_kinds.Module_Name_Field,
}

// The wait of the loop did not fit: written once.
@(log_fact = "root: the wait of the loop holds more words than {word_capacity}: each wait ends at once, and the queues past it are not waited on")
Root_Wait_Full :: struct {
	word_capacity: u64,
}

// The delegated wiring service did not start. The status is its number,
// as the line wrote it.
@(log_fact = "root: cannot start wiring service: status {status_number}")
Wiring_Service_Start_Failed :: struct {
	status_number: u64,
}

// The delegated wiring service started, within its bound of starts.
@(log_fact = "root: started delegated wiring service (start {starts} of {start_limit})")
Wiring_Service_Started :: struct {
	starts:      u64,
	start_limit: u64,
}

@(log_fact = "root: delegated wiring service stopped")
Wiring_Service_Stopped :: struct {}

// The delegated service disk_processes did not start.
@(log_fact = "root: cannot start the disk processes service: status {status}")
Disk_Processes_Service_Start_Failed :: struct {
	status: op.Status,
}

// The delegated service disk_processes started, within its bound of
// starts.
@(log_fact = "root: started the disk processes service (start {starts} of {start_limit})")
Disk_Processes_Service_Started :: struct {
	starts:      u64,
	start_limit: u64,
}

@(log_fact = "root: the disk processes service stopped")
Disk_Processes_Service_Stopped :: struct {}

// The service sent an event that no load takes, or took no Cancel: it is
// stopped, and the next load starts a fresh one.
@(log_fact = "root: the disk processes service broke its contract: it is stopped, and the next load starts it again")
Disk_Processes_Service_Faulted :: struct {}

// The service did not answer Cancel with Cancelled within its bound: it is
// stopped, and the loans of the ended load end with it.
@(log_fact = "root: the disk processes service did not give back the memory of an ended load in {bound}: it is stopped")
Disk_Processes_Cancel_Late :: struct {
	bound: value_kinds.Time_In_Milliseconds,
}

// The wiring service ended the wirings of a process whose grant wirings
// was revoked.
@(log_fact = "root: revoked the grant wirings of {target}, wirings ended: {ended}")
Wirings_Revoked :: struct {
	ended:  u64,
	target: value_kinds.Module_Name_Field,
}

// The delegated devices service did not start.
@(log_fact = "root: cannot start the devices service: status {status}")
Devices_Service_Start_Failed :: struct {
	status: op.Status,
}

// The delegated devices service started, within its bound of starts.
@(log_fact = "root: started the delegated devices service (start {starts} of {start_limit})")
Devices_Service_Started :: struct {
	starts:      u64,
	start_limit: u64,
}

@(log_fact = "root: the delegated devices service stopped")
Devices_Service_Stopped :: struct {}

// The devices service stopped or gave no answer while it classified the
// bus: it is stopped, and started again within its bound.
@(log_fact = "root: the devices service gave no answer for a device of the bus (start {starts}): it is stopped")
Devices_Service_Silent :: struct {
	starts: u64,
}

// The devices service classified the bus before any device service.
@(log_fact = "root: the devices service classified {classified} of the {looked_up} devices of the bus")
Bus_Classified :: struct {
	classified: u64,
	looked_up:  u64,
}

// The devices service did not classify the bus within its bound of starts.
@(log_fact = "root: the devices service did not classify the bus in {start_limit} starts: no device service starts, so the machine has no data disk, no network device, no sound device and no entropy device")
Devices_Service_Absent :: struct {
	start_limit: u64,
}

@(log_fact = "root: cannot read the configuration of the bus: status {status}: no device service starts")
Bus_Configuration_Unread :: struct {
	status: op.Status,
}

@(log_fact = "root: the bus holds more than {capacity} devices of a known class: the devices past them get no device service")
Classified_Devices_Full :: struct {
	capacity: u64,
}

// A device service whose device the devices service did not classify,
// because no devices service answered.
@(log_fact = "root: no devices service classified the bus: {service} does not start for the device {device} of the bus {bus}")
Device_Unclassified :: struct {
	device:  u64,
	bus:     u64,
	service: value_kinds.Module_Name_Field,
}

// The devices service answered a notice of a binding with a status that
// names no member.
@(log_fact = "root: the devices service answered with the status word {status_word}, which names no status")
Devices_Answer_Refused :: struct {
	status_word: u64,
}

// The devices service refused a notice of a binding: the core and the
// service disagree on a device.
@(log_fact = "root: the devices service refused a notice of a binding: status word {status_word}, values {first_value} and {second_value}")
Devices_Notice_Refused :: struct {
	status_word:  u64,
	first_value:  u64,
	second_value: u64,
}

// The delegated principals service did not start.
@(log_fact = "root: cannot start the principals service: status {status}")
Principals_Service_Start_Failed :: struct {
	status: op.Status,
}

// The delegated principals service started, within its bound of starts.
@(log_fact = "root: started the delegated principals service (start {starts} of {start_limit})")
Principals_Service_Started :: struct {
	starts:      u64,
	start_limit: u64,
}

@(log_fact = "root: the delegated principals service stopped")
Principals_Service_Stopped :: struct {}

// The principals service gave no answer to the call of a disk grant table
// in time: the core stops it, and starts it again within its bound.
@(log_fact = "root: the principals service gave no answer to the call of a disk grant table in time: it is stopped, and it starts again with no key until the next unlock")
Principals_Service_Silent :: struct {}

// The principals service did not start within its bound: the core keeps
// its state with no mirror.
@(log_fact = "root: the principals service did not start in {start_limit} starts: the root service keeps the principals, their disk grant tables and the client keys with no mirror")
Principals_Service_Absent :: struct {
	start_limit: u64,
}

// The principals service answered with a status that names no member, or
// with a tag that names no command in flight.
@(log_fact = "root: the principals service answered with the status word {status_word} and the tag {tag}, which name no status or no command in flight")
Principals_Answer_Refused :: struct {
	status_word: u64,
	tag:         u64,
}

// The principals service refused a command of the mirror: the core and
// the service disagree, and the core keeps its rule.
@(log_fact = "root: the principals service refused the command {command_word}: status word {status_word}, values {first_value} and {second_value}")
Principals_Command_Refused :: struct {
	command_word: u64,
	status_word:  u64,
	first_value:  u64,
	second_value: u64,
}

// The disk grant table of a principal does not pass the border of the set
// of rows: the service keeps the set before it.
@(log_fact = "root: the disk grant table of principal {principal} does not pass the border of the principals service: its rows are not sent")
Principals_Rows_Unsent :: struct {
	principal: u64,
}

// The core replaced the overrides of the roles with the set of a
// generation of the plan of principal 0. rollback is 1 for a rollback.
@(log_fact = "root: the roles of the plan of generation {generation} are in force: {overrides} overrides, serial {serial}, rollback {rollback}")
Plan_Roles_Replaced :: struct {
	generation: u64,
	serial:     u64,
	overrides:  u64,
	rollback:   u64,
}

// The core refused a set of the roles of a plan: no override changed.
@(log_fact = "root: refused the roles of the plan of generation {generation}: refusal {refusal_code} at the override {override_index}; the serial {serial} stays in force")
Plan_Roles_Refused :: struct {
	refusal_code:   u64,
	override_index: u64,
	generation:     u64,
	serial:         u64,
}

// One hash of the role contracts, as the root service computes it at its
// start (root_delegation.role_contracts_digest): encoded counts the
// contracts that pass their canonical encoding.
@(log_fact = "root: the role contracts: {encoded} of {contracts} encoded, digest {digest}")
Role_Contracts_Digest :: struct {
	contracts: u64,
	encoded:   u64,
	digest:    value_kinds.Hash_Field,
}

// A module that a plan names as the holder of a role does not fill the
// contract of the role: the result of the check, so a reader sees which
// face, export and parameter differ (role_contract.Contract_Check_Result).
@(log_fact = "root: {holder} does not fill the contract of the role {role_code}: refusal {refusal_code}, difference {difference_code}, face {face}, export {export}, parameter {parameter}")
Plan_Role_Contract_Not_Filled :: struct {
	role_code:       u64,
	refusal_code:    u64,
	difference_code: u64,
	face:            u64,
	export:          u64,
	parameter:       u64,
	holder:          value_kinds.Module_Name_Field,
}

// The fields of a name: the writers of the facts above fill them with the
// procedures of the contract, whose host tests give the edges of a cut.
module_name_field :: value_kinds.module_name_field
text_field :: value_kinds.text_field

// The powerbox did not start after the holder of Display: the trusted
// display has no picker of stores until a start of the powerbox.
@(log_fact = "root: the powerbox did not start after the compositor: status {status_number}; the picker of stores of the trusted display shows no store")
Powerbox_Start_Failed :: struct {
	status_number: u64,
}

// The powerbox asked for the stores of a principal, and this service gave
// no connection: the principal is not unlocked, or the storage service
// gave no connection. The picker shows no list, and the principal asks
// again.
@(log_fact = "root: gave the powerbox no list of the stores of the principal {principal}: the principal is not unlocked, or the storage service gave no connection")
Picker_Listing_Refused :: struct {
	principal: u64,
}
