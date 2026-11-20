type: Fixed

**The prepared modules give their handles back**: a start or a wiring no longer fails because the root service holds the shared code of up to 64 modules for later starts. Before each start and each wiring, the root service closes the prepared modules used least recently until the work has room; a closed module is prepared again at its next start. The line of the tables of the root service also says how many of its handles are prepared modules.
