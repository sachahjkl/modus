// Display role conformance suite (src/md/features/roles_and_contracts.md).
//
// Tests any holder of Role.Display strictly against the Display role contract
// and contract-level invariants: contract hash and metadata check, surface
// lifecycle, present and frame validation, invalid draw and surface record
// refusal, and two-client isolation. It never names a specific holder module
// and imports contract packages only.
package display_conformance

import "modus:contract/draw_record"
import "modus:contract/role_contract"
import "modus:contract/scale_factor"

// Closed set of conformance cases run against a Display holder.
Conformance_Case :: enum u8 {
	Contract_Check         = 0,
	Surface_Lifecycle      = 1,
	Present_And_Frame      = 2,
	Invalid_Record_Refusal = 3,
	Two_Client_Isolation   = 4,
}

CONFORMANCE_CASE_COUNT :: len(Conformance_Case)

// Why a conformance case failed against a Display holder.
Conformance_Failure :: enum u8 {
	None                               = 0,
	Contract_Refused                   = 1,
	Client_Open_Failed                 = 2,
	Invalid_Surface_Accepted           = 3,
	Valid_Surface_Refused              = 4,
	Unprivileged_Inspection_Allowed    = 5,
	Window_State_Mismatch              = 6,
	Client_Close_Failed                = 7,
	Invalid_Present_Accepted           = 8,
	Valid_Present_Refused              = 9,
	Frame_Accounting_Mismatch          = 10,
	Invalid_Draw_Record_Accepted       = 11,
	Valid_Draw_Record_Refused          = 12,
	Cross_Client_State_Corrupted       = 13,
	Key_Delivered_To_Unfocused_Client  = 14,
}

// Surface creation parameters sent by a client over the Display window ring.
Surface_Create_Request :: struct {
	memory_handle: u32,
	width:         u32,
	height:        u32,
	scale_word:    u64,
	serial:        u64,
	title:         string,
}

// Outcome of a Surface_Create command.
Surface_Outcome :: enum u8 {
	Accepted        = 0,
	Refused_Size    = 1,
	Refused_Scale   = 2,
	Refused_Handle  = 3,
	Refused_Serial  = 4,
	Refused_Client  = 5,
}

// Present parameters sent by a client over the Display window ring.
Present_Request :: struct {
	picture_index:  u64,
	surface_serial: u64,
	left:           u32,
	top:            u32,
	width:          u32,
	height:         u32,
	key_serial:     u64,
}

// Outcome of a Present command.
Present_Outcome :: enum u8 {
	Accepted           = 0,
	Refused_Picture    = 1,
	Refused_Serial     = 2,
	Refused_No_Surface = 3,
	Refused_Client     = 4,
}

// Contract-level snapshot of one window returned by windows().
Window_Snapshot :: struct {
	client_id:            u32,
	width:                u32,
	height:               u32,
	focus:                bool,
	presents:             u64,
	presents_refused:     u64,
	pictures_drawn_again: u64,
	frames:               u64,
}

// Contract-level snapshot of screen state returned by screen().
Screen_Snapshot :: struct {
	frames:   u64,
	presents: u64,
}

// Driver callbacks through which the conformance suite exercises any Display
// role holder (compositor, mock holder, or interposed membrane).
Display_Holder_Interface :: struct {
	state:           rawptr,
	module_bytes:    []u8,
	declaration:     role_contract.Module_Role_Declaration,
	client_open:     proc "contextless" (state: rawptr, client_id: u32) -> bool,
	client_close:    proc "contextless" (state: rawptr, client_id: u32) -> bool,
	surface_create:  proc "contextless" (state: rawptr, client_id: u32, request: Surface_Create_Request) -> Surface_Outcome,
	present:         proc "contextless" (state: rawptr, client_id: u32, request: Present_Request) -> Present_Outcome,
	draw_validate:   proc "contextless" (state: rawptr, client_id: u32, record: draw_record.Draw_Record) -> draw_record.Problem,
	window_list:     proc "contextless" (state: rawptr, caller_acts_for_principal: bool, out: []Window_Snapshot) -> (count: int, authorized: bool),
	screen_read:     proc "contextless" (state: rawptr, caller_acts_for_principal: bool) -> (snapshot: Screen_Snapshot, authorized: bool),
	deliver_key:     proc "contextless" (state: rawptr, key_code: u32, serial: u64) -> (delivered_client_id: u32, ok: bool),
}

// Result of one conformance case.
Case_Result :: struct {
	passed:  bool,
	failure: Conformance_Failure,
}

// Aggregate report of all conformance cases for a Display holder.
Conformance_Report :: struct {
	results:      [Conformance_Case]Case_Result,
	passed_count: int,
	failed_count: int,
	all_passed:   bool,
}

// display_contract_version exports the version of the Display role contract
// that this conformance suite checks.
@(export, link_name = "display_contract_version")
display_contract_version :: proc "c" () -> i64 {
	return i64(role_contract.DISPLAY_CONTRACT_VERSION)
}

@(private = "file")
case_contract_check :: proc "contextless" (holder: ^Display_Holder_Interface) -> Case_Result {
	contract := role_contract.display_contract()
	check := role_contract.module_fills_contract(holder.module_bytes, holder.declaration, contract)
	if check.refusal != .None || check.expected_hash != role_contract.display_contract_hash() {
		return {passed = false, failure = .Contract_Refused}
	}
	return {passed = true, failure = .None}
}

@(private = "file")
case_surface_lifecycle :: proc "contextless" (holder: ^Display_Holder_Interface) -> Case_Result {
	CLIENT_ID :: u32(1)
	if !holder.client_open(holder.state, CLIENT_ID) {
		return {passed = false, failure = .Client_Open_Failed}
	}

	// Refuse edge-case invalid surfaces: zero size, one past limit, zero handle, bad scale.
	invalid_requests := [6]Surface_Create_Request {
		{memory_handle = 1, width = 0, height = 100, scale_word = u64(scale_factor.DEFAULT), serial = 1, title = "zero_w"},
		{memory_handle = 1, width = 100, height = 0, scale_word = u64(scale_factor.DEFAULT), serial = 1, title = "zero_h"},
		{memory_handle = 1, width = role_contract.DISPLAY_SURFACE_LIMIT + 1, height = 100, scale_word = u64(scale_factor.DEFAULT), serial = 1, title = "over_w"},
		{memory_handle = 1, width = 100, height = role_contract.DISPLAY_SURFACE_LIMIT + 1, scale_word = u64(scale_factor.DEFAULT), serial = 1, title = "over_h"},
		{memory_handle = 0, width = 320, height = 200, scale_word = u64(scale_factor.DEFAULT), serial = 1, title = "no_handle"},
		{memory_handle = 1, width = 320, height = 200, scale_word = 99, serial = 1, title = "bad_scale"},
	}
	for req in invalid_requests {
		if holder.surface_create(holder.state, CLIENT_ID, req) == .Accepted {
			_ = holder.client_close(holder.state, CLIENT_ID)
			return {passed = false, failure = .Invalid_Surface_Accepted}
		}
	}

	// Accept valid surface.
	valid := Surface_Create_Request {
		memory_handle = 10,
		width         = 320,
		height        = 200,
		scale_word    = u64(scale_factor.DEFAULT),
		serial        = 1,
		title         = "alpha",
	}
	if holder.surface_create(holder.state, CLIENT_ID, valid) != .Accepted {
		_ = holder.client_close(holder.state, CLIENT_ID)
		return {passed = false, failure = .Valid_Surface_Refused}
	}

	// Unprivileged caller must be refused window inspection.
	windows_buf: [4]Window_Snapshot
	if _, authorized := holder.window_list(holder.state, false, windows_buf[:]); authorized {
		_ = holder.client_close(holder.state, CLIENT_ID)
		return {passed = false, failure = .Unprivileged_Inspection_Allowed}
	}

	// Authorized caller sees the created window.
	count, authorized := holder.window_list(holder.state, true, windows_buf[:])
	if !authorized || count != 1 || windows_buf[0].client_id != CLIENT_ID || windows_buf[0].width != 320 || windows_buf[0].height != 200 {
		_ = holder.client_close(holder.state, CLIENT_ID)
		return {passed = false, failure = .Window_State_Mismatch}
	}

	// Closing the client removes its window.
	if !holder.client_close(holder.state, CLIENT_ID) {
		return {passed = false, failure = .Client_Close_Failed}
	}
	count_after, auth_after := holder.window_list(holder.state, true, windows_buf[:])
	if !auth_after || count_after != 0 {
		return {passed = false, failure = .Window_State_Mismatch}
	}
	return {passed = true, failure = .None}
}

@(private = "file")
case_present_and_frame :: proc "contextless" (holder: ^Display_Holder_Interface) -> Case_Result {
	CLIENT_ID :: u32(2)
	if !holder.client_open(holder.state, CLIENT_ID) {
		return {passed = false, failure = .Client_Open_Failed}
	}
	defer holder.client_close(holder.state, CLIENT_ID)

	// Present before creating a surface must be refused.
	if holder.present(holder.state, CLIENT_ID, {picture_index = 0, surface_serial = 1}) == .Accepted {
		return {passed = false, failure = .Invalid_Present_Accepted}
	}

	if holder.surface_create(holder.state, CLIENT_ID, {memory_handle = 20, width = 400, height = 300, scale_word = u64(scale_factor.DEFAULT), serial = 1, title = "beta"}) != .Accepted {
		return {passed = false, failure = .Valid_Surface_Refused}
	}

	// Out-of-range picture index and wrong surface serial must be refused.
	bad_presents := [4]Present_Request {
		{picture_index = u64(role_contract.DISPLAY_PICTURE_COUNT), surface_serial = 1},
		{picture_index = max(u64), surface_serial = 1},
		{picture_index = 0, surface_serial = 0},
		{picture_index = 0, surface_serial = 99},
	}
	for req in bad_presents {
		if holder.present(holder.state, CLIENT_ID, req) == .Accepted {
			return {passed = false, failure = .Invalid_Present_Accepted}
		}
	}

	// Alternating valid presents must succeed.
	if holder.present(holder.state, CLIENT_ID, {picture_index = 0, surface_serial = 1, width = 400, height = 300}) != .Accepted {
		return {passed = false, failure = .Valid_Present_Refused}
	}
	if holder.present(holder.state, CLIENT_ID, {picture_index = 1, surface_serial = 1, width = 400, height = 300}) != .Accepted {
		return {passed = false, failure = .Valid_Present_Refused}
	}

	// Unprivileged screen() read must be refused.
	if _, auth := holder.screen_read(holder.state, false); auth {
		return {passed = false, failure = .Unprivileged_Inspection_Allowed}
	}
	screen_snap, screen_auth := holder.screen_read(holder.state, true)
	if !screen_auth || screen_snap.presents < 2 || screen_snap.frames == 0 {
		return {passed = false, failure = .Frame_Accounting_Mismatch}
	}

	windows_buf: [4]Window_Snapshot
	count, win_auth := holder.window_list(holder.state, true, windows_buf[:])
	if !win_auth || count != 1 || windows_buf[0].presents != 2 || windows_buf[0].presents_refused < 4 {
		return {passed = false, failure = .Frame_Accounting_Mismatch}
	}
	return {passed = true, failure = .None}
}

@(private = "file")
case_invalid_record_refusal :: proc "contextless" (holder: ^Display_Holder_Interface) -> Case_Result {
	CLIENT_ID :: u32(3)
	if !holder.client_open(holder.state, CLIENT_ID) {
		return {passed = false, failure = .Client_Open_Failed}
	}
	defer holder.client_close(holder.state, CLIENT_ID)

	if holder.surface_create(holder.state, CLIENT_ID, {memory_handle = 30, width = 200, height = 200, scale_word = u64(scale_factor.DEFAULT), serial = 1, title = "gamma"}) != .Accepted {
		return {passed = false, failure = .Valid_Surface_Refused}
	}

	// Unknown draw kind (255 and retired kind 2).
	unknown_kind := draw_record.Draw_Record{kind = 255}
	if holder.draw_validate(holder.state, CLIENT_ID, unknown_kind) != .Unknown_Kind {
		return {passed = false, failure = .Invalid_Draw_Record_Accepted}
	}
	retired_kind := draw_record.Draw_Record{kind = 2}
	if holder.draw_validate(holder.state, CLIENT_ID, retired_kind) != .Unknown_Kind {
		return {passed = false, failure = .Invalid_Draw_Record_Accepted}
	}

	// Non-zero reserved byte.
	bad_reserved := draw_record.record_of(draw_record.Draw_Rectangle{color = draw_record.opaque(0x112233)}, 0, 0, 0, 640, 640)
	bad_reserved.reserved[0] = 1
	if holder.draw_validate(holder.state, CLIENT_ID, bad_reserved) != .Reserved_Not_Zero {
		return {passed = false, failure = .Invalid_Draw_Record_Accepted}
	}

	// Inverted bounding box.
	inverted := draw_record.record_of(draw_record.Draw_Rectangle{color = draw_record.opaque(0x112233)}, 0, 640, 0, 0, 640)
	if holder.draw_validate(holder.state, CLIENT_ID, inverted) != .Box_Inverted {
		return {passed = false, failure = .Invalid_Draw_Record_Accepted}
	}

	// Coordinate past limit.
	past_limit := draw_record.record_of(draw_record.Draw_Rectangle{color = draw_record.opaque(0x112233)}, 0, 0, 0, draw_record.COORDINATE_UNIT_LIMIT + 64, 640)
	if holder.draw_validate(holder.state, CLIENT_ID, past_limit) != .Box_Past_Coordinate_Limit {
		return {passed = false, failure = .Invalid_Draw_Record_Accepted}
	}

	// Valid canonical rectangle must be accepted.
	valid_rect := draw_record.record_of(draw_record.Draw_Rectangle{color = draw_record.opaque(0x112233)}, 0, 0, 0, 640, 640)
	if holder.draw_validate(holder.state, CLIENT_ID, valid_rect) != .None {
		return {passed = false, failure = .Valid_Draw_Record_Refused}
	}
	return {passed = true, failure = .None}
}

@(private = "file")
case_two_client_isolation :: proc "contextless" (holder: ^Display_Holder_Interface) -> Case_Result {
	CLIENT_A :: u32(10)
	CLIENT_B :: u32(11)
	if !holder.client_open(holder.state, CLIENT_A) {
		return {passed = false, failure = .Client_Open_Failed}
	}
	if !holder.client_open(holder.state, CLIENT_B) {
		_ = holder.client_close(holder.state, CLIENT_A)
		return {passed = false, failure = .Client_Open_Failed}
	}

	if holder.surface_create(holder.state, CLIENT_A, {memory_handle = 100, width = 300, height = 200, scale_word = u64(scale_factor.DEFAULT), serial = 1, title = "client_a"}) != .Accepted {
		_ = holder.client_close(holder.state, CLIENT_A)
		_ = holder.client_close(holder.state, CLIENT_B)
		return {passed = false, failure = .Valid_Surface_Refused}
	}
	if holder.surface_create(holder.state, CLIENT_B, {memory_handle = 101, width = 500, height = 400, scale_word = u64(scale_factor.DEFAULT), serial = 7, title = "client_b"}) != .Accepted {
		_ = holder.client_close(holder.state, CLIENT_A)
		_ = holder.client_close(holder.state, CLIENT_B)
		return {passed = false, failure = .Valid_Surface_Refused}
	}

	// Client A presenting Client B's serial (7) must be refused and must not
	// alter Client B's present count.
	if holder.present(holder.state, CLIENT_A, {picture_index = 0, surface_serial = 7}) == .Accepted {
		_ = holder.client_close(holder.state, CLIENT_A)
		_ = holder.client_close(holder.state, CLIENT_B)
		return {passed = false, failure = .Cross_Client_State_Corrupted}
	}

	// Client B presents once; Client A has 0 valid presents.
	if holder.present(holder.state, CLIENT_B, {picture_index = 0, surface_serial = 7, width = 500, height = 400}) != .Accepted {
		_ = holder.client_close(holder.state, CLIENT_A)
		_ = holder.client_close(holder.state, CLIENT_B)
		return {passed = false, failure = .Valid_Present_Refused}
	}

	// Client B opened most recently and has focus; key input must go only to Client B.
	delivered_to, key_ok := holder.deliver_key(holder.state, 0x1E, 42)
	if !key_ok || delivered_to != CLIENT_B {
		_ = holder.client_close(holder.state, CLIENT_A)
		_ = holder.client_close(holder.state, CLIENT_B)
		return {passed = false, failure = .Key_Delivered_To_Unfocused_Client}
	}

	// Closing Client A must leave Client B intact and still able to present.
	if !holder.client_close(holder.state, CLIENT_A) {
		_ = holder.client_close(holder.state, CLIENT_B)
		return {passed = false, failure = .Client_Close_Failed}
	}
	windows_buf: [4]Window_Snapshot
	count, auth := holder.window_list(holder.state, true, windows_buf[:])
	if !auth || count != 1 || windows_buf[0].client_id != CLIENT_B || windows_buf[0].presents != 1 {
		_ = holder.client_close(holder.state, CLIENT_B)
		return {passed = false, failure = .Cross_Client_State_Corrupted}
	}
	if holder.present(holder.state, CLIENT_B, {picture_index = 1, surface_serial = 7, width = 500, height = 400}) != .Accepted {
		_ = holder.client_close(holder.state, CLIENT_B)
		return {passed = false, failure = .Cross_Client_State_Corrupted}
	}
	if !holder.client_close(holder.state, CLIENT_B) {
		return {passed = false, failure = .Client_Close_Failed}
	}
	return {passed = true, failure = .None}
}

// run_display_conformance executes all conformance cases against holder and
// returns a full Conformance_Report.
run_display_conformance :: proc "contextless" (holder: ^Display_Holder_Interface) -> (report: Conformance_Report) {
	report.results[.Contract_Check] = case_contract_check(holder)
	report.results[.Surface_Lifecycle] = case_surface_lifecycle(holder)
	report.results[.Present_And_Frame] = case_present_and_frame(holder)
	report.results[.Invalid_Record_Refusal] = case_invalid_record_refusal(holder)
	report.results[.Two_Client_Isolation] = case_two_client_isolation(holder)

	for item in report.results {
		if item.passed {
			report.passed_count += 1
		} else {
			report.failed_count += 1
		}
	}
	report.all_passed = report.failed_count == 0
	return report
}
