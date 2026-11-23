#+build !freestanding
package role_policy

import "core:testing"
import "modus:contract/module"
import "modus:contract/module_file_writer"
import "modus:contract/role_contract"

@(private = "file")
make_hash :: proc(tag: u8) -> role_contract.Contract_Hash {
	h: role_contract.Contract_Hash
	h[0] = tag
	h[31] = tag ~ 0x5A
	return h
}

@(private = "file")
build_display_module :: proc(t: ^testing.T) -> []u8 {
	code := [16]u8{0 = 0xC3}
	segments := [1]module_file_writer.Segment_Part {
		{memory_offset = 0, memory_size = module.PAGE_SIZE, flags = {.Read, .Execute}, data = code[:]},
	}
	display_parts: role_contract.Display_Module_Parts
	role_contract.display_module_parts_write(&display_parts)
	parts := module_file_writer.Module_Parts{segments = segments[:], exports = display_parts.exports[:], records = display_parts.records[:], enums = display_parts.enums[:], parameter_settings = display_parts.set_ranges[:]}
	needed, sr := module_file_writer.file_size_needed(parts)
	testing.expect_value(t, sr.refusal, module_file_writer.Refusal.None)
	buf := make([]u8, int(needed), context.temp_allocator)
	_, wr := module_file_writer.write(parts, buf)
	testing.expect_value(t, wr.refusal, module_file_writer.Refusal.None)
	return buf
}

@(private = "file")
build_simple_role_contract_and_module :: proc(t: ^testing.T, role: role_contract.Role, export_name: string) -> (role_contract.Role_Contract, []u8, role_contract.Contract_Hash) {
	req_exports := make([]role_contract.Required_Export, 1, context.temp_allocator)
	req_exports[0] = {name = export_name, result = .Integer}
	faces := make([]role_contract.Required_Face, 1, context.temp_allocator)
	faces[0] = {kind = .Exports, name = "primary_exports", exports = req_exports}
	contract := role_contract.Role_Contract{role = role, version = 1, faces = faces}
	digest, ok := role_contract.contract_hash(contract)
	testing.expect(t, ok)

	code := [16]u8{0 = 0xC3}
	segments := [1]module_file_writer.Segment_Part {
		{memory_offset = 0, memory_size = module.PAGE_SIZE, flags = {.Read, .Execute}, data = code[:]},
	}
	exports := [1]module_file_writer.Export_Part{{name = export_name, code_offset = 0, result = .Integer}}
	parts := module_file_writer.Module_Parts{segments = segments[:], exports = exports[:]}
	needed, sr := module_file_writer.file_size_needed(parts)
	testing.expect_value(t, sr.refusal, module_file_writer.Refusal.None)
	buf := make([]u8, int(needed), context.temp_allocator)
	_, wr := module_file_writer.write(parts, buf)
	testing.expect_value(t, wr.refusal, module_file_writer.Refusal.None)
	return contract, buf, digest
}

@(test)
origin_and_scope_borders_refuse_invalid_values :: proc(t: ^testing.T) {
	for bad in ([?]u64{0, u64(Holder_Origin.Disk_Module) + 1, 255, max(u64)}) {
		origin, ok := holder_origin_from_word(bad)
		testing.expectf(t, !ok && origin == .None, "origin word %d must be refused", bad)
	}
	for valid in ([?]Holder_Origin{.Boot_Image, .Disk_Module}) {
		origin, ok := holder_origin_from_word(u64(valid))
		testing.expect(t, ok && origin == valid)
	}

	// Machine scope requires identifier 0.
	testing.expect(t, scope_key_valid_for_role(.Display, {.Machine, 0}))
	testing.expect(t, !scope_key_valid_for_role(.Display, {.Machine, 1}))
	testing.expect(t, !scope_key_valid_for_role(.Display, {.Session, 0}))

	// Client and Device scopes refuse identifier 0.
	testing.expect(t, !scope_key_valid_for_role(.Terminal, {.Client, 0}))
	testing.expect(t, scope_key_valid_for_role(.Terminal, {.Client, 1}))
	testing.expect(t, !scope_key_valid_for_role(.Block_Device, {.Device, 0}))
	testing.expect(t, scope_key_valid_for_role(.Block_Device, {.Device, 4}))

	// Session scope allows 0 (principal 0) and non-zero principals.
	testing.expect(t, scope_key_valid_for_role(.Console, {.Session, 0}))
	testing.expect(t, scope_key_valid_for_role(.Console, {.Session, 2}))
	testing.expect(t, !scope_key_valid_for_role(.None, {.Machine, 0}))
}

@(test)
bind_holder_enforces_trusted_path_rescue_and_contract_verification :: proc(t: ^testing.T) {
	registry: Role_Registry
	display_mod := build_display_module(t)
	display_hash := role_contract.display_contract_hash()
	hashes := [1]role_contract.Contract_Hash{display_hash}
	decl := role_contract.Module_Role_Declaration{
		contract_hashes = hashes[:],
		ring_faces      = role_contract.display_ring_faces(),
	}

	base := Bind_Request {
		role                = .Display,
		scope               = {.Machine, 0},
		module_hash         = make_hash(0x11),
		origin              = .Disk_Module,
		chosen_by_principal = role_contract.MACHINE_PRINCIPAL,
		process_slot        = 1,
		module_bytes        = display_mod,
		declaration         = decl,
		contract            = role_contract.display_contract(),
	}

	// Refusals leave the registry completely empty.
	bad_role := base
	bad_role.role = role_contract.Role(99)
	testing.expect_value(t, bind_holder(&registry, bad_role).refusal, Bind_Refusal.Unknown_Role)

	bad_origin := base
	bad_origin.origin = .None
	testing.expect_value(t, bind_holder(&registry, bad_origin).refusal, Bind_Refusal.Invalid_Origin)

	zero_slot := base
	zero_slot.process_slot = 0
	testing.expect_value(t, bind_holder(&registry, zero_slot).refusal, Bind_Refusal.Zero_Process_Slot)

	zero_hash := base
	zero_hash.module_hash = {}
	testing.expect_value(t, bind_holder(&registry, zero_hash).refusal, Bind_Refusal.Zero_Module_Hash)

	bad_scope := base
	bad_scope.scope = {.Machine, 1}
	testing.expect_value(t, bind_holder(&registry, bad_scope).refusal, Bind_Refusal.Scope_Mismatch)

	mismatch_role := base
	mismatch_role.role = .Input
	testing.expect_value(t, bind_holder(&registry, mismatch_role).refusal, Bind_Refusal.Role_Contract_Mismatch)

	// Non-principal-0 refused for Display disk holder.
	for bad_principal in ([?]u64{1, 2, max(u64)}) {
		non_zero := base
		non_zero.chosen_by_principal = bad_principal
		testing.expect_value(t, bind_holder(&registry, non_zero).refusal, Bind_Refusal.Trusted_Path_Requires_Principal_Zero)
	}

	// Rescue mode refuses disk holder even when chosen by principal 0.
	registry.rescue_mode = true
	testing.expect_value(t, bind_holder(&registry, base).refusal, Bind_Refusal.Rescue_Refuses_Disk_Holder)
	registry.rescue_mode = false

	// Failed contract check (tampered hash) refuses and does not bind.
	tampered := display_hash
	tampered[0] ~= 0xFF
	tampered_hashes := [1]role_contract.Contract_Hash{tampered}
	bad_contract_req := base
	bad_contract_req.declaration.contract_hashes = tampered_hashes[:]
	bad_res := bind_holder(&registry, bad_contract_req)
	testing.expect_value(t, bad_res.refusal, Bind_Refusal.Contract_Not_Filled)
	testing.expect_value(t, bad_res.contract_check.refusal, role_contract.Contract_Check_Refusal.Hash_Mismatch)

	// Confirm nothing was bound after all refusals.
	_, found := holder_find(&registry, .Display, {.Machine, 0})
	testing.expect(t, !found)

	// Valid Display disk holder chosen by principal 0 succeeds.
	ok_res := bind_holder(&registry, base)
	testing.expect_value(t, ok_res.refusal, Bind_Refusal.None)
	holder, holder_found := holder_find(&registry, .Display, {.Machine, 0})
	testing.expect(t, holder_found)
	testing.expect_value(t, holder.process_slot, u32(1))
	testing.expect_value(t, holder.contract_hash, display_hash)

	// Second Display holder in Machine scope is refused.
	second := base
	second.process_slot = 2
	second.module_hash = make_hash(0x22)
	testing.expect_value(t, bind_holder(&registry, second).refusal, Bind_Refusal.Role_Already_Held)

	// Unbinding slot 1 frees the role for slot 2.
	testing.expect_value(t, unbind_process(&registry, 1), 1)
	testing.expect_value(t, bind_holder(&registry, second).refusal, Bind_Refusal.None)
}

@(test)
scoped_single_holder_and_assistive_multi_holder_rules :: proc(t: ^testing.T) {
	registry: Role_Registry

	// Session-scoped Console: distinct sessions can each hold one Console,
	// same session refuses a second holder.
	console_contract, console_mod, console_hash := build_simple_role_contract_and_module(t, .Console, "run_line")
	console_hashes := [1]role_contract.Contract_Hash{console_hash}
	console_decl := role_contract.Module_Role_Declaration{contract_hashes = console_hashes[:]}

	session0 := Bind_Request {
		role                = .Console,
		scope               = {.Session, 0},
		module_hash         = make_hash(0x31),
		origin              = .Boot_Image,
		chosen_by_principal = 0,
		process_slot        = 10,
		module_bytes        = console_mod,
		declaration         = console_decl,
		contract            = console_contract,
	}
	session1 := session0
	session1.scope = {.Session, 1}
	session1.process_slot = 11

	// Named principal cannot choose a Disk_Module for Console (trusted path).
	disk_console := session1
	disk_console.origin = .Disk_Module
	disk_console.chosen_by_principal = 1
	testing.expect_value(t, bind_holder(&registry, disk_console).refusal, Bind_Refusal.Trusted_Path_Requires_Principal_Zero)

	testing.expect_value(t, bind_holder(&registry, session0).refusal, Bind_Refusal.None)
	testing.expect_value(t, bind_holder(&registry, session1).refusal, Bind_Refusal.None)

	dup_session0 := session0
	dup_session0.process_slot = 12
	testing.expect_value(t, bind_holder(&registry, dup_session0).refusal, Bind_Refusal.Role_Already_Held)

	// Assistive allows up to ASSISTIVE_HOLDER_LIMIT distinct holders in Machine scope.
	assist_contract, assist_mod, assist_hash := build_simple_role_contract_and_module(t, .Assistive, "read_tree")
	assist_hashes := [1]role_contract.Contract_Hash{assist_hash}
	assist_decl := role_contract.Module_Role_Declaration{contract_hashes = assist_hashes[:]}

	for i in u32(1) ..= u32(ASSISTIVE_HOLDER_LIMIT) {
		req := Bind_Request {
			role                = .Assistive,
			scope               = {.Machine, 0},
			module_hash         = make_hash(u8(0x40 + i)),
			origin              = .Disk_Module,
			chosen_by_principal = role_contract.MACHINE_PRINCIPAL,
			process_slot        = 20 + i,
			module_bytes        = assist_mod,
			declaration         = assist_decl,
			contract            = assist_contract,
		}
		testing.expect_value(t, bind_holder(&registry, req).refusal, Bind_Refusal.None)
	}

	// Duplicate process slot is refused.
	dup_assist := Bind_Request {
		role                = .Assistive,
		scope               = {.Machine, 0},
		module_hash         = make_hash(0x50),
		origin              = .Boot_Image,
		chosen_by_principal = 0,
		process_slot        = 21,
		module_bytes        = assist_mod,
		declaration         = assist_decl,
		contract            = assist_contract,
	}
	testing.expect_value(t, bind_holder(&registry, dup_assist).refusal, Bind_Refusal.Duplicate_Holder)

	// One past ASSISTIVE_HOLDER_LIMIT is refused.
	past_limit := dup_assist
	past_limit.process_slot = 40
	testing.expect_value(t, bind_holder(&registry, past_limit).refusal, Bind_Refusal.Assistive_Limit_Reached)

	listed: [ASSISTIVE_HOLDER_LIMIT]Role_Holder
	testing.expect_value(t, holders_for_scope(&registry, .Assistive, {.Machine, 0}, listed[:]), ASSISTIVE_HOLDER_LIMIT)
}

@(test)
local_service_resolution_is_caller_scoped_and_never_global :: proc(t: ^testing.T) {
	registry: Role_Registry
	hash_a := make_hash(0xA1)
	hash_b := make_hash(0xB2)

	// Edge refusals on bind.
	testing.expect_value(t, local_service_bind(&registry, 0, "manual", hash_a), Local_Service_Refusal.Zero_Caller_Slot)
	testing.expect_value(t, local_service_bind(&registry, 1, "", hash_a), Local_Service_Refusal.Invalid_Local_Name)
	testing.expect_value(t, local_service_bind(&registry, 1, "bad name", hash_a), Local_Service_Refusal.Invalid_Local_Name)
	testing.expect_value(t, local_service_bind(&registry, 1, "manual", {}), Local_Service_Refusal.Zero_Module_Hash)

	// Bind "manual" to different hashes for caller 1 and caller 2.
	testing.expect_value(t, local_service_bind(&registry, 1, "manual", hash_a), Local_Service_Refusal.None)
	testing.expect_value(t, local_service_bind(&registry, 1, "manual", hash_b), Local_Service_Refusal.Duplicate_Binding)
	testing.expect_value(t, local_service_bind(&registry, 2, "manual", hash_b), Local_Service_Refusal.None)

	// Undeclared dependency gets No_Grant even when bound (no global discovery).
	callable_empty := [1]string{""}
	_, refusal := local_service_resolve(&registry, 1, "manual", callable_empty[:])
	testing.expect_value(t, refusal, Local_Service_Refusal.No_Grant)

	// Caller 3 declares "manual", but plan bound no hash for caller 3: must NOT
	// fall back to caller 1 or caller 2's binding!
	callable_manual := [1]string{"manual"}
	_, refusal = local_service_resolve(&registry, 3, "manual", callable_manual[:])
	testing.expect_value(t, refusal, Local_Service_Refusal.Unbound_Local_Name)

	// Caller 1 and caller 2 each resolve their own plan-bound hash.
	resolved_a, res_a := local_service_resolve(&registry, 1, "manual", callable_manual[:])
	testing.expect_value(t, res_a, Local_Service_Refusal.None)
	testing.expect_value(t, resolved_a, hash_a)

	resolved_b, res_b := local_service_resolve(&registry, 2, "manual", callable_manual[:])
	testing.expect_value(t, res_b, Local_Service_Refusal.None)
	testing.expect_value(t, resolved_b, hash_b)

	// Stopping caller 1 unbinds caller 1's local bindings without affecting caller 2.
	unbind_process(&registry, 1)
	_, refusal = local_service_resolve(&registry, 1, "manual", callable_manual[:])
	testing.expect_value(t, refusal, Local_Service_Refusal.Unbound_Local_Name)
	still_b, res_still_b := local_service_resolve(&registry, 2, "manual", callable_manual[:])
	testing.expect_value(t, res_still_b, Local_Service_Refusal.None)
	testing.expect_value(t, still_b, hash_b)
}


// The table of the root service with the default of the boot image: the
// display is held by the module compositor.
@(private = "file")
image_holder_names :: proc() -> (names: Holder_Names) {
	names.defaults[.Display] = "compositor"
	names.defaults[.Input] = "input"
	names.defaults[.Storage] = "storage"
	names.defaults[.Console] = "console"
	return names
}

// A second holder of the role Display, panel_display, which is not the
// module compositor: the root service starts it, routes "display" to it,
// and trusts it as the holder, through the table only. The refusals come
// first: the empty name, None, a role with no holder, a text that is no
// role name (the module of the image, a role name in other letters), and
// the old holder once the role moved. The contract check binds the second
// holder last, with the same descriptions as any holder of the role.
@(test)
a_second_display_holder_takes_the_routing_of_the_role :: proc(t: ^testing.T) {
	names := image_holder_names()
	_, empty_ok := target_resolve(&names, "")
	testing.expect(t, !empty_ok, "the empty name resolves")
	testing.expect_value(t, holder_name(&names, .None), "")
	testing.expect(t, !is_holder(&names, "", .Assistive), "the empty name holds a role with no holder")
	_, assistive_ok := target_resolve(&names, "assistive")
	testing.expect(t, !assistive_ok, "a role with no holder falls through to a module of its name")
	testing.expect_value(t, role_of_module(&names, ""), role_contract.Role.None)
	for text in ([?]string{"compositor", "Display", "display ", "displays"}) {
		testing.expectf(t, role_of_name(text) == .None, "%q names a role", text)
	}

	// The image: "display" reaches compositor.
	resolved, resolved_ok := target_resolve(&names, "display")
	testing.expect(t, resolved_ok)
	testing.expect_value(t, resolved, "compositor")

	// The plan gives the role to panel_display: each answer follows.
	names.overrides[.Display] = "panel_display"
	resolved, resolved_ok = target_resolve(&names, "display")
	testing.expect(t, resolved_ok)
	testing.expect_value(t, resolved, "panel_display")
	testing.expect_value(t, holder_name(&names, .Display), "panel_display")
	testing.expect(t, is_holder(&names, "panel_display", .Display))
	testing.expect(t, !is_holder(&names, "compositor", .Display), "the module of the image still holds the role")
	testing.expect_value(t, role_of_module(&names, "panel_display"), role_contract.Role.Display)
	testing.expect_value(t, role_of_module(&names, "compositor"), role_contract.Role.None)
	// The name of the old module is a plain name: it reaches no role.
	plain, plain_ok := target_resolve(&names, "compositor")
	testing.expect(t, plain_ok)
	testing.expect_value(t, plain, "compositor")
	// The other roles keep their holders.
	testing.expect_value(t, holder_name(&names, .Input), "input")

	// An image whose default is panel_display gives the same answers.
	image_of_panel: Holder_Names
	image_of_panel.defaults[.Display] = "panel_display"
	resolved, resolved_ok = target_resolve(&image_of_panel, "display")
	testing.expect(t, resolved_ok)
	testing.expect_value(t, resolved, "panel_display")
	testing.expect_value(t, role_of_module(&image_of_panel, "panel_display"), role_contract.Role.Display)

	// The contract check: panel_display fills the display contract with
	// the same descriptions, and the registry binds it.
	registry: Role_Registry
	display_hash := role_contract.display_contract_hash()
	hashes := [1]role_contract.Contract_Hash{display_hash}
	request := Bind_Request {
		role                = .Display,
		scope               = {.Machine, 0},
		module_hash         = make_hash(0x33),
		origin              = .Boot_Image,
		chosen_by_principal = role_contract.MACHINE_PRINCIPAL,
		process_slot        = 3,
		module_bytes        = build_display_module(t),
		declaration         = {contract_hashes = hashes[:], ring_faces = role_contract.display_ring_faces()},
		contract            = role_contract.display_contract(),
	}
	testing.expect_value(t, bind_holder(&registry, request).refusal, Bind_Refusal.None)
	holder, found := holder_find(&registry, .Display, {.Machine, 0})
	testing.expect(t, found)
	testing.expect_value(t, holder.process_slot, u32(3))
	testing.expect_value(t, holder.contract_hash, display_hash)
}
