import PiUI
import SwiftUI
import UIKit.UIGestureRecognizerSubclass
import WebKit

// Web cards (`show_ui`, `update_ui` in webui.ts): HTML the agent wrote, drawn in a sandboxed WKWebView.
//
// The sandbox: a content security policy that allows no network, frames, workers or form posts, only inline script and
// style and data: images; a content rule list that blocks every http(s), ws(s), ftp and file load underneath it; no
// navigation after the first load (links the user taps open through the app's `openURL`, like any link in the chat);
// a data store that keeps nothing; no pop-ups, alerts, camera or microphone; and no WebRTC (pi-ui.js removes it before
// the page's scripts run). A page can only show things and talk to Pi through `pi.submit` and `pi.prompt`, and only
// right after the user touched it: each touch allows one message (`TouchGate`), so a script cannot send on its own.

/// The document, styles and rules every web card loads with.
@MainActor
enum WebCardSandbox {
    static let policy = [
        "default-src 'none'", "script-src 'unsafe-inline'", "style-src 'unsafe-inline'", "img-src data: blob:", "font-src data:",
        "media-src data: blob:", "connect-src 'none'", "frame-src 'none'", "child-src 'none'", "worker-src 'none'",
        "object-src 'none'", "form-action 'none'", "base-uri 'none'", "manifest-src 'none'",
    ].joined(separator: "; ")

    private static func resource(_ name: String, _ ext: String) -> String {
        Bundle.main.url(forResource: name, withExtension: ext).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    static let library = resource("pi-ui", "js")
    static let styles = resource("pi-ui", "css")

    /// Network loads of any kind, blocked under the CSP in case it misses one. (Content blocker patterns have no `|`.)
    private static let ruleSource = "[" + ["^https?://", "^wss?://", "^ftp://", "^file:"]
        .map { #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"# }
        .joined(separator: ",") + "]"
    private(set) static var rules: WKContentRuleList?
    /// Set once compiling was tried; a failure leaves cards behind the CSP alone (and says so in Diagnostics).
    private(set) static var prepared = false
    private static var compiling: Task<Result<WKContentRuleList?, any Error>, Never>?

    /// Compiles the rule list once; cards wait for it before loading anything.
    static func prepare(log: (String) -> Void) async {
        if prepared { return }
        let task = compiling ?? Task {
            do {
                return .success(try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "pi-webcard-v2", encodedContentRuleList: ruleSource))
            } catch {
                return .failure(error)
            }
        }
        compiling = task
        switch await task.value {
        case let .success(list): rules = list
        case let .failure(error): log("Web card content rules did not compile: \(error.localizedDescription)")
        }
        prepared = true
    }

    static func document(_ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">\
        <meta http-equiv="Content-Security-Policy" content="\(policy)">\
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">\
        <meta name="color-scheme" content="light dark">\
        <style>\(PiDesign.css)\n\(styles)</style></head><body>\(body)</body></html>
        """
    }

    /// `window.__piCard`, for pi-ui.js: the card's identity and the agent's `set_value` values.
    static func config(_ card: WebCardRef, data: [String: JSONValue]) -> String {
        struct Config: Encodable {
            let id: String
            let version: Int
            let title: String
            let data: [String: JSONValue]
        }
        let json = (try? JSONEncoder().encode(Config(id: card.id, version: card.version, title: card.title, data: data))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "Object.defineProperty(window, '__piCard', { value: Object.freeze(\(json)) });"
    }
}

/// What a card's page asked for.
enum WebCardMessage {
    case submit(JSONValue?, label: String?)
    case prompt(String)
    case open(URL)
    case height(CGFloat)
    case error(String)

    init?(_ body: Any) {
        guard let object = body as? [String: Any], let type = object["type"] as? String else { return nil }
        switch type {
        case "submit":
            let value = object["value"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) }
                .flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            self = .submit(value, label: object["label"] as? String)
        case "prompt":
            guard let text = object["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            self = .prompt(String(text.prefix(4000)))
        case "open":
            guard let text = object["url"] as? String, let url = URL(string: text), ["http", "https", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            self = .open(url)
        case "height":
            guard let value = object["value"] as? Double, value.isFinite else { return nil }
            self = .height(CGFloat(max(0, min(value, 20_000))))
        case "error":
            self = .error(String((object["message"] as? String ?? "Script error").prefix(300)))
        default:
            return nil
        }
    }

    /// Messages that act for the user, and so need a touch first.
    var isAction: Bool {
        switch self {
        case .submit, .prompt, .open: true
        case .height, .error: false
        }
    }
}

// MARK: - The card in the transcript

/// A web card under its call: a kicker with the title and Expand, the page sized to its content (up to a limit, then
/// "Show all" opens it full height in a sheet).
struct WebCardView: View {
    let card: WebCardRef
    let store: ChatStore
    @State private var height: CGFloat = 0
    @State private var ready = WebCardSandbox.prepared
    @State private var expanded = false
    @State private var scriptError: String?
    @Environment(\.openURL) private var openURL

    static let maxInline: CGFloat = 560

    var body: some View {
        VStack(alignment: .leading, spacing: PiDesign.Space.s) {
            HStack(spacing: 6) {
                Label(card.title.uppercased(), systemImage: "rectangle.on.rectangle")
                    .lineLimit(1)
                    .piKicker(PiDesign.Palette.accent)
                Spacer(minLength: 0)
                Button("Expand", systemImage: "arrow.up.left.and.arrow.down.right") { expanded = true }
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            ZStack(alignment: .bottom) {
                if ready {
                    WebCardWebView(card: card, data: store.surfaceData.doc, scrolls: false, onMessage: handle)
                        .id("\(card.id)-\(card.version)")
                        .frame(height: max(min(height, Self.maxInline), 44))
                        .opacity(height > 0 ? 1 : 0)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                }
                if height > Self.maxInline {
                    LinearGradient(colors: [.clear, Color(.systemBackground)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 56)
                        .allowsHitTesting(false)
                    Button("Show All") { expanded = true }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .padding(.bottom, 6)
                }
            }
            .animation(PiDesign.Motion.disclose, value: height > 0)
            if let scriptError {
                Label("The card's script failed: \(scriptError)", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityIdentifier("webcard.\(card.id)")
        .task {
            if !ready {
                await WebCardSandbox.prepare { store.diagnostics.record("error", "webcard", $0) }
                ready = true
            }
            await store.refreshSurfaceData()
        }
        .sheet(isPresented: $expanded) {
            NavigationStack {
                WebCardWebView(card: card, data: store.surfaceData.doc, scrolls: true) { message in
                    handle(message)
                    if message.isAction { expanded = false }
                }
                .padding(.horizontal)
                .navigationTitle(card.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { expanded = false } }
                }
            }
        }
    }

    private func handle(_ message: WebCardMessage) {
        switch message {
        case let .height(value):
            height = value
        case let .error(text):
            scriptError = text
            store.diagnostics.record("warn", "webcard", "\(card.id) v\(card.version): \(text)")
        case let .open(url):
            openURL(url)
        case let .submit(value, label):
            Task { await store.cardInput(card, value: value ?? .null, label: label) }
        case let .prompt(text):
            Task { await store.cardInput(card, prompt: text) }
        }
    }
}

// MARK: - The web view

struct WebCardWebView: UIViewRepresentable {
    let card: WebCardRef
    let data: [String: JSONValue]
    /// Inline the page does not scroll (the transcript does); in the sheet it does.
    let scrolls: Bool
    let onMessage: (WebCardMessage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onMessage: onMessage) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.dataDetectorTypes = []
        configuration.allowsInlineMediaPlayback = true
        let content = configuration.userContentController
        if let rules = WebCardSandbox.rules { content.add(rules) }
        content.addUserScript(WKUserScript(source: WebCardSandbox.config(card, data: data), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: WebCardSandbox.library, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.add(WeakMessageHandler(context.coordinator), name: "pi")

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = scrolls
        view.scrollView.bounces = scrolls
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.pinchGestureRecognizer?.isEnabled = false
        view.allowsLinkPreview = false
        view.allowsBackForwardNavigationGestures = false
        #if DEBUG
        view.isInspectable = true
        #endif
        let gate = TouchGate()
        context.coordinator.gate = gate
        view.addGestureRecognizer(gate)
        view.loadHTMLString(WebCardSandbox.document(card.html), baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onMessage = onMessage
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "pi")
        view.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        var onMessage: (WebCardMessage) -> Void
        var gate: TouchGate?
        private var loaded = false

        init(onMessage: @escaping (WebCardMessage) -> Void) {
            self.onMessage = onMessage
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let parsed = WebCardMessage(message.body) else { return }
            // One touch, one action: a script cannot submit, prompt or open links on its own.
            if parsed.isAction, gate?.consume() != true { return }
            onMessage(parsed)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // The document itself, once; nothing after it.
            if !loaded, action.targetFrame?.isMainFrame == true, action.request.url?.absoluteString == "about:blank" {
                loaded = true
                return .allow
            }
            if action.navigationType == .linkActivated, let url = action.request.url, url.scheme == "http" || url.scheme == "https" {
                onMessage(.open(url))
            }
            return .cancel
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // target="_blank": the user's tap opens it like any link.
            if action.navigationType == .linkActivated, let url = action.request.url, url.scheme == "http" || url.scheme == "https" {
                onMessage(.open(url))
            }
            return nil
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {}

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool { false }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? { nil }

        func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision { .deny }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            loaded = false
            webView.reload()
        }
    }
}

/// The message handler, held weakly: the user content controller keeps its handlers, and the coordinator owns the view.
@MainActor
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Notes each tap on the card without taking part in gestures, and lets one action through per tap, within a minute
/// (a field the user tapped, then typed in and submitted from the keyboard, still counts). A touch that scrolls the
/// transcript is no tap: the scroll view's pan cancels it, or it moves too far.
final class TouchGate: UIGestureRecognizer {
    private var tappedAt: Date?
    private var start: CGPoint?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        start = touches.first?.location(in: view)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let start, let point = touches.first?.location(in: view) else { return }
        if hypot(point.x - start.x, point.y - start.y) > 12 { state = .failed }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        tappedAt = .now
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    override func reset() {
        start = nil
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    func consume() -> Bool {
        guard let tappedAt, Date.now.timeIntervalSince(tappedAt) < 60 else { return false }
        self.tappedAt = nil
        return true
    }
}
