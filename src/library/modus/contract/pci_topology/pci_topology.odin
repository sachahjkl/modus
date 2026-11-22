// Pure freestanding PCIe-to-PCI bridge enumeration, multi-root-bus ACPI MCFG
// segment tracking, and AMD-Vi IOMMU Interrupt Remapping & multi-device IVMD
// reserved memory contracts (src/md/features/device_services.md).
package pci_topology

import "modus:contract/enum_word"

MAX_ROOT_BUSES :: 8
MAX_BRIDGES :: 32
MAX_IOMMU_IRTE :: 128
MAX_RESERVED_RANGES :: 16

Iommu_Decision :: enum u8 {
	Allow            = 1,
	Refuse_Forged_Irq = 2,
	Refuse_Bad_Device = 3,
	Refuse_Reserved  = 4,
}

iommu_decision_of_word :: proc "contextless" (word: u64) -> (d: Iommu_Decision, ok: bool) {
	return enum_word.member_of_word(Iommu_Decision, word)
}

Root_Bus_Segment :: struct {
	active:       bool,
	segment:      u16,
	start_bus:    u8,
	end_bus:      u8,
	ecam_base:    u64,
	next_free_bus: u8,
}

Bridge_Entry :: struct {
	active:          bool,
	segment:         u16,
	primary_bus:     u8,
	device:          u8,
	function:        u8,
	secondary_bus:   u8,
	subordinate_bus: u8,
}

Topology_State :: struct {
	roots:        [MAX_ROOT_BUSES]Root_Bus_Segment,
	root_count:   int,
	bridges:      [MAX_BRIDGES]Bridge_Entry,
	bridge_count: int,
}

topology_init :: proc "contextless" (t: ^Topology_State) {
	if t == nil {
		return
	}
	t^ = {}
}

// topology_add_root_bus registers an ACPI MCFG root bus range (including second
// and higher root buses). Refuses overlapping ranges or unaligned ECAM bases.
topology_add_root_bus :: proc "contextless" (t: ^Topology_State, segment: u16, start_bus, end_bus: u8, ecam_base: u64) -> bool {
	if t == nil || t.root_count >= MAX_ROOT_BUSES || start_bus > end_bus || (ecam_base & 0xFFF) != 0 || ecam_base == 0 {
		return false
	}
	for i in 0 ..< t.root_count {
		r := t.roots[i]
		if r.segment == segment && !(end_bus < r.start_bus || start_bus > r.end_bus) {
			return false // Overlapping bus range in same segment.
		}
	}
	t.roots[t.root_count] = {
		active        = true,
		segment       = segment,
		start_bus     = start_bus,
		end_bus       = end_bus,
		ecam_base     = ecam_base,
		next_free_bus = start_bus + 1,
	}
	t.root_count += 1
	return true
}

// topology_number_bridge assigns a fresh secondary bus number to a PCIe-to-PCI
// bridge on an active root bus segment and updates subordinate bounds.
topology_number_bridge :: proc "contextless" (t: ^Topology_State, segment: u16, primary_bus, dev, fn: u8) -> (secondary_bus: u8, ok: bool) {
	if t == nil || t.bridge_count >= MAX_BRIDGES || dev >= 32 || fn >= 8 {
		return 0, false
	}
	for i in 0 ..< t.root_count {
		r := &t.roots[i]
		if r.segment == segment && primary_bus >= r.start_bus && primary_bus <= r.end_bus {
			if r.next_free_bus == 0 || r.next_free_bus > r.end_bus {
				return 0, false // Exhausted bus numbers in root segment.
			}
			sec := r.next_free_bus
			r.next_free_bus += 1
			t.bridges[t.bridge_count] = {
				active          = true,
				segment         = segment,
				primary_bus     = primary_bus,
				device          = dev,
				function        = fn,
				secondary_bus   = sec,
				subordinate_bus = sec,
			}
			t.bridge_count += 1
			// Widen subordinate_bus of any parent bridge hosting primary_bus.
			for b_idx in 0 ..< t.bridge_count - 1 {
				parent := &t.bridges[b_idx]
				if parent.segment == segment && parent.secondary_bus <= primary_bus && primary_bus <= parent.subordinate_bus {
					if sec > parent.subordinate_bus {
						parent.subordinate_bus = sec
					}
				}
			}
			return sec, true
		}
	}
	return 0, false
}

// ============================================================================
// AMD-Vi IOMMU: Interrupt Remapping (forged-IRQ defense) & multi-device IVMD
// ============================================================================

Irte_Slot :: struct {
	active:    bool,
	device_id: u16, // BDF (bus<<8 | dev<<3 | fn)
	vector:    u8,
	dest_apic: u8,
}

Ivmd_Range :: struct {
	active:       bool,
	start_phys:   u64,
	end_phys:     u64,
	device_first: u16, // Inclusive BDF range covered by this shared IVMD
	device_last:  u16,
	exclusion:    bool,
}

Amd_Iommu_Table :: struct {
	irtes:      [MAX_IOMMU_IRTE]Irte_Slot,
	irte_count: int,
	ivmds:      [MAX_RESERVED_RANGES]Ivmd_Range,
	ivmd_count: int,
}

amd_iommu_init :: proc "contextless" (tbl: ^Amd_Iommu_Table) {
	if tbl == nil {
		return
	}
	tbl^ = {}
}

amd_iommu_bind_irq :: proc "contextless" (tbl: ^Amd_Iommu_Table, device_id: u16, vector, dest_apic: u8) -> bool {
	if tbl == nil || tbl.irte_count >= MAX_IOMMU_IRTE || vector < 32 {
		return false
	}
	tbl.irtes[tbl.irte_count] = {active = true, device_id = device_id, vector = vector, dest_apic = dest_apic}
	tbl.irte_count += 1
	return true
}

// amd_iommu_verify_interrupt refuses any MSI/MSI-X message whose source BDF
// does not match an installed IRTE entry (forged interrupt defense on AMD-Vi).
amd_iommu_verify_interrupt :: proc "contextless" (tbl: ^Amd_Iommu_Table, source_bdf: u16, vector: u8) -> Iommu_Decision {
	if tbl == nil {
		return .Refuse_Bad_Device
	}
	for i in 0 ..< tbl.irte_count {
		e := tbl.irtes[i]
		if e.active && e.device_id == source_bdf && e.vector == vector {
			return .Allow
		}
	}
	return .Refuse_Forged_Irq
}

amd_iommu_add_ivmd :: proc "contextless" (tbl: ^Amd_Iommu_Table, start_phys, end_phys: u64, dev_first, dev_last: u16, exclusion: bool) -> bool {
	if tbl == nil || tbl.ivmd_count >= MAX_RESERVED_RANGES || start_phys >= end_phys || dev_first > dev_last {
		return false
	}
	tbl.ivmds[tbl.ivmd_count] = {
		active       = true,
		start_phys   = start_phys,
		end_phys     = end_phys,
		device_first = dev_first,
		device_last  = dev_last,
		exclusion    = exclusion,
	}
	tbl.ivmd_count += 1
	return true
}

// amd_iommu_dma_allowed checks whether device_bdf may map [phys, phys+length)
// without colliding with any shared multi-device IVMD reserved range.
amd_iommu_dma_allowed :: proc "contextless" (tbl: ^Amd_Iommu_Table, device_bdf: u16, phys, length: u64) -> Iommu_Decision {
	if tbl == nil || length == 0 || phys > max(u64) - length {
		return .Refuse_Bad_Device
	}
	end := phys + length
	for i in 0 ..< tbl.ivmd_count {
		r := tbl.ivmds[i]
		if r.active && device_bdf >= r.device_first && device_bdf <= r.device_last {
			if !(end <= r.start_phys || phys >= r.end_phys) {
				return .Refuse_Reserved
			}
		}
	}
	return .Allow
}
