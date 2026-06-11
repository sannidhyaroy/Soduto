//
//  ConversationDetailView.swift
//  Soduto
//
//  Created by Sannidhya Roy on 17/05/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI

/// Message thread view for a single conversation.
///
/// Scroll uses a Y-flip trick for reliable bottom-anchor behaviour:
/// - The `ScrollView` gets `.scaleEffect(x: 1, y: -1)` so scroll offset 0 = visual bottom.
///   Using `scaleEffect` (Y-only flip) rather than `rotationEffect(180°)` keeps the scroll
///   indicator on the right side; 180° rotation flips X too, moving the bar to the left.
/// - Each row also gets `.scaleEffect(x: 1, y: -1)` to un-flip the content.
/// - `thread.messages` is newest-first; index-0 lands at the visual bottom without any
///   programmatic `scrollTo` calls.
/// - `.id(threadId)` resets offset to 0 on every thread switch; no `onAppear` needed.
/// - Live new messages prepended at index-0 are immediately visible when the user is at
///   the bottom; scrolling up to read history keeps the user's position undisturbed.
///
/// **Cluster headers (Google Messages style):** messages are grouped into time clusters
/// separated by gaps greater than `clusterGapThreshold`. Each cluster gets ONE header
/// row above its messages: combined "Day · Time" for the chronologically first cluster
/// of each calendar day, time-only for subsequent clusters within the same day. Replaces
/// the older separate day-separator + per-message timestamp pattern. Per-message
/// timestamps still render inside `MessageBubbleView` so users can see exact times when
/// they expand a bubble (separate concern from cluster grouping).
struct ConversationDetailView: View {
    @ObservedObject var model: SMSDataModel
    let threadId: Int64
    
    var body: some View {
        VStack(spacing: 0) {
            if let thread = model.conversations[threadId] {
                content(for: thread)
            } else {
                ContentUnavailableView(
                    "Conversation unavailable",
                    systemImage: "exclamationmark.bubble"
                )
            }
            MessageComposeView(
                model: model,
                onSend: { body, subId in
                    model.sendReply(in: threadId, body: body, subId: subId)
                },
                threadId: threadId
            )
        }
    }
    
    @ViewBuilder
    private func content(for thread: SMSService.ConversationThread) -> some View {
        // `thread.messages` is newest-first
        // `clusterMessages` preserves that order, producing clusters newest-first
        // After the Y-flip, index-0 of the LazyVStack (newest cluster's newest message) appears at the visual bottom
        let clusters = Self.clusterMessages(thread.messages)
        let simTransitions = Self.simTransitionMessageIds(thread.messages)
        let unreadBoundaryId = Self.unreadBoundaryMessageId(thread.messages)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let latestMessageId = thread.messages.first?.id
                ForEach(clusters) { cluster in
                    // Messages first in logical order so the header lands visually ABOVE
                    // the cluster's messages after the Y-flip.
                    ForEach(Array(cluster.messages.enumerated()), id: \.element.id) { idx, message in
                        MessageBubbleView(
                            message: message,
                            model: model,
                            isGroupThread: thread.addresses.count > 1,
                            isContinuation: Self.isContinuation(messages: cluster.messages, at: idx),
                            isLatestMessage: message.id == latestMessageId
                        )
                        .id(message.id)
                        .padding(.horizontal, 16)
                        .scaleEffect(x: 1, y: -1)

                        // Render the "Sending with X" marker AFTER the transition bubble
                        // in logical order — after the Y-flip this puts it visually ABOVE
                        // the new SIM region's first message, delimiting the boundary
                        // between the old and new SIM. Matches Google Messages.
                        if simTransitions.contains(message.id) {
                            sendingWithMarker(subId: message.subId)
                        }
                        // Unread divider: rendered after the OLDEST unread incoming
                        // message in logical order → visually ABOVE that message,
                        // marking the read↔unread boundary in the thread.
                        if message.id == unreadBoundaryId {
                            unreadDivider()
                        }
                    }
                    clusterHeader(for: cluster)
                }
                
                // Load-older sentinel at the logical END = visual TOP after flip, where the user scrolls to reach older messages
                if !model.hasReachedStartOfThread(threadId) {
                    HStack {
                        Spacer()
                        LoadMoreBubble(
                            isLoading: model.isLoadingThread(threadId),
                            action: { model.loadMoreInThread(threadId) },
                            iconName: "chevron.down",  // flipped → appears as ∧ (up)
                            tooltip: "Load older messages"
                        )
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .scaleEffect(x: 1, y: -1)
                }
            }
            // Logical .top = visual bottom after flip: gap between newest msg and compose bar
            .padding(.top, 12)
        }
        .scaleEffect(x: 1, y: -1)
        // Fresh ScrollView per thread resets offset to 0 (= visual bottom = newest messages)
        .id(threadId)
    }

    /// Centered "Sending with X" inline marker with light hairlines on either side and
    /// the SIM name styled as an accent-colored underlined link — matches Google Messages.
    /// Sits between two outgoing bubbles where the SIM changed. Y-flip is undone via
    /// `.scaleEffect` like every other row inside the inverted ScrollView.
    @ViewBuilder
    private func sendingWithMarker(subId: Int64?) -> some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(.secondary)
                .frame(height: 1)
                .opacity(0.25)
            Text(Self.sendingWithAttributed(subId: subId))
                .font(.caption2.weight(.semibold))
                .fixedSize()
            Rectangle()
                .fill(.secondary)
                .frame(height: 1)
                .opacity(0.25)
        }
        .padding(.horizontal, 16)
        // Padding swapped vs. visual intent because of the parent Y-flip.
        // Visual result: 8 pt above marker, 4 pt below.
        .padding(.top, 4)
        .padding(.bottom, 8)
        .scaleEffect(x: 1, y: -1)
    }
    
    /// Builds an AttributedString for "Sending with [SIM N]" with the prefix in secondary and the SIM name styled as a link (accent + underline).
    /// Used by both the inline thread marker and the pre-send label in the compose bar so the two look identical.
    static func sendingWithAttributed(subId: Int64?) -> AttributedString {
        var prefix = AttributedString("Sending with ")
        prefix.foregroundColor = .secondary
        
        var simName = AttributedString(MessageComposeView.simLabelText(for: subId))
        simName.foregroundColor = .accentColor
        simName.underlineStyle = .single
        
        return prefix + simName
    }

    /// Horizontal "Unread" hairline divider. Accent-colored hairlines (more prominent
    /// than the gray ones used for SIM-transition markers) so the read/unread boundary
    /// pops out — that's the divider's whole job. Rendered after the oldest unread
    /// incoming message in logical order so it lands visually ABOVE that message after
    /// the Y-flip.
    @ViewBuilder
    private func unreadDivider() -> some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 1)
                .opacity(0.55)
            Text("Unread")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .fixedSize()
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 1)
                .opacity(0.55)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .scaleEffect(x: 1, y: -1)
    }

    @ViewBuilder
    private func clusterHeader(for cluster: MessageCluster) -> some View {
        HStack {
            Spacer()
            Text(Self.headerText(for: cluster))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
            Spacer()
        }
        // Padding values are swapped vs. their visual intent because this row lives inside
        // the Y-flipped ScrollView: logical .bottom → visual top, logical .top → visual bottom.
        // Visual result: 14 pt above header (from previous cluster's last message), 4 pt below.
        .padding(.top, 4)
        .padding(.bottom, 14)
        .scaleEffect(x: 1, y: -1)
    }

    // MARK: - Clustering

    private struct MessageCluster: Identifiable {
        /// Newest message's id within the cluster — stable across renders for `ForEach`.
        let id: Int64
        /// Chronological start of the cluster (oldest message's date). Drives the header
        /// time and the "first cluster of day" decision.
        let representativeDate: Date
        /// Messages within this cluster, in newest-first order (matching `thread.messages`).
        let messages: [SMSService.Message]
        /// `true` when this cluster is the chronologically earliest within its calendar
        /// day. Used to decide whether the header shows "Day · Time" or just "Time".
        let isFirstOfDay: Bool
    }

    /// Maximum gap between two consecutive messages before they get split into separate
    /// clusters. 15 min balances "tight back-and-forth stays together" against "an hour
    /// later is a different conversation."
    private static let clusterGapThreshold: TimeInterval = 15 * 60
    
    /// Group `messages` (newest-first) into time-based clusters.
    /// Output preserves the newest-first order.
    /// A cluster boundary is inserted whenever the gap between two consecutive messages exceeds `clusterGapThreshold`; sender identity is NOT a boundary (those clusters often span a back-and-forth in a single sitting).
    private static func clusterMessages(_ messages: [SMSService.Message]) -> [MessageCluster] {
        guard !messages.isEmpty else { return [] }
        let cal = Calendar.current
        
        // First pass: split into raw clusters by time gap
        var rawClusters: [[SMSService.Message]] = []
        var current: [SMSService.Message] = [messages[0]]
        for i in 1..<messages.count {
            let msg = messages[i]          // older than previous (newest-first iteration)
            let oldestSoFar = current.last!
            let gap = oldestSoFar.date.timeIntervalSince(msg.date)
            if gap > clusterGapThreshold {
                rawClusters.append(current)
                current = [msg]
            } else {
                current.append(msg)
            }
        }
        if !current.isEmpty {
            rawClusters.append(current)
        }
        
        // Second pass: stamp `isFirstOfDay` so headers can render the day prefix only on the chronologically first cluster of each calendar day
        // In newest-first order, a cluster is first-of-day if the next OLDER cluster (idx+1) is from a different day (or doesn't exist; last cluster overall is always first of its day)
        return rawClusters.enumerated().map { (idx, msgs) in
            let representativeDate = msgs.last!.date  // oldest = chronological start
            let isFirstOfDay: Bool
            if idx == rawClusters.count - 1 {
                isFirstOfDay = true
            } else {
                let myDay = cal.startOfDay(for: representativeDate)
                let olderDay = cal.startOfDay(for: rawClusters[idx + 1].last!.date)
                isFirstOfDay = myDay != olderDay
            }
            return MessageCluster(
                id: msgs.first!.id,        // newest message's id, stable per cluster
                representativeDate: representativeDate,
                messages: msgs,
                isFirstOfDay: isFirstOfDay
            )
        }
    }
    
    /// Combined "Day · Time" for first-of-day clusters, time-only otherwise.
    private static func headerText(for cluster: MessageCluster) -> String {
        let timeStr = Self.timeOnlyFormatter.string(from: cluster.representativeDate)
        guard cluster.isFirstOfDay else { return timeStr }
        let dayStr = Self.dayPrefixFormatter.string(from: cluster.representativeDate)
        return "\(dayStr) · \(timeStr)"
    }
    
    /// Returns the ID of the message that should have the "Unread" divider rendered directly after it (which lands visually ABOVE that message after the Y-flip).
    /// The boundary message is the OLDEST unread incoming message, provided there's at least one older read message in the loaded history.
    /// If everything in the loaded slice is unread, there's no read↔unread boundary to mark, so return nil.
    private static func unreadBoundaryMessageId(_ messages: [SMSService.Message]) -> Int64? {
        let lastUnreadIdx = messages.lastIndex { !$0.isRead && !$0.type.isFromMe }
        guard let idx = lastUnreadIdx, idx + 1 < messages.count else { return nil }
        return messages[idx].id
    }
    
    /// Returns the set of message IDs that mark a SIM-transition boundary: each is an outgoing message whose `sub_id` differs from the previous (older) outgoing message's `sub_id`.
    /// Incoming messages aren't transition points; they're "received via X" which is a different concept.
    /// The OLDEST outgoing in the loaded history is intentionally excluded (no older outgoing to compare against, adding a marker there would be misleading if the thread continues off-screen).
    private static func simTransitionMessageIds(_ messages: [SMSService.Message]) -> Set<Int64> {
        var result: Set<Int64> = []
        for (i, msg) in messages.enumerated() where msg.type.isFromMe {
            // Walk to the next older outgoing message (newest-first array → higher index)
            var olderOutgoingSubId: Int64??
            for j in (i + 1)..<messages.count where messages[j].type.isFromMe {
                olderOutgoingSubId = messages[j].subId
                break
            }
            // Only flag if we found an older outgoing AND its sub_id differs
            // `Int64??` distinguishes "no older outgoing" (nil) from "older outgoing on default/nil sub_id" (.some(nil))
            if case .some(let prev) = olderOutgoingSubId, prev != msg.subId {
                result.insert(msg.id)
            }
        }
        return result
    }

    /// Within a cluster, a message is a "continuation" of the previous one if it's
    /// from the same sender within the same minute — used to tighten the spacing and
    /// suppress the sender label for cluster appearance.
    private static func isContinuation(messages: [SMSService.Message], at idx: Int) -> Bool {
        let nextIdx = idx + 1
        guard nextIdx < messages.count else { return false }
        let above = messages[nextIdx]   // older; appears directly above curr after flip
        let curr  = messages[idx]
        guard above.type.isFromMe == curr.type.isFromMe else { return false }
        let aboveSender = curr.type.isFromMe ? "self" : (above.addresses.first ?? "")
        let currSender  = curr.type.isFromMe ? "self" : (curr.addresses.first ?? "")
        guard aboveSender == currSender else { return false }
        return abs(curr.date.timeIntervalSince(above.date)) < 60
    }
    
    // MARK: - Formatters
    
    /// Short locale-aware time ("2:35 PM" / "14:35").
    /// Used both alone (subsequent clusters within the same day) and as the suffix in the combined day-prefix header.
    private static let timeOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
    
    /// Day prefix formatter used in combined headers (see `ContextualSeparatorFormatter` for the exact rules).
    private static let dayPrefixFormatter: ContextualSeparatorFormatter = ContextualSeparatorFormatter()
}

/// Day-level separator format: "Today", "Yesterday", weekday name within the past week, "MMM d" within the year, otherwise "MMM d, yyyy".
private final class ContextualSeparatorFormatter {
    private let weekday = DateFormatter()
    private let monthDay = DateFormatter()
    private let monthDayYear = DateFormatter()
    
    init() {
        weekday.dateFormat = "EEEE"
        monthDay.setLocalizedDateFormatFromTemplate("MMM d")
        monthDayYear.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
    }
    
    func string(from date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let daysAgo = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
        if daysAgo < 7 { return weekday.string(from: date) }
        if cal.component(.year, from: date) == cal.component(.year, from: Date()) {
            return monthDay.string(from: date)
        }
        return monthDayYear.string(from: date)
    }
}
