package build

import module "modus:contract/module"
import "modus:support/console_condition"
import "core:strings"
import "core:testing"

// The catalog of the tests of the step of a fact: one module, whose fact
// type is probe.Probe, with the record "Probe": the unsigned Integer
// "value" of 8 bytes, the hexadecimal "mark" of 4 bytes and the "number"
// of 4 bytes, or the Text "note" of 4 bytes in place of "number".
@(private = "file")
fact_step_catalog :: proc(last_is_text := false) -> (catalog: Fact_Catalog, hash: [module.HASH_SIZE]u8) {
	for &value, index in hash {
		value = u8(index + 1)
	}
	catalog = Fact_Catalog{allocator = context.temp_allocator}
	template := last_is_text ? "probe: {value} {mark} {note}" : "probe: {value} {mark} {number}"
	_ = fact_catalog_add(&catalog, hash, "", fact_render_file(template, last_is_text))
	return catalog, hash
}

// Each step that the check refuses, before the run: no process, a name
// that is not a fact name, a fact type that no module writes, and each
// fault of the condition, with its sentence. The refusals of a status
// field and of a Bytes field are refusals of console_condition, which its
// host tests give. A refused step changes nothing in the catalog. The last
// cases are steps that the check takes, at the edges of the fields.
@(test)
a_step_of_a_fact_is_refused_before_the_run :: proc(t: ^testing.T) {
	catalog, _ := fact_step_catalog()
	text_catalog, _ := fact_step_catalog(true)
	empty := Fact_Catalog{allocator = context.temp_allocator}
	Case :: struct {
		catalog:   ^Fact_Catalog,
		fact:      string,
		process:   string,
		condition: string,
		fault:     Fact_Step_Fault,
		refusal:   console_condition.Refusal,
		problem:   string, // "": the sentence is not compared.
	}
	cases := [?]Case {
		{&catalog, "probe.Probe", "", "", .No_Process, .None, "the step of the fact probe.Probe names no process: each process that compiles its package in writes it"},
		{&catalog, "", "probe", "", .Not_A_Fact_Name, .None, ""},
		{&catalog, "probe", "probe", "", .Not_A_Fact_Name, .None, "\"probe\" is not the name of a fact type: a package name, a dot and a record name, as storage.Bad_Block"},
		{&catalog, ".Probe", "probe", "", .Not_A_Fact_Name, .None, ""},
		{&catalog, "probe.", "probe", "", .Not_A_Fact_Name, .None, ""},
		{&catalog, "probe.Probe.value", "probe", "", .Not_A_Fact_Name, .None, ""},
		{&catalog, "probe.Probes", "probe", "", .Unknown_Fact_Type, .None, "no fact type has the name probe.Probes; the fact types of probe are probe.Probe"},
		{&catalog, "storage.Bad_Block", "probe", "", .Unknown_Fact_Type, .None, "no fact type has the name storage.Bad_Block; the fact types are probe.Probe"},
		{&catalog, "Probe.probe", "probe", "", .Unknown_Fact_Type, .None, ""},
		{&empty, "probe.Probe", "probe", "", .Unknown_Fact_Type, .None, "no module of the build writes a fact type: probe.Probe names nothing"},
		// The field and the operator.
		{&catalog, "probe.Probe", "probe", "= 3", .Condition_Refused, .No_Field, ""},
		{&catalog, "probe.Probe", "probe", "value", .Condition_Refused, .No_Operator, "where: after the field value comes an operator: =, !=, <, <=, > or >="},
		{&catalog, "probe.Probe", "probe", "value == 3", .Condition_Refused, .Double_Equal, ""},
		{&catalog, "probe.Probe", "probe", "value ! 3", .Condition_Refused, .Lone_Bang, ""},
		{&catalog, "probe.Probe", "probe", "value =", .Condition_Refused, .No_Value, ""},
		{&catalog, "probe.Probe", "probe", "values = 3", .Condition_Refused, .Unknown_Field, "where: the records Probe have no field values; their fields are value, mark, number"},
		{&text_catalog, "probe.Probe", "probe", "note < \"a\"", .Condition_Refused, .No_Order, ""},
		// The value: its kind, its sign, its range, its form.
		{&catalog, "probe.Probe", "probe", "value = \"42\"", .Condition_Refused, .Wrong_Kind, "where: the field value is Integer, the value is Text"},
		{&text_catalog, "probe.Probe", "probe", "note = 3", .Condition_Refused, .Wrong_Kind, ""},
		{&catalog, "probe.Probe", "probe", "value = -1", .Condition_Refused, .Negative_For_Unsigned, ""},
		{&catalog, "probe.Probe", "probe", "mark = 0x1_0000_0000", .Condition_Refused, .Out_Of_Field, ""},
		{&catalog, "probe.Probe", "probe", "number > 4294967296", .Condition_Refused, .Out_Of_Field, ""},
		{&catalog, "probe.Probe", "probe", "value = forty", .Unreadable_Value, .None, "the value of the condition \"value = forty\" is neither an Integer nor a Text in quotes"},
		{&catalog, "probe.Probe", "probe", "value = 9223372036854775808", .Unreadable_Value, .None, ""},
		{&text_catalog, "probe.Probe", "probe", "note = \"open", .Unreadable_Value, .None, ""},
		{&catalog, "probe.Probe", "probe", "value = 42 7", .Text_After_The_Value, .None, "the condition \"value = 42 7\" has text after its value: a step of a fact has one condition"},
		{&text_catalog, "probe.Probe", "probe", "note = \"ok\" and", .Text_After_The_Value, .None, ""},
		// Steps that the check takes: the edges of each field.
		{&catalog, "probe.Probe", "probe", "", .None, .None, ""},
		{&catalog, "probe.Probe", "probe", "value = 0", .None, .None, ""},
		{&catalog, "probe.Probe", "probe", "value = 9223372036854775807", .None, .None, ""},
		{&catalog, "probe.Probe", "probe", "mark = 0xffff_ffff", .None, .None, ""},
		{&catalog, "probe.Probe", "probe", "number <= 4294967295", .None, .None, ""},
		{&text_catalog, "probe.Probe", "probe", "note != \"\"", .None, .None, ""},
	}
	for item in cases {
		modules_before := len(item.catalog.modules)
		step, fault, refusal, problem := fact_step_check(item.catalog, item.fact, item.process, item.condition)
		testing.expectf(t, fault == item.fault && refusal == item.refusal, "the step %s of %q, %q gave %v and %v, not %v and %v (%s)", item.fact, item.process, item.condition, fault, refusal, item.fault, item.refusal, problem)
		testing.expectf(t, (fault == .None) == (problem == ""), "the step %s, %q has a sentence for each refusal only: %q", item.fact, item.condition, problem)
		if item.problem != "" {
			testing.expect_value(t, problem, item.problem)
		}
		testing.expect_value(t, len(item.catalog.modules), modules_before)
		if fault == .None {
			testing.expect_value(t, len(step.types), 1)
			testing.expect_value(t, step.has_condition, item.condition != "")
		}
	}
}

// The line of a fact matches a step by its process, its module, its key
// and its values. Each other line does not: another process, another
// module, another key, a value that fails the condition, a line with more
// value bytes than the record. The render gives the place of each line of
// a fact in the rendered log, and no place for a line that stays raw.
@(test)
the_line_of_a_fact_matches_its_step :: proc(t: ^testing.T) {
	catalog, hash := fact_step_catalog()
	values := [16]u8{42, 0, 0, 0, 0, 0, 0, 0, 0x46, 0x47, 0x4f, 0x4c, 7, 0, 0, 0}
	line := fact_render_line(hash, FACT_RENDER_KEY, values[:])
	other_hash := hash
	other_hash[0] = 0xFF
	log := strings.concatenate({"[root] root: a text\r\n[log_reader] ", line, "\r\n[log_reader] ", fact_render_line(other_hash, FACT_RENDER_KEY, values[:]), "\r\n[storage] ", line, "\n"}, context.temp_allocator)
	places := make([dynamic]Fact_Line_Place, context.temp_allocator)
	rendered, rendered_lines := fact_lines_render(&catalog, log, &places)
	testing.expect_value(t, rendered_lines, 2)
	testing.expect_value(t, len(places), 2)
	if len(places) != 2 {
		return
	}
	testing.expect_value(t, rendered[places[0].start:places[0].end], "[log_reader] probe: 42 0x4c4f4746 7\r\n")
	testing.expect_value(t, rendered[places[1].start:places[1].end], "[storage] probe: 42 0x4c4f4746 7\n")
	testing.expect_value(t, places[0].process, "log_reader")
	testing.expect_value(t, places[1].process, "storage")

	matches :: proc(t: ^testing.T, catalog: ^Fact_Catalog, process, condition: string, place: Fact_Line_Place) -> bool {
		step, fault, _, problem := fact_step_check(catalog, "probe.Probe", process, condition)
		testing.expectf(t, fault == .None, "the step of %q is taken: %s", condition, problem)
		return fact_step_matches(step, place)
	}
	// Another process, a value that fails, a key or a module of another
	// fact, more value bytes than the record.
	testing.expect(t, !matches(t, &catalog, "log_reader", "", places[1]))
	testing.expect(t, !matches(t, &catalog, "log_reader", "value = 43", places[0]))
	testing.expect(t, !matches(t, &catalog, "log_reader", "value != 42", places[0]))
	testing.expect(t, !matches(t, &catalog, "log_reader", "mark < 0x4c4f4746", places[0]))
	other_key := places[0]
	other_key.line.key_tag += 1
	testing.expect(t, !matches(t, &catalog, "log_reader", "", other_key))
	other_module := places[0]
	other_module.line.module_tag[0] = 0xFF
	testing.expect(t, !matches(t, &catalog, "log_reader", "", other_module))
	too_long := places[0]
	too_long.line.value_count = 17
	testing.expect(t, !matches(t, &catalog, "log_reader", "", too_long))
	// The bytes after the values of a line are zero.
	testing.expect(t, matches(t, &catalog, "log_reader", "number = 7", places[0]))
	testing.expect(t, matches(t, &catalog, "log_reader", "", places[0]))
	testing.expect(t, matches(t, &catalog, "log_reader", "value = 42", places[0]))
	testing.expect(t, matches(t, &catalog, "log_reader", "mark = 0x4c4f4746", places[0]))
	testing.expect(t, matches(t, &catalog, "storage", "value >= 42", places[1]))
}
