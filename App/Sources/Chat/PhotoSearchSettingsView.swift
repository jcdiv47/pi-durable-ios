import Photos
import PiAppleTools
import SwiftUI

/// Settings › Photo Search (docs/adr/0010-photo-search.md): how much of the library the on-device index covers, and
/// indexing now, stopping, or deleting the index.
struct PhotoSearchSettingsView: View {
    @State private var status: PhotoIndex.Status?
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section {
                if let status {
                    LabeledContent("Model", value: status.modelInstalled ? "MobileCLIP, on device" : "Not in this build")
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
                } footer: {
                    if !status.modelInstalled {
                        Text("Build Pi after running scripts/fetch-mobileclip.sh to include the model.")
                    }
                }
            }
        }
        .navigationTitle("Photo Search")
        .confirmationDialog("Delete the photo index?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Index", role: .destructive) { Task { try? await PhotoIndex.shared.deleteIndex(); await refresh() } }
        } message: {
            Text("Your photos stay as they are. Pi indexes them again the next time it searches.")
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

    private func refresh() async {
        status = await PhotoIndex.shared.status()
    }
}
