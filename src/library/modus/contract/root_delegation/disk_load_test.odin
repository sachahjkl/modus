#+build !freestanding
#+build !modus
package root_delegation

import "core:testing"
import "modus:contract/blake3"

@(private = "file")
hash_of_tag :: proc(tag: u8) -> (hash: blake3.Hash) {
	hash[0] = tag
	hash[31] = tag ~ 0x5A
	return hash
}

@(private = "file")
valid_load_request :: proc() -> (request: Load_Request) {
	request.kind = u8(Load_Kind.Module)
	request.principal = 1
	request.module_hash = hash_of_tag(1)
	request.nickname_length = u8(copy(request.nickname[:], "visitor"))
	request.storage_module_length = u8(copy(request.storage_module[:], "storage"))
	return request
}

// A word of a command or of an event that names no member, and zero, are
// refused; each member is read back.
@(test)
the_words_of_the_ring_refuse_zero_and_each_word_past_the_members :: proc(t: ^testing.T) {
	for word in ([?]u32{0, u32(max(Disk_Load_Command)) + 1, 0xFFFF, max(u32)}) {
		_, ok := disk_load_command_of_word(word)
		testing.expectf(t, !ok, "the command word %d is taken", word)
	}
	for word in ([?]u32{0, u32(max(Disk_Load_Event)) + 1, 0xFFFF, max(u32)}) {
		_, ok := disk_load_event_of_word(word)
		testing.expectf(t, !ok, "the event word %d is taken", word)
	}
	for command in Disk_Load_Command {
		read, ok := disk_load_command_of_word(u32(command))
		testing.expect_value(t, ok, command != .None)
		if ok {
			testing.expect_value(t, read, command)
		}
	}
	for event in Disk_Load_Event {
		read, ok := disk_load_event_of_word(u32(event))
		testing.expect_value(t, ok, event != .None)
		if ok {
			testing.expect_value(t, read, event)
		}
	}
}

// A request with no nickname, a nickname past its capacity, a byte after
// the nickname, no storage module, no hash, or more replacements than the
// table holds is refused; the edges of each bound are taken.
@(test)
a_load_request_refuses_each_field_out_of_its_bounds :: proc(t: ^testing.T) {
	request := valid_load_request()
	request.nickname_length = 0
	_, _, _, ok := load_request_check(&request)
	testing.expect(t, !ok)

	request = valid_load_request()
	request.nickname_length = NICKNAME_CAPACITY + 1
	_, _, _, ok = load_request_check(&request)
	testing.expect(t, !ok)

	request = valid_load_request()
	request.nickname_length = max(u8)
	_, _, _, ok = load_request_check(&request)
	testing.expect(t, !ok)

	request = valid_load_request()
	request.nickname[NICKNAME_CAPACITY - 1] = 'x'
	_, _, _, ok = load_request_check(&request)
	testing.expect(t, !ok)

	request = valid_load_request()
	request.storage_module_length = 0
	_, _, _, ok = load_request_check(&request)
	testing.expect(t, !ok)

	request = valid_load_request()
	request.module_hash = {}
	_, _, _, ok = load_request_check(&request)
	testing.expect(t, !ok)

	for count in ([?]u32{LOAD_REPLACEMENT_CAPACITY + 1, max(u32)}) {
		request = valid_load_request()
		request.replacement_count = count
		_, _, _, ok = load_request_check(&request)
		testing.expectf(t, !ok, "%d replacements are taken", count)
	}

	request = valid_load_request()
	request.replacement_count = LOAD_REPLACEMENT_CAPACITY
	request.nickname_length = NICKNAME_CAPACITY
	for index in 0 ..< NICKNAME_CAPACITY {
		request.nickname[index] = 'n'
	}
	_, nickname, storage_module, taken := load_request_check(&request)
	testing.expect(t, taken)
	testing.expect_value(t, len(nickname), NICKNAME_CAPACITY)
	testing.expect_value(t, storage_module, "storage")
}

// Each event is taken at its step only: an event at another step is
// refused, and no event is taken when no load runs.
@(test)
each_event_is_taken_at_its_step_only :: proc(t: ^testing.T) {
	takes := [Disk_Load_Event]bit_set[Disk_Load_Step] {
		.None              = {},
		.Memory_Wanted     = {}, // Checked with its place below.
		.Module_Filled     = {.Module_Lent},
		.Scan_Started      = {.Module_Checked},
		.Import_Found      = {.Candidate_Lent},
		.Candidate_Dropped = {.Candidate_Lent},
		.Ready             = {.Module_Checked, .Scan},
		.Refused           = {}, // Checked with its refusal below.
		.Command_Refused   = {.Module_Asked, .Module_Lent, .Module_Checked, .Scan, .Candidate_Lent},
		.Cancelled         = {},
	}
	for event in Disk_Load_Event {
		if event == .Memory_Wanted || event == .Refused {
			continue
		}
		for step in Disk_Load_Step {
			report := Event_Report{import_count = 1, file_name_length = 1}
			report.file_name[0] = 'f'
			testing.expectf(t, event_report_check(.Module, step, event, &report, 0, 0) == (step in takes[event]), "the event %v at the step %v", event, step)
		}
	}
	for step in Disk_Load_Step {
		module_report := Event_Report{place = u32(File_Place.Module), byte_count = 1}
		testing.expect_value(t, event_report_check(.Module, step, .Memory_Wanted, &module_report, 0, 0), step == .Module_Asked)
		candidate_report := Event_Report{place = u32(File_Place.Candidate), byte_count = 1, file_name_length = 1}
		candidate_report.file_name[0] = 'f'
		testing.expect_value(t, event_report_check(.Module, step, .Memory_Wanted, &candidate_report, 0, 0), step == .Scan)
	}
}

// A Memory_Wanted with no place, a place that names no member, no byte,
// more bytes than a module file has, or a candidate past the kept files
// is refused; the edges of the size are taken.
@(test)
a_memory_wanted_refuses_each_size_and_place_out_of_its_bounds :: proc(t: ^testing.T) {
	for place in ([?]u32{u32(File_Place.None), u32(max(File_Place)) + 1, max(u32)}) {
		report := Event_Report{place = place, byte_count = 1}
		testing.expectf(t, !event_report_check(.Module, .Module_Asked, .Memory_Wanted, &report, 0, 0), "the place %d is taken", place)
	}
	for size in ([?]u64{0, MODULE_BYTES_LIMIT + 1, max(u64)}) {
		report := Event_Report{place = u32(File_Place.Module), byte_count = size}
		testing.expectf(t, !event_report_check(.Module, .Module_Asked, .Memory_Wanted, &report, 0, 0), "%d bytes are taken", size)
	}
	candidate := Event_Report{place = u32(File_Place.Candidate), byte_count = 1, file_name_length = 1}
	candidate.file_name[0] = 'f'
	unnamed := candidate
	unnamed.file_name_length = 0
	testing.expect(t, !event_report_check(.Module, .Scan, .Memory_Wanted, &unnamed, 0, 0))
	testing.expect(t, !event_report_check(.Module, .Scan, .Memory_Wanted, &candidate, LOAD_IMPORT_CAPACITY, 0))
	testing.expect(t, !event_report_check(.Module, .Scan, .Memory_Wanted, &candidate, max(int), 0))
	testing.expect(t, event_report_check(.Module, .Scan, .Memory_Wanted, &candidate, LOAD_IMPORT_CAPACITY - 1, 0))
	// The loans of the scan are bounded: the last one is taken, one more is
	// refused, whatever the kept files.
	testing.expect(t, event_report_check(.Module, .Scan, .Memory_Wanted, &candidate, 0, LOAD_CANDIDATE_LOAN_LIMIT - 1))
	for loans in ([?]int{LOAD_CANDIDATE_LOAN_LIMIT, LOAD_CANDIDATE_LOAN_LIMIT + 1, max(int)}) {
		testing.expectf(t, !event_report_check(.Module, .Scan, .Memory_Wanted, &candidate, 0, loans), "the loan %d is taken", loans)
	}
	for size in ([?]u64{1, MODULE_BYTES_LIMIT}) {
		report := Event_Report{place = u32(File_Place.Module), byte_count = size}
		testing.expectf(t, event_report_check(.Module, .Module_Asked, .Memory_Wanted, &report, 0, 0), "%d bytes are refused", size)
	}
}

// A Scan_Started with no import or more imports than one load keeps, and
// an Import_Found with no file name, a name past its field, a byte after
// a name, or past the kept files, are refused.
@(test)
the_events_of_the_scan_refuse_each_count_and_name_out_of_its_bounds :: proc(t: ^testing.T) {
	for count in ([?]u64{0, LOAD_IMPORT_CAPACITY + 1, max(u64)}) {
		report := Event_Report{import_count = count}
		testing.expectf(t, !event_report_check(.Module, .Module_Checked, .Scan_Started, &report, 0, 0), "%d imports are taken", count)
	}
	for count in ([?]u64{1, LOAD_IMPORT_CAPACITY}) {
		report := Event_Report{import_count = count}
		testing.expect(t, event_report_check(.Module, .Module_Checked, .Scan_Started, &report, 0, 0))
	}

	found := Event_Report{file_name_length = 1}
	found.file_name[0] = 'f'
	testing.expect(t, event_report_check(.Module, .Candidate_Lent, .Import_Found, &found, 0, 0))
	testing.expect(t, !event_report_check(.Module, .Candidate_Lent, .Import_Found, &found, LOAD_IMPORT_CAPACITY, 0))

	no_name := found
	no_name.file_name_length = 0
	testing.expect(t, !event_report_check(.Module, .Candidate_Lent, .Import_Found, &no_name, 0, 0))
	for length in ([?]u32{LOAD_FILE_NAME_CAPACITY + 1, max(u32)}) {
		long := found
		long.file_name_length = length
		testing.expectf(t, !event_report_check(.Module, .Candidate_Lent, .Import_Found, &long, 0, 0), "a file name of %d bytes is taken", length)
		long_importer := found
		long_importer.importer_name_length = length
		testing.expectf(t, !event_report_check(.Module, .Candidate_Lent, .Import_Found, &long_importer, 0, 0), "an importer name of %d bytes is taken", length)
	}
	trailing := found
	trailing.file_name[LOAD_FILE_NAME_CAPACITY - 1] = 'x'
	testing.expect(t, !event_report_check(.Module, .Candidate_Lent, .Import_Found, &trailing, 0, 0))
	trailing_importer := found
	trailing_importer.importer_name[0] = 'x'
	testing.expect(t, !event_report_check(.Module, .Candidate_Lent, .Import_Found, &trailing_importer, 0, 0))

	whole := found
	whole.file_name_length = LOAD_FILE_NAME_CAPACITY
	whole.importer_name_length = LOAD_FILE_NAME_CAPACITY
	for index in 0 ..< LOAD_FILE_NAME_CAPACITY {
		whole.file_name[index] = 'f'
		whole.importer_name[index] = 'i'
	}
	testing.expect(t, event_report_check(.Module, .Candidate_Lent, .Import_Found, &whole, LOAD_IMPORT_CAPACITY - 1, 0))
}

// A refusal that names no member, the member None, a flag past 1, a
// refusal at a step where it cannot come, or a missing import with no hash
// is refused; each refusal is taken at its own step.
@(test)
a_refused_event_names_a_refusal_of_its_step :: proc(t: ^testing.T) {
	for word in ([?]u32{u32(Disk_Load_Refusal.None), u32(max(Disk_Load_Refusal)) + 1, max(u32)}) {
		report := Event_Report{refusal = word}
		for step in Disk_Load_Step {
			testing.expectf(t, !event_report_check(.Module, step, .Refused, &report, 0, 0), "the refusal word %d is taken at %v", word, step)
		}
	}
	module_report := Event_Report{refusal = u32(Disk_Load_Refusal.Object_Empty)}
	testing.expect(t, event_report_check(.Module, .Module_Asked, .Refused, &module_report, 0, 0))
	for step in ([?]Disk_Load_Step{.Idle, .Module_Lent, .Module_Checked, .Scan, .Candidate_Lent}) {
		testing.expectf(t, !event_report_check(.Module, step, .Refused, &module_report, 0, 0), "Object_Empty is taken at %v", step)
	}
	bounds := Event_Report{refusal = u32(Disk_Load_Refusal.Import_Bounds)}
	for step in Disk_Load_Step {
		testing.expect_value(t, event_report_check(.Module, step, .Refused, &bounds, 0, 0), step == .Module_Checked || step == .Scan)
	}
	flagged := module_report
	flagged.damaged = 2
	testing.expect(t, !event_report_check(.Module, .Module_Asked, .Refused, &flagged, 0, 0))
	flagged = module_report
	flagged.entries_left_out = max(u32)
	testing.expect(t, !event_report_check(.Module, .Module_Asked, .Refused, &flagged, 0, 0))

	missing := Event_Report{refusal = u32(Disk_Load_Refusal.Import_Missing)}
	testing.expect(t, !event_report_check(.Module, .Scan, .Refused, &missing, 0, 0))
	missing.hash = hash_of_tag(9)
	testing.expect(t, event_report_check(.Module, .Scan, .Refused, &missing, 0, 0))
	testing.expect(t, !event_report_check(.Module, .Candidate_Lent, .Refused, &missing, 0, 0))

	bytes := Event_Report{refusal = u32(Disk_Load_Refusal.Import_No_Byte_At)}
	testing.expect(t, !event_report_check(.Module, .Candidate_Lent, .Refused, &bytes, 0, 0))
	bytes.file_name_length = 1
	bytes.file_name[0] = 'f'
	testing.expect(t, event_report_check(.Module, .Candidate_Lent, .Refused, &bytes, 0, 0))

	storage := Event_Report{refusal = u32(Disk_Load_Refusal.Storage_Stopped)}
	for step in Disk_Load_Step {
		testing.expect_value(t, event_report_check(.Module, step, .Refused, &storage, 0, 0), step != .Idle)
	}
}

// The start from bytes names what the core knows, and nothing else: each
// field that differs is refused, and the request of the load is taken.
@(test)
a_start_from_bytes_names_the_load_of_the_core :: proc(t: ^testing.T) {
	kept := [2]blake3.Hash{hash_of_tag(2), hash_of_tag(3)}
	valid :: proc(kept: []blake3.Hash) -> (request: Start_From_Bytes_Request) {
		request.principal = 1
		request.module_hash = hash_of_tag(1)
		request.module_byte_count = 4096
		request.nickname_length = u8(copy(request.nickname[:], "visitor"))
		request.import_count = u32(len(kept))
		copy(request.import_hashes[:], kept)
		return request
	}
	check :: proc(request: ^Start_From_Bytes_Request, kept: []blake3.Hash) -> Start_From_Bytes_Refusal {
		return start_from_bytes_check(request, 1, "visitor", hash_of_tag(1), 4096, kept)
	}

	request := valid(kept[:])
	request.principal = 0
	testing.expect_value(t, check(&request, kept[:]), Start_From_Bytes_Refusal.Other_Principal)

	request = valid(kept[:])
	request.nickname_length = u8(copy(request.nickname[:], "visitos"))
	testing.expect_value(t, check(&request, kept[:]), Start_From_Bytes_Refusal.Other_Nickname)

	request = valid(kept[:])
	request.nickname[NICKNAME_CAPACITY - 1] = 'x'
	testing.expect_value(t, check(&request, kept[:]), Start_From_Bytes_Refusal.Trailing_Nickname_Bytes)

	request = valid(kept[:])
	request.nickname_length = 0
	testing.expect_value(t, check(&request, kept[:]), Start_From_Bytes_Refusal.Trailing_Nickname_Bytes)

	request = valid(kept[:])
	request.module_hash = hash_of_tag(4)
	testing.expect_value(t, check(&request, kept[:]), Start_From_Bytes_Refusal.Other_Module_Hash)

	for count in ([?]u64{0, 4095, 4097, max(u64)}) {
		request = valid(kept[:])
		request.module_byte_count = count
		testing.expect_value(t, check(&request, kept[:]), Start_From_Bytes_Refusal.Other_Byte_Count)
	}

	for count in ([?]u32{LOAD_IMPORT_CAPACITY + 1, max(u32)}) {
		request = valid(kept[:])
		request.import_count = count
		testing.expect_value(t, check(&request, kept[:]), Start_From_Bytes_Refusal.Too_Many_Imports)
	}

	for count in ([?]u32{0, 1, 3}) {
		request = valid(kept[:])
		request.import_count = count
		testing.expect_value(t, check(&request, kept[:]), Start_From_Bytes_Refusal.Other_Import_Count)
	}

	request = valid(kept[:])
	request.import_hashes[0], request.import_hashes[1] = request.import_hashes[1], request.import_hashes[0]
	testing.expect_value(t, check(&request, kept[:]), Start_From_Bytes_Refusal.Other_Import_Hash)

	request = valid(kept[:])
	request.import_hashes[LOAD_IMPORT_CAPACITY - 1] = hash_of_tag(7)
	testing.expect_value(t, check(&request, kept[:]), Start_From_Bytes_Refusal.Other_Import_Hash)

	request = valid(kept[:])
	testing.expect_value(t, check(&request, kept[:]), Start_From_Bytes_Refusal.None)
	request = valid(nil)
	testing.expect_value(t, check(&request, nil), Start_From_Bytes_Refusal.None)
}

// A step where each refusal can come, for the test of its names.
@(private = "file")
step_of_refusal :: proc(refusal: Disk_Load_Refusal) -> Disk_Load_Step {
	switch refusal {
	case .None, .Not_Mapped, .No_Object, .Object_Empty, .Object_Too_Large, .Call_Not_Taken, .Storage_Stopped, .Read_Refused, .Answer_Not_Allowed:
		return .Module_Asked
	case .No_Byte_At, .Too_Many_Bytes:
		return .Module_Lent
	case .Import_Bounds, .Import_Entry_Name_Outside, .Import_Entry_Kind_Unknown, .Import_Missing:
		return .Scan
	case .Import_No_Byte_At, .Import_Too_Many_Bytes:
		return .Candidate_Lent
	}
	return .Idle
}

// For each refusal, at the step where it can come, a file name or an
// importer name past its field is refused, and so is a byte after a name:
// the core never reads a name that its field does not hold. The same
// report with names at their edges is taken.
@(test)
each_refusal_bounds_both_of_its_names :: proc(t: ^testing.T) {
	for refusal in Disk_Load_Refusal {
		if refusal == .None {
			continue
		}
		step := step_of_refusal(refusal)
		valid := Event_Report{refusal = u32(refusal), hash = hash_of_tag(4), file_name_length = 1, importer_name_length = LOAD_FILE_NAME_CAPACITY}
		valid.file_name[0] = 'f'
		for index in 0 ..< LOAD_FILE_NAME_CAPACITY {
			valid.importer_name[index] = 'i'
		}
		testing.expectf(t, event_report_check(.Module, step, .Refused, &valid, 0, 0), "the refusal %v with valid names is refused", refusal)
		for length in ([?]u32{LOAD_FILE_NAME_CAPACITY + 1, max(u32)}) {
			long_file := valid
			long_file.file_name_length = length
			testing.expectf(t, !event_report_check(.Module, step, .Refused, &long_file, 0, 0), "the refusal %v takes a file name of %d bytes", refusal, length)
			long_importer := valid
			long_importer.importer_name_length = length
			testing.expectf(t, !event_report_check(.Module, step, .Refused, &long_importer, 0, 0), "the refusal %v takes an importer name of %d bytes", refusal, length)
		}
		trailing := valid
		trailing.file_name[LOAD_FILE_NAME_CAPACITY - 1] = 'x'
		testing.expectf(t, !event_report_check(.Module, step, .Refused, &trailing, 0, 0), "the refusal %v takes a byte after the file name", refusal)
	}
}
// The kind of a load: None, and each word past the members, are refused at
// the border of the request. A load of the script font set takes a file up
// to its own limit, and a module file no more than its limit; it never
// takes an entry of a scan.
@(test)
the_kind_of_a_load_bounds_its_file :: proc(t: ^testing.T) {
	for word in ([?]u8{0, u8(max(Load_Kind)) + 1, 0x7F, max(u8)}) {
		request := valid_load_request()
		request.kind = word
		_, _, _, ok := load_request_check(&request)
		testing.expectf(t, !ok, "the kind word %d is taken", word)
	}
	request := valid_load_request()
	request.kind = u8(Load_Kind.Script_Fonts)
	kind, _, _, ok := load_request_check(&request)
	testing.expect(t, ok && kind == .Script_Fonts)
	testing.expect_value(t, load_bytes_limit(.None), u64(0))
	Edge :: struct {
		kind:  Load_Kind,
		bytes: u64,
		taken: bool,
	}
	edges := [?]Edge {
		{.Module, MODULE_BYTES_LIMIT, true},
		{.Module, MODULE_BYTES_LIMIT + 1, false},
		{.Script_Fonts, load_bytes_limit(.Script_Fonts), true},
		{.Script_Fonts, load_bytes_limit(.Script_Fonts) + 1, false},
		{.Script_Fonts, max(u64), false},
		{.Script_Fonts, 0, false},
		{.None, 1, false},
	}
	for edge in edges {
		report := Event_Report{place = u32(File_Place.Module), byte_count = edge.bytes}
		testing.expectf(t, event_report_check(edge.kind, .Module_Asked, .Memory_Wanted, &report, 0, 0) == edge.taken, "%v: a file of %d bytes", edge.kind, edge.bytes)
	}
	candidate := Event_Report{place = u32(File_Place.Candidate), byte_count = 1}
	candidate.file_name_length = u32(copy(candidate.file_name[:], "entry"))
	testing.expect(t, !event_report_check(.Script_Fonts, .Scan, .Memory_Wanted, &candidate, 0, 0))
	testing.expect(t, event_report_check(.Module, .Scan, .Memory_Wanted, &candidate, 0, 0))
}
