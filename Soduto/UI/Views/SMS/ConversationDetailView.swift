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
        // thread.messages is newest-first. groupedByDay preserves that order, producing
        // groups newest-day → oldest-day. After the 180° rotation, index-0 of the
        // LazyVStack (newest group's newest message) appears at the visual bottom.
        let grouped = Self.groupedByDay(thread.messages)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(grouped, id: \.dayStart) { group in
                    // Messages first in logical order so the separator lands visually
                    // ABOVE the group's messages after the 180° flip.
                    ForEach(Array(group.messages.enumerated()), id: \.element.id) { idx, message in
                        MessageBubbleView(
                            message: message,
                            model: model,
                            isGroupThread: thread.addresses.count > 1,
                            isContinuation: Self.isContinuation(messages: group.messages, at: idx)
                        )
                        .id(message.id)
                        .padding(.horizontal, 16)
                        .scaleEffect(x: 1, y: -1)
                    }
                    dateSeparator(group.dayStart)
                }

                // Load-older sentinel at the logical END = visual TOP after rotation,
                // where the user scrolls to reach older messages.
                if !model.hasReachedStartOfThread(threadId) {
                    HStack {
                        Spacer()
                        LoadMoreBubble(
                            isLoading: model.isLoadingThread(threadId),
                            action: { model.loadMoreInThread(threadId) },
                            iconName: "chevron.down",  // rotated 180° → appears as ∧ (up)
                            tooltip: "Load older messages"
                        )
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .scaleEffect(x: 1, y: -1)
                }
            }
            // Logical .top = visual bottom after rotation: gap between newest msg and compose bar.
            .padding(.top, 12)
        }
        .scaleEffect(x: 1, y: -1)
        // Fresh ScrollView per thread resets offset to 0 (= visual bottom = newest messages)
        .id(threadId)
    }

    @ViewBuilder
    private func dateSeparator(_ date: Date) -> some View {
        HStack {
            Spacer()
            Text(Self.dateSeparatorFormatter.string(from: date))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
            Spacer()
        }
        // Padding values are swapped vs. their visual intent because this row lives inside
        // the 180°-rotated ScrollView: logical .bottom → visual top, logical .top → visual bottom.
        // Visual result: 14 pt above separator (from previous day's last message), 4 pt below.
        .padding(.top, 4)
        .padding(.bottom, 14)
        .scaleEffect(x: 1, y: -1)
    }

    // MARK: - Grouping

    private struct DayGroup: Identifiable {
        let dayStart: Date
        let messages: [SMSService.Message]
        var id: Date { dayStart }
    }

    /// Group messages by calendar day (user's locale). Input is newest-first; output groups
    /// are also newest-day-first, matching the rotation-trick layout order.
    private static func groupedByDay<S: Sequence>(_ messages: S) -> [DayGroup]
    where S.Element == SMSService.Message {
        let cal = Calendar.current
        var groups: [DayGroup] = []
        var currentDay: Date?
        var bucket: [SMSService.Message] = []
        for msg in messages {
            let day = cal.startOfDay(for: msg.date)
            if currentDay == nil || currentDay != day {
                if let cd = currentDay {
                    groups.append(DayGroup(dayStart: cd, messages: bucket))
                }
                currentDay = day
                bucket = [msg]
            } else {
                bucket.append(msg)
            }
        }
        if let cd = currentDay {
            groups.append(DayGroup(dayStart: cd, messages: bucket))
        }
        return groups
    }

    /// Returns true when the message at `idx` is a visual continuation of the one directly
    /// above it. In newest-first order, "directly above" = `idx + 1` (the older message).
    /// Continuation suppresses the sender label and tightens bubble spacing.
    private static func isContinuation(messages: [SMSService.Message], at idx: Int) -> Bool {
        let nextIdx = idx + 1
        guard nextIdx < messages.count else { return false }
        let above = messages[nextIdx]   // older; appears directly above curr after rotation
        let curr  = messages[idx]
        guard above.type.isFromMe == curr.type.isFromMe else { return false }
        let aboveSender = curr.type.isFromMe ? "self" : (above.addresses.first ?? "")
        let currSender  = curr.type.isFromMe ? "self" : (curr.addresses.first ?? "")
        guard aboveSender == currSender else { return false }
        return abs(curr.date.timeIntervalSince(above.date)) < 60
    }

    // MARK: - Formatter

    private static let dateSeparatorFormatter: ContextualSeparatorFormatter = ContextualSeparatorFormatter()
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
