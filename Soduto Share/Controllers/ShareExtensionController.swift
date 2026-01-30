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
        
        let item = self.extensionContext!.inputItems[0] as! NSExtensionItem
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
        guard let content = extensionContext!.inputItems[0] as? NSExtensionItem else {
            self.extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
            return
        }
        
        guard let contents = content.attachments else {
            self.extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
            return
        }
        
        let contentType: String = UTType.url.identifier
        guard index < self.validDeviceEntries.count else {
            UserNotificationHelper.show(title: "Soduto Share", body: "Selected device is no longer available.", sound: true, id: "DeviceUnavailable", urgency: .active)
            self.extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
            return
        }
        let selectedDevice = self.validDeviceEntries[index]["id"] ?? ""
        AppDefaultsStore.ShareExtension.selectedDevice = selectedDevice
        
        // Use a DispatchGroup to wait for all async loadItem calls to complete before dismissing the extension
        let group = DispatchGroup()
        var didProcessAnyAttachment = false
        
        for attachment in contents {
            if attachment.hasItemConformingToTypeIdentifier(contentType) {
                group.enter()
                didProcessAnyAttachment = true
                attachment.loadItem(forTypeIdentifier: contentType, options: nil) { [weak self] (data, error) in
                    defer { group.leave() }
                    guard let self = self else { return }
                    
                    if let error = error {
                        NSLog("Failed to load shared item: \(error)")
                        return
                    }
                    guard let data = data as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else {
                        NSLog("Failed to create URL from shared data")
                        return
                    }
                    self.saveBookmark(url: url)
                    self.uploadFile()
                }
            } else {
                UserNotificationHelper.show(title: "Soduto Share", body: "Invalid content type selected to share", sound: true, id: "InvalidContent", urgency: .active)
            }
        }
        
        if !didProcessAnyAttachment {
            self.extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
            return
        }
        
        // Complete the extension request only after all async operations finish
        group.notify(queue: .main) {
            self.extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
        }
    }
    
    @objc func cancel(_ sender: AnyObject?) {
        let cancelError = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
        self.extensionContext!.cancelRequest(withError: cancelError)
    }
    
    private func uploadFile() {
        let notificationName = CFNotificationName("com.Soduto.Share" as CFString)
        let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(notificationCenter, notificationName, nil, nil, false)
    }
    
    private func saveBookmark(url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            AppDefaultsStore.ShareExtension.fileBookmarkData = bookmarkData
        } catch {
            print("Failed to save bookmark data for \(url)", error)
        }
    }
}
