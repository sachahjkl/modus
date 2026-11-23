// The machine test of the builders (src/md/features/recipes.md, "The
// builder"). It registers recipes of the test builder builder_probe with
// the service recipes, and builds them:
//
// 1. the act "make": the builder writes its output, which becomes a
//    realisation; a second build takes the realisation, with no start;
// 2. the act "copy", whose input is the output of 1: the input reaches the
//    builder through its input store;
// 3. the refusals: a write in the input store ("write_input"), a look for a
//    handle past the context ("network"), an error record ("fail"), a stop
//    ("stop"), a builder that no module is, an input that no build gave, and
//    last a builder that never answers ("hang"), which the service ends at
//    the bound of a build.
//
// **Start**: start("build_check") in the console of principal 0. **What a
// reader sees**: no window; one line of the log for each check, then
// "build_check: each check of the builders passed", or a line
// "build_check: WRONG: ...". It stops itself with Done, or Failed.
package build_check

import "modus:contract/blake3"
import "modus:contract/declaration_eval"
import "modus:contract/errors"
import "modus:contract/isolated"
import module "modus:contract/module"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:system"

requests: ring.Ring
next_tag: u32 = 1
connection: system.Call_Connection
recipes_file: []u8
register_export: u32
build_export: u32
probe_hash: blake3.Hash

@(private = "file")
wrong :: proc "contextless" (text: string, value: u64) -> ! {
	system.log_fact(.Error, Wrong{value = value}, text)
	system.stop(.Failed)
}

// arguments_of writes the argument record {act, text} in the canonical form
// of the output of an evaluation: the names in the order of their bytes.
@(private = "file")
arguments_of :: proc "contextless" (buffer: []u8, act: string, text: string) -> []u8 {
	writer := declaration_eval.Output_Writer{buffer = buffer}
	declaration_eval.output_write_u8(&writer, u8(declaration_eval.Value_Tag.Record))
	declaration_eval.output_write_u32(&writer, 2)
	declaration_eval.output_write_string(&writer, "act")
	declaration_eval.output_write_text(&writer, act)
	declaration_eval.output_write_string(&writer, "text")
	declaration_eval.output_write_text(&writer, text)
	if writer.overflow {
		wrong("the arguments do not fit", 0)
	}
	return buffer[:writer.written]
}

// register gives the recipe hash of a recipe of the builder, with at most
// one input tree.
@(private = "file")
register :: proc "contextless" (builder: blake3.Hash, act: string, input: blake3.Hash) -> blake3.Hash {
	head := pr.Recipe_Head {
		output_kind_word = i64(object_cache.Cache_Object_Kind.Tree),
		builder_hash     = value_kinds.Hash_Field(builder),
	}
	rows: [1]pr.Recipe_Input_Row
	row_count := 0
	if input != {} {
		rows[0] = {kind_word = i64(object_cache.Cache_Object_Kind.Tree), hash = value_kinds.Hash_Field(input)}
		copy(rows[0].name[:], "made")
		row_count = 1
	}
	argument_buffer: [256]u8
	bytes := arguments_of(argument_buffer[:], act, "made by a builder of the test")
	arguments := [3]isolated.Argument {
		{record = ([^]u8)(&head)[:size_of(head)]},
		{table = {records = ([^]u8)(&rows[0])[:row_count * size_of(pr.Recipe_Input_Row)], count = u64(row_count)}},
		{table = {records = bytes, count = u64(len(bytes))}},
	}
	references: [1]pr.Recipe_Reference
	error: errors.Error_Record
	count, status := system.call_isolated(&connection, recipes_file, register_export, arguments[:], &error, false, ([^]u8)(&references[0])[:size_of(references)])
	if status != .Ok || count != 1 {
		wrong("recipes.register refused a recipe of the test; the error kind", u64(error.kind))
	}
	return blake3.Hash(references[0].recipe_hash)
}

// build builds a recipe in a mode, and gives its row, or its refusal: the
// value found of the error record of the service.
@(private = "file")
build :: proc "contextless" (recipe: blake3.Hash, mode: pr.Build_Mode) -> (row: pr.Recipe_Build_Row, refusal: pr.Recipe_Refusal) {
	reference := pr.Recipe_Reference{recipe_hash = value_kinds.Hash_Field(recipe)}
	arguments := [2]isolated.Argument{{record = ([^]u8)(&reference)[:size_of(reference)]}, {integer = u64(mode)}}
	rows: [1]pr.Recipe_Build_Row
	error: errors.Error_Record
	count, status := system.call_isolated(&connection, recipes_file, build_export, arguments[:], &error, false, ([^]u8)(&rows[0])[:size_of(rows)])
	switch status {
	case .Ok:
		if count != 1 {
			wrong("recipes.build gave no row; the count", u64(count))
		}
		return rows[0], .None
	case .Failed:
		found, known := pr.recipe_refusal_of_word(u64(error.found))
		if !known {
			wrong("recipes.build refused with a word that names no refusal", u64(error.found))
		}
		return {}, found
	case .Lend_Failed, .No_Room, .Ring_Full, .Stopped, .Refused, .Wrong_Answer, .Not_Done, .Failed_With_Wrong_Details, .Timed_Out:
	}
	wrong("the call of recipes.build did not come back; the call status", u64(status))
}

@(private = "file")
refused_as_asked :: proc "contextless" (act: string, recipe: blake3.Hash, expected: pr.Recipe_Refusal) {
	_, refusal := build(recipe, .Build_Only)
	if refusal != expected {
		wrong("a build was not refused as the test asks; the refusal", u64(refusal))
	}
	system.log_fact(.Info, Refused_As_Asked{refusal = u64(refusal)}, act)
}

@(private = "file")
head_of :: proc "contextless" (hash: value_kinds.Hash_Field) -> u64 {
	return (transmute([4]u64)hash)[0]
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	opened, ring_status := system.ring_open(ctx.handles[system.GRANT_ROOT], receive_handles = true)
	if ring_status != .Ok {
		wrong("no root ring; the status", u64(ring_status))
	}
	requests = opened
	image_handle := ctx.handles[system.GRANT_IMAGE]
	address, map_status := system.memory_map(image_handle, {})
	if image_handle == 0 || map_status != .Ok {
		wrong("the boot image does not map; the status", u64(map_status))
	}
	image := ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	probe_file := system.image_find(image, "builder_probe")
	if probe_file == nil {
		wrong("the boot image holds no builder_probe", 0)
	}
	probe_hash = blake3.hash(probe_file)

	connected: system.Status
	connection, connected = system.service_connection(&requests, next_tag, "recipes")
	next_tag += 1
	if connected != .Ok {
		wrong("the root service gave no connection to recipes; the status", u64(connected))
	}
	entry := system.image_entry_of(image, connection.module_hash)
	if entry == nil {
		wrong("recipes is no module of the boot image", 0)
	}
	recipes_file = image[entry.offset:][:entry.size]
	register_export = module.export_find(recipes_file, "register")
	build_export = module.export_find(recipes_file, "build")
	if register_export == 0 || build_export == 0 {
		wrong("recipes has no export register or build", 0)
	}

	// 1. The output of a builder becomes a realisation, and a second build
	//    takes it with no start.
	made := register(probe_hash, "make", {})
	row, refusal := build(made, .Build_Only)
	if refusal != .None || row.outcome_word != i64(pr.Recipe_Build_Outcome.Built_Locally) {
		wrong("the act make was not built; the refusal", u64(refusal))
	}
	system.log_fact(.Info, Built{outcome = u64(row.outcome_word), output_head = head_of(row.output_hash)}, "a builder made an output")
	again, again_refusal := build(made, .Cache_First)
	if again_refusal != .None || again.outcome_word != i64(pr.Recipe_Build_Outcome.From_Cache) || again.output_hash != row.output_hash {
		wrong("the second build of make did not take its realisation; the outcome", u64(again.outcome_word))
	}
	system.log_fact(.Info, Built{outcome = u64(again.outcome_word), output_head = head_of(again.output_hash)}, "the second build took the realisation")

	// 2. The output of 1 is the input of a build.
	copied := register(probe_hash, "copy", blake3.Hash(row.output_hash))
	copy_row, copy_refusal := build(copied, .Build_Only)
	if copy_refusal != .None || copy_row.outcome_word != i64(pr.Recipe_Build_Outcome.Built_Locally) || copy_row.output_hash == row.output_hash {
		wrong("the act copy was not built from its input; the refusal", u64(copy_refusal))
	}
	system.log_fact(.Info, Built{outcome = u64(copy_row.outcome_word), output_head = head_of(copy_row.output_hash)}, "the output of a build was the input of the next")

	// 3. The refusals; the hang last, as it takes the bound of a build.
	refused_as_asked("write_input", register(probe_hash, "write_input", {}), .Builder_Failed)
	refused_as_asked("network", register(probe_hash, "network", {}), .Builder_Failed)
	refused_as_asked("fail", register(probe_hash, "fail", {}), .Builder_Failed)
	refused_as_asked("stop", register(probe_hash, "stop", {}), .Builder_Failed)
	no_module := "a builder that no module is"
	refused_as_asked("a builder that no module is", register(blake3.hash(transmute([]u8)no_module), "make", {}), .Builder_Absent)
	never := "an output that no build gave"
	refused_as_asked("an input that no build gave", register(probe_hash, "copy", blake3.hash(transmute([]u8)never)), .Input_Absent)
	refused_as_asked("hang", register(probe_hash, "hang", {}), .Builder_Timed_Out)

	system.call_connection_end(&connection)
	system.log_fact(.Info, Done{})
	system.stop(.Done)
}

