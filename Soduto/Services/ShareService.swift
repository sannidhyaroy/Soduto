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
        let deviceName: String
        let deviceId: Device.Id
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
    
    /// Tracks an incoming multi-file download batch announced by kdeconnect.share.request.update.
    /// Finish notifications are suppressed per-file and coalesced into one summary.
    private struct DownloadBatch {
        let totalFiles: Int
        let totalBytes: Int64?
        let deviceName: String
        var succeeded: Int = 0
        var failed: Int = 0
        var completed: Int { succeeded + failed }
        var isDone: Bool { completed >= totalFiles }
    }
    
    /// Tracks a batch of outgoing file uploads to a single device.
    /// Finish notifications are suppressed per-file and coalesced into one summary.
    private struct UploadBatch {
        let total: Int
        var succeeded: Int = 0
        var failed: Int = 0
        let isExtensionInitiated: Bool
        /// Per-batch notification ID (UUID). Shared by start and finish so finish replaces start.
        /// UUID ensures consecutive batches to the same device don't clobber each other's finish.
        let notificationId: String
        var completed: Int { succeeded + failed }
        var isDone: Bool { completed >= total }
    }
    
    
    // MARK: Service properties
    
    public static let serviceId: Service.Id = "com.soduto.services.share"
    
    /// Dedicated directory for text snippets shared from remote devices.
    /// Isolated from the generic temp dir so it can be wiped safely on first device setup.
    private static let sharedTextDirectory: URL = {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("com.soduto.Soduto", isDirectory: true)
            .appendingPathComponent("SharedText", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    
    /// Whether startup cleanup has already run for this process.
    private static var didCleanupSharedTextFiles = false
    
    /// Removes all files from sharedTextDirectory. Called once per process on the first setup(for:).
    private static func cleanupSharedTextFiles() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: sharedTextDirectory, includingPropertiesForKeys: nil) else { return }
        let count = contents.filter { (try? FileManager.default.removeItem(at: $0)) != nil }.count
        if count > 0 {
            Logger.services.debug("Cleaned up \(count, privacy: .public) stale shared text file(s) from previous session")
        }
    }
    
    private static let dragTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType(UTType.fileURL.identifier),
        NSPasteboard.PasteboardType(UTType.url.identifier),
        NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier),
        NSPasteboard.PasteboardType(UTType.text.identifier)]
    
    public let incomingCapabilities = Set<Service.Capability>([
        DataPacket.sharePacketType,
        DataPacket.shareUpdatePacketType
    ])
    public let outgoingCapabilities = Set<Service.Capability>([
        DataPacket.sharePacketType,
        DataPacket.shareUpdatePacketType
    ])
    
    private var downloadInfos: [DownloadInfo] = []
    private var devices: [Device.Id:Device] = [:]
    private var validDevices: [Device] { return self.devices.values.filter { $0.isReachable && $0.pairingStatus == .Paired } }
    
    /// Tracks pending file upload batches per device (all send paths).
    /// When all uploads in a batch complete, a single summary notification is shown.
    /// Extension-initiated batches additionally report status back via Darwin notification.
    private var pendingUploadBatches: [Device.Id: UploadBatch] = [:]
    
    /// Tracks incoming multi-file download batches announced via kdeconnect.share.request.update.
    private var pendingDownloadBatches: [Device.Id: DownloadBatch] = [:]
    
    /// Maps DataPacket.id → Device.id for every in-flight file upload.
    /// Lets connection(_:didSendPacket:) reliably find the destination device and its batch
    /// without depending on connection.identity, which can be nil in edge cases.
    private var uploadPacketDeviceIds: [Int64: Device.Id] = [:]
    
    
    // MARK: Service methods
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        // Handle share.request.update — only create a batch if share.request packets haven't already done so.
        if dataPacket.isShareUpdatePacket {
            do {
                if pendingDownloadBatches[device.id] == nil,
                   let numberOfFiles = try dataPacket.getNumberOfFiles(), numberOfFiles > 1 {
                    let totalBytes = try dataPacket.getTotalPayloadSize()
                    pendingDownloadBatches[device.id] = DownloadBatch(
                        totalFiles: numberOfFiles,
                        totalBytes: totalBytes,
                        deviceName: device.name
                    )
                    self.showDownloadBatchStartNotification(deviceId: device.id, deviceName: device.name, fileCount: numberOfFiles, totalBytes: totalBytes)
                    Logger.services.info("Expecting \(numberOfFiles) files (\(totalBytes ?? 0) bytes) from '\(device.name, privacy: .public)'")
                }
            } catch {
                Logger.services.error("Failed to parse share update packet: \(error, privacy: .public)")
            }
            return true
        }
        
        guard dataPacket.isSharePacket else { return false }
        
#if DEBUG
        Logger.services.debug("handleDataPacket(<\(dataPacket, privacy: .public)> fromDevice:<\(device, privacy: .public)>)")
#else
        Logger.services.debug("handleDataPacket(type: \(dataPacket.type, privacy: .public), id: \(dataPacket.id, privacy: .public)) from device: \(device.id, privacy: .public)")
#endif
        
        do {
            if let downloadTask = dataPacket.downloadTask {
                let fileName = try dataPacket.getFilename()
                // Android embeds numberOfFiles/totalPayloadSize in each share.request body for multi-file batches.
                // Create a batch tracker on the first file if we haven't already (e.g. from share.request.update).
                if pendingDownloadBatches[device.id] == nil,
                   let numberOfFiles = try dataPacket.getNumberOfFiles(), numberOfFiles > 1 {
                    let totalBytes = try dataPacket.getTotalPayloadSize()
                    pendingDownloadBatches[device.id] = DownloadBatch(
                        totalFiles: numberOfFiles,
                        totalBytes: totalBytes,
                        deviceName: device.name
                    )
                    self.showDownloadBatchStartNotification(deviceId: device.id, deviceName: device.name, fileCount: numberOfFiles, totalBytes: totalBytes)
                    Logger.services.info("Expecting \(numberOfFiles) files from '\(device.name, privacy: .public)'")
                }
                self.downloadFile(fileName, usingTask: downloadTask, from: device)
            }
            else if let text = try dataPacket.getText() {
                let directory = ShareService.sharedTextDirectory
                let fileName = try dataPacket.getFilename() ?? "\(UUID().uuidString).txt"
                
                // Sanitize filename by extracting only the last path component to prevent path traversal attacks
                let sanitizedFileName = URL(fileURLWithPath: "").appendingPathComponent(fileName, isDirectory: false).lastPathComponent
                let fullURL = directory.appendingPathComponent(sanitizedFileName, isDirectory: false)
                
                // Verify the resolved path is still within the shared text directory
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
        if !ShareService.didCleanupSharedTextFiles {
            ShareService.didCleanupSharedTextFiles = true
            ShareService.cleanupSharedTextFiles()
        }
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
                self.uploadFiles(openPanel.urls, to: device)
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
    /// - Device identity is resolved via `uploadPacketDeviceIds` (stored at send time) rather than
    ///   `connection.identity`, which can be nil in edge cases and would silently break batch tracking.
    public func connection(_ connection: Connection, didSendPacket packet: DataPacket, uploadedPayload: Bool) {
        guard packet.hasPayload(), packet.type == DataPacket.sharePacketType else { return }
        
        // Resolve device ID from the pre-stored mapping; fall back to connection identity.
        let deviceId = uploadPacketDeviceIds.removeValue(forKey: packet.id)
        ?? (try? connection.identity?.getDeviceId())
        let deviceName = deviceId.flatMap { self.devices[$0]?.name }
        ?? (try? connection.identity?.getDeviceName())
        ?? "Unknown Device"
        
        guard let deviceId = deviceId, var batch = pendingUploadBatches[deviceId] else {
            // No tracked batch — single file transfer.
            self.showUploadFinishNotification(deviceName: deviceName, packet: packet, succeeded: uploadedPayload)
            return
        }
        
        if uploadedPayload { batch.succeeded += 1 } else { batch.failed += 1 }
        
        if batch.isDone {
            pendingUploadBatches.removeValue(forKey: deviceId)
            self.showUploadBatchFinishNotification(deviceId: deviceId, deviceName: deviceName, batch: batch)
            if batch.isExtensionInitiated {
                let status = batch.failed > 0 ? "failed" : "success"
                Self.reportExtensionTransferStatus(deviceId: deviceId, status: status)
            }
        } else {
            pendingUploadBatches[deviceId] = batch
        }
    }
    
    
    // MARK: DownloadTaskDelegate
    
    public func downloadTask(_ task: DownloadTask, finishedWithSuccess success: Bool) {
        Logger.services.debug("downloadTask(<\(task.id, privacy: .public)> finishedWithSuccess:<\(success, privacy: .public)>)")
        
        guard let index = self.downloadInfos.firstIndex(where: { $0.task === task }) else { return }
        let info = self.downloadInfos.remove(at: index)
        
        // Try to rename the .part file to its final name.
        var finalUrl: URL? = nil
        var succeeded = success
        if success {
            do { finalUrl = try self.renamePartFile(url: info.url, to: info.fileName) }
            catch { succeeded = false }
        }
        
        // If this file belongs to a batch, update the batch counter and suppress per-file notifications.
        if var batch = pendingDownloadBatches[info.deviceId] {
            if succeeded { batch.succeeded += 1 } else { batch.failed += 1 }
            if batch.isDone {
                pendingDownloadBatches.removeValue(forKey: info.deviceId)
                self.showDownloadBatchFinishNotification(deviceId: info.deviceId, deviceName: info.deviceName, batch: batch)
            } else {
                pendingDownloadBatches[info.deviceId] = batch
            }
        } else {
            self.showDownloadFinishNotification(fileName: info.fileName, deviceName: info.deviceName, downloadTask: task, succeeded: succeeded, finalUrl: finalUrl)
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
        guard let menuItem = sender as? NSMenuItem,
              let obj = menuItem.representedObject as? DragDestination else { return }
        guard obj.device.isReachable && obj.device.pairingStatus == .Paired else { return }
        
        let filePackets = obj.dataPackets.filter { $0.hasPayload() }
        for p in filePackets { uploadPacketDeviceIds[p.id] = obj.device.id }
        if filePackets.count > 1 {
            let totalSize = filePackets.compactMap { $0.payloadSize }.reduce(0, +)
            obj.device.send(DataPacket.shareUpdatePacket(numberOfFiles: filePackets.count, totalPayloadSize: totalSize))
            self.beginUploadBatch(for: obj.device, fileCount: filePackets.count)
        } else if filePackets.count == 1 {
            self.showUploadStartNotification(to: obj.device, packetId: filePackets[0].id)
        }
        // URL/text packets complete instantly — no start notification needed.
        obj.dataPackets.forEach { obj.device.send($0) }
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
            uploadPacketDeviceIds[dataPacket.id] = device.id
            device.send(dataPacket)
            // Start notification is shown by beginTrackingExtensionUploads as one aggregate notification.
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
    /// Shows one aggregate start notification (consistent with drag-and-drop batch behavior),
    /// then reports a summary finish notification when all uploads complete.
    public func beginTrackingExtensionUploads(deviceId: String, fileCount: Int) {
        guard fileCount > 0 else { return }
        let notifId = "\(self.id).upload.batch.\(UUID().uuidString)"
        pendingUploadBatches[deviceId] = UploadBatch(total: fileCount, isExtensionInitiated: true, notificationId: notifId)
        let deviceName = self.devices[deviceId]?.name ?? "Unknown Device"
        postShareNotification(
            id: notifId,
            title: deviceName,
            subtitle: "Outbound Transfer in Progress",
            body: fileCount > 1 ? "Sending \(fileCount) files to \(deviceName)" : "Sending File to \(deviceName)",
            sound: nil,
            urgency: .passive
        )
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
        uploadPacketDeviceIds[dataPacket.id] = device.id
        device.send(dataPacket)
        self.showUploadStartNotification(to: device, packetId: dataPacket.id)
    }
    
    /// Sends one or more files to a device. For batches (>1 file) emits a share.request.update
    /// packet first, shows a single aggregate start notification, and registers a completion batch.
    /// Single files use per-file notifications.
    private func uploadFiles(_ urls: [URL], to device: Device) {
        let packets = urls.compactMap { self.dataPacket(forFileUrl: $0) }
        guard !packets.isEmpty else { return }
        for p in packets { uploadPacketDeviceIds[p.id] = device.id }
        if packets.count > 1 {
            let totalSize = packets.compactMap { $0.payloadSize }.reduce(0, +)
            device.send(DataPacket.shareUpdatePacket(numberOfFiles: packets.count, totalPayloadSize: totalSize))
            self.beginUploadBatch(for: device, fileCount: packets.count)
        } else {
            self.showUploadStartNotification(to: device, packetId: packets[0].id)
        }
        packets.forEach { device.send($0) }
    }
    
    /// Registers a multi-file upload batch for a device and shows an aggregate start notification.
    private func beginUploadBatch(for device: Device, fileCount: Int) {
        guard fileCount > 1 else { return }
        let notifId = "\(self.id).upload.batch.\(UUID().uuidString)"
        pendingUploadBatches[device.id] = UploadBatch(total: fileCount, isExtensionInitiated: false, notificationId: notifId)
        postShareNotification(
            id: notifId,
            title: device.name,
            subtitle: "Outbound Transfer in Progress",
            body: "Sending \(fileCount) files to \(device.name)",
            sound: nil,
            urgency: .passive
        )
    }
    
    private func downloadFile(_ fileName: String?, usingTask task: DownloadTask, from device: Device) {
        guard let fileName = fileName else {
            // A filename is required to save the file meaningfully. Well-behaved clients
            // (including Android) always provide one. Proceeding without it would produce
            // an opaque, unidentifiable file, so we fail the transfer instead.
            Logger.services.error("Received file transfer with no filename from '\(device.name, privacy: .public)' — aborting download")
            self.showDownloadFinishNotification(fileName: nil, deviceName: device.name, downloadTask: task, succeeded: false)
            return
        }
        
        do {
            let url = try URL(forDownloadedFile: fileName)
            self.downloadFile(downloadTask: task, fileName: fileName, destUrl: url, deviceName: device.name, deviceId: device.id)
            // Suppress per-file start notification when a batch start notification was already shown.
            if pendingDownloadBatches[device.id] == nil {
                self.showDownloadStartNotification(fileName: fileName, deviceName: device.name, downloadTask: task)
            }
        }
        catch {
            Logger.services.error("Failed to resolve download destination for '\(fileName, privacy: .public)': \(error, privacy: .public)")
            self.showDownloadFinishNotification(fileName: fileName, deviceName: device.name, downloadTask: task, succeeded: false)
        }
    }
    
    private func downloadFile(downloadTask task: DownloadTask, fileName: String, destUrl: URL, deviceName: String, deviceId: Device.Id) {
        if let (tempStream, partUrl) = self.streamForTempDownload(finalUrl: destUrl) {
            self.downloadInfos.append(DownloadInfo(task: task, fileName: fileName, url: partUrl, deviceName: deviceName, deviceId: deviceId))
            task.delegate = self
            task.start(withStream: tempStream.transfer())
        }
        else {
            self.showDownloadFinishNotification(fileName: fileName, deviceName: deviceName, downloadTask: task, succeeded: false)
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
    
    // MARK: Notification helpers
    
    /// Per-packet notification ID for a single-file upload.
    /// Uses the DataPacket's stable ID so concurrent uploads to the same device never collide.
    private func uploadNotificationId(for packetId: Int64) -> String {
        "\(self.id).upload.\(packetId)"
    }
    
    /// Stable notification ID for a single incoming file download.
    /// The same ID is used for start and finish so the finish replaces the start in-place.
    private func downloadNotificationId(for taskId: Int64) -> String {
        "\(self.id).download.\(taskId)"
    }
    
    /// Stable notification ID for an incoming multi-file download batch.
    private func downloadBatchNotificationId(for deviceId: Device.Id) -> String {
        "\(self.id).download.batch.\(deviceId)"
    }
    
    /// Posts or replaces a share notification. Posting with an existing `id` replaces that notification.
    private func postShareNotification(
        id: String,
        title: String,
        subtitle: String,
        body: String,
        sound: UNNotificationSound?,
        urgency: UNMutableNotificationContent.NotificationUrgency,
        fileUrl: URL? = nil,
        categoryId: String? = nil
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = sound
        content.setUrgency(urgency)
        if let url = fileUrl {
            content.userInfo = [
                NotificationProperty.downloadedFileUrl.rawValue: url.absoluteString,
                UserNotificationManager.Property.actionHandlerClass.rawValue: NSStringFromClass(ShareService.self)
            ]
        }
        if let categoryId = categoryId {
            content.categoryIdentifier = categoryId
        }
        if let iconPath = self.notificationIconPath,
           let attachment = try? UNNotificationAttachment(identifier: id, url: URL(fileURLWithPath: iconPath), options: nil) {
            content.attachments = [attachment]
        }
        un.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error = error {
                Logger.services.error("Failed to post notification '\(id)': \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    private func showUploadStartNotification(to device: Device, packetId: Int64) {
        postShareNotification(
            id: uploadNotificationId(for: packetId),
            title: device.name,
            subtitle: "Outbound Transfer in Progress",
            body: "Sending File to \(device.name)",
            sound: nil,
            urgency: .passive
        )
    }
    
    private func showUploadFinishNotification(deviceName: String, packet: DataPacket, succeeded: Bool) {
        postShareNotification(
            id: uploadNotificationId(for: packet.id),
            title: deviceName,
            subtitle: succeeded ? "Outbound Transfer Successful" : "Outbound Transfer Failed",
            body: succeeded ? "File sent to \(deviceName)" : "Failed to send file to \(deviceName)",
            sound: .default,
            urgency: .active
        )
    }
    
    private func showUploadBatchFinishNotification(deviceId: Device.Id, deviceName: String, batch: UploadBatch) {
        let succeeded: Bool
        let body: String
        if batch.total == 1 {
            succeeded = batch.succeeded == 1
            body = succeeded ? "File sent to \(deviceName)" : "Failed to send file to \(deviceName)"
        } else if batch.failed == 0 {
            succeeded = true
            body = "\(batch.succeeded) files sent to \(deviceName)"
        } else if batch.succeeded == 0 {
            succeeded = false
            body = "Failed to send \(batch.failed) files to \(deviceName)"
        } else {
            succeeded = false
            body = "\(batch.succeeded) of \(batch.total) files sent to \(deviceName)"
        }
        postShareNotification(
            id: batch.notificationId,
            title: deviceName,
            subtitle: succeeded ? "Outbound Transfer Successful" : "Outbound Transfer Failed",
            body: body,
            sound: .default,
            urgency: .active
        )
    }
    
    private func showDownloadStartNotification(fileName: String?, deviceName: String, downloadTask task: DownloadTask) {
        postShareNotification(
            id: downloadNotificationId(for: task.id),
            title: deviceName,
            subtitle: "Inbound Transfer in Progress",
            body: "Receiving File from \(deviceName)",
            sound: nil,
            urgency: .active
        )
    }
    
    private func showDownloadFinishNotification(fileName: String?, deviceName: String, downloadTask task: DownloadTask, succeeded: Bool, finalUrl: URL? = nil) {
        let displayName = finalUrl?.lastPathComponent ?? fileName
        let body: String
        if let name = displayName {
            body = succeeded ? "Received '\(name)' from \(deviceName)" : "Failed to receive '\(name)' from \(deviceName)"
        } else {
            body = succeeded ? "File received from \(deviceName)" : "Transfer from \(deviceName) failed"
        }
        postShareNotification(
            id: downloadNotificationId(for: task.id),
            title: deviceName,
            subtitle: succeeded ? "Inbound Transfer Successful" : "Inbound Transfer Failed",
            body: body,
            sound: .default,
            urgency: .active,
            fileUrl: finalUrl,
            categoryId: succeeded && finalUrl != nil ? "DownloadFinished" : nil
        )
    }
    
    private func showDownloadBatchStartNotification(deviceId: Device.Id, deviceName: String, fileCount: Int, totalBytes: Int64?) {
        let sizeDesc = totalBytes.flatMap { $0 > 0 ? " (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)))" : nil } ?? ""
        postShareNotification(
            id: downloadBatchNotificationId(for: deviceId),
            title: deviceName,
            subtitle: "Inbound Transfer in Progress",
            body: "Receiving \(fileCount) files\(sizeDesc) from \(deviceName)",
            sound: nil,
            urgency: .active
        )
    }
    
    private func showDownloadBatchFinishNotification(deviceId: Device.Id, deviceName: String, batch: DownloadBatch) {
        let succeeded = batch.failed == 0
        let body: String
        if batch.failed == 0 {
            body = "Received \(batch.succeeded) files from \(deviceName)"
        } else if batch.succeeded == 0 {
            body = "Failed to receive \(batch.failed) files from \(deviceName)"
        } else {
            body = "Received \(batch.succeeded) of \(batch.totalFiles) files from \(deviceName)"
        }
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        postShareNotification(
            id: downloadBatchNotificationId(for: deviceId),
            title: deviceName,
            subtitle: succeeded ? "Inbound Transfer Successful" : "Inbound Transfer Failed",
            body: body,
            sound: .default,
            urgency: .active,
            fileUrl: downloadsURL,
            categoryId: succeeded ? "DownloadFinished" : nil
        )
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
            let filePackets = packets.filter { $0.hasPayload() }
            for p in filePackets { uploadPacketDeviceIds[p.id] = device.id }
            if filePackets.count > 1 {
                let totalSize = filePackets.compactMap { $0.payloadSize }.reduce(0, +)
                device.send(DataPacket.shareUpdatePacket(numberOfFiles: filePackets.count, totalPayloadSize: totalSize))
                self.beginUploadBatch(for: device, fileCount: filePackets.count)
            } else if filePackets.count == 1 {
                self.showUploadStartNotification(to: device, packetId: filePackets[0].id)
            }
            packets.forEach { device.send($0) }
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
        case invalidNumberOfFiles
        case invalidTotalPayloadSize
    }
    
    struct ShareProperty {
        static let filename = "filename"
        static let text = "text"
        static let url = "url"
    }
    
    struct ShareUpdateProperty {
        static let numberOfFiles = "numberOfFiles"
        static let totalPayloadSize = "totalPayloadSize"
    }
    
    
    // MARK: Properties
    
    static let sharePacketType = "kdeconnect.share.request"
    static let shareUpdatePacketType = "kdeconnect.share.request.update"
    
    var isSharePacket: Bool { return self.type == DataPacket.sharePacketType }
    var isShareUpdatePacket: Bool { return self.type == DataPacket.shareUpdatePacketType }
    
    
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
    
    static func shareUpdatePacket(numberOfFiles: Int, totalPayloadSize: Int64) -> DataPacket {
        return DataPacket(type: shareUpdatePacketType, body: [
            ShareUpdateProperty.numberOfFiles: NSNumber(value: numberOfFiles),
            ShareUpdateProperty.totalPayloadSize: NSNumber(value: totalPayloadSize)
        ])
    }
    
    func getNumberOfFiles() throws -> Int? {
        guard body.keys.contains(ShareUpdateProperty.numberOfFiles) else { return nil }
        guard let value = body[ShareUpdateProperty.numberOfFiles] as? NSNumber else { throw ShareError.invalidNumberOfFiles }
        return value.intValue
    }
    
    func getTotalPayloadSize() throws -> Int64? {
        guard body.keys.contains(ShareUpdateProperty.totalPayloadSize) else { return nil }
        guard let value = body[ShareUpdateProperty.totalPayloadSize] as? NSNumber else { throw ShareError.invalidTotalPayloadSize }
        return value.int64Value
    }
    
    func validateShareType() throws {
        guard self.isSharePacket else { throw ShareError.wrongType }
    }
}
