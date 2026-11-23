// Live console pre-call / wide-grant confirmation policy, CLDR en/fr
// localized prompt labels, and role contract listing integrated into console.
package console

import "modus:contract/console_prompt"
import "modus:contract/locale_cldr"
import "modus:contract/blake3"
import "modus:system"
import "modus:contract/role_contract"
import "modus:contract/tree_hash"

console_active_locale: locale_cldr.Locale_Id = .En_US

console_action_requires_prompt :: proc "contextless" (act: console_prompt.Act_Kind, wide_grant_active: bool) -> bool {
	return console_prompt.wide_grant_act_policy(act, wide_grant_active) != .Allow_Silent
}

console_localized_label :: proc "contextless" (key: locale_cldr.Message_Key) -> string {
	return locale_cldr.message_text(console_active_locale, key)
}

// locale_command switches or reports the live CLDR locale (en or fr) of the console.
locale_command :: proc "contextless" (arguments: []Value) -> Value {
	tag := arguments[0].text
	switch tag {
	case "", "status":
	case "en", "en-US", "english":
		console_active_locale = .En_US
	case "fr", "fr-FR", "french":
		console_active_locale = .Fr_FR
	case:
		return fail("locale: expected en, fr, or empty text")
	}
	data := locale_cldr.locale_data(console_active_locale)
	return {kind = .Text, text = data.tag}
}

// roles_command returns a typed table of all closed system roles and their
// scope, trust path, and multi-holder rules from role_contract.
roles_command :: proc "contextless" (arguments: []Value) -> Value {
	columns := [2]Column{text_column("role", 32), text_column("multi_holder", 16)}
	table, made := made_table("Role", columns[:])
	if !made {
		return fail("roles: the line has no room for the description")
	}
	for role in role_contract.Role {
		if role == .None {
			continue
		}
		props := role_contract.role_properties(role)
		row := made_row(&table)
		if row == nil {
			break
		}
		made_text(&table, row, 0, props.name)
		made_text(&table, row, 1, props.allows_multiple_holders ? "yes" : "no")
	}
	return made_value(&table, "roles")
}

// delegated_services_command lists the delegated system service roles and their
// module names (plans, recipes, projects, powerbox, disk_processes, principals,
// devices, settings) as a typed table.
delegated_services_command :: proc "contextless" (arguments: []Value) -> Value {
	columns := [2]Column{text_column("role", 24), text_column("module", 24)}
	table, made := made_table("Delegated_Service", columns[:])
	if !made {
		return fail("delegated_services: the line has no room for the description")
	}
	DELEGATED :: [8]role_contract.Role{.Disk_Processes, .Principals, .Devices, .Settings, .Powerbox, .Plans, .Recipes, .Projects}
	for role in DELEGATED {
		props := role_contract.role_properties(role)
		row := made_row(&table)
		if row == nil {
			break
		}
		made_text(&table, row, 0, props.name)
		made_text(&table, row, 1, props.name)
	}
	return made_value(&table, "delegated_services")
}

// tree_hash_command computes the canonical BLAKE3 tree hash of a single-entry
// immutable tree (entry name + content bytes) using modus:contract/tree_hash.
tree_hash_command :: proc "contextless" (arguments: []Value) -> Value {
	name := arguments[0].text
	content := arguments[1].text
	content_hash := blake3.hash(transmute([]u8)content)
	entry, r1 := tree_hash.tree_entry_make(.Object, name, content_hash)
	if r1 != .None {
		return fail("tree_hash: the entry name is empty, too long, or holds a byte it must not have")
	}
	entries := [1]tree_hash.Tree_Entry{entry}
	encoded: [tree_hash.HEADER_SIZE + tree_hash.ENTRY_SIZE_MOST]u8
	written, r2 := tree_hash.tree_encode(entries[:], encoded[:])
	if r2 != .None {
		return fail("tree_hash: cannot encode canonical tree")
	}
	digest, r3 := tree_hash.tree_hash(encoded[:written])
	if r3 != .None {
		return fail("tree_hash: cannot hash canonical tree")
	}
	hex := "0123456789abcdef"
	if len(scratch) - scratch_count < 64 {
		return fail("tree_hash: scratch buffer full")
	}
	dst := scratch[scratch_count : scratch_count + 64]
	for b, i in digest {
		dst[i * 2] = hex[b >> 4]
		dst[i * 2 + 1] = hex[b & 0x0F]
	}
	scratch_count += 64
	return {kind = .Text, text = string(dst)}
}

// compile_c_command compiles C source text inside modus in one step:
// ensures c_compiler (chibicc) and assemble call hosts are running, compiles
// C -> x86-64 assembly -> validated .modus module, and isolates it under name
// so its exports become immediately callable Lex commands.
compile_c_command :: proc "contextless" (arguments: []Value) -> Value {
	mod_name := arguments[0]
	c_source := arguments[1]
	if len(mod_name.text) == 0 || len(c_source.text) == 0 {
		return fail("compile_c: expected a module name and C source text")
	}
	// Each c_compiler call host compiles one C source cleanly; isolate fresh
	// and unload after compile so compile_c can be invoked repeatedly.
	if command_find("compile") != nil {
		unload_cc := [1]Value{{kind = .Text, text = "c_compiler"}}
		_ = call_run("unload", unload_cc[:])
	}
	{
		iso_cc := [1]Value{{kind = .Text, text = "c_compiler"}}
		r := isolate_module(iso_cc[:])
		if r.kind == .None {
			return {}
		}
	}
	defer {
		unload_cc := [1]Value{{kind = .Text, text = "c_compiler"}}
		_ = call_run("unload", unload_cc[:])
	}
	if command_find("assemble") == nil {
		iso_as := [1]Value{{kind = .Text, text = "assemble"}}
		r := isolate_module(iso_as[:])
		if r.kind == .None {
			return {}
		}
	}
	buf_pages := [1]Value{{kind = .Integer, integer = 16}}
	asm_buf := call_run("buffer", buf_pages[:])
	if asm_buf.kind != .Handle {
		return {}
	}
	defer system.close(system.Handle(asm_buf.integer))
	mod_buf := call_run("buffer", buf_pages[:])
	if mod_buf.kind != .Handle {
		return {}
	}
	defer system.close(system.Handle(mod_buf.integer))

	cc_args := [2]Value{c_source, asm_buf}
	asm_len := call_run("compile", cc_args[:])
	if asm_len.kind != .Integer || asm_len.integer <= 0 {
		return {}
	}
	slice_args := [3]Value{asm_buf, {kind = .Integer, integer = 0}, asm_len}
	asm_bytes := call_run("bytes", slice_args[:])
	if asm_bytes.kind != .Bytes {
		return {}
	}
	as_args := [2]Value{asm_bytes, mod_buf}
	mod_len := call_run("assemble", as_args[:])
	if mod_len.kind != .Integer || mod_len.integer <= 0 {
		return {}
	}
	iso_args := [3]Value{mod_name, mod_buf, mod_len}
	return isolate_from_memory(iso_args[:])
}
