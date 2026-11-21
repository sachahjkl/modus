type: Added

**Supervision contracts, restart window, and client call retry rules**: added the `supervision` contract package with explicit-value enums and transport borders, the fixed-layout `Connection_Page` with atomic seqlock transitions across holder restarts, the `Request_Serial_Log` deduplication table for at-most-once execution, and the single-retry `Client_Call_Tracker` state machine; added the pure `Supervision_Tree` with restart strategies, optional sliding restart window, dependency cycle refusal, and bounded escalation to `start_policy_rules`, with host tests.
