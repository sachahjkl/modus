package assemble

import "modus:contract/module_file_writer"
import "modus:contract/value_kinds"
import "internal:assemble/assembler"

// The log facts of the assembler (src/md/features/log_facts.md): the
// refusal of a source, the refusals of the writer of module files, and the
// module file that it wrote, as records of fields. Each fact template is
// the sentence that the line wrote before it was a fact, but for the words
// of a refusal of the writer. No field has the name of a column of the head
// of facts(): number, time, process, level.
//
// Neither refusal crosses a border as a typed value: the export answers a
// refusal of the assembler with the place and the byte of the source, and a
// refusal of the writer with its number in the value `found` of an error
// record. So neither is a contract enum that a reader names, and a field
// takes no enum of another package. A refusal of the assembler is its word,
// an Integer of 4 bytes that the sentence writes as its number beside the
// words of assembler.refusal_sentence. A refusal of the writer is the name
// of its member, which this module writes from WRITER_REFUSAL_NAMES. A Text
// field is the last field.

// The bytes of the Text field of the sentence of a refusal of the
// assembler: the longest has 119 bytes, and a zero byte; the record then
// ends on 8 bytes.
REFUSAL_SENTENCE_FIELD_BYTES :: 124
// The bytes of the Text field of the name of a refusal of the writer: the
// longest, "Segment_Written_And_Executed", has 28 bytes, and a zero byte.
WRITER_REFUSAL_FIELD_BYTES :: 40

// The name of each refusal of the writer of module files, as its member.
@(rodata)
WRITER_REFUSAL_NAMES := [module_file_writer.Refusal]string {
	.None                         = "None",
	.Table_Past_Bound             = "Table_Past_Bound",
	.Not_A_Name                   = "Not_A_Name",
	.Name_Twice                   = "Name_Twice",
	.Export_Without_Description   = "Export_Without_Description",
	.Too_Many_Arguments           = "Too_Many_Arguments",
	.Parameter_Lists_Disagree     = "Parameter_Lists_Disagree",
	.Export_Outside_Code          = "Export_Outside_Code",
	.Segment_Not_On_Pages         = "Segment_Not_On_Pages",
	.Segment_Past_Address_Range   = "Segment_Past_Address_Range",
	.Segment_Data_Past_Size       = "Segment_Data_Past_Size",
	.Segment_Overlap              = "Segment_Overlap",
	.Segment_Written_And_Executed = "Segment_Written_And_Executed",
	.Import_Slot_Not_Valid               = "Import_Slot_Not_Valid",
	.Rebase_Not_Valid             = "Rebase_Not_Valid",
	.Record_Not_Valid             = "Record_Not_Valid",
	.Fact_Not_Valid               = "Fact_Not_Valid",
	.Facts_Without_Own_Hash_Place = "Facts_Without_Own_Hash_Place",
	.Own_Hash_Place_Not_Writable  = "Own_Hash_Place_Not_Writable",
	.Output_Too_Small             = "Output_Too_Small",
	.Written_File_Not_Valid       = "Written_File_Not_Valid",
	.Record_Streams_Past_Bound    = "Record_Streams_Past_Bound",
	.Record_Stream_Without_Description = "Record_Stream_Without_Description",
	.Record_Stream_Place_Not_Writable  = "Record_Stream_Place_Not_Writable",
	.Record_Streams_Not_Valid     = "Record_Streams_Not_Valid",
	.Enum_Not_Valid               = "Enum_Not_Valid",
	.Member_Text_Not_Valid        = "Member_Text_Not_Valid",
	.Need_Not_Valid               = "Need_Not_Valid",
	.Parameter_Setting_Not_Valid  = "Parameter_Setting_Not_Valid",
}

// A module file written whole.
@(log_fact = "assemble: a module file of {size} with {exports} exports")
Module_File_Written :: struct {
	size:    value_kinds.Size_In_Bytes,
	exports: u64,
}

// The assembler refused the source, at a place of the text.
@(log_fact = "assemble: line {line}, column {column}: {refusal_sentence} (refusal {refusal}, value {value})")
Source_Refused :: struct {
	line:             u32,
	column:           u32,
	value:            u64,
	refusal:          u32,
	refusal_sentence: [124]u8,
}

// The writer of module files refused the parts that the assembler gave.
@(log_fact = "assemble: the module file writer refused the parts: refusal {writer_refusal}, index {index}")
Parts_Refused :: struct {
	index:          u64,
	writer_refusal: [40]u8,
}

// The writer of module files refused the file.
@(log_fact = "assemble: the module file writer refused the file: refusal {writer_refusal}, index {index}")
File_Refused :: struct {
	index:          u64,
	writer_refusal: [40]u8,
}

// The tool reads the length of a Text field as a literal: the constants
// name the same bytes. A refusal of the assembler is a word of 4 bytes.
#assert(size_of(Source_Refused) == 20 + REFUSAL_SENTENCE_FIELD_BYTES)
#assert(size_of(Parts_Refused) == 8 + WRITER_REFUSAL_FIELD_BYTES)
#assert(size_of(assembler.Refusal) == size_of(u32))

// writer_refusal_field gives the Text field of the name of a refusal of
// the writer.
writer_refusal_field :: proc "contextless" (refusal: module_file_writer.Refusal) -> [WRITER_REFUSAL_FIELD_BYTES]u8 {
	return value_kinds.text_field(WRITER_REFUSAL_NAMES[refusal], WRITER_REFUSAL_FIELD_BYTES)
}
