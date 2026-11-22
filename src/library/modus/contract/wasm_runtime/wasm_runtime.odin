// Pure freestanding sandboxed WebAssembly 1.0 module validator and bounded
// stack-machine interpreter (src/md/features/desktop_to_browser.md,
// "WebAssembly modules").
//
// Confines every module to caller-supplied linear memory, bounded operand/call
// stacks, strict instruction fuel, and an explicit capability import table.
// Zero dynamic allocations and zero kernel operations.
package wasm_runtime

import "modus:contract/byte_order"
import "modus:contract/enum_word"

WASM_MAGIC :: u32(0x6D736100) // "\0asm" little-endian
WASM_VERSION :: u32(1)
WASM_PAGE_SIZE :: 65536

MAX_WASM_TYPES :: 16
MAX_WASM_FUNCS :: 32
MAX_WASM_EXPORTS :: 32
MAX_WASM_IMPORTS :: 16
MAX_WASM_LOCALS :: 32
MAX_WASM_STACK :: 256
MAX_WASM_CALL_DEPTH :: 32
MAX_WASM_PARAMS :: 8
MAX_WASM_FUEL :: u64(1_000_000)

Wasm_Refusal :: enum u8 {
	None                 = 0,
	Bad_Magic            = 1,
	Bad_Version          = 2,
	Truncated            = 3,
	Bad_Section_Order    = 4,
	Bad_Leb128           = 5,
	Unsupported_Feature  = 6,
	Capacity_Exceeded    = 7,
	Unknown_Export       = 8,
	Import_Not_Granted   = 9,
	Trap_Unreachable     = 10,
	Trap_Div_By_Zero     = 11,
	Trap_Memory_Oob      = 12,
	Trap_Stack_Underflow = 13,
	Trap_Stack_Overflow  = 14,
	Trap_Call_Depth      = 15,
	Trap_Out_Of_Fuel     = 16,
	Bad_Opcode           = 17,
}

wasm_refusal_of_word :: proc "contextless" (word: u64) -> (r: Wasm_Refusal, ok: bool) {
	return enum_word.member_of_word(Wasm_Refusal, word)
}

Wasm_Val_Type :: enum u8 {
	I32 = 0x7F,
	I64 = 0x7E,
}

Func_Type :: struct {
	param_count:  u8,
	result_count: u8,
	params:       [MAX_WASM_PARAMS]Wasm_Val_Type,
	result:       Wasm_Val_Type,
}

Export_Entry :: struct {
	name:       [32]u8,
	name_len:   u8,
	kind:       u8, // 0 = func
	func_index: u32,
}

Import_Entry :: struct {
	module_name: [32]u8,
	module_len:  u8,
	field_name:  [32]u8,
	field_len:   u8,
	type_index:  u32,
}

Code_Body :: struct {
	offset:      u32,
	length:      u32,
	extra_locals: u8,
}

Wasm_Module :: struct {
	valid:            bool,
	type_count:       int,
	types:            [MAX_WASM_TYPES]Func_Type,
	import_count:     int,
	imports:          [MAX_WASM_IMPORTS]Import_Entry,
	func_count:       int, // Defined (non-imported) functions.
	func_type_indices: [MAX_WASM_FUNCS]u32,
	bodies:           [MAX_WASM_FUNCS]Code_Body,
	export_count:     int,
	exports:          [MAX_WASM_EXPORTS]Export_Entry,
	min_memory_pages: u32,
	has_memory:       bool,
}

Host_Import_Callback :: #type proc "contextless" (
	module_name: string,
	field_name: string,
	args: []i64,
	user_data: rawptr,
) -> (result: i64, allowed: bool)

@(private = "file")
read_uleb128_u32 :: proc "contextless" (bytes: []u8, pos: ^int) -> (val: u32, ok: bool) {
	shift := u32(0)
	res := u32(0)
	for _ in 0 ..< 5 {
		if pos^ >= len(bytes) {
			return 0, false
		}
		b := bytes[pos^]
		pos^ += 1
		if shift == 28 && (b & 0xF0) != 0 {
			return 0, false
		}
		res |= u32(b & 0x7F) << shift
		if (b & 0x80) == 0 {
			return res, true
		}
		shift += 7
	}
	return 0, false
}

@(private = "file")
read_sleb128_i32 :: proc "contextless" (bytes: []u8, pos: ^int) -> (val: i32, ok: bool) {
	shift := u32(0)
	res := u32(0)
	for _ in 0 ..< 5 {
		if pos^ >= len(bytes) {
			return 0, false
		}
		b := bytes[pos^]
		pos^ += 1
		res |= u32(b & 0x7F) << shift
		shift += 7
		if (b & 0x80) == 0 {
			if shift < 32 && (b & 0x40) != 0 {
				res |= (~u32(0)) << shift
			}
			return i32(res), true
		}
	}
	return 0, false
}

// wasm_module_parse validates a WebAssembly 1.0 binary into mod without allocating.
wasm_module_parse :: proc "contextless" (bytes: []u8, mod: ^Wasm_Module) -> Wasm_Refusal {
	if mod == nil || len(bytes) < 8 {
		return .Truncated
	}
	mod^ = {}
	if byte_order.read_u32_little_endian(bytes, 0) != WASM_MAGIC {
		return .Bad_Magic
	}
	if byte_order.read_u32_little_endian(bytes, 4) != WASM_VERSION {
		return .Bad_Version
	}

	pos := 8
	last_section_id := u8(0)
	code_count := 0

	for pos < len(bytes) {
		sec_id := bytes[pos]
		pos += 1
		sec_size, ok_sz := read_uleb128_u32(bytes, &pos)
		if !ok_sz || int(sec_size) > len(bytes) - pos {
			return .Truncated
		}
		sec_end := pos + int(sec_size)
		if sec_id != 0 {
			if sec_id <= last_section_id {
				return .Bad_Section_Order
			}
			last_section_id = sec_id
		}

		switch sec_id {
		case 0: // Custom section: skip safely.
			pos = sec_end
		case 1: // Type section.
			cnt, ok := read_uleb128_u32(bytes, &pos)
			if !ok || int(cnt) > MAX_WASM_TYPES {
				return !ok ? .Bad_Leb128 : .Capacity_Exceeded
			}
			for i in 0 ..< int(cnt) {
				if pos >= sec_end || bytes[pos] != 0x60 {
					return .Unsupported_Feature
				}
				pos += 1
				pcnt, okp := read_uleb128_u32(bytes, &pos)
				if !okp || int(pcnt) > MAX_WASM_PARAMS || pos + int(pcnt) > sec_end {
					return .Capacity_Exceeded
				}
				ft: Func_Type
				ft.param_count = u8(pcnt)
				for p in 0 ..< int(pcnt) {
					vt, vok := enum_word.member_of_word(Wasm_Val_Type, u64(bytes[pos]))
					if !vok {
						return .Unsupported_Feature
					}
					ft.params[p] = vt
					pos += 1
				}
				rcnt, okr := read_uleb128_u32(bytes, &pos)
				if !okr || rcnt > 1 || pos + int(rcnt) > sec_end {
					return .Unsupported_Feature
				}
				ft.result_count = u8(rcnt)
				if rcnt == 1 {
					vt, vok := enum_word.member_of_word(Wasm_Val_Type, u64(bytes[pos]))
					if !vok {
						return .Unsupported_Feature
					}
					ft.result = vt
					pos += 1
				}
				mod.types[i] = ft
			}
			mod.type_count = int(cnt)
		case 2: // Import section (function imports only).
			cnt, ok := read_uleb128_u32(bytes, &pos)
			if !ok || int(cnt) > MAX_WASM_IMPORTS {
				return !ok ? .Bad_Leb128 : .Capacity_Exceeded
			}
			for i in 0 ..< int(cnt) {
				mlen, okm := read_uleb128_u32(bytes, &pos)
				if !okm || int(mlen) > 32 || pos + int(mlen) > sec_end {
					return .Truncated
				}
				imp: Import_Entry
				copy(imp.module_name[:], bytes[pos:pos + int(mlen)])
				imp.module_len = u8(mlen)
				pos += int(mlen)
				flen, okf := read_uleb128_u32(bytes, &pos)
				if !okf || int(flen) > 32 || pos + int(flen) > sec_end {
					return .Truncated
				}
				copy(imp.field_name[:], bytes[pos:pos + int(flen)])
				imp.field_len = u8(flen)
				pos += int(flen)
				if pos >= sec_end || bytes[pos] != 0x00 { // func import kind
					return .Unsupported_Feature
				}
				pos += 1
				tidx, okt := read_uleb128_u32(bytes, &pos)
				if !okt || int(tidx) >= mod.type_count {
					return .Bad_Leb128
				}
				imp.type_index = tidx
				mod.imports[i] = imp
			}
			mod.import_count = int(cnt)
		case 3: // Function section.
			cnt, ok := read_uleb128_u32(bytes, &pos)
			if !ok || int(cnt) > MAX_WASM_FUNCS {
				return !ok ? .Bad_Leb128 : .Capacity_Exceeded
			}
			for i in 0 ..< int(cnt) {
				tidx, okt := read_uleb128_u32(bytes, &pos)
				if !okt || int(tidx) >= mod.type_count {
					return .Bad_Leb128
				}
				mod.func_type_indices[i] = tidx
			}
			mod.func_count = int(cnt)
		case 5: // Memory section.
			cnt, ok := read_uleb128_u32(bytes, &pos)
			if !ok || cnt != 1 || pos >= sec_end {
				return .Unsupported_Feature
			}
			flags := bytes[pos]
			pos += 1
			min_p, okmin := read_uleb128_u32(bytes, &pos)
			if !okmin {
				return .Bad_Leb128
			}
			if flags == 1 {
				_, okmax := read_uleb128_u32(bytes, &pos)
				if !okmax {
					return .Bad_Leb128
				}
			} else if flags != 0 {
				return .Unsupported_Feature
			}
			mod.has_memory = true
			mod.min_memory_pages = min_p
		case 7: // Export section.
			cnt, ok := read_uleb128_u32(bytes, &pos)
			if !ok || int(cnt) > MAX_WASM_EXPORTS {
				return !ok ? .Bad_Leb128 : .Capacity_Exceeded
			}
			for i in 0 ..< int(cnt) {
				nlen, okn := read_uleb128_u32(bytes, &pos)
				if !okn || int(nlen) > 32 || pos + int(nlen) + 1 > sec_end {
					return .Truncated
				}
				exp: Export_Entry
				copy(exp.name[:], bytes[pos:pos + int(nlen)])
				exp.name_len = u8(nlen)
				pos += int(nlen)
				exp.kind = bytes[pos]
				pos += 1
				idx, oki := read_uleb128_u32(bytes, &pos)
				if !oki {
					return .Bad_Leb128
				}
				exp.func_index = idx
				mod.exports[i] = exp
			}
			mod.export_count = int(cnt)
		case 10: // Code section.
			cnt, ok := read_uleb128_u32(bytes, &pos)
			if !ok || int(cnt) != mod.func_count {
				return .Truncated
			}
			for i in 0 ..< int(cnt) {
				bsz, okb := read_uleb128_u32(bytes, &pos)
				if !okb || int(bsz) > sec_end - pos {
					return .Truncated
				}
				body_end := pos + int(bsz)
				decl_cnt, okd := read_uleb128_u32(bytes, &pos)
				if !okd {
					return .Bad_Leb128
				}
				extra := u32(0)
				for _ in 0 ..< int(decl_cnt) {
					lcnt, okl := read_uleb128_u32(bytes, &pos)
					if !okl || pos >= body_end {
						return .Truncated
					}
					_, vok := enum_word.member_of_word(Wasm_Val_Type, u64(bytes[pos]))
					if !vok {
						return .Unsupported_Feature
					}
					pos += 1
					extra += lcnt
					if extra > MAX_WASM_LOCALS {
						return .Capacity_Exceeded
					}
				}
				mod.bodies[i] = Code_Body{
					offset       = u32(pos),
					length       = u32(body_end - pos),
					extra_locals = u8(extra),
				}
				pos = body_end
			}
			code_count = int(cnt)
		case:
			return .Unsupported_Feature
		}
		if pos != sec_end {
			return .Truncated
		}
	}
	if code_count != mod.func_count {
		return .Truncated
	}
	mod.valid = true
	return .None
}

// wasm_execute_export runs an exported function with caller-provided linear
// memory, strict instruction fuel, and explicit host-import capability callback.
wasm_execute_export :: proc "contextless" (
	bytes: []u8,
	mod: ^Wasm_Module,
	export_name: string,
	args: []i64,
	memory: []u8,
	fuel_limit: u64,
	host_import: Host_Import_Callback = nil,
	host_user_data: rawptr = nil,
) -> (result: i64, refusal: Wasm_Refusal) {
	if mod == nil || !mod.valid {
		return 0, .Bad_Magic
	}
	if fuel_limit == 0 || fuel_limit > MAX_WASM_FUEL {
		return 0, .Trap_Out_Of_Fuel
	}
	if mod.has_memory && u64(len(memory)) < u64(mod.min_memory_pages) * WASM_PAGE_SIZE {
		return 0, .Trap_Memory_Oob
	}

	exp_bytes := transmute([]u8)export_name
	target_func := -1
	for i in 0 ..< mod.export_count {
		e := &mod.exports[i]
		if e.kind == 0 && int(e.name_len) == len(exp_bytes) {
			same := true
			for k in 0 ..< len(exp_bytes) {
				if e.name[k] != exp_bytes[k] {
					same = false
					break
				}
			}
			if same {
				target_func = int(e.func_index)
				break
			}
		}
	}
	if target_func < 0 {
		return 0, .Unknown_Export
	}

	fuel := fuel_limit
	return exec_func(bytes, mod, target_func, args, memory, &fuel, 0, host_import, host_user_data)
}

@(private = "file")
exec_func :: proc "contextless" (
	bytes: []u8,
	mod: ^Wasm_Module,
	func_idx: int,
	args: []i64,
	memory: []u8,
	fuel: ^u64,
	depth: int,
	host_import: Host_Import_Callback,
	host_user_data: rawptr,
) -> (result: i64, refusal: Wasm_Refusal) {
	if depth >= MAX_WASM_CALL_DEPTH {
		return 0, .Trap_Call_Depth
	}
	if func_idx < mod.import_count {
		if host_import == nil {
			return 0, .Import_Not_Granted
		}
		imp := &mod.imports[func_idx]
		m_str := string(imp.module_name[:imp.module_len])
		f_str := string(imp.field_name[:imp.field_len])
		res, allowed := host_import(m_str, f_str, args, host_user_data)
		if !allowed {
			return 0, .Import_Not_Granted
		}
		return res, .None
	}

	def_idx := func_idx - mod.import_count
	if def_idx < 0 || def_idx >= mod.func_count {
		return 0, .Unknown_Export
	}
	ft := &mod.types[mod.func_type_indices[def_idx]]
	body := &mod.bodies[def_idx]
	if len(args) != int(ft.param_count) {
		return 0, .Trap_Stack_Underflow
	}
	total_locals := int(ft.param_count) + int(body.extra_locals)
	if total_locals > MAX_WASM_LOCALS {
		return 0, .Capacity_Exceeded
	}

	locals: [MAX_WASM_LOCALS]i64
	for i in 0 ..< len(args) {
		locals[i] = args[i]
	}

	stack: [MAX_WASM_STACK]i64
	sp := 0
	pc := int(body.offset)
	end_pc := int(body.offset) + int(body.length)

	push :: proc "contextless" (stack: ^[MAX_WASM_STACK]i64, sp: ^int, v: i64) -> bool {
		if sp^ >= MAX_WASM_STACK {
			return false
		}
		stack[sp^] = v
		sp^ += 1
		return true
	}
	pop :: proc "contextless" (stack: ^[MAX_WASM_STACK]i64, sp: ^int) -> (i64, bool) {
		if sp^ <= 0 {
			return 0, false
		}
		sp^ -= 1
		return stack[sp^], true
	}

	for pc < end_pc {
		if fuel^ == 0 {
			return 0, .Trap_Out_Of_Fuel
		}
		fuel^ -= 1
		op := bytes[pc]
		pc += 1
		switch op {
		case 0x00: // unreachable
			return 0, .Trap_Unreachable
		case 0x01: // nop
		case 0x0B: // end
			if ft.result_count == 1 {
				v, ok := pop(&stack, &sp)
				if !ok {
					return 0, .Trap_Stack_Underflow
				}
				return v, .None
			}
			return 0, .None
		case 0x0F: // return
			if ft.result_count == 1 {
				v, ok := pop(&stack, &sp)
				if !ok {
					return 0, .Trap_Stack_Underflow
				}
				return v, .None
			}
			return 0, .None
		case 0x10: // call
			callee, okc := read_uleb128_u32(bytes, &pc)
			if !okc {
				return 0, .Bad_Leb128
			}
			callee_type_idx: u32
			if int(callee) < mod.import_count {
				callee_type_idx = mod.imports[callee].type_index
			} else if int(callee) - mod.import_count < mod.func_count {
				callee_type_idx = mod.func_type_indices[int(callee) - mod.import_count]
			} else {
				return 0, .Unknown_Export
			}
			ct := &mod.types[callee_type_idx]
			call_args: [MAX_WASM_PARAMS]i64
			for i := int(ct.param_count) - 1; i >= 0; i -= 1 {
				v, ok := pop(&stack, &sp)
				if !ok {
					return 0, .Trap_Stack_Underflow
				}
				call_args[i] = v
			}
			cres, cref := exec_func(bytes, mod, int(callee), call_args[:ct.param_count], memory, fuel, depth + 1, host_import, host_user_data)
			if cref != .None {
				return 0, cref
			}
			if ct.result_count == 1 {
				if !push(&stack, &sp, cres) {
					return 0, .Trap_Stack_Overflow
				}
			}
		case 0x1A: // drop
			if _, ok := pop(&stack, &sp); !ok {
				return 0, .Trap_Stack_Underflow
			}
		case 0x20: // local.get
			lidx, okl := read_uleb128_u32(bytes, &pc)
			if !okl || int(lidx) >= total_locals {
				return 0, .Bad_Leb128
			}
			if !push(&stack, &sp, locals[lidx]) {
				return 0, .Trap_Stack_Overflow
			}
		case 0x21: // local.set
			lidx, okl := read_uleb128_u32(bytes, &pc)
			if !okl || int(lidx) >= total_locals {
				return 0, .Bad_Leb128
			}
			v, ok := pop(&stack, &sp)
			if !ok {
				return 0, .Trap_Stack_Underflow
			}
			locals[lidx] = v
		case 0x28: // i32.load
			_, oka := read_uleb128_u32(bytes, &pc)
			off, oko := read_uleb128_u32(bytes, &pc)
			if !oka || !oko {
				return 0, .Bad_Leb128
			}
			base, ok := pop(&stack, &sp)
			if !ok {
				return 0, .Trap_Stack_Underflow
			}
			addr := u64(u32(base)) + u64(off)
			if addr + 4 > u64(len(memory)) {
				return 0, .Trap_Memory_Oob
			}
			val := i64(i32(byte_order.read_u32_little_endian(memory, int(addr))))
			if !push(&stack, &sp, val) {
				return 0, .Trap_Stack_Overflow
			}
		case 0x36: // i32.store
			_, oka := read_uleb128_u32(bytes, &pc)
			off, oko := read_uleb128_u32(bytes, &pc)
			if !oka || !oko {
				return 0, .Bad_Leb128
			}
			val, okv := pop(&stack, &sp)
			base, okb := pop(&stack, &sp)
			if !okv || !okb {
				return 0, .Trap_Stack_Underflow
			}
			addr := u64(u32(base)) + u64(off)
			if addr + 4 > u64(len(memory)) {
				return 0, .Trap_Memory_Oob
			}
			byte_order.write_u32_little_endian(memory, int(addr), u32(val))
		case 0x41: // i32.const
			v, okv := read_sleb128_i32(bytes, &pc)
			if !okv {
				return 0, .Bad_Leb128
			}
			if !push(&stack, &sp, i64(v)) {
				return 0, .Trap_Stack_Overflow
			}
		case 0x6A: // i32.add
			b, okb := pop(&stack, &sp)
			a, oka := pop(&stack, &sp)
			if !oka || !okb {
				return 0, .Trap_Stack_Underflow
			}
			if !push(&stack, &sp, i64(i32(a) + i32(b))) {
				return 0, .Trap_Stack_Overflow
			}
		case 0x6B: // i32.sub
			b, okb := pop(&stack, &sp)
			a, oka := pop(&stack, &sp)
			if !oka || !okb {
				return 0, .Trap_Stack_Underflow
			}
			if !push(&stack, &sp, i64(i32(a) - i32(b))) {
				return 0, .Trap_Stack_Overflow
			}
		case 0x6C: // i32.mul
			b, okb := pop(&stack, &sp)
			a, oka := pop(&stack, &sp)
			if !oka || !okb {
				return 0, .Trap_Stack_Underflow
			}
			if !push(&stack, &sp, i64(i32(a) * i32(b))) {
				return 0, .Trap_Stack_Overflow
			}
		case 0x6D: // i32.div_s
			b, okb := pop(&stack, &sp)
			a, oka := pop(&stack, &sp)
			if !oka || !okb {
				return 0, .Trap_Stack_Underflow
			}
			ai, bi := i32(a), i32(b)
			if bi == 0 || (ai == min(i32) && bi == -1) {
				return 0, .Trap_Div_By_Zero
			}
			if !push(&stack, &sp, i64(ai / bi)) {
				return 0, .Trap_Stack_Overflow
			}
		case:
			return 0, .Bad_Opcode
		}
	}
	return 0, .Truncated
}
