//
//  SMSService.swift
//  Soduto
//
//  Created by Sannidhya Roy on 03/05/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import AppKit
import UniformTypeIdentifiers
import os

/// Service implementing the KDE Connect SMS protocol v2: full conversation browsing,
/// lazy message-history pagination, contact-aware notifications, and (later) MMS.
///
/// Bootstrap is **lazy**, the conversation list is not fetched on every device connect,
/// only when something asks for it (the SMS window opens, the user clicks a reply action
/// that needs context, etc.). Heavy SMS users have tens of thousands of unique threads;
/// flooding the channel on every reconnect would block ping/clipboard/battery packets.
///
/// The conversation list itself paginates using a Soduto protocol extension on
/// `kdeconnect.sms.request_conversations`: optional `numberToRequest`
/// + `rangeStartTimestamp` fields, honoured by the Soduto Android client and
/// ignored by stock KDE Connect Android (falls back to the original unbounded behaviour).
public class SMSService: NSObject, IncomingService, ObservableObject, DownloadTaskDelegate {
    
    // MARK: Init
    
    public override init() {
        super.init()
        // Nuke any leftover MMS attachment files from previous app sessions.
        // The conversation list itself is in-memory-only (re-fetched from the phone on bootstrap)
        // So, previously-downloaded attachments are orphaned anyway
        Self.purgeAttachmentCacheOnLaunch()
    }
    
    private static func purgeAttachmentCacheOnLaunch() {
        guard let cachesRoot = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return }
        let bundleId = Bundle.main.bundleIdentifier ?? "com.soduto.Soduto"
        let dir = cachesRoot
            .appendingPathComponent(bundleId, isDirectory: true)
            .appendingPathComponent("sms-attachments", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        do {
            try FileManager.default.removeItem(at: dir)
            Logger.services.debug("SMSService: purged stale attachment cache at \(dir.path, privacy: .public)")
        } catch {
            Logger.services.notice("SMSService: failed to purge attachment cache: \(error, privacy: .public)")
        }
    }
    
    
    // MARK: Public data model
    
    public enum MessageType: Int, Equatable {
        case unknown = 0
        case inbox = 1     // received
        case sent = 2
        case draft = 3
        case outbox = 4
        case failed = 5
        case queued = 6
        
        public var isFromMe: Bool {
            switch self {
            case .sent, .draft, .outbox, .failed, .queued: return true
            case .inbox, .unknown: return false
            }
        }
    }
    
    public struct EventFlags: OptionSet, Equatable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let text = EventFlags(rawValue: 0x1)
        public static let multiTarget = EventFlags(rawValue: 0x2)
    }
    
    public struct MessageAttachment: Equatable, Identifiable {
        public let partId: Int64
        public let mimeType: String
        /// Base64-encoded thumbnail (Decode lazily; can be large).
        public let encodedThumbnail: String?
        public let uniqueIdentifier: String
        
        public var id: String { "\(partId)|\(uniqueIdentifier)" }
    }
    
    public struct Message: Equatable, Identifiable {
        public let id: Int64           // _id
        public let threadId: Int64
        public let addresses: [String] // sender first for inbox, recipients for sent
        public let body: String
        public let date: Date
        public let type: MessageType
        public let isRead: Bool
        public let event: EventFlags
        public let subId: Int64?
        public let attachments: [MessageAttachment]
        
        public var isMultiTarget: Bool { event.contains(.multiTarget) }
        public var hasAttachments: Bool { !attachments.isEmpty }
    }
    
    public struct ConversationThread: Equatable, Identifiable {
        public let id: Int64
        /// Messages sorted newest-first.
        /// The first entry is the latest message (used for the conversation list preview).
        /// Older messages are lazily paged into this array via `requestMore(threadId:device:pageSize:)`.
        /// Until then it contains just the summary message from `request_conversations`.
        public var messages: [Message]
        public var unreadCount: Int
        
        /// Addresses derived from the most-recent message.
        /// The participants we treat as "the other side" of this conversation for display purposes.
        public var addresses: [String] { messages.first?.addresses ?? [] }
        
        /// The latest message, if any (always present after a successful upsert).
        public var latestMessage: Message? { messages.first }
        
        public var latestDate: Date { messages.first?.date ?? .distantPast }
    }
    
    // MARK: Service
    
    public static let serviceId: Service.Id = "com.soduto.services.sms"
    
    /// Whether a device speaks SMS Protocol v2.
    /// The UI uses this to decide whether to surface a "Messages" action and whether to open the new SMS window or fall back to the legacy `SendMessageWindowController`.
    public static func deviceSupportsV2SMS(_ device: Device) -> Bool {
        return device.outgoingCapabilities.contains(DataPacket.smsMessagesPacketType)
    }
    
    public var incomingCapabilities: Set<Service.Capability> {
        incomingEnabled ? [
            DataPacket.smsMessagesPacketType,
            DataPacket.smsAttachmentFilePacketType
        ] : []
    }
    
    public var outgoingCapabilities: Set<Service.Capability> {
        incomingEnabled ? [
            DataPacket.smsRequestPacketTypeV2,
            DataPacket.smsRequestConversationsPacketType,
            DataPacket.smsRequestConversationPacketType,
            DataPacket.smsRequestAttachmentPacketType
        ] : []
    }
    
    // MARK: IncomingService
    
    var userDefaults: UserDefaults = .standard
    let incomingPreferenceKey = AppDefaultsStore.Preferences.Services.SMS.incomingKey
    
    // MARK: Published State
    
    /// Per-device conversation cache keyed by threadId.
    /// `threadId` is per-device (Android-assigned), always key by `(deviceId, threadId)`.
    @Published public private(set) var conversations: [Device.Id: [Int64: ConversationThread]] = [:]
    
    /// Total unread messages per device (updated as part of every flush; drives badges).
    @Published public private(set) var totalUnreadCount: [Device.Id: Int] = [:]
    
    /// Distinct `sub_id` values seen per device.
    /// The compose UI shows a SIM picker only when this set has ≥2 entries (dual-SIM phones).
    @Published public private(set) var seenSubIds: [Device.Id: Set<Int64>] = [:]
    
    /// Per-attachment download state for the in-bubble thumbnail UI
    /// Drives the blur overlay + download button / spinner / final crisp inline image.
    /// Keyed by `unique_identifier` (globally unique per phone for MMS parts).
    /// The `.downloaded` case carries the local cache URL so the bubble can render the full-resolution file in place of the small base64 thumbnail.
    public enum AttachmentDownloadState: Equatable {
        case downloading
        case downloaded(URL)
        case failed
    }
    @Published public private(set) var attachmentStates: [String: AttachmentDownloadState] = [:]
    
    /// Public-facing snapshot of conversation-list pagination state, observed by the UI to drive the load-more sentinel (idle → show "load more"; in-flight → show spinner; reached-end → hide sentinel).
    public struct ListPaginationSnapshot: Equatable {
        public let isLoading: Bool
        public let hasReachedEnd: Bool
    }
    @Published public private(set) var listPaginationSnapshots: [Device.Id: ListPaginationSnapshot] = [:]
    
    /// Per-thread pagination snapshot, keyed by `(deviceId, threadId)`.
    /// Drives the scroll-up sentinel in the message thread view.
    public struct ThreadPaginationSnapshot: Equatable {
        public let isLoading: Bool
        public let hasReachedStart: Bool
    }
    @Published public private(set) var threadPaginationSnapshots: [Device.Id: [Int64: ThreadPaginationSnapshot]] = [:]
    
    // MARK: Internal state
    
    private var devices: [Device.Id: Device] = [:]
    
    /// One SMS window per device, lazy-instantiated.
    /// Released via `onClose` when the user closes the window so the controller can fully deallocate.
    private var windowControllers: [Device.Id: SMSWindowController] = [:]
    
    /// In-flight MMS attachment downloads keyed by the underlying `DownloadTask` id, so the `DownloadTaskDelegate` callbacks can correlate progress / completion back to the originating request (filename, .part location, which `attachmentStates` entry to update).
    private struct AttachmentDownloadInfo {
        let task: DownloadTask
        let filename: String
        let partUrl: URL
        let deviceId: Device.Id
        /// `unique_identifier` from the originating `request_attachment`.
        /// Set when the FIFO queue had a matching entry, used to update `attachmentStates`.
        /// `nil` when the response didn't correlate to a known request (e.g. an unsolicited push, which shouldn't happen but we handle defensively).
        let attachmentKey: String?
    }
    private var pendingAttachmentDownloads: [Int64: AttachmentDownloadInfo] = [:]
    
    /// FIFO queue of `(uniqueIdentifier, mimeType)` we've sent `request_attachment` for.
    /// Android's `attachment_file` response doesn't echo our request id back, so we rely on the phone answering in the order it received the requests.
    /// `mimeType` is kept around so `handleAttachmentFile` can ensure the cached filename ends with the right extension (avoids `CGImageSource`'s `public.data` hint warning when `NSImage` can't infer format from path).
    private var pendingAttachmentKeys: [(uniqueId: String, mimeType: String)] = []
    
    /// Per-thread message-id dedup set: `[deviceId: [threadId: Set<messageId>]]`
    private var knownMessageIds: [Device.Id: [Int64: Set<Int64>]] = [:]
    
    // MARK: Pagination state (conversation list)
    
    private struct ListPaginationState {
        var inFlight: Bool = false
        var hasReachedEnd: Bool = false
        var lastResponseMessageCount: Int = 0
        var lastRequestedPageSize: Int = 0
        var settleWorkItem: DispatchWorkItem?
    }
    private var listPagination: [Device.Id: ListPaginationState] = [:] {
        didSet { publishListPaginationSnapshots() }
    }
    private static let listSettleInterval: TimeInterval = 1.5
    
    private func publishListPaginationSnapshots() {
        var snapshots: [Device.Id: ListPaginationSnapshot] = [:]
        for (id, state) in listPagination {
            snapshots[id] = ListPaginationSnapshot(
                isLoading: state.inFlight,
                hasReachedEnd: state.hasReachedEnd
            )
        }
        listPaginationSnapshots = snapshots
    }
    
    // MARK: Pagination state (per-thread)
    
    private struct ThreadPaginationState {
        var inFlight: Bool = false
        var hasReachedStart: Bool = false
        var lastResponseMessageCount: Int = 0
        var lastRequestedPageSize: Int = 0
        var settleWorkItem: DispatchWorkItem?
    }
    private var threadPagination: [Device.Id: [Int64: ThreadPaginationState]] = [:] {
        didSet { publishThreadPaginationSnapshots() }
    }
    private static let threadSettleInterval: TimeInterval = 1.0
    
    private func publishThreadPaginationSnapshots() {
        var snapshots: [Device.Id: [Int64: ThreadPaginationSnapshot]] = [:]
        for (deviceId, threadMap) in threadPagination {
            var inner: [Int64: ThreadPaginationSnapshot] = [:]
            for (threadId, state) in threadMap {
                inner[threadId] = ThreadPaginationSnapshot(
                    isLoading: state.inFlight,
                    hasReachedStart: state.hasReachedStart
                )
            }
            snapshots[deviceId] = inner
        }
        threadPaginationSnapshots = snapshots
    }
    
    // MARK: Coalescing buffer
    
    private let bufferLock = NSLock()
    private var pendingMessages: [Device.Id: [Message]] = [:]
    private var flushScheduled = false
    private static let flushInterval: TimeInterval = 0.1
    
    // MARK: Memory caps
    
    private static let maxMessagesPerLoadedThread = 500
    
    // MARK: Service Protocol
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        switch dataPacket.type {
        case DataPacket.smsMessagesPacketType:
            guard incomingEnabled else { return true }
            handleMessagesPacket(dataPacket, from: device)
            return true
        case DataPacket.smsAttachmentFilePacketType:
            guard incomingEnabled else { return true }
            handleAttachmentFile(dataPacket, from: device)
            return true
        default:
            return false
        }
    }
    
    public func setup(for device: Device) {
        guard devices[device.id] == nil else { return }
        // Only set up for devices that announce SMS Protocol v2 support
        // Older clients keep using `TelephonyService`'s legacy notification path
        guard device.outgoingCapabilities.contains(DataPacket.smsMessagesPacketType) else {
            Logger.services.debug("SMSService skipping device \(device.id, privacy: .public): no v2 SMS support")
            return
        }
        devices[device.id] = device
        // Deliberately NOT auto-bootstrapping.
        // The conversation list pull is expensive for heavy-SMS users
        // Defer until something asks (window open, notification reply, etc.)
        Logger.services.debug("SMSService ready for \(device.id, privacy: .public) — bootstrap deferred")
    }
    
    public func cleanup(for device: Device) {
        devices.removeValue(forKey: device.id)
        // Cached conversations remain in memory for fast reopen if the device reconnects
    }
    
    enum ActionId: ServiceAction.Id {
        case openMessages
    }
    
    public func actions(for device: Device) -> [ServiceAction] {
        // Vend "Messages" only for paired phones that announce SMS v2 support
        // Older clients keep showing `TelephonyService`'s legacy "Send SMS" one-shot compose dialog, that's gated on the inverse condition in `TelephonyService.actions`
        guard Self.deviceSupportsV2SMS(device) else { return [] }
        guard device.pairingStatus == .Paired else { return [] }
        return [
            ServiceAction(
                id: ActionId.openMessages.rawValue,
                title: "Messages",
                description: "Browse SMS conversations and send messages",
                service: self,
                device: device
            )
        ]
    }
    
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device, userInfo: [String: Any]?) {
        guard let actionId = ActionId(rawValue: id) else { return }
        guard device.pairingStatus == .Paired else { return }
        switch actionId {
        case .openMessages:
            showWindow(for: device)
        }
    }
    
    // MARK: Public API
    
    /// Initial conversation-list fetch. Pages `numberToRequest` newest threads from the phone.
    /// Safe to call multiple times, duplicate calls are coalesced into the in-flight request.
    public func bootstrapConversations(for device: Device, pageSize: Int = 20) {
        ensureDevice(device)
        var state = listPagination[device.id] ?? ListPaginationState()
        guard !state.inFlight, !state.hasReachedEnd else { return }
        guard (conversations[device.id]?.isEmpty ?? true) else {
            // Already have data from a previous run, let `loadMore` drive further paging
            return
        }
        state.inFlight = true
        state.lastResponseMessageCount = 0
        state.lastRequestedPageSize = pageSize
        listPagination[device.id] = state
        Logger.services.info("SMSService bootstrapping conversation list for \(device.id, privacy: .public) (pageSize=\(pageSize, privacy: .public))")
        request(DataPacket.smsRequestConversationsPacket(numberToRequest: pageSize), from: device)
    }
    
    /// Fetch the next page of older conversations.
    /// `rangeStartTimestamp` is derived from the oldest thread already loaded.
    public func loadMoreConversations(for device: Device, pageSize: Int = 20) {
        ensureDevice(device)
        var state = listPagination[device.id] ?? ListPaginationState()
        guard !state.inFlight, !state.hasReachedEnd else { return }
        guard let oldestDate = oldestConversationDate(deviceId: device.id) else {
            bootstrapConversations(for: device, pageSize: pageSize)
            return
        }
        state.inFlight = true
        state.lastResponseMessageCount = 0
        state.lastRequestedPageSize = pageSize
        listPagination[device.id] = state
        // -1 ms to guarantee strictly-older semantics regardless of whether the phone interprets `rangeStartTimestamp` as `<` or `<=`
        // Without this, a `<=` phone re-sends the boundary thread; the duplicate inflates `lastResponseMessageCount` past `pageSize` and trips the flood-detection branch in `scheduleListSettle`, wrongly setting `hasReachedEnd = true` after the second batch
        // Matches the thread pagination convention in `requestMore(threadId:device:pageSize:)`
        let oldestMs = Int64(oldestDate.timeIntervalSince1970 * 1000) - 1
        Logger.services.debug("SMSService loadMore for \(device.id, privacy: .public) rangeStartTs=\(oldestMs, privacy: .public)")
        request(DataPacket.smsRequestConversationsPacket(
            numberToRequest: pageSize,
            rangeStartTimestamp: oldestMs
        ), from: device)
    }
    
    /// Fetch a page of older messages within an open thread.
    /// Covers both the initial thread open (where only the summary message is loaded) and the scroll-up sentinel's "load older" trigger.
    public func requestMore(threadId: Int64, device: Device, pageSize: Int = 25) {
        ensureDevice(device)
        var state = (threadPagination[device.id]?[threadId]) ?? ThreadPaginationState()
        guard !state.inFlight, !state.hasReachedStart else { return }
        state.inFlight = true
        state.lastResponseMessageCount = 0
        state.lastRequestedPageSize = pageSize
        threadPagination[device.id, default: [:]][threadId] = state
        
        let thread = conversations[device.id]?[threadId]
        // `messages.last` is the OLDEST loaded (array is sorted newest-first)
        // Anchor the next page at `oldest.date - 1` so the response contains strictly older messages
        let rangeStartTs: Int64? = thread?.messages.last.map {
            Int64($0.date.timeIntervalSince1970 * 1000) - 1
        }
        Logger.services.debug("SMSService requesting more for thread \(threadId, privacy: .public) rangeStart=\(rangeStartTs ?? -1, privacy: .public)")
        request(DataPacket.smsRequestConversationPacket(
            threadID: threadId,
            rangeStartTimestamp: rangeStartTs,
            numberToRequest: pageSize
        ), from: device)
    }
    
    /// Send an SMS to one or more addresses (group MMS thread if more than one).
    /// `subId` only included when the device has revealed itself to be dual-SIM.
    public func sendMessage(addresses: [String], body: String, device: Device, subId: Int64? = nil) {
        guard incomingEnabled else { return }
        guard !addresses.isEmpty, !body.isEmpty else { return }
        let packet = DataPacket.smsRequestPacketV2(addresses: addresses, messageBody: body, subID: subId)
        device.send(packet)
        Logger.services.info("SMSService sent \(body.count, privacy: .public)-char message to \(addresses.count, privacy: .public) recipient(s) on \(device.id, privacy: .public)")
    }
    
    /// Convenience for routing a notification "Reply" action through SMS Protocol v2.
    /// Currently unused: SMS notification replies go through `NotificationsService`'s generic repliable-notification mechanism (`kdeconnect.notification.reply` / `requestReplyId`) instead, which sends directly to the phone without needing `SMSService`.
    /// Kept in case a dedicated SMS-specific reply path is wanted later.
    public func replyTo(phoneNumber: String, text: String, device: Device) {
        sendMessage(addresses: [phoneNumber], body: text, device: device)
    }
    
    /// Show (or focus if already open) the SMS window for a given device.
    ///
    /// Per-device window controllers live on this service (same pattern as `TelephonyService.sendMessageController`).
    /// Released via `onClose` when the user closes the window.
    /// `ContactsService` (needed by the recipient picker) is resolved through `AppDelegate.shared()` so callers don't have to thread it.
    public func showWindow(for device: Device) {
        guard let contactsService = AppDelegate.shared()
            .serviceManager.service(ofType: ContactsService.self) else {
            Logger.services.notice("SMSService.showWindow: ContactsService unavailable")
            NSSound.beep()
            return
        }
        if let existing = windowControllers[device.id] {
            existing.show()
            return
        }
        let controller = SMSWindowController(device: device, smsService: self, contactsService: contactsService)
        controller.onClose = { [weak self] in
            self?.windowControllers.removeValue(forKey: device.id)
        }
        windowControllers[device.id] = controller
        controller.show()
    }
    
    /// Request a full attachment file.
    /// The phone responds with `kdeconnect.sms.attachment_file` carrying a payload stream.
    /// `SMSService` saves it to the per-device cache dir and updates `attachmentStates[uniqueIdentifier]` so the bubble can flip out of the "blurred + download button" state and render the crisp full-resolution image.
    /// `mimeType` is the MIME type from the original `MessageAttachment` (used to fix up the cached filename's extension if the phone-supplied filename lacks one).
    public func requestAttachment(partId: Int64, uniqueIdentifier: String, mimeType: String, device: Device) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Optimistically mark downloading so the bubble UI flips immediately
            self.attachmentStates[uniqueIdentifier] = .downloading
            self.pendingAttachmentKeys.append((uniqueIdentifier, mimeType))
        }
        request(DataPacket.smsRequestAttachmentPacket(
            partID: partId,
            uniqueIdentifier: uniqueIdentifier
        ), from: device)
    }
    
    // MARK: Attachment Download
    
    /// Save the streamed payload from a `kdeconnect.sms.attachment_file` packet to the per-device cache directory.
    /// The downloaded file is then made available to the bubble UI via `attachmentStates[key] = .downloaded(url)`
    /// The bubble renders the full-resolution image inline (replacing the low-res base64 thumbnail).
    private func handleAttachmentFile(_ packet: DataPacket, from device: Device) {
        // Snapshot what we need from the packet
        // `handleDataPacket` runs on the connection's background queue, but `pendingAttachmentDownloads` + `pendingAttachmentKeys` are mutated on main alongside `attachmentStates`
        let downloadTask = packet.downloadTask
        let rawFilename = (packet.body["filename"] as? String) ?? "attachment"
        let payloadSize = packet.payloadSize
        let deviceId = device.id
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let downloadTask = downloadTask else {
                Logger.services.notice("SMS attachment_file from \(deviceId, privacy: .public) carries no payload")
                return
            }
            
            // Pop the FIFO entry, that's the user-clicked thumbnail this response answers.
            // Used to update `attachmentStates` so the bubble UI can flip out of the spinner state on completion.
            // Its mimeType feeds `sanitizedFilename` so the saved file gets a proper extension.
            let popped: (uniqueId: String, mimeType: String)? = self.pendingAttachmentKeys.isEmpty ? nil : self.pendingAttachmentKeys.removeFirst()
            let attachmentKey = popped?.uniqueId
            
            let safeFilename = Self.sanitizedFilename(rawFilename, mimeType: popped?.mimeType)
            Logger.services.info("SMS attachment_file from \(deviceId, privacy: .public): \(rawFilename, privacy: .public) → \(safeFilename, privacy: .public) (\(payloadSize ?? -1, privacy: .public) bytes)")
            
            guard let dir = self.attachmentCacheDirectory(for: deviceId) else {
                Logger.services.error("SMS attachment: cache dir unavailable for \(deviceId, privacy: .public)")
                if let key = attachmentKey { self.attachmentStates[key] = .failed }
                return
            }
            let destUrl = dir.appendingPathComponent(safeFilename)
            guard destUrl.resolvingSymlinksInPath().path
                .hasPrefix(dir.resolvingSymlinksInPath().path) else {
                Logger.services.error("SMS attachment: refusing path outside cache dir for \(rawFilename, privacy: .public)")
                if let key = attachmentKey { self.attachmentStates[key] = .failed }
                return
            }
            
            guard let (stream, partUrl) = Self.streamForTempDownload(finalUrl: destUrl) else {
                Logger.services.error("SMS attachment: couldn't open output stream for \(rawFilename, privacy: .public)")
                if let key = attachmentKey { self.attachmentStates[key] = .failed }
                return
            }
            
            self.pendingAttachmentDownloads[downloadTask.id] = AttachmentDownloadInfo(
                task: downloadTask,
                filename: safeFilename,
                partUrl: partUrl,
                deviceId: deviceId,
                attachmentKey: attachmentKey
            )
            downloadTask.delegate = self
            downloadTask.start(withStream: stream)
        }
    }
    
    // MARK: DownloadTaskDelegate
    
    public func downloadTask(_ task: DownloadTask, finishedWithSuccess success: Bool) {
        guard let info = pendingAttachmentDownloads.removeValue(forKey: task.id) else { return }
        if success {
            do {
                let finalUrl = try Self.renamePartFile(url: info.partUrl, to: info.filename)
                if let key = info.attachmentKey {
                    attachmentStates[key] = .downloaded(finalUrl)
                }
            } catch {
                Logger.services.error("SMS attachment: rename failed for \(info.filename, privacy: .public): \(error, privacy: .public)")
                if let key = info.attachmentKey { attachmentStates[key] = .failed }
                try? FileManager.default.removeItem(at: info.partUrl)
            }
        } else {
            if let key = info.attachmentKey { attachmentStates[key] = .failed }
            try? FileManager.default.removeItem(at: info.partUrl)
        }
    }
    
    public func downloadTask(_ task: DownloadTask, didReceiveBytes bytesReceived: Int64, totalBytes: Int64?) {
        // No-op; chat-attachment progress feedback comes from the in-bubble spinner (binary downloading/downloaded)
        // If we ever want a determinate ring instead of an indeterminate spinner, surface `bytesReceived / totalBytes` on the `.downloading` enum case.
    }
    
    // MARK: Cache + file helpers
    
    /// `~/Library/Caches/<bundle-id>/sms-attachments/<sanitized-deviceId>/`
    private func attachmentCacheDirectory(for deviceId: Device.Id) -> URL? {
        guard let cachesRoot = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let bundleId = Bundle.main.bundleIdentifier ?? "com.soduto.Soduto"
        let safeDeviceId = StableHashing.shortSha256(deviceId, length: 32)
        let url = cachesRoot
            .appendingPathComponent(bundleId, isDirectory: true)
            .appendingPathComponent("sms-attachments", isDirectory: true)
            .appendingPathComponent(safeDeviceId, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    
    /// Strip everything but the filename's basename and replace any unsafe characters.
    /// Attachment filenames arrive from the phone (sender-controlled).
    /// Sanitise so we can't be coerced into traversing out of the cache directory.
    /// If the supplied `mimeType` resolves to a known file extension AND the filename lacks one, append it.
    /// Keeps `NSImage(contentsOf:)` from falling through to the `kCGImageSourceTypeIdentifierHint:public.data` warning path.
    private static func sanitizedFilename(_ raw: String, mimeType: String? = nil) -> String {
        let base = (raw as NSString).lastPathComponent
        let stripped = base.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = stripped.isEmpty ? "attachment" : stripped
        
        guard (safe as NSString).pathExtension.isEmpty,
              let mimeType, !mimeType.isEmpty,
              let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension else {
            return safe
        }
        return "\(safe).\(ext)"
    }
    
    /// Open a `.part` temp file alongside the final destination.
    /// Same idiom as `ShareService.streamForTempDownload(finalUrl:)`.
    /// Auto-suffixes the name to avoid clobbering an in-flight download from a different source.
    private static func streamForTempDownload(finalUrl: URL) -> (OutputStream, URL)? {
        var partUrl = finalUrl.appendingPathExtension("part")
        for _ in 1...10000 {
            if !FileManager.default.fileExists(atPath: partUrl.path) {
                if let stream = OutputStream(url: partUrl, append: false) {
                    stream.open()
                    if stream.hasSpaceAvailable {
                        return (stream, partUrl)
                    }
                    stream.close()
                }
            }
            partUrl = partUrl.alternativeForDuplicate()
        }
        return nil
    }
    
    /// Rename `.part` → final filename, dodging collisions with already-saved files.
    private static func renamePartFile(url partUrl: URL, to fileName: String) throws -> URL {
        var finalUrl = partUrl.deletingLastPathComponent().appendingPathComponent(fileName)
        for _ in 1...10000 {
            if !FileManager.default.fileExists(atPath: finalUrl.path) {
                try FileManager.default.moveItem(at: partUrl, to: finalUrl)
                return finalUrl
            }
            finalUrl = finalUrl.alternativeForDuplicate()
        }
        throw CocoaError(.fileWriteFileExists)
    }
    
    // MARK: Incoming packet handling
    
    private func handleMessagesPacket(_ packet: DataPacket, from device: Device) {
        guard let messagesArray = packet.body["messages"] as? [[String: Any]] else {
            Logger.services.notice("SMS messages packet missing 'messages' from \(device.id, privacy: .public)")
            return
        }
        
        var parsed: [Message] = []
        parsed.reserveCapacity(messagesArray.count)
        for raw in messagesArray {
            if let m = Self.parseMessage(raw) {
                parsed.append(m)
            }
        }
        guard !parsed.isEmpty else {
            // Empty batch is meaningful
            // It can signal "no more conversations" / "no older messages in thread" when it arrives as a response to a paged request
            handleEmptyResponse(from: device)
            return
        }
        
        // Dispatch the settle marker by packet shape + in-flight pagination state
        //
        // Android sends multi-message packets for `request_conversation` responses (a whole thread page in one packet) but for `request_conversations` it iterates threads and sends ONE packet PER thread (1 message each)
        // A live new SMS arrival is also a 1-message push with no pending request
        // To disambiguate the 1-message case, we also check the in-flight pagination flags:
        //
        //   - parsed.count > 1               → thread response (multi-message is exclusive)
        //   - parsed.count == 1, thread in-flight for this thread → thread response (last page can also be 1 message for tiny threads)
        //   - parsed.count == 1, list in-flight → list response (settle list)
        //   - parsed.count == 1, nothing in-flight → live new SMS (no settle)
        let firstThread = parsed[0].threadId
        let isMultiMessage = parsed.count > 1
        let allSameThread = parsed.allSatisfy { $0.threadId == firstThread }
        let isFromInFlightThread = allSameThread && (threadPagination[device.id]?[firstThread]?.inFlight ?? false)
        let isListResponse = !isMultiMessage && !isFromInFlightThread && (listPagination[device.id]?.inFlight ?? false)
        
        bufferLock.lock()
        pendingMessages[device.id, default: []].append(contentsOf: parsed)
        let shouldSchedule = !flushScheduled
        if shouldSchedule { flushScheduled = true }
        bufferLock.unlock()
        
        if shouldSchedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in
                self?.flushPending()
            }
        }
        
        // Authoritative end signal from Soduto Android Client
        // When `hasMore` is explicitly false we close out the in-flight pagination right away instead of waiting for the settle timer or relying on the count heuristic
        // When the field is absent (stock KDE Connect Android) `hasMore` is nil and we fall back to the timer
        let hasMore: Bool? = (packet.body["hasMore"] as? NSNumber)?.boolValue ?? (packet.body["hasMore"] as? Bool)
        
        if isMultiMessage || isFromInFlightThread {
            scheduleThreadSettle(deviceId: device.id, threadId: firstThread, batchCount: parsed.count)
            if hasMore == false {
                finalizeThreadEnd(deviceId: device.id, threadId: firstThread)
            }
        } else if isListResponse {
            scheduleListSettle(deviceId: device.id, batchCount: parsed.count)
            if hasMore == false {
                finalizeListEnd(deviceId: device.id)
            }
        }
    }
    
    /// Immediately flip `hasReachedEnd = true` and clear in-flight + the settle timer when the phone tells us a list page is the last one.
    private func finalizeListEnd(deviceId: Device.Id) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, var s = self.listPagination[deviceId] else { return }
            s.settleWorkItem?.cancel()
            s.settleWorkItem = nil
            s.inFlight = false
            s.hasReachedEnd = true
            self.listPagination[deviceId] = s
            Logger.services.debug("SMSService list end for \(deviceId, privacy: .public) (hasMore=false)")
        }
    }
    
    /// Immediately flip `hasReachedStart = true` and clear in-flight + the settle timer when the phone tells us a thread page is the last (oldest) one.
    private func finalizeThreadEnd(deviceId: Device.Id, threadId: Int64) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  var s = self.threadPagination[deviceId]?[threadId] else { return }
            s.settleWorkItem?.cancel()
            s.settleWorkItem = nil
            s.inFlight = false
            s.hasReachedStart = true
            self.threadPagination[deviceId, default: [:]][threadId] = s
            Logger.services.debug("SMSService thread \(threadId, privacy: .public) end (hasMore=false)")
        }
    }
    
    /// An empty `messages` array arriving as a response is a "no more results" signal.
    /// We can't know which request it answers without more state, so we conservatively mark BOTH the list and any in-flight thread requests as reached-end.
    /// False positives here are recoverable (the next user action just re-asks).
    private func handleEmptyResponse(from device: Device) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if var s = self.listPagination[device.id], s.inFlight {
                s.inFlight = false
                s.hasReachedEnd = true
                s.settleWorkItem?.cancel()
                s.settleWorkItem = nil
                self.listPagination[device.id] = s
                Logger.services.debug("SMSService list pagination: reached end for \(device.id, privacy: .public)")
            }
            for (threadId, var s) in self.threadPagination[device.id] ?? [:] where s.inFlight {
                s.inFlight = false
                s.hasReachedStart = true
                s.settleWorkItem?.cancel()
                s.settleWorkItem = nil
                self.threadPagination[device.id, default: [:]][threadId] = s
                Logger.services.debug("SMSService thread \(threadId, privacy: .public) reached start")
            }
        }
    }
    
    // MARK: Flush (main thread, batched)
    
    private func flushPending() {
        bufferLock.lock()
        let snapshot = pendingMessages
        pendingMessages.removeAll()
        flushScheduled = false
        bufferLock.unlock()
        
        for (deviceId, messages) in snapshot {
            applyMessages(messages, deviceId: deviceId)
        }
    }
    
    /// Insert new messages into the model.
    /// Dedup by `_id` per thread, append, sort newest-first, cap to `maxMessagesPerLoadedThread`, recompute unread count.
    private func applyMessages(_ messages: [Message], deviceId: Device.Id) {
        var deviceConvos = conversations[deviceId] ?? [:]
        var deviceKnown = knownMessageIds[deviceId] ?? [:]
        var deviceSubIds = seenSubIds[deviceId] ?? []
        var anyChange = false
        
        for message in messages {
            // Track distinct SIM ids for the compose UI's optional picker
            if let sub = message.subId, sub > 0, !deviceSubIds.contains(sub) {
                deviceSubIds.insert(sub)
            }
            
            var knownInThread = deviceKnown[message.threadId] ?? []
            if knownInThread.contains(message.id) {
                // Skip duplicates: updates aren't part of the protocol, Android only sends new/historical messages
                continue
            }
            knownInThread.insert(message.id)
            deviceKnown[message.threadId] = knownInThread
            
            var thread = deviceConvos[message.threadId] ?? ConversationThread(id: message.threadId, messages: [], unreadCount: 0)
            thread.messages.append(message)
            deviceConvos[message.threadId] = thread
            anyChange = true
        }
        
        guard anyChange else { return }
        
        for (threadId, var thread) in deviceConvos {
            thread.messages.sort { $0.date > $1.date }
            if thread.messages.count > Self.maxMessagesPerLoadedThread {
                thread.messages = Array(thread.messages.prefix(Self.maxMessagesPerLoadedThread))
            }
            thread.unreadCount = thread.messages.reduce(into: 0) { acc, m in
                if !m.isRead && !m.type.isFromMe { acc += 1 }
            }
            deviceConvos[threadId] = thread
        }
        
        let totalUnread = deviceConvos.values.reduce(0) { $0 + $1.unreadCount }
        
        conversations[deviceId] = deviceConvos
        knownMessageIds[deviceId] = deviceKnown
        seenSubIds[deviceId] = deviceSubIds
        totalUnreadCount[deviceId] = totalUnread
    }
    
    // MARK: Pagination settle detection
    
    /// After the last incoming message for a list-pagination batch, wait a short window for further packets.
    /// If nothing more arrives, declare the page complete and clear the in-flight flag so `loadMore()` can fire again.
    private func scheduleListSettle(deviceId: Device.Id, batchCount: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            var state = self.listPagination[deviceId] ?? ListPaginationState()
            state.lastResponseMessageCount += batchCount
            state.settleWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                var s = self.listPagination[deviceId] ?? ListPaginationState()
                s.inFlight = false
                if s.lastResponseMessageCount == 0 {
                    s.hasReachedEnd = true
                } else if s.lastRequestedPageSize > 0 && s.lastResponseMessageCount > s.lastRequestedPageSize {
                    // Phone returned more than we asked for (e.g. stock KDE Connect Android ignored our pagination params and flooded the full conversation list)
                    // We have everything; suppress further `loadMore()` to avoid re-flooding
                    s.hasReachedEnd = true
                    Logger.services.notice("SMSService list flood detected for \(deviceId, privacy: .public) (\(s.lastResponseMessageCount, privacy: .public) > \(s.lastRequestedPageSize, privacy: .public)); marking complete")
                } else if s.lastRequestedPageSize > 0 && s.lastResponseMessageCount < s.lastRequestedPageSize {
                    // Phone returned a partial page, there's nothing older left
                    s.hasReachedEnd = true
                }
                s.settleWorkItem = nil
                self.listPagination[deviceId] = s
                Logger.services.debug("SMSService list page settled for \(deviceId, privacy: .public): \(s.lastResponseMessageCount, privacy: .public) msgs, end=\(s.hasReachedEnd, privacy: .public)")
            }
            state.settleWorkItem = work
            self.listPagination[deviceId] = state
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.listSettleInterval, execute: work)
        }
    }
    
    private func scheduleThreadSettle(deviceId: Device.Id, threadId: Int64, batchCount: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            var state = (self.threadPagination[deviceId]?[threadId]) ?? ThreadPaginationState()
            state.lastResponseMessageCount += batchCount
            state.settleWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                var s = (self.threadPagination[deviceId]?[threadId]) ?? ThreadPaginationState()
                s.inFlight = false
                if s.lastResponseMessageCount == 0 {
                    s.hasReachedStart = true
                } else if s.lastRequestedPageSize > 0 && s.lastResponseMessageCount < s.lastRequestedPageSize {
                    // Phone returned a partial page, no more history to fetch for this thread
                    s.hasReachedStart = true
                }
                s.settleWorkItem = nil
                self.threadPagination[deviceId, default: [:]][threadId] = s
                Logger.services.debug("SMSService thread \(threadId, privacy: .public) settled: \(s.lastResponseMessageCount, privacy: .public) msgs, start=\(s.hasReachedStart, privacy: .public)")
            }
            state.settleWorkItem = work
            self.threadPagination[deviceId, default: [:]][threadId] = state
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.threadSettleInterval, execute: work)
        }
    }
    
    // MARK: Helpers
    
    private func ensureDevice(_ device: Device) {
        if devices[device.id] == nil {
            devices[device.id] = device
        }
    }
    
    private func oldestConversationDate(deviceId: Device.Id) -> Date? {
        return conversations[deviceId]?.values.compactMap { $0.latestMessage?.date }.min()
    }
    
    // MARK: Parsing
    
    private static func parseMessage(_ raw: [String: Any]) -> Message? {
        guard let id = (raw["_id"] as? NSNumber)?.int64Value else { return nil }
        guard let threadId = (raw["thread_id"] as? NSNumber)?.int64Value else { return nil }
        guard let dateMs = (raw["date"] as? NSNumber)?.int64Value else { return nil }
        
        let body = (raw["body"] as? String) ?? ""
        let typeRaw = (raw["type"] as? NSNumber)?.intValue ?? 0
        let type = MessageType(rawValue: typeRaw) ?? .unknown
        let readRaw = (raw["read"] as? NSNumber)?.intValue ?? 1
        let isRead = readRaw != 0
        let eventRaw = (raw["event"] as? NSNumber)?.intValue ?? Int(EventFlags.text.rawValue)
        let event = EventFlags(rawValue: eventRaw)
        let subId = (raw["sub_id"] as? NSNumber)?.int64Value
        
        var addresses: [String] = []
        if let addressArray = raw["addresses"] as? [[String: Any]] {
            for entry in addressArray {
                if let address = entry["address"] as? String, !address.isEmpty {
                    addresses.append(address)
                }
            }
        }
        
        var attachments: [MessageAttachment] = []
        if let attachmentArray = raw["attachments"] as? [[String: Any]] {
            for entry in attachmentArray {
                guard let partId = (entry["part_id"] as? NSNumber)?.int64Value,
                      let mime = entry["mime_type"] as? String,
                      let uniqueId = entry["unique_identifier"] as? String else {
                    continue
                }
                let thumb = entry["encoded_thumbnail"] as? String
                attachments.append(MessageAttachment(
                    partId: partId,
                    mimeType: mime,
                    encodedThumbnail: thumb,
                    uniqueIdentifier: uniqueId
                ))
            }
        }
        
        return Message(
            id: id,
            threadId: threadId,
            addresses: addresses,
            body: body,
            date: Date(timeIntervalSince1970: TimeInterval(dateMs) / 1000.0),
            type: type,
            isRead: isRead,
            event: event,
            subId: subId,
            attachments: attachments
        )
    }
}

// MARK: - DataPacket (SMS Protocol v2)

fileprivate extension DataPacket {
    
    // MARK: Types
    
    enum SMSError: Error {
        case wrongType
        case malformedBody
    }
    
    enum SMSProperty: String {
        case version = "version"
        case addresses = "addresses"
        case address = "address"
        case messageBody = "messageBody"
        case subID = "subID"
        case attachments = "attachments"
        case fileName = "fileName"
        case base64EncodedFile = "base64EncodedFile"
        case mimeType = "mimeType"
        case threadID = "threadID"
        case rangeStartTimestamp = "rangeStartTimestamp"
        case numberToRequest = "numberToRequest"
        case partID = "part_id"
        case uniqueIdentifier = "unique_identifier"
    }
    
    // MARK: Properties
    
    static let smsMessagesPacketType = "kdeconnect.sms.messages"
    static let smsAttachmentFilePacketType = "kdeconnect.sms.attachment_file"
    
    static let smsRequestPacketTypeV2 = "kdeconnect.sms.request"
    static let smsRequestConversationsPacketType = "kdeconnect.sms.request_conversations"
    static let smsRequestConversationPacketType = "kdeconnect.sms.request_conversation"
    static let smsRequestAttachmentPacketType = "kdeconnect.sms.request_attachment"
    
    var isSMSMessagesPacket: Bool { type == DataPacket.smsMessagesPacketType }
    var isSMSAttachmentFilePacket: Bool { type == DataPacket.smsAttachmentFilePacketType }
    
    // MARK: Public static methods
    
    /// SMS Protocol v2 send-SMS packet.
    /// `addresses` becomes a list of `{ "address": <string> }` objects so a single packet with N recipients creates a group MMS thread on the phone (matching KDE smsapp behaviour).
    /// For N separate threads, call this N times.
    static func smsRequestPacketV2(addresses: [String], messageBody: String, subID: Int64? = nil, attachments: [SMSOutgoingAttachment] = []) -> DataPacket {
        var body: [String: AnyObject] = [
            SMSProperty.version.rawValue: NSNumber(value: 2),
            SMSProperty.addresses.rawValue: addresses.map { [SMSProperty.address.rawValue: $0] } as AnyObject,
            SMSProperty.messageBody.rawValue: messageBody as AnyObject
        ]
        if let sub = subID {
            body[SMSProperty.subID.rawValue] = NSNumber(value: sub)
        }
        if !attachments.isEmpty {
            body[SMSProperty.attachments.rawValue] = attachments.map { att in
                [
                    SMSProperty.fileName.rawValue: att.fileName,
                    SMSProperty.base64EncodedFile.rawValue: att.base64EncodedFile,
                    SMSProperty.mimeType.rawValue: att.mimeType
                ]
            } as AnyObject
        }
        return DataPacket(type: smsRequestPacketTypeV2, body: body)
    }
    
    /// Request the most-recent message in each thread.
    /// Soduto extension: optional pagination via `numberToRequest` + `rangeStartTimestamp`.
    /// Stock KDE Connect Android ignores the params and returns every thread (original behaviour).
    static func smsRequestConversationsPacket(numberToRequest: Int? = nil, rangeStartTimestamp: Int64? = nil) -> DataPacket {
        var body: [String: AnyObject] = [:]
        if let n = numberToRequest {
            body[SMSProperty.numberToRequest.rawValue] = NSNumber(value: n)
        }
        if let ts = rangeStartTimestamp {
            body[SMSProperty.rangeStartTimestamp.rawValue] = NSNumber(value: ts)
        }
        return DataPacket(type: smsRequestConversationsPacketType, body: body)
    }
    
    /// Request messages from a specific thread.
    static func smsRequestConversationPacket(threadID: Int64, rangeStartTimestamp: Int64? = nil, numberToRequest: Int? = nil) -> DataPacket {
        var body: [String: AnyObject] = [
            SMSProperty.threadID.rawValue: NSNumber(value: threadID)
        ]
        if let ts = rangeStartTimestamp {
            body[SMSProperty.rangeStartTimestamp.rawValue] = NSNumber(value: ts)
        }
        if let n = numberToRequest {
            body[SMSProperty.numberToRequest.rawValue] = NSNumber(value: n)
        }
        return DataPacket(type: smsRequestConversationPacketType, body: body)
    }
    
    static func smsRequestAttachmentPacket(partID: Int64, uniqueIdentifier: String) -> DataPacket {
        return DataPacket(type: smsRequestAttachmentPacketType, body: [
            SMSProperty.partID.rawValue: NSNumber(value: partID),
            SMSProperty.uniqueIdentifier.rawValue: uniqueIdentifier as AnyObject
        ])
    }
}

/// Lightweight value type for outgoing MMS attachments.
/// Inline base64 is the protocol's chosen mechanism for send-side attachments (no payload streaming, unlike receive).
/// MMS send lives in a follow-up phase; the type is here so `smsRequestPacketV2` doesn't have to change shape later.
public struct SMSOutgoingAttachment {
    public let fileName: String
    public let base64EncodedFile: String
    public let mimeType: String
    
    public init(fileName: String, base64EncodedFile: String, mimeType: String) {
        self.fileName = fileName
        self.base64EncodedFile = base64EncodedFile
        self.mimeType = mimeType
    }
}
