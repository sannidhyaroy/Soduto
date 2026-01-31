//
//  ShareExtensionController.swift
//  Soduto Share
//
//  Created by Sannidhya Roy on 03/12/22.
//  Copyright © 2022 Soduto. All rights reserved.
//

import Cocoa
import SwiftUI
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.soduto.Soduto.Soduto-Share", category: "ShareExtension")

class ShareExtensionController: NSViewController {
    
    /// Each entry is ["id": "<deviceId>", "name": "<displayName>", "type": "<deviceType>"]
    var validDeviceEntries: [[String: String]] = AppDefaultsStore.ShareExtension.reachableDevices
    
    lazy var viewModel = ShareViewModel(deviceCount: validDeviceEntries.count)
    
    // MARK: - NSViewController
    
    /// Computes a sheet height that fits the content, capped at a maximum.
    private var sheetHeight: CGFloat {
        guard !validDeviceEntries.isEmpty else { return 240 }
        
        let fixedHeight: CGFloat = 84  // title (~44) + 2 dividers (~2) + footer (~38)
        let columnsPerRow = 4
        let rowCount = Int(ceil(Double(validDeviceEntries.count) / Double(columnsPerRow)))
        let gridHeight = CGFloat(rowCount) * 75        // 56 circle + 6 spacing + 13 text
        + CGFloat(max(0, rowCount - 1)) * 16       // inter-row spacing
        + 32                                        // grid padding (16 top + 16 bottom)
        
        return min(fixedHeight + gridHeight, 400)
    }
    
    override func loadView() {
        // Clear any stale transfer statuses from a previous session
        AppDefaultsStore.ShareExtension.transferStatuses = nil
        
        let rootView = ShareSheetView(viewModel: viewModel, deviceEntries: validDeviceEntries, onDeviceSelected: { [weak self] index in
            self?.shareToDevice(at: index)
        }, onDismiss: { [weak self] in
            guard let self = self else { return }
            if self.viewModel.hasInitiatedAnyShare {
                self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            } else {
                self.cancel(nil)
            }
        })
        
        let height = sheetHeight
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 410, height: height))
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        
        self.view = container
        self.preferredContentSize = NSSize(width: 410, height: height)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        guard let item = self.extensionContext?.inputItems.first as? NSExtensionItem else { return }
        if let attachments = item.attachments {
            logger.debug("Attachments = \(attachments)")
        } else {
            logger.debug("No Attachments")
        }
        
        // Register for reverse Darwin notifications from main app (transfer status updates)
        let statusNotificationName = "com.soduto.share.status" as CFString
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(), { _, observer, _, _, _ in
            guard let observer = observer else { return }
            let controller = Unmanaged<ShareExtensionController>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async {
                controller.handleStatusUpdate()
            }
        }, statusNotificationName, nil, .deliverImmediately)
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        self.view.window?.unbind(NSBindingName(rawValue: #keyPath(touchBar)))
        self.view.window?.bind(NSBindingName(rawValue: #keyPath(touchBar)), to: self, withKeyPath: #keyPath(touchBar), options: nil)
    }
    
    deinit {
        self.view.window?.unbind(NSBindingName(rawValue: #keyPath(touchBar)))
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(), nil, nil)
        AppDefaultsStore.ShareExtension.transferStatuses = nil
    }
    
    // MARK: - Share Logic
    
    func shareToDevice(at index: Int) {
        // Guard: device must be interactive
        guard viewModel.isInteractive(index) else { return }
        
        // Guard: valid index
        guard index < validDeviceEntries.count else {
            UserNotificationHelper.show(title: "Soduto Share", body: "Selected device is no longer available.", sound: true, id: "DeviceUnavailable", urgency: .active)
            return
        }
        
        // Guard: not currently collecting attachments (prevents race on first tap)
        guard !viewModel.isCollectingAttachments else { return }
        
        // Set transferring state (breathing ring appears)
        viewModel.deviceStatuses[index] = .transferring
        
        if viewModel.cachedBookmarks != nil {
            // Attachments already cached — hand off immediately
            handOffToMainApp(deviceIndex: index)
        } else {
            // First tap — collect attachments, then hand off
            collectAttachmentsThenHandOff(deviceIndex: index)
        }
    }
    
    @objc func cancel(_ sender: AnyObject?) {
        let cancelError = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
        self.extensionContext!.cancelRequest(withError: cancelError)
    }
    
    // MARK: - Attachment Collection
    
    private func collectAttachmentsThenHandOff(deviceIndex: Int) {
        guard let content = extensionContext?.inputItems.first as? NSExtensionItem else { return }
        
        viewModel.isCollectingAttachments = true
        
        let group = DispatchGroup()
        let lock = NSLock()
        var collectedBookmarks: [Data] = []
        var collectedTexts: [String] = []
        
        // macOS share sheet provides shared text via attributedContentText on NSExtensionItem.
        if let attributedText = content.attributedContentText {
            let text = attributedText.string
            if !text.isEmpty {
                collectedTexts.append(text)
            }
        }
        
        for attachment in content.attachments ?? [] {
            if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                attachment.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] (data, error) in
                    defer { group.leave() }
                    guard self != nil else { return }
                    
                    if let error = error {
                        logger.error("Failed to load shared item: \(error.localizedDescription)")
                        return
                    }
                    guard let data = data as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else {
                        logger.error("Failed to create URL from shared data")
                        return
                    }
                    if let bookmark = Self.createBookmark(for: url) {
                        lock.lock()
                        collectedBookmarks.append(bookmark)
                        lock.unlock()
                    }
                }
            } else if collectedTexts.isEmpty && attachment.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                // Safety net: in case an app vends text via NSItemProvider instead of attributedContentText
                group.enter()
                attachment.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] (data, error) in
                    defer { group.leave() }
                    guard self != nil else { return }
                    
                    if let error = error {
                        logger.error("Failed to load shared text: \(error.localizedDescription)")
                        return
                    }
                    guard let text = data as? String else {
                        logger.error("Failed to read shared text")
                        return
                    }
                    lock.lock()
                    collectedTexts.append(text)
                    lock.unlock()
                }
            }
        }
        
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            
            // Cache for reuse on subsequent device taps
            self.viewModel.cachedBookmarks = collectedBookmarks
            self.viewModel.cachedTexts = collectedTexts
            self.viewModel.isCollectingAttachments = false
            
            self.handOffToMainApp(deviceIndex: deviceIndex)
        }
    }
    
    // MARK: - Handoff to Main App
    
    private func handOffToMainApp(deviceIndex: Int) {
        let selectedDevice = validDeviceEntries[deviceIndex]["id"] ?? ""
        
        // Clear any previous status for this device (important for retries)
        var statuses = AppDefaultsStore.ShareExtension.transferStatuses ?? [:]
        statuses.removeValue(forKey: selectedDevice)
        AppDefaultsStore.ShareExtension.transferStatuses = statuses
        
        // Write device ID
        AppDefaultsStore.ShareExtension.selectedDevice = selectedDevice
        
        // Write cached attachment data
        let bookmarks = viewModel.cachedBookmarks ?? []
        let texts = viewModel.cachedTexts ?? []
        
        if !bookmarks.isEmpty {
            AppDefaultsStore.ShareExtension.fileBookmarkData = bookmarks
        }
        if !texts.isEmpty {
            AppDefaultsStore.ShareExtension.sharedTexts = texts
        }
        
        // Notify the main app only if there is data to share
        if !bookmarks.isEmpty || !texts.isEmpty {
            notifyMainApp()
        }
    }
    
    // MARK: - Status Updates from Main App
    
    func handleStatusUpdate() {
        guard let statuses = AppDefaultsStore.ShareExtension.transferStatuses else { return }
        for (index, entry) in validDeviceEntries.enumerated() {
            guard let deviceId = entry["id"], let status = statuses[deviceId] else { continue }
            switch status {
            case "success":
                viewModel.deviceStatuses[index] = .sent
            case "failed":
                viewModel.deviceStatuses[index] = .failed
            default:
                break
            }
        }
    }
    
    // MARK: - Private Helpers
    
    private func notifyMainApp() {
        let notificationName = CFNotificationName("com.soduto.share.handoff" as CFString)
        let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(notificationCenter, notificationName, nil, nil, false)
    }
    
    private static func createBookmark(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            logger.error("Failed to create bookmark for \(url): \(error.localizedDescription)")
            return nil
        }
    }
}
