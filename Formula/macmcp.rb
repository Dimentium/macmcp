class Macmcp < Formula
  desc "Local macOS MCP bridge for mail, Calendar, and Reminders"
  homepage "https://github.com/Dimentium/macmcp"
  url "https://github.com/Dimentium/macmcp.git", tag: "v0.2.21", revision: "3a7f0a1fe36599cb95418dbf2cbb341ee100b685"
  license "MIT"

  depends_on "go"
  depends_on "python@3.14"

  def install
    odie "MacMCP requires macOS" unless OS.mac?

    libexec.install Dir["*"]
    bin.write_exec_script libexec/"scripts/macmcp"
  end

  def caveats
    <<~EOS
      MacMCP is installed but not configured yet.
      Run `macmcp setup --gmail-address you@gmail.com` to install the app and
      complete first-run setup. Use `--icloud-address` for iCloud Mail.
    EOS
  end

  test do
    system bin/"macmcp", "help"
  end
end
