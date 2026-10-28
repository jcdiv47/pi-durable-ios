import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The share sheet's "Pi": takes what another app shares (screenshots, photos, selected text, links, files), lets the
/// user add a prompt and pick a conversation, and leaves it in the App Group inbox for PiApp, which it then opens.
/// Like the widget, it never loads JS or opens Pi storage.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let model = ShareModel(
            items: items,
            finish: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) },
            cancel: { [weak self] in self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled)) },
            open: { [weak self] url in await self?.openApp(url) ?? false }
        )
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    /// Extensions cannot call `UIApplication.shared.open`; the application object is still on the responder chain,
    /// and its `openURL:options:completionHandler:` opens Pi. False when iOS refuses.
    private func openApp(_ url: URL) async -> Bool {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                let selector = NSSelectorFromString("openURL:options:completionHandler:")
                guard application.responds(to: selector) else { return false }
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                let open = unsafeBitCast(application.method(for: selector), to: Open.self)
                return await withCheckedContinuation { continuation in
                    open(application, selector, url as NSURL, NSDictionary()) { continuation.resume(returning: $0) }
                }
            }
            responder = current.next
        }
        return false
    }
}

@MainActor
@Observable
final class ShareModel {
    enum Phase: Equatable {
        case loading
        case ready
        case empty
        /// Saved, but Pi did not open: it sends the item the next time it is opened.
        case saved
    }

    private(set) var phase = Phase.loading
    var attachments: [Attachment] = []
    var text = ""
    /// nil: a new conversation.
    var conversationId: Int?
    let recent = Array(RecentConversation.read().prefix(8))
    private let id = UUID().uuidString
    private let finish: () -> Void
    private let cancelRequest: () -> Void
    private let open: (URL) async -> Bool

    init(items: [NSExtensionItem], finish: @escaping () -> Void, cancel: @escaping () -> Void, open: @escaping (URL) async -> Bool) {
        self.finish = finish
        cancelRequest = cancel
        self.open = open
        // Item providers are not Sendable; only the loading task touches them from here on.
        nonisolated(unsafe) let providers = items.flatMap { $0.attachments ?? [] }
        // Safari puts the page title in the item's text; some apps put selected text there with no provider.
        let title = items.lazy.compactMap { $0.attributedTitle?.string ?? $0.attributedContentText?.string }.first
        let content = items.lazy.compactMap { $0.attributedContentText?.string }.first
        Task {
            attachments = await Attachments.load(providers, title: title)
            if attachments.isEmpty, let text = content, !text.isEmpty {
                attachments = [Attachment(content: .text(text))]
            }
            phase = attachments.isEmpty ? .empty : .ready
        }
    }

    func remove(_ attachment: Attachment) {
        attachments.removeAll { $0.id == attachment.id }
        if attachments.isEmpty { phase = .empty }
    }

    var canSend: Bool { phase == .ready && (!attachments.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }

    /// `draft`: open in Pi's composer instead of sending.
    func send(draft: Bool) async {
        let input = SharedInput(id: id, text: text.trimmingCharacters(in: .whitespacesAndNewlines), attachments: attachments, conversationId: conversationId, draft: draft)
        do { try ShareInbox.write(input) } catch { return }
        if await open(URL(string: "pidurable://share/\(id)")!) {
            finish()
        } else {
            phase = .saved
            try? await Task.sleep(for: .seconds(1.5))
            finish()
        }
    }

    func cancel() { cancelRequest() }
}

struct ShareView: View {
    @Bindable var model: ShareModel
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section { shared }
                Section {
                    TextField("Ask about this (optional)", text: $model.text, axis: .vertical)
                        .lineLimit(2...6)
                        .focused($focused)
                        .accessibilityIdentifier("share.prompt")
                    picker
                }
                Section {
                    Button("Open in Pi to Edit", systemImage: "square.and.pencil") { Task { await model.send(draft: true) } }
                        .disabled(model.phase != .ready)
                } footer: {
                    if model.phase == .saved {
                        Label("Saved. Pi sends it the next time you open it.", systemImage: "tray.and.arrow.down")
                    }
                }
            }
            .navigationTitle("Pi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .onAppear { focused = true }
    }

    @ViewBuilder private var shared: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity)
        case .empty:
            Text("Nothing here Pi can read. It takes images, text, links, PDFs and text files.").foregroundStyle(.secondary)
        case .ready, .saved:
            // The last one stays: a share without anything is just Cancel.
            let remove: ((Attachment) -> Void)? = model.attachments.count > 1 ? { model.remove($0) } : nil
            AttachmentStrip(attachments: model.attachments, remove: remove)
                .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        }
    }

    private var picker: some View {
        Picker("Conversation", selection: $model.conversationId) {
            Text("New conversation").tag(Int?.none)
            ForEach(model.recent) { conversation in
                Text(conversation.title).lineLimit(1).tag(Int?.some(conversation.id))
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", role: .cancel) { model.cancel() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Send", systemImage: "arrow.up") { Task { await model.send(draft: false) } }
                .buttonStyle(.glassProminent)
                .disabled(!model.canSend)
                .accessibilityIdentifier("share.send")
        }
    }
}
