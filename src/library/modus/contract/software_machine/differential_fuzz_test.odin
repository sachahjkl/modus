#+build !freestanding
#+build !modus
#+build linux
#+build amd64
package software_machine

import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"
import "core:sys/linux"
import "core:testing"

// Differential host fuzzer for software_machine against native x86-64 hardware
// execution (src/md/features/browser_machine.md, "The order of the work").
//
// Maps a 4-page native arena (code, trampoline bridge, guest data, guest stack)
// via mmap and maps the exact same virtual addresses of code, data, and stack
// into software_machine's 4-level page tables. Every generated instruction or
// multi-instruction sequence runs on:
//   1. Native x86-64 silicon through the register/flag/XMM/MXCSR trampoline.
//   2. software_machine.processor_step (single-instruction interpreter).
//   3. software_machine.processor_run with a populated Block_Cache.
// All three must match bit-for-bit on all 16 GPRs, architecturally defined
// RFLAGS bits, all 16 XMM registers, defined MXCSR flags, and both 4 KiB
// guest data and stack pages.

// Format property: 4 x86-64 4 KiB pages for code, bridge, data, and stack.
DIFF_ARENA_PAGES :: 4
DIFF_ARENA_BYTES :: DIFF_ARENA_PAGES * int(PAGE_SIZE)

// Format property: fixed offsets within the 4-page differential arena.
DIFF_CODE_OFFSET :: 0x0000
DIFF_EPILOGUE_OFFSET :: 0x0200
DIFF_TAKEN_PAD_OFFSET :: 0x0400
DIFF_FALLTHROUGH_PAD_OFFSET :: 0x0420
DIFF_SNIPPET_OFFSET :: 0x0500

DIFF_BRIDGE_OFFSET :: 0x1000
DIFF_HOST_RBX :: DIFF_BRIDGE_OFFSET + 0x000
DIFF_HOST_RBP :: DIFF_BRIDGE_OFFSET + 0x008
DIFF_HOST_R12 :: DIFF_BRIDGE_OFFSET + 0x010
DIFF_HOST_R13 :: DIFF_BRIDGE_OFFSET + 0x018
DIFF_HOST_R14 :: DIFF_BRIDGE_OFFSET + 0x020
DIFF_HOST_R15 :: DIFF_BRIDGE_OFFSET + 0x028
DIFF_HOST_RSP :: DIFF_BRIDGE_OFFSET + 0x030
DIFF_HOST_MXCSR :: DIFF_BRIDGE_OFFSET + 0x038
DIFF_HOST_RFLAGS :: DIFF_BRIDGE_OFFSET + 0x040

DIFF_GUEST_GPRS :: DIFF_BRIDGE_OFFSET + 0x100
DIFF_GUEST_RFLAGS :: DIFF_BRIDGE_OFFSET + 0x180
DIFF_GUEST_MXCSR :: DIFF_BRIDGE_OFFSET + 0x188
DIFF_GUEST_XMM :: DIFF_BRIDGE_OFFSET + 0x190

DIFF_DATA_OFFSET :: 0x2000
DIFF_STACK_OFFSET :: 0x3000
DIFF_INITIAL_STACK_OFFSET :: DIFF_STACK_OFFSET + 0x800
DIFF_BRANCH_MARKER_OFFSET :: DIFF_DATA_OFFSET + 0xFF0

// Format property: architectural user-modifiable RFLAGS bits (CF, PF, AF, ZF, SF, DF, OF).
DIFF_FLAGS_ARITH :: RFLAGS_CF | RFLAGS_PF | RFLAGS_AF | RFLAGS_ZF | RFLAGS_SF | RFLAGS_OF
DIFF_FLAGS_ALL :: DIFF_FLAGS_ARITH | RFLAGS_DF
DIFF_FLAGS_LOGIC :: RFLAGS_CF | RFLAGS_PF | RFLAGS_ZF | RFLAGS_SF | RFLAGS_OF
DIFF_FLAGS_NO_AF :: RFLAGS_CF | RFLAGS_PF | RFLAGS_ZF | RFLAGS_SF | RFLAGS_OF | RFLAGS_DF
DIFF_FLAGS_CF_OF :: RFLAGS_CF | RFLAGS_OF | RFLAGS_DF
DIFF_FLAGS_SHIFT_MULTI :: RFLAGS_CF | RFLAGS_PF | RFLAGS_ZF | RFLAGS_SF | RFLAGS_DF
DIFF_FLAGS_SHLD_MULTI :: RFLAGS_CF | RFLAGS_PF | RFLAGS_ZF | RFLAGS_SF | RFLAGS_DF
DIFF_FLAGS_NONE :: RFLAGS_DF

// Format property: MXCSR flags excluding Precision (bit 5), which software_machine
// intentionally raises only on overflow or flush-to-zero.
DIFF_MXCSR_DEFINED_MASK :: u32(0xFFDF)

// Plan value: software_machine step limit per differential snippet so runaway
// sequences cannot stall a host test.
DIFF_STEP_BUDGET :: u64(4096)

// Plan value: physical RAM size for software_machine fixture (32 x 4 KiB frames).
DIFF_SW_RAM_BYTES :: 32 * int(PAGE_SIZE)

// Plan value: deterministic PRNG seed for reproducible differential fuzzing.
DIFF_PRNG_SEED :: u64(0x9E37_79B9_7F4A_7C15)

Diff_State :: struct {
	gprs:   [16]u64,
	rflags: u64,
	xmm:    [16][16]u8,
	mxcsr:  u32,
	data:   [PAGE_SIZE]u8,
	stack:  [PAGE_SIZE]u8,
}

Diff_Arena :: struct {
	base:        rawptr,
	bytes:       []u8,
	va:          u64,
	blocks:      Block_Cache,
	sw_machine:  Test_Machine,
	code_frame:  u64,
	data_frame:  u64,
	stack_frame: u64,
}

Diff_Prng :: struct {
	state: u64,
}

@(private = "file")
prng_next :: proc(p: ^Diff_Prng) -> u64 {
	x := p.state
	x ~= x >> 12
	x ~= x << 25
	x ~= x >> 27
	p.state = x
	return x * 0x2545_F491_4F6C_DD1D
}

@(private = "file")
EDGE_VALUES_U64 := [?]u64 {
	0x0000_0000_0000_0000,
	0x0000_0000_0000_0001,
	0x0000_0000_0000_0002,
	0x0000_0000_0000_000F,
	0x0000_0000_0000_0010,
	0x0000_0000_0000_007F,
	0x0000_0000_0000_0080,
	0x0000_0000_0000_00FF,
	0x0000_0000_0000_7FFF,
	0x0000_0000_0000_8000,
	0x0000_0000_0000_FFFF,
	0x0000_0000_7FFF_FFFF,
	0x0000_0000_8000_0000,
	0x0000_0000_FFFF_FFFF,
	0x7FFF_FFFF_FFFF_FFFF,
	0x8000_0000_0000_0000,
	0xFFFF_FFFF_FFFF_FFFF,
	0x5555_5555_5555_5555,
	0xAAAA_AAAA_AAAA_AAAA,
	0x0123_4567_89AB_CDEF,
	0xFEDC_BA98_7654_3210,
}

@(private = "file")
prng_edge_or_rand :: proc(p: ^Diff_Prng) -> u64 {
	r := prng_next(p)
	if (r & 3) != 0 {
		return EDGE_VALUES_U64[(r >> 2) % u64(len(EDGE_VALUES_U64))]
	}
	return prng_next(p)
}

@(private = "file")
Emit_Buf :: struct {
	code: []u8,
	pos:  int,
}

@(private = "file")
emit_b :: proc(e: ^Emit_Buf, bytes: ..u8) {
	for b in bytes {
		e.code[e.pos] = b
		e.pos += 1
	}
}

@(private = "file")
emit_u32 :: proc(e: ^Emit_Buf, v: u32) {
	emit_b(e, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

@(private = "file")
emit_i32 :: proc(e: ^Emit_Buf, v: i32) {
	emit_u32(e, u32(v))
}

@(private = "file")
emit_u64 :: proc(e: ^Emit_Buf, v: u64) {
	emit_u32(e, u32(v))
	emit_u32(e, u32(v >> 32))
}

// Emits: mov [rip + target_off], reg64 (opcode 0x89, mod=0, rm=5).
@(private = "file")
emit_store_gpr_rip :: proc(e: ^Emit_Buf, reg: u8, target_off: int) {
	rex := u8(0x48) | (u8(0x04) if reg >= 8 else 0)
	modrm := u8(0x05) | ((reg & 7) << 3)
	disp := i32(target_off - (e.pos + 7))
	emit_b(e, rex, 0x89, modrm)
	emit_i32(e, disp)
}

// Emits: mov reg64, [rip + target_off] (opcode 0x8B, mod=0, rm=5).
@(private = "file")
emit_load_gpr_rip :: proc(e: ^Emit_Buf, reg: u8, target_off: int) {
	rex := u8(0x48) | (u8(0x04) if reg >= 8 else 0)
	modrm := u8(0x05) | ((reg & 7) << 3)
	disp := i32(target_off - (e.pos + 7))
	emit_b(e, rex, 0x8B, modrm)
	emit_i32(e, disp)
}

// Emits: movdqu xmm, [rip + target_off] (F3 [REX] 0F 6F modrm disp32).
@(private = "file")
emit_load_xmm_rip :: proc(e: ^Emit_Buf, xmm: u8, target_off: int) {
	has_rex := xmm >= 8
	insn_len := 9 if has_rex else 8
	disp := i32(target_off - (e.pos + insn_len))
	emit_b(e, 0xF3)
	if has_rex {
		emit_b(e, 0x44)
	}
	emit_b(e, 0x0F, 0x6F, u8(0x05) | ((xmm & 7) << 3))
	emit_i32(e, disp)
}

// Emits: movdqu [rip + target_off], xmm (F3 [REX] 0F 7F modrm disp32).
@(private = "file")
emit_store_xmm_rip :: proc(e: ^Emit_Buf, xmm: u8, target_off: int) {
	has_rex := xmm >= 8
	insn_len := 9 if has_rex else 8
	disp := i32(target_off - (e.pos + insn_len))
	emit_b(e, 0xF3)
	if has_rex {
		emit_b(e, 0x44)
	}
	emit_b(e, 0x0F, 0x7F, u8(0x05) | ((xmm & 7) << 3))
	emit_i32(e, disp)
}

// Emits: stmxcsr [rip + target_off] (0F AE /3, mod=0, rm=5).
@(private = "file")
emit_stmxcsr_rip :: proc(e: ^Emit_Buf, target_off: int) {
	disp := i32(target_off - (e.pos + 7))
	emit_b(e, 0x0F, 0xAE, 0x1D)
	emit_i32(e, disp)
}

// Emits: ldmxcsr [rip + target_off] (0F AE /2, mod=0, rm=5).
@(private = "file")
emit_ldmxcsr_rip :: proc(e: ^Emit_Buf, target_off: int) {
	disp := i32(target_off - (e.pos + 7))
	emit_b(e, 0x0F, 0xAE, 0x15)
	emit_i32(e, disp)
}

// Emits: jmp rel32 to target_off.
@(private = "file")
emit_jmp_rel32 :: proc(e: ^Emit_Buf, target_off: int) {
	disp := i32(target_off - (e.pos + 5))
	emit_b(e, 0xE9)
	emit_i32(e, disp)
}

// Emits: mov dword ptr [rip + target_off], imm32 (C7 05 disp32 imm32).
@(private = "file")
emit_store_u32_imm_rip :: proc(e: ^Emit_Buf, target_off: int, imm: u32) {
	disp := i32(target_off - (e.pos + 10))
	emit_b(e, 0xC7, 0x05)
	emit_i32(e, disp)
	emit_u32(e, imm)
}

@(private = "file")
diff_arena_create :: proc(t: ^testing.T) -> (arena: ^Diff_Arena, ok: bool) {
	ptr, err := linux.mmap(
		0,
		uint(DIFF_ARENA_BYTES),
		{.READ, .WRITE, .EXEC},
		{.PRIVATE, .ANONYMOUS},
		-1,
		0,
	)
	if err != .NONE || ptr == nil {
		testing.expectf(t, false, "mmap RWX arena failed: %v", err)
		return nil, false
	}
	arena = new(Diff_Arena)
	arena.base = ptr
	arena.bytes = ([^]u8)(ptr)[:DIFF_ARENA_BYTES]
	arena.va = u64(uintptr(ptr))

	// Fill code page with INT3 so any unexpected jump traps immediately.
	slice.fill(arena.bytes[:PAGE_SIZE], 0xCC)

	// Assemble Prologue at DIFF_CODE_OFFSET (0x0000).
	e := Emit_Buf{code = arena.bytes[:PAGE_SIZE], pos = DIFF_CODE_OFFSET}
	emit_store_gpr_rip(&e, u8(General_Register.Rbx), DIFF_HOST_RBX)
	emit_store_gpr_rip(&e, u8(General_Register.Rbp), DIFF_HOST_RBP)
	emit_store_gpr_rip(&e, u8(General_Register.R12), DIFF_HOST_R12)
	emit_store_gpr_rip(&e, u8(General_Register.R13), DIFF_HOST_R13)
	emit_store_gpr_rip(&e, u8(General_Register.R14), DIFF_HOST_R14)
	emit_store_gpr_rip(&e, u8(General_Register.R15), DIFF_HOST_R15)
	emit_store_gpr_rip(&e, u8(General_Register.Rsp), DIFF_HOST_RSP)
	emit_stmxcsr_rip(&e, DIFF_HOST_MXCSR)
	emit_b(&e, 0x9C, 0x58) // pushfq; pop rax
	emit_store_gpr_rip(&e, u8(General_Register.Rax), DIFF_HOST_RFLAGS)

	emit_ldmxcsr_rip(&e, DIFF_GUEST_MXCSR)
	for i in u8(0) ..< 16 {
		emit_load_xmm_rip(&e, i, DIFF_GUEST_XMM + int(i) * 16)
	}
	emit_load_gpr_rip(&e, u8(General_Register.Rax), DIFF_GUEST_RFLAGS)
	emit_b(&e, 0x50, 0x9D) // push rax; popfq
	for r in u8(0) ..< 16 {
		emit_load_gpr_rip(&e, r, DIFF_GUEST_GPRS + int(r) * 8)
	}
	emit_jmp_rel32(&e, DIFF_SNIPPET_OFFSET)
	testing.expectf(t, e.pos <= DIFF_EPILOGUE_OFFSET, "prologue overflowed epilogue offset: %d", e.pos)

	// Assemble Epilogue at DIFF_EPILOGUE_OFFSET (0x0200).
	e.pos = DIFF_EPILOGUE_OFFSET
	for r in u8(0) ..< 16 {
		emit_store_gpr_rip(&e, r, DIFF_GUEST_GPRS + int(r) * 8)
	}
	emit_load_gpr_rip(&e, u8(General_Register.Rsp), DIFF_HOST_RSP)
	emit_b(&e, 0x9C, 0xFC, 0x58) // pushfq; cld; pop rax
	emit_store_gpr_rip(&e, u8(General_Register.Rax), DIFF_GUEST_RFLAGS)
	emit_stmxcsr_rip(&e, DIFF_GUEST_MXCSR)
	for i in u8(0) ..< 16 {
		emit_store_xmm_rip(&e, i, DIFF_GUEST_XMM + int(i) * 16)
	}
	emit_ldmxcsr_rip(&e, DIFF_HOST_MXCSR)
	emit_load_gpr_rip(&e, u8(General_Register.Rax), DIFF_HOST_RFLAGS)
	emit_b(&e, 0x50, 0x9D) // push rax; popfq
	emit_load_gpr_rip(&e, u8(General_Register.Rbx), DIFF_HOST_RBX)
	emit_load_gpr_rip(&e, u8(General_Register.Rbp), DIFF_HOST_RBP)
	emit_load_gpr_rip(&e, u8(General_Register.R12), DIFF_HOST_R12)
	emit_load_gpr_rip(&e, u8(General_Register.R13), DIFF_HOST_R13)
	emit_load_gpr_rip(&e, u8(General_Register.R14), DIFF_HOST_R14)
	emit_load_gpr_rip(&e, u8(General_Register.R15), DIFF_HOST_R15)
	emit_b(&e, 0xC3) // ret
	testing.expectf(t, e.pos <= DIFF_TAKEN_PAD_OFFSET, "epilogue overflowed taken pad: %d", e.pos)

	// Assemble branch landing pads at 0x0300 (taken) and 0x0320 (fallthrough).
	e.pos = DIFF_TAKEN_PAD_OFFSET
	emit_store_u32_imm_rip(&e, DIFF_BRANCH_MARKER_OFFSET, 1)
	emit_jmp_rel32(&e, DIFF_EPILOGUE_OFFSET)

	e.pos = DIFF_FALLTHROUGH_PAD_OFFSET
	emit_store_u32_imm_rip(&e, DIFF_BRANCH_MARKER_OFFSET, 2)
	emit_jmp_rel32(&e, DIFF_EPILOGUE_OFFSET)

	// Build software_machine page tables once and reuse across all snippets.
	arena.sw_machine = test_machine_create(DIFF_SW_RAM_BYTES)
	arena.code_frame = test_alloc_frame(&arena.sw_machine)
	arena.data_frame = test_alloc_frame(&arena.sw_machine)
	arena.stack_frame = test_alloc_frame(&arena.sw_machine)
	test_map_4k_page(&arena.sw_machine, arena.va + DIFF_CODE_OFFSET, arena.code_frame, PAGE_PRESENT | PAGE_USER)
	test_map_4k_page(&arena.sw_machine, arena.va + DIFF_DATA_OFFSET, arena.data_frame, PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)
	test_map_4k_page(&arena.sw_machine, arena.va + DIFF_STACK_OFFSET, arena.stack_frame, PAGE_PRESENT | PAGE_WRITE | PAGE_USER | PAGE_NO_EXECUTE)
	copy(arena.sw_machine.ram[arena.code_frame:arena.code_frame + PAGE_SIZE], arena.bytes[DIFF_CODE_OFFSET:DIFF_CODE_OFFSET + int(PAGE_SIZE)])
	arena.sw_machine.ram[arena.code_frame + DIFF_EPILOGUE_OFFSET] = 0xCC

	return arena, true
}

@(private = "file")
diff_arena_destroy :: proc(arena: ^Diff_Arena) {
	if arena == nil {
		return
	}
	test_machine_destroy(&arena.sw_machine)
	if arena.base != nil {
		_ = linux.munmap(arena.base, uint(DIFF_ARENA_BYTES))
		arena.base = nil
		arena.bytes = nil
	}
	free(arena)
}

@(private = "file")
diff_run_native :: proc(arena: ^Diff_Arena, code: []u8, input: ^Diff_State) -> (out: Diff_State) {
	// Write snippet + jmp epilogue into code page.
	copy(arena.bytes[DIFF_SNIPPET_OFFSET:], code)
	e := Emit_Buf{code = arena.bytes[:PAGE_SIZE], pos = DIFF_SNIPPET_OFFSET + len(code)}
	emit_jmp_rel32(&e, DIFF_EPILOGUE_OFFSET)

	// Write guest state into bridge + data + stack pages.
	mem.copy(&arena.bytes[DIFF_GUEST_GPRS], &input.gprs[0], size_of(input.gprs))
	safe_flags := (input.rflags & DIFF_FLAGS_ALL) | USER_INITIAL_RFLAGS
	mem.copy(&arena.bytes[DIFF_GUEST_RFLAGS], &safe_flags, size_of(safe_flags))
	safe_mxcsr := input.mxcsr & MXCSR_MASK
	mem.copy(&arena.bytes[DIFF_GUEST_MXCSR], &safe_mxcsr, size_of(safe_mxcsr))
	mem.copy(&arena.bytes[DIFF_GUEST_XMM], &input.xmm[0][0], size_of(input.xmm))
	copy(arena.bytes[DIFF_DATA_OFFSET:DIFF_DATA_OFFSET + int(PAGE_SIZE)], input.data[:])
	copy(arena.bytes[DIFF_STACK_OFFSET:DIFF_STACK_OFFSET + int(PAGE_SIZE)], input.stack[:])

	entry := (proc "c" ())(arena.base)
	entry()

	mem.copy(&out.gprs[0], &arena.bytes[DIFF_GUEST_GPRS], size_of(out.gprs))
	mem.copy(&out.rflags, &arena.bytes[DIFF_GUEST_RFLAGS], size_of(out.rflags))
	mem.copy(&out.mxcsr, &arena.bytes[DIFF_GUEST_MXCSR], size_of(out.mxcsr))
	mem.copy(&out.xmm[0][0], &arena.bytes[DIFF_GUEST_XMM], size_of(out.xmm))
	copy(out.data[:], arena.bytes[DIFF_DATA_OFFSET:DIFF_DATA_OFFSET + int(PAGE_SIZE)])
	copy(out.stack[:], arena.bytes[DIFF_STACK_OFFSET:DIFF_STACK_OFFSET + int(PAGE_SIZE)])
	return out
}

@(private = "file")
diff_run_software :: proc(arena: ^Diff_Arena, code: []u8, input: ^Diff_State, use_blocks: bool) -> (out: Diff_State, outcome: Step_Outcome, final_rip: u64) {
	m := &arena.sw_machine
	// Copy updated snippet + trailing jmp epilogue (len(code) + 5 bytes) into software code frame.
	snippet_len := len(code) + 5
	copy(m.ram[arena.code_frame + DIFF_SNIPPET_OFFSET:][:snippet_len], arena.bytes[DIFF_SNIPPET_OFFSET:][:snippet_len])
	copy(m.ram[arena.data_frame:arena.data_frame + PAGE_SIZE], input.data[:])
	copy(m.ram[arena.stack_frame:arena.stack_frame + PAGE_SIZE], input.stack[:])

	cpu: Processor_State
	processor_init(&cpu, m.cr3, arena.va + DIFF_SNIPPET_OFFSET, input.gprs[int(General_Register.Rsp)])
	cpu.registers = input.gprs
	cpu.rflags = (input.rflags & DIFF_FLAGS_ALL) | USER_INITIAL_RFLAGS
	cpu.xmm = input.xmm
	cpu.mxcsr = input.mxcsr & MXCSR_MASK

	if use_blocks {
		cpu.blocks = &arena.blocks
		outcome = processor_run(&cpu, m.ram, DIFF_STEP_BUDGET)
	} else {
		outcome = .Running
		for _ in 0 ..< DIFF_STEP_BUDGET {
			outcome = processor_step(&cpu, m.ram)
			if outcome != .Running {
				break
			}
		}
	}

	out.gprs = cpu.registers
	out.rflags = cpu.rflags
	out.xmm = cpu.xmm
	out.mxcsr = cpu.mxcsr
	copy(out.data[:], m.ram[arena.data_frame:arena.data_frame + PAGE_SIZE])
	copy(out.stack[:], m.ram[arena.stack_frame:arena.stack_frame + PAGE_SIZE])
	return out, outcome, cpu.rip
}

Diff_Compare_Options :: struct {
	rflags_mask:       u64,
	mxcsr_mask:        u32,
	ignore_reg_mask:   u16, // Bit r ignores GPR r (for architecturally undefined BSF/BSR dst on 0).
	check_probe:       bool,
}

@(private = "file")
diff_default_options :: proc(rflags_mask := DIFF_FLAGS_ALL) -> Diff_Compare_Options {
	return {
		rflags_mask = rflags_mask,
		mxcsr_mask  = DIFF_MXCSR_DEFINED_MASK,
		check_probe = true,
	}
}

@(private = "file")
diff_check :: proc(t: ^testing.T, arena: ^Diff_Arena, label: string, code: []u8, input: ^Diff_State, opts: Diff_Compare_Options) -> bool {
	if opts.check_probe {
		off := 0
		for off < len(code) {
			p := instruction_probe(code[off:])
			if p.status != .Supported || p.length <= 0 {
				testing.expectf(t, false, "%s: instruction_probe failed at +%d (status=%v len=%d bytes=%x)", label, off, p.status, p.length, code[off:])
				return false
			}
			off += p.length
		}
	}

	native := diff_run_native(arena, code, input)
	sw_step, step_outcome, step_rip := diff_run_software(arena, code, input, false)
	sw_block, block_outcome, block_rip := diff_run_software(arena, code, input, true)

	expected_rip := arena.va + DIFF_EPILOGUE_OFFSET + 1
	if step_outcome != .Breakpoint || step_rip != expected_rip {
		testing.expectf(t, false, "%s: sw_step ended with %v at %x (expected Breakpoint at %x) code=%x", label, step_outcome, step_rip, expected_rip, code)
		return false
	}
	if block_outcome != .Breakpoint || block_rip != expected_rip {
		testing.expectf(t, false, "%s: sw_block ended with %v at %x (expected Breakpoint at %x) code=%x", label, block_outcome, block_rip, expected_rip, code)
		return false
	}

	for mode_idx in 0 ..< 2 {
		sw := &sw_step if mode_idx == 0 else &sw_block
		mode := "step" if mode_idx == 0 else "block"
		for r in 0 ..< 16 {
			if (opts.ignore_reg_mask & (u16(1) << uint(r))) != 0 {
				continue
			}
			if native.gprs[r] != sw.gprs[r] {
				testing.expectf(t, false, "%s (%s): GPR %v mismatch: native=%016x sw=%016x (in=%016x) code=%x", label, mode, General_Register(r), native.gprs[r], sw.gprs[r], input.gprs[r], code)
				return false
			}
		}
		nf := native.rflags & opts.rflags_mask
		sf := sw.rflags & opts.rflags_mask
		if nf != sf {
			testing.expectf(t, false, "%s (%s): RFLAGS mismatch (mask=%04x): native=%04x sw=%04x (in=%04x) code=%x", label, mode, opts.rflags_mask, nf, sf, input.rflags & opts.rflags_mask, code)
			return false
		}
		nm := native.mxcsr & opts.mxcsr_mask
		sm := sw.mxcsr & opts.mxcsr_mask
		if nm != sm {
			testing.expectf(t, false, "%s (%s): MXCSR mismatch (mask=%04x): native=%04x sw=%04x code=%x", label, mode, opts.mxcsr_mask, nm, sm, code)
			return false
		}
		for x in 0 ..< 16 {
			if native.xmm[x] != sw.xmm[x] {
				testing.expectf(t, false, "%s (%s): XMM%d mismatch:\n  native=%x\n  sw    =%x\n  code  =%x", label, mode, x, native.xmm[x], sw.xmm[x], code)
				return false
			}
		}
		if native.data != sw.data {
			for i in 0 ..< len(native.data) {
				if native.data[i] != sw.data[i] {
					testing.expectf(t, false, "%s (%s): data page mismatch at +%03x: native=%02x sw=%02x code=%x", label, mode, i, native.data[i], sw.data[i], code)
					return false
				}
			}
		}
		if native.stack != sw.stack {
			for i in 0 ..< len(native.stack) {
				if native.stack[i] != sw.stack[i] {
					testing.expectf(t, false, "%s (%s): stack page mismatch at +%03x: native=%02x sw=%02x code=%x", label, mode, i, native.stack[i], sw.stack[i], code)
					return false
				}
			}
		}
	}
	return true
}

@(private = "file")
diff_seed_state :: proc(arena: ^Diff_Arena, p: ^Diff_Prng) -> (s: Diff_State) {
	for r in 0 ..< 16 {
		s.gprs[r] = prng_edge_or_rand(p)
	}
	s.gprs[int(General_Register.Rsp)] = arena.va + DIFF_INITIAL_STACK_OFFSET
	s.rflags = (prng_next(p) & DIFF_FLAGS_ARITH) | USER_INITIAL_RFLAGS
	s.mxcsr = MXCSR_START
	for x in 0 ..< 16 {
		lo := prng_next(p)
		hi := prng_next(p)
		mem.copy(&s.xmm[x][0], &lo, 8)
		mem.copy(&s.xmm[x][8], &hi, 8)
	}
	for i := 0; i < len(s.data); i += 8 {
		v := prng_next(p)
		mem.copy(&s.data[i], &v, 8)
	}
	for i := 0; i < len(s.stack); i += 8 {
		v := prng_next(p)
		mem.copy(&s.stack[i], &v, 8)
	}
	return s
}

// -----------------------------------------------------------------------------
// 1. Exhaustive ALU, Shifts/Rotates, Double Shifts, Unary, Mul/Div, Bit Ops
// -----------------------------------------------------------------------------

@(test)
diff_fuzz_alu_all_widths_and_encodings :: proc(t: ^testing.T) {
	arena, ok := diff_arena_create(t)
	if !ok {
		return
	}
	defer diff_arena_destroy(arena)

	prng := Diff_Prng{state = DIFF_PRNG_SEED}

	// All 8 ALU ops (ADD, OR, ADC, SBB, AND, SUB, XOR, CMP) across 8/16/32/64-bit,
	// register-register, memory-register, register-memory, AL/rAX-imm, and 80/81/83 imm.
	for alu in 0 ..< 8 {
		is_logic := alu == 1 || alu == 4 || alu == 6
		mask := DIFF_FLAGS_LOGIC if is_logic else DIFF_FLAGS_ALL
		opts := diff_default_options(mask)
		base_op := u8(alu << 3)

		for iter in 0 ..< 16 {
			s := diff_seed_state(arena, &prng)
			s.gprs[int(General_Register.Rbx)] = arena.va + DIFF_DATA_OFFSET + u64((iter * 16) & 0x3F0)
			if (iter & 1) != 0 {
				s.rflags |= RFLAGS_CF
			} else {
				s.rflags &~= RFLAGS_CF
			}

			// 8-bit reg-reg (including high-byte AH/CH/DH/BH without REX and SIL/DIL/R8B with REX).
			c8_hi := [?]u8{base_op + 0, 0xE4} // ALU ah, ah / spl? No, without REX reg=4 (AH), rm=4 (AH)
			if !diff_check(t, arena, fmt.tprintf("alu%d_r8_hi", alu), c8_hi[:], &s, opts) {
				return
			}
			c8_hi2 := [?]u8{base_op + 2, 0xEC} // ALU ch, ah (reg=5 CH, rm=4 AH)
			if !diff_check(t, arena, fmt.tprintf("alu%d_r8_ch_ah", alu), c8_hi2[:], &s, opts) {
				return
			}
			c8_rex := [?]u8{0x45, base_op + 0, 0xCE} // ALU r14b, r9b
			if !diff_check(t, arena, fmt.tprintf("alu%d_r8_rex", alu), c8_rex[:], &s, opts) {
				return
			}
			c8_mem := [?]u8{base_op + 0, 0x4B, 0x03} // ALU [rbx+3], cl
			if !diff_check(t, arena, fmt.tprintf("alu%d_m8_r8", alu), c8_mem[:], &s, opts) {
				return
			}

			// 16-bit, 32-bit, 64-bit reg-reg and mem-reg.
			c16 := [?]u8{0x66, base_op + 1, 0xD0} // ALU ax, dx
			if !diff_check(t, arena, fmt.tprintf("alu%d_r16", alu), c16[:], &s, opts) {
				return
			}
			c32 := [?]u8{base_op + 3, 0xC2} // ALU eax, edx
			if !diff_check(t, arena, fmt.tprintf("alu%d_r32", alu), c32[:], &s, opts) {
				return
			}
			c64 := [?]u8{0x48, base_op + 1, 0xD0} // ALU rax, rdx
			if !diff_check(t, arena, fmt.tprintf("alu%d_r64", alu), c64[:], &s, opts) {
				return
			}
			c64_m := [?]u8{0x48, base_op + 1, 0x43, 0x08} // ALU [rbx+8], rax
			if !diff_check(t, arena, fmt.tprintf("alu%d_m64_r64", alu), c64_m[:], &s, opts) {
				return
			}
			c64_rm := [?]u8{0x4C, base_op + 3, 0x4B, 0x10} // ALU r9, [rbx+16]
			if !diff_check(t, arena, fmt.tprintf("alu%d_r64_m64", alu), c64_rm[:], &s, opts) {
				return
			}

			// Immediate forms: AL/rAX and Group 1 (80/81/83).
			imm8 := u8(prng_edge_or_rand(&prng))
			imm32 := u32(prng_edge_or_rand(&prng))
			c_al := [?]u8{base_op + 4, imm8}
			if !diff_check(t, arena, fmt.tprintf("alu%d_al_imm8", alu), c_al[:], &s, opts) {
				return
			}
			c_rax := [?]u8{0x48, base_op + 5, u8(imm32), u8(imm32 >> 8), u8(imm32 >> 16), u8(imm32 >> 24)}
			if !diff_check(t, arena, fmt.tprintf("alu%d_rax_imm32", alu), c_rax[:], &s, opts) {
				return
			}
			c_80 := [?]u8{0x80, u8(0xC0 | (alu << 3) | 1), imm8} // ALU cl, imm8
			if !diff_check(t, arena, fmt.tprintf("alu%d_80_cl", alu), c_80[:], &s, opts) {
				return
			}
			c_81 := [?]u8{0x66, 0x81, u8(0xC0 | (alu << 3) | 2), u8(imm32), u8(imm32 >> 8)} // ALU dx, imm16
			if !diff_check(t, arena, fmt.tprintf("alu%d_81_dx", alu), c_81[:], &s, opts) {
				return
			}
			c_83 := [?]u8{0x48, 0x83, u8(0xC0 | (alu << 3) | 0), imm8} // ALU rax, sign-ext imm8
			if !diff_check(t, arena, fmt.tprintf("alu%d_83_rax", alu), c_83[:], &s, opts) {
				return
			}
		}
	}
}

@(test)
diff_fuzz_shifts_rotates_and_double_shifts :: proc(t: ^testing.T) {
	arena, ok := diff_arena_create(t)
	if !ok {
		return
	}
	defer diff_arena_destroy(arena)

	prng := Diff_Prng{state = DIFF_PRNG_SEED ~ 0x1111_2222}
	shift_subs := [?]u8{0, 1, 4, 5, 7} // ROL, ROR, SHL, SHR, SAR
	counts := [?]u8{0, 1, 2, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 255}

	for sub in shift_subs {
		is_rot := sub == 0 || sub == 1
		for count in counts {
			s := diff_seed_state(arena, &prng)
			s.gprs[int(General_Register.Rcx)] = (s.gprs[int(General_Register.Rcx)] & ~u64(0xFF)) | u64(count)
			s.gprs[int(General_Register.Rbx)] = arena.va + DIFF_DATA_OFFSET + 64

			// Determine architecturally defined flags per Intel SDM for each width.
			widths := [?]struct {
				bits:   uint,
				prefix: u8, // 0=none, 0x66=16-bit, 0x48=64-bit
				is8:    bool,
			}{
				{8, 0, true},
				{16, 0x66, false},
				{32, 0, false},
				{64, 0x48, false},
			}

			for w in widths {
				mask_val := u8(63) if w.bits == 64 else u8(31)
				eff_count := uint(count & mask_val)
				fmask: u64
				if eff_count == 0 {
					fmask = DIFF_FLAGS_ALL
				} else if is_rot {
					// ROL/ROR preserve SF, ZF, AF, PF; define CF when (eff_count % bits) != 0, OF only when eff_count == 1.
					fmask = RFLAGS_SF | RFLAGS_ZF | RFLAGS_AF | RFLAGS_PF | RFLAGS_DF
					if (eff_count % w.bits) != 0 {
						fmask |= RFLAGS_CF
					}
					if eff_count == 1 {
						fmask |= RFLAGS_OF
					}
				} else {
					// SHL/SHR/SAR: SF, ZF, PF defined for count > 0; CF defined for count <= bits; OF defined only for count == 1; AF undefined.
					fmask = RFLAGS_SF | RFLAGS_ZF | RFLAGS_PF | RFLAGS_DF
					if eff_count <= w.bits {
						fmask |= RFLAGS_CF
					}
					if eff_count == 1 {
						fmask |= RFLAGS_OF
					}
				}
				opts := diff_default_options(fmask)

				// Test C0/C1 imm8 and D2/D3 CL on RAX and [RBX].
				buf: [8]u8
				n := 0
				if w.prefix != 0 {
					buf[n] = w.prefix
					n += 1
				}
				buf[n] = 0xC0 if w.is8 else 0xC1
				buf[n + 1] = 0xC0 | (sub << 3) | 0 // RAX
				buf[n + 2] = count
				if !diff_check(t, arena, fmt.tprintf("shift%d_w%d_imm%d", sub, w.bits, count), buf[:n + 3], &s, opts) {
					return
				}

				buf[n] = 0xD2 if w.is8 else 0xD3
				buf[n + 1] = 0xC0 | (sub << 3) | 0 // RAX, CL
				if !diff_check(t, arena, fmt.tprintf("shift%d_w%d_cl%d", sub, w.bits, count), buf[:n + 2], &s, opts) {
					return
				}

				// Memory form [rbx+8], CL.
				buf[n] = 0xD2 if w.is8 else 0xD3
				buf[n + 1] = 0x40 | (sub << 3) | 3 // [rbx + disp8]
				buf[n + 2] = 8
				if !diff_check(t, arena, fmt.tprintf("shift%d_m%d_cl%d", sub, w.bits, count), buf[:n + 3], &s, opts) {
					return
				}
			}

			// Test D0/D1 (shift by 1) explicitly.
			if count == 1 {
				fmask1 := (RFLAGS_CF | RFLAGS_OF | RFLAGS_SF | RFLAGS_ZF | RFLAGS_PF | RFLAGS_DF) if !is_rot else (RFLAGS_CF | RFLAGS_OF | RFLAGS_SF | RFLAGS_ZF | RFLAGS_AF | RFLAGS_PF | RFLAGS_DF)
				c_d1 := [?]u8{0x48, 0xD1, 0xC0 | (sub << 3) | 2} // RDX by 1
				if !diff_check(t, arena, fmt.tprintf("shift%d_d1", sub), c_d1[:], &s, diff_default_options(fmask1)) {
					return
				}
			}
		}
	}

	// Double shifts: SHLD (0F A4/A5) and SHRD (0F AC/AD) across 16/32/64-bit.
	ds_counts := [?]u8{0, 1, 5, 15, 16, 31, 32, 63, 64}
	for count in ds_counts {
		s := diff_seed_state(arena, &prng)
		s.gprs[int(General_Register.Rcx)] = (s.gprs[int(General_Register.Rcx)] & ~u64(0xFF)) | u64(count)
		for op2 in ([?]u8{0xA4, 0xA5, 0xAC, 0xAD}) {
			has_imm := op2 == 0xA4 || op2 == 0xAC
			for w_idx in 0 ..< 3 {
				bits := uint(16) if w_idx == 0 else (uint(32) if w_idx == 1 else uint(64))
				eff := uint(count & (63 if bits == 64 else 31))
				// For 16-bit with count >= 16, Intel SDM marks result and flags undefined;
				// skip count >= 16 on 16-bit against silicon.
				if bits == 16 && eff >= 16 {
					continue
				}
				fmask := DIFF_FLAGS_ALL if eff == 0 else (DIFF_FLAGS_NO_AF if eff == 1 else DIFF_FLAGS_SHLD_MULTI)
				buf: [8]u8
				n := 0
				if w_idx == 0 {
					buf[n] = 0x66
					n += 1
				} else if w_idx == 2 {
					buf[n] = 0x48
					n += 1
				}
				buf[n] = 0x0F
				buf[n + 1] = op2
				buf[n + 2] = 0xD0 // rm=RAX, reg=RDX
				n += 3
				if has_imm {
					buf[n] = count
					n += 1
				}
				if !diff_check(t, arena, fmt.tprintf("dshift_%02x_w%d_c%d", op2, bits, count), buf[:n], &s, diff_default_options(fmask)) {
					return
				}
			}
		}
	}
}

@(test)
diff_fuzz_unary_mul_div_bitops_and_atomics :: proc(t: ^testing.T) {
	arena, ok := diff_arena_create(t)
	if !ok {
		return
	}
	defer diff_arena_destroy(arena)

	prng := Diff_Prng{state = DIFF_PRNG_SEED ~ 0x3333_4444}

	for iter in 0 ..< 32 {
		s := diff_seed_state(arena, &prng)
		s.gprs[int(General_Register.Rbx)] = arena.va + DIFF_DATA_OFFSET + 128

		// TEST, NOT, NEG, INC, DEC across 8/16/32/64-bit.
		c_test64 := [?]u8{0x48, 0x85, 0xD0} // test rax, rdx
		if !diff_check(t, arena, "test64", c_test64[:], &s, diff_default_options(DIFF_FLAGS_LOGIC)) {
			return
		}
		c_test_imm := [?]u8{0x48, 0xF7, 0xC0, 0x55, 0xAA, 0x0F, 0x80} // test rax, imm32
		if !diff_check(t, arena, "test_f7_imm", c_test_imm[:], &s, diff_default_options(DIFF_FLAGS_LOGIC)) {
			return
		}
		c_not64 := [?]u8{0x48, 0xF7, 0xD0} // not rax
		if !diff_check(t, arena, "not64", c_not64[:], &s, diff_default_options(DIFF_FLAGS_ALL)) {
			return
		}
		c_neg64 := [?]u8{0x48, 0xF7, 0xD8} // neg rax
		if !diff_check(t, arena, "neg64", c_neg64[:], &s, diff_default_options(DIFF_FLAGS_ALL)) {
			return
		}
		c_neg8 := [?]u8{0xF6, 0xDC} // neg ah
		if !diff_check(t, arena, "neg8_ah", c_neg8[:], &s, diff_default_options(DIFF_FLAGS_ALL)) {
			return
		}
		c_inc8 := [?]u8{0xFE, 0xC0} // inc al (preserves CF)
		if !diff_check(t, arena, "inc8", c_inc8[:], &s, diff_default_options(DIFF_FLAGS_ALL)) {
			return
		}
		c_dec32 := [?]u8{0xFF, 0xC8} // dec eax (preserves CF, zero-extends RAX)
		if !diff_check(t, arena, "dec32", c_dec32[:], &s, diff_default_options(DIFF_FLAGS_ALL)) {
			return
		}
		c_inc64_lock := [?]u8{0xF0, 0x48, 0xFF, 0x03} // lock inc qword [rbx]
		if !diff_check(t, arena, "lock_inc64", c_inc64_lock[:], &s, diff_default_options(DIFF_FLAGS_ALL)) {
			return
		}

		// MUL & IMUL (1-op, 2-op, 3-op) across 8/16/32/64-bit.
		for code_entry in ([][]u8{
			{0xF6, 0xE2},                   // mul dl
			{0x66, 0xF7, 0xE2},             // mul dx
			{0xF7, 0xE2},                   // mul edx
			{0x48, 0xF7, 0xE2},             // mul rdx
			{0xF6, 0xEA},                   // imul dl
			{0x66, 0xF7, 0xEA},             // imul dx
			{0xF7, 0xEA},                   // imul edx
			{0x48, 0xF7, 0xEA},             // imul rdx
			{0x48, 0x0F, 0xAF, 0xC2},       // imul rax, rdx
			{0x0F, 0xAF, 0xC2},             // imul eax, edx
			{0x66, 0x0F, 0xAF, 0xC2},       // imul ax, dx
			{0x48, 0x6B, 0xC2, 0x81},       // imul rax, rdx, -127
			{0x48, 0x69, 0xC2, 0x78, 0x56, 0x34, 0x12}, // imul rax, rdx, 0x12345678
		}) {
			if !diff_check(t, arena, "mul_imul", code_entry, &s, diff_default_options(DIFF_FLAGS_CF_OF)) {
				return
			}
		}

		// Safe non-overflowing DIV and IDIV across 8/16/32/64-bit.
		{
			ds := s
			div_val := (prng_next(&prng) % 0x7FFF_FFFF) + 1
			ds.gprs[int(General_Register.Rcx)] = div_val
			ds.gprs[int(General_Register.Rdx)] = prng_next(&prng) % div_val
			c_div64 := [?]u8{0x48, 0xF7, 0xF1} // div rcx
			if !diff_check(t, arena, "div64", c_div64[:], &ds, diff_default_options(DIFF_FLAGS_NONE)) {
				return
			}
			ds.gprs[int(General_Register.Rdx)] = 0
			ds.gprs[int(General_Register.Rax)] = prng_next(&prng) & 0xFFFF_FFFF
			ds.gprs[int(General_Register.Rcx)] = (prng_next(&prng) % 0xFFFF) + 1
			// Use 32-bit div with edx < ecx.
			ds.gprs[int(General_Register.Rdx)] = prng_next(&prng) % ds.gprs[int(General_Register.Rcx)]
			c_div32 := [?]u8{0xF7, 0xF1}
			if !diff_check(t, arena, "div32", c_div32[:], &ds, diff_default_options(DIFF_FLAGS_NONE)) {
				return
			}
			// Signed 64-bit idiv via CQO + IDIV RCX (never overflows unless RAX=INT64_MIN && RCX=-1).
			idiv_s := s
			d64 := i64(prng_edge_or_rand(&prng))
			if d64 == 0 || d64 == -1 {
				d64 = -7
			}
			idiv_s.gprs[int(General_Register.Rcx)] = u64(d64)
			c_idiv64 := [?]u8{0x48, 0x99, 0x48, 0xF7, 0xF9} // cqo; idiv rcx
			if !diff_check(t, arena, "cqo_idiv64", c_idiv64[:], &idiv_s, diff_default_options(DIFF_FLAGS_NONE)) {
				return
			}
			c_idiv32 := [?]u8{0x99, 0xF7, 0xF9} // cdq; idiv ecx
			idiv_s.gprs[int(General_Register.Rcx)] = u64(u32(i32(-13) if (iter & 1) == 0 else i32(17)))
			if !diff_check(t, arena, "cdq_idiv32", c_idiv32[:], &idiv_s, diff_default_options(DIFF_FLAGS_NONE)) {
				return
			}
			// 8-bit idiv via CBW + IDIV CL.
			idiv_s.gprs[int(General_Register.Rcx)] = u64(u8(i8(-5) if (iter & 1) == 0 else i8(7)))
			c_idiv8 := [?]u8{0x66, 0x98, 0xF6, 0xF9} // cbw; idiv cl
			if !diff_check(t, arena, "cbw_idiv8", c_idiv8[:], &idiv_s, diff_default_options(DIFF_FLAGS_NONE)) {
				return
			}
		}

		// BT / BTS / BTR / BTC (register and memory with signed offsets in range [-256, +255]).
		{
			bs := s
			bs.gprs[int(General_Register.Rbx)] = arena.va + DIFF_DATA_OFFSET + 512
			off_i := i64(prng_next(&prng) % 512) - 256
			bs.gprs[int(General_Register.Rdx)] = u64(off_i)
			bt_opts := diff_default_options(RFLAGS_CF | RFLAGS_ZF | RFLAGS_DF)
			for op2 in ([?]u8{0xA3, 0xAB, 0xB3, 0xBB}) {
				c_bt_reg := [?]u8{0x48, 0x0F, op2, 0xD0} // bt* rax, rdx
				if !diff_check(t, arena, fmt.tprintf("bt_%02x_reg", op2), c_bt_reg[:], &bs, bt_opts) {
					return
				}
				c_bt_mem := [?]u8{0x48, 0x0F, op2, 0x13} // bt* [rbx], rdx
				if !diff_check(t, arena, fmt.tprintf("bt_%02x_mem", op2), c_bt_mem[:], &bs, bt_opts) {
					return
				}
				c_bt32_mem := [?]u8{0x0F, op2, 0x13} // bt* dword [rbx], edx
				if !diff_check(t, arena, fmt.tprintf("bt32_%02x_mem", op2), c_bt32_mem[:], &bs, bt_opts) {
					return
				}
			}
			for sub in u8(4) ..= 7 {
				imm := u8(prng_next(&prng))
				c_ba := [?]u8{0x48, 0x0F, 0xBA, 0xC0 | (sub << 3) | 0, imm}
				if !diff_check(t, arena, fmt.tprintf("ba_%d_reg", sub), c_ba[:], &bs, bt_opts) {
					return
				}
				c_ba_m := [?]u8{0x48, 0x0F, 0xBA, (sub << 3) | 3, imm}
				if !diff_check(t, arena, fmt.tprintf("ba_%d_mem", sub), c_ba_m[:], &bs, bt_opts) {
					return
				}
			}
		}

		// BSF / BSR (non-zero & zero cases), BSWAP, MOVZX, MOVSX, MOVSXD, CBW/CWDE/CDQE.
		{
			bsf_opts := diff_default_options(RFLAGS_ZF | RFLAGS_DF)
			if s.gprs[int(General_Register.Rdx)] == 0 {
				bsf_opts.ignore_reg_mask = u16(1) << uint(General_Register.Rax)
			}
			for c in ([][]u8{
				{0x48, 0x0F, 0xBC, 0xC2}, // bsf rax, rdx
				{0x48, 0x0F, 0xBD, 0xC2}, // bsr rax, rdx
				{0x0F, 0xBC, 0xC2},       // bsf eax, edx
				{0x0F, 0xBD, 0xC2},       // bsr eax, edx
				{0x66, 0x0F, 0xBC, 0xC2}, // bsf ax, dx
				{0x66, 0x0F, 0xBD, 0xC2}, // bsr ax, dx
			}) {
				opts := diff_default_options(RFLAGS_ZF | RFLAGS_DF)
				if (s.gprs[int(General_Register.Rdx)] & 0xFFFF) == 0 {
					opts.ignore_reg_mask = u16(1) << uint(General_Register.Rax)
				}
				if !diff_check(t, arena, "bsf_bsr", c, &s, opts) {
					return
				}
			}
			for c in ([][]u8{
				{0x48, 0x0F, 0xC8},       // bswap rax
				{0x0F, 0xC8},             // bswap eax
				{0x41, 0x0F, 0xCF},       // bswap r15d
				{0x49, 0x0F, 0xCF},       // bswap r15
				{0x48, 0x0F, 0xB6, 0xC2}, // movzx rax, dl
				{0x0F, 0xB6, 0xC6},       // movzx eax, dh
				{0x48, 0x0F, 0xB7, 0xC2}, // movzx rax, dx
				{0x48, 0x0F, 0xBE, 0xC2}, // movsx rax, dl
				{0x48, 0x0F, 0xBF, 0xC2}, // movsx rax, dx
				{0x48, 0x63, 0xC2},       // movsxd rax, edx
				{0x66, 0x98},             // cbw
				{0x98},                   // cwde
				{0x48, 0x98},             // cdqe
				{0x66, 0x99},             // cwd
				{0x99},                   // cdq
				{0x48, 0x99},             // cqo
				{0x90},                   // nop
				{0x48, 0x90},             // rex.w nop (must NOT zero-extend eax)
				{0x41, 0x90},             // xchg r8d, eax (MUST zero-extend both!)
				{0x49, 0x90},             // xchg r8, rax
				{0x48, 0x87, 0x03},       // xchg [rbx], rax
				{0x0F, 0xC3, 0x13},       // movnti [rbx], edx
				{0x48, 0x0F, 0xC3, 0x13}, // movnti [rbx], rdx
			}) {
				if !diff_check(t, arena, "misc_int", c, &s, diff_default_options(DIFF_FLAGS_ALL)) {
					return
				}
			}
		}

		// Atomic LOCK CMPXCHG (both equal and unequal paths) and LOCK XADD.
		{
			as := s
			as.gprs[int(General_Register.Rbx)] = arena.va + DIFF_DATA_OFFSET + 256
			if (iter & 1) == 0 {
				// Force match so exchange path runs.
				mem.copy(&as.data[256], &as.gprs[int(General_Register.Rax)], 8)
			}
			for c in ([][]u8{
				{0xF0, 0x0F, 0xB0, 0x13},       // lock cmpxchg byte [rbx], dl
				{0xF0, 0x66, 0x0F, 0xB1, 0x13}, // lock cmpxchg word [rbx], dx
				{0xF0, 0x0F, 0xB1, 0x13},       // lock cmpxchg dword [rbx], edx
				{0xF0, 0x48, 0x0F, 0xB1, 0x13}, // lock cmpxchg qword [rbx], rdx
				{0xF0, 0x0F, 0xC0, 0x13},       // lock xadd byte [rbx], dl
				{0xF0, 0x0F, 0xC1, 0x13},       // lock xadd dword [rbx], edx
				{0xF0, 0x48, 0x0F, 0xC1, 0x13}, // lock xadd qword [rbx], rdx
				{0xF0, 0x48, 0x01, 0x13},       // lock add qword [rbx], rdx
				{0xF0, 0x48, 0x29, 0x13},       // lock sub qword [rbx], rdx
			}) {
				if !diff_check(t, arena, "lock_atomic", c, &as, diff_default_options(DIFF_FLAGS_ALL)) {
					return
				}
			}
		}
	}
}

// -----------------------------------------------------------------------------
// 2. Branches (Jcc/JMP/CALL/RET/LEAVE), CMOVcc, SETcc, Addressing Modes, Strings
// -----------------------------------------------------------------------------

@(test)
diff_fuzz_branches_cmov_setcc_addressing_and_strings :: proc(t: ^testing.T) {
	arena, ok := diff_arena_create(t)
	if !ok {
		return
	}
	defer diff_arena_destroy(arena)

	prng := Diff_Prng{state = DIFF_PRNG_SEED ~ 0x5555_6666}

	// All 16 condition codes across all 32 combinations of (CF, PF, ZF, SF, OF).
	for cc in u8(0) ..< 16 {
		for flags_idx in u64(0) ..< 32 {
			s := diff_seed_state(arena, &prng)
			s.gprs[int(General_Register.Rbx)] = arena.va + DIFF_DATA_OFFSET + 32
			rflags := USER_INITIAL_RFLAGS
			if (flags_idx & 1) != 0 { rflags |= RFLAGS_CF }
			if (flags_idx & 2) != 0 { rflags |= RFLAGS_PF }
			if (flags_idx & 4) != 0 { rflags |= RFLAGS_ZF }
			if (flags_idx & 8) != 0 { rflags |= RFLAGS_SF }
			if (flags_idx & 16) != 0 { rflags |= RFLAGS_OF }
			s.rflags = rflags

			// CMOVcc 16/32/64-bit (including 32-bit zero-extension when NOT taken!).
			c_cmov16 := [?]u8{0x66, 0x0F, 0x40 + cc, 0xC2}
			c_cmov32 := [?]u8{0x0F, 0x40 + cc, 0xC2}
			c_cmov64 := [?]u8{0x48, 0x0F, 0x40 + cc, 0x03} // cmovcc rax, [rbx]
			c_setcc_r := [?]u8{0x0F, 0x90 + cc, 0xC0}      // setcc al
			c_setcc_m := [?]u8{0x0F, 0x90 + cc, 0x03}      // setcc [rbx]
			for c in ([][]u8{c_cmov16[:], c_cmov32[:], c_cmov64[:], c_setcc_r[:], c_setcc_m[:]}) {
				if !diff_check(t, arena, fmt.tprintf("cc_%x", cc), c, &s, diff_default_options(DIFF_FLAGS_ALL)) {
					return
				}
			}

			// Jcc rel8 and Jcc rel32 jumping to DIFF_TAKEN_PAD_OFFSET or falling through to DIFF_FALLTHROUGH_PAD_OFFSET.
			if (flags_idx & 3) == 0 {
				// Jcc rel8: if taken -> jump +5 (over jmp fallthrough) -> jmp taken.
				j8 := [12]u8{}
				e := Emit_Buf{code = j8[:], pos = 0}
				emit_b(&e, 0x70 + cc, 5) // jcc +5
				// Note: emit_jmp_rel32 computes relative to snippet start offset!
				rel_fall := i32(DIFF_FALLTHROUGH_PAD_OFFSET - (DIFF_SNIPPET_OFFSET + 7))
				emit_b(&e, 0xE9)
				emit_i32(&e, rel_fall)
				rel_taken := i32(DIFF_TAKEN_PAD_OFFSET - (DIFF_SNIPPET_OFFSET + 12))
				emit_b(&e, 0xE9)
				emit_i32(&e, rel_taken)
				if !diff_check(t, arena, fmt.tprintf("jcc8_%x", cc), j8[:], &s, diff_default_options(DIFF_FLAGS_ALL)) {
					return
				}

				// Jcc rel32 straight to DIFF_TAKEN_PAD_OFFSET, else fallthrough jmp.
				j32 := [11]u8{}
				e2 := Emit_Buf{code = j32[:], pos = 0}
				emit_b(&e2, 0x0F, 0x80 + cc)
				emit_i32(&e2, i32(DIFF_TAKEN_PAD_OFFSET - (DIFF_SNIPPET_OFFSET + 6)))
				emit_b(&e2, 0xE9)
				emit_i32(&e2, i32(DIFF_FALLTHROUGH_PAD_OFFSET - (DIFF_SNIPPET_OFFSET + 11)))
				if !diff_check(t, arena, fmt.tprintf("jcc32_%x", cc), j32[:], &s, diff_default_options(DIFF_FLAGS_ALL)) {
					return
				}
			}
		}
	}

	// Complex memory addressing modes, LEA, PUSH/POP/CALL/RET/LEAVE/PUSHF/POPF.
	{
		s := diff_seed_state(arena, &prng)
		s.gprs[int(General_Register.Rbx)] = arena.va + DIFF_DATA_OFFSET + 256
		s.gprs[int(General_Register.Rcx)] = 7
		s.gprs[int(General_Register.R12)] = arena.va + DIFF_DATA_OFFSET + 128
		s.gprs[int(General_Register.R13)] = arena.va + DIFF_DATA_OFFSET + 384
		s.gprs[int(General_Register.Rbp)] = arena.va + DIFF_INITIAL_STACK_OFFSET + 32

		for c in ([][]u8{
			{0x48, 0x8D, 0x44, 0xCB, 0x20},                   // lea rax, [rbx + rcx*8 + 0x20]
			{0x4C, 0x8D, 0x4C, 0x8B, 0xF0},                   // lea r9, [rbx + rcx*4 - 0x10]
			{0x48, 0x8D, 0x05, 0x10, 0x00, 0x00, 0x00},       // lea rax, [rip + 0x10]
			{0x49, 0x8B, 0x44, 0x24, 0x08},                   // mov rax, [r12 + 8] (SIB with REX.B)
			{0x49, 0x8B, 0x45, 0x00},                         // mov rax, [r13 + 0] (mod=1 r13)
			{0x48, 0x8B, 0x44, 0x8B, 0x10},                   // mov rax, [rbx + rcx*4 + 16]
			{0x50, 0x5A},                                     // push rax; pop rdx
			{0x6A, 0xFE, 0x58},                               // push -2; pop rax
			{0x68, 0x78, 0x56, 0x34, 0x12, 0x58},             // push 0x12345678; pop rax
			{0xFF, 0x33, 0x8F, 0x44, 0x24, 0x08},             // push qword [rbx]; pop qword [rsp+8]
			{0x9C, 0x9D},                                     // pushfq; popfq
			{0xC9},                                           // leave
			// call +5; jmp +3; add rax, 7; ret
			{0xE8, 0x02, 0x00, 0x00, 0x00, 0xEB, 0x05, 0x48, 0x83, 0xC0, 0x07, 0xC3},
			// call +2; jmp +6; ret 8 (with extra push)
			{0x50, 0xE8, 0x02, 0x00, 0x00, 0x00, 0xEB, 0x03, 0xC2, 0x08, 0x00},
		}) {
			if !diff_check(t, arena, "addr_stack_call", c, &s, diff_default_options(DIFF_FLAGS_ALL)) {
				return
			}
		}
	}

	// String operations: MOVSB/W/D/Q, REP MOVSB/W/D/Q, STOSB/W/D/Q, REP STOSB/W/D/Q (DF=0 and DF=1, RCX=0/1/19/65, overlap).
	for df in 0 ..< 2 {
		for rcx_val in ([?]u64{0, 1, 7, 19, 65}) {
			s := diff_seed_state(arena, &prng)
			if df == 1 {
				s.rflags |= RFLAGS_DF
			} else {
				s.rflags &~= RFLAGS_DF
			}
			s.gprs[int(General_Register.Rcx)] = rcx_val
			// Place RSI and RDI well inside data page (even for DF=1 with 65*8 = 520 bytes).
			s.gprs[int(General_Register.Rsi)] = arena.va + DIFF_DATA_OFFSET + 1024
			s.gprs[int(General_Register.Rdi)] = arena.va + DIFF_DATA_OFFSET + 2048

			for c in ([][]u8{
				{0xA4},             // movsb
				{0x66, 0xA5},       // movsw
				{0xA5},             // movsd
				{0x48, 0xA5},       // movsq
				{0xF3, 0xA4},       // rep movsb
				{0x66, 0xF3, 0xA5}, // rep movsw
				{0xF3, 0xA5},       // rep movsd
				{0xF3, 0x48, 0xA5}, // rep movsq
				{0xAA},             // stosb
				{0x66, 0xAB},       // stosw
				{0xAB},             // stosd
				{0x48, 0xAB},       // stosq
				{0xF3, 0xAA},       // rep stosb
				{0x66, 0xF3, 0xAB}, // rep stosw
				{0xF3, 0xAB},       // rep stosd
				{0xF3, 0x48, 0xAB}, // rep stosq
			}) {
				if !diff_check(t, arena, fmt.tprintf("string_df%d_c%d", df, rcx_val), c, &s, diff_default_options(DIFF_FLAGS_ALL)) {
					return
				}
			}

			// Overlapping forward rep movsb (dst = src + 3) to verify chunk-copy overlap rule!
			if df == 0 && rcx_val > 0 {
				os := s
				os.gprs[int(General_Register.Rdi)] = os.gprs[int(General_Register.Rsi)] + 3
				c_ov := [?]u8{0xF3, 0xA4}
				if !diff_check(t, arena, "rep_movsb_overlap", c_ov[:], &os, diff_default_options(DIFF_FLAGS_ALL)) {
					return
				}
			}
		}
	}
}

// -----------------------------------------------------------------------------
// 3. SSE / SSE2 Scalar and Vector Differential Fuzzing
// -----------------------------------------------------------------------------

@(private = "file")
EDGE_F32_BITS := [?]u32 {
	0x0000_0000, // +0.0
	0x8000_0000, // -0.0
	0x3F80_0000, // +1.0
	0xBF80_0000, // -1.0
	0x3F00_0000, // +0.5
	0x3FC0_0000, // +1.5
	0x4020_0000, // +2.5
	0xC020_0000, // -2.5
	0x4F00_0000, // 2^31 (out of i32 range)
	0xCF00_0000, // -2^31 (in i32 range)
	0x7F7F_FFFF, // FLT_MAX
	0x0000_0001, // smallest denormal
	0x7F80_0000, // +Inf
	0xFF80_0000, // -Inf
	0x7FC0_0123, // +qNaN with payload
	0xFFC0_0456, // -qNaN with payload
	0x7F80_0001, // +sNaN
}

@(private = "file")
EDGE_F64_BITS := [?]u64 {
	0x0000_0000_0000_0000, // +0.0
	0x8000_0000_0000_0000, // -0.0
	0x3FF0_0000_0000_0000, // +1.0
	0xBFF0_0000_0000_0000, // -1.0
	0x3FE0_0000_0000_0000, // +0.5
	0x3FF8_0000_0000_0000, // +1.5
	0x4004_0000_0000_0000, // +2.5
	0xC004_0000_0000_0000, // -2.5
	0x41DF_FFFF_FFC0_0000, // ~2^31 - 1
	0x41E0_0000_0000_0000, // 2^31
	0xC1E0_0000_0000_0000, // -2^31
	0x43E0_0000_0000_0000, // 2^63
	0xC3E0_0000_0000_0000, // -2^63
	0x7FEF_FFFF_FFFF_FFFF, // DBL_MAX
	0x0000_0000_0000_0001, // smallest denormal
	0x7FF0_0000_0000_0000, // +Inf
	0xFFF0_0000_0000_0000, // -Inf
	0x7FF8_0000_0000_0123, // +qNaN
	0xFFF8_0000_0000_0456, // -qNaN
	0x7FF0_0000_0000_0001, // +sNaN
}

@(test)
diff_fuzz_sse_sse2_integer_and_float :: proc(t: ^testing.T) {
	arena, ok := diff_arena_create(t)
	if !ok {
		return
	}
	defer diff_arena_destroy(arena)

	prng := Diff_Prng{state = DIFF_PRNG_SEED ~ 0x7777_8888}

	// All 66-map packed integer SSE2 binary ops (reg-reg and aligned mem).
	vec_int_ops := [?]u8 {
		0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x6D,
		0x74, 0x75, 0x76,
		0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD8, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF,
		0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE8, 0xE9, 0xEA, 0xEB, 0xEC, 0xED, 0xEE, 0xEF,
		0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE,
	}

	for op2 in vec_int_ops {
		for iter in 0 ..< 4 {
			s := diff_seed_state(arena, &prng)
			s.gprs[int(General_Register.Rbx)] = arena.va + DIFF_DATA_OFFSET + 64 // 16-byte aligned
			// For shift ops, test both small and large shift counts.
			if op2 == 0xD1 || op2 == 0xD2 || op2 == 0xD3 || op2 == 0xE1 || op2 == 0xE2 || op2 == 0xF1 || op2 == 0xF2 || op2 == 0xF3 {
				cnt := u64(iter * 17)
				zero := u64(0)
				mem.copy(&s.xmm[1][0], &cnt, 8)
				mem.copy(&s.xmm[1][8], &zero, 8)
				mem.copy(&s.data[64], &s.xmm[1][0], 16)
			}
			c_rr := [?]u8{0x66, 0x0F, op2, 0xC1} // op xmm0, xmm1
			c_rm := [?]u8{0x66, 0x0F, op2, 0x03} // op xmm0, [rbx]
			if !diff_check(t, arena, fmt.tprintf("sse_int_%02x_rr", op2), c_rr[:], &s, diff_default_options(DIFF_FLAGS_ALL)) {
				return
			}
			if !diff_check(t, arena, fmt.tprintf("sse_int_%02x_rm", op2), c_rm[:], &s, diff_default_options(DIFF_FLAGS_ALL)) {
				return
			}
		}
	}

	// Moves, shuffles, unpacks, immediate shifts, pinsrw/pextrw/pmovmskb/movmsk/maskmovdqu/stmxcsr/ldmxcsr.
	for _ in 0 ..< 8 {
		s := diff_seed_state(arena, &prng)
		s.gprs[int(General_Register.Rbx)] = arena.va + DIFF_DATA_OFFSET + 128 // 16-byte aligned
		s.gprs[int(General_Register.Rdi)] = arena.va + DIFF_DATA_OFFSET + 192
		imm := u8(prng_next(&prng))

		for c in ([][]u8{
			{0x0F, 0x10, 0x43, 0x03},       // movups xmm0, [rbx+3] (unaligned)
			{0x0F, 0x11, 0x43, 0x05},       // movups [rbx+5], xmm0
			{0x66, 0x0F, 0x10, 0x43, 0x07}, // movupd xmm0, [rbx+7]
			{0x66, 0x0F, 0x11, 0x43, 0x01}, // movupd [rbx+1], xmm0
			{0xF3, 0x0F, 0x10, 0xC1},       // movss xmm0, xmm1
			{0xF3, 0x0F, 0x10, 0x03},       // movss xmm0, [rbx]
			{0xF3, 0x0F, 0x11, 0x03},       // movss [rbx], xmm0
			{0xF2, 0x0F, 0x10, 0xC1},       // movsd xmm0, xmm1
			{0xF2, 0x0F, 0x10, 0x03},       // movsd xmm0, [rbx]
			{0xF2, 0x0F, 0x11, 0x03},       // movsd [rbx], xmm0
			{0x0F, 0x12, 0xC1},             // movhlps xmm0, xmm1
			{0x0F, 0x16, 0xC1},             // movlhps xmm0, xmm1
			{0x0F, 0x12, 0x03},             // movlps xmm0, [rbx]
			{0x0F, 0x13, 0x03},             // movlps [rbx], xmm0
			{0x0F, 0x16, 0x03},             // movhps xmm0, [rbx]
			{0x0F, 0x17, 0x03},             // movhps [rbx], xmm0
			{0x66, 0x0F, 0x12, 0x03},       // movlpd xmm0, [rbx]
			{0x66, 0x0F, 0x13, 0x03},       // movlpd [rbx], xmm0
			{0x66, 0x0F, 0x16, 0x03},       // movhpd xmm0, [rbx]
			{0x66, 0x0F, 0x17, 0x03},       // movhpd [rbx], xmm0
			{0x0F, 0x14, 0xC1},             // unpcklps xmm0, xmm1
			{0x0F, 0x15, 0xC1},             // unpckhps xmm0, xmm1
			{0x66, 0x0F, 0x14, 0xC1},       // unpcklpd xmm0, xmm1
			{0x66, 0x0F, 0x15, 0xC1},       // unpckhpd xmm0, xmm1
			{0x0F, 0x28, 0x03},             // movaps xmm0, [rbx]
			{0x0F, 0x29, 0x03},             // movaps [rbx], xmm0
			{0x66, 0x0F, 0x28, 0x03},       // movapd xmm0, [rbx]
			{0x66, 0x0F, 0x29, 0x03},       // movapd [rbx], xmm0
			{0x0F, 0x2B, 0x03},             // movntps [rbx], xmm0
			{0x66, 0x0F, 0x2B, 0x03},       // movntpd [rbx], xmm0
			{0x66, 0x0F, 0xE7, 0x03},       // movntdq [rbx], xmm0
			{0x0F, 0x50, 0xC1},             // movmskps eax, xmm1
			{0x66, 0x0F, 0x50, 0xC1},       // movmskpd eax, xmm1
			{0x0F, 0x54, 0xC1},             // andps xmm0, xmm1
			{0x0F, 0x55, 0xC1},             // andnps xmm0, xmm1
			{0x0F, 0x56, 0xC1},             // orps xmm0, xmm1
			{0x0F, 0x57, 0xC1},             // xorps xmm0, xmm1
			{0x66, 0x0F, 0x6E, 0xC0},       // movd xmm0, eax
			{0x66, 0x48, 0x0F, 0x6E, 0xC0}, // movq xmm0, rax
			{0x66, 0x0F, 0x7E, 0xC0},       // movd eax, xmm0
			{0x66, 0x48, 0x0F, 0x7E, 0xC0}, // movq rax, xmm0
			{0xF3, 0x0F, 0x7E, 0xC1},       // movq xmm0, xmm1
			{0x66, 0x0F, 0xD6, 0xC1},       // movq xmm1, xmm0
			{0x66, 0x0F, 0xD6, 0x03},       // movq [rbx], xmm0
			{0x66, 0x0F, 0x6F, 0x03},       // movdqa xmm0, [rbx]
			{0x66, 0x0F, 0x7F, 0x03},       // movdqa [rbx], xmm0
			{0xF3, 0x0F, 0x6F, 0x43, 0x03}, // movdqu xmm0, [rbx+3]
			{0xF3, 0x0F, 0x7F, 0x43, 0x05}, // movdqu [rbx+5], xmm0
			{0x66, 0x0F, 0x70, 0xC1, imm},  // pshufd xmm0, xmm1, imm
			{0xF3, 0x0F, 0x70, 0xC1, imm},  // pshufhw xmm0, xmm1, imm
			{0xF2, 0x0F, 0x70, 0xC1, imm},  // pshuflw xmm0, xmm1, imm
			{0x0F, 0xC6, 0xC1, imm},        // shufps xmm0, xmm1, imm
			{0x66, 0x0F, 0xC6, 0xC1, imm},  // shufpd xmm0, xmm1, imm
			{0x66, 0x0F, 0x71, 0xD0, imm & 31}, // psrlw xmm0, imm
			{0x66, 0x0F, 0x71, 0xE0, imm & 31}, // psraw xmm0, imm
			{0x66, 0x0F, 0x71, 0xF0, imm & 31}, // psllw xmm0, imm
			{0x66, 0x0F, 0x72, 0xD0, imm & 63}, // psrld xmm0, imm
			{0x66, 0x0F, 0x72, 0xE0, imm & 63}, // psrad xmm0, imm
			{0x66, 0x0F, 0x72, 0xF0, imm & 63}, // pslld xmm0, imm
			{0x66, 0x0F, 0x73, 0xD0, imm & 127}, // psrlq xmm0, imm
			{0x66, 0x0F, 0x73, 0xF0, imm & 127}, // psllq xmm0, imm
			{0x66, 0x0F, 0x73, 0xD8, imm & 31},  // psrldq xmm0, imm
			{0x66, 0x0F, 0x73, 0xF8, imm & 31},  // pslldq xmm0, imm
			{0x66, 0x0F, 0xC4, 0xC0, imm},  // pinsrw xmm0, eax, imm
			{0x66, 0x0F, 0xC5, 0xC1, imm},  // pextrw eax, xmm1, imm
			{0x66, 0x0F, 0xD7, 0xC1},       // pmovmskb eax, xmm1
			{0x66, 0x0F, 0xF7, 0xC1},       // maskmovdqu xmm0, xmm1
			{0x0F, 0xAE, 0x1B},             // stmxcsr [rbx]
			{0x0F, 0xAE, 0xE8},             // lfence
			{0x0F, 0xAE, 0xF0},             // mfence
			{0x0F, 0xAE, 0xF8},             // sfence
		}) {
			if !diff_check(t, arena, "sse_misc", c, &s, diff_default_options(DIFF_FLAGS_ALL)) {
				return
			}
		}
	}

	// Floating-point scalar & packed arithmetic, sqrt, min/max, cmp (all 8 predicates),
	// ucomis/comis, and conversions across edge float values (including NaNs, Infs, +/-0, denormals).
	for i in 0 ..< len(EDGE_F32_BITS) {
		j := (i * 5 + 3) % len(EDGE_F32_BITS)
		s := diff_seed_state(arena, &prng)
		s.gprs[int(General_Register.Rbx)] = arena.va + DIFF_DATA_OFFSET + 64
		// Populate xmm0 and xmm1 with edge f32 lanes, xmm2 and xmm3 with edge f64 lanes.
		f32_a := [4]u32{EDGE_F32_BITS[i], EDGE_F32_BITS[(i + 1) % len(EDGE_F32_BITS)], EDGE_F32_BITS[(i + 2) % len(EDGE_F32_BITS)], EDGE_F32_BITS[(i + 3) % len(EDGE_F32_BITS)]}
		f32_b := [4]u32{EDGE_F32_BITS[j], EDGE_F32_BITS[(j + 1) % len(EDGE_F32_BITS)], EDGE_F32_BITS[(j + 2) % len(EDGE_F32_BITS)], EDGE_F32_BITS[(j + 3) % len(EDGE_F32_BITS)]}
		f64_a := [2]u64{EDGE_F64_BITS[i % len(EDGE_F64_BITS)], EDGE_F64_BITS[(i + 1) % len(EDGE_F64_BITS)]}
		f64_b := [2]u64{EDGE_F64_BITS[(i * 7 + 2) % len(EDGE_F64_BITS)], EDGE_F64_BITS[(i * 7 + 3) % len(EDGE_F64_BITS)]}
		s.xmm[0] = transmute([16]u8)f32_a
		s.xmm[1] = transmute([16]u8)f32_b
		s.xmm[2] = transmute([16]u8)f64_a
		s.xmm[3] = transmute([16]u8)f64_b

		// Arithmetic: add, mul, sub, min, div, max, sqrt across ps, pd, ss, sd.
		for op2 in ([?]u8{0x58, 0x59, 0x5C, 0x5D, 0x5E, 0x5F, 0x51}) {
			c_ps := [?]u8{0x0F, op2, 0xC1}       // *ps xmm0, xmm1
			c_ss := [?]u8{0xF3, 0x0F, op2, 0xC1} // *ss xmm0, xmm1
			c_pd := [?]u8{0x66, 0x0F, op2, 0xD3} // *pd xmm2, xmm3
			c_sd := [?]u8{0xF2, 0x0F, op2, 0xD3} // *sd xmm2, xmm3
			for c in ([][]u8{c_ps[:], c_ss[:], c_pd[:], c_sd[:]}) {
				if !diff_check(t, arena, fmt.tprintf("fp_op_%02x_%d", op2, i), c, &s, diff_default_options(DIFF_FLAGS_ALL)) {
					return
				}
			}
		}

		// Comparisons: cmpps/cmpss/cmppd/cmpsd across all 8 predicates, plus ucomis/comis.
		for pred in u8(0) ..< 8 {
			c_cmpps := [?]u8{0x0F, 0xC2, 0xC1, pred}
			c_cmpss := [?]u8{0xF3, 0x0F, 0xC2, 0xC1, pred}
			c_cmppd := [?]u8{0x66, 0x0F, 0xC2, 0xD3, pred}
			c_cmpsd := [?]u8{0xF2, 0x0F, 0xC2, 0xD3, pred}
			for c in ([][]u8{c_cmpps[:], c_cmpss[:], c_cmppd[:], c_cmpsd[:]}) {
				if !diff_check(t, arena, fmt.tprintf("cmp_p%d_%d", pred, i), c, &s, diff_default_options(DIFF_FLAGS_ALL)) {
					return
				}
			}
		}
		for c in ([][]u8{
			{0x0F, 0x2E, 0xC1},       // ucomiss xmm0, xmm1
			{0x0F, 0x2F, 0xC1},       // comiss xmm0, xmm1
			{0x66, 0x0F, 0x2E, 0xD3}, // ucomisd xmm2, xmm3
			{0x66, 0x0F, 0x2F, 0xD3}, // comisd xmm2, xmm3
		}) {
			if !diff_check(t, arena, fmt.tprintf("ucomis_%d", i), c, &s, diff_default_options(DIFF_FLAGS_ALL)) {
				return
			}
		}

		// Conversions (across all 4 MXCSR rounding modes for rounding float->int).
		for rm in u32(0) ..< 4 {
			rs := s
			rs.mxcsr = MXCSR_START | (rm << MXCSR_ROUNDING_SHIFT)
			for c in ([][]u8{
				{0xF3, 0x0F, 0x2C, 0xC0},       // cvttss2si eax, xmm0
				{0xF3, 0x48, 0x0F, 0x2C, 0xC0}, // cvttss2si rax, xmm0
				{0xF3, 0x0F, 0x2D, 0xC0},       // cvtss2si eax, xmm0
				{0xF3, 0x48, 0x0F, 0x2D, 0xC0}, // cvtss2si rax, xmm0
				{0xF2, 0x0F, 0x2C, 0xC2},       // cvttsd2si eax, xmm2
				{0xF2, 0x48, 0x0F, 0x2C, 0xC2}, // cvttsd2si rax, xmm2
				{0xF2, 0x0F, 0x2D, 0xC2},       // cvtsd2si eax, xmm2
				{0xF2, 0x48, 0x0F, 0x2D, 0xC2}, // cvtsd2si rax, xmm2
				{0x66, 0x0F, 0x5B, 0xC8},       // cvtps2dq xmm1, xmm0
				{0xF3, 0x0F, 0x5B, 0xC8},       // cvttps2dq xmm1, xmm0
				{0xF2, 0x0F, 0xE6, 0xDA},       // cvtpd2dq xmm3, xmm2
				{0x66, 0x0F, 0xE6, 0xDA},       // cvttpd2dq xmm3, xmm2
			}) {
				if !diff_check(t, arena, fmt.tprintf("cvt_rm%d_%d", rm, i), c, &rs, diff_default_options(DIFF_FLAGS_ALL)) {
					return
				}
			}
		}

		// Integer -> float and float <-> float conversions (default round-to-nearest).
		for c in ([][]u8{
			{0xF3, 0x0F, 0x2A, 0xC0},       // cvtsi2ss xmm0, eax
			{0xF3, 0x48, 0x0F, 0x2A, 0xC0}, // cvtsi2ss xmm0, rax
			{0xF2, 0x0F, 0x2A, 0xD0},       // cvtsi2sd xmm2, eax
			{0xF2, 0x48, 0x0F, 0x2A, 0xD0}, // cvtsi2sd xmm2, rax
			{0xF3, 0x0F, 0x5A, 0xD0},       // cvtss2sd xmm2, xmm0
			{0xF2, 0x0F, 0x5A, 0xC2},       // cvtsd2ss xmm0, xmm2
			{0x0F, 0x5A, 0xD0},             // cvtps2pd xmm2, xmm0
			{0x66, 0x0F, 0x5A, 0xC2},       // cvtpd2ps xmm0, xmm2
			{0x0F, 0x5B, 0xC1},             // cvtdq2ps xmm0, xmm1
			{0xF3, 0x0F, 0xE6, 0xD0},       // cvtdq2pd xmm2, xmm0
		}) {
			if !diff_check(t, arena, fmt.tprintf("cvt_f_%d", i), c, &s, diff_default_options(DIFF_FLAGS_ALL)) {
				return
			}
		}
	}

	// RCPPS/RCPSS/RSQRTPS/RSQRTSS: verify within Intel SDM 1.5 * 2^-12 bound against hardware.
	{
		s := diff_seed_state(arena, &prng)
		vals := [4]f32{1.0, 2.0, 0.25, 16.0}
		s.xmm[1] = transmute([16]u8)vals
		for op2 in ([?]u8{0x52, 0x53}) {
			c := [?]u8{0x0F, op2, 0xC1}
			native := diff_run_native(arena, c[:], &s)
			sw, outcome, _ := diff_run_software(arena, c[:], &s, false)
			testing.expect_value(t, outcome, Step_Outcome.Breakpoint)
			nf := transmute([4]f32)native.xmm[0]
			sf := transmute([4]f32)sw.xmm[0]
			for lane in 0 ..< 4 {
				rel := math.abs(f64(nf[lane]) - f64(sf[lane])) / max(math.abs(f64(sf[lane])), 1e-30)
				testing.expectf(t, rel <= 1.5 / 4096.0, "rcp/rsqrt op=%02x lane=%d rel=%v (native=%v sw=%v)", op2, lane, rel, nf[lane], sf[lane])
			}
		}
	}
}

// -----------------------------------------------------------------------------
// 4. Randomized Multi-Instruction Differential Fuzz Sequences
// -----------------------------------------------------------------------------

@(test)
diff_fuzz_random_multi_instruction_sequences :: proc(t: ^testing.T) {
	arena, ok := diff_arena_create(t)
	if !ok {
		return
	}
	defer diff_arena_destroy(arena)

	prng := Diff_Prng{state = DIFF_PRNG_SEED ~ 0xAAAA_BBBB_CCCC_DDDD}

	// Plan value: 128 deterministic random sequences x 12 mixed instructions = 1,536
	// differential instructions covering GPR/memory/stack/SSE2 state transitions.
	SEQUENCE_COUNT :: 128
	INSNS_PER_SEQUENCE :: 12

	for seq in 0 ..< SEQUENCE_COUNT {
		s := diff_seed_state(arena, &prng)
		// Keep RBX and R12 anchored to aligned slots inside the data page so
		// generated memory operands never fault on unmapped addresses.
		s.gprs[int(General_Register.Rbx)] = arena.va + DIFF_DATA_OFFSET + 256
		s.gprs[int(General_Register.R12)] = arena.va + DIFF_DATA_OFFSET + 512

		code: [256]u8
		e := Emit_Buf{code = code[:], pos = 0}
		// Track which GPRs are safe to mutate (everything except RSP, RBX, R12).
		mutable_regs := [?]u8{0, 1, 2, 5, 6, 7, 8, 9, 10, 11, 13, 14, 15}

		for _ in 0 ..< INSNS_PER_SEQUENCE {
			dst := mutable_regs[prng_next(&prng) % u64(len(mutable_regs))]
			src := mutable_regs[prng_next(&prng) % u64(len(mutable_regs))]
			kind := prng_next(&prng) % 10
			rex := u8(0x48) | (u8(0x04) if src >= 8 else 0) | (u8(0x01) if dst >= 8 else 0)
			modrm_rr := u8(0xC0) | ((src & 7) << 3) | (dst & 7)

			switch kind {
			case 0: // ADD/SUB/ADC/SBB r64, r64
				ops := [?]u8{0x01, 0x11, 0x19, 0x29}
				emit_b(&e, rex, ops[prng_next(&prng) % 4], modrm_rr)
			case 1: // AND/OR/XOR r32, r32 (tests zero-extension)
				ops := [?]u8{0x09, 0x21, 0x31}
				r32 := u8(0x40) | (u8(0x04) if src >= 8 else 0) | (u8(0x01) if dst >= 8 else 0)
				emit_b(&e, r32, ops[prng_next(&prng) % 3], modrm_rr)
			case 2: // LEA r64, [rbx + disp8]
				r_lea := u8(0x48) | (u8(0x04) if dst >= 8 else 0)
				disp := u8(prng_next(&prng) & 0x7F)
				emit_b(&e, r_lea, 0x8D, 0x43 | ((dst & 7) << 3), disp)
			case 3: // Store + load memory roundtrip on [rbx + aligned disp8]
				off := u8((prng_next(&prng) & 0xF) * 8)
				r_mem := u8(0x48) | (u8(0x04) if src >= 8 else 0)
				emit_b(&e, r_mem, 0x89, 0x43 | ((src & 7) << 3), off)
				r_ld := u8(0x48) | (u8(0x04) if dst >= 8 else 0)
				emit_b(&e, r_ld, 0x8B, 0x43 | ((dst & 7) << 3), off)
			case 4: // Shift by 1 (SHL/SHR/SAR/ROL/ROR)
				subs := [?]u8{0, 1, 4, 5, 7}
				sub := subs[prng_next(&prng) % 5]
				r_sh := u8(0x48) | (u8(0x01) if dst >= 8 else 0)
				emit_b(&e, r_sh, 0xD1, 0xC0 | (sub << 3) | (dst & 7))
			case 5: // CMP + CMOVcc r64, r64
				emit_b(&e, rex, 0x39, modrm_rr)
				cc := u8(prng_next(&prng) & 0xF)
				r_cm := u8(0x48) | (u8(0x04) if dst >= 8 else 0) | (u8(0x01) if src >= 8 else 0)
				emit_b(&e, r_cm, 0x0F, 0x40 + cc, 0xC0 | ((dst & 7) << 3) | (src & 7))
			case 6: // PUSH src; POP dst
				if src >= 8 { emit_b(&e, 0x41) }
				emit_b(&e, 0x50 + (src & 7))
				if dst >= 8 { emit_b(&e, 0x41) }
				emit_b(&e, 0x58 + (dst & 7))
			case 7: // IMUL r64, r64, imm8
				r_im := u8(0x48) | (u8(0x04) if dst >= 8 else 0) | (u8(0x01) if src >= 8 else 0)
				emit_b(&e, r_im, 0x6B, 0xC0 | ((dst & 7) << 3) | (src & 7), u8(prng_next(&prng)))
			case 8: // SSE2 packed integer op + movdqu store to [r12 + disp8]
				x_dst := u8(prng_next(&prng) & 7)
				x_src := u8(prng_next(&prng) & 7)
				s_ops := [?]u8{0xFC, 0xFD, 0xFE, 0xD4, 0xEF, 0xEB, 0xDB, 0x74}
				emit_b(&e, 0x66, 0x0F, s_ops[prng_next(&prng) % 8], 0xC0 | (x_dst << 3) | x_src)
				off := u8((prng_next(&prng) & 7) * 16)
				emit_b(&e, 0xF3, 0x41, 0x0F, 0x7F, 0x44 | (x_dst << 3), 0x24, off)
			case 9: // MOVZX / MOVSX + BSWAP + NEG
				r_zx := u8(0x48) | (u8(0x04) if dst >= 8 else 0) | (u8(0x01) if src >= 8 else 0)
				emit_b(&e, r_zx, 0x0F, 0xB6, 0xC0 | ((dst & 7) << 3) | (src & 7))
				r_bs := u8(0x48) | (u8(0x01) if dst >= 8 else 0)
				emit_b(&e, r_bs, 0x0F, 0xC8 + (dst & 7))
			}
		}

		// End every random sequence with a canonical flag-defining ADD so final
		// RFLAGS are 100% architecturally defined even if an earlier instruction
		// left AF/OF undefined.
		emit_b(&e, 0x48, 0x01, 0xD0) // add rax, rdx

		if !diff_check(t, arena, fmt.tprintf("rand_seq_%d", seq), code[:e.pos], &s, diff_default_options(DIFF_FLAGS_ALL)) {
			return
		}
	}
}

@(test)
instruction_probe_refuses_invalid_and_truncated_forms :: proc(t: ^testing.T) {
	// Empty slice -> Truncated.
	testing.expect_value(t, instruction_probe(nil).status, Instruction_Probe_Status.Truncated)
	// Truncated 2-byte escape.
	testing.expect_value(t, instruction_probe([]u8{0x0F}).status, Instruction_Probe_Status.Truncated)
	// Truncated ModRM displacement.
	testing.expect_value(t, instruction_probe([]u8{0x48, 0x8B, 0x45}).status, Instruction_Probe_Status.Truncated)
	// Overlong 16-byte instruction (15 prefixes + NOP).
	overlong := [16]u8{0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x90}
	testing.expect_value(t, instruction_probe(overlong[:]).status, Instruction_Probe_Status.Exceeds_Max_Length)
	// Privileged HLT -> Unsupported.
	testing.expect_value(t, instruction_probe([]u8{0xF4}).status, Instruction_Probe_Status.Unsupported_Opcode)
	// LEA with register ModRM -> Invalid_Modrm_Form.
	testing.expect_value(t, instruction_probe([]u8{0x48, 0x8D, 0xC0}).status, Instruction_Probe_Status.Invalid_Modrm_Form)
	// x87 / AVX (VEX) -> Unsupported_Opcode.
	testing.expect_value(t, instruction_probe([]u8{0xD9, 0xE8}).status, Instruction_Probe_Status.Unsupported_Opcode)
	testing.expect_value(t, instruction_probe([]u8{0xC5, 0xF8, 0x77}).status, Instruction_Probe_Status.Unsupported_Opcode)
	// Valid instructions return exact byte length.
	p1 := instruction_probe([]u8{0x48, 0x8D, 0x44, 0xCB, 0x20})
	testing.expect_value(t, p1.status, Instruction_Probe_Status.Supported)
	testing.expect_value(t, p1.length, 5)
	p2 := instruction_probe([]u8{0xF3, 0x0F, 0x7F, 0x43, 0x05})
	testing.expect_value(t, p2.status, Instruction_Probe_Status.Supported)
	testing.expect_value(t, p2.length, 5)
}
