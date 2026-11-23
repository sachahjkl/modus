// Role contracts: the closed set of system roles, their scopes and trust
// classes, canonical contract hashing, and the check that a module fills a
// contract (src/md/features/roles_and_contracts.md).
//
// A role is a place in the system that one process fills for the others:
// the display, the console, the storage, a device class. Every client depends
// on the role contract and its BLAKE3 hash, never on the name of the module
// that holds the role.
//
// This is a contract package: it imports base packages and contract packages
// only, calls no kernel operation, and allocates no memory.
package role_contract

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/module"

// A BLAKE3 digest that identifies a role contract or a module file.
Contract_Hash :: blake3.Hash

// The principal identifier of the machine itself. Only principal 0 can select
// a disk module for a role in the trusted path.
MACHINE_PRINCIPAL :: u64(0)

// The size of the stack buffer for canonical encoding of a role contract.
CANONICAL_BUFFER_CAPACITY :: 4096

// Domain separator prefix written at the start of every canonical contract
// encoding so contract hashes cannot collide with module hashes or other blobs.
CANONICAL_DOMAIN_TAG :: "MODUS_ROLE_CONTRACT_V1"

// The closed list of system roles. Explicit contract values cross rings and
// plans; zero means no role and is refused at the border.
Role :: enum u64 {
	None           = 0,
	Display        = 1,
	Input          = 2,
	Console        = 3,
	Assistive      = 4,
	Speech         = 5,
	Terminal       = 6,
	Start_Policy   = 7,
	Storage        = 8,
	Network        = 9,
	Block_Device   = 10,
	Network_Device = 11,
	Sound_Device   = 12,
	Entropy_Device = 13,
	Tpm            = 14,
	Remote_Display = 15,
	Plans          = 16,
	Projects       = 17,
	Recipes        = 18,
	Powerbox       = 19,
	Disk_Processes = 20,
	Principals     = 21,
	Devices        = 22,
	Settings       = 23,
}

// The scope within which a role has its holder (or holders, for Assistive).
Role_Scope :: enum u8 {
	None    = 0,
	Machine = 1,
	Session = 2,
	Client  = 3,
	Device  = 4,
}

// Whether a role sits on the trusted path of keys, trusted surfaces, or
// window inspection.
Trust_Path_Class :: enum u8 {
	None         = 0,
	Ordinary     = 1,
	Trusted_Path = 2,
}

// The kind of interface face that a role contract requires from its holder.
Face_Kind :: enum u8 {
	None          = 0,
	Exports       = 1,
	Ring          = 2,
	Record_Stream = 3,
}

// The fixed properties of one role.
Role_Properties :: struct {
	scope:                   Role_Scope,
	trust_path:              Trust_Path_Class,
	allows_multiple_holders: bool,
	name:                    string,
}

// Why canonical encoding or contract conformance checking refused a contract
// or a candidate module.
Contract_Check_Refusal :: enum u8 {
	None                  = 0,
	Malformed_Contract    = 1,
	Unknown_Face_Kind     = 2,
	Malformed_Module      = 3,
	Undeclared_Contract   = 4,
	Hash_Mismatch         = 5,
	Missing_Export        = 6,
	Wrong_Signature       = 7,
	Missing_Ring_Face     = 8,
	Ring_Face_Mismatch    = 9,
	Missing_Record_Stream = 10,
	Wrong_Record_Stream   = 11,
}

// One required parameter of a required export in a role contract.
Required_Parameter :: struct {
	type:        module.Type,
	direction:   module.Direction,
	detail:      u32,
	record_name: string, // A Record or a Table: the name of its record; an Enum: the name of its enum type.
	optional:    bool, // A call may leave it out: its need is Optional.
	// An Integer setter parameter: the range that the file of the holder
	// gives in its table Parameter_Settings, from the constants of the
	// contract (src/md/features/module_settings.md).
	has_range:   bool,
	least:       i64,
	most:        i64,
}

// One required export of an Exports face in a role contract.
Required_Export :: struct {
	name:               string,
	parameters:         []Required_Parameter,
	result:             module.Type,
	result_record_name: string,
	has_error_record:   bool,
	error_record_name:  string,
}

// One required shared-memory ring face in a role contract.
Required_Ring_Face :: struct {
	name:             string,
	command_count:    u32,
	event_count:      u32,
	carries_handles:  bool,
	handle_rights:    u32,
	protocol_version: u32,
}

// One required record output or record input in a role contract.
Required_Record_Stream :: struct {
	name:        string,
	is_input:    bool,
	record_name: string,
}

// One face required by a role contract.
Required_Face :: struct {
	kind:          Face_Kind,
	name:          string,
	exports:       []Required_Export,
	ring_face:     Required_Ring_Face,
	record_stream: Required_Record_Stream,
}

// Canonical description of a role contract. The version orders versions for a
// reader; the BLAKE3 hash of the canonical encoding decides every check.
Role_Contract :: struct {
	role:    Role,
	version: u32,
	faces:   []Required_Face,
}

// The role contract claims carried alongside a module's binary tables: the
// hashes of contracts the author claims to fill, and the ring faces it serves.
Module_Role_Declaration :: struct {
	contract_hashes: []Contract_Hash,
	ring_faces:      []Required_Ring_Face,
}

// Detailed outcome of checking a module against a role contract.
Contract_Check_Result :: struct {
	refusal:       Contract_Check_Refusal,
	difference:    module.Difference,
	face_index:    u32,
	export_index:  u32,
	parameter:     u32,
	expected_hash: Contract_Hash,
}

// role_from_word converts a transport word into a Role. Zero and every word
// outside the closed enum are refused.
role_from_word :: proc "contextless" (word: u64) -> (role: Role, ok: bool) {
	member := enum_word.member_of_word(Role, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// role_scope_from_word converts a transport word into a Role_Scope, refusing
// zero and every unknown word.
role_scope_from_word :: proc "contextless" (word: u64) -> (scope: Role_Scope, ok: bool) {
	member := enum_word.member_of_word(Role_Scope, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// trust_path_class_from_word converts a transport word into a Trust_Path_Class,
// refusing zero and every unknown word.
trust_path_class_from_word :: proc "contextless" (word: u64) -> (class: Trust_Path_Class, ok: bool) {
	member := enum_word.member_of_word(Trust_Path_Class, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// face_kind_from_word converts a transport word into a Face_Kind, refusing
// zero and every unknown word.
face_kind_from_word :: proc "contextless" (word: u64) -> (kind: Face_Kind, ok: bool) {
	member := enum_word.member_of_word(Face_Kind, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// role_properties returns the scope, trust class, multiplicity rule, and
// canonical name for a Role. Only Assistive permits multiple holders in one
// scope; only Display, Input, Console, Assistive, and Powerbox are in the
// trusted path.
role_properties :: proc "contextless" (role: Role) -> Role_Properties {
	switch role {
	case .None:
		return {}
	case .Display:
		return {scope = .Machine, trust_path = .Trusted_Path, allows_multiple_holders = false, name = "display"}
	case .Input:
		return {scope = .Machine, trust_path = .Trusted_Path, allows_multiple_holders = false, name = "input"}
	case .Console:
		return {scope = .Session, trust_path = .Trusted_Path, allows_multiple_holders = false, name = "console"}
	case .Assistive:
		return {scope = .Machine, trust_path = .Trusted_Path, allows_multiple_holders = true, name = "assistive"}
	case .Speech:
		return {scope = .Machine, trust_path = .Ordinary, allows_multiple_holders = false, name = "speech"}
	case .Terminal:
		return {scope = .Client, trust_path = .Ordinary, allows_multiple_holders = false, name = "terminal"}
	case .Start_Policy:
		return {scope = .Machine, trust_path = .Ordinary, allows_multiple_holders = false, name = "start_policy"}
	case .Storage:
		return {scope = .Machine, trust_path = .Ordinary, allows_multiple_holders = false, name = "storage"}
	case .Network:
		return {scope = .Machine, trust_path = .Ordinary, allows_multiple_holders = false, name = "network"}
	case .Block_Device:
		return {scope = .Device, trust_path = .Ordinary, allows_multiple_holders = false, name = "block_device"}
	case .Network_Device:
		return {scope = .Device, trust_path = .Ordinary, allows_multiple_holders = false, name = "network_device"}
	case .Sound_Device:
		return {scope = .Device, trust_path = .Ordinary, allows_multiple_holders = false, name = "sound_device"}
	case .Entropy_Device:
		return {scope = .Device, trust_path = .Ordinary, allows_multiple_holders = false, name = "entropy_device"}
	case .Tpm:
		return {scope = .Device, trust_path = .Ordinary, allows_multiple_holders = false, name = "tpm"}
	case .Remote_Display:
		return {scope = .Machine, trust_path = .Ordinary, allows_multiple_holders = false, name = "remote_display"}
	case .Plans:
		return {scope = .Machine, trust_path = .Ordinary, allows_multiple_holders = false, name = "plans"}
	case .Projects:
		return {scope = .Machine, trust_path = .Ordinary, allows_multiple_holders = false, name = "projects"}
	case .Recipes:
		return {scope = .Machine, trust_path = .Ordinary, allows_multiple_holders = false, name = "recipes"}
	case .Powerbox:
		return {scope = .Machine, trust_path = .Trusted_Path, allows_multiple_holders = false, name = "powerbox"}
	case .Disk_Processes:
		return {scope = .Machine, trust_path = .Ordinary, allows_multiple_holders = false, name = "disk_processes"}
	case .Principals:
		return {scope = .Machine, trust_path = .Ordinary, allows_multiple_holders = false, name = "principals"}
	case .Devices:
		return {scope = .Machine, trust_path = .Ordinary, allows_multiple_holders = false, name = "devices"}
	case .Settings:
		return {scope = .Machine, trust_path = .Ordinary, allows_multiple_holders = false, name = "settings"}
	}
	return {}
}

// role_is_in_trusted_path reports whether a role handles trusted path input,
// trusted surfaces, or cross-window inspection.
role_is_in_trusted_path :: proc "contextless" (role: Role) -> bool {
	return role_properties(role).trust_path == .Trusted_Path
}

// role_allows_multiple_holders reports whether a role permits more than one
// holder in one scope.
role_allows_multiple_holders :: proc "contextless" (role: Role) -> bool {
	return role_properties(role).allows_multiple_holders
}

// disk_holder_allowed_for_principal reports whether the given principal may
// select a disk module to hold a role. Trusted-path roles accept a disk module
// only when chosen by principal 0.
disk_holder_allowed_for_principal :: proc "contextless" (role: Role, principal: u64) -> bool {
	props := role_properties(role)
	if props.scope == .None {
		return false
	}
	if props.trust_path == .Trusted_Path {
		return principal == MACHINE_PRINCIPAL
	}
	return true
}

@(private = "file")
Canonical_Writer :: struct {
	buffer:   []u8,
	position: int,
	overflow: bool,
}

@(private = "file")
writer_byte :: proc "contextless" (canonical_writer: ^Canonical_Writer, value: u8) {
	if canonical_writer.overflow || canonical_writer.position >= len(canonical_writer.buffer) {
		canonical_writer.overflow = true
		return
	}
	canonical_writer.buffer[canonical_writer.position] = value
	canonical_writer.position += 1
}

@(private = "file")
writer_u32 :: proc "contextless" (writer: ^Canonical_Writer, value: u32) {
	if writer.overflow || len(writer.buffer) - writer.position < 4 {
		writer.overflow = true
		return
	}
	byte_order.write_u32_little_endian(writer.buffer, writer.position, value)
	writer.position += 4
}

@(private = "file")
writer_u64 :: proc "contextless" (writer: ^Canonical_Writer, value: u64) {
	if writer.overflow || len(writer.buffer) - writer.position < 8 {
		writer.overflow = true
		return
	}
	byte_order.write_u64_little_endian(writer.buffer, writer.position, value)
	writer.position += 8
}

@(private = "file")
writer_bytes :: proc "contextless" (canonical_writer: ^Canonical_Writer, text: string) {
	writer_u32(canonical_writer, u32(len(text)))
	if canonical_writer.overflow || len(canonical_writer.buffer) - canonical_writer.position < len(text) {
		canonical_writer.overflow = true
		return
	}
	for index in 0 ..< len(text) {
		canonical_writer.buffer[canonical_writer.position + index] = text[index]
	}
	canonical_writer.position += len(text)
}

// canonical_encode writes the deterministic canonical byte representation of a
// role contract into buffer. It validates every enum word and structural
// constraint so two different contracts cannot produce the same bytes.
canonical_encode :: proc "contextless" (contract: Role_Contract, buffer: []u8) -> (written: int, refusal: Contract_Check_Refusal) {
	role, role_ok := role_from_word(u64(contract.role))
	if !role_ok || contract.version == 0 || len(contract.faces) == 0 {
		return 0, .Malformed_Contract
	}
	writer := Canonical_Writer{buffer = buffer}
	writer_bytes(&writer, CANONICAL_DOMAIN_TAG)
	writer_u64(&writer, u64(role))
	writer_u32(&writer, contract.version)
	writer_u32(&writer, u32(len(contract.faces)))

	for face, face_index in contract.faces {
		kind, kind_ok := face_kind_from_word(u64(face.kind))
		if !kind_ok {
			return 0, .Unknown_Face_Kind
		}
		if len(face.name) == 0 {
			return 0, .Malformed_Contract
		}
		for earlier in contract.faces[:face_index] {
			if earlier.name == face.name {
				return 0, .Malformed_Contract
			}
		}
		writer_byte(&writer, u8(kind))
		writer_bytes(&writer, face.name)
		switch kind {
		case .None:
			return 0, .Unknown_Face_Kind
		case .Exports:
			if len(face.exports) == 0 {
				return 0, .Malformed_Contract
			}
			writer_u32(&writer, u32(len(face.exports)))
			for required_export, export_index in face.exports {
				if len(required_export.name) == 0 || len(required_export.parameters) > module.PARAMETER_CAPACITY {
					return 0, .Malformed_Contract
				}
				for earlier_export in face.exports[:export_index] {
					if earlier_export.name == required_export.name {
						return 0, .Malformed_Contract
					}
				}
				result_type, result_ok := module.type_of_word(u8(required_export.result))
				if !result_ok {
					return 0, .Malformed_Contract
				}
				words := len(required_export.parameters)
				for parameter in required_export.parameters {
					words += parameter.optional ? 1 : 0
				}
				if len(required_export.parameters) > module.PARAMETER_CAPACITY || module.call_argument_count(words, u8(result_type), required_export.has_error_record) > module.CALL_WORD_CAPACITY {
					return 0, .Malformed_Contract
				}
				writer_bytes(&writer, required_export.name)
				writer_byte(&writer, u8(result_type))
				writer_bytes(&writer, required_export.result_record_name)
				writer_byte(&writer, required_export.has_error_record ? 1 : 0)
				writer_bytes(&writer, required_export.error_record_name)
				writer_u32(&writer, u32(len(required_export.parameters)))
				for parameter in required_export.parameters {
					parameter_type, parameter_type_ok := module.type_of_word(u8(parameter.type))
					direction, direction_ok := enum_word.member_of_word(module.Direction, u64(parameter.direction))
					if !parameter_type_ok || !direction_ok || parameter_type == .None {
						return 0, .Malformed_Contract
					}
					if parameter_type != .Table && parameter_type != .Bytes && direction != .Read {
						return 0, .Malformed_Contract
					}
					writer_byte(&writer, u8(parameter_type))
					writer_byte(&writer, u8(direction))
					writer_u32(&writer, parameter.detail)
					writer_bytes(&writer, parameter.record_name)
					writer_byte(&writer, parameter.optional ? 1 : 0)
					writer_byte(&writer, parameter.has_range ? 1 : 0)
					writer_u64(&writer, cast(u64)parameter.least)
					writer_u64(&writer, cast(u64)parameter.most)
				}
			}
		case .Ring:
			ring_face := face.ring_face
			if len(ring_face.name) == 0 || (ring_face.command_count == 0 && ring_face.event_count == 0) || ring_face.protocol_version == 0 {
				return 0, .Malformed_Contract
			}
			if !ring_face.carries_handles && ring_face.handle_rights != 0 {
				return 0, .Malformed_Contract
			}
			writer_bytes(&writer, ring_face.name)
			writer_u32(&writer, ring_face.command_count)
			writer_u32(&writer, ring_face.event_count)
			writer_byte(&writer, ring_face.carries_handles ? 1 : 0)
			writer_u32(&writer, ring_face.handle_rights)
			writer_u32(&writer, ring_face.protocol_version)
		case .Record_Stream:
			stream := face.record_stream
			if len(stream.name) == 0 {
				return 0, .Malformed_Contract
			}
			writer_bytes(&writer, stream.name)
			writer_byte(&writer, stream.is_input ? 1 : 0)
			writer_bytes(&writer, stream.record_name)
		}
	}
	if writer.overflow {
		return 0, .Malformed_Contract
	}
	return writer.position, .None
}

// contract_hash computes the deterministic BLAKE3 digest of a role contract's
// canonical description bytes.
contract_hash :: proc "contextless" (contract: Role_Contract) -> (hash: Contract_Hash, ok: bool) {
	buffer: [CANONICAL_BUFFER_CAPACITY]u8
	written, refusal := canonical_encode(contract, buffer[:])
	if refusal != .None {
		return {}, false
	}
	return blake3.hash(buffer[:written]), true
}

@(private = "file")
check_export_signature :: proc "contextless" (module_bytes: []u8, required: Required_Export) -> (refusal: Contract_Check_Refusal, difference: module.Difference, parameter: u32) {
	export_index := module.export_find(module_bytes, required.name)
	if export_index == 0 {
		return .Missing_Export, .Missing_Export, 0
	}
	described, function_ok := module.function(module_bytes, export_index)
	if !function_ok {
		return .Malformed_Module, .None, 0
	}
	if int(described.parameter_count) != len(required.parameters) {
		return .Wrong_Signature, .Parameter_Count, 0
	}
	for index in 0 ..< len(required.parameters) {
		expected := required.parameters[index]
		found_type, type_ok := module.function_parameter_type(described, index)
		if !type_ok {
			return .Malformed_Module, .None, u32(index + 1)
		}
		if found_type != expected.type {
			return .Wrong_Signature, .Parameter_Type, u32(index + 1)
		}
		found_direction, direction_ok := enum_word.member_of_word(module.Direction, u64(described.parameter_directions[index]))
		if !direction_ok {
			return .Malformed_Module, .None, u32(index + 1)
		}
		if found_direction != expected.direction {
			return .Wrong_Signature, .Parameter_Direction, u32(index + 1)
		}
		if module.parameter_optional(described, index) != expected.optional {
			return .Wrong_Signature, .Parameter_Detail, u32(index + 1)
		}
		setting, has_setting := module.parameter_setting(module_bytes, export_index, index)
		found_range := has_setting && setting.has_range
		if found_range != expected.has_range || found_range && (setting.least != expected.least || setting.most != expected.most) {
			return .Wrong_Signature, .Parameter_Range, u32(index + 1)
		}
		if found_type == .Record || found_type == .Table {
			record_description, record_ok := module.record_type(module_bytes, described.parameter_details[index])
			if !record_ok {
				return .Malformed_Module, .None, u32(index + 1)
			}
			if len(expected.record_name) > 0 && module.string_at(module_bytes, record_description.name_offset, record_description.name_count) != expected.record_name {
				return .Wrong_Signature, .Parameter_Detail, u32(index + 1)
			}
		} else if found_type == .Enum {
			// The detail of an Enum parameter holds indexes of the module
			// itself (its enum and its getter): two holders of one role
			// number them as they like. The contract names the enum.
			enum_index, _ := module.enum_detail_of(described.parameter_details[index])
			enum_description, enum_problem := module.enum_type(module_bytes, enum_index)
			if enum_problem != .None {
				return .Malformed_Module, .None, u32(index + 1)
			}
			if len(expected.record_name) > 0 && module.string_at(module_bytes, enum_description.name_offset, enum_description.name_count) != expected.record_name {
				return .Wrong_Signature, .Parameter_Detail, u32(index + 1)
			}
		} else if described.parameter_details[index] != expected.detail {
			return .Wrong_Signature, .Parameter_Detail, u32(index + 1)
		}
	}
	found_result, result_ok := module.function_result_type(described)
	if !result_ok {
		return .Malformed_Module, .None, 0
	}
	if found_result != required.result {
		return .Wrong_Signature, .Result_Type, 0
	}
	if found_result == .Record || found_result == .Table {
		record_description, record_ok := module.record_type(module_bytes, described.result_detail)
		if !record_ok {
			return .Malformed_Module, .None, 0
		}
		if len(required.result_record_name) > 0 && module.string_at(module_bytes, record_description.name_offset, record_description.name_count) != required.result_record_name {
			return .Wrong_Signature, .Result_Detail, 0
		}
	}
	has_error := described.error_record != 0
	if has_error != required.has_error_record {
		return .Wrong_Signature, .Error_Record, 0
	}
	if has_error {
		error_description, error_ok := module.record_type(module_bytes, described.error_record)
		if !error_ok {
			return .Malformed_Module, .None, 0
		}
		if len(required.error_record_name) > 0 && module.string_at(module_bytes, error_description.name_offset, error_description.name_count) != required.error_record_name {
			return .Wrong_Signature, .Error_Record, 0
		}
	}
	return .None, .None, 0
}

@(private = "file")
check_ring_face :: proc "contextless" (declared_rings: []Required_Ring_Face, required: Required_Ring_Face) -> Contract_Check_Refusal {
	for candidate in declared_rings {
		if candidate.name != required.name {
			continue
		}
		if candidate.command_count != required.command_count ||
			candidate.event_count != required.event_count ||
			candidate.carries_handles != required.carries_handles ||
			candidate.handle_rights != required.handle_rights ||
			candidate.protocol_version != required.protocol_version {
			return .Ring_Face_Mismatch
		}
		return .None
	}
	return .Missing_Ring_Face
}

@(private = "file")
check_record_stream_face :: proc "contextless" (module_bytes: []u8, required: Required_Record_Stream) -> Contract_Check_Refusal {
	if required.is_input {
		total := module.count(module_bytes, .Record_Inputs)
		for index in u32(1) ..< total {
			row, _, description, _, ok := module.record_input(module_bytes, index)
			if !ok {
				return .Malformed_Module
			}
			if module.string_at(module_bytes, row.name_offset, row.name_count) != required.name {
				continue
			}
			if len(required.record_name) == 0 {
				return row.record == 0 ? .None : .Wrong_Record_Stream
			}
			if row.record == 0 {
				return .Wrong_Record_Stream
			}
			if module.string_at(module_bytes, description.name_offset, description.name_count) != required.record_name {
				return .Wrong_Record_Stream
			}
			return .None
		}
		return .Missing_Record_Stream
	}
	total := module.count(module_bytes, .Record_Outputs)
	for index in u32(1) ..< total {
		row, _, description, ok := module.record_output(module_bytes, index)
		if !ok {
			return .Malformed_Module
		}
		if module.string_at(module_bytes, row.name_offset, row.name_count) != required.name {
			continue
		}
		if len(required.record_name) == 0 {
			return row.record == 0 ? .None : .Wrong_Record_Stream
		}
		if row.record == 0 {
			return .Wrong_Record_Stream
		}
		if module.string_at(module_bytes, description.name_offset, description.name_count) != required.record_name {
			return .Wrong_Record_Stream
		}
		return .None
	}
	return .Missing_Record_Stream
}

// module_fills_contract verifies that a module file is structurally valid,
// declares filling the contract's BLAKE3 hash, and exposes every required
// export, ring face, and record stream with matching signatures and types.
// Extra exports or extra declared contracts on the module are permitted.
module_fills_contract :: proc "contextless" (module_bytes: []u8, declaration: Module_Role_Declaration, contract: Role_Contract) -> Contract_Check_Result {
	canonical_buffer: [CANONICAL_BUFFER_CAPACITY]u8
	written, encode_refusal := canonical_encode(contract, canonical_buffer[:])
	if encode_refusal != .None {
		return {refusal = encode_refusal}
	}
	expected_hash := blake3.hash(canonical_buffer[:written])

	if module.validate(module_bytes) != .None {
		return {refusal = .Malformed_Module, expected_hash = expected_hash}
	}
	if stream_fault, _ := module.record_streams_check(module_bytes); stream_fault != .None {
		return {refusal = .Malformed_Module, expected_hash = expected_hash}
	}

	if len(declaration.contract_hashes) == 0 {
		return {refusal = .Undeclared_Contract, expected_hash = expected_hash}
	}
	hash_declared := false
	for declared_hash in declaration.contract_hashes {
		if declared_hash != (Contract_Hash{}) && declared_hash == expected_hash {
			hash_declared = true
			break
		}
	}
	if !hash_declared {
		return {refusal = .Hash_Mismatch, expected_hash = expected_hash}
	}

	for face, face_index in contract.faces {
		kind, kind_ok := face_kind_from_word(u64(face.kind))
		if !kind_ok {
			return {refusal = .Unknown_Face_Kind, face_index = u32(face_index), expected_hash = expected_hash}
		}
		switch kind {
		case .None:
			return {refusal = .Unknown_Face_Kind, face_index = u32(face_index), expected_hash = expected_hash}
		case .Exports:
			for required_export, export_index in face.exports {
				refusal, difference, parameter := check_export_signature(module_bytes, required_export)
				if refusal != .None {
					return {
						refusal       = refusal,
						difference    = difference,
						face_index    = u32(face_index),
						export_index  = u32(export_index),
						parameter     = parameter,
						expected_hash = expected_hash,
					}
				}
			}
		case .Ring:
			if refusal := check_ring_face(declaration.ring_faces, face.ring_face); refusal != .None {
				return {refusal = refusal, face_index = u32(face_index), expected_hash = expected_hash}
			}
		case .Record_Stream:
			if refusal := check_record_stream_face(module_bytes, face.record_stream); refusal != .None {
				return {refusal = refusal, face_index = u32(face_index), expected_hash = expected_hash}
			}
		}
	}
	return {refusal = .None, expected_hash = expected_hash}
}
