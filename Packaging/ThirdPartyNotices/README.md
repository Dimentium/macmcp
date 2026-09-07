# Third-Party Notices

This directory is copied unchanged into every distributed `MacMCP.app` under
`Contents/Resources/ThirdPartyNotices`.

- `MacMCP-LICENSE` is MacMCP's MIT license.
- `mail-mcp-LICENSE` and `che-ical-mcp-LICENSE` are the MIT licenses for the
  embedded sidecars at the revisions in `UPSTREAMS.lock.json`.
- `swift/` contains the license texts for every dependency resolved by the
  bridge's `Package.resolved`. The MCP Swift SDK has a documented MIT to
  Apache-2.0 licensing transition, so its upstream license text is preserved
  verbatim.
- `go/` contains the license and NOTICE files emitted by
  `go-licenses v1.6.0 save ./...` for the pinned `mail-mcp` source at
  `e26b28ef87e6eab46d796d63ec1bbaa210d080d4`.

Regenerate the Go notices whenever the pinned mail sidecar revision or its Go
module graph changes. Preserve all upstream texts when updating this directory.
