//
//  ShareExtensionController+TouchBar.swift
//  Soduto Share
//
//  Created by Sannidhya Roy on 30/01/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Cocoa

extension ShareExtensionController: NSTouchBarDelegate, NSScrubberDataSource, NSScrubberDelegate, NSScrubberFlowLayoutDelegate {
    
    static let scrubberItemId = NSUserInterfaceItemIdentifier("DeviceItem")
    static let cancelItemId = NSTouchBarItem.Identifier("com.soduto.Soduto.share.touchbar.cancel")
    static let devicesItemId = NSTouchBarItem.Identifier("com.soduto.Soduto.share.touchbar.devices")
    
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
        guard viewModel.isInteractive(index) else {
            scrubber.selectedIndex = -1
            return
        }
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
}
