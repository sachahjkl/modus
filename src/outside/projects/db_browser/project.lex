// db_browser: sandboxed SQLite GUI application for modus.
// Every build input is named by content hash; zero ambient disk or network access.
let
  default_build = {
    source = here(),
    target = "db_browser",
    heap   = 2 MiB,
  },
  release_build = default_build with { heap = 4 MiB },
in
  project {
    source = here(),
    inputs = {
      modus = catalog,
    },
    outputs = {
      default = recipe(catalog.modules.host, release_build),
      source  = here(),
    },
    console = {
      modules = [catalog.modules.host],
      stores  = [store("db_browser", .read, .write)],
    },
  }
