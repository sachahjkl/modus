// The integer instructions of the 0F map beside the first set of cpu.odin:
// the bit tests and scans, bswap, the double shifts, movnti, rdtsc and
// cpuid. Each one writes its register or memory as its last action, and
// processor_step gives back the registers and flags of a faulted one.
package software_machine

// The operation of bt, bts, btr and btc on the bit that they test.
Bit_Test_Operation :: enum u8 {
	Test       = 0,
	Set        = 1,
	Reset      = 2,
	Complement = 3,
}

@(private = "file")
integer_finish :: proc "contextless" (cpu: ^Processor_State, cursor: ^Instruction_Cursor) -> Step_Outcome {
	cpu.rip = cursor.current_rip
	cpu.steps_executed += 1
	return .Running
}

@(private = "file")
integer_invalid :: proc "contextless" (cpu: ^Processor_State, cursor: ^Instruction_Cursor) -> Step_Outcome {
	return record_fault(cpu, cursor.start_rip, .Invalid_Opcode, cursor.start_rip)
}

// execute_bit_test runs bt, bts, btr and btc. With a register offset and a
// memory operand, the offset is signed and reaches past the operand: the
// address moves by whole operands (Intel SDM, BT).
@(private = "file")
execute_bit_test :: proc "contextless" (
	cpu: ^Processor_State,
	physical_memory: []u8,
	cursor: ^Instruction_Cursor,
	prefixes: Decoded_Prefixes,
	operation: Bit_Test_Operation,
	modrm: Decoded_Modrm,
	offset: u64,
	offset_from_register: bool,
) -> Step_Outcome {
	width := operand_width_from_prefixes(prefixes)
	bits := u64(width_bit_count(width))
	bit := offset & (bits - 1)
	value: u64
	address: u64
	if modrm.is_register {
		value = read_register(cpu, modrm.rm_register, width, prefixes.has_rex)
	} else {
		address = resolve_effective_address(cpu, modrm, cursor.current_rip, true)
		if offset_from_register {
			signed := sign_extend_to_i64(offset, width)
			address += u64(signed >> uint(trailing_zero_count(bits))) * u64(width)
		}
		read_value, read_outcome := read_memory_width(cpu, physical_memory, cursor.start_rip, address, width)
		if read_outcome != .Running {
			return read_outcome
		}
		value = read_value
	}
	selected := (value >> bit) & 1
	result := value
	switch operation {
	case .Test:
	case .Set:
		result |= u64(1) << bit
	case .Reset:
		result &~= u64(1) << bit
	case .Complement:
		result ~= u64(1) << bit
	}
	if operation != .Test {
		if modrm.is_register {
			write_register(cpu, modrm.rm_register, width, prefixes.has_rex, result)
		} else if outcome := write_memory_width(cpu, physical_memory, cursor.start_rip, address, width, result); outcome != .Running {
			return outcome
		}
	}
	set_flag(cpu, RFLAGS_CF, selected != 0)
	return integer_finish(cpu, cursor)
}

@(private = "file")
trailing_zero_count :: #force_inline proc "contextless" (value: u64) -> u64 {
	count := u64(0)
	for shifted := value; shifted != 0 && shifted & 1 == 0; shifted >>= 1 {
		count += 1
	}
	return count
}

// execute_double_shift runs shld and shrd: the destination shifted, filled
// with the bits of the source. A count of 0 changes nothing, not the flags.
@(private = "file")
execute_double_shift :: proc "contextless" (cpu: ^Processor_State, destination, source: u64, raw_count: u8, width: Operand_Width, left: bool) -> (result: u64, changed: bool) {
	count := u64(raw_count & (63 if width == .Bits_64 else 31))
	if count == 0 {
		return destination, false
	}
	mask := width_mask(width)
	bits := u64(width_bit_count(width))
	destination_masked := destination & mask
	source_masked := source & mask
	carry: bool
	if count < bits {
		if left {
			result = ((destination_masked << count) | (source_masked >> (bits - count))) & mask
			carry = (destination_masked >> (bits - count)) & 1 != 0
		} else {
			result = ((destination_masked >> count) | (source_masked << (bits - count))) & mask
			carry = (destination_masked >> (count - 1)) & 1 != 0
		}
	} else {
		// Only a 16-bit operand reaches here: the processor shifts the
		// 32 bits of the destination and the source as one.
		joined := (destination_masked << 16) | source_masked if left else (source_masked << 16) | destination_masked
		if left {
			result = ((joined << count) >> 16) & mask
			carry = (joined >> (32 - count)) & 1 != 0
		} else {
			result = (joined >> count) & mask
			carry = (joined >> (count - 1)) & 1 != 0
		}
	}
	set_flag(cpu, RFLAGS_CF, carry)
	set_flag(cpu, RFLAGS_OF, ((result ~ destination_masked) & width_sign_bit(width)) != 0)
	update_szp_flags(cpu, result, width)
	return result, true
}

// integer_two_byte_step runs one of the instructions of this file. handled
// is false for an opcode that is none of them.
@(private)
integer_two_byte_step :: proc "contextless" (cpu: ^Processor_State, physical_memory: []u8, cursor: ^Instruction_Cursor, prefixes: Decoded_Prefixes, opcode: u8) -> (outcome: Step_Outcome, handled: bool) {
	width := operand_width_from_prefixes(prefixes)
	switch opcode {
	case 0x31:
		// rdtsc: #GP when CR4.TSD is enabled, else the counter in edx:eax with
		// the high halves cleared.
		if cpu.timestamp_disable {
			return record_fault(cpu, cursor.start_rip, .General_Protection, 0), true
		}
		counter := cpu.steps_executed
		if cpu.cycle_counter_read != nil {
			counter = cpu.cycle_counter_read()
		}
		cpu.registers[int(General_Register.Rax)] = counter & 0xFFFF_FFFF
		cpu.registers[int(General_Register.Rdx)] = counter >> 32
		return integer_finish(cpu, cursor), true
	case 0xA2:
		eax, ebx, ecx, edx := identification_read(u32(cpu.registers[int(General_Register.Rax)]), u32(cpu.registers[int(General_Register.Rcx)]))
		cpu.registers[int(General_Register.Rax)] = u64(eax)
		cpu.registers[int(General_Register.Rbx)] = u64(ebx)
		cpu.registers[int(General_Register.Rcx)] = u64(ecx)
		cpu.registers[int(General_Register.Rdx)] = u64(edx)
		return integer_finish(cpu, cursor), true
	case 0xA3, 0xAB, 0xB3, 0xBB:
		modrm, modrm_outcome := decode_modrm(cpu, physical_memory, cursor, prefixes)
		if modrm_outcome != .Running {
			return modrm_outcome, true
		}
		operation, _ := enum_word_bit_test((opcode >> 3) & 3)
		offset := read_register(cpu, modrm.reg_index, width, prefixes.has_rex)
		return execute_bit_test(cpu, physical_memory, cursor, prefixes, operation, modrm, offset, true), true
	case 0xBA:
		modrm, modrm_outcome := decode_modrm(cpu, physical_memory, cursor, prefixes)
		if modrm_outcome != .Running {
			return modrm_outcome, true
		}
		immediate, fetch_outcome := fetch_u8(cpu, physical_memory, cursor)
		if fetch_outcome != .Running {
			return fetch_outcome, true
		}
		selector := modrm.reg_index & 7
		if selector < 4 {
			return integer_invalid(cpu, cursor), true
		}
		operation, _ := enum_word_bit_test(selector - 4)
		return execute_bit_test(cpu, physical_memory, cursor, prefixes, operation, modrm, u64(immediate), false), true
	case 0xBC, 0xBD:
		// bsf and bsr. With F3 they are tzcnt and lzcnt, which the answer of
		// cpuid does not name: a processor without them runs bsf and bsr.
		modrm, modrm_outcome := decode_modrm(cpu, physical_memory, cursor, prefixes)
		if modrm_outcome != .Running {
			return modrm_outcome, true
		}
		source, read_outcome := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, width, prefixes.has_rex)
		if read_outcome != .Running {
			return read_outcome, true
		}
		if source == 0 {
			// The destination keeps its value (AMD64 APM, BSF).
			set_flag(cpu, RFLAGS_ZF, true)
			return integer_finish(cpu, cursor), true
		}
		index := trailing_zero_count(source)
		if opcode == 0xBD {
			index = 63
			for (source >> index) & 1 == 0 {
				index -= 1
			}
		}
		set_flag(cpu, RFLAGS_ZF, false)
		write_register(cpu, modrm.reg_index, width, prefixes.has_rex, index)
		return integer_finish(cpu, cursor), true
	case 0xA4, 0xA5, 0xAC, 0xAD:
		// shld and shrd, by an immediate or by cl.
		modrm, modrm_outcome := decode_modrm(cpu, physical_memory, cursor, prefixes)
		if modrm_outcome != .Running {
			return modrm_outcome, true
		}
		count := u8(cpu.registers[int(General_Register.Rcx)])
		if opcode == 0xA4 || opcode == 0xAC {
			immediate, fetch_outcome := fetch_u8(cpu, physical_memory, cursor)
			if fetch_outcome != .Running {
				return fetch_outcome, true
			}
			count = immediate
		}
		destination, read_outcome := read_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, width, prefixes.has_rex)
		if read_outcome != .Running {
			return read_outcome, true
		}
		source := read_register(cpu, modrm.reg_index, width, prefixes.has_rex)
		result, changed := execute_double_shift(cpu, destination, source, count, width, opcode == 0xA4 || opcode == 0xA5)
		// On x86-64, a 32-bit register destination still zero-extends into the
		// upper 32 bits even when the masked shift count is 0.
		if changed || (modrm.is_register && width == .Bits_32) {
			if write_outcome := write_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, width, prefixes.has_rex, result); write_outcome != .Running {
				return write_outcome, true
			}
		}
		return integer_finish(cpu, cursor), true
	case 0xC3:
		// movnti: a store of a general register, memory only.
		modrm, modrm_outcome := decode_modrm(cpu, physical_memory, cursor, prefixes)
		if modrm_outcome != .Running {
			return modrm_outcome, true
		}
		if modrm.is_register || prefixes.has_operand_size_override {
			return integer_invalid(cpu, cursor), true
		}
		store_width := Operand_Width.Bits_64 if prefixes.rex_w else Operand_Width.Bits_32
		value := read_register(cpu, modrm.reg_index, store_width, prefixes.has_rex)
		if write_outcome := write_rm_operand(cpu, physical_memory, cursor.start_rip, cursor.current_rip, modrm, store_width, prefixes.has_rex, value); write_outcome != .Running {
			return write_outcome, true
		}
		return integer_finish(cpu, cursor), true
	case 0xC8 ..= 0xCF:
		// bswap. With a 16-bit operand the result is not defined; the
		// processors clear the low word, and so does this one.
		register := (opcode - 0xC8) | (u8(8) if prefixes.rex_b else 0)
		switch width {
		case .Bits_64:
			value := cpu.registers[register]
			swapped: u64
			for index in uint(0) ..< 8 {
				swapped |= ((value >> (8 * index)) & 0xFF) << (8 * (7 - index))
			}
			cpu.registers[register] = swapped
		case .Bits_32:
			value := cpu.registers[register] & 0xFFFF_FFFF
			swapped: u64
			for index in uint(0) ..< 4 {
				swapped |= ((value >> (8 * index)) & 0xFF) << (8 * (3 - index))
			}
			cpu.registers[register] = swapped
		case .Bits_16, .Bits_8:
			cpu.registers[register] &~= 0xFFFF
		}
		return integer_finish(cpu, cursor), true
	}
	return .Running, false
}

// enum_word_bit_test gives the operation of a 2-bit selector; every value
// names a member.
@(private = "file")
enum_word_bit_test :: proc "contextless" (word: u8) -> (Bit_Test_Operation, bool) {
	switch word & 3 {
	case 0:
		return .Test, true
	case 1:
		return .Set, true
	case 2:
		return .Reset, true
	}
	return .Complement, true
}
