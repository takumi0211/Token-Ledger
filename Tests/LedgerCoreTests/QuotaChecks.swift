import Foundation
import LedgerCore
import Testing

extension LedgerCoreTests {
    static func quotaChecks() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-18T12:00:00Z")!
        let json = #"""
        [{"provider":"codex","usage":{"primary":{"windowMinutes":10080,"usedPercent":49,"resetsAt":"2026-10-24T23:55:16Z"},"secondary":{"windowMinutes":300,"usedPercent":1}},"accountEmail":"not-retained@example.test"},
        {"provider":"claude","usage":{"primary":{"windowMinutes":300,"usedPercent":10,"resetsAt":"2026-10-18T15:59:00.000Z"},"secondary":{"windowMinutes":10080,"usedPercent":90}}}]
        """#
        let codex = try QuotaReading.decode(Data(json.utf8), provider: "codex", now: now)
        let claude = try QuotaReading.decode(Data(json.utf8), provider: "claude", now: now)
        #expect(codex.remainingPercent(now: now) == 51 && claude.remainingPercent(now: now) == 90)
        #expect(codex.windowMinutes == 10080 && claude.windowMinutes == 300)
        #expect(claude.resetCountdown(now: now) == "3h 59m")
        #expect(codex.resetCountdown(now: now) == "155h 56m")
        let lastMinute = claude.resetsAt!.addingTimeInterval(-30)
        let freshNearReset = try QuotaReading.decode(Data(json.utf8), provider: "claude", now: lastMinute)
        #expect(freshNearReset.resetCountdown(now: lastMinute) == "<1m")
        #expect(freshNearReset.resetCountdown(now: freshNearReset.resetsAt!) == nil)
        #expect(claude.resetCountdown(now: now.addingTimeInterval(901)) == nil)
        let persisted = try String(decoding: JSONEncoder().encode([codex, claude]), as: UTF8.self)
        #expect(!persisted.contains("accountEmail") && !persisted.contains("example.test"))
        #expect(codex.remainingPercent(now: now.addingTimeInterval(901)) == nil)
        let afterReset = #"[{"provider":"claude","usage":{"primary":{"windowMinutes":300,"usedPercent":10,"resetsAt":"2026-10-18T11:59:00Z"}}}]"#
        for (data, provider) in [
            (afterReset, "claude"),
            (json.replacingOccurrences(of: "10080", with: "1440"), "codex"),
            (json.replacingOccurrences(of: #""usedPercent":10"#, with: #""usedPercent":101"#), "claude"),
            (#"[{"provider":"claude","error":{"message":"Unavailable"}}]"#, "claude"),
        ] {
            do {
                _ = try QuotaReading
                    .decode(Data(data.utf8), provider: provider, now: now)
                Issue.record("Invalid quota accepted")
            } catch { #expect(error is LedgerError) }
        }
    }
}
