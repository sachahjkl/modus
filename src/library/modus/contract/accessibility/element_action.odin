// The check of an action that an assistive holder asks on an element
// (src/md/features/accessibility.md, "2. The assistive role"). The window
// layer runs it on the tree of its last frame before it puts the key of the
// action in the input of the next frame, so a holder acts only by an action
// that the element declared. The check is here, in the contract, so that
// the window layer, the compositor and each holder refuse the same requests.
package accessibility

// Why an action is refused. Value 0 names no refusal.
Element_Action_Refusal :: enum u8 {
	None                = 0,
	Action_Unknown      = 1, // The word names no Element_Action.
	Element_Absent      = 2, // The element word is 0, or names no element of the last frame.
	Action_Not_Declared = 3, // The element did not declare the action in its last frame.
	Protected_Text      = 4, // Insert_Text on a protected field: a passphrase is typed on the keyboard only.
}

// element_action_authorize_node checks an action word against one node of
// the last tree. The word becomes its Element_Action here, at the border.
element_action_authorize_node :: proc "contextless" (node: ^Semantic_Node, action_word: u8) -> (action: Element_Action, refusal: Element_Action_Refusal) {
	member, known := element_action_of_word(action_word)
	if !known {
		return {}, .Action_Unknown
	}
	if node == nil || node.element == 0 {
		return {}, .Element_Absent
	}
	// A node built by hand can still carry Insert_Text with Protected: the
	// state wins over the declaration.
	if member == .Insert_Text && .Protected in node.states {
		return {}, .Protected_Text
	}
	if member not_in node.actions {
		return {}, .Action_Not_Declared
	}
	return member, .None
}

// element_action_authorize finds the element by its word in the last tree
// and checks the action on it. node_index is -1 on each refusal.
element_action_authorize :: proc "contextless" (tree: ^Semantic_Tree, element: u32, action_word: u8) -> (action: Element_Action, node_index: i32, refusal: Element_Action_Refusal) {
	if _, known := element_action_of_word(action_word); !known {
		return {}, -1, .Action_Unknown
	}
	if tree == nil {
		return {}, -1, .Element_Absent
	}
	index := semantic_tree_find_by_element(tree, element)
	if index < 0 {
		return {}, -1, .Element_Absent
	}
	member, node_refusal := element_action_authorize_node(&tree.nodes[index], action_word)
	if node_refusal != .None {
		return {}, -1, node_refusal
	}
	return member, index, .None
}
