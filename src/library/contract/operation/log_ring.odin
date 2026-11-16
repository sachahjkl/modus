package operation

// The two rules of a reader of the ring of the log (Log_Head, Log_Record).
//
// The kernel writes record W in the slot W % LOG_RECORD_CAPACITY, over the
// record W - LOG_RECORD_CAPACITY, and stores `written = W + 1` only after
// the whole record. While it writes, `written` is still W. So the record
// W - LOG_RECORD_CAPACITY, whose number is `written - LOG_RECORD_CAPACITY`,
// can be half written: a reader never takes it. A copy that holds the old
// head of a record and the new text would give one program the text of
// another one.
//
// A reader copies the record, puts an acquire fence, reads `written` again,
// and keeps the copy only when `log_copy_kept` holds. The fence keeps the
// compiler from moving a load of the copy after that second load; the
// processor does not reorder two loads.

// log_first_kept gives the first record from the number `after` on that a
// reader can still copy whole, and the count of the records from `after`
// that it cannot: the kernel wrote over them, or writes over the oldest one
// now.
//
// Example: with `written = LOG_RECORD_CAPACITY + 10` and `after = 0`, the
// first record that a reader can copy is 11, and 11 records are lost.
log_first_kept :: proc "contextless" (after: u64, written: u64) -> (next: u64, lost: u64) {
	next = min(after, written)
	if written - next >= LOG_RECORD_CAPACITY {
		lost = written - next - LOG_RECORD_CAPACITY + 1
		next += lost
	}
	return next, lost
}

// log_copy_kept says if the copy of the record `number` is whole: the
// kernel did not start to write over it before `written_after_copy`, the
// value of `written` that the reader loaded after the copy and the fence.
log_copy_kept :: proc "contextless" (number: u64, written_after_copy: u64) -> bool {
	return written_after_copy - number < LOG_RECORD_CAPACITY
}
