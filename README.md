# homebrew-tap

Homebrew tap for EnjoyableWork software

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
