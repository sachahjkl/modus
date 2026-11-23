// The test builder of the machine test of the builders
// (src/md/features/recipes.md, "The builder"). The service recipes starts
// it as a call host and calls build; the argument act of its recipe says
// what it does:
//
// - "make": writes the object "made", with the argument text, in its store "out";
// - "copy": reads the object "made" of each input tree, and writes its bytes as "copied";
// - "write_input": writes in its input store, which refuses it, and tries a name above its store "out";
// - "network": checks that no slot past its context holds a handle;
// - "hang": never returns;
// - "fail": returns an error record;
// - "stop": stops its process.
//
// Each act but "make" and "copy" fails, so the build is refused and nothing
// is kept. The log lines of the module say what the sandbox refused.
package builder_probe

import "base:intrinsics"
import "modus:contract/blake3"
import "modus:contract/declaration_eval"
import "modus:contract/errors"
import "modus:contract/isolated"
import op "modus:contract/operation"
import pr "modus:contract/plans_recipes"
import "modus:contract/tree_hash"
import "modus:storage"
import "modus:system"

// What the recipe asks of the builder.
Probe_Act :: enum u8 {
	Make,
	Copy,
	Write_Input,
	Network,
	Hang,
	Fail,
	Stop,
}

// The name of each act in the argument act of a recipe.
@(rodata)
PROBE_ACT_NAMES := [Probe_Act]string {
	.Make        = "make",
	.Copy        = "copy",
	.Write_Input = "write_input",
	.Network     = "network",
	.Hang        = "hang",
	.Fail        = "fail",
	.Stop        = "stop",
}

// probe_act_of_name is the one border of the argument act: a name that is
// no act is refused.
probe_act_of_name :: proc "contextless" (name: string) -> (act: Probe_Act, ok: bool) {
	for member in Probe_Act {
		if PROBE_ACT_NAMES[member] == name {
			return member, true
		}
	}
	return {}, false
}

// argument_text gives the text of the field name of the argument record,
// or false when the record has no such field or it is no text.
argument_text :: proc "contextless" (arguments: []u8, name: string) -> (text: string, ok: bool) {
	reader := declaration_eval.Output_Reader{bytes = arguments}
	tag, tag_refusal := declaration_eval.output_read_tag(&reader)
	if tag_refusal != .None || tag != .Record {
		return "", false
	}
	count, count_refusal := declaration_eval.output_read_u32(&reader)
	if count_refusal != .None {
		return "", false
	}
	for _ in 0 ..< count {
		field, field_refusal := declaration_eval.output_read_string(&reader)
		if field_refusal != .None {
			return "", false
		}
		start := reader.offset
		value_tag, value_refusal := declaration_eval.output_read_tag(&reader)
		if value_refusal != .None {
			return "", false
		}
		if field == name && value_tag == .Text {
			value, text_refusal := declaration_eval.output_read_string(&reader)
			return value, text_refusal == .None
		}
		reader.offset = start
		if declaration_eval.output_skip_value(&reader, 1) != .None {
			return "", false
		}
	}
	return "", false
}

// build is the export of the builder contract.
@(export, link_name = "build")
build :: proc "c" (inputs: ^system.Table_To_Read(pr.Recipe_Input_Row), arguments: ^system.Bytes_To_Read, error: ^errors.Error_Record) -> i64 {
	argument_bytes := arguments.bytes[:arguments.count]
	act_name, has_act := argument_text(argument_bytes, "act")
	act, known := probe_act_of_name(act_name)
	if !has_act || !known {
		system.log_fact(.Warning, Unknown_Act{})
		return errors.fail(error, -1, .Bad_Value, .None, 2)
	}
	ctx := system.context_record()
	input, output, opened := storage.builder_stores_open(ctx)
	if !opened {
		return errors.fail(error, -2, .No_Grant, .Store, 0)
	}
	switch act {
	case .Make:
		text, has_text := argument_text(argument_bytes, "text")
		if !has_text {
			text = "made by a builder"
		}
		if _, status := storage.write(&output, storage.ROOT, "made", transmute([]u8)text, error); status != .Ok {
			return -3
		}
		return 1
	case .Copy:
		return copy_inputs(&input, &output, system.table_records(inputs), error)
	case .Write_Input:
		written := "a write of a builder"
		write_error: errors.Error_Record
		if _, status := storage.write(&input, storage.ROOT, "intruder", transmute([]u8)written, &write_error); status == .Ok {
			system.log_fact(.Error, Input_Write_Taken{})
		} else {
			system.log_fact(.Info, Input_Write_Refused{kind = write_error.kind})
		}
		above_error: errors.Error_Record
		_, _ = storage.write(&output, storage.ROOT, "..", transmute([]u8)written, &above_error)
		system.log_fact(.Info, Above_Out_Refused{kind = above_error.kind})
		return errors.fail(error, -4, .Refused, .None, 0)
	case .Network:
		// The slots that a builder has are 0 to 6 and the log; each other
		// slot below the log is empty: a datagram ring, the control ring of
		// the network, a store of its own, the boot image.
		for slot in 7 ..< op.CONTEXT_LOG {
			if kind, _, _ := system.handle_state(ctx.handles[slot]); kind != .None {
				system.log_fact(.Error, Other_Handle{slot = u64(slot)})
				return errors.fail(error, -5, .Refused, .None, 0)
			}
		}
		system.log_fact(.Info, No_Other_Handle{first = 7, last = op.CONTEXT_LOG - 1})
		return errors.fail(error, -5, .Refused, .None, 0)
	case .Hang:
		for {
			intrinsics.cpu_relax()
		}
	case .Fail:
		return errors.fail(error, -6, .Refused, .None, 2)
	case .Stop:
		system.stop(.Failed)
	}
	return -7
}

HEX_DIGITS :: "0123456789abcdef"

hash_hex :: proc "contextless" (hash: [32]u8) -> (text: [64]u8) {
	digits := HEX_DIGITS
	for byte_value, index in hash {
		text[2 * index] = digits[byte_value >> 4]
		text[2 * index + 1] = digits[byte_value & 0x0f]
	}
	return text
}

// The canonical bytes of an input tree, and the bytes of its object "made".
tree_bytes: [tree_hash.MAX_ENCODED_TREE_BYTES]u8
object_bytes: [4096]u8

// copy_inputs writes, for each input tree, the bytes of its object "made"
// as the object "copied" of the store "out". The input store holds the
// objects of each input under their hexadecimal hash.
copy_inputs :: proc "contextless" (input, output: ^storage.Client, rows: []pr.Recipe_Input_Row, error: ^errors.Error_Record) -> i64 {
	if len(rows) == 0 {
		return errors.fail(error, -8, .Empty, .Records, 1)
	}
	for &row in rows {
		name := hash_hex(blake3.Hash(row.hash))
		arguments := [2]isolated.Argument{{integer = u64(storage.ROOT)}, {text = name[:]}}
		value, text, status := storage.call(input, "tree_read", arguments[:], error)
		if status != .Ok || value < 0 || len(text) > len(tree_bytes) {
			return -9
		}
		copy(tree_bytes[:], text)
		entry, found, refusal := tree_hash.tree_lookup(tree_bytes[:len(text)], "made")
		if refusal != .None || !found {
			return errors.fail(error, -10, .Absent, .Objects, 1)
		}
		object_name := hash_hex(entry.hash)
		bytes, object_found, read_status := storage.read(input, storage.ROOT, string(object_name[:]), object_bytes[:], error)
		if read_status != .Ok || !object_found || blake3.hash(bytes) != entry.hash {
			return errors.fail(error, -11, .Damaged, .Objects, 1)
		}
		name_length := 0
		for name_length < len(row.name) && row.name[name_length] != 0 {
			name_length += 1
		}
		system.log_fact(.Info, Input_Read{size = u64(len(bytes))}, string(row.name[:name_length]))
		if _, write_status := storage.write(output, storage.ROOT, "copied", bytes, error); write_status != .Ok {
			return -12
		}
	}
	return 1
}
