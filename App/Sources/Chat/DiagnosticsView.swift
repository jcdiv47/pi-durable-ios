import SwiftUI

struct DiagnosticsView: View {
    @Bindable var store: ChatStore
    @State private var filter = "all"

    private var entries: [DiagnosticsLog.Entry] {
        let all = store.diagnostics.entries.reversed()
        return filter == "all" ? Array(all) : all.filter { $0.level == "error" || $0.level == "warn" }
    }

    var body: some View {
        List {
            Section {
                if store.tasks.isEmpty {
                    Text("No live tasks").foregroundStyle(.secondary)
                }
                ForEach(store.tasks) { task in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(task.kind).font(.subheadline.monospaced())
                            Spacer()
                            Text(task.reason.map { "blocked: \($0)" } ?? task.state)
                                .font(.caption)
                                .foregroundStyle(task.state == "blocked" ? .orange : .secondary)
                        }
                        Text("Task \(task.id)" + (task.conversationId.map { " · \(conversationTitle($0))" } ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let error = task.error {
                            Text(error).font(.caption2).foregroundStyle(.red).lineLimit(3)
                        }
                    }
                    .swipeActions {
                        Button("Abort", role: .destructive) { Task { await store.abortTask(task) } }
                    }
                }
            } header: {
                Text("Tasks")
            } footer: {
                Text("A task the process keeps dying in ends after five restarts in a row. Abort ends a task now.")
            }

            Section {
                Picker("Show", selection: $filter) {
                    Text("All").tag("all")
                    Text("Problems").tag("problems")
                }
                .pickerStyle(.segmented)
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: icon(entry.level)).foregroundStyle(color(entry.level))
                            Text(entry.category).font(.caption.weight(.semibold))
                            Spacer()
                            Text(entry.date, format: .dateTime.month().day().hour().minute().second()).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(entry.message).font(.caption.monospaced()).textSelection(.enabled).lineLimit(8)
                    }
                }
            } header: {
                Text("Log")
            }
        }
        .navigationTitle("Diagnostics")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Refresh tasks", systemImage: "arrow.clockwise") { Task { await store.refreshTasks() } }
                    Button("Clear log", systemImage: "trash", role: .destructive) { store.diagnostics.clear() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .refreshable { await store.refreshTasks() }
        .task { await store.refreshTasks() }
    }

    private func conversationTitle(_ id: Int) -> String {
        store.meta(id)?.title ?? "conversation \(id)"
    }

    private func icon(_ level: String) -> String {
        switch level {
        case "error": "xmark.octagon.fill"
        case "warn": "exclamationmark.triangle.fill"
        default: "info.circle"
        }
    }

    private func color(_ level: String) -> Color {
        switch level {
        case "error": .red
        case "warn": .orange
        default: .secondary
        }
    }
}
