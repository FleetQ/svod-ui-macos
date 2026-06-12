import SwiftUI
import AppKit

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 1 — Editor & Frontmatter
// ════════════════════════════════════════════════════════════════════════

// MARK: - MarkdownTextView
//
// NSViewRepresentable over NSTextView with live, single-surface markdown styling
// (no split preview). Restyles on every edit, drives [[wikilink]] autocomplete,
// focus/typewriter dimming, and link hover hit-testing. Binds to `text` (the note
// body — frontmatter is edited in its own panel and recomposed by EditorView).

struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var focusMode: Bool
    var isResolved: (String) -> Bool

    // callbacks up to EditorView (window-space rects)
    var onAutocomplete: (_ query: String?, _ caretRect: CGRect) -> Void
    var onHoverLink: (_ target: String?, _ resolvedPath: String?, _ rect: CGRect) -> Void
    /// Called when the user clicks a `[[wikilink]]` or `[[vault:note]]` link.
    var onOpenLink: (_ target: String) -> Void = { _ in }
    /// Bridge so the autocomplete popover can steer the text view via the coordinator.
    var register: (Coordinator) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = HoverTextView()
        tv.onMouseMoved = { [weak coordinator = context.coordinator] in coordinator?.hoverLinkProbe() }
        tv.onMouseExited = { [weak coordinator = context.coordinator] in coordinator?.parent.onHoverLink(nil, nil, .zero) }
        let scroll = NSScrollView()
        scroll.documentView = tv
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        context.coordinator.textView = tv

        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.usesFindBar = true
        tv.drawsBackground = true
        tv.backgroundColor = nsColor(ThemeColor.editorSurface)
        tv.insertionPointColor = nsColor(ThemeColor.accent)
        tv.textColor = nsColor(ThemeColor.textPrimary)
        tv.font = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        tv.textContainerInset = NSSize(width: Spacing.xl, height: Spacing.xl)
        tv.allowsCharacterPickerTouchBarItem = false
        tv.linkTextAttributes = [:]   // we colour links ourselves; suppress default blue

        // ~70ch reading measure, centered.
        tv.maxSize = NSSize(width: Spacing.readingMeasure, height: .greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: Spacing.readingMeasure, height: .greatestFiniteMagnitude)
        tv.isHorizontallyResizable = false

        // line spacing for long-form reading
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = Typography.editorLineSpacing
        tv.defaultParagraphStyle = ps
        tv.typingAttributes[.paragraphStyle] = ps

        scroll.drawsBackground = true
        scroll.backgroundColor = nsColor(ThemeColor.editorSurface)
        scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = false

        context.coordinator.scrollView = scroll
        tv.coordinator = context.coordinator
        register(context.coordinator)

        tv.string = text
        context.coordinator.restyle()
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        context.coordinator.parent = self
        if tv.string != text {
            let sel = tv.selectedRange()
            tv.string = text
            tv.setSelectedRange(NSRange(location: min(sel.location, text.utf16.count), length: 0))
            context.coordinator.restyle()
        }
        // center the measure in the available width
        context.coordinator.centerTextContainer()
        context.coordinator.applyFocusDimming()
    }

    // MARK: - Coordinator
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?

        init(_ parent: MarkdownTextView) { self.parent = parent }

        // restyle the whole storage
        func restyle() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let hl = MarkdownSyntaxHighlighter(isResolved: parent.isResolved)
            hl.highlight(storage)
            // re-assert paragraph spacing the highlighter doesn't set
            let ps = NSMutableParagraphStyle()
            ps.lineSpacing = Typography.editorLineSpacing
            storage.addAttribute(.paragraphStyle, value: ps,
                                 range: NSRange(location: 0, length: storage.length))
            applyFocusDimming()
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            restyle()
            updateAutocomplete()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            applyFocusDimming()
            updateAutocomplete()
        }

        // MARK: focus / typewriter dimming
        func applyFocusDimming() {
            guard let tv = textView, let storage = tv.textStorage, storage.length > 0 else { return }
            let full = NSRange(location: 0, length: storage.length)
            if !parent.focusMode {
                // ensure no residual dimming
                storage.removeAttribute(.foregroundColor, range: full)
                let hl = MarkdownSyntaxHighlighter(isResolved: parent.isResolved)
                hl.highlight(storage)
                return
            }
            let activePara = (tv.string as NSString).paragraphRange(for: tv.selectedRange())
            // dim everything, then restore the active paragraph by re-highlighting it.
            storage.addAttribute(.foregroundColor, value: nsColor(ThemeColor.textDisabled), range: full)
            let hl = MarkdownSyntaxHighlighter(isResolved: parent.isResolved)
            hl.highlight(storage)            // re-color all (overrides dim on styled spans)
            // then re-dim the non-active region:
            let before = NSRange(location: 0, length: activePara.location)
            let after = NSRange(location: NSMaxRange(activePara),
                                length: storage.length - NSMaxRange(activePara))
            for r in [before, after] where r.length > 0 {
                storage.addAttribute(.foregroundColor, value: nsColor(ThemeColor.textDisabled), range: r)
            }
            centerActiveLine()
        }

        /// Typewriter scrolling — keep the caret line vertically centered.
        private func centerActiveLine() {
            guard parent.focusMode, let tv = textView, let lm = tv.layoutManager,
                  let container = tv.textContainer, let scroll = scrollView else { return }
            let glyphRange = lm.glyphRange(forCharacterRange: tv.selectedRange(), actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphRange, in: container)
            let caretY = rect.midY + tv.textContainerInset.height
            let half = scroll.contentView.bounds.height / 2
            let target = max(0, caretY - half)
            tv.scroll(NSPoint(x: 0, y: target))
        }

        func centerTextContainer() {
            guard let tv = textView, let scroll = scrollView else { return }
            let available = scroll.contentSize.width
            let measure = min(Spacing.readingMeasure, available)
            let inset = max(Spacing.xl, (available - measure) / 2)
            tv.textContainerInset = NSSize(width: inset, height: Spacing.xl)
            tv.textContainer?.containerSize = NSSize(width: measure, height: .greatestFiniteMagnitude)
        }

        // MARK: autocomplete detection — unclosed `[[` before the caret on this line
        func updateAutocomplete() {
            guard let tv = textView else { parent.onAutocomplete(nil, .zero); return }
            let caret = tv.selectedRange().location
            let ns = tv.string as NSString
            guard caret <= ns.length else { parent.onAutocomplete(nil, .zero); return }
            let lineRange = ns.lineRange(for: NSRange(location: max(0, caret - 1), length: 0))
            let before = ns.substring(with: NSRange(location: lineRange.location, length: caret - lineRange.location))
            guard let open = before.range(of: "[[", options: .backwards) else {
                parent.onAutocomplete(nil, .zero); return
            }
            let query = String(before[open.upperBound...])
            // a closing ]] in the query means it's already complete
            if query.contains("]]") { parent.onAutocomplete(nil, .zero); return }
            parent.onAutocomplete(query, caretRect())
        }

        /// Window-space rect of the caret, for popover anchoring.
        func caretRect() -> CGRect {
            guard let tv = textView, let window = tv.window else { return .zero }
            let r = tv.firstRect(forCharacterRange: tv.selectedRange(), actualRange: nil)
            return window.convertFromScreen(r)
        }

        /// Replace the active `[[query` with `[[name]]` and place the caret after.
        func insertWikilink(_ name: String) {
            guard let tv = textView else { return }
            let caret = tv.selectedRange().location
            let ns = tv.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: max(0, caret - 1), length: 0))
            let before = ns.substring(with: NSRange(location: lineRange.location, length: caret - lineRange.location))
            guard let open = before.range(of: "[[", options: .backwards) else { return }
            let openOffset = before.distance(from: before.startIndex, to: open.lowerBound)
            let replaceStart = lineRange.location + openOffset
            let replaceRange = NSRange(location: replaceStart, length: caret - replaceStart)
            let insertion = "[[\(name)]]"
            if tv.shouldChangeText(in: replaceRange, replacementString: insertion) {
                tv.textStorage?.replaceCharacters(in: replaceRange, with: insertion)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: replaceStart + insertion.utf16.count, length: 0))
            }
            parent.text = tv.string
            restyle()
            parent.onAutocomplete(nil, .zero)
        }

        // MARK: autocomplete keyboard steering (called by HoverTextView)
        /// Returns true if the key was consumed by the active popover.
        var autocompleteActive = false
        func handleKey(_ event: NSEvent) -> Bool {
            guard autocompleteActive else { return false }
            switch event.keyCode {
            case 125: onMove?(1); return true     // down
            case 126: onMove?(-1); return true    // up
            case 36, 48:                          // return / tab
                if let name = onChoose?() { insertWikilink(name) }
                return true
            case 53:                              // escape
                onCancel?(); parent.onAutocomplete(nil, .zero); return true
            default: return false
            }
        }
        var onMove: ((Int) -> Void)?
        var onChoose: (() -> String?)?
        var onCancel: (() -> Void)?

        // MARK: link click — open same-vault or cross-vault wikilink
        func textView(_ view: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let value = link as? String, value.hasPrefix("svodwiki://") else { return false }
            let target = String(value.dropFirst("svodwiki://".count))
            parent.onOpenLink(target)
            return true
        }

        // Use the layout manager to hit-test the .link attribute under the mouse.
        func hoverLinkProbe() {
            guard let tv = textView, let window = tv.window else { return }
            let mouse = window.mouseLocationOutsideOfEventStream
            let local = tv.convert(mouse, from: nil)
            guard let lm = tv.layoutManager, let container = tv.textContainer else { return }
            let point = NSPoint(x: local.x - tv.textContainerInset.width,
                                y: local.y - tv.textContainerInset.height)
            let idx = lm.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
            guard idx < (tv.textStorage?.length ?? 0) else { parent.onHoverLink(nil, nil, .zero); return }
            if let value = tv.textStorage?.attribute(.link, at: idx, effectiveRange: nil) as? String,
               value.hasPrefix("svodwiki://") {
                let target = String(value.dropFirst("svodwiki://".count))
                let r = tv.firstRect(forCharacterRange: NSRange(location: idx, length: 0), actualRange: nil)
                let rect = window.convertFromScreen(r)
                // resolution path looked up in EditorView via isResolved closure family
                parent.onHoverLink(target, nil, rect)
            } else {
                parent.onHoverLink(nil, nil, .zero)
            }
        }
    }
}

// MARK: - HoverTextView
//
// NSTextView subclass that forwards mouse-moved (for link hover previews) and lets
// the coordinator intercept keys while the [[ autocomplete popover is open.
final class HoverTextView: NSTextView {
    var onMouseMoved: (() -> Void)?
    var onMouseExited: (() -> Void)?
    weak var coordinator: MarkdownTextView.Coordinator?

    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouseMoved?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseExited?()
    }

    override func keyDown(with event: NSEvent) {
        if coordinator?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }
}
