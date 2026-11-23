// Pure instruction decoding, CPUID feature filtering, control-register bit
// helpers, and replay operation classification for record and replay
// (src/md/features/record_and_replay.md).
//
// This package is a pure kernel part: it keeps no mutable state and reads no
// hardware register, so every rule runs under host tests.
package replay_filter

import op "modus:contract/operation"

// Model-specific registers and control bits for trapping rdtsc, rdtscp and cpuid.
MSR_PLATFORM_INFO :: u32(0xCE)
PLATFORM_INFO_CPUID_FAULTING_BIT :: u64(1) << 31

MSR_MISC_FEATURES_ENABLES :: u32(0x140)
MISC_FEATURES_CPUID_FAULTING_ENABLE :: u64(1) << 0

MSR_TSC_AUX :: u32(0xC000_0103)
// Fixed processor auxiliary value exposed to recorded and replayed threads.
RECORDED_PROCESSOR_AUXILIARY :: u32(0)

// CR4.TSD: makes rdtsc and rdtscp fault with #GP in user mode.
CR4_TIME_STAMP_DISABLE :: u64(1) << 2

// CPUID feature bits cleared while recording or replaying so code that queries
// CPUID avoids unrecordable instructions (rdrand, rdseed, rdpid, HLE/RTM
// transactions, waitpkg).
CPUID_LEAF_1_ECX_RDRAND :: u32(1) << 30
CPUID_LEAF_7_EBX_HLE :: u32(1) << 4
CPUID_LEAF_7_EBX_RTM :: u32(1) << 11
CPUID_LEAF_7_EBX_RDSEED :: u32(1) << 18
CPUID_LEAF_7_ECX_WAITPKG :: u32(1) << 5
CPUID_LEAF_7_ECX_RDPID :: u32(1) << 22
CPUID_LEAF_7_EDX_RTM_ALWAYS_ABORT :: u32(1) << 11
CPUID_LEAF_7_EDX_TSX_FORCE_ABORT :: u32(1) << 13

CPUID_LEAF_1_ECX_MASK_CLEAR :: CPUID_LEAF_1_ECX_RDRAND
CPUID_LEAF_7_EBX_MASK_CLEAR :: CPUID_LEAF_7_EBX_HLE | CPUID_LEAF_7_EBX_RTM | CPUID_LEAF_7_EBX_RDSEED
CPUID_LEAF_7_ECX_MASK_CLEAR :: CPUID_LEAF_7_ECX_WAITPKG | CPUID_LEAF_7_ECX_RDPID
CPUID_LEAF_7_EDX_MASK_CLEAR :: CPUID_LEAF_7_EDX_RTM_ALWAYS_ABORT | CPUID_LEAF_7_EDX_TSX_FORCE_ABORT

// Which trapped x86-64 instruction starts at the faulting instruction pointer.
Trapped_Instruction :: enum u8 {
	None   = 0,
	Rdtsc  = 1, // 0F 31 (2 bytes).
	Rdtscp = 2, // 0F 01 F9 (3 bytes).
	Cpuid  = 3, // 0F A2 (2 bytes).
}

// Decoded instruction kind and exact byte length to advance RIP past it.
Decoded_Instruction :: struct {
	kind:   Trapped_Instruction,
	length: u8,
}

// The four 32-bit registers returned by CPUID.
Cpuid_Registers :: struct {
	eax: u32,
	ebx: u32,
	ecx: u32,
	edx: u32,
}

// Whether a kernel operation runs locally on the replayed process's address
// space/threads, is answered purely from the recorded input history, or is
// refused in single-thread record/replay mode.
Replay_Operation_Policy :: enum u8 {
	Synthetic  = 0, // Never run for real in replay mode; answer strictly from history.
	Real_Local = 1, // Run locally on the replayed process when operating on itself.
	Refused    = 2, // Refused in single-thread record/replay mode (Thread_Create, Guest_Run).
}

// decode_trapped_instruction checks the bytes at RIP for rdtsc (0F 31),
// rdtscp (0F 01 F9), or cpuid (0F A2). Any other sequence or short slice gives
// None with length 0.
decode_trapped_instruction :: proc "contextless" (bytes: []u8) -> Decoded_Instruction {
	if len(bytes) < 2 || bytes[0] != 0x0F {
		return {}
	}
	switch bytes[1] {
	case 0x31:
		return {kind = .Rdtsc, length = 2}
	case 0xA2:
		return {kind = .Cpuid, length = 2}
	case 0x01:
		if len(bytes) >= 3 && bytes[2] == 0xF9 {
			return {kind = .Rdtscp, length = 3}
		}
	}
	return {}
}

// filter_cpuid_result masks out unrecordable hardware features from a raw
// CPUID response for the given leaf and subleaf.
filter_cpuid_result :: proc "contextless" (leaf: u32, subleaf: u32, raw: Cpuid_Registers) -> Cpuid_Registers {
	filtered := raw
	switch leaf {
	case 1:
		filtered.ecx &~= CPUID_LEAF_1_ECX_MASK_CLEAR
	case 7:
		if subleaf == 0 {
			filtered.ebx &~= CPUID_LEAF_7_EBX_MASK_CLEAR
			filtered.ecx &~= CPUID_LEAF_7_ECX_MASK_CLEAR
			filtered.edx &~= CPUID_LEAF_7_EDX_MASK_CLEAR
		}
	}
	return filtered
}

// platform_info_supports_cpuid_faulting reports whether MSR_PLATFORM_INFO
// advertises CPUID faulting (bit 31).
platform_info_supports_cpuid_faulting :: proc "contextless" (platform_info: u64) -> bool {
	return platform_info & PLATFORM_INFO_CPUID_FAULTING_BIT != 0
}

// misc_features_with_cpuid_faulting returns MSR_MISC_FEATURES_ENABLES with bit
// 0 set or cleared while preserving all other bits.
misc_features_with_cpuid_faulting :: proc "contextless" (current: u64, enable: bool) -> u64 {
	if enable {
		return current | MISC_FEATURES_CPUID_FAULTING_ENABLE
	}
	return current &~ MISC_FEATURES_CPUID_FAULTING_ENABLE
}

// cr4_with_timestamp_disable returns CR4 with CR4.TSD set or cleared while
// preserving all other bits.
cr4_with_timestamp_disable :: proc "contextless" (current: u64, enable: bool) -> u64 {
	if enable {
		return current | CR4_TIME_STAMP_DISABLE
	}
	return current &~ CR4_TIME_STAMP_DISABLE
}

// replay_operation_policy decides whether a kernel operation builds local
// address-space/thread state in replay mode, is answered synthetically from
// the input history without executing side effects, or is refused in
// single-thread record/replay mode.
replay_operation_policy :: proc "contextless" (operation: op.Operation) -> Replay_Operation_Policy {
	switch operation {
	case .Memory_Create, .Memory_Map, .Memory_Unmap, .Memory_Commit, .Memory_Protect, .Handle_Close, .Thread_Stop, .Process_Stop:
		return .Real_Local
	case .Thread_Create, .Guest_Run:
		return .Refused
	case .None, .Log, .Memory_Size, .Process_Create, .Process_Start, .Process_State, .Handle_Give, .Interrupt_Read, .Device_Create, .Inspect, .Machine_Stop, .Thread_State, .Word_Wait, .Word_Wake, .Budget_Create, .Budget_Read, .Handle_State, .Handle_Revoke, .Memory_Physical, .Process_Module, .Strategy_Set, .Fault_Handler_Set, .Fault_Answer, .Events_Set, .Thread_Control, .Log_Read, .Memory_Read:
		return .Synthetic
	}
	return .Synthetic
}

// Capacity of the replay handle translation table: matches the handle table
// size of a process.
REPLAY_HANDLE_MAP_CAPACITY :: op.HANDLE_TABLE_CAPACITY

// One recorded-to-real handle translation entry for objects created locally
// during replay (such as Memory_Create).
Replay_Handle_Entry :: struct {
	recorded: u64, // Handle value returned during recording (0 means free slot).
	real:     u64, // Actual handle allocated in the replay process.
}

// Fixed-capacity flat map from recorded handles to real replay handles so
// Memory_Map, Memory_Commit, and Handle_Close never leak slots or suffer
// handle generation drift.
Replay_Handle_Map :: struct {
	entries: [REPLAY_HANDLE_MAP_CAPACITY]Replay_Handle_Entry,
}

// replay_handle_map_insert binds a non-zero recorded handle to a non-zero real
// handle. Refuses zero handles, duplicate recorded handles, or a full map.
replay_handle_map_insert :: proc "contextless" (table: ^Replay_Handle_Map, recorded: u64, real: u64) -> bool {
	if table == nil || recorded == 0 || real == 0 {
		return false
	}
	free_slot := -1
	for entry, index in table.entries {
		if entry.recorded == recorded {
			return false
		}
		if entry.recorded == 0 && free_slot < 0 {
			free_slot = index
		}
	}
	if free_slot < 0 {
		return false
	}
	table.entries[free_slot] = {recorded = recorded, real = real}
	return true
}

// replay_handle_map_lookup returns the real handle bound to recorded, if any.
replay_handle_map_lookup :: proc "contextless" (table: ^Replay_Handle_Map, recorded: u64) -> (real: u64, found: bool) {
	if table == nil || recorded == 0 {
		return 0, false
	}
	for entry in table.entries {
		if entry.recorded == recorded {
			return entry.real, true
		}
	}
	return 0, false
}

// replay_handle_map_remove deletes and returns the real handle bound to
// recorded, freeing the slot for reuse.
replay_handle_map_remove :: proc "contextless" (table: ^Replay_Handle_Map, recorded: u64) -> (real: u64, found: bool) {
	if table == nil || recorded == 0 {
		return 0, false
	}
	for &entry in table.entries {
		if entry.recorded == recorded {
			real = entry.real
			entry = {}
			return real, true
		}
	}
	return 0, false
}
