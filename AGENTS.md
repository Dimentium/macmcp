# Agent Notes

## Continuity

Read [docs/HANDOFF.md](docs/HANDOFF.md) first for the current architecture,
verified state, open work, and operational constraints. Keep it aligned with
`docs/PLAN.md`, `docs/KNOWN_ISSUES.md`, and `docs/RELEASING.md`; do not create a
second competing handoff document.

## Release MacMCP

For a normal release, use `scripts/release.sh`. Do not publish a signed app or
update the Cask manually unless diagnosing a failed release step.

Before running it:

1. Bump the source version in `AppVersion.swift`, both bundle plists, and the
   matching packaging test.
2. Update and test any pinned sidecar revisions, then run `swift test`.
3. Commit the intended source changes and confirm the worktree is clean.

Run on the release Mac:

```sh
scripts/release.sh \
  --signing-identity "Developer ID Application: Your Name (TEAMID)" \
  --install-local
```

The script runs tests, builds, signs, notarizes, tags, publishes the GitHub
release, regenerates the Cask and source formula, upgrades the local Cask, and
restarts MacMCP. Review the private `dist/release-*.log` and final
`macmcp diagnose --json`; verify one app process, one tunnel client, and one
tunnel proxy before reporting success.
