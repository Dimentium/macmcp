# typed: strict
# frozen_string_literal: true

cask "macmcp" do
  version "0.2.17"
  sha256 "e25d3178090b8647d288e4f54d085cb97f6f5678788075f7b38be393cdf7324d"

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
