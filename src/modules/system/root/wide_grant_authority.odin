// Wide-grant authority key management and act record output wiring in the
// root service (src/md/features/wide_grants.md, "The deliberate act: the
// proof of the principal" and "The record of each act").
//
// At boot, right after the system random generator is seeded, the root
// service (the unlock authority) draws a fresh 32-byte keyed BLAKE3 authority
// key with random.fill_for_a_key, refusing weak entropy. When the collector
// starts, the root service passes that key in its four context value slots
// (GRANT_VALUE_WIDE_GRANT_AUTHORITY_KEY) and erases every temporary copy.
// Without strong entropy, the key stays zero and the collector refuses every
// wide grant while still serving its audit store.
package root

import "base:intrinsics"
import "modus:contract/blake3"
import "modus:contract/errors"
import module "modus:contract/module"
import "modus:contract/output"
import "modus:contract/wide_grants"
import "modus:random"
import "modus:system"

// Wide-grant act records emitted by the root service: grant start, process
// starts/stops, shares/connections, and revocation/expiry.
acts: system.Record_Output(wide_grants.Act_Stream_Record)

// Authority key held exclusively by the unlock authority (this service) and
// delivered to the collector in its context at start.
wide_grant_authority: wide_grants.Wide_Grant_Authority

// wide_grant_authority_start generates a fresh authority key from
// process_generator, refusing weak entropy (below Processor) and refusing an
// all-zero key. Never logs key material.
wide_grant_authority_start :: proc "contextless" () {
	raw_key: wide_grants.Authority_Key
	defer intrinsics.mem_zero_volatile(&raw_key, size_of(raw_key))
	key_error: errors.Error_Record
	strength := random.seed_strength(&process_generator)
	if !random.fill_for_a_key(&process_generator, raw_key[:], wide_grants.AUTHORITY_KEY_LEAST_ENTROPY, &key_error) {
		_ = wide_grants.authority_init_from_bytes(&wide_grant_authority, {}, strength)
		system.log_fact(.Warning, Wide_Grant_Authority_Key_Refused{status_code = u64(wide_grant_authority.status)})
		return
	}
	if !wide_grants.authority_init_from_bytes(&wide_grant_authority, raw_key, strength) {
		system.log_fact(.Warning, Wide_Grant_Authority_Key_Refused{status_code = u64(wide_grant_authority.status)})
		return
	}
	system.log_fact(.Info, Wide_Grant_Authority_Key_Ready{})
}

// wide_grant_authority_values_write writes the collector's principal and
// fresh authority key words into its start context. When no strong key exists
// at boot, the four key slots remain zero so the collector fails closed and
// refuses every wide grant.
wide_grant_authority_values_write :: proc "contextless" (work: ^Start_Work) {
	system.value_put(&work.values, system.GRANT_VALUE_SERVICE_PRINCIPAL, work.principal)
	key_words, ok := wide_grants.authority_context_words(&wide_grant_authority)
	defer intrinsics.mem_zero_volatile(&key_words, size_of(key_words))
	if ok {
		system.values_put(&work.values, system.GRANT_VALUE_WIDE_GRANT_AUTHORITY_KEY, key_words[:])
	}
}

// wide_grant_authority_mint_proof issues a keyed Wide_Grant_Proof bound to
// terms after unlock proves the principal passphrase or a host-key signature
// verifies. Refuses when the authority key is not ready or the origin is
// remote display input.
wide_grant_authority_mint_proof :: proc "contextless" (
	terms: ^wide_grants.Wide_Grant_Terms,
	kind: wide_grants.Proof_Kind,
	origin: wide_grants.Proof_Origin,
	verifier_key_or_token_hash: blake3.Hash,
) -> (proof: wide_grants.Wide_Grant_Proof, refusal: wide_grants.Wide_Grant_Refusal) {
	return wide_grants.authority_mint_proof(&wide_grant_authority, terms, kind, origin, verifier_key_or_token_hash, system.time())
}

// wide_grant_act_record_emit writes one root-service act record onto root's
// `acts` record output without blocking. Returns busy == true when an audit
// ring is full so the caller refuses the act rather than running unrecorded.
wide_grant_act_record_emit :: proc "contextless" (
	grant_serial: u64,
	principal_id: u64,
	kind: wide_grants.Act_Kind,
	target_window_id: u64 = 0,
	detail_word_0: u64 = 0,
	detail_word_1: u64 = 0,
) -> (recorded: bool, busy: bool) {
	if grant_serial == 0 || kind == .None {
		return false, false
	}
	record := wide_grants.Act_Stream_Record {
		grant_serial     = grant_serial,
		principal_id     = principal_id,
		timestamp_ms     = system.time(),
		producer_word    = u64(wide_grants.Act_Producer.Root_Service),
		act_kind_word    = u64(kind),
		target_window_id = target_window_id,
		detail_word_0    = detail_word_0,
		detail_word_1    = detail_word_1,
	}
	switch system.output_write(&acts, record, wait = false) {
	case .Ok:
		return true, false
	case .Full:
		return false, true
	case .No_Reader, .No_Writer, .Ended, .Bad_Record, .No_Record:
		return false, false
	}
	return false, false
}

// module_record_output_index looks up the 1-based Record_Outputs index of
// stream_name in a verified module file, or 0 if absent.
@(private = "file")
module_record_output_index :: proc "contextless" (file: []u8, stream_name: string) -> u32 {
	total := module.count(file, .Record_Outputs)
	for index in u32(1) ..< total {
		row, _, _, ok := module.record_output(file, index)
		if !ok {
			continue
		}
		name := module.string_at(file, row.name_offset, row.name_count)
		if name == stream_name {
			return index
		}
	}
	return 0
}

// module_record_input_index looks up the 1-based Record_Inputs index of
// stream_name in a verified module file, or 0 if absent.
@(private = "file")
module_record_input_index :: proc "contextless" (file: []u8, stream_name: string) -> u32 {
	total := module.count(file, .Record_Inputs)
	for index in u32(1) ..< total {
		row, _, _, _, ok := module.record_input(file, index)
		if !ok {
			continue
		}
		name := module.string_at(file, row.name_offset, row.name_count)
		if name == stream_name {
			return index
		}
	}
	return 0
}

// wide_grant_act_wiring_plan builds the output.Wiring rows that connect the
// running stream act producers (agent console, remote, trusted display) to
// collector.sources with Audit Space_Terms and Always_Holds_Writer.
wide_grant_act_wiring_plan :: proc "contextless" (
	collector_handle: u32,
	console_handle: u32,
	remote_handle: u32,
	display_handle: u32,
	terms_offset: u32,
	out_rows: []output.Wiring,
	out_terms: ^wide_grants.Space_Terms,
) -> (written: int, refusal: wide_grants.Act_Wiring_Refusal) {
	collector_file := image_file_checked("collector")
	sources_index := module_record_input_index(collector_file, "sources")
	if sources_index == 0 {
		return 0, .Bad_Wiring_End
	}
	endpoints: [3]wide_grants.Act_Producer_Endpoint
	count := 0
	candidates := [3]struct {
		producer: wide_grants.Act_Producer,
		name:     string,
		handle:   u32,
	} {
		{.Agent_Console, role_holder_name(.Console), console_handle},
		{.Remote_Service, "remote", remote_handle},
		{.Trusted_Display, role_holder_name(.Display), display_handle},
	}
	for c in candidates {
		if c.handle == 0 {
			continue
		}
		file := image_file_checked(c.name)
		out_index := module_record_output_index(file, wide_grants.ACT_OUTPUT_NAME)
		if out_index == 0 {
			return 0, .Bad_Wiring_End
		}
		endpoints[count] = {
			producer     = c.producer,
			end          = .Started,
			handle       = c.handle,
			output_index = out_index,
		}
		count += 1
	}
	return wide_grants.act_wiring_rows_build(
		.Started,
		collector_handle,
		sources_index,
		endpoints[:count],
		terms_offset,
		wide_grants.ACT_SPACE_BOUND_RECORDS,
		out_rows,
		out_terms,
	)
}
