import AppKit
import AVFoundation
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case setup, dictation, insights, transforms, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .setup: return "Setup"
        case .dictation: return "Dictation"
        case .insights: return "Insights"
        case .transforms: return "Transforms"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .setup: return "sparkles"
        case .dictation: return "mic"
        case .insights: return "chart.bar.xaxis"
        case .transforms: return "wand.and.rays"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - Theme (dark only)

enum Theme {
    static let saffron = Color(red: 1.0, green: 0.56, blue: 0.16)
    static let rose = Color(red: 0.96, green: 0.33, blue: 0.47)
    static let gradient = LinearGradient(colors: [saffron, rose], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let canvas = Color(red: 0.035, green: 0.035, blue: 0.04)
    static let sidebar = Color(red: 0.055, green: 0.055, blue: 0.06)
    static let cardFill = Color.white.opacity(0.035)
    static let cardStroke = Color.white.opacity(0.08)
    static let border = LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom)
    static let muted = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.32)
}

/// Near-black canvas lit by two soft glows.
struct AppBackground: View {
    var body: some View {
        ZStack {
            Theme.canvas
            RadialGradient(colors: [Theme.saffron.opacity(0.16), .clear], center: UnitPoint(x: 0.92, y: -0.05), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Theme.rose.opacity(0.07), .clear], center: UnitPoint(x: 0.1, y: 1.05), startRadius: 0, endRadius: 480)
        }
        .ignoresSafeArea()
    }
}

/// Glass card with a hairline gradient border. `glow` adds a warm light in one corner.
struct Card<Content: View>: View {
    var padding: CGFloat = 22
    var glow = false
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CardSurface(glow: glow))
    }
}

struct CardSurface: View {
    var glow = false
    var radius: CGFloat = 20
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.cardFill)
            .overlay {
                if glow {
                    RadialGradient(colors: [Theme.saffron.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: 320)
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.8))
    }
}

struct PageHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 34, weight: .semibold))
                .tracking(-0.6)
            if let subtitle {
                Text(subtitle).font(.system(size: 14)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.bottom, 8)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(Theme.saffron.opacity(0.9))
    }
}

struct StatTile: View {
    let value: String
    let label: String
    var icon: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.saffron)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.saffron.opacity(0.12)))
            }
            Text(value)
                .font(.system(size: 36, weight: .light))
                .tracking(-1)
                .monospacedDigit()
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardSurface())
    }
}

/// Bars for recent days; today's (or the hovered) bar glows with its value.
struct GlowBarChart: View {
    let values: [(label: String, value: Int)]
    @State private var hovered: Int?

    var body: some View {
        let top = max(values.map(\.value).max() ?? 1, 1)
        let focus = hovered ?? (values.count - 1)
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(values.indices, id: \.self) { i in
                let v = values[i].value
                let isFocus = i == focus
                VStack(spacing: 8) {
                    ZStack(alignment: .top) {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(isFocus ? AnyShapeStyle(LinearGradient(colors: [Theme.saffron, Theme.rose.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                                          : AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom)))
                            .frame(height: max(8, 120 * CGFloat(v) / CGFloat(top)))
                            .shadow(color: isFocus ? Theme.saffron.opacity(0.55) : .clear, radius: 14)
                        if isFocus {
                            Text(formatCount(v))
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Capsule().fill(Color.black.opacity(0.6)))
                                .offset(y: -24)
                        }
                    }
                    .frame(height: 130, alignment: .bottom)
                    Text(values[i].label)
                        .font(.system(size: 10.5, weight: isFocus ? .semibold : .regular))
                        .foregroundStyle(isFocus ? Theme.saffron : Theme.faint)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onHover { hovered = $0 ? i : (hovered == i ? nil : hovered) }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovered)
    }
}

extension Stats {
    /// Words per day for the last `days` days, oldest first.
    func recentDays(_ days: Int) -> [(label: String, value: Int)] {
        let cal = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = days > 7 ? "d" : "EEE"
        return (0..<days).reversed().map { offset in
            let date = cal.date(byAdding: .day, value: -offset, to: Date())!
            return (formatter.string(from: date), data.wordsByDay[Stats.dayFormatter.string(from: date)] ?? 0)
        }
    }
}

/// Polls permission state, which macOS doesn't notify about.
final class PermissionWatcher: ObservableObject {
    @Published var microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published var accessibility = Paster.hasAccessibility
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            let ax = Paster.hasAccessibility
            if mic != self.microphone { self.microphone = mic }
            if ax != self.accessibility { self.accessibility = ax }
        }
    }

    deinit { timer?.invalidate() }

    func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        } else {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    func requestAccessibility() {
        Paster.requestAccessibility()
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// Clears a stale Accessibility entry (left by an older build) and asks again.
    func resetAccessibility() {
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "app.dictator.Dictator"]
        try? reset.run()
        reset.waitUntilExit()
        requestAccessibility()
    }

    private func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}

func formatCount(_ n: Int) -> String {
    switch n {
    case ..<1_000: return "\(n)"
    case ..<1_000_000: return String(format: n < 10_000 ? "%.1fK" : "%.0fK", Double(n) / 1_000)
    default: return String(format: "%.1fM", Double(n) / 1_000_000)
    }
}

// MARK: - Window shell

struct MainView: View {
    @ObservedObject var app: AppController
    @StateObject private var permissions = PermissionWatcher()
    @State private var hoveredPage: Page?

    private var setupComplete: Bool {
        app.speech != .notInstalled && permissions.microphone && permissions.accessibility
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
            ScrollView {
                content
                    .padding(.horizontal, 44)
                    .padding(.top, 48)
                    .padding(.bottom, 40)
                    .frame(maxWidth: 940, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
        }
        .tint(Theme.saffron)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .frame(minWidth: 860, minHeight: 580)
        .environmentObject(permissions)
    }

    @ViewBuilder private var content: some View {
        switch app.page {
        case .setup: SetupPage(app: app)
        case .dictation: DictationPage(app: app, history: app.history, stats: app.stats)
        case .insights: InsightsPage(stats: app.stats)
        case .transforms: TransformsPage(app: app, store: app.configStore)
        case .settings: SettingsPage(app: app, settings: app.settings, store: app.configStore, downloader: app.downloader)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.gradient)
                    .frame(width: 32, height: 32)
                    .overlay(Image(systemName: "waveform").font(.system(size: 15, weight: .bold)).foregroundStyle(.white))
                    .shadow(color: Theme.saffron.opacity(0.45), radius: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Dictator").font(.system(size: 17, weight: .semibold))
                    Text("On-device dictation").font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 40)
            .padding(.bottom, 26)

            if !setupComplete || app.page == .setup { navButton(.setup) }
            ForEach([Page.dictation, .insights, .transforms, .settings]) { navButton($0) }
            Spacer()
            statusFooter
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 18)
        .frame(width: 222)
        .background(Theme.sidebar)
    }

    private func navButton(_ page: Page) -> some View {
        let selected = app.page == page
        let hovered = hoveredPage == page
        return Button { app.page = page } label: {
            HStack(spacing: 12) {
                Image(systemName: page.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(page.title).font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                Spacer()
                if page == .setup && !setupComplete {
                    Circle().fill(Theme.rose).frame(width: 7, height: 7).shadow(color: Theme.rose, radius: 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.saffron.opacity(0.22), Theme.saffron.opacity(0.06)], startPoint: .leading, endPoint: .trailing))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.saffron.opacity(0.25), lineWidth: 0.7))
                } else if hovered {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.05))
                }
            }
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.62))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredPage = $0 ? page : (hoveredPage == page ? nil : hoveredPage) }
        .animation(.easeOut(duration: 0.15), value: hovered)
    }

    private var statusFooter: some View {
        let (color, text): (Color, String) = {
            switch app.speech {
            case .ready: return (.green, "Ready")
            case .loading: return (Theme.saffron, "Preparing models…")
            case .downloading: return (Theme.saffron, "Downloading…")
            case .notInstalled: return (Theme.rose, "Setup needed")
            case .failed: return (.red, "Model error")
            }
        }()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 7, height: 7).shadow(color: color, radius: 4)
                Text(text).font(.system(size: 12, weight: .medium))
            }
            Text("Hold \(app.settings.hotkey.label) to talk").font(.system(size: 11)).foregroundStyle(Theme.faint)
            Text("AI cleanup: \(app.llmStatus)").font(.system(size: 11)).foregroundStyle(Theme.faint).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardSurface(radius: 14))
    }
}
