import AppKit
import SwiftUI

final class OverlayModel: ObservableObject {
    enum Phase: Equatable { case idle, listening(handsFree: Bool), thinking, message(String) }

    @Published var phase: Phase = .idle
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 22)
    @Published var listeningSince = Date()
    @Published var showBar = true
    /// Pointer x inside the panel while hovering, nil when away (drives the dock magnification).
    @Published var hoverX: CGFloat?

    // Actions from the dock and the hands-free stop button.
    var onDictate: () -> Void = {}
    var onStop: () -> Void = {}
    var onPasteLast: () -> Void = {}
    var onPolish: () -> Void = {}
    var onOpen: () -> Void = {}
    var onMoveTo: (BarPosition) -> Void = { _ in }
    var onHideBar: () -> Void = {}

    func push(level rms: Float) {
        // Map speech RMS (~0.003–0.15) onto 0…1 with a log curve so quiet speech still moves the bars.
        let db = 20 * log10(max(rms, 1e-5))
        let normalized = CGFloat(min(max((db + 58) / 42, 0), 1))
        levels.removeFirst()
        levels.append(normalized)
    }
}

/// Where the bar sits. `.custom` is wherever the user dragged it.
enum BarPosition: String, CaseIterable, Identifiable {
    case left, center, right, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .left: return "Bottom left"
        case .center: return "Bottom centre"
        case .right: return "Bottom right"
        case .custom: return "Where I dragged it"
        }
    }
}

/// The floating bar at the bottom of the screen: a slim handle that opens into a small dock on hover,
/// and becomes the recording capsule while dictating.
final class OverlayController {
    let model = OverlayModel()
    private let size = NSSize(width: 420, height: 120)
    private let defaults = UserDefaults.standard

    var position: BarPosition {
        get { BarPosition(rawValue: defaults.string(forKey: "barPosition") ?? "") ?? .center }
        set { defaults.set(newValue.rawValue, forKey: "barPosition"); reposition() }
    }

    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = FirstMouseHostingView(rootView: OverlayView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        panel.ignoresMouseEvents = true
        return panel
    }()
    private var mouseMonitors: [Any] = []
    private var pressStart: (mouse: NSPoint, origin: NSPoint)?
    private var isDragging = false

    /// Watches the pointer: the panel only takes clicks while the pointer is over the bar itself.
    private func installMouseMonitors() {
        guard mouseMonitors.isEmpty else { return }
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in self?.updateHover() }) { mouseMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moves.union([.leftMouseDown, .leftMouseUp]), handler: { [weak self] event in
            self?.handleLocal(event) ?? event
        }) { mouseMonitors.append(m) }
    }

    // Bar geometry inside the panel (matches OverlayView's bottom-aligned layout).
    private func screenRect(width: CGFloat, bottom: CGFloat, height: CGFloat) -> NSRect {
        NSRect(x: panel.frame.midX - width / 2, y: panel.frame.minY + bottom, width: width, height: height)
    }
    private var handleZone: NSRect { screenRect(width: 58, bottom: 14, height: 9).insetBy(dx: -10, dy: -8) }
    private var dockZone: NSRect { screenRect(width: 236, bottom: 4, height: 70) }
    private var capsuleZone: NSRect { screenRect(width: 320, bottom: 6, height: 54) }

    private func updateHover() {
        let mouse = NSEvent.mouseLocation
        var accept = false
        switch model.phase {
        case .idle where model.showBar:
            let zone = (model.hoverX != nil || isDragging) ? dockZone : handleZone
            if zone.contains(mouse) || isDragging {
                accept = true
                let x = mouse.x - panel.frame.minX
                if model.hoverX != x { model.hoverX = x }
            } else if model.hoverX != nil {
                model.hoverX = nil
            }
        case .listening(true):
            accept = capsuleZone.contains(mouse) || isDragging
        default:
            if model.hoverX != nil { model.hoverX = nil }
        }
        if panel.ignoresMouseEvents == accept { panel.ignoresMouseEvents = !accept }
    }

    /// Drag the bar by any part of it; a press that doesn't move stays a normal click.
    private func handleLocal(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .mouseMoved:
            updateHover()
            return event
        case .leftMouseDown where event.window === panel:
            pressStart = (NSEvent.mouseLocation, panel.frame.origin)
            isDragging = false
            return event
        case .leftMouseDragged where pressStart != nil:
            guard let start = pressStart, let frame = currentScreenFrame else { return event }
            let mouse = NSEvent.mouseLocation
            if !isDragging, hypot(mouse.x - start.mouse.x, mouse.y - start.mouse.y) < 4 { return event }
            isDragging = true
            panel.setFrameOrigin(clamped(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                                 y: start.origin.y + mouse.y - start.mouse.y), in: frame))
            updateHover()
            return nil
        case .leftMouseUp where pressStart != nil:
            pressStart = nil
            guard isDragging else { return event }
            isDragging = false
            savePosition()
            updateHover()
            return nil
        default:
            if event.type == .leftMouseDragged { updateHover() }
            return event
        }
    }

    /// Shows the idle bar (if enabled) at the bottom of the screen the pointer is on.
    func start(showBar: Bool) {
        model.showBar = showBar
        installMouseMonitors()
        reposition()
        panel.orderFrontRegardless()
        updateMouseHandling()
    }

    func setShowBar(_ show: Bool) {
        model.showBar = show
        updateMouseHandling()
    }

    func show(_ phase: OverlayModel.Phase) {
        if case .listening(let handsFree) = phase {
            if case .listening = model.phase {} else {
                model.levels = Array(repeating: 0, count: model.levels.count)
                model.listeningSince = Date()
            }
            if handsFree, case .listening(false) = model.phase { model.listeningSince = model.listeningSince }
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { model.phase = phase }
        reposition()
        panel.orderFrontRegardless()
        updateMouseHandling()
    }

    func flash(_ message: String) {
        show(.message(message))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            if case .message = self?.model.phase { self?.hide() }
        }
    }

    func hide() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { model.phase = .idle }
        updateMouseHandling()
    }

    /// PNG of the overlay's current state on a dark backdrop (used by `--snapshot`).
    func render() -> Data? {
        let host = NSHostingView(rootView: OverlayView(model: model).background(Color(white: 0.16)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private var currentScreenFrame: NSRect? {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        return screen?.visibleFrame
    }

    /// Places the bar for the chosen position on the screen the pointer is on (custom = same relative spot).
    private func reposition() {
        guard !isDragging, let frame = currentScreenFrame else { return }
        let centerX: CGFloat, bottom: CGFloat
        switch position {
        case .left: centerX = frame.minX + 130; bottom = frame.minY + 4
        case .center: centerX = frame.midX; bottom = frame.minY + 4
        case .right: centerX = frame.maxX - 130; bottom = frame.minY + 4
        case .custom:
            centerX = frame.minX + frame.width * CGFloat(defaults.object(forKey: "barX") as? Double ?? 0.5)
            bottom = frame.minY + CGFloat(defaults.object(forKey: "barY") as? Double ?? 4)
        }
        panel.setFrameOrigin(clamped(NSPoint(x: centerX - size.width / 2, y: bottom), in: frame))
    }

    /// Keeps the visible bar on screen (the panel itself is wider than the bar, so it may overhang a little).
    private func clamped(_ origin: NSPoint, in frame: NSRect) -> NSPoint {
        let overhang = size.width / 2 - 110
        return NSPoint(x: min(max(origin.x, frame.minX - overhang), frame.maxX - size.width + overhang),
                       y: min(max(origin.y, frame.minY), frame.maxY - size.height))
    }

    /// Remembers where the user dragged the bar (relative to the screen, so it survives display changes).
    private func savePosition() {
        guard let frame = currentScreenFrame else { return }
        let origin = panel.frame.origin
        defaults.set(Double((origin.x + size.width / 2 - frame.minX) / frame.width), forKey: "barX")
        defaults.set(Double(origin.y - frame.minY), forKey: "barY")
        defaults.set(BarPosition.custom.rawValue, forKey: "barPosition")
    }

    /// Re-evaluates whether the panel should take clicks right now.
    private func updateMouseHandling() {
        updateHover()
    }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Views

private enum Glow {
    static let saffron = Color(red: 1.0, green: 0.58, blue: 0.2)
    static let rose = Color(red: 0.96, green: 0.33, blue: 0.48)
    static let gradient = LinearGradient(colors: [saffron, rose], startPoint: .bottom, endPoint: .top)
}

/// Dark glass: system blur under a black tint, hairline border and a faint top highlight.
private struct GlassCapsule: View {
    var body: some View {
        ZStack {
            VisualEffectBlur()
            Color.black.opacity(0.62)
        }
        .clipShape(Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(
            LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
    }
}

private struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            content
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            if model.showBar { DockBar(model: model).transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom))) }
        case .listening(let handsFree):
            ListeningCapsule(model: model, handsFree: handsFree)
                .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
        case .thinking:
            ThinkingCapsule().transition(.opacity)
        case .message(let text):
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background(GlassCapsule())
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

/// Collapsed: a slim glowing handle. Hovered: a small dock whose icons magnify under the pointer.
private struct DockBar: View {
    @ObservedObject var model: OverlayModel

    private struct Item { let icon: String; let label: String; let action: () -> Void }
    private var items: [Item] {
        [Item(icon: "mic.fill", label: "Dictate hands-free", action: model.onDictate),
         Item(icon: "doc.on.clipboard", label: "Paste last dictation", action: model.onPasteLast),
         Item(icon: "wand.and.stars", label: "Polish selection", action: model.onPolish),
         Item(icon: "waveform", label: "Open Dictator", action: model.onOpen)]
    }
    private let base: CGFloat = 26, spacing: CGFloat = 14, panelWidth: CGFloat = 420

    var body: some View {
        let expanded = model.hoverX != nil
        Group {
            if expanded {
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(items.indices, id: \.self) { i in icon(i) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(GlassCapsule())
                .transition(.scale(scale: 0.4, anchor: .bottom).combined(with: .opacity))
            } else {
                Capsule()
                    .fill(Color.black.opacity(0.55))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.6))
                    .overlay(Capsule().fill(Glow.gradient).frame(width: 18, height: 2.5).opacity(0.9))
                    .frame(width: 58, height: 9)
                    .shadow(color: Glow.saffron.opacity(0.25), radius: 6)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: expanded)
        .contextMenu {
            ForEach([BarPosition.left, .center, .right]) { p in Button("Move to \(p.label.lowercased())") { model.onMoveTo(p) } }
            Divider()
            Button("Hide the bar") { model.onHideBar() }
        }
        .help("Drag to move · right-click for options")
    }

    private func center(_ i: Int) -> CGFloat {
        let totalWidth = CGFloat(items.count) * base + CGFloat(items.count - 1) * spacing
        return (panelWidth - totalWidth) / 2 + CGFloat(i) * (base + spacing) + base / 2
    }

    /// Dock-style magnification: icons near the pointer grow, with a smooth falloff.
    private func scale(_ i: Int) -> CGFloat {
        guard let x = model.hoverX else { return 1 }
        let d = x - center(i)
        return 1 + 0.55 * exp(-(d * d) / (2 * 38 * 38))
    }

    /// Only the icon nearest the pointer shows its name.
    private var labelled: Int? {
        guard let x = model.hoverX else { return nil }
        let nearest = items.indices.min { abs(center($0) - x) < abs(center($1) - x) }
        return nearest.flatMap { abs(center($0) - x) < base + spacing ? $0 : nil }
    }

    private func icon(_ i: Int) -> some View {
        let s = scale(i)
        let item = items[i]
        return Button(action: item.action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8 * s, style: .continuous)
                    .fill(i == 0 ? AnyShapeStyle(LinearGradient(colors: [Glow.saffron, Glow.rose], startPoint: .topLeading, endPoint: .bottomTrailing))
                                 : AnyShapeStyle(Color.white.opacity(0.1)))
                Image(systemName: item.icon)
                    .font(.system(size: 12.5 * s, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
            }
            .frame(width: base * s, height: base * s)
            .overlay(alignment: .top) {
                if labelled == i {
                    Text(item.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .fixedSize()
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                        .offset(y: -30)
                        .transition(.opacity)
                }
            }
        }
        .buttonStyle(.plain)
        .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.75), value: s)
    }
}

private struct ListeningCapsule: View {
    @ObservedObject var model: OverlayModel
    let handsFree: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            if handsFree {
                Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Glow.rose)
            } else {
                Circle().fill(Glow.saffron).frame(width: 7, height: 7)
                    .shadow(color: Glow.saffron, radius: pulse ? 6 : 2)
                    .scaleEffect(pulse ? 1.15 : 0.85)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
            }
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(model.levels.indices, id: \.self) { i in
                    Capsule()
                        .fill(Glow.gradient)
                        .frame(width: 2.6, height: 3 + model.levels[i] * 20)
                }
            }
            .frame(height: 24)
            .shadow(color: Glow.saffron.opacity(0.55), radius: 6)
            .animation(.easeOut(duration: 0.09), value: model.levels)
            if handsFree {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let s = Int(context.date.timeIntervalSince(model.listeningSince))
                    Text(String(format: "%d:%02d", s / 60, s % 60))
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                }
                Button(action: model.onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .help("Finish dictation")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(GlassCapsule())
    }
}

private struct ThinkingCapsule: View {
    @State private var sweep = false

    var body: some View {
        ZStack {
            Capsule().fill(Color.white.opacity(0.08)).frame(width: 96, height: 3)
            Capsule()
                .fill(LinearGradient(colors: [.clear, Glow.saffron, Glow.rose, .clear], startPoint: .leading, endPoint: .trailing))
                .frame(width: 44, height: 3)
                .offset(x: sweep ? 34 : -34)
                .shadow(color: Glow.saffron.opacity(0.8), radius: 5)
                .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: sweep)
        }
        .frame(width: 132, height: 42)
        .background(GlassCapsule())
        .onAppear { sweep = true }
    }
}
