type: Fixed

**Collector audit space reload after a wide grant.** The root service now writes wide-grant requests past the principal identifier header in the collector shared region, preventing a startup race that corrupted the stored principal identifier on the first wide grant of a named principal.
