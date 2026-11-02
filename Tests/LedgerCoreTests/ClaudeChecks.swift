import Foundation
import LedgerCore
import Testing

extension LedgerCoreTests {
    static func claudeChecks() throws {
        func check(_ value: Bool) {
            #expect(value)
        }
        let fm = FileManager.default,
            base = fm.temporaryDirectory.appendingPathComponent("ledger-claude-check-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let source = base.appendingPathComponent("source"), destination = base.appendingPathComponent("usage")
        let parent = source.appendingPathComponent("projects/project/parent.jsonl")
        try fm.createDirectory(at: parent.deletingLastPathComponent(), withIntermediateDirectories: true)
        let raw = #"{"type": "assistant", "timestamp": "2026-09-19T10:00:00Z", "sessionId": "session", "requestId": "request", "isSidechain": false, "message": {"id": "message", "model": "claude-opus-4-6", "content": [{"text":"PRIVATE_CONVERSATION"}], "usage": {"input_tokens": 10,"cache_read_input_tokens": 1000,"cache_creation_input_tokens": 50,"output_tokens": 20}, "stop_reason":"end_turn"}}"#
        try Data((raw + "\n").utf8).write(to: parent)
        let adapter = ClaudeHistoryProjection(source: source, destination: destination)
        try adapter.prepare()
        let result = try Data(contentsOf: destination.appendingPathComponent("projects/project/parent.jsonl"))
        let text = String(decoding: result, as: UTF8.self)
        #expect(!text.contains("PRIVATE_CONVERSATION") && text.contains("\"type\":\"assistant\""))
        let row = try JSONSerialization.jsonObject(with: result) as! [String: Any]
        let message = row["message"] as! [String: Any]
        #expect((row["requestId"] as? String) == "request" && (message["id"] as? String) == "message")
        try check(Data(contentsOf: parent) == Data((raw + "\n").utf8))
        let changed = raw.replacingOccurrences(of: "\"output_tokens\": 20", with: "\"output_tokens\": 25")
        try Data((changed + "\n").utf8).write(to: parent)
        _ = try adapter.prepare()
        let newer = try Data(contentsOf: destination.appendingPathComponent("projects/project/parent.jsonl"))
        #expect(String(decoding: newer, as: UTF8.self).contains("\"output_tokens\":25"))
        try Data((changed + "\n" + #"{"type":"assistant","message":{"usage":{"input_tokens":8"#).utf8).write(to: parent)
        _ = try adapter.prepare()
        try check(Data(contentsOf: destination.appendingPathComponent("projects/project/parent.jsonl")) == newer)
        try fm.removeItem(at: parent)
        _ = try adapter.prepare()
        try check(Data(contentsOf: destination.appendingPathComponent("projects/project/parent.jsonl")) == newer)
    }
}
