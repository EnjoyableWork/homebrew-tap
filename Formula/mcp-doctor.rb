# typed: false
# frozen_string_literal: true

class McpDoctor < Formula
  desc "Diagnose protocol, schema, and runtime failures in MCP servers"
  homepage "https://github.com/EnjoyableWork/mcp-doctor"
  url "https://github.com/EnjoyableWork/mcp-doctor/releases/download/v0.4.2/mcp-doctor-0.4.2.crate"
  sha256 "c9f58db1d9713e6f2ccdf8352f6461438d6a477664e6e0c3503987a42422c3bc"
  license "MIT"

  depends_on "rust" => :build

  def install
    system "cargo", "install", *std_cargo_args(path: ".")
  end

  test do
    server = testpath/"passive-server.rb"
    server.write <<~RUBY
      #!/usr/bin/env ruby
      require "json"

      requests = []
      while (line = STDIN.gets)
        request = JSON.parse(line)
        abort "active tool call attempted" if request["method"] == "tools/call"
        requests << request["method"]
        result = case request["method"]
        when "server/discover"
          {
            "resultType" => "complete",
            "supportedVersions" => ["2026-07-28"],
            "capabilities" => { "tools" => {} },
            "ttlMs" => 0,
            "cacheScope" => "private",
          }
        when "tools/list"
          {
            "resultType" => "complete",
            "tools" => [],
            "ttlMs" => 0,
            "cacheScope" => "private",
          }
        else
          abort "unexpected method"
        end
        STDOUT.puts(JSON.generate({ "jsonrpc" => "2.0", "id" => request["id"], "result" => result }))
        STDOUT.flush
      end
      abort "unexpected passive request sequence" unless requests == ["server/discover", "tools/list"]
    RUBY
    chmod 0755, server

    output = shell_output("#{bin}/mcp-doctor inspect --format json -- #{server}")
    assert_match '"outcome": "passed"', output
    assert_match '"skip_reason": "not_authorized"', output
  end
end
