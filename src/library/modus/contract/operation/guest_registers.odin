package operation

import "modus:contract/enum_word"

// The guest processors that one guest process can have: `Guest_Run` names
// one by its index, from 0 to `GUEST_PROCESSOR_CAPACITY - 1`. Each one has
// its own state, paid at its first run, and runs on one thread at a time;
// several threads run several guest processors of one guest at once.
GUEST_PROCESSOR_CAPACITY :: 4

// guest_processor_of_word gives the guest processor that the third argument
// of `Guest_Run` names, or false for an index past the last guest processor.
guest_processor_of_word :: proc "contextless" (word: u64) -> (index: u32, ok: bool) {
	if word >= GUEST_PROCESSOR_CAPACITY {
		return 0, false
	}
	return u32(word), true
}

// The state of a mode that `Guest_Run` loads in the guest processor before
// its entry: the segments, the descriptor tables and the privilege level.
// The guest then changes its own segments, so a load is a request of one
// run: the kernel writes `Keep` in the record after it.
//
// Example: a process that put a system in long mode at 0x20_0000 runs once
// with `mode_load = u8(Guest_Mode_Load.Long_64)`, `rip = 0x20_0000` and the
// control registers of long mode, then answers each exit with the record
// that the kernel gave back.
Guest_Mode_Load :: enum u8 {
	Keep         = 0, // No load: the segments stay as the guest left them. A new guest processor starts in real mode.
	Real_16      = 1, // Real mode: each segment of 64 KiB at the base of its selector times 16.
	Protected_32 = 2, // Protected mode: flat segments of 4 GiB, 32-bit code.
	Long_64      = 3, // Long mode: flat segments, 64-bit code.
}

// An event that `Guest_Run` delivers to the guest at its entry: an
// interrupt of a device that the process models, or an exception of an
// instruction that the process ran in place of the guest. The processor
// delivers it through the interrupt table of the guest, with no check of the
// interrupt flag: the process checks first that the guest accepts it (the
// interrupt flag in `rflags` for an external interrupt). The kernel refuses
// an external interrupt and the non-maskable interrupt while the record
// says that the guest is in its interrupt shadow.
Guest_Inject_Kind :: enum u8 {
	None                   = 0, // Nothing to deliver.
	External_Interrupt     = 1, // An interrupt of a device, at any vector, with no error code.
	Non_Maskable_Interrupt = 2, // The non-maskable interrupt: the vector 2.
	Exception              = 3, // An exception of the vectors 0 to 31, with its error code for the vectors that have one.
	Software_Interrupt     = 4, // `int n`: the guest returns to `rip`, the address after the instruction.
}

// The registers of a guest processor that `Guest_Run` takes and gives: the
// general registers, the instruction address, the flags, the control
// registers, and the 64-bit system state that a system writes through
// model-specific registers (the targets of `syscall`, the bases of `fs` and
// `gs`), and the interrupt shadow. The kernel keeps the rest of the state of the guest processor (its
// segments, its descriptor tables, its extended state) between two runs. See [guest](term:guest) and (docs/ARCHITECTURE.md, "A guest").
//
// A process answers an exit by a change of the record before the next run:
// for `Port_Read`, the value in the low bytes of `rax` and the next
// instruction in `rip`; for `Port_Write` and `Halt`, the next instruction in
// `rip`; for a write of `EFER` (an exit `Other`), the new value in `efer`;
// for a write of `LSTAR`, `SFMASK`, `STAR` or a base of `fs` or `gs`, the
// new value in its field; for `rdtsc` and `rdtscp` (exits `Other`), the
// count in `rdx:rax` and the next instruction in `rip`. A process that
// moves `rip` past the instruction of the exit clears `interrupt_shadow`:
// that instruction ended the shadow.
// The kernel loads the control registers before each entry and writes them
// back after each exit: a process passes back the record that it got.
//
// Two parts are requests of one run, which the kernel clears in the record
// when it serves them: `mode_load`, and the event (`inject_kind` and its
// fields). An event waits while the guest processor still holds an event
// that an exit interrupted: the kernel then leaves the request in the
// record, and the process runs again.
//
// A record of zeros is a guest processor at the address 0 in real mode,
// with no flag set and nothing to deliver. 240 bytes.
//
// Example: a guest at 0x1000 in real mode is `{rip = 0x1000}`; after the exit
// `Port_Write` of `out dx, al` with dx 0x80 and al 42, `rax & 0xFF` is 42.
Guest_Registers :: struct {
	rax, rbx, rcx, rdx: u64,
	rsi, rdi, rbp, rsp: u64,
	r8, r9, r10, r11:   u64,
	r12, r13, r14, r15: u64,
	rip:    u64, // In real mode, the offset in the code segment.
	rflags: u64, // Only the bits of `GUEST_FLAGS_DEFINED`; the kernel sets bit 1, which is always 1.
	cr0:    u64, // Only the low 32 bits; the kernel sets the extension type (bit 4), which is always 1.
	cr3:    u64, // The top table of the guest: the bits from 52 are 0.
	cr4:    u64, // Only the bits of `GUEST_CONTROL_4_DEFINED`.
	efer:   u64, // Only the bits of `GUEST_EFER_DEFINED`; the kernel sets SVME (bit 12), which the processor needs.
	inject_error_code:       u32, // The error code of an `Exception` with `inject_error_code_valid`, else 0.
	inject_vector:           u8, // The vector of the event to deliver.
	inject_kind:             u8, // The word of a `Guest_Inject_Kind`.
	inject_error_code_valid: u8, // 1: the exception pushes `inject_error_code`. 0 or 1.
	mode_load:               u8, // The word of a `Guest_Mode_Load`.
	code_selector:           u16, // The selector of the code segment of a mode load; after the exit, the selector of `cs` of the guest.
	data_selector:           u16, // The selector of the data segments of a mode load; after the exit, the selector of `ds` of the guest.
	interrupt_shadow:        u8, // 1: the guest is just after `sti` or `mov ss`, and takes no interrupt before the next instruction completes. 0 or 1.
	reserved:                [3]u8, // 0.
	star:                    u64, // STAR: bits 32 to 47 the selectors of `syscall`, 48 to 63 those of `sysret`. Any value.
	lstar:                   u64, // LSTAR: the address that `syscall` enters in 64-bit mode. Canonical.
	sfmask:                  u64, // SFMASK: the flags that `syscall` clears. Bits 32 to 63 are 0.
	fs_base:                 u64, // The base of `fs` (FS_BASE). Canonical. A mode load does not change it.
	gs_base:                 u64, // The base of `gs` (GS_BASE). Canonical. A mode load does not change it.
	kernel_gs_base:          u64, // KERNEL_GS_BASE: the base that `swapgs` exchanges with `gs_base`. Canonical.
}
#assert(size_of(Guest_Registers) == 240)
#assert(offset_of(Guest_Registers, interrupt_shadow) == 188)
#assert(offset_of(Guest_Registers, reserved) == 189)
#assert(offset_of(Guest_Registers, star) == 192)
#assert(offset_of(Guest_Registers, kernel_gs_base) == 232)

// The bits of SFMASK that a processor has: the low 32 bits, a mask of the
// flags register. The others are reserved.
GUEST_SYSTEM_CALL_MASK_DEFINED :: u64(0xFFFF_FFFF)

// The bits of the flags register that a processor has: carry, parity,
// adjust, zero, sign, trap, interrupt, direction, overflow, the I/O
// privilege level, nested task, resume, virtual 8086, alignment check, the
// two virtual interrupt flags and identification. The others are reserved:
// bit 1 is always 1, and the processor faults on a reserved bit set.
GUEST_FLAGS_DEFINED :: u64(0x003F_7FD7)

// The bits of the control registers and of `EFER` that the kernel checks
// (the AMD manual, volume 2, "System Resources").
GUEST_CONTROL_0_PROTECTION :: u64(1) << 0 // PE: protected mode.
GUEST_CONTROL_0_EXTENSION_TYPE :: u64(1) << 4 // ET: always 1.
GUEST_CONTROL_0_NOT_WRITE_THROUGH :: u64(1) << 29 // NW: refused without CD.
GUEST_CONTROL_0_CACHE_DISABLE :: u64(1) << 30 // CD.
GUEST_CONTROL_0_PAGING :: u64(1) << 31 // PG: refused without PE.
GUEST_CONTROL_0_DEFINED :: u64(0xFFFF_FFFF)
GUEST_CONTROL_3_DEFINED :: u64(1) << 52 - 1
GUEST_CONTROL_4_PHYSICAL_ADDRESS_EXTENSION :: u64(1) << 5 // PAE.
GUEST_CONTROL_4_FIVE_LEVEL_PAGING :: u64(1) << 12 // LA57: addresses of 57 bits in long mode.
// VME to LA57 (0 to 12), FSGSBASE, PCIDE and OSXSAVE (16 to 18), SMEP,
// SMAP, PKE and CET (20 to 23). The bits of the other vendor (13, 14) and
// the reserved bits are refused.
GUEST_CONTROL_4_DEFINED :: u64(0x00F7_1FFF)
GUEST_EFER_SYSTEM_CALL :: u64(1) << 0 // SCE.
GUEST_EFER_LONG_MODE_ENABLE :: u64(1) << 8 // LME.
GUEST_EFER_LONG_MODE_ACTIVE :: u64(1) << 10 // LMA.
GUEST_EFER_NO_EXECUTE :: u64(1) << 11 // NXE.
GUEST_EFER_SECURE_VIRTUAL_MACHINE :: u64(1) << 12 // SVME: the kernel sets it.
// SCE, LME, LMA, NXE, SVME, LMSLE, FFXSR and TCE.
GUEST_EFER_DEFINED :: u64(0xFD01)

// The exception vectors that `Guest_Inject_Kind.Exception` refuses: the
// non-maskable interrupt (2), which has its own kind; the machine check
// (18), which the kernel takes as a fault of the machine; and the reserved
// vectors (15, 22 to 27, 31).
GUEST_EXCEPTIONS_REFUSED :: u32(1 << 2 | 1 << 15 | 1 << 18 | 0b11_1111 << 22 | 1 << 31)
// The exceptions that push an error code: #DF, #TS, #NP, #SS, #GP, #PF,
// #AC, #CP, #VC and #SX.
GUEST_EXCEPTIONS_WITH_ERROR_CODE :: u32(1 << 8 | 1 << 10 | 1 << 11 | 1 << 12 | 1 << 13 | 1 << 14 | 1 << 17 | 1 << 21 | 1 << 29 | 1 << 30)
GUEST_VECTOR_NON_MASKABLE_INTERRUPT :: 2

// Why `Guest_Run` refuses a registers record, with `Bad_Operation`: the
// first field that the rules refuse, in the order of the checks.
Guest_Registers_Refusal :: enum u8 {
	None                = 0, // The record is accepted.
	Flags               = 1, // `rflags` has a bit outside `GUEST_FLAGS_DEFINED`.
	Control_0           = 2, // `cr0` has a bit past 31, NW without CD, or PG without PE.
	Control_3           = 3, // `cr3` has a bit from 52.
	Control_4           = 4, // `cr4` has a bit outside `GUEST_CONTROL_4_DEFINED`.
	Efer                = 5, // `efer` has a bit outside `GUEST_EFER_DEFINED`.
	Long_Mode           = 6, // LMA without LME, PG and PAE; or LME and PG without LMA.
	Instruction_Address = 7, // In long mode, `rip` is not canonical.
	Mode_Load           = 8, // `mode_load` names no `Guest_Mode_Load`, or the control registers do not fit the mode.
	Inject_Kind         = 9, // `inject_kind` names no `Guest_Inject_Kind`, or `inject_error_code_valid` is not 0 or 1.
	Inject_Vector       = 10, // A vector that the kind does not take.
	Inject_Error_Code   = 11, // An error code for an event that pushes none.
	Reserved            = 12, // A byte of `reserved` is not 0.
	System_Call_Address = 13, // `lstar` is not canonical.
	System_Call_Mask    = 14, // `sfmask` has a bit outside `GUEST_SYSTEM_CALL_MASK_DEFINED`.
	Segment_Base        = 15, // `fs_base`, `gs_base` or `kernel_gs_base` is not canonical.
	Interrupt_Shadow    = 16, // `interrupt_shadow` is not 0 or 1.
	Inject_In_Interrupt_Shadow = 17, // An `External_Interrupt` or a `Non_Maskable_Interrupt` while `interrupt_shadow` is 1: it would come one instruction early.
}

// guest_address_canonical says if an address is canonical: each bit from
// the width of the addresses copies the last bit below it.
guest_address_canonical :: proc "contextless" (address: u64, five_level: bool) -> bool {
	width := u64(five_level ? 57 : 48)
	high := address >> (width - 1)
	return high == 0 || high == (u64(1) << (65 - width)) - 1
}

// guest_address_canonical_of gives the canonical form of an address: the
// last bit below the width copied into each bit above it. The kernel masks
// the bases that it writes back with it, so that a process can always pass
// the record back.
guest_address_canonical_of :: proc "contextless" (address: u64, five_level: bool) -> u64 {
	shift := u64(five_level ? 64 - 57 : 64 - 48)
	return u64(i64(address << shift) >> shift)
}

// The requests of a registers record that the checks accepted, as members:
// the kernel reads the words of the record only through
// guest_registers_check.
Guest_Requests :: struct {
	mode_load:   Guest_Mode_Load,
	inject_kind: Guest_Inject_Kind,
}

// guest_registers_refusal says if `Guest_Run` refuses a registers record
// (guest_registers_check gives why).
guest_registers_refusal :: proc "contextless" (registers: Guest_Registers) -> bool {
	_, refusal := guest_registers_check(registers)
	return refusal != .None
}

// guest_registers_check checks a registers record, and gives its requests
// as members, or why `Guest_Run` refuses it. A word that names no member is
// refused: a later kernel can give it a meaning. The processor checks the
// rest of the state at its entry, and refuses it with the exit
// `Refused_State`.
guest_registers_check :: proc "contextless" (registers: Guest_Registers) -> (requests: Guest_Requests, refusal: Guest_Registers_Refusal) {
	if registers.rflags &~ GUEST_FLAGS_DEFINED != 0 {
		return {}, .Flags
	}
	cr0, cr4, efer := registers.cr0, registers.cr4, registers.efer
	protection := cr0 & GUEST_CONTROL_0_PROTECTION != 0
	paging := cr0 & GUEST_CONTROL_0_PAGING != 0
	if cr0 &~ GUEST_CONTROL_0_DEFINED != 0 || cr0 & GUEST_CONTROL_0_NOT_WRITE_THROUGH != 0 && cr0 & GUEST_CONTROL_0_CACHE_DISABLE == 0 || paging && !protection {
		return {}, .Control_0
	}
	if registers.cr3 &~ GUEST_CONTROL_3_DEFINED != 0 {
		return {}, .Control_3
	}
	if cr4 &~ GUEST_CONTROL_4_DEFINED != 0 {
		return {}, .Control_4
	}
	if efer &~ GUEST_EFER_DEFINED != 0 {
		return {}, .Efer
	}
	long_enabled := efer & GUEST_EFER_LONG_MODE_ENABLE != 0
	long_active := efer & GUEST_EFER_LONG_MODE_ACTIVE != 0
	extension := cr4 & GUEST_CONTROL_4_PHYSICAL_ADDRESS_EXTENSION != 0
	if long_active && !(long_enabled && paging && extension) || long_enabled && paging && !long_active {
		return {}, .Long_Mode
	}
	five_level := cr4 & GUEST_CONTROL_4_FIVE_LEVEL_PAGING != 0
	if long_active && !guest_address_canonical(registers.rip, five_level) {
		return {}, .Instruction_Address
	}
	// The processor refuses each of these values in `wrmsr` in any mode, so
	// the record refuses them in any mode too: `vmload` loads them with no
	// check.
	if !guest_address_canonical(registers.lstar, five_level) {
		return {}, .System_Call_Address
	}
	if registers.sfmask &~ GUEST_SYSTEM_CALL_MASK_DEFINED != 0 {
		return {}, .System_Call_Mask
	}
	if !guest_address_canonical(registers.fs_base, five_level) || !guest_address_canonical(registers.gs_base, five_level) || !guest_address_canonical(registers.kernel_gs_base, five_level) {
		return {}, .Segment_Base
	}
	mode_load, mode_known := enum_word.member_of_word(Guest_Mode_Load, u64(registers.mode_load))
	if !mode_known {
		return {}, .Mode_Load
	}
	switch mode_load {
	case .Keep:
	case .Real_16:
		if protection || long_enabled {
			return {}, .Mode_Load
		}
	case .Protected_32:
		if !protection || long_enabled {
			return {}, .Mode_Load
		}
	case .Long_64:
		// The rules above made LMA mean LME, PG and PAE.
		if !long_active {
			return {}, .Mode_Load
		}
	}
	inject_kind, kind_known := enum_word.member_of_word(Guest_Inject_Kind, u64(registers.inject_kind))
	if !kind_known || registers.inject_error_code_valid > 1 {
		return {}, .Inject_Kind
	}
	if event_refusal := guest_event_refusal(inject_kind, registers.inject_vector, registers.inject_error_code_valid == 1, registers.inject_error_code); event_refusal != .None {
		return {}, event_refusal
	}
	if registers.interrupt_shadow > 1 {
		return {}, .Interrupt_Shadow
	}
	// The processor delivers an injected event with no check of the shadow:
	// an interrupt of a device would come before the instruction that the
	// shadow protects (the second half of `mov ss`; `sti; hlt`).
	if registers.interrupt_shadow == 1 && (inject_kind == .External_Interrupt || inject_kind == .Non_Maskable_Interrupt) {
		return {}, .Inject_In_Interrupt_Shadow
	}
	if registers.reserved != {} {
		return {}, .Reserved
	}
	return {mode_load = mode_load, inject_kind = inject_kind}, .None
}

// guest_event_refusal gives why `Guest_Run` refuses an event, or `None`:
// each field that the kind does not use is 0.
guest_event_refusal :: proc "contextless" (kind: Guest_Inject_Kind, vector: u8, error_code_valid: bool, error_code: u32) -> Guest_Registers_Refusal {
	if !error_code_valid && error_code != 0 {
		return .Inject_Error_Code
	}
	switch kind {
	case .None:
		if vector != 0 {
			return .Inject_Vector
		}
		if error_code_valid {
			return .Inject_Error_Code
		}
	case .External_Interrupt, .Software_Interrupt:
		if error_code_valid {
			return .Inject_Error_Code
		}
	case .Non_Maskable_Interrupt:
		if vector != GUEST_VECTOR_NON_MASKABLE_INTERRUPT {
			return .Inject_Vector
		}
		if error_code_valid {
			return .Inject_Error_Code
		}
	case .Exception:
		if vector >= 32 || GUEST_EXCEPTIONS_REFUSED & (u32(1) << vector) != 0 {
			return .Inject_Vector
		}
		if error_code_valid && GUEST_EXCEPTIONS_WITH_ERROR_CODE & (u32(1) << vector) == 0 {
			return .Inject_Error_Code
		}
	}
	return .None
}
