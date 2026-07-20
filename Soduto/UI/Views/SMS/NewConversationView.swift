//
//  NewConversationView.swift
//  Soduto
//
//  Created by Sannidhya Roy on 17/05/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI

/// Inline detail pane shown when the user has clicked the compose button (sidebar
/// "New Message" row is active). Inspired by Apple Messages' new-conversation layout:
/// - **Top bar**: `To:` field with committed recipient chips and a text field for typing
///   the next recipient.
/// - **Main area**: As the user types, contact suggestions appear as left-aligned
///   chat-bubble pills (mimicking incoming-message bubbles). Clicking a pill commits the
///   recipient and clears suggestions.
/// - **Bottom**: shared `MessageComposeView`. Send is disabled until at least one
///   recipient is committed AND the body is non-empty. Send routes to `SMSDataModel.sendNew`.
///
/// The inline + bubble-pill pattern is Apple's standard and works better with the
/// per-device NavigationSplitView.
struct NewConversationView: View {
    @ObservedObject var model: SMSDataModel
    
    @State private var recipientQuery: String = ""
    @FocusState private var recipientFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            recipientBar
            Divider()
            suggestionsArea
            MessageComposeView(
                model: model,
                onSend: { body, subId in
                    // Commit any in-progress typed recipient first
                    commitRawQueryIfNeeded()
                    let recipients = model.draftRecipients
                    guard !recipients.isEmpty else { return }
                    model.sendNew(to: recipients, body: body, subId: subId)
                },
                additionalCanSend: hasAtLeastOneRecipient
            )
        }
        .background(Color(NSColor.textBackgroundColor))
        .onAppear { recipientFocused = true }
    }
    
    // MARK: - Top "To:" bar
    
    private var recipientBar: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("To:")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 0) {
                FlowLayout(spacing: 6) {
                    ForEach(model.draftRecipients, id: \.self) { recipient in
                        RecipientChip(
                            text: model.displayName(for: recipient),
                            onRemove: { remove(recipient) }
                        )
                    }
                    TextField("Name or number", text: $recipientQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($recipientFocused)
                        .frame(minWidth: 140)
                        .padding(.vertical, 3)
                        .onSubmit(commitRawQueryIfNeeded)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
    
    // MARK: - Suggestion bubbles
    
    @ViewBuilder
    private var suggestionsArea: some View {
        let suggestions = filteredSuggestions
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if recipientQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    emptyHint
                } else if suggestions.isEmpty {
                    rawQueryFallback
                } else {
                    ForEach(suggestions) { suggestion in
                        SuggestionBubble(
                            suggestion: suggestion,
                            onPick: { addRecipient(suggestion.phoneNumber) }
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    @ViewBuilder
    private var emptyHint: some View {
        VStack(alignment: .center, spacing: 6) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("Type a name or number")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Pick a suggestion to add a recipient")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
    
    /// When the user has typed something but no contact matches, show the raw query as a single tappable pill so they can still commit it (e.g. shortcodes like "STOP" or a fresh number).
    @ViewBuilder
    private var rawQueryFallback: some View {
        let trimmed = recipientQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        SuggestionBubble(
            suggestion: .init(
                displayName: trimmed,
                phoneLabel: nil,
                phoneNumber: trimmed,
                source: .phone  // arbitrary; not displayed
            ),
            isRawFallback: true,
            onPick: { addRecipient(trimmed) }
        )
    }
    
    // MARK: - State helpers
    
    private var filteredSuggestions: [SMSDataModel.ContactSearchResult] {
        let raw = model.searchContacts(recipientQuery)
        let alreadyAdded = Set(model.draftRecipients.map { VCardParser.normalize(phoneNumber: $0) })
        // A single vCard often has the same number listed under multiple TEL TYPE entries (cell + mobile + home) which produces duplicate suggestion rows
        // The duplicates have identical `id` values, so SwiftUI's ForEach silently skips the dupes and reserves blank space where they would have rendered, visible as gaps between bubbles
        // Dedupe by normalized phone keeps one row per number and removes the gaps
        var seenNumbers = Set<String>()
        return raw.filter { result in
            let normalized = VCardParser.normalize(phoneNumber: result.phoneNumber)
            if alreadyAdded.contains(normalized) { return false }
            return seenNumbers.insert(normalized).inserted
        }
    }
    
    private var hasAtLeastOneRecipient: Bool {
        if !model.draftRecipients.isEmpty { return true }
        return !recipientQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private func commitRawQueryIfNeeded() {
        let trimmed = recipientQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        addRecipient(trimmed)
    }
    
    private func addRecipient(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            recipientQuery = ""
            return
        }
        if !model.draftRecipients.contains(trimmed) {
            model.draftRecipients.append(trimmed)
        }
        recipientQuery = ""
        recipientFocused = true
    }
    
    private func remove(_ recipient: String) {
        model.draftRecipients.removeAll { $0 == recipient }
        recipientFocused = true
    }
}

// MARK: - Recipient chip

private struct RecipientChip: View {
    let text: String
    let onRemove: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0.7)
            .help("Remove")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color.accentColor.opacity(isHovering ? 0.26 : 0.18))
        )
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }
}

// MARK: - Suggestion "bubble" (autocomplete pill)

/// Left-aligned chat-bubble-shaped pill that surfaces an autocomplete suggestion.
/// Visually mimics an incoming message bubble (rounded, secondary fill).
private struct SuggestionBubble: View {
    let suggestion: SMSDataModel.ContactSearchResult
    var isRawFallback: Bool = false
    let onPick: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 10) {
                Image(systemName: isRawFallback ? "questionmark.circle" : "person.crop.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(isRawFallback ? .secondary : Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    if !isRawFallback {
                        HStack(spacing: 6) {
                            Text(suggestion.phoneNumber)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            if let label = suggestion.phoneLabel, !label.isEmpty {
                                Text("·")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                Text(label)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            if suggestion.source == .mac {
                                Image(systemName: "macbook")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .help("From macOS Contacts")
                            }
                        }
                    } else {
                        Text("Send to this number as-is")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isHovering ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isHovering ? Color.accentColor.opacity(0.55) : Color.clear,
                                  lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        // Cap width so a long contact entry doesn't stretch across the entire detail pane
        .frame(maxWidth: 420, alignment: .leading)
    }
}

// MARK: - Flow layout (chip wrapping)

/// HStack-with-wrap layout for the recipient chip area.
/// SwiftUI's built-in `HStack` doesn't wrap, and chips need to flow to the next line when they fill the `To:` field.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var height: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth && rowWidth > 0 {
                height += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        height += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: height)
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
