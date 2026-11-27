package build

import module "modus:contract/module"
import "modus:contract/module_file_writer"
import "modus:contract/role_contract"
import rd "modus:contract/root_delegation"
import "core:strings"
import "core:testing"
import "modustool:foundation"

@(private = "file")
role_holder_module_file_in :: proc(t: ^testing.T, base_folder: string, holder: string) -> (file: []u8, ok: bool) {
	folder := foundation.join(base_folder, holder)
	description, described := describe_package(folder)
	if !testing.expectf(t, described, "describe_package failed for default role holder %s (%s)", holder, folder) {
		return nil, false
	}
	paths, listed := foundation.files_with_suffix(folder, ".odin")
	if !testing.expectf(t, listed, "listing sources failed for %s", folder) {
		return nil, false
	}
	sources := make([dynamic]Fact_Source, context.temp_allocator)
	for path in paths {
		if strings.has_suffix(path, "_test.odin") || strings.has_suffix(path, "_wasm64p32.odin") {
			continue
		}
		text, read_ok := foundation.read_text_file(path)
		if !testing.expectf(t, read_ok, "reading %s failed", path) {
			return nil, false
		}
		append(&sources, Fact_Source{path = path, source = text})
	}
	outputs, inputs, streams_ok := record_streams_of_sources(folder, sources[:])
	if !testing.expectf(t, streams_ok, "record_streams_of_sources failed for %s", holder) {
		return nil, false
	}
	if !testing.expectf(t, record_streams_merge(&description, outputs, inputs), "record_streams_merge failed for %s", holder) {
		return nil, false
	}

	code := [16]u8{0 = 0xC3}
	data: [4096]u8
	segments := [2]module_file_writer.Segment_Part {
		{memory_offset = 0, memory_size = 4096, flags = {.Read, .Execute}, data = code[:]},
		{memory_offset = 4096, memory_size = 4096, flags = {.Read, .Write}, data = data[:]},
	}
	export_parts := make([]module_file_writer.Export_Part, len(description.exports), context.temp_allocator)
	for item, index in description.exports {
		export_parts[index] = export_part_from_description(item, 0)
	}
	setting_rows := make([dynamic]module.Parameter_Setting, context.temp_allocator)
	for item in description.exports {
		append(&setting_rows, ..item.setting_rows)
	}
	output_parts := make([]module_file_writer.Record_Output_Part, len(description.record_outputs), context.temp_allocator)
	for item, index in description.record_outputs {
		output_parts[index] = {
			name         = item.name,
			about        = item.about,
			text         = item.text,
			record_index = item.record_index,
			pairing      = item.pairing,
			place        = 4096 + u64(index * 16),
		}
	}
	input_parts := make([]module_file_writer.Record_Input_Part, len(description.record_inputs), context.temp_allocator)
	for item, index in description.record_inputs {
		input_parts[index] = {
			name         = item.name,
			about        = item.about,
			text         = item.text,
			record_index = item.record_index,
			terms_index  = item.terms_index,
			wirings      = item.wirings,
			place        = 4096 + u64((len(description.record_outputs) + index) * 16),
		}
	}
	parts := module_file_writer.Module_Parts {
		segments           = segments[:],
		exports            = export_parts,
		records            = description.records,
		enums              = description.enums,
		member_texts       = description.member_texts,
		parameter_settings = setting_rows[:],
		about              = description.about,
		text               = description.text,
		record_outputs     = output_parts,
		record_inputs      = input_parts,
	}
	size, size_refusal := module_file_writer.file_size_needed(parts)
	if !testing.expectf(t, size_refusal.refusal == .None, "%s: module_file_writer size refused: %s", holder, module_file_refusal_text(parts, size_refusal)) {
		return nil, false
	}
	bytes := make([]u8, int(size), context.temp_allocator)
	_, write_refusal := module_file_writer.write(parts, bytes)
	if !testing.expectf(t, write_refusal.refusal == .None, "%s: module_file_writer write refused: %s", holder, module_file_refusal_text(parts, write_refusal)) {
		return nil, false
	}
	return bytes, true
}

@(private = "file")
role_holder_module_file :: proc(t: ^testing.T, holder: string) -> (file: []u8, ok: bool) {
	return role_holder_module_file_in(t, foundation.SYSTEM_MODULE_SOURCES, holder)
}

@(private = "file")
role_contract_declaration_for :: proc(contract: role_contract.Role_Contract, hash: role_contract.Contract_Hash) -> (hashes: [1]role_contract.Contract_Hash, ring_faces: [8]role_contract.Required_Ring_Face, ring_count: int) {
	hashes[0] = hash
	for &face in contract.faces {
		if face.kind == .Ring {
			ring_faces[ring_count] = face.ring_face
			ring_count += 1
		}
	}
	return
}

// Every role in role_contract.Role (except .None) has a canonical contract in
// root_delegation.role_contract_by_role, and every default boot-image holder in
// role_contract.DEFAULT_HOLDER_NAMES fills its role contract when checked by
// role_contract.module_fills_contract. Refusal cases come first: a holder
// checked against another role's contract (missing export or wrong record
// stream) is refused.
@(test)
every_default_boot_image_role_holder_fills_its_role_contract :: proc(t: ^testing.T) {
	// Refusal cases first: checking a non-matching holder against a contract
	// with exports (Console) and against a contract with a record stream
	// (Start_Policy) must fail cleanly.
	input_file, input_ok := role_holder_module_file(t, "input")
	if input_ok {
		console_contract, _ := rd.role_contract_by_role(.Console)
		console_hash, _ := rd.role_contract_hash_by_role(.Console)
		c_hashes, c_rings, c_ring_count := role_contract_declaration_for(console_contract, console_hash)
		c_result := role_contract.module_fills_contract(input_file, {contract_hashes = c_hashes[:], ring_faces = c_rings[:c_ring_count]}, console_contract)
		testing.expect_value(t, c_result.refusal, role_contract.Contract_Check_Refusal.Missing_Export)

		sp_contract, _ := rd.role_contract_by_role(.Start_Policy)
		sp_hash, _ := rd.role_contract_hash_by_role(.Start_Policy)
		sp_hashes, sp_rings, sp_ring_count := role_contract_declaration_for(sp_contract, sp_hash)
		sp_result := role_contract.module_fills_contract(input_file, {contract_hashes = sp_hashes[:], ring_faces = sp_rings[:sp_ring_count]}, sp_contract)
		testing.expect_value(t, sp_result.refusal, role_contract.Contract_Check_Refusal.Missing_Record_Stream)
	}

	// Verify every role has a canonical contract and every default boot-image
	// holder fills its contract.
	checked_holders := 0
	for role in role_contract.Role {
		if role == .None {
			continue
		}
		contract, known := rd.role_contract_by_role(role)
		if !testing.expectf(t, known, "role %v has no canonical contract in role_catalog", role) {
			continue
		}
		hash, hashed := rd.role_contract_hash_by_role(role)
		if !testing.expectf(t, hashed, "role %v failed canonical contract hashing", role) {
			continue
		}
		holder := role_contract.DEFAULT_HOLDER_NAMES[role]
		if holder == "" {
			continue
		}
		file, built := role_holder_module_file(t, holder)
		if !built {
			continue
		}
		hashes, ring_faces, ring_count := role_contract_declaration_for(contract, hash)
		declaration := role_contract.Module_Role_Declaration {
			contract_hashes = hashes[:],
			ring_faces      = ring_faces[:ring_count],
		}
		result := role_contract.module_fills_contract(file, declaration, contract)
		testing.expectf(
			t,
			result.refusal == .None,
			"default holder %s of role %v failed contract check: refusal=%v difference=%v face=%d export=%d param=%d",
			holder,
			role,
			result.refusal,
			result.difference,
			result.face_index,
			result.export_index,
			result.parameter,
		)
		checked_holders += 1
	}
	// All 21 roles with a default boot-image holder must be checked (23 roles
	// minus Assistive and Speech which have no default holder yet).
	testing.expect_value(t, checked_holders, 21)
}

// The barless second Display holder panel_display must fill the canonical
// Display role contract so root accepts it as a replacement holder in a plan.
@(test)
second_display_holder_panel_display_fills_display_contract :: proc(t: ^testing.T) {
	file, built := role_holder_module_file_in(t, foundation.TEST_MODULE_SOURCES, "panel_display")
	if !built {
		return
	}
	contract, known := rd.role_contract_by_role(.Display)
	testing.expect(t, known, "Display role contract must be present")
	hash, hashed := rd.role_contract_hash_by_role(.Display)
	testing.expect(t, hashed, "Display role contract hash must compute")
	hashes, ring_faces, ring_count := role_contract_declaration_for(contract, hash)
	result := role_contract.module_fills_contract(file, {contract_hashes = hashes[:], ring_faces = ring_faces[:ring_count]}, contract)
	testing.expectf(
		t,
		result.refusal == .None,
		"panel_display failed Display contract check: refusal=%v difference=%v face=%d export=%d param=%d",
		result.refusal,
		result.difference,
		result.face_index,
		result.export_index,
		result.parameter,
	)
}
