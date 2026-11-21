#+build !freestanding
package assembler

import "core:fmt"
import "core:testing"

@(test)
byte_and_word_moves_have_the_bytes_of_the_manual :: proc(t: ^testing.T) {
	// 8-bit register moves: standard, high-byte, REX-forced (%spl/%bpl/%sil/%dil), high (%r8b..%r15b).
	expect_code(t, "movb %al, %bl", {0x88, 0xC3})
	expect_code(t, "mov %ah, %bl", {0x88, 0xE3})
	expect_code(t, "mov %bh, %ch", {0x88, 0xFD})
	expect_code(t, "mov %dh, %al", {0x88, 0xF0})
	expect_code(t, "mov %sil, %dil", {0x40, 0x88, 0xF7})
	expect_code(t, "mov %spl, %bpl", {0x40, 0x88, 0xE5})
	expect_code(t, "mov %r8b, %r15b", {0x45, 0x88, 0xC7})
	expect_code(t, "mov %dil, -1(%rbp)", {0x40, 0x88, 0x7D, 0xFF})
	expect_code(t, "mov %sil, (%rsp)", {0x40, 0x88, 0x34, 0x24})
	expect_code(t, "mov %ah, (%rsp)", {0x88, 0x24, 0x24})
	expect_code(t, "mov %r8b, (%r12)", {0x45, 0x88, 0x04, 0x24})
	expect_code(t, "mov (%rax,%rcx,2), %r9b", {0x44, 0x8A, 0x0C, 0x48})
	expect_code(t, "mov (%rbp), %sil", {0x40, 0x8A, 0x75, 0x00})
	// 8-bit immediates: -128..255.
	expect_code(t, "mov $0, %al", {0xB0, 0x00})
	expect_code(t, "mov $0x7F, %al", {0xB0, 0x7F})
	expect_code(t, "mov $-128, %r11b", {0x41, 0xB3, 0x80})
	expect_code(t, "mov $255, %dil", {0x40, 0xB7, 0xFF})
	expect_code(t, "mov $0, %ah", {0xB4, 0x00})
	expect_code(t, "movb $42, (%rbx)", {0xC6, 0x03, 0x2A})
	expect_code(t, "movb $-1, (%r12)", {0x41, 0xC6, 0x04, 0x24, 0xFF})
	// 16-bit moves: 0x66 always precedes REX.
	expect_code(t, "movw %ax, %cx", {0x66, 0x89, 0xC1})
	expect_code(t, "mov %r8w, %r15w", {0x66, 0x45, 0x89, 0xC7})
	expect_code(t, "mov %si, -2(%rbp)", {0x66, 0x89, 0x75, 0xFE})
	expect_code(t, "mov (%r13,%r12,4), %r10w", {0x66, 0x47, 0x8B, 0x54, 0xA5, 0x00})
	expect_code(t, "mov $0x1234, %ax", {0x66, 0xB8, 0x34, 0x12})
	expect_code(t, "mov $0x1234, %r9w", {0x66, 0x41, 0xB9, 0x34, 0x12})
	expect_code(t, "mov $-32768, %dx", {0x66, 0xBA, 0x00, 0x80})
	expect_code(t, "mov $0xFFFF, %di", {0x66, 0xBF, 0xFF, 0xFF})
	expect_code(t, "movw $0x1234, 8(%rsp)", {0x66, 0xC7, 0x44, 0x24, 0x08, 0x34, 0x12})
}

@(test)
scaled_indexed_addressing_has_the_bytes_of_the_manual :: proc(t: ^testing.T) {
	// Base + index with each scale (implicit 1, 1, 2, 4, 8).
	expect_code(t, "mov (%rax,%rbx), %rcx", {0x48, 0x8B, 0x0C, 0x18})
	expect_code(t, "mov (%rax,%rbx,1), %rcx", {0x48, 0x8B, 0x0C, 0x18})
	expect_code(t, "mov (%rax,%rcx,2), %rdx", {0x48, 0x8B, 0x14, 0x48})
	expect_code(t, "mov (%rax,%rcx,4), %rdx", {0x48, 0x8B, 0x14, 0x88})
	expect_code(t, "mov (%rax,%rcx,8), %rdx", {0x48, 0x8B, 0x14, 0xC8})
	// Base %rbp / %r13 with displacement 0 forces mod=01 and disp8=0.
	expect_code(t, "lea (%rbp,%rax,1), %rcx", {0x48, 0x8D, 0x4C, 0x05, 0x00})
	expect_code(t, "lea (%r13,%r12,8), %r10", {0x4F, 0x8D, 0x54, 0xE5, 0x00})
	// Base %rsp / %r12 with index: SIB base=4, no extra SIB byte.
	expect_code(t, "mov (%rsp,%r9,1), %r10", {0x4E, 0x8B, 0x14, 0x0C})
	expect_code(t, "mov (%r12,%rax,4), %rcx", {0x49, 0x8B, 0x0C, 0x84})
	// High registers in all three positions with disp8 and disp32.
	expect_code(t, "lea 16(%r8,%r9,8), %r10", {0x4F, 0x8D, 0x54, 0xC8, 0x10})
	expect_code(t, "mov -4(%rbp,%rax,2), %r8d", {0x44, 0x8B, 0x44, 0x45, 0xFC})
	expect_code(t, "mov 0x1000(%r14,%r15,4), %r11", {0x4F, 0x8B, 0x9C, 0xBE, 0x00, 0x10, 0x00, 0x00})
	// Omitted base: mod=00, rm=4, SIB.base=5, disp32 always present.
	expect_code(t, "lea (,%rax,8), %rcx", {0x48, 0x8D, 0x0C, 0xC5, 0x00, 0x00, 0x00, 0x00})
	expect_code(t, "mov 16(,%rcx,4), %rdx", {0x48, 0x8B, 0x14, 0x8D, 0x10, 0x00, 0x00, 0x00})
	expect_code(t, "mov (,%r12,8), %rax", {0x4A, 0x8B, 0x04, 0xE5, 0x00, 0x00, 0x00, 0x00})
	expect_code(t, "mov -8(,%rax), %rcx", {0x48, 0x8B, 0x0C, 0x05, 0xF8, 0xFF, 0xFF, 0xFF})
}

@(test)
bitwise_alu_and_test_have_the_bytes_of_the_manual :: proc(t: ^testing.T) {
	// AND / OR / XOR across 8, 16, 32, 64 bits.
	expect_code(t, "and %rsi, %rax", {0x48, 0x21, 0xF0})
	expect_code(t, "and %edi, %eax", {0x21, 0xF8})
	expect_code(t, "and %cx, %dx", {0x66, 0x21, 0xCA})
	expect_code(t, "and %dl, %al", {0x20, 0xD0})
	expect_code(t, "and (%rax), %rcx", {0x48, 0x23, 0x08})
	expect_code(t, "and (%rax), %cl", {0x22, 0x08})
	expect_code(t, "and $0x0F, %al", {0x80, 0xE0, 0x0F})
	expect_code(t, "and $0x1234, %ax", {0x66, 0x81, 0xE0, 0x34, 0x12})
	expect_code(t, "and $0xFFFF, %ax", {0x66, 0x83, 0xE0, 0xFF})
	expect_code(t, "and $-16, %rdi", {0x48, 0x83, 0xE7, 0xF0})
	expect_code(t, "and $0xFFFFFFF0, %edi", {0x83, 0xE7, 0xF0})
	expect_code(t, "and $0x12345678, %rax", {0x48, 0x81, 0xE0, 0x78, 0x56, 0x34, 0x12})

	expect_code(t, "or %r8, %r9", {0x4D, 0x09, 0xC1})
	expect_code(t, "or %dl, %al", {0x08, 0xD0})
	expect_code(t, "or $12, %ah", {0x80, 0xCC, 0x0C})
	expect_code(t, "orq $1, (%r12)", {0x49, 0x83, 0x0C, 0x24, 0x01})
	expect_code(t, "orb $0x80, (%rax)", {0x80, 0x08, 0x80})

	expect_code(t, "xor %rax, %rax", {0x48, 0x31, 0xC0})
	expect_code(t, "xor %eax, %eax", {0x31, 0xC0})
	expect_code(t, "xor %r8b, %r9b", {0x45, 0x30, 0xC1})
	expect_code(t, "xor $0xFF, %r10b", {0x41, 0x80, 0xF2, 0xFF})
	expect_code(t, "xor (%rbx,%rcx,4), %r11", {0x4C, 0x33, 0x1C, 0x8B})

	// 8-bit and 16-bit ADD, SUB, CMP.
	expect_code(t, "addb %al, %bl", {0x00, 0xC3})
	expect_code(t, "addw %ax, %cx", {0x66, 0x01, 0xC1})
	expect_code(t, "subb $1, %sil", {0x40, 0x80, 0xEE, 0x01})
	expect_code(t, "cmpb $0, (%rax)", {0x80, 0x38, 0x00})
	expect_code(t, "cmpw $1000, (%rbp)", {0x66, 0x81, 0x7D, 0x00, 0xE8, 0x03})

	// TEST across 8, 16, 32, 64 bits (reg/reg, reg/mem, mem/reg, imm/reg, imm/mem).
	expect_code(t, "test %rax, %rax", {0x48, 0x85, 0xC0})
	expect_code(t, "test %eax, %ebx", {0x85, 0xC3})
	expect_code(t, "test %ax, %cx", {0x66, 0x85, 0xC1})
	expect_code(t, "test %al, %dl", {0x84, 0xC2})
	expect_code(t, "test %sil, %dil", {0x40, 0x84, 0xF7})
	expect_code(t, "test %r8, (%r9,%r10,8)", {0x4F, 0x85, 0x04, 0xD1})
	expect_code(t, "test (%rax), %rbx", {0x48, 0x85, 0x18})
	expect_code(t, "testb $1, %dl", {0xF6, 0xC2, 0x01})
	expect_code(t, "testb $1, %sil", {0x40, 0xF6, 0xC6, 0x01})
	expect_code(t, "testb $1, %ah", {0xF6, 0xC4, 0x01})
	expect_code(t, "testw $0x1234, %cx", {0x66, 0xF7, 0xC1, 0x34, 0x12})
	expect_code(t, "testl $0x12345678, %edx", {0xF7, 0xC2, 0x78, 0x56, 0x34, 0x12})
	expect_code(t, "testq $0x12345678, %rsi", {0x48, 0xF7, 0xC6, 0x78, 0x56, 0x34, 0x12})
	expect_code(t, "testq $1, (%rbp)", {0x48, 0xF7, 0x45, 0x00, 0x01, 0x00, 0x00, 0x00})
}

@(test)
multiply_divide_and_unary_have_the_bytes_of_the_manual :: proc(t: ^testing.T) {
	// IMUL 2-operand (reg/mem -> reg), 2-operand imm, 3-operand imm, and 1-operand.
	expect_code(t, "imul %edi, %eax", {0x0F, 0xAF, 0xC7})
	expect_code(t, "imul %r8, %r9", {0x4D, 0x0F, 0xAF, 0xC8})
	expect_code(t, "imul (%rax,%rcx,4), %rdx", {0x48, 0x0F, 0xAF, 0x14, 0x88})
	expect_code(t, "imul %cx, %dx", {0x66, 0x0F, 0xAF, 0xD1})
	expect_code(t, "imul $3, %rax", {0x48, 0x6B, 0xC0, 0x03})
	expect_code(t, "imul $1000, %eax", {0x69, 0xC0, 0xE8, 0x03, 0x00, 0x00})
	expect_code(t, "imul $3, 8(%rbp), %rcx", {0x48, 0x6B, 0x4D, 0x08, 0x03})
	expect_code(t, "imul $1000, (%r8), %r9", {0x4D, 0x69, 0x08, 0xE8, 0x03, 0x00, 0x00})
	expect_code(t, "imul $1000, %cx, %dx", {0x66, 0x69, 0xD1, 0xE8, 0x03})
	expect_code(t, "imulb %bl", {0xF6, 0xEB})
	expect_code(t, "imulw %bx", {0x66, 0xF7, 0xEB})
	expect_code(t, "imull %ebx", {0xF7, 0xEB})
	expect_code(t, "imulq %rbx", {0x48, 0xF7, 0xEB})
	expect_code(t, "imulq (%rsp)", {0x48, 0xF7, 0x2C, 0x24})

	// IDIV / DIV.
	expect_code(t, "idivb %bl", {0xF6, 0xFB})
	expect_code(t, "idivw %bx", {0x66, 0xF7, 0xFB})
	expect_code(t, "idiv %edi", {0xF7, 0xFF})
	expect_code(t, "idiv %r9", {0x49, 0xF7, 0xF9})
	expect_code(t, "idivq 8(%rbp)", {0x48, 0xF7, 0x7D, 0x08})
	expect_code(t, "div %dil", {0x40, 0xF6, 0xF7})
	expect_code(t, "div %si", {0x66, 0xF7, 0xF6})
	expect_code(t, "div %edi", {0xF7, 0xF7})
	expect_code(t, "div %rcx", {0x48, 0xF7, 0xF1})

	// NEG / NOT / INC / DEC.
	expect_code(t, "neg %al", {0xF6, 0xD8})
	expect_code(t, "neg %sil", {0x40, 0xF6, 0xDE})
	expect_code(t, "neg %ah", {0xF6, 0xDC})
	expect_code(t, "neg %ax", {0x66, 0xF7, 0xD8})
	expect_code(t, "neg %eax", {0xF7, 0xD8})
	expect_code(t, "neg %rax", {0x48, 0xF7, 0xD8})
	expect_code(t, "negq (%r12)", {0x49, 0xF7, 0x1C, 0x24})
	expect_code(t, "not %r8b", {0x41, 0xF6, 0xD0})
	expect_code(t, "not %r9w", {0x66, 0x41, 0xF7, 0xD1})
	expect_code(t, "not %eax", {0xF7, 0xD0})
	expect_code(t, "not %rax", {0x48, 0xF7, 0xD0})
	expect_code(t, "inc %al", {0xFE, 0xC0})
	expect_code(t, "inc %ax", {0x66, 0xFF, 0xC0})
	expect_code(t, "inc %eax", {0xFF, 0xC0})
	expect_code(t, "inc %rdx", {0x48, 0xFF, 0xC2})
	expect_code(t, "dec %rcx", {0x48, 0xFF, 0xC9})
}

@(test)
shifts_have_the_bytes_of_the_manual :: proc(t: ^testing.T) {
	// Implicit 1-operand, $0, $1, $imm8, and %cl across 8/16/32/64 bits.
	expect_code(t, "shl %al", {0xD0, 0xE0})
	expect_code(t, "shl $1, %al", {0xD0, 0xE0})
	expect_code(t, "shl $0, %al", {0xC0, 0xE0, 0x00})
	expect_code(t, "shl $3, %al", {0xC0, 0xE0, 0x03})
	expect_code(t, "shl %cl, %al", {0xD2, 0xE0})
	expect_code(t, "shl %cl, %sil", {0x40, 0xD2, 0xE6})
	expect_code(t, "shl %cl, %ah", {0xD2, 0xE4})
	expect_code(t, "shl $1, %ax", {0x66, 0xD1, 0xE0})
	expect_code(t, "shl $3, %ax", {0x66, 0xC1, 0xE0, 0x03})
	expect_code(t, "shl %cl, %ax", {0x66, 0xD3, 0xE0})
	expect_code(t, "shl $1, %eax", {0xD1, 0xE0})
	expect_code(t, "shl $3, %eax", {0xC1, 0xE0, 0x03})
	expect_code(t, "shl %cl, %eax", {0xD3, 0xE0})
	expect_code(t, "shl $1, %rax", {0x48, 0xD1, 0xE0})
	expect_code(t, "shl $8, %rax", {0x48, 0xC1, 0xE0, 0x08})
	expect_code(t, "shl %cl, %rax", {0x48, 0xD3, 0xE0})
	expect_code(t, "sal $4, %r8", {0x49, 0xC1, 0xE0, 0x04})
	expect_code(t, "shr %rdi", {0x48, 0xD1, 0xEF})
	expect_code(t, "shr $8, %rax", {0x48, 0xC1, 0xE8, 0x08})
	expect_code(t, "shr %cl, %r9", {0x49, 0xD3, 0xE9})
	expect_code(t, "sar $2, %eax", {0xC1, 0xF8, 0x02})
	expect_code(t, "sar %cl, %rax", {0x48, 0xD3, 0xF8})
	expect_code(t, "sarq $1, (%rbp,%rcx,8)", {0x48, 0xD1, 0x7C, 0xCD, 0x00})
	expect_code(t, "shrq %cl, (%r12)", {0x49, 0xD3, 0x2C, 0x24})
}

@(test)
conditional_sets_extending_moves_and_indirect_branches_have_the_bytes_of_the_manual :: proc(t: ^testing.T) {
	// Every SETcc condition and alias: 0F 90+cc C0 on %al.
	for member in Condition {
		for item in MNEMONICS {
			if item.operation != .Set_If || item.condition != member {
				continue
			}
			text := fmt.tprintf("%s %%al", item.name)
			expect_code(t, text, {0x0F, 0x90 | u8(member), 0xC0})
		}
	}
	// SETcc register classes and memory.
	expect_code(t, "sete %dil", {0x40, 0x0F, 0x94, 0xC7})
	expect_code(t, "sete %ah", {0x0F, 0x94, 0xC4})
	expect_code(t, "sete %r8b", {0x41, 0x0F, 0x94, 0xC0})
	expect_code(t, "setne (%r12)", {0x41, 0x0F, 0x95, 0x04, 0x24})
	expect_code(t, "setle 4(%rbp)", {0x0F, 0x9E, 0x45, 0x04})

	// Sign-extending and zero-extending moves: explicit, source-only, and unsized.
	expect_code(t, "movsbw %al, %ax", {0x66, 0x0F, 0xBE, 0xC0})
	expect_code(t, "movsbw (%rax), %ax", {0x66, 0x0F, 0xBE, 0x00})
	expect_code(t, "movsbl %al, %eax", {0x0F, 0xBE, 0xC0})
	expect_code(t, "movsbl %sil, %eax", {0x40, 0x0F, 0xBE, 0xC6})
	expect_code(t, "movsbl %ah, %eax", {0x0F, 0xBE, 0xC4})
	expect_code(t, "movsbl (%rax), %eax", {0x0F, 0xBE, 0x00})
	expect_code(t, "movsbq %al, %rax", {0x48, 0x0F, 0xBE, 0xC0})
	expect_code(t, "movsbq %sil, %rax", {0x48, 0x0F, 0xBE, 0xC6})
	expect_code(t, "movsbq (%r8,%r9,1), %r10", {0x4F, 0x0F, 0xBE, 0x14, 0x08})
	expect_code(t, "movswl %ax, %eax", {0x0F, 0xBF, 0xC0})
	expect_code(t, "movswl (%rax), %eax", {0x0F, 0xBF, 0x00})
	expect_code(t, "movswq %ax, %rax", {0x48, 0x0F, 0xBF, 0xC0})
	expect_code(t, "movswq (%rax), %rax", {0x48, 0x0F, 0xBF, 0x00})
	expect_code(t, "movslq %eax, %rax", {0x48, 0x63, 0xC0})
	expect_code(t, "movslq (%rax), %r8", {0x4C, 0x63, 0x00})
	expect_code(t, "movsb %al, %rax", {0x48, 0x0F, 0xBE, 0xC0})
	expect_code(t, "movsw (%rax), %r9", {0x4C, 0x0F, 0xBF, 0x08})
	expect_code(t, "movsx %al, %eax", {0x0F, 0xBE, 0xC0})
	expect_code(t, "movsx %eax, %rax", {0x48, 0x63, 0xC0})

	expect_code(t, "movzbw (%rax), %ax", {0x66, 0x0F, 0xB6, 0x00})
	expect_code(t, "movzbl %al, %eax", {0x0F, 0xB6, 0xC0})
	expect_code(t, "movzbl %cl, %eax", {0x0F, 0xB6, 0xC1})
	expect_code(t, "movzbl (%rax), %eax", {0x0F, 0xB6, 0x00})
	expect_code(t, "movzbq (%rax), %rax", {0x48, 0x0F, 0xB6, 0x00})
	expect_code(t, "movzwl %ax, %eax", {0x0F, 0xB7, 0xC0})
	expect_code(t, "movzwl (%rax), %eax", {0x0F, 0xB7, 0x00})
	expect_code(t, "movzwq (%rax), %rax", {0x48, 0x0F, 0xB7, 0x00})
	expect_code(t, "movzb %al, %rax", {0x48, 0x0F, 0xB6, 0xC0})
	expect_code(t, "movzw (%rax), %rcx", {0x48, 0x0F, 0xB7, 0x08})
	expect_code(t, "movzx %al, %eax", {0x0F, 0xB6, 0xC0})
	expect_code(t, "movzx %al, %rax", {0x48, 0x0F, 0xB6, 0xC0})
	expect_code(t, "movzx %ax, %rax", {0x48, 0x0F, 0xB7, 0xC0})

	// Zero-operand sign extensions and string store.
	expect_code(t, "cbw", {0x66, 0x98})
	expect_code(t, "cwtl", {0x98})
	expect_code(t, "cwde", {0x98})
	expect_code(t, "cltq", {0x48, 0x98})
	expect_code(t, "cdqe", {0x48, 0x98})
	expect_code(t, "cwd", {0x66, 0x99})
	expect_code(t, "cdq", {0x99})
	expect_code(t, "cltd", {0x99})
	expect_code(t, "cqo", {0x48, 0x99})
	expect_code(t, "cqto", {0x48, 0x99})
	expect_code(t, "stosb", {0xAA})
	expect_code(t, "rep stosb", {0xF3, 0xAA})

	// Indirect calls and jumps.
	expect_code(t, "call *%r10", {0x41, 0xFF, 0xD2})
	expect_code(t, "call *%rax", {0xFF, 0xD0})
	expect_code(t, "call *(%rax)", {0xFF, 0x10})
	expect_code(t, "call *8(%rbp)", {0xFF, 0x55, 0x08})
	expect_code(t, "jmp *%rax", {0xFF, 0xE0})
	expect_code(t, "jmp *%r11", {0x41, 0xFF, 0xE3})
	expect_code(t, "jmp *(%r12,%r13,8)", {0x43, 0xFF, 0x24, 0xEC})
	// RIP-relative indirect call to a pointer in data (4096 - 6).
	expect_code(t, "call *fn_ptr(%rip); ret; section data; fn_ptr: zero 8", {0xFF, 0x15, 0xFA, 0x0F, 0x00, 0x00, 0xC3})
}

@(test)
high_byte_register_rex_conflicts_are_refused :: proc(t: ^testing.T) {
	// %ah/%ch/%dh/%bh cannot appear in any instruction that needs a REX byte.
	expect_refusal(t, "mov %ah, %r8b", .Operand_Form_Not_Valid, 1, 5)
	expect_refusal(t, "mov %r8b, %bh", .Operand_Form_Not_Valid, 1, 11)
	expect_refusal(t, "mov %ah, %sil", .Operand_Form_Not_Valid, 1, 5)
	expect_refusal(t, "mov %dil, %ch", .Operand_Form_Not_Valid, 1, 11)
	expect_refusal(t, "mov %ah, (%r8)", .Operand_Form_Not_Valid, 1, 5)
	expect_refusal(t, "mov %ah, (%rax,%r9,2)", .Operand_Form_Not_Valid, 1, 5)
	expect_refusal(t, "mov (%r12), %dh", .Operand_Form_Not_Valid, 1, 13)
	expect_refusal(t, "movsbq %ah, %rax", .Operand_Form_Not_Valid, 1, 8)
	expect_refusal(t, "movsbl %ah, %r8d", .Operand_Form_Not_Valid, 1, 8)
	expect_refusal(t, "movzbq %bh, %rax", .Operand_Form_Not_Valid, 1, 8)
	expect_refusal(t, "add %ch, %dil", .Operand_Form_Not_Valid, 1, 5)
	expect_refusal(t, "test %dh, (%r12)", .Operand_Form_Not_Valid, 1, 6)
	expect_refusal(t, "cmp %ah, %spl", .Operand_Form_Not_Valid, 1, 5)
}

@(test)
malformed_sib_indirect_and_expanded_forms_are_refused :: proc(t: ^testing.T) {
	// SIB and memory operand refusals.
	expect_refusal(t, "mov (%rax,%rsp), %rcx", .Operand_Not_Valid, 1, 11)
	expect_refusal(t, "mov (,%rsp,4), %rcx", .Operand_Not_Valid, 1, 7)
	expect_refusal(t, "mov (%rax,%rcx,0), %rdx", .Operand_Not_Valid, 1, 16)
	expect_refusal(t, "mov (%rax,%rcx,3), %rdx", .Operand_Not_Valid, 1, 16)
	expect_refusal(t, "mov (%rax,%rcx,5), %rdx", .Operand_Not_Valid, 1, 16)
	expect_refusal(t, "mov (%rax,%rcx,16), %rdx", .Operand_Not_Valid, 1, 16)
	expect_refusal(t, "mov (%rax,%rcx,-1), %rdx", .Operand_Not_Valid, 1, 16)
	expect_refusal(t, "mov (%rax,%rcx,x), %rdx", .Number_Not_Valid, 1, 16)
	expect_refusal(t, "mov (%rip,%rax), %rcx", .Operand_Not_Valid, 1, 11)
	expect_refusal(t, "mov (%rax,%rip), %rcx", .Operand_Not_Valid, 1, 11)
	expect_refusal(t, "mov (), %rcx", .Operand_Not_Valid, 1, 6)
	expect_refusal(t, "mov (,), %rcx", .Operand_Not_Valid, 1, 7)
	expect_refusal(t, "mov (%rax,), %rcx", .Operand_Not_Valid, 1, 11)
	expect_refusal(t, "mov (,%rax,), %rcx", .Number_Not_Valid, 1, 12)
	expect_refusal(t, "mov (%rax,%ebx), %rcx", .Operand_Size_Wrong, 1, 11)
	expect_refusal(t, "mov (%rax,%bx,2), %rcx", .Operand_Size_Wrong, 1, 11)
	expect_refusal(t, "mov (%rax,%foo), %rcx", .Register_Unknown, 1, 11)
	expect_refusal(t, "mov x(%rax,%rbx,4), %rcx; x: ret", .Operand_Not_Valid, 1, 5)
	expect_refusal(t, "mov x(,%rax,4), %rcx; x: ret", .Operand_Not_Valid, 1, 5)
	expect_refusal(t, "mov 0x80000000(%rax,%rcx,4), %rdx", .Displacement_Too_Large, 1, 5)
	expect_refusal(t, "mov -0x80000001(,%rcx,4), %rdx", .Displacement_Too_Large, 1, 5)

	// Indirect operand refusals.
	expect_refusal(t, "call *%eax", .Operand_Size_Wrong, 1, 6)
	expect_refusal(t, "jmp *%r8d", .Operand_Size_Wrong, 1, 5)
	expect_refusal(t, "call *$1", .Operand_Not_Valid, 1, 6)
	expect_refusal(t, "call *target; target: ret", .Operand_Not_Valid, 1, 6)
	expect_refusal(t, "call **%rax", .Operand_Not_Valid, 1, 6)
	expect_refusal(t, "call *", .Operand_Not_Valid, 1, 6)
	expect_refusal(t, "mov *%rax, %rbx", .Operand_Form_Not_Valid, 1, 5)
	expect_refusal(t, "push *%rax", .Operand_Form_Not_Valid, 1, 6)
	expect_refusal(t, "je *%rax", .Operand_Form_Not_Valid, 1, 4)

	// Shift refusals.
	expect_refusal(t, "shl %al, %rax", .Operand_Form_Not_Valid, 1, 5)
	expect_refusal(t, "shl %ch, %rax", .Operand_Form_Not_Valid, 1, 5)
	expect_refusal(t, "shl %ecx, %rax", .Operand_Form_Not_Valid, 1, 5)
	expect_refusal(t, "shl %rcx, %rax", .Operand_Form_Not_Valid, 1, 5)
	expect_refusal(t, "shl (%rax), %rbx", .Operand_Form_Not_Valid, 1, 5)
	expect_refusal(t, "shl $-1, %rax", .Immediate_Too_Large, 1, 5)
	expect_refusal(t, "shl $256, %rax", .Immediate_Too_Large, 1, 5)
	expect_refusal(t, "shl $1, (%rax)", .Operand_Size_Unknown, 1, 1)
	expect_refusal(t, "shl %cl, (%rax)", .Operand_Size_Unknown, 1, 1)
	expect_refusal(t, "shl (%rax)", .Operand_Size_Unknown, 1, 1)
	expect_refusal(t, "shl", .Operand_Count_Wrong, 1, 1)
	expect_refusal(t, "shl $1, %rax, %rbx", .Operand_Count_Wrong, 1, 15)

	// IMUL refusals.
	expect_refusal(t, "imulb %al, %bl", .Operand_Size_Wrong, 1, 12)
	expect_refusal(t, "imul $3, %al", .Operand_Size_Wrong, 1, 10)
	expect_refusal(t, "imul $3, (%rax), %bl", .Operand_Size_Wrong, 1, 18)
	expect_refusal(t, "imul %rax, (%rbx)", .Operand_Form_Not_Valid, 1, 12)
	expect_refusal(t, "imul %rax, %rbx, %rcx", .Operand_Form_Not_Valid, 1, 6)
	expect_refusal(t, "imul $3, $4, %rax", .Operand_Form_Not_Valid, 1, 10)
	expect_refusal(t, "imul $3, (%rax), (%rbx)", .Operand_Form_Not_Valid, 1, 18)
	expect_refusal(t, "imul (%rax)", .Operand_Size_Unknown, 1, 1)
	expect_refusal(t, "imul", .Operand_Count_Wrong, 1, 1)
	expect_refusal(t, "imul $1, %rax, %rbx, %rcx", .Operand_Count_Wrong, 1, 22)
	expect_refusal(t, "imul $0x80000000, %rax", .Immediate_Too_Large, 1, 6)
	expect_refusal(t, "imulw $65536, %ax", .Immediate_Too_Large, 1, 7)
	expect_refusal(t, "imulw $-32769, %ax", .Immediate_Too_Large, 1, 7)

	// Unary, SETcc, TEST refusals.
	expect_refusal(t, "idiv $1", .Operand_Form_Not_Valid, 1, 6)
	expect_refusal(t, "neg $1", .Operand_Form_Not_Valid, 1, 5)
	expect_refusal(t, "not (%rax)", .Operand_Size_Unknown, 1, 1)
	expect_refusal(t, "inc (%rax)", .Operand_Size_Unknown, 1, 1)
	expect_refusal(t, "sete %eax", .Operand_Size_Wrong, 1, 6)
	expect_refusal(t, "sete %rax", .Operand_Size_Wrong, 1, 6)
	expect_refusal(t, "sete %ax", .Operand_Size_Wrong, 1, 6)
	expect_refusal(t, "sete $1", .Operand_Form_Not_Valid, 1, 6)
	expect_refusal(t, "seteb %al", .Mnemonic_Unknown, 1, 1)
	expect_refusal(t, "test $1, (%rax)", .Operand_Size_Unknown, 1, 1)
	expect_refusal(t, "test (%rax), (%rbx)", .Operand_Form_Not_Valid, 1, 6)
	expect_refusal(t, "test $256, %al", .Immediate_Too_Large, 1, 6)
	expect_refusal(t, "test $-129, %al", .Immediate_Too_Large, 1, 6)
	expect_refusal(t, "test $65536, %ax", .Immediate_Too_Large, 1, 6)
	expect_refusal(t, "test $-32769, %ax", .Immediate_Too_Large, 1, 6)

	// Extending move refusals.
	expect_refusal(t, "movsb %al, %al", .Operand_Size_Wrong, 1, 12)
	expect_refusal(t, "movsw %ax, %ax", .Operand_Size_Wrong, 1, 12)
	expect_refusal(t, "movzw %ax, %al", .Operand_Size_Wrong, 1, 12)
	expect_refusal(t, "movzx %eax, %rax", .Operand_Size_Wrong, 1, 7)
	expect_refusal(t, "movsx %rax, %rax", .Operand_Size_Wrong, 1, 7)
	expect_refusal(t, "movzx (%rax), %eax", .Operand_Size_Unknown, 1, 1)
	expect_refusal(t, "movsx (%rax), %rax", .Operand_Size_Unknown, 1, 1)
	expect_refusal(t, "movsbl %ax, %eax", .Operand_Size_Wrong, 1, 8)
	expect_refusal(t, "movsbq %al, %eax", .Operand_Size_Wrong, 1, 13)
	expect_refusal(t, "movzbl %al, (%rax)", .Operand_Form_Not_Valid, 1, 13)
	expect_refusal(t, "movzbl $1, %eax", .Operand_Form_Not_Valid, 1, 8)

	// 8/16-bit immediate bounds and invalid suffixes on push/pop/lea.
	expect_refusal(t, "movb $256, %al", .Immediate_Too_Large, 1, 6)
	expect_refusal(t, "movb $-129, %al", .Immediate_Too_Large, 1, 6)
	expect_refusal(t, "movw $65536, %ax", .Immediate_Too_Large, 1, 6)
	expect_refusal(t, "movw $-32769, %ax", .Immediate_Too_Large, 1, 6)
	expect_refusal(t, "addb $256, %al", .Immediate_Too_Large, 1, 6)
	expect_refusal(t, "addw $-32769, %ax", .Immediate_Too_Large, 1, 6)
	expect_refusal(t, "pushb %rax", .Operand_Size_Wrong, 1, 1)
	expect_refusal(t, "pushw %rax", .Operand_Size_Wrong, 1, 1)
	expect_refusal(t, "leab (%rax), %rax", .Operand_Size_Wrong, 1, 1)
	expect_refusal(t, "leaw (%rax), %rax", .Operand_Size_Wrong, 1, 1)

	// REP and zero-operand instruction refusals.
	expect_refusal(t, "rep", .Mnemonic_Unknown, 1, 1)
	expect_refusal(t, "rep ret", .Mnemonic_Unknown, 1, 5)
	expect_refusal(t, "section data; rep stosb", .Instruction_In_Data, 1, 15)
	expect_refusal(t, "cqo %rax", .Operand_Count_Wrong, 1, 1)
	expect_refusal(t, "cdq %eax", .Operand_Count_Wrong, 1, 1)
	expect_refusal(t, "stosb %al", .Operand_Count_Wrong, 1, 1)
	expect_refusal(t, "rep stosb %al", .Operand_Count_Wrong, 1, 1)
}
