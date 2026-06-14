import SwiftUI
import WebKit

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 1 — Editor & Frontmatter
// ════════════════════════════════════════════════════════════════════════
//
// The Svod editing surface, rendered by a bundled CodeMirror 6 + markdown-it +
// mermaid web editor inside a WKWebView (see Resources/webeditor/). This replaces
// the hand-rolled NSTextView + regex highlighter: the web stack gives 100% GFM,
// code syntax highlighting, mermaid diagrams and tables "for free", with two modes
// (Edit = CodeMirror source, Preview = rendered markdown).
//
// Data flow:
//   Swift → JS   setContent / setMode / setNoteNames / configure (via evaluateJavaScript)
//   JS → Swift   change / openLink / openExternal / ready (via messageHandlers.svod)
// Only the note body is edited here; frontmatter is handled by FrontmatterPanel.

struct WebEditorView: NSViewRepresentable {
    @Binding var text: String
    var previewMode: Bool
    var noteNames: [String]
    var onOpenLink: (String) -> Void
    var onOpenExternal: (URL) -> Void = { NSWorkspace.shared.open($0) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: "svod")
        cfg.userContentController = ucc

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.allowsMagnification = false
        wv.underPageBackgroundColor = nsColor(ThemeColor.editorSurface)  // no white flash
        context.coordinator.webView = wv

        let html = Bundle.main.url(forResource: "editor", withExtension: "html", subdirectory: "webeditor")
            ?? Bundle.main.url(forResource: "editor", withExtension: "html")
        if let html {
            wv.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
        return wv
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync()
    }

    // MARK: - Coordinator
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: WebEditorView
        weak var webView: WKWebView?
        private var ready = false

        // Mirrors of what JS currently has, to avoid feedback loops / redundant pushes.
        private var jsDocText = ""
        private var jsPreview: Bool?
        private var jsNoteNames: [String] = []
        private var configured = false

        init(_ parent: WebEditorView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // boot() posts {type:"ready"}; we configure + push there. didFinish is a
            // fallback in case the message is missed.
            if !ready { ready = true; pushAll() }
        }

        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                pushAll()
            case "change":
                if let t = body["text"] as? String {
                    jsDocText = t
                    if parent.text != t { parent.text = t }
                }
            case "openLink":
                if let target = body["target"] as? String { parent.onOpenLink(target) }
            case "openExternal":
                if let href = body["href"] as? String, let url = URL(string: href) { parent.onOpenExternal(url) }
            default: break
            }
        }

        /// Push any state that drifted from what JS holds.
        func sync() {
            guard ready else { return }
            if !configured { configure(); configured = true }
            if parent.text != jsDocText {
                jsDocText = parent.text
                call("window.SvodEditor.setContent(\(jsString(parent.text)))")
            }
            if jsPreview != parent.previewMode {
                jsPreview = parent.previewMode
                call("window.SvodEditor.setMode('\(parent.previewMode ? "preview" : "edit")')")
            }
            if jsNoteNames != parent.noteNames {
                jsNoteNames = parent.noteNames
                if let data = try? JSONSerialization.data(withJSONObject: parent.noteNames),
                   let json = String(data: data, encoding: .utf8) {
                    call("window.SvodEditor.setNoteNames(\(json))")
                }
            }
        }

        private func pushAll() {
            configure(); configured = true
            jsDocText = parent.text
            call("window.SvodEditor.setContent(\(jsString(parent.text)))")
            if let data = try? JSONSerialization.data(withJSONObject: parent.noteNames),
               let json = String(data: data, encoding: .utf8) {
                jsNoteNames = parent.noteNames
                call("window.SvodEditor.setNoteNames(\(json))")
            }
            jsPreview = parent.previewMode
            call("window.SvodEditor.setMode('\(parent.previewMode ? "preview" : "edit")')")
        }

        private func configure() {
            let appearance = webView?.effectiveAppearance ?? NSApp.effectiveAppearance
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            var colors: [String: String] = [:]
            appearance.performAsCurrentDrawingAppearance {
                let map: [String: Color] = [
                    "editorSurface": ThemeColor.editorSurface, "surface": ThemeColor.surfaceRaised,
                    "textPrimary": ThemeColor.textPrimary, "textSecondary": ThemeColor.textSecondary,
                    "textTertiary": ThemeColor.textTertiary, "accent": ThemeColor.accent,
                    "link": ThemeColor.link, "linkUnresolved": ThemeColor.linkUnresolved,
                    "borderSubtle": ThemeColor.borderSubtle, "surfaceHover": ThemeColor.surfaceHover,
                    "selection": ThemeColor.surfaceSelected, "string": ThemeColor.sync,
                    "heading": ThemeColor.textPrimary, "emphasis": ThemeColor.textPrimary,
                    "code": ThemeColor.accent,
                ]
                for (k, v) in map { colors[k] = hex(v) }
            }
            let payload: [String: Any] = ["colors": colors, "dark": dark]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                call("window.SvodEditor.configure(\(json))")
            }
        }

        private func call(_ js: String) {
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        /// JSON-encode a Swift string into a safe JS string literal.
        private func jsString(_ s: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
            let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
            return String(arr.dropFirst().dropLast())   // strip the [ ] → the quoted element
        }

        private func hex(_ color: Color) -> String {
            let ns = (NSColor(color).usingColorSpace(.sRGB)) ?? NSColor(color)
            let r = Int(round(ns.redComponent * 255)), g = Int(round(ns.greenComponent * 255)), b = Int(round(ns.blueComponent * 255))
            return String(format: "#%02X%02X%02X", r, g, b)
        }
    }
}
