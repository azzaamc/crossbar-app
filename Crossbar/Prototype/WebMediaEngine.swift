#if DEBUG
import Combine
import Foundation
import SwiftUI
import WebKit

struct WebMediaEvent: Equatable {
    let type: String
    let message: String?
}

@MainActor
final class WebMediaEngine: ObservableObject {
    @Published private(set) var eventLog: [String] = []
    var onEvent: ((WebMediaEvent) -> Void)?

    private weak var webView: WKWebView?

    func attach(_ webView: WKWebView?) {
        self.webView = webView
    }

    func join(callID: String, video: Bool) {
        send("join", payload: ["callID": callID, "video": video])
    }

    func leave() {
        send("leave")
    }

    func setMuted(_ muted: Bool) {
        send("setMuted", payload: ["muted": muted])
    }

    func setCameraEnabled(_ enabled: Bool) {
        send("setCameraEnabled", payload: ["enabled": enabled])
    }

    func switchCamera() {
        send("switchCamera")
    }

    func setAudioSessionActive(_ active: Bool) {
        send("setAudioSessionActive", payload: ["active": active])
    }

    func receive(_ body: Any) {
        guard
            let object = body as? [String: Any],
            let type = object["type"] as? String
        else {
            append("bridge: malformed event")
            return
        }

        let message = object["message"] as? String
        let detail = message.map { ": \($0)" } ?? ""
        append("web → native: \(type)\(detail)")
        onEvent?(WebMediaEvent(type: type, message: message))
    }

    private func send(_ command: String, payload: [String: Any] = [:]) {
        guard let webView else {
            append("native → web: \(command) (runtime unavailable)")
            return
        }

        let envelope: [String: Any] = ["command": command, "payload": payload]
        guard
            JSONSerialization.isValidJSONObject(envelope),
            let data = try? JSONSerialization.data(withJSONObject: envelope),
            let json = String(data: data, encoding: .utf8)
        else {
            append("native → web: \(command) (serialization failed)")
            return
        }

        append("native → web: \(command)")
        webView.evaluateJavaScript("window.CrossbarRuntime.receive(\(json)); true;") { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.append("javascript: \(error.localizedDescription)")
            }
        }
    }

    private func append(_ line: String) {
        eventLog.append(line)
        if eventLog.count > 30 {
            eventLog.removeFirst(eventLog.count - 30)
        }
    }
}

struct WebRuntimeView: UIViewRepresentable {
    let engine: WebMediaEngine

    func makeCoordinator() -> Coordinator {
        Coordinator(engine: engine)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(context.coordinator, name: "crossbar")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .black
        engine.attach(webView)

        if let url = Bundle.main.url(forResource: "RuntimeProbe", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            engine.receive(["type": "error", "message": "RuntimeProbe.html is missing from the app bundle"])
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "crossbar")
        coordinator.engine?.attach(nil)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate {
        weak var engine: WebMediaEngine?

        init(engine: WebMediaEngine) {
            self.engine = engine
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            engine?.receive(message.body)
        }

        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            decisionHandler(.grant)
        }
    }
}
#endif
