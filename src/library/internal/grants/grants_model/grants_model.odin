// Pure snapshot model, border decoders, flat row builder, and inline
// confirmation state for the desktop Grants window
// (src/md/features/grants_window.md). Freestanding, zero allocations, and
// tested on the host.
package grants_model

import "modus:contract/root_ring"
import "modus:contract/wide_grants"
import "modus:disk_process"
import "modus:system"

// Inline capacity: typical desktop sessions hold under 24 processes with
// revocable grants. Overflow past this count increments processes_truncated
// instead of failing the refresh.
PROCESS_ROW_CAPACITY :: 64

// Format property: the disk grant table of one principal holds at most
// disk_process.ROW_CAPACITY rows.
DISK_ROW_CAPACITY :: disk_process.ROW_CAPACITY

// Computed: worst-case flat display rows built once per snapshot refresh:
// 3 section headers + 1 wide grant row (or empty line) + 1 process empty line
// or PROCESS_ROW_CAPACITY * (1 process heading + len(system.Root_Grant) grant
// rows) + 1 truncation footnote + 1 disk empty line or DISK_ROW_CAPACITY * 2.
DISPLAY_ROW_CAPACITY :: 3 + 1 + 1 + PROCESS_ROW_CAPACITY * (1 + len(system.Root_Grant)) + 1 + DISK_ROW_CAPACITY * 2

// Complete mask of valid system.Root_Grant bits for border validation.
ALL_ROOT_GRANTS_MASK :: u64(1 << len(system.Root_Grant)) - 1

// Complete mask of valid disk_process.Disk_Grant bits for border validation.
ALL_DISK_GRANTS_MASK :: u64(1 << len(disk_process.Disk_Grant)) - 1

// One running process of the current principal that holds or lost grants.
Process_Row :: struct {
	name:        [len(system.Name) - 1]u8,
	name_length: int,
	granted:     system.Root_Grants,
	revoked:     system.Root_Grants,
}

// Active wide grant of the current principal, when active is true.
Wide_Grant_Row :: struct {
	active:       bool,
	client_key:   [32]u8,
	scopes:       wide_grants.Wide_Authorities,
	ends_at_ms:   u64,
	grant_serial: u64,
}

// One remembered disk grant row of the current principal.
Disk_Row :: struct {
	nickname:          [disk_process.NAME_LIMIT]u8,
	nickname_length:   int,
	hash_prefix:       u64,
	grants:            disk_process.Disk_Grants,
	persistence:       root_ring.Disk_Grant_Row_Persistence,
	forget_by_default: bool,
	lasting:           root_ring.Disk_Grant_Lasting,
}

// Immutable grant state captured by the worker thread from the root service.
Snapshot :: struct {
	loaded:              bool,
	has_error:           bool,
	wide_grant:          Wide_Grant_Row,
	processes:           [PROCESS_ROW_CAPACITY]Process_Row,
	process_count:       int,
	processes_total:     u64,
	processes_truncated: u64,
	disks:               [DISK_ROW_CAPACITY]Disk_Row,
	disk_count:          int,
	disks_total:         u64,
	disks_truncated:     u64,
}

// What one revocation action targets.
Action_Target_Kind :: enum u8 {
	None          = 0,
	Wide_Grant    = 1,
	Process_Grant = 2,
	Disk_Grant    = 3,
}

Action_Target :: struct {
	kind:          Action_Target_Kind,
	process_index: int,
	root_grant:    system.Root_Grant,
	disk_index:    int,
	disk_grant:    disk_process.Disk_Grant,
}

// Inline two-step confirmation state so one press arms the action and a second
// press on the action-named button executes it.
Confirm_State :: struct {
	armed:  bool,
	target: Action_Target,
}

// Section classification of a precomputed display row.
Section_Kind :: enum u8 {
	Wide_Grant = 0,
	Process    = 1,
	Disk_Grant = 2,
}

// Visual kind of one precomputed display row.
Display_Row_Kind :: enum u8 {
	Section_Heading   = 0,
	Empty_Notice      = 1,
	Wide_Grant_Item   = 2,
	Process_Heading   = 3,
	Process_Grant     = 4,
	Disk_Grant_Item   = 5,
	Truncation_Notice = 6,
}

// One flat row in the precomputed view list; rebuilt only when Snapshot changes.
Display_Row :: struct {
	kind:          Display_Row_Kind,
	section:       Section_Kind,
	process_index: int,
	root_grant:    system.Root_Grant,
	grant_revoked: bool, // True when Process_Grant is already revoked (read-only).
	disk_index:    int,
	disk_grant:    disk_process.Disk_Grant,
	removable:     bool,
}

// Precomputed flat list of rows for O(visible) frame rendering.
Display_List :: struct {
	rows:  [DISPLAY_ROW_CAPACITY]Display_Row,
	count: int,
}

process_row_name :: proc "contextless" (row: ^Process_Row) -> string {
	if row == nil || row.name_length <= 0 || row.name_length > len(row.name) {
		return ""
	}
	return string(row.name[:row.name_length])
}

disk_row_nickname :: proc "contextless" (row: ^Disk_Row) -> string {
	if row == nil || row.nickname_length <= 0 || row.nickname_length > len(row.nickname) {
		return ""
	}
	return string(row.nickname[:row.nickname_length])
}

// snapshot_add_process_completion validates one Grants_Read(.Process)
// completion at the border and appends it to snap. Unknown grant bits are
// refused; rows beyond PROCESS_ROW_CAPACITY increment processes_truncated.
snapshot_add_process_completion :: proc "contextless" (snap: ^Snapshot, values: [7]u64) -> (total: u64, added: bool) {
	if snap == nil {
		return 0, false
	}
	total = values[6]
	snap.processes_total = total
	unpacked := system.name_unpack({values[0], values[1], values[2], values[3]})
	name := system.name_of(unpacked[:])
	if len(name) == 0 {
		return total, false
	}
	// Border: refuse unknown bits outside system.Root_Grant.
	if (values[4] &~ ALL_ROOT_GRANTS_MASK) != 0 || (values[5] &~ ALL_ROOT_GRANTS_MASK) != 0 {
		return total, false
	}
	if snap.process_count >= PROCESS_ROW_CAPACITY {
		snap.processes_truncated += 1
		return total, false
	}
	row := &snap.processes[snap.process_count]
	row^ = {
		granted = transmute(system.Root_Grants)values[4],
		revoked = transmute(system.Root_Grants)values[5],
	}
	row.name_length = copy(row.name[:], name)
	snap.process_count += 1
	return total, true
}

// snapshot_set_wide_grant_completion validates one Grants_Read(.Wide_Grant)
// completion at the border. Serial 0 clears the wide grant; unknown authority
// bits or a zero client key with a non-zero serial are refused fail-closed.
snapshot_set_wide_grant_completion :: proc "contextless" (snap: ^Snapshot, values: [7]u64) -> bool {
	if snap == nil {
		return false
	}
	snap.wide_grant = {}
	if values[6] == 0 {
		return true
	}
	scopes, scopes_ok := wide_grants.wide_authorities_from_word(values[4])
	if !scopes_ok || scopes == {} {
		return false
	}
	key := transmute([32]u8)([4]u64{values[0], values[1], values[2], values[3]})
	if key == {} {
		return false
	}
	snap.wide_grant = {
		active       = true,
		client_key   = key,
		scopes       = scopes,
		ends_at_ms   = values[5],
		grant_serial = values[6],
	}
	return true
}

// snapshot_add_disk_completion validates one Grants_Read(.Disk_Grant)
// completion at the border and appends it to snap. Unknown grant bits or
// malformed metadata are refused; rows beyond DISK_ROW_CAPACITY increment
// disks_truncated.
snapshot_add_disk_completion :: proc "contextless" (snap: ^Snapshot, values: [7]u64) -> (total: u64, added: bool) {
	if snap == nil {
		return 0, false
	}
	total = values[6]
	snap.disks_total = total
	nickname_bytes, nickname_length := disk_process.name_unpack({values[0], values[1], values[2]})
	if nickname_length == 0 {
		return total, false
	}
	if (values[4] &~ ALL_DISK_GRANTS_MASK) != 0 {
		return total, false
	}
	persistence, forget_by_default, lasting, meta_ok := root_ring.disk_grant_meta_unpack(values[5])
	if !meta_ok {
		return total, false
	}
	if snap.disk_count >= DISK_ROW_CAPACITY {
		snap.disks_truncated += 1
		return total, false
	}
	row := &snap.disks[snap.disk_count]
	row^ = {
		hash_prefix       = values[3],
		grants            = transmute(disk_process.Disk_Grants)u8(values[4]),
		persistence       = persistence,
		forget_by_default = forget_by_default,
		lasting           = lasting,
	}
	row.nickname_length = copy(row.nickname[:], nickname_bytes[:nickname_length])
	snap.disk_count += 1
	return total, true
}

// process_grant_removable reports whether a process grant is currently held
// and can be revoked.
process_grant_removable :: proc "contextless" (snap: ^Snapshot, process_index: int, grant: system.Root_Grant) -> bool {
	if snap == nil || process_index < 0 || process_index >= snap.process_count {
		return false
	}
	return grant in snap.processes[process_index].granted
}

// disk_grant_removable reports whether a disk grant row holds a grant that
// Disk_Grant(.Disallow) accepts. Start_Policy rows are changed only through
// start policy selection and are never removable here.
disk_grant_removable :: proc "contextless" (snap: ^Snapshot, disk_index: int, grant: disk_process.Disk_Grant) -> bool {
	if snap == nil || disk_index < 0 || disk_index >= snap.disk_count {
		return false
	}
	switch grant {
	case .Store:
		return .Store in snap.disks[disk_index].grants
	case .Start_Policy:
		return false
	}
	return false
}

// target_valid reports whether target refers to a live revocable grant in snap.
target_valid :: proc "contextless" (snap: ^Snapshot, target: Action_Target) -> bool {
	if snap == nil {
		return false
	}
	switch target.kind {
	case .None:
		return false
	case .Wide_Grant:
		return snap.wide_grant.active && snap.wide_grant.grant_serial != 0
	case .Process_Grant:
		return process_grant_removable(snap, target.process_index, target.root_grant)
	case .Disk_Grant:
		return disk_grant_removable(snap, target.disk_index, target.disk_grant)
	}
	return false
}

// targets_equal compares two Action_Target values strictly by kind and active
// fields.
targets_equal :: proc "contextless" (a, b: Action_Target) -> bool {
	if a.kind != b.kind {
		return false
	}
	switch a.kind {
	case .None, .Wide_Grant:
		return true
	case .Process_Grant:
		return a.process_index == b.process_index && a.root_grant == b.root_grant
	case .Disk_Grant:
		return a.disk_index == b.disk_index && a.disk_grant == b.disk_grant
	}
	return false
}

// confirm_arm arms inline confirmation for target if target is currently
// revocable in snap. Refuses unrevocable or out-of-range targets without
// changing state.
confirm_arm :: proc "contextless" (state: ^Confirm_State, snap: ^Snapshot, target: Action_Target) -> bool {
	if state == nil || !target_valid(snap, target) {
		return false
	}
	state.armed = true
	state.target = target
	return true
}

confirm_cancel :: proc "contextless" (state: ^Confirm_State) {
	if state == nil {
		return
	}
	state^ = {}
}

confirm_matches :: proc "contextless" (state: ^Confirm_State, target: Action_Target) -> bool {
	return state != nil && state.armed && targets_equal(state.target, target)
}

// confirm_reconcile clears a pending confirmation when a refreshed snapshot no
// longer contains the armed target.
confirm_reconcile :: proc "contextless" (state: ^Confirm_State, snap: ^Snapshot) {
	if state == nil || !state.armed {
		return
	}
	if !target_valid(snap, state.target) {
		state^ = {}
	}
}

@(private = "file")
display_list_append :: proc "contextless" (list: ^Display_List, row: Display_Row) {
	if list.count < len(list.rows) {
		list.rows[list.count] = row
		list.count += 1
	}
}

// display_list_build constructs the flat ordered list of rows from snap once
// per refresh so frame rendering touches only visible rows.
display_list_build :: proc "contextless" (list: ^Display_List, snap: ^Snapshot) {
	if list == nil {
		return
	}
	list.count = 0
	if snap == nil {
		return
	}

	// Section 1: Wide grant.
	display_list_append(list, {kind = .Section_Heading, section = .Wide_Grant})
	if snap.wide_grant.active {
		display_list_append(list, {kind = .Wide_Grant_Item, section = .Wide_Grant, removable = true})
	} else {
		display_list_append(list, {kind = .Empty_Notice, section = .Wide_Grant})
	}

	// Section 2: Running process grants.
	display_list_append(list, {kind = .Section_Heading, section = .Process})
	if snap.process_count == 0 {
		display_list_append(list, {kind = .Empty_Notice, section = .Process})
	} else {
		for p in 0 ..< snap.process_count {
			row := &snap.processes[p]
			display_list_append(list, {kind = .Process_Heading, section = .Process, process_index = p})
			for grant in system.Root_Grant {
				if grant in row.granted {
					display_list_append(list, {
						kind          = .Process_Grant,
						section       = .Process,
						process_index = p,
						root_grant    = grant,
						grant_revoked = false,
						removable     = true,
					})
				}
			}
			for grant in system.Root_Grant {
				if grant in row.revoked && grant not_in row.granted {
					display_list_append(list, {
						kind          = .Process_Grant,
						section       = .Process,
						process_index = p,
						root_grant    = grant,
						grant_revoked = true,
						removable     = false,
					})
				}
			}
		}
		if snap.processes_truncated > 0 {
			display_list_append(list, {kind = .Truncation_Notice, section = .Process})
		}
	}

	// Section 3: Remembered disk grants.
	display_list_append(list, {kind = .Section_Heading, section = .Disk_Grant})
	if snap.disk_count == 0 {
		display_list_append(list, {kind = .Empty_Notice, section = .Disk_Grant})
	} else {
		for d in 0 ..< snap.disk_count {
			row := &snap.disks[d]
			emitted := false
			for grant in disk_process.Disk_Grant {
				if grant in row.grants {
					display_list_append(list, {
						kind       = .Disk_Grant_Item,
						section    = .Disk_Grant,
						disk_index = d,
						disk_grant = grant,
						removable  = grant == .Store,
					})
					emitted = true
				}
			}
			if !emitted {
				display_list_append(list, {
					kind       = .Disk_Grant_Item,
					section    = .Disk_Grant,
					disk_index = d,
					disk_grant = .Store,
					removable  = false,
				})
			}
		}
		if snap.disks_truncated > 0 {
			display_list_append(list, {kind = .Truncation_Notice, section = .Disk_Grant})
		}
	}
}

// format_hex_prefix formats an 8-byte little-endian word as 16 lowercase
// hexadecimal digits matching the console and monitor hash prefix convention.
format_hex_prefix :: proc "contextless" (out: ^[16]u8, word: u64) -> string {
	bytes := transmute([8]u8)word
	digits := "0123456789abcdef"
	for b, i in bytes {
		out[2 * i] = digits[b >> 4]
		out[2 * i + 1] = digits[b & 15]
	}
	return string(out[:])
}

// format_wide_scopes writes the active scopes of a wide grant in plain words.
format_wide_scopes :: proc "contextless" (out: ^[32]u8, scopes: wide_grants.Wide_Authorities) -> string {
	w := system.Writer{buffer = out[:]}
	if .View_Screen in scopes {
		system.write_part(&w, "view screen")
	}
	if .Send_Input in scopes {
		if w.count > 0 {
			system.write_part(&w, ", ")
		}
		system.write_part(&w, "send input")
	}
	if w.count == 0 {
		system.write_part(&w, "none")
	}
	return system.written(&w)
}

// format_remaining_time formats remaining wide-grant time without underflow.
format_remaining_time :: proc "contextless" (out: ^[24]u8, now_ms, ends_at_ms: u64) -> string {
	if ends_at_ms <= now_ms {
		return "ending"
	}
	remaining_ms := ends_at_ms - now_ms
	w := system.Writer{buffer = out[:]}
	if remaining_ms >= 60_000 {
		minutes := (remaining_ms + 59_999) / 60_000
		system.write_part(&w, minutes)
		system.write_part(&w, " min left")
	} else {
		seconds := (remaining_ms + 999) / 1000
		system.write_part(&w, seconds)
		system.write_part(&w, " s left")
	}
	return system.written(&w)
}

// disk_persistence_label returns a concise human-readable durability label
// for a disk grant row.
disk_persistence_label :: proc "contextless" (row: ^Disk_Row) -> string {
	if row == nil {
		return ""
	}
	if row.lasting == .Until_Stop {
		return "until stop"
	}
	switch row.persistence {
	case .Persist:
		return "kept on disk"
	case .Forget:
		return "forgotten at stop"
	case .Global:
		return row.forget_by_default ? "forgotten at stop" : "kept on disk"
	}
	return "until stop"
}
