title: A lock ends each window of unlock
date: 2026-11-16
release: next
picture: none
kind: Fixed
guide: docs/PRINCIPALS.md

A console of a session can open the window of `unlock` to set the machine passphrase or to seal the machine key. The window shows a recovery key one time. Before, the window stayed open after `lock()`: anyone at the locked machine could read that recovery key, or type a machine passphrase.

Now the lock stops the window of `unlock`, whatever it shows. The window writes its record only after Enter, when the recovery key is written down. So the stop loses nothing: the disk stays as it was, and the owner asks again. The creation of a principal follows the same rule: its file is written, and its session starts, after Enter on its recovery key.
