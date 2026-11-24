// store_explorer as a Lex project (src/md/features/store_explorer.md): an
// outside module whose source is this folder tree, built by the host builder
// and distributed through the signed object cache.
project {
  source = here(),
  outputs = {
    default = recipe(catalog.modules.host, {
      source = here(),
      target = "store_explorer",
    }),
    source = here(),
  },
}
