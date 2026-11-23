// The test builder of the machine test of the builders
// (src/md/features/recipes.md, "The builder"). The service recipes starts
// it as a call host and calls build; the argument act of its recipe says
// what it does:
//
// - "make": writes the object "made", with the argument text, in its store "out";
// - "copy": reads the object "made" of each input tree, and writes its bytes as "copied";
// - "write_input": writes in its input store, which refuses it, and tries the names ".." and "a/b" and an open of ".." in its store "out";
// - "share_out": asks one share more than the storage service holds, through its store "out";
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
import "modus:contract/call_outcome"
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
	Share_Out,
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
	.Share_Out   = "share_out",
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
build :: proc "c" (inputs: ^system.Table_To_Read(pr.Recipe_Input_Row), arguments: ^system.Bytes_To_Read, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	argument_bytes := arguments.bytes[:arguments.count]
	act_name, has_act := argument_text(argument_bytes, "act")
	act, known := probe_act_of_name(act_name)
	if !has_act || !known {
		system.log_fact(.Warning, Unknown_Act{})
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 2)
	}
	ctx := system.context_record()
	input, output, opened := storage.builder_stores_open(ctx)
	if !opened {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Store, 0)
	}
	switch act {
	case .Make:
		text, has_text := argument_text(argument_bytes, "text")
		if !has_text {
			text = "made by a builder"
		}
		if _, status := storage.write(&output, storage.ROOT, "made", transmute([]u8)text, error); status != .Ok {
			// The storage client wrote the record of the refused write.
			return .Callee_Unavailable, 0
		}
		return .Succeeded, 1
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
		// Each way out of the root of the store "out": the names ".." and
		// "a/b", which name no entry under it, and the place of "..".
		for name in ([?]string{"..", "a/b"}) {
			above_error: errors.Error_Record
			if _, status := storage.write(&output, storage.ROOT, name, transmute([]u8)written, &above_error); status == .Ok {
				system.log_fact(.Error, Above_Out_Taken{}, name)
			} else {
				system.log_fact(.Info, Above_Out_Refused{kind = above_error.kind}, name)
			}
		}
		open_error: errors.Error_Record
		if place, status := storage.open_tree(&output, storage.ROOT, "..", &open_error); status == .Ok {
			_ = storage.close_tree(&output, place, &open_error)
			system.log_fact(.Error, Above_Out_Taken{}, "an open of ..")
		} else {
			system.log_fact(.Info, Above_Out_Refused{kind = open_error.kind}, "an open of ..")
		}
		return call_outcome.fail(error, .Wrong_State, .Refused, .None, 0)
	case .Share_Out:
		// One share more than the service holds: each is refused, so no
		// builder holds a share of the service after its end.
		refused: u64
		share_error: errors.Error_Record
		for _ in 0 ..= SHARES_OF_THE_SERVICE {
			if _, _, status := storage.share(&output, storage.ROOT, false, &share_error); status == .Ok {
				system.log_fact(.Error, Share_Made{})
				return call_outcome.fail(error, .Wrong_State, .Refused, .None, 0)
			}
			refused += 1
		}
		system.log_fact(.Info, Shares_Refused{count = refused, kind = share_error.kind})
		return call_outcome.fail(error, .Wrong_State, .Refused, .None, 0)
	case .Network:
		// The slots that a builder has are 0 to 6 and the log; each other
		// slot below the log is empty: a datagram ring, the control ring of
		// the network, a store of its own, the boot image.
		for slot in 7 ..< op.CONTEXT_LOG {
			if kind, _, _ := system.handle_state(ctx.handles[slot]); kind != .None {
				system.log_fact(.Error, Other_Handle{slot = u64(slot)})
				return call_outcome.fail(error, .Wrong_State, .Refused, .None, 0)
			}
		}
		system.log_fact(.Info, No_Other_Handle{first = 7, last = op.CONTEXT_LOG - 1})
		return call_outcome.fail(error, .Wrong_State, .Refused, .None, 0)
	case .Hang:
		for {
			intrinsics.cpu_relax()
		}
	case .Fail:
		return call_outcome.fail(error, .Wrong_State, .Refused, .None, 2)
	case .Stop:
		system.stop(.Failed)
	}
	return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 2)
}

// The shares that the storage service holds (SHARE_CAPACITY of its module).
SHARES_OF_THE_SERVICE :: 16

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
copy_inputs :: proc "contextless" (input, output: ^storage.Client, rows: []pr.Recipe_Input_Row, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if len(rows) == 0 {
		return call_outcome.fail(error, .Argument_Refused, .Empty, .Records, 1)
	}
	for &row in rows {
		name := hash_hex(blake3.Hash(row.hash))
		arguments := [2]isolated.Argument{{integer = u64(storage.ROOT)}, {text = name[:]}}
		tree_size, text, status, _ := storage.call(input, "tree_read", arguments[:], error)
		if status != .Ok || tree_size < 0 || len(text) > len(tree_bytes) {
			// The storage client wrote the record of the refused read.
			return .Callee_Unavailable, 0
		}
		copy(tree_bytes[:], text)
		entry, found, refusal := tree_hash.tree_lookup(tree_bytes[:len(text)], "made")
		if refusal != .None || !found {
			return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Objects, 1)
		}
		object_name := hash_hex(entry.hash)
		bytes, object_found, read_status := storage.read(input, storage.ROOT, string(object_name[:]), object_bytes[:], error)
		if read_status != .Ok || !object_found || blake3.hash(bytes) != entry.hash {
			return call_outcome.fail(error, .Data_Damaged, .Damaged, .Objects, 1)
		}
		name_length := 0
		for name_length < len(row.name) && row.name[name_length] != 0 {
			name_length += 1
		}
		system.log_fact(.Info, Input_Read{size = u64(len(bytes))}, string(row.name[:name_length]))
		if _, write_status := storage.write(output, storage.ROOT, "copied", bytes, error); write_status != .Ok {
			// The storage client wrote the record of the refused write.
			return .Callee_Unavailable, 0
		}
	}
	return .Succeeded, 1
}
