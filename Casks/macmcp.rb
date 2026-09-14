# typed: strict
# frozen_string_literal: true

cask "macmcp" do
  version "0.2.29"
  sha256 "93d417a648995890d3487df3ed59e1bf8cd67816426e71d7c0d1edd580e7721d"

  url "https://github.com/Dimentium/macmcp/releases/download/v#{version}/MacMCP-#{version}-macos.zip"
  name "MacMCP"
  desc "Local MCP bridge for mail, Calendar, and Reminders"
  homepage "https://github.com/Dimentium/macmcp"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "MacMCP.app"
  binary "#{appdir}/MacMCP.app/Contents/Resources/macmcp"

  zap trash: [
    "~/Library/Application Support/macmcp",
    "~/Library/Caches/macmcp",
    "~/Library/Logs/MacMCP",
  ]
end
