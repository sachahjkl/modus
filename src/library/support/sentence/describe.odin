package sentence

import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The text of a description: what a process shows to a reader about the
// types of an export (module.Function).

// The name of each right, as `op.Right` names it.
@(rodata)
right_names := [op.Right]string {
	.Give    = "Give",
	.Read    = "Read",
	.Write   = "Write",
	.Execute = "Execute",
	.Control = "Control",
	.Inspect = "Inspect",
	.Devices = "Devices",
	.Stop    = "Stop",
	.Spend   = "Spend",
	.Physical = "Physical",
	.Schedule = "Schedule",
	.Commit   = "Commit",
	.Events   = "Events",
	.Debug    = "Debug",
	.Counters = "Counters",
}

// The name of each object kind in a description.
@(rodata)
object_names := [op.Object_Kind]string {
	.None      = "no object",
	.Memory    = "Memory",
	.Process   = "Process",
	.Interrupt = "Interrupt",
	.Ports     = "Ports",
	.Machine   = "Machine",
	.Thread    = "Thread",
	.Budget    = "Budget",
	.Log       = "Log",
}

// write_rights writes the names of rights, with a text between two names.
write_rights :: proc "contextless" (writer: ^Writer, rights: op.Rights, between: string) {
	first := true
	for right in op.Right {
		if right in rights {
			write_part(writer, first ? "" : between)
			write_part(writer, right_names[right])
			first = false
		}
	}
}

// write_type writes the type of a parameter, of a result or of a field:
// "Integer", "Text", "Text(32)" for a Text field of 32 bytes, the name of a
// record, "Table(Name)" for a table of records, or "Handle(Read, Write)"
// with the rights that the callee needs. file is the module of the
// description.
write_type :: proc "contextless" (writer: ^Writer, file: []u8, type: module.Type, detail: u32) {
	switch type {
	case .None:
	case .Integer:
		write_part(writer, "Integer")
	case .Text:
		write_part(writer, "Text")
		if detail != 0 {
			write_part(writer, "(")
			write_part(writer, u64(detail))
			write_part(writer, ")")
		}
	case .Table:
		write_part(writer, "Table(")
		write_type(writer, file, .Record, detail)
		write_part(writer, ")")
	case .Bytes:
		write_part(writer, "Bytes")
	case .Record:
		if described, ok := module.record_type(file, detail); ok {
			write_part(writer, module.string_at(file, described.name_offset, described.name_count))
		} else {
			write_part(writer, "Record")
		}
	case .Handle:
		write_part(writer, "Handle")
		if rights := transmute(op.Rights)detail; rights != {} {
			write_part(writer, "(")
			write_rights(writer, rights, ", ")
			write_part(writer, ")")
		}
	}
}

// write_type_word writes the type of a byte of a module file, as
// write_type: "?" for a byte that names no type (a description is input
// that nobody checked), never a type that the file does not hold.
write_type_word :: proc "contextless" (writer: ^Writer, file: []u8, word: u8, detail: u32) {
	type, type_ok := module.type_of_word(word)
	if !type_ok {
		write_part(writer, "?")
		return
	}
	write_type(writer, file, type, detail)
}

// The name of each direction of a table parameter.
@(rodata)
direction_names := [module.Direction]string {
	.Read   = "Read",
	.Change = "Change",
	.Append = "Append",
}

// direction_name gives the name of a direction: "?" for a value out of
// the enumeration (a description is input that nobody checked).
direction_name :: proc "contextless" (direction: module.Direction) -> string {
	return direction <= max(module.Direction) ? direction_names[direction] : "?"
}

// write_parameter_type writes the type of a parameter: as write_type, and
// for a Table or Bytes parameter its direction too: "Table(Reading,
// Change)", "Bytes(Read)". One form in the manual, the console and the
// errors.
write_parameter_type :: proc "contextless" (writer: ^Writer, file: []u8, type: module.Type, detail: u32, direction: module.Direction) {
	name := direction_name(direction)
	switch type {
	case .Table:
		write_part(writer, "Table(")
		write_type(writer, file, .Record, detail)
		write_part(writer, ", ")
		write_part(writer, name)
		write_part(writer, ")")
	case .Bytes:
		write_part(writer, "Bytes(")
		write_part(writer, name)
		write_part(writer, ")")
	case .None, .Integer, .Text, .Record, .Handle:
		write_type(writer, file, type, detail)
	}
}

// write_parameter_type_word writes the type of a parameter from its byte in
// a module file, as write_parameter_type: "?" for a byte that names no type.
write_parameter_type_word :: proc "contextless" (writer: ^Writer, file: []u8, word: u8, detail: u32, direction: module.Direction) {
	type, type_ok := module.type_of_word(word)
	if !type_ok {
		write_part(writer, "?")
		return
	}
	write_parameter_type(writer, file, type, detail, direction)
}

// write_field_type writes the type of a field of a record: as write_type,
// and the size of an Integer that does not have 8 bytes: "Integer(4)",
// "Unsigned(1)", "Unsigned" for an unsigned Integer of 8 bytes. A field
// with a field kind writes its kind in place of its type:
// "Hexadecimal(4)", "Status(Log_Level)", "Module_Name(32)", "Hash(32)". A
// byte of the type or of the kind that names nothing is "?".
write_field_type :: proc "contextless" (writer: ^Writer, file: []u8, item: module.Field) {
	kind, kind_ok := module.field_kind(item)
	if !kind_ok {
		write_part(writer, "?")
		return
	}
	switch kind {
	case .Plain:
	case .Hexadecimal:
		write_part(writer, "Hexadecimal")
		write_field_size(writer, item.detail)
		return
	case .Status:
		which, which_ok := module.field_contract_enum(item)
		write_part(writer, "Status(")
		write_part(writer, which_ok ? value_kinds.CONTRACT_ENUM_TYPES[which].name : "?")
		write_part(writer, ")")
		return
	case .Module_Name:
		write_part(writer, "Module_Name(")
		write_part(writer, u64(item.detail))
		write_part(writer, ")")
		return
	case .Hash:
		write_part(writer, "Hash(")
		write_part(writer, u64(item.detail))
		write_part(writer, ")")
		return
	case .Fact_Values:
		write_part(writer, "Fact_Values(")
		write_part(writer, u64(item.detail))
		write_part(writer, ")")
		return
	}
	if item.type != u8(module.Type.Integer) {
		write_type_word(writer, file, item.type, item.detail)
		return
	}
	write_part(writer, item.unsigned ? "Unsigned" : "Integer")
	write_field_size(writer, item.detail)
}

// write_field_size writes the size of an Integer field that does not have
// 8 bytes, in parentheses: "(4)". The detail 0 and 8 are 8 bytes.
@(private = "file")
write_field_size :: proc "contextless" (writer: ^Writer, detail: u32) {
	if detail != 0 && detail != 8 {
		write_part(writer, "(")
		write_part(writer, u64(detail))
		write_part(writer, ")")
	}
}
