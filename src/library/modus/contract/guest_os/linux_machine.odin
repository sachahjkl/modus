package guest_os

import "modus:contract/enum_word"
import op "modus:contract/operation"

// The machine of a Linux guest of 64 bits that a process runs with
// `Guest_Run`: the answer to each exit that the kernel gives back. It holds
// the devices (the serial port, the interrupt controllers, the timer and
// three virtio devices: a console, a read-only disk of inputs and a
// writable disk of outputs), the model-specific registers that the record
// of the guest does not carry, and the virtual clock. It makes no kernel
// operation: the process makes them, so a host test drives the machine
// with exits that it writes itself.

LINUX_VIRTIO_BASE :: u64(0xD000_0000)
LINUX_TICKS_PER_EXIT :: u64(4) // About 3.4 microseconds of the timer for each exit.
// The counts of the time stamp counter for each tick of the timer: a
// counter of about 1.19 GHz, which Linux calibrates against the timer.
LINUX_TIME_STAMP_COUNTS_PER_TICK :: u64(1000)

// The devices of the machine, in the order of their windows.
Linux_Machine_Device :: enum u8 {
	Console     = 0,
	Input_Disk  = 1,
	Output_Disk = 2,
}

LINUX_MACHINE_DEVICE_LINES :: [Linux_Machine_Device]u8 {
	.Console     = 5,
	.Input_Disk  = 10,
	.Output_Disk = 11,
}

// The place of one virtio device: its window and its interrupt line, which
// the command line gives the kernel.
Machine_Device_Place :: struct {
	base:           u64,
	interrupt_line: u8,
}

// One exit as `system.guest_run` gives it.
Machine_Exit :: struct {
	kind:        op.Guest_Exit_Kind,
	a, b, c:     u64,
	next:        u64,
	code:        u64,
	information: u64,
}

// What the process does after the machine answered an exit.
Machine_Step :: enum u8 {
	Continue       = 1, // Run the guest again with the record.
	Not_Handled    = 2, // A port that no device of the machine has: the process answers it.
	Halted         = 5, // The guest waits with no interrupt that can come: it stopped.
	Failed         = 6, // The guest did what the machine does not answer: machine.failure says what.
	// Only with waits_for_input: the guest ran hlt with its interrupts on and no interrupt waits. The process
	// waits for an input, or for the time of linux_machine_wait_ticks, then calls linux_machine_resume.
	Waiting        = 7,
}

Machine_Failure :: enum u8 {
	None                  = 0,
	Shutdown              = 1, // A triple fault: the guest processor stopped.
	Refused_State         = 2,
	Unknown_Exit          = 3,
	Undecoded_Instruction = 4, // An access to a device by an instruction that the decode refuses.
	Access_Mismatch       = 5, // The decoded instruction does not make the access that the exit gave.
	Memory_Refused        = 6, // The kernel refused an access to the memory of the guest: its mapping gives no such access. The kernel switches each page between Write and Execute itself.
	Writes_Own_Page       = 7, // An instruction writes the page that holds it, and the machine cannot do that write for it.
}

// The exit codes of the processor that the machine answers in an exit
// `Other` (the AMD manual, volume 2, appendix C). Each other code stops the
// guest.
Other_Exit_Code :: enum u64 {
	Debug                   = 0x41, // The exception #DB, which the kernel intercepts.
	Alignment_Check         = 0x51, // The exception #AC, which the kernel intercepts.
	Model_Specific_Register = 0x7C, // rdmsr (information 0) or wrmsr (information 1).
	Time_Stamp_Counter      = 0x6E, // rdtsc, which the kernel intercepts.
	Time_Stamp_Counter_And_Processor = 0x87, // rdtscp, which the kernel intercepts.
	Read_Processor_Register = 0x8E, // rdpru, which the kernel intercepts.
	Write_Back_Invalidate   = 0x89, // wbinvd or wbnoinvd, which the kernel intercepts.
}
// The access bits of a nested page fault.
FAULT_ACCESS_WRITE :: u64(1) << 1
FAULT_ACCESS_EXECUTE :: u64(1) << 4

// The model-specific registers that the machine answers.
Model_Specific_Register :: enum u32 {
	Time_Stamp_Counter       = 0x0000_0010,
	Apic_Base                = 0x0000_001B,
	Memory_Type_Range_Capabilities = 0x0000_00FE, // MTRRCAP: no range.
	Miscellaneous_Enable     = 0x0000_01A0,
	Page_Attribute_Table     = 0x0000_0277,
	Memory_Type_Range_Default = 0x0000_02FF, // MTRRdefType: the ranges stay off.
	Sysenter_Code_Selector   = 0x0000_0174,
	Sysenter_Stack           = 0x0000_0175,
	Sysenter_Entry           = 0x0000_0176,
	Extended_Features        = 0xC000_0080, // EFER.
	System_Call_Target       = 0xC000_0081, // STAR.
	Long_System_Call_Target  = 0xC000_0082, // LSTAR.
	Compatibility_System_Call_Target = 0xC000_0083, // CSTAR.
	System_Call_Flags_Mask   = 0xC000_0084, // SFMASK.
	Fs_Base                  = 0xC000_0100,
	Gs_Base                  = 0xC000_0101,
	Kernel_Gs_Base           = 0xC000_0102,
}

FLAGS_INTERRUPT :: u64(1) << 9
VECTOR_GENERAL_PROTECTION :: u8(13)
VECTOR_DEBUG :: u8(1)
VECTOR_ALIGNMENT_CHECK :: u8(17)
// The page attribute table at the reset of a processor: write-back,
// write-through, uncached-minus and uncached, twice.
PAGE_ATTRIBUTE_TABLE_RESET :: u64(0x0007_0406_0007_0406)
// The bits of EFER that the guest writes: SCE, LME and NXE. LMA follows the
// processor; SVME stays the kernel's and the guest never sees it.
GUEST_WRITABLE_EFER :: op.GUEST_EFER_SYSTEM_CALL | op.GUEST_EFER_LONG_MODE_ENABLE | op.GUEST_EFER_NO_EXECUTE

Linux_Machine :: struct {
	memory:                           Guest_Memory,
	serial:                           Serial_Port,
	interrupts:                       Interrupt_Controllers,
	timer:                            Interval_Timer,
	devices:                          [Linux_Machine_Device]Virtio_Device,
	clock:                            u64, // In ticks of the timer.
	compatibility_system_call_target: u64,
	sysenter:                         [3]u64,
	page_attribute_table:             u64, // Kept for the guest: the nested page table, not this value, gives the memory type.
	failure:                          Machine_Failure,
	faults_injected:                  u64, // The general protection faults of refused model-specific registers.
	unclaimed_accesses:               u64, // Accesses to an address or a port where no device answers.
	// The record asks for an external interrupt only to open the interrupt window: no line went into
	// service. The next exit takes the request back, and the machine asks again.
	window_requested:                 bool,
	// The caller waits for the input of a principal: at an idle hlt the machine gives Waiting, and the
	// caller moves the clock with the time of the machine (linux_machine_resume). Else the clock jumps to
	// the next tick at once, as a build needs (src/md/features/linux_shell.md, "The machine").
	waits_for_input:                  bool,
	// The writes that the machine did for an instruction that writes the page that holds it (exit
	// Writes_Own_Page): a measure.
	own_page_writes:                  u64,
	// The debug registers of the guest: each access exits, and the machine keeps the values. No breakpoint
	// of the guest reaches the processor.
	debug_registers:                  [8]u64,
}

// The debug registers at the reset of a processor, and the bits of DR6 and
// DR7 that read 1 whatever the guest writes.
DEBUG_STATUS_FIXED :: u64(0xFFFF_0FF0)
DEBUG_CONTROL_FIXED :: u64(0x400)
// The exit codes of a read of DRn (0x20 + n) and of a write of DRn
// (0x30 + n): the AMD manual, volume 2, appendix C.
EXIT_DEBUG_REGISTER_READ :: u64(0x20)
EXIT_DEBUG_REGISTER_WRITE :: u64(0x30)

// machine_debug_register answers a mov to or from a debug register: the
// instruction 0F 21 (read) or 0F 23 (write) with its ModRM, after an
// optional REX in long mode, whose register agrees with the exit code. The
// value stays in the machine: DR6 and DR7 keep their fixed bits, DR4 and
// DR5 are DR6 and DR7. Each other form stops the guest.
@(private = "file")
machine_debug_register :: proc "contextless" (machine: ^Linux_Machine, registers: ^op.Guest_Registers, code: u64) -> Machine_Step {
	write := code >= EXIT_DEBUG_REGISTER_WRITE
	index := code & 0xF
	bytes: [4]u8
	count := guest_instruction_fetch(machine.memory, registers^, registers.rip, bytes[:])
	at := 0
	rex := u8(0)
	long := registers.efer & op.GUEST_EFER_LONG_MODE_ACTIVE != 0
	if long && count > 0 && bytes[0] & 0xF0 == 0x40 {
		rex = bytes[0]
		at = 1
	}
	if count < at + 3 || bytes[at] != 0x0F || bytes[at + 1] != (write ? 0x23 : 0x21) || bytes[at + 2] >> 6 != 3 {
		machine.failure = .Unknown_Exit
		return .Failed
	}
	modrm := bytes[at + 2]
	named := u64(modrm >> 3 & 7) | u64(rex >> 2 & 1) << 3
	if named != index || index > 7 {
		machine.failure = .Unknown_Exit
		return .Failed
	}
	place := index == 4 || index == 5 ? index + 2 : index
	general, known := enum_word.member_of_word(General_Register, u64(modrm & 7 | (rex & 1) << 3))
	if !known {
		machine.failure = .Unknown_Exit // Four bits name each register: this does not happen.
		return .Failed
	}
	register := general_register_pointer(registers, general)
	if write {
		value := long ? register^ : register^ & 0xFFFF_FFFF
		switch place {
		case 6:
			value = value | DEBUG_STATUS_FIXED
		case 7:
			value = value | DEBUG_CONTROL_FIXED
		}
		machine.debug_registers[place] = value
	} else {
		register^ = long ? machine.debug_registers[place] : machine.debug_registers[place] & 0xFFFF_FFFF
	}
	registers.rip += u64(at + 3)
	return .Continue
}

// machine_own_page_write does the write of an instruction that writes the
// page of a switching mapping that holds it (the exit Writes_Own_Page): the
// page is never writable and executable at once, so the guest cannot do it.
// Linux does it at its start: it patches its text with memcpy, whose own
// page holds sites that it patches. The machine decodes the instruction
// with the decode of a device access (a mov to memory), computes the linear
// address of its operand, translates it through the page table of the
// guest, and does the write only when it is the address of the exit: then
// it writes the bytes through the memory of the process and moves rip past
// the instruction, and the page of the guest stays as the kernel left it.
// It refuses code that is not 64-bit (b of the exit is not 1, where the
// decode would read the bytes of another mode), each other instruction (a
// string store with rep, a lock), an address of 32 bits, an operand that is
// not the address of the exit, and a write that crosses a page.
@(private = "file")
machine_own_page_write :: proc "contextless" (machine: ^Linux_Machine, registers: ^op.Guest_Registers, exit: Machine_Exit) -> Machine_Step {
	PAGE_BYTES :: u64(4096)
	address := exit.a
	refused := exit.b != 1
	bytes: [INSTRUCTION_BYTES_MOST]u8
	count := guest_instruction_fetch(machine.memory, registers^, registers.rip, bytes[:])
	decoded, decode_refusal := device_access_decode(bytes[:count], true)
	refused ||= decode_refusal != .None || decoded.direction != .Write
	linear, computed := memory_operand_linear(registers^, decoded)
	physical, mapped := guest_linear_to_physical(machine.memory, registers^, linear)
	size := u64(decoded.size)
	memory_bytes := u64(len(machine.memory.bytes))
	refused ||= !computed || !mapped || physical != address
	refused ||= address >= memory_bytes || size > memory_bytes - address || address % PAGE_BYTES + size > PAGE_BYTES
	if refused {
		machine.failure = .Writes_Own_Page
		return .Failed
	}
	value := device_access_value(registers^, decoded)
	for index in 0 ..< size {
		machine.memory.bytes[address + index] = u8(value >> (index * 8))
	}
	device_access_complete(registers, decoded, 0)
	machine.own_page_writes += 1
	return .Continue
}

// linux_machine_wait_ticks gives the ticks of the timer from the clock of
// the guest to its next interrupt, after a step Waiting; false when no
// interrupt of the timer can come (the timer is off, or its line masked):
// only an input wakes the guest then.
linux_machine_wait_ticks :: proc "contextless" (machine: ^Linux_Machine) -> (ticks: u64, bounded: bool) {
	deadline, timer_waits := timer_deadline(&machine.timer)
	if !timer_waits || machine.interrupts.primary.mask & (1 << TIMER_INTERRUPT_LINE) != 0 {
		return 0, false
	}
	return deadline > machine.clock ? deadline - machine.clock : 0, true
}

// linux_machine_resume ends a step Waiting: the clock of the guest moves by
// the ticks that passed in the time of the machine, at most to the next
// interrupt of the timer, and the machine asks for the interrupt that waits
// (a tick, a key). A late wake gives the guest one tick, not a burst of
// them.
linux_machine_resume :: proc "contextless" (machine: ^Linux_Machine, registers: ^op.Guest_Registers, passed_ticks: u64) {
	ticks, bounded := linux_machine_wait_ticks(machine)
	step := bounded ? min(passed_ticks, ticks) : passed_ticks
	machine.clock = machine.clock + step >= machine.clock ? machine.clock + step : max(u64)
	machine_interrupts_update(machine, registers)
}

// linux_machine_serial_input gives bytes of a principal to the serial port
// of the guest, and gives how many the port took: its receive queue holds
// SERIAL_RECEIVE_BYTES, and a byte past it is dropped and counted.
linux_machine_serial_input :: proc "contextless" (machine: ^Linux_Machine, bytes: []u8) -> (taken: int) {
	return serial_receive_put(&machine.serial, bytes)
}

// linux_machine_start makes the machine of a build on the memory of the
// guest and its two disks.
linux_machine_start :: proc "contextless" (machine: ^Linux_Machine, memory: Guest_Memory, input_disk: []u8, output_disk: []u8) {
	machine^ = {memory = memory, page_attribute_table = PAGE_ATTRIBUTE_TABLE_RESET}
	machine.debug_registers[6] = DEBUG_STATUS_FIXED
	machine.debug_registers[7] = DEBUG_CONTROL_FIXED
	machine.devices[.Console] = virtio_console_device()
	machine.devices[.Input_Disk] = virtio_block_device(input_disk, true, "modus-inputs")
	machine.devices[.Output_Disk] = virtio_block_device(output_disk, false, "modus-outputs")
	lines := LINUX_MACHINE_DEVICE_LINES
	for line in lines {
		machine_line_level(machine, line)
	}
	machine_line_level(machine, SERIAL_INTERRUPT_LINE)
}

@(private = "file")
machine_line_level :: proc "contextless" (machine: ^Linux_Machine, line: u8) {
	if line < 8 {
		machine.interrupts.primary.level |= 1 << line
	} else {
		machine.interrupts.secondary.level |= 1 << (line - 8)
	}
}

LINUX_MACHINE_DEVICE_COUNT :: len(Linux_Machine_Device)

// linux_machine_places gives the place of each virtio device, in the order
// of Linux_Machine_Device.
linux_machine_places :: proc "contextless" () -> (places: [LINUX_MACHINE_DEVICE_COUNT]Machine_Device_Place) {
	lines := LINUX_MACHINE_DEVICE_LINES
	for device in Linux_Machine_Device {
		places[int(device)] = {base = LINUX_VIRTIO_BASE + u64(device) * VIRTIO_WINDOW_BYTES, interrupt_line = lines[device]}
	}
	return
}

// linux_cpuid gives the answer of the machine to cpuid: the features of a
// processor of 64 bits that Linux needs, with no local APIC (the
// interrupts come through the controllers 8259), no XSAVE (xsetbv exits),
// and no value of the host processor.
linux_cpuid :: proc "contextless" (leaf: u32, subleaf: u32) -> (a, b, c, d: u32) {
	VENDOR_B :: 0x7564_6F4D // "Modu"
	VENDOR_D :: 0x6361_4D73 // "sMac"
	VENDOR_C :: 0x656E_6968 // "hine"
	switch leaf {
	case 0:
		return 7, VENDOR_B, VENDOR_C, VENDOR_D
	case 1:
		// Family 6. ecx: SSE3, CMPXCHG16B, POPCNT, a hypervisor. edx: FPU,
		// PSE, TSC, MSR, PAE, CX8, PGE, CMOV, CLFLUSH, MMX, FXSR, SSE, SSE2.
		return 0x0000_0663, 0x0000_0800, 0x8080_2001, 0x0788_A179
	case 0x8000_0000:
		return 0x8000_0008, VENDOR_B, VENDOR_C, VENDOR_D
	case 0x8000_0001:
		// ecx: LAHF in long mode. edx: SYSCALL, NX, long mode.
		return 0, 0, 0x0000_0001, 0x2010_0800
	case 0x8000_0008:
		return 0x0000_3028, 0, 0, 0 // 40 bits of physical address, 48 of linear address.
	}
	return 0, 0, 0, 0
}

// linux_machine_handle_exit answers one exit: it changes the record, and
// gives what the process does next.
linux_machine_handle_exit :: proc "contextless" (machine: ^Linux_Machine, registers: ^op.Guest_Registers, exit: Machine_Exit) -> Machine_Step {
	// Host-caused interruptions must not advance the guest clock, or the guest
	// can count host interrupts and measure real machine time.
	if exit.kind != .Interrupted {
		machine.clock += LINUX_TICKS_PER_EXIT
	}
	// A request that only opened the window leaves the record: no line is in
	// service for it, and the update below asks again from the state now.
	if machine.window_requested {
		registers.inject_kind = u8(op.Guest_Inject_Kind.None)
		registers.inject_vector = 0
		machine.window_requested = false
	}
	address_of_exit := registers.rip
	step := Machine_Step.Continue
	switch exit.kind {
	case .Interrupted, .Interrupt_Window:
	case .Writes_Own_Page:
		step = machine_own_page_write(machine, registers, exit)
	case .Port_Read, .Port_Write:
		step = machine_port(machine, registers, exit)
	case .Memory:
		step = machine_memory(machine, registers, exit)
	case .Cpuid:
		a, b, c, d := linux_cpuid(u32(registers.rax), u32(registers.rcx))
		registers.rax, registers.rbx, registers.rcx, registers.rdx = u64(a), u64(b), u64(c), u64(d)
		registers.rip = exit.next
	case .Halt:
		registers.rip = exit.next
		step = machine_halt(machine, registers)
	case .Other:
		step = machine_other(machine, registers, exit)
	case .Shutdown:
		machine.failure = .Shutdown
		step = .Failed
	case .Refused_State:
		machine.failure = .Refused_State
		step = .Failed
	case .None:
		machine.failure = .Unknown_Exit
		step = .Failed
	}
	// The instruction of the exit completed: it was the one that the shadow
	// of sti or mov ss protected, so the shadow ends, as on the processor.
	if registers.rip != address_of_exit {
		registers.interrupt_shadow = 0
	}
	if step == .Continue {
		machine_interrupts_update(machine, registers)
	}
	return step
}

// machine_next_instruction gives the address after the instruction of an
// exit: the address that the kernel gave, or the address of the
// instruction plus its length with no prefix.
@(private = "file")
machine_next_instruction :: proc "contextless" (exit: Machine_Exit, address: u64, length: u64) -> u64 {
	return exit.next != 0 ? exit.next : address + length
}

// The legacy devices of the machine, by their ports.
Legacy_Device :: enum u8 {
	Serial               = 1, // 0x3F8 to 0x3FF.
	Primary_Interrupts   = 2, // 0x20 and 0x21.
	Secondary_Interrupts = 3, // 0xA0 and 0xA1.
	Timer                = 4, // 0x40 to 0x43, and the gate at 0x61.
	Quiet                = 5, // The delay port 0x80 and the trigger modes 0x4D0 and 0x4D1: nothing to answer.
}

// legacy_device_of_port gives the device of a port, or false for a port
// where no device of the machine answers.
legacy_device_of_port :: proc "contextless" (port: u16) -> (device: Legacy_Device, ok: bool) {
	if port >= SERIAL_PORT_BASE && port < SERIAL_PORT_BASE + 8 {
		return .Serial, true
	}
	if port & ~u16(1) == INTERRUPT_PRIMARY_PORT {
		return .Primary_Interrupts, true
	}
	if port & ~u16(1) == INTERRUPT_SECONDARY_PORT {
		return .Secondary_Interrupts, true
	}
	if port >= TIMER_PORT_BASE && port <= TIMER_CONTROL_PORT || port == TIMER_GATE_PORT {
		return .Timer, true
	}
	if port == 0x80 || port == 0x4D0 || port == 0x4D1 {
		return .Quiet, true
	}
	return .Quiet, false
}

machine_port_owned :: proc "contextless" (port: u16) -> bool {
	_, owned := legacy_device_of_port(port)
	return owned
}

machine_port_read_byte :: proc "contextless" (machine: ^Linux_Machine, port: u16) -> u8 {
	device, owned := legacy_device_of_port(port)
	if !owned {
		return 0xFF
	}
	switch device {
	case .Serial:
		return serial_read(&machine.serial, port - SERIAL_PORT_BASE)
	case .Primary_Interrupts:
		return interrupt_chip_read(&machine.interrupts.primary, port & 1 != 0)
	case .Secondary_Interrupts:
		return interrupt_chip_read(&machine.interrupts.secondary, port & 1 != 0)
	case .Timer:
		return timer_read(&machine.timer, port, machine.clock)
	case .Quiet:
	}
	return 0
}

machine_port_write_byte :: proc "contextless" (machine: ^Linux_Machine, port: u16, value: u8) {
	device, owned := legacy_device_of_port(port)
	if !owned {
		return
	}
	switch device {
	case .Serial:
		serial_write(&machine.serial, port - SERIAL_PORT_BASE, value)
	case .Primary_Interrupts:
		interrupt_chip_write(&machine.interrupts.primary, port & 1 != 0, value)
	case .Secondary_Interrupts:
		interrupt_chip_write(&machine.interrupts.secondary, port & 1 != 0, value)
	case .Timer:
		timer_write(&machine.timer, port, value, machine.clock)
	case .Quiet:
	}
}

// machine_port answers a port: each byte of a wide access goes to the port
// of its own address, as the bus does. A port of no device of the machine
// goes back to the process.
@(private = "file")
machine_port :: proc "contextless" (machine: ^Linux_Machine, registers: ^op.Guest_Registers, exit: Machine_Exit) -> Machine_Step {
	port := u16(exit.a)
	size := exit.b
	if size != 1 && size != 2 && size != 4 {
		machine.failure = .Unknown_Exit
		return .Failed
	}
	for index in 0 ..< size {
		if !machine_port_owned(port + u16(index)) {
			return .Not_Handled
		}
	}
	if exit.kind == .Port_Read {
		value := u64(0)
		for index in 0 ..< size {
			value |= u64(machine_port_read_byte(machine, port + u16(index))) << (index * 8)
		}
		switch size {
		case 4:
			registers.rax = value
		case:
			mask := size_mask(u8(size))
			registers.rax = registers.rax &~ mask | value
		}
	} else {
		for index in 0 ..< size {
			machine_port_write_byte(machine, port + u16(index), u8(exit.c >> (index * 8)))
		}
	}
	registers.rip = exit.next
	return .Continue
}

// machine_memory answers a nested page fault: in the memory of the guest,
// the kernel refused the access (it switches each page between Write and
// Execute itself, so an exit there is a mapping with no such access), and
// the guest stops; past it, an access to a device, decoded from the
// instruction at rip.
@(private = "file")
machine_memory :: proc "contextless" (machine: ^Linux_Machine, registers: ^op.Guest_Registers, exit: Machine_Exit) -> Machine_Step {
	address := exit.a
	access := exit.b
	if address < u64(len(machine.memory.bytes)) {
		machine.failure = .Memory_Refused
		return .Failed
	}
	bytes: [INSTRUCTION_BYTES_MOST]u8
	count := guest_instruction_fetch(machine.memory, registers^, registers.rip, bytes[:])
	decoded, refusal := device_access_decode(bytes[:count], registers.efer & op.GUEST_EFER_LONG_MODE_ACTIVE != 0)
	if refusal != .None || access & FAULT_ACCESS_EXECUTE != 0 {
		machine.failure = .Undecoded_Instruction
		return .Failed
	}
	if (decoded.direction == .Write) != (access & FAULT_ACCESS_WRITE != 0) {
		machine.failure = .Access_Mismatch
		return .Failed
	}
	device, offset, claimed := machine_device_at(machine, address)
	switch decoded.direction {
	case .Read:
		value := max(u64)
		if claimed && decoded.size <= 4 {
			word, _ := virtio_read(device, offset, decoded.size)
			value = u64(word)
		} else {
			machine.unclaimed_accesses += 1
		}
		device_access_complete(registers, decoded, value)
	case .Write:
		if claimed && decoded.size <= 4 {
			_ = virtio_write(device, machine.memory, offset, decoded.size, u32(device_access_value(registers^, decoded)))
		} else {
			machine.unclaimed_accesses += 1
		}
		device_access_complete(registers, decoded, 0)
	}
	return .Continue
}

@(private = "file")
machine_device_at :: proc "contextless" (machine: ^Linux_Machine, address: u64) -> (device: ^Virtio_Device, offset: u64, ok: bool) {
	if address < LINUX_VIRTIO_BASE {
		return nil, 0, false
	}
	which := enum_word.member_of_word(Linux_Machine_Device, (address - LINUX_VIRTIO_BASE) / VIRTIO_WINDOW_BYTES) or_return
	return &machine.devices[which], (address - LINUX_VIRTIO_BASE) % VIRTIO_WINDOW_BYTES, true
}

// machine_halt answers hlt: with interrupts on, the clock jumps to the next
// interrupt of the timer, which the update after it delivers. With
// interrupts off, or with no interrupt that can come, the guest stopped.
@(private = "file")
machine_halt :: proc "contextless" (machine: ^Linux_Machine, registers: ^op.Guest_Registers) -> Machine_Step {
	if registers.rflags & FLAGS_INTERRUPT == 0 {
		return .Halted
	}
	machine_lines_update(machine)
	if _, waiting := interrupt_acknowledge_peek(&machine.interrupts); waiting {
		return .Continue
	}
	if machine.waits_for_input {
		return .Waiting
	}
	deadline, timer_waits := timer_deadline(&machine.timer)
	if !timer_waits || machine.interrupts.primary.mask & (1 << TIMER_INTERRUPT_LINE) != 0 {
		return .Halted
	}
	machine.clock = max(machine.clock, deadline)
	return .Continue
}

// interrupt_acknowledge_peek says if an interrupt waits, with no change.
interrupt_acknowledge_peek :: proc "contextless" (controllers: ^Interrupt_Controllers) -> (vector: u8, ok: bool) {
	copy_of_controllers := controllers^
	return interrupt_acknowledge(&copy_of_controllers)
}

// machine_other answers an exit Other: a model-specific register, or an
// exception that the kernel intercepts and that goes back to the guest.
@(private = "file")
machine_other :: proc "contextless" (machine: ^Linux_Machine, registers: ^op.Guest_Registers, exit: Machine_Exit) -> Machine_Step {
	if exit.code >= EXIT_DEBUG_REGISTER_READ && exit.code < EXIT_DEBUG_REGISTER_WRITE + 16 {
		return machine_debug_register(machine, registers, exit.code)
	}
	code, known := enum_word.member_of_word(Other_Exit_Code, exit.code)
	if !known || code == .Model_Specific_Register && exit.information > 1 {
		machine.failure = .Unknown_Exit
		return .Failed
	}
	switch code {
	case .Model_Specific_Register:
		machine_model_specific(machine, registers, exit, exit.information == 1)
	case .Time_Stamp_Counter:
		machine_time_stamp_counter(machine, registers, exit, false)
	case .Time_Stamp_Counter_And_Processor:
		machine_time_stamp_counter(machine, registers, exit, true)
	case .Read_Processor_Register:
		machine_exception(registers, 6, false) // #UD: do not advance rip.
	case .Debug:
		machine_exception(registers, VECTOR_DEBUG, false)
	case .Alignment_Check:
		machine_exception(registers, VECTOR_ALIGNMENT_CHECK, true)
	case .Write_Back_Invalidate:
		return machine_cache_write_back(machine, registers, exit)
	}
	return .Continue
}

// machine_cache_write_back answers wbinvd and wbnoinvd: the memory of the
// guest is a memory object of the process, which no cache of the guest
// holds back, so the instruction has nothing to do and completes. The
// exit gives no length, so the machine reads the instruction, and refuses
// each other form (a prefix that it does not know).
@(private = "file")
machine_cache_write_back :: proc "contextless" (machine: ^Linux_Machine, registers: ^op.Guest_Registers, exit: Machine_Exit) -> Machine_Step {
	bytes: [3]u8
	count := guest_instruction_fetch(machine.memory, registers^, registers.rip, bytes[:])
	length := u64(0)
	if count >= 2 && bytes[0] == 0x0F && bytes[1] == 0x09 {
		length = 2 // wbinvd
	} else if count >= 3 && bytes[0] == 0xF3 && bytes[1] == 0x0F && bytes[2] == 0x09 {
		length = 3 // wbnoinvd
	} else {
		machine.failure = .Undecoded_Instruction
		return .Failed
	}
	registers.rip = machine_next_instruction(exit, registers.rip, length)
	return .Continue
}

// page_attribute_table_valid says if each of the eight entries of a page
// attribute table names a memory type: 0, 1, 4, 5, 6 or 7. The types 2 and
// 3 and the bits past 3 of an entry are reserved, and the processor
// refuses them.
page_attribute_table_valid :: proc "contextless" (value: u64) -> bool {
	for entry in 0 ..< u64(8) {
		kind := value >> (entry * 8) & 0xFF
		if kind > 7 || kind == 2 || kind == 3 {
			return false
		}
	}
	return true
}

// machine_time_stamp_counter answers rdtsc and rdtscp from the virtual
// clock: the guest reads no time of the machine, so a build gives the same
// count at the same exit. rdtscp gives the processor 0 in rcx: the machine
// has one guest processor.
@(private = "file")
machine_time_stamp_counter :: proc "contextless" (machine: ^Linux_Machine, registers: ^op.Guest_Registers, exit: Machine_Exit, with_processor: bool) {
	count := machine.clock * LINUX_TIME_STAMP_COUNTS_PER_TICK
	registers.rax = count & 0xFFFF_FFFF
	registers.rdx = count >> 32
	if with_processor {
		registers.rcx = 0
	}
	registers.rip = machine_next_instruction(exit, registers.rip, with_processor ? 3 : 2) // 0F 01 F9, or 0F 31.
}

// machine_exception asks the kernel to deliver an exception at the next
// run, with the error code 0 when the vector has one.
machine_exception :: proc "contextless" (registers: ^op.Guest_Registers, vector: u8, error_code: bool) {
	registers.inject_kind = u8(op.Guest_Inject_Kind.Exception)
	registers.inject_vector = vector
	registers.inject_error_code_valid = error_code ? 1 : 0
	registers.inject_error_code = 0
}

// machine_model_specific answers rdmsr and wrmsr. The registers that the
// record carries go to the record, so that the kernel loads them in the
// guest processor; the others of the list are kept here. Each other
// register, a value that the processor refuses, and the local APIC, which
// cpuid does not offer, give a general protection fault, as a processor
// gives it; the instruction does not complete.
machine_model_specific :: proc "contextless" (machine: ^Linux_Machine, registers: ^op.Guest_Registers, exit: Machine_Exit, write: bool) {
	five_level := registers.cr4 & op.GUEST_CONTROL_4_FIVE_LEVEL_PAGING != 0
	register, known := enum_word.member_of_word(Model_Specific_Register, registers.rcx & 0xFFFF_FFFF)
	value := registers.rdx << 32 | registers.rax & 0xFFFF_FFFF
	result := u64(0)
	refused := !known
	if known {
		switch register {
		case .Apic_Base:
			refused = true
		case .Time_Stamp_Counter:
			// The counter of the virtual clock, as rdtsc gives it. A write
			// would move the clock of the guest backward: refused.
			refused = write
			result = machine.clock * LINUX_TIME_STAMP_COUNTS_PER_TICK
		case .Memory_Type_Range_Capabilities:
			refused = write // A register that the processor only reads.
		case .Miscellaneous_Enable, .Memory_Type_Range_Default:
			// Both read 0: no feature to turn off, and the ranges off. A
			// write that keeps 0 changes nothing; each other write would
			// turn on what the machine does not have.
			refused = write && value != 0
		case .Page_Attribute_Table:
			refused = write && !page_attribute_table_valid(value)
			if write && !refused {
				machine.page_attribute_table = value
			}
			result = machine.page_attribute_table
		case .Extended_Features:
			if write {
				// The processor refuses a change of LME while paging is on.
				long_mode_changes := (value ~ registers.efer) & op.GUEST_EFER_LONG_MODE_ENABLE != 0
				refused = value &~ (GUEST_WRITABLE_EFER | op.GUEST_EFER_LONG_MODE_ACTIVE) != 0 || long_mode_changes && registers.cr0 & op.GUEST_CONTROL_0_PAGING != 0
				if !refused {
					registers.efer = registers.efer &~ GUEST_WRITABLE_EFER | value & GUEST_WRITABLE_EFER
				}
			}
			result = registers.efer &~ op.GUEST_EFER_SECURE_VIRTUAL_MACHINE
		case .System_Call_Target:
			if write {
				registers.star = value
			}
			result = registers.star
		case .Long_System_Call_Target:
			refused = write && !op.guest_address_canonical(value, five_level)
			if write && !refused {
				registers.lstar = value
			}
			result = registers.lstar
		case .Compatibility_System_Call_Target:
			refused = write && !op.guest_address_canonical(value, five_level)
			if write && !refused {
				machine.compatibility_system_call_target = value
			}
			result = machine.compatibility_system_call_target
		case .System_Call_Flags_Mask:
			refused = write && value &~ op.GUEST_SYSTEM_CALL_MASK_DEFINED != 0
			if write && !refused {
				registers.sfmask = value
			}
			result = registers.sfmask
		case .Fs_Base, .Gs_Base, .Kernel_Gs_Base:
			field := register == .Fs_Base ? &registers.fs_base : register == .Gs_Base ? &registers.gs_base : &registers.kernel_gs_base
			refused = write && !op.guest_address_canonical(value, five_level)
			if write && !refused {
				field^ = value
			}
			result = field^
		case .Sysenter_Code_Selector, .Sysenter_Stack, .Sysenter_Entry:
			slot := &machine.sysenter[u32(register) - u32(Model_Specific_Register.Sysenter_Code_Selector)]
			if write {
				slot^ = value
			}
			result = slot^
		}
	}
	if refused {
		machine.faults_injected += 1
		registers.inject_kind = u8(op.Guest_Inject_Kind.Exception)
		registers.inject_vector = VECTOR_GENERAL_PROTECTION
		registers.inject_error_code_valid = 1
		registers.inject_error_code = 0
		return
	}
	if !write {
		registers.rax = result & 0xFFFF_FFFF
		registers.rdx = result >> 32
	}
	registers.rip = machine_next_instruction(exit, registers.rip, 2) // rdmsr and wrmsr: 0F 32 and 0F 30.
}

// machine_lines_update sets the level of each line from its device.
@(private = "file")
machine_lines_update :: proc "contextless" (machine: ^Linux_Machine) {
	if timer_advance(&machine.timer, machine.clock) {
		interrupt_line_set(&machine.interrupts, TIMER_INTERRUPT_LINE, true)
	}
	interrupt_line_set(&machine.interrupts, SERIAL_INTERRUPT_LINE, serial_interrupt(&machine.serial))
	lines := LINUX_MACHINE_DEVICE_LINES
	for device in Linux_Machine_Device {
		interrupt_line_set(&machine.interrupts, lines[device], machine.devices[device].interrupt_status != 0)
	}
}

// machine_interrupts_update sets the lines, then asks for the interrupt
// that waits, when no other event waits in the record. When the guest takes
// interrupts (its interrupt flag set, out of the shadow of sti or mov ss),
// the line goes into service, as at the acknowledge cycle of the processor,
// and the kernel delivers its vector. Else the record asks for the same
// vector with no acknowledge: the kernel opens the interrupt window, and
// the exit Interrupt_Window brings the machine back here, where the line is
// acknowledged then. A vector below 32 is never asked: a controller that
// the guest did not program yet has the base 0, the guest would take the
// interrupt for an exception, and the kernel refuses it.
machine_interrupts_update :: proc "contextless" (machine: ^Linux_Machine, registers: ^op.Guest_Registers) {
	machine_lines_update(machine)
	if registers.inject_kind != u8(op.Guest_Inject_Kind.None) {
		return
	}
	vector, waiting := interrupt_waiting_vector(&machine.interrupts)
	if !waiting || vector < op.GUEST_VECTOR_FIRST_EXTERNAL {
		return
	}
	if !op.guest_external_interrupt_taken(registers^) {
		registers.inject_kind = u8(op.Guest_Inject_Kind.External_Interrupt)
		registers.inject_vector = vector
		machine.window_requested = true
		return
	}
	acknowledged, _ := interrupt_acknowledge(&machine.interrupts)
	registers.inject_kind = u8(op.Guest_Inject_Kind.External_Interrupt)
	registers.inject_vector = acknowledged
}
