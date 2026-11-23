type: Added

**A closed audit space ends after its retention.** An audit space that closed when its module changed the size of its record is kept 90 days from its close, then removed, and its place in the collector is free. A reader of a removed space gets the refusal `Space_Removed`, with the kind `Absent`, not a part of the audit; a removal that stops goes on at the next pass, also after a restart.
