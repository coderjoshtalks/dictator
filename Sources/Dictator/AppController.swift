import AppKit
import AVFoundation
import Combine
import SwiftUI
import WhisperKit

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    enum SpeechState: Equatable {
        case notInstalled, downloading, loading, ready, failed(String)
    }

    let settings = Settings()
    let configStore = ConfigStore()
    let history = History()
    let stats = Stats()
    let downloader = ModelDownloader()

    @Published private(set) var speech: SpeechState = .notInstalled
    @Published private(set) var llmStatus = "Off"
    @Published var page: Page = .dictation

    let llm = LLMEngine()
    private let speechEngine = SpeechEngine()
    /// One pipeline per dictation, so a new one can start while the previous is still being processed.
    private var pipeline: DictationPipeline?
    /// Pastes happen in the order the dictations were spoken.
    private var deliveryChain: Task<Void, Never>?
    private var postRoll = false
    private let learner = Learner()
    private var segmentTimer: Timer?
    private var recordingStarted = Date()
    private static let maxRecording: TimeInterval = 20 * 60
    private let recorder = AudioRecorder()
    private let overlay = OverlayController()
    private let hotkey = HotkeyMonitor()
    private let shortcuts = GlobalShortcuts()
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    private var context = FocusContext()
    private var busy = false
    private var accessibilityTrusted = Paster.hasAccessibility
    private var permissionTimer: Timer?

    var config: RefinementConfig { configStore.config }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launched \(Bundle.main.shortVersion); mic \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue), accessibility \(Paster.hasAccessibility)")
        setUpStatusItem()
        // Startup self-check: does work scheduled onto the main thread actually run?
        DispatchQueue.main.async { Log.write("self-check: main dispatch queue OK") }
        Task { @MainActor in Log.write("self-check: main-actor task OK") }
        RunLoop.main.perform { Log.write("self-check: main run loop OK") }

        recorder.onLevel = { [weak self] level in self?.overlay.model.push(level: level) }
        overlay.model.onDictate = { [weak self] in self?.startHandsFreeFromBar() }
        overlay.model.onStop = { [weak self] in
            self?.hotkey.reset()
            self?.finishRecording()
        }
        overlay.model.onPasteLast = { [weak self] in self?.pasteLast() }
        overlay.model.onPolish = { [weak self] in
            guard let self else { return }
            let transforms = self.configStore.activeTransforms
            guard let polish = transforms.first(where: { $0.name.lowercased() == "polish" }) ?? transforms.first else {
                self.overlay.flash("Turn on Transforms first")
                return
            }
            Task { await self.runTransform(polish) }
        }
        overlay.model.onOpen = { [weak self] in self?.showWindow() }
        overlay.model.onMoveTo = { [weak self] position in self?.overlay.position = position }
        overlay.model.onHideBar = { [weak self] in self?.settings.showBar = false }
        overlay.start(showBar: settings.showBar)
        settings.$showBar.dropFirst().sink { [weak self] in self?.overlay.setShowBar($0) }.store(in: &cancellables)
        hotkey.hotkey = settings.hotkey
        hotkey.onAction = { [weak self] action in
            Log.write("hotkey action: \(action)")
            Task { @MainActor in self?.handle(action) }
        }
        hotkey.start()
        // Key monitors installed before Accessibility is granted stay deaf, so re-arm them the moment it is.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let trusted = Paster.hasAccessibility
                if trusted != self.accessibilityTrusted {
                    self.accessibilityTrusted = trusted
                    Log.write("accessibility changed: \(trusted)")
                    if trusted { self.hotkey.start() }
                }
            }
        }

        settings.$hotkey.dropFirst().sink { [weak self] in self?.hotkey.hotkey = $0; self?.rebuildMenu() }.store(in: &cancellables)
        configStore.$config.dropFirst()
            .removeDuplicates { $0.modelID == $1.modelID && $0.customModelPath == $1.customModelPath && $0.level == $1.level
                && $0.transformsEnabled == $1.transformsEnabled && $0.transforms == $1.transforms }
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.registerShortcuts(); self?.applyLLM() }
            }
            .store(in: &cancellables)
        registerShortcuts()

        if Paths.speechModelInstalled {
            Task { await loadSpeechModel() }
        }
        learner.isIgnored = { [weak self] in self?.settings.isIgnored($0) ?? false }
        learner.onLearn = { [weak self] heard, corrected in
            guard let self, self.settings.learnFromEdits else { return }
            self.settings.learn(heard: heard, corrected: corrected)
            self.overlay.flash("Learned “\(corrected)”")
            Log.write("learned a correction (\(heard.count) → \(corrected.count) chars)")
        }
        if !Paths.speechModelInstalled || !Paster.hasAccessibility || AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            page = .setup
            showWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        llm.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    // MARK: Models

    func installSpeechModel() async {
        let wasReady = speech == .ready
        if !wasReady { speech = .downloading }
        let ok = await downloader.download(Assets.speechModels, into: Paths.models, key: "speech")
        if ok {
            if wasReady { try? await speechEngine.load() } else { await loadSpeechModel() }
        } else if !wasReady {
            speech = Paths.speechModelInstalled ? .ready : .notInstalled
        }
        objectWillChange.send()
    }

    private func loadSpeechModel() async {
        speech = .loading
        rebuildMenu()
        let started = Date()
        do {
            try await speechEngine.load()
            Log.write(String(format: "speech model loaded in %.1fs", Date().timeIntervalSince(started)))
            speech = .ready
            if let path = UserDefaults.standard.string(forKey: "selfTestAudio") {
                Task { try? await Task.sleep(nanoseconds: 3_000_000_000); await self.runSelfTest(audioPath: path) }
            }
        } catch {
            Log.write("speech model failed: \(error.localizedDescription)")
            speech = .failed(error.localizedDescription)
        }
        rebuildMenu()
        applyLLM()
    }

    /// Hidden stability test (`defaults write app.dictator.Dictator selfTestAudio /path/to.wav`): runs dictations through
    /// the real pipeline from a file (no mic, no paste), cycles every page and every bar state, logs, then quits.
    private func runSelfTest(audioPath: String) async {
        Log.write("self-test: starting")
        guard let audio = try? AudioProcessor.loadAudioAsFloatArray(fromPath: audioPath) else { Log.write("self-test: can't read audio"); return }
        // The real microphone path (audio is discarded): open, record 1.5 s, close — three times.
        for i in 1...3 {
            let t0 = Date()
            recorder.start(deviceUID: settings.microphoneUID) { error in Log.write("self-test mic \(i) failed: \(error.localizedDescription)") }
            overlay.show(.listening(handsFree: false))
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let captured: [Float] = await withCheckedContinuation { cont in recorder.stop { cont.resume(returning: $0) } }
            overlay.hide()
            Log.write(String(format: "self-test mic %d: %.1fs captured, cycle took %.2fs", i, Double(captured.count) / 16_000, Date().timeIntervalSince(t0)))
        }
        showWindow()
        for page in Page.allCases + Page.allCases {
            self.page = page
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        for run in 1...3 {
            overlay.show(.listening(handsFree: run == 2))
            let pipeline = DictationPipeline(engine: speechEngine, llm: llm)
            pipeline.begin(.init(config: config, dictionary: settings.dictionary, recognition: settings.recognition, appName: "Self-test", contextBefore: nil))
            var fed = 0
            while fed < audio.count {
                try? await Task.sleep(nanoseconds: 250_000_000)
                fed = min(audio.count, fed + Voice.sampleRate / 4)
                for i in 0..<4 { overlay.model.push(level: Float(0.02 * Double(i + 1))) }
                let available = fed
                pipeline.tick(totalSamples: available) { range in Array(audio[range.clamped(to: 0..<available)]) }
            }
            overlay.show(.thinking)
            let t0 = Date()
            let result = await pipeline.finish(audio: audio)
            Log.write(String(format: "self-test run %d: %.2fs after release, %d chars, %@", run, Date().timeIntervalSince(t0), result.text.count, result.engine))
            overlay.flash("Self-test \(run) done")
            try? await Task.sleep(nanoseconds: 600_000_000)
            overlay.hide()
        }
        for x in stride(from: 100, through: 320, by: 20) { overlay.model.hoverX = CGFloat(x); try? await Task.sleep(nanoseconds: 60_000_000) }
        overlay.model.hoverX = nil
        UserDefaults.standard.removeObject(forKey: "selfTestAudio")
        Log.write("self-test: finished without crashing")
        NSApp.terminate(nil)
    }

    func installLLM(_ model: LLMModelInfo) async {
        let ok = await downloader.download(Assets.llmFiles(model), into: Paths.models, key: model.id)
        if ok {
            configStore.config.modelID = model.id
            applyLLM()
        }
        objectWillChange.send()
    }

    /// The LLM runs when cleanup or transforms need it and a model is installed.
    func applyLLM() {
        let needed = config.level != .none || !configStore.activeTransforms.isEmpty
        guard needed else { llm.stop(); llmStatus = "Off"; return }
        guard let model = config.modelPath, FileManager.default.fileExists(atPath: model.path) else {
            llm.stop(); llmStatus = "No model installed"; return
        }
        if llm.isRunning && llm.loadedModel == model { llmStatus = "Running"; return }
        llmStatus = "Starting…"
        Task {
            do {
                try await llm.start(model: model)
                llmStatus = "Running"
                Log.write("LLM started: \(model.lastPathComponent)")
            } catch {
                llmStatus = "Error: \(error.localizedDescription)"
                Log.write("LLM failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Dictation

    private func handle(_ action: HotkeyMonitor.Action) {
        Log.write("handling \(action)")
        switch action {
        case .start: startRecording()
        case .finish: finishRecording()
        case .cancel:
            if recorder.isRecording { Sounds.play(.cancel, enabled: settings.sounds) }
            cancelRecording()
        case .handsFree:
            if recorder.isRecording {
                overlay.show(.listening(handsFree: true))
                pipeline?.mute(from: recorder.sampleCount, seconds: 0.25)
                Sounds.play(.lock, enabled: settings.sounds)
            }
        }
    }

    private func startRecording() {
        guard !recorder.isRecording, !postRoll else {
            Log.write("hotkey press ignored: still finishing the previous recording")
            hotkey.reset()
            return
        }
        guard speech == .ready else {
            Log.write("hotkey press ignored: speech model \(speech)")
            hotkey.reset()
            overlay.flash(speech == .loading ? "Still loading…" : "Finish setup first")
            if speech != .loading { page = .setup; showWindow() }
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            Log.write("hotkey press ignored: no microphone permission")
            hotkey.reset()
            overlay.flash("Allow microphone access")
            page = .setup
            showWindow()
            return
        }
        Log.write("start: opening microphone")
        // The mic opens on a background queue; the pill and sound appear immediately.
        recorder.start(deviceUID: settings.microphoneUID) { [weak self] _ in
            guard let self else { return }
            self.segmentTimer?.invalidate()
            self.pipeline?.cancel()
            self.pipeline = nil
            self.hotkey.reset()
            self.overlay.flash("Microphone unavailable")
        }
        overlay.show(.listening(handsFree: false))
        Sounds.play(.start, enabled: settings.sounds)
        Log.write("start: reading text around the cursor")
        context = config.useScreenContext ? FocusContext.capture() : FocusContext(appName: NSWorkspace.shared.frontmostApplication?.localizedName)
        Log.write("start: recording")
        recordingStarted = Date()
        let pipeline = DictationPipeline(engine: speechEngine, llm: llm)
        self.pipeline = pipeline
        pipeline.begin(.init(config: config, dictionary: settings.dictionary, recognition: settings.recognition,
                             appName: context.appName, contextBefore: context.textBefore))
        // Process finished phrases in the background while the user keeps talking.
        segmentTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.recorder.isRecording else { return }
                self.pipeline?.tick(totalSamples: self.recorder.sampleCount) { self.recorder.samples(in: $0) }
                let elapsed = Date().timeIntervalSince(self.recordingStarted)
                if elapsed >= Self.maxRecording {
                    self.hotkey.reset()
                    self.finishRecording()
                } else if elapsed >= Self.maxRecording - 60, Int(elapsed * 2) % 20 == 0 {
                    self.overlay.flash("1 minute left in this dictation")
                    self.overlay.show(.listening(handsFree: true))
                }
            }
        }
    }

    /// The mic button on the bar: start a hands-free dictation (finish with the hotkey or the stop button).
    private func startHandsFreeFromBar() {
        startRecording()
        guard recorder.isRecording else { return }
        hotkey.beginHandsFree()
        overlay.show(.listening(handsFree: true))
    }

    private func cancelRecording() {
        segmentTimer?.invalidate()
        pipeline?.cancel()
        pipeline = nil
        recorder.stop { _ in }
        overlay.hide()
    }

    private func finishRecording() {
        guard recorder.isRecording, !postRoll else { return }
        // Keep listening for a moment after the key is released: people let go while saying the last word.
        postRoll = true
        overlay.show(.thinking)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.postRoll = false
            self?.transcribeRecording()
        }
    }

    private func transcribeRecording() {
        guard recorder.isRecording, let pipeline else { return }
        self.pipeline = nil
        segmentTimer?.invalidate()
        let released = Date()
        recorder.stop { [weak self] audio in
            Sounds.play(.stop, enabled: self?.settings.sounds ?? false)   // after the mic is off, so it can't be transcribed
            self?.process(audio, with: pipeline, released: released)
        }
    }

    private func process(_ audio: [Float], with pipeline: DictationPipeline, released: Date) {
        let seconds = Double(audio.count) / Double(Transcriber.sampleRate)
        if settings.keepLastRecording { AudioRecorder.writeWAV(audio, to: Paths.lastRecording) }

        // Too short or no speech at all (judged against the room's noise, so whispers still count).
        guard seconds >= 0.35, Voice.hasSpeech(audio) else {
            Log.write(String(format: "skipped: %.2fs, no speech detected (rms %.4f)", seconds, AudioRecorder.rms(audio)))
            pipeline.cancel()
            overlay.hide()
            return
        }

        overlay.show(.thinking)
        let ctx = context
        let config = self.config
        let autoTransform = configStore.activeTransforms.first { $0.id == config.autoTransformID }

        let previous = deliveryChain
        deliveryChain = Task {
            let result = await pipeline.finish(audio: audio)
            await previous?.value
            var text = result.text
            guard !text.isEmpty else {
                Log.write(String(format: "nothing recognised in %.1fs of audio", seconds))
                if !recorder.isRecording { overlay.hide() }
                return
            }
            if let autoTransform, llm.isRunning, let transformed = try? await Refiner.transform(text, with: autoTransform, temperature: config.temperature, llm: llm), !transformed.isEmpty {
                text = transformed
            }
            if !recorder.isRecording { overlay.hide() }
            deliver(Self.spaced(text, after: ctx.textBefore))
            if settings.learnFromEdits { learner.watch(pasted: text) }
            let wait = Date().timeIntervalSince(released) + 0.3

            let words = text.split(whereSeparator: \.isWhitespace).count
            history.add(HistoryItem(date: Date(), raw: result.raw, text: text, app: ctx.appName, seconds: seconds,
                                    transform: autoTransform?.name, cleanup: config.level.label, engine: result.engine))
            stats.recordDictation(words: words, seconds: seconds, fixes: result.fixes, app: ctx.appName)
            Log.write(String(format: "dictation: %.1fs → %d words in %.2fs after release, %@ model, cleanup %@%@", seconds, words, wait,
                             result.engine, config.level.label, result.llmRejected ? " (some LLM output rejected, used rules)" : ""))
        }
    }

    /// Adds a leading space when continuing right after a word.
    static func spaced(_ text: String, after before: String?) -> String {
        guard let last = before?.last, !last.isWhitespace, !"([{\"'“‘/@#".contains(last),
              let first = text.first, !",.!?;:)".contains(first) else { return text }
        return " " + text
    }

    private func deliver(_ text: String) {
        if Paster.hasAccessibility {
            Paster.paste(text)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            overlay.flash("Copied — allow Accessibility to auto-paste")
        }
    }

    // MARK: Transforms

    private func registerShortcuts() {
        shortcuts.unregisterAll()
        shortcuts.register(GlobalShortcuts.pasteLast) { [weak self] in self?.pasteLast() }
        for (index, transform) in configStore.activeTransforms.enumerated() {
            shortcuts.register(GlobalShortcuts.transformSlots[index]) { [weak self] in
                Task { await self?.runTransform(transform) }
            }
        }
        rebuildMenu()
    }

    func runTransform(_ transform: Transform) async {
        guard !busy else { return }
        guard llm.isRunning else { overlay.flash("AI model isn't running"); return }
        var selection = FocusContext.capture().selectedText
        if selection == nil { selection = await Paster.copySelection() }
        guard let original = selection, !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            overlay.flash("Select some text first")
            return
        }
        busy = true
        defer { busy = false }
        overlay.show(.thinking)
        do {
            let rewritten = try await Refiner.transform(original, with: transform, temperature: config.temperature, llm: llm)
            overlay.hide()
            guard !rewritten.isEmpty else { overlay.flash("Nothing came back"); return }
            deliver(rewritten)
            history.add(HistoryItem(kind: .transform, date: Date(), raw: original, text: rewritten,
                                    app: NSWorkspace.shared.frontmostApplication?.localizedName, seconds: 0, transform: transform.name))
            stats.recordTransform()
            Log.write("transform \(transform.name): \(original.count) → \(rewritten.count) chars")
        } catch {
            overlay.flash("Transform failed")
            Log.write("transform failed: \(error.localizedDescription)")
        }
    }

    var barPosition: BarPosition {
        get { overlay.position }
        set { objectWillChange.send(); overlay.position = newValue }
    }

    @objc func pasteLast() {
        guard let last = history.items.first(where: { $0.kind == .dictation }) else { return }
        deliver(last.text)
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Dictator")
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        let state: String = {
            switch speech {
            case .ready: return "Ready — hold \(settings.hotkey.label) to talk"
            case .loading: return "Loading speech model…"
            case .downloading: return "Downloading speech model…"
            case .notInstalled: return "Setup needed"
            case .failed: return "Speech model error"
            }
        }()
        menu.addItem(withTitle: state, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        menu.addItem(item("Open Dictator", #selector(openWindow), key: "o"))
        menu.addItem(item("Paste last dictation (⌃⌥V)", #selector(pasteLast)))

        let transforms = configStore.activeTransforms
        if !transforms.isEmpty {
            let sub = NSMenu()
            for (i, t) in transforms.enumerated() {
                let entry = NSMenuItem(title: "\(t.name)  \(GlobalShortcuts.transformSlots[i].label)", action: #selector(menuTransform(_:)), keyEquivalent: "")
                entry.target = self
                entry.tag = i
                sub.addItem(entry)
            }
            let parent = NSMenuItem(title: "Transform selection", action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Dictator", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func menuTransform(_ sender: NSMenuItem) {
        let transforms = configStore.activeTransforms
        guard transforms.indices.contains(sender.tag) else { return }
        Task { await runTransform(transforms[sender.tag]) }
    }

    @objc private func openWindow() { showWindow() }

    // MARK: Window

    func showWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Dictator"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(red: 0.035, green: 0.035, blue: 0.04, alpha: 1)
            window.minSize = NSSize(width: 820, height: 560)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: MainView(app: self))
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar-only app when the window is closed.
        NSApp.setActivationPolicy(.accessory)
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
}
