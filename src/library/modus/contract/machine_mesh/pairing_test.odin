#+build !freestanding
#+build !modus
package machine_mesh

import "base:runtime"
import "core:crypto/ed25519"
import "core:testing"
import "modus:contract/blake3"

@(private = "file")
pairing_test_keypair :: proc(seed_byte: u8) -> (private_key: ed25519.Private_Key, public_bytes: [PUBLIC_KEY_SIZE]u8) {
	seed: [ed25519.PRIVATE_KEY_SIZE]u8
	for index in 0 ..< len(seed) {
		seed[index] = seed_byte ~ u8(index * 7 + 5)
	}
	ok := ed25519.private_key_set_bytes(&private_key, seed[:])
	assert(ok)
	ed25519.private_key_public_bytes(&private_key, public_bytes[:])
	return private_key, public_bytes
}

@(private = "file")
pairing_test_verify :: proc "contextless" (public_key: [PUBLIC_KEY_SIZE]u8, message: []u8, signature: [SIGNATURE_SIZE]u8, _: rawptr) -> bool {
	context = runtime.default_context()
	key := public_key
	signature_copy := signature
	parsed: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&parsed, key[:]) {
		return false
	}
	return ed25519.verify(&parsed, message, signature_copy[:])
}

@(private = "file")
pairing_test_scalar :: proc(seed: u8) -> [CPACE_SCALAR_SIZE]u8 {
	input := [2]u8{seed, 0x3C}
	return blake3.hash(input[:])
}

@(private = "file")
pairing_test_binding :: proc(seed: u8) -> [PAIRING_CHANNEL_BINDING_SIZE]u8 {
	input := [3]u8{seed, 0xE7, 0x19}
	return blake3.hash(input[:])
}

@(private = "file")
OFFERER_KEY :: [PUBLIC_KEY_SIZE]u8{0 = 0xA1, 31 = 0x01}
@(private = "file")
JOINER_KEY :: [PUBLIC_KEY_SIZE]u8{0 = 0xB2, 31 = 0x02}
@(private = "file")
RELAY_KEY :: [PUBLIC_KEY_SIZE]u8{0 = 0xC3, 31 = 0x03}
@(private = "file")
START_MS :: u64(5_000_000)

// The two sides of one pairing, run to the end of the exchange, with the
// code that the joiner types.
@(private = "file")
Pairing_Test_Run :: struct {
	offerer:        Pairing_Session,
	joiner:         Pairing_Session,
	offerer_ledger: Pairing_Code_Ledger,
	joiner_ledger:  Pairing_Code_Ledger,
	offerer_table:  Paired_Machine_Table,
	joiner_table:   Paired_Machine_Table,
	code:           [PAIRING_CODE_TEXT_SIZE]u8,
}

@(private = "file")
pairing_test_exchange :: proc(
	t: ^testing.T,
	run: ^Pairing_Test_Run,
	typed_code: []u8,
	offerer_binding: [PAIRING_CHANNEL_BINDING_SIZE]u8,
	joiner_binding: [PAIRING_CHANNEL_BINDING_SIZE]u8,
) -> (offerer_tag, joiner_tag: [CPACE_CONFIRM_TAG_SIZE]u8) {
	offerer_binding_copy := offerer_binding
	joiner_binding_copy := joiner_binding
	random_bytes := [8]u8{0x5D, 0x11, 0x92, 0xE4, 0x07, 0xBB, 0x3A, 0xFF}
	code, offer_status := pairing_offer(&run.offerer, OFFERER_KEY, random_bytes, START_MS)
	testing.expect_value(t, offer_status, Pairing_Status.Ok)
	run.code = code
	testing.expect_value(t, pairing_join(&run.joiner, JOINER_KEY, typed_code, START_MS + 10), Pairing_Status.Ok)

	joiner_element, joiner_start := pairing_exchange_start(&run.joiner, &run.joiner_ledger, OFFERER_KEY, joiner_binding_copy[:], pairing_test_scalar(1), START_MS + 20)
	testing.expect_value(t, joiner_start, Pairing_Status.Ok)
	offerer_element, offerer_start := pairing_exchange_start(&run.offerer, &run.offerer_ledger, JOINER_KEY, offerer_binding_copy[:], pairing_test_scalar(2), START_MS + 20)
	testing.expect_value(t, offerer_start, Pairing_Status.Ok)
	// The code leaves the session once the generator is derived.
	testing.expect(t, bytes_all_zero(run.joiner.code_secret[:]))
	testing.expect(t, bytes_all_zero(run.offerer.code_secret[:]))

	joiner_identity := JOINER_KEY
	offerer_identity := OFFERER_KEY
	finish_status: Pairing_Status
	joiner_tag, finish_status = pairing_exchange_finish(&run.joiner, offerer_element, offerer_identity[:])
	testing.expect_value(t, finish_status, Pairing_Status.Ok)
	offerer_tag, finish_status = pairing_exchange_finish(&run.offerer, joiner_element, joiner_identity[:])
	testing.expect_value(t, finish_status, Pairing_Status.Ok)
	return offerer_tag, joiner_tag
}

@(test)
pairing_code_text_round_trips_and_refuses_each_bad_text :: proc(t: ^testing.T) {
	// A draw with zero in its 50 low bits is refused, whatever the high bits.
	_, zero_status := pairing_code_secret_of_random([8]u8{0, 0, 0, 0, 0, 0, 0xFC, 0xFF})
	testing.expect_value(t, zero_status, Pairing_Status.Refused_Zero_Code)

	// The largest code: all 50 bits set, high bits of the draw dropped.
	largest, largest_status := pairing_code_secret_of_random([8]u8{0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF})
	testing.expect_value(t, largest_status, Pairing_Status.Ok)
	largest_text := pairing_code_text(largest)
	testing.expect_value(t, string(largest_text[:]), "7777777777")
	testing.expect_value(t, largest[6], u8(0x03))

	smallest, smallest_status := pairing_code_secret_of_random([8]u8{1, 0, 0, 0, 0, 0, 0, 0})
	testing.expect_value(t, smallest_status, Pairing_Status.Ok)
	smallest_text := pairing_code_text(smallest)
	testing.expect_value(t, string(smallest_text[:]), "AAAAAAAAAB")

	secret, read_status := pairing_code_of_text(transmute([]u8)string("k7qm2zx4ra"))
	testing.expect_value(t, read_status, Pairing_Status.Ok)
	upper := pairing_code_text(secret)
	testing.expect_value(t, string(upper[:]), "K7QM2ZX4RA")
	again, again_status := pairing_code_of_text(upper[:])
	testing.expect_value(t, again_status, Pairing_Status.Ok)
	testing.expect_value(t, again, secret)

	refused_texts := [?]string{"", "K", "K7QM2ZX4R", "K7QM2ZX4RAA", "K7QM2ZX4R0", "K7QM2ZX4R1", "K7QM2ZX4R8", "K7QM2-X4RA", "K7QM2 X4RA", "K7QM2ZX4R\x00", "K7QM2ZX4R\xff"}
	for text in refused_texts {
		_, status := pairing_code_of_text(transmute([]u8)text)
		testing.expect_value(t, status, Pairing_Status.Refused_Bad_Code_Text)
	}
	_, all_zero_status := pairing_code_of_text(transmute([]u8)string("AAAAAAAAAA"))
	testing.expect_value(t, all_zero_status, Pairing_Status.Refused_Zero_Code)
}

@(test)
machine_identity_is_deterministic_and_refuses_a_zero_key :: proc(t: ^testing.T) {
	_, zero_ok := machine_identity_from_public_key({})
	testing.expect(t, !zero_ok)
	first, first_ok := machine_identity_from_public_key(OFFERER_KEY)
	second, second_ok := machine_identity_from_public_key(OFFERER_KEY)
	other, other_ok := machine_identity_from_public_key(JOINER_KEY)
	testing.expect(t, first_ok && second_ok && other_ok)
	testing.expect_value(t, first, second)
	testing.expect(t, first.fingerprint != other.fingerprint)
	testing.expect(t, first.public_key == OFFERER_KEY)
}

@(test)
pairing_refuses_bad_phases_keys_and_channel_bindings :: proc(t: ^testing.T) {
	session: Pairing_Session
	ledger: Pairing_Code_Ledger
	table: Paired_Machine_Table
	binding := pairing_test_binding(9)
	identity := OFFERER_KEY

	// Each step before its phase is refused and changes nothing.
	_, status := pairing_exchange_start(&session, &ledger, JOINER_KEY, binding[:], pairing_test_scalar(1), START_MS)
	testing.expect_value(t, status, Pairing_Status.Refused_Bad_Phase)
	_, status = pairing_exchange_finish(&session, {}, identity[:])
	testing.expect_value(t, status, Pairing_Status.Refused_Bad_Phase)
	_, status = pairing_confirm(&session, &table, {}, {.Calls}, START_MS)
	testing.expect_value(t, status, Pairing_Status.Refused_Bad_Phase)
	testing.expect_value(t, ledger.count, 0)
	testing.expect_value(t, table.count, 0)

	_, status = pairing_offer(nil, OFFERER_KEY, [8]u8{1, 0, 0, 0, 0, 0, 0, 0}, START_MS)
	testing.expect_value(t, status, Pairing_Status.Refused_Nil_Input)
	_, status = pairing_offer(&session, {}, [8]u8{1, 0, 0, 0, 0, 0, 0, 0}, START_MS)
	testing.expect_value(t, status, Pairing_Status.Refused_Zero_Key)
	_, status = pairing_offer(&session, OFFERER_KEY, {}, START_MS)
	testing.expect_value(t, status, Pairing_Status.Refused_Zero_Code)

	// A second offer while one runs is refused: it would replace a code
	// that the principal may be typing.
	_, status = pairing_offer(&session, OFFERER_KEY, [8]u8{1, 0, 0, 0, 0, 0, 0, 0}, START_MS)
	testing.expect_value(t, status, Pairing_Status.Ok)
	_, status = pairing_offer(&session, OFFERER_KEY, [8]u8{2, 0, 0, 0, 0, 0, 0, 0}, START_MS)
	testing.expect_value(t, status, Pairing_Status.Refused_Bad_Phase)
	testing.expect_value(t, pairing_join(&session, OFFERER_KEY, transmute([]u8)string("AAAAAAAAAC"), START_MS), Pairing_Status.Refused_Bad_Phase)

	// The peer is this machine: refused, and the session is spent.
	_, status = pairing_exchange_start(&session, &ledger, OFFERER_KEY, binding[:], pairing_test_scalar(1), START_MS)
	testing.expect_value(t, status, Pairing_Status.Refused_Same_Machine)
	testing.expect_value(t, session.phase, Pairing_Phase.Failed)
	testing.expect(t, bytes_all_zero(session.code_secret[:]))

	zero_binding: [PAIRING_CHANNEL_BINDING_SIZE]u8
	long_binding: [PAIRING_CHANNEL_BINDING_SIZE + 1]u8
	long_binding[0] = 1
	bad_bindings := [?][]u8{nil, binding[:PAIRING_CHANNEL_BINDING_SIZE - 1], long_binding[:], zero_binding[:]}
	for bad_binding in bad_bindings {
		_, status = pairing_offer(&session, OFFERER_KEY, [8]u8{3, 0, 0, 0, 0, 0, 0, 0}, START_MS)
		testing.expect_value(t, status, Pairing_Status.Ok)
		_, status = pairing_exchange_start(&session, &ledger, JOINER_KEY, bad_binding, pairing_test_scalar(1), START_MS)
		testing.expect_value(t, status, Pairing_Status.Refused_Bad_Channel_Binding)
		testing.expect_value(t, session.phase, Pairing_Phase.Failed)
	}

	_, status = pairing_offer(&session, OFFERER_KEY, [8]u8{4, 0, 0, 0, 0, 0, 0, 0}, START_MS)
	testing.expect_value(t, status, Pairing_Status.Ok)
	_, status = pairing_exchange_start(&session, &ledger, {}, binding[:], pairing_test_scalar(1), START_MS)
	testing.expect_value(t, status, Pairing_Status.Refused_Zero_Key)
	// No refusal above reached the ledger: a refused start spends no slot.
	testing.expect_value(t, ledger.count, 0)
}

@(test)
pairing_with_the_same_code_records_each_peer_once :: proc(t: ^testing.T) {
	run: Pairing_Test_Run
	binding := pairing_test_binding(1)
	random_bytes := [8]u8{0x5D, 0x11, 0x92, 0xE4, 0x07, 0xBB, 0x3A, 0xFF}
	secret, _ := pairing_code_secret_of_random(random_bytes)
	typed := pairing_code_text(secret)
	offerer_tag, joiner_tag := pairing_test_exchange(t, &run, typed[:], binding, binding)

	// The wrong uses are refused before the tag is read.
	_, status := pairing_confirm(&run.joiner, &run.joiner_table, offerer_tag, {}, START_MS + 30)
	testing.expect_value(t, status, Pairing_Status.Refused_Bad_Uses)
	testing.expect_value(t, run.joiner.phase, Pairing_Phase.Failed)
	testing.expect_value(t, run.joiner_table.count, 0)

	// Input without View is refused as well, before the tag is read.
	run = {}
	offerer_tag, joiner_tag = pairing_test_exchange(t, &run, typed[:], binding, binding)
	_, input_alone := pairing_confirm(&run.joiner, &run.joiner_table, offerer_tag, {.Input}, START_MS + 30)
	testing.expect_value(t, input_alone, Pairing_Status.Refused_Bad_Uses)
	testing.expect_value(t, run.joiner_table.count, 0)

	// A new run, with good uses this time.
	run = {}
	offerer_tag, joiner_tag = pairing_test_exchange(t, &run, typed[:], binding, binding)
	joiner_row, joiner_status := pairing_confirm(&run.joiner, &run.joiner_table, offerer_tag, {.Calls}, START_MS + 30)
	testing.expect_value(t, joiner_status, Pairing_Status.Ok)
	offerer_row, offerer_status := pairing_confirm(&run.offerer, &run.offerer_table, joiner_tag, {.Calls, .View}, START_MS + 30)
	testing.expect_value(t, offerer_status, Pairing_Status.Ok)
	testing.expect(t, joiner_row.identity_key == OFFERER_KEY)
	testing.expect(t, offerer_row.identity_key == JOINER_KEY)
	testing.expect(t, joiner_row.uses == {.Calls})
	testing.expect(t, offerer_row.uses == {.Calls, .View})
	testing.expect_value(t, joiner_row.source, Paired_Machine_Source.Pairing)
	testing.expect_value(t, joiner_row.transcript_fingerprint, offerer_row.transcript_fingerprint)
	testing.expect(t, !bytes_all_zero(joiner_row.transcript_fingerprint[:]))
	testing.expect_value(t, run.joiner.phase, Pairing_Phase.Paired)
	testing.expect(t, bytes_all_zero(run.joiner.cpace.session_key[:]))
	testing.expect(t, bytes_all_zero(run.offerer.cpace.intermediate_session_key[:]))

	// The joiner types the same code again: the code is spent.
	testing.expect_value(t, pairing_join(&run.joiner, JOINER_KEY, typed[:], START_MS + 40), Pairing_Status.Ok)
	_, status = pairing_exchange_start(&run.joiner, &run.joiner_ledger, OFFERER_KEY, binding[:], pairing_test_scalar(3), START_MS + 40)
	testing.expect_value(t, status, Pairing_Status.Refused_Code_Spent)
	testing.expect_value(t, run.joiner.phase, Pairing_Phase.Failed)
	testing.expect_value(t, run.joiner_table.count, 1)

	// A pairing that reached the end cannot confirm a second time.
	_, status = pairing_confirm(&run.offerer, &run.offerer_table, joiner_tag, {.Calls}, START_MS + 50)
	testing.expect_value(t, status, Pairing_Status.Refused_Bad_Phase)
	testing.expect_value(t, run.offerer_table.count, 1)
}

@(test)
pairing_with_a_wrong_code_or_another_connection_fails_on_both_sides :: proc(t: ^testing.T) {
	random_bytes := [8]u8{0x5D, 0x11, 0x92, 0xE4, 0x07, 0xBB, 0x3A, 0xFF}
	secret, _ := pairing_code_secret_of_random(random_bytes)
	typed := pairing_code_text(secret)
	// One character changed.
	typed[9] = typed[9] == 'A' ? 'B' : 'A'
	binding := pairing_test_binding(2)

	run: Pairing_Test_Run
	offerer_tag, joiner_tag := pairing_test_exchange(t, &run, typed[:], binding, binding)
	_, joiner_status := pairing_confirm(&run.joiner, &run.joiner_table, offerer_tag, {.Calls}, START_MS + 30)
	_, offerer_status := pairing_confirm(&run.offerer, &run.offerer_table, joiner_tag, {.Calls}, START_MS + 30)
	testing.expect_value(t, joiner_status, Pairing_Status.Refused_Confirmation_Failed)
	testing.expect_value(t, offerer_status, Pairing_Status.Refused_Confirmation_Failed)
	testing.expect_value(t, run.joiner.phase, Pairing_Phase.Failed)
	testing.expect_value(t, run.offerer.phase, Pairing_Phase.Failed)
	testing.expect_value(t, run.joiner_table.count + run.offerer_table.count, 0)
	testing.expect(t, bytes_all_zero(run.joiner.cpace.session_key[:]))
	// The code ran once on the offerer: a second exchange with it is refused.
	testing.expect_value(t, run.offerer_ledger.count, 1)

	// The right code, but each side sees another connection: a relay that
	// joined two handshakes. The exporters differ, so the tags differ.
	run = {}
	right := pairing_code_text(secret)
	offerer_tag, joiner_tag = pairing_test_exchange(t, &run, right[:], pairing_test_binding(3), pairing_test_binding(4))
	_, joiner_status = pairing_confirm(&run.joiner, &run.joiner_table, offerer_tag, {.Calls}, START_MS + 30)
	_, offerer_status = pairing_confirm(&run.offerer, &run.offerer_table, joiner_tag, {.Calls}, START_MS + 30)
	testing.expect_value(t, joiner_status, Pairing_Status.Refused_Confirmation_Failed)
	testing.expect_value(t, offerer_status, Pairing_Status.Refused_Confirmation_Failed)
	testing.expect_value(t, run.joiner_table.count + run.offerer_table.count, 0)

	// A tag of all zeros, and a tag replayed from another run, are refused.
	run = {}
	offerer_tag, _ = pairing_test_exchange(t, &run, right[:], binding, binding)
	_, joiner_status = pairing_confirm(&run.joiner, &run.joiner_table, {}, {.Calls}, START_MS + 30)
	testing.expect_value(t, joiner_status, Pairing_Status.Refused_Confirmation_Failed)
	old_tag := offerer_tag
	run = {}
	_, _ = pairing_test_exchange(t, &run, right[:], pairing_test_binding(5), pairing_test_binding(5))
	_, joiner_status = pairing_confirm(&run.joiner, &run.joiner_table, old_tag, {.Calls}, START_MS + 30)
	testing.expect_value(t, joiner_status, Pairing_Status.Refused_Confirmation_Failed)
	testing.expect_value(t, run.joiner_table.count, 0)
}

@(test)
pairing_refuses_a_peer_whose_associated_data_is_not_its_handshake_key :: proc(t: ^testing.T) {
	random_bytes := [8]u8{0x21, 0x43, 0x65, 0x87, 0xA9, 0xCB, 0x02, 0x00}
	binding := pairing_test_binding(6)
	offerer: Pairing_Session
	joiner: Pairing_Session
	offerer_ledger: Pairing_Code_Ledger
	joiner_ledger: Pairing_Code_Ledger
	code, _ := pairing_offer(&offerer, OFFERER_KEY, random_bytes, START_MS)
	testing.expect_value(t, pairing_join(&joiner, JOINER_KEY, code[:], START_MS), Pairing_Status.Ok)
	// The joiner proved the handshake key of a relay, not of the offerer.
	_, status := pairing_exchange_start(&joiner, &joiner_ledger, RELAY_KEY, binding[:], pairing_test_scalar(1), START_MS)
	testing.expect_value(t, status, Pairing_Status.Ok)
	offerer_element, offerer_status := pairing_exchange_start(&offerer, &offerer_ledger, JOINER_KEY, binding[:], pairing_test_scalar(2), START_MS)
	testing.expect_value(t, offerer_status, Pairing_Status.Ok)
	offerer_identity := OFFERER_KEY
	_, status = pairing_exchange_finish(&joiner, offerer_element, offerer_identity[:])
	testing.expect_value(t, status, Pairing_Status.Refused_Peer_Key_Mismatch)
	testing.expect_value(t, joiner.phase, Pairing_Phase.Failed)
	testing.expect(t, bytes_all_zero(joiner.cpace.secret_scalar[:]))

	// Associated data of another length, and an identity element, are refused.
	joiner_identity := JOINER_KEY
	_, status = pairing_exchange_finish(&offerer, offerer_element, joiner_identity[:31])
	testing.expect_value(t, status, Pairing_Status.Refused_Peer_Key_Mismatch)
	offerer = {}
	offerer_ledger = {}
	_, _ = pairing_offer(&offerer, OFFERER_KEY, random_bytes, START_MS)
	_, _ = pairing_exchange_start(&offerer, &offerer_ledger, JOINER_KEY, binding[:], pairing_test_scalar(2), START_MS)
	_, status = pairing_exchange_finish(&offerer, {}, joiner_identity[:])
	testing.expect_value(t, status, Pairing_Status.Refused_Exchange)
	testing.expect_value(t, offerer.cpace_status, Cpace_Status.Refused_Identity_Point)
	testing.expect_value(t, offerer.phase, Pairing_Phase.Failed)
}

@(test)
pairing_code_ends_ten_minutes_after_its_start_and_never_before_it :: proc(t: ^testing.T) {
	binding := pairing_test_binding(7)
	random_bytes := [8]u8{9, 9, 9, 9, 9, 9, 0, 0}
	cases := [?]struct {
		now:     u64,
		expired: bool,
	}{
		{START_MS, false},
		{START_MS + PAIRING_CODE_LIFETIME_MS - 1, false},
		{START_MS + PAIRING_CODE_LIFETIME_MS, true},
		{START_MS + PAIRING_CODE_LIFETIME_MS + 1, true},
		{START_MS - 1, true}, // A clock that went back.
		{max(u64), true},
	}
	for item in cases {
		session: Pairing_Session
		ledger: Pairing_Code_Ledger
		_, _ = pairing_offer(&session, OFFERER_KEY, random_bytes, START_MS)
		_, status := pairing_exchange_start(&session, &ledger, JOINER_KEY, binding[:], pairing_test_scalar(1), item.now)
		if item.expired {
			testing.expect_value(t, status, Pairing_Status.Refused_Code_Expired)
			testing.expect_value(t, session.phase, Pairing_Phase.Failed)
			testing.expect_value(t, ledger.count, 0)
		} else {
			testing.expect_value(t, status, Pairing_Status.Ok)
		}
	}
}

@(test)
pairing_ledger_refuses_a_spent_code_and_refuses_when_full :: proc(t: ^testing.T) {
	ledger: Pairing_Code_Ledger
	testing.expect_value(t, pairing_ledger_spend(nil, {}, START_MS), Pairing_Status.Refused_Nil_Input)
	for index in 0 ..< MAX_SPENT_PAIRING_CODES {
		secret := [PAIRING_CODE_SECRET_SIZE]u8{0 = u8(index + 1)}
		testing.expect_value(t, pairing_ledger_spend(&ledger, secret, START_MS), Pairing_Status.Ok)
	}
	testing.expect_value(t, pairing_ledger_spend(&ledger, [PAIRING_CODE_SECRET_SIZE]u8{0 = 1}, START_MS + 1), Pairing_Status.Refused_Code_Spent)
	testing.expect_value(t, pairing_ledger_spend(&ledger, [PAIRING_CODE_SECRET_SIZE]u8{0 = 0x77}, START_MS + 1), Pairing_Status.Refused_Spent_Ledger_Full)
	// Just before the life of the codes ends, the ledger is still full.
	testing.expect_value(t, pairing_ledger_spend(&ledger, [PAIRING_CODE_SECRET_SIZE]u8{0 = 0x77}, START_MS + PAIRING_CODE_LIFETIME_MS - 1), Pairing_Status.Refused_Spent_Ledger_Full)
	testing.expect_value(t, pairing_ledger_spend(&ledger, [PAIRING_CODE_SECRET_SIZE]u8{0 = 0x77}, START_MS + PAIRING_CODE_LIFETIME_MS), Pairing_Status.Ok)
	testing.expect_value(t, ledger.count, 1)
	// A ledger whose count is damaged is refused, never read past its end.
	ledger.count = MAX_SPENT_PAIRING_CODES + 1
	testing.expect_value(t, pairing_ledger_spend(&ledger, [PAIRING_CODE_SECRET_SIZE]u8{0 = 0x78}, START_MS), Pairing_Status.Refused_Nil_Input)
	ledger.count = -1
	testing.expect_value(t, pairing_ledger_spend(&ledger, [PAIRING_CODE_SECRET_SIZE]u8{0 = 0x78}, START_MS), Pairing_Status.Refused_Nil_Input)
}

@(test)
paired_machine_table_refuses_duplicates_bad_rows_and_overflow :: proc(t: ^testing.T) {
	table: Paired_Machine_Table
	testing.expect_value(t, paired_machine_add(&table, Paired_Machine{uses = {.Calls}, source = .Pairing}), Pairing_Status.Refused_Zero_Key)
	testing.expect_value(t, paired_machine_add(&table, Paired_Machine{identity_key = OFFERER_KEY, uses = {}, source = .Pairing}), Pairing_Status.Refused_Bad_Uses)
	testing.expect_value(t, paired_machine_add(&table, Paired_Machine{identity_key = OFFERER_KEY, uses = {.Input}, source = .Pairing}), Pairing_Status.Refused_Bad_Uses)
	testing.expect_value(t, paired_machine_add(&table, Paired_Machine{identity_key = OFFERER_KEY, uses = {.Calls}, source = Paired_Machine_Source(0)}), Pairing_Status.Refused_Nil_Input)
	testing.expect_value(t, paired_machine_add(&table, Paired_Machine{identity_key = OFFERER_KEY, uses = {.Calls}, source = Paired_Machine_Source(3)}), Pairing_Status.Refused_Nil_Input)
	testing.expect_value(t, table.count, 0)

	for index in 0 ..< MAX_PAIRED_MACHINES {
		key := [PUBLIC_KEY_SIZE]u8{0 = u8(index + 1), 1 = 0xEE}
		testing.expect_value(t, paired_machine_add(&table, Paired_Machine{identity_key = key, uses = {.Calls}, source = .Pairing}), Pairing_Status.Ok)
	}
	first := [PUBLIC_KEY_SIZE]u8{0 = 1, 1 = 0xEE}
	testing.expect_value(t, paired_machine_add(&table, Paired_Machine{identity_key = first, uses = {.View}, source = .Pairing}), Pairing_Status.Refused_Already_Paired)
	testing.expect_value(t, paired_machine_add(&table, Paired_Machine{identity_key = OFFERER_KEY, uses = {.Calls}, source = .Pairing}), Pairing_Status.Refused_Table_Full)
	row, found := paired_machine_find(&table, first)
	testing.expect(t, found && row.uses == {.Calls})
	testing.expect(t, !paired_machine_remove(&table, OFFERER_KEY))
	testing.expect(t, !paired_machine_remove(&table, {}))
	testing.expect(t, paired_machine_remove(&table, first))
	testing.expect(t, !paired_machine_remove(&table, first))
	_, found = paired_machine_find(&table, first)
	testing.expect(t, !found)
	testing.expect_value(t, table.count, MAX_PAIRED_MACHINES - 1)
}

@(private = "file")
pairing_test_list_entry :: proc(seed: u8, tpm_attested: bool) -> Machine_Entry {
	_, machine_id := pairing_test_keypair(seed)
	_, signing := pairing_test_keypair(seed + 1)
	_, transport := pairing_test_keypair(seed + 2)
	return Machine_Entry {
		machine_id = machine_id,
		signing_public_key = signing,
		transport_public_key = transport,
		uses = {.Calls},
		tpm_attested = tpm_attested,
		state = .Active,
		added_at_ms = 1_000,
	}
}

@(private = "file")
pairing_test_sign_list :: proc(list: ^Signed_Machine_List, root: ^ed25519.Private_Key) {
	buffer: [MAX_MACHINE_LIST_SIGNING_BYTES]u8
	written, status := machine_list_signing_bytes(list, buffer[:])
	assert(status == .Accepted)
	ed25519.sign(root, buffer[:written], list.signature[:])
}

@(test)
machine_list_holder_refuses_downgrade_and_revokes_removed_machines_at_once :: proc(t: ^testing.T) {
	root_private, root_public := pairing_test_keypair(0x40)
	other_root_private, other_root_public := pairing_test_keypair(0x44)
	own := pairing_test_list_entry(0x50, true)
	laptop := pairing_test_list_entry(0x54, true)
	home := pairing_test_list_entry(0x58, true)

	holder: Machine_List_Holder
	table: Paired_Machine_Table
	testing.expect(t, !machine_list_holder_init(&holder, {}))
	testing.expect(t, machine_list_holder_init(&holder, root_public))
	// A pairing of principal 0 is not the list's to remove.
	testing.expect_value(t, paired_machine_add(&table, Paired_Machine{identity_key = RELAY_KEY, uses = {.Calls}, source = .Pairing}), Pairing_Status.Ok)

	first := Signed_Machine_List{principal_root_public_key = root_public, sequence_number = 5, entry_count = 3}
	first.entries[0] = own
	first.entries[1] = laptop
	first.entries[2] = home
	pairing_test_sign_list(&first, &root_private)

	// The first list of another principal is refused: the holder names one.
	foreign_list := first
	foreign_list.principal_root_public_key = other_root_public
	pairing_test_sign_list(&foreign_list, &other_root_private)
	status, revoked, added, not_added := machine_list_holder_update(&holder, &table, own.machine_id, &foreign_list, default_join_policy(), pairing_test_verify, 2_000)
	testing.expect_value(t, status, Machine_List_Status.Refused_Root_Key_Mismatch)
	testing.expect(t, !holder.has_list && table.count == 1)

	// A signature of another key over the right root key is refused.
	forged := first
	pairing_test_sign_list(&forged, &other_root_private)
	status, _, _, _ = machine_list_holder_update(&holder, &table, own.machine_id, &forged, default_join_policy(), pairing_test_verify, 2_000)
	testing.expect_value(t, status, Machine_List_Status.Refused_Invalid_Signature)
	status, _, _, _ = machine_list_holder_update(&holder, &table, own.machine_id, &first, default_join_policy(), nil, 2_000)
	testing.expect_value(t, status, Machine_List_Status.Refused_Invalid_Signature)
	testing.expect(t, !holder.has_list && table.count == 1)

	status, revoked, added, not_added = machine_list_holder_update(&holder, &table, own.machine_id, &first, default_join_policy(), pairing_test_verify, 2_000)
	testing.expect_value(t, status, Machine_List_Status.Accepted)
	testing.expect_value(t, revoked, 0)
	testing.expect_value(t, added, 2) // Not this machine itself.
	testing.expect_value(t, not_added, 0)
	_, own_found := paired_machine_find(&table, own.machine_id)
	testing.expect(t, !own_found)
	home_row, home_found := paired_machine_find(&table, home.machine_id)
	testing.expect(t, home_found && home_row.source == .Machine_List)

	// The same list again, and an older one, are refused and change nothing.
	status, _, _, _ = machine_list_holder_update(&holder, &table, own.machine_id, &first, default_join_policy(), pairing_test_verify, 2_100)
	testing.expect_value(t, status, Machine_List_Status.Refused_Replay_Or_Downgrade)
	older := first
	older.sequence_number = 4
	older.entry_count = 2
	pairing_test_sign_list(&older, &root_private)
	status, _, _, _ = machine_list_holder_update(&holder, &table, own.machine_id, &older, default_join_policy(), pairing_test_verify, 2_100)
	testing.expect_value(t, status, Machine_List_Status.Refused_Replay_Or_Downgrade)
	testing.expect_value(t, table.count, 3)
	testing.expect_value(t, holder.list.sequence_number, u64(5))

	// A newer list without home: its row leaves at once.
	second := first
	second.sequence_number = 6
	second.entry_count = 2
	second.entries[2] = {}
	pairing_test_sign_list(&second, &root_private)
	status, revoked, added, _ = machine_list_holder_update(&holder, &table, own.machine_id, &second, default_join_policy(), pairing_test_verify, 3_000)
	testing.expect_value(t, status, Machine_List_Status.Accepted)
	testing.expect_value(t, revoked, 1)
	testing.expect_value(t, added, 0)
	_, home_found = paired_machine_find(&table, home.machine_id)
	testing.expect(t, !home_found)
	_, relay_found := paired_machine_find(&table, RELAY_KEY)
	testing.expect(t, relay_found)

	// A newer list that keeps laptop as Revoked removes it too.
	third := second
	third.sequence_number = 7
	third.entries[1].state = .Revoked
	third.entries[1].revoked_at_ms = 3_500
	pairing_test_sign_list(&third, &root_private)
	status, revoked, _, _ = machine_list_holder_update(&holder, &table, own.machine_id, &third, default_join_policy(), pairing_test_verify, 4_000)
	testing.expect_value(t, status, Machine_List_Status.Accepted)
	testing.expect_value(t, revoked, 1)
	testing.expect_value(t, table.count, 1)

	// A machine with no TPM attestation is refused by default, and the
	// refusal leaves the list and the table as they were.
	untrusted := third
	untrusted.sequence_number = 8
	untrusted.entry_count = 3
	untrusted.entries[2] = pairing_test_list_entry(0x60, false)
	pairing_test_sign_list(&untrusted, &root_private)
	status, _, _, _ = machine_list_holder_update(&holder, &table, own.machine_id, &untrusted, default_join_policy(), pairing_test_verify, 5_000)
	testing.expect_value(t, status, Machine_List_Status.Refused_Without_Tpm)
	testing.expect_value(t, holder.list.sequence_number, u64(7))
	testing.expect_value(t, table.count, 1)
	status, _, added, _ = machine_list_holder_update(&holder, &table, own.machine_id, &untrusted, Join_Policy{allow_without_tpm = true}, pairing_test_verify, 5_000)
	testing.expect_value(t, status, Machine_List_Status.Accepted_Without_Tpm_Warning)
	testing.expect_value(t, added, 1)
}

@(test)
signed_grant_from_the_wire_is_refused_past_one_day_when_revoked_and_when_damaged :: proc(t: ^testing.T) {
	root_private, root_public := pairing_test_keypair(0x70)
	_, grantee_root := pairing_test_keypair(0x74)
	machine := pairing_test_list_entry(0x78, true)
	signing_private, _ := pairing_test_keypair(0x78 + 1)
	list := Signed_Machine_List{principal_root_public_key = root_public, sequence_number = 1, entry_count = 1}
	list.entries[0] = machine
	pairing_test_sign_list(&list, &root_private)

	issued := u64(1_000_000)
	grant := Signed_Grant {
		grant_serial               = 9,
		grantor_root_public_key    = root_public,
		grantor_signing_public_key = machine.signing_public_key,
		serving_machine_id         = machine.machine_id,
		grantee_root_public_key    = grantee_root,
		target_kind                = .Store_Object,
		target_hash                = pairing_test_scalar(0x11),
		rights                     = {.Read},
		issued_at_ms               = issued,
		expires_at_ms              = issued + MAX_SHORT_GRANT_LIFE_MS,
	}
	sign := proc(grant: ^Signed_Grant, key: ^ed25519.Private_Key) {
		bytes, status := signed_grant_signing_bytes(grant)
		assert(status == .Accepted)
		ed25519.sign(key, bytes[:], grant.signature[:])
	}
	sign(&grant, &signing_private)
	wire: [SIGNED_GRANT_WIRE_SIZE]u8
	written, encode_status := signed_grant_encode(&grant, wire[:])
	testing.expect_value(t, encode_status, Grant_Check_Status.Accepted)
	testing.expect_value(t, written, SIGNED_GRANT_WIRE_SIZE)
	decoded, decode_status := signed_grant_decode(wire[:])
	testing.expect_value(t, decode_status, Grant_Check_Status.Accepted)
	testing.expect_value(t, signed_grant_check(&decoded, &list, machine.machine_id, grantee_root, issued + 1, nil, pairing_test_verify), Grant_Check_Status.Accepted)
	// The last millisecond of the day, then the end of the day.
	testing.expect_value(t, signed_grant_check(&decoded, &list, machine.machine_id, grantee_root, issued + MAX_SHORT_GRANT_LIFE_MS - 1, nil, pairing_test_verify), Grant_Check_Status.Accepted)
	testing.expect_value(t, signed_grant_check(&decoded, &list, machine.machine_id, grantee_root, issued + MAX_SHORT_GRANT_LIFE_MS, nil, pairing_test_verify), Grant_Check_Status.Refused_Expired)
	testing.expect_value(t, signed_grant_check(&decoded, &list, machine.machine_id, grantee_root, max(u64), nil, pairing_test_verify), Grant_Check_Status.Refused_Expired)

	// Each byte of the wire that changes is refused: by the decoder, or by
	// the signature. None is accepted.
	for index in 0 ..< SIGNED_GRANT_WIRE_SIZE {
		damaged := wire
		damaged[index] ~= 0x01
		candidate, status := signed_grant_decode(damaged[:])
		if status == .Accepted {
			status = signed_grant_check(&candidate, &list, machine.machine_id, grantee_root, issued + 1, nil, pairing_test_verify)
		}
		testing.expect(t, status != .Accepted)
	}
	_, short_status := signed_grant_decode(wire[:SIGNED_GRANT_WIRE_SIZE - 1])
	testing.expect(t, short_status != .Accepted)

	// More than one day with no revocation list: refused, also while young.
	long := grant
	long.expires_at_ms = issued + MAX_SHORT_GRANT_LIFE_MS + 1
	sign(&long, &signing_private)
	testing.expect_value(t, signed_grant_check(&long, &list, machine.machine_id, grantee_root, issued + 1, nil, pairing_test_verify), Grant_Check_Status.Refused_Long_Grant_Without_Revocation)

	// A revocation list that names the serial ends the grant before its day.
	revocations := Revocation_List{grantor_root_public_key = root_public, signer_public_key = machine.signing_public_key, epoch = 1, revoked_count = 1}
	revocations.revoked_serials[0] = grant.grant_serial
	revocation_bytes: [INLINE_REVOCATION_LIST_SIGNING_BYTES]u8
	revocation_written, revocation_status := revocation_list_signing_bytes(&revocations, revocation_bytes[:])
	testing.expect_value(t, revocation_status, Revocation_List_Status.Accepted)
	ed25519.sign(&signing_private, revocation_bytes[:revocation_written], revocations.signature[:])
	testing.expect_value(t, signed_grant_check(&decoded, &list, machine.machine_id, grantee_root, issued + 1, &revocations, pairing_test_verify), Grant_Check_Status.Refused_Revoked)
	// A revocation list changed after its signature (the serial taken out)
	// is refused with the grant, never ignored.
	forged := revocations
	forged.revoked_count = 0
	forged.revoked_serials[0] = 0
	testing.expect_value(t, signed_grant_check(&decoded, &list, machine.machine_id, grantee_root, issued + 1, &forged, pairing_test_verify), Grant_Check_Status.Refused_Bad_Revocation_List)

	// A grant for another serving machine, or for another receiver.
	_, other_machine := pairing_test_keypair(0x90)
	testing.expect_value(t, signed_grant_check(&decoded, &list, other_machine, grantee_root, issued + 1, nil, pairing_test_verify), Grant_Check_Status.Refused_Wrong_Serving_Machine)
	testing.expect_value(t, signed_grant_check(&decoded, &list, machine.machine_id, other_machine, issued + 1, nil, pairing_test_verify), Grant_Check_Status.Refused_Wrong_Grantee)
}
