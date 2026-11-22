// Live console pre-call / wide-grant confirmation policy, CLDR en/fr
// localized prompt labels, and role contract listing integrated into console.
package console

import "modus:contract/console_prompt"
import "modus:contract/locale_cldr"
import "modus:contract/role_contract"

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
