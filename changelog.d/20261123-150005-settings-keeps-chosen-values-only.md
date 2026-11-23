type: Changed

**The settings keep only what the principal chose.** The store of `settings` holds a name and a word for each value that the principal changed, so a default that the principal never touched follows a later release. A word that a setting refuses holds as no choice and stays in the record, and a record that this release cannot read is no longer written over at boot. `reset` makes one choice absent again, and `settings_state` gives the layer of each value.
