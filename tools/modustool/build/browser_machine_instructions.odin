// Boot-image x86-64 instruction-set verification against software_machine
// (src/md/features/browser_machine.md, "The instruction set, checked").
//
// Walks every executable segment of every module in a browser-machine boot
// image and decodes each instruction with software_machine.instruction_probe.
// Any unsupported opcode, invalid ModRM form, or truncated instruction stops
// the check with the module name, segment offset, and offending bytes.
package build

import "core:fmt"
import "core:os"
import info "modus:contract/boot_info"
import "modus:contract/module"
import "modus:contract/software_machine"
import "modus:contract/system_description"
import "modustool:foundation"

// One unsupported or malformed instruction found in a module code segment.
Browser_Machine_Instruction_Fault :: struct {
	module_name: string,
	offset:      int,
	status:      software_machine.Instruction_Probe_Status,
	opcode:      u8,
	opcode2:     u8,
	two_byte:    bool,
}

// Summary of checking every executable segment of a module or boot image.
Browser_Machine_Instruction_Report :: struct {
	modules_checked:      int,
	instructions_checked: int,
	cpuid_gated_checked:  int,
	faults:               [dynamic]Browser_Machine_Instruction_Fault,
}

// Plan value: cap reported faults per boot image so a corrupt segment does not
// flood diagnostic output while still identifying the earliest failures.
BROWSER_MACHINE_INSTRUCTION_FAULT_LIMIT :: 32

// browser_machine_code_bytes_check probes every instruction in a raw x86-64
// executable segment byte slice. Returns the count of valid instructions
// decoded and appends any unsupported instruction faults up to the cap.
browser_machine_code_bytes_check :: proc(module_name: string, code: []u8, faults: ^[dynamic]Browser_Machine_Instruction_Fault) -> (instructions: int, cpuid_gated: int) {
	offset := 0
	for offset < len(code) {
		probe := software_machine.instruction_probe(code[offset:])
		if (probe.status == .Supported || probe.status == .Cpuid_Gated) && probe.length > 0 {
			instructions += 1
			if probe.status == .Cpuid_Gated {
				cpuid_gated += 1
			}
			offset += probe.length
			continue
		}
		if len(faults) < BROWSER_MACHINE_INSTRUCTION_FAULT_LIMIT {
			append(faults, Browser_Machine_Instruction_Fault {
				module_name = module_name,
				offset      = offset,
				status      = probe.status,
				opcode      = probe.opcode,
				opcode2     = probe.opcode2,
				two_byte    = probe.two_byte,
			})
		}
		// Stop scanning this segment once decoding loses synchronization so we
		// do not report cascading garbage offsets.
		break
	}
	return instructions, cpuid_gated
}

// browser_machine_module_instructions_check validates every executable segment
// of one compiled modus module file against software_machine.instruction_probe.
browser_machine_module_instructions_check :: proc(module_name: string, module_bytes: []u8, faults: ^[dynamic]Browser_Machine_Instruction_Fault) -> (instructions: int, cpuid_gated: int, ok: bool) {
	if _, header_err := module.header(module_bytes); header_err != .None {
		return 0, 0, false
	}
	segment_count := module.count(module_bytes, .Segments)
	for seg_idx in u32(1) ..< segment_count {
		seg, seg_ok := module.record(module_bytes, .Segments, seg_idx, module.Segment)
		if !seg_ok {
			return instructions, cpuid_gated, false
		}
		if .Execute not_in seg.flags {
			continue
		}
		if seg.file_offset > u64(len(module_bytes)) || seg.file_size > u64(len(module_bytes)) - seg.file_offset {
			return instructions, cpuid_gated, false
		}
		code := module_bytes[seg.file_offset:seg.file_offset + seg.file_size]
		seg_ins, seg_gated := browser_machine_code_bytes_check(module_name, code, faults)
		instructions += seg_ins
		cpuid_gated += seg_gated
	}
	return instructions, cpuid_gated, true
}

// browser_machine_image_instructions_scan scans every module inside a boot
// image byte slice and reports instruction coverage against software_machine.
browser_machine_image_instructions_scan :: proc(image_bytes: []u8, allocator := context.temp_allocator) -> (report: Browser_Machine_Instruction_Report, problem: string) {
	report.faults = make([dynamic]Browser_Machine_Instruction_Fault, allocator)
	modules, _, valid := info.image_tables(image_bytes)
	if !valid {
		return report, "not a valid boot image"
	}
	for &entry in modules {
		name := system_description.name_of(&entry.name)
		bytes, inside := info.image_entry_bytes(image_bytes, &entry)
		if !inside {
			return report, fmt.tprintf("module %s points outside boot image", name)
		}
		count, gated, mod_ok := browser_machine_module_instructions_check(name, bytes, &report.faults)
		if !mod_ok {
			return report, fmt.tprintf("module %s has a damaged module header or segment table", name)
		}
		report.modules_checked += 1
		report.instructions_checked += count
		report.cpuid_gated_checked += gated
	}
	return report, ""
}

// browser_machine_boot_image_instructions_check reads a boot image from disk
// and verifies that every executable instruction of every module in the image
// is supported by software_machine.
browser_machine_boot_image_instructions_check :: proc(image_path: string) -> bool {
	bytes, read_err := os.read_entire_file(image_path, context.temp_allocator)
	if read_err != nil {
		fmt.eprintfln("modustool: cannot read %s: %v", image_path, read_err)
		return false
	}
	report, problem := browser_machine_image_instructions_scan(bytes, context.temp_allocator)
	if problem != "" {
		fmt.eprintfln("modustool: instruction check of %s failed: %s", image_path, problem)
		return false
	}
	if len(report.faults) > 0 {
		fmt.eprintfln("modustool: %s has %d instruction faults against software_machine:", image_path, len(report.faults))
		for fault in report.faults {
			if fault.two_byte {
				fmt.eprintfln("modustool:   %s +0x%x: %v (0F %02x)", fault.module_name, fault.offset, fault.status, fault.opcode2)
			} else {
				fmt.eprintfln("modustool:   %s +0x%x: %v (%02x)", fault.module_name, fault.offset, fault.status, fault.opcode)
			}
		}
		return false
	}
	foundation.test_passed_print("instruction check of %s: %d instructions (%d cpuid-gated) across %d modules supported by software_machine", image_path, report.instructions_checked, report.cpuid_gated_checked, report.modules_checked)
	return true
}
