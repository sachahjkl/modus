// db_browser as a Lex project (src/md/features/db_browser.md): an outside
// module whose source is this folder tree, built by the host builder and
// distributed through the signed object cache.
project {
  source = here(),
  outputs = {
    default = recipe(catalog.modules.host, {
      source = here(),
      target = "db_browser",
    }),
    source = here(),
  },
}
