# typed: false
# frozen_string_literal: true

class McpSync < Formula
  desc "Keep MCP server configuration synchronized across supported clients"
  homepage "https://github.com/EnjoyableWork/mcp-sync"
  url "https://github.com/EnjoyableWork/mcp-sync/releases/download/v0.1.0/enjoyable-mcp-sync-0.1.0.crate"
  sha256 "dc48488c20725abc4d773834544acd6965b78b2b2a963b0386b09752a2c3288e"
  license "MIT"

  depends_on "rust" => :build

  def install
    system "cargo", "install", *std_cargo_args(path: ".")
  end

  test do
    assert_equal "mcp-sync #{version}", shell_output("#{bin}/mcp-sync --version").strip
  end
end
