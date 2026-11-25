// Compiled WebAssembly tier for hot decoded x86-64 guest basic blocks
// (src/md/features/browser_machine.md, "The compiled tier").
//
// Encodes a validated sequence of decoded x86-64 register ALU, immediate move,
// guest linear-memory load/store, and conditional exit operations into a
// self-contained WebAssembly 1.0 binary module without heap allocation.
//
// Calling convention of the exported `run_block` function:
//   (param $regs_base i32)       -- byte offset of the 16 x86-64 GPRs ([16]u64)
//   (param $guest_mem_base i32)  -- byte offset of guest linear memory base
//   (result i32)                 -- 0 on normal fallthrough, >0 on conditional exit
//
// Two-pass emission measures exact section lengths before writing into `out`,
// so any refusal leaves `out` untouched.
package browser_vm_runtime

import "modus:contract/enum_word"

// Format property: WebAssembly 1.0 binary magic ("\0asm") and version 1 header.
WASM_BINARY_HEADER :: [8]u8{0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00}

// Format property: WebAssembly 32-bit linear memory addresses at most 4 GiB in
// 64 KiB pages (65536 pages).
WASM_MAX_MEMORY_PAGES :: u32(65536)

// Format property: x86-64 has 16 architectural general-purpose registers (RAX..R15).
WASM_GUEST_REGISTER_COUNT :: u8(16)

// Format property: LEB128 encodes 7 bits per byte, so 32-bit values take at
// most 5 bytes and 64-bit values take at most 10 bytes.
WASM_LEB128_MAX_U32_BYTES :: 5
WASM_LEB128_MAX_I32_BYTES :: 5
WASM_LEB128_MAX_U64_BYTES :: 10
WASM_LEB128_MAX_I64_BYTES :: 10

// Plan value: a decoded block runs 64 times in the interpreter before queueing
// for WebAssembly compilation so cold startup blocks avoid compile overhead.
HOT_BLOCK_COMPILE_THRESHOLD :: u64(64)

// Plan value: matches software_machine.BLOCK_INSTRUCTION_CAPACITY so one
// decoded basic block maps directly into one compiled tier block.
WASM_TIER_MAX_BLOCK_OPS :: 16

// Plan value: matches software_machine.BLOCK_BYTE_CAPACITY (128 bytes per block).
WASM_TIER_MAX_BLOCK_BYTES :: u8(128)

// Plan value: direct-mapped hot-block table sized to match the decoded block
// cache power-of-two indexing (256 slots fit in a small freestanding table).
WASM_TIER_TRACKER_SLOTS :: 256
WASM_TIER_TRACKER_SLOT_BITS :: 8
#assert(1 << WASM_TIER_TRACKER_SLOT_BITS == WASM_TIER_TRACKER_SLOTS)

// Normal fallthrough return value of a compiled block (`run_block` result).
WASM_EXIT_FALLTHROUGH :: i32(0)

// Format property: WebAssembly 1.0 section identifiers in canonical wire order.
@(private = "file")
WASM_SECTION_TYPE :: u8(1)
@(private = "file")
WASM_SECTION_IMPORT :: u8(2)
@(private = "file")
WASM_SECTION_FUNCTION :: u8(3)
@(private = "file")
WASM_SECTION_EXPORT :: u8(7)
@(private = "file")
WASM_SECTION_CODE :: u8(10)

// Format property: WebAssembly 1.0 value types, descriptor tags, and opcodes.
@(private = "file")
WASM_TYPE_FUNC :: u8(0x60)
@(private = "file")
WASM_VALTYPE_I32 :: u8(0x7F)
@(private = "file")
WASM_BLOCKTYPE_EMPTY :: u8(0x40)
@(private = "file")
WASM_DESC_FUNC :: u8(0x00)
@(private = "file")
WASM_DESC_MEMORY :: u8(0x02)
@(private = "file")
WASM_LIMITS_MIN_ONLY :: u8(0x00)
@(private = "file")
WASM_LIMITS_SHARED_MIN_MAX :: u8(0x03)

@(private = "file")
WASM_OP_IF :: u8(0x04)
@(private = "file")
WASM_OP_END :: u8(0x0B)
@(private = "file")
WASM_OP_RETURN :: u8(0x0F)
@(private = "file")
WASM_OP_LOCAL_GET :: u8(0x20)
@(private = "file")
WASM_OP_I64_LOAD :: u8(0x29)
@(private = "file")
WASM_OP_I64_STORE :: u8(0x37)
@(private = "file")
WASM_OP_I32_CONST :: u8(0x41)
@(private = "file")
WASM_OP_I64_CONST :: u8(0x42)
@(private = "file")
WASM_OP_I64_EQZ :: u8(0x50)
@(private = "file")
WASM_OP_I64_EQ :: u8(0x51)
@(private = "file")
WASM_OP_I64_NE :: u8(0x52)
@(private = "file")
WASM_OP_I32_ADD :: u8(0x6A)
@(private = "file")
WASM_OP_I64_ADD :: u8(0x7C)
@(private = "file")
WASM_OP_I64_SUB :: u8(0x7D)
@(private = "file")
WASM_OP_I64_AND :: u8(0x83)
@(private = "file")
WASM_OP_I64_OR :: u8(0x84)
@(private = "file")
WASM_OP_I64_XOR :: u8(0x85)
@(private = "file")
WASM_OP_I32_WRAP_I64 :: u8(0xA7)

// Closed set of refusals returned by the compiled WebAssembly tier.
Wasm_Tier_Refusal :: enum u8 {
	None                     = 0,
	Nil_Pointer              = 1,
	Empty_Block              = 2,
	Too_Many_Ops             = 3,
	Unknown_Op_Kind          = 4,
	Register_Out_Of_Range    = 5,
	Unused_Field_Non_Zero    = 6,
	Invalid_Memory_Config    = 7,
	Invalid_Exit_Status      = 8,
	Buffer_Too_Small         = 9,
	Invalid_Block_Size       = 10,
	Invalid_State_Transition = 11,
	Malformed_Wasm_Module    = 12,
}

wasm_tier_refusal_of_word :: proc "contextless" (word: u64) -> (refusal: Wasm_Tier_Refusal, ok: bool) {
	return enum_word.member_of_word(Wasm_Tier_Refusal, word)
}

// Memory import limits form for the compiled block module.
Wasm_Memory_Limits_Kind :: enum u8 {
	Unshared_Min_Only = 1, // Single-worker fallback without SharedArrayBuffer.
	Shared_Min_Max    = 2, // Cross-origin isolated shared memory across workers.
}

wasm_memory_limits_kind_of_word :: proc "contextless" (word: u64) -> (kind: Wasm_Memory_Limits_Kind, ok: bool) {
	return enum_word.member_of_word(Wasm_Memory_Limits_Kind, word)
}

// Closed set of decoded x86-64 block operations lowered to WebAssembly.
Wasm_Block_Op_Kind :: enum u8 {
	Mov_Imm64         = 1,  // reg[dst] = imm
	Mov_Reg64         = 2,  // reg[dst] = reg[src]
	Add_Reg64         = 3,  // reg[dst] = reg[dst] + reg[src]
	Sub_Reg64         = 4,  // reg[dst] = reg[dst] - reg[src]
	And_Reg64         = 5,  // reg[dst] = reg[dst] & reg[src]
	Or_Reg64          = 6,  // reg[dst] = reg[dst] | reg[src]
	Xor_Reg64         = 7,  // reg[dst] = reg[dst] ^ reg[src]
	Add_Imm64         = 8,  // reg[dst] = reg[dst] + imm
	Load_Guest_U64    = 9,  // reg[dst] = mem64[guest_base + u32(reg[src]) + guest_offset]
	Store_Guest_U64   = 10, // mem64[guest_base + u32(reg[dst]) + guest_offset] = reg[src]
	Exit_If_Zero      = 11, // if reg[src] == 0 { return exit_status }
	Exit_If_Not_Zero  = 12, // if reg[src] != 0 { return exit_status }
	Exit_If_Equal_Reg = 13, // if reg[dst] == reg[src] { return exit_status }
}

wasm_block_op_kind_of_word :: proc "contextless" (word: u64) -> (kind: Wasm_Block_Op_Kind, ok: bool) {
	return enum_word.member_of_word(Wasm_Block_Op_Kind, word)
}

// One decoded x86-64 basic-block operation to lower into WebAssembly.
Wasm_Block_Op :: struct {
	kind:         Wasm_Block_Op_Kind,
	dst:          u8,
	src:          u8,
	guest_offset: u32,
	imm:          i64,
	exit_status:  i32,
}

// Memory import descriptor for the emitted WebAssembly module.
Wasm_Memory_Import :: struct {
	limits_kind: Wasm_Memory_Limits_Kind,
	min_pages:   u32,
	max_pages:   u32, // Required when limits_kind == .Shared_Min_Max; must be 0 when .Unshared_Min_Only.
}

// Input specification for compiling one hot x86-64 basic block.
Wasm_Block_Spec :: struct {
	start_physical: u64,
	memory:         Wasm_Memory_Import,
	ops:            []Wasm_Block_Op,
}

// Compilation lifecycle state of one tracked basic-block slot.
Hot_Block_State :: enum u8 {
	Empty          = 0,
	Interpreted    = 1,
	Compile_Queued = 2,
	Compiled       = 3,
	Refused        = 4,
}

hot_block_state_of_word :: proc "contextless" (word: u64) -> (state: Hot_Block_State, ok: bool) {
	return enum_word.member_of_word(Hot_Block_State, word)
}

// One tracked hot-block entry keyed by guest physical address.
Hot_Block_Slot :: struct {
	state:               Hot_Block_State,
	start_physical:      u64,
	byte_count:          u8,
	hit_count:           u64,
	compiled_byte_count: u32,
}

// Fixed-capacity hot-block execution tracker that promotes blocks to WebAssembly
// compilation once their hit count reaches HOT_BLOCK_COMPILE_THRESHOLD.
Wasm_Tier_Tracker :: struct {
	slots:              [WASM_TIER_TRACKER_SLOTS]Hot_Block_Slot,
	total_executions:   u64,
	queued_compiles:    u64,
	completed_compiles: u64,
	refused_compiles:   u64,
	evictions:          u64,
}

// ============================================================================
// LEB128 Encoders (freestanding, zero-allocation, zero-mutation on refusal)
// ============================================================================

// wasm_encode_uleb128_u32 encodes `value` in unsigned LEB128 into `out`.
// Refuses `.Buffer_Too_Small` without writing any byte of `out`.
wasm_encode_uleb128_u32 :: proc "contextless" (value: u32, out: []u8) -> (written: int, refusal: Wasm_Tier_Refusal) {
	needed := uleb128_u32_length(value)
	if len(out) < needed {
		return 0, .Buffer_Too_Small
	}
	v := value
	pos := 0
	for {
		b := u8(v & 0x7F)
		v >>= 7
		if v != 0 {
			b |= 0x80
		}
		out[pos] = b
		pos += 1
		if v == 0 {
			break
		}
	}
	return pos, .None
}

// wasm_encode_uleb128_u64 encodes `value` in unsigned LEB128 into `out`.
// Refuses `.Buffer_Too_Small` without writing any byte of `out`.
wasm_encode_uleb128_u64 :: proc "contextless" (value: u64, out: []u8) -> (written: int, refusal: Wasm_Tier_Refusal) {
	needed := uleb128_u64_length(value)
	if len(out) < needed {
		return 0, .Buffer_Too_Small
	}
	v := value
	pos := 0
	for {
		b := u8(v & 0x7F)
		v >>= 7
		if v != 0 {
			b |= 0x80
		}
		out[pos] = b
		pos += 1
		if v == 0 {
			break
		}
	}
	return pos, .None
}

// wasm_encode_sleb128_i32 encodes `value` in signed LEB128 into `out`.
// Refuses `.Buffer_Too_Small` without writing any byte of `out`.
wasm_encode_sleb128_i32 :: proc "contextless" (value: i32, out: []u8) -> (written: int, refusal: Wasm_Tier_Refusal) {
	needed := sleb128_i32_length(value)
	if len(out) < needed {
		return 0, .Buffer_Too_Small
	}
	v := value
	pos := 0
	for {
		b := u8(v & 0x7F)
		v >>= 7
		sign_set := (b & 0x40) != 0
		done := (v == 0 && !sign_set) || (v == -1 && sign_set)
		if !done {
			b |= 0x80
		}
		out[pos] = b
		pos += 1
		if done {
			break
		}
	}
	return pos, .None
}

// wasm_encode_sleb128_i64 encodes `value` in signed LEB128 into `out`.
// Refuses `.Buffer_Too_Small` without writing any byte of `out`.
wasm_encode_sleb128_i64 :: proc "contextless" (value: i64, out: []u8) -> (written: int, refusal: Wasm_Tier_Refusal) {
	needed := sleb128_i64_length(value)
	if len(out) < needed {
		return 0, .Buffer_Too_Small
	}
	v := value
	pos := 0
	for {
		b := u8(v & 0x7F)
		v >>= 7
		sign_set := (b & 0x40) != 0
		done := (v == 0 && !sign_set) || (v == -1 && sign_set)
		if !done {
			b |= 0x80
		}
		out[pos] = b
		pos += 1
		if done {
			break
		}
	}
	return pos, .None
}

@(private = "file")
uleb128_u32_length :: proc "contextless" (value: u32) -> int {
	v := value
	n := 0
	for {
		n += 1
		v >>= 7
		if v == 0 {
			break
		}
	}
	return n
}

@(private = "file")
uleb128_u64_length :: proc "contextless" (value: u64) -> int {
	v := value
	n := 0
	for {
		n += 1
		v >>= 7
		if v == 0 {
			break
		}
	}
	return n
}

@(private = "file")
sleb128_i32_length :: proc "contextless" (value: i32) -> int {
	v := value
	n := 0
	for {
		b := u8(v & 0x7F)
		v >>= 7
		n += 1
		sign_set := (b & 0x40) != 0
		if (v == 0 && !sign_set) || (v == -1 && sign_set) {
			break
		}
	}
	return n
}

@(private = "file")
sleb128_i64_length :: proc "contextless" (value: i64) -> int {
	v := value
	n := 0
	for {
		b := u8(v & 0x7F)
		v >>= 7
		n += 1
		sign_set := (b & 0x40) != 0
		if (v == 0 && !sign_set) || (v == -1 && sign_set) {
			break
		}
	}
	return n
}

// ============================================================================
// Validation & Two-Pass Binary Encoder
// ============================================================================

@(private = "file")
Wasm_Writer :: struct {
	buf:           []u8,
	pos:           int,
	counting_only: bool,
	overflow:      bool,
}

@(private = "file")
writer_byte :: proc "contextless" (w: ^Wasm_Writer, b: u8) {
	if !w.counting_only {
		if w.pos >= len(w.buf) {
			w.overflow = true
			return
		}
		w.buf[w.pos] = b
	}
	w.pos += 1
}

@(private = "file")
writer_bytes :: proc "contextless" (w: ^Wasm_Writer, data: []u8) {
	if !w.counting_only {
		if w.pos + len(data) > len(w.buf) {
			w.overflow = true
			return
		}
		copy(w.buf[w.pos:], data)
	}
	w.pos += len(data)
}

@(private = "file")
writer_name :: proc "contextless" (w: ^Wasm_Writer, name: string) {
	writer_uleb_u32(w, u32(len(name)))
	writer_bytes(w, transmute([]u8)name)
}

@(private = "file")
writer_uleb_u32 :: proc "contextless" (w: ^Wasm_Writer, value: u32) {
	v := value
	for {
		b := u8(v & 0x7F)
		v >>= 7
		if v != 0 {
			b |= 0x80
		}
		writer_byte(w, b)
		if v == 0 {
			break
		}
	}
}

@(private = "file")
writer_sleb_i32 :: proc "contextless" (w: ^Wasm_Writer, value: i32) {
	v := value
	for {
		b := u8(v & 0x7F)
		v >>= 7
		sign_set := (b & 0x40) != 0
		done := (v == 0 && !sign_set) || (v == -1 && sign_set)
		if !done {
			b |= 0x80
		}
		writer_byte(w, b)
		if done {
			break
		}
	}
}

@(private = "file")
writer_sleb_i64 :: proc "contextless" (w: ^Wasm_Writer, value: i64) {
	v := value
	for {
		b := u8(v & 0x7F)
		v >>= 7
		sign_set := (b & 0x40) != 0
		done := (v == 0 && !sign_set) || (v == -1 && sign_set)
		if !done {
			b |= 0x80
		}
		writer_byte(w, b)
		if done {
			break
		}
	}
}

@(private = "file")
validate_memory_import :: proc "contextless" (mem: Wasm_Memory_Import) -> Wasm_Tier_Refusal {
	kind, ok := enum_word.member_of_argument(mem.limits_kind)
	if !ok {
		return .Invalid_Memory_Config
	}
	if mem.min_pages == 0 || mem.min_pages > WASM_MAX_MEMORY_PAGES {
		return .Invalid_Memory_Config
	}
	switch kind {
	case .Unshared_Min_Only:
		if mem.max_pages != 0 {
			return .Invalid_Memory_Config
		}
	case .Shared_Min_Max:
		if mem.max_pages < mem.min_pages || mem.max_pages > WASM_MAX_MEMORY_PAGES {
			return .Invalid_Memory_Config
		}
	}
	return .None
}

@(private = "file")
validate_block_op :: proc "contextless" (op: Wasm_Block_Op) -> Wasm_Tier_Refusal {
	kind, ok := enum_word.member_of_argument(op.kind)
	if !ok {
		return .Unknown_Op_Kind
	}
	switch kind {
	case .Mov_Imm64, .Add_Imm64:
		if op.dst >= WASM_GUEST_REGISTER_COUNT {
			return .Register_Out_Of_Range
		}
		if op.src != 0 || op.guest_offset != 0 || op.exit_status != 0 {
			return .Unused_Field_Non_Zero
		}
	case .Mov_Reg64, .Add_Reg64, .Sub_Reg64, .And_Reg64, .Or_Reg64, .Xor_Reg64:
		if op.dst >= WASM_GUEST_REGISTER_COUNT || op.src >= WASM_GUEST_REGISTER_COUNT {
			return .Register_Out_Of_Range
		}
		if op.guest_offset != 0 || op.imm != 0 || op.exit_status != 0 {
			return .Unused_Field_Non_Zero
		}
	case .Load_Guest_U64, .Store_Guest_U64:
		if op.dst >= WASM_GUEST_REGISTER_COUNT || op.src >= WASM_GUEST_REGISTER_COUNT {
			return .Register_Out_Of_Range
		}
		if op.imm != 0 || op.exit_status != 0 {
			return .Unused_Field_Non_Zero
		}
	case .Exit_If_Zero, .Exit_If_Not_Zero:
		if op.src >= WASM_GUEST_REGISTER_COUNT {
			return .Register_Out_Of_Range
		}
		if op.exit_status <= WASM_EXIT_FALLTHROUGH {
			return .Invalid_Exit_Status
		}
		if op.dst != 0 || op.guest_offset != 0 || op.imm != 0 {
			return .Unused_Field_Non_Zero
		}
	case .Exit_If_Equal_Reg:
		if op.dst >= WASM_GUEST_REGISTER_COUNT || op.src >= WASM_GUEST_REGISTER_COUNT {
			return .Register_Out_Of_Range
		}
		if op.exit_status <= WASM_EXIT_FALLTHROUGH {
			return .Invalid_Exit_Status
		}
		if op.guest_offset != 0 || op.imm != 0 {
			return .Unused_Field_Non_Zero
		}
	}
	return .None
}

// wasm_block_spec_validate checks every border invariant of `spec` before emission.
wasm_block_spec_validate :: proc "contextless" (spec: Wasm_Block_Spec) -> Wasm_Tier_Refusal {
	if len(spec.ops) == 0 {
		return .Empty_Block
	}
	if len(spec.ops) > WASM_TIER_MAX_BLOCK_OPS {
		return .Too_Many_Ops
	}
	if mem_refusal := validate_memory_import(spec.memory); mem_refusal != .None {
		return mem_refusal
	}
	for op in spec.ops {
		if op_refusal := validate_block_op(op); op_refusal != .None {
			return op_refusal
		}
	}
	return .None
}

@(private = "file")
emit_load_reg :: proc "contextless" (w: ^Wasm_Writer, reg: u8) {
	writer_byte(w, WASM_OP_LOCAL_GET)
	writer_uleb_u32(w, 0) // local 0: regs_base
	writer_byte(w, WASM_OP_I64_LOAD)
	writer_uleb_u32(w, 3) // 8-byte aligned register file
	writer_uleb_u32(w, u32(reg) * 8)
}

@(private = "file")
emit_store_reg_prefix :: proc "contextless" (w: ^Wasm_Writer) {
	writer_byte(w, WASM_OP_LOCAL_GET)
	writer_uleb_u32(w, 0) // local 0: regs_base
}

@(private = "file")
emit_store_reg_suffix :: proc "contextless" (w: ^Wasm_Writer, reg: u8) {
	writer_byte(w, WASM_OP_I64_STORE)
	writer_uleb_u32(w, 3) // 8-byte aligned register file
	writer_uleb_u32(w, u32(reg) * 8)
}

@(private = "file")
emit_guest_address :: proc "contextless" (w: ^Wasm_Writer, addr_reg: u8) {
	// Effective address in Wasm linear memory: guest_mem_base + i32.wrap_i64(reg[addr_reg]).
	writer_byte(w, WASM_OP_LOCAL_GET)
	writer_uleb_u32(w, 1) // local 1: guest_mem_base
	emit_load_reg(w, addr_reg)
	writer_byte(w, WASM_OP_I32_WRAP_I64)
	writer_byte(w, WASM_OP_I32_ADD)
}

@(private = "file")
emit_conditional_exit_tail :: proc "contextless" (w: ^Wasm_Writer, exit_status: i32) {
	writer_byte(w, WASM_OP_IF)
	writer_byte(w, WASM_BLOCKTYPE_EMPTY)
	writer_byte(w, WASM_OP_I32_CONST)
	writer_sleb_i32(w, exit_status)
	writer_byte(w, WASM_OP_RETURN)
	writer_byte(w, WASM_OP_END)
}

@(private = "file")
emit_function_body_contents :: proc "contextless" (w: ^Wasm_Writer, ops: []Wasm_Block_Op) {
	// Zero extra locals: params 0 (regs_base) and 1 (guest_mem_base) suffice.
	writer_uleb_u32(w, 0)
	for op in ops {
		switch op.kind {
		case .Mov_Imm64:
			emit_store_reg_prefix(w)
			writer_byte(w, WASM_OP_I64_CONST)
			writer_sleb_i64(w, op.imm)
			emit_store_reg_suffix(w, op.dst)
		case .Mov_Reg64:
			emit_store_reg_prefix(w)
			emit_load_reg(w, op.src)
			emit_store_reg_suffix(w, op.dst)
		case .Add_Reg64:
			emit_store_reg_prefix(w)
			emit_load_reg(w, op.dst)
			emit_load_reg(w, op.src)
			writer_byte(w, WASM_OP_I64_ADD)
			emit_store_reg_suffix(w, op.dst)
		case .Sub_Reg64:
			emit_store_reg_prefix(w)
			emit_load_reg(w, op.dst)
			emit_load_reg(w, op.src)
			writer_byte(w, WASM_OP_I64_SUB)
			emit_store_reg_suffix(w, op.dst)
		case .And_Reg64:
			emit_store_reg_prefix(w)
			emit_load_reg(w, op.dst)
			emit_load_reg(w, op.src)
			writer_byte(w, WASM_OP_I64_AND)
			emit_store_reg_suffix(w, op.dst)
		case .Or_Reg64:
			emit_store_reg_prefix(w)
			emit_load_reg(w, op.dst)
			emit_load_reg(w, op.src)
			writer_byte(w, WASM_OP_I64_OR)
			emit_store_reg_suffix(w, op.dst)
		case .Xor_Reg64:
			emit_store_reg_prefix(w)
			emit_load_reg(w, op.dst)
			emit_load_reg(w, op.src)
			writer_byte(w, WASM_OP_I64_XOR)
			emit_store_reg_suffix(w, op.dst)
		case .Add_Imm64:
			emit_store_reg_prefix(w)
			emit_load_reg(w, op.dst)
			writer_byte(w, WASM_OP_I64_CONST)
			writer_sleb_i64(w, op.imm)
			writer_byte(w, WASM_OP_I64_ADD)
			emit_store_reg_suffix(w, op.dst)
		case .Load_Guest_U64:
			emit_store_reg_prefix(w)
			emit_guest_address(w, op.src)
			writer_byte(w, WASM_OP_I64_LOAD)
			// Guest x86-64 memory operands may be unaligned, so use align=0 (2^0 = 1).
			writer_uleb_u32(w, 0)
			writer_uleb_u32(w, op.guest_offset)
			emit_store_reg_suffix(w, op.dst)
		case .Store_Guest_U64:
			emit_guest_address(w, op.dst)
			emit_load_reg(w, op.src)
			writer_byte(w, WASM_OP_I64_STORE)
			writer_uleb_u32(w, 0)
			writer_uleb_u32(w, op.guest_offset)
		case .Exit_If_Zero:
			emit_load_reg(w, op.src)
			writer_byte(w, WASM_OP_I64_EQZ)
			emit_conditional_exit_tail(w, op.exit_status)
		case .Exit_If_Not_Zero:
			emit_load_reg(w, op.src)
			writer_byte(w, WASM_OP_I64_CONST)
			writer_sleb_i64(w, 0)
			writer_byte(w, WASM_OP_I64_NE)
			emit_conditional_exit_tail(w, op.exit_status)
		case .Exit_If_Equal_Reg:
			emit_load_reg(w, op.dst)
			emit_load_reg(w, op.src)
			writer_byte(w, WASM_OP_I64_EQ)
			emit_conditional_exit_tail(w, op.exit_status)
		}
	}
	// Normal fallthrough exit returns 0.
	writer_byte(w, WASM_OP_I32_CONST)
	writer_sleb_i32(w, WASM_EXIT_FALLTHROUGH)
	writer_byte(w, WASM_OP_END)
}

@(private = "file")
emit_import_section_payload :: proc "contextless" (w: ^Wasm_Writer, mem: Wasm_Memory_Import) {
	writer_uleb_u32(w, 1) // 1 import
	writer_name(w, "modus")
	writer_name(w, "memory")
	writer_byte(w, WASM_DESC_MEMORY)
	switch mem.limits_kind {
	case .Unshared_Min_Only:
		writer_byte(w, WASM_LIMITS_MIN_ONLY)
		writer_uleb_u32(w, mem.min_pages)
	case .Shared_Min_Max:
		writer_byte(w, WASM_LIMITS_SHARED_MIN_MAX)
		writer_uleb_u32(w, mem.min_pages)
		writer_uleb_u32(w, mem.max_pages)
	}
}

@(private = "file")
emit_export_section_payload :: proc "contextless" (w: ^Wasm_Writer) {
	writer_uleb_u32(w, 1) // 1 export
	writer_name(w, "run_block")
	writer_byte(w, WASM_DESC_FUNC)
	writer_uleb_u32(w, 0) // func index 0
}

@(private = "file")
emit_module :: proc "contextless" (w: ^Wasm_Writer, spec: Wasm_Block_Spec) {
	header := WASM_BINARY_HEADER
	writer_bytes(w, header[:])

	// Section 1: Type section — 1 type: (i32, i32) -> i32.
	type_payload := [7]u8{
		0x01, // count = 1
		WASM_TYPE_FUNC,
		0x02, WASM_VALTYPE_I32, WASM_VALTYPE_I32,
		0x01, WASM_VALTYPE_I32,
	}
	writer_byte(w, WASM_SECTION_TYPE)
	writer_uleb_u32(w, u32(len(type_payload)))
	writer_bytes(w, type_payload[:])

	// Section 2: Import section — imported guest linear memory.
	import_counter := Wasm_Writer{counting_only = true}
	emit_import_section_payload(&import_counter, spec.memory)
	writer_byte(w, WASM_SECTION_IMPORT)
	writer_uleb_u32(w, u32(import_counter.pos))
	emit_import_section_payload(w, spec.memory)

	// Section 3: Function section — 1 function using type index 0.
	func_payload := [2]u8{0x01, 0x00}
	writer_byte(w, WASM_SECTION_FUNCTION)
	writer_uleb_u32(w, u32(len(func_payload)))
	writer_bytes(w, func_payload[:])

	// Section 7: Export section — exports `run_block` as func 0.
	export_counter := Wasm_Writer{counting_only = true}
	emit_export_section_payload(&export_counter)
	writer_byte(w, WASM_SECTION_EXPORT)
	writer_uleb_u32(w, u32(export_counter.pos))
	emit_export_section_payload(w)

	// Section 10: Code section — 1 function body.
	body_counter := Wasm_Writer{counting_only = true}
	emit_function_body_contents(&body_counter, spec.ops)
	body_size := u32(body_counter.pos)
	code_payload_size := u32(1 + uleb128_u32_length(body_size) + body_counter.pos)

	writer_byte(w, WASM_SECTION_CODE)
	writer_uleb_u32(w, code_payload_size)
	writer_uleb_u32(w, 1) // 1 function body
	writer_uleb_u32(w, body_size)
	emit_function_body_contents(w, spec.ops)
}

// wasm_compile_block validates `spec` and emits a complete WebAssembly 1.0 module
// into `out`. Any refusal writes zero bytes to `out`.
wasm_compile_block :: proc "contextless" (spec: Wasm_Block_Spec, out: []u8) -> (written: int, refusal: Wasm_Tier_Refusal) {
	if check := wasm_block_spec_validate(spec); check != .None {
		return 0, check
	}
	counter := Wasm_Writer{counting_only = true}
	emit_module(&counter, spec)
	if counter.pos > len(out) {
		return 0, .Buffer_Too_Small
	}
	emitter := Wasm_Writer{buf = out, counting_only = false}
	emit_module(&emitter, spec)
	if emitter.overflow || emitter.pos != counter.pos {
		return 0, .Buffer_Too_Small
	}
	return emitter.pos, .None
}

// ============================================================================
// Structural Verification of Emitted WebAssembly Modules
// ============================================================================

@(private = "file")
read_uleb128_u32 :: proc "contextless" (data: []u8, pos: ^int) -> (value: u32, ok: bool) {
	shift := u32(0)
	result := u32(0)
	for count in 0 ..< WASM_LEB128_MAX_U32_BYTES {
		if pos^ >= len(data) {
			return 0, false
		}
		b := data[pos^]
		pos^ += 1
		// Reject non-zero unused upper bits in the 5th byte of a u32 LEB128.
		if count == 4 && (b & 0xF0) != 0 {
			return 0, false
		}
		result |= u32(b & 0x7F) << shift
		if (b & 0x80) == 0 {
			return result, true
		}
		shift += 7
	}
	return 0, false
}

// wasm_module_verify_structure checks that `module_bytes` has a valid
// WebAssembly 1.0 header, canonical section order, exact section lengths with
// zero trailing bytes, and all five required sections (Type, Import, Function,
// Export, Code).
wasm_module_verify_structure :: proc "contextless" (module_bytes: []u8) -> Wasm_Tier_Refusal {
	header := WASM_BINARY_HEADER
	if len(module_bytes) < len(header) {
		return .Malformed_Wasm_Module
	}
	for i in 0 ..< len(header) {
		if module_bytes[i] != header[i] {
			return .Malformed_Wasm_Module
		}
	}
	pos := len(header)
	last_section_id := u8(0)
	seen_sections := u16(0)
	for pos < len(module_bytes) {
		section_id := module_bytes[pos]
		pos += 1
		if section_id == 0 || section_id > WASM_SECTION_CODE || section_id <= last_section_id {
			return .Malformed_Wasm_Module
		}
		last_section_id = section_id
		section_len, len_ok := read_uleb128_u32(module_bytes, &pos)
		if !len_ok {
			return .Malformed_Wasm_Module
		}
		if int(section_len) > len(module_bytes) - pos {
			return .Malformed_Wasm_Module
		}
		seen_sections |= u16(1) << section_id
		pos += int(section_len)
	}
	required := (u16(1) << WASM_SECTION_TYPE) |
		(u16(1) << WASM_SECTION_IMPORT) |
		(u16(1) << WASM_SECTION_FUNCTION) |
		(u16(1) << WASM_SECTION_EXPORT) |
		(u16(1) << WASM_SECTION_CODE)
	if (seen_sections & required) != required {
		return .Malformed_Wasm_Module
	}
	return .None
}

// ============================================================================
// Hot-Block Hit Threshold Tracker
// ============================================================================

@(private = "file")
tracker_slot_index :: proc "contextless" (start_physical: u64) -> int {
	return int((start_physical * 0x9E37_79B9_7F4A_7C15) >> (64 - WASM_TIER_TRACKER_SLOT_BITS))
}

// wasm_tier_record_execution increments the execution count for the block at
// `start_physical` and returns `should_compile = true` once when the block's
// hit count reaches HOT_BLOCK_COMPILE_THRESHOLD.
wasm_tier_record_execution :: proc "contextless" (
	tracker: ^Wasm_Tier_Tracker,
	start_physical: u64,
	byte_count: u8,
) -> (should_compile: bool, hits: u64, refusal: Wasm_Tier_Refusal) {
	if tracker == nil {
		return false, 0, .Nil_Pointer
	}
	if byte_count == 0 || byte_count > WASM_TIER_MAX_BLOCK_BYTES {
		return false, 0, .Invalid_Block_Size
	}
	idx := tracker_slot_index(start_physical)
	slot := &tracker.slots[idx]
	tracker.total_executions += 1

	if slot.state == .Empty || slot.start_physical != start_physical || slot.byte_count != byte_count {
		if slot.state != .Empty {
			tracker.evictions += 1
		}
		slot^ = Hot_Block_Slot{
			state          = .Interpreted,
			start_physical = start_physical,
			byte_count     = byte_count,
			hit_count      = 1,
		}
		return false, 1, .None
	}

	if slot.hit_count < max(u64) {
		slot.hit_count += 1
	}
	if slot.state == .Interpreted && slot.hit_count >= HOT_BLOCK_COMPILE_THRESHOLD {
		slot.state = .Compile_Queued
		tracker.queued_compiles += 1
		return true, slot.hit_count, .None
	}
	return false, slot.hit_count, .None
}

// wasm_tier_mark_compiled transitions a queued hot block to `.Compiled`.
wasm_tier_mark_compiled :: proc "contextless" (
	tracker: ^Wasm_Tier_Tracker,
	start_physical: u64,
	compiled_byte_count: u32,
) -> Wasm_Tier_Refusal {
	if tracker == nil {
		return .Nil_Pointer
	}
	if compiled_byte_count == 0 {
		return .Invalid_Block_Size
	}
	slot := &tracker.slots[tracker_slot_index(start_physical)]
	if slot.state != .Compile_Queued || slot.start_physical != start_physical {
		return .Invalid_State_Transition
	}
	slot.state = .Compiled
	slot.compiled_byte_count = compiled_byte_count
	tracker.completed_compiles += 1
	return .None
}

// wasm_tier_mark_refused transitions a queued hot block to `.Refused` so a
// rejected compilation is not re-queued on subsequent executions.
wasm_tier_mark_refused :: proc "contextless" (
	tracker: ^Wasm_Tier_Tracker,
	start_physical: u64,
) -> Wasm_Tier_Refusal {
	if tracker == nil {
		return .Nil_Pointer
	}
	slot := &tracker.slots[tracker_slot_index(start_physical)]
	if slot.state != .Compile_Queued || slot.start_physical != start_physical {
		return .Invalid_State_Transition
	}
	slot.state = .Refused
	tracker.refused_compiles += 1
	return .None
}

// wasm_tier_invalidate drops one block from the hot-block tracker when guest
// code bytes at `start_physical` change.
wasm_tier_invalidate :: proc "contextless" (tracker: ^Wasm_Tier_Tracker, start_physical: u64) {
	if tracker == nil {
		return
	}
	slot := &tracker.slots[tracker_slot_index(start_physical)]
	if slot.state != .Empty && slot.start_physical == start_physical {
		slot^ = {}
	}
}

// wasm_tier_invalidate_all clears every tracked hot block.
wasm_tier_invalidate_all :: proc "contextless" (tracker: ^Wasm_Tier_Tracker) {
	if tracker == nil {
		return
	}
	for &slot in tracker.slots {
		slot = {}
	}
}
