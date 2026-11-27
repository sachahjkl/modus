#+build !freestanding
package build

import "core:mem"
import "core:testing"
import "modus:contract/module"
import "modus:contract/software_machine"

// Helper constructing a minimal valid modus module file with one executable
// code segment holding `code`.
@(private = "file")
synthetic_code_module :: proc(code: []u8) -> []u8 {
	dir_size := size_of(module.Header) + module.TABLE_COUNT * size_of(module.Table_Entry)
	segments := [2]module.Segment {
		{},
		{
			file_offset   = module.PAGE_SIZE,
			file_size     = u64(len(code)),
			memory_offset = 0,
			memory_size   = module.PAGE_SIZE,
			flags         = {.Read, .Execute},
		},
	}
	total_size := int(module.PAGE_SIZE) + len(code)
	buf := make([]u8, total_size, context.temp_allocator)
	dir: [module.TABLE_COUNT]module.Table_Entry
	dir[int(module.Table_Kind.Segments)] = {
		offset      = u64(dir_size),
		count       = u32(len(segments)),
		record_size = size_of(module.Segment),
	}
	hdr := module.Header {
		magic       = module.MAGIC,
		version     = module.VERSION,
		header_size = size_of(module.Header),
		machine     = .X86_64,
		table_count = module.TABLE_COUNT,
		memory_size = module.PAGE_SIZE,
	}
	mem.copy(&buf[0], &hdr, size_of(hdr))
	mem.copy(&buf[size_of(module.Header)], &dir[0], size_of(dir))
	mem.copy(&buf[dir_size], &segments[0], size_of(segments))
	copy(buf[module.PAGE_SIZE:], code)
	return buf
}

@(test)
browser_machine_instruction_scan_accepts_valid_and_refuses_unsupported :: proc(t: ^testing.T) {
	// Refusal first: invalid boot image bytes.
	_, bad_problem := browser_machine_image_instructions_scan(nil)
	testing.expect(t, bad_problem != "", "empty image is refused")
	_, bad_problem = browser_machine_image_instructions_scan(transmute([]u8)string("not a boot image"))
	testing.expect(t, bad_problem != "", "non-image bytes are refused")

	// Refusal: module containing unsupported privileged HLT (0xF4).
	bad_code := []u8{0x55, 0x48, 0x89, 0xE5, 0xF4, 0xC3}
	bad_mod := synthetic_code_module(bad_code)
	bad_img := boot_image_encode([]Image_File{{name = "bad_mod", file = bad_mod}}, 1)
	bad_report, problem := browser_machine_image_instructions_scan(bad_img)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, bad_report.modules_checked, 1)
	testing.expect_value(t, len(bad_report.faults), 1)
	if len(bad_report.faults) == 1 {
		testing.expect_value(t, bad_report.faults[0].module_name, "bad_mod")
		testing.expect_value(t, bad_report.faults[0].offset, 4)
		testing.expect_value(t, bad_report.faults[0].status, software_machine.Instruction_Probe_Status.Unsupported_Opcode)
		testing.expect_value(t, bad_report.faults[0].opcode, u8(0xF4))
	}

	// Refusal: truncated instruction at end of segment.
	trunc_code := []u8{0x90, 0x0F}
	trunc_mod := synthetic_code_module(trunc_code)
	trunc_img := boot_image_encode([]Image_File{{name = "trunc_mod", file = trunc_mod}}, 1)
	trunc_report, trunc_problem := browser_machine_image_instructions_scan(trunc_img)
	testing.expect_value(t, trunc_problem, "")
	testing.expect_value(t, len(trunc_report.faults), 1)
	if len(trunc_report.faults) == 1 {
		testing.expect_value(t, trunc_report.faults[0].status, software_machine.Instruction_Probe_Status.Truncated)
		testing.expect_value(t, trunc_report.faults[0].offset, 1)
	}

	// Valid module with ALU, SSE2, CPUID-gated rdrand/rdseed, and SYSCALL passes with exact counts.
	good_code := []u8{
		0x55,                         // push rbp
		0x48, 0x89, 0xE5,             // mov rbp, rsp
		0x66, 0x0F, 0xEF, 0xC0,       // pxor xmm0, xmm0
		0x48, 0x83, 0xC0, 0x01,       // add rax, 1
		0x48, 0x0F, 0xC7, 0xF6,       // rdrand rsi (CPUID-gated)
		0x48, 0x0F, 0xC7, 0xF9,       // rdseed rcx (CPUID-gated)
		0x0F, 0x05,                   // syscall
		0x5D,                         // pop rbp
		0xC3,                         // ret
	}
	good_mod := synthetic_code_module(good_code)
	good_img := boot_image_encode([]Image_File{{name = "good_mod", file = good_mod}}, 1)
	good_report, good_problem := browser_machine_image_instructions_scan(good_img)
	testing.expect_value(t, good_problem, "")
	testing.expect_value(t, good_report.modules_checked, 1)
	testing.expect_value(t, good_report.instructions_checked, 9)
	testing.expect_value(t, good_report.cpuid_gated_checked, 2)
	testing.expect_value(t, len(good_report.faults), 0)
}
