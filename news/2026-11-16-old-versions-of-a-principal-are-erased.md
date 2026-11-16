title: The old file of a principal is erased after a change
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/STORAGE.md

Before, a change of the passphrase or of the recovery key of a named principal left the file from before as a version on the disk. That version opened with the old secret.

Now `unlock` asks the storage service to erase the versions of the file after each change. The service ends the versions in one commit, writes its root a second time, and then writes zeros over each block that no other state names. A loss of power at any write leaves the versions or none, and no root names a block of zeros.

In the test, the tool reads the file of the principal from the disk before a change. After the change, the disk holds none of its salt and none of its sealed keys.

The erase reaches the blocks that the storage service reads. A flash disk or a snapshot of the host can still keep an old copy.
