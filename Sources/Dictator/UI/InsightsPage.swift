import SwiftUI

struct InsightsPage: View {
    @ObservedObject var stats: Stats

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Insights", subtitle: "How much you've written by voice. Everything is counted on this Mac.")

            Card(glow: true) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(text: "Last 14 days")
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(formatCount(stats.recentDays(14).reduce(0) { $0 + $1.value }))
                                .font(.system(size: 44, weight: .light)).tracking(-1.2).monospacedDigit()
                            Text("words").font(.system(size: 14)).foregroundStyle(Theme.muted)
                        }
                    }
                    Spacer()
                }
                GlowBarChart(values: stats.recentDays(14))
            }

            Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    StatTile(value: "\(stats.wordsPerMinute)", label: "words per minute", icon: "speedometer")
                    StatTile(value: formatCount(stats.data.words), label: "total words", icon: "text.word.spacing")
                    StatTile(value: formatCount(stats.data.fixes), label: "fixes by Dictator", icon: "checkmark.seal")
                }
                GridRow {
                    StatTile(value: timeSaved, label: "saved vs typing at 40 wpm", icon: "hourglass")
                    StatTile(value: formatCount(stats.data.dictations), label: "dictations", icon: "mic")
                    StatTile(value: formatCount(stats.data.transforms), label: "transforms", icon: "wand.and.rays")
                }
            }

            Card {
                HStack {
                    Text("Activity").font(.headline)
                    Spacer()
                    Label("\(stats.currentStreak) day streak", systemImage: "flame").foregroundStyle(Theme.saffron)
                    Text("·").foregroundStyle(.tertiary)
                    Text("longest \(stats.longestStreak)").foregroundStyle(.secondary)
                }
                .font(.callout)
                Heatmap(wordsByDay: stats.data.wordsByDay)
            }

            Card {
                Text("Where you dictate").font(.headline)
                let apps = stats.data.wordsByApp.sorted { $0.value > $1.value }.prefix(8)
                if apps.isEmpty {
                    Text("No dictations yet.").foregroundStyle(.secondary)
                } else {
                    let top = Double(apps.first?.value ?? 1)
                    ForEach(Array(apps), id: \.key) { app, words in
                        HStack(spacing: 12) {
                            Text(app).frame(width: 150, alignment: .leading).lineLimit(1)
                            GeometryReader { geo in
                                Capsule().fill(Theme.gradient)
                                    .frame(width: max(6, geo.size.width * Double(words) / top), height: 10)
                                    .frame(maxHeight: .infinity, alignment: .center)
                            }
                            .frame(height: 16)
                            Text("\(formatCount(words)) words").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private var timeSaved: String {
        let m = stats.minutesSaved
        return m >= 60 ? String(format: "%.1fh", Double(m) / 60) : "\(m)m"
    }
}

/// 26 weeks × 7 days, darker = more words.
private struct Heatmap: View {
    let wordsByDay: [String: Int]
    private let weeks = 26

    var body: some View {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today) - 1          // 0 = Sunday
        let start = calendar.date(byAdding: .day, value: -(weeks - 1) * 7 - weekday, to: today)!
        let maxWords = max(wordsByDay.values.max() ?? 1, 1)

        HStack(alignment: .top, spacing: 4) {
            ForEach(0..<weeks, id: \.self) { week in
                VStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { day in
                        let date = calendar.date(byAdding: .day, value: week * 7 + day, to: start)!
                        let words = wordsByDay[Stats.dayFormatter.string(from: date)] ?? 0
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(color(words: words, max: maxWords))
                            .frame(width: 14, height: 14)
                            .opacity(date > today ? 0 : 1)
                            .help("\(date.formatted(date: .abbreviated, time: .omitted)): \(words) words")
                    }
                }
            }
        }
    }

    private func color(words: Int, max: Int) -> Color {
        guard words > 0 else { return Color.primary.opacity(0.07) }
        let level = 0.25 + 0.75 * (Double(words) / Double(max)).squareRoot()
        return Theme.saffron.opacity(level)
    }
}
