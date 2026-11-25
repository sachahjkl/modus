// Multi-worker SharedArrayBuffer SMP coordination and Checked boot-image file
// wait gate (src/md/features/browser_machine.md).
//
// Two freestanding zero-allocation contracts:
//   1. Browser_Smp_Table: tracks 1..MAX_BROWSER_CPUS worker CPU slots,
//      per-CPU IPI wake masks and wait words, one-time shared passive
//      data-segment initialization, and generation-counted TLB shootdowns with
//      explicit target/ack bitmasks.
//   2. Checked_Image_File_Gate: tracks per-boot-image-file BLAKE3 verification
//      state (Unchecked, Hashing, Verified, Refused) so Image-grant holders
//      (console, log, manual) wait until a file is verified and fail closed
//      permanently on any hash or size mismatch.
package browser_vm_runtime

import "modus:contract/blake3"
import "modus:contract/enum_word"

// Plan value: browser engines cap workers at 4 on desktop Chromium and 2 on
// Firefox; 8 slots leave headroom for higher-core desktops while keeping the
// SharedArrayBuffer SMP table compact inside one 4 KiB page.
MAX_BROWSER_CPUS :: u8(8)

// Plan value: a full release boot image holds system services, libraries,
// applications, fonts, manual pages, and start lists (~60 entries today);
// 128 slots give fixed freestanding headroom without dynamic allocation.
CHECKED_IMAGE_MAX_FILES :: u16(128)

// Plan value: at most 8 Image-grant holders (console, log, manual, root, etc.)
// wait concurrently on the same boot-image file during first-use hashing.
CHECKED_IMAGE_MAX_WAITERS_PER_FILE :: 8

// ============================================================================
// Multi-Worker SMP Coordination Table (SharedArrayBuffer)
// ============================================================================

// Explicit lifecycle state of one browser worker processor slot.
Browser_Cpu_State :: enum u32 {
	Offline      = 0,
	Starting     = 1,
	Online       = 2,
	Idle_Waiting = 3,
	Halted       = 4,
}

browser_cpu_state_of_word :: proc "contextless" (word: u64) -> (state: Browser_Cpu_State, ok: bool) {
	return enum_word.member_of_word(Browser_Cpu_State, word)
}

// Closed set of inter-processor interrupt kinds between browser workers.
Browser_Ipi_Kind :: enum u8 {
	Reschedule       = 0,
	Tlb_Shootdown    = 1,
	Stop_Processor   = 2,
	Device_Interrupt = 3,
}

browser_ipi_kind_of_word :: proc "contextless" (word: u64) -> (kind: Browser_Ipi_Kind, ok: bool) {
	return enum_word.member_of_word(Browser_Ipi_Kind, word)
}

Browser_Ipi_Mask :: bit_set[Browser_Ipi_Kind; u32]

BROWSER_IPI_VALID_BITS :: u32(0x0F)

// browser_ipi_mask_of_word converts a transport word into a Browser_Ipi_Mask,
// refusing any word that sets an undefined bit.
browser_ipi_mask_of_word :: proc "contextless" (word: u64) -> (mask: Browser_Ipi_Mask, ok: bool) {
	if (word & ~u64(BROWSER_IPI_VALID_BITS)) != 0 {
		return {}, false
	}
	return transmute(Browser_Ipi_Mask)u32(word), true
}

// Closed set of refusals returned by Browser_Smp_Table operations.
Browser_Smp_Refusal :: enum u8 {
	None                          = 0,
	Nil_Table                     = 1,
	Invalid_Cpu_Count             = 2,
	Cpu_Out_Of_Range              = 3,
	Invalid_Cpu_Transition        = 4,
	Cpu_Not_Ready                 = 5,
	Empty_Ipi_Mask                = 6,
	Unknown_Ipi_Bit               = 7,
	Shootdown_Already_Active      = 8,
	No_Active_Shootdown           = 9,
	Generation_Mismatch           = 10,
	Already_Acknowledged          = 11,
	Shootdown_Generation_Overflow = 12,
}

browser_smp_refusal_of_word :: proc "contextless" (word: u64) -> (refusal: Browser_Smp_Refusal, ok: bool) {
	return enum_word.member_of_word(Browser_Smp_Refusal, word)
}

// Per-CPU coordination slot in shared memory.
Browser_Cpu_Slot :: struct {
	state:               Browser_Cpu_State,
	ipi_pending:         Browser_Ipi_Mask,
	wake_word:           u32, // Monotonic wait/notify word for memory.atomic.wait32.
	last_tlb_generation: u64,
	ipi_received_count:  u64,
}

// Active or last completed cross-worker TLB shootdown state.
Browser_Tlb_Shootdown :: struct {
	active:                 bool,
	generation:             u64,
	initiator_cpu:          u8,
	target_mask:            u32,
	ack_mask:               u32,
	target_cr3:             u64,
	target_virtual_address: u64,
}

// SharedArrayBuffer worker CPU coordination table.
Browser_Smp_Table :: struct {
	cpu_count:                 u8,
	data_segments_initialized: bool,
	slots:                     [MAX_BROWSER_CPUS]Browser_Cpu_Slot,
	shootdown:                 Browser_Tlb_Shootdown,
}

// browser_smp_init configures `table` for `cpu_count` worker CPUs (1..MAX_BROWSER_CPUS).
// CPU 0 begins `.Online` as the boot worker; CPUs 1..<cpu_count begin `.Offline`.
// Refuses invalid counts without mutating `table`.
browser_smp_init :: proc "contextless" (table: ^Browser_Smp_Table, cpu_count: u8) -> Browser_Smp_Refusal {
	if table == nil {
		return .Nil_Table
	}
	if cpu_count == 0 || cpu_count > MAX_BROWSER_CPUS {
		return .Invalid_Cpu_Count
	}
	table^ = {}
	table.cpu_count = cpu_count
	table.slots[0].state = .Online
	return .None
}

// browser_smp_claim_data_segment_init enforces one-time passive data-segment
// initialization on a shared WebAssembly memory. Only the first worker sees
// `should_initialize == true`.
browser_smp_claim_data_segment_init :: proc "contextless" (table: ^Browser_Smp_Table) -> (should_initialize: bool, refusal: Browser_Smp_Refusal) {
	if table == nil {
		return false, .Nil_Table
	}
	if table.cpu_count == 0 || table.cpu_count > MAX_BROWSER_CPUS {
		return false, .Invalid_Cpu_Count
	}
	if table.data_segments_initialized {
		return false, .None
	}
	table.data_segments_initialized = true
	return true, .None
}

@(private = "file")
cpu_transition_allowed :: proc "contextless" (from, to: Browser_Cpu_State) -> bool {
	switch from {
	case .Offline:
		return to == .Starting
	case .Starting:
		return to == .Online || to == .Halted
	case .Online:
		return to == .Idle_Waiting || to == .Halted
	case .Idle_Waiting:
		return to == .Online || to == .Halted
	case .Halted:
		return false
	}
	return false
}

// browser_smp_transition_cpu moves `cpu_id` to `next_state` if the transition
// is valid. Refuses out-of-range CPUs, unknown enum values, and illegal edges
// without mutating `table`.
browser_smp_transition_cpu :: proc "contextless" (
	table: ^Browser_Smp_Table,
	cpu_id: u8,
	next_state: Browser_Cpu_State,
) -> Browser_Smp_Refusal {
	if table == nil {
		return .Nil_Table
	}
	if cpu_id >= table.cpu_count || table.cpu_count > MAX_BROWSER_CPUS {
		return .Cpu_Out_Of_Range
	}
	validated_next, ok := enum_word.member_of_argument(next_state)
	if !ok {
		return .Invalid_Cpu_Transition
	}
	slot := &table.slots[cpu_id]
	if !cpu_transition_allowed(slot.state, validated_next) {
		return .Invalid_Cpu_Transition
	}
	slot.state = validated_next
	if validated_next == .Halted {
		// A halted worker will never run again or ack a pending shootdown, so
		// satisfy its target bit now to prevent permanent shootdown deadlock.
		bit := u32(1) << cpu_id
		slot.ipi_pending -= {.Tlb_Shootdown}
		if table.shootdown.active && (table.shootdown.target_mask & bit) != 0 {
			table.shootdown.ack_mask |= bit
			slot.last_tlb_generation = table.shootdown.generation
			if table.shootdown.ack_mask == table.shootdown.target_mask {
				table.shootdown.active = false
			}
		}
	}
	return .None
}

// browser_smp_send_ipi posts `mask` to `target_cpu` from an `.Online` sender
// and bumps the target's wake word for `memory.atomic.notify`.
browser_smp_send_ipi :: proc "contextless" (
	table: ^Browser_Smp_Table,
	from_cpu: u8,
	target_cpu: u8,
	mask: Browser_Ipi_Mask,
) -> Browser_Smp_Refusal {
	if table == nil {
		return .Nil_Table
	}
	if table.cpu_count == 0 || table.cpu_count > MAX_BROWSER_CPUS {
		return .Invalid_Cpu_Count
	}
	if from_cpu >= table.cpu_count || target_cpu >= table.cpu_count {
		return .Cpu_Out_Of_Range
	}
	raw_bits := transmute(u32)mask
	if (raw_bits & ~BROWSER_IPI_VALID_BITS) != 0 {
		return .Unknown_Ipi_Bit
	}
	if raw_bits == 0 {
		return .Empty_Ipi_Mask
	}
	if table.slots[from_cpu].state != .Online {
		return .Cpu_Not_Ready
	}
	target_state := table.slots[target_cpu].state
	if target_state != .Online && target_state != .Idle_Waiting {
		return .Cpu_Not_Ready
	}
	target := &table.slots[target_cpu]
	target.ipi_pending |= mask
	target.wake_word += 1
	target.ipi_received_count += 1
	return .None
}

// browser_smp_take_ipis atomically claims all pending IPIs for `cpu_id`.
// If `cpu_id` was `.Idle_Waiting` and had pending IPIs, it transitions to `.Online`.
browser_smp_take_ipis :: proc "contextless" (
	table: ^Browser_Smp_Table,
	cpu_id: u8,
) -> (pending: Browser_Ipi_Mask, refusal: Browser_Smp_Refusal) {
	if table == nil {
		return {}, .Nil_Table
	}
	if table.cpu_count == 0 || table.cpu_count > MAX_BROWSER_CPUS {
		return {}, .Invalid_Cpu_Count
	}
	if cpu_id >= table.cpu_count {
		return {}, .Cpu_Out_Of_Range
	}
	slot := &table.slots[cpu_id]
	if slot.state != .Online && slot.state != .Idle_Waiting {
		return {}, .Cpu_Not_Ready
	}
	pending = slot.ipi_pending
	slot.ipi_pending = {}
	if slot.state == .Idle_Waiting && pending != {} {
		slot.state = .Online
	}
	return pending, .None
}

// browser_smp_begin_tlb_shootdown advances the monotonic TLB shootdown
// generation and sends `.Tlb_Shootdown` IPIs to every other active CPU
// (`.Online` or `.Idle_Waiting`). When no peer CPU is active, the shootdown
// completes immediately with `shootdown.active == false`.
browser_smp_begin_tlb_shootdown :: proc "contextless" (
	table: ^Browser_Smp_Table,
	initiator_cpu: u8,
	target_cr3: u64,
	target_virtual_address: u64,
) -> (generation: u64, refusal: Browser_Smp_Refusal) {
	if table == nil {
		return 0, .Nil_Table
	}
	if table.cpu_count == 0 || table.cpu_count > MAX_BROWSER_CPUS {
		return 0, .Invalid_Cpu_Count
	}
	if initiator_cpu >= table.cpu_count {
		return 0, .Cpu_Out_Of_Range
	}
	if table.slots[initiator_cpu].state != .Online {
		return 0, .Cpu_Not_Ready
	}
	if table.shootdown.active {
		return 0, .Shootdown_Already_Active
	}
	if table.shootdown.generation == max(u64) {
		return 0, .Shootdown_Generation_Overflow
	}

	target_mask := u32(0)
	for i in u8(0) ..< table.cpu_count {
		if i == initiator_cpu {
			continue
		}
		st := table.slots[i].state
		if st == .Online || st == .Idle_Waiting {
			target_mask |= u32(1) << i
		}
	}

	next_gen := table.shootdown.generation + 1
	table.shootdown.generation = next_gen
	table.shootdown.initiator_cpu = initiator_cpu
	table.shootdown.target_mask = target_mask
	table.shootdown.ack_mask = 0
	table.shootdown.target_cr3 = target_cr3
	table.shootdown.target_virtual_address = target_virtual_address
	table.slots[initiator_cpu].last_tlb_generation = next_gen

	if target_mask == 0 {
		table.shootdown.active = false
		return next_gen, .None
	}

	table.shootdown.active = true
	for i in u8(0) ..< table.cpu_count {
		if (target_mask & (u32(1) << i)) != 0 {
			table.slots[i].ipi_pending |= {.Tlb_Shootdown}
			table.slots[i].wake_word += 1
			table.slots[i].ipi_received_count += 1
		}
	}
	return next_gen, .None
}

// browser_smp_ack_tlb_shootdown records that `cpu_id` flushed its local TLB
// for `generation`. Returns `all_acked = true` once every targeted CPU has acked.
browser_smp_ack_tlb_shootdown :: proc "contextless" (
	table: ^Browser_Smp_Table,
	cpu_id: u8,
	generation: u64,
) -> (all_acked: bool, refusal: Browser_Smp_Refusal) {
	if table == nil {
		return false, .Nil_Table
	}
	if table.cpu_count == 0 || table.cpu_count > MAX_BROWSER_CPUS {
		return false, .Invalid_Cpu_Count
	}
	if cpu_id >= table.cpu_count {
		return false, .Cpu_Out_Of_Range
	}
	if !table.shootdown.active {
		return false, .No_Active_Shootdown
	}
	if generation != table.shootdown.generation {
		return false, .Generation_Mismatch
	}
	st := table.slots[cpu_id].state
	if st != .Online && st != .Idle_Waiting {
		return false, .Cpu_Not_Ready
	}
	bit := u32(1) << cpu_id
	if (table.shootdown.target_mask & bit) == 0 || (table.shootdown.ack_mask & bit) != 0 {
		return false, .Already_Acknowledged
	}

	table.shootdown.ack_mask |= bit
	table.slots[cpu_id].last_tlb_generation = generation
	table.slots[cpu_id].ipi_pending -= {.Tlb_Shootdown}
	if table.shootdown.ack_mask == table.shootdown.target_mask {
		table.shootdown.active = false
		return true, .None
	}
	return false, .None
}

// browser_smp_shootdown_complete reports whether no cross-CPU shootdown is pending.
browser_smp_shootdown_complete :: proc "contextless" (table: ^Browser_Smp_Table) -> bool {
	if table == nil {
		return false
	}
	return !table.shootdown.active
}

// ============================================================================
// Checked Boot-Image File Wait Gate
// ============================================================================

// Per-boot-image-file verification state for first-use BLAKE3 checks.
Image_File_Verify_State :: enum u8 {
	Unchecked = 0,
	Hashing   = 1,
	Verified  = 2,
	Refused   = 3,
}

image_file_verify_state_of_word :: proc "contextless" (word: u64) -> (state: Image_File_Verify_State, ok: bool) {
	return enum_word.member_of_word(Image_File_Verify_State, word)
}

// Decision returned to an Image-grant holder requesting to read a boot-image file.
Image_Read_Decision :: enum u8 {
	Allow       = 1, // File hash verified: caller can read tables/bytes now.
	Wait        = 2, // Verification pending: caller must wait until woken.
	Deny_Failed = 3, // File failed verification: fail closed permanently.
}

image_read_decision_of_word :: proc "contextless" (word: u64) -> (decision: Image_Read_Decision, ok: bool) {
	return enum_word.member_of_word(Image_Read_Decision, word)
}

// Closed set of refusals returned by Checked_Image_File_Gate operations.
Image_Gate_Refusal :: enum u8 {
	None                     = 0,
	Nil_Gate                 = 1,
	File_Count_Out_Of_Range  = 2,
	File_Index_Out_Of_Range  = 3,
	Zero_Expected_Hash       = 4,
	Invalid_Expected_Size    = 5,
	Invalid_Holder_Id        = 6,
	Waiter_Queue_Full        = 7,
	Invalid_State_Transition = 8,
	Hash_Mismatch            = 9,
	Output_Too_Small         = 10,
}

image_gate_refusal_of_word :: proc "contextless" (word: u64) -> (refusal: Image_Gate_Refusal, ok: bool) {
	return enum_word.member_of_word(Image_Gate_Refusal, word)
}

// Per-file verification slot inside Checked_Image_File_Gate.
Checked_Image_File_Entry :: struct {
	expected_hash: blake3.Hash,
	expected_size: u64,
	state:         Image_File_Verify_State,
	waiter_count:  u8,
	waiters:       [CHECKED_IMAGE_MAX_WAITERS_PER_FILE]u64,
	hash_attempts: u32,
	denied_reads:  u64,
}

// Gate coordinating first-use BLAKE3 verification of boot-image files against
// concurrent reads by Image-grant holders (`console`, `log`, `manual`).
Checked_Image_File_Gate :: struct {
	file_count: u16,
	entries:    [CHECKED_IMAGE_MAX_FILES]Checked_Image_File_Entry,
}

@(private = "file")
hash_is_all_zero :: proc "contextless" (h: blake3.Hash) -> bool {
	acc := u8(0)
	for b in h {
		acc |= b
	}
	return acc == 0
}

@(private = "file")
hashes_equal_constant_time :: proc "contextless" (a, b: blake3.Hash) -> bool {
	diff := u8(0)
	for i in 0 ..< blake3.HASH_SIZE {
		diff |= a[i] ~ b[i]
	}
	return diff == 0
}

// checked_image_gate_init populates `gate` from the signed system description's
// expected BLAKE3 hashes and byte lengths. Refuses zero hashes, zero sizes,
// mismatched slices, or out-of-range counts without mutating `gate`.
checked_image_gate_init :: proc "contextless" (
	gate: ^Checked_Image_File_Gate,
	expected_hashes: []blake3.Hash,
	expected_sizes: []u64,
) -> Image_Gate_Refusal {
	if gate == nil {
		return .Nil_Gate
	}
	if len(expected_hashes) == 0 || len(expected_hashes) > int(CHECKED_IMAGE_MAX_FILES) {
		return .File_Count_Out_Of_Range
	}
	if len(expected_sizes) != len(expected_hashes) {
		return .File_Count_Out_Of_Range
	}
	for i in 0 ..< len(expected_hashes) {
		if hash_is_all_zero(expected_hashes[i]) {
			return .Zero_Expected_Hash
		}
		if expected_sizes[i] == 0 {
			return .Invalid_Expected_Size
		}
	}

	gate^ = {}
	gate.file_count = u16(len(expected_hashes))
	for i in 0 ..< len(expected_hashes) {
		gate.entries[i] = Checked_Image_File_Entry{
			expected_hash = expected_hashes[i],
			expected_size = expected_sizes[i],
			state         = .Unchecked,
		}
	}
	return .None
}

// checked_image_gate_request_read checks whether `holder_id` can read
// `file_index`. Verified files return `.Allow`; failed files return
// `.Deny_Failed`; unchecked or hashing files enqueue `holder_id` once and
// return `.Wait`. `need_hash_start` is true when the file is still `.Unchecked`.
checked_image_gate_request_read :: proc "contextless" (
	gate: ^Checked_Image_File_Gate,
	file_index: u16,
	holder_id: u64,
) -> (decision: Image_Read_Decision, need_hash_start: bool, refusal: Image_Gate_Refusal) {
	if gate == nil {
		return .Deny_Failed, false, .Nil_Gate
	}
	if file_index >= gate.file_count || gate.file_count > CHECKED_IMAGE_MAX_FILES {
		return .Deny_Failed, false, .File_Index_Out_Of_Range
	}
	if holder_id == 0 {
		return .Deny_Failed, false, .Invalid_Holder_Id
	}
	entry := &gate.entries[file_index]
	switch entry.state {
	case .Verified:
		return .Allow, false, .None
	case .Refused:
		entry.denied_reads += 1
		return .Deny_Failed, false, .None
	case .Unchecked, .Hashing:
		for i in 0 ..< int(entry.waiter_count) {
			if entry.waiters[i] == holder_id {
				return .Wait, entry.state == .Unchecked, .None
			}
		}
		if int(entry.waiter_count) >= CHECKED_IMAGE_MAX_WAITERS_PER_FILE {
			return .Deny_Failed, false, .Waiter_Queue_Full
		}
		entry.waiters[entry.waiter_count] = holder_id
		entry.waiter_count += 1
		return .Wait, entry.state == .Unchecked, .None
	}
	return .Deny_Failed, false, .Invalid_State_Transition
}

// checked_image_gate_begin_hashing transitions an `.Unchecked` file to
// `.Hashing`. Refuses `.Hashing`, `.Verified`, or `.Refused` without mutation.
checked_image_gate_begin_hashing :: proc "contextless" (
	gate: ^Checked_Image_File_Gate,
	file_index: u16,
) -> Image_Gate_Refusal {
	if gate == nil {
		return .Nil_Gate
	}
	if file_index >= gate.file_count || gate.file_count > CHECKED_IMAGE_MAX_FILES {
		return .File_Index_Out_Of_Range
	}
	entry := &gate.entries[file_index]
	if entry.state != .Unchecked {
		return .Invalid_State_Transition
	}
	entry.state = .Hashing
	entry.hash_attempts += 1
	return .None
}

// checked_image_gate_finish_hashing computes the BLAKE3 hash of `file_bytes`
// and compares both byte length and hash in constant time against the signed
// description. On match, transitions to `.Verified`; on mismatch, transitions
// permanently to `.Refused` and returns `.Hash_Mismatch`. In both cases, drains
// all waiting holder IDs into `woken_holders_out`. Refuses `.Output_Too_Small`
// without mutating `gate`.
checked_image_gate_finish_hashing :: proc "contextless" (
	gate: ^Checked_Image_File_Gate,
	file_index: u16,
	file_bytes: []u8,
	woken_holders_out: []u64,
) -> (woken_count: int, verified: bool, refusal: Image_Gate_Refusal) {
	if gate == nil {
		return 0, false, .Nil_Gate
	}
	if file_index >= gate.file_count || gate.file_count > CHECKED_IMAGE_MAX_FILES {
		return 0, false, .File_Index_Out_Of_Range
	}
	entry := &gate.entries[file_index]
	if entry.state != .Hashing {
		return 0, false, .Invalid_State_Transition
	}
	count := int(entry.waiter_count)
	if len(woken_holders_out) < count {
		return 0, false, .Output_Too_Small
	}

	actual_hash := blake3.hash(file_bytes)
	matches := u64(len(file_bytes)) == entry.expected_size &&
		hashes_equal_constant_time(actual_hash, entry.expected_hash)

	for i in 0 ..< count {
		woken_holders_out[i] = entry.waiters[i]
		entry.waiters[i] = 0
	}
	entry.waiter_count = 0

	if matches {
		entry.state = .Verified
		return count, true, .None
	}
	entry.state = .Refused
	return count, false, .Hash_Mismatch
}

// checked_image_gate_refuse_file fails closed on an `.Unchecked` or `.Hashing`
// file (for example when its image range is missing) and wakes all waiters.
checked_image_gate_refuse_file :: proc "contextless" (
	gate: ^Checked_Image_File_Gate,
	file_index: u16,
	woken_holders_out: []u64,
) -> (woken_count: int, refusal: Image_Gate_Refusal) {
	if gate == nil {
		return 0, .Nil_Gate
	}
	if file_index >= gate.file_count || gate.file_count > CHECKED_IMAGE_MAX_FILES {
		return 0, .File_Index_Out_Of_Range
	}
	entry := &gate.entries[file_index]
	if entry.state != .Unchecked && entry.state != .Hashing {
		return 0, .Invalid_State_Transition
	}
	count := int(entry.waiter_count)
	if len(woken_holders_out) < count {
		return 0, .Output_Too_Small
	}
	for i in 0 ..< count {
		woken_holders_out[i] = entry.waiters[i]
		entry.waiters[i] = 0
	}
	entry.waiter_count = 0
	entry.state = .Refused
	return count, .None
}

// checked_image_gate_state reads the verification state of one boot-image file.
checked_image_gate_state :: proc "contextless" (
	gate: ^Checked_Image_File_Gate,
	file_index: u16,
) -> (state: Image_File_Verify_State, ok: bool) {
	if gate == nil || file_index >= gate.file_count || gate.file_count > CHECKED_IMAGE_MAX_FILES {
		return .Refused, false
	}
	return gate.entries[file_index].state, true
}

// checked_image_gate_all_verified reports whether every boot-image file in
// `gate` has passed BLAKE3 verification.
checked_image_gate_all_verified :: proc "contextless" (gate: ^Checked_Image_File_Gate) -> bool {
	if gate == nil || gate.file_count == 0 || gate.file_count > CHECKED_IMAGE_MAX_FILES {
		return false
	}
	for i in u16(0) ..< gate.file_count {
		if gate.entries[i].state != .Verified {
			return false
		}
	}
	return true
}
