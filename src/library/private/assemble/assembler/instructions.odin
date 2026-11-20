package assembler

// The instructions of the subset and their encodings (src/md/features/assembler.md,
// "The subset"). Each form has one encoding, the one of the Intel manual
// that the comment of its case names, so a label never changes the size of
// an instruction.

// What an instruction does.
Operation :: enum u8 {
	Move         = 0, // mov
	Add          = 1, // add
	Subtract     = 2, // sub
	Compare      = 3, // cmp
	Load_Address = 4, // lea
	Push         = 5, // push
	Pop          = 6, // pop
	Jump         = 7, // jmp
	Jump_If      = 8, // the 16 conditional jumps
	Call         = 9, // call
	Return       = 10, // ret
}

// The condition of a conditional jump: its value is the low 4 bits of the
// opcode 0F 80+cc of the Intel manual.
Condition :: enum u8 {
	Overflow         = 0x0, // jo
	Not_Overflow     = 0x1, // jno
	Below            = 0x2, // jb
	Above_Or_Equal   = 0x3, // jae
	Equal            = 0x4, // je
	Not_Equal        = 0x5, // jne
	Below_Or_Equal   = 0x6, // jbe
	Above            = 0x7, // ja
	Sign             = 0x8, // js
	Not_Sign         = 0x9, // jns
	Parity           = 0xA, // jp
	Not_Parity       = 0xB, // jnp
	Less             = 0xC, // jl
	Greater_Or_Equal = 0xD, // jge
	Less_Or_Equal    = 0xE, // jle
	Greater          = 0xF, // jg
}

// The size of an operation.
Operand_Size :: enum u8 {
	Unknown = 0, // No suffix and no register gives it yet.
	Bits_32 = 1, // The suffix `l`, or a register such as %eax.
	Bits_64 = 2, // The suffix `q`, or a register such as %rax.
}

// A register: its number in the encoding, 0 to 15, and its size.
Register :: struct {
	number: u8,
	size:   Operand_Size,
}

@(private)
Register_Name :: struct {
	name:     string,
	register: Register,
}

// The registers of the subset. The number is the one of the Intel manual:
// its low 3 bits go in the ModRM byte, its bit 3 in the prefix REX.
@(private, rodata)
REGISTER_NAMES := [?]Register_Name {
	{"rax", {0, .Bits_64}}, {"rcx", {1, .Bits_64}}, {"rdx", {2, .Bits_64}}, {"rbx", {3, .Bits_64}},
	{"rsp", {4, .Bits_64}}, {"rbp", {5, .Bits_64}}, {"rsi", {6, .Bits_64}}, {"rdi", {7, .Bits_64}},
	{"r8", {8, .Bits_64}}, {"r9", {9, .Bits_64}}, {"r10", {10, .Bits_64}}, {"r11", {11, .Bits_64}},
	{"r12", {12, .Bits_64}}, {"r13", {13, .Bits_64}}, {"r14", {14, .Bits_64}}, {"r15", {15, .Bits_64}},
	{"eax", {0, .Bits_32}}, {"ecx", {1, .Bits_32}}, {"edx", {2, .Bits_32}}, {"ebx", {3, .Bits_32}},
	{"esp", {4, .Bits_32}}, {"ebp", {5, .Bits_32}}, {"esi", {6, .Bits_32}}, {"edi", {7, .Bits_32}},
	{"r8d", {8, .Bits_32}}, {"r9d", {9, .Bits_32}}, {"r10d", {10, .Bits_32}}, {"r11d", {11, .Bits_32}},
	{"r12d", {12, .Bits_32}}, {"r13d", {13, .Bits_32}}, {"r14d", {14, .Bits_32}}, {"r15d", {15, .Bits_32}},
}

@(private)
Mnemonic :: struct {
	name:       string,
	operation:  Operation,
	condition:  Condition,
	suffixable: bool, // The name takes the suffix `q` or `l`.
}

@(private, rodata)
MNEMONICS := [?]Mnemonic {
	{name = "mov", operation = .Move, suffixable = true},
	{name = "add", operation = .Add, suffixable = true},
	{name = "sub", operation = .Subtract, suffixable = true},
	{name = "cmp", operation = .Compare, suffixable = true},
	{name = "lea", operation = .Load_Address, suffixable = true},
	{name = "push", operation = .Push, suffixable = true},
	{name = "pop", operation = .Pop, suffixable = true},
	{name = "jmp", operation = .Jump},
	{name = "call", operation = .Call},
	{name = "ret", operation = .Return},
	{name = "jo", operation = .Jump_If, condition = .Overflow},
	{name = "jno", operation = .Jump_If, condition = .Not_Overflow},
	{name = "jb", operation = .Jump_If, condition = .Below},
	{name = "jae", operation = .Jump_If, condition = .Above_Or_Equal},
	{name = "je", operation = .Jump_If, condition = .Equal},
	{name = "jne", operation = .Jump_If, condition = .Not_Equal},
	{name = "jbe", operation = .Jump_If, condition = .Below_Or_Equal},
	{name = "ja", operation = .Jump_If, condition = .Above},
	{name = "js", operation = .Jump_If, condition = .Sign},
	{name = "jns", operation = .Jump_If, condition = .Not_Sign},
	{name = "jp", operation = .Jump_If, condition = .Parity},
	{name = "jnp", operation = .Jump_If, condition = .Not_Parity},
	{name = "jl", operation = .Jump_If, condition = .Less},
	{name = "jge", operation = .Jump_If, condition = .Greater_Or_Equal},
	{name = "jle", operation = .Jump_If, condition = .Less_Or_Equal},
	{name = "jg", operation = .Jump_If, condition = .Greater},
}

// mnemonic_of_word reads a mnemonic, with its suffix of size when it has
// one: `movq` is `mov` of 64 bits, `addl` is `add` of 32 bits.
@(private)
mnemonic_of_word :: proc "contextless" (word: string) -> (mnemonic: Mnemonic, size: Operand_Size, ok: bool) {
	for item in MNEMONICS {
		if item.name == word {
			return item, .Unknown, true
		}
	}
	if len(word) < 2 {
		return {}, .Unknown, false
	}
	stem := word[:len(word) - 1]
	switch word[len(word) - 1] {
	case 'q':
		size = .Bits_64
	case 'l':
		size = .Bits_32
	case:
		return {}, .Unknown, false
	}
	for item in MNEMONICS {
		if item.suffixable && item.name == stem {
			return item, size, true
		}
	}
	return {}, .Unknown, false
}

// The kinds of operands that the syntax reads.
Operand_Kind :: enum u8 {
	Register  = 0, // %rax
	Immediate = 1, // $42
	Memory    = 2, // 8(%rbp), table(%rip)
	Label     = 3, // the target of a jump or a call
}

@(private)
Operand :: struct {
	kind:                        Operand_Kind,
	register:                    Register, // A Register; the base of a Memory.
	base_is_instruction_pointer: bool, // A Memory: the base is %rip.
	value:                       i128, // An Immediate: its value. A Memory: its displacement.
	label:                       int, // A Label, or a Memory whose displacement is a label: the index of the label. -1: none.
	place:                       Place,
}

// operand_read reads one operand: `%register`, `$number`, `displacement(%base)`
// with a number or a label as its displacement, or a label alone.
@(private)
operand_read :: proc "contextless" (cursor: ^Cursor, workspace: ^Workspace) -> (operand: Operand, refusal: Refusal_Record) {
	blanks_skip(cursor)
	operand = {label = -1, place = place_here(cursor)}
	if cursor.position >= cursor.end {
		return operand, refuse(.Operand_Not_Valid, operand.place)
	}
	switch cursor.text[cursor.position] {
	case '%':
		cursor.position += 1
		name := word_read(cursor)
		if name == "rip" {
			return operand, refuse(.Operand_Not_Valid, operand.place)
		}
		register, known := register_of_name(name)
		if !known {
			return operand, refuse(.Register_Unknown, operand.place)
		}
		operand.kind = .Register
		operand.register = register
		return operand, {}
	case '$':
		cursor.position += 1
		value, ok := signed_number_read(cursor)
		if !ok {
			return operand, refuse(.Number_Not_Valid, operand.place)
		}
		operand.kind = .Immediate
		operand.value = value
		return operand, {}
	}
	label_name := ""
	character := cursor.text[cursor.position]
	if character == '-' || is_digit(character) {
		value, ok := signed_number_read(cursor)
		if !ok {
			return operand, refuse(.Number_Not_Valid, operand.place)
		}
		operand.value = value
	} else if character != '(' {
		label_name = word_read(cursor)
		if label_name == "" {
			return operand, refuse(.Operand_Not_Valid, operand.place)
		}
		if refusal = label_name_check(label_name, operand.place); refusal.refusal != .None {
			return operand, refusal
		}
	}
	if cursor.position < cursor.end && cursor.text[cursor.position] == '(' {
		cursor.position += 1
		blanks_skip(cursor)
		base_place := place_here(cursor)
		if cursor.position >= cursor.end || cursor.text[cursor.position] != '%' {
			return operand, refuse(.Operand_Not_Valid, base_place)
		}
		cursor.position += 1
		name := word_read(cursor)
		if name == "rip" {
			operand.base_is_instruction_pointer = true
		} else {
			register, known := register_of_name(name)
			if !known {
				return operand, refuse(.Register_Unknown, base_place)
			}
			if register.size != .Bits_64 {
				return operand, refuse(.Operand_Size_Wrong, base_place)
			}
			operand.register = register
		}
		// An index register (`(%rax,%rbx,8)`) is not in the subset.
		if !next_is(cursor, ')') {
			return operand, refuse(.Operand_Not_Valid, place_here(cursor))
		}
		// A label reached from a register other than %rip is an absolute
		// address, which needs a rebase.
		if label_name != "" && !operand.base_is_instruction_pointer {
			return operand, refuse(.Operand_Not_Valid, operand.place)
		}
		operand.kind = .Memory
	} else if label_name != "" {
		operand.kind = .Label
	} else {
		// A number alone is an absolute address.
		return operand, refuse(.Operand_Not_Valid, operand.place)
	}
	if label_name != "" {
		if operand.label, refusal = label_named(workspace, label_name, operand.place); refusal.refusal != .None {
			return operand, refusal
		}
	}
	return operand, {}
}

@(private)
register_of_name :: proc "contextless" (name: string) -> (register: Register, ok: bool) {
	for item in REGISTER_NAMES {
		if item.name == name {
			return item.register, true
		}
	}
	return {}, false
}

// The bytes of one instruction, before they go into the code.
@(private)
Encoding :: struct {
	bytes:           [16]u8,
	count:           int,
	reference_field: int, // The offset of the 4 bytes of a reference in the instruction; -1: none.
	reference_label: int,
	reference_kind:  Reference_Kind,
	reference_place: Place,
}

@(private)
put_byte :: proc "contextless" (encoding: ^Encoding, value: u8) {
	encoding.bytes[encoding.count] = value
	encoding.count += 1
}

@(private)
put_u32 :: proc "contextless" (encoding: ^Encoding, value: u32) {
	for shift := u32(0); shift < 32; shift += 8 {
		put_byte(encoding, u8(value >> shift))
	}
}

@(private)
put_u64 :: proc "contextless" (encoding: ^Encoding, value: u64) {
	for shift := u64(0); shift < 64; shift += 8 {
		put_byte(encoding, u8(value >> shift))
	}
}

// put_prefix writes the prefix REX when one of its bits is set: W for a
// 64-bit operation, R for bit 3 of the field reg of ModRM, B for bit 3 of
// the field rm, of the base, or of the register of the opcode.
@(private)
put_prefix :: proc "contextless" (encoding: ^Encoding, wide: bool, reg_number: u8, rm_number: u8) {
	prefix := u8(0x40)
	if wide {
		prefix |= 0x08
	}
	prefix |= (reg_number >> 3 & 1) << 2
	prefix |= rm_number >> 3 & 1
	if prefix != 0x40 {
		put_byte(encoding, prefix)
	}
}

@(private)
modrm :: proc "contextless" (mode: u8, reg_field: u8, rm_field: u8) -> u8 {
	return mode << 6 | (reg_field & 7) << 3 | rm_field & 7
}

@(private)
fits_signed_8 :: proc "contextless" (value: i128) -> bool {
	return value >= -128 && value <= 127
}

@(private)
fits_signed_32 :: proc "contextless" (value: i128) -> bool {
	return value >= i128(min(i32)) && value <= i128(max(i32))
}

// The number of the base of a memory operand for the prefix REX: %rip
// sets no bit.
@(private)
base_number :: proc "contextless" (operand: Operand) -> u8 {
	return operand.base_is_instruction_pointer ? 0 : operand.register.number
}

// put_memory writes ModRM, SIB and the displacement of a memory operand.
//
// - %rip: ModRM 00 reg 101 and 4 bytes; a label gives a reference.
// - A base with a displacement 0: ModRM 00, but %rbp and %r13, whose 00
//   form means %rip or no base, take 01 and one byte 0.
// - A displacement of one byte with a sign: ModRM 01; else 10 and 4 bytes.
// - %rsp and %r12, whose rm 100 means "a byte SIB follows", take SIB 24:
//   no index, the base alone.
@(private)
put_memory :: proc "contextless" (encoding: ^Encoding, reg_field: u8, operand: Operand) -> Refusal_Record {
	if operand.base_is_instruction_pointer {
		put_byte(encoding, modrm(0, reg_field, 5))
		if operand.label >= 0 {
			encoding.reference_field = encoding.count
			encoding.reference_label = operand.label
			encoding.reference_kind = .Address
			encoding.reference_place = operand.place
			put_u32(encoding, 0)
			return {}
		}
		if !fits_signed_32(operand.value) {
			return refuse(.Displacement_Too_Large, operand.place)
		}
		put_u32(encoding, u32(i32(operand.value)))
		return {}
	}
	if !fits_signed_32(operand.value) {
		return refuse(.Displacement_Too_Large, operand.place)
	}
	low := operand.register.number & 7
	mode: u8
	switch {
	case operand.value == 0 && low != 5:
		mode = 0
	case fits_signed_8(operand.value):
		mode = 1
	case:
		mode = 2
	}
	put_byte(encoding, modrm(mode, reg_field, low))
	if low == 4 {
		put_byte(encoding, 0x24)
	}
	switch mode {
	case 1:
		put_byte(encoding, u8(i8(operand.value)))
	case 2:
		put_u32(encoding, u32(i32(operand.value)))
	}
	return {}
}

// The opcodes of the operations of two operands (Intel manual, volume 2):
// `store` is the form r/m ← reg (MOV 89, ADD 01, SUB 29, CMP 39), `load`
// the form reg ← r/m (8B, 03, 2B, 3B), `extension` the field reg of the
// forms with an immediate (MOV C7 /0, ADD 83 or 81 /0, SUB /5, CMP /7).
@(private)
Two_Operand_Opcodes :: struct {
	store:     u8,
	load:      u8,
	extension: u8,
}

@(private)
two_operand_opcodes :: proc "contextless" (operation: Operation) -> (opcodes: Two_Operand_Opcodes, ok: bool) {
	switch operation {
	case .Move:
		return {store = 0x89, load = 0x8B, extension = 0}, true
	case .Add:
		return {store = 0x01, load = 0x03, extension = 0}, true
	case .Subtract:
		return {store = 0x29, load = 0x2B, extension = 5}, true
	case .Compare:
		return {store = 0x39, load = 0x3B, extension = 7}, true
	case .Load_Address, .Push, .Pop, .Jump, .Jump_If, .Call, .Return:
	}
	return {}, false
}

// failed says if a step refused: the caller then returns its record.
@(private)
failed :: proc "contextless" (refusal: Refusal_Record) -> bool {
	return refusal.refusal != .None
}

// instruction_read reads the operands of an instruction, encodes it, and
// writes it at the end of the code.
@(private)
instruction_read :: proc "contextless" (cursor: ^Cursor, workspace: ^Workspace, word: string, word_place: Place) -> Refusal_Record {
	mnemonic, suffix_size, known := mnemonic_of_word(word)
	if !known {
		return refuse(.Mnemonic_Unknown, word_place)
	}
	if cursor.section^ != .Code {
		return refuse(.Instruction_In_Data, word_place)
	}
	operands: [2]Operand
	count := 0
	if !at_end(cursor) {
		for {
			if count == len(operands) {
				// A third operand: count each one, for the value of the record.
				blanks_skip(cursor)
				return refuse(.Operand_Count_Wrong, place_here(cursor), u64(count + 1))
			}
			refusal: Refusal_Record
			if operands[count], refusal = operand_read(cursor, workspace); refusal.refusal != .None {
				return refusal
			}
			count += 1
			if at_end(cursor) {
				break
			}
			if !next_is(cursor, ',') {
				return refuse(.Operand_Not_Valid, place_here(cursor))
			}
		}
	}
	encoding := Encoding {
		reference_field = -1,
	}
	if refusal := instruction_encode(&encoding, mnemonic, suffix_size, operands[:count], word_place); refusal.refusal != .None {
		return refusal
	}
	start := workspace.extents[.Code]
	if refusal := section_write(workspace, .Code, encoding.bytes[:encoding.count], word_place); refusal.refusal != .None {
		return refusal
	}
	if encoding.reference_field >= 0 {
		if workspace.reference_count == REFERENCE_CAPACITY {
			return refuse(.References_Full, encoding.reference_place, REFERENCE_CAPACITY)
		}
		workspace.references[workspace.reference_count] = {
			label           = encoding.reference_label,
			kind            = encoding.reference_kind,
			field_offset    = start + u64(encoding.reference_field),
			instruction_end = start + u64(encoding.count),
			place           = encoding.reference_place,
		}
		workspace.reference_count += 1
	}
	return {}
}

// operation_size gives the size of an operation of two operands: the
// suffix, and each register that is not the base of a memory operand. The
// sizes must agree.
@(private)
operation_size :: proc "contextless" (suffix_size: Operand_Size, operands: []Operand) -> (size: Operand_Size, refusal: Refusal_Record) {
	size = suffix_size
	for operand in operands {
		if operand.kind != .Register {
			continue
		}
		if size == .Unknown {
			size = operand.register.size
		} else if size != operand.register.size {
			return size, refuse(.Operand_Size_Wrong, operand.place)
		}
	}
	return size, {}
}

// instruction_encode writes the bytes of one instruction.
@(private)
instruction_encode :: proc "contextless" (encoding: ^Encoding, mnemonic: Mnemonic, suffix_size: Operand_Size, operands: []Operand, word_place: Place) -> Refusal_Record {
	// The operations by their count of operands.
	wanted := 2
	switch mnemonic.operation {
	case .Return:
		wanted = 0
	case .Jump, .Call, .Jump_If, .Push, .Pop:
		wanted = 1
	case .Move, .Add, .Subtract, .Compare, .Load_Address:
	}
	if len(operands) != wanted {
		return refuse(.Operand_Count_Wrong, word_place, u64(len(operands)))
	}
	switch mnemonic.operation {
	case .Return:
		// RET: C3.
		put_byte(encoding, 0xC3)
	case .Jump, .Call, .Jump_If:
		// JMP rel32: E9 cd. CALL rel32: E8 cd. Jcc rel32: 0F 80+cc cd.
		target := operands[0]
		if target.kind != .Label {
			return refuse(.Operand_Form_Not_Valid, target.place)
		}
		if mnemonic.operation == .Jump {
			put_byte(encoding, 0xE9)
		} else if mnemonic.operation == .Call {
			put_byte(encoding, 0xE8)
		} else {
			put_byte(encoding, 0x0F)
			put_byte(encoding, 0x80 | u8(mnemonic.condition))
		}
		encoding.reference_field = encoding.count
		encoding.reference_label = target.label
		encoding.reference_kind = .Jump_Target
		encoding.reference_place = target.place
		put_u32(encoding, 0)
	case .Push, .Pop:
		operand := operands[0]
		switch operand.kind {
		case .Register:
			// PUSH r64: 50+rd. POP r64: 58+rd. No form of 32 bits exists in
			// the 64-bit mode.
			if operand.register.size != .Bits_64 {
				return refuse(.Operand_Size_Wrong, operand.place)
			}
			if suffix_size == .Bits_32 {
				return refuse(.Operand_Size_Wrong, word_place)
			}
			put_prefix(encoding, false, 0, operand.register.number)
			opcode := mnemonic.operation == .Push ? u8(0x50) : u8(0x58)
			put_byte(encoding, opcode + operand.register.number & 7)
		case .Immediate:
			// PUSH imm8: 6A ib. PUSH imm32: 68 id, extended to 64 bits.
			if mnemonic.operation != .Push {
				return refuse(.Operand_Form_Not_Valid, operand.place)
			}
			if suffix_size == .Bits_32 {
				return refuse(.Operand_Size_Wrong, word_place)
			}
			switch {
			case fits_signed_8(operand.value):
				put_byte(encoding, 0x6A)
				put_byte(encoding, u8(i8(operand.value)))
			case fits_signed_32(operand.value):
				put_byte(encoding, 0x68)
				put_u32(encoding, u32(i32(operand.value)))
			case:
				return refuse(.Immediate_Too_Large, operand.place)
			}
		case .Memory, .Label:
			return refuse(.Operand_Form_Not_Valid, operand.place)
		}
	case .Load_Address:
		// LEA r64, m: REX.W 8D /r.
		source, destination := operands[0], operands[1]
		if source.kind != .Memory {
			return refuse(.Operand_Form_Not_Valid, source.place)
		}
		if destination.kind != .Register {
			return refuse(.Operand_Form_Not_Valid, destination.place)
		}
		if destination.register.size != .Bits_64 {
			return refuse(.Operand_Size_Wrong, destination.place)
		}
		if suffix_size == .Bits_32 {
			return refuse(.Operand_Size_Wrong, word_place)
		}
		put_prefix(encoding, true, destination.register.number, base_number(source))
		put_byte(encoding, 0x8D)
		return put_memory(encoding, destination.register.number, source)
	case .Move, .Add, .Subtract, .Compare:
		return two_operand_encode(encoding, mnemonic.operation, suffix_size, operands[0], operands[1], word_place)
	}
	return {}
}

// two_operand_encode writes mov, add, sub and cmp: the source first, as
// the syntax of AT&T writes it.
@(private)
two_operand_encode :: proc "contextless" (encoding: ^Encoding, operation: Operation, suffix_size: Operand_Size, source: Operand, destination: Operand, word_place: Place) -> Refusal_Record {
	operands := [2]Operand{source, destination}
	size, refusal := operation_size(suffix_size, operands[:])
	if refusal.refusal != .None {
		return refusal
	}
	opcodes, has_opcodes := two_operand_opcodes(operation)
	if !has_opcodes {
		return refuse(.Mnemonic_Unknown, word_place)
	}
	destination_ok := destination.kind == .Register || destination.kind == .Memory
	source_ok := source.kind == .Register || source.kind == .Immediate || source.kind == .Memory && destination.kind == .Register
	if source.kind == .Label || !source_ok {
		return refuse(.Operand_Form_Not_Valid, source.place)
	}
	if !destination_ok {
		return refuse(.Operand_Form_Not_Valid, destination.place)
	}
	if size == .Unknown {
		return refuse(.Operand_Size_Unknown, word_place)
	}
	wide := size == .Bits_64
	switch source.kind {
	case .Register:
		// MOV r/m, r: 89 /r. ADD 01 /r, SUB 29 /r, CMP 39 /r.
		if destination.kind == .Register {
			put_prefix(encoding, wide, source.register.number, destination.register.number)
			put_byte(encoding, opcodes.store)
			put_byte(encoding, modrm(3, source.register.number, destination.register.number))
			return {}
		}
		put_prefix(encoding, wide, source.register.number, base_number(destination))
		put_byte(encoding, opcodes.store)
		return put_memory(encoding, source.register.number, destination)
	case .Memory:
		// MOV r, r/m: 8B /r. ADD 03 /r, SUB 2B /r, CMP 3B /r.
		put_prefix(encoding, wide, destination.register.number, base_number(source))
		put_byte(encoding, opcodes.load)
		return put_memory(encoding, destination.register.number, source)
	case .Immediate:
		return immediate_encode(encoding, operation, opcodes, wide, source, destination)
	case .Label:
	}
	return refuse(.Operand_Form_Not_Valid, source.place)
}

// immediate_encode writes an operation of an immediate on a register or on
// memory.
//
// - A 64-bit operation takes an immediate of 32 bits with a sign, which
//   the processor extends; `mov` to a register alone takes 64 bits, with
//   REX.W B8+rd io.
// - A 32-bit operation takes -2^31 to 2^32 - 1: the 32 bits of the value.
@(private)
immediate_encode :: proc "contextless" (encoding: ^Encoding, operation: Operation, opcodes: Two_Operand_Opcodes, wide: bool, source: Operand, destination: Operand) -> Refusal_Record {
	value := source.value
	if wide {
		long_move := operation == .Move && destination.kind == .Register && !fits_signed_32(value)
		if long_move {
			// MOV r64, imm64: REX.W B8+rd io.
			if value < i128(min(i64)) || value > i128(max(u64)) {
				return refuse(.Immediate_Too_Large, source.place)
			}
			put_prefix(encoding, true, 0, destination.register.number)
			put_byte(encoding, 0xB8 + destination.register.number & 7)
			put_u64(encoding, u64(value & i128(max(u64))))
			return {}
		}
		if !fits_signed_32(value) {
			return refuse(.Immediate_Too_Large, source.place)
		}
	} else {
		if value < i128(min(i32)) || value > i128(max(u32)) {
			return refuse(.Immediate_Too_Large, source.place)
		}
		if value > i128(max(i32)) {
			value -= i128(1) << 32
		}
	}
	if operation == .Move {
		if destination.kind == .Register && !wide {
			// MOV r32, imm32: B8+rd id.
			put_prefix(encoding, false, 0, destination.register.number)
			put_byte(encoding, 0xB8 + destination.register.number & 7)
			put_u32(encoding, u32(i32(value)))
			return {}
		}
		// MOV r/m, imm32: C7 /0 id.
		put_prefix(encoding, wide, 0, destination.kind == .Register ? destination.register.number : base_number(destination))
		put_byte(encoding, 0xC7)
		if destination.kind == .Register {
			put_byte(encoding, modrm(3, 0, destination.register.number))
		} else if refusal := put_memory(encoding, 0, destination); failed(refusal) {
			return refusal
		}
		put_u32(encoding, u32(i32(value)))
		return {}
	}
	// ADD, SUB, CMP r/m, imm8: 83 /n ib; r/m, imm32: 81 /n id.
	short := fits_signed_8(value)
	put_prefix(encoding, wide, 0, destination.kind == .Register ? destination.register.number : base_number(destination))
	put_byte(encoding, short ? u8(0x83) : u8(0x81))
	if destination.kind == .Register {
		put_byte(encoding, modrm(3, opcodes.extension, destination.register.number))
	} else if refusal := put_memory(encoding, opcodes.extension, destination); failed(refusal) {
		return refusal
	}
	if short {
		put_byte(encoding, u8(i8(value)))
	} else {
		put_u32(encoding, u32(i32(value)))
	}
	return {}
}
