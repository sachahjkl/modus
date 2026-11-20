title: An export takes a member of an enum
date: 2026-11-20
release: next
picture: none
kind: Shown
guide: docs/MODULE_CONTRACT.md

An export of a module can now take a value of a closed set: an enum, whose members the module file names.

The console completes the members after a dot and refuses a name that the enum does not have, before the call: `settings.set(keyboard_layout = .french)`.

The palette reads the same description. It shows one row of buttons for each such parameter, and marks the member in use, which it asks of the getter that the parameter names.

The settings are the first user: one optional argument for each setting, and one getter for each, `settings.font()`.
