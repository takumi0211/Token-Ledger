import LedgerCore
import SwiftUI

struct QuotaLimitsView: View {
    let model: LedgerModel
    private static let resetDate: DateFormatter = {
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "MMM d, HH:mm"
        return date
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(alignment: .leading, spacing: 8) {
                Text("REMAINING").font(.system(size: 8, weight: .semibold)).tracking(1.2).foregroundStyle(Palette.muted)
                row("claude", label: "5h", now: context.date)
                row("codex", label: "Week", now: context.date)
            }
        }
    }

    private func row(_ provider: String, label: String, now: Date) -> some View {
        let reading = model.quotaReadings.first { $0.provider == provider }
        let remaining = reading?.remainingPercent(now: now)
        let countdown = reading?.resetCountdown(now: now)
        let cached = model.quotaFailed.contains(provider) || reading
            .map { now.timeIntervalSince($0.capturedAt) > 180 } == true
        let tone = remaining.map { $0 <= 10 ? Color.orange.opacity(0.9) : Palette.accent } ?? Palette.muted
        let name = provider == "claude" ? "Claude" : "Codex"
        return VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 5) {
                Image(nsImage: ProviderAssets.logo(provider)).resizable().scaledToFit().frame(width: 11, height: 11)
                    .accessibilityHidden(true)
                Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
                if cached, remaining != nil {
                    Circle().fill(Color.orange.opacity(0.8)).frame(width: 3, height: 3)
                }
                Text(remaining.map { String(format: "%.0f%%", $0) } ?? "—")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(cached ? Palette.muted : Palette.ink)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.accent.opacity(0.12))
                    if let remaining {
                        Capsule().fill(tone.opacity(cached ? 0.45 : 0.85))
                            .frame(width: geometry.size.width * remaining / 100)
                    }
                }
            }.frame(height: 3)
            Text(countdown.map { "↻ " + $0 } ?? "—")
                .font(.system(size: 8.5, weight: .regular, design: .rounded)).monospacedDigit()
                .foregroundStyle(Palette.muted.opacity(cached ? 0.5 : 0.85))
                .frame(maxWidth: .infinity, alignment: .trailing).frame(height: 10).lineLimit(1)
        }.help(help(reading, name: name, label: label, cached: cached, remaining: remaining))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name) \(label) limit")
            .accessibilityValue(remaining
                .map {
                    "\(String(format: "%.0f", $0)) percent remaining\(cached ? ", cached" : "")\(countdown.map { ", resets in " + $0 } ?? "")"
                } ?? "Unavailable")
    }

    private func help(
        _ reading: QuotaReading?,
        name: String,
        label: String,
        cached: Bool,
        remaining: Double?
    ) -> String {
        guard let reading
        else { return "\(name) · \(label) · \(model.quotaRefreshing ? "Reading usage…" : "Usage unavailable")" }
        let date = Self.resetDate
        let amount = remaining.map { String(format: "%.0f%% remaining", $0) } ?? "Usage unavailable"
        let reset = reading.resetsAt.map { " · Resets " + date.string(from: $0) } ?? ""
        return "\(name) · \(label) · \(amount)\(reset)\(cached ? " · Cached" : "") · Updated \(date.string(from: reading.capturedAt))"
    }
}
