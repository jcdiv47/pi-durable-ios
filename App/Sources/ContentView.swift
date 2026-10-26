import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var keyDraft = ""
    @State private var prompt = "In about 150 words, explain why an AI agent running on a phone needs to survive being killed."

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    Text(model.status).accessibilityIdentifier("status")
                    if model.mode != .chat { Text("Mode: \(model.mode.rawValue)").foregroundStyle(.secondary) }
                }
                if model.mode == .chat {
                    keySection
                    Section("Prompt") {
                        TextField("Prompt", text: $prompt, axis: .vertical)
                        Button(model.busy ? "Streaming…" : "Send") {
                            Task { await model.send(prompt) }
                        }
                        .disabled(model.busy || !model.ready || !model.hasKey || prompt.isEmpty)
                    }
                    Section("Response") {
                        if model.thinkingChars > 0 {
                            Text("Thought for \(model.thinkingChars) characters").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(model.streamed.isEmpty ? "—" : model.streamed)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("response")
                        if let result = model.lastResult {
                            Text(result).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Pi Durable · M0")
        }
    }

    @ViewBuilder private var keySection: some View {
        Section("\(model.providerName) API key") {
            if model.hasKey {
                Label("Stored in the Keychain", systemImage: "key.fill")
                Button("Remove key", role: .destructive) { model.removeKey() }
            } else {
                SecureField("sk-…", text: $keyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save to Keychain") {
                    model.saveKey(keyDraft)
                    keyDraft = ""
                }
                .disabled(keyDraft.isEmpty)
            }
        }
    }
}
