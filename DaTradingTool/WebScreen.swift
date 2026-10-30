import SwiftUI
import UIKit
import WebKit
import UserNotifications

/// The tool's page in a WKWebView. The page talks to the phone through window.webkit.messageHandlers.da:
///   { open: url }                 links open in Safari or the app that owns them (Phantom, X, Telegram)
///   { save: name, text: json }    Settings > Backup > Export, through the iOS Save sheet
///   { notify: title, body, always }  alerts as iPhone notifications (while the app is in the background)
///   { ask: true }                 asks for notification permission, answers with window.__daPerm(state)
/// The app never holds wallet keys: Buy and Sell hand the trade to the Phantom app or jup.ag.
struct WebScreen: UIViewRepresentable {
    func makeCoordinator() -> WebCoordinator {
        WebCoordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let config = WKWebViewConfiguration()
        // the page reads this to know it runs in the iPhone app
        config.applicationNameForUserAgent = "Mobile/15E148 DaTradingTool/1.1.0 (iOS)"
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(WeakMessageHandler(coordinator), name: "da")

        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.allowsBackForwardNavigationGestures = false
        web.navigationDelegate = coordinator
        web.uiDelegate = coordinator
        coordinator.web = web
        coordinator.start()
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Forwards page messages without the web view keeping its coordinator alive forever.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

final class WebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler,
    UNUserNotificationCenterDelegate, UIDocumentPickerDelegate {

    weak var web: WKWebView?
    private var inFront = true
    private var lastOpened = ""
    private var lastOpenedAt = Date.distantPast

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resignedActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    @objc private func becameActive() { inFront = true }
    @objc private func resignedActive() { inFront = false }

    /// Tells the page whether notifications are allowed, then loads it.
    func start() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let state: String
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: state = "granted"
            case .denied: state = "denied"
            default: state = "default"
            }
            DispatchQueue.main.async {
                guard let web = self.web,
                      let page = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") else { return }
                let script = WKUserScript(source: "window.__daIosPerm = '\(state)';", injectionTime: .atDocumentStart, forMainFrameOnly: true)
                web.configuration.userContentController.addUserScript(script)
                web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
            }
        }
    }

    private func js(_ code: String) {
        web?.evaluateJavaScript(code, completionHandler: nil)
    }

    // MARK: messages from the page

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any] else { return }
        if let url = m["open"] as? String {
            openOut(url)
        } else if let name = m["save"] as? String, let text = m["text"] as? String {
            save(name: name, text: text)
        } else if let title = m["notify"] as? String {
            notify(title: title, body: (m["body"] as? String) ?? "", always: (m["always"] as? Bool) ?? false)
        } else if m["ask"] != nil {
            askNotify()
        }
    }

    /// Links never open inside the app: Safari, or the app that owns the link (Phantom's links open Phantom).
    private func openOut(_ string: String) {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return }
        // a link can arrive twice (as a navigation and as a new-window request); open it once
        if string == lastOpened && Date().timeIntervalSince(lastOpenedAt) < 1.5 { return }
        lastOpened = string
        lastOpenedAt = Date()
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    // MARK: backups

    private func save(name: String, text: String) {
        let safeName = name.replacingOccurrences(of: "/", with: "-")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            js("window.__daSaved && window.__daSaved(false)")
            return
        }
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        picker.delegate = self
        guard let top = topController() else {
            js("window.__daSaved && window.__daSaved(false)")
            return
        }
        top.present(picker, animated: true, completion: nil)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        js("window.__daSaved && window.__daSaved(true)")
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        js("window.__daSaved && window.__daSaved(false)")
    }

    private func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    // MARK: notifications

    private func askNotify() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                self.js("window.__daPerm && window.__daPerm('\(granted ? "granted" : "denied")')")
            }
        }
    }

    /// A verified launch or wallet trade while the app is in the background. While you're looking at the app,
    /// the page shows its own alert (only the Test alert button asks for a notification then).
    private func notify(title: String, body: String, always: Bool) {
        if inFront && !always { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    // MARK: navigation: the tool's own page stays, everything else opens outside

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if url.isFileURL || scheme == "about" || scheme == "blob" || scheme == "data" {
            decisionHandler(.allow)
            return
        }
        if let frame = navigationAction.targetFrame, !frame.isMainFrame {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        openOut(url.absoluteString)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { openOut(url.absoluteString) }
        return nil
    }

    // if iOS ever stops the page (low memory), bring it straight back
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}
