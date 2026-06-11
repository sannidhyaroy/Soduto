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
            MessageComposeView(model: model) { body, subId in
                model.sendReply(in: threadId, body: body, subId: subId)
            }
        }
    }
    
    @ViewBuilder
    private func content(for thread: SMSService.ConversationThread) -> some View {
        // `thread.messages` is newest-first
        // `clusterMessages` preserves that order, producing clusters newest-first
        // After the Y-flip, index-0 of the LazyVStack (newest cluster's newest message) appears at the visual bottom
        let clusters = Self.clusterMessages(thread.messages)

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

    /// Group `messages` (newest-first) into time-based clusters. Output preserves the
    /// newest-first order. A cluster boundary is inserted whenever the gap between two
    /// consecutive messages exceeds `clusterGapThreshold`; sender identity is NOT a
    /// boundary (those clusters often span a back-and-forth in a single sitting).
    private static func clusterMessages(_ messages: [SMSService.Message]) -> [MessageCluster] {
        guard !messages.isEmpty else { return [] }
        let cal = Calendar.current

        // First pass: split into raw clusters by time gap.
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
