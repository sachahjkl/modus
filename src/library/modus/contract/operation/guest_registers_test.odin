#+build !freestanding
package operation

import "core:testing"
import "modus:contract/errors"

// refusal_of gives why the checks refuse a record, or None.
refusal_of :: proc(registers: Guest_Registers) -> Guest_Registers_Refusal {
	_, refusal := guest_registers_check(registers)
	return refusal
}

// The control registers of a guest in long mode, which each case of long
// mode below changes by one bit.
LONG_MODE_REGISTERS :: Guest_Registers {
	rip  = 0x20_0000,
	cr0  = GUEST_CONTROL_0_PROTECTION | GUEST_CONTROL_0_EXTENSION_TYPE | GUEST_CONTROL_0_PAGING,
	cr3  = 0x1000,
	cr4  = GUEST_CONTROL_4_PHYSICAL_ADDRESS_EXTENSION,
	efer = GUEST_EFER_LONG_MODE_ENABLE | GUEST_EFER_LONG_MODE_ACTIVE,
}

// Each bit of the flags register that no processor defines is refused,
// alone and with every defined bit: the processor faults on a reserved bit
// set at the entry of a guest. Bit 1, which is always 1, is defined: the
// record can hold it clear or set.
@(test)
guest_registers_with_a_reserved_flag_are_refused :: proc(t: ^testing.T) {
	// The reserved bits of the flags register, from the manual of the
	// processor: 3, 5, 15, then 22 to 63.
	reserved_bits := [?]u64{3, 5, 15, 22, 31, 32, 63}
	for bit in reserved_bits {
		alone := Guest_Registers{rflags = u64(1) << bit}
		testing.expectf(t, refusal_of(alone) == .Flags, "the reserved bit %v is refused", bit)
		with_defined := Guest_Registers{rflags = GUEST_FLAGS_DEFINED | u64(1) << bit}
		testing.expectf(t, refusal_of(with_defined) == .Flags, "the reserved bit %v is refused beside the defined bits", bit)
	}
	for bit: u64 = 0; bit < 64; bit += 1 {
		registers := Guest_Registers{rflags = u64(1) << bit}
		defined := GUEST_FLAGS_DEFINED & (u64(1) << bit) != 0
		testing.expectf(t, (refusal_of(registers) == .Flags) == !defined, "the bit %v: defined %v", bit, defined)
	}
	testing.expect_value(t, refusal_of({rflags = ~GUEST_FLAGS_DEFINED}), Guest_Registers_Refusal.Flags)
	testing.expect_value(t, refusal_of({rflags = max(u64)}), Guest_Registers_Refusal.Flags)
	// The successful cases last: no flag, each defined flag, bit 1 clear,
	// and the general registers at their largest values, which the kernel
	// does not refuse.
	testing.expect_value(t, refusal_of({}), Guest_Registers_Refusal.None)
	testing.expect_value(t, refusal_of({rflags = GUEST_FLAGS_DEFINED}), Guest_Registers_Refusal.None)
	testing.expect_value(t, refusal_of({rflags = GUEST_FLAGS_DEFINED &~ 0b10}), Guest_Registers_Refusal.None)
	testing.expect_value(t, refusal_of({rflags = 0b10}), Guest_Registers_Refusal.None)
	largest := Guest_Registers {
		rax = max(u64),
		rbx = max(u64),
		rcx = max(u64),
		rdx = max(u64),
		rsi = max(u64),
		rdi = max(u64),
		rbp = max(u64),
		rsp = max(u64),
		r8  = max(u64),
		r9  = max(u64),
		r10 = max(u64),
		r11 = max(u64),
		r12 = max(u64),
		r13 = max(u64),
		r14 = max(u64),
		r15 = max(u64),
		rip = max(u64),
	}
	testing.expect_value(t, refusal_of(largest), Guest_Registers_Refusal.None)
}

// The control registers: a bit that no processor defines, and a pair of
// bits that no processor accepts, are refused before the entry.
@(test)
guest_control_registers_with_a_reserved_bit_are_refused :: proc(t: ^testing.T) {
	for bit in ([?]u64{32, 33, 62, 63}) {
		testing.expectf(t, refusal_of({cr0 = u64(1) << bit}) == .Control_0, "cr0 bit %v", bit)
	}
	testing.expect_value(t, refusal_of({cr0 = max(u64)}), Guest_Registers_Refusal.Control_0)
	// NW without CD, and PG without PE.
	testing.expect_value(t, refusal_of({cr0 = GUEST_CONTROL_0_NOT_WRITE_THROUGH}), Guest_Registers_Refusal.Control_0)
	testing.expect_value(t, refusal_of({cr0 = GUEST_CONTROL_0_PAGING}), Guest_Registers_Refusal.Control_0)
	for bit in ([?]u64{52, 53, 63}) {
		testing.expectf(t, refusal_of({cr3 = u64(1) << bit}) == .Control_3, "cr3 bit %v", bit)
	}
	testing.expect_value(t, refusal_of({cr3 = max(u64)}), Guest_Registers_Refusal.Control_3)
	for bit: u64 = 0; bit < 64; bit += 1 {
		defined := GUEST_CONTROL_4_DEFINED & (u64(1) << bit) != 0
		refusal := refusal_of({cr4 = u64(1) << bit})
		testing.expectf(t, (refusal == .Control_4) == !defined, "cr4 bit %v: defined %v, refusal %v", bit, defined, refusal)
		efer_defined := GUEST_EFER_DEFINED & (u64(1) << bit) != 0
		efer_refusal := refusal_of({efer = u64(1) << bit})
		testing.expectf(t, (efer_refusal == .Efer) == !efer_defined, "efer bit %v: defined %v, refusal %v", bit, efer_defined, efer_refusal)
	}
	// The bits of the other vendor are refused.
	testing.expect_value(t, refusal_of({cr4 = u64(1) << 13}), Guest_Registers_Refusal.Control_4)
	testing.expect_value(t, refusal_of({cr4 = u64(1) << 14}), Guest_Registers_Refusal.Control_4)
	testing.expect_value(t, refusal_of({efer = u64(1) << 9}), Guest_Registers_Refusal.Efer)
	// The successful cases: the largest values that the rules accept.
	testing.expect_value(t, refusal_of({cr0 = GUEST_CONTROL_0_CACHE_DISABLE | GUEST_CONTROL_0_NOT_WRITE_THROUGH | GUEST_CONTROL_0_EXTENSION_TYPE}), Guest_Registers_Refusal.None)
	testing.expect_value(t, refusal_of({cr3 = GUEST_CONTROL_3_DEFINED}), Guest_Registers_Refusal.None)
	testing.expect_value(t, refusal_of({cr0 = GUEST_CONTROL_0_PROTECTION | GUEST_CONTROL_0_PAGING, cr4 = GUEST_CONTROL_4_DEFINED}), Guest_Registers_Refusal.None)
	testing.expect_value(t, refusal_of({efer = GUEST_EFER_SECURE_VIRTUAL_MACHINE | GUEST_EFER_NO_EXECUTE | GUEST_EFER_SYSTEM_CALL}), Guest_Registers_Refusal.None)
}

// Long mode needs PE, PG, PAE, LME and LMA together, and a canonical
// instruction address; each missing bit is refused.
@(test)
guest_long_mode_needs_each_of_its_bits :: proc(t: ^testing.T) {
	registers := LONG_MODE_REGISTERS
	registers.mode_load = u8(Guest_Mode_Load.Long_64)
	testing.expect_value(t, refusal_of(registers), Guest_Registers_Refusal.None)

	no_extension := registers
	no_extension.cr4 = 0
	testing.expect_value(t, refusal_of(no_extension), Guest_Registers_Refusal.Long_Mode)
	no_paging := registers
	no_paging.cr0 &~= GUEST_CONTROL_0_PAGING
	testing.expect_value(t, refusal_of(no_paging), Guest_Registers_Refusal.Long_Mode)
	no_protection := registers
	no_protection.cr0 &~= GUEST_CONTROL_0_PROTECTION
	testing.expect_value(t, refusal_of(no_protection), Guest_Registers_Refusal.Control_0)
	no_enable := registers
	no_enable.efer &~= GUEST_EFER_LONG_MODE_ENABLE
	testing.expect_value(t, refusal_of(no_enable), Guest_Registers_Refusal.Long_Mode)
	// LME and PG without LMA: the processor sets LMA, and refuses the pair
	// without it.
	no_active := registers
	no_active.efer &~= GUEST_EFER_LONG_MODE_ACTIVE
	testing.expect_value(t, refusal_of(no_active), Guest_Registers_Refusal.Long_Mode)
	// The load of long mode needs long mode: LME without PG is not active.
	not_active_yet := registers
	not_active_yet.cr0 &~= GUEST_CONTROL_0_PAGING
	not_active_yet.efer &~= GUEST_EFER_LONG_MODE_ACTIVE
	testing.expect_value(t, refusal_of(not_active_yet), Guest_Registers_Refusal.Mode_Load)

	// The addresses at the edges of the canonical halves, with 48 bits and
	// with 57.
	for address in ([?]u64{0x0000_8000_0000_0000, 0xFFFF_7FFF_FFFF_FFFF, 0x0001_0000_0000_0000, max(u64) &~ (u64(1) << 63)}) {
		non_canonical := registers
		non_canonical.rip = address
		testing.expectf(t, refusal_of(non_canonical) == .Instruction_Address, "rip %x is not canonical", address)
	}
	for address in ([?]u64{0, 0x0000_7FFF_FFFF_FFFF, 0xFFFF_8000_0000_0000, max(u64)}) {
		canonical := registers
		canonical.rip = address
		testing.expectf(t, refusal_of(canonical) == .None, "rip %x is canonical", address)
	}
	five_level := registers
	five_level.cr4 |= GUEST_CONTROL_4_FIVE_LEVEL_PAGING
	five_level.rip = 0x0000_8000_0000_0000
	testing.expect_value(t, refusal_of(five_level), Guest_Registers_Refusal.None)
	five_level.rip = 0x0100_0000_0000_0000
	testing.expect_value(t, refusal_of(five_level), Guest_Registers_Refusal.Instruction_Address)
	five_level.rip = 0xFF00_0000_0000_0000
	testing.expect_value(t, refusal_of(five_level), Guest_Registers_Refusal.None)
	// Out of long mode, a 32-bit address is never refused as non-canonical.
	testing.expect_value(t, refusal_of({rip = 0xFFFF_FFFF_FFFF_FFFF}), Guest_Registers_Refusal.None)
}

// The word of the mode load: each word that names no member is refused, and
// each mode needs the control registers of that mode.
@(test)
guest_mode_load_border_and_modes :: proc(t: ^testing.T) {
	for word in ([?]u8{4, 5, 128, max(u8)}) {
		testing.expectf(t, refusal_of({mode_load = word}) == .Mode_Load, "mode word %v", word)
	}
	protected := Guest_Registers{cr0 = GUEST_CONTROL_0_PROTECTION}
	// Real mode refuses PE and LME.
	real := protected
	real.mode_load = u8(Guest_Mode_Load.Real_16)
	testing.expect_value(t, refusal_of(real), Guest_Registers_Refusal.Mode_Load)
	testing.expect_value(t, refusal_of({mode_load = u8(Guest_Mode_Load.Real_16), efer = GUEST_EFER_LONG_MODE_ENABLE}), Guest_Registers_Refusal.Mode_Load)
	// Protected mode needs PE and refuses LME.
	testing.expect_value(t, refusal_of({mode_load = u8(Guest_Mode_Load.Protected_32)}), Guest_Registers_Refusal.Mode_Load)
	with_enable := protected
	with_enable.mode_load = u8(Guest_Mode_Load.Protected_32)
	with_enable.efer = GUEST_EFER_LONG_MODE_ENABLE
	testing.expect_value(t, refusal_of(with_enable), Guest_Registers_Refusal.Mode_Load)
	// Long mode needs long mode.
	testing.expect_value(t, refusal_of({mode_load = u8(Guest_Mode_Load.Long_64)}), Guest_Registers_Refusal.Mode_Load)
	long_from_protected := protected
	long_from_protected.mode_load = u8(Guest_Mode_Load.Long_64)
	testing.expect_value(t, refusal_of(long_from_protected), Guest_Registers_Refusal.Mode_Load)
	// The successful cases last: each mode with its registers.
	testing.expect_value(t, refusal_of({mode_load = u8(Guest_Mode_Load.Keep)}), Guest_Registers_Refusal.None)
	testing.expect_value(t, refusal_of({mode_load = u8(Guest_Mode_Load.Real_16), code_selector = 0xF000, data_selector = max(u16)}), Guest_Registers_Refusal.None)
	protected.mode_load = u8(Guest_Mode_Load.Protected_32)
	testing.expect_value(t, refusal_of(protected), Guest_Registers_Refusal.None)
	paged := protected
	paged.cr0 |= GUEST_CONTROL_0_PAGING
	testing.expect_value(t, refusal_of(paged), Guest_Registers_Refusal.None)
	testing.expect_value(t, u8(max(Guest_Mode_Load)), u8(3))
}

// The event to deliver: each word that names no kind, each vector that a
// kind does not take, and each error code that the event does not push, is
// refused.
@(test)
guest_event_border_vectors_and_error_codes :: proc(t: ^testing.T) {
	for word in ([?]u8{5, 6, 128, max(u8)}) {
		testing.expectf(t, refusal_of({inject_kind = word}) == .Inject_Kind, "kind word %v", word)
	}
	for valid in ([?]u8{2, 3, max(u8)}) {
		testing.expectf(t, refusal_of({inject_kind = u8(Guest_Inject_Kind.Exception), inject_vector = 13, inject_error_code_valid = valid}) == .Inject_Kind, "error code valid %v", valid)
	}
	// None takes nothing.
	testing.expect_value(t, refusal_of({inject_vector = 1}), Guest_Registers_Refusal.Inject_Vector)
	testing.expect_value(t, refusal_of({inject_vector = max(u8)}), Guest_Registers_Refusal.Inject_Vector)
	testing.expect_value(t, refusal_of({inject_error_code_valid = 1}), Guest_Registers_Refusal.Inject_Error_Code)
	testing.expect_value(t, refusal_of({inject_error_code = 1}), Guest_Registers_Refusal.Inject_Error_Code)
	testing.expect_value(t, refusal_of({inject_error_code = max(u32)}), Guest_Registers_Refusal.Inject_Error_Code)
	// The non-maskable interrupt is the vector 2 only.
	for vector in ([?]u8{0, 1, 3, 32, max(u8)}) {
		testing.expectf(t, refusal_of({inject_kind = u8(Guest_Inject_Kind.Non_Maskable_Interrupt), inject_vector = vector}) == .Inject_Vector, "non-maskable vector %v", vector)
	}
	testing.expect_value(t, refusal_of({inject_kind = u8(Guest_Inject_Kind.Non_Maskable_Interrupt), inject_vector = 2, inject_error_code_valid = 1}), Guest_Registers_Refusal.Inject_Error_Code)
	// An exception is a vector below 32, not 2, 15, 18, 22 to 27 or 31.
	for vector in ([?]u8{2, 15, 18, 22, 27, 31, 32, 33, max(u8)}) {
		testing.expectf(t, refusal_of({inject_kind = u8(Guest_Inject_Kind.Exception), inject_vector = vector}) == .Inject_Vector, "exception vector %v", vector)
	}
	// An error code only for the exceptions that push one.
	for vector in ([?]u8{0, 1, 3, 6, 7, 9, 16, 19, 20, 28}) {
		testing.expectf(t, refusal_of({inject_kind = u8(Guest_Inject_Kind.Exception), inject_vector = vector, inject_error_code_valid = 1}) == .Inject_Error_Code, "exception %v pushes no error code", vector)
	}
	// An interrupt pushes no error code.
	testing.expect_value(t, refusal_of({inject_kind = u8(Guest_Inject_Kind.External_Interrupt), inject_vector = 32, inject_error_code_valid = 1}), Guest_Registers_Refusal.Inject_Error_Code)
	testing.expect_value(t, refusal_of({inject_kind = u8(Guest_Inject_Kind.Software_Interrupt), inject_vector = 0x80, inject_error_code = 4}), Guest_Registers_Refusal.Inject_Error_Code)
	// The reserved word.
	testing.expect_value(t, refusal_of({reserved = 1}), Guest_Registers_Refusal.Reserved)
	testing.expect_value(t, refusal_of({reserved = max(u32)}), Guest_Registers_Refusal.Reserved)
	// The successful cases last.
	for vector in ([?]u8{8, 10, 11, 12, 13, 14, 17, 21, 29, 30}) {
		testing.expectf(t, refusal_of({inject_kind = u8(Guest_Inject_Kind.Exception), inject_vector = vector, inject_error_code_valid = 1, inject_error_code = max(u32)}) == .None, "exception %v with its error code", vector)
		testing.expectf(t, refusal_of({inject_kind = u8(Guest_Inject_Kind.Exception), inject_vector = vector}) == .None, "exception %v in real mode, with no error code", vector)
	}
	for vector in ([?]u8{0, 8, 32, max(u8)}) {
		testing.expectf(t, refusal_of({inject_kind = u8(Guest_Inject_Kind.External_Interrupt), inject_vector = vector}) == .None, "external vector %v", vector)
		testing.expectf(t, refusal_of({inject_kind = u8(Guest_Inject_Kind.Software_Interrupt), inject_vector = vector}) == .None, "software vector %v", vector)
	}
	testing.expect_value(t, refusal_of({inject_kind = u8(Guest_Inject_Kind.Non_Maskable_Interrupt), inject_vector = 2}), Guest_Registers_Refusal.None)
	testing.expect_value(t, u8(max(Guest_Inject_Kind)), u8(4))
}

// The procedure that says if a record is refused agrees with the reason
// that the checks give, and the checks give the requests as members.
@(test)
guest_registers_refusal_agrees_with_the_check :: proc(t: ^testing.T) {
	records := [?]Guest_Registers{{}, {rflags = max(u64)}, {cr4 = u64(1) << 13}, {mode_load = max(u8)}, {inject_kind = 5}, {reserved = 1}, LONG_MODE_REGISTERS}
	for registers in records {
		testing.expect_value(t, guest_registers_refusal(registers), refusal_of(registers) != .None)
	}
	long := LONG_MODE_REGISTERS
	long.mode_load = u8(Guest_Mode_Load.Long_64)
	long.inject_kind = u8(Guest_Inject_Kind.External_Interrupt)
	long.inject_vector = 0x30
	requests, refusal := guest_registers_check(long)
	testing.expect_value(t, refusal, Guest_Registers_Refusal.None)
	testing.expect_value(t, requests, Guest_Requests{mode_load = .Long_64, inject_kind = .External_Interrupt})
	// A refused record gives no request.
	long.inject_vector = 0
	long.inject_error_code = 1
	requests, refusal = guest_registers_check(long)
	testing.expect_value(t, refusal, Guest_Registers_Refusal.Inject_Error_Code)
	testing.expect_value(t, requests, Guest_Requests{})
}

// The index of a guest processor: 0 to 3, nothing past.
@(test)
guest_processor_index_bounds :: proc(t: ^testing.T) {
	for word in ([?]u64{GUEST_PROCESSOR_CAPACITY, GUEST_PROCESSOR_CAPACITY + 1, u64(max(u32)), u64(max(u32)) + 1, max(u64)}) {
		_, ok := guest_processor_of_word(word)
		testing.expectf(t, !ok, "processor word %v is refused", word)
	}
	for word in 0 ..< u64(GUEST_PROCESSOR_CAPACITY) {
		index, ok := guest_processor_of_word(word)
		testing.expectf(t, ok && u64(index) == word, "processor word %v", word)
	}
	testing.expect_value(t, GUEST_PROCESSOR_CAPACITY, 4)
	// The form of the argument names the same bound for the error record.
	testing.expect_value(t, OPERATIONS[.Guest_Run].parameters[2].form, Form.Bounded)
	testing.expect_value(t, OPERATIONS[.Guest_Run].parameters[2].limit, u64(GUEST_PROCESSOR_CAPACITY - 1))
	problem, limit := argument_value_problem(.Guest_Run, 2, {0, 0, GUEST_PROCESSOR_CAPACITY, 0, 0, 0, 0})
	testing.expect_value(t, problem, errors.Kind.Bad_Value)
	testing.expect_value(t, limit, u64(GUEST_PROCESSOR_CAPACITY - 1))
	problem, _ = argument_value_problem(.Guest_Run, 2, {0, 0, GUEST_PROCESSOR_CAPACITY - 1, 0, 0, 0, 0})
	testing.expect_value(t, problem, errors.Kind.None)
}
