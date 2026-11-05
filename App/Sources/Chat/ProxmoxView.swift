import SwiftUI

/// The Proxmox page (`Route.proxmox`, `pidurable://proxmox`, the list's More menu): the node, its backups and its guests
/// as the chat's cards draw them, read straight from the node without the model (`PiRuntime.proxmoxDashboard`). Refreshes
/// every 30 seconds while it's on screen, and on pull. A guest's context menu asks Pi about it.
struct ProxmoxView: View {
    @Bindable var store: ChatStore
    @Binding var path: [Route]
    @State private var dashboard: PveDashboard?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        Group {
            if store.proxmox == nil {
                ContentUnavailableView {
                    Label("No Proxmox Node", systemImage: "server.rack")
                } description: {
                    Text("Add your Proxmox VE node in Settings to see it here, and so Pi can read it.")
                } actions: {
                    Button("Open Settings") { path.append(.settings) }
                        .buttonStyle(.glassProminent)
                }
            } else {
                content
            }
        }
        .navigationTitle("Proxmox")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Ask Pi", systemImage: "square.and.pencil") {
                    Task { await store.compose("How is my Proxmox node doing? ") }
                }
            }
        }
        .task(id: store.proxmox) {
            guard store.proxmox != nil else { return }
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error {
                    errorBanner(error)
                }
                if let dashboard {
                    PveOverviewCard(value: dashboard.overview, full: true)
                    PveBackupsCard(value: dashboard.backups, full: true)
                    PveGuestsCard(value: dashboard.guests, full: true)
                    Text("Updated \(Pve.date(dashboard.overview.at), format: .dateTime.hour().minute().second()) · read-only token")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                } else if error == nil {
                    ProgressView("Reading the node…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .refreshable { await load() }
        .animation(.snappy, value: error)
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(dashboard == nil ? "Couldn't read the node" : "Couldn't refresh", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Button("Try Again") { Task { await load() } }
                    .buttonStyle(.glass)
                    .disabled(loading)
                if message.contains("Settings") {
                    Button("Open Settings") { path.append(.settings) }
                        .buttonStyle(.glass)
                }
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 22))
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            dashboard = try await store.proxmoxDashboard()
            error = nil
        } catch {
            self.error = Self.message(error)
        }
    }

    /// JS errors arrive as "Error: …"; the page shows the sentence.
    private static func message(_ error: Error) -> String {
        let text = String(describing: error)
        return text.hasPrefix("Error: ") ? String(text.dropFirst(7)) : text
    }
}
