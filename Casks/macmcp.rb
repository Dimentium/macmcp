# typed: strict
# frozen_string_literal: true

cask "macmcp" do
  version "0.2.15"
  sha256 "e1c30de744063f4147f7595c48c4a33925133551a522d74de4c4765a9113b71d"

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
