//
//  ConversationListView.swift
//  Soduto
//
//  Created by Sannidhya Roy on 17/05/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI

/// Sidebar list of all conversations on the bound device.
///
/// Behavior:
/// - **Search** at top filters by contact name, raw address, or latest message body.
/// - **Rows** show avatar (contact photo or generated initials), contact/address title,
///   latest message snippet, relative timestamp, and an unread badge.
/// - **Infinite scroll**: a bottom sentinel auto-triggers `loadMoreConversations` when
///   it appears. The sentinel shows a downward chevron when idle and a spinner while
///   loading; it disappears entirely once `hasReachedEndOfConversations` is true.
///   The native NSScrollView elastic bounce provides the "pull" feel.
struct ConversationListView: View {
    @ObservedObject var model: SMSDataModel
    /// When true, the compose button is rendered in this sidebar's title bar slot.
    /// When false, `SMSView` is rendering the same button into the detail pane's toolbar instead (sidebar is collapsed).
    /// `SMSView` is the single source of truth for which configuration is active.
    let showComposeButton: Bool
    @FocusState private var isSearchFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            conversationList
        }
        // Intentionally no `.navigationTitle` here; SMSView owns the window title via `.navigationTitle`/`.navigationSubtitle` driven by the model
        //
        // Compose button anchored to the trailing edge of the sidebar's slice of the window toolbar (matches Apple Messages)
        // SwiftUI's `.primaryAction` placement alone wasn't enough on macOS NavigationSplitView; the item landed next to the sidebar toggle on the leading edge
        // Wrapping in `ToolbarItemGroup` with a leading `Spacer()` pushes the button to the trailing edge
        .toolbar {
            if showComposeButton {
                ToolbarItemGroup(placement: .primaryAction) {
                    Spacer()
                    Button {
                        model.startNewConversation()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .help("New Message")
                    .disabled(model.composingNew)
                }
            }
        }
    }
    
    // MARK: Search
    
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isSearchFocused)
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        // Apple-style focus ring: accent-colored border + soft outer glow when typing
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isSearchFocused ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .animation(.easeInOut(duration: 0.15), value: isSearchFocused)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
    
    // MARK: List
    
    private var conversationList: some View {
        let visible = model.visibleConversations
        return Group {
            if visible.isEmpty && !model.composingNew {
                emptyState
            } else {
                // `List` uses the same Int64? type for both real thread IDs and the sentinel "new message" row; we encode the sentinel as `Int64.min` which is otherwise unreachable as a real thread ID
                // Selection is routed through `composeAwareSelection` so picking the sentinel toggles the model's `composingNew` flag rather than calling `selectThread`
                List(selection: composeAwareSelection) {
                    if model.composingNew {
                        NewMessageSidebarRow {
                            model.cancelNewConversation()
                        }
                        .tag(Int64?.some(Self.newMessageSentinelId))
                        .listRowSeparator(.hidden)
                    }
                    ForEach(visible) { thread in
                        ConversationRowView(thread: thread, model: model)
                            .tag(Int64?.some(thread.id))
                    }
                    if !model.hasReachedEndOfConversations {
                        loadMoreSentinel
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }
    
    /// Sentinel used in `List` selection to represent the transient "New Message" row.
    /// `Int64.min` is unreachable as a real Android thread id (which is always non-negative).
    private static let newMessageSentinelId: Int64 = .min
    
    private var composeAwareSelection: Binding<Int64?> {
        Binding(
            get: {
                if model.composingNew { return Self.newMessageSentinelId }
                return model.selectedThreadId
            },
            set: { newValue in
                if newValue == Self.newMessageSentinelId {
                    // Re-selecting the sentinel is a no-op (it's already active)
                    if !model.composingNew { model.startNewConversation() }
                } else {
                    model.selectThread(newValue)
                }
            }
        )
    }
    
    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            if model.isLoadingMoreConversations {
                ProgressView()
                    .controlSize(.small)
                Text("Loading conversations…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if !model.searchText.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text("No matches")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "tray")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text("No conversations yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: "Load-more" Sentinel
    
    /// Circular "bubble" button at the end of the conversation list.
    /// Springs in on first appearance, scales up subtly on hover, scales down briefly on press.
    /// Idle shows a bold chevron-down; tapping it kicks off the next page fetch and the icon cross-fades to a small spinner until the response settles.
    /// SwiftUI's `List` on macOS doesn't reliably re-fire `.onAppear` for cells that scroll into view (unlike `LazyVStack`), so the load is strictly click-driven.
    @ViewBuilder
    private var loadMoreSentinel: some View {
        HStack {
            Spacer()
            LoadMoreBubble(
                isLoading: model.isLoadingMoreConversations,
                action: { model.loadMoreConversations() }
            )
            Spacer()
        }
        .padding(.vertical, 12)
    }
}

// MARK: - "Load-more" Bubble

struct LoadMoreBubble: View {
    let isLoading: Bool
    let action: () -> Void
    /// SF Symbol shown when idle.
    /// Defaults to `chevron.down`, which points downward to indicate "more below" in the conversation list.
    /// The message-thread sentinel also passes `chevron.down` because the row lives inside a 180°-rotated ScrollView, which flips the glyph to appear as ∧ (up), correct for "load older messages above".
    var iconName: String = "chevron.down"
    var tooltip: String = "Load older conversations"
    
    @State private var hasAppeared = false
    @State private var isHovering = false
    @GestureState private var isPressed = false
    
    var body: some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    // Pure SwiftUI Shape, no `NSProgressIndicator` wrapping, no NSView intrinsic-size constraints, no `max < min` AutoLayout race when the outer bubble scales during hover/press/appearance animations
                    SoftSpinner(diameter: 14, lineWidth: 1.8, color: .primary.opacity(0.7))
                        .transition(.opacity)
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.primary.opacity(0.75))
                        .transition(.opacity)
                }
            }
            .frame(width: 34, height: 34)
            // `.thickMaterial` has noticeably more contrast than `.regularMaterial` against dark sidebar backgrounds, keeps the bubble readable in both modes
            .background(Circle().fill(.thickMaterial))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 4, x: 0, y: 2)
            .animation(.easeInOut(duration: 0.18), value: isLoading)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .help(isLoading ? "Loading…" : tooltip)
        .scaleEffect(scaleValue)
        .opacity(hasAppeared ? 1.0 : 0.0)
        .animation(.spring(response: 0.5, dampingFraction: 0.55), value: hasAppeared)
        .animation(.spring(response: 0.28, dampingFraction: 0.65), value: isHovering)
        .animation(.spring(response: 0.2, dampingFraction: 0.55), value: isPressed)
        .onHover { isHovering = $0 }
        .onAppear { hasAppeared = true }
        .simultaneousGesture(
            // Mouse-down springs the bubble inward; release snaps back.
            // Doesn't swallow the click; Button still fires its action on a normal click
            DragGesture(minimumDistance: 0)
                .updating($isPressed) { _, state, _ in state = true }
        )
    }
    
    private var scaleValue: CGFloat {
        if !hasAppeared { return 0.1 }
        let base: CGFloat = isHovering ? 1.08 : 1.0
        return isPressed ? base * 0.88 : base
    }
}

// MARK: - "New Message" Transient Row

/// Top-of-sidebar row shown while the user is composing a brand-new conversation.
/// Hover reveals an X on the trailing edge that discards the in-progress draft (mirroring Apple Messages).
/// The row itself selects the inline new-conversation detail pane.
private struct NewMessageSidebarRow: View {
    let onDiscard: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: 40, height: 40)
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            Text("New Message")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isHovering {
                Button(action: onDiscard) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .help("Discard new message")
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }
}

// MARK: - Row

private struct ConversationRowView: View {
    let thread: SMSService.ConversationThread
    @ObservedObject var model: SMSDataModel
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.threadTitle(for: thread))
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Self.relativeFormatter.string(from: thread.latestDate))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    if let latest = thread.latestMessage, latest.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Text(snippet)
                        .font(.system(size: 12))
                        .foregroundStyle(thread.unreadCount > 0 ? .primary : .secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    if thread.unreadCount > 0 {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private var snippet: String {
        guard let body = thread.latestMessage?.body else { return "" }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Attachment" : trimmed
    }
    
    @ViewBuilder
    private var avatar: some View {
        if let img = model.avatarImage(for: thread) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 40)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.85))
                )
        }
    }
    
    /// Compact relative timestamp: HH:mm today, Yesterday, weekday this week, localized short date older.
    private static let relativeFormatter = ContextualDateFormatter()
}

/// Activity indicator (SwiftUI shape).
/// Avoids the `NSProgressIndicator` wrapping that SwiftUI's `ProgressView` uses on macOS: that wrapping declares rigid intrinsic-size constraints which log `max < min` AutoLayout warnings whenever its parent view scales (e.g. via `.scaleEffect` during hover/press/appearance animations on the load-more bubble).
/// A trimmed Circle with a continuous rotation has no such constraints.
struct SoftSpinner: View {
    var diameter: CGFloat = 14
    var lineWidth: CGFloat = 1.8
    var color: Color = .secondary
    
    @State private var isRotating = false
    
    var body: some View {
        Circle()
            .trim(from: 0.0, to: 0.75)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: diameter, height: diameter)
            .rotationEffect(.degrees(isRotating ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: isRotating)
            .onAppear { isRotating = true }
    }
}

/// Picks a compact format based on how far in the past the given date is.
private final class ContextualDateFormatter {
    private let time = DateFormatter()
    private let weekday = DateFormatter()
    private let dayMonth = DateFormatter()
    private let dayMonthYear = DateFormatter()
    
    init() {
        time.dateFormat = "HH:mm"
        weekday.dateFormat = "EEE"
        dayMonth.setLocalizedDateFormatFromTemplate("MMM d")
        dayMonthYear.setLocalizedDateFormatFromTemplate("M/d/yy")
    }
    
    func string(from date: Date) -> String {
        let cal = Calendar.current
        let now = Date()
        if cal.isDateInToday(date) { return time.string(from: date) }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let daysAgo = cal.dateComponents([.day], from: date, to: now).day ?? 0
        if daysAgo < 7 { return weekday.string(from: date) }
        if cal.component(.year, from: date) == cal.component(.year, from: now) {
            return dayMonth.string(from: date)
        }
        return dayMonthYear.string(from: date)
    }
}
