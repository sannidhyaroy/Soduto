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

class ShareExtensionController: NSViewController {
    
    /// Each entry is ["id": "<deviceId>", "name": "<displayName>", "type": "<deviceType>"]
    var validDeviceEntries: [[String: String]] = AppDefaultsStore.ShareExtension.reachableDevices
    
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
        let rootView = ShareSheetView(deviceEntries: validDeviceEntries, onDeviceSelected: { [weak self] index in
            self?.shareToDevice(at: index)
        }, onCancel: { [weak self] in
            self?.cancel(nil)
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
            NSLog("Attachments = %@", attachments as NSArray)
        } else {
            NSLog("No Attachments")
        }
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        self.view.window?.unbind(NSBindingName(rawValue: #keyPath(touchBar)))
        self.view.window?.bind(NSBindingName(rawValue: #keyPath(touchBar)), to: self, withKeyPath: #keyPath(touchBar), options: nil)
    }
    
    deinit {
        self.view.window?.unbind(NSBindingName(rawValue: #keyPath(touchBar)))
    }
    
    // MARK: - Share Logic
    
    func shareToDevice(at index: Int) {
        guard let content = extensionContext?.inputItems.first as? NSExtensionItem else {
            self.extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
            return
        }
        
        guard index < self.validDeviceEntries.count else {
            UserNotificationHelper.show(title: "Soduto Share", body: "Selected device is no longer available.", sound: true, id: "DeviceUnavailable", urgency: .active)
            self.extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
            return
        }
        let selectedDevice = self.validDeviceEntries[index]["id"] ?? ""
        AppDefaultsStore.ShareExtension.selectedDevice = selectedDevice
        
        // Use a DispatchGroup to wait for all async loadItem calls to complete before dismissing the extension
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
                        NSLog("Failed to load shared item: \(error)")
                        return
                    }
                    guard let data = data as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else {
                        NSLog("Failed to create URL from shared data")
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
                        NSLog("Failed to load shared text: \(error)")
                        return
                    }
                    guard let text = data as? String else {
                        NSLog("Failed to read shared text")
                        return
                    }
                    lock.lock()
                    collectedTexts.append(text)
                    lock.unlock()
                }
            }
        }
        
        // Wait for all async attachment loads, then store results and notify the main app
        group.notify(queue: .main) {
            if !collectedBookmarks.isEmpty {
                AppDefaultsStore.ShareExtension.fileBookmarkData = collectedBookmarks
            }
            if !collectedTexts.isEmpty {
                AppDefaultsStore.ShareExtension.sharedTexts = collectedTexts
            }
            if !collectedBookmarks.isEmpty || !collectedTexts.isEmpty {
                self.notifyMainApp()
            }
            self.extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
        }
    }
    
    @objc func cancel(_ sender: AnyObject?) {
        let cancelError = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
        self.extensionContext!.cancelRequest(withError: cancelError)
    }
    
    private func notifyMainApp() {
        let notificationName = CFNotificationName("com.Soduto.Share" as CFString)
        let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(notificationCenter, notificationName, nil, nil, false)
    }
    
    private static func createBookmark(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            print("Failed to create bookmark data for \(url)", error)
            return nil
        }
    }
}
