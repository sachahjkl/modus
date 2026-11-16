title: A name that names nothing gives an error
date: 2026-11-16
release: next
picture: none
kind: Fixed
guide: docs/MODULE_CONTRACT.md

Some calls answered a name that names nothing with an empty text or 0. `manual.about("nothing")` gave an empty line, as for a module with no documentation. `settings.get("colour")` gave an empty text. `storage.stores()` gave the text "no grant to see the stores" to a caller with no grant. `next_prime` above 2^40 gave 0. Each of these calls now fails with an error record, and the console writes its sentence: "error: manual.about: the argument name names none of the modules (-1)". A program that calls them now tells an empty answer from a failure.
