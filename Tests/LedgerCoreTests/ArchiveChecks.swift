import Foundation
import LedgerCore
import Testing

extension LedgerCoreTests {
    static func archiveChecks() throws {
        func check(_ condition: Bool) {
            #expect(condition)
        }
        let fm = FileManager.default,
            base = fm.temporaryDirectory.appendingPathComponent("ledger-archive-check-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let source = base.appendingPathComponent("original"), destination = base.appendingPathComponent("projection")
        let sessions = source.appendingPathComponent("sessions/2026/09/30")
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        let prefix = try brewPrefix()
        let library = prefix.appendingPathComponent("lib/libzstd.1.dylib")
        let adapter = CodexHistoryProjection(source: source, destination: destination, library: library)
        let rows: [[String: Any]] = [
            [
                "type": "session_meta",
                "ordinal": 0,
                "timestamp": "2026-09-30T12:00:00Z",
                "payload": [
                    "id": "parent",
                    "forked_from_id": "ancestor",
                    "history_base": ["thread_id": "ancestor"],
                    "subagent_history_start_ordinal": 9,
                    "base_instructions": "PRIVATE_PROMPT",
                ],
            ],
            ["type": "response_item", "ordinal": 1, "payload": ["text": "PRIVATE_PROMPT token_count"]],
            [
                "type": "turn_context",
                "ordinal": 2,
                "timestamp": "2026-09-30T12:00:00Z",
                "payload": ["model": "gpt-5", "turn_id": "turn1", "user_instructions": "PRIVATE_PROMPT"],
            ],
            [
                "type": "event_msg",
                "ordinal": 3,
                "timestamp": "2026-09-30T12:00:01Z",
                "payload": [
                    "type": "token_count",
                    "info": ["total_token_usage": [
                        "input_tokens": 1000,
                        "cached_input_tokens": 900,
                        "output_tokens": 10,
                    ]],
                ],
            ],
            [
                "type": "token_usage_record",
                "ordinal": 4,
                "timestamp": "2026-09-30T12:00:01Z",
                "payload": [
                    "thread_id": "parent",
                    "session_id": "sess",
                    "response_id": "response1",
                    "turn_id": "turn1",
                    "model": "gpt-5",
                    "usage": ["input_tokens": 1000, "output_tokens": 10],
                    "thread_token_usage": ["input_tokens": 1000, "output_tokens": 10],
                ],
            ],
            [
                "type": "event_msg",
                "ordinal": 5,
                "timestamp": "2026-09-30T12:00:02Z",
                "payload": [
                    "type": "task_complete",
                    "turn_id": "turn1",
                    "duration_ms": 2000,
                    "last_agent_message": "PRIVATE_PROMPT",
                ],
            ],
            [
                "timestamp": "2026-09-30T12:00:03Z",
                "data": [
                    "model": "gpt-5",
                    "usage": ["input_tokens": 20, "output_tokens": 5],
                    "content": "PRIVATE_PROMPT",
                ],
            ],
        ]
        var data = Data()
        for row in rows {
            try data.append(JSONSerialization.data(withJSONObject: row))
            data.append(10)
        }
        let plain = base.appendingPathComponent("fixture.jsonl"),
            compressed = sessions.appendingPathComponent("rollout-2026-09-30T12-00-00-fixture.jsonl.zst")
        try data.write(to: plain)
        let zstd = Process()
        zstd.executableURL = prefix.appendingPathComponent("bin/zstd")
        zstd.arguments = [
            "-q",
            "-f",
            plain.path,
            "-o",
            compressed.path,
        ]
        try zstd.run()
        zstd.waitUntilExit()
        #expect(zstd.terminationStatus == 0)
        let original = try Data(contentsOf: compressed)
        _ = try adapter.prepare()
        let projected = destination
            .appendingPathComponent("sessions/2026/09/30/rollout-2026-09-30T12-00-00-fixture.jsonl")
        let result = try Data(contentsOf: projected), text = String(decoding: result, as: UTF8.self)
        #expect(!text.contains("PRIVATE_PROMPT"))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == rows.count + 1 && lines[1].isEmpty)
        for index in [3, 4] {
            let decoded = try JSONSerialization.jsonObject(with: Data(lines[index].utf8)) as! NSDictionary
            #expect(decoded == rows[index] as NSDictionary)
        }
        #expect(text.contains("subagent_history_start_ordinal") && text.contains("ancestor") && text
            .contains("response1"))
        try check(Data(contentsOf: compressed) == original)
        let attributes = try fm.attributesOfItem(atPath: projected.path)
        _ = try adapter.prepare()
        try check((fm.attributesOfItem(atPath: projected.path)[.modificationDate] as? Date) ==
            (attributes[.modificationDate] as? Date))
        // Concatenated zstd frames are valid archives; truncated frames must fail closed.
        try (original + original).write(to: compressed)
        _ = try adapter.prepare()
        try check(Data(contentsOf: projected).count == result.count * 2)
        try original.dropLast(5).write(to: compressed)
        do { _ = try adapter.prepare()
            Issue.record("Truncated archive accepted")
        } catch { #expect(error is LedgerError) }
        try check(Data(contentsOf: projected).count == result.count * 2)
        // The uncompressed original wins rather than being counted twice or overwritten.
        let live = compressed.deletingPathExtension()
        try data.write(to: live)
        _ = try adapter.prepare()
        let linkedAttributes = try fm.attributesOfItem(atPath: projected.path)
        let liveAttributes = try fm.attributesOfItem(atPath: live.path)
        #expect((linkedAttributes[.systemFileNumber] as? NSNumber) ==
            (liveAttributes[.systemFileNumber] as? NSNumber))
        try check(Data(contentsOf: live) == data)
        try fm.removeItem(at: compressed)
        try fm.removeItem(at: live)
        _ = try adapter.prepare()
        try check(Data(contentsOf: projected) == data)
        let archived = source.appendingPathComponent("archived_sessions/\(live.lastPathComponent)")
        try fm.createDirectory(at: archived.deletingLastPathComponent(), withIntermediateDirectories: true)
        let appended = try data + (JSONSerialization.data(withJSONObject: rows[3])) + Data([10])
        try appended.write(to: archived)
        _ = try adapter.prepare()
        let movedProjection = destination.appendingPathComponent("archived_sessions/\(live.lastPathComponent)")
        check(!fm.fileExists(atPath: projected.path))
        try check(Data(contentsOf: movedProjection) == appended)
        try fm.removeItem(at: archived)
        _ = try adapter.prepare()
        try check(Data(contentsOf: movedProjection) == appended)
        try original.write(to: compressed)
        _ = try adapter.prepare()
        try fm.removeItem(at: compressed)
        _ = try adapter.prepare()
        try check(Data(contentsOf: projected) == result)
        check(!fm.fileExists(atPath: movedProjection.path))
    }
}
