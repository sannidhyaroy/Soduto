//
//  MessageComposeView.swift
//  Soduto
//
//  Created by Sannidhya Roy on 17/05/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI
import AppKit

/// Compose bar pinned to the bottom of `ConversationDetailView` and reused by the inline
/// new-conversation pane. Plain SMS only; MMS send is a follow-up.
///
/// Layout (matches iMessage):
/// - Attach button (disabled placeholder)
/// - Compact text editor: starts as a single line (~22 pt tall), grows up to 6 visible
///   lines as the user adds newlines (Shift+Return)
/// - Send button: paperplane glyph only when disabled, accent-filled circle with white
///   glyph when enabled. On dual-SIM phones a small badge in the bottom-right indicates
///   the active SIM (sparkles for default, numbered for SIM 1/2/…). Right-click opens a
///   menu to switch SIM.
///
/// Key handling:
/// - **Return** sends
/// - **Shift+Return** inserts a newline
/// - **Cmd+Return** also sends (muscle-memory affordance)
///
/// SwiftUI's `TextField(axis: .vertical)` on macOS doesn't reliably distinguish Return vs
/// Shift+Return, so the input is an `NSTextView` wrapped via `NSViewRepresentable` that
/// publishes its content height back through a `@Binding` (intrinsic content size alone
/// is not honored; SwiftUI keeps the view at its max).
struct MessageComposeView: View {
    @ObservedObject var model: SMSDataModel

    /// Called when the user hits send with non-empty text. Receives the trimmed body and
    /// the selected SIM (nil = default). The caller decides whether to route to an
    /// existing thread (`sendReply`) or a brand-new conversation (`sendNew`).
    let onSend: (String, Int64?) -> Void
    
    /// Extra gate beyond non-empty text.
    /// Used by the inline new-conversation pane to also require at least one recipient before enabling send.
    var additionalCanSend: Bool = true

    @State private var messageText: String = ""
    @State private var selectedSubId: Int64?
    /// Measured height of the inner `NSTextView` — single line at rest, grows up to a
    /// six-line cap as the user types newlines.
    @State private var inputHeight: CGFloat = MessageComposeView.singleLineHeight
    
    /// Approximate single-line height for the system 13 pt font + our text container inset.
    /// Used as the initial `inputHeight` and as a floor when the NSTextView hasn't laid out yet.
    static let singleLineHeight: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                attachButton
                textField
                sendButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.regularMaterial)
    }

    // MARK: - Sub-views
    
    private var attachButton: some View {
        Button {
            // MMS-send is a follow-up; base64-inline attachments in `sms.request` need their own design (channel-blocking, size cap)
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(.tertiary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(true)
        .help("Attachments coming soon")
    }
    
    private var textField: some View {
        ComposeTextEditor(
            text: $messageText,
            placeholder: "Message",
            onCommit: send,
            measuredHeight: $inputHeight
        )
        .frame(height: inputHeight)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
    }
    
    @ViewBuilder
    private var sendButton: some View {
        // Right-click menu hosts the SIM picker. Hidden entirely on single-SIM phones
        // so the bar stays minimal. (Long-press doesn't trigger SwiftUI .contextMenu on
        // macOS — only right-click does — so the menu and help text use that wording.)
        if availableSubIds.count >= 2 {
            sendButtonCore
                .contextMenu {
                    Button {
                        selectedSubId = nil
                    } label: {
                        if selectedSubId == nil {
                            Label("Default SIM", systemImage: "checkmark")
                        } else {
                            Text("Default SIM")
                        }
                    }
                    Divider()
                    ForEach(availableSubIds, id: \.self) { sub in
                        Button {
                            selectedSubId = sub
                        } label: {
                            if selectedSubId == sub {
                                Label("SIM \(sub)", systemImage: "checkmark")
                            } else {
                                Text("SIM \(sub)")
                            }
                        }
                    }
                }
        } else {
            sendButtonCore
        }
    }
    
    private var sendButtonCore: some View {
        Button(action: send) {
            sendButtonContent
                .overlay(alignment: .bottomTrailing) {
                    if availableSubIds.count >= 2 {
                        simBadge
                            .offset(x: 4, y: 4)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .keyboardShortcut(.return, modifiers: .command)
        .help(helpText)
    }
    
    /// Two visual states for the send button:
    /// - **Enabled**: filled accent circle with a white paperplane glyph (iMessage style)
    /// - **Disabled**: paperplane glyph only on `.secondary` foreground, no circle
    ///
    /// Keeping the disabled state circle-less avoids the "faded white glyph on faded accent fill" combination that vanishes in light mode.
    @ViewBuilder
    private var sendButtonContent: some View {
        if canSend {
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 28, height: 28)
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    // Paperplane's visual weight skews lower-left; nudging up-right a touch makes it look centered inside the circle
                    .offset(x: -1, y: 1)
            }
        } else {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
    }
    
    /// Always-visible badge on dual-SIM phones so the active SIM is unambiguous.
    /// Uses `Color.accentColor` (not orange) to match the send button when active, and a `.thickMaterial` ring so the badge reads against both the accent circle and the transparent disabled state.
    @ViewBuilder
    private var simBadge: some View {
        ZStack {
            // Background pad lets the badge sit cleanly on top of the accent circle
            // (or against the surrounding compose-bar material when send is disabled).
            Circle()
                .fill(Color(NSColor.windowBackgroundColor))
                .frame(width: 15, height: 15)
            simBadgeGlyph
        }
    }

    @ViewBuilder
    private var simBadgeGlyph: some View {
        if let sub = selectedSubId {
            if (0...50).contains(sub) {
                Image(systemName: "\(sub).circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white, Color.accentColor)
            } else {
                Text("\(sub)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor))
            }
        } else {
            // Default SIM — sparkles distinguishes "no override picked" from a numbered
            // SIM without leaving the corner blank.
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 13, height: 13)
                Image(systemName: "sparkles")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }
    
    // MARK: - Helpers
    
    private var availableSubIds: [Int64] {
        Array(model.seenSubIds).sorted()
    }
    
    private var canSend: Bool {
        additionalCanSend
        && !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private var helpText: String {
        if availableSubIds.count >= 2 {
            let simLabel = selectedSubId.map { "SIM \($0)" } ?? "default SIM"
            return "Send via \(simLabel) (↩ or ⌘↩) — right-click to choose SIM"
        }
        return "Send (↩ or ⌘↩)"
    }
    
    private func send() {
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !trimmed.isEmpty else { return }
        onSend(trimmed, selectedSubId)
        messageText = ""
        inputHeight = Self.singleLineHeight
    }
}

// MARK: - NSTextView-backed editor

/// `NSViewRepresentable` that hosts an `NSTextView` and publishes its content-driven height to SwiftUI via a `@Binding`.
/// SwiftUI doesn't honor `NSView.intrinsicContentSize` of an `NSTextView` (it tends to keep the view at its allowed maximum), so an explicit `.frame(height:)` driven by the measured height is the only reliable way to get the "single-line at rest, grow with content, soft cap at N lines" behavior.
private struct ComposeTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onCommit: () -> Void
    @Binding var measuredHeight: CGFloat
    
    /// Soft cap on visible lines before the text view stops growing.
    /// Beyond this the content scrolls within the same height (`NSTextView` handles this natively).
    private static let maxVisibleLines: CGFloat = 6
    
    func makeNSView(context: Context) -> ComposeNSTextView {
        let tv = ComposeNSTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.font = NSFont.systemFont(ofSize: 13)
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 0, height: 3)
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.placeholderString = placeholder
        tv.onCommit = onCommit
        tv.string = text
        // First measurement comes after the view is in the hierarchy and has a width
        DispatchQueue.main.async {
            measureHeight(for: tv)
        }
        return tv
    }
    
    func updateNSView(_ nsView: ComposeNSTextView, context: Context) {
        if nsView.string != text {
            nsView.string = text
            nsView.needsDisplay = true
        }
        nsView.placeholderString = placeholder
        nsView.onCommit = onCommit
        DispatchQueue.main.async {
            measureHeight(for: nsView)
        }
    }
    
    private func measureHeight(for tv: ComposeNSTextView) {
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let lineHeight = (tv.font ?? NSFont.systemFont(ofSize: 13)).boundingRectForFont.height
        let inset = tv.textContainerInset.height * 2
        let minH = lineHeight + inset
        let maxH = lineHeight * Self.maxVisibleLines + inset
        let newH = min(max(used.height + inset, minH), maxH)
        if abs(measuredHeight - newH) > 0.5 {
            measuredHeight = newH
        }
    }
    
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposeTextEditor
        init(parent: ComposeTextEditor) { self.parent = parent }
        
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? ComposeNSTextView else { return }
            parent.text = tv.string
            // Re-measure on every change so the row grows/shrinks immediately
            DispatchQueue.main.async { [parent] in
                parent.measureHeight(for: tv)
            }
        }
    }
}

/// `NSTextView` subclass that:
/// 1. routes Return → commit, Shift+Return → newline, Cmd+Return → commit
/// 2. draws its own placeholder when empty and unfocused
private final class ComposeNSTextView: NSTextView {
    var placeholderString: String = ""
    var onCommit: (() -> Void)?
    
    override func keyDown(with event: NSEvent) {
        // Return key (keyCode 36) and numpad Enter (76)
        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.shift) {
                // Shift+Return → literal newline through the text system (preserves undo and word-wrap consistency)
                insertNewlineIgnoringFieldEditor(self)
                return
            }
            // Plain Return and Cmd+Return both send
            // The SwiftUI `.keyboardShortcut` doesn't fire while `NSTextView` is first responder, so route both here
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty,
              window?.firstResponder !== self else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let origin = NSPoint(x: textContainerInset.width, y: textContainerInset.height)
        (placeholderString as NSString).draw(at: origin, withAttributes: attrs)
    }
    
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        needsDisplay = true
        return result
    }
    
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        needsDisplay = true
        return result
    }
}
