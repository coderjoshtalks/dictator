import SwiftUI

struct TransformsPage: View {
    @ObservedObject var app: AppController
    @ObservedObject var store: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Transforms",
                       subtitle: "Select text in any app and press a shortcut to rewrite it in place with your own prompt. ⌘Z undoes it.")

            Card {
                Toggle(isOn: $store.config.transformsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Transforms").font(.headline)
                        Text("Shortcuts ⌃⌥1 – ⌃⌥8 follow the order of the enabled transforms below.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if store.config.transformsEnabled {
                    Divider()
                    Picker("Run after every dictation", selection: $store.config.autoTransformID) {
                        Text("Off").tag(UUID?.none)
                        ForEach(store.config.transforms.filter(\.enabled)) { t in
                            Text(t.name).tag(UUID?.some(t.id))
                        }
                    }
                    Text("Applies the chosen transform to every dictation before it's pasted. Adds a second or two.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if store.config.modelID == "qwen3-1.7b" {
                    Label("Transforms work much better with Qwen3 4B — switch in Settings › AI model. The 1.7B model is best kept for quick cleanup.",
                          systemImage: "lightbulb")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if app.llmStatus != "Running" {
                    Label("Transforms need the AI model — status: \(app.llmStatus). Install one in Settings › AI model.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
            }

            if store.config.transformsEnabled {
                ForEach($store.config.transforms) { $transform in
                    TransformCard(app: app, transform: $transform,
                                  shortcut: shortcutLabel(for: transform),
                                  onDelete: { store.config.transforms.removeAll { $0.id == transform.id } })
                }
                HStack {
                    Button {
                        store.config.transforms.append(Transform(name: "New transform", prompt: "Rewrite this text so that it…"))
                    } label: { Label("Add transform", systemImage: "plus") }
                    .disabled(store.config.transforms.count >= 8)
                    Spacer()
                    Button("Restore built-in transforms") {
                        let names = Set(store.config.transforms.map(\.name))
                        store.config.transforms += Defaults.transforms.filter { !names.contains($0.name) }
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private func shortcutLabel(for transform: Transform) -> String? {
        guard let index = store.activeTransforms.firstIndex(where: { $0.id == transform.id }) else { return nil }
        return GlobalShortcuts.transformSlots[index].label
    }
}

private struct TransformCard: View {
    @ObservedObject var app: AppController
    @Binding var transform: Transform
    let shortcut: String?
    let onDelete: () -> Void

    @State private var expanded = false
    @State private var sample = ""
    @State private var output = ""
    @State private var running = false

    var body: some View {
        Card {
            HStack(spacing: 12) {
                Toggle("", isOn: $transform.enabled).toggleStyle(.switch).labelsHidden()
                TextField("Name", text: $transform.name)
                    .textFieldStyle(.plain).font(.headline)
                Spacer()
                if let shortcut {
                    Text(shortcut).font(.callout.monospaced())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.saffron.opacity(0.15)))
                        .foregroundStyle(Theme.saffron)
                }
                Button { withAnimation { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain)
            }

            if expanded {
                Text("Prompt").font(.subheadline.weight(.medium))
                editor($transform.prompt, height: 90)
                Text("Writing samples (optional) — paste a few things you've written so the result sounds like you.")
                    .font(.subheadline.weight(.medium))
                editor($transform.samples, height: 60)

                Divider()
                Text("Test it").font(.subheadline.weight(.medium))
                editor($sample, height: 60)
                HStack {
                    Button(running ? "Running…" : "Run \(transform.name)") {
                        running = true
                        Task {
                            defer { running = false }
                            do {
                                output = try await Refiner.transform(sample, with: transform, temperature: app.config.temperature, llm: app.llm)
                            } catch {
                                output = "⚠️ \(error.localizedDescription)"
                            }
                        }
                    }
                    .disabled(running || sample.isEmpty)
                    Spacer()
                    Button("Delete transform", role: .destructive, action: onDelete).buttonStyle(.link)
                }
                if !output.isEmpty {
                    Text(output).textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.saffron.opacity(0.08)))
                }
            } else {
                Text(transform.prompt).lineLimit(2).font(.callout).foregroundStyle(.secondary)
            }
        }
        .opacity(transform.enabled ? 1 : 0.6)
    }

    private func editor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.callout)
            .frame(height: height)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.cardStroke))
    }
}
