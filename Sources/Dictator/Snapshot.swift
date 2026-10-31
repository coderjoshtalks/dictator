import AppKit
import SwiftUI

/// `Dictator --snapshot <folder>` renders each page off-screen to PNG (for checking the design without screen recording).
enum Snapshot {
    @MainActor
    static func run(to folder: String) {
        _ = NSApplication.shared
        let app = AppController()
        for page in Page.allCases {
            app.page = page
            let view = NSHostingView(rootView: MainView(app: app))
            view.frame = NSRect(x: 0, y: 0, width: 1000, height: 720)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(page.rawValue).png"))
        }
        // The floating bar in each state (blur doesn't render off-screen, so it sits on a dark backdrop here).
        let overlay = OverlayController()
        overlay.model.levels = (0..<22).map { CGFloat(0.25 + 0.7 * abs(sin(Double($0) * 0.7))) }
        let states: [(String, OverlayModel.Phase, CGFloat?)] = [
            ("bar-idle", .idle, nil), ("bar-hover", .idle, 205), ("pill-listening", .listening(handsFree: false), nil),
            ("pill-handsfree", .listening(handsFree: true), nil), ("pill-thinking", .thinking, nil), ("pill-message", .message("Learned “Arena”"), nil),
        ]
        for (name, phase, hover) in states {
            overlay.model.phase = phase
            overlay.model.hoverX = hover
            if let image = overlay.render() {
                try? image.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
            }
        }
    }
}
