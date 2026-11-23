package role_policy

import "modus:contract/role_contract"

// The module name of the holder of each role: the default of the boot image,
// and the override that a plan of principal 0 installs. The root service
// starts, routes and trusts a holder through this table only, so any module
// that fills the contract of a role takes its place by one row
// (src/md/features/roles_and_contracts.md, "A process gets a connection, never
// finds one").
Holder_Names :: struct {
	defaults:  [role_contract.Role]string,
	overrides: [role_contract.Role]string, // "": the default of the image holds the role.
}

// holder_name gives the module name of the active holder of a role, or "" for
// None and for a role with no holder.
holder_name :: proc "contextless" (names: ^Holder_Names, role: role_contract.Role) -> string {
	if role == .None {
		return ""
	}
	if override := names.overrides[role]; override != "" {
		return override
	}
	return names.defaults[role]
}

// is_holder says if a module name is the active holder of a role. A role with
// no holder has no module that holds it, also not the empty name.
is_holder :: proc "contextless" (names: ^Holder_Names, module_name: string, role: role_contract.Role) -> bool {
	holder := holder_name(names, role)
	return holder != "" && module_name == holder
}

// role_of_name gives the role whose canonical name is a text, or None. The
// text is a name of a role only when it equals role_properties(role).name.
role_of_name :: proc "contextless" (name: string) -> role_contract.Role {
	if name == "" {
		return .None
	}
	for role in role_contract.Role {
		if role != .None && role_contract.role_properties(role).name == name {
			return role
		}
	}
	return .None
}

// role_of_module gives the role that a module name holds now, or None.
role_of_module :: proc "contextless" (names: ^Holder_Names, module_name: string) -> role_contract.Role {
	if module_name == "" {
		return .None
	}
	for role in role_contract.Role {
		if role != .None && holder_name(names, role) == module_name {
			return role
		}
	}
	return .None
}

// target_resolve gives the module that a name of a Connect or of a start row
// reaches: the active holder for the name of a role, and the name itself for
// any other name. A role with no holder is refused (ok false), so a caller
// never falls through to a module of the same name.
target_resolve :: proc "contextless" (names: ^Holder_Names, name: string) -> (module_name: string, ok: bool) {
	if name == "" {
		return "", false
	}
	role := role_of_name(name)
	if role == .None {
		return name, true
	}
	holder := holder_name(names, role)
	return holder, holder != ""
}

// store_name_of_module gives the name of the private store of a module: the
// name of the role that it holds now, else its own name, and none ("") for a
// module that has the name of a role that it does not hold. The store of a role
// belongs to the role (src/md/features/module_settings.md, "The role
// store"): a holder that the plan put in place of another, and the same
// module after a restart, get the store of the one before, so the choices of
// the principal for the role stay.
store_name_of_module :: proc "contextless" (names: ^Holder_Names, module_name: string) -> string {
	if role := role_of_module(names, module_name); role != .None {
		return role_contract.role_properties(role).name
	}
	// A module that holds no role and has the name of a role, as the
	// default holder that a plan replaced, would reach the store of the
	// role, which only its holder keeps: it gets no store.
	if role_of_name(module_name) != .None {
		return ""
	}
	return module_name
}

// grant_row_name_of_module gives the name of the row of the start grant sets
// whose grants a module gets: the row of the default holder of the role that
// it holds now, else its own row. The grants of a role follow its holder: a
// holder that the plan names does the work of the role with the grants that
// the role needs, never with the grants of its own name.
grant_row_name_of_module :: proc "contextless" (names: ^Holder_Names, module_name: string) -> string {
	if role := role_of_module(names, module_name); role != .None && names.defaults[role] != "" {
		return names.defaults[role]
	}
	return module_name
}
