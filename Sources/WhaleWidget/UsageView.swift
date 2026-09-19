import SwiftUI

/// 用量记录窗口：今日模型消费、近 7 天、全部记录；模型占比；按日期展开明细。
struct UsageView: View {

    @ObservedObject var store: WhaleStore
    @State private var search = ""
    @State private var expandedDay: String?

    private let accent = Color(red: 0.125, green: 0.192, blue: 0.439)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summary
                Divider()
                modelBreakdown
                Divider()
                recentDays
                if !store.todayModels.isEmpty {
                    Divider()
                    details
                }
            }
            .padding(16)
        }
        .frame(minWidth: 420, minHeight: 500)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - 概览

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 20) {
                metric("今日", store.todayUsage)
                metric("近 7 天", store.recentWeek.reduce(0) { $0 + $1.amount })
                metric("全部", store.allTimeTotal)
            }
            Text(store.usageLabel)
                .font(.system(size: 11)).foregroundColor(.secondary)
            if store.needsReview {
                Text("⚠️ 检测到余额增加，请在「余额校正」里按实际到账金额核对")
                    .font(.system(size: 11)).foregroundColor(.orange)
            }
            if let day = store.ledger.firstObservationDate {
                Text("统计起点：\(day)（余额观测口径，起点之前的消费不计入）")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
    }

    private func metric(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundColor(.secondary)
            Text("¥" + String(format: "%.2f", value))
                .font(.system(size: 20, weight: .bold, design: .rounded))
        }
    }

    // MARK: - 模型占比

    private var modelBreakdown: some View {
        let models = store.todayFriendlyModels
        let total = max(0.000001, models.reduce(0) { $0 + $1.cost })
        return VStack(alignment: .leading, spacing: 8) {
            Text("今日模型消费").font(.system(size: 13, weight: .semibold))
            if models.isEmpty {
                Text("今天还没有记录到模型消费")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            } else {
                ForEach(models, id: \.model) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(item.model).font(.system(size: 12))
                            Spacer()
                            Text("¥\(String(format: "%.4f", item.cost)) · \(item.count) 轮")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.gray.opacity(0.18))
                                .overlay(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(accent)
                                        .frame(width: geo.size.width * CGFloat(item.cost / total))
                                }
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
    }

    // MARK: - 近 7 天

    private var recentDays: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("近 7 天").font(.system(size: 13, weight: .semibold))
            ForEach(store.recentWeek, id: \.day) { item in
                HStack {
                    Button {
                        expandedDay = expandedDay == item.day ? nil : item.day
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: expandedDay == item.day ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9))
                            Text(item.day).font(.system(size: 12, design: .monospaced))
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("¥" + String(format: "%.4f", item.amount))
                        .font(.system(size: 12, design: .monospaced))
                }
                if expandedDay == item.day {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(store.ledger.events.filter { $0.day == item.day }, id: \.at) { event in
                            HStack {
                                Text(timeString(event.at)).font(.system(size: 11, design: .monospaced))
                                Text(FriendlyModel.name(event.model)).font(.system(size: 11))
                                Spacer()
                                Text("¥" + String(format: "%.4f", event.cost))
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            .foregroundColor(.secondary)
                        }
                        if store.ledger.events.filter({ $0.day == item.day }).isEmpty {
                            Text("（该日仅有余额观测记录，无逐轮明细）")
                                .font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    }
                    .padding(.leading, 16)
                }
            }
        }
    }

    // MARK: - 逐条明细

    private var details: some View {
        let events = filteredEvents()
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("逐条明细").font(.system(size: 13, weight: .semibold))
                Spacer()
                TextField("按日期或模型名搜索", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(width: 180)
            }
            if events.isEmpty {
                Text("没有匹配的记录").font(.system(size: 12)).foregroundColor(.secondary)
            } else {
                ForEach(events, id: \.at) { event in
                    HStack(spacing: 8) {
                        Text(event.day).font(.system(size: 11, design: .monospaced))
                        Text(timeString(event.at)).font(.system(size: 11, design: .monospaced))
                        Text(FriendlyModel.name(event.model)).font(.system(size: 11))
                        Spacer()
                        Text("¥" + String(format: "%.4f", event.cost))
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundColor(.secondary)
                }
            }
        }
    }

    /// 支持按日期或模型名搜索，按时间倒序。
    private func filteredEvents() -> [Ledger.UsageEvent] {
        let keyword = search.trimmingCharacters(in: .whitespaces).lowercased()
        let all = store.ledger.events.sorted { $0.at > $1.at }
        guard !keyword.isEmpty else { return Array(all.prefix(200)) }
        return all.filter {
            $0.day.contains(keyword)
                || $0.model.lowercased().contains(keyword)
                || FriendlyModel.name($0.model).lowercased().contains(keyword)
        }
    }

    private func timeString(_ ms: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}
