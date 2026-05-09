//
//  NotificationsService.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-11-26.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation
import Cocoa
import os
import UserNotifications

/// Show notifications from other devices
///
/// This service listens to packages with type "kdeconnect.notification" that will
/// contain all the information of the other device notifications.
///
/// The other device will report us every notification that is created or dismissed,
/// so we can keep in sync a local list of notifications.
///
/// At the beginning we can request the already existing notifications by sending a
/// package with the boolean "request" set to true.
///
/// The received packages will contain the following fields:
///
/// "id" (string): A unique notification id.
/// "appName" (string): The app that generated the notification.
/// "ticker" (string): Brief summary of the notification.
/// "title" (string, optional): Notification title (e.g., sender name in messaging apps).
/// "text" (string, optional): Full notification body text.
/// "isClearable" (boolean): True if we can request to dismiss the notification.
/// "isCancel" (boolean): True if the notification was dismissed in the peer device.
/// "silent" (boolean): True if the notification is pre-existing (not fresh).
/// "actions" (string[], optional): Available action buttons.
/// "requestReplyId" (string, optional): UUID for repliable notifications (e.g., chat replies).
/// "payloadHash" (string, optional): MD5 hash of the notification icon (requires payload download).
/// "groupName" (string, optional): Group name for group conversation messages.
/// "conversation" ([{sender, content}], optional): Message history for messaging-style notifications.
///
/// Additionally the package can contain a payload with the icon of the notification in PNG format.
///
/// The content of these fields is used to display the notifications to the user.
/// Note that if we receive a second notification with the same "id", we should
/// update the existent notification instead of creating a new one.
///
/// If the user dismisses a notification from this device, we have to request the
/// other device to remove it. This is done by sending a package with the fields
/// "id" set to the id of the notification we want to dismiss and a boolean "cancel"
/// set to true. The other device will answer with a notification package with
/// "isCancel" set to true when it is dismissed.
///
/// Notification synchronization is best-effort and prioritizes local UI consistency.
/// Due to KDE Connect protocol limitations, some remote notifications may not be mirrored.
public class NotificationsService: Service, DownloadTaskDelegate, UserNotificationActionHandler {
    
    // MARK: Types
    
    public typealias NotificationId = String
    
    enum UserInfoProperty: String {
        case deviceId = "com.soduto.services.notifications.deviceId"
        case notificationId = "com.soduto.services.notifications.notificationId"
        case requestReplyId = "com.soduto.services.notifications.requestReplyId"
        case isCancelable = "com.soduto.services.notifications.isCancelable"
        case appName = "com.soduto.services.notifications.appName"
    }
    
    enum ActionId: ServiceAction.Id {
        case refresh
    }
    
    /// Actor to ensure startup cleanup runs exactly once
    private actor StartupCleanupManager {
        private var cleanupTask: Task<Void, Never>?
        
        func ensureCleanup(action: @escaping @Sendable () async -> Void) async {
            if let task = cleanupTask {
                return await task.value
            }
            
            let task = Task {
                await action()
            }
            cleanupTask = task
            return await task.value
        }
    }
    
    /// Marked @unchecked Sendable because DownloadTask and Device do not strictly conform to Sendable,
    /// but are used here in a thread-safe manner (DownloadTask is unique per request, Device is treated as reference).
    private struct DownloadInfo: @unchecked Sendable {
        let task: DownloadTask
        let fileHash: String?
        let notificationId: String
        let partFileURL: URL
        let dataPacket: DataPacket
        let device: Device
    }
    
    /// Actor to manage icon download state and cache mappings safely off the main thread.
    private actor IconStateManager {
        var notificationIconDownloadInfos: [DownloadInfo] = []
        var downloadedNotificationIconFileURLByNotificationId: [String: URL] = [:]
        var cachedDownloadedNotificationIconFileURLByHash: [String: URL] = [:]
        
        /// Represents exclusive ownership of a temporary download stream.
        /// The stream is created inside IconStateManager and immediately handed off to a single DownloadTask. It is never shared.
        /// This wrapper ensures the stream is closed if it's never handed off (e.g. error before start).
        final class TempIconDownloadStream: @unchecked Sendable {
            let stream: OutputStream
            let fileURL: URL
            private var isTransferred = false
            
            init(stream: OutputStream, fileURL: URL) {
                self.stream = stream
                self.fileURL = fileURL
            }
            
            deinit {
                if !isTransferred {
                    stream.close()
                }
            }
            
            func transfer() -> OutputStream {
                isTransferred = true
                return stream
            }
        }
        
        func addDownloadInfo(_ info: DownloadInfo) {
            notificationIconDownloadInfos.append(info)
        }
        
        func removeDownloadInfo(for task: DownloadTask) -> DownloadInfo? {
            guard let index = notificationIconDownloadInfos.firstIndex(where: { $0.task === task }) else { return nil }
            return notificationIconDownloadInfos.remove(at: index)
        }
        
        func setDownloadedIconURL(_ url: URL, for notificationId: String) {
            downloadedNotificationIconFileURLByNotificationId[notificationId] = url
        }
        
        func getDownloadedIconURL(for notificationId: String) -> URL? {
            return downloadedNotificationIconFileURLByNotificationId[notificationId]
        }
        
        func removeDownloadedIconURL(for notificationId: String) -> URL? {
            return downloadedNotificationIconFileURLByNotificationId.removeValue(forKey: notificationId)
        }
        
        func setCachedIconURL(_ url: URL, for hash: String) {
            cachedDownloadedNotificationIconFileURLByHash[hash] = url
        }
        
        func getCachedIconURL(for hash: String) -> URL? {
            return cachedDownloadedNotificationIconFileURLByHash[hash]
        }
        
        // MARK: - File I/O Operations (Thread-safe)
        
        func streamForTempDownload() -> TempIconDownloadStream? {
            let temporaryDirectory = NSTemporaryDirectory()
            let randomUuidForFileName = "\(UUID().uuidString)"
            let tempFileURL = URL(fileURLWithPath: randomUuidForFileName, relativeTo: URL(fileURLWithPath: temporaryDirectory, isDirectory: true))
            
            var partFileURL = tempFileURL.appendingPathExtension("part")
            var stream: OutputStream? = nil
            for _ in 1...10000 {
                if !FileManager.default.fileExists(atPath: partFileURL.path) {
                    stream = OutputStream(url: partFileURL, append: false)
                    stream?.open()
                    if stream?.hasSpaceAvailable ?? false {
                        break
                    }
                }
                partFileURL = partFileURL.alternativeForDuplicate()
            }
            
            if stream == nil {
                partFileURL = tempFileURL.appendingPathExtension("part-\(UUID().uuidString)")
                if !FileManager.default.fileExists(atPath: partFileURL.path) {
                    stream = OutputStream(url: partFileURL, append: false)
                    stream?.open()
                }
            }
            
            if let readyStream = stream, (stream?.hasSpaceAvailable ?? false) {
                return TempIconDownloadStream(stream: readyStream, fileURL: partFileURL)
            } else {
                stream?.close()
                return nil
            }
        }
        
        func renamePartFile(url partFileURL: URL, to fileName: String) throws -> URL {
            var finalFileURL = partFileURL.deletingLastPathComponent().appendingPathComponent(fileName)
            for _ in 1...10000 {
                if !FileManager.default.fileExists(atPath: finalFileURL.path) {
                    do {
                        try FileManager.default.moveItem(at: partFileURL, to: finalFileURL)
                        return finalFileURL
                    } catch {}
                }
                finalFileURL = finalFileURL.alternativeForDuplicate()
            }
            throw DataPacket.NotificationError.partFileRenameFailed
        }
        
        func copyFileToCache(url fileURL: URL, hash fileHash: String) throws -> URL {
            guard isValidHash(fileHash) else { throw DataPacket.NotificationError.invalidPayloadHash }
            
            let finalFileURL = fileURL.deletingLastPathComponent().appendingPathComponent("\(fileHash).png.cache")
            if FileManager.default.fileExists(atPath: finalFileURL.path) {
                Logger.services.debug("Cache icon already exists for hash \(fileHash, privacy: .public): \(finalFileURL.path, privacy: .public)")
                return finalFileURL
            }
            
            do {
                try FileManager.default.copyItem(at: fileURL, to: finalFileURL)
                return finalFileURL
            } catch {
                // Another task may have copied the same cache file first.
                if isFileAlreadyExistsError(error) && FileManager.default.fileExists(atPath: finalFileURL.path) {
                    Logger.services.debug("Cache icon copy raced but destination now exists for hash \(fileHash, privacy: .public): \(finalFileURL.path, privacy: .public)")
                    return finalFileURL
                }
                Logger.services.error(
                    "Failed to copy icon to cache for hash \(fileHash, privacy: .public). src=\(fileURL.path, privacy: .public) srcExists=\(FileManager.default.fileExists(atPath: fileURL.path), privacy: .public) dst=\(finalFileURL.path, privacy: .public) dstExists=\(FileManager.default.fileExists(atPath: finalFileURL.path), privacy: .public) error=\(error, privacy: .public)"
                )
                throw DataPacket.NotificationError.copyFileFailed
            }
        }
        
        func copyFileFromCache(url fileURL: URL, notificationId: String) throws -> URL {
            let safeFileName = sanitize(notificationId) + ".png"
            let finalFileURL = fileURL.deletingLastPathComponent().appendingPathComponent(safeFileName)
            if FileManager.default.fileExists(atPath: finalFileURL.path) {
                Logger.services.debug("Notification icon already exists for \(notificationId, privacy: .public): \(finalFileURL.path, privacy: .public)")
                return finalFileURL
            }
            
            do {
                try FileManager.default.copyItem(at: fileURL, to: finalFileURL)
                return finalFileURL
            } catch {
                // Another task may have copied the same notification icon first.
                if isFileAlreadyExistsError(error) && FileManager.default.fileExists(atPath: finalFileURL.path) {
                    Logger.services.debug("Notification icon copy raced but destination now exists for \(notificationId, privacy: .public): \(finalFileURL.path, privacy: .public)")
                    return finalFileURL
                }
                Logger.services.error(
                    "Failed to copy icon from cache for notification \(notificationId, privacy: .public). src=\(fileURL.path, privacy: .public) srcExists=\(FileManager.default.fileExists(atPath: fileURL.path), privacy: .public) dst=\(finalFileURL.path, privacy: .public) dstExists=\(FileManager.default.fileExists(atPath: finalFileURL.path), privacy: .public) error=\(error, privacy: .public)"
                )
                throw DataPacket.NotificationError.copyFileFailed
            }
        }
        
        private func isValidHash(_ hash: String) -> Bool {
            let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
            return !hash.isEmpty && hash.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
        
        private func sanitize(_ string: String) -> String {
            let invalidCharacters = CharacterSet(charactersIn: "/:|\\<>\"?*")
            return string.components(separatedBy: invalidCharacters).joined(separator: "_")
        }
        
        private func isFileAlreadyExistsError(_ error: Error) -> Bool {
            let nsError = error as NSError
            return nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteFileExistsError
        }
    }
    
    /// Represents the synchronization phase for a single device's notification sync lifecycle
    ///
    /// The sync lifecycle proceeds as:
    ///   `.preparing` → `.syncing` → (optionally) `.verifying` → back to absent (idle)
    ///
    /// - `preparing`: setup() is running async prep work (cleanup, reconcile, repopulate).
    ///   Notification IDs arriving during this phase are buffered.
    /// - `syncing`: The first `notification.request` has been sent. Received IDs are tracked.
    ///   When the debounce timer fires, `finishSyncWindow` computes suspected stale IDs.
    ///   If none are found, the phase ends. If some are found, transitions to `.verifying`.
    /// - `verifying`: A second `notification.request` has been sent solely to confirm whether
    ///   suspected-stale IDs are truly gone. New notifications are still processed normally,
    ///   but **no new suspects are created**. When the debounce timer fires again, any IDs still
    ///   absent from both responses are confirmed stale and removed.
    private enum SyncPhase {
        /// Async prep in progress; buffering early-arriving notification IDs.
        case preparing(bufferedIds: Set<NotificationId>)
        
        /// First sync window open; tracking received IDs from the initial `notification.request`.
        case syncing(receivedIds: Set<NotificationId>)
        
        /// Verification window open; confirming suspected-stale IDs with a second request.
        /// `suspectedStaleIds`: IDs absent from the first response that need confirmation.
        /// `receivedIds`: IDs received during this verification window.
        case verifying(suspectedStaleIds: Set<NotificationId>, receivedIds: Set<NotificationId>)
    }
    
    /// MainActor-isolated state manager for active notifications and sync tasks.
    @MainActor
    private class NotificationStateManager {
        nonisolated init() {}
        
        /// A notification that arrived before its app hit the grouping threshold,
        /// held so it can be re-posted into the app group when the threshold is crossed.
        struct UngroupedEntry {
            let notificationId: NotificationId
            let payloadHash: String?   // nil if the notification had no icon
        }
        
        /// Number of notifications from the same app required before we group them.
        static let groupingThreshold = 3
        
        /// Delivered notification ids grouped by device
        var notificationIds: [Device.Id: Set<NotificationId>] = [:]
        
        /// Tracks the last known content hash for each notification to detect true updates vs reconnection duplicates
        var notificationContentHashes: [NotificationId: String] = [:]
        
        /// Current sync phase per device. Absent (nil) means idle — no sync in progress.
        var syncPhase: [Device.Id: SyncPhase] = [:]
        
        /// Debounce tasks for sync window reconciliation, per device.
        var debounceTasks: [Device.Id: Task<Void, Never>] = [:]
        
        /// Tracks setup generations to prevent stale setup tasks from mutating current sync state.
        var setupGenerationByDevice: [Device.Id: Int] = [:]
        
        /// Tasks for device setup/sync
        var setupTasks: [Device.Id: Task<Void, Never>] = [:]
        
        /// Monotonically-increasing notification count per (deviceId, appName). Never decremented —
        /// once an app crosses the grouping threshold it stays grouped for the session.
        var appNotifCounts: [Device.Id: [String: Int]] = [:]
        
        /// Pre-threshold notifications waiting to be promoted into their app group
        /// when the threshold is crossed. Cleared permanently at that point.
        var ungroupedEntries: [Device.Id: [String: [UngroupedEntry]]] = [:]
        
        func addNotificationId(_ id: NotificationId, from device: Device) {
            if notificationIds[device.id] == nil {
                notificationIds[device.id] = Set<NotificationId>()
            }
            notificationIds[device.id]?.insert(id)
        }
        
        func removeNotificationId(_ id: NotificationId, from device: Device) {
            _ = notificationIds[device.id]?.remove(id)
        }
        
        func reset() {
            notificationIds.removeAll()
            notificationContentHashes.removeAll()
            debounceTasks.values.forEach { $0.cancel() }
            debounceTasks.removeAll()
            syncPhase.removeAll()
            setupGenerationByDevice.removeAll()
            setupTasks.values.forEach { $0.cancel() }
            setupTasks.removeAll()
            appNotifCounts.removeAll()
            ungroupedEntries.removeAll()
        }
        
        /// Returns the thread identifier to stamp on a new notification and whether the caller
        /// should immediately trigger re-grouping of the pre-threshold notifications.
        func threadIdentifier(for appName: String, deviceId: Device.Id, notificationId: NotificationId, payloadHash: String?) -> (threadId: String, needsRegroup: Bool) {
            let count = (appNotifCounts[deviceId]?[appName] ?? 0) + 1
            appNotifCounts[deviceId, default: [:]][appName] = count
            if count < NotificationStateManager.groupingThreshold {
                ungroupedEntries[deviceId, default: [:]][appName, default: []].append(
                    UngroupedEntry(notificationId: notificationId, payloadHash: payloadHash)
                )
                return (deviceId, false)
            } else if count == NotificationStateManager.groupingThreshold {
                return ("\(deviceId).\(appName)", true)
            } else {
                return ("\(deviceId).\(appName)", false)
            }
        }
        
        /// Atomically reads and clears the ungrouped entries for an app.
        /// Called exactly once per app per session, when the threshold is first crossed.
        func takeUngroupedEntries(for appName: String, deviceId: Device.Id) -> [UngroupedEntry] {
            let entries = ungroupedEntries[deviceId]?[appName] ?? []
            ungroupedEntries[deviceId]?[appName] = nil
            return entries
        }
        
        /// Clears per-device grouping state. Called on device disconnect so reconnections start fresh.
        func resetGroupingState(for deviceId: Device.Id) {
            appNotifCounts[deviceId] = nil
            ungroupedEntries[deviceId] = nil
        }
    }
    
    
    // MARK: Properties
    
    let un = UNUserNotificationCenter.current()
    
    @MainActor
    private var userNotificationManager: UserNotificationManager {
        let manager = AppDelegate.shared().userNotificationManager
        precondition(manager != nil, "UserNotificationManager accessed before applicationDidFinishLaunching")
        return manager!
    }
    
    
    // MARK: Service properties
    
    public static let serviceId: Service.Id = "com.soduto.services.notifications"
    
    public let incomingCapabilities = Set<Service.Capability>([ DataPacket.notificationPacketType ])
    public let outgoingCapabilities = Set<Service.Capability>([
        DataPacket.notificationRequestPacketType,
        DataPacket.notificationReplyPacketType,
        DataPacket.notificationActionPackageType
    ])
    
    private let iconState = IconStateManager()
    private let state = NotificationStateManager()
    
    /// Manager to ensure startup cleanup only runs once per app session (static, process-wide)
    private static let cleanupManager = StartupCleanupManager()
    
    /// Time to wait for the first notification packet before assuming the device has no notifications.
    private let initialSyncTimeout: TimeInterval = 3.5
    
    /// Time to wait after the last received notification packet before reconciling.
    /// This acts as a debounce to ensure we received the full batch of notifications even on slow networks.
    private let syncDebounceTimeout: TimeInterval = 2.0
    
    // MARK: Service methods
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        guard dataPacket.isNotificationPacket else { return false }
        
        // Log the raw packet (enable only when debugging, as logs may leak sensitive info)
        //Logger.services.debug("NotificationsService received packet: \(dataPacket.body, privacy: .public)")
        
        Task {
            if (try? dataPacket.getRequestFlag()) ?? false {
                // Doing nothing as we dont (at least currently) provide our own notifications to other devices
            }
            else if (try? dataPacket.getCancelFlag()) ?? false {
                await self.hideNotification(for: dataPacket, from: device)
            }
            else {
                // Eagerly record this notification ID for sync window tracking, before starting any icon download
                if let syncNotificationId = self.notificationId(for: dataPacket, from: device) {
                    await MainActor.run {
                        self.recordReceivedNotificationId(syncNotificationId, for: device)
                    }
                }
                do {
                    let id = try dataPacket.getId() ?? nil
                    if id != nil && dataPacket.downloadTask != nil {
                        let iconDownloadTask = dataPacket.downloadTask
                        await self.startIconDownloadTaskAndShowNotification(downloadTask: iconDownloadTask!, notificationId: id!, dataPacket: dataPacket, device: device)
                    }
                    else {
                        // No download task - try to find cached icon
                        if let id = id {
                            // First, try by payload hash (if the packet includes it)
                            if let payloadHash = try? dataPacket.getPayloadHash(),
                               let cachedIconURL = await self.iconState.getCachedIconURL(for: payloadHash) {
                                Logger.services.debug("Using cached icon for notification \(id, privacy: .public) with hash \(payloadHash, privacy: .public)")
                                do {
                                    let copiedFromCacheFileURL = try await self.iconState.copyFileFromCache(url: cachedIconURL, notificationId: id)
                                    await self.iconState.setDownloadedIconURL(copiedFromCacheFileURL, for: id)
                                } catch {
                                    Logger.services.error("Failed to copy cached icon: \(error.localizedDescription, privacy: .public)")
                                }
                            }
                            // Second, check if we already have a downloaded icon for this notification ID
                            else if await self.iconState.getDownloadedIconURL(for: id) != nil {
                                Logger.services.debug("Icon already available for notification \(id, privacy: .public)")
                            }
                            else {
                                Logger.services.debug("No icon available for notification \(id, privacy: .public) - no downloadTask, no payloadHash match, no cached icon")
                            }
                        }
                        
                        await self.showNotification(for: dataPacket, from: device)
                    }
                }
                catch {
                    await self.showNotification(for: dataPacket, from: device)
                }
            }
        }
        
        return true
    }
    
    /// Called when a device connects. Requests current notifications from the device.
    ///
    /// ## Synchronization model
    ///
    /// The sync lifecycle for a device proceeds through explicit phases (see `SyncPhase`):
    ///
    /// 1. **Preparing** (`.preparing`): Async setup work runs — icon cleanup, state reconciliation,
    ///    repopulation from Notification Center. Notification IDs arriving early are buffered.
    /// 2. **Syncing** (`.syncing`): The first `notification.request` is sent. Received IDs are tracked
    ///    with a debounce timer. When the timer fires, suspected-stale IDs are computed.
    /// 3. **Verifying** (`.verifying`): If any suspected-stale IDs were found, a second
    ///    `notification.request` is sent to confirm. IDs absent from both responses are confirmed
    ///    stale and removed. No new suspects are created in this phase.
    ///
    /// ## Key behavioral choices
    ///
    /// - If zero notification packets are observed in a sync window, the sync is treated as
    ///   non-authoritative and no destructive stale-removal is performed.
    /// - IDs observed after setup begins but before the sync window opens are buffered in the
    ///   `.preparing` phase and merged when transitioning to `.syncing`.
    /// - Stale removal requires two consecutive absences (initial + verification) to protect against
    ///   Android's `NotificationListenerService.getActiveNotifications()` occasionally returning
    ///   incomplete results. This ensures we don't falsely remove notifications that Android simply
    ///   didn't include in a single response.
    ///
    /// ## Duplicate alert prevention
    ///
    /// - `isAlreadyDisplayed` check: Notifications already in `notificationIds` are skipped entirely
    ///   if their content hash is unchanged (reconnection scenario), preventing unnecessary refreshes
    ///   when the device momentarily reconnects (e.g., WiFi change, charging starts)
    ///
    /// On app startup, `notificationIds` is empty, so we first repopulate it from the
    /// Notification Center's delivered notifications before requesting new ones.
    public func setup(for device: Device) {
        guard device.incomingCapabilities.contains(DataPacket.notificationPacketType) else { return }
        
        // Clean up stale icon files from previous app sessions (once per app launch, process-wide).
        /// We await this cleanup BEFORE requesting new notifications to avoid race conditions where
        /// we might delete valid icons for newly arriving notifications.
        Task { @MainActor in
            state.setupTasks[device.id]?.cancel()
            state.debounceTasks[device.id]?.cancel()
            let generation = (state.setupGenerationByDevice[device.id] ?? 0) + 1
            state.setupGenerationByDevice[device.id] = generation
            state.syncPhase[device.id] = .preparing(bufferedIds: [])
            
            let setupTask = Task {
                await Self.cleanupManager.ensureCleanup { Self.cleanupStaleIconFiles() }
                /// First reconcile to remove any stale entries for notifications dismissed via macOS UI,
                /// then repopulate from delivered notifications to restore state after app restart.
                /// This ensures that on app restart, we don't re-alert for already-displayed notifications.
                await reconcileNotificationState()
                await repopulateNotificationIds(for: device)
                
                // Check generation on MainActor before proceeding
                let shouldProceed = await MainActor.run {
                    state.setupGenerationByDevice[device.id] == generation
                }
                guard shouldProceed else { return }
                
                // Transition from .preparing to .syncing, merging any buffered IDs
                await MainActor.run {
                    startSyncWindow(for: device)
                    state.setupGenerationByDevice.removeValue(forKey: device.id)
                }
                device.send(DataPacket.notificationRequestPacket())
            }
            state.setupTasks[device.id] = setupTask
            await setupTask.value
        }
    }
    
    /// Removes all locally-delivered notifications associated with the given device.
    /// Called by the Service lifecycle when the device becomes unavailable.
    ///
    /// This method is invoked when the device is reported as disconnected or unavailable.
    /// For `NotificationsService`, this does NOT imply that remote notifications were dismissed. Connections may be transient, and notification state must
    /// be reconciled on the next successful setup.
    ///
    /// IMPORTANT:
    /// - It may be called multiple times for the same device.
    /// - It does not distinguish between momentary connection loss and actual device removal.
    ///
    /// With modern KDE Connect behavior (frequent transient disconnects), this can cause notifications to be removed prematurely and interfere
    /// with debounce or time-based synchronization logic, hence this method does not immediately remove notifications. Actual cleanup is
    /// performed only in response to authoritative remote cancel packets or post-reconnection reconciliation.
    public func cleanup(for device: Device) {
        Logger.services.debug("Ignoring cleanup for \(device.name, privacy: .public); waiting for reconciliation and reconnection...")
        Task { @MainActor in
            state.resetGroupingState(for: device.id)
        }
    }
    
    /// Defines service actions for notifications service (like: `Request Notifications`)
    public func actions(for device: Device) -> [ServiceAction] {
        guard device.incomingCapabilities.contains(DataPacket.notificationRequestPacketType) else { return [] }
        guard device.pairingStatus == .Paired else { return [] }
        
        return [
            ServiceAction(id: ActionId.refresh.rawValue, group: "setup", title: "Request Notifications", description: "Send notification request to the remote device", service: self, device: device)
        ]
    }
    
    /// Performs service actions for a specific device (like: `Request Notifications`)
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device, userInfo: [String: Any]?) {
        guard let actionId = ActionId(rawValue: id) else { return }
        guard device.pairingStatus == .Paired else { return }
        
        switch actionId {
        case .refresh:
            // Reconcile state first to clean up any notifications dismissed via macOS UI
            Task { @MainActor in
                await reconcileNotificationState()
                device.send(DataPacket.notificationRequestPacket())
            }
        }
    }
    
    // MARK: DownloadTaskDelegate
    
    /// Delegate callback for download completion.
    /// Note: This is called on the Main Thread (default delegate queue for DownloadTask).
    /// We offload the processing to a Task to interact with the internal actors safely.
    public func downloadTask(_ task: DownloadTask, finishedWithSuccess success: Bool) {
        Logger.services.debug("downloadTask(<\(task.id, privacy: .public)> finishedWithSuccess:<\(success, privacy: .public)>)")
        
        Task {
            guard let info = await self.iconState.removeDownloadInfo(for: task) else { return }
            if success {
                do {
                    // Sanitize the notification ID for use in filename (remove |, :, etc.)
                    let safeFileName = sanitizeForFilename(info.notificationId) + ".png"
                    let finalFileURL = try await self.iconState.renamePartFile(url: info.partFileURL, to: safeFileName)
                    Logger.services.debug("downloadTask saving icon to: \(finalFileURL.path, privacy: .public)")
                    Logger.services.debug("Notification id: \(info.notificationId, privacy: .public)")
                    
                    await self.iconState.setDownloadedIconURL(finalFileURL, for: info.notificationId)
                    
                    if let fileHash = info.fileHash, await self.iconState.getCachedIconURL(for: fileHash) == nil {
                        let cachedFileURL = try await self.iconState.copyFileToCache(url: finalFileURL, hash: fileHash)
                        await self.iconState.setCachedIconURL(cachedFileURL, for: fileHash)
                        Logger.services.debug("New icon found with hash \(fileHash, privacy: .public), saving to cached icons as \(cachedFileURL, privacy: .public)")
                    }
                }
                catch let error {
                    Logger.services.error("Failed to process downloaded icon for \(info.notificationId, privacy: .public): \(error, privacy: .public)")
                }
            }
            await self.showNotification(for: info.dataPacket, from: info.device)
        }
    }
    
    
    // MARK: UserNotificationActionHandler
    
    /// Handles user responses to notification actions.
    ///
    /// ## Dismiss Philosophy
    ///
    /// We provide a custom "Dismiss" action button that dismisses the notification on **both**
    /// the host (macOS) and remote (Android) device. This is more reliable than relying on
    /// `UNNotificationDismissActionIdentifier` callbacks from macOS, which are not always
    /// delivered consistently.
    ///
    /// - **Custom Dismiss button**: Dismisses on both macOS and Android (sends cancel packet)
    /// - **macOS system dismiss** (X button/swipe): Dismisses only on macOS (no cancel packet sent)
    /// - **Clicking notification body**: Does nothing - notification stays visible
    ///
    /// This design ensures users have explicit control over whether a notification is
    /// dismissed on the remote device, rather than accidentally dismissing it by clicking.
    ///
    /// ## Supported Actions
    ///
    /// - **Dismiss**: Sends a cancel packet to the remote device if the notification is cancelable
    /// - **Reply**: Sends the user's text reply to the remote device
    /// - **Action1/2/3**: Sends the semantic action string stored in userInfo to trigger the remote action
    /// - **Copy OTP**: Copies the detected OTP from userInfo to the clipboard (no device interaction)
    /// - **Default (body click)**: Ignored - notification remains visible
    public static func handleAction(for response: UNNotificationResponse, context: UserNotificationContext) {
        let userInfo = response.notification.request.content.userInfo
        
        // Clicking the notification body should do nothing - the notification stays visible.
        // Users must use the explicit "Dismiss" button to dismiss on both macOS and Android.
        // See the Dismiss Philosophy documentation above.
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            return
        }
        
        // Handle "Copy OTP" — reads the stored code from userInfo, copies it to the clipboard,
        // and shows a HUD toast. No device interaction needed, so this works even if the remote
        // device has disconnected since the notification was delivered.
        if response.actionIdentifier == UserNotificationManager.ActionIdentifier.copyOtp.rawValue {
            if let otp = userInfo[UserNotificationManager.Property.otpCode.rawValue] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(otp, forType: .string)
                MainActor.assumeIsolated { HUDToast.show("OTP Copied") }
            }
            return
        }
        
        guard let deviceId = userInfo[UserInfoProperty.deviceId.rawValue] as? String else { return }
        guard let notificationId = userInfo[UserInfoProperty.notificationId.rawValue] as? NotificationId else { return }
        guard let isCancelable = userInfo[UserInfoProperty.isCancelable.rawValue] as? NSNumber else { return }
        guard let device = context.deviceManager.device(withId: deviceId) else { return }
        guard device.pairingStatus == .Paired else { return }
        
        let actionId = response.actionIdentifier
        
        // Handle dismiss action - dismisses on both macOS and Android
        if actionId == UserNotificationManager.ActionIdentifier.dismiss.rawValue {
            if isCancelable.boolValue {
                device.send(DataPacket.notificationCancelPacket(forId: notificationId))
            }
        }
        // Handle reply action
        else if actionId == UserNotificationManager.ActionIdentifier.reply.rawValue {
            if let textInputResponse = response as? UNTextInputNotificationResponse {
                let message = textInputResponse.userText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let requestReplyId = userInfo[UserInfoProperty.requestReplyId.rawValue] as? String else { return }
                guard !message.isEmpty else {
                    Logger.services.debug("Empty reply message ignored for notification \(notificationId, privacy: .public)")
                    return
                }
                device.send(DataPacket.notificationReplyPacket(forId: requestReplyId, message: message))
            }
        }
        // Handle positional action buttons - look up semantic meaning from userInfo
        else if actionId == UserNotificationManager.ActionIdentifier.action1.rawValue {
            if let semanticAction = userInfo[UserNotificationManager.Property.action1.rawValue] as? String {
                device.send(DataPacket.notificationActionPacket(forAction: semanticAction, forKey: notificationId))
            }
        }
        else if actionId == UserNotificationManager.ActionIdentifier.action2.rawValue {
            if let semanticAction = userInfo[UserNotificationManager.Property.action2.rawValue] as? String {
                device.send(DataPacket.notificationActionPacket(forAction: semanticAction, forKey: notificationId))
            }
        }
        else if actionId == UserNotificationManager.ActionIdentifier.action3.rawValue {
            if let semanticAction = userInfo[UserNotificationManager.Property.action3.rawValue] as? String {
                device.send(DataPacket.notificationActionPacket(forAction: semanticAction, forKey: notificationId))
            }
        }
        
        // Remove the notification ID from tracking
        for service in context.serviceManager.services {
            guard let notificationsService = service as? NotificationsService else { continue }
            Task { @MainActor in
                notificationsService.state.removeNotificationId(notificationId, from: device)
            }
        }
    }
    
    // MARK: Public methods
    
    /// Requests all current notifications from all connected devices.
    /// This clears local notification state and re-fetches everything.
    public func refreshNotifications() {
        let devices = AppDelegate.shared().validDevices
        
        Task { @MainActor in
            state.reset()
            un.removeAllDeliveredNotifications()
            un.removeAllPendingNotificationRequests()
            
            // Request notifications from each device
            for device in devices {
                guard device.incomingCapabilities.contains(DataPacket.notificationRequestPacketType) else { continue }
                device.send(DataPacket.notificationRequestPacket())
            }
        }
    }
    
    
    // MARK: Private methods
    
    private func notificationId(for dataPacket: DataPacket, from device: Device) -> NotificationId? {
        assert(dataPacket.isNotificationPacket, "Expected notification data packet")
        
        guard let deviceId = device.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        guard let packetId = (try? dataPacket.getId())??.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        
        return "\(self.id).\(deviceId).\(packetId)"
    }
    
    /// Extracts the raw remote notification ID from a tracked local notification identifier.
    /// Local format: `<serviceId>.<encodedDeviceId>.<encodedRemoteNotificationId>`
    private func packetNotificationId(from trackedId: NotificationId, for device: Device) -> String {
        guard let encodedDeviceId = device.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            return trackedId
        }
        let prefix = "\(self.id).\(encodedDeviceId)."
        guard trackedId.hasPrefix(prefix) else { return trackedId }
        
        let encodedPacketId = String(trackedId.dropFirst(prefix.count))
        return encodedPacketId.removingPercentEncoding ?? encodedPacketId
    }
    
    /// Sanitizes a string to be safe for use in filenames by replacing invalid characters.
    /// macOS doesn't allow: / : in filenames. We also replace | and other problematic chars.
    private func sanitizeForFilename(_ string: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:|\\<>\"?*")
        return string.components(separatedBy: invalidCharacters).joined(separator: "_")
    }
    
    /// Repopulates the `notificationIds` dictionary from the Notification Center's delivered notifications.
    /// This is necessary because `notificationIds` is in-memory and lost on app restart.
    ///
    /// Important: this method must MERGE, not early-return, even when we already have in-memory IDs.
    /// During setup, pre-sync packets can arrive before repopulation runs; if we skip here, we can miss
    /// previously delivered notifications from an earlier app session and break duplicate detection.
    private func repopulateNotificationIds(for device: Device) async {
        guard let deviceIdEncoded = device.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            Logger.services.error("Failed to encode device ID for \(device.name, privacy: .public)")
            return
        }
        
        // Build the prefix we use for this device's notifications
        let prefix = "\(self.id).\(deviceIdEncoded)."
        
        let notifications = await un.deliveredNotifications()
        
        await MainActor.run {
            var matchCount = 0
            var insertedCount = 0
            for notification in notifications {
                let identifier = notification.request.identifier
                // Check if this notification belongs to this service and device
                if identifier.hasPrefix(prefix) {
                    let alreadyTracked = state.notificationIds[device.id]?.contains(identifier) ?? false
                    state.addNotificationId(identifier, from: device)
                    // Also restore the content hash so we can detect reconnection duplicates
                    let body = notification.request.content.body
                    state.notificationContentHashes[identifier] = StableHashing.sha256(body)
                    // Restore grouping threshold so existing app groups are immediately honoured
                    // on the next notification
                    if let storedAppName = notification.request.content.userInfo[UserInfoProperty.appName.rawValue] as? String,
                       !storedAppName.isEmpty {
                        let current = state.appNotifCounts[device.id]?[storedAppName] ?? 0
                        if current < NotificationStateManager.groupingThreshold {
                            state.appNotifCounts[device.id, default: [:]][storedAppName] = NotificationStateManager.groupingThreshold
                        }
                    }
                    matchCount += 1
                    if !alreadyTracked {
                        insertedCount += 1
                    }
                }
            }
            
            if matchCount > 0 || insertedCount > 0 {
                Logger.services.debug("Repopulated \(matchCount, privacy: .public) delivered notification IDs for device \(device.name, privacy: .public); inserted \(insertedCount, privacy: .public) missing IDs into in-memory state")
            }
        }
    }
    
    /// Reconciles the in-memory `notificationIds` and `notificationContentHashes` with what's actually
    /// in the Notification Center. This handles the case where users dismissed notifications via
    /// macOS's native UI (swipe, X button, or clearing from Notification Center) without using our
    /// "Dismiss" action button.
    ///
    /// Call this at key moments like refresh or before requesting new notifications.
    private func reconcileNotificationState() async {
        let prefix = "\(self.id)."
        
        let deliveredNotifications = await un.deliveredNotifications()
        
        await MainActor.run {
            // Build a set of all notification IDs currently in Notification Center
            let deliveredIds = Set(deliveredNotifications.map { $0.request.identifier })
            
            var removedCount = 0
            
            // For each device, remove any tracked IDs that are no longer delivered
            for (deviceId, trackedIds) in state.notificationIds {
                let stale = trackedIds.filter { $0.hasPrefix(prefix) && !deliveredIds.contains($0) }
                for trackedId in stale {
                    /// NOTE: DO NOT clean up icon files HERE, because they are cached for the very reason
                    /// that KDE Connect does NOT send download Tasks on subsequent requests
                    _ = state.notificationIds[deviceId]?.remove(trackedId)
                    state.notificationContentHashes.removeValue(forKey: trackedId)
                }
                removedCount += stale.count
            }
            
            if removedCount > 0 {
                Logger.services.debug("Reconciled notification state: removed \(removedCount, privacy: .public) stale entries")
            }
        }
    }
    
    private func startIconDownloadTaskAndShowNotification(downloadTask task: DownloadTask, notificationId: String, dataPacket: DataPacket, device: Device) async {
        var downloadFileHash: String? = nil
        do {
            downloadFileHash = try dataPacket.getPayloadHash()
        }
        catch {}
        
        if let hash = downloadFileHash, let cachedURL = await iconState.getCachedIconURL(for: hash) {
            Logger.services.debug("Found cached icon for hash \(hash, privacy: .public) at \(cachedURL, privacy: .public)")
            do {
                let copiedFromCacheFileURL = try await iconState.copyFileFromCache(url: cachedURL, notificationId: notificationId)
                await iconState.setDownloadedIconURL(copiedFromCacheFileURL, for: notificationId)
            }
            catch let error {
                Logger.services.error("Failed to copy cached icon for \(notificationId, privacy: .public): \(error, privacy: .public)")
            }
            await self.showNotification(for: dataPacket, from: device)
        } else {
            if let tempStream = await iconState.streamForTempDownload() {
                let partFileURL = tempStream.fileURL
                await iconState.addDownloadInfo(DownloadInfo(
                    task: task,
                    fileHash: downloadFileHash,
                    notificationId: notificationId,
                    partFileURL: partFileURL,
                    dataPacket: dataPacket,
                    device: device
                ))
                task.delegate = self
                task.start(withStream: tempStream.transfer())
            }
        }
    }
    
    /// Cleans up stale notification icon files from the temp directory.
    /// Call this on app startup to remove leftover files from previous sessions.
    ///
    /// This cleans up:
    /// - `.png` files (downloaded icons)
    /// - `.png.cache` files (cached icons by hash)
    /// - `.part` files (incomplete downloads)
    ///
    /// Files in NSTemporaryDirectory are eventually cleaned by macOS, but this
    /// provides more immediate cleanup to prevent accumulation over time.
    private static func cleanupStaleIconFiles() {
        let tempDirectory = NSTemporaryDirectory()
        let fileManager = FileManager.default
        
        do {
            let tempContents = try fileManager.contentsOfDirectory(atPath: tempDirectory)
            var cleanedCount = 0
            
            for fileName in tempContents {
                // Only clean up files that look like our notification icons
                let isNotificationIcon = fileName.hasSuffix(".png") ||
                                          fileName.hasSuffix(".png.cache") ||
                                          fileName.hasSuffix(".part")
                
                // Skip files that don't match our patterns
                guard isNotificationIcon else { continue }
                
                let filePath = (tempDirectory as NSString).appendingPathComponent(fileName)
                try? fileManager.removeItem(atPath: filePath)
                cleanedCount += 1
            }
            
            if cleanedCount > 0 {
                Logger.services.debug("Cleaned up \(cleanedCount, privacy: .public) stale notification icon files from temp directory")
            }
        } catch {
            Logger.services.error("Failed to enumerate temp directory for icon cleanup: \(error, privacy: .public)")
        }
    }
    
    private func buildNotificationContent(
        for dataPacket: DataPacket,
        from device: Device,
        of packetNotificationId: String,
        conversation: [DataPacket.ConversationMessage]?,
        isSilent: Bool,
        title: String?,
        body: String?,
        groupName: String?,
        ticker: String,
        appName: String,
        replyId: String?,
        isCancelable: Bool,
        actions: [String]?,
        otpCode: String?,
        threadIdentifier: String
    ) async -> UNMutableNotificationContent {
        let notification = UNMutableNotificationContent()
        
        /// Filter actions — exclude:
        /// - Empty action buttons (like in sensitive notifications from Google Messages)
        /// - "Reply" (handled separately via requestReplyId)
        /// - Native copy-OTP actions (e.g. `Copy OTP`, `Copy "XYZABC"`) — they copy on the remote device, which is useless on macOS. We provide our own button when an OTP is detected
        var filteredActions: [String] = []
        if let actions = actions {
            for action in actions {
                let lower = action.lowercased()
                if lower == "" { continue }
                // Suppress inline reply buttons as they are not supported
                if lower == "reply" { continue }
                // Suppress native copy-otp style buttons as we provide our own
                if lower.hasPrefix("copy") { continue }
                filteredActions.append(action)
            }
        }
        // Limit to max 3 custom actions (Android can show max 3)
        let actionCount = min(filteredActions.count, 3)
        
        let shouldMute = isSilent
        
        // Build userInfo with base properties
        var userInfo: [String: Any] = [
            UserInfoProperty.deviceId.rawValue: device.id,
            UserInfoProperty.appName.rawValue: appName,
            UserInfoProperty.notificationId.rawValue: packetNotificationId,
            UserInfoProperty.requestReplyId.rawValue: replyId as Any,
            UserInfoProperty.isCancelable.rawValue: NSNumber(value: isCancelable),
            UserNotificationManager.Property.shouldMute.rawValue: NSNumber(value: shouldMute),
            UserNotificationManager.Property.actionHandlerClass.rawValue: NSStringFromClass(NotificationsService.self)
        ]
        
        // Store semantic action mappings in userInfo using positional keys
        if actionCount >= 1 {
            userInfo[UserNotificationManager.Property.action1.rawValue] = filteredActions[0]
        }
        if actionCount >= 2 {
            userInfo[UserNotificationManager.Property.action2.rawValue] = filteredActions[1]
        }
        if actionCount >= 3 {
            userInfo[UserNotificationManager.Property.action3.rawValue] = filteredActions[2]
        }
        if let otp = otpCode {
            userInfo[UserNotificationManager.Property.otpCode.rawValue] = otp
        }
        
        notification.userInfo = userInfo
        notification.title = "\(appName) | \(device.name)"
        
        (notification.subtitle, notification.body) = renderNotificationContent(
            title: title,
            body: body,
            ticker: ticker,
            groupName: groupName,
            conversation: conversation
        )
        notification.threadIdentifier = threadIdentifier
        
        let hasReply = replyId != nil
        let actionTitles = Array(filteredActions.prefix(3))
        let categoryId = await userNotificationManager.getOrCreateCategory(
            hasReply: hasReply,
            actionTitles: actionTitles,
            otpCode: otpCode
        )
        notification.categoryIdentifier = categoryId
        
        /// Only play sound if notification is not muted
        /// shouldMute is true for: silent notifications from android
        if !shouldMute {
            notification.sound = .default
        }
        /// Set interruption level based on notification type
        /// - passive: for silent/muted notifications (won't interrupt user)
        /// - active: for normal notifications (default behavior)
        if shouldMute {
            notification.setUrgency(.passive)
        } else {
            notification.setUrgency(.active)
        }
        
        return notification
    }
    
    /// Renders the subtitle and body for a notification, with conversation-aware formatting.
    ///
    /// Conversation rendering follows KDE Desktop's approach:
    ///  - **Group conversation** (groupName present): subtitle = groupName, body shows sender labels
    ///    only when the sender changes between consecutive messages.
    ///  - **1:1 conversation** (no groupName): subtitle = first message's sender (or existing title),
    ///    body shows message content only (single sender, no labels needed).
    ///  - **Non-conversation**: subtitle = title, body = text (or ticker fallback).
    ///
    /// - Parameters:
    ///   - title: The notification title (e.g., sender name in messaging apps)
    ///   - body: The notification body text
    ///   - ticker: The notification summary (fallback)
    ///   - groupName: The group name if this is a group conversation
    ///   - conversation: Message history array if this is a conversation notification
    /// - Returns: A tuple of (subtitle, body) for the notification content
    private func renderNotificationContent(
        title: String?,
        body: String?,
        ticker: String,
        groupName: String?,
        conversation: [DataPacket.ConversationMessage]?
    ) -> (subtitle: String, body: String) {
        guard let messages = conversation, !messages.isEmpty else {
            return (subtitle: groupName ?? title ?? "", body: body ?? ticker)
        }
        
        let isGroup = groupName != nil
        let subtitle = isGroup ? groupName! : (messages.first?.sender ?? title ?? "")
        
        var lines: [String] = []
        var previousSender: String? = subtitle
        for message in messages {
            guard !message.content.isEmpty else { continue }
            if isGroup {
                if message.sender != previousSender {
                    lines.append("\(message.sender): \(message.content)")
                    previousSender = message.sender
                } else {
                    lines.append("  \(message.content)")
                }
            } else if message.sender != subtitle {
                // 1:1: mark non-contact messages with › (e.g. the user's own replies)
                lines.append("› \(message.content)")
            } else {
                lines.append(message.content)
            }
        }
        let renderedBody = lines.isEmpty ? (body ?? ticker) : lines.joined(separator: "\n")
        
        return (subtitle: subtitle, body: renderedBody)
    }
    
    private func showNotification(for dataPacket: DataPacket, from device: Device) async {
        assert(dataPacket.isNotificationPacket, "Expected notification data packet")
        
        do {
            guard let packetNotificationId = try dataPacket.getId() else {
                Logger.services.debug("Notification rejected: missing ID")
                return
            }
            guard let notificationId = self.notificationId(for: dataPacket, from: device) else {
                Logger.services.debug("Notification rejected: couldn't generate notificationId for packet \(packetNotificationId, privacy: .public)")
                return
            }
            guard let appName = try dataPacket.getAppName() else {
                Logger.services.debug("Notification rejected: missing appName for \(packetNotificationId, privacy: .public)")
                return
            }
            guard appName != "KDE Connect" else {
                Logger.services.debug("Notification rejected: from KDE Connect itself")
                return
            }
            // Gather all data before hopping between threads
            guard let ticker = try dataPacket.getTicker() else {
                Logger.services.debug("Notification rejected: missing ticker for \(appName, privacy: .public) - \(packetNotificationId, privacy: .public)")
                return
            }
            
            let title = try dataPacket.getTitle()
            let body = try dataPacket.getText()
            let groupName = try dataPacket.getGroupName()
            let conversation = try dataPacket.getConversation()
            let replyId = try dataPacket.getReplyRequestId()
            let actions = try dataPacket.getActions()
            let isSilent = try dataPacket.getSilentFlag()
            let isCancelable = try dataPacket.getClearableFlag()
            
            // Interact with MainActor state
            let shouldShow = await MainActor.run { () -> Bool in
                let isAlreadyDisplayed = state.notificationIds[device.id]?.contains(notificationId) ?? false
                
                /// Compute content hash to detect if this is a true update (content changed) vs reconnection duplicate (same content).
                /// For conversations, hash includes all message content so new messages in the thread trigger an update.
                let contentForHash: String
                if let conversation = conversation, !conversation.isEmpty {
                    contentForHash = conversation.map { "\($0.sender)\u{1F}\($0.content)" }.joined(separator: "\u{1E}")
                } else {
                    contentForHash = body ?? ticker
                }
                let currentContentHash = StableHashing.sha256(contentForHash)
                let previousContentHash = state.notificationContentHashes[notificationId]
                let isContentChanged = previousContentHash == nil || previousContentHash != currentContentHash
                
                /// isReconnectionDuplicate: Same notification with same content arriving again
                let isReconnectionDuplicate = isAlreadyDisplayed && !isContentChanged
                
                guard !isReconnectionDuplicate else {
                    Logger.services.debug("Notification skipped (reconnection duplicate): \(appName, privacy: .public) - \(packetNotificationId, privacy: .public)")
                    return false
                }
                
                // Update the stored content hash
                state.notificationContentHashes[notificationId] = currentContentHash
                return true
            }
            
            guard shouldShow else { return }
            
            // Determine the thread identifier for grouping.
            let payloadHash = try? dataPacket.getPayloadHash()
            let (threadId, needsRegroup): (String, Bool) = await MainActor.run {
                guard !appName.isEmpty else { return (device.id, false) }
                return state.threadIdentifier(for: appName, deviceId: device.id, notificationId: notificationId, payloadHash: payloadHash)
            }
            
            // Extract OTP if notification is from an allowed app
            // Show action button always but only auto-copy when in idle phase
            let otpCode: String? = await MainActor.run {
                OTPExtractor.handleIfOTP(
                    body: body, title: title, appName: appName,
                    packetNotificationId: packetNotificationId,
                    autoCopy: state.syncPhase[device.id] == nil
                )
            }
            
            let notificationIconURL: URL? = await iconState.getDownloadedIconURL(for: packetNotificationId)
            
            let notification = await buildNotificationContent(
                for: dataPacket,
                from: device,
                of: packetNotificationId,
                conversation: conversation,
                isSilent: isSilent,
                title: title,
                body: body,
                groupName: groupName,
                ticker: ticker,
                appName: appName,
                replyId: replyId,
                isCancelable: isCancelable,
                actions: actions,
                otpCode: otpCode,
                threadIdentifier: threadId
            )
            
            /// Set Notification App Icon
            /// UNNotificationAttachment MOVES the file to its data store, so we must copy it first
            if let iconURL = notificationIconURL {
                // Track temp file for cleanup on error
                var tempCopyURL: URL? = nil
                do {
                    // Create a temporary copy for the attachment (will be moved by the system)
                    tempCopyURL = iconURL.deletingLastPathComponent()
                        .appendingPathComponent(UUID().uuidString + ".png")
                    try FileManager.default.copyItem(at: iconURL, to: tempCopyURL!)
                    
                    // Use sanitized identifier for attachment
                    let attachmentId = sanitizeForFilename(notificationId)
                    let attachment = try UNNotificationAttachment(identifier: attachmentId, url: tempCopyURL!, options: nil)
                    notification.attachments = [attachment]
                    // On success, tempCopyURL is moved by UNNotificationAttachment - no cleanup needed
                } catch {
                    Logger.services.error("Failed to create notification attachment: \(error.localizedDescription, privacy: .public)")
                    // Clean up the temporary file if it was created but attachment failed
                    if let tempURL = tempCopyURL, FileManager.default.fileExists(atPath: tempURL.path) {
                        try? FileManager.default.removeItem(at: tempURL)
                    }
                    // Opportunistically cleanup icon file dictionary entry, if present
                    if await iconState.removeDownloadedIconURL(for: packetNotificationId) != nil {
                        Logger.services.debug("Removed icon file dictionary entry for failed notification attachment")
                    }
                }
            }
            
            // Create notification request
            let request = UNNotificationRequest(identifier: notificationId, content: notification, trigger: nil)
            
            // Regroup pre-threshold notifications first so the new notification lands last,
            // giving it the most-recent position within the group in Notification Center.
            if needsRegroup {
                let entries = await MainActor.run { state.takeUngroupedEntries(for: appName, deviceId: device.id) }
                if !entries.isEmpty {
                    await regroupNotifications(threadId: threadId, entries: entries)
                }
            }
            
            // Push Notification
            do {
                try await un.add(request)
                await state.addNotificationId(notificationId, from: device)
            } catch {
                Logger.services.error("Failed to add UNNotificationRequest: \(error, privacy: .public)")
            }
        }
        catch {
            Logger.services.error("Error while showing notification: \(error, privacy: .public)")
        }
    }
    
    /// Re-posts pre-threshold notifications into their app group when the threshold is crossed.
    ///
    /// Uses `getDeliveredNotifications` to fetch current content (so attachments are read from
    /// macOS's own store), then rebuilds the attachment from the icon cache before re-adding.
    /// Re-posted notifications use passive urgency as the user already saw the original alert.
    private func regroupNotifications(threadId: String, entries: [NotificationStateManager.UngroupedEntry]) async {
        let delivered = await un.deliveredNotifications()
        for entry in entries {
            guard let notification = delivered.first(where: { $0.request.identifier == entry.notificationId }) else { continue }
            let content = notification.request.content.mutableCopy() as! UNMutableNotificationContent
            content.threadIdentifier = threadId
            content.sound = nil
            content.setUrgency(.passive)
            if let hash = entry.payloadHash,
               let cachedURL = await iconState.getCachedIconURL(for: hash) {
                let originalAttachments = content.attachments
                content.attachments = []
                let tempURL = cachedURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".png")
                do {
                    try FileManager.default.copyItem(at: cachedURL, to: tempURL)
                    let attachmentId = sanitizeForFilename(entry.notificationId)
                    let attachment = try UNNotificationAttachment(identifier: attachmentId, url: tempURL, options: nil)
                    content.attachments = [attachment]
                } catch {
                    Logger.services.error("Failed to rebuild attachment during regroup for \(entry.notificationId, privacy: .public): \(error, privacy: .public)")
                    try? FileManager.default.removeItem(at: tempURL)
                    content.attachments = originalAttachments
                }
            }
            let request = UNNotificationRequest(identifier: entry.notificationId, content: content, trigger: nil)
            try? await un.add(request)
        }
    }
    
    
    private func hideNotification(for dataPacket: DataPacket, from device: Device) async {
        assert(dataPacket.isNotificationPacket, "Expected notification data packet")
        
        guard let id = self.notificationId(for: dataPacket, from: device) else { return }
        
        // If we're in verification phase and this ID is in the suspected set, clear it.
        // The explicit isCancel is authoritative — no need for verification to re-process it.
        await MainActor.run {
            clearSuspectedId(id, for: device)
        }
        
        // Clean up downloaded icon file for this packet
        if let packetId = try? dataPacket.getId() {
            if let iconURL = await iconState.removeDownloadedIconURL(for: packetId) {
                // Delete the actual icon file from disk
                do {
                    try FileManager.default.removeItem(at: iconURL)
                    Logger.services.debug("Deleted icon file for notification \(packetId, privacy: .public) at \(iconURL.path, privacy: .public)")
                } catch {
                    Logger.services.error("Failed to delete icon file for notification \(packetId, privacy: .public): \(error, privacy: .public)")
                }
            }
        }
        
        await self.hideNotification(for: id, from: device)
    }
    
    private func hideNotification(for id: NotificationId, from device: Device) async {
        un.removeNotification(withId: id)
        
        await MainActor.run {
            state.removeNotificationId(id, from: device)
            state.notificationContentHashes.removeValue(forKey: id)
        }
    }
    
    // MARK: Sync Window & Stale Notification Removal
    
    /// Transitions a device from `.preparing` to `.syncing` phase.
    ///
    /// Any notification IDs buffered during the `.preparing` phase are seeded into the
    /// `.syncing` received set, so reconciliation does not lose early packets.
    /// Starts the initial sync timeout (debounce timer).
    @MainActor
    private func startSyncWindow(for device: Device) {
        state.debounceTasks[device.id]?.cancel()
        
        // Extract buffered IDs from the preparing phase
        var bufferedIds: Set<NotificationId> = []
        if case .preparing(let ids) = state.syncPhase[device.id] {
            bufferedIds = ids
        }
        
        // Transition to syncing phase
        state.syncPhase[device.id] = .syncing(receivedIds: bufferedIds)
        
        // Start initial sync timeout
        let task = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: UInt64(initialSyncTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await finishSyncWindow(for: device)
        }
        state.debounceTasks[device.id] = task
        
        if bufferedIds.isEmpty {
            Logger.services.debug("Sync phase → .syncing for \(device.name, privacy: .public)")
        } else {
            Logger.services.debug("Sync phase → .syncing for \(device.name, privacy: .public) with \(bufferedIds.count, privacy: .public) buffered IDs from .preparing")
        }
    }
    
    /// Records a notification ID for sync reconciliation.
    ///
    /// Behavior depends on the current `SyncPhase`:
    /// - `.preparing`: The ID is buffered. It will be merged when transitioning to `.syncing`.
    /// - `.syncing`: The ID is recorded and the debounce timer is reset.
    /// - `.verifying`: The ID is recorded (confirming it's alive) and the debounce timer is reset.
    ///   No new suspects are created in this phase.
    /// - Absent (idle): The ID is ignored — no sync is in progress.
    @MainActor
    private func recordReceivedNotificationId(_ notificationId: NotificationId, for device: Device) {
        guard let phase = state.syncPhase[device.id] else { return }
        
        switch phase {
        case .preparing(var bufferedIds):
            bufferedIds.insert(notificationId)
            state.syncPhase[device.id] = .preparing(bufferedIds: bufferedIds)
            // No debounce needed during preparation — setup drives the transition.
            
        case .syncing(var receivedIds):
            receivedIds.insert(notificationId)
            state.syncPhase[device.id] = .syncing(receivedIds: receivedIds)
            resetDebounceTimer(for: device)
            
        case .verifying(let suspectedStaleIds, var receivedIds):
            receivedIds.insert(notificationId)
            state.syncPhase[device.id] = .verifying(suspectedStaleIds: suspectedStaleIds, receivedIds: receivedIds)
            resetDebounceTimer(for: device)
        }
    }
    
    /// Resets the debounce timer for a device's sync window.
    /// When the timer fires, `finishSyncWindow` is called to process the current phase.
    @MainActor
    private func resetDebounceTimer(for device: Device) {
        state.debounceTasks[device.id]?.cancel()
        let task = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: UInt64(syncDebounceTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await finishSyncWindow(for: device)
        }
        state.debounceTasks[device.id] = task
    }
    
    /// Removes a notification ID from the verification suspected-stale set, if present.
    ///
    /// This is called when an explicit `isCancel` packet arrives during the `.verifying` phase.
    /// Since the notification is being authoritatively cancelled, it should not remain in the
    /// suspected set (which would cause a redundant removal attempt in `finishSyncWindow`).
    @MainActor
    private func clearSuspectedId(_ notificationId: NotificationId, for device: Device) {
        guard case .verifying(var suspectedStaleIds, let receivedIds) = state.syncPhase[device.id] else { return }
        if suspectedStaleIds.remove(notificationId) != nil {
            state.syncPhase[device.id] = .verifying(suspectedStaleIds: suspectedStaleIds, receivedIds: receivedIds)
            Logger.services.debug("Cleared \(notificationId, privacy: .public) from suspected-stale set (explicit isCancel during verification)")
        }
    }
    
    /// Finishes the sync window for a device. Behavior depends on the current `SyncPhase`.
    ///
    /// ## `.syncing` phase (first pass)
    /// Computes `suspectedStaleIds = localIds - receivedIds`.
    /// - If empty: all local notifications confirmed alive → transition to idle.
    /// - If non-empty: suspected notifications may be stale OR Android simply didn't include
    ///   them in this batch (its `NotificationListenerService.getActiveNotifications()` response
    ///   is not guaranteed to be complete). Transition to `.verifying` and send a second
    ///   `notification.request` to confirm.
    /// - If zero IDs were received: non-authoritative → skip stale removal entirely.
    ///
    /// ## `.verifying` phase (second pass)
    /// Checks suspected IDs against the second response.
    /// - IDs that appeared in the verification window: confirmed alive, keep them.
    /// - IDs still absent after two consecutive requests: confirmed stale, remove them.
    /// - If zero IDs were received during verification: non-authoritative → keep all suspects.
    ///
    /// This two-pass approach intentionally favors false negatives (keeping a stale notification
    /// slightly longer) over false positives (incorrectly deleting a still-valid notification).
    /// Truly dismissed notifications will be consistently absent across both requests.
    ///
    /// NOTE: KDE Connect does not provide an authoritative or complete notification snapshot.
    /// There is no explicit end-of-list marker or completeness guarantee.
    /// Stale removal performed here is therefore best-effort and heuristic-based.
    @MainActor
    private func finishSyncWindow(for device: Device) async {
        guard let phase = state.syncPhase[device.id] else { return }
        state.debounceTasks[device.id]?.cancel()
        state.debounceTasks.removeValue(forKey: device.id)
        
        switch phase {
        case .preparing:
            // Should not happen — startSyncWindow transitions away from .preparing.
            // But if it does, just clean up.
            Logger.services.debug("finishSyncWindow called during .preparing for \(device.name, privacy: .public); ignoring")
            return
            
        case .syncing(let receivedIds):
            await finishInitialSync(for: device, receivedIds: receivedIds)
            
        case .verifying(let suspectedStaleIds, let receivedIds):
            await finishVerification(for: device, suspectedStaleIds: suspectedStaleIds, receivedIds: receivedIds)
        }
    }
    
    /// Handles completion of the initial `.syncing` phase.
    @MainActor
    private func finishInitialSync(for device: Device, receivedIds: Set<NotificationId>) async {
        guard let localIds = state.notificationIds[device.id] else {
            Logger.services.debug("Sync [initial] for \(device.name, privacy: .public): no local notifications to reconcile")
            state.syncPhase.removeValue(forKey: device.id)
            return
        }
        
        // If we didn't receive any notification IDs, the response was non-authoritative
        guard !receivedIds.isEmpty else {
            Logger.services.debug("Sync [initial] for \(device.name, privacy: .public): no notification packets received; skipping stale removal")
            state.syncPhase.removeValue(forKey: device.id)
            return
        }
        
        let suspectedStaleIds = localIds.subtracting(receivedIds)
        
        if suspectedStaleIds.isEmpty {
            Logger.services.debug("Sync [initial] for \(device.name, privacy: .public): all \(localIds.count, privacy: .public) local notifications confirmed alive (received \(receivedIds.count, privacy: .public))")
            state.syncPhase.removeValue(forKey: device.id)
            return
        }
        
        // Suspected stale IDs found — transition to verification phase
        Logger.services.debug("Sync [initial] for \(device.name, privacy: .public): \(suspectedStaleIds.count, privacy: .public) suspected stale (received \(receivedIds.count, privacy: .public) of \(localIds.count, privacy: .public) local); sending verification request")
        
        state.syncPhase[device.id] = .verifying(suspectedStaleIds: suspectedStaleIds, receivedIds: [])
        
        // Start verification timeout and send second request
        let task = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: UInt64(initialSyncTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await finishSyncWindow(for: device)
        }
        state.debounceTasks[device.id] = task
        device.send(DataPacket.notificationRequestPacket())
    }
    
    /// Handles completion of the `.verifying` phase.
    @MainActor
    private func finishVerification(for device: Device, suspectedStaleIds: Set<NotificationId>, receivedIds: Set<NotificationId>) async {
        // Always transition to idle after verification, regardless of outcome
        state.syncPhase.removeValue(forKey: device.id)
        
        // If zero IDs received during verification, the response was non-authoritative
        guard !receivedIds.isEmpty else {
            Logger.services.debug("Sync [verification] for \(device.name, privacy: .public): no notification packets received during verification; keeping all \(suspectedStaleIds.count, privacy: .public) suspects")
            return
        }
        
        // IDs that appeared in the verification window are confirmed alive
        let confirmedStaleIds = suspectedStaleIds.subtracting(receivedIds)
        let confirmedAliveIds = suspectedStaleIds.intersection(receivedIds)
        
        if !confirmedAliveIds.isEmpty {
            Logger.services.debug("Sync [verification] for \(device.name, privacy: .public): \(confirmedAliveIds.count, privacy: .public) suspected notifications confirmed alive")
        }
        
        if confirmedStaleIds.isEmpty {
            Logger.services.debug("Sync [verification] for \(device.name, privacy: .public): all suspected notifications confirmed alive; no removals")
            return
        }
        
        Logger.services.debug("Sync [verification] for \(device.name, privacy: .public): removing \(confirmedStaleIds.count, privacy: .public) confirmed-stale notifications")
        let deliveredByIdentifier = Dictionary(uniqueKeysWithValues: (await un.deliveredNotifications()).map { ($0.request.identifier, $0.request.content) })
        
        for staleId in confirmedStaleIds {
            let remotePacketId = packetNotificationId(from: staleId, for: device)
            if let content = deliveredByIdentifier[staleId] {
                let bodyPreview = String(content.body.prefix(180))
                Logger.services.debug(
                    "Removing confirmed-stale notification for \(device.name, privacy: .public): localId=\(staleId, privacy: .public), remoteId=\(remotePacketId, privacy: .public), title=\(content.title, privacy: .public), subtitle=\(content.subtitle, privacy: .public), bodyPreview=\(bodyPreview, privacy: .public)"
                )
            } else {
                Logger.services.debug(
                    "Removing confirmed-stale notification for \(device.name, privacy: .public): localId=\(staleId, privacy: .public), remoteId=\(remotePacketId, privacy: .public), deliveredMetadata=missing"
                )
            }
            /// NOTE: KDE Connect does NOT send download Task payload on subsequent requests, hence we'll take a conservative approach and keep our icon caches
            await hideNotification(for: staleId, from: device)
        }
    }
}


// MARK: - DataPacket (Notifications)

/// Notifications service data packet utilities
fileprivate extension DataPacket {
    
    // MARK: Types
    
    enum NotificationError: Error {
        case wrongType
        case invalidRequest
        case invalidCancelRequest
        case invalidReplyIdRequest
        case invalidId
        case invalidAppName
        case invalidGroupName
        case invalidTitle
        case invalidConversation
        case invalidText
        case invalidTicker
        case invalidActions
        case invalidClearableFlag
        case invalidCancelFlag
        case invalidSilentFlag
        case invalidPayloadHash
        case partFileRenameFailed
        case copyFileFailed
    }
    
    enum NotificationProperty: String {
        // all notifications request properties
        case request = "request"             /// (boolean): True if we are requesting for current notifications
        // cancel request properties (to notification originating device)
        case cancel = "cancel"               /// (string): An id of notification to be canceled on originating device
        // action request properties (to notification originating device)
        case key = "key"                     /// (string): An id of notification to request action to be performed on originating device
        case action = "action"               /// (string): The action request to be performed on originating device
        // reply request properties (to notification originating device)
        case requestReplyId = "requestReplyId"
        case message = "message"
        // notification info properties (from notification originating device)
        case id = "id"                       /// (string): A unique notification id.
        case appName = "appName"             /// (string): The app that generated the notification
        case title = "title"                 /// (string): The notification title (e.g., sender name in messaging apps)
        case text = "text"                   /// (string): The full notification body text (may contain newlines for message history)
        case groupName = "groupName"         /// (string): The group name if the notification is a group conversation message
        case ticker = "ticker"               /// (string): The notification summary
        case conversation = "conversation"   /// (array): List of {sender, content} messages if the notification is a conversation
        case actions = "actions"             /// (string array): The available actions of the notification.
        case isClearable = "isClearable"     /// (boolean): True if we can request to dismiss the notification.
        case isCancel = "isCancel"           /// (boolean): True if the notification was dismissed in the peer device.
        case silent = "silent"               /// (boolean): True if this notification should be silent.
        case payloadHash = "payloadHash"     /// (string): The hash of the payload
    }
    
    /// Represents a single message in a conversation notification.
    struct ConversationMessage {
        let sender: String
        let content: String
    }
    
    
    // MARK: Properties
    
    static let notificationPacketType = "kdeconnect.notification"
    static let notificationRequestPacketType = "kdeconnect.notification.request"
    static let notificationReplyPacketType = "kdeconnect.notification.reply"
    static let notificationActionPackageType = "kdeconnect.notification.action"
    
    var isNotificationPacket: Bool { return self.type == DataPacket.notificationPacketType }
    var isNotificationRequestPacket: Bool { return self.type == DataPacket.notificationRequestPacketType }
    var isNotificationActionPacket: Bool { return self.type == DataPacket.notificationActionPackageType }
    
    
    // MARK: Public static methods
    
    static func notificationRequestPacket() -> DataPacket {
        return DataPacket(type: notificationRequestPacketType, body: [
            NotificationProperty.request.rawValue: NSNumber(value: true)
        ])
    }
    
    static func notificationCancelPacket(forId id: String) -> DataPacket {
        return DataPacket(type: notificationRequestPacketType, body: [
            NotificationProperty.cancel.rawValue: id as AnyObject
        ])
    }
    
    static func notificationReplyPacket(forId uuid: String, message: String) -> DataPacket {
        return DataPacket(type: notificationReplyPacketType, body: [NotificationProperty.requestReplyId.rawValue: uuid as AnyObject, NotificationProperty.message.rawValue: message as AnyObject])
    }
    
    static func notificationActionPacket(forAction action: String, forKey key: String) -> DataPacket {
        return DataPacket(type: notificationActionPackageType, body: [NotificationProperty.action.rawValue: action as AnyObject, NotificationProperty.key.rawValue: key as AnyObject])
    }
    
    
    // MARK: Public methods
    
    func getRequestFlag() throws -> Bool {
        try self.validateNotificationType()
        guard body.keys.contains(NotificationProperty.request.rawValue) else { return false }
        guard let value = body[NotificationProperty.request.rawValue] as? NSNumber else { throw NotificationError.invalidRequest }
        return value.boolValue
    }
    
    func getCancelRequest() throws -> String? {
        try self.validateNotificationType()
        guard body.keys.contains(NotificationProperty.cancel.rawValue) else { return nil }
        guard let value = body[NotificationProperty.cancel.rawValue] as? String else { throw NotificationError.invalidCancelRequest }
        return value
    }
    
    func getReplyRequestId() throws -> String? {
        try self.validateNotificationType()
        guard body.keys.contains(NotificationProperty.requestReplyId.rawValue) else { return nil }
        guard let value = body[NotificationProperty.requestReplyId.rawValue] as? String else { throw NotificationError.invalidReplyIdRequest }
        return value
    }
    
    func getId() throws -> String? {
        try self.validateNotificationType()
        guard body.keys.contains(NotificationProperty.id.rawValue) else { return nil }
        guard let value = body[NotificationProperty.id.rawValue] as? String else { throw NotificationError.invalidId }
        return value
    }
    
    func getAppName() throws -> String? {
        try self.validateNotificationType()
        guard body.keys.contains(NotificationProperty.appName.rawValue) else { return nil }
        guard let value = body[NotificationProperty.appName.rawValue] as? String else { throw NotificationError.invalidAppName }
        return value
    }
    
    /// Gets the group name for group conversation notifications (e.g., a Signal group chat name).
    func getGroupName() throws -> String? {
        try self.validateNotificationType()
        guard body.keys.contains(NotificationProperty.groupName.rawValue) else { return nil }
        guard let value = body[NotificationProperty.groupName.rawValue] as? String else { throw NotificationError.invalidGroupName }
        return value.isEmpty ? nil : value
    }
    
    /// Gets the conversation message history from messaging-style notifications.
    /// Returns nil if the field is absent. Messages with missing sender or content are skipped.
    func getConversation() throws -> [ConversationMessage]? {
        try self.validateNotificationType()
        guard body.keys.contains(NotificationProperty.conversation.rawValue) else { return nil }
        guard let array = body[NotificationProperty.conversation.rawValue] as? [[String: Any]] else { throw NotificationError.invalidConversation }
        
        var messages: [ConversationMessage] = []
        for obj in array {
            guard let sender = obj["sender"] as? String, let content = obj["content"] as? String else { continue }
            messages.append(ConversationMessage(sender: sender, content: content))
        }
        return messages
    }
    
    /// Gets the notification ticker (a brief summary, e.g., "Sender: message")
    func getTicker() throws -> String? {
        try self.validateNotificationType()
        guard body.keys.contains(NotificationProperty.ticker.rawValue) else { return nil }
        guard let value = body[NotificationProperty.ticker.rawValue] as? String else { throw NotificationError.invalidTicker }
        return value
    }
    
    /// Gets the notification title (e.g., sender name in messaging apps or headline in non-messaging apps)
    func getTitle() throws -> String? {
        try self.validateNotificationType()
        guard body.keys.contains(NotificationProperty.title.rawValue) else { return nil }
        guard let value = body[NotificationProperty.title.rawValue] as? String else { throw NotificationError.invalidTitle }
        return value
    }
    
    /// Gets the full notification body text (may contain newlines for message history)
    func getText() throws -> String? {
        try self.validateNotificationType()
        guard body.keys.contains(NotificationProperty.text.rawValue) else { return nil }
        guard let value = body[NotificationProperty.text.rawValue] as? String else { throw NotificationError.invalidText }
        return value
    }
    
    /// Gets the available actions of the notification.
    /// - Returns: An array of action strings, or nil if no actions are present.
    /// - Throws: `NotificationError.invalidActions` if the actions property is present but not in the expected format.
    func getActions() throws -> [String]? {
        try self.validateNotificationType()
        guard body.keys.contains(NotificationProperty.actions.rawValue) else { return nil }
        guard let value = body[NotificationProperty.actions.rawValue] as? [String] else { throw NotificationError.invalidActions }
        return value
    }
    
    func getClearableFlag() throws -> Bool {
        try self.validateNotificationType()
        guard body.keys.contains(NotificationProperty.isClearable.rawValue) else { return false }
        guard let value = body[NotificationProperty.isClearable.rawValue] as? NSNumber else { throw NotificationError.invalidClearableFlag }
        return value.boolValue
    }
    
    func getCancelFlag() throws -> Bool {
        try self.validateNotificationType()
        guard body.keys.contains(NotificationProperty.isCancel.rawValue) else { return false }
        guard let value = body[NotificationProperty.isCancel.rawValue] as? NSNumber else { throw NotificationError.invalidCancelFlag }
        return value.boolValue
    }
    
    func getSilentFlag() throws -> Bool {
        try self.validateNotificationType()
        guard body.keys.contains(NotificationProperty.silent.rawValue) else { return false }
        guard let value = body[NotificationProperty.silent.rawValue] as? NSNumber else { throw NotificationError.invalidSilentFlag }
        return value.boolValue
    }
    
    func getPayloadHash() throws -> String? {
        try self.validateNotificationType()
        guard body.keys.contains(NotificationProperty.payloadHash.rawValue) else { return nil }
        guard let value = body[NotificationProperty.payloadHash.rawValue] as? String else { throw NotificationError.invalidPayloadHash }
        return value
    }
    
    func validateNotificationType() throws {
        guard self.isNotificationPacket else { throw NotificationError.wrongType }
    }
}
