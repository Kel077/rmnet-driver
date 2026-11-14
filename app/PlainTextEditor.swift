// A multi-line plain-text field for the message being written: an NSTextView in an NSScrollView with
// every automatic substitution switched off (smart quotes, smart dashes, text replacement, spelling
// correction), so the text sent is exactly what was typed. SwiftUI's TextEditor cannot switch these off
// on macOS, and a curly quote alone would make a message Unicode (70 characters a part instead of 160).
import AppKit
import SwiftUI

struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var editable: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()   // wraps at the view's width, scrolls vertically
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        if let view = scroll.documentView as? NSTextView {
            view.isRichText = false                     // plain text: pasted fonts and colours are dropped
            view.importsGraphics = false                // no pasted or dropped images
            view.allowsImageEditing = false
            view.usesFontPanel = false
            view.usesRuler = false
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.isAutomaticDashSubstitutionEnabled = false
            view.isAutomaticTextReplacementEnabled = false
            view.isAutomaticSpellingCorrectionEnabled = false
            view.isAutomaticTextCompletionEnabled = false
            view.isAutomaticLinkDetectionEnabled = false
            view.isAutomaticDataDetectionEnabled = false
            view.smartInsertDeleteEnabled = false
            view.allowsUndo = true
            view.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            view.string = text
            view.delegate = context.coordinator
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let view = scroll.documentView as? NSTextView else { return }
        // Only a change from outside (the text cleared after a send) is written back.
        if view.string != text { view.string = text }
        view.isEditable = editable
        view.textColor = editable ? .textColor : .disabledControlTextColor
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}
