//
//  ShareViewController.swift
//  Soduto Share
//
//  Created by Sannidhya Roy on 03/12/22.
//  Copyright © 2022 Soduto. All rights reserved.
//

import Cocoa
import UserNotifications
import UniformTypeIdentifiers

class ShareViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTouchBarDelegate {
    
    @IBOutlet private weak var infoText: NSTextField!
    @IBOutlet private weak var tableScroll: NSScrollView!
    let un = UNUserNotificationCenter.current()
    var touchButtonTag = 0
    
    /// Each entry is ["id": "<deviceId>", "name": "<displayName>"]
    var validDeviceEntries = AppDefaultsStore.ShareExtension.reachableDevices
    var validDeviceNames: [String] {
        return validDeviceEntries.map { $0["name"] ?? "Unknown Device" }
    }
    
    //MARK: - NSTableViewDataSource
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        self.validDeviceEntries.count
    }
    
    //MARK: -NSTableViewDelegate
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn = tableColumn else {
            return nil
        }
        
        if tableColumn.identifier == .labelColumn,
           let cell = tableView.makeView(withIdentifier: .labelIdentifier, owner: self) as? ButtonLabelCell
        {
            // Insert code for button column
            cell.configure(self.validDeviceNames[row], tag: row)
            return cell
        }
        else {
            return nil
        }
    }
    
    //MARK: -NSTouchBar
    
    @available(macOS 10.12.1, *)
    override func makeTouchBar() -> NSTouchBar? {
        
        let touchBarIdenitifier = NSTouchBar.CustomizationIdentifier("com.Soduto.TouchBar")
        let touchBarButtonIdentifier = NSTouchBarItem.Identifier(rawValue: "com.Soduto.TouchBar.cancelButton")
        var touchBarAllowedIdentifiers = [touchBarButtonIdentifier]
        if !(self.validDeviceEntries.isEmpty) {
            var i = 0
            for _ in validDeviceEntries {
                touchBarAllowedIdentifiers.append(NSTouchBarItem.Identifier(rawValue: "com.Soduto.TouchBar.device" + String(i)))
                i += 1
            }
        }
        let touchBar = NSTouchBar()
        touchBar.delegate = self
        touchBar.customizationIdentifier = touchBarIdenitifier
        touchBar.defaultItemIdentifiers = touchBarAllowedIdentifiers
        touchBar.customizationAllowedItemIdentifiers = touchBarAllowedIdentifiers
        
        return touchBar
    }
    
    @available(macOS 10.12.1, *)
    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        if identifier.rawValue == "com.Soduto.TouchBar.cancelButton" {
            let cancel = NSCustomTouchBarItem(identifier: identifier)
            cancel.customizationLabel = "Cancel"
            if #available(macOSApplicationExtension 11.0, *) {
                let label = NSButton.init(title: "Cancel", image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)!, target: self, action: #selector(self.cancel(_:)))
                cancel.view = label
                return cancel
            } else {
                let label = NSButton.init(title: "Cancel", target: self, action: #selector(self.cancel(_:)))
                cancel.view = label
                return cancel
            }
        }
        if !(self.validDeviceEntries.isEmpty) {
            let button = NSCustomTouchBarItem(identifier: identifier)
            button.customizationLabel = self.validDeviceNames[self.touchButtonTag]
            let label = NSButton.init(title: self.validDeviceNames[self.touchButtonTag], target: self, action: #selector(self.send(_:)))
            label.tag = self.touchButtonTag
            button.view = label
            self.touchButtonTag += 1
            return button
        }
        return nil
    }
    
    @available(macOS 10.12.1, *)
    deinit {
        self.view.window?.unbind(NSBindingName(rawValue: #keyPath(touchBar)))
    }
    
    //MARK: -NSViewController
    
    override var nibName: NSNib.Name? {
        return NSNib.Name("ShareViewController")
    }
    
    override func loadView() {
        super.loadView()
        
        // Insert code here to customize the view
        
        if (self.validDeviceEntries.isEmpty) {
            infoText.isHidden = false
            tableScroll.isHidden = true
        }
        let item = self.extensionContext!.inputItems[0] as! NSExtensionItem
        if let attachments = item.attachments {
            NSLog("Attachments = %@", attachments as NSArray)
        } else {
            NSLog("No Attachments")
        }
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        if #available(OSX 10.12.1, *) {
            self.view.window?.unbind(NSBindingName(rawValue: #keyPath(touchBar))) // unbind first
            self.view.window?.bind(NSBindingName(rawValue: #keyPath(touchBar)), to: self, withKeyPath: #keyPath(touchBar), options: nil)
        }
    }
    
    @IBAction func send(_ sender: AnyObject?) {
        guard let content = extensionContext!.inputItems[0] as? NSExtensionItem else {
            self.extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
            return
        }
        
        guard let contents = content.attachments else {
            self.extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
            return
        }
        
        let contentType: String = UTType.url.identifier
        // Store the selected device ID instead of an array index
        let pressedBtnTag = sender?.tag ?? 0
        guard pressedBtnTag < self.validDeviceEntries.count else {
            UserNotificationHelper.show(title: "Soduto Share", body: "Selected device is no longer available.", sound: true, id: "DeviceUnavailable", urgency: .active)
            self.extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
            return
        }
        let selectedDevice = self.validDeviceEntries[pressedBtnTag]["id"] ?? ""
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
    
    @IBAction func cancel(_ sender: AnyObject?) {
        let cancelError = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
        self.extensionContext!.cancelRequest(withError: cancelError)
    }
    
    private func uploadFile() {
        let notificationName = CFNotificationName("com.Soduto.Share" as CFString)
        let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
        
        CFNotificationCenterPostNotification(notificationCenter, notificationName, nil, nil, false)
    }
    
    func saveBookmark(url: URL) {
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

extension NSUserInterfaceItemIdentifier {
    static let labelColumn = NSUserInterfaceItemIdentifier("LabelColumn")
    static let labelIdentifier = NSUserInterfaceItemIdentifier("LabelIdentifier")
}
