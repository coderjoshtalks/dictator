import SwiftUI

struct SetupPage: View {
    @ObservedObject var app: AppController
    @ObservedObject private var downloader: ModelDownloader
    @EnvironmentObject var permissions: PermissionWatcher
    @State private var tryText = ""

    init(app: AppController) {
        self.app = app
        self.downloader = app.downloader
    }

    private var defaultLLM: LLMModelInfo { LLMModelInfo.catalog[0] }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Welcome to Dictator",
                       subtitle: "Speak English or Hinglish in any app and get clean text — all on your Mac, no account, no subscription.")

            step(1, "Download the speech models", done: app.speech != .notInstalled && app.speech != .downloading && Paths.englishModelInstalled) {
                Text("Two Whisper models that run on your Mac: one tuned for Hinglish, one for pure English. Dictator picks the right one each time. \(mb(Assets.speechModelBytes)), one time.")
                    .font(.callout).foregroundStyle(.secondary)
                speechStatus
                if app.speech == .ready && !Paths.englishModelInstalled && !downloader.isDownloading("speech") {
                    HStack {
                        Text("Add the English model for about half the errors on pure English (\(mb(Assets.speechEnglish.reduce(0) { $0 + $1.size }))).")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Download") { Task { await app.installSpeechModel() } }.disabled(downloader.isBusy)
                    }
                }
            }

            step(2, "Download the AI cleanup model (recommended)", done: defaultLLM.installed) {
                Text("Removes “um”s, applies “no wait, I mean…” corrections, punctuates, and powers Transforms. \(defaultLLM.sizeMB) MB. You can skip this and use rules only.")
                    .font(.callout).foregroundStyle(.secondary)
                if let progress = downloader.progress[defaultLLM.id] {
                    ProgressView(value: progress) { Text("Downloading… \(Int(progress * 100))%").font(.caption) }
                } else if !defaultLLM.installed {
                    HStack {
                        Button("Download") { Task { await app.installLLM(defaultLLM) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(downloader.isBusy)
                        if let error = downloader.errors[defaultLLM.id] { Text(error).font(.caption).foregroundStyle(.red) }
                    }
                }
            }

            step(3, "Allow the microphone", done: permissions.microphone) {
                PermissionRow(title: "Microphone", detail: "Dictator only listens while you hold the dictation key.",
                              granted: permissions.microphone, action: permissions.requestMicrophone)
            }

            step(4, "Allow Accessibility", done: permissions.accessibility) {
                PermissionRow(title: "Accessibility", detail: "Lets Dictator type into other apps. Turn on “Dictator” in the list that opens.",
                              granted: permissions.accessibility, action: permissions.requestAccessibility)
                if !permissions.accessibility {
                    HStack(alignment: .top) {
                        Text("Dictator is already switched on in the list but still shows as not allowed? That entry is from an older version. Reset it, then switch Dictator on again.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset & re-add", action: permissions.resetAccessibility)
                    }
                }
            }

            step(5, "Pick your dictation key", done: true) {
                Picker("Hold to talk", selection: Binding(get: { app.settings.hotkey }, set: { app.settings.hotkey = $0 })) {
                    ForEach(Hotkey.allCases) { Text($0.label).tag($0) }
                }
                .frame(maxWidth: 320)
                if app.settings.hotkey == .fn {
                    Text("Using fn? In System Settings › Keyboard set “Press 🌐 key to” → “Do Nothing” so it doesn't open emoji.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            step(6, "Try it", done: false) {
                Text("Click in the box, hold \(app.settings.hotkey.label), say “kal ki meeting 5 baje hai, no wait, 6 baje”, and let go.")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $tryText)
                    .frame(height: 60)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.cardStroke))
            }

            HStack {
                Spacer()
                Button("Done") { app.page = .dictation }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(app.speech == .notInstalled || app.speech == .downloading)
            }
        }
    }

    @ViewBuilder private var speechStatus: some View {
        switch app.speech {
        case .notInstalled:
            HStack {
                Button("Download") { Task { await app.installSpeechModel() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(downloader.isBusy)
                if let error = downloader.errors["speech"] { Text(error).font(.caption).foregroundStyle(.red) }
            }
        case .downloading:
            ProgressView(value: downloader.progress["speech"] ?? 0) {
                Text("Downloading… \(Int((downloader.progress["speech"] ?? 0) * 100))%").font(.caption)
            }
        case .loading:
            ProgressView { Text("Optimizing for your Mac's Neural Engine — the first time takes about 3 minutes.").font(.caption) }
        case .ready:
            Label("Installed and ready", systemImage: "checkmark").foregroundStyle(.green)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, done: Bool, @ViewBuilder content: () -> Content) -> some View {
        Card {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(done ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.cardFill)).frame(width: 28, height: 28)
                    if done { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white) }
                    else { Text("\(number)").font(.callout.weight(.semibold)) }
                }
                Text(title).font(.headline)
            }
            content()
        }
    }

    private func mb(_ bytes: Int64) -> String { "\(bytes / 1_000_000) MB" }
}
