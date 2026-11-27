type: Fixed

**Assistant startup race on the storage ring.** The assistant now finishes mapping startup fonts through `display.open` before launching its storage worker thread, preventing a startup deadlock on the shared storage connection.
