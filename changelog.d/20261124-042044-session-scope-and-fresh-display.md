type: Changed

**Session-scoped services, display isolation at lock, and closed joint-process check.** Every start grant set declares explicit `.Session` or `.Machine` scope checked against a closed 15-process joint list, session services launch per principal with encrypted stores, and locking a session isolates display state by restarting the display holder (or resetting clipboard, notifications, palette recents, and menus when a machine window stays open).
