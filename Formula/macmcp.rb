class Macmcp < Formula
  desc "Local macOS MCP bridge for mail, Calendar, and Reminders"
  homepage "https://github.com/Dimentium/macmcp"
  url "https://github.com/Dimentium/macmcp.git", tag: "v0.1.5", revision: "1bd50766b9740fce6c41dcb733337a08dd6d0de8"
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
