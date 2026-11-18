# The grant word of an endpoint

The grant of a network endpoint (`datagram.Grant`) crosses two borders as one `u64`: the command `Endpoint_Add` or `Endpoint_Grant` of the control ring, from the root service to the network service, and the completion of `Info`, from the network service to the process. The rules of the grant are in [`docs/NETWORK.md`](../../../docs/NETWORK.md), "The grant of a segment endpoint".

## Constraints

- A network grant is an authority: who a process may reach, and on which port it may answer.
- A word of transport becomes its record at one place only, and that place refuses a value that names no member.
- The decision of the network service is tested on the host. The service is a module with an entry, and such a module is not built for a host test.

## The chosen form

- The word: the port in bits 0 to 15, the address in bits 16 to 47, the flags `inspect`, `tcp` and `listen` in bits 48 to 50. `GRANT_KNOWN_BIT_COUNT` (51) bits are known.
- `datagram.grant_unpack` is the one border. A word with a bit from 51 to 63 gives the zero grant and `false`. The zero grant names no remote, so a caller that forgets the flag still gets no right.
- The decisions of the service on the word are pure procedures of `src/library/support/network` (`endpoint_grants.odin`): `endpoint_add_grant` and `endpoint_grant_change`. Each gives the completion record of its refusal. `endpoint_grant_change` writes the grant of the endpoint only when it takes the word. The service acts on the result only, so the host test of these procedures is the test of the refusal of the service: its status, its record, and that the grant did not change.
- On a refused `Endpoint_Add` the service maps no region and opens no ring: no work runs on a word that it refuses.
- The value of the record is the unknown bits shifted down by `GRANT_KNOWN_BIT_COUNT`. It is positive for each word, also with bit 63, and says which bits were wrong.

## Refused forms

- **Ignore the unknown bits.** A word with a new flag then became a grant with fewer rights than its writer meant, in silence.
- **Mask the word before the read.** The same loss, with one more step.
- **The whole word, cast to `i64`, as the value of the record.** A word with bit 63 gave a negative value, which reads as a number that the word never held.
- **The decision inside the process.** No host test could give it a refused word and check that nothing changed.

## State

Built: the border, its refusal in the service, the host tests of `datagram` and of `src/library/support/network`. Left: no machine test sends a refused word through the control ring; the root service writes no such word.
