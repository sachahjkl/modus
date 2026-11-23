package build

import "core:slice"
import "core:strings"
import "core:testing"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/value_kinds"

// A complete language-neutral manifest with module metadata, budget, enum,
// record, and exports (including optional enum with getter, table, bytes,
// handle, and error_record) parses into the exact Module_Manifest structure.
@(test)
manifest_parse_complete :: proc(t: ^testing.T) {
	source := `
# Language-neutral manifest for a C module.
module: math_c
about: Arithmetic helpers compiled from freestanding C.
library: no
imports: drawing cryptography
budget: working_memory_pages=8 processes=1 threads=2 window_width=640 window_height=480

enum Rounding u32
  member down = 0
  member nearest = 1

enum Signed_Mode i8
  member reverse = -2
  member forward = 1

record Pair size=64
  field left offset=0 type=i64
  field right offset=8 type=u32
  field flags offset=12 type=hex32
  field tag offset=16 type=text(16)
  field digest offset=32 type=hash

record Error_Info size=16
  field code offset=0 type=i64
  field detail offset=8 type=u64

export entry

export current_rounding
  about: Return the active rounding mode.
  result: enum(Rounding)

export add_pair
  about: Sum the fields of a pair using the chosen rounding mode.
  param pair: record(Pair)
  param mode: enum(Rounding) optional getter=current_rounding
  param span: integer(size_pages)
  param mem: handle(read, write)
  param rows: table(Error_Info, change)
  param payload: bytes(read)
  result: integer
  error_record: Error_Info
`
	manifest, problem := manifest_parse(source)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, manifest.name, "math_c")
	testing.expect(t, !manifest.library)
	testing.expect(t, slice.equal(manifest.imports, []string{"drawing", "cryptography"}))
	testing.expect_value(t, manifest.description.about, "Arithmetic helpers compiled from freestanding C.")

	// Budget.
	testing.expect(t, manifest.description.budget.stated)
	testing.expect_value(t, manifest.description.budget.parts.working_memory_pages, u64(8))
	testing.expect_value(t, manifest.description.budget.parts.processes, u64(1))
	testing.expect_value(t, manifest.description.budget.parts.threads, u64(2))
	testing.expect_value(t, manifest.description.budget.parts.window_width, u64(640))
	testing.expect_value(t, manifest.description.budget.parts.window_height, u64(480))

	// Enums.
	testing.expect_value(t, len(manifest.description.enums), 2)
	testing.expect_value(t, manifest.description.enums[0].name, "Rounding")
	testing.expect_value(t, manifest.description.enums[0].size, u8(4))
	testing.expect(t, manifest.description.enums[0].unsigned)
	testing.expect_value(t, len(manifest.description.enums[0].members), 2)
	testing.expect_value(t, manifest.description.enums[1].members[0].value, i64(-2))

	// Records.
	testing.expect_value(t, len(manifest.description.records), 2)
	pair := manifest.description.records[0]
	testing.expect_value(t, pair.name, "Pair")
	testing.expect_value(t, pair.size, u32(64))
	testing.expect_value(t, len(pair.fields), 5)
	testing.expect_value(t, pair.fields[2].kind, value_kinds.Field_Kind.Hexadecimal)
	testing.expect_value(t, pair.fields[3].type, module.Type.Text)
	testing.expect_value(t, pair.fields[3].detail, u32(16))
	testing.expect_value(t, pair.fields[4].type, module.Type.Bytes)
	testing.expect_value(t, pair.fields[4].kind, value_kinds.Field_Kind.Hash)

	// Exports.
	testing.expect_value(t, len(manifest.description.exports), 3)
	testing.expect_value(t, manifest.description.exports[0].name, "entry")
	add_pair := manifest.description.exports[2]
	testing.expect_value(t, add_pair.name, "add_pair")
	testing.expect_value(t, len(add_pair.parameters), 6)
	testing.expect_value(t, add_pair.parameters[0], module.Type.Record)
	testing.expect_value(t, add_pair.details[0], u32(1))
	testing.expect_value(t, add_pair.parameters[1], module.Type.Enum)
	enum_idx, getter_idx := module.enum_detail_of(add_pair.details[1])
	testing.expect_value(t, enum_idx, u32(1))
	testing.expect_value(t, getter_idx, u32(2))
	testing.expect_value(t, add_pair.optional_parameters, u16(1 << 1))
	testing.expect_value(t, add_pair.details[2], value_kinds.integer_unit_detail(value_kinds.size_in(.Pages)))
	expected_rights := op.Rights{.Read, .Write}
	testing.expect_value(t, add_pair.details[3], transmute(u32)expected_rights)
	testing.expect_value(t, add_pair.parameters[4], module.Type.Table)
	testing.expect_value(t, add_pair.directions[4], module.Direction.Change)
	testing.expect_value(t, add_pair.parameters[5], module.Type.Bytes)
	testing.expect_value(t, add_pair.directions[5], module.Direction.Read)
	testing.expect_value(t, add_pair.result, module.Type.Integer)
	testing.expect_value(t, add_pair.error_record, u32(2))
}

// An export that can fail and has no value gives its call outcome alone: an
// error record with no result, or with a record result, is accepted.
@(test)
manifest_parse_outcome_without_value :: proc(t: ^testing.T) {
	for result in ([2]string{"", "  result: record(Err)\n"}) {
		source := strings.concatenate({"module: m\nabout: Ok.\nrecord Err size=8\n  field c offset=0 type=i64\nexport f\n  about: Test.\n", result, "  error_record: Err\n"}, context.temp_allocator)
		manifest, problem := manifest_parse(source)
		testing.expectf(t, problem == "", "the export with an error record and the result %q was refused: %s", result, problem)
		if problem == "" {
			testing.expect_value(t, manifest.description.exports[0].error_record, u32(1))
		}
	}
}

// Adversarial manifest inputs: edges (0, 1, bound, one past bound, negative)
// and malformed directives are refused with a clear diagnostic.
@(test)
manifest_parse_refusals :: proc(t: ^testing.T) {
	Case :: struct {
		label:   string,
		source:  string,
		snippet: string,
	}
	too_long_name := strings.repeat("a", MODULE_NAME_BYTES_MOST + 1, context.temp_allocator)
	too_many_members := strings.builder_make(context.temp_allocator)
	strings.write_string(&too_many_members, "module: m\nabout: Ok.\nenum Big u32\n")
	for i in 0 ..= module.ENUM_MEMBER_CAPACITY {
		strings.write_string(&too_many_members, "  member m")
		strings.write_int(&too_many_members, i)
		strings.write_string(&too_many_members, " = ")
		strings.write_int(&too_many_members, i)
		strings.write_byte(&too_many_members, '\n')
	}

	cases := [?]Case {
		{"empty manifest", "", "required key `module` is absent"},
		{"missing about", "module: m\n", "required key `about` is absent"},
		{"uppercase module name", "module: Bad\nabout: Ok.\n", "not a valid module name"},
		{"module name one past bound", strings.concatenate({"module: ", too_long_name, "\nabout: Ok.\n"}, context.temp_allocator), "not a valid module name"},
		{"control char in about", "module: m\nabout: bad\ttext\n", "UTF-8 without control"},
		{"unknown top key", "module: m\nabout: Ok.\nkernel: yes\n", "unknown top-level key"},
		{"duplicate top key", "module: m\nmodule: n\nabout: Ok.\n", "written twice"},
		{"bad library value", "module: m\nabout: Ok.\nlibrary: true\n", "must be `yes` or `no`"},
		{"duplicate import", "module: m\nabout: Ok.\nimports: a a\n", "listed twice"},
		{"bad import name", "module: m\nabout: Ok.\nimports: ../a\n", "not a valid module name"},
		{"budget zero value", "module: m\nabout: Ok.\nbudget: threads=0\n", "positive integer"},
		{"budget window width alone", "module: m\nabout: Ok.\nbudget: window_width=640\n", "given together"},
		{"budget window one past bound", "module: m\nabout: Ok.\nbudget: window_width=2049 window_height=100\n", "exceeds the limit"},
		{"enum with zero members", "module: m\nabout: Ok.\nenum Empty u32\n", "has 0 members"},
		{"enum with 65 members", strings.to_string(too_many_members), "exceeds the limit"},
		{"enum bad backing type", "module: m\nabout: Ok.\nenum Bad f32\n", "unknown backing type"},
		{"enum value past u8 bound", "module: m\nabout: Ok.\nenum E u8\n  member a = 256\n", "does not fit"},
		{"enum negative u8 value", "module: m\nabout: Ok.\nenum E u8\n  member a = -1\n", "does not fit"},
		{"enum reserved absent word u8", "module: m\nabout: Ok.\nenum E u8\n  member a = 255\n", "reserved as the absent word"},
		{"enum reserved absent word i32", "module: m\nabout: Ok.\nenum E i32\n  member a = -1\n", "reserved as the absent word"},
		{"enum uppercase member name", "module: m\nabout: Ok.\nenum E u32\n  member Fast = 0\n", "not a valid lowercase member name"},
		{"enum duplicate member value", "module: m\nabout: Ok.\nenum E u32\n  member a = 1\n  member b = 1\n", "used twice"},
		{"record past 256 bytes", "module: m\nabout: Ok.\nrecord Big size=257\n", "must be 0 to 256"},
		{"record unaligned i64", "module: m\nabout: Ok.\nrecord R size=16\n  field x offset=4 type=i64\n", "not aligned to 8"},
		{"record field past size", "module: m\nabout: Ok.\nrecord R size=8\n  field x offset=4 type=u64\n", "not aligned"},
		{"record field overflows size", "module: m\nabout: Ok.\nrecord R size=8\n  field x offset=8 type=u8\n", "exceeds record size"},
		{"record unknown field type", "module: m\nabout: Ok.\nrecord R size=8\n  field x offset=0 type=f64\n", "unknown type"},
		{"record text zero", "module: m\nabout: Ok.\nrecord R size=8\n  field x offset=0 type=text(0)\n", "text size must be 1 to 256"},
		{"record unknown handle right", "module: m\nabout: Ok.\nrecord R size=8\n  field h offset=0 type=handle(fly)\n", "unknown handle right"},
		{"export missing about", "module: m\nabout: Ok.\nexport foo\n  result: integer\n", "has no `about:`"},
		{"entry with parameter", "module: m\nabout: Ok.\nexport entry\n  param x: integer\n", "takes no described parameter"},
		{"export unknown param type", "module: m\nabout: Ok.\nexport f\n  about: Test.\n  param x: float\n", "unknown parameter type"},
		{"export unknown result type", "module: m\nabout: Ok.\nexport f\n  about: Test.\n  result: float\n", "unknown result type"},
		{"export optional non-enum", "module: m\nabout: Ok.\nexport f\n  about: Test.\n  param x: integer optional\n", "allowed on enum parameters only"},
		{"export getter missing", "module: m\nabout: Ok.\nenum E u32\n  member a = 0\nexport f\n  about: Test.\n  param e: enum(E) getter=missing\n", "names no export"},
		{"export getter wrong return", "module: m\nabout: Ok.\nenum E u32\n  member a = 0\nexport g\n  about: Bad getter.\n  result: integer\nexport f\n  about: Test.\n  param e: enum(E) getter=g\n", "return an enum"},
		{"export error_record with enum result", "module: m\nabout: Ok.\nenum E u32\n  member a = 0\nrecord Err size=8\n  field c offset=0 type=i64\nexport f\n  about: Test.\n  result: enum(E)\n  error_record: Err\n", "cannot be an enum"},
		{"export table record with handle", "module: m\nabout: Ok.\nrecord With_Handle size=8\n  field h offset=0 type=handle(read)\nexport f\n  about: Test.\n  param t: table(With_Handle, read)\n", "cannot contain a handle"},
		{"export 13 call arguments", "module: m\nabout: Ok.\nexport f\n  about: Test.\n  param p1: integer\n  param p2: integer\n  param p3: integer\n  param p4: integer\n  param p5: integer\n  param p6: integer\n  param p7: integer\n  param p8: integer\n  param p9: integer\n  param p10: integer\n  param p11: integer\n  param p12: integer\n  result: text\n", "at most 12"},
		{"export duplicate name", "module: m\nabout: Ok.\nexport f\n  about: One.\nexport f\n  about: Two.\n", "declared twice"},
	}

	for item in cases {
		_, problem := manifest_parse(item.source)
		testing.expectf(t, problem != "", "case %q must be refused", item.label)
		testing.expectf(t, strings.contains(problem, item.snippet), "case %q gave %q, expected %q", item.label, problem, item.snippet)
	}
}
