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
    /// Per-thread "what SIM to use" selection.
    /// Encoded as an enum so we can distinguish "Smart auto-pick" (context-dependent) from "phone's default SIM" (explicit no-override).
    /// Resolved to an `Int64?` at send time by `resolveSendSubId()`.
    enum SIMSelection: Hashable {
        /// Auto-pick the SIM that received the most recent incoming message in the open thread.
        /// Only meaningful when `threadId` is non-nil.
        case smart
        /// Send `sub_id: nil` and let the phone fall back to its system default.
        case phoneDefault
        /// Always send with this exact `sub_id`.
        case specific(Int64)
    }
    
    @ObservedObject var model: SMSDataModel
    
    /// Called when the user hits send with non-empty text.
    /// Receives the trimmed body and the resolved SIM (nil = phone default).
    /// The caller decides whether to route to an existing thread (`sendReply`) or a brand-new conversation (`sendNew`).
    let onSend: (String, Int64?) -> Void
    
    /// Extra gate beyond non-empty text.
    /// Used by the inline new-conversation pane to also require at least one recipient before enabling send.
    var additionalCanSend: Bool = true
    
    /// Thread context for Smart SIM resolution + the "Sending with X" pre-send label.
    /// `nil` from `NewConversationView` (no thread yet → no incoming to match against).
    var threadId: Int64? = nil
    
    @State private var messageText: String = ""
    @State private var simSelection: SIMSelection
    /// Measured height of the inner `NSTextView`; single line at rest, grows up to a six-line cap as the user types newlines.
    @State private var inputHeight: CGFloat = MessageComposeView.singleLineHeight
    
    /// Approximate single-line height for the system 13 pt font + our text container inset.
    /// Used as the initial `inputHeight` and as a floor when the NSTextView hasn't laid out yet.
    static let singleLineHeight: CGFloat = 22
    
    init(model: SMSDataModel, onSend: @escaping (String, Int64?) -> Void, additionalCanSend: Bool = true, threadId: Int64? = nil) {
        self.model = model
        self.onSend = onSend
        self.additionalCanSend = additionalCanSend
        self.threadId = threadId
        // Default to Smart when we have a thread to learn from (matches the user's expectation that replies usually go on the same SIM as the incoming side)
        // Falls back to phoneDefault for brand-new conversations
        self._simSelection = State(initialValue: threadId != nil ? .smart : .phoneDefault)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if shouldShowSendingWithLabel {
                sendingWithLabel(subId: resolveSendSubId())
            }
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
    
    /// Centered "Sending with X" inline label rendered just above the compose bar when the next send's SIM will differ from the most recent outgoing message's SIM.
    /// Suppressed when there's no thread context, no prior outgoing to compare against, or when the resolved SIM matches the previous outgoing (no transition to flag).
    /// Visual treatment matches the in-thread SIM-transition marker for consistency.
    @ViewBuilder
    private func sendingWithLabel(subId: Int64?) -> some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(.secondary)
                .frame(height: 1)
                .opacity(0.25)
            Text(ConversationDetailView.sendingWithAttributed(subId: subId))
                .font(.caption2.weight(.semibold))
                .fixedSize()
            Rectangle()
                .fill(.secondary)
                .frame(height: 1)
                .opacity(0.25)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
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
        // Right-click menu hosts the SIM picker
        // Hidden entirely on single-SIM phones so the bar stays minimal
        // Smart SIM only appears when there's a thread to learn from (it auto-picks the SIM of the most recent incoming message); the new-conversation pane stays on Default-or-Specific because there's no incoming history to read
        if availableSubIds.count >= 2 {
            sendButtonCore
                .contextMenu {
                    if threadId != nil {
                        Button {
                            simSelection = .smart
                        } label: {
                            if case .smart = simSelection {
                                Label("Smart SIM", systemImage: "checkmark")
                            } else {
                                Text("Smart SIM")
                            }
                        }
                        .help("Auto-pick the SIM that received the last incoming message")
                    }
                    Button {
                        simSelection = .phoneDefault
                    } label: {
                        if case .phoneDefault = simSelection {
                            Label("Default SIM", systemImage: "checkmark")
                        } else {
                            Text("Default SIM")
                        }
                    }
                    .help("Let the phone choose using its system default")
                    Divider()
                    ForEach(availableSubIds, id: \.self) { sub in
                        Button {
                            simSelection = .specific(sub)
                        } label: {
                            if case .specific(let s) = simSelection, s == sub {
                                Label("SIM \(sub)", systemImage: "checkmark")
                            } else {
                                Text("SIM \(sub)")
                            }
                        }
                        .help("Always send via SIM \(sub)")
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
            Circle()
                .fill(Color(NSColor.windowBackgroundColor))
                .frame(width: 15, height: 15)
            simBadgeGlyph
        }
    }
    
    @ViewBuilder
    private var simBadgeGlyph: some View {
        switch simSelection {
        case .smart:
            // Sparkles = auto/intelligent
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 13, height: 13)
                Image(systemName: "sparkles")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
        case .phoneDefault:
            // simcard.2.fill = "system SIM", reads as "phone decides which SIM to use"
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 13, height: 13)
                Image(systemName: "simcard.2.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
        case .specific(let sub):
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
            return "⏎ send · ⇧⏎ new line · right-click for SIM"
        }
        return "⏎ send · ⇧⏎ new line"
    }
    
    /// Translate `simSelection` into the concrete `sub_id` to send.
    /// Smart walks the thread's messages for the most recent incoming with a real sub_id; falls back to nil (phone default) if nothing matches.
    private func resolveSendSubId() -> Int64? {
        switch simSelection {
        case .phoneDefault:
            return nil
        case .specific(let id):
            return id
        case .smart:
            guard let threadId,
                  let thread = model.conversations[threadId] else { return nil }
            return thread.messages.first(where: {
                !$0.type.isFromMe && ($0.subId ?? 0) > 0
            })?.subId
        }
    }
    
    /// Most recent outgoing message's `sub_id`, or `nil` if there's no outgoing yet.
    /// Used to decide whether to show the "Sending with X" label above the compose bar.
    private var mostRecentOutgoingSubId: Int64? {
        guard let threadId,
              let thread = model.conversations[threadId] else { return nil }
        return thread.messages.first(where: { $0.type.isFromMe })?.subId
    }
    
    private var hasOutgoingInThread: Bool {
        guard let threadId,
              let thread = model.conversations[threadId] else { return false }
        return thread.messages.contains(where: { $0.type.isFromMe })
    }
    
    /// True when the next send will land on a different SIM than the most recent outgoing in this thread.
    /// Drives whether the pre-send "Sending with X" label renders above the compose bar.
    /// Suppressed when there's no thread context, no prior outgoing to compare against, or when the resolved SIM matches last time.
    private var shouldShowSendingWithLabel: Bool {
        guard threadId != nil, hasOutgoingInThread else { return false }
        return resolveSendSubId() != mostRecentOutgoingSubId
    }
    
    /// Human-readable SIM name.
    static func simLabelText(for subId: Int64?) -> String {
        guard let subId else { return "default SIM" }
        // TODO: Generic for now ("SIM 1"), but a protocol extension can ship per-`sub_id` carrier names ("Airtel") and this is the single seam to swap them in
        return "SIM \(subId)"
    }
    
    private func send() {
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !trimmed.isEmpty else { return }
        onSend(trimmed, resolveSendSubId())
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
