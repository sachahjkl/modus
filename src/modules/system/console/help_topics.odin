package console

import "modus:console_language"
import "modus:system"

// describe(name) and help(name) give the help on one name: a command gives
// its signature and its help, and a word of Lex or a name of the evaluation
// gives a guide with an example. help() with no argument stays the table of
// the commands. A command and a guide can have one name (where, connect,
// start, ...): the answer then has both. A name that is neither gets the
// names near it. The guides are texts of the console, so a guide names only
// what a line of this console can do (docs/CONSOLE.md, "Help on one name").

// One guide: the name that a principal types, and the text.
Help_Topic :: struct {
	name:  string,
	guide: string,
}

HELP_LET :: "let binds names for one expression: let a = 2, b = a * 3 in a + b gives 8. At the start of a line, let x = [1, 2, 3] with no in keeps the value in the variable x, as x = [1, 2, 3] does."
HELP_WITH :: "r with {width = 10} gives the record r with some fields changed. On its right: a record literal of fields of that record, or a record of the same description."
HELP_WHERE :: "where(table, condition) keeps the rows whose field meets the condition: a field, an operator (=, !=, <, <=, >, >=) and a value. where(processes(), threads > 2), or processes() |> where(name = \"console\"). A field that holds a status takes the name of a member."
HELP_MAP :: "map(list, function) calls the function on each item and gives the list of the results: map([1, 2, 3], (n) => n * n) gives [1, 4, 9]. A variable keeps a list: x = [1, 2, 3], then map(x, (n) => n * 2)."
HELP_FILTER :: "filter(list, function) keeps the items for which the function gives true: filter([1, 2, 3], (n) => n > 1) gives [2, 3]."
HELP_PIPE :: "a |> f(b) is f(a, b): the value on the left is the first argument of the call on the right, or takes the place of _: processes() |> where(threads > 2) |> first(3)."
HELP_CONNECT :: "connect(\"monitor\") connects a running service and adds its exports as monitor.<export>. Binding it (mon = connect(\"monitor\")) registers them as mon.<export> under a handle that help(mon) inspects and unload(mon) removes."
HELP_FUNCTION :: "(x) => x * 2 is a function: its parameters, =>, then its body. let double = (x) => x * 2 in double(3) gives 6. A variable keeps no function: a function reads the values of its line."
HELP_LIST :: "[1, 2, 3] is a list. map and filter take one. A variable keeps a list of 64 items at most: x = [1, 2, 3]. No command takes a list."
HELP_IF :: "if condition then a else b gives a when the condition is true, else b: if 2 > 1 then \"yes\" else \"no\"."
HELP_START :: "start(\"notes\") starts a boot-image module with its declared grants, or starts a pinned disk process from module_files. Pass a wiring table for boot-image streams or a 64-digit hash text for a disk process: start(\"db_browser\", \"<hash>\")."
HELP_START_FROM_DISK :: "start_from_disk(\"name\", \"<hash>\") starts a module stored in module_files only if its bytes match the 64-digit BLAKE3 hash. Pass \"\" as the hash to use the hash pinned in the principal's disk grant table."
HELP_ISOLATE :: "s = isolate(\"sample\") loads a boot-image module in a separate zero-grant call host and registers its exports and record constructors as s.<name>. Use help(s) to list its commands and unload(s) or reassigning s to stop it."
HELP_LOAD :: "m = load(\"math\") maps a boot-image module into the console process for direct calls and registers its exports and record constructors as m.<name>. Use s = isolate(\"sample\") for any module that does not need the console's handles."
HELP_PROJECTS_INSTALL :: "projects.install(\"db_browser\") ingests the project store, builds or fetches its project.lex output, verifies and delivers the module into module_files, and returns its provenance and module hash. Pass an optional build mode (prefer_cache, build_only, cache_only, or verify) as the second argument."
HELP_ALLOW :: "allow(\"visitor\", \"store\") grants the named disk process access to its private store from its next start. Only store can be granted from the console."
HELP_REVOKE :: "revoke(\"notes\", \"store\") ends one held grant on a running process immediately and returns how many holdings closed. Future calls on closed handles report that the grant was revoked."
HELP_PLANS_DIFFERENCE :: "plans.difference(rows, summary) compares a proposed plan against the principal's active plan without applying any change. It returns the difference table and appends the summary row."
HELP_PLANS_APPLY :: "plans.apply(\"evening\", plan { locks = { settings = { appearance = .dark } } }) validates the plan, opens the trusted display consent dialog, waits for your decision, and returns the committed generation row. Pass an optional third Plan_Expected record when pinning the current plan hash."
HELP_PLANS_ROLLBACK :: "plans.rollback() opens the trusted display consent dialog to restore the previous plan generation, waits for your decision, and returns the generation row. Pass a generation number such as plans.rollback(2) to select a specific generation."

@(rodata)
HELP_TOPICS := [?]Help_Topic {
	{"let", HELP_LET},
	{"in", HELP_LET},
	{"with", HELP_WITH},
	{"where", HELP_WHERE},
	{"map", HELP_MAP},
	{"filter", HELP_FILTER},
	{"|>", HELP_PIPE},
	{"_", HELP_PIPE},
	{"connect", HELP_CONNECT},
	{"=>", HELP_FUNCTION},
	{"function", HELP_FUNCTION},
	{"[", HELP_LIST},
	{"list", HELP_LIST},
	{"if", HELP_IF},
	{"start", HELP_START},
	{"start_from_disk", HELP_START_FROM_DISK},
	{"isolate", HELP_ISOLATE},
	{"load", HELP_LOAD},
	{"projects.install", HELP_PROJECTS_INSTALL},
	{"allow", HELP_ALLOW},
	{"revoke", HELP_REVOKE},
	{"plans.difference", HELP_PLANS_DIFFERENCE},
	{"plans.apply", HELP_PLANS_APPLY},
	{"plans.rollback", HELP_PLANS_ROLLBACK},
}

// help_topic gives the text of describe(name) and help(name), or fails the
// line with the names near the name.
help_topic :: proc "contextless" (topic: string) -> Value {
	found := command_known(topic)
	guide := ""
	for &item in HELP_TOPICS {
		if item.name == topic {
			guide = item.guide
		}
	}
	if found == nil && guide == "" {
		nearest := console_language.nearest_names_start(topic)
		for &item in HELP_TOPICS {
			console_language.nearest_name_offer(&nearest, item.name)
		}
		for &command in commands[:command_count] {
			console_language.nearest_name_offer(&nearest, command.name)
		}
		if nearest.count == 0 {
			return fail("describe: no command and no word of Lex has the name ", topic, "; help() gives the commands")
		}
		return fail("describe: no command and no word of Lex has the name ", topic, nearest_names_text(&nearest))
	}
	writer := system.Writer {
		buffer = scratch[scratch_count:],
	}
	if found != nil {
		_, _ = signature_write(&writer, found, -1, true)
		system.write_part(&writer, "\n")
		system.write_part(&writer, found.about)
	}
	if guide != "" {
		system.write_part(&writer, found != nil ? "\n" : "")
		system.write_part(&writer, guide)
	}
	text := system.written(&writer)
	scratch_count += len(text)
	return {kind = .Text, text = text}
}
