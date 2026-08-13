# typed: false
# frozen_string_literal: true

class McpSync < Formula
  desc "Keep MCP server configuration synchronized across supported clients"
  homepage "https://github.com/EnjoyableWork/mcp-sync"
  url "https://github.com/EnjoyableWork/mcp-sync/releases/download/v0.1.1/enjoyable-mcp-sync-0.1.1.crate"
  sha256 "ea44931c93eaf89126f5dee1978f3485822d2a36f6acb8c0cc1d5f2def925d49"
  license "MIT"

  depends_on "rust" => :build

  def install
    system "cargo", "install", *std_cargo_args(path: ".")
  end

  test do
    assert_equal "mcp-sync #{version}", shell_output("#{bin}/mcp-sync --version").strip
  end
end
