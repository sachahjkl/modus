type: Added

**Reclaiming orphaned encrypted store blocks after principal removal.** After deliberate principal removal erases a principal's keys and deletes its principal file, the storage service scrubs the removed principal's store cells and frees all unreachable encrypted blocks and store table cells in bounded, crash-resumable commits so repeated principal creation and removal leaks no disk capacity.
