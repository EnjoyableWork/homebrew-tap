# homebrew-tap

Homebrew tap for EnjoyableWork software

## mcp-doctor project and community

This repository is the supporting Homebrew distribution codebase for
[`mcp-doctor`](https://github.com/EnjoyableWork/mcp-doctor). The source
repository owns the project policies and public discussion. For an
`mcp-doctor` formula or product change, use its:

- [contribution process](https://github.com/EnjoyableWork/mcp-doctor/blob/main/CONTRIBUTING.md),
  including the same inbound and outbound MIT terms;
- [bug and feature forms](https://github.com/EnjoyableWork/mcp-doctor/issues/new/choose);
- [support guidance](https://github.com/EnjoyableWork/mcp-doctor/blob/main/SUPPORT.md);
- [code of conduct](https://github.com/EnjoyableWork/mcp-doctor/blob/main/CODE_OF_CONDUCT.md);
  and
- [private vulnerability-reporting process](https://github.com/EnjoyableWork/mcp-doctor/security/advisories/new).

The tap source is licensed under this repository's [MIT License](LICENSE).
The `mcp-doctor` formula declares that same license, and each upstream source
package and native archive includes the exact project license.

## mcp-doctor releases

`mcp-doctor` formula updates are owned by the tap's
`Publish verified mcp-doctor formula` workflow. It accepts an exact stable
version, independently verifies the annotated and immutable upstream GitHub
Release, provenance, checksums, Cargo package hash, and formula bytes, then
copies only `Formula/mcp-doctor.rb`.

Use `rehearse` mode with `0.1.0` to exercise every read-only and negative check
without changing the tap. Use `publish` only for a newer immutable version
after the upstream Cargo handoff succeeds. The environment-gated write job uses
this repository's short-lived `GITHUB_TOKEN`; no cross-repository personal
access token is accepted or stored.
