// Live runtime wiring of modus:contract/origin_browser,
// modus:contract/rich_toolkit, and modus:contract/hardware_keys in the
// browser module (src/md/features/desktop_to_browser.md;
// src/md/features/hardware_keys.md).
//
// Enforces 1-process-per-origin slot isolation and bounded web history via
// origin_browser, synchronizes gui_toolkit style palette tokens via
// rich_toolkit, and verifies origin-bound WebAuthn assertions via
// hardware_keys without heap allocation.
package browser

import "modus:contract/hardware_keys"
import "modus:contract/html_css"
import "modus:contract/origin_browser"
import "modus:contract/rich_toolkit"
import "modus:graphics"

// Package-level BSS state for live origin isolation, web history, and
// single-use WebAuthn challenges.
origin_process_table: origin_browser.Origin_Process_Table
web_history: origin_browser.History_Stack
current_style_tokens: rich_toolkit.Modus_Style_Tokens

// Plan value: one pending WebAuthn challenge slot per isolated origin slot.
Webauthn_Pending_Challenge :: struct {
	active:                    bool,
	has_pending:               bool,
	process_id:                u64,
	origin:                    origin_browser.Web_Origin,
	nonce:                     [hardware_keys.HARDWARE_KEY_CHALLENGE_SIZE]u8,
	require_user_verification: bool,
	last_sign_count:           u32,
}

webauthn_challenges: [origin_browser.ORIGIN_PROCESS_CAPACITY]Webauthn_Pending_Challenge

// Light appearance counterpart to rich_toolkit.MODUS_GUI_TOOLKIT_DARK keeping
// rectangular forms and matching unit spacing (docs/DESIGN.md).
MODUS_GUI_TOOLKIT_LIGHT :: rich_toolkit.Modus_Style_Tokens{
	background_rgba   = 0xF5F7FAFF,
	surface_rgba      = 0xFFFFFFFF,
	border_rgba       = 0xCFD6E0FF,
	text_primary_rgba = 0x11161EFF,
	text_muted_rgba   = 0x526071FF,
	accent_rgba       = 0x1D6FD6FF,
	danger_rgba       = 0xC63737FF,
	corner_radius_px  = 0,
	border_width_px   = 1,
	unit_spacing_px   = 8,
	bar_height_px     = 28,
}

// browser_style_tokens selects the active gui_toolkit style token palette for
// the current desktop appearance and contrast preference.
browser_style_tokens :: proc "contextless" (appearance: graphics.Appearance, high_contrast: bool) -> rich_toolkit.Modus_Style_Tokens {
	if high_contrast {
		return rich_toolkit.MODUS_GUI_TOOLKIT_HIGH_CONTRAST
	}
	switch appearance {
	case .Dark:
		return rich_toolkit.MODUS_GUI_TOOLKIT_DARK
	case .Light:
		return MODUS_GUI_TOOLKIT_LIGHT
	}
	return rich_toolkit.MODUS_GUI_TOOLKIT_DARK
}

// document_origin_to_web_origin converts an HTTP or HTTPS html_css origin
// into a validated canonical origin_browser.Web_Origin tuple. modus://
// built-in pages return is_web = false.
document_origin_to_web_origin :: proc "contextless" (origin: ^html_css.Document_Origin) -> (web: origin_browser.Web_Origin, is_web: bool) {
	if origin == nil {
		return {}, false
	}
	scheme_prefix: string
	switch origin.scheme {
	case .Http:
		scheme_prefix = "http://"
	case .Https:
		scheme_prefix = "https://"
	case .Modus:
		return {}, false
	}
	if origin.host_len == 0 || int(origin.host_len) > origin_browser.ORIGIN_HOST_MAX_BYTES {
		return {}, false
	}
	url_buf: [origin_browser.ORIGIN_HOST_MAX_BYTES + 24]u8
	writer := Source_Writer{bytes = url_buf[:]}
	put(&writer, scheme_prefix)
	put(&writer, string(origin.host[:origin.host_len]))
	if origin.port != 0 {
		put(&writer, ":")
		put_number(&writer, u64(origin.port))
	}
	if writer.full {
		return {}, false
	}
	parsed, ref := origin_browser.origin_parse_url(writer_text(&writer))
	if ref != .None {
		return {}, false
	}
	return parsed, true
}

// browser_origin_acquire_slot acquires or reuses the isolated renderer slot
// for an HTTP/HTTPS origin in origin_process_table.
browser_origin_acquire_slot :: proc "contextless" (origin: ^html_css.Document_Origin) -> (process_id: u64, refusal: origin_browser.Origin_Browser_Refusal) {
	web, is_web := document_origin_to_web_origin(origin)
	if !is_web {
		return 0, .None
	}
	pid, _, ref := origin_browser.origin_table_acquire(&origin_process_table, web)
	return pid, ref
}

// browser_origin_release_slot releases an evicted HTTP/HTTPS origin's slot
// and clears any pending WebAuthn challenge bound to that process slot.
browser_origin_release_slot :: proc "contextless" (process_id: u64) {
	if process_id == 0 {
		return
	}
	for &entry in webauthn_challenges {
		if entry.active && entry.process_id == process_id {
			entry = {}
		}
	}
	_ = origin_browser.origin_table_release(&origin_process_table, process_id)
}

// browser_origin_enforce checks that the active renderer process slot bound
// to requester is strictly permitted to access owner. Web origins fail closed
// if process_id is zero.
browser_origin_enforce :: proc "contextless" (process_id: u64, owner: ^html_css.Document_Origin) -> origin_browser.Origin_Browser_Refusal {
	web_owner, is_web := document_origin_to_web_origin(owner)
	if !is_web {
		return .None
	}
	if process_id == 0 {
		return .Process_Not_Found
	}
	return origin_browser.origin_table_may_access(&origin_process_table, process_id, web_owner)
}

// browser_web_url_check validates an HTTP/HTTPS navigation target through
// origin_browser.origin_parse_url, refusing embedded credentials, control
// bytes, and malformed hosts.
browser_web_url_check :: proc "contextless" (raw_url: string) -> (web: origin_browser.Web_Origin, refusal: origin_browser.Origin_Browser_Refusal) {
	return origin_browser.origin_parse_url(raw_url)
}

// browser_web_history_record appends a validated HTTP/HTTPS URL to the
// bounded origin_browser.History_Stack.
browser_web_history_record :: proc "contextless" (raw_url: string) -> (web: origin_browser.Web_Origin, refusal: origin_browser.Origin_Browser_Refusal) {
	return origin_browser.history_navigate(&web_history, raw_url)
}

// browser_form_encode_fields encodes HTML form fields with WHATWG
// application/x-www-form-urlencoded rules via origin_browser.
browser_form_encode_fields :: proc "contextless" (
	fields: []origin_browser.Form_Field,
	out: []u8,
) -> (written: int, refusal: origin_browser.Origin_Browser_Refusal) {
	return origin_browser.form_encode_urlencoded(fields, out)
}

// browser_webauthn_origin_scope formats the full canonical HTTPS WebAuthn
// origin scope ("https://<host>:<port>") into out, strictly refusing http://
// and modus:// origins.
browser_webauthn_origin_scope :: proc "contextless" (
	origin: ^html_css.Document_Origin,
	out: ^[hardware_keys.HARDWARE_KEY_SCOPE_LIMIT]u8,
) -> (scope: string, refusal: hardware_keys.Hardware_Key_Refusal) {
	if out == nil {
		return "", .Bad_Wire_Length
	}
	web_origin, is_web := document_origin_to_web_origin(origin)
	if !is_web || web_origin.scheme != .Https {
		return "", .Scope_Mismatch
	}
	writer := Source_Writer{bytes = out[:]}
	put(&writer, "https://")
	put(&writer, origin_browser.origin_host(&web_origin))
	put(&writer, ":")
	put_number(&writer, u64(web_origin.port))
	if writer.full {
		return "", .Scope_Too_Long
	}
	return writer_text(&writer), .None
}

// browser_webauthn_challenge_issue registers a single-use 32-byte WebAuthn
// challenge bound to process_id and an isolated HTTPS origin.
browser_webauthn_challenge_issue :: proc "contextless" (
	process_id: u64,
	origin: ^html_css.Document_Origin,
	nonce: [hardware_keys.HARDWARE_KEY_CHALLENGE_SIZE]u8,
	require_user_verification: bool,
	scope_out: ^[hardware_keys.HARDWARE_KEY_SCOPE_LIMIT]u8,
) -> (challenge: hardware_keys.Hardware_Key_Challenge, refusal: hardware_keys.Hardware_Key_Refusal) {
	web_origin, is_web := document_origin_to_web_origin(origin)
	if !is_web || web_origin.scheme != .Https || process_id == 0 {
		return {}, .Scope_Mismatch
	}
	if origin_browser.origin_table_may_access(&origin_process_table, process_id, web_origin) != .None {
		return {}, .Scope_Mismatch
	}
	acc: u8
	for b in nonce {
		acc |= b
	}
	if acc == 0 {
		return {}, .Zero_Challenge
	}
	scope, scope_ref := browser_webauthn_origin_scope(origin, scope_out)
	if scope_ref != .None {
		return {}, scope_ref
	}
	slot: ^Webauthn_Pending_Challenge
	for &entry in webauthn_challenges {
		if entry.active && entry.process_id == process_id {
			slot = &entry
			break
		}
	}
	if slot == nil {
		for &entry in webauthn_challenges {
			if !entry.active {
				slot = &entry
				break
			}
		}
	}
	if slot == nil {
		return {}, .Bad_Wire_Length
	}
	slot.active = true
	slot.has_pending = true
	slot.process_id = process_id
	slot.origin = web_origin
	slot.nonce = nonce
	slot.require_user_verification = require_user_verification
	return hardware_keys.Hardware_Key_Challenge{
		protocol                  = .Ctap2_Fido2,
		purpose                   = .Browser_WebAuthn,
		challenge                 = nonce,
		scope                     = scope,
		require_user_presence     = true,
		require_user_verification = require_user_verification,
	}, .None
}

// browser_webauthn_verify_assertion consumes the single-use pending challenge
// for process_id and verifies a canonical hardware-key WebAuthn assertion
// bound strictly to HTTPS scheme, canonical host, port, and monotonic count.
browser_webauthn_verify_assertion :: proc "contextless" (
	process_id: u64,
	origin: ^html_css.Document_Origin,
	wire_assertion: []u8,
	expected_public_key: [hardware_keys.HARDWARE_KEY_PUBLIC_KEY_SIZE]u8,
	last_sign_count: u32,
	verify_sig: hardware_keys.Hardware_Key_Verify_Proc,
	user: rawptr = nil,
) -> (new_sign_count: u32, refusal: hardware_keys.Hardware_Key_Refusal) {
	web_origin, is_web := document_origin_to_web_origin(origin)
	if !is_web || web_origin.scheme != .Https || process_id == 0 {
		return last_sign_count, .Scope_Mismatch
	}
	if origin_browser.origin_table_may_access(&origin_process_table, process_id, web_origin) != .None {
		return last_sign_count, .Scope_Mismatch
	}
	slot: ^Webauthn_Pending_Challenge
	for &entry in webauthn_challenges {
		if entry.active && entry.process_id == process_id {
			slot = &entry
			break
		}
	}
	if slot == nil || !slot.has_pending {
		return last_sign_count, .Zero_Challenge
	}
	if !origin_browser.origin_equal(&slot.origin, &web_origin) {
		return last_sign_count, .Scope_Mismatch
	}

	// Consume single-use challenge before decoding or verifying the assertion.
	pending_nonce := slot.nonce
	require_uv := slot.require_user_verification
	slot.has_pending = false
	slot.nonce = {}

	scope_buf: [hardware_keys.HARDWARE_KEY_SCOPE_LIMIT]u8
	scope, scope_ref := browser_webauthn_origin_scope(origin, &scope_buf)
	if scope_ref != .None {
		return last_sign_count, scope_ref
	}
	assertion, dec_ref := hardware_keys.hardware_key_assertion_decode(wire_assertion)
	if dec_ref != .None {
		return last_sign_count, dec_ref
	}
	effective_last := max(last_sign_count, slot.last_sign_count)
	challenge := hardware_keys.Hardware_Key_Challenge{
		protocol                  = .Ctap2_Fido2,
		purpose                   = .Browser_WebAuthn,
		challenge                 = pending_nonce,
		scope                     = scope,
		require_user_presence     = true,
		require_user_verification = require_uv,
	}
	ver_ref := hardware_keys.hardware_key_assertion_verify(
		&challenge,
		&assertion,
		expected_public_key,
		effective_last,
		verify_sig,
		user,
	)
	if ver_ref != .None {
		return last_sign_count, ver_ref
	}
	if assertion.sign_count > slot.last_sign_count {
		slot.last_sign_count = assertion.sign_count
	}
	return assertion.sign_count, .None
}
