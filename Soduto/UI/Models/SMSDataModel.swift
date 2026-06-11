//
//  SMSDataModel.swift
//  Soduto
//
//  Created by Sannidhya Roy on 17/05/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import AppKit
import Combine

/// Presentation model for a single device's SMS window.
///
/// Soduto's SMS feature is per-device: one window per phone, no central switcher (see
/// `project_sms_per_device_window.md`). This model is bound to one `Device` for its
/// entire lifetime and only mirrors that device's slice of `SMSService` state.
///
/// The model is **lightweight**: `SMSService` owns the conversation cache so it survives window close (unread badges / notifications keep working).
/// The model just debounces service state into a UI-friendly form.
@MainActor
final class SMSDataModel: ObservableObject {
    
    // MARK: Fixed bindings
    
    let device: Device
    let smsService: SMSService
    let contactsService: ContactsService
    
    // MARK: Published state
    
    @Published var selectedThreadId: Int64?
    @Published var searchText: String = ""
    
    /// When true, the sidebar shows a transient "New Message" row at the top and the detail pane shows the inline new-conversation composer (instead of a thread).
    /// Mutually exclusive with `selectedThreadId`: selecting a thread cancels this, and entering compose mode clears the thread selection.
    @Published var composingNew: Bool = false
    
    /// Recipient list for the in-progress new conversation.
    /// Mirrors what the user has committed via the inline "To:" picker (autocomplete pills or typed entries).
    /// Cleared on cancel/send.
    @Published var draftRecipients: [String] = []
    
    /// Conversations for the bound device, mirrored from `SMSService` after debounce.
    @Published private(set) var conversations: [Int64: SMSService.ConversationThread] = [:]
    
    /// Pagination snapshot for the bound device. Drives the load-more sentinel.
    @Published private(set) var listPaginationSnapshot = SMSService.ListPaginationSnapshot(isLoading: false, hasReachedEnd: false)
    
    /// Per-thread pagination snapshots for the bound device.
    /// Drives the scroll-up sentinel inside `ConversationDetailView`.
    @Published private(set) var threadPaginationSnapshots: [Int64: SMSService.ThreadPaginationSnapshot] = [:]
    
    /// Distinct `sub_id` values the phone has reported across received messages.
    /// The compose UI surfaces a SIM picker only when this has ≥2 entries (dual-SIM phones).
    @Published private(set) var seenSubIds: Set<Int64> = []
    
    /// Mirrored from `SMSService.attachmentStates`, drives the per-attachment blur/spinner/crisp state in the message bubbles.
    /// The `.downloaded(URL)` case carries the cached file path so the bubble can render the full-resolution image.
    @Published private(set) var attachmentStates: [String: SMSService.AttachmentDownloadState] = [:]
    
    /// Bumped on vCard cache changes so views that call `displayName(...)`/`photo(...)` re-evaluate after new contacts arrive.
    @Published private(set) var contactsVersion: Int = 0
    
    private var cancellables: Set<AnyCancellable> = []
    
    /// Address set (normalized) that the user just sent a new conversation to.
    /// As soon as a conversation appears in `conversations` whose addresses match this set, we auto-select it and clear the pending state.
    /// Cleared on a 30s timeout in case the phone never echoes the new thread back.
    private var pendingNewConversationAddresses: Set<String>?
    private var pendingNewConversationTimeoutTask: Task<Void, Never>?
    
    // MARK: Init
    
    init(device: Device, smsService: SMSService, contactsService: ContactsService) {
        self.device = device
        self.smsService = smsService
        self.contactsService = contactsService
        
        let deviceId = device.id
        
        smsService.$conversations
            .map { $0[deviceId] ?? [:] }
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                self?.conversations = $0
                self?.attemptPendingNewConversationSelection()
            }
            .store(in: &cancellables)
        
        smsService.$listPaginationSnapshots
            .map { $0[deviceId] ?? SMSService.ListPaginationSnapshot(isLoading: false, hasReachedEnd: false) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.listPaginationSnapshot = $0 }
            .store(in: &cancellables)
        
        smsService.$threadPaginationSnapshots
            .map { $0[deviceId] ?? [:] }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.threadPaginationSnapshots = $0 }
            .store(in: &cancellables)
        
        smsService.$seenSubIds
            .map { $0[deviceId] ?? [] }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.seenSubIds = $0 }
            .store(in: &cancellables)
        
        smsService.$attachmentStates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.attachmentStates = $0 }
            .store(in: &cancellables)
        
        contactsService.$vcardsByUID
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.contactsVersion &+= 1 }
            .store(in: &cancellables)
    }
    
    // MARK: Lifecycle hooks
    
    /// Fires on the window's first appearance, not every appearance.
    /// Triggers the lazy conversation-list bootstrap.
    func windowDidAppear() {
        smsService.bootstrapConversations(for: device)
    }
    
    // MARK: Commands
    
    func selectThread(_ id: Int64?) {
        // This method is invoked from SwiftUI's List selection binding (see `composeAwareSelection` in ConversationListView), which fires DURING the view update phase
        // Mutating `@Published` state mid-update triggers SwiftUI's "Publishing changes from within view updates is not allowed" runtime warning
        // Wrapping in a `Task` defers mutations to the next runloop tick; the task inherits the enclosing class's `@MainActor` isolation, so we land back on the main actor before touching `@Published` state
        Task { [weak self] in
            guard let self else { return }
            // Picking a real thread cancels any in-progress new-conversation compose so the sidebar's transient "New Message" row drops away and the detail pane swaps to the thread view
            if id != nil && self.composingNew {
                self.composingNew = false
                self.draftRecipients = []
            }
            self.selectedThreadId = id
            // Lazily fetch the first page of older messages for this thread if all we have is the summary message from `request_conversations`
            // If the user previously opened it (more messages already loaded), the in-flight / reached-start guards in `SMSService.requestMore` make this a no-op
            if let id, let thread = self.conversations[id], thread.messages.count <= 1 {
                self.smsService.requestMore(threadId: id, device: self.device)
            }
        }
    }
    
    /// Clears any existing thread selection so the detail pane swaps to the inline composer and the sidebar adds the transient row.
    func startNewConversation() {
        selectedThreadId = nil
        draftRecipients = []
        composingNew = true
    }
    
    /// Called by the hover-X on the sidebar row or implicitly when the user picks a real thread.
    func cancelNewConversation() {
        composingNew = false
        draftRecipients = []
    }
    
    /// Tapping (or right-clicking → "Send Message") a phone number inside a bubble.
    /// Looks for an existing 1-on-1 thread matching the normalized number; jumps to it if found, otherwise flips into compose mode pre-populated with the number.
    /// Group threads are intentionally NOT matched here: a 1-on-1 tap shouldn't drop the user into a group conversation that happens to include the number.
    func openOrStartThread(forPhoneNumber rawNumber: String) {
        let trimmed = rawNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalized = VCardParser.normalize(phoneNumber: trimmed)
        guard !normalized.isEmpty else { return }
        
        if let existingId = matchingThreadId(for: [normalized]) {
            if composingNew {
                composingNew = false
                draftRecipients = []
            }
            selectedThreadId = existingId
            return
        }
        
        selectedThreadId = nil
        draftRecipients = [trimmed]
        composingNew = true
    }
    
    /// Triggered by the bottom sentinel's `.onAppear` for silent infinite scroll.
    func loadMoreConversations() {
        smsService.loadMoreConversations(for: device)
    }
    
    func loadMoreInThread(_ threadId: Int64) {
        smsService.requestMore(threadId: threadId, device: device)
    }
    
    func isLoadingThread(_ threadId: Int64) -> Bool {
        threadPaginationSnapshots[threadId]?.isLoading ?? false
    }
    
    func hasReachedStartOfThread(_ threadId: Int64) -> Bool {
        threadPaginationSnapshots[threadId]?.hasReachedStart ?? false
    }
    
    // MARK: Send
    
    /// Pulls the thread's participant addresses (so group MMS threads stay grouped) and forwards to `SMSService`.
    func sendReply(in threadId: Int64, body: String, subId: Int64? = nil) {
        guard let thread = conversations[threadId] else { return }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Dedup recipients while preserving order; group MMS sometimes ships the same address twice in the addresses array (each participant slot)
        var seen = Set<String>()
        let recipients = thread.addresses.filter { seen.insert($0).inserted }
        guard !recipients.isEmpty else { return }
        smsService.sendMessage(addresses: recipients, body: trimmed, device: device, subId: subId)
    }
    
    /// The phone allocates or finds a thread for these addresses.
    /// The new message appears in the conversation list on the next `sms.messages` push.
    ///
    /// If a thread already exists for this address set, jumps to it immediately.
    /// Otherwise records the pending address set so the next `conversations` update that introduces a matching thread auto-selects it (with a 30s timeout fallback).
    func sendNew(to recipients: [String], body: String, subId: Int64? = nil) {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else { return }
        var seen = Set<String>()
        let dedupedRecipients = recipients
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !dedupedRecipients.isEmpty else { return }
        smsService.sendMessage(addresses: dedupedRecipients, body: trimmedBody, device: device, subId: subId)
        
        let normalized = Set(dedupedRecipients.map { VCardParser.normalize(phoneNumber: $0) })
        
        // Match against existing threads first: common when re-messaging a contact who already has a thread
        // Jump straight there
        if let existingId = matchingThreadId(for: normalized) {
            composingNew = false
            draftRecipients = []
            selectedThreadId = existingId
            return
        }
        
        // Truly new thread: record the pending address set and exit compose mode
        // When the phone echoes the `sms.messages` packet for the new thread, the `conversations` sink calls `attemptPendingNewConversationSelection()` and jumps the user into it
        pendingNewConversationAddresses = normalized
        composingNew = false
        draftRecipients = []
        selectedThreadId = nil
        
        pendingNewConversationTimeoutTask?.cancel()
        pendingNewConversationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            await MainActor.run {
                guard let self else { return }
                self.pendingNewConversationAddresses = nil
                self.pendingNewConversationTimeoutTask = nil
            }
        }
    }
    
    /// Called from the `conversations` sink whenever the model receives a fresh snapshot.
    /// If we just sent a brand-new conversation and a matching thread has now appeared, select it and clear the pending state.
    private func attemptPendingNewConversationSelection() {
        guard let pending = pendingNewConversationAddresses else { return }
        guard let matched = matchingThreadId(for: pending) else { return }
        selectedThreadId = matched
        pendingNewConversationAddresses = nil
        pendingNewConversationTimeoutTask?.cancel()
        pendingNewConversationTimeoutTask = nil
    }
    
    /// Find a thread whose normalized-address set exactly matches `addresses`.
    /// Used both for "already exists" and for matching the echoed thread after send.
    private func matchingThreadId(for addresses: Set<String>) -> Int64? {
        for (id, thread) in conversations {
            let normalized = Set(thread.addresses.map { VCardParser.normalize(phoneNumber: $0) })
            if normalized == addresses { return id }
        }
        return nil
    }
    
    // MARK: Contact search (for the new-conversation recipient picker)
    
    /// One result row in the recipient-picker autocomplete list.
    struct ContactSearchResult: Identifiable, Hashable {
        public enum Source: Hashable { case phone, mac }
        let displayName: String
        let phoneLabel: String?  // "mobile", "work", "home", etc., when known
        let phoneNumber: String  // raw value to send to
        let source: Source
        var id: String { "\(source)|\(displayName)|\(phoneNumber)" }
    }
    
    /// Substring-match `query` against all phone-side vCards and any matching Mac contacts (via `ContactsService.lookupContact`).
    /// Capped at 30 results so the autocomplete UI stays responsive.
    func searchContacts(_ query: String) -> [ContactSearchResult] {
        _ = contactsVersion
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        var results: [ContactSearchResult] = []
        
        for vcard in contactsService.allPhoneContacts(deviceId: device.id) {
            let name = vcard.displayName ?? ""
            let nameMatches = name.lowercased().contains(trimmed)
            for phone in vcard.phoneNumbers {
                let phoneMatches = phone.raw.lowercased().contains(trimmed) || phone.normalized.contains(trimmed)
                if nameMatches || phoneMatches {
                    results.append(.init(
                        displayName: name.isEmpty ? phone.raw : name,
                        phoneLabel: phone.types.first,
                        phoneNumber: phone.raw,
                        source: .phone
                    ))
                }
            }
        }
        
        // For each phone vCard already returned, suppress the same number from Mac to avoid duplicate rows
        let phoneNumbersFromPhoneSide = Set(results.map { VCardParser.normalize(phoneNumber: $0.phoneNumber) })
        
        // Mac contacts: ask the service for all Mac matches reachable via its cache
        // Walk the published cache rather than iterating `CNContactStore` here (it's already on the main thread and that would block)
        for (normalized, resolved) in contactsService.macContactsSnapshot() {
            if phoneNumbersFromPhoneSide.contains(normalized) { continue }
            if resolved.displayName.lowercased().contains(trimmed)
                || normalized.contains(trimmed) {
                results.append(.init(
                    displayName: resolved.displayName,
                    phoneLabel: nil,
                    phoneNumber: normalized,
                    source: .mac
                ))
            }
        }
        
        return Array(results.prefix(30))
    }
    
    // MARK: Derived state
    
    /// Conversations sorted newest-first, optionally filtered by `searchText`.
    var visibleConversations: [SMSService.ConversationThread] {
        let sorted = conversations.values.sorted { $0.latestDate > $1.latestDate }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return sorted }
        return sorted.filter { thread in
            if let body = thread.latestMessage?.body, body.lowercased().contains(query) {
                return true
            }
            for addr in thread.addresses {
                if addr.lowercased().contains(query) { return true }
                if displayName(for: addr).lowercased().contains(query) { return true }
            }
            return false
        }
    }
    
    var isLoadingMoreConversations: Bool { listPaginationSnapshot.isLoading }
    var hasReachedEndOfConversations: Bool { listPaginationSnapshot.hasReachedEnd }
    
    /// Display title for the currently selected conversation, used as the window title.
    /// Nil when no thread is selected; caller substitutes a generic fallback.
    var selectedThreadTitle: String? {
        guard let id = selectedThreadId,
              let thread = conversations[id] else { return nil }
        return threadTitle(for: thread)
    }
    
    // MARK: Contact resolution helpers
    
    /// Phone vCards win; falls back to macOS `CNContactStore`; then a friendly form for RCS Business Messaging agent addresses (Google's RBM directory is not accessible from third-party apps, so we extract a readable prefix from the address itself); finally the raw address.
    /// Re-evaluated whenever `contactsVersion` bumps.
    func displayName(for phoneNumber: String) -> String {
        _ = contactsVersion
        if let c = contactsService.lookupContact(phoneNumber: phoneNumber, deviceId: device.id) {
            return c.displayName
        }
        if let rcs = Self.prettifyRcsAgent(phoneNumber) {
            return rcs
        }
        return phoneNumber
    }
    
    /// RCS Business Messaging agent addresses look like `<friendly>_<...>_<unique_id>_agent@rbm.goog` (Google RBM).
    /// Returns a readable prefix if the address matches the shape, otherwise nil.
    ///
    /// Examples:
    /// - `code_0fidwtdi_agent@rbm.goog` → "Code"
    /// - `rush_app_2zmhifdq_agent@rbm.goog` → "Rush App"
    /// - `instamart_rftrgnt6_agent@rbm.goog` → "Instamart"
    /// - `kotak811_maymvimi_agent@rbm.goog` → "Kotak811"
    private static func prettifyRcsAgent(_ address: String) -> String? {
        let agentSuffix = "_agent@rbm.goog"
        guard address.hasSuffix(agentSuffix) else { return nil }
        var s = String(address.dropLast(agentSuffix.count))
        // Strip the last underscore-separated token if it looks like a random unique ID (6+ chars, all letters/digits)
        // Keeps multi-word agent slugs like "rush_app"
        if let lastUnderscore = s.lastIndex(of: "_") {
            let lastToken = s[s.index(after: lastUnderscore)...]
            if lastToken.count >= 6 && lastToken.allSatisfy({ $0.isLetter || $0.isNumber }) {
                s = String(s[..<lastUnderscore])
            }
        }
        let cleaned = s.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned.capitalized
    }
    
    func photo(for phoneNumber: String) -> NSImage? {
        _ = contactsVersion
        return contactsService.lookupContact(phoneNumber: phoneNumber, deviceId: device.id)?.photo
    }
    
    /// One-line row title. 1-on-1 → contact name; group → "Name & N others".
    func threadTitle(for thread: SMSService.ConversationThread) -> String {
        let addrs = thread.addresses
        guard let first = addrs.first else { return "Unknown" }
        let primary = displayName(for: first)
        let unique = Set(addrs)
        if unique.count <= 1 { return primary }
        return "\(primary) & \(unique.count - 1) other\(unique.count == 2 ? "" : "s")"
    }
    
    func avatarImage(for thread: SMSService.ConversationThread) -> NSImage? {
        guard let first = thread.addresses.first else { return nil }
        return photo(for: first)
    }
}
