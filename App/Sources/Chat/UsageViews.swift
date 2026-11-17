import SwiftUI

/// Token counts and costs as the chat writes them.
enum UsageFormat {
    /// "1,234" below ten thousand, "48K" and "1.2M" above.
    static func tokens(_ count: Double) -> String {
        count < 10_000 ? Int(count).formatted() : count.formatted(.number.notation(.compactName).precision(.significantDigits(2...3)))
    }

    /// Dollars, with cents down to "<$0.01" and fractions of a cent shown as that.
    static func cost(_ dollars: Double) -> String {
        if dollars > 0 && dollars < 0.01 { return "<$0.01" }
        return dollars.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    /// A model's name from its `provider/modelId` key, as the picker shows it when the model is still listed.
    @MainActor static func modelName(_ key: String, store: ChatStore) -> String {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return key }
        return store.modelName(ModelRef(provider: parts[0], modelId: parts[1]))
    }
}

/// Under the transcript: what the conversation has used, what it cost, and how full its context is.
/// Nothing until a model has answered with usage. Cost shows only when the model has prices (the offline and Apple
/// models have none).
struct ConversationUsageFooter: View {
    let usage: UsageTotals
    let contextWindow: Double?

    var body: some View {
        if !parts.isEmpty {
            VStack(spacing: 6) {
                Text(parts.joined(separator: " · "))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                // How full the context is, at a glance; orange and red as it nears the window.
                if let contextShare {
                    PiMeter(value: contextShare).frame(width: 64)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityIdentifier("conversation.usage")
        }
    }

    private var tokens: Double { usage.input + usage.output }

    private var contextShare: Double? {
        guard let context = usage.context, let contextWindow, contextWindow > 0 else { return nil }
        return min(context / contextWindow, 1)
    }

    private var parts: [String] {
        guard tokens > 0 else { return [] }
        var parts = ["\(UsageFormat.tokens(tokens)) tokens"]
        if usage.cost > 0 { parts.append(UsageFormat.cost(usage.cost)) }
        if let contextShare, let contextWindow {
            parts.append("\(contextShare.formatted(.percent.precision(.fractionLength(0)))) of \(UsageFormat.tokens(contextWindow)) context")
        }
        return parts
    }

    private var accessibilityText: String {
        var text = "Used \(Int(usage.input).formatted()) tokens in and \(Int(usage.output).formatted()) out"
        if usage.cost > 0 { text += ", about \(UsageFormat.cost(usage.cost))" }
        if let contextShare { text += ". Context \(contextShare.formatted(.percent.precision(.fractionLength(0)))) full" }
        return text
    }
}

/// Settings › Usage: what the model answers of a month cost, across conversations, and by model.
struct UsageSettingsView: View {
    @Bindable var store: ChatStore
    /// Months back from this one: 0 is this month.
    @State private var monthsBack = 0
    @State private var totals: SpendTotals?
    @State private var loading = true

    static func month(_ monthsBack: Int, from now: Date = .now) -> DateInterval {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .month, value: -monthsBack, to: calendar.dateInterval(of: .month, for: now)!.start)!
        return calendar.dateInterval(of: .month, for: start)!
    }

    private var interval: DateInterval { Self.month(monthsBack) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Cost", value: totals.map { UsageFormat.cost($0.cost) } ?? "—")
                LabeledContent("Tokens Sent", value: totals.map { UsageFormat.tokens($0.input) } ?? "—")
                LabeledContent("Tokens Received", value: totals.map { UsageFormat.tokens($0.output) } ?? "—")
                LabeledContent("Conversations", value: totals.map { "\($0.conversations)" } ?? "—")
            } header: {
                HStack {
                    Text(interval.start.formatted(.dateTime.month(.wide).year()))
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                }
            } footer: {
                Text("Costs are estimates from each model's list prices; models without prices count tokens only. Archived conversations count, deleted ones don't. Tokens sent include cached ones.")
            }
            .monospacedDigit()
            if let totals, !totals.models.isEmpty {
                Section("By Model") {
                    ForEach(totals.models, id: \.model) { model in
                        LabeledContent {
                            Text(model.cost > 0 ? UsageFormat.cost(model.cost) : "\(UsageFormat.tokens(model.input + model.output)) tokens")
                                .monospacedDigit()
                        } label: {
                            Text(UsageFormat.modelName(model.model, store: store))
                            Text("\(UsageFormat.tokens(model.input)) in · \(UsageFormat.tokens(model.output)) out").monospacedDigit()
                        }
                    }
                }
            }
        }
        .navigationTitle("Usage")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Earlier Month", systemImage: "chevron.left") { monthsBack += 1 }
                Button("Later Month", systemImage: "chevron.right") { monthsBack -= 1 }
                    .disabled(monthsBack == 0)
            }
        }
        .task(id: monthsBack) {
            loading = true
            let found = await store.spending(interval)
            guard !Task.isCancelled else { return }
            totals = found
            loading = false
        }
        .refreshable { totals = await store.spending(interval) }
    }
}
