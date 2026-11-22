// Canonical role contracts for Plans, Recipes, and Projects
// (src/md/features/roles_and_contracts.md) and (src/md/features/recipes.md)
// and (src/md/features/declarations.md).
//
// Each role contract hashes to a deterministic 32-byte BLAKE3 identity so
// console and root reach any conforming holder by role rather than module name.
package role_contract

PLANS_CONTRACT_VERSION :: u32(1)
RECIPES_CONTRACT_VERSION :: u32(1)
PROJECTS_CONTRACT_VERSION :: u32(1)

@(private = "file", rodata)
plans_required_exports := [?]Required_Export{
	{name = "status", parameters = nil, result = .Record, result_record_name = "Plans_Status", has_error_record = true, error_record_name = "Error_Record"},
	{name = "current_generation", parameters = nil, result = .Integer, has_error_record = true, error_record_name = "Error_Record"},
	{name = "diff", parameters = nil, result = .Table, result_record_name = "Plan_Diff_Row", has_error_record = true, error_record_name = "Error_Record"},
	{name = "apply", parameters = nil, result = .Integer, has_error_record = true, error_record_name = "Error_Record"},
	{name = "rollback", parameters = nil, result = .Integer, has_error_record = true, error_record_name = "Error_Record"},
}

@(private = "file")
plans_required_faces := [1]Required_Face{
	{kind = .Exports, name = "plans_exports", exports = plans_required_exports[:]},
}

@(private = "file", rodata)
recipes_required_exports := [?]Required_Export{
	{name = "status", parameters = nil, result = .Record, result_record_name = "Recipes_Status", has_error_record = true, error_record_name = "Error_Record"},
	{name = "build", parameters = nil, result = .Record, result_record_name = "Realisation", has_error_record = true, error_record_name = "Error_Record"},
	{name = "verify", parameters = nil, result = .Integer, has_error_record = true, error_record_name = "Error_Record"},
}

@(private = "file")
recipes_required_faces := [1]Required_Face{
	{kind = .Exports, name = "recipes_exports", exports = recipes_required_exports[:]},
}

@(private = "file", rodata)
projects_required_exports := [?]Required_Export{
	{name = "status", parameters = nil, result = .Record, result_record_name = "Projects_Status", has_error_record = true, error_record_name = "Error_Record"},
	{name = "update", parameters = nil, result = .Table, result_record_name = "Pin_Change", has_error_record = true, error_record_name = "Error_Record"},
	{name = "enter", parameters = nil, result = .Integer, has_error_record = true, error_record_name = "Error_Record"},
}

@(private = "file")
projects_required_faces := [1]Required_Face{
	{kind = .Exports, name = "projects_exports", exports = projects_required_exports[:]},
}

plans_contract :: proc "contextless" () -> Role_Contract {
	return {role = .Plans, version = PLANS_CONTRACT_VERSION, faces = plans_required_faces[:]}
}

recipes_contract :: proc "contextless" () -> Role_Contract {
	return {role = .Recipes, version = RECIPES_CONTRACT_VERSION, faces = recipes_required_faces[:]}
}

projects_contract :: proc "contextless" () -> Role_Contract {
	return {role = .Projects, version = PROJECTS_CONTRACT_VERSION, faces = projects_required_faces[:]}
}
