import Foundation
import Testing
@testable import PiRuntime

private struct FixedKeys: ProviderKeySource {
    func apiKey(for provider: String) -> String? { ["brave": "BRAVE/KEY=1", "deepseek": "sk-test", "mcp-ha": "ha-token"][provider] }
}

struct ServiceTests {
    @Test("A header placeholder becomes the key on the service's hosts only")
    func headerKey() throws {
        var used = Set<String>()
        let value = try ProviderKeys.substitute("Bearer pi-host-key:deepseek", host: "api.deepseek.com", keys: FixedKeys(), used: &used)
        #expect(value == "Bearer sk-test")
        #expect(used == ["deepseek"])
        #expect(throws: (any Error).self) {
            try ProviderKeys.substitute("pi-host-key:brave", host: "evil.example", keys: FixedKeys(), used: &used)
        }
        #expect(used == ["deepseek"], "a refused key is not counted")
    }

    @Test("A query placeholder, plain or percent-encoded, becomes the percent-encoded key")
    func queryKey() throws {
        var used = Set<String>()
        let encoded = try ProviderKeys.substitute(
            url: URL(string: "https://api.search.brave.com/res?q=a%20b&key=pi-host-key%3Abrave")!, keys: FixedKeys(), used: &used
        )
        #expect(encoded.absoluteString == "https://api.search.brave.com/res?q=a%20b&key=BRAVE/KEY%3D1")
        #expect(used == ["brave"])
        let plain = try ProviderKeys.substitute(url: URL(string: "https://api.search.brave.com/res?key=pi-host-key:brave")!, keys: FixedKeys(), used: &used)
        #expect(plain.query == "key=BRAVE/KEY%3D1")
        let untouched = URL(string: "https://example.com/?q=pi")!
        #expect(try ProviderKeys.substitute(url: untouched, keys: FixedKeys(), used: &used) == untouched)
        #expect(throws: (any Error).self) {
            try ProviderKeys.substitute(url: URL(string: "https://evil.example/?key=pi-host-key%3Abrave")!, keys: FixedKeys(), used: &used)
        }
    }

    @Test("An MCP server's token goes only to the host saved for it in Settings")
    func mcpHost() throws {
        ProviderKeys.setMCPHosts(["ha": "100.64.0.2"])
        defer { ProviderKeys.setMCPHosts([:]) }
        var used = Set<String>()
        #expect(try ProviderKeys.substitute("Bearer pi-host-key:mcp-ha", host: "100.64.0.2", keys: FixedKeys(), used: &used) == "Bearer ha-token")
        #expect(throws: (any Error).self) {
            try ProviderKeys.substitute("Bearer pi-host-key:mcp-ha", host: "evil.example", keys: FixedKeys(), used: &used)
        }
        #expect(throws: (any Error).self, "a server with no saved host") {
            try ProviderKeys.substitute("Bearer pi-host-key:mcp-nas", host: "100.64.0.2", keys: FixedKeys(), used: &used)
        }
        ProviderKeys.setMCPHosts([:])
        #expect(throws: (any Error).self, "a removed server") {
            try ProviderKeys.substitute("Bearer pi-host-key:mcp-ha", host: "100.64.0.2", keys: FixedKeys(), used: &used)
        }
    }

    @Test("Monthly usage stops at the cap, takes the service's own count, and starts over next month")
    func monthlyCap() throws {
        let suite = "pi.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let usage = ServiceUsage(defaults: defaults, caps: ["brave": 2])
        let october = Date(timeIntervalSince1970: 1_793_000_000) // 2026-10-26
        try usage.record("brave", at: october)
        try usage.record("brave", at: october)
        #expect(throws: (any Error).self) { try usage.record("brave", at: october) }
        #expect(usage.count(for: "brave", at: october) == 2)
        usage.correct("brave", remaining: 1, at: october)
        #expect(usage.count(for: "brave", at: october) == 1)
        try usage.record("brave", at: october.addingTimeInterval(10 * 86_400))
        #expect(usage.count(for: "brave", at: october.addingTimeInterval(10 * 86_400)) == 1, "November is counted apart")
        for _ in 0..<5 { try usage.record("deepseek", at: october) }
        #expect(usage.count(for: "deepseek", at: october) == 5, "no cap, only a count")
    }
}
