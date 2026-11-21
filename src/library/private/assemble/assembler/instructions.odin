package assembler

// The instructions of the subset and their encodings (src/md/features/assembler.md,
// "The subset"). Each form has one encoding, the one of the Intel manual
// that the comment of its case names, so a label never changes the size of
// an instruction.

// What an instruction does.
Operation :: enum u8 {
	Move                         = 0, // mov
	Add                          = 1, // add
	Subtract                     = 2, // sub
	Compare                      = 3, // cmp
	Load_Address                 = 4, // lea
	Push                         = 5, // push
	Pop                          = 6, // pop
	Jump                         = 7, // jmp
	Jump_If                      = 8, // the 16 conditional jumps
	Call                         = 9, // call
	Return                       = 10, // ret
	Move_Sign_Extended           = 11, // movsxd, movslq, movsbw, movsbl, movsbq, movswl, movswq, movsb, movsw, movsx
	Move_Zero_Extended           = 12, // movzbw, movzbl, movzbq, movzwl, movzwq, movzb, movzw, movzx
	Bitwise_And                  = 13, // and
	Bitwise_Or                   = 14, // or
	Bitwise_Xor                  = 15, // xor
	Test                         = 16, // test
	Multiply_Signed              = 17, // imul
	Divide_Signed                = 18, // idiv
	Divide_Unsigned              = 19, // div
	Negate                       = 20, // neg
	Bitwise_Not                  = 21, // not
	Increment                    = 22, // inc
	Decrement                    = 23, // dec
	Shift_Left                   = 24, // shl, sal
	Shift_Right_Logical          = 25, // shr
	Shift_Right_Arithmetic       = 26, // sar
	Set_If                       = 27, // the 16 conditional byte sets
	Sign_Extend_Byte_To_Word     = 28, // cbw
	Sign_Extend_Word_To_Long     = 29, // cwtl, cwde
	Sign_Extend_Long_To_Quad     = 30, // cltq, cdqe
	Sign_Extend_Word_To_Double   = 31, // cwd
	Sign_Extend_Long_To_Double   = 32, // cdq, cltd
	Sign_Extend_Quad_To_Octaword = 33, // cqo, cqto
	Store_Byte                   = 34, // stosb
	Repeat_Store_Byte            = 35, // rep stosb
}

// The condition of a conditional jump or conditional set: its value is the
// low 4 bits of the opcodes 0F 80+cc and 0F 90+cc of the Intel manual.
Condition :: enum u8 {
	Overflow         = 0x0, // jo, seto
	Not_Overflow     = 0x1, // jno, setno
	Below            = 0x2, // jb, setb
	Above_Or_Equal   = 0x3, // jae, setae
	Equal            = 0x4, // je, sete
	Not_Equal        = 0x5, // jne, setne
	Below_Or_Equal   = 0x6, // jbe, setbe
	Above            = 0x7, // ja, seta
	Sign             = 0x8, // js, sets
	Not_Sign         = 0x9, // jns, setns
	Parity           = 0xA, // jp, setp
	Not_Parity       = 0xB, // jnp, setnp
	Less             = 0xC, // jl, setl
	Greater_Or_Equal = 0xD, // jge, setge
	Less_Or_Equal    = 0xE, // jle, setle
	Greater          = 0xF, // jg, setg
}

// The size of an operation.
Operand_Size :: enum u8 {
	Unknown = 0, // No suffix and no register gives it yet.
	Bits_8  = 1, // The suffix `b`, or an 8-bit register such as %al.
	Bits_16 = 2, // The suffix `w`, or a 16-bit register such as %ax.
	Bits_32 = 3, // The suffix `l`, or a 32-bit register such as %eax.
	Bits_64 = 4, // The suffix `q`, or a 64-bit register such as %rax.
}

// How an 8-bit register interacts with the prefix REX:
// - %spl, %bpl, %sil and %dil share the numbers 4 to 7 with %ah, %ch, %dh
//   and %bh, and need a prefix REX (0x40 when no other bit is set).
// - %ah, %ch, %dh and %bh cannot be encoded in an instruction that has any
//   prefix REX.
Register_Byte_Kind :: enum u8 {
	Standard  = 0,
	Low_Rex   = 1,
	High_Byte = 2,
}

// A register: its number in the encoding, 0 to 15, its size, and its REX
// rule when it is 8 bits.
Register :: struct {
	number:    u8,
	size:      Operand_Size,
	byte_kind: Register_Byte_Kind,
}

@(private)
Register_Name :: struct {
	name:     string,
	register: Register,
}

// The registers of x86-64. The number is the one of the Intel manual: its
// low 3 bits go in the ModRM or SIB byte, its bit 3 in the prefix REX.
@(private, rodata)
REGISTER_NAMES := [?]Register_Name {
	{"rax", {0, .Bits_64, .Standard}}, {"rcx", {1, .Bits_64, .Standard}}, {"rdx", {2, .Bits_64, .Standard}}, {"rbx", {3, .Bits_64, .Standard}},
	{"rsp", {4, .Bits_64, .Standard}}, {"rbp", {5, .Bits_64, .Standard}}, {"rsi", {6, .Bits_64, .Standard}}, {"rdi", {7, .Bits_64, .Standard}},
	{"r8", {8, .Bits_64, .Standard}}, {"r9", {9, .Bits_64, .Standard}}, {"r10", {10, .Bits_64, .Standard}}, {"r11", {11, .Bits_64, .Standard}},
	{"r12", {12, .Bits_64, .Standard}}, {"r13", {13, .Bits_64, .Standard}}, {"r14", {14, .Bits_64, .Standard}}, {"r15", {15, .Bits_64, .Standard}},
	{"eax", {0, .Bits_32, .Standard}}, {"ecx", {1, .Bits_32, .Standard}}, {"edx", {2, .Bits_32, .Standard}}, {"ebx", {3, .Bits_32, .Standard}},
	{"esp", {4, .Bits_32, .Standard}}, {"ebp", {5, .Bits_32, .Standard}}, {"esi", {6, .Bits_32, .Standard}}, {"edi", {7, .Bits_32, .Standard}},
	{"r8d", {8, .Bits_32, .Standard}}, {"r9d", {9, .Bits_32, .Standard}}, {"r10d", {10, .Bits_32, .Standard}}, {"r11d", {11, .Bits_32, .Standard}},
	{"r12d", {12, .Bits_32, .Standard}}, {"r13d", {13, .Bits_32, .Standard}}, {"r14d", {14, .Bits_32, .Standard}}, {"r15d", {15, .Bits_32, .Standard}},
	{"ax", {0, .Bits_16, .Standard}}, {"cx", {1, .Bits_16, .Standard}}, {"dx", {2, .Bits_16, .Standard}}, {"bx", {3, .Bits_16, .Standard}},
	{"sp", {4, .Bits_16, .Standard}}, {"bp", {5, .Bits_16, .Standard}}, {"si", {6, .Bits_16, .Standard}}, {"di", {7, .Bits_16, .Standard}},
	{"r8w", {8, .Bits_16, .Standard}}, {"r9w", {9, .Bits_16, .Standard}}, {"r10w", {10, .Bits_16, .Standard}}, {"r11w", {11, .Bits_16, .Standard}},
	{"r12w", {12, .Bits_16, .Standard}}, {"r13w", {13, .Bits_16, .Standard}}, {"r14w", {14, .Bits_16, .Standard}}, {"r15w", {15, .Bits_16, .Standard}},
	{"al", {0, .Bits_8, .Standard}}, {"cl", {1, .Bits_8, .Standard}}, {"dl", {2, .Bits_8, .Standard}}, {"bl", {3, .Bits_8, .Standard}},
	{"ah", {4, .Bits_8, .High_Byte}}, {"ch", {5, .Bits_8, .High_Byte}}, {"dh", {6, .Bits_8, .High_Byte}}, {"bh", {7, .Bits_8, .High_Byte}},
	{"spl", {4, .Bits_8, .Low_Rex}}, {"bpl", {5, .Bits_8, .Low_Rex}}, {"sil", {6, .Bits_8, .Low_Rex}}, {"dil", {7, .Bits_8, .Low_Rex}},
	{"r8b", {8, .Bits_8, .Standard}}, {"r9b", {9, .Bits_8, .Standard}}, {"r10b", {10, .Bits_8, .Standard}}, {"r11b", {11, .Bits_8, .Standard}},
	{"r12b", {12, .Bits_8, .Standard}}, {"r13b", {13, .Bits_8, .Standard}}, {"r14b", {14, .Bits_8, .Standard}}, {"r15b", {15, .Bits_8, .Standard}},
}

@(private)
Mnemonic :: struct {
	name:             string,
	operation:        Operation,
	condition:        Condition,
	source_size:      Operand_Size, // For extending moves: fixed source size, or Unknown.
	destination_size: Operand_Size, // For extending moves: fixed destination size, or Unknown.
	suffixable:       bool, // The name takes the suffix `b`, `w`, `l` or `q`.
}

@(private, rodata)
MNEMONICS := [?]Mnemonic {
	{name = "mov", operation = .Move, suffixable = true},
	{name = "add", operation = .Add, suffixable = true},
	{name = "sub", operation = .Subtract, suffixable = true},
	{name = "cmp", operation = .Compare, suffixable = true},
	{name = "and", operation = .Bitwise_And, suffixable = true},
	{name = "or", operation = .Bitwise_Or, suffixable = true},
	{name = "xor", operation = .Bitwise_Xor, suffixable = true},
	{name = "test", operation = .Test, suffixable = true},
	{name = "imul", operation = .Multiply_Signed, suffixable = true},
	{name = "idiv", operation = .Divide_Signed, suffixable = true},
	{name = "div", operation = .Divide_Unsigned, suffixable = true},
	{name = "neg", operation = .Negate, suffixable = true},
	{name = "not", operation = .Bitwise_Not, suffixable = true},
	{name = "inc", operation = .Increment, suffixable = true},
	{name = "dec", operation = .Decrement, suffixable = true},
	{name = "shl", operation = .Shift_Left, suffixable = true},
	{name = "sal", operation = .Shift_Left, suffixable = true},
	{name = "shr", operation = .Shift_Right_Logical, suffixable = true},
	{name = "sar", operation = .Shift_Right_Arithmetic, suffixable = true},
	{name = "lea", operation = .Load_Address, suffixable = true},
	{name = "push", operation = .Push, suffixable = true},
	{name = "pop", operation = .Pop, suffixable = true},
	{name = "jmp", operation = .Jump},
	{name = "call", operation = .Call},
	{name = "ret", operation = .Return},
	{name = "stosb", operation = .Store_Byte},
	// Zero-operand sign extensions.
	{name = "cbw", operation = .Sign_Extend_Byte_To_Word},
	{name = "cwtl", operation = .Sign_Extend_Word_To_Long},
	{name = "cwde", operation = .Sign_Extend_Word_To_Long},
	{name = "cltq", operation = .Sign_Extend_Long_To_Quad},
	{name = "cdqe", operation = .Sign_Extend_Long_To_Quad},
	{name = "cwd", operation = .Sign_Extend_Word_To_Double},
	{name = "cdq", operation = .Sign_Extend_Long_To_Double},
	{name = "cltd", operation = .Sign_Extend_Long_To_Double},
	{name = "cqo", operation = .Sign_Extend_Quad_To_Octaword},
	{name = "cqto", operation = .Sign_Extend_Quad_To_Octaword},
	// Sign-extending and zero-extending moves: the name states one, both,
	// or neither size; no extra suffix is accepted.
	{name = "movsbw", operation = .Move_Sign_Extended, source_size = .Bits_8, destination_size = .Bits_16},
	{name = "movsbl", operation = .Move_Sign_Extended, source_size = .Bits_8, destination_size = .Bits_32},
	{name = "movsbq", operation = .Move_Sign_Extended, source_size = .Bits_8, destination_size = .Bits_64},
	{name = "movswl", operation = .Move_Sign_Extended, source_size = .Bits_16, destination_size = .Bits_32},
	{name = "movswq", operation = .Move_Sign_Extended, source_size = .Bits_16, destination_size = .Bits_64},
	{name = "movslq", operation = .Move_Sign_Extended, source_size = .Bits_32, destination_size = .Bits_64},
	{name = "movsxd", operation = .Move_Sign_Extended, source_size = .Bits_32, destination_size = .Bits_64},
	{name = "movsb", operation = .Move_Sign_Extended, source_size = .Bits_8},
	{name = "movsw", operation = .Move_Sign_Extended, source_size = .Bits_16},
	{name = "movsx", operation = .Move_Sign_Extended},
	{name = "movzbw", operation = .Move_Zero_Extended, source_size = .Bits_8, destination_size = .Bits_16},
	{name = "movzbl", operation = .Move_Zero_Extended, source_size = .Bits_8, destination_size = .Bits_32},
	{name = "movzbq", operation = .Move_Zero_Extended, source_size = .Bits_8, destination_size = .Bits_64},
	{name = "movzwl", operation = .Move_Zero_Extended, source_size = .Bits_16, destination_size = .Bits_32},
	{name = "movzwq", operation = .Move_Zero_Extended, source_size = .Bits_16, destination_size = .Bits_64},
	{name = "movzb", operation = .Move_Zero_Extended, source_size = .Bits_8},
	{name = "movzw", operation = .Move_Zero_Extended, source_size = .Bits_16},
	{name = "movzx", operation = .Move_Zero_Extended},
	// Conditional jumps and their standard aliases.
	{name = "jo", operation = .Jump_If, condition = .Overflow},
	{name = "jno", operation = .Jump_If, condition = .Not_Overflow},
	{name = "jb", operation = .Jump_If, condition = .Below},
	{name = "jc", operation = .Jump_If, condition = .Below},
	{name = "jnae", operation = .Jump_If, condition = .Below},
	{name = "jae", operation = .Jump_If, condition = .Above_Or_Equal},
	{name = "jnb", operation = .Jump_If, condition = .Above_Or_Equal},
	{name = "jnc", operation = .Jump_If, condition = .Above_Or_Equal},
	{name = "je", operation = .Jump_If, condition = .Equal},
	{name = "jz", operation = .Jump_If, condition = .Equal},
	{name = "jne", operation = .Jump_If, condition = .Not_Equal},
	{name = "jnz", operation = .Jump_If, condition = .Not_Equal},
	{name = "jbe", operation = .Jump_If, condition = .Below_Or_Equal},
	{name = "jna", operation = .Jump_If, condition = .Below_Or_Equal},
	{name = "ja", operation = .Jump_If, condition = .Above},
	{name = "jnbe", operation = .Jump_If, condition = .Above},
	{name = "js", operation = .Jump_If, condition = .Sign},
	{name = "jns", operation = .Jump_If, condition = .Not_Sign},
	{name = "jp", operation = .Jump_If, condition = .Parity},
	{name = "jpe", operation = .Jump_If, condition = .Parity},
	{name = "jnp", operation = .Jump_If, condition = .Not_Parity},
	{name = "jpo", operation = .Jump_If, condition = .Not_Parity},
	{name = "jl", operation = .Jump_If, condition = .Less},
	{name = "jnge", operation = .Jump_If, condition = .Less},
	{name = "jge", operation = .Jump_If, condition = .Greater_Or_Equal},
	{name = "jnl", operation = .Jump_If, condition = .Greater_Or_Equal},
	{name = "jle", operation = .Jump_If, condition = .Less_Or_Equal},
	{name = "jng", operation = .Jump_If, condition = .Less_Or_Equal},
	{name = "jg", operation = .Jump_If, condition = .Greater},
	{name = "jnle", operation = .Jump_If, condition = .Greater},
	// Conditional byte sets and their standard aliases.
	{name = "seto", operation = .Set_If, condition = .Overflow},
	{name = "setno", operation = .Set_If, condition = .Not_Overflow},
	{name = "setb", operation = .Set_If, condition = .Below},
	{name = "setc", operation = .Set_If, condition = .Below},
	{name = "setnae", operation = .Set_If, condition = .Below},
	{name = "setae", operation = .Set_If, condition = .Above_Or_Equal},
	{name = "setnb", operation = .Set_If, condition = .Above_Or_Equal},
	{name = "setnc", operation = .Set_If, condition = .Above_Or_Equal},
	{name = "sete", operation = .Set_If, condition = .Equal},
	{name = "setz", operation = .Set_If, condition = .Equal},
	{name = "setne", operation = .Set_If, condition = .Not_Equal},
	{name = "setnz", operation = .Set_If, condition = .Not_Equal},
	{name = "setbe", operation = .Set_If, condition = .Below_Or_Equal},
	{name = "setna", operation = .Set_If, condition = .Below_Or_Equal},
	{name = "seta", operation = .Set_If, condition = .Above},
	{name = "setnbe", operation = .Set_If, condition = .Above},
	{name = "sets", operation = .Set_If, condition = .Sign},
	{name = "setns", operation = .Set_If, condition = .Not_Sign},
	{name = "setp", operation = .Set_If, condition = .Parity},
	{name = "setpe", operation = .Set_If, condition = .Parity},
	{name = "setnp", operation = .Set_If, condition = .Not_Parity},
	{name = "setpo", operation = .Set_If, condition = .Not_Parity},
	{name = "setl", operation = .Set_If, condition = .Less},
	{name = "setnge", operation = .Set_If, condition = .Less},
	{name = "setge", operation = .Set_If, condition = .Greater_Or_Equal},
	{name = "setnl", operation = .Set_If, condition = .Greater_Or_Equal},
	{name = "setle", operation = .Set_If, condition = .Less_Or_Equal},
	{name = "setng", operation = .Set_If, condition = .Less_Or_Equal},
	{name = "setg", operation = .Set_If, condition = .Greater},
	{name = "setnle", operation = .Set_If, condition = .Greater},
}

// mnemonic_of_word reads a mnemonic, with its suffix of size when it has
// one: `movq` is `mov` of 64 bits, `addl` is `add` of 32 bits, `movw` of
// 16 bits, `movb` of 8 bits.
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
	case 'w':
		size = .Bits_16
	case 'b':
		size = .Bits_8
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
	Register  = 0, // %rax, %eax, %ax, %al
	Immediate = 1, // $42
	Memory    = 2, // 8(%rbp), table(%rip), 16(%rax,%rcx,4), (,%rcx,8)
	Label     = 3, // the target of a direct jump or call
}

// The scale of an index register in a memory operand: its value is the
// 2-bit field ss of the byte SIB.
Index_Scale :: enum u8 {
	Scale_1 = 0,
	Scale_2 = 1,
	Scale_4 = 2,
	Scale_8 = 3,
}

@(private)
Operand :: struct {
	kind:                        Operand_Kind,
	indirect:                    bool, // `*` before a register or memory operand, for `call` and `jmp`.
	register:                    Register, // A Register; the base of a Memory when has_base is true.
	has_base:                    bool, // A Memory: a 64-bit base register is present.
	base_is_instruction_pointer: bool, // A Memory: the base is %rip.
	has_index:                   bool, // A Memory: an index register is present.
	index_register:              Register, // The index register of a Memory.
	scale:                       Index_Scale, // The scale of the index register.
	value:                       i128, // An Immediate: its value. A Memory: its displacement.
	label:                       int, // A Label, or a Memory whose displacement is a label: the index of the label. -1: none.
	place:                       Place,
}

// operand_read reads one operand: `%register`, `$number`,
// `displacement(base, index, scale)` with optional parts, `*register` or
// `*memory`, or a label alone.
@(private)
operand_read :: proc "contextless" (cursor: ^Cursor, workspace: ^Workspace) -> (operand: Operand, refusal: Refusal_Record) {
	blanks_skip(cursor)
	operand = {label = -1, place = place_here(cursor)}
	if cursor.position >= cursor.end {
		return operand, refuse(.Operand_Not_Valid, operand.place)
	}
	if cursor.text[cursor.position] == '*' {
		operand.indirect = true
		cursor.position += 1
		blanks_skip(cursor)
		if cursor.position >= cursor.end {
			return operand, refuse(.Operand_Not_Valid, operand.place)
		}
		// An indirect operand takes a register or memory only.
		if cursor.text[cursor.position] == '$' || cursor.text[cursor.position] == '*' {
			return operand, refuse(.Operand_Not_Valid, operand.place)
		}
	}
	switch cursor.text[cursor.position] {
	case '%':
		register_place := place_here(cursor)
		cursor.position += 1
		name := word_read(cursor)
		if name == "rip" {
			return operand, refuse(.Operand_Not_Valid, operand.place)
		}
		register, known := register_of_name(name)
		if !known {
			return operand, refuse(.Register_Unknown, register_place)
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
		if cursor.position >= cursor.end {
			return operand, refuse(.Operand_Not_Valid, place_here(cursor))
		}
		if cursor.text[cursor.position] == '%' {
			base_place := place_here(cursor)
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
				operand.has_base = true
			}
		} else if cursor.text[cursor.position] != ',' {
			return operand, refuse(.Operand_Not_Valid, place_here(cursor))
		}
		if next_is(cursor, ',') {
			if operand.base_is_instruction_pointer {
				// %rip-relative addressing has no SIB form.
				return operand, refuse(.Operand_Not_Valid, place_here(cursor))
			}
			blanks_skip(cursor)
			index_place := place_here(cursor)
			if cursor.position >= cursor.end || cursor.text[cursor.position] != '%' {
				return operand, refuse(.Operand_Not_Valid, index_place)
			}
			cursor.position += 1
			index_name := word_read(cursor)
			if index_name == "rip" {
				return operand, refuse(.Operand_Not_Valid, index_place)
			}
			index_register, known := register_of_name(index_name)
			if !known {
				return operand, refuse(.Register_Unknown, index_place)
			}
			if index_register.size != .Bits_64 {
				return operand, refuse(.Operand_Size_Wrong, index_place)
			}
			// SIB index 4 with REX.X = 0 means no index, so %rsp cannot be
			// an index register; %r12 has REX.X = 1 and is valid.
			if index_register.number == 4 {
				return operand, refuse(.Operand_Not_Valid, index_place)
			}
			operand.has_index = true
			operand.index_register = index_register
			operand.scale = .Scale_1
			if next_is(cursor, ',') {
				blanks_skip(cursor)
				scale_place := place_here(cursor)
				scale_value, ok := signed_number_read(cursor)
				if !ok {
					return operand, refuse(.Number_Not_Valid, scale_place)
				}
				switch scale_value {
				case 1:
					operand.scale = .Scale_1
				case 2:
					operand.scale = .Scale_2
				case 4:
					operand.scale = .Scale_4
				case 8:
					operand.scale = .Scale_8
				case:
					return operand, refuse(.Operand_Not_Valid, scale_place)
				}
			}
		}
		if !next_is(cursor, ')') {
			return operand, refuse(.Operand_Not_Valid, place_here(cursor))
		}
		// A label reached from a register other than %rip is an absolute
		// address, which needs a rebase.
		if label_name != "" && !operand.base_is_instruction_pointer {
			return operand, refuse(.Operand_Not_Valid, operand.place)
		}
		operand.kind = .Memory
	} else if label_name != "" && !operand.indirect {
		operand.kind = .Label
	} else {
		// A number alone is an absolute address; `*label` is no indirect form.
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
put_u16 :: proc "contextless" (encoding: ^Encoding, value: u16) {
	put_byte(encoding, u8(value))
	put_byte(encoding, u8(value >> 8))
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

// rex_flags_of inspects register operands for 8-bit registers that force or
// forbid a prefix REX.
@(private)
rex_flags_of :: proc "contextless" (operands: ..Operand) -> (force_rex: bool, forbid_rex: bool, conflict_place: Place) {
	for operand in operands {
		if operand.kind != .Register {
			continue
		}
		switch operand.register.byte_kind {
		case .Standard:
		case .Low_Rex:
			force_rex = true
		case .High_Byte:
			forbid_rex = true
			conflict_place = operand.place
		}
	}
	return force_rex, forbid_rex, conflict_place
}

// put_rex writes the prefix REX when wide is true, when any high bit
// (reg, index, base/rm) is set, or when force_rex is true (for %spl, %bpl,
// %sil, %dil). It refuses when a REX byte is needed and forbid_rex is true
// (for %ah, %ch, %dh, %bh).
@(private)
put_rex :: proc "contextless" (
	encoding: ^Encoding,
	wide: bool,
	reg_number: u8,
	index_num: u8,
	rm_number: u8,
	force_rex: bool,
	forbid_rex: bool,
	conflict_place: Place,
) -> Refusal_Record {
	prefix := u8(0x40)
	if wide {
		prefix |= 0x08
	}
	prefix |= (reg_number >> 3 & 1) << 2
	prefix |= (index_num >> 3 & 1) << 1
	prefix |= rm_number >> 3 & 1
	need_rex := force_rex || prefix != 0x40
	if need_rex && forbid_rex {
		return refuse(.Operand_Form_Not_Valid, conflict_place)
	}
	if need_rex {
		put_byte(encoding, prefix)
	}
	return {}
}

// put_operand_prefixes writes the 16-bit operand-size override (0x66) and
// the prefix REX in the order required by x86-64.
@(private)
put_operand_prefixes :: proc "contextless" (
	encoding: ^Encoding,
	size: Operand_Size,
	reg_number: u8,
	index_num: u8,
	rm_number: u8,
	force_rex: bool,
	forbid_rex: bool,
	conflict_place: Place,
) -> Refusal_Record {
	if size == .Bits_16 {
		put_byte(encoding, 0x66)
	}
	return put_rex(encoding, size == .Bits_64, reg_number, index_num, rm_number, force_rex, forbid_rex, conflict_place)
}

@(private)
modrm :: proc "contextless" (mode: u8, reg_field: u8, rm_field: u8) -> u8 {
	return mode << 6 | (reg_field & 7) << 3 | rm_field & 7
}

@(private)
sib :: proc "contextless" (scale: Index_Scale, index_field: u8, base_field: u8) -> u8 {
	return u8(scale) << 6 | (index_field & 7) << 3 | base_field & 7
}

@(private)
fits_signed_8 :: proc "contextless" (value: i128) -> bool {
	return value >= -128 && value <= 127
}

@(private)
fits_signed_32 :: proc "contextless" (value: i128) -> bool {
	return value >= i128(min(i32)) && value <= i128(max(i32))
}

// The number of the base of a memory operand for REX.B: %rip and an
// omitted base set no bit.
@(private)
base_number :: proc "contextless" (operand: Operand) -> u8 {
	return operand.has_base ? operand.register.number : 0
}

// The number of the index of a memory operand for REX.X: no index sets no
// bit.
@(private)
index_number :: proc "contextless" (operand: Operand) -> u8 {
	return operand.has_index ? operand.index_register.number : 0
}

@(private)
rm_number_of :: proc "contextless" (operand: Operand) -> u8 {
	return operand.kind == .Register ? operand.register.number : base_number(operand)
}

@(private)
rm_index_of :: proc "contextless" (operand: Operand) -> u8 {
	return operand.kind == .Memory ? index_number(operand) : 0
}

// put_rm_body writes ModRM (and SIB/displacement for memory) for an r/m
// operand.
@(private)
put_rm_body :: proc "contextless" (encoding: ^Encoding, reg_field: u8, operand: Operand) -> Refusal_Record {
	if operand.kind == .Register {
		put_byte(encoding, modrm(3, reg_field, operand.register.number))
		return {}
	}
	return put_memory(encoding, reg_field, operand)
}

// put_memory writes ModRM, SIB and the displacement of a memory operand.
//
// - %rip: ModRM 00 reg 101 and 4 bytes; a label gives a reference.
// - Index without base (`disp(,index,scale)`): ModRM 00 reg 100, SIB with
//   base 101, and a 4-byte signed displacement.
// - Base with index (`disp(base,index,scale)`): ModRM mod reg 100, SIB,
//   and displacement (0, 1 or 4 bytes; %rbp/%r13 with disp 0 take disp8 0).
// - Base alone: ModRM mod reg base&7 (%rsp/%r12 take SIB 24; %rbp/%r13
//   with disp 0 take disp8 0).
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
	if !operand.has_base {
		// Scaled index with no base always encodes mod=00, rm=4, SIB.base=5, disp32.
		put_byte(encoding, modrm(0, reg_field, 4))
		put_byte(encoding, sib(operand.scale, operand.index_register.number, 5))
		put_u32(encoding, u32(i32(operand.value)))
		return {}
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
	if operand.has_index {
		put_byte(encoding, modrm(mode, reg_field, 4))
		put_byte(encoding, sib(operand.scale, operand.index_register.number, low))
	} else {
		put_byte(encoding, modrm(mode, reg_field, low))
		if low == 4 {
			put_byte(encoding, 0x24)
		}
	}
	switch mode {
	case 1:
		put_byte(encoding, u8(i8(operand.value)))
	case 2:
		put_u32(encoding, u32(i32(operand.value)))
	}
	return {}
}

// The opcodes of the two-operand ALU and move family (Intel manual,
// volume 2): `store` is r/m <- r (89, 01, 29, 39, 21, 09, 31; 8-bit is
// store - 1), `load` is r <- r/m (8B, 03, 2B, 3B, 23, 0B, 33; 8-bit is
// load - 1), `extension` is the field reg of the immediate form (C6/C7 /0,
// 80/81/83 /n).
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
	case .Bitwise_Or:
		return {store = 0x09, load = 0x0B, extension = 1}, true
	case .Bitwise_And:
		return {store = 0x21, load = 0x23, extension = 4}, true
	case .Subtract:
		return {store = 0x29, load = 0x2B, extension = 5}, true
	case .Bitwise_Xor:
		return {store = 0x31, load = 0x33, extension = 6}, true
	case .Compare:
		return {store = 0x39, load = 0x3B, extension = 7}, true
	case .Load_Address, .Push, .Pop, .Jump, .Jump_If, .Call, .Return,
	     .Move_Sign_Extended, .Move_Zero_Extended, .Test, .Multiply_Signed,
	     .Divide_Signed, .Divide_Unsigned, .Negate, .Bitwise_Not,
	     .Increment, .Decrement, .Shift_Left, .Shift_Right_Logical,
	     .Shift_Right_Arithmetic, .Set_If, .Sign_Extend_Byte_To_Word,
	     .Sign_Extend_Word_To_Long, .Sign_Extend_Long_To_Quad,
	     .Sign_Extend_Word_To_Double, .Sign_Extend_Long_To_Double,
	     .Sign_Extend_Quad_To_Octaword, .Store_Byte, .Repeat_Store_Byte:
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
	mnemonic: Mnemonic
	suffix_size: Operand_Size
	known: bool
	if word == "rep" {
		blanks_skip(cursor)
		next_place := place_here(cursor)
		next_word := word_read(cursor)
		if next_word == "stosb" {
			mnemonic = {name = "rep stosb", operation = .Repeat_Store_Byte}
			known = true
		} else {
			return refuse(.Mnemonic_Unknown, next_word == "" ? word_place : next_place)
		}
	} else {
		mnemonic, suffix_size, known = mnemonic_of_word(word)
	}
	if !known {
		return refuse(.Mnemonic_Unknown, word_place)
	}
	if cursor.section^ != .Code {
		return refuse(.Instruction_In_Data, word_place)
	}
	operands: [3]Operand
	max_operands := mnemonic.operation == .Multiply_Signed ? 3 : 2
	count := 0
	if !at_end(cursor) {
		for {
			if count == max_operands {
				// Past the operand limit for this operation.
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

// operation_size gives the size of an operation from its suffix and each
// register operand. The sizes must agree.
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
	// Only direct/indirect `call` and `jmp` accept `*` operands.
	if mnemonic.operation != .Call && mnemonic.operation != .Jump {
		for operand in operands {
			if operand.indirect {
				return refuse(.Operand_Form_Not_Valid, operand.place)
			}
		}
	}

	// Variable-count operations check their counts in their own encoders.
	switch mnemonic.operation {
	case .Multiply_Signed:
		return multiply_signed_encode(encoding, suffix_size, operands, word_place)
	case .Shift_Left, .Shift_Right_Logical, .Shift_Right_Arithmetic:
		return shift_encode(encoding, mnemonic.operation, suffix_size, operands, word_place)
	case .Move, .Add, .Subtract, .Compare, .Load_Address, .Push, .Pop,
	     .Jump, .Jump_If, .Call, .Return, .Move_Sign_Extended,
	     .Move_Zero_Extended, .Bitwise_And, .Bitwise_Or, .Bitwise_Xor,
	     .Test, .Divide_Signed, .Divide_Unsigned, .Negate, .Bitwise_Not,
	     .Increment, .Decrement, .Set_If, .Sign_Extend_Byte_To_Word,
	     .Sign_Extend_Word_To_Long, .Sign_Extend_Long_To_Quad,
	     .Sign_Extend_Word_To_Double, .Sign_Extend_Long_To_Double,
	     .Sign_Extend_Quad_To_Octaword, .Store_Byte, .Repeat_Store_Byte:
	}

	wanted := 2
	switch mnemonic.operation {
	case .Return, .Sign_Extend_Byte_To_Word, .Sign_Extend_Word_To_Long,
	     .Sign_Extend_Long_To_Quad, .Sign_Extend_Word_To_Double,
	     .Sign_Extend_Long_To_Double, .Sign_Extend_Quad_To_Octaword,
	     .Store_Byte, .Repeat_Store_Byte:
		wanted = 0
	case .Jump, .Call, .Jump_If, .Push, .Pop, .Divide_Signed, .Divide_Unsigned,
	     .Negate, .Bitwise_Not, .Increment, .Decrement, .Set_If:
		wanted = 1
	case .Move, .Add, .Subtract, .Compare, .Bitwise_And, .Bitwise_Or,
	     .Bitwise_Xor, .Test, .Load_Address, .Move_Sign_Extended,
	     .Move_Zero_Extended, .Multiply_Signed, .Shift_Left,
	     .Shift_Right_Logical, .Shift_Right_Arithmetic:
	}
	if len(operands) != wanted {
		return refuse(.Operand_Count_Wrong, word_place, u64(len(operands)))
	}

	switch mnemonic.operation {
	case .Return:
		// RET: C3.
		put_byte(encoding, 0xC3)
	case .Store_Byte:
		// STOSB: AA.
		put_byte(encoding, 0xAA)
	case .Repeat_Store_Byte:
		// REP STOSB: F3 AA.
		put_byte(encoding, 0xF3)
		put_byte(encoding, 0xAA)
	case .Sign_Extend_Byte_To_Word:
		// CBW: 66 98.
		put_byte(encoding, 0x66)
		put_byte(encoding, 0x98)
	case .Sign_Extend_Word_To_Long:
		// CWDE / CWTL: 98.
		put_byte(encoding, 0x98)
	case .Sign_Extend_Long_To_Quad:
		// CDQE / CLTQ: 48 98.
		put_byte(encoding, 0x48)
		put_byte(encoding, 0x98)
	case .Sign_Extend_Word_To_Double:
		// CWD: 66 99.
		put_byte(encoding, 0x66)
		put_byte(encoding, 0x99)
	case .Sign_Extend_Long_To_Double:
		// CDQ / CLTD: 99.
		put_byte(encoding, 0x99)
	case .Sign_Extend_Quad_To_Octaword:
		// CQO / CQTO: 48 99.
		put_byte(encoding, 0x48)
		put_byte(encoding, 0x99)
	case .Jump, .Call, .Jump_If:
		target := operands[0]
		if target.indirect {
			// CALL r/m64: FF /2. JMP r/m64: FF /4. 64-bit size is default
			// in 64-bit mode, so REX.W is not needed.
			if target.kind == .Register && target.register.size != .Bits_64 {
				return refuse(.Operand_Size_Wrong, target.place)
			}
			if target.kind != .Register && target.kind != .Memory {
				return refuse(.Operand_Form_Not_Valid, target.place)
			}
			extension := mnemonic.operation == .Call ? u8(2) : u8(4)
			if refusal := put_rex(encoding, false, 0, rm_index_of(target), rm_number_of(target), false, false, target.place); failed(refusal) {
				return refusal
			}
			put_byte(encoding, 0xFF)
			return put_rm_body(encoding, extension, target)
		}
		// JMP rel32: E9 cd. CALL rel32: E8 cd. Jcc rel32: 0F 80+cc cd.
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
	case .Set_If:
		// SETcc r/m8: [REX] 0F 90+cc /0.
		operand := operands[0]
		if operand.kind == .Register {
			if operand.register.size != .Bits_8 {
				return refuse(.Operand_Size_Wrong, operand.place)
			}
		} else if operand.kind != .Memory {
			return refuse(.Operand_Form_Not_Valid, operand.place)
		}
		force_rex, forbid_rex, conflict_place := rex_flags_of(operand)
		if refusal := put_rex(encoding, false, 0, rm_index_of(operand), rm_number_of(operand), force_rex, forbid_rex, conflict_place); failed(refusal) {
			return refusal
		}
		put_byte(encoding, 0x0F)
		put_byte(encoding, 0x90 | u8(mnemonic.condition))
		return put_rm_body(encoding, 0, operand)
	case .Push, .Pop:
		operand := operands[0]
		switch operand.kind {
		case .Register:
			// PUSH r64: 50+rd. POP r64: 58+rd. No form of 32 bits exists in
			// the 64-bit mode.
			if operand.register.size != .Bits_64 {
				return refuse(.Operand_Size_Wrong, operand.place)
			}
			if suffix_size != .Unknown && suffix_size != .Bits_64 {
				return refuse(.Operand_Size_Wrong, word_place)
			}
			if refusal := put_rex(encoding, false, 0, 0, operand.register.number, false, false, operand.place); failed(refusal) {
				return refusal
			}
			opcode := mnemonic.operation == .Push ? u8(0x50) : u8(0x58)
			put_byte(encoding, opcode + operand.register.number & 7)
		case .Immediate:
			// PUSH imm8: 6A ib. PUSH imm32: 68 id, extended to 64 bits.
			if mnemonic.operation != .Push {
				return refuse(.Operand_Form_Not_Valid, operand.place)
			}
			if suffix_size != .Unknown && suffix_size != .Bits_64 {
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
		if suffix_size != .Unknown && suffix_size != .Bits_64 {
			return refuse(.Operand_Size_Wrong, word_place)
		}
		if refusal := put_rex(encoding, true, destination.register.number, index_number(source), base_number(source), false, false, destination.place); failed(refusal) {
			return refusal
		}
		put_byte(encoding, 0x8D)
		return put_memory(encoding, destination.register.number, source)
	case .Move_Sign_Extended, .Move_Zero_Extended:
		return extending_move_encode(encoding, mnemonic, operands[0], operands[1], word_place)
	case .Move, .Add, .Subtract, .Compare, .Bitwise_And, .Bitwise_Or, .Bitwise_Xor:
		return two_operand_encode(encoding, mnemonic.operation, suffix_size, operands[0], operands[1], word_place)
	case .Test:
		return test_encode(encoding, suffix_size, operands[0], operands[1], word_place)
	case .Divide_Signed, .Divide_Unsigned, .Negate, .Bitwise_Not, .Increment, .Decrement:
		return unary_encode(encoding, mnemonic.operation, suffix_size, operands[0], word_place)
	case .Multiply_Signed, .Shift_Left, .Shift_Right_Logical, .Shift_Right_Arithmetic:
	}
	return {}
}

// extending_move_encode writes sign-extending (MOVSX / MOVSXD) and
// zero-extending (MOVZX) moves from an 8-, 16- or 32-bit register or
// memory operand into a wider register.
@(private)
extending_move_encode :: proc "contextless" (encoding: ^Encoding, mnemonic: Mnemonic, source: Operand, destination: Operand, word_place: Place) -> Refusal_Record {
	if destination.kind != .Register {
		return refuse(.Operand_Form_Not_Valid, destination.place)
	}
	if source.kind != .Register && source.kind != .Memory {
		return refuse(.Operand_Form_Not_Valid, source.place)
	}
	dest_size := destination.register.size
	if mnemonic.destination_size != .Unknown && dest_size != mnemonic.destination_size {
		return refuse(.Operand_Size_Wrong, destination.place)
	}
	src_size: Operand_Size
	if mnemonic.source_size != .Unknown {
		if source.kind == .Register && source.register.size != mnemonic.source_size {
			return refuse(.Operand_Size_Wrong, source.place)
		}
		src_size = mnemonic.source_size
	} else {
		// Unsized `movsx` / `movzx` cannot infer a memory operand's width.
		if source.kind != .Register {
			return refuse(.Operand_Size_Unknown, word_place)
		}
		src_size = source.register.size
	}
	valid_pair := false
	switch src_size {
	case .Bits_8:
		valid_pair = dest_size == .Bits_16 || dest_size == .Bits_32 || dest_size == .Bits_64
	case .Bits_16:
		valid_pair = dest_size == .Bits_32 || dest_size == .Bits_64
	case .Bits_32:
		// x86-64 has MOVSXD for 32->64 sign extension, and no 32->64 MOVZX.
		valid_pair = mnemonic.operation == .Move_Sign_Extended && dest_size == .Bits_64
	case .Bits_64, .Unknown:
	}
	if !valid_pair {
		return refuse(.Operand_Size_Wrong, src_size == .Bits_64 || (src_size == .Bits_32 && mnemonic.operation == .Move_Zero_Extended) ? source.place : destination.place)
	}
	force_rex, forbid_rex, conflict_place := rex_flags_of(source, destination)
	if dest_size == .Bits_16 {
		put_byte(encoding, 0x66)
	}
	if refusal := put_rex(encoding, dest_size == .Bits_64, destination.register.number, rm_index_of(source), rm_number_of(source), force_rex, forbid_rex, conflict_place); failed(refusal) {
		return refusal
	}
	if src_size == .Bits_32 {
		// MOVSXD r64, r/m32: REX.W 63 /r.
		put_byte(encoding, 0x63)
	} else if mnemonic.operation == .Move_Sign_Extended {
		// MOVSX r, r/m8: 0F BE /r. MOVSX r, r/m16: 0F BF /r.
		put_byte(encoding, 0x0F)
		put_byte(encoding, src_size == .Bits_8 ? u8(0xBE) : u8(0xBF))
	} else {
		// MOVZX r, r/m8: 0F B6 /r. MOVZX r, r/m16: 0F B7 /r.
		put_byte(encoding, 0x0F)
		put_byte(encoding, src_size == .Bits_8 ? u8(0xB6) : u8(0xB7))
	}
	return put_rm_body(encoding, destination.register.number, source)
}

// two_operand_encode writes mov, add, sub, cmp, and, or and xor: the
// source first, as the syntax of AT&T writes it.
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
	force_rex, forbid_rex, conflict_place := rex_flags_of(source, destination)
	switch source.kind {
	case .Register:
		// r/m <- r: 8-bit is store-1, 16/32/64-bit is store.
		opcode := size == .Bits_8 ? opcodes.store - 1 : opcodes.store
		if refusal = put_operand_prefixes(encoding, size, source.register.number, rm_index_of(destination), rm_number_of(destination), force_rex, forbid_rex, conflict_place); failed(refusal) {
			return refusal
		}
		put_byte(encoding, opcode)
		return put_rm_body(encoding, source.register.number, destination)
	case .Memory:
		// r <- r/m: 8-bit is load-1, 16/32/64-bit is load.
		opcode := size == .Bits_8 ? opcodes.load - 1 : opcodes.load
		if refusal = put_operand_prefixes(encoding, size, destination.register.number, index_number(source), base_number(source), force_rex, forbid_rex, conflict_place); failed(refusal) {
			return refusal
		}
		put_byte(encoding, opcode)
		return put_memory(encoding, destination.register.number, source)
	case .Immediate:
		return immediate_encode(encoding, operation, opcodes, size, source, destination)
	case .Label:
	}
	return refuse(.Operand_Form_Not_Valid, source.place)
}

// normalize_immediate checks that value fits the immediate width of size
// and returns the sign-normalized value for short-form selection.
//
// - 8-bit: -128 .. 255.
// - 16-bit: -32768 .. 65535 (unsigned values above 32767 fold to negative).
// - 32-bit: -2^31 .. 2^32 - 1 (unsigned values above 2^31 - 1 fold to negative).
// - 64-bit: -2^31 .. 2^31 - 1 (sign-extended by the processor).
@(private)
normalize_immediate :: proc "contextless" (size: Operand_Size, raw: i128, place: Place) -> (value: i128, refusal: Refusal_Record) {
	value = raw
	switch size {
	case .Bits_8:
		if value < i128(min(i8)) || value > i128(max(u8)) {
			return 0, refuse(.Immediate_Too_Large, place)
		}
	case .Bits_16:
		if value < i128(min(i16)) || value > i128(max(u16)) {
			return 0, refuse(.Immediate_Too_Large, place)
		}
		if value > i128(max(i16)) {
			value -= i128(1) << 16
		}
	case .Bits_32:
		if value < i128(min(i32)) || value > i128(max(u32)) {
			return 0, refuse(.Immediate_Too_Large, place)
		}
		if value > i128(max(i32)) {
			value -= i128(1) << 32
		}
	case .Bits_64:
		if !fits_signed_32(value) {
			return 0, refuse(.Immediate_Too_Large, place)
		}
	case .Unknown:
		return 0, refuse(.Operand_Size_Unknown, place)
	}
	return value, {}
}

// immediate_encode writes an operation of an immediate on a register or on
// memory.
@(private)
immediate_encode :: proc "contextless" (encoding: ^Encoding, operation: Operation, opcodes: Two_Operand_Opcodes, size: Operand_Size, source: Operand, destination: Operand) -> Refusal_Record {
	force_rex, forbid_rex, conflict_place := rex_flags_of(destination)
	// 64-bit MOV imm64 to a register: REX.W B8+rd io.
	if operation == .Move && size == .Bits_64 && destination.kind == .Register && !fits_signed_32(source.value) {
		if source.value < i128(min(i64)) || source.value > i128(max(u64)) {
			return refuse(.Immediate_Too_Large, source.place)
		}
		if refusal := put_rex(encoding, true, 0, 0, destination.register.number, false, false, destination.place); failed(refusal) {
			return refusal
		}
		put_byte(encoding, 0xB8 + destination.register.number & 7)
		put_u64(encoding, u64(source.value & i128(max(u64))))
		return {}
	}
	value, refusal := normalize_immediate(size, source.value, source.place)
	if failed(refusal) {
		return refusal
	}
	if operation == .Move {
		if destination.kind == .Register && size != .Bits_64 {
			// MOV r8, imm8: B0+rb ib. MOV r16, imm16: 66 B8+rw iw. MOV r32, imm32: B8+rd id.
			if refusal = put_operand_prefixes(encoding, size, 0, 0, destination.register.number, force_rex, forbid_rex, conflict_place); failed(refusal) {
				return refusal
			}
			base_opcode := size == .Bits_8 ? u8(0xB0) : u8(0xB8)
			put_byte(encoding, base_opcode + destination.register.number & 7)
			switch size {
			case .Bits_8:
				put_byte(encoding, u8(value & 0xFF))
			case .Bits_16:
				put_u16(encoding, u16(value & 0xFFFF))
			case .Bits_32:
				put_u32(encoding, u32(i32(value)))
			case .Bits_64, .Unknown:
			}
			return {}
		}
		// MOV r/m8, imm8: C6 /0 ib. MOV r/m16, imm16: 66 C7 /0 iw. MOV r/m32/64, imm32: C7 /0 id.
		if refusal = put_operand_prefixes(encoding, size, 0, rm_index_of(destination), rm_number_of(destination), force_rex, forbid_rex, conflict_place); failed(refusal) {
			return refusal
		}
		put_byte(encoding, size == .Bits_8 ? u8(0xC6) : u8(0xC7))
		if refusal = put_rm_body(encoding, 0, destination); failed(refusal) {
			return refusal
		}
		switch size {
		case .Bits_8:
			put_byte(encoding, u8(value & 0xFF))
		case .Bits_16:
			put_u16(encoding, u16(value & 0xFFFF))
		case .Bits_32, .Bits_64:
			put_u32(encoding, u32(i32(value)))
		case .Unknown:
		}
		return {}
	}
	// ALU r/m8, imm8: 80 /n ib.
	if size == .Bits_8 {
		if refusal = put_rex(encoding, false, 0, rm_index_of(destination), rm_number_of(destination), force_rex, forbid_rex, conflict_place); failed(refusal) {
			return refusal
		}
		put_byte(encoding, 0x80)
		if refusal = put_rm_body(encoding, opcodes.extension, destination); failed(refusal) {
			return refusal
		}
		put_byte(encoding, u8(value & 0xFF))
		return {}
	}
	// ALU r/m16/32/64, imm8: 83 /n ib; else 81 /n iw/id.
	short := fits_signed_8(value)
	if refusal = put_operand_prefixes(encoding, size, 0, rm_index_of(destination), rm_number_of(destination), force_rex, forbid_rex, conflict_place); failed(refusal) {
		return refusal
	}
	put_byte(encoding, short ? u8(0x83) : u8(0x81))
	if refusal = put_rm_body(encoding, opcodes.extension, destination); failed(refusal) {
		return refusal
	}
	if short {
		put_byte(encoding, u8(i8(value)))
	} else if size == .Bits_16 {
		put_u16(encoding, u16(value & 0xFFFF))
	} else {
		put_u32(encoding, u32(i32(value)))
	}
	return {}
}

// test_encode writes TEST: r/m with r (84 /r, 85 /r) and r/m with imm
// (F6 /0 ib, F7 /0 iw/id).
@(private)
test_encode :: proc "contextless" (encoding: ^Encoding, suffix_size: Operand_Size, source: Operand, destination: Operand, word_place: Place) -> Refusal_Record {
	operands := [2]Operand{source, destination}
	size, refusal := operation_size(suffix_size, operands[:])
	if failed(refusal) {
		return refusal
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
	force_rex, forbid_rex, conflict_place := rex_flags_of(source, destination)
	switch source.kind {
	case .Register:
		// TEST r/m, r: 84 /r (8-bit), 85 /r (16/32/64-bit).
		if refusal = put_operand_prefixes(encoding, size, source.register.number, rm_index_of(destination), rm_number_of(destination), force_rex, forbid_rex, conflict_place); failed(refusal) {
			return refusal
		}
		put_byte(encoding, size == .Bits_8 ? u8(0x84) : u8(0x85))
		return put_rm_body(encoding, source.register.number, destination)
	case .Memory:
		// TEST is commutative: `test mem, reg` encodes as TEST r/m, r with
		// destination in reg and source in r/m.
		if refusal = put_operand_prefixes(encoding, size, destination.register.number, index_number(source), base_number(source), force_rex, forbid_rex, conflict_place); failed(refusal) {
			return refusal
		}
		put_byte(encoding, size == .Bits_8 ? u8(0x84) : u8(0x85))
		return put_memory(encoding, destination.register.number, source)
	case .Immediate:
		// TEST r/m, imm: F6 /0 ib (8-bit), F7 /0 iw/id (16/32/64-bit).
		value: i128
		value, refusal = normalize_immediate(size, source.value, source.place)
		if failed(refusal) {
			return refusal
		}
		if refusal = put_operand_prefixes(encoding, size, 0, rm_index_of(destination), rm_number_of(destination), force_rex, forbid_rex, conflict_place); failed(refusal) {
			return refusal
		}
		put_byte(encoding, size == .Bits_8 ? u8(0xF6) : u8(0xF7))
		if refusal = put_rm_body(encoding, 0, destination); failed(refusal) {
			return refusal
		}
		switch size {
		case .Bits_8:
			put_byte(encoding, u8(value & 0xFF))
		case .Bits_16:
			put_u16(encoding, u16(value & 0xFFFF))
		case .Bits_32, .Bits_64:
			put_u32(encoding, u32(i32(value)))
		case .Unknown:
		}
		return {}
	case .Label:
	}
	return refuse(.Operand_Form_Not_Valid, source.place)
}

// unary_encode writes one-operand ALU instructions: NOT (F6/F7 /2),
// NEG (F6/F7 /3), DIV (F6/F7 /6), IDIV (F6/F7 /7), INC (FE/FF /0),
// DEC (FE/FF /1).
@(private)
unary_encode :: proc "contextless" (encoding: ^Encoding, operation: Operation, suffix_size: Operand_Size, operand: Operand, word_place: Place) -> Refusal_Record {
	if operand.kind != .Register && operand.kind != .Memory {
		return refuse(.Operand_Form_Not_Valid, operand.place)
	}
	operands := [1]Operand{operand}
	size, refusal := operation_size(suffix_size, operands[:])
	if failed(refusal) {
		return refusal
	}
	if size == .Unknown {
		return refuse(.Operand_Size_Unknown, word_place)
	}
	opcode_8: u8
	opcode_wide: u8
	extension: u8
	switch operation {
	case .Bitwise_Not:
		opcode_8, opcode_wide, extension = 0xF6, 0xF7, 2
	case .Negate:
		opcode_8, opcode_wide, extension = 0xF6, 0xF7, 3
	case .Divide_Unsigned:
		opcode_8, opcode_wide, extension = 0xF6, 0xF7, 6
	case .Divide_Signed:
		opcode_8, opcode_wide, extension = 0xF6, 0xF7, 7
	case .Increment:
		opcode_8, opcode_wide, extension = 0xFE, 0xFF, 0
	case .Decrement:
		opcode_8, opcode_wide, extension = 0xFE, 0xFF, 1
	case .Move, .Add, .Subtract, .Compare, .Load_Address, .Push, .Pop,
	     .Jump, .Jump_If, .Call, .Return, .Move_Sign_Extended,
	     .Move_Zero_Extended, .Bitwise_And, .Bitwise_Or, .Bitwise_Xor,
	     .Test, .Multiply_Signed, .Shift_Left, .Shift_Right_Logical,
	     .Shift_Right_Arithmetic, .Set_If, .Sign_Extend_Byte_To_Word,
	     .Sign_Extend_Word_To_Long, .Sign_Extend_Long_To_Quad,
	     .Sign_Extend_Word_To_Double, .Sign_Extend_Long_To_Double,
	     .Sign_Extend_Quad_To_Octaword, .Store_Byte, .Repeat_Store_Byte:
		return refuse(.Mnemonic_Unknown, word_place)
	}
	force_rex, forbid_rex, conflict_place := rex_flags_of(operand)
	if refusal = put_operand_prefixes(encoding, size, 0, rm_index_of(operand), rm_number_of(operand), force_rex, forbid_rex, conflict_place); failed(refusal) {
		return refusal
	}
	put_byte(encoding, size == .Bits_8 ? opcode_8 : opcode_wide)
	return put_rm_body(encoding, extension, operand)
}

// multiply_signed_encode writes IMUL in its 1-, 2- and 3-operand forms:
// - 1 operand: IMUL r/m (F6 /5, F7 /5).
// - 2 operands: IMUL r, r/m (0F AF /r) or IMUL r, r, imm (6B /r ib, 69 /r iw/id).
// - 3 operands: IMUL r, r/m, imm (6B /r ib, 69 /r iw/id).
@(private)
multiply_signed_encode :: proc "contextless" (encoding: ^Encoding, suffix_size: Operand_Size, operands: []Operand, word_place: Place) -> Refusal_Record {
	switch len(operands) {
	case 1:
		operand := operands[0]
		if operand.kind != .Register && operand.kind != .Memory {
			return refuse(.Operand_Form_Not_Valid, operand.place)
		}
		size, refusal := operation_size(suffix_size, operands)
		if failed(refusal) {
			return refusal
		}
		if size == .Unknown {
			return refuse(.Operand_Size_Unknown, word_place)
		}
		force_rex, forbid_rex, conflict_place := rex_flags_of(operand)
		if refusal = put_operand_prefixes(encoding, size, 0, rm_index_of(operand), rm_number_of(operand), force_rex, forbid_rex, conflict_place); failed(refusal) {
			return refusal
		}
		put_byte(encoding, size == .Bits_8 ? u8(0xF6) : u8(0xF7))
		return put_rm_body(encoding, 5, operand)
	case 2:
		source, destination := operands[0], operands[1]
		if destination.kind != .Register {
			return refuse(.Operand_Form_Not_Valid, destination.place)
		}
		if source.kind == .Immediate {
			return multiply_signed_immediate_encode(encoding, suffix_size, source, destination, destination, word_place)
		}
		if source.kind != .Register && source.kind != .Memory {
			return refuse(.Operand_Form_Not_Valid, source.place)
		}
		size, refusal := operation_size(suffix_size, operands)
		if failed(refusal) {
			return refusal
		}
		if size == .Bits_8 {
			return refuse(.Operand_Size_Wrong, destination.place)
		}
		if refusal = put_operand_prefixes(encoding, size, destination.register.number, rm_index_of(source), rm_number_of(source), false, false, destination.place); failed(refusal) {
			return refusal
		}
		put_byte(encoding, 0x0F)
		put_byte(encoding, 0xAF)
		return put_rm_body(encoding, destination.register.number, source)
	case 3:
		immediate, source, destination := operands[0], operands[1], operands[2]
		if immediate.kind != .Immediate {
			return refuse(.Operand_Form_Not_Valid, immediate.place)
		}
		if source.kind != .Register && source.kind != .Memory {
			return refuse(.Operand_Form_Not_Valid, source.place)
		}
		if destination.kind != .Register {
			return refuse(.Operand_Form_Not_Valid, destination.place)
		}
		return multiply_signed_immediate_encode(encoding, suffix_size, immediate, source, destination, word_place)
	}
	return refuse(.Operand_Count_Wrong, word_place, u64(len(operands)))
}

@(private)
multiply_signed_immediate_encode :: proc "contextless" (encoding: ^Encoding, suffix_size: Operand_Size, immediate: Operand, source: Operand, destination: Operand, word_place: Place) -> Refusal_Record {
	sized := [2]Operand{source, destination}
	size, refusal := operation_size(suffix_size, sized[:])
	if failed(refusal) {
		return refusal
	}
	if size == .Bits_8 {
		return refuse(.Operand_Size_Wrong, destination.place)
	}
	if size == .Unknown {
		return refuse(.Operand_Size_Unknown, word_place)
	}
	value: i128
	value, refusal = normalize_immediate(size, immediate.value, immediate.place)
	if failed(refusal) {
		return refusal
	}
	short := fits_signed_8(value)
	if refusal = put_operand_prefixes(encoding, size, destination.register.number, rm_index_of(source), rm_number_of(source), false, false, destination.place); failed(refusal) {
		return refusal
	}
	put_byte(encoding, short ? u8(0x6B) : u8(0x69))
	if refusal = put_rm_body(encoding, destination.register.number, source); failed(refusal) {
		return refusal
	}
	if short {
		put_byte(encoding, u8(i8(value)))
	} else if size == .Bits_16 {
		put_u16(encoding, u16(value & 0xFFFF))
	} else {
		put_u32(encoding, u32(i32(value)))
	}
	return {}
}

// shift_encode writes SHL/SAL (/4), SHR (/5) and SAR (/7):
// - 1 operand (`shl %rax`): shift by 1 (D0 /n, D1 /n).
// - 2 operands with `%cl` (`shl %cl, %rax`): shift by CL (D2 /n, D3 /n).
// - 2 operands with `$imm` (`shl $8, %rax`): D0/D1 for $1, else C0/C1 ib.
@(private)
shift_encode :: proc "contextless" (encoding: ^Encoding, operation: Operation, suffix_size: Operand_Size, operands: []Operand, word_place: Place) -> Refusal_Record {
	if len(operands) != 1 && len(operands) != 2 {
		return refuse(.Operand_Count_Wrong, word_place, u64(len(operands)))
	}
	extension: u8
	switch operation {
	case .Shift_Left:
		extension = 4
	case .Shift_Right_Logical:
		extension = 5
	case .Shift_Right_Arithmetic:
		extension = 7
	case .Move, .Add, .Subtract, .Compare, .Load_Address, .Push, .Pop,
	     .Jump, .Jump_If, .Call, .Return, .Move_Sign_Extended,
	     .Move_Zero_Extended, .Bitwise_And, .Bitwise_Or, .Bitwise_Xor,
	     .Test, .Multiply_Signed, .Divide_Signed, .Divide_Unsigned, .Negate,
	     .Bitwise_Not, .Increment, .Decrement, .Set_If,
	     .Sign_Extend_Byte_To_Word, .Sign_Extend_Word_To_Long,
	     .Sign_Extend_Long_To_Quad, .Sign_Extend_Word_To_Double,
	     .Sign_Extend_Long_To_Double, .Sign_Extend_Quad_To_Octaword,
	     .Store_Byte, .Repeat_Store_Byte:
		return refuse(.Mnemonic_Unknown, word_place)
	}
	target := operands[len(operands) - 1]
	if target.kind != .Register && target.kind != .Memory {
		return refuse(.Operand_Form_Not_Valid, target.place)
	}
	sized := [1]Operand{target}
	size, refusal := operation_size(suffix_size, sized[:])
	if failed(refusal) {
		return refusal
	}
	if size == .Unknown {
		return refuse(.Operand_Size_Unknown, word_place)
	}
	force_rex, forbid_rex, conflict_place := rex_flags_of(target)
	if len(operands) == 1 {
		if refusal = put_operand_prefixes(encoding, size, 0, rm_index_of(target), rm_number_of(target), force_rex, forbid_rex, conflict_place); failed(refusal) {
			return refusal
		}
		put_byte(encoding, size == .Bits_8 ? u8(0xD0) : u8(0xD1))
		return put_rm_body(encoding, extension, target)
	}
	count := operands[0]
	switch count.kind {
	case .Register:
		// Only %cl can supply a variable shift count.
		if count.register.size != .Bits_8 || count.register.number != 1 || count.register.byte_kind != .Standard {
			return refuse(.Operand_Form_Not_Valid, count.place)
		}
		if refusal = put_operand_prefixes(encoding, size, 0, rm_index_of(target), rm_number_of(target), force_rex, forbid_rex, conflict_place); failed(refusal) {
			return refusal
		}
		put_byte(encoding, size == .Bits_8 ? u8(0xD2) : u8(0xD3))
		return put_rm_body(encoding, extension, target)
	case .Immediate:
		if count.value < 0 || count.value > 255 {
			return refuse(.Immediate_Too_Large, count.place)
		}
		if refusal = put_operand_prefixes(encoding, size, 0, rm_index_of(target), rm_number_of(target), force_rex, forbid_rex, conflict_place); failed(refusal) {
			return refusal
		}
		if count.value == 1 {
			put_byte(encoding, size == .Bits_8 ? u8(0xD0) : u8(0xD1))
			return put_rm_body(encoding, extension, target)
		}
		put_byte(encoding, size == .Bits_8 ? u8(0xC0) : u8(0xC1))
		if refusal = put_rm_body(encoding, extension, target); failed(refusal) {
			return refusal
		}
		put_byte(encoding, u8(count.value))
		return {}
	case .Memory, .Label:
		return refuse(.Operand_Form_Not_Valid, count.place)
	}
	return refuse(.Operand_Form_Not_Valid, count.place)
}
