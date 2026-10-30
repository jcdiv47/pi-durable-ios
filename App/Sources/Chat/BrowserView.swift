import SwiftUI
import WebKit

/// Pi's own browser, for links when Settings › Links › Open links in is Pi. It is a route on the chat's stack, so it slides
/// in from the right and the edge swipe goes back to the conversation; the page's own swipe navigation is off so that
/// edge stays the stack's.
struct BrowserView: View {
    let url: URL
    /// Made on first appearance: the destination is rebuilt whenever the stack's body runs, and a page is a web view.
    @State private var page: WebPage?
    @State private var failure: String?

    /// The links this browser takes: web pages, except Apple Maps', which open the Maps app.
    static func opens(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased()) && url.host()?.lowercased() != "maps.apple.com"
    }

    var body: some View {
        if let page {
            content(page)
        } else {
            // A real view to appear: modifiers on an empty Group have nothing to attach to, so they never run.
            Color.clear.onAppear {
                let decider = LinkDecider()
                let page = WebPage(navigationDecider: decider)
                decider.page = page
                self.page = page
                load(page, url)
            }
        }
    }

    private func content(_ page: WebPage) -> some View {
        WebView(page)
            .webViewBackForwardNavigationGestures(.disabled)
            .safeAreaInset(edge: .top, spacing: 0) {
                // Pages draw under the bar in their own colors, and a light page in dark mode hides the white title:
                // the bar's material spreads up from here, with the loading bar along its bottom edge.
                ProgressView(value: page.estimatedProgress)
                    .progressViewStyle(.linear)
                    .opacity(page.isLoading ? 1 : 0)
                    .background(.bar)
            }
            .overlay {
                if let failure, !page.isLoading {
                    ContentUnavailableView {
                        Label("Page didn't open", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(failure)
                    } actions: {
                        Button("Try again") { load(page, page.url ?? url) }.buttonStyle(.glassProminent)
                    }
                    .background(.background)
                }
            }
            .onChange(of: page.isLoading) { if page.isLoading { failure = nil } }
            .navigationTitle(page.title.isEmpty ? (page.url ?? url).host() ?? "" : page.title)
            .navigationSubtitle(page.title.isEmpty ? "" : (page.url ?? url).host() ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if page.isLoading {
                        Button("Stop", systemImage: "xmark") { page.stopLoading() }
                    } else {
                        Button("Reload", systemImage: "arrow.clockwise") { load(page, page.url ?? url) }
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Back", systemImage: "chevron.backward") {
                        if let item = page.backForwardList.backList.last { page.load(item) }
                    }
                    .disabled(page.backForwardList.backList.isEmpty)
                    Button("Forward", systemImage: "chevron.forward") {
                        if let item = page.backForwardList.forwardList.first { page.load(item) }
                    }
                    .disabled(page.backForwardList.forwardList.isEmpty)
                }
                ToolbarSpacer(placement: .bottomBar)
                ToolbarItemGroup(placement: .bottomBar) {
                    ShareLink(item: page.url ?? url)
                    Button("Open in Default Browser", systemImage: "safari") {
                        UIApplication.shared.open(page.url ?? url)
                    }
                }
            }
    }

    /// Loads `target`, keeping why it failed. A load cut short by another (a tap on a link, Stop) is no failure.
    private func load(_ page: WebPage, _ target: URL) {
        failure = nil
        Task {
            do {
                for try await _ in page.load(target) {}
            } catch {
                let error = error as NSError
                let interrupted = error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
                    || error.domain == "WebKitErrorDomain" && error.code == 102
                if !interrupted { failure = error.localizedDescription }
            }
        }
    }
}

/// Links a web view can't follow itself: other schemes (mail, phone, apps) go to iOS, as do Apple Maps pages (not a map
/// a page embeds), and a link that opens a new window (`target="_blank"`) opens in this page, which has no windows.
@MainActor private final class LinkDecider: WebPage.NavigationDeciding {
    weak var page: WebPage?

    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .allow }
        if !["http", "https", "about", "blob", "data"].contains(url.scheme?.lowercased() ?? "") {
            await UIApplication.shared.open(url)
            return .cancel
        }
        if action.target?.isMainFrame != false, url.host()?.lowercased() == "maps.apple.com" {
            await UIApplication.shared.open(url)
            return .cancel
        }
        if action.target == nil {
            page?.load(action.request)
            return .cancel
        }
        return .allow
    }
}
