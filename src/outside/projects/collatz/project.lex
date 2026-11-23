// collatz as a project (src/md/features/application_projects.md): its source
// is the tree of this folder, and its module is the C module of collatz.c,
// built by the C builder of the catalog of the system.
project {
  source = here(),
  outputs = {
    default = catalog.c.module("collatz.c"),
  },
}
