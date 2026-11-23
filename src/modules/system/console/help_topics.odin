package console

import "modus:console_language"
import "modus:system"

// describe(name) gives the help on one name: a command gives its signature
// and its help, and a word of Lex or a name of the evaluation gives a guide
// with an example. help() stays the table of the commands: one command
// gives the help on one name. A command and a guide can have one name
// (where, connect): the answer then has both. A name that is neither gets
// the names near it. The guides are texts of the console, so
// a guide names only what a line of this console can do
// (docs/CONSOLE.md, "Help on one name").

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
HELP_CONNECT :: "connect(\"monitor\") adds the exports of a service as commands: monitor.processes(). A call of monitor.processes() connects the service at its first use, with the same check."
HELP_FUNCTION :: "(x) => x * 2 is a function: its parameters, =>, then its body. let double = (x) => x * 2 in double(3) gives 6. A variable keeps no function: a function reads the values of its line."
HELP_LIST :: "[1, 2, 3] is a list. map and filter take one. A variable keeps a list of 64 items at most: x = [1, 2, 3]. No command takes a list."
HELP_IF :: "if condition then a else b gives a when the condition is true, else b: if 2 > 1 then \"yes\" else \"no\"."

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
}

// help_topic gives the text of describe(name), or fails the line with the
// names near the name.
help_topic :: proc "contextless" (topic: string) -> Value {
	found := command_find(topic)
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
