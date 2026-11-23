#+build !freestanding
package display_conformance

import "core:testing"
import "modus:contract/draw_record"
import "modus:contract/module"
import "modus:contract/module_file_writer"
import "modus:contract/role_contract"
import "modus:contract/scale_factor"

// Fault injection flags for adversarial mock Display holders so each
// conformance case is proven to catch real non-compliance.
Mock_Fault :: enum {
	Accept_Invalid_Surface_Size,
	Allow_Unprivileged_Inspection,
	Accept_Invalid_Present_Picture,
	Accept_Cross_Client_Serial,
	Accept_Invalid_Draw_Record,
	Leak_Key_To_Unfocused_Client,
	Corrupt_Other_Client_On_Close,
}
Mock_Faults :: bit_set[Mock_Fault]

Mock_Client :: struct {
	open:                 bool,
	client_id:            u32,
	has_surface:          bool,
	width:                u32,
	height:               u32,
	surface_serial:       u64,
	last_picture:         u64,
	presents:             u64,
	presents_refused:     u64,
	pictures_drawn_again: u64,
	frames:               u64,
}

Mock_Display :: struct {
	faults:         Mock_Faults,
	clients:        [8]Mock_Client,
	focus_order:    [8]u32,
	focus_count:    int,
	total_frames:   u64,
	total_presents: u64,
}

@(private = "file")
mock_find :: proc "contextless" (mock: ^Mock_Display, client_id: u32) -> ^Mock_Client {
	for &c in mock.clients {
		if c.open && c.client_id == client_id {
			return &c
		}
	}
	return nil
}

@(private = "file")
mock_client_open :: proc "contextless" (state: rawptr, client_id: u32) -> bool {
	mock := (^Mock_Display)(state)
	if client_id == 0 || mock_find(mock, client_id) != nil {
		return false
	}
	for &c in mock.clients {
		if !c.open {
			c = {open = true, client_id = client_id}
			return true
		}
	}
	return false
}

@(private = "file")
mock_client_close :: proc "contextless" (state: rawptr, client_id: u32) -> bool {
	mock := (^Mock_Display)(state)
	client := mock_find(mock, client_id)
	if client == nil {
		return false
	}
	client^ = {}
	write := 0
	for index in 0 ..< mock.focus_count {
		if mock.focus_order[index] != client_id {
			mock.focus_order[write] = mock.focus_order[index]
			write += 1
		}
	}
	mock.focus_count = write
	if .Corrupt_Other_Client_On_Close in mock.faults {
		for &other in mock.clients {
			if other.open {
				other.has_surface = false
			}
		}
	}
	return true
}

@(private = "file")
mock_surface_create :: proc "contextless" (state: rawptr, client_id: u32, request: Surface_Create_Request) -> Surface_Outcome {
	mock := (^Mock_Display)(state)
	client := mock_find(mock, client_id)
	if client == nil {
		return .Refused_Client
	}
	if request.memory_handle == 0 {
		return .Refused_Handle
	}
	if .Accept_Invalid_Surface_Size not_in mock.faults {
		if request.width == 0 || request.height == 0 || request.width > role_contract.DISPLAY_SURFACE_LIMIT || request.height > role_contract.DISPLAY_SURFACE_LIMIT {
			return .Refused_Size
		}
	}
	if _, scale_problem := scale_factor.scale_of_word(request.scale_word); scale_problem != .None {
		return .Refused_Scale
	}
	if request.serial == 0 {
		return .Refused_Serial
	}
	client.has_surface = true
	client.width = request.width
	client.height = request.height
	client.surface_serial = request.serial
	client.presents = 0
	client.presents_refused = 0
	client.pictures_drawn_again = 0
	client.frames = 0
	// Place newly created window at the front of the focus stack.
	write := 0
	for index in 0 ..< mock.focus_count {
		if mock.focus_order[index] != client_id {
			mock.focus_order[write] = mock.focus_order[index]
			write += 1
		}
	}
	mock.focus_order[write] = client_id
	mock.focus_count = write + 1
	return .Accepted
}

@(private = "file")
mock_present :: proc "contextless" (state: rawptr, client_id: u32, request: Present_Request) -> Present_Outcome {
	mock := (^Mock_Display)(state)
	client := mock_find(mock, client_id)
	if client == nil {
		return .Refused_Client
	}
	if !client.has_surface {
		client.presents_refused += 1
		return .Refused_No_Surface
	}
	if .Accept_Invalid_Present_Picture not_in mock.faults {
		if request.picture_index >= u64(role_contract.DISPLAY_PICTURE_COUNT) {
			client.presents_refused += 1
			return .Refused_Picture
		}
	}
	serial_matches := request.surface_serial == client.surface_serial
	if !serial_matches && .Accept_Cross_Client_Serial in mock.faults {
		for &other in mock.clients {
			if other.open && other.has_surface && other.surface_serial == request.surface_serial {
				serial_matches = true
				break
			}
		}
	}
	if !serial_matches {
		client.presents_refused += 1
		return .Refused_Serial
	}
	if client.presents > 0 && request.picture_index == client.last_picture {
		client.pictures_drawn_again += 1
	}
	client.last_picture = request.picture_index
	client.presents += 1
	client.frames += 1
	mock.total_presents += 1
	mock.total_frames += 1
	return .Accepted
}

@(private = "file")
mock_draw_validate :: proc "contextless" (state: rawptr, client_id: u32, record: draw_record.Draw_Record) -> draw_record.Problem {
	mock := (^Mock_Display)(state)
	_ = client_id
	if .Accept_Invalid_Draw_Record in mock.faults {
		return .None
	}
	_, problem := draw_record.read(record)
	return problem
}

@(private = "file")
mock_window_list :: proc "contextless" (state: rawptr, caller_acts_for_principal: bool, out: []Window_Snapshot) -> (count: int, authorized: bool) {
	mock := (^Mock_Display)(state)
	if !caller_acts_for_principal && .Allow_Unprivileged_Inspection not_in mock.faults {
		return 0, false
	}
	for index := mock.focus_count - 1; index >= 0; index -= 1 {
		client := mock_find(mock, mock.focus_order[index])
		if client == nil || !client.has_surface {
			continue
		}
		if count < len(out) {
			out[count] = {
				client_id            = client.client_id,
				width                = client.width,
				height               = client.height,
				focus                = count == 0,
				presents             = client.presents,
				presents_refused     = client.presents_refused,
				pictures_drawn_again = client.pictures_drawn_again,
				frames               = client.frames,
			}
		}
		count += 1
	}
	return count, true
}

@(private = "file")
mock_screen_read :: proc "contextless" (state: rawptr, caller_acts_for_principal: bool) -> (snapshot: Screen_Snapshot, authorized: bool) {
	mock := (^Mock_Display)(state)
	if !caller_acts_for_principal && .Allow_Unprivileged_Inspection not_in mock.faults {
		return {}, false
	}
	return {frames = mock.total_frames, presents = mock.total_presents}, true
}

@(private = "file")
mock_deliver_key :: proc "contextless" (state: rawptr, key_code: u32, serial: u64) -> (delivered_client_id: u32, ok: bool) {
	mock := (^Mock_Display)(state)
	_ = key_code
	_ = serial
	if mock.focus_count == 0 {
		return 0, false
	}
	if .Leak_Key_To_Unfocused_Client in mock.faults && mock.focus_count > 1 {
		return mock.focus_order[0], true
	}
	return mock.focus_order[mock.focus_count - 1], true
}

@(private = "file")
build_mock_display_module :: proc(t: ^testing.T, omit_screen: bool = false) -> []u8 {
	code := [16]u8{0 = 0xC3}
	segments := [1]module_file_writer.Segment_Part {
		{memory_offset = 0, memory_size = module.PAGE_SIZE, flags = {.Read, .Execute}, data = code[:]},
	}
	display_parts: role_contract.Display_Module_Parts
	role_contract.display_module_parts_write(&display_parts)
	if omit_screen {
		// The export of another name: the indexes of the getters stay.
		display_parts.exports[2].name = "screen_elsewhere"
	}
	parts := module_file_writer.Module_Parts{segments = segments[:], exports = display_parts.exports[:], records = display_parts.records[:], enums = display_parts.enums[:], parameter_settings = display_parts.set_ranges[:]}
	needed, sr := module_file_writer.file_size_needed(parts)
	testing.expect_value(t, sr.refusal, module_file_writer.Refusal.None)
	buf := make([]u8, int(needed), context.temp_allocator)
	_, wr := module_file_writer.write(parts, buf)
	testing.expect_value(t, wr.refusal, module_file_writer.Refusal.None)
	return buf
}

@(private = "file")
make_holder :: proc(mock: ^Mock_Display, module_bytes: []u8, hashes: []role_contract.Contract_Hash) -> Display_Holder_Interface {
	return {
		state          = mock,
		module_bytes   = module_bytes,
		declaration    = {contract_hashes = hashes, ring_faces = role_contract.display_ring_faces()},
		client_open    = mock_client_open,
		client_close   = mock_client_close,
		surface_create = mock_surface_create,
		present        = mock_present,
		draw_validate  = mock_draw_validate,
		window_list    = mock_window_list,
		screen_read    = mock_screen_read,
		deliver_key    = mock_deliver_key,
	}
}

@(test)
compliant_display_holder_passes_entire_conformance_suite :: proc(t: ^testing.T) {
	mock: Mock_Display
	mod_bytes := build_mock_display_module(t)
	hashes := [1]role_contract.Contract_Hash{role_contract.display_contract_hash()}
	holder := make_holder(&mock, mod_bytes, hashes[:])

	report := run_display_conformance(&holder)
	testing.expect(t, report.all_passed, "compliant Display holder must pass all conformance cases")
	testing.expect_value(t, report.passed_count, CONFORMANCE_CASE_COUNT)
	testing.expect_value(t, report.failed_count, 0)
	testing.expect_value(t, display_contract_version(), i64(role_contract.DISPLAY_CONTRACT_VERSION))
}

@(test)
conformance_suite_catches_contract_tampering_and_missing_exports :: proc(t: ^testing.T) {
	// Tampered hash fails Contract_Check.
	mock_tampered: Mock_Display
	mod_bytes := build_mock_display_module(t)
	bad_hash := role_contract.display_contract_hash()
	bad_hash[3] ~= 0x01
	bad_hashes := [1]role_contract.Contract_Hash{bad_hash}
	holder_tampered := make_holder(&mock_tampered, mod_bytes, bad_hashes[:])
	report := run_display_conformance(&holder_tampered)
	testing.expect(t, !report.all_passed)
	testing.expect_value(t, report.results[.Contract_Check].failure, Conformance_Failure.Contract_Refused)

	// Missing required export ("screen") fails Contract_Check.
	mock_missing: Mock_Display
	incomplete_mod := build_mock_display_module(t, omit_screen = true)
	good_hashes := [1]role_contract.Contract_Hash{role_contract.display_contract_hash()}
	holder_missing := make_holder(&mock_missing, incomplete_mod, good_hashes[:])
	report = run_display_conformance(&holder_missing)
	testing.expect(t, !report.all_passed)
	testing.expect_value(t, report.results[.Contract_Check].failure, Conformance_Failure.Contract_Refused)
}

@(test)
conformance_suite_catches_every_behavioral_non_compliance :: proc(t: ^testing.T) {
	mod_bytes := build_mock_display_module(t)
	hashes := [1]role_contract.Contract_Hash{role_contract.display_contract_hash()}

	Fault_Expectation :: struct {
		fault:         Mock_Fault,
		expected_case: Conformance_Case,
		expected_fail: Conformance_Failure,
	}
	expectations := [?]Fault_Expectation {
		{.Accept_Invalid_Surface_Size, .Surface_Lifecycle, .Invalid_Surface_Accepted},
		{.Allow_Unprivileged_Inspection, .Surface_Lifecycle, .Unprivileged_Inspection_Allowed},
		{.Accept_Invalid_Present_Picture, .Present_And_Frame, .Invalid_Present_Accepted},
		{.Accept_Invalid_Draw_Record, .Invalid_Record_Refusal, .Invalid_Draw_Record_Accepted},
		{.Accept_Cross_Client_Serial, .Two_Client_Isolation, .Cross_Client_State_Corrupted},
		{.Leak_Key_To_Unfocused_Client, .Two_Client_Isolation, .Key_Delivered_To_Unfocused_Client},
		{.Corrupt_Other_Client_On_Close, .Two_Client_Isolation, .Cross_Client_State_Corrupted},
	}

	for item in expectations {
		mock := Mock_Display{faults = {item.fault}}
		holder := make_holder(&mock, mod_bytes, hashes[:])
		report := run_display_conformance(&holder)
		testing.expectf(t, !report.all_passed, "fault %v must fail conformance", item.fault)
		testing.expectf(
			t,
			!report.results[item.expected_case].passed && report.results[item.expected_case].failure == item.expected_fail,
			"fault %v: expected case %v failure %v, got %v",
			item.fault,
			item.expected_case,
			item.expected_fail,
			report.results[item.expected_case].failure,
		)
	}
}
