#+build !freestanding
package replay_filter

import "core:testing"
import op "modus:contract/operation"

// Opcode decoding accepts rdtsc, rdtscp, and cpuid with exact lengths and
// refuses empty slices, truncated sequences, and unrelated opcodes.
@(test)
decode_trapped_instruction_edges :: proc(t: ^testing.T) {
	// Empty, 1-byte, and truncated 2-byte rdtscp prefix are refused.
	testing.expect_value(t, decode_trapped_instruction(nil), Decoded_Instruction{})
	testing.expect_value(t, decode_trapped_instruction({0x0F}), Decoded_Instruction{})
	testing.expect_value(t, decode_trapped_instruction({0x0F, 0x01}), Decoded_Instruction{})
	testing.expect_value(t, decode_trapped_instruction({0x0F, 0x01, 0xF8}), Decoded_Instruction{})
	testing.expect_value(t, decode_trapped_instruction({0x0F, 0x01, 0xFA}), Decoded_Instruction{})
	testing.expect_value(t, decode_trapped_instruction({0x90, 0x0F, 0x31}), Decoded_Instruction{})
	testing.expect_value(t, decode_trapped_instruction({0x0F, 0x05}), Decoded_Instruction{}) // syscall
	testing.expect_value(t, decode_trapped_instruction({0x0F, 0xC7, 0xF0}), Decoded_Instruction{}) // rdrand

	// Exact valid encodings (with trailing bytes ignored).
	testing.expect_value(t, decode_trapped_instruction({0x0F, 0x31}), Decoded_Instruction{.Rdtsc, 2})
	testing.expect_value(t, decode_trapped_instruction({0x0F, 0x31, 0x90}), Decoded_Instruction{.Rdtsc, 2})
	testing.expect_value(t, decode_trapped_instruction({0x0F, 0x01, 0xF9}), Decoded_Instruction{.Rdtscp, 3})
	testing.expect_value(t, decode_trapped_instruction({0x0F, 0x01, 0xF9, 0xCC}), Decoded_Instruction{.Rdtscp, 3})
	testing.expect_value(t, decode_trapped_instruction({0x0F, 0xA2}), Decoded_Instruction{.Cpuid, 2})
	testing.expect_value(t, decode_trapped_instruction({0x0F, 0xA2, 0xC3}), Decoded_Instruction{.Cpuid, 2})
}

// CPUID filter clears rdrand, rdseed, rdpid, HLE/RTM, and waitpkg while
// leaving every other bit and every other leaf/subleaf untouched.
@(test)
filter_cpuid_clears_only_unrecordable_features :: proc(t: ^testing.T) {
	all_ones := Cpuid_Registers{max(u32), max(u32), max(u32), max(u32)}

	// Leaf 1 clears only ECX bit 30 (RDRAND).
	leaf1 := filter_cpuid_result(1, 0, all_ones)
	testing.expect_value(t, leaf1.eax, max(u32))
	testing.expect_value(t, leaf1.ebx, max(u32))
	testing.expect_value(t, leaf1.ecx, max(u32) &~ CPUID_LEAF_1_ECX_RDRAND)
	testing.expect_value(t, leaf1.edx, max(u32))

	// Leaf 7, subleaf 0 clears HLE, RTM, RDSEED (EBX), WAITPKG, RDPID (ECX), RTM/TSX abort bits (EDX).
	leaf7 := filter_cpuid_result(7, 0, all_ones)
	testing.expect_value(t, leaf7.eax, max(u32))
	testing.expect_value(t, leaf7.ebx, max(u32) &~ (CPUID_LEAF_7_EBX_HLE | CPUID_LEAF_7_EBX_RTM | CPUID_LEAF_7_EBX_RDSEED))
	testing.expect_value(t, leaf7.ecx, max(u32) &~ (CPUID_LEAF_7_ECX_WAITPKG | CPUID_LEAF_7_ECX_RDPID))
	testing.expect_value(t, leaf7.edx, max(u32) &~ (CPUID_LEAF_7_EDX_RTM_ALWAYS_ABORT | CPUID_LEAF_7_EDX_TSX_FORCE_ABORT))

	// Leaf 7, subleaf 1 is untouched.
	testing.expect_value(t, filter_cpuid_result(7, 1, all_ones), all_ones)

	// Leaf 0 and extended leaf 0x8000_0001 (including RDTSCP bit 27) are untouched.
	testing.expect_value(t, filter_cpuid_result(0, 0, all_ones), all_ones)
	testing.expect_value(t, filter_cpuid_result(0x8000_0001, 0, all_ones), all_ones)
}

// Control and MSR bit helpers toggle only their exact bits.
@(test)
control_and_msr_bit_helpers :: proc(t: ^testing.T) {
	testing.expect(t, !platform_info_supports_cpuid_faulting(0))
	testing.expect(t, !platform_info_supports_cpuid_faulting(max(u64) &~ PLATFORM_INFO_CPUID_FAULTING_BIT))
	testing.expect(t, platform_info_supports_cpuid_faulting(PLATFORM_INFO_CPUID_FAULTING_BIT))
	testing.expect(t, platform_info_supports_cpuid_faulting(max(u64)))

	testing.expect_value(t, misc_features_with_cpuid_faulting(0xAA00, true), u64(0xAA01))
	testing.expect_value(t, misc_features_with_cpuid_faulting(0xAA01, false), u64(0xAA00))

	testing.expect_value(t, cr4_with_timestamp_disable(0x4_0620, true), u64(0x4_0624))
	testing.expect_value(t, cr4_with_timestamp_disable(0x4_0624, false), u64(0x4_0620))
}

// Every kernel operation has an explicit replay policy; side-effecting handle
// and device operations are Synthetic, and Thread_Create/Guest_Run are Refused.
@(test)
replay_operation_policy_covers_every_operation :: proc(t: ^testing.T) {
	real_count := 0
	refused_count := 0
	synthetic_count := 0
	for operation in op.Operation {
		policy := replay_operation_policy(operation)
		switch operation {
		case .Memory_Create, .Memory_Map, .Memory_Unmap, .Memory_Commit, .Memory_Protect, .Handle_Close, .Thread_Stop, .Process_Stop:
			testing.expect_value(t, policy, Replay_Operation_Policy.Real_Local)
			real_count += 1
		case .Thread_Create, .Guest_Run:
			testing.expect_value(t, policy, Replay_Operation_Policy.Refused)
			refused_count += 1
		case .None, .Log, .Memory_Size, .Process_Create, .Process_Start, .Process_State, .Handle_Give, .Interrupt_Read, .Device_Create, .Inspect, .Machine_Stop, .Thread_State, .Word_Wait, .Word_Wake, .Budget_Create, .Budget_Read, .Handle_State, .Handle_Revoke, .Memory_Physical, .Process_Module, .Strategy_Set, .Fault_Handler_Set, .Fault_Answer, .Events_Set, .Thread_Control, .Log_Read:
			testing.expect_value(t, policy, Replay_Operation_Policy.Synthetic)
			synthetic_count += 1
		}
	}
	testing.expect_value(t, real_count, 8)
	testing.expect_value(t, refused_count, 2)
	testing.expect_value(t, synthetic_count, len(op.Operation) - 10)
}

// Replay handle translation table refuses zero handles, duplicates, and
// overflow, and reuses freed slots cleanly on remove.
@(test)
replay_handle_map_edges :: proc(t: ^testing.T) {
	table: Replay_Handle_Map
	testing.expect(t, !replay_handle_map_insert(&table, 0, 5))
	testing.expect(t, !replay_handle_map_insert(&table, 5, 0))
	_, found := replay_handle_map_lookup(&table, 0)
	testing.expect(t, !found)
	_, found = replay_handle_map_remove(&table, 0)
	testing.expect(t, !found)

	for i in u64(1) ..= REPLAY_HANDLE_MAP_CAPACITY {
		testing.expect(t, replay_handle_map_insert(&table, i, i + 1000))
	}
	// Duplicate and past-capacity inserts are refused.
	testing.expect(t, !replay_handle_map_insert(&table, 1, 9999))
	testing.expect(t, !replay_handle_map_insert(&table, REPLAY_HANDLE_MAP_CAPACITY + 1, 9999))

	// Lookup and remove reuse the slot cleanly.
	real, ok := replay_handle_map_lookup(&table, 42)
	testing.expect(t, ok)
	testing.expect_value(t, real, u64(1042))
	removed, rem_ok := replay_handle_map_remove(&table, 42)
	testing.expect(t, rem_ok)
	testing.expect_value(t, removed, u64(1042))
	_, still_there := replay_handle_map_lookup(&table, 42)
	testing.expect(t, !still_there)
	testing.expect(t, replay_handle_map_insert(&table, 999, 5555))
	real2, ok2 := replay_handle_map_lookup(&table, 999)
	testing.expect(t, ok2)
	testing.expect_value(t, real2, u64(5555))
}
