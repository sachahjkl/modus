type: Changed

**A name that names nothing gives an error record.** `manual.about`, `manual.signature`, `manual.problem` and `settings.get` with a name or a number that names nothing, `storage.stores` for a caller that does not act for a principal, and `next_prime` above 2^40 fail with an error record, where they gave an empty text, 0 or the text "no grant to see the stores". The console then writes the sentence, for example "error: manual.about: the argument name names none of the modules (-1)", and a caller tells an empty answer from a failure.
