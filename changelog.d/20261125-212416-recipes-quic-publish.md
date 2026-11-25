type: Added

**In-modus QUIC cache publishing**: `recipes` exports `publisher_key`, `configure_publisher`, and `publish` (wired in the console as `recipes.publisher_key`, `recipes.configure_publisher`, and `recipes.publish`) to keep a per-principal Ed25519 publisher seed inside `recipes`, stream verified output closures bottom-up over QUIC UDP:5010, and publish signed realisations without exposing private key material.
