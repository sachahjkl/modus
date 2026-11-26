// The SPDX identifiers of the licenses that the records of a boot image
// and the reuse list name: the release reads the license of each record
// that it publishes (docs/TOOLS.md, "The reuse list").
package build

import "core:strings"

// The SPDX value of a work with no license.
REUSE_LICENSE_NONE :: "NONE"

// The words of a record that grants no license at all.
REUSE_NO_LICENSE_WORDS :: "All rights reserved"

// reuse_spdx_of_record_words gives the SPDX identifier that the words of a
// record name, or "" when the words name none that the site translates.
reuse_spdx_of_record_words :: proc(words: string) -> string {
	for pair in spdx_names {
		if strings.has_prefix(words, pair[0]) {
			return pair[1]
		}
	}
	if strings.has_prefix(words, REUSE_NO_LICENSE_WORDS) {
		return REUSE_LICENSE_NONE
	}
	return ""
}

// The license words that a file of the repository writes, and the SPDX
// identifier that each one names. This is a translation of recorded words,
// not a recorded fact: a phrase that is not here is shown as the file
// writes it.
@(rodata)
spdx_names := [?][2]string {
	{"SIL OFL 1.1", "OFL-1.1"},
	{"Bitstream Vera license", "Bitstream-Vera"},
	{"MIT License", "MIT"},
	{"MIT", "MIT"},
	{"CC-BY-NC-4.0", "CC-BY-NC-4.0"},
	{"BSD-1-Clause", "BSD-1-Clause"},
	{"zlib", "Zlib"},
	{"CC BY-SA 4.0", "CC-BY-SA-4.0"},
	{"CC BY 4.0", "CC-BY-4.0"},
	{"CC BY 3.0", "CC-BY-3.0"},
	{"CC0", "CC0-1.0"},
	{"GNU GENERAL PUBLIC LICENSE", "GPL-2.0-or-later"},
}
