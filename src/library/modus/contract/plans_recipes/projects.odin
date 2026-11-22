// Projects contract: pins.lex canonical formatting and strict parsing,
// unified source resolver-plus-fetch records, and project console
// specifications for projects.enter and exit (src/md/features/declarations.md).
//
// This is a contract package: it imports base and contract packages only,
// calls no kernel operation, and allocates no memory.
package plans_recipes

import "modus:contract/blake3"
import "modus:contract/enum_word"
import "modus:contract/object_cache"
import "modus:contract/powerbox"
import "modus:contract/text_encoding"

// Structural bounds on project pins, source resolver requests, and project consoles.
MAX_PROJECT_PINS :: 32
MAX_UPSTREAM_REF_BYTES :: 128
MAX_SOURCE_ADDRESS_BYTES :: 256
MAX_CONSOLE_MODULES :: 16
MAX_CONSOLE_STORES :: 8
MAX_PROJECT_CONSOLE_DEPTH :: 4
MAX_PINS_LEX_BYTES :: 16384
MAX_CONSOLE_CANONICAL_BYTES :: 4096

// Domain separation string for canonical project-console grant digests.
PROJECT_CONSOLE_HASH_DOMAIN :: "modus project console v1"

// Exact byte length of a Lex BLAKE3 hash literal: "blake3:" + 64 lowercase hex digits.
BLAKE3_LITERAL_PREFIX :: "blake3:"
BLAKE3_HEX_LENGTH :: blake3.HASH_SIZE * 2
BLAKE3_LITERAL_LENGTH :: len(BLAKE3_LITERAL_PREFIX) + BLAKE3_HEX_LENGTH

// Context slots for the delegated projects service.
PROJECTS_SERVICE_RING_SLOT :: 10
PROJECTS_SERVICE_REGION_SLOT :: 11
PROJECTS_CONTEXT_VALUE_DISPLAY_SLOT :: 0

#assert(BLAKE3_LITERAL_LENGTH == 71)

// Closed set of actions handled by a source module under the unified resolver
// and fetcher contract.
Source_Resolver_Action :: enum u8 {
	None    = 0,
	Resolve = 1,
	Fetch   = 2,
}

// Closed set of statuses returned by a source module resolver or fetcher.
Source_Resolver_Status :: enum u8 {
	None              = 0,
	Ok                = 1,
	Refused           = 2,
	Network_Denied    = 3,
	Hash_Mismatch     = 4,
	Signature_Invalid = 5,
	Not_Found         = 6,
}

// Closed set of refusal reasons for pins.lex, source resolution, and project consoles.
Project_Refusal :: enum u8 {
	None                  = 0,
	Invalid_Pin_Name      = 1,
	Zero_Hash             = 2,
	Duplicate_Pin         = 3,
	Too_Many_Pins         = 4,
	Invalid_Upstream_Ref  = 5,
	Buffer_Too_Small      = 6,
	Malformed_Syntax      = 7,
	Invalid_Hash_Literal  = 8,
	Unknown_Field         = 9,
	Missing_Field         = 10,
	Duplicate_Field       = 11,
	Trailing_Tokens       = 12,
	Bad_Resolver_Action   = 13,
	Bad_Resolver_Status   = 14,
	Invalid_Address       = 15,
	Host_Mismatch         = 16,
	Hash_Mismatch         = 17,
	Too_Many_Modules      = 18,
	Too_Many_Stores       = 19,
	Invalid_Module_Name   = 20,
	Duplicate_Module      = 21,
	Invalid_Store_Name    = 22,
	Duplicate_Store       = 23,
	Bad_Store_Rights      = 24,
	Undeclared_Store      = 25,
	Store_Rights_Exceeded = 26,
	Pin_Not_Found          = 27,
	Console_Limit_Reached  = 28,
	Unknown_Console        = 29,
	Empty_Console          = 30,
	Unknown_Project        = 31,
	Nesting_Depth_Exceeded = 32,
	No_Active_Console      = 33,
	Consent_Required       = 34,
	Untrusted_Consent      = 35,
	Child_Console_Active   = 36,
	Project_Limit_Reached  = 37,
	Bad_Evaluation         = 38,
	Evaluation_Refused     = 39,
	Not_A_Project          = 40,
	Store_Failed           = 41, // The private store did not take the write: the project and its pins did not change.
	Store_Damaged          = 42, // The project object of the private store does not decode, or names another project.
}

// Closed set of commands accepted on the projects service ring.
Projects_Ring_Command :: enum u32 {
	None          = 0,
	List_Inputs   = 1,
	Update_Pins   = 2,
	Enter_Project = 3,
	Exit_Project  = 4,
}

// One pinned declaration input recorded in pins.lex beside project.lex.
Pin_Entry :: struct {
	name_bytes:          [MAX_ENTRY_NAME_BYTES]u8,
	name_length:         u8,
	source_module_hash:  blake3.Hash,
	tree_hash:           blake3.Hash,
	upstream_ref_bytes:  [MAX_UPSTREAM_REF_BYTES]u8,
	upstream_ref_length: u16,
}

// Unified resolver-plus-fetch request sent to any source module
// (catalog.git.source, catalog.jj.source, catalog.archive.source, follow).
Source_Resolver_Request :: struct {
	action_word:         u64,
	input_name_bytes:    [MAX_ENTRY_NAME_BYTES]u8,
	input_name_length:   u8,
	source_module_hash:  blake3.Hash,
	address_bytes:       [MAX_SOURCE_ADDRESS_BYTES]u8,
	address_length:      u16,
	allowed_host_bytes:  [powerbox.MAX_HOST_BYTES]u8,
	allowed_host_length: u16,
	requested_ref_bytes: [MAX_UPSTREAM_REF_BYTES]u8,
	requested_ref_length: u16,
	expected_tree_hash:  blake3.Hash,
	publisher_public_key: [object_cache.PUBLIC_KEY_SIZE]u8,
	has_publisher_key:   bool,
}

// Unified resolver-plus-fetch response returned by a source module.
Source_Resolver_Response :: struct {
	status_word:         u64,
	source_module_hash:  blake3.Hash,
	resolved_tree_hash:  blake3.Hash,
	resolved_ref_bytes:  [MAX_UPSTREAM_REF_BYTES]u8,
	resolved_ref_length: u16,
	release_number:      u64,
	publisher_signature: [object_cache.SIGNATURE_SIZE]u8,
}

// One module connected when entering a project's child console.
Project_Console_Module :: struct {
	name_bytes:  [MAX_ENTRY_NAME_BYTES]u8,
	name_length: u8,
	module_hash: blake3.Hash,
}

// One store granted to a project's child console with attenuated rights.
Project_Console_Store :: struct {
	name_bytes:  [MAX_ENTRY_NAME_BYTES]u8,
	name_length: u8,
	rights_word: u64,
}

// Declarative specification for projects.enter(project): connects modules by
// hash and grants only stores the project explicitly names, leaving nothing
// installed globally and never modifying the principal's applied plan.
Project_Console_Spec :: struct {
	project_tree_hash: blake3.Hash,
	principal:         u64,
	parent_console_id: u64,
	module_count:      u32,
	modules:           [MAX_CONSOLE_MODULES]Project_Console_Module,
	store_count:       u32,
	stores:            [MAX_CONSOLE_STORES]Project_Console_Store,
}

// Itemized grants added beyond the caller's current console session when
// entering a project console. Any non-empty diff requires verified consent.
Project_Console_Grant_Diff :: struct {
	spec_hash:          blake3.Hash,
	added_module_count: u32,
	added_modules:      [MAX_CONSOLE_MODULES]Project_Console_Module,
	added_store_count:  u32,
	added_stores:       [MAX_CONSOLE_STORES]Project_Console_Store,
	needs_consent:      bool,
}

// Evaluated project declaration carrying its console field (or output builders
// and source store when the project omits the console field).
Project_Declaration :: struct {
	name_bytes:           [MAX_ENTRY_NAME_BYTES]u8,
	name_length:          u8,
	project_tree_hash:    blake3.Hash,
	has_console_field:    bool,
	console_module_count: u32,
	console_modules:      [MAX_CONSOLE_MODULES]Project_Console_Module,
	console_store_count:  u32,
	console_stores:       [MAX_CONSOLE_STORES]Project_Console_Store,
	builder_module_count: u32,
	builder_modules:      [MAX_CONSOLE_MODULES]Project_Console_Module,
	has_source_store:     bool,
	source_store_bytes:   [MAX_ENTRY_NAME_BYTES]u8,
	source_store_length:  u8,
}

// Single borders converting transport words into closed enum members.

source_resolver_action_of_word :: proc "contextless" (word: u64) -> (action: Source_Resolver_Action, ok: bool) {
	member := enum_word.member_of_word(Source_Resolver_Action, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

source_resolver_status_of_word :: proc "contextless" (word: u64) -> (status: Source_Resolver_Status, ok: bool) {
	member := enum_word.member_of_word(Source_Resolver_Status, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

projects_ring_command_of_word :: proc "contextless" (word: u32) -> (command: Projects_Ring_Command, ok: bool) {
	member := enum_word.member_of_word(Projects_Ring_Command, u64(word)) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// Reserved Lex words that may never appear as pin or module field names.
@(private = "file", rodata)
LEX_RESERVED_WORDS := [?]string{"let", "in", "with", "_", "if", "then", "else", "true", "false"}

// lex_field_name_valid checks that name is a legal ASCII Lex record field name:
// starts with [A-Za-z_], continues with [A-Za-z0-9_], is not a reserved Lex
// keyword, and contains no path separator or dot.
lex_field_name_valid :: proc "contextless" (bytes: []u8) -> bool {
	if len(bytes) == 0 || len(bytes) > MAX_ENTRY_NAME_BYTES {
		return false
	}
	first := bytes[0]
	first_ok := (first >= 'a' && first <= 'z') || (first >= 'A' && first <= 'Z') || first == '_'
	if !first_ok {
		return false
	}
	for item in bytes[1:] {
		char_ok := (item >= 'a' && item <= 'z') || (item >= 'A' && item <= 'Z') || (item >= '0' && item <= '9') || item == '_'
		if !char_ok {
			return false
		}
	}
	candidate := string(bytes)
	for reserved in LEX_RESERVED_WORDS {
		if candidate == reserved {
			return false
		}
	}
	return true
}

// upstream_ref_valid checks that ref bytes are non-control UTF-8 without quote
// or backslash characters so canonical pins.lex formatting cannot be escaped or
// injected.
upstream_ref_valid :: proc "contextless" (bytes: []u8) -> bool {
	if len(bytes) > MAX_UPSTREAM_REF_BYTES {
		return false
	}
	if len(bytes) == 0 {
		return true
	}
	if !text_encoding.text_valid(bytes) {
		return false
	}
	for item in bytes {
		if item == '"' || item == '\\' {
			return false
		}
	}
	return true
}

// pin_entry_make constructs a validated Pin_Entry with zero-padded fixed arrays.
pin_entry_make :: proc "contextless" (
	name: string,
	source_module_hash: blake3.Hash,
	tree_hash: blake3.Hash,
	upstream_ref: string = "",
) -> (entry: Pin_Entry, refusal: Project_Refusal) {
	name_raw := transmute([]u8)name
	if !lex_field_name_valid(name_raw) {
		return {}, .Invalid_Pin_Name
	}
	if hash_is_zero(source_module_hash) || hash_is_zero(tree_hash) {
		return {}, .Zero_Hash
	}
	ref_raw := transmute([]u8)upstream_ref
	if !upstream_ref_valid(ref_raw) {
		return {}, .Invalid_Upstream_Ref
	}
	copy(entry.name_bytes[:len(name_raw)], name_raw)
	entry.name_length = u8(len(name_raw))
	entry.source_module_hash = source_module_hash
	entry.tree_hash = tree_hash
	if len(ref_raw) > 0 {
		copy(entry.upstream_ref_bytes[:len(ref_raw)], ref_raw)
		entry.upstream_ref_length = u16(len(ref_raw))
	}
	return entry, .None
}

// pin_entry_validate checks all invariants of one Pin_Entry, including
// zero-padded tails past name_length and upstream_ref_length.
pin_entry_validate :: proc "contextless" (entry: ^Pin_Entry) -> Project_Refusal {
	if entry == nil {
		return .Invalid_Pin_Name
	}
	if int(entry.name_length) == 0 || int(entry.name_length) > MAX_ENTRY_NAME_BYTES {
		return .Invalid_Pin_Name
	}
	if !lex_field_name_valid(entry.name_bytes[:entry.name_length]) {
		return .Invalid_Pin_Name
	}
	for pad in entry.name_bytes[entry.name_length:] {
		if pad != 0 {
			return .Invalid_Pin_Name
		}
	}
	if hash_is_zero(entry.source_module_hash) || hash_is_zero(entry.tree_hash) {
		return .Zero_Hash
	}
	if int(entry.upstream_ref_length) > MAX_UPSTREAM_REF_BYTES {
		return .Invalid_Upstream_Ref
	}
	if !upstream_ref_valid(entry.upstream_ref_bytes[:entry.upstream_ref_length]) {
		return .Invalid_Upstream_Ref
	}
	for pad in entry.upstream_ref_bytes[entry.upstream_ref_length:] {
		if pad != 0 {
			return .Invalid_Upstream_Ref
		}
	}
	return .None
}

@(private = "file", rodata)
LOWER_HEX_DIGITS := [16]u8{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'}

@(private = "file")
encoder_blake3_literal :: proc "contextless" (encoder: ^Canonical_Encoder, hash: blake3.Hash) {
	prefix := BLAKE3_LITERAL_PREFIX
	encoder_raw_bytes(encoder, transmute([]u8)prefix)
	hex_pair: [2]u8
	for value in hash {
		hex_pair[0] = LOWER_HEX_DIGITS[value >> 4]
		hex_pair[1] = LOWER_HEX_DIGITS[value & 0x0F]
		encoder_raw_bytes(encoder, hex_pair[:])
	}
}

@(private = "file")
hex_nibble_lowercase :: proc "contextless" (character: u8) -> (nibble: u8, ok: bool) {
	if character >= '0' && character <= '9' {
		return character - '0', true
	}
	if character >= 'a' && character <= 'f' {
		return 10 + (character - 'a'), true
	}
	return 0, false
}

// blake3_literal_parse parses an exact 71-byte "blake3:<64 lowercase hex>"
// literal and refuses uppercase hex, wrong length, or all-zero digests.
blake3_literal_parse :: proc "contextless" (bytes: []u8) -> (hash: blake3.Hash, refusal: Project_Refusal) {
	prefix := BLAKE3_LITERAL_PREFIX
	if len(bytes) != BLAKE3_LITERAL_LENGTH {
		return {}, .Invalid_Hash_Literal
	}
	for index in 0 ..< len(prefix) {
		if bytes[index] != prefix[index] {
			return {}, .Invalid_Hash_Literal
		}
	}
	hex_bytes := bytes[len(prefix):]
	for byte_index in 0 ..< blake3.HASH_SIZE {
		high, high_ok := hex_nibble_lowercase(hex_bytes[byte_index * 2])
		low, low_ok := hex_nibble_lowercase(hex_bytes[byte_index * 2 + 1])
		if !high_ok || !low_ok {
			return {}, .Invalid_Hash_Literal
		}
		hash[byte_index] = (high << 4) | low
	}
	if hash_is_zero(hash) {
		return {}, .Zero_Hash
	}
	return hash, .None
}

// pins_lex_format formats pins into canonical deterministic Lex record syntax
// sorted strictly by input name:
//
//   {
//     alpha = { tree = blake3:<64hex>, source = blake3:<64hex> },
//     beta = { tree = blake3:<64hex>, source = blake3:<64hex>, ref = "..." },
//   }
//
// All pins are validated and required length is checked before writing any
// byte to output, so a refused call leaves output untouched.
pins_lex_format :: proc "contextless" (pins: []Pin_Entry, output: []u8) -> (written: int, refusal: Project_Refusal) {
	if len(pins) > MAX_PROJECT_PINS {
		return 0, .Too_Many_Pins
	}

	for index in 0 ..< len(pins) {
		pin := pins[index]
		if pin_refusal := pin_entry_validate(&pin); pin_refusal != .None {
			return 0, pin_refusal
		}
		for earlier in 0 ..< index {
			prev := pins[earlier]
			if bytes_equal(prev.name_bytes[:prev.name_length], pin.name_bytes[:pin.name_length]) {
				return 0, .Duplicate_Pin
			}
		}
	}

	// Sort indices strictly by UTF-8 byte order of pin name.
	order: [MAX_PROJECT_PINS]int
	for index in 0 ..< len(pins) {
		order[index] = index
	}
	for i in 1 ..< len(pins) {
		key_index := order[i]
		key_name := pins[key_index].name_bytes[:pins[key_index].name_length]
		j := i - 1
		for j >= 0 {
			cur := pins[order[j]]
			if compare_bytes(cur.name_bytes[:cur.name_length], key_name) <= 0 {
				break
			}
			order[j + 1] = order[j]
			j -= 1
		}
		order[j + 1] = key_index
	}

	// Compute exact byte length first so output stays untouched on Buffer_Too_Small.
	required := 4 // "{\n}\n"
	for pos in 0 ..< len(pins) {
		pin := pins[order[pos]]
		// "  <name> = { tree = <71>, source = <71> },\n"
		line_len := 2 + int(pin.name_length) + len(" = { tree = ") + BLAKE3_LITERAL_LENGTH + len(", source = ") + BLAKE3_LITERAL_LENGTH + len(" },\n")
		if pin.upstream_ref_length > 0 {
			line_len += len(", ref = \"\"") + int(pin.upstream_ref_length)
		}
		required += line_len
	}
	if required > MAX_PINS_LEX_BYTES || len(output) < required {
		return 0, .Buffer_Too_Small
	}

	encoder := Canonical_Encoder{buffer = output}
	encoder_raw_bytes(&encoder, transmute([]u8)string("{\n"))
	for pos in 0 ..< len(pins) {
		pin := pins[order[pos]]
		encoder_raw_bytes(&encoder, transmute([]u8)string("  "))
		encoder_raw_bytes(&encoder, pin.name_bytes[:pin.name_length])
		encoder_raw_bytes(&encoder, transmute([]u8)string(" = { tree = "))
		encoder_blake3_literal(&encoder, pin.tree_hash)
		encoder_raw_bytes(&encoder, transmute([]u8)string(", source = "))
		encoder_blake3_literal(&encoder, pin.source_module_hash)
		if pin.upstream_ref_length > 0 {
			encoder_raw_bytes(&encoder, transmute([]u8)string(", ref = \""))
			encoder_raw_bytes(&encoder, pin.upstream_ref_bytes[:pin.upstream_ref_length])
			encoder_byte(&encoder, '"')
		}
		encoder_raw_bytes(&encoder, transmute([]u8)string(" },\n"))
	}
	encoder_raw_bytes(&encoder, transmute([]u8)string("}\n"))
	if encoder.overflow {
		return 0, .Buffer_Too_Small
	}
	return encoder.position, .None
}

@(private = "file")
Lex_Scanner :: struct {
	bytes:  []u8,
	offset: int,
}

@(private = "file")
scanner_skip_ws_and_comments :: proc "contextless" (scanner: ^Lex_Scanner) -> bool {
	for scanner.offset < len(scanner.bytes) {
		ch := scanner.bytes[scanner.offset]
		if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' {
			scanner.offset += 1
			continue
		}
		if ch == '/' && scanner.offset + 1 < len(scanner.bytes) && scanner.bytes[scanner.offset + 1] == '/' {
			scanner.offset += 2
			for scanner.offset < len(scanner.bytes) && scanner.bytes[scanner.offset] != '\n' {
				if scanner.bytes[scanner.offset] == 0 {
					return false
				}
				scanner.offset += 1
			}
			continue
		}
		if ch < 0x20 || ch == 0x7F {
			return false
		}
		break
	}
	return true
}

@(private = "file")
scanner_consume_byte :: proc "contextless" (scanner: ^Lex_Scanner, expected: u8) -> bool {
	if !scanner_skip_ws_and_comments(scanner) {
		return false
	}
	if scanner.offset >= len(scanner.bytes) || scanner.bytes[scanner.offset] != expected {
		return false
	}
	scanner.offset += 1
	return true
}

@(private = "file")
scanner_read_token :: proc "contextless" (scanner: ^Lex_Scanner) -> (token: []u8, ok: bool) {
	if !scanner_skip_ws_and_comments(scanner) || scanner.offset >= len(scanner.bytes) {
		return nil, false
	}
	start := scanner.offset
	for scanner.offset < len(scanner.bytes) {
		ch := scanner.bytes[scanner.offset]
		if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == '=' || ch == '{' || ch == '}' || ch == ',' || ch == '"' {
			break
		}
		scanner.offset += 1
	}
	if scanner.offset == start {
		return nil, false
	}
	return scanner.bytes[start:scanner.offset], true
}

@(private = "file")
scanner_read_quoted_string :: proc "contextless" (scanner: ^Lex_Scanner) -> (content: []u8, ok: bool) {
	if !scanner_consume_byte(scanner, '"') {
		return nil, false
	}
	start := scanner.offset
	for scanner.offset < len(scanner.bytes) {
		ch := scanner.bytes[scanner.offset]
		if ch == '"' {
			slice := scanner.bytes[start:scanner.offset]
			scanner.offset += 1
			return slice, true
		}
		if ch == '\\' || ch == '\n' || ch == '\r' || ch < 0x20 || ch == 0x7F {
			return nil, false
		}
		scanner.offset += 1
	}
	return nil, false
}

// pins_lex_parse strictly parses canonical Lex pin syntax into out_pins (sorted
// by name). Refuses malformed syntax, duplicate pin names, duplicate or unknown
// fields, missing tree or source hashes, uppercase or malformed blake3 literals,
// zero hashes, path traversal or reserved keywords as names, and trailing tokens.
pins_lex_parse :: proc "contextless" (text: []u8, out_pins: []Pin_Entry) -> (count: int, refusal: Project_Refusal) {
	if len(text) == 0 || len(text) > MAX_PINS_LEX_BYTES {
		return 0, .Malformed_Syntax
	}
	// Reject NUL bytes anywhere in input.
	for item in text {
		if item == 0 {
			return 0, .Malformed_Syntax
		}
	}

	scanner := Lex_Scanner{bytes = text, offset = 0}
	if !scanner_consume_byte(&scanner, '{') {
		return 0, .Malformed_Syntax
	}

	parsed: [MAX_PROJECT_PINS]Pin_Entry
	parsed_count := 0

	for {
		if !scanner_skip_ws_and_comments(&scanner) {
			return 0, .Malformed_Syntax
		}
		if scanner.offset >= len(scanner.bytes) {
			return 0, .Malformed_Syntax
		}
		if scanner.bytes[scanner.offset] == '}' {
			scanner.offset += 1
			break
		}

		pin_name_token, name_ok := scanner_read_token(&scanner)
		if !name_ok {
			return 0, .Malformed_Syntax
		}
		if !lex_field_name_valid(pin_name_token) {
			return 0, .Invalid_Pin_Name
		}
		if !scanner_consume_byte(&scanner, '=') {
			return 0, .Malformed_Syntax
		}
		if !scanner_consume_byte(&scanner, '{') {
			return 0, .Malformed_Syntax
		}

		has_tree := false
		has_source := false
		has_ref := false
		tree_digest: blake3.Hash
		source_digest: blake3.Hash
		ref_slice: []u8

		for {
			if !scanner_skip_ws_and_comments(&scanner) {
				return 0, .Malformed_Syntax
			}
			if scanner.offset >= len(scanner.bytes) {
				return 0, .Malformed_Syntax
			}
			if scanner.bytes[scanner.offset] == '}' {
				scanner.offset += 1
				break
			}

			field_token, field_ok := scanner_read_token(&scanner)
			if !field_ok {
				return 0, .Malformed_Syntax
			}
			if !scanner_consume_byte(&scanner, '=') {
				return 0, .Malformed_Syntax
			}

			field_name := string(field_token)
			switch field_name {
			case "tree":
				if has_tree {
					return 0, .Duplicate_Field
				}
				val_token, val_ok := scanner_read_token(&scanner)
				if !val_ok {
					return 0, .Invalid_Hash_Literal
				}
				digest, hash_refusal := blake3_literal_parse(val_token)
				if hash_refusal != .None {
					return 0, hash_refusal
				}
				tree_digest = digest
				has_tree = true
			case "source":
				if has_source {
					return 0, .Duplicate_Field
				}
				val_token, val_ok := scanner_read_token(&scanner)
				if !val_ok {
					return 0, .Invalid_Hash_Literal
				}
				digest, hash_refusal := blake3_literal_parse(val_token)
				if hash_refusal != .None {
					return 0, hash_refusal
				}
				source_digest = digest
				has_source = true
			case "ref":
				if has_ref {
					return 0, .Duplicate_Field
				}
				str_bytes, str_ok := scanner_read_quoted_string(&scanner)
				if !str_ok || !upstream_ref_valid(str_bytes) {
					return 0, .Invalid_Upstream_Ref
				}
				ref_slice = str_bytes
				has_ref = true
			case:
				return 0, .Unknown_Field
			}

			if !scanner_skip_ws_and_comments(&scanner) {
				return 0, .Malformed_Syntax
			}
			if scanner.offset >= len(scanner.bytes) {
				return 0, .Malformed_Syntax
			}
			if scanner.bytes[scanner.offset] == ',' {
				scanner.offset += 1
				continue
			}
			if scanner.bytes[scanner.offset] == '}' {
				scanner.offset += 1
				break
			}
			return 0, .Malformed_Syntax
		}

		if !has_tree || !has_source {
			return 0, .Missing_Field
		}

		for earlier in 0 ..< parsed_count {
			prev := &parsed[earlier]
			if bytes_equal(prev.name_bytes[:prev.name_length], pin_name_token) {
				return 0, .Duplicate_Pin
			}
		}
		if parsed_count >= MAX_PROJECT_PINS {
			return 0, .Too_Many_Pins
		}

		entry := Pin_Entry {
			name_length         = u8(len(pin_name_token)),
			source_module_hash  = source_digest,
			tree_hash           = tree_digest,
			upstream_ref_length = u16(len(ref_slice)),
		}
		copy(entry.name_bytes[:len(pin_name_token)], pin_name_token)
		if len(ref_slice) > 0 {
			copy(entry.upstream_ref_bytes[:len(ref_slice)], ref_slice)
		}
		parsed[parsed_count] = entry
		parsed_count += 1

		if !scanner_skip_ws_and_comments(&scanner) {
			return 0, .Malformed_Syntax
		}
		if scanner.offset >= len(scanner.bytes) {
			return 0, .Malformed_Syntax
		}
		if scanner.bytes[scanner.offset] == ',' {
			scanner.offset += 1
			continue
		}
		if scanner.bytes[scanner.offset] == '}' {
			scanner.offset += 1
			break
		}
		return 0, .Malformed_Syntax
	}

	if !scanner_skip_ws_and_comments(&scanner) {
		return 0, .Malformed_Syntax
	}
	if scanner.offset != len(scanner.bytes) {
		return 0, .Trailing_Tokens
	}
	if parsed_count > len(out_pins) {
		return 0, .Buffer_Too_Small
	}

	// Sort parsed pins canonically by name before writing out_pins.
	for i in 1 ..< parsed_count {
		key := parsed[i]
		key_name := key.name_bytes[:key.name_length]
		j := i - 1
		for j >= 0 && compare_bytes(parsed[j].name_bytes[:parsed[j].name_length], key_name) > 0 {
			parsed[j + 1] = parsed[j]
			j -= 1
		}
		parsed[j + 1] = key
	}
	for index in 0 ..< parsed_count {
		out_pins[index] = parsed[index]
	}
	return parsed_count, .None
}

// extract_address_host returns the host portion of an "https://host/..." or
// "http://host/..." address (stripping optional :port) for host-grant matching.
@(private = "file")
extract_address_host :: proc "contextless" (address: []u8) -> (host: []u8, ok: bool) {
	rest := address
	https_prefix := transmute([]u8)string("https://")
	http_prefix := transmute([]u8)string("http://")
	if len(rest) > len(https_prefix) && bytes_equal(rest[:len(https_prefix)], https_prefix) {
		rest = rest[len(https_prefix):]
	} else if len(rest) > len(http_prefix) && bytes_equal(rest[:len(http_prefix)], http_prefix) {
		rest = rest[len(http_prefix):]
	} else {
		return nil, false
	}
	end := 0
	for end < len(rest) && rest[end] != '/' && rest[end] != ':' && rest[end] != '?' {
		end += 1
	}
	if end == 0 {
		return nil, false
	}
	return rest[:end], true
}

@(private = "file")
ascii_lower_byte :: proc "contextless" (value: u8) -> u8 {
	if value >= 'A' && value <= 'Z' {
		return value + ('a' - 'A')
	}
	return value
}

@(private = "file")
hosts_equal_case_insensitive :: proc "contextless" (first, second: []u8) -> bool {
	if len(first) != len(second) {
		return false
	}
	for index in 0 ..< len(first) {
		if ascii_lower_byte(first[index]) != ascii_lower_byte(second[index]) {
			return false
		}
	}
	return true
}

// source_resolver_request_validate validates a unified resolver-plus-fetch
// request at the border. Ensures network grants cover ONLY the address host,
// and Fetch requests always carry an expected_tree_hash in advance.
source_resolver_request_validate :: proc "contextless" (request: ^Source_Resolver_Request) -> Project_Refusal {
	if request == nil {
		return .Bad_Resolver_Action
	}
	action, action_ok := source_resolver_action_of_word(request.action_word)
	if !action_ok {
		return .Bad_Resolver_Action
	}
	if int(request.input_name_length) == 0 || int(request.input_name_length) > MAX_ENTRY_NAME_BYTES || !lex_field_name_valid(request.input_name_bytes[:request.input_name_length]) {
		return .Invalid_Pin_Name
	}
	if hash_is_zero(request.source_module_hash) {
		return .Zero_Hash
	}
	if int(request.address_length) == 0 || int(request.address_length) > MAX_SOURCE_ADDRESS_BYTES {
		return .Invalid_Address
	}
	address := request.address_bytes[:request.address_length]
	if !text_encoding.text_valid(address) {
		return .Invalid_Address
	}
	if int(request.allowed_host_length) == 0 || int(request.allowed_host_length) > powerbox.MAX_HOST_BYTES {
		return .Host_Mismatch
	}
	allowed_host := request.allowed_host_bytes[:request.allowed_host_length]
	if !powerbox.host_name_valid(allowed_host) {
		return .Host_Mismatch
	}
	address_host, host_ok := extract_address_host(address)
	if !host_ok {
		return .Invalid_Address
	}
	if !hosts_equal_case_insensitive(address_host, allowed_host) {
		return .Host_Mismatch
	}
	if int(request.requested_ref_length) > MAX_UPSTREAM_REF_BYTES || !upstream_ref_valid(request.requested_ref_bytes[:request.requested_ref_length]) {
		return .Invalid_Upstream_Ref
	}
	switch action {
	case .None:
		return .Bad_Resolver_Action
	case .Resolve:
	case .Fetch:
		if hash_is_zero(request.expected_tree_hash) {
			return .Zero_Hash
		}
	}
	return .None
}

// source_resolver_response_validate validates a source module response against
// its originating request. Refuses unknown statuses, source module mismatch,
// zero resolved tree hashes, and any Fetch whose output tree hash disagrees
// with expected_tree_hash.
source_resolver_response_validate :: proc "contextless" (
	request: ^Source_Resolver_Request,
	response: ^Source_Resolver_Response,
) -> Project_Refusal {
	if req_refusal := source_resolver_request_validate(request); req_refusal != .None {
		return req_refusal
	}
	if response == nil {
		return .Bad_Resolver_Status
	}
	status, status_ok := source_resolver_status_of_word(response.status_word)
	if !status_ok {
		return .Bad_Resolver_Status
	}
	if response.source_module_hash != request.source_module_hash {
		return .Hash_Mismatch
	}
	if int(response.resolved_ref_length) > MAX_UPSTREAM_REF_BYTES || !upstream_ref_valid(response.resolved_ref_bytes[:response.resolved_ref_length]) {
		return .Invalid_Upstream_Ref
	}
	if status != .Ok {
		return .None
	}
	if hash_is_zero(response.resolved_tree_hash) {
		return .Zero_Hash
	}
	action, _ := source_resolver_action_of_word(request.action_word)
	if action == .Fetch && response.resolved_tree_hash != request.expected_tree_hash {
		return .Hash_Mismatch
	}
	return .None
}

@(private = "file")
store_rights_cover :: proc "contextless" (held, requested: Plan_Store_Rights) -> bool {
	switch held {
	case .None:
		return false
	case .Read_Only:
		return requested == .Read_Only
	case .Read_Write:
		return requested == .Read_Only || requested == .Read_Write
	}
	return false
}

// project_console_module_make constructs a validated Project_Console_Module.
project_console_module_make :: proc "contextless" (name: string, module_hash: blake3.Hash) -> (mod: Project_Console_Module, refusal: Project_Refusal) {
	raw := transmute([]u8)name
	if !lex_field_name_valid(raw) {
		return {}, .Invalid_Module_Name
	}
	if hash_is_zero(module_hash) {
		return {}, .Zero_Hash
	}
	copy(mod.name_bytes[:len(raw)], raw)
	mod.name_length = u8(len(raw))
	mod.module_hash = module_hash
	return mod, .None
}

// project_console_store_make constructs a validated Project_Console_Store.
project_console_store_make :: proc "contextless" (name: string, rights: Plan_Store_Rights) -> (store: Project_Console_Store, refusal: Project_Refusal) {
	raw := transmute([]u8)name
	if len(raw) == 0 || len(raw) > MAX_ENTRY_NAME_BYTES {
		return {}, .Invalid_Store_Name
	}
	copy(store.name_bytes[:len(raw)], raw)
	store.name_length = u8(len(raw))
	if !entry_name_valid(store.name_bytes[:], store.name_length) {
		return {}, .Invalid_Store_Name
	}
	if _, rights_ok := plan_store_rights_of_word(u64(rights)); !rights_ok {
		return {}, .Bad_Store_Rights
	}
	store.rights_word = u64(rights)
	return store, .None
}

// project_console_spec_validate_structure validates the standalone structural
// invariants of a Project_Console_Spec: non-zero project tree hash, non-empty
// console specification, bounded counts, valid non-duplicate module names and
// hashes, and valid non-duplicate store names and rights words.
project_console_spec_validate_structure :: proc "contextless" (
	spec: ^Project_Console_Spec,
) -> (refusal: Project_Refusal, bad_index: u32) {
	if spec == nil || hash_is_zero(spec.project_tree_hash) {
		return .Zero_Hash, 0
	}
	if spec.module_count > MAX_CONSOLE_MODULES {
		return .Too_Many_Modules, 0
	}
	if spec.store_count > MAX_CONSOLE_STORES {
		return .Too_Many_Stores, 0
	}
	if spec.module_count == 0 && spec.store_count == 0 {
		return .Empty_Console, 0
	}

	for index in u32(0) ..< spec.module_count {
		mod := &spec.modules[index]
		if int(mod.name_length) == 0 || int(mod.name_length) > MAX_ENTRY_NAME_BYTES || !lex_field_name_valid(mod.name_bytes[:mod.name_length]) {
			return .Invalid_Module_Name, index
		}
		for pad in mod.name_bytes[mod.name_length:] {
			if pad != 0 {
				return .Invalid_Module_Name, index
			}
		}
		if hash_is_zero(mod.module_hash) {
			return .Zero_Hash, index
		}
		for earlier in u32(0) ..< index {
			prev := &spec.modules[earlier]
			if bytes_equal(prev.name_bytes[:prev.name_length], mod.name_bytes[:mod.name_length]) {
				return .Duplicate_Module, index
			}
		}
	}

	for index in u32(0) ..< spec.store_count {
		req_store := &spec.stores[index]
		if !entry_name_valid(req_store.name_bytes[:], req_store.name_length) {
			return .Invalid_Store_Name, index
		}
		if _, rights_ok := plan_store_rights_of_word(req_store.rights_word); !rights_ok {
			return .Bad_Store_Rights, index
		}
		for earlier in u32(0) ..< index {
			prev := &spec.stores[earlier]
			if bytes_equal(prev.name_bytes[:prev.name_length], req_store.name_bytes[:req_store.name_length]) {
				return .Duplicate_Store, index
			}
		}
	}
	return .None, 0
}

// project_console_spec_validate validates a Project_Console_Spec for
// projects.enter(project) against the caller's held stores. Refuses zero
// project tree hash, empty console specs, duplicate or invalid modules/stores,
// any store not declared in caller_stores, and any store whose requested
// rights exceed what the caller holds.
project_console_spec_validate :: proc "contextless" (
	spec: ^Project_Console_Spec,
	caller_stores: []Project_Console_Store,
) -> (refusal: Project_Refusal, bad_index: u32) {
	if struct_ref, struct_bad := project_console_spec_validate_structure(spec); struct_ref != .None {
		return struct_ref, struct_bad
	}

	for index in u32(0) ..< spec.store_count {
		req_store := &spec.stores[index]
		req_rights, _ := plan_store_rights_of_word(req_store.rights_word)

		// Verify caller holds the declared store with covering rights.
		matched_store := false
		rights_covered := false
		for &held_store in caller_stores {
			if int(held_store.name_length) > MAX_ENTRY_NAME_BYTES {
				continue
			}
			if !bytes_equal(held_store.name_bytes[:held_store.name_length], req_store.name_bytes[:req_store.name_length]) {
				continue
			}
			matched_store = true
			held_rights, held_ok := plan_store_rights_of_word(held_store.rights_word)
			if held_ok && store_rights_cover(held_rights, req_rights) {
				rights_covered = true
			}
			break
		}
		if !matched_store {
			return .Undeclared_Store, index
		}
		if !rights_covered {
			return .Store_Rights_Exceeded, index
		}
	}
	return .None, 0
}

// project_console_spec_hash computes the order-independent canonical BLAKE3
// digest of a validated Project_Console_Spec so trusted Display consent binds
// to the exact modules and store grants of the child console.
project_console_spec_hash :: proc "contextless" (spec: ^Project_Console_Spec) -> (digest: blake3.Hash, refusal: Project_Refusal) {
	if struct_ref, _ := project_console_spec_validate_structure(spec); struct_ref != .None {
		return {}, struct_ref
	}

	mod_order: [MAX_CONSOLE_MODULES]u32
	for i in u32(0) ..< spec.module_count {
		mod_order[i] = i
	}
	for i in u32(1) ..< spec.module_count {
		key := mod_order[i]
		key_name := spec.modules[key].name_bytes[:spec.modules[key].name_length]
		j := int(i) - 1
		for j >= 0 {
			cur := &spec.modules[mod_order[j]]
			if compare_bytes(cur.name_bytes[:cur.name_length], key_name) <= 0 {
				break
			}
			mod_order[j + 1] = mod_order[j]
			j -= 1
		}
		mod_order[j + 1] = key
	}

	store_order: [MAX_CONSOLE_STORES]u32
	for i in u32(0) ..< spec.store_count {
		store_order[i] = i
	}
	for i in u32(1) ..< spec.store_count {
		key := store_order[i]
		key_name := spec.stores[key].name_bytes[:spec.stores[key].name_length]
		j := int(i) - 1
		for j >= 0 {
			cur := &spec.stores[store_order[j]]
			if compare_bytes(cur.name_bytes[:cur.name_length], key_name) <= 0 {
				break
			}
			store_order[j + 1] = store_order[j]
			j -= 1
		}
		store_order[j + 1] = key
	}

	buf: [MAX_CONSOLE_CANONICAL_BYTES]u8
	enc := Canonical_Encoder{buffer = buf[:]}
	encoder_raw_bytes(&enc, spec.project_tree_hash[:])
	encoder_u64(&enc, spec.principal)
	encoder_u32(&enc, spec.module_count)
	for pos in u32(0) ..< spec.module_count {
		mod := &spec.modules[mod_order[pos]]
		encoder_bytes(&enc, mod.name_bytes[:mod.name_length])
		encoder_raw_bytes(&enc, mod.module_hash[:])
	}
	encoder_u32(&enc, spec.store_count)
	for pos in u32(0) ..< spec.store_count {
		st := &spec.stores[store_order[pos]]
		encoder_bytes(&enc, st.name_bytes[:st.name_length])
		encoder_u64(&enc, st.rights_word)
	}
	if enc.overflow {
		return {}, .Buffer_Too_Small
	}
	return blake3.derive_key(PROJECT_CONSOLE_HASH_DOMAIN, buf[:enc.position]), .None
}

// project_console_grant_diff computes which module connections and store
// grants requested by spec lie outside the caller's current console session.
// Any added module or uncovered/widened store sets needs_consent = true.
project_console_grant_diff :: proc "contextless" (
	spec: ^Project_Console_Spec,
	session_stores: []Project_Console_Store,
	session_modules: []Project_Console_Module,
) -> (diff: Project_Console_Grant_Diff, refusal: Project_Refusal) {
	spec_hash, hash_ref := project_console_spec_hash(spec)
	if hash_ref != .None {
		return {}, hash_ref
	}
	diff.spec_hash = spec_hash

	for index in u32(0) ..< spec.module_count {
		req_mod := spec.modules[index]
		covered := false
		for &held_mod in session_modules {
			if int(held_mod.name_length) > MAX_ENTRY_NAME_BYTES {
				continue
			}
			if bytes_equal(held_mod.name_bytes[:held_mod.name_length], req_mod.name_bytes[:req_mod.name_length]) &&
			   held_mod.module_hash == req_mod.module_hash {
				covered = true
				break
			}
		}
		if !covered {
			diff.added_modules[diff.added_module_count] = req_mod
			diff.added_module_count += 1
		}
	}

	for index in u32(0) ..< spec.store_count {
		req_store := spec.stores[index]
		req_rights, _ := plan_store_rights_of_word(req_store.rights_word)
		covered := false
		for &held_store in session_stores {
			if int(held_store.name_length) > MAX_ENTRY_NAME_BYTES {
				continue
			}
			if !bytes_equal(held_store.name_bytes[:held_store.name_length], req_store.name_bytes[:req_store.name_length]) {
				continue
			}
			held_rights, held_ok := plan_store_rights_of_word(held_store.rights_word)
			if held_ok && store_rights_cover(held_rights, req_rights) {
				covered = true
			}
			break
		}
		if !covered {
			diff.added_stores[diff.added_store_count] = req_store
			diff.added_store_count += 1
		}
	}

	diff.needs_consent = diff.added_module_count > 0 || diff.added_store_count > 0
	return diff, .None
}

// project_console_spec_from_declaration constructs an isolated
// Project_Console_Spec from a Project_Declaration's console field (or from its
// output builders and source store with Read_Write when no console field is
// declared). Refuses unknown projects and empty console fields cleanly.
project_console_spec_from_declaration :: proc "contextless" (
	decl: ^Project_Declaration,
	principal: u64,
	parent_console_id: u64 = 0,
) -> (spec: Project_Console_Spec, refusal: Project_Refusal) {
	if decl == nil || hash_is_zero(decl.project_tree_hash) {
		return {}, .Unknown_Project
	}
	spec.project_tree_hash = decl.project_tree_hash
	spec.principal = principal
	spec.parent_console_id = parent_console_id

	if decl.has_console_field {
		if decl.console_module_count > MAX_CONSOLE_MODULES {
			return {}, .Too_Many_Modules
		}
		if decl.console_store_count > MAX_CONSOLE_STORES {
			return {}, .Too_Many_Stores
		}
		spec.module_count = decl.console_module_count
		for i in u32(0) ..< decl.console_module_count {
			spec.modules[i] = decl.console_modules[i]
		}
		spec.store_count = decl.console_store_count
		for i in u32(0) ..< decl.console_store_count {
			spec.stores[i] = decl.console_stores[i]
		}
	} else {
		if decl.builder_module_count > MAX_CONSOLE_MODULES {
			return {}, .Too_Many_Modules
		}
		spec.module_count = decl.builder_module_count
		for i in u32(0) ..< decl.builder_module_count {
			spec.modules[i] = decl.builder_modules[i]
		}
		if decl.has_source_store {
			if !entry_name_valid(decl.source_store_bytes[:], decl.source_store_length) {
				return {}, .Invalid_Store_Name
			}
			spec.stores[0] = {
				name_bytes  = decl.source_store_bytes,
				name_length = decl.source_store_length,
				rights_word = u64(Plan_Store_Rights.Read_Write),
			}
			spec.store_count = 1
		}
	}

	if struct_ref, _ := project_console_spec_validate_structure(&spec); struct_ref != .None {
		return {}, struct_ref
	}
	return spec, .None
}
