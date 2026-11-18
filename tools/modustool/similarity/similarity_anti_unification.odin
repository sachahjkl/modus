package similarity

import "core:hash/xxhash"
import "core:mem"

// The anti-unification of two code pieces, their similarity score, and
// the factoring template of a family
// (src/md/infrastructure/similarity_finder.md, "6. The anti-unification
// and the similarity score").

// Above this product of the sizes of two code pieces, the alignment of
// their lists of children weighs a pair of children by its shape only:
// the same shape weighs its size, the same kind weighs 1. The weighted
// alignment keeps one weight for each pair of subtrees that it compares,
// so this product bounds its memory and its time for one pair.
SIMILARITY_WEIGHTED_ALIGNMENT_NODE_PRODUCT_MOST :: 1_000_000

// The kind of a blank: how the factored procedure takes it.
Similarity_Blank_Kind :: enum u8 {
	Value, // A parameter.
	Type, // A polymorphic parameter `$T`.
	Place, // A pointer parameter.
	Procedure, // A procedure parameter.
	Not_A_Parameter, // Odin cannot pass it.
}

similarity_blank_kind_name :: proc(kind: Similarity_Blank_Kind) -> string {
	switch kind {
	case .Value:
		return "value"
	case .Type:
		return "type"
	case .Place:
		return "place"
	case .Procedure:
		return "procedure"
	case .Not_A_Parameter:
		return "not a parameter"
	}
	return ""
}

// The cost of a blank in the ranking: one node for each parameter, two
// for a pointer or a procedure parameter.
similarity_blank_cost :: proc(kind: Similarity_Blank_Kind) -> i64 {
	switch kind {
	case .Value, .Type:
		return 1
	case .Place, .Procedure:
		return 2
	case .Not_A_Parameter:
		return 0
	}
	return 0
}

// The kind of a blank from the role of its node in the template.
similarity_blank_kind_of :: proc(node: Similarity_Node) -> Similarity_Blank_Kind {
	if similarity_kind_is_statement(node.kind) {
		return .Not_A_Parameter
	}
	switch node.role {
	case .Value:
		return .Value
	case .Type:
		return .Type
	case .Place:
		return .Place
	case .Called:
		return .Procedure
	case .Field, .Declared, .Label, .Statement, .Structure:
		return .Not_A_Parameter
	}
	return .Not_A_Parameter
}

// The partner of a node of the first code piece in the other: a matched
// node, or the other root of a blank.
Similarity_Partner :: struct {
	node:    i32,
	matched: bool,
}

// The anti-unification of two code pieces.
Similarity_Alignment :: struct {
	first:           i32, // The piece whose nodes the template keeps.
	other:           i32,
	matched:         i32, // The nodes of the template.
	partners:        map[i32]Similarity_Partner,
	unmatched_first: [dynamic]i32, // The children of the first piece that have no partner.
	unmatched_other: [dynamic]i32, // The children of the other piece that have no partner.
	cheap:           bool, // The lists were aligned by the shape of the children only.
}

// The state of one anti-unification. scratch holds the weights and the
// tables of the alignment; result holds the alignment that the caller keeps.
Similarity_Unifier :: struct {
	nodes:       []Similarity_Node,
	weights:     map[u64]i32,
	local_first: map[i32]i32, // The binding number of a local of the first piece, and the local of the other.
	local_other: map[i32]i32,
	cheap:       bool,
	alignment:   ^Similarity_Alignment,
	scratch:     mem.Allocator,
	result:      mem.Allocator,
}

similarity_unifier_make :: proc(nodes: []Similarity_Node, scratch, result: mem.Allocator) -> Similarity_Unifier {
	return Similarity_Unifier{nodes = nodes, weights = make(map[u64]i32, scratch), local_first = make(map[i32]i32, scratch), local_other = make(map[i32]i32, scratch), scratch = scratch, result = result}
}

// Two nodes match at their own level: the same kind, role and label, a
// local with a local, and the same count of children unless the children
// are a list.
similarity_shallow_match :: proc(nodes: []Similarity_Node, a, b: i32) -> bool {
	x := nodes[a]
	y := nodes[b]
	if x.kind != y.kind || x.role != y.role || x.literal != y.literal || (x.local >= 0) != (y.local >= 0) {
		return false
	}
	if x.local < 0 && x.label != y.label {
		return false
	}
	return similarity_kind_has_list(x.kind) || x.child_count == y.child_count
}

@(private = "file")
similarity_children :: proc(u: ^Similarity_Unifier, node: i32) -> []i32 {
	list := make([]i32, u.nodes[node].child_count, u.scratch)
	child := u.nodes[node].first_child
	for index in 0 ..< len(list) {
		list[index] = child
		child = u.nodes[child].next_sibling
	}
	return list
}

// similarity_weight gives the matched nodes of the best anti-unification
// of two subtrees, with the locals matched by kind only: the binding map
// can only lower it, so it bounds the score from above.
similarity_weight :: proc(u: ^Similarity_Unifier, a, b: i32) -> i32 {
	if !similarity_shallow_match(u.nodes, a, b) {
		return 0
	}
	x := u.nodes[a]
	y := u.nodes[b]
	if x.exact_hash == y.exact_hash && x.size == y.size {
		return x.size
	}
	key := u64(u32(a)) << 32 | u64(u32(b))
	if known, found := u.weights[key]; found {
		return known
	}
	total: i32 = 1
	if similarity_kind_has_list(x.kind) {
		total += similarity_align(u, similarity_children(u, a), similarity_children(u, b), nil)
	} else {
		left := x.first_child
		right := y.first_child
		for left >= 0 && right >= 0 {
			total += similarity_weight(u, left, right)
			left = u.nodes[left].next_sibling
			right = u.nodes[right].next_sibling
		}
	}
	u.weights[key] = total
	return total
}

@(private = "file")
similarity_pair_weight :: proc(u: ^Similarity_Unifier, a, b: i32) -> i32 {
	x := u.nodes[a]
	y := u.nodes[b]
	if x.kind != y.kind {
		return 0
	}
	if u.cheap {
		if x.shape_hash == y.shape_hash && x.size == y.size {
			return x.size
		}
		return 1
	}
	return similarity_weight(u, a, b)
}

// similarity_align aligns two lists of children by the longest common
// subsequence whose weight is the matched nodes of each aligned pair. It
// gives the weight, and the aligned pairs in order when pairs is not nil.
similarity_align :: proc(u: ^Similarity_Unifier, first, other: []i32, pairs: ^[dynamic][2]i32) -> i32 {
	rows := len(first) + 1
	columns := len(other) + 1
	table := make([]i32, rows * columns, u.scratch)
	for row in 1 ..< rows {
		for column in 1 ..< columns {
			best := max(table[(row - 1) * columns + column], table[row * columns + column - 1])
			if weight := similarity_pair_weight(u, first[row - 1], other[column - 1]); weight > 0 {
				best = max(best, table[(row - 1) * columns + column - 1] + weight)
			}
			table[row * columns + column] = best
		}
	}
	if pairs != nil {
		reversed := make([dynamic][2]i32, u.scratch)
		row := rows - 1
		column := columns - 1
		for row > 0 && column > 0 {
			here := table[row * columns + column]
			switch {
			case here == table[(row - 1) * columns + column]:
				row -= 1
			case here == table[row * columns + column - 1]:
				column -= 1
			case:
				append(&reversed, [2]i32{first[row - 1], other[column - 1]})
				row -= 1
				column -= 1
			}
		}
		for index := len(reversed) - 1; index >= 0; index -= 1 {
			append(pairs, reversed[index])
		}
	}
	return table[len(table) - 1]
}

// Two nodes match in the template: they match at their own level, and a
// local keeps the binding map one to one.
@(private = "file")
similarity_final_match :: proc(u: ^Similarity_Unifier, a, b: i32) -> bool {
	if !similarity_shallow_match(u.nodes, a, b) {
		return false
	}
	first_local := u.nodes[a].local
	other_local := u.nodes[b].local
	if first_local < 0 {
		return true
	}
	if mapped, found := u.local_first[first_local]; found && mapped != other_local {
		return false
	}
	if mapped, found := u.local_other[other_local]; found && mapped != first_local {
		return false
	}
	u.local_first[first_local] = other_local
	u.local_other[other_local] = first_local
	return true
}

@(private = "file")
similarity_build :: proc(u: ^Similarity_Unifier, a, b: i32) {
	if !similarity_final_match(u, a, b) {
		u.alignment.partners[a] = Similarity_Partner{node = b, matched = false}
		return
	}
	u.alignment.partners[a] = Similarity_Partner{node = b, matched = true}
	u.alignment.matched += 1
	if similarity_kind_has_list(u.nodes[a].kind) {
		similarity_build_lists(u, similarity_children(u, a), similarity_children(u, b))
		return
	}
	left := u.nodes[a].first_child
	right := u.nodes[b].first_child
	for left >= 0 && right >= 0 {
		similarity_build(u, left, right)
		left = u.nodes[left].next_sibling
		right = u.nodes[right].next_sibling
	}
}

@(private = "file")
similarity_build_lists :: proc(u: ^Similarity_Unifier, first, other: []i32) {
	if len(first) == len(other) && !similarity_kind_has_list_of_roots(u, first, other) {
		for index in 0 ..< len(first) {
			similarity_build(u, first[index], other[index])
		}
		return
	}
	pairs := make([dynamic][2]i32, u.scratch)
	similarity_align(u, first, other, &pairs)
	first_index := 0
	other_index := 0
	for pair in pairs {
		for first[first_index] != pair[0] {
			append(&u.alignment.unmatched_first, first[first_index])
			first_index += 1
		}
		for other[other_index] != pair[1] {
			append(&u.alignment.unmatched_other, other[other_index])
			other_index += 1
		}
		similarity_build(u, pair[0], pair[1])
		first_index += 1
		other_index += 1
	}
	for ; first_index < len(first); first_index += 1 {
		append(&u.alignment.unmatched_first, first[first_index])
	}
	for ; other_index < len(other); other_index += 1 {
		append(&u.alignment.unmatched_other, other[other_index])
	}
}

// Two lists of equal length are compared place by place, unless a place
// holds two nodes of different kinds: the alignment then finds the
// statement that only one side has.
@(private = "file")
similarity_kind_has_list_of_roots :: proc(u: ^Similarity_Unifier, first, other: []i32) -> bool {
	for index in 0 ..< len(first) {
		if u.nodes[first[index]].kind != u.nodes[other[index]].kind {
			return true
		}
	}
	return false
}

// The roots of a code piece: one node, or the statements of a run.
similarity_piece_roots :: proc(nodes: []Similarity_Node, piece: Similarity_Piece, allocator: mem.Allocator) -> []i32 {
	roots := make([]i32, piece.root_count, allocator)
	node := piece.first
	for index in 0 ..< len(roots) {
		roots[index] = node
		node = nodes[node].next_sibling
	}
	return roots
}

similarity_alignment_cheap :: proc(first, other: Similarity_Piece) -> bool {
	return i64(first.size) * i64(other.size) > SIMILARITY_WEIGHTED_ALIGNMENT_NODE_PRODUCT_MOST
}

// similarity_unify gives the anti-unification of two code pieces. The
// scratch memory can be freed after the call.
similarity_unify :: proc(nodes: []Similarity_Node, pieces: []Similarity_Piece, first, other: i32, scratch, result: mem.Allocator) -> ^Similarity_Alignment {
	u := similarity_unifier_make(nodes, scratch, result)
	u.cheap = similarity_alignment_cheap(pieces[first], pieces[other])
	alignment := new(Similarity_Alignment, result)
	alignment^ = Similarity_Alignment{first = first, other = other, partners = make(map[i32]Similarity_Partner, result), unmatched_first = make([dynamic]i32, result), unmatched_other = make([dynamic]i32, result), cheap = u.cheap}
	u.alignment = alignment
	first_roots := similarity_piece_roots(nodes, pieces[first], scratch)
	other_roots := similarity_piece_roots(nodes, pieces[other], scratch)
	if len(first_roots) == 1 && len(other_roots) == 1 {
		similarity_build(&u, first_roots[0], other_roots[0])
	} else {
		similarity_build_lists(&u, first_roots, other_roots)
	}
	return alignment
}

// similarity_upper_matched gives a count of matched nodes that is at least
// the count of the anti-unification, with no binding map and no result:
// the comparison of the candidate pairs uses it. A cheap pair is unified
// whole, because its weights are no bound.
similarity_upper_matched :: proc(nodes: []Similarity_Node, pieces: []Similarity_Piece, first, other: i32, scratch: mem.Allocator) -> (matched: i32, cheap: bool) {
	if similarity_alignment_cheap(pieces[first], pieces[other]) {
		alignment := similarity_unify(nodes, pieces, first, other, scratch, scratch)
		return alignment.matched, true
	}
	u := similarity_unifier_make(nodes, scratch, scratch)
	first_roots := similarity_piece_roots(nodes, pieces[first], scratch)
	other_roots := similarity_piece_roots(nodes, pieces[other], scratch)
	if len(first_roots) == 1 && len(other_roots) == 1 {
		return similarity_weight(&u, first_roots[0], other_roots[0]), false
	}
	return similarity_align(&u, first_roots, other_roots, nil), false
}

// The similarity score: two times the matched nodes over the sum of the
// sizes.
similarity_score :: proc(matched, first_size, other_size: i32) -> f64 {
	if first_size + other_size == 0 {
		return 0
	}
	return 2 * f64(matched) / f64(first_size + other_size)
}

// One blank of a factoring template: its place in the first member, and
// the argument of each member there. A gap is a place that some members
// do not have.
Similarity_Blank :: struct {
	number:    i32, // ?1, ?2...: the same arguments at two places give one number. 0 for a gap.
	kind:      Similarity_Blank_Kind,
	place:     i32, // The node of the first member.
	arguments: []i32, // The node of each member, or -1 where the member does not have it.
	gap:       bool,
}

// The factoring template of a family, in the nodes of its first member.
Similarity_Template :: struct {
	members:         []i32, // The pieces; the first one is the first member.
	matched:         i32, // The nodes of the template.
	in_template:     []bool, // For each node of the first member, by its offset from the start of the member.
	blanks:          [dynamic]Similarity_Blank,
	parameter_count: i32, // The distinct numbers of the blanks.
	parameter_cost:  i64,
	gaps:            i32, // The places of the first member that some members do not have.
	only_in_members: []i32, // For each member, the children that only it has, against the first member.
	scores:          []f64, // The score of each member with the first member.
	coverages:       []f64, // The share of each member that the template covers.
	cheap:           bool,
}

// similarity_template computes the factoring template of a family from the
// anti-unification of its first member with each other member: a node of
// the first member is in the template when it matched in each of them.
similarity_template :: proc(nodes: []Similarity_Node, pieces: []Similarity_Piece, members: []i32, alignments: []^Similarity_Alignment, allocator, scratch: mem.Allocator) -> Similarity_Template {
	template := Similarity_Template {
		members         = members,
		blanks          = make([dynamic]Similarity_Blank, allocator),
		only_in_members = make([]i32, len(members), allocator),
		scores          = make([]f64, len(members), allocator),
		coverages       = make([]f64, len(members), allocator),
	}
	first := pieces[members[0]]
	low := first.first
	high := first.last + nodes[first.last].size
	counts := make([]i32, high - low, scratch)
	for alignment in alignments {
		template.cheap = template.cheap || alignment.cheap
		for node, partner in alignment.partners {
			if partner.matched {
				counts[node - low] += 1
			}
		}
	}
	template.in_template = make([]bool, high - low, allocator)
	needed := i32(len(alignments))
	for index in 0 ..< len(counts) {
		if counts[index] == needed {
			template.in_template[index] = true
			template.matched += 1
		}
	}
	numbers := make(map[u64]i32, scratch)
	key_bytes := make([dynamic]u8, scratch)
	for node := low; node < high; node += 1 {
		if template.in_template[node - low] {
			continue
		}
		parent := nodes[node].parent
		is_root := parent < low || parent >= high || node == first.first
		if !is_root && !template.in_template[parent - low] {
			continue
		}
		blank := Similarity_Blank{kind = similarity_blank_kind_of(nodes[node]), place = node, arguments = make([]i32, len(members), allocator)}
		blank.arguments[0] = node
		clear(&key_bytes)
		similarity_key_write(&key_bytes, nodes[node].exact_hash)
		for alignment, index in alignments {
			if partner, found := alignment.partners[node]; found {
				blank.arguments[index + 1] = partner.node
				similarity_key_write(&key_bytes, nodes[partner.node].exact_hash)
			} else {
				blank.arguments[index + 1] = -1
				blank.gap = true
			}
		}
		if blank.gap {
			template.gaps += 1
		} else {
			key := xxhash.XXH3_64_default(key_bytes[:])
			if number, found := numbers[key]; found {
				blank.number = number
			} else {
				template.parameter_count += 1
				blank.number = template.parameter_count
				numbers[key] = blank.number
				template.parameter_cost += similarity_blank_cost(blank.kind)
			}
		}
		append(&template.blanks, blank)
		node += nodes[node].size - 1
	}
	template.scores[0] = 1
	template.coverages[0] = f64(template.matched) / f64(max(first.size, 1))
	for alignment, index in alignments {
		member := pieces[members[index + 1]]
		template.only_in_members[index + 1] = i32(len(alignment.unmatched_other))
		template.scores[index + 1] = similarity_score(alignment.matched, first.size, member.size)
		template.coverages[index + 1] = f64(template.matched) / f64(max(member.size, 1))
	}
	return template
}

@(private = "file")
similarity_key_write :: proc(bytes: ^[dynamic]u8, value: u64) {
	parts := transmute([8]u8)value
	append(bytes, ..parts[:])
}

// A blank that is a parameter: a template whose blanks are all
// parameters, with no gap and no child that only some members have,
// is one procedure.
similarity_template_is_one_procedure :: proc(template: Similarity_Template) -> bool {
	if template.gaps > 0 {
		return false
	}
	for count in template.only_in_members {
		if count > 0 {
			return false
		}
	}
	for blank in template.blanks {
		if blank.kind == .Not_A_Parameter {
			return false
		}
	}
	return true
}

// similarity_template_hash names a template: its nodes, the locals by the
// order of their first use, and its blanks by number and kind. A move of
// a file, a rename of a local and a change of an argument keep it.
similarity_template_hash :: proc(nodes: []Similarity_Node, pieces: []Similarity_Piece, template: Similarity_Template) -> u64 {
	first := pieces[template.members[0]]
	low := first.first
	high := first.last + nodes[first.last].size
	bytes := make([dynamic]u8, context.temp_allocator)
	locals := make(map[i32]i32, context.temp_allocator)
	blank_at := make(map[i32]Similarity_Blank, context.temp_allocator)
	for blank in template.blanks {
		blank_at[blank.place] = blank
	}
	for node := low; node < high; node += 1 {
		if blank, is_blank := blank_at[node]; is_blank {
			append(&bytes, '?', u8(blank.kind), blank.gap ? 1 : 0)
			similarity_key_write(&bytes, u64(blank.number))
			node += nodes[node].size - 1
			continue
		}
		if !template.in_template[node - low] {
			continue
		}
		item := nodes[node]
		append(&bytes, u8(item.kind), u8(item.role), u8(item.literal))
		if item.local >= 0 {
			order, found := locals[item.local]
			if !found {
				order = i32(len(locals))
				locals[item.local] = order
			}
			similarity_key_write(&bytes, u64(order))
		} else {
			append(&bytes, item.label)
		}
		append(&bytes, 0)
	}
	return xxhash.XXH3_64_default(bytes[:])
}
