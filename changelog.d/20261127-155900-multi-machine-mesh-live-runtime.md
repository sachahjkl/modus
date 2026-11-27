type: Added

**Live runtime wiring for multi-machine mesh, remote roles, and store sync.** Wired `machine_mesh`, `machine_sync`, `machine_wire`, and `paired_dispatch` into `remote` and `network` with principal-0 authorized mesh exports, non-blocking remote role dispatch with wide-grant auditing and handle-bearing role refusal, directional CPace-derived ChaCha20-Poly1305 NAT relay sealing, and the two-machine QEMU `mesh` test part.
