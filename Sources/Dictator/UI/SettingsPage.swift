import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsPage: View {
    @ObservedObject var app: AppController
    @ObservedObject var settings: Settings
    @ObservedObject var store: ConfigStore
    @ObservedObject var downloader: ModelDownloader
    @EnvironmentObject var permissions: PermissionWatcher

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Settings")
            dictationCard
            CleanupCard(app: app, settings: settings, store: store)
            PlaygroundCard(app: app, settings: settings, store: store)
            modelCard
            dictionaryCard
            permissionsCard
            aboutCard
        }
    }

    // MARK: Dictation

    private var dictationCard: some View {
        Card {
            Text("Dictation").font(.headline)
            Picker("Hold to talk", selection: $settings.hotkey) {
                ForEach(Hotkey.allCases) { Text($0.label).tag($0) }
            }
            if settings.hotkey == .fn {
                Text("Tip: in System Settings › Keyboard, set “Press 🌐 key to” → “Do Nothing”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Recognition", selection: $settings.recognition) {
                ForEach(RecognitionMode.allCases) { Text($0.label).tag($0) }
            }
            if !Paths.englishModelInstalled {
                Text("The English model isn't installed, so everything uses the Hinglish model. Get it from Setup.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Picker("Microphone", selection: $settings.microphoneUID) {
                Text("System default").tag("")
                ForEach(AudioDevices.inputs()) { Text($0.name).tag($0.uid) }
            }
            if AudioDevices.isBluetooth(uid: settings.microphoneUID) {
                Text("Bluetooth headsets (like AirPods) switch to a low-quality call mode while recording, which costs accuracy. Your Mac's built-in microphone is usually more accurate — you can keep listening on the headset.")
                    .font(.caption).foregroundStyle(Theme.saffron)
            }
            Toggle("Sounds when recording starts, stops and locks", isOn: $settings.sounds)
            Toggle("Show the Dictator bar", isOn: $settings.showBar)
            Picker("Bar position", selection: Binding(get: { app.barPosition }, set: { app.barPosition = $0 })) {
                ForEach(BarPosition.allCases) { Text($0.label).tag($0) }
            }
            Text("Tip: drag the bar anywhere on screen, or right-click it to snap it left, centre or right.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Learn from my corrections (adds fixed words to the dictionary)", isOn: $settings.learnFromEdits)
            Toggle("Launch Dictator at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
            Toggle("Keep the last recording for troubleshooting", isOn: $settings.keepLastRecording)
            Text("Shortcuts: ⌃⌥V pastes your last dictation.").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Model

    private var modelCard: some View {
        Card {
            HStack {
                Text("AI model").font(.headline)
                Spacer()
                Text(app.llmStatus).font(.callout).foregroundStyle(app.llmStatus == "Running" ? .green : .secondary)
            }
            Text("Runs locally with llama.cpp on your Mac's GPU. Used for cleanup and transforms.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(LLMModelInfo.catalog) { model in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: store.config.modelID == model.id ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(store.config.modelID == model.id ? Theme.saffron : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name).fontWeight(.medium)
                        Text("\(model.note) \(model.sizeMB >= 1000 ? String(format: "%.1f GB", Double(model.sizeMB) / 1000) : "\(model.sizeMB) MB")")
                            .font(.caption).foregroundStyle(.secondary)
                        if let error = downloader.errors[model.id] {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                    Spacer()
                    if let progress = downloader.progress[model.id] {
                        ProgressView(value: progress).frame(width: 120)
                    } else if model.installed {
                        Button(store.config.modelID == model.id ? "In use" : "Use") { store.config.modelID = model.id }
                            .disabled(store.config.modelID == model.id)
                    } else {
                        Button("Download") { Task { await app.installLLM(model) } }
                            .disabled(downloader.isBusy)
                    }
                }
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: store.config.modelID == LLMModelInfo.customID ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(store.config.modelID == LLMModelInfo.customID ? Theme.saffron : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your own GGUF model").fontWeight(.medium)
                    Text(store.config.customModelPath.isEmpty ? "Any llama.cpp-compatible chat model." : store.config.customModelPath)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
                    if panel.runModal() == .OK, let url = panel.url {
                        store.config.customModelPath = url.path
                        store.config.modelID = LLMModelInfo.customID
                    }
                }
            }
        }
    }

    // MARK: Dictionary

    private var dictionaryCard: some View {
        Card {
            Text("Dictionary").font(.headline)
            Text("Names, products and jargon Dictator should get right — one per line. Use “heard -> Written” to always replace a word.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $settings.dictionaryText)
                .font(.system(.callout, design: .monospaced))
                .frame(height: 110)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.cardStroke))
        }
    }

    // MARK: Permissions & about

    private var permissionsCard: some View {
        Card {
            Text("Permissions").font(.headline)
            PermissionRow(title: "Microphone", detail: "To hear you while you hold the key.", granted: permissions.microphone,
                          action: permissions.requestMicrophone)
            PermissionRow(title: "Accessibility", detail: "To type into other apps and read the text around your cursor.",
                          granted: permissions.accessibility, action: permissions.requestAccessibility)
        }
    }

    private var aboutCard: some View {
        Card {
            Text("About").font(.headline)
            Text("Dictator \(Bundle.main.shortVersion) — on-device dictation for English and Hinglish. Your voice and text never leave this Mac.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Show data folder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.root]) }
                if let notices = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") {
                    Button("Open-source licenses") { NSWorkspace.shared.open(notices) }
                }
            }
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(granted ? .green : Theme.rose)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Allow…", action: action) }
        }
    }
}

// MARK: - Cleanup (prompt, examples, parameters)

private struct CleanupCard: View {
    @ObservedObject var app: AppController
    @ObservedObject var settings: Settings
    @ObservedObject var store: ConfigStore
    @State private var editingLevel: CleanupLevel = .light
    @State private var showPrompt = false

    var body: some View {
        Card {
            Text("AI cleanup").font(.headline)
            Picker("Cleanup level", selection: $store.config.level) {
                ForEach(CleanupLevel.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(store.config.level.summary).font(.callout).foregroundStyle(.secondary)

            Toggle("Use the text around your cursor as context (better capitalization and continuity)", isOn: $store.config.useScreenContext)
            HStack {
                Text("Creativity (temperature)")
                Slider(value: $store.config.temperature, in: 0...1, step: 0.05)
                Text(String(format: "%.2f", store.config.temperature)).monospacedDigit().frame(width: 40)
            }
            Picker("Safety check on AI output", selection: $store.config.guardLevel) {
                ForEach(GuardLevel.allCases) { Text($0.label).tag($0) }
            }
            Text("If the model answers your question, translates, or rewrites too much, Dictator falls back to the rule-based cleanup. Strict catches more; Off trusts the model.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()
            DisclosureGroup(isExpanded: $showPrompt) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Edit level", selection: $editingLevel) {
                        Text("Light").tag(CleanupLevel.light)
                        Text("Medium").tag(CleanupLevel.medium)
                    }
                    .pickerStyle(.segmented)
                    Text("Placeholders: {{dictionary}} your words · {{app}} the app you're typing in · {{context}} text before the cursor. Remove one to stop sending it.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: promptBinding)
                        .font(.system(.callout, design: .monospaced))
                        .frame(height: 230)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.cardStroke))

                    Text("Examples (what you say → what should be typed)").font(.subheadline.weight(.medium))
                    ForEach(examplesBinding) { $example in
                        HStack(alignment: .top, spacing: 8) {
                            TextField("Spoken", text: $example.input, axis: .vertical).textFieldStyle(.roundedBorder)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary).padding(.top, 6)
                            TextField("Typed", text: $example.output, axis: .vertical).textFieldStyle(.roundedBorder)
                            Button { examplesBinding.wrappedValue.removeAll { $0.id == example.id } } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary).padding(.top, 5)
                        }
                    }
                    HStack {
                        Button { examplesBinding.wrappedValue.append(Example(input: "", output: "")) } label: {
                            Label("Add example", systemImage: "plus")
                        }
                        Spacer()
                        Button("Reset \(editingLevel.label) to default") { store.resetPrompt(for: editingLevel) }
                            .buttonStyle(.link)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("Edit the prompt and examples").fontWeight(.medium)
            }
        }
    }

    private var promptBinding: Binding<String> {
        Binding(get: { store.config.prompt(for: editingLevel) },
                set: { store.config.prompts[editingLevel.rawValue] = $0 })
    }

    private var examplesBinding: Binding<[Example]> {
        Binding(get: { store.config.examples(for: editingLevel) },
                set: { store.config.examples[editingLevel.rawValue] = $0 })
    }
}

// MARK: - Playground

private struct PlaygroundCard: View {
    @ObservedObject var app: AppController
    @ObservedObject var settings: Settings
    @ObservedObject var store: ConfigStore
    @State private var input = "um so kal ki meeting 5 baje hai no wait 6 baje hai please sab log time pe aa jana"
    @State private var appName = ""
    @State private var result: RefineResult?
    @State private var running = false
    @State private var showPrompt = false

    var body: some View {
        Card {
            Text("Cleanup playground").font(.headline)
            Text("Type what a raw transcript looks like and see exactly what your current settings produce.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $input)
                .font(.callout)
                .frame(height: 60)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.cardStroke))
            HStack {
                TextField("Pretend app (e.g. Slack)", text: $appName).textFieldStyle(.roundedBorder).frame(width: 220)
                Spacer()
                Button(running ? "Running…" : "Run cleanup") { run() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(running || input.isEmpty)
            }
            if let result {
                VStack(alignment: .leading, spacing: 8) {
                    row("Result", result.text, highlight: true)
                    if let out = result.llmOutput {
                        row(result.llmAccepted == true ? "Model output (used)" : "Model output (rejected by safety check)", out)
                    }
                    if let error = result.llmError { row("Model error", error) }
                    if result.llmOutput == nil && result.llmError == nil && store.config.level != .none {
                        row("Note", "The AI model isn't running (\(app.llmStatus)), so only rules were applied.")
                    }
                    Text(String(format: "%.2f s · %d fixes", result.seconds, result.fixes)).font(.caption).foregroundStyle(.secondary)
                    if let prompt = result.renderedPrompt {
                        DisclosureGroup("Exact prompt sent to the model", isExpanded: $showPrompt) {
                            Text(prompt).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    private func row(_ label: String, _ text: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(highlight ? Theme.saffron.opacity(0.1) : Theme.cardFill))
        }
    }

    private func run() {
        running = true
        let request = RefineRequest(raw: input, config: store.config, dictionary: settings.dictionary,
                                    appName: appName.isEmpty ? nil : appName)
        Task {
            result = await Refiner.refine(request, llm: app.llm)
            running = false
        }
    }
}
