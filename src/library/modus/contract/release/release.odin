// The release number of the system (docs/glossary/project.md, "Release number"):
// the newest release of CHANGELOG.md. The merge of step N on master is the
// release 0.N.0; a correction between two steps is 0.N.1, 0.N.2.
//
// `modustool changelog release <number>`, which `modustool ship` runs,
// writes the line below; nothing else changes it. `modustool changelog
// check` fails when it is not the newest release of CHANGELOG.md.
package release

RELEASE_NUMBER :: "0.114.0"
