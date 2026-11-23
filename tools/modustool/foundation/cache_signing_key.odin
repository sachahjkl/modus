package foundation

// The files of the cache signing key: its seed in a key folder, its public
// key in the repository, each 64 hexadecimal digits, the form that
// cache-serve reads. The key commands of the package build and the client of
// the package cache_server both name them, and neither imports the other
// (src/md/infrastructure/cache_publication.md).
CACHE_SIGNING_KEY_FILE_NAME :: "cache_signing_key"
CACHE_SIGNING_KEY_PUBLIC_SUFFIX :: ".public"
CACHE_SIGNING_KEY_PUBLIC_FILE :: RESOURCE_FOLDER + "/keys/" + CACHE_SIGNING_KEY_FILE_NAME + CACHE_SIGNING_KEY_PUBLIC_SUFFIX
