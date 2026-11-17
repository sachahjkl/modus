type: Fixed

**A call answer with a status that names no status is refused**: `remote.answer_check` accepted an answer of the remote service whose status word named no member of `remote.Status`, and the host then held a status that the service did not name. The host now refuses such an answer as it refuses an answer whose bytes are not its header and its total.
