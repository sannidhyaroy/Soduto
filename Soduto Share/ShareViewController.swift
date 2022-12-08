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

let sharedUserDefaults = UserDefaults(suiteName: SharedUserDefaults.suiteName)

class ShareViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTouchBarDelegate {
    
    @IBOutlet private weak var infoText: NSTextField!
    @IBOutlet private weak var tableScroll: NSScrollView!
    let un = UNUserNotificationCenter.current()
    var touchButtonTag = 0
    var validDevices = sharedUserDefaults?.object(forKey: SharedUserDefaults.Keys.devicesToShow) as? [String] ?? []
    
    //MARK: - NSTableViewDataSource
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        self.validDevices.count
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
            cell.configure(self.validDevices[row], tag: row)
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
        if !(self.validDevices.isEmpty) {
            var i = 0
            for _ in validDevices {
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
        if !(self.validDevices.isEmpty) {
            let button = NSCustomTouchBarItem(identifier: identifier)
            button.customizationLabel = self.validDevices[self.touchButtonTag]
            let label = NSButton.init(title: self.validDevices[self.touchButtonTag], target: self, action: #selector(self.send(_:)))
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
        
        if (self.validDevices.isEmpty) {
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
        var contentType: String
        if let content = extensionContext!.inputItems[0] as? NSExtensionItem {
            if #available(macOSApplicationExtension 11.0, *) {
                contentType = UTType.url.identifier
            } else {
                // Fallback on earlier versions
                contentType = kUTTypeURL as String
            }
            
            if let contents = content.attachments {
                let pressedBtnTag = sender?.tag
                sharedUserDefaults?.set(pressedBtnTag, forKey: SharedUserDefaults.Keys.buttonTag)
                // look for content files
                for attachment in contents {
                    if attachment.hasItemConformingToTypeIdentifier(contentType) {
                        attachment.loadItem(forTypeIdentifier: contentType, options: nil, completionHandler: { (data, error) in
                            if let url = URL(dataRepresentation: data as! Data, relativeTo: nil) {
                                self.saveBookmark(url: url)
                                self.uploadFile()
                            }
                        })
                    } else {
                        self.ShowCustomNotification(title: "Soduto Share", body: "Invalid content type selected to share", sound: true, id: "InvalidContent")
                    }
                }
            }
        }
        // Complete implementation by setting the appropriate value on the output item
        
        self.extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
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
            sharedUserDefaults?.set(bookmarkData, forKey: SharedUserDefaults.Keys.kSandboxKey)
        } catch {
            print("Failed to save bookmark data for \(url)", error)
        }
    }
    
    // MARK: Notification System
    
    public func ShowCustomNotification(title: String, body: String, sound: Bool, id: String) {
        if #available(macOS 11.0, *) {
            un.getNotificationSettings { (settings) in
                if settings.authorizationStatus == .authorized {
                    let notification = UNMutableNotificationContent()
                    notification.title = title
                    notification.body = body
                    if sound {
                        notification.sound = UNNotificationSound.default
                    }
                    let request = UNNotificationRequest(identifier: id, content: notification, trigger: nil)
                    self.un.add(request){ (error) in
                        if error != nil {print(error?.localizedDescription as Any)}
                    }
                }
                else {
                    print("Soduto isn't authorized to send notifications!")
                }
            }
        } else {
            let notification = NSUserNotification()
            notification.title = title
            notification.informativeText = body
            if sound {
                notification.soundName = NSUserNotificationDefaultSoundName
            }
            notification.identifier = id
            NSUserNotificationCenter.default.deliver(notification)
        }
    }
}

extension NSUserInterfaceItemIdentifier {
    static let labelColumn = NSUserInterfaceItemIdentifier("LabelColumn")
    static let labelIdentifier = NSUserInterfaceItemIdentifier("LabelIdentifier")
}
