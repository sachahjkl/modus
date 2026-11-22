// The rules of the interrupt controller of a processor of a browser
// machine, in software, in the place of the local APIC
// (src/md/features/browser_machine.md, "The timer and the cycle counter").
// A vector that waits is one bit of a set of words; the processor takes
// the highest first, as the APIC delivers the vector of highest priority
// first. The timer is a deadline on the clock of the page, in nanoseconds.
// The kernel holds the words in the shared memory and changes them with
// atomic operations (apic_wasm64p32.odin); this package holds the rules,
// with host tests.
//
// This package allocates no memory and calls no kernel operation.
package virtual_interrupt_controller

VECTOR_COUNT :: 256
PENDING_WORD_COUNT :: VECTOR_COUNT / 64
// The vectors below this one are the exceptions of the processor: an
// exception comes from an instruction, never from the controller.
FIRST_INTERRUPT_VECTOR :: 32

Pending_Words :: [PENDING_WORD_COUNT]u64

// vector_bit gives the word and the bit of vector. false: the vector is an
// exception, which the controller never gives.
vector_bit :: proc "contextless" (vector: u8) -> (word_index: int, mask: u64, ok: bool) {
	if vector < FIRST_INTERRUPT_VECTOR {
		return 0, 0, false
	}
	return int(vector / 64), u64(1) << (vector % 64), true
}

// highest_pending gives the highest vector whose bit is set in pending.
// false: none is set. A bit of an exception vector is never given.
highest_pending :: proc "contextless" (pending: Pending_Words) -> (vector: u8, found: bool) {
	for index := PENDING_WORD_COUNT - 1; index >= 0; index -= 1 {
		word := pending[index]
		if index == 0 {
			word &~= (u64(1) << FIRST_INTERRUPT_VECTOR) - 1
		}
		if word != 0 {
			return u8(index * 64 + 63 - int(count_leading_zeros(word))), true
		}
	}
	return 0, false
}

// The timer of one processor. Only its processor writes it. A period of 0:
// no timer.
Timer :: struct {
	deadline_nanoseconds: u64,
	period_nanoseconds:   u64,
	vector:               u8,
	paused:               bool,
}

// timer_arm starts a periodic timer that gives vector every period
// nanoseconds, the first time one period after now. false: a period of 0,
// or a vector that is an exception; the timer does not change.
timer_arm :: proc "contextless" (timer: ^Timer, now_nanoseconds: u64, period_nanoseconds: u64, vector: u8) -> bool {
	if period_nanoseconds == 0 || vector < FIRST_INTERRUPT_VECTOR {
		return false
	}
	timer^ = {
		deadline_nanoseconds = add_saturating(now_nanoseconds, period_nanoseconds),
		period_nanoseconds   = period_nanoseconds,
		vector               = vector,
	}
	return true
}

// timer_pause stops, or continues, the delivery of the timer. The deadline
// keeps running, as the count of a masked APIC timer: a deadline that
// passed during the pause gives one vector at the next check.
timer_pause :: proc "contextless" (timer: ^Timer, paused: bool) {
	timer.paused = paused
}

// timer_check says whether the deadline passed, and then moves it one
// period on. Deadlines that the processor missed, while a long kernel path
// or a busy page held it, give one tick, as the one bit of the APIC: the
// next deadline is one period after now, so the processor never catches up
// with a burst of ticks. true: the caller sets the vector of the timer.
timer_check :: proc "contextless" (timer: ^Timer, now_nanoseconds: u64) -> (due: bool) {
	period := timer.period_nanoseconds
	if period == 0 || timer.paused || now_nanoseconds < timer.deadline_nanoseconds {
		return false
	}
	next := add_saturating(timer.deadline_nanoseconds, period)
	if next <= now_nanoseconds {
		next = add_saturating(now_nanoseconds, period)
	}
	timer.deadline_nanoseconds = next
	return true
}

// wait_bound gives how long the processor can wait for a message before
// the deadline of its timer, at most longest_nanoseconds: 0 when the
// deadline passed.
wait_bound :: proc "contextless" (timer: Timer, now_nanoseconds: u64, longest_nanoseconds: u64) -> u64 {
	if timer.period_nanoseconds == 0 || timer.paused {
		return longest_nanoseconds
	}
	if now_nanoseconds >= timer.deadline_nanoseconds {
		return 0
	}
	return min(timer.deadline_nanoseconds - now_nanoseconds, longest_nanoseconds)
}

@(private = "file")
add_saturating :: #force_inline proc "contextless" (a: u64, b: u64) -> u64 {
	return a > max(u64) - b ? max(u64) : a + b
}

@(private = "file")
count_leading_zeros :: #force_inline proc "contextless" (word: u64) -> u64 {
	count := u64(0)
	for bit := u64(63); word & (u64(1) << bit) == 0; bit -= 1 {
		count += 1
	}
	return count
}
