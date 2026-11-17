package system

import "modus:contract/errors"

// status_of_word is the border of the status word of a completion that the
// kernel or the root service wrote: its member, with a record of zeros, or
// for a word that names no status, the refusal Bad_Operation with the
// record Bad_Value (value: the word, limit: the largest status). The caller
// copies the error record of the completion only when the refusal record is
// zero. It reads and changes no state.
status_of_word :: proc "contextless" (word: u32) -> (status: Status, refusal: errors.Error_Record) {
	read, ok := member_of_word(Status, u64(word))
	if ok {
		return read, {}
	}
	return .Bad_Operation, errors.error_make(.Bad_Value, value = i64(word), limit = i64(max(Status)))
}
