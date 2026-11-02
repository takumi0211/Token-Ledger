import LedgerCore
import SwiftUI

struct LedgerView: View {
    @Bindable var model: LedgerModel
    @State private var details: String?
    @State private var information = false
    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack(spacing: 8) {
                Image(nsImage: TokenGlyph.image).foregroundStyle(Palette.accent)
                Text("Token Ledger").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                Spacer()
                HStack(spacing: 2) {
                    ForEach(LedgerPeriod.allCases, id: \.self) { period in
                        Button { withAnimation(.snappy(duration: 0.2)) { model.period = period } } label: {
                            Text(period.rawValue).font(.system(size: 11, weight: .medium))
                                .foregroundStyle(model.period == period ? Palette.ink : Palette.muted)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 7)
                                    .fill(.white.opacity(model.period == period ? 0.11 : 0)))
                        }.buttonStyle(.plain).accessibilityAddTraits(model.period == period ? .isSelected : [])
                    }
                }.padding(3).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("API EQUIVALENT").font(.system(size: 9, weight: .semibold)).tracking(1.7)
                        .foregroundStyle(Palette.muted)
                    Text(model.total.money).font(.system(size: 47, weight: .light, design: .rounded))
                        .monospacedDigit().tracking(-1.8).foregroundStyle(Palette.ink).contentTransition(.numericText())
                        .minimumScaleFactor(0.65).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(periodCaption).font(.system(size: 11))
                        if model.total.partial, model.snapshot != nil {
                            Text("· Partial").font(.system(size: 9))
                        }
                    }.foregroundStyle(Palette.muted).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                QuotaLimitsView(model: model).frame(width: 104)
            }.padding(.top, 5).padding(.bottom, 2)
            VStack(spacing: 1) {
                providerRow("claude", title: "Claude Code")
                Rectangle().fill(.white.opacity(0.055)).frame(height: 1).padding(.leading, 52)
                providerRow("codex", title: "Codex")
            }.background(.white.opacity(0.032), in: RoundedRectangle(cornerRadius: 17))
            history
            VStack(spacing: 13) {
                Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
                HStack(spacing: 6) {
                    Circle().fill(model.failed ? Color.orange.opacity(0.8) : Palette.accent.opacity(0.8)).frame(
                        width: 4,
                        height: 4
                    )
                    Text(model.status).font(.system(size: 10)).foregroundStyle(Palette.muted)
                    Spacer()
                    Button { information.toggle() } label: {
                        Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                    .buttonStyle(.plain).help("About these estimates")
                    .popover(isPresented: $information) { explanation }
                    Button { model.refreshNow() } label: {
                        RefreshGlyph(isRefreshing: model.refreshing).frame(width: 16, height: 16)
                            .accessibilityHidden(true)
                    }.buttonStyle(.plain).disabled(model.refreshing).padding(.leading, 10)
                        .accessibilityLabel("Refresh").help("Refresh local usage")
                }
            }
        }
        .padding(22).frame(width: 384, height: 540)
        .background {
            ZStack(alignment: .topLeading) {
                Color(red: 0.035, green: 0.037, blue: 0.035)
                RadialGradient(
                    colors: [Palette.accent.opacity(0.09), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 390
                )
                LinearGradient(
                    colors: [.white.opacity(0.025), .clear, .black.opacity(0.15)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 19).stroke(.white.opacity(0.07), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 19)).preferredColorScheme(.dark)
    }

    private var periodCaption: String {
        if model.period == .all {
            return "All recorded history"
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = model
            .period == .today ? "MMM d" : "MMMM 'to date'"
        f.timeZone = model.snapshot?.calendar.timeZone ?? .current
        return f.string(from: Date())
    }

    private func providerRow(_ id: String, title: String) -> some View {
        let report = model.reports.first(where: { $0.provider == id })
        let metric = report?
            .metrics(model.period, now: Date(), calendar: model.snapshot?.calendar ?? .current) ?? .unavailable
        return Button { details = id } label: {
            HStack(spacing: 12) {
                Image(nsImage: ProviderAssets.logo(id)).resizable().scaledToFit()
                    .frame(width: 27, height: 27).frame(width: 31, height: 36).accessibilityHidden(true)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
                Spacer()
                Text(metric.money).font(.system(size: 21, weight: .regular, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Palette.ink)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.muted.opacity(0.6))
            }.padding(.horizontal, 14).padding(.vertical, 16).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help(metric.partial ? "Partial estimate from available history and pricing." : "Model breakdown")
            .popover(isPresented: Binding(get: { details == id }, set: {
                if !$0 {
                    details = nil
                }
            })) {
                breakdown(report)
            }
    }

    private var history: some View {
        UsageHistoryChart(snapshot: model.snapshot, period: model.period)
    }

    private func breakdown(_ report: ProviderReport?) -> some View {
        let models: [ModelUsage] = {
            guard let report else { return [] }
            if model.period == .today {
                return (report.daily?.first(where: { $0.date == ProviderReport.key(
                    Date(),
                    calendar: model.snapshot?.calendar ?? .current
                ) })?.modelBreakdowns ?? []).flatMap(\.displayRows)
            }
            // Aggregate upstream model subtotals only; pricing stays inside CodexBar.
            var rows: [String: [ModelUsage]] = [:]
            for day in report.daily ?? [] {
                for item in (day.modelBreakdowns ?? []).flatMap(\.displayRows) {
                    rows[item.modelName, default: []].append(item)
                }
            }
            return rows.keys.sorted().compactMap { name in
                let values = rows[name]!
                let summed = UsageMetrics.combined(values.map { UsageMetrics(
                    tokens: $0.totalTokens,
                    cost: $0.cost,
                    partial: false
                ) })
                return ModelUsage(
                    modelName: name,
                    totalTokens: values.allSatisfy { $0.totalTokens != nil } ? summed.tokens : nil,
                    cost: values.allSatisfy { $0.cost != nil } ? summed.cost : nil
                )
            }
        }()
        return VStack(alignment: .leading, spacing: 12) {
            Text(report?.title ?? "Usage").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
            if models.isEmpty {
                Text("No model breakdown available.").foregroundStyle(Palette.muted)
            }
            ForEach(models.sorted { ($0.cost ?? -1) > ($1.cost ?? -1) }) { row in
                HStack(alignment: .top, spacing: 16) {
                    Text(row.modelName).lineLimit(1).help(row.modelName).foregroundStyle(Palette.ink)
                    Spacer()
                    Text(row.cost.map { String(format: "$%.0f", $0) } ?? "Unpriced").foregroundStyle(Palette.accent)
                        .monospacedDigit()
                }
            }
            Text("API equivalent · local logs").font(.system(size: 9)).foregroundStyle(Palette.muted)
        }.font(.system(size: 10)).padding(18).frame(width: 320).preferredColorScheme(.dark)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("API equivalent").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
            Text(
                "Recorded Claude Code and Codex usage, priced by CodexBar. These are estimates, not charges or invoices."
            )
            Text("Cache pricing is included. History or pricing may be incomplete. Missing data stays unavailable.")
            Text("Only local history is included; activity on other machines may be missing.")
            Text("Calendar: \(model.snapshot?.timeZoneID ?? TimeZone.current.identifier) · Updated every minute")
            Text("CodexBar 0.77.0 · Peter Steinberger · MIT").font(.system(size: 9)).foregroundStyle(Palette.accent)
        }.font(.system(size: 10)).foregroundStyle(Palette.muted).padding(18).frame(width: 290).fixedSize(
            horizontal: false,
            vertical: true
        ).preferredColorScheme(.dark)
    }
}
