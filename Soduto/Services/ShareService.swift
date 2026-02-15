//
//  ShareService.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-12-02.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation
import Cocoa
import os
import UniformTypeIdentifiers
import UserNotifications

/// Service providing capability to send end receive files, links, etc
///
/// It receives a packages with type kdeconnect.share.request. If they have a payload
/// attached, it will download it as a file with the filename set in the field
/// "filename" (string). If that field is not set it should generate a filename.
///
/// If the content transferred is text, it can be sent in a field "text" (string)
/// instead of an attached payload. In that case, this plugin opens a text editor
/// with the content instead of saving it as a file.
///
/// If the content transferred is a url, it can be sent in a field "url" (string).
/// In that case, this plugin opens that url in the default browser.
///
/// Transfer completion handling:
/// - Download completion is delivered via `DownloadTaskDelegate`.
/// - Upload completion is delivered via `ConnectionDelegate`.
///
/// This reflects the architectural distinction between: incoming, service-owned downloads and outgoing, connection-owned uploads.
/// Note:
/// `ShareService` is not the primary `ConnectionDelegate`.
/// Upload completion events are forwarded by `Device`, which owns the active connection lifecycle.
public class ShareService: NSObject, Service, DownloadTaskDelegate, ConnectionDelegate, UserNotificationActionHandler, NSDraggingDestination {
    
    let un = UNUserNotificationCenter.current()
    let notificationIconPath = Bundle.main.pathForImageResource(NSImage.Name("AirDrop"))
    
    // MARK: Types
    
    public enum ExtensionShareResult {
        case fileUploadQueued    // file with payload, tracked via ConnectionDelegate
        case sentWithoutPayload  // URL shared, completes immediately
        case skipped             // unshareable (directory, unreadable, etc.)
    }
    
    private enum ShareError: Error {
        case partFileRenameFailed
    }
    
    private enum ActionId: ServiceAction.Id {
        case shareFiles
    }
    
    private enum NotificationProperty: String {
        case downloadedFileUrl = "com.soduto.ShareService.download.url"
    }
    
    private struct DownloadInfo {
        let task: DownloadTask
        let fileName: String
        let url: URL
    }
    
    /// Owns a temporary download stream and guarantees closure
    private final class TempDownloadStream {
        let stream: OutputStream
        private var isTransferred = false
        
        init(stream: OutputStream) {
            self.stream = stream
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
    
    private struct DragDestination {
        let dataPackets: [DataPacket]
        let device: Device
    }
    
    
    // MARK: Service properties
    
    public static let serviceId: Service.Id = "com.soduto.services.share"
    
    private static let dragTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType(UTType.fileURL.identifier),
        NSPasteboard.PasteboardType(UTType.url.identifier),
        NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier),
        NSPasteboard.PasteboardType(UTType.text.identifier)]
    
    public let incomingCapabilities = Set<Service.Capability>([ DataPacket.sharePacketType ])
    public let outgoingCapabilities = Set<Service.Capability>([ DataPacket.sharePacketType ])
    
    private var downloadInfos: [DownloadInfo] = []
    private var devices: [Device.Id:Device] = [:]
    private var validDevices: [Device] { return self.devices.values.filter { $0.isReachable && $0.pairingStatus == .Paired } }
    
    /// Tracks pending file uploads initiated by the Share Extension, per device.
    /// When all tracked uploads for a device complete, the final status is reported back to the extension.
    private var pendingExtensionUploads: [Device.Id: (total: Int, succeeded: Int, failed: Int)] = [:]
    
    
    // MARK: Service methods
    
    /// NIO-compatible packet handler.
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onAnyConnection connection: AnyBaseConnection) -> Bool {
        return handleDataPacketCore(dataPacket, fromDevice: device)
    }
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        return handleDataPacketCore(dataPacket, fromDevice: device)
    }
    
    private func handleDataPacketCore(_ dataPacket: DataPacket, fromDevice device: Device) -> Bool {
        guard dataPacket.isSharePacket else { return false }
        
#if DEBUG
        Logger.services.debug("handleDataPacket(<\(dataPacket, privacy: .public)> fromDevice:<\(device, privacy: .public)>)")
#else
        Logger.services.debug("handleDataPacket(type: \(dataPacket.type, privacy: .public), id: \(dataPacket.id, privacy: .public)) from device: \(device.id, privacy: .public)")
#endif
        
        do {
            if let downloadTask = dataPacket.downloadTask {
                let fileName = try dataPacket.getFilename()
                self.downloadFile(fileName, usingTask: downloadTask, from: device)
            }
            else if let text = try dataPacket.getText() {
                let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                let fileName = try dataPacket.getFilename() ?? "\(UUID().uuidString).txt"
                
                // Sanitize filename by extracting only the last path component to prevent path traversal attacks
                let sanitizedFileName = URL(fileURLWithPath: "").appendingPathComponent(fileName, isDirectory: false).lastPathComponent
                let fullURL = directory.appendingPathComponent(sanitizedFileName, isDirectory: false)
                
                // Verify the resolved path is still within the temp directory
                guard fullURL.path.hasPrefix(directory.path) else {
                    Logger.services.error("Rejected text file with suspicious filename: \(fileName, privacy: .public)")
                    return false
                }
                
                try text.write(to: fullURL, atomically: true, encoding: .utf8)
                NSWorkspace.shared.open(fullURL)
            }
            else if let urlString = try dataPacket.getUrl(), let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
            else {
                Logger.services.error("Unknown shared content")
            }
        }
        catch {
            Logger.services.error("Error while handling share packet: \(error, privacy: .public)")
        }
        
        return true
    }
    
    public func setup(for device: Device) {
        self.devices[device.id] = device
    }
    
    public func cleanup(for device: Device) {
        _ = self.devices.removeValue(forKey: device.id)
    }
    
    public func actions(for device: Device) -> [ServiceAction] {
        guard device.incomingCapabilities.contains(DataPacket.sharePacketType) else { return [] }
        guard device.pairingStatus == .Paired else { return [] }
        
        return [
            ServiceAction(id: ActionId.shareFiles.rawValue, title: "Send Files", description: "Upload files to the peer device.", service: self, device: device)
        ]
    }
    
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device) {
        guard let actionId = ActionId(rawValue: id) else { return }
        guard device.pairingStatus == .Paired else { return }
        
        switch actionId {
        case .shareFiles:
            NSApp.activate(ignoringOtherApps: true)
            let openPanel = NSOpenPanel()
            openPanel.canChooseFiles = true
            openPanel.allowsMultipleSelection = true
            openPanel.begin { result in
                guard result == NSApplication.ModalResponse.OK else { return }
                for url in openPanel.urls {
                    self.uploadFile(url: url, to: device)
                }
            }
            break
        }
        
    }
    
    
    // MARK: ConnectionDelegate
    
    /// ShareService receives upload completion events indirectly.
    /// The active `ConnectionDelegate` is `Device`, which forwards selected events to services that opt-in.
    
    /// ShareService does not react to connection state changes.
    public func connection(_ connection: Connection, didSwitchToState: Connection.State) {
        // Not needed by ShareService
    }
    
    /// Incoming packets are routed to services via the `Service` API, so this callback is intentionally ignored.
    public func connection(_ connection: Connection, didReadPacket: DataPacket) {
        // ShareService already handles packets via Service APIs
    }
    
    /// Upload capacity changes are not handled at the service level.
    public func connectionCapacityChanged(_ connection: Connection) {
        // Not relevant for ShareService
    }
    
    /// Called by `Connection` when an outgoing packet (and its payload, if any) has finished sending.
    ///
    /// This method is used to detect completion of file uploads initiated by `ShareService`.
    ///
    /// Important:
    /// - Upload completion is reported via `ConnectionDelegate`, not `UploadTaskDelegate`.
    /// - Only packets with payloads are considered uploads.
    /// - The `Connection` instance is the authoritative source for the destination device information.
    public func connection(_ connection: Connection, didSendPacket packet: DataPacket, uploadedPayload: Bool) {
        guard packet.hasPayload(), packet.type == DataPacket.sharePacketType else { return }
        
        self.showUploadFinishNotification(connection: connection, succeeded: uploadedPayload)
        
        // Track extension-initiated uploads and report final status when all complete
        guard let deviceId = try? connection.identity?.getDeviceId(), var tracking = pendingExtensionUploads[deviceId] else { return }
        
        if uploadedPayload {
            tracking.succeeded += 1
        } else {
            tracking.failed += 1
        }
        
        if tracking.succeeded + tracking.failed >= tracking.total {
            pendingExtensionUploads.removeValue(forKey: deviceId)
            let status = tracking.failed > 0 ? "failed" : "success"
            Self.reportExtensionTransferStatus(deviceId: deviceId, status: status)
        } else {
            pendingExtensionUploads[deviceId] = tracking
        }
    }
    
    
    // MARK: DownloadTaskDelegate
    
    public func downloadTask(_ task: DownloadTask, finishedWithSuccess success: Bool) {
        Logger.services.debug("downloadTask(<\(task, privacy: .public)> finishedWithSuccess:<\(success, privacy: .public)>)")
        
        guard let index = self.downloadInfos.firstIndex(where: { $0.task === task }) else { return }
        let info = self.downloadInfos.remove(at: index)
        
        do {
            if success {
                let finalUrl = try self.renamePartFile(url: info.url, to: info.fileName)
                self.showDownloadFinishNotification(fileName: info.fileName, downloadTask: task, succeeded: success, finalUrl: finalUrl)
            }
            else {
                self.showDownloadFinishNotification(fileName: info.fileName, downloadTask: task, succeeded: success)
            }
        }
        catch {
            self.showDownloadFinishNotification(fileName: info.fileName, downloadTask: task, succeeded: false)
        }
    }
    
    
    // MARK: UserNotificationsActionHandler
    
    /// Handles user responses to share/download notification actions.
    ///
    /// Opens the downloaded file when the user clicks the notification action.
    public static func handleAction(for response: UNNotificationResponse, context: UserNotificationContext) {
        guard let urlString = response.notification.request.content.userInfo[NotificationProperty.downloadedFileUrl.rawValue] as? String else { return }
        guard let url = URL(string: urlString) else { return }
        if response.actionIdentifier == "openfile" || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            NSWorkspace.shared.open(url)
        }
    }
    
    // MARK: NSDraggingDestination
    
    public dynamic func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return draggingUpdated(sender)
    }
    
    public dynamic func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard self.validDevices.count > 0 else { return [] }
        
        let types: [String] = type(of: self).dragTypes.map { $0.rawValue }
        let canRead: Bool = sender.draggingPasteboard.canReadItem(withDataConformingToTypes: types)
        return canRead ? [.copy] : []
    }
    
    public dynamic func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard self.validDevices.count > 0 else { return false }
        
        var filePackets: [DataPacket] = []
        var urlPackets: [DataPacket] = []
        var textPackets: [DataPacket] = []
        
        let types = type(of: self).dragTypes
        let items: [NSPasteboardItem] = sender.draggingPasteboard.pasteboardItems ?? []
        for item in items {
            guard let type = item.availableType(from: types) else { continue }
            switch type.rawValue {
                
            case UTType.fileURL.identifier:
                guard let urlString = item.string(forType: type) else { break }
                guard let url = URL(string: urlString) else { break }
                guard let dataPacket = self.dataPacket(forFileUrl: url) else { break }
                filePackets.append(dataPacket)
                break
                
            case UTType.url.identifier:
                guard let urlString = item.string(forType: type) else { break }
                guard let url = URL(string: urlString) else { break }
                let dataPacket = self.dataPacket(forUrl: url)
                urlPackets.append(dataPacket)
                break
                
            case type.rawValue where UTType(type.rawValue)?.conforms(to: .text) == true:
                guard let text = item.string(forType: type) else { break }
                if let url = URL(string: text), url.scheme != nil {
                    let dataPacket = self.dataPacket(forUrl: url)
                    urlPackets.append(dataPacket)
                }
                else {
                    let dataPacket = self.dataPacket(forText: text)
                    textPackets.append(dataPacket)
                }
                break
                
            default:
                break
            }
        }
        
        guard filePackets.count > 0 || urlPackets.count > 0 || textPackets.count > 0 else { return false }
        
        return self.popUpDragDestinationMenu(forFilePackets: filePackets, urlPackets: urlPackets, textPackets: textPackets, sender: sender)
    }
    
    
    // MARK: Actions
    
    @objc private dynamic func dragDestinationMenuItemAction(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem else { return }
        
        if let obj = menuItem.representedObject as? DragDestination {
            guard obj.device.isReachable && obj.device.pairingStatus == .Paired else { return }
            for packet in obj.dataPackets {
                obj.device.send(packet)
                self.showUploadStartNotification(to: obj.device)
            }
        }
    }
    
    
    // MARK: Share Extension methods
    
    /// Called by AppDelegate's upload observer when the Share extension signals a file or URL to share.
    @discardableResult
    public func shareFromExtension(url: URL, to device: Device) -> ExtensionShareResult {
        guard device.isReachable && device.pairingStatus == .Paired else {
            UserNotificationHelper.show(title: device.name, subtitle: "Outbound Transfer Failed", body: "\(device.name) is no longer reachable.", sound: true, id: "DeviceUnreachableUpload", urgency: .timeSensitive)
            return .skipped
        }
        
        if let dataPacket = self.dataPacket(forFileUrl: url) {
            device.send(dataPacket)
            self.showUploadStartNotification(to: device)
            return .fileUploadQueued
        } else if url.isFileURL {
            // Directory, unreadable file, etc. — nothing to send
            Logger.services.error("Cannot share file URL (unsupported content type): \(url, privacy: .public)")
            return .skipped
        } else {
            let dataPacket = self.dataPacket(forUrl: url)
            device.send(dataPacket)
            return .sentWithoutPayload
        }
    }
    
    /// Called by AppDelegate's upload observer when the Share extension signals text to share.
    public func shareFromExtension(text: String, to device: Device) {
        guard device.isReachable && device.pairingStatus == .Paired else {
            UserNotificationHelper.show(title: device.name, subtitle: "Outbound Transfer Failed", body: "\(device.name) is no longer reachable.", sound: true, id: "DeviceUnreachableUpload", urgency: .timeSensitive)
            return
        }
        let dataPacket = self.dataPacket(forText: text)
        device.send(dataPacket)
    }
    
    /// Begin tracking file uploads initiated by the Share Extension.
    /// When all tracked uploads for this device complete, the final status is reported back to the extension, via the `com.soduto.share.status` Darwin notification.
    public func beginTrackingExtensionUploads(deviceId: String, fileCount: Int) {
        guard fileCount > 0 else { return }
        pendingExtensionUploads[deviceId] = (total: fileCount, succeeded: 0, failed: 0)
    }
    
    /// Reports transfer status back to the Share Extension via App Group UserDefaults + Darwin notification.
    public static func reportExtensionTransferStatus(deviceId: String, status: String) {
        var statuses = AppDefaultsStore.ShareExtension.transferStatuses ?? [:]
        statuses[deviceId] = status
        AppDefaultsStore.ShareExtension.transferStatuses = statuses
        
        let name = CFNotificationName("com.soduto.share.status" as CFString)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), name, nil, nil, false)
    }
    
    
    // MARK: Private methods
    
    private func fileSize(path: String) -> Int64? {
        var fileSize : Int64? = nil
        
        do {
            let attr = try FileManager.default.attributesOfItem(atPath: path)
            fileSize = attr[FileAttributeKey.size] as? Int64
        } catch {
            Logger.services.error("Failed to get file information: \(error, privacy: .public)")
        }
        
        return fileSize
    }
    
    private func uploadFile(url: URL, to device: Device) {
        guard let dataPacket = self.dataPacket(forFileUrl: url) else { return }
        device.send(dataPacket)
        self.showUploadStartNotification(to: device)
    }
    
    private func downloadFile(_ fileName: String?, usingTask task: DownloadTask, from device: Device) {
        // FIXME: handle nil fileName correctly. The commented approach is wrong because download easily
        // expires - needs to start downloading in background while asking for file name
        
        //        let askFileLocation = {
        //            NSApp.activate(ignoringOtherApps: true)
        //            let panel = NSSavePanel()
        //            panel.message = "Select save location for download received form device \"\(device.name)\""
        //            panel.nameFieldStringValue = fileName ?? ""
        //            panel.begin { result in
        //                guard result == NSFileHandlingPanelOKButton else { return }
        //                guard let url = panel.url else { return }
        //                self.downloadFile(downloadTask: task, fileName: url.lastPathComponent, destUrl: url)
        //            }
        //        }
        
        do {
            if let fileName = fileName {
                let url = try URL(forDownloadedFile: fileName)
                self.downloadFile(downloadTask: task, fileName: fileName, destUrl: url)
                self.showDownloadStartNotification(fileName: fileName, downloadTask: task)
            }
            else {
                //                askFileLocation()
                self.showDownloadFinishNotification(fileName: fileName, downloadTask: task, succeeded: false)
            }
        }
        catch {
            // Failed to retrieve appropriate download destination - ask user to select
            //            askFileLocation()
            self.showDownloadFinishNotification(fileName: fileName, downloadTask: task, succeeded: false)
        }
    }
    
    private func downloadFile(downloadTask task: DownloadTask, fileName: String, destUrl: URL) {
        if let (tempStream, partUrl) = self.streamForTempDownload(finalUrl: destUrl) {
            self.downloadInfos.append(DownloadInfo(task: task, fileName: fileName, url: partUrl))
            task.delegate = self
            task.start(withStream: tempStream.transfer())
        }
        else {
            self.showDownloadFinishNotification(fileName: fileName, downloadTask: task, succeeded: false)
        }
    }
    
    private func streamForTempDownload(finalUrl: URL) -> (TempDownloadStream, URL)? {
        // Try open stream for new file. Try alternative names on fail
        var partUrl = finalUrl.appendingPathExtension("part")
        var stream: OutputStream? = nil
        for _ in 1...10000 {
            if !FileManager.default.fileExists(atPath: partUrl.path) {
                stream = OutputStream(url: partUrl, append: false)
                stream?.open()
                if stream?.hasSpaceAvailable == true {
                    return (TempDownloadStream(stream: stream!), partUrl)
                }
                // Open failed or stream unusable
                stream?.close()
                stream = nil
            }
            
            partUrl = partUrl.alternativeForDuplicate()
        }
        
        // Last attempt with completely random extension
        partUrl = finalUrl.appendingPathExtension("part-\(UUID().uuidString)")
        if !FileManager.default.fileExists(atPath: partUrl.path) {
            stream = OutputStream(url: partUrl, append: false)
            stream?.open()
            
            if stream?.hasSpaceAvailable == true {
                return (TempDownloadStream(stream: stream!), partUrl)
            }
            stream?.close()
        }
        return nil
    }
    
    private func renamePartFile(url partUrl: URL, to fileName: String) throws -> URL {
        
        // Try rename file from temporary *.part name to final path based on original file name
        // NOTE: *.part name might not necesarily be equal to filename with appended .part suffix
        var finalUrl = partUrl.deletingLastPathComponent().appendingPathComponent(fileName)
        for _ in 1...10000 {
            if !FileManager.default.fileExists(atPath: finalUrl.path) {
                do {
                    try FileManager.default.moveItem(at: partUrl, to: finalUrl)
                    return finalUrl
                }
                catch {}
            }
            finalUrl = finalUrl.alternativeForDuplicate()
        }
        
        throw ShareError.partFileRenameFailed
    }
    
    private func showUploadStartNotification(to device: Device) {
        let deviceName = device.name
        let title = device.name
        let subtitle = "Outbound Transfer in Progress"
        let body = "Sending File to \(deviceName)"
        let notificationId = "\(self.id).upload.start.\(device.id)"
        
        let notification = UNMutableNotificationContent()
        notification.title = title
        notification.subtitle = subtitle
        notification.body = body
        notification.sound = nil
        notification.setUrgency(.passive)
        if let iconPath = self.notificationIconPath {
            let notificationIconURL = URL(fileURLWithPath: iconPath)
            do {
                let attachment = try UNNotificationAttachment(identifier: notificationId, url: notificationIconURL, options: nil)
                notification.attachments = [attachment]
            } catch {
                print(error.localizedDescription)
            }
        }
        
        let request = UNNotificationRequest(identifier: notificationId, content: notification, trigger: nil)
        un.add(request) { error in
            if let error = error {
                print(error.localizedDescription)
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            self.un.removeNotification(withId: notificationId)
        }
    }
    
    private func showDownloadStartNotification(fileName: String?, downloadTask task: DownloadTask) {
        let deviceName = (try? task.connection.identity?.getDeviceName()) ?? "Unknown Device"
        let title = deviceName
        let subtitle = "Inbound Transfer in Progress"
        let body = "Receiving File from \(deviceName)"
        let notificationId = "\(self.id).download.\(task.id)"
        
        let notification = UNMutableNotificationContent()
        notification.title = title
        notification.subtitle = subtitle
        notification.body = body
        notification.sound = nil
        notification.setUrgency(.active)
        if let iconPath = self.notificationIconPath {
            let notificationIconURL = URL(fileURLWithPath: iconPath)
            do {
                let attachment = try UNNotificationAttachment(identifier: notificationId, url: notificationIconURL, options: nil)
                notification.attachments = [attachment]
            } catch {
                print(error.localizedDescription)
            }
        }
        
        let request = UNNotificationRequest(identifier: notificationId, content: notification, trigger: nil)
        un.add(request) { error in
            if let error = error {
                print(error.localizedDescription)
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            self.un.removeNotification(withId: notificationId)
        }
    }
    
    private func showUploadFinishNotification(connection: Connection, succeeded: Bool) {
        let deviceName = (try? connection.identity?.getDeviceName()) ?? "Unknown Device"
        let deviceId = (try? connection.identity?.getDeviceId()) ?? "unknown-device"
        let title = deviceName
        let subtitle = succeeded ? "Outbound Transfer Successful" : "Outbound Transfer Failed"
        let body = succeeded ? "File sent to \(deviceName)" : "Failed to send file to \(deviceName)"
        let notificationId = "\(self.id).upload.finish.\(deviceId)"
        let notification = UNMutableNotificationContent()
        notification.title = title
        notification.subtitle = subtitle
        notification.body = body
        notification.sound = .default
        notification.setUrgency(.active)
        if let iconPath = self.notificationIconPath {
            let notificationIconURL = URL(fileURLWithPath: iconPath)
            do {
                let attachment = try UNNotificationAttachment(identifier: notificationId, url: notificationIconURL, options: nil)
                notification.attachments = [attachment]
            } catch {
                print("Failed to attach upload icon: \(error.localizedDescription)")
            }
        }
        
        let request = UNNotificationRequest(identifier: notificationId, content: notification, trigger: nil)
        un.add(request) { error in
            if let error = error {
                print("Failed to post upload notification: \(error.localizedDescription)")
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            self.un.removeNotification(withId: notificationId)
        }
    }
    
    private func showDownloadFinishNotification(fileName: String?, downloadTask task: DownloadTask, succeeded: Bool, finalUrl: URL? = nil) {
        let deviceName = (try? task.connection.identity?.getDeviceName()) ?? "Unknown Device"
        let title = deviceName
        let subtitle = succeeded ? "Inbound Transfer Successful" : "Inbound Transfer Failed"
        let body: String
        if let fileName = finalUrl?.lastPathComponent ?? fileName {
            body = "Received '\(fileName)' from \(deviceName)"
        }
        else {
            body = "File received from \(deviceName)"
        }
        let notificationId = "\(self.id).download.\(task.id)"
        
        let notification = UNMutableNotificationContent()
        if let url = finalUrl {
            notification.userInfo = [
                NotificationProperty.downloadedFileUrl.rawValue: url.absoluteString,
                UserNotificationManager.Property.actionHandlerClass.rawValue: NSStringFromClass(ShareService.self)
            ]
        }
        notification.title = title
        notification.subtitle = subtitle
        notification.body = body
        notification.sound = .default
        notification.setUrgency(.active)
        if let iconPath = self.notificationIconPath {
            let notificationIconURL = URL(fileURLWithPath: iconPath)
            do {
                let attachment = try UNNotificationAttachment(identifier: notificationId, url: notificationIconURL, options: nil)
                notification.attachments = [attachment]
            } catch {
                print(error.localizedDescription)
            }
        }
        if succeeded && finalUrl != nil {
            notification.categoryIdentifier = "DownloadFinished"
        }
        
        let request = UNNotificationRequest(identifier: notificationId, content: notification, trigger: nil)
        un.add(request) { error in
            if let error = error {
                print(error.localizedDescription)
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            self.un.removeNotification(withId: notificationId)
        }
    }
    
    private func popUpDragDestinationMenu(forFilePackets filePackets: [DataPacket], urlPackets: [DataPacket], textPackets: [DataPacket], sender: NSDraggingInfo) -> Bool {
        
        let packets: [DataPacket]
        let title: String
        if filePackets.count > 0 {
            packets = filePackets
            title = packets.count == 1 ?
            String(format: NSLocalizedString("Upload file to:", comment: "Drag destinations menu title"), packets.count) :
            String(format: NSLocalizedString("Upload %d file(s) to:", comment: "Drag destinations menu title"), packets.count)
        }
        else if urlPackets.count > 0 {
            packets = urlPackets
            title = packets.count == 1 ?
            String(format: NSLocalizedString("Open link on:", comment: "Drag destinations menu title"), packets.count) :
            String(format: NSLocalizedString("Open %d link(s) on:", comment: "Drag destinations menu title"), packets.count)
        }
        else if textPackets.count > 0 {
            packets = textPackets
            title = packets.count == 1 ?
            String(format: NSLocalizedString("Send text snippet to:", comment: "Drag destinations menu title"), packets.count) :
            String(format: NSLocalizedString("Send %d text snippet(s) to:", comment: "Drag destinations menu title"), packets.count)
        }
        else {
            return false
        }
        
        
        let menu = NSMenu()
        menu.autoenablesItems = false
        
        let titleItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        
        if AppDefaultsStore.Preferences.disableSharePopUp && self.validDevices.count == 1 {
            guard let device = validDevices.first, device.isReachable == true, device.pairingStatus == .Paired else { return false }
            for packet in packets {
                device.send(packet)
                self.showUploadStartNotification(to: device)
            }
            return true
        }
        
        for device in self.validDevices {
            let keyEquivalent: String = menu.items.count <= 10 ? "\(menu.items.count % 10)" : ""
            let item = NSMenuItem(title: device.name, action: nil, keyEquivalent: keyEquivalent)
            item.target = self
            item.action = #selector(dragDestinationMenuItemAction(_:))
            item.representedObject = DragDestination(dataPackets: packets, device: device)
            menu.addItem(item)
        }
        
        let position = sender.draggingDestinationWindow?.frame.origin ?? NSEvent.mouseLocation
        return menu.popUp(positioning: nil, at: position, in: nil)
    }
    
    private func dataPacket(forFileName fileName: String) -> DataPacket? {
        let url = URL(fileURLWithPath: fileName)
        let dataPacket = self.dataPacket(forFileUrl: url)
        return dataPacket
    }
    
    private func dataPacket(forFileUrl url: URL) -> DataPacket? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        guard !isDirectory.boolValue else { return nil }
        guard let filename = url.pathComponents.last else { return nil }
        guard let stream = InputStream(url: url) else { return nil }
        
        let fileSize = self.fileSize(path: url.path)
        let dataPacket = DataPacket.sharePacket(fileStream: stream, fileSize: fileSize, fileName: filename)
        return dataPacket
    }
    
    private func dataPacket(forUrl url: URL) -> DataPacket {
        return DataPacket.sharePacket(url: url)
    }
    
    private func dataPacket(forText text: String) -> DataPacket {
        return DataPacket.sharePacket(text: text)
    }
}


// MARK: DataPacket (Share)

/// Ping service data packet utilities
fileprivate extension DataPacket {
    
    // MARK: Types
    
    enum ShareError: Error {
        case wrongType
        case invalidFilename
        case invalidText
        case invalidUrl
    }
    
    struct ShareProperty {
        static let filename = "filename"
        static let text = "text"
        static let url = "url"
    }
    
    
    // MARK: Properties
    
    static let sharePacketType = "kdeconnect.share.request"
    
    var isSharePacket: Bool { return self.type == DataPacket.sharePacketType }
    
    
    // MARK: Public methods
    
    static func sharePacket(fileStream: InputStream, fileSize: Int64?, fileName: String?) -> DataPacket {
        var body: Body = [:]
        if let filename = fileName {
            body[ShareProperty.filename] = filename as AnyObject
        }
        var packet = DataPacket(type: sharePacketType, body: body)
        packet.payload = fileStream
        packet.payloadSize = fileSize
        return packet
    }
    
    static func sharePacket(url: URL) -> DataPacket {
        let body: Body = [
            ShareProperty.url: url.absoluteString as AnyObject
        ]
        let packet = DataPacket(type: sharePacketType, body: body)
        return packet
    }
    
    static func sharePacket(text: String) -> DataPacket {
        let body: Body = [
            ShareProperty.text: text as AnyObject
        ]
        let packet = DataPacket(type: sharePacketType, body: body)
        return packet
    }
    
    func getFilename() throws -> String? {
        try self.validateShareType()
        guard body.keys.contains(ShareProperty.filename) else { return nil }
        guard let value = body[ShareProperty.filename] as? String else { throw ShareError.invalidFilename }
        return value
    }
    
    func getText() throws -> String? {
        try self.validateShareType()
        guard body.keys.contains(ShareProperty.text) else { return nil }
        guard let value = body[ShareProperty.text] as? String else { throw ShareError.invalidText }
        return value
    }
    
    func getUrl() throws -> String? {
        try self.validateShareType()
        guard body.keys.contains(ShareProperty.url) else { return nil }
        guard let value = body[ShareProperty.url] as? String else { throw ShareError.invalidUrl }
        return value
    }
    
    func validateShareType() throws {
        guard self.isSharePacket else { throw ShareError.wrongType }
    }
}
