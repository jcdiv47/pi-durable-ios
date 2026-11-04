import SwiftUI

/// The agent's scheduled tasks (`schedule_task`), across conversations: when each runs next, Run now, and Cancel.
struct SchedulesView: View {
    let store: ChatStore
    @Binding var path: [Route]
    @State private var running: Int?

    var body: some View {
        List {
            ForEach(store.schedules) { schedule in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(schedule.name).font(.headline)
                        Spacer()
                        Text(schedule.every).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(schedule.prompt).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                    if let next = schedule.next {
                        Label {
                            Text("Next \(next, format: .relative(presentation: .named))")
                        } icon: {
                            Image(systemName: "clock")
                        }
                        .font(.caption)
                    }
                    if let answer = schedule.lastAnswer, !answer.isEmpty, let last = schedule.lastRun {
                        Text("\(last, format: .relative(presentation: .named)): \(answer)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    HStack {
                        Button("Open conversation") { path.append(.conversation(schedule.conversationId)) }
                        Spacer()
                        Button {
                            running = schedule.taskId
                            Task {
                                _ = try? await store.runSchedule(schedule.name, requestId: UUID().uuidString)
                                running = nil
                            }
                        } label: {
                            if running == schedule.taskId { ProgressView().controlSize(.small) } else { Text("Run now") }
                        }
                        .disabled(running != nil)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                }
                .padding(.vertical, 2)
                .swipeActions {
                    Button("Cancel", systemImage: "xmark", role: .destructive) { Task { await store.cancelSchedule(schedule) } }
                }
            }
        }
        .overlay {
            if store.schedules.isEmpty {
                ContentUnavailableView {
                    Label("No Scheduled Tasks", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Pi can do things later, or on a timetable, even while the app is closed.")
                } actions: {
                    Button("Ask Pi", systemImage: "square.and.pencil") {
                        Task { await store.compose("Every morning at 8, ") }
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        }
        .navigationTitle("Scheduled Tasks")
        .refreshable { await store.refreshSchedules() }
        .task { await store.refreshSchedules() }
    }
}
