#+build !freestanding
package browser_vm_runtime

import "core:testing"

@(private = "file")
decode_uleb128_u64_test :: proc(data: []u8) -> (value: u64, consumed: int, ok: bool) {
	shift := u32(0)
	for i in 0 ..< len(data) {
		if i >= WASM_LEB128_MAX_U64_BYTES {
			return 0, 0, false
		}
		b := data[i]
		value |= u64(b & 0x7F) << shift
		if (b & 0x80) == 0 {
			return value, i + 1, true
		}
		shift += 7
	}
	return 0, 0, false
}

@(private = "file")
decode_sleb128_i64_test :: proc(data: []u8) -> (value: i64, consumed: int, ok: bool) {
	shift := u32(0)
	bits := u64(0)
	for i in 0 ..< len(data) {
		if i >= WASM_LEB128_MAX_I64_BYTES {
			return 0, 0, false
		}
		b := data[i]
		bits |= u64(b & 0x7F) << shift
		shift += 7
		if (b & 0x80) == 0 {
			if shift < 64 && (b & 0x40) != 0 {
				bits |= ~u64(0) << shift
			}
			return transmute(i64)bits, i + 1, true
		}
	}
	return 0, 0, false
}

@(test)
wasm_tier_enum_borders_refuse_unknown_words :: proc(t: ^testing.T) {
	_, ok_ref := wasm_tier_refusal_of_word(999)
	testing.expect(t, !ok_ref)
	r, ok_r := wasm_tier_refusal_of_word(u64(Wasm_Tier_Refusal.Buffer_Too_Small))
	testing.expect(t, ok_r && r == .Buffer_Too_Small)

	_, ok_lim0 := wasm_memory_limits_kind_of_word(0)
	testing.expect(t, !ok_lim0)
	_, ok_lim3 := wasm_memory_limits_kind_of_word(3)
	testing.expect(t, !ok_lim3)
	lim, ok_lim := wasm_memory_limits_kind_of_word(u64(Wasm_Memory_Limits_Kind.Shared_Min_Max))
	testing.expect(t, ok_lim && lim == .Shared_Min_Max)

	_, ok_op0 := wasm_block_op_kind_of_word(0)
	testing.expect(t, !ok_op0)
	_, ok_op99 := wasm_block_op_kind_of_word(99)
	testing.expect(t, !ok_op99)
	op, ok_op := wasm_block_op_kind_of_word(u64(Wasm_Block_Op_Kind.Exit_If_Equal_Reg))
	testing.expect(t, ok_op && op == .Exit_If_Equal_Reg)

	_, ok_st := hot_block_state_of_word(5)
	testing.expect(t, !ok_st)
	st, ok_st2 := hot_block_state_of_word(u64(Hot_Block_State.Compile_Queued))
	testing.expect(t, ok_st2 && st == .Compile_Queued)
}

@(test)
wasm_tier_leb128_edge_values_and_short_buffer_refusal :: proc(t: ^testing.T) {
	u32_edges := [?]u32{0, 1, 127, 128, 16383, 16384, max(u32)}
	for v in u32_edges {
		buf: [WASM_LEB128_MAX_U32_BYTES]u8
		n, ref := wasm_encode_uleb128_u32(v, buf[:])
		testing.expect(t, ref == .None && n >= 1 && n <= WASM_LEB128_MAX_U32_BYTES)
		decoded, used, ok := decode_uleb128_u64_test(buf[:n])
		testing.expect(t, ok && used == n && decoded == u64(v))

		// One byte short must refuse without touching the output slice.
		short: [WASM_LEB128_MAX_U32_BYTES]u8
		for &b in short {
			b = 0xAA
		}
		sn, sref := wasm_encode_uleb128_u32(v, short[:n - 1])
		testing.expect(t, sn == 0 && sref == .Buffer_Too_Small)
		for b in short {
			testing.expect(t, b == 0xAA)
		}
	}

	u64_edges := [?]u64{0, 1, 127, 128, max(u32), u64(max(u32)) + 1, max(u64)}
	for v in u64_edges {
		buf: [WASM_LEB128_MAX_U64_BYTES]u8
		n, ref := wasm_encode_uleb128_u64(v, buf[:])
		testing.expect(t, ref == .None && n >= 1 && n <= WASM_LEB128_MAX_U64_BYTES)
		decoded, used, ok := decode_uleb128_u64_test(buf[:n])
		testing.expect(t, ok && used == n && decoded == v)
	}

	i32_edges := [?]i32{0, 1, -1, 63, 64, -64, -65, 127, 128, -128, -129, min(i32), max(i32)}
	for v in i32_edges {
		buf: [WASM_LEB128_MAX_I32_BYTES]u8
		n, ref := wasm_encode_sleb128_i32(v, buf[:])
		testing.expect(t, ref == .None && n >= 1 && n <= WASM_LEB128_MAX_I32_BYTES)
		decoded, used, ok := decode_sleb128_i64_test(buf[:n])
		testing.expect(t, ok && used == n && decoded == i64(v))
	}

	i64_edges := [?]i64{0, 1, -1, 63, 64, -64, -65, 127, 128, -128, -129, min(i32), max(i32), min(i64), max(i64)}
	for v in i64_edges {
		buf: [WASM_LEB128_MAX_I64_BYTES]u8
		n, ref := wasm_encode_sleb128_i64(v, buf[:])
		testing.expect(t, ref == .None && n >= 1 && n <= WASM_LEB128_MAX_I64_BYTES)
		decoded, used, ok := decode_sleb128_i64_test(buf[:n])
		testing.expect(t, ok && used == n && decoded == v)

		// One byte short must refuse without writing any byte.
		short: [WASM_LEB128_MAX_I64_BYTES]u8
		for &b in short {
			b = 0x55
		}
		sn, sref := wasm_encode_sleb128_i64(v, short[:n - 1])
		testing.expect(t, sn == 0 && sref == .Buffer_Too_Small)
		for b in short {
			testing.expect(t, b == 0x55)
		}
	}
}

@(test)
wasm_tier_compile_refusals_leave_output_untouched :: proc(t: ^testing.T) {
	valid_mem := Wasm_Memory_Import{limits_kind = .Unshared_Min_Only, min_pages = 16}
	out: [512]u8
	for &b in out {
		b = 0xCC
	}

	// Empty block refused.
	n, ref := wasm_compile_block({start_physical = 0x1000, memory = valid_mem, ops = nil}, out[:])
	testing.expect(t, n == 0 && ref == .Empty_Block)

	// Too many ops (WASM_TIER_MAX_BLOCK_OPS + 1) refused.
	too_many: [WASM_TIER_MAX_BLOCK_OPS + 1]Wasm_Block_Op
	for &op in too_many {
		op = {kind = .Mov_Imm64, dst = 0, imm = 1}
	}
	n, ref = wasm_compile_block({start_physical = 0x1000, memory = valid_mem, ops = too_many[:]}, out[:])
	testing.expect(t, n == 0 && ref == .Too_Many_Ops)

	// Unknown forged op kind refused.
	bad_op := [1]Wasm_Block_Op{{kind = Wasm_Block_Op_Kind(200), dst = 0}}
	n, ref = wasm_compile_block({start_physical = 0x1000, memory = valid_mem, ops = bad_op[:]}, out[:])
	testing.expect(t, n == 0 && ref == .Unknown_Op_Kind)

	// Out-of-range register (16) refused.
	bad_reg := [1]Wasm_Block_Op{{kind = .Add_Reg64, dst = 16, src = 0}}
	n, ref = wasm_compile_block({start_physical = 0x1000, memory = valid_mem, ops = bad_reg[:]}, out[:])
	testing.expect(t, n == 0 && ref == .Register_Out_Of_Range)

	// Unused field non-zero refused.
	dirty_op := [1]Wasm_Block_Op{{kind = .Mov_Imm64, dst = 1, src = 2, imm = 7}}
	n, ref = wasm_compile_block({start_physical = 0x1000, memory = valid_mem, ops = dirty_op[:]}, out[:])
	testing.expect(t, n == 0 && ref == .Unused_Field_Non_Zero)

	// Conditional exit status <= 0 refused.
	bad_exit := [1]Wasm_Block_Op{{kind = .Exit_If_Zero, src = 0, exit_status = 0}}
	n, ref = wasm_compile_block({start_physical = 0x1000, memory = valid_mem, ops = bad_exit[:]}, out[:])
	testing.expect(t, n == 0 && ref == .Invalid_Exit_Status)

	bad_exit_neg := [1]Wasm_Block_Op{{kind = .Exit_If_Not_Zero, src = 0, exit_status = -1}}
	n, ref = wasm_compile_block({start_physical = 0x1000, memory = valid_mem, ops = bad_exit_neg[:]}, out[:])
	testing.expect(t, n == 0 && ref == .Invalid_Exit_Status)

	// Invalid memory configs refused (zero min pages, > 65536, shared with max < min, unshared with non-zero max).
	one_op := [1]Wasm_Block_Op{{kind = .Mov_Imm64, dst = 0, imm = 42}}
	bad_mems := [?]Wasm_Memory_Import{
		{limits_kind = Wasm_Memory_Limits_Kind(0), min_pages = 1},
		{limits_kind = .Unshared_Min_Only, min_pages = 0},
		{limits_kind = .Unshared_Min_Only, min_pages = WASM_MAX_MEMORY_PAGES + 1},
		{limits_kind = .Unshared_Min_Only, min_pages = 4, max_pages = 8},
		{limits_kind = .Shared_Min_Max, min_pages = 16, max_pages = 8},
		{limits_kind = .Shared_Min_Max, min_pages = 16, max_pages = WASM_MAX_MEMORY_PAGES + 1},
	}
	for bm in bad_mems {
		n, ref = wasm_compile_block({start_physical = 0x1000, memory = bm, ops = one_op[:]}, out[:])
		testing.expect(t, n == 0 && ref == .Invalid_Memory_Config)
	}

	// Verify none of the refusals modified a single byte of `out`.
	for b in out {
		testing.expect(t, b == 0xCC)
	}
}

@(test)
wasm_tier_compile_full_block_valid_header_sections_and_exact_bound :: proc(t: ^testing.T) {
	ops := [?]Wasm_Block_Op{
		{kind = .Mov_Imm64, dst = 0, imm = -1234567890123},
		{kind = .Mov_Reg64, dst = 1, src = 0},
		{kind = .Add_Imm64, dst = 1, imm = 128},
		{kind = .Add_Reg64, dst = 0, src = 1},
		{kind = .Sub_Reg64, dst = 2, src = 0},
		{kind = .And_Reg64, dst = 2, src = 1},
		{kind = .Or_Reg64, dst = 3, src = 2},
		{kind = .Xor_Reg64, dst = 3, src = 1},
		{kind = .Load_Guest_U64, dst = 4, src = 5, guest_offset = 64},
		{kind = .Store_Guest_U64, dst = 5, src = 4, guest_offset = 72},
		{kind = .Exit_If_Zero, src = 4, exit_status = 1},
		{kind = .Exit_If_Not_Zero, src = 3, exit_status = 2},
		{kind = .Exit_If_Equal_Reg, dst = 0, src = 1, exit_status = 3},
	}
	spec := Wasm_Block_Spec{
		start_physical = 0x20_0000,
		memory         = {limits_kind = .Shared_Min_Max, min_pages = 256, max_pages = 8192},
		ops            = ops[:],
	}

	out: [1024]u8
	written, ref := wasm_compile_block(spec, out[:])
	testing.expect(t, ref == .None && written > 8)

	// Verify exact Wasm magic and version bytes.
	expected_header := WASM_BINARY_HEADER
	for i in 0 ..< len(expected_header) {
		testing.expect(t, out[i] == expected_header[i])
	}

	// Verify structural validity of emitted binary.
	testing.expect(t, wasm_module_verify_structure(out[:written]) == .None)

	// One byte shorter must refuse `.Buffer_Too_Small` with zero mutation.
	short: [1024]u8
	for &b in short {
		b = 0x77
	}
	sn, sref := wasm_compile_block(spec, short[:written - 1])
	testing.expect(t, sn == 0 && sref == .Buffer_Too_Small)
	for b in short {
		testing.expect(t, b == 0x77)
	}

	// Truncating or corrupting the emitted binary must fail structural verification.
	testing.expect(t, wasm_module_verify_structure(out[:written - 1]) == .Malformed_Wasm_Module)
	corrupt := out
	corrupt[0] = 0xFF
	testing.expect(t, wasm_module_verify_structure(corrupt[:written]) == .Malformed_Wasm_Module)
}

@(test)
wasm_tier_hot_block_threshold_and_state_transitions :: proc(t: ^testing.T) {
	// Nil pointer and invalid byte counts refused.
	_, _, nil_ref := wasm_tier_record_execution(nil, 0x1000, 16)
	testing.expect(t, nil_ref == .Nil_Pointer)

	tracker: Wasm_Tier_Tracker
	_, _, zero_ref := wasm_tier_record_execution(&tracker, 0x1000, 0)
	testing.expect(t, zero_ref == .Invalid_Block_Size)
	_, _, over_ref := wasm_tier_record_execution(&tracker, 0x1000, WASM_TIER_MAX_BLOCK_BYTES + 1)
	testing.expect(t, over_ref == .Invalid_Block_Size)
	testing.expect(t, tracker.total_executions == 0)

	// First HOT_BLOCK_COMPILE_THRESHOLD - 1 executions stay interpreted.
	for i in u64(1) ..< HOT_BLOCK_COMPILE_THRESHOLD {
		should_compile, hits, ref := wasm_tier_record_execution(&tracker, 0x4000, 24)
		testing.expect(t, ref == .None && !should_compile && hits == i)
	}

	// Hitting exact threshold queues compile exactly once.
	should_compile, hits, ref := wasm_tier_record_execution(&tracker, 0x4000, 24)
	testing.expect(t, ref == .None && should_compile && hits == HOT_BLOCK_COMPILE_THRESHOLD)
	testing.expect(t, tracker.queued_compiles == 1)

	// Subsequent hit while queued must not re-queue.
	should_compile2, hits2, ref2 := wasm_tier_record_execution(&tracker, 0x4000, 24)
	testing.expect(t, ref2 == .None && !should_compile2 && hits2 == HOT_BLOCK_COMPILE_THRESHOLD + 1)

	// Zero compiled byte count refused without state change.
	testing.expect(t, wasm_tier_mark_compiled(&tracker, 0x4000, 0) == .Invalid_Block_Size)
	// Wrong physical address refused.
	testing.expect(t, wasm_tier_mark_compiled(&tracker, 0x5000, 96) == .Invalid_State_Transition)
	// Valid transition to compiled succeeds once; second call refused.
	testing.expect(t, wasm_tier_mark_compiled(&tracker, 0x4000, 96) == .None)
	testing.expect(t, tracker.completed_compiles == 1)
	testing.expect(t, wasm_tier_mark_compiled(&tracker, 0x4000, 96) == .Invalid_State_Transition)
	testing.expect(t, wasm_tier_mark_refused(&tracker, 0x4000) == .Invalid_State_Transition)

	// Invalidation resets the slot so it starts fresh.
	wasm_tier_invalidate(&tracker, 0x4000)
	sc_after, hits_after, ref_after := wasm_tier_record_execution(&tracker, 0x4000, 24)
	testing.expect(t, ref_after == .None && !sc_after && hits_after == 1)

	// Refusal path transitions queued -> refused and never re-queues.
	for _ in u64(2) ..< HOT_BLOCK_COMPILE_THRESHOLD {
		_, _, _ = wasm_tier_record_execution(&tracker, 0x4000, 24)
	}
	sc_q, _, _ := wasm_tier_record_execution(&tracker, 0x4000, 24)
	testing.expect(t, sc_q)
	testing.expect(t, wasm_tier_mark_refused(&tracker, 0x4000) == .None)
	testing.expect(t, tracker.refused_compiles == 1)
	sc_post_ref, _, _ := wasm_tier_record_execution(&tracker, 0x4000, 24)
	testing.expect(t, !sc_post_ref)
}
