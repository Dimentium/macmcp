# typed: strict
# frozen_string_literal: true

cask "macmcp" do
  version "0.2.7"
  sha256 "137dc27fa9dcbbd17a8c884cb748852d771d6b8dc19e14b554fe85615bb08fb4"

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
  ]
end
