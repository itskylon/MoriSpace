import SwiftUI
import WebKit

/// Web access and Graph authorization have independent sessions. Passwords stay in Microsoft's page.
enum OneDriveWebPolicy {
    static let home = URL(string: "https://onedrive.live.com/login/")!
    static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return ["live.com", "microsoftonline.com", "microsoft.com", "onedrive.com", "sharepoint.com", "office.com", "microsoft365.com", "cloud.microsoft"].contains {
            host == $0 || host.hasSuffix("." + $0)
        }
    }
}

@MainActor final class OneDriveWebStore: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var loading = false
    @Published private(set) var canBack = false
    @Published private(set) var canForward = false
    @Published private(set) var host = "onedrive.live.com"
    @Published private(set) var error: String?
    private weak var webView: WKWebView?
    private var observations: [NSKeyValueObservation] = []
    var browserURL: URL {
        guard let url = webView?.url, OneDriveWebPolicy.allows(url) else { return OneDriveWebPolicy.home }
        return url
    }

    func attach(_ view: WKWebView) {
        webView = view
        view.navigationDelegate = self; view.uiDelegate = self
        observations = [
            view.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() },
            view.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() },
            view.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() },
            view.observe(\.url, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() }
        ]
        view.load(URLRequest(url: OneDriveWebPolicy.home))
    }
    func detach(_ view: WKWebView) {
        guard view === webView else { return }
        observations.removeAll(); view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil; webView = nil
    }
    private nonisolated func scheduleUpdate() {
        Task { @MainActor [weak self] in
            guard let self, let view = self.webView else { return }
            self.loading = view.isLoading; self.canBack = view.canGoBack; self.canForward = view.canGoForward
            self.host = view.url?.host ?? "onedrive.live.com"
        }
    }
    func back() { webView?.goBack() }
    func forward() { webView?.goForward() }
    func reload() {
        error = nil
        if webView?.url == nil { webView?.load(URLRequest(url: OneDriveWebPolicy.home)) }
        else { webView?.reload() }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { error = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        error = "网页已暂停，请刷新或在浏览器打开。"
    }
    private func failed(_ failure: Error) {
        guard (failure as NSError).code != NSURLErrorCancelled else { return }
        error = "微软网页暂时无法加载，请检查网络后刷新，或在浏览器打开。"
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload {
            error = "网页下载请使用右下角的浏览器按钮；原生下载需连接文件功能。"
            decisionHandler(.cancel); return
        }
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.targetFrame?.isMainFrame != false && !OneDriveWebPolicy.allows(url) {
            error = "此链接不属于支持的微软网页，请在浏览器打开 OneDrive 后操作。"
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !response.canShowMIMEType {
            error = "此文件请在浏览器打开或下载；原生预览需连接文件功能。"
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url, OneDriveWebPolicy.allows(url) { webView.load(action.request) }
        return nil
    }
}

private struct OneDriveWebSurface: UIViewRepresentable {
    @ObservedObject var store: OneDriveWebStore
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.accessibilityIdentifier = "oneDriveOfficialWeb"
        store.attach(view)
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    func makeCoordinator() -> OneDriveWebStore { store }
    static func dismantleUIView(_ view: WKWebView, coordinator: OneDriveWebStore) { coordinator.detach(view) }
}

struct OneDriveWebView: View {
    @StateObject private var store = OneDriveWebStore()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").foregroundStyle(NASStyle.accent)
                Text(store.host).font(.caption).lineLimit(1)
                Spacer()
                Text("微软官方网页").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).frame(minHeight: 36).background(NASStyle.surface)
            if store.loading { ProgressView().progressViewStyle(.linear).accessibilityLabel("正在加载微软网页") }
            if let error = store.error { ErrorBanner(message: error).padding(12) }
            OneDriveWebSurface(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 16) {
                Button { store.back() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .disabled(!store.canBack).accessibilityLabel("后退").accessibilityIdentifier("oneDriveWebBack")
                Button { store.forward() } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .disabled(!store.canForward).accessibilityLabel("前进")
                Spacer()
                Button { store.reload() } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                    .accessibilityLabel("刷新网页").accessibilityIdentifier("oneDriveWebReload")
                Button { openURL(store.browserURL) } label: { Image(systemName: "safari").frame(width: 44, height: 44) }
                    .accessibilityLabel("在浏览器打开").accessibilityIdentifier("oneDriveWebExternal")
            }.buttonStyle(.plain).padding(.horizontal, 12).background(NASStyle.surface)
        }.background(NASStyle.canvas).tint(NASStyle.accent)
            .navigationTitle("OneDrive 网页版").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }.accessibilityIdentifier("oneDriveWebDone")
            } }
    }
}
