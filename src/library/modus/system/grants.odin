package system

import "base:intrinsics"
import "modus:contract/fixed_addresses"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/root_ring"
import "modus:contract/start_grant"

// The context slots of a process that the root service starts: the one
// table of the handles 0 to 13 and of the values 0 to 8 and 13, whose roles
// the root service and its process agree on (docs/MODULE_CONTRACT.md,
// "6. The context"). The handles from 14 and the other values have the
// roles that src/library/modus/contract/operation fixes for each process.
//
// A handle that the process was not granted is 0. Two roles share one slot
// only when no process holds both: a process has a window or a terminal,
// one device service, the TPM or an endpoint of the network, and a device
// service or the replacement table. Each
// starter of the root service writes each handle and each value through
// one procedure that refuses a place that is taken already, so a start grant set that
// holds two roles of one slot does not start, and loses no handle and no
// value in silence (src/md/api/root_ring.md).
// The package of each reader names its slots after this table: an alias,
// or a constant that the root service checks against it.

// The handle 0: the display ring to the compositor, a memory object with
// **Read** and **Write**. A process with a window sends its commands there,
// and receives its input as completion records (`src/library/modus/display`).
GRANT_DISPLAY :: 0 // Memory: the ring to the compositor.
// The handle 1: the root ring, a memory object with **Read** and **Write**,
// for a process with a start grant of `root_ring.ROOT_RING_GRANTS`, as the
// console. It sends `Root_Command` records on it: start, stop, connect,
// grants, revoke, replace, and the commands of the principals. The root
// service checks each command against the start grants of the sender.
GRANT_ROOT :: 1 // Memory: the ring to the root service, to start and stop processes.
// The handle 1 of a terminal, which has no root ring: the process that
// writes in it, with the right Read (package terminal).
GRANT_TERMINAL_PROCESS :: 1 // A terminal: the process that writes, with Read.
// The handle 0 of a terminal that draws no window (package terminal,
// renderer_context_of): the ports of the second serial port for
// serial_terminal, the framebuffer for grid_terminal. A terminal with a
// window has its display ring there.
GRANT_TERMINAL_DEVICE :: 0 // Ports, or memory: the device that the terminal draws on.
// The handle 2 of grid_terminal: the input ring of the input service, which
// it reads in place of the compositor.
GRANT_TERMINAL_INPUT :: 2 // Memory: the input ring.
// The handle 2: the machine, with only the rights of the grants of the
// process: **Inspect** to read the reports of the processes and of the
// kernel, **Stop** to stop the machine, **Schedule** to change the
// scheduling strategy.
GRANT_MACHINE :: 2 // The machine, with the rights of the start grant set: Inspect, or Inspect and Stop.
// The handle 3: the memory of the boot image, with **Read**, for a process
// with the grant Image: it lists the modules, loads them, and reads the
// descriptions of their exports. Its size is the value 0.
GRANT_IMAGE :: 3 // Memory: the boot image, to list the modules.
// The handle 4: the memory of the records of the log of the kernel, with
// **Read** only, for a process with the grant Log_Records: it reads the
// lines of every process, and writes none.
GRANT_LOG_RECORDS :: 4 // Memory, with Read: the records of the log.
// The handle 4 of a process with the grant Terminal, and of its terminal:
// the text region (package terminal). The one process with Log_Records,
// the log service, has a window.
GRANT_TERMINAL_TEXT :: 4 // Memory: the text region of a terminal.
// The handle 5: the service ring of a service, a memory object with
// **Read** and **Write**. The root service names each new connection of a
// caller on it, with the call ring and the call region of that caller
// (`src/library/modus/system/service.odin`). The file of the service is at the
// value 1.
GRANT_SERVICE :: 5 // Memory: the service ring. The root service names each connection of a caller on it.
// The handle 6 of a process with the grant Terminal, and of its terminal:
// the terminal ring (package terminal).
GRANT_TERMINAL_RING :: 6 // Memory: the terminal ring.
// The handle 6 of the client of a device service: the block ring of the
// grant Data_Disk or Scratch_Disk (modus:contract/block), the frame ring
// of the grant Network_Device (modus:contract/frame), or the stream ring of
// the grant Sound_Device (modus:contract/timed_stream). A client has one
// device service, and no terminal.
GRANT_DEVICE_RING :: 6 // Memory: the block ring, the frame ring or the stream ring.
// The handle 6 of the process `date`: the date page, with **Write**
// (modus:contract/date).
GRANT_DATE_PAGE :: 6 // Memory: the date page.
// The handle 7 of a process with the grant Store: the call ring of its
// private store (package storage).
GRANT_STORAGE_RING :: 7 // Memory: the call ring of the private store.
// The handle 7 of the process `date`: the two ports of the real-time clock.
GRANT_DATE_PORTS :: 7 // Ports: the real-time clock.
// The handle 8 of a process with the grant Store: the call region of its
// private store.
GRANT_STORAGE_REGION :: 8 // Memory: the call region of the private store.
// The handle 9 of a process with the grant Store: the storage service, with
// the right Read: its state.
GRANT_STORAGE_SERVICE :: 9 // The storage service, with Read.
// The handle 10: the replacement table of the machine, with **Read**
// only, for a process that loads modules by itself: its loader reads the
// table before each load, so a replacement reaches the loads that follow.
GRANT_REPLACEMENTS :: 10 // Memory, with Read: the replacement table of the machine (Replacement_Table).
// The handle 10 of the client of a device service: the device service of
// its device ring, with the right Read. Its stop is an event of the client,
// so a wait for an answer of the device service ends when it stops. No
// client of a device service loads modules by itself.
GRANT_DEVICE_SERVICE :: 10 // The device service of the device ring, with Read.
// The handle 11 of a process with the grant Network: the datagram ring of
// its endpoint (modus:contract/datagram).
GRANT_DATAGRAM_RING :: 11 // Memory: the datagram ring of the endpoint.
// The handle 11 of a process with the grant Tpm: the ring of the TPM
// service (modus:contract/tpm_service).
GRANT_TPM_RING :: 11 // Memory: the ring of the TPM service.
// The handle 12 of the network service (the grant Network_Device): the
// control ring from the root service (modus:contract/datagram).
GRANT_NETWORK_CONTROL :: 12 // Memory: the control ring of the network service.
// The handle 12 of the process `settings`: the settings page, with
// **Write** (modus:contract/settings).
GRANT_SETTINGS_PAGE :: 12 // Memory: the settings page.
// The handle 12 of a process with the grant Tpm: the TPM service, with the
// right Read: its state.
GRANT_TPM_SERVICE :: 12 // The TPM service, with Read.
// The handle 12 of the process with the grant Remote_Clients: the client
// table, with **Read** (modus:contract/remote).
GRANT_CLIENT_TABLE :: 12 // Memory, with Read: the client table.
// The handle 13 of a process with the grant Network: the datagram region of
// its endpoint.
GRANT_DATAGRAM_REGION :: 13 // Memory: the datagram region of the endpoint.
// The handle 13 of a process with the grant Tpm: the region of the TPM
// service.
GRANT_TPM_REGION :: 13 // Memory: the region of the TPM service.
// The value 0: the size in bytes of the boot image of the handle 3.
GRANT_VALUE_IMAGE_SIZE :: 0
// The values 0 to 3 of a terminal: the name of the process that writes in
// it, its title (package terminal).
GRANT_VALUE_TERMINAL_NAME :: 0
// The values 0 to 7 of the process `randomness`: the facts of the seed of
// the system, which only the root service has (modus:random).
GRANT_VALUE_SEED_FACTS :: 0
// The value 1, for a service: the address where the root service mapped
// the file of the process, read-only. The service reads the descriptions
// of its exports there, to check each call; the value 2 is its size.
GRANT_VALUE_FILE_ADDRESS :: 1 // A service: where the file of the process is, read-only (the descriptions of its exports).
// The value 2, for a service: the size in bytes of its file at the address
// of the value 1.
GRANT_VALUE_FILE_SIZE :: 2
// The value 3 of a process with the grant Store: the size in bytes of the
// file of the storage service, which its client reads (package storage).
GRANT_VALUE_STORAGE_FILE_SIZE :: 3
// The value 4 of the module file service `module_files`: the principal of its
// store (modus:disk_process).
GRANT_VALUE_SERVICE_PRINCIPAL :: 4
// The value 4 of a terminal: its columns.
GRANT_VALUE_TERMINAL_COLUMNS :: 4
// The value 5 of `unlock`: what this start does, the word of an
// Unlock_Mode (modus:principals).
GRANT_VALUE_UNLOCK_MODE :: 5
// The value 5 of a terminal: its rows.
GRANT_VALUE_TERMINAL_ROWS :: 5
// The values 6 to 8 of `unlock`: the name of the principal to create.
GRANT_VALUE_UNLOCK_NAME :: 6
// The value 14 of `unlock`: the number of the principal that asked for a change.
GRANT_VALUE_UNLOCK_PRINCIPAL :: 14
// The value 6 of a terminal: 1 when it shows the rates of its process.
GRANT_VALUE_TERMINAL_MEASURE :: 6
// The values 7, 8 and 13 of grid_terminal: the width and the height of the
// framebuffer in pixels, and its pixels of a line. The values 9 to 12 are
// the seed.
GRANT_VALUE_TERMINAL_SCREEN_WIDTH :: 7
GRANT_VALUE_TERMINAL_SCREEN_HEIGHT :: 8
GRANT_VALUE_TERMINAL_SCREEN_PIXELS_PER_LINE :: 13
// The value 13 of a process with the grant Tpm: 1 when a seal by the TPM is
// allowed, as the firmware verified the boot program.
GRANT_VALUE_SEAL_ALLOWED :: 13

// The context slot of each handle that the root service gives at a start
// (root_ring.Start_Grant_Set_Handle). The table is whole: a new handle does not
// compile until its row names its slot.
@(rodata)
START_GRANT_SET_HANDLE_SLOTS := [root_ring.Start_Grant_Set_Handle]int {
	.Display         = GRANT_DISPLAY,
	.Root_Ring       = GRANT_ROOT,
	.Machine         = GRANT_MACHINE,
	.Image           = GRANT_IMAGE,
	.Log_Records     = GRANT_LOG_RECORDS,
	.Service_Ring    = GRANT_SERVICE,
	.Terminal_Ring   = GRANT_TERMINAL_RING,
	.Terminal_Text   = GRANT_TERMINAL_TEXT,
	.Device_Ring     = GRANT_DEVICE_RING,
	.Date_Page       = GRANT_DATE_PAGE,
	.Date_Ports      = GRANT_DATE_PORTS,
	.Storage_Ring    = GRANT_STORAGE_RING,
	.Storage_Region  = GRANT_STORAGE_REGION,
	.Storage_Service = GRANT_STORAGE_SERVICE,
	.Replacements    = GRANT_REPLACEMENTS,
	.Datagram_Ring   = GRANT_DATAGRAM_RING,
	.Datagram_Region = GRANT_DATAGRAM_REGION,
	.Network_Control = GRANT_NETWORK_CONTROL,
	.Settings_Page   = GRANT_SETTINGS_PAGE,
	.Tpm_Ring        = GRANT_TPM_RING,
	.Tpm_Service     = GRANT_TPM_SERVICE,
	.Tpm_Region      = GRANT_TPM_REGION,
	.Client_Table    = GRANT_CLIENT_TABLE,
	.Device_Service  = GRANT_DEVICE_SERVICE,
	.Log             = op.CONTEXT_LOG,
}

// start_grant_set_slot_taken_twice says if two handles of a start grant set take one context
// slot, and the first such slot: a start of that start grant set is refused. It reads
// the same mapping that a start writes by.
start_grant_set_slot_taken_twice :: proc "contextless" (start_grant_set: bit_set[start_grant.Grant]) -> (slot: int, twice: bool) {
	trial: Context_Grants
	for handle in root_ring.start_grant_set_handles(start_grant_set) {
		if !grant_put(&trial, START_GRANT_SET_HANDLE_SLOTS[handle], {handle = 1}) {
			return START_GRANT_SET_HANDLE_SLOTS[handle], true
		}
	}
	return 0, false
}

// The first write into a context that was refused. A starter writes the
// whole context through grant_put, value_put, values_put and
// range_mapped_put, then reads this record once, before the start: a
// refused write stops the start, and the record names its place. A later
// refusal keeps the first, which is the one that a reader can act on.
Context_Refusal :: struct {
	refused: bool,
	place:   int, // The slot of the handle, or the index of the value, as the starter named it.
}

// context_refusal_note keeps the first refused place.
context_refusal_note :: proc "contextless" (refusal: ^Context_Refusal, place: int) {
	if !refusal.refused {
		refusal^ = {refused = true, place = place}
	}
}

// The handles that a starter writes into the context of a process, with
// the slots that it took. A slot takes one handle: a second write to it is
// refused and writes no handle, so two roles of one slot never lose a
// handle in silence.
Context_Grants :: struct {
	grants:  [op.CONTEXT_HANDLES]Grant,
	taken:   bit_set[0 ..< op.CONTEXT_HANDLES; u32],
	refusal: Context_Refusal,
}

// grant_put writes a handle into a slot of the context. It refuses a slot
// past the handles of the context, the slot of the budget, which the
// loader writes, the slots of the wiring ring and of the record output log,
// which only a wiring list fills (process_start refuses them too), and a
// slot that holds a handle already: it writes no handle and keeps the
// refusal with the slot, and the caller then does not start the process,
// and says which slot.
grant_put :: proc "contextless" (context_grants: ^Context_Grants, slot: int, grant: Grant) -> (ok: bool) {
	wiring_slot := slot == op.CONTEXT_WIRING_RING || slot == op.CONTEXT_LOG_OUTPUT || slot == op.CONTEXT_LOG_OUTPUT_END
	if slot < 0 || slot >= op.CONTEXT_HANDLES || slot == op.CONTEXT_BUDGET || wiring_slot || slot in context_grants.taken {
		context_refusal_note(&context_grants.refusal, slot)
		return false
	}
	context_grants.taken += {slot}
	context_grants.grants[slot] = grant
	return true
}

// The part of a context that a refusal names.
Context_Part :: enum u8 {
	Handle = 0, // A slot of the handles.
	Value  = 1, // An index of the values.
}

// context_refusal_of gives the first refusal of a context that a starter
// built, the handles before the values: the one decision of each starter
// before its start. refused false: no write was refused, and the start can
// run.
context_refusal_of :: proc "contextless" (grants: ^Context_Grants, values: ^Context_Values) -> (part: Context_Part, place: int, refused: bool) {
	if grants.refusal.refused {
		return .Handle, grants.refusal.place, true
	}
	if values.refusal.refused {
		return .Value, values.refusal.place, true
	}
	return .Handle, 0, false
}

// The values that a starter writes into the context of a process, with
// the indexes that it took. An index takes one value, as a slot takes one
// handle: two parts of a start that write one index lose no value in
// silence.
Context_Values :: struct {
	values:  [op.CONTEXT_VALUES]u64,
	taken:   bit_set[0 ..< op.CONTEXT_VALUES; u32],
	refusal: Context_Refusal,
}

// The facts of the seed of the system: the values 0 to 7 of the process
// `randomness` (random.report_values_write).
SEED_FACTS_VALUE_COUNT :: 8

// value_index_of_the_system says if a starter writes an index of the
// values with no value_put: the seed and its strength, which
// random.values_with_seed writes last over the values, and the fixed
// ranges, which range_mapped_put writes bit by bit.
value_index_of_the_system :: proc "contextless" (index: int) -> bool {
	in_the_seed := index >= op.CONTEXT_VALUE_SEED && index < op.CONTEXT_VALUE_SEED + op.CONTEXT_VALUE_SEED_COUNT
	return in_the_seed || index == op.CONTEXT_VALUE_SEED_STRENGTH || index == op.CONTEXT_VALUE_FIXED_RANGES_MAPPED
}

// value_put writes one value of the context. It refuses an index past the
// values, an index of the system, and an index that holds a value
// already: it writes no value and keeps the refusal.
value_put :: proc "contextless" (context_values: ^Context_Values, index: int, value: u64) -> (ok: bool) {
	if index < 0 || index >= op.CONTEXT_VALUES || value_index_of_the_system(index) || index in context_values.taken {
		context_refusal_note(&context_values.refusal, index)
		return false
	}
	context_values.taken += {index}
	context_values.values[index] = value
	return true
}

// values_put writes the words of one value of several words (a name) from
// the index `first`. It writes them all or none: a write with no word, a
// word past the values, or a word whose index value_put refuses refuses
// the whole write, and the refusal names the first index that is refused.
values_put :: proc "contextless" (context_values: ^Context_Values, first: int, words: []u64) -> (ok: bool) {
	if first < 0 || first >= op.CONTEXT_VALUES || len(words) == 0 {
		context_refusal_note(&context_values.refusal, first)
		return false
	}
	if len(words) > op.CONTEXT_VALUES - first {
		context_refusal_note(&context_values.refusal, op.CONTEXT_VALUES)
		return false
	}
	for index in first ..< first + len(words) {
		if value_index_of_the_system(index) || index in context_values.taken {
			context_refusal_note(&context_values.refusal, index)
			return false
		}
	}
	for word, offset in words {
		context_values.taken += {first + offset}
		context_values.values[first + offset] = word
	}
	return true
}

// range_mapped_put states in the values that the starter maps a fixed
// range (fixed_addresses.range_mapped_add). It refuses a range that is
// stated already: two mappings at one address, one of which the process
// would never read. The refusal names the value of the fixed ranges.
range_mapped_put :: proc "contextless" (context_values: ^Context_Values, range: fixed_addresses.Fixed_Range) -> (ok: bool) {
	if range in fixed_addresses.ranges_mapped(&context_values.values) {
		context_refusal_note(&context_values.refusal, op.CONTEXT_VALUE_FIXED_RANGES_MAPPED)
		return false
	}
	fixed_addresses.range_mapped_add(&context_values.values, range)
	return true
}

// The replacement table of the machine. The root service writes it, and
// gives it with the right Read. It gives the records to each process that
// it starts (system.process_start); a process that loads modules reads the
// table before each load. version is odd while the root service writes.
//
// A reader copies the table with `replacements_read`, which reads again
// while the version changes; `replacements_write` is for the root service.
// See [replacement table](term:replacement-table).
REPLACEMENT_CAPACITY :: 32 // The replacements of one machine. `Replace` gives No_Slot for one more.
Replacement_Table :: struct {
	version: u32, // Odd while the root service writes; one more at each start and each end of a write.
	count:   u32, // The records in use.
	records: [REPLACEMENT_CAPACITY]module.Replacement,
}
#assert(size_of(Replacement_Table) <= PAGE_SIZE)

// replacements_read copies the records of a replacement table that another
// process writes. It reads again while the table changes.
replacements_read :: proc "contextless" (table: ^Replacement_Table, records: ^[REPLACEMENT_CAPACITY]module.Replacement) -> []module.Replacement {
	if table == nil {
		return nil
	}
	for {
		version := intrinsics.atomic_load_explicit(&table.version, .Acquire)
		if version & 1 != 0 {
			continue
		}
		count := min(intrinsics.volatile_load(&table.count), REPLACEMENT_CAPACITY)
		intrinsics.mem_copy_non_overlapping(records, &table.records, size_of(table.records))
		intrinsics.atomic_thread_fence(.Acquire)
		if intrinsics.atomic_load_explicit(&table.version, .Relaxed) == version {
			return records[:count]
		}
	}
}

// replacements_write changes a replacement table: it sets the record of
// `from`, or removes it when `to` is zero. The one writer is the root
// service.
replacements_write :: proc "contextless" (table: ^Replacement_Table, from, to: [32]u8) -> Status {
	place := -1
	for index in 0 ..< int(table.count) {
		if table.records[index].from == from {
			place = index
		}
	}
	if to == {} && place < 0 {
		return .Bad_Handle
	}
	if to != {} && place < 0 && table.count == REPLACEMENT_CAPACITY {
		return .No_Slot
	}
	intrinsics.atomic_store_explicit(&table.version, table.version + 1, .Release)
	intrinsics.atomic_thread_fence(.Release)
	switch {
	case to == {}:
		table.records[place] = table.records[table.count - 1]
		table.records[table.count - 1] = {}
		table.count -= 1
	case place < 0:
		table.records[table.count] = {from = from, to = to}
		table.count += 1
	case:
		table.records[place].to = to
	}
	intrinsics.atomic_store_explicit(&table.version, table.version + 1, .Release)
	return .Ok
}

// The grants that the root service records for each process, and that it
// can revoke while the process runs (the command `Revoke`). Each grant is a
// handle of the context, or a connection that the root service made; a
// revocation ends each handle and each mapping that came from it.
//
// A recorded grant is not a start grant (modus:contract/start_grant). A start
// grant says what the start grant set of a process gives, and its name has capital
// letters (`Inspect`). A recorded grant says which handle the root service
// gave, and its name is in lower case (`machine`): the console types it.
// Several start grants are one recorded grant: `Inspect`, `Stop`,
// `Schedule` and `Events` are rights of the one handle `machine`.
Root_Grant :: enum u32 {
	Log         = 0, // Write on the log.
	Machine     = 1, // The machine, with the rights of the start grant set.
	Image       = 2, // Read the boot image.
	Log_Records = 3, // Read the records of the log.
	Store       = 4, // A private store in the storage service.
	Network     = 5, // An endpoint of datagrams in the network service, with one remote.
	Acts_For_Principal = 6, // To act for the principal of its session in each service that the process is connected to (isolated.CALLER_ACTS_FOR_PRINCIPAL).
	History     = 7, // The store of the line history of the console in the storage service (Root_Command.Connect_History).
	Debug       = 8, // The handle of another process with the right Debug, for each process that the command Debug named (Root_Command.Debug).
	Palette     = 9, // The entry table and the ring of the palette provider (Root_Command.Palette_Provide): the commands of the process show in the palette of the desktop.
	Wirings     = 10, // The wirings that the process asked for (Root_Command.Wire, and the wiring list of Start): their rings are paid from its budget. A revocation ends each of them with the end word Revoked.
}
// A set of grants: bit n is the grant n. The completion of `Grants` holds
// two of them.
Root_Grants :: bit_set[Root_Grant;u64]

// The name of each grant, as the console and the log write it.
root_grant_names := [Root_Grant]string {
	.Log         = "log",
	.Machine     = "machine",
	.Image       = "image",
	.Log_Records = "log_records",
	.Store       = "store",
	.Network     = "network",
	.Acts_For_Principal = "acts_for_principal",
	.History     = "history",
	.Debug       = "debug",
	.Palette     = "palette",
	.Wirings     = "wirings",
}

// A name of a process in a command of the root ring: 31 bytes at most, zero
// bytes after it.
Name :: [32]u8

// name_pack gives the four values of a name, as a command of the root ring
// carries it. A name longer than 31 bytes is cut.
name_pack :: proc "contextless" (name: string) -> (values: [4]u64) {
	bytes: Name
	copy(bytes[:len(bytes) - 1], name)
	return transmute([4]u64)bytes
}

// name_unpack gives the name of four values. Its last byte is always zero,
// whatever the values hold: a reader takes the bytes before the first zero.
name_unpack :: proc "contextless" (values: [4]u64) -> Name {
	bytes := transmute(Name)values
	bytes[len(bytes) - 1] = 0
	return bytes
}
