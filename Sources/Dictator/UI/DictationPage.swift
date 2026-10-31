import AppKit
import SwiftUI

struct DictationPage: View {
    @ObservedObject var app: AppController
    @ObservedObject var history: History
    @ObservedObject var stats: Stats
    @State private var search = ""
    @State private var tryText = ""

    private var firstName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? "there"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Namaste, \(firstName)",
                       subtitle: "Hold \(app.settings.hotkey.label) in any app and speak. Double-tap it for hands-free, Esc to cancel.")

            HStack(alignment: .top, spacing: 16) {
                Card(glow: true) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel(text: "This week")
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(formatCount(stats.recentDays(7).reduce(0) { $0 + $1.value }))
                                    .font(.system(size: 44, weight: .light)).tracking(-1.2).monospacedDigit()
                                Text("words").font(.system(size: 14)).foregroundStyle(Theme.muted)
                            }
                        }
                        Spacer()
                        Text(formatCount(stats.data.words) + " all time").font(.system(size: 12)).foregroundStyle(Theme.faint)
                    }
                    GlowBarChart(values: stats.recentDays(7))
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 16) {
                    StatTile(value: "\(stats.wordsPerMinute)", label: "words per minute", icon: "speedometer")
                    StatTile(value: "\(stats.currentStreak)", label: stats.currentStreak == 1 ? "day streak" : "day streak", icon: "flame")
                }
                .frame(width: 210)
            }

            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Try it here").font(.system(size: 15, weight: .semibold))
                        Text("Click in the box, hold \(app.settings.hotkey.label), say something in English or Hinglish, then let go.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                }
                TextEditor(text: $tryText)
                    .font(.system(size: 14))
                    .frame(height: 66)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.35)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardStroke))
            }

            HStack {
                Text("History").font(.title3.weight(.semibold))
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $search).textFieldStyle(.plain).frame(width: 180)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Theme.cardFill))
            }

            if groups.isEmpty {
                Card {
                    Text(history.items.isEmpty ? "Your dictations will show up here." : "No matches.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                }
            } else {
                ForEach(groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title.uppercased())
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.8)
                        VStack(spacing: 0) {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { Divider().padding(.leading, 86) }
                                HistoryRow(item: item) { history.delete(item) }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.cardFill))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.cardStroke))
                    }
                }
            }
        }
    }

    private var groups: [(title: String, items: [HistoryItem])] {
        let filtered = search.isEmpty ? history.items : history.items.filter {
            $0.text.localizedCaseInsensitiveContains(search) || $0.raw.localizedCaseInsensitiveContains(search)
        }
        let calendar = Calendar.current
        var result: [(String, [HistoryItem])] = []
        for item in filtered.prefix(300) {
            let title: String
            if calendar.isDateInToday(item.date) { title = "Today" }
            else if calendar.isDateInYesterday(item.date) { title = "Yesterday" }
            else { title = item.date.formatted(.dateTime.weekday(.wide).day().month(.wide)) }
            if result.last?.0 == title { result[result.count - 1].1.append(item) } else { result.append((title, [item])) }
        }
        return result.map { (title: $0.0, items: $0.1) }
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    let onDelete: () -> Void
    @State private var hovering = false
    @State private var showOriginal = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(item.date.formatted(.dateTime.hour().minute()))
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(showOriginal ? item.raw : item.text)
                    .textSelection(.enabled)
                    .foregroundStyle(showOriginal ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    if item.kind == .transform || item.transform != nil {
                        badge(item.transform ?? "Transform", systemImage: "wand.and.rays")
                    }
                    if let app = item.app { Text(app).font(.caption).foregroundStyle(.tertiary) }
                    if showOriginal { Text(item.kind == .transform ? "original text" : "what the model heard").font(.caption).foregroundStyle(.tertiary) }
                }
            }
            HStack(spacing: 2) {
                iconButton(copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                if item.raw != item.text {
                    iconButton(showOriginal ? "eye.slash" : "arrow.left.arrow.right", help: "Show before / after") { showOriginal.toggle() }
                }
                iconButton("trash", help: "Delete", action: onDelete)
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func badge(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Theme.saffron.opacity(0.15)))
            .foregroundStyle(Theme.saffron)
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}
