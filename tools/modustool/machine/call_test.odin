package machine

import "modus:contract/isolated"
import module "modus:contract/module"
import "core:fmt"
import "core:strings"
import "core:testing"

// nine_parameter_module gives a module file with one export, combine: nine
// parameters, Integers and Texts, a Text result and an error record. It has
// the tables that a call from the host reads, and no code.
@(private = "file")
nine_parameter_module :: proc() -> []u8 {
	Directory :: [module.TABLE_COUNT]module.Table_Entry
	directory: Directory
	export_name := "combine"
	string_bytes := make([dynamic]u8, context.temp_allocator)
	append(&string_bytes, 0)
	function := module.Function {
		name_offset     = u32(len(string_bytes)),
		name_count      = u32(len(export_name)),
		parameter_count = 9,
		result          = u8(module.Type.Text),
		error_record    = 1,
	}
	append(&string_bytes, export_name)
	types := [9]module.Type{.Integer, .Text, .Integer, .Integer, .Integer, .Integer, .Integer, .Integer, .Text}
	for type, index in types {
		function.parameters[index] = u8(type)
		parameter_name := fmt.tprintf("value_%d", index + 1)
		function.parameter_names[index] = u32(len(string_bytes))
		function.parameter_name_counts[index] = u8(len(parameter_name))
		append(&string_bytes, parameter_name)
	}
	exports := [2]module.Export{1 = {function = 1}}
	functions := [2]module.Function{1 = function}
	file := make([dynamic]u8, size_of(module.Header) + size_of(Directory), context.temp_allocator)
	directory[module.Table_Kind.Exports] = {offset = u64(len(file)), count = 2, record_size = size_of(module.Export)}
	append(&file, ..([^]u8)(&exports)[:size_of(exports)])
	directory[module.Table_Kind.Functions] = {offset = u64(len(file)), count = 2, record_size = size_of(module.Function)}
	append(&file, ..([^]u8)(&functions)[:size_of(functions)])
	directory[module.Table_Kind.Strings] = {offset = u64(len(file)), count = u32(len(string_bytes)), record_size = 1}
	append(&file, ..string_bytes[:])
	(^module.Header)(&file[0])^ = {magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = module.TABLE_COUNT}
	(^Directory)(&file[size_of(module.Header)])^ = directory
	return file[:]
}

// A call from the host to an export with nine parameters, past the six
// registers: the text of the call gives the nine values, and the argument
// record that the tool writes gives each one back in its place, with the
// buffer of the result as argument 10 and the error record as argument 11.
@(test)
a_call_from_the_host_takes_nine_arguments :: proc(t: ^testing.T) {
	client: Call_Client
	call_client_open(&client, "")
	defer call_client_close(&client)
	built := nine_parameter_module()
	file := make([]u8, len(built))
	copy(file, built)
	// The client reads each module one time: this one is read already.
	append(&client.modules, Read_Module{service = strings.clone("nine"), file = file})
	prepared, problem := call_prepare(&client, `nine.combine(1, "two", 3, 4, 5, 6, 7, 8, "nine")`)
	if !testing.expect_value(t, problem, "") {
		return
	}
	testing.expect_value(t, prepared.function.parameter_count, 9)
	decoded: isolated.Call
	if !testing.expect(t, isolated.decode(prepared.file, prepared.function, 0, u64(prepared.request.record_size), client.region, &decoded), "the receiver reads the argument record") {
		return
	}
	for value, index in ([8]u64{0 = 1, 2 = 3, 3 = 4, 4 = 5, 5 = 6, 6 = 7, 7 = 8}) {
		if index != 1 {
			testing.expect_value(t, decoded.arguments[index], value)
		}
	}
	testing.expect_value(t, (^string)(uintptr(decoded.arguments[1]))^, "two")
	testing.expect_value(t, (^string)(uintptr(decoded.arguments[8]))^, "nine")
	testing.expect(t, decoded.arguments[9] == u64(uintptr(&decoded.slices[9])), "argument 10 is the buffer of the Text result")
	if testing.expect_value(t, decoded.error.count, isolated.ERROR_RECORD_SIZE) {
		testing.expect_value(t, decoded.arguments[10], u64(uintptr(&client.region[decoded.error.start])))
	}
	// One value too few: refused before a call.
	_, problem = call_prepare(&client, `nine.combine(1, "two", 3, 4, 5, 6, 7, 8)`)
	testing.expect_value(t, problem, "nine.combine has 9 parameters; the call gives 8, with no value_9")
}

// The text of a call: the service, the export, and the typed arguments.
@(test)
call_parse_reads :: proc(t: ^testing.T) {
	service, export, arguments, problem := call_parse(`  storage.write("a \"note\"\n", -12, 0x10) `)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, service, "storage")
	testing.expect_value(t, export, "write")
	testing.expect_value(t, len(arguments), 3)
	testing.expect(t, arguments[0].is_text && arguments[0].text == "a \"note\"\n")
	testing.expect(t, !arguments[1].is_text && arguments[1].integer == -12)
	testing.expect(t, !arguments[2].is_text && arguments[2].integer == 16)
	service, export, arguments, problem = call_parse("monitor.processes()")
	testing.expect(t, problem == "" && service == "monitor" && export == "processes" && len(arguments) == 0)
	// A table: rows of field values.
	service, export, arguments, problem = call_parse(`sample.sum_values([(1, "a", 10), (2, "b", -20)], 7)`)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(arguments), 2)
	if len(arguments) == 2 {
		testing.expect(t, arguments[0].is_table && len(arguments[0].rows) == 2)
		testing.expect(t, len(arguments[0].rows[1]) == 3 && arguments[0].rows[1][1].text == "b" && arguments[0].rows[1][2].integer == -20)
		testing.expect(t, arguments[1].integer == 7)
	}
	_, _, arguments, problem = call_parse("sample.sum_values([])")
	testing.expect(t, problem == "" && len(arguments) == 1 && arguments[0].is_table && len(arguments[0].rows) == 0, "an empty table")
}

// A named argument and a member of an enum: a name given twice, an argument
// with no name after a named one, a dot with no name, a name with no value,
// and a member in a row of a table are refused; then a member by its place
// and by its name are read.
@(test)
call_parse_reads_names_and_members :: proc(t: ^testing.T) {
	for text in ([]string{"settings.set(font = .a, font = .b)", "settings.set(font = .a, .b)", "settings.set(font = .)", "settings.set(font = )", "settings.set(.)", "s.f([(.a, 1)])"}) {
		_, _, arguments, problem := call_parse(text)
		refused := problem != ""
		// A member in a row is read, and the table refuses it before a call.
		if text == "s.f([(.a, 1)])" {
			refused = len(arguments) == 1 && arguments[0].is_table && arguments[0].rows[0][0].is_member
		}
		testing.expectf(t, refused, "%s is refused", text)
	}
	_, _, arguments, problem := call_parse("settings.set(.spleen, keyboard_layout = .french, scale = 11)")
	testing.expect_value(t, problem, "")
	if testing.expect_value(t, len(arguments), 3) {
		testing.expect(t, arguments[0].is_member && arguments[0].text == "spleen" && arguments[0].name == "")
		testing.expect(t, arguments[1].is_member && arguments[1].text == "french" && arguments[1].name == "keyboard_layout")
		testing.expect(t, !arguments[2].is_member && arguments[2].integer == 11 && arguments[2].name == "scale")
	}
}

// Each malformed text gives a sentence, and no call.
@(test)
call_parse_refuses :: proc(t: ^testing.T) {
	for text in ([]string{"processes()", "monitor.processes", ".x()", "monitor.count(\"open", "monitor.count(1 2)", "monitor.count(1,)", "monitor.count(abc)", "s.f([(1, 2)", "s.f([(1, [(2)])])", "s.f([(1 2)])", "s.f([1, 2])"}) {
		_, _, _, problem := call_parse(text)
		testing.expectf(t, problem != "", "%s is refused", text)
	}
}
