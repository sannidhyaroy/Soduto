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

class ShareExtensionController: NSViewController, NSTouchBarDelegate, NSScrubberDataSource, NSScrubberDelegate, NSScrubberFlowLayoutDelegate {
    
    /// Each entry is ["id": "<deviceId>", "name": "<displayName>", "type": "<deviceType>"]
    var validDeviceEntries: [[String: String]] = AppDefaultsStore.ShareExtension.reachableDevices
    
    private static let scrubberItemId = NSUserInterfaceItemIdentifier("DeviceItem")
    private static let cancelItemId = NSTouchBarItem.Identifier("com.soduto.Soduto.share.touchbar.cancel")
    private static let devicesItemId = NSTouchBarItem.Identifier("com.soduto.Soduto.share.touchbar.devices")
    
    // MARK: - NSTouchBar
    
    override func makeTouchBar() -> NSTouchBar? {
        let touchBar = NSTouchBar()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [Self.cancelItemId, Self.devicesItemId]
        return touchBar
    }
    
    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case Self.cancelItemId:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.customizationLabel = "Cancel"
            let button = NSButton(
                image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel")!,
                target: self,
                action: #selector(cancel(_:))
            )
            button.bezelStyle = .inline
            item.view = button
            return item
            
        case Self.devicesItemId:
            guard !validDeviceEntries.isEmpty else { return nil }
            
            let scrubber = NSScrubber()
            scrubber.register(DeviceScrubberItemView.self, forItemIdentifier: Self.scrubberItemId)
            scrubber.dataSource = self
            scrubber.delegate = self
            scrubber.mode = .free
            scrubber.showsAdditionalContentIndicators = true
            
            let layout = NSScrubberFlowLayout()
            layout.itemSpacing = 8
            scrubber.scrubberLayout = layout
            
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = scrubber
            return item
            
        default:
            return nil
        }
    }
    
    // MARK: - NSScrubberDataSource
    
    func numberOfItems(for scrubber: NSScrubber) -> Int {
        validDeviceEntries.count
    }
    
    func scrubber(_ scrubber: NSScrubber, viewForItemAt index: Int) -> NSScrubberItemView {
        let view = scrubber.makeItem(withIdentifier: Self.scrubberItemId, owner: nil) as! DeviceScrubberItemView
        let entry = validDeviceEntries[index]
        view.configure(
            name: entry["name"] ?? "Unknown Device",
            symbolName: sfSymbolName(for: entry["type"] ?? "unknown")
        )
        return view
    }
    
    // MARK: - NSScrubberDelegate
    
    func scrubber(_ scrubber: NSScrubber, didSelectItemAt index: Int) {
        shareToDevice(at: index)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            scrubber.selectedIndex = -1
        }
    }
    
    // MARK: - NSScrubberFlowLayoutDelegate
    
    func scrubber(_ scrubber: NSScrubber, layout: NSScrubberFlowLayout, sizeForItemAt itemIndex: Int) -> NSSize {
        let name = validDeviceEntries[itemIndex]["name"] ?? "Unknown Device"
        let textWidth = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        let itemWidth = min(max(textWidth + 42, 80), 160)
        return NSSize(width: itemWidth, height: 30)
    }
    
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

// MARK: - Touch Bar Scrubber Item

private class DeviceScrubberItemView: NSScrubberItemView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    
    override var isSelected: Bool {
        didSet { updateAppearance() }
    }
    
    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }
    
    private func updateAppearance() {
        if isHighlighted {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
        } else if isSelected {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
        } else {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        }
    }
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = .labelColor
        nameLabel.backgroundColor = .clear
        nameLabel.isBordered = false
        nameLabel.isEditable = false
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        
        addSubview(iconView)
        addSubview(nameLabel)
        
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    func configure(name: String, symbolName: String) {
        nameLabel.stringValue = name
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        iconView.contentTintColor = .labelColor
    }
}
