package modustool

import info "modus:contract/boot_info"
import "core:strings"
import "core:testing"

// The texts of the monitor of QEMU for the x86-64 machine, in its format:
// "CPU#<number>" before each processor, RIP in 64-bit code, EIP and the
// base of CS in the other modes.

// A processor of the kernel at a halt.
@(private = "file")
KERNEL_PROCESSOR :: "\r\nCPU#0\r\n" +
	"RAX=0000000000000000 RBX=ffffffff80123000 RCX=0000000000000000 RDX=0000000000000000\r\n" +
	"RSI=0000000000000000 RDI=0000000000000000 RBP=ffffffff80200ff0 RSP=ffffffff80200fe0\r\n" +
	"R8 =0000000000000000 R9 =0000000000000000 R10=0000000000000000 R11=0000000000000000\r\n" +
	"R12=0000000000000000 R13=0000000000000000 R14=0000000000000000 R15=0000000000000000\r\n" +
	"RIP=ffffffff80012345 RFL=00000246 [---Z-P-] CPL=0 II=0 A20=1 SMM=0 HLT=1\r\n" +
	"ES =0010 0000000000000000 ffffffff 00c09300 DPL=0 DS   [-WA]\r\n" +
	"CS =0008 0000000000000000 ffffffff 00a09b00 DPL=0 CS64 [-RA]\r\n" +
	"FCW=037f FSW=0000 [ST=0] FTW=00 MXCSR=00001f80\r\n"

// A processor that waits for its start, in real mode: CS base ffff0000,
// EIP fff0, the reset vector of the firmware.
@(private = "file")
WAITING_PROCESSOR :: "\r\nCPU#1\r\n" +
	"EAX=00000000 EBX=00000000 ECX=00000000 EDX=00000663\r\n" +
	"ESI=00000000 EDI=00000000 EBP=00000000 ESP=00000000\r\n" +
	"EIP=0000fff0 EFL=00000002 [-------] CPL=0 II=0 A20=1 SMM=0 HLT=1\r\n" +
	"ES =0000 00000000 0000ffff 00009300\r\n" +
	"CS =f000 ffff0000 0000ffff 00009b00\r\n"

// A processor in system management mode, at the largest address.
@(private = "file")
MANAGEMENT_PROCESSOR :: "\r\nCPU#2\r\n" +
	"RIP=ffffffffffffffff RFL=00000002 [-------] CPL=0 II=0 A20=1 SMM=1 HLT=0\r\n" +
	"CS =0038 0000000000000000 ffffffff 00af9b00 DPL=0 CS64 [-RA]\r\n"

// A processor that runs a program.
@(private = "file")
PROGRAM_PROCESSOR :: "\r\nCPU#3\r\n" +
	"RIP=0000000000401000 RFL=00000202 [-------] CPL=3 II=0 A20=1 SMM=0 HLT=0\r\n" +
	"CS =002b 0000000000000000 ffffffff 00a0fb00 DPL=3 CS64 [-RA]\r\n"

@(private = "file")
PROCESSOR_LIST :: "* CPU #0: thread_id=4242\r\n  CPU #1: thread_id=4243\r\n  CPU #2: thread_id=4244\r\n  CPU #3: thread_id=4245\r\n"

// One processor in 64-bit code, with a line of its registers that the
// cases change.
@(private = "file")
registers_of_one_processor :: proc(line: string) -> string {
	return strings.concatenate({"CPU#0\n", line, "\nCS =0008 0000000000000000 ffffffff 00a09b00 DPL=0 CS64 [-RA]\n"}, context.temp_allocator)
}

@(private = "file")
expect_registers_refused :: proc(t: ^testing.T, text: string, expected: Processor_Read_Fault, loc := #caller_location) {
	states, fault, _ := processor_registers_read(text)
	testing.expect_value(t, fault, expected, loc = loc)
	testing.expect_value(t, len(states), 0, loc = loc)
}

// A damaged text of the registers is refused, with the fault that names
// its damage, and gives no processor.
@(test)
damaged_registers_are_refused :: proc(t: ^testing.T) {
	expect_registers_refused(t, "", .No_Processor)
	expect_registers_refused(t, "\r\n\r\n", .No_Processor)
	expect_registers_refused(t, "RIP=0000000000000000 CPL=0 SMM=0 HLT=0\n", .Text_Before_The_First_Processor)
	expect_registers_refused(t, "CPU#\nRIP=0 CPL=0 SMM=0 HLT=0\n", .Damaged_Processor_Header)
	expect_registers_refused(t, "CPU#x\nRIP=0 CPL=0 SMM=0 HLT=0\n", .Damaged_Processor_Header)
	expect_registers_refused(t, "CPU#65537\nRIP=0 CPL=0 SMM=0 HLT=0\n", .Damaged_Processor_Header)
	expect_registers_refused(t, "CPU#-1\nRIP=0 CPL=0 SMM=0 HLT=0\n", .Damaged_Processor_Header)
	expect_registers_refused(t, "CPU#0\nRIP=0 CPL=0 SMM=0 HLT=0\nCPU#0\nRIP=0 CPL=0 SMM=0 HLT=0\n", .Repeated_Processor)
	// The text of a processor cut before its registers.
	expect_registers_refused(t, "CPU#0\nRIP=0 CPL=0 SMM=0 HLT=0\nCPU#1\n", .Missing_Instruction_Address)
}

// A missing RIP, a value with a character that is no digit, a value past
// 64 bits, and each field out of its range or missing, are refused.
@(test)
damaged_fields_are_refused :: proc(t: ^testing.T) {
	expect_registers_refused(t, registers_of_one_processor("RFL=00000246 CPL=0 SMM=0 HLT=1"), .Missing_Instruction_Address)
	expect_registers_refused(t, registers_of_one_processor("RIP= CPL=0 SMM=0 HLT=1"), .Damaged_Value)
	expect_registers_refused(t, registers_of_one_processor("RIP=ffffffff8001234g CPL=0 SMM=0 HLT=1"), .Damaged_Value)
	expect_registers_refused(t, registers_of_one_processor("RIP=-1 CPL=0 SMM=0 HLT=1"), .Damaged_Value)
	// One bit past 64 bits, and the largest value with a digit more.
	expect_registers_refused(t, registers_of_one_processor("RIP=10000000000000000 CPL=0 SMM=0 HLT=1"), .Value_Past_64_Bits)
	expect_registers_refused(t, registers_of_one_processor("RIP=fffffffffffffffff CPL=0 SMM=0 HLT=1"), .Value_Past_64_Bits)
	expect_registers_refused(t, registers_of_one_processor("RIP=0 RIP=0 CPL=0 SMM=0 HLT=1"), .Repeated_Field)
	expect_registers_refused(t, registers_of_one_processor("RIP=0 CPL=4 SMM=0 HLT=1"), .Damaged_Value)
	expect_registers_refused(t, registers_of_one_processor("RIP=0 CPL=0 SMM=2 HLT=1"), .Damaged_Value)
	expect_registers_refused(t, registers_of_one_processor("RIP=0 CPL=0 SMM=0 HLT=2"), .Damaged_Value)
	expect_registers_refused(t, registers_of_one_processor("RIP=0 CPL=0 SMM=0"), .Missing_Field)
	expect_registers_refused(t, registers_of_one_processor("RIP=0 SMM=0 HLT=1"), .Missing_Field)
	expect_registers_refused(t, registers_of_one_processor("RIP=0 CPL=0 HLT=1"), .Missing_Field)
	// EIP is 32 bits, and needs the base of CS.
	expect_registers_refused(t, "CPU#0\nEIP=100000000 CPL=0 SMM=0 HLT=1\nCS =f000 ffff0000 0000ffff 00009b00\n", .Damaged_Value)
	expect_registers_refused(t, "CPU#0\nEIP=0000fff0 CPL=0 SMM=0 HLT=1\n", .Missing_Field)
	expect_registers_refused(t, "CPU#0\nEIP=0000fff0 CPL=0 SMM=0 HLT=1\nCS =f000\n", .Damaged_Value)
	expect_registers_refused(t, "CPU#0\nEIP=0000fff0 CPL=0 SMM=0 HLT=1\nCS =f000 fffx0000 0000ffff 00009b00\n", .Damaged_Value)
	expect_registers_refused(t, "CPU#0\nEIP=0000fff0 CPL=0 SMM=0 HLT=1\nCS =f000 ffff0000 0000ffff 00009b00\nCS =f000 ffff0000 0000ffff 00009b00\n", .Repeated_Field)
}

@(private = "file")
expect_list_refused :: proc(t: ^testing.T, text: string, expected: Processor_Read_Fault, loc := #caller_location) {
	entries, fault, _ := processor_list_read(text)
	testing.expect_value(t, fault, expected, loc = loc)
	testing.expect_value(t, len(entries), 0, loc = loc)
}

// A damaged list of the processors is refused.
@(test)
damaged_processor_lists_are_refused :: proc(t: ^testing.T) {
	expect_list_refused(t, "", .No_Processor)
	expect_list_refused(t, "* CPU 0: thread_id=1\n", .Damaged_Processor_List_Line)
	expect_list_refused(t, "* CPU #0 thread_id=1\n", .Damaged_Processor_List_Line)
	expect_list_refused(t, "* CPU #: thread_id=1\n", .Damaged_Processor_List_Line)
	expect_list_refused(t, "* CPU #0:\n", .Damaged_Processor_List_Line)
	expect_list_refused(t, "* CPU #0: thread_id=\n", .Damaged_Value)
	expect_list_refused(t, "* CPU #0: thread_id=18446744073709551616\n", .Damaged_Value)
	expect_list_refused(t, "* CPU #0: thread_id=1 thread_id=2\n", .Repeated_Field)
	expect_list_refused(t, "* CPU #0: thread_id=1\n  CPU #0: thread_id=2\n", .Repeated_Processor)
	expect_list_refused(t, "* CPU #0: thread_id=1\nthe end\n", .Damaged_Processor_List_Line)
}

// The registers and the list must name the same processors.
@(test)
registers_and_list_of_other_processors_are_refused :: proc(t: ^testing.T) {
	REGISTERS :: KERNEL_PROCESSOR + WAITING_PROCESSOR
	other_number, fault, _ := processors_read(REGISTERS, "* CPU #0: thread_id=1\n  CPU #2: thread_id=2\n")
	testing.expect_value(t, fault, Processor_Read_Fault.Processor_Lists_Differ)
	testing.expect_value(t, len(other_number), 0)
	fewer, fewer_fault, _ := processors_read(REGISTERS, "* CPU #0: thread_id=1\n")
	testing.expect_value(t, fewer_fault, Processor_Read_Fault.Processor_Lists_Differ)
	testing.expect_value(t, len(fewer), 0)
	// A fault of one text names that text.
	_, damaged_fault, where_text := processors_read(REGISTERS, "CPU 0\n")
	testing.expect_value(t, damaged_fault, Processor_Read_Fault.Damaged_Processor_List_Line)
	testing.expect_value(t, where_text, PROCESSOR_LIST_LINE + ", line 1")
}

// The reply of the monitor is a JSON string; another value is refused.
@(test)
monitor_replies_that_are_not_a_text_are_refused :: proc(t: ^testing.T) {
	// A string cut before its closing quote, a closing quote that a
	// backslash escapes, and a lone quote are refused too.
	for value in ([]string{"", "{\"a\": 1}", "12", "\"RIP=0", "\"RIP=0\\\"", "\"", "true"}) {
		_, decoded := monitor_text_decode(value)
		testing.expect(t, !decoded, value)
	}
	text, decoded := monitor_text_decode("\"\\r\\nCPU#0\\r\\nRIP=0\\r\\n\"")
	testing.expect(t, decoded)
	testing.expect_value(t, text, "\r\nCPU#0\r\nRIP=0\r\n")
	// A backslash that a backslash escapes leaves the closing quote whole.
	backslash, backslash_decoded := monitor_text_decode("\"a\\\\\"")
	testing.expect(t, backslash_decoded)
	testing.expect_value(t, backslash, "a\\")
}

// An address names its code by the ranges that the tool knows, at each
// edge of each range.
@(test)
addresses_name_their_code_at_the_edges :: proc(t: ^testing.T) {
	FLASH_START :: FIRMWARE_FLASH_END - 0x40_0000
	known := Known_Code{firmware_flash_start = FLASH_START, kernel_module = "kernel"}
	at :: proc(address: u64) -> Processor_State {
		return {instruction_address = address}
	}
	testing.expect_value(t, code_place_kind(at(0), known), Code_Place_Kind.No_Known_Code)
	testing.expect_value(t, code_place_kind(at(FIRMWARE_LOW_COPY_START - 1), known), Code_Place_Kind.No_Known_Code)
	testing.expect_value(t, code_place_kind(at(FIRMWARE_LOW_COPY_START), known), Code_Place_Kind.Firmware)
	testing.expect_value(t, code_place_kind(at(FIRMWARE_LOW_COPY_END - 1), known), Code_Place_Kind.Firmware)
	testing.expect_value(t, code_place_kind(at(FIRMWARE_LOW_COPY_END), known), Code_Place_Kind.No_Known_Code)
	testing.expect_value(t, code_place_kind(at(FLASH_START - 1), known), Code_Place_Kind.No_Known_Code)
	testing.expect_value(t, code_place_kind(at(FLASH_START), known), Code_Place_Kind.Firmware)
	testing.expect_value(t, code_place_kind(at(FIRMWARE_FLASH_END - 1), known), Code_Place_Kind.Firmware)
	testing.expect_value(t, code_place_kind(at(FIRMWARE_FLASH_END), known), Code_Place_Kind.No_Known_Code)
	testing.expect_value(t, code_place_kind(at(u64(info.KERNEL_BASE) - 1), known), Code_Place_Kind.No_Known_Code)
	testing.expect_value(t, code_place_kind(at(u64(info.KERNEL_BASE)), known), Code_Place_Kind.Kernel)
	testing.expect_value(t, code_place_kind(at(max(u64)), known), Code_Place_Kind.Kernel)
	// With no sizes of the flash files, the flash is not known.
	testing.expect_value(t, code_place_kind(at(FLASH_START), Known_Code{}), Code_Place_Kind.No_Known_Code)
	// The privilege level and system management mode come before the address.
	testing.expect_value(t, code_place_kind({instruction_address = u64(info.KERNEL_BASE), privilege_level = PROGRAM_PRIVILEGE_LEVEL}, known), Code_Place_Kind.Program)
	testing.expect_value(t, code_place_kind({instruction_address = u64(info.KERNEL_BASE), system_management_mode = true}, known), Code_Place_Kind.Firmware_System_Management_Mode)
}

// The four processors of a machine: each one has its number, its thread,
// its address, its halt and its code. This case comes last.
@(test)
the_processors_of_a_machine_are_read_and_named :: proc(t: ^testing.T) {
	states, fault, _ := processors_read(KERNEL_PROCESSOR + WAITING_PROCESSOR + MANAGEMENT_PROCESSOR + PROGRAM_PROCESSOR, PROCESSOR_LIST)
	testing.expect_value(t, fault, Processor_Read_Fault.None)
	if !testing.expect_value(t, len(states), 4) {
		return
	}
	known := Known_Code{firmware_flash_start = FIRMWARE_FLASH_END - 0x40_0000, kernel_module = "kernel"}

	testing.expect_value(t, states[0].number, 0)
	testing.expect_value(t, states[0].host_thread, 4242)
	testing.expect(t, states[0].current)
	testing.expect_value(t, states[0].instruction_address, 0xffffffff80012345)
	testing.expect(t, states[0].halted)
	testing.expect_value(t, processor_line(states[0], known), "processor 0, halted, at 0xffffffff80012345: the kernel: kernel + 0x12345, with no debug object of kernel")

	// The base of CS and EIP: the reset vector, in the flash.
	testing.expect_value(t, states[1].number, 1)
	testing.expect(t, !states[1].current)
	testing.expect_value(t, states[1].instruction_address, 0xfffffff0)
	testing.expect_value(t, processor_line(states[1], known), "processor 1, halted, at 0xfffffff0: the firmware")

	testing.expect_value(t, states[2].instruction_address, max(u64))
	testing.expect(t, states[2].system_management_mode)
	testing.expect(t, !states[2].halted)
	testing.expect_value(t, processor_line(states[2], known), "processor 2, running, at 0xffffffffffffffff: the firmware, in system management mode")

	testing.expect_value(t, states[3].privilege_level, PROGRAM_PRIVILEGE_LEVEL)
	testing.expect_value(t, states[3].host_thread, 4245)
	testing.expect_value(t, processor_line(states[3], known), "processor 3, running, at 0x401000: a program, at privilege level 3")

	// An address that no known range holds.
	testing.expect_value(t, processor_line({number = 1, instruction_address = 0x7e8c2a0}, known), "processor 1, running, at 0x7e8c2a0: no known code")
	// A volume that the table of the volumes does not hold names no kernel
	// module, and the line says so.
	testing.expect_value(t, processor_line(states[0], Known_Code{}), "processor 0, halted, at 0xffffffff80012345: the kernel, at the offset 0x12345: the table of the volumes names no kernel module for this volume")
	// An older QEMU marks a halt in the list.
	halted, halted_fault, _ := processors_read(PROGRAM_PROCESSOR, "  CPU #3: (halted) thread_id=9\n")
	testing.expect_value(t, halted_fault, Processor_Read_Fault.None)
	if testing.expect_value(t, len(halted), 1) {
		testing.expect(t, halted[0].halted)
	}
}

// The text that QEMU 10.2.4 printed for `info registers -a` and `info cpus`
// of a machine with two processors that waits for its start: a real text,
// with the ends of line of the monitor.
QEMU_REAL_REGISTERS ::
	"CPU#0\r\n" +
	"EAX=00000000 EBX=00000000 ECX=00000000 EDX=00060fb1\r\n" +
	"ESI=00000000 EDI=00000000 EBP=00000000 ESP=00000000\r\n" +
	"EIP=0000fff0 EFL=00000002 [-------] CPL=0 II=0 A20=1 SMM=0 HLT=0\r\n" +
	"ES =0000 00000000 0000ffff 00009300\r\n" +
	"CS =f000 ffff0000 0000ffff 00009b00\r\n" +
	"SS =0000 00000000 0000ffff 00009300\r\n" +
	"DS =0000 00000000 0000ffff 00009300\r\n" +
	"FS =0000 00000000 0000ffff 00009300\r\n" +
	"GS =0000 00000000 0000ffff 00009300\r\n" +
	"LDT=0000 00000000 0000ffff 00008200\r\n" +
	"TR =0000 00000000 0000ffff 00008b00\r\n" +
	"GDT=     00000000 0000ffff\r\n" +
	"IDT=     00000000 0000ffff\r\n" +
	"CR0=60000010 CR2=00000000 CR3=00000000 CR4=00000000\r\n" +
	"DR0=0000000000000000 DR1=0000000000000000 DR2=0000000000000000 DR3=0000000000000000 \r\n" +
	"DR6=00000000ffff0ff0 DR7=0000000000000400\r\n" +
	"EFER=0000000000000000\r\n" +
	"FCW=037f FSW=0000 [ST=0] FTW=00 MXCSR=00001f80\r\n" +
	"FPR0=0000000000000000 0000 FPR1=0000000000000000 0000\r\n" +
	"XMM00=0000000000000000 0000000000000000 XMM01=0000000000000000 0000000000000000\r\n" +
	"\r\n" +
	"CPU#1\r\n" +
	"EAX=00000000 EBX=00000000 ECX=00000000 EDX=00060fb1\r\n" +
	"ESI=00000000 EDI=00000000 EBP=00000000 ESP=00000000\r\n" +
	"EIP=0000fff0 EFL=00000002 [-------] CPL=0 II=0 A20=1 SMM=0 HLT=1\r\n" +
	"ES =0000 00000000 0000ffff 00009300\r\n" +
	"CS =f000 ffff0000 0000ffff 00009b00\r\n" +
	"SS =0000 00000000 0000ffff 00009300\r\n" +
	"GDT=     00000000 0000ffff\r\n" +
	"CR0=60000010 CR2=00000000 CR3=00000000 CR4=00000000\r\n" +
	"EFER=0000000000000000\r\n" +
	"XMM00=0000000000000000 0000000000000000 XMM01=0000000000000000 0000000000000000\r\n"
QEMU_REAL_PROCESSORS :: "* CPU #0: thread_id=3430400 model=qemu64\r\n  CPU #1: thread_id=3430401 model=qemu64\r\n"

@(test)
processor_state_of_a_real_text_of_qemu :: proc(t: ^testing.T) {
	states, fault, _ := processor_registers_read(QEMU_REAL_REGISTERS)
	testing.expect_value(t, fault, Processor_Read_Fault.None)
	if testing.expect_value(t, len(states), 2) {
		// The reset vector: the base of CS and EIP.
		testing.expect_value(t, states[0].instruction_address, 0xffff_fff0)
		testing.expect(t, !states[0].halted)
		testing.expect(t, states[1].halted)
		testing.expect_value(t, states[1].privilege_level, 0)
	}
	entries, list_fault, _ := processor_list_read(QEMU_REAL_PROCESSORS)
	testing.expect_value(t, list_fault, Processor_Read_Fault.None)
	if testing.expect_value(t, len(entries), 2) {
		testing.expect(t, entries[0].current)
		testing.expect_value(t, entries[1].host_thread, 3430401)
	}
}
