//
//  ShellEditorView.swift
//  Soduto
//
//  Created by Sannidhya Roy on 19/06/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI
import AppKit

// MARK: - ShellEditorView

/// A multi-line shell command editor with a left gutter that shows a green `$`
/// for each hard-newline line. Soft-wrapped continuation rows render no prompt,
/// so users can visually distinguish a single logical line that wrapped from
/// multiple statements typed across lines.
///
/// The editor itself draws no background — wrap it in a styled container
/// (dark fill + rounded border) to get the full terminal look.
struct ShellEditorView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        
        let textView = ShellTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.placeholder = placeholder
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 4
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = NSColor(white: 0.95, alpha: 1)
        textView.insertionPointColor = .white
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.string = text
        
        scrollView.documentView = textView
        
        let ruler = ShellPromptRulerView(scrollView: scrollView, orientation: .verticalRuler)
        ruler.clientView = textView
        ruler.ruleThickness = 20
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        
        return scrollView
    }
    
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ShellTextView else { return }
        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
        }
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            if selectedRange.location <= (text as NSString).length {
                textView.setSelectedRange(selectedRange)
            }
        }
        scrollView.verticalRulerView?.needsDisplay = true
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    
    // MARK: Coordinator
    
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ShellEditorView
        
        init(_ parent: ShellEditorView) {
            self.parent = parent
        }
        
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }
}


// MARK: - ShellTextView

/// NSTextView subclass that renders a placeholder string when empty,
/// styled to read on the dark terminal background
private final class ShellTextView: NSTextView {
    
    var placeholder: String = "" {
        didSet { needsDisplay = true }
    }
    
    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor(white: 1, alpha: 0.3)
        ]
        let text = NSAttributedString(string: placeholder, attributes: attributes)
        let origin = NSPoint(
            x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
            y: textContainerOrigin.y
        )
        text.draw(at: origin)
    }
}


// MARK: - ShellPromptRulerView

/// Vertical gutter that draws a green `$` for each line fragment that starts
/// a logical paragraph (hard newline). Soft-wrapped continuation fragments
/// get no prompt — making it visually clear which lines the user typed
private final class ShellPromptRulerView: NSRulerView {
    
    override var isFlipped: Bool { true }
    
    override func draw(_ dirtyRect: NSRect) {
        // Skip the default ruler chrome (tick marks, numerals) — we want a
        // clean transparent gutter that lets the parent's dark fill show through
        drawHashMarksAndLabels(in: dirtyRect)
    }
    
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        
        let promptFont = textView.font ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let prompt = NSAttributedString(string: "$", attributes: [
            .font: promptFont,
            .foregroundColor: NSColor.systemGreen.withAlphaComponent(0.85)
        ])
        let promptSize = prompt.size()
        let drawX = bounds.width - promptSize.width - 4
        let containerOrigin = textView.textContainerOrigin
        
        func drawPrompt(forLineAt fragmentRect: NSRect) {
            let yInTextView = fragmentRect.minY + containerOrigin.y
            let yInRuler = self.convert(NSPoint(x: 0, y: yInTextView), from: textView).y
            let drawY = yInRuler + (fragmentRect.height - promptSize.height) / 2
            prompt.draw(at: NSPoint(x: drawX, y: drawY))
        }
        
        let nsString = textView.string as NSString
        
        // Empty editor: still show a single prompt so users know where to type
        if nsString.length == 0 {
            let yInTextView = textView.textContainerOrigin.y
            let yInRuler = convert(NSPoint(x: 0, y: yInTextView), from: textView).y
            prompt.draw(at: NSPoint(x: drawX, y: yInRuler))
            return
        }
        
        // Ensure layout is current before enumerating fragments
        layoutManager.ensureLayout(for: textContainer)
        
        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragmentRect, _, _, fragmentGlyphRange, _ in
            let charRange = layoutManager.characterRange(forGlyphRange: fragmentGlyphRange, actualGlyphRange: nil)
            
            // A fragment starts a logical paragraph if it's at position 0 or
            // the character immediately before its start is a hard newline
            let isParagraphStart: Bool
            if charRange.location == 0 {
                isParagraphStart = true
            } else {
                let prev = nsString.substring(with: NSRange(location: charRange.location - 1, length: 1))
                isParagraphStart = (prev == "\n")
            }
            guard isParagraphStart else { return }
            drawPrompt(forLineAt: fragmentRect)
        }
        
        // When the text ends with `\n`, the layout manager exposes an
        // `extraLineFragmentRect` representing the insertion point on the
        // following empty line. Draw a prompt there so pressing Enter shows
        // a `$` immediately rather than waiting for the first character
        let extraRect = layoutManager.extraLineFragmentRect
        if extraRect.height > 0 {
            drawPrompt(forLineAt: extraRect)
        }
    }
}


// MARK: - Preview

#Preview {
    StatefulPreviewWrapper("""
    echo "starting backup"
    rsync -avz --progress ~/Documents /Volumes/Backup
    echo "done"
    """) { binding in
        ShellEditorView(text: binding)
            .frame(width: 380, height: 140)
            .padding(8)
            .background(Color.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding()
    }
}

private struct StatefulPreviewWrapper<Value, Content: View>: View {
    @State private var value: Value
    let content: (Binding<Value>) -> Content
    init(_ initial: Value, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        self._value = State(initialValue: initial)
        self.content = content
    }
    var body: some View { content($value) }
}
