package system

import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/ring"

// The table of error details (docs/MODULE_CONTRACT.md, section 8, "The table
// of error details"): an optional Append table of error records that the
// caller gives, the last parameter of an export with an error record. The
// export writes one error detail for each thing that it has to say, and its
// error record is the first of them.
//
// In the signature of an export, write the type in full, so that the kernel
// tool reads the direction from it:
//
//   details: ^system.Table_To_Append(errors.Error_Record)
Error_Details :: Table_To_Append(errors.Error_Record)

// error_detail_append appends one error detail. A nil table: the caller
// asked for none, and nothing is written. Else the Append rule: the detail is
// written when it fits, and counted in each case, so that the caller learns
// how many details there were.
error_detail_append :: proc "contextless" (details: ^Error_Details, detail: errors.Error_Record) {
	if details != nil {
		table_append(details, detail)
	}
}

// The kernel writes the table of a command in the layout of this type.
#assert(size_of(Error_Details) == size_of(op.Error_Details_Place))
#assert(offset_of(Error_Details, count) == offset_of(op.Error_Details_Place, count))
#assert(offset_of(Error_Details, capacity) == offset_of(op.Error_Details_Place, capacity))

// call_with_error_details executes one kernel operation, as call_with_error,
// and names a table of error details in the command: when the kernel refuses
// it, the table gets the error record first, then one error detail for each
// other argument that the kernel finds wrong (docs/MODULE_CONTRACT.md,
// "Kernel operations"). A nil table: the command is the command of
// call_with_error. The operation must leave its last value free
// (`op.command_takes_error_details`); else the kernel refuses the command
// with the record Unsupported, and writes no detail.
//
// ```odin
// error: errors.Error_Record
// records: [8]errors.Error_Record
// details := system.Error_Details{records = &records[0], capacity = len(records)}
// _, status := system.call_with_error_details(&error, &details, .Memory_Create, u64(budget), pages, flags)
// for &detail in system.error_details_written(&details) {
// 	system.kernel_error_text(&writer, &detail)
// }
// ```
call_with_error_details :: proc "contextless" (error: ^errors.Error_Record, details: ^Error_Details, operation: op.Operation, values: ..u64) -> (results: [7]u64, status: Status) {
	command := ring.Record {
		kind = u32(operation),
	}
	for value, index in values {
		command.values[index] = value
	}
	if details != nil {
		command.kind |= op.COMMAND_NAMES_ERROR_DETAILS
		command.values[op.ERROR_DETAILS_VALUE] = u64(uintptr(details))
	}
	return command_call(error, command)
}

// error_details_written gives the error details that the table holds: the
// first min(count, capacity). The count can be larger: the caller says how
// many did not fit.
error_details_written :: proc "contextless" (details: ^Error_Details) -> []errors.Error_Record {
	if details == nil || details.records == nil {
		return nil
	}
	return details.records[:min(details.count, details.capacity)]
}
