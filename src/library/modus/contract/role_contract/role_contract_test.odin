#+build !freestanding
package role_contract

import "core:testing"
import "modus:contract/module"
import "modus:contract/module_file_writer"
import op "modus:contract/operation"

// Build a minimal valid module file in memory with the given exports, records,
// and optional record streams, using the contract module file writer.
@(private = "file")
build_test_module :: proc(
	t: ^testing.T,
	exports: []module_file_writer.Export_Part,
	records: []module_file_writer.Record_Description,
	record_outputs: []module_file_writer.Record_Output_Part = nil,
	record_inputs: []module_file_writer.Record_Input_Part = nil,
	enums: []module_file_writer.Enum_Description = nil,
	parameter_settings: []module.Parameter_Setting = nil,
) -> []u8 {
	code := [16]u8{0 = 0xC3} // Single ret instruction.
	segments := [1]module_file_writer.Segment_Part {
		{
			memory_offset = 0,
			memory_size   = module.PAGE_SIZE,
			flags         = {.Read, .Execute},
			data          = code[:],
		},
	}
	parts := module_file_writer.Module_Parts {
		segments       = segments[:],
		exports        = exports,
		records        = records,
		record_outputs = record_outputs,
		record_inputs  = record_inputs,
		enums          = enums,
		parameter_settings = parameter_settings,
	}
	needed, size_refusal := module_file_writer.file_size_needed(parts)
	testing.expect_value(t, size_refusal.refusal, module_file_writer.Refusal.None)
	buffer := make([]u8, int(needed), context.temp_allocator)
	written, write_refusal := module_file_writer.write(parts, buffer)
	testing.expect_value(t, write_refusal.refusal, module_file_writer.Refusal.None)
	testing.expect_value(t, written, needed)
	return buffer
}

// Records matching the Display contract exports: Pointer, Window, Screen,
// Error_Record.
@(private = "file")
display_test_records :: proc() -> [5]module_file_writer.Record_Description {
	@(static)
	value_field := [1]module_file_writer.Field_Description {
		{name = "value", offset = 0, type = .Integer, detail = 8},
	}
	return {
		{name = "Pointer", size = 8, fields = value_field[:]},
		{name = "Window", size = 8, fields = value_field[:]},
		{name = "Screen", size = 8, fields = value_field[:]},
		{name = "Error_Record", size = 8, fields = value_field[:]},
		{name = "Setting_State", size = 8, fields = value_field[:]},
	}
}

// A fault of a holder of Display in its settings, for the refusals of the
// check of the contract.
@(private = "file")
Display_Settings_Fault :: enum {
	None,
	Enum_Of_Another_Name, // The edge of the bar is an enum of another name.
	Set_Not_Optional, // A parameter of set is not optional.
	No_Settings_State, // The export settings_state is missing.
	Range_Of_Another_Number, // The range of the time of a notification ends one past the contract.
	No_Range, // The factor of the magnifier has no range.
}

// build_compliant_display_module writes the parts of the contract
// (display_module_parts_write), with one fault, and an extra export.
build_compliant_display_module :: proc(t: ^testing.T, include_extra_export: bool = false, fault := Display_Settings_Fault.None) -> []u8 {
	@(static) parts: Display_Module_Parts
	display_module_parts_write(&parts)
	@(static) needs: [5]module.Parameter_Need
	needs = {.Optional, .Optional, .Optional, .Optional, .Optional}
	ranges := parts.set_ranges
	ranges_used := ranges[:]
	switch fault {
	case .None:
	case .Enum_Of_Another_Name:
		parts.enums[0].name = "Edge"
	case .Set_Not_Optional:
		needs[1] = .Required
		parts.exports[3].parameter_needs = needs[:]
	case .No_Settings_State:
		parts.exports[DISPLAY_MODULE_EXPORT_COUNT - 1].name = "settings_state_elsewhere"
	case .Range_Of_Another_Number:
		ranges[0].most += 1
	case .No_Range:
		ranges[1] = ranges[2]
		ranges_used = ranges[:2]
	}
	exports: [DISPLAY_MODULE_EXPORT_COUNT + 1]module_file_writer.Export_Part
	copy(exports[:], parts.exports[:])
	exports[DISPLAY_MODULE_EXPORT_COUNT] = {name = "extra_diagnostics", result = .Integer}
	count := include_extra_export ? DISPLAY_MODULE_EXPORT_COUNT + 1 : DISPLAY_MODULE_EXPORT_COUNT
	return build_test_module(t, exports[:count], parts.records[:], enums = parts.enums[:], parameter_settings = ranges_used)
}

@(test)
border_conversions_refuse_unknown_and_zero_words :: proc(t: ^testing.T) {
	// Zero, one past the last enum value, and max(u64) are refused.
	for bad_role in ([?]u64{0, u64(max(Role)) + 1, u64(max(Role)) + 100, 0xFFFF_FFFF, max(u64)}) {
		role, ok := role_from_word(bad_role)
		testing.expectf(t, !ok && role == .None, "word %d must be refused", bad_role)
	}
	// Every valid member from 1 to Powerbox round-trips through its explicit value.
	for member in Role {
		if member == .None {
			continue
		}
		parsed, ok := role_from_word(u64(member))
		testing.expectf(t, ok && parsed == member, "member %v must round-trip", member)
	}

	// Scope border edges.
	for bad_scope in ([?]u64{0, u64(Role_Scope.Device) + 1, 255, max(u64)}) {
		scope, ok := role_scope_from_word(bad_scope)
		testing.expectf(t, !ok && scope == .None, "scope word %d must be refused", bad_scope)
	}
	for scope in Role_Scope {
		if scope == .None {
			continue
		}
		parsed, ok := role_scope_from_word(u64(scope))
		testing.expect(t, ok && parsed == scope)
	}

	// Trust path class border edges.
	for bad_class in ([?]u64{0, u64(Trust_Path_Class.Trusted_Path) + 1, 255, max(u64)}) {
		class, ok := trust_path_class_from_word(bad_class)
		testing.expectf(t, !ok && class == .None, "trust class word %d must be refused", bad_class)
	}

	// Face kind border edges.
	for bad_face in ([?]u64{0, u64(Face_Kind.Record_Stream) + 1, 99, 255, max(u64)}) {
		kind, ok := face_kind_from_word(bad_face)
		testing.expectf(t, !ok && kind == .None, "face kind word %d must be refused", bad_face)
	}
}

@(test)
role_properties_enforce_scopes_trusted_path_and_multiplicity :: proc(t: ^testing.T) {
	// Zero role has zero properties.
	testing.expect_value(t, role_properties(.None).scope, Role_Scope.None)
	testing.expect(t, !disk_holder_allowed_for_principal(.None, 0))

	trusted_count := 0
	multi_holder_count := 0
	for role in Role {
		if role == .None {
			continue
		}
		props := role_properties(role)
		testing.expectf(t, props.scope != .None, "role %v must have a scope", role)
		testing.expectf(t, props.trust_path != .None, "role %v must have a trust class", role)
		testing.expectf(t, len(props.name) > 0, "role %v must have a name", role)

		if props.allows_multiple_holders {
			multi_holder_count += 1
			testing.expect_value(t, role, Role.Assistive)
		}
		if props.trust_path == .Trusted_Path {
			trusted_count += 1
			// Trusted-path roles allow disk holders only for principal 0.
			testing.expect(t, disk_holder_allowed_for_principal(role, MACHINE_PRINCIPAL))
			for principal in ([?]u64{1, 2, 7, max(u64)}) {
				testing.expectf(t, !disk_holder_allowed_for_principal(role, principal), "trusted role %v must refuse principal %d", role, principal)
			}
		} else {
			testing.expect(t, disk_holder_allowed_for_principal(role, MACHINE_PRINCIPAL))
			testing.expect(t, disk_holder_allowed_for_principal(role, 1))
		}
	}
	testing.expect_value(t, trusted_count, 5)
	testing.expect_value(t, multi_holder_count, 1)

	// Specific scope checks.
	testing.expect_value(t, role_properties(.Display).scope, Role_Scope.Machine)
	testing.expect_value(t, role_properties(.Console).scope, Role_Scope.Session)
	testing.expect_value(t, role_properties(.Terminal).scope, Role_Scope.Client)
	testing.expect_value(t, role_properties(.Block_Device).scope, Role_Scope.Device)
	testing.expect_value(t, role_properties(.Tpm).scope, Role_Scope.Device)
}

@(test)
display_contract_hash_is_deterministic_and_sensitive :: proc(t: ^testing.T) {
	first := display_contract_hash()
	second := display_contract_hash()
	testing.expect(t, first != (Contract_Hash{}), "display contract hash must not be zero")
	testing.expect_value(t, first, second)

	// Verify the pinned BLAKE3 hex digest so any accidental drift in the Display
	// contract fails this test immediately.
	hex_buf: [64]u8
	hex_digits := "0123456789abcdef"
	for b, idx in first {
		hex_buf[idx * 2] = hex_digits[b >> 4]
		hex_buf[idx * 2 + 1] = hex_digits[b & 0x0F]
	}
	testing.expect_value(t, string(hex_buf[:]), "41667fda2758aeca1508582498ae10843dd9c372d7ee5bc45ccb7afe6f7a4db6")

	mutated := display_contract()
	mutated.version += 1
	mutated_hash, mutated_ok := contract_hash(mutated)
	testing.expect(t, mutated_ok)
	testing.expect(t, mutated_hash != first, "changing version must change contract hash")

	other_role := display_contract()
	other_role.role = .Remote_Display
	other_role_hash, other_role_ok := contract_hash(other_role)
	testing.expect(t, other_role_ok)
	testing.expect(t, other_role_hash != first, "changing role must change contract hash")

	// Changing a single ring protocol version changes the hash.
	mutated_faces: [5]Required_Face
	copy(mutated_faces[:], display_contract().faces)
	mutated_faces[1].ring_face.protocol_version += 1
	ring_changed := Role_Contract{role = .Display, version = DISPLAY_CONTRACT_VERSION, faces = mutated_faces[:]}
	ring_changed_hash, ring_changed_ok := contract_hash(ring_changed)
	testing.expect(t, ring_changed_ok)
	testing.expect(t, ring_changed_hash != first, "changing ring protocol version must change contract hash")
}

@(test)
module_fills_contract_refuses_malformed_undeclared_and_tampered :: proc(t: ^testing.T) {
	contract := display_contract()
	expected_hash := display_contract_hash()
	valid_hashes := [1]Contract_Hash{expected_hash}
	valid_decl := Module_Role_Declaration{contract_hashes = valid_hashes[:], ring_faces = display_ring_faces()}
	good_module := build_compliant_display_module(t)

	// Malformed module bytes: empty, truncated, corrupted magic.
	testing.expect_value(t, module_fills_contract(nil, valid_decl, contract).refusal, Contract_Check_Refusal.Malformed_Module)
	testing.expect_value(t, module_fills_contract(good_module[:16], valid_decl, contract).refusal, Contract_Check_Refusal.Malformed_Module)
	corrupt := make([]u8, len(good_module), context.temp_allocator)
	copy(corrupt, good_module)
	corrupt[0] ~= 0xFF
	testing.expect_value(t, module_fills_contract(corrupt, valid_decl, contract).refusal, Contract_Check_Refusal.Malformed_Module)

	// Undeclared contract (no hashes declared).
	undeclared := Module_Role_Declaration{contract_hashes = nil, ring_faces = display_ring_faces()}
	testing.expect_value(t, module_fills_contract(good_module, undeclared, contract).refusal, Contract_Check_Refusal.Undeclared_Contract)

	// Tampered contract hash (single bit flipped) and all-zero hash.
	tampered := expected_hash
	tampered[15] ~= 0x01
	tampered_list := [1]Contract_Hash{tampered}
	tampered_decl := Module_Role_Declaration{contract_hashes = tampered_list[:], ring_faces = display_ring_faces()}
	testing.expect_value(t, module_fills_contract(good_module, tampered_decl, contract).refusal, Contract_Check_Refusal.Hash_Mismatch)

	zero_list := [1]Contract_Hash{{}}
	zero_decl := Module_Role_Declaration{contract_hashes = zero_list[:], ring_faces = display_ring_faces()}
	testing.expect_value(t, module_fills_contract(good_module, zero_decl, contract).refusal, Contract_Check_Refusal.Hash_Mismatch)

	// Unknown face kind and malformed contract.
	bad_face := [1]Required_Face{{kind = Face_Kind(99), name = "bad"}}
	bad_face_contract := Role_Contract{role = .Display, version = 1, faces = bad_face[:]}
	testing.expect_value(t, module_fills_contract(good_module, valid_decl, bad_face_contract).refusal, Contract_Check_Refusal.Unknown_Face_Kind)

	zero_face := [1]Required_Face{{kind = .None, name = "zero"}}
	zero_face_contract := Role_Contract{role = .Display, version = 1, faces = zero_face[:]}
	testing.expect_value(t, module_fills_contract(good_module, valid_decl, zero_face_contract).refusal, Contract_Check_Refusal.Unknown_Face_Kind)

	no_role_contract := Role_Contract{role = .None, version = 1, faces = contract.faces}
	testing.expect_value(t, module_fills_contract(good_module, valid_decl, no_role_contract).refusal, Contract_Check_Refusal.Malformed_Contract)

	zero_version_contract := Role_Contract{role = .Display, version = 0, faces = contract.faces}
	testing.expect_value(t, module_fills_contract(good_module, valid_decl, zero_version_contract).refusal, Contract_Check_Refusal.Malformed_Contract)
}

@(test)
module_fills_contract_refuses_missing_export_and_wrong_signatures :: proc(t: ^testing.T) {
	contract := display_contract()
	expected_hash := display_contract_hash()
	valid_hashes := [1]Contract_Hash{expected_hash}
	valid_decl := Module_Role_Declaration{contract_hashes = valid_hashes[:], ring_faces = display_ring_faces()}
	records := display_test_records()

	// Missing export ("screen" absent).
	missing_exports := [2]module_file_writer.Export_Part {
		{name = "pointer", code_offset = 0, result = .Table, result_detail = 1, error_record = 4},
		{name = "windows", code_offset = 0, result = .Table, result_detail = 2, error_record = 4},
	}
	missing_mod := build_test_module(t, missing_exports[:], records[:])
	res := module_fills_contract(missing_mod, valid_decl, contract)
	testing.expect_value(t, res.refusal, Contract_Check_Refusal.Missing_Export)
	testing.expect_value(t, res.difference, module.Difference.Missing_Export)

	// Wrong parameter count (pointer takes an Integer parameter).
	extra_param_types := [1]module.Type{.Integer}
	extra_param_names := [1]string{"id"}
	wrong_count_exports := [3]module_file_writer.Export_Part {
		{name = "pointer", code_offset = 0, parameters = extra_param_types[:], parameter_names = extra_param_names[:], result = .Table, result_detail = 1, error_record = 4},
		{name = "windows", code_offset = 0, result = .Table, result_detail = 2, error_record = 4},
		{name = "screen", code_offset = 0, result = .Table, result_detail = 3, error_record = 4},
	}
	wrong_count_mod := build_test_module(t, wrong_count_exports[:], records[:])
	res = module_fills_contract(wrong_count_mod, valid_decl, contract)
	testing.expect_value(t, res.refusal, Contract_Check_Refusal.Wrong_Signature)
	testing.expect_value(t, res.difference, module.Difference.Parameter_Count)

	// Wrong result type (screen returns Integer instead of Table).
	wrong_result_exports := [3]module_file_writer.Export_Part {
		{name = "pointer", code_offset = 0, result = .Table, result_detail = 1, error_record = 4},
		{name = "windows", code_offset = 0, result = .Table, result_detail = 2, error_record = 4},
		{name = "screen", code_offset = 0, result = .Integer, error_record = 4},
	}
	wrong_result_mod := build_test_module(t, wrong_result_exports[:], records[:])
	res = module_fills_contract(wrong_result_mod, valid_decl, contract)
	testing.expect_value(t, res.refusal, Contract_Check_Refusal.Wrong_Signature)
	testing.expect_value(t, res.difference, module.Difference.Result_Type)

	// Wrong result record name (screen returns Table of Window instead of Screen).
	wrong_rec_exports := [3]module_file_writer.Export_Part {
		{name = "pointer", code_offset = 0, result = .Table, result_detail = 1, error_record = 4},
		{name = "windows", code_offset = 0, result = .Table, result_detail = 2, error_record = 4},
		{name = "screen", code_offset = 0, result = .Table, result_detail = 2, error_record = 4},
	}
	wrong_rec_mod := build_test_module(t, wrong_rec_exports[:], records[:])
	res = module_fills_contract(wrong_rec_mod, valid_decl, contract)
	testing.expect_value(t, res.refusal, Contract_Check_Refusal.Wrong_Signature)
	testing.expect_value(t, res.difference, module.Difference.Result_Detail)

	// Missing error record on windows.
	no_error_exports := [3]module_file_writer.Export_Part {
		{name = "pointer", code_offset = 0, result = .Table, result_detail = 1, error_record = 4},
		{name = "windows", code_offset = 0, result = .Table, result_detail = 2, error_record = 0},
		{name = "screen", code_offset = 0, result = .Table, result_detail = 3, error_record = 4},
	}
	no_error_mod := build_test_module(t, no_error_exports[:], records[:])
	res = module_fills_contract(no_error_mod, valid_decl, contract)
	testing.expect_value(t, res.refusal, Contract_Check_Refusal.Wrong_Signature)
	testing.expect_value(t, res.difference, module.Difference.Error_Record)
}

@(test)
module_fills_contract_checks_parameter_types_directions_and_rings :: proc(t: ^testing.T) {
	// Custom contract requiring a parameter with direction .Read and a Handle
	// with specific rights, plus a Record_Output stream.
	params := [2]Required_Parameter {
		{type = .Bytes, direction = .Read},
		{type = .Handle, direction = .Read, detail = transmute(u32)op.Rights{.Read}},
	}
	req_exports := [1]Required_Export {
		{name = "commit_block", parameters = params[:], result = .Integer, has_error_record = false},
	}
	req_faces := [2]Required_Face {
		{kind = .Exports, name = "storage_exports", exports = req_exports[:]},
		{kind = .Record_Stream, name = "events_stream", record_stream = {name = "commits", is_input = false, record_name = "Commit_Event"}},
	}
	storage_contract := Role_Contract{role = .Storage, version = 1, faces = req_faces[:]}
	expected_hash, hash_ok := contract_hash(storage_contract)
	testing.expect(t, hash_ok)
	decl_hashes := [1]Contract_Hash{expected_hash}
	decl := Module_Role_Declaration{contract_hashes = decl_hashes[:]}

	field := [1]module_file_writer.Field_Description{{name = "generation", offset = 0, type = .Integer, detail = 8}}
	records := [2]module_file_writer.Record_Description {
		{name = "Commit_Event", size = 8, fields = field[:]},
		{name = "Other_Event", size = 8, fields = field[:]},
	}
	out_streams := [1]module_file_writer.Record_Output_Part {
		{name = "commits", record_index = 1},
	}
	param_names := [2]string{"data", "target"}

	// Wrong parameter direction (.Change instead of .Read).
	wrong_dir_types := [2]module.Type{.Bytes, .Handle}
	wrong_dir_dirs := [2]module.Direction{.Change, .Read}
	wrong_dir_details := [2]u32{0, transmute(u32)op.Rights{.Read}}
	wrong_dir_exports := [1]module_file_writer.Export_Part {
		{name = "commit_block", code_offset = 0, parameters = wrong_dir_types[:], parameter_names = param_names[:], parameter_details = wrong_dir_details[:], parameter_directions = wrong_dir_dirs[:], result = .Integer},
	}
	wrong_dir_mod := build_test_module(t, wrong_dir_exports[:], records[:], out_streams[:])
	res := module_fills_contract(wrong_dir_mod, decl, storage_contract)
	testing.expect_value(t, res.refusal, Contract_Check_Refusal.Wrong_Signature)
	testing.expect_value(t, res.difference, module.Difference.Parameter_Direction)
	testing.expect_value(t, res.parameter, u32(1))

	// Wrong parameter type (.Text instead of .Bytes).
	wrong_type_types := [2]module.Type{.Text, .Handle}
	wrong_type_dirs := [2]module.Direction{.Read, .Read}
	wrong_type_exports := [1]module_file_writer.Export_Part {
		{name = "commit_block", code_offset = 0, parameters = wrong_type_types[:], parameter_names = param_names[:], parameter_details = wrong_dir_details[:], parameter_directions = wrong_type_dirs[:], result = .Integer},
	}
	wrong_type_mod := build_test_module(t, wrong_type_exports[:], records[:], out_streams[:])
	res = module_fills_contract(wrong_type_mod, decl, storage_contract)
	testing.expect_value(t, res.refusal, Contract_Check_Refusal.Wrong_Signature)
	testing.expect_value(t, res.difference, module.Difference.Parameter_Type)
	testing.expect_value(t, res.parameter, u32(1))

	// Wrong handle rights detail.
	wrong_rights_details := [2]u32{0, transmute(u32)op.Rights{.Read, .Write}}
	wrong_rights_exports := [1]module_file_writer.Export_Part {
		{name = "commit_block", code_offset = 0, parameters = wrong_dir_types[:], parameter_names = param_names[:], parameter_details = wrong_rights_details[:], parameter_directions = wrong_type_dirs[:], result = .Integer},
	}
	wrong_rights_mod := build_test_module(t, wrong_rights_exports[:], records[:], out_streams[:])
	res = module_fills_contract(wrong_rights_mod, decl, storage_contract)
	testing.expect_value(t, res.refusal, Contract_Check_Refusal.Wrong_Signature)
	testing.expect_value(t, res.difference, module.Difference.Parameter_Detail)
	testing.expect_value(t, res.parameter, u32(2))

	// Missing record stream.
	good_exports := [1]module_file_writer.Export_Part {
		{name = "commit_block", code_offset = 0, parameters = wrong_dir_types[:], parameter_names = param_names[:], parameter_details = wrong_dir_details[:], parameter_directions = wrong_type_dirs[:], result = .Integer},
	}
	no_stream_mod := build_test_module(t, good_exports[:], records[:], nil)
	testing.expect_value(t, module_fills_contract(no_stream_mod, decl, storage_contract).refusal, Contract_Check_Refusal.Missing_Record_Stream)

	// Wrong record stream record type.
	wrong_stream := [1]module_file_writer.Record_Output_Part{{name = "commits", record_index = 2}}
	wrong_stream_mod := build_test_module(t, good_exports[:], records[:], wrong_stream[:])
	testing.expect_value(t, module_fills_contract(wrong_stream_mod, decl, storage_contract).refusal, Contract_Check_Refusal.Wrong_Record_Stream)

	// Fully compliant custom module passes.
	good_mod := build_test_module(t, good_exports[:], records[:], out_streams[:])
	testing.expect_value(t, module_fills_contract(good_mod, decl, storage_contract).refusal, Contract_Check_Refusal.None)
}

@(test)
display_contract_accepts_compliant_module_and_refuses_bad_ring_faces :: proc(t: ^testing.T) {
	contract := display_contract()
	expected_hash := display_contract_hash()
	good_module := build_compliant_display_module(t, include_extra_export = true)

	// Missing ring face is refused.
	incomplete_rings := display_ring_faces()[:3]
	hashes := [1]Contract_Hash{expected_hash}
	testing.expect_value(
		t,
		module_fills_contract(good_module, {contract_hashes = hashes[:], ring_faces = incomplete_rings}, contract).refusal,
		Contract_Check_Refusal.Missing_Ring_Face,
	)

	// Mismatched ring face (wrong command count) is refused.
	bad_rings: [4]Required_Ring_Face
	copy(bad_rings[:], display_ring_faces())
	bad_rings[0].command_count -= 1
	testing.expect_value(
		t,
		module_fills_contract(good_module, {contract_hashes = hashes[:], ring_faces = bad_rings[:]}, contract).refusal,
		Contract_Check_Refusal.Ring_Face_Mismatch,
	)

	// A holder whose settings are not those of the role is refused: an enum
	// of another name, a setter whose parameter is not optional, a range
	// that ends one past the contract, a number with no range, a missing
	// state export.
	Fault_Case :: struct {
		fault:      Display_Settings_Fault,
		difference: module.Difference,
		parameter:  u32,
	}
	for item in ([?]Fault_Case{{.Enum_Of_Another_Name, .Parameter_Detail, 1}, {.Set_Not_Optional, .Parameter_Detail, 2}, {.Range_Of_Another_Number, .Parameter_Range, 3}, {.No_Range, .Parameter_Range, 4}}) {
		faulty := build_compliant_display_module(t, fault = item.fault)
		faulty_result := module_fills_contract(faulty, {contract_hashes = hashes[:], ring_faces = display_ring_faces()}, contract)
		testing.expectf(t, faulty_result.refusal == .Wrong_Signature && faulty_result.difference == item.difference && faulty_result.parameter == item.parameter, "%v gives %v, %v at %d", item.fault, faulty_result.refusal, faulty_result.difference, faulty_result.parameter)
	}
	no_state := build_compliant_display_module(t, fault = .No_Settings_State)
	testing.expect_value(t, module_fills_contract(no_state, {contract_hashes = hashes[:], ring_faces = display_ring_faces()}, contract).refusal, Contract_Check_Refusal.Missing_Export)

	// Compliant module with extra export and multiple declared contract hashes passes.
	other_hash := expected_hash
	other_hash[0] ~= 0xAA
	two_hashes := [2]Contract_Hash{other_hash, expected_hash}
	result := module_fills_contract(good_module, {contract_hashes = two_hashes[:], ring_faces = display_ring_faces()}, contract)
	testing.expect_value(t, result.refusal, Contract_Check_Refusal.None)
	testing.expect_value(t, result.expected_hash, expected_hash)
}

@(test)
powerbox_contract_is_deterministic_and_verifies_compliant_module :: proc(t: ^testing.T) {
	contract := powerbox_contract()
	first := powerbox_contract_hash()
	second := powerbox_contract_hash()
	testing.expect(t, first != (Contract_Hash{}), "powerbox contract hash must not be zero")
	testing.expect_value(t, first, second)
	testing.expect(t, first != display_contract_hash(), "powerbox contract hash must differ from display")

	field := [1]module_file_writer.Field_Description{{name = "value", offset = 0, type = .Integer, detail = 8}}
	records := [2]module_file_writer.Record_Description {
		{name = "Powerbox_Status", size = 8, fields = field[:]},
		{name = "Error_Record", size = 8, fields = field[:]},
	}
	exports := [2]module_file_writer.Export_Part {
		{name = "pending_count", code_offset = 0, result = .Integer, error_record = 2},
		{name = "status", code_offset = 0, result = .Record, result_detail = 1, error_record = 2},
	}
	good_mod := build_test_module(t, exports[:], records[:])
	hashes := [1]Contract_Hash{first}
	decl := Module_Role_Declaration{contract_hashes = hashes[:], ring_faces = powerbox_ring_faces()}
	res := module_fills_contract(good_mod, decl, contract)
	testing.expect_value(t, res.refusal, Contract_Check_Refusal.None)
	testing.expect_value(t, res.expected_hash, first)

	// Missing one ring face is refused.
	incomplete := Module_Role_Declaration{contract_hashes = hashes[:], ring_faces = powerbox_ring_faces()[:1]}
	testing.expect_value(t, module_fills_contract(good_mod, incomplete, contract).refusal, Contract_Check_Refusal.Missing_Ring_Face)
}
