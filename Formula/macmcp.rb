class Macmcp < Formula
  desc "Local macOS MCP bridge for mail, Calendar, and Reminders"
  homepage "https://github.com/Dimentium/macmcp"
  url "https://github.com/Dimentium/macmcp.git", tag: "v0.2.0", revision: "cf24c5d21c03e5f44ca2db07e2922f3106d6ecdc"
  license "MIT"

  def install
    odie "MacMCP requires macOS" unless OS.mac?

    libexec.install Dir["*"]
    bin.write_exec_script libexec/"scripts/macmcp"
  end

  def caveats
    <<~EOS
      MacMCP is installed but not configured yet.
      Run `macmcp setup` to install the app and complete first-run setup.
    EOS
  end

  test do
    system bin/"macmcp", "help"
  end
end
