package build

import "modus:contract/errors"
import module "modus:contract/module"
import op "modus:contract/operation"
import "core:fmt"
import "core:strings"
import "core:testing"
import "modustool:foundation"

// The log facts of the demonstrations against the lines that they replaced
// (src/md/features/log_facts.md, "The facts of the demonstrations"): the
// demonstrations from address_space to heron. The fact types come from the
// extraction of the tool on the sources of each module: a host test does
// not depend on a build. Each sentence is compared with the parts of the
// old line written by sentence.format, at the edges of each field.

// The counts of these tests: 0, 1 and the largest u64.
@(private = "file")
DEMONSTRATION_COUNTS := [3]u64{0, 1, max(u64)}
// The two verdicts of a case, as the lines wrote them after ": ".
@(private = "file")
DEMONSTRATION_VERDICTS := [2]string{"as it must", "WRONG"}

// status_text gives the words of a status word in a sentence: the name of
// its member, or its number when it names none.
@(private = "file")
status_text :: proc(word: u64) -> string {
	if name, named := module.contract_enum_member_name(.Status, word); named {
		return name
	}
	return fmt.tprint(word)
}

// kind_text gives the words of the kind of an error record in a sentence:
// the name of its member, or its number when it names none.
@(private = "file")
kind_text :: proc(word: u64) -> string {
	if name, named := module.contract_enum_member_name(.Error_Kind, word); named {
		return name
	}
	return fmt.tprint(word)
}

// unit_text gives the words of the unit of an error record in a sentence.
@(private = "file")
unit_text :: proc(word: u64) -> string {
	if name, named := module.contract_enum_member_name(.Error_Unit, word); named {
		return name
	}
	return fmt.tprint(word)
}

// The records of the tests of an error record as fields: zero, a refusal
// of the kernel, and the largest words, which name no kind and no unit.
@(private = "file")
DEMONSTRATION_RECORDS := [3]errors.Error_Record{{}, {kind = i64(errors.Kind.Out_Of_Range), unit = i64(errors.Unit.Blocks), operation = 3, argument = 1, value = 8193, limit = 8192, found = 0}, {kind = max(i64), unit = max(i64), operation = min(i64), argument = -1, value = max(i64), limit = min(i64), found = -1}}

// record_values gives the fields of an error record for fact_test_render.
@(private = "file")
record_values :: proc(record: errors.Error_Record) -> [7]Fact_Test_Field {
	return {{"kind", u64(record.kind)}, {"unit", u64(record.unit)}, {"operation", u64(record.operation)}, {"argument", u64(record.argument)}, {"value", u64(record.value)}, {"limit", u64(record.limit)}, {"found", u64(record.found)}}
}

// record_words gives the words of an error record in a sentence, as
// errors.ERROR_RECORD_FACT_TEMPLATE_END writes them.
@(private = "file")
record_words :: proc(record: errors.Error_Record) -> string {
	return fmt.tprintf("kind %s, unit %s, operation %d, argument %d, value %d, limit %d, found %d", kind_text(u64(record.kind)), unit_text(u64(record.unit)), record.operation, record.argument, record.value, record.limit, record.found)
}

// with_values gives the fields of a record and more fields in one list.
@(private = "file")
with_values :: proc(record: errors.Error_Record, more: ..Fact_Test_Field) -> []Fact_Test_Field {
	values := make([dynamic]Fact_Test_Field, context.temp_allocator)
	fields := record_values(record)
	for value in fields {
		append(&values, value)
	}
	append(&values, ..more)
	return values[:]
}

@(private = "file")
demonstration_file :: proc(t: ^testing.T, folder: string) -> (file: []u8, ok: bool) {
	return facts_file_of_folder(t, strings.concatenate({foundation.DEMONSTRATION_MODULE_SOURCES, folder}, context.temp_allocator))
}

// The longest text that a writer of each demonstration puts in each Text
// field, which its field holds with a zero byte after it.
@(private = "file")
Demonstration_Texts :: struct {
	folder: string,
	texts:  []Demonstration_Text,
}

@(private = "file")
Demonstration_Text :: struct {
	field:   string,
	longest: string,
}

@(private = "file")
DEMONSTRATION_TEXTS := [?]Demonstration_Texts {
	{"address_space", {{"verdict", "as expected"}, {"refusal_name", "a range outside the object"}, {"case_name", "a holder's stop with an outcome and a stop of itself with no outcome are refused, and nothing stops"}, {"waiter", "did not wake"}, {"stop_verdict", "was not refused with No_Right"}, {"target", "this process"}, {"budget_after_decommit", "not the same"}, {"neighbour_page", "stayed right"}, {"problem", "a decommit of more than the page limit of one call was not refused with its record"}}},
	{"budget", {{"step", "close the new budget, keep the memory"}, {"answer", "0123456789012345678901234567890123456789"}}},
	{"time_page", {{"cause", "a least size is below the least size of a resizable surface"}, {"removal", "does not refuse"}}},
	{"counters", {{"step", "Read_Counters gave Unsupported and Start_Counters"}, {"refused_step", "Start_Counters with a copy of the machine handle with no right"}, {"measure", "the reads in order"}}},
	{"crowd", {{"queue", "queue with a lock"}}},
	{"cryptography_vectors", {{"verdict", "FAILED"}, {"primitive", "Ed25519 verify, 32 bytes"}, {"standard", "RFC 8032 7.1 test 1"}, {"refusal", "; a bad input is refused with no byte given"}}},
	{"debugged", {{"verdict", "as it must"}, {"subject", "the debugger that steps"}, {"role", "a second debugger"}, {"step", "the resume of the first thread of the child"}, {"mode_owner", "debugger"}, {"trap_path", "was held until the kernel entry, and the kernel dropped it"}}},
	{"disk", {{"direction", "write"}, {"block_word", "blocks"}}},
	{"errors", {{"details_case", "a kernel command with two wrong arguments"}, {"queue_filled", "yes"}, {"command_held", "yes"}, {"answers_in_order", "yes"}, {"held_command_ran", "yes"}, {"child_state", "running, its stop cause "}}},
	{"extended_state", {{"components", "x87, SSE, AVX, AVX-512"}, {"xmm_sets", "SSE, SSE2, SSE3, SSSE3, SSE4.1, SSE4.2, AES, PCLMULQDQ"}, {"avx_sets", "AVX, F16C, FMA, AVX2, AVX-512 F, AVX-512 DQ, AVX-512 CD, AVX-512 BW, AVX-512 VL"}, {"general_register_sets", "POPCNT, BMI1, BMI2"}, {"register", "the x87 control word"}, {"moment", "start state, pass"}, {"part_name", "xsaveopt64 + vzeroupper + xrstor64"}, {"kept_registers", "zmm0 to zmm31 and k0 to k7 (64 bits)"}}},
	{"fault_ring", {{"step", "Fault_Handler_Set with the kinds of the entries"}, {"before_answer", "the thread ran or faulted again with no answer: WRONG"}, {"inspect_answer", "an error"}, {"verdict", "as it must"}, {"serial_answer", "refused with Bad_State, then the right answer resumed the thread: as it must"}, {"foreign_answer", "refused with Bad_State"}, {"case_name", "a word wait, a fault, a decommit of the word"}, {"resume_answer", "a word that names no status"}, {"address_place", "the instruction address is NOT inside its loop"}, {"loop_motion", "and the loop did not turn while the thread was stopped"}, {"run_after", "the thread did not run after its Resume"}, {"run_after_resume", "the thread did not run after its Resume"}, {"before_resume", "it did not run before its Resume"}, {"after_resume", "and it did not run after it"}, {"after_one_resume", "still stopped after one Resume"}, {"after_two_resumes", "not running after the second"}, {"failed_call", "memory_create"}, {"parent_thread_running", "kept running"}}},
	{"fetch", {{"remote_address", "255.255.255.255"}, {"hash_check", "NOT the expected one"}, {"hash_answer", "the remote answered another hash"}, {"wrong_mark", " (WRONG)"}, {"body", "hello from the host"}, {"close_end", "and keeps its half open: FIN-WAIT-2"}}},
	{"flow", {{"waiting", "read the counters then wait"}}},
	{"frames", {{"case_text", "4 twins, each with a copy of the module"}, {"answer", "012345678901234567890123456789012345678901234567"}}},
	{"guest_demo", {{"step", "Memory_Map of the code in the guest"}, {"instruction", "int1"}}},
	{"hall_of_fame", {{"chosen_name", "United States Graphics Company"}}},
	{"heron", {{"animation", "scratch"}, {"motion", ", the heron moved and came back to its place"}, {"ways", ", on the grid and free"}, {"way", "on the grid"}, {"cell_lines", "hidden"}, {"held", ", held"}, {"form", "long neck"}, {"side", "right"}}},
}

// Each fact type of these demonstrations with a Text field ends with its
// Text fields, and each Text field holds the longest text of its writer
// and a zero byte. A demonstration with no fact type fails the test: each
// folder named here writes facts.
@(test)
the_texts_of_the_demonstration_facts_come_last_and_whole :: proc(t: ^testing.T) {
	for item in DEMONSTRATION_TEXTS {
		file, ok := demonstration_file(t, item.folder)
		if !ok {
			continue
		}
		most := make(map[string]u32, context.temp_allocator)
		for text in item.texts {
			most[text.field] = u32(len(text.longest))
		}
		facts_expect_text_fields_last(t, file, most)
	}
}

// Each fact type of address_space writes the line of before: each verdict,
// the longest name of an edge case and a short one, the counts 0, 1 and
// max(u64), a time of max(i64), each status from the first member to the
// last, and each stop cause with and without its outcome.
@(test)
the_facts_of_address_space_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := demonstration_file(t, "address_space")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "address_space", type_name, values)
	}
	longest_case :: "a holder's stop with an outcome and a stop of itself with no outcome are refused, and nothing stops"
	for verdict in ([2]string{"right", "WRONG"}) {
		for name in ([2]string{longest_case, "a"}) {
			facts_expect_line(t, render(t, file, "Edge_Case", {{"verdict", verdict}, {"case_name", name}}), line_of_before("address_space: edge case: ", name, ": ", verdict))
		}
	}
	for verdict in DEMONSTRATION_VERDICTS {
		for count in DEMONSTRATION_COUNTS {
			other := max(u64) - count
			facts_expect_line(t, render(t, file, "Page_Tables_Of_Spread_Mappings", {{"mappings", count}, {"least_paid", other}, {"most_paid", count}, {"pages_kept", other}, {"verdict", verdict}}), line_of_before("address_space: page tables: ", count, " mappings of one page, each at its own entry of three levels: ", other, " to ", count, " pages of tables while mapped, ", other, " pages kept after the unmap", ": ", verdict))
			for same in ([2]string{"the same", "not the same"}) {
				facts_expect_line(t, render(t, file, "Page_Tables_Of_Reservation", {{"reservation_pages", count}, {"table_pages", other}, {"pages_kept", count}, {"budget_after_decommit", same}, {"verdict", verdict}}), line_of_before("address_space: page tables: ", "a reservation of ", count, " pages: ", other, " pages of tables, ", same, " after a commit and a decommit of 16 pages, ", count, " pages kept after the unmap", ": ", verdict))
			}
			facts_expect_line(t, render(t, file, "Page_Tables_Of_Large_Page", {{"table_pages", count}, {"pages_kept", other}, {"verdict", verdict}}), line_of_before("address_space: page tables: ", "a large page: ", count, " pages of tables above it while mapped, ", other, " pages kept after the unmap", ": ", verdict))
			for page in ([2]string{"stayed right", "changed"}) {
				facts_expect_line(t, render(t, file, "Page_Tables_Beside_Neighbour", {{"rounds", count}, {"rounds_right", other}, {"pages_kept", count}, {"neighbour_page", page}, {"verdict", verdict}}), line_of_before("address_space: page tables: ", count, " rounds of a map and an unmap beside a page that another thread writes and reads: ", other, " rounds right, the page of the other thread ", page, ", ", count, " pages kept", ": ", verdict))
			}
		}
	}
	times := [2]u64{0, u64(max(i64))}
	for time in times {
		for waiter in ([2]string{"woke", "did not wake"}) {
			facts_expect_line(t, render(t, file, "Revocation_Of_Large_Mapping", {{"revocation", time}, {"waiter", waiter}}), line_of_before("address_space: a revocation of a mapping of 1 GiB with a thread that waits on a word of it: ", time, " us; the waiter ", waiter))
		}
		for count in DEMONSTRATION_COUNTS {
			facts_expect_line(t, render(t, file, "Large_Object_Ended", {{"unmap_and_close", time}, {"pages_kept", count}}), line_of_before("address_space: an Uncommitted object of 1 GiB with 4 frames: unmap and close in ", time, " us; pages kept: ", count))
			facts_expect_line(t, render(t, file, "Sparse_Table_Measured", {{"pages_committed", count}, {"object_pages", u64(262144)}, {"pages_present", max(u64) - count}, {"pages_returned", count}, {"decommit_time", time}, {"committed_again_zero", u64(1)}}), line_of_before("address_space: sparse table: ", count, " pages committed of ", u64(262144), ", ", max(u64) - count, " with a frame; decommit: ", count, " pages back in the budget at once, in ", time, " us; a page committed again is zero: ", u64(1)))
		}
	}
	for count in DEMONSTRATION_COUNTS {
		facts_expect_line(t, render(t, file, "Neighbour_Touches", {{"touches", count}}), line_of_before("address_space: page tables: the other thread wrote and read its page ", count, " times during the rounds"))
		facts_expect_line(t, render(t, file, "Addresses_Reused", {{"pages_after_last", count}, {"pages_after_first", max(u64) - count}}), line_of_before("address_space: addresses: one object mapped and unmapped 100000 times: the budget holds ", count, " pages after, ", max(u64) - count, " after the first time"))
		for target in ([2]string{"this process", "a child"}) {
			facts_expect_line(t, render(t, file, "Stop_Word_Not_Refused", {{"stop_word", count}, {"status_word", max(u64) - count}, {"error_kind", count}, {"argument", u64(2)}, {"limit", signed_bits(-1)}, {"target", target}}), line_of_before("address_space: WRONG: Process_Stop of ", target, " with the word ", count, " gave the status word ", status_text(max(u64) - count), ", the error kind ", kind_text(count), ", the argument ", i64(2), " and the limit ", i64(-1)))
		}
	}
	statuses := [2]op.Status{min(op.Status), max(op.Status)}
	for status in statuses {
		facts_expect_line(t, render(t, file, "Own_Handle_Child_Board_Not_Mapped", {{"map_status", u64(status)}}), line_of_before("address_space: the child of its own handle could not map its board: ", op.STATUS_NAMES[status]))
		for stop_verdict in ([2]string{"was refused with No_Right", "was not refused with No_Right"}) {
			for outcome in op.Stop_Outcome {
				facts_expect_line(t, render(t, file, "Own_Handle_Child_Stopped", {{"give_status", u64(status)}, {"cause", u64(op.Stop_Cause.Itself)}, {"outcome", u64(outcome)}, {"stop_verdict", stop_verdict}}), line_of_before("address_space: a child stopped through its own process handle: the give gave ", op.STATUS_NAMES[status], ", the stop through the handle ", stop_verdict, ", and the child stopped: ", op.STOP_CAUSE_TEXTS[.Itself], ", ", op.STOP_OUTCOME_TEXTS[outcome]))
			}
			for cause in op.Stop_Cause {
				if cause == .Itself {
					continue
				}
				facts_expect_line(t, render(t, file, "Own_Handle_Child_Stopped_Without_Outcome", {{"give_status", u64(status)}, {"cause", u64(cause)}, {"stop_verdict", stop_verdict}}), line_of_before("address_space: a child stopped through its own process handle: the give gave ", op.STATUS_NAMES[status], ", the stop through the handle ", stop_verdict, ", and the child stopped: ", op.STOP_CAUSE_TEXTS[cause]))
			}
		}
	}
	problem :: "a decommit of more than the page limit of one call was not refused with its record"
	facts_expect_line(t, render(t, file, "Demonstration_Wrong", {{"problem", problem}}), line_of_before("address_space: wrong: ", problem))
}

// Each fact type of budget, time_page, crowd, cryptography_vectors, flow,
// frames and hall_of_fame writes the line of before: the counts 0, 1 and
// max(u64), and each text of a closed set.
@(test)
the_facts_of_the_small_demonstrations_write_the_lines_of_before :: proc(t: ^testing.T) {
	budget, budget_ok := demonstration_file(t, "budget")
	time_page, time_page_ok := demonstration_file(t, "time_page")
	crowd, crowd_ok := demonstration_file(t, "crowd")
	vectors, vectors_ok := demonstration_file(t, "cryptography_vectors")
	flow, flow_ok := demonstration_file(t, "flow")
	frames, frames_ok := demonstration_file(t, "frames")
	hall, hall_ok := demonstration_file(t, "hall_of_fame")
	if !budget_ok || !time_page_ok || !crowd_ok || !vectors_ok || !flow_ok || !frames_ok || !hall_ok {
		return
	}
	for count in DEMONSTRATION_COUNTS {
		other := max(u64) - count
		budget_answer :: "0123456789012345678901234567890123456789"
		facts_expect_line(t, fact_test_render(t, budget, "budget", "Wrong_Answer", {{"pages", count}, {"step", "close the new budget, keep the memory"}, {"answer", budget_answer}}), line_of_before("budget: wrong answer: ", "close the new budget, keep the memory", ": ", budget_answer, ", ", count, " pages"))
		facts_expect_line(t, fact_test_render(t, budget, "budget", "Budget_Held", {{"memory_objects", count}, {"threads", other}}), line_of_before("budget: ok, ", count, " memory objects then no budget, ", other, " threads then no budget, each page returned"))

		facts_expect_line(t, fact_test_render(t, time_page, "time_page", "Time_Page_Measured", {{"reads_in_one_second", count}, {"kernel_entries", other}}), line_of_before("time_page: the time page: ", count, " reads in one second, ", other, " kernel entries for one million reads"))
		facts_expect_line(t, fact_test_render(t, time_page, "time_page", "Kernel_Entry_Measured", {{"reads_in_one_second", other}, {"kernel_entries", count}}), line_of_before("time_page: a kernel entry: ", other, " reads in one second, ", count, " kernel entries for one million reads"))
		facts_expect_line(t, fact_test_render(t, time_page, "time_page", "Time_Page_Checked", {{"reads", count}, {"kernel_entries", other}}), line_of_before("time_page: the check of the time page: ", count, " reads, ", other, " kernel entries"))
		facts_expect_line(t, fact_test_render(t, time_page, "time_page", "Kernel_Entry_Checked", {{"reads", other}, {"kernel_entries", count}}), line_of_before("time_page: the check of a kernel entry: ", other, " reads, ", count, " kernel entries"))
		facts_expect_line(t, fact_test_render(t, time_page, "time_page", "Page_And_Kernel_Entry", {{"outside", count}, {"apart_most", other}}), line_of_before("time_page: the time page and a kernel entry: in 1000 pairs of reads of the page with an entry between them, the entry was outside the two reads ", count, " times; the two reads were at most ", other, " ms apart (a measure)"))
		facts_expect_line(t, fact_test_render(t, time_page, "time_page", "Page_And_Cycle_Counter", {{"compared", count}, {"least_behind", other}, {"most_behind", count}, {"most_ahead", other}}), line_of_before("time_page: the time page and the cycle counter: in ", count, " reads the page was ", other, " to ", count, " ms behind and at most ", other, " ms ahead"))

		for queue in ([2]string{"shared queue", "queue with a lock"}) {
			facts_expect_line(t, fact_test_render(t, crowd, "crowd", "Run_Measured", {{"writers", u64(3)}, {"readers", u64(1)}, {"records_in_one_second", count}, {"kernel_entries", other}, {"written_records", count}, {"read_records", other}, {"wrong_records", count}, {"queue", queue}}), line_of_before("crowd: ", queue, ", ", u64(3), " writers, ", u64(1), " readers: ", count, " records in one second, ", other, " kernel entries for one million records, ", count, " written, ", other, " read, ", count, " wrong"))
			facts_expect_line(t, fact_test_render(t, crowd, "crowd", "Run_Checked", {{"writers", u64(1)}, {"readers", u64(3)}, {"written_records", count}, {"read_records", other}, {"wrong_records", count}, {"kernel_entries", other}, {"queue", queue}}), line_of_before("crowd: ", queue, ", ", u64(1), " writers, ", u64(3), " readers: ", count, " written, ", other, " read, ", count, " wrong, ", other, " kernel entries for one million records"))
		}
		facts_expect_line(t, fact_test_render(t, crowd, "crowd", "Crowd_Wrong", {{"wrong_records", count}}), line_of_before("crowd: wrong: ", count, " records lost, in disorder or read two times"))
		facts_expect_line(t, fact_test_render(t, crowd, "crowd", "Crowd_Held", {{"runs", count}}), line_of_before("crowd: ok, ", count, " runs, each record written is read one time, each event started all the threads"))

		facts_expect_line(t, fact_test_render(t, vectors, "cryptography_vectors", "Speed_Measured", {{"call_time", count}, {"call_bytes", other}, {"megabytes_in_one_second", count}, {"primitive", "Ed25519 verify, 32 bytes"}}), line_of_before("cryptography_vectors: ", "Ed25519 verify, 32 bytes", ": ", count, " ns for ", other, " bytes, ", count, " MB/s"))
		facts_expect_line(t, fact_test_render(t, vectors, "cryptography_vectors", "Empty_Call_Measured", {{"call_time", count}}), line_of_before("cryptography_vectors: one call of an export of the module, through its import slot: ", count, " ns"))

		for waiting in ([2]string{"read the counters then wait", "wait at once"}) {
			facts_expect_line(t, fact_test_render(t, flow, "flow", "Ring_Measured", {{"capacity", u64(1024)}, {"records_in_one_second", count}, {"kernel_entries", other}, {"lost_records", count}, {"waiting", waiting}}), line_of_before("flow: capacity ", u64(1024), ", ", waiting, ": ", count, " records in one second, ", other, " kernel entries for one million records, ", count, " lost"))
			facts_expect_line(t, fact_test_render(t, flow, "flow", "Ring_Checked", {{"capacity", u64(32)}, {"read_records", count}, {"lost_records", other}, {"kernel_entries", count}, {"waiting", waiting}}), line_of_before("flow: capacity ", u64(32), ", ", waiting, ": ", count, " records read in order, ", other, " lost, ", count, " kernel entries for one million records"))
		}
		facts_expect_line(t, fact_test_render(t, flow, "flow", "Flow_Wrong", {{"lost_records", count}}), line_of_before("flow: wrong: ", count, " records lost"))
		facts_expect_line(t, fact_test_render(t, flow, "flow", "Flow_Held", {{"rings", count}}), line_of_before("flow: ok, ", count, " rings, 0 records lost"))

		facts_expect_line(t, fact_test_render(t, frames, "frames", "Twin_Not_Started", {{"status_word", count}}), line_of_before("frames: cannot start a twin: status ", status_text(count)))
		facts_expect_line(t, fact_test_render(t, frames, "frames", "Twins_Paid", {{"own_copy_pages", count}, {"shared_code_pages", other}, {"module_pages", count}}), line_of_before("frames: 4 twins: ", count, " pages with a copy of the module each, ", other, " pages with the shared code (", count, " pages of the module, once)"))
		facts_expect_line(t, fact_test_render(t, frames, "frames", "Create_And_Map_Measured", {{"frames_now", count}, {"frames_on_first_use", other}}), line_of_before("frames: create and map 8192 pages: ", count, " us with each frame now, ", other, " us with pages on first use"))
		facts_expect_line(t, fact_test_render(t, frames, "frames", "First_Use_Measured", {{"first_use", count}, {"write_present", other}}), line_of_before("frames: the first use of a page: ", count, " ns; a write to a page that has its frame: ", other, " ns"))
		facts_expect_line(t, fact_test_render(t, frames, "frames", "Twin_Start_Measured", {{"own_copy_start", count}, {"shared_code_start", other}}), line_of_before("frames: start a twin: ", count, " us with its own copy of the module, ", other, " us with the shared code"))
		facts_expect_line(t, fact_test_render(t, frames, "frames", "Frames_Held", {{"cases", count}}), line_of_before("frames: ok, ", count, " cases"))

		facts_expect_line(t, fact_test_render(t, hall, "hall_of_fame", "Portrait_Refused", {{"portrait", count}, {"pixels", other}, {"portrait_pixels", count}}), line_of_before("hall_of_fame: the portrait ", count, " has ", other, " pixels, not ", count, ": its card shows no picture"))
		facts_expect_line(t, fact_test_render(t, hall, "hall_of_fame", "First_Frame_Drawn", {{"drawn", count}, {"cards", other}, {"draw_time", count}}), line_of_before("hall_of_fame: ok, the first frame drew ", count, " of the ", other, " people in ", count, " us"))
	}
	causes := [2]string{"a least size is below the least size of a resizable surface", "the command ring of the window is full"}
	for cause in causes {
		facts_expect_line(t, fact_test_render(t, time_page, "time_page", "Window_Stays_Fixed", {{"cause", cause}}), line_of_before("time_page: the window stays fixed: ", cause))
	}
	refusals := [3]string{"; a bad input is refused with no byte given", "; a bad input was NOT refused", ""}
	for verdict in ([2]string{"passed", "FAILED"}) {
		for refusal in refusals {
			facts_expect_line(t, fact_test_render(t, vectors, "cryptography_vectors", "Vector_Checked", {{"verdict", verdict}, {"primitive", "ChaCha20-Poly1305"}, {"standard", "RFC 8032 7.1 test 1"}, {"refusal", refusal}}), line_of_before("cryptography_vectors: ", "ChaCha20-Poly1305", " (", "RFC 8032 7.1 test 1", "): ", verdict, refusal))
		}
	}
	frames_answer :: "012345678901234567890123456789012345678901234567"
	facts_expect_line(t, fact_test_render(t, frames, "frames", "Wrong_Answer", {{"case_text", "4 twins, each with a copy of the module"}, {"answer", frames_answer}}), line_of_before("frames: wrong answer: ", "4 twins, each with a copy of the module", ": ", frames_answer))
	for name in ([2]string{"United States Graphics Company", "Dax Raad"}) {
		facts_expect_line(t, fact_test_render(t, hall, "hall_of_fame", "Card_Chosen", {{"chosen_name", name}}), line_of_before("hall_of_fame: chose ", name))
	}
}

// Each fact type of counters and of guest_demo writes the line of before:
// a status word of 0, 1 and max(u64), as the lines wrote a status as its
// number; each status that a refusal expected, by its name; the counts 0,
// 1 and max(u64).
@(test)
the_facts_of_counters_and_guest_demo_write_the_lines_of_before :: proc(t: ^testing.T) {
	counters, counters_ok := demonstration_file(t, "counters")
	guest, guest_ok := demonstration_file(t, "guest_demo")
	if !counters_ok || !guest_ok {
		return
	}
	expected := [2]op.Status{.No_Right, .Bad_State}
	for count in DEMONSTRATION_COUNTS {
		other := max(u64) - count
		for step in ([2]string{"Read_Counters gave Unsupported and Start_Counters", "Read_Counters after the loop"}) {
			facts_expect_line(t, fact_test_render(t, counters, "counters", "Step_Failed", {{"status_word", count}, {"step", step}}), line_of_before("counters: failed: ", step, " gave ", status_text(count)))
		}
		for status in expected {
			facts_expect_line(t, fact_test_render(t, counters, "counters", "Step_Not_Refused", {{"status_word", count}, {"expected", u64(status)}, {"refused_step", "Start_Counters with a copy of the machine handle with no right"}}), line_of_before("counters: failed: ", "Start_Counters with a copy of the machine handle with no right", " gave ", status_text(count), ", not ", op.STATUS_NAMES[status]))
			facts_expect_line(t, fact_test_render(t, guest, "guest_demo", "Step_Not_Refused", {{"status_word", count}, {"expected", u64(status)}, {"step", "Process_Start of the guest"}}), line_of_before("guest_demo: failed: ", "Process_Start of the guest", " gave ", status_text(count), ", not ", op.STATUS_NAMES[status]))
		}
		facts_expect_line(t, fact_test_render(t, counters, "counters", "Loop_Too_Short", {{"turns", count}, {"instructions", other}, {"least_instructions", count}, {"cycles", other}, {"cache_misses", count}, {"branch_misses", other}}), line_of_before("counters: failed: a loop of ", count, " turns retired ", other, " instructions, fewer than ", count, "; ", other, " cycles, ", count, " cache misses, ", other, " branch misses"))
		facts_expect_line(t, fact_test_render(t, counters, "counters", "Orders_Read_Other_Words", {{"sum_in_order", count}, {"sum_by_page", other}}), line_of_before("counters: failed: the two orders read other words: ", count, " and ", other))
		facts_expect_line(t, fact_test_render(t, counters, "counters", "Loop_Retired", {{"turns", count}, {"least_instructions", other}}), line_of_before("counters: a loop of ", count, " turns retired at least ", other, " instructions: as it must"))
		facts_expect_line(t, fact_test_render(t, counters, "counters", "Orders_Read_Same_Words", {{"reads", count}, {"word_bytes", other}, {"region_pages", count}}), line_of_before("counters: ", count, " reads of ", other, " bytes in ", count, " pages, in order and by page, read the same words: as it must"))
		for measure in ([3]string{"the loop", "the reads in order", "the reads by page"}) {
			facts_expect_line(t, fact_test_render(t, counters, "counters", "Counts_Measured", {{"instructions", count}, {"cycles", other}, {"cache_misses", count}, {"branch_misses", other}, {"measure", measure}}), line_of_before("counters: ", measure, " (a measure): ", count, " instructions retired, ", other, " cycles, ", count, " cache misses, ", other, " branch misses"))
		}

		for step in ([2]string{"Memory_Map of the code in the guest", "Guest_Run"}) {
			facts_expect_line(t, fact_test_render(t, guest, "guest_demo", "Step_Failed", {{"status_word", count}, {"step", step}}), line_of_before("guest_demo: failed: ", step, " gave ", status_text(count)))
		}
		facts_expect_line(t, fact_test_render(t, guest, "guest_demo", "Port_Write_Size_Wrong", {{"port_write_bytes", count}}), line_of_before("guest_demo: failed: the port write has ", count, " bytes, not 1"))
		for instruction in ([2]string{"hlt", "int1"}) {
			facts_expect_line(t, fact_test_render(t, guest, "guest_demo", "Instruction_Not_Reached", {{"runs", count}, {"instruction", instruction}}), line_of_before("guest_demo: failed: the guest did not reach its ", instruction, " in ", count, " runs"))
		}
		facts_expect_line(t, fact_test_render(t, guest, "guest_demo", "Port_Writes_Wrong", {{"writes", count}, {"written_value", other}, {"written_port", count}}), line_of_before("guest_demo: failed: the guest wrote ", count, " times, the last ", other, " to the port ", count))
	}
}

// Each case of debugged is a fact type with one field, its verdict: each
// one writes the line of before with each verdict. The other fact types
// write their lines at the counts 0, 1 and max(u64), with each stop cause.
@(test)
the_facts_of_debugged_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := demonstration_file(t, "debugged")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "debugged", type_name, values)
	}
	Case_Line :: struct {
		type_name: string,
		sentence:  string,
	}
	cases := [?]Case_Line {
		{"Attach_Checked", "attach: the debugger is the debug handler of the child"},
		{"Breakpoints_On_Running_Thread_Refused", "a write of breakpoints on a thread that is not held: refused with Bad_State"},
		{"Handle_Without_Debug_Refused", "a handle with no Debug: attach and Stop refused with No_Right"},
		{"Kernel_Breakpoint_Refused", "a breakpoint at an address of the kernel: refused with the breakpoint address in the error record"},
		{"Execute_Breakpoint_Reached", "an execute breakpoint at a procedure of the child: the fault record names breakpoint 0 and the address"},
		{"Registers_At_Breakpoint", "the registers at the stop: the instruction address is the breakpoint"},
		{"Child_Memory_Read", "Read_Memory of a value of the child: the bytes of the child, not of the debugger"},
		{"Kernel_Memory_Read_Refused", "Read_Memory at an address of the kernel: refused with Bad_Address"},
		{"Unmapped_Memory_Read_Refused", "Read_Memory of a page that the child does not map: refused with Bad_Address"},
		{"Inspect_Only_Memory_Read_Refused", "Read_Memory through a thread handle with Inspect only: refused with No_Right"},
		{"Own_Thread_Breakpoints_Refused", "a write of breakpoints on a thread of the caller, with no Debug handle: refused with Bad_Handle"},
		{"Single_Step_Checked", "a single step: one instruction ran, and the record names the step"},
		{"Data_Breakpoint_Reached", "a data breakpoint on a word that the child writes: the fault record names breakpoint 1"},
		{"Breakpoints_Removed", "the breakpoints removed: the child resumed and stopped itself at its end"},
		{"Detach_While_Held", "a detach while a thread is held: the child runs again"},
		{"Debugger_Ended_While_Held", "the debugger ended while the child was held at a breakpoint: the child runs again"},
		{"Debugger_Closed_While_Held", "the debugger closed its handle while the child was held at a breakpoint: the child runs again"},
		{"Debugger_Revoked_While_Held", "the handle of the debugger was revoked while the child was held at a breakpoint: the child runs again"},
		{"Step_Then_Debugger_End", "a single step, then the end of the debugger: the child ran to its own end"},
		{"Breakpoint_Of_One_Thread", "a breakpoint of one thread: that thread stops, and another thread of the child runs through the same procedure"},
		{"Own_Stop_Kept_After_Detach", "a stop of the child on its own thread, then a stop and a detach of the debugger: the thread is still held by the stop of the child"},
		{"Kernel_Copy_Breakpoint", "a data breakpoint on a buffer that the kernel copies: the operation succeeded, no record came for the copy, and the read of the child came"},
		{"Stack_Selector_Breakpoint", "a data breakpoint that a load of the stack selector holds before a syscall: the kernel entry returned"},
		{"Full_Debugger_Ring", "a full ring of the debugger: the breakpoint is lost for the debugger, the child goes on, and a record comes again when the ring has room"},
	}
	for item in cases {
		for verdict in DEMONSTRATION_VERDICTS {
			facts_expect_line(t, render(t, file, item.type_name, {{"verdict", verdict}}), line_of_before("debugged: ", item.sentence, ": ", verdict))
		}
	}
	subjects := [2]string{"the debugger that steps", "the child"}
	for subject in subjects {
		facts_expect_line(t, render(t, file, "Detail_Not_Stopped", {{"subject", subject}}), line_of_before("debugged: detail: ", subject, " did not stop"))
		for outcome in op.Stop_Outcome {
			facts_expect_line(t, render(t, file, "Detail_Stopped", {{"cause", u64(op.Stop_Cause.Itself)}, {"outcome", u64(outcome)}, {"subject", subject}}), line_of_before("debugged: detail: ", subject, " stopped: ", op.STOP_CAUSE_TEXTS[.Itself], ", ", op.STOP_OUTCOME_TEXTS[outcome]))
		}
		for cause in op.Stop_Cause {
			if cause == .Itself {
				continue
			}
			facts_expect_line(t, render(t, file, "Detail_Stopped_Without_Outcome", {{"cause", u64(cause)}, {"subject", subject}}), line_of_before("debugged: detail: ", subject, " stopped: ", op.STOP_CAUSE_TEXTS[cause]))
		}
	}
	facts_expect_line(t, render(t, file, "Step_Failed", {{"role", "a second debugger"}, {"step", "the resume of the first thread of the child"}}), line_of_before("debugged: ", "a second debugger", ": ", "the resume of the first thread of the child", " failed"))
	paths := [2]string{"came to the debugger before the syscall", "was held until the kernel entry, and the kernel dropped it"}
	for path in paths {
		facts_expect_line(t, render(t, file, "Stack_Selector_Trap", {{"trap_path", path}}), line_of_before("debugged: detail: the trap of the load of the stack selector ", path))
	}
	for count in DEMONSTRATION_COUNTS {
		other := max(u64) - count
		for owner in ([2]string{"child", "debugger"}) {
			facts_expect_line(t, render(t, file, "Mode_Unknown", {{"mode_word", count}, {"mode_owner", owner}}), line_of_before("debugged: the context names the ", owner, " mode ", count, ", which names no mode"))
		}
		facts_expect_line(t, render(t, file, "Role_Unknown", {{"role_word", count}}), line_of_before("debugged: the context names the role ", count, ", which names no role"))
		facts_expect_line(t, render(t, file, "Attach_Status", {{"status_word", count}}), line_of_before("debugged: detail: the attach gave the status ", status_text(count)))
		facts_expect_line(t, render(t, file, "First_Breakpoint_Not_Set", {{"stop_status_word", count}, {"write_status_word", other}, {"resume_status_word", count}}), line_of_before("debugged: the first breakpoint was not set: the statuses ", status_text(count), " ", status_text(other), " ", status_text(count)))
		facts_expect_line(t, render(t, file, "Child_Rounds", {{"rounds", count}}), line_of_before("debugged: detail: the child ran ", count, " rounds"))
		facts_expect_line(t, render(t, file, "Revocation_Ended", {{"holdings", count}}), line_of_before("debugged: detail: the revocation ended ", count, " holdings"))
		facts_expect_line(t, render(t, file, "Own_Stop_Counts", {{"stop_count", count}, {"resume_status_word", other}, {"resume_count", count}}), line_of_before("debugged: detail: the stop of the debugger gave the count ", count, "; the Resume of the child gave the status ", status_text(other), " and the count ", count))
		facts_expect_line(t, render(t, file, "Data_Breakpoints_Not_Set", {{"attach_status_word", count}, {"stop_status_word", other}, {"write_status_word", count}, {"resume_status_word", other}}), line_of_before("debugged: the data breakpoints were not set: the statuses ", status_text(count), " ", status_text(other), " ", status_text(count), " ", status_text(other)))
		facts_expect_line(t, render(t, file, "Full_Ring_Faults", {{"faults", count}}), line_of_before("debugged: detail: the faults that found the ring full: ", count))
		facts_expect_line(t, render(t, file, "Debugged_Held", {{"cases", count}}), line_of_before("debugged: ok, ", count, " cases: a debugger holds, reads and steps one process, and its end gives the process back"))
		facts_expect_line(t, render(t, file, "Debugged_Failed", {{"wrong_cases", count}, {"cases", other}}), line_of_before("debugged: failed: ", count, " cases of ", other))
	}
}

// Each fact type of disk writes the line of before: a read and a write, one
// block and several, the counts 0, 1 and max(u64). The line of the
// measure record, "disk: read, 1 block in each request, 32 in flight", is
// the start of the sentence of Run_Measured with those fields.
@(test)
the_facts_of_disk_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := demonstration_file(t, "disk")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "disk", type_name, values)
	}
	Run_Shape :: struct {
		direction: string,
		blocks:    u64,
		word:      string,
	}
	shapes := [3]Run_Shape{{"read", 1, " block"}, {"write", 16, " blocks"}, {"read", max(u64), " blocks"}}
	for shape in shapes {
		for count in DEMONSTRATION_COUNTS {
			other := max(u64) - count
			facts_expect_line(t, render(t, file, "Run_Measured", {{"request_blocks", shape.blocks}, {"depth", u64(32)}, {"blocks_in_second", count}, {"own_entries", other}, {"service_entries", count}, {"request_errors", other}, {"direction", shape.direction}, {"block_word", shape.word[1:]}}), line_of_before("disk: ", shape.direction, ", ", shape.blocks, shape.word, " in each request, ", u64(32), " in flight: ", count, " blocks in one second, kernel entries for 100 requests: ", other, " of this process, ", count, " of the block service, ", other, " errors"))
			facts_expect_line(t, render(t, file, "Run_Checked", {{"request_blocks", shape.blocks}, {"depth", u64(1)}, {"requests", count}, {"own_entries", other}, {"service_entries", count}, {"request_errors", other}, {"direction", shape.direction}, {"block_word", shape.word[1:]}}), line_of_before("disk: ", shape.direction, ", ", shape.blocks, shape.word, " in each request, ", u64(1), " in flight: ", count, " requests, kernel entries for 100 requests: ", other, " of this process, ", count, " of the block service, ", other, " errors"))
		}
	}
	measured := render(t, file, "Run_Measured", {{"request_blocks", u64(1)}, {"depth", u64(32)}, {"blocks_in_second", u64(1)}, {"direction", "read"}, {"block_word", "block"}})
	testing.expectf(t, strings.has_prefix(measured, "disk: read, 1 block in each request, 32 in flight"), "the measured line of the disk is %q", measured)
	for count in DEMONSTRATION_COUNTS {
		other := max(u64) - count
		facts_expect_line(t, render(t, file, "Command_Word_Refused", {{"command_word", count}}), line_of_before("disk: the command word ", count, " of the block ring: refused with Bad_Command and the record Unsupported of the word, and the next Info is served: as it must"))
		facts_expect_line(t, render(t, file, "Command_Word_Not_Refused", {{"command_word", count}, {"status_word", other}, {"error_kind", count}, {"operation_word", other}, {"next_status_word", count}}), line_of_before("disk: the command word ", count, " of the block ring: WRONG: the status ", other, ", the error kind ", kind_text(count), ", the operation ", other, "; the next Info: the status ", count))
		facts_expect_line(t, render(t, file, "Window_Words_Read", {{"first_word", count}, {"second_word", other}, {"third_word", count}}), line_of_before("disk: the window sent the command words ", count, ", ", other, " and ", count, ": the compositor read the three: as it must"))
		facts_expect_line(t, render(t, file, "Window_Words_Not_Read", {{"first_word", count}, {"second_word", other}, {"third_word", count}, {"bound", other}}), line_of_before("disk: the window sent the command words ", count, ", ", other, " and ", count, ": WRONG: the compositor did not read them in ", other, " ms"))
		facts_expect_line(t, render(t, file, "Disk_Ready", {{"disk_blocks", count}, {"request_blocks_most", other}}), line_of_before("disk: ok, the disk has ", count, " blocks, ", other, " blocks in one request at most"))
		facts_expect_line(t, render(t, file, "Disk_Held", {{"runs", count}}), line_of_before("disk: ok, ", count, " runs, 0 errors, write then read back: 0 wrong"))
		facts_expect_line(t, render(t, file, "Disk_Wrong", {{"request_errors", count}, {"wrong_bytes", other}}), line_of_before("disk: wrong: ", count, " errors, ", other, " wrong bytes"))
	}
}

// Each fact type of errors and of extended_state writes the line of
// before: the counts 0, 1 and max(u64), an error kind of -1 and of
// max(i64), each answer yes or no, each stop cause and outcome.
@(test)
the_facts_of_errors_and_extended_state_write_the_lines_of_before :: proc(t: ^testing.T) {
	errors_file, errors_ok := demonstration_file(t, "errors")
	extended, extended_ok := demonstration_file(t, "extended_state")
	if !errors_ok || !extended_ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "errors_process", type_name, values)
	}
	answers := [2]string{"yes", "no"}
	for count in DEMONSTRATION_COUNTS {
		other := max(u64) - count
		facts_expect_line(t, render(t, errors_file, "Escaped_Name_Not_Refused", {{"status_word", count}}), line_of_before("errors: WRONG: a name of a process with an escape byte gave ", status_text(count)))
		details_cases := [4]string{"a kernel command with two wrong arguments", "an accepted kernel command with a table", "Log with two wrong arguments and a table", "an accepted Log with a table"}
		for details_case in details_cases {
			facts_expect_line(t, render(t, errors_file, "Details_Wrong", {{"status_word", count}, {"details", other}, {"details_case", details_case}}), line_of_before("errors: WRONG: ", details_case, " gave the status ", status_text(count), " and ", other, " error details"))
		}
		facts_expect_line(t, render(t, errors_file, "Small_Table_Wrong", {{"status_word", count}, {"details", other}}), line_of_before("errors: WRONG: a table of 1 place gave the status ", status_text(count), " and the count ", other))
		facts_expect_line(t, render(t, errors_file, "Full_Queue_Without_Memory", {{"held_status_word", count}, {"refused_status_word", other}}), line_of_before("errors: WRONG: the case of a full completion queue has no memory: ", status_text(count), " ", status_text(other)))
		for kind in ([2]i64{-1, max(i64)}) {
			facts_expect_line(t, render(t, errors_file, "Busy_Ring_Call_Not_Refused", {{"status_word", count}, {"error_kind", signed_bits(kind)}}), line_of_before("errors: WRONG: a kernel call on a kernel ring that holds records gave ", status_text(count), " and the kind ", kind_text(u64(kind))))
		}
		facts_expect_line(t, render(t, errors_file, "Details_Measured", {{"accepted_without_table", count}, {"accepted_with_table", other}, {"refused_with_record", count}, {"refused_with_details", other}}), line_of_before("errors: a kernel command and its table of error details: accepted with no table ", count, " ns, with a table ", other, " ns; refused with its error record ", count, " ns, with its 2 error details ", other, " ns"))
		facts_expect_line(t, render(t, errors_file, "Slot_Reused_Early", {{"slot", count}}), line_of_before("errors: WRONG: the slot ", count, " of the child served another process before its report was read"))
		facts_expect_line(t, render(t, errors_file, "Free_Slot_Report_Wrong", {{"slot", count}, {"state_word", other}, {"cause_word", count}, {"outcome_word", other}, {"handles", count}, {"entries", other}}), line_of_before("errors: WRONG: the report of the free slot ", count, " gives the state ", other, ", the stop cause ", count, ", the stop outcome ", other, ", ", count, " handles, ", other, " entries of the process before it"))
		facts_expect_line(t, render(t, errors_file, "Refusals_Child_Not_Started", {{"status_word", count}, {"stage_word", other}, {"kernel_status_word", count}, {"file_error_word", other}}), line_of_before("errors: WRONG: the child of the refusals did not start: ", status_text(count), ", the stage ", other, ", the status of the kernel ", status_text(count), ", the error of the file ", other))
		facts_expect_line(t, render(t, errors_file, "Contention_Counted", {{"failures", count}, {"handles_made", other}, {"wrong_records", count}, {"refused_records", other}}), line_of_before("errors: under contention: ", count, " failures from 2 threads while a third thread closed and made ", other, " handles; ", count, " records contradict their status, ", other, " records name no cause (Refused)"))
		facts_expect_line(t, render(t, errors_file, "Errors_Held", {{"cases", count}}), line_of_before("errors: ok, ", count, " cases, each with the expected error record"))
		facts_expect_line(t, render(t, errors_file, "Errors_Wrong", {{"wrong_cases", count}, {"cases", other}}), line_of_before("errors: ", count, " cases of ", other, " gave another answer"))
		facts_expect_line(t, render(t, errors_file, "Calls_Measured", {{"kernel_succeeds", count}, {"kernel_fails", other}, {"direct_succeeds", count}, {"direct_fails", other}}), line_of_before("errors: a kernel operation that succeeds: ", count, " ns; one that fails, with its error record: ", other, " ns; a direct call that succeeds: ", count, " ns; one that fails: ", other, " ns"))
		facts_expect_line(t, render(t, errors_file, "Page_Shown", {{"page", count}}), line_of_before("errors: the window shows the page ", count, " of the cases"))

		facts_expect_line(t, fact_test_render(t, extended, "extended_state", "Threads_Fewer_Than_Processors", {{"processors", count}, {"threads", other}}), line_of_before("extended_state: ", count, " processors: ", other, " threads, the most that a process can have, fewer than the processors plus two"))
		facts_expect_line(t, fact_test_render(t, extended, "extended_state", "Thread_Not_Started", {{"thread_number", count}}), line_of_before("extended_state: cannot start thread ", count))
		facts_expect_line(t, fact_test_render(t, extended, "extended_state", "Kernel_Entry_Measured", {{"kernel_entries", count}, {"xmm_time", other}, {"ymm_time", count}, {"zmm_time", other}}), line_of_before("extended_state: an empty kernel entry, ", count, " times: ", other, " ns with xmm in use, ", count, " ns with ymm in use, ", other, " ns with zmm in use (0: not usable)"))
		facts_expect_line(t, fact_test_render(t, extended, "extended_state", "Registers_Wrong", {{"wrong_registers", count}, {"wrong_start_parts", other}}), line_of_before("extended_state: failed: ", count, " wrong registers after a pass, ", other, " parts of a start state wrong"))
		for kept in ([2]string{"xmm0 to xmm15", "zmm0 to zmm31 and k0 to k7 (64 bits)"}) {
			facts_expect_line(t, fact_test_render(t, extended, "extended_state", "Registers_Kept", {{"threads", count}, {"processors", other}, {"passes", count}, {"kernel_entries", other}, {"kept_registers", kept}}), line_of_before("extended_state: ok, ", count, " threads on ", other, " processors, ", count, " passes, ", other, " kernel entries in the passes: each thread kept ", kept, ", the x87 stack, the x87 control word and MXCSR, and started with the start state"))
		}
		for components in ([4]string{"x87, SSE", "x87, SSE, AVX", "x87, SSE, AVX-512", "x87, SSE, AVX, AVX-512"}) {
			facts_expect_line(t, fact_test_render(t, extended, "extended_state", "Saved_Components", {{"saved_area_bytes", count}, {"components", components}}), line_of_before("extended_state: the kernel saves ", components, "; one save writes at most ", count, " bytes"))
		}
	}
	for first in answers {
		for second in answers {
			facts_expect_line(t, render(t, errors_file, "Full_Queue_Command_Wrong", {{"queue_filled", first}, {"command_held", second}}), line_of_before("errors: WRONG: a command past a full completion queue: the queue filled: ", first, "; the command held with no wait: ", second))
			facts_expect_line(t, render(t, errors_file, "Full_Queue_Answers_Wrong", {{"answers_in_order", first}, {"held_command_ran", second}}), line_of_before("errors: WRONG: the answers of a full completion queue: each once in order: ", first, "; the held command ran once: ", second))
		}
	}
	for state in ([2]string{"stopped by ", "running, its stop cause "}) {
		for cause in op.Stop_Cause {
			for outcome in op.Stop_Outcome {
				facts_expect_line(t, render(t, errors_file, "Busy_Ring_Stop_Wrong", {{"cause", u64(cause)}, {"outcome", u64(outcome)}, {"child_state", state}}), line_of_before("errors: WRONG: a stop on a kernel ring that holds records left the child ", state, op.STOP_CAUSE_TEXTS[cause], ", with the outcome ", op.STOP_OUTCOME_TEXTS[outcome]))
			}
		}
	}
}

// Each fact type of fault_ring writes the line of before: each verdict,
// the longest case name, each text of a closed set, each status from the
// first member to the last, each stop cause, and the counts 0, 1 and
// max(u64).
@(test)
the_facts_of_fault_ring_write_the_lines_of_before :: proc(t: ^testing.T) {
	file, ok := demonstration_file(t, "fault_ring")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "fault_ring", type_name, values)
	}
	name :: "a word wait, a fault, a decommit of the word"
	Entry_Line :: struct {
		type_name: string,
		sentence:  string,
	}
	entries := [?]Entry_Line {
		{"Two_Byte_Breakpoint", "int 3 in two bytes: one breakpoint record, at the address of the instruction plus 2"},
		{"Software_Page_Fault_Vector", "int 14: one protection fault with the error code 0x72, no page fault; the handler skipped the two bytes"},
		{"Debug_Instruction", "int1: one debug record, at the address of the instruction plus 1"},
		{"Trap_Flag_Steps", "the trap flag set with popfq: 6 debug records, one after each instruction, the last after the popfq that cleared the flag"},
		{"Stack_Selector_Then_Syscall", "mov ss, then syscall, with the trap flag: on this processor the machine went on, and each record is a debug trap of this process, in its code"},
		{"Stack_Selector_Then_Breakpoint", "mov ss, then int3, with the trap flag: on this processor the machine went on; one breakpoint record after the int3, and each other record is a debug trap of this process, in its code"},
		{"Two_Debug_Instructions", "two int1 in a row: two debug records, at the address of the first plus 1 and plus 2"},
	}
	statuses := [2]op.Status{min(op.Status), max(op.Status)}
	for verdict in DEMONSTRATION_VERDICTS {
		for entry in entries {
			facts_expect_line(t, render(t, file, entry.type_name, {{"verdict", verdict}}), line_of_before("fault_ring: ", entry.sentence, ": ", verdict))
		}
		for count in DEMONSTRATION_COUNTS {
			other := max(u64) - count
			facts_expect_line(t, render(t, file, "Read_Only_Write_Repaired", {{"page_value", count}, {"verdict", verdict}}), line_of_before("fault_ring: a write to a read-only page: the handler gave Write back; the page holds ", count, ": ", verdict))
			facts_expect_line(t, render(t, file, "Stack_Grown", {{"repaired_pages", count}, {"stack_pages", other}, {"least_repair_time", count}, {"verdict", verdict}}), line_of_before("fault_ring: a stack that grows: ", count, " pages of ", other, ", each one committed by the handler at its first touch; one repaired fault took ", count, " ns at least", ": ", verdict))
			for answer in ([2]string{"refused with Bad_State", "not refused"}) {
				facts_expect_line(t, render(t, file, "Foreign_Answer", {{"answered_thread", count}, {"answered_serial", other}, {"foreign_answer", answer}, {"verdict", verdict}}), line_of_before("fault_ring: an answer from another process: the parent answered for the thread ", count, " and the serial ", other, ": ", answer, "; the thread still waited, and the answer of its own process resumed it", ": ", verdict))
			}
			facts_expect_line(t, render(t, file, "Early_Answers", {{"answers", count}, {"right_values", other}, {"early_faults", count}, {"elapsed", other}, {"verdict", verdict}}), line_of_before("fault_ring: 10 000 answers given at once: ", count, " faults resumed, ", other, " values right, of ", count, ": ", verdict, ", in ", other, " ms"))
			facts_expect_line(t, render(t, file, "Breakpoint_Resumed", {{"records_seen", count}, {"record_kind", other}, {"computed", count}, {"verdict", verdict}}), line_of_before("fault_ring: a breakpoint, answered resume: ", count, " record of the kind ", other, "; the thread went on after the int3 and computed ", count, ": ", verdict))
			facts_expect_line(t, render(t, file, "Kinds_Never_Delivered", {{"refused_arguments", count}, {"asked_arguments", other}, {"verdict", verdict}}), line_of_before("fault_ring: the kinds never delivered: Fault_Handler_Set refused ", count, " arguments of ", other, " with Bad_Operation", ": ", verdict))
			for resume in ([3]string{"no answer", "a word that names no status", "Bad_State"}) {
				facts_expect_line(t, render(t, file, "Fault_Kind_At_Report_Instruction", {{"records_seen", count}, {"record_kind", other}, {"error_code", count}, {"case_name", name}, {"resume_answer", resume}, {"verdict", verdict}}), line_of_before("fault_ring: ", name, ": ", count, " record of the kind ", other, ", the error code ", count, ", ", "the instruction of the stop report", "; Resume got ", resume, ": ", verdict))
				facts_expect_line(t, render(t, file, "Fault_Kind_Not_At_Report_Instruction", {{"records_seen", count}, {"record_kind", other}, {"error_code", count}, {"case_name", name}, {"resume_answer", resume}, {"verdict", verdict}}), line_of_before("fault_ring: ", name, ": ", count, " record of the kind ", other, ", the error code ", count, ", ", "not the instruction of the stop report", "; Resume got ", resume, ": ", verdict))
			}
			for run_after in ([2]string{"the thread ran after its Resume", "the thread did not run after its Resume"}) {
				facts_expect_line(t, render(t, file, "Hostile_Frame_Refused", {{"refused_writes", count}, {"writes", other}, {"run_after", run_after}, {"verdict", verdict}}), line_of_before("fault_ring: a frame that a process cannot hold: ", count, " writes of ", other, " refused with Bad_Operation (the code selector of the kernel, the I/O privilege level, interrupts off, an instruction address that is not canonical); ", run_after, ": ", verdict))
				facts_expect_line(t, render(t, file, "Hostile_Extended_State_Refused", {{"run_after_resume", run_after}, {"verdict", verdict}}), line_of_before("fault_ring: an extended state that faults: every hostile write refused with Bad_Operation, the area that was read accepted; ", run_after, ": ", verdict))
			}
			facts_expect_line(t, render(t, file, "Foreign_Thread_Refused", {{"refused_calls", count}, {"tried_calls", other}, {"verdict", verdict}}), line_of_before("fault_ring: the thread of another process: ", count, " calls of ", other, " refused; no number and no handle of this process names it", ": ", verdict))
			facts_expect_line(t, render(t, file, "Handler_Records_Read", {{"records_read", count}, {"vector", other}, {"case_name", name}, {"verdict", verdict}}), line_of_before("fault_ring: ", name, ": the handler read ", count, " records; the stop report names the vector ", other, ": ", verdict))
			for running in ([2]string{"kept running", "did not run"}) {
				facts_expect_line(t, render(t, file, "Parent_Thread_Kept", {{"stop_count", count}, {"case_name", name}, {"parent_thread_running", running}, {"verdict", verdict}}), line_of_before("fault_ring: ", name, ": the thread of the parent has the stop count ", count, " and ", running, ": ", verdict))
			}
		}
		for place in ([2]string{"the instruction address is inside its loop", "the instruction address is NOT inside its loop"}) {
			for motion in ([2]string{"and the loop did not turn while the thread was stopped", "and the loop turned while the thread was stopped"}) {
				facts_expect_line(t, render(t, file, "Spinning_Thread_Stopped", {{"address_place", place}, {"loop_motion", motion}, {"verdict", verdict}}), line_of_before("fault_ring: a stop of a thread that spins: ", place, ", ", motion, ": ", verdict))
			}
		}
		for before in ([2]string{"it did not run before its Resume", "it ran before its Resume"}) {
			for after in ([2]string{"and it ran after it", "and it did not run after it"}) {
				facts_expect_line(t, render(t, file, "Waiting_Thread_Stopped", {{"before_resume", before}, {"after_resume", after}, {"verdict", verdict}}), line_of_before("fault_ring: a stop of a thread that waits: its wait ended, ", before, ", ", after, ": ", verdict))
			}
		}
		for status in statuses {
			facts_expect_line(t, render(t, file, "Two_Stops_Two_Resumes", {{"third_resume", u64(status)}, {"after_one_resume", "still stopped after one Resume"}, {"after_two_resumes", "not running after the second"}, {"verdict", verdict}}), line_of_before("fault_ring: two stops, two resumes: ", "still stopped after one Resume", ", ", "not running after the second", "; a third Resume got ", op.STATUS_NAMES[status], ": ", verdict))
			for result in DEMONSTRATION_COUNTS {
				facts_expect_line(t, render(t, file, "Divide_Error_Skipped", {{"result", result}, {"resume_status", u64(status)}, {"verdict", verdict}}), line_of_before("fault_ring: a divide error skipped by its handler: Resume before the write got ", op.STATUS_NAMES[status], "; after the write of the instruction address and rax, the thread went on with ", result, ": ", verdict))
			}
		}
		for cause in op.Stop_Cause {
			facts_expect_line(t, render(t, file, "Stopped_Again", {{"cause", u64(cause)}, {"case_name", name}, {"verdict", verdict}}), line_of_before("fault_ring: ", name, ": stopped again by this process, the child keeps the stop cause ", op.STOP_CAUSE_TEXTS[cause], ": ", verdict))
		}
	}
	for serial_answer in ([2]string{"refused with Bad_State, then the right answer resumed the thread: as it must", "not refused: WRONG"}) {
		facts_expect_line(t, render(t, file, "Wrong_Serial_Answer", {{"serial_answer", serial_answer}}), line_of_before("fault_ring: an answer with a wrong serial: ", serial_answer))
	}
	step :: "Fault_Handler_Set with the kinds of the entries"
	facts_expect_line(t, render(t, file, "Child_Step_Failed", {{"step", step}}), line_of_before("fault_ring: a child: ", step, " failed"))
	for status in statuses {
		for call in ([2]string{"memory_create", "memory_map"}) {
			facts_expect_line(t, render(t, file, "Shared_Page_Failed", {{"call_status", u64(status)}, {"case_name", name}, {"failed_call", call}}), line_of_before("fault_ring: ", name, ": ", call, " of the shared page failed: ", op.STATUS_NAMES[status]))
		}
		facts_expect_line(t, render(t, file, "Parent_Answer_Not_Refused", {{"answer_status", u64(status)}, {"case_name", name}}), line_of_before("fault_ring: ", name, ": Fault_Answer of the parent gave ", op.STATUS_NAMES[status], ", not Bad_State"))
		facts_expect_line(t, render(t, file, "Parent_Thread_Not_Started", {{"start_status", u64(status)}, {"case_name", name}}), line_of_before("fault_ring: ", name, ": the thread of the parent did not start: ", op.STATUS_NAMES[status]))
	}
	for count in DEMONSTRATION_COUNTS {
		other := max(u64) - count
		facts_expect_line(t, render(t, file, "Layout_Unknown", {{"layout_word", count}}), line_of_before("fault_ring: Thread_State gave the layout ", count, ", which names no layout: WRONG"))
		facts_expect_line(t, render(t, file, "Child_Not_Stopped", {{"bound", count}, {"case_name", name}}), line_of_before("fault_ring: ", name, ": the child did not stop in ", count, " ms"))
		facts_expect_line(t, render(t, file, "Child_Not_Stopped_Overall", {{"overall_bound", count}, {"progress", other}, {"early_faults", count}, {"answers", other}, {"elapsed", count}, {"case_name", name}}), line_of_before("fault_ring: ", name, ": the child did not stop in ", count, " ms: at step ", other, " of ", count, ", ", other, " answers, after ", count, " ms"))
		facts_expect_line(t, render(t, file, "Child_Without_Progress", {{"bound", count}, {"progress", other}, {"early_faults", count}, {"answers", other}, {"elapsed", count}, {"case_name", name}}), line_of_before("fault_ring: ", name, ": the child did not stop: no progress for ", count, " ms at step ", other, " of ", count, ", ", other, " answers, after ", count, " ms"))
		facts_expect_line(t, render(t, file, "Budget_Not_Returned", {{"bound", count}, {"pages", other}, {"pages_after", count}, {"threads", other}, {"threads_after", count}, {"processes", other}, {"processes_after", count}, {"case_name", name}}), line_of_before("fault_ring: ", name, ": the budget of this process did not get back every page, thread and process of the child in ", count, " ms: pages ", other, " expected, ", count, " after; threads ", other, ", ", count, "; processes ", other, ", ", count))
		facts_expect_line(t, render(t, file, "Budget_After_Line", {{"pages", count}, {"threads", other}, {"processes", count}, {"case_name", name}}), line_of_before("fault_ring: ", name, ": after the line: pages ", count, ", threads ", other, ", processes ", count))
		facts_expect_line(t, render(t, file, "Role_Unknown", {{"role_word", count}}), line_of_before("fault_ring: the context names the role ", count, ", which names no role"))
		facts_expect_line(t, render(t, file, "Fault_Ring_Held", {{"cases", count}}), line_of_before("fault_ring: ok, ", count, " cases: each fault was repaired, or stopped its process with the report of today, each control of a thread held, and each child gave back every page and every thread"))
		facts_expect_line(t, render(t, file, "Fault_Ring_Failed", {{"wrong_cases", count}, {"cases", other}}), line_of_before("fault_ring: failed: ", count, " cases of ", other))
	}
}

// Each fact type of fetch and of heron writes the line of before: each
// part that is there or not, the longest address and a short one, the
// counts 0, 1 and max(u64).
@(test)
the_facts_of_fetch_and_heron_write_the_lines_of_before :: proc(t: ^testing.T) {
	fetch, fetch_ok := demonstration_file(t, "fetch")
	heron, heron_ok := demonstration_file(t, "heron")
	if !fetch_ok || !heron_ok {
		return
	}
	marks := [2]string{"", " (WRONG)"}
	for count in DEMONSTRATION_COUNTS {
		other := max(u64) - count
		for mark in marks {
			for address in ([2]string{"255.255.255.255", "10.0.2.100"}) {
				facts_expect_line(t, fact_test_render(t, fetch, "fetch", "Grant_Read", {{"remote_port", count}, {"first_local_port", other}, {"last_local_port", count}, {"remote_address", address}, {"wrong_mark", mark}}), line_of_before("fetch: ", "the grant", ": ", "TCP to ", address, " port ", count, " only, from the local ports ", other, " to ", count, mark))
			}
			facts_expect_line(t, fact_test_render(t, fetch, "fetch", "Handshake_Established", {{"handshake_time", count}, {"segment_size_most", other}, {"wrong_mark", mark}}), line_of_before("fetch: ", "the handshake with 10.0.2.100 port 80", ": ", "established in ", count, " us, the MSS ", other, mark))
			facts_expect_line(t, fact_test_render(t, fetch, "fetch", "Hello_Answered", {{"status_code", count}, {"request_time", other}, {"wrong_mark", mark}, {"body", "hello from the host"}}), line_of_before("fetch: ", "GET /hello", ": ", "status ", count, ", \"", "hello from the host", "\" in ", other, " us", mark))
			for close_end in ([3]string{"and sent its own: TIME-WAIT for 10 s", "and keeps its half open: FIN-WAIT-2", "WRONG: no ACK of the FIN"}) {
				facts_expect_line(t, fact_test_render(t, fetch, "fetch", "Close_Acknowledged", {{"wrong_mark", mark}, {"close_end", close_end}}), line_of_before("fetch: ", "the close from this side", ": ", "the remote acknowledged the FIN, ", close_end, mark))
			}
		}
		facts_expect_line(t, fact_test_render(t, fetch, "fetch", "Hello_Timed", {{"request_sent", count}, {"first_segment", other}, {"first_data", count}}), line_of_before("fetch: GET /hello: the request went to the network service after ", count, " us, the first segment came after ", other, " us, the first segment with data after ", count, " us"))
		facts_expect_line(t, fact_test_render(t, fetch, "fetch", "Connection_Counted", {{"segments_sent", count}, {"segments_received", other}, {"retransmissions", count}, {"smoothed_round_trip", other}, {"bad_checksums", count}}), line_of_before("fetch: the connection: ", count, " segments sent, ", other, " received, ", count, " retransmissions, srtt ", other, " us, ", count, " segments dropped for a wrong checksum"))
		facts_expect_line(t, fact_test_render(t, fetch, "fetch", "Fetch_Held", {{"cases", count}}), line_of_before("fetch: ok, ", count, " cases"))
		facts_expect_line(t, fact_test_render(t, fetch, "fetch", "Fetch_Wrong", {{"wrong_cases", count}, {"cases", other}}), line_of_before("fetch: WRONG: ", count, " of ", other, " cases"))

		facts_expect_line(t, fact_test_render(t, heron, "heron", "Played_In_Own_Order", {{"frames", count}, {"animation", "scratch"}}), line_of_before("heron: ", "scratch", " played in its own order: ", count, " frames"))
		for motion in ([4]string{"", ", the heron left the window and came back", ", the heron moved and came back to its place", ", the heron is not back in its place"}) {
			for ways in ([3]string{", on the grid and free", ", on the grid", ", free"}) {
				facts_expect_line(t, fact_test_render(t, heron, "heron", "Played", {{"frames", count}, {"animation", "dash"}, {"motion", motion}, {"ways", ways}}), line_of_before("heron: ", "dash", " played: ", count, " frames", motion, ways))
			}
		}
		for held in ([2]string{", held", ""}) {
			for lines in ([2]string{"shown", "hidden"}) {
				for side in ([2]string{"left", "right"}) {
					facts_expect_line(t, fact_test_render(t, heron, "heron", "Grid_Frame_Shown", {{"frame", count}, {"frame_count", other}, {"cells_sideways", count}, {"cells_up", other}, {"changed_cells", count}, {"animation", "dash"}, {"held", held}, {"form", "long neck"}, {"side", side}, {"cell_lines", lines}}), line_of_before("heron: shows ", "dash", " at frame ", count, " of ", other, held, ", on the grid: the form ", "long neck", ", ", count, " cells to the ", side, " and ", other, " up; the lines of the cells ", lines, "; ", count, " cells of the frame differ from the still heron"))
				}
				facts_expect_line(t, fact_test_render(t, heron, "heron", "Free_Frame_Shown", {{"frame", count}, {"frame_count", other}, {"width", count}, {"height", other}, {"changed_cells", count}, {"animation", "dash"}, {"held", held}, {"cell_lines", lines}}), line_of_before("heron: shows ", "dash", " at frame ", count, " of ", other, held, ", free: the frame stretched to ", count, " by ", other, " pixels; the lines of the cells ", lines, "; ", count, " cells of the frame differ from the still heron"))
			}
		}
		facts_expect_line(t, fact_test_render(t, heron, "heron", "Cell_Size_Changed", {{"cell_size", count}}), line_of_before("heron: cells of ", count, " pixels"))
	}
	for way in ([2]string{"on the grid", "free"}) {
		for lines in ([2]string{"shown", "hidden"}) {
			facts_expect_line(t, fact_test_render(t, heron, "heron", "Still_Shown", {{"way", way}, {"cell_lines", lines}}), line_of_before("heron: shows the still heron, ", way, "; the lines of the cells ", lines))
		}
	}
	for time in DEMONSTRATION_COUNTS {
		facts_expect_line(t, fact_test_render(t, heron, "heron", "Picture_Measured", {{"picture_time", time}, {"damaged_pixels", u64(1)}, {"window_pixels", u64(307200)}, {"pictures", max(u64)}, {"animation", "scratch"}}), line_of_before("heron: a picture of ", "scratch", " took ", microseconds_text(time), " to draw and damaged ", u64(1), " pixels of the ", u64(307200), " of the window, the means of ", max(u64), " pictures (a measure)"))
	}
}

// Each fact type with no field writes the line of before, which was a text
// with no value: its sentence is its template, and its record has no byte.
// The handshake with no answer changed: it wrote "no answer00" before.
@(test)
the_facts_with_no_field_write_the_lines_of_before :: proc(t: ^testing.T) {
	No_Field_Line :: struct {
		folder:       string,
		package_name: string,
		type_name:    string,
		line:         string,
	}
	lines := [?]No_Field_Line {
		{"address_space", "address_space", "Address_Space_Held", "address_space: ok, the arena and the sparse table paid only what they used, the decommit gave each page back, the protection changed with its shoot-down, the guard page stopped the child, the large pages are in the report, each refusal has its error record"},
		{"address_space", "address_space", "Own_Handle_Child_Without_Handle", "address_space: the child of its own handle got no handle"},
		{"address_space", "address_space", "Refused_Stop_Stopped_Child", "address_space: WRONG: a refused Process_Stop stopped the child"},
		{"address_space", "address_space", "Neighbour_Page_Not_Mapped", "address_space: page tables: the page of the other thread: no mapping: WRONG"},
		{"time_page", "time_page", "Clock_Held", "time_page: ok, the time never went back, the page and the kernel give the same time, the kernel refuses to remove the time page"},
		{"counters", "counters", "Start_Without_Right_Refused", "counters: Start_Counters with a copy of the machine handle with no right gave No_Right: as it must"},
		{"counters", "counters", "Counters_Unsupported", "counters: Read_Counters and Start_Counters gave Bad_Operation with the error kind Unsupported: the processors of this machine have no counters that the kernel uses: as it must"},
		{"counters", "counters", "Read_Before_Start_Refused", "counters: Read_Counters before Start_Counters gave Bad_State: as it must"},
		{"counters", "counters", "Second_Read_Below_First", "counters: failed: a second read gave a count below the first"},
		{"counters", "counters", "Second_Read_Not_Below", "counters: a second read gave no count below the first: as it must"},
		{"counters", "counters", "Stop_Without_Handle_Checked", "counters: Stop_Counters with no handle gave Ok, and Read_Counters after it gave Bad_State: as it must"},
		{"counters", "counters", "Counters_Held", "counters: ok"},
		{"debugged", "debugged", "No_Shared_Page", "debugged: no shared page"},
		{"debugged", "debugged", "Child_Not_Started", "debugged: a child did not start"},
		{"debugged", "debugged", "Execute_Breakpoint_Without_Record", "debugged: an execute breakpoint at a procedure of the child: no record came: WRONG"},
		{"debugged", "debugged", "No_Random_Seed", "debugged: no random seed in the context"},
		{"debugged", "debugged", "No_Boot_Image", "debugged: no boot image"},
		{"disk", "disk", "No_Block_Ring", "disk: no block ring"},
		{"disk", "disk", "No_Data_Region", "disk: no data region"},
		{"disk", "disk", "Block_Ring_Not_Mapped", "disk: the block service does not map the block ring"},
		{"errors", "errors_process", "Escaped_Name_Refused", "errors: a name of a process with an escape byte is refused: as it must"},
		{"errors", "errors_process", "Two_Details_Given", "errors: a kernel command with two wrong arguments gives the two in its table of error details: as it must"},
		{"errors", "errors_process", "Small_Table_Counts_Each", "errors: a table smaller than its error details holds the first and counts each one: as it must"},
		{"errors", "errors_process", "Accepted_Command_Table_Empty", "errors: an accepted kernel command leaves its table of error details empty: as it must"},
		{"errors", "errors_process", "Log_Details_Given", "errors: Log with a level that names no member and one run past the bound gives the two in its table of error details: as it must"},
		{"errors", "errors_process", "Accepted_Log_Table_Empty", "errors: an accepted Log with a table of error details leaves the table empty: as it must"},
		{"errors", "errors_process", "Full_Queue_Push_Refused", "errors: WRONG: the kernel ring refused a push of the case of a full completion queue"},
		{"errors", "errors_process", "Command_Past_Full_Queue_Held", "errors: a command past a full completion queue stays unrun in the kernel ring, and the entry does not wait: as it must"},
		{"errors", "errors_process", "Busy_Ring_Call_Refused", "errors: a kernel call on a kernel ring that holds records is refused with Busy, and its command does not run: as it must"},
		{"errors", "errors_process", "Busy_Ring_Wait_Ended", "errors: a wait of the library on a kernel ring that holds records ends at once and pushes nothing: as it must"},
		{"errors", "errors_process", "Busy_Ring_Wait_Wrong", "errors: WRONG: a wait of the library on a kernel ring that holds records waited or pushed its command"},
		{"errors", "errors_process", "Full_Queue_Answers_In_Order", "errors: each answer of a full completion queue arrives once and in order, and the held command runs once after them: as it must"},
		{"errors", "errors_process", "Sum_Of_Calls_Zero", "errors: the sum of the calls is 0"},
		{"errors", "errors_process", "Free_Slot_Report_Empty", "errors: the report of the slot of the child after its last handle closed gives its state None and its serial, and no fact of the child: as it must"},
		{"errors", "errors_process", "Busy_Ring_Stop_Is_Itself", "errors: a stop on a kernel ring that holds records ends the process as a stop of itself, not a fault: as it must"},
		{"errors", "errors_process", "No_Random_Seed", "errors: no random seed in the context"},
		{"errors", "errors_process", "Contention_Case_Failed", "errors: WRONG: the case under contention failed"},
		{"extended_state", "extended_state", "Avx_Not_Usable", "extended_state: AVX is not usable: the processor does not have it or the kernel does not save it; the test holds xmm0 to xmm15"},
		{"fault", "fault", "Write_To_Address_Zero", "fault: this process writes to address 0"},
		{"fault", "fault", "Write_Did_Not_Stop", "fault: the write did not stop the process"},
		{"fault_ring", "fault_ring", "No_Random_Seed", "fault_ring: no random seed in the context"},
		{"fault_ring", "fault_ring", "No_Boot_Image", "fault_ring: no boot image"},
		{"fetch", "fetch", "Handshake_Not_Answered", "fetch: the handshake with 10.0.2.100 port 80: no answer (WRONG)"},
		{"fetch", "fetch", "Held_Commands_Past_Bound", "fetch: the held commands passed their proven bound"},
		{"fetch", "fetch", "No_Random_Seed", "fetch: no random seed in the context"},
		{"fetch", "fetch", "No_Endpoint", "fetch: no endpoint: the process has no grant of the network"},
		{"fetch", "fetch", "No_Datagram_Region", "fetch: no datagram region"},
		{"fetch", "fetch", "No_Connection_Memory", "fetch: no memory for the buffers of the connections"},
		{"fetch", "fetch", "Sequence_Secret_Taken", "fetch: the secret of the initial sequence numbers from the generator of the process"},
		{"fetch", "fetch", "Connection_Ended", "fetch: the connection ended, its record is free"},
		{"frames", "frames", "No_Random_Seed", "frames: no random seed in the context"},
		{"guest_demo", "guest_demo", "Guests_Unsupported", "guest_demo: Guest_Run gave Bad_Operation with the error kind Unsupported: the processors of this machine have no virtualization support that the kernel uses, and no guest runs: as it must"},
		{"guest_demo", "guest_demo", "Port_Written_Then_Halted", "guest_demo: the guest wrote 42 to the port 0x80, then halted after it: as it must"},
		{"guest_demo", "guest_demo", "Debug_Exit_Arrived", "guest_demo: the int1 of the guest arrived as an exit Other with the exit code 0x88: as it must"},
		{"guest_demo", "guest_demo", "Guest_Start_Refused", "guest_demo: Process_Start of the guest gave Bad_State: as it must"},
		{"guest_demo", "guest_demo", "Guest_Demo_Held", "guest_demo: ok"},
		{"heron", "heron", "No_Random_Seed", "heron: no random seed in the context"},
		{"heron", "heron", "First_Picture_Presented", "heron: ok, the first picture is presented"},
		{"heron", "heron", "Paused", "heron: paused"},
		{"heron", "heron", "Plays_Again", "heron: plays again"},
		{"heron", "heron", "Slow", "heron: slow"},
		{"heron", "heron", "Full_Speed", "heron: full speed"},
	}
	for item in lines {
		file, ok := demonstration_file(t, item.folder)
		if !ok {
			continue
		}
		facts_expect_line(t, fact_test_render(t, file, item.package_name, item.type_name, {}), item.line)
	}
}

// The words of the new kinds as the lines wrote them: 16 hexadecimal
// digits as system.Hex writes them, hundredths with two decimals, and
// nanoseconds as microseconds with one decimal, cut.
@(private = "file")
hex_text :: proc(value: u64) -> string {
	return fmt.tprintf("%016x", value)
}

@(private = "file")
hundredths_text :: proc(value: i64) -> string {
	if value < 0 {
		return fmt.tprintf("-%d.%02d", -value / 100, -value % 100)
	}
	return fmt.tprintf("%d.%02d", value / 100, value % 100)
}

@(private = "file")
microseconds_text :: proc(nanoseconds: u64) -> string {
	return fmt.tprintf("%d.%d us", nanoseconds / 1000, nanoseconds / 100 % 10)
}

// The hundredths of these tests: 0, one, one less than a whole, a
// negative value, and the largest.
@(private = "file")
DEMONSTRATION_HUNDREDTHS := [5]i64{0, 1, 99, -50, max(i64)}

// The words of 16 hexadecimal digits at their edges.
@(private = "file")
DEMONSTRATION_WORDS := [4]u64{0, 1, 0x5eed000000000003, max(u64)}

// The status words of these tests: the first member, a refusal, the last
// member, one past it, and the largest word, which name no member.
@(private = "file")
DEMONSTRATION_STATUS_WORDS := [5]u64{u64(min(op.Status)), u64(op.Status.No_Right), u64(max(op.Status)), u64(max(op.Status)) + 1, max(u64)}

// Each fact type of address_space of the second round writes its line: the
// library refusal of a stop with each status word, the measures, the guard
// page with its address, the large pages in hundredths, a refusal and each
// step of the delegation with each error record of these tests.
@(test)
the_facts_of_address_space_of_the_second_round_write_their_lines :: proc(t: ^testing.T) {
	file, ok := demonstration_file(t, "address_space")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "address_space", type_name, values)
	}
	for word in DEMONSTRATION_STATUS_WORDS {
		for stop_word in DEMONSTRATION_COUNTS {
			facts_expect_line(t, render(t, file, "Stop_Command_Refused_By_Library", {{"stop_word", stop_word}, {"call_status", word}}), line_of_before("address_space: WRONG: the library refused the command of Process_Stop with the word ", stop_word, ": ", status_text(word)))
		}
		facts_expect_line(t, render(t, file, "Stop_Word_Not_Refused", {{"stop_word", u64(1)}, {"status_word", word}, {"error_kind", word}, {"argument", u64(2)}, {"limit", u64(0)}, {"target", "a child"}}), line_of_before("address_space: WRONG: Process_Stop of ", "a child", " with the word ", u64(1), " gave the status word ", status_text(word), ", the error kind ", kind_text(word), ", the argument ", i64(2), " and the limit ", i64(0)))
	}
	for count in DEMONSTRATION_COUNTS {
		other := max(u64) - count
		facts_expect_line(t, render(t, file, "Arena_Measured", {{"frame_list_pages", count}, {"map_time", other}, {"pages_one_range", count}, {"pages_16_ranges", other}, {"pages_256_ranges", count}, {"entries_one_range", other}, {"entries_16_ranges", count}, {"entries_256_ranges", other}}), line_of_before("address_space: arena: 1 GiB of addresses in one mapping, ", count, " pages paid for its frame list, mapped in ", other, " us; pages committed and used in one second with 1, 16, 256 ranges for each kernel entry: ", count, ", ", other, ", ", count, "; kernel entries for 1000 pages: ", other, ", ", count, ", ", other))
		facts_expect_line(t, render(t, file, "Protection_Measured", {{"least_one_processor", count}, {"most_one_processor", other}, {"least_two_processors", count}, {"most_two_processors", other}, {"least_four_processors", count}, {"most_four_processors", other}}), line_of_before("address_space: protection of 64 pages, one call with its shoot-down, the middle of 40 calls, least and most of 5 batches: ", count, " to ", other, " ns with 1 processor running the process, ", count, " to ", other, " ns with 2, ", count, " to ", other, " ns with 4"))
		for address in DEMONSTRATION_WORDS {
			facts_expect_line(t, render(t, file, "Guard_Page_Stop", {{"vector", count}, {"fault_address", address}, {"in_guard_page", u64(1)}}), line_of_before("address_space: guard page: the child stopped with vector ", count, " at ", hex_text(address), ", in its guard page: ", u64(1)))
		}
	}
	for hundredths in DEMONSTRATION_HUNDREDTHS {
		facts_expect_line(t, render(t, file, "Large_Pages_Measured", {{"large_page_read", u64(hundredths)}, {"small_page_read", u64(hundredths)}, {"large_in_report", u64(1)}}), line_of_before("address_space: large pages: one random read over 64 MiB: ", hundredths_text(hundredths), " ns through large pages of 2 MiB, ", hundredths_text(hundredths), " ns through pages of 4 KiB of the same object; the report says Large: ", u64(1)))
	}
	Step_Line :: struct {
		type_name: string,
		head:      string, // The words before the verdict.
		note:      string, // The words between the verdict and the record.
	}
	steps := [?]Step_Line {
		{"Delegation_Commit_Past_Budget", "1 B commits 32 pages, then one more", "32 pages committed; the 33rd: "},
		{"Delegation_Commit_Without_Budget", "2 B commits with no budget handle; it reads and writes the committed pages", "B wrote and read 55 in a committed page; a commit: "},
		{"Delegation_Object_With_Commit_Only", "3 B makes an object with the handle that has Commit only", ""},
		{"Delegation_Commit_With_Other_Payer", "4 B commits with a budget that does not pay for the object", ""},
		{"Delegation_Commit_After_Revocation", "5 A revokes the budget handle of B: B commits no more", "the 32 pages stay committed and paid (the child budget holds 0); a commit: "},
		{"Delegation_Decommit_Of_Shared_Object", "7 B decommits pages of an object that A holds too", ""},
		{"Delegation_Give_Without_Right", "9 B gives its Commit handle on: it has no right Give", ""},
	}
	plain_steps := [?]Step_Line {
		{"Delegation_Pages_Taken_Back", "6 A takes the pages back: it revokes the object of B, then decommits", "32 pages back in the child budget; A held the object with no mapping"},
		{"Delegation_Pages_Not_Taken_Back", "6 A takes the pages back: it revokes the object of B, then decommits", "the decommit was refused"},
		{"Delegation_Object_Moved", "8 the child budget ends: the object moves to the budget of A", "a commit with the budget of A: 1 page; with the old handle: refused"},
		{"Delegation_Object_Not_Moved", "8 the child budget ends: the object moves to the budget of A", "the commit with the budget of A was refused"},
		{"Delegation_Object_Lives_On", "10 an object that B made with a Spend handle, after the revocation", "the object of 1 page that B made with it lives on after the revocation, paid by the child budget, and A cannot end it: the narrow right Commit makes no object"},
		{"Delegation_Object_Gone", "10 an object that B made with a Spend handle, after the revocation", "the object did not stay"},
	}
	for verdict in ([2]string{"as expected", "WRONG"}) {
		for step in steps {
			for record in DEMONSTRATION_RECORDS {
				facts_expect_line(t, render(t, file, step.type_name, with_values(record, {"verdict", verdict})), line_of_before("address_space: delegation: ", step.head, ": ", verdict, ": ", step.note, record_words(record)))
			}
		}
		for step in plain_steps {
			facts_expect_line(t, render(t, file, step.type_name, {{"verdict", verdict}}), line_of_before("address_space: delegation: ", step.head, ": ", verdict, ": ", step.note))
		}
	}
	for record in DEMONSTRATION_RECORDS {
		for name in ([2]string{"a range outside the object", "write and execute"}) {
			facts_expect_line(t, render(t, file, "Refusal_Recorded", with_values(record, {"refusal_name", name})), line_of_before("address_space: refused: ", name, ": ", record_words(record)))
		}
	}
}

// Each fact type of time_page, cryptography_vectors, debugged and disk of the
// second round writes its line: the times as microseconds with one decimal
// at their edges, the head of a hash, each address of these tests, the
// status words, and each error record of these tests.
@(test)
the_facts_of_time_page_debugged_and_disk_of_the_second_round_write_their_lines :: proc(t: ^testing.T) {
	time_page, time_page_ok := demonstration_file(t, "time_page")
	vectors, vectors_ok := demonstration_file(t, "cryptography_vectors")
	debugged, debugged_ok := demonstration_file(t, "debugged")
	disk, disk_ok := demonstration_file(t, "disk")
	if !time_page_ok || !vectors_ok || !debugged_ok || !disk_ok {
		return
	}
	times := [4]u64{0, 999, 812_499, max(u64)}
	for time in times {
		facts_expect_line(t, fact_test_render(t, time_page, "time_page", "Picture_Measured", {{"picture_time", time}}), line_of_before("time_page: the window drew one picture in ", microseconds_text(time), ", the mean of 10"))
		facts_expect_line(t, fact_test_render(t, time_page, "time_page", "Interface_Measured", {{"records", u64(1)}, {"damage_rectangles", max(u64)}, {"build_time", time}, {"difference_time", time}, {"draw_time", time}}), line_of_before("time_page: the interface: ", u64(1), " records, ", max(u64), " damage rectangles; build ", microseconds_text(time), ", difference ", microseconds_text(time), ", draw ", microseconds_text(time)))
	}
	for count in DEMONSTRATION_COUNTS {
		for removal in ([2]string{"refuses", "does not refuse"}) {
			facts_expect_line(t, fact_test_render(t, time_page, "time_page", "Time_Wrong", {{"went_back", count}, {"outside", count}, {"page_changes", count}, {"least_behind", count}, {"most_ahead", count}, {"removal", removal}}), line_of_before("time_page: wrong: the time went back ", count, " times, a kernel entry was outside two reads of the page ", count, " times, the page changed ", count, " times and is at least ", count, " ms behind and ", count, " ms ahead of the cycle counter, the kernel ", removal, " to remove the time page"))
		}
	}

	// The head of 16 bytes of a hash: the record is written by hand, since
	// the helpers of these tests give a whole hash only.
	key, bytes, made := fact_test_record(t, vectors, "cryptography_vectors", "Vectors_Of_Module", {{"passed", u64(23)}, {"vectors", u64(24)}})
	if made {
		head: [16]u8
		for index in 0 ..< len(head) {
			head[index] = u8(index * 17)
		}
		copy(bytes[16:], head[:])
		buffer: [module.FACT_SENTENCE_BYTES_MOST]u8
		count, _, refusal := module.fact_sentence_write(vectors, key, bytes, buffer[:], nil)
		testing.expectf(t, refusal == .None, "the fact Vectors_Of_Module is refused: %v", refusal)
		facts_expect_line(t, string(buffer[:count]), "cryptography_vectors: the module cryptography, BLAKE3 00112233445566778899aabbccddeeff...: 23 of 24 vectors passed")
	}

	for word in DEMONSTRATION_WORDS {
		other := max(u64) - word
		facts_expect_line(t, fact_test_render(t, debugged, "debugged", "Execute_Breakpoint_Record", {{"record_kind", u64(3)}, {"error_code", word}, {"instruction", other}, {"procedure", word}}), line_of_before("debugged: detail: the record of the execute breakpoint: kind ", u64(3), ", status ", hex_text(word), ", instruction ", hex_text(other), ", the procedure ", hex_text(word)))
		facts_expect_line(t, fact_test_render(t, debugged, "debugged", "Child_Value_Read", {{"child_value", word}, {"debugger_copy", other}}), line_of_before("debugged: detail: the value of the child ", hex_text(word), ", the copy of the debugger ", hex_text(other)))
		facts_expect_line(t, fact_test_render(t, debugged, "debugged", "Step_Detail", {{"error_code", word}, {"address_before", other}, {"address_after", word}, {"first_byte", u64(0xcc)}}), line_of_before("debugged: detail: the step: status ", hex_text(word), ", the instruction address from ", hex_text(other), " to ", hex_text(word), ", the first byte ", hex_text(0xcc)))
		facts_expect_line(t, fact_test_render(t, debugged, "debugged", "Data_Breakpoint_Record", {{"record_kind", u64(1)}, {"error_code", word}, {"child_word", other}}), line_of_before("debugged: detail: the record of the data breakpoint: kind ", u64(1), ", status ", hex_text(word), ", the word of the child ", other))
		for status in DEMONSTRATION_STATUS_WORDS {
			facts_expect_line(t, fact_test_render(t, debugged, "debugged", "Kernel_Copy_Detail", {{"log_status", status}, {"error_code", word}}), line_of_before("debugged: detail: Log gave the status ", status_text(status), "; the record of the read of the child: status ", hex_text(word)))
		}
	}

	for record in DEMONSTRATION_RECORDS {
		facts_expect_line(t, fact_test_render(t, disk, "disk", "Data_Region_Refused", with_values(record)), line_of_before("disk: the block service refused the data region: ", record_words(record)))
		facts_expect_line(t, fact_test_render(t, disk, "disk", "Read_Past_End_Refused", with_values(record)), line_of_before("disk: a read of 2 blocks from the last block: ", record_words(record)))
		facts_expect_line(t, fact_test_render(t, disk, "disk", "Read_Past_End_Not_Refused", with_values(record)), line_of_before("disk: a read of 2 blocks from the last block: WRONG: ", record_words(record)))
	}
	// The sentence that the main test waits for: the record of a read of 2
	// blocks from the last block of a disk of 8192 blocks.
	facts_expect_line(t, fact_test_render(t, disk, "disk", "Read_Past_End_Refused", with_values(DEMONSTRATION_RECORDS[1])), "disk: a read of 2 blocks from the last block: kind Out_Of_Range, unit Blocks, operation 3, argument 1, value 8193, limit 8192, found 0")
}

// Each fact type of errors, extended_state, guest_demo and fetch of the
// second round writes its line: the hundredths at their edges, each set of
// the instruction sets, each part measured or not, the addresses of these
// tests, and each error record of these tests with its context.
@(test)
the_facts_of_errors_extended_state_guest_demo_and_fetch_of_the_second_round_write_their_lines :: proc(t: ^testing.T) {
	errors_file, errors_ok := demonstration_file(t, "errors")
	extended, extended_ok := demonstration_file(t, "extended_state")
	guest, guest_ok := demonstration_file(t, "guest_demo")
	fetch, fetch_ok := demonstration_file(t, "fetch")
	if !errors_ok || !extended_ok || !guest_ok || !fetch_ok {
		return
	}
	for hundredths in DEMONSTRATION_HUNDREDTHS {
		facts_expect_line(t, fact_test_render(t, errors_file, "errors_process", "Families_Measured", {{"wrapper_time", u64(hundredths)}, {"root_time", u64(7)}, {"export_time", u64(hundredths)}, {"failures", u64(0)}}), line_of_before("errors: a failed call of each family: a wrapper of support (terminal.open with no terminal): ", hundredths_text(hundredths), " ns; a command of the root ring (Connect refused): ", u64(7), " ns; an export (tally.add with a note of 40 bytes, direct): ", hundredths_text(hundredths), " ns; ", u64(0), " failures"))
		for part in ([2]string{"the loop", "xsaveopt64 + vzeroupper + xrstor64"}) {
			facts_expect_line(t, fact_test_render(t, extended, "extended_state", "Save_Part_Measured", {{"cycles", u64(hundredths)}, {"part_time", u64(hundredths)}, {"part_name", part}}), line_of_before("extended_state: a part of a save and a restore, alone in this process: ", part, " ", hundredths_text(hundredths), " cycles of the cycle counter for one loop (", hundredths_text(hundredths), " ns)"))
			facts_expect_line(t, fact_test_render(t, extended, "extended_state", "Instruction_Measured", {{"cycles", u64(hundredths)}, {"part_time", u64(hundredths)}, {"part_name", part}}), line_of_before("extended_state: an instruction alone, the loop included: ", part, " ", hundredths_text(hundredths), " cycles of the cycle counter for one loop (", hundredths_text(hundredths), " ns)"))
		}
		for mark in ([2]string{"", " (WRONG)"}) {
			for check in ([2]string{"as expected", "NOT the expected one"}) {
				facts_expect_line(t, fact_test_render(t, fetch, "fetch", "Large_Page_Received", {{"received_bytes", u64(1048576)}, {"received_hash", u64(0xe7867887f2822325)}, {"rate", u64(hundredths)}, {"wrong_mark", mark}, {"hash_check", check}}), line_of_before("fetch: GET /large: ", u64(1048576), " bytes, fnv1a64 ", hex_text(0xe7867887f2822325), " ", check, ", ", hundredths_text(hundredths), " MB/s", mark))
			}
			for answer in ([2]string{"the remote got the same hash", "the remote answered another hash"}) {
				facts_expect_line(t, fact_test_render(t, fetch, "fetch", "Body_Sent", {{"rate", u64(hundredths)}, {"wrong_mark", mark}, {"hash_answer", answer}}), line_of_before("fetch: POST /sink, 1 MiB: ", answer, ", ", hundredths_text(hundredths), " MB/s", mark))
			}
		}
	}
	for count in DEMONSTRATION_COUNTS {
		other := max(u64) - count
		facts_expect_line(t, fact_test_render(t, errors_file, "errors_process", "Refusals_Measured", {{"log_refusals", count}, {"log_time", other}, {"log_control_locks", count}, {"log_frame_locks", other}, {"create_refusals", count}, {"create_time", other}, {"create_control_locks", count}, {"create_frame_locks", other}}), line_of_before("errors: ", count, " refused Log: ", other, " ns each, the control lock taken ", count, " times and the frame lock ", other, " times; ", count, " refused Memory_Create: ", other, " ns each, the control lock taken ", count, " times and the frame lock ", other, " times"))
		facts_expect_line(t, fact_test_render(t, extended, "extended_state", "Hand_Over_Measured", {{"x87_and_sse_time", count}, {"ymm_time", other}, {"x87_and_sse_hand_overs", count}, {"ymm_hand_overs", other}, {"period", count}}), line_of_before("extended_state: a hand-over between two threads by the word wait (a wake, a wait, and the save and restore of the thread that waits and of the thread that runs): ", count, " ns with x87 and SSE in use, ", other, " ns with the ymm high halves in use (0: not usable); ", count, " and ", other, " hand-overs in ", count, " ms each"))
		for word in DEMONSTRATION_WORDS {
			facts_expect_line(t, fact_test_render(t, extended, "extended_state", "Register_Wrong", {{"thread_number", count}, {"pass", other}, {"expected", word}, {"found", max(u64) - word}, {"register", "the x87 control word"}, {"moment", "start state, pass"}}), line_of_before("extended_state: WRONG: thread ", count, ", ", "the x87 control word", ", ", "start state, pass", " ", other, ": expected ", hex_text(word), ", found ", hex_text(max(u64) - word)))
			facts_expect_line(t, fact_test_render(t, guest, "guest_demo", "Halted_Elsewhere", {{"halt_address", word}, {"expected_address", other}}), line_of_before("guest_demo: failed: the guest halted at ", hex_text(word), ", not at ", hex_text(other)))
			facts_expect_line(t, fact_test_render(t, guest, "guest_demo", "Exit_Unexpected", {{"exit_kind", count}, {"exit_code", word}, {"information", other}, {"instruction_address", word}}), line_of_before("guest_demo: failed: an exit of kind ", count, ", exit code ", hex_text(word), ", information ", hex_text(other), ", at ", hex_text(word)))
			facts_expect_line(t, fact_test_render(t, guest, "guest_demo", "Debug_Exit_Wrong", {{"exit_kind", count}, {"exit_code", word}, {"expected_code", u64(0x88)}}), line_of_before("guest_demo: failed: int1 gave an exit of kind ", count, ", exit code ", hex_text(word), ", not Other with ", hex_text(0x88)))
		}
	}
	for part in ([2]string{"the loop", "vzeroupper"}) {
		facts_expect_line(t, fact_test_render(t, extended, "extended_state", "Save_Part_Not_Measured", {{"part_name", part}}), line_of_before("extended_state: a part of a save and a restore, alone in this process: ", part, " none"))
		facts_expect_line(t, fact_test_render(t, extended, "extended_state", "Instruction_Not_Measured", {{"part_name", part}}), line_of_before("extended_state: an instruction alone, the loop included: ", part, " none"))
	}
	xmm := [2]string{"SSE, SSE2, SSE3, SSSE3, SSE4.1, SSE4.2, AES, PCLMULQDQ", "none"}
	for sets in xmm {
		facts_expect_line(t, fact_test_render(t, extended, "extended_state", "Usable_Sets", {{"xmm_sets", sets}}), line_of_before("extended_state: the usable instruction sets: ", sets))
	}
	facts_expect_line(t, fact_test_render(t, extended, "extended_state", "Usable_Sets_Of_Avx", {{"avx_sets", "AVX, F16C, FMA, AVX2, AVX-512 F, AVX-512 DQ, AVX-512 CD, AVX-512 BW, AVX-512 VL"}}), "extended_state: the usable instruction sets of AVX: AVX, F16C, FMA, AVX2, AVX-512 F, AVX-512 DQ, AVX-512 CD, AVX-512 BW, AVX-512 VL")
	facts_expect_line(t, fact_test_render(t, extended, "extended_state", "Usable_Sets_Of_General_Registers", {{"general_register_sets", "POPCNT, BMI1, BMI2"}}), "extended_state: the usable instruction sets of the general registers: POPCNT, BMI1, BMI2")

	for record in DEMONSTRATION_RECORDS {
		for mark in ([2]string{"", " (WRONG)"}) {
			facts_expect_line(t, fact_test_render(t, fetch, "fetch", "Syn_To_Other_Remote_Refused", with_values(record, {"wrong_mark", mark})), line_of_before("fetch: a SYN to 10.0.2.2 port 80: refused by the network service: ", record_words(record), mark))
			facts_expect_line(t, fact_test_render(t, fetch, "fetch", "Syn_From_Other_Port_Refused", with_values(record, {"first_local_port", u64(49152)}, {"last_local_port", u64(49167)}, {"wrong_mark", mark})), line_of_before("fetch: a SYN from the local port 1234: refused: ", record_words(record), " (its ports are ", u64(49152), " to ", u64(49167), ")", mark))
		}
	}
	// The sentence that the test of TCP waits for: a SYN to a remote that
	// the grant does not name.
	refused := errors.Error_Record{kind = i64(errors.Kind.No_Grant), unit = i64(errors.Unit.Endpoint), operation = 2, argument = 3, value = errors.endpoint_pack(0x0A000202, 80), limit = errors.endpoint_pack(0x0A000264, 80)}
	facts_expect_line(t, fact_test_render(t, fetch, "fetch", "Syn_To_Other_Remote_Refused", with_values(refused, {"wrong_mark", ""})), "fetch: a SYN to 10.0.2.2 port 80: refused by the network service: kind No_Grant, unit Endpoint, operation 2, argument 3, value 10995149963344, limit 10995156385872, found 0")
}

// Each fact type of fault_ring of the second round writes its line: each
// verdict, each address of these tests, each status word, each stop cause
// and outcome in its form, and each outcome of the lost debug frame.
@(test)
the_facts_of_fault_ring_of_the_second_round_write_their_lines :: proc(t: ^testing.T) {
	file, ok := demonstration_file(t, "fault_ring")
	if !ok {
		return
	}
	render :: proc(t: ^testing.T, file: []u8, type_name: string, values: []Fact_Test_Field) -> string {
		return fact_test_render(t, file, "fault_ring", type_name, values)
	}
	name :: "a word wait, a fault, a decommit of the word"
	statuses := [2]op.Status{min(op.Status), max(op.Status)}
	for verdict in DEMONSTRATION_VERDICTS {
		for word in DEMONSTRATION_WORDS {
			other := max(u64) - word
			facts_expect_line(t, render(t, file, "Lazy_Page_Repaired", {{"written_value", word}, {"read_value", other}, {"verdict", verdict}}), line_of_before("fault_ring: a read of a page that is not committed: the handler committed it and wrote ", hex_text(word), "; the thread read ", hex_text(other), ": ", verdict))
			facts_expect_line(t, render(t, file, "Register_Written", {{"published_value", word}, {"verdict", verdict}}), line_of_before("fault_ring: a write of a register: the thread published ", hex_text(word), " from r12 after its Resume", ": ", verdict))
			for status in DEMONSTRATION_STATUS_WORDS {
				for before in ([2]string{"no second record and no run before the answer", "the thread ran or faulted again with no answer: WRONG"}) {
					facts_expect_line(t, render(t, file, "Leftover_Word_Answered", {{"woken", u64(1)}, {"read_value", word}, {"answer_status", status}, {"before_answer", before}, {"verdict", verdict}}), line_of_before("fault_ring: a word wait, a fault, a decommit of the word: the waker woke ", u64(1), " thread; ", before, "; the answer: ", status_text(status), ", the thread read ", hex_text(word), ": ", verdict))
				}
			}
			for cause in op.Stop_Cause {
				switch cause {
				case .Itself:
					for outcome in op.Stop_Outcome {
						facts_expect_line(t, render(t, file, "Child_Stopped_Itself", {{"cause", u64(cause)}, {"outcome", u64(outcome)}, {"address", word}, {"case_name", name}, {"verdict", verdict}}), line_of_before("fault_ring: ", name, ": the child stopped: ", op.STOP_CAUSE_TEXTS[cause], ", ", op.STOP_OUTCOME_TEXTS[outcome], ", the address ", hex_text(word), ": ", verdict))
						facts_expect_line(t, render(t, file, "Cases_Child_Stopped_Itself", {{"cause", u64(cause)}, {"outcome", u64(outcome)}, {"result_bits", word}, {"case_name", name}, {"verdict", verdict}}), line_of_before("fault_ring: ", name, ": the child stopped: ", op.STOP_CAUSE_TEXTS[cause], ", ", op.STOP_OUTCOME_TEXTS[outcome], ", the result bits ", hex_text(word), ": ", verdict))
					}
				case .Fault:
					facts_expect_line(t, render(t, file, "Child_Stopped_On_Fault", {{"vector", u64(14)}, {"address", word}, {"cause", u64(cause)}, {"case_name", name}, {"verdict", verdict}}), line_of_before("fault_ring: ", name, ": the child stopped: ", op.STOP_CAUSE_TEXTS[cause], ", vector ", u64(14), ", the address ", hex_text(word), ": ", verdict))
					facts_expect_line(t, render(t, file, "Cases_Child_Stopped_On_Fault", {{"vector", u64(0)}, {"result_bits", word}, {"cause", u64(cause)}, {"case_name", name}, {"verdict", verdict}}), line_of_before("fault_ring: ", name, ": the child stopped: ", op.STOP_CAUSE_TEXTS[cause], ", vector ", u64(0), ", the result bits ", hex_text(word), ": ", verdict))
				case .None, .Holder, .Last_Thread_Ended, .Handles_Closed, .Not_Committed, .Cannot_Return, .Fault_Unanswered:
					facts_expect_line(t, render(t, file, "Child_Stopped", {{"address", word}, {"cause", u64(cause)}, {"case_name", name}, {"verdict", verdict}}), line_of_before("fault_ring: ", name, ": the child stopped: ", op.STOP_CAUSE_TEXTS[cause], ", the address ", hex_text(word), ": ", verdict))
					facts_expect_line(t, render(t, file, "Cases_Child_Stopped", {{"result_bits", word}, {"cause", u64(cause)}, {"case_name", name}, {"verdict", verdict}}), line_of_before("fault_ring: ", name, ": the child stopped: ", op.STOP_CAUSE_TEXTS[cause], ", the result bits ", hex_text(word), ": ", verdict))
				}
			}
		}
		for status in statuses {
			for answer in ([2]string{"Ok", "an error"}) {
				facts_expect_line(t, render(t, file, "Thread_Handle_Rights", {{"control_stop", u64(status)}, {"control_read", u64(status)}, {"control_write", u64(status)}, {"inspect_write", u64(status)}, {"write_only", u64(status)}, {"inspect_answer", answer}, {"verdict", verdict}}), line_of_before("fault_ring: the rights of a thread handle: with Read and Control, Stop got ", op.STATUS_NAMES[status], ", Read_Registers ", op.STATUS_NAMES[status], ", Write_Registers ", op.STATUS_NAMES[status], "; with Inspect only, Stop, Read_Registers and Resume got ", answer, ", Write_Registers ", op.STATUS_NAMES[status], "; with Write only, Write_Registers got ", op.STATUS_NAMES[status], "; the thread kept running", ": ", verdict))
			}
		}
		Outcome_Line :: struct {
			type_name: string,
			outcome:   string,
		}
		outcomes := [3]Outcome_Line{{"Lost_Frame_Records_In_Code", "the int1 and the trap came to the process as debug records in its code"}, {"Lost_Frame_Stopped_By_Kernel", "the trap came at the stub of int1, and the kernel stopped the child as a fault of a debug exception with the instruction address 0"}, {"Lost_Frame_Neither", "neither outcome"}}
		for item in outcomes {
			facts_expect_line(t, render(t, file, item.type_name, {{"verdict", verdict}}), line_of_before("fault_ring: mov ss, then int1, with the trap flag: the machine went on and the child gave back every page and every thread; on this processor ", item.outcome, ": ", verdict))
		}
	}
	for status in DEMONSTRATION_STATUS_WORDS {
		for count in DEMONSTRATION_COUNTS {
			facts_expect_line(t, render(t, file, "Child_Start_Failed", {{"start_status", status}, {"load_stage", count}, {"load_status", status}, {"file_error", count}, {"pages", count}, {"processes", count}, {"threads", count}, {"child_pages", u64(4096)}, {"child_threads", u64(3)}, {"case_name", name}}), line_of_before("fault_ring: ", name, ": process_start failed: ", status_text(status), "; the load: stage ", count, ", status ", status_text(status), ", the error of the file ", count, "; this process can give pages ", count, ", processes ", count, ", threads ", count, ", and the child asks ", u64(4096), ", 1, ", u64(3)))
		}
	}
}
