#+build !freestanding
#+build !modus
package role_contract

import "core:testing"

@(test)
display_and_powerbox_conformance_suite :: proc(t: ^testing.T) {
	contracts := [2]Role_Contract{
		display_contract(),
		powerbox_contract(),
	}
	hashes: [2]Contract_Hash
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
	bad := display_contract()
	bad.role = .None
	_, bad_ok := contract_hash(bad)
	testing.expect(t, !bad_ok)
}
