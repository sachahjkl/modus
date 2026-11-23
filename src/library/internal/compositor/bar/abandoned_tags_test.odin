#+build !freestanding
package bar

import "core:testing"

// Each abandoned Open keeps its tag until its late answer: a second Open
// abandoned before the first answer does not push the first one out.
@(test)
abandoned_tags_keep_each_tag_until_its_answer :: proc(t: ^testing.T) {
	set: Abandoned_Tags
	// 0 is no tag, and takes nothing.
	testing.expect(t, !abandoned_tags_add(&set, 0))
	testing.expect(t, !abandoned_tags_take(&set, 0))
	testing.expect_value(t, set.count, 0)
	// An empty set holds no tag.
	testing.expect(t, !abandoned_tags_take(&set, 7))
	// Up to the bound, each tag is kept; one past the bound is refused, and
	// the set is unchanged.
	for tag in 1 ..= u32(ABANDONED_TAG_CAPACITY) {
		testing.expect(t, abandoned_tags_add(&set, tag))
	}
	testing.expect(t, abandoned_tags_full(&set))
	before := set
	testing.expect(t, !abandoned_tags_add(&set, max(u32)))
	testing.expect_value(t, set, before)
	// A tag kept twice is one tag.
	set.count -= 1
	testing.expect(t, !abandoned_tags_add(&set, 1))
	set.count += 1
	// The answers come in any order, each once; a tag that the set never
	// held takes nothing.
	testing.expect(t, abandoned_tags_take(&set, 1))
	testing.expect(t, !abandoned_tags_take(&set, 1))
	testing.expect(t, !abandoned_tags_full(&set))
	testing.expect(t, !abandoned_tags_take(&set, max(u32)))
	testing.expect(t, abandoned_tags_take(&set, u32(ABANDONED_TAG_CAPACITY)))
	for tag in 2 ..< u32(ABANDONED_TAG_CAPACITY) {
		testing.expect(t, abandoned_tags_take(&set, tag))
	}
	testing.expect_value(t, set.count, 0)
	// A damaged count takes and keeps nothing.
	set.count = ABANDONED_TAG_CAPACITY + 1
	testing.expect(t, !abandoned_tags_take(&set, 2))
	testing.expect(t, !abandoned_tags_add(&set, 2))
	set.count = -1
	testing.expect(t, !abandoned_tags_take(&set, 2))
	testing.expect(t, !abandoned_tags_add(&set, 2))
	// The last case: a set that frees a place keeps a new tag again.
	set = {}
	testing.expect(t, abandoned_tags_add(&set, 9))
	testing.expect(t, abandoned_tags_take(&set, 9))
}
