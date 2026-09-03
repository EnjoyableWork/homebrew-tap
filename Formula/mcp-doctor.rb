# typed: false
# frozen_string_literal: true

class McpDoctor < Formula
  desc "Diagnose protocol, schema, and runtime failures in MCP servers"
  homepage "https://github.com/EnjoyableWork/mcp-doctor"
  url "https://github.com/EnjoyableWork/mcp-doctor/releases/download/v0.4.1/mcp-doctor-0.4.1.crate"
  sha256 "d6f59e72ca2ae68299a1b22a9be1f3f549c21484909e3e71f26f64c3f7c614d9"
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
