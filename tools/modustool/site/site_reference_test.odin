package site

import "core:reflect"
import "core:slice"
import "core:strings"
import "core:testing"
import "modus:contract/errors"
import "modus:contract/fixed_addresses"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/start_grant"
import "modustool:foundation"
import "modustool:build"

@(private = "file")
read_text :: proc(t: ^testing.T, path: string) -> string {
	text, ok := foundation.read_text_file_quiet(path)
	testing.expectf(t, ok, "cannot read %s", path)
	return text
}

// The members that the reader finds are those that the compiler knows, with
// the same names and values, in the same order.
@(private = "file")
expect_members_of :: proc(t: ^testing.T, members: []foundation.Enumeration_Member, type: typeid) {
	names := reflect.enum_field_names(type)
	values := reflect.enum_field_values(type)
	testing.expectf(t, len(members) == len(names), "the reader found %d members of %v, the compiler knows %d", len(members), type, len(names))
	for member, index in members {
		if index >= len(names) {
			break
		}
		testing.expectf(t, member.name == names[index] && i64(member.number) == i64(values[index]), "member %d of %v: the reader has %s = %d, the compiler %s = %d", index, type, member.name, member.number, names[index], i64(values[index]))
	}
}

@(test)
site_operations_of_the_repository :: proc(t: ^testing.T) {
	text := read_text(t, SITE_OPERATION_FILE)
	members, problem := foundation.enumeration_read(text, SITE_OPERATION_FILE, "Operation")
	testing.expect_value(t, problem, "")
	expect_members_of(t, members, op.Operation)
	for member in members {
		if member.name != "Memory_Map" {
			continue
		}
		operation := foundation.operation_comment_split(member)
		testing.expect(t, strings.has_prefix(operation.parameters, "memory, process, address"))
		testing.expect_value(t, operation.result, "address")
	}
	statuses, status_problem := foundation.enumeration_read(text, SITE_OPERATION_FILE, "Status")
	testing.expect_value(t, status_problem, "")
	expect_members_of(t, statuses, op.Status)
}

@(test)
site_errors_of_the_repository :: proc(t: ^testing.T) {
	text := read_text(t, SITE_ERRORS_FILE)
	kinds, kinds_problem := foundation.enumeration_read(text, SITE_ERRORS_FILE, "Kind")
	testing.expect_value(t, kinds_problem, "")
	expect_members_of(t, kinds, errors.Kind)
	units, units_problem := foundation.enumeration_read(text, SITE_ERRORS_FILE, "Unit")
	testing.expect_value(t, units_problem, "")
	expect_members_of(t, units, errors.Unit)
	names, names_problem := foundation.names_table_read(text, SITE_ERRORS_FILE, "UNIT_NAMES")
	testing.expect_value(t, names_problem, "")
	testing.expect_value(t, len(names), len(units))
	testing.expect_value(t, names["Pages"], "pages")
}

@(test)
site_fixed_ranges_of_the_repository :: proc(t: ^testing.T) {
	text := read_text(t, SITE_FIXED_ADDRESSES_FILE)
	ranges, problem := foundation.enumeration_read(text, SITE_FIXED_ADDRESSES_FILE, "Fixed_Range")
	testing.expect_value(t, problem, "")
	expect_members_of(t, ranges, fixed_addresses.Fixed_Range)
}

@(test)
site_context_of_the_repository :: proc(t: ^testing.T) {
	text := read_text(t, SITE_OPERATION_FILE)
	roles, problem := foundation.constants_read(text, SITE_OPERATION_FILE, "CONTEXT_HANDLES ::", {"CONTEXT_", "ROOT_"})
	testing.expect_value(t, problem, "")
	found_log, found_machine := false, false
	for role in roles {
		if role.name == "CONTEXT_LOG" {
			found_log = role.value == op.CONTEXT_LOG && strings.contains(role.comment, "The log of the kernel")
		}
		if role.name == "ROOT_MACHINE" {
			found_machine = role.value == op.ROOT_MACHINE
		}
		testing.expectf(t, role.name != "CONTEXT_ADDRESS", "CONTEXT_ADDRESS is an address, not a role")
	}
	testing.expect(t, found_log && found_machine, "CONTEXT_LOG or ROOT_MACHINE is absent, or has another value")
}

@(test)
site_grants_of_the_repository :: proc(t: ^testing.T) {
	grants_text := read_text(t, foundation.SYSTEM_GRANTS_FILE)
	recorded, recorded_problem := foundation.enumeration_read(grants_text, foundation.SYSTEM_GRANTS_FILE, "Root_Grant")
	testing.expect_value(t, recorded_problem, "")
	names, names_problem := foundation.names_table_read(grants_text, foundation.SYSTEM_GRANTS_FILE, "root_grant_names")
	testing.expect_value(t, names_problem, "")
	for grant in recorded {
		testing.expectf(t, names[grant.name] != "", "the grant %s has no name in root_grant_names", grant.name)
	}
	roles_text := read_text(t, foundation.ROOT_ROLES_FILE)
	start_grant_text := read_text(t, SITE_START_GRANT_FILE)
	at_start, start_problem := foundation.enumeration_read(start_grant_text, SITE_START_GRANT_FILE, "Grant")
	testing.expect_value(t, start_problem, "")
	testing.expect(t, len(at_start) > 0 && at_start[0].name == "Root_Ring")
	// The number of a start grant is in an error record: the site shows the
	// number that the contract writes, and the name that a sentence writes.
	for grant in at_start {
		name, known := start_grant.grant_name(i64(grant.number))
		testing.expectf(t, known && name == grant.name, "the start grant %s has the number %d, which grant_name names %q", grant.name, grant.number, name)
	}
	testing.expect_value(t, len(at_start), len(start_grant.Grant))
	rows, rows_problem := foundation.role_table_read(roles_text, foundation.ROOT_ROLES_FILE, build.PROCESS_ROLES_TABLE)
	testing.expect_value(t, rows_problem, "")
	console, named := site_role_row_of(rows, "console")
	testing.expect(t, named && len(console.grants) > 1 && console.grants[0] == "Root_Ring", "a set is read as its members, with no period")
	testing.expect_value(t, console.terms, "store_blocks = 3, log_gives = true")
	inspect, inspect_named := site_role_row_of(rows, "inspect")
	testing.expect(t, inspect_named && strings.contains(inspect.comment, "A developer tool"), "the comment lines above a row are its comment")
	testing.expect_value(t, inspect.terms, "")
	// A row with no grant is a row of the table, with no grant.
	plasma, plasma_named := site_role_row_of(rows, "plasma")
	testing.expect(t, plasma_named && len(plasma.grants) == 0)
	_, system_parts, parts_problem := build.process_roles_read(roles_text)
	testing.expect_value(t, parts_problem, "")
	testing.expect_value(t, len(build.process_roles_problems(rows, system_parts, foundation.module_builds[:], foundation.ROOT_ROLES_FILE)), 0)
}

// A set of grants is a list of values: each grant one link to its row in
// the first table of the page of the grants, with no brace, no period and
// no comma.
@(test)
site_grant_set_is_a_list_of_values :: proc(t: ^testing.T) {
	site := test_site()
	b := strings.builder_make(context.temp_allocator)
	site_grant_set_write(&site, &b, site_page_file(SITE_GRANTS_FOLDER), {"Root_Ring", "Debug_Image"}, false)
	html := strings.to_string(b)
	testing.expect_value(t, html, "<ul class=\"value-list\"><li><a href=\"#start-grant-root-ring\"><code class=\"value value-grant\">Root_Ring</code></a></li><li><a href=\"#start-grant-debug-image\"><code class=\"value value-grant\">Debug_Image</code></a></li></ul>")
	from_module := strings.builder_make(context.temp_allocator)
	site_grant_set_write(&site, &from_module, site_module_page("console"), {"Store"}, true)
	testing.expect(t, strings.contains(strings.to_string(from_module), "grants/index.html#start-grant-store\""), strings.to_string(from_module))
	none := strings.builder_make(context.temp_allocator)
	site_grant_set_write(&site, &none, site_page_file(SITE_GRANTS_FOLDER), {}, false)
	testing.expect_value(t, strings.to_string(none), "none")
}

@(test)
site_console_commands_of_the_repository :: proc(t: ^testing.T) {
	all := make([dynamic]foundation.Console_Command_Entry, context.temp_allocator)
	files := SITE_CONSOLE_COMMAND_FILES
	for file in files {
		commands, problem := foundation.console_commands_read(read_text(t, file), file)
		testing.expect_value(t, problem, "")
		append(&all, ..commands)
	}
	signatures := make(map[string]string, context.temp_allocator)
	for command in all {
		testing.expectf(t, command.about != "", "the command %s has no help", command.name)
		signatures[command.name] = foundation.console_signature(command)
	}
	testing.expect_value(t, signatures["help"], "help() -> Table")
	testing.expect_value(t, signatures["repeat"], "repeat(Text, Integer) -> Text")
	testing.expect_value(t, signatures["where"], "where(Table, Condition) -> Table")
	testing.expect_value(t, signatures["facts"], "facts(Table, Fact_Type) -> Table")
	testing.expect_value(t, signatures["columns"], "columns(Table, Field...) -> Table")
	testing.expect_value(t, signatures["start"], "start(Text, [Table])")
	testing.expect_value(t, signatures["wire"], "wire(Stream, Record_Input) -> Table")
	// Each built-in command has its documentation above its line: the help
	// alone is one line, too short for a reader of the site.
	for command in all {
		testing.expectf(t, command.documentation != "", "the command %s has no comment above its line", command.name)
	}
}

@(test)
site_property_names_in_a_text :: proc(t: ^testing.T) {
	testing.expect(t, slice.equal(site_property_numbers("Property 19 is not complete (P17); see property 9.", 21), []int{19, 17, 9}))
	testing.expect_value(t, len(site_property_numbers("properties 3 and 4, P256, HTTP2, property 30", 21)), 0)
	testing.expect_value(t, len(site_property_numbers("the property 12a", 21)), 0)
}

@(test)
site_type_text_as_the_console :: proc(t: ^testing.T) {
	description := build.Module_Description{records = []build.Record_Description{{name = "Rectangle"}}}
	testing.expect_value(t, site_type_text(description, .Handle, transmute(u32)op.Rights{.Read, .Write}, .Read, true), "Handle(Read, Write)")
	testing.expect_value(t, site_type_text(description, .Table, 1, .Change, true), "Table(Rectangle, Change)")
	testing.expect_value(t, site_type_text(description, .Table, 1, .Read, false), "Table(Rectangle)")
	testing.expect_value(t, site_type_text(description, .Record, 1, .Read, false), "Rectangle")
	export := build.Export_Description{name = "write", parameters = []module.Type{.Text, .Text}, names = []string{"name", "data"}, details = []u32{0, 0}, directions = []module.Direction{.Read, .Read}, result = .Integer}
	testing.expect_value(t, site_export_signature(description, export), "write(name: Text, data: Text) -> Integer")
}

// Each module of module_builds has a page, the code spans of the guides find
// their rows, and a name of two tables links nowhere.
@(test)
site_reference_of_the_repository :: proc(t: ^testing.T) {
	site: Site
	testing.expect(t, site_reference_read(&site))
	testing.expect_value(t, len(site.reference.modules), len(foundation.module_builds))
	pages := make(map[string]bool, context.temp_allocator)
	for item in site.reference.modules {
		testing.expectf(t, item.page == site_module_page(item.build.name) && item.page not_in pages, "the module %s has no page of its own", item.build.name)
		pages[item.page] = true
		testing.expectf(t, item.description.about != "", "the module %s has no purpose", item.build.name)
	}
	target, found := site_code_link(&site, "Memory_Map")
	testing.expect(t, found && target == "docs/reference/operations/index.html#operation-memory-map", target)
	_, ambiguous := site_code_link(&site, "Bad_Address")
	testing.expect(t, !ambiguous, "Bad_Address is a status and an error kind: it links nowhere")
	command, command_found := site_code_link(&site, "load(\"math\")")
	testing.expect(t, command_found && command == "docs/reference/console/index.html#command-load", command)
	_, spaced := site_code_link(&site, "Memory_Map and more")
	testing.expect(t, !spaced)
	math_page, math_found := site_code_link(&site, "math")
	testing.expect(t, math_found && math_page == site_module_page("math"), math_page)
	testing.expect_value(t, site_module_page("math"), "docs/reference/modules/math/index.html")
}

@(test)
site_demonstrations_of_the_repository :: proc(t: ^testing.T) {
	rows, removals, problem := site_demonstrations_read(read_text(t, SITE_DEMONSTRATIONS_FILE))
	testing.expect_value(t, problem, "")
	// One row for each property, in order, each with a state and a text.
	testing.expect_value(t, len(rows), 23)
	for row, index in rows {
		testing.expect_value(t, row.number, index + 1)
		testing.expectf(t, row.state != "" && row.shown != "" && row.missing != "", "the row of the property %d has an empty cell", row.number)
	}
	testing.expect(t, len(removals) > 0)
}

@(test)
site_demonstrations_of_a_small_file :: proc(t: ^testing.T) {
	text := "## The table\n\n| # | Property | State | Shows | Picture | Not shown |\n|---|---|---|---|---|---|\n| 1 | Small | Shown | It runs | `rights`, `errors` | — |\n\n## What removes each part\n\n1. Property 1: a check.\n"
	rows, removals, problem := site_demonstrations_read(text)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 {
		testing.expect_value(t, rows[0].state, "Shown")
		testing.expect_value(t, len(rows[0].pictures), 2)
		testing.expect_value(t, rows[0].pictures[1], "errors")
		testing.expect_value(t, rows[0].line, 5)
	}
	testing.expect_value(t, len(removals), 1)
	_, _, short := site_demonstrations_read("## The table\n\n| 1 | Small | Shown |\n")
	testing.expect(t, strings.has_prefix(short, SITE_DEMONSTRATIONS_FILE + ", line 3:"), short)
}
