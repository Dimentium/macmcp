# typed: strict
# frozen_string_literal: true

cask "macmcp" do
  version "0.2.33"
  sha256 "f61f79e0e2e37a8309518f6ed51e4af2e11c8a6a06b892e0f2e848d4febd0a22"

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
