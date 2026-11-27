// Pure freestanding x86-64 user-mode instruction decoder and support probe for
// software_machine (src/md/features/browser_machine.md, "The instruction set,
// checked").
//
// Validates that an instruction byte stream decodes cleanly within the x86-64
// 15-byte architectural limit and maps to an opcode form implemented by
// `cpu.odin`, `integer_instructions.odin`, and `sse.odin`. Used by the build
// tool to check every executable segment of every boot-image module.
package software_machine

// Classification of one decoded x86-64 instruction byte sequence.
Instruction_Probe_Status :: enum u8 {
	Supported          = 0,
	Cpuid_Gated        = 1, // Architectural instruction gated off by identification_read (rdrand/rdseed).
	Unsupported_Opcode = 2,
	Truncated          = 3,
	Exceeds_Max_Length = 4,
	Invalid_Modrm_Form = 5,
}

// Outcome of probing one instruction at the start of a byte slice.
Instruction_Probe_Result :: struct {
	status:   Instruction_Probe_Status,
	length:   int,
	opcode:   u8,
	opcode2:  u8,
	two_byte: bool,
}

@(private = "file")
Probe_Cursor :: struct {
	bytes:  []u8,
	offset: int,
	status: Instruction_Probe_Status,
}

@(private = "file")
probe_u8 :: proc "contextless" (c: ^Probe_Cursor) -> (value: u8, ok: bool) {
	if c.status != .Supported {
		return 0, false
	}
	if c.offset >= MAX_INSTRUCTION_BYTES {
		c.status = .Exceeds_Max_Length
		return 0, false
	}
	if c.offset >= len(c.bytes) {
		c.status = .Truncated
		return 0, false
	}
	value = c.bytes[c.offset]
	c.offset += 1
	return value, true
}

@(private = "file")
probe_skip :: proc "contextless" (c: ^Probe_Cursor, count: int) -> bool {
	for _ in 0 ..< count {
		if _, ok := probe_u8(c); !ok {
			return false
		}
	}
	return true
}

@(private = "file")
Probe_Modrm :: struct {
	is_register: bool,
	reg_low:     u8,
}

@(private = "file")
probe_modrm :: proc "contextless" (c: ^Probe_Cursor) -> (m: Probe_Modrm, ok: bool) {
	b := probe_u8(c) or_return
	mod := (b >> 6) & 3
	m.reg_low = (b >> 3) & 7
	rm_low := b & 7
	if mod == 3 {
		m.is_register = true
		return m, true
	}
	if mod == 0 && rm_low == 5 {
		probe_skip(c, 4) or_return
		return m, true
	}
	if rm_low == 4 {
		sib := probe_u8(c) or_return
		base_low := sib & 7
		if mod == 0 && base_low == 5 {
			probe_skip(c, 4) or_return
			return m, true
		}
	}
	if mod == 1 {
		probe_skip(c, 1) or_return
	} else if mod == 2 {
		probe_skip(c, 4) or_return
	}
	return m, true
}

@(private = "file")
probe_imm_width :: proc "contextless" (width: Operand_Width) -> int {
	switch width {
	case .Bits_8:
		return 1
	case .Bits_16:
		return 2
	case .Bits_32, .Bits_64:
		return 4
	}
	return 4
}

@(private = "file")
probe_simd_prefix :: proc "contextless" (prefixes: Decoded_Prefixes) -> Simd_Prefix {
	if prefixes.has_rep || prefixes.has_repne {
		return .Repeat_Not_Equal if prefixes.last_repeat_is_not_equal else .Repeat
	}
	if prefixes.has_operand_size_override {
		return .Operand_Size
	}
	return .None
}

@(private = "file")
probe_vector_integer_binary_known :: proc "contextless" (opcode: u8) -> bool {
	switch opcode {
	case 0x60 ..= 0x6D,
	     0x74 ..= 0x76,
	     0xD1 ..= 0xD5,
	     0xD8 ..= 0xDF,
	     0xE0 ..= 0xE5,
	     0xE8 ..= 0xEF,
	     0xF1 ..= 0xF6,
	     0xF8 ..= 0xFE:
		return true
	}
	return false
}

@(private = "file")
probe_simd_two_byte :: proc "contextless" (c: ^Probe_Cursor, prefixes: Decoded_Prefixes, opcode2: u8) -> (status: Instruction_Probe_Status, handled: bool) {
	switch opcode2 {
	case 0x10 ..= 0x18, 0x28 ..= 0x2F, 0x50 ..= 0x7F, 0xAE, 0xC2, 0xC4 ..= 0xC6, 0xD1 ..= 0xFE:
	case:
		return .Supported, false
	}
	prefix := probe_simd_prefix(prefixes)
	modrm, ok := probe_modrm(c)
	if !ok {
		return c.status, true
	}
	switch opcode2 {
	case 0x10, 0x11:
		return .Supported, true
	case 0x12, 0x13, 0x16, 0x17:
		if prefix != .None && prefix != .Operand_Size {
			return .Unsupported_Opcode, true
		}
		store := opcode2 == 0x13 || opcode2 == 0x17
		if modrm.is_register && (store || prefix == .Operand_Size) {
			return .Invalid_Modrm_Form, true
		}
		return .Supported, true
	case 0x14, 0x15, 0x2E, 0x2F, 0x54 ..= 0x57:
		if prefix != .None && prefix != .Operand_Size {
			return .Unsupported_Opcode, true
		}
		return .Supported, true
	case 0x18:
		return .Supported, true
	case 0x28, 0x29, 0x2B:
		if prefix != .None && prefix != .Operand_Size {
			return .Unsupported_Opcode, true
		}
		if opcode2 == 0x2B && modrm.is_register {
			return .Invalid_Modrm_Form, true
		}
		return .Supported, true
	case 0x2A, 0x2C, 0x2D:
		if prefix != .Repeat && prefix != .Repeat_Not_Equal {
			return .Unsupported_Opcode, true
		}
		return .Supported, true
	case 0x50:
		if !modrm.is_register || (prefix != .None && prefix != .Operand_Size) {
			return .Invalid_Modrm_Form, true
		}
		return .Supported, true
	case 0x51, 0x58, 0x59, 0x5A, 0x5C ..= 0x5F:
		return .Supported, true
	case 0x52, 0x53:
		if prefix != .None && prefix != .Repeat {
			return .Unsupported_Opcode, true
		}
		return .Supported, true
	case 0x5B:
		if prefix == .Repeat_Not_Equal {
			return .Unsupported_Opcode, true
		}
		return .Supported, true
	case 0x6E:
		if prefix != .Operand_Size {
			return .Unsupported_Opcode, true
		}
		return .Supported, true
	case 0x6F, 0x7F:
		if prefix != .Operand_Size && prefix != .Repeat {
			return .Unsupported_Opcode, true
		}
		return .Supported, true
	case 0x70:
		if !probe_skip(c, 1) {
			return c.status, true
		}
		if prefix == .None {
			return .Unsupported_Opcode, true
		}
		return .Supported, true
	case 0x71, 0x72, 0x73:
		if prefix != .Operand_Size {
			return .Unsupported_Opcode, true
		}
		if !modrm.is_register {
			return .Invalid_Modrm_Form, true
		}
		if !probe_skip(c, 1) {
			return c.status, true
		}
		switch modrm.reg_low {
		case 2, 6:
			return .Supported, true
		case 4:
			return (.Invalid_Modrm_Form if opcode2 == 0x73 else .Supported), true
		case 3, 7:
			return (.Supported if opcode2 == 0x73 else .Invalid_Modrm_Form), true
		case:
			return .Invalid_Modrm_Form, true
		}
	case 0x7E:
		if prefix != .Repeat && prefix != .Operand_Size {
			return .Unsupported_Opcode, true
		}
		return .Supported, true
	case 0xAE:
		if prefix != .None {
			return .Unsupported_Opcode, true
		}
		if modrm.is_register {
			if modrm.reg_low >= 5 && modrm.reg_low <= 7 {
				return .Supported, true
			}
			return .Invalid_Modrm_Form, true
		}
		switch modrm.reg_low {
		case 0, 1, 2, 3, 7:
			return .Supported, true
		case:
			return .Invalid_Modrm_Form, true
		}
	case 0xC2:
		if !probe_skip(c, 1) {
			return c.status, true
		}
		return .Supported, true
	case 0xC4:
		if prefix != .Operand_Size {
			return .Unsupported_Opcode, true
		}
		if !probe_skip(c, 1) {
			return c.status, true
		}
		return .Supported, true
	case 0xC5:
		if prefix != .Operand_Size || !modrm.is_register {
			return .Invalid_Modrm_Form, true
		}
		if !probe_skip(c, 1) {
			return c.status, true
		}
		return .Supported, true
	case 0xC6:
		if prefix != .None && prefix != .Operand_Size {
			return .Unsupported_Opcode, true
		}
		if !probe_skip(c, 1) {
			return c.status, true
		}
		return .Supported, true
	case 0xD6:
		if prefix != .Operand_Size {
			return .Unsupported_Opcode, true
		}
		return .Supported, true
	case 0xD7:
		if prefix != .Operand_Size || !modrm.is_register {
			return .Invalid_Modrm_Form, true
		}
		return .Supported, true
	case 0xE6:
		if prefix == .None {
			return .Unsupported_Opcode, true
		}
		return .Supported, true
	case 0xE7:
		if prefix != .Operand_Size || modrm.is_register {
			return .Invalid_Modrm_Form, true
		}
		return .Supported, true
	case 0xF7:
		if prefix != .Operand_Size || !modrm.is_register {
			return .Invalid_Modrm_Form, true
		}
		return .Supported, true
	}
	if prefix != .Operand_Size {
		return .Unsupported_Opcode, true
	}
	if !probe_vector_integer_binary_known(opcode2) {
		return .Unsupported_Opcode, true
	}
	return .Supported, true
}

// instruction_probe decodes one x86-64 user-mode instruction at the start of
// `bytes` and reports its exact byte length and whether `software_machine`
// implements it.
instruction_probe :: proc "contextless" (bytes: []u8) -> (result: Instruction_Probe_Result) {
	if len(bytes) == 0 {
		return {status = .Truncated}
	}
	c := Probe_Cursor{bytes = bytes, status = .Supported}
	prefixes: Decoded_Prefixes
	opcode: u8

	prefix_loop: for {
		b, ok := probe_u8(&c)
		if !ok {
			return {status = c.status, length = c.offset}
		}
		switch b {
		case 0x66:
			prefixes.has_operand_size_override = true
			prefixes.has_rex = false
			prefixes.rex_w, prefixes.rex_r, prefixes.rex_x, prefixes.rex_b = false, false, false, false
		case 0x67:
			prefixes.has_address_size_override = true
			prefixes.has_rex = false
			prefixes.rex_w, prefixes.rex_r, prefixes.rex_x, prefixes.rex_b = false, false, false, false
		case 0xF0:
			prefixes.has_lock = true
			prefixes.has_rex = false
			prefixes.rex_w, prefixes.rex_r, prefixes.rex_x, prefixes.rex_b = false, false, false, false
		case 0xF2:
			prefixes.has_repne = true
			prefixes.last_repeat_is_not_equal = true
			prefixes.has_rex = false
			prefixes.rex_w, prefixes.rex_r, prefixes.rex_x, prefixes.rex_b = false, false, false, false
		case 0xF3:
			prefixes.has_rep = true
			prefixes.last_repeat_is_not_equal = false
			prefixes.has_rex = false
			prefixes.rex_w, prefixes.rex_r, prefixes.rex_x, prefixes.rex_b = false, false, false, false
		case 0x65:
			prefixes.has_gs_override = true
			prefixes.has_rex = false
			prefixes.rex_w, prefixes.rex_r, prefixes.rex_x, prefixes.rex_b = false, false, false, false
		case 0x26, 0x2E, 0x36, 0x3E:
			prefixes.has_rex = false
			prefixes.rex_w, prefixes.rex_r, prefixes.rex_x, prefixes.rex_b = false, false, false, false
		case 0x40 ..= 0x4F:
			prefixes.has_rex = true
			prefixes.rex_w = (b & 0x08) != 0
			prefixes.rex_r = (b & 0x04) != 0
			prefixes.rex_x = (b & 0x02) != 0
			prefixes.rex_b = (b & 0x01) != 0
		case:
			opcode = b
			break prefix_loop
		}
	}

	result.opcode = opcode
	width := operand_width_from_prefixes(prefixes)

	if opcode == 0x0F {
		result.two_byte = true
		op2, ok := probe_u8(&c)
		if !ok {
			result.status = c.status
			result.length = c.offset
			return result
		}
		result.opcode2 = op2
		switch op2 {
		case 0x05, 0x0B, 0x31, 0xA2, 0xC8 ..= 0xCF:
			result.status = .Supported
			result.length = c.offset
			return result
		case 0x1F, 0x40 ..= 0x4F, 0x90 ..= 0x9F, 0xA3, 0xA5, 0xAB, 0xAD, 0xAF, 0xB0, 0xB1, 0xB3, 0xB6, 0xB7, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF, 0xC0, 0xC1:
			if _, m_ok := probe_modrm(&c); !m_ok {
				result.status = c.status
				result.length = c.offset
				return result
			}
			result.status = .Supported
			result.length = c.offset
			return result
		case 0xC3:
			modrm, m_ok := probe_modrm(&c)
			if !m_ok {
				result.status = c.status
				result.length = c.offset
				return result
			}
			if modrm.is_register || prefixes.has_operand_size_override {
				result.status = .Invalid_Modrm_Form
				result.length = c.offset
				return result
			}
			result.status = .Supported
			result.length = c.offset
			return result
		case 0xC7:
			// Group 9: rdrand (0F C7 /6, mod=3) and rdseed (0F C7 /7, mod=3)
			// are emitted in modus:random behind a CPUID feature check that
			// identification_read reports absent.
			modrm, m_ok := probe_modrm(&c)
			if !m_ok {
				result.status = c.status
				result.length = c.offset
				return result
			}
			if modrm.is_register && (modrm.reg_low == 6 || modrm.reg_low == 7) && !prefixes.has_rep && !prefixes.has_repne {
				result.status = .Cpuid_Gated
				result.length = c.offset
				return result
			}
			result.status = .Unsupported_Opcode
			result.length = c.offset
			return result
		case 0x80 ..= 0x8F:
			if !probe_skip(&c, 4) {
				result.status = c.status
				result.length = c.offset
				return result
			}
			result.status = .Supported
			result.length = c.offset
			return result
		case 0xA4, 0xAC:
			if _, m_ok := probe_modrm(&c); !m_ok {
				result.status = c.status
				result.length = c.offset
				return result
			}
			if !probe_skip(&c, 1) {
				result.status = c.status
				result.length = c.offset
				return result
			}
			result.status = .Supported
			result.length = c.offset
			return result
		case 0xBA:
			modrm, m_ok := probe_modrm(&c)
			if !m_ok {
				result.status = c.status
				result.length = c.offset
				return result
			}
			if !probe_skip(&c, 1) {
				result.status = c.status
				result.length = c.offset
				return result
			}
			if modrm.reg_low < 4 {
				result.status = .Invalid_Modrm_Form
				result.length = c.offset
				return result
			}
			result.status = .Supported
			result.length = c.offset
			return result
		}
		if simd_status, handled := probe_simd_two_byte(&c, prefixes, op2); handled {
			result.status = simd_status
			result.length = c.offset
			return result
		}
		result.status = .Unsupported_Opcode
		result.length = c.offset
		return result
	}

	// Standard 8-ALU-op matrix (0x00..0x3D).
	if opcode <= 0x3D && (opcode & 0x07) <= 5 {
		switch opcode & 0x07 {
		case 0, 1, 2, 3:
			if _, ok := probe_modrm(&c); !ok {
				result.status = c.status
				result.length = c.offset
				return result
			}
		case 4:
			if !probe_skip(&c, 1) {
				result.status = c.status
				result.length = c.offset
				return result
			}
		case 5:
			if !probe_skip(&c, probe_imm_width(width)) {
				result.status = c.status
				result.length = c.offset
				return result
			}
		}
		result.status = .Supported
		result.length = c.offset
		return result
	}

	switch opcode {
	case 0x50 ..= 0x5F, 0x90 ..= 0x99, 0x9C, 0x9D, 0xA4, 0xA5, 0xAA, 0xAB, 0xC3, 0xC9, 0xCC, 0xEC ..= 0xEF, 0xFC, 0xFD:
		result.status = .Supported
		result.length = c.offset
		return result
	case 0x6A, 0x70 ..= 0x7F, 0xA8, 0xB0 ..= 0xB7, 0xE4 ..= 0xE7, 0xEB:
		if !probe_skip(&c, 1) {
			result.status = c.status
			result.length = c.offset
			return result
		}
		result.status = .Supported
		result.length = c.offset
		return result
	case 0xC2:
		if !probe_skip(&c, 2) {
			result.status = c.status
			result.length = c.offset
			return result
		}
		result.status = .Supported
		result.length = c.offset
		return result
	case 0x68:
		imm_bytes := 2 if (prefixes.has_operand_size_override && !prefixes.rex_w) else 4
		if !probe_skip(&c, imm_bytes) {
			result.status = c.status
			result.length = c.offset
			return result
		}
		result.status = .Supported
		result.length = c.offset
		return result
	case 0xA9:
		if !probe_skip(&c, probe_imm_width(width)) {
			result.status = c.status
			result.length = c.offset
			return result
		}
		result.status = .Supported
		result.length = c.offset
		return result
	case 0xB8 ..= 0xBF:
		imm_bytes := 8 if width == .Bits_64 else (2 if width == .Bits_16 else 4)
		if !probe_skip(&c, imm_bytes) {
			result.status = c.status
			result.length = c.offset
			return result
		}
		result.status = .Supported
		result.length = c.offset
		return result
	case 0xE8, 0xE9:
		if !probe_skip(&c, 4) {
			result.status = c.status
			result.length = c.offset
			return result
		}
		result.status = .Supported
		result.length = c.offset
		return result
	case 0x63, 0x84 ..= 0x8B:
		if _, ok := probe_modrm(&c); !ok {
			result.status = c.status
			result.length = c.offset
			return result
		}
		result.status = .Supported
		result.length = c.offset
		return result
	case 0x8D:
		modrm, ok := probe_modrm(&c)
		if !ok {
			result.status = c.status
			result.length = c.offset
			return result
		}
		result.status = .Invalid_Modrm_Form if modrm.is_register else .Supported
		result.length = c.offset
		return result
	case 0x8F:
		modrm, ok := probe_modrm(&c)
		if !ok {
			result.status = c.status
			result.length = c.offset
			return result
		}
		result.status = .Invalid_Modrm_Form if modrm.reg_low != 0 else .Supported
		result.length = c.offset
		return result
	case 0x69, 0x6B:
		if _, ok := probe_modrm(&c); !ok {
			result.status = c.status
			result.length = c.offset
			return result
		}
		imm_bytes := 1 if opcode == 0x6B else probe_imm_width(width)
		if !probe_skip(&c, imm_bytes) {
			result.status = c.status
			result.length = c.offset
			return result
		}
		result.status = .Supported
		result.length = c.offset
		return result
	case 0x80, 0x81, 0x83:
		if _, ok := probe_modrm(&c); !ok {
			result.status = c.status
			result.length = c.offset
			return result
		}
		imm_bytes := 1 if (opcode == 0x80 || opcode == 0x83) else probe_imm_width(width)
		if !probe_skip(&c, imm_bytes) {
			result.status = c.status
			result.length = c.offset
			return result
		}
		result.status = .Supported
		result.length = c.offset
		return result
	case 0xC0, 0xC1, 0xD0 ..= 0xD3:
		modrm, ok := probe_modrm(&c)
		if !ok {
			result.status = c.status
			result.length = c.offset
			return result
		}
		if opcode == 0xC0 || opcode == 0xC1 {
			if !probe_skip(&c, 1) {
				result.status = c.status
				result.length = c.offset
				return result
			}
		}
		switch modrm.reg_low {
		case 0, 1, 4, 5, 6, 7:
			result.status = .Supported
		case:
			result.status = .Invalid_Modrm_Form
		}
		result.length = c.offset
		return result
	case 0xC6, 0xC7:
		modrm, ok := probe_modrm(&c)
		if !ok {
			result.status = c.status
			result.length = c.offset
			return result
		}
		if modrm.reg_low != 0 {
			result.status = .Invalid_Modrm_Form
			result.length = c.offset
			return result
		}
		imm_bytes := 1 if opcode == 0xC6 else probe_imm_width(width)
		if !probe_skip(&c, imm_bytes) {
			result.status = c.status
			result.length = c.offset
			return result
		}
		result.status = .Supported
		result.length = c.offset
		return result
	case 0xF6, 0xF7:
		modrm, ok := probe_modrm(&c)
		if !ok {
			result.status = c.status
			result.length = c.offset
			return result
		}
		if modrm.reg_low == 0 || modrm.reg_low == 1 {
			imm_bytes := 1 if opcode == 0xF6 else probe_imm_width(width)
			if !probe_skip(&c, imm_bytes) {
				result.status = c.status
				result.length = c.offset
				return result
			}
		}
		result.status = .Supported
		result.length = c.offset
		return result
	case 0xFE:
		modrm, ok := probe_modrm(&c)
		if !ok {
			result.status = c.status
			result.length = c.offset
			return result
		}
		result.status = .Supported if (modrm.reg_low == 0 || modrm.reg_low == 1) else .Invalid_Modrm_Form
		result.length = c.offset
		return result
	case 0xFF:
		modrm, ok := probe_modrm(&c)
		if !ok {
			result.status = c.status
			result.length = c.offset
			return result
		}
		switch modrm.reg_low {
		case 0, 1, 2, 4, 6:
			result.status = .Supported
		case:
			result.status = .Invalid_Modrm_Form
		}
		result.length = c.offset
		return result
	}

	result.status = .Unsupported_Opcode
	result.length = c.offset
	return result
}
