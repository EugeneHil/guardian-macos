import CoreBridge
import Foundation
import Testing

private func policy(_ json: String) throws -> WDPolicy {
    try WDPolicy(json: Data(json.utf8))
}

private func chromeEnvPolicy(matcher: String = #"{"signingIdPrefix": "com.google.Chrome"}"#) -> String {
    """
    {"schemaVersion": 1, "version": 7, "rules": [
      {"id": "no-env", "targets": ["**/.env"], "action": "deny", "processes": [\(matcher)]}
    ]}
    """
}

private func process(_ path: String = "/bin/x", signingId: String = "", teamId: String = "") -> WDProcessInfo {
    WDProcessInfo(path: path, signingId: signingId, teamId: teamId)
}

struct CoreBridgeTests {
    @Test func parsesAndEvaluatesDeny() throws {
        let parsed = try policy(chromeEnvPolicy())
        #expect(parsed.version == 7)
        #expect(parsed.ruleCount == 1)
        let engine = WDEngine(policy: parsed)
        let request = WDAccessRequest(
            filePath: "/Users/a/p/.env",
            process: process(signingId: "com.google.Chrome.helper"),
            responsible: nil
        )
        let decision = engine.evaluate(request)
        #expect(decision.deny)
        #expect(decision.ruleId == "no-env")
    }

    @Test func allowsNonBlocklistedProcess() throws {
        let engine = try WDEngine(policy: policy(chromeEnvPolicy()))
        let request = WDAccessRequest(
            filePath: "/Users/a/p/.env",
            process: process(signingId: "com.apple.Terminal"),
            responsible: nil
        )
        let decision = engine.evaluate(request)
        #expect(!decision.deny)
        #expect(decision.ruleId.isEmpty)
    }

    @Test func invalidPolicyThrowsWithPaths() {
        let json = #"{"schemaVersion": 1, "version": 1, "rules": [{"id": "x"}]}"#
        do {
            _ = try policy(json)
            Issue.record("expected the policy to be rejected")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == WDPolicyErrorDomain)
            let lines = nsError.userInfo[WDPolicyValidationErrorsKey] as? [String] ?? []
            #expect(lines.contains { $0.hasPrefix("rules[0]") })
        }
    }

    @Test func normalizesProcessPath() throws {
        let engine = try WDEngine(policy: policy(chromeEnvPolicy(matcher: #"{"path": "/private/tmp/x"}"#)))
        let request = WDAccessRequest(filePath: "/Users/a/.env", process: process("/tmp/x"), responsible: nil)
        #expect(engine.evaluate(request).deny)
    }

    @Test func responsibleProcessIsMatched() throws {
        let matcher = #"{"signingIdPrefix": "com.anthropic.claude"}"#
        let engine = try WDEngine(policy: policy(chromeEnvPolicy(matcher: matcher)))
        let request = WDAccessRequest(
            filePath: "/Users/a/.env",
            process: process("/usr/bin/cat"),
            responsible: process("/Applications/Claude.app/x", signingId: "com.anthropic.claude")
        )
        #expect(engine.evaluate(request).deny)
    }

    @Test func prefilterTakesRawBytes() throws {
        let engine = try WDEngine(policy: policy(chromeEnvPolicy()))
        func check(_ bytes: [CChar]) -> Bool {
            bytes.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return false }
                return engine.isPotentiallyProtectedPath(base, length: UInt(buffer.count))
            }
        }
        #expect(check(Array("/Users/a/.env".utf8CString.dropLast())))
        #expect(!check(Array("/usr/lib/libc.dylib".utf8CString.dropLast())))
        _ = check([0x2F, CChar(bitPattern: 0xFF), CChar(bitPattern: 0xC0), 0x2F, 0x00, 0x41])
    }

    @Test func coreVersionIsPinned() {
        #expect(WDEngine.coreVersion() == "0.1.0")
    }
}
