package guest_os

import "modus:contract/enum_word"
import op "modus:contract/operation"

// The decode of the instruction of a memory exit on a device: the kernel
// gives the guest physical address and the access, not the instruction, so
// the process reads it in the memory of the guest. Only the forms of `mov`
// that a driver uses on a register of a device are decoded: `mov` between a
// register and memory (88, 89, 8A, 8B), `mov` of an immediate to memory
// (C6, C7), `movzx` from memory (0F B6, 0F B7) and `movsx` from memory
// (0F BE, 0F BF). The accessors of Linux (`readb`, `readw`, `readl`,
// `writeb`, `writew`, `writel`) are inline assembly of one `mov` with a
// memory operand of any addressing form; the address comes from the exit,
// so the decode reads the bytes of the operand only to find the length.
// Each other instruction is refused: the process then stops the guest, and
// emulates nothing that it did not decode whole.

// The longest instruction of the processor.
INSTRUCTION_BYTES_MOST :: 15

// The general registers, by their number in the encoding.
General_Register :: enum u8 {
	Rax = 0,
	Rcx = 1,
	Rdx = 2,
	Rbx = 3,
	Rsp = 4,
	Rbp = 5,
	Rsi = 6,
	Rdi = 7,
	R8  = 8,
	R9  = 9,
	R10 = 10,
	R11 = 11,
	R12 = 12,
	R13 = 13,
	R14 = 14,
	R15 = 15,
}

Device_Access_Direction :: enum u8 {
	Read  = 1, // The guest reads the device into a register.
	Write = 2, // The guest writes a register or an immediate to the device.
}

// One decoded access to a device.
Device_Access :: struct {
	direction:        Device_Access_Direction,
	size:             u8, // The bytes of the access: 1, 2, 4 or 8.
	register:         General_Register, // The register of the access; none for an immediate write.
	high_byte:        bool, // The register is ah, ch, dh or bh: bits 8 to 15 of rax, rcx, rdx or rbx.
	immediate:        bool, // A write of the immediate value, not of a register.
	immediate_value:  u64,
	destination_size: u8, // A read: the bytes of the register that it writes (movzx and movsx write more than they read).
	sign_extend:      bool, // A read of movsx: the value fills the register with its sign bit.
	length:           u8, // The bytes of the instruction.
}

Instruction_Refusal :: enum u8 {
	None             = 0,
	Truncated        = 1, // The bytes end before the instruction.
	Unknown_Opcode   = 2, // Not one of the decoded forms.
	Register_Operand = 3, // The operand is a register, not memory: no access to a device.
	Too_Long         = 4, // More than 15 bytes.
}

// device_access_decode decodes the instruction in bytes. long_mode says if
// the code is 64-bit, where 40 to 4F are the REX prefix; else the code is
// 32-bit, where they are other instructions.
device_access_decode :: proc "contextless" (bytes: []u8, long_mode: bool) -> (access: Device_Access, refusal: Instruction_Refusal) {
	at := 0
	operand_16 := false
	rex: u8 = 0
	// The prefixes: the operand size, the address size (64-bit only), and the
	// segments, which do not change the physical address that the kernel gave.
	prefixes: for {
		if at >= len(bytes) {
			return {}, .Truncated
		}
		switch bytes[at] {
		case 0x66:
			operand_16 = true
		case 0x67:
			if !long_mode {
				return {}, .Unknown_Opcode // 16-bit addressing: another form of the operand.
			}
		case 0x26, 0x2E, 0x36, 0x3E, 0x64, 0x65:
		case:
			break prefixes
		}
		at += 1
		if at >= INSTRUCTION_BYTES_MOST {
			return {}, .Too_Long
		}
	}
	if long_mode && bytes[at] & 0xF0 == 0x40 {
		rex = bytes[at]
		at += 1
		if at >= len(bytes) {
			return {}, .Truncated
		}
	}
	rex_w := rex & 0x8 != 0
	rex_r := rex & 0x4 != 0
	wide_size := u8(rex_w ? 8 : operand_16 ? 2 : 4)
	opcode := u16(bytes[at])
	at += 1
	if opcode == 0x0F {
		if at >= len(bytes) {
			return {}, .Truncated
		}
		opcode = 0x0F00 | u16(bytes[at])
		at += 1
	}
	immediate_bytes := 0
	switch opcode {
	case 0x88:
		access = {direction = .Write, size = 1}
	case 0x89:
		access = {direction = .Write, size = wide_size}
	case 0x8A:
		access = {direction = .Read, size = 1, destination_size = 1}
	case 0x8B:
		access = {direction = .Read, size = wide_size, destination_size = wide_size}
	case 0xC6:
		access = {direction = .Write, size = 1, immediate = true}
		immediate_bytes = 1
	case 0xC7:
		access = {direction = .Write, size = wide_size, immediate = true}
		immediate_bytes = operand_16 && !rex_w ? 2 : 4
	case 0x0FB6:
		access = {direction = .Read, size = 1, destination_size = wide_size}
	case 0x0FB7:
		access = {direction = .Read, size = 2, destination_size = wide_size}
	case 0x0FBE:
		access = {direction = .Read, size = 1, destination_size = wide_size, sign_extend = true}
	case 0x0FBF:
		access = {direction = .Read, size = 2, destination_size = wide_size, sign_extend = true}
	case:
		return {}, .Unknown_Opcode
	}
	if at >= len(bytes) {
		return {}, .Truncated
	}
	modrm := bytes[at]
	at += 1
	mode := modrm >> 6
	register_field := modrm >> 3 & 0x7
	rm := modrm & 0x7
	if mode == 3 {
		return {}, .Register_Operand
	}
	if access.immediate && register_field != 0 {
		return {}, .Unknown_Opcode // C6 and C7 with another extension are not mov.
	}
	displacement := 0
	if rm == 4 {
		// A SIB byte; its base 5 with the mode 0 has a displacement of 32 bits.
		if at >= len(bytes) {
			return {}, .Truncated
		}
		sib := bytes[at]
		at += 1
		if mode == 0 && sib & 0x7 == 5 {
			displacement = 4
		}
	} else if mode == 0 && rm == 5 {
		displacement = 4 // rip-relative in 64-bit code, an absolute address in 32-bit code.
	}
	if mode == 1 {
		displacement = 1
	} else if mode == 2 {
		displacement = 4
	}
	at += displacement
	if at + immediate_bytes > len(bytes) {
		return {}, .Truncated
	}
	if immediate_bytes > 0 {
		value := u64(0)
		for index in 0 ..< immediate_bytes {
			value |= u64(bytes[at + index]) << (u64(index) * 8)
		}
		// A 32-bit immediate of a 64-bit write is sign-extended.
		if immediate_bytes == 4 && access.size == 8 && value & 0x8000_0000 != 0 {
			value |= 0xFFFF_FFFF_0000_0000
		}
		access.immediate_value = value
		at += immediate_bytes
	}
	if at > INSTRUCTION_BYTES_MOST {
		return {}, .Too_Long
	}
	if !access.immediate {
		number := register_field | (rex_r ? 8 : 0)
		// Without REX, the bytes 4 to 7 of an operand of one byte are ah, ch,
		// dh and bh; with REX, they are spl, bpl, sil and dil.
		if access.size == 1 && access.destination_size <= 1 && rex == 0 && number >= 4 && number < 8 {
			access.high_byte = true
			number -= 4
		}
		register, known := enum_word.member_of_word(General_Register, u64(number))
		if !known {
			return {}, .Unknown_Opcode // Cannot happen: four bits name each register.
		}
		access.register = register
	}
	access.length = u8(at)
	return access, .None
}

// general_register_pointer gives the field of a record that holds a
// general register.
general_register_pointer :: proc "contextless" (registers: ^op.Guest_Registers, register: General_Register) -> ^u64 {
	switch register {
	case .Rax:
		return &registers.rax
	case .Rcx:
		return &registers.rcx
	case .Rdx:
		return &registers.rdx
	case .Rbx:
		return &registers.rbx
	case .Rsp:
		return &registers.rsp
	case .Rbp:
		return &registers.rbp
	case .Rsi:
		return &registers.rsi
	case .Rdi:
		return &registers.rdi
	case .R8:
		return &registers.r8
	case .R9:
		return &registers.r9
	case .R10:
		return &registers.r10
	case .R11:
		return &registers.r11
	case .R12:
		return &registers.r12
	case .R13:
		return &registers.r13
	case .R14:
		return &registers.r14
	case .R15:
		return &registers.r15
	}
	return &registers.rax
}

// size_mask gives the mask of the low bytes of a value.
size_mask :: proc "contextless" (size: u8) -> u64 {
	return size >= 8 ? max(u64) : (u64(1) << (u64(size) * 8)) - 1
}

// device_access_value gives the value that a decoded write sends.
device_access_value :: proc "contextless" (registers: op.Guest_Registers, access: Device_Access) -> u64 {
	if access.immediate {
		return access.immediate_value & size_mask(access.size)
	}
	copy_of_registers := registers
	value := general_register_pointer(&copy_of_registers, access.register)^
	if access.high_byte {
		value >>= 8
	}
	return value & size_mask(access.size)
}

// sign_extended gives a value of size bytes with its sign bit copied up
// through all 64 bits.
sign_extended :: proc "contextless" (value: u64, size: u8) -> u64 {
	if size >= 8 {
		return value
	}
	bits := u64(size) * 8
	sign := u64(1) << (bits - 1)
	low := value & size_mask(size)
	return (low ~ sign) - sign
}

// device_access_complete writes the value of a decoded read in its register
// with the rules of the processor: a write of 4 bytes clears the high half,
// a write of 1 or 2 bytes keeps the other bytes; then it moves rip past the
// instruction.
device_access_complete :: proc "contextless" (registers: ^op.Guest_Registers, access: Device_Access, value: u64) {
	if access.direction == .Read {
		target := general_register_pointer(registers, access.register)
		read := value & size_mask(access.size)
		if access.sign_extend {
			read = sign_extended(read, access.size) & size_mask(access.destination_size)
		}
		switch {
		case access.high_byte:
			target^ = target^ &~ u64(0xFF00) | (read & 0xFF) << 8
		case access.destination_size == 4:
			target^ = read
		case access.destination_size == 8:
			target^ = read
		case:
			mask := size_mask(access.destination_size)
			target^ = target^ &~ mask | read
		}
	}
	registers.rip += u64(access.length)
}
