# typed: strict
# frozen_string_literal: true

cask "macmcp" do
  version "0.2.32"
  sha256 "ec66d9b2c15fd9224007506adf521eaba65f02b4e39e8b3ec96b6932445d4217"

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
