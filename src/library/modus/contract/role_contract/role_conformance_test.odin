#+build !freestanding
package role_contract

import "core:testing"

@(test)
display_powerbox_plans_recipes_projects_conformance_suite :: proc(t: ^testing.T) {
	contracts := [5]Role_Contract{
		display_contract(),
		powerbox_contract(),
		plans_contract(),
		recipes_contract(),
		projects_contract(),
	}
	hashes: [5]Contract_Hash
	for c, i in contracts {
		h, ok := contract_hash(c)
		testing.expect(t, ok)
		testing.expect(t, h != Contract_Hash{})
		// Re-hashing is bit-for-bit deterministic.
		h2, ok2 := contract_hash(c)
		testing.expect(t, ok2 && h == h2)
		hashes[i] = h
		// Every role contract has a globally distinct hash.
		for j in 0 ..< i {
			testing.expect(t, hashes[i] != hashes[j])
		}
	}

	// Adversarial check: tampered role .None refused.
	bad := plans_contract()
	bad.role = .None
	_, bad_ok := contract_hash(bad)
	testing.expect(t, !bad_ok)
}
