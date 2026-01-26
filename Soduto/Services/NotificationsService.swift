//
//  NotificationsService.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-11-26.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation
import Cocoa
import CleanroomLogger
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
/// "appName" (string): The app that generated the notification
/// "ticker" (string): The title or headline of the notification.
/// "isClearable" (boolean): True if we can request to dismiss the notification.
/// "isCancel" (boolean): True if the notification was dismissed in the peer device.
/// "requestAnswer" (boolean): True if this is an answer to a "request" package.
///
/// Additionally the package can contain a payload with the icon of the notification
/// in PNG format.
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
    
    let un = UNUserNotificationCenter.current()
    
    // MARK: Types
    
    public typealias NotificationId = String
    
    enum UserInfoProperty: String {
        case deviceId = "com.soduto.services.notifications.deviceId"
        case notificationId = "com.soduto.services.notifications.notificationId"
        case requestReplyId = "com.soduto.services.notifications.requestReplyId"
        case isCancelable = "com.soduto.services.notifications.isCancelable"
        case dontPresent = "com.soduto.services.notifications.dontPresent"
    }
    
    enum ActionId: ServiceAction.Id {
        case refresh
    }

    private struct DownloadInfo {
        let task: DownloadTask
        let fileHash: String?
        let notificationId: String
        let partFileURL: URL
        let dataPacket: DataPacket
        let device: Device
        init(task: DownloadTask, fileHash:String?, notificationId: String, partFileURL: URL, dataPacket: DataPacket, device: Device) {
            self.task = task
            self.fileHash = fileHash
            self.notificationId = notificationId
            self.partFileURL = partFileURL
            self.dataPacket = dataPacket
            self.device = device
        }
    }
    
    
    // MARK: Service properties
    
    public static let serviceId: Service.Id = "com.soduto.services.notifications"
    
    public let incomingCapabilities = Set<Service.Capability>([ DataPacket.notificationPacketType ])
    public let outgoingCapabilities = Set<Service.Capability>([ DataPacket.notificationPacketType ])
    
    private var notificationIconDownloadInfos: [DownloadInfo] = []
    private var downloadedNotificationIconFileURLByNotificationId: [String: URL] = [:]
    private var cachedDownloadedNotificationIconFileURLByHash: [String: URL] = [:]

    /// Delivered notification ids grouped by device
    private var notificationIds: [Device.Id: Set<NotificationId>] = [:]
    
    /// Tracks the last known content hash for each notification to detect true updates vs reconnection duplicates
    /// Key: notificationId, Value: hash of body/ticker content
    private var notificationContentHashes: [NotificationId: Int] = [:]
    
    /// Flag to ensure startup cleanup only runs once per app session (static, process-wide)
    private static var hasPerformedStartupCleanup = false
    
    /// Tracks notification IDs received during a sync window (after a notification request), grouped by device.
    /// Used to detect notifications that were dismissed on the remote device while disconnected.
    private var pendingSyncReceivedIds: [Device.Id: Set<NotificationId>] = [:]
    
    /// Timers for post-sync reconciliation, keyed by device ID.
    private var syncReconciliationTimers: [Device.Id: Timer] = [:]
    
    /// Time to wait for the first notification packet before assuming the device has no notifications.
    private let initialSyncTimeout: TimeInterval = 3.5
    
    /// Time to wait after the last received notification packet before reconciling.
    /// This acts as a debounce to ensure we received the full batch of notifications even on slow networks.
    private let syncDebounceTimeout: TimeInterval = 2.0
    
    // MARK: Service methods
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        
        guard dataPacket.isNotificationPacket else { return false }
        
        // Log the raw packet (enable only when debugging, as logs may leak sensitive info)
        //Log.debug?.message("NotificationsService received packet: \(dataPacket.body)")
        
        if (try? dataPacket.getRequestFlag()) ?? false {
            // Doing nothing as we dont (at least currently) provide our own notifications to other devices
        }
        else if (try? dataPacket.getCancelFlag()) ?? false {
            self.hideNotification(for: dataPacket, from: device)
        }
        else {
            do {
                let id = try dataPacket.getId() ?? nil
                if (id != nil && dataPacket.downloadTask != nil) {
                    let iconDownloadTask = dataPacket.downloadTask
                    self.startIconDownloadTaskAndShowNotification(downloadTask: iconDownloadTask!, notificationId: id!, dataPacket: dataPacket, device: device)
                }
                else {
                    // No download task - try to find cached icon
                    if let id = id {
                        // First, try by payload hash (if the packet includes it)
                        if let payloadHash = try? dataPacket.getPayloadHash(),
                           let cachedIconURL = self.cachedDownloadedNotificationIconFileURLByHash[payloadHash] {
                            Log.debug?.message("Using cached icon for notification \(id) with hash \(payloadHash)")
                            do {
                                let copiedFromCacheFileURL = try self.copyFileFromCache(url: cachedIconURL, notificationId: id)
                                self.downloadedNotificationIconFileURLByNotificationId[id] = copiedFromCacheFileURL
                            } catch {
                                Log.error?.message("Failed to copy cached icon: \(error.localizedDescription)")
                            }
                        }
                        // Second, check if we already have a downloaded icon for this notification ID
                        else if self.downloadedNotificationIconFileURLByNotificationId[id] != nil {
                            Log.debug?.message("Icon already available for notification \(id)")
                        }
                        else {
                            Log.debug?.message("No icon available for notification \(id) - no downloadTask, no payloadHash match, no cached icon")
                        }
                    }
                    
                    self.showNotification(for: dataPacket, from: device)
                }
            }
            catch {
                self.showNotification(for: dataPacket, from: device)
            }
        }
        
        return true
    }
    
    /// Called when a device connects. Requests all current notifications from the device.
    /// TODO: Verify if existing notifications are send continuously, then comment out the codeblock inside this function.
    ///
    /// Duplicate alerts are prevented by:
    /// - `isAlreadyDisplayed` check: Notifications already in `notificationIds` are skipped entirely
    ///   if their content hash is unchanged (reconnection scenario), preventing unnecessary refreshes when the
    ///   device momentarily reconnects (e.g., WiFi change, charging starts)
    ///
    /// On app startup, `notificationIds` is empty, so we first repopulate it from the
    /// Notification Center's delivered notifications before requesting new ones.
    public func setup(for device: Device) {
        guard device.incomingCapabilities.contains(DataPacket.notificationPacketType) else { return }
        
        // Clean up stale icon files from previous app sessions (once per app launch, process-wide)
        if !Self.hasPerformedStartupCleanup {
            Self.hasPerformedStartupCleanup = true
            cleanupStaleIconFiles()
        }
        
        /// First reconcile to remove any stale entries for notifications dismissed via macOS UI,
        /// then repopulate from delivered notifications to restore state after app restart.
        /// This ensures that on app restart, we don't re-alert for already-displayed notifications.
        reconcileNotificationState { [weak self] in
            self?.repopulateNotificationIds(for: device) {
                // Start sync window: track received notification IDs for this device
                self?.startSyncWindow(for: device)
                device.send(DataPacket.notificationRequestPacket())
            }
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
        Log.debug?.message("Ignoring cleanup for \(device.name); waiting for reconciliation and reconnection...")
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
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device) {
        guard let actionId = ActionId(rawValue: id) else { return }
        guard device.pairingStatus == .Paired else { return }
        
        switch actionId {
        case .refresh:
            // Reconcile state first to clean up any notifications dismissed via macOS UI
            reconcileNotificationState { [weak self] in
                guard self != nil else { return }
                device.send(DataPacket.notificationRequestPacket())
            }
        }
    }
    
    // MARK: DownloadTaskDelegate
    
    public func downloadTask(_ task: DownloadTask, finishedWithSuccess success: Bool) {
        Log.debug?.message("downloadTask(<\(task)> finishedWithSuccess:<\(success)>)")
        
        guard let index = self.notificationIconDownloadInfos.firstIndex(where: { $0.task === task }) else { return }
        let info = self.notificationIconDownloadInfos.remove(at: index)
        if success {
            do {
                // Sanitize the notification ID for use in filename (remove |, :, etc.)
                let safeFileName = sanitizeForFilename(info.notificationId) + ".png"
                let finalFileURL = try self.renamePartFile(url: info.partFileURL, to: safeFileName)
                Log.debug?.message("downloadTask saving icon to: \(finalFileURL.path)")
                Log.debug?.message("Notification id: \(info.notificationId)")
                self.downloadedNotificationIconFileURLByNotificationId[info.notificationId] = finalFileURL
                if (info.fileHash != nil && self.cachedDownloadedNotificationIconFileURLByHash[info.fileHash!] == nil) {
                    let cachedFileURL = try self.copyFileToCache(url: finalFileURL, hash: info.fileHash!)
                    self.cachedDownloadedNotificationIconFileURLByHash[info.fileHash!] = cachedFileURL
                    Log.debug?.message("New icon found with hash \(info.fileHash!), saving to cached icons as \(cachedFileURL)")
                }
            }
            catch let error {
                Log.error?.message("Failed to process downloaded icon for \(info.notificationId): \(error)")
            }
        }
        self.showNotification(for: info.dataPacket, from: info.device)
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
    /// - **Default (body click)**: Ignored - notification remains visible
    public static func handleAction(for response: UNNotificationResponse, context: UserNotificationContext) {
        let userInfo = response.notification.request.content.userInfo
        
        // Clicking the notification body should do nothing - the notification stays visible.
        // Users must use the explicit "Dismiss" button to dismiss on both macOS and Android.
        // See the Dismiss Philosophy documentation above.
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
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
                    Log.debug?.message("Empty reply message ignored for notification \(notificationId)")
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
            notificationsService.removeNotificationId(notificationId, from: device)
        }
    }
    
    //MARK: Custom Notification Push method
    
    /// Displays a custom notification to the user.
    /// - Parameters:
    ///   - title: The title of the notification.
    ///   - subtitle: The subtitle of the notification (optional).
    ///   - body: The body text of the notification.
    ///   - sound: Whether to play a sound with the notification.
    ///   - id: The unique identifier for the notification.
    ///   - urgency: The urgency level for the notification (default: .active).
    public func ShowCustomNotification(title: String, subtitle: String? = nil, body: String, sound: Bool, id: String, urgency: UNMutableNotificationContent.NotificationUrgency? = .active) {
        let notification = UNMutableNotificationContent()
        notification.title = title
        if let subtitle = subtitle {
            notification.subtitle = subtitle
        }
        notification.body = body
        if sound {
            notification.sound = UNNotificationSound.default
        }
        if let urgency = urgency {
            notification.setUrgency(urgency)
        }
        let request = UNNotificationRequest(identifier: id, content: notification, trigger: nil)
        un.add(request) { error in
            if let error = error {
                Log.error?.message("Failed to add UNNotificationRequest for custom notification id \(id): \(error)")
            }
        }
    }
    
    
    // MARK: Public methods
    
    /// Requests all current notifications from all connected devices.
    /// This clears local notification state and re-fetches everything.
    public func refreshNotifications() {
        let devices = AppDelegate.shared().validDevices
        
        self.notificationIds.removeAll()
        self.notificationContentHashes.removeAll()
        un.removeAllDeliveredNotifications()
        un.removeAllPendingNotificationRequests()
        
        // Request notifications from each device
        for device in devices {
            guard device.incomingCapabilities.contains(DataPacket.notificationRequestPacketType) else { continue }
            device.send(DataPacket.notificationRequestPacket())
        }
    }
    
    
    // MARK: Private methods
    
    private func notificationId(for dataPacket: DataPacket, from device: Device) -> NotificationId? {
        assert(dataPacket.isNotificationPacket, "Expected notification data packet")
        
        guard let deviceId = device.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        guard let packetId = (try? dataPacket.getId())??.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        
        return "\(self.id).\(deviceId).\(packetId)"
    }
    
    /// Sanitizes a string to be safe for use in filenames by replacing invalid characters.
    /// macOS doesn't allow: / : in filenames. We also replace | and other problematic chars.
    private func sanitizeForFilename(_ string: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:|\\<>\"?*")
        return string.components(separatedBy: invalidCharacters).joined(separator: "_")
    }
    
    /// Repopulates the `notificationIds` dictionary from the Notification Center's delivered notifications.
    /// This is necessary because `notificationIds` is in-memory and lost on app restart.
    /// - Parameters:
    ///   - device: The device to repopulate notification IDs for.
    ///   - completion: Called after repopulation is complete.
    private func repopulateNotificationIds(for device: Device, completion: @escaping () -> Void) {
        // If we already have IDs for this device, skip repopulation
        if notificationIds[device.id] != nil && !notificationIds[device.id]!.isEmpty {
            Log.debug?.message("Skipping repopulation for \(device.name) - already have \(notificationIds[device.id]!.count) IDs")
            completion()
            return
        }
        
        guard let deviceIdEncoded = device.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            Log.error?.message("Failed to encode device ID for \(device.name)")
            completion()
            return
        }
        
        // Build the prefix we use for this device's notifications
        let prefix = "\(self.id).\(deviceIdEncoded)."
        
        un.getDeliveredNotifications { [weak self] notifications in
            DispatchQueue.main.async {
                guard let self = self else {
                    completion()
                    return
                }
                
                var matchCount = 0
                for notification in notifications {
                    let identifier = notification.request.identifier
                    // Check if this notification belongs to this service and device
                    if identifier.hasPrefix(prefix) {
                        self.addNotificationId(identifier, from: device)
                        // Also restore the content hash so we can detect reconnection duplicates
                        let body = notification.request.content.body
                        self.notificationContentHashes[identifier] = body.hashValue
                        matchCount += 1
                    }
                }
                
                if matchCount > 0 {
                    Log.debug?.message("Repopulated \(matchCount) notification IDs for device \(device.name)")
                }
                
                completion()
            }
        }
    }
    
    /// Reconciles the in-memory `notificationIds` and `notificationContentHashes` with what's actually
    /// in the Notification Center. This handles the case where users dismissed notifications via
    /// macOS's native UI (swipe, X button, or clearing from Notification Center) without using our
    /// "Dismiss" action button.
    ///
    /// Call this at key moments like refresh or before requesting new notifications.
    ///
    /// - Parameter completion: Called after reconciliation is complete.
    private func reconcileNotificationState(completion: @escaping () -> Void) {
        let prefix = "\(self.id)."
        
        un.getDeliveredNotifications { [weak self] deliveredNotifications in
            DispatchQueue.main.async {
                guard let self = self else {
                    completion()
                    return
                }
                
                // Build a set of all notification IDs currently in Notification Center
                let deliveredIds = Set(deliveredNotifications.map { $0.request.identifier })
                
                var removedCount = 0
                
                // For each device, remove any tracked IDs that are no longer delivered
                for (deviceId, trackedIds) in self.notificationIds {
                    let stale = trackedIds.filter { $0.hasPrefix(prefix) && !deliveredIds.contains($0) }
                    for trackedId in stale {
                        // NOTE: DO NOT clean up icon files HERE, because they are cached for the very reason
                        // that KDE Connect does NOT send download Tasks on subsequent requests
                        self.notificationIds[deviceId]?.remove(trackedId)
                        self.notificationContentHashes.removeValue(forKey: trackedId)
                    }
                    removedCount += stale.count
                }
                
                if removedCount > 0 {
                    Log.debug?.message("Reconciled notification state: removed \(removedCount) stale entries")
                }
                
                completion()
            }
        }
    }
    
    private func startIconDownloadTaskAndShowNotification(downloadTask task: DownloadTask, notificationId: String, dataPacket: DataPacket, device: Device) {
        var downloadFileHash: String? = nil
        do {
            downloadFileHash = try dataPacket.getPayloadHash()
        }
        catch {}
        if (downloadFileHash != nil && cachedDownloadedNotificationIconFileURLByHash[downloadFileHash!] != nil) {
            Log.debug?.message("Found cached icon for hash \(downloadFileHash!) at \(cachedDownloadedNotificationIconFileURLByHash[downloadFileHash!]!)")
            do {
                let copiedFromCacheFileURL = try self.copyFileFromCache(url: cachedDownloadedNotificationIconFileURLByHash[downloadFileHash!]!, notificationId: notificationId)
                self.downloadedNotificationIconFileURLByNotificationId[notificationId] = copiedFromCacheFileURL
            }
            catch let error {
                Log.error?.message("Failed to copy cached icon for \(notificationId): \(error)")
            }
            self.showNotification(for: dataPacket, from: device)
        } else {
            if let (readyStream, partFileURL) = self.streamForTempDownload() {
                self.notificationIconDownloadInfos.append(DownloadInfo(
                    task: task,
                    fileHash: downloadFileHash,
                    notificationId: notificationId,
                    partFileURL: partFileURL,
                    dataPacket: dataPacket,
                    device: device
                ))
                task.delegate = self
                task.start(withStream: readyStream)
            }
        }
    }
    
    private func streamForTempDownload() -> (OutputStream, URL)? {
        let temporaryDirectory = NSTemporaryDirectory()
        let randomUuidForFileName = "\(UUID().uuidString)"
        let tempFileURL = URL(fileURLWithPath: randomUuidForFileName, relativeTo: URL(fileURLWithPath: temporaryDirectory, isDirectory: true))
        // Try open stream for new file. Try alternative names on fail
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
        
        // Last attempt with completely random extension
        if stream == nil {
            partFileURL = tempFileURL.appendingPathExtension("part-\(UUID().uuidString)")
            if !FileManager.default.fileExists(atPath: partFileURL.path) {
                stream = OutputStream(url: partFileURL, append: false)
                stream?.open()
            }
        }
        
        if let readyStream = stream, (stream?.hasSpaceAvailable ?? false) {
            return (readyStream, partFileURL)
        }
        else {
            stream?.close()
            return nil
        }
    }

    private func renamePartFile(url partFileURL: URL, to fileName: String) throws -> URL {
        // Try rename file from temporary *.part name to final path based on original file name
        // NOTE: *.part name might not necesarily be equal to filename with appended .part suffix
        var finalFileURL = partFileURL.deletingLastPathComponent().appendingPathComponent(fileName)
        for _ in 1...10000 {
            if !FileManager.default.fileExists(atPath: finalFileURL.path) {
                do {
                    try FileManager.default.moveItem(at: partFileURL, to: finalFileURL)
                    return finalFileURL
                }
                catch {}
            }
            finalFileURL = finalFileURL.alternativeForDuplicate()
        }
        
        throw DataPacket.NotificationError.partFileRenameFailed
    }

    private func copyFileToCache(url fileURL: URL, hash fileHash: String) throws -> URL {
        let finalFileURL = fileURL.deletingLastPathComponent().appendingPathComponent("\(fileHash).png.cache")
        for _ in 1...10000 {
            if !FileManager.default.fileExists(atPath: finalFileURL.path) {
                do {
                    try FileManager.default.copyItem(at: fileURL, to: finalFileURL)
                    return finalFileURL
                }
                catch {}
            }
        }
        
        throw DataPacket.NotificationError.copyFileFailed
    }

    private func copyFileFromCache(url fileURL: URL, notificationId fileNotificationId: String) throws -> URL {
        // Sanitize the notification ID for use in filename
        let safeFileName = sanitizeForFilename(fileNotificationId) + ".png"
        let finalFileURL = fileURL.deletingLastPathComponent().appendingPathComponent(safeFileName)
        for _ in 1...10000 {
            if !FileManager.default.fileExists(atPath: finalFileURL.path) {
                do {
                    try FileManager.default.copyItem(at: fileURL, to: finalFileURL)
                    return finalFileURL
                }
                catch {}
            }
        }
        
        throw DataPacket.NotificationError.copyFileFailed
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
    private func cleanupStaleIconFiles() {
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
                Log.debug?.message("Cleaned up \(cleanedCount) stale notification icon files from temp directory")
            }
        } catch {
            Log.error?.message("Failed to enumerate temp directory for icon cleanup: \(error)")
        }
    }

    private func buildNotificationContent(
        for dataPacket: DataPacket,
        from device: Device,
        with notificationId: String,
        isSilent: Bool,
        dontPresent: Bool,
        title: String?,
        body: String?,
        ticker: String,
        appName: String,
        replyId: String?,
        isCancelable: Bool,
        actions: [String]?
    ) -> UNMutableNotificationContent {
        let notification = UNMutableNotificationContent()
        
        /// Filter actions - exclude copy OTP actions, "Reply" actions (handled separately via requestReplyId), and limit to max 3
        var filteredActions: [String] = []
        if let actions = actions {
            for action in actions {
                // Don't show if there's a copy action from "Messages" app and instead copy it to clipboard automatically
                if action.hasPrefix("Copy \"") && action.hasSuffix("\"") && appName == "Messages" {
                    self.copyOTP(from: action) // Copy OTP to clipboard
                }
                // Skip "Reply" actions since we handle reply separately via requestReplyId
                else if action.lowercased() == "reply" {
                    continue
                }
                else {
                    filteredActions.append(action)
                }
            }
        }
        // Limit to max 3 custom actions (Android can show max 3)
        let actionCount = min(filteredActions.count, 3)
        
        let shouldMute = isSilent
        
        // Build userInfo with base properties
        var userInfo: [String: Any] = [
            UserInfoProperty.deviceId.rawValue: device.id,
            UserInfoProperty.notificationId.rawValue: notificationId,
            UserInfoProperty.requestReplyId.rawValue: replyId as Any,
            UserInfoProperty.isCancelable.rawValue: NSNumber(value: isCancelable),
            UserNotificationManager.Property.dontPresent.rawValue: NSNumber(value: dontPresent),
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
        
        notification.userInfo = userInfo
        notification.title = "\(appName) | \(device.name)"
        notification.subtitle = title ?? ""
        notification.body = body ?? ticker
        
        let hasReply = replyId != nil
        let actionTitles = Array(filteredActions.prefix(3))
        let categoryId = AppDelegate.shared().userNotificationManager.getOrCreateCategory(
            hasReply: hasReply,
            actionTitles: actionTitles
        )
        notification.categoryIdentifier = categoryId
        
        /// Only play sound if notification is not muted
        /// shouldMute is true for: silent notifications from android
        if !shouldMute {
            notification.sound = UNNotificationSound.default
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

    private func showNotification(for dataPacket: DataPacket, from device: Device) {
        // Should run on main thread to ensure thread safety for state dictionaries
        // (notificationIds, notificationContentHashes, downloadedNotificationIconFileURLByNotificationId)
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.showNotification(for: dataPacket, from: device)
            }
            return
        }

        assert(dataPacket.isNotificationPacket, "Expected notification data packet")

        do {
            guard let packetNotificationId = try dataPacket.getId() else {
                Log.debug?.message("Notification rejected: missing ID")
                return
            }
            guard let notificationId = self.notificationId(for: dataPacket, from: device) else {
                Log.debug?.message("Notification rejected: couldn't generate notificationId for packet \(packetNotificationId)")
                return
            }
            guard let appName = try dataPacket.getAppName() else {
                Log.debug?.message("Notification rejected: missing appName for \(packetNotificationId)")
                return
            }
            guard appName != "KDE Connect" else {
                Log.debug?.message("Notification rejected: from KDE Connect itself")
                return
            }
            guard let ticker = try dataPacket.getTicker() else {
                Log.debug?.message("Notification rejected: missing ticker for \(appName) - \(packetNotificationId)")
                return
            }
            
            let title = try dataPacket.getTitle()
            let body = try dataPacket.getText()            
            let replyId = try dataPacket.getReplyRequestId()
            let actions = try dataPacket.getActions()
            let isAnswer = try dataPacket.getAnswerFlag()
            let isSilent = try dataPacket.getSilentFlag()
            let isCancelable = try dataPacket.getClearableFlag()
            let isAlreadyDisplayed = self.notificationIds[device.id]?.contains(notificationId) ?? false
            
            // Compute content hash to detect if this is a true update (content changed) vs reconnection duplicate (same content)
            let contentForHash = body ?? ticker
            let currentContentHash = contentForHash.hashValue
            let previousContentHash = self.notificationContentHashes[notificationId]
            let isContentChanged = previousContentHash == nil || previousContentHash != currentContentHash
            
            // Update the stored content hash
            self.notificationContentHashes[notificationId] = currentContentHash
            
            /// isReconnectionDuplicate: Same notification with same content arriving again (e.g., after network change)
            /// This should be completely ignored - don't update Notification Center at all
            let isReconnectionDuplicate = isAlreadyDisplayed && !isContentChanged
            
            /// Record this notification as received during sync window (even if it's a reconnection duplicate).
            /// This ensures we don't incorrectly remove it as "stale" when the sync window finishes.
            self.recordReceivedNotificationId(notificationId, for: device)
            
            // Skip reconnection duplicates entirely - no need to update Notification Center
            if isReconnectionDuplicate {
                Log.debug?.message("Notification skipped (reconnection duplicate): \(appName) - \(packetNotificationId)")
                return
            }
            /// dontPresent: Don't show notification
            /// This applies to: answer packets (responses to our requests)
            let dontPresent = isAnswer

            var notificationIconURL: URL? = nil
            // Don't remove the icon URL - keep it for potential notification updates
            if let iconURL = self.downloadedNotificationIconFileURLByNotificationId[packetNotificationId] {
                notificationIconURL = iconURL
            }

            let notification = buildNotificationContent(
                for: dataPacket,
                from: device,
                with: notificationId,
                isSilent: isSilent,
                dontPresent: dontPresent,
                title: title,
                body: body,
                ticker: ticker,
                appName: appName,
                replyId: replyId,
                isCancelable: isCancelable,
                actions: actions
            )
            
            /// Set Notification App Icon
            /// UNNotificationAttachment MOVES the file to its data store, so we must copy it first to preserve the original for potential notification updates
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
                    Log.error?.message("Failed to create notification attachment: \(error.localizedDescription)")
                    // Clean up the temporary file if it was created but attachment failed
                    if let tempURL = tempCopyURL, FileManager.default.fileExists(atPath: tempURL.path) {
                        try? FileManager.default.removeItem(at: tempURL)
                    }
                    // Opportunistically cleanup icon file dictionary entry, if present
                    if let iconURL = self.downloadedNotificationIconFileURLByNotificationId.removeValue(forKey: packetNotificationId) {
                        Log.debug?.message("Removed icon file dictionary entry for failed notification attachment: \(packetNotificationId) at \(iconURL.path)")
                    }
                }
            }
            
            // Create notification request
            let request = UNNotificationRequest(identifier: notificationId, content: notification, trigger: nil)
            
            // Push Notification (categories are already registered at app startup)
            un.add(request) { error in
                if let error = error {
                    Log.error?.message("Failed to add UNNotificationRequest: \(error)")
                }
            }

            self.addNotificationId(notificationId, from: device)    /// Add the Notification ID to the `notificationIds` Dictionary
        }
        catch {
            Log.error?.message("Error while showing notification: \(error)")
        }
    }

    
    private func hideNotification(for dataPacket: DataPacket, from device: Device) {
        assert(dataPacket.isNotificationPacket, "Expected notification data packet")
        
        guard let id = self.notificationId(for: dataPacket, from: device) else { return }
        
        // Clean up downloaded icon file for this packet
        if let packetId = try? dataPacket.getId() {
            if let iconURL = self.downloadedNotificationIconFileURLByNotificationId.removeValue(forKey: packetId) {
                // Delete the actual icon file from disk
                do {
                    try FileManager.default.removeItem(at: iconURL)
                    Log.debug?.message("Deleted icon file for notification \(packetId) at \(iconURL.path)")
                } catch {
                    Log.error?.message("Failed to delete icon file for notification \(packetId): \(error)")
                }
            }
        }
        
        self.hideNotification(for: id, from: device)
    }
    
    private func hideNotification(for id: NotificationId, from device: Device) {
        un.removeNotification(withId: id)
        
        self.removeNotificationId(id, from: device)
        self.notificationContentHashes.removeValue(forKey: id)
    }
    
    private func addNotificationId(_ id: NotificationId, from device: Device) {
        // Ensure main thread for state mutation
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.addNotificationId(id, from: device)
            }
            return
        }
        
        if self.notificationIds[device.id] == nil {
            self.notificationIds[device.id] = Set<NotificationId>()
        }
        self.notificationIds[device.id]?.insert(id)
    }
    
    private func removeNotificationId(_ id: NotificationId, from device: Device) {
        // Ensure main thread for state mutation
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.removeNotificationId(id, from: device)
            }
            return
        }
        
        guard self.notificationIds[device.id] != nil else { return }
        _ = self.notificationIds[device.id]?.remove(id)
    }
    
    private func copyOTP(from string:String) {
        let prefixToRemove = "Copy \""
        let suffixToRemove = "\""
        let pattern = "[^0-9A-Za-z]" // Matches any character that is NOT a number or letter
        
        // Extract OTP
        let startIndex = string.index(string.startIndex, offsetBy: prefixToRemove.count)
        let endIndex = string.index(string.endIndex, offsetBy: -suffixToRemove.count)
        let slicedString = string[startIndex..<endIndex]
        
        let regex = try! NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(location: 0, length: slicedString.utf16.count)
        
        // Remove any non-alphanumeric character (like invisible unicode characters)
        let otp = regex.stringByReplacingMatches(in: String(slicedString), options: [], range: range, withTemplate: "")
        
        // Copy to clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(otp, forType: .string)
    }
    
    // MARK: Sync Window & Stale Notification Removal
    
    /// Starts a sync window for a device. During this window, all received notification IDs are tracked.
    /// After the window closes (timer fires), any local notification IDs not received are considered
    /// dismissed on the remote device and are removed from macOS.
    private func startSyncWindow(for device: Device) {
        DispatchQueue.main.async {
            self.syncReconciliationTimers[device.id]?.invalidate() // Cancel any existing timer for this device
            self.pendingSyncReceivedIds[device.id] = []  // Clear the set of received IDs for this device
            
            self.syncReconciliationTimers[device.id] = Timer.scheduledTimer(
                withTimeInterval: self.initialSyncTimeout, repeats: false) { [weak self] _ in
                    self?.finishSyncWindow(for: device)
            }
            Log.debug?.message("Started sync window for device \(device.name)")
        }
    }
    
    /// Called when a notification is received during a sync window. Adds the notification ID to the pending set.
    private func recordReceivedNotificationId(_ notificationId: NotificationId, for device: Device) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Only record if a sync window is active for this device
            guard self.pendingSyncReceivedIds[device.id] != nil else { return }
            self.pendingSyncReceivedIds[device.id]?.insert(notificationId)
            
            // Debounce: Reschedule the reconciliation timer to wait for end of stream
            // This prevents the window from closing while large batches of notifications are still arriving
            self.syncReconciliationTimers[device.id]?.invalidate()
            self.syncReconciliationTimers[device.id] = Timer.scheduledTimer(
                withTimeInterval: self.syncDebounceTimeout,
                repeats: false
            ) { [weak self] _ in
                self?.finishSyncWindow(for: device)
            }
        }
    }
    
    /// Finishes the sync window for a device. Removes any local notifications not received during the sync.
    /// NOTE: KDE Connect does not provide an authoritative or complete notification snapshot.
    /// There is no explicit end-of-list marker or completeness guarantee.
    /// Stale removal performed here is therefore best-effort and heuristic-based.
    ///
    /// In rare cases, notifications that still exist on the remote device may be removed locally, if they are not re-sent during the sync window.
    /// They will be re-added when the notification packet arrives later. This situation may arise in devices that delay sending notification packets, even after establishing connection.
    /// This behavior is an intentional trade-off to provide a cleaner and more seamless notification mirroring experience on macOS.
    /// TODO: Verify if existing notifications are send continuously, then comment out the `for loop` codeblock inside this function
    private func finishSyncWindow(for device: Device) {
        guard let receivedIds = pendingSyncReceivedIds.removeValue(forKey: device.id) else { return }
        syncReconciliationTimers.removeValue(forKey: device.id)
        
        guard let localIds = notificationIds[device.id] else {
            Log.debug?.message("Finished sync window for \(device.name): no local notifications to reconcile")
            return
        }
        
        // Find local notifications that were NOT received from the device (i.e., dismissed on remote)
        let staleIds = localIds.subtracting(receivedIds)
        
        if staleIds.isEmpty {
            Log.debug?.message("Finished sync window for \(device.name): all local notifications still exist on remote")
            return
        }
        
        Log.debug?.message("Finished sync window for \(device.name): removing \(staleIds.count) stale notifications")
        
        for staleId in staleIds {
            /// NOTE: KDE Connect does NOT send download Task payload on subsequent requests, hence we'll take a conservative approach
            /// and keep our icon caches
            hideNotification(for: staleId, from: device)
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
        case invalidTicker
        case invalidActions
        case invalidClearableFlag
        case invalidCancelFlag
        case invalidAnswerFlag
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
        case ticker = "ticker"               /// (string): The notification summary
        case actions = "actions"             /// (string array): The available actions of the notification.
        case isClearable = "isClearable"     /// (boolean): True if we can request to dismiss the notification.
        case isCancel = "isCancel"           /// (boolean): True if the notification was dismissed in the peer device.
        case requestAnswer = "requestAnswer" /// (boolean): True if this is an answer to a "request" package.
        case silent = "silent"               /// (boolean): True if this notification should be silent.
        case payloadHash = "payloadHash"     /// (string): The hash of the payload
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
        guard let value = body[NotificationProperty.title.rawValue] as? String else { return nil }
        return value
    }
    
    /// Gets the full notification body text (may contain newlines for message history)
    func getText() throws -> String? {
        try self.validateNotificationType()
        guard body.keys.contains(NotificationProperty.text.rawValue) else { return nil }
        guard let value = body[NotificationProperty.text.rawValue] as? String else { return nil }
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
    
    func getAnswerFlag() throws -> Bool {
        try self.validateNotificationType()
        guard body.keys.contains(NotificationProperty.requestAnswer.rawValue) else { return false }
        guard let value = body[NotificationProperty.requestAnswer.rawValue] as? NSNumber else { throw NotificationError.invalidAnswerFlag }
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
