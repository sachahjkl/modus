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
	Switch_Write   = 3, // The guest writes its memory where it may now execute: the process gives that region Write.
	Switch_Execute = 4, // The guest executes its memory where it may now write: the process gives that region Execute.
	Halted         = 5, // The guest waits with no interrupt that can come: it stopped.
	Failed         = 6, // The guest did what the machine does not answer: machine.failure says what.
}

Machine_Failure :: enum u8 {
	None                  = 0,
	Shutdown              = 1, // A triple fault: the guest processor stopped.
	Refused_State         = 2,
	Unknown_Exit          = 3,
	Undecoded_Instruction = 4, // An access to a device by an instruction that the decode refuses.
	Access_Mismatch       = 5, // The decoded instruction does not make the access that the exit gave.
	Memory_Read_Fault     = 6, // A read of the memory of the guest faulted: the mapping lost its access.
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
}
// The access bits of a nested page fault.
FAULT_ACCESS_WRITE :: u64(1) << 1
FAULT_ACCESS_EXECUTE :: u64(1) << 4

// The model-specific registers that the machine answers.
Model_Specific_Register :: enum u32 {
	Apic_Base                = 0x0000_001B,
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
	switch_address:                   u64, // The guest physical address of the last Switch_Write or Switch_Execute.
	failure:                          Machine_Failure,
	faults_injected:                  u64, // The general protection faults of refused model-specific registers.
	unclaimed_accesses:               u64, // Accesses to an address or a port where no device answers.
}

// linux_machine_start makes the machine of a build on the memory of the
// guest and its two disks.
linux_machine_start :: proc "contextless" (machine: ^Linux_Machine, memory: Guest_Memory, input_disk: []u8, output_disk: []u8) {
	machine^ = {memory = memory}
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
	address_of_exit := registers.rip
	step := Machine_Step.Continue
	switch exit.kind {
	case .Interrupted:
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
// a switch of its region between Write and Execute; past it, an access to a
// device, decoded from the instruction at rip.
@(private = "file")
machine_memory :: proc "contextless" (machine: ^Linux_Machine, registers: ^op.Guest_Registers, exit: Machine_Exit) -> Machine_Step {
	address := exit.a
	access := exit.b
	if address < u64(len(machine.memory.bytes)) {
		machine.switch_address = address
		if access & FAULT_ACCESS_EXECUTE != 0 {
			return .Switch_Execute
		}
		if access & FAULT_ACCESS_WRITE != 0 {
			return .Switch_Write
		}
		machine.failure = .Memory_Read_Fault
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
	}
	return .Continue
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

// machine_interrupts_update sets the lines, then asks the kernel to deliver
// the interrupt that waits, when the guest takes interrupts and no other
// event waits in the record. Inside the interrupt shadow of sti or mov ss,
// the interrupt waits for a later exit: the processor would deliver it one
// instruction early, and the kernel refuses that record.
machine_interrupts_update :: proc "contextless" (machine: ^Linux_Machine, registers: ^op.Guest_Registers) {
	machine_lines_update(machine)
	if registers.inject_kind != u8(op.Guest_Inject_Kind.None) || registers.rflags & FLAGS_INTERRUPT == 0 || registers.interrupt_shadow != 0 {
		return
	}
	vector, waiting := interrupt_acknowledge(&machine.interrupts)
	if !waiting {
		return
	}
	registers.inject_kind = u8(op.Guest_Inject_Kind.External_Interrupt)
	registers.inject_vector = vector
}
