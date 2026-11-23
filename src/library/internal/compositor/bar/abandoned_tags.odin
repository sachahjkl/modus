package bar

// The tags of the commands whose asker left before their answer came: the
// Opens of a store picker that the principal closed while the powerbox
// made its list. Each late answer names a dialog of the powerbox that the
// compositor closes at once, so the set keeps every tag until its answer
// comes: a tag that left the set would leave that dialog open, and its
// answer would read as no answer at all.
ABANDONED_TAG_CAPACITY :: 8

Abandoned_Tags :: struct {
	tags:  [ABANDONED_TAG_CAPACITY]u32,
	count: int,
}

// abandoned_tags_full says that the set holds no more tag: the compositor
// then opens no new picker until a late answer frees a place.
abandoned_tags_full :: proc "contextless" (set: ^Abandoned_Tags) -> bool {
	return set.count >= ABANDONED_TAG_CAPACITY
}

// abandoned_tags_add keeps a tag. false: the tag is 0, the set holds it
// already, or the set is full; the set does not change.
abandoned_tags_add :: proc "contextless" (set: ^Abandoned_Tags, tag: u32) -> bool {
	if tag == 0 || set.count < 0 || set.count >= ABANDONED_TAG_CAPACITY {
		return false
	}
	for kept in set.tags[:set.count] {
		if kept == tag {
			return false
		}
	}
	set.tags[set.count] = tag
	set.count += 1
	return true
}

// abandoned_tags_take says if the set holds a tag, and removes it: the
// answer of that tag comes once.
abandoned_tags_take :: proc "contextless" (set: ^Abandoned_Tags, tag: u32) -> bool {
	if tag == 0 || set.count <= 0 || set.count > ABANDONED_TAG_CAPACITY {
		return false
	}
	for index in 0 ..< set.count {
		if set.tags[index] == tag {
			set.count -= 1
			set.tags[index] = set.tags[set.count]
			set.tags[set.count] = 0
			return true
		}
	}
	return false
}
