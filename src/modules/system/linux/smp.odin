// Live multi-vCPU Linux SMP runtime and store-backed guest image descriptor
// wiring over modus:contract/guest_os (src/md/features/foreign_systems.md;
// src/md/features/linux_shell.md).
//
// Builds the deterministic ACPI MADT ("APIC") table capped by the process's
// thread budget, verifies the kernel and initial archive store object names
// and BLAKE3 hashes via Guest_Store_Image_Spec, and schedules active vCPUs
// across Guest_Run without heap allocation.
package linux_shell

import "modus:contract/blake3"
import "modus:contract/guest_os"
import op "modus:contract/operation"

// Format property: reserved 4 KiB guest physical page between the initial
// page tables (0x9000..0xFFFF) and the command line (0x2_0000) holding the
// generated ACPI MADT ("APIC") table.
LINUX_MADT_GUEST_ADDRESS :: u64(0x1_0000)
LINUX_MADT_GUEST_BYTES :: u64(4096)

// Closed set of lifecycle states for one guest virtual processor.
Vcpu_Run_State :: enum u8 {
	Off     = 0, // Application processor waiting for startup.
	Ready   = 1, // Runnable on the next Guest_Run turn.
	Running = 2, // Currently executing inside Guest_Run.
	Waiting = 3, // Halted with interrupts enabled, waiting for input or timer.
	Halted  = 4, // Halted with interrupts disabled (poweroff/halt).
	Failed  = 5, // Stopped on an unhandled guest exit or machine failure.
}

// Per-vCPU execution context kept in fixed BSS storage.
Guest_Vcpu :: struct {
	apic_id:   u8,
	state:     Vcpu_Run_State,
	registers: op.Guest_Registers,
	exits:     u64,
	runs:      u64,
}

// Live SMP topology, validated store-image descriptor, and vCPU table for
// one Linux guest instance.
Guest_Smp_Runtime :: struct {
	initialized:  bool,
	vcpu_count:   u8,
	active_vcpu:  u8,
	madt_bytes:   u32,
	madt_address: u64,
	image_spec:   guest_os.Guest_Store_Image_Spec,
	vcpus:        [guest_os.GUEST_MAX_VCPUS]Guest_Vcpu,
}

// guest_vcpu_count_of derives the live guest vCPU count from the process
// thread budget, capped at guest_os.GUEST_MAX_VCPUS. Returns 0 for budget 0.
guest_vcpu_count_of :: proc "contextless" (thread_budget: u64) -> u8 {
	if thread_budget == 0 {
		return 0
	}
	return u8(min(thread_budget, u64(guest_os.GUEST_MAX_VCPUS)))
}

// guest_smp_prepare validates the store-backed guest image descriptor (kernel
// and optional initrd object names plus BLAKE3 hashes), generates the ACPI
// MADT table for up to thread_budget vCPUs into guest_memory at
// LINUX_MADT_GUEST_ADDRESS, and initializes BSP (vCPU 0) and AP slots.
guest_smp_prepare :: proc "contextless" (
	rt: ^Guest_Smp_Runtime,
	guest_memory: guest_os.Guest_Memory,
	kernel_name: string,
	kernel_bytes: []u8,
	archive_name: string,
	archive_bytes: []u8,
	flags: guest_os.Guest_Grant_Flags,
	thread_budget: u64,
	bsp_registers: op.Guest_Registers,
) -> guest_os.Guest_Smp_Image_Refusal {
	if rt == nil {
		return .Bad_Object_Name
	}
	rt^ = {}

	if len(kernel_bytes) == 0 {
		return .Zero_Kernel_Hash
	}
	kernel_hash := blake3.hash(kernel_bytes)
	archive_hash: blake3.Hash
	if len(archive_bytes) > 0 {
		archive_hash = blake3.hash(archive_bytes)
	}

	spec, spec_ref := guest_os.guest_store_image_make(kernel_hash, kernel_name, archive_hash, archive_name, flags)
	if spec_ref != .None {
		return spec_ref
	}
	if val_ref := guest_os.guest_store_image_validate(&spec); val_ref != .None {
		return val_ref
	}

	vcpu_count := guest_vcpu_count_of(thread_budget)
	if vcpu_count == 0 {
		return .Zero_Vcpus
	}

	madt_window, madt_ok := guest_os.guest_memory_range(guest_memory, LINUX_MADT_GUEST_ADDRESS, LINUX_MADT_GUEST_BYTES)
	if !madt_ok {
		return .Buffer_Too_Small
	}
	madt_written, madt_ref := guest_os.guest_madt_build(
		vcpu_count,
		thread_budget,
		guest_os.GUEST_LOCAL_APIC_DEFAULT_BASE,
		madt_window,
	)
	if madt_ref != .None {
		return madt_ref
	}
	if guest_os.guest_madt_checksum(madt_window[:madt_written]) != 0 {
		return .Buffer_Too_Small
	}

	rt.initialized = true
	rt.vcpu_count = vcpu_count
	rt.active_vcpu = 0
	rt.madt_bytes = u32(madt_written)
	rt.madt_address = LINUX_MADT_GUEST_ADDRESS
	rt.image_spec = spec

	for cpu in u8(0) ..< vcpu_count {
		rt.vcpus[cpu] = {
			apic_id = cpu,
			state   = cpu == 0 ? .Ready : .Off,
		}
	}
	rt.vcpus[0].registers = bsp_registers
	return .None
}

// guest_smp_start_ap brings an application processor (apic_id 1 ..< vcpu_count)
// online from .Off into .Ready with validated long-mode entry address,
// page-aligned page table root, and dedicated 16-byte-aligned stack pointer.
guest_smp_start_ap :: proc "contextless" (rt: ^Guest_Smp_Runtime, apic_id: u8, entry_rip: u64, cr3: u64, stack_rsp: u64) -> bool {
	if rt == nil || !rt.initialized || apic_id == 0 || apic_id >= rt.vcpu_count {
		return false
	}
	if entry_rip == 0 || cr3 == 0 || (cr3 & 0xFFF) != 0 || stack_rsp == 0 || (stack_rsp & 0xF) != 0 {
		return false
	}
	vcpu := &rt.vcpus[apic_id]
	if vcpu.state != .Off {
		return false
	}
	regs := rt.vcpus[0].registers
	regs.rip = entry_rip
	regs.cr3 = cr3
	regs.rsp = stack_rsp
	vcpu.registers = regs
	vcpu.state = .Ready
	return true
}

// guest_smp_has_other_runnable reports without mutating active_vcpu whether
// another vCPU besides exclude_vcpu is currently .Ready to run.
guest_smp_has_other_runnable :: proc "contextless" (rt: ^Guest_Smp_Runtime, exclude_vcpu: u8) -> bool {
	if rt == nil || !rt.initialized {
		return false
	}
	for cpu in u8(0) ..< rt.vcpu_count {
		if cpu != exclude_vcpu && rt.vcpus[cpu].state == .Ready {
			return true
		}
	}
	return false
}

// guest_smp_first_waiting returns the first vCPU currently in .Waiting so the
// wait loop arms the timer and wakes the actual waiting vCPU.
guest_smp_first_waiting :: proc "contextless" (rt: ^Guest_Smp_Runtime) -> (index: u8, found: bool) {
	if rt == nil || !rt.initialized {
		return 0, false
	}
	for cpu in u8(0) ..< rt.vcpu_count {
		if rt.vcpus[cpu].state == .Waiting {
			return cpu, true
		}
	}
	return 0, false
}

// guest_smp_select_next chooses the next runnable (.Ready) vCPU in round-robin
// order after active_vcpu so no online vCPU starves.
guest_smp_select_next :: proc "contextless" (rt: ^Guest_Smp_Runtime) -> (index: u8, found: bool) {
	if rt == nil || !rt.initialized || rt.vcpu_count == 0 {
		return 0, false
	}
	count := int(rt.vcpu_count)
	start := (int(rt.active_vcpu) + 1) % count
	for offset in 0 ..< count {
		candidate := (start + offset) % count
		if rt.vcpus[candidate].state == .Ready {
			rt.active_vcpu = u8(candidate)
			return u8(candidate), true
		}
	}
	return 0, false
}

// guest_smp_wake_waiting transitions any .Waiting vCPUs back to .Ready after
// an input or timer wake.
guest_smp_wake_waiting :: proc "contextless" (rt: ^Guest_Smp_Runtime) -> (woken: u8) {
	if rt == nil || !rt.initialized {
		return 0
	}
	for cpu in u8(0) ..< rt.vcpu_count {
		if rt.vcpus[cpu].state == .Waiting {
			rt.vcpus[cpu].state = .Ready
			woken += 1
		}
	}
	return woken
}

// guest_smp_has_live_vcpu reports whether at least one vCPU is still runnable,
// running, or waiting for input/timer interrupts.
guest_smp_has_live_vcpu :: proc "contextless" (rt: ^Guest_Smp_Runtime) -> bool {
	if rt == nil || !rt.initialized {
		return false
	}
	for cpu in u8(0) ..< rt.vcpu_count {
		switch rt.vcpus[cpu].state {
		case .Ready, .Running, .Waiting:
			return true
		case .Off, .Halted, .Failed:
		}
	}
	return false
}
