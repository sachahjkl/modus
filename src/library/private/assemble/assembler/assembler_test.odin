#+build !freestanding
package assembler

import "base:intrinsics"
import module "modus:contract/module"
import writer "modus:contract/module_file_writer"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:testing"

// expect_code assembles a text and compares the bytes of its code with the
// bytes of the Intel manual.
@(private = "file")
expect_code :: proc(t: ^testing.T, text: string, expected: []u8, loc := #caller_location) {
	workspace := new(Workspace)
	defer free(workspace)
	_, refusal := assemble(text, workspace)
	if !testing.expectf(t, refusal.refusal == .None, "%q: refused with %v at line %d, column %d", text, refusal.refusal, refusal.place.line, refusal.place.column, loc = loc) {
		return
	}
	code := workspace.code[:workspace.stored[.Code]]
	testing.expectf(t, string(code) == string(expected), "%q: the bytes are % 02X, the manual gives % 02X", text, code, expected, loc = loc)
}

// expect_refusal assembles a text that must be refused, and checks the
// refusal, its place, and that no part is given.
@(private = "file")
expect_refusal :: proc(t: ^testing.T, text: string, refusal: Refusal, line: u32, column: u32, loc := #caller_location) -> Refusal_Record {
	workspace := new(Workspace)
	defer free(workspace)
	parts, record := assemble(text, workspace)
	testing.expectf(t, record.refusal == refusal, "%q: the refusal is %v, not %v", text, record.refusal, refusal, loc = loc)
	testing.expectf(t, record.place.line == line && record.place.column == column, "%q: the place is line %d, column %d, not line %d, column %d", text, record.place.line, record.place.column, line, column, loc = loc)
	testing.expectf(t, record.place == place_of_offset(text, int(record.place.offset)), "%q: the offset %d is not at line %d, column %d", text, record.place.offset, record.place.line, record.place.column, loc = loc)
	testing.expectf(t, parts.segments == nil && parts.exports == nil, "%q: a refused text gave parts", text, loc = loc)
	return record
}

@(test)
moves_have_the_bytes_of_the_manual :: proc(t: ^testing.T) {
	expect_code(t, "mov %rdi, %rax", {0x48, 0x89, 0xF8})
	expect_code(t, "movq %r8, %r15", {0x4D, 0x89, 0xC7})
	expect_code(t, "mov %eax, %ecx", {0x89, 0xC1})
	expect_code(t, "movl %r9d, %eax", {0x44, 0x89, 0xC8})
	expect_code(t, "mov $1, %rax", {0x48, 0xC7, 0xC0, 0x01, 0x00, 0x00, 0x00})
	expect_code(t, "mov $-1, %rax", {0x48, 0xC7, 0xC0, 0xFF, 0xFF, 0xFF, 0xFF})
	// Past 32 bits with a sign: the form B8+rd with 8 bytes.
	expect_code(t, "mov $0x123456789, %rax", {0x48, 0xB8, 0x89, 0x67, 0x45, 0x23, 0x01, 0x00, 0x00, 0x00})
	expect_code(t, "mov $0xFFFFFFFFFFFFFFFF, %r11", {0x49, 0xBB, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF})
	expect_code(t, "mov $-0x8000000000000000, %rax", {0x48, 0xB8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80})
	expect_code(t, "mov $5, %r10d", {0x41, 0xBA, 0x05, 0x00, 0x00, 0x00})
	expect_code(t, "mov $0xFFFFFFFF, %eax", {0xB8, 0xFF, 0xFF, 0xFF, 0xFF})
	expect_code(t, "mov $-0x80000000, %eax", {0xB8, 0x00, 0x00, 0x00, 0x80})
	// Memory: each mode of ModRM, and the bases that need a byte more.
	expect_code(t, "mov (%rax), %rcx", {0x48, 0x8B, 0x08})
	expect_code(t, "mov 8(%rbp), %rax", {0x48, 0x8B, 0x45, 0x08})
	expect_code(t, "mov %rax, -16(%rsp)", {0x48, 0x89, 0x44, 0x24, 0xF0})
	expect_code(t, "mov (%rbp), %rcx", {0x48, 0x8B, 0x4D, 0x00})
	expect_code(t, "mov (%r13), %rcx", {0x49, 0x8B, 0x4D, 0x00})
	expect_code(t, "mov (%r12), %rcx", {0x49, 0x8B, 0x0C, 0x24})
	expect_code(t, "mov 127(%rbx), %rdx", {0x48, 0x8B, 0x53, 0x7F})
	expect_code(t, "mov -128(%rbx), %rdx", {0x48, 0x8B, 0x53, 0x80})
	expect_code(t, "mov 128(%rbx), %rdx", {0x48, 0x8B, 0x93, 0x80, 0x00, 0x00, 0x00})
	expect_code(t, "mov -129(%rbx), %rdx", {0x48, 0x8B, 0x93, 0x7F, 0xFF, 0xFF, 0xFF})
	expect_code(t, "mov 0x7FFFFFFF(%rax), %rbx", {0x48, 0x8B, 0x98, 0xFF, 0xFF, 0xFF, 0x7F})
	expect_code(t, "mov 0x1000(%rbx), %rdx", {0x48, 0x8B, 0x93, 0x00, 0x10, 0x00, 0x00})
	expect_code(t, "mov %r8d, 4(%r9)", {0x45, 0x89, 0x41, 0x04})
	expect_code(t, "movq $7, 8(%rdi)", {0x48, 0xC7, 0x47, 0x08, 0x07, 0x00, 0x00, 0x00})
	expect_code(t, "movl $7, (%rax)", {0xC7, 0x00, 0x07, 0x00, 0x00, 0x00})
	// A blank, a tab and a comment change no byte.
	expect_code(t, "\tmov   %rdi ,%rax   # the first argument", {0x48, 0x89, 0xF8})
}

@(test)
arithmetic_has_the_bytes_of_the_manual :: proc(t: ^testing.T) {
	expect_code(t, "add %rsi, %rax", {0x48, 0x01, 0xF0})
	expect_code(t, "add %eax, %ebx", {0x01, 0xC3})
	expect_code(t, "add 8(%rsp), %r14", {0x4C, 0x03, 0x74, 0x24, 0x08})
	// The edges of the short form 83 ib, then the form 81 id.
	expect_code(t, "add $1, %rax", {0x48, 0x83, 0xC0, 0x01})
	expect_code(t, "add $127, %rax", {0x48, 0x83, 0xC0, 0x7F})
	expect_code(t, "add $-128, %rax", {0x48, 0x83, 0xC0, 0x80})
	expect_code(t, "add $128, %rax", {0x48, 0x81, 0xC0, 0x80, 0x00, 0x00, 0x00})
	expect_code(t, "add $1000, %rax", {0x48, 0x81, 0xC0, 0xE8, 0x03, 0x00, 0x00})
	expect_code(t, "add $0x7FFFFFFF, %rax", {0x48, 0x81, 0xC0, 0xFF, 0xFF, 0xFF, 0x7F})
	expect_code(t, "add $-0x80000000, %rax", {0x48, 0x81, 0xC0, 0x00, 0x00, 0x00, 0x80})
	// The 32 bits of 0xFFFFFFFF are -1 for the processor: the short form.
	expect_code(t, "addl $0xFFFFFFFF, %eax", {0x83, 0xC0, 0xFF})
	expect_code(t, "sub $8, %rsp", {0x48, 0x83, 0xEC, 0x08})
	expect_code(t, "sub 16(%rbp), %rax", {0x48, 0x2B, 0x45, 0x10})
	expect_code(t, "sub %rax, (%rdi)", {0x48, 0x29, 0x07})
	expect_code(t, "cmp %rcx, %rax", {0x48, 0x39, 0xC8})
	expect_code(t, "cmp $10, %rdi", {0x48, 0x83, 0xFF, 0x0A})
	expect_code(t, "cmp $0x80, %rax", {0x48, 0x81, 0xF8, 0x80, 0x00, 0x00, 0x00})
	expect_code(t, "cmpq $-1, (%rax)", {0x48, 0x83, 0x38, 0xFF})
	expect_code(t, "cmpl $0, 4(%r12)", {0x41, 0x83, 0x7C, 0x24, 0x04, 0x00})
}

@(test)
addresses_and_the_stack_have_the_bytes_of_the_manual :: proc(t: ^testing.T) {
	expect_code(t, "lea 8(%rsp), %rbp", {0x48, 0x8D, 0x6C, 0x24, 0x08})
	expect_code(t, "leaq (%r15), %r8", {0x4D, 0x8D, 0x07})
	expect_code(t, "lea 16(%rip), %rax", {0x48, 0x8D, 0x05, 0x10, 0x00, 0x00, 0x00})
	expect_code(t, "push %rbp", {0x55})
	expect_code(t, "pushq %r12", {0x41, 0x54})
	expect_code(t, "pop %rbp", {0x5D})
	expect_code(t, "popq %r15", {0x41, 0x5F})
	expect_code(t, "push $1", {0x6A, 0x01})
	expect_code(t, "push $-1", {0x6A, 0xFF})
	expect_code(t, "push $1000", {0x68, 0xE8, 0x03, 0x00, 0x00})
	expect_code(t, "ret", {0xC3})
}

@(test)
jumps_and_labels_have_the_bytes_of_the_manual :: proc(t: ^testing.T) {
	// The displacement counts from the end of the instruction.
	expect_code(t, "jmp next; next: ret", {0xE9, 0x00, 0x00, 0x00, 0x00, 0xC3})
	expect_code(t, "top: jmp top", {0xE9, 0xFB, 0xFF, 0xFF, 0xFF})
	expect_code(t, "call f; ret; f: ret", {0xE8, 0x01, 0x00, 0x00, 0x00, 0xC3, 0xC3})
	// Each condition: 0F 80+cc, back to itself, 6 bytes.
	for member in Condition {
		for item in MNEMONICS {
			if item.operation != .Jump_If || item.condition != member {
				continue
			}
			text := fmt.tprintf("top: %s top", item.name)
			expect_code(t, text, {0x0F, 0x80 | u8(member), 0xFA, 0xFF, 0xFF, 0xFF})
		}
	}
	// A label on its own line, and two labels at one place.
	expect_code(t, "first:\nsecond: jne first", {0x0F, 0x85, 0xFA, 0xFF, 0xFF, 0xFF})
	// A label of the data, from the end of the instruction: the data starts
	// on the page after the code, 4096 - 7.
	expect_code(t, "lea value(%rip), %rax; ret; section data; value: byte 42", {0x48, 0x8D, 0x05, 0xF9, 0x0F, 0x00, 0x00, 0xC3})
	// The immediate comes after the displacement: the end is after it, 4096 - 11.
	expect_code(t, "movq $1, value(%rip); ret; section data; value: zero 8", {0x48, 0xC7, 0x05, 0xF5, 0x0F, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0xC3})
}

@(test)
data_bytes_and_zero_bytes :: proc(t: ^testing.T) {
	workspace := new(Workspace)
	defer free(workspace)
	parts, refusal := assemble("ret; section data; byte 1, 0x41, -1, 255, -128; zero 3; byte 2", workspace)
	testing.expect_value(t, refusal.refusal, Refusal.None)
	testing.expect_value(t, len(parts.segments), 2)
	expected := [?]u8{1, 0x41, 0xFF, 0xFF, 0x80, 0, 0, 0, 2}
	testing.expect_value(t, string(parts.segments[1].data), string(expected[:]))
	testing.expect_value(t, parts.segments[1].memory_offset, u64(module.PAGE_SIZE))
	testing.expect_value(t, parts.segments[1].flags, module.Segment_Flags{.Read, .Write})
	testing.expect_value(t, parts.segments[0].flags, module.Segment_Flags{.Read, .Execute})

	// Zero bytes at the end are not stored: the extent grows, the data does
	// not. The largest extent passes.
	parts, refusal = assemble("ret; section data; byte 7; zero 0xFFFFFFFFFF", workspace)
	testing.expect_value(t, refusal.refusal, Refusal.None)
	testing.expect_value(t, len(parts.segments[1].data), 1)
	testing.expect_value(t, parts.segments[1].memory_size, SECTION_EXTENT_MOST)
}

@(test)
texts_past_their_bounds_are_refused :: proc(t: ^testing.T) {
	expect_refusal(t, "", .Text_Empty, 1, 1)

	// The bound of the text, then one byte more.
	at_bound := strings.concatenate({"ret", strings.repeat("\n", TEXT_BYTES_MOST - 3, context.temp_allocator)}, context.temp_allocator)
	expect_code(t, at_bound, {0xC3})
	past_bound := strings.concatenate({at_bound, "\n"}, context.temp_allocator)
	record := expect_refusal(t, past_bound, .Text_Too_Long, TEXT_BYTES_MOST - 2, 1)
	testing.expect_value(t, record.value, u64(TEXT_BYTES_MOST + 1))

	// A line of the bound, then a line of one byte more.
	line_at_bound := strings.concatenate({"ret\n#", strings.repeat("x", LINE_BYTES_MOST - 1, context.temp_allocator)}, context.temp_allocator)
	expect_code(t, line_at_bound, {0xC3})
	line_past_bound := strings.concatenate({line_at_bound, "x\nret"}, context.temp_allocator)
	record = expect_refusal(t, line_past_bound, .Line_Too_Long, 2, LINE_BYTES_MOST + 1)
	testing.expect_value(t, record.value, u64(LINE_BYTES_MOST + 1))

	// The code: 65 536 bytes, then one more.
	code_at_bound := strings.repeat("ret\n", CODE_BYTES_MOST, context.temp_allocator)
	workspace := new(Workspace)
	defer free(workspace)
	_, refusal := assemble(code_at_bound, workspace)
	testing.expect_value(t, refusal.refusal, Refusal.None)
	record = expect_refusal(t, strings.concatenate({code_at_bound, "ret"}, context.temp_allocator), .Section_Past_Capacity, CODE_BYTES_MOST + 1, 1)
	testing.expect_value(t, record.value, u64(CODE_BYTES_MOST + 1))

	// The data: its last byte, then one past it; an extent past its bound.
	expect_code(t, "ret; section data; zero 65535; byte 1", {0xC3})
	record = expect_refusal(t, "ret; section data; zero 65536; byte 1", .Section_Past_Capacity, 1, 37)
	testing.expect_value(t, record.value, u64(DATA_BYTES_MOST + 1))
	record = expect_refusal(t, "section data; zero 0x10000000001", .Section_Past_Capacity, 1, 20)
	testing.expect_value(t, record.value, SECTION_EXTENT_MOST + 1)
	expect_refusal(t, "ret; section data; zero 0x10000000000; zero 1", .Section_Past_Capacity, 1, 45)

	expect_refusal(t, "# a comment and no instruction", .No_Instruction, 1, 1)
	expect_refusal(t, "section data; byte 1", .No_Instruction, 1, 1)
}

@(test)
bytes_that_are_no_text_are_refused :: proc(t: ^testing.T) {
	record := expect_refusal(t, "ret\x01", .Character_Not_Valid, 1, 4)
	testing.expect_value(t, record.value, u64(1))
	record = expect_refusal(t, "ret\r\nret", .Character_Not_Valid, 1, 4)
	testing.expect_value(t, record.value, u64('\r'))
	record = expect_refusal(t, "ret\n\x7F", .Character_Not_Valid, 2, 1)
	testing.expect_value(t, record.value, u64(0x7F))
	record = expect_refusal(t, "jmp é", .Character_Not_Valid, 1, 5)
	testing.expect_value(t, record.value, u64(0xC3))
	// A byte past ASCII in a comment, and a tab, are text.
	expect_code(t, "\tret # é", {0xC3})
}

@(test)
unknown_words_are_refused :: proc(t: ^testing.T) {
	expect_refusal(t, "movx %rax, %rbx", .Mnemonic_Unknown, 1, 1)
	expect_refusal(t, "  frob", .Mnemonic_Unknown, 1, 3)
	// A suffix on a word that takes none, and a suffix that is no size.
	expect_refusal(t, "retq", .Mnemonic_Unknown, 1, 1)
	expect_refusal(t, "jmpq top; top: ret", .Mnemonic_Unknown, 1, 1)
	expect_refusal(t, "movb %al, %bl", .Mnemonic_Unknown, 1, 1)
	expect_refusal(t, "q", .Mnemonic_Unknown, 1, 1)
	expect_refusal(t, "$1", .Mnemonic_Unknown, 1, 1)
	expect_refusal(t, "mov %rax, %rzz", .Register_Unknown, 1, 11)
	expect_refusal(t, "mov (%foo), %rax", .Register_Unknown, 1, 6)
	expect_refusal(t, "section text", .Section_Unknown, 1, 9)
	expect_refusal(t, "section", .Section_Unknown, 1, 8)
	expect_refusal(t, "export f(a: Record); f: ret", .Type_Unknown, 1, 13)
	expect_refusal(t, "export f() -> Text; f: ret", .Type_Unknown, 1, 15)
	expect_refusal(t, "export f() -> ; f: ret", .Type_Unknown, 1, 15)
}

@(test)
operands_out_of_the_subset_are_refused :: proc(t: ^testing.T) {
	// An index register, an absolute address, %rip alone, a label from a
	// base that is not %rip, no comma, no base after the parenthesis.
	expect_refusal(t, "mov (%rax,%rbx), %rcx", .Operand_Not_Valid, 1, 10)
	expect_refusal(t, "mov 4096, %rax", .Operand_Not_Valid, 1, 5)
	expect_refusal(t, "mov %rip, %rax", .Operand_Not_Valid, 1, 5)
	expect_refusal(t, "mov table(%rax), %rcx; table: ret", .Operand_Not_Valid, 1, 5)
	expect_refusal(t, "mov %rax %rbx", .Operand_Not_Valid, 1, 10)
	expect_refusal(t, "mov 8(rax), %rbx", .Operand_Not_Valid, 1, 7)
	expect_refusal(t, "mov %rax,", .Operand_Not_Valid, 1, 10)

	record := expect_refusal(t, "ret %rax", .Operand_Count_Wrong, 1, 1)
	testing.expect_value(t, record.value, u64(1))
	record = expect_refusal(t, "push", .Operand_Count_Wrong, 1, 1)
	testing.expect_value(t, record.value, u64(0))
	expect_refusal(t, "mov %rax", .Operand_Count_Wrong, 1, 1)
	record = expect_refusal(t, "mov %rax, %rbx, %rcx", .Operand_Count_Wrong, 1, 17)
	testing.expect_value(t, record.value, u64(3))

	expect_refusal(t, "mov (%rax), (%rbx)", .Operand_Form_Not_Valid, 1, 5)
	expect_refusal(t, "mov $1, $2", .Operand_Form_Not_Valid, 1, 9)
	expect_refusal(t, "mov x, %rax; x: ret", .Operand_Form_Not_Valid, 1, 5)
	expect_refusal(t, "push (%rax)", .Operand_Form_Not_Valid, 1, 6)
	expect_refusal(t, "pop $1", .Operand_Form_Not_Valid, 1, 5)
	expect_refusal(t, "lea %rax, %rbx", .Operand_Form_Not_Valid, 1, 5)
	expect_refusal(t, "lea (%rax), 8(%rbx)", .Operand_Form_Not_Valid, 1, 13)
	expect_refusal(t, "jmp %rax", .Operand_Form_Not_Valid, 1, 5)
	expect_refusal(t, "section data; ret", .Instruction_In_Data, 1, 15)
}

@(test)
operands_of_the_wrong_size_are_refused :: proc(t: ^testing.T) {
	expect_refusal(t, "mov %eax, %rbx", .Operand_Size_Wrong, 1, 11)
	expect_refusal(t, "movl %rax, %rbx", .Operand_Size_Wrong, 1, 6)
	expect_refusal(t, "addq %eax, %ebx", .Operand_Size_Wrong, 1, 6)
	expect_refusal(t, "push %eax", .Operand_Size_Wrong, 1, 6)
	expect_refusal(t, "pushl %rax", .Operand_Size_Wrong, 1, 1)
	expect_refusal(t, "pushl $1", .Operand_Size_Wrong, 1, 1)
	expect_refusal(t, "lea (%rax), %eax", .Operand_Size_Wrong, 1, 13)
	expect_refusal(t, "lea (%eax), %rax", .Operand_Size_Wrong, 1, 6)
	expect_refusal(t, "leal (%rax), %rax", .Operand_Size_Wrong, 1, 1)
	// No register and no suffix: the size is not known.
	expect_refusal(t, "mov $1, (%rax)", .Operand_Size_Unknown, 1, 1)
	expect_refusal(t, "add $1, 8(%rbp)", .Operand_Size_Unknown, 1, 1)
}

@(test)
values_past_their_fields_are_refused :: proc(t: ^testing.T) {
	// One past each edge that the encodings above take.
	expect_refusal(t, "add $0x80000000, %rax", .Immediate_Too_Large, 1, 5)
	expect_refusal(t, "add $-0x80000001, %rax", .Immediate_Too_Large, 1, 5)
	expect_refusal(t, "mov $0x10000000000000000, %rax", .Immediate_Too_Large, 1, 5)
	expect_refusal(t, "mov $-0x8000000000000001, %rax", .Immediate_Too_Large, 1, 5)
	// A number far past 64 bits does not wrap to a small one.
	expect_refusal(t, "mov $0x1000000000000000000000000000000001, %rax", .Immediate_Too_Large, 1, 5)
	expect_refusal(t, "mov $0x100000000, %eax", .Immediate_Too_Large, 1, 5)
	expect_refusal(t, "mov $-0x80000001, %eax", .Immediate_Too_Large, 1, 5)
	expect_refusal(t, "movq $0x80000000, (%rax)", .Immediate_Too_Large, 1, 6)
	expect_refusal(t, "push $0x80000000", .Immediate_Too_Large, 1, 6)
	expect_refusal(t, "push $-0x80000001", .Immediate_Too_Large, 1, 6)
	expect_refusal(t, "section data; byte 256", .Immediate_Too_Large, 1, 20)
	expect_refusal(t, "section data; byte -129", .Immediate_Too_Large, 1, 20)
	expect_refusal(t, "mov 0x80000000(%rax), %rbx", .Displacement_Too_Large, 1, 5)
	expect_refusal(t, "mov -0x80000001(%rax), %rbx", .Displacement_Too_Large, 1, 5)
	expect_refusal(t, "lea 0x80000000(%rip), %rbx", .Displacement_Too_Large, 1, 5)

	expect_refusal(t, "mov $, %rax", .Number_Not_Valid, 1, 5)
	expect_refusal(t, "mov $12ab, %rax", .Number_Not_Valid, 1, 5)
	expect_refusal(t, "mov $0x, %rax", .Number_Not_Valid, 1, 5)
	expect_refusal(t, "mov $-, %rax", .Number_Not_Valid, 1, 5)
	expect_refusal(t, "section data; byte x", .Number_Not_Valid, 1, 20)
	expect_refusal(t, "section data; zero -1", .Number_Not_Valid, 1, 20)
}

@(test)
labels_that_break_a_rule_are_refused :: proc(t: ^testing.T) {
	record := expect_refusal(t, "a: ret\na: ret", .Label_Defined_Twice, 2, 1)
	testing.expect_value(t, record.value, u64(1))
	record = expect_refusal(t, "a: a: ret", .Label_Defined_Twice, 1, 4)
	testing.expect_value(t, record.value, u64(1))
	// The place of a label never defined is its first use.
	expect_refusal(t, "jmp nowhere", .Label_Not_Defined, 1, 5)
	expect_refusal(t, "ret; lea x(%rip), %rax; jmp x", .Label_Not_Defined, 1, 10)
	expect_refusal(t, "export f(); ret", .Label_Not_Defined, 1, 8)
	expect_refusal(t, "jmp x; section data; x: byte 1", .Label_In_Wrong_Section, 1, 5)
	expect_refusal(t, "export x(); ret; section data; x: byte 1", .Label_In_Wrong_Section, 1, 8)
	expect_refusal(t, "1abc: ret", .Label_Not_Valid, 1, 1)

	// A name of 255 bytes, then of 256.
	name := strings.repeat("a", writer.NAME_BYTES_MOST, context.temp_allocator)
	expect_code(t, strings.concatenate({name, ": ret"}, context.temp_allocator), {0xC3})
	expect_refusal(t, strings.concatenate({name, "a: ret"}, context.temp_allocator), .Label_Not_Valid, 1, 1)
}

@(test)
a_distance_past_2_gibibytes_is_refused :: proc(t: ^testing.T) {
	// lea is 7 bytes and ret 1: the data is at 4096, and the label after
	// `zero count` is 4096 + count - 7 bytes after the end of lea.
	LARGEST_DISTANCE :: i64(max(i32))
	count_at_bound := LARGEST_DISTANCE - (module.PAGE_SIZE - 7)
	text := fmt.tprintf("lea far(%%rip), %%rax; ret; section data; zero %d; far:", count_at_bound)
	expect_code(t, text, {0x48, 0x8D, 0x05, 0xFF, 0xFF, 0xFF, 0x7F, 0xC3})
	text = fmt.tprintf("lea far(%%rip), %%rax; ret; section data; zero %d; far:", count_at_bound + 1)
	record := expect_refusal(t, text, .Distance_Too_Large, 1, 5)
	testing.expect_value(t, record.value, u64(module.PAGE_SIZE + count_at_bound + 1))

	// A jump: no text holds 2 GiB of code, so the label is moved after the
	// statements are read, then the references are written.
	workspace := new(Workspace)
	defer free(workspace)
	jump_text := "jmp far; far: ret"
	for move in ([]i128{i128(max(i32)), i128(max(i32)) + 1}) {
		intrinsics.mem_zero(workspace, size_of(Workspace))
		testing.expect_value(t, statements_read(jump_text, workspace).refusal, Refusal.None)
		far := label_find(workspace, "far")
		jump_end := workspace.labels[far].offset
		workspace.labels[far].offset = u64(i128(jump_end) + move)
		resolved := references_resolve(workspace)
		if move == i128(max(i32)) {
			testing.expect_value(t, resolved.refusal, Refusal.None)
			expected := [5]u8{0xE9, 0xFF, 0xFF, 0xFF, 0x7F}
			testing.expect_value(t, string(workspace.code[:5]), string(expected[:]))
		} else {
			testing.expect_value(t, resolved.refusal, Refusal.Distance_Too_Large)
			testing.expect_value(t, resolved.place.line, u32(1))
			testing.expect_value(t, resolved.place.column, u32(5))
		}
	}
}

@(test)
exports_that_break_a_rule_are_refused :: proc(t: ^testing.T) {
	expect_refusal(t, "export f; f: ret", .Directive_Not_Valid, 1, 9)
	expect_refusal(t, "export f(a Integer); f: ret", .Directive_Not_Valid, 1, 12)
	expect_refusal(t, "export f() Integer; f: ret", .Directive_Not_Valid, 1, 12)
	expect_refusal(t, "export f() - Integer; f: ret", .Directive_Not_Valid, 1, 13)
	expect_refusal(t, "export f(a: Integer b: Integer); f: ret", .Directive_Not_Valid, 1, 21)
	expect_refusal(t, "section code x", .Directive_Not_Valid, 1, 14)
	expect_refusal(t, "ret; section data; byte 1 2", .Directive_Not_Valid, 1, 27)
	expect_refusal(t, "ret; section data; zero 4 4", .Directive_Not_Valid, 1, 27)
	expect_refusal(t, "export f(); export f(); f: ret", .Export_Twice, 1, 20)
	expect_refusal(t, "export f.g(); f.g: ret", .Name_Not_Valid, 1, 8)
	expect_refusal(t, "export (); ret", .Name_Not_Valid, 1, 8)
	expect_refusal(t, "export f(1a: Integer); f: ret", .Name_Not_Valid, 1, 10)

	// 12 parameters, then 13.
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "export f(")
	for index in 0 ..< module.PARAMETER_CAPACITY {
		fmt.sbprintf(&builder, "%sp%d: Integer", index == 0 ? "" : ", ", index)
	}
	twelve := strings.to_string(builder)
	expect_code(t, strings.concatenate({twelve, ") -> Integer; f: ret"}, context.temp_allocator), {0xC3})
	thirteen := strings.concatenate({twelve, ", last: Integer); f: ret"}, context.temp_allocator)
	record := expect_refusal(t, thirteen, .Too_Many_Parameters, 1, u32(len(twelve) + 3))
	testing.expect_value(t, record.value, u64(module.PARAMETER_CAPACITY + 1))
}

@(test)
tables_past_their_capacity_are_refused :: proc(t: ^testing.T) {
	// 512 labels, then 513.
	builder := strings.builder_make(context.temp_allocator)
	for index in 0 ..< LABEL_CAPACITY {
		fmt.sbprintf(&builder, "label_%d:\n", index)
	}
	strings.write_string(&builder, "ret\n")
	labels_at_bound := strings.to_string(builder)
	expect_code(t, labels_at_bound, {0xC3})
	record := expect_refusal(t, strings.concatenate({labels_at_bound, "one_more: ret"}, context.temp_allocator), .Labels_Full, LABEL_CAPACITY + 2, 1)
	testing.expect_value(t, record.value, u64(LABEL_CAPACITY))

	// 2048 references, then 2049.
	references_at_bound := strings.concatenate({"x: jmp x\n", strings.repeat("jmp x\n", REFERENCE_CAPACITY - 1, context.temp_allocator)}, context.temp_allocator)
	workspace := new(Workspace)
	defer free(workspace)
	_, refusal := assemble(references_at_bound, workspace)
	testing.expect_value(t, refusal.refusal, Refusal.None)
	expect_refusal(t, strings.concatenate({references_at_bound, "jmp x"}, context.temp_allocator), .References_Full, REFERENCE_CAPACITY + 1, 5)

	// 32 exports, then 33.
	exports := strings.builder_make(context.temp_allocator)
	for index in 0 ..< EXPORT_CAPACITY {
		fmt.sbprintf(&exports, "export f%d()\nf%d: ret\n", index, index)
	}
	exports_at_bound := strings.to_string(exports)
	_, refusal = assemble(exports_at_bound, workspace)
	testing.expect_value(t, refusal.refusal, Refusal.None)
	expect_refusal(t, strings.concatenate({exports_at_bound, "export g()"}, context.temp_allocator), .Exports_Full, 2 * EXPORT_CAPACITY + 1, 8)
}

@(test)
each_refusal_has_a_sentence :: proc(t: ^testing.T) {
	for member in Refusal {
		testing.expectf(t, refusal_sentence(member) != "an unknown refusal", "%v has no sentence", member)
	}
}

// The whole program: an addition, a loop, a call with the stack, and a
// read of the data. The last case of the package: it runs after each
// refusal above.
@(private = "file")
PROGRAM :: `# A program of each instruction of the subset.
export add(a: Integer, b: Integer) -> Integer
export sum_to(n: Integer) -> Integer
export twice_sum(n: Integer) -> Integer
export message_difference()  -> Integer
add:
	mov %rdi, %rax
	add %rsi, %rax
	ret
sum_to:                     # 1 + 2 + ... + n
	mov $0, %rax
	mov $1, %rcx
loop:
	cmp %rdi, %rcx
	jg done
	add %rcx, %rax
	add $1, %rcx
	jmp loop
done:
	ret
twice_sum:
	push %rbx
	call sum_to
	mov %rax, %rbx
	add %rbx, %rax
	pop %rbx
	ret
message_difference:
	lea message(%rip), %rcx
	mov $0, %rax
	sub $8, %rsp
	mov (%rcx), %rdx
	mov %rdx, (%rsp)
	add $8, %rsp
	movl $0, %eax
	mov %rdx, %rax
	sub $0x6968, %rax
	ret
section data
message: byte 0x68, 0x69
`

@(test)
a_whole_program_is_a_valid_module_that_runs :: proc(t: ^testing.T) {
	workspace := new(Workspace)
	defer free(workspace)
	parts, refusal := assemble(PROGRAM, workspace)
	if !testing.expectf(t, refusal.refusal == .None, "refused with %v at line %d, column %d", refusal.refusal, refusal.place.line, refusal.place.column) {
		return
	}
	size, needed := writer.file_size_needed(parts)
	testing.expect_value(t, needed.refusal, writer.Refusal.None)
	file := make([]u8, int(size))
	defer delete(file)
	written, written_refusal := writer.write(parts, file)
	testing.expect_value(t, written_refusal.refusal, writer.Refusal.None)
	testing.expect_value(t, written, size)
	testing.expect_value(t, module.validate(file), module.Error.None)

	// Each export, with its description.
	head, _ := module.header(file)
	testing.expect_value(t, head.entry_export, u32(0))
	testing.expect_value(t, module.count(file, .Exports), u32(5))
	add, ok := module.function(file, 1)
	testing.expect(t, ok)
	testing.expect_value(t, module.string_at(file, add.name_offset, add.name_count), "add")
	testing.expect_value(t, add.parameter_count, u8(2))
	testing.expect_value(t, add.parameters[0], u8(module.Type.Integer))
	testing.expect_value(t, add.parameters[1], u8(module.Type.Integer))
	testing.expect_value(t, add.result, u8(module.Type.Integer))
	testing.expect_value(t, module.string_at(file, add.parameter_names[1], u32(add.parameter_name_counts[1])), "b")
	message_difference, _ := module.function(file, 4)
	testing.expect_value(t, module.string_at(file, message_difference.name_offset, message_difference.name_count), "message_difference")
	testing.expect_value(t, message_difference.parameter_count, u8(0))

	// The code runs on the processor of the host: the segments at their
	// offsets, the code with Read and Execute.
	when ODIN_ARCH == .amd64 {
		memory_size := parts.segments[1].memory_offset + parts.segments[1].memory_size
		memory, error := virtual.reserve_and_commit(uint(memory_size))
		if !testing.expect(t, error == .None, "the host gave no memory for the code") {
			return
		}
		defer virtual.release(raw_data(memory), uint(memory_size))
		for segment in parts.segments {
			copy(memory[segment.memory_offset:], segment.data)
		}
		testing.expect(t, virtual.protect(raw_data(memory), uint(parts.segments[0].memory_size), {.Read, .Execute}))
		Two_Arguments :: proc "c" (a: i64, b: i64) -> i64
		One_Argument :: proc "c" (n: i64) -> i64
		No_Argument :: proc "c" () -> i64
		export_at :: proc(memory: []u8, workspace: ^Workspace, index: int) -> rawptr {
			return &memory[workspace.export_parts[index].code_offset]
		}
		add_export := cast(Two_Arguments)export_at(memory, workspace, 0)
		sum_to_export := cast(One_Argument)export_at(memory, workspace, 1)
		twice_sum_export := cast(One_Argument)export_at(memory, workspace, 2)
		message_difference_export := cast(No_Argument)export_at(memory, workspace, 3)
		testing.expect_value(t, add_export(2, 3), i64(5))
		testing.expect_value(t, add_export(-7, 3), i64(-4))
		testing.expect_value(t, sum_to_export(0), i64(0))
		testing.expect_value(t, sum_to_export(1), i64(1))
		testing.expect_value(t, sum_to_export(100), i64(5050))
		testing.expect_value(t, twice_sum_export(100), i64(10100))
		// The 8 bytes at the label: "hi" and six zero bytes of the page,
		// less "hi" as a number.
		testing.expect_value(t, message_difference_export(), i64(0))
	}
}
