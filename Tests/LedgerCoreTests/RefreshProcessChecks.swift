import Foundation
import LedgerCore
import Testing

extension LedgerCoreTests {
    static func refreshProcessChecks() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ledger-refresh-check-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let now = Date()
        let day = ProviderReport.key(now, calendar: .current)
        let reports: [[String: Any]] = ["codex", "claude"].map {
            ["provider": $0, "source": "local", "currencyCode": "USD", "reportingPeriod": "month-to-date",
             "historyCoverageIsEstablished": true, "totals": ["totalTokens": 10, "totalCost": 1],
             "daily": [["date": day, "totalTokens": 10, "totalCost": 1]]]
        }
        let data = try JSONSerialization.data(withJSONObject: reports)
        let output = root.appendingPathComponent("report.json")
        try data.write(to: output)
        let calls = root.appendingPathComponent("calls.txt")
        let homes = root.appendingPathComponent("homes.txt")
        let helper = root.appendingPathComponent("fixture-engine")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(calls.path)"
        printf '%s\\n' "$HOME" "$CFFIXED_USER_HOME" >> "\(homes.path)"
        /bin/cat "\(output.path)"
        """
        try Data(script.utf8).write(to: helper)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let month = try UsageSnapshot.decodeEngine(data)
        let allData = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "month-to-date", with: "all")
            .utf8)
        let all = try UsageSnapshot.decodeEngine(allData)
        var previous = UsageSnapshot(capturedAt: now, reports: month, allReports: all)
        let engine = CodexBarEngine(
            executable: helper,
            historySource: root.appendingPathComponent("empty-codex"),
            historyDestination: root.appendingPathComponent("support/CodexHistory"),
            claudeHistorySource: root.appendingPathComponent("empty-claude")
        )
        for force in [false, false, true] {
            previous = try await engine.loadSnapshot(
                timeZoneID: previous.timeZoneID,
                previous: previous,
                forceRefresh: force
            )
        }
        let commands = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n")
        #expect(commands.count == 3)
        #expect(commands[0].contains("--refresh") && !commands[1].contains("--refresh") && commands[2]
            .contains("--refresh"))
        let recordedHomes = try String(contentsOf: homes, encoding: .utf8).split(separator: "\n")
        let isolatedHome = root.appendingPathComponent("support/EngineHome-v3-speed/Month").path
        #expect(recordedHomes.count == 6 && recordedHomes.allSatisfy { $0 == isolatedHome })
        #expect(previous.metrics(.today).cost == 2)
    }
}
