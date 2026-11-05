import SwiftUI
import UIKit
import WebKit

/// Searches the web for any image, for covers the book services don't have
/// (fan-made covers, for one). Tap an image to preview it, then use it.
/// The web view is private: no cookies, cache or history are kept.
struct WebCoverSearchView: View {
    var onPick: (Data, URL?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var browser = WebBrowserModel()
    @State private var pending: PendingPick?
    @State private var isDownloading = false
    @State private var errorMessage: String?

    struct PendingPick: Identifiable {
        let id = UUID()
        var data: Data
        var image: UIImage
        var url: URL?
    }

    init(initialQuery: String, onPick: @escaping (Data, URL?) -> Void) {
        self.onPick = onPick
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                if browser.progress < 1 {
                    ProgressView(value: browser.progress)
                        .progressViewStyle(.linear)
                }
                WebImageBrowser(model: browser) { full, shown in
                    Task { await prepare(full: full, shown: shown) }
                }
                .overlay {
                    if isDownloading {
                        ProgressView("Getting the image…")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                Text("Tap any image to use it. Searches go to Bing; nothing is saved.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            .navigationTitle("Search the web")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Back", systemImage: "chevron.backward") { browser.webView?.goBack() }
                        .disabled(!browser.canGoBack)
                    Button("Forward", systemImage: "chevron.forward") { browser.webView?.goForward() }
                        .disabled(!browser.canGoForward)
                    Spacer()
                }
            }
            .sheet(item: $pending) { pick in
                confirmation(pick)
                    .presentationDetents([.medium, .large])
            }
            .alert("Couldn't use that image", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear { search() }
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search for images", text: $query)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit { search() }
            if !query.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func confirmation(_ pick: PendingPick) -> some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(uiImage: pick.image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(Text("The chosen image"))
                Text("\(Int(pick.image.size.width * pick.image.scale)) × \(Int(pick.image.size.height * pick.image.scale)) pixels. You can crop and zoom it next.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    onPick(pick.data, pick.url)
                    pending = nil
                    dismiss()
                } label: {
                    Label("Use this image", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep looking") { pending = nil }
                }
            }
        }
    }

    private func search() {
        guard let url = WebImageSearch.searchURL(for: query) else { return }
        browser.load(url)
    }

    private func prepare(full: String?, shown: String?) async {
        guard !isDownloading else { return }
        isDownloading = true
        defer { isDownloading = false }
        for candidate in WebImageSearch.candidates(full: full, shown: shown) {
            let data: Data?
            let url: URL?
            switch candidate {
            case .remote(let remote):
                data = try? await CoverSearchService.downloadImage(remote)
                url = remote
            case .inline(let inline):
                data = inline
                url = nil
            }
            if let data, data.count <= CoverSearchService.maxImageBytes, let image = UIImage(data: data),
               image.size.width * image.scale >= CoverSearchService.minimumImageSide,
               image.size.height * image.scale >= CoverSearchService.minimumImageSide {
                pending = PendingPick(data: data, image: image, url: url)
                return
            }
        }
        errorMessage = String(localized: "That image couldn't be downloaded. Try opening it first, or pick another.")
    }
}

/// Navigation state shared between the SwiftUI chrome and the web view.
@MainActor @Observable
final class WebBrowserModel {
    var progress: Double = 1
    var canGoBack = false
    var canGoForward = false
    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored private var pendingURL: URL?

    func load(_ url: URL) {
        if let webView {
            webView.load(URLRequest(url: url))
        } else {
            pendingURL = url
        }
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
        if let pendingURL {
            webView.load(URLRequest(url: pendingURL))
            self.pendingURL = nil
        }
    }
}

private struct WebImageBrowser: UIViewRepresentable {
    let model: WebBrowserModel
    var onTapImage: (String?, String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model, onTapImage: onTapImage) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: WebImageSearch.pickScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.add(context.coordinator, name: "coverPick")
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.observe(webView)
        model.attach(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onTapImage = onTapImage
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "coverPick")
        webView.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let model: WebBrowserModel
        var onTapImage: (String?, String?) -> Void
        private var observations: [NSKeyValueObservation] = []

        init(model: WebBrowserModel, onTapImage: @escaping (String?, String?) -> Void) {
            self.model = model
            self.onTapImage = onTapImage
        }

        func observe(_ webView: WKWebView) {
            observations = [
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                    MainActor.assumeIsolated { self?.model.progress = view.estimatedProgress }
                },
                webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                    MainActor.assumeIsolated { self?.model.canGoBack = view.canGoBack }
                },
                webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                    MainActor.assumeIsolated { self?.model.canGoForward = view.canGoForward }
                },
            ]
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            onTapImage(body["full"] as? String, body["shown"] as? String)
        }

        /// Only web pages: no app links, phone numbers or other schemes.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let scheme = navigationAction.request.url?.scheme?.lowercased() else { return .cancel }
            guard ["https", "about", "blob", "data"].contains(scheme) else { return .cancel }
            // Links that would open a new window open here instead.
            if navigationAction.targetFrame == nil, scheme == "https" {
                webView.load(navigationAction.request)
                return .cancel
            }
            return .allow
        }
    }
}
