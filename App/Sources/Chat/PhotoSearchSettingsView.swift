import Photos
import PiAppleTools
import SwiftUI
import UIKit

/// Settings › Photo Search (docs/adr/0010-photo-search.md): how much of the library the on-device index covers, and
/// indexing now, stopping, or deleting the index. Builds without the model in the app download it here
/// (`ClipModelDownload`).
struct PhotoSearchSettingsView: View {
    @State private var status: PhotoIndex.Status?
    @State private var download: ClipModelDownload.State?
    @State private var confirmDelete = false
    @State private var confirmRemoveModel = false
    /// Built into the app by scripts/fetch-mobileclip.sh: nothing to download or remove.
    private let bundled = ClipModelFiles.bundled() != nil

    var body: some View {
        Form {
            Section {
                if let status {
                    LabeledContent("Model", value: model(status))
                    LabeledContent("Photos Access", value: access)
                    LabeledContent("Indexed") {
                        if let total = status.total {
                            Text("\(status.indexed.formatted()) of \(total.formatted())")
                        } else {
                            Text(status.indexed.formatted())
                        }
                    }
                    if let total = status.total, total > 0, status.indexed < total {
                        ProgressView(value: Double(status.indexed), total: Double(total))
                    }
                } else {
                    ProgressView()
                }
            } footer: {
                Text("Ask Pi to find a photo by what it shows, like \u{201C}the whiteboard from Tuesday\u{201D}. Pi indexes your photos on this iPhone, while the app is open and overnight while it charges. Pi's model only gets the matches' dates; you see the photos.")
            }

            if !bundled, let download {
                modelSection(download)
            }

            if let status {
                Section {
                    if !status.authorized {
                        Button("Allow Photos Access") {
                            Task {
                                _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                                await PhotoIndex.shared.startIndexing()
                                await refresh()
                            }
                        }
                    } else if status.running {
                        Button("Stop Indexing") { Task { await PhotoIndex.shared.stop(); await refresh() } }
                    } else {
                        Button("Index Now") { Task { await PhotoIndex.shared.startIndexing(); await refresh() } }
                            .disabled(!status.modelInstalled)
                    }
                    Button("Delete Index", role: .destructive) { confirmDelete = true }
                        .disabled(status.indexed == 0)
                }
            }
        }
        .navigationTitle("Photo Search")
        .confirmationDialog("Delete the photo index?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Index", role: .destructive) { Task { try? await PhotoIndex.shared.deleteIndex(); await refresh() } }
        } message: {
            Text("Your photos stay as they are. Pi indexes them again the next time it searches.")
        }
        .confirmationDialog("Remove the model?", isPresented: $confirmRemoveModel, titleVisibility: .visible) {
            Button("Remove Model", role: .destructive) {
                Task {
                    await PhotoIndex.shared.unloadModel()
                    try? await ClipModelDownload.shared.remove()
                    await refresh()
                }
            }
        } message: {
            Text("Photo search stops working until you download it again. The index is kept.")
        }
        .task {
            // Progress while the page is open.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var access: String {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: "All Photos"
        case .limited: "Selected Photos"
        case .notDetermined: "Not asked yet"
        default: "Not allowed"
        }
    }

    @ViewBuilder
    private func modelSection(_ download: ClipModelDownload.State) -> some View {
        Section {
            switch download {
            case .notDownloaded, .failed:
                Button("Download Model (\(size(ClipModelDownload.totalBytes)))") { Task { await install() } }
            case let .downloading(received, total), let .waitingForWiFi(received, total):
                ProgressView(value: Double(received), total: Double(total))
                Button("Cancel Download", role: .cancel) { Task { await ClipModelDownload.shared.cancel() } }
            case .installing:
                ProgressView()
            case .installed:
                Button("Remove Model", role: .destructive) { confirmRemoveModel = true }
            }
        } footer: {
            switch download {
            case let .failed(message):
                Text("The download stopped: \(message) Downloading again keeps what already arrived.")
            case .installed:
                Text("MobileCLIP-S2 runs on this iPhone. Removing it frees \(size(ClipModelDownload.totalBytes)).")
            default:
                Text("Photo search needs MobileCLIP-S2 from Hugging Face, downloaded once over Wi-Fi. It goes on while you use other apps; Pi installs it the next time it’s open.")
            }
        }
    }

    private func model(_ status: PhotoIndex.Status) -> String {
        if bundled { return "MobileCLIP, in the app" }
        switch download {
        case .installed?: return status.modelInstalled ? "MobileCLIP, downloaded" : "Can't be loaded"
        case let .downloading(received, total)?: return "Downloading \(size(received)) of \(size(total))"
        case .waitingForWiFi?: return "Waiting for Wi-Fi"
        case .installing?: return "Installing"
        case .failed?: return "Download failed"
        default: return "Not downloaded"
        }
    }

    private func size(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    /// The transfers go on in the background by themselves; the background time covers compiling if the user leaves
    /// just then. Then starts indexing.
    private func install() async {
        let background = BackgroundTime("MobileCLIP download")
        defer { background.end() }
        do {
            try await ClipModelDownload.shared.install()
            await PhotoIndex.shared.startIndexing()
        } catch {}
        await refresh()
    }

    private func refresh() async {
        if !bundled { download = await ClipModelDownload.shared.state() }
        status = await PhotoIndex.shared.status()
    }
}

/// Time iOS gives a suspended app to finish something, ended once, by us or when it runs out.
@MainActor
private final class BackgroundTime {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
