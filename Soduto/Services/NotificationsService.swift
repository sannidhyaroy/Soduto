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
    
    
    // MARK: Service methods
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        
        guard dataPacket.isNotificationPacket else { return false }
        
        // Log the raw packet for debugging
        Log.debug?.message("NotificationsService received packet: \(dataPacket.body)")
        
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
    /// 
    /// Duplicate alerts are prevented by:
    /// - `isAnswer` flag: Android sets `requestAnswer: true` on response packets
    /// - `isAlreadyDisplayed` check: Notifications already in `notificationIds` are shown silently
    public func setup(for device: Device) {
        guard device.incomingCapabilities.contains(DataPacket.notificationPacketType) else { return }
        device.send(DataPacket.notificationRequestPacket())
    }
    
    /// Requests all current notifications from all connected devices.
    /// This clears local notification state and re-fetches everything.
    public func refreshNotifications() {
        let devices = AppDelegate.shared().validDevices
        
        self.notificationIds.removeAll()
        un.removeAllDeliveredNotifications()
        un.removeAllPendingNotificationRequests()
        
        // Request notifications from each device
        for device in devices {
            guard device.incomingCapabilities.contains(DataPacket.notificationRequestPacketType) else { continue }
            device.send(DataPacket.notificationRequestPacket())
        }
    }
    
    public func cleanup(for device: Device) {
        // Hide notifications for the device
        guard let ids = self.notificationIds[device.id] else { return }
        for id in ids {
            self.hideNotification(for: id, from: device)
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
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device) {
        guard let actionId = ActionId(rawValue: id) else { return }
        guard device.pairingStatus == .Paired else { return }
        
        switch actionId {
        case .refresh:
            device.send(DataPacket.notificationRequestPacket())
            break
        }
    }
    
    // MARK: DownloadTaskDelegate
    
    public func downloadTask(_ task: DownloadTask, finishedWithSuccess success: Bool) {
        Log.debug?.message("downloadTask(<\(task)> finishedWithSuccess:<\(success)>)")
        
        guard let index = self.notificationIconDownloadInfos.firstIndex(where: { $0.task === task }) else { return }
        let info = self.notificationIconDownloadInfos.remove(at: index)
        if success {
            do {
                let finalFileURL = try self.renamePartFile(url: info.partFileURL, to: "\(info.notificationId).png")
                Log.debug?.message("downloadTask saving icon to: \(finalFileURL.path)")
                Log.debug?.message("Notification id: \(info.notificationId)")
                self.downloadedNotificationIconFileURLByNotificationId[info.notificationId] = finalFileURL
                if (info.fileHash != nil && self.cachedDownloadedNotificationIconFileURLByHash[info.fileHash!] == nil) {
                    let cachedFileURL = try self.copyFileToCache(url: finalFileURL, hash: info.fileHash!)
                    self.cachedDownloadedNotificationIconFileURLByHash[info.fileHash!] = cachedFileURL
                    Log.debug?.message("New icon found with hash \(info.fileHash!), saving to cached icons as \(cachedFileURL)")
                }
            }
            catch {}
        }
        self.showNotification(for: info.dataPacket, from: info.device)
    }

    
    // MARK: UserNotificationActionHandler
    
    /// Handles user responses to notification actions.
    ///
    /// Supports the following actions:
    /// - **Dismiss**: Sends a cancel packet to the remote device if the notification is cancelable
    /// - **Reply**: Sends the user's text reply to the remote device
    /// - **Action1/2/3**: Sends the semantic action string stored in userInfo to trigger the remote action
    public static func handleAction(for response: UNNotificationResponse, context: UserNotificationContext) {
        let userInfo = response.notification.request.content.userInfo
        guard let deviceId = userInfo[UserInfoProperty.deviceId.rawValue] as? String else { return }
        guard let notificationId = userInfo[UserInfoProperty.notificationId.rawValue] as? NotificationId else { return }
        guard let isCancelable = userInfo[UserInfoProperty.isCancelable.rawValue] as? NSNumber else { return }
        guard let device = context.deviceManager.device(withId: deviceId) else { return }
        guard device.pairingStatus == .Paired else { return }
        
        let actionId = response.actionIdentifier
        
        // Handle dismiss action
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
    public func ShowCustomNotification(title: String, subtitle: String? = nil, body: String, sound: Bool, id: String) {
        let notification = UNMutableNotificationContent()
        notification.title = title
        if let subtitle = subtitle {
            notification.subtitle = subtitle
        }
        notification.body = body
        if sound {
            notification.sound = UNNotificationSound.default
        }
        let request = UNNotificationRequest(identifier: id, content: notification, trigger: nil)
        un.add(request) { error in
            if let error = error {
                print(error.localizedDescription)
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
            catch {}
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
        let finalFileURL = fileURL.deletingLastPathComponent().appendingPathComponent("\(fileNotificationId).png")
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

    private func showNotification(for dataPacket: DataPacket, from device: Device) {
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
            
            // Log successful notification processing
            Log.debug?.message("Processing notification from \(appName): id=\(packetNotificationId), ticker=\(ticker.prefix(50))...")
            
            let replyId = try dataPacket.getReplyRequestId()
            let actions = try dataPacket.getActions()
            let isAnswer = try dataPacket.getAnswerFlag()
            let isSilent = try dataPacket.getSilentFlag()
            let isCancelable = try dataPacket.getClearableFlag()
            let isAlreadyDisplayed = self.notificationIds[device.id]?.contains(notificationId) ?? false
            let dontPresent = isAnswer || isSilent || isAlreadyDisplayed
            let hasReply = replyId != nil
            
            Log.debug?.message("Notification flags - isAnswer: \(isAnswer), isSilent: \(isSilent), isCancelable: \(isCancelable), hasReply: \(hasReply), isUpdate: \(isAlreadyDisplayed), actions: \(actions ?? [])")

            var notificationIconURL: URL? = nil
            if (self.downloadedNotificationIconFileURLByNotificationId[packetNotificationId] != nil) {
                notificationIconURL = self.downloadedNotificationIconFileURLByNotificationId.removeValue(forKey: packetNotificationId)
            }

            let notification = UNMutableNotificationContent()
            
            // Filter actions - exclude copy OTP actions, "Reply" actions (handled separately via requestReplyId), and limit to max 3
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
            
            // Build userInfo with base properties
            var userInfo: [String: Any] = [
                UserInfoProperty.deviceId.rawValue: device.id,
                UserInfoProperty.notificationId.rawValue: packetNotificationId,
                UserInfoProperty.requestReplyId.rawValue: replyId as Any,
                UserInfoProperty.isCancelable.rawValue: NSNumber(value: isCancelable),
                UserNotificationManager.Property.dontPresent.rawValue: NSNumber(value: dontPresent),
                UserNotificationManager.Property.actionHandlerClass.rawValue: NSStringFromClass(NotificationsService.self)
            ]
            
            // Store semantic action mappings in userInfo using positional keys
            // When handling, we look up the semantic meaning using the positional identifier
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
            notification.title = device.name
            notification.subtitle = "\(appName)"  // Set Notification Subtitle
            notification.body = ticker  // Set Notification Body
            
            // Get or create a category with actual action titles from the remote device
            // Categories are cached by shape + titles for reuse across notifications
            let actionTitles = Array(filteredActions.prefix(3))
            let categoryId = AppDelegate.shared().userNotificationManager.getOrCreateCategory(
                hasReply: hasReply,
                actionTitles: actionTitles
            )
            notification.categoryIdentifier = categoryId
            
            // Don't set notification sound if it's an answer to request packet or is a silent notification
            if !dontPresent {
                notification.sound = UNNotificationSound.default
            }
            
            // Set Notification App Icon
            if let iconURL = notificationIconURL {
                do {
                    let attachment = try UNNotificationAttachment(identifier: notificationId, url: iconURL, options: nil)
                    notification.attachments = [attachment]
                } catch {
                    print(error.localizedDescription)
                }
            }
            
            // Create notification request
            let request = UNNotificationRequest(identifier: notificationId, content: notification, trigger: nil)
            
            // Push Notification (categories are already registered at app startup)
            un.add(request) { error in
                if let error = error {
                    print(error.localizedDescription)
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
        self.hideNotification(for: id, from: device)
    }
    
    private func hideNotification(for id: NotificationId, from device: Device) {
        UNUserNotificationCenter.current().removeNotification(withId: id)
        
        self.removeNotificationId(id, from: device)
    }
    
    private func addNotificationId(_ id: NotificationId, from device: Device) {
        if self.notificationIds[device.id] == nil {
            self.notificationIds[device.id] = Set<NotificationId>()
        }
        self.notificationIds[device.id]?.insert(id)
    }
    
    private func removeNotificationId(_ id: NotificationId, from device: Device) {
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
        case ticker = "ticker"               /// (string): The title or headline of the notification.
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
    
    func getTicker() throws -> String? {
        try self.validateNotificationType()
        guard body.keys.contains(NotificationProperty.ticker.rawValue) else { return nil }
        guard let value = body[NotificationProperty.ticker.rawValue] as? String else { throw NotificationError.invalidTicker }
        return value
    }
    
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
