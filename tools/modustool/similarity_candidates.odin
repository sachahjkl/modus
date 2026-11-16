package modustool

import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:sync"
import "core:thread"

// The code pieces and the candidates that the anti-unification compares
// (src/md/infrastructure/similarity_finder.md, "2. The code pieces" and
// "5. The candidates").

// A procedure, a run and a block smaller than this save less than the
// call that replaces them.
SIMILARITY_PIECE_NODES_LEAST :: 40
// The same for an expression.
SIMILARITY_EXPRESSION_NODES_LEAST :: 12
// An expression is a family from this count of uses.
SIMILARITY_EXPRESSION_USES_LEAST :: 3
// The least share of each member that the template of a family covers;
// it is also the least score of a pair that the near pass keeps.
SIMILARITY_COVERAGE_LEAST :: 0.70
// The report counts what each minimum and the threshold leave just
// outside: the sizes and the scores from these values up.
SIMILARITY_PIECE_NODES_NEAR_MINIMUM :: 30
SIMILARITY_EXPRESSION_NODES_NEAR_MINIMUM :: 9
SIMILARITY_SCORE_NEAR_THRESHOLD :: 0.65
// The threads that compare the candidate pairs, at most.
SIMILARITY_COMPARISON_THREADS_MOST :: 16

Similarity_Piece_Kind :: enum u8 {
	Procedure,
	Run, // Two or more consecutive statements of one block.
	Expression,
	Block,
}

// A code piece: one root node, or the consecutive statements of a run.
// Its nodes are the interval [first, last + size of last) of the table.
Similarity_Piece :: struct {
	first:      i32,
	last:       i32,
	root_count: i32,
	size:       i32,
	kind:       Similarity_Piece_Kind,
}

similarity_piece_range :: proc(nodes: []Similarity_Node, piece: Similarity_Piece) -> (low, high: i32) {
	return piece.first, piece.last + nodes[piece.last].size
}

similarity_piece_contains :: proc(nodes: []Similarity_Node, outer, inner: Similarity_Piece) -> bool {
	outer_low, outer_high := similarity_piece_range(nodes, outer)
	inner_low, inner_high := similarity_piece_range(nodes, inner)
	return outer_low <= inner_low && inner_high <= outer_high
}

similarity_pieces_overlap :: proc(nodes: []Similarity_Node, first, other: Similarity_Piece) -> bool {
	first_low, first_high := similarity_piece_range(nodes, first)
	other_low, other_high := similarity_piece_range(nodes, other)
	return first_low < other_high && other_low < first_high
}

Similarity_Keyed_Piece :: struct {
	key:   u64,
	piece: i32,
}

// similarity_groups_by_key gives the groups of pieces with one key and at
// least `least` members, each in the order of the pieces.
similarity_groups_by_key :: proc(keyed: []Similarity_Keyed_Piece, least: int, allocator: mem.Allocator) -> [][]i32 {
	slice.sort_by(keyed, proc(a, b: Similarity_Keyed_Piece) -> bool {
		return a.key < b.key || (a.key == b.key && a.piece < b.piece)
	})
	groups := make([dynamic][]i32, allocator)
	start := 0
	for index in 1 ..= len(keyed) {
		if index < len(keyed) && keyed[index].key == keyed[start].key {
			continue
		}
		if index - start >= least {
			group := make([]i32, index - start, allocator)
			for position in 0 ..< len(group) {
				group[position] = keyed[start + position].piece
			}
			append(&groups, group)
		}
		start = index
	}
	return groups[:]
}

// One repeated run of statements: its length, and the place in the
// stream of the statements of each occurrence.
Similarity_Run_Group :: struct {
	length: i32,
	starts: []i32,
}

@(private = "file")
Similarity_Suffix :: struct {
	first:    i64,
	second:   i64,
	position: i32,
}

@(private = "file")
Similarity_Statement_Shape :: struct {
	hash:     u64,
	position: i32,
}

// The stream of the statements of all the blocks: each statement as the
// number of its shape hash, and after each list a number that no other
// place has, so no run crosses the end of a list.
Similarity_Statement_Stream :: struct {
	ids:        []i64,
	nodes:      []i32, // The statement at each place, or -1 at the end of a list.
	shape_count: i64,
}

similarity_statement_stream :: proc(nodes: []Similarity_Node, allocator: mem.Allocator) -> Similarity_Statement_Stream {
	places := make([dynamic]i32, allocator)
	for node in 0 ..< len(nodes) {
		if nodes[node].kind != .Block_Stmt && nodes[node].kind != .Case_Clause {
			continue
		}
		count := 0
		child := nodes[node].first_child
		for child >= 0 {
			if similarity_kind_is_statement(nodes[child].kind) {
				count += 1
			}
			child = nodes[child].next_sibling
		}
		if count < 2 {
			continue
		}
		child = nodes[node].first_child
		for child >= 0 {
			if similarity_kind_is_statement(nodes[child].kind) {
				append(&places, child)
			}
			child = nodes[child].next_sibling
		}
		append(&places, -1)
	}
	shapes := make([dynamic]Similarity_Statement_Shape, allocator)
	for node, position in places {
		if node >= 0 {
			append(&shapes, Similarity_Statement_Shape{hash = nodes[node].shape_hash, position = i32(position)})
		}
	}
	slice.sort_by(shapes[:], proc(a, b: Similarity_Statement_Shape) -> bool {
		return a.hash < b.hash || (a.hash == b.hash && a.position < b.position)
	})
	ids := make([]i64, len(places), allocator)
	shape_count: i64 = 0
	for shape, index in shapes {
		if index > 0 && shape.hash != shapes[index - 1].hash {
			shape_count += 1
		}
		ids[shape.position] = shape_count
	}
	if len(shapes) > 0 {
		shape_count += 1
	}
	separator := shape_count
	for node, position in places {
		if node < 0 {
			ids[position] = separator
			separator += 1
		}
	}
	return Similarity_Statement_Stream{ids = ids, nodes = places[:], shape_count = shape_count}
}

// similarity_suffix_array sorts the suffixes of the stream by prefix
// doubling: each round sorts by the rank of the first half and of the
// second half, until each rank is unique.
similarity_suffix_array :: proc(ids: []i64, allocator: mem.Allocator) -> []i32 {
	count := len(ids)
	ranks := make([]i64, count, allocator)
	copy(ranks, ids)
	order := make([]Similarity_Suffix, count, allocator)
	step := 1
	for {
		for position in 0 ..< count {
			order[position] = Similarity_Suffix{first = ranks[position], second = position + step < count ? ranks[position + step] : -1, position = i32(position)}
		}
		slice.sort_by(order, proc(a, b: Similarity_Suffix) -> bool {
			return a.first < b.first || (a.first == b.first && (a.second < b.second || (a.second == b.second && a.position < b.position)))
		})
		distinct_count: i64 = 0
		for index in 0 ..< count {
			if index > 0 && (order[index].first != order[index - 1].first || order[index].second != order[index - 1].second) {
				distinct_count += 1
			}
			ranks[order[index].position] = distinct_count
		}
		if distinct_count + 1 >= i64(count) || step >= count {
			break
		}
		step *= 2
	}
	suffixes := make([]i32, count, allocator)
	for index in 0 ..< count {
		suffixes[index] = order[index].position
	}
	return suffixes
}

// similarity_longest_common_prefixes gives, for each place of the suffix
// array, the length of the prefix that its suffix shares with the suffix
// before it (the algorithm of Kasai).
similarity_longest_common_prefixes :: proc(ids: []i64, suffixes: []i32, allocator: mem.Allocator) -> []i32 {
	count := len(ids)
	inverse := make([]i32, count, allocator)
	for position, index in suffixes {
		inverse[position] = i32(index)
	}
	prefixes := make([]i32, count, allocator)
	shared := 0
	for position in 0 ..< count {
		place := int(inverse[position])
		if place == 0 {
			shared = 0
			continue
		}
		before := int(suffixes[place - 1])
		for position + shared < count && before + shared < count && ids[position + shared] == ids[before + shared] {
			shared += 1
		}
		prefixes[place] = i32(shared)
		if shared > 0 {
			shared -= 1
		}
	}
	return prefixes
}

@(private = "file")
Similarity_Interval :: struct {
	prefix: i32,
	left:   i32,
}

// similarity_repeated_runs gives each run of two or more statements that
// occurs two or more times, at least the minimum size, that no longer run
// with the same occurrences holds, and whose occurrences do not overlap.
// near_minimum counts the groups just below the minimum size.
similarity_repeated_runs :: proc(nodes: []Similarity_Node, stream: Similarity_Statement_Stream, allocator: mem.Allocator) -> (groups: []Similarity_Run_Group, near_minimum: i32) {
	suffixes := similarity_suffix_array(stream.ids, allocator)
	prefixes := similarity_longest_common_prefixes(stream.ids, suffixes, allocator)
	found := make([dynamic]Similarity_Run_Group, allocator)
	stack := make([dynamic]Similarity_Interval, allocator)
	append(&stack, Similarity_Interval{prefix = 0, left = 0})
	count := i32(len(suffixes))
	for place: i32 = 1; place <= count; place += 1 {
		current: i32 = place < count ? prefixes[place] : 0
		left := place - 1
		for stack[len(stack) - 1].prefix > current {
			interval := pop(&stack)
			if interval.prefix >= 2 {
				if group, accepted, near := similarity_run_group(nodes, stream, suffixes[interval.left:place], interval.prefix, allocator); accepted {
					append(&found, group)
				} else if near {
					near_minimum += 1
				}
			}
			left = interval.left
		}
		if stack[len(stack) - 1].prefix < current {
			append(&stack, Similarity_Interval{prefix = current, left = left})
		}
	}
	slice.sort_by(found[:], proc(a, b: Similarity_Run_Group) -> bool {
		return a.starts[0] < b.starts[0] || (a.starts[0] == b.starts[0] && a.length > b.length)
	})
	return found[:], near_minimum
}

@(private = "file")
similarity_run_group :: proc(nodes: []Similarity_Node, stream: Similarity_Statement_Stream, occurrences: []i32, length: i32, allocator: mem.Allocator) -> (group: Similarity_Run_Group, accepted, near_minimum: bool) {
	starts := make([]i32, len(occurrences), allocator)
	copy(starts, occurrences)
	slice.sort(starts)
	size: i32 = 0
	for offset in 0 ..< length {
		size += nodes[stream.nodes[starts[0] + offset]].size
	}
	if size < SIMILARITY_PIECE_NODES_LEAST {
		return {}, false, size >= SIMILARITY_PIECE_NODES_NEAR_MINIMUM
	}
	// A longer run to the left with the same occurrences holds this one.
	extends_left := true
	for start in starts {
		if start == 0 || stream.ids[start - 1] >= stream.shape_count || stream.ids[start - 1] != stream.ids[starts[0] - 1] {
			extends_left = false
			break
		}
	}
	if extends_left {
		return {}, false, false
	}
	// Overlapping occurrences are one statement repeated in a row: an
	// expression family finds that, and a run of them counts it many times.
	for index in 1 ..< len(starts) {
		if starts[index] < starts[index - 1] + length {
			return {}, false, false
		}
	}
	return Similarity_Run_Group{length = length, starts = starts}, true, false
}

// The features of a near piece for the filter: the count of each pair of a
// parent kind and a node kind, and the count of each node kind, both sorted
// by the number of the feature.
Similarity_Feature :: struct {
	feature: u32,
	count:   i32,
}

Similarity_Near_Piece :: struct {
	piece:  i32,
	size:   i32,
	pairs:  []Similarity_Feature,
	kinds:  []Similarity_Feature,
	prefix: []u32, // The features of the pairs whose units are in the prefix of the filter.
}

@(private = "file")
SIMILARITY_FEATURE_ROOT :: 255

similarity_near_features :: proc(nodes: []Similarity_Node, piece: Similarity_Piece, scratch_counts: []i32, touched: ^[dynamic]u32, allocator: mem.Allocator) -> (pairs, kinds: []Similarity_Feature) {
	low, high := similarity_piece_range(nodes, piece)
	clear(touched)
	for node := low; node < high; node += 1 {
		parent_kind: u32 = SIMILARITY_FEATURE_ROOT
		if parent := nodes[node].parent; parent >= low && parent < high {
			parent_kind = u32(nodes[parent].kind)
		}
		feature := parent_kind << 8 | u32(nodes[node].kind)
		if scratch_counts[feature] == 0 {
			append(touched, feature)
		}
		scratch_counts[feature] += 1
	}
	slice.sort(touched[:])
	pairs = make([]Similarity_Feature, len(touched), allocator)
	kind_counts: [256]i32
	for feature, index in touched {
		pairs[index] = Similarity_Feature{feature = feature, count = scratch_counts[feature]}
		kind_counts[feature & 0xff] += scratch_counts[feature]
		scratch_counts[feature] = 0
	}
	kind_list := make([dynamic]Similarity_Feature, allocator)
	for count, kind in kind_counts {
		if count > 0 {
			append(&kind_list, Similarity_Feature{feature = u32(kind), count = count})
		}
	}
	return pairs, kind_list[:]
}

similarity_feature_distance :: proc(first, other: []Similarity_Feature) -> i64 {
	distance: i64 = 0
	left := 0
	right := 0
	for left < len(first) || right < len(other) {
		switch {
		case right >= len(other) || (left < len(first) && first[left].feature < other[right].feature):
			distance += i64(first[left].count)
			left += 1
		case left >= len(first) || other[right].feature < first[left].feature:
			distance += i64(other[right].count)
			right += 1
		case:
			distance += i64(abs(first[left].count - other[right].count))
			left += 1
			right += 1
		}
	}
	return distance
}

// The counts of the filter of the near pairs.
Similarity_Near_Filter_Counts :: struct {
	all_pairs:    i64, // Each pair of near pieces.
	prefix_pairs: i64, // The pairs that share a feature of their prefixes.
	kept_pairs:   i64, // The pairs that the sizes and the two vectors keep.
}

@(private = "file")
Similarity_Feature_Order :: struct {
	feature:   u32,
	frequency: i64,
}

// similarity_near_pairs gives each pair of near pieces whose score can
// reach the threshold. It never drops such a pair:
//  - the matched nodes of a pair have the same pair feature on both
//    sides, so the overlap of the pair features is at least the matched
//    nodes, which the threshold and the sizes bound from below; two
//    multisets with that overlap share a feature of their prefixes in a
//    fixed order of the features (prefix filtering);
//  - the score of sizes m <= n is at most 2m / (m + n);
//  - the L1 distance of each vector is at most the distance of the
//    anti-unification, so the score is at most 1 - L1 / (m + n).
similarity_near_pairs :: proc(nodes: []Similarity_Node, pieces: []Similarity_Piece, near: []i32, threshold: f64, allocator: mem.Allocator) -> (pairs: [][2]i32, counts: Similarity_Near_Filter_Counts) {
	scratch_counts := make([]i32, 1 << 16, allocator)
	touched := make([dynamic]u32, allocator)
	items := make([]Similarity_Near_Piece, len(near), allocator)
	frequency := make([]i64, 1 << 16, allocator)
	for piece, index in near {
		items[index].piece = piece
		items[index].size = pieces[piece].size
		items[index].pairs, items[index].kinds = similarity_near_features(nodes, pieces[piece], scratch_counts, &touched, allocator)
		for feature in items[index].pairs {
			frequency[feature.feature] += i64(feature.count)
		}
	}
	// The rank of each feature: the rarest first.
	order := make([dynamic]Similarity_Feature_Order, allocator)
	for value, feature in frequency {
		if value > 0 {
			append(&order, Similarity_Feature_Order{feature = u32(feature), frequency = value})
		}
	}
	slice.sort_by(order[:], proc(a, b: Similarity_Feature_Order) -> bool {
		return a.frequency < b.frequency || (a.frequency == b.frequency && a.feature < b.feature)
	})
	rank := make([]i32, 1 << 16, allocator)
	for item, index in order {
		rank[item.feature] = i32(index)
	}
	// The overlap that a pair above the threshold reaches is at least
	// share times the larger size, so each piece keeps the first
	// size - ceil(share * size) + 1 units of its features.
	share := threshold / (2 - threshold)
	for &item in items {
		sorted := make([]Similarity_Feature, len(item.pairs), allocator)
		copy(sorted, item.pairs)
		similarity_sort_features_by_rank(sorted, rank)
		needed := i32(f64(item.size) * share)
		if f64(needed) < f64(item.size) * share {
			needed += 1
		}
		units := item.size - needed + 1
		prefix := make([dynamic]u32, allocator)
		for feature in sorted {
			if units <= 0 {
				break
			}
			append(&prefix, feature.feature)
			units -= feature.count
		}
		item.prefix = prefix[:]
	}
	// The smaller pieces first: a candidate in the index is never larger.
	by_size := make([]i32, len(items), allocator)
	for index in 0 ..< len(by_size) {
		by_size[index] = i32(index)
	}
	similarity_sort_by_size(by_size, items)
	postings := make([][dynamic]i32, 1 << 16, allocator)
	stamp := make([]i32, len(items), allocator)
	for index in 0 ..< len(stamp) {
		stamp[index] = -1
	}
	found := make([dynamic][2]i32, allocator)
	for order_index in 0 ..< len(by_size) {
		current := by_size[order_index]
		item := items[current]
		least_size := threshold * f64(item.size) / (2 - threshold)
		for feature in item.prefix {
			for candidate in postings[feature] {
				if stamp[candidate] == current {
					continue
				}
				stamp[candidate] = current
				counts.prefix_pairs += 1
				other := items[candidate]
				if f64(other.size) < least_size {
					continue
				}
				total := f64(item.size + other.size)
				if 1 - f64(similarity_feature_distance(item.kinds, other.kinds)) / total < threshold || 1 - f64(similarity_feature_distance(item.pairs, other.pairs)) / total < threshold {
					continue
				}
				if similarity_pieces_overlap(nodes, pieces[item.piece], pieces[other.piece]) {
					continue
				}
				first := min(item.piece, other.piece)
				second := max(item.piece, other.piece)
				append(&found, [2]i32{first, second})
			}
		}
		for feature in item.prefix {
			if cap(postings[feature]) == 0 {
				postings[feature] = make([dynamic]i32, allocator)
			}
			append(&postings[feature], current)
		}
	}
	slice.sort_by(found[:], proc(a, b: [2]i32) -> bool {
		return a[0] < b[0] || (a[0] == b[0] && a[1] < b[1])
	})
	counts.all_pairs = i64(len(items)) * i64(len(items) - 1) / 2
	counts.kept_pairs = i64(len(found))
	return found[:], counts
}

@(private = "file")
Similarity_Ranked_Feature :: struct {
	rank:    i32,
	feature: Similarity_Feature,
}

@(private = "file")
similarity_sort_features_by_rank :: proc(features: []Similarity_Feature, rank: []i32) {
	ranked := make([]Similarity_Ranked_Feature, len(features), context.temp_allocator)
	for feature, index in features {
		ranked[index] = Similarity_Ranked_Feature{rank = rank[feature.feature], feature = feature}
	}
	slice.sort_by(ranked, proc(a, b: Similarity_Ranked_Feature) -> bool {
		return a.rank < b.rank
	})
	for item, index in ranked {
		features[index] = item.feature
	}
}

@(private = "file")
Similarity_Sized :: struct {
	size:  i32,
	index: i32,
}

@(private = "file")
similarity_sort_by_size :: proc(order: []i32, items: []Similarity_Near_Piece) {
	sized := make([]Similarity_Sized, len(order), context.temp_allocator)
	for index, position in order {
		sized[position] = Similarity_Sized{size = items[index].size, index = index}
	}
	slice.sort_by(sized, proc(a, b: Similarity_Sized) -> bool {
		return a.size < b.size || (a.size == b.size && a.index < b.index)
	})
	for item, position in sized {
		order[position] = item.index
	}
}

@(private = "file")
Similarity_Comparison_Work :: struct {
	nodes:  []Similarity_Node,
	pieces: []Similarity_Piece,
	pairs:  [][2]i32,
	scores: []f64,
	cheap:  []bool,
	next:   int, // The next pair to compare (atomic).
}

@(private = "file")
similarity_comparison_worker :: proc(data: rawptr) {
	work := (^Similarity_Comparison_Work)(data)
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return
	}
	defer virtual.arena_destroy(&arena)
	scratch := virtual.arena_allocator(&arena)
	for {
		place := sync.atomic_add(&work.next, 1)
		if place >= len(work.pairs) {
			return
		}
		pair := work.pairs[place]
		matched, cheap := similarity_upper_matched(work.nodes, work.pieces, pair[0], pair[1], scratch)
		work.scores[place] = similarity_score(matched, work.pieces[pair[0]].size, work.pieces[pair[1]].size)
		work.cheap[place] = cheap
		virtual.arena_free_all(&arena)
	}
}

// similarity_compare_pairs gives a score of each pair that is at least its
// similarity score, on several threads. Each place of the result is
// written by one thread, so the threads change no output.
similarity_compare_pairs :: proc(nodes: []Similarity_Node, pieces: []Similarity_Piece, pairs: [][2]i32, allocator: mem.Allocator) -> (scores: []f64, cheap: []bool) {
	scores = make([]f64, len(pairs), allocator)
	cheap = make([]bool, len(pairs), allocator)
	work := Similarity_Comparison_Work{nodes = nodes, pieces = pieces, pairs = pairs, scores = scores, cheap = cheap}
	thread_count := min(os.get_processor_core_count(), SIMILARITY_COMPARISON_THREADS_MOST, len(pairs))
	if thread_count <= 1 {
		similarity_comparison_worker(&work)
		return scores, cheap
	}
	workers := make([]^thread.Thread, thread_count, context.temp_allocator)
	for &worker in workers {
		worker = thread.create_and_start_with_data(&work, similarity_comparison_worker)
	}
	thread.join_multiple(..workers)
	for worker in workers {
		thread.destroy(worker)
	}
	return scores, cheap
}
