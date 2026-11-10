import PiRuntime
import SwiftUI

/// Settings › Apple Intelligence: whether the on-device model can run, the
/// `apple/on-device` model in the picker, and the cheap jobs it does for the app.
struct IntelligenceSettingsView: View {
    @Bindable var store: ChatStore

    var body: some View {
        Form {
            Section {
                LabeledContent("On-Device Model") {
                    Text(store.intelligenceStatus == .available ? "Ready" : "Unavailable")
                        .foregroundStyle(store.intelligenceStatus == .available ? .green : .secondary)
                }
            } footer: {
                Text(store.intelligenceStatus.explanation)
            }

            Section {
                Toggle("Conversation Titles", isOn: $store.intelligenceTitles)
                    .accessibilityIdentifier("intelligence.titles")
                Toggle("Notification Summaries", isOn: $store.intelligenceSummaries)
                    .accessibilityIdentifier("intelligence.summaries")
            } header: {
                Text("On This iPhone")
            } footer: {
                Text("New conversations get a short title, and when a long answer finishes while you're away, its notification shows a summary. Both run on the device. When the model is unavailable, Pi uses the first line instead.")
            }
            .disabled(store.intelligenceStatus != .available)

            Section {
                if let model = store.models.first(where: { $0.provider == "apple" }) {
                    LabeledContent(model.name) {
                        Text("\(Int(model.contextWindow).formatted()) tokens")
                    }
                } else {
                    Text("Not available on this iPhone right now.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Chat Model")
            } footer: {
                Text("Choose it in a conversation's model picker for private answers that work offline. It has no tools: it can't read your calendar or health data, search the web or make widgets. Switch the conversation to a cloud model for those.")
            }
        }
        .navigationTitle("Apple Intelligence")
        .task { await store.applyIntelligence() }
    }
}
