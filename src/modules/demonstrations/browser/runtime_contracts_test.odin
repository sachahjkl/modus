#+build !freestanding
package browser

import "core:testing"
import "modus:contract/hardware_keys"
import "modus:contract/origin_browser"
import "modus:contract/rich_toolkit"

@(private = "file")
test_hwk_verify_accept :: proc "contextless" (
	public_key: [hardware_keys.HARDWARE_KEY_PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [hardware_keys.HARDWARE_KEY_SIGNATURE_SIZE]u8,
	user: rawptr,
) -> bool {
	_ = public_key
	_ = message
	return signature[0] == 0xA5 && user == nil
}

@(private = "file")
test_hwk_verify_reject :: proc "contextless" (
	public_key: [hardware_keys.HARDWARE_KEY_PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [hardware_keys.HARDWARE_KEY_SIGNATURE_SIZE]u8,
	user: rawptr,
) -> bool {
	_ = public_key
	_ = message
	_ = signature
	_ = user
	return false
}

@(test)
browser_origin_table_history_forms_and_style_tokens :: proc(t: ^testing.T) {
	globals_hold()
	origin_states = {}
	origin_process_table = {}
	web_history = origin_browser.history_init()

	// Origin process table gives distinct isolated slots to distinct web origins
	// and refuses cross-origin access.
	addr_a, prob_a := address_parse("https://alpha.example")
	addr_b, prob_b := address_parse("https://beta.example")
	testing.expect_value(t, prob_a, Address_Problem.None)
	testing.expect_value(t, prob_b, Address_Problem.None)
	orig_a := origin_of(&addr_a)
	orig_b := origin_of(&addr_b)

	testing.expect_value(t, origin_storage_write(&orig_a, "token", "secret-alpha"), Origin_Reply_Status.Done)
	testing.expect_value(t, origin_storage_write(&orig_b, "token", "secret-beta"), Origin_Reply_Status.Done)

	state_a := origin_state_find(&orig_a, false)
	state_b := origin_state_find(&orig_b, false)
	testing.expect(t, state_a != nil && state_b != nil)
	testing.expect(t, state_a.process_id != 0 && state_b.process_id != 0 && state_a.process_id != state_b.process_id)
	testing.expect_value(t, browser_origin_enforce(state_a.process_id, &orig_a), origin_browser.Origin_Browser_Refusal.None)
	testing.expect_value(t, browser_origin_enforce(state_a.process_id, &orig_b), origin_browser.Origin_Browser_Refusal.Cross_Origin_Denied)
	// Web origins fail closed on process_id == 0.
	testing.expect_value(t, browser_origin_enforce(0, &orig_a), origin_browser.Origin_Browser_Refusal.Process_Not_Found)

	// Full origin process table fails closed instead of creating an unbound state.
	for i in 0 ..< origin_browser.ORIGIN_PROCESS_CAPACITY {
		host_buf: [32]u8
		w := Source_Writer{bytes = host_buf[:]}
		put(&w, "https://slot")
		put_number(&w, u64(i))
		put(&w, ".example")
		a, p := address_parse(writer_text(&w))
		testing.expect_value(t, p, Address_Problem.None)
		o := origin_of(&a)
		_, _ = browser_origin_acquire_slot(&o)
	}
	extra_addr, _ := address_parse("https://overflow-origin.example")
	extra_orig := origin_of(&extra_addr)
	testing.expect_value(t, origin_storage_write(&extra_orig, "k", "v"), Origin_Reply_Status.Refused_Other_Origin)
	testing.expect(t, origin_state_find(&extra_orig, false) == nil)
	origin_process_table = {}
	origin_states = {}

	// Refused web URL leaves current page unchanged in page_load.
	testing.expect(t, page_load("https://alpha.example/home", true))
	before_current := current
	testing.expect(t, !page_load("https://alpha.example/bad path", true))
	testing.expect_value(t, current, before_current)

	// URL validation refuses embedded credentials and control bytes.
	_, cred_ref := browser_web_url_check("https://user:pass@alpha.example/login")
	testing.expect_value(t, cred_ref, origin_browser.Origin_Browser_Refusal.Credentials_Refused)
	_, ctrl_ref := browser_web_url_check("https://alpha.example/\n")
	testing.expect_value(t, ctrl_ref, origin_browser.Origin_Browser_Refusal.Bad_Control_Byte)

	// Web history navigation records HTTP/HTTPS entries and moves back/forward.
	_, nav1 := browser_web_history_record("https://alpha.example/one")
	_, nav2 := browser_web_history_record("https://beta.example/two")
	testing.expect_value(t, nav1, origin_browser.Origin_Browser_Refusal.None)
	testing.expect_value(t, nav2, origin_browser.Origin_Browser_Refusal.None)
	back_entry, back_ref := origin_browser.history_back(&web_history)
	testing.expect_value(t, back_ref, origin_browser.Origin_Browser_Refusal.None)
	testing.expect_value(t, origin_browser.history_entry_url(back_entry), "https://alpha.example/one")

	// Form encoding via origin_browser refuses undersized output with zero mutation.
	fields := [2]origin_browser.Form_Field{
		{name = "q", value = "hello world&x=1"},
		{name = "page", value = "2"},
	}
	small: [4]u8 = {0xCC, 0xCC, 0xCC, 0xCC}
	_, small_ref := browser_form_encode_fields(fields[:], small[:])
	testing.expect_value(t, small_ref, origin_browser.Origin_Browser_Refusal.Buffer_Too_Small)
	testing.expect_value(t, small[0], u8(0xCC))

	encoded: [64]u8
	written, enc_ref := browser_form_encode_fields(fields[:], encoded[:])
	testing.expect_value(t, enc_ref, origin_browser.Origin_Browser_Refusal.None)
	testing.expect_value(t, string(encoded[:written]), "q=hello+world%26x%3D1&page=2")

	// gui_toolkit style tokens keep rectangular geometry and expected heights.
	dark := browser_style_tokens(.Dark, false)
	light := browser_style_tokens(.Light, false)
	hc := browser_style_tokens(.Dark, true)
	testing.expect_value(t, dark, rich_toolkit.MODUS_GUI_TOOLKIT_DARK)
	testing.expect_value(t, hc, rich_toolkit.MODUS_GUI_TOOLKIT_HIGH_CONTRAST)
	testing.expect_value(t, light.corner_radius_px, i32(0))
	testing.expect_value(t, light.bar_height_px, i32(28))
}

@(test)
browser_webauthn_hardware_key_enforces_origin_purpose_and_sign_count :: proc(t: ^testing.T) {
	globals_hold()
	origin_states = {}
	origin_process_table = {}
	webauthn_challenges = {}

	addr_a, _ := address_parse("https://bank.example")
	addr_a_port, _ := address_parse("https://bank.example:8443")
	addr_http, _ := address_parse("http://bank.example")
	addr_b, _ := address_parse("https://evil.example")
	orig_a := origin_of(&addr_a)
	orig_a_port := origin_of(&addr_a_port)
	orig_http := origin_of(&addr_http)
	orig_b := origin_of(&addr_b)

	pid_a, ref_a := browser_origin_acquire_slot(&orig_a)
	pid_a_port, ref_ap := browser_origin_acquire_slot(&orig_a_port)
	pid_http, ref_http := browser_origin_acquire_slot(&orig_http)
	pid_b, ref_b := browser_origin_acquire_slot(&orig_b)
	testing.expect(t, ref_a == .None && ref_ap == .None && ref_http == .None && ref_b == .None)
	testing.expect(t, pid_a != pid_b && pid_a != pid_a_port)

	challenge: [hardware_keys.HARDWARE_KEY_CHALLENGE_SIZE]u8
	pub_key: [hardware_keys.HARDWARE_KEY_PUBLIC_KEY_SIZE]u8
	sig: [hardware_keys.HARDWARE_KEY_SIGNATURE_SIZE]u8
	challenge[0] = 0x11
	pub_key[0] = 0x22
	sig[0] = 0xA5
	scope_buf: [hardware_keys.HARDWARE_KEY_SCOPE_LIMIT]u8

	// Insecure http:// origin is refused for WebAuthn challenge issuance.
	_, http_ref := browser_webauthn_challenge_issue(pid_http, &orig_http, challenge, true, &scope_buf)
	testing.expect_value(t, http_ref, hardware_keys.Hardware_Key_Refusal.Scope_Mismatch)

	// Zero nonce is refused.
	_, zero_ref := browser_webauthn_challenge_issue(pid_a, &orig_a, {}, true, &scope_buf)
	testing.expect_value(t, zero_ref, hardware_keys.Hardware_Key_Refusal.Zero_Challenge)

	// Built-in modus:// origin has no WebAuthn surface and is refused.
	modus_addr, _ := address_parse("modus://welcome")
	modus_orig := origin_of(&modus_addr)
	_, modus_ref := browser_webauthn_challenge_issue(pid_a, &modus_orig, challenge, true, &scope_buf)
	testing.expect_value(t, modus_ref, hardware_keys.Hardware_Key_Refusal.Scope_Mismatch)

	// Full origin scope includes scheme, host, and explicit port.
	ch, ch_ref := browser_webauthn_challenge_issue(pid_a, &orig_a, challenge, true, &scope_buf)
	testing.expect_value(t, ch_ref, hardware_keys.Hardware_Key_Refusal.None)
	testing.expect_value(t, ch.scope, "https://bank.example:443")

	assertion := hardware_keys.Hardware_Key_Assertion{
		version    = hardware_keys.HARDWARE_KEY_VERSION,
		protocol   = .Ctap2_Fido2,
		purpose    = .Browser_WebAuthn,
		flags      = {.User_Present, .User_Verified},
		sign_count = 10,
		challenge  = challenge,
		public_key = pub_key,
		signature  = sig,
	}
	testing.expect_value(t, hardware_keys.hardware_key_assertion_scope_set(&assertion, "https://bank.example:443"), hardware_keys.Hardware_Key_Refusal.None)
	wire: [hardware_keys.HARDWARE_KEY_WIRE_LIMIT]u8
	wire_len, enc_ref := hardware_keys.hardware_key_assertion_encode(&assertion, wire[:])
	testing.expect_value(t, enc_ref, hardware_keys.Hardware_Key_Refusal.None)

	// Cross-origin process slot is refused before consuming pid_a's challenge.
	_, cross_ref := browser_webauthn_verify_assertion(pid_b, &orig_a, wire[:wire_len], pub_key, 5, test_hwk_verify_accept)
	testing.expect_value(t, cross_ref, hardware_keys.Hardware_Key_Refusal.Scope_Mismatch)

	// Different port origin (bank.example:8443) cannot use bank.example:443 assertion.
	_, port_ch_ref := browser_webauthn_challenge_issue(pid_a_port, &orig_a_port, challenge, true, &scope_buf)
	testing.expect_value(t, port_ch_ref, hardware_keys.Hardware_Key_Refusal.None)
	_, port_ref := browser_webauthn_verify_assertion(pid_a_port, &orig_a_port, wire[:wire_len], pub_key, 5, test_hwk_verify_accept)
	testing.expect_value(t, port_ref, hardware_keys.Hardware_Key_Refusal.Scope_Mismatch)

	// Cross-purpose assertion (.Unlock replayed to browser WebAuthn) is refused and consumes challenge.
	wrong_purpose := assertion
	wrong_purpose.purpose = .Unlock
	wrong_wire: [hardware_keys.HARDWARE_KEY_WIRE_LIMIT]u8
	wrong_len, _ := hardware_keys.hardware_key_assertion_encode(&wrong_purpose, wrong_wire[:])
	_, purp_ref := browser_webauthn_verify_assertion(pid_a, &orig_a, wrong_wire[:wrong_len], pub_key, 5, test_hwk_verify_accept)
	testing.expect_value(t, purp_ref, hardware_keys.Hardware_Key_Refusal.Purpose_Mismatch)

	// Missing pending challenge after consumption is refused.
	_, missing_ref := browser_webauthn_verify_assertion(pid_a, &orig_a, wire[:wire_len], pub_key, 5, test_hwk_verify_accept)
	testing.expect_value(t, missing_ref, hardware_keys.Hardware_Key_Refusal.Zero_Challenge)

	// Bad cryptographic signature is refused on a fresh challenge.
	_, _ = browser_webauthn_challenge_issue(pid_a, &orig_a, challenge, true, &scope_buf)
	_, bad_sig_ref := browser_webauthn_verify_assertion(pid_a, &orig_a, wire[:wire_len], pub_key, 5, test_hwk_verify_reject)
	testing.expect_value(t, bad_sig_ref, hardware_keys.Hardware_Key_Refusal.Bad_Signature)

	// Valid assertion succeeds and advances sign_count to 10.
	_, _ = browser_webauthn_challenge_issue(pid_a, &orig_a, challenge, true, &scope_buf)
	new_count, ok_ref := browser_webauthn_verify_assertion(pid_a, &orig_a, wire[:wire_len], pub_key, 5, test_hwk_verify_accept)
	testing.expect_value(t, ok_ref, hardware_keys.Hardware_Key_Refusal.None)
	testing.expect_value(t, new_count, u32(10))

	// Immediate replay of consumed challenge is refused with Zero_Challenge.
	_, replay_ref := browser_webauthn_verify_assertion(pid_a, &orig_a, wire[:wire_len], pub_key, 10, test_hwk_verify_accept)
	testing.expect_value(t, replay_ref, hardware_keys.Hardware_Key_Refusal.Zero_Challenge)

	// Rollback of monotonic sign_count is refused even if caller passes a lower count.
	_, _ = browser_webauthn_challenge_issue(pid_a, &orig_a, challenge, true, &scope_buf)
	_, roll_ref := browser_webauthn_verify_assertion(pid_a, &orig_a, wire[:wire_len], pub_key, 0, test_hwk_verify_accept)
	testing.expect_value(t, roll_ref, hardware_keys.Hardware_Key_Refusal.Sign_Count_Rollback)
}
