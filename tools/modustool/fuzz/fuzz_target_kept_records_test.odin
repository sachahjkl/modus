package fuzz

import "core:testing"

// Each seed of the kept settings passes its oracle: the record of nothing,
// the last values, a word past each setting beside a name of a later
// release, a zone off its step, a record cut by one byte and one byte
// long, and a page with a full language list.
@(test)
the_seeds_of_the_kept_settings_pass :: proc(t: ^testing.T) {
	seeds := make([dynamic][]u8, context.temp_allocator)
	fuzz_kept_settings_seeds(&seeds)
	testing.expect(t, len(seeds) > 8)
	for seed, index in seeds {
		verdict := fuzz_kept_settings_execute(seed)
		testing.expectf(t, verdict.oracle == .None, "the seed %d breaks the oracle %v: %s", index, verdict.oracle, verdict.text)
		delete(seed)
	}
}
