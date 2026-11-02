import LedgerCore
import SwiftUI

struct UsageHistoryChart: View {
    let period: LedgerPeriod
    private let points: [CostChartPoint]
    private let calendar: Calendar
    private let slots: Int
    private let average: Double?
    private let completeCount: Int
    private let formatter: DateFormatter
    @State private var hovered: String?
    @State private var pinned: String?

    init(snapshot: UsageSnapshot?, period: LedgerPeriod, now: Date = Date()) {
        self.period = period
        calendar = snapshot?.calendar ?? .current
        if period == .all {
            let series = MonthlyCostSeries(snapshot: snapshot, now: now)
            points = series.points
            slots = max(points.count, 12)
            average = series.average
            completeCount = series.completeMonths.count
        } else {
            let series = DailyCostSeries(snapshot: snapshot, now: now)
            points = series.points
            slots = max(series.daysInMonth, 1)
            average = series.average
            completeCount = series.completedDays.count
        }
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = period == .all ? "MMM ''yy" : "MMM d"
    }

    private var active: CostChartPoint? {
        points.first { $0.id == (hovered ?? pinned) } ?? points.last
    }

    private var inspecting: Bool {
        hovered != nil || pinned != nil
    }

    private var maximum: Double {
        max(points.compactMap(\.total.cost).max() ?? 1, 1)
    }

    private var showAverage: Bool {
        completeCount >= 3 && average != nil
    }

    private var averageAtRest: Bool {
        period == .month && !inspecting && showAverage
    }

    private var scopeDescription: String {
        let scope = period == .all ? "Monthly totals from recorded local usage." : "Current calendar month."
        return scope +
            (showAverage ?
                " Average across \(completeCount) fully recorded \(period == .all ? "months" : "days"): \(money(average))." :
                "")
    }

    private func dateLabel(_ point: CostChartPoint) -> String {
        point.isCurrentPeriod && period != .all ? "Today" : formatter.string(from: point.date)
    }

    private func money(_ cost: Double?) -> String {
        guard let cost else { return "—" }
        return cost > 0 && cost < 0.5 ? "<$1" : String(format: "$%.0f", cost)
    }

    private func stateLabel(_ point: CostChartPoint) -> String? {
        if point.total.cost == nil {
            return "No data"
        }
        if point.total.partial {
            return "Partial"
        }
        if point.isCurrentPeriod {
            return "so far"
        }
        if !point.isCompletePeriod {
            return "Partial"
        }
        return nil
    }

    private func description(_ point: CostChartPoint) -> String {
        func spoken(_ value: Double?) -> String {
            value == nil ? "Unavailable" : money(value)
        }
        return "\(dateLabel(point)) · \(spoken(point.total.cost))\(stateLabel(point).map { " · " + $0 } ?? "") · Claude \(spoken(point.claude.cost)) · Codex \(spoken(point.codex.cost))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(period == .all ? "BY MONTH" : "THIS MONTH")
                    .font(.system(size: 8, weight: .semibold)).tracking(1.5).foregroundStyle(Palette.muted)
                    .help(period == .all ? "Monthly totals from recorded local usage." :
                        "Daily API-equivalent cost in this calendar month")
                Spacer()
                Text(averageAtRest ? "Avg / day" : (active.map(dateLabel) ?? "No history"))
                    .font(.system(size: 9)).foregroundStyle(Palette.muted)
                if !averageAtRest, let state = active.flatMap(stateLabel) {
                    Text(state).font(.system(size: 8)).foregroundStyle(Palette.muted.opacity(0.85))
                }
                Text(money(averageAtRest ? average : active?.total.cost))
                    .font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Palette.ink)
                    .frame(minWidth: 33, alignment: .trailing)
            }.frame(height: 16).accessibilityHidden(true)
            GeometryReader { geometry in
                let slotWidth = geometry.size.width / CGFloat(slots)
                let leadingSlots = period == .all ? max(0, slots - points.count) : 0
                ZStack(alignment: .bottom) {
                    Rectangle().fill(Palette.accent.opacity(0.09)).frame(height: 1)
                    if showAverage, let average {
                        Path { path in
                            let y = geometry.size.height - 56 * average / maximum
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                        }.stroke(Palette.accent.opacity(0.23), style: StrokeStyle(lineWidth: 0.6, dash: [2, 3]))
                            .allowsHitTesting(false)
                    }
                    HStack(alignment: .bottom, spacing: 0) {
                        if leadingSlots > 0 {
                            Color.clear.frame(width: slotWidth * CGFloat(leadingSlots), height: 58)
                                .allowsHitTesting(false)
                        }
                        ForEach(points) { point in
                            Button { pinned = pinned == point.id ? nil : point.id } label: {
                                VStack(spacing: 0) {
                                    Spacer(minLength: 0)
                                    if let cost = point.total.cost {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Palette.accent
                                                .opacity(point.id == active?.id ? 0.95 : (inspecting ? 0.20 : 0.30)))
                                            .overlay {
                                                if point.total.partial {
                                                    RoundedRectangle(cornerRadius: 2).stroke(
                                                        Palette.accent.opacity(0.45),
                                                        style: StrokeStyle(
                                                            lineWidth: 0.7,
                                                            dash: [1.5, 2]
                                                        )
                                                    )
                                                }
                                            }
                                            .frame(height: cost == 0 ? 1 : max(2, 56 * cost / maximum))
                                    } else {
                                        RoundedRectangle(cornerRadius: 1)
                                            .stroke(
                                                Palette.accent.opacity(0.4),
                                                style: StrokeStyle(lineWidth: 0.7, dash: [1, 2])
                                            ).frame(height: 3)
                                    }
                                }.padding(.horizontal, slotWidth * 0.18).frame(width: slotWidth, height: 58)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel(description(point))
                                .accessibilityHint("Click to pin this period. Click again to release.")
                                .accessibilityAddTraits(pinned == point.id ? .isSelected : [])
                        }
                        if slots > points.count, period != .all {
                            Color.clear.frame(width: slotWidth * CGFloat(slots - points.count), height: 58)
                                .allowsHitTesting(false)
                        }
                    }
                }.contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            let index = min(points.count - 1, max(0, Int(location.x / slotWidth) - leadingSlots))
                            if points.indices.contains(index) {
                                hovered = points[index].id
                            }
                        case .ended: hovered = nil
                        }
                    }
            }.frame(height: 58)
            HStack(spacing: 0) {
                if inspecting, let active {
                    Text("Claude \(money(active.claude.cost))")
                    Spacer()
                    Text("Codex \(money(active.codex.cost))")
                } else if period == .all, points.count < 12, !points.isEmpty {
                    Text("Detailed history")
                    Spacer()
                    Text(points.last.map(dateLabel) ?? "")
                } else if !points.isEmpty {
                    Text(period == .all ? points.first.map(dateLabel) ?? "" : "1")
                    Spacer()
                    Text(period == .all ? (showAverage ? "Avg " + money(average) + "/mo" : "Detailed history") :
                        (showAverage && period == .today ? "Avg " + money(average) : ""))
                        .help(period == .all ? "Old undated totals are excluded from this chart." :
                            "Average of fully recorded days, excluding today")
                    Spacer()
                    Text(period == .all ? points.last.map(dateLabel) ?? "" : String(slots))
                }
            }.font(.system(size: 9)).monospacedDigit().foregroundStyle(Palette.muted).frame(height: 13)
                .accessibilityHidden(true)
        }.frame(height: 105)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(period == .all ? "Monthly API-equivalent costs from dated history" :
                "Daily API-equivalent costs this month")
            .accessibilityValue(scopeDescription)
            .onChange(of: period) { _, _ in hovered = nil
                pinned = nil
            }
            .onChange(of: points.map(\.id)) { _, keys in
                if let pinned, !keys.contains(pinned) {
                    self.pinned = nil
                }
                if let hovered, !keys.contains(hovered) {
                    self.hovered = nil
                }
            }
            .onDisappear { hovered = nil
                pinned = nil
            }
    }
}
