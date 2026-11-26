#+build !freestanding
#+build !modus
// Adversarial host tests for modus:contract/language_analysis (MODLAEF1).
package language_analysis

import "core:strings"
import "core:testing"
import "modus:contract/byte_order"

@(test)
ring_request_and_response_refuse_invalid_inputs :: proc(t: ^testing.T) {
	// Zero request id, non-zero flags, unknown enum word, cursor past source.
	_, ref := ring_request_validate({})
	testing.expect_value(t, ref, Analysis_Refusal.Bad_Request)

	_, ref = ring_request_validate({request_id = 1, kind_word = 99})
	testing.expect_value(t, ref, Analysis_Refusal.Unknown_Enum_Word)

	_, ref = ring_request_validate({request_id = 1, kind_word = u32(Analysis_Request_Kind.Hover), cursor_offset = 11, source_bytes = 10})
	testing.expect_value(t, ref, Analysis_Refusal.Span_Order_Invalid)

	_, ref = ring_request_validate({request_id = 1, kind_word = u32(Analysis_Request_Kind.Hover), flags = 1})
	testing.expect_value(t, ref, Analysis_Refusal.Bad_Request)

	kind, ok_ref := ring_request_validate({request_id = 42, document_generation = 7, cursor_offset = 5, source_bytes = 10, kind_word = u32(Analysis_Request_Kind.Definition)})
	testing.expect_value(t, ok_ref, Analysis_Refusal.None)
	testing.expect_value(t, kind, Analysis_Request_Kind.Definition)

	// Response refusals: zero id, unknown refusal word, snapshot past capacity.
	_, ref = ring_response_validate({}, 4096)
	testing.expect_value(t, ref, Analysis_Refusal.Bad_Request)

	_, ref = ring_response_validate({request_id = 1, refusal_word = 77}, 4096)
	testing.expect_value(t, ref, Analysis_Refusal.Unknown_Enum_Word)

	_, ref = ring_response_validate({request_id = 1, snapshot_bytes = 4097, refusal_word = u32(Analysis_Refusal.None)}, 4096)
	testing.expect_value(t, ref, Analysis_Refusal.Bad_Size)

	status, resp_ref := ring_response_validate({request_id = 42, document_generation = 7, snapshot_bytes = 256, diagnostic_count = 1, refusal_word = u32(Analysis_Refusal.None)}, 4096)
	testing.expect_value(t, resp_ref, Analysis_Refusal.None)
	testing.expect_value(t, status, Analysis_Refusal.None)
}

@(test)
snapshot_validator_refuses_hostile_corruption :: proc(t: ^testing.T) {
	// Empty and truncated buffers.
	_, ref := snapshot_validate(nil)
	testing.expect_value(t, ref, Analysis_Refusal.Buffer_Too_Small)

	short_buf: [SNAPSHOT_HEADER_SIZE - 1]u8
	_, ref = snapshot_validate(short_buf[:])
	testing.expect_value(t, ref, Analysis_Refusal.Buffer_Too_Small)

	// Build one valid baseline snapshot to mutate per adversarial case.
	base_strings := "bad syntax"
	diags := [1]Diagnostic_Row{{start_offset = 0, end_offset = 3, line = 1, column = 1, severity_word = u32(Analysis_Diagnostic_Severity.Error), message_offset = 0, message_bytes = u32(len(base_strings))}}
	tokens := [1]Semantic_Token_Row{{start_offset = 0, length = 3, kind_word = u32(Semantic_Token_Kind.Keyword)}}
	tables := Snapshot_Tables{
		document_generation = 9,
		diagnostics         = diags[:],
		tokens              = tokens[:],
		strings             = transmute([]u8)base_strings,
	}

	// Undersized output buffer refuses cleanly.
	tiny: [SNAPSHOT_HEADER_SIZE]u8
	_, enc_ref := snapshot_encode(tables, tiny[:])
	testing.expect_value(t, enc_ref, Analysis_Refusal.Buffer_Too_Small)

	buf: [512]u8
	written, ok_enc := snapshot_encode(tables, buf[:])
	testing.expect_value(t, ok_enc, Analysis_Refusal.None)
	testing.expect(t, written > SNAPSHOT_HEADER_SIZE)

	// 1. Bad magic.
	corrupt := buf
	corrupt[0] = 'X'
	_, ref = snapshot_validate(corrupt[:written])
	testing.expect_value(t, ref, Analysis_Refusal.Bad_Magic)

	// 2. Unsupported version.
	corrupt = buf
	byte_order.write_u32_little_endian(corrupt[:], 8, 99)
	_, ref = snapshot_validate(corrupt[:written])
	testing.expect_value(t, ref, Analysis_Refusal.Unsupported_Version)

	// 3. Total bytes larger than slice.
	corrupt = buf
	byte_order.write_u32_little_endian(corrupt[:], 12, u32(written + 1))
	_, ref = snapshot_validate(corrupt[:written])
	testing.expect_value(t, ref, Analysis_Refusal.Bad_Size)

	// 4. Overlapping sections: point tokens_offset onto diagnostics_offset.
	corrupt = buf
	hdr, valid_ref := snapshot_validate(buf[:written])
	testing.expect_value(t, valid_ref, Analysis_Refusal.None)
	byte_order.write_u32_little_endian(corrupt[:], 32, hdr.diagnostics_offset)
	_, ref = snapshot_validate(corrupt[:written])
	testing.expect_value(t, ref, Analysis_Refusal.Section_Overlap)

	// 5. Unaligned section offset.
	corrupt = buf
	byte_order.write_u32_little_endian(corrupt[:], 32, hdr.tokens_offset + 1)
	_, ref = snapshot_validate(corrupt[:written])
	testing.expect_value(t, ref, Analysis_Refusal.Bad_Alignment)

	// 6. Unknown diagnostic severity enum word.
	corrupt = buf
	byte_order.write_u32_little_endian(corrupt[:], int(hdr.diagnostics_offset) + 16, 42)
	_, ref = snapshot_validate(corrupt[:written])
	testing.expect_value(t, ref, Analysis_Refusal.Unknown_Enum_Word)

	// 7. Out-of-bounds string pool span.
	corrupt = buf
	byte_order.write_u32_little_endian(corrupt[:], int(hdr.diagnostics_offset) + 24, hdr.strings_bytes + 1)
	_, ref = snapshot_validate(corrupt[:written])
	testing.expect_value(t, ref, Analysis_Refusal.String_Out_Of_Bounds)

	// 8. Inverted diagnostic span (start > end).
	corrupt = buf
	byte_order.write_u32_little_endian(corrupt[:], int(hdr.diagnostics_offset) + 0, 10)
	byte_order.write_u32_little_endian(corrupt[:], int(hdr.diagnostics_offset) + 4, 2)
	_, ref = snapshot_validate(corrupt[:written])
	testing.expect_value(t, ref, Analysis_Refusal.Span_Order_Invalid)

	// 9. Unknown semantic token kind word.
	corrupt = buf
	byte_order.write_u32_little_endian(corrupt[:], int(hdr.tokens_offset) + 8, 255)
	_, ref = snapshot_validate(corrupt[:written])
	testing.expect_value(t, ref, Analysis_Refusal.Unknown_Enum_Word)
}

@(test)
lex_analyzer_round_trip_tokens_definitions_hovers_and_diagnostics :: proc(t: ^testing.T) {
	ws := new(Lex_Analyzer_Workspace)
	defer free(ws)

	lex_source := `// Declarative Lex build
let
  default_build = { heap = 2 MiB, mode = .fast },
  release_build = default_build with { heap = 4 MiB },
in
  project {
    source = here(),
    outputs = { default = recipe(catalog.modules.c_builder, release_build) },
  }
`
	out := make([]u8, 32 * 1024)
	defer delete(out)

	written, ref := lex_analyze_into_snapshot(ws, lex_source, 12, out)
	testing.expect_value(t, ref, Analysis_Refusal.None)
	testing.expect(t, written > SNAPSHOT_HEADER_SIZE)

	hdr, val_ref := snapshot_validate(out[:written])
	testing.expect_value(t, val_ref, Analysis_Refusal.None)
	testing.expect_value(t, hdr.document_generation, u64(12))
	testing.expect_value(t, hdr.diagnostics_count, u32(0))
	testing.expect(t, hdr.tokens_count > 20)
	testing.expect(t, hdr.completions_count >= 8)
	testing.expect(t, hdr.definitions_count >= 2)
	testing.expect(t, hdr.hovers_count >= 4)

	// Verify definition jump from `default_build` usage back to its `let` declaration.
	second_use := strings.last_index(lex_source, "default_build")
	testing.expect(t, second_use > 0)
	def, def_found := snapshot_definition_for_offset(out[:written], hdr, u32(second_use + 2))
	testing.expect(t, def_found, "must resolve definition span for default_build")
	testing.expect_value(t, snapshot_string_at(out[:written], hdr, def.name_offset, def.name_bytes), "default_build")
	testing.expect_value(t, lex_source[def.target_start:def.target_end], "default_build")
	testing.expect(t, def.target_start < def.use_start)

	// Verify hover lookup on `here`.
	here_at := strings.index(lex_source, "here")
	testing.expect(t, here_at > 0)
	hover, hover_found := snapshot_hover_for_offset(out[:written], hdr, u32(here_at))
	testing.expect(t, hover_found, "must provide hover entry for here")
	testing.expect(t, strings.contains(snapshot_string_at(out[:written], hdr, hover.signature_offset, hover.signature_bytes), "Tree_Ref"))

	// Broken Lex input emits exact Error diagnostics (unterminated string, bad blake3:, unclosed brace).
	broken := "let x = \"unterminated\n  y = blake3:1234\nin { a = 1"
	written_bad, bad_ref := lex_analyze_into_snapshot(ws, broken, 13, out)
	testing.expect_value(t, bad_ref, Analysis_Refusal.None)
	hdr_bad, val_bad := snapshot_validate(out[:written_bad])
	testing.expect_value(t, val_bad, Analysis_Refusal.None)
	testing.expect_value(t, hdr_bad.diagnostics_count, u32(3))

	// Exceeding workspace definitions/hovers capacity returns Capacity_Exceeded consistently.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "let x = 1 in [")
	for i in 0 ..< LEX_ANALYZE_DEFINITIONS_LIMIT + 2 {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		strings.write_string(&b, "x")
	}
	strings.write_string(&b, "]")
	_, overflow_ref := lex_analyze_into_snapshot(ws, strings.to_string(b), 14, out)
	testing.expect_value(t, overflow_ref, Analysis_Refusal.Capacity_Exceeded)
}
