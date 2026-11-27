// Live verification of 1 GiB Frames_Now runs, resumable 2 MiB slice zeroing
// across schedule(), 1 GiB PDPT leaf mappings, zero-allocation demotion via
// Process.demotion_tables, and run reclamation on a 4 GiB pdpe1gb machine
// (src/md/features/frames_of_a_process.md).
package pdpe1gb_probe

import "modus:contract/call_outcome"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:system"

// Budget covers one 1 GiB object (262144 pages), its frame list (513 pages),
// page tables for mapping and demotion (514 pages), and working headroom.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 266240}

GIGABYTE_PAGES :: u64(262144)
GIGABYTE_BYTES :: u64(1 << 30)
SLICE_2M_WORDS :: u64((2 << 20) / size_of(u64))

machine: system.Handle
self_index: u64
mappings_report: op.Process_Mapping_Report

@(private = "file")
wrong :: proc "contextless" (what: string, got: u64, expected: u64) -> ! {
	system.log_fact(.Error, Wrong{got = got, expected = expected}, what)
	system.stop(.Failed)
}

@(private = "file")
system_report_read :: proc "contextless" () -> op.System_Report {
	report: op.System_Report
	_, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report))
	if status != .Succeeded {
		wrong("Inspect System failed", u64(status), u64(call_outcome.Call_Outcome.Succeeded))
	}
	return report
}

@(private = "file")
find_self :: proc "contextless" (slots: u64) {
	for index in u64(1) ..< slots {
		report: op.Process_Report
		if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process), index, u64(uintptr(&report)), size_of(report)); status != .Succeeded {
			continue
		}
		if system.name_of(report.name[:]) == "pdpe1gb_probe" && report.state != .Stopped && report.state != .None {
			self_index = index
			return
		}
	}
	wrong("cannot find own process slot in Inspect", 0, 1)
}

@(private = "file")
mapping_at :: proc "contextless" (address: u64) -> ^op.Process_Mapping {
	mappings_report = {}
	_, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process_Mappings), self_index, u64(uintptr(&mappings_report)), size_of(mappings_report))
	if status != .Succeeded {
		wrong("Inspect Process_Mappings failed", u64(status), u64(call_outcome.Call_Outcome.Succeeded))
	}
	for &mapping in mappings_report.mappings[:mappings_report.count] {
		if mapping.address == address {
			return &mapping
		}
	}
	return nil
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	machine = ctx.handles[system.GRANT_MACHINE]
	if machine == 0 {
		wrong("missing machine Inspect handle", 0, 1)
	}
	sys_before := system_report_read()
	find_self(sys_before.process_slots)
	if sys_before.free_runs_1g < 1 {
		wrong("expected at least one free 1 GiB run on a 4 GiB pdpe1gb machine", sys_before.free_runs_1g, 1)
	}

	memory, create_status := system.memory_create(GIGABYTE_PAGES, flags = {.Uncommitted})
	if create_status != .Succeeded {
		wrong("creating uncommitted 1 GiB object failed", u64(create_status), u64(call_outcome.Call_Outcome.Succeeded))
	}

	// Refusal edges come first: invalid flag combinations and oversized ranges
	// that are not a single aligned 1 GiB Frames_Now request must be refused.
	{
		record: errors.Error_Record
		one := [1]op.Page_Range{{first = 0, page_count = 1}}
		_, status := system.memory_commit(memory, one[:], error = &record, flags = {.Decommit, .Frames_Now})
		if status != .Argument_Refused || record.kind != i64(errors.Kind.Bad_Value) {
			wrong("Decommit with Frames_Now must be refused with Bad_Value", u64(status), u64(call_outcome.Call_Outcome.Argument_Refused))
		}

		full := [1]op.Page_Range{{first = 0, page_count = GIGABYTE_PAGES}}
		record = {}
		_, status = system.memory_decommit(memory, full[:], &record)
		if status != .Argument_Refused || record.kind != i64(errors.Kind.Too_Long) {
			wrong("1 GiB decommit must be refused with Too_Long", u64(status), u64(call_outcome.Call_Outcome.Argument_Refused))
		}

		record = {}
		_, status = system.memory_commit(memory, full[:], error = &record)
		if status != .Argument_Refused || record.kind != i64(errors.Kind.Too_Long) {
			wrong("1 GiB commit without Frames_Now must be refused with Too_Long", u64(status), u64(call_outcome.Call_Outcome.Argument_Refused))
		}

		over := [1]op.Page_Range{{first = 0, page_count = op.RANGE_TABLE_PAGE_LIMIT + 1}}
		record = {}
		_, status = system.memory_commit(memory, over[:], error = &record, flags = {.Frames_Now})
		if status != .Argument_Refused || record.kind != i64(errors.Kind.Too_Long) {
			wrong("non-1 GiB Frames_Now past RANGE_TABLE_PAGE_LIMIT must be refused with Too_Long", u64(status), u64(call_outcome.Call_Outcome.Argument_Refused))
		}

		misaligned := [1]op.Page_Range{{first = 1, page_count = GIGABYTE_PAGES - 1}}
		record = {}
		_, status = system.memory_commit(memory, misaligned[:], error = &record, flags = {.Frames_Now})
		if status != .Argument_Refused {
			wrong("misaligned Frames_Now past RANGE_TABLE_PAGE_LIMIT must be refused", u64(status), u64(call_outcome.Call_Outcome.Argument_Refused))
		}
	}
	system.log_fact(.Info, Refusals_Checked{})

	// Commit the whole 1 GiB range with Frames_Now, driving resumable 2 MiB
	// zeroing slices across schedule().
	full_range := [1]op.Page_Range{{first = 0, page_count = GIGABYTE_PAGES}}
	commit_record: errors.Error_Record
	changed, commit_status := system.memory_commit(memory, full_range[:], error = &commit_record, flags = {.Frames_Now})
	if commit_status != .Succeeded || changed != GIGABYTE_PAGES {
		wrong("1 GiB Frames_Now commit failed", changed, GIGABYTE_PAGES)
	}
	sys_after_commit := system_report_read()
	if sys_after_commit.free_runs_1g + 1 != sys_before.free_runs_1g {
		wrong("free_runs_1g did not decrease by 1 after 1 GiB Frames_Now commit", sys_after_commit.free_runs_1g, sys_before.free_runs_1g - 1)
	}
	system.log_fact(.Info, Run_Committed{before = sys_before.free_runs_1g, after = sys_after_commit.free_runs_1g})

	// Map the 1 GiB object and verify 1 GiB alignment and PDPT leaf entry.
	address, map_status := system.memory_map(memory, {.Write})
	if map_status != .Succeeded {
		wrong("mapping 1 GiB object failed", u64(map_status), u64(call_outcome.Call_Outcome.Succeeded))
	}
	base := u64(uintptr(address))
	if base % GIGABYTE_BYTES != 0 {
		wrong("1 GiB mapping is not 1 GiB aligned", base % GIGABYTE_BYTES, 0)
	}
	mapping := mapping_at(base)
	if mapping == nil {
		wrong("1 GiB mapping missing from Process_Mappings", base, 1)
	}
	if mapping.entries_1g != 1 || mapping.entries_2m != 0 || mapping.entries_4k != 0 || mapping.present != GIGABYTE_PAGES {
		wrong("expected 1 GiB entry count 1 with zero 2 MiB and 4 KiB entries", mapping.entries_1g, 1)
	}
	system.log_fact(.Info, Mapped_1G{entries_1g = mapping.entries_1g, entries_2m = mapping.entries_2m, entries_4k = mapping.entries_4k})

	// Check zeroed bytes across multiple 2 MiB slice offsets to verify every
	// continuation slice zeroed its memory.
	words := ([^]u64)(address)
	slice_offsets := [?]u64{0, 1, 2, 63, 128, 255, 256, 384, 510, 511}
	for slice_index in slice_offsets {
		first_word := slice_index * SLICE_2M_WORDS
		last_word := first_word + SLICE_2M_WORDS - 1
		if words[first_word] != 0 {
			wrong("first word of 2 MiB slice is not zero", words[first_word], 0)
		}
		if words[last_word] != 0 {
			wrong("last word of 2 MiB slice is not zero", words[last_word], 0)
		}
	}

	// Write distinct canaries across 4 KiB, 2 MiB, 512 MiB, and tail boundaries.
	CANARY_P0 :: u64(0x1111_2222_3333_4444)
	CANARY_P1 :: u64(0x5555_6666_7777_8888)
	CANARY_P2 :: u64(0x9999_AAAA_BBBB_CCCC)
	CANARY_2M :: u64(0xDEAD_BEEF_CAFE_0001)
	CANARY_512M :: u64(0xDEAD_BEEF_CAFE_0002)
	CANARY_LAST :: u64(0xDEAD_BEEF_CAFE_0003)

	PAGE_WORDS :: u64(system.PAGE_SIZE / size_of(u64))
	words[0] = CANARY_P0
	words[1 * PAGE_WORDS] = CANARY_P1
	words[2 * PAGE_WORDS] = CANARY_P2
	words[512 * PAGE_WORDS] = CANARY_2M
	words[131072 * PAGE_WORDS] = CANARY_512M
	words[(GIGABYTE_PAGES - 1) * PAGE_WORDS] = CANARY_LAST

	// Partial Memory_Protect on page 1 forces 1 GiB -> 2 MiB -> 4 KiB demotion
	// with zero additional budget allocation via Process.demotion_tables.
	budget_before, budget_before_status := system.budget_read()
	if budget_before_status != .Succeeded {
		wrong("budget_read before demotion failed", u64(budget_before_status), u64(call_outcome.Call_Outcome.Succeeded))
	}
	protect_range := [1]op.Address_Range{{address = base + system.PAGE_SIZE, page_count = 1}}
	protected, protect_status := system.memory_protect(protect_range[:], {})
	if protect_status != .Succeeded || protected != 1 {
		wrong("partial Memory_Protect on 1 GiB mapping failed", u64(protect_status), u64(call_outcome.Call_Outcome.Succeeded))
	}
	budget_after, budget_after_status := system.budget_read()
	if budget_after_status != .Succeeded || budget_after.pages != budget_before.pages {
		wrong("1 GiB demotion spent budget pages instead of using demotion_tables", budget_after.pages, budget_before.pages)
	}
	demoted := mapping_at(base)
	if demoted == nil {
		wrong("demoted mapping missing from Process_Mappings", base, 1)
	}
	if demoted.entries_1g != 0 || demoted.entries_2m != 511 || demoted.entries_4k != 512 || demoted.present != GIGABYTE_PAGES {
		wrong("demoted entry counts do not match 0/511/512", demoted.entries_2m, 511)
	}
	system.log_fact(.Info, Demoted_1G{entries_1g = demoted.entries_1g, entries_2m = demoted.entries_2m, entries_4k = demoted.entries_4k})

	// Verify data integrity across every canary after demotion.
	if words[0] != CANARY_P0 || words[1 * PAGE_WORDS] != CANARY_P1 || words[2 * PAGE_WORDS] != CANARY_P2 || words[512 * PAGE_WORDS] != CANARY_2M || words[131072 * PAGE_WORDS] != CANARY_512M || words[(GIGABYTE_PAGES - 1) * PAGE_WORDS] != CANARY_LAST {
		wrong("canary corrupted after 1 GiB demotion", words[1 * PAGE_WORDS], CANARY_P1)
	}
	// Remaining writable pages stay writable.
	words[0] = CANARY_P0 ~ 1
	words[512 * PAGE_WORDS] = CANARY_2M ~ 1
	if words[0] != CANARY_P0 ~ 1 || words[512 * PAGE_WORDS] != CANARY_2M ~ 1 {
		wrong("writable page after demotion did not keep new write", words[0], CANARY_P0 ~ 1)
	}

	// Unmap and close; verify the 1 GiB run returns to free_runs_1g.
	if unmap_status := system.memory_unmap(address); unmap_status != .Succeeded {
		wrong("unmapping 1 GiB object failed", u64(unmap_status), u64(call_outcome.Call_Outcome.Succeeded))
	}
	system.close(memory)
	sys_after_free := system_report_read()
	if sys_after_free.free_runs_1g < sys_before.free_runs_1g {
		wrong("1 GiB run did not return to free_runs_1g after close", sys_after_free.free_runs_1g, sys_before.free_runs_1g)
	}
	system.log_fact(.Info, Probe_Passed{free_runs_1g = sys_after_free.free_runs_1g})
	system.stop(.Done)
}
