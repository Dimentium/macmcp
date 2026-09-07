class Macmcp < Formula
  desc "Local macOS MCP bridge for mail, Calendar, and Reminders"
  homepage "https://github.com/Dimentium/macmcp"
  url "https://github.com/Dimentium/macmcp.git", tag: "v0.2.1", revision: "709d82f08aa16a32db10fb5bfb14af6458d5a202"
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
